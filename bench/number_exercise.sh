#!/usr/bin/env bash
# The prelude's numbers at their edges: printed and read back, what does not
# fit, the two divisions that leave the type, and the float values that are
# their own question - NaN, the two zeros, and a conversion that cannot fit.
#
#     bash bench/number_exercise.sh
#
# `bench/number_exercise.iyi` is the program, run plain and optimised. Then
# the two panics are driven here - a program that panics has no next line to
# assert on - and then each check is proved capable of failing by patching a
# *copy of the prelude* and building against it through `IYI_PATH`. A check
# that cannot fail is not a check.
#
# What is being protected: `Int32::MIN` has no positive twin, so a parser
# that accumulates the magnitude and negates it cannot read what `to_s`
# wrote, and with checked arithmetic it panicked rather than answering the
# `nil` a `?` promises. And `MIN // -1` is the one division whose result the
# type does not hold: left to the processor it traps, and the program dies of
# "a floating-point system exception" for an integer divide - the same
# sentence the zero divisor used to give before it was checked here.
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
# The arm that asks for a signal cannot ask for one everywhere, and a run
# that skipped it must not read as a run that made the measurement.
guard_unmeasured=0

run_case() { # run_case <label> <name> [build flags...]
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/number_exercise.iyi" \
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
  if ! grep -q "all number checks passed" "$WORK/$name.out"; then
    echo "  $label: the exercise ended without passing"
    tail -3 "$WORK/$name.out"
    status=1
    return
  fi
  echo "  $label: every check held"
}

echo "== the edges, plain"
run_case "plain" plain

echo
echo "== and with optimisation on (--release)"
run_case "release" release --release

echo
echo "== the divisions that leave the type, which are panics"

panics_with() { # panics_with <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nputs (%s).to_s\n' "$expression" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of panicking"
    status=1
    return
  fi
  # 136 is SIGFPE: the processor's own report, which is the failure this
  # check exists to keep out. A panic is exit 1 with a sentence.
  if [ "$code" -ne 1 ]; then
    echo "  $label: died with exit $code rather than a panic"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$name.out"; then
    echo "  $label: panicked, but not with '$phrase'"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits 1 at "%s"\n' "$label" \
    "$(grep -m1 -o "$phrase.*" "$WORK/$name.out")"
}

panics_with "min over minus one" min_div "arithmetic overflow" "-2147483648 // -1"
panics_with "int64 min over minus one" min_div64 "arithmetic overflow" "-9223372036854775808_i64 // -1_i64"
panics_with "division by zero" zero_div "division by zero" "7 // 0"
panics_with "modulo by zero" zero_mod "modulo by zero" "7 % 0"

# And the float that does not fit an integer, which the compiler checks
# rather than this file: unchecked it would hand back whatever the hardware's
# conversion left behind. The last one is the boundary - 2147483647.9
# truncates to a value that fits, and this compiler and the other language
# both refuse it - measured against both rather than assumed.
panics_with "a float too large for an int" big_float "arithmetic overflow" "1e20.to_i"
panics_with "not a number as an int" nan_int "arithmetic overflow" "(0.0/0.0).to_i"
panics_with "infinity as an int" inf_int "arithmetic overflow" "(1.0/0.0).to_i"
panics_with "the boundary float" edge_float "arithmetic overflow" "2147483647.9.to_i"

# And the same value through the unchecked form, which is the pair of every
# panic above: the instruction without the check. It is spelled
# `unsafe_to_i32` because `!` is not part of a name in iyi (III.1.7), and
# until an expansion was parsed in the language of the file it expands in,
# nothing written in iyi source could name it at all — `x.to_i!` reads as
# `x.to_i` with its error propagated, which the compiler refuses.
answers_with() { # answers_with <label> <name> <expected> <expression>
  local label="$1" name="$2" expected="$3" expression="$4"
  printf 'module main\n\nputs (%s).to_s\n' "$expression" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  if ! "$WORK/$name" > "$WORK/$name.out" 2>&1; then
    echo "  $label: panicked where the unchecked form has nothing to check"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  if [ "$(cat "$WORK/$name.out")" != "$expected" ]; then
    echo "  $label: answered $(cat "$WORK/$name.out") rather than $expected"
    status=1
    return
  fi
  printf '  %s: answers %s\n' "$label" "$expected"
}

answers_with "an int too large for a byte, unchecked" big_byte_unchecked 44 "300.unsafe_to_u8"
answers_with "a negative as a byte, unchecked" neg_byte_unchecked 255 "(-1).unsafe_to_u8"
answers_with "a handle of -1, unchecked" handle_unchecked 18446744073709551615 "(-1_i64).unsafe_to_u64"

echo
echo "== proving the checks can fail, one broken method at a time"

# A copy of the whole prelude with one method patched, on `IYI_PATH` ahead of
# the real one. The patch has to change the file - a sed that matched nothing
# would otherwise read as a pass - and the exercise then has to exit non-zero
# at the check that names the method.
prove_fails() { # prove_fails <label> <dir> <file> <phrase> <sed script>
  local label="$1" dir="$2" file="$3" phrase="$4" script="$5"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  sed -e "$script" "$REPO/src/iyi/$file" > "$WORK/$dir/iyi/$file"
  if cmp -s "$REPO/src/iyi/$file" "$WORK/$dir/iyi/$file"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi

  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/number_exercise.iyi" \
       > "$WORK/$dir/build" 2>&1; then
    echo "  $label: the patched prelude did not build"
    sed -n '1,10p' "$WORK/$dir/build"
    status=1
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
    echo "  $label: failed, but not at the expected check (wanted '$phrase')"
    tail -2 "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" \
    "$(grep -m1 -o "$phrase.*" "$WORK/$dir/out" | sed 's/^assert failed: //')"
}

# 1. The parser accumulating a positive magnitude again, which is what could
#    not read `Int32::MIN`.
prove_fails "parser accumulates positively" pos_parse string.iyi \
  "arithmetic overflow" \
  's/^      value = value \* 10 - digit$/      value = value * 10 + digit/'

# 2. The range guard removed, so a string that does not fit reaches the
#    checked arithmetic and panics where a `nil` was promised. That panic is
#    the old behaviour, and it is what this proof reads.
prove_fails "range guard removed" no_guard string.iyi \
  "arithmetic overflow" \
  's/^      return nil if value < -214748364 || (value == -214748364 \&\& digit > 8)$/      # unguarded/'

# 3. The magnitude that only exists as a negative handed back as a positive,
#    so `"2147483648"` answers a number instead of nil.
prove_fails "min accepted as a positive" min_pos string.iyi \
  "number: max plus one is nil" \
  's/^    return nil if value == -2147483648$/    return 0 if value == -2147483648/'

# 4. Truncation turned into a floor, so `//` and `%` stop agreeing. Anchored
#    on the Int32 overflow guard, which is the one line only `Int32#//` has.
prove_fails "division floors instead" floor_div number.iyi \
  "number: division truncates toward zero" \
  's/^    raise "arithmetic overflow" if self == -2147483648 \&\& other == -1$/    return unsafe_div(other) - 1 if self < 0/'

# 5. And the remainder beside it, anchored the same way on `Int32#%`.
prove_fails "remainder takes the divisor sign" mod_sign number.iyi \
  "number: remainder takes the dividend" \
  's/^    return 0 if self == -2147483648 \&\& other == -1$/    return 0 - unsafe_mod(other)/'

# 6. `to_s` in a base, the other direction of the round trip: the letters
#    written from the wrong offset.
prove_fails "base printing broken" bad_base number.iyi \
  "number: hex" \
  's/^        buffer\[at\] = d < 10 ? (48 + d).to_u8 : (87 + d).to_u8$/        buffer[at] = d < 10 ? (48 + d).to_u8 : (55 + d).to_u8/'

# 7. The rounding a column of numbers reads, in the file it lives in.
prove_fails "floor rounds the wrong way" bad_floor float.iyi \
  "number: floor goes down" \
  's/^    truncated > self ? truncated - 1.0 : truncated$/    truncated/'

# 8. And the rounding that has to be symmetric about zero.
prove_fails "round is not symmetric" bad_round float.iyi \
  "number: round is symmetric" \
  's/^    self < 0.0 ? nearest \* -1.0 : nearest$/    nearest/'

# 8b. A tie decided away from zero, which is the other library's meaning
#     of the same name.
prove_fails "a tie rounds away" away_round float.iyi \
  "number: a tie rounds to the even integer" \
  's/^                (whole \/ 2.0).floor \* 2.0 == whole ? whole : whole + 1.0$/                whole + 1.0/'

# 8c. The nearest found by a sum, which rounds before the floor sees it.
prove_fails "round adds a half" sum_round float.iyi \
  "number: round reads the fraction, not a sum" \
  's/^    fraction = magnitude - whole$/    fraction = (magnitude + 0.5).floor > whole ? 0.75 : 0.25/'

# 8d. A place count under one read as zero.
prove_fails "negative places ignored" places_round float.iyi \
  "number: round to tens and hundreds" \
  's/^    return round if digits == 0$/    return round if digits <= 0/'

# 9. And the unchecked conversions made checked, which is what the prelude
#    had before `unsafe_to_u8` was a name: the instruction is the point, so
#    a checked one panics where the exercise asserted a value. Anchored on
#    the eight-space annotation inside the conversion loop, which is the one
#    `unsafe_chr` (six spaces, in the integer loop) does not share.
prove_fails "the unchecked conversion checked" checked_unsafe primitives.iyi \
  "arithmetic overflow" \
  's/^        @\[::Primitive(:unchecked_convert)\]$/        @[::Primitive(:convert)]/'

echo
echo "== and the check that keeps the processor out of it"

# The overflowing division with its guard removed does not fail a check - it
# dies of SIGFPE, which is the whole reason the guard is there. So this one
# asks for the signal rather than for a phrase.
prove_traps() { # prove_traps <label> <dir> <sed script>
  local label="$1" dir="$2" script="$3"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  sed -e "$script" "$REPO/src/iyi/number.iyi" > "$WORK/$dir/iyi/number.iyi"
  if cmp -s "$REPO/src/iyi/number.iyi" "$WORK/$dir/iyi/number.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  printf 'module main\n\nputs (-2147483648 %% -1).to_s\n' > "$WORK/$dir/program.iyi"
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$WORK/$dir/program.iyi" > "$WORK/$dir/build" 2>&1; then
    echo "  $label: the patched prelude did not build"
    sed -n '1,10p' "$WORK/$dir/build"
    status=1
    return
  fi
  "$WORK/$dir/program" > "$WORK/$dir/out" 2>&1
  local code=$?
  if [ "$code" -lt 128 ]; then
    echo "  $label: exited $code rather than dying of a signal, so the guard proves nothing"
    status=1
    return
  fi
  printf '  %s: dies of signal %s without the guard\n' "$label" "$((code - 128))"
}

# Windows delivers no signal: without the guard the program still dies, but
# it dies with an exit code and nothing names a processor fault, so this arm
# is not measured here rather than weakened into accepting one.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    echo "  remainder without its guard: not measured here, because Windows delivers no signal for a processor fault"
    guard_unmeasured=1
    ;;
  *)
    prove_traps "remainder without its guard" no_mod_guard \
      's/^    return 0 if self == -2147483648 \&\& other == -1$/    # unchecked/'
    ;;
esac

echo
if [ "$status" -eq 0 ]; then
  echo "Numbers: every value prints and reads back, what does not fit says so,"
  echo "the two divisions that leave the type are panics with sentences rather"
  echo "than a fault from the processor, and the floats keep the three answers"
  echo "a program reads without thinking - NaN is not itself, -0.0 is zero, and"
  echo "everything rounds toward the same side it always did."
  if [ "$guard_unmeasured" -eq 1 ]; then
    echo "What this run did not measure is what the remainder's guard prevents:"
    echo "that needs a signal, and this platform delivers none."
  fi
else
  echo "the number surface does not hold"
fi
exit "$status"
