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
for phrase in reclaimed warm survivor liveness large steady refault room threaded cut trim batches idle; do
  grep -q "$phrase" "$WORK/sweep.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  reclaimed, warm, survivor, liveness, large, steady, refault, room, threaded, cut, trim, batches and idle all reported"

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
# The script edits `prelude.iyi` unless a fifth argument names another
# file of `src/iyi`.
prove_fails() {
  local label="$1" dir="$2" phrase="$3" script="$4" file="${5:-prelude.iyi}"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  awk "$script" "$REPO/src/iyi/$file" > "$WORK/$dir/iyi/$file"
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
  if grep -qE "$phrase" "$WORK/$dir/out"; then
    printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
      "$(grep -m1 -E "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
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
  grep -v '^[0-9][0-9]* ' "$WORK/$dir/out" | tail -6 | sed 's/^/    /'
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
  '{ if ($0 ~ /^          if word & IyiHeap::EPOCH_FLAG != epoch && \(colour == WHITE \|\| word & IyiHeap::FREE_FLAG != 0\)$/) { print "          if word & IyiHeap::EPOCH_FLAG != epoch"; next } print }'

# The refill stops threading idle warm runs: the pages stay idle, the
# class carves its frontier, and the warm check names how many were left.
prove_fails "warm pages never taken up" nowarm "warm:" \
  '{ sub(/head = thread_warm\(candidate, table, index\) if /, "head = 0_u64 if "); print }'

# A chunk popped off the list is handed out with the dead object's bytes
# still in it - a warm page holds what the dead left - so the clearing
# entry point lies, and the check reads it.
prove_fails "warm chunks not cleared" dirtywarm "warm:" \
  '{ if ($0 ~ /^          clear_block\(head, chunk_of\(index\)\) if clear$/) { print "          # removed"; next } print }'

# The allocation's fast path handing out a list chunk without clearing it:
# every chunk after a refill's first comes that way.
prove_fails "the fast path does not clear" dirtyfast "warm:" \
  '{ if ($0 ~ /^                write64\(word, 0_u64\)$/) { print "                # removed"; next } print }'

# The carve not counted as the class's take: an epoch that carves what
# its warm pages fell short of keeps no more warm the epoch after - the
# first warm check's burst keeps none, and the churn asking twice its
# budget hands its excess back every epoch and carves it again (#150).
prove_fails "the carve not counted" carvetake "warm:|refault:|rounding:" \
  '{ if ($0 ~ /^        taken_add\(table, index, count &\* chunk\)$/) { print "        # removed"; found = 1; next } print } END { if (!found) exit 3 }'

# A budget's worth of pages kept warm on top of the class's take, as
# every class's room held a budget before it followed the take: the
# burst's pages stay warm.
prove_fails "a budget kept warm past the take" roombudget "room:" \
  '{ if ($0 ~ /^          room = taken >= room \? taken : room - \(room - taken \+ ROOM_FADE - 1_u64\)\.unsafe_div\(ROOM_FADE\)$/) { print "          room = taken + budget.unsafe_shr(IyiHeap::PAGE_SHIFT)"; found = 1; next } print } END { if (!found) exit 3 }'

# A room that rises with the take and never falls: the burst's pages
# stay warm through every small epoch after it.
prove_fails "the room never falls" roomflat "room:" \
  '{ if ($0 ~ /^          room = taken >= room \? taken : room - \(room - taken \+ ROOM_FADE - 1_u64\)\.unsafe_div\(ROOM_FADE\)$/) { print "          room = taken >= room ? taken : room"; found = 1; next } print } END { if (!found) exit 3 }'

# The pause's sweep handing a whole arena's dead chunks over as one
# batch: the one refill that takes it takes every warm page the arena
# kept, and the class reads as taking them all.
prove_fails "a pause's batch a whole arena" wholebatch "room:" \
  '{ if ($0 ~ /^      def self\.sweep_one_held : Bool$/) held = 1
     if (held && $0 ~ /^          batch = sweep_slice\(arena, SWEEP_SPAN\)$/) { print "          batch = sweep_slice(arena, IyiHeap::SWEEP_DONE)"; held = 0; found = 1; next }
     print } END { if (!found) exit 3 }'

# A warm run threaded whole, as before: one refill takes the run.
prove_fails "a warm run threaded whole" uncapped "threaded:" \
  '{ if (sub(/run = take_run\(arena, true, WARM_RUN\.unsafe_shr\(PAGE_SHIFT\)\)/, "run = take_run(arena, true, 0_u64)")) found = 1; print } END { if (!found) exit 3 }'

# A warm run cut at the page a slab's worth on, off the chunk grid: the
# last chunk threaded reaches pages into the rest of the run, which the
# trim hands back under it.
prove_fails "a warm run cut off the grid" offgrid "cut:|trim:" \
  '{ if ($0 ~ /^          cut = \(first \+ \(target - first \+ chunk - 1_u64\)\.unsafe_div\(chunk\) \* chunk - arena\)\.unsafe_shr\(PAGE_SHIFT\)$/) { print "          cut = page + most"; found = 1; next } print } END { if (!found) exit 3 }'

# The trim handing back a run's first page whatever reaches into it:
# the chunk threaded last before it loses its tail.
prove_fails "the trim takes a reached-into page" trimedge "trim:" \
  '{ if ($0 ~ /^          low = low \+ PAGE if \(low - first\)\.unsafe_mod\(chunk\) != 0$/) { print "          # removed"; found = 1; next } print } END { if (!found) exit 3 }'

# The trim turning a batch's listed pages idle and leaving the batch on
# the centre: the next refill hands out chunks of idle pages.
prove_fails "a trimmed batch left on the centre" trimstack "batches:" \
  '{ if ($0 ~ /^              write64\(line \+ CLASS_BATCHES, following\)$/) { print "              # removed"; found = 1; next }
     if ($0 ~ /^              write64\(previous \+ BATCH_NEXT, /) { print "              # removed"; next }
     print } END { if (!found) exit 3 }'

# The monitor never asking for the trim: the warm pages of an idle pool
# stay.
prove_fails "the idle pool never trims" notrim "idle:" \
  '{ if (sub(/trimmed = IyiMark\.trim_idle$/, "trimmed = true")) found = 1; print } END { if (!found) exit 3 }' concurrency.iyi

# A class nobody allocates in any more kept warm within the budget, as
# every class was: its pages hold the room the classes in use want.
prove_fails "idle classes kept warm" idlewarm "idle class:" \
  '{ if ($0 ~ /^        @@epoch - IyiHeap\.read64\(line \+ IyiHeap::CLASS_USED\) >= IDLE_EPOCHS &&$/) { print "        false &&"; found = 1; next } print } END { if (!found) exit 3 }'

# A class idle after a few epochs however short: four collections back
# to back hand its pages back.
prove_fails "idle by epochs alone" idleshort "idle class:" \
  '{ if ($0 ~ /^          @@epoch_ns - used_ns >= IDLE_NS$/) { print "          true"; found = 1; next } print } END { if (!found) exit 3 }'

# A class refilled only in the first epoch read at its stamp of 0, which
# every clock reading is more than a second past: its arenas go back three
# collections in, however short.
prove_fails "the first epoch's classes idle at once" idlefirst "idle class:" \
  '{ if ($0 ~ /^        used_ns = @@first_turn_ns if used_ns == 0_u64$/) { print "        # removed"; found = 1; next } print } END { if (!found) exit 3 }'

# An idle class's empty arena kept by its cache as every fill arena was:
# its pages go cold but the mapping, its header and its tables stay.
prove_fails "idle classes' arenas kept" idlearena "idle class:" \
  '{ if ($0 ~ /^          IyiHeap\.let_go_fill\(arena\) if idle$/) { print "          # removed"; found = 1; next } print } END { if (!found) exit 3 }'

# The carve's batch left unstamped: the listed chunks read as nothing the
# sweep or the mark can tell from an uncarved one.
prove_fails "a batch left unstamped" batchstamp "batch:" \
  '{ if ($0 ~ /^            write8\(entry, CARVED_FLAG \| FREE_FLAG \| epoch\)$/) { print "            # removed"; next } print }'

# And not listed at all: every allocation carves again. darwin arm64's
# sixteen-kilobyte pages make the carving show first in the warm check's
# high water, which catches it there.
prove_fails "a batch not listed" batchlist "batch:|warm:" \
  '{ if ($0 ~ /^          table\[index\] = listed$/) { print "          # removed"; next } print }'

# The idle bit read for the first page of a slice and trusted to its end:
# the chunks of idle pages after it read as dead, are linked again, and
# the pages come back from the kernel under the batch. Proven on Linux,
# whose four-kilobyte pages put idle ones inside the rounding check's
# slices; darwin arm64's sixteen-kilobyte pages let it through there.
case "$(uname -s)" in
  Linux)
    prove_fails "an idle bit trusted past its page" stalepage "rounding:" \
      '{ if (sub(/page_next = \(cursor \| \(IyiHeap::PAGE &- 1_u64\)\) &\+ 1_u64 if cursor >= page_next/, "page_next = stop if cursor >= page_next")) found = 1; print } END { if (!found) exit 3 }'
    ;;
  *)
    echo "  an idle bit trusted past its page: not proven here, because this platform's pages keep idle ones out of the rounding check's slices"
    ;;
esac

echo
if [ "$status" -eq 0 ]; then
  echo "Sweeping: unreachable chunks come back and are handed out again, a live"
  echo "object survives intact, and the exercise fails in both directions."
else
  echo "Sweeping: something above failed."
fi
exit "$status"
