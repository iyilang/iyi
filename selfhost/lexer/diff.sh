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
#
# The repo is found from this script rather than named, the build lands in a
# scratch directory removed on the way out, and with no arguments it runs the
# whole sample corpus. Named, it only ran where it was written; with no
# default it answered "agree 0, differ 0" and exited 0, which is a gate that
# cannot fail.
set -u
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
export LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$REPO/bin/iyi" ] || { echo "  no $REPO/bin/iyi: run make first"; exit 1; }

IYI_CACHE_DIR="$WORK/iyi" IYI_PATH="$REPO/src" \
  "$REPO/bin/iyi" build -o "$WORK/lexer" "$HERE/lexer.iyi" > "$WORK/build.log" 2>&1 || {
  echo "  the port does not build:"
  grep -aoE "Error[^\"]{0,120}" "$WORK/build.log" | head -3 | sed 's|^|    |'
  exit 1
}

files=("$REPO"/samples/iyi/*.iyi)
[ "$#" -gt 0 ] && files=("$@")

normalise() {
  grep -vE "^(COMMENT|SPACE|NEWLINE)	" "$1" \
    | cut -f1,4 \
    | sed -E 's/^DELIMITER_START	DELIMITER_START$/SLASH	SLASH/; s|^/	/$|SLASH	SLASH|'
}

agree=0
differ=0
skipped=0
for f in "${files[@]}"; do
  if grep -q '#{' "$f" 2>/dev/null; then
    skipped=$((skipped + 1))
    continue
  fi
  CRYSTAL_CACHE_DIR="$WORK/cr" "$REPO/bin/crystal" run --no-color "$HERE/oracle.cr" -- "$f" 2>/dev/null \
    | grep -v "Using compiled" > "$WORK/a.txt"
  if [ ! -s "$WORK/a.txt" ]; then
    echo "  NO ORACLE $(basename "$f")"
    continue
  fi
  "$WORK/lexer" "$f" > "$WORK/b.txt" 2>/dev/null
  normalise "$WORK/a.txt" > "$WORK/an.txt"
  normalise "$WORK/b.txt" > "$WORK/bn.txt"
  if diff -q "$WORK/an.txt" "$WORK/bn.txt" > /dev/null; then
    agree=$((agree + 1))
  else
    differ=$((differ + 1))
    echo "  DIFFERS $(basename "$f")  $(diff "$WORK/an.txt" "$WORK/bn.txt" | head -4 | tr '\n' ' ' | cut -c1-110)"
  fi
done
echo "  agree $agree, differ $differ, skipped $skipped (interpolation, out of this slice)"
# Nothing compared is a failure, not a pass.
[ "$differ" -eq 0 ] && [ "$agree" -gt 0 ]
