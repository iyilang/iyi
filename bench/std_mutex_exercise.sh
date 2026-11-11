#!/usr/bin/env bash
# Exercises `std/mutex`: the lock at run time, and the compiler's check of
# every block that reaches the value behind it.
#
#     bash bench/std_mutex_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# the patches below are written in python, and windows answers `python3`
# with a store stub that prints and exits rather than running it, so the
# interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from `pwd` is `/c/...` and finds no prelude at all, and a
# scratch directory named `/tmp/tmp.X` is silently ignored on that path, so
# the patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

# std_copy_dir <name>: $WORK/<name>/std made for a patched module, with the
# prelude's tree beside it. The compiler takes a file for std's only where
# its directory's parent holds `iyi/prelude.iyi` (`ShareReach#std_at?`), so
# a std copy alone was a program's module, held to a program's rules.
std_copy_dir() {
  rm -rf "$WORK/$1"
  mkdir -p "$WORK/$1/std"
  cp -R "$REPO/src/iyi" "$WORK/$1/"
}

# A broken lock can wait forever; where `timeout` exists, a run that does
# is ended and counted as caught.
LIMIT=""
command -v timeout >/dev/null 2>&1 && LIMIT="timeout 60"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_mutex_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  $LIMIT "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/mutex exercise, plain build"
build_and_run "plain" mutex-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/mutex-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every mutex section reported"
for phrase in "== a value behind a lock" "== tasks that park while they hold it" "== threads" "== a thread asleep until the release" "== cancelled while it waits" "== waiting for the value to change" "== what it refuses" "== a waiter parks, and its worker runs other tasks" "== a waiter the holder keeps taking the lock back from"; do
  if ! grep -q "$phrase" "$WORK/mutex-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" mutex-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/mutex-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what the compiler refuses"
# Each block that reaches the value is a way in and a way out, and each is
# refused where it is written: a captured array, an answer that carries the
# value out, a constructor handed an array something else holds, a
# constant, a method's self, a nested lock reaching the outer value, and
# the private constructor that would take a value from outside.
refuse_build() { # refuse_build <name> <phrase> <body>
  printf 'module %s\n\nimport std/mutex::{Mutex}\n\n%s\n' "$1" "$3" >"$WORK/$1.iyi"
  if "$IYI" build --no-codegen -o "$WORK/$1" "$WORK/$1.iyi" >"$WORK/$1.log" 2>&1; then
    echo "  $1 compiled"
    status=1
  elif ! grep -qF "$2" "$WORK/$1.log"; then
    echo "  $1 was refused, but not saying \"$2\":"
    grep -m1 'Error' "$WORK/$1.log" | sed 's/^/    /'
    status=1
  else
    echo "  $1: $(grep -m1 'Error' "$WORK/$1.log" | sed 's/^Error: //' | cut -c1-150)"
  fi
}
refuse_build captured_array 'the block Mutex#lock runs behind the Mutex'"'"'s lock captures `outside : Array(Int32)`, which is not Share' \
'outside = [1, 2]
m = Mutex.new { [0] }
m.lock { |a| a.concat(outside) }'
refuse_build answer_out 'Mutex#get answers `(Array(Int32) | Cancelled)`, which is not Share' \
'm = Mutex.new { [0] }
leaked = m.get { |a| a }'
refuse_build handed_in 'the block Mutex.new makes the Mutex'"'"'s value in captures `outside : Array(Int32)`' \
'outside = [1]
m = Mutex.new { outside }'
refuse_build constant 'names the constant `CACHE : Array(Array(Int32))`, which is not Share' \
'CACHE = [] of Array(Int32)
m = Mutex.new { [0] }
m.lock { |a| CACHE << a }'
refuse_build self_capture 'captures `self : SelfCapture::Keeper`' \
'class Keeper
  @m : Mutex(Array(Int32))

  def initialize
    @kept = [] of Array(Int32)
    @m = Mutex.new { [0] }
  end

  def keep : Nil
    @m.lock { |a| @kept << a }
    nil
  end
end

Keeper.new.keep'
refuse_build nested 'captures `a : Array(Int32)`, which is not Share' \
'm = Mutex.new { [0] }
n = Mutex.new { [[0]] }
m.lock { |a| n.lock { |b| b << a } }'
refuse_build value_constructor "private method 'new' called" \
'm = Mutex(Array(Int32)).new([1])'

echo
echo "== a deadlock on one thread is said, not waited out"
# The two tasks are `spawn(unit: :same)`: each block captures only the Mutex,
# which is `Share`, and a plain `spawn` put them on the pool, where the
# deadlock is no longer one thread's and the scheduler names it instead
# ("deadlock: every fiber is blocked"), each task then failing `cancelled`.
cat >"$WORK/deadlock.iyi" <<'IYI'
module deadlock

import std/mutex::{Mutex}

m = Mutex.new { [0] }
group do |g|
  g.spawn(unit: :same) do
    # A channel nobody else holds: the block may not capture one that is
    # not Share, so the holder makes its own, and waits on it for good.
    m.lock { |a| a[0] = Channel(Int32).new.receive.or_panic }.or_panic
    0
  end
  g.spawn(unit: :same) do
    m.lock { |a| a[0] = 1 }.or_panic
    0
  end
end
IYI
if $LIMIT "$IYI" run "$WORK/deadlock.iyi" >"$WORK/deadlock.out" 2>&1; then
  echo "  a task waiting for a lock its parked holder could never release finished"
  status=1
elif grep -q "Mutex: deadlock: the task holding this lock is parked on this thread" "$WORK/deadlock.out"; then
  echo "  $(grep -m1 -o 'Mutex: deadlock.*' "$WORK/deadlock.out")"
else
  echo "  the deadlock ended without saying so:"
  tail -3 "$WORK/deadlock.out" | sed 's/^/    /'
  status=1
fi

echo
echo "== a wait beside a thread that has yet to run is no deadlock"
# On darwin, and on Linux when libc makes the threads, a started thread puts
# itself on the threads' list only once it runs, so a `wait_for` right after
# `IyiThread.start` found one thread with nothing else to run on it and
# panicked "deadlock" (`Mutex.alone?`): on tmac (macOS 26.6, M2 Pro) the
# exercise built `-Diyi_chaos`, one worker, did so on every seed 1-8, in the
# wait for a write from another thread. Built so here, and run with
# `IYI_CHAOS_LATE_THREADS`, which holds a thread that links itself until
# the simulated thread has nothing to run: the waiting task reaches the
# check before the thread is on the list, on every seed, and the copy that
# counts the list alone must be caught on every seed where threads link
# themselves. Left to the OS, tmac caught it on seeds 5-7 of 1-8.
cat >"$WORK/starting.iyi" <<'IYI'
module starting

import std/mutex::{Mutex}

late = Mutex.new { [0] }
writer = IyiThread.start do
  late.lock { |cell| cell[0] = 9 }.or_panic
  nil
end
seen = late.wait_for { |cell| cell[0] == 0 ? nil : cell[0] }.or_panic
writer.join
puts "answered #{seen}"
IYI
starting_runs() { # starting_runs <name> <search path>: sets answered, deadlocked, other (seed lists)
  answered=""; deadlocked=""; other=""
  if ! IYI_PATH="$2" "$IYI" build -Diyi_chaos -o "$WORK/$1" "$WORK/starting.iyi" >"$WORK/$1.build.log" 2>&1; then
    other=" build"
    tail -5 "$WORK/$1.build.log" | sed 's/^/    /'
    return
  fi
  for seed in 1 2 3 4 5 6 7 8; do
    IYI_CHAOS=$seed IYI_WORKERS=1 IYI_CHAOS_LATE_THREADS=1 $LIMIT "$WORK/$1" >"$WORK/$1-$seed.out" 2>&1
    if grep -q "answered 9" "$WORK/$1-$seed.out"; then
      answered="$answered $seed"
    elif grep -q "Mutex#wait_for: deadlock" "$WORK/$1-$seed.out"; then
      deadlocked="$deadlocked $seed"
    else
      other="$other $seed"
    fi
  done
}
starting_runs starting "$REPO/src${PSEP}$REPO/samples/iyi"
if [ -n "$deadlocked$other" ]; then
  echo "  a wait beside a starting thread failed: deadlock on seeds${deadlocked:- none}, otherwise on${other:- none}"
  status=1
else
  echo "  answered on seeds$answered"
fi
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the threads'-list-only proof is unmeasured"
else
  # The patched module's directory is not the binary's name: `-o
  # $WORK/listonly` over a directory of that name ran nothing (darwin:
  # "Permission denied" on every seed), so the copy was never proven.
  std_copy_dir listonly-std
  if ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/mutex.iyi").read_text()
old = "        return false if IyiThread.others_started?\n"
if src.count(old) != 1:
    raise SystemExit("patch site missing")
Path("$WORK/listonly-std/std/mutex.iyi").write_text(src.replace(old, "        return false if IyiThread.program_threads > 1_u64\n", 1))
PY
  then
    echo "  the threads'-list-only patch did not apply"
    status=1
  else
    starting_runs listonly "$WORK/listonly-std${PSEP}$REPO/src${PSEP}$REPO/samples/iyi"
    case "$(uname -s)" in
      Darwin)
        if [ -n "$deadlocked" ] && [ -z "$answered$other" ]; then
          echo "  a deadlock check counting the threads' list alone is caught: deadlock on seeds$deadlocked"
        else
          echo "  a deadlock check counting the threads' list alone was not caught on every seed: answered on${answered:- none}, deadlock on${deadlocked:- none}, otherwise on${other:- none}"
          status=1
        fi
        ;;
      *)
        echo "  a deadlock check counting the threads' list alone, here where \`start\` lists the thread itself: answered on${answered:- none}, deadlock on${deadlocked:- none} (caught on darwin)"
        if [ -n "$other" ]; then
          echo "  ... and neither on${other}: the copy did not run as built"
          status=1
        fi
        ;;
    esac
  fi
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new> [argument...]: the exercise,
# given the arguments, must fail on a copy of the module with <old>
# replaced, at the check that names <phrase>, or, given `hangs` as the
# phrase, by running past the time limit.
prove_broken() {
  std_copy_dir patched
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if [ "$2" = hangs ] && [ -z "$LIMIT" ]; then
    echo "  no timeout here, so the $1 proof is unmeasured"
    return
  fi
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/mutex.iyi").read_text()
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site is not in the module once")
Path("$WORK/patched/std/mutex.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
    return
  fi
  local label="$1" phrase="$2"
  shift 4
  IYI_PATH="${UNPREEMPTED:+$UNPREEMPTED$PSEP}$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" $LIMIT "$IYI" run "$REPO/bench/std_mutex_exercise.iyi" -- "$@" >"$WORK/mut.out" 2>&1
  code=$?
  if [ "$code" -eq 0 ]; then
    echo "  the exercise PASSED on $label"
    status=1
  elif [ "$phrase" = hangs ] && [ "$code" -eq 124 ]; then
    echo "  $label is caught: the waiter never woke"
  elif [ "$phrase" != hangs ] && grep -qF "$phrase" "$WORK/mut.out"; then
    echo "  $label is caught"
  else
    echo "  $label failed, but not where it should have (exit $code):"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
prove_broken "a lock taken while it is held" "parking inside the lock counted" \
  '    return false unless @word.compare_and_set(FREE, HELD)[1]
' '    @word.set(HELD)
'
# A waiter whose cancellation is ignored takes the lock anyway, and its
# block runs; the exercise's waiter then reports that it ran.
prove_broken "a cancelled waiter whose block runs anyway" "not Cancelled" \
  '    if refused = acquire
      return refused
    end
    register_release
    IyiCross.shared { block.call(@value) }
    run_release
    nil
  end

  # The block'"'"'s answer' '    acquire
    register_release
    IyiCross.shared { block.call(@value) }
    run_release
    nil
  end

  # The block'"'"'s answer'
prove_broken "a block that does not release" "already holds the lock" \
  '    register_release
    IyiCross.shared { block.call(@value) }
    run_release
    nil
  end

  # The block'"'"'s answer' '    IyiCross.shared { block.call(@value) }
    nil
  end

  # The block'"'"'s answer'
# A release not registered with the task's cleanups (`register_release`):
# the lock is let go after the block, and kept by a block that panics -
# first by the second lock its holder refuses.
prove_broken "a release a panic does not run" "the panic released the lock it held" \
  '    register_release
    IyiCross.shared { block.call(@value) }
    run_release
    nil
  end

  # The block'"'"'s answer' '    IyiCross.shared { block.call(@value) }
    release
    nil
  end

  # The block'"'"'s answer'
# A release that does not count itself as a change: a waiter reads its own
# release as one, checks again at once, and spins with the lock in turn,
# never yielding to the producer on its thread.
prove_broken "a release not counted as a change" hangs \
  '    @changes.add(1_u64) if counted
' ''
# A waiter that counts itself as waiting only after its release, as one
# once did: its own release reads nobody waiting and skips the count, and
# the waiter spins as above.
prove_broken "a waiter counted after its release" hangs \
  '    answer = IyiCross.shared { block.call(@value) }
    @change_waiters.add(1_u64) if answer.nil?
    run_release
' '    answer = IyiCross.shared { block.call(@value) }
    run_release
    @change_waiters.add(1_u64) if answer.nil?
'
# The refusal of a wait nothing could end, taken out: the task parks, and
# the scheduler names the deadlock on the main thread, which the
# exercise's `assert_panics` around that task does not catch.
prove_broken "a wait nothing could end left to wait" "deadlock: every fiber is blocked" \
  '        if Mutex.alone?
          @change_waiters.sub(1_u64)
          raise "Mutex#wait_for: deadlock: nothing is left to change the value - no other task on this thread, and no other thread"
        end
' ''
# A task parked on the lock is woken by a release and nothing else;
# without the wake it stays parked, and with nothing left to run the
# scheduler names the deadlock.
prove_broken "a release that does not wake a task parked on the lock" "deadlock: every fiber is blocked" \
  '          @word.set(FREE)
          IyiScheduler.wake_on(pointerof(@word), 1)
        else
' '          @word.set(FREE)
        else
'
# The same for a task parked waiting for a change.
prove_broken "a release that does not wake a task waiting for a change" "deadlock: every fiber is blocked" \
  '      IyiScheduler.wake_on(pointerof(@changes), 0x7FFFFFFF) if counted
' ''
# A waiter that never starves, and a release that lets the lock go where
# it should hand it over: either way the holder takes it back after each
# hold, and the waiter waits out all of them.
prove_broken "a waiter that never starves" "the holder taking it back each time it let it go" \
  '          if retakes >= RETAKES || __iyi_monotonic_ns - began >= STARVE_NS
' '          if false
' starves
prove_broken "a release that lets go where it hands over" "the holder taking it back each time it let it go" \
  '    @word.set(HANDED)
' '    @word.set(FREE)
' starves
# A waiter that holds its worker until the lock is free, spinning where it
# parked, as one asleep in the kernel holds it: the task spawned beside it
# waits for the release to start. Built against a prelude whose pool never
# preempts (SPEC.md III.4.13, part 9): the spin is a loop in a library
# module, and a preempted spinner gives its worker to the task beside it,
# which a waiter asleep in the kernel would not.
mkdir -p "$WORK/unpreempted/iyi"
cp "$REPO"/src/iyi/*.iyi "$WORK/unpreempted/iyi/"
grep -v '^            Pointer(Atomic(UInt64)).new(address).value.set(1_u64) if address != 0_u64$' \
  "$REPO/src/iyi/concurrency.iyi" > "$WORK/unpreempted/iyi/concurrency.iyi"
if cmp -s "$WORK/unpreempted/iyi/concurrency.iyi" "$REPO/src/iyi/concurrency.iyi"; then
  echo "  the monitor's raise was not found, so the copy without preemption is the tree"
  status=1
fi
UNPREEMPTED="$WORK/unpreempted"
prove_broken "a waiter that holds its worker" "while a Mutex waiter held one worker of two" \
  '        waited = IyiScheduler.park_on(pointerof(@word), seen)
' '        while @word.get == seen
          IyiThread.spin_pause
        end
        waited = nil
' parks

echo
if [ "$status" -eq 0 ]; then
  echo "the std/mutex exercise holds"
else
  echo "the std/mutex exercise did not hold"
fi
exit $status
