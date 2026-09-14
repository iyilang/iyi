#!/usr/bin/env bash
# Drives bench/thread_floor.iyi: what a kernel thread, and a stop-the-world
# over kernel threads, cost the dependency floor (SPEC.md III.9) — measured
# before the design that needs them (GC_DESIGN.md Stages 4, 7, 8, 9;
# SPEC.md III.4.7's `Share`) is written.
#
#     bash bench/thread_floor.sh
#
# Seven steps, and the last four are failure proofs, because a gate that
# cannot fail is not a gate:
#
#   1. The program holds every property, plain and --release (and on darwin
#      the three refused variants, release): N threads,
#      each with a tid of its own and a thread-local block of its own;
#      every one stopped where it ran by a signal and a handler that read
#      the thread's sp and pc out of the context and found the sp on that
#      thread's stack, released by one wake; every one joined; every
#      `@[ThreadLocal]` slot still its owner's at the end; the one word
#      every thread added to holding exactly the sum of their own.
#   2. The binary keeps the floor. This is the measurement the file exists
#      for, and it is asserted, not printed. On Linux: the runtime's five
#      C-template names and nothing else — a thread by raw `clone` adds no
#      symbol, a thread-local variable adds no `__tls_get_addr`, and the
#      prelude's `Atomic(T)` adds no `__atomic_*`. On darwin, where
#      III.9's rule is that every call is libSystem's: the exact list
#      below, which is the runtime's names plus what a thread costs there,
#      spelled out one by one.
#   3. The pause, by thread count, printed from real runs, and what one
#      touch of a `@[ThreadLocal]` costs against a plain class variable.
#      Reported rather than budgeted: a budget would be a number this
#      script made up, and the shape (how it scales past the core count)
#      is the finding.
#   4. The ran-its-loop assertion is reachable: a thread that counts into
#      the wrong word exits 1 at that check's own name.
#   5. The thread-local assertion is reachable. On Linux, `clone` without
#      CLONE_SETTLS leaves every thread on the main thread's block. On
#      darwin dyld lays the block out and there is no bit to drop, so the
#      `@[ThreadLocal]` annotation itself is dropped instead: the slots
#      become one thread's class variables and clash. Either way the
#      program exits 1 naming the thread-local that was not.
#   6. The held-context assertion is reachable: the context's sp read at
#      the pc's offset is not on any thread's stack, and the program exits
#      1 counting the handlers that read it.
#   7. The atomic is doing the counting: with a load and a store in place
#      of the prelude's `Atomic(UInt64).add` on the one word every thread
#      adds to, the sum comes up short and the program exits 1 naming how
#      many updates it lost.
#
# Linux x86_64 and aarch64, darwin aarch64.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"

cd "$WORK" || exit 1

step() { echo "== $1"; }

case "$(uname -s)" in
  Linux) cores="$(nproc)" ;;
  Darwin) cores="$(sysctl -n hw.ncpu)" ;;
  *)
    echo "thread floor: measured on Linux and darwin; nothing to measure here"
    exit 0
    ;;
esac

# ── 1. The program, twice ─────────────────────────────────────────────────
step "thread floor, plain build"
if ! "$IYI" build "$REPO/bench/thread_floor.iyi" -o floor > build.log 2>&1; then
  cat build.log; exit 1
fi
if ! timeout 60 ./floor 4 100 > answers.txt 2>&1; then
  cat answers.txt; exit 1
fi
grep -q 'every property held' answers.txt || { cat answers.txt; exit 1; }

step "thread floor, release build"
if ! "$IYI" build --release "$REPO/bench/thread_floor.iyi" -o floor-release > build-release.log 2>&1; then
  cat build-release.log; exit 1
fi
if ! timeout 60 ./floor-release 4 100 > answers-release.txt 2>&1; then
  cat answers-release.txt; exit 1
fi
grep -q 'every property held' answers-release.txt || { cat answers-release.txt; exit 1; }

# darwin has the alternatives it measured and refused, each a flag: two
# other parks (`-Dtf_park_lock`, `-Dtf_park_sigsuspend`) and a second stop
# (`-Dtf_mach`, Mach's thread_suspend and thread_get_state in place of a
# signal). Built and held to their own lists so the comparison in step 3
# stays reproducible.
if [ "$(uname -s)" = Darwin ]; then
  for variant in park_lock park_sigsuspend mach; do
    step "thread floor, release build, -Dtf_$variant"
    if ! "$IYI" build --release "-Dtf_$variant" "$REPO/bench/thread_floor.iyi" -o "floor-$variant" > "build-$variant.log" 2>&1; then
      cat "build-$variant.log"; exit 1
    fi
    if ! timeout 60 "./floor-$variant" 4 100 > "answers-$variant.txt" 2>&1; then
      cat "answers-$variant.txt"; exit 1
    fi
    grep -q 'every property held' "answers-$variant.txt" || { cat "answers-$variant.txt"; exit 1; }
  done
fi

# ── 2. The floor ──────────────────────────────────────────────────────────
case "$(uname -s)" in
  Linux)
    # The same five names bench/concurrency_exercise.sh allows, for the
    # same reason: they are crt1.o's, not the program's. `clone`, `futex`,
    # `tgkill`, `rt_sigaction` and `gettid` are syscalls here and appear
    # as nothing.
    step "dependency floor: a thread without pthreads adds no symbol"
    for bin in floor floor-release; do
      added="$(nm -u "$bin" |
        sed -e 's/^ *[wU] *//' -e 's/@.*$//' |
        grep -v -E '^(_ITM_deregisterTMCloneTable|_ITM_registerTMCloneTable|__cxa_finalize|__gmon_start__|__libc_start_main)$' |
        grep -cv '^\s*$')"
      if [ "$added" -ne 0 ]; then
        echo "$bin put $added undefined symbols on the link line:"
        nm -u "$bin"
        exit 1
      fi
    done
    echo "  five template names and nothing else, plain and release"
    ;;
  Darwin)
    # The exact list, held the way bench/concurrency_exercise.sh holds the
    # exercise's. Twelve names are every darwin program's (the runtime's
    # list in bench/dependency_floor.sh). Eight are what a thread costs,
    # and each one is a dependency taken on by name:
    #   pthread_create, pthread_join, pthread_kill   the thread
    #   pthread_threadid_np                          its id, both views
    #   sigaction                                    the stop
    #   pipe, read                                   the park: a handler
    #       blocked in `read`, which POSIX promises a handler may call
    #   __tlv_bootstrap                              a @[ThreadLocal]: the
    #       thunk in every Mach-O thread-local descriptor, which dyld
    #       rebinds to its own tlv_get_addr at load
    # The release build once carried one more, `bzero`: the compiler zeroes
    # every `Pointer.malloc` with an `llvm.memset`, and the aarch64 back end
    # lowers a memset it will not inline to a `bzero` call. The prelude
    # defines `bzero` now, the way it defines `memset`, so the name resolves
    # to the program's own and the release list is the plain list.
    step "dependency floor: what a thread costs darwin, by name"
    # `_read` is the runtime's now, not only this probe's: since thread.iyi
    # every darwin program can park for a collection's stop, and the park
    # is a read on a pipe, reachable from the runtime lock's spin in every
    # build the optimiser cannot fold — including the refused variants,
    # which park their own threads differently but carry the runtime's.
    # `_pipe`, `_pthread_create`, `_pthread_kill`, `_sigaction` and
    # `_sysctlbyname` are the runtime's too: the parallel marker starts
    # its helpers as kernel threads sized by `hw.ncpu`, and the concurrent
    # mark's second stop registers the main thread, whose park is a pipe,
    # installs the stop's handler and signals with `pthread_kill`. The
    # refused variants carry them for the same reason - the Mach one
    # included, whose own stop never signals - so the five sit in the
    # runtime's list, not the probe's.
    runtime='___error __dyld_get_image_header __dyld_get_image_vmaddr_slide _clock_gettime_nsec_np _exit _kevent _kqueue _madvise _mmap _munmap _pipe _pthread_create _pthread_get_stackaddr_np _pthread_kill _pthread_self _read _sigaction _sigaltstack _sysctlbyname _write'
    thread='__tlv_bootstrap _pthread_join _pthread_threadid_np'
    # The refused parks: the lock's two calls in place of `pipe` and `read`,
    # and `sigsuspend` alone in their place. The Mach stop swaps the stop
    # and park names for four of its own:
    #   pthread_mach_thread_np                       the thread's port
    #   thread_suspend, thread_resume                the stop
    #   thread_get_state                             the registers, read held
    park_lock='__tlv_bootstrap _os_unfair_lock_lock _os_unfair_lock_unlock _pthread_join _pthread_threadid_np'
    park_sigsuspend='__tlv_bootstrap _pthread_join _pthread_threadid_np _sigsuspend'
    mach='__tlv_bootstrap _pthread_join _pthread_mach_thread_np _pthread_threadid_np _thread_get_state _thread_resume _thread_suspend'
    printf '%s\n' $runtime $thread | LC_ALL=C sort > expected-floor.txt
    printf '%s\n' $runtime $thread | LC_ALL=C sort > expected-floor-release.txt
    printf '%s\n' $runtime $park_lock | LC_ALL=C sort > expected-floor-park_lock.txt
    printf '%s\n' $runtime $park_sigsuspend | LC_ALL=C sort > expected-floor-park_sigsuspend.txt
    printf '%s\n' $runtime $mach | LC_ALL=C sort > expected-floor-mach.txt
    for bin in floor floor-release floor-park_lock floor-park_sigsuspend floor-mach; do
      nm -u "$bin" | sed -e 's/^ *//' | awk '{ print $NF }' | LC_ALL=C sort > "found-$bin.txt"
      if ! diff "expected-$bin.txt" "found-$bin.txt" > "diff-$bin.txt"; then
        echo "$bin moved the darwin floor (< expected, > found):"
        cat "diff-$bin.txt"
        exit 1
      fi
      extra_libs="$(otool -L "$bin" | sed -n '2,$p' | awk '{ print $1 }' | grep -cv 'libSystem')"
      if [ "$extra_libs" -ne 0 ]; then
        echo "$bin links something besides libSystem:"
        otool -L "$bin"
        exit 1
      fi
    done
    echo "  the runtime's thirteen names, the thread's seven, libSystem alone, plain and release; each refused variant to its own list"
    ;;
esac

# ── 3. The pause, by count ────────────────────────────────────────────────
step "stop-the-world by thread count, release build ($cores cores here)"
for count in 1 4 8 16 64; do
  echo "  $count threads:"
  timeout 120 ./floor-release "$count" 200 | grep -E '^  (stop|resume)' | sed 's/^/  /'
done
if [ "$(uname -s)" = Darwin ]; then
  # The refused variants, same table up to the core count — the regime the
  # design lives in; past it every one of them is the quantum, and the
  # 16- and 64-thread rows are in CHANGELOG.md. The two parks resume a
  # little faster (the lock) or slower (sigsuspend, a second kill loop)
  # than the pipe; the Mach stop loses at every count. Printed so each of
  # those stays a measurement.
  for variant in park_lock park_sigsuspend mach; do
    step "the same, -Dtf_$variant"
    for count in 1 4 8; do
      echo "  $count threads:"
      timeout 120 "./floor-$variant" "$count" 200 | grep -E '^  (stop|resume)' | sed 's/^/  /'
    done
  done
fi
# And what the cutover's spelling costs: one read-modify-write of a
# `@[ThreadLocal]` against one of a plain class variable, in the release
# build, printed for the same reason the pauses are; and the contended
# `Atomic(UInt64).add` every thread ran on one word, none lost.
grep -E '^(touch|atomic):' answers-release.txt | sed 's/^/  /'

# ── 4. Failure proof: the ran-its-loop assertion is reachable ─────────────
# A thread that counts into the wrong word looks alive to every earlier
# step — it has a tid, it stops, it resumes, it joins — and is caught by
# the last check by name. The earlier checks cannot be made to fire by a
# one-word edit that leaves the threads real, which is the point of them.
step "failure proof: a thread that never counted is refused"
sed 's/__tf_add(line + 16_u64, 1_u64)/__tf_add(line + 24_u64, 1_u64)/' \
  "$REPO/bench/thread_floor.iyi" > idle.iyi
grep -q 'line + 24_u64' idle.iyi || { echo "the sed found nothing to change"; exit 1; }
if ! "$IYI" build idle.iyi -o idle > build-idle.log 2>&1; then
  cat build-idle.log; exit 1
fi
timeout 60 ./idle 2 10 > idle.txt 2>&1
if [ $? -ne 1 ] || ! grep -q "never ran its loop" idle.txt; then
  echo "the loop check did not fire:"; cat idle.txt; exit 1
fi

# ── 5. Failure proof: the thread-local assertion is reachable ─────────────
step "failure proof: threads sharing one thread-local block are refused"
case "$(uname -s)" in
  Linux)
    # The one flag bit, dropped from the constant and from both arms' asm
    # immediates: every thread then inherits the parent's thread pointer
    # and shares its block, so the slots clash and the program says whose.
    sed 's/012d/0125/g' "$REPO/bench/thread_floor.iyi" > shared.iyi
    [ "$(grep -c '0125' shared.iyi)" -ge 3 ] || { echo "the sed found nothing to change"; exit 1; }
    ;;
  Darwin)
    # No bit to drop: dyld lays the block out for every pthread. What can
    # be dropped is the annotation, and then the slot, the seed and the
    # line are one thread's class variables that every thread writes. With
    # the line shared, every handler parks on one thread's pipe and only
    # one byte ever reaches it, so the program would hang before it could
    # name the clash; the lock park releases every lock whoever holds it,
    # and is what this proof builds with — the proof is about the
    # thread-local, not the park.
    sed '/@\[ThreadLocal\]/d' "$REPO/bench/thread_floor.iyi" > shared.iyi
    [ "$(grep -c '@\[ThreadLocal\]' "$REPO/bench/thread_floor.iyi")" -ge 3 ] || { echo "the sed found nothing to change"; exit 1; }
    shared_flags="-Dtf_park_lock"
    ;;
esac
if ! "$IYI" build ${shared_flags:-} shared.iyi -o shared > build-shared.log 2>&1; then
  cat build-shared.log; exit 1
fi
timeout 60 ./shared 2 10 > shared.txt 2>&1
if [ $? -ne 1 ] || ! grep -q "thread-local" shared.txt; then
  echo "the thread-local check did not fire:"; cat shared.txt; exit 1
fi

# ── 6. Failure proof: the held-context assertion is reachable ─────────────
# One offset moved by a word, so the handler reads pc where it expects sp:
# a code address is on no thread's stack, and every handler says so.
step "failure proof: a handler reading the wrong register is refused"
sed -e 's/TF_UC_SP = 160_u64/TF_UC_SP = 168_u64/' -e 's/TF_UC_SP = 432_u64/TF_UC_SP = 440_u64/' \
    -e 's/TF_MC_SP = 264_u64/TF_MC_SP = 272_u64/' "$REPO/bench/thread_floor.iyi" > astray.iyi
cmp -s astray.iyi "$REPO/bench/thread_floor.iyi" && { echo "the sed found nothing to change"; exit 1; }
if ! "$IYI" build astray.iyi -o astray > build-astray.log 2>&1; then
  cat build-astray.log; exit 1
fi
timeout 60 ./astray 2 10 > astray.txt 2>&1
if [ $? -ne 1 ] || ! grep -q "was not their thread's stack" astray.txt; then
  echo "the held-context check did not fire:"; cat astray.txt; exit 1
fi

# ── 7. Failure proof: the atomic is what keeps the shared count ──────────
# The counters are the prelude's `Atomic(UInt64)` (step 2 is what proves
# that costs no name). Under `-Dtf_plain_add` the shared word's add is a
# load and a store instead, and with threads on more than one core the
# sum comes up short: the program names the word and how many updates it
# lost. The atomic contract, refused by its own removal.
step "failure proof: a load-and-store in the atomic's place loses updates"
if ! "$IYI" build --release -Dtf_plain_add "$REPO/bench/thread_floor.iyi" -o plain-add > build-plain-add.log 2>&1; then
  cat build-plain-add.log; exit 1
fi
timeout 60 ./plain-add 4 20 > plain-add.txt 2>&1
if [ $? -ne 1 ] || ! grep -q "updates were lost" plain-add.txt; then
  echo "the shared-counter check did not fire:"; cat plain-add.txt; exit 1
fi

echo "workdir $WORK"
echo "thread floor: every step held"
exit 0
