#!/usr/bin/env bash
# The reach rule: a parallel unit may not reach module state that is not
# Share (SPEC.md III.4.5).
#
#     bash bench/reach_rule.sh
#
# The block of `g.spawn(unit: :new)`, of `g.spawn(in: u)`, of
# `IyiThread.start` and of a `@[Share]` def is walked through every def it
# may call, std's and the prelude's included, and a constant or class
# variable met whose type is not Share, and that no proven `@[SafeReach]`
# and no `@[UnsafeReach]` covers, is a compile error. Each program is
# compiled with `iyi build --no-codegen`; nothing is run.
#
#   1. A proc call is followed to the literals it may run (R6), in the
#      runtime's own shapes, which `spec/compiler/semantic/iyi_spec.cr`
#      cannot write without the prelude: a `defer` (and one whose state
#      holds only a number, refused as well: the rule asks the type, not
#      what is stored), a block spawned `unit: :same` inside the unit, a
#      proc handed to a spawn, an `IyiDeferNode` pushed, a `Hash`'s
#      default block, a block handed to a def that calls it, and a kept
#      literal calling its def's block. Each is refused naming the
#      program's state and the path to it. The state between carries a
#      claim - the hash and the proc a proven `@[SafeReach]`, the table
#      and the guard an `@[UnsafeReach]`, since each keeps a copy of
#      itself the proof cannot follow (a handler holding the table, a
#      pushed node) - so the state refused is the one written from the
#      unit.
#   2. std's and the prelude's state is walked: a unit that prints, reads
#      the clock and sets an environment variable compiles, since every
#      piece of runtime state it reaches is Share or marked. Its broken
#      copy, the prelude with the mark taken off the environment's table
#      (`IyiEnvironTable.@@held`, which `ENV[]=` writes from the unit):
#      refused, naming it.
#   3. `iyi fix` claims what it proves: a unit reaching a table that a
#      module fills at its initialisation and only reads after is refused,
#      told the claim is proven; `iyi fix` writes `@[SafeReach]` above the
#      declaration, in the module's own file, and the program compiles. A
#      table the unit writes is refused and left to a hand: `iyi fix`
#      changes nothing.
#   4. Broken copies of the compiler (`IYI_SPAWN_BROKEN`), each a program
#      step 1 refuses that then compiles: kept literals not read as the
#      code that makes them and no proc handed on followed (`creation`:
#      the `unit: :same` block, the handed proc, the `IyiDeferNode` and
#      the block handed to a def; the `defer` is still refused, by its
#      inline copy), no proc call std or the prelude makes followed
#      (`allruntime`: the `Hash`'s default block), no parameter a literal
#      captures bound (`captured`: the kept literal), and no std def
#      entered (`callbacks`: the `Hash`'s default block).
#   5. A std module's claims are proven once, over all of its code, and
#      the answer is reused by every importer (`reach_module_proof.cr`).
#      In a std tree of the test's own: a table read by a probed def is
#      stored as proven for every importer, and an importer whose subclass
#      overrides the method the module hands it to is proven again and
#      refused; a table a block-taking def writes is not stored, so a unit
#      calling that def is refused. Broken copies: `modulereach` stores the
#      second table anyway, and the unit's program compiles on it;
#      `modulepass` takes the first past the override, and so does that
#      program.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PSEP=":"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    WORK="$(cygpath -m "$WORK")"
    PSEP=";"
    ;;
esac

cd "$WORK" || exit 1

step() { echo "== $1"; }

# refused NAME TEXT...: the compile fails, saying every TEXT.
refused() {
  local name="$1"
  shift
  if "$IYI" build --no-codegen -o "$name" "$name.iyi" > "$name.log" 2>&1; then
    echo "$name.iyi compiled, and a unit reaches state that is not Share:"; cat "$name.log"; exit 1
  fi
  local text
  for text in "$@"; do
    if ! grep -qF -- "$text" "$name.log"; then
      echo "$name.iyi was refused, but not with: $text"; cat "$name.log"; exit 1
    fi
  done
  echo "  refused: $name.iyi: $(grep -m1 -o 'reaches `[^`]*`[^:]*' "$name.log" | cut -c1-150)"
}

# compiles NAME [ENV...]: the compile succeeds.
compiles() {
  local name="$1"
  shift
  if ! env "$@" "$IYI" build --no-codegen -o "$name" "$name.iyi" > "$name-ok.log" 2>&1; then
    echo "$name.iyi was refused${1:+ with $*}:"; cat "$name-ok.log"; exit 1
  fi
}

# caught BROKEN NAME: with IYI_SPAWN_BROKEN=BROKEN, NAME.iyi, which the
# sound compiler refuses, compiles.
caught() {
  if env IYI_SPAWN_BROKEN="$1" "$IYI" build --no-codegen -o "$2" "$2.iyi" > "$2-$1.log" 2>&1; then
    echo "  caught: with IYI_SPAWN_BROKEN=$1, $2.iyi compiles"
  else
    echo "the broken copy $1 was not caught: $2.iyi is still refused:"; cat "$2-$1.log"; exit 1
  fi
}

# still_refused BROKEN NAME TEXT: with IYI_SPAWN_BROKEN=BROKEN, NAME.iyi is
# refused all the same, saying TEXT.
still_refused() {
  if env IYI_SPAWN_BROKEN="$1" "$IYI" build --no-codegen -o "$2" "$2.iyi" > "$2-$1.log" 2>&1 || ! grep -qF -- "$3" "$2-$1.log"; then
    echo "with IYI_SPAWN_BROKEN=$1, $2.iyi was not refused with: $3"; cat "$2-$1.log"; exit 1
  fi
  echo "  still refused with IYI_SPAWN_BROKEN=$1: $2.iyi"
}

# The class every step-1 program's unit writes: an `Array` grown in place.
box() {
  cat <<'IYI'
class Box
  def initialize
    @items = [] of String
  end

  def add(item : String) : Nil
    @items << item
  end
end

IYI
}

# ── 1. A proc call, to the literals it may run (R6) ────────────────────────
step "a proc call reaches the literals it may run, and the state they reach is refused"

{ echo 'module r6_defer'; echo; box; cat <<'IYI'
BOX = Box.new

def work(n : Int32) : Int32
  defer BOX.add("item #{n}")
  n + 1
end

group do |g|
  g.spawn(unit: :new) { work(1) }
end
IYI
} > r6_defer.iyi
refused r6_defer 'reaches `BOX : R6Defer::Box` (not Share) through `work` → ' "R6Defer::Box's field @items"

cat > r6_defer_clean.iyi <<'IYI'
module r6_defer_clean

class Counter
  def initialize
    @n = 0_i64
  end

  def bump : Nil
    @n += 1
  end
end

COUNTER = Counter.new

def work(n : Int32) : Int32
  defer COUNTER.bump
  n + 1
end

group do |g|
  g.spawn(unit: :new) { work(1) }
end
IYI
refused r6_defer_clean 'reaches `COUNTER : R6DeferClean::Counter` (not Share) through `work` → ' "R6DeferClean::Counter's field @n is assigned in"

{ echo 'module r6_same'; echo; box; cat <<'IYI'
BOX = Box.new

def work(n : Int32) : Int32
  group do |g|
    g.spawn(unit: :same) do
      BOX.add("item #{n}")
      0
    end
  end
  n
end

group do |g|
  g.spawn(unit: :new) { work(1) }
end
IYI
} > r6_same.iyi
refused r6_same 'reaches `BOX : R6Same::Box` (not Share) through `work` → '

{ echo 'module r6_handed'; echo; box; cat <<'IYI'
BOX = Box.new

@[SafeReach("made once, then only handed to spawns")]
BODY = -> do
  BOX.add("handed")
  0
end

def work(n : Int32) : Int32
  group do |g|
    g.spawn(unit: :same, &BODY)
  end
  n
end

group do |g|
  g.spawn(unit: :new) { work(1) }
end
IYI
} > r6_handed.iyi
refused r6_handed 'reaches `BOX : R6Handed::Box` (not Share) through `work` → '

# The guard's claim is the author's word (`@[UnsafeReach]`, in a module
# marked `@[Unsafe]`): pushing its node keeps a copy of it on the fiber,
# which `@[SafeReach]`'s proof refuses wherever it is kept.
{ echo '@[Unsafe("the gate pushes a defer node by hand")]'; echo 'module r6_node'; echo; box; cat <<'IYI'
BOX = Box.new

class Guard
  def initialize
    @node = IyiDeferNode.new(-> { BOX.add("released"); nil })
  end

  def enter : Nil
    __iyi_defer_push_node(@node)
  end
end

@[UnsafeReach("made once, then only pushed, by the unit that runs its node")]
GUARD = Guard.new

def work(n : Int32) : Int32
  GUARD.enter
  n
end

group do |g|
  g.spawn(unit: :new) { work(1) }
end
IYI
} > r6_node.iyi
refused r6_node 'reaches `BOX : R6Node::Box` (not Share) through `work` → `Guard#enter` → '

{ echo 'module r6_hash'; echo; box; cat <<'IYI'
LOG = Box.new

@[SafeReach("made once, then only read")]
NAMES = Hash(Int32, Int32).new do |table, key|
  LOG.add("missed #{key}")
  key
end

def work(n : Int32) : Int32
  NAMES[n]
end

group do |g|
  g.spawn(unit: :new) { work(1) }
end
IYI
} > r6_hash.iyi
refused r6_hash 'reaches `LOG : R6Hash::Box` (not Share) through `work` → '

{ echo 'module r6_param'; echo; box; cat <<'IYI'
BOX = Box.new

def twice(&block : -> Int32) : Int32
  block.call + block.call
end

def work(n : Int32) : Int32
  twice do
    BOX.add("twice #{n}")
    n
  end
end

group do |g|
  g.spawn(unit: :new) { work(1) }
end
IYI
} > r6_param.iyi
refused r6_param 'reaches `BOX : R6Param::Box` (not Share) through `work` → `BOX.add`'

# The table's claim is the author's word as the guard's is: the handler
# it keeps holds the table, a copy `@[SafeReach]`'s proof refuses.
{ echo '@[Unsafe("the gate keeps its handlers in a table it claims by hand")]'; echo 'module r6_captured'; echo; box; cat <<'IYI'
BOX = Box.new

class Table
  def initialize
    @handlers = [] of Proc(Int32)
  end

  def add(&block : -> String) : Nil
    @handlers << -> { block.call.size }
  end

  def run_all : Int32
    sum = 0
    @handlers.each { |handler| sum += handler.call }
    sum
  end
end

@[UnsafeReach("filled before the first parallel task starts, then only read")]
TABLE = Table.new

TABLE.add do
  BOX.add("route")
  "route"
end

def serve : Int32
  TABLE.run_all
end

group do |g|
  g.spawn(unit: :new) { serve }
end
IYI
} > r6_captured.iyi
refused r6_captured 'reaches `BOX : R6Captured::Box` (not Share) through `serve` → `Table#run_all` → '

# ── 2. std's and the prelude's state ───────────────────────────────────────
step "a unit reaching the runtime's state compiles where the state is Share or marked"
cat > runtime_state.iyi <<'IYI'
module runtime_state

import std/env::{ENV}
import std/time::{Time}

def note(n : Int32) : Int32
  ENV["REACH_RULE_SEEN"] = n.to_s
  puts "unit #{n} at #{Time.monotonic.to_s}"
  n
end

group do |g|
  g.spawn(unit: :new) { note(1) }
end
IYI
compiles runtime_state
echo "  compiles: runtime_state.iyi (prints, reads the clock, sets ENV from a unit)"
mkdir -p unmarked/iyi
cp "$REPO"/src/iyi/*.iyi unmarked/iyi/
awk '/written only by std\/env.s writes/ { next } { print }' "$REPO/src/iyi/prelude.iyi" > unmarked/iyi/prelude.iyi
if cmp -s unmarked/iyi/prelude.iyi "$REPO/src/iyi/prelude.iyi"; then
  echo "the awk for the unmarked prelude found nothing to change"; exit 1
fi
if IYI_PATH="$WORK/unmarked${PSEP}$REPO/src" "$IYI" build --no-codegen -o runtime_state runtime_state.iyi > unmarked.log 2>&1; then
  echo "the prelude without the mark on IyiEnvironTable.@@held was not refused:"; cat unmarked.log; exit 1
fi
if ! grep -qF 'reaches `@@held : Pointer(Pointer(UInt8))` (not Share) through `note` → ' unmarked.log; then
  echo "the prelude without the mark was refused, but not for @@held:"; cat unmarked.log; exit 1
fi
echo "  broken copy, the mark taken off @@held: refused, $(grep -m1 -o 'reaches `@@held[^:]*' unmarked.log | cut -c1-120)"

# ── 3. iyi fix ─────────────────────────────────────────────────────────────
step "iyi fix writes the claim it proves, in the file that declares the state"
mkdir -p fixed/dep
cat > fixed/dep/table.iyi <<'IYI'
module dep/table

pub class Rows
  def initialize
    @rows = [] of Int32
  end

  def add(n : Int32) : Nil
    @rows << n
  end

  def first : Int32
    @rows[0]
  end
end

ROWS = Rows.new
ROWS.add(7)

pub def first_row : Int32
  ROWS.first
end
IYI
cat > fixed/main.iyi <<'IYI'
module main

import dep/table::{first_row}

group do |g|
  g.spawn(unit: :new) { first_row }
end
IYI
if (cd fixed && "$IYI" build --no-codegen -o main main.iyi) > fix-before.log 2>&1; then
  echo "the program reaching ROWS compiled before iyi fix:"; cat fix-before.log; exit 1
fi
if ! grep -qF 'so a claim is proven: `iyi fix` adds `@[SafeReach("set before the first parallel task starts, then only read")]`' fix-before.log; then
  echo "the refusal did not offer the claim:"; cat fix-before.log; exit 1
fi
if ! (cd fixed && "$IYI" fix main.iyi) > fix.log 2>&1; then
  echo "iyi fix did not end clean:"; cat fix.log; exit 1
fi
if ! grep -qxF '@[SafeReach("set before the first parallel task starts, then only read")]' fixed/dep/table.iyi \
  || ! grep -A1 -F '@[SafeReach(' fixed/dep/table.iyi | grep -qxF 'ROWS = Rows.new'; then
  echo "iyi fix did not write the claim above ROWS in dep/table.iyi:"; cat fix.log; cat fixed/dep/table.iyi; exit 1
fi
if ! (cd fixed && "$IYI" build --no-codegen -o main main.iyi) > fix-after.log 2>&1; then
  echo "the program did not compile after iyi fix:"; cat fix-after.log; exit 1
fi
echo "  claimed by iyi fix in dep/table.iyi, then compiles"
mkdir -p handed/dep
awk '/^@\[SafeReach\(/ { next } { print } /^pub def first_row : Int32$/ { print "  ROWS.add(8)" }' fixed/dep/table.iyi > handed/dep/table.iyi
if ! grep -qxF '  ROWS.add(8)' handed/dep/table.iyi; then
  echo "the awk for the written table found nothing to change"; exit 1
fi
cp fixed/main.iyi handed/main.iyi
cp handed/dep/table.iyi handed-before.iyi
if (cd handed && "$IYI" fix main.iyi) > handed.log 2>&1; then
  echo "iyi fix ended clean on a table the unit writes:"; cat handed.log; exit 1
fi
if ! cmp -s handed/dep/table.iyi handed-before.iyi || ! grep -qF 'A claim here would not be proven, so `iyi fix` leaves it to a hand' handed.log; then
  echo "iyi fix changed a table the unit writes, or did not say why it left it:"; cat handed.log; cat handed/dep/table.iyi; exit 1
fi
echo "  a table the unit writes: refused, left to a hand, the file unchanged"

# ── 4. Broken copies of the compiler ───────────────────────────────────────
step "failure proofs: broken copies of the walk"
for name in r6_same r6_handed r6_node r6_param; do caught creation "$name"; done
still_refused creation r6_defer 'reaches `BOX : R6Defer::Box` (not Share)'
caught allruntime r6_hash
caught captured r6_captured
caught callbacks r6_hash

# ── 5. A std module's claims, proven once and reused ───────────────────────
step "a std module's claims are proven once, over all of its code, and reused"
# Two modules of a std tree of the test's own (std is a module whose tree
# holds the prelude), each with a table claimed safe. `reachtable` also
# has a def that writes its table and takes a block, which no
# definition-site probe calls; `reachpass` hands its table to a method of
# a class the importer may inherit.
mkdir -p mystd/iyi mystd/std
cp "$REPO"/src/iyi/*.iyi mystd/iyi/
cat > mystd/std/reachtable.iyi <<'IYI'
module std/reachtable

@[SafeReach("filled at module start, then only read")]
TABLE = [3, 1, 2]
TABLE.sort_in_place

pub def lowest : Int32
  TABLE[0]
end

pub def each_grown(& : Int32 -> Nil) : Nil
  TABLE << TABLE.size
  yield TABLE.size
end
IYI
cat > mystd/std/reachpass.iyi <<'IYI'
module std/reachpass

@[SafeReach("filled at module start, then only read")]
NAMES = ["a", "b"]

pub class Sink
  def take(names : Array(String)) : Int32
    names.size
  end
end

pub def feed(sink : Sink) : Int32
  sink.take(NAMES)
end
IYI
cat > lowest.iyi <<'IYI'
module lowest

import std/reachtable::{lowest}

group do |g|
  g.spawn(unit: :new) { lowest }
end
IYI
cat > grown.iyi <<'IYI'
module grown

import std/reachtable::{each_grown}

group do |g|
  g.spawn(unit: :new) { each_grown { |n| puts n } }
end
IYI
cat > fed.iyi <<'IYI'
module fed

import std/reachpass::{Sink, feed}

group do |g|
  g.spawn(unit: :new) { feed(Sink.new) }
end
IYI
cat > spilled.iyi <<'IYI'
module spilled

import std/reachpass::{Sink, feed}

class Spill < Sink
  def take(names : Array(String)) : Int32
    names << "x"
    names.size
  end
end

group do |g|
  g.spawn(unit: :new) { feed(Spill.new) }
end
IYI
# in_std CACHE NAME [VAR=VALUE...]: NAME.iyi built against the test's std,
# with its own compiler cache, where a module's answer is stored.
in_std() {
  local cache="$1" name="$2"
  shift 2
  env IYI_PATH="$WORK/mystd${PSEP}$REPO/src" IYI_CACHE_DIR="$WORK/$cache" "$@" \
    "$IYI" build --no-codegen -o "$name" "$name.iyi" > "$name-$cache.log" 2>&1
}
answers() { cat "$WORK/$1"/reach-* 2> /dev/null; }
if ! in_std sound lowest; then
  echo "lowest.iyi was refused:"; cat lowest-sound.log; exit 1
fi
if ! answers sound | grep -qxF 'iyi reach verdict 2' || ! answers sound | grep -q "^dormant	each_grown	"; then
  echo "the proof of std/reachtable stored no answer, or stored TABLE without each_grown, which it never read, as dormant:"; answers sound; exit 1
fi
echo "  lowest.iyi compiles; std/reachtable's answer holds TABLE only for an importer that never types each_grown, which writes it and no probe can call"
if in_std sound grown || ! grep -qF 'is refused: nothing proves every thread may reach it safely' grown-sound.log || ! grep -qF 'TABLE' grown-sound.log; then
  echo "grown.iyi, whose unit calls each_grown, was not refused for TABLE:"; cat grown-sound.log; exit 1
fi
echo "  refused: grown.iyi, whose unit calls each_grown"
if ! in_std sound fed; then
  echo "fed.iyi was refused:"; cat fed-sound.log; exit 1
fi
if ! answers sound | grep -q '^state.*NAMES'; then
  echo "the proof of std/reachpass did not store NAMES:"; answers sound; exit 1
fi
echo "  fed.iyi compiles, and std/reachpass's answer proves NAMES for every importer"
if in_std sound spilled || ! grep -qF 'is refused: nothing proves every thread may reach it safely' spilled-sound.log || ! grep -qF 'NAMES' spilled-sound.log; then
  echo "spilled.iyi, whose subclass writes what feed hands it, was not refused for NAMES:"; cat spilled-sound.log; exit 1
fi
echo "  refused: spilled.iyi, the stored answer set aside for its override of Sink#take"
if in_std broken-cover lowest IYI_SPAWN_BROKEN=modulereach && in_std broken-cover grown IYI_SPAWN_BROKEN=modulereach; then
  echo "  caught: with IYI_SPAWN_BROKEN=modulereach, grown.iyi compiles on the answer lowest.iyi's build stored"
else
  echo "the broken copy modulereach was not caught:"; cat lowest-broken-cover.log grown-broken-cover.log; exit 1
fi
if in_std broken-pass fed && in_std broken-pass spilled IYI_SPAWN_BROKEN=modulepass; then
  echo "  caught: with IYI_SPAWN_BROKEN=modulepass, spilled.iyi compiles on the answer fed.iyi's build stored"
else
  echo "the broken copy modulepass was not caught:"; cat fed-broken-pass.log spilled-broken-pass.log; exit 1
fi

echo "reach_rule: every refusal holds, and every broken copy is caught"
