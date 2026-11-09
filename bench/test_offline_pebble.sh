#!/usr/bin/env bash
# Runs the focused offline Pebble unit tests.
#
#     bash bench/test_offline_pebble.sh
#
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ]; then
  echo "FAIL: python3 or python required to run offline pebble tests" >&2
  exit 1
fi

exec "$PY" "$REPO/proof/test_offline_pebble.py" "$@"
