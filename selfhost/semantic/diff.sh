#!/usr/bin/env bash
# The declaration pass against the current compiler's, as one line per file.
#
# `oracle.cr` runs the real top-level semantic pass and prints what the
# file declared. `declare.iyi` walks the port's own tree and prints the
# same. A port that answers the same for every file is evidence; a port
# that answers for none of them and is never run is not.
#
# Three of the samples have no oracle: `collections`, `immutable` and
# `webapp` declare types whose bodies name something an import brings,
# and this pass resolves no imports. They are reported as having no
# oracle rather than skipped, so the number says what it is measuring.
set -u
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
export LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$REPO/bin/iyi" ] || { echo "  no $REPO/bin/iyi: run make first"; exit 1; }

IYI_CACHE_DIR="$WORK/iyi" IYI_PATH="$REPO/src:$REPO/selfhost" \
  "$REPO/bin/iyi" build -o "$WORK/declare" "$HERE/declare.iyi" > "$WORK/build.log" 2>&1 || {
  echo "  the port does not build:"
  grep -aoE "Error[^\"]{0,120}" "$WORK/build.log" | head -3 | sed 's|^|    |'
  exit 1
}

files=("$REPO"/samples/iyi/*.iyi)
[ "$#" -gt 0 ] && files=("$@")

agree=0
differ=0
no_oracle=0
for f in "${files[@]}"; do
  CRYSTAL_CACHE_DIR="$WORK/cr" "$REPO/bin/crystal" run --no-color "$HERE/oracle.cr" -- "$f" 2>/dev/null \
    | grep -v "Using compiled" > "$WORK/a.txt"
  # An empty answer is the pass refusing the file, not a file that
  # declares nothing: every sample declares something.
  if [ ! -s "$WORK/a.txt" ] || [ -z "$(tr -d '[:space:]' < "$WORK/a.txt")" ]; then
    no_oracle=$((no_oracle + 1))
    echo "  NO ORACLE $(basename "$f")"
    continue
  fi
  "$WORK/declare" "$f" > "$WORK/b.txt" 2>/dev/null
  if diff -q "$WORK/a.txt" "$WORK/b.txt" > /dev/null; then
    agree=$((agree + 1))
  else
    differ=$((differ + 1))
    echo "  DIFFERS $(basename "$f")"
    echo "    oracle: $(cut -c1-150 "$WORK/a.txt")"
    echo "    port:   $(cut -c1-150 "$WORK/b.txt")"
  fi
done
echo "  agree $agree, differ $differ, no oracle $no_oracle"
[ "$differ" -eq 0 ]
