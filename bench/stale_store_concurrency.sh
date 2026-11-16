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

# The shared Crystal entrypoint for stale gates. The PowerShell launcher sets
# CRYSTAL_PATH, CRYSTAL_HAS_WRAPPER and library paths before using crystal.exe.
if [[ "${1:-}" == --crystal ]]; then
  shift
  if [[ "$WINDOWS" == 1 ]]; then
    [[ -f "$REPO_DIR/.build/crystal.exe" ]] || {
      echo "Missing $REPO_DIR/.build/crystal.exe" >&2; exit 1;
    }
    exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$REPO_DIR/bin/crystal.ps1" "$@"
  fi
  exec "$REPO_DIR/bin/crystal" "$@"
fi

cd "$REPO_DIR"
BIN="$REPO_DIR/.build/stale_store_concurrency"
[[ "$WINDOWS" == 0 ]] || BIN="$BIN.exe"
if [[ ! -f "$BIN" ]]; then
  echo "Building $BIN..."
  bash "$REPO_DIR/bench/stale_store_concurrency.sh" --crystal build \
    -o "$BIN" "$REPO_DIR/bench/stale_store_concurrency.cr"
fi

TMP_STORE="$(mktemp -d "${TMPDIR:-/tmp}/stale_store_concurrency.XXXXXX")"
[[ "$WINDOWS" == 0 ]] || TMP_STORE="$(cygpath -m "$TMP_STORE")"
trap 'rm -rf "$TMP_STORE"' EXIT

echo "Starting 2 concurrent processes each recording 1000 receipts..."
python3 - "$BIN" "$TMP_STORE" <<'PY'
import subprocess, sys

binary, store = sys.argv[1:]
children = [subprocess.Popen([binary, "run", store, str(n), "1000"]) for n in (1, 2)]
statuses = [child.wait() for child in children]
if statuses != [0, 0]:
    sys.exit(f"concurrent writers failed: {statuses}")
subprocess.run([binary, "verify", store, "2000"], check=True)
PY
echo "Row 21 concurrency test PASSED: 2000 parseable records, seq=2000."
