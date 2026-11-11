#!/usr/bin/env bash
# heap22 slices S1 and S1b, measured: bench/heap_local_cost.iyi built
# --release without partitions, with them at the tree's granule (1 KiB),
# and with a copy of the runtime at S1's 4 KiB granule; each runs the
# idle test (as is, and collecting at every park) and the pause test.
# Prints the programs' lines; fails only if a program fails.
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

build() { # name flags [iyi-path]
  local name="$1" flags="$2" path="${3:-}"
  local env=()
  [ -n "$path" ] && env=("IYI_PATH=$path")
  # shellcheck disable=SC2086
  if ! env ${env[@]+"${env[@]}"} "$IYI" build --release $flags -o "$WORK/$name" "$REPO/bench/heap_local_cost.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$name: build failed"
    sed -n '1,16p' "$WORK/$name.build.log"
    status=1
    return 1
  fi
}

run() { # name args...
  local name="$1"
  shift
  if ! timeout 600 "$WORK/$name" "$@"; then
    echo "$name $*: failed"
    status=1
  fi
}

mkdir -p "$WORK/g12/iyi"
cp -R "$REPO/src/iyi/." "$WORK/g12/iyi/"
awk '{ if (sub(/^  GRANULE_SHIFT = 10_u64$/, "  GRANULE_SHIFT = 12_u64")) found = 1; print } END { if (!found) exit 3 }' \
  "$REPO/src/iyi/heap_partition.iyi" > "$WORK/g12/iyi/heap_partition.iyi" || { echo "the granule is not 1 KiB in this tree"; exit 1; }

build off "" && { run off idle "$UNITS" "$WORKERS"; run off pause "$PUNITS" "$PROUNDS" "$WORKERS"; }
if build g10 "-Dheap_partitions"; then
  run g10 idle "$UNITS" "$WORKERS"
  run g10 idle "$UNITS" "$WORKERS" shrink
  run g10 pause "$PUNITS" "$PROUNDS" "$WORKERS"
fi
if build g12 "-Dheap_partitions" "$WORK/g12${PSEP}$REPO/src"; then
  run g12 idle "$UNITS" "$WORKERS"
  run g12 idle "$UNITS" "$WORKERS" shrink
  run g12 pause "$PUNITS" "$PROUNDS" "$WORKERS"
fi
exit "$status"
