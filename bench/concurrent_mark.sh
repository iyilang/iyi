#!/usr/bin/env bash
# Drives bench/concurrent_mark.iyi: the mark beside the program, GC_DESIGN.md
# Stage 9, and the write barrier it stands on.
#
#     bash bench/concurrent_mark.sh
#
# Every failure proof runs its broken copy once and checks its exit status
# and named failure. Some older proofs still match only a sentence fragment.
# A forced copy waits on a word the program sets, and a copy that cannot
# build against the real runtime fails the gate. A step whose code this
# platform does not compile says so by name; a host with too few cores fails.
# In the order they run:
#   - the program, release: rounds that move a payload into a black holder
#     under a running mark, the pauses of a concurrent collection against the
#     stop-the-world mark, a large block outgrown under a mark, a small live
#     set finished in its stop, a stray barrier, the share beside busy threads,
#     the wakes, and on Windows the priority boost counted over the process's
#     threads;
#   - the machine alone, and the first collections beside threads computing on
#     every core, reported as measurements;
#   - buffers grown by realloc beside a mark, ten runs;
#   - small chunks freed in bursts across the pauses, ten runs, on every shape;
#   - chunks the last mark kept, freed beside the sweep, ten runs, and the
#     armed look that holds the sweep at one kept chunk until the program frees it;
#   - failure proofs: an unlocked free inside a sweep's look; a barrier that
#     shades nothing; a barrier run after its mark ended; a block outgrown under
#     a mark that the closer holds open; a small live set given the
#     thousand-object bound; the remainder round's count stored over the
#     assists counted in; helper 0 waiting past the next mark; a collection let
#     go after the release; the stopped, bounded and verb collections let go
#     late; a free outside the allocator's bracket; an idle pool whose workers
#     wait for task arrival, and a queued-work turn that starts no worker;
#     a first collection waiting for every helper to park;
#   - marks beside twenty-four connections on twelve workers, with every helper
#     and with one;
#   - on Windows only: the helpers woken with the boost (the boost counted and
#     wake timings reported); the helper cap beside a busy program; the pool's waiting
#     workers counted as the program's; a busy pool's running workers counted
#     free. Those proofs exist only where their code is compiled (thread.iyi's
#     start_helper and prelude.iyi's start_concurrent under win32), and the
#     gate names that platform arm instead of passing silently.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# the wrapper in bin is a posix shell script, so a caller that already has a
# compiler of its own names it through the environment.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
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

cd "$WORK" || exit 1

step() { echo "== $1"; }

step "the mark beside the program, release build"
if ! "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o marks > build.log 2>&1; then
  cat build.log; exit 1
fi
if ! timeout -k 5 300 ./marks > answers.txt 2>&1; then
  cat answers.txt; exit 1
fi
grep -q 'every property held' answers.txt || { cat answers.txt; exit 1; }

step "the pauses, stopped and beside the program ($(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "$NUMBER_OF_PROCESSORS") cores here)"
grep -E '^(stray|small|moves|pause|large|wake|share):' answers.txt | sed 's/^/  /'

# What the machine takes away on its own: a thread per core that reads the
# clock and does nothing else - no allocation, so no collection - for a
# second, and the longest gap any of them saw between two reads. A stop
# that meets such a gap lasts it, and nothing in the runtime shortens it:
# on a twelve-core Windows VM this read 23 to 64 ms, where the longest
# second stops measured 13 to 45.
step "the machine alone: a thread per core reading the clock, no collector"
cat > machine.iyi <<'IYI'
@[Unsafe("each thread writes its longest clock gap into its own word of a page mapped with __iyi_mmap, so no allocation or collector touches the measurement")]
class Gaps
  @@page : UInt64 = 0_u64

  def self.setup : Nil
    @@page = __iyi_mmap(4096_u64).address
  end

  def self.slot(i : Int32) : Pointer(UInt64)
    Pointer(UInt64).new(@@page + i.to_u64 * 64_u64)
  end
end

def watch(index : Int32, deadline : UInt64) : Nil
  longest = 0_u64
  last = IyiMark.now_ns
  while last < deadline
    now = IyiMark.now_ns
    longest = now - last if now - last > longest
    last = now
  end
  Gaps.slot(index).value = longest
end

Gaps.setup
count = IyiThread.core_count.to_i32
deadline = IyiMark.now_ns + 1000000000_u64
threads = [] of IyiThread
# Each thread's index is its block call's own: a captured local `k = i`
# reassigned by a `while` was one cell every thread read, and a late reader
# could see the next index (SPEC.md III.4.4 refuses it now).
(count - 1).times do |j|
  threads << IyiThread.start do
    watch(j + 1, deadline)
    nil
  end
end
watch(0, deadline)
threads.each { |t| t.join }
worst = 0_u64
i = 0
while i < count
  worst = Gaps.slot(i).value if Gaps.slot(i).value > worst
  i = i + 1
end
puts "machine: #{count} threads reading the clock for a second, the longest gap any saw #{(worst // 1000_u64).to_i64} us"
IYI
if ! "$IYI" build --release machine.iyi -o machine > build-machine.log 2>&1; then
  cat build-machine.log; exit 1
fi
timeout -k 5 60 ./machine > machine.txt 2>&1 || { cat machine.txt; exit 1; }
grep '^machine:' machine.txt | sed 's/^/  /'

# Report the first collection beside busy threads with and without helpers.
# The forced helper-hold proof below decides the wait defect; timings are
# measurements, not a pass/fail bound.
cat > crowded.iyi <<'IYI'
module crowded

class Flag
  getter stop : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
  end
end

def spin(flag : Flag) : Nil
  x = 0_i64
  while flag.stop.get == 0_i64
    x = x &+ 1
  end
end

IyiMark.workers = 0_u64 if Program.args.size > 0 && Program.args[0] == "alone"
flag = Flag.new
spinners = [] of IyiThread
(IyiThread.core_count.to_i * 2).times { spinners << IyiThread.start { spin(flag) } }
# Under -Dready_force the copy holds each helper until this program releases
# it, and it releases them only once a collection has returned: a watcher
# waits for that, and fails by name if none returns in ten seconds.
{% if flag?(:ready_force) %}
watcher = IyiThread.start do
  deadline = IyiMark.now_ns + 10000000000_u64
  while IyiMark.collections == 0_u64 && IyiMark.now_ns < deadline
    IyiThread.yield_cpu
  end
  if IyiMark.collections == 0_u64
    print "FAIL: crowded: the first collection did not return while its helpers were held\n"
    __iyi_exit(1)
  end
  IyiMark.release_ready
  nil
end
{% end %}
started = IyiMark.now_ns
sum = 0_i64
300000.times do |i|
  a = Array(Int32).new(4, i)
  sum = sum + a[0]
end
took = IyiMark.now_ns - started
flag.stop.set(1_i64)
spinners.each { |thread| thread.join }
{% if flag?(:ready_force) %}
watcher.join
{% end %}
puts "crowded: #{took // 1000000_u64} ms, #{IyiMark.collections} collections, beside #{spinners.size} threads, #{sum}"
IYI
if ! "$IYI" build --release crowded.iyi -o crowded > build-crowded.log 2>&1; then
  cat build-crowded.log; exit 1
fi
crowded_once() {
  timeout -k 5 120 "./$1" "$2" > crowded.txt 2>&1 || { cat crowded.txt; exit 1; }
  ms="$(tr -d '\r' < crowded.txt | sed -n 's/^crowded: \([0-9]*\) ms, [1-9][0-9]* collections, .*$/\1/p')"
  beside="$(tr -d '\r' < crowded.txt | sed -n 's/^.* beside \([0-9]*\) threads.*$/\1/p')"
  [ -n "$ms" ] || { echo "no collection, or no answer:"; cat crowded.txt; exit 1; }
}
step "the first collections beside threads computing on every core"
crowded_once crowded alone
alone="$ms"
crowded_once crowded helped
echo "  beside $beside threads computing: $ms ms with helpers, $alone ms with none"

# A buffer of references grown by `realloc` frees its old copy, and a mark
# beside the program may have that copy grayed and queued: it blackened the
# freed chunk, the sweep relinked it black, and the chunk's next object was
# born black outside any mark - never scanned by the next, which swept what
# only it held. Without the sweep's whitening, 13 runs of this in 20 lost
# leaves or died of a memory fault. Ten runs, each its own chance.
step "buffers grown by realloc beside the mark keep what they hold, ten runs"
cat > realloced.iyi <<'IYI'
@[Unsafe("the program grows buffers of objects with Pointer#malloc and realloc while the mark runs, the memory the collector must keep")]
module realloced

class Leaf
  getter v : Int64
  getter s : String

  def initialize(@v : Int64)
    @s = "L#{@v}"
  end
end

class Held
  getter buf : Pointer(Leaf)
  getter n : Int32
  getter base : Int64

  def initialize(@buf : Pointer(Leaf), @n : Int32, @base : Int64)
  end
end

seed = 12345_i64
keep = [] of Held
lost = 0
300.times do |round|
  seed = (seed * 1103515245 + 12345) % 2147483647
  n = 1 + (seed % 3000).to_i32
  cap = 1
  buf = Pointer(Leaf).malloc(1_u64)
  base = round.to_i64 * 10000
  i = 0
  while i < n
    if i >= cap
      cap = cap * 2
      buf = buf.realloc(cap.to_u64)
    end
    buf[i] = Leaf.new(base + i)
    i += 1
  end
  keep << Held.new(buf, n, base)
  keep.shift if keep.size > 12
  keep.each do |h|
    h.n.times do |j|
      leaf = h.buf[j]
      lost += 1 if leaf.v != h.base + j || leaf.s != "L#{h.base + j}"
    end
  end
end
puts "lost #{lost}"
exit(lost == 0 ? 0 : 1)
IYI
if ! "$IYI" build realloced.iyi -o realloced > build-realloced.log 2>&1; then
  cat build-realloced.log; exit 1
fi
for run in 1 2 3 4 5 6 7 8 9 10; do
  if ! timeout -k 5 120 ./realloced > realloced.txt 2>&1 || ! grep -qx "lost 0" realloced.txt; then
    echo "  run $run of 10 lost what a realloc'd buffer held:"; tail -3 realloced.txt; exit 1
  fi
done
echo "  ten runs of three hundred realloc'd buffers, every leaf intact"

# A chunk `free` hands back goes on this thread's own list, and a pause
# drops every list: the sweep after it relinks the dropped chunks as dead.
# A thread stopped inside `free`, between the chunk's entry and its list -
# a suspend lands anywhere - put the chunk back after the pause, linked to
# the list it had read, while the sweep linked the same chunks into its
# batches. Handed out twice, one held a batch head's tagged word where its
# index goes, and the stamp wrote through it: this program faulted or lost
# a chunk in 25 runs of 30 here, and step 4's faulted in 3 of 1,600, each
# fault looked at on that store. A pause among the frees waits 2 ms for
# the helpers' sweep before the list is allocated from, which is what made
# it near certain.
step "small chunks freed in bursts across the pauses keep what was kept, ten runs"
cat > freed.iyi <<'IYI'
@[Unsafe("the program allocates raw chunks with Pointer#malloc and frees them with GC.free across the collector's pauses, then reads them back to see none was reused")]
module freed

import std/gc::{GC}

class Node
  getter link : Node?

  def initialize(@link : Node?)
  end
end

# Frees the aged chunks, the one at `first` before the rest (when it is 0 or
# more), and returns how many of their words the program left wrong.
def free_aged(aged : Pointer(Pointer(UInt64)), generation : UInt64, first : Int32) : Int32
  lost = 0
  if first >= 0
    chunk = aged[first]
    tag = generation.unsafe_shl(8_u64) | first.to_u64
    lost += 1 if chunk[0] != tag || chunk[255] != tag ^ 0x5A5A_u64
    GC.free(chunk.as(Void*))
  end
  j = 64
  while j > 0
    j -= 1
    next if j == first
    chunk = aged[j]
    tag = generation.unsafe_shl(8_u64) | j.to_u64
    lost += 1 if chunk[0] != tag || chunk[255] != tag ^ 0x5A5A_u64
    GC.free(chunk.as(Void*))
  end
  lost
end

# Past the stop's bound, so every mark goes beside the program and a
# helper's stop ends it, wherever this thread stands.
{% if flag?(:freed_force) %}
  IyiMark.auto = false
{% end %}
chain = nil.as(Node?)
i = 0
while i < 20000
  chain = Node.new(chain)
  i += 1
end
ring = Pointer(Pointer(UInt64)).malloc(4096_u64)
burst = Pointer(Pointer(UInt64)).malloc(64_u64)
# Chunks a mark kept, freed beside the lazy sweep of their arena: 2 KB
# each, a class nothing else here allocates, all in one arena.
aged = Pointer(Pointer(UInt64)).malloc(64_u64)
generation = 1_u64
j = 0
while j < 64
  chunk = Pointer(UInt64).malloc(256_u64)
  chunk[0] = generation.unsafe_shl(8_u64) | j.to_u64
  chunk[255] = chunk[0] ^ 0x5A5A_u64
  aged[j] = chunk
  j += 1
end
lost = 0
round = 0
{% if flag?(:freed_force) %}
  # Clear old debt before arming the look. Disable automatic collections while
  # setting up, then trigger exactly one lazy collection without allocating.
  # A sweep helper, never this thread, must publish the armed look.
  # Probe 44681170296: control and mutant matched 20 of 20 on each CI shape.
  forced_limit = IyiMark.now_ns + 5000000000_u64
  while IyiMark.freed_collecting?
    if IyiMark.now_ns >= forced_limit
      print "FAIL: freed: the previous collection did not finish within five seconds\n"
      __iyi_exit(76)
    end
    IyiThread.spin_pause
  end
  forced_arena = IyiHeap.arena_of(aged[0].address)
  IyiMark.collect
  IyiHeap.arm_look(forced_arena)
  forced_limit = IyiMark.now_ns + 5000000000_u64
  IyiHeap.allocated_word.value.set(IyiMark.budget)
  IyiMark.collect_if_due
  while IyiHeap.forced_look == 0_u64 && IyiMark.now_ns < forced_limit
    IyiThread.spin_pause
  end
  if IyiHeap.forced_look == 0_u64
    print "FAIL: freed: no sweep looked at a chunk the last mark kept within five seconds\n"
    __iyi_exit(76)
  end
  look = IyiHeap.forced_look
  first = -1
  j = 0
  while j < 64
    first = j if IyiHeap.head_of(forced_arena, aged[j].address) == look
    j += 1
  end
  if first < 0
    print "FAIL: freed: the sweep looked at a chunk the last mark kept that is not one of the aged ones\n"
    __iyi_exit(1)
  end
  lost += free_aged(aged, generation, first)
  IyiMark.auto = true
  generation = generation &+ 1_u64
  j = 0
  while j < 64
    chunk = Pointer(UInt64).malloc(256_u64)
    chunk[0] = generation.unsafe_shl(8_u64) | j.to_u64
    chunk[255] = chunk[0] ^ 0x5A5A_u64
    aged[j] = chunk
    j += 1
  end
{% end %}
while round < 200000
  j = 0
  while j < 64
    burst[j] = Pointer(UInt64).malloc(2_u64)
    j += 1
  end
  epoch = IyiMark.epoch
  j = 0
  while j < 64
    GC.free(burst[j].as(Void*))
    j += 1
  end
  if IyiMark.epoch != epoch
    # The pause just past dropped every list, and the helpers sweep: 2 ms
    # before the list is allocated from. In it the aged chunks - the mark
    # that just ended kept them - are checked and freed, all at once, as
    # soon as a slice of their arena is seen in flight or 5 ms have gone.
    until_ns = IyiMark.now_ns + 2000000_u64
    watch_ns = IyiMark.now_ns + 5000000_u64
    arena = IyiHeap.arena_of(aged[0].address)
    while IyiMark.now_ns < watch_ns && IyiHeap.read64(arena + IyiHeap::OFF_SWEEPING) != IyiMark.epoch
    end
    lost += free_aged(aged, generation, -1)
    while IyiMark.now_ns < until_ns
    end
    generation = generation &+ 1_u64
    j = 0
    while j < 64
      chunk = Pointer(UInt64).malloc(256_u64)
      chunk[0] = generation.unsafe_shl(8_u64) | j.to_u64
      chunk[255] = chunk[0] ^ 0x5A5A_u64
      aged[j] = chunk
      j += 1
    end
  end
  slot = round % 4096
  if round >= 4096
    old = ring[slot]
    lost += 1 if old[0] != (round - 4096).to_u64 || old[1] != (round - 4096).to_u64 &+ 7_u64
  end
  kept = Pointer(UInt64).malloc(2_u64)
  kept[0] = round.to_u64
  kept[1] = round.to_u64 &+ 7_u64
  ring[slot] = kept
  round += 1
end
count = 0
node = chain
while node
  count += 1
  node = node.link
end
puts "lost #{lost + 20000 - count}"
exit(lost == 0 && count == 20000 ? 0 : 1)
IYI
if ! "$IYI" build freed.iyi -o freed > build-freed.log 2>&1; then
  cat build-freed.log; exit 1
fi
# Every shape runs the bursts, darwin included: the macOS 15 runner this gate
# runs on (six cores) ended each of ten runs in 1 to 4 s with every kept chunk
# intact (probe/rl-concmark, 2026-11-19, job 135912015082 and 135912015440).
for run in 1 2 3 4 5 6 7 8 9 10; do
  timeout -k 5 120 ./freed > freed.txt 2>&1
  code=$?
  if [ "$code" -ne 0 ] || ! grep -qx "lost 0" freed.txt; then
    echo "  run $run of 10 lost a chunk kept beside chunks freed (exit $code):"; tail -3 freed.txt; exit 1
  fi
done
echo "  ten runs of 200,000 bursts of frees, every kept chunk intact"

# A sweep may read a kept chunk while that chunk is being freed. The armed
# copy publishes that exact look and holds it until the free announces itself
# or changes the entry. The unarmed runs exercise the same copy without a
# clock-decided widening window.
step "chunks the last mark kept, freed beside the sweep, ten runs"
mkdir -p widened/iyi
cp "$REPO"/src/iyi/*.iyi widened/iyi/
# Armed by the program
# (`IyiHeap.arm_look`, on the aged chunks' arena), the first such look publishes
# its chunk and holds it by words until the program's free of that chunk
# announces itself on the slice's claim (`note_free_waiting`, at the top of
# free_unswept), or the entry changes. Five seconds without either is named.
# The park in free_unswept's wait under the bracket (prelude L4380-4389) is not
# forced here; the gate does not prove it.
awk 'function forced() {
    print "      # Copy only (concurrent_mark freed proof): the first kept chunk a sweep looks at in the armed arena is published"
    print "      # here, and the look holds until its free says it is waiting, or the entry of that chunk changes."
    print "      @[UnsafeReach(\"copy-only: the look words, set and read through their addresses\")]"
    print "      @@forced_on : UInt64 = 0_u64"
    print "      @[UnsafeReach(\"copy-only: the look words, set and read through their addresses\")]"
    print "      @@forced_arena : UInt64 = 0_u64"
    print "      @[UnsafeReach(\"copy-only: the look words, set and read through their addresses\")]"
    print "      @@forced_look : UInt64 = 0_u64"
    print "      @[UnsafeReach(\"copy-only: the look words, set and read through their addresses\")]"
    print "      @@forced_waiting : UInt64 = 0_u64"
    print ""
    print "      def self.arm_look(arena : UInt64) : Nil"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_arena).address).value.set(arena)"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_on).address).value.set(1_u64)"
    print "      end"
    print ""
    print "      def self.look_on_helper? : Bool"
    print "        @@cache == 0_u64"
    print "      end"
    print ""
    print "      def self.look_armed_in?(arena : UInt64) : Bool"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_on).address).value.get != 0_u64 && Pointer(Atomic(UInt64)).new(pointerof(@@forced_arena).address).value.get == arena"
    print "      end"
    print ""
    print "      def self.forced_look : UInt64"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_look).address).value.get"
    print "      end"
    print ""
    print "      def self.publish_look(chunk : UInt64) : Nil"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_look).address).value.set(chunk)"
    print "      end"
    print ""
    print "      def self.forced_waiting : UInt64"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_waiting).address).value.get"
    print "      end"
    print ""
    print "      def self.note_free_waiting(head : UInt64) : Nil"
    print "        if Pointer(Atomic(UInt64)).new(pointerof(@@forced_on).address).value.get != 0_u64"
    print "          Pointer(Atomic(UInt64)).new(pointerof(@@forced_waiting).address).value.set(head)"
    print "        end"
    print "      end"
    print ""
  }
  /^      def self\.free\(pointer : Void\*\) : Nil$/ { forced(); declared++ }
  /^      def self\.helper_main\(seen : UInt64\) : Nil$/ {
    print "      def self.freed_collecting? : Bool"
    print "        @@collecting"
    print "      end"
    print ""
    mark_declared++
  }
  /^      def self\.free_unswept\(/ { print; print "        note_free_waiting(head)"; noted++; next }
  /^          word = IyiHeap\.read8\(byte\)$/ { print
    print "          if chunk >= 1024_u64 && word & IyiHeap::EPOCH_FLAG != epoch && word & IyiHeap::FREE_FLAG == 0 && IyiHeap.read8(mark) != WHITE"
    print "            if IyiHeap.look_armed_in?(arena) && IyiHeap.forced_look == 0_u64"
    print "              unless IyiHeap.look_on_helper?"
    print "                message = \"freed: the armed look ran on an allocating thread, not a helper\\n\""
    print "                __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "                __iyi_exit(76)"
    print "              end"
    print "              IyiHeap.publish_look(cursor)"
    print "              look_limit = IyiMark.now_ns &+ 5000000000_u64"
    print "              while IyiHeap.read8(byte) == word && IyiHeap.forced_waiting != cursor && IyiMark.now_ns < look_limit"
    print "                spin_pause"
    print "              end"
    print "              if IyiHeap.read8(byte) == word && IyiHeap.forced_waiting != cursor"
    print "                __iyi_write(2, \"freed: the sweep held a chunk the last mark kept for five seconds, and no free came\\n\".to_unsafe.as(Void*), 84_u64)"
    print "                __iyi_exit(76)"
    print "              end"
    print "              if IyiHeap.read8(byte) != word"
    print "                __iyi_write(2, \"freed: a chunk the last mark kept was freed while the sweep looked at it\\n\".to_unsafe.as(Void*), 73_u64)"
    print "                __iyi_exit(1)"
    print "              end"
    print "            end"
    print "          end"
    found++; next }
  { print } END { if (declared != 1 || mark_declared != 1 || noted != 1 || found != 1) exit 3 }' "$REPO/src/iyi/prelude.iyi" > widened/iyi/prelude.iyi || { echo "the sweep's look or the free this step arms is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/widened${PSEP}$REPO/src" "$IYI" build freed.iyi -o freed-widened > build-widened.log 2>&1; then
  cat build-widened.log; exit 1
fi
for run in 1 2 3 4 5 6 7 8 9 10; do
  timeout -k 5 120 ./freed-widened > widened.txt 2>&1
  code=$?
  if [ "$code" -ne 0 ] || ! grep -qx "lost 0" widened.txt; then
    echo "  run $run of 10 beside the widened sweep lost a chunk or saw a free land (exit $code):"; tail -3 widened.txt; exit 1
  fi
done
echo "  ten runs, no free inside the sweep's look at a kept chunk, every chunk intact"

step "failure proof: the armed look held for the program's free of its chunk, with that free made by the locked path"
if ! IYI_PATH="$WORK/widened${PSEP}$REPO/src" "$IYI" build freed.iyi -Dfreed_force -o freed-armed > build-armed.log 2>&1; then
  cat build-armed.log; exit 1
fi
timeout -k 5 120 ./freed-armed > armed.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -qx "lost 0" armed.txt; then
  echo "the hook alone, armed, did not keep every chunk (exit $code):"; tail -3 armed.txt; exit 1
fi
echo "  the hook alone, armed, exits 0: $(grep -m1 '^lost' armed.txt)"

step "failure proof: a chunk the sweep has not reached, freed with no lock, is freed inside the sweep's look"
mkdir -p unlocked/iyi
cp "$REPO"/src/iyi/*.iyi unlocked/iyi/
awk '{ if (sub(/^            free_unswept\(arena, head, slot, table, index\)$/, "            list_freed(arena, head, slot, table, index)")) found++; print } END { if (found != 1) exit 3 }' \
  widened/iyi/prelude.iyi > unlocked/iyi/prelude.iyi || { echo "the free this proof puts back is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/unlocked${PSEP}$REPO/src" "$IYI" build freed.iyi -Dfreed_force -o freed-unlocked > build-unlocked.log 2>&1; then
  cat build-unlocked.log; exit 1
fi
timeout -k 5 120 ./freed-unlocked > unlocked.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -Fxq "freed: a chunk the last mark kept was freed while the sweep looked at it" unlocked.txt; then
  echo "the free with no lock was not seen inside the sweep's look (exit $code):"; tail -3 unlocked.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "freed: a chunk the last mark kept was freed while the sweep looked at it"

# Copy only: each helper that takes a mark permit waits in its drain until the
# program releases the move, so the payload the program moves is still white.
# The hook changes no runtime decision; with it the move is forced, and the
# proofs below no longer depend on whether the marker reached the tail first.
hold_moves() {
  awk 'function forced() {
      print "      # Copy only (concurrent_mark moves proof): helpers wait in drain until the program releases its move."
      print "      @[UnsafeReach(\"copy-only: the move hold word, set and read through its address\")]"
      print "      @@forced_move : UInt64 = 0_u64"
      print ""
      print "      def self.hold_move : Nil"
      print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_move).address).value.set(1_u64)"
      print "      end"
      print ""
      print "      def self.release_move : Nil"
      print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_move).address).value.set(0_u64)"
      print "      end"
      print ""
      print "      def self.forced_move_hold? : Bool"
      print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_move).address).value.get != 0_u64"
      print "      end"
      print ""
    }
    /^      def self\.helper_main\(seen : UInt64\) : Nil$/ { forced(); declared++ }
    /^            IyiHeap\.write64\(w \+ W_BLACK, drain\(w\)\)$/ {
      print "            move_limit = IyiMark.now_ns &+ 10000000000_u64"
      print "            while forced_move_hold?"
      print "              if IyiMark.now_ns >= move_limit"
      print "                message = \"FAIL: moves: the helper was held past ten seconds\\n\""
      print "                __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
      print "                __iyi_exit(76)"
      print "              end"
      print "              IyiThread.park_if_requested"
      print "              spin_pause"
      print "            end"
      print; held++; next
    }
    { print } END { if (declared != 1 || held != 1) exit 3 }' "$1" > "$2" || { echo "the helper's drain this proof holds is missing or ambiguous"; exit 1; }
}

step "the moves beside the program, forced: every round's payload white at its move"
mkdir -p moves-held/iyi
cp "$REPO"/src/iyi/*.iyi moves-held/iyi/
hold_moves "$REPO/src/iyi/prelude.iyi" moves-held/iyi/prelude.iyi
if ! IYI_PATH="$WORK/moves-held${PSEP}$REPO/src" "$IYI" build --release -Dmove_force "$REPO/bench/concurrent_mark.iyi" -o moves-held-run > build-moves-held.log 2>&1; then
  cat build-moves-held.log; exit 1
fi
timeout -k 5 300 ./moves-held-run > moves-held.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -q '^moves: 24 of 24 rounds moved a payload' moves-held.txt; then
  echo "the forced moves did not hold (exit $code):"; tail -3 moves-held.txt; exit 1
fi
echo "  the hook alone, exits 0: $(grep -m1 '^moves:' moves-held.txt | cut -c1-80)"

step "failure proof: a barrier that shades nothing loses the moved payload"
mkdir -p patched/iyi
cp "$REPO"/src/iyi/*.iyi patched/iyi/
awk '{ if (sub(/return unless Pointer\(Atomic\(UInt8\)\)\.new\(mark\)\.value\.compare_and_set\(WHITE\.unsafe_to_u8, GRAY\.unsafe_to_u8\)\[1\]/, "return # the barrier shades nothing")) found = 1; print } END { if (!found) exit 3 }' "$REPO/src/iyi/prelude.iyi" > patched/iyi/prelude.iyi.shade || { echo "the barrier's shading this proof removes is not in the prelude any more"; exit 1; }
cmp -s patched/iyi/prelude.iyi.shade "$REPO/src/iyi/prelude.iyi" && { echo "the awk found nothing to change"; exit 1; }
hold_moves patched/iyi/prelude.iyi.shade patched/iyi/prelude.iyi
if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src" "$IYI" build --release -Dmove_force "$REPO/bench/concurrent_mark.iyi" -o nobarrier > build-nobarrier.log 2>&1; then
  cat build-nobarrier.log; exit 1
fi
timeout -k 5 300 ./nobarrier > nobarrier.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -Eq "^FAIL: round [0-9]+: (the payload moved into a black holder under the mark was freed: the barrier lost it|the payload's seed is -?[0-9]+ rather than -?[0-9]+: its chunk was reused, the barrier lost it)$" nobarrier.txt; then
  echo "the payload check did not fire (exit $code):"; tail -3 nobarrier.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 'the barrier lost it' nobarrier.txt)"

step "failure proof: a barrier that shades after its mark ended loses what the holder held"
mkdir -p stray/iyi
cp "$REPO"/src/iyi/*.iyi stray/iyi/
awk '{ if ($0 ~ /^        return if LibIyiGCTable\.__iyi_marking == 0_u8$/ && prev ~ /def self\.barrier\(/) { prev = $0; next } prev = $0; print }' "$REPO/src/iyi/prelude.iyi" > stray/iyi/prelude.iyi.stray
cmp -s stray/iyi/prelude.iyi.stray "$REPO/src/iyi/prelude.iyi" && { echo "the awk found nothing to change"; exit 1; }
hold_moves stray/iyi/prelude.iyi.stray stray/iyi/prelude.iyi
if ! IYI_PATH="$WORK/stray${PSEP}$REPO/src" "$IYI" build --release -Dmove_force "$REPO/bench/concurrent_mark.iyi" -o straybarrier > build-stray.log 2>&1; then
  cat build-stray.log; exit 1
fi
timeout -k 5 300 ./straybarrier > stray.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -Fxq "FAIL: stray: a barrier run after its mark had ended left the holder gray, and the next mark swept the payload it held" stray.txt; then
  echo "the stray barrier check did not fire (exit $code):"; tail -3 stray.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 'stray: a barrier run after' stray.txt)"

step "failure proof: a large block outgrown under a mark, the mark held open by the copy's closer, is unmapped beside the helpers"
mkdir -p held/iyi
cp "$REPO"/src/iyi/*.iyi held/iyi/
# The closer of a concurrent mark is the only thing that finishes one (the
# `finish_concurrent` call in helper_main). The hook holds it while the
# program says so, so the mark is still running when the program's realloc
# frees the old block. The copy's only change is the hold: with the guard
# in place the block stays mapped, and the held rounds say so. The original
# finish call is emitted by the unconditional print below. Do not print it
# in the hook too: two finishes corrupt the next mark.
awk 'function forced() {
    print "      # Copy only (concurrent_mark: the unmapped proof): the closer waits while a proof holds its mark open."
    print "      @[UnsafeReach(\"copy-only: the closer hold word, set and read through its address\")]"
    print "      @@forced_hold : UInt64 = 0_u64"
    print ""
    print "      def self.hold_mark : Nil"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_hold).address).value.set(1_u64)"
    print "      end"
    print ""
    print "      def self.release_mark : Nil"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_hold).address).value.set(0_u64)"
    print "      end"
    print ""
    print "      def self.forced_hold? : Bool"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_hold).address).value.get != 0_u64"
    print "      end"
    print ""
  }
  /^      def self\.helper_main\(seen : UInt64\) : Nil$/ { forced(); declared++ }
  /^              seen = finish_concurrent$/ {
    print "              hold_limit = IyiMark.now_ns &+ 10000000000_u64"
    print "              while IyiMark.forced_hold?"
    print "                if IyiMark.now_ns >= hold_limit"
    print "                  message = \"FAIL: large: the closer was held past ten seconds\\n\""
    print "                  __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "                  __iyi_exit(76)"
    print "                end"
    print "                spin_pause"
    print "              end"
    hooked++ }
  { print } END { if (declared != 1 || hooked != 1) exit 3 }' "$REPO/src/iyi/prelude.iyi" > held/iyi/prelude.iyi || { echo "the closer's finish or helper_main is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/held${PSEP}$REPO/src" "$IYI" build --release -Dunmapped_force "$REPO/bench/concurrent_mark.iyi" -o held-run > build-held.log 2>&1; then
  cat build-held.log; exit 1
fi
timeout -k 5 300 ./held-run > held.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -q "^large: 8 of 8 blocks outgrown under a running mark stayed mapped beside the helpers, and [0-8] were freed after$" held.txt; then
  echo "the held rounds did not keep the block mapped (exit $code):"; tail -3 held.txt; exit 1
fi
echo "  the hook alone, exits 0: $(grep -m1 '^large: 8 of 8' held.txt)"
mkdir -p unmapped/iyi
cp held/iyi/*.iyi unmapped/iyi/
awk '
  /^            free_large\(pointer\.address - HEADER\) if LibIyiGCTable\.__iyi_marking == 0_u8 && partition_free_large\(pointer\.address - HEADER - LARGE_HEAD\)$/ { print "            free_large(pointer.address - HEADER) if partition_free_large(pointer.address - HEADER - LARGE_HEAD)"; partitioned++; next }
  /^            free_large\(pointer\.address - HEADER\) if LibIyiGCTable\.__iyi_marking == 0_u8$/ { print "            free_large(pointer.address - HEADER)"; shared++; next }
  { print } END { if (partitioned != 1 || shared != 1) exit 3 }' \
  held/iyi/prelude.iyi > unmapped/iyi/prelude.iyi || { echo "the shared or partitioned guard is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/unmapped${PSEP}$REPO/src" "$IYI" build --release -Dunmapped_force "$REPO/bench/concurrent_mark.iyi" -o unmapped-run > build-unmapped.log 2>&1; then
  cat build-unmapped.log; exit 1
fi
timeout -k 5 300 ./unmapped-run > unmapped.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -Fxq "FAIL: large: a block outgrown under a mark was unmapped beside the helpers" unmapped.txt; then
  echo "the large block check did not fire (exit $code):"; tail -3 unmapped.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -Fx 'FAIL: large: a block outgrown under a mark was unmapped beside the helpers' unmapped.txt)"

step "failure proof: a small live set given the thousand-object bound goes beside the program"
mkdir -p thousand/iyi
cp "$REPO"/src/iyi/*.iyi thousand/iyi/
awk '{ if (sub(/drain_bounded\(w, IyiStat\.get\(IyiStat::KEPT\) < STW_MARK_SMALL \? STW_MARK_SMALL : STW_MARK_BOUND\)/, "drain_bounded(w, STW_MARK_BOUND)")) found++; print } END { if (found != 1) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > thousand/iyi/prelude.iyi || { echo "the bound this proof replaces is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/thousand${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o thousand-run > build-thousand.log 2>&1; then
  cat build-thousand.log; exit 1
fi
timeout -k 5 300 ./thousand-run > thousand.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -Eq "^FAIL: small: [0-9]+ of [0-9]+ collections over [0-9]+ live bytes ran beside the program$" thousand.txt; then
  echo "the small live set check did not fire (exit $code):"; tail -3 thousand.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: small:' thousand.txt)"

# A mark beside the program that never ended (#149): on Windows at eight
# and twelve workers, a server whose every connection was a parallel task
# parked on its socket stopped collecting, and its heap grew until the
# machine ran out. The remainder round, which runs beside the program when
# the second stop retreats, stored the count of workers marking over the
# mutators' assists counted in, and no drain saw it reach zero again.
# bench/mark_stall.iyi is that server's shape. Its watchdog fails a run
# whose collections stand still while it allocates, and the runtime fails
# one whose count goes below zero. Ten seconds with the helpers the
# runtime gives it, and ten with one: helper 0 alone, the case in which
# helper 0 waiting past the next mark leaves nobody to drain it. Linux
# never showed the stall unwidened - twenty runs of fifteen seconds at
# twelve workers on master, 1,588 second stops retreated, none stalled.
# The proofs below force their interleavings with event acknowledgements.
step "marks beside twenty-four connections on twelve workers all end, with every helper and with one"
if ! "$IYI" build --release "$REPO/bench/mark_stall.iyi" -o stall > build-stall.log 2>&1; then
  cat build-stall.log; exit 1
fi
for helpers in every one; do
  case "$helpers" in
    every) timeout -k 5 120 ./stall workers=12 seconds=10 > "stall-$helpers.txt" 2>&1 ;;
    one) timeout -k 5 120 ./stall workers=12 seconds=10 helpers=1 > "stall-$helpers.txt" 2>&1 ;;
  esac
  code=$?
  if [ "$code" -ne 0 ] || ! grep -q "every collection finished" "stall-$helpers.txt"; then
    echo "  with $helpers helper, exit $code:"; cat "stall-$helpers.txt"; exit 1
  fi
  echo "  with $helpers helper: $(grep '^collections:' "stall-$helpers.txt")"
done

# The copied runtime acknowledges its forced event. Producers keep allocating
# until that acknowledgement, with a deadline used only to name a hang.
cat > forced.iyi <<'IYI'
module forced

class Node
  getter value : Int64
  property next_node : Node?
  def initialize(@value : Int64, @next_node : Node?)
  end
end

class Flag
  getter ready : Atomic(Int32)
  getter go : Atomic(Int32)
  getter stop : Atomic(Int32)
  def initialize
    @ready = Atomic(Int32).new(0)
    @go = Atomic(Int32).new(0)
    @stop = Atomic(Int32).new(0)
  end
end

name = "forced"
Program.args.each do |argument|
  parts = argument.split('=')
  if parts.size == 2 && parts[0] == "name"
    name = parts[1]
  elsif parts.size == 2 && parts[0] == "helpers"
    IyiMark.workers = parts[1].to_i.to_u64
  else
    print "FAIL: forced: no option #{argument}\n"
    __iyi_exit(2)
  end
end
IyiMark.auto = false
chain = nil.as(Node?)
i = 0
while i < 200000
  chain = Node.new(i.to_i64, chain)
  i += 1
end
flag = Flag.new
producers = [] of IyiThread
2.times do
  producers << IyiThread.start do
    flag.ready.add(1)
    while flag.go.get == 0
      IyiThread.park_if_requested
      IyiThread.spin_pause
    end
    kept = 0_i64
    while flag.stop.get == 0
      node = Node.new(kept, nil)
      j = 1
      while j < 64
        node = Node.new(kept &+ j.to_i64, node)
        j += 1
      end
      kept = kept &+ node.value
    end
    nil
  end
end
limit = IyiMark.now_ns + 60000000000_u64
while flag.ready.get != 2
  if IyiMark.now_ns >= limit
    print "FAIL: #{name}: producers did not become ready within sixty seconds\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
IyiMark.auto = true
flag.go.set(1)
limit = IyiMark.now_ns + 60000000000_u64
while !IyiMark.forced_acked?
  if IyiMark.now_ns >= limit
    print "FAIL: #{name}: the copy acknowledged nothing within sixty seconds, after #{IyiMark.collections} collections, #{IyiMark.concurrent_collections} of them beside the program\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
flag.stop.set(1)
producers.each { |thread| thread.join }
count = 0
node = chain
while node
  count += 1
  node = node.next_node
end
if count != 200000
  print "FAIL: #{name}: the chain held #{count} of its 200000 nodes after the acknowledgement\n"
  __iyi_exit(1)
end
puts "forced: #{name} acknowledged"
IYI
add_forced_ack() {
  awk '/^      def self\.helper_main\(seen : UInt64\) : Nil$/ {
      print "      @[UnsafeReach(\"copy-only: forced fixture acknowledgement\")]"
      print "      @@forced_ack : UInt64 = 0_u64"
      print "      def self.forced_ack : Nil"
      print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_ack).address).value.set(1_u64)"
      print "      end"
      print "      def self.forced_acked? : Bool"
      print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_ack).address).value.get != 0_u64"
      print "      end"
      found++
    }
    { print } END { if (found != 1) exit 3 }' "$1/iyi/prelude.iyi" > "$1/iyi/prelude.iyi.new" || { echo "the acknowledgement anchor in $1 is missing or ambiguous"; exit 1; }
  mv "$1/iyi/prelude.iyi.new" "$1/iyi/prelude.iyi"
}

# Force one retreat and hold its remainder count until an assist has counted
# itself in. The control adds helper 0; the mutant stores over that assist.
step "the remainder round counts helper 0 beside a held assist"
mkdir -p stored-held/iyi stored/iyi
cp "$REPO"/src/iyi/*.iyi stored-held/iyi/
awk 'function declarations() {
    print "      @[UnsafeReach(\"copy-only: stored proof state\")]"
    print "      @@stored_state : UInt64 = 0_u64"
    print "      @[UnsafeReach(\"copy-only: stored proof assist\")]"
    print "      @@stored_assist : UInt64 = 0_u64"
    print "      def self.stored_word : Pointer(Atomic(UInt64))"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@stored_state).address)"
    print "      end"
    print "      def self.stored_retreat?(attempts : UInt64) : Bool"
    print "        attempts == 0_u64 && stored_word.value.compare_and_set(0_u64, 1_u64)[1]"
    print "      end"
    print "      def self.stored_open : Bool"
    print "        return false unless stored_word.value.compare_and_set(1_u64, 2_u64)[1]"
    print "        limit = now_ns &+ 10000000000_u64"
    print "        assist = Pointer(Atomic(UInt64)).new(pointerof(@@stored_assist).address)"
    print "        while assist.value.get == 0_u64"
    print "          if now_ns >= limit"
    print "            message = \"FAIL: stored: no assist entered the forced remainder within ten seconds\\n\""
    print "            __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "            __iyi_exit(76)"
    print "          end"
    print "          spin_pause"
    print "        end"
    print "        message = \"stored: an assist counted itself in before helper 0 and waits for its count\\n\""
    print "        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "        true"
    print "      end"
    print "      def self.stored_close : Nil"
    print "        stored_word.value.set(3_u64)"
    print "      end"
    print "      def self.stored_hold_assist : Nil"
    print "        return unless stored_word.value.get == 2_u64"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@stored_assist).address).value.set(1_u64)"
    print "        limit = now_ns &+ 10000000000_u64"
    print "        while stored_word.value.get == 2_u64"
    print "          if now_ns >= limit"
    print "            message = \"FAIL: stored: the assist was held past ten seconds\\n\""
    print "            __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "            __iyi_exit(76)"
    print "          end"
    print "          spin_pause"
    print "        end"
    print "      end"
    print "      def self.stored_finished : Nil"
    print "        return unless stored_word.value.compare_and_set(3_u64, 4_u64)[1]"
    print "        message = \"stored: the mark whose remainder counted the held assist finished\\n\""
    print "        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "        forced_ack"
    print "      end"
  }
  /^      def self\.assist : Nil$/ { declarations(); declared++ }
  /^        active\.value\.add\(1_u64\)$/ { print; print "        stored_hold_assist"; assist++; next }
  /^            if attempts < FINISH_RETRIES && unfinished$/ {
    print "            if attempts < FINISH_RETRIES && (stored_retreat?(attempts) || unfinished)"
    retreat++; next
  }
  /^          pool_word\(POOL_ACTIVE\)\.value\.add\(1_u64\)$/ {
    print "          stored_window = stored_open"
    print
    print "          stored_close if stored_window"
    counted++; next
  }
  /^            return generation$/ { print "            stored_finished"; finished++ }
  { print } END { if (declared != 1 || assist != 1 || retreat != 1 || counted != 1 || finished != 1) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > stored-held/iyi/prelude.iyi || { echo "the stored proof hooks are missing or ambiguous"; exit 1; }
add_forced_ack stored-held
if ! IYI_PATH="$WORK/stored-held${PSEP}$REPO/src" "$IYI" build --release forced.iyi -o stored-held-run > build-stored-held.log 2>&1; then
  cat build-stored-held.log; exit 1
fi
timeout -k 5 120 ./stored-held-run name=stored > stored-held.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -Fxq "forced: stored acknowledged" stored-held.txt || ! grep -Fxq "stored: the mark whose remainder counted the held assist finished" stored-held.txt || ! grep -Fxq "stored: an assist counted itself in before helper 0 and waits for its count" stored-held.txt; then
  echo "the held stored control did not complete (exit $code):"; tail -5 stored-held.txt; exit 1
fi
echo "  held stored control exits 0 after the assist rendezvous"
step "failure proof: storing over the counted assist loses the worker count"
cp stored-held/iyi/*.iyi stored/iyi/
awk '/^          pool_word\(POOL_ACTIVE\)\.value\.add\(1_u64\)$/ {
    print "          pool_word(POOL_ACTIVE).value.set(1_u64)"; found++; next
  }
  { print } END { if (found != 1) exit 3 }' stored-held/iyi/prelude.iyi > stored/iyi/prelude.iyi || { echo "the remainder count is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/stored${PSEP}$REPO/src" "$IYI" build --release forced.iyi -o stored-run > build-stored.log 2>&1; then
  cat build-stored.log; exit 1
fi
timeout -k 5 120 ./stored-run name=stored > stored.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || grep -Fxq "forced: stored acknowledged" stored.txt || ! grep -Fxq "stored: an assist counted itself in before helper 0 and waits for its count" stored.txt || ! grep -Eq "^iyi: the collector's count of workers marking went below zero: POOL_ACTIVE [0-9]+, POOL_HEAD [0-9]+, generation [0-9]+, permits left [0-9]+ and taken [0-9]+, helpers done [0-9]+[.] A mark that does not end is a bug in iyi's runtime, ours to fix: https://github[.]com/iyilang/iyi/issues$" stored.txt; then
  echo "the stored count was not caught after the rendezvous (exit $code):"; tail -5 stored.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 'went below zero' stored.txt)"

# Hold helper 0 after its first finish until a later concurrent mark opens.
# The control keeps the early generation read; the mutant moves only that
# read past the hold and is caught by the actual unclaimed-permit state.
step "helper 0 retains its generation across a forced next mark"
mkdir -p late-held/iyi late/iyi
cp "$REPO"/src/iyi/*.iyi late-held/iyi/
awk 'function forced() {
    print "      @[UnsafeReach(\"copy-only: one late generation hold\")]"
    print "      @@late_once : UInt64 = 0_u64"
    print "      @[UnsafeReach(\"copy-only: late check passed\")]"
    print "      @@late_checked : UInt64 = 0_u64"
    print "      def self.late_hold(old : UInt64) : Bool"
    print "        return false unless Pointer(Atomic(UInt64)).new(pointerof(@@late_once).address).value.compare_and_set(0_u64, 1_u64)[1]"
    print "        if @@helpers != 1_u64"
    print "          message = \"FAIL: late: the forced generation proof requires one helper\\n\""
    print "          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "          __iyi_exit(76)"
    print "        end"
    print "        limit = now_ns &+ 10000000000_u64"
    print "        while pool_word(POOL_GENERATION).value.get == old || LibIyiGCTable.__iyi_marking == 0_u8 || pool_word(POOL_FINISH).value.get == 0_u64"
    print "          if now_ns >= limit"
    print "            message = \"FAIL: late: the next concurrent mark did not start within ten seconds\\n\""
    print "            __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "            __iyi_exit(76)"
    print "          end"
    print "          spin_pause"
    print "        end"
    print "        true"
    print "      end"
    print "      def self.late_check(generation : UInt64) : Nil"
    print "        permits = pool_word(POOL_MARK_PERMITS).value.get"
    print "        unless LibIyiGCTable.__iyi_marking != 0_u8 && pool_word(POOL_FINISH).value.get != 0_u64 && permits == 1_u64"
    print "          message = \"FAIL: late: the next mark did not retain one unclaimed permit\\n\""
    print "          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "          __iyi_exit(76)"
    print "        end"
    print "        if generation == pool_word(POOL_GENERATION).value.get && LibIyiGCTable.__iyi_marking != 0_u8 && pool_word(POOL_FINISH).value.get != 0_u64 && permits == 1_u64"
    print "          message = \"FAIL: late: helper 0 would wait past the turn of a mark whose permit nobody has taken\\n\""
    print "          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "          __iyi_exit(1)"
    print "        end"
    print "        message = \"late: helper 0 retained its earlier generation through the next mark\\n\""
    print "        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@late_checked).address).value.set(1_u64)"
    print "      end"
    print "      def self.late_finished : Nil"
    print "        return unless Pointer(Atomic(UInt64)).new(pointerof(@@late_checked).address).value.compare_and_set(1_u64, 2_u64)[1]"
    print "        message = \"late: helper 0 finished the next mark\\n\""
    print "        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "        forced_ack"
    print "      end"
  }
  /^      def self\.helper_main\(seen : UInt64\) : Nil$/ { forced(); declared++ }
  /^            generation = pool_word\(POOL_GENERATION\)\.value\.get$/ {
    print "            late_baseline = pool_word(POOL_GENERATION).value.get"
    baseline++
  }
  /^            return generation$/ {
    print "            late_forced = late_hold(late_baseline)"
    print "            late_check(generation) if late_forced"
    print "            late_finished unless late_forced"
    hook++
  }
  { print } END { if (declared != 1 || baseline != 1 || hook != 1) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > late-held/iyi/prelude.iyi || { echo "the late generation hook is missing or ambiguous"; exit 1; }
add_forced_ack late-held
if ! IYI_PATH="$WORK/late-held${PSEP}$REPO/src" "$IYI" build --release forced.iyi -o late-held-run > build-late-held.log 2>&1; then
  cat build-late-held.log; exit 1
fi
timeout -k 5 120 ./late-held-run name=late helpers=1 > late-held.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -Fxq "forced: late acknowledged" late-held.txt || ! grep -Fxq "late: helper 0 finished the next mark" late-held.txt || ! grep -Fxq "late: helper 0 retained its earlier generation through the next mark" late-held.txt; then
  echo "the held late control did not complete (exit $code):"; tail -5 late-held.txt; exit 1
fi
echo "  held late control exits 0 after the next mark"
step "failure proof: helper 0 reads the next mark generation too late"
cp late-held/iyi/*.iyi late/iyi/
awk '/^            generation = pool_word\(POOL_GENERATION\)\.value\.get$/ { early++; next }
  /^            late_check\(generation\) if late_forced$/ {
    print "            generation = pool_word(POOL_GENERATION).value.get"
    moved++
  }
  { print } END { if (early != 1 || moved != 1) exit 3 }' late-held/iyi/prelude.iyi > late/iyi/prelude.iyi || { echo "the late generation read is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/late${PSEP}$REPO/src" "$IYI" build --release forced.iyi -o late-run > build-late.log 2>&1; then
  cat build-late.log; exit 1
fi
timeout -k 5 120 ./late-run name=late helpers=1 > late.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || grep -Fxq "forced: late acknowledged" late.txt || ! grep -Fxq "FAIL: late: helper 0 would wait past the turn of a mark whose permit nobody has taken" late.txt; then
  echo "the late generation was not caught (exit $code):"; tail -5 late.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "FAIL: late: helper 0 would wait past the turn of a mark whose permit nobody has taken"

# The historical bug let the collection flag fall after threads were released.
# The copy holds the collector after its release until the first slice
# past the budget answers the probe. The control clears the flag before the
# release and the probe answers "let go". The mutant clears the flag only after
# the hold, and the probe fails on that state.
step "failure proof: a collection let go after its threads are released leaves their allocation untriggered"
mkdir -p released-held/iyi released/iyi
cp "$REPO"/src/iyi/*.iyi released-held/iyi/
awk 'function declarations() {
    print "      # Copy only (concurrent_mark released proof): the first slice past the budget after the release answers one probe."
    print "      @[UnsafeReach(\"copy-only: release probe words\")]"
    print "      @@probe_once : UInt64 = 0_u64"
    print "      @[UnsafeReach(\"copy-only: release probe words\")]"
    print "      @@probe_state : UInt64 = 0_u64"
    print ""
    print "      def self.arm_release_probe : Bool"
    print "        return false unless Pointer(Atomic(UInt64)).new(pointerof(@@probe_once).address).value.compare_and_set(0_u64, 1_u64)[1]"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@probe_state).address).value.set(1_u64)"
    print "        true"
    print "      end"
    print ""
    print "      def self.release_probe(total : UInt64) : Nil"
    print "        return unless Pointer(Atomic(UInt64)).new(pointerof(@@probe_state).address).value.get == 1_u64 && total >= budget"
    print "        up = @@collecting"
    print "        return unless Pointer(Atomic(UInt64)).new(pointerof(@@probe_state).address).value.compare_and_set(1_u64, 2_u64)[1]"
    print "        if up"
    print "          message = \"FAIL: released: the first slice past the budget after the release found the collection still up\\n\""
    print "          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "          __iyi_exit(1)"
    print "        end"
    print "        message = \"released: the first slice past the budget after the release found the collection let go\\n\""
    print "        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@probe_state).address).value.set(3_u64)"
    print "      end"
    print ""
    print "      def self.hold_release_probe : Nil"
    print "        limit = now_ns &+ 10000000000_u64"
    print "        while Pointer(Atomic(UInt64)).new(pointerof(@@probe_state).address).value.get != 3_u64"
    print "          if now_ns >= limit"
    print "            message = \"FAIL: released: the release probe was not answered within ten seconds\\n\""
    print "            __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "            __iyi_exit(76)"
    print "          end"
    print "          spin_pause"
    print "        end"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@probe_state).address).value.set(0_u64)"
    print "        forced_ack"
    print "      end"
    print ""
  }
  /^      def self\.pressure\(size : UInt64\) : Nil$/ { declarations(); print; declared++; in_pressure = 1; next }
  in_pressure && /^        total = IyiHeap\.allocated_word\.value\.add\(size\) \+ size$/ { print; print "        release_probe(total)"; in_pressure = 0; probed++; next }
  prev_lg && $0 == "            IyiThread.resume_others(others)" { print "            released_forced = arm_release_probe"; print; prev_lg = 0; armed++; next }
  $0 == "            return generation" { print "            hold_release_probe if released_forced"; print; returned++; prev_lg = 0; next }
  { prev_lg = ($0 == "            let_go_holders"); print }
  END { if (declared != 1 || probed != 1 || armed != 1 || returned != 1) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > released-held/iyi/prelude.iyi || { echo "the release order or pressure is missing or ambiguous"; exit 1; }
add_forced_ack released-held
cp released-held/iyi/*.iyi released/iyi/
awk 'pend {
    if ($0 == "            let_go_holders") { print; pend = 0; dropped++; next }
    print "            @@collecting = false"; pend = 0
  }
  $0 == "            @@collecting = false" { pend = 1; next }
  $0 == "            hold_release_probe if released_forced" { print; print "            @@collecting = false"; added++; next }
  { print } END { if (dropped != 1 || added != 1) exit 3 }' released-held/iyi/prelude.iyi > released/iyi/prelude.iyi || { echo "the flag this proof moves is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/released-held${PSEP}$REPO/src" "$IYI" build --release forced.iyi -o released-held-run > build-released-held.log 2>&1; then
  cat build-released-held.log; exit 1
fi
timeout -k 5 120 ./released-held-run name=released > released-held.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -Fxq "forced: released acknowledged" released-held.txt || ! grep -Fxq "released: the first slice past the budget after the release found the collection let go" released-held.txt; then
  echo "the held release control did not complete (exit $code):"; tail -5 released-held.txt; exit 1
fi
echo "  held release control exits 0 after the probe answers let go"
if ! IYI_PATH="$WORK/released${PSEP}$REPO/src" "$IYI" build --release forced.iyi -o released-run > build-released.log 2>&1; then
  cat build-released.log; exit 1
fi
timeout -k 5 120 ./released-run name=released > released.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || grep -Fxq "forced: released acknowledged" released.txt || ! grep -Fxq "FAIL: released: the first slice past the budget after the release found the collection still up" released.txt; then
  echo "the untriggered allocation was not caught (exit $code):"; tail -5 released.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "FAIL: released: the first slice past the budget after the release found the collection still up"

# The same window where a program's own thread finishes the collection:
# the trigger's whose mark ends inside its first stop (`finish_stopped`),
# and the stopped ones, the trigger's with no helper and `IyiMark.collect`
# (`collect_locked`). Before the flag moved there, the window between their
# release and its fall lasted 1.6 to 24.2 ms at its longest in a run here,
# and one counted 166,789,120 bytes against a budget of 4,194,304
# (GC_DESIGN.md Stage 9). bench/release_trigger.iyi runs one collection
# of each and then a second thread's slices past the budget, which must
# trigger the next; three runs.
step "every collection a program's thread finishes is let go before its threads are released"
if ! "$IYI" build --release "$REPO/bench/release_trigger.iyi" -o trigger > build-trigger.log 2>&1; then
  cat build-trigger.log; exit 1
fi
for run in 1 2 3; do
  if ! timeout -k 5 60 ./trigger > "trigger-$run.txt" 2>&1 || ! grep -q "every collection was let go" "trigger-$run.txt"; then
    echo "  run $run:"; cat "trigger-$run.txt"; exit 1
  fi
done
grep -E '^(bounded|stopped|verb|one core):' trigger-1.txt | sed 's/^/  /'

# At the release of each stopped-collection path, hold its collector until a
# resumed thread crosses the next budget. The broken copies additionally hold
# until that thread reaches the ceiling; the normal copies release on the first
# crossing. Time is only a named setup failure, never a release condition.
if grep -q '^one core:' trigger-1.txt; then
  echo "FAIL: this host has one core; the bounded round needs a helper beside a second thread, and CI shapes have at least four"
  exit 1
fi
step "the stopped collectors let go before a resumed thread crosses the budget"
mkdir -p letgo-held/iyi
cp "$REPO"/src/iyi/*.iyi letgo-held/iyi/
awk 'function declarations() {
    print "      @[UnsafeReach(\"copy-only: let-go proof state\")]"
    print "      @@go_state : UInt64 = 0_u64"
    print "      @[UnsafeReach(\"copy-only: let-go proof sites\")]"
    print "      @@go_seen : UInt64 = 0_u64"
    print "      @[UnsafeReach(\"copy-only: let-go proof flag\")]"
    print "      @@go_up : UInt64 = 0_u64"
    print "      @[UnsafeReach(\"copy-only: let-go proof hold count\")]"
    print "      @@go_holds : UInt64 = 0_u64"
    print "      def self.go_arm(site : UInt64) : Bool"
    print "        seen = Pointer(Atomic(UInt64)).new(pointerof(@@go_seen).address)"
    print "        bit = 1_u64.unsafe_shl(site)"
    print "        return false if seen.value.get & bit != 0_u64"
    print "        seen.value.set(seen.value.get | bit)"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@go_up).address).value.set(0_u64)"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@go_holds).address).value.set(IyiStat.get(IyiStat::HOLDS))"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@go_state).address).value.set(1_u64)"
    print "        true"
    print "      end"
    print "      def self.go_probe(total : UInt64) : Nil"
    print "        state = Pointer(Atomic(UInt64)).new(pointerof(@@go_state).address)"
    print "        return unless state.value.get == 1_u64 && total >= budget"
    print "        up = @@collecting"
    print "        return unless state.value.compare_and_set(1_u64, 2_u64)[1]"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@go_up).address).value.set(up ? 1_u64 : 0_u64)"
    print "        message = up ? \"let-go: a resumed slice crossed the budget while collecting was up\\n\" : \"let-go: a resumed slice crossed the budget after collection was let go\\n\""
    print "        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "        state.value.set(3_u64)"
    print "      end"
    print "      def self.go_hold : Nil"
    print "        state = Pointer(Atomic(UInt64)).new(pointerof(@@go_state).address)"
    print "        limit = now_ns &+ 10000000000_u64"
    print "        while state.value.get != 3_u64"
    print "          if now_ns >= limit"
    print "            message = \"FAIL: let-go: the resumed thread did not answer the release probe within ten seconds\\n\""
    print "            __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "            __iyi_exit(76)"
    print "          end"
    print "          spin_pause"
    print "        end"
    print "        limit = now_ns &+ 10000000000_u64"
    print "        while Pointer(Atomic(UInt64)).new(pointerof(@@go_up).address).value.get != 0_u64 && IyiStat.get(IyiStat::HOLDS) <= Pointer(Atomic(UInt64)).new(pointerof(@@go_holds).address).value.get"
    print "          if now_ns >= limit"
    print "            message = \"FAIL: let-go: no resumed slice reached the ceiling within ten seconds of the probe\\n\""
    print "            __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "            __iyi_exit(76)"
    print "          end"
    print "          spin_pause"
    print "        end"
    print "        state.value.set(0_u64)"
    print "      end"
  }
  /^      def self\.pressure\(size : UInt64\) : Nil$/ { declarations(); print; declared++; in_pressure = 1; next }
  in_pressure && /^        total = IyiHeap\.allocated_word\.value\.add\(size\) \+ size$/ { print; print "        go_probe(total)"; in_pressure = 0; probed++; next }
  /^      def self\.collect_locked\(eager : Bool\) : Nil$/ { scope = 1 }
  /^        def self\.finish_stopped\(started : UInt64, others : Int64\) : Nil$/ { scope = 2 }
  /^        def self\.finish_concurrent : UInt64$/ { scope = 0 }
  scope == 1 && /^      end$/ { scope = 0 }
  scope == 2 && /^        end$/ { scope = 0 }
  scope == 1 && /^          IyiThread\.resume_others\(others\)$/ {
    print "          go_locked = go_arm(eager ? 2_u64 : 1_u64)"
    print
    print "          go_hold if go_locked"
    locked++; next
  }
  scope == 2 && /^          IyiThread\.resume_others\(others\)$/ {
    print "          go_stopped = go_arm(3_u64)"
    print
    print "          go_hold if go_stopped"
    stopped++; next
  }
  { print } END { if (declared != 1 || probed != 1 || locked != 1 || stopped != 1) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > letgo-held/iyi/prelude.iyi || { echo "the let-go proof anchors are missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/letgo-held${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/release_trigger.iyi" -o letgo-held-run > build-letgo-held.log 2>&1; then
  cat build-letgo-held.log; exit 1
fi
timeout -k 5 120 ./letgo-held-run > letgo-held.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -Fxq "release trigger: every collection was let go before its threads were released" letgo-held.txt || [ "$(grep -Fxc "let-go: a resumed slice crossed the budget after collection was let go" letgo-held.txt)" -ne 3 ]; then
  echo "the held let-go control did not complete (exit $code):"; tail -10 letgo-held.txt; exit 1
fi
echo "  held let-go control exits 0 for all three collection paths"
let_go_late() {
  name=$1 indent=$2
  shift 2
  mkdir -p "$name/iyi"
  cp letgo-held/iyi/*.iyi "$name/iyi/"
  awk -v n="$indent" 'BEGIN { while (length(pad) < n) pad = pad " " }
    $0 == (pad "@@collecting = false") { removed++; next }
    n == 8 && $0 == "          go_hold if go_locked" { print; print "          @@collecting = false"; inserted++; next }
    n == 10 && $0 == "          go_hold if go_stopped" { print; print "          @@collecting = false"; inserted++; next }
    { print } END { if (removed != 1 || inserted != 1) exit 3 }' \
    letgo-held/iyi/prelude.iyi > "$name/iyi/prelude.iyi" || { echo "the let-go order for $name is missing or ambiguous"; exit 1; }
  if ! IYI_PATH="$WORK/$name${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/release_trigger.iyi" -o "$name-run" > "build-$name.log" 2>&1; then
    cat "build-$name.log"; exit 1
  fi
  timeout -k 5 120 "./$name-run" > "$name.txt" 2>&1
  code=$?
  if [ "$code" -ne 1 ]; then
    echo "the untriggered slices were not caught (exit $code):"; cat "$name.txt"; exit 1
  fi
  for round in "$@"; do
    if ! grep -Eq "^FAIL: $round: after collection [0-9]+ was counted, [1-9][0-9]* of a thread's slices were held at the ceiling of a collection that was not theirs, which had not been let go$" "$name.txt"; then
      echo "the $round round did not fail at its complete sentence:"; cat "$name.txt"; exit 1
    fi
    printf '  exits 1 at "%s"\n' "$(grep -m1 "^FAIL: $round:" "$name.txt")"
  done
}
step "failure proof: a stopped collection let go after its threads are released leaves their slices untriggered"
let_go_late locked-late 8 stopped verb
step "failure proof: a collection that ends in its first stop let go after its threads are released leaves their slices untriggered"
let_go_late bounded-late 10 bounded

# Both copies hold the same free between reading and linking its cache head.
# A second thread requests collection there. The bracketed free observes the
# deferred stop request and leaves the bracket; the unbracketed free is
# stopped there and resumes after collection dropped its stale head.
step "failure proof: a free outside the allocator's bracket puts a dropped list back"
mkdir -p bracketed/iyi
cp "$REPO"/src/iyi/*.iyi bracketed/iyi/
cat > unbracketed.iyi <<'IYI'
@[Unsafe("frees raw 16-byte chunks with GC.free and allocates them with Pointer#malloc, reading the words it wrote into each to see whether two live chunks share one")]
module unbracketed

import std/gc::{GC}
IyiMark.auto = false

live = Pointer(Pointer(UInt64)).malloc(64_u64)
i = 0
while i < 64
  chunk = Pointer(UInt64).malloc(2_u64)
  chunk[0] = (i + 1).to_u64
  chunk[1] = (i + 1).to_u64 &+ 7_u64
  live[i] = chunk
  i += 1
end
# One collection, so every chunk above is kept and carries the current parity:
# a free of one of them takes the path with no lock.
IyiMark.collect
# The second thread waits until the free reaches the shared hook.
{% if flag?(:unbracketed_force) %}
  collector = IyiThread.start do
    limit = IyiMark.now_ns + 10000000000_u64
    while !IyiHeap.drop_requested? && IyiMark.now_ns < limit
      IyiThread.spin_pause
    end
    unless IyiHeap.drop_requested?
      print "FAIL: freed: the armed free never reached its link\n"
      __iyi_exit(76)
    end
    IyiMark.collect
    IyiHeap.finish_drop
    nil
  end
{% end %}
# The first free puts a chunk on this thread's cache list.
GC.free(live[0].as(Void*))
{% if flag?(:unbracketed_force) %}
  arena = IyiHeap.arena_of(live[1].address)
  head = IyiHeap.head_of(arena, live[1].address)
  slot = IyiHeap.chunk_index(arena, head)
  if IyiHeap.read8(arena + IyiHeap::META + slot * IyiHeap::META_ENTRY) & IyiHeap::EPOCH_FLAG != IyiMark.epoch_flag
    print "FAIL: freed: the armed chunk would take the locked free path\n"
    __iyi_exit(1)
  end
  IyiHeap.arm_drop
{% end %}
GC.free(live[1].as(Void*))
{% if flag?(:unbracketed_force) %}
  collector.join
  if IyiHeap.drop_done != 1_u64
    print "FAIL: freed: the armed collection did not complete exactly once\n"
    __iyi_exit(1)
  end
{% end %}
got = Pointer(Pointer(UInt64)).malloc(64_u64)
k = 0
while k < 64
  fresh = Pointer(UInt64).malloc(2_u64)
  m = 0
  while m < k
    if got[m].address == fresh.address
      print "freed: a free outside the allocator's bracket put a dropped list back\n"
      __iyi_exit(1)
    end
    m += 1
  end
  i = 2
  while i < 64
    if live[i].address == fresh.address
      print "freed: a free outside the allocator's bracket put a dropped list back\n"
      __iyi_exit(1)
    end
    i += 1
  end
  got[k] = fresh
  got[k][0] = 1000_u64 + k.to_u64
  k += 1
end
bad = 0
k = 0
while k < 64
  bad += 1 if got[k][0] != 1000_u64 + k.to_u64
  m = 0
  while m < k
    bad += 1 if got[m].address == got[k].address
    m += 1
  end
  k += 1
end
i = 2
while i < 64
  bad += 1 if live[i][0] != (i + 1).to_u64 || live[i][1] != (i + 1).to_u64 &+ 7_u64
  i += 1
end
if bad > 0
  print "freed: a free outside the allocator's bracket put a dropped list back\n"
  __iyi_exit(1)
end
puts "unbracketed: 64 chunks handed out, none shared, the 62 kept ones whole"
IYI
awk 'function forced() {
    print "      @[UnsafeReach(\"copy-only: bracket proof rendezvous words\")]"
    print "      @@drop_armed : UInt64 = 0_u64"
    print "      @[UnsafeReach(\"copy-only: bracket proof rendezvous words\")]"
    print "      @@drop_requested : UInt64 = 0_u64"
    print "      @[UnsafeReach(\"copy-only: bracket proof rendezvous words\")]"
    print "      @@drop_done : UInt64 = 0_u64"
    print "      def self.arm_drop : Nil"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@drop_armed).address).value.set(1_u64)"
    print "      end"
    print "      def self.drop_requested? : Bool"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@drop_requested).address).value.get != 0_u64"
    print "      end"
    print "      def self.drop_done : UInt64"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@drop_done).address).value.get"
    print "      end"
    print "      def self.finish_drop : Nil"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@drop_done).address).value.set(1_u64)"
    print "      end"
    print "      def self.hold_drop(table : Pointer(UInt64)) : Nil"
    print "        armed = Pointer(Atomic(UInt64)).new(pointerof(@@drop_armed).address).value"
    print "        return if armed.get == 0_u64"
    print "        armed.set(0_u64)"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@drop_requested).address).value.set(1_u64)"
    print "        limit = IyiMark.now_ns &+ 10000000000_u64"
    print "        while drop_done == 0_u64 && read64(table.address + CACHE_REQUEST) == 0_u64"
    print "          if IyiMark.now_ns >= limit"
    print "            message = \"FAIL: freed: the stop did not reach the held free\\n\""
    print "            __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "            __iyi_exit(76)"
    print "          end"
    print "          IyiMark.spin_pause"
    print "        end"
    print "      end"
  }
  /^      def self\.free\(pointer : Void\*\) : Nil$/ { forced(); declared++ }
  /^        write64\(head \+ OFF_LINK, table\[index\]\)$/ {
    print "        stale = table[index]"
    print "        IyiHeap.hold_drop(table)"
    print "        write64(head + OFF_LINK, stale)"
    linked++; next
  }
  { print } END { if (declared != 1 || linked != 1) exit 3 }' "$REPO/src/iyi/prelude.iyi" > bracketed/iyi/prelude.iyi || { echo "the list link or free this proof changes is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/bracketed${PSEP}$REPO/src" "$IYI" build unbracketed.iyi -Dunbracketed_force -o bracketed-run > build-bracketed.log 2>&1; then
  cat build-bracketed.log; exit 1
fi
timeout -k 5 120 ./bracketed-run > bracketed.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -Fxq 'unbracketed: 64 chunks handed out, none shared, the 62 kept ones whole' bracketed.txt; then
  echo "the bracketed control did not pass (exit $code):"; tail -3 bracketed.txt; exit 1
fi
echo "  the bracketed control exits 0: $(grep -Fx 'unbracketed: 64 chunks handed out, none shared, the 62 kept ones whole' bracketed.txt)"
mkdir -p unbracketed/iyi
cp bracketed/iyi/*.iyi unbracketed/iyi/
awk '/^          write64\(table\.address &\+ CACHE_INSIDE, read64\(table\.address &\+ CACHE_INSIDE\) &\+ 1_u64\)$/ { entered++; next }
  prev ~ /^          end$/ && /^          leave\(table\)$/ { left++; prev = $0; next }
  { prev = $0; print } END { if (entered != 1 || left != 1) exit 3 }' bracketed/iyi/prelude.iyi > unbracketed/iyi/prelude.iyi.new || { echo "the bracket this proof removes from free is missing or ambiguous"; exit 1; }
mv unbracketed/iyi/prelude.iyi.new unbracketed/iyi/prelude.iyi
if ! IYI_PATH="$WORK/unbracketed${PSEP}$REPO/src" "$IYI" build unbracketed.iyi -Dunbracketed_force -o unbracketed-run > build-unbracketed.log 2>&1; then
  cat build-unbracketed.log; exit 1
fi
timeout -k 5 120 ./unbracketed-run > unbracketed.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -Fxq "freed: a free outside the allocator's bracket put a dropped list back" unbracketed.txt; then
  echo "the dropped list was not put back (exit $code):"; tail -3 unbracketed.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "freed: a free outside the allocator's bracket put a dropped list back"

# Hold each worker after the first until every task has arrived. The healthy
# program releases the workers while waiting for the launched count; the
# arrived-only mutant waits only for task arrival and releases after the group.
if ! grep -q '^idle pool: with' answers.txt; then
  echo "FAIL: the idle pool step did not run: it needs three cores, and this host has fewer"
  exit 1
fi
step "the idle pool fills when workers wait for task arrival"
mkdir -p latestart/iyi
cp "$REPO"/src/iyi/*.iyi latestart/iyi/
awk '/^  def self\.work : Nil$/ {
    print "  @[UnsafeReach(\"copy-only: idle start rendezvous\")]"
    print "  @@idle_starts : Int64 = 0_i64"
    print "  @[UnsafeReach(\"copy-only: idle start rendezvous\")]"
    print "  @@idle_release : Int64 = 0_i64"
    print "  def self.release_starts : Nil"
    print "    word(pointerof(@@idle_release)).value.set(1_i64)"
    print "  end"
    print "  def self.hold_start : Nil"
    print "    return if word(pointerof(@@idle_starts)).value.add(1_i64) == 0_i64"
    print "    limit = IyiMark.now_ns &+ 10000000000_u64"
    print "    while word(pointerof(@@idle_release)).value.get == 0_i64"
    print "      if IyiMark.now_ns >= limit"
    print "        message = \"FAIL: idle pool: a worker start was held past ten seconds\\n\""
    print "        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "        __iyi_exit(76)"
    print "      end"
    print "      IyiThread.park_if_requested"
    print "      IyiThread.spin_pause"
    print "    end"
    print "    message = \"idle pool: a worker start waited until task arrival\\n\""
    print "    __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "  end"
    print
    found++
    if (getline <= 0 || $0 != "    {% if !flag?(:gc_none) && !flag?(:gc_boehm) %}") exit 3
    print; print "      hold_start"; inserted++; next
  }
  { print } END { if (found != 1 || inserted != 1) exit 3 }' \
  "$REPO/src/iyi/concurrency.iyi" > latestart/iyi/concurrency.iyi || { echo "the worker start is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/latestart${PSEP}$REPO/src" "$IYI" build --release -Didle_force "$REPO/bench/concurrent_mark.iyi" -o latestart-run > build-latestart.log 2>&1; then
  cat build-latestart.log; exit 1
fi
timeout -k 5 300 ./latestart-run > latestart.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -q "^idle pool: with" latestart.txt || ! grep -Fxq "idle pool: a worker start waited until task arrival" latestart.txt; then
  echo "the idle pool step did not hold on the late-start runtime (exit $code):"; tail -3 latestart.txt; exit 1
fi
echo "  $(grep -m1 '^idle pool: with' latestart.txt)"

step "failure proof: an idle pool step whose tasks wait only for each other is caught on that runtime"
awk '$0 == "            break unless arrived < cores || IyiWorkers.launched < cores.to_i32" {
    print "            break unless arrived < cores"; changed++; next }
  { print } END { if (changed != 1) exit 3 }' \
  "$REPO/bench/concurrent_mark.iyi" > arrived_only.iyi || { echo "the idle wait is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/latestart${PSEP}$REPO/src" "$IYI" build --release -Didle_force arrived_only.iyi -o arrived-only > build-arrived.log 2>&1; then
  cat build-arrived.log; exit 1
fi
timeout -k 5 300 ./arrived-only > arrived.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -Eq "^FAIL: idle pool: [12] of [0-9]+ workers waiting, and every worker the pool launched is one of them$" arrived.txt; then
  echo "the idle pool check did not fire (exit $code):"; tail -3 arrived.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: idle pool:' arrived.txt)"

# The pool's workers start one at a time, each called for by the one
# before it when its find leaves a task waiting (`IyiWorkers.stop_spinning`),
# and that call can be lost: a task half through its give-up at a back-edge
# - off its worker, not yet in the preempted queue - is not seen waiting,
# so a find that took the last task seen called nobody, and the tasks then
# took turns on the workers with none started. On the project's Mac (macOS
# 26.6, Apple M2 Pro, 10 cores) beside two other CI jobs the idle pool step
# read "9 of 10 workers waiting" so (job 134651603579), and in 1 of 150
# release runs beside 20 busy loops. A task that takes its turn while one
# waits and none is idle now starts the next worker
# (`IyiWorkers.turn_wanted?`). The copies below queue every task while the
# first worker is held, then observe a turn with no idle worker, no start in
# flight, and no start owed. Only the turn's start differs in the mutant.
turn_called="idle pool: a turn with queued work and no idle or spinning worker called for the next worker"
turn_lost="FAIL: idle pool: a turn with queued work and no idle or spinning worker called for no worker"
step "a turn with queued work calls for the next worker"
mkdir -p turn-held/iyi unstarted/iyi
cp "$REPO"/src/iyi/*.iyi turn-held/iyi/
awk -v called="$turn_called" -v lost="$turn_lost" 'function held() {
    print "  @[UnsafeReach(\"copy-only: turn proof words\")]"
    print "  @@first_held : Int64 = 0_i64"
    print "  @[UnsafeReach(\"copy-only: turn proof words\")]"
    print "  @@first_release : Int64 = 0_i64"
    print "  @[UnsafeReach(\"copy-only: turn proof words\")]"
    print "  @@turn_once : Int64 = 0_i64"
    print "  @[UnsafeReach(\"copy-only: turn proof words\")]"
    print "  @@turn_launched : Int64 = 0_i64"
    print "  @[UnsafeReach(\"copy-only: turn proof words\")]"
    print "  @@turn_owes : Int64 = 0_i64"
    print "  def self.release_first : Nil"
    print "    word(pointerof(@@first_release)).value.set(1_i64)"
    print "  end"
    print "  def self.hold_first : Nil"
    print "    return unless word(pointerof(@@first_held)).value.add(1_i64) == 0_i64"
    print "    limit = IyiMark.now_ns &+ 10000000000_u64"
    print "    while word(pointerof(@@first_release)).value.get == 0_i64"
    print "      if IyiMark.now_ns >= limit"
    print "        message = \"FAIL: idle pool: the first worker was held past ten seconds\\n\""
    print "        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "        __iyi_exit(76)"
    print "      end"
    print "      IyiThread.park_if_requested"
    print "      IyiThread.spin_pause"
    print "    end"
    print "  end"
    print "  def self.turn_arm : Bool"
    print "    return false unless word(pointerof(@@launched)).value.get == 1_i64 && word(pointerof(@@idle)).value.get == 0_i64 && word(pointerof(@@spinning)).value.get == 0_i64 && word(pointerof(@@owed)).value.get == 0_i64"
    print "    return false unless word(pointerof(@@turn_once)).value.compare_and_set(0_i64, 1_i64)[1]"
    print "    word(pointerof(@@turn_launched)).value.set(word(pointerof(@@launched)).value.get)"
    print "    word(pointerof(@@turn_owes)).value.set(owes.to_i64)"
    print "    true"
    print "  end"
    print "  def self.turn_verdict : Nil"
    print "    if word(pointerof(@@launched)).value.get > word(pointerof(@@turn_launched)).value.get || owes.to_i64 > word(pointerof(@@turn_owes)).value.get"
    print "      message = \"" called "\\n\""
    print "      __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "      return"
    print "    end"
    print "    message = \"" lost "\\n\""
    print "    __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "    __iyi_exit(1)"
    print "  end"
  }
  $0 == "    wake_one if found && work_waiting?" { uncalled++; prev = $0; next }
  /^  def self\.work : Nil$/ {
    held(); declared++; print
    if (getline <= 0 || $0 != "    {% if !flag?(:gc_none) && !flag?(:gc_boehm) %}") exit 3
    print; print "      hold_first"; inserted++; prev = $0; next
  }
  prev == "    return false unless work_waiting?" && $0 == "    wake_one" { print "    turn_armed = turn_arm"; print; print "    turn_verdict if turn_armed"; hooked++; prev = $0; next }
  { prev = $0; print } END { if (uncalled != 1 || declared != 1 || inserted != 1 || hooked != 1) exit 3 }' \
  "$REPO/src/iyi/concurrency.iyi" > turn-held/iyi/concurrency.iyi || { echo "a turn proof anchor is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/turn-held${PSEP}$REPO/src" "$IYI" build --release -Dunstarted_force "$REPO/bench/concurrent_mark.iyi" -o turn-held-run > build-turn-held.log 2>&1; then
  cat build-turn-held.log; exit 1
fi
timeout -k 5 300 ./turn-held-run > turn-held.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -q "^idle pool: with" turn-held.txt || [ "$(grep -Fxc "$turn_called" turn-held.txt)" -ne 1 ]; then
  echo "the held turn control did not call for the next worker and fill the pool (exit $code):"; tail -5 turn-held.txt; exit 1
fi
echo "  $turn_called"
step "failure proof: a turn with queued work calls for no worker"
cp turn-held/iyi/*.iyi unstarted/iyi/
awk 'prev == "    turn_armed = turn_arm" && $0 == "    wake_one" { removed++; prev = $0; next }
  { prev = $0; print } END { if (removed != 1) exit 3 }' turn-held/iyi/concurrency.iyi > unstarted/iyi/concurrency.iyi || { echo "the turn start is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/unstarted${PSEP}$REPO/src" "$IYI" build --release -Dunstarted_force "$REPO/bench/concurrent_mark.iyi" -o unstarted-run > build-unstarted.log 2>&1; then
  cat build-unstarted.log; exit 1
fi
timeout -k 5 300 ./unstarted-run > unstarted.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -Fxq "$turn_lost" unstarted.txt; then
  echo "the turn that called for no worker was not caught (exit $code):"; tail -5 unstarted.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$turn_lost"

# The first collection's wait for every helper to reach its park, put back.
# The helper is held before it counts itself ready. The same hook runs in
# both copies and reports if it observes the first collection waiting for
# that count before the program has released the helper. The broken copy
# publishes that state from inside its restored wait; no timer is a verdict.
step "failure proof: a first collection that waits for every helper to reach its park is caught"
mkdir -p held-helpers/iyi
cp "$REPO"/src/iyi/*.iyi held-helpers/iyi/
awk 'function forced() {
    print "      # Copy only (concurrent_mark: the first-collection proof): a helper waits here until the program releases it."
    print "      @[UnsafeReach(\"copy-only: the release word, set and read through its address\")]"
    print "      @@forced_ready : UInt64 = 0_u64"
    print "      @[UnsafeReach(\"copy-only: the first collection is waiting for helper readiness\")]"
    print "      @@forced_waiting : UInt64 = 0_u64"
    print ""
    print "      def self.release_ready : Nil"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_ready).address).value.set(1_u64)"
    print "      end"
    print ""
    print "      def self.forced_ready? : Bool"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_ready).address).value.get != 0_u64"
    print "      end"
    print "      def self.note_ready_wait : Nil"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_waiting).address).value.set(1_u64)"
    print "      end"
    print ""
    print "      def self.ready_waiting? : Bool"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_waiting).address).value.get != 0_u64"
    print "      end"
    print ""
    print ""
  }
  /^      def self\.helper_main\(seen : UInt64\) : Nil$/ { forced(); declared++ }
  declared == 1 && !hooked && /^        w = worker$/ {
    print
    print "        ready_limit = IyiMark.now_ns &+ 10000000000_u64"
    print "        while !IyiMark.forced_ready?"
    print "          if IyiMark.ready_waiting?"
    print "            __iyi_write(2, \"FAIL: crowded: the first collection waited for a held helper\\n\".to_unsafe.as(Void*), 61_u64)"
    print "            __iyi_exit(1)"
    print "          end"
    print "          if IyiMark.now_ns >= ready_limit"
    print "            message = \"FAIL: crowded: the helper was held past ten seconds\\n\""
    print "            __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
    print "            __iyi_exit(76)"
    print "          end"
    print "          IyiThread.park_if_requested"
    print "          spin_pause"
    print "        end"
    print "        pool_word(512_u64).value.add(1_u64)"
    hooked = 1; next }
  { print } END { if (declared != 1 || hooked != 1) exit 3 }' "$REPO/src/iyi/prelude.iyi" > held-helpers/iyi/prelude.iyi || { echo "the helper's entry this proof holds is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/held-helpers${PSEP}$REPO/src" "$IYI" build --release -Dready_force crowded.iyi -o crowded-held > build-held-helpers.log 2>&1; then
  cat build-held-helpers.log; exit 1
fi
timeout -k 5 120 ./crowded-held > crowded-held.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -q '^crowded: ' crowded-held.txt; then
  echo "the hook alone, helpers held until a collection returns, did not pass (exit $code):"; tail -3 crowded-held.txt; exit 1
fi
echo "  the hook alone, exits 0: $(grep -m1 '^crowded: ' crowded-held.txt)"
mkdir -p ready/iyi
cp held-helpers/iyi/*.iyi ready/iyi/
awk '/^          @@helpers = @@helpers \+ 1_u64$/ { made++; print; next }
  made == 1 && !waited && /^        end$/ { print; print "        ready_limit = IyiMark.now_ns &+ 10000000000_u64"; print "        while pool_word(512_u64).value.get < @@helpers"; print "          IyiMark.note_ready_wait"; print "          if IyiMark.now_ns >= ready_limit"; print "            message = \"FAIL: crowded: the readiness wait was held past ten seconds\\n\""; print "            __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"; print "            __iyi_exit(76)"; print "          end"; print "          spin_pause"; print "        end"; waited++; next }
  { print } END { if (made != 1 || waited != 1) exit 3 }' held-helpers/iyi/prelude.iyi > ready/iyi/prelude.iyi || { echo "the helpers' start this proof changes is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/ready${PSEP}$REPO/src" "$IYI" build --release -Dready_force crowded.iyi -o crowded-ready > build-ready.log 2>&1; then
  cat build-ready.log; exit 1
fi
timeout -k 5 120 ./crowded-ready > crowded-ready.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -Fxq 'FAIL: crowded: the first collection waited for a held helper' crowded-ready.txt; then
  echo "the first collection's wait was not caught (exit $code):"; tail -3 crowded-ready.txt; exit 1
fi
printf '  exits 1 at "%s"\n' 'FAIL: crowded: the first collection waited for a held helper'
# Four proofs follow, and they exist only where the code they prove does: the
# wake boost is set in thread.iyi's start_helper under win32, and the helper
# cap and the threads-minus-waiting count are in prelude.iyi's start_concurrent
# under win32. Off Windows those lines are not compiled, so these steps run on
# Windows alone, and this exit names them rather than passing silently.
if [ "$PSEP" = ":" ]; then
  echo "platform: the wake boost (thread.iyi start_helper), the helper cap and the thread counts (prelude.iyi start_concurrent) are compiled only for Windows; their four steps run there"
  echo "workdir $WORK"
  echo "concurrent mark: every step that exists on this platform held"
  exit 0
fi

step "failure proof: helpers created with Windows priority boost enabled are detected"
mkdir -p boosted/iyi
cp "$REPO"/src/iyi/*.iyi boosted/iyi/
awk '/^ *LibC\.SetThreadPriorityBoost\(h, 1_i32\)$/ { print "        # the helpers keep the boost"; found++; next } { print } END { if (found != 1) exit 3 }' \
  "$REPO/src/iyi/thread.iyi" > boosted/iyi/thread.iyi || { echo "the helper boost call is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/boosted${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o boosted-run > build-boosted.log 2>&1; then
  cat build-boosted.log; exit 1
fi
# The wake is one scheduling race per collection. Slow wakes over two
# hundred and fifty collections are printed as information, not a bound.
# On a machine with idle processors the race is the machine's to lose: a
# woken helper takes an idle processor and preempts nobody. On twelve
# processors the boosted build lost 0 to 3 wakes of 256 in five runs, and
# the gate's ten runs missed it at two and four workers (WinSoak's soak).
# So each run is held to two processors (`start /affinity 3`), with a
# process spinning beside it: the program's thread and the spinner hold
# both, and a boosted helper preempts one of them at every wake. Here,
# Windows 11 with 12 logical processors (the user's machine), five runs
# so: the boosted build lost 118 to 132 wakes of 256 in the four that
# started after the spinner (a fifth, its spinner a Python not yet
# running, lost none, which is why the spinner here says it is ready),
# and the shipped build 0 or 1 in each of five. The shipped build is run
# the same way first, and holds.
cat > spin.iyi <<'IYI'
module spin

import std/file::{File}

File.touch("spin-ready")
deadline = IyiMark.now_ns + 300000000000_u64
x = 0_i64
while !File.file?("spin-stop") && IyiMark.now_ns < deadline
  i = 0_i64
  while i < 1000000_i64
    x = x &+ i
    i = i + 1_i64
  end
end
puts "spun #{x}"
IYI
if ! "$IYI" build --release spin.iyi -o spin > build-spin.log 2>&1; then
  cat build-spin.log; exit 1
fi
# `./$1` held to two processors beside the spinner, its output in `$2`.
pinned_run() {
  rm -f spin-ready spin-stop
  MSYS_NO_PATHCONV=1 cmd /c start "" /b /affinity 3 spin.exe > spin.txt 2>&1
  for wait in $(seq 1 100); do [ -f spin-ready ] && break; sleep 0.1; done
  [ -f spin-ready ] || { echo "the spinner did not start"; exit 1; }
  MSYS_NO_PATHCONV=1 timeout -k 5 300 cmd /c start "" /b /wait /affinity 3 "$1.exe" pinned > "$2" 2>&1
  pinned_status=$?
  touch spin-stop
  sleep 1
  return "$pinned_status"
}
pinned_run marks pinned.txt
code=$?
if [ "$code" -ne 0 ] || ! grep -Fxq "concurrent mark: every property held" pinned.txt || ! grep -q "^wake: the program's thread woke the helpers" pinned.txt; then
  echo "the shipped build, held to two processors beside a spinner failed (exit $code):"; tail -3 pinned.txt; exit 1
fi
echo "  the shipped build, held to two processors beside a spinner: $(grep -m1 '^wake: the program' pinned.txt)"
# The decider is the structural check: a copy that drops the boost leaves the
# runtime's threads with it on, and the program fails by name on its one run,
# which the wake's timing cannot change. The pinned effect copy is never built:
# the structural check fails before the wake is reached, so it would only
# repeat the same run.
timeout -k 5 300 ./boosted-run > boosted.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q '^FAIL: wake boost: [0-9]* threads of this process have the priority boost off, the mark asked for [0-9]* helpers$' boosted.txt; then
  echo "the boost check did not fire (exit $code):"; tail -3 boosted.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: wake boost' boosted.txt)"

step "failure proof: a mark beside a busy program that asks for every helper is caught"
mkdir -p greedy/iyi
cp "$REPO"/src/iyi/*.iyi greedy/iyi/
awk '/^ *helpers = free if helpers > free$/ { found++; next } { print } END { if (found != 1) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > greedy/iyi/prelude.iyi || { echo "the cap this proof removes is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/greedy${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o greedy-run > build-greedy.log 2>&1; then
  cat build-greedy.log; exit 1
fi
timeout -k 5 300 ./greedy-run > greedy.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -Eq "^FAIL: share: with [0-9]+ threads of the program's on [0-9]+ cores, the mark beside them asked for [0-9]+ helpers rather than 1$" greedy.txt; then
  echo "the share check did not fire (exit $code):"; tail -3 greedy.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: share:' greedy.txt)"

# The pool's waiting workers counted as threads of the program's again,
# as they were: the idle pool's mark asks for one helper, and the idle
# pool check exits 1.
step "failure proof: a mark beside an idle pool that counts its waiting workers is caught"
mkdir -p counted/iyi
cp "$REPO"/src/iyi/*.iyi counted/iyi/
awk '/^ *threads = threads > waiting \? threads - waiting : 1_u64$/ { found++; next } { print } END { if (found != 1) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > counted/iyi/prelude.iyi || { echo "the line this proof removes is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/counted${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o counted-run > build-counted.log 2>&1; then
  cat build-counted.log; exit 1
fi
timeout -k 5 300 ./counted-run > counted.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -Eq "^FAIL: idle pool: with [0-9]+ threads of the program's on [0-9]+ cores, [0-9]+ of them pool workers waiting, the mark beside them asked for [0-9]+ helper$" counted.txt; then
  echo "the idle pool check did not fire (exit $code):"; tail -3 counted.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: idle pool:' counted.txt)"

# Every worker of a started pool counted free, running or not: the busy
# pool's mark asks for every helper, and the busy pool check exits 1.
step "failure proof: a mark beside a busy pool that counts its running workers free is caught"
mkdir -p pooled/iyi
cp "$REPO"/src/iyi/*.iyi pooled/iyi/
awk '/^ *waiting = IyiScheduler\.waiting_threads$/ { sub(/IyiScheduler\.waiting_threads/, "IyiWorkers.started? ? IyiWorkers.count.to_u64 : IyiScheduler.waiting_threads"); found++ } { print } END { if (found != 1) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > pooled/iyi/prelude.iyi || { echo "the line this proof changes is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/pooled${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o pooled-run > build-pooled.log 2>&1; then
  cat build-pooled.log; exit 1
fi
timeout -k 5 300 ./pooled-run > pooled.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -Eq "^FAIL: busy pool: with [0-9]+ pool workers running on [0-9]+ cores, [0-9]+ waiting, the mark beside them asked for [0-9]+ helpers rather than 1$" pooled.txt; then
  echo "the busy pool check did not fire (exit $code):"; tail -3 pooled.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: busy pool:' pooled.txt)"


echo "workdir $WORK"
echo "concurrent mark: every step held"
exit 0
