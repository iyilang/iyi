#!/usr/bin/env bash
# The first token the port and the oracle disagree on, per file, with the
# few tokens either side of it. `diff.sh` answers whether a file agrees;
# this answers what to fix next, which is a different question and was
# being done by hand with `diff | head` every time.
set -u
# Homebrew is where this laptop keeps clang and libgc. On a machine
# without it these add nothing and, unlike replacing PATH outright,
# they take nothing away either: a runner that puts its toolchain
# somewhere else keeps it.
if [ -d /opt/homebrew/bin ]; then export PATH="/opt/homebrew/bin:$PATH"; fi
if [ -d /opt/homebrew/opt/bdw-gc/lib ]; then
  export LIBRARY_PATH="/opt/homebrew/opt/bdw-gc/lib:${LIBRARY_PATH:-}"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

IYI_CACHE_DIR="$WORK/iyi" IYI_PATH="$REPO/src" \
  "$REPO/bin/iyi" build -o "$WORK/lexer" "$HERE/lexer.iyi" > "$WORK/build.log" 2>&1 || {
  echo "  the port does not build:"
  grep -aoE "Error[^\"]{0,120}" "$WORK/build.log" | head -3 | sed 's|^|    |'
  exit 1
}

normalise() {
  grep -vE "^(COMMENT|SPACE|NEWLINE)	" "$1" \
    | cut -f1,4 \
    | sed -E 's/^DELIMITER_START	DELIMITER_START$/SLASH	SLASH/; s|^/	/$|SLASH	SLASH|'
}

files=("$REPO"/samples/iyi/*.iyi)
[ "$#" -gt 0 ] && files=("$@")

for f in "${files[@]}"; do
  CRYSTAL_CACHE_DIR="$WORK/cr" "$REPO/bin/crystal" run --no-color "$HERE/oracle.cr" -- "$f" 2>/dev/null \
    | grep -v "Using compiled" > "$WORK/a.txt"
  [ -s "$WORK/a.txt" ] || { printf '%-22s no oracle\n' "$(basename "$f")"; continue; }
  "$WORK/lexer" "$f" > "$WORK/b.txt" 2>/dev/null
  normalise "$WORK/a.txt" > "$WORK/an.txt"
  normalise "$WORK/b.txt" > "$WORK/bn.txt"
  if diff -q "$WORK/an.txt" "$WORK/bn.txt" > /dev/null; then
    printf '%-22s agree\n' "$(basename "$f")"
    continue
  fi
  line=$(diff "$WORK/an.txt" "$WORK/bn.txt" | grep -m1 -oE '^[0-9]+')
  [ -n "${line:-}" ] || line=1
  printf '%-22s first differs at token %s\n' "$(basename "$f")" "$line"
  echo "    oracle: $(sed -n "$((line > 2 ? line - 2 : 1)),$((line + 3))p" "$WORK/an.txt" | tr '\n' ' ' | tr '\t' '=' | cut -c1-130)"
  echo "    port:   $(sed -n "$((line > 2 ? line - 2 : 1)),$((line + 3))p" "$WORK/bn.txt" | tr '\n' ' ' | tr '\t' '=' | cut -c1-130)"
done
