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
#      the allocator.
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
#   5. Failure proof: the thread-root walk removed from a copy of the
#      prelude, and a thread's list — reachable from its stopped frames
#      alone — is swept out from under it; the program exits 1 naming the
#      node on a free list.
#   6. Failure proof: a block that captures a value whose type is not
#      `Share` (SPEC.md III.4.4) does not compile, and the error names the
#      variable, its type and the field that made it mutable.
#   7. On Windows, a program whose main thread ends while another thread's
#      collections stop it ends, two hundred runs of two hundred; and with
#      the end put back into the C runtime's `exit` a run never ends, and
#      is released by resuming its threads.
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
caught=0
run=1
while [ "$run" -le 5 ]; do
  timeout -k 5 120 ./skipping-run > skipping.txt 2>&1
  grep -q '^wrong=0$' skipping.txt || caught=$((caught + 1))
  run=$((run + 1))
done
if [ "$caught" -eq 0 ]; then
  echo "five runs with the fiber marked early all kept their lists"; exit 1
fi
echo "  $caught of five runs lost a list or died"

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

echo "workdir $WORK"
echo "thread exercise: every step held"
exit 0
