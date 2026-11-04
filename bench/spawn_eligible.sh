#!/usr/bin/env bash
# Where a `spawn` runs (SPEC.md III.4.15, III.4.16): one verb. Written
# plain, in parallel where the compiler can prove it safe and in its
# spawner's unit otherwise; `parallel: true` asks for the pool and
# `serial: true` for the unit; and a spawn kept in its unit, or moved
# by a change elsewhere, is said where the author looks.
#
#     bash bench/spawn_eligible.sh
#
#   1. bench/spawn_eligible.iyi, plain and --release, on four workers:
#      four spawns whose blocks capture only atomics are all running at
#      one instant, from the main thread and from inside a parallel task;
#      four that append to their parent's `Array` stay in its unit, one at
#      a time; four `spawn(serial: true)` tasks that capture only atomics
#      stay in theirs; and four `spawn(parallel: true)` tasks are all
#      running at one instant. On a pool of one, eligible spawns stay on
#      the main thread and no pool starts, while `spawn(parallel: true)`
#      tasks run on the pool's worker. On a pool of four, in a process of
#      its own, one spawn starts one worker, spawns joined one at a time at
#      most three, and four tasks running at one instant all four.
#   2. The explanation: `--explain-spawn` notes each spawn, naming the
#      capture that kept one in its unit - a captured `Array`, a local
#      assigned in the loop that spawns, a constant reached through a call
#      - and a constant marked `@[SafeReach]` keeps nothing serial; a
#      spawn that spelled its placement is noted as asked. Notes are not
#      warnings: `--error-on-warnings` passes and `-f json` marks them
#      `"severity": "note"`. Unasked, `iyi check` notes each spawn the
#      compiler kept in its unit and no other, and `iyi build` prints
#      nothing.
#   3. The one verb: `spawn_parallel` and `spawn_serial`, on a group and in
#      a typed group, are compile errors naming the new spelling; `iyi fix`
#      rewrites both, and the program runs. `parallel: false`, a value the
#      compiler cannot read, both arguments at once, and a capture that is
#      not Share under `parallel: true` are refused.
#   4. The cliff, said: a spawn kept in its unit by a type another module
#      declares names that module and the field; and a rebuild that moves
#      a spawn of a module's artifact, because the module it imports
#      changed, prints one line naming the spawn, each way, and nothing
#      when nothing moved. `iyi mod dump` lists the artifact's spawns.
#      Across an artifact (SPEC.md III.4.15): a spawn whose block calls a
#      function of a module read from its `.iyimod`, which has no bodies,
#      is placed by what the artifact recorded that function reaches: one
#      that appends to the module's unguarded `Array` stays in its unit
#      and loses no append on four workers, one that reads state under a
#      `@[SafeReach]` only the module's initialiser writes runs in
#      parallel, and one that reaches state under a claim the producing
#      program proved of its own calls stays in its unit, through a call
#      or through a body that travelled.
#   5. Failure proofs against broken copies, each caught at the named
#      check. Of the runtime: an eligible spawn left in its unit, an
#      ineligible one sent to the pool, `serial: true` sent to the pool,
#      `parallel: true` left in the unit, `spawn_parallel` kept as an
#      alias, a pool of one that starts for eligible spawns anyway, a pool
#      that starts every worker at once, and one that never starts a
#      second. Of the compiler, through `IYI_SPAWN_BROKEN`: no module named
#      in a reason, no note from `iyi check` unasked, no line for a moved
#      spawn, `spawn_parallel` answered as any undefined method, an
#      artifact written without what its functions reach (whose consumer
#      must keep every spawn calling into it in its unit, naming the
#      module), a function read from an artifact taken to reach nothing,
#      and an artifact that takes every proven claim to hold for every
#      importer.
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
  for run in "together nested unit serial asked --workers=4" "one --workers=1" "askedone --workers=1" "grows --workers=4"; do
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
  g.spawn(serial: true) { done.add(1) }
  g.spawn(parallel: true) { done.add(1) }
end
IYI
explain() { # log, line, expected text
  if ! grep -F "explained.iyi:$2:" "$1" | grep -qF "$3"; then
    echo "line $2 was not noted with \"$3\":"; cat "$1"; exit 1
  fi
  echo "  line $2: $(grep -m1 -F "explained.iyi:$2:" "$1" | sed 's/^.*note: //' | cut -c1-160)"
}
if ! "$IYI" check --explain-spawn --error-on-warnings explained.iyi > explain.log 2>&1; then
  echo "check --explain-spawn --error-on-warnings failed a program with no warning:"; cat explain.log; exit 1
fi
explain explain.log 29 'spawn runs in parallel'
explain explain.log 30 'spawn stays in its spawner'"'"'s unit: the block captures `log : Array(Int32)`, which is not Share'
explain explain.log 31 'the block reaches the constant `LEDGER : Explained::Ledger` through `record` → `LEDGER.add`'
explain explain.log 32 'spawn runs in parallel'
explain explain.log 35 'line 36: `i` is assigned here, in a loop or a block that spawns the task again'
explain explain.log 38 'spawn stays in its spawner'"'"'s unit: `serial: true` keeps it there'
explain explain.log 39 'spawn runs in parallel: `parallel: true` asks for it'
if grep -q 'Warning' explain.log; then
  echo "a plain spawn was warned about:"; cat explain.log; exit 1
fi
if ! "$IYI" check --explain-spawn -f json explained.iyi > explain.json 2>&1 \
  || [ "$(grep -o '"severity":"note"' explain.json | wc -l | tr -d ' ')" != 7 ]; then
  echo "-f json did not carry the seven notes as \"severity\": \"note\":"; cat explain.json; exit 1
fi
echo "  -f json: seven frames marked \"severity\": \"note\""

step "iyi check notes, unasked, each spawn the compiler kept in its unit"
# Lines 30, 31 and 35 and no other: not the two in parallel, not the one
# that asked for its unit, not the one that asked for the pool.
unasked() { # log
  [ "$(grep -c ': note: ' "$1")" = 3 ] \
    && grep -q 'explained.iyi:30:.*note: spawn stays in its spawner' "$1" \
    && grep -q 'explained.iyi:31:.*note: spawn stays in its spawner' "$1" \
    && grep -q 'explained.iyi:35:.*note: spawn stays in its spawner' "$1"
}
if ! "$IYI" check --error-on-warnings explained.iyi > unasked.log 2>&1; then
  echo "check --error-on-warnings failed on its notes:"; cat unasked.log; exit 1
fi
if ! unasked unasked.log; then
  echo "check did not note exactly the three spawns kept in their unit:"; cat unasked.log; exit 1
fi
echo "  lines 30, 31 and 35, and --error-on-warnings exits 0"
if ! "$IYI" build explained.iyi -o explained > built.log 2>&1 || [ -s built.log ]; then
  echo "build printed something, or failed:"; cat built.log; exit 1
fi
echo "  build: nothing printed"

# ── 3. The one verb ───────────────────────────────────────────────────────
step "spawn_parallel and spawn_serial are compile errors naming the new spelling"
cat > old.iyi <<'IYI'
module old

done = Atomic(Int32).new(0)
group do |g|
  g.spawn_parallel { done.add(1) }
  g.spawn_serial do
    done.add(2)
  end
end
puts done.get
IYI
cat > old_typed.iyi <<'IYI'
module old_typed

pair = group do |g|
  a = g.spawn_serial { 1 }
  b = g.spawn { 2 }
end!
puts pair
IYI
refused() { # file, expected text, log
  if "$IYI" check "$1" > "$3" 2>&1; then
    echo "$1 compiled:"; cat "$3"; return 1
  fi
  if ! grep -qF "$2" "$3"; then
    echo "$1 was not refused with \"$2\":"; cat "$3"; return 1
  fi
}
refused old.iyi '`spawn_parallel` is gone: one verb starts a task now. Write `g.spawn(parallel: true) { }`' old.log || exit 1
echo "  $(grep -m1 -o 'old.iyi:5:[0-9]*' old.log): spawn_parallel"
refused old_typed.iyi '`spawn_serial` is gone: one verb starts a task now. Write `g.spawn(serial: true) { }`' old_typed.log || exit 1
echo "  $(grep -m1 -o 'old_typed.iyi:4:[0-9]*' old_typed.log): spawn_serial, in a typed group"
if ! "$IYI" check -f json old.iyi > old.json 2>&1; grep -qF '"suggested_edit"' old.json && grep -qF 'spawn(parallel: true)' old.json; then
  echo "  -f json carries the edit: spawn(parallel: true)"
else
  echo "-f json carried no edit for spawn_parallel:"; cat old.json; exit 1
fi
cp old.iyi fixed.iyi
if ! "$IYI" fix fixed.iyi > fix.log 2>&1; then
  echo "iyi fix failed:"; cat fix.log; exit 1
fi
if ! grep -qF 'g.spawn(parallel: true) { done.add(1) }' fixed.iyi || ! grep -qF 'g.spawn(serial: true) do' fixed.iyi; then
  echo "iyi fix did not write the new spellings:"; cat fixed.iyi; exit 1
fi
if ! "$IYI" run fixed.iyi > fixed.txt 2>&1 || [ "$(cat fixed.txt)" != 3 ]; then
  echo "the fixed program did not run to 3:"; cat fixed.txt; exit 1
fi
echo "  iyi fix: both rewritten, and the program runs"

step "a placement is the literal true, one of them, and parallel: true is Share-gated"
cat > placed.iyi <<'IYI'
module placed

def ordered : Bool
  true
end

log = [] of Int32
group do |g|
  g.spawn(PLACEMENT) { 1 }
end
IYI
placement() { # argument, expected text
  sed "s/PLACEMENT/$1/; s/{ 1 }/$3/" placed.iyi > "placed_$4.iyi"
  refused "placed_$4.iyi" "$2" "placed_$4.log" || exit 1
  echo "  $1: $(grep -m1 -F "$2" "placed_$4.log" | sed 's/^.*Error: //; s/^ *//' | cut -c1-110)"
}
placement 'parallel: false' '`parallel: false` asks for nothing that leaving it out does not' '{ 1 }' false
placement 'serial: ordered' '`serial:` takes the literal `true`' '{ 1 }' unread
placement 'parallel: true, serial: true' 'a spawn is placed one way' '{ 1 }' both
placement 'parallel: true' 'the block spawn(parallel: true) runs on another thread captures `log : Array(Int32)`, which is not Share' '{ log << 1; 0 }' unshared

# ── 4. The cliff, said ────────────────────────────────────────────────────
step "a spawn kept in its unit by another module's type names the module and the field"
mkdir -p cliff/dep cliff/app
cat > cliff/dep/config.iyi <<'IYI'
module dep/config

pub class Config
  def initialize(@hits : Int32)
  end

  def hits : Int32
    @hits
  end
end
IYI
cp cliff/dep/config.iyi config_share.iyi
cat > config_bumped.iyi <<'IYI'
module dep/config

pub class Config
  def initialize(@hits : Int32)
  end

  def hits : Int32
    @hits
  end

  def bump : Nil
    @hits += 1
  end
end
IYI
cat > cliff/app/work.iyi <<'IYI'
module app/work

import dep/config::{Config}

pub def crunch(config : Config) : Int32
  total = Atomic(Int32).new(0)
  group do |g|
    g.spawn { total.add(config.hits) }
  end
  total.get
end
IYI
cat > cliff/main.iyi <<'IYI'
module main

import dep/config::{Config}
import app/work::{crunch}

puts crunch(Config.new(5))
IYI
cp config_bumped.iyi cliff/dep/config.iyi
if ! (cd cliff && "$IYI" check --error-on-warnings main.iyi) > remote.log 2>&1; then
  echo "check failed:"; cat remote.log; exit 1
fi
remote='field @hits (module `dep/config`) is assigned in `bump`'
if ! grep -F 'work.iyi:8:' remote.log | grep -qF "$remote"; then
  echo "the note did not name the module and the field (\"$remote\"):"; cat remote.log; exit 1
fi
echo "  $(grep -m1 -F 'work.iyi:8:' remote.log | sed 's/^.*note: //' | cut -c1-200)"

step "a rebuild that moves a spawn says so, once, each way"
# The incremental loop (SPEC.md IV.3): artifacts read where they are
# current and rewritten where they are not. `app/work` is rebuilt because
# the module it imports changed, and its artifact's record says where its
# spawn ran before.
rebuild() { # log
  (cd cliff && "$IYI" build --use-iyimod mods --emit-iyimod mods -o main main.iyi) > "$1" 2>&1
}
cp config_share.iyi cliff/dep/config.iyi
if ! (cd cliff && "$IYI" build --emit-iyimod mods -o main main.iyi) > first.log 2>&1 || [ -s first.log ]; then
  echo "the first build failed, or printed something:"; cat first.log; exit 1
fi
if ! "$IYI" mod dump cliff/mods/app/work.iyimod > dump.log 2>&1 || ! grep -qE '^  App::Work\.crunch 8:[0-9]+ parallel$' dump.log; then
  echo "the artifact does not record crunch's spawn as parallel:"; cat dump.log; exit 1
fi
echo "  mod dump: $(grep -m1 'App::Work.crunch' dump.log | sed 's/^ *//')"
moved() { # log, line, expected text
  [ "$(grep -c ': note: ' "$1")" = 1 ] && grep -F "work.iyi:$2:" "$1" | grep -qF "$3"
}
to_unit='spawn in `App::Work.crunch` ran in parallel when app/work was last built, and stays in its spawner'"'"'s unit now: the block captures `config : Dep::Config::Config`, which is not Share: Dep::Config::Config'"'"'s field @hits (module `dep/config`) is assigned in `bump`'
to_pool='spawn in `App::Work.crunch` stayed in its spawner'"'"'s unit when app/work was last built, and runs in parallel now'
cp config_bumped.iyi cliff/dep/config.iyi
rebuild moved.log || { echo "the rebuild failed:"; cat moved.log; exit 1; }
if ! moved moved.log 8 "$to_unit"; then
  echo "the rebuild did not print one line for the spawn kept in its unit now:"; cat moved.log; exit 1
fi
echo "  $(grep -m1 ': note: ' moved.log | sed 's/^.*note: //' | cut -c1-200)"
if ! (cd cliff && ./main) | grep -qx 5; then
  echo "the rebuilt program did not print 5"; exit 1
fi
# A line above the spawn moves it to line 9 and makes `app/work` stale, so
# this rebuild compiles it again: the spawn is named by its def and its
# block, not by its line, and it has not moved.
awk 'NR == 2 { print "# Above the spawn: its line moves, and it does not." } { print }' cliff/app/work.iyi > work.iyi.new && mv work.iyi.new cliff/app/work.iyi
rebuild still.log || { echo "the rebuild failed:"; cat still.log; exit 1; }
if grep -q 'up to date' still.log || grep -q ': note: ' still.log; then
  echo "a rebuild that compiled app/work again and moved nothing did not stay silent:"; cat still.log; exit 1
fi
echo "  app/work rebuilt with its spawn on another line, nothing moved: nothing printed"
cp config_share.iyi cliff/dep/config.iyi
rebuild back.log || { echo "the rebuild failed:"; cat back.log; exit 1; }
if ! moved back.log 9 "$to_pool"; then
  echo "the rebuild did not print one line for the spawn in parallel now:"; cat back.log; exit 1
fi
echo "  $(grep -m1 ': note: ' back.log | sed 's/^.*note: //' | cut -c1-200)"

step "a spawn whose block calls into a module read from its artifact is placed by what the artifact recorded"
# The module is compiled from source once, by `first.iyi`, which calls
# every function so its artifact holds each one's machine code; `app.iyi`
# is then built against the artifact, which has the declarations and not
# the bodies. Before the artifact recorded what each function reaches,
# the spawn at line 8 ran in parallel and lost appends: 19,870 to 19,952
# of 20,000 on four workers (Linux).
mkdir -p reach/dep
cat > reach/dep/counter.iyi <<'IYI'
module dep/counter

SEEN = [] of Int32

@[SafeReach("filled by this module's initialiser, then only read")]
NAMES = [] of String
NAMES << "first"

pub class Registry
  @[SafeReach("registered at startup, then only read")]
  @@noted = [] of Int32

  def self.register(n : Int32) : Nil
    @@noted << n
  end

  def self.count(&block : -> Nil) : Int32
    block.call
    @@noted.size
  end
end

pub def note(n : Int32) : Nil
  SEEN << n
end

pub def total : Int32
  SEEN.size
end

pub def names : Int32
  NAMES.size
end
IYI
cat > reach/first.iyi <<'IYI'
module main

import dep/counter::{note, total, names, Registry}

Registry.register(1)
note(1)
puts total + names + Registry.count { nil }
IYI
cat > reach/app.iyi <<'IYI'
module main

import dep/counter::{note, total, names, Registry}

seen = Atomic(Int32).new(0)
group do |g|
  20000.times do |i|
    g.spawn { note(i); nil }
  end
  g.spawn { seen.add(names); nil }
  g.spawn { Registry.register(2); nil }
  g.spawn { seen.add(Registry.count { nil }); nil }
end
puts total
IYI
if ! (cd reach && "$IYI" build --emit-iyimod mods -o first first.iyi) > reach-first.log 2>&1 || [ -s reach-first.log ]; then
  echo "the build writing dep/counter's artifact failed, or printed something:"; cat reach-first.log; exit 1
fi
if ! (cd reach && IYI_SPAWN_BROKEN=reaches "$IYI" build --emit-iyimod bare -o first first.iyi) > reach-bare.log 2>&1; then
  echo "the build writing the artifact without its reaches failed:"; cat reach-bare.log; exit 1
fi
"$IYI" mod dump reach/mods/dep/counter.iyimod > reach-dump.log 2>&1
for want in 'note reaches the constant `SEEN : Array(Int32)` (module `dep/counter`) through `SEEN.<<`' \
  'register reaches the class variable `@@noted : Array(Int32)` (module `dep/counter`) through `@@noted.<<`'; do
  if ! grep -qF "$want" reach-dump.log; then
    echo "mod dump does not record \"$want\":"; cat reach-dump.log; exit 1
  fi
done
if grep -qF 'names reaches' reach-dump.log; then
  echo "mod dump records names, which reads only what the initialiser fills:"; cat reach-dump.log; exit 1
fi
echo "  mod dump: $(grep -m1 -F 'note reaches' reach-dump.log | sed 's/^ *//')"
against() { # log, artifact directory, environment...
  local log="$1" mods="$2"
  shift 2
  (cd reach && env "$@" "$IYI" build --use-iyimod "$mods" --explain-spawn -o app app.iyi) > "$log" 2>&1
}
placed() { # log, line, expected text
  grep -F "app.iyi:$2:" "$1" | grep -qF "$3"
}
seen_unit='spawn stays in its spawner'"'"'s unit: the block reaches the constant `SEEN : Array(Int32)` (module `dep/counter`) through `note` → `SEEN.<<`, and it is not Share'
claimed='the block reaches the class variable `@@noted : Array(Int32)` (module `dep/counter`) through `Registry.register` → `@@noted.<<`'
travelled='the block reaches the class variable `@@noted : Array(Int32)` through `Registry.count` → `@@noted.size`'
unknown='dep/counter arrived as an artifact that does not record what its functions reach of module state'
against reach-app.log mods || { echo "the build against the artifact failed:"; cat reach-app.log; exit 1; }
for check in "8|$seen_unit" "10|spawn runs in parallel" "11|$claimed" "12|$travelled"; do
  if ! placed reach-app.log "${check%%|*}" "${check#*|}"; then
    echo "line ${check%%|*} was not placed with \"${check#*|}\":"; cat reach-app.log; exit 1
  fi
  echo "  line ${check%%|*}: $(grep -m1 -F "app.iyi:${check%%|*}:" reach-app.log | sed 's/^.*note: //' | cut -c1-160)"
done
for run in 1 2 3; do
  if ! got=$(cd reach && timeout -k 5 120 ./app --workers=4) || [ "$got" != 20000 ]; then
    echo "the program built against the artifact lost appends on run $run: $got of 20000"; exit 1
  fi
done
echo "  20000 of 20000 appends, three runs on four workers"
if ! "$IYI" mod dump reach/bare/dep/counter.iyimod | grep -qF 'reaches       (not recorded)'; then
  echo "the artifact written without its reaches still records them"; exit 1
fi
against reach-unknown.log bare || { echo "the build against the artifact without reaches failed:"; cat reach-unknown.log; exit 1; }
for line in 8 10 11; do
  if ! placed reach-unknown.log "$line" "$unknown"; then
    echo "line $line, calling into an artifact that does not say what it reaches, was not kept in its unit naming dep/counter:"; cat reach-unknown.log; exit 1
  fi
done
echo "  without the record, lines 8, 10 and 11 stay in their unit: $(grep -m1 -F 'app.iyi:10:' reach-unknown.log | sed 's/^.*unit: //' | cut -c1-120)"

# ── 5. Failure proofs ─────────────────────────────────────────────────────
# Of the runtime: each a copy of src/iyi with concurrency.iyi changed,
# built against through IYI_PATH; nothing in the tree is touched.
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

step "failure proof: serial: true sent to the pool"
broken optoutignored '/^  def spawn\(\*, serial : Bool, &block/ { inserial = 1 } inserial && /^    in_unit\(&block\)$/ { print "    on_pool(&block)"; inserial = 0; next } { print }'
caught optoutignored 'spawn(serial: true) tasks were running at one instant' serial --workers=4

step "failure proof: parallel: true left in its unit"
broken askedignored '/^    def spawn\(\*, parallel : Bool, &block/ { inasked = 1 } inasked && /^      on_pool\(&block\)$/ { print "      in_unit(&block)"; inasked = 0; next } { print }'
caught askedignored 'spawn(parallel: true) tasks waited 2000 ms for the others and left alone' asked --workers=4
caught askedignored 'spawn(parallel: true) tasks ran on the spawner'"'"'s thread on a pool of one' askedone --workers=1

step "failure proof: a pool of one that starts for eligible spawns"
broken oneignored '/^  def self.parallel\? : Bool$/ { print; print "    return true"; next } { print }'
caught oneignored 'one: ' one --workers=1

step "failure proof: a pool that starts every worker at once"
broken wholepool '/^      start_monitor$/ { print "      while word(pointerof(@@launched)).value.get < @@started.to_i64"; print "        word(pointerof(@@launched)).value.add(1_i64)"; print "        word(pointerof(@@spinning)).value.add(1_i64)"; print "        IyiThread.start { IyiWorkers.work }"; print "      end" } { print }'
caught wholepool 'grows: one eligible spawn started 4 of' grows --workers=4

step "failure proof: a pool that never starts a second worker"
broken nevergrows '/^  def self.grow : Nil$/ { print; print "    return"; next } { print }'
caught nevergrows 'grows: 4 eligible spawns running at one instant started 1 of' grows --workers=4

step "failure proof: spawn_parallel kept as an alias"
mkdir -p alias/iyi
cp "$REPO"/src/iyi/*.iyi alias/iyi/
awk '/^    def spawn\(\*, parallel : Bool, &block/ { print "    def spawn_parallel(&block : -> T) : IyiTask(T) forall T"; print "      on_pool(&block)"; print "    end"; print "" } { print }' \
  "$REPO/src/iyi/concurrency.iyi" > alias/iyi/concurrency.iyi
if cmp -s alias/iyi/concurrency.iyi "$REPO/src/iyi/concurrency.iyi"; then
  echo "the awk for alias found nothing to change"; exit 1
fi
if IYI_PATH="$WORK/alias${PSEP}$REPO/src" refused old.iyi '`spawn_parallel` is gone' alias.log > /dev/null; then
  echo "the alias copy was not caught:"; cat alias.log; exit 1
fi
echo "  caught: with the alias, spawn_parallel at old.iyi:5 is not refused ($(grep -m1 -o 'old.iyi:[0-9]*' alias.log || echo 'it compiled'))"

# Of the compiler: `IYI_SPAWN_BROKEN` turns one mechanism off each.
step "failure proof: a reason that names no module"
cp config_bumped.iyi cliff/dep/config.iyi
(cd cliff && IYI_SPAWN_BROKEN=remote "$IYI" check main.iyi) > remote-broken.log 2>&1
if grep -qF "$remote" remote-broken.log; then
  echo "the copy that names no module was not caught:"; cat remote-broken.log; exit 1
fi
echo "  caught: the note reads \"$(grep -m1 -o "Dep::Config::Config's field @hits[^(]*is assigned in \`bump\`" remote-broken.log)\""

step "failure proof: iyi check silent unasked"
IYI_SPAWN_BROKEN=fallback "$IYI" check explained.iyi > fallback-broken.log 2>&1
if unasked fallback-broken.log; then
  echo "the copy that notes nothing unasked was not caught:"; cat fallback-broken.log; exit 1
fi
echo "  caught: $(grep -c ': note: ' fallback-broken.log) notes, not 3"

step "failure proof: no line for a moved spawn"
cp config_bumped.iyi cliff/dep/config.iyi
(cd cliff && IYI_SPAWN_BROKEN=moves "$IYI" build --use-iyimod mods --emit-iyimod mods -o main main.iyi) > moves-broken.log 2>&1
if moved moves-broken.log 9 "$to_unit"; then
  echo "the copy that prints no line was not caught:"; cat moves-broken.log; exit 1
fi
echo "  caught: the rebuild printed $(grep -c ': note: ' moves-broken.log) lines"

step "failure proof: spawn_parallel answered as any undefined method"
if IYI_SPAWN_BROKEN=retired refused old.iyi '`spawn_parallel` is gone' retired-broken.log > /dev/null; then
  echo "the copy that names no spelling was not caught:"; cat retired-broken.log; exit 1
fi
echo "  caught: \"$(grep -m1 -o "undefined method 'spawn_parallel'[^.]*" retired-broken.log)\""

step "failure proof: an artifact that does not say what its functions reach"
if placed reach-unknown.log 8 "$seen_unit"; then
  echo "the artifact without its reaches was not caught:"; cat reach-unknown.log; exit 1
fi
echo "  caught: line 8 reads \"$(grep -m1 -F 'app.iyi:8:' reach-unknown.log | sed 's/^.*note: //' | cut -c1-110)\""

step "failure proof: a function read from an artifact taken to reach nothing"
against reach-headers.log mods IYI_SPAWN_BROKEN=headers || { echo "the build failed:"; cat reach-headers.log; exit 1; }
if placed reach-headers.log 8 "$seen_unit"; then
  echo "the copy that reads no record was not caught:"; cat reach-headers.log; exit 1
fi
echo "  caught: line 8 reads \"$(grep -m1 -F 'app.iyi:8:' reach-headers.log | sed 's/^.*note: //' | cut -c1-60)\", and the program printed $(cd reach && timeout -k 5 120 ./app --workers=4) of 20000"

step "failure proof: an artifact that takes every proven claim to hold for every importer"
if ! (cd reach && IYI_SPAWN_BROKEN=robust "$IYI" build --emit-iyimod trusting -o first first.iyi) > reach-trusting.log 2>&1; then
  echo "the build writing the trusting artifact failed:"; cat reach-trusting.log; exit 1
fi
against reach-robust.log trusting || { echo "the build failed:"; cat reach-robust.log; exit 1; }
if placed reach-robust.log 11 "$claimed"; then
  echo "the artifact that trusts every claim was not caught:"; cat reach-robust.log; exit 1
fi
echo "  caught: line 11 reads \"$(grep -m1 -F 'app.iyi:11:' reach-robust.log | sed 's/^.*note: //' | cut -c1-60)\""

echo "== spawn eligibility: every check held"
