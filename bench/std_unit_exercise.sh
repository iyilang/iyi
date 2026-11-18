#!/usr/bin/env bash
# Exercises `std/unit` (SPEC.md III.4.18): a `Unit`'s tasks at run time,
# and the compiler's checks of every block that reaches its value.
#
#     bash bench/std_unit_exercise.sh
#
#   1. bench/std_unit_exercise.iyi, plain and --release: on four workers,
#      eight tasks of one `Unit` from two units run one at a time on pool
#      workers; a task that parks lets a unit-mate run and finds the value
#      changed when it resumes, in an order the channels fix; a task that
#      panics answers `Panicked` and the `Unit` runs its next four tasks;
#      and 10,000 tasks of one `Unit` are counted and timed beside 10,000
#      `spawn(unit: :new)`. With `-Dheap_partitions` (IYI_OPTS), sixteen
#      `Unit`s whose handles are let go while their tasks' are kept die at
#      a global collection. On a pool of one, the same on the main thread,
#      and a `Unit`'s task spawned from an `IyiThread` runs on the main
#      thread with no pool started.
#   2. What the compiler refuses: a `spawn(in:)` block capturing what is
#      not Share, a task answering what is not Share, `Unit.new`'s block
#      capturing what is not Share, two placements at once, and a `Unit`'s
#      value reached from outside its tasks.
#   3. Broken copies, each caught at the check that names it. Of the
#      runtime, each a copy of src/iyi built against through IYI_PATH: a
#      `Unit` whose tasks each take a unit of their own (the token not
#      taken), one whose tasks run on the spawner's thread on a pool of
#      one, and, with `-Dheap_partitions`, finished tasks' bodies kept
#      (`keptproc`: they name the handle, and no `Unit` dies) and, with
#      `-Dheap_verify` too, kept while naming the value (`keptbody`: the
#      verifier's report at the unit's death). Of the compiler, through
#      `IYI_SPAWN_BROKEN`: the capture check removed (`unit-capture`), and
#      the answer check removed (`unit-answer`). With `-Dheap_verify` in
#      IYI_OPTS a runtime copy is built twice: without it, the rest of
#      IYI_OPTS kept, where its own check is the one it must fail; and with
#      it, where it must fail its own check or exit 86 at the verifier's
#      report that names it (the tokenless copy's tasks leave the Unit's
#      value in units of their own, which the verifier finds at such a
#      unit's death).
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

trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

step() { echo "== $1"; }

# ── 1. The exercise ───────────────────────────────────────────────────────
for build in plain release; do
  step "a Unit's tasks at run time, $build build"
  flag=""
  [ "$build" = release ] && flag="--release"
  if ! "$IYI" build $flag "$REPO/bench/std_unit_exercise.iyi" -o "unit-$build" > "build-$build.log" 2>&1; then
    echo "build failed:"; tail -20 "build-$build.log"; exit 1
  fi
  for run in "alone parks panic cost --workers=4" "outlive --workers=4" "alone parks panic --workers=1" "main --workers=1"; do
    # shellcheck disable=SC2086 # the steps are words
    timeout -k 5 120 "./unit-$build" $run > "ran-$build.txt" 2>&1
    code=$?
    if [ "$code" -ne 0 ] || ! grep -q 'every property held' "ran-$build.txt"; then
      echo "the exercise failed (exit $code, $run):"; cat "ran-$build.txt"; exit 1
    fi
    grep -v 'every property held' "ran-$build.txt" | sed 's/^/  /'
  done
done

# ── 2. What the compiler refuses ──────────────────────────────────────────
step "what the compiler refuses"
refused() { # name, expected text, body; answers 1 when it compiled or said otherwise
  printf 'module %s\n\nimport std/unit::{Unit}\n\n%s\n' "$1" "$3" > "$1.iyi"
  if "$IYI" build --no-codegen -o "$1" "$1.iyi" > "$1.log" 2>&1; then
    echo "  $1 compiled"; return 1
  fi
  if ! grep -qF "$2" "$1.log"; then
    echo "  $1 was refused, but not saying \"$2\":"; grep -m1 'Error' "$1.log" | sed 's/^/    /'; return 1
  fi
  echo "  $1: $(grep -m1 -F "$2" "$1.log" | sed 's/^.*Error: //; s/^ *//' | cut -c1-150)"
}
CAPTURE_BODY='outside = [1, 2]
counts = Unit.new { [0] }
group do |g|
  g.spawn(in: counts) { |c| c.concat(outside); 0 }
end'
ANSWER_BODY='counts = Unit.new { [0] }
group do |g|
  leaked = g.spawn(in: counts) { |c| c }
end'
refused captured 'the block spawn(in: counts) runs in another unit captures `outside : Array(Int32)`, which is not Share' "$CAPTURE_BODY" || exit 1
refused answered 'spawn(in: counts) answers `Array(Int32)`, which is not Share' "$ANSWER_BODY" || exit 1
refused handed_in 'the block Unit.new makes the Unit'"'"'s value in captures `outside : Array(Int32)`, which is not Share' \
'outside = [1]
counts = Unit.new { outside }' || exit 1
refused both 'a spawn is placed one way' \
'counts = Unit.new { [0] }
group do |g|
  g.spawn(in: counts, unit: :new) { |c| c.size }
end' || exit 1
refused reached 'protected method '"'"'iyi_value'"'"' called' \
'counts = Unit.new { [0] }
counts.iyi_value << 1' || exit 1

# ── 3. Broken copies ──────────────────────────────────────────────────────
# Of the runtime: a copy of src/iyi with concurrency.iyi changed by awk.
# `-Dheap_verify` ends a copy at its report (exit 86) before the copy's
# own check can fail, so the own check's build leaves it out; with it in
# IYI_OPTS, the copy is built with it as well (`$1-verify`).
VERIFY=0
PARTITIONS=0
OWN_OPTS=""
for opt in ${IYI_OPTS:-}; do
  [ "$opt" = -Dheap_partitions ] && PARTITIONS=1
  if [ "$opt" = -Dheap_verify ]; then VERIFY=1; else OWN_OPTS="${OWN_OPTS:+$OWN_OPTS }$opt"; fi
done
broken() { # name, awk program
  mkdir -p "$1/iyi"
  cp "$REPO"/src/iyi/*.iyi "$1/iyi/"
  if ! awk "$2" "$REPO/src/iyi/concurrency.iyi" > "$1/iyi/concurrency.iyi" ||
     cmp -s "$1/iyi/concurrency.iyi" "$REPO/src/iyi/concurrency.iyi"; then
    echo "the awk for $1 did not find every line it changes"; exit 1
  fi
  if ! IYI_OPTS="$OWN_OPTS" IYI_PATH="$WORK/$1${PSEP}$REPO/src" "$IYI" build "$REPO/bench/std_unit_exercise.iyi" -o "$1-run" > "build-$1.log" 2>&1; then
    echo "the broken copy $1 failed to build:"; tail -20 "build-$1.log"; exit 1
  fi
  if [ "$VERIFY" = 1 ] &&
     ! IYI_PATH="$WORK/$1${PSEP}$REPO/src" "$IYI" build "$REPO/bench/std_unit_exercise.iyi" -o "$1-verify" > "build-$1-verify.log" 2>&1; then
    echo "the broken copy $1 failed to build with -Dheap_verify:"; tail -20 "build-$1-verify.log"; exit 1
  fi
}
# A run that ends any way but exit 1 at the sentence is run again, up to
# five times, as bench/spawn_eligible.sh's are. The `-Dheap_verify` build
# is caught by the same sentence, or by exit 86 with the report's line
# that names the copy (none: the sentence alone).
caught() { # name, expected FAIL text, verifier's report line, step arguments...
  local name="$1" want="$2" report="$3" code attempt how
  shift 3
  for attempt in 1 2 3 4 5; do
    timeout -k 5 120 "./$name-run" "$@" > "$name.txt" 2>&1
    code=$?
    [ "$code" -eq 1 ] && grep -qF "$want" "$name.txt" && break
  done
  if [ "$code" -ne 1 ] || ! grep -qF "$want" "$name.txt"; then
    echo "the broken copy $name was not caught at \"$want\" (exit $code):"; tail -20 "$name.txt"; exit 1
  fi
  echo "  exits 1 at \"$(grep -m1 -F "$want" "$name.txt" | sed 's/^FAIL: //')\"${OWN_OPTS:+ ($OWN_OPTS)}"
  [ "$VERIFY" = 1 ] || return 0
  for attempt in 1 2 3 4 5; do
    timeout -k 5 120 "./$name-verify" "$@" > "$name-verify.txt" 2>&1
    code=$?
    if [ "$code" -eq 1 ] && grep -qF "$want" "$name-verify.txt"; then
      how="exits 1 at \"$(grep -m1 -F "$want" "$name-verify.txt" | sed 's/^FAIL: //')\""; break
    fi
    if [ -n "$report" ] && [ "$code" -eq 86 ] && grep -q "^iyi: heap_verify: partition " "$name-verify.txt" &&
       grep -qxF "  $report" "$name-verify.txt"; then
      how="exits 86 at the verifier's \"$report\""; break
    fi
  done
  if [ -z "${how:-}" ]; then
    [ -n "$report" ] && want="$want\" or the verifier's \"$report"
    echo "the broken copy $name built with -Dheap_verify was not caught at \"$want\" (exit $code):"
    tail -20 "$name-verify.txt"; exit 1
  fi
  echo "  with -Dheap_verify: $how"
}

step "failure proof: a Unit whose tasks do not take its token"
broken tokenless '/^        pooled\(owner\.iyi_unit, &work\)$/ { print "        pooled(IyiUnit.new, &work)"; next } { print }'
caught tokenless 'tasks of one Unit were running at one instant' "at its unit's death, a slot names one of its LOCAL chunks, about to be freed" alone --workers=4

step "failure proof: a Unit's tasks on the spawner's thread on a pool of one"
broken spawnerthread '/^        fiber.home = IyiScheduler.main_state$/ { print "        fiber.home = IyiScheduler.state"; next } { print }'
caught spawnerthread 'ran on the spawner'"'"'s thread on a pool of one' '' main --workers=1

# A reaped fiber lets its block go (`fiber.proc = nil` in
# `IyiScheduler.unregister`), so what a finished task of a `Unit` ran
# names nothing once it is done; the copies keep it, as a stale word would
# (tmac: a release build's panic step, 34 runs of 35 before the body named
# the handle). Kept, the body names the `Unit`'s handle, and the handle
# keeps the unit: none of outlive's Units dies (`keptproc`, its own
# check). With the body naming the value instead, as it did, the units die
# while their kept bodies name their values, which only `-Dheap_verify`
# sees (`keptbody`, its report at the unit's death).
KEEPPROC='/^        fiber\.proc = nil$/ { kept++; next }'
KEEPEND='{ print } END { if (kept != 1) exit 3 }'
step "failure proof: a Unit task's body kept after it finished names the Unit's handle"
if [ "$PARTITIONS" = 1 ]; then
  broken keptproc "$KEEPPROC $KEEPEND"
  caught keptproc 'Units died in 200 global collections after their handles were let go' '' outlive --workers=4
else
  echo "  not run without -Dheap_partitions: a Unit has no partition to die"
fi
step "failure proof: a Unit task's body kept after it finished names the Unit's value"
if [ "$VERIFY" = 1 ] && [ "$PARTITIONS" = 1 ]; then
  broken keptbody "$KEEPPROC"'
    /^    work = IyiCross\.shared \{ unit_work\(block, owner, pinned\) \}$/ { print "    work = IyiCross.shared { unit_work(block, owner.iyi_value, pinned) }"; kept++; next }
    /^  private def unit_work\(block : S -> T, owner : Unit\(S\), pinned : Bool\) : Proc\(T\) forall S, T$/ { print "  private def unit_work(block : S -> T, value : S, pinned : Bool) : Proc(T) forall S, T"; kept++; next }
    /^      answer = block\.call\(owner\.iyi_value\)$/ { print "      answer = block.call(value)"; kept++; next }
    { print } END { if (kept != 4) exit 3 }'
  want="at its unit's death, a slot names one of its LOCAL chunks, about to be freed"
  for attempt in 1 2 3 4 5; do
    timeout -k 5 120 ./keptbody-verify outlive --workers=4 > keptbody-verify.txt 2>&1
    code=$?
    [ "$code" -eq 86 ] && grep -q "^iyi: heap_verify: partition " keptbody-verify.txt && grep -qxF "  $want" keptbody-verify.txt && break
  done
  if [ "$code" -ne 86 ] || ! grep -qxF "  $want" keptbody-verify.txt; then
    echo "the broken copy keptbody was not caught at the verifier's \"$want\" (exit $code):"; tail -20 keptbody-verify.txt; exit 1
  fi
  echo "  with -Dheap_verify: exits 86 at the verifier's \"$want\""
else
  echo "  not run without -Dheap_partitions -Dheap_verify: only the verifier sees a body name a freed value"
fi

# Of the compiler: `IYI_SPAWN_BROKEN` turns one check off each, and the
# program it refused compiles.
compiles() { # name, broken mechanism, body
  printf 'module %s\n\nimport std/unit::{Unit}\n\n%s\n' "$1" "$3" > "$1.iyi"
  if IYI_SPAWN_BROKEN="$2" "$IYI" build --no-codegen -o "$1" "$1.iyi" > "$1.log" 2>&1; then
    echo "  caught: with IYI_SPAWN_BROKEN=$2, $1.iyi compiles"
  else
    echo "the broken copy $2 was not caught: $1.iyi is still refused:"; cat "$1.log"; exit 1
  fi
}
step "failure proof: the capture check removed"
compiles captured_broken unit-capture "$CAPTURE_BODY"
step "failure proof: the answer check removed"
compiles answered_broken unit-answer "$ANSWER_BODY"

echo "== std/unit: every check held"
