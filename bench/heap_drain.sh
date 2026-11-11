#!/usr/bin/env bash
# heap22 S6 (LeakHunt): the partitions' runs given back, driven.
# bench/heap_drain.iyi built with partitions, plain and optimised: its
# partition arenas flat round after round (drained runs taken again) and
# its pooled runs' pages back after an idle wait; its mark mode, the
# partitions held under long global marks; with the verifier and under
# chaos with a local collection at every park, no report; the flag-off
# control; then one broken copy per mechanism: without the take of
# drained runs or the global sweep's listing the arenas grow, without
# the idle wake the pool stays warm, without the release the resident set
# stays, without the hold the arenas grow under the marks (the program
# fails), and a taken run's objects left `LOCAL` instead of published are
# caught by `-Dheap_verify` (exit 86).
#
#   bash bench/heap_drain.sh           # every part
#   bash bench/heap_drain.sh sound     # plain, optimised, verifier, chaos
#   bash bench/heap_drain.sh off       # the flag-off control
#   bash bench/heap_drain.sh copies    # the broken copies
#
# Needs `make` first. `IYI` names the compiler, `SEEDS` the chaos seeds
# (default "1 2"), `KEEP=DIR` keeps every build and run. Exits non-zero
# when a sound build fails or a copy is missed.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="${KEEP:-$(mktemp -d)}"
mkdir -p "$WORK"
PART="${1:-all}"
SEEDS="${SEEDS:-1 2}"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
  *) PSEP=':' ;;
esac

[ -n "${KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT

status=0

# build NAME FLAGS [PATH]: the program built with FLAGS (against PATH's
# runtime when given); false when it does not build.
build() {
  local name="$1" flags="$2" path="${3:-}"
  # shellcheck disable=SC2086
  if ! env ${path:+IYI_PATH="$path"} "$IYI" build $flags -o "$WORK/$name" "$REPO/bench/heap_drain.iyi" >"$WORK/$name.build.log" 2>&1; then
    echo "  $name: build failed"
    sed -n '1,12p' "$WORK/$name.build.log" | sed 's/^/    /'
    status=1
    return 1
  fi
}

# whole LABEL NAME FLAGS [ARGS...]: built and run; exit 0, no report.
whole() {
  local label="$1" name="$2" flags="$3"
  shift 3
  build "$name" "$flags" || return
  timeout 600 "$WORK/$name" "$@" >"$WORK/$name.out" 2>"$WORK/$name.err"
  local code=$?
  if [ "$code" -ne 0 ] || grep -q "^iyi: heap_verify: partition" "$WORK/$name.err"; then
    echo "  $label: exit $code"
    sed -n '1,12p' "$WORK/$name.out" "$WORK/$name.err" | sed 's/^/    /'
    status=1
    return
  fi
  echo "  $label: $(head -1 "$WORK/$name.out")"
}

# again LABEL NAME OUT [ARGS...]: NAME, built by `whole`, run again with
# ARGS into OUT; exit 0, no report.
again() {
  local label="$1" name="$2" out="$3"
  shift 3
  [ -x "$WORK/$name" ] || return
  timeout 600 "$WORK/$name" "$@" >"$WORK/$out.out" 2>"$WORK/$out.err"
  local code=$?
  if [ "$code" -ne 0 ] || grep -q "^iyi: heap_verify: partition" "$WORK/$out.err"; then
    echo "  $label: exit $code"
    sed -n '1,12p' "$WORK/$out.out" "$WORK/$out.err" | sed 's/^/    /'
    status=1
    return
  fi
  echo "  $label: $(head -1 "$WORK/$out.out")"
}

if [ "$PART" = all ] || [ "$PART" = sound ]; then
  echo "== the arenas flat round after round (-Dheap_partitions)"
  whole "plain" plain "-Dheap_partitions"
  whole "optimised" release "-Dheap_partitions --release"
  whole "verifier" verify "-Dheap_partitions -Dheap_verify" 8 24 4
  echo "== the partitions held under long marks (mark mode)"
  again "optimised" release release-mark mark
  again "verifier" verify verify-mark mark 1000000 4 2
  build stress "-Dheap_partitions -Dheap_verify -Diyi_chaos" && for seed in $SEEDS; do
    env IYI_CHAOS="$seed" IYI_HEAP_STRESS=1 timeout 600 "$WORK/stress" 6 8 4 >"$WORK/stress-$seed.out" 2>"$WORK/stress-$seed.err"
    code=$?
    if [ "$code" -ne 0 ] || grep -q "^iyi: heap_verify: partition" "$WORK/stress-$seed.err"; then
      echo "  chaos seed $seed, a collection at every park: exit $code"
      sed -n '1,12p' "$WORK/stress-$seed.out" "$WORK/stress-$seed.err" | sed 's/^/    /'
      status=1
    else
      echo "  chaos seed $seed, a collection at every park: $(head -1 "$WORK/stress-$seed.out")"
    fi
  done
fi

if [ "$PART" = all ] || [ "$PART" = off ]; then
  echo "== the flag-off control"
  whole "flag off" off ""
  again "flag off, mark mode" off off-mark mark
fi

# One line deleted after a marker: `del MARKER LINE` as an awk program.
del() {
  printf '/%s/ { armed = 1 } armed && /%s/ { armed = 0; found = 1; next } { print } END { if (!found) exit 3 }' "$1" "$2"
}
# One line rewritten after a marker: `subst MARKER FROM TO`.
subst() {
  printf '/%s/ { armed = 1 } armed && sub(/%s/, "%s") { armed = 0; found = 1 } { print } END { if (!found) exit 3 }' "$1" "$2" "$3"
}

# copy LABEL DIR WANT AWK [FLAGS [ARGS...]]: src/iyi/heap_partition.iyi
# patched by AWK, the program built against it (with FLAGS, default the
# optimised partitioned build) and run with ARGS: caught when it exits
# WANT - 1, the arenas' growth the program fails on, or 86, the
# verifier's report, the program's own checks printed and passed over.
copy() {
  local label="$1" name="$2" dir="$WORK/$2" want="$3" script="$4" flags="${5:--Dheap_partitions --release}"
  shift 4
  [ $# -gt 0 ] && shift
  mkdir -p "$dir"
  cp -R "$REPO/src/iyi" "$REPO/src/std" "$dir/"
  if ! awk "$script" "$REPO/src/iyi/heap_partition.iyi" >"$dir/iyi/heap_partition.iyi"; then
    echo "  $label: what the copy changes is not in heap_partition.iyi any more"
    status=1
    return
  fi
  build "$name-bin" "$flags" "$dir${PSEP}$REPO/src" || return
  local only=""
  [ "$want" = 86 ] && only=1
  env ${only:+HEAP22_PRINT_ONLY=1} timeout 600 "$WORK/$name-bin" "$@" >"$dir/run.out" 2>"$dir/run.err"
  local code=$?
  if [ "$code" -ne "$want" ]; then
    echo "  $label: missed (exit $code, wanted $want)"
    sed -n '1,6p' "$dir/run.out" | sed 's/^/    /'
    status=1
    return
  fi
  if [ "$want" = 86 ]; then
    echo "  $label: caught, $(grep -m1 -A1 '^iyi: heap_verify: partition' "$dir/run.err" | tail -1 | sed 's/^ *//')"
  else
    echo "  $label: caught, $(grep -m1 '^FAIL: ' "$dir/run.out")"
  fi
}

if [ "$PART" = all ] || [ "$PART" = copies ]; then
  echo "== each mechanism removed"
  copy "a partition takes drained runs" c1 1 \
    "$(subst 'def self\.partition_take' 'drained = pop_listed\(index, PC_DRAIN\)' 'drained = 0_u64')"
  copy "the global sweep lists a parked run again" c2 1 \
    "$(del 'def self\.sweep_partition_slice' 'IyiHeap\.list_drained\(index, arena, cursor, n\)')"
  copy "a taken run's objects published" c3 86 \
    "$(subst 'def self\.adopt_drained' 'write8\(own, OWN_PUB\)' 'write8(own, 0_u64)')" "-Dheap_partitions -Dheap_verify" 8 24 4
  copy "an idle worker wakes for the warm pool" c4 1 \
    "$(subst 'def self\.idle_wait_ms' 'return timeout unless pool_warm\?' 'return timeout')"
  copy "a cooled run's pages go back" c5 1 \
    "$(del 'def self\.cool_pools' '__iyi_release_pages\(low, high - low\)')"
  copy "a partition holds under a mark" c6 1 \
    "$(del 'def self\.partition_slice' 'hold_partition\(record, debt\)')" "-Dheap_partitions --release" mark
fi

exit $status
