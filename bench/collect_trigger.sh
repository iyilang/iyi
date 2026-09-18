#!/usr/bin/env bash
# The allocation-pressure trigger, driven. Runs the trigger exercise plain
# and optimised, checks it reached its last line, and proves the checks fail
# in the directions that matter: a heap where nothing triggers, a budget
# that never grows with the live set, mappings that never go back, and a
# scheduler state left off the list that roots it.
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
for phrase in quiet trigger bounded_or_budget fiber scavenge pauses; do
  case "$phrase" in
    bounded_or_budget) grep -q "budget:" "$WORK/trigger.out" || { echo "  MISSING: budget"; status=1; } ;;
    *) grep -q "$phrase:" "$WORK/trigger.out" || { echo "  MISSING: $phrase"; status=1; } ;;
  esac
done
[ "$status" -eq 0 ] && echo "  quiet, trigger, budget, fiber, scavenge and pauses all reported"

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
echo "== the checks fail when the trigger is broken"
prove_fails() {
  # $5 names the prelude file the awk program rewrites; prelude.iyi unless said.
  local label="$1" dir="$2" phrase="$3" script="$4" file="${5:-prelude.iyi}"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  awk "$script" "$REPO/src/iyi/$file" > "$WORK/$dir/iyi/$file"
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/collect_trigger.iyi" \
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
  '{ sub(/IyiHeap\.arena_live\(arena\) == 0 && IyiHeap\.release_arena\(previous, arena\)/, "false"); print }'

# The allocator's slices and the helpers' round removed: every arena is
# debt until a pause pays it, which is the eager sweep back inside the
# pause, and the lazy check names it.
prove_fails "sweep never lazy" nolazy "lazy:" \
  '{ sub(/answer = IyiMark\.sweep_one\(chunk\)/, "answer = 0_u64"); sub(/return if @@helpers == 0_u64 \|\| @@sweep_left == 0_u64/, "return"); print }'

# The scheduler's state left off the global list: the thread-local still
# names it, nothing the walk scans does, the churn's own size class takes
# the chunk back, and the check names what came back in its place.
prove_fails "scheduler state unrooted" unrooted "scheduler state:" \
  '{ sub(/@@states_head = state/, "@@states_head = nil"); print }' concurrency.iyi

echo
if [ "$status" -eq 0 ]; then
  echo "Trigger: collections come from allocation pressure alone, the heap"
  echo "stays bounded, empty arenas go back to the kernel, the pauses have"
  echo "measured numbers, the budget grows with what survives, a parked"
  echo "fiber's reference lives through it, and the checks fail when any"
  echo "of it is broken."
else
  echo "Trigger: something above failed."
fi
exit "$status"
