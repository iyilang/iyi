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
#      built once and run PLAIN_RUNS times on one worker (IYI_WORKERS=1),
#      every run passing.
#   3. Caught, with a seed that reproduces: `iyi test --chaos=1
#      --chaos-runs 100` fails each test at its pinned seed (6 for the
#      claim, 42 for the join), naming the seed and the `--chaos=SEED` that
#      runs it again; that line fails again; and the program built for
#      chaos, run five times on the seed with IYI_CHAOS_TRACE, prints the
#      same output and schedule hash five times, failing each.
#   4. A drawn seed: `iyi test --chaos --chaos-runs 200` on a test that
#      fails on every seed fails at run 1 of 200 whichever seed the clock
#      draws, names that seed, and the seed fails again.
#   5. One seed, one schedule; many seeds, many: bench/chaos_exercise.iyi
#      under seeds 1 to 30, twice each, holds every property each time,
#      each seed's two runs print the same lines and schedule, the 30 meet
#      at least 20 orders and both arms of a `select`, and parallel units,
#      and a `Unit`'s tasks (SPEC.md III.4.18), start before the spawner
#      parks under some seeds and not others.
#   6. Broken copies of the scheduler, each caught at the check that names
#      it: the stream ignored (every draw 0, which is the plain
#      scheduler's choice everywhere) finds neither bug; a copy that
#      consumes seed 1 but uses 2 for both streams takes seed 2's schedule;
#      units ignored (any task chosen, a unit-mate's
#      included) runs a task between a unit-mate's operations or before
#      its spawner parks; parallel tasks left in their spawner's unit
#      never start before it parks; a `Unit`'s tasks given a chaos unit
#      each run between each other's operations; a `Unit`'s tasks given
#      none, left in the spawner's, never start before it parks; and a
#      point left in a build without the flag names the scheduler in its IR.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
EXE=""
PLAIN_RUNS="${PLAIN_RUNS-40}"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    EXE=".exe"
    PATH_WINDOWS=1
    ;;
  *) PSEP=':'; PATH_WINDOWS=0 ;;
esac

cd "$WORK" || exit 1

step() { echo "== $1"; }
die() { echo "FAIL: $*"; exit 1; }
case "$PLAIN_RUNS" in
  ''|*[!0-9]*) die "PLAIN_RUNS must be a positive integer" ;;
esac
case "$PLAIN_RUNS" in
  *[1-9]*) ;;
  *) die "PLAIN_RUNS must be a positive integer" ;;
esac

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
# code answered. A chaos seed names one schedule only with one worker.
chaos_test() { # prelude, log, iyi test arguments...
  local prelude="$1" log="$2"
  shift 2
  if [ -n "$prelude" ]; then
    IYI_WORKERS=1 IYI_PATH="$prelude${PSEP}$REPO/src" timeout -k 5 900 "$IYI" test "$@" > "$log" 2>&1
  else
    IYI_WORKERS=1 timeout -k 5 900 "$IYI" test "$@" > "$log" 2>&1
  fi
}

# The sweep checks CLI search behaviour, not mutant detection. Seeds 6 and
# 42 are canaries for this build's scheduler, not compatibility promises.
#
# After the fixture's verdict the only child evidence must be its trace.
# A death description, even one unknown to this gate, cannot be
# mistaken for a normal exit. Build diagnostics before the verdict are
# allowed, since the compiler may emit linker warnings.
# The CLI prints its reproduce line only after the child's evidence ends.
normal_failure() { # log, fixture verdict, source, seed, run, total
  local log="$1" verdict="$2" source="$3" seed="$4" run="$5" total="$6"
  CHAOS_SOURCE="$source" awk -v verdict="  $verdict" -v seed="$seed" -v run="$run" -v total="$total" -v windows="$PATH_WINDOWS" '
    BEGIN { source = ENVIRON["CHAOS_SOURCE"] }
    {
      line = $0
      if (windows) gsub(/\\/, "/", line)
      if (line == source ": fail (chaos seed " seed ", run " run " of " total ")") {
        if (header++ || stage) exit 1
        next
      }
      if (line == verdict) {
        if (header != 1 || stage || seen++) exit 1
        stage = 1
        next
      }
      if (stage == 1) {
        if (line !~ ("^  iyi chaos: seed " seed ", .*schedule [0-9a-f]+$")) exit 1
        stage = 2
        next
      }
      if (stage == 2) {
        suffix = " test --chaos=" seed " " source
        if (line !~ /^  reproduce: / || substr(line, length(line) - length(suffix) + 1) != suffix) exit 1
        stage = 3
      }
    }
    END { if (header != 1 || seen != 1 || stage != 3) exit 1 }
  ' "$log"
}
caught() { # prelude, label, source, expected seed, exact fixture verdict
  local prelude="$1" label="$2" source="$3" want_seed="$4" verdict="$5" code seed first got
  IYI_CHAOS_TRACE=1 chaos_test "$prelude" "catch-$label.txt" --chaos=1 --chaos-runs 100 "$source"
  code=$?
  if [ "$code" -ne 1 ] || ! normal_failure "catch-$label.txt" "$verdict" "$source" "$want_seed" "$want_seed" 100; then
    echo "$label: search did not end at its fixture verdict (exit $code):"; tail -20 "catch-$label.txt"; return 1
  fi
  seed="$want_seed"
  IYI_CHAOS_TRACE=1 chaos_test "$prelude" "again-$label.txt" "--chaos=$seed" "$source"
  code=$?
  if [ "$code" -ne 1 ] || ! normal_failure "again-$label.txt" "$verdict" "$source" "$seed" 1 1; then
    echo "$label: --chaos=$seed did not fail again (exit $code):"; tail -5 "again-$label.txt"; return 1
  fi
  build "traced-$label" "$prelude" "$source" -Diyi_chaos || { echo "$label: the chaos build failed:"; tail -20 "build-traced-$label.log"; return 1; }
  first=""
  for attempt in 1 2 3 4 5; do
    IYI_CHAOS="$seed" IYI_CHAOS_TRACE=1 IYI_WORKERS=1 timeout -k 5 120 "./traced-$label$EXE" > "traced-$label-$attempt.txt" 2>&1
    code=$?
    { [ "$code" -eq 1 ] && grep -qxF "$verdict" "traced-$label-$attempt.txt"; } || { echo "$label: seed $seed did not exit 1 at its fixture verdict (exit $code):"; cat "traced-$label-$attempt.txt"; return 1; }
    if [ -z "$first" ]; then
      first="traced-$label-$attempt.txt"
    elif ! cmp -s "$first" "traced-$label-$attempt.txt"; then
      echo "$label: seed $seed ran two schedules:"; cat "$first" "traced-$label-$attempt.txt"; return 1
    fi
  done
  got="$(sed -n 's/.*schedule \([0-9a-f][0-9a-f]*\)$/\1/p' "$first" | head -1)"
  [ -n "$got" ] || { echo "$label: missing schedule hash"; return 1; }
  echo "  $label: caught at seed $seed, again through --chaos=$seed, and five traced runs alike on schedule ${got:-none}:"
  sed 's/^/    /' "$first"
}

# Step 5 under one prelude: answers 1, saying why, when a property fails.
seeds() { # prelude, label
  local prelude="$1" label="$2" seed orders early late unit_early unit_late lefts rights
  build "exercise-$label" "$prelude" "$REPO/bench/chaos_exercise.iyi" -Diyi_chaos || { echo "$label: the exercise did not build:"; tail -20 "build-exercise-$label.log"; return 1; }
  : > "orders-$label.txt"
  early=0
  late=0
  unit_early=0
  unit_late=0
  for seed in $(seq 1 30); do
    for twice in a b; do
      IYI_CHAOS="$seed" IYI_CHAOS_TRACE=1 IYI_WORKERS=1 timeout -k 5 120 "./exercise-$label$EXE" > "seed-$label-$seed-$twice.txt" 2>&1
      code=$?
      if [ "$code" -ne 0 ] || ! grep -qxF "every property held" "seed-$label-$seed-$twice.txt"; then
        echo "$label: seed $seed: $(grep -m1 FAIL "seed-$label-$seed-$twice.txt" || tail -3 "seed-$label-$seed-$twice.txt")"; return 1
      fi
    done
    if ! cmp -s "seed-$label-$seed-a.txt" "seed-$label-$seed-b.txt"; then
      echo "$label: seed $seed's two runs differ:"; diff "seed-$label-$seed-a.txt" "seed-$label-$seed-b.txt"; return 1
    fi
    grep "^order " "seed-$label-$seed-a.txt" >> "orders-$label.txt"
    if grep -q "parallel units started before the spawner parked: 0$" "seed-$label-$seed-a.txt"; then
      late=$((late + 1))
    else
      early=$((early + 1))
    fi
    if grep -q "^Unit tasks started before the spawner parked: 0$" "seed-$label-$seed-a.txt"; then
      unit_late=$((unit_late + 1))
    else
      unit_early=$((unit_early + 1))
    fi
  done
  orders="$(sort -u "orders-$label.txt" | wc -l | tr -d ' ')"
  lefts="$(cat seed-"$label"-*-a.txt | grep -c "^left arms [1-3] of 3")"
  rights="$(cat seed-"$label"-*-a.txt | grep -c "^left arms [0-2] of 3")"
  [ "$early" -gt 0 ] || { echo "$label: no seed started a parallel unit before the spawner parked"; return 1; }
  [ "$late" -gt 0 ] || { echo "$label: every seed started a parallel unit before the spawner parked"; return 1; }
  [ "$unit_early" -gt 0 ] || { echo "$label: no seed started a Unit's task before the spawner parked"; return 1; }
  [ "$unit_late" -gt 0 ] || { echo "$label: every seed started a Unit's task before the spawner parked"; return 1; }
  [ "$orders" -ge 20 ] || { echo "$label: 30 seeds met $orders orders, not 20"; return 1; }
  [ "$lefts" -gt 0 ] && [ "$rights" -gt 0 ] || { echo "$label: a select took one arm only ($lefts runs with a left arm, $rights with a right)"; return 1; }
  echo "  $label: 30 seeds, each run twice alike: $orders orders, a parallel unit started before the spawner parked under $early seeds and not under $late, a Unit's task under $unit_early and not under $unit_late"
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
# One worker, so that a plain run's outcome does not depend on how the
# pool's threads interleave. Every run must pass: a failing run is a
# finding, not a run to tolerate.
for test in claim join; do
  step "bench/chaos_$test.iyi passes without --chaos, on one worker"
  build "plain-$test" "" "$REPO/bench/chaos_$test.iyi" || die "the plain build failed: $(tail -20 "build-plain-$test.log")"
  failed=0
  for run in $(seq 1 "$PLAIN_RUNS"); do
    IYI_WORKERS=1 timeout -k 5 120 "./plain-$test$EXE" > "plain-$test-$run.txt" 2>&1 || failed=$((failed + 1))
  done
  echo "  failed $failed of $PLAIN_RUNS runs on one worker"
  [ "$failed" -eq 0 ] || die "chaos_$test failed $failed of $PLAIN_RUNS plain runs: $(cat plain-"$test"-*.txt | sort | uniq -c)"
done

# ── 3. Caught, with a seed that reproduces ────────────────────────────────
step "iyi test --chaos catches each bug at its pinned seed, and that seed runs the schedule again"
caught "" claim "$REPO/bench/chaos_claim.iyi" 6 "two leaders: 2 tasks found the slot empty, and task 1 wrote last" || exit 1
caught "" join "$REPO/bench/chaos_join.iyi" 42 "the reader saw 0, before the writer that adds 42 had run (work 4)" || exit 1

# ── 4. A drawn seed ───────────────────────────────────────────────────────
step "a seed drawn by iyi test, named and run again"
# A test that fails on every seed: the drawn seed fails at run 1 of 200
# whichever seed the clock draws, so what is checked is that the seed is
# named and fails again.
cat > "$WORK/fails_every_seed.iyi" <<'IYI'
module chaos_fails_every_seed

print "fails on every seed\n"
exit(1)
IYI
IYI_CHAOS_TRACE=1 chaos_test "" drawn.txt --chaos --chaos-runs 200 "$WORK/fails_every_seed.iyi"
code=$?
[ "$code" -eq 1 ] || die "a test that fails on every seed did not fail under 200 drawn seeds (exit $code): $(tail -3 drawn.txt)"
seed="$(CHAOS_SOURCE="$WORK/fails_every_seed.iyi" awk -v windows="$PATH_WINDOWS" '
  BEGIN { prefix = ENVIRON["CHAOS_SOURCE"] ": fail (chaos seed " }
  {
    line = $0
    if (windows) gsub(/\\/, "/", line)
    if (substr(line, 1, length(prefix)) != prefix) next
    rest = substr(line, length(prefix) + 1)
    if (rest !~ /^[0-9]+, run 1 of 200\)$/) next
    sub(/, run 1 of 200\)$/, "", rest)
    seed = rest
    count++
  }
  END { if (count != 1) exit 1; print seed }
' drawn.txt)" || die "drawn test has no unique fixture failure header: $(tail -20 drawn.txt)"
normal_failure drawn.txt "fails on every seed" "$WORK/fails_every_seed.iyi" "$seed" 1 200 || die "drawn test did not exit normally with effective seed $seed: $(tail -20 drawn.txt)"
grep -qF "(chaos seed $seed, run 1 of 200)" drawn.txt || die "the drawn seed $seed was not run 1 of 200: $(grep -m1 'chaos seed' drawn.txt)"
IYI_CHAOS_TRACE=1 chaos_test "" drawn-again.txt "--chaos=$seed" "$WORK/fails_every_seed.iyi"
code=$?
[ "$code" -eq 1 ] || die "the drawn seed $seed did not fail again (exit $code): $(tail -3 drawn-again.txt)"
normal_failure drawn-again.txt "fails on every seed" "$WORK/fails_every_seed.iyi" "$seed" 1 1 || die "drawn replay did not exit normally with effective seed $seed: $(tail -20 drawn-again.txt)"
grep -qF "(chaos seed $seed, run 1 of 1)" drawn-again.txt || die "--chaos=$seed did not run one seed: $(grep -m1 'chaos seed' drawn-again.txt)"
echo "  drawn seed $seed failed at run 1 of 200, and --chaos=$seed failed again"

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
  awk "$3" "$REPO/src/iyi/$2" > "$1/iyi/$2" || { echo "the awk for $1 failed"; exit 1; }
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
broken prngignored chaos.iyi '/^  def self.draw : UInt64$/ { n++; print; print "    return 0_u64"; next } { print } END { if (n != 1) exit 3 }' || die "prngignored anchor missing or ambiguous"
for test in claim join; do
  case "$test" in
    claim) seed=6; verdict="one leader: task 1" ;;
    join) seed=42; verdict="the reader saw 42 (work 4)" ;;
  esac
  build "prng-$test" "$WORK/prngignored" "$REPO/bench/chaos_$test.iyi" -Diyi_chaos || die "prngignored $test build failed: $(tail -20 "build-prng-$test.log")"
  IYI_CHAOS="$seed" IYI_WORKERS=1 timeout -k 5 120 "./prng-$test$EXE" > "prng-$test.txt" 2>&1
  code=$?
  [ "$code" -eq 0 ] && grep -qxF "$verdict" "prng-$test.txt" || die "prngignored $test did not exit 0 at '$verdict' (exit $code): $(tail -20 "prng-$test.txt")"
  echo "  prngignored $test: seed $seed exited 0 at $verdict"
done

step "broken copy: the seed consumed but both streams use the next seed"
broken seedignored chaos.iyi '/^    IyiStat\.set\(IyiStat::CHAOS_STREAM, seed\)$/ { n++; print "    IyiStat.set(IyiStat::CHAOS_STREAM, seed &+ 1_u64)"; next } /value = IyiStat.get\(IyiStat::CHAOS_SEED\) \^ mix/ { m++; sub(/IyiStat.get\(IyiStat::CHAOS_SEED\)/, "(IyiStat.get(IyiStat::CHAOS_SEED) \\&+ 1_u64)"); print; next } { print } END { if (n != 1 || m != 1) exit 3 }' || die "seedignored anchor missing or ambiguous"
build exercise-seedignored "$WORK/seedignored" "$REPO/bench/chaos_exercise.iyi" -Diyi_chaos || die "seedignored build failed: $(tail -20 build-exercise-seedignored.log)"
IYI_CHAOS=1 IYI_CHAOS_TRACE=1 IYI_WORKERS=1 timeout -k 5 120 "./exercise-seedignored$EXE" > seedignored.txt 2>&1
code=$?
[ "$code" -eq 0 ] && grep -qxF "every property held" seedignored.txt || die "seedignored fixture verdict missing (exit $code): $(tail -20 seedignored.txt)"
grep -q '^iyi chaos: seed 1, ' seedignored.txt || die "seedignored did not consume supplied seed 1"
sed 's/^iyi chaos: seed [0-9]*,/iyi chaos: seed,/' seedignored.txt > seedignored-normalized.txt
sed 's/^iyi chaos: seed [0-9]*,/iyi chaos: seed,/' seed-shipped-2-a.txt > seed2-normalized.txt
sed 's/^iyi chaos: seed [0-9]*,/iyi chaos: seed,/' seed-shipped-1-a.txt > seed1-normalized.txt
! cmp -s seed1-normalized.txt seed2-normalized.txt || die "seedignored witness unarmed: healthy seeds 1 and 2 have identical schedules"
cmp -s seedignored-normalized.txt seed2-normalized.txt || die "seedignored did not run seed 2's schedule: $(diff seed2-normalized.txt seedignored-normalized.txt)"
echo "  seedignored consumed seed 1 and ran seed 2's schedule"

# Each copy runs one seed. The healthy seed 2 must witness both early starts.
grep -qE '^left arms [0-3] of 3, parallel units started before the spawner parked: [1-9][0-9]*$' seed-shipped-2-a.txt || die "parallel early-start witness was not armed"
grep -qE '^Unit tasks started before the spawner parked: [1-9][0-9]*$' seed-shipped-2-a.txt || die "Unit early-start witness was not armed"
mutant_run() { # name, seed, expected exit, exact verdict
  local name="$1" seed="$2" want_code="$3" verdict="$4" code
  build "exercise-$name" "$WORK/$name" "$REPO/bench/chaos_exercise.iyi" -Diyi_chaos || die "$name build failed: $(tail -20 "build-exercise-$name.log")"
  IYI_CHAOS="$seed" IYI_CHAOS_TRACE=1 IYI_WORKERS=1 timeout -k 5 120 "./exercise-$name$EXE" > "$name.txt" 2>&1
  code=$?
  if [ "$name" = leftinunit ]; then
    [ "$code" -eq "$want_code" ] && grep -qxE "$verdict" "$name.txt" || die "$name seed $seed did not exit $want_code at its early-start verdict (exit $code): $(tail -20 "$name.txt")"
  else
    [ "$code" -eq "$want_code" ] && grep -qxF "$verdict" "$name.txt" || die "$name seed $seed did not exit $want_code at '$verdict' (exit $code): $(tail -20 "$name.txt")"
  fi
  echo "  $name seed $seed: $verdict"
}

step "broken copy: units ignored, a unit-mate chosen like any task"
broken unitsignored chaos.iyi '/^      if unit.stamp != generation$/ { n++; print "      if true"; next } { print } END { if (n != 1) exit 3 }'
mutant_run unitsignored 2 1 "FAIL: a task of the spawner's unit ran before the spawner parked"

step "broken copy: a parallel task left in its spawner's unit"
broken leftinunit chaos.iyi '/^    task.fiber.chaos_unit = IyiCross.shared \{ IyiChaosUnit.new\(IyiStat.get\(IyiStat::CHAOS_UNITS\), fresh_priority\) \}$/ { n++; next } { print } END { if (n != 1) exit 3 }'
mutant_run leftinunit 2 0 "left arms [0-3] of 3, parallel units started before the spawner parked: 0"
grep -qxF "every property held" leftinunit.txt || die "leftinunit fixture did not finish normally"

step "broken copy: a Unit's tasks each given a chaos unit of their own"
broken unitsplit chaos.iyi '/^    unless unit.is_a\?\(IyiChaosUnit\)$/ { n++; print "    unless false"; next } { print } END { if (n != 1) exit 3 }'
mutant_run unitsplit 4 1 "FAIL: tasks of one Unit ran between each other's operations 1 times"

step "broken copy: a Unit's tasks left in their spawner's unit"
broken unitleft chaos.iyi '/^    fiber.chaos_unit = unit$/ { n++; print "    fiber.chaos_unit = unit_of(IyiScheduler.current)"; next } { print } END { if (n != 1) exit 3 }'
mutant_run unitleft 2 0 "Unit tasks started before the spawner parked: 0"
grep -qxF "every property held" unitleft.txt || die "unitleft fixture did not finish normally"

step "broken copy: the scheduler left in a build without the flag"
broken pointleft prelude.iyi 'NR > 1 { if ($0 == "    require \"./chaos\"") { if (prev != "  {% if flag?(:iyi_chaos) %}") exit 3; prev = "  {% if true %}"; n++ } print prev } { prev = $0 } END { if (NR) print prev; if (n != 1) exit 3 }'
# Loading chaos also needs each gated concurrency support block. Check each
# block by its first line and multiplicity, not only a combined count.
awk '
  BEGIN {
    expected["# The unit the chaos scheduler counts this fiber in, and whether it"] = 1
    expected["fiber.homebound = true if IyiChaos.kept?(fiber)"] = 1
    expected["fiber = IyiChaos.pick(st)"] = 1
    expected["IyiChaos.at_idle"] = 1
    expected["return chaos_wake_on(word, count) if IyiChaos.chooses_wakes?"] = 1
    expected["drawn = IyiChaos.steal_start(count)"] = 1
    expected["return if IyiChaos.back_edge"] = 1
    expected["return give_up(st, fiber) if !fiber.homebound && IyiChaos.forced_turn?"] = 1
    expected["IyiChaos.report"] = 1
    expected["IyiChaos.point"] = 11
    expected["# Its tasks\047 chaos unit, made at its first task (`IyiChaos.adopt_into`)."] = 1
    expected["IyiChaos.adopt(fiber)"] = 1
    expected["return chaos_task(pinned, &block) if IyiChaos.simulated?"] = 2
    expected["IyiChaos.adopt_into(fiber, owner)"] = 1
    expected["# The chaos scheduler\047s arm tried first (SPEC.md III.4.17); the"] = 1
    expected["chaos_arm = IyiChaos.arm({{ U.size }})"] = 1
  }
  NR > 1 {
    if (prev ~ /\{% if flag\?\(:iyi_chaos\) %\}/) {
      key = $0
      sub(/^[[:space:]]*/, "", key)
      if (!(key in expected)) exit 3
      found[key]++
      sub(/\{% if flag\?\(:iyi_chaos\) %\}/, "{% if true %}", prev)
    }
    print prev
  }
  { prev = $0 }
  END {
    if (NR) print prev
    for (key in expected) if (found[key] != expected[key]) exit 3
  }
' "$REPO/src/iyi/concurrency.iyi" > pointleft/iyi/concurrency.iyi || die "pointleft concurrency support anchor missing or ambiguous"
off_is_nothing "$WORK/pointleft" pointleft > pointleft.txt 2>&1
expect_caught pointleft "a plain build names the chaos scheduler"

echo "== the chaos scheduler: every check held"
