#!/usr/bin/env bash
# Drives bench/concurrent_mark.iyi: the mark beside the program, GC_DESIGN.md
# Stage 9, and the write barrier it stands on.
#
#     bash bench/concurrent_mark.sh
#
# Five steps, the last two failure proofs:
#   1. The program holds, release: twenty-four rounds each move a payload
#      out of an unmarked chain into an already-marked holder under a
#      running mark, and every payload is intact after the collection.
#   2. The pauses, printed: the stop-the-world mark over the same chain
#      against a concurrent collection's two stops, and the longest the
#      program's thread spent waking the helpers, which on Windows is
#      held under 1 ms.
#   3. The machine alone, printed: one thread per core reading the clock
#      and nothing else, and the longest gap any of them saw. A pause is
#      only the runtime's where the machine gives its threads their cores:
#      on a twelve-core Windows VM this read 23 to 64 ms, the length of
#      the longest second stops measured there.
#   4. Failure proof: the barrier's shade removed from a copy of the
#      prelude; the first payload moved under a mark is freed, and the
#      program exits 1 saying so.
#   5. Failure proof, on Windows: the helpers given back the boost a
#      satisfied wait brings, and the wake check exits 1.
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
grep -E '^(moves|pause|wake):' answers.txt | sed 's/^/  /'

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
i = 1
while i < count
  k = i
  threads << IyiThread.start do
    watch(k, deadline)
    nil
  end
  i = i + 1
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

step "failure proof: a barrier that shades nothing loses the moved payload"
mkdir -p patched/iyi
cp "$REPO"/src/iyi/*.iyi patched/iyi/
awk '{ sub(/mutator_shade\(w, base\) if base != 0/, "# the barrier shades nothing"); print }' "$REPO/src/iyi/prelude.iyi" > patched/iyi/prelude.iyi
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
# The wake is one scheduling race per collection: on twelve cores the
# boosted build was caught in 5 runs of 10, on four in 10 of 10. Five
# runs, and the first that is caught is the proof.
caught=""
for try in 1 2 3 4 5; do
  timeout -k 5 300 ./boosted-run > boosted.txt 2>&1
  code=$?
  if [ "$code" -eq 1 ] && grep -q "waking the helpers held the program's thread" boosted.txt; then
    caught="$try"; break
  fi
done
[ -n "$caught" ] || { echo "the wake check did not fire in 5 runs:"; tail -3 boosted.txt; exit 1; }
printf '  exits 1 on run %s at "%s"\n' "$caught" "$(grep -m1 'waking the helpers' boosted.txt)"

echo "workdir $WORK"
echo "concurrent mark: every step held"
exit 0
