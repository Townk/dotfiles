#!/usr/bin/env bash
# Run the test suite (OpenSCAD must be on PATH). The slow tests (minutes each) are
# skipped unless --all is given; run them before merging.
#   bash scripts/test.sh [--all] [pytest args...]
set -euo pipefail
cd "$(dirname "$0")/.."
mark=(-m "not slow")
if [[ "${1:-}" == "--all" ]]; then mark=(); shift; fi
exec uv run pytest -n auto ${mark[@]+"${mark[@]}"} "$@"
