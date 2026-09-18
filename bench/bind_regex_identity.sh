#!/usr/bin/env bash
# Binds two Crystal shards, each holding a regex literal of its own, and checks
# that a program built against both boundaries prints what the same program
# prints built against their source.
#
# A regex literal does not stay a literal. The compiler turns it into a
# program-level constant, the unit that reads it refers to that constant by
# name, and the name reaches a linker — so the name is part of the boundary
# whether or not anybody wrote it. It used to be assigned by the order the
# literals were met in, which is not an identity two programs share: both of
# the shards below numbered their own from zero and both said `$Regex:0`.
#
# `bench/bind_roundtrip.sh` cannot ask this. One boundary can be wrong about
# the name and still be right about the pattern, because there is nothing for
# it to collide with. It takes two, and the failure it caught is the one worth
# a gate of its own:
#
#     --- source ---            --- artifact ---
#     alpha-[0-9]+              alpha-[0-9]+
#     beta-[a-z]+               alpha-[0-9]+
#
# Nothing raised, nothing failed to link, and the second shard matched against
# the first one's pattern. That is III.6 rule 1's "returns something of another
# type" one level down, and a linker cannot see it.
#
#     bash bench/bind_regex_identity.sh
#
# Needs `make` (both the compiler and `iyi`). Exits non-zero if either bind
# fails, if either arm fails to build or link, or if the two print differently.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# the wrappers in bin are posix shell scripts, so a caller that already has
# compilers of its own names them through the environment.
CRYSTAL="${CRYSTAL:-$REPO/bin/crystal}"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and the sources
# written into a scratch directory named `/tmp/tmp.X` are named by a path it
# cannot read.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# Each shard matches as well as naming its pattern, and the match is the half
# that took longest to make true. Reading the constant says which one the unit
# got; running it says the whole path works, and that path was three separate
# holes deep. `Regex::PCRE2::@@current_jit_stack` is thread-local, so it is
# reached through a `noinline` function in the main module — which does not
# travel. `Regex::MatchOptions` is an enum, and ids are handed out by walking
# `Object`'s subclasses, which does not reach one: a consumer whose own code
# never mentions it numbers it nowhere. Both are fixed, and this line is what
# keeps them fixed.
#
# The explicit `initialize` is not decoration either: `new` is synthesised from
# it rather than read from the artifact, and a class without one leaves the
# consumer asking for a constructor symbol nobody emitted.
for mod in alpha beta; do
  case "$mod" in
    alpha) root=Alpha; pattern='alpha-[0-9]+' ;;
    beta)  root=Beta;  pattern='beta-[a-z]+' ;;
  esac

  cat > "$WORK/$mod.cr" <<CR
module $root
  class Part
    @seed : Int32

    def initialize(@seed : Int32)
    end

    def pattern : String
      /$pattern/.source
    end

    def matches(s : String) : Bool
      !!(s =~ /$pattern/)
    end
  end
end
CR
  printf 'require "./%s"\n' "$mod" > "$WORK/${mod}_entry.cr"
done

cat > "$WORK/app_source.iyi" <<'IYI'
module main

require "./alpha"
require "./beta"

puts Alpha::Part.new(1).pattern
puts Beta::Part.new(2).pattern
puts Alpha::Part.new(1).matches("alpha-42")
puts Alpha::Part.new(1).matches("beta-xy")
puts Beta::Part.new(2).matches("beta-xy")
puts Beta::Part.new(2).matches("alpha-42")
IYI

sed -e 's|require "./alpha"|import alpha|' -e 's|require "./beta"|import beta|' \
  "$WORK/app_source.iyi" > "$WORK/app_artifact.iyi"

cd "$WORK" || exit 1
mkdir mods
status=0

for mod in alpha beta; do
  case "$mod" in
    alpha) root=Alpha ;;
    beta)  root=Beta ;;
  esac

  if ! "$CRYSTAL" tool bind -e "$root" --emit-bind mods "${mod}_entry.cr" \
        > "bind-$mod.log" 2>&1; then
    echo "binding $mod failed"
    tail -12 "bind-$mod.log"
    echo "workdir $WORK"
    exit 1
  fi

  if ! (cd mods && "$CRYSTAL" build --iyi-keep "$root" --emit-bind . \
          -o "keep_$mod" "${mod}_keep.cr" > "fill-$mod.log" 2>&1); then
    echo "filling $mod failed"
    tail -12 "mods/fill-$mod.log"
    echo "workdir $WORK"
    exit 1
  fi
done

# Printed because it is the evidence: two boundaries, two names. Identical
# names here are the bug, and they are visible before anything is built.
echo "the names the two boundaries carry:"
for mod in alpha beta; do
  "$IYI" mod dump "mods/$mod.iyimod" | sed -n 's/^  \(\$Regex:[^ ]*\) = \(.*\)$/  '"$mod"': \1 = \2/p'
done

for arm in source artifact; do
  build_cmd=("$IYI" build --crystal)
  if [ "$arm" = artifact ]; then
    build_cmd+=(--use-iyimod mods)
  fi
  build_cmd+=(-o "out_$arm" "app_$arm.iyi")

  if ! "${build_cmd[@]}" > "build-$arm.log" 2>&1; then
    echo "$arm: build failed"
    tail -12 "build-$arm.log"
    status=1
    continue
  fi
  "./out_$arm" > "out-$arm.txt" 2>&1
done

if [ -f out-source.txt ] && [ -f out-artifact.txt ]; then
  if diff -q out-source.txt out-artifact.txt > /dev/null; then
    echo "each boundary kept its own literal, and matched with it"
    sed 's/^/  /' out-artifact.txt
  else
    echo "OUTPUT DIFFERS"
    diff out-source.txt out-artifact.txt | head -10
    status=1
  fi
fi

echo "workdir $WORK"
exit $status
