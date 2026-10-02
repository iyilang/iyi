#!/usr/bin/env bash
# Drives bench/concurrent_mark.iyi: the mark beside the program, GC_DESIGN.md
# Stage 9, and the write barrier it stands on.
#
#     bash bench/concurrent_mark.sh
#
# Nine steps, the last five failure proofs:
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
#      the longest second stops measured there.
#   4. Buffers of references grown by `realloc`, ten runs of three hundred
#      rounds, plain: every referent intact in every run. The old buffer
#      is freed while a mark may have it queued.
#   5. Failure proof: the barrier's shade removed from a copy of the
#      prelude; the first payload moved under a mark is freed, and the
#      program exits 1 saying so.
#   6. Failure proof: the barrier's own look at the marking flag removed;
#      a barrier run after its mark ended grays a holder, the next mark
#      sweeps the payload it held, and the program exits 1 saying so.
#   7. Failure proof: `free`'s look at the mark removed; a large block
#      outgrown under a mark is unmapped beside the helpers at once, which
#      is how a helper walking the large list faulted, and the program
#      exits 1 saying so.
#   8. Failure proof, on Windows: the helpers given back the boost a
#      satisfied wait brings, and the wake check - more than three of the
#      program's wakes past a millisecond - exits 1.
#   9. Failure proof, on Windows: the cap on the helpers beside a busy
#      program removed, and the share check exits 1.
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

echo "workdir $WORK"
echo "concurrent mark: every step held"
exit 0
