#!/usr/bin/env bash
# The allocation-pressure trigger, driven. Runs the trigger exercise plain
# and optimised, checks it reached its last line, runs it again under a
# terminal's descriptor limit, and proves the checks fail in the
# directions that matter: a heap where nothing triggers, a budget that
# never grows with the live set, mappings that never go back, a scheduler
# state left off the list that roots it, an ended thread's allocation left
# uncounted, a budget floor blind to the threads, threads allocating free
# while a triggered collection pays its debt, and a descriptor every
# thread keeps.
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
  awk "$script" "$REPO/src/iyi/$file" > "$WORK/$dir/iyi/$file"
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
# churn buys the same collections either way.
prove_fails "budget never grows" nogrow "budget:" \
  '{ sub(/@@budget = next_budget\(.*\)/, "@@budget = MIN_BUDGET"); print }'

# The scavenge disabled: sweeps keep reclaiming chunks, mappings never go
# back, and the heap is high-water — the check names it.
prove_fails "mappings never return" noscavenge "scavenge:" \
  '{ sub(/elsif empty && IyiHeap\.release_arena\(previous, arena\)/, "elsif false"); print }'

# Every empty arena handed back whatever the budget: the next epoch maps
# the ones it needs afresh, and the spare check counts them.
prove_fails "empty arenas never spared" nospare "spare:" \
  '{ sub(/if empty && spared \+ IyiHeap::MAP \+ SPARE_BELOW <= budget/, "if false"); print }'

# The allocator's slices and the helpers' round removed: every arena is
# debt until a pause pays it, which is the eager sweep back inside the
# pause, and the lazy check names it.
prove_fails "sweep never lazy" nolazy "lazy:" \
  '{ sub(/answer = IyiMark\.sweep_for\(table, index\)/, "answer = 0_u64"); sub(/return if @@helpers == 0_u64 \|\| @@sweep_left == 0_u64/, "return"); print }'

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

# The floor back at MIN_BUDGET whatever the threads: four threads
# registered, and the budget a collection leaves is a single thread's.
prove_fails "floor blind to the threads" nofloor "floor:" \
  '{ sub(/floor = MIN_BUDGET \* IyiThread\.program_threads/, "floor = MIN_BUDGET"); print }'

# The debt's assist removed: a slice that finds a collection triggered
# runs on as it did, and four threads churning together with no helper
# sweep none of the debt the triggering thread pays.
prove_fails "debt never assisted" noassist "debt:" \
  '{ sub(/sweep_assist if total >= budget/, "# removed"); print }' prelude.iyi debt_assist.iyi

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
  echo "thread past the budget, a parked fiber's reference lives through it,"
  echo "five hundred ended threads hold no descriptor, and the checks fail"
  echo "when any of it is broken."
else
  echo "Trigger: something above failed."
fi
exit "$status"
