#!/usr/bin/env bash
# Drives bench/concurrent_mark.iyi: the mark beside the program, GC_DESIGN.md
# Stage 9, and the write barrier it stands on.
#
#     bash bench/concurrent_mark.sh
#
# Twelve steps, the last seven failure proofs:
#   1. The program holds, release: twenty-four rounds or more each move a
#      payload out of an unmarked chain into an already-marked holder, at
#      least one of them under a running mark, and every payload is intact
#      after the collection; and large blocks outgrown by `realloc` under
#      a running mark stay mapped beside the helpers, and are freed after.
#   2. The pauses, printed: the stop-the-world mark over the same chain
#      against a concurrent collection's two stops, and the longest the
#      program's thread spent waking the helpers, which on Windows is
#      held under 1 ms; and how many helpers a mark beside a thread on
#      every core but one asked for, which on Windows is held to one.
#   3. The machine alone, printed: one thread per core reading the clock
#      and nothing else, and the longest gap any of them saw. A pause is
#      only the runtime's where the machine gives its threads their cores:
#      on a twelve-core Windows VM this read 23 to 64 ms, the length of
#      the longest second stops measured there. And the first collections
#      beside twice the cores' threads computing: on Windows, the main
#      thread's allocations take no more than four times what they take
#      with no helpers, and 100 ms.
#   4. Buffers of references grown by `realloc`, ten runs of three hundred
#      rounds, plain: every referent intact in every run. The old buffer
#      is freed while a mark may have it queued.
#   5. Small chunks handed back by `GC.free` in bursts, ten runs, plain:
#      every chunk kept since is intact, the pauses landing among the
#      frees included.
#   6. Failure proof: the barrier's shade removed from a copy of the
#      prelude; the first payload moved under a mark is freed, and the
#      program exits 1 saying so.
#   7. Failure proof: the barrier's own look at the marking flag removed;
#      a barrier run after its mark ended grays a holder, the next mark
#      sweeps the payload it held, and the program exits 1 saying so.
#   8. Failure proof: `free`'s look at the mark removed; a large block
#      outgrown under a mark is unmapped beside the helpers at once, which
#      is how a helper walking the large list faulted, and the program
#      exits 1 saying so.
#   9. Failure proof: `free` outside the allocator's bracket; a pause
#      among the frees puts the lists it dropped back on the cache, and
#      step 5's program exits 1 within ten runs.
#  10. Failure proof, on Windows: the helpers given back the boost a
#      satisfied wait brings, and the wake check - more than three of the
#      program's wakes past a millisecond - exits 1.
#  11. Failure proof, on Windows: the cap on the helpers beside a busy
#      program removed, and the share check exits 1.
#  12. Failure proof, on Windows: the first collection's wait for every
#      helper to reach its park put back, and the crowded check fires.
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
started = IyiMark.now_ns
sum = 0_i64
300000.times do |i|
  a = Array(Int32).new(4, i)
  sum = sum + a[0]
end
took = IyiMark.now_ns - started
flag.stop.set(1_i64)
spinners.each { |thread| thread.join }
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
module freed

import std/gc::{GC}

class Node
  getter link : Node?

  def initialize(@link : Node?)
  end
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
lost = 0
round = 0
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
    until_ns = IyiMark.now_ns + 2000000_u64
    while IyiMark.now_ns < until_ns
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
for run in 1 2 3 4 5 6 7 8 9 10; do
  if ! timeout -k 5 120 ./freed > freed.txt 2>&1 || ! grep -qx "lost 0" freed.txt; then
    echo "  run $run of 10 lost a chunk kept beside chunks freed:"; tail -3 freed.txt; exit 1
  fi
done
echo "  ten runs of 200,000 bursts of frees, every kept chunk intact"

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

step "failure proof: a large block outgrown under a mark is unmapped beside the helpers"
if ! grep -q "stayed mapped beside the helpers" answers.txt; then
  echo "  not run: the program outgrew too few blocks under a mark here to check"
else
mkdir -p unmapped/iyi
cp "$REPO"/src/iyi/*.iyi unmapped/iyi/
awk '{ if (sub(/free_large\(pointer\.address - HEADER\) if LibIyiGCTable\.__iyi_marking == 0_u8/, "free_large(pointer.address - HEADER)")) found = 1; print } END { if (!found) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > unmapped/iyi/prelude.iyi || { echo "the look at the mark this proof removes is not in the prelude any more"; exit 1; }
cmp -s unmapped/iyi/prelude.iyi "$REPO/src/iyi/prelude.iyi" && { echo "the awk found nothing to change"; exit 1; }
if ! IYI_PATH="$WORK/unmapped${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o unmapped-run > build-unmapped.log 2>&1; then
  cat build-unmapped.log; exit 1
fi
timeout -k 5 300 ./unmapped-run > unmapped.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "large: a block outgrown under a mark was unmapped" unmapped.txt; then
  echo "the large block check did not fire (exit $code):"; tail -3 unmapped.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 'large: a block outgrown' unmapped.txt)"
fi

step "failure proof: a small live set given the thousand-object bound goes beside the program"
mkdir -p thousand/iyi
cp "$REPO"/src/iyi/*.iyi thousand/iyi/
awk '{ if (sub(/drain_bounded\(w, @@kept < STW_MARK_SMALL \? STW_MARK_SMALL : STW_MARK_BOUND\)/, "drain_bounded(w, STW_MARK_BOUND)")) found = 1; print } END { if (!found) exit 3 }' \
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

# Windows only: a suspended thread stops at any instruction there, the
# window measured. darwin's runner kept every chunk in ten runs without the
# bracket, its stop landing elsewhere; Linux died of SIGSEGV.
if [ "$PSEP" = ":" ]; then
  echo "  the free bracket's failure proof is measured on Windows, where a stop lands mid-free"
else
step "failure proof: a free outside the allocator's bracket puts a dropped list back"
mkdir -p unbracketed/iyi
cp "$REPO"/src/iyi/*.iyi unbracketed/iyi/
awk '/^          write64\(table\.address &\+ CACHE_INSIDE, read64\(table\.address &\+ CACHE_INSIDE\) &\+ 1_u64\)$/ { entered = 1; next }
  prev ~ /^          table\[index\] = head$/ && /^          leave\(table\)$/ { left = 1; prev = $0; next }
  { prev = $0; print } END { if (!entered || !left) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > unbracketed/iyi/prelude.iyi || { echo "the bracket this proof removes from free is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/unbracketed${PSEP}$REPO/src" "$IYI" build freed.iyi -o freed-unbracketed > build-unbracketed.log 2>&1; then
  cat build-unbracketed.log; exit 1
fi
caught=""
for try in 1 2 3 4 5 6 7 8 9 10; do
  timeout -k 5 120 ./freed-unbracketed > unbracketed.txt 2>&1
  if [ "$?" -eq 1 ]; then caught="$try"; break; fi
done
[ -n "$caught" ] || { echo "ten runs of the free outside its bracket kept every chunk:"; tail -3 unbracketed.txt; exit 1; }
echo "  exits 1 within ten runs: a kept chunk lost, or a memory fault"
fi

if [ "$PSEP" = ":" ]; then
  echo "workdir $WORK"
  echo "concurrent mark: every step held"
  exit 0
fi

step "failure proof: helpers woken with Windows' wake boost hold the program's thread"
mkdir -p boosted/iyi
cp "$REPO"/src/iyi/*.iyi boosted/iyi/
awk '{ if ($0 ~ /^ *LibC\.SetThreadPriorityBoost\(h, 1_i32\)$/) { print "        # the helpers keep the boost"; next } print }' "$REPO/src/iyi/thread.iyi" > boosted/iyi/thread.iyi
cmp -s boosted/iyi/thread.iyi "$REPO/src/iyi/thread.iyi" && { echo "the awk found nothing to change"; exit 1; }
if ! IYI_PATH="$WORK/boosted${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/concurrent_mark.iyi" -o boosted-run > build-boosted.log 2>&1; then
  cat build-boosted.log; exit 1
fi
# The wake is one scheduling race per collection, and the check counts
# the races lost over two hundred and fifty: on a four-core runner the
# boosted build lost 5 to 88 in each of 40 runs, where the check allows 3.
# Ten runs, and the first that is caught is the proof: on an idle twelve-core
# machine the boost showed in 1 wake of 256 across five runs once, and the
# next run of the gate caught it on its second.
caught=""
for try in 1 2 3 4 5 6 7 8 9 10; do
  timeout -k 5 300 ./boosted-run > boosted.txt 2>&1
  code=$?
  if [ "$code" -eq 1 ] && grep -q "waking the helpers held the program's thread" boosted.txt; then
    caught="$try"; break
  fi
done
[ -n "$caught" ] || { echo "the wake check did not fire in 10 runs:"; tail -3 boosted.txt; exit 1; }
printf '  exits 1 on run %s at "%s"\n' "$caught" "$(grep -m1 'waking the helpers' boosted.txt)"

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

# Measured on twelve cores, where eleven new helpers waited for a core;
# on a CI runner's four the wait cost 35 ms against a 164 ms bound and the
# proof did not fire. Below eight cores it is said to be unmeasured.
cores="${NUMBER_OF_PROCESSORS:-$(nproc 2>/dev/null || echo 0)}"
if [ "$cores" -lt 8 ]; then
  echo "  the first-collection wait proof needs 8 cores to show; this machine has $cores: unmeasured here"
else
step "failure proof: a first collection that waits for every helper to reach its park is caught"
mkdir -p ready/iyi
cp "$REPO"/src/iyi/*.iyi ready/iyi/
# The wait put back as it was: each helper counts itself in on a word of
# the pool, and the helpers' start waits for the count.
awk '/^      def self\.helper_main\(seen : UInt64\) : Nil$/ { print; main = 1; next }
  main && /^        w = worker$/ { print; print "        pool_word(512_u64).value.add(1_u64)"; main = 0; counted = 1; next }
  /^          @@helpers = @@helpers \+ 1_u64$/ { print; made = 1; next }
  made && /^        end$/ { print; print "        while pool_word(512_u64).value.get < @@helpers"; print "          spin_pause"; print "        end"; made = 0; waited = 1; next }
  { print } END { if (!counted || !waited) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > ready/iyi/prelude.iyi || { echo "the helpers' start this proof changes is not in the prelude any more"; exit 1; }
if ! IYI_PATH="$WORK/ready${PSEP}$REPO/src" "$IYI" build --release crowded.iyi -o crowded-ready > build-ready.log 2>&1; then
  cat build-ready.log; exit 1
fi
# Runs with the wait took 291 to 1,223 ms here, against bounds of 140 and
# 184, and a machine busy elsewhere moves both: five rounds of three, and
# the first caught is the proof.
caught=""
for round in 1 2 3 4 5; do
  crowded_best crowded-ready helped
  if [ "$best" -gt "$bound" ]; then caught="$round"; break; fi
done
[ -n "$caught" ] || { echo "the crowded check did not fire in five rounds: $best ms with the wait, within $bound"; exit 1; }
echo "  caught on round $caught: beside $beside threads computing, past four times the time with no helpers and 100 ms"
fi

echo "workdir $WORK"
echo "concurrent mark: every step held"
exit 0
