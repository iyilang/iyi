#!/usr/bin/env bash
# Exercises `std/math`: sqrt, sin/cos, frexp/ldexp, the logarithms, pow,
# the inverse trigonometric and hyperbolic functions, gamma, erf, and the
# Float32 overloads, against Python's values.
#
#     bash bench/std_math_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The negative proofs are patched by python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

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
  "$WORK/$name" $ORACLE >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

# `Math.exp` and `Math.pow` are Arm's optimized-routines exp and pow -
# glibc's since 2.28 - and `bench/arm_math` holds Arm's files as they are
# published, so the
# oracle is that algorithm compiled here, with contraction off, rather than
# this machine's libm: glibc's own build for a processor with FMA answers
# differently in the last bit for about 7 arguments in 10,000, and Apple's
# and Windows' libm are other algorithms. Python draws the arguments -
# over the range, the tiny, the ends and the special cases - and the
# compiled oracle writes each with its answer.
ORACLE=""
CC="${CC:-cc}"
if [ -n "$PY" ] && command -v "$CC" >/dev/null 2>&1 &&
   "$CC" -O2 -ffp-contract=off -fno-builtin -I"$REPO/bench/arm_math" -o "$WORK/arm_math" \
     "$REPO/bench/arm_math/oracle.c" "$REPO/bench/arm_math/exp.c" "$REPO/bench/arm_math/exp_data.c" \
     "$REPO/bench/arm_math/pow.c" "$REPO/bench/arm_math/pow_log_data.c" > "$WORK/arm_math.log" 2>&1; then
  "$PY" - "$WORK/exp.in" <<'PY'
import random, struct, sys
random.seed(2718)
xs = [random.uniform(-20, 20) for _ in range(100000)]
xs += [random.uniform(-1, 1) for _ in range(60000)]
xs += [random.uniform(-745.2, 709.8) for _ in range(60000)]
xs += [random.uniform(-760, -500) for _ in range(40000)]
xs += [random.uniform(500, 720) for _ in range(40000)]
xs += [random.uniform(-1e-15, 1e-15) for _ in range(10000)]
xs += [0.0, -0.0, float("inf"), float("-inf"), float("nan"), 709.782712893384, 709.7827128933841,
       -745.1332191019412, -745.1332191019411, -708.3964185322641, 5e-324, -5e-324, 2.0 ** -54,
       -(2.0 ** -54), 2.0 ** -55, 512.0, -512.0, 1024.0, -1024.0, 1e308, -1e308]
with open(sys.argv[1], "wb") as out:
    for x in xs:
        out.write(struct.pack("<d", x))
PY
  # And pairs for pow: the specials crossed with each other - zeros,
  # infinities, NaN, negative bases, subnormals, the ends of the range -
  # then whole and fractional exponents, bases near one with large ones,
  # subnormal bases, and results either side of overflow and underflow.
  "$PY" - "$WORK/pow.in" <<'PY'
import itertools, random, struct, sys
random.seed(1618)
xs = [0.0, -0.0, 1.0, -1.0, 2.0, -2.0, 0.5, -0.5, 3.0, -3.0, float("inf"), float("-inf"), float("nan"),
      5e-324, -5e-324, 2.2250738585072014e-308, 1e-310, -1e-310, 1.7976931348623157e308,
      -1.7976931348623157e308, 0.9999999999999999, 1.0000000000000002, 10.0, -10.0, 1e300, 1e-300]
ys = [0.0, -0.0, 1.0, -1.0, 2.0, -2.0, 3.0, -3.0, 0.5, -0.5, 1.5, -1.5, float("inf"), float("-inf"),
      float("nan"), 1e-20, -1e-20, 2.0 ** -66, -(2.0 ** -66), 2.0 ** 63, -(2.0 ** 63),
      9007199254740993.0, 1e300, -1e300, 1023.0, 1024.0, -1074.0, -1075.0, 0.1, -0.1, 53.0, 52.0, 1e10]
pairs = list(itertools.product(xs, ys))
for _ in range(40000):
    pairs.append((random.uniform(-10, 10), float(random.randint(-400, 400))))
    pairs.append((random.uniform(0, 10), random.uniform(-10, 10)))
    pairs.append((random.uniform(0.9, 1.1), random.uniform(-1e5, 1e5)))
    pairs.append((random.uniform(1e-310, 1e-300), random.uniform(-2, 2)))
    pairs.append((random.uniform(1, 2), random.uniform(1000, 1100)))
    pairs.append((random.uniform(1, 2), random.uniform(-1100, -1000)))
with open(sys.argv[1], "wb") as out:
    for x, y in pairs:
        out.write(struct.pack("<dd", x, y))
PY
  "$WORK/arm_math" exp "$WORK/exp.in" "$WORK/exp.bin" &&
    "$WORK/arm_math" pow "$WORK/pow.in" "$WORK/pow.bin" &&
    ORACLE="$WORK/exp.bin $WORK/pow.bin"
fi
[ -z "$ORACLE" ] && echo "exp and pow against Arm's: not compared here, because there is no C compiler or no python3 to build and drive the oracle with"

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
if [ -n "$ORACLE" ]; then
  for phrase in "== exp against Arm's exp, bit for bit" "== pow against Arm's pow, bit for bit"; do
    if ! grep -q "$phrase" "$WORK/math-plain.out" 2>/dev/null; then
      echo "  missing section: $phrase"
      status=1
    fi
  done
fi
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
  if [ -z "$PY" ]; then
    echo "  $label: skipped, no working python3 to make the broken copy with"
    return 0
  fi
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  OLD="$old" NEW="$new" "$PY" - <<PY
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
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_math_exercise.iyi" $ORACLE >"$WORK/mut.out" 2>&1; then
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
# The next three change `exp` by a unit or two in the last place, which the
# relative checks above cannot see and the oracle can; without the oracle
# they are not proven here.
if [ -n "$ORACLE" ]; then
  mutate "exp's polynomial a term short" 'r2 * r2 * (EXP_C4 + r * EXP_C5)' 'r2 * r2 * EXP_C4'
  mutate "exp's reduction without ln2's low part" 'r = value + kd * EXP_NEGLN2HI + kd * EXP_NEGLN2LO' 'r = value + kd * EXP_NEGLN2HI'
  mutate "exp's subnormal result rounded twice" '      y = (hi + lo) - 1.0' '      y = y'
  mutate "pow's logarithm a term short" 'ar2 * (POW_A5 + r * POW_A6)' 'ar2 * POW_A5'
  mutate "pow's product with y not split" '    ehi = yhi * lhi
    elo = ylo * lhi + exp * llo' '    ehi = exp * hi
    elo = exp * lo'
  mutate "pow's logarithm without its table's tail" '    lo1 = kd * POW_LN2LO + logctail' '    lo1 = kd * POW_LN2LO'
else
  echo "  exp's and pow's last-bit proofs: not run, no oracle here"
fi
mutate "exp's overflow scale a power off" 'return 5.486124068793689e+303 * (scale + scale * tmp)' 'return 2.7430620343968443e+303 * (scale + scale * tmp)'
mutate "pow's odd power of a negative base positive" 'sign_bias = 0x40000_u64 if yint == 1' 'sign_bias = 0_u64 if yint == 1'
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
