#!/usr/bin/env bash
# The iyi-written inference slice against the current compiler.
#
# Each fixture contains called internal methods and at least one uncalled
# one. The oracle runs full semantic analysis and reads typed DefInstances;
# the port walks its own AST and performs the same inference. Exact bytes
# are the gate. An empty answer from either side is a failure, not
# agreement.
#
# With no arguments it runs every fixture, because a slice that grew a
# second fixture and kept checking the first proves only the first.
set -u
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
export LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$REPO/bin/iyi" ] || { echo "  no $REPO/bin/iyi: run make first"; exit 1; }

IYI_CACHE_DIR="$WORK/iyi" IYI_PATH="$REPO/src:$REPO/selfhost" \
  "$REPO/bin/iyi" build -o "$WORK/infer" "$HERE/infer.iyi" > "$WORK/build.log" 2>&1 || {
  echo "  the port does not build:"
  grep -aoE "Error[^\"]{0,120}" "$WORK/build.log" | head -3 | sed 's|^|    |'
  exit 1
}

fixtures=("$HERE"/fixtures/infer*.iyi)
[ "$#" -gt 0 ] && fixtures=("$@")

status=0
for fixture in "${fixtures[@]}"; do
  CRYSTAL_CACHE_DIR="$WORK/cr" "$REPO/bin/crystal" run --no-color \
    "$HERE/infer_oracle.cr" -- "$fixture" 2>/dev/null \
    | grep -v "Using compiled" > "$WORK/oracle.txt"
  "$WORK/infer" "$fixture" > "$WORK/port.txt" 2>/dev/null

  name="$(basename "$fixture")"
  if [ ! -s "$WORK/oracle.txt" ]; then
    echo "  $name: oracle answered nothing"; status=1; continue
  fi
  if [ ! -s "$WORK/port.txt" ]; then
    echo "  $name: port answered nothing"; status=1; continue
  fi
  if diff -q "$WORK/oracle.txt" "$WORK/port.txt" >/dev/null; then
    echo "  $name agrees: $(cat "$WORK/port.txt")"
  else
    echo "  DIFFERS $name"
    echo "    oracle: $(cat "$WORK/oracle.txt")"
    echo "    port:   $(cat "$WORK/port.txt")"
    status=1
  fi
done
exit $status
