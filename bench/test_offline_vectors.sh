#!/usr/bin/env bash
# Runs the focused offline vector intake tests.
#
#     bash bench/test_offline_vectors.sh
#
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    ;;
esac
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ]; then
  echo "FAIL: python3 or python required to run offline vector tests" >&2
  exit 1
fi

BASH_BIN="${BASH_BIN:-${BASH:-bash}}"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    if command -v cygpath >/dev/null 2>&1; then
      BASH_BIN="$(cygpath -w "$BASH_BIN" 2>/dev/null || cygpath -m "$BASH_BIN" 2>/dev/null || echo "$BASH_BIN")"
    fi
    ;;
esac
export BASH_BIN

if [ $# -gt 0 ]; then
  (cd "$REPO" && exec "$PY" -B -m unittest "$@")
else
  (cd "$REPO" && exec "$PY" -B -m unittest proof.test_offline_vectors -v)
fi
