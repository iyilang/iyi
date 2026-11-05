#!/usr/bin/env bash
# An `ensure` that parks its fiber while an exception passes through it, on
# x86_64-windows-msvc: the exception comes out the other side as the same
# object with the same callstack, for every way an ensure is reached.
#
#     bash bench/ensure_park.sh
#
# The compiler used to run an ensure inside the C++ catch funclet and
# re-raise with `_CxxThrowException(NULL, NULL)`, which rethrows the C++
# runtime's per-thread "current exception". An ensure that switched fibers
# in there - `Fiber.yield`, `sleep`, a channel, a contended mutex - handed
# the thread, and that state, to the next fiber on it, and the process
# aborted with 0xC0000409: 3 runs of 3 for each of the seven parking
# shapes below at 8 fibers on one thread, and the one run of each of the
# four run at 16 fibers on four threads; two fibers were enough, and one
# fiber alone passed (Windows 11, 12 logical processors, the
# user's machine). Git's bash reports that abort as exit 127. The compiler
# now catches the object, leaves the funclet, runs the ensure as ordinary
# code and throws the object again (src/compiler/iyi/codegen/exception.cr).
# bench/ensure_park.cr is the program; each shape it takes is one way an
# ensure is reached.
#
# The broken copy is the old funclet codegen itself: the bootstrap Crystal
# the fork is built with still has it, so the same program built by that
# compiler must fail the same check. If a bootstrap ever stops aborting,
# this says so rather than passing on a proof that proves nothing.
#
# The funclet is MSVC's alone: elsewhere a landing pad is ordinary code and
# the re-raise names its exception, so on any other platform this reports
# itself unmeasured and exits 0.
set -euo pipefail

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *)
    echo "ensure_park: unmeasured on $(uname -s): the catch funclet this checks is x86_64-windows-msvc's"
    exit 0
    ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The wrapper in bin is a posix shell script, so a caller with a compiler of
# its own names it through the environment.
CRYSTAL="${CRYSTAL:-$REPO/bin/crystal}"
# The broken copy's compiler: the Crystal the fork is bootstrapped with.
BOOTSTRAP="${BOOTSTRAP_CRYSTAL:-crystal}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# A native compiler cannot resolve this shell's own path mapping.
REPO="$(cygpath -m "$REPO")"
WORK="$(cygpath -m "$WORK")"

status=0
fail() { echo "ensure_park FAIL: $1"; status=1; }

# Passes when the program exits 0 and says wrong=0; otherwise `last` says
# how it ended. A run that hangs is ended at 300 s (exit 124) and fails.
check() { # exe shape fibers rounds threads
  local exe="$1" shape="$2" fibers="$3" rounds="$4" threads="$5" out code
  set +e
  out="$(timeout 300 "$exe" "$shape" "$fibers" "$rounds" "$threads" 2>&1)"
  code=$?
  set -e
  if [ "$code" -eq 0 ] && printf '%s\n' "$out" | grep -q "^ensure_park shape=$shape .* wrong=0$"; then
    return 0
  fi
  last="exit $code: $(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ')"
  return 1
}

echo "== the fork's compiler =="
if ! "$CRYSTAL" build --no-color -o "$WORK/fixed.exe" "$REPO/bench/ensure_park.cr" > "$WORK/fixed.log" 2>&1; then
  sed -n '1,20p' "$WORK/fixed.log"
  fail "bench/ensure_park.cr did not build with $CRYSTAL"
else
  # 8 fibers x 400 rounds per shape on the default one-thread context, which
  # is where two fibers' handlers interleave on one thread; then four
  # threads, where a parked fiber can also resume on another one.
  for shape in yield sleep channel mutex rescued missed nested; do
    if check "$WORK/fixed.exe" "$shape" 8 400 1; then
      echo "  ok   $shape, 8 fibers x 400 rounds, 1 thread"
    else
      fail "$shape, 1 thread: $last"
    fi
  done
  for shape in yield channel mutex rescued; do
    if check "$WORK/fixed.exe" "$shape" 16 200 4; then
      echo "  ok   $shape, 16 fibers x 200 rounds, 4 threads"
    else
      fail "$shape, 4 threads: $last"
    fi
  done
fi

echo "== the broken copy: the old funclet codegen, from the bootstrap Crystal =="
if ! command -v "$BOOTSTRAP" > /dev/null 2>&1; then
  fail "no bootstrap compiler '$BOOTSTRAP' on the PATH to build the broken copy with"
elif ! env -u CRYSTAL_PATH -u CRYSTAL_HAS_WRAPPER "$BOOTSTRAP" build --no-color -o "$WORK/broken.exe" \
     "$REPO/bench/ensure_park.cr" > "$WORK/broken.log" 2>&1; then
  sed -n '1,20p' "$WORK/broken.log"
  fail "bench/ensure_park.cr did not build with the bootstrap ($BOOTSTRAP)"
else
  # The control first: an ensure that does not park passes under the old
  # codegen too, so what fails below fails for parking and not for being
  # built by another compiler.
  if check "$WORK/broken.exe" none 8 400 1; then
    echo "  ok   the old codegen passes the control, an ensure that does not park"
  else
    fail "the old codegen failed the control, so its failures below prove nothing: $last"
  fi
  # Every one-thread shape whose ensure parks while the propagating
  # exception is the funclet's own must fail; `rescued` reaches its ensure
  # through the rescue_ensure pad, the same funclet.
  for shape in yield sleep channel mutex rescued missed nested; do
    if check "$WORK/broken.exe" "$shape" 8 400 1; then
      fail "the old funclet codegen passed $shape, so the check does not test it"
    else
      echo "  failure proof: the old codegen fails $shape ($last)"
    fi
  done
fi

if [ "$status" -eq 0 ]; then
  echo "ensure_park: an ensure that parks while an exception passes keeps the exception, on every shape"
fi
exit "$status"
