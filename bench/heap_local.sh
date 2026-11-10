#!/usr/bin/env bash
# heap22 slice S1's local collections, driven: bench/heap_local.iyi built
# with partitions and the verifying build's poison-on-free, plain and
# optimised, and with partitions alone; then proven to fail at its own
# check in each direction that matters - a local mark that follows words
# into other partitions, a free that lists another heap's chunk, a global
# sweep that drops what it frees for a partition, a pointer answer left
# as a store into the box, a death that frees a pinned unit's partition,
# a local mark blind to the unit's other fibers, and a local sweep that
# leaves a weak cell naming the chunk it freed.
#
#   bash bench/heap_local.sh            # both halves
#   bash bench/heap_local.sh cases      # the builds that must pass
#   bash bench/heap_local.sh broken     # the copies that must fail
#
# Needs `make` first. Exits non-zero if any step fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
PART="${1:-all}"

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

run_case() { # label name build-flags program-args...
  local label="$1" name="$2" flags="$3"
  shift 3
  # shellcheck disable=SC2086
  if ! "$IYI" build $flags -o "$WORK/$name" "$REPO/bench/heap_local.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,16p' "$WORK/$name.build.log"
    status=1
    return
  fi
  # A hang is a failure too, ended at 300 s (exit 124).
  timeout 300 "$WORK/$name" "$@" >"$WORK/$name.out" 2>&1
  local code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$code" -ne 0 ]; then
    echo "$label: exit $code"
    status=1
  fi
}

if [ "$PART" = all ] || [ "$PART" = cases ]; then
  echo "== partitions and poison-on-free, plain"
  run_case "verify" verify "-Dheap_partitions -Dheap_verify"
  run_case "verify, 4 workers" verify4 "-Dheap_partitions -Dheap_verify" 4 120
  echo "== partitions and poison-on-free, optimised"
  run_case "verify release" verifyr "--release -Dheap_partitions -Dheap_verify"
  run_case "verify release, 8 workers" verifyr8 "--release -Dheap_partitions -Dheap_verify" 8 200
  echo "== partitions alone, optimised"
  run_case "release" release "--release -Dheap_partitions" 4 200
  echo "== without partitions"
  run_case "no flag" noflag ""
fi

prove_fails() { # label dir phrase awk-script file
  local label="$1" dir="$2" phrase="$3" script="$4" file="$5"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  if ! awk "$script" "$REPO/src/iyi/$file" > "$WORK/$dir/iyi/$file"; then
    echo "  $label: what the copy changes is not in $file any more"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -Dheap_partitions -Dheap_verify \
       -o "$WORK/$dir/program" "$REPO/bench/heap_local.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched runtime did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  timeout 200 "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "^FAIL: $phrase" "$WORK/$dir/out"; then
    echo "  $label: failed (exit $code), but not at the expected check"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(grep -m1 "^FAIL: $phrase" "$WORK/$dir/out" | sed 's/^FAIL: //')"
}

if [ "$PART" = all ] || [ "$PART" = broken ]; then
  echo
  echo "== the checks fail when a mechanism is broken"

  # The local mark's owner filter gone: a word into another partition is
  # followed, and that partition's `OWN` byte written by a unit that does
  # not own it.
  prove_fails "a missed root filter" nofilter "filter:" \
    '/def self\.local_shade\(record : UInt64, id : UInt64, parity : UInt64, word : UInt64\)/ { inside = 1 } inside && /unsafe_shr\(GRANULE_SHIFT\) &\* 2_u64\) != id$/ { inside = 0; found = 1; next } { print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # `free` lists a chunk of the shared heap on a partition's list.
  prove_fails "an owner check missing in free" nofreeowner "free:" \
    '{ if (sub(/return id == 0 unless partition_arena\?\(arena\)/, "return true unless partition_arena?(arena)")) found = 1; print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # The global sweep frees a partition's dead and hands nothing back.
  prove_fails "a dropped return stack" noreturn "return:" \
    '/def self\.push_return\(record : UInt64, index : Int32, head : UInt64, tail : UInt64\)/ { print; print "    return"; found = 1; next } { print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # A pointer answer stored into the box and nothing more: the partition
  # is freed whole at the unit's death under the answer.
  prove_fails "a merge left as a box store" noanswer "answer:" \
    '/^      answered\(box\.object_id, / { found = 1; next } { print } END { if (!found) exit 3 }' \
    concurrency.iyi

  # A pin that moves the unit's allocation to the shared heap and leaves
  # its partition the unit's: the death frees it whole.
  prove_fails "a death that frees a pinned partition" nopin "pin:" \
    '/def self\.pin_running : Nil/ { inside = 1 } inside && /^    unit\.heap = 0_u64$/ { found = found + 1; next } inside && /^    merge\(record, 0_u64\)$/ { found = found + 1; inside = 0; next } { print } END { if (found != 2) exit 3 }' \
    heap_partition.iyi

  # The unit's other fibers' stacks left out of the local roots.
  prove_fails "other fibers' stacks unscanned" nostacks "fibers:" \
    '{ if ($0 ~ /^          local_range\(record, id, parity, fiber\.saved_sp, fiber\.stack_top\)$/) { found = 1; next } print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # The local sweep frees a weak target and leaves its cell naming the
  # freed chunk.
  prove_fails "a weak cell left on a freed target" noweak "weak:" \
    '/def self\.sweep_weak\(record : UInt64\) : Nil/ { inside = 1 } inside && /^            write64\(cell, 0_u64\)$/ { inside = 0; found = 1; next } { print } END { if (!found) exit 3 }' \
    heap_partition.iyi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "heap_local: units collect their own partitions, and the checks fail when any mechanism is broken."
fi
exit "$status"
