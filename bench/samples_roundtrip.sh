#!/usr/bin/env bash
# Builds each iyi sample twice and checks it prints the same thing both times:
# once from source, once from the imported modules' `.iyimod` artifacts with
# every one of those modules' source **deleted**.
#
# That deletion is the whole test. R-1 says a consumer compiles against a
# module's declarations and never its source, and the only way to be sure of it
# is to take the source away and see whether the build still produces a program
# that behaves. `spec/compiler/iyimod_spec.cr` checks the same property on small
# programs written for it; this checks it on the samples, which were written to
# document the language rather than to pass this.
#
#     bash bench/samples_roundtrip.sh
#
# Needs `make` (which builds both the compiler and `iyi`). It runs `iyi` rather
# than `crystal` because these are iyi programs and that is the binary a person
# has. Exits non-zero if any sample fails to build either way, or prints
# something different from its artifacts.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from `pwd` is `/c/...` and finds no prelude at all, and a
# scratch directory named `/tmp/tmp.X` is silently ignored on that path, so
# the patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# Every sample that imports a module. A sample that imports nothing has no
# boundary to cross, which is why `hello`, `generics` and `errors` are not
# here; the rest are, and six of them were missing. `calc` was the one that
# mattered — an `impl` method written `: Int32 | UnknownName |
# DividedByZero` over a body that answers `Int32`, so the producer emitted
# the narrow symbol and the consumer asked for the union. `derive` is here
# for the reason R-5 exists: the macro that generated its methods is in
# `std/derives`, and that source is deleted below, so the artifact has to
# carry what the derive produced.
SAMPLES="modules immutable collections init_order webapp derive calc format socket std_iterator std_text std_time"

cp -r "$REPO/samples/iyi/." "$WORK/"
cd "$WORK" || exit 1

status=0

for sample in $SAMPLES; do
  if ! "$IYI" build --emit-iyimod mods -o "from-source-$sample" "$sample.iyi" >"emit-$sample.log" 2>&1; then
    echo "$sample: writing artifacts failed"
    tail -5 "emit-$sample.log"
    status=1
    continue
  fi
  "./from-source-$sample" >"out-source-$sample.txt" 2>&1
done

# Every module's source, gone — so a build that reads one has nothing to fall
# back to.
rm -rf app std boot kemal

for sample in $SAMPLES; do
  [ -f "from-source-$sample" ] || continue
  if ! "$IYI" build --use-iyimod mods -o "from-artifact-$sample" "$sample.iyi" >"use-$sample.log" 2>&1; then
    echo "$sample: building from artifacts failed"
    tail -12 "use-$sample.log"
    status=1
    continue
  fi
  "./from-artifact-$sample" >"out-artifact-$sample.txt" 2>&1
  if diff -q "out-source-$sample.txt" "out-artifact-$sample.txt" >/dev/null; then
    echo "$sample: identical output"
  else
    echo "$sample: OUTPUT DIFFERS"
    diff "out-source-$sample.txt" "out-artifact-$sample.txt" | head -10
    status=1
  fi
done

# `calc` on what Windows pipes, and on input with an error. cmd's `echo`
# ends the line in CRLF and the lexer had no case for `\r`: `echo 2 + 3 *
# 4| iyi run samples\iyi\calc.iyi` answered "error: unexpected character at
# 9". And every error went to standard output at exit 0, so a script could
# not tell. The from-source build of it is the one run.
if [ -f from-source-calc ]; then
  crlf="$(printf 'x = 2 + 3 * 4\r\nx * 10\r\n' | ./from-source-calc 2>&1 | tr -d '\r')"
  printf '1 / 0\n' | ./from-source-calc > calc-err.out 2> calc-err.err
  err_code=$?
  if [ "$crlf" = "140" ] && [ "$err_code" -eq 1 ] && [ ! -s calc-err.out ] &&
     [ "$(tr -d '\r' < calc-err.err)" = "error: divided by zero" ]; then
    echo "calc: CRLF input answers 140; 1 / 0 is said on standard error, exit 1"
  else
    echo "calc: CRLF input answered '$crlf'; 1 / 0 exited $err_code with '$(cat calc-err.out)' on standard output"
    status=1
  fi
fi

# Symbols, numbered by the program that links. A symbol is its index in the
# program's table, and each build numbers its symbols in the order it meets
# them: the producer below meets `:apple` and `:carrot` first, the consumer
# meets four others before them. A unit that baked the producer's numbers in
# compared the consumer's `:apple` against the producer's number for it, so
# `webapp` above counted no before-filter once the prelude met one symbol
# more. The module decides by `case`, autocasts a symbol to an enum member,
# prints one, and answers `:carrot`, a symbol the consumer never writes - so
# only the artifact can tell the consumer it exists.
SYM="$WORK/symbols"
mkdir -p "$SYM/tags"
cat > "$SYM/tags/kind.iyi" <<'IYI'
module tags/kind

pub enum Colour
  Red
  Green
end

pub def kind_of(tag : Symbol) : String
  case tag
  when :apple  then "fruit"
  when :carrot then "vegetable"
  else              "unknown"
  end
end

pub def favourite : Symbol
  :carrot
end

pub def colour_name(colour : Colour) : String
  colour == Colour::Green ? "green" : "red"
end

pub def green_by_symbol : String
  colour_name(:green)
end

pub def tag_text(tag : Symbol) : String
  tag.to_s
end
IYI
cat > "$SYM/producer.iyi" <<'IYI'
module producer

import tags/kind::*

puts kind_of(:apple)
puts favourite
puts tag_text(:apple)
puts green_by_symbol
IYI
cat > "$SYM/consumer.iyi" <<'IYI'
module consumer

import tags/kind::*

others = [:zebra, :yak, :walrus, :vole]
puts others.size
puts kind_of(:apple)
puts kind_of(:zebra)
puts kind_of(favourite)
puts favourite.to_s
puts favourite == favourite
puts tag_text(:vole)
puts green_by_symbol
IYI
printf '4\nfruit\nunknown\nvegetable\ncarrot\ntrue\nvole\ngreen\n' > "$SYM/expected.txt"
if ! (cd "$SYM" && "$IYI" build --emit-iyimod mods -o producer producer.iyi) > "$SYM/emit.log" 2>&1; then
  echo "symbols: writing artifacts failed"
  tail -5 "$SYM/emit.log"
  status=1
else
  rm -rf "$SYM/tags"
  if ! (cd "$SYM" && "$IYI" build --use-iyimod mods -o consumer consumer.iyi) > "$SYM/use.log" 2>&1; then
    echo "symbols: building the consumer from artifacts failed"
    tail -12 "$SYM/use.log"
    status=1
  elif ! "$SYM/consumer" > "$SYM/consumer.txt" 2>&1 || ! cmp -s "$SYM/expected.txt" "$SYM/consumer.txt"; then
    echo "symbols: the consumer, numbering its own, read the module's symbols wrong"
    diff "$SYM/expected.txt" "$SYM/consumer.txt" | head -12
    status=1
  else
    echo "symbols: numbered by the consumer, read right by the module's units"
  fi
fi

# What a module's object code reaches in the program that links it, built
# both ways and with `--release` both ways - the samples above never write
# a release artifact. A struct changed through a getter and through `self`
# changes the original: inlined from source, the call answers the field
# itself, and an artifact's body-less header was a call that answered a
# copy, so `h.counter.bump` left the counter at 1 in the build writing the
# artifact and in the one reading it. Checked `+`, a class, a `defer` and a
# `group`, whose code refers by name to what the consumer defines: its
# runtime `fun`s, type ids, `:headed` bytes and class variables, which a
# `--release` consumer made private and the linker could not find
# (`__iyi_raise_overflow`), and on Windows the `void*` type descriptor a
# catch pad names, which a consumer with no `defer` or `raise` of its own
# never defined (`??_R0PEAX@8`).
REACH="$WORK/reach"
mkdir -p "$REACH/shelf"
cat > "$REACH/shelf/box.iyi" <<'IYI'
module shelf/box

pub struct Counter
  property n : Int32

  def initialize(@n : Int32)
  end

  def me : self
    self
  end

  def bump : Nil
    @n += 1
  end
end

pub class Holder
  property counter : Counter

  def initialize(@counter : Counter)
  end
end

pub def add1(x : Int32) : Int32
  x + 1
end

pub def with_defer(log : Array(String)) : Int32
  defer log << "defer"
  log << "body"
  7
end

pub def twice_in_task(n : Int32) : Int32
  out = 0
  group do |g|
    t = g.spawn { n * 2 }
    v = t.value
    out = v.is_a?(Int32) ? v : -1
  end
  out
end
IYI
cat > "$REACH/main.iyi" <<'IYI'
module main

import shelf/box::*

h = Holder.new(Counter.new(1))
h.counter.bump
puts "through a getter: #{h.counter.n}"
c = Counter.new(1)
c.me.bump
puts "through self: #{c.n}"
puts add1(41)
log = [] of String
puts "#{with_defer(log)} #{log.join(",")}"
puts twice_in_task(21)
IYI
printf 'through a getter: 2\nthrough self: 2\n42\n7 body,defer\n42\n' > "$REACH/expected.txt"
reach() { # reach <label> <name> [build flags...]
  local label="$1" name="$2"
  shift 2
  if ! (cd "$REACH" && "$IYI" build "$@" -o "$name" main.iyi) > "$REACH/$name.log" 2>&1; then
    echo "reach: $label failed to build"
    grep -m3 -E "error|Error" "$REACH/$name.log"
    status=1
  elif ! "$REACH/$name" > "$REACH/$name.txt" 2>&1 || ! cmp -s "$REACH/expected.txt" "$REACH/$name.txt"; then
    echo "reach: $label answered differently from the source"
    diff "$REACH/expected.txt" "$REACH/$name.txt" | head -8
    status=1
  else
    echo "reach: $label answers as the source does"
  fi
}
reach "writing the artifact" emit --emit-iyimod mods
reach "writing it --release" emit-release --release --emit-iyimod modsr
rm -rf "$REACH/shelf"
reach "reading the artifact" use --use-iyimod mods
reach "reading it --release" use-release --release --use-iyimod modsr

# Shapes of module whose artifact read back as something other than its
# source, each built from source while writing the artifact and then from the
# artifact alone. Each was measured failing on the build that read it:
# `impl_block` linked no further than `Kit::Lib::B#walk<&Proc(Int32, Nil)>`
# and Enumerable's `map` said "can't use yield inside a proc literal";
# `abstract_generic` came back as `pub abstract generic class GA(T)`;
# `empty_body` ended on `G(Int32)@G(T)#noop:Nil`; `field_default` was refused
# for "code inside a type body that has to run"; `hooks` said `undefined
# method 'kind' for Main::Mine`; `macro_def` put `class ::Main::User` in
# the library's artifact - `superclass mismatch for class Main::User`; and
# `annotated`, whose bodies `macro_def` made travel, read `@type` on a
# declaration that arrived without its annotations: `price` answered 0 for
# the library's own `@[Priced(3)] class Basket`, and the module-private
# `Zone` was `undefined constant Zone`.
TRAVEL="$WORK/travel"
travel() { # travel <case> <expected output>, with $TRAVEL/<case>/{kit/lib.iyi,main.iyi}
  local name="$1" dir="$TRAVEL/$1"
  printf '%s\n' "$2" > "$dir/expected.txt"
  if ! (cd "$dir" && "$IYI" build --emit-iyimod mods -o emit main.iyi) > "$dir/emit.log" 2>&1; then
    echo "travel: $name failed to build from source"
    grep -m3 -E "error|Error" "$dir/emit.log"
    status=1
    return
  fi
  rm -rf "$dir/kit"
  if ! (cd "$dir" && "$IYI" build --use-iyimod mods -o use main.iyi) > "$dir/use.log" 2>&1; then
    echo "travel: $name failed to build from its artifact"
    grep -m3 -E "error|Error" "$dir/use.log"
    status=1
  elif ! "$dir/emit" > "$dir/emit.txt" 2>&1 || ! cmp -s "$dir/expected.txt" "$dir/emit.txt" ||
    ! "$dir/use" > "$dir/use.txt" 2>&1 || ! cmp -s "$dir/expected.txt" "$dir/use.txt"; then
    echo "travel: $name answered differently from the source"
    diff "$dir/expected.txt" "$dir/use.txt" | head -8
    status=1
  else
    echo "travel: $name answers from its artifact as from source"
  fi
}
mkdir -p "$TRAVEL"/{impl_block,abstract_generic,empty_body,field_default,hooks,macro_def,annotated,unreached}/kit
cat > "$TRAVEL/impl_block/kit/lib.iyi" <<'IYI'
module kit/lib

import std/enumerable::{Enumerable}

pub trait Walk
  abstract def walk(& : Int32 -> Nil) : Nil
end

pub struct B
  def initialize(@n : Int32)
  end
end

impl Walk for B
  def walk(& : Int32 -> Nil) : Nil
    yield 3
    yield 4
  end
end

impl Enumerable for B
  type Elem = Int32

  def each(& : Int32 -> Nil) : Nil
    i = 0
    while i < @n
      yield i
      i += 1
    end
  end
end
IYI
cat > "$TRAVEL/impl_block/main.iyi" <<'IYI'
module main

import kit/lib::*
import std/enumerable

B.new(0).walk { |x| puts x }
puts B.new(3).map { |x| x * 2 }
IYI
travel impl_block "$(printf '3\n4\n[0, 2, 4]')"
cat > "$TRAVEL/abstract_generic/kit/lib.iyi" <<'IYI'
module kit/lib

pub abstract class GA(T)
  abstract def get : T
end

pub class GC(T) < GA(T)
  def initialize(@v : T)
  end

  def get : T
    @v
  end
end
IYI
cat > "$TRAVEL/abstract_generic/main.iyi" <<'IYI'
module main

import kit/lib::*

puts GC.new(3).get
IYI
travel abstract_generic 3
cat > "$TRAVEL/empty_body/kit/lib.iyi" <<'IYI'
module kit/lib

pub class G(T)
  def initialize(@v : T)
  end

  def noop : Nil
  end

  def get : T
    @v
  end
end

pub struct S(T)
  def one : Int32
    1
  end
end

pub def each_none(& : Int32 -> Nil) : Nil
end
IYI
cat > "$TRAVEL/empty_body/main.iyi" <<'IYI'
module main

import kit/lib::*

g = G.new(5)
g.noop
each_none { |x| puts x }
puts "#{g.get} #{S(String).new.one}"
IYI
travel empty_body "5 1"
cat > "$TRAVEL/field_default/kit/lib.iyi" <<'IYI'
module kit/lib

pub class A
  @id = 7
  @items = [] of String

  def describe : String
    "#{@id} #{@items.size}"
  end
end
IYI
cat > "$TRAVEL/field_default/main.iyi" <<'IYI'
module main

import kit/lib::*

puts A.new.describe
IYI
travel field_default "7 0"
cat > "$TRAVEL/hooks/kit/lib.iyi" <<'IYI'
module kit/lib

pub abstract class P
  @@names = [] of String

  macro inherited
    P.add({{@type.name.stringify}})

    def kind : String
      {{@type.name.stringify}}
    end
  end

  def self.add(name : String) : Nil
    @@names << name
  end

  def self.names : Array(String)
    @@names
  end
end

pub class One < P
end
IYI
cat > "$TRAVEL/hooks/main.iyi" <<'IYI'
module main

import kit/lib::*

class Mine < P
end

puts "#{One.new.kind} #{Mine.new.kind} #{P.names}"
IYI
travel hooks 'Kit::Lib::One Main::Mine ["Kit::Lib::One", "Main::Mine"]'
cat > "$TRAVEL/macro_def/kit/lib.iyi" <<'IYI'
module kit/lib

pub class Model
  def type_name : String
    {{ @type.name.stringify }}
  end
end
IYI
cat > "$TRAVEL/macro_def/main.iyi" <<'IYI'
module main

import kit/lib::*

class User < Model
end

puts "#{User.new.type_name} #{Model.new.type_name}"
IYI
travel macro_def "Main::User Kit::Lib::Model"
# `Basket` sorts above `Priced`, so the annotation is only declared before
# the type it is written over if the reader orders it there.
cat > "$TRAVEL/annotated/kit/lib.iyi" <<'IYI'
module kit/lib

pub annotation Priced
end

annotation Zone
end

@[Priced(3)]
@[Zone]
pub class Basket
  def price : Int32
    {{ (found = @type.annotation(Priced)) ? found[0] : 0 }}
  end

  def zoned? : Bool
    {{ @type.annotation(Zone) ? true : false }}
  end
end
IYI
cat > "$TRAVEL/annotated/main.iyi" <<'IYI'
module main

import kit/lib::*

class Bag < Basket
end

@[Priced(5)]
class Box < Basket
end

puts "#{Basket.new.price} #{Bag.new.price} #{Box.new.price} #{Basket.new.zoned?} #{Bag.new.zoned?}"
IYI
travel annotated "3 0 5 true false"

# And a method the build writing the artifact never called, which the
# artifact declares and has no machine code for (SPEC.md IV.1g). It is
# refused naming the module; it was a link error naming a mangled symbol,
# `.2A.Kit.3A..3A.Lib.40.Kit.3A..3A.Lib.3A..3A.fb_public.3C.Int32.3E.`.
cat > "$TRAVEL/unreached/kit/lib.iyi" <<'IYI'
module kit/lib

pub def fb_public(x : Int32) : Int32
  x * 7
end
IYI
printf 'module producer\n\nimport kit/lib\n' > "$TRAVEL/unreached/producer.iyi"
printf 'module main\n\nimport kit/lib::*\n\nputs fb_public(3)\n' > "$TRAVEL/unreached/main.iyi"
if ! (cd "$TRAVEL/unreached" && "$IYI" build --emit-iyimod mods -o producer producer.iyi) > "$TRAVEL/unreached/emit.log" 2>&1; then
  echo "travel: unreached failed to write its artifact"
  status=1
else
  rm -rf "$TRAVEL/unreached/kit"
  (cd "$TRAVEL/unreached" && "$IYI" build --use-iyimod mods -o use main.iyi) > "$TRAVEL/unreached/use.log" 2>&1
  if grep -q "kit/lib's artifact declares .Kit::Lib.fb_public" "$TRAVEL/unreached/use.log" &&
    grep -q "never reached it" "$TRAVEL/unreached/use.log"; then
    echo "travel: a method the artifact's build never reached is refused naming the module"
  else
    echo "travel: a method the artifact's build never reached was not refused by name"
    grep -m3 -E "error|Error" "$TRAVEL/unreached/use.log"
    status=1
  fi
fi

# And a `forall` def, which is the caller's to compile like a block-taking
# one (SPEC.md IV.1g), with its bounds the caller's to check (II.6 §3,
# II.7 rule 3). The artifact is written by a program that calls `wrap` at
# its own `Meters`, and read by one that calls everything at types the
# producer never used. The forall bodies stayed behind and their
# instantiations went into the library's object code: the consumer was
# refused at the import because `kit/lib` "numbers
# `Kit::Lib::Box(Producer::Meters)`, and this build cannot name it", and
# without that call `wrap("s")` was "has no symbol for it". The signatures
# carried `forall T` and no `where` at all, so `render(2.5)` and a `shown`
# over `Float64`, both refused from source, built from the artifact.
mkdir -p "$TRAVEL/forall/kit"
cat > "$TRAVEL/forall/kit/lib.iyi" <<'IYI'
module kit/lib

pub trait Show
  abstract def show : String
end

impl Show for Int32
  def show : String
    "i#{self}"
  end
end

pub trait Bag
  type Elem
  abstract def items : Array(Elem)

  def shown : String where Elem : Show
    items.map { |x| x.show }.join(",")
  end
end

pub struct Box(T)
  getter value : T

  def initialize(@value : T)
  end
end

pub struct Two(T)
  def initialize(@a : T, @b : T)
  end
end

impl Bag for Two(T) forall T
  type Elem = T

  def items : Array(T)
    [@a, @b]
  end
end

pub def wrap(x : T) : Box(T) forall T
  Box.new(x)
end

pub def render(x : T) : String forall T : Show
  x.show
end

pub struct Conv
  def initialize
  end

  def pair(x : T) : Array(T) forall T
    [x, x]
  end

  def self.one(x : T) : Array(T) forall T
    [x]
  end
end
IYI
cat > "$TRAVEL/forall/producer.iyi" <<'IYI'
module producer

import kit/lib::*

pub struct Meters
  def initialize
  end
end

puts wrap(Meters.new).value.class
puts render(1)
puts Conv.new.pair(1).size
puts Two.new(1, 2).shown
IYI
cat > "$TRAVEL/forall/main.iyi" <<'IYI'
module main

import kit/lib::*

puts wrap("s").value
puts Conv.new.pair("s").size
puts Conv.one('c').size
puts render(7)
puts Two.new(3, 4).shown
IYI
printf 'module main\n\nimport kit/lib::*\n\nputs render(2.5)\n' > "$TRAVEL/forall/free.iyi"
printf 'module main\n\nimport kit/lib::*\n\nputs Two.new(1.5, 2.5).shown\n' > "$TRAVEL/forall/where.iyi"
printf 's\n2\n1\ni7\ni3,i4\n' > "$TRAVEL/forall/expected.txt"
if ! (cd "$TRAVEL/forall" && "$IYI" build --emit-iyimod mods -o producer producer.iyi) > "$TRAVEL/forall/emit.log" 2>&1; then
  echo "travel: forall failed to write its artifact"
  grep -m3 -E "error|Error" "$TRAVEL/forall/emit.log"
  status=1
else
  rm -rf "$TRAVEL/forall/kit"
  if ! (cd "$TRAVEL/forall" && "$IYI" build --use-iyimod mods -o use main.iyi) > "$TRAVEL/forall/use.log" 2>&1; then
    echo "travel: forall defs at the consumer's types failed to build from another program's artifact"
    grep -m3 -E "error|Error" "$TRAVEL/forall/use.log"
    status=1
  elif ! "$TRAVEL/forall/use" > "$TRAVEL/forall/use.txt" 2>&1 || ! cmp -s "$TRAVEL/forall/expected.txt" "$TRAVEL/forall/use.txt"; then
    echo "travel: forall defs answered differently from the source"
    diff "$TRAVEL/forall/expected.txt" "$TRAVEL/forall/use.txt" | head -8
    status=1
  else
    echo "travel: forall defs compile at the consumer's types from another program's artifact"
  fi
  for bound in free where; do
    (cd "$TRAVEL/forall" && "$IYI" build --use-iyimod mods -o "$bound" "$bound.iyi") > "$TRAVEL/forall/$bound.log" 2>&1
    if grep -q "Float64 does not implement Kit::Lib::Show, required by" "$TRAVEL/forall/$bound.log"; then
      echo "travel: a $bound bound read from the artifact is checked as from source"
    else
      echo "travel: a $bound bound read from the artifact was not checked"
      grep -m3 -E "error|Error" "$TRAVEL/forall/$bound.log"
      status=1
    fi
  done
fi

echo "workdir $WORK"
exit $status
