#!/usr/bin/env bash
# Prepare the model-generated (or reference) solution for execution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# If a model solution exists under solution/, prefer it.
# Otherwise fall back to the reference implementation.
if [[ -d solution ]]; then
  echo "Building model solution..."
  # Expect the model to produce a runnable entry point.
  # Common patterns: main.py, backup.py, or a small Makefile.
  if [[ -f solution/Makefile ]]; then
    make -C solution
  elif [[ -f solution/setup.py ]] || [[ -f solution/pyproject.toml ]]; then
    pip install -e solution --quiet
  fi
  # Ensure the entry point is executable if it is a script
  find solution -name "*.py" -exec chmod +x {} +
else
  echo "No model solution found – using reference."
  chmod +x reference/backup.py
fi

echo "Build complete."
