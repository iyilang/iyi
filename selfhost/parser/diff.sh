#!/usr/bin/env bash
# The parser port against the current parser, as canonical S-expressions.
#
# An AST diff needs a canonical form on both sides or it compares formatting.
# `oracle.cr` prints the shape the current parser builds; the port prints the
# same shape from its own tree. Anything the two disagree about is either a
# parse difference or a hole in the port, and both are worth seeing.
#
# The repo is found from this script rather than named, so the harness runs
# from any worktree, and the build lands in a scratch directory that is
# removed on the way out: a differential test that leaves state behind
# eventually passes because of it.
set -u
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
export LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$REPO/bin/iyi" ] || { echo "  no $REPO/bin/iyi: run make first"; exit 1; }

IYI_CACHE_DIR="$WORK/iyi" IYI_PATH="$REPO/src" \
  "$REPO/bin/iyi" build -o "$WORK/parser" "$HERE/parser.iyi" > "$WORK/build.log" 2>&1 || {
  echo "  the port does not build:"
  grep -aoE "Error[^\"]{0,120}" "$WORK/build.log" | head -3 | sed 's|^|    |'
  exit 1
}

# Every fixture, plus whatever else was named on the command line.
files=("$HERE"/fixtures/*.iyi)
[ "$#" -gt 0 ] && files=("$@")

agree=0
differ=0
no_oracle=0
for f in "${files[@]}"; do
  CRYSTAL_CACHE_DIR="$WORK/cr" "$REPO/bin/crystal" run --no-color "$HERE/oracle.cr" -- "$f" 2>/dev/null \
    | grep -v "Using compiled" > "$WORK/a.txt"
  # An oracle that printed nothing has not agreed or disagreed with
  # anything. Counting that as a difference makes the port look worse than
  # it is and hides a file the current parser itself refused.
  if [ ! -s "$WORK/a.txt" ]; then
    no_oracle=$((no_oracle + 1))
    echo "  NO ORACLE $(basename "$f")"
    continue
  fi
  "$WORK/parser" "$f" > "$WORK/b.txt" 2>/dev/null
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
[ "$no_oracle" -eq 0 ] || echo "  (a file with no oracle is the current parser refusing it, not the port)"
[ "$differ" -eq 0 ]
