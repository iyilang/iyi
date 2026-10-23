#!/usr/bin/env bash
# Drives bench/parallel_mark.iyi: the parallel marker, GC_DESIGN.md Stage 7.
#
#     bash bench/parallel_mark.sh
#
# Nine steps, six of them failure proofs:
#   1. The program holds, release: a million-node tree survives five marks
#      alone and five with helpers, and the helpers blackened nodes; a
#      mark's round of permits, closed, gives none to a late helper; the
#      pool holds a handful of pieces after them; a worker's stack grew to
#      hold a 300,000-wide object marked alone; and, on Linux and Windows,
#      a helper with no work spins fifty microseconds before it parks.
#   2. The two pause means, printed: alone against with helpers.
#   3. Failure proof: the marker's donation of its stack's bottom removed
#      from a copy of the prelude; the helpers wake and find nothing, and
#      the program exits 1 saying so.
#   4. Failure proof: a batch taken is never freed; no batch is ever
#      handed out twice, and the pool check says so on any machine.
#   5. Failure proof: a stack that will not grow dies where it used to,
#      by name, on the wide object.
#   6. Failure proof: the spin before the park counted in pause hints, far
#      past the bound on any machine; the park check names its length.
#   7. Failure proof: a close that leaves the round's permits open; the
#      late take succeeds, and the permits check says so.
#   8. A helper a round late is counted: on a copy of the prelude where
#      every helper waits between its wake and its permit, and the
#      collector after opening a mark's permits, 200 back-to-back
#      collections with helpers end, in each of five runs.
#   9. Failure proof: that copy with the permits opened before the
#      mark's counts are reset, as every round had them; it never ends,
#      and the bound ends it.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs whatever compiler the caller names; `bin/iyi` is a shell
# wrapper, and on Windows the caller has to point at the built exe itself.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` on it is silently ignored, so the patched
# copy is never read and the proof that a check can fail quietly stops
# proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
cd "$WORK" || exit 1

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

step() { echo "== $1"; }

case "$(uname -s)" in
  Linux | Darwin | MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *) echo "parallel mark: measured on Linux, darwin and Windows; nothing to measure here"; exit 0 ;;
esac

# The cores this process may run on - `nproc` reads the affinity mask, so
# `taskset -c 0` is one core here - and not the machine's count.
CORES="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
export PARALLEL_MARK_CORES="$CORES"

step "the parallel marker, release build"
if ! "$IYI" build --release "$REPO/bench/parallel_mark.iyi" -o marks > build.log 2>&1; then
  cat build.log; exit 1
fi
if ! timeout -k 5 300 ./marks > answers.txt 2>&1; then
  cat answers.txt; exit 1
fi
grep -q 'every property held' answers.txt || { cat answers.txt; exit 1; }

step "the mark, alone and with helpers ($CORES cores here)"
grep -E '^(tree|permits|mark|pool|stack|park):' answers.txt | sed 's/^/  /'

# $1 label, $2 awk program over the prelude, $3 the phrase the failing check
# prints, $4 the exit code expected.
prove_fails() {
  local label="$1" script="$2" phrase="$3" want="$4" dir="patched-$RANDOM"
  step "failure proof: $label"
  mkdir -p "$dir/iyi"
  cp "$REPO"/src/iyi/*.iyi "$dir/iyi/"
  awk "$script" "$REPO/src/iyi/prelude.iyi" > "$dir/iyi/prelude.iyi"
  cmp -s "$dir/iyi/prelude.iyi" "$REPO/src/iyi/prelude.iyi" && { echo "the awk found nothing to change"; exit 1; }
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/parallel_mark.iyi" -o "$dir/program" > "$dir/build.log" 2>&1; then
    cat "$dir/build.log"; exit 1
  fi
  timeout -k 5 300 "./$dir/program" > "$dir/out.txt" 2>&1
  local code=$?
  if [ "$code" -ne "$want" ] || ! grep -q "$phrase" "$dir/out.txt"; then
    echo "the check did not fire (exit $code, wanted $want at \"$phrase\"):"; tail -3 "$dir/out.txt"; exit 1
  fi
  printf '  exits %s at "%s"\n' "$code" "$(grep -m1 "$phrase" "$dir/out.txt")"
}

# On one core the helpers are never scheduled while the marker works, so
# the checks that need one - sharing, and recycling what was shared - are
# off, and there is nothing for their proofs to show.
if [ "$CORES" -gt 1 ]; then
  prove_fails "a marker that never shares its stack is refused" \
    '{ sub(/since >= DONATE_EVERY/, "false \\&\\& since >= DONATE_EVERY"); print }' "blackened nothing" 1
else
  step "failure proof: a marker that never shares its stack is refused"
  echo "  one core here: the sharing check needs a second, so it and its proof are off"
fi

# A taken batch's words never go back: every batch published is a fresh
# one, and the pool has reused none.
if [ "$CORES" -gt 1 ]; then
  prove_fails "a pool that never recycles a batch is refused" \
    '{ if ($0 ~ /^        free_batch\(batch\)$/) { print "        # removed"; next } print }' "pool:" 1
else
  step "failure proof: a pool that never recycles a batch is refused"
  echo "  one core here: no helper takes a batch, so recycling is not asked and not proved"
fi

# The stack never grows: the fatal it used to be, on the wide object.
prove_fails "a stack that will not grow dies by name" \
  '{ if ($0 ~ /^        return IyiHeap\.read64\(w \+ W_STACK\) if need <= cap$/) { print "        IyiRoots.fatal(\"iyi: a mark worker'"'"'s stack overflowed\\n\") if need > cap"; print; next } print }' "stack overflowed" 1

# A spin counted in pause hints and not by the clock, long enough on any
# machine: the check reads the spin's length and names it.
case "$(uname -s)" in
  Darwin)
    step "failure proof: a spin before the park that ignores the clock is refused"
    echo "  not here: darwin's helpers spin without parking, so the spin before a park is Linux's and Windows'"
    ;;
  *)
    prove_fails "a spin before the park that ignores the clock is refused" \
      '{ sub(/spins & \(SPIN_CHECK - 1_u64\) == 0_u64 && now_ns >= deadline/, "spins >= 200000_u64"); print }' "park:" 1
    ;;
esac

# The round's close leaves its permits where they were: a helper waking
# after the wait takes one, on any machine and any core count.
prove_fails "a round whose close leaves its permits open is refused" \
  '{ sub(/value - \(value & MARK_PERMITS_LEFT\)\)\[1\]/, "value)[1]"); print }' "permits:" 1

# A helper woken for one round that reaches its take only once the next
# round is open - preempted between its wake and its take - takes a
# permit a generation early, and every count it adds to has to be that
# round's by then (`open_mark_permits`). A copy of the prelude makes it
# happen every round: each helper waits 200 us between its wake and its
# take, and the collector 50 us once a mark's permits are open. The
# program collects 200 times back to back with a 2 MiB block live, so
# every mark asks for helpers and is over before a helper's wait is.
cat > late.iyi <<'IYI'
class Held
  @@block : UInt64 = 0_u64

  def self.block : UInt64
    @@block
  end

  def self.block=(value : UInt64) : Nil
    @@block = value
  end
end

IyiMark.auto = false
IyiMark.workers = 15_u64
Held.block = Pointer(UInt8).malloc(2097152_u64).address
round = 0
while round < 200
  IyiMark.collect
  round = round + 1
end
raise "late: the live block was lost" if Held.block == 0_u64
puts "late: 200 collections back to back, each mark with helpers a round late, and every one ended"
IYI
LATE='
  /^          seen = wait_generation\(seen\)$/ { print; print "          until_ns = now_ns + 200000_u64"; print "          while now_ns < until_ns"; print "            spin_pause"; print "          end"; late = 1; next }
  /^        open_mark_permits\(helpers\)$/ { print; print "        until_ns = now_ns + 50000_u64"; print "        while now_ns < until_ns"; print "          spin_pause"; print "        end"; slow = 1; next }
  { print }
  END { if (!(late && slow)) exit 3 }'
# $1 the copy's directory, $2 the prelude to make it late from.
late_copy() {
  mkdir -p "$1/iyi"
  cp "$REPO"/src/iyi/*.iyi "$1/iyi/"
  awk "$LATE" "$2" > "$1/iyi/prelude.iyi" || { echo "the helper's take or the mark's permits are not where the copy waits any more"; exit 1; }
  if ! IYI_PATH="$WORK/$1${PSEP}$REPO/src" "$IYI" build late.iyi -o "$1/late" > "$1/build.log" 2>&1; then
    cat "$1/build.log"; exit 1
  fi
}
if [ "$CORES" -gt 1 ]; then
  step "a helper a round late is counted, on a copy where every helper is late (five runs)"
  late_copy late-copy "$REPO/src/iyi/prelude.iyi"
  for run in 1 2 3 4 5; do
    timeout -k 5 120 ./late-copy/late > late.txt 2>&1
    code=$?
    if [ "$code" -ne 0 ] || ! grep -q '^late: ' late.txt; then
      echo "  run $run of 5 did not end well (exit $code):"; tail -3 late.txt; exit 1
    fi
  done
  sed 's/^/  /' late.txt

  # The order every round had: the permits opened first, then the counts
  # reset - a late taker's finished drain wiped from the takers done, or
  # its count wiped from the workers active, so the drains take it below
  # zero. Either way a wait never ends, and nothing is printed.
  step "failure proof: a mark's permits opened before its counts are reset never ends"
  awk '/^        open_mark_permits\(helpers\)$/ { moved = 1; next }
       /^        pool_word\(POOL_FINISH\)\.value\.set\(0_u64\)$/ { print "        open_mark_permits(helpers)" }
       { print }
       END { if (!moved) exit 3 }' "$REPO/src/iyi/prelude.iyi" > first-prelude.iyi ||
    { echo "the mark's permits are not where the proof moves them from"; exit 1; }
  late_copy late-first first-prelude.iyi
  timeout -k 5 30 ./late-first/late > late-first.txt 2>&1
  code=$?
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT) taskkill //F //IM late.exe > /dev/null 2>&1 ;;
  esac
  if { [ "$code" -ne 124 ] && [ "$code" -ne 137 ]; } || grep -q '^late: ' late-first.txt; then
    echo "the check did not fire (exit $code):"; tail -3 late-first.txt; exit 1
  fi
  echo "  still running at 30 s, ended by the bound (exit $code), its last line never printed"
else
  step "a helper a round late is counted, on a copy where every helper is late"
  echo "  one core here: a mark asks no helper, so no helper is late and nothing is proved"
fi

echo "workdir $WORK"
echo "parallel mark: every step held"
exit 0
