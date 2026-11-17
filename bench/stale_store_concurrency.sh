#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    WINDOWS=1
    REPO_DIR="$(cygpath -m "$REPO_DIR")"
    ;;
  *) WINDOWS=0 ;;
esac

# The shared Crystal entrypoint for stale gates. On Windows bin/crystal.ps1
# only sets CRYSTAL_PATH, CRYSTAL_HAS_WRAPPER and the library path before it
# runs .build/crystal.exe; called through `powershell -File` it also reads
# `-o` as an abbreviation of -OutVariable and -OutBuffer and refuses the
# build, so the same environment is set here and the executable is run.
if [[ "${1:-}" == --crystal ]]; then
  shift
  if [[ "$WINDOWS" == 1 ]]; then
    [[ -f "$REPO_DIR/.build/crystal.exe" ]] || {
      echo "Missing $REPO_DIR/.build/crystal.exe" >&2; exit 1;
    }
    exec env CRYSTAL_PATH="${CRYSTAL_PATH:-lib;$REPO_DIR/src}" CRYSTAL_HAS_WRAPPER=true \
      CRYSTAL_CONFIG_LIBRARY_PATH="${CRYSTAL_CONFIG_LIBRARY_PATH:-${CRYSTAL_LIBRARY_PATH:-}}" \
      "$REPO_DIR/.build/crystal.exe" "$@"
  fi
  exec "$REPO_DIR/bin/crystal" "$@"
fi

# The interpreter that runs, not `python3` by name: on a runner without
# setup-python that name can be the Store's stub, which answers nothing.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
[[ -n "$PY" ]] || { echo "python3 required for the store concurrency gate" >&2; exit 1; }

cd "$REPO_DIR"
BIN="$REPO_DIR/.build/stale_store_concurrency"
[[ "$WINDOWS" == 0 ]] || BIN="$BIN.exe"
echo "Building $BIN from this checkout..."
"$BASH" "$REPO_DIR/bench/stale_store_concurrency.sh" --crystal build \
  -o "$BIN" "$REPO_DIR/bench/stale_store_concurrency.cr"

TMP_STORE="$(mktemp -d "${TMPDIR:-/tmp}/stale_store_concurrency.XXXXXX")"
[[ "$WINDOWS" == 0 ]] || TMP_STORE="$(cygpath -m "$TMP_STORE")"
trap 'rm -rf "$TMP_STORE"' EXIT

echo "Starting 2 concurrent processes each recording 1000 receipts..."
"$PY" - "$BIN" "$TMP_STORE" <<'PY'
import subprocess, sys

binary, store = sys.argv[1:]
children = [subprocess.Popen([binary, "run", store, str(n), "1000"]) for n in (1, 2)]
statuses = [child.wait() for child in children]
if statuses != [0, 0]:
    sys.exit(f"concurrent writers failed: {statuses}")
subprocess.run([binary, "verify", store, "2000"], check=True)
PY
echo "Row 21 concurrency test PASSED: 2000 parseable records, seq=2000."
