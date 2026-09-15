#!/usr/bin/env bash
# Exercises `std/math`: sqrt, sin/cos, frexp/ldexp, the logarithms, pow,
# the inverse trigonometric and hyperbolic functions, gamma, erf, and the
# Float32 overloads, against Python's values.
#
#     bash bench/std_math_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src:$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_math_exercise.iyi" \
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

echo "== the std/math exercise, plain build"
build_and_run "plain" math-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/math-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every math section reported"
for phrase in "== sqrt" "== sincos" "== frexp and ldexp" "== log, log2, log10" "== exp, exp2, expm1, log1p" "== pow" "== atan, atan2, asin, acos" "== the hyperbolic functions and hypot, cbrt" "== gamma, lgamma" "== erf, erfc" "== fma, min, max, gcd" "== the Float32 overloads"; do
  if ! grep -q "$phrase" "$WORK/math-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" math-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/math-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mutate() { # mutate <label> <old> <new>
  local label="$1" old="$2" new="$3"
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  OLD="$old" NEW="$new" python3 - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/math.iyi").read_text()
old = os.environ["OLD"]
if old not in src:
    raise SystemExit("patch site missing: " + old)
Path("$WORK/patched/std/math.iyi").write_text(src.replace(old, os.environ["NEW"], 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_math_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  else
    echo "  $label: caught"
  fi
}
mutate "no huge-arg guard in sin/cos" 'return {0.0, 1.0} if q_f.abs >= 9223372036854775808.0' '# no huge-arg guard'
mutate "a subnormal left unscaled by frexp" 'bits = IyiFloatText.bits_of(value * TWO_54)' 'bits = IyiFloatText.bits_of(value)'
mutate "the third part of pi/2 as it was" 'P3 = 2.02226624879595063154e-21' 'P3 = 6.12323399573676588613e-17'
mutate "log10 without its whole-number check" 'ten_to(n.to_i32) == value ? n : res' 'res'
mutate "exp cut off one argument early" 'return 1.0 / 0.0 if value > 709.782712893384' 'return 1.0 / 0.0 if value >= 709.782712893384'
mutate "atan2 blind to the sign of zero" 'return x_neg ? copysign(PI, y) : y' 'return y'
mutate "erfc as 1 - erf everywhere" 'return 1.0 - erf(value) if value < 1.0' 'return 1.0 - erf(value)'
mutate "gamma with a pole answered" 'return 0.0 / 0.0 if value <= 0.0 && value == value.floor' '# poles answered'
mutate "gcd on the positive side" 'x = a > 0 ? -a : a' 'x = a.abs'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/math exercise holds"
else
  echo "the std/math exercise did not hold"
fi
exit $status
