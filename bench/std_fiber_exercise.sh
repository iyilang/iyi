#!/usr/bin/env bash
# Exercises `std/fiber`: Fiber API.
#
#     bash bench/std_fiber_exercise.sh
#
# Proves:
#   * bench/std_fiber_exercise.iyi passes plain and --release.
#   * Fiber.current, name, and string inspection reflect current state.
#   * Spawning, initial state, and identity comparison.
#   * Cooperative yielding preserves sequential execution ordering.
#   * Completed fibers are dead, and fibers suspended in queue are resumable.
#   * Fiber.suspend parks off the run queue until explicit resume.
#   * A parked fiber is not running and is resumable.
#   * Enqueue of a dead fiber or a fiber with no stack is refused.
#   * Negative proofs: broken state comparisons or dropped fiber properties
#     are caught by assertions.
#
# Exits non-zero on any failure.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src:$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_fiber_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
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

echo "== the std/fiber exercise, plain build"
build_and_run "plain" fiber-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/fiber-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every fiber section reported"
for phrase in "== accessors and identity" \
              "== spawning and initial state" \
              "== cooperative yielding and deterministic ordering" \
              "== completion and suspended states" \
              "== explicit suspend and resume"; do
  if ! grep -q "$phrase" "$WORK/fiber-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" fiber-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/fiber-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
prove_fails() { # prove_fails <label> <dir> <phrase> <sed script>
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$script" "$REPO/src/std/fiber.iyi" > "$WORK/$dir/std/fiber.iyi"
  if cmp -s "$REPO/src/std/fiber.iyi" "$WORK/$dir/std/fiber.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build -o "$WORK/$dir/program" "$REPO/bench/std_fiber_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched module did not build"
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
    echo "  $label: failed, but not at the expected check ('$phrase')"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

prove_fails "running? inverted" mut_running "main fiber must be running" \
  's/@state == IyiFiberState::Running/@state != IyiFiberState::Running/'
prove_fails "dead? always false" mut_dead "completed fiber is dead" \
  's/@state == IyiFiberState::Done/false/'
prove_fails "resumable? always false" mut_resumable "freshly spawned fiber is resumable" \
  's/@state != IyiFiberState::Running && @state != IyiFiberState::Done/false/'
prove_fails "Fiber.new drops name" mut_name "spawned worker has assigned name" \
  's/f.name = name/f.name = nil/'
prove_fails "suspend leaves Running" mut_suspend "parked worker is not running" \
  's/IyiScheduler.current.state = IyiFiberState::Runnable/nil/'

echo
echo "== dead fiber enqueue is refused"
cat > "$WORK/dead_enq.iyi" << 'IYI'
module dead_enq
import std/fiber
using std/fiber::{Fiber}
f = Fiber.new do
end
f.resume
Fiber.yield
f.enqueue
Fiber.yield
puts "survived"
IYI
if ! "$IYI" build -o "$WORK/dead_enq" "$WORK/dead_enq.iyi" >"$WORK/dead_enq.build.log" 2>&1; then
  echo "dead enqueue: build failed"
  sed -n '1,12p' "$WORK/dead_enq.build.log"
  status=1
else
  "$WORK/dead_enq" >"$WORK/dead_enq.out" 2>&1
  if grep -q "survived" "$WORK/dead_enq.out" 2>/dev/null || ! grep -q "cannot enqueue a dead fiber" "$WORK/dead_enq.out"; then
    echo "dead enqueue: not refused with the module sentence"
    sed -n '1,12p' "$WORK/dead_enq.out"
    status=1
  else
    echo "  refused a dead fiber"
  fi
fi

echo
echo "== fiber with no stack is refused"
cat > "$WORK/ghost.iyi" << 'IYI'
module ghost
import std/fiber
using std/fiber::{Fiber}
f = Fiber.new
f.resume
Fiber.yield
puts "survived"
IYI
if ! "$IYI" build -o "$WORK/ghost" "$WORK/ghost.iyi" >"$WORK/ghost.build.log" 2>&1; then
  echo "ghost enqueue: build failed"
  sed -n '1,12p' "$WORK/ghost.build.log"
  status=1
else
  "$WORK/ghost" >"$WORK/ghost.out" 2>&1
  if grep -q "survived" "$WORK/ghost.out" 2>/dev/null || ! grep -q "cannot enqueue a fiber that has no stack" "$WORK/ghost.out"; then
    echo "ghost enqueue: not refused with the module sentence"
    sed -n '1,12p' "$WORK/ghost.out"
    status=1
  else
    echo "  refused a fiber with no stack"
  fi
fi

echo
echo "== proving those refuses come from the guards"
prove_enq() { # prove_enq <label> <dir> <script> <program> <old-bug>
  local label="$1" dir="$2" script="$3" program="$4" old="$5"
  mkdir -p "$WORK/$dir/std"
  sed -e "$script" "$REPO/src/std/fiber.iyi" > "$WORK/$dir/std/fiber.iyi"
  if cmp -s "$REPO/src/std/fiber.iyi" "$WORK/$dir/std/fiber.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build -o "$WORK/$dir/program" "$WORK/$program.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched module did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  if grep -q "$old" "$WORK/$dir/out"; then
    printf '  %s: old bug returns (%s)\n' "$label" "$old"
  else
    echo "  $label: patched run did not show the old bug"
    sed -n '1,12p' "$WORK/$dir/out"
    status=1
  fi
}
prove_enq "dead enqueue unguarded" mut_dead_enq \
  's/raise "cannot enqueue a dead fiber" if dead?//;s/raise "cannot enqueue a fiber that has no stack".*//' \
  dead_enq "stack overflow"
prove_enq "ghost enqueue unguarded" mut_ghost_enq \
  's/raise "cannot enqueue a fiber that has no stack".*//' \
  ghost "stack overflow"
echo
if [ "$status" -eq 0 ]; then
  echo "the std/fiber exercise holds"
else
  echo "the std/fiber exercise did not hold"
fi
exit $status
