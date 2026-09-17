#!/usr/bin/env bash
# Drives bench/runtime_exercise.iyi: the concurrency runtime gate for
# Windows x86_64, Linux, and Darwin (SPEC.md III.4).
#
#     bash bench/runtime_exercise.sh
#
# Verifies:
#   1. Exercise holds every property on plain and release builds.
#   2. The binary preserves the platform dependency floor.
#   3. Cross-compiles clean for x86_64-windows-msvc and x86_64-windows-gnu.
#   4. Failure proofs:
#      - Deadlock exits 1 naming deadlock rather than hanging.
#      - Interleaving assert is reachable (wrong expected order fails).
#      - IO cancellation assert is reachable (missing cancellation fails).
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
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

cd "$WORK" || exit 1

step() { echo "== $1"; }

# 1. Plain build
step "runtime exercise, plain build"
if ! "$IYI" build "$REPO/bench/runtime_exercise.iyi" -o exercise > build.log 2>&1; then
  echo "build failed:"
  cat build.log
  exit 1
fi
if ! ./exercise > answers.txt 2>&1; then
  echo "exercise failed:"
  cat answers.txt
  exit 1
fi
grep -q 'runtime exercise: every property held' answers.txt || { cat answers.txt; exit 1; }

# 2. Release build
step "runtime exercise, release build"
if ! "$IYI" build --release "$REPO/bench/runtime_exercise.iyi" -o exercise-release > build-release.log 2>&1; then
  echo "release build failed:"
  cat build-release.log
  exit 1
fi
if ! ./exercise-release > answers-release.txt 2>&1; then
  echo "release exercise failed:"
  cat answers-release.txt
  exit 1
fi
grep -q 'runtime exercise: every property held' answers-release.txt || { cat answers-release.txt; exit 1; }

# 3. Windows cross-compilation
step "runtime exercise, cross-compilation to x86_64-windows-msvc"
if ! "$IYI" build --cross-compile --target x86_64-windows-msvc "$REPO/bench/runtime_exercise.iyi" -o runtime-msvc.obj > msvc.log 2>&1; then
  echo "cross-compile to msvc failed:"
  cat msvc.log
  exit 1
fi

step "runtime exercise, cross-compilation to x86_64-windows-gnu"
if ! "$IYI" build --cross-compile --target x86_64-windows-gnu "$REPO/bench/runtime_exercise.iyi" -o runtime-gnu.o > gnu.log 2>&1; then
  echo "cross-compile to gnu failed:"
  cat gnu.log
  exit 1
fi

# 4. Dependency floor
step "dependency floor: runtime stays on platform doorway"
case "$(uname -s)" in
  Darwin)
    allowed='___error|__tlv_bootstrap|_backtrace|_backtrace_symbols_fd|_madvise|_pipe|_pthread_create|_pthread_kill|_sigaction|_sigaltstack|_sysctlbyname|__dyld_get_image_header|__dyld_get_image_vmaddr_slide|_clock_gettime_nsec_np|_exit|_kevent|_kqueue|_malloc|_memset|_mmap|_mprotect|_munmap|_pipe|_pthread_get_stackaddr_np|_pthread_self|_read|_realloc|_write'
    added="$(nm -u exercise | sed -e 's/^ *//' | awk '{ print $NF }' |
      grep -E -cv "^($allowed)\$")"
    extra_libs="$(otool -L exercise | sed -n '2,$p' | awk '{ print $1 }' |
      grep -cv 'libSystem')"
    if [ "$added" -ne 0 ] || [ "$extra_libs" -ne 0 ]; then
      echo "the runtime moved the darwin floor:"
      nm -u exercise
      otool -L exercise
      exit 1
    fi
    ;;
  *)
    added="$(nm -u exercise |
      sed -e 's/^ *[wU] *//' -e 's/@.*$//' |
      grep -v -E '^(_ITM_deregisterTMCloneTable|_ITM_registerTMCloneTable|__cxa_finalize|__gmon_start__|__libc_start_main)$' |
      grep -cv '^\s*$')"
    if [ "$added" -ne 0 ]; then
      echo "the runtime put $added undefined symbols back on the link line:"
      nm -u exercise
      exit 1
    fi
    ;;
esac

# 5. Failure proof: deadlock
step "failure proof: deadlock is a diagnosis, not a hang"
cat > deadlock.iyi <<'IYI'
channel = Channel(Int32).new(1)
value = channel.receive
puts value.is_a?(Int32)
IYI
if ! "$IYI" build deadlock.iyi -o deadlock > build-deadlock.log 2>&1; then
  echo "deadlock probe failed to build:"
  cat build-deadlock.log
  exit 1
fi
set +e
./deadlock > deadlock.txt 2>&1
status=$?
set -e
if [ "$status" -ne 1 ]; then
  echo "a deadlocked program exited $status rather than 1:"
  cat deadlock.txt
  exit 1
fi
grep -q 'deadlock' deadlock.txt || { echo "died without naming the deadlock:"; cat deadlock.txt; exit 1; }

# 6. Failure proof: interleaving assert can fail
step "failure proof: a wrong interleaving order is refused"
sed 's/== "bababa"/== "aaabbb"/' "$REPO/bench/runtime_exercise.iyi" > misordered.iyi
if ! "$IYI" build misordered.iyi -o misordered > build-misordered.log 2>&1; then
  echo "misordered probe failed to build:"
  cat build-misordered.log
  exit 1
fi
set +e
./misordered > misordered.txt 2>&1
status=$?
set -e
if [ "$status" -ne 1 ] || ! grep -q 'FAIL: interleaving' misordered.txt; then
  echo "the interleaving assert cannot fail, so it checks nothing:"
  cat misordered.txt
  exit 1
fi

# 7. Failure proof: IO cancellation assert can fail
step "failure proof: an uncaught IO block fails rather than silently passing"
sed 's/outcome.is_a?(Cancelled) ? "cancelled" : "read"/outcome.is_a?(Cancelled) ? "bogus" : "read"/' "$REPO/bench/runtime_exercise.iyi" > uncancelled.iyi
if ! "$IYI" build uncancelled.iyi -o uncancelled > build-uncancelled.log 2>&1; then
  echo "uncancelled probe failed to build:"
  cat build-uncancelled.log
  exit 1
fi
set +e
./uncancelled > uncancelled.txt 2>&1
status=$?
set -e
if [ "$status" -ne 1 ] || ! grep -q 'FAIL: cancellation never reached the IO-blocked task' uncancelled.txt; then
  echo "the IO cancellation assert cannot fail:"
  cat uncancelled.txt
  exit 1
fi

echo "workdir $WORK"
echo "runtime gate: every step held"
exit 0
