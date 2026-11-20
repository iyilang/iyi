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

# Git Bash paths are not paths a native Windows compiler can open. Keep
# the executable suffix and both compiler search paths native as well.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    HERE="$(cygpath -m "$HERE")"
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    EXE=.exe
    WINDOWS=1
    ;;
  *) EXE=; WINDOWS=0 ;;
esac
export CRYSTAL_PATH="$REPO/src"
export IYI_PATH="$REPO/src"
export IYI_CONFIG_PATH="$REPO/src"
echo "  host: $(uname -s) $(uname -m)"

[ -x "$REPO/bin/iyi" ] || { echo "  no $REPO/bin/iyi: run make first"; exit 1; }

IYI_CACHE_DIR="$WORK/iyi" \
  "$REPO/bin/iyi" build -o "$WORK/lexer$EXE" "$HERE/lexer.iyi" > "$WORK/build.log" 2>&1 || {
  echo "  the port does not build:"
  grep -aoE "Error[^\"]{0,120}" "$WORK/build.log" | head -3 | sed 's|^|    |'
  exit 1
}

files=("$REPO"/samples/iyi/*.iyi)
[ "$#" -gt 0 ] && files=("$@")

normalise() {
  LC_ALL=C awk -F '\t' '
    $1 == "COMMENT" || $1 == "SPACE" || $1 == "NEWLINE" { next }
    NF != 4 { print "invalid token record at line " NR > "/dev/stderr"; exit 1 }
    ($1 == "DELIMITER_START" && $4 == "DELIMITER_START") || ($1 == "/" && $4 == "/") {
      print "SLASH\tSLASH"
      next
    }
    { print $1 "\t" $4 }
  ' "$1"
}

agree=0
differ=0
skipped=0
for f in "${files[@]}"; do
  [ "$WINDOWS" -eq 0 ] || f="$(cygpath -m "$f")" || exit 1
  CRYSTAL_CACHE_DIR="$WORK/cr" "$REPO/bin/crystal" run --no-color "$HERE/oracle.cr" -- "$f" 2>/dev/null \
    | grep -v "Using compiled" > "$WORK/a.txt"
  if [ ! -s "$WORK/a.txt" ]; then
    echo "  NO ORACLE $(basename "$f")"
    skipped=$((skipped + 1))
    continue
  fi
  # Status and stderr kept rather than dropped: a crash and a wrong
  # token stream otherwise print the same diff of one file against
  # nothing.
  "$WORK/lexer$EXE" "$f" > "$WORK/b.txt" 2> "$WORK/b.err"
  status=$?
  if [ "$status" -ne 0 ] || [ ! -s "$WORK/b.txt" ]; then
    echo "  PORT FAILED $(basename "$f"): exit $status, $(head -2 "$WORK/b.err" | tr '\n' ' ' | cut -c1-150)"
    differ=$((differ + 1))
    continue
  fi
  if ! normalise "$WORK/a.txt" > "$WORK/an.txt" || ! normalise "$WORK/b.txt" > "$WORK/bn.txt"; then
    echo "  NORMALIZATION FAILED $(basename "$f")"
    differ=$((differ + 1))
    continue
  fi
  if diff -q "$WORK/an.txt" "$WORK/bn.txt" > /dev/null; then
    agree=$((agree + 1))
  else
    differ=$((differ + 1))
    echo "  DIFFERS $(basename "$f")  $(diff "$WORK/an.txt" "$WORK/bn.txt" | head -4 | tr '\n' ' ' | cut -c1-110)"
  fi
done
echo "  agree $agree, differ $differ, skipped $skipped"
# Nothing compared is a failure, not a pass.
[ "$differ" -eq 0 ] && [ "$agree" -gt 0 ]
