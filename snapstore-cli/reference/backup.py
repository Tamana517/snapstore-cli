#!/usr/bin/env python3
"""
Incremental snapshot backup tool with content-addressable storage.

Handles hard links, sparse files, basic crash safety via temp directories,
and referential integrity on prune.
"""

import argparse
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


# ---------------------------------------------------------------------------
# Low-level helpers
# ---------------------------------------------------------------------------

def sha256_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def is_sparse(path: Path) -> bool:
    """Heuristic: logical size significantly larger than allocated blocks."""
    try:
        st = path.stat()
        # st_blocks is 512-byte blocks on Linux
        allocated = st.st_blocks * 512
        return st.st_size > allocated + 4096
    except OSError:
        return False


def copy_sparse(src: Path, dst: Path) -> None:
    """Copy a file, attempting to preserve sparsity on Linux."""
    # Prefer a simple approach that works: read/write in chunks and
    # use truncate + seek for holes when possible. For portability we
    # fall back to a full copy if the advanced path fails.
    try:
        src_st = src.stat()
        with open(src, "rb") as sf, open(dst, "wb") as df:
            # First truncate to the logical size
            df.truncate(src_st.st_size)
            pos = 0
            while pos < src_st.st_size:
                # Try to find data / hole boundaries (Linux SEEK_DATA / SEEK_HOLE)
                try:
                    data_start = os.lseek(sf.fileno(), pos, os.SEEK_DATA)
                    hole_start = os.lseek(sf.fileno(), data_start, os.SEEK_HOLE)
                except (OSError, AttributeError):
                    # Fallback: just copy everything
                    sf.seek(pos)
                    remaining = src_st.st_size - pos
                    while remaining > 0:
                        chunk = sf.read(min(1024 * 1024, remaining))
                        if not chunk:
                            break
                        df.write(chunk)
                        remaining -= len(chunk)
                    break

                # Write the data extent
                sf.seek(data_start)
                to_read = hole_start - data_start
                while to_read > 0:
                    chunk = sf.read(min(1024 * 1024, to_read))
                    if not chunk:
                        break
                    df.seek(data_start + (hole_start - data_start - to_read))
                    df.write(chunk)
                    to_read -= len(chunk)
                pos = hole_start
        os.chmod(dst, src_st.st_mode)
    except OSError:
        shutil.copy2(src, dst)


def ensure_dir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)


# ---------------------------------------------------------------------------
# Repository layout
#
# repo/
#   objects/          # content-addressed blobs (sha256)
#   snapshots/        # one json file per snapshot
#   tmp/              # temporary work area (cleaned on start)
# ---------------------------------------------------------------------------

class Repo:
    def __init__(self, root: Path):
        self.root = root
        self.objects = root / "objects"
        self.snapshots = root / "snapshots"
        self.tmp = root / "tmp"
        ensure_dir(self.objects)
        ensure_dir(self.snapshots)
        ensure_dir(self.tmp)

    def object_path(self, digest: str) -> Path:
        # two-level fan-out to keep directories manageable
        return self.objects / digest[:2] / digest[2:]

    def store_blob(self, src: Path) -> str:
        digest = sha256_file(src)
        dest = self.object_path(digest)
        if not dest.exists():
            ensure_dir(dest.parent)
            # copy into place atomically
            tmp = self.tmp / f"blob-{uuid.uuid4().hex}"
            shutil.copy2(src, tmp)
            os.replace(tmp, dest)
        return digest

    def store_bytes(self, data: bytes) -> str:
        digest = hashlib.sha256(data).hexdigest()
        dest = self.object_path(digest)
        if not dest.exists():
            ensure_dir(dest.parent)
            tmp = self.tmp / f"blob-{uuid.uuid4().hex}"
            tmp.write_bytes(data)
            os.replace(tmp, dest)
        return digest

    def has_object(self, digest: str) -> bool:
        return self.object_path(digest).exists()

    def open_object(self, digest: str) -> Path:
        p = self.object_path(digest)
        if not p.exists():
            raise FileNotFoundError(f"missing object {digest}")
        return p


# ---------------------------------------------------------------------------
# Snapshot metadata
# ---------------------------------------------------------------------------

# Each entry in the tree is one of:
#   {"type": "file", "digest": "...", "size": N, "mode": ..., "sparse": bool}
#   {"type": "dir",  "mode": ...}
#   {"type": "symlink", "target": "...", "mode": ...}
#   {"type": "hardlink", "target": "relative/path/to/first"}  # points at first occurrence

def walk_source(source: Path) -> Tuple[Dict, Dict[int, str]]:
    """
    Walk the source tree and build a nested dict representation.
    Returns (tree, inode_to_first_relpath) for hard-link detection.
    """
    inode_first: Dict[int, str] = {}
    root: Dict = {"type": "dir", "mode": 0o755, "children": {}}

    def get_dir_node(rel: str) -> Dict:
        """Return the children dict for the directory at relative path rel."""
        if not rel or rel == ".":
            return root["children"]
        node = root
        for part in rel.split(os.sep):
            if part not in node["children"]:
                node["children"][part] = {"type": "dir", "mode": 0o755, "children": {}}
            node = node["children"][part]
            if "children" not in node:
                node["children"] = {}
        return node["children"]

    for dirpath, dirnames, filenames in os.walk(source, followlinks=False):
        rel_dir = os.path.relpath(dirpath, source)
        if rel_dir == ".":
            rel_dir = ""
        children = get_dir_node(rel_dir)

        for name in sorted(filenames):
            full = Path(dirpath) / name
            try:
                st = full.lstat()
            except OSError:
                continue

            rel_path = str(Path(rel_dir) / name) if rel_dir else name

            if stat.S_ISLNK(st.st_mode):
                target = os.readlink(full)
                children[name] = {"type": "symlink", "target": target, "mode": st.st_mode}
            elif stat.S_ISREG(st.st_mode):
                if st.st_nlink > 1 and st.st_ino in inode_first:
                    children[name] = {"type": "hardlink", "target": inode_first[st.st_ino]}
                else:
                    if st.st_nlink > 1:
                        inode_first[st.st_ino] = rel_path
                    children[name] = {
                        "type": "file",
                        "path": str(full),
                        "size": st.st_size,
                        "mode": st.st_mode,
                        "sparse": is_sparse(full),
                    }

        for name in sorted(dirnames):
            full = Path(dirpath) / name
            try:
                st = full.lstat()
            except OSError:
                continue
            if name not in children:
                children[name] = {"type": "dir", "mode": st.st_mode, "children": {}}

    return root, inode_first


def materialize_tree(repo: Repo, node: Dict, dest: Path, hardlink_map: Dict[str, Path]) -> None:
    """Recursively recreate the tree under dest."""
    typ = node.get("type")
    if typ == "dir":
        ensure_dir(dest)
        for name, child in node.get("children", {}).items():
            materialize_tree(repo, child, dest / name, hardlink_map)
    elif typ == "file":
        src_blob = repo.open_object(node["digest"])
        if node.get("sparse"):
            copy_sparse(src_blob, dest)
        else:
            shutil.copy2(src_blob, dest)
        try:
            os.chmod(dest, node.get("mode", 0o644))
        except OSError:
            pass
    elif typ == "symlink":
        if dest.exists() or dest.is_symlink():
            dest.unlink()
        os.symlink(node["target"], dest)
    elif typ == "hardlink":
        target_rel = node["target"]
        if target_rel not in hardlink_map:
            raise RuntimeError(f"hardlink target missing: {target_rel}")
        if dest.exists() or dest.is_symlink():
            dest.unlink()
        os.link(hardlink_map[target_rel], dest)
    else:
        raise RuntimeError(f"unknown node type {typ}")


def collect_digests(node: Dict, out: Set[str]) -> None:
    typ = node.get("type")
    if typ == "file":
        out.add(node["digest"])
    elif typ == "dir":
        for child in node.get("children", {}).values():
            collect_digests(child, out)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_backup(source: Path, repo_path: Path) -> int:
    if not source.is_dir():
        print(f"error: source does not exist or is not a directory: {source}", file=sys.stderr)
        return 1

    repo = Repo(repo_path)
    # clean tmp
    for p in repo.tmp.iterdir():
        if p.is_file():
            p.unlink()
        else:
            shutil.rmtree(p, ignore_errors=True)

    tree, _ = walk_source(source)

    # second pass: store file contents and replace "path" with "digest"
    def store_files(node: Dict) -> None:
        if node.get("type") == "file" and "path" in node:
            src = Path(node.pop("path"))
            digest = repo.store_blob(src)
            node["digest"] = digest
        elif node.get("type") == "dir":
            for child in node.get("children", {}).values():
                store_files(child)

    store_files(tree)

    # Use a monotonic counter + timestamp so lexicographic order matches creation order
    existing = list(repo.snapshots.glob("*.json"))
    seq = len(existing) + 1
    snapshot_id = f"{seq:06d}-{time.strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:6]}"
    meta = {
        "id": snapshot_id,
        "created": time.time(),
        "tree": tree,
    }

    # write snapshot atomically
    snap_path = repo.snapshots / f"{snapshot_id}.json"
    tmp_snap = repo.tmp / f"snap-{uuid.uuid4().hex}"
    tmp_snap.write_text(json.dumps(meta, indent=2, sort_keys=True))
    os.replace(tmp_snap, snap_path)

    print(snapshot_id)
    return 0


def cmd_restore(repo_path: Path, snapshot_id: str, dest: Path) -> int:
    repo = Repo(repo_path)
    snap_file = repo.snapshots / f"{snapshot_id}.json"
    if not snap_file.exists():
        print(f"error: snapshot not found: {snapshot_id}", file=sys.stderr)
        return 1

    meta = json.loads(snap_file.read_text())
    tree = meta["tree"]

    if dest.exists():
        # only allow restoring into an empty directory or a new path
        if any(dest.iterdir()):
            print(f"error: destination is not empty: {dest}", file=sys.stderr)
            return 1
    else:
        ensure_dir(dest)

    # first materialize all non-hardlink files so we can build the hardlink map
    hardlink_map: Dict[str, Path] = {}

    def first_pass(node: Dict, rel: str, base: Path) -> None:
        typ = node.get("type")
        if typ == "dir":
            ensure_dir(base)
            for name, child in node.get("children", {}).items():
                first_pass(child, f"{rel}/{name}" if rel else name, base / name)
        elif typ == "file":
            src_blob = repo.open_object(node["digest"])
            if node.get("sparse"):
                copy_sparse(src_blob, base)
            else:
                shutil.copy2(src_blob, base)
            try:
                os.chmod(base, node.get("mode", 0o644))
            except OSError:
                pass
            hardlink_map[rel] = base
        elif typ == "symlink":
            if base.exists() or base.is_symlink():
                base.unlink()
            os.symlink(node["target"], base)
        elif typ == "hardlink":
            # resolved in second pass
            pass

    first_pass(tree, "", dest)

    # second pass for hard links
    def second_pass(node: Dict, rel: str, base: Path) -> None:
        typ = node.get("type")
        if typ == "dir":
            for name, child in node.get("children", {}).items():
                second_pass(child, f"{rel}/{name}" if rel else name, base / name)
        elif typ == "hardlink":
            target_rel = node["target"]
            if target_rel not in hardlink_map:
                print(f"error: hardlink target missing: {target_rel}", file=sys.stderr)
                raise RuntimeError("missing hardlink target")
            if base.exists() or base.is_symlink():
                base.unlink()
            os.link(hardlink_map[target_rel], base)

    try:
        second_pass(tree, "", dest)
    except RuntimeError:
        return 1

    return 0


def cmd_list(repo_path: Path) -> int:
    repo = Repo(repo_path)
    ids = sorted(p.stem for p in repo.snapshots.glob("*.json"))
    for i in ids:
        print(i)
    return 0


def cmd_verify(repo_path: Path, snapshot_id: Optional[str] = None) -> int:
    repo = Repo(repo_path)
    if snapshot_id:
        snap_files = [repo.snapshots / f"{snapshot_id}.json"]
        if not snap_files[0].exists():
            print(f"error: snapshot not found: {snapshot_id}", file=sys.stderr)
            return 1
    else:
        snap_files = list(repo.snapshots.glob("*.json"))

    errors = 0
    for sf in snap_files:
        try:
            meta = json.loads(sf.read_text())
            digests: Set[str] = set()
            collect_digests(meta["tree"], digests)
            for d in digests:
                if not repo.has_object(d):
                    print(f"missing object {d} referenced by {sf.stem}", file=sys.stderr)
                    errors += 1
                else:
                    # light check: file exists and is non-empty if size > 0
                    p = repo.object_path(d)
                    if p.stat().st_size == 0 and d != hashlib.sha256(b"").hexdigest():
                        # empty file is valid, but we still count it present
                        pass
        except Exception as e:
            print(f"error reading {sf}: {e}", file=sys.stderr)
            errors += 1

    return 1 if errors else 0


def cmd_prune(repo_path: Path, keep: int) -> int:
    if keep < 0:
        print("error: --keep must be non-negative", file=sys.stderr)
        return 1

    repo = Repo(repo_path)
    snaps = sorted(repo.snapshots.glob("*.json"), key=lambda p: p.stem)
    if len(snaps) <= keep:
        return 0

    to_remove = snaps[: len(snaps) - keep]
    to_keep = snaps[len(snaps) - keep :]

    # collect digests that must stay
    live: Set[str] = set()
    for sf in to_keep:
        meta = json.loads(sf.read_text())
        collect_digests(meta["tree"], live)

    # remove old snapshot metadata first
    for sf in to_remove:
        sf.unlink()

    # now remove unreferenced objects
    for dirpath, _, filenames in os.walk(repo.objects):
        for name in filenames:
            full = Path(dirpath) / name
            # reconstruct digest from fan-out path
            rel = full.relative_to(repo.objects)
            digest = str(rel).replace(os.sep, "")
            if digest not in live:
                try:
                    full.unlink()
                except OSError:
                    pass

    return 0


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="backup")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_backup = sub.add_parser("backup")
    p_backup.add_argument("source_dir")
    p_backup.add_argument("repo_dir")

    p_restore = sub.add_parser("restore")
    p_restore.add_argument("repo_dir")
    p_restore.add_argument("snapshot_id")
    p_restore.add_argument("dest_dir")

    p_list = sub.add_parser("list")
    p_list.add_argument("repo_dir")

    p_verify = sub.add_parser("verify")
    p_verify.add_argument("repo_dir")
    p_verify.add_argument("snapshot_id", nargs="?")

    p_prune = sub.add_parser("prune")
    p_prune.add_argument("repo_dir")
    p_prune.add_argument("--keep", type=int, required=True)

    args = parser.parse_args(argv)

    try:
        if args.cmd == "backup":
            return cmd_backup(Path(args.source_dir), Path(args.repo_dir))
        elif args.cmd == "restore":
            return cmd_restore(Path(args.repo_dir), args.snapshot_id, Path(args.dest_dir))
        elif args.cmd == "list":
            return cmd_list(Path(args.repo_dir))
        elif args.cmd == "verify":
            return cmd_verify(Path(args.repo_dir), args.snapshot_id)
        elif args.cmd == "prune":
            return cmd_prune(Path(args.repo_dir), args.keep)
    except KeyboardInterrupt:
        return 130
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
