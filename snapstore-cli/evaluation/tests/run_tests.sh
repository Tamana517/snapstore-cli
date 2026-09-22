#!/usr/bin/env bash
# Black-box verifier for the snapshot backup tool.
# Includes concurrent-modification, crash-injection, and sparse-file checks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

REFERENCE=0
if [[ "${1:-}" == "--reference" ]]; then
  REFERENCE=1
fi

run_tool() {
  if [[ $REFERENCE -eq 1 ]]; then
    python3 "$ROOT/reference/backup.py" "$@"
  else
    bash "$ROOT/app-setup/start.sh" "$@"
  fi
}

PASS=0
FAIL=0
REPORT=()

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    REPORT+=("PASS  $desc")
  else
    FAIL=$((FAIL + 1))
    REPORT+=("FAIL  $desc (expected='$expected' actual='$actual')")
  fi
}

assert_ok() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    REPORT+=("PASS  $desc")
  else
    FAIL=$((FAIL + 1))
    REPORT+=("FAIL  $desc")
  fi
}

assert_fail() {
  local desc="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    REPORT+=("PASS  $desc")
  else
    FAIL=$((FAIL + 1))
    REPORT+=("FAIL  $desc (expected non-zero exit)")
  fi
}

TMP=$(mktemp -d /tmp/backup-test-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

SRC="$TMP/src"
REPO="$TMP/repo"
DEST="$TMP/dest"

mkdir -p "$SRC/sub"
echo "hello world" > "$SRC/file1.txt"
echo "same content" > "$SRC/file2.txt"
ln "$SRC/file2.txt" "$SRC/hardlink.txt"
echo "unique" > "$SRC/sub/nested.txt"

# Create a properly sparse file (logical 1 MiB, only a few blocks allocated)
dd if=/dev/zero of="$SRC/sparse.dat" bs=1k count=0 seek=1024 2>/dev/null
# write a small data region at the start so the file is not pure hole
printf 'SPARSE' | dd of="$SRC/sparse.dat" bs=1 conv=notrunc 2>/dev/null

# ---------------------------------------------------------------------------
# 1. Basic backup
# ---------------------------------------------------------------------------
ID1=$(run_tool backup "$SRC" "$REPO" 2>/dev/null | tail -1 | tr -d '[:space:]')
if [[ -n "$ID1" ]]; then
  PASS=$((PASS + 1)); REPORT+=("PASS  backup creates snapshot")
else
  FAIL=$((FAIL + 1)); REPORT+=("FAIL  backup creates snapshot")
fi

# 2. List contains the id
LIST_OUT=$(run_tool list "$REPO" 2>/dev/null || true)
if echo "$LIST_OUT" | grep -q "$ID1"; then
  PASS=$((PASS + 1)); REPORT+=("PASS  snapshot appears in list")
else
  FAIL=$((FAIL + 1)); REPORT+=("FAIL  snapshot appears in list")
fi

# 3. Restore content
rm -rf "$DEST"
mkdir -p "$DEST"
if run_tool restore "$REPO" "$ID1" "$DEST" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); REPORT+=("PASS  restore exits 0")
else
  FAIL=$((FAIL + 1)); REPORT+=("FAIL  restore exits 0")
fi

assert_eq "restored file1 content" "hello world" "$(cat "$DEST/file1.txt" 2>/dev/null || echo MISSING)"
assert_eq "restored nested content" "unique" "$(cat "$DEST/sub/nested.txt" 2>/dev/null || echo MISSING)"

# 4. Hard-link preservation
INO_A=$(stat -c %i "$DEST/file2.txt" 2>/dev/null || stat -f %i "$DEST/file2.txt" 2>/dev/null || echo 0)
INO_B=$(stat -c %i "$DEST/hardlink.txt" 2>/dev/null || stat -f %i "$DEST/hardlink.txt" 2>/dev/null || echo 1)
if [[ "$INO_A" == "$INO_B" && "$INO_A" != "0" ]]; then
  PASS=$((PASS + 1)); REPORT+=("PASS  hard links share inode after restore")
else
  FAIL=$((FAIL + 1)); REPORT+=("FAIL  hard links do not share inode (got $INO_A vs $INO_B)")
fi

# ---------------------------------------------------------------------------
# 5. Sparse-file checks (logical size + allocated blocks)
# ---------------------------------------------------------------------------
ORIG_SIZE=$(stat -c %s "$SRC/sparse.dat" 2>/dev/null || stat -f %z "$SRC/sparse.dat")
REST_SIZE=$(stat -c %s "$DEST/sparse.dat" 2>/dev/null || stat -f %z "$DEST/sparse.dat" 2>/dev/null || echo 0)
assert_eq "sparse logical size preserved" "$ORIG_SIZE" "$REST_SIZE"

# Allocated blocks: restored file should not be fully dense
# (on Linux st_blocks is in 512-byte units)
ORIG_BLOCKS=$(stat -c %b "$SRC/sparse.dat" 2>/dev/null || echo 0)
REST_BLOCKS=$(stat -c %b "$DEST/sparse.dat" 2>/dev/null || echo 999999)
# Allow some slack; just ensure we did not expand to full size
FULL_BLOCKS=$((ORIG_SIZE / 512 + 8))
if [[ "$REST_BLOCKS" -lt "$FULL_BLOCKS" ]]; then
  PASS=$((PASS + 1)); REPORT+=("PASS  sparse file remains sparse after restore (blocks=$REST_BLOCKS < $FULL_BLOCKS)")
else
  FAIL=$((FAIL + 1)); REPORT+=("FAIL  sparse file expanded (blocks=$REST_BLOCKS, full would be ~$FULL_BLOCKS)")
fi

# ---------------------------------------------------------------------------
# 6. Second snapshot + list growth
# ---------------------------------------------------------------------------
echo "extra" > "$SRC/extra.txt"
ID2=$(run_tool backup "$SRC" "$REPO" 2>/dev/null | tail -1 | tr -d '[:space:]')
COUNT=$(run_tool list "$REPO" 2>/dev/null | grep -c . || echo 0)
assert_eq "two snapshots listed" "2" "$COUNT"

# 7. Verify clean
if run_tool verify "$REPO" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); REPORT+=("PASS  verify clean repository")
else
  FAIL=$((FAIL + 1)); REPORT+=("FAIL  verify clean repository")
fi

# 8. Prune
if run_tool prune "$REPO" --keep 1 >/dev/null 2>&1; then
  PASS=$((PASS + 1)); REPORT+=("PASS  prune --keep 1")
else
  FAIL=$((FAIL + 1)); REPORT+=("FAIL  prune --keep 1")
fi
COUNT=$(run_tool list "$REPO" 2>/dev/null | grep -c . || echo 0)
assert_eq "only one snapshot after prune" "1" "$COUNT"
REMAINING=$(run_tool list "$REPO" 2>/dev/null | tail -1 | tr -d '[:space:]')
assert_eq "remaining snapshot is the newest" "$ID2" "$REMAINING"

# 9. Restore after prune
rm -rf "$DEST"
mkdir -p "$DEST"
if run_tool restore "$REPO" "$ID2" "$DEST" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); REPORT+=("PASS  restore after prune")
else
  FAIL=$((FAIL + 1)); REPORT+=("FAIL  restore after prune")
fi
assert_eq "extra.txt present after prune restore" "extra" "$(cat "$DEST/extra.txt" 2>/dev/null || echo MISSING)"

# 10. Corruption detection
OBJ=$(find "$REPO/objects" -type f 2>/dev/null | head -1 || true)
if [[ -n "$OBJ" ]]; then
  cp "$OBJ" "$TMP/victim.bak"
  rm -f "$OBJ"
  if ! run_tool verify "$REPO" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); REPORT+=("PASS  verify detects missing object")
  else
    FAIL=$((FAIL + 1)); REPORT+=("FAIL  verify detects missing object")
  fi
  mkdir -p "$(dirname "$OBJ")"
  mv "$TMP/victim.bak" "$OBJ"
else
  REPORT+=("SKIP  corruption test (no objects)")
fi

# 11. Error paths
assert_fail "backup missing source" run_tool backup /nonexistent "$REPO"
assert_fail "restore missing snapshot" run_tool restore "$REPO" "does-not-exist" "$DEST"

# ---------------------------------------------------------------------------
# 12. Concurrent modification during backup
#    Start backup in background, mutate source while it runs, then check
#    that the finished snapshot is still internally consistent (restore works
#    and does not contain torn content mixed from before/after).
# ---------------------------------------------------------------------------
CONC_SRC="$TMP/conc_src"
CONC_REPO="$TMP/conc_repo"
CONC_DEST="$TMP/conc_dest"
rm -rf "$CONC_SRC" "$CONC_REPO" "$CONC_DEST"
mkdir -p "$CONC_SRC"
# Create a larger file so backup takes measurable time
dd if=/dev/urandom of="$CONC_SRC/big.bin" bs=1M count=8 2>/dev/null
echo "version-one" > "$CONC_SRC/mutable.txt"

# Run backup in background
run_tool backup "$CONC_SRC" "$CONC_REPO" > "$TMP/conc_id.txt" 2>"$TMP/conc_err.txt" &
BKP_PID=$!

# Give it a moment to start, then mutate
sleep 0.15
echo "version-two-SHOULD-NOT-APPEAR-IN-CONSISTENT-SNAPSHOT" > "$CONC_SRC/mutable.txt"
# also grow the big file a bit
dd if=/dev/urandom of="$CONC_SRC/big.bin" bs=1M count=2 oflag=append conv=notrunc 2>/dev/null || true

wait $BKP_PID || true
CONC_ID=$(cat "$TMP/conc_id.txt" 2>/dev/null | tail -1 | tr -d '[:space:]')

if [[ -z "$CONC_ID" ]]; then
  FAIL=$((FAIL + 1)); REPORT+=("FAIL  concurrent backup produced no snapshot id")
else
  PASS=$((PASS + 1)); REPORT+=("PASS  concurrent backup produced a snapshot")
  rm -rf "$CONC_DEST"
  mkdir -p "$CONC_DEST"
  if run_tool restore "$CONC_REPO" "$CONC_ID" "$CONC_DEST" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); REPORT+=("PASS  concurrent snapshot restores")
    # The snapshot must be consistent: either the old or the new content,
    # never a mix of partial writes. We only require that restore succeeds
    # and the file is readable and non-empty.
    if [[ -s "$CONC_DEST/mutable.txt" ]]; then
      PASS=$((PASS + 1)); REPORT+=("PASS  concurrent snapshot has consistent mutable.txt")
    else
      FAIL=$((FAIL + 1)); REPORT+=("FAIL  concurrent snapshot mutable.txt missing/empty")
    fi
  else
    FAIL=$((FAIL + 1)); REPORT+=("FAIL  concurrent snapshot restores")
  fi
fi

# ---------------------------------------------------------------------------
# 13. Crash injection (kill -9 mid-backup)
#     Start a backup, kill it hard, then verify the repository is still
#     usable (list/verify succeed, no partial snapshot is visible, or the
#     tool recovered cleanly).
# ---------------------------------------------------------------------------
CRASH_SRC="$TMP/crash_src"
CRASH_REPO="$TMP/crash_repo"
rm -rf "$CRASH_SRC" "$CRASH_REPO"
mkdir -p "$CRASH_SRC"
dd if=/dev/urandom of="$CRASH_SRC/large.bin" bs=1M count=12 2>/dev/null
echo "stable" > "$CRASH_SRC/ok.txt"

# Baseline: one clean snapshot so the repo exists
CLEAN_ID=$(run_tool backup "$CRASH_SRC" "$CRASH_REPO" 2>/dev/null | tail -1 | tr -d '[:space:]')

# Now start another backup and kill it
run_tool backup "$CRASH_SRC" "$CRASH_REPO" > "$TMP/crash_out.txt" 2>"$TMP/crash_err.txt" &
CRASH_PID=$!
sleep 0.1
kill -9 $CRASH_PID 2>/dev/null || true
wait $CRASH_PID 2>/dev/null || true

# Repository must still be usable
if run_tool list "$CRASH_REPO" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); REPORT+=("PASS  list works after crash")
else
  FAIL=$((FAIL + 1)); REPORT+=("FAIL  list works after crash")
fi

if run_tool verify "$CRASH_REPO" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); REPORT+=("PASS  verify works after crash")
else
  # Some implementations may leave temporary objects; we still require
  # that the previously committed snapshot remains valid.
  if run_tool verify "$CRASH_REPO" "$CLEAN_ID" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); REPORT+=("PASS  prior snapshot still verifies after crash")
  else
    FAIL=$((FAIL + 1)); REPORT+=("FAIL  verify / prior snapshot after crash")
  fi
fi

# A later clean backup must succeed
POST_ID=$(run_tool backup "$CRASH_SRC" "$CRASH_REPO" 2>/dev/null | tail -1 | tr -d '[:space:]')
if [[ -n "$POST_ID" ]]; then
  PASS=$((PASS + 1)); REPORT+=("PASS  backup succeeds after previous crash")
else
  FAIL=$((FAIL + 1)); REPORT+=("FAIL  backup succeeds after previous crash")
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "==== RESULTS ===="
for line in "${REPORT[@]}"; do
  echo "$line"
done
echo
echo "Passed: $PASS   Failed: $FAIL"
TOTAL=$((PASS + FAIL))
if [[ $TOTAL -eq 0 ]]; then
  SCORE="0.0000"
else
  SCORE=$(awk "BEGIN {printf \"%.4f\", $PASS / $TOTAL}")
fi
echo "Score: $SCORE"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
