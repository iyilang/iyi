#!/usr/bin/env bash
# Where a plain `spawn` runs (SPEC.md III.4.15): in parallel where the
# compiler can prove it safe, in its spawner's unit otherwise.
#
#     bash bench/spawn_eligible.sh
#
#   1. bench/spawn_eligible.iyi, plain and --release, on four workers:
#      four spawns whose blocks capture only atomics are all running at
#      one instant, from the main thread and from inside a parallel task;
#      four that append to their parent's `Array` stay in its unit, one at
#      a time; and four `spawn_serial` tasks that capture only atomics stay
#      in theirs. On a pool of one, eligible spawns stay on the main thread
#      and no pool starts. On a pool of four, in a process of its own, one
#      spawn starts one worker, spawns joined one at a time at most three,
#      and four tasks running at one instant all four.
#   2. The explanation: `--explain-spawn` notes each spawn, naming the
#      capture that kept one in its unit - a captured `Array`, a local
#      assigned in the loop that spawns, a constant reached through a call
#      - and a constant marked `@[SafeReach]` keeps nothing serial. Notes
#      are not warnings: `--error-on-warnings` passes, `-f json` marks
#      them `"severity": "note"`, and a build that asked for none prints
#      none.
#   3. Failure proofs against broken copies of the runtime, each caught at
#      the named check: an eligible spawn left in its unit, an ineligible
#      one sent to the pool, `spawn_serial` sent to the pool, a pool of one
#      that starts for eligible spawns anyway, a pool that starts every
#      worker at once, and one that never starts a second.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
  *) PSEP=':' ;;
esac

cd "$WORK" || exit 1

step() { echo "== $1"; }

# ── 1. The exercise, twice ────────────────────────────────────────────────
for build in plain release; do
  step "where each spawn runs, $build build"
  flag=""
  [ "$build" = release ] && flag="--release"
  if ! "$IYI" build $flag "$REPO/bench/spawn_eligible.iyi" -o "eligible-$build" > "build-$build.log" 2>&1; then
    echo "build failed:"; tail -20 "build-$build.log"; exit 1
  fi
  for run in "together nested unit serial --workers=4" "one --workers=1" "grows --workers=4"; do
    # shellcheck disable=SC2086 # the steps are words
    timeout -k 5 120 "./eligible-$build" $run > "ran-$build.txt" 2>&1
    code=$?
    if [ "$code" -ne 0 ] || ! grep -q 'every property held' "ran-$build.txt"; then
      echo "the exercise failed (exit $code, $run):"; cat "ran-$build.txt"; exit 1
    fi
    grep -v 'every property held' "ran-$build.txt" | sed 's/^/  /'
  done
done

# ── 2. The explanation ────────────────────────────────────────────────────
step "--explain-spawn names what kept a spawn in its unit"
cat > explained.iyi <<'IYI'
module explained

class Ledger
  def initialize
    @rows = 0
  end

  def add : Int32
    @rows += 1
  end
end

LEDGER = Ledger.new

@[SafeReach("the gate's claim: set once, and every task only reads it")]
LIMITS = [10, 20]

def record : Int32
  LEDGER.add
end

def limit : Int32
  LIMITS[0]
end

done = Atomic(Int32).new(0)
log = [] of Int32
group do |g|
  g.spawn { done.add(1) }
  g.spawn { log << 1; 0 }
  g.spawn { record }
  g.spawn { limit }
  i = 0
  while i < 2
    g.spawn { i }
    i = i + 1
  end
end
IYI
explain() { # line, expected text
  if ! grep -F "explained.iyi:$1:" explain.log | grep -qF "$2"; then
    echo "line $1 was not noted with \"$2\":"; cat explain.log; exit 1
  fi
  echo "  line $1: $(grep -m1 -F "explained.iyi:$1:" explain.log | sed 's/^.*note: //' | cut -c1-160)"
}
if ! "$IYI" check --explain-spawn --error-on-warnings explained.iyi > explain.log 2>&1; then
  echo "check --explain-spawn --error-on-warnings failed a program with no warning:"; cat explain.log; exit 1
fi
explain 29 'spawn runs in parallel'
explain 30 'spawn stays in its spawner'"'"'s unit: the block captures `log : Array(Int32)`, which is not Share'
explain 31 'the block reaches the constant `LEDGER : Explained::Ledger` through `record` → `LEDGER.add`'
explain 32 'spawn runs in parallel'
explain 35 'line 36: `i` is assigned here, in a loop or a block that spawns the task again'
if grep -q 'Warning' explain.log; then
  echo "a plain spawn was warned about:"; cat explain.log; exit 1
fi
if ! "$IYI" check --explain-spawn -f json explained.iyi > explain.json 2>&1 \
  || [ "$(grep -o '"severity":"note"' explain.json | wc -l | tr -d ' ')" != 5 ]; then
  echo "-f json did not carry the five notes as \"severity\": \"note\":"; cat explain.json; exit 1
fi
echo "  -f json: five frames marked \"severity\": \"note\""
if ! "$IYI" check explained.iyi > quiet.log 2>&1 || [ -s quiet.log ]; then
  echo "check without --explain-spawn printed something:"; cat quiet.log; exit 1
fi
echo "  without --explain-spawn: nothing printed"

# ── 3. Failure proofs: broken copies of the runtime ──────────────────────
# Each a copy of src/iyi with concurrency.iyi changed, built against
# through IYI_PATH; nothing in the tree is touched.
broken() { # name, awk program
  mkdir -p "$1/iyi"
  cp "$REPO"/src/iyi/*.iyi "$1/iyi/"
  awk "$2" "$REPO/src/iyi/concurrency.iyi" > "$1/iyi/concurrency.iyi"
  if cmp -s "$1/iyi/concurrency.iyi" "$REPO/src/iyi/concurrency.iyi"; then
    echo "the awk for $1 found nothing to change"; exit 1
  fi
  if ! IYI_PATH="$WORK/$1${PSEP}$REPO/src" "$IYI" build "$REPO/bench/spawn_eligible.iyi" -o "$1-run" > "build-$1.log" 2>&1; then
    echo "the broken copy $1 failed to build:"; tail -20 "build-$1.log"; exit 1
  fi
}
# A run that ends any way but exit 1 at the sentence is run again, up to
# five times, as bench/parallel_exercise.sh's are: a broken copy that races
# on purpose can lose the race some other way first.
caught() { # name, expected FAIL text, step arguments...
  local name="$1" want="$2" code attempt
  shift 2
  for attempt in 1 2 3 4 5; do
    timeout -k 5 120 "./$name-run" "$@" > "$name.txt" 2>&1
    code=$?
    [ "$code" -eq 1 ] && grep -qF "$want" "$name.txt" && break
  done
  if [ "$code" -ne 1 ] || ! grep -qF "$want" "$name.txt"; then
    echo "the broken copy $name was not caught at \"$want\" (exit $code):"; tail -20 "$name.txt"; exit 1
  fi
  echo "  exits 1 at \"$(grep -m1 -F "$want" "$name.txt" | sed 's/^FAIL: //')\""
}

step "failure proof: an eligible spawn left in its unit"
broken leftserial '/^      return in_unit\(&block\) unless IyiWorkers.parallel\?$/ { print "      return in_unit(&block)"; next } { print }'
caught leftserial 'eligible spawns waited 2000 ms for the others and left alone' together --workers=4

step "failure proof: an ineligible spawn sent to the pool"
broken madeparallel '/^  def spawn\(&block/ { inspawn = 1 } inspawn && /^    in_unit\(&block\)$/ { print "    on_pool(&block)"; inspawn = 0; next } { print }'
caught madeparallel 'tasks of one unit were running at one instant' unit --workers=4

step "failure proof: spawn_serial sent to the pool"
broken optoutignored '/^  def spawn_serial\(&block/ { inserial = 1 } inserial && /^    in_unit\(&block\)$/ { print "    on_pool(&block)"; inserial = 0; next } { print }'
caught optoutignored 'spawn_serial tasks were running at one instant' serial --workers=4

step "failure proof: a pool of one that starts for eligible spawns"
broken oneignored '/^  def self.parallel\? : Bool$/ { print; print "    return true"; next } { print }'
caught oneignored 'one: ' one --workers=1

step "failure proof: a pool that starts every worker at once"
broken wholepool '/^      start_monitor$/ { print "      while word(pointerof(@@launched)).value.get < @@started.to_i64"; print "        word(pointerof(@@launched)).value.add(1_i64)"; print "        word(pointerof(@@spinning)).value.add(1_i64)"; print "        IyiThread.start { IyiWorkers.work }"; print "      end" } { print }'
caught wholepool 'grows: one eligible spawn started 4 of' grows --workers=4

step "failure proof: a pool that never starts a second worker"
broken nevergrows '/^  def self.grow : Nil$/ { print; print "    return"; next } { print }'
caught nevergrows 'grows: 4 eligible spawns running at one instant started 1 of' grows --workers=4

echo "== spawn eligibility: every check held"
