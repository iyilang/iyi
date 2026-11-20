#!/usr/bin/env bash
# The iyi-written codegen slice against the current compiler, by what the
# programs do rather than by what they emit.
#
# Two independent backends do not write the same LLVM IR. Each fixture
# is built by both, run, and compared by exit status and exact stdout bytes.
# A fixture that exits 0 and prints nothing would pass for free.
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
command -v clang > /dev/null || { echo "  no clang: the emitted IR cannot be assembled"; exit 1; }

IYI_CACHE_DIR="$WORK/iyi" \
  "$REPO/bin/iyi" build -o "$WORK/emit$EXE" "$HERE/emit.iyi" > "$WORK/build.log" 2>&1 || {
  echo "  the port does not build:"
  sed -n '1,20p' "$WORK/build.log"
  exit 1
}

fixtures=("$HERE"/fixtures/*.iyi)
[ "$#" -gt 0 ] && fixtures=("$@")

agree=0
differ=0
for fixture in "${fixtures[@]}"; do
  [ "$WINDOWS" -eq 0 ] || fixture="$(cygpath -m "$fixture")" || exit 1
  name="$(basename "$fixture")"

  # The oracle: the current compiler builds it and it runs.
  IYI_CACHE_DIR="$WORK/iyi" "$REPO/bin/iyi" build -o "$WORK/oracle$EXE" "$fixture" \
    > "$WORK/oracle.log" 2>&1 || {
    echo "  $name: the current compiler does not build it"
    sed -n '1,20p' "$WORK/oracle.log"
    differ=$((differ + 1)); continue
  }
  "$WORK/oracle$EXE" > "$WORK/oracle.out" 2>/dev/null; oracle_status=$?

  # The port: emit IR, assemble it, and run that.
  "$WORK/emit$EXE" "$fixture" > "$WORK/out.ll" 2> "$WORK/emit.err" || {
    echo "  $name: the port did not emit"
    sed -n '1,20p' "$WORK/emit.err"
    differ=$((differ + 1)); continue
  }
  clang_args=(-Wno-override-module)
  if [ "$WINDOWS" -eq 1 ]; then
    # The emitted LLVM IR does not carry the default-library directives
    # produced by a C frontend. Link the same dynamic CRT as iyi itself.
    clang_args+=(--target=x86_64-pc-windows-msvc -lmsvcrt -lucrt -lvcruntime -lkernel32)
  fi
  clang -o "$WORK/port$EXE" "$WORK/out.ll" "${clang_args[@]}" > "$WORK/clang.log" 2>&1 || {
    echo "  $name: the emitted IR does not assemble:"
    sed -n '1,20p' "$WORK/clang.log"
    differ=$((differ + 1)); continue
  }
  "$WORK/port$EXE" > "$WORK/port.out" 2>/dev/null; port_status=$?

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
  if [ ! -f "$HERE/refuses/unheld_shape.iyi" ]; then
    echo "  DIFFERS: required refusal unheld_shape.iyi is missing"
    differ=$((differ + 1))
  fi
  for program in "$HERE"/refuses/*.iyi; do
    [ -e "$program" ] || continue
    name="$(basename "$program")"
    "$WORK/emit$EXE" "$program" > /dev/null 2> "$WORK/refuse.err"; status=$?
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
  if [ "$agree" -lt 14 ]; then
    echo "  DIFFERS: fewer than 14 supported fixtures agreed"
    differ=$((differ + 1))
  fi
fi

echo "  agree $agree, differ $differ, refused $refused"
# Nothing compared is a failure, not a pass.
[ "$differ" -eq 0 ] && [ "$agree" -gt 0 ]
