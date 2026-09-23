#!/usr/bin/env bash
# GC_DESIGN.md Stage 6, driven. Runs the sweep exercise plain and optimised,
# checks it reached its last line rather than merely exiting 0, and proves the
# checks fail in both directions that matter: a sweep that reclaims nothing, and
# a sweep that reclaims something live.
#
#   bash bench/sweep_exercise.sh
#
# Needs `make` first. Exits non-zero if any step fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/sweep_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the exercise, the default allocator"
run_case "the exercise" sweep
if ! grep -q "all sweep checks passed" "$WORK/sweep.out" 2>/dev/null; then
  echo "  MISSING: the run did not reach the end"
  status=1
fi

echo
echo "== every check reported"
for phrase in reclaimed warm survivor liveness large steady; do
  grep -q "$phrase" "$WORK/sweep.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  reclaimed, warm, survivor, liveness, large and steady all reported"

echo
echo "== the same program with optimisation on"
run_case "release" sweep-release --release
if ! grep -q "all sweep checks passed" "$WORK/sweep-release.out" 2>/dev/null; then
  echo "  MISSING: the optimised build did not reach the end"
  status=1
fi

echo
echo "== the same program without the flag"
run_case "gc_none" sweep-none -Dgc_none

echo
echo "== the checks fail when the sweep is broken"
# Two directions. A sweep that reclaims nothing is a leak; a sweep that reclaims
# something live is a corrupted program. A check that cannot see both is not
# testing a collector.
prove_fails() {
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  awk "$script" "$REPO/src/iyi/prelude.iyi" > "$WORK/$dir/iyi/prelude.iyi"
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/sweep_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched prelude did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  # The phrase is the good case: the exercise survived the break, noticed it,
  # and said which check caught it.
  if grep -q "$phrase" "$WORK/$dir/out"; then
    printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
      "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
    return
  fi
  # A break can also be too severe to narrate. Since the prelude allocates its
  # own IO buffers from this heap, a sweep that hands out live chunks corrupts
  # the machinery `puts` needs, and the program dies on a signal before any
  # check can report. That is the break being caught, not missed, so it counts
  # only under conditions that cannot be satisfied by a working collector: the
  # process died on a signal, and it never reached the line that says it passed.
  # Windows delivers no signal: the runtime's vectored handler names the
  # access violation and exits 1, which is the same death in its own words.
  if [ "$exit_code" -ge 128 ] && ! grep -q "all sweep checks passed" "$WORK/$dir/out"; then
    printf '  %s: dies on signal %s before it can report, and never passes\n' \
      "$label" "$(( exit_code - 128 ))"
    return
  fi
  if [ "$exit_code" -eq 1 ] && grep -q "died of a memory fault" "$WORK/$dir/out" &&
     ! grep -q "all sweep checks passed" "$WORK/$dir/out"; then
    printf '  %s: dies of a memory fault before it can report, and never passes\n' "$label"
    return
  fi
  echo "  $label: failed, but not at the expected check"
  sed -n '$p' "$WORK/$dir/out"
  status=1
}

# The walk still counts and repaints, it just never hands a dead chunk on:
# nothing is linked onto the batch, and no run of them goes idle for the
# carve to take up - the two ways a swept chunk comes back.

prove_fails "sweep frees nothing" nofree "sweep:" \
  '{ if (!done && $0 ~ /^            batch_head = cursor$/) { print "            # removed"; done = 1; next }
     if ($0 ~ /^        return batch_head unless page_low < page_high && \(continuing \|\| /) { print "        return batch_head"; next }
     print }'

# The colour test stops mattering, so a live object goes on the free list.
prove_fails "sweep frees the live" reckless "sweep:" \
  '{ if ($0 ~ /^          if word & IyiHeap::EPOCH_FLAG != @@epoch_flag && \(colour == WHITE \|\| word & IyiHeap::FREE_FLAG != 0\)$/) { print "          if word & IyiHeap::EPOCH_FLAG != @@epoch_flag"; next } print }'

# The refill stops threading idle warm runs: the pages stay idle, the
# class carves its frontier, and the warm check names how many were left.
prove_fails "warm pages never taken up" nowarm "warm:" \
  '{ sub(/head = thread_warm\(candidate\) if /, "head = 0_u64 if "); print }'

# A chunk popped off the list is handed out with the dead object's bytes
# still in it - a warm page holds what the dead left - so the clearing
# entry point lies, and the check reads it.
prove_fails "warm chunks not cleared" dirtywarm "warm:" \
  '{ if ($0 ~ /^          clear_block\(head, chunk_of\(index\)\) if clear$/) { print "          # removed"; next } print }'

echo
if [ "$status" -eq 0 ]; then
  echo "Sweeping: unreachable chunks come back and are handed out again, a live"
  echo "object survives intact, and the exercise fails in both directions."
else
  echo "Sweeping: something above failed."
fi
exit "$status"
