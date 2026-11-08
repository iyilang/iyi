#!/usr/bin/env bash
# `@[SafeReach("why")]` proven, not trusted (SPEC.md III.4.4).
#
#     bash bench/safe_reach.sh
#
# The mark quiets the reach warning for the state it is on and lets a
# spawn that reaches that state run in parallel, so it says every thread
# may reach the state safely. The compiler accepts it only when it can
# prove that, and otherwise refuses the annotation, naming a write that
# breaks it and where that write may run from. Each program is checked
# with `iyi check --error-on-warnings`; nothing is run.
#
#   1. The write nothing guards: #148's pool, a constant whose method
#      assigns a field, called from two parallel tasks under a claim that
#      one task asks. Refused, naming `DATABASE.query_one(n)` in `ask`,
#      the field it assigns and the parallel block it runs from. Before
#      the proof this program checked clean.
#   2. (a) A `Share` type, an `Atomic`, reached through `bump`: accepted.
#      Its broken copy, the same constant a counter class whose `add`
#      assigns a field: refused, naming `COUNT.add(1_i64)` in `bump`.
#   3. (b) Every write and every read behind one `Mutex#lock`: accepted.
#      Its broken copies: one task writes outside the lock, refused naming
#      the write; one reads outside it, refused naming the read.
#   4. (c) Every write at module init, before the first parallel task,
#      then only read: accepted. Its broken copies: one writes once more
#      after the group that starts the tasks, refused naming that
#      statement; one keeps a copy at module init (`COPIES = [TABLE]`)
#      and writes through it later, refused naming the copy, since a
#      copy kept where the proof cannot follow may be written anywhere.
#      A constant whose initializer writes the state, declared before the
#      first parallel task and first read by a task: accepted, since the
#      initializer runs at the declaration. Its broken copy, the same
#      constant declared after the tasks, which a task's read initializes:
#      refused, naming the write in the initializer's call. A def that
#      spawns, declared above the writes and called after them: accepted,
#      since a declaration starts nothing (R-2c's probe of it never runs).
#      Its broken copy, the same def called above the writes: refused,
#      naming that call as the first start. A start in a module the
#      writer's module neither imports nor is imported by, run first by
#      the program's import order: accepted. Its broken copy, the writer's
#      module importing it: refused, naming that module's spawn. A start
#      reached only through a block of the importer's, which std's proc
#      calls are taken to run: accepted. Its broken copy, the block in the
#      writer's module: refused, naming the module's `LOCK` as the start.
#   5. `@[UnsafeReach]`, the claim nothing checks, in a module marked
#      `@[Unsafe("why")]` (SPEC.md III.13): accepted for the program step 1
#      refuses. Its broken copy, the same module without the mark, still
#      reading through a `Pointer`: refused, since the unsafe spelling is
#      kept for modules that say they are outside what the compiler proves.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

cd "$WORK" || exit 1

step() { echo "== $1"; }

# accepted NAME: checks clean, with no warning, under --error-on-warnings.
accepted() {
  if ! "$IYI" check --error-on-warnings "$1.iyi" > "$1.log" 2>&1; then
    echo "$1.iyi was refused, and its claim holds:"; cat "$1.log"; exit 1
  fi
  echo "  accepted: $1.iyi"
}

# refused NAME TEXT...: the check fails, with every TEXT in what it says.
# Windows spells a module's file `dep\table.iyi` where TEXT says
# `dep/table.iyi`, so what it says is read with `/` for `\`.
refused() {
  local name="$1"
  shift
  if "$IYI" check "$name.iyi" > "$name.log" 2>&1; then
    echo "$name.iyi checked clean, and its claim does not hold:"; cat "$name.log"; exit 1
  fi
  tr '\\' '/' < "$name.log" > "$name.said"
  local text
  for text in "$@"; do
    if ! grep -qF -- "$text" "$name.said"; then
      echo "$name.iyi was refused, but not with \"$text\":"; cat "$name.log"; exit 1
    fi
  done
  echo "  refused:  $name.iyi: $(grep -m1 '^Error: ' "$name.log" | cut -c8-200)..."
}

# derive FROM TO AWK: TO is FROM edited by AWK, which must change it.
derive() {
  awk "$3" "$1.iyi" > "$2.iyi"
  if cmp -s "$1.iyi" "$2.iyi"; then
    echo "the edit making $2.iyi from $1.iyi found nothing to change"; exit 1
  fi
}

# ── 1. The write nothing guards ─────────────────────────────────────────
step "a write from two parallel tasks under SafeReach is refused"
cat > unguarded.iyi <<'IYI'
module unguarded

class Database
  def initialize
    @total = 0
  end

  def query_one(n : Int64) : Int64
    @total += 1
    n
  end
end

@[SafeReach("one task asks at a time")]
DATABASE = Database.new

def ask(n : Int64) : Int64
  DATABASE.query_one(n)
end

group do |g|
  g.spawn(unit: :new) { ask(1_i64) }
  g.spawn(unit: :new) { ask(2_i64) }
end
IYI
refused unguarded '@[SafeReach] on `DATABASE` is refused' \
  '`DATABASE.query_one(n)` in `ask` at unguarded.iyi:18:12 writes it (`Database#query_one` assigns `@total`' \
  'the block `spawn(unit: :new)` runs as a parallel task, at unguarded.iyi:22:5, which calls `ask`'

# ── 2. (a) A Share type ───────────────────────────────────────────────────
step "(a) a Share type is accepted"
cat > counted.iyi <<'IYI'
module counted

@[SafeReach("an Atomic: each add is one instruction")]
COUNT = Atomic(Int64).new(0_i64)

def bump : Int64
  COUNT.add(1_i64)
end

group do |g|
  g.spawn(unit: :new) { bump }
  g.spawn(unit: :new) { bump }
end
IYI
accepted counted
derive counted counted_broken '
/^module counted$/ { print "module counted_broken"; print ""; print "class Counter"; print "  def initialize"; print "    @n = 0_i64"; print "  end"; print ""; print "  def add(k : Int64) : Int64"; print "    @n += k"; print "  end"; print "end"; next }
/^COUNT = / { print "COUNT = Counter.new"; next }
{ print }'
refused counted_broken '@[SafeReach] on `COUNT` is refused' \
  '`COUNT.add(1_i64)` in `bump`' '`Counter#add` assigns `@n`'

# ── 3. (b) Behind one lock ────────────────────────────────────────────────
step "(b) every write and read behind one Mutex#lock is accepted"
cat > locked.iyi <<'IYI'
module locked

import std/mutex::{Mutex}

class Table
  def initialize
    @rows = [] of String
  end

  def add(row : String) : Nil
    @rows << row
  end

  def first_size : Int32
    @rows[0].size
  end
end

LOCK = Mutex.new { 0 }

@[SafeReach("every write and every read is behind LOCK")]
TABLE = Table.new

def keep(row : String) : Nil
  TABLE.add(row)
end

def first_size : Int32
  TABLE.first_size
end

group do |g|
  g.spawn(unit: :new) do
    LOCK.lock { |_| keep("a") }
    0
  end
  g.spawn(unit: :new) do
    LOCK.get { |_| first_size }
  end
end
IYI
accepted locked
derive locked locked_write '
/^module locked$/ { print "module locked_write"; next }
/LOCK.get \{ \|_\| first_size \}/ { print "    keep(\"b\")"; print "    0"; next }
{ print }'
refused locked_write '@[SafeReach] on `TABLE` is refused' \
  '`TABLE.add(row)` in `keep`' '`Table#add` → `Array#<<`' \
  'the block `spawn(unit: :new)` runs as a parallel task, at locked_write.iyi:37:5, which calls `keep`'
derive locked locked_read '
/^module locked$/ { print "module locked_read"; next }
/LOCK.get \{ \|_\| first_size \}/ { print "    first_size"; next }
{ print }'
refused locked_read '@[SafeReach] on `TABLE` is refused' \
  "writes it behind \`LOCK\`'s lock, but \`TABLE\` is read at locked_read.iyi:29:3, with no lock" \
  'the block `spawn(unit: :new)` runs as a parallel task, at locked_read.iyi:37:5, which calls `first_size`'

# ── 4. (c) Before the first parallel task ─────────────────────────────────
step "(c) every write at module init, then only read, is accepted"
cat > startup.iyi <<'IYI'
module startup

class Table
  def initialize
    @rows = [] of String
  end

  def add(row : String) : Nil
    @rows << row
  end

  def first_size : Int32
    @rows[0].size
  end
end

@[SafeReach("filled at module init, then only read")]
TABLE = Table.new
TABLE.add("hello")
TABLE.add("world")

def first_size : Int32
  TABLE.first_size
end

group do |g|
  g.spawn(unit: :new) { first_size }
  g.spawn(unit: :new) { first_size }
end
IYI
accepted startup
derive startup startup_late '
/^module startup$/ { print "module startup_late"; next }
{ print }
END { print "TABLE.add(\"late\")" }'
refused startup_late '@[SafeReach] on `TABLE` is refused' \
  '`TABLE.add("late")` in the program'"'"'s top level at startup_late.iyi:30:7' \
  'after the statement at startup_late.iyi:26:1 may start the first parallel task'
derive startup startup_copied '
/^module startup$/ { print "module startup_copied"; next }
/^TABLE.add\("world"\)$/ { print; print "COPIES = [TABLE]"; next }
{ print }
END { print "COPIES.first.add(\"late\")" }'
refused startup_copied '@[SafeReach] on `TABLE` is refused' \
  'keeps a copy of it where the proof cannot follow (`Pointer#[]=` stores it in memory' \
  'whatever writes through that copy may do so anywhere'

step "(c) a constant whose initializer writes the state is placed where it runs"
# A constant's initializer runs at its declaration, or at its first read
# when that comes first. Both measured on Linux with an initializer that
# prints: `EARLY = f("early")` printed "init early" between the
# statements around it, and `LATE`, read by a call above its declaration,
# printed "init late" at that read. The proof places the initializer at
# the declaration. Declared before the first parallel task, it has run by
# then whoever reads it first: accepted. Declared after, a task's read may
# be the first and run it there: refused, as any write after the first
# parallel task is - the one case a read before the declaration makes.
cat > startup_early.iyi <<'IYI'
module startup_early

class Table
  def initialize
    @rows = [] of String
  end

  def add(row : String) : Nil
    @rows << row
  end

  def first_size : Int32
    @rows[0].size
  end
end

@[SafeReach("filled at module init, then only read")]
TABLE = Table.new

def fill : Int32
  TABLE.add("hello")
  1
end

def early : Int32
  EARLY
end

def first_size : Int32
  TABLE.first_size
end

EARLY = fill

group do |g|
  g.spawn(unit: :new) { early }
  g.spawn(unit: :new) { first_size }
end
IYI
accepted startup_early
derive startup_early startup_before '
/^module startup_early$/ { print "module startup_before"; next }
/^EARLY = fill$/ { next }
{ print }
END { print "EARLY = fill" }'
refused startup_before '@[SafeReach] on `TABLE` is refused' \
  '`TABLE.add("hello")` in `fill`' \
  'it may run once a parallel task has started'

step "(c) a def that spawns starts nothing until it is called"
# R-2c types every fully declared def at its definition through a probe
# that calls it under `if false`, prepended to the program; the proof read
# the probe of `scan` as the first statement that may start a parallel
# task, and refused this program, naming `TABLE.add("hello")` as written
# after the statement at `def scan` (met building `bench/spawn_fuzz.py`:
# any module with a fully declared def that spawned refused every claim
# written at module init).
cat > startup_def.iyi <<'IYI'
module startup_def

class Table
  def initialize
    @rows = [] of String
  end

  def add(row : String) : Nil
    @rows << row
  end

  def first_size : Int32
    @rows[0].size
  end
end

@[SafeReach("filled at module init, then only read")]
TABLE = Table.new

def first_size : Int32
  TABLE.first_size
end

def scan : Int32
  seen = Atomic(Int32).new(0)
  group do |g|
    g.spawn(unit: :new) { seen.add(first_size) }
    g.spawn(unit: :new) { seen.add(first_size) }
  end
  seen.get
end

TABLE.add("hello")
TABLE.add("world")
puts scan
IYI
accepted startup_def
derive startup_def startup_def_early '
/^module startup_def$/ { print "module startup_def_early"; next }
/^TABLE.add\("hello"\)$/ { print "puts scan" }
{ print }'
refused startup_def_early '@[SafeReach] on `TABLE` is refused' \
  '`TABLE.add("hello")` in the program'"'"'s top level at startup_def_early.iyi:34:7' \
  'after the statement at startup_def_early.iyi:33:1 may start the first parallel task'

step "(c) a start in a module the writer's module does not import comes before nothing it writes"
# A module's initialiser runs after the modules it imports and before
# those importing it; where it falls among the others is each program's
# import order. `dep/busy`'s spawn, which `app.iyi` imports first, made
# `dep/table`'s `TABLE.add("hello")` a write after the first parallel
# task, while a program importing them the other way proved the claim -
# and wrote `dep/table`'s artifact without `TABLE` in what it reaches, as
# a claim that holds for every importer (found by `bench/spawn_fuzz.py`,
# seed 2364). `dep/busy` names nothing of `dep/table`, and its tasks are
# joined before `dep/table`'s initialiser runs: accepted. Its broken
# copy, `dep/table` importing `dep/busy`: refused, naming the spawn.
mkdir -p order/dep
cat > order/dep/table.iyi <<'IYI'
module dep/table

class Table
  def initialize
    @rows = [] of String
  end

  def add(row : String) : Nil
    @rows << row
  end

  def first_size : Int32
    @rows[0].size
  end
end

@[SafeReach("filled at module init, then only read")]
TABLE = Table.new
TABLE.add("hello")

pub def first_size : Int32
  TABLE.first_size
end
IYI
cat > order/dep/busy.iyi <<'IYI'
module dep/busy

pub def ready : Int32
  1
end

done = Atomic(Int32).new(0)
group do |g|
  g.spawn(unit: :new) { done.add(ready) }
end
IYI
cat > order/app.iyi <<'IYI'
module main

import dep/busy::{ready}
import dep/table::{first_size}

seen = Atomic(Int32).new(0)
group do |g|
  g.spawn(unit: :new) { seen.add(first_size) }
  g.spawn(unit: :new) { seen.add(ready) }
end
puts seen.get
IYI
(cd order && accepted app) || exit 1
cp -r order order_imports
awk '/^module dep\/table$/ { print; print ""; print "import dep/busy::{ready}"; next } { print }' order/dep/table.iyi > order_imports/dep/table.iyi
(cd order_imports && refused app '@[SafeReach] on `TABLE` is refused' \
  '`TABLE.add("hello")` in the program'"'"'s top level at dep/table.iyi:21:7' \
  'after the statement at dep/busy.iyi:8:1 may start the first parallel task') || exit 1

step "(c) a block of the importer's is no start in the module it imports"
# A proc call reaches every literal of its type, so std's `IyiDeferNode#run`
# (`raise` → `IyiScheduler.panic_current` runs the defers) reaches every
# `-> Nil` block, and `Mutex.new`'s initializer reaches `raise` through its
# release node. A block of the program's that starts a group so made
# `LOCK = Mutex.new { 0 }` in `dep/table` a start, refusing the claim its
# initialiser writes after it, while the build that wrote the artifact,
# without such a block, proved it and recorded it as holding for every
# importer (`bench/spawn_fuzz.py`, seeds 75, 2046, 2054, 2248, 2256, 2364
# and 2388). The program's block exists only once `dep/table`'s
# initialiser has run: accepted. Its broken copy, the same block in
# `dep/table`, which every program importing it has: refused, naming
# `LOCK`.
mkdir -p nested/dep
cat > nested/dep/table.iyi <<'IYI'
module dep/table

import std/mutex::{Mutex}

class Table
  def initialize
    @rows = [] of String
  end

  def add(row : String) : Nil
    @rows << row
  end

  def first_size : Int32
    @rows[0].size
  end
end

LOCK = Mutex.new { 0 }

@[SafeReach("filled at module init, then only read")]
TABLE = Table.new
TABLE.add("hello")

pub def first_size : Int32
  TABLE.first_size
end

pub def count(n : Int32) : Int32
  LOCK.lock { |_| n }
  n
end

pub def fan(t : Int32) : Nil
  group do |g|
    t.times { g.spawn(unit: :new) { count(1); nil } }
  end
end
IYI
cat > nested/app.iyi <<'IYI'
module main

import dep/table::{first_size, fan}

seen = Atomic(Int32).new(0)
group do |g|
  g.spawn(unit: :new) { seen.add(first_size) }
  g.spawn { fan(2); nil }
end
puts seen.get
IYI
(cd nested && accepted app) || exit 1
cp -r nested nested_own
cat >> nested_own/dep/table.iyi <<'IYI'

pub def nest : Nil
  group do |g|
    g.spawn { fan(2); nil }
  end
end
IYI
(cd nested_own && refused app '@[SafeReach] on `TABLE` is refused' \
  '`TABLE.add("hello")` in the program'"'"'s top level at dep/table.iyi:23:7' \
  'after the statement at dep/table.iyi:19:1 may start the first parallel task') || exit 1

# ── 5. UnsafeReach, where it is allowed ───────────────────────────────────
step "@[UnsafeReach] is kept for a module marked @[Unsafe]"
derive unguarded marked '
/^module unguarded$/ { print "@[Unsafe(\"hands a raw byte to its caller\")]"; print "module marked"; next }
/^@\[SafeReach/ { print "@[UnsafeReach(\"one task asks at a time\")]"; next }
{ print }
END { print "puts Pointer(UInt8).malloc(1_u64).address > 0_u64" }'
accepted marked
derive marked unsafe_plain '
/^module marked$/ { print "module unsafe_plain"; next }
/^@\[Unsafe\(/ { next }
{ print }'
refused unsafe_plain '@[UnsafeReach] on `DATABASE` is the claim the compiler takes on trust' \
  '`unsafe_plain` is not marked unsafe'

echo "every SafeReach claim was proven or refused as it should be"
