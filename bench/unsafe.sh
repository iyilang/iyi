#!/usr/bin/env bash
# Unsafe code is code in a module that says so (SPEC.md III.13).
#
#     bash bench/unsafe.sh
#
# An operation the compiler does not check - a value whose type is or
# holds a `Pointer`, `uninitialized`, a `lib`, a `fun`, `asm`,
# `@[Primitive]`, `@[Extern]`, a call to a def whose caller keeps a
# promise (`@[Unsafe(call: "...")]`), and the trust marks `@[Share]` and
# `@[UnsafeReach]` - is allowed in a module whose first statement is
# `@[Unsafe("why")]` and refused in every other `.iyi` file.
#
#   1. Every way out of the checked language SPEC.md III.13 lists is a
#      program that compiled clean before this check: each is refused,
#      naming the operation, and its copy marked `@[Unsafe("...")]` above
#      its first line is accepted. The refused program is the marked
#      one's broken copy: the mark taken away.
#   2. What a module reads bytes with when it does not handle raw memory -
#      `String#byte_at`, `Bytes.of`, `String.new(Bytes)`,
#      `String.new(Array(UInt8))`, `IyiIO#write(Bytes)` - and the literals
#      the compiler expands through a buffer are accepted unmarked, as is a
#      def over a trait typed through the witness the compiler writes.
#   3. A mark without a reason is refused; a mark nothing needs is warned
#      of, and fails under `--error-on-warnings`. Its broken copy, the same
#      mark on a module that uses `to_unsafe`, is neither, and nor is a
#      module whose unsafe code sits behind another target's
#      `{% if flag?(...) %}`.
#   4. `iyi fix` writes the mark, with the reason the compiler saw, into
#      the h1b program step 1 refuses, and the result checks clean.
#   5. A module marked `@[Unsafe]` built as a `.iyimod` keeps its mark:
#      `mod dump` prints it, and an unmarked importer that instantiates its
#      generic - whose body travels and is typed again in the importer -
#      builds against the artifact with the source gone. Its broken copy,
#      the producer unmarked, is refused naming the producer.
#   6. A program that faults in its own marked module is told so: the
#      memory-fault message names the module.
#   7. `--crystal` and `.cr` files are unaffected: a `.cr` program that
#      reads through a `Pointer` builds under `--crystal`.
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

# accepted NAME [FLAGS...]: `iyi check` passes.
accepted() {
  local name="$1"
  shift
  if ! "$IYI" check "$@" "$name.iyi" > "$name.log" 2>&1; then
    echo "$name.iyi was refused:"; cat "$name.log"; exit 1
  fi
  echo "  accepted: $name.iyi"
}

# refused NAME TEXT...: `iyi check` fails, with every TEXT in what it says.
refused() {
  local name="$1"
  shift
  if "$IYI" check "$name.iyi" > "$name.log" 2>&1; then
    echo "$name.iyi checked clean:"; cat "$name.log"; exit 1
  fi
  tr '\\' '/' < "$name.log" > "$name.said"
  local text
  for text in "$@"; do
    if ! grep -qF -- "$text" "$name.said"; then
      echo "$name.iyi was refused, but not with \"$text\":"; cat "$name.log"; exit 1
    fi
  done
  echo "  refused:  $name.iyi: $(grep -m1 '^Error: ' "$name.log" | cut -c8-160)..."
}

# route NAME TEXT...: NAME.iyi is refused with every TEXT, and its copy
# marked above its first line is accepted.
route() {
  local name="$1"
  shift
  refused "$name" "$@" "is not marked unsafe" '@[Unsafe("...")]'
  { echo "@[Unsafe(\"the gate's program for this route\")]"; cat "$name.iyi"; } > "${name}_marked.iyi"
  accepted "${name}_marked"
}

# ── 1. Every way out ─────────────────────────────────────────────────────
step "every way out of the checked language is refused unmarked and accepted marked"

cat > h1b.iyi <<'IYI'
name = "x" * 64
group do |g|
  4.times { |t| g.spawn { 200_000.times { |i| name.to_unsafe[i % 64] = (65 + t).to_u8 }; 0 } }
end
puts name
IYI
route h1b '`name.to_unsafe` answers `Pointer(UInt8)`' 'Read a byte with `byte_at(i)`'

cat > strnew.iyi <<'IYI'
s = String.new(3) { |b| b[0] = 65_u8; b[1] = 66_u8; b[2] = 67_u8 }
puts s
IYI
route strnew '`b` is a `Pointer(UInt8)`'

cat > build.iyi <<'IYI'
b = Array(String).unsafe_build(4)
b.unsafe_set_size(1_000_000)
puts b[999_999]
IYI
route build 'promises "every element below the capacity is written before it is read"'

cat > fetch.iyi <<'IYI'
import std/slice::{Slice}
s = Slice(Int32).new(3, 0)
puts s.unsafe_fetch(5)
IYI
route fetch '`Std::Slice::Slice(Int32)#unsafe_fetch` promises "index is in 0...size"' 'Use `[]`, which checks the index'

cat > view.iyi <<'IYI'
import std/slice::{Slice}
s = Slice(UInt8).new("hello".to_unsafe, 1_000_000)
puts s[999_999]
IYI
route view '`"hello".to_unsafe` answers `Pointer(UInt8)`'

cat > unwritten.iyi <<'IYI'
s = uninitialized String
puts s.size
IYI
route unwritten '`uninitialized String` is a value nothing has written'

cat > alias.iyi <<'IYI'
alias P = Pointer(UInt8)
def first(p : P) : UInt8
  p.value
end
puts "x".size
IYI
route alias '`p` is a `Pointer(UInt8)`'

cat > generic.iyi <<'IYI'
class Box(T)
  def initialize(@v : T)
  end

  def v : T
    @v
  end
end
b = Box.new("abc".to_unsafe)
puts b.v.value
IYI
route generic 'Box(Pointer(UInt8))'

cat > address.iyi <<'IYI'
class A
  @x = 1

  def x : Int32
    @x
  end
end
z = 42_u64
puts pointerof(z).as(A).x
IYI
route address '`pointerof(z)` takes an address'

cat > clib.iyi <<'IYI'
class O
  @v = 7

  def v : Int32
    @v
  end
end

lib LibZero
  fun explicit_bzero(p : UInt8*, n : UInt64) : Nil
end
o = O.new
LibZero.explicit_bzero(o.as(UInt8*), 64_u64)
puts o.v
IYI
route clib '`lib LibZero` declares C functions the compiler does not check'

cat > cfun.iyi <<'IYI'
fun cb(a : UInt64) : UInt64
  a
end
puts 1
IYI
route cfun '`fun cb` is a C function the compiler does not check'

cat > machine.iyi <<'IYI'
def f : Int32
  asm("nop")
  1
end
puts f
IYI
route machine '`asm` is machine code the compiler does not check'

cat > primitive.iyi <<'IYI'
class Foo
  @[Primitive(:class)]
  def k
  end
end
puts 1
IYI
route primitive "@[Primitive] makes \`k\` the compiler's own code"

cat > extern.iyi <<'IYI'
@[Extern]
struct Pair
  @a = 0
  @b = 0
end
puts 1
IYI
route extern '@[Extern] makes `Pair` a C struct the compiler does not check'

cat > trusted.iyi <<'IYI'
@[Share]
class Counter
  @n = 0

  def bump : Nil
    @n = @n + 1
  end

  def n : Int32
    @n
  end
end
c = Counter.new
group do |g|
  4.times { g.spawn { 100_000.times { c.bump }; 0 } }
end
puts c.n
IYI
route trusted '@[Share] on `Counter` is a claim the compiler takes on trust' 'Make its fields Share'

cat > reach.iyi <<'IYI'
@[UnsafeReach("set once")]
SEEN = [] of Int32
SEEN << 1
puts SEEN.size
IYI
route reach '@[UnsafeReach] on `SEEN` is the claim the compiler takes on trust'

cat > socket.iyi <<'IYI'
import std/socket::{IyiSocket}

def send(s : IyiSocket, text : String) : Nil
  s.write(text.to_unsafe, text.bytesize)
end
puts 1
IYI
route socket '`text.to_unsafe` answers `Pointer(UInt8)`'

# ── 2. The safe spellings ────────────────────────────────────────────────
step "bytes read without raw memory, and the literals the compiler expands, need no mark"
cat > safe_api.iyi <<'IYI'
import std/slice::{Bytes, Slice}
t = "hello"
puts t.byte_at(1)
puts t.byte_at(-1)
b = Bytes.of(t)
puts b[4]
puts String.new(b)
puts String.new([104_u8, 105_u8, 33_u8], 0, 2)
STDOUT.write(Bytes.of("ok\n"))
IYI
accepted safe_api --error-on-warnings
cat > literals.iyi <<'IYI'
a = [1, 2, 3]
h = {"a" => 1}
puts "#{a.size} #{h.size} #{[a, [4]].flatten.size}"
IYI
accepted literals --error-on-warnings
# A def over a trait nothing implements yet is typed where it is written
# through a witness whose requirements the compiler wrote with
# `uninitialized` bodies; the module was refused for them. Its broken copy
# writes the same `uninitialized` in the person's own def.
cat > witness.iyi <<'IYI'
trait Shape
  abstract def area : Int32
end

def area_of(x : Shape) : Int32
  x.area + 1
end

puts 1
IYI
accepted witness --error-on-warnings
awk '{ if ($0 == "  x.area + 1") { print "  y = uninitialized Int32"; print "  x.area + y" } else print }' witness.iyi > witness_broken.iyi
refused witness_broken '`uninitialized Int32` is a value nothing has written'

# ── 3. The mark itself ───────────────────────────────────────────────────
step "a mark says why, and a mark nothing needs is warned of"
printf '@[Unsafe]\nputs 1\n' > noreason.iyi
refused noreason "a module's @[Unsafe] says why the module handles raw memory, as one string"
printf '@[Unsafe(call: "x")]\nclass Foo\nend\nputs 1\n' > contract_type.iyi
refused contract_type 'is the promise a def'"'"'s caller keeps, and `Foo` is a type'
printf '@[Unsafe("reads nothing raw")]\nputs 1\n' > unneeded.iyi
if ! "$IYI" check unneeded.iyi > unneeded.log 2>&1 || ! grep -qF '`unneeded.iyi` is marked @[Unsafe] and does nothing unsafe' unneeded.log; then
  echo "the unneeded mark was not warned of:"; cat unneeded.log; exit 1
fi
echo "  warned:   unneeded.iyi: $(grep -m1 'does nothing unsafe' unneeded.log | cut -c1-120)..."
if "$IYI" check --error-on-warnings unneeded.iyi > unneeded_strict.log 2>&1; then
  echo "the unneeded mark passed --error-on-warnings:"; cat unneeded_strict.log; exit 1
fi
echo "  refused:  unneeded.iyi under --error-on-warnings"
# Its broken copy: the same mark on a module that needs it, which no warning names.
accepted h1b_marked --error-on-warnings
# A module whose unsafe code is another target's, behind a macro
# conditional, is not told to drop the mark this target's compile did not
# see used (std/system_roots on Linux was); unneeded.iyi is its broken copy.
cat > other_target.iyi <<'IYI'
@[Unsafe("asks the platform's C library on a target this is not")]
{% if flag?(:iyi_no_such_target) %}
  x = uninitialized Int32
{% end %}
puts 1
IYI
accepted other_target --error-on-warnings

# ── 4. iyi fix writes the mark ───────────────────────────────────────────
step "iyi fix inserts the mark with the reason the compiler saw"
cp h1b.iyi fixed.iyi
if ! "$IYI" fix fixed.iyi > fix.log 2>&1; then
  echo "iyi fix failed:"; cat fix.log; exit 1
fi
if ! head -1 fixed.iyi | grep -qF "@[Unsafe(\"reads a String's memory through \`to_unsafe\`, line 3\")]"; then
  echo "iyi fix did not write the mark above the first statement:"; head -3 fixed.iyi; cat fix.log; exit 1
fi
echo "  fixed:    $(head -1 fixed.iyi)"
accepted fixed

# ── 5. The artifact carries the mark ─────────────────────────────────────
step "a marked module's .iyimod keeps the mark for its importers"
mkdir -p art/raw && cd art || exit 1
cat > raw/cell.iyi <<'IYI'
@[Unsafe("a cell keeps its value in memory it allocates itself")]
module raw/cell

pub class Cell(T)
  @slot : Pointer(T)

  def initialize(value : T)
    @slot = Pointer(T).malloc(1_u64)
    @slot.value = value
  end

  def get : T
    @slot.value
  end
end
IYI
cat > main.iyi <<'IYI'
module main

import raw/cell::{Cell}

puts Cell(Int32).new(41).get + 1
puts Cell(String).new("travelled").get
IYI
export IYI_PATH="$REPO/src${PSEP}$WORK/art"
if ! "$IYI" build --emit-iyimod mods -o out main.iyi > emit.log 2>&1; then
  echo "the marked producer does not build:"; cat emit.log; exit 1
fi
if ! "$IYI" mod dump mods/raw/cell.iyimod | grep -qF 'unsafe        a cell keeps its value in memory it allocates itself'; then
  echo "mod dump does not print the mark:"; "$IYI" mod dump mods/raw/cell.iyimod | sed -n '1,12p'; exit 1
fi
echo "  dumped:   $("$IYI" mod dump mods/raw/cell.iyimod | grep '^unsafe')"
mv raw/cell.iyi cell.iyi.kept
if ! "$IYI" build --use-iyimod mods -o out2 main.iyi > use.log 2>&1; then
  echo "the unmarked importer does not build against the marked artifact:"; cat use.log; exit 1
fi
said="$(./out2 2>&1 | tr -d '\r' | tr '\n' ' ')"
if [ "$said" != "42 travelled " ]; then
  echo "the importer built against the artifact printed \"$said\""; exit 1
fi
echo "  built:    main.iyi against mods/raw/cell.iyimod, source gone: $said"
# Its broken copy: the producer without its mark.
grep -v '^@\[Unsafe' cell.iyi.kept > raw/cell.iyi
if "$IYI" build --emit-iyimod mods_plain -o out3 main.iyi > plain.log 2>&1; then
  echo "the unmarked producer built:"; cat plain.log; exit 1
fi
if ! tr '\\' '/' < plain.log | grep -qF '`raw/cell` is not marked unsafe'; then
  echo "the unmarked producer was refused, but not naming it:"; cat plain.log; exit 1
fi
echo "  refused:  raw/cell unmarked: $(grep -m1 '^Error: ' plain.log | cut -c8-120)..."
unset IYI_PATH
cd "$WORK" || exit 1

# ── 6. The fault names the module ────────────────────────────────────────
step "a memory fault names the program's own unsafe modules"
cat > fault.iyi <<'IYI'
@[Unsafe("reads an address nothing allocated, on purpose")]
puts Pointer(Int64).new(16_u64).value
IYI
"$IYI" run fault.iyi > fault.log 2>&1
code=$?
if [ "$code" -eq 0 ] || ! grep -qF "this program's own are fault.iyi" fault.log; then
  echo "the fault (exit $code) did not name fault.iyi:"; cat fault.log; exit 1
fi
echo "  died:     exit $code, $(grep -m1 -o "this program's own are fault.iyi[^;.]*" fault.log)"

# ── 7. Crystal is unaffected ─────────────────────────────────────────────
step "a .cr program reads through a Pointer under --crystal"
cat > raw.cr <<'CR'
bytes = "crystal".to_unsafe
puts bytes[0].chr
CR
if ! "$IYI" build --crystal raw.cr -o raw_cr > raw_cr.log 2>&1; then
  echo "the .cr program does not build under --crystal:"; cat raw_cr.log; exit 1
fi
said="$(./raw_cr 2>&1 | tr -d '\r')"
if [ "$said" != "c" ]; then
  echo "the .cr program printed \"$said\""; exit 1
fi
echo "  built:    raw.cr under --crystal, printed $said"

echo "unsafe code was refused outside a module marked @[Unsafe], and accepted in one"
