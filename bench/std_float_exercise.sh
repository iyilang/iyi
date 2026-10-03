#!/usr/bin/env bash
# Exercises `std/float`: Float32 arithmetic and constants, the conversions
# to the integers, the exact comparison against them, and `%` and `//`.
#
#     bash bench/std_float_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# the patches and oracles below are written in python, and windows answers
# `python3` with a store stub that prints and exits rather than running it, so
# the interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

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
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_float_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
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

echo "== the std/float exercise, plain build"
build_and_run "plain" float-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/float-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every float section reported"
for phrase in "== arithmetic" "== constants" "== narrowing" "== conversions to integers" "== comparison with integers" "== modulo and floored division" "== traits" "== signed zeros and the smallest exponent"; do
  if ! grep -q "$phrase" "$WORK/float-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" float-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/float-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what the conversions and the division refuse"
# A panicking program has no next line to assert on, so each refusal is
# its own program. The conversion truncates first: what is refused is a
# truncation the integer does not hold, NaN, and the infinities.
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/float\nimport std/int\n\nputs (%s).to_s\n' "$expression" > "$WORK/$name.iyi"
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
  printf '  %s: exits 1 at "%s"\n' "$label" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}
refuses "256.0_f32 to_u8" f32_u8_256 "arithmetic overflow" '256.0_f32.to_u8'
refuses "-1.0_f32 to_u8" f32_u8_neg "arithmetic overflow" '(-1.0_f32).to_u8'
refuses "128.0_f32 to_i8" f32_i8_128 "arithmetic overflow" '128.0_f32.to_i8'
refuses "-129.0_f32 to_i8" f32_i8_neg "arithmetic overflow" '(-129.0_f32).to_i8'
refuses "2^31 to_i32" f32_i32_2g "arithmetic overflow" '2147483648.0_f32.to_i32'
refuses "2^63 to_i64" f32_i64_2e "arithmetic overflow" '9223372036854775808.0_f32.to_i64'
refuses "2^128 to_u128" f32_u128 "arithmetic overflow" '340282366920938463463374607431768211456.0_f32.to_u128'
refuses "NaN to_i32" f32_nan "arithmetic overflow" '(0.0_f32 / 0.0_f32).to_i32'
refuses "Infinity to_u64" f32_inf "arithmetic overflow" '(1.0_f32 / 0.0_f32).to_u64'
refuses "-Infinity to_i128" f32_ninf "arithmetic overflow" '(-1.0_f32 / 0.0_f32).to_i128'
refuses "a double // zero" f64_div0 "division by zero" '1.0 // 0.0'
refuses "a single // zero" f32_div0 "division by zero" '1.0_f32 // 0.0_f32'

echo
echo "== what a program without the import is told"
# The error names the import: `-x` on a Float64 was "wrong number of
# arguments for 'Float64#-' (given 0, expected 1)" and nothing more, and
# `1.5_f32.to_f64` was sent to `iyi build --crystal`.
told() { # told <label> <name> <phrase> <program>
  local label="$1" name="$2" phrase="$3" program="$4"
  printf '%s\n' "$program" > "$WORK/$name.iyi"
  if "$IYI" check "$WORK/$name.iyi" > "$WORK/$name.check" 2>&1; then
    echo "  $label: it type-checked without the import"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.check"; then
    echo "  $label: refused, but not naming the import:"
    sed -n '1,12p' "$WORK/$name.check"
    status=1
    return
  fi
  printf '  %s: "%s"\n' "$label" "$phrase"
}
told "-x on a Float64" told_neg '`-` with no arguments on Float64 is in `std/float`' $'x = 1.5\nputs -x'
told "to_f64 on a Float32" told_to_f64 '`to_f64` on Float32 is in `std/float`' $'x = 1.5_f32\nputs x.to_f64'

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/float.iyi").read_text()
old = 'MAX          =  3.40282347e+38_f32'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/float.iyi").write_text(src.replace(old, 'MAX          =  1.0_f32', 1))
PY
then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_float_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken float is caught"
fi

# Each repair to the signed zeros and to `** Int32::MIN`, undone in a copy
# that still builds: the exercise has to stop at that repair's own check.
# The message proves the broken copy compiled and ran up to it; a copy
# that did not build fails too, and would prove nothing.
breaks() { # breaks <label> <name> <file under src/> <old> <new> <check>
  local label="$1" name="$2" file="$3" old="$4" new="$5" check="$6"
  if [ -z "$PY" ]; then
    echo "  $label: no python3 on this machine, unmeasured"
    return
  fi
  mkdir -p "$WORK/$name/$(dirname "$file")"
  # A prelude file is found beside `prelude.iyi`, so the whole prelude is
  # copied for one of its files to be replaced.
  case "$file" in
    iyi/*) cp -r "$REPO/src/iyi" "$WORK/$name/" ;;
  esac
  if ! SRC="$REPO/src/$file" DST="$WORK/$name/$file" OLD="$old" NEW="$new" "$PY" - <<'PY'
import os
from pathlib import Path
src = Path(os.environ["SRC"]).read_text()
old = os.environ["OLD"]
if old not in src:
    raise SystemExit("patch site missing")
Path(os.environ["DST"]).write_text(src.replace(old, os.environ["NEW"], 1))
PY
  then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi
  IYI_PATH="$WORK/$name${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_float_exercise.iyi" >"$WORK/$name.out" 2>&1
  if grep -q "ALL CHECKS PASSED" "$WORK/$name.out"; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF -- "ASSERTION FAILED: $check" "$WORK/$name.out"; then
    echo "  $label: it failed, but not at '$check'"
    sed -n '1,5p' "$WORK/$name.out"
    status=1
  else
    echo "  $label: caught at \"$check\""
  fi
}
breaks "trunc through an integer again" trunc std/float.iyi \
  'whole == 0.0{{ sfx.id }} ? self * 0.0{{ sfx.id }} : whole' 'whole' \
  '(-0.5).trunc is -0.0'
breaks "remainder of a zero by the sign test" remainder std/float.iyi \
  'return self if self == 0.0{{ sfx.id }}' '# return self if self == 0.0{{ sfx.id }}' \
  '(-0.0).remainder(2.0) is -0.0'
breaks "the prelude's round without its zero" round iyi/float.iyi \
  'return self if self == 0.0' '# return self if self == 0.0' \
  '(-0.0).round is -0.0'
breaks "round(mode) without its zero" round_mode std/number.iyi \
  'return self if self == 0.0' '# return self if self == 0.0' \
  '(-0.0).round(TiesAway) is -0.0'
breaks "** Int32::MIN without the square" pow_min iyi/float.iyi \
  'return 1.0 / (half * half)' 'return 1.0 / half' \
  '1.0000001 ** Int32::MIN'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/float exercise holds"
else
  echo "the std/float exercise did not hold"
fi
exit $status
