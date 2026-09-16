#!/usr/bin/env bash
# Drives bench/concurrency_exercise.iyi: the concurrency runtime's gate
# (SPEC.md III.4, built in III.4.8's order).
#
#     bash bench/concurrency_exercise.sh
#
# Four steps, and the last two are failure proofs, because a gate that
# cannot fail is not a gate:
#
#   1. The exercise holds every asserted property, plain and --release —
#      the release arm is not decoration: the context switch is naked asm,
#      and the optimiser is the thing that corrupted it until @[NoInline]
#      said not to.
#   2. The binary keeps the dependency floor (III.9): on Linux the runtime
#      is raw syscalls and must add zero undefined symbols; on darwin the
#      floor is libSystem and nothing else, held as the exact symbol list.
#   3. A deadlocked program — every fiber blocked, nothing to wake one —
#      exits 1 with the deadlock named, rather than hanging.
#   4. A group whose spelling would compile sequentially still interleaves:
#      step 1's first property, called out because III.4.8 refused the
#      sequential imitation by name; this step proves the check *can* fail
#      by asserting the exercise's own assert is reachable (a wrong
#      expected order exits 1).
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"

cd "$WORK" || exit 1

step() { echo "== $1"; }

# ── 1. The exercise, twice ────────────────────────────────────────────────
step "exercise, plain build"
if ! "$IYI" build "$REPO/bench/concurrency_exercise.iyi" -o exercise > build.log 2>&1; then
  echo "build failed:"
  tail -5 build.log
  exit 1
fi
if ! timeout 60 ./exercise > answers.txt 2>&1; then
  echo "exercise failed:"
  cat answers.txt
  exit 1
fi
grep -q 'every property held' answers.txt || { cat answers.txt; exit 1; }

step "exercise, release build"
if ! "$IYI" build --release "$REPO/bench/concurrency_exercise.iyi" -o exercise-release > build-release.log 2>&1; then
  echo "release build failed:"
  tail -5 build-release.log
  exit 1
fi
if ! timeout 60 ./exercise-release > answers-release.txt 2>&1; then
  echo "release exercise failed:"
  cat answers-release.txt
  exit 1
fi
grep -q 'every property held' answers-release.txt || { cat answers-release.txt; exit 1; }

# ── 2. The dependency floor ───────────────────────────────────────────────
# On Linux the five allowed names are the C runtime template's, not the
# prelude's — bench/dependency_floor.sh spells out why — and the runtime is
# raw syscalls, so it may add nothing beyond them. On darwin every call is
# a libSystem symbol by design (III.9: raw syscalls are not a stable ABI
# there), so the floor is the exact list below plus libSystem as the one
# linked library; a new name is a dependency being taken on and belongs in
# this list in the commit that causes it.
step "dependency floor: the runtime stays on the platform's own doorway"
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

# ── 3. Failure proof: a deadlock dies loudly ──────────────────────────────
step "failure proof: deadlock is a diagnosis, not a hang"
cat > deadlock.iyi <<'IYI'
channel = Channel(Int32).new(1)
value = channel.receive
puts value.is_a?(Int32)
IYI
if ! "$IYI" build deadlock.iyi -o deadlock > build-deadlock.log 2>&1; then
  echo "deadlock probe failed to build:"
  tail -5 build-deadlock.log
  exit 1
fi
timeout 10 ./deadlock > deadlock.txt 2>&1
status=$?
if [ "$status" -ne 1 ]; then
  echo "a deadlocked program exited $status rather than 1 (124 is a hang):"
  cat deadlock.txt
  exit 1
fi
grep -q 'deadlock' deadlock.txt || { echo "died without naming the deadlock:"; cat deadlock.txt; exit 1; }

# ── 4. Failure proof: the interleaving assert is reachable ────────────────
step "failure proof: a wrong order is refused"
sed 's/== "bababa"/== "aaabbb"/' "$REPO/bench/concurrency_exercise.iyi" > misordered.iyi
if ! "$IYI" build misordered.iyi -o misordered > build-misordered.log 2>&1; then
  echo "misordered probe failed to build:"
  tail -5 build-misordered.log
  exit 1
fi
timeout 60 ./misordered > misordered.txt 2>&1
if [ $? -ne 1 ] || ! grep -q 'FAIL: interleaving' misordered.txt; then
  echo "the interleaving assert cannot fail, so it checks nothing:"
  cat misordered.txt
  exit 1
fi

echo "workdir $WORK"
echo "concurrency gate: every step held"
exit 0
