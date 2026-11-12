#!/usr/bin/env bash
# The iyi-written codegen slice against the current compiler, by what the
# programs do rather than by what they emit.
#
# Every other slice diffs an artifact: a token stream, a tree, a
# declaration, a type. Two independent backends do not write the same
# LLVM IR, and diffing the text would measure spelling. So each fixture
# ends in `__iyi_exit`, both compilers turn it into an executable, and
# this compares the status the two processes exit with. That is the one
# observable both can be asked for without a runtime underneath the port.
#
# A fixture that exits 0 either way would pass for free, so a fixture is
# required to exit non-zero and the gate says so rather than counting it.
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

[ -x "$REPO/bin/iyi" ] || { echo "  no $REPO/bin/iyi: run make first"; exit 1; }
command -v clang > /dev/null || { echo "  no clang: the emitted IR cannot be assembled"; exit 1; }

IYI_CACHE_DIR="$WORK/iyi" IYI_PATH="$REPO/src:$REPO/selfhost" \
  "$REPO/bin/iyi" build -o "$WORK/emit" "$HERE/emit.iyi" > "$WORK/build.log" 2>&1 || {
  echo "  the port does not build:"
  grep -aoE "Error[^\"]{0,120}" "$WORK/build.log" | head -3 | sed 's|^|    |'
  exit 1
}

# The emitter reads the prelude for a program that did not require it,
# the way the compiler does, and it finds it on `IYI_PATH`. Exported
# rather than put in front of each run, because the port is invoked in
# two places below and a fixture that silently found no prelude would
# look like a fixture whose program does not need one.
export IYI_PATH="$REPO/src:$REPO/selfhost"

fixtures=("$HERE"/fixtures/*.iyi)
[ "$#" -gt 0 ] && fixtures=("$@")

agree=0
differ=0
for fixture in "${fixtures[@]}"; do
  name="$(basename "$fixture")"

  # The oracle: the current compiler builds it and it runs.
  IYI_CACHE_DIR="$WORK/iyi" "$REPO/bin/iyi" build -o "$WORK/oracle" "$fixture" \
    > "$WORK/oracle.log" 2>&1 || {
    echo "  $name: the current compiler does not build it"
    differ=$((differ + 1)); continue
  }
  "$WORK/oracle" > "$WORK/oracle.out" 2>/dev/null; oracle_status=$?

  # The port: emit IR, assemble it, and run that.
  "$WORK/emit" "$fixture" > "$WORK/out.ll" 2> "$WORK/emit.err" || {
    echo "  $name: the port did not emit"; differ=$((differ + 1)); continue
  }
  clang -Wno-override-module -o "$WORK/port" "$WORK/out.ll" > "$WORK/clang.log" 2>&1 || {
    echo "  $name: the emitted IR does not assemble:"
    grep -aoE "error:.{0,100}" "$WORK/clang.log" | head -3 | sed 's|^|    |'
    differ=$((differ + 1)); continue
  }
  "$WORK/port" > "$WORK/port.out" 2>/dev/null; port_status=$?

  if [ "$oracle_status" -eq 0 ] && [ ! -s "$WORK/oracle.out" ]; then
    echo "  $name: exits 0 and prints nothing, which any emitter passes"
    differ=$((differ + 1)); continue
  fi
  if [ "$oracle_status" -ne "$port_status" ]; then
    differ=$((differ + 1))
    echo "  DIFFERS $name: the current compiler exits $oracle_status, the port $port_status"
    continue
  fi
  if ! diff -q "$WORK/oracle.out" "$WORK/port.out" > /dev/null; then
    differ=$((differ + 1))
    echo "  DIFFERS $name: same status, different output:"
    diff "$WORK/oracle.out" "$WORK/port.out" | head -4 | sed 's|^|    |'
    continue
  fi
  agree=$((agree + 1))
  if [ -s "$WORK/oracle.out" ]; then
    echo "  $name agrees: exit $oracle_status, $(wc -c < "$WORK/oracle.out" | tr -d ' ') bytes out"
  else
    echo "  $name agrees: exit $oracle_status"
  fi
done

# The other half of the gate: programs this slice is required to
# refuse. A call it cannot answer used to come back as a literal zero,
# which assembles, runs, and exits with a plausible wrong number. That
# is invisible to everything above, because it compares exit status and
# a wrong status is still a status. So each file under `refuses/` has to
# make the emitter exit non-zero and say what it could not do.
#
# Only when the whole corpus was asked for. Naming fixtures on the
# command line is how one is looked at, and that should not drag these in.
refused=0
if [ "$#" -eq 0 ]; then
  for program in "$HERE"/refuses/*.iyi; do
    [ -e "$program" ] || continue
    name="$(basename "$program")"
    "$WORK/emit" "$program" > /dev/null 2> "$WORK/refuse.err"; status=$?
    if [ "$status" -eq 0 ]; then
      echo "  DIFFERS $name: the port emitted it, and it is meant to refuse"
      differ=$((differ + 1)); continue
    fi
    if [ ! -s "$WORK/refuse.err" ]; then
      echo "  DIFFERS $name: refused with exit $status and said nothing"
      differ=$((differ + 1)); continue
    fi
    refused=$((refused + 1))
    echo "  $name refused: exit $status, $(head -1 "$WORK/refuse.err")"
  done
fi

echo "  agree $agree, differ $differ, refused $refused"
# Nothing compared is a failure, not a pass.
[ "$differ" -eq 0 ] && [ "$agree" -gt 0 ]
