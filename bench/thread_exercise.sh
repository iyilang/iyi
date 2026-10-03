#!/usr/bin/env bash
# Drives bench/thread_exercise.iyi: kernel threads under the collector —
# GC_DESIGN.md Stage 4, the stop-the-world, built (src/iyi/thread.iyi).
#
#     bash bench/thread_exercise.sh
#
# Seven steps, and the fifth and sixth are failure proofs, because a gate
# that cannot fail is not a gate; the seventh, Windows' own, carries its own:
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
#  4b. Four times the cores' threads taking the runtime lock in turn, held
#      on Windows to five times one thread taking it for all their turns,
#      and as many computing stopped by collections, held there to 60 ms a
#      stop; with a failure proof each - the lock's yield removed, and the
#      suspends asked one at a time.
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
#      the end put back into the C runtime's `exit` a run never ends, and
#      is released by resuming its threads.
#  7c. On Windows, threads and their tasks grow fresh stacks while a thread
#      collects in a loop, and every run ends; with the stop's scan started
#      at sp again, inside the guard page, a run dies.
#
# Linux x86_64 and aarch64, darwin aarch64.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
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

step() { echo "== $1"; }

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

# The plain build, ten more times. A death here is a failure whatever it
# says: on a Windows runner the exercise died once in sixty of a guard-page
# violation in the collector (status 0x80000001) after it had printed its
# first line, so one run passing proved nothing. The registry check in
# the exercise is the deterministic half of the same fix; this is the
# half that turns the rare death into a red step.
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
    # sigaction for the thread and the stop, pipe/read/write for the park,
    # __tlv_bootstrap for the thread-locals, and close for a finished
    # thread's kqueue (`IyiScheduler.retire_thread`). Nothing else.
    step "dependency floor: what threads cost darwin, by name"
    runtime='___error __dyld_get_image_header __dyld_get_image_vmaddr_slide __tlv_bootstrap _backtrace _backtrace_symbols_fd _clock_gettime_nsec_np _exit _kevent _kqueue _mmap _mprotect _munmap _pthread_create _pthread_get_stackaddr_np _pthread_self _sigaction _sigaltstack _sysctlbyname _write'
    thread='_close _pipe _pthread_create _pthread_join _pthread_kill _read'
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
      echo "  held to one core it counts 1 and starts no helper; one core here, so two were not tried"
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

# ── 4b. The runtime lock and the stop, four times the cores' threads ──────
# The lock only spun: a holder preempted with it waited out the spinners'
# timeslices, and 48 threads taking it on twelve cores took 30 to 35 times
# what one thread took for all of their turns (r2_alloc_threads: 64 threads
# allocating 1.8 to 20 s against 0.2 to 0.4 for twelve). It yields the core
# every 128th turn now: 1.3 to 1.5 times. And Windows' stop waited for each
# suspend before asking for the next, so a thread with no core held the
# stop until the scheduler ran it: collections beside 48 threads computing
# on twelve cores, half a second after they started, stopped them in 85 to
# 275 ms each, and in 0 to 13 asked all at once. Asserted on Windows, where
# it was measured; printed everywhere.
cat > crowd.iyi <<'IYI'
module crowd

class Counter
  getter value : Atomic(Int64)

  def initialize
    @value = Atomic(Int64).new(0_i64)
  end
end

class Flag
  getter stop : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
  end
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

def fail(message : String) : Nil
  print "FAIL: #{message}\n"
  __iyi_exit(1)
end

asserted = false
{% if flag?(:win32) %}
  asserted = true
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
# The best of up to three tries: a machine busy elsewhere is not the lock.
best = 0_u64
tries = 0
while tries < 3 && (tries == 0 || best > 5_u64 * alone)
  started = IyiMark.now_ns
  threads = [] of IyiThread
  crowd.times { threads << IyiThread.start { hammer(counter, rounds); nil } }
  threads.each { |thread| thread.join }
  took = IyiMark.now_ns - started
  best = took if tries == 0 || took < best
  tries = tries + 1
end
fail("lock: #{crowd} threads taking the runtime lock took #{best // 1000000_u64} ms, past 5 times the #{alone // 1000000_u64} ms one thread took for all their turns") if asserted && best > 5_u64 * alone
puts "lock: #{crowd} threads taking the runtime lock on #{cores} cores, held to 5 times one thread taking it for all their turns"

# The threads run half a second before the first stop: in the first
# moments of 48 new threads a stop asked one thread at a time was as quick
# as one asked at once (every stop of one run in three), and after half a
# second it was slow in every run.
flag = Flag.new
spinners = [] of IyiThread
crowd.times { spinners << IyiThread.start { spin(flag) } }
settled = IyiMark.now_ns + 500000000_u64
while IyiMark.now_ns < settled
end
mean = 0_u64
tries = 0
while tries < 3 && (tries == 0 || mean > 60000000_u64)
  stop_ns = IyiThread.stop_ns
  stops = IyiThread.stops
  5.times { IyiMark.collect }
  round = (IyiThread.stop_ns - stop_ns) // (IyiThread.stops - stops)
  mean = round if tries == 0 || round < mean
  tries = tries + 1
end
flag.stop.set(1_i64)
spinners.each { |thread| thread.join }
fail("stop: five collections stopped #{spinners.size} threads that only compute in #{mean // 1000000_u64} ms each, past 60") if asserted && mean > 60000000_u64
puts "stop: five collections stopped #{spinners.size} threads that only compute, held to 60 ms a stop"
IYI
step "the runtime lock and the stop with four times the cores' threads"
if ! "$IYI" build --release crowd.iyi -o crowd > build-crowd.log 2>&1; then
  cat build-crowd.log; exit 1
fi
if ! timeout -k 5 300 ./crowd > crowd.txt 2>&1; then
  cat crowd.txt; exit 1
fi
sed 's/^/  /' crowd.txt
# The two proofs need cores for the spin and the serial stop to show: on a
# CI runner's four, sixteen threads spinning without the yield stayed under
# five times one thread's turns, and the proof did not fire. Measured on
# twelve; below eight they are said to be unmeasured.
cores="${NUMBER_OF_PROCESSORS:-0}"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    if [ "$cores" -lt 8 ]; then
      echo "  the lock and stop failure proofs need 8 cores to show; this machine has $cores: unmeasured here"
    else
    step "failure proof: a lock that only spins is caught"
    mkdir -p spinning/iyi
    cp "$REPO"/src/iyi/*.iyi spinning/iyi/
    awk '/^        IyiThread\.yield_cpu if \(spins = spins &\+ 1\) & 127 == 0$/ { found = 1; next } { print } END { if (!found) exit 3 }' \
      "$REPO/src/iyi/prelude.iyi" > spinning/iyi/prelude.iyi || { echo "the lock's yield is not in the prelude any more"; exit 1; }
    if ! IYI_PATH="$WORK/spinning${PSEP}$REPO/src" "$IYI" build --release crowd.iyi -o crowd-spinning > build-spinning.log 2>&1; then
      cat build-spinning.log; exit 1
    fi
    timeout -k 5 300 ./crowd-spinning > spinning.txt 2>&1
    code=$?
    if [ "$code" -ne 1 ] || ! grep -q '^FAIL: lock:' spinning.txt; then
      echo "the lock check did not fire (exit $code):"; tail -3 spinning.txt; exit 1
    fi
    printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: lock:' spinning.txt)"
    step "failure proof: a stop that waits for each suspend before the next is caught"
    mkdir -p serial/iyi
    cp "$REPO"/src/iyi/*.iyi serial/iyi/
    awk '/^          LibC\.SuspendThread\(Pointer\(Void\)\.new\(IyiHeap\.read64\(cursor \+ IYI_TL_HANDLE\)\)\) if cursor != line$/ { asked = 1; next }
      { print }
      /^            handle = Pointer\(Void\)\.new\(IyiHeap\.read64\(cursor \+ IYI_TL_HANDLE\)\)$/ && asked { print "            LibC.SuspendThread(handle)"; moved = 1 }
      END { if (!asked || !moved) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > serial/iyi/thread.iyi || { echo "the stop's suspends are not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/serial${PSEP}$REPO/src" "$IYI" build --release crowd.iyi -o crowd-serial > build-serial.log 2>&1; then
      cat build-serial.log; exit 1
    fi
    # A stop asked one thread at a time was now and then as quick as the
    # other through a whole run - one run in three here - so five runs, and
    # the first caught is the proof.
    caught=""
    for try in 1 2 3 4 5; do
      timeout -k 5 300 ./crowd-serial > serial.txt 2>&1
      code=$?
      if [ "$code" -eq 1 ] && grep -q '^FAIL: stop:' serial.txt; then
        caught="$try"; break
      fi
    done
    [ -n "$caught" ] || { echo "the stop check did not fire in five runs:"; tail -3 serial.txt; exit 1; }
    printf '  exits 1 on run %s at "%s"\n' "$caught" "$(grep -m1 '^FAIL: stop:' serial.txt)"
    fi
    ;;
esac

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
# fraction of a second.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    step "failure proof, again: two hundred runs, and every one ends"
    again=1
    while [ "$again" -le 200 ]; do
      timeout -k 5 30 ./unrooted 8 > unrooted-again.txt 2>&1
      code=$?
      if [ "$code" -ne 1 ] || ! grep -q "on a free list" unrooted-again.txt; then
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

def pair(id : Int32, trips : Int32) : Nil
  there = Channel(Int32).new(1)
  back = Channel(Int32).new(1)
  group do |g|
    2.times do |side|
      g.spawn do
        seed = (id * 10 + side).to_i64 * 1000000_i64
        mine = build(300, seed)
        wrong = 0
        trips.times do |t|
          if side == 0
            there.send(t)
            back.receive
          else
            there.receive
            back.send(t)
          end
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
threads = [] of IyiThread
6.times do |id|
  threads << IyiThread.start { pair(id + 1, 100000); nil }
end
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

# The failure proof: the fiber marked running before the switch again, in
# a copy.
step "failure proof: a fiber marked running before the switch loses its list"
mkdir -p skipping/iyi
cp "$REPO"/src/iyi/*.iyi skipping/iyi/
awk '/^    state.current = fiber$/ { print "    fiber.state = IyiFiberState::Running"; found = 1 } { print } END { if (!found) exit 3 }' \
  "$REPO/src/iyi/concurrency.iyi" > skipping/iyi/concurrency.iyi || { echo "the switch's current-fiber line is not in concurrency.iyi any more"; exit 1; }
if ! IYI_PATH="$WORK/skipping${PSEP}$REPO/src" "$IYI" build switching.iyi -o skipping-run > build-skipping.log 2>&1; then
  cat build-skipping.log; exit 1
fi
# A race, so it is run until it is caught: most runs lose a list, and one
# runner once ran five that all kept theirs.
caught=""
run=1
while [ "$run" -le 20 ]; do
  timeout -k 5 120 ./skipping-run > skipping.txt 2>&1
  grep -q '^wrong=0$' skipping.txt || { caught="$run"; break; }
  run=$((run + 1))
done
if [ -z "$caught" ]; then
  echo "twenty runs with the fiber marked early all kept their lists"; exit 1
fi
echo "  run $caught lost a list or died"

# Windows' `SuspendThread` asks for the suspend and returns, and the thread
# runs on until `GetThreadContext` waits for it. The stop read the
# allocator's word in between, so a thread that ran on into `take` was
# stopped inside it, which the deferral exists to prevent: the program
# above died of a memory fault once in the 54 runs CI made of it. A copy
# of the runtime makes the run-on certain - every suspend taken back and
# asked again, for up to 2 ms, until the context is read with the thread
# inside the allocator - and every list holds; with the word read before
# the context, the same run-on loses a list or dies: 18 runs in 20 on
# twelve cores, 3 in 20 held to four, so the proof runs up to sixty.
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
    step "failure proof: the allocator's word read before the context, under the same suspends"
    mkdir -p early/iyi
    cp "$REPO"/src/iyi/*.iyi early/iyi/
    awk "$runon"' /^            sp = IyiRoots\.capture_thread_registers\(handle, cursor \+ IYI_TL_SPILL\)$/ { held = $0; found = 1; next }
      /^              IyiHeap\.write64\(cursor \+ IYI_TL_SP, sp\)$/ { runon("              "); print "  " held; moved = 1 }
      { print } END { if (!found || !moved) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > early/iyi/thread.iyi || { echo "the stop's context read or its sp store is not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/early${PSEP}$REPO/src" "$IYI" build switching.iyi -o early-run > build-early.log 2>&1; then
      cat build-early.log; exit 1
    fi
    caught=0
    run=1
    while [ "$caught" -eq 0 ] && [ "$run" -le 60 ]; do
      timeout -k 5 120 ./early-run > early.txt 2>&1
      grep -q '^wrong=0$' early.txt || caught=$run
      run=$((run + 1))
    done
    if [ "$caught" -eq 0 ]; then
      echo "sixty runs reading the allocator's word before the context all kept their lists"; exit 1
    fi
    printf '  run %s of up to sixty: "%s"\n' "$caught" "$(grep -m1 -E '^wrong=|memory fault' early.txt | cut -d. -f1)"
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
# The advice names what iyi has: it said "or behind a `Mutex`", and `Mutex`
# is an undefined constant here. `Atomic` is the one it names now.
if grep -q 'Mutex' build-raced.log build-reassigned.log || ! grep -q 'Keep the value in an `Atomic`' build-raced.log; then
  echo "the advice does not name Atomic alone:"; cat build-raced.log build-reassigned.log; exit 1
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
# 0 in 1,000. The proof puts the return back, and a run that hangs is
# released by resuming its threads, which nothing else here can do.
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
    if ! "$IYI" build --release ends.iyi -o ends > build-ends.log 2>&1; then
      cat build-ends.log; exit 1
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

    step "failure proof: a program that ends back in the C runtime hangs under a collection"
    mkdir -p crt-end/iyi
    cp "$REPO"/src/iyi/*.iyi crt-end/iyi/
    awk '/^    LibC\.fflush\(Pointer\(Void\)\.new\(0_u64\)\)$/ || /^    __iyi_exit\(0\)$/ { found++; next } { print } END { if (found != 2) exit 3 }' \
      "$REPO/src/iyi/prelude.iyi" > crt-end/iyi/prelude.iyi || { echo "the end this proof removes is not in the prelude any more"; exit 1; }
    if ! IYI_PATH="$WORK/crt-end${PSEP}$REPO/src" "$IYI" build --release ends.iyi -o ends-in-crt > build-crt-end.log 2>&1; then
      cat build-crt-end.log; exit 1
    fi
    # One run in two hung on four cores, so twenty runs; the first that
    # does not end is the proof.
    hung=""
    try=1
    while [ "$try" -le 20 ]; do
      timeout -k 1 5 ./ends-in-crt > ends-in-crt.txt 2>&1
      code=$?
      if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then hung="$try"; break; fi
      try=$((try + 1))
    done
    left="$(release ends-in-crt | tr -d '\r')"
    [ -n "$hung" ] || { echo "twenty runs that end in the C runtime all ended"; exit 1; }
    [ "$left" = "left: 0" ] || { echo "a hung run could not be released ($left)"; exit 1; }
    printf '  run %s never ended, and was released by resuming its threads\n' "$hung"
    ;;
esac

# ── 7b. Windows: a thread is named on its line before a stop can see it ───
# A child was linked for the stops under the runtime lock and ran at once,
# and its handle reached its line only after the lock was released: a stop
# in between suspended NULL, read sp 0 and scanned from address 0. The
# child is created suspended now, its handle written under the lock, and
# resumed after. A copy of the runtime holds every start open 2 ms there
# while two threads collect, and every run ends well; the failure proof
# puts the old order back under the same 2 ms, and a run dies.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    step "threads started while two others collect, each start held open 2 ms: three runs, and every one ends well"
    cat > starting.iyi <<'IYI'
class Flag
  getter stop : Atomic(Int64)
  getter ran : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @ran = Atomic(Int64).new(0_i64)
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

flag = Flag.new
churners = [] of IyiThread
2.times { churners << IyiThread.start { churn(flag) } }
deadline = __iyi_monotonic_ns + Program.args[0].to_i.to_i64 * 1_000_000_000_i64
started = 0
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
raise "ran #{flag.ran.get} of #{started}" if flag.ran.get != started
puts "ok started=#{started}"
IYI
    widen='function widen(pad) {
      print pad "widen = __iyi_monotonic_ns"
      print pad "while __iyi_monotonic_ns - widen < 2000000_i64"
      print pad "end"
    }'
    mkdir -p widened/iyi
    cp "$REPO"/src/iyi/*.iyi widened/iyi/
    awk "$widen"' /^        LibC\.ResumeThread\(h\)$/ { widen("        "); found = 1 } { print } END { if (!found) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > widened/iyi/thread.iyi || { echo "the start's resume is not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/widened${PSEP}$REPO/src" "$IYI" build starting.iyi -o widened-run > build-widened.log 2>&1; then
      cat build-widened.log; exit 1
    fi
    run=1
    while [ "$run" -le 3 ]; do
      timeout -k 5 60 ./widened-run 3 > widened.txt 2>&1
      code=$?
      if [ "$code" -ne 0 ] || ! grep -q '^ok ' widened.txt; then
        echo "run $run with every start held open exited $code:"; tail -3 widened.txt; exit 1
      fi
      run=$((run + 1))
    done
    echo "  three runs of three seconds, and every thread ran its body"

    step "failure proof: the handle written after the unlock, the thread already running, under the same 2 ms"
    mkdir -p unnamed/iyi
    cp "$REPO"/src/iyi/*.iyi unnamed/iyi/
    awk "$widen"' /^        IyiHeap\.write64\(line \+ IYI_TL_HANDLE, h\.address\)$/ { held = $0; found++; next }
      /^        h = LibC\.CreateThread\(.*thread_entry.*, 4_i32, nil\)$/ { sub(/, 4_i32, nil\)$/, ", 0_i32, nil)"); found++ }
      /^        LibC\.ResumeThread\(h\)$/ { widen("        "); print held; found++ }
      { print } END { if (found != 3) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > unnamed/iyi/thread.iyi || { echo "the start's creation, handle write or resume is not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/unnamed${PSEP}$REPO/src" "$IYI" build starting.iyi -o unnamed-run > build-unnamed.log 2>&1; then
      cat build-unnamed.log; exit 1
    fi
    caught=0
    run=1
    while [ "$caught" -eq 0 ] && [ "$run" -le 10 ]; do
      timeout -k 5 60 ./unnamed-run 3 > unnamed.txt 2>&1
      grep -q '^ok ' unnamed.txt || caught=$run
      run=$((run + 1))
    done
    if [ "$caught" -eq 0 ]; then
      echo "ten runs with the handle written after the unlock all ended well"; exit 1
    fi
    printf '  run %s of up to ten: "%s"\n' "$caught" "$(head -1 unnamed.txt | tr -d '\r' | cut -d. -f1)"
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
      # A new thread each time: its stack and its tasks' stacks are
      # committed only as they grow.
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

    step "failure proof: the scan from sp again, guard page and all, and a run dies"
    mkdir -p guarded/iyi
    cp "$REPO"/src/iyi/*.iyi guarded/iyi/
    awk '/^            sp = first_written\(sp, top\)$/ { found = 1; next } { print } END { if (!found) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > guarded/iyi/thread.iyi || { echo "the scan's start is not in thread.iyi any more"; exit 1; }
    if ! IYI_PATH="$WORK/guarded${PSEP}$REPO/src" "$IYI" build guard.iyi -o guard-from-sp > build-guarded.log 2>&1; then
      cat build-guarded.log; exit 1
    fi
    caught=0
    run=1
    while [ "$caught" -eq 0 ] && [ "$run" -le 5 ]; do
      timeout -k 5 60 ./guard-from-sp 2000 > guarded.txt 2>&1
      grep -q '^stacks grown beside a collecting thread: true' guarded.txt || caught=$run
      run=$((run + 1))
    done
    if [ "$caught" -eq 0 ]; then
      echo "five runs scanning from sp all ended well"; exit 1
    fi
    echo "  run $caught of up to five died"
    ;;
esac

echo "workdir $WORK"
echo "thread exercise: every step held"
exit 0
