#!/usr/bin/env bash
# Thin wrapper – keeps package.json scripts working after moving tests into tests/
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec bash "$ROOT/tests/run_tests.sh" "$@"
