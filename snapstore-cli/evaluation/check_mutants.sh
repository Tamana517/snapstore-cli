#!/usr/bin/env bash
# Confirm that each mutant is caught by the verifier.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== Mutant checks ==="

catch_count=0
total=0

for mdir in mutants/m*; do
  name=$(basename "$mdir")
  total=$((total + 1))
  echo
  echo "--- Testing mutant: $name ---"

  # Temporarily point start.sh at the mutant by copying into a solution/ dir
  rm -rf solution
  mkdir -p solution
  cp "$mdir/backup.py" solution/backup.py
  chmod +x solution/backup.py

  if bash evaluation/run_tests.sh >/tmp/mutant-out.txt 2>&1; then
    echo "UNEXPECTED: mutant $name passed the suite (should have failed)"
    cat /tmp/mutant-out.txt
  else
    echo "CAUGHT: mutant $name failed as expected"
    catch_count=$((catch_count + 1))
  fi
done

rm -rf solution

echo
echo "Mutants caught: $catch_count / $total"
if [[ $catch_count -eq $total ]]; then
  echo "All mutants detected."
  exit 0
else
  echo "Some mutants were not detected."
  exit 1
fi
