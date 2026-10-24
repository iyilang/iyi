#!/usr/bin/env bash
# Binds pieces of Crystal's own library as boundaries and consumes each.
#
# `bench/yaml_reads.sh` does this for one namespace and holds one claim about
# it. This asks the same question of several, because what a boundary breaks on
# depends on what the namespace *holds*: `JSON` is types and methods, `URI` is
# a struct with a lot of parsing behind it, and `Log` is global state written
# by macros — a private constant, a class variable with a live initialiser, and
# two `{% for %}` loops that write a method of the same name on both sides of
# the class.
#
# `Log` is the one that found things, and it found four. `tool bind` died on it
# with a stack overflow and no diagnosis. A parameter written `Class` is every
# metaclass there is and there is no end to them. A class variable the library
# declares was declared a second time here, so the initialiser that runs was
# not the one the artifact carried. And `MonoBodies` was keyed without the side
# of the type, so `Log.info`'s body took `Log#info`'s key.
#
# `Path` and `Time` arrived later and found one thing between them: a constant
# has two spellings, and which one a build picks is a fact about that build's
# order rather than about the constant. See the comment above them.
#
# The six after them found nothing, and that is worth having too: a gate that
# only holds the cases that once broke says nothing about the ones that never
# did, and "never did" is a claim that stops being true the moment somebody
# changes how a boundary is written.
#
#     bash bench/library_boundaries.sh
#
# Needs `make`. Nothing here reaches the network: what it binds is in this
# checkout.
#
# Exits non-zero if any bind or fill fails, or if any consumer answers
# differently from the same program built from source.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# Both compilers are whichever ones the caller names; `bin/crystal` and
# `bin/iyi` are shell wrappers, and on Windows the caller has to point at
# the built exes themselves.
CRYSTAL="${CRYSTAL:-$REPO/bin/crystal}"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` on it is silently ignored, so the boundary
# is built against nothing.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
cd "$WORK" || exit 1

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

export CRYSTAL_PATH="$REPO/src"
export IYI_PATH="$REPO/share/iyi/src${PSEP}$REPO/share/iyi/crystal${PSEP}$REPO/src"

status=0

# root | require | module name | program
check() {
  root="$1"; req="$2"; mod="$3"; program="$4"
  dir="$WORK/$mod"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    printf 'require "%s"\n' "$req" > probe.cr

    if ! "$CRYSTAL" tool bind -e "$root" --emit-bind mods probe.cr > bind.log 2>&1; then
      echo "$root: binding failed"
      tail -8 bind.log
      exit 1
    fi

    if ! (cd mods && "$CRYSTAL" build --iyi-keep "$root" --emit-bind . \
            -o keep "${mod}_keep.cr" > fill.log 2>&1); then
      echo "$root: filling failed"
      tail -8 mods/fill.log
      exit 1
    fi

    printf 'module main\n\nrequire "%s"\n\n%s\n' "$req" "$program" > a_src.iyi
    printf 'module main\n\nimport %s\n\n%s\n' "$mod" "$program" > a_art.iyi

    if ! "$IYI" run --crystal a_src.iyi > out_src.txt 2>&1; then
      echo "$root: the source arm failed"
      tail -8 out_src.txt
      exit 1
    fi

    if ! "$IYI" run --crystal --use-iyimod mods a_art.iyi > out_art.txt 2>&1; then
      echo "$root: the artifact arm failed"
      tail -8 out_art.txt
      exit 1
    fi

    if ! diff -q out_src.txt out_art.txt > /dev/null; then
      echo "$root: THE TWO ARMS ANSWER DIFFERENTLY"
      diff out_src.txt out_art.txt | head -8
      exit 1
    fi

    echo "  $root — $(tr '\n' ' ' < out_art.txt)"
  ) || status=1
}

echo "bound from the library, and consumed:"

check JSON json j_s_o_n 'v = JSON.parse(%q({"a":[1,2,3],"b":"x"}))
puts v["b"]
puts v["a"].as_a.size'

check URI uri u_r_i 'u = URI.parse("https://iyi.example/a/b?q=1#frag")
puts u.host
puts u.path
puts u.query'

# The formatter is written out so the line carries no clock: a gate that
# compares two runs cannot compare timestamps taken seconds apart. The
# dispatcher is synchronous for the same kind of reason — the default hands the
# write to a fiber, and a gate that read the buffer first would compare two
# empty strings and call it a match.
#
# The `debug` line is the half that says the *level* crossed: it must not
# appear, and a boundary that lost `Log::Severity`'s numbering would let it.
check Log log log 'io = IO::Memory.new
backend = Log::IOBackend.new(io, dispatcher: Log::DispatchMode::Sync)
backend.formatter = Log::Formatter.new { |entry, dest| dest << entry.severity.to_s << " " << entry.source << " " << entry.message }
Log.setup(:info, backend)
Log.for("x").info { "hello" }
Log.for("x").debug { "not this one" }
puts io.to_s.strip'

# Two the boundary could not carry until it learned that a constant has two
# spellings. `Path` reads `Iterator::Stop::INSTANCE` from its `PartIterator`
# unit and `Time` reads `Time::Span::ZERO`; both are reached through
# `~NAME:const_read`, a function the producer emitted because *its* units read
# them before initialising them, and which the consumer had no reason to write
# — it initialises them from its own program, in its own order, and emits a
# plain global. `undefined symbol`, in a program whose own source names no
# iterator.
#
# `Time` is also the case that says an enum and a struct with arithmetic on it
# cross: `day_of_week` is an enum read back by name, and `total_hours` is a
# `Time::Span` divided out. The clock is never asked — every value here is
# written down — because a gate that compares two runs cannot compare two
# readings of `Time.utc`.
check Path path path 'p = Path.posix("/a/b/c.txt")
puts p.basename
puts p.extension
puts p.parent
puts (p / "d").to_s'

check Time time time 't = Time.utc(2026, 8, 26, 13, 5, 0)
puts t.to_s("%Y-%m-%d %H:%M:%S")
puts (t + 3.days).day
puts (t - Time.utc(2026, 8, 20)).total_hours
puts t.day_of_week'

# Six more, each cheap and each asking a different small question: `Base64` is
# module functions over `IO`, `UUID` is a struct wrapping a `StaticArray` and
# an enum read back by name, `INI` returns a hash of hashes, `CSV` is a parser
# and a builder that takes a block, `Colorize` is macro-written methods on
# `Object` — a type the *library* owns.
#
# `XML` used to be the twelfth, chosen because it calls libxml2 and so its
# boundary has to carry a `@[Link]` flag the consumer never wrote. libxml2 is
# an ancestor dependency and the module is gone, so that property is proven
# by `bench/yaml_reads.sh` instead, which binds `YAML` the same way and for
# the same reason. Eleven here, and the link-flag question still asked.
check Base64 base64 base64 'e = Base64.strict_encode("iyi, encoded")
puts e
puts String.new(Base64.decode(e))'

check UUID uuid u_u_i_d 'u = UUID.new("c0ffee00-dead-beef-cafe-000000000001")
puts u.to_s
puts u.variant
puts UUID.new(StaticArray(UInt8, 16).new(0_u8)).to_s'

check INI ini i_n_i 'h = INI.parse("[a]\nx = 1\ny = 2\n")
puts h["a"]["x"]
puts h["a"].size'

check CSV csv c_s_v 'rows = CSV.parse("a,b\n1,2\n")
puts rows.size
puts rows[1][1]
puts CSV.build { |b| b.row "x", "y" }.strip'

check Colorize colorize colorize 'puts "x".colorize(:red).to_s.inspect
puts Colorize.enabled?'

# And the one that took a change to the format. `Random` is a *mixin* module
# with `abstract def next_u` for its includers to answer, and iyi's own module
# header is `extend self` — read under one, the module went into its own
# metaclass and the metaclass answered nothing: `abstract def Random#next_u()
# must be implemented by Random:Module`, on a program whose only line was
# `import random`. Plain Crystal refuses `extend self` beside an `abstract def`
# for the same reason. A boundary now carries whether the module wrote
# `extend self` rather than the header assuming it.
check Random random random 'r = Random.new(42)
puts r.rand(100)
puts r.next_bool.class'

if [ "$status" -eq 0 ]; then
  echo "every boundary answers what its source does"
fi

echo "workdir $WORK"
exit $status
