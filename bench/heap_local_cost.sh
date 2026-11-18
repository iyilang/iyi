#!/usr/bin/env bash
# heap22 slices S1 and S1b, measured: bench/heap_local_cost.iyi built
# --release without partitions, with them at the tree's granule (1 KiB),
# and with a copy of the runtime at S1's 4 KiB granule; each runs the
# idle test (as is, and collecting at every park) and the pause test.
# Prints the programs' lines; fails if a program fails, if a build or run
# could not be carried out at all, or if a row's lines do not name the
# partitions setting it was built with.
#
#   bash bench/heap_local_cost.sh [UNITS [WORKERS [PAUSE_UNITS PAUSE_ROUNDS]]]
#
# Defaults: 10,000 idle units on 4 workers, 64 units of 400 requests.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
UNITS="${1:-10000}"
WORKERS="${2:-4}"
PUNITS="${3:-64}"
PROUNDS="${4:-400}"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
  *) PSEP=':' ;;
esac

trap 'rm -rf "$WORK"' EXIT
status=0

# A build or run the shell itself could not carry out (exit 126/127,
# "Permission denied", "command not found") is a failure of this script,
# named as such, never a row quietly missing.
shell_refused() { # code file
  [ "$1" -eq 126 ] || [ "$1" -eq 127 ] || grep -qE 'Permission denied|command not found' "$2"
}

# Each build names its flags, `IYI_OPTS` left out: under a gate's
# `-Dheap_partitions` the flag-off row was built with the flag.
build() { # name flags [iyi-path]
  local name="$1" flags="$2" path="${3:-}"
  local env=()
  [ -n "$path" ] && env=("IYI_PATH=$path")
  # shellcheck disable=SC2086
  env -u IYI_OPTS ${env[@]+"${env[@]}"} "$IYI" build --release $flags -o "$WORK/$name" "$REPO/bench/heap_local_cost.iyi" \
    >"$WORK/$name.build.log" 2>&1
  local code=$?
  if shell_refused "$code" "$WORK/$name.build.log"; then
    echo "FAIL: $name: the build could not be run (exit $code)"
    sed -n '1,16p' "$WORK/$name.build.log"
    status=1
    return 1
  fi
  if [ "$code" -ne 0 ]; then
    echo "$name: build failed"
    sed -n '1,16p' "$WORK/$name.build.log"
    status=1
    return 1
  fi
  if [ ! -f "$WORK/$name" ] || [ ! -x "$WORK/$name" ]; then
    echo "FAIL: $name: the build left no executable at $WORK/$name"
    status=1
    return 1
  fi
}

# run NAME PARTITIONS ARGS...: every line the row prints must say
# `partitions=PARTITIONS`, the build it was meant to measure.
run() {
  local name="$1" want="$2"
  shift 2
  timeout 600 "$WORK/$name" "$@" >"$WORK/$name.out" 2>&1
  local code=$?
  cat "$WORK/$name.out"
  if shell_refused "$code" "$WORK/$name.out"; then
    echo "FAIL: $name $*: the program could not be run (exit $code)"
    status=1
  elif [ "$code" -ne 0 ]; then
    echo "$name $*: failed"
    status=1
  elif ! grep -q " partitions=" "$WORK/$name.out" || grep " partitions=" "$WORK/$name.out" | grep -qv " partitions=$want "; then
    echo "FAIL: $name $*: a line does not say partitions=$want"
    status=1
  fi
}

# The runtime copy at S1's granule, in a directory of its own: under
# `$WORK/g12` it was the path the g12 build wrote to, and every g12 row
# failed to run ("Permission denied").
mkdir -p "$WORK/g12rt/iyi"
cp -R "$REPO/src/iyi/." "$WORK/g12rt/iyi/"
awk '{ if (sub(/^  GRANULE_SHIFT = 10_u64$/, "  GRANULE_SHIFT = 12_u64")) found = 1; print } END { if (!found) exit 3 }' \
  "$REPO/src/iyi/heap_partition.iyi" > "$WORK/g12rt/iyi/heap_partition.iyi" || { echo "the granule is not 1 KiB in this tree"; exit 1; }

build off "" && { run off off idle "$UNITS" "$WORKERS"; run off off pause "$PUNITS" "$PROUNDS" "$WORKERS"; }
if build g10 "-Dheap_partitions"; then
  run g10 on idle "$UNITS" "$WORKERS"
  run g10 on idle "$UNITS" "$WORKERS" shrink
  run g10 on pause "$PUNITS" "$PROUNDS" "$WORKERS"
fi
if build g12 "-Dheap_partitions" "$WORK/g12rt${PSEP}$REPO/src"; then
  run g12 on idle "$UNITS" "$WORKERS"
  run g12 on idle "$UNITS" "$WORKERS" shrink
  run g12 on pause "$PUNITS" "$PROUNDS" "$WORKERS"
fi
exit "$status"
