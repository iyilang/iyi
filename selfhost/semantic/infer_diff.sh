#!/usr/bin/env bash
# The iyi-written first inference slice against the current compiler.
#
# The fixture contains four called internal methods and one uncalled one. The
# oracle runs full semantic analysis and reads typed DefInstances; the port
# walks its own AST and performs the same small inference. Exact bytes are the
# gate. An empty answer from either side is a failure, not agreement.
set -u
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
export LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FIXTURE="${1:-$HERE/fixtures/infer.iyi}"
[ -x "$REPO/bin/iyi" ] || { echo "  no $REPO/bin/iyi: run make first"; exit 1; }

IYI_CACHE_DIR="$WORK/iyi" IYI_PATH="$REPO/src:$REPO/selfhost" \
  "$REPO/bin/iyi" build -o "$WORK/infer" "$HERE/infer.iyi" > "$WORK/build.log" 2>&1 || {
  echo "  the port does not build:"
  grep -aoE "Error[^\"]{0,120}" "$WORK/build.log" | head -3 | sed 's|^|    |'
  exit 1
}

CRYSTAL_CACHE_DIR="$WORK/cr" "$REPO/bin/crystal" run --no-color \
  "$HERE/infer_oracle.cr" -- "$FIXTURE" 2>/dev/null \
  | grep -v "Using compiled" > "$WORK/oracle.txt"
"$WORK/infer" "$FIXTURE" > "$WORK/port.txt" 2>/dev/null

[ -s "$WORK/oracle.txt" ] || { echo "  oracle answered nothing"; exit 1; }
[ -s "$WORK/port.txt" ] || { echo "  port answered nothing"; exit 1; }

if diff -q "$WORK/oracle.txt" "$WORK/port.txt" >/dev/null; then
  echo "  agree: $(cat "$WORK/port.txt")"
else
  echo "  DIFFERS $(basename "$FIXTURE")"
  echo "    oracle: $(cat "$WORK/oracle.txt")"
  echo "    port:   $(cat "$WORK/port.txt")"
  exit 1
fi
