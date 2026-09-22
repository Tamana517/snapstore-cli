#!/usr/bin/env bash
# Start / expose the tool so the verifier can invoke it.
# For this task the "runtime" is simply the CLI binary itself.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -d solution ]]; then
  # Prefer whatever the model produced
  if [[ -x solution/backup ]]; then
    exec solution/backup "$@"
  elif [[ -f solution/backup.py ]]; then
    exec python3 solution/backup.py "$@"
  elif [[ -f solution/main.py ]]; then
    exec python3 solution/main.py "$@"
  else
    # last resort: try to find any executable python entry
    entry=$(find solution -name "*.py" | head -1)
    if [[ -n "$entry" ]]; then
      exec python3 "$entry" "$@"
    fi
    echo "error: could not locate entry point in solution/" >&2
    exit 1
  fi
else
  exec python3 reference/backup.py "$@"
fi
