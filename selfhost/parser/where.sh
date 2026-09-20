#!/usr/bin/env bash
# Where the port first disagrees with the oracle, rather than that it does.
#
# Two S-expressions that share a long prefix diff as two whole lines, which
# says nothing. This prints the first differing column and the text around it
# on both sides, which is the thing a port is actually debugged from.
set -u
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
export LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

IYI_CACHE_DIR="$WORK/iyi" IYI_PATH="$REPO/src" \
  "$REPO/bin/iyi" build -o "$WORK/parser" "$HERE/parser.iyi" > "$WORK/build.log" 2>&1 || {
  grep -aoE "Error[^\"]{0,120}" "$WORK/build.log" | head -3 | sed 's|^|  |'; exit 1; }

for f in "$@"; do
  CRYSTAL_CACHE_DIR="$WORK/cr" "$REPO/bin/crystal" run --no-color "$HERE/oracle.cr" -- "$f" 2>/dev/null \
    | grep -v "Using compiled" > "$WORK/a.txt"
  "$WORK/parser" "$f" > "$WORK/b.txt" 2>/dev/null
  python3 - "$f" "$WORK/a.txt" "$WORK/b.txt" <<'PY'
import sys
name, left, right = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read()
if left == right:
    print(f"  {name}: agree")
    raise SystemExit
i = next((i for i, (x, y) in enumerate(zip(left, right)) if x != y), min(len(left), len(right)))
start = max(0, i - 60)
print(f"  {name}: first differs at column {i}")
print(f"    oracle: ...{left[start:i]}<<{left[i:i+50]}")
print(f"    port:   ...{right[start:i]}<<{right[i:i+50]}")
PY
done
