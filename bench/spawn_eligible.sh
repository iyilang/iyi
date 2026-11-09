#!/usr/bin/env bash
# Where a `spawn` runs (SPEC.md III.4.15, III.4.16, III.4.18): one verb.
# Written plain, in parallel where the compiler can prove it safe and in
# its spawner's unit otherwise; `unit: :new` asks for a unit of its own
# and `unit: :same` for the spawner's; and a spawn kept in its unit, or
# moved by a change elsewhere, is said where the author looks.
#
#     bash bench/spawn_eligible.sh
#
#   1. bench/spawn_eligible.iyi, plain and --release, on four workers:
#      four spawns whose blocks capture only atomics are all running at
#      one instant, from the main thread and from inside a parallel task;
#      four that append to their parent's `Array` stay in its unit, one at
#      a time; four `spawn(unit: :same)` tasks that capture only atomics
#      stay in theirs; and four `spawn(unit: :new)` tasks are all
#      running at one instant. On a pool of one, eligible spawns stay on
#      the main thread and no pool starts, while `spawn(unit: :new)`
#      tasks run on the pool's worker. On a pool of four, in a process of
#      its own, one spawn starts one worker, spawns joined one at a time at
#      most three, and four tasks running at one instant all four; one
#      spawn still starts one worker when it lands, every time, between
#      the worker's first empty look and its idle count.
#   2. The explanation: `--explain-spawn` notes each spawn, naming the
#      capture that kept one in its unit - a captured `Array`, a local
#      assigned in the loop that spawns, a constant reached through a call
#      - and a constant marked `@[SafeReach]` keeps nothing serial; a
#      spawn that spelled its placement is noted as asked. Notes are not
#      warnings: `--error-on-warnings` passes and `-f json` marks them
#      `"severity": "note"`. Unasked, `iyi check` notes each spawn the
#      compiler kept in its unit and no other, and `iyi build` prints
#      nothing. What std calls back is walked too: a spawn interpolating a
#      value whose `to_s` appends to an unguarded `Array`, or asking
#      `Array#includes?` of values whose `==` does, stays in its unit,
#      named through the std def that calls back, and loses no append on
#      four workers.
#   3. The one verb: `spawn_parallel` and `spawn_serial`, on a group and in
#      a typed group, and `serial: true` and `parallel: true`, are compile
#      errors naming the new spelling; `iyi fix` rewrites all four, and the
#      program runs. A symbol that names no unit, a value the compiler
#      cannot read, two placements at once, and a capture that is not
#      Share under `unit: :new` are refused.
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
#      or through a body that travelled. And a module's own spawn, compiled
#      into its artifact, that the producing program could run in parallel
#      only on such a claim stays in its unit in the artifact: a consumer
#      appending without the lock beside it loses no append.
#   5. Failure proofs against broken copies, each caught at the named
#      check. Of the runtime: an eligible spawn left in its unit, an
#      ineligible one sent to the pool, `unit: :same` sent to the pool,
#      `unit: :new` left in the unit, `spawn_parallel` or `serial:` kept as an
#      alias, a pool of one that starts for eligible spawns anyway, a pool
#      that starts every worker at once, one that never starts a second,
#      and a worker that gives back the token of the one out looking
#      before it counts itself idle. Of the compiler, through
#      `IYI_SPAWN_BROKEN`: no module named in a reason, no note from `iyi
#      check` unasked, no line for a moved spawn, `spawn_parallel` and
#      `serial: true` answered as any undefined method or parameter, an artifact written without what
#      its functions reach (whose consumer must keep every spawn calling
#      into it in its unit, naming the module), a function read from an
#      artifact taken to reach nothing, and an artifact that takes every
#      proven claim to hold for every importer; a walk that stops at std
#      (`callbacks`), and an artifact whose own spawns stand on a claim
#      proven for its producer alone (`claimed`).
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
  g.spawn(unit: :same) { done.add(1) }
  g.spawn(unit: :new) { done.add(1) }
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
explain explain.log 30 'spawn stays in its spawner'"'"'s unit (SPEC.md III.4.18): the block captures `log : Array(Int32)`, which is not Share'
explain explain.log 31 'the block reaches the constant `LEDGER : Explained::Ledger` through `record` → `LEDGER.add`'
explain explain.log 32 'spawn runs in parallel'
explain explain.log 35 'line 36: `i` is assigned here, in a loop or a block that spawns the task again'
explain explain.log 38 'spawn stays in its spawner'"'"'s unit (SPEC.md III.4.18): `unit: :same` keeps it there'
explain explain.log 39 'spawn runs in a unit of its own: `unit: :new` asks for it'
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

step "what std calls back of the program's own is walked"
# The walk stopped at std, whose state is std's to keep safe, and so at
# what std calls back: an interpolation asks the value's `to_s`, and
# `Array#includes?` asks `==`. Both spawns ran in parallel and lost
# appends (8,095 to 8,100 of 8,102 on four workers, Linux; found by
# `bench/spawn_fuzz.py`, seeds 27 and 34).
cat > callback.iyi <<'IYI'
module callback

SHOWN = [] of Int32

class Shown
  def to_s : String
    SHOWN << 1
    "s"
  end
end

class Key
  def ==(other : Key) : Bool
    SHOWN << 1
    true
  end
end

group do |g|
  4.times do
    g.spawn { 5000.times { "#{Shown.new}" }; nil }
  end
  4.times do
    g.spawn { 5000.times { [Key.new].includes?(Key.new) }; nil }
  end
end
puts SHOWN.size
IYI
callback_to_s='`Shown#to_s` → `SHOWN.<<`, and it is not Share'
callback_eq='`Array#includes?` → `Key#==` → `SHOWN.<<`, and it is not Share'
if ! "$IYI" build --explain-spawn -o callback callback.iyi > callback.log 2>&1; then
  echo "the build failed:"; cat callback.log; exit 1
fi
for check in "21|$callback_to_s" "24|$callback_eq"; do
  if ! grep -F "callback.iyi:${check%%|*}:" callback.log | grep -qF "${check#*|}"; then
    echo "line ${check%%|*} was not kept in its unit through \"${check#*|}\":"; cat callback.log; exit 1
  fi
  echo "  line ${check%%|*}: $(grep -m1 -F "callback.iyi:${check%%|*}:" callback.log | sed 's/^.*note: //' | cut -c1-150)"
done
for run in 1 2 3; do
  if ! got=$(timeout -k 5 120 ./callback --workers=4) || [ "$got" != 40000 ]; then
    echo "the program lost appends on run $run: $got of 40000"; exit 1
  fi
done
echo "  40000 of 40000 appends, three runs on four workers"

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
refused old.iyi '`spawn_parallel` is gone: one verb starts a task now. Write `g.spawn(unit: :new) { }`' old.log || exit 1
echo "  $(grep -m1 -o 'old.iyi:5:[0-9]*' old.log): spawn_parallel"
refused old_typed.iyi '`spawn_serial` is gone: one verb starts a task now. Write `g.spawn(unit: :same) { }`' old_typed.log || exit 1
echo "  $(grep -m1 -o 'old_typed.iyi:4:[0-9]*' old_typed.log): spawn_serial, in a typed group"
if ! "$IYI" check -f json old.iyi > old.json 2>&1; grep -qF '"suggested_edit"' old.json && grep -qF 'spawn(unit: :new)' old.json; then
  echo "  -f json carries the edit: spawn(unit: :new)"
else
  echo "-f json carried no edit for spawn_parallel:"; cat old.json; exit 1
fi
cp old.iyi fixed.iyi
if ! "$IYI" fix fixed.iyi > fix.log 2>&1; then
  echo "iyi fix failed:"; cat fix.log; exit 1
fi
if ! grep -qF 'g.spawn(unit: :new) { done.add(1) }' fixed.iyi || ! grep -qF 'g.spawn(unit: :same) do' fixed.iyi; then
  echo "iyi fix did not write the new spellings:"; cat fixed.iyi; exit 1
fi
if ! "$IYI" run fixed.iyi > fixed.txt 2>&1 || [ "$(cat fixed.txt)" != 3 ]; then
  echo "the fixed program did not run to 3:"; cat fixed.txt; exit 1
fi
echo "  iyi fix: both rewritten, and the program runs"

step "serial: true and parallel: true are compile errors naming unit: :same and unit: :new"
cat > placed_old.iyi <<'IYI'
module placed_old

done = Atomic(Int32).new(0)
group do |g|
  g.spawn(serial: true) { done.add(1) }
  g.spawn(parallel: true) do
    done.add(2)
  end
end
puts done.get
IYI
refused placed_old.iyi '`serial:` is gone: a spawn names its unit now. Write `g.spawn(unit: :same) { }`' placed_old.log || exit 1
echo "  $(grep -m1 -o 'placed_old.iyi:5:[0-9]*' placed_old.log): serial: true"
sed 's/serial: true/unit: :same/' placed_old.iyi > placed_new.iyi
refused placed_new.iyi '`parallel:` is gone: a spawn names its unit now. Write `g.spawn(unit: :new) { }`' placed_new.log || exit 1
echo "  $(grep -m1 -o 'placed_new.iyi:6:[0-9]*' placed_new.log): parallel: true"
cp placed_old.iyi placed_fixed.iyi
if ! "$IYI" fix placed_fixed.iyi > placed_fix.log 2>&1; then
  echo "iyi fix failed:"; cat placed_fix.log; exit 1
fi
if ! grep -qF 'g.spawn(unit: :same) { done.add(1) }' placed_fixed.iyi || ! grep -qF 'g.spawn(unit: :new) do' placed_fixed.iyi; then
  echo "iyi fix did not write unit: :same and unit: :new:"; cat placed_fixed.iyi; exit 1
fi
if ! "$IYI" run placed_fixed.iyi > placed_fixed.txt 2>&1 || [ "$(cat placed_fixed.txt)" != 3 ]; then
  echo "the fixed program did not run to 3:"; cat placed_fixed.txt; exit 1
fi
echo "  iyi fix: both rewritten, and the program runs"

step "a placement is :same or :new as written, one of them, and unit: :new is Share-gated"
cat > placed.iyi <<'IYI'
module placed

import std/unit::{Unit}

def ordered : Symbol
  :same
end

counts = Unit.new { 0 }
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
placement 'unit: :here' '`unit: :here` names no unit' '{ 1 }' other
placement 'unit: ordered' '`unit:` takes `:same` or `:new` as written' '{ 1 }' unread
placement 'in: counts, unit: :same' 'a spawn is placed one way' '{ |c| c }' both
placement 'unit: :new' 'the block spawn(unit: :new) runs in a unit of its own, on another thread captures `log : Array(Int32)`, which is not Share' '{ log << 1; 0 }' unshared

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
to_unit='spawn in `App::Work.crunch` ran in parallel when app/work was last built, and stays in its spawner'"'"'s unit now (SPEC.md III.4.18): the block captures `config : Dep::Config::Config`, which is not Share: Dep::Config::Config'"'"'s field @hits (module `dep/config`) is assigned in `bump`'
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
seen_unit='spawn stays in its spawner'"'"'s unit (SPEC.md III.4.18): the block reaches the constant `SEEN : Array(Int32)` (module `dep/counter`) through `note` → `SEEN.<<`, and it is not Share'
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

step "a module's own spawn standing on a claim its producer alone proved stays in its unit in the artifact"
# `fill`'s tasks reach `ROWS` through `locked_add`, behind `LOCK`, and
# `first.iyi` writes `ROWS` only there: the claim holds for it, and its
# build ran the tasks in parallel. The artifact carries that machine code
# to every importer, and `app.iyi` appends through `add`, outside the
# lock, which its own build from source refuses the claim for. Before
# this, `fill`'s tasks ran in parallel beside that append (found by
# `bench/spawn_fuzz.py`).
mkdir -p claimed/dep
cat > claimed/dep/ledger.iyi <<'IYI'
module dep/ledger

import std/mutex::{Mutex}

LOCK = Mutex.new { 0 }

@[SafeReach("every write and every read is behind LOCK")]
ROWS = [] of Int32

pub def add(n : Int32) : Nil
  ROWS << n
end

def size_now : Int32
  ROWS.size
end

pub def locked_add(n : Int32) : Nil
  LOCK.lock { |_| add(n) }
  nil
end

pub def total : Int32
  LOCK.get { |_| size_now }.as(Int32)
end

pub def fill(tasks : Int32, each : Int32) : Nil
  group do |g|
    tasks.times do
      g.spawn { each.times { |i| locked_add(i) }; nil }
    end
  end
end
IYI
cat > claimed/first.iyi <<'IYI'
module main

import dep/ledger::{locked_add, total, fill}

locked_add(1)
fill(2, 10)
puts total
IYI
cat > claimed/app.iyi <<'IYI'
module main

import dep/ledger::{add, fill, total}

group do |g|
  g.spawn { fill(4, 5000); nil }
  g.spawn { 20000.times { |i| add(i) }; nil }
end
puts total
IYI
if ! (cd claimed && "$IYI" build --emit-iyimod mods -o first first.iyi) > claimed-first.log 2>&1 || [ -s claimed-first.log ]; then
  echo "the producing build failed, or printed something:"; cat claimed-first.log; exit 1
fi
claimed_unit='Dep::Ledger.fill 30:9 in its spawner'"'"'s unit: the block reaches the constant `ROWS : Array(Int32)` through `locked_add` → `add` → `ROWS.<<`'
claimed_why='its @[SafeReach] is proven for this program and not for every program importing the module'
"$IYI" mod dump claimed/mods/dep/ledger.iyimod > claimed-dump.log 2>&1
if ! grep -qF "$claimed_unit" claimed-dump.log || ! grep -qF "$claimed_why" claimed-dump.log; then
  echo "the artifact does not record fill's spawn in its unit, on a claim proven for its producer alone:"; cat claimed-dump.log; exit 1
fi
echo "  mod dump: $(grep -m1 -F 'Dep::Ledger.fill' claimed-dump.log | sed 's/^ *//' | cut -c1-140)"
if ! (cd claimed && "$IYI" build --use-iyimod mods -o app app.iyi) > claimed-app.log 2>&1; then
  echo "the build against the artifact failed:"; cat claimed-app.log; exit 1
fi
for run in 1 2 3; do
  if ! got=$(cd claimed && timeout -k 5 120 ./app --workers=4) || [ "$got" != 40000 ]; then
    echo "the program built against the artifact lost appends on run $run: $got of 40000"; exit 1
  fi
done
echo "  40000 of 40000 appends, three runs on four workers"

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

step "failure proof: unit: :same sent to the pool"
broken optoutignored '/^  def spawn\(\*, unit : Symbol, &block/ { inserial = 1 } inserial && /^    in_unit\(&block\)$/ { print "    on_pool(&block)"; inserial = 0; next } { print }'
caught optoutignored 'spawn(unit: :same) tasks were running at one instant' serial --workers=4

step "failure proof: unit: :new left in its unit"
broken askedignored '/^    private def spawn_new\(&block/ { inasked = 1 } inasked && /^      on_pool\(&block\)$/ { print "      in_unit(&block)"; inasked = 0; next } { print }'
caught askedignored 'spawn(unit: :new) tasks waited 2000 ms for the others and left alone' asked --workers=4
caught askedignored 'spawn(unit: :new) tasks ran on the spawner'"'"'s thread on a pool of one' askedone --workers=1

step "failure proof: a pool of one that starts for eligible spawns"
broken oneignored '/^  def self.parallel\? : Bool$/ { print; print "    return true"; next } { print }'
caught oneignored 'one: ' one --workers=1

step "failure proof: a pool that starts every worker at once"
broken wholepool '/^      start_monitor$/ { print "      while word(pointerof(@@launched)).value.get < @@started.to_i64"; print "        word(pointerof(@@launched)).value.add(1_i64)"; print "        word(pointerof(@@spinning)).value.add(1_i64)"; print "        IyiThread.start { IyiWorkers.work }"; print "      end" } { print }'
caught wholepool 'grows: one eligible spawn started 4 of' grows --workers=4

step "failure proof: a pool that never starts a second worker"
broken nevergrows '/^  def self.grow : Nil$/ { print; print "    return"; next } { print }'
caught nevergrows 'grows: 4 eligible spawns running at one instant started 1 of' grows --workers=4

# A worker the pool starts holds the token of the one out looking until
# its look finds a task or it has counted itself idle
# (`IyiScheduler.idle_worker`), so a push between its empty look and its
# count finds the token taken and starts nobody, and the look after the
# count finds the task. The token went back before the count, and
# `grows`'s one spawn, landing there, found none idle and the token free
# and started a second worker: on a darwin CI runner (run 42187717533),
# in 17 of 8,000 runs on Linux (12 vCPU, shared), and in none of 8,000 on
# macOS 26.6, Apple M2 Pro, 10 cores, or 2,000 on Windows 11, 12 logical
# processors (the user's machines). No count of runs proves that, so the
# window is held open: the main thread waits 50 ms after the pool's start
# before its push, and the first worker's first empty look waits 200 ms
# before it counts itself idle. Held open in every worker's first look,
# the wait also let `grows`'s four tasks all arrive on fewer workers, time
# sliced, and its last check failed one run of 20 on the Windows machine
# with the token held through the wait. Given back first, the copy below
# started a second worker in 20 runs of 20 on each of the three machines,
# owing the start each time; with the same waits before the token went
# back, 20 of 20 held on each.
step "a spawn landing between a worker's empty look and its idle count starts no second worker"
awk_widen='/^  (@\[Effect\(:scheduler\)\];[[:space:]]*)?def self[.]start : Nil$/ { instart = 1 }
  instart && /^      start_monitor$/ {
    print
    print "      until_ns = __iyi_monotonic_ns + 50_000_000_i64"
    print "      while __iyi_monotonic_ns < until_ns"
    print "        IyiThread.spin_pause"
    print "      end"
    c++
    next }
  instart && /^  end$/ { instart = 0 }
  /^  (@\[Effect\(:scheduler\)\];[[:space:]]*)?def self[.]work : Nil$/ { inwork = 1 }
  inwork && /^      while true$/ { print "      widened = slot != 0_i64"; a++ }
  inwork && /^          IyiScheduler\.idle_worker\(st\)$/ {
    print "          unless widened"
    print "            widened = true"
    print "            until_ns = __iyi_monotonic_ns + 200_000_000_i64"
    print "            while __iyi_monotonic_ns < until_ns"
    print "              IyiThread.spin_pause"
    print "            end"
    print "          end"
    b++ }
  inwork && /^  end$/ { inwork = 0 }
  { print } END { if (a != 1 || b != 1 || c != 1) exit 3 }'

for check in missing_start dup_start missing_while dup_while missing_idle dup_idle; do
  case "$check" in
    missing_start) awk '!/^[[:space:]]*start_monitor$/' "$REPO/src/iyi/concurrency.iyi" > "disposable-$check.iyi" ;;
    dup_start)     awk '/^[[:space:]]*start_monitor$/ { print; print; next } 1' "$REPO/src/iyi/concurrency.iyi" > "disposable-$check.iyi" ;;
    missing_while) awk '/^  (@\[Effect\(:scheduler\)\];[[:space:]]*)?def self[.]work : Nil$/ { inw=1 } inw && /^      while true$/ { inw=0; next } 1' "$REPO/src/iyi/concurrency.iyi" > "disposable-$check.iyi" ;;
    dup_while)     awk '/^  (@\[Effect\(:scheduler\)\];[[:space:]]*)?def self[.]work : Nil$/ { inw=1 } inw && /^      while true$/ { inw=0; print; print; next } 1' "$REPO/src/iyi/concurrency.iyi" > "disposable-$check.iyi" ;;
    missing_idle)  awk '/^  (@\[Effect\(:scheduler\)\];[[:space:]]*)?def self[.]work : Nil$/ { inw=1 } inw && /IyiScheduler\.idle_worker\(st\)/ { inw=0; next } 1' "$REPO/src/iyi/concurrency.iyi" > "disposable-$check.iyi" ;;
    dup_idle)      awk '/^  (@\[Effect\(:scheduler\)\];[[:space:]]*)?def self[.]work : Nil$/ { inw=1 } inw && /IyiScheduler\.idle_worker\(st\)/ { inw=0; print; print; next } 1' "$REPO/src/iyi/concurrency.iyi" > "disposable-$check.iyi" ;;
  esac
  if awk "$awk_widen" "disposable-$check.iyi" > /dev/null 2>&1; then
    echo "disposable check $check unexpectedly succeeded"; rm -f "disposable-$check.iyi"; exit 1
  fi
  rm -f "disposable-$check.iyi"
done

mkdir -p widened/iyi
cp "$REPO"/src/iyi/*.iyi widened/iyi/
awk "$awk_widen" "$REPO/src/iyi/concurrency.iyi" > widened/iyi/concurrency.iyi ||
  { echo "the worker's look and the pool's start this step holds open are not in the runtime any more"; exit 1; }
if cmp -s widened/iyi/concurrency.iyi "$REPO/src/iyi/concurrency.iyi"; then
  echo "the worker's look and the pool's start this step holds open are not in the runtime any more"; exit 1
fi
if ! IYI_PATH="$WORK/widened${PSEP}$REPO/src" "$IYI" build "$REPO/bench/spawn_eligible.iyi" -o widened-run > build-widened.log 2>&1; then
  echo "the widened copy failed to build:"; tail -20 build-widened.log; exit 1
fi
for run in 1 2 3; do
  timeout -k 5 120 ./widened-run grows --workers=4 > widened.txt 2>&1
  code=$?
  if [ "$code" -ne 0 ] || ! grep -q 'every property held' widened.txt; then
    echo "  run $run of 3 with the look held open failed (exit $code):"; cat widened.txt; exit 1
  fi
done
echo "  three runs with the look held open: $(grep -m1 '^grows: one' widened.txt | sed 's/,.*//')"

step "failure proof: the token given back before the idle count"
awk_early='/^  (@\[Effect\(:scheduler\)\];[[:space:]]*)?def self[.]work : Nil$/ { inwork = 1 }
  inwork && /^        else$/ { inempty = 1 }
  inwork && inempty && /^          IyiScheduler\.release_unit\(st\)$/ {
    print "          stop_spinning(st, false)"
    found++ }
  inwork && inempty && /^        end$/ { inempty = 0 }
  inwork && /^  end$/ { inwork = 0; inempty = 0 }
  { print } END { if (found != 1) exit 3 }'

for check in missing_release dup_release; do
  case "$check" in
    missing_release) awk '/^  (@\[Effect\(:scheduler\)\];[[:space:]]*)?def self[.]work : Nil$/ { inw=1 } inw && /^        else$/ { ine=1 } ine && /IyiScheduler\.release_unit\(st\)/ { ine=0; next } 1' widened/iyi/concurrency.iyi > "disposable-$check.iyi" ;;
    dup_release)     awk '/^  (@\[Effect\(:scheduler\)\];[[:space:]]*)?def self[.]work : Nil$/ { inw=1 } inw && /^        else$/ { ine=1 } ine && /IyiScheduler\.release_unit\(st\)/ { ine=0; print; print; next } 1' widened/iyi/concurrency.iyi > "disposable-$check.iyi" ;;
  esac
  if awk "$awk_early" "disposable-$check.iyi" > /dev/null 2>&1; then
    echo "disposable check $check unexpectedly succeeded"; rm -f "disposable-$check.iyi"; exit 1
  fi
  rm -f "disposable-$check.iyi"
done

mkdir -p early/iyi
cp "$REPO"/src/iyi/*.iyi early/iyi/
awk "$awk_early" widened/iyi/concurrency.iyi > early/iyi/concurrency.iyi ||
  { echo "the worker's way to idle this proof reorders is not in the runtime any more"; exit 1; }
if cmp -s early/iyi/concurrency.iyi widened/iyi/concurrency.iyi; then
  echo "the worker's way to idle this proof reorders is not in the runtime any more"; exit 1
fi
if ! IYI_PATH="$WORK/early${PSEP}$REPO/src" "$IYI" build "$REPO/bench/spawn_eligible.iyi" -o early-run > build-early.log 2>&1; then
  echo "the broken copy early failed to build:"; tail -20 build-early.log; exit 1
fi
caught early 'grows: one eligible spawn started 2 of' grows --workers=4

step "failure proof: spawn_parallel kept as an alias"
mkdir -p alias/iyi
cp "$REPO"/src/iyi/*.iyi alias/iyi/
awk '/^    private def spawn_new\(&block/ { print "    def spawn_parallel(&block : -> T) : IyiTask(T) forall T"; print "      on_pool(&block)"; print "    end"; print "" } { print }' \
  "$REPO/src/iyi/concurrency.iyi" > alias/iyi/concurrency.iyi
if cmp -s alias/iyi/concurrency.iyi "$REPO/src/iyi/concurrency.iyi"; then
  echo "the awk for alias found nothing to change"; exit 1
fi
if IYI_PATH="$WORK/alias${PSEP}$REPO/src" refused old.iyi '`spawn_parallel` is gone' alias.log > /dev/null; then
  echo "the alias copy was not caught:"; cat alias.log; exit 1
fi
echo "  caught: with the alias, spawn_parallel at old.iyi:5 is not refused ($(grep -m1 -o 'old.iyi:[0-9]*' alias.log || echo 'it compiled'))"

step "failure proof: serial: kept as an alias"
mkdir -p serial_alias/iyi
cp "$REPO"/src/iyi/*.iyi serial_alias/iyi/
awk '/^  def spawn\(\*, unit : Symbol, &block/ { print "  def spawn(*, serial : Bool, &block : -> T) : IyiTask(T) forall T"; print "    in_unit(&block)"; print "  end"; print "" } { print }' \
  "$REPO/src/iyi/concurrency.iyi" > serial_alias/iyi/concurrency.iyi
if cmp -s serial_alias/iyi/concurrency.iyi "$REPO/src/iyi/concurrency.iyi"; then
  echo "the awk for serial_alias found nothing to change"; exit 1
fi
if IYI_PATH="$WORK/serial_alias${PSEP}$REPO/src" refused placed_old.iyi '`serial:` is gone' serial_alias.log > /dev/null; then
  echo "the serial: alias copy was not caught:"; cat serial_alias.log; exit 1
fi
echo "  caught: with the alias, serial: true at placed_old.iyi:5 is not refused ($(grep -m1 -o 'placed_old.iyi:[0-9]*' serial_alias.log || echo 'it compiled'))"

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

step "failure proof: serial: true answered as any missing parameter"
if IYI_SPAWN_BROKEN=retired refused placed_old.iyi '`serial:` is gone' retired-placement.log > /dev/null; then
  echo "the copy that names no spelling was not caught:"; cat retired-placement.log; exit 1
fi
echo "  caught: \"$(grep -m1 -o "no parameter named 'serial'" retired-placement.log || grep -m1 'Error' retired-placement.log)\""

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

step "failure proof: a walk that stops at std"
if ! IYI_SPAWN_BROKEN=callbacks "$IYI" build --explain-spawn -o callback_broken callback.iyi > callback-broken.log 2>&1; then
  echo "the build failed:"; cat callback-broken.log; exit 1
fi
if grep -F 'callback.iyi:21:' callback-broken.log | grep -qF "$callback_to_s"; then
  echo "the walk that stops at std was not caught:"; cat callback-broken.log; exit 1
fi
echo "  caught: line 21 reads \"$(grep -m1 -F 'callback.iyi:21:' callback-broken.log | sed 's/^.*note: //' | cut -c1-40)\", and the program printed $(timeout -k 5 120 ./callback_broken --workers=4) of 40000"

step "failure proof: an artifact whose own spawns stand on a claim proven for its producer alone"
if ! (cd claimed && IYI_SPAWN_BROKEN=claimed "$IYI" build --emit-iyimod trusting -o first first.iyi) > claimed-broken.log 2>&1; then
  echo "the build writing the artifact failed:"; cat claimed-broken.log; exit 1
fi
"$IYI" mod dump claimed/trusting/dep/ledger.iyimod > claimed-broken-dump.log 2>&1
if grep -qF "$claimed_unit" claimed-broken-dump.log; then
  echo "the artifact whose spawns stand on its producer's claim was not caught:"; cat claimed-broken-dump.log; exit 1
fi
(cd claimed && "$IYI" build --use-iyimod trusting -o app_trusting app.iyi) > claimed-trusting.log 2>&1
echo "  caught: the artifact reads \"$(grep -m1 -F 'Dep::Ledger.fill' claimed-broken-dump.log | sed 's/^ *//')\", and the program printed $(cd claimed && timeout -k 5 120 ./app_trusting --workers=4 2>&1 | tail -1) of 40000"

echo "== spawn eligibility: every check held"
