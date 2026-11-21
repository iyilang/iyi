#!/usr/bin/env bash
# Drives bench/thread_exercise.iyi: kernel threads under the collector —
# GC_DESIGN.md Stage 4, the stop-the-world, built (src/iyi/thread.iyi).
#
#     bash bench/thread_exercise.sh [again | but-again]
#
# With no argument every step runs. `again` runs the plain build's ten
# more runs of step 1 alone, and `but-again` every step but those, so a
# caller that bounds each gate can give the two halves a bound each:
# Windows' collector job does. On windows-2025's four cores the ten runs
# took 388 and 454 s of the whole's 802 s (job 128265739456) and of the
# 900 s at which its bound of 15 minutes ended it (job 128494833123).
#
# Seven steps, and the fifth and sixth are failure proofs, because a gate
# that cannot fail is not a gate; the seventh, Windows' own and one of
# darwin's, carries its own:
#
#   1. The program holds every property, plain and --release, with eight
#      threads: each allocates from its own cache while collections run
#      from whichever thread crosses the budget; each holds a live list in
#      nothing but its own frames through those collections and finds it
#      intact, by checksum and by the sweep's own free flag; each runs
#      fibers of its own, one parked holding an object's only reference;
#      collections stopped threads; and the program finishes, which is the
#      proof no stop deadlocked on the runtime lock or on a thread inside
#      the allocator. A joined thread keeps nothing its block captured, its
#      line is unmapped, and a second join of it returns at once.
#   2. The binary keeps the floor. On Linux the runtime's five C-template
#      names and nothing else: a thread by raw `clone`, a stop by `tgkill`
#      and `rt_sigaction`, a park by `futex`, all syscalls. On darwin the
#      exact list: the runtime's names plus what a thread costs there,
#      the thread floor's list, spelled out.
#   3. The numbers, printed from the release run: allocations per thread,
#      collections, stops, and the wall time per allocation per thread at
#      1, 4 and 8 threads. Reported rather than budgeted.
#   4. The same, twice the cores' worth of threads, release — past the core count —
#      because a thread stopped while it has no CPU is the case the
#      floor's table said costs the timeslice, and the properties must hold
#      there too.
#  4b. Four times the cores' threads taking the runtime lock in turn,
#      with the ratio to one thread reported, and three threads computing
#      on one processor, two of them kept off it, stopped by collections,
#      held on Windows to 60 ms a stop; with the suspends asked one at a
#      time, the stop check fails.
#  4c. On Windows held to one core, five threads start and are joined
#      beside a thread that collects in a loop, and beside one that takes
#      the runtime lock in a loop, each within 10 s. Copy-only controls
#      check the spinner's count and both collection yields separately.
#  4d. On Windows, a process one level above normal computes in bursts on
#      the stopping thread's processor while that thread collects in a
#      loop, and no more than three stops last past the bound; with the
#      stop's raise of its thread's priority taken out, stops last a
#      burst. A thread taking the runtime lock beside them allows at most
#      five waits past its bound; a copy-only counter detects a lock held
#      while the stopper lowers its priority inside the release. A panic inside a
#      stop puts the priority back; with `raise`'s lowering taken out,
#      the thread keeps it. Threads that raise together for collections,
#      crossing the budget at once or collecting at once, each put their
#      own back; with one record of the raise for them all, a thread
#      keeps it.
#   5. Failure proof: the thread-root walk removed from a copy of the
#      prelude, and a thread's list — reachable from its stopped frames
#      alone — is swept out from under it; the program exits 1 naming the
#      node on a free list.
#   6. Failure proof: a block that captures a value whose type is not
#      `Share` (SPEC.md III.4.4) does not compile, and the error names the
#      variable, its type and the field that made it mutable. Nor does a
#      captured local the thread's block assigns, or its starter assigns
#      after the start: one cell two threads write (6b). A String, and a
#      struct or `List` holding one, is captured and runs (6c). A constant
#      the block names is asked what a captured value is (6d).
#   7. On Windows, a program whose main thread ends while another thread's
#      collections stop it ends, two hundred runs of two hundred; and with
#      the end put back into the C runtime's `exit`, main's emitted IR
#      returns where it should end in `__iyi_exit`, which the check names
#      on the one build.
#  7c. On Windows, threads and their tasks grow fresh stacks while a thread
#      collects in a loop, and every run ends; with the stop's scan started
#      at sp again, inside the guard page, a run dies.
#  7d. On darwin, threads are born sixteen at a time beside a thread that
#      collects in a loop, for 10 s or 3,200 threads, and every one starts;
#      with a thread's line linked before its first touch of a thread-local
#      again, a run is killed.
#  7e. On darwin, a thread's first allocation held in its frame through two
#      collections is not swept; with its stack's top written after that
#      allocation again, a run aborts by name.
#  7f. On Linux and darwin, tasks begin on fresh stacks beside a thread that
#      collects in a loop, and each task's stack top is its own stack's to
#      the stop's scan; with a fiber's top read as no fiber's again, the
#      first task says so by name.
#  7g. On Linux and darwin, a mark helper that faults holding the runtime
#      lock kills the process with SIGSEGV; with the fault handler's
#      default action built in a heap block again, the process outlives
#      the fault.
#  7j. On darwin, a collection straight after a thread's start, before the
#      thread has linked its line, stops nobody and leaves the next stop
#      nothing to wait for; with the thread counted in `start` again, a
#      run hangs.
#  7k. On Linux, a program that calls C calls it from sixteen parallel
#      tasks and a started thread, through collections, and libc answers
#      each of them as its own thread; the binary names `pthread_create`
#      and `pthread_join`. With the compiler's answer replaced by a
#      `false`, the threads are raw clones again and a run dies or says so.
#
# Not forced (each is decided by a timeout, a timing bound or a schedule
# search, so the verdict is not a named invariant of the code under test):
#   4c   five threads started and joined beside a collecting or lock-taking
#        thread, held to 10 s: a healthy timing bound, unchanged.
#   4d   the no-raise timing mutant (a stop beside a burst with the raises
#        taken out): removed; its only verdict was a stop timing.
#   7d   unborn: the mutant's verdict is a schedule search for a collection
#        landing before a link, not forced.
#   7e   toplate: its healthy topfirst can pass without seeing two collections;
#        no witness added.
#   7h   unwoken: the mutant's verdict is the 30 s timeout (exit 124).
#   7h   Linux unowed: the mutant's verdict is exit 124 or a count of owed turns
#        in a timed storm.
#   7g   heaped: the healthy wild exits 3 if no fault has come by its deadline,
#        and no fault-handler witness is required.
#   The lock-order record (B6), the guard holder (B5), the release record (A2),
#   the stop-order record (4b) and the fixed-count burst (A1) are forced.
#
set -u

part="${1:-}"
case "$part" in
  "" | again | but-again) ;;
  *) echo "usage: bash bench/thread_exercise.sh [again | but-again]" >&2; exit 2 ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/end_process.sh"
# On Windows `timeout` is this bounded wait, not GNU timeout: GNU timeout ends
# an overrunning run through MSYS's exit_process_tree, which can end the runner
# agent (bench/end_process.sh). Here an overrun is ended by end_process and
# answers 124, as timeout does, and every other exit is the program's own. The
# step that runs it is the one that fails. Elsewhere it is GNU timeout.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # The end of an overrunning child is bounded by its own deadline, separate
    # from the child's bound. end_process runs in the background; a stalled end
    # is reported as a child that could not be recovered, and is not waited for.
    end_bounded() {
      local child="$1" killer deadline=$((SECONDS + 10))
      end_process "$child" KILL &
      killer=$!
      while kill -0 "$killer" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "FAIL: ${current_step:-bounded cleanup}: the child could not be recovered (pid $child)" >&2
          return 76
        fi
        sleep 0.1
      done
      if ! wait "$killer" 2>/dev/null; then
        # The child can exit between the launcher's liveness check and
        # end_process reading its PID. Reap that already-exited child.
        if ! kill -0 "$child" 2>/dev/null; then
          wait "$child" 2>/dev/null || true
          return 0
        fi
        echo "FAIL: ${current_step:-bounded cleanup}: the child could not be recovered (pid $child)" >&2
        return 76
      fi
      while kill -0 "$child" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "FAIL: ${current_step:-bounded cleanup}: the child could not be recovered (pid $child)" >&2
          return 76
        fi
        sleep 0.1
      done
      return 0
    }
    timeout() {
      local limit child deadline
      while [ "${1:-}" = -k ]; do shift 2; done
      limit="$1"; shift
      deadline=$((SECONDS + limit))
      "$@" &
      child=$!
      while kill -0 "$child" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "SETUP: ${current_step:-bounded run}: process exceeded its $limit s bound" >&2
          end_bounded "$child" || return 76
          return 76
        fi
        sleep 0.1
      done
      wait "$child"
    }
    ;;
esac
# The compiler, overridable: `bin/iyi` is a POSIX shell wrapper, and on
# Windows the caller is the only one who knows where the real binary is.
IYI="${IYI:-$REPO/bin/iyi}"
# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on the search path, so
# the patched copy is never read and the proof that a check can fail
# quietly stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

. "$REPO/bench/floor_base.sh"

cd "$WORK" || exit 1

current_step=""
step() {
  [ -z "$current_step" ] || printf '== end: %s\n' "$current_step"
  current_step="$1"
  printf '== start: %s\n' "$current_step"
}
trap 'status=$?; [ -z "$current_step" ] || printf "== end: %s (exit %s)\n" "$current_step" "$status"' EXIT

case "$(uname -s)" in
  Linux | Darwin | MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *)
    echo "thread exercise: measured on Linux, darwin and Windows; nothing to measure here"
    exit 0
    ;;
esac

# ── 1. The program, twice ─────────────────────────────────────────────────
step "threads under the collector, plain build"
if ! "$IYI" build "$REPO/bench/thread_exercise.iyi" -o threads > build.log 2>&1; then
  cat build.log; exit 1
fi
if [ "$part" != again ]; then
  if ! timeout -k 5 300 ./threads 8 > answers.txt 2>&1; then
    cat answers.txt; exit 1
  fi
  grep -q 'every property held' answers.txt || { cat answers.txt; exit 1; }

  step "threads under the collector, release build"
  if ! "$IYI" build --release "$REPO/bench/thread_exercise.iyi" -o threads-release > build-release.log 2>&1; then
    cat build-release.log; exit 1
  fi
  if ! timeout -k 5 300 ./threads-release 8 > answers-release.txt 2>&1; then
    cat answers-release.txt; exit 1
  fi
  grep -q 'every property held' answers-release.txt || { cat answers-release.txt; exit 1; }
fi

# The plain build, ten more times. A death here is a failure whatever it
# says: on a Windows runner the exercise died once in sixty of a guard-page
# violation in the collector (status 0x80000001) after it had printed its
# first line, so one run passing proved nothing. The registry check in
# the exercise is the deterministic half of the same fix; this is the
# half that turns the rare death into a red step.
if [ "$part" != but-again ]; then
  step "the plain build, ten more runs, and every one ends well"
  again=1
  while [ "$again" -le 10 ]; do
    timeout -k 5 300 ./threads 8 > again.txt 2>&1
    code=$?
    if [ "$code" -ne 0 ] || ! grep -q 'every property held' again.txt; then
      echo "run $again exited $code:"; tail -5 again.txt; exit 1
    fi
    again=$((again + 1))
  done
  echo "  ten of ten"
fi
if [ "$part" = again ]; then
  echo "workdir $WORK"
  echo "thread exercise: the plain build's ten more runs held"
  exit 0
fi

# ── 2. The floor ──────────────────────────────────────────────────────────
case "$(uname -s)" in
  Linux)
    step "dependency floor: threads and their stop add no symbol"
    for bin in threads threads-release; do
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
    # The runtime's list (bench/dependency_floor.sh), the concurrency
    # exercise's `mprotect` (a fiber stack's guard page), and the thread
    # floor's thread list: pthread_create, pthread_join, pthread_kill and
    # sigaction for the thread and the stop, whose park is the futex the
    # runtime's list already names, __tlv_bootstrap for the thread-locals,
    # and close for a finished thread's kqueue
    # (`IyiScheduler.retire_thread`). Nothing else.
    step "dependency floor: what threads cost darwin, by name"
    runtime='___error __dyld_get_image_header __dyld_get_image_vmaddr_slide __tlv_bootstrap _backtrace _backtrace_symbols_fd _clock_gettime_nsec_np _exit _kevent _kqueue _mmap _mprotect _munmap _os_sync_wait_on_address _os_sync_wake_by_address_all _pthread_create _pthread_get_stackaddr_np _pthread_self _sigaction _sigaltstack _sysctlbyname _thread_switch _write'
    thread='_close _pthread_create _pthread_join _pthread_kill'
    for bin in threads threads-release; do
      allowed="$(printf '%s\n' $runtime $thread | sort -u)"
      found="$(nm -u "$bin" | sed -e 's/^ *//' | awk '{ print $NF }' | sort -u)"
      extra="$(comm -13 <(echo "$allowed") <(echo "$found"))"
      if [ -n "$extra" ]; then
        echo "$bin asks libSystem for more than the list:"
        echo "$extra" | sed 's/^/  /'
        exit 1
      fi
      libs="$(otool -L "$bin" | sed -n '2,$p' | awk '{ print $1 }' | grep -v -E '^/usr/lib/libSystem' | grep -cv '^$')"
      if [ "$libs" -ne 0 ]; then
        echo "$bin links something beyond libSystem:"; otool -L "$bin"; exit 1
      fi
    done
    echo "  the runtime's names and the thread floor's, and nothing else"
    ;;
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # A PE leaves nothing undefined, so the floor is the DLLs a thread
    # program imports, read with the toolchain's own `dumpbin`: threads
    # and their stop are kernel32's (`CreateThread`, `SuspendThread`,
    # `GetThreadContext`), and nothing else may join the C runtime.
    step "dependency floor: threads and their stop add no DLL"
    DUMPBIN="$(find_dumpbin || true)"
    [ -n "$DUMPBIN" ] || { echo "no dumpbin here, and a machine that built these binaries has the toolchain that carries it"; exit 1; }
    for bin in threads threads-release; do
      dlls="$(pe_dlls "$bin.exe")"
      [ -n "$dlls" ] || { echo "dumpbin read no import table out of $bin"; exit 1; }
      extra="$(extra_dlls "$FLOOR_DLLS_RUNTIME" "$dlls")"
      if [ -n "$extra" ]; then
        echo "$bin imports $(echo $extra) beyond kernel32 and the C runtime"; exit 1
      fi
    done
    echo "  kernel32 and the C runtime's DLLs, plain and release"
    ;;
esac

# ── 3. The numbers ────────────────────────────────────────────────────────
cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")"
step "the numbers, release build ($cores cores here)"
grep -E '^(threads|speed):' answers-release.txt | sed 's/^/  /'

# ── 3b. Windows: the cores are the process's ──────────────────────────────
# The cores the marker sizes its helpers by were the machine's, whatever
# the affinity mask: a process held to one core (`start /affinity 1`) on
# twelve started eleven mark helpers, and eight allocating threads ran
# 3,077 ms against 178 with none. The mask's bits are counted now.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    step "the cores a process may run on are its affinity mask's"
    cat > cores.iyi <<'IYI'
puts "core_count=#{IyiThread.core_count} default_helpers=#{IyiMark.default_helpers}"
IYI
    if ! "$IYI" build cores.iyi -o cores > build-cores.log 2>&1; then
      cat build-cores.log; exit 1
    fi
    held() { MSYS2_ARG_CONV_EXCL='*' cmd /c "start /affinity $1 /b /wait cores.exe" | tr -d '\r'; }
    got="$(held 1)"
    [ "$got" = "core_count=1 default_helpers=0" ] || { echo "held to one core: $got"; exit 1; }
    if [ "${NUMBER_OF_PROCESSORS:-1}" -ge 2 ]; then
      got="$(held 3)"
      [ "$got" = "core_count=2 default_helpers=1" ] || { echo "held to two cores: $got"; exit 1; }
      echo "  held to one core it counts 1 and starts no helper; held to two, 2 and one"
    else
      echo "the affinity check requires at least two processors" >&2
      exit 1
    fi
    ;;
esac

# ── 4. Past the core count ────────────────────────────────────────────────
# Twice the cores, at least nine and at most 32: past the core count on
# any runner, and within a runner's patience - 32 threads on the darwin
# runner's three cores are a stop of 33 for every one of the three that
# can run, and the step outlived its five minutes there.
over=$((cores * 2))
[ "$over" -lt 9 ] && over=9
[ "$over" -gt 32 ] && over=32
step "the same, $over threads, release (past the $cores cores here)"
if ! timeout -k 5 300 ./threads-release "$over" > answers-32.txt 2>&1; then
  cat answers-32.txt; exit 1
fi
grep -q 'every property held' answers-32.txt || { cat answers-32.txt; exit 1; }
grep -E '^threads:' answers-32.txt | sed 's/^/  /'

# ── 4b. The runtime lock with four times the cores' threads, and the stop ─
# The lock only spun: a holder preempted with it waited out the spinners'
# timeslices, and 48 threads taking it on twelve cores took 30 to 35 times
# what one thread took for all of their turns (r2_alloc_threads: 64 threads
# allocating 1.8 to 20 s against 0.2 to 0.4 for twelve). It yields the core
# every 128th turn now: 1.3 to 1.5 times. That ratio was asserted, at 5,
# with a copy whose lock never gives its core away as the proof, and the
# bound is retired: what the copy measured was the spin's code shape, not
# its spinning. On mt/next the copy took 14.7 to 15.4 times one thread on
# Linux (12 vCPU) and on Windows 11, 12 logical processors (the user's
# machine), and 37 to 43 with the first turn's yield gone too; with the
# runtime lock's spin keeping a word for the turn a stop's release owes
# it (`IyiThread.owe_turn`), the same copy took 2.4 to 3.5 times on both,
# a copy with no yield and no count of spinners 1.8 to 2.1, one taking
# the lock by CAS of the whole word 2.0 - and the runtime's lock 2.0. Any
# one of the four lines that word adds to the lock's path took the first
# copy from 37 to between 5 and 7, with no stop in the run and an overlap
# count of holders at 0; holds of 500 and 2,000 increments showed nothing
# for any copy (1.1 to 2.1). A bound no broken lock can cross holds
# nothing, so the ratio is printed now and not asserted. What the yield
# is for is held where it shows: one core, a thread taking the lock in a
# loop, and threads starting beside it (4c), with its proof copy.
#
# And Windows' stop waited for each suspend before asking for the next, so
# a thread with no core held the stop until the scheduler ran it:
# collections beside 48 threads computing on twelve cores, half a second
# after they started, stopped them in 85 to 275 ms each, and in 0 to 13
# asked all at once. The stop is now measured with threads that have no
# core by construction (below). Asserted on Windows, where it was
# measured; printed everywhere.
cat > crowd.iyi <<'IYI'
@[Unsafe("on Windows the spinners pin and prioritize themselves through Windows' thread functions, a lib and C calls with pointerof answers")]
module crowd

class Counter
  getter value : Atomic(Int64)

  def initialize
    @value = Atomic(Int64).new(0_i64)
  end
end

class Flag
  getter stop : Atomic(Int64)
  getter held : Atomic(Int64)
  getter go : Atomic(Int64)
  getter burst : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @held = Atomic(Int64).new(0_i64)
    @go = Atomic(Int64).new(0_i64)
    @burst = Atomic(Int64).new(0_i64)
  end
end

{% if flag?(:win32) %}
  lib Placing
    fun SetThreadAffinityMask(thread : Void*, mask : UInt64) : UInt64
    fun SetThreadPriority(thread : Void*, priority : Int32) : Int32
    fun Sleep(milliseconds : UInt32) : Nil
  end
{% end %}

# The running thread held to the processors `mask` names, at Windows'
# `priority` (-2 lowest, 2 highest) with no boost above it; nothing
# elsewhere, where the stop is not asserted.
def hold(mask : UInt64, priority : Int32) : Nil
  {% if flag?(:win32) %}
    Placing.SetThreadAffinityMask(::LibC.GetCurrentThread, mask)
    Placing.SetThreadPriority(::LibC.GetCurrentThread, priority)
    ::LibC.SetThreadPriorityBoost(::LibC.GetCurrentThread, 1_i32)
  {% end %}
end

# The processors this process may run on, lowest first; one guessed bit
# outside Windows.
def processors : Array(UInt64)
  mask = 1_u64
  {% if flag?(:win32) %}
    system = 0_u64
    ::LibC.GetProcessAffinityMask(::LibC.GetCurrentProcess, pointerof(mask), pointerof(system))
  {% end %}
  bits = [] of UInt64
  bit = 1_u64
  while mask != 0_u64
    bits << bit if (mask & 1_u64) != 0_u64
    mask = mask.unsafe_shr(1_u64)
    bit = bit.unsafe_shl(1_u64)
  end
  bits
end

def hammer(counter : Counter, rounds : Int32) : Nil
  index = 0
  while index < rounds
    IyiRuntimeLock.lock
    hold = 0
    while hold < 50
      counter.value.add(1_i64)
      hold = hold + 1
    end
    IyiRuntimeLock.unlock
    index = index + 1
  end
end

def spin(flag : Flag) : Nil
  x = 0_i64
  while flag.stop.get == 0_i64
    x = x &+ 1
  end
end

# A thread on the shared processor below the one above it: `hold` moves it
# there before it lowers it, so it gets there while nothing above it is.
def spin_low(flag : Flag, mask : UInt64) : Nil
  hold(mask, -2_i32)
  flag.held.add(1_i64)
  spin(flag)
end

# The thread above the two low ones, moved there once they are: it
# computes 400 ms at a time, counting each start, and lets them run for a
# millisecond in between.
def spin_high(flag : Flag, mask : UInt64) : Nil
  while flag.go.get == 0_i64
    IyiThread.yield_cpu
  end
  hold(mask, 2_i32)
  flag.held.add(1_i64)
  while flag.stop.get == 0_i64
    flag.burst.add(1_i64)
    ends = IyiMark.now_ns + 400000000_u64
    while IyiMark.now_ns < ends && flag.stop.get == 0_i64
    end
    {% if flag?(:win32) %}
      Placing.Sleep(1_u32)
    {% end %}
  end
end

def fail(message : String) : Nil
  print "FAIL: #{message}\n"
  __iyi_exit(1)
end

{% if flag?(:win32) && flag?(:stop_order_force) %}
IyiThread.stop_order_reset
{% end %}
cores = IyiThread.core_count.to_i
crowd = cores * 4
crowd = 8 if crowd < 8
crowd = 64 if crowd > 64
rounds = 20000
counter = Counter.new
started = IyiMark.now_ns
hammer(counter, crowd * rounds)
alone = IyiMark.now_ns - started
started = IyiMark.now_ns
threads = [] of IyiThread
crowd.times { threads << IyiThread.start { hammer(counter, rounds); nil } }
threads.each { |thread| thread.join }
took = IyiMark.now_ns - started
puts "lock: #{crowd} threads taking the runtime lock on #{cores} cores took #{(took * 10_u64) // alone // 10_u64}.#{(took * 10_u64) // alone % 10_u64} times what one thread took for all their turns (printed, not bounded)"

# The stop, beside three threads that only compute on one processor, the
# stopping thread on another: one thread at Windows' highest priority,
# which computes 400 ms at a time, and two at its lowest, which it keeps
# off the processor. The stop walks the threads newest first and the high
# one is in the middle, so either way round a low one is asked first; and
# each collection starts as a run of the high one does. A stop asked all
# at once suspends the high thread at once, and the low ones take theirs
# the moment they run; one that waits for each suspend before asking for
# the next waits out the high thread's run for the first low one. Beside
# 48 threads with no such hold, on a Windows machine (Windows 11, 12
# logical processors), that stop stayed under 60 ms in 15 runs of 15 and
# the check could not tell it from a stop asked all at once.
cpus = processors
shared = cpus.last
hold(cpus.first, 0_i32)
flag = Flag.new
spinners = [] of IyiThread
spinners << IyiThread.start { spin_low(flag, shared) }
spinners << IyiThread.start { spin_high(flag, shared) }
spinners << IyiThread.start { spin_low(flag, shared) }
while flag.held.get < 2_i64
  IyiThread.yield_cpu
end
# On a machine of one processor, the stopping thread shares it, and stays
# level with the high thread, or that thread would hold it off as well.
hold(cpus.first, 2_i32) if cpus.size == 1
flag.go.set(1_i64)
while flag.held.get < 3_i64
  IyiThread.yield_cpu
end
stop_ns = IyiThread.stop_ns
stops = IyiThread.stops
5.times do
  burst = flag.burst.get
  while flag.burst.get == burst
    IyiThread.yield_cpu
  end
  IyiMark.collect
end
mean = (IyiThread.stop_ns - stop_ns) // (IyiThread.stops - stops)
flag.stop.set(1_i64)
spinners.each { |thread| thread.join }
{% if flag?(:win32) && flag?(:stop_order_force) %}
fail("stop: a context was captured before all suspend requests were issued") if IyiThread.stop_order_early?
fail("stop: no context capture was observed") unless IyiThread.stop_order_seen?
puts "stop: every suspend request preceded the first context capture"
{% end %}
puts "stop: five collections stopped #{spinners.size} threads that only compute, on one processor, in #{mean // 1000_u64} us each (measurement only)"
IYI
step "the runtime lock with four times the cores' threads, and the stop"
if ! "$IYI" build --release crowd.iyi -o crowd > build-crowd.log 2>&1; then
  cat build-crowd.log; exit 1
fi
if ! timeout -k 5 300 ./crowd > crowd.txt 2>&1; then
  cat crowd.txt; exit 1
fi
sed 's/^/  /' crowd.txt
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    cat > stop-order.part <<'IYI'
    IYI_STOP_ORDER_SEEN = 1408_u64
    IYI_STOP_ORDER_EARLY = 1472_u64
    def self.stop_order_reset : Nil
      word(control + IYI_STOP_ORDER_SEEN).value.set(0_u64)
      word(control + IYI_STOP_ORDER_EARLY).value.set(0_u64)
    end
    def self.stop_order_suspend(handle : Pointer(Void)) : Nil
      if LibC.SuspendThread(handle) < 0_i32
        message = "SETUP: stop: SuspendThread failed\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
    end
    def self.stop_order_observe(asked : Int64, expected : Int64, sp : UInt64) : Nil
      if sp == 0_u64
        message = "SETUP: stop: context capture returned no stack\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      page = control
      word(page + IYI_STOP_ORDER_SEEN).value.set(1_u64)
      word(page + IYI_STOP_ORDER_EARLY).value.set(1_u64) if asked < expected
    end
    def self.stop_order_seen? : Bool
      word(control + IYI_STOP_ORDER_SEEN).value.get != 0_u64
    end
    def self.stop_order_early? : Bool
      word(control + IYI_STOP_ORDER_EARLY).value.get != 0_u64
    end
IYI
    stop_order_copy() {
      awk -v part=stop-order.part -v mode="$1" '
        /^    # ── Roots/ { while ((getline s < part) > 0) print s; roots++ }
        /^      private def self\.suspend_others\(line : UInt64\) : Int64$/ { print; print "        stop_asked = 0_i64"; entry++; next }
        /^          LibC\.SuspendThread\(Pointer\(Void\)\.new\(IyiHeap\.read64\(cursor \+ IYI_TL_HANDLE\)\)\) if cursor != line$/ {
          if (mode == "control") {
            print "          if cursor != line"
            print "            stop_order_suspend(Pointer(Void).new(IyiHeap.read64(cursor + IYI_TL_HANDLE)))"
            print "            stop_asked += 1_i64"
            print "          end"
          }
          asked++; next
        }
        /^            handle = Pointer\(Void\)\.new\(IyiHeap\.read64\(cursor \+ IYI_TL_HANDLE\)\)$/ {
          print
          if (mode == "forced") { print "            stop_order_suspend(handle)"; print "            stop_asked += 1_i64" }
          handles++; next
        }
        /^            sp = IyiRoots\.capture_thread_registers\(handle, cursor \+ IYI_TL_SPILL\)$/ {
          print
          print "            stop_order_observe(stop_asked, @@count - (line != 0_u64 ? 1_i64 : 0_i64), sp)"
          capture++; next
        }
        { print }
        END { if (roots != 1 || entry != 1 || asked != 1 || handles != 1 || capture != 1) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    mkdir -p ordered/iyi serial/iyi
    cp "$REPO"/src/iyi/*.iyi ordered/iyi/
    cp "$REPO"/src/iyi/*.iyi serial/iyi/
    stop_order_copy control ordered/iyi/thread.iyi || { echo "stop ordering control anchors changed"; exit 1; }
    stop_order_copy forced serial/iyi/thread.iyi || { echo "stop ordering mutant anchors changed"; exit 1; }
    if ! IYI_PATH="$WORK/ordered${PSEP}$REPO/src" "$IYI" build --release crowd.iyi -Dstop_order_force -o crowd-order > build-order.log 2>&1; then
      cat build-order.log; exit 1
    fi
    timeout -k 5 300 ./crowd-order > order.txt 2>&1
    code=$?
    if [ "$code" -eq 76 ]; then cat order.txt; exit 76; fi
    if [ "$code" -ne 0 ] || ! tr -d '\r' < order.txt | grep -qxF 'stop: every suspend request preceded the first context capture'; then
      echo "the stop-order control failed (exit $code):"; cat order.txt; exit 1
    fi
    echo "  control: exit 0, every suspend request preceded the first context capture"
    step "failure proof: a stop that captures before issuing every suspend request is caught"
    if ! IYI_PATH="$WORK/serial${PSEP}$REPO/src" "$IYI" build --release crowd.iyi -Dstop_order_force -o crowd-serial > build-serial.log 2>&1; then
      cat build-serial.log; exit 1
    fi
    timeout -k 5 300 ./crowd-serial > serial.txt 2>&1
    code=$?
    if [ "$code" -eq 76 ]; then cat serial.txt; exit 76; fi
    if [ "$code" -ne 1 ] || ! tr -d '\r' < serial.txt | grep -qxF 'FAIL: stop: a context was captured before all suspend requests were issued'; then
      echo "the stop-order check did not fire (exit $code):"; cat serial.txt; exit 1
    fi
    echo '  exits 1 at "FAIL: stop: a context was captured before all suspend requests were issued"'
    ;;
esac

# ── 4c. Windows: on one core a waiter gets the runtime lock ──────────────
# The lock was a plain test-and-set, and a holder on one core runs its
# unlock and its next lock back to back: a spinner ran only while the
# holder was preempted, so with the lock held. Under `start /affinity 1`
# a thread starting beside one looping collections waited in its first
# allocation for minutes, and ten beside one taking the lock in a loop
# waited more than a minute.
# A spinner that sees no release in 128 turns counts itself on the lock's
# word now, and a free lock with one counted is its first; a collection
# gives the core away once it has released the threads it stopped, which
# was nearly all the time they had. The controls below check those three
# invariants directly rather than killing a deliberately hung process.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    step "held to one core, threads start beside a thread collecting in a loop and one taking the lock in a loop"
    cat > starve.iyi <<'IYI'
@[Unsafe("the one-core exercise pins its process with the Windows affinity API")]
module starve

lib CorePin
  fun SetProcessAffinityMask(process : Void*, mask : UInt64) : Int32
end

class Flag
  getter stop : Atomic(Int64)
  getter turns : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @turns = Atomic(Int64).new(0_i64)
  end
end

def fail(message : String) : Nil
  print "FAIL: #{message}\n"
  __iyi_exit(1)
end

# Five threads started and joined one after another beside a thread that
# collects in a loop, or takes the runtime lock in one and holds it for
# 2,000 increments a turn; answers the nanoseconds the five took.
def beside(collect : Bool) : UInt64
  flag = Flag.new
  busy = IyiThread.start do
    while flag.stop.get == 0_i64
      if collect
        IyiMark.collect
      else
        IyiRuntimeLock.lock
        held = 0
        while held < 2000
          flag.turns.add(1_i64)
          held = held + 1
        end
        IyiRuntimeLock.unlock
      end
    end
    nil
  end
  started = IyiMark.now_ns
  5.times { IyiThread.start { nil }.join }
  took = IyiMark.now_ns - started
  flag.stop.set(1_i64)
  busy.join
  took
end

fail("one-core affinity could not be set") if CorePin.SetProcessAffinityMask(::LibC.GetCurrentProcess, 1_u64) == 0_i32
fail("the process is not held to one core") unless IyiThread.core_count == 1

took = beside(true)
fail("five threads started beside a thread collecting in a loop took #{took // 1000000_u64} ms, past 10 s") if took > 10000000000_u64
puts "five threads started and joined beside a thread collecting in a loop, held to 10 s"
took = beside(false)
fail("five threads started beside a thread taking the runtime lock in a loop took #{took // 1000000_u64} ms, past 10 s") if took > 10000000000_u64
puts "five threads started and joined beside a thread taking the runtime lock in a loop, held to 10 s"
IYI
    # Unlike GNU timeout on MSYS, end_process ends only this native child.
    # A stuck child's wait is bounded even if Windows cannot terminate it.
    win_native() {
      local limit="$1" label="$2" child deadline
      shift 2
      "$@" &
      child=$!
      deadline=$((SECONDS + limit))
      while kill -0 "$child" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "SETUP: $label: process exceeded its bound" >&2
          end_bounded "$child" || return 76
          return 76
        fi
        sleep 0.1
      done
      wait "$child"
    }
    if ! "$IYI" build --release starve.iyi -o starve > build-starve.log 2>&1; then
      cat build-starve.log; exit 1
    fi
    win_native 120 "the one-core check" ./starve > starve-raw.txt 2>&1
    code=$?
    if [ "$code" -eq 76 ]; then cat starve-raw.txt; exit 76; fi
    tr -d '\r' < starve-raw.txt > starve.txt
    if [ "$code" -ne 0 ] || [ "$(grep -c ', held to 10 s$' starve.txt)" -ne 2 ] || grep -q '^FAIL' starve.txt; then
      echo "held to one core (exit $code):"; cat starve.txt; exit 1
    fi
    sed 's/^/  /' starve.txt

    # The old proof passed when GNU timeout killed a deliberately hung
    # process. On MSYS that kill can also reach the runner agent through a
    # reused parent pid. Exercise the spinner's count directly instead, and
    # record the return from each real collection yield in copy-only code.
    cat > fairness.iyi <<'IYI'
@[Unsafe("the test's atomic word is outside the collector and the copy records collection yields")]
module fairness

class Flag
  getter ready : Atomic(Int64)
  getter stop : Atomic(Int64)

  def initialize
    @ready = Atomic(Int64).new(0_i64)
    @stop = Atomic(Int64).new(0_i64)
  end
end

IyiMark.auto = false
IyiMark.workers = 0_u64
{% if flag?(:fairness_force) %}
IyiThread.fair_yield_reset
{% end %}
word = Pointer(Atomic(UInt64)).new(__iyi_mmap(4096_u64).address)
word.value.set(1_u64)
spins, since = IyiThread.lock_turn(word, 1_u64, 127_i64, 0_u64)
if spins >= 0_i64 || (word.value.get & 0xFFFE_u64) != 2_u64
  print "FAIL: fairness: a spinner seeing no lock release for 128 turns was not counted\n"
  __iyi_exit(1)
end

flag = Flag.new
worker = IyiThread.start do
  flag.ready.set(1_i64)
  while flag.stop.get == 0_i64
    IyiThread.spin_pause
  end
  nil
end
deadline = IyiMark.now_ns &+ 20000000000_u64
while flag.ready.get == 0_i64
  if IyiMark.now_ns >= deadline
    print "FAIL: fairness: the helper did not start\n"
    __iyi_exit(1)
  end
  IyiThread.yield_cpu
end
IyiMark.collect
if IyiThread.fair_yield_count != 1_u64
  print "FAIL: fairness: an explicit collection released its threads without yielding\n"
  __iyi_exit(1)
end
# Make the budget collection due without relying on allocation timing.
IyiHeap.allocated_word.value.set(IyiMark.budget)
IyiMark.collect_if_due
if IyiThread.fair_yield_count != 2_u64
  print "FAIL: fairness: a budget collection released its threads without yielding\n"
  __iyi_exit(1)
end
flag.stop.set(1_i64)
worker.join
puts "fairness: the spinner was counted, and explicit and budget collections yielded after release"
IYI
    fair_thread() {
      awk -v mode="$1" '
        /^    # ── Roots/ {
          print "    def self.fair_yield_reset : Nil"
          print "      word(control + 384_u64).value.set(0_u64)"
          print "    end"
          print "    def self.fair_yield_count : UInt64"
          print "      word(control + 384_u64).value.get"
          print "    end"
          roots++
        }
        /^      yield_cpu if @@count > 1_i64$/ {
          print "      if @@count > 1_i64"
          print "        yield_cpu"
          print "        word(control + 384_u64).value.add(1_u64)"
          print "      end"
          hook++; next
        }
        mode == "uncounted" && /^        if !counted && released == since$/ {
          print "        if false"
          removed++; next
        }
        { print }
        END { if (roots != 1 || hook != 1 || (mode == "uncounted" && removed != 1)) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    fair_prelude() {
      awk -v mode="$1" '
        /^      def self\.collect_if_due : Nil$/ { section = "budget"; budget++ }
        /^      def self\.collect_cleared : Nil$/ { section = "explicit"; explicit++ }
        /^          IyiThread\.yield_to_stopped$/ && section == mode { removed++; next }
        { print }
        END { if (budget != 1 || explicit != 1 || removed != 1) exit 3 }
      ' "$REPO/src/iyi/prelude.iyi" > "$2"
    }
    for mode in control uncounted explicit budget; do
      case "$mode" in
        control)
          step "the counted-spinner and collection-yield control"
          expected="fairness: the spinner was counted, and explicit and budget collections yielded after release"
          expected_code=0
          ;;
        uncounted)
          step "failure proof: a spinner is not counted after 128 turns"
          expected="FAIL: fairness: a spinner seeing no lock release for 128 turns was not counted"
          expected_code=1
          ;;
        explicit)
          step "failure proof: an explicit collection omits its yield"
          expected="FAIL: fairness: an explicit collection released its threads without yielding"
          expected_code=1
          ;;
        budget)
          step "failure proof: a budget collection omits its yield"
          expected="FAIL: fairness: a budget collection released its threads without yielding"
          expected_code=1
          ;;
      esac
      mkdir -p "fair-$mode/iyi"
      cp "$REPO"/src/iyi/*.iyi "fair-$mode/iyi/"
      fair_thread "$mode" "fair-$mode/iyi/thread.iyi" || { echo "the fairness hook or count anchor is not unique"; exit 1; }
      case "$mode" in
        explicit | budget)
          fair_prelude "$mode" "fair-$mode/iyi/prelude.iyi" || { echo "the collection yield anchor is not unique"; exit 1; }
          ;;
      esac
      if ! IYI_PATH="$WORK/fair-$mode${PSEP}$REPO/src" "$IYI" build --release fairness.iyi -Dfairness_force -o "fair-$mode-run" > "build-fair-$mode.log" 2>&1; then
        cat "build-fair-$mode.log"; exit 1
      fi
      win_native 60 "the fairness $mode proof" "./fair-$mode-run" > "fair-$mode-raw.txt" 2>&1
      code=$?
      tr -d '\r' < "fair-$mode-raw.txt" > "fair-$mode.txt"
      if [ "$code" -ne "$expected_code" ] || ! grep -qxF "$expected" "fair-$mode.txt"; then
        echo "the fairness $mode proof exited $code, expected $expected_code:"; cat "fair-$mode.txt"; exit 1
      fi
      printf '  exits %s at "%s"\n' "$code" "$expected"
    done
    ;;
esac

# ── 4d. Windows: the stopping thread above a burst on its processor ──────
# A stop on Windows is the stopping thread's own loop of `SuspendThread`
# and `ResumeThread` calls, and nothing else moves until it ends: where a
# thread above it takes its processor, the world stays stopped until that
# thread lets go. In a real server on a saturated machine (iyiturkiye,
# Windows 11, 12 logical processors, the user's machine) single calls in
# that loop took 148 to 214 ms. The stop raises its thread to Windows'
# highest priority now (`IyiThread.raise_stopper`).
#
# Placed so that only the priority decides: the stopping thread is held
# to one processor, its boost off, beside a separate process one level
# above normal (and below highest), also boostless, that computes 100 ms
# at a time and sleeps between; the threads the stop suspends compute on
# every other processor, allocating nothing, so none is ever waited for
# at its park. The burst is another process because a thread of the
# program's own would be suspended by the stop it is meant to hold up.
# The first shape of this check, a spinner at normal priority sharing the
# processor, paused 17 ms on both builds and told them apart in nothing.
#
# On that machine, five runs of four seconds each, interleaved: the
# shipped build's longest stop 0.7 to 1.9 ms (3.1 ms alone, no burst),
# and with the raise taken out, or on the build before it, 100.3 to
# 103.1 ms in every run, the stops 73 to 93% of the run against 7%. The
# bound is 20 ms, and three stops a run may pass it (`stopping.iyi` says
# why).
#
# The priority is put back after the runtime lock is let go, not at the
# end of the release: the drop is where the burst takes the processor,
# and a thread descheduled there holds the lock. A fifth thread takes the
# lock in a loop on the other processors and keeps its longest wait.
# Five interleaved runs: 0.3 to 16.8 ms, none past 20, and with the drop
# put back at the end of the release, 100.1 to 102.6 ms, 36 or 37 waits
# past 20 ms in each run. The bound is 50 ms.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    if [ "${NUMBER_OF_PROCESSORS:-1}" -lt 2 ]; then
      echo "the stop beside a burst needs at least two processors for the threads it stops; this machine has ${NUMBER_OF_PROCESSORS:-1}" >&2
      exit 1
    else
    cat > burst.iyi <<'IYI'
@[Unsafe("the burner pins itself to one processor and raises its priority by calling Windows' thread functions through a lib")]
module burst

import std/file::{File}

lib Placing
  fun SetThreadAffinityMask(thread : Void*, mask : UInt64) : UInt64
  fun SetThreadPriority(thread : Void*, priority : Int32) : Int32
  fun Sleep(milliseconds : UInt32) : Nil
end

# On the processor the first argument numbers, one level above normal and
# with no boost, computing the second argument's milliseconds at a time
# and sleeping a millisecond between, until a file named burst-stop
# appears, or 300 s.
processor = Program.args[0].to_i
length = Program.args[1].to_i.to_u64 * 1000000_u64
Placing.SetThreadAffinityMask(::LibC.GetCurrentThread, 1_u64.unsafe_shl(processor.to_u64))
Placing.SetThreadPriority(::LibC.GetCurrentThread, 1_i32)
::LibC.SetThreadPriorityBoost(::LibC.GetCurrentThread, 1_i32)
File.touch("burst-ready")
bursts = 0
deadline = IyiMark.now_ns + 300000000000_u64
while !File.file?("burst-stop") && IyiMark.now_ns < deadline
  ends = IyiMark.now_ns + length
  while IyiMark.now_ns < ends
  end
  bursts = bursts + 1
  Placing.Sleep(1_u32)
end
puts "bursts: #{bursts}"
IYI
    cat > stopping.iyi <<'IYI'
@[Unsafe("each thread pins itself to its processors by calling Windows' SetThreadAffinityMask through a lib")]
module stopping

class Flag
  getter stop : Atomic(Int64)
  getter held : Atomic(Int64)
  getter waited : Atomic(Int64)
  getter waits : Atomic(Int64)
  getter turns : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @held = Atomic(Int64).new(0_i64)
    @waited = Atomic(Int64).new(0_i64)
    @waits = Atomic(Int64).new(0_i64)
    @turns = Atomic(Int64).new(0_i64)
  end
end

lib Placing
  fun SetThreadAffinityMask(thread : Void*, mask : UInt64) : UInt64
end

def fail(message : String) : Nil
  print "FAIL: #{message}\n"
  __iyi_exit(1)
end

# Computes, allocating nothing, on the processors *mask* names.
def compute(flag : Flag, mask : UInt64) : Nil
  Placing.SetThreadAffinityMask(::LibC.GetCurrentThread, mask)
  flag.held.add(1_i64)
  x = 0_i64
  while flag.stop.get == 0_i64
    x = x &+ 1
  end
end

# Takes the runtime lock in a loop on the processors *mask* names,
# computing 20 us between turns, and keeps its longest wait and how many
# waits passed *bound*.
def taker(flag : Flag, mask : UInt64, bound : UInt64) : Nil
  Placing.SetThreadAffinityMask(::LibC.GetCurrentThread, mask)
  flag.held.add(1_i64)
  while flag.stop.get == 0_i64
    asked = IyiMark.now_ns
    IyiRuntimeLock.lock
    took = IyiMark.now_ns - asked
    IyiRuntimeLock.unlock
    flag.waits.add(1_i64) if took > bound
    flag.turns.add(1_i64)
    flag.waited.set(took.to_i64) if took.to_i64 > flag.waited.get
    ends = IyiMark.now_ns + 20000_u64
    while IyiMark.now_ns < ends
    end
  end
end

# The processor the first argument numbers is the stopping thread's, and
# the burst's; the threads it stops run on every other one. The second
# and third are the bounds on a stop and on a wait for the lock, in ms.
processor = Program.args[0].to_i
bound = Program.args[1].to_i.to_u64 * 1000000_u64
lock_bound = Program.args[2].to_i.to_u64 * 1000000_u64
shared = 1_u64.unsafe_shl(processor.to_u64)
mask = 0_u64
system = 0_u64
::LibC.GetProcessAffinityMask(::LibC.GetCurrentProcess, pointerof(mask), pointerof(system))
elsewhere = mask ^ shared
# As many threads that compute as the other processors hold beside the
# taker and one left idle, up to four: a taker that shares a processor
# with one waits out that thread's quantum, a lock it never asked for. On
# windows-2025's 4-processor runners four computed on the 3 processors
# left with the taker, and five runs of five had 2 to 11 waits past 50
# ms, the longest 102 to 611 ms (debug job 126403714389); CI run
# 41778179340 had 17, the longest 303 ms. Two beside the taker, filling
# the three, still left the taker waiting out the runner's own threads:
# its longest wait 0.2 to 41 ms in 45 runs on three runners, against 0.2
# to 1.6 ms with one beside it and a processor idle (debug run
# 41812323963). Windows 11, 12 logical processors (the user's machine),
# leaves 11 for the five.
others = 0
bits = elsewhere
while bits != 0_u64
  others = others + 1 if bits & 1_u64 != 0_u64
  bits = bits.unsafe_shr(1_u64)
end
computes = others - 2
computes = 4 if computes > 4
computes = 0 if computes < 0
IyiMark.workers = 0_u64
{% if flag?(:burst_force) %}
# Initialize the copy-only record before any thread can read it.
IyiThread.burst_probe_init
{% end %}
flag = Flag.new
threads = [] of IyiThread
computes.times { threads << IyiThread.start { compute(flag, elsewhere) } }
threads << IyiThread.start { taker(flag, elsewhere, lock_bound) }
while flag.held.get < computes.to_i64 + 1_i64
  IyiThread.yield_cpu
end
Placing.SetThreadAffinityMask(::LibC.GetCurrentThread, shared)
::LibC.SetThreadPriorityBoost(::LibC.GetCurrentThread, 1_i32)
collections = 0
over = 0
longest = 0_u64
stop_ns = IyiThread.stop_ns
started = IyiMark.now_ns
watch = started + 60000000000_u64
# The collections follow the taker's 100th acknowledged lock attempt, a
# happens-before word (the turns counter), not a clock window. The healthy
# verdict is the structural counter below and that the taker reached 100
# turns within 60 s. Stop and wait timings are measurements only.
while flag.turns.get < 100_i64
  fail("taker: fewer than 100 turns on the runtime lock within 60 s") if IyiMark.now_ns >= watch
  IyiThread.yield_cpu
end
20.times do
  {% if flag?(:burst_force) %}
  IyiThread.burst_probe_begin
  {% end %}
  before = IyiThread.stop_ns
  IyiMark.collect
  {% if flag?(:burst_force) %}
  IyiThread.burst_probe_end
  {% end %}
  took = IyiThread.stop_ns - before
  longest = took if took > longest
  over = over + 1 if took > bound
  collections = collections + 1
end
share = (IyiThread.stop_ns - stop_ns) * 100_u64 // (IyiMark.now_ns - started)
flag.stop.set(1_i64)
threads.each { |thread| thread.join }
# Stop and lock-wait durations above the supplied thresholds are measured,
# never verdicts. Both copies observe the same lower_stopper body and the
# actual runtime-unlock event on the collecting thread. The mutant moves
# the restore before that unlock; the control keeps the original order.
{% if flag?(:burst_force) %}
seen = IyiThread.burst_probe_seen
unlocked = IyiThread.burst_probe_unlocked
fail("lock: no priority restore was recorded") if seen == 0_u64
fail("lock: the priority was restored while the stopper still held the runtime lock") if unlocked == 0_u64
puts "lock: restore recorded after the runtime lock was released"
{% end %}
puts "stop: #{collections} stops of #{threads.size} threads beside a burst on the stopping thread's processor, #{share}% of the run in stops, #{over} past #{bound // 1000000_u64} ms, the longest #{longest // 1000_u64} us"
puts "lock: #{flag.waits.get} waits for the runtime lock beside #{collections} collections took past #{lock_bound // 1000000_u64} ms, the longest #{flag.waited.get // 1000_i64} us"
IYI
    shared=$(( NUMBER_OF_PROCESSORS - 1 ))
    # `./$1` beside the burst, its output in `$2`.
    beside_burst() {
      local burst_pid deadline killed=0
      rm -f burst-ready burst-stop
      MSYS_NO_PATHCONV=1 ./burst.exe "$shared" 100 > burst.txt 2>&1 &
      burst_pid=$!
      deadline=$((SECONDS + 10))
      while [ ! -f burst-ready ]; do
        if ! kill -0 "$burst_pid" 2>/dev/null || [ "$SECONDS" -ge "$deadline" ]; then
          echo "SETUP: burst: owned burner did not become ready (pid $burst_pid)" >&2
          if kill -0 "$burst_pid" 2>/dev/null; then end_bounded "$burst_pid" || exit 76; fi
          wait "$burst_pid" 2>/dev/null || true
          exit 76
        fi
        sleep 0.1
      done
      timeout -k 5 120 "./$1" "$shared" 20 50 > "$2" 2>&1
      BURST_STATUS=$?
      touch burst-stop
      deadline=$((SECONDS + 10))
      while kill -0 "$burst_pid" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          end_bounded "$burst_pid" || exit 76
          killed=1
          break
        fi
        sleep 0.1
      done
      if ! wait "$burst_pid" 2>/dev/null && [ "$killed" -eq 0 ]; then
        echo "SETUP: burst: owned burner exited unsuccessfully (pid $burst_pid)" >&2
        exit 76
      fi
      tr -d '\r' < burst.txt >> "$2"
      [ "$BURST_STATUS" -ne 76 ] || exit 76
    }
    cat > burst.part <<'IYI'
    # Both copies observe the actual lower_stopper body. These per-thread
    # words track whether this stopper has executed the actual runtime unlock.
    IYI_BURST_SEEN     = 384_u64
    IYI_BURST_EARLY    = 448_u64
    @[ThreadLocal]
    @@burst_probe_active : Bool = false
    @[ThreadLocal]
    @@burst_probe_released : Bool = false

    def self.burst_probe_init : Nil
      page = control
      word(page + IYI_BURST_SEEN).value.set(0_u64)
      word(page + IYI_BURST_EARLY).value.set(0_u64)
    end

    def self.burst_probe_begin : Nil
      @@burst_probe_released = false
      @@burst_probe_active = true
    end

    def self.burst_probe_unlock : Nil
      @@burst_probe_released = true if @@burst_probe_active
    end

    def self.burst_probe_restore : Nil
      return unless @@burst_probe_active
      page = control
      word(page + IYI_BURST_SEEN).value.add(1_u64)
      word(page + IYI_BURST_EARLY).value.add(1_u64) unless @@burst_probe_released
    end

    def self.burst_probe_end : Nil
      @@burst_probe_active = false
    end

    def self.burst_probe_seen : UInt64
      word(control + IYI_BURST_SEEN).value.get
    end

    def self.burst_probe_unlocked : UInt64
      word(control + IYI_BURST_EARLY).value.get == 0_u64 ? 1_u64 : 0_u64
    end
IYI
    burst_copy() {
      awk -v gate=burst.part -v mode="$1" '
        /^    # ── Roots/ { while ((getline line < gate) > 0) print line; roots++ }
        /^        return unless @@stopper_raised$/ { print; print "        burst_probe_restore"; observed++; next }
        mode == "forced" && /^        @@owed = @@deferred$/ {
          print
          print "        lower_stopper"
          moved++; next
        }
        { print }
        END { if (roots != 1 || observed != 1 || (mode == "forced" && moved != 1)) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    burst_prelude() {
      awk -v mode="$1" '
        in_unlock && /^        IyiRuntimeLock\.unlock$/ { print; print "        IyiThread.burst_probe_unlock"; released++; next }
        mode == "forced" && in_unlock && /^          IyiThread\.lower_stopper$/ { lower++; next }
        /^      def self\.unlock_released : Nil$/ { unlocks++; in_unlock = 1 }
        in_unlock && /^      end$/ { in_unlock = 0 }
        { print }
        END { if (unlocks != 1 || released != 1 || (mode == "forced" && lower != 1)) exit 3 }
      ' "$REPO/src/iyi/prelude.iyi" > "$2"
    }
    step "the stop beside a burst on the stopping thread's processor"
    if ! "$IYI" build --release burst.iyi -o burst > build-burst.log 2>&1; then
      cat build-burst.log; exit 1
    fi
    mkdir -p burst-ctl/iyi
    cp "$REPO"/src/iyi/*.iyi burst-ctl/iyi/
    burst_copy control burst-ctl/iyi/thread.iyi || { echo "the burst probe's roots anchor is not unique"; exit 1; }
    burst_prelude control burst-ctl/iyi/prelude.iyi || { echo "the runtime lock wait anchor is not unique"; exit 1; }
    if ! IYI_PATH="$WORK/burst-ctl${PSEP}$REPO/src" "$IYI" build --release stopping.iyi -Dburst_force -o stopping > build-stopping.log 2>&1; then
      cat build-stopping.log; exit 1
    fi
    beside_burst stopping stopping.txt
    if [ "$BURST_STATUS" -ne 0 ] || grep -q '^FAIL' stopping.txt || ! grep -qxF 'lock: restore recorded after the runtime lock was released' stopping.txt || ! grep -q '^stop:' stopping.txt || ! grep -qE '^lock: [0-9]+ waits for the runtime lock beside [0-9]+ collections took past 50 ms, the longest [0-9]+ us$' stopping.txt; then
      echo "beside a burst (exit $BURST_STATUS):"; cat stopping.txt; exit 1
    fi
    sed 's/^/  /' stopping.txt

    step "failure proof: a priority put back inside the release holds the runtime lock through the burst"
    # The copy lowers the priority where the release ends, after its last
    # `ResumeThread`, where it was lowered before. The release waited there
    # for the resumed threads to count out, and this copy found its end by
    # that wait; the release waits for nobody now (`resume_others`) and
    # ends by leaving the count owed to the next stop, `@@owed`.
    mkdir -p inside/iyi
    cp "$REPO"/src/iyi/*.iyi inside/iyi/
    burst_copy forced inside/iyi/thread.iyi || { echo "the burst probe's roots or release anchor is not unique"; exit 1; }
    burst_prelude forced inside/iyi/prelude.iyi || { echo "the runtime lock wait or lowering anchor is not unique"; exit 1; }
    if ! IYI_PATH="$WORK/inside${PSEP}$REPO/src" "$IYI" build --release stopping.iyi -Dburst_force -o stopping-inside > build-inside.log 2>&1; then
      cat build-inside.log; exit 1
    fi
    beside_burst stopping-inside inside.txt
    if [ "$BURST_STATUS" -ne 1 ] || ! grep -qxF 'FAIL: lock: the priority was restored while the stopper still held the runtime lock' inside.txt; then
      echo "the lock check did not fire on its one run (exit $BURST_STATUS):"; cat inside.txt; exit 1
    fi
    printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: lock:' inside.txt)"
    fi


    # A panic inside a stop ends its task, not its thread, which then runs
    # every task after it: `raise` puts the priority back. A copy panics
    # in its first stop, raised, and the main fiber's defer reads its
    # thread's priority, writing what it read without allocating - the
    # runtime lock is the stop's still.
    step "a panic inside a stop puts the stopping thread's priority back"
    cat > panicky.iyi <<'IYI'
@[Unsafe("the report writes through __iyi_write and reads the thread's priority from Windows, so it allocates nothing inside the stop")]
module panicky

def say(text : String) : Nil
  __iyi_write(1, text.to_unsafe.as(Void*), text.bytesize.to_u64)
end

def report : Nil
  if ::LibC.GetThreadPriority(::LibC.GetCurrentThread) == 0
    say("panic: the stopping thread's priority put back\n")
  else
    say("FAIL: panic: the stopping thread kept the stop's priority\n")
  end
end

def run : Nil
  defer report
  IyiMark.collect
end

asleep = IyiThread.start { sleep(10000); nil }
run
asleep.join
IYI
    mkdir -p panicking/iyi
    cp "$REPO"/src/iyi/*.iyi panicking/iyi/
    awk '{ print } /^        raise_stopper$/ { print "        raise \"inside the stop\""; found = 1 } END { if (!found) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > panicking/iyi/thread.iyi || { echo "the stop's raise is not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/panicking${PSEP}$REPO/src" "$IYI" build --release panicky.iyi -o panicky > build-panicky.log 2>&1; then
      cat build-panicky.log; exit 1
    fi
    timeout -k 5 60 ./panicky > panicky.txt 2>&1
    code=$?
    if [ "$code" -eq 76 ]; then cat panicky.txt; exit 76; fi
    if [ "$code" -ne 1 ] || ! tr -d '\r' < panicky.txt | grep -qxF "panic: the stopping thread's priority put back" || ! tr -d '\r' < panicky.txt | grep -q '^iyi: panic: inside the stop'; then
      echo "a panic inside the stop (exit $code):"; cat panicky.txt; exit 1
    fi
    echo "  $(grep -m1 '^panic:' panicky.txt)"

    step "failure proof: a panic inside a stop that keeps the priority is caught"
    mkdir -p unlowered/iyi
    cp panicking/iyi/*.iyi unlowered/iyi/
    awk '/^      IyiThread\.lower_stopper$/ { found = 1; next } { print } END { if (!found) exit 3 }' \
      "$REPO/src/iyi/prelude.iyi" > unlowered/iyi/prelude.iyi || { echo "the panic's lowering is not in the prelude any more"; exit 1; }
    if ! IYI_PATH="$WORK/unlowered${PSEP}$REPO/src" "$IYI" build --release panicky.iyi -o panicky-unlowered > build-unlowered.log 2>&1; then
      cat build-unlowered.log; exit 1
    fi
    timeout -k 5 60 ./panicky-unlowered > unlowered.txt 2>&1
    code=$?
    if [ "$code" -eq 76 ]; then cat unlowered.txt; exit 76; fi
    if [ "$code" -ne 1 ] || ! tr -d '\r' < unlowered.txt | grep -qxF "FAIL: panic: the stopping thread kept the stop's priority"; then
      echo "the panic check did not fire (exit $code):"; cat unlowered.txt; exit 1
    fi
    printf '  says "%s"\n' "$(grep -m1 '^FAIL: panic:' unlowered.txt)"

    # Every thread a collection raised puts its own priority back,
    # however many raised together. The raise comes before the runtime
    # lock, and threads that cross the budget at once, or collect at once,
    # all raise and wait for the lock in turn. What to put back was one
    # record for the program, the last raiser's, and every other raiser
    # found another thread's id there and kept the highest priority for
    # good: bench/mark_stall.iyi at twelve workers ended each of 30 runs
    # with 8, 10 or 11 of its 14 threads raised, and made 89,327 to
    # 387,547 requests in its 10 s, against 320,668 to 554,078 and none
    # raised with a record per thread (Windows 11, 12 logical processors
    # held to 4, the user's machine). On a four-processor CI runner its
    # tasks allocated 60 MiB in five seconds, under the budget, and
    # concurrent_mark.sh failed the run as a stall (job 128104679578).
    # Here eight threads churn, and then four collect twenty times each
    # at once. On that machine, held to 4, the runtime before kept 3 of
    # the 4 collectors raised in each of 20 runs, and 1 to 7 of the 8
    # churners; per thread, none in 20.
    step "threads that raise together for collections each put their own priority back"
    cat > raisers.iyi <<'IYI'
@[Unsafe("each thread reads its own priority from Windows' GetThreadPriority, a C call")]
module raisers

# Threads crossing the budget together, then threads collecting together:
# each reads its priority as it starts and again as it ends, and counts
# itself if the two differ.
class Tally
  @count : Atomic(Int64)

  def initialize
    @count = Atomic(Int64).new(0_i64)
  end

  def add(value : Int64) : Nil
    @count.add(value)
  end

  def count : Int64
    @count.get
  end
end

def priority : Int32
  ::LibC.GetThreadPriority(::LibC.GetCurrentThread)
end

# Garbage a string at a time, flat out.
def churn(strings : Int32) : Int64
  kept = 0_i64
  i = 0
  while i < strings
    kept = kept &+ "churn #{i}".bytesize.to_i64
    i = i + 1
  end
  kept
end

CHURNERS   = 8
COLLECTORS = 4
ROUNDS     = 20

before = IyiMark.collections
churners_raised = Tally.new
collectors_raised = Tally.new
go = Tally.new
threads = [] of IyiThread
CHURNERS.times do
  threads << IyiThread.start do
    was = priority
    churn(1000000)
    churners_raised.add(1_i64) if priority != was
    nil
  end
end
threads.each { |thread| thread.join }
churned = IyiMark.collections - before
threads = [] of IyiThread
COLLECTORS.times do
  threads << IyiThread.start do
    was = priority
    while go.count == 0_i64
      IyiThread.spin_pause
    end
    ROUNDS.times { IyiMark.collect }
    collectors_raised.add(1_i64) if priority != was
    nil
  end
end
go.add(1_i64)
threads.each { |thread| thread.join }
if churners_raised.count != 0_i64 || collectors_raised.count != 0_i64
  print "FAIL: raise: #{churners_raised.count} of #{CHURNERS} threads churning through #{churned} collections, and #{collectors_raised.count} of #{COLLECTORS} collecting #{ROUNDS} times each together, kept the stop's priority\n"
  __iyi_exit(1)
end
print "raise: #{CHURNERS} threads churning through #{churned} collections, and #{COLLECTORS} collecting #{ROUNDS} times each together, every one at its own priority after\n"
IYI
    if ! "$IYI" build --release raisers.iyi -o raisers > build-raisers.log 2>&1; then
      cat build-raisers.log; exit 1
    fi
    if ! timeout -k 5 60 ./raisers > raisers.txt 2>&1 || ! grep -q '^raise:' raisers.txt; then
      echo "threads raised together:"; cat raisers.txt; exit 1
    fi
    echo "  $(grep -m1 '^raise:' raisers.txt)"

    # The record the program's again: the raise's two words without their
    # `@[ThreadLocal]`. A thread collecting waits at the lock raised while
    # another holds it, so every collector but the last to lower finds
    # the record already put back: 20 runs of 20 on the machine above.
    step "failure proof: one record of the raise for every thread leaves a thread raised"
    mkdir -p shared/iyi
    cp "$REPO"/src/iyi/*.iyi shared/iyi/
    awk '/^      @\[ThreadLocal\]$/ { held = $0; next }
      held != "" { if ($0 ~ /^      @@stopper_(priority|raised) /) removed++; else print held; held = "" }
      { print } END { if (removed != 2) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > shared/iyi/thread.iyi || { echo "the raise's thread-local record is not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/shared${PSEP}$REPO/src" "$IYI" build --release raisers.iyi -o raisers-shared > build-shared.log 2>&1; then
      cat build-shared.log; exit 1
    fi
    timeout -k 5 60 ./raisers-shared > shared.txt 2>&1
    code=$?
    if [ "$code" -ne 1 ] || ! grep -q '^FAIL: raise:' shared.txt; then
      echo "one record for every thread was not caught (exit $code):"; cat shared.txt; exit 1
    fi
    printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: raise:' shared.txt)"
    ;;
esac

# ── 4e. The release waits for nobody it lets go ──────────────────────────
# A stop's release used to wait for every thread it let go to leave its
# park, so a collection lasted until the last of them had a processor
# again: on Windows 11, 12 logical processors, a thread parked inside the
# allocator and then held off its processor by another program kept each
# collection 403 to 410 ms past its stop, and 25 to 28 ms once the release
# stopped waiting (the mark of 2,000,000 links among it). The next stop
# now waits, before it clears the words the released threads read
# (`stop_others`), and the release waits for none of them (`resume_others`).
#
# The released thread is held before counting out. Both copies read the
# actual count-out after resume_others returns; the mutant waits for that
# count inside the release after letting the held thread leave its gate.
# A missing or expired hold is a distinct setup failure, not the verdict.
#
# The bound this replaces was 200 ms on a mean of five collections. It read
# 175 ms in one run and 411 ms in the next on GitHub's windows-2025 runner,
# beside 76 ms for the healthy release (jwaldrip/iyi run 44368465397), so
# it measured the runner's scheduling and not the release.
#
# The gate uses words on the control page past IYI_TC_TURNS, and it
# exists only in copies of the runtime's thread.iyi, made here by awk, so
# the tree is never touched. The healthy copy is the tree with the hook and
# nothing else; the waiting copy adds the wait a release would make.
cat > gate.part <<'IYI'
    # ── The release gate (bench/thread_exercise.sh, step 4e) ─────────────
    # Copies only: the awk in that step puts this into a copy of the
    # runtime's thread.iyi, and the tree has none of it. The control-page
    # words name the armed line, hold, opening, expiry, and start time.
    # The start time also lets the collector detect an expired hold while
    # the held thread itself is suspended.
    IYI_GATE_LINE    = 384_u64
    IYI_GATE_HELD    = 448_u64
    IYI_GATE_OPEN    = 512_u64
    IYI_GATE_EXPIRED = 576_u64
    IYI_GATE_STARTED = 832_u64
    IYI_GATE_NS      = 5000000000_u64

    # The calling thread's own line is the one the gate holds.
    def self.release_gate_arm : Nil
      word(control + IYI_GATE_LINE).value.set(@@line)
    end

    # `park` calls this for every parked thread before it counts itself out
    # of the release. Atomics only: nothing allocates and no lock is taken.
    # For the armed line the thread sets `held`, then waits for its owner.
    # A deadline failure ends the process; it never opens the gate.
    def self.release_gate_hold(line : UInt64, message : String) : Nil
      page = control
      return if line == 0_u64 || word(page + IYI_GATE_LINE).value.get != line
      began = IyiMark.now_ns
      word(page + IYI_GATE_STARTED).value.set(began)
      word(page + IYI_GATE_HELD).value.set(1_u64)
      while word(page + IYI_GATE_OPEN).value.get == 0_u64
        if IyiMark.now_ns &- began > IYI_GATE_NS
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          {% if flag?(:darwin) %}
            LibC.thread_gate_exit(76_i32)
          {% else %}
            __iyi_exit(76)
          {% end %}
        end
        yield_cpu
      end
    end

    # Opens the gate and answers {held, expired}. The release may return
    # before the armed thread has reached the gate, so this waits for `held`
    # as well, within the same bound.
    def self.release_gate_open : Tuple(Bool, Bool)
      page = control
      began = IyiMark.now_ns
      while word(page + IYI_GATE_HELD).value.get == 0_u64
        if IyiMark.now_ns &- began > IYI_GATE_NS
          message = "SETUP: release gate: the held thread never arrived\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(76)
        end
        yield_cpu
      end
      if release_gate_expired?
        message = "SETUP: release gate: hold deadline elapsed before opening\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      word(page + IYI_GATE_OPEN).value.set(1_u64)
      {true, false}
    end

    # Whether the armed thread has reached its gate. A skipping copy's main
    # waits on this before it collects; nothing else reads it.
    def self.release_gate_held? : Bool
      word(control + IYI_GATE_HELD).value.get != 0_u64
    end
    def self.release_gate_expired? : Bool
      page = control
      return true if word(page + IYI_GATE_EXPIRED).value.get != 0_u64
      return false if word(page + IYI_GATE_HELD).value.get == 0_u64
      IyiMark.now_ns &- word(page + IYI_GATE_STARTED).value.get > IYI_GATE_NS
    end
    # Both copies observe the actual count-out after the held thread reaches
    # its gate. A missing hold or expired gate is a setup failure.
    def self.release_gate_wait_held(page : UInt64) : Nil
      began = IyiMark.now_ns
      while word(page + IYI_GATE_HELD).value.get == 0_u64
        if IyiMark.now_ns &- began > IYI_GATE_NS
          message = "SETUP: release: the held thread never reached its park\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(76)
        end
        yield_cpu
      end
    end

    # Mutant: allow the held thread to leave its gate and wait for the real
    # count-out before returning from resume_others.
    def self.release_gate_wait_resumed(page : UInt64, target : UInt64) : Nil
      release_gate_wait_held(page)
      word(page + IYI_GATE_OPEN).value.set(1_u64)
      began = IyiMark.now_ns
      while word(page + IYI_TC_RESUMED).value.get < target
        if IyiMark.now_ns &- began > IYI_GATE_NS
          message = "SETUP: release: the held thread never counted out\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(76)
        end
        yield_cpu
      end
    end

    def self.release_gate_counted_out? : Bool
      page = control
      release_gate_wait_held(page)
      word(page + IYI_TC_RESUMED).value.get != 0_u64
    end



    # ── Copy-only: an armed start with its handle written late ──────────
    # `release_gate_arm_next` arms exactly one start. `release_gate_take_arm`
    # is called once per start before its CreateThread: the one armed start
    # is created suspended-free but writes its handle only after its unlock,
    # and holds there in `release_gate_start_hold` until the gate opens. A
    # stop reads each thread's handle once, in `release_gate_unnamed?`, and
    # records a visit to the armed line whose handle is still 0.
    IYI_GATE_ARM    = 640_u64
    IYI_GATE_RECORD = 704_u64
    IYI_GATE_SKIP   = 768_u64

    def self.release_gate_arm_next : Nil
      word(control + IYI_GATE_ARM).value.set(1_u64)
    end

    def self.release_gate_take_arm : Bool
      word(control + IYI_GATE_ARM).value.swap(0_u64) != 0_u64
    end

    def self.release_gate_start_hold(line : UInt64) : Nil
      word(control + IYI_GATE_LINE).value.set(line)
      release_gate_hold(line, "SETUP: unnamed: held start gate timed out\n")
    end

    def self.release_gate_unnamed?(cursor : UInt64, line : UInt64) : Bool
      return false if cursor == line
      return false if word(control + IYI_GATE_LINE).value.get != cursor
      return false if IyiHeap.read64(cursor + IYI_TL_HANDLE) != 0_u64
      word(control + IYI_GATE_SKIP).value.set(cursor)
      word(control + IYI_GATE_RECORD).value.set(1_u64)
      true
    end
    def self.release_gate_clear_skip : Nil
      word(control + IYI_GATE_SKIP).value.set(0_u64)
    end

    def self.release_gate_skipped?(cursor : UInt64) : Bool
      cursor == word(control + IYI_GATE_SKIP).value.get
    end


    def self.release_gate_recorded? : Bool
      word(control + IYI_GATE_RECORD).value.get != 0_u64
    end

IYI
cat > release.iyi <<'IYI'
@[Unsafe("a timed-out allocator rendezvous writes its diagnostic without allocating")]
module release

class Flag
  getter stop : Atomic(Int64)
  getter inside : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @inside = Atomic(Int64).new(0_i64)
  end
end

def fail(message : String) : Nil
  print "FAIL: #{message}\n"
  __iyi_exit(1)
end

# The held thread. It is inside the allocator from `enter_barrier` to
# `leave_barrier` for all the time it is not leaving, so every stop finds
# it there and it parks where it leaves. `inside` tells the stopper that it
# has entered, before the stop is sent.
def hold_in_allocator(flag : Flag) : Nil
  IyiThread.release_gate_arm
  while flag.stop.get == 0_i64
    IyiHeap.enter_barrier
    flag.inside.set(1_i64)
    began = IyiMark.now_ns
    while flag.stop.get == 0_i64 && !IyiHeap.stop_requested?
      if IyiMark.now_ns &- began > 20000000000_u64
        message = "SETUP: release: the holder never received a stop request\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      IyiThread.spin_pause
    end
    flag.inside.set(0_i64)
    IyiHeap.leave_barrier
  end
end

flag = Flag.new
held = IyiThread.start { hold_in_allocator(flag) }
deadline = IyiMark.now_ns &+ 20000000000_u64
while flag.inside.get == 0_i64
  if IyiMark.now_ns >= deadline
    print "SETUP: release: the holder never entered the allocator\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
IyiRuntimeLock.lock
others = IyiThread.stop_others
IyiThread.resume_others(others)
waited = IyiThread.release_gate_counted_out?
IyiRuntimeLock.unlock
reached, expired = IyiThread.release_gate_open
flag.stop.set(1_i64)
held.join
if !reached || expired
  print "SETUP: release: the held thread did not remain at its park\n"
  __iyi_exit(76)
end
fail("release: the release waited for the thread it let go") if waited
puts "release: the held thread parked inside the allocator, and the release did not wait for it"
IYI
step "a release beside a thread held in the allocator, which it does not wait for"
mkdir -p gated/iyi waiting/iyi
cp "$REPO"/src/iyi/*.iyi gated/iyi/
awk -v gate=gate.part '
  /^    # ── Roots / { while ((getline line < gate) > 0) print line; roots++ }
  /^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ { print; print "      fun thread_gate_exit = _exit(status : Int32) : NoReturn"; darwin_exit++; next }
  /^      count_in\(page \+ IYI_TC_RESUMED\)$/ { print "      release_gate_hold(line, \"SETUP: release: held thread gate timed out\\n\")"; hook++ }
  { print }
  END { if (roots != 1 || hook != 1 || darwin_exit != 1) exit 3 }
' "$REPO/src/iyi/thread.iyi" > gated/iyi/thread.iyi || { echo "the park or the roots are not in thread.iyi any more"; exit 1; }
if ! IYI_PATH="$WORK/gated${PSEP}$REPO/src" "$IYI" build --release release.iyi -o release > build-release.log 2>&1; then
  cat build-release.log; exit 1
fi
timeout -k 5 120 ./release > release.txt 2>&1
code=$?
if [ "$code" -eq 76 ]; then cat release.txt; exit 76; fi
if [ "$code" -ne 0 ] || ! grep -qxF 'release: the held thread parked inside the allocator, and the release did not wait for it' release.txt; then
  echo "the release control failed (exit $code):"; cat release.txt; exit 1
fi
sed 's/^/  /' release.txt

step "failure proof: a release that waits for the threads it let go is caught on its one run"
cp "$REPO"/src/iyi/*.iyi waiting/iyi/
awk '
  /^        @@owed = @@deferred$/ { print; print "        release_gate_wait_resumed(page, @@owed.to_u64)"; deferred++; next }
  /^        @@owed = others$/ { print; print "        release_gate_wait_resumed(page, @@owed.to_u64)"; owed++; next }
  { print }
  END { if (deferred != 1 || owed != 1) exit 3 }
' gated/iyi/thread.iyi > waiting/iyi/thread.iyi || { echo "the release is not in thread.iyi any more"; exit 1; }
if ! IYI_PATH="$WORK/waiting${PSEP}$REPO/src" "$IYI" build --release release.iyi -o release-waiting > build-waiting.log 2>&1; then
  cat build-waiting.log; exit 1
fi
timeout -k 5 120 ./release-waiting > waiting.txt 2>&1
code=$?
if [ "$code" -eq 76 ]; then cat waiting.txt; exit 76; fi
if [ "$code" -ne 1 ] || ! grep -q '^FAIL: release: the release waited for the thread it let go$' waiting.txt; then
  echo "the release check did not fire on its one run (exit $code):"; cat waiting.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: release:' waiting.txt)"

# ── 5. Failure proof: a stopped thread's frames are roots ─────────────────
# The walk over stopped threads removed from the root set, in a copy of
# the prelude built against through IYI_PATH; nothing in the tree is
# touched. Every collection another thread triggers then frees this
# thread's list, and the check names the node on a free list.
step "failure proof: without the thread-root walk a live list is swept"
mkdir -p patched/iyi
cp "$REPO"/src/iyi/*.iyi patched/iyi/
awk '{ sub(/each_thread_root\(visit\)/, "each_global_root(visit)"); print }' \
  "$REPO/src/iyi/prelude.iyi" > patched/iyi/prelude.iyi
cmp -s patched/iyi/prelude.iyi "$REPO/src/iyi/prelude.iyi" && { echo "the awk found nothing to change"; exit 1; }
if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/thread_exercise.iyi" -o unrooted > build-unrooted.log 2>&1; then
  cat build-unrooted.log; exit 1
fi
# `-k`: Git Bash's TERM can be lost on a native program, and a deadline
# that does not end the run is a job that hangs to its own limit.
timeout -k 5 120 ./unrooted 8 > unrooted.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "on a free list" unrooted.txt; then
  echo "the live-list check did not fire (exit $code):"; tail -5 unrooted.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 'on a free list' unrooted.txt)"

# The same program, two hundred more times, on Windows. Its threads fail
# while collections run, and each run has to end: leaving with
# `ExitProcess`, 3 runs in 70 here never did - the last thread sat in
# `NtTerminateProcess`, and neither `timeout` nor `Stop-Process` could end
# it; on a runner this proof hung until the job was cancelled at 81
# minutes - and with `TerminateProcess` 0 in 1,150 hung. A run is a
# fraction of a second. A run ends by exit 1 at the check that names the
# node on a free list, or at the runtime's "iyi: out of memory": this copy
# sweeps live lists, and a thread that reads a swept node can ask for a
# size made of garbage - run 53 of 200 did so on a runner (CI job
# 128176433783), and it ended, which is what this loop is here to prove.
# The single run above still has to name the free list.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    step "failure proof, again: two hundred runs, and every one ends"
    again=1
    while [ "$again" -le 200 ]; do
      timeout -k 5 30 ./unrooted 8 > unrooted-again.txt 2>&1
      code=$?
      if [ "$code" -ne 1 ] || ! grep -qE "on a free list|^iyi: out of memory$" unrooted-again.txt; then
        echo "run $again exited $code:"; tail -3 unrooted-again.txt; exit 1
      fi
      again=$((again + 1))
    done
    echo "  two hundred of two hundred exit 1"
    ;;
esac

# ── 5b. Failure proof: a finished thread's fibers leave the registry ──────
# The thread's retirement from the scheduler taken out of a copy of the
# runtime: every thread that ran fibers leaves its main fiber on the list,
# and the exercise's count names them.
step "failure proof: a finished thread's main fiber left registered is named"
mkdir -p stale/iyi
cp "$REPO"/src/iyi/*.iyi stale/iyi/
awk '/^      IyiScheduler.retire_thread$/ { found = 1; next } { print } END { if (!found) exit 3 }' \
  "$REPO/src/iyi/thread.iyi" > stale/iyi/thread.iyi || { echo "the retirement this proof removes is not in thread.iyi any more"; exit 1; }
if ! IYI_PATH="$WORK/stale${PSEP}$REPO/src" "$IYI" build "$REPO/bench/thread_exercise.iyi" -o stale-threads > build-stale.log 2>&1; then
  cat build-stale.log; exit 1
fi
timeout -k 5 120 ./stale-threads 8 > stale.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "registry:" stale.txt; then
  echo "the registry check did not fire (exit $code):"; tail -5 stale.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 'registry:' stale.txt | sed 's/^FAIL: //')"

# ── 5c. A task being switched to is a root ────────────────────────────────
# A switch marked the fiber it enters running before its stack was the
# thread's, and the fiber walk skips the running one: a thread stopped
# between the two had that fiber's stack scanned by nobody, and what only
# it named was freed. The fiber is marked on its own stack now. Two tasks per thread hand a token back and forth,
# each holding a list only its own stack names, while the main thread
# collects every millisecond; each checks its list every 64 trips.
step "a task a thread is switching into keeps its objects"
cat > switching.iyi <<'IYI'
@[Unsafe("the tallies live in a page from __iyi_mmap read as atomic words, so counting allocates nothing the collector sees")]
module switching

import std/gc::{GC}

class Node
  getter value : Int64
  getter next_node : Node?

  def initialize(@value : Int64, @next_node : Node?)
  end
end

def build(n : Int32, seed : Int64) : Node?
  head = nil.as(Node?)
  n.times { |i| head = Node.new(seed + i.to_i64, head) }
  head
end

def intact?(head : Node?, n : Int32, seed : Int64) : Bool
  i = n - 1
  cur = head
  while cur.is_a?(Node)
    return false if cur.value != seed + i.to_i64
    i = i - 1
    cur = cur.next_node
  end
  i == -1
end

class Tally
  @@page = 0_u64

  def self.setup : Nil
    @@page = __iyi_mmap(4096_u64).address
  end

  def self.wrong : Pointer(Atomic(UInt64))
    Pointer(Atomic(UInt64)).new(@@page)
  end

  def self.finished : Pointer(Atomic(UInt64))
    Pointer(Atomic(UInt64)).new(@@page + 8_u64)
  end
end
{% if flag?(:skipping_force) %}
# Addresses in this mapping are not roots; the sweep's flags can be read
# without following links in nodes that may have been freed.
class Ledger
  @@page = 0_u64

  def self.setup : Nil
    @@page = __iyi_mmap(8192_u64).address
  end

  def self.record(side : Int32, head : Node?) : Nil
    index = 0
    node = head
    while node.is_a?(Node)
      Pointer(Atomic(UInt64)).new(@@page + (side * 300 + index).to_u64 * 8_u64).value.set(node.object_id)
      node = node.next_node
      index = index + 1
    end
  end

  def self.freed : Int32
    count = 0
    600.times do |index|
      address = Pointer(Atomic(UInt64)).new(@@page + index.to_u64 * 8_u64).value.get
      if address == 0_u64
        print "FAIL: skipping: the ledger was not populated\n"
        __iyi_exit(1)
      end
      count = count + 1 if IyiMark.flags(address) & IyiHeap::FREE_FLAG != 0
    end
    count
  end
end
{% end %}


def pair(id : Int32, trips : Int32) : Nil
  there = Channel(Int32).new(1)
  back = Channel(Int32).new(1)
  group do |g|
    2.times do |side|
      g.spawn do
        seed = (id * 10 + side).to_i64 * 1000000_i64
        mine = build(300, seed)
        {% if flag?(:skipping_force) %}
        Ledger.record(side, mine)
        {% end %}
        wrong = 0
        trips.times do |t|
          if side == 0
            there.send(t)
            back.receive
          else
            there.receive
            back.send(t)
          end
          {% if flag?(:skipping_force) %}
          IyiThread.release_gate_arm if id == 1 && side == 0 && t == 2
          {% end %}
          build(20, 0_i64) if t % 8 == 0
          wrong = wrong + 1 if t % 64 == 0 && !intact?(mine, 300, seed)
        end
        Tally.wrong.value.add(wrong.to_u64)
        Tally.finished.value.add(1_u64)
        0
      end
    end
    0
  end
end

Tally.setup
count = 6
{% if flag?(:skipping_force) %}
IyiMark.auto = false
Ledger.setup
count = 1
{% end %}
threads = [] of IyiThread
count.times do |id|
  threads << IyiThread.start { pair(id + 1, 100000); nil }
end
{% if flag?(:skipping_force) %}
# Collect once while the switch is held. Read the sweep flags before any
# allocation can reuse the unrooted nodes recorded in the mmap ledger.
deadline = IyiMark.now_ns &+ 20000000000_u64
while !IyiThread.release_gate_held? && IyiMark.now_ns < deadline
  IyiThread.yield_cpu
end
if !IyiThread.release_gate_held?
  print "SETUP: skipping: the armed switch never reached the gate\n"
  __iyi_exit(76)
end
if IyiThread.release_gate_expired?
  print "SETUP: skipping: the hold deadline elapsed before the collection\n"
  __iyi_exit(76)
end
GC.collect
if IyiThread.release_gate_expired?
  print "SETUP: skipping: the hold deadline elapsed during the collection\n"
  __iyi_exit(76)
end
freed = Ledger.freed
if IyiThread.release_gate_expired?
  print "SETUP: skipping: the hold deadline elapsed before the ledger was read\n"
  __iyi_exit(76)
end
if freed != 0
  puts "FAIL: skipping: #{freed} live nodes of a task marked running before its switch are on a free list after the collection"
  __iyi_exit(1)
end
puts "skipping: held=1 collected=1 expired=0 freed=0"
__iyi_exit(0)
{% end %}
while Tally.finished.value.get < 12_u64
  GC.collect
  sleep(1)
end
threads.each { |th| th.join }
puts "wrong=#{Tally.wrong.value.get}"
IYI
if ! "$IYI" build switching.iyi -o switching > build-switching.log 2>&1; then
  cat build-switching.log; exit 1
fi
run=1
while [ "$run" -le 5 ]; do
  timeout -k 5 120 ./switching > switching.txt 2>&1
  code=$?
  if [ "$code" -ne 0 ] || ! grep -q '^wrong=0$' switching.txt; then
    echo "run $run exited $code:"; tail -3 switching.txt; exit 1
  fi
  run=$((run + 1))
done
echo "  five runs, no list lost"

# Hold the switch before the planted early Running write is followed by a
# context swap. A single collection must free nodes belonging to the skipped
# target; the mmap ledger observes the free flags without reading freed nodes.
step "failure proof: a fiber marked running before the switch loses its list"
mkdir -p skipping/iyi
cp "$REPO"/src/iyi/*.iyi skipping/iyi/
# The gate's functions go into the copy's thread.iyi, before its roots.
splice_gate() {
  awk -v gate=gate.part '
    /^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ { print; print "      fun thread_gate_exit = _exit(status : Int32) : NoReturn"; darwin_exit++; next }
    /^    # ── Roots/ { while ((getline line < gate) > 0) print line; roots++ }
    { print }
    END { if (roots != 1 || darwin_exit != 1) exit 3 }
  ' "$REPO/src/iyi/thread.iyi" > "$1"
}
splice_gate skipping/iyi/thread.iyi || { echo "the roots are not in thread.iyi any more"; exit 1; }
awk '
  /^    st.current = fiber$/ { print "    fiber.state = IyiFiberState::Running"; print "    IyiThread.release_gate_hold(IyiThread.current_line, \"SETUP: skipping: held switch gate timed out\\n\")"; found++ }
  { print }
  END { if (found != 1) exit 3 }
' "$REPO/src/iyi/concurrency.iyi" > skipping/iyi/concurrency.iyi || { echo "the switch's current-fiber line is not in concurrency.iyi any more"; exit 1; }
if ! IYI_PATH="$WORK/skipping${PSEP}$REPO/src" "$IYI" build switching.iyi -Dskipping_force -o skipping-run > build-skipping.log 2>&1; then
  cat build-skipping.log; exit 1
fi
timeout -k 5 120 ./skipping-run > skipping.txt 2>&1
code=$?
if [ "$code" -eq 76 ]; then cat skipping.txt; exit 76; fi
if [ "$code" -ne 1 ] || ! grep -qEx 'FAIL: skipping: [1-9][0-9]* live nodes of a task marked running before its switch are on a free list after the collection' skipping.txt; then
  echo "the fiber marked running early was not caught on its one run (exit $code):"; tail -3 skipping.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: skipping' skipping.txt)"

# The same hold after the switch scans both lists, so no node is free.
step "the same hold after the switch, with the fiber already running: every list holds"
mkdir -p skipping-ctl/iyi
cp "$REPO"/src/iyi/*.iyi skipping-ctl/iyi/
splice_gate skipping-ctl/iyi/thread.iyi || { echo "the roots are not in thread.iyi any more"; exit 1; }
awk '
  /^    current.state = IyiFiberState::Running$/ { print; print "    IyiThread.release_gate_hold(IyiThread.current_line, \"SETUP: skipping: held switch gate timed out\\n\")"; found++; next }
  { print }
  END { if (found != 1) exit 3 }
' "$REPO/src/iyi/concurrency.iyi" > skipping-ctl/iyi/concurrency.iyi || { echo "the running write is not in concurrency.iyi any more"; exit 1; }
if ! IYI_PATH="$WORK/skipping-ctl${PSEP}$REPO/src" "$IYI" build switching.iyi -Dskipping_force -o skipping-ctl-run > build-skipping-ctl.log 2>&1; then
  cat build-skipping-ctl.log; exit 1
fi
timeout -k 5 120 ./skipping-ctl-run > skipping-ctl.txt 2>&1
code=$?
if [ "$code" -eq 76 ]; then cat skipping-ctl.txt; exit 76; fi
if [ "$code" -ne 0 ] || ! grep -qxF 'skipping: held=1 collected=1 expired=0 freed=0' skipping-ctl.txt; then
  echo "the hook-only control failed (exit $code):"; tail -3 skipping-ctl.txt; exit 1
fi
echo "  hook-only control: held=1 collected=1 expired=0 freed=0"

# Windows' `SuspendThread` asks for the suspend and returns, and the thread
# runs on until `GetThreadContext` waits for it. The stop read the
# allocator's word in between, so a thread that ran on into `take` was
# stopped inside it, which the deferral exists to prevent: the program
# above died of a memory fault once in the 54 runs CI made of it. A copy
# of the runtime makes the run-on likely - every suspend taken back and asked
# again, for up to 2 ms, until the context is read with the thread inside the
# allocator, or 2 ms pass. The five runs below say the lists hold when it
# lands inside. They do not force the landing, so the landing itself is not
# proven here (listed in the header as not forced).
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    runon='function runon(pad) {
      print pad "until_ns = __iyi_monotonic_ns + 2000000_i64"
      print pad "while __iyi_monotonic_ns < until_ns"
      print pad "  LibC.ResumeThread(handle)"
      print pad "  while __iyi_monotonic_ns < until_ns && !IyiHeap.cache_inside?(IyiHeap.read64(cursor + IYI_TL_CACHE))"
      print pad "  end"
      print pad "  LibC.SuspendThread(handle)"
      print pad "  IyiRoots.capture_thread_registers(handle, cursor + IYI_TL_SPILL)"
      print pad "  break if IyiHeap.cache_inside?(IyiHeap.read64(cursor + IYI_TL_CACHE))"
      print pad "end"
    }'
    step "a stop whose suspend lands inside the allocator keeps every list"
    mkdir -p late/iyi
    cp "$REPO"/src/iyi/*.iyi late/iyi/
    awk "$runon"' /^            sp = IyiRoots\.capture_thread_registers\(handle, cursor \+ IYI_TL_SPILL\)$/ { runon("            "); found = 1 } { print } END { if (!found) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > late/iyi/thread.iyi || { echo "the stop's context read is not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/late${PSEP}$REPO/src" "$IYI" build switching.iyi -o late-run > build-late.log 2>&1; then
      cat build-late.log; exit 1
    fi
    run=1
    while [ "$run" -le 5 ]; do
      timeout -k 5 120 ./late-run > late.txt 2>&1
      code=$?
      if [ "$code" -ne 0 ] || ! grep -q '^wrong=0$' late.txt; then
        echo "run $run with late suspends exited $code:"; tail -3 late.txt; exit 1
      fi
      run=$((run + 1))
    done
    echo "  five runs, no list lost"
    # ── 15. The handshake: the armed thread is held inside `take` ─────────
    # The same rendezvous runs in both copies: the stopper first sees the
    # armed owner outside `take`, lets it enter the fast path, suspends it
    # again, and captures its actual registers and sp. The control reads the
    # allocator depth after that capture, as shipped. The broken copy uses
    # the earlier depth instead. A world-stopped snapshot distinguishes a
    # deferred owner from one incorrectly held inside the allocator.
    cat > early.part <<'IYI'
    # Copy-only state for the forced run-on after the first context capture.
    IYI_EARLY_TARGET  = 384_u64
    IYI_EARLY_GO      = 448_u64
    IYI_EARLY_HELD    = 512_u64
    IYI_EARLY_OPEN    = 576_u64
    IYI_EARLY_LAPSED  = 640_u64
    IYI_EARLY_ARMED   = 704_u64
    IYI_EARLY_SEEN    = 768_u64
    IYI_EARLY_BEFORE  = 832_u64
    IYI_EARLY_AFTER   = 896_u64
    IYI_EARLY_SP2     = 960_u64
    IYI_EARLY_STOPPED = 1024_u64
    IYI_EARLY_PARKED  = 1088_u64
    IYI_EARLY_SAME_SP = 1152_u64
    IYI_EARLY_SNAPSHOT = 1216_u64

    def self.early_setup : Nil
      word(control + IYI_EARLY_ARMED).value.set(0_u64)
    end

    def self.early_arm : Nil
      page = control
      word(page + IYI_EARLY_ARMED).value.set(@@line)
      word(page + IYI_EARLY_TARGET).value.set(@@line)
    end

    def self.early_target?(line : UInt64) : Bool
      line != 0_u64 && word(control + IYI_EARLY_TARGET).value.get == line
    end

    def self.early_go? : Bool
      go = word(control + IYI_EARLY_GO).value.get
      go != 0_u64 && go == @@line
    end

    def self.early_open : Nil
      word(control + IYI_EARLY_OPEN).value.set(1_u64)
    end

    def self.early_take_hook : Nil
      # Allocations before early_setup must not race to create control.
      page = @@control
      return if page == 0_u64
      go = word(page + IYI_EARLY_GO).value.get
      return if go == 0_u64 || go != @@line
      began = IyiMark.now_ns
      word(page + IYI_EARLY_HELD).value.set(1_u64)
      while word(page + IYI_EARLY_OPEN).value.get == 0_u64
        if IyiMark.now_ns &- began >= 5000000000_u64
          message = "SETUP: early: the gate inside take never opened\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(76)
        end
        spin_pause
      end
    end

    # A setup failure of the rendezvous ends the run here, by its own named
    # sentence, before any path reaches the scanner with a stale stack
    # pointer. The stopper writes and exits; it never returns a stale sp.
    def self.early_setup_fail(message : String) : Nil
      __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
      __iyi_exit(76)
    end

    def self.early_rendezvous(cursor : UInt64, handle : Pointer(Void), sp : UInt64) : UInt64
      page = control
      return sp unless early_target?(cursor)
      word(page + IYI_EARLY_TARGET).value.set(0_u64)
      cache = IyiHeap.read64(cursor + IYI_TL_CACHE)
      before = IyiHeap.cache_inside?(cache) ? 1_u64 : 0_u64
      word(page + IYI_EARLY_BEFORE).value.set(before)
      word(page + IYI_EARLY_SEEN).value.set(1_u64)
      return sp if before != 0_u64
      word(page + IYI_EARLY_GO).value.set(cursor)
      if LibC.ResumeThread(handle) != 1_i32
        early_setup_fail("SETUP: early: the armed thread could not be resumed\n")
      end
      began = IyiMark.now_ns
      while word(page + IYI_EARLY_HELD).value.get == 0_u64
        if IyiMark.now_ns &- began >= 5000000000_u64
          word(page + IYI_EARLY_LAPSED).value.set(1_u64)
          word(page + IYI_EARLY_GO).value.set(0_u64)
          early_setup_fail("SETUP: early: the armed thread never reached the hook inside take\n")
        end
        yield_cpu
      end
      word(page + IYI_EARLY_GO).value.set(0_u64)
      if LibC.SuspendThread(handle) != 0_i32
        early_setup_fail("SETUP: early: the armed thread could not be suspended\n")
      end
      captured = IyiRoots.capture_thread_registers(handle, cursor + IYI_TL_SPILL)
      if captured == 0_u64
        word(page + IYI_EARLY_LAPSED).value.set(2_u64)
        early_setup_fail("SETUP: early: the second context capture returned no stack\n")
      end
      word(page + IYI_EARLY_AFTER).value.set(IyiHeap.cache_inside?(cache) ? 1_u64 : 0_u64)
      word(page + IYI_EARLY_SP2).value.set(captured)
      early_open
      captured
    end

    # Called after the stop's deferral wait, before the marker reads roots.
    def self.early_stopped : Nil
      page = control
      return if word(page + IYI_EARLY_SEEN).value.get == 0_u64
      return if word(page + IYI_EARLY_SNAPSHOT).value.get != 0_u64
      line = word(page + IYI_EARLY_ARMED).value.get
      cache = IyiHeap.read64(line + IYI_TL_CACHE)
      captured = word(page + IYI_EARLY_SP2).value.get
      word(page + IYI_EARLY_STOPPED).value.set(IyiHeap.cache_inside?(cache) ? 1_u64 : 0_u64)
      word(page + IYI_EARLY_PARKED).value.set(word(page + IYI_TC_SUSPENDED).value.get)
      same = captured != 0_u64 && IyiHeap.read64(line + IYI_TL_SP) == captured
      word(page + IYI_EARLY_SAME_SP).value.set(same ? 1_u64 : 0_u64)
      word(page + IYI_EARLY_SNAPSHOT).value.set(1_u64)
    end

    def self.early_value(offset : UInt64) : UInt64
      word(control + offset).value.get
    end
IYI
    # Both copies run the same rendezvous after the first capture. Only the
    # broken copy moves the allocator-depth decision before that capture.
    early_thread() {
      awk -v gate=early.part -v mode="$1" '
        /^    # ── Roots/ { while ((getline line < gate) > 0) print line; roots++ }
        /^            sp = IyiRoots\.capture_thread_registers\(handle, cursor \+ IYI_TL_SPILL\)$/ {
          if (mode == "forced") {
            print "            early_armed = IyiThread.early_target?(cursor)"
            print "            early_inside = false"
            print "            early_inside = IyiHeap.cache_inside?(IyiHeap.read64(cursor + IYI_TL_CACHE)) if early_armed"
          }
          print
          print "            sp = IyiThread.early_rendezvous(cursor, handle, sp)"
          capture++; next
        }
        mode == "forced" && /^            if IyiHeap\.cache_inside\?\(cache\)$/ {
          print "            if (early_armed && early_inside) || (!early_armed && IyiHeap.cache_inside?(cache))"
          decision++; next
        }
        /^        while word\(page \+ IYI_TC_SUSPENDED\)\.value\.get < deferred\.to_u64$/ {
          print "        early_deadline = IyiMark.now_ns &+ 20000000000_u64"
          print
          print "          if IyiMark.now_ns >= early_deadline"
          print "            message = \"SETUP: early: the deferred owner never parked\\n\""
          print "            __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
          print "            __iyi_exit(76)"
          print "          end"
          bounded++; next
        }
        /^      IyiStat\.bump\(IyiStat::STOPS, 1_u64\)$/ { print "      IyiThread.early_stopped"; snapshot++ }
        { print }
        END { if (roots != 1 || capture != 1 || bounded != 1 || snapshot != 1 || (mode == "forced" && decision != 1)) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    # The copy of prelude.iyi: `take`'s fast path calls the hook after its stamp.
    early_prelude() {
      awk '
        /^      def self\.take\(size : UInt64, clear : Bool, bits : UInt64, type_id : UInt64\) : UInt64$/ { declarations++; intake = 1; print; next }
        intake && /^      end$/ { intake = 0; closures++; print; next }
        intake && /^ *stamp\(table, index, head, bits, type_id\)$/ { ind = substr($0, 1, match($0, /[^ ]/) - 1); print; print ind "IyiThread.early_take_hook"; stamps++; next }
        { print }
        END { if (declarations != 1 || closures != 1 || stamps != 1) exit 3 }
      ' "$REPO/src/iyi/prelude.iyi" > "$1"
    }
    cat > early.iyi <<'IYI'
class Flag
  getter waiting : Atomic(Int64)
  getter release : Atomic(Int64)

  def initialize
    @waiting = Atomic(Int64).new(0_i64)
    @release = Atomic(Int64).new(0_i64)
  end
end

class Node
  getter value : Int64
  getter next_node : Node?

  def initialize(@value : Int64, @next_node : Node?)
  end
end

def fill(n : Int32) : Node?
  head = nil.as(Node?)
  n.times { |i| head = Node.new(999_i64, head) }
  head
end


{% if flag?(:early_force) %}
IyiMark.auto = false
IyiMark.workers = 0_u64
IyiThread.early_setup
{% end %}
flag = Flag.new
owner = IyiThread.start do
  warm = fill(400)
  warm = nil
  IyiThread.early_arm
  flag.waiting.set(1_i64)
  deadline = IyiMark.now_ns &+ 20000000000_u64
  while !IyiThread.early_go? && flag.release.get == 0_i64
    if IyiMark.now_ns >= deadline
      print "SETUP: early: the owner was never let go\n"
      __iyi_exit(76)
    end
    IyiThread.spin_pause
  end
  kept = Node.new(42_i64, nil)
  kept.value
end
deadline = IyiMark.now_ns &+ 20000000000_u64
while flag.waiting.get == 0_i64
  if IyiMark.now_ns >= deadline
    print "SETUP: early: the owner never armed\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
IyiMark.collect
flag.release.set(1_i64)
IyiThread.early_open
owner.join
lapsed = IyiThread.early_value(IyiThread::IYI_EARLY_LAPSED)
if lapsed == 1_u64
  print "SETUP: early: the armed thread never reached the hook inside take\n"
  __iyi_exit(76)
end
if lapsed == 2_u64
  print "SETUP: early: the second context capture returned no stack\n"
  __iyi_exit(76)
end
held = IyiThread.early_value(IyiThread::IYI_EARLY_HELD)
seen = IyiThread.early_value(IyiThread::IYI_EARLY_SEEN)
before = IyiThread.early_value(IyiThread::IYI_EARLY_BEFORE)
after = IyiThread.early_value(IyiThread::IYI_EARLY_AFTER)
snapshot = IyiThread.early_value(IyiThread::IYI_EARLY_SNAPSHOT)
stopped = IyiThread.early_value(IyiThread::IYI_EARLY_STOPPED)
parked = IyiThread.early_value(IyiThread::IYI_EARLY_PARKED)
same_sp = IyiThread.early_value(IyiThread::IYI_EARLY_SAME_SP)
puts "early: held=#{held} before=#{before} after=#{after} stopped=#{stopped} parked=#{parked}"
if held != 1_u64 || seen != 1_u64 || before != 0_u64 || after != 1_u64 || snapshot != 1_u64
  print "SETUP: early: the rendezvous did not take the armed thread from outside take to inside it\n"
  __iyi_exit(76)
end
if stopped == 1_u64 && parked == 0_u64 && same_sp == 1_u64
  puts "early: the second captured sp was stored on the stopped line"
  print "FAIL: early: a stop held a thread inside take on a decision read before it went in\n"
  __iyi_exit(1)
end
if stopped != 0_u64 || parked != 1_u64
  print "SETUP: early: the stop neither parked nor held the armed thread\n"
  __iyi_exit(76)
end
puts "early: the stop deferred the thread after the second context capture"
IYI
    step "the late context capture is followed by a fresh allocator-depth check"
    mkdir -p early-ctl/iyi early-fz/iyi
    cp "$REPO"/src/iyi/*.iyi early-ctl/iyi/
    early_prelude early-ctl/iyi/prelude.iyi || { echo "SETUP: early: the take fast-path anchors changed"; exit 76; }
    early_thread control early-ctl/iyi/thread.iyi || { echo "SETUP: early: the thread anchors changed"; exit 76; }
    if ! IYI_PATH="$WORK/early-ctl${PSEP}$REPO/src" "$IYI" build early.iyi -Dearly_force -o early-ctl-run > build-early-ctl.log 2>&1; then
      cat build-early-ctl.log; exit 76
    fi
    win_native 60 "the late-capture control" ./early-ctl-run > early-ctl-raw.txt 2>&1
    code=$?
    if [ "$code" -eq 76 ]; then cat early-ctl-raw.txt; exit 76; fi
    tr -d '\r' < early-ctl-raw.txt > early-ctl.txt
    if [ "$code" -ne 0 ] || ! grep -qxF 'early: held=1 before=0 after=1 stopped=0 parked=1' early-ctl.txt || ! grep -qxF 'early: the stop deferred the thread after the second context capture' early-ctl.txt; then
      echo "the control did not defer the armed thread (exit $code):"; cat early-ctl.txt; exit 1
    fi
    printf '  control: exit 0, %s\n' "$(grep -m1 '^early: held=' early-ctl.txt)"
    step "failure proof: a stop uses the allocator depth read before the second context capture"
    cp "$REPO"/src/iyi/*.iyi early-fz/iyi/
    early_prelude early-fz/iyi/prelude.iyi || { echo "SETUP: early: the take fast-path anchors changed"; exit 76; }
    early_thread forced early-fz/iyi/thread.iyi || { echo "SETUP: early: the thread anchors changed"; exit 76; }
    if ! IYI_PATH="$WORK/early-fz${PSEP}$REPO/src" "$IYI" build early.iyi -Dearly_force -o early-fz-run > build-early-fz.log 2>&1; then
      cat build-early-fz.log; exit 76
    fi
    win_native 60 "the stale-decision proof" ./early-fz-run > early-fz-raw.txt 2>&1
    code=$?
    if [ "$code" -eq 76 ]; then cat early-fz-raw.txt; exit 76; fi
    tr -d '\r' < early-fz-raw.txt > early-fz.txt
    if [ "$code" -ne 1 ] || ! grep -qxF 'early: held=1 before=0 after=1 stopped=1 parked=0' early-fz.txt || ! grep -qxF 'early: the second captured sp was stored on the stopped line' early-fz.txt || ! grep -qxF 'FAIL: early: a stop held a thread inside take on a decision read before it went in' early-fz.txt; then
      echo "the stale allocator decision was not caught on its one run (exit $code):"; cat early-fz.txt; exit 1
    fi
    printf '  exits 1 at "%s" (%s)\n' 'FAIL: early: a stop held a thread inside take on a decision read before it went in' "$(grep -m1 '^early: held=' early-fz.txt)"
    ;;
esac

# ── 5d. The first collection's helpers ────────────────────────────────────
# How many helpers a mark may use is decided at the first collection, and
# the word saying it was decided was written before the count: a thread
# that read between the two started no helper, then read the count again,
# handed the mark to a helper 0 that did not exist, and every collection
# after waited on it forever - 31 runs in 200 of this program on a
# twelve-core Windows machine. Eight threads cross the first budget
# together, each holding a list past the stop's bound so the mark goes
# beside the program; a hundred runs, and every one must end.
step "threads crossing the first budget together: a hundred runs, and every one ends"
cat > first.iyi <<'IYI'
module first

import std/gc::{GC}

class Node
  getter value : Int64
  getter next_node : Node?

  def initialize(@value : Int64, @next_node : Node?)
  end
end

def build(n : Int32) : Node?
  head = nil.as(Node?)
  n.times { |i| head = Node.new(i.to_i64, head) }
  head
end

threads = [] of IyiThread
8.times do
  threads << IyiThread.start do
    keep = build(3000)
    20.times { build(3000) }
    puts "lost" unless keep.is_a?(Node)
    nil
  end
end
threads.each { |th| th.join }
GC.collect
puts "collected"
IYI
if ! "$IYI" build first.iyi -o first > build-first.log 2>&1; then
  cat build-first.log; exit 1
fi
run=1
while [ "$run" -le 100 ]; do
  timeout -k 5 30 ./first > first.txt 2>&1
  code=$?
  if [ "$code" -ne 0 ] || ! grep -q '^collected' first.txt; then
    echo "run $run exited $code (124 is the harness's timeout):"; tail -3 first.txt; exit 1
  fi
  run=$((run + 1))
done
echo "  a hundred of a hundred ended"

# ── 5e. A line `puts` writes is one write ─────────────────────────────────
# `STDOUT` is sync, and `write_line` wrote the text and then the newline:
# four threads of 20,000 `puts` each left 750 of 80,000 lines merged with
# another thread's, on Windows into a file. Every line must come out whole.
step "four threads printing at once: every line whole"
cat > whole_lines.iyi <<'IYI'
threads = [] of IyiThread
4.times do |t|
  threads << IyiThread.start do
    20000.times { |i| puts "thread-#{t}-line-#{i}-of-twenty-thousand" }
    nil
  end
end
threads.each { |th| th.join }
IYI
if ! "$IYI" build whole_lines.iyi -o whole_lines > build-whole_lines.log 2>&1; then
  cat build-whole_lines.log; exit 1
fi
./whole_lines > whole_lines.txt 2>&1
total=$(wc -l < whole_lines.txt | tr -d ' ')
broken=$(LC_ALL=C grep -cvE '^thread-[0-3]-line-[0-9]+-of-twenty-thousand$' whole_lines.txt)
if [ "$total" -ne 80000 ] || [ "$broken" -ne 0 ]; then
  echo "  $broken of $total lines are not one thread's whole line"; exit 1
fi
echo "  80000 lines from four threads, none merged"

# ── 5f. A finished thread asks the registry under the lock ────────────────
# A thread's retirement unlinks its main fiber only if the registry holds
# it: the fiber is the head or has a fiber before it. Both words are other
# threads' to rewrite as they link and unlink their own fibers, and read
# without the lock the answer was no for a fiber the registry held - the
# head read before a neighbour's unregister made this fiber the head, the
# back link after that unregister cleared it - and the main fiber stayed
# on the list, naming a stack that was gone: the exercise's registry check
# fired once in 24 runs on the M2 (S6 bench, flag off). Here two threads
# make their main fibers in turn, so the second's is before the first's;
# the first ends, and the second 100 ms after it. Copies of the runtime
# hold a 300 ms window between the head's read and the back link's, for a
# fiber that is not the head: under the lock the second's unregister waits
# for the window and nothing is left on the registry, five runs of five;
# with the lock taken out of the ask, as it was, the second unlinks itself
# inside the window and the first's main fiber is left, five of five.
step "two neighbours retire together: the registry is asked under the lock"
cat > neighbours.iyi <<'IYI'
@[Unsafe("the threads' turns are words of a page from __iyi_mmap read as atomics, and the first reads its own fiber's back link, which only the registry's writers change")]
module neighbours

class Turns
  @@page = 0_u64

  def self.setup : Nil
    @@page = __iyi_mmap(4096_u64).address
  end

  def self.word(index : UInt64) : Pointer(Atomic(UInt64))
    Pointer(Atomic(UInt64)).new(@@page + index * 64_u64)
  end
end

def wait_for(index : UInt64) : Nil
  while Turns.word(index).value.get == 0_u64
  end
end

def registered : Int32
  count = 0
  fiber = IyiScheduler.first_fiber
  while fiber.is_a?(IyiFiber)
    count = count + 1
    fiber = fiber.next_fiber
  end
  count
end

Turns.setup
IyiScheduler.current
before = registered
first = IyiThread.start do
  IyiScheduler.current
  Turns.word(0_u64).value.set(1_u64)
  wait_for(1_u64)
  Turns.word(3_u64).value.set(1_u64) if IyiScheduler.current.prev_fiber.is_a?(IyiFiber)
  Turns.word(2_u64).value.set(1_u64)
  nil
end
second = IyiThread.start do
  wait_for(0_u64)
  IyiScheduler.current
  Turns.word(1_u64).value.set(1_u64)
  wait_for(2_u64)
  gap = __iyi_monotonic_ns + 100_000_000_i64
  while __iyi_monotonic_ns < gap
  end
  nil
end
first.join
second.join
puts "behind=#{Turns.word(3_u64).value.get} left=#{registered - before}"
IYI
window='/^  def self\.registered\?\(fiber : IyiFiber\) : Bool$/ { inside = 1 }
  inside && /^  end$/ { inside = 0 }
  inside && unlocked && /^    IyiRuntimeLock\.(un)?lock$/ { dropped++; next }
  { print }
  inside && /^    head = @@all_head$/ {
    print "    if !(head.is_a?(IyiFiber) && head.object_id == fiber.object_id)"
    print "      window = __iyi_monotonic_ns + 300_000_000_i64"
    print "      while __iyi_monotonic_ns < window"
    print "      end"
    print "    end"
    found = 1
  }
  END { if (!found || (unlocked && dropped != 2)) exit 3 }'
for copy in window unlocked; do
  mkdir -p "$copy/iyi"
  cp "$REPO"/src/iyi/*.iyi "$copy/iyi/"
  awk -v unlocked="$([ "$copy" = unlocked ] && echo 1)" "$window" \
    "$REPO/src/iyi/concurrency.iyi" > "$copy/iyi/concurrency.iyi" || { echo "the registry's ask is not in concurrency.iyi any more"; exit 1; }
done
if ! "$IYI" build neighbours.iyi -o neighbours > build-neighbours.log 2>&1; then
  cat build-neighbours.log; exit 1
fi
for copy in window unlocked; do
  if ! IYI_PATH="$WORK/$copy${PSEP}$REPO/src" "$IYI" build neighbours.iyi -o "neighbours-$copy" > "build-neighbours-$copy.log" 2>&1; then
    cat "build-neighbours-$copy.log"; exit 1
  fi
done
for run in neighbours neighbours-window neighbours-unlocked; do
  want=0
  [ "$run" = neighbours-unlocked ] && want=1
  again=1
  while [ "$again" -le 5 ]; do
    timeout -k 5 30 "./$run" > "$run.txt" 2>&1
    code=$?
    if [ "$code" -ne 0 ] || ! grep -qx "behind=1 left=$want" "$run.txt"; then
      echo "$run, run $again, exited $code where it should leave $want fiber(s) registered:"; tail -3 "$run.txt"; exit 1
    fi
    again=$((again + 1))
  done
done
echo "  five runs of five each: none left as the tree asks, none with the window under the lock, one left in every run with the lock taken out"

# ── 6. Share: what a thread's block may capture is decided at compile time ─
# SPEC.md III.4.4's marker, gating III.4.11's block: a value whose type has
# a mutable field — here an `Array`, whose size is assigned by its own
# methods — cannot be captured by a block another thread runs, and the
# compiler names the variable, the type and the field that failed. The
# exercise itself captures integers and passes; this program must not
# compile.
step "failure proof: a block capturing a mutable value does not compile"
cat > unshared.iyi <<'IYI'
items = [1, 2, 3]
t = IyiThread.start do
  items.size
  nil
end
t.join
IYI
if "$IYI" build unshared.iyi -o unshared > build-unshared.log 2>&1; then
  echo "a block capturing an Array compiled:"; cat build-unshared.log; exit 1
fi
if ! grep -q "captures \`items : Array(Int32)\`, which is not Share" build-unshared.log; then
  echo "the refusal did not name the capture:"; cat build-unshared.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is not Share' build-unshared.log | sed 's/^Error: //')"

# `self` is captured by a receiverless call as much as by an instance
# variable: `bump` written for `self.bump` in the block of a method of a
# Counter whose `bump` does `@n += 1`, twenty million times beside its
# starter's twenty million, compiled and counted 28936626 of 40000000,
# while `@n += 1` in the block itself was refused. A method of a Share
# self, and a class method calling another receiverless, still build and
# run.
step "failure proof: a block calling a method of a self that is not Share does not compile"
cat > selfcall.iyi <<'IYI'
class Counter
  @n = 0

  def bump : Nil
    @n += 1
  end

  def run : Nil
    t = IyiThread.start do
      bump
      nil
    end
    t.join
  end
end

Counter.new.run
IYI
cat > selfcall_shared.iyi <<'IYI'
class Greeter
  def initialize(@name : String)
  end

  def greeting : String
    "hi #{@name}"
  end

  def run : Nil
    t = IyiThread.start do
      puts greeting
      nil
    end
    t.join
  end

  def self.twice(n : Int32) : Int32
    n * 2
  end

  def self.go : Nil
    t = IyiThread.start do
      puts twice(21)
      nil
    end
    t.join
  end
end

Greeter.new("ada").run
Greeter.go
IYI
if "$IYI" build selfcall.iyi -o selfcall > build-selfcall.log 2>&1; then
  echo "a block calling a receiverless method of a Counter compiled:"; cat build-selfcall.log; exit 1
fi
if ! grep -q "captures \`self : Counter\`, which is not Share: Counter's field @n is assigned in \`bump\`" build-selfcall.log; then
  echo "the refusal did not name self:"; cat build-selfcall.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is not Share' build-selfcall.log | sed 's/^Error: //')"
if ! "$IYI" build selfcall_shared.iyi -o selfcall_shared > build-selfcall-shared.log 2>&1; then
  echo "receiverless calls on a Share self and on a class were refused:"; cat build-selfcall-shared.log; exit 1
fi
if [ "$(./selfcall_shared | tr -d '\r' | tr '\n' ' ')" != "hi ada 42 " ]; then
  echo "receiverless calls on a Share self and on a class built, but printed:"; ./selfcall_shared; exit 1
fi
echo "  a Share self's method and a class method, called receiverless, still build and print hi ada 42"

# The structural scan for an assigned field reads every method the type
# has, not only the ones its class and superclasses declare, and reads
# macro code as what it expands to. A `bump` from an included `module`, and
# one whose `@n += 1` sat inside `{% if true %}` or in a macro it called,
# each compiled, and two threads bumping the counter two million times each
# counted 2336841 and 2343960 of 4000000; each is refused by its field now.
step "failure proof: a field assigned by a mixin's method or by macro code is not Share"
for shape in mixin macro_if macro_call; do
  case "$shape" in
    mixin) bump='include Bump' ;;
    macro_if) bump='def bump : Nil
    {% if true %}
      @n += 1
    {% end %}
  end' ;;
    macro_call) bump='macro incr
    @n += 1
  end

  def bump : Nil
    incr
  end' ;;
  esac
  cat > "assigned_$shape.iyi" <<IYI
module Bump
  def bump : Nil
    @n += 1
  end
end

class Counter
  $bump

  def initialize
    @n = 0_i64
  end
end

c = Counter.new
t = IyiThread.start do
  c.bump
  nil
end
t.join
IYI
  if "$IYI" build "assigned_$shape.iyi" -o "assigned_$shape" > "build-assigned-$shape.log" 2>&1; then
    echo "a counter bumped by $shape code compiled:"; cat "build-assigned-$shape.log"; exit 1
  fi
  if ! grep -q "Counter's field @n is assigned in \`bump\`" "build-assigned-$shape.log"; then
    echo "the $shape refusal did not name the field:"; cat "build-assigned-$shape.log"; exit 1
  fi
done
echo "  refused by its field three ways: a mixin's method, {% if %} and a macro call"

# An address is a write the scan cannot see: `pointerof(@n).value += 1` in
# `poke` read as no assignment, so the Counter was Share, and two threads
# poking it 100 million times each counted 122761325 of 200000000. A field
# whose address a method other than `initialize` takes is mutable now.
step "failure proof: a field given out by pointerof is not Share"
cat > addressed.iyi <<'IYI'
@[Unsafe("poke writes the counter through pointerof, the address the Share refusal must name")]
class Counter
  def initialize(@n : Int32)
  end

  def poke : Nil
    pointerof(@n).value += 1
  end
end

c = Counter.new(0)
t = IyiThread.start do
  c.poke
  nil
end
t.join
IYI
if "$IYI" build addressed.iyi -o addressed > build-addressed.log 2>&1; then
  echo "a counter written through pointerof compiled:"; cat build-addressed.log; exit 1
fi
if ! grep -q "Counter's field @n is given out by \`pointerof\` in \`poke\`" build-addressed.log; then
  echo "the pointerof refusal did not name the field:"; cat build-addressed.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is not Share' build-addressed.log | sed 's/^Error: //')"

# ── 6b. A captured local is one cell, and nothing assigns it after the start
# A Share type makes a value safe to read from two threads, not a variable
# safe to write: a captured local is one cell both threads reach. `count`
# added to two million times by a thread and two million by its starter
# compiled, and counted 2684265, 2355445 and 4000000 on three runs. The
# block assigning it, and the starter assigning it after the start, are
# refused by name now; a local assigned before the start, and a block's
# own local captured on each call, still build and run.
step "failure proof: a captured local the thread or its starter assigns does not compile"
cat > raced.iyi <<'IYI'
count = 0
t = IyiThread.start do
  2000000.times { count += 1 }
  nil
end
2000000.times { count += 1 }
t.join
puts count
IYI
cat > reassigned.iyi <<'IYI'
limit = 1
t = IyiThread.start do
  puts limit
  nil
end
limit = 2
t.join
IYI
cat > assigned_before.iyi <<'IYI'
total = 0
[1, 2, 3].each { |v| total += v }
3.times do |i|
  part = total * 10 + i
  t = IyiThread.start do
    puts part
    nil
  end
  t.join
end
IYI
if "$IYI" build raced.iyi -o raced > build-raced.log 2>&1; then
  echo "a thread assigning a captured local compiled:"; cat build-raced.log; exit 1
fi
if ! grep -q "assigns \`count\`, a local of the code that started the thread" build-raced.log; then
  echo "the refusal did not name the variable:"; cat build-raced.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'assigns `count`' build-raced.log | sed 's/^Error: //')"
if "$IYI" build reassigned.iyi -o reassigned > build-reassigned.log 2>&1; then
  echo "a captured local assigned after the thread started compiled:"; cat build-reassigned.log; exit 1
fi
if ! grep -q "\`limit\` is assigned here, after the thread has started" build-reassigned.log; then
  echo "the refusal did not name the variable:"; cat build-reassigned.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is assigned here' build-reassigned.log | sed 's/^Error: //')"
# The advice names what iyi has to keep a value two threads write: an
# `Atomic`, or a `Mutex` from std/mutex. It once said "or behind a
# `Mutex`" before there was one; the module is named now, so the advice
# leads somewhere.
if ! grep -q 'Keep the value in an `Atomic`, or behind a `Mutex` (std/mutex)' build-raced.log || ! grep -q 'or behind a `Mutex` (std/mutex)' build-reassigned.log; then
  echo "the advice does not name Atomic and std/mutex's Mutex:"; cat build-raced.log build-reassigned.log; exit 1
fi
# The same line inside `{% if true %}` or `{% for %}`: the walk read the
# macro's text rather than its expansion, so it compiled, and a thread
# reading a captured `Int64 | Float64` its starter kept reassigning that
# way counted 243585 torn reads in a debug build.
for flow in if for; do
  case "$flow" in
    if) open='{% if true %}' ;;
    for) open='{% for i in [1] %}' ;;
  esac
  cat > "reassigned_$flow.iyi" <<IYI
limit = 1
t = IyiThread.start do
  puts limit
  nil
end
$open
  limit = 2
{% end %}
t.join
IYI
  if "$IYI" build "reassigned_$flow.iyi" -o "reassigned_$flow" > "build-reassigned-$flow.log" 2>&1; then
    echo "a captured local assigned after the start inside {% $flow %} compiled:"; cat "build-reassigned-$flow.log"; exit 1
  fi
  if ! grep -q "\`limit\` is assigned here, after the thread has started" "build-reassigned-$flow.log"; then
    echo "the {% $flow %} refusal did not name the variable:"; cat "build-reassigned-$flow.log"; exit 1
  fi
done
echo "  and refused the same inside {% if %} and {% for %}"
if ! "$IYI" build assigned_before.iyi -o assigned_before > build-assigned-before.log 2>&1; then
  echo "locals assigned before the start were refused:"; cat build-assigned-before.log; exit 1
fi
if [ "$(./assigned_before | tr -d '\r' | tr '\n' ' ')" != "60 61 62 " ]; then
  echo "locals assigned before the start built, but read:"; ./assigned_before; exit 1
fi
echo "  a local assigned before the start, and a block's own local, still build and read 60 61 62"

# ── 6c. A String is Share, and so is what holds one immutably ──────────────
# `String#size` caches the character count in `@length`, the one write a
# string has after it is built, and the structural scan read it as a
# mutable field: `s = "x"` captured by a thread's block was refused with
# "String's field @length is assigned in `size`", and with it a struct
# holding a string and `List(String)`. The cache is idempotent - every
# thread writes the same count of the same bytes - so String is trusted.
# A type that assigns its own String field after construction still is not.
step "a String, a struct holding one and a List(String) are captured; a field assigned later is not"
cat > strings.iyi <<'IYI'
module strings

import std/list::{List}

struct User
  getter name : String

  def initialize(@name : String)
  end
end

s = "x"
u = User.new("ada")
l = List.new(["a", "b"])
t = IyiThread.start do
  puts "#{s} #{s.size} #{u.name} #{l.size}"
  nil
end
t.join
IYI
if ! "$IYI" build strings.iyi -o strings > build-strings.log 2>&1; then
  echo "a block capturing a String, a User and a List(String) was refused:"; cat build-strings.log; exit 1
fi
if [ "$(./strings | tr -d '\r')" != "x 1 ada 2" ]; then
  echo "the block capturing strings built, but printed:"; ./strings; exit 1
fi
echo "  a String, a struct holding one and a List(String) captured, and read x 1 ada 2"
cat > renamed.iyi <<'IYI'
module renamed

class Tag
  def initialize(@name : String)
  end

  def rename(to : String) : Nil
    @name = to
  end
end

tag = Tag.new("a")
t = IyiThread.start do
  tag.rename("b")
  nil
end
t.join
IYI
if "$IYI" build renamed.iyi -o renamed > build-renamed.log 2>&1; then
  echo "a block capturing a Tag whose String field is reassigned compiled:"; cat build-renamed.log; exit 1
fi
if ! grep -q "Tag's field @name is assigned in \`rename\`" build-renamed.log; then
  echo "the refusal did not name the field:"; cat build-renamed.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is not Share' build-renamed.log | sed 's/^Error: //')"

# ── 6d. A constant the block names is module-level state ──────────────────
# SPEC.md III.4.5: module-level mutable state is not reachable from another
# thread. The block names a constant in its own text rather than capturing
# it, so the closure's variables never listed it: `COUNTS = [0]` with
# `COUNTS[0] += 1` run a million times in the block and a million by its
# starter compiled and printed 1061337, and `C2 = Counter.new` bumped the
# same way printed 1404865. Each is refused by the constant's name now; a
# constant whose type is Share - an integer, a String, a List - is read
# from the thread as before.
step "failure proof: a block naming a constant that is not Share does not compile"
cat > constant_array.iyi <<'IYI'
COUNTS = [0]
t = IyiThread.start do
  COUNTS[0] += 1
  nil
end
t.join
IYI
cat > constant_counter.iyi <<'IYI'
class Counter
  @n = 0

  def bump : Nil
    @n += 1
  end
end

C2 = Counter.new
t = IyiThread.start do
  C2.bump
  nil
end
t.join
IYI
cat > constant_shared.iyi <<'IYI'
module constant_shared

import std/list::{List}

LIMIT = 3
GREETING = "hi"
NAMES = List.new(["a", "b"])
t = IyiThread.start do
  puts "#{GREETING} #{LIMIT} #{NAMES.size}"
  nil
end
t.join
IYI
if "$IYI" build constant_array.iyi -o constant_array > build-constant-array.log 2>&1; then
  echo "a block naming an Array constant compiled:"; cat build-constant-array.log; exit 1
fi
if ! grep -q "names the constant \`COUNTS : Array(Int32)\`, which is not Share" build-constant-array.log; then
  echo "the refusal did not name the constant:"; cat build-constant-array.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is not Share' build-constant-array.log | sed 's/^Error: //')"
if "$IYI" build constant_counter.iyi -o constant_counter > build-constant-counter.log 2>&1; then
  echo "a block naming a Counter constant compiled:"; cat build-constant-counter.log; exit 1
fi
if ! grep -q "names the constant \`C2 : Counter\`, which is not Share: Counter's field @n is assigned in \`bump\`" build-constant-counter.log; then
  echo "the refusal did not name the constant:"; cat build-constant-counter.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is not Share' build-constant-counter.log | sed 's/^Error: //')"
if ! "$IYI" build constant_shared.iyi -o constant_shared > build-constant-shared.log 2>&1; then
  echo "a block naming Share constants was refused:"; cat build-constant-shared.log; exit 1
fi
if [ "$(./constant_shared | tr -d '\r')" != "hi 3 2" ]; then
  echo "a block naming Share constants built, but printed:"; ./constant_shared; exit 1
fi
echo "  an Int32, a String and a List(String) constant still build and read hi 3 2"

# A class variable is module-level state too, and the block names it with
# nothing the closure lists: a class method whose thread block and starter
# each ran `@@count += 1` two million times compiled, and printed 2548908
# and 2461914 of 4000000. One written after its initializer - by the block
# or by a method - is one cell every thread shares, and one whose type is
# not Share is refused as a constant is; one only its initializer writes,
# of a Share type, is read from the thread as before.
step "failure proof: a block naming a class variable written again, or not Share, does not compile"
cat > classvar_assigned.iyi <<'IYI'
class Tally
  @@count = 0

  def self.run : Nil
    t = IyiThread.start do
      @@count += 1
      nil
    end
    t.join
  end
end

Tally.run
IYI
cat > classvar_written.iyi <<'IYI'
class Tally
  @@count = 0

  def self.bump : Nil
    @@count += 1
  end

  def self.run : Nil
    t = IyiThread.start do
      puts @@count
      nil
    end
    bump
    t.join
  end
end

Tally.run
IYI
cat > classvar_array.iyi <<'IYI'
class Tally
  @@items = [1, 2, 3]

  def self.run : Nil
    t = IyiThread.start do
      puts @@items.size
      nil
    end
    t.join
  end
end

Tally.run
IYI
cat > classvar_shared.iyi <<'IYI'
module classvar_shared

import std/list::{List}

class Tally
  @@limit = 3
  @@name = "x"
  @@names : List(String) = List.new(["a", "b"])

  def self.run : Nil
    t = IyiThread.start do
      puts "#{@@name} #{@@limit} #{@@names.size}"
      nil
    end
    t.join
  end
end

Tally.run
IYI
for shape in assigned written array; do
  case "$shape" in
    assigned) said="assigns \`@@count\`, a class variable, so every thread that reaches it shares one mutable cell" ;;
    written) said="names the class variable \`@@count\`, which is written after its initializer (in \`bump\`)" ;;
    array) said="names the class variable \`@@items : Array(Int32)\`, which is not Share" ;;
  esac
  if "$IYI" build "classvar_$shape.iyi" -o "classvar_$shape" > "build-classvar-$shape.log" 2>&1; then
    echo "a block naming a class variable ($shape) compiled:"; cat "build-classvar-$shape.log"; exit 1
  fi
  if ! grep -qF "$said" "build-classvar-$shape.log"; then
    echo "the class variable refusal ($shape) did not say what it should:"; cat "build-classvar-$shape.log"; exit 1
  fi
  printf '  refused: %s\n' "$(grep -m1 'class variable' "build-classvar-$shape.log" | sed 's/^Error: //')"
done
if ! "$IYI" build classvar_shared.iyi -o classvar_shared > build-classvar-shared.log 2>&1; then
  echo "a block naming class variables only their initializers write was refused:"; cat build-classvar-shared.log; exit 1
fi
if [ "$(./classvar_shared | tr -d '\r')" != "x 3 2" ]; then
  echo "a block naming class variables only their initializers write built, but printed:"; ./classvar_shared; exit 1
fi
echo "  an Int32, a String and a List(String) class variable only their initializers write still build and read x 3 2"

# ── 7. Windows: a program ends while a collection stops it ────────────────
# A thread runs collections back to back - each one stops the main thread -
# while the main thread comes to the end of the program. Back into the C
# runtime, that end was `ExitProcess`, which ended the collecting thread
# with the main thread still suspended: the process never ended, its one
# thread in `NtTerminateProcess` and beyond `timeout`; 35 runs in 100 here,
# 20 in 40 held to four cores. `main` ends through `TerminateProcess` now:
# 0 in 1,000. The proof puts the return back, and the emitted IR of main
# shows it on one build: the end must be the `__iyi_exit` call with no `ret`
# in main. Two hundred runs stay as the stress test of the end itself.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    step "a program ends while another thread's collections stop it: two hundred runs, and every one ends"
    cat > ends.iyi <<'IYI'
head = [] of Int32
n = 0
while n < 2000
  head << n
  n = n + 1
end
t = IyiThread.start do
  while true
    IyiMark.collect
  end
  nil
end
until_ns = IyiMark.now_ns + 20000000_u64
while IyiMark.now_ns < until_ns
end
print "ended with #{head.size}\n"
IYI
    cat > release.ps1 <<'PS1'
param([string]$Name)
Add-Type -Namespace IyiGate -Name Thread -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr OpenThread(int access, bool inherit, int id);
[DllImport("kernel32.dll")] public static extern int ResumeThread(System.IntPtr thread);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr handle);
'@
Get-Process $Name -ErrorAction SilentlyContinue | ForEach-Object {
  $process = $_
  $process.Threads | ForEach-Object {
    $thread = [IyiGate.Thread]::OpenThread(2, $false, $_.Id)
    if ($thread -ne [System.IntPtr]::Zero) { [void][IyiGate.Thread]::ResumeThread($thread); [void][IyiGate.Thread]::CloseHandle($thread) }
  }
  [void]$process.WaitForExit(5000)
}
"left: $(@(Get-Process $Name -ErrorAction SilentlyContinue).Count)"
PS1
    release() { powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$WORK/release.ps1")" -Name "$1"; }
    # Windows' `main` ends in `__iyi_exit`, which ends the process with
    # `TerminateProcess`. In LLVM IR that is the call and then `unreachable`,
    # with no `ret` in main. A copy that returns to the C runtime has a `ret`
    # where the call was, and its run is the one that can hang under a
    # collection. The check reads main's body from the emitted IR, on one
    # build, so it is the same on every run.
    ends_in_exit() {
      awk '
        /^define .*@main\(/ { definitions++; inmain = 1; next }
        inmain && /^}/ { closed++; inmain = 0; next }
        inmain && /^  / {
          if ($0 ~ /^  ret /) rets++
          if ($0 ~ /(^|[[:space:]])call[[:space:]].*@__iyi_exit\(/) exits++
          prev = last; last = $0
        }
        END {
          if (definitions != 1 || closed != 1 || last == "") {
            print "SETUP: ends: missing or malformed main in the IR"; exit 76
          }
          if (rets > 0) {
            print "FAIL: main returns to the C runtime instead of ending in __iyi_exit"; exit 1
          }
          if (exits >= 1 && last ~ /^  unreachable([[:space:]]|$)/ && prev ~ /(^|[[:space:]])call[[:space:]].*@__iyi_exit\(/) {
            print "main ends in __iyi_exit"; exit 0
          }
          print "SETUP: ends: main has no final exit call followed by unreachable"; exit 76
        }
      ' "$1"
    }
    if ! "$IYI" build --release --emit llvm-ir ends.iyi -o ends > build-ends.log 2>&1; then
      cat build-ends.log; exit 1
    fi
    ends_in_exit ends.ll > ends-end.txt
    code=$?
    if [ "$code" -eq 76 ]; then cat ends-end.txt; exit 76; fi
    if [ "$code" -ne 0 ] || [ "$(cat ends-end.txt)" != 'main ends in __iyi_exit' ]; then
      echo "the healthy program does not end in __iyi_exit:"; cat ends-end.txt; exit 1
    fi
    again=1
    while [ "$again" -le 200 ]; do
      timeout -k 1 30 ./ends > ends.txt 2>&1
      code=$?
      if [ "$code" -ne 0 ] || ! grep -q "^ended with 2000$" ends.txt; then
        echo "run $again exited $code:"; tail -3 ends.txt; release ends; exit 1
      fi
      again=$((again + 1))
    done
    echo "  two hundred of two hundred ended"

    step "failure proof: a program that ends back in the C runtime fails the end check on its one build"
    mkdir -p crt-end/iyi
    cp "$REPO"/src/iyi/*.iyi crt-end/iyi/
    # The pair is the win32 end of `fun main`; `def exit` writes the same
    # `__iyi_exit(status)` line, so only the one after the flush is taken.
    awk '
      /^fun main\(argc : Int32, argv : UInt8\*\*\) : Int32$/ { main++; inmain = 1 }
      inmain && /^end$/ { inmain = 0; closed++ }
      inmain && after && /^    __iyi_exit\(status\)$/ { exits++; after = 0; next }
      after { after = 0 }
      inmain && /^    LibC\.fflush\(Pointer\(Void\)\.new\(0_u64\)\)$/ { flushes++; after = 1; next }
      { print }
      END { if (main != 1 || closed != 1 || flushes != 1 || exits != 1) exit 3 }
    ' "$REPO/src/iyi/prelude.iyi" > crt-end/iyi/prelude.iyi || { echo "SETUP: ends: main flush/exit anchors changed"; exit 76; }
    if ! IYI_PATH="$WORK/crt-end${PSEP}$REPO/src" "$IYI" build --release --emit llvm-ir ends.iyi -o ends-in-crt > build-crt-end.log 2>&1; then
      cat build-crt-end.log; exit 1
    fi
    ends_in_exit ends-in-crt.ll > crt-end.txt
    code=$?
    if [ "$code" -eq 76 ]; then cat crt-end.txt; exit 76; fi
    if [ "$code" -ne 1 ]; then
      echo "the program that ends back in the C runtime did not fail correctly (exit $code):"; cat crt-end.txt; exit 1
    fi
    if [ "$(cat crt-end.txt)" != 'FAIL: main returns to the C runtime instead of ending in __iyi_exit' ]; then
      echo "the end check failed with another sentence:"; cat crt-end.txt; exit 1
    fi
    echo "  $(cat crt-end.txt)"
    ;;
esac

# ── 7b. Windows: a thread is named on its line before a stop can see it ───
# A child was linked for the stops under the runtime lock and ran at once,
# and its handle reached its line only after the lock was released: a stop
# in between suspended NULL, read sp 0 and scanned from address 0. The
# child is created suspended now, its handle written under the lock, and
# resumed after. The failure proof holds the next start after its unlock and
# before its handle is written, while a helper collects: the child runs
# unnamed meanwhile, and the copy's stop that visits its line records it and
# skips it. The child holds nothing a stop would free, so the record is
# the observable and the copy skips that line to avoid scanning address 0.
# The control holds the same start after its handle is written and before
# the thread is resumed, and records nothing.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    cat > starting.iyi <<'IYI'
class Flag
  getter stop : Atomic(Int64)
  getter ran : Atomic(Int64)
  getter opened : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @ran = Atomic(Int64).new(0_i64)
    @opened = Atomic(Int64).new(0_i64)
  end
end

class Node
  property next_node : Node?
  property value : Int64

  def initialize(@value : Int64)
    @next_node = nil
  end
end

def churn(flag : Flag) : Nil
  while flag.stop.get == 0_i64
    head : Node? = nil
    200.times do |i|
      n = Node.new(i.to_i64)
      n.next_node = head
      head = n
    end
    sum = 0_i64
    cur = head
    while cur.is_a?(Node)
      sum = sum + cur.value
      cur = cur.next_node
    end
    raise "churn sum #{sum}" if sum != 19900_i64
  end
end

def child(flag : Flag, i : Int32) : Nil
  a = [] of String
  20.times { |k| a << "child-#{i}-#{k}" }
  raise "child list" if a.size != 20 || a[19] != "child-#{i}-19"
  flag.ran.add(1_i64)
end

# The forced program's child allocates nothing, so a stop that skips its
# unnamed line frees nothing this child still holds.
def child_quiet(flag : Flag) : Nil
  # Linked until the collection that the armed start was held for is over:
  # a child that exited earlier would leave the stop nothing to visit.
  deadline = IyiMark.now_ns &+ 20000000000_u64
  while flag.opened.get == 0_i64
    if IyiMark.now_ns >= deadline
      print "SETUP: unnamed: the held child's gate never opened\n"
      __iyi_exit(76)
    end
    IyiThread.spin_pause
  end
  flag.ran.add(1_i64)
end

flag = Flag.new
churners = [] of IyiThread
started = 0
{% if flag?(:unnamed_force) %}
IyiMark.auto = false
{% else %}
2.times { churners << IyiThread.start { churn(flag) } }
{% end %}
{% if flag?(:unnamed_force) %}
# Started before the arm, so its own start is not the one held. It waits,
# with a bound of its own, for the armed start to reach its gate, collects
# while that start is held, and opens the gate. A lapsed hold or a missed
# gate ends the run with its own sentence.
helper = IyiThread.start do
  bound = IyiMark.now_ns &+ 20000000000_u64
  while !IyiThread.release_gate_held? && IyiMark.now_ns < bound
    IyiThread.yield_cpu
  end
  if !IyiThread.release_gate_held?
    print "SETUP: unnamed: the armed start never reached its gate\n"
    __iyi_exit(76)
  end
  if IyiThread.release_gate_expired?
    print "SETUP: unnamed: the hold deadline elapsed before the collection\n"
    __iyi_exit(76)
  end
  IyiMark.collect
  if IyiThread.release_gate_expired?
    print "SETUP: unnamed: the hold deadline elapsed during the collection\n"
    __iyi_exit(76)
  end
  held, expired = IyiThread.release_gate_open
  if !held || expired
    print "SETUP: unnamed: the held start gate did not open\n"
    __iyi_exit(76)
  end
  flag.opened.set(1_i64)
  nil
end
IyiThread.release_gate_arm_next
armed = IyiThread.start { child_quiet(flag) }
armed.join
helper.join
flag.stop.set(1_i64)
churners.each(&.join)
if IyiThread.release_gate_recorded?
  print "FAIL: a stop met a started thread whose handle was not yet written\n"
  __iyi_exit(1)
end
puts "unnamed: held=1 collected=1 expired=0, and no stop met a thread without its handle"
started = 1
{% else %}
deadline = __iyi_monotonic_ns + Program.args[0].to_i.to_i64 * 1_000_000_000_i64
while __iyi_monotonic_ns < deadline
  batch = [] of IyiThread
  4.times do |k|
    n = started + k
    batch << IyiThread.start { child(flag, n) }
  end
  started = started + 4
  batch.each(&.join)
end
flag.stop.set(1_i64)
churners.each(&.join)
{% end %}
raise "ran #{flag.ran.get} of #{started}" if flag.ran.get != started
puts "ok started=#{started}"
IYI
    # The gate's functions go into a copy's thread.iyi before its roots, and
    # the start is held after its unlock. `forced` creates the thread running
    # and writes its handle after the hold; `control` writes it before the
    # unlock, as shipped, and holds after. Both copies make a stop skip and
    # record a visit to a line whose handle is still 0.
    unnamed_copy() {
      awk -v gate=gate.part -v mode="$1" '
        /^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ { print; print "      fun thread_gate_exit = _exit(status : Int32) : NoReturn"; darwin_exit++; next }
        /^    # ── Roots/ { while ((getline line < gate) > 0) print line; roots++ }
        /^    def self\.start\(proc : Proc\(Nil\)\) : IyiThread$/ { starts++; in_start = 1 }
        in_start && /^      \{% elsif flag\?\(:win32\) %\}$/ { win_branches++; in_win = 1 }
        in_start && /^    end$/ { closes++; in_start = 0; in_win = 0 }
        in_win && /^        h = LibC\.CreateThread\(nil, 0_u64, Pointer\(Void\)\.new\(thread_entry\), Pointer\(Void\)\.new\(line\), 4_i32, nil\)$/ {
          created++
          print "        late = IyiThread.release_gate_take_arm"
          if (mode == "forced") print "        h = LibC.CreateThread(nil, 0_u64, Pointer(Void).new(thread_entry), Pointer(Void).new(line), (late ? 0_i32 : 4_i32), nil)"
          else print
          next
        }
        in_win && /^        IyiHeap\.write64\(line \+ IYI_TL_HANDLE, h\.address\)$/ {
          stores++
          if (created != 1 || stores != 1 || unlocks != 0) bad_order = 1
          if (mode == "forced") print "        IyiHeap.write64(line + IYI_TL_HANDLE, h.address) unless late"
          else print
          next
        }
        in_win && /^        IyiRuntimeLock\.unlock$/ {
          unlocks++
          if (created != 1 || stores != 1 || unlocks != 1) bad_order = 1
          print
          print "        IyiThread.release_gate_start_hold(line) if late"
          if (mode == "forced") print "        IyiHeap.write64(line + IYI_TL_HANDLE, h.address) if late"
          next
        }
        /^      private def self\.suspend_others\(line : UInt64\) : Int64$/ { print; print "        IyiThread.release_gate_clear_skip"; clears++; next }
        /^          LibC\.SuspendThread\(Pointer\(Void\)\.new\(IyiHeap\.read64\(cursor \+ IYI_TL_HANDLE\)\)\) if cursor != line$/ { print "          LibC.SuspendThread(Pointer(Void).new(IyiHeap.read64(cursor + IYI_TL_HANDLE))) if cursor != line && !IyiThread.release_gate_unnamed?(cursor, line)"; one++; next }
        /^        deferred = 0_i64$/ { armed_scan = 1 }
        armed_scan && /^          if cursor != line$/ { print "          if cursor != line && !IyiThread.release_gate_skipped?(cursor)"; two++; armed_scan = 0; next }
        /^        if cursor != own$/ { print "        if cursor != own && !IyiThread.release_gate_skipped?(cursor)"; roots3++; next }
        { print }
        END { if (roots != 1 || darwin_exit != 1 || starts != 1 || closes != 1 || win_branches != 1 || created != 1 || stores != 1 || unlocks != 1 || bad_order || clears != 1 || one != 1 || two != 1 || roots3 != 1) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }

    step "threads started while two others collect: three runs, and every one ends well"
    if ! "$IYI" build starting.iyi -o starting > build-starting.log 2>&1; then
      cat build-starting.log; exit 1
    fi
    run=1
    while [ "$run" -le 3 ]; do
      timeout -k 5 60 ./starting 3 > starting.txt 2>&1
      code=$?
      if [ "$code" -ne 0 ] || ! grep -q '^ok ' starting.txt; then
        echo "run $run exited $code:"; tail -3 starting.txt; exit 1
      fi
      run=$((run + 1))
    done
    echo "  three runs of three seconds, and every thread ran its body"

    step "the gate after the handle is written, the thread still suspended: one run, and nothing recorded"
    mkdir -p held/iyi
    cp "$REPO"/src/iyi/*.iyi held/iyi/
    unnamed_copy control held/iyi/thread.iyi || { echo "the start's unlock or the stop's suspend is not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/held${PSEP}$REPO/src" "$IYI" build starting.iyi -Dunnamed_force -o held-run > build-held.log 2>&1; then
      cat build-held.log; exit 1
    fi
    timeout -k 5 60 ./held-run 3 > held.txt 2>&1
    code=$?
    if [ "$code" -eq 76 ]; then cat held.txt; exit 76; fi
    if [ "$code" -ne 0 ] || ! tr -d '\r' < held.txt | grep -qFx 'unnamed: held=1 collected=1 expired=0, and no stop met a thread without its handle' || ! tr -d '\r' < held.txt | grep -qFx 'ok started=1'; then
      echo "the control held after the handle was written exited $code:"; tail -3 held.txt; exit 1
    fi
    echo "  control: exit 0, unnamed: held=1 collected=1 expired=0, and no stop met a thread without its handle"

    step "failure proof: a stop that meets a started thread before its handle is written is recorded on its one run"
    mkdir -p unnamed/iyi
    cp "$REPO"/src/iyi/*.iyi unnamed/iyi/
    unnamed_copy forced unnamed/iyi/thread.iyi || { echo "the start's unlock or the stop's suspend is not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/unnamed${PSEP}$REPO/src" "$IYI" build starting.iyi -Dunnamed_force -o unnamed-run > build-unnamed.log 2>&1; then
      cat build-unnamed.log; exit 1
    fi
    timeout -k 5 60 ./unnamed-run 3 > unnamed.txt 2>&1
    code=$?
    if [ "$code" -eq 76 ]; then cat unnamed.txt; exit 76; fi
    if [ "$code" -ne 1 ] || ! tr -d '\r' < unnamed.txt | grep -qFx 'FAIL: a stop met a started thread whose handle was not yet written'; then
      echo "the stop did not meet the unnamed thread on its one run (exit $code):"; tail -3 unnamed.txt; exit 1
    fi
    printf '  exits 1 at "%s"\n' 'FAIL: a stop met a started thread whose handle was not yet written'
    ;;
esac

# ── 7c. Windows: a stop scans no stack's guard page ──────────────────────
# A thread, or a task on its fiber stack, stopped after a frame moved sp
# below the committed stack and before its first touch of the new page
# has sp in that stack's guard page, and the scan from sp read it from the
# collecting thread: STATUS_GUARD_PAGE_VIOLATION there, and the process
# died with 0x80000001 and nothing printed, or a fiber's overflow handler
# named a "stack overflow" nobody had. The scan starts at the first
# committed page that is not a guard page now. Ten runs of the old scan
# in ten died, each inside a second; the proof puts it back.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    step "threads and tasks grow fresh stacks beside a thread collecting in a loop: three runs, and every one ends"
    cat > guard.iyi <<'IYI'
@[Unsafe("each frame writes an uninitialized pad through pointerof so a fresh stack is touched as it grows")]
class Shared
  getter stop : Atomic(Int64)
  getter grown : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @grown = Atomic(Int64).new(0_i64)
  end
end

# Sixteen words a frame, each read back after the call below returns:
# every level steps sp into a page this stack has not touched yet.
def deep(n : Int32) : Int32
  return 0 if n == 0
  pad = uninitialized UInt64[16]
  slot = pointerof(pad).as(Pointer(UInt64))
  slot.value = n.to_u64
  below = deep(n - 1)
  below + (slot.value == n.to_u64 ? 0 : 1)
end

shared = Shared.new
{% if flag?(:guard_force) %}
IyiThread.release_gate_arm_guard
{% end %}
collector = IyiThread.start do
  while shared.stop.get == 0_i64
    IyiMark.collect
  end
  nil
end
deadline = IyiMark.now_ns + Program.args[0].to_i.to_u64 * 1000000_u64
workers = [] of IyiThread
4.times do
  workers << IyiThread.start do
    while IyiMark.now_ns < deadline
      # A healthy stress only: it shows the stacks grow beside a collector
      # and that every run ends. It does not decide the guard proof (step 7c's
      # holder does); a collector that runs after the workers finish proves
      # nothing here, and that is why the proof does not use it.
      IyiThread.start do
        raise "a thread's frames read back wrong" if deep(2000) != 0
        group do |g|
          2.times { g.spawn { deep(400) } }
          0
        end
        nil
      end.join
      shared.grown.add(1_i64)
    end
    nil
  end
end
workers.each(&.join)
shared.stop.set(1_i64)
collector.join
puts "stacks grown beside a collecting thread: #{shared.grown.get > 0}"
IYI
    if ! "$IYI" build guard.iyi -o guard > build-guard.log 2>&1; then
      cat build-guard.log; exit 1
    fi
    run=1
    while [ "$run" -le 3 ]; do
      timeout -k 5 60 ./guard 2000 > guard.txt 2>&1
      code=$?
      if [ "$code" -ne 0 ] || ! grep -q '^stacks grown beside a collecting thread: true' guard.txt; then
        echo "run $run exited $code:"; tail -3 guard.txt; exit 1
      fi
      run=$((run + 1))
    done
    echo "  three runs of two seconds, and every one ended"

    # The guard scan's functions go into a copy's thread.iyi before its roots:
    # `keep` answers the committed page, as shipped (the control); the forced
    # copy answers the page one below it while the arm is up, which is the
    # guard page under a growing stack.
    cat > guard.part <<'IYI'
    # ── The guard scan (bench/thread_exercise.sh, step 7c) ─────────────────
    # Copies only: the awk in that step puts this into a copy of thread.iyi,
    # and the tree has none of it. While armed, a copy's scan of a stopped
    # stack starts inside the stack's guard page (64 bytes into it), which is
    # the guard page under a growing stack.
    IYI_GATE_GUARD = 768_u64
    IYI_GATE_GUARD_HIT = 832_u64
    IYI_GATE_HOLDER = 960_u64
    IYI_GATE_CANDIDATE = 1024_u64
    IYI_GATE_SCANNED = 1088_u64

    def self.release_gate_guard_hit?(address : UInt64) : Bool
      page = word(control + IYI_GATE_GUARD_HIT).value.get
      page != 0_u64 && address >= page && address < page + 4096_u64
    end

    def self.release_gate_arm_guard : Nil
      word(control + IYI_GATE_GUARD).value.set(1_u64)
    end

    # The guard page of the stack `sp` is in: the committed page with
    # PAGE_GUARD in its reservation, found walking up from the allocation
    # base to the top. Windows keeps one guard page at a growing stack's
    # committed edge, so this is the page a scan from below that edge reads
    # first, wherever the stack's sp sits. 0 when there is none.
    def self.guard_page_of(sp : UInt64, top : UInt64) : UInt64
      buffer = uninitialized UInt64[6]
      info = pointerof(buffer).as(Pointer(UInt64))
      if LibC.VirtualQuery(Pointer(Void).new(sp), info.as(Void*), 48_u64) == 0_u64
        message = "SETUP: guard: stack VirtualQuery failed\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      pos = info[1]
      while pos < top
        if LibC.VirtualQuery(Pointer(Void).new(pos), info.as(Void*), 48_u64) == 0_u64 || info[3] == 0_u64
          message = "SETUP: guard: reservation VirtualQuery failed\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(76)
        end
        return pos if (info[4] & 0xFFFFFFFF_u64) == 0x1000_u64 && (info[4].unsafe_shr(32_u64) & 0x100_u64) != 0_u64
        pos = info[0] + info[3]
      end
      0_u64
    end

    # The holder marks its own stack top before it holds, so the scan can
    # recognise its stack by top alone (no timing, no sp).
    def self.release_gate_holder_mark : Nil
      top = IyiHeap.read64(current_line + IYI_TL_TOP)
      word(control + IYI_GATE_HOLDER).value.set(top)
    end

    # Both copies resolve the same candidate for the holder's stack: the guard
    # page found from its allocation base. The control records the committed
    # scan start it used; the mutant scans from the guard page instead.
    def self.release_gate_candidate : UInt64
      word(control + IYI_GATE_CANDIDATE).value.get
    end

    def self.release_gate_scanned_from : UInt64
      word(control + IYI_GATE_SCANNED).value.get
    end

    def self.release_gate_guard_scan(sp : UInt64, top : UInt64, keep : Bool) : UInt64
      return first_written(sp, top) if word(control + IYI_GATE_GUARD).value.get == 0_u64
      return first_written(sp, top) if word(control + IYI_GATE_HOLDER).value.get != top
      guard = guard_page_of(sp, top)
      if guard == 0_u64
        message = "SETUP: guard: the holder has no guard page\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      word(control + IYI_GATE_CANDIDATE).value.set(guard)
      if keep
        committed = first_written(guard + 64_u64, top)
        buffer = uninitialized UInt64[6]
        info = pointerof(buffer).as(Pointer(UInt64))
        if LibC.VirtualQuery(Pointer(Void).new(committed), info.as(Void*), 48_u64) == 0_u64
          message = "SETUP: guard: normalized scan VirtualQuery failed\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(76)
        end
        if committed > sp || committed >= top || (info[4] & 0xFFFFFFFF_u64) != 0x1000_u64 || (info[4].unsafe_shr(32_u64) & 0x100_u64) != 0_u64
          message = "FAIL: guard: normalization did not find committed stack memory\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(1)
        end
        word(control + IYI_GATE_SCANNED).value.set(committed)
        return committed
      end
      word(control + IYI_GATE_GUARD_HIT).value.set(guard)
      guard + 64_u64
    end
IYI
    guard_copy() {
      awk -v gate=guard.part -v keep="$1" '
        /^    # ── Roots/ { while ((getline line < gate) > 0) print line; roots++ }
        /^            sp = first_written\(sp, top\)$/ { print "            sp = IyiThread.release_gate_guard_scan(sp, top, " keep ")"; scans++; next }
        { print }
        END { if (roots != 1 || scans != 1) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    guard_prelude() {
      awk '
        /^    if code == IYI_WIN_GUARD_PAGE$/ { guard_branch++; inside_guard = 1 }
        /^    if code == IYI_WIN_ACCESS_VIOLATION$/ { inside_guard = 0 }
        inside_guard && /^        if IyiScheduler.fiber_guard_hit\?\(faulting\)$/ {
          print "        if IyiThread.release_gate_guard_hit?(faulting)"
          print "          message = \"FAIL: guard: a stop scan began inside its guard page\\n\""
          print "          LibC.WriteFile(handle, message.to_unsafe.as(Void*), message.bytesize, pointerof(written), nil)"
          print "          __iyi_win_fault_exit"
          print "        end"
          found++
        }
        { print }
        END { if (guard_branch != 1 || found != 1) exit 3 }
      ' "$REPO/src/iyi/prelude.iyi" > "$1"
    }

    cat > guard-hold.iyi <<'IYI'
@[Unsafe("the holder marks its own stack top and then spins without allocating; the copy records are the only shared state")]
class Shared
  getter ready : Atomic(Int64)
  getter release : Atomic(Int64)

  def initialize
    @ready = Atomic(Int64).new(0_i64)
    @release = Atomic(Int64).new(0_i64)
  end
end

def hold(shared : Shared) : Nil
  {% if flag?(:guard_force) %}
  IyiThread.release_gate_holder_mark
  {% end %}
  shared.ready.set(1_i64)
  while shared.release.get == 0_i64
    IyiThread.spin_pause
  end
end

shared = Shared.new
{% if flag?(:guard_force) %}
IyiThread.release_gate_arm_guard
{% end %}
holder = IyiThread.start { hold(shared); nil }
watch = IyiMark.now_ns &+ 20000000000_u64
while shared.ready.get == 0_i64
  if IyiMark.now_ns >= watch
    print "SETUP: guard: the holder never reached its hold\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
IyiMark.collect
shared.release.set(1_i64)
holder.join
{% if flag?(:guard_force) %}
if IyiThread.release_gate_candidate == 0_u64
  print "SETUP: guard: the holder's stack has no guard page\n"
  __iyi_exit(76)
end
if IyiThread.release_gate_scanned_from == 0_u64
  print "SETUP: guard: the stop did not scan the holder's stack\n"
  __iyi_exit(76)
end
puts "guard: the stop scanned the holder's stack from its committed page"
{% end %}
IYI
    step "the holder's stack, scanned from its committed page, armed: one run, and the scan is reported"
    mkdir -p kept/iyi
    cp "$REPO"/src/iyi/*.iyi kept/iyi/
    guard_copy true kept/iyi/thread.iyi || { echo "SETUP: guard: scan anchor changed"; exit 76; }
    guard_prelude kept/iyi/prelude.iyi || { echo "SETUP: guard: fault handler anchor changed"; exit 76; }
    if ! IYI_PATH="$WORK/kept${PSEP}$REPO/src" "$IYI" build guard-hold.iyi -Dguard_force -o guard-kept > build-kept.log 2>&1; then
      cat build-kept.log; exit 76
    fi
    timeout -k 5 60 ./guard-kept > kept.txt 2>&1
    code=$?
    if [ "$code" -eq 76 ]; then cat kept.txt; exit 76; fi
    if [ "$code" -ne 0 ] || ! tr -d '\r' < kept.txt | grep -qxF "guard: the stop scanned the holder's stack from its committed page"; then
      echo "the control did not scan from its committed page (exit $code):"; tail -3 kept.txt; exit 1
    fi
    echo "  control: exit 0, guard: the stop scanned the holder's stack from its committed page"

    step "failure proof: the holder's stack scanned from its guard page dies on its one run"
    mkdir -p guarded/iyi
    cp "$REPO"/src/iyi/*.iyi guarded/iyi/
    guard_copy false guarded/iyi/thread.iyi || { echo "SETUP: guard: scan anchor changed"; exit 76; }
    guard_prelude guarded/iyi/prelude.iyi || { echo "SETUP: guard: fault handler anchor changed"; exit 76; }
    if ! IYI_PATH="$WORK/guarded${PSEP}$REPO/src" "$IYI" build guard-hold.iyi -Dguard_force -o guard-from-sp > build-guarded.log 2>&1; then
      cat build-guarded.log; exit 76
    fi
    timeout -k 5 60 ./guard-from-sp > guarded.txt 2>&1
    code=$?
    if [ "$code" -eq 76 ]; then cat guarded.txt; exit 76; fi
    if [ "$code" -ne 1 ] || ! grep -qxF 'FAIL: guard: a stop scan began inside its guard page' guarded.txt; then
      echo "the guard-page scan did not end at its sentence (exit $code):"; tail -3 guarded.txt; exit 1
    fi
    echo "  exits 1 at \"FAIL: guard: a stop scan began inside its guard page\""

    step "failure proof: an identity stack normalization rejects a guard-page input"
    mkdir -p identity/iyi
    cp kept/iyi/*.iyi identity/iyi/
    awk '
      /^      def self\.first_written\(sp : UInt64, top : UInt64\) : UInt64$/ {
        print; print "        return sp"; found++; next
      }
      { print }
      END { if (found != 1) exit 3 }
    ' kept/iyi/thread.iyi > identity/iyi/thread.iyi || { echo "SETUP: guard: normalization anchor changed"; exit 76; }
    if ! IYI_PATH="$WORK/identity${PSEP}$REPO/src" "$IYI" build guard-hold.iyi -Dguard_force -o guard-identity > build-identity.log 2>&1; then
      cat build-identity.log; exit 76
    fi
    timeout -k 5 60 ./guard-identity > identity.txt 2>&1
    code=$?
    if [ "$code" -eq 76 ]; then cat identity.txt; exit 76; fi
    if [ "$code" -ne 1 ] || ! tr -d '\r' < identity.txt | grep -qxF 'FAIL: guard: normalization did not find committed stack memory'; then
      echo "the normalization check did not fire (exit $code):"; cat identity.txt; exit 1
    fi
    echo '  exits 1 at "FAIL: guard: normalization did not find committed stack memory"'
    ;;
esac

# ── 7d. darwin: a stop names a thread only once its thread-locals are made ─
# dyld makes a thread's thread-locals at its first touch of one, a `calloc`
# of the image's whole block, and the stop's handler reads two of them. The
# parent linked a thread's line before `pthread_create`, so a stop could
# signal the thread inside that `calloc`; the handler's read made the block
# again and took the allocator's lock the interrupted call held, and
# libplatform killed the process ("Trying to recursively lock an
# os_unfair_lock") or libmalloc trapped ("ulock_wait failure"). The
# switching program above died so in 5 runs of 130 on macOS 26.6 (an M2
# Pro), and the program below in 19 of 20 (18 killed, 1 trapped), each
# inside 4 s. A thread links its own line now, after its first touch: the
# program, 3,200 threads a run, sixteen at a time beside a thread that
# collects in a loop, ran 20 runs of 20 there. The failure proof links the
# line in the parent again. Then a handler that lands before the thread's
# touch, or inside it where the allocator lets its own touch through,
# finds no line, returns without counting in, and the stop waits for it
# forever (5 runs of 5 hung so on the M2): the copy's handler aborts there
# instead, so the proof counts a kill, a trap or an abort, each by name,
# and never waits out a timeout. The M2 counted 5 aborts in 5 runs.
#
# A run is bounded by its own clock, not by a count: twenty rounds, then
# rounds until 10 s have passed, 200 at most. Every run was 200 rounds and
# held to 60 s by the harness, and macos-15's three-core runners make 54
# to 479 threads a second (147 the median, 425 runs over four runners in
# debug jobs) where the M2 makes about 1,100: 3,200 threads took 7.2 to
# 59.6 s there, and CI's job ran out the 60 s on its first run once. The
# slowest twenty rounds of 438 runs took 11.5 s, so a run ends inside
# about 23 s on that machine, and the 60 s is left to say a run hung.
case "$(uname -s)" in
  Darwin)
    step "darwin: threads born sixteen at a time beside a thread collecting in a loop, for 10 s or 3,200 threads: five runs, and every one ends well"
    cat > born.iyi <<'IYI'
module born

import std/gc::{GC}

class Flag
  getter stop : Atomic(Int64)
  getter born : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @born = Atomic(Int64).new(0_i64)
  end
end

def storm(flag : Flag) : Nil
  while flag.stop.get == 0_i64
    GC.collect
  end
end

def arrive(flag : Flag) : Nil
  flag.born.add(1_i64)
end

flag = Flag.new
stormer = IyiThread.start { storm(flag) }
rounds = Program.args[0].to_i
deadline = __iyi_monotonic_ns + Program.args[1].to_i.to_i64 * 1_000_000_000_i64
started = 0
round = 0
while round < rounds && (round < 20 || __iyi_monotonic_ns < deadline)
  batch = [] of IyiThread
  16.times { batch << IyiThread.start { arrive(flag) } }
  started = started + 16
  batch.each(&.join)
  round = round + 1
end
flag.stop.set(1_i64)
stormer.join
raise "born #{flag.born.get} of #{started}" if flag.born.get != started
puts "ok born=#{started} stops=#{IyiThread.stops}"
IYI
    if ! "$IYI" build born.iyi -o born > build-born.log 2>&1; then
      cat build-born.log; exit 1
    fi
    # In a subshell that waits, so a run a signal ends is reported here,
    # by its status, and not by the shell's job notice.
    run=1
    born=""
    while [ "$run" -le 5 ]; do
      ( timeout -k 5 60 ./born 200 10 > born.txt 2>&1; exit $? ) 2> /dev/null
      code=$?
      if [ "$code" -ne 0 ] || ! grep -q '^ok born=[0-9]* ' born.txt; then
        echo "run $run exited $code:"; tail -3 born.txt; exit 1
      fi
      born="$born $(sed -n 's/^ok born=\([0-9]*\) .*/\1/p' born.txt)"
      run=$((run + 1))
    done
    echo "  five runs, every thread born and joined:$born threads"

    step "failure proof: the line linked by the parent before the thread's first touch, as it was"
    probe='function probe(pad) {
      print pad "if line == 0"
      print pad "  message = \"iyi: proof: a stop reached a thread before it wrote its line\\n\""
      print pad "  __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
      print pad "  LibC.pthread_kill(LibC.pthread_self, 6)"
      print pad "end"
    }'
    mkdir -p unborn/iyi
    cp "$REPO"/src/iyi/*.iyi unborn/iyi/
    awk "$probe"' /^        result = LibC\.pthread_create\(Pointer\(UInt64\)\.new\(line \+ IYI_TL_HANDLE\), / {
        print "        IyiHeap.write64(line + IYI_TL_NEXT, @@lines)"; print "        @@lines = line"; print "        @@count = @@count + 1_i64"; found++ }
      /^        link\(line\)$/ { found++; next }
      /^      line = own_line$/ { print; probe("      "); found++; next }
      { print } END { if (found != 3) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > unborn/iyi/thread.iyi || { echo "the start's pthread_create, the thread's own link or the handler's line is not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/unborn${PSEP}$REPO/src" "$IYI" build born.iyi -o unborn-run > build-unborn.log 2>&1; then
      cat build-unborn.log; exit 1
    fi
    killed=0; trapped=0; aborted=0; ended=0; other=""
    run=1
    while [ "$run" -le 5 ]; do
      ( timeout -k 5 60 ./unborn-run 200 10 > unborn.txt 2>&1; exit $? ) 2> /dev/null
      code=$?
      case "$code" in
        137) killed=$((killed + 1)) ;;
        133) trapped=$((trapped + 1)) ;;
        134) grep -q '^iyi: proof: a stop reached a thread before it wrote its line' unborn.txt && aborted=$((aborted + 1)) || other="$other 134" ;;
        0) ended=$((ended + 1)) ;;
        *) other="$other $code" ;;
      esac
      run=$((run + 1))
    done
    echo "  five runs: $killed killed (SIGKILL), $trapped trapped (SIGTRAP), $aborted aborted at the handler's unwritten line (SIGABRT), $ended ended${other:+, other exits:$other}"
    if [ $((killed + trapped + aborted)) -eq 0 ]; then
      echo "five runs with the line linked before the thread's first touch: none killed, trapped or aborted"; exit 1
    fi

    ;;
esac

# ── 7e. darwin: a thread's first allocation is a root ─────────────────────
# A darwin thread wrote its stack's top on its line after
# `IyiStackGuard.install`, whose `stack_t` is the thread's first heap
# chunk. A stop between that allocation and the chunk's three stores
# scanned the stack from sp up to 0, `GC.collect` freed the chunk in its
# pause's sweep, and the stores wrote over the free batch it went onto: 7d's
# program died of SIGSEGV in 13 runs of 342 of 3,200 threads on macos-15's
# three cores, the same before the thread-local fix (6 of 115) as after it
# (5 of 103), 12 of the 13 at the centre's next pop of the class, reading
# 0x10008 - the `stack_t`'s 65,536 plus 8. Linux's top is written by the
# parent before `clone`. A darwin thread's first store is its top now. A
# copy of the runtime holds the `stack_t` in the install's frame until two
# collections have stopped the thread (50 ms at most), then asks the sweep's
# own flag whether the chunk was freed, and aborts by name if it was; every
# thread of three runs keeps it. With the top written after the install
# again, the same copy aborts, or dies of the overwritten batch: on
# macos-15, three runs of this gate aborted 9 runs of 9, and kept every
# first allocation in the fixed copy's 9.
case "$(uname -s)" in
  Darwin)
    step "darwin: a thread's first allocation, held in its frame through two collections, is not swept: three runs"
    held='function held(pad) {
      print pad "held_until = __iyi_monotonic_ns + 50_000_000_i64"
      print pad "held_from = IyiThread.stops"
      print pad "while IyiThread.stops < held_from + 2_u64 && __iyi_monotonic_ns < held_until"
      print pad "end"
      print pad "if IyiMark.flags(stack.address) & IyiHeap::FREE_FLAG != 0"
      print pad "  message = \"iyi: proof: a thread'"'"'s first allocation was swept from under it\\n\""
      print pad "  __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
      print pad "  LibC.pthread_kill(LibC.pthread_self, 6)"
      print pad "end"
    }'
    for copy in topfirst toplate; do
      mkdir -p "$copy/iyi"
      cp "$REPO"/src/iyi/*.iyi "$copy/iyi/"
      awk "$held"' /^        stack = Pointer\(UInt64\)\.malloc\(3_u64\)$/ && !found { print; held("        "); found = 1; next }
        { print } END { if (!found) exit 3 }' \
        "$REPO/src/iyi/concurrency.iyi" > "$copy/iyi/concurrency.iyi" || { echo "the stack guard's stack_t is not in concurrency.iyi any more"; exit 1; }
    done
    awk '/^        IyiHeap\.write64\(line \+ IYI_TL_TOP, IyiRoots\.discover_stack_base\)$/ && !top { top = $0; next }
      /^        IyiStackGuard\.install$/ && top { print; print top; moved = 1; next }
      { print } END { if (!top || !moved) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > toplate/iyi/thread.iyi || { echo "the thread's top or its stack guard is not in thread.iyi any more"; exit 1; }
    for copy in topfirst toplate; do
      if ! IYI_PATH="$WORK/$copy${PSEP}$REPO/src" "$IYI" build born.iyi -o "$copy-run" > "build-$copy.log" 2>&1; then
        cat "build-$copy.log"; exit 1
      fi
    done
    run=1
    while [ "$run" -le 3 ]; do
      ( timeout -k 5 60 ./topfirst-run 20 1 > topfirst.txt 2>&1; exit $? ) 2> /dev/null
      code=$?
      if [ "$code" -ne 0 ] || ! grep -q '^ok born=320 ' topfirst.txt; then
        echo "run $run exited $code:"; tail -3 topfirst.txt; exit 1
      fi
      run=$((run + 1))
    done
    echo "  three runs of 320 threads, every first allocation kept"

    step "failure proof: the top written after the stack guard's allocation, as it was"
    aborted=0; faulted=0; ended=0; other=""
    run=1
    while [ "$run" -le 3 ]; do
      ( timeout -k 5 60 ./toplate-run 20 1 > toplate.txt 2>&1; exit $? ) 2> /dev/null
      code=$?
      case "$code" in
        134) grep -q "^iyi: proof: a thread's first allocation was swept from under it" toplate.txt && aborted=$((aborted + 1)) || other="$other 134" ;;
        139) faulted=$((faulted + 1)) ;;
        0) ended=$((ended + 1)) ;;
        *) other="$other $code" ;;
      esac
      run=$((run + 1))
    done
    echo "  three runs: $aborted aborted at a swept first allocation (SIGABRT), $faulted faulted (SIGSEGV), $ended ended${other:+, other exits:$other}"
    if [ $((aborted + faulted)) -eq 0 ]; then
      echo "three runs with the top written after the stack guard's allocation: none aborted or faulted"; exit 1
    fi
    ;;
esac

# ── 7f. A stop at a fresh task's first instruction scans that task's stack ─
# On aarch64 a fresh fiber's first resume pops the whole frame
# `settle_stack` laid, so the switch's `ret` and `__iyi_fiber_main`'s first
# instruction run with sp at the fiber stack's top. The stop's scan asks
# `IyiScheduler.fiber_top_holding` which stack holds a stopped thread's sp,
# and it answered that the top was no fiber's: the scan ran from there up
# to the thread's own top, across the mappings between. On macOS 26.6, an
# M2 Pro with 10 cores, the program below without its check died so, of
# SIGSEGV or SIGBUS in the collector's `scan_range`, in 9 runs of 23 of
# 5 s, the main thread stopped at that instruction in every crash report;
# and bench/concurrency_exercise.iyi hung in 2 of 675 soak runs there,
# the one sampled where a mark helper had faulted so and its fault
# handler waited on the runtime lock (7g). With the top counted as the
# fiber's, none of 26.
# A stop lands on one of two instructions in a task's life, so a run's
# death is luck; each task asks the scan's own question of its own top
# as well, which the old bound answers wrongly every time. It asks under
# the runtime lock, as the stop does: the fiber list changes under that
# lock, and with the pool's workers starting tasks beside it the walk
# unlocked read a list mid-change. On the M2, on mt/next at 341a034b3,
# the unlocked check failed 18 of 20 runs of 5 s, with and without the
# turn-counter release; under the lock, none of 6.
case "$(uname -s)" in
  Linux | Darwin)
    step "tasks begin on fresh stacks beside a thread collecting in a loop, and each task's top is its own stack's: three runs of 5 s"
    cat > fresh.iyi <<'IYI'
module fresh

import std/gc::{GC}

class Flag
  getter stop : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
  end
end

def storm(flag : Flag) : Nil
  while flag.stop.get == 0_i64
    GC.collect
  end
end

# Where a stop finds sp at a task's first instruction on aarch64, asked of
# the scan the way the stop asks it.
def first_run : Int32
  top = IyiScheduler.current_stack_top
  IyiRuntimeLock.lock
  held = IyiScheduler.fiber_top_holding(top)
  IyiRuntimeLock.unlock
  raise "a task's stack top is no task's to the stop's scan" if held != top
  0
end

def burst : Nil
  group do |g|
    64.times do
      g.spawn do
        first_run
      end
    end
  end
end

flag = Flag.new
stormer = IyiThread.start { storm(flag) }
deadline = __iyi_monotonic_ns + Program.args[0].to_i.to_i64 * 1_000_000_000_i64
started = 0
while __iyi_monotonic_ns < deadline
  burst
  started = started + 64
end
flag.stop.set(1_i64)
stormer.join
puts "ok started=#{started} stops=#{IyiThread.stops}"
IYI
    if ! "$IYI" build fresh.iyi -o fresh > build-fresh.log 2>&1; then
      cat build-fresh.log; exit 1
    fi
    run=1
    started=""
    while [ "$run" -le 3 ]; do
      ( timeout -k 5 60 ./fresh 5 > fresh.txt 2>&1; exit $? ) 2> /dev/null
      code=$?
      if [ "$code" -ne 0 ] || ! grep -q '^ok started=[0-9]* ' fresh.txt; then
        echo "run $run exited $code:"; tail -3 fresh.txt; exit 1
      fi
      started="$started $(sed -n 's/^ok started=\([0-9]*\) .*/\1/p' fresh.txt)"
      run=$((run + 1))
    done
    echo "  three runs, every task's top its own stack's:$started tasks"

    step "failure proof: a fiber's top read as no fiber's, as it was"
    mkdir -p topless/iyi
    cp "$REPO"/src/iyi/*.iyi topless/iyi/
    awk '/^      return top if top != 0 && address <= top && address > top - IyiFiber::STACK_BYTES$/ {
        print "      return top if top != 0 && address < top && address >= top - IyiFiber::STACK_BYTES"; found = 1; next }
      { print } END { if (!found) exit 3 }' \
      "$REPO/src/iyi/concurrency.iyi" > topless/iyi/concurrency.iyi || { echo "the fiber stack's bound is not in concurrency.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/topless${PSEP}$REPO/src" "$IYI" build fresh.iyi -o topless-run > build-topless.log 2>&1; then
      cat build-topless.log; exit 1
    fi
    ( timeout -k 5 60 ./topless-run 5 > topless.txt 2>&1; exit $? ) 2> /dev/null
    code=$?
    if [ "$code" -eq 0 ] || ! grep -q "a task's stack top is no task's to the stop's scan" topless.txt; then
      echo "with a fiber's top read as no fiber's, a run exited $code:"; tail -3 topless.txt; exit 1
    fi
    echo "  the first task named its top no task's (exit $code)"
    ;;
esac

# ── 7g. A fault the stack guard does not own kills the process ───────────
# The guard's handler (`IyiStackGuard.faulted`) gives a fault away from a
# stack's edge back to the signal's default action, and built that action
# in a heap block. A mark helper has no allocator cache, and one that
# faulted inside a collection, holding the runtime lock, waited for that
# lock at the block's first touch for good: on macOS 26.6, an M2 Pro with
# 10 cores, a soak run of bench/concurrency_exercise.iyi hung so, sampled
# with its helper in `IyiRuntimeLock.lock` under the handler, under a root
# scan that had faulted. The action is in the handler's frame now. A
# helper that takes the runtime lock and stores to address 8 kills the
# process with SIGSEGV at once, on the M2 and on Linux x86_64; with the
# heap block back, the process outlives the fault by the 5 s it waits,
# and says so.
case "$(uname -s)" in
  Linux | Darwin)
    step "a mark helper's fault inside a collection kills the process"
    cat > wild.iyi <<'IYI'
@[Unsafe("a mark helper is started on a function that writes to a wild address, the fault the gate wants inside a collection")]
module wild

# A helper's life here: the runtime lock taken, as a collection on a mark
# helper holds it, then a store to an address nothing maps.
def fault_holding_the_lock(address : UInt64) : Nil
  IyiRuntimeLock.lock
  Pointer(UInt64).new(address).value = 1_u64
end

entry = ->(address : UInt64) { fault_holding_the_lock(address) }
IyiThread.start_helper(Pointer(UInt64).new(pointerof(entry).address).value, 8_u64)
deadline = __iyi_monotonic_ns + 5_000_000_000_i64
while __iyi_monotonic_ns < deadline
end
message = "the helper's fault left the process alive for 5 s\n"
__iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
__iyi_exit(3)
IYI
    if ! "$IYI" build wild.iyi -o wild > build-wild.log 2>&1; then
      cat build-wild.log; exit 1
    fi
    ( timeout -k 5 60 ./wild > wild.txt 2>&1; exit $? ) 2> /dev/null
    code=$?
    if [ "$code" -ne 139 ]; then
      echo "a helper's fault holding the runtime lock exited $code, not 139 (SIGSEGV):"; tail -3 wild.txt; exit 1
    fi
    echo "  killed by SIGSEGV (exit 139)"

    step "failure proof: the default action built in a heap block, as it was"
    mkdir -p heaped/iyi
    cp "$REPO"/src/iyi/*.iyi heaped/iyi/
    awk '/^      action = uninitialized UInt64\[4\]$/ { found++; next }
      /^      words = pointerof\(action\)\.as\(Pointer\(UInt64\)\)$/ { print "      words = Pointer(UInt64).malloc(4_u64)"; found++; next }
      { print } END { if (found != 2) exit 3 }' \
      "$REPO/src/iyi/concurrency.iyi" > heaped/iyi/concurrency.iyi || { echo "the stack guard's default action is not in concurrency.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/heaped${PSEP}$REPO/src" "$IYI" build wild.iyi -o heaped-run > build-heaped.log 2>&1; then
      cat build-heaped.log; exit 1
    fi
    ( timeout -k 5 60 ./heaped-run > heaped.txt 2>&1; exit $? ) 2> /dev/null
    code=$?
    if [ "$code" -ne 3 ] || ! grep -q "^the helper's fault left the process alive for 5 s" heaped.txt; then
      echo "with the action in a heap block, a helper's fault exited $code:"; tail -3 heaped.txt; exit 1
    fi
    echo "  the process outlived its helper's fault by 5 s"
    ;;
esac

# ── 7h. A stop sleeps on its count, and its last thread wakes it ─────────
# The stopper waited for its threads to count in, and after the release
# to count out, in a loop around `yield_cpu`; it spins a little now and
# then sleeps on the count's word (`IyiThread.wait_count`), and the thread
# that brings the count to what the stopper waits for wakes it
# (`IyiThread.count_in`). A wake that never comes is a stop that never
# ends, so the proof takes the wake out and a run hangs; the storm's
# thousands of stops are where a sleeping stopper is all but certain.
case "$(uname -s)" in
  Linux | Darwin)
    step "threads born sixteen at a time beside a thread collecting in a loop, its stops asleep on their counts: three runs, every one ends, and on Linux no more stops begin owing turns than waits for them ran out"
    cat > asleep.iyi <<'IYI'
module asleep

import std/gc::{GC}

class Flag
  getter stop : Atomic(Int64)
  getter born : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @born = Atomic(Int64).new(0_i64)
  end
end

def storm(flag : Flag) : Nil
  while flag.stop.get == 0_i64
    GC.collect
  end
end

def arrive(flag : Flag) : Nil
  flag.born.add(1_i64)
end

flag = Flag.new
stormer = IyiThread.start { storm(flag) }
rounds = Program.args[0].to_i
deadline = __iyi_monotonic_ns + Program.args[1].to_i.to_i64 * 1_000_000_000_i64
started_ns = __iyi_monotonic_ns
started = 0
round = 0
while round < rounds && (round < 20 || __iyi_monotonic_ns < deadline)
  batch = [] of IyiThread
  16.times { batch << IyiThread.start { arrive(flag) } }
  started = started + 16
  batch.each(&.join)
  round = round + 1
end
took = (__iyi_monotonic_ns - started_ns) // 1_000_000_i64
flag.stop.set(1_i64)
stormer.join
raise "born #{flag.born.get} of #{started}" if flag.born.get != started
puts "ok born=#{started} ms=#{took} stops=#{IyiThread.stops} owing=#{IyiThread.owing_stops} outwaited=#{IyiThread.turn_waits_out}"
IYI
    if ! "$IYI" build asleep.iyi -o asleep > build-asleep.log 2>&1; then
      cat build-asleep.log; exit 1
    fi
    # A stop that begins while a thread the stop before parked in the
    # runtime lock's spin still owes its try of the lock follows a wait
    # for that try that ran out, on Linux, which the proof below holds
    # to: `owing` no more than `outwaited`.
    owed() { sed -n "s/^ok .* $1=\([0-9]*\).*/\1/p" "$2"; }
    run=1
    while [ "$run" -le 3 ]; do
      ( timeout -k 5 60 ./asleep 200 10 > asleep.txt 2>&1; exit $? ) 2> /dev/null
      code=$?
      if [ "$code" -ne 0 ] || ! grep -q '^ok born=[0-9]* ms=[0-9]* .* owing=[0-9]* outwaited=[0-9]*$' asleep.txt; then
        echo "run $run exited $code:"; tail -3 asleep.txt; exit 1
      fi
      echo "  $(sed 's/^ok //' asleep.txt)"
      if [ "$(uname -s)" = Linux ] && [ "$(owed owing asleep.txt)" -gt "$(owed outwaited asleep.txt)" ]; then
        echo "run $run began $(owed owing asleep.txt) stops owing turns, after $(owed outwaited asleep.txt) waits for them ran out"; exit 1
      fi
      run=$((run + 1))
    done

    step "failure proof: the last thread to count in leaves the stopper asleep, and a run hangs"
    mkdir -p unwoken/iyi
    cp "$REPO"/src/iyi/*.iyi unwoken/iyi/
    awk '/^        return if sleeper == 0_u64 \|\| now < sleeper$/ { print "        return"; found = 1; next }
      { print } END { if (!found) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > unwoken/iyi/thread.iyi || { echo "the count's wake is not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/unwoken${PSEP}$REPO/src" "$IYI" build asleep.iyi -o unwoken-run > build-unwoken.log 2>&1; then
      cat build-unwoken.log; exit 1
    fi
    ( timeout -k 5 30 ./unwoken-run 200 10 > unwoken.txt 2>&1; exit $? ) 2> /dev/null
    code=$?
    if [ "$code" -ne 124 ]; then
      echo "with the wake taken out, a run exited $code rather than hanging:"; tail -3 unwoken.txt; exit 1
    fi
    echo "  the run hung until the 30 s timeout (exit 124)"

    # The same storm holds the collection's wait for the turns the last
    # stop's lock waiters are owed (`IyiThread.await_turns`): the release
    # waits for nobody, and without that wait the thread collecting in a
    # loop takes the runtime lock back before the threads it released
    # from the lock's spin have tried it, and they never get it. The copy
    # returns from the wait at once, and a run hangs, or ends having
    # begun stops owing turns that no wait ran out for. Whether it ends
    # is the box's: a collector preempted between its release and its
    # next lock is a turn for the threads it released. It ended on
    # ubuntu-24.04's 4-core runners in 28.3 s (run 41800443380), and on
    # Linux (12 vCPU, 7h run alone at a load average of 3.1 to 5.5) it
    # hung 8 runs of 20 past 30 s and ended 12 at 10 to 45 threads a
    # second, where the runtime made 3,200 in 1.27 to 1.92 s;
    # beside 8 busy loops it ended 10 of 10 at 262 to 877 a second, the
    # runtime's slowest 1,288 to 1,785 in the same runs; beside 11, 6 of 6
    # at 268 to 311 against the runtime's 292 to 367. The rate this proof
    # held to, a tenth of the runtime's, let all 16 loaded runs through.
    # The owing count did not: the copy began 164,689 to 464,783 stops
    # owing turns alone, 6,147 to 52,692 beside 8 loops, 86 to 311
    # beside 11, with no wait run out, and the runtime began 0 to 15,
    # never more than its waits that ran out, 108 runs of 108. darwin's
    # spinners give their core away (7i), and there the same copy made
    # its threads in 1.6 to 1.7 s, 3 runs of 3 on the M2, so the proof
    # is Linux's.
    if [ "$(uname -s)" = Linux ]; then
      step "failure proof: no wait for the released lock waiters' turns, and a run hangs or begins stops owing turns"
      mkdir -p unowed/iyi
      cp "$REPO"/src/iyi/*.iyi unowed/iyi/
      awk '/^      return if turns\.value\.get == 0_u64$/ { print "      return"; found = 1; next } { print } END { if (!found) exit 3 }' \
        "$REPO/src/iyi/thread.iyi" > unowed/iyi/thread.iyi || { echo "the wait for the turns is not in thread.iyi any more"; exit 1; }
      if ! IYI_PATH="$WORK/unowed${PSEP}$REPO/src" "$IYI" build asleep.iyi -o unowed-run > build-unowed.log 2>&1; then
        cat build-unowed.log; exit 1
      fi
      ( timeout -k 5 30 ./unowed-run 200 10 > unowed.txt 2>&1; exit $? ) 2> /dev/null
      code=$?
      if [ "$code" -eq 124 ]; then
        echo "  the run hung until the 30 s timeout (exit 124)"
      elif [ "$code" -eq 0 ] && grep -q '^ok born=[0-9]* ms=[0-9]* .* owing=[0-9]* outwaited=[0-9]*$' unowed.txt; then
        if [ "$(owed owing unowed.txt)" -le "$(owed outwaited unowed.txt)" ]; then
          echo "with the wait for the turns taken out, a run began no more stops owing turns than waits for them ran out:"; tail -3 unowed.txt; exit 1
        fi
        echo "  the run ended, $(sed 's/^ok //' unowed.txt)"
      else
        echo "with the wait for the turns taken out, a run exited $code:"; tail -3 unowed.txt; exit 1
      fi
    fi
    ;;
esac

# ── 7i. darwin: a yield is a Mach trap ──────────────────────────────────
# darwin's `IyiThread.yield_cpu` was the ARM `yield` hint, which gives the
# scheduler nothing; it is Mach's `thread_switch` with the depress option
# now (src/iyi/thread.iyi says what each call cost). The check was a ratio
# of threads born a second beside a busy process per core to the alone
# rate, and the runner moved the ratio: on Namespace's macOS 15 VM (6
# vCPUs) the hint kept 37 to 52 per cent and the switch 64 to 70 (runs
# 44271652334, 44292915166, 44358208505), so a proof that the hint falls
# under half failed some of its tries. Counted instead: each call is one
# `thread_switch` trap, and the task's `syscalls_mach` (task_events_info,
# flavor 2, its sixth word) reads the traps. A thousand calls must make at
# least a thousand traps, and the hint, which makes none, must make fewer
# than a thousand. A call makes its trap whatever else the machine is
# doing, so load on the runner does not move the count.
case "$(uname -s)" in
  Darwin)
    step "darwin: a thousand yield_cpu calls make at least a thousand Mach traps"
    cat > yield_traps.iyi <<'IYI'
@[Unsafe("the Mach trap count is read through task_info, a C call that fills Pointer.malloc memory")]
module yield_traps

lib LibTraps
  fun task_self_trap : UInt32
  fun task_info(task : UInt32, flavor : Int32, info : Int32*, count : UInt32*) : Int32
end

# The task's Mach trap count: task_events_info (TASK_EVENTS_INFO, flavor
# 2), eight 32-bit words, and syscalls_mach is the sixth of them.
def mach_traps : Int64
  info = Pointer(Int32).malloc(8_u64)
  count = Pointer(UInt32).malloc(1_u64)
  count.value = 8_u32
  return -1_i64 if LibTraps.task_info(LibTraps.task_self_trap, 2, info, count) != 0
  info[5].to_i64
end

before = mach_traps
1000.times { IyiThread.yield_cpu }
after = mach_traps
puts "yield: #{after - before} Mach traps for 1000 yield_cpu calls"
IYI
    if ! "$IYI" build yield_traps.iyi -o yield-traps > build-traps.log 2>&1; then
      cat build-traps.log; exit 1
    fi
    if ! timeout -k 5 120 ./yield-traps > traps.txt 2>&1; then
      cat traps.txt; exit 1
    fi
    traps="$(sed -n 's/^yield: \([0-9-]*\) Mach traps.*$/\1/p' traps.txt)"
    if [ -z "$traps" ] || [ "$traps" -lt 1000 ]; then
      echo "a thousand yield_cpu calls made ${traps:-no count} Mach traps, under 1,000"; cat traps.txt; exit 1
    fi
    sed 's/^/  /' traps.txt

    step "failure proof: yield_cpu as the ARM hint again, and the same calls make under a thousand traps"
    mkdir -p hinted/iyi
    cp "$REPO"/src/iyi/*.iyi hinted/iyi/
    awk '/^        LibC\.thread_switch\(0_u32, IYI_SWITCH_OPTION_DEPRESS, 1_u32\)$/ { print "        asm(\"yield\" :::: \"volatile\")"; found = 1; next }
      { print } END { if (!found) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > hinted/iyi/thread.iyi || { echo "darwin's thread_switch is not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/hinted${PSEP}$REPO/src" "$IYI" build yield_traps.iyi -o yield-traps-hinted > build-hinted.log 2>&1; then
      cat build-hinted.log; exit 1
    fi
    if ! timeout -k 5 120 ./yield-traps-hinted > hinted-traps.txt 2>&1; then
      cat hinted-traps.txt; exit 1
    fi
    hinted="$(sed -n 's/^yield: \([0-9-]*\) Mach traps.*$/\1/p' hinted-traps.txt)"
    if [ -z "$hinted" ] || [ "$hinted" -ge 1000 ]; then
      echo "with the hint, a thousand yield_cpu calls made ${hinted:-no count} Mach traps, not under 1,000"; cat hinted-traps.txt; exit 1
    fi
    echo "  with the hint, the same calls make $hinted traps: under 1,000, caught"
    ;;
esac

# ── 7j. darwin: a stop counts only the lines it can name ─────────────────
# Hold one child after TLS is established but before it links its line.
# The same copy-only observer checks the actual count and roster at entry
# to stop_others. The mutant counts in start before the held line is linked.
case "$(uname -s)" in
  Darwin)
    cat > count-roster.part <<'IYI'
    IYI_ROSTER_ARM = 384_u64
    IYI_ROSTER_HELD = 448_u64
    IYI_ROSTER_OPEN = 512_u64
    IYI_ROSTER_CHECKED = 576_u64

    def self.roster_arm : Nil
      word(control + IYI_ROSTER_ARM).value.set(1_u64)
    end
    def self.roster_held? : Bool
      word(control + IYI_ROSTER_HELD).value.get != 0_u64
    end
    def self.roster_checked? : Bool
      word(control + IYI_ROSTER_CHECKED).value.get != 0_u64
    end
    def self.roster_open : Nil
      word(control + IYI_ROSTER_OPEN).value.set(1_u64)
    end
    def self.roster_pre_link : Nil
      page = @@control
      return if page == 0_u64 || !word(page + IYI_ROSTER_ARM).value.compare_and_set(1_u64, 0_u64)[1]
      word(page + IYI_ROSTER_HELD).value.set(1_u64)
      started = IyiMark.now_ns
      while word(page + IYI_ROSTER_OPEN).value.get == 0_u64
        if IyiMark.now_ns &- started > 20000000000_u64
          message = "SETUP: roster: the held child was never opened\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          LibC.roster_exit(76_i32)
        end
        yield_cpu
      end
    end
    def self.roster_check(line : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || word(page + IYI_ROSTER_HELD).value.get == 0_u64 || word(page + IYI_ROSTER_OPEN).value.get != 0_u64
      roster = 0_i64
      cursor = @@lines
      while cursor != 0_u64
        roster += 1_i64
        cursor = IyiHeap.read64(cursor + IYI_TL_NEXT)
      end
      if @@count != roster
        message = "FAIL: roster: a thread was counted before its line was linked\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        LibC.roster_exit(1_i32)
      end
      if roster != 1_i64 || line == 0_u64
        message = "SETUP: roster: the held-child stop did not have one collector line\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        LibC.roster_exit(76_i32)
      end
      word(page + IYI_ROSTER_CHECKED).value.set(1_u64)
    end
IYI
    roster_copy() {
      awk -v part=count-roster.part -v mode="$1" '
        /^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ { print; print "      fun roster_exit = _exit(status : Int32) : NoReturn"; alias_count++; next }
        /^    # ── Roots/ { while ((getline s < part) > 0) print s; roots++ }
        /^    def self\.start\(proc : Proc\(Nil\)\) : IyiThread$/ { in_start = 1; starts++ }
        in_start && /^      \{% elsif flag\?\(:darwin\) %\}$/ { in_darwin = 1; darwin++ }
        in_start && /^      \{% elsif flag\?\(:win32\) %\}$/ { in_darwin = 0 }
        in_start && /^    end$/ { in_start = 0; in_darwin = 0; start_ends++ }
        in_darwin && /^          Pointer\(Void\)\.new\(thread_entry\), Pointer\(Void\)\.new\(line\)\)$/ {
          print
          if (mode == "forced") print "        @@count = @@count + 1_i64 if result == 0"
          created++; next
        }
        /^    def self\.run\(line : UInt64\) : Nil$/ { in_run = 1; runs++ }
        in_run && /^    end$/ { in_run = 0; run_ends++ }
        in_run && /^        link\(line\)$/ {
          print "        IyiThread.roster_pre_link"
          if (mode == "forced") {
            print "        IyiRuntimeLock.lock"
            print "        IyiHeap.write64(line + IYI_TL_NEXT, @@lines)"
            print "        @@lines = line"
            print "        IyiRuntimeLock.unlock"
          } else print
          links++; next
        }
        /^      return 0_i64 if @@count == 0_i64 \|\| \(line != 0 && @@count <= 1_i64\)$/ { print "      IyiThread.roster_check(line)"; checks++ }
        { print }
        END { if (alias_count != 1 || roots != 1 || starts != 1 || start_ends != 1 || darwin != 1 || created != 1 || runs != 1 || run_ends != 1 || links != 1 || checks != 1) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    cat > roster.iyi <<'IYI'
@[Unsafe("the proof holds a child at a copy-only pre-link rendezvous")]
class Gate
  getter ready : Atomic(Int64)
  getter stop : Atomic(Int64)
  def initialize
    @ready = Atomic(Int64).new(0_i64)
    @stop = Atomic(Int64).new(0_i64)
  end
end

IyiMark.auto = false
IyiMark.workers = 0_u64
IyiThread.roster_arm
gate = Gate.new
thread = IyiThread.start do
  gate.ready.set(1_i64)
  while gate.stop.get == 0_i64
    IyiThread.spin_pause
  end
  nil
end
deadline = IyiMark.now_ns &+ 20000000000_u64
while !IyiThread.roster_held?
  if IyiMark.now_ns >= deadline
    print "SETUP: roster: the child never reached the pre-link gate\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
IyiMark.collect
unless IyiThread.roster_checked?
  print "SETUP: roster: the held-child stop was not observed\n"
  __iyi_exit(76)
end
IyiThread.roster_open
deadline = IyiMark.now_ns &+ 20000000000_u64
while gate.ready.get == 0_i64
  if IyiMark.now_ns >= deadline
    print "SETUP: roster: the child did not link after opening\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
before = IyiThread.stopped
IyiMark.collect
if IyiThread.stopped <= before
  print "SETUP: roster: the linked child was not stopped\n"
  __iyi_exit(76)
end
gate.stop.set(1_i64)
thread.join
puts "roster: the unlinked child was not counted, then its linked line was stopped"
IYI
    for mode in control forced; do
      mkdir -p "roster-$mode/iyi"
      cp "$REPO"/src/iyi/*.iyi "roster-$mode/iyi/"
      roster_copy "$mode" "roster-$mode/iyi/thread.iyi" || { echo "SETUP: roster: copy anchors changed"; exit 76; }
      if ! IYI_PATH="$WORK/roster-$mode${PSEP}$REPO/src" "$IYI" build roster.iyi -o "roster-$mode-run" > "build-roster-$mode.log" 2>&1; then
        cat "build-roster-$mode.log"; exit 76
      fi
      step "darwin: pre-link roster $mode"
      timeout -k 5 60 "./roster-$mode-run" > "roster-$mode.txt" 2>&1
      code=$?
      if [ "$code" -eq 76 ] || [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then cat "roster-$mode.txt"; exit 76; fi
      if [ "$mode" = control ]; then
        [ "$code" -eq 0 ] && grep -qxF 'roster: the unlinked child was not counted, then its linked line was stopped' "roster-$mode.txt" || { echo "roster control failed (exit $code):"; cat "roster-$mode.txt"; exit 1; }
        echo '  control: exit 0, roster: the unlinked child was not counted, then its linked line was stopped'
      else
        [ "$code" -eq 1 ] && grep -qxF 'FAIL: roster: a thread was counted before its line was linked' "roster-$mode.txt" || { echo "roster mutant failed unexpectedly (exit $code):"; cat "roster-$mode.txt"; exit 1; }
        echo '  exits 1 at "FAIL: roster: a thread was counted before its line was linked"'
      fi
    done
    ;;
esac

# ── 7k. A program that calls C runs it on threads libc made ──────────────
# The pool's threads were a raw `clone` with a TLS block made from the
# executable's PT_TLS and none of libc's thread state, so C reaching for it
# ran on nothing: `pthread_self` answered 0 on a worker and `strerror`
# died of SIGSEGV (issue #158). A program whose own code calls C now gets
# `pthread_create` threads (`IyiThread.program_calls_c?`); every worker
# and a started thread answer libc's own questions through collections
# that stop them, and the binary names `pthread_create` and
# `pthread_join`, where step 2's binaries, which call no C, name neither.
# With the compiler's answer replaced by a `false` the program cannot
# see, the run dies or says what it lost.
case "$(uname -s)" in
  Linux)
    step "C called from parallel tasks and a thread runs on libc's threads"
    cat > calls_c.iyi <<'IYI'
@[Unsafe("the program asks libc for its thread, errno and strings through a lib, and compares C strings byte by byte")]
@[Link("c")]
lib LibCalls
  fun pthread_self : UInt64
  fun strerror(code : Int32) : UInt8*
  fun __errno_location : Int32*
  fun close(fd : Int32) : Int32
  fun strdup(text : UInt8*) : UInt8*
  fun free(pointer : Void*) : Void
end

def same?(c : UInt8*, s : String) : Bool
  bytes = s.to_unsafe
  i = 0
  while i < s.bytesize
    return false if c[i] != bytes[i]
    i += 1
  end
  c[i] == 0_u8
end

selfless = Atomic(Int64).new(0_i64)
errno = Atomic(Int64).new(0_i64)
text = Atomic(Int64).new(0_i64)
done = Atomic(Int64).new(0_i64)
main_self = LibCalls.pthread_self

group do |g|
  16.times do
    g.spawn(unit: :new) do
      100.times do |i|
        selfless.add(1_i64) if LibCalls.pthread_self == 0_u64 || LibCalls.pthread_self == main_self
        LibCalls.close(-1)
        errno.add(1_i64) if LibCalls.__errno_location.value != 9
        text.add(1_i64) unless same?(LibCalls.strerror(2), "No such file or directory")
        line = "line #{i}"
        copy = LibCalls.strdup(line.to_unsafe)
        text.add(1_i64) unless same?(copy, line)
        LibCalls.free(copy.as(Void*))
        IyiMark.collect if i % 25 == 0
      end
      done.add(1_i64)
      nil
    end
  end
end

thread = IyiThread.start do
  selfless.add(1_i64) if LibCalls.pthread_self == 0_u64 || LibCalls.pthread_self == main_self
  nil
end
thread.join

if done.get != 16 || selfless.get != 0 || errno.get != 0 || text.get != 0
  puts "tasks #{done.get} of 16; pthread_self wrong #{selfless.get}, errno wrong #{errno.get}, strings wrong #{text.get}"
  exit 1
end
puts "every property held, #{IyiThread.stops} stops"
IYI
    if ! "$IYI" build calls_c.iyi -o calls-c > build-calls-c.log 2>&1; then
      cat build-calls-c.log; exit 1
    fi
    if ! timeout -k 5 120 ./calls-c > calls-c.txt 2>&1 || ! grep -q 'every property held' calls-c.txt; then
      cat calls-c.txt; exit 1
    fi
    named=$(nm -u calls-c | sed -e 's/^ *[wU] *//' -e 's/@.*$//' | grep -cE '^(pthread_create|pthread_join)$')
    if [ "$named" -ne 2 ]; then
      echo "the program calls C and its threads are not libc's:"; nm -u calls-c; exit 1
    fi
    echo "  $(cat calls-c.txt)"

    step "failure proof: the threads a raw clone again in a program that calls C"
    mkdir -p cloned/iyi
    cp "$REPO"/src/iyi/*.iyi cloned/iyi/
    awk '/^    @\[Primitive\(:iyi_calls_c\)\]$/ { found++; next }
      /^    def self\.program_calls_c\? : Bool$/ { print; print "      Pointer(UInt8).new(0_u64).address != 0_u64"; found++; next }
      { print } END { if (found != 2) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > cloned/iyi/thread.iyi || { echo "the compiler's answer is not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/cloned${PSEP}$REPO/src" "$IYI" build calls_c.iyi -o cloned-run > build-cloned.log 2>&1; then
      cat build-cloned.log; exit 1
    fi
    ( timeout -k 5 120 ./cloned-run > cloned.txt 2>&1; exit $? ) 2> /dev/null
    code=$?
    if [ "$code" -eq 0 ] || grep -q 'every property held' cloned.txt; then
      echo "with raw clones, C on the workers still held:"; cat cloned.txt; exit 1
    fi
    echo "  exit $code: $(tail -1 cloned.txt)"
    ;;
esac

echo "workdir $WORK"
echo "thread exercise: every step held"
exit 0
