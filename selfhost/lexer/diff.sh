#!/usr/bin/env bash
# The whole point of the port: the iyi-written lexer against the current one,
# token for token, on real source. A port that compiles proves nothing; a port
# that agrees with its oracle on a corpus is evidence.
#
# Known and deliberate differences, normalised away here rather than hidden:
#   - the current lexer collapses a run of blank lines into one NEWLINE, this
#     slice emits one per line
#   - the current lexer does not emit COMMENT tokens in this mode
#   - string bodies: this slice does not do interpolation yet, so any string
#     with #{...} in it is out of scope and the file is skipped
#   - the `/` in a module path (`module samples/modules`): the current lexer
#     emits DELIMITER_START, treating it as the start of a regex literal, and
#     the parser repairs it downstream. The port emits it as an operator,
#     which is what the language means. Folded to one symbol here so the
#     difference is recorded rather than either side being declared wrong.
set -u
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
export LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib
REPO=/Users/jwaldrip/dev/worktrees/iyi-rebase
cd /tmp/lexport || exit 1

normalise() {
  grep -vE "^(COMMENT|SPACE|NEWLINE)	" "$1" \
    | cut -f1,4 \
    | sed -E 's/^DELIMITER_START	DELIMITER_START$/SLASH	SLASH/; s|^/	/$|SLASH	SLASH|'
}

agree=0; differ=0; skipped=0
for f in "$@"; do
  if grep -q '#{' "$f" 2>/dev/null; then
    skipped=$((skipped + 1))
    continue
  fi
  CRYSTAL_CACHE_DIR=/tmp/lexport/c "$REPO/bin/crystal" run --no-color oracle.cr -- "$f" 2>/dev/null \
    | grep -v "Using compiled" > /tmp/lexport/a.txt
  ./lexer "$f" > /tmp/lexport/b.txt 2>/dev/null
  normalise /tmp/lexport/a.txt > /tmp/lexport/an.txt
  normalise /tmp/lexport/b.txt > /tmp/lexport/bn.txt
  if diff -q /tmp/lexport/an.txt /tmp/lexport/bn.txt > /dev/null; then
    agree=$((agree + 1))
  else
    differ=$((differ + 1))
    echo "  DIFFERS $(basename "$f")  $(diff /tmp/lexport/an.txt /tmp/lexport/bn.txt | head -4 | tr '\n' ' ' | cut -c1-110)"
  fi
done
echo "  agree $agree, differ $differ, skipped $skipped (interpolation, out of this slice)"
[ "$differ" -eq 0 ]
