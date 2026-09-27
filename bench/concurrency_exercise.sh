#!/usr/bin/env bash
# Drives bench/concurrency_exercise.iyi: the concurrency runtime's gate
# (SPEC.md III.4, built in III.4.8's order).
#
#     bash bench/concurrency_exercise.sh
#
# Five steps, and the last three are failure proofs, because a gate that
# cannot fail is not a gate:
#
#   1. The exercise holds every asserted property, plain and --release —
#      the release arm is not decoration: the context switch is naked asm,
#      and the optimiser is the thing that corrupted it until @[NoInline]
#      said not to. And a fiber reading stdin parks, and is cancelled
#      there (bench/stdin_park.iyi, fed by a pipe), which a read made the
#      blocking call it was is refused for.
#   2. The binary keeps the dependency floor (III.9): on Linux the runtime
#      is raw syscalls and must add zero undefined symbols; on darwin the
#      floor is libSystem and nothing else, held as the exact symbol list;
#      on Windows it is kernel32 and the C runtime's DLLs, read off the
#      import table with dumpbin.
#   3. A deadlocked program — every fiber blocked, nothing to wake one —
#      exits 1 with the deadlock named, rather than hanging.
#   4. A group whose spelling would compile sequentially still interleaves:
#      step 1's first property, called out because III.4.8 refused the
#      sequential imitation by name; this step proves the check *can* fail
#      by asserting the exercise's own assert is reachable (a wrong
#      expected order exits 1).
#   5. On Windows, the switch's xmm6-xmm15 restore taken out of a copy of
#      the runtime fails the exercise's doubles check by name, in the
#      --release build that keeps doubles in those registers.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# the wrapper in bin is a posix shell script, so a caller that already has a
# compiler of its own names it through the environment.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a program
# built into a scratch directory named `/tmp/tmp.X` is named by a path it
# cannot read.
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

. "$REPO/bench/floor_base.sh"

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

# ── 1b. A fiber reading stdin parks, and is cancelled there ───────────────
# bench/stdin_park.iyi, fed by a pipe that answers a second after the
# program has started and again two seconds later. On Windows the read is a
# thread's of its own (`IyiStdinReader`); here, it was the program's
# thread's, and the proof below puts that back.
step "a fiber reading stdin parks, and is cancelled there"
if ! "$IYI" build "$REPO/bench/stdin_park.iyi" -o stdin_park > build-stdin.log 2>&1; then
  echo "stdin exercise failed to build:"
  tail -5 build-stdin.log
  exit 1
fi
feed() { # the lines, once the program has said it runs
  local tries=0
  while [ ! -e "$1" ] && [ "$tries" -lt 600 ]; do sleep 0.05; tries=$((tries + 1)); done
  sleep 1; echo first; sleep 2; echo second
}
rm -f stdin.ready
feed stdin.ready | STDIN_PARK_READY=stdin.ready timeout -k 5 60 ./stdin_park > stdin.txt 2>&1
if ! grep -q 'every property held' stdin.txt; then
  echo "stdin exercise failed:"
  cat stdin.txt
  exit 1
fi
sed 's/^/  /' stdin.txt | grep -v 'every property held'

step "failure proof: a stdin read that holds the thread is refused"
mkdir -p blocking/iyi
cp "$REPO"/src/iyi/*.iyi blocking/iyi/
sed 's/^        outcome = iyi_read(0, buffer, count)$/        outcome = __iyi_read(0, buffer, count)/' \
  "$REPO/src/iyi/io.iyi" > blocking/iyi/io.iyi
if [ "$(diff "$REPO/src/iyi/io.iyi" blocking/iyi/io.iyi | grep -c '^>')" -lt 1 ]; then
  echo "the sed found no stdin read to make blocking"
  exit 1
fi
if ! IYI_PATH="$WORK/blocking${PSEP}$REPO/src" "$IYI" build "$REPO/bench/stdin_park.iyi" -o stdin_blocking > build-blocking.log 2>&1; then
  echo "the blocking copy failed to build:"
  tail -5 build-blocking.log
  exit 1
fi
rm -f blocking.ready
feed blocking.ready | STDIN_PARK_READY=blocking.ready timeout -k 5 60 ./stdin_blocking > stdin-blocking.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q 'held the thread' stdin-blocking.txt; then
  echo "a stdin read that holds the thread was not refused (exit $code):"
  cat stdin-blocking.txt
  exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 'held the thread' stdin-blocking.txt | sed 's/^FAIL: //')"

# ── 2. The dependency floor ───────────────────────────────────────────────
# On Linux the five allowed names are the C runtime template's, not the
# prelude's — bench/dependency_floor.sh spells out why — and the runtime is
# raw syscalls, so it may add nothing beyond them. On darwin every call is
# a libSystem symbol by design (III.9: raw syscalls are not a stable ABI
# there), so the floor is the exact list below plus libSystem as the one
# linked library; a new name is a dependency being taken on and belongs in
# this list in the commit that causes it.
step "dependency floor: the runtime stays on the platform's own doorway"
# A floor counted with a reader that is not installed is not a floor at all:
# `nm -u` in a shell with no `nm` prints nothing, the count comes out zero,
# and that reads as the floor holding. The reader is resolved first, and an
# absent one is named rather than counted.
NM=""
command -v nm >/dev/null 2>&1 && NM=nm
unmeasured=0
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # A PE leaves nothing undefined: what the runtime asks of Windows is the
    # DLLs the exercise imports, read with the toolchain's own `dumpbin`
    # (bench/floor_base.sh). The runtime's doorway is kernel32 and the C
    # runtime's DLLs; a socket or entropy DLL here would be a module the
    # exercise does not import taking one on.
    DUMPBIN="$(find_dumpbin || true)"
    if [ -z "$DUMPBIN" ]; then
      echo "no dumpbin here, so the import floor is not measured"
      unmeasured=$((unmeasured + 1))
    else
      dlls="$(pe_dlls exercise.exe)"
      if [ -z "$dlls" ]; then
        echo "dumpbin read no import table out of the exercise, so the floor was not measured"
        exit 1
      fi
      extra="$(extra_dlls "$FLOOR_DLLS_RUNTIME" "$dlls")"
      if [ -n "$extra" ]; then
        echo "the runtime moved the Windows floor: the exercise imports $(echo $extra)"
        exit 1
      fi
      echo "  imports: $(echo $dlls)"
    fi
    NM=""
    ;;
esac
if [ -z "$NM" ]; then
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
    *)
      echo "no nm here, so the symbol floor is not measured"
      unmeasured=$((unmeasured + 1))
      ;;
  esac
else
  case "$(uname -s)" in
    Darwin)
      allowed='___error|__tlv_bootstrap|_backtrace|_backtrace_symbols_fd|_madvise|_pipe|_pthread_create|_pthread_kill|_sigaction|_sigaltstack|_sysctlbyname|__dyld_get_image_header|__dyld_get_image_vmaddr_slide|_clock_gettime_nsec_np|_exit|_kevent|_kqueue|_malloc|_memset|_mmap|_mprotect|_munmap|_pipe|_pthread_get_stackaddr_np|_pthread_self|_read|_realloc|_write'
      added="$("$NM" -u exercise | sed -e 's/^ *//' | awk '{ print $NF }' |
        grep -E -cv "^($allowed)\$")"
      extra_libs="$(otool -L exercise | sed -n '2,$p' | awk '{ print $1 }' |
        grep -cv 'libSystem')"
      if [ "$added" -ne 0 ] || [ "$extra_libs" -ne 0 ]; then
        echo "the runtime moved the darwin floor:"
        "$NM" -u exercise
        otool -L exercise
        exit 1
      fi
      ;;
    *)
      added="$("$NM" -u exercise |
        sed -e 's/^ *[wU] *//' -e 's/@.*$//' |
        grep -v -E '^(_ITM_deregisterTMCloneTable|_ITM_registerTMCloneTable|__cxa_finalize|__gmon_start__|__libc_start_main)$' |
        grep -cv '^\s*$')"
      if [ "$added" -ne 0 ]; then
        echo "the runtime put $added undefined symbols back on the link line:"
        "$NM" -u exercise
        exit 1
      fi
      ;;
  esac
fi

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

# ── 5. Failure proof: the switch keeps xmm6-xmm15, on Windows ────────────
# Only Windows x64 keeps vector registers across a call among the
# platforms this runs on - the SysV convention keeps none, and aarch64's
# d8-d15 are a different arm of the switch - so only there is there a
# restore to take out. The frame keeps its size, so a fresh fiber still
# starts; the registers simply come back as whatever the other fiber left.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    step "failure proof: a switch that drops xmm6-xmm15 is caught"
    mkdir -p dropped/iyi
    cp -R "$REPO/src/iyi/." dropped/iyi/
    awk '/^         movups [0-9]+\(%rsp\), %xmm[0-9]+$/ { found = found + 1; next } { print }
         END { if (found != 10) exit 3 }' \
      "$REPO/src/iyi/concurrency.iyi" > dropped/iyi/concurrency.iyi
    if [ $? -ne 0 ]; then
      echo "the ten restores this proof removes are not in the switch any more; update the proof"
      exit 1
    fi
    if ! IYI_PATH="$WORK/dropped;$REPO/src" "$IYI" build --release "$REPO/bench/concurrency_exercise.iyi" \
         -o dropped-exercise > build-dropped.log 2>&1; then
      echo "the patched runtime did not build:"
      tail -5 build-dropped.log
      exit 1
    fi
    timeout 60 ./dropped-exercise > dropped.txt 2>&1
    if [ $? -ne 1 ] || ! grep -q 'FAIL: switch' dropped.txt; then
      echo "a switch without its xmm restores passed the doubles check, so it checks nothing:"
      tail -5 dropped.txt
      exit 1
    fi
    echo "  caught: $(grep -m1 'FAIL: switch' dropped.txt)"
    ;;
  *)
    step "failure proof: a switch that drops xmm6-xmm15 is caught: not here, because this platform's calling convention keeps no xmm register across a call"
    ;;
esac

echo "workdir $WORK"
# A summary may not claim more than was measured, so a step whose reader was
# missing is named here rather than folded into the pass.
if [ "$unmeasured" -gt 0 ]; then
  echo "concurrency gate: every step held, with $unmeasured not measured here"
else
  echo "concurrency gate: every step held"
fi
exit 0
