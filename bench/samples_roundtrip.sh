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

echo "workdir $WORK"
exit $status
