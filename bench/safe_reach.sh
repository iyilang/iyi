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
#   5. `@[UnsafeReach]`, the claim nothing checks, in a file that uses
#      `Pointer`: accepted for the program step 1 refuses. Its broken copy,
#      the same program without a `Pointer`: refused, since the unsafe
#      spelling is kept for the prelude and for files already outside
#      what the compiler proves.
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
refused() {
  local name="$1"
  shift
  if "$IYI" check "$name.iyi" > "$name.log" 2>&1; then
    echo "$name.iyi checked clean, and its claim does not hold:"; cat "$name.log"; exit 1
  fi
  local text
  for text in "$@"; do
    if ! grep -qF -- "$text" "$name.log"; then
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
  g.spawn(parallel: true) { ask(1_i64) }
  g.spawn(parallel: true) { ask(2_i64) }
end
IYI
refused unguarded '@[SafeReach] on `DATABASE` is refused' \
  '`DATABASE.query_one(n)` in `ask` at unguarded.iyi:18:12 writes it (`Database#query_one` assigns `@total`' \
  'the block `spawn(parallel: true)` runs as a parallel task, at unguarded.iyi:22:5, which calls `ask`'

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
  g.spawn(parallel: true) { bump }
  g.spawn(parallel: true) { bump }
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
  g.spawn(parallel: true) do
    LOCK.lock { |_| keep("a") }
    0
  end
  g.spawn(parallel: true) do
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
  'the block `spawn(parallel: true)` runs as a parallel task, at locked_write.iyi:37:5, which calls `keep`'
derive locked locked_read '
/^module locked$/ { print "module locked_read"; next }
/LOCK.get \{ \|_\| first_size \}/ { print "    first_size"; next }
{ print }'
refused locked_read '@[SafeReach] on `TABLE` is refused' \
  "writes it behind \`LOCK\`'s lock, but \`TABLE\` is read at locked_read.iyi:29:3, with no lock" \
  'the block `spawn(parallel: true)` runs as a parallel task, at locked_read.iyi:37:5, which calls `first_size`'

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
  g.spawn(parallel: true) { first_size }
  g.spawn(parallel: true) { first_size }
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

# ── 5. UnsafeReach, where it is allowed ───────────────────────────────────
step "@[UnsafeReach] is kept for a file that uses Pointer"
derive unguarded unsafe '
/^module unguarded$/ { print "module unsafe"; next }
/^@\[SafeReach/ { print "@[UnsafeReach(\"one task asks at a time\")]"; next }
{ print }
END { print "puts Pointer(UInt8).malloc(1_u64).address > 0_u64" }'
accepted unsafe
derive unsafe unsafe_plain '
/^module unsafe$/ { print "module unsafe_plain"; next }
/Pointer/ { next }
{ print }'
refused unsafe_plain '@[UnsafeReach] on `DATABASE` is not allowed here' \
  'kept for the prelude and runtime (src/iyi) and for a file that already uses `Pointer`'

echo "every SafeReach claim was proven or refused as it should be"
