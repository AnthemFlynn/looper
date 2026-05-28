#!/usr/bin/env bash
# Run every milestone acceptance script in order. Exits nonzero on first
# failure. Useful for "is the whole roadmap complete?" checks.
#
# Usage:
#   ./scripts/acceptance-all.sh                 # run v0.1 → v0.8
#   ./scripts/acceptance-all.sh --through v0.3  # run v0.1 → v0.3 only
#
# Honors LOOPER_BIN like the individual scripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
THROUGH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --through)
      THROUGH="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

for v in v0.1 v0.2 v0.3 v0.4 v0.5 v0.6 v0.7 v0.8; do
  echo
  echo "============================================================"
  echo "  $v acceptance"
  echo "============================================================"
  "$SCRIPT_DIR/acceptance-$v.sh"

  if [ -n "$THROUGH" ] && [ "$v" = "$THROUGH" ]; then
    echo
    echo "Stopped after $THROUGH per --through flag."
    exit 0
  fi
done

echo
echo "All milestone acceptance tests passed."
