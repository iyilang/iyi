#!/usr/bin/env bash
# The chaos scheduler (SPEC.md III.4.17): `iyi test --chaos[=SEED]
# [--chaos-runs N]`, which runs a test once per seed with its scheduling
# choices drawn from the seed, so that a logical ordering race - an order
# the program depends on and the language does not promise - fails on
# some seed, and fails again on that seed.
#
#     bash bench/chaos_exercise.sh
#
#   1. Off is nothing: a program built without -Diyi_chaos names nothing
#      of the scheduler's in its IR, and the same program built with it
#      does.
#   2. The bugs pass without it: bench/chaos_claim.iyi (a check-then-act
#      on an `Atomic`) and bench/chaos_join.iyi (a missing join), each
#      built once and run PLAIN_RUNS times on the machine's own pool, fail
#      at most once.
#   3. Caught, with a seed that reproduces: `iyi test --chaos=1
#      --chaos-runs 100` fails each test, naming the seed and the
#      `--chaos=SEED` that runs it again; that line fails again; and the
#      program built for chaos, run five times on the seed with
#      IYI_CHAOS_TRACE, prints the same output and the same schedule five
#      times, failing each.
#   4. A drawn seed: `iyi test --chaos --chaos-runs 200` on the claim test
#      fails on a seed drawn there, and that seed fails again.
#   5. One seed, one schedule; many seeds, many: bench/chaos_exercise.iyi
#      under seeds 1 to 30, twice each, holds every property each time,
#      each seed's two runs print the same lines and schedule, the 30 meet
#      at least 20 orders and both arms of a `select`, and parallel units
#      start before the spawner parks under some seeds and not others.
#   6. Broken copies of the scheduler, each caught at the check that names
#      it: the stream ignored (every draw 0, which is the plain
#      scheduler's choice everywhere) finds neither bug; the seed not
#      honoured (the stream seeded from the clock) does not run one seed's
#      schedule twice; units ignored (any task chosen, a unit-mate's
#      included) runs a task between a unit-mate's operations or before
#      its spawner parks; parallel tasks left in their spawner's unit
#      never start before it parks; and a point left in a build without
#      the flag names the scheduler in its IR.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
EXE=""
PLAIN_RUNS="${PLAIN_RUNS:-40}"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    EXE=".exe"
    ;;
  *) PSEP=':' ;;
esac

cd "$WORK" || exit 1

step() { echo "== $1"; }
die() { echo "FAIL: $*"; exit 1; }

# A build of *source* into *name*, under the prelude *prelude* (empty for
# the repository's own), with the rest of the arguments.
build() { # name, prelude, source, flags...
  local name="$1" prelude="$2" source="$3"
  shift 3
  if [ -n "$prelude" ]; then
    IYI_PATH="$prelude${PSEP}$REPO/src" "$IYI" build "$source" -o "$name" "$@" > "build-$name.log" 2>&1
  else
    "$IYI" build "$source" -o "$name" "$@" > "build-$name.log" 2>&1
  fi
}

# `iyi test` over *source*, under *prelude*; its output in *log*, its exit
# code answered.
chaos_test() { # prelude, log, iyi test arguments...
  local prelude="$1" log="$2"
  shift 2
  if [ -n "$prelude" ]; then
    IYI_PATH="$prelude${PSEP}$REPO/src" timeout -k 5 900 "$IYI" test "$@" > "$log" 2>&1
  else
    timeout -k 5 900 "$IYI" test "$@" > "$log" 2>&1
  fi
}

# Step 3 for one test under one prelude: caught within 100 seeds from 1,
# the named seed failing again through `iyi test`, and five traced runs of
# it identical and failing. Prints why it did not hold and answers 1.
caught() { # prelude, label, source
  local prelude="$1" label="$2" source="$3" code seed first run
  chaos_test "$prelude" "catch-$label.txt" --chaos=1 --chaos-runs 100 "$source"
  code=$?
  if [ "$code" -ne 1 ] || ! grep -q "reproduce: .* test --chaos=" "catch-$label.txt"; then
    echo "$label: not caught in seeds 1 to 100 (exit $code):"; tail -5 "catch-$label.txt"; return 1
  fi
  seed="$(sed -n 's/.*(chaos seed \([0-9][0-9]*\), run \([0-9][0-9]*\) of 100).*/\1/p' "catch-$label.txt" | head -1)"
  run="$(sed -n 's/.*(chaos seed \([0-9][0-9]*\), run \([0-9][0-9]*\) of 100).*/\2/p' "catch-$label.txt" | head -1)"
  [ -n "$seed" ] || { echo "$label: the failure names no seed:"; cat "catch-$label.txt"; return 1; }
  chaos_test "$prelude" "again-$label.txt" "--chaos=$seed" "$source"
  code=$?
  if [ "$code" -ne 1 ] || ! grep -q "(chaos seed $seed, run 1 of 1)" "again-$label.txt"; then
    echo "$label: --chaos=$seed did not fail again (exit $code):"; tail -5 "again-$label.txt"; return 1
  fi
  build "traced-$label" "$prelude" "$source" -Diyi_chaos || { echo "$label: the chaos build failed:"; tail -20 "build-traced-$label.log"; return 1; }
  first=""
  for attempt in 1 2 3 4 5; do
    IYI_CHAOS="$seed" IYI_CHAOS_TRACE=1 IYI_WORKERS=1 timeout -k 5 120 "./traced-$label$EXE" > "traced-$label-$attempt.txt" 2>&1
    code=$?
    [ "$code" -eq 1 ] || { echo "$label: seed $seed's traced run $attempt passed (exit $code):"; cat "traced-$label-$attempt.txt"; return 1; }
    if [ -z "$first" ]; then
      first="traced-$label-$attempt.txt"
    elif ! cmp -s "$first" "traced-$label-$attempt.txt"; then
      echo "$label: seed $seed ran two schedules:"; cat "$first" "traced-$label-$attempt.txt"; return 1
    fi
  done
  echo "  $label: caught at seed $seed (run $run of 100), again through --chaos=$seed, and five traced runs alike:"
  sed 's/^/    /' "$first"
}

# Step 5 under one prelude: answers 1, saying why, when a property fails.
seeds() { # prelude, label
  local prelude="$1" label="$2" seed orders early late lefts rights
  build "exercise-$label" "$prelude" "$REPO/bench/chaos_exercise.iyi" -Diyi_chaos || { echo "$label: the exercise did not build:"; tail -20 "build-exercise-$label.log"; return 1; }
  : > "orders-$label.txt"
  early=0
  late=0
  for seed in $(seq 1 30); do
    for twice in a b; do
      IYI_CHAOS="$seed" IYI_CHAOS_TRACE=1 IYI_WORKERS=1 timeout -k 5 120 "./exercise-$label$EXE" > "seed-$label-$seed-$twice.txt" 2>&1
      if ! grep -q "every property held" "seed-$label-$seed-$twice.txt"; then
        echo "$label: seed $seed: $(grep -m1 FAIL "seed-$label-$seed-$twice.txt" || tail -3 "seed-$label-$seed-$twice.txt")"; return 1
      fi
    done
    if ! cmp -s "seed-$label-$seed-a.txt" "seed-$label-$seed-b.txt"; then
      echo "$label: seed $seed's two runs differ:"; diff "seed-$label-$seed-a.txt" "seed-$label-$seed-b.txt"; return 1
    fi
    grep "^order " "seed-$label-$seed-a.txt" >> "orders-$label.txt"
    if grep -q "started before the spawner parked: 0$" "seed-$label-$seed-a.txt"; then
      late=$((late + 1))
    else
      early=$((early + 1))
    fi
  done
  orders="$(sort -u "orders-$label.txt" | wc -l | tr -d ' ')"
  lefts="$(cat seed-"$label"-*-a.txt | grep -c "^left arms [1-3] of 3")"
  rights="$(cat seed-"$label"-*-a.txt | grep -c "^left arms [0-2] of 3")"
  [ "$early" -gt 0 ] || { echo "$label: no seed started a parallel unit before the spawner parked"; return 1; }
  [ "$late" -gt 0 ] || { echo "$label: every seed started a parallel unit before the spawner parked"; return 1; }
  [ "$orders" -ge 20 ] || { echo "$label: 30 seeds met $orders orders, not 20"; return 1; }
  [ "$lefts" -gt 0 ] && [ "$rights" -gt 0 ] || { echo "$label: a select took one arm only ($lefts runs with a left arm, $rights with a right)"; return 1; }
  echo "  $label: 30 seeds, each run twice alike: $orders orders, a parallel unit started before the spawner parked under $early seeds and not under $late"
}

# ── 1. Off is nothing ─────────────────────────────────────────────────────
step "a build without -Diyi_chaos carries none of the scheduler"
off_is_nothing() { # prelude, label
  local prelude="$1" label="$2"
  build "off-$label" "$prelude" "$REPO/bench/chaos_claim.iyi" --emit llvm-ir || { echo "$label: the plain build failed:"; tail -20 "build-off-$label.log"; return 1; }
  if grep -q "IyiChaos" "off-$label.ll"; then
    echo "$label: a plain build names the chaos scheduler: $(grep -m1 -o '[^ ]*IyiChaos[^ ]*' "off-$label.ll")"; return 1
  fi
  build "on-$label" "$prelude" "$REPO/bench/chaos_claim.iyi" --emit llvm-ir -Diyi_chaos || { echo "$label: the chaos build failed:"; tail -20 "build-on-$label.log"; return 1; }
  grep -q "IyiChaos" "on-$label.ll" || { echo "$label: a chaos build names no chaos scheduler"; return 1; }
  echo "  $label: plain IR names nothing of it, the -Diyi_chaos IR does ($(grep -c 'IyiChaos' "on-$label.ll") lines)"
}
off_is_nothing "" shipped || exit 1

# ── 2. The bugs pass without it ───────────────────────────────────────────
for test in claim join; do
  step "bench/chaos_$test.iyi passes without --chaos"
  build "plain-$test" "" "$REPO/bench/chaos_$test.iyi" || die "the plain build failed: $(tail -20 "build-plain-$test.log")"
  failed=0
  for run in $(seq 1 "$PLAIN_RUNS"); do
    timeout -k 5 120 "./plain-$test$EXE" > "plain-$test-$run.txt" 2>&1 || failed=$((failed + 1))
  done
  echo "  failed $failed of $PLAIN_RUNS runs on the machine's own pool"
  [ "$failed" -le 1 ] || die "chaos_$test failed $failed of $PLAIN_RUNS plain runs: $(cat plain-"$test"-*.txt | sort | uniq -c)"
done

# ── 3. Caught, with a seed that reproduces ────────────────────────────────
step "iyi test --chaos catches each bug, and its seed runs the schedule again"
caught "" claim "$REPO/bench/chaos_claim.iyi" || exit 1
caught "" join "$REPO/bench/chaos_join.iyi" || exit 1

# ── 4. A drawn seed ───────────────────────────────────────────────────────
step "a seed drawn by iyi test, named and run again"
chaos_test "" drawn.txt --chaos --chaos-runs 200 "$REPO/bench/chaos_claim.iyi"
code=$?
[ "$code" -eq 1 ] || die "200 drawn seeds did not catch chaos_claim (exit $code): $(tail -3 drawn.txt)"
seed="$(sed -n 's/.*reproduce: .* test --chaos=\([0-9][0-9]*\) .*/\1/p' drawn.txt | head -1)"
[ -n "$seed" ] || die "the drawn failure names no seed: $(cat drawn.txt)"
chaos_test "" drawn-again.txt "--chaos=$seed" "$REPO/bench/chaos_claim.iyi"
code=$?
[ "$code" -eq 1 ] || die "the drawn seed $seed did not fail again (exit $code): $(tail -3 drawn-again.txt)"
echo "  $(grep -m1 'chaos seed' drawn.txt | sed 's/^.*: //'), and --chaos=$seed failed again"

# ── 5. One seed, one schedule; many seeds, many ───────────────────────────
step "bench/chaos_exercise.iyi under 30 seeds, twice each"
seeds "" shipped || exit 1

# ── 6. Broken copies of the scheduler ─────────────────────────────────────
# Each a copy of src/iyi with one file changed by awk, built against
# through IYI_PATH; nothing in the tree is touched. Every check above is
# deterministic under the simulation, so each copy runs once.
broken() { # name, file, awk program
  mkdir -p "$1/iyi"
  cp "$REPO"/src/iyi/*.iyi "$1/iyi/"
  awk "$3" "$REPO/src/iyi/$2" > "$1/iyi/$2"
  if cmp -s "$1/iyi/$2" "$REPO/src/iyi/$2"; then
    echo "the awk for $1 found nothing to change"; exit 1
  fi
}
expect_caught() { # name, the sentence its check prints
  if ! grep -qF "$2" "$1.txt"; then
    echo "the broken copy $1 was not caught at \"$2\":"; tail -10 "$1.txt"; exit 1
  fi
  echo "  caught: $(grep -m1 -F "$2" "$1.txt")"
}

step "broken copy: the stream ignored, every choice the plain scheduler's"
broken prngignored chaos.iyi '/^  def self.draw : UInt64$/ { print; print "    return 0_u64"; next } { print }'
caught "$WORK/prngignored" claim "$REPO/bench/chaos_claim.iyi" > prngignored.txt 2>&1
expect_caught prngignored "claim: not caught in seeds 1 to 100"
caught "$WORK/prngignored" join "$REPO/bench/chaos_join.iyi" > prngignored.txt 2>&1
expect_caught prngignored "join: not caught in seeds 1 to 100"

step "broken copy: the seed not honoured, the stream seeded from the clock"
broken seedignored chaos.iyi '/^    @@stream = @@seed$/ { print "    @@stream = __iyi_monotonic_ns.to_u64"; next } { print }'
seeds "$WORK/seedignored" seedignored > seedignored.txt 2>&1
expect_caught seedignored "two runs differ"

step "broken copy: units ignored, a unit-mate chosen like any task"
broken unitsignored chaos.iyi '/^      if unit.stamp != generation$/ { print "      if true"; next } { print }'
seeds "$WORK/unitsignored" unitsignored > unitsignored.txt 2>&1
expect_caught unitsignored "FAIL: "

step "broken copy: a parallel task left in its spawner's unit"
broken leftinunit chaos.iyi '/^    task.fiber.chaos_unit = IyiChaosUnit.new\(@@units, fresh_priority\)$/ { next } { print }'
seeds "$WORK/leftinunit" leftinunit > leftinunit.txt 2>&1
expect_caught leftinunit "no seed started a parallel unit before the spawner parked"

step "broken copy: the scheduler left in a build without the flag"
broken pointleft prelude.iyi '/^  {% if flag\?\(:iyi_chaos\) %}$/ && !done { print "  {% if true %}"; done = 1; next } { print }'
awk '{ sub(/\{% if flag\?\(:iyi_chaos\) %\}/, "{% if true %}"); print }' "$REPO/src/iyi/concurrency.iyi" > pointleft/iyi/concurrency.iyi
off_is_nothing "$WORK/pointleft" pointleft > pointleft.txt 2>&1
expect_caught pointleft "a plain build names the chaos scheduler"

echo "== the chaos scheduler: every check held"
