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

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    HERE="$(cygpath -m "$HERE")"
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    EXE=.exe
    PATH_SEP=';'
    WINDOWS=1
    ;;
  *) EXE=; PATH_SEP=:; WINDOWS=0 ;;
esac
export CRYSTAL_PATH="$REPO/src"
export IYI_PATH="$REPO/src${PATH_SEP}$REPO/selfhost"
export IYI_CONFIG_PATH="$REPO/src"
echo "  host: $(uname -s) $(uname -m)"

[ -x "$REPO/bin/iyi" ] || { echo "  no $REPO/bin/iyi: run make first"; exit 1; }

IYI_CACHE_DIR="$WORK/iyi" \
  "$REPO/bin/iyi" build -o "$WORK/infer$EXE" "$HERE/infer.iyi" > "$WORK/build.log" 2>&1 || {
  echo "  the port does not build:"
  grep -aoE "Error[^\"]{0,120}" "$WORK/build.log" | head -3 | sed 's|^|    |'
  exit 1
}

fixtures=("$HERE"/fixtures/infer*.iyi)
[ "$#" -gt 0 ] && fixtures=("$@")

status=0
for fixture in "${fixtures[@]}"; do
  [ "$WINDOWS" -eq 0 ] || fixture="$(cygpath -m "$fixture")" || exit 1
  oracle_status=0
  CRYSTAL_CACHE_DIR="$WORK/cr" "$REPO/bin/crystal" run --no-color \
    "$HERE/infer_oracle.cr" -- "$fixture" > "$WORK/oracle.raw" 2> "$WORK/oracle.err" || oracle_status=$?
  grep -v "Using compiled" "$WORK/oracle.raw" > "$WORK/oracle.txt"
  # Keep both commands' status and stderr. Partial output from a failed
  # analysis is not an oracle, even when the bytes happen to agree.
  "$WORK/infer$EXE" "$fixture" > "$WORK/port.txt" 2> "$WORK/port.err"
  port_status=$?

  name="$(basename "$fixture")"
  if [ "$oracle_status" -ne 0 ] || [ ! -s "$WORK/oracle.txt" ]; then
    echo "  $name: oracle failed or answered nothing, exiting $oracle_status"
    cat "$WORK/oracle.err"
    status=1; continue
  fi
  if [ "$port_status" -ne 0 ] || [ ! -s "$WORK/port.txt" ]; then
    echo "  $name: port failed or answered nothing, exiting $port_status"
    cat "$WORK/port.err"
    status=1; continue
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
