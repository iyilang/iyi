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
for phrase in "== a value behind a lock" "== tasks that park while they hold it" "== threads" "== a thread asleep until the release" "== cancelled while it waits" "== waiting for the value to change" "== what it refuses" "== a waiter parks, and its worker runs other tasks"; do
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
cat >"$WORK/deadlock.iyi" <<'IYI'
module deadlock

import std/mutex::{Mutex}

m = Mutex.new { [0] }
group do |g|
  g.spawn do
    # A channel nobody else holds: the block may not capture one that is
    # not Share, so the holder makes its own, and waits on it for good.
    m.lock { |a| a[0] = Channel(Int32).new.receive.or_panic }.or_panic
    0
  end
  g.spawn do
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
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new> [argument...]: the exercise,
# given the arguments, must fail on a copy of the module with <old>
# replaced, at the check that names <phrase>, or, given `hangs` as the
# phrase, by running past the time limit.
prove_broken() {
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
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
    defer release
    block.call(@value)
    nil
  end

  # The block'"'"'s answer' '    acquire
    defer release
    block.call(@value)
    nil
  end

  # The block'"'"'s answer'
prove_broken "a block that does not release" "already holds the lock" \
  '    defer release
    block.call(@value)
    nil
  end

  # The block'"'"'s answer' '    block.call(@value)
    nil
  end

  # The block'"'"'s answer'
# A release that does not count itself as a change: a waiter reads its own
# release as one, checks again at once, and spins with the lock in turn,
# never yielding to the producer on its thread.
prove_broken "a release not counted as a change" hangs \
  '    @changes.add(1_u64)
' ''
# The refusal of a wait nothing could end, taken out: the task parks, and
# the scheduler names the deadlock on the main thread, which the
# exercise's `assert_panics` around that task does not catch.
prove_broken "a wait nothing could end left to wait" "deadlock: every fiber is blocked" \
  '        if Mutex.alone?
          raise "Mutex#wait_for: deadlock: nothing is left to change the value - no other task on this thread, and no other thread"
        end
' ''
# A task parked on the lock is woken by a release and nothing else;
# without the wake it stays parked, and with nothing left to run the
# scheduler names the deadlock.
prove_broken "a release that does not wake a task parked on the lock" "deadlock: every fiber is blocked" \
  '      IyiScheduler.wake_on(pointerof(@word), 1) if @word.swap(FREE) == CONTENDED
' '      @word.swap(FREE)
'
# The same for a task parked waiting for a change.
prove_broken "a release that does not wake a task waiting for a change" "deadlock: every fiber is blocked" \
  '      IyiScheduler.wake_on(pointerof(@changes), 0x7FFFFFFF) if @change_waiters.get != 0_u64
' ''
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
  '        waited = IyiScheduler.park_on(pointerof(@word), CONTENDED)
' '        while @word.get == CONTENDED
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
