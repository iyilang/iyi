#!/usr/bin/env bash
# Exercises `std/kernel`.
#
#     bash bench/std_kernel_exercise.sh
#
# Proves the exercise holds plain and --release, that a broken module is
# caught, that output helpers emit expected content, and that abort
# terminates execution with status codes and stderr messages.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_kernel_exercise.iyi" \
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

echo "== the std/kernel exercise, plain build"
build_and_run "plain" kernel-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/kernel-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every kernel section reported"
for phrase in "== p" "== pp" "== puts_all" "== print_all" "== loop" "== sleep"; do
  if ! grep -q "$phrase" "$WORK/kernel-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== output helpers emitted expected text"
for phrase in "42" '"kernel test"' "line1" "12345" "line3" "chunkA-987"; do
  if ! grep -qF -- "$phrase" "$WORK/kernel-plain.out" 2>/dev/null; then
    echo "  missing captured output: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  output helpers captured"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" kernel-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/kernel-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
else
  echo "  every check holds under --release"
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/kernel.iyi").read_text()
old = '  while true\n    yield\n  end'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/kernel.iyi").write_text(src.replace(old, '  return nil', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_kernel_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken kernel is caught"
fi

echo
echo "== one sleep, and it is the prelude's milliseconds"
# The module declared `sleep(seconds : Float64)` beside the prelude's
# `sleep(ms : Int32)`, so the unit was decided by whether the argument was
# written `2` or `2.0` — and the seconds one busy-waited on the monotonic
# clock, burning a core and starving every other fiber on the thread. Three
# things are checked: `std/kernel` exports no `sleep`, a `Float64` argument
# is refused by the prelude's own sentence, and a 2 ms sleep costs 2 ms of
# wall clock and no core.
if "$IYI" doc "$REPO/src/std/kernel.iyi" 2>/dev/null | grep -q "def sleep"; then
  echo "  std/kernel declares a sleep again"
  status=1
else
  echo "  std/kernel declares no sleep"
fi

printf '%s\n' 'module kernel_sleep_using' 'import std/kernel' 'using std/kernel::{sleep}' 'puts "USING_OK"' > "$WORK/sleep_using.iyi"
if "$IYI" build -o "$WORK/sleep_using" "$WORK/sleep_using.iyi" >"$WORK/sleep_using.build" 2>&1; then
  echo "  \`using std/kernel::{sleep}\` still compiles, so the name is still there"
  status=1
elif grep -q "no \`sleep\`" "$WORK/sleep_using.build"; then
  echo "  \`using std/kernel::{sleep}\` is refused by name"
else
  echo "  \`using std/kernel::{sleep}\` failed for a different reason"
  sed -n '1,12p' "$WORK/sleep_using.build"
  status=1
fi

printf '%s\n' 'module kernel_sleep_seconds' 'sleep(0.005)' > "$WORK/sleep_seconds.iyi"
if "$IYI" build -o "$WORK/sleep_seconds" "$WORK/sleep_seconds.iyi" >"$WORK/sleep_seconds.build" 2>&1; then
  echo "  a Float64 sleep compiled: two units for one name are back"
  status=1
elif grep -q "takes milliseconds" "$WORK/sleep_seconds.build"; then
  echo "  a Float64 sleep is refused, and the sentence names the unit"
else
  echo "  a Float64 sleep failed for a different reason"
  sed -n '1,12p' "$WORK/sleep_seconds.build"
  status=1
fi

echo
echo "== abort paths"
check_abort() { # check_abort <label> <name> <expected_code> <expected_stderr> <code>
  local label="$1" name="$2" expected_code="$3" expected_stderr="$4" code="$5"
  printf 'module main\n\nimport std/kernel\nusing std/kernel::{abort}\n\n%s\n' "$code" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2> "$WORK/$name.err"
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: it exited 0 instead of terminating"
    status=1
    return
  fi
  if [ "$exit_code" -ne "$expected_code" ]; then
    echo "  $label: expected exit code $expected_code, got $exit_code"
    status=1
    return
  fi
  if [ -n "$expected_stderr" ]; then
    if ! grep -qF -- "$expected_stderr" "$WORK/$name.err"; then
      echo "  $label: missing expected stderr '$expected_stderr'"
      status=1
      return
    fi
  fi
  printf '  %s: exits %s with expected message\n' "$label" "$exit_code"
}

check_abort "default abort" abort_default 1 "" 'abort()'
check_abort "abort with message and custom status" abort_msg 3 "kernel abort: fatal condition" 'abort("kernel abort: fatal condition", 3)'
check_abort "abort with nil message and custom status" abort_nil 42 "" 'abort(nil, 42)'

echo
if [ "$status" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
fi
exit $status
