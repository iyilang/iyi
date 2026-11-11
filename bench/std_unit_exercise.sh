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
#      `spawn(unit: :new)`. On a pool of one, the same on the main thread,
#      and a `Unit`'s task spawned from an `IyiThread` runs on the main
#      thread with no pool started.
#   2. What the compiler refuses: a `spawn(in:)` block capturing what is
#      not Share, a task answering what is not Share, `Unit.new`'s block
#      capturing what is not Share, two placements at once, and a `Unit`'s
#      value reached from outside its tasks.
#   3. Broken copies, each caught at the check that names it. Of the
#      runtime, each a copy of src/iyi built against through IYI_PATH: a
#      `Unit` whose tasks each take a unit of their own (the token not
#      taken), and one whose tasks run on the spawner's thread on a pool
#      of one. Of the compiler, through `IYI_SPAWN_BROKEN`: the capture
#      check removed (`unit-capture`), and the answer check removed
#      (`unit-answer`).
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
  for run in "alone parks panic cost --workers=4" "alone parks panic --workers=1" "main --workers=1"; do
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
broken() { # name, awk program
  mkdir -p "$1/iyi"
  cp "$REPO"/src/iyi/*.iyi "$1/iyi/"
  awk "$2" "$REPO/src/iyi/concurrency.iyi" > "$1/iyi/concurrency.iyi"
  if cmp -s "$1/iyi/concurrency.iyi" "$REPO/src/iyi/concurrency.iyi"; then
    echo "the awk for $1 found nothing to change"; exit 1
  fi
  if ! IYI_PATH="$WORK/$1${PSEP}$REPO/src" "$IYI" build "$REPO/bench/std_unit_exercise.iyi" -o "$1-run" > "build-$1.log" 2>&1; then
    echo "the broken copy $1 failed to build:"; tail -20 "build-$1.log"; exit 1
  fi
}
# A run that ends any way but exit 1 at the sentence is run again, up to
# five times, as bench/spawn_eligible.sh's are.
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

step "failure proof: a Unit whose tasks do not take its token"
broken tokenless '/^        pooled\(owner\.iyi_unit, &work\)$/ { print "        pooled(IyiUnit.new, &work)"; next } { print }'
caught tokenless 'tasks of one Unit were running at one instant' alone --workers=4

step "failure proof: a Unit's tasks on the spawner's thread on a pool of one"
broken spawnerthread '/^      fiber.home = IyiScheduler.main_state$/ { print "      fiber.home = IyiScheduler.state"; next } { print }'
caught spawnerthread 'ran on the spawner'"'"'s thread on a pool of one' main --workers=1

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
