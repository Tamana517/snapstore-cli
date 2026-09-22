#!/usr/bin/env bash
# Wipe generated state so the next run starts clean.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Remove any temporary repositories or restore targets left by tests
rm -rf /tmp/backup-test-* 2>/dev/null || true
rm -rf "$ROOT"/evaluation/tmp 2>/dev/null || true

# Clean Python caches that sometimes appear
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find . -name "*.pyc" -delete 2>/dev/null || true

echo "Reset complete."
