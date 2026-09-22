# Incremental Snapshot Backup Tool

Build a command-line tool that creates and manages incremental, content-addressable snapshots of a directory tree.

The tool must work entirely on the local filesystem. No network services, no external databases, and no third-party backup libraries are allowed.

## Commands

Your tool must expose the following subcommands (exact names and argument order matter):

```
backup  <source_dir> <repo_dir>
restore <repo_dir> <snapshot_id> <dest_dir>
list    <repo_dir>
verify  <repo_dir> [snapshot_id]
prune   <repo_dir> --keep <N>
```

- `backup` creates a new snapshot of `source_dir` inside `repo_dir` and prints the new snapshot ID to stdout.
- `restore` materializes the given snapshot into `dest_dir` (creating it if needed).
- `list` prints one snapshot ID per line (newest last is fine).
- `verify` checks integrity of the repository or a single snapshot. Exit 0 on success, non-zero on any problem.
- `prune --keep N` retains the N most recent snapshots and removes everything else that is no longer referenced. Exit 0 on success.

## Required Behavior

### Snapshot Consistency
A snapshot must represent a consistent point-in-time view of the source tree.
If files in the source are modified, truncated, or deleted while the backup is running, the finished snapshot must still be internally consistent (no torn or partially-updated file contents).

### Hard Links
When the source contains hard-linked files (multiple paths sharing the same inode), the restored tree must recreate those hard links. Restoring two paths that were hard-linked must result in the same inode number in the destination.

### Sparse Files
Sparse files must be restored as sparse. Logical size and the presence of holes must be preserved; the restored file must not consume more disk blocks than necessary.

### Atomic Publication
A snapshot is either fully visible in the repository or not visible at all.
If the backup process is killed (SIGKILL) part-way through, the repository must not expose a partial or corrupted snapshot. Subsequent `list` and `restore` operations must behave as if the interrupted backup never happened (or the tool may resume it safely; either approach is acceptable as long as the repository stays consistent).

### Content Deduplication
Identical file content must be stored only once inside the repository. Different snapshots that share content must share the underlying storage objects.

### Crash Safety
After an abrupt termination, the repository must remain usable. `list`, `verify`, `restore`, and later `backup` / `prune` operations must continue to work correctly.

### Pruning
`prune --keep N` must never delete storage objects that are still referenced by any of the retained snapshots. After pruning, every remaining snapshot must restore to exactly the same tree it produced before the prune.

### Verification
`verify` (and `verify <snapshot_id>`) must detect missing or altered content objects. It must exit non-zero when corruption is present.

### Restore Fidelity
A restored tree must match the original snapshot with respect to:
- file contents
- hard-link relationships
- sparsity
- regular file / directory / symlink structure

Permissions, ownership, and timestamps may be preserved if convenient, but are not required for correctness scoring.

## Error Handling
- Non-existent source or repository paths, permission errors, and malformed arguments must produce a non-zero exit code and a clear message on stderr.
- The tool must never leave the repository in a permanently corrupted state under normal or crash-induced failure.


### Concurrent Modification
The source directory may be modified by other processes while a backup is running.
The finished snapshot must still be internally consistent (no torn or partially-updated file contents).

### Crash Injection
If the backup process is terminated with SIGKILL part-way through, the repository must remain usable.
`list`, `verify`, and subsequent `backup` operations must continue to work. A partial snapshot must not become visible (or the tool may recover cleanly).

## Constraints
- The implementation must be self-contained. Do not rely on external backup tools (rsync, restic, borg, etc.) or on system services.
- All state lives inside the repository directory you are given.
- The tool will be invoked repeatedly against the same repository; state must persist correctly across invocations.

## Deliverable
A working program (any mainstream language) that can be built and executed via the provided lifecycle scripts. The exact binary name or entry point will be configured in the build/start scripts; focus on correct observable behavior.
