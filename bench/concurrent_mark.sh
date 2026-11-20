#!/usr/bin/env bash
# Drives bench/concurrent_mark.iyi: the mark beside the program, GC_DESIGN.md
# Stage 9, and the write barrier it stands on.
#
#     bash bench/concurrent_mark.sh
#
# The rules: every failure proof runs its broken copy once and passes only on
# its exact exit status and exact sentence. A forced copy waits on a word the
# program sets, never on a clock, and a copy that cannot build against the
# real runtime fails the gate. A step whose code this platform does not
# compile says so by name, and a host with too few cores fails. In the order
# they run:
#   - the program, release: rounds that move a payload into a black holder
#     under a running mark, the pauses of a concurrent collection against the
#     stop-the-world mark, a large block outgrown under a mark, a small live
#     set finished in its stop, a stray barrier, the share beside busy threads,
#     the wakes, and on Windows the priority boost counted over the process's
#     threads;
#   - the machine alone, and the first collections beside threads computing on
#     every core, held to four times the time with no helpers and 100 ms;
#   - buffers grown by realloc beside a mark, ten runs;
#   - small chunks freed in bursts across the pauses, ten runs, on every shape;
#   - chunks the last mark kept, freed beside a sweep that waits at each, ten
#     runs, and the armed look that holds the sweep at one kept chunk until the
#     program frees it;
#   - failure proofs: an unlocked free inside a sweep's look; a barrier that
#     shades nothing; a barrier run after its mark ended; a block outgrown under
#     a mark that the closer holds open; a small live set given the
#     thousand-object bound; the remainder round's count stored over the
#     assists counted in; helper 0 waiting past the next mark; a collection let
#     go after the release; the stopped, bounded and verb collections let go
#     late; a free outside the allocator's bracket; an idle pool whose workers
#     start late, and one whose workers are not called; a first collection
#     waiting for every helper to park;
#   - marks beside twenty-four connections on twelve workers, with every helper
#     and with one;
#   - on Windows only: the helpers woken with the boost (the boost counted and
#     the wake check); the helper cap beside a busy program; the pool's waiting
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

# The first collection beside threads of the program's that hold every
# core. It starts the helpers, and it waited for each to reach its park,
# which a new thread does only once the scheduler gives it a core: beside
# 24 threads computing on twelve cores, 300,000 small allocations on the
# main thread took 1.8 to 4.0 s, against 8 to 212 ms with no helpers. A
# helper is handed the generation it waits past now, and nothing waits for
# it to run: 11 to 77 ms. Three runs of each, the best of each compared;
# asserted on Windows, where it was measured, and printed everywhere.
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
# The best of three runs of `./$1 $2` in milliseconds, into `best`.
crowded_best() {
  best=""
  for try in 1 2 3; do
    timeout -k 5 120 "./$1" $2 > crowded.txt 2>&1 || { cat crowded.txt; exit 1; }
    ms="$(tr -d '\r' < crowded.txt | sed -n 's/^crowded: \([0-9]*\) ms, [1-9][0-9]* collections, .*$/\1/p')"
    beside="$(tr -d '\r' < crowded.txt | sed -n 's/^.* beside \([0-9]*\) threads.*$/\1/p')"
    [ -n "$ms" ] || { echo "no collection, or no answer:"; cat crowded.txt; exit 1; }
    if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then best="$ms"; fi
  done
}
step "the first collections beside threads computing on every core cost what they cost with no helpers"
crowded_best crowded alone
alone="$best"
crowded_best crowded helped
helped="$best"
bound=$((alone * 4 + 100))
if [ "$PSEP" != ":" ] && [ "$helped" -gt "$bound" ]; then
  echo "beside $beside threads computing, 300,000 allocations took $helped ms with helpers, past $bound: four times the $alone ms with none, and 100"
  exit 1
fi
echo "  beside $beside threads computing, held to four times the time with no helpers and 100 ms"

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
  # The copy's sweep answers the armed arena's first look with the kept chunk
  # it looks at, and holds that look until this program frees the chunk. Nothing
  # is allocated from the moment the concurrent mark starts until the look is
  # answered: a collection this program triggered in that window would wait for
  # the held sweep. A settle and an eager collection first leave no lazy sweep
  # of an older mark pending.
  forced_arena = IyiHeap.arena_of(aged[0].address)
  IyiMark.settle
  IyiMark.collect
  IyiHeap.arm_look(forced_arena)
  forced_limit = IyiMark.now_ns + 5000000000_u64
  while !IyiMark.marking? && IyiMark.now_ns < forced_limit
    block = Pointer(UInt8).malloc(64_u64)
    block.value = 1_u8
  end
  if !IyiMark.marking?
    print "FAIL: freed: no concurrent mark started within five seconds\n"
    __iyi_exit(1)
  end
  while IyiHeap.forced_look == 0_u64 && IyiMark.now_ns < forced_limit
    IyiThread.spin_pause
  end
  if IyiHeap.forced_look == 0_u64
    print "FAIL: freed: no sweep looked at a chunk the last mark kept within five seconds\n"
    __iyi_exit(1)
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
# Not on darwin: its three-core runner ended a run with no line printed,
# inside the 120 s bound or past it, and what stops a thread there is a
# signal at a safe point rather than a suspend at any instruction.
if [ "$(uname -s)" = "Darwin" ]; then
  echo "  the bursts of frees are measured on Windows and Linux; darwin's runner is not one of them"
else
for run in 1 2 3 4 5 6 7 8 9 10; do
  timeout -k 5 120 ./freed > freed.txt 2>&1
  code=$?
  if [ "$code" -ne 0 ] || ! grep -qx "lost 0" freed.txt; then
    echo "  run $run of 10 lost a chunk kept beside chunks freed (exit $code):"; tail -3 freed.txt; exit 1
  fi
done
echo "  ten runs of 200,000 bursts of frees, every kept chunk intact"
fi

# A chunk the last mark kept, freed before the lazy sweep of its arena
# reached it - the aged chunks above. A slice walking past it reads its
# entry, then its colour, and writes the entry back: freed between the two
# reads it read as allocated before the mark and white, dead, and the
# slice linked it into its batch while it sat on the freeing thread's
# list; freed between the read and the write it lost its free flag. Such a
# free now waits for the slice. On four cores beside two busy loops the
# old free faulted step 5's program in 4 runs of 1,000, plain, and 108 of
# 1,000 release: ten runs are no proof. So a copy of the prelude widens
# the window: a slice that meets a chunk of a kilobyte or more the last
# mark kept waits up to 100 us for its entry to change, and says so and
# exits 1 if it does. The aged chunks are freed all at once as soon as a
# slice of their arena is in flight, while it waits at one of them. With
# the old free that copy exited 1 by name in 200 runs of 200, plain and
# release alike, and with the lock in 0 of 1,000 of each. Small classes
# are left alone: a slice meets thousands of kept chunks there, and a
# wait at each stalls the sweep.
step "chunks the last mark kept, freed beside a sweep that waits at each, ten runs"
mkdir -p widened/iyi
cp "$REPO"/src/iyi/*.iyi widened/iyi/
# The sweep's look at a kept chunk of a kilobyte or more. Unarmed (the plain
# runs), the look waits 100 us for the entry to change. Armed by the program
# (`IyiHeap.arm_look`, on the aged chunks' arena), the first such look publishes
# its chunk and holds it by words until the program's free of that chunk
# announces itself on the slice's claim (`note_free_waiting`, at the top of
# free_unswept), or the entry changes. Five seconds without either is named.
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
  /^      def self\.free\(pointer : Void\*\) : Nil$/ { forced(); declared = 1 }
  /^      def self\.free_unswept\(/ { print; print "        note_free_waiting(head)"; noted = 1; next }
  /^          word = IyiHeap\.read8\(byte\)$/ { print
    print "          if chunk >= 1024_u64 && word & IyiHeap::EPOCH_FLAG != epoch && word & IyiHeap::FREE_FLAG == 0 && IyiHeap.read8(mark) != WHITE"
    print "            if IyiHeap.look_armed_in?(arena) && IyiHeap.forced_look == 0_u64"
    print "              IyiHeap.publish_look(cursor)"
    print "              look_limit = IyiMark.now_ns &+ 5000000000_u64"
    print "              while IyiHeap.read8(byte) == word && IyiHeap.forced_waiting != cursor && IyiMark.now_ns < look_limit"
    print "                spin_pause"
    print "              end"
    print "              if IyiHeap.read8(byte) == word && IyiHeap.forced_waiting != cursor"
    print "                __iyi_write(2, \"freed: the sweep held a chunk the last mark kept for five seconds, and no free came\\n\".to_unsafe.as(Void*), 84_u64)"
    print "                __iyi_exit(1)"
    print "              end"
    print "            else"
    print "              window_end = IyiMark.now_ns &+ 100000_u64"
    print "              while IyiHeap.read8(byte) == word && IyiMark.now_ns < window_end"
    print "                spin_pause"
    print "              end"
    print "            end"
    print "            if IyiHeap.read8(byte) != word"
    print "              __iyi_write(2, \"freed: a chunk the last mark kept was freed while the sweep looked at it\\n\".to_unsafe.as(Void*), 73_u64)"
    print "              __iyi_exit(1)"
    print "            end"
    print "          end"
    found++; next }
  { print } END { if (declared != 1 || noted != 1 || found != 1) exit 3 }' "$REPO/src/iyi/prelude.iyi" > widened/iyi/prelude.iyi || { echo "the sweep's look or the free this step arms is missing or ambiguous"; exit 1; }
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

step "failure proof: a barrier that shades nothing loses the moved payload"
mkdir -p patched/iyi
cp "$REPO"/src/iyi/*.iyi patched/iyi/
awk '{ if (sub(/return unless Pointer\(Atomic\(UInt8\)\)\.new\(mark\)\.value\.compare_and_set\(WHITE\.unsafe_to_u8, GRAY\.unsafe_to_u8\)\[1\]/, "return # the barrier shades nothing")) found = 1; print } END { if (!found) exit 3 }' "$REPO/src/iyi/prelude.iyi" > patched/iyi/prelude.iyi || { echo "the barrier's shading this proof removes is not in the prelude any more"; exit 1; }
cmp -s patched/iyi/prelude.iyi "$REPO/src/iyi/prelude.iyi" && { echo "the awk found nothing to change"; exit 1; }
if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o nobarrier > build-nobarrier.log 2>&1; then
  cat build-nobarrier.log; exit 1
fi
timeout -k 5 300 ./nobarrier > nobarrier.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "the barrier lost it" nobarrier.txt; then
  echo "the payload check did not fire (exit $code):"; tail -3 nobarrier.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 'the barrier lost it' nobarrier.txt)"

step "failure proof: a barrier that shades after its mark ended loses what the holder held"
mkdir -p stray/iyi
cp "$REPO"/src/iyi/*.iyi stray/iyi/
awk '{ if ($0 ~ /^        return if LibIyiGCTable\.__iyi_marking == 0_u8$/ && prev ~ /def self\.barrier\(/) { prev = $0; next } prev = $0; print }' "$REPO/src/iyi/prelude.iyi" > stray/iyi/prelude.iyi
cmp -s stray/iyi/prelude.iyi "$REPO/src/iyi/prelude.iyi" && { echo "the awk found nothing to change"; exit 1; }
if ! IYI_PATH="$WORK/stray${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o straybarrier > build-stray.log 2>&1; then
  cat build-stray.log; exit 1
fi
timeout -k 5 300 ./straybarrier > stray.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "stray: a barrier run after its mark" stray.txt; then
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
# in place the block stays mapped, and the held rounds say so.
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
  /^      def self\.helper_main\(seen : UInt64\) : Nil$/ { forced(); declared = 1 }
  /^              seen = finish_concurrent$/ {
    print "              while IyiMark.forced_hold?"
    print "                IyiThread.park_if_requested"
    print "                spin_pause"
    print "              end"
    hooked = 1 }
  { print } END { if (!declared || !hooked) exit 3 }' "$REPO/src/iyi/prelude.iyi" > held/iyi/prelude.iyi || { echo "the closer's finish or helper_main is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/held${PSEP}$REPO/src" "$IYI" build --release -Dunmapped_force "$REPO/bench/concurrent_mark.iyi" -o held-run > build-held.log 2>&1; then
  cat build-held.log; exit 1
fi
timeout -k 5 300 ./held-run > held.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -q "^large: 2 of 2 blocks outgrown under a running mark stayed mapped beside the helpers, and [0-2] were freed after$" held.txt; then
  echo "the held rounds did not keep the block mapped (exit $code):"; tail -3 held.txt; exit 1
fi
echo "  the hook alone, exits 0: $(grep -m1 '^large: 2 of 2' held.txt)"
mkdir -p unmapped/iyi
cp held/iyi/*.iyi unmapped/iyi/
awk '{ if (sub(/free_large\(pointer\.address - HEADER\) if LibIyiGCTable\.__iyi_marking == 0_u8/, "free_large(pointer.address - HEADER)")) found = 1; print } END { if (!found) exit 3 }' \
  held/iyi/prelude.iyi > unmapped/iyi/prelude.iyi || { echo "the look at the mark this proof removes is not in the prelude any more"; exit 1; }
cmp -s unmapped/iyi/prelude.iyi held/iyi/prelude.iyi && { echo "the awk found nothing to change"; exit 1; }
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
awk '{ if (sub(/drain_bounded\(w, IyiStat\.get\(IyiStat::KEPT\) < STW_MARK_SMALL \? STW_MARK_SMALL : STW_MARK_BOUND\)/, "drain_bounded(w, STW_MARK_BOUND)")) found = 1; print } END { if (!found) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > thousand/iyi/prelude.iyi || { echo "the bound this proof replaces is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/thousand${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o thousand-run > build-thousand.log 2>&1; then
  cat build-thousand.log; exit 1
fi
timeout -k 5 300 ./thousand-run > thousand.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "^FAIL: small:" thousand.txt; then
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
# twelve workers on master, 1,588 second stops retreated, none stalled -
# so each proof below widens its window.
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

# The store put back where the remainder round counts helper 0 in, and a
# window before it, held open until an assist has counted itself in - a
# second at most - in which every assist that begins is held until the
# store has landed: the window Windows' release leaves open while the
# threads it resumed first allocate, made certain. And every second stop
# retreats once, so that round runs at every collection. Both were left
# to the machine before: a window of 200 us, and no forced retreat, and
# on four-core Windows and three-core darwin runners the program
# retreated 0 or 1 times in ten seconds and that copy exited 0. The
# count goes below zero at the first collection's remainder round, and
# `count_out` says so: 12 runs of 12 here held to three, four and twelve
# cores, each ended inside 110 ms.
step "failure proof: the remainder round's count stored over the assists counted in"
mkdir -p stored/iyi
cp "$REPO"/src/iyi/*.iyi stored/iyi/
awk '/^          pool_word\(POOL_ACTIVE\)\.value\.add\(1_u64\)$/ {
    print "          pool_word(1408_u64).value.set(0_u64)"
    print "          pool_word(1344_u64).value.set(1_u64)"
    print "          window = now_ns + 1000000000_u64"
    print "          while pool_word(1408_u64).value.get == 0_u64 && now_ns < window"
    print "            spin_pause"
    print "          end"
    print "          pool_word(POOL_ACTIVE).value.set(1_u64)"
    print "          pool_word(1344_u64).value.set(0_u64)"
    stored = 1; next }
  /^        active\.value\.add\(1_u64\)$/ {
    print
    print "        if pool_word(1344_u64).value.get != 0_u64"
    print "          pool_word(1408_u64).value.set(1_u64)"
    print "          while pool_word(1344_u64).value.get != 0_u64"
    print "            spin_pause"
    print "          end"
    print "        end"
    held = 1; next }
  /^            if attempts < FINISH_RETRIES && unfinished$/ {
    print "            if attempts < FINISH_RETRIES && (unfinished || attempts == 0_u64)"
    forced = 1; next }
  { print } END { if (!stored || !held || !forced) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > stored/iyi/prelude.iyi || { echo "the count this proof stores, or the assist it holds, is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/stored${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/mark_stall.iyi" -o stored-run > build-stored.log 2>&1; then
  cat build-stored.log; exit 1
fi
timeout -k 5 120 ./stored-run workers=12 seconds=10 > stored.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "count of workers marking went below zero" stored.txt; then
  echo "the stored count was not caught (exit $code):"; tail -3 stored.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 'went below zero' stored.txt | cut -c1-150)"

# Helper 0 reading the generation it waits past after `@@collecting`
# falls, and held there until another thread's mark turns it, ten seconds
# at most: helper 0 then waits past that mark, and with no other helper
# nobody takes its permit. The collection stands still and the tasks
# allocate; the runtime's overdue report, its bound cut to 20 ms here,
# names the mark while they do, and the watchdog holds them at 512 MiB and
# fails the run two seconds later - 12 runs of 12 here held to three,
# four and twelve cores, each at the second collection, the reports at 20
# to 22, 40 to 46 and 81 to 93 ms and in one run 182. The hold was 50 ms
# at most, and on a four-core Windows runner no mark began inside it at
# any of one run's 13 collections, the tasks held by the watchdog at 11 of
# them, and the copy exited 0 (job 122392781393).
step "failure proof: helper 0 waiting past the next mark leaves it to nobody"
mkdir -p late/iyi
cp "$REPO"/src/iyi/*.iyi late/iyi/
awk '/^            generation = pool_word\(POOL_GENERATION\)\.value\.get$/ { early = 1; next }
  /^            return generation$/ {
    print "            held = pool_word(POOL_GENERATION).value.get"
    print "            until_ns = now_ns + 10000000000_u64"
    print "            while pool_word(POOL_GENERATION).value.get == held && now_ns < until_ns"
    print "              spin_pause"
    print "            end"
    print "            return pool_word(POOL_GENERATION).value.get"
    late = 1; next }
  /^      MARK_OVERDUE_NS = 10000000000_u64$/ { print "      MARK_OVERDUE_NS = 20000000_u64"; due = 1; next }
  { print } END { if (!early || !late || !due) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > late/iyi/prelude.iyi || { echo "the generation read or the overdue bound this proof moves is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/late${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/mark_stall.iyi" -o late-run > build-late.log 2>&1; then
  cat build-late.log; exit 1
fi
timeout -k 5 120 ./late-run workers=12 seconds=10 helpers=1 stall_mib=512 stall_ms=2000 > late.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "^FAIL: stall:" late.txt; then
  echo "the watchdog did not catch the mark nobody drained (exit $code):"; tail -3 late.txt; exit 1
fi
if ! grep -q "the collector's mark has run .* permits left 1 and taken 0" late.txt; then
  echo "the runtime did not say the mark nobody drained was overdue:"; tail -3 late.txt; exit 1
fi
printf '  says "%s"\n' "$(grep -m1 "the collector's mark has run" late.txt | cut -c1-150)"
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: stall:' late.txt | cut -c1-150)"

# `@@collecting` let go after helper 0 releases the threads, as it was,
# and helper 0 held ten seconds before it lets it go: the window a
# four-core Windows runner gave twelve and eight workers whenever they
# took helper 0's cores, held past the watchdog's whole course - its hold
# at 256 MiB or two seconds after the last collection, and its two
# seconds' wait after. The tasks allocate with no mark to assist and no
# trigger to cross, and while the flag is up `pressure` turns every slice
# away, so nothing the held tasks still allocate triggers the next: the
# run fails, naming the count since the last collection against its
# budget. The hold is after helper 0's unlock, the flag's fall moved
# there with it: held under the lock, the tasks waited for helper 0
# wherever they needed the lock, and on master merged with #150 and #151
# the copy exited 0 in 34 runs of 36. Here it fails at the first
# collection, 36 runs of 36 held to three, four and twelve cores, and the
# runtime as it is passes the same run 36 of 36. Two holds were left to
# the machine before. 300 ms caught it only where the tasks allocated
# 256 MiB inside it: four-core Windows runners held them at 287 and 289
# MiB (jobs 122392780789 and 122392781553). And a hold until nothing was
# counted for half a second let the flag fall while the held tasks still
# allocated - a cache folds its allocation into the count a 64 KiB slice
# at a time - and a slice then crossed the budget and collected: on the
# same merge 2 runs of 12 on twelve cores exited 0, the tasks held 554 ms
# at the longest.
step "failure proof: a collection let go after its threads are released leaves their allocation untriggered"
mkdir -p released/iyi
cp "$REPO"/src/iyi/*.iyi released/iyi/
awk '/^            @@collecting = false$/ && !moved { moved = 1; next }
  moved && !put && /^            unlock_released$/ {
    print
    print "            window = now_ns + 10000000000_u64"
    print "            while now_ns < window"
    print "              spin_pause"
    print "            end"
    print "            @@collecting = false"
    put = 1; next }
  { print } END { if (!moved || !put) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > released/iyi/prelude.iyi || { echo "the order this proof undoes is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/released${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/mark_stall.iyi" -o released-run > build-released.log 2>&1; then
  cat build-released.log; exit 1
fi
timeout -k 5 120 ./released-run workers=12 seconds=10 stall_ms=2000 > released.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "^FAIL: stall:.*marking false" released.txt; then
  echo "the untriggered allocation was not caught (exit $code):"; tail -3 released.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: stall:' released.txt | cut -c1-150)"

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

# `@@collecting` let go after the release again, in one of the two places
# that let it go, and the thread that ran the collection held a second
# between the two: the second thread's slices are turned away, it
# triggers nothing and does nothing more, and the rounds that end there
# fail by name - `collect_locked`'s the stopped round and the verb's, and
# `finish_stopped`'s the bounded one; 12 runs of 12 each here held to
# three, four and twelve cores, and the runtime as it is 12 of 12 clean.
let_go_late() {
  name=$1 indent=$2
  shift 2
  mkdir -p "$name/iyi"
  cp "$REPO"/src/iyi/*.iyi "$name/iyi/"
  awk -v n="$indent" 'BEGIN { while (length(pad) < n) pad = pad " " }
    $0 == (pad "@@collecting = false") && !moved { held = 1; next }
    held && /^          IyiThread\.resume_others\(others\)$/ {
      print
      print "          window = now_ns + 1000000000_u64"
      print "          while now_ns < window"
      print "            spin_pause"
      print "          end"
      print "          @@collecting = false"
      held = 0; moved = 1; next }
    { print } END { if (!moved) exit 3 }' \
    "$REPO/src/iyi/prelude.iyi" > "$name/iyi/prelude.iyi" || { echo "the order the $name proof undoes is not in the prelude any more"; exit 1; }
  if ! IYI_PATH="$WORK/$name${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/release_trigger.iyi" -o "$name-run" > "build-$name.log" 2>&1; then
    cat "build-$name.log"; exit 1
  fi
  timeout -k 5 60 "./$name-run" > "$name.txt" 2>&1
  code=$?
  if [ "$code" -ne 1 ]; then
    echo "the untriggered slices were not caught (exit $code):"; cat "$name.txt"; exit 1
  fi
  for round in "$@"; do
    if ! grep -q "^FAIL: $round: after collection" "$name.txt"; then
      echo "the $round round did not fail:"; cat "$name.txt"; exit 1
    fi
    printf '  exits 1 at "%s"\n' "$(grep -m1 "^FAIL: $round:" "$name.txt" | cut -c1-150)"
  done
}

step "failure proof: a stopped collection let go after its threads are released leaves their slices untriggered"
let_go_late locked-late 8 stopped verb

step "failure proof: a collection that ends in its first stop let go after its threads are released leaves their slices untriggered"
if grep -q '^one core:' trigger-1.txt; then
  echo "  not run: one core, no helper, and no mark that ends in its first stop"
else
  let_go_late bounded-late 10 bounded
fi

# The free's bracket, and the list it guards. A free links the chunk onto its
# cache's list, and a pause drops every cache's list: a link to a list read
# before a collection and written after it puts back what the collection
# dropped, and the chunks it links are the ones its sweep had already put on
# the centre. A collection inside the free is what the bracket keeps from
# happening (the stop waits for a free inside the bracket), so the copy with
# the bracket removed runs one there, at the one free the program arms. The
# control keeps the bracket and the link, and no collection. Single thread:
# a deterministic sequence, not a timing race.
step "failure proof: a free outside the allocator's bracket puts a dropped list back"
mkdir -p bracketed/iyi
cp "$REPO"/src/iyi/*.iyi bracketed/iyi/
cat > unbracketed.iyi <<'IYI'
@[Unsafe("frees raw 16-byte chunks with GC.free and allocates them with Pointer#malloc, reading the words it wrote into each to see whether two live chunks share one")]
module unbracketed

import std/gc::{GC}

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
# The first free puts a chunk on this thread's cache list, and the second is
# the one the program arms: its link reads that list, and a collection inside
# the free (copy only) drops it.
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
    print "      # Copy only (concurrent_mark bracket proof): the one-shot word the program arms before its free."
    print "      @[UnsafeReach(\"copy-only: the one-shot word, set and read through its address\")]"
    print "      @@drop_armed : UInt64 = 0_u64"
    print "      @[UnsafeReach(\"copy-only: the number of forced collections completed\")]"
    print "      @@drop_done : UInt64 = 0_u64"
    print ""
    print "      def self.arm_drop : Nil"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@drop_armed).address).value.set(1_u64)"
    print "      end"
    print ""
    print "      def self.take_drop : Bool"
    print "        armed = Pointer(Atomic(UInt64)).new(pointerof(@@drop_armed).address).value.get != 0_u64"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@drop_armed).address).value.set(0_u64) if armed"
    print "        armed"
    print "      end"
    print "      def self.drop_done : UInt64"
    print "        Pointer(Atomic(UInt64)).new(pointerof(@@drop_done).address).value.get"
    print "      end"
    print ""
    print "      def self.force_drop : Nil"
    print "        if take_drop"
    print "          IyiMark.collect"
    print "          Pointer(Atomic(UInt64)).new(pointerof(@@drop_done).address).value.add(1_u64)"
    print "        end"
    print "      end"
    print ""
    print ""
  }
  /^      def self\.free\(pointer : Void\*\) : Nil$/ { forced(); declared++ }
  /^          leave\(table\)$/ { print; print "          IyiHeap.force_drop"; left++; next }
  /^        write64\(head \+ OFF_LINK, table\[index\]\)$/ { print "        stale = table[index]"; print "        write64(head + OFF_LINK, stale)"; linked++; next }
  { print } END { if (declared != 1 || linked != 1 || left != 1) exit 3 }' "$REPO/src/iyi/prelude.iyi" > bracketed/iyi/prelude.iyi || { echo "the list link, bracket leave or free this proof changes is missing or ambiguous"; exit 1; }
if ! IYI_PATH="$WORK/bracketed${PSEP}$REPO/src" "$IYI" build unbracketed.iyi -Dunbracketed_force -o bracketed-run > build-bracketed.log 2>&1; then
  cat build-bracketed.log; exit 1
fi
timeout -k 5 120 ./bracketed-run > bracketed.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -Fxq 'unbracketed: 64 chunks handed out, none shared, the 62 kept ones whole' bracketed.txt; then
  echo "the control, collection after the bracket, did not pass (exit $code):"; tail -3 bracketed.txt; exit 1
fi
echo "  the control, collection after the bracket, exits 0: $(grep -Fx 'unbracketed: 64 chunks handed out, none shared, the 62 kept ones whole' bracketed.txt)"
mkdir -p unbracketed/iyi
cp bracketed/iyi/*.iyi unbracketed/iyi/
awk '/^        stale = table\[index\]$/ { print; print "        IyiHeap.force_drop"; hooked++; next }
  { print } END { if (hooked != 1) exit 3 }' bracketed/iyi/prelude.iyi > unbracketed/iyi/prelude.iyi || { echo "the link this proof collects inside is missing or ambiguous"; exit 1; }
awk '/^          write64\(table\.address &\+ CACHE_INSIDE, read64\(table\.address &\+ CACHE_INSIDE\) &\+ 1_u64\)$/ { entered++; next }
  prev ~ /^          end$/ && /^          leave\(table\)$/ { left++; prev = $0; next }
  { prev = $0; print } END { if (entered != 1 || left != 1) exit 3 }' unbracketed/iyi/prelude.iyi > unbracketed/iyi/prelude.iyi.new || { echo "the bracket this proof removes from free is missing or ambiguous"; exit 1; }
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

# The idle pool's step fills the pool before it asks anything of it, and
# the pool grows one worker at a time, each started by the last to find a
# task (`IyiWorkers.grow`). On Windows 11 with 12 logical processors (the
# user's machine) a start took about a millisecond, and the twelve spinning
# tasks could all arrive time-sliced on fewer threads, each preempted in
# its 5 to 10 ms quantum, and end with 7 to 11 workers launched: "11 of 12
# workers waiting" in 13 of 60 runs. Held open here: a copy of the runtime
# in which every worker's thread waits 50 ms before its first look, so the
# pool takes 50 ms a worker to fill and the tasks have all arrived on the
# first long before. The step holds on that copy - its tasks spin until the
# pool has launched every worker - and the step as it was, its tasks
# spinning only until all have arrived and nothing counting the workers
# launched after them, exits 1 on it at the count of workers waiting. The
# program runs that step on three cores or more, which step 1's answers
# say.
if ! grep -q '^idle pool: with' answers.txt; then
  echo "  the idle pool step needs three cores, and step 1 did not run it here: its late-start and uncalled-worker proofs are unmeasured"
else
step "the idle pool fills on a runtime whose workers each start 50 ms late"
mkdir -p latestart/iyi
cp "$REPO"/src/iyi/*.iyi latestart/iyi/
awk '/^  def self\.work : Nil$/ { print; getline; print
    print "      late = __iyi_monotonic_ns + 50000000_i64"
    print "      while __iyi_monotonic_ns < late"
    print "        IyiThread.spin_pause"
    print "      end"
    found = 1; next }
  { print } END { if (!found) exit 3 }' \
  "$REPO/src/iyi/concurrency.iyi" > latestart/iyi/concurrency.iyi || { echo "the worker's start this step delays is not in the runtime any more"; exit 1; }
if ! IYI_PATH="$WORK/latestart${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o latestart-run > build-latestart.log 2>&1; then
  cat build-latestart.log; exit 1
fi
timeout -k 5 300 ./latestart-run > latestart.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -q "^idle pool: with" latestart.txt; then
  echo "the idle pool step did not hold on the late-start runtime (exit $code):"; tail -3 latestart.txt; exit 1
fi
echo "  $(grep -m1 '^idle pool: with' latestart.txt)"

step "failure proof: an idle pool step whose tasks wait only for each other is caught on that runtime"
awk '$0 == "          while (Busy.arrived.value.get < cores || IyiWorkers.launched < cores.to_i32) && IyiMark.now_ns < until_ns" {
    print "          while Busy.arrived.value.get < cores && IyiMark.now_ns < until_ns"; found++; next }
  $0 == "    launched = IyiWorkers.launched" || /^    fail\("idle pool: the pool launched .*\) if launched < cores\.to_i32$/ { found++; next }
  { print } END { if (found != 3) exit 3 }' \
  "$REPO/bench/concurrent_mark.iyi" > arrived_only.iyi || { echo "the wait this proof shortens, or the count of workers launched it removes, is not in bench/concurrent_mark.iyi any more"; exit 1; }
if ! IYI_PATH="$WORK/latestart${PSEP}$REPO/src" "$IYI" build --release arrived_only.iyi -o arrived-only > build-arrived.log 2>&1; then
  cat build-arrived.log; exit 1
fi
timeout -k 5 300 ./arrived-only > arrived.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "^FAIL: idle pool: [0-9]* of [0-9]* workers waiting" arrived.txt; then
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
# (`IyiWorkers.turn_wanted?`). The lost call is a race the machine decides:
# without that start, a copy whose every give-up spun 3 ms between its take
# and its queue stopped the pool short in 9 of 12 runs beside 24 busy loops
# on Linux (12 vCPU), and in none of 30 on the idle machine, where the pool
# has grown before the first turn. So it is made certain here: a copy of
# the runtime in which no find calls the next worker, and the turns alone
# grow the pool. The step holds on that copy; with the turns' start taken
# out of it too, the pool keeps the workers the spawns started, and the
# step exits 1 naming them. On Linux (12 vCPU), on all twelve, four and
# three of its cores, that copy held 30 runs of 30 and the one without the
# start was caught in 30 of 30, at one or two workers launched.
step "the idle pool fills on a runtime in which no worker's find calls the next"
mkdir -p uncalled/iyi
cp "$REPO"/src/iyi/*.iyi uncalled/iyi/
awk '$0 == "    wake_one if found && work_waiting?" { found = 1; next }
  { print } END { if (!found) exit 3 }' \
  "$REPO/src/iyi/concurrency.iyi" > uncalled/iyi/concurrency.iyi || { echo "the call for the next worker this step removes is not in the runtime any more"; exit 1; }
if ! IYI_PATH="$WORK/uncalled${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o uncalled-run > build-uncalled.log 2>&1; then
  cat build-uncalled.log; exit 1
fi
timeout -k 5 300 ./uncalled-run > uncalled.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! grep -q "^idle pool: with" uncalled.txt; then
  echo "the idle pool step did not hold on the runtime whose finds call nobody (exit $code):"; tail -3 uncalled.txt; exit 1
fi
echo "  $(grep -m1 '^idle pool: with' uncalled.txt)"

step "failure proof: turns taken while a task waits and none is idle that start no worker are caught on that runtime"
mkdir -p unstarted/iyi
cp uncalled/iyi/*.iyi unstarted/iyi/
awk 'prev == "    return false unless work_waiting?" && $0 == "    wake_one" { found = 1; prev = $0; next }
  { prev = $0; print } END { if (!found) exit 3 }' \
  uncalled/iyi/concurrency.iyi > unstarted/iyi/concurrency.iyi || { echo "the turn's start this proof removes is not in the runtime any more"; exit 1; }
if ! IYI_PATH="$WORK/unstarted${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o unstarted-run > build-unstarted.log 2>&1; then
  cat build-unstarted.log; exit 1
fi
timeout -k 5 300 ./unstarted-run > unstarted.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "^FAIL: idle pool: the pool launched" unstarted.txt; then
  echo "the idle pool's count of workers launched did not fire (exit $code):"; tail -3 unstarted.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: idle pool:' unstarted.txt)"
fi

# The first collection's wait for every helper to reach its park, put back.
# Each helper makes its count on entry, and the helpers' start waits for every
# count. Forced: the copy holds each helper before its count until the program
# releases them, and the program releases them only once a collection has
# returned. With the wait put back the first collection then never returns and
# the program's watcher fails by name. The hook alone (the count, no wait)
# lets the first collection return, and the program passes.
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
    print "        while !IyiMark.forced_ready?"
    print "          if IyiMark.ready_waiting?"
    print "            __iyi_write(2, \"FAIL: crowded: the first collection waited for a held helper\\n\".to_unsafe.as(Void*), 61_u64)"
    print "            __iyi_exit(1)"
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
  made == 1 && !waited && /^        end$/ { print; print "        while pool_word(512_u64).value.get < @@helpers"; print "          IyiMark.note_ready_wait"; print "          spin_pause"; print "        end"; waited++; next }
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
# The wake is one scheduling race per collection, and the check counts
# the races lost over two hundred and fifty: on a four-core runner the
# boosted build lost 5 to 88 in each of 40 runs, where the check allows 3.
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
# which the wake's timing cannot change. The pinned effect copy is not run:
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
awk '/^ *helpers = free if helpers > free$/ { found = 1; next } { print } END { if (!found) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > greedy/iyi/prelude.iyi || { echo "the cap this proof removes is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/greedy${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o greedy-run > build-greedy.log 2>&1; then
  cat build-greedy.log; exit 1
fi
timeout -k 5 300 ./greedy-run > greedy.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "^FAIL: share:" greedy.txt; then
  echo "the share check did not fire (exit $code):"; tail -3 greedy.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: share:' greedy.txt)"

# The pool's waiting workers counted as threads of the program's again,
# as they were: the idle pool's mark asks for one helper, and the idle
# pool check exits 1.
step "failure proof: a mark beside an idle pool that counts its waiting workers is caught"
mkdir -p counted/iyi
cp "$REPO"/src/iyi/*.iyi counted/iyi/
awk '/^ *threads = threads > waiting \? threads - waiting : 1_u64$/ { found = 1; next } { print } END { if (!found) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > counted/iyi/prelude.iyi || { echo "the line this proof removes is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/counted${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o counted-run > build-counted.log 2>&1; then
  cat build-counted.log; exit 1
fi
timeout -k 5 300 ./counted-run > counted.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "^FAIL: idle pool:" counted.txt; then
  echo "the idle pool check did not fire (exit $code):"; tail -3 counted.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: idle pool:' counted.txt)"

# Every worker of a started pool counted free, running or not: the busy
# pool's mark asks for every helper, and the busy pool check exits 1.
step "failure proof: a mark beside a busy pool that counts its running workers free is caught"
mkdir -p pooled/iyi
cp "$REPO"/src/iyi/*.iyi pooled/iyi/
awk '/^ *waiting = IyiScheduler\.waiting_threads$/ { sub(/IyiScheduler\.waiting_threads/, "IyiWorkers.started? ? IyiWorkers.count.to_u64 : IyiScheduler.waiting_threads"); found = 1 } { print } END { if (!found) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > pooled/iyi/prelude.iyi || { echo "the line this proof changes is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/pooled${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o pooled-run > build-pooled.log 2>&1; then
  cat build-pooled.log; exit 1
fi
timeout -k 5 300 ./pooled-run > pooled.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "^FAIL: busy pool:" pooled.txt; then
  echo "the busy pool check did not fire (exit $code):"; tail -3 pooled.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: busy pool:' pooled.txt)"


echo "workdir $WORK"
echo "concurrent mark: every step held"
exit 0
