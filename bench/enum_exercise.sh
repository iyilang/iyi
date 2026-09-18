#!/usr/bin/env bash
# The prelude's `Enum` surface: every method, and the compiler's three uses.
#
#     bash bench/enum_exercise.sh
#
# `bench/enum_exercise.iyi` is the program. It runs plain and optimised, and
# then each check is proved capable of failing by patching a *copy of the
# prelude* — `src/iyi/enum.iyi` with one method broken — and building against
# it through `IYI_PATH`. A check that cannot fail is not a check.
#
# What is being protected is not only the methods. The compiler gives an enum
# `value` and `new` and nothing else, and three things it writes depend on this
# file: a `when` naming a member lowers to `===`, which is `==`; a per-member
# question method (`level.warn?`) is `self == Member`; and a `@[Flags]` enum's
# is `self.includes?(Member)`. Before the surface existed, all three answered
# `Object`'s defaults — `==` was `false`, so `case` matched nothing.
#
# Exits non-zero if any check fails or if any patch leaves the exercise green.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs whatever compiler the caller names; `bin/iyi` is a shell
# wrapper, and on Windows the caller has to point at the built exe itself.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` on it is silently ignored, so the patched
# copy is never read and the proof that a check can fail quietly stops
# proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

status=0

run_case() { # run_case <label> <name> [build flags...]
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/enum_exercise.iyi" \
       > "$WORK/$name.build" 2>&1; then
    echo "  $label: the exercise did not build"
    sed -n '1,12p' "$WORK/$name.build"
    status=1
    return
  fi
  if ! "$WORK/$name" > "$WORK/$name.out" 2>&1; then
    echo "  $label: the exercise panicked"
    tail -3 "$WORK/$name.out"
    status=1
    return
  fi
  if ! grep -q "all enum checks passed" "$WORK/$name.out"; then
    echo "  $label: the exercise ended without passing"
    tail -3 "$WORK/$name.out"
    status=1
    return
  fi
  echo "  $label: every check held"
}

echo "== the surface, plain"
run_case "plain" plain

echo
echo "== and with optimisation on (--release)"
run_case "release" release --release

echo
echo "== the sample a program reads, which is what asked for the surface"
if "$IYI" run "$REPO/samples/iyi/enums.iyi" > "$WORK/sample.out" 2>&1; then
  # Two lines out of it, because the whole point is that a member prints as
  # its name and a flags enum prints as the bits it holds.
  if grep -q "^level: Warn$" "$WORK/sample.out" &&
     grep -q "^mode: Read | Write$" "$WORK/sample.out"; then
    echo "  samples/iyi/enums.iyi: a member is its name, and a flag set is its bits"
  else
    echo "  samples/iyi/enums.iyi: ran, but not printing the names"
    sed -n '1,6p' "$WORK/sample.out"
    status=1
  fi
else
  echo "  samples/iyi/enums.iyi: did not run"
  tail -3 "$WORK/sample.out"
  status=1
fi

echo
echo "== an exported enum across a module boundary, which is iyi's own thesis"

# Two modules and two builds of the consumer: one against the exporter's
# source, one against its `.iyimod`. The answers have to be the same string,
# because the enum a consumer reads is a *declaration* — its members and the
# numbers they were given — and the surface is stencilled onto it by the
# consumer's own prelude.
#
# Three defects were in the way, each invisible until an enum was exported:
# the question methods the compiler writes carried no return type and R-2
# refused them ("`debug?` is exported and does not say what it returns"); the
# artifact writer asked an enum for its instance variables (`BUG: Level::Level
# doesn't implement instance_vars`); and an enum's members read as code inside
# a type body, so the module could not be imported from an artifact at all.
mkdir -p "$WORK/boundary/mods"
cat > "$WORK/boundary/level.iyi" <<'IYI'
module level

pub enum Level : Int32
  Debug = 0
  Warn  = 2
end

@[Flags]
pub enum Mode
  Read
  Write
end

pub def loudest : Level
  Level::Warn
end
IYI
cat > "$WORK/boundary/main.iyi" <<'IYI'
module main

import level
using level::{Level, Mode, loudest}

l = loudest
puts "name: #{l}"
puts "same: #{l == Level::Warn}"
puts "warn? #{l.warn?}"
puts(case l
     in Level::Debug then "quiet"
     in Level::Warn  then "loud"
     end)
puts "members: #{Level.values.size}"
puts "parsed: #{Level.parse?("debug").to_s}"
puts "bits: #{(Mode::Read | Mode::Write).to_s}"
IYI

(
  cd "$WORK/boundary" || exit 1
  "$IYI" run main.iyi > source.out 2>&1
) || {
  echo "  the source arm did not run"
  tail -3 "$WORK/boundary/source.out"
  status=1
}

if (
  cd "$WORK/boundary" || exit 1
  "$IYI" build --emit-iyimod mods -o exporter main.iyi > emit.log 2>&1 &&
    "$IYI" build --use-iyimod mods -o consumer main.iyi > use.log 2>&1 &&
    ./consumer > artifact.out 2>&1
); then
  if diff -u "$WORK/boundary/source.out" "$WORK/boundary/artifact.out" > "$WORK/boundary/diff"; then
    echo "  the two arms answer the same thing:"
    sed 's/^/    /' "$WORK/boundary/source.out"
  else
    echo "  the artifact arm answers differently"
    sed -n '1,12p' "$WORK/boundary/diff"
    status=1
  fi
else
  echo "  the artifact arm did not build or run"
  tail -4 "$WORK/boundary/emit.log" "$WORK/boundary/use.log" 2>/dev/null
  status=1
fi

echo
echo "== proving the checks can fail, one broken method at a time"

# A copy of the whole prelude with one method patched, on `IYI_PATH` ahead of
# the tree's own. `--prelude` resolves `iyi/prelude` the way an import does, so
# the copy is what the build reads.
prove_fails() { # prove_fails <label> <dir> <phrase> <sed script>
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  sed -e "$script" "$REPO/src/iyi/enum.iyi" > "$WORK/$dir/iyi/enum.iyi"
  if cmp -s "$REPO/src/iyi/enum.iyi" "$WORK/$dir/iyi/enum.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi

  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/enum_exercise.iyi" \
       > "$WORK/$dir/build" 2>&1; then
    # A patch that stops the build is a failure the exercise cannot report,
    # and it is still the check firing: say which way it went.
    if grep -q "$phrase" "$WORK/$dir/build"; then
      printf '  %s: refused at compile time\n' "$label"
    else
      echo "  $label: the patched prelude did not build, and not for this check"
      sed -n '1,10p' "$WORK/$dir/build"
      status=1
    fi
    return
  fi

  "$WORK/$dir/program" > "$WORK/$dir/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at the expected check ('$phrase')"
    tail -2 "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" \
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

# 1. Equality inverted: `==` is what `case`, `!=`, `===` and every question
#    method the compiler writes are built on.
prove_fails "== inverted" no_eq "enum: == same member" \
  's/^    value == other.value$/    value != other.value/'

# 2. The order reversed, which a threshold reads.
prove_fails "> reversed" no_gt "enum: >" \
  's/^    value > other.value$/    value < other.value/'

# 3. `to_s` answering the digits instead of the name.
prove_fails "to_s without names" no_to_s "enum: to_s first member" \
  's/^        return {{ member.stringify }} if value == {{ @type.constant(member) }}$//'

# 4. `hash` collapsed to one number. A `Hash` of members still answers
#    correctly — it compares the keys it finds — so what this breaks is the
#    distribution, and the check that sees it is the one asking two members to
#    hash apart.
prove_fails "hash collapsed" no_hash "enum: members hash apart" \
  's/^    value.to_i32$/    0/'

# 5. `includes?` asking equality instead of membership, which is what a flags
#    enum's question methods go through.
prove_fails "includes? as equality" no_includes "flags: includes? held" \
  's/^    value & other.value == other.value$/    value == other.value/'

# 6. `values` including the flags members the compiler synthesized.
prove_fails "values keeps None" no_values "flags: values skips None and All" \
  's/@type.annotation(Flags) && (member.stringify == "None"/@type.annotation(Flags) \&\& (member.stringify == "Nothing"/'

# 7. `parse?` no longer folding case, which is the half a person's input
#    needs. It is the *exact* check that fires first, because one comparison
#    answers both and the member's side is folded too.
prove_fails "parse? stops folding case" no_parse "enum: parse? exact" \
  's/wanted = name.downcase/wanted = name/'

# 8. `from_value?` answering a member for every integer.
prove_fails "from_value? never nil" no_from_value "enum: from_value? no member" \
  's/^    nil$/    self.new(0)/'

echo
if [ "$status" -eq 0 ]; then
  echo "an enum is its name, its order, its value and its members"
else
  echo "the enum surface does not hold"
fi
exit "$status"
