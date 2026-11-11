#!/usr/bin/env bash
# The allocation-pressure trigger, driven. Runs the trigger exercise plain
# and optimised, checks it reached its last line, runs it again under a
# terminal's descriptor limit, and proves the checks fail in the
# directions that matter: a heap where nothing triggers, a budget that
# never grows with the live set, mappings that never go back, a scheduler
# state left off the list that roots it, an ended thread's allocation left
# uncounted, a budget floor blind to the threads, threads allocating free
# while a triggered collection pays its debt, threads allocating past the
# collection's ceiling, and a descriptor every thread keeps.
# Under `-Dheap_partitions` the budget and floor copies change the
# partition branch of the budget, two more take that branch from the
# start and never, and working_set's bound gets a copy with the
# partitions' own collection off instead of the ceiling's.
#
#   bash bench/collect_trigger.sh
#
# Needs `make` first. Exits non-zero if any step fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# the wrapper in bin is a posix shell script, so a caller that already has a
# compiler of its own names it through the environment.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0

# Built with `-Dheap_partitions` (the compiler reads `IYI_OPTS`) the shared
# heap's budget is `IyiMark.next_budget`'s partition branch once the
# program has made a partition (the exercise's step 1c makes one): twice
# what survived outside the partitions, floored at `IyiHeap::SHARED_MIN`
# whatever the threads (heap22, design section 4.2). The copies that
# change the budget or its floor change that branch then.
PARTITIONS=0
case " ${IYI_OPTS:-} " in
  *" -Dheap_partitions "*) PARTITIONS=1 ;;
esac
# The partition branch's last line, which the budget and floor copies
# rewrite.
SHARED_RETURN='return grown_shared < IyiHeap::SHARED_MIN \? IyiHeap::SHARED_MIN : grown_shared'

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/collect_trigger.iyi" \
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
run_case "the exercise" trigger
if ! grep -q "all trigger checks passed" "$WORK/trigger.out" 2>/dev/null; then
  echo "  MISSING: the exercise did not reach the end"
  status=1
fi

echo
echo "== every check reported"
for phrase in quiet trigger bounded_or_budget fiber scavenge pauses threads floor; do
  case "$phrase" in
    bounded_or_budget) grep -q "budget:" "$WORK/trigger.out" || { echo "  MISSING: budget"; status=1; } ;;
    *) grep -q "$phrase:" "$WORK/trigger.out" || { echo "  MISSING: $phrase"; status=1; } ;;
  esac
done
[ "$status" -eq 0 ] && echo "  quiet, trigger, budget, fiber, scavenge, pauses, threads and floor all reported"
if [ "$PARTITIONS" -eq 1 ] && ! grep -q "partitions:" "$WORK/trigger.out"; then
  echo "  MISSING: partitions"
  status=1
fi

echo
echo "== a triggered collection's debt, swept by the threads past the budget"
if ! "$IYI" build --release -o "$WORK/debt" "$REPO/bench/debt_assist.iyi" >"$WORK/debt.build.log" 2>&1; then
  echo "  the debt exercise did not build"; sed -n '1,12p' "$WORK/debt.build.log"; status=1
elif ! "$WORK/debt" >"$WORK/debt.out" 2>&1 || ! grep -q "^debt:" "$WORK/debt.out"; then
  echo "  the debt exercise failed:"; sed 's/^/  /' "$WORK/debt.out"; status=1
else
  sed 's/^/  /' "$WORK/debt.out"
fi

echo
# One run's peak is a draw with a long tail: it is the largest epoch's,
# and an epoch is as large as its collection is slow. Single runs went
# past the bound of four budgets, 192 MiB, at every commit from ad0712a65
# to 12f085712, and none of them moved the distribution: held to 4 of
# Windows 11's 12 logical processors (the user's machine), the runtimes
# of ad0712a65, a43f52139 (8b482f97e's too) and 12f085712 (ea40ef2c8's
# and dcd048158's too) under one compiler peaked at 124 to 236 MiB,
# medians 161 to 166, past the bound in 2 to 4 runs of 30 each, and with
# every thread's raise put back by itself at 129 to 209, 3 of 45; on
# macOS 26.6, an M2 Pro with 10 cores (the user's machine), ad0712a65,
# a43f52139, 8b482f97e, ea40ef2c8 and 12f085712 each built as itself
# peaked at 147 to 206 MiB, medians 171 to 175, past it in 17 runs of
# 400, and a byte-for-byte copy of 12f085712's program in 2 of 50 against
# its own 3 of 50; on Linux (12 vCPU held to 4) the three runtimes at 157
# to 200, past it in 0 to 2 runs of 40 each. CI's single runs since
# ad0712a65 - 137, 141, 181 and 201 MiB on Windows' four-processor
# runners, 168, 168 and 193 on darwin's three-core ones - are draws from
# the same. The bound's own evidence was 3 to 5 runs a machine
# (bench/working_set.iyi), and the step takes the best of three runs, as
# the proof below gives its copy three: a run within the bound passes
# it, and a run that fails anything else fails it at once.
echo "== twelve workers allocating flat out peak within four budgets, the best of three runs"
if ! "$IYI" build --release -o "$WORK/working" "$REPO/bench/working_set.iyi" >"$WORK/working.build.log" 2>&1; then
  echo "  the working-set program did not build"; sed -n '1,12p' "$WORK/working.build.log"; status=1
else
  held=""
  for run in 1 2 3; do
    "$WORK/working" >"$WORK/working.out" 2>&1
    code=$?
    if [ "$code" -eq 0 ] && grep -q "^working set:" "$WORK/working.out"; then
      held="$run"; break
    fi
    if ! grep -q "^FAIL: working set: .* past four budgets" "$WORK/working.out"; then
      echo "  the working-set program failed run $run (exit $code):"; sed 's/^/  /' "$WORK/working.out"; held="failed"; status=1; break
    fi
    echo "  run $run: $(grep -m1 '^FAIL: working set:' "$WORK/working.out")"
  done
  if [ -z "$held" ]; then
    echo "  the working-set program went past the bound in all three runs"; status=1
  elif [ "$held" != failed ]; then
    echo "  run $held: $(grep -m1 '^working set:' "$WORK/working.out")"
  fi
fi

echo
echo "== the same program with optimisation on"
run_case "release" trigger-release --release
if ! grep -q "all trigger checks passed" "$WORK/trigger-release.out" 2>/dev/null; then
  echo "  MISSING: the optimised build did not reach the end"
  status=1
fi

echo
echo "== the same program, opted out with -Dgc_none"
run_case "gc_none" trigger-none -Dgc_none

echo
echo "== the exercise is fast enough to be a gate"
# The first run of this exercise took 106 seconds, because the freed check
# was a free-list walk and the trigger's steady state made every sweep
# quadratic. The FREE flag made it one load; this step is what keeps that
# from quietly regressing. Ten seconds is fifty times the measured 0.2 and
# far under the quadratic's 100.
started="$(date +%s)"
"$WORK/trigger" > /dev/null 2>&1
elapsed="$(( $(date +%s) - started ))"
if [ "$elapsed" -gt 10 ]; then
  echo "  the exercise took ${elapsed}s, so a sweep or the freed check has gone quadratic again"
  status=1
else
  echo "  ${elapsed}s for 132 MiB of churn and its collections"
fi

echo
echo "== five hundred short-lived threads under a terminal's descriptor limit"
# A Mac's terminal starts a program under `ulimit -n` 256. darwin's stop
# parked each thread on a pipe of its own that nothing closed, so the 500
# threads of the exercise's step 7 died at "pipe failed" under that limit
# on macOS 26.6, Apple M2 Pro, 10 cores (the user's machine). A thread
# holds no descriptor past its end on Linux or darwin now. Windows has no
# such limit to run under; a thread's handles are counted by
# bench/thread_exercise.sh's teardown.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    echo "  no descriptor limit to run under here" ;;
  *)
    ( ulimit -n 256 && exec "$WORK/trigger" ) > "$WORK/trigger-256.out" 2>&1
    code=$?
    if [ "$code" -ne 0 ] || ! grep -q "all trigger checks passed" "$WORK/trigger-256.out"; then
      echo "  under ulimit -n 256 the exercise exited $code:"
      tail -5 "$WORK/trigger-256.out" | sed 's/^/  /'
      status=1
    else
      grep "threads:" "$WORK/trigger-256.out"
    fi
    ;;
esac

echo
echo "== the checks fail when the trigger is broken"
prove_fails() {
  # $5 names the prelude file the awk program rewrites; prelude.iyi unless
  # said. $6 the exercise; collect_trigger.iyi unless said. $7 a
  # descriptor limit the program runs under; none unless said.
  local label="$1" dir="$2" phrase="$3" script="$4" file="${5:-prelude.iyi}" program="${6:-collect_trigger.iyi}" limit="${7:-}"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  if ! awk "$script" "$REPO/src/iyi/$file" > "$WORK/$dir/iyi/$file"; then
    echo "  $label: what the copy changes is not in $file any more"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/$program" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched prelude did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  if [ -n "$limit" ]; then
    ( ulimit -n "$limit" && exec "$WORK/$dir/program" ) >"$WORK/$dir/out" 2>&1
  else
    "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  fi
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at the expected check"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

# The pressure report removed from the hot path: nothing ever triggers, and
# the churn's check names the leak.
prove_fails "nothing triggers" notrigger "trigger:" \
  '{ sub(/IyiMark\.pressure\(slice\)/, "# removed"); print }'

# The budget pinned at the floor: the live set stops mattering, and the same
# churn buys the same collections either way. Under partitions the floor
# is the partition branch's, `SHARED_MIN`, and the copy pins it there.
if [ "$PARTITIONS" -eq 1 ]; then
  prove_fails "budget never grows" nogrow "budget:" \
    "{ if (sub(/$SHARED_RETURN/, \"return IyiHeap::SHARED_MIN\")) found = 1; print } END { if (!found) exit 3 }"
else
  prove_fails "budget never grows" nogrow "budget:" \
    '{ sub(/IyiStat\.set\(IyiStat::BUDGET, next_budget\(.*\)\)/, "IyiStat.set(IyiStat::BUDGET, MIN_BUDGET)"); print }'
fi

# The scavenge disabled: sweeps keep reclaiming chunks, mappings never go
# back, and the heap is high-water — the check names it.
prove_fails "mappings never return" noscavenge "scavenge:" \
  '{ sub(/elsif empty && IyiHeap\.release_arena\(previous, arena\)/, "elsif false"); print }'

# Every empty arena handed back whatever the budget: the next epoch maps
# the ones it needs afresh, and the spare check counts them.
prove_fails "empty arenas never spared" nospare "spare:" \
  '{ if (sub(/if empty && !idle && spared \+ IyiHeap::MAP \+ SPARE_BELOW <= budget/, "if false")) found = 1; print } END { if (!found) exit 3 }'

# The allocator's slices and the helpers' round removed: every arena is
# debt until a pause pays it, which is the eager sweep back inside the
# pause, and the lazy check names it.
prove_fails "sweep never lazy" nolazy "lazy:" \
  '{ sub(/answer = IyiMark\.sweep_for\(table, index\)/, "answer = 0_u64"); sub(/return if @@helpers == 0_u64 \|\| IyiStat\.get\(IyiStat::SWEEP_LEFT\) == 0_u64/, "return"); print }'

# The scheduler's state left off every root: the thread-local still names
# it, nothing the walk scans does, the churn's own size class takes the
# chunk back, and the check names what came back in its place. It has two
# roots since tasks crossed cores (SPEC.md III.4.13): the global list of
# states, and the main fiber's `home` - the thread a fiber is woken into -
# which the fiber registry reaches. Cut only the list, the state lived
# through the home and the check passed, on every platform. The link
# alone, not the unlink a retiring thread does (`state.next_state`).
prove_fails "scheduler state unrooted" unrooted "scheduler state:" \
  '{ sub(/@@states_head = state$/, "@@states_head = nil"); sub(/^    main\.home = state$/, "    main.home = nil"); print }' concurrency.iyi

# A thread's unreported slice dropped with its cache again: five hundred
# threads under a slice each count for nothing, and the threads check
# names the collection that did not run.
prove_fails "an ended thread's slice uncounted" noretire "threads:" \
  '{ sub(/allocated_word\.value\.add\(read64\(page \+ CACHE_SLICE\)\)/, "# removed"); print }'

if [ "$PARTITIONS" -eq 1 ]; then
  # Under partitions the floor counts no thread (design section 4.2), so
  # a floor blind to the threads is the design: the partition branch
  # returns before the line that copy rewrites.
  echo "  floor blind to the threads: not run under -Dheap_partitions, where the floor is SHARED_MIN whatever the threads and next_budget returns before the floor it rewrites; the shared floor's copies follow"

  # The shared floor back at a thread's, MIN_BUDGET: a collection with a
  # few KB live leaves half the shared floor, busy or idle.
  prove_fails "the shared floor at a thread's" lowfloor "floor:" \
    "{ if (sub(/$SHARED_RETURN/, \"return grown_shared < MIN_BUDGET ? MIN_BUDGET : grown_shared\")) found = 1; print } END { if (!found) exit 3 }"

  # The old floor back, SHARED_MIN for every thread that filled a slice:
  # four threads churning leave four floors.
  prove_fails "floor counts the threads" threadfloor "floor:" \
    "{ if (sub(/^ +allocating_threads\$/, \"          threads = allocating_threads\")) found++; if (sub(/$SHARED_RETURN/, \"return grown_shared < IyiHeap::SHARED_MIN * threads ? IyiHeap::SHARED_MIN * threads : grown_shared\")) found++; print } END { if (found != 2) exit 3 }"

  # The floor counting every registered thread, idle or not: the four
  # threads stop allocating, and the next budget is still five floors.
  prove_fails "floor counts idle threads" idlefloor "floor:" \
    "{ if (sub(/$SHARED_RETURN/, \"return grown_shared < IyiHeap::SHARED_MIN * IyiThread.program_threads ? IyiHeap::SHARED_MIN * IyiThread.program_threads : grown_shared\")) found = 1; print } END { if (!found) exit 3 }"

  # The shared heap's rule from the program's start: a program with no
  # partition yet has its budget floored at `SHARED_MIN` rather than a
  # thread's, and step 1c names the collection that left it.
  prove_fails "the shared rule before any partition" sharedfirst "partitions:" \
    '{ if (sub(/if IyiHeap\.partitions_made\?$/, "if true")) found = 1; print } END { if (!found) exit 3 }'

  # The rule without partitions for good: the shared heap's floor counts
  # the threads again once the pool units run, and the floor step names it.
  prove_fails "the shared rule never taken" sharednever "floor:" \
    '{ if (sub(/if IyiHeap\.partitions_made\?$/, "if false")) found = 1; print } END { if (!found) exit 3 }'
else
  # The floor back at MIN_BUDGET whatever the threads: four threads
  # registered, and the budget a collection leaves is a single thread's.
  prove_fails "floor blind to the threads" nofloor "floor:" \
    '{ sub(/floor = MIN_BUDGET \* allocating_threads/, "floor = MIN_BUDGET"); print }'

  # The floor counting every registered thread again, idle or not: the four
  # threads stop allocating, and the next budget is still five threads'.
  prove_fails "floor counts idle threads" idlefloor "floor:" \
    '{ sub(/floor = MIN_BUDGET \* allocating_threads/, "floor = MIN_BUDGET * IyiThread.program_threads"); print }'
fi

# The debt's assist removed: a slice that finds a collection triggered
# runs on as it did, and four threads churning together with no helper
# sweep none of the debt the triggering thread pays. Both of the assist's
# calls go: the slice's past the budget, and the hold's past the ceiling.
# With the hold's left in, a thread that reached the ceiling while the
# collection's thread paid the debt swept it there: held to 3 cores on
# Linux (12 vCPUs), the copy passed 5 of 10 runs, 12 to 62 slices swept,
# and it passed on darwin arm64's 3-core runner (run 41800443380), 2 of
# 10 runs there. With both out it failed 20 of 20 held to 3 cores, and
# 10 of 10 on that runner (debug run 41812323963), where the shipped
# runtime swept 98 to 861 slices in 10; 435 to 1202 on Linux.
prove_fails "debt never assisted" noassist "debt:" \
  '{ if (sub(/sweep_assist if total >= budget/, "# removed")) found++; if (sub(/^            sweep_assist$/, "            nil")) found++; print } END { if (found != 2) exit 3 }' prelude.iyi debt_assist.iyi

# The collection's ceiling removed: a slice that finds a collection under
# way past the budget allocates on, as every slice did, and twelve
# workers peak past four budgets. Built for release as the step above
# runs it, and run three times, as the step above takes the best of
# three: it is caught when all three go past the bound. Without the
# ceiling, on Windows 11, 12 logical processors (the user's machine), the
# runtime peaked at 217 to 285 MiB in 15 runs (601 to 873 held to 4
# processors, where the runtime as it is peaked at 135 to 209, and 148 to
# 164 on all 12); on macOS 26.6, an M2 Pro with 10 cores (the user's
# machine), 420 to 569 in 15; on Linux (12 vCPU) 406 to 685 in 10, and
# 437 to 627 held to 4. Before the ceiling went in it peaked at 231 to
# 248 in 5 runs on that Windows machine on a 52 MiB budget; the bound is
# four of the twelve workers' 48 MiB floor.
if [ "$PARTITIONS" -eq 1 ]; then
  # Under partitions the twelve workers are pool units (`unit: :new`)
  # allocating in partitions of their own: a partition's slice never
  # holds (`IyiHeap.partition_slice`, the ceiling is the shared heap's)
  # and never feeds the global trigger (design section 4.2), so the
  # working set ran through no collection of the shared heap and the
  # ceiling's copy cannot move it. What bounds it is each partition's
  # own collection (design section 4.1): the copy turns every local
  # collection off - in flight, at a park and by an idle worker - and
  # twenty thousand rounds a worker, a tenth of the step's, are left to
  # pile up with nothing taking any of it back: forty thousand peaked at
  # 888 MiB through no collection on macOS 26.6, an M2 Pro with 10
  # cores, so twenty thousand are about twice the four budgets the step
  # holds the twelve to.
  echo "  the ceiling never holds: not run under -Dheap_partitions, where working_set's workers allocate in their partitions, whose slices never reach the shared heap's ceiling; the partitions' own collection's copy follows"
  mkdir -p "$WORK/nolocal/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/nolocal/iyi/"
  if ! awk '{ if (sub(/^  @@local_off : Bool = false$/, "  @@local_off : Bool = true")) found = 1; print } END { if (!found) exit 3 }' \
       "$REPO/src/iyi/heap_partition.iyi" > "$WORK/nolocal/iyi/heap_partition.iyi"; then
    echo "  a partition never collects: the switch this proof turns is not in heap_partition.iyi any more"; status=1
  elif ! IYI_PATH="$WORK/nolocal${PSEP}$REPO/src" "$IYI" build --release \
         -o "$WORK/nolocal/program" "$REPO/bench/working_set.iyi" >"$WORK/nolocal/build.log" 2>&1; then
    echo "  a partition never collects: the patched runtime did not build"; sed -n '1,12p' "$WORK/nolocal/build.log"; status=1
  else
    "$WORK/nolocal/program" 12 20000 >"$WORK/nolocal/out" 2>&1
    exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
      echo "  a partition never collects: the working set still stayed within the bound, so it does not test this"
      sed -n '$p' "$WORK/nolocal/out"; status=1
    elif ! grep -q "^FAIL: working set: .* past four budgets" "$WORK/nolocal/out"; then
      echo "  a partition never collects: failed, but not at the expected check"
      sed -n '$p' "$WORK/nolocal/out"; status=1
    else
      printf '  a partition never collects: exits %s at "%s"\n' "$exit_code" "$(grep -m1 '^FAIL: working set:' "$WORK/nolocal/out")"
    fi
  fi
else
  mkdir -p "$WORK/noceiling/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/noceiling/iyi/"
  if ! awk '{ if ($0 ~ /^ *hold if total >= ceiling$/) { print "# removed"; removed++; next } print } END { if (removed != 2) exit 3 }' \
       "$REPO/src/iyi/prelude.iyi" > "$WORK/noceiling/iyi/prelude.iyi"; then
    echo "  the ceiling never holds: the two holds this proof removes are not in the prelude any more"; status=1
  elif ! IYI_PATH="$WORK/noceiling${PSEP}$REPO/src" "$IYI" build --release \
         -o "$WORK/noceiling/program" "$REPO/bench/working_set.iyi" >"$WORK/noceiling/build.log" 2>&1; then
    echo "  the ceiling never holds: the patched prelude did not build"; sed -n '1,12p' "$WORK/noceiling/build.log"; status=1
  else
    peaks=""
    held=""
    for run in 1 2 3; do
      "$WORK/noceiling/program" >"$WORK/noceiling/out" 2>&1
      if [ $? -ne 0 ] && grep -q "^FAIL: working set: .* past four budgets" "$WORK/noceiling/out"; then
        peaks="$peaks $(sed -n 's/^FAIL: working set: [0-9]* workers peaked at \([0-9]*\) MiB.*/\1/p' "$WORK/noceiling/out")"
      else
        held="$run"; break
      fi
    done
    if [ -n "$held" ]; then
      echo "  the ceiling never holds: run $held did not go past the bound, so the best of three does not test this"
      sed -n '$p' "$WORK/noceiling/out"; status=1
    else
      printf '  the ceiling never holds: all three runs exit 1, peaking at%s MiB, the last at "%s"\n' "$(printf '%s' "$peaks" | sed 's/ \([0-9]*\)/ \1,/g; s/,$//')" "$(grep -m1 '^FAIL: working set:' "$WORK/noceiling/out")"
    fi
  fi
fi

# A descriptor every thread keeps, under the terminal's limit: the darwin
# park's pipe again, made at every start and never closed, and on Linux
# the same leak in Linux's calls, an eventfd. Step 7's five hundred
# threads run out of descriptors.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    echo "  a descriptor every thread keeps: no descriptor limit to run under here" ;;
  Darwin)
    prove_fails "a pipe every thread keeps" keptpipe "pipe failed" \
      '/^      fun sysctlbyname\(name : UInt8\*/ { print; print "      fun pipe(fds : Int32*) : Int32"; next }
       /^    def self\.start\(proc : Proc\(Nil\)\) : IyiThread$/ { start = 1 }
       start && /^      \{% elsif flag\?\(:darwin\) %\}$/ { print; print "        fds = Pointer(Int32).malloc(2_u64)"; print "        raise \"pipe failed\" if LibC.pipe(fds) != 0"; start = 0; next }
       { print }' thread.iyi collect_trigger.iyi 256 ;;
  *)
    prove_fails "an eventfd every thread keeps" keptfd "eventfd2 failed" \
      '/^    def self\.start\(proc : Proc\(Nil\)\) : IyiThread$/ { start = 1 }
       start && /^      \{% if flag\?\(:linux\) %\}$/ { print; print "        raise \"eventfd2 failed\" if __iyi_conc_syscall3(IYI_SYS_EVENTFD2, 0_i64, 0x80000_i64, 0_i64) < 0"; start = 0; next }
       { print }' thread.iyi collect_trigger.iyi 256 ;;
esac

echo
if [ "$status" -eq 0 ]; then
  echo "Trigger: collections come from allocation pressure alone, the heap"
  echo "stays bounded, empty arenas go back to the kernel past what a deep"
  echo "budget will fill again, the pauses have"
  echo "measured numbers, the budget grows with what survives and is floored"
  echo "for every thread, a triggered collection's debt is swept by every"
  echo "thread past the budget, twelve workers allocating flat out peak within"
  echo "four budgets, a parked fiber's reference lives through it,"
  echo "five hundred ended threads hold no descriptor, and the checks fail"
  echo "when any of it is broken."
else
  echo "Trigger: something above failed."
fi
exit "$status"
