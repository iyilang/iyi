#!/usr/bin/env bash
# The parser port against the current parser, as canonical S-expressions.
#
# An AST diff needs a canonical form on both sides or it compares formatting.
# `oracle.cr` prints the shape the current parser builds; the port prints the
# same shape from its own tree. Anything the two disagree about is either a
# parse difference or a hole in the port, and both are worth seeing.
set -u
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
export LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib
REPO=/Users/jwaldrip/dev/worktrees/iyi-rebase
cd /tmp/parsport || exit 1

agree=0; differ=0
for f in "$@"; do
  CRYSTAL_CACHE_DIR=/tmp/parsport/c "$REPO/bin/crystal" run --no-color oracle.cr -- "$f" 2>/dev/null \
    | grep -v "Using compiled" > a.txt
  ./parser "$f" > b.txt 2>/dev/null
  if diff -q a.txt b.txt > /dev/null; then
    agree=$((agree + 1))
  else
    differ=$((differ + 1))
    echo "  DIFFERS $(basename "$f")"
    echo "    oracle: $(cut -c1-150 a.txt)"
    echo "    port:   $(cut -c1-150 b.txt)"
  fi
done
echo "  agree $agree, differ $differ"
[ "$differ" -eq 0 ]
