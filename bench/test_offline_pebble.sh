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
BASH_BIN="${BASH_BIN:-${BASH:-bash}}"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    if command -v cygpath >/dev/null 2>&1; then
      BASH_BIN="$(cygpath -w "$BASH_BIN" 2>/dev/null || echo "$BASH_BIN")"
    fi
    ;;
esac
export BASH_BIN


exec "$PY" "$REPO/proof/test_offline_pebble.py" "$@"
