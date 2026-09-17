#!/usr/bin/env bash
# Exercises `std/enum`: the rest of `Enum`, added to the prelude's.
#
#     bash bench/std_enum_exercise.sh
#
# Proves:
#   * bench/std_enum_exercise.iyi passes plain and --release: conversions,
#     arithmetic and order, from_value/parse, the flags treatment of
#     valid?/each, and the io spellings (the io line is read off stdout).
#   * `from_value` and `parse` refuse with a sentence naming the value or
#     the text; `~` is not a verb an enum has.
#   * Negative proofs: copies of the module whose `each` yields None and
#     All, whose `valid?` accepts everything, and whose `+` steps the wrong
#     way each fail at the named check.
#
# Exits non-zero if any check fails.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

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

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2" source="$3"
  shift 3
  if ! "$IYI" build "$@" -o "$WORK/$name" "$source" >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/enum exercise, plain build"
build_and_run "std_enum" exercise-enum "$REPO/bench/std_enum_exercise.iyi"

echo
echo "== every enum check reported"
for check in "conversions" "arithmetic and order" "from_value and parse" "flags: valid? and each agree with the prelude" "io spellings" "io: Warn|None|Read | Append|9" "ALL CHECKS PASSED"; do
  if ! grep -qF -- "$check" "$WORK/exercise-enum.out" 2>/dev/null; then
    echo "  MISSING: $check"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  conversions, arithmetic, from_value/parse, flags and the io line all reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "std_enum --release" exercise-enum-release "$REPO/bench/std_enum_exercise.iyi" --release >/dev/null
if grep -q "ALL CHECKS PASSED" "$WORK/exercise-enum-release.out" 2>/dev/null; then
  echo "  every check holds under --release"
else
  echo "  release: missing pass sentinel"
  status=1
fi

# ---------------------------------------------------------------------------
# What from_value and parse refuse
# ---------------------------------------------------------------------------

echo
echo "== what from_value and parse refuse"
enum_panics_with() { # enum_panics_with <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/enum\n\nenum Level\n  Debug\n  Info\n  Warn\nend\n\n@[Flags]\nenum Mode\n  Read\n  Write\nend\n\nputs (%s).to_s\n' "$expression" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of panicking: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: panicked, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}
enum_panics_with "a value no member has" fv9 "Level member has the value 9" 'Level.from_value(9)'
enum_panics_with "a flags combination, by value" fv3 "Mode member has the value 3" 'Mode.from_value(3)'
enum_panics_with "a name no member has" pnone "Level member is named \"fatal\"" 'Level.parse("fatal")'

echo
echo "== an enum has no ~"
printf 'module main\n\nimport std/enum\n\n@[Flags]\nenum Mode\n  Read\n  Write\nend\n\nputs (~Mode::Read).to_s\n' > "$WORK/tilde.iyi"
if "$IYI" build -o "$WORK/tilde" "$WORK/tilde.iyi" >"$WORK/tilde.log" 2>&1; then
  echo "  ~Mode::Read BUILT (the module should not offer it)"
  status=1
elif grep -q "undefined method '~'" "$WORK/tilde.log"; then
  echo "  ~Mode::Read is refused at compile time: $(grep -m1 "undefined method '~'" "$WORK/tilde.log" | sed 's/^Error: //')"
else
  echo "  ~Mode::Read failed to build, but not as an undefined method:"
  tail -4 "$WORK/tilde.log" | sed 's/^/    /'
  status=1
fi

# ---------------------------------------------------------------------------
# Negative failure proofs
# ---------------------------------------------------------------------------

echo
echo "== proving the checks can fail when the module is broken"
prove_fails() { # prove_fails <label> <dir> <phrase> <sed script>
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$script" "$REPO/src/std/enum.iyi" > "$WORK/$dir/std/enum.iyi"
  if cmp -s "$REPO/src/std/enum.iyi" "$WORK/$dir/std/enum.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -o "$WORK/$dir/program" "$REPO/bench/std_enum_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched module did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at the expected check ('$phrase')"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

prove_fails "each yields None and All" each_all "flags each walks the members, not None or All" \
  's/    values.each { |member| yield member }/    {% for member in @type.constants %}\n      yield new({{@type.constant(member)}})\n    {% end %}/'
prove_fails "valid? accepts everything" valid_all "plain: a member is valid, 9 is not" \
  's/    !from_value?(val.value.to_i32).nil?/    true/'
prove_fails "+ steps backwards" plus_back "Info + 1 is Warn" \
  's/    self.class.new(value + other)/    self.class.new(value - other)/'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/enum exercise holds"
else
  echo "the std/enum exercise did not hold"
fi
exit $status
