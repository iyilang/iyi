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

IYI_CACHE_DIR="$WORK/iyi" IYI_PATH="$REPO/src:$REPO/selfhost" \
  "$REPO/bin/iyi" build -o "$WORK/parser" "$HERE/main.iyi" > "$WORK/build.log" 2>&1 || {
  grep -aoE "Error[^\"]{0,120}" "$WORK/build.log" | head -3 | sed 's|^|  |'; exit 1; }

for f in "$@"; do
  CRYSTAL_CACHE_DIR="$WORK/cr" "$REPO/bin/crystal" run --no-color "$HERE/oracle.cr" -- "$f" 2>/dev/null \
    | grep -v "Using compiled" > "$WORK/a.txt"
  "$WORK/parser" "$f" > "$WORK/b.txt" 2>/dev/null
  python3 - "$f" "$WORK/a.txt" "$WORK/b.txt" <<'PY'
import sys, os
name, left, right = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read()
base = os.path.basename(name)
if not left.strip():
    print(f"  {base:22s} no oracle")
    raise SystemExit
if left == right:
    print(f"  {base:22s} agree           100%")
    raise SystemExit
i = next((i for i, (x, y) in enumerate(zip(left, right)) if x != y), min(len(left), len(right)))
# How much of the tree the port got right before it went wrong. Whole-file
# agreement is the only thing that counts as done, but it moves one file at
# a time and hides a slice that fixed nine tenths of twenty files.
print(f"  {base:22s} differs at {i:6d}  {100 * i // len(left):3d}%  {left[i:i+44]}")
PY
done
