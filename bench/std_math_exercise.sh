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

# `Math.exp`, `exp2`, `log`, `log2` and `pow` are Arm's optimized-routines
# ones - glibc's since 2.28 - and `log10`, `expm1` and `log1p` glibc's
# fdlibm ones, and `bench/libm_oracle` holds those files as they are
# published, so the
# oracle is that algorithm compiled here, with contraction off, rather than
# this machine's libm: glibc's own build for a processor with FMA answers
# differently in the last bit for about 7 arguments in 10,000, and Apple's
# and Windows' libm are other algorithms. Python draws the arguments -
# over the range, the tiny, the ends and the special cases - and the
# compiled oracle writes each with its answer.
ORACLE=""
ORACLE_CM=""
CC="${CC:-cc}"
# Two builds. The first is Arm's files and glibc's fdlibm ones and needs
# nothing past a C compiler; the second adds `core_math/` and the Bessel
# functions, which call libm's exact `fma` and CORE-MATH's sin and cos. A
# toolchain that cannot build the second still checks everything the first
# covers, and says what it could not.
ORACLE_BUILT=""
CM_BUILT=""
if [ -n "$PY" ] && command -v "$CC" >/dev/null 2>&1; then
  if "$CC" -O2 -ffp-contract=off -fno-builtin -I"$REPO/bench/libm_oracle" -o "$WORK/libm_oracle" \
     "$REPO/bench/libm_oracle/oracle.c" "$REPO/bench/libm_oracle/exp.c" \
     "$REPO/bench/libm_oracle/exp_data.c" "$REPO/bench/libm_oracle/pow.c" \
     "$REPO/bench/libm_oracle/pow_log_data.c" "$REPO/bench/libm_oracle/log.c" \
     "$REPO/bench/libm_oracle/log_data.c" "$REPO/bench/libm_oracle/exp2.c" \
     "$REPO/bench/libm_oracle/log2.c" "$REPO/bench/libm_oracle/log2_data.c" \
     "$REPO/bench/libm_oracle/e_log10.c" "$REPO/bench/libm_oracle/s_expm1.c" \
     "$REPO/bench/libm_oracle/s_log1p.c" "$REPO/bench/libm_oracle/e_sinh.c" \
     "$REPO/bench/libm_oracle/e_cosh.c" "$REPO/bench/libm_oracle/s_tanh.c" > "$WORK/libm_oracle.log" 2>&1; then
    ORACLE_BUILT=1
  else
    echo "the oracle did not build here:"
    sed -n '1,12p' "$WORK/libm_oracle.log"
  fi
  if [ -n "$ORACLE_BUILT" ] &&
     "$CC" -O2 -ffp-contract=off -fno-builtin -DIYI_ORACLE_CORE_MATH -Dattribute_hidden= \
       -D__builtin_roundeven=__builtin_rint \
       -I"$REPO/bench/libm_oracle" -o "$WORK/libm_oracle_cm" \
     "$REPO/bench/libm_oracle/oracle.c" "$REPO/bench/libm_oracle/exp.c" \
     "$REPO/bench/libm_oracle/exp_data.c" "$REPO/bench/libm_oracle/pow.c" \
     "$REPO/bench/libm_oracle/pow_log_data.c" "$REPO/bench/libm_oracle/log.c" \
     "$REPO/bench/libm_oracle/log_data.c" "$REPO/bench/libm_oracle/exp2.c" \
     "$REPO/bench/libm_oracle/log2.c" "$REPO/bench/libm_oracle/log2_data.c" \
     "$REPO/bench/libm_oracle/e_log10.c" "$REPO/bench/libm_oracle/s_expm1.c" \
     "$REPO/bench/libm_oracle/s_log1p.c" "$REPO/bench/libm_oracle/e_sinh.c" \
     "$REPO/bench/libm_oracle/e_cosh.c" "$REPO/bench/libm_oracle/s_tanh.c" \
     "$REPO/bench/libm_oracle/e_j0.c" "$REPO/bench/libm_oracle/e_j1.c" \
     "$REPO/bench/libm_oracle/e_jn.c" "$REPO/bench/libm_oracle/core_math/s_erf.c" \
     "$REPO/bench/libm_oracle/core_math/s_erf_common.c" \
     "$REPO/bench/libm_oracle/core_math/s_erf_data.c" "$REPO/bench/libm_oracle/core_math/s_erfc.c" \
     "$REPO/bench/libm_oracle/core_math/s_erfc_data.c" \
     "$REPO/bench/libm_oracle/core_math/s_asinh.c" "$REPO/bench/libm_oracle/core_math/e_acosh.c" \
     "$REPO/bench/libm_oracle/core_math/e_atanh.c" \
     "$REPO/bench/libm_oracle/core_math/s_asincosh_data.c" \
     "$REPO/bench/libm_oracle/core_math/s_atanh_data.c" "$REPO/bench/libm_oracle/core_math/atan.c" \
     "$REPO/bench/libm_oracle/core_math/asin.c" "$REPO/bench/libm_oracle/core_math/acos.c" \
     "$REPO/bench/libm_oracle/core_math/e_gamma_r.c" \
     "$REPO/bench/libm_oracle/core_math/e_lgamma_r.c" "$REPO/bench/libm_oracle/core_math/tan.c" \
     "$REPO/bench/libm_oracle/core_math/sin.c" "$REPO/bench/libm_oracle/core_math/cos.c" \
     "$REPO/bench/libm_oracle/core_math/cbrt.c" "$REPO/bench/libm_oracle/core_math/hypot.c" \
     "$REPO/bench/libm_oracle/core_math/atan2.c" -lm > "$WORK/libm_oracle_cm.log" 2>&1; then
    CM_BUILT=1
  elif [ -n "$ORACLE_BUILT" ]; then
    echo "the oracle's CORE-MATH and Bessel part did not build here:"
    sed -n '1,15p' "$WORK/libm_oracle_cm.log"
  fi
fi
if [ -n "$ORACLE_BUILT" ]; then
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
  # And log's: the range by magnitude, the band around 1 its polynomial
  # takes and that band's two edges, the subnormals, and the specials.
  "$PY" - "$WORK/log.in" <<'PY'
import random, struct, sys
random.seed(1414)
xs = [10 ** random.uniform(-300, 300) for _ in range(60000)]
xs += [random.uniform(1e-3, 1e6) for _ in range(60000)]
xs += [random.uniform(0.9, 1.1) for _ in range(60000)]
xs += [random.uniform(1 - 2 ** -4 - 1e-6, 1 - 2 ** -4 + 1e-6) for _ in range(5000)]
xs += [random.uniform(1.0646972656 - 1e-6, 1.0646972656 + 1e-6) for _ in range(5000)]
xs += [random.uniform(0, 1e-307) for _ in range(20000)]
xs += [0.0, -0.0, 1.0, -1.0, float("inf"), float("-inf"), float("nan"), 5e-324, 2.2250738585072014e-308,
       1.7976931348623157e308, 0.9999999999999999, 1.0000000000000002, 1 - 2 ** -4, 1 + float.fromhex("0x1.09p-4")]
with open(sys.argv[1], "wb") as out:
    for x in xs:
        out.write(struct.pack("<d", x))
PY
  # exp2's: the whole range and the band past each end its special case
  # takes, whole numbers, and the edges of overflow and underflow; log2's:
  # the range, the band around 1, the subnormals and every power of two.
  "$PY" - "$WORK/exp2.in" "$WORK/log2.in" "$WORK/log10.in" "$WORK/expm1.in" "$WORK/log1p.in" <<'PY'
import random, struct, sys
random.seed(1732)
xs = [random.uniform(-1080, 1030) for _ in range(100000)]
xs += [random.uniform(-1, 1) for _ in range(50000)]
xs += [float(random.randint(-1080, 1030)) for _ in range(5000)]
xs += [0.0, -0.0, float("inf"), float("-inf"), float("nan"), 1024.0, -1074.0, -1075.0,
       -1075.0000000000002, -1076.0, 928.0, 928.0000000000001, -928.0, -929.0, 5e-324, 1e-17]
ys = [10 ** random.uniform(-307, 308) for _ in range(100000)]
ys += [random.uniform(0.95, 1.06) for _ in range(50000)]
ys += [random.uniform(0, 1e-307) for _ in range(20000)]
ys += [2.0 ** k for k in range(-1074, 1024)]
ys += [0.0, -0.0, -1.0, float("inf"), float("-inf"), float("nan"), 1.0]
# log10's: the range, the subnormals, every power of ten, the band around 1.
zs = [10 ** random.uniform(-307, 308) for _ in range(100000)]
zs += [random.uniform(0, 1e-307) for _ in range(20000)]
zs += [10.0 ** k for k in range(-323, 309)]
zs += [random.uniform(0.9, 1.1) for _ in range(30000)]
zs += [0.0, -0.0, -1.0, float("inf"), float("-inf"), float("nan"), 1.0, 5e-324]
# expm1's: near zero, the range to overflow, the tiny, the saturation below
# -56 ln2 and the edges of each reduction; log1p's: the range, near zero,
# the band that is not reduced and its edges, -1 and below, the huge.
es = [random.uniform(-5, 5) for _ in range(100000)]
es += [random.uniform(-40, 710) for _ in range(50000)]
es += [random.uniform(-1e-8, 1e-8) for _ in range(10000)]
es += [random.uniform(-800, -30) for _ in range(5000)]
es += [0.0, -0.0, float("inf"), float("-inf"), float("nan"), 709.782712893384, 709.7827128933841,
       38.816242111356935, -38.816242111356935, 0.34657359027997264, -0.34657359027997264,
       1.0397207708399179, 5e-324, 1e-17, 2.0 ** -54, -(2.0 ** -54)]
ls = [random.uniform(-0.99999, 5) for _ in range(100000)]
ls += [10 ** random.uniform(-20, 300) for _ in range(50000)]
ls += [random.uniform(-0.3, 0.42) for _ in range(20000)]
ls += [random.uniform(-1e-9, 1e-9) for _ in range(5000)]
ls += [0.0, -0.0, -1.0, -1.0000000000000002, float("inf"), float("-inf"), float("nan"), 0.41421356,
       -0.2928932, 2.0 ** -29, -(2.0 ** -29), 2.0 ** -54, 1e300, 4503599627370496.0, 9007199254740992.0]
for path, values in ((sys.argv[1], xs), (sys.argv[2], ys), (sys.argv[3], zs), (sys.argv[4], es), (sys.argv[5], ls)):
    with open(path, "wb") as out:
        for v in values:
            out.write(struct.pack("<d", v))
PY
  # sinh's, cosh's and tanh's: every branch fdlibm takes and each side of
  # its thresholds - 2^-55 and 2^-28, cosh's 0.5 ln 2, 1, 22, log(DBL_MAX)
  # and the overflow threshold - both signs, and the specials.
  "$PY" - "$WORK/hyp.in" <<'PY'
import random, struct, sys
random.seed(1729)
xs = [random.uniform(-25, 25) for _ in range(100000)]
xs += [random.uniform(-1, 1) for _ in range(50000)]
xs += [random.choice([1, -1]) * 10 ** random.uniform(-20, 0) for _ in range(50000)]
xs += [random.choice([1, -1]) * random.uniform(20, 712) for _ in range(50000)]
for edge in (2.0 ** -55, 2.0 ** -28, 0.34657359027997264, 1.0, 22.0, 709.782712893384, 710.4758600739439):
    xs += [random.choice([1, -1]) * edge * (1 + random.uniform(-1e-6, 1e-6)) for _ in range(2000)]
    xs += [edge, -edge]
xs += [0.0, -0.0, float("inf"), float("-inf"), float("nan"), 5e-324, -5e-324, 1e-310, 710.4758600739440,
       710.4758600739439, 1e300, -1e300]
with open(sys.argv[1], "wb") as out:
    for x in xs:
        out.write(struct.pack("<d", x))
PY
  # erf's and erfc's: the magnitudes from 2^-70 to 32, where erf's
  # tiny formula, its two polynomial tables and erfc's asymptotic tables
  # and underflow each take over; the band where erfc's result is
  # subnormal; erfc's negatives out to where it is 2; the subnormals and
  # the specials.
  "$PY" - "$WORK/erf.in" <<'PY'
import random, struct, sys
random.seed(1830)
xs = [random.choice([1, -1]) * 2 ** random.uniform(-70, 5) for _ in range(80000)]
xs += [random.uniform(-6, 6) for _ in range(60000)]
xs += [random.uniform(1.7, 28) for _ in range(40000)]
xs += [random.uniform(25.8, 27.3) for _ in range(20000)]
xs += [random.choice([1, -1]) * random.uniform(0, 2.2250738585072014e-308) for _ in range(5000)]
for edge in (5.9215871957945065, 2.0 ** -61, 5.86183139113198, 27.226017111108366, 0.0625, 0.125, 1.0):
    xs += [random.choice([1, -1]) * edge * (1 + random.uniform(-1e-9, 1e-9)) for _ in range(1000)]
xs += [0.0, -0.0, float("inf"), float("-inf"), float("nan"), 5e-324, -5e-324, 1e300, -1e300]
with open(sys.argv[1], "wb") as out:
    for x in xs:
        out.write(struct.pack("<d", x))
PY
  # asinh's, acosh's and atanh's, one set for the three: the magnitudes
  # across the whole range, 1 from above to 2^60 for acosh, 1 from below
  # for atanh, the tiny, the subnormals, the out-of-domain and the specials.
  "$PY" - "$WORK/ash.in" <<'PY'
import random, struct, sys
random.seed(1885)
xs = [random.choice([1, -1]) * 2 ** random.uniform(-1074, 1023) for _ in range(60000)]
xs += [random.choice([1, -1]) * 2 ** random.uniform(-40, 40) for _ in range(60000)]
xs += [1 + 2 ** random.uniform(-52, 6) for _ in range(40000)]
xs += [random.choice([1, -1]) * (1 - 2 ** random.uniform(-53, -1)) for _ in range(40000)]
xs += [random.choice([1, -1]) * random.uniform(0, 2.2250738585072014e-308) for _ in range(5000)]
xs += [0.0, -0.0, 1.0, -1.0, 2.0, -2.0, 0.25, -0.25, float("inf"), float("-inf"), float("nan"), 5e-324, -5e-324,
       1.0000000000000002, 0.9999999999999999, -0.9999999999999999, 1.7976931348623157e308]
with open(sys.argv[1], "wb") as out:
    for x in xs:
        out.write(struct.pack("<d", x))
PY
  # atan's, asin's and acos's: atan over the whole range and the band its
  # small-argument refinement takes, asin and acos across [-1, 1], near
  # the ends and near zero, the out-of-domain, the subnormals, the specials.
  "$PY" - "$WORK/atan.in" "$WORK/asin.in" <<'PY'
import random, struct, sys
random.seed(1914)
xs = [random.choice([1, -1]) * 2 ** random.uniform(-1074, 1023) for _ in range(60000)]
xs += [random.choice([1, -1]) * 2 ** random.uniform(-30, 60) for _ in range(80000)]
xs += [random.choice([1, -1]) * 2 ** random.uniform(-27, -7.2) for _ in range(40000)]
xs += [0.0, -0.0, 1.0, -1.0, float("inf"), float("-inf"), float("nan"), 5e-324, -5e-324, 1.7976931348623157e308]
ys = [random.uniform(-1, 1) for _ in range(80000)]
ys += [random.choice([1, -1]) * (1 - 2 ** random.uniform(-53, -1)) for _ in range(60000)]
ys += [random.choice([1, -1]) * 2 ** random.uniform(-1074, 0) for _ in range(40000)]
ys += [0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 1.0000000000000002, -1.0000000000000002, 2.0, float("inf"), float("-inf"),
       float("nan"), 5e-324, -5e-324]
for path, values in ((sys.argv[1], xs), (sys.argv[2], ys)):
    with open(path, "wb") as out:
        for v in values:
            out.write(struct.pack("<d", v))
PY
  # lgamma's and tgamma's, one set: the whole range, the band where tgamma
  # is finite, the negatives down to where it underflows, each side of the
  # integers and half-integers from -200 to 200, near lgamma's zeros at 1
  # and 2, the tiny, the subnormals and the specials.
  "$PY" - "$WORK/gamma.in" <<'PY'
import random, struct, sys
random.seed(1729 * 2)
xs = [random.choice([1, -1]) * 2 ** random.uniform(-1074, 1023) for _ in range(50000)]
xs += [random.uniform(-185, 172) for _ in range(80000)]
xs += [random.uniform(0, 10) for _ in range(30000)]
xs += [random.choice([1.0, 2.0]) + random.choice([1, -1]) * 2 ** random.uniform(-52, -2) for _ in range(20000)]
for k in range(-400, 401):
    for _ in range(20):
        xs.append(k / 2 + random.choice([1, -1]) * 2 ** random.uniform(-50, -3))
    xs.append(k / 2)
xs += [random.choice([1, -1]) * random.uniform(0, 2.2250738585072014e-308) for _ in range(5000)]
xs += [0.0, -0.0, 1.0, 2.0, -1.0, float("inf"), float("-inf"), float("nan"), 5e-324, -5e-324,
       171.62437695630272, 171.6243769563027, 1.7976931348623157e308, -1.7976931348623157e308]
with open(sys.argv[1], "wb") as out:
    for x in xs:
        out.write(struct.pack("<d", x))
PY
  # sin's, cos's and tan's: the whole range to 2^1023, where the reduction takes the table
  # of 2/pi's bits; [-10, 10]; each side of the multiples of pi/2 and
  # pi/4, the poles and zeros a reduction can lose; the worst cases for
  # reduction the literature names; the tiny and the specials.
  "$PY" - "$WORK/trig.in" <<'PY'
import math, random, struct, sys
random.seed(3141)
xs = [random.choice([1, -1]) * 2 ** random.uniform(-40, 1023) for _ in range(80000)]
xs += [random.uniform(-10, 10) for _ in range(80000)]
for k in range(1, 20001):
    x = k * math.pi / 4
    xs += [x, math.nextafter(x, 0), math.nextafter(x, math.inf)]
for x in (6381956970095103 * 2.0 ** 797, 5261692873635770 * 2.0 ** 499, float.fromhex("0x1.6ac5b262ca1ffp+851"),
          float.fromhex("0x1.61a3db8c8d129p+1023"), float.fromhex("0x1.dffffffffff1fp-22"),
          float.fromhex("0x1.dfffffffffc7cp-21")):
    xs += [x, -x, math.nextafter(x, 0), math.nextafter(x, math.inf)]
xs += [random.choice([1, -1]) * 2 ** random.uniform(-1074, -26) for _ in range(5000)]
xs += [0.0, -0.0, float("inf"), float("-inf"), float("nan"), 5e-324, 1.7976931348623157e308]
with open(sys.argv[1], "wb") as out:
    for x in xs:
        out.write(struct.pack("<d", x))
PY
  # The Bessel functions': the magnitudes from 2^-60 to 2^60, [0, 100]
  # densely, each side of fdlibm's thresholds, the negatives, the
  # subnormals and the specials; and for jn and yn every order from -5 to
  # 30 and a few large ones against a sample of those.
  "$PY" - "$WORK/bessel.in" "$WORK/besseln.in" <<'PY'
import random, struct, sys
random.seed(1824)
xs = [random.choice([1, -1]) * 2 ** random.uniform(-60, 60) for _ in range(60000)]
xs += [random.uniform(0, 100) for _ in range(60000)]
for edge in (2.0 ** -27, 2.0 ** -13, 2.0 ** -3, 1.0, 2.0, 2.857142857142857, 4.545454545454545, 8.0, 2.0 ** 129, 2.0 ** 302):
    xs += [edge * (1 + random.uniform(-1e-9, 1e-9)) for _ in range(500)]
    xs += [edge, -edge]
xs += [random.choice([1, -1]) * random.uniform(0, 2.2250738585072014e-308) for _ in range(2000)]
xs += [0.0, -0.0, float("inf"), float("-inf"), float("nan"), 5e-324, 1.7976931348623157e308]
orders = list(range(-5, 31)) + [50, 100, -100, 1000, -1000]
pairs = []
for n in orders:
    for _ in range(1500):
        pairs.append((float(n), random.choice([random.uniform(0, 3 * abs(n) + 5), 2 ** random.uniform(-30, 40)])))
    for x in (0.0, -0.0, -1.5, float("inf"), float("nan"), 5e-324, float(abs(n))):
        pairs.append((float(n), x))
with open(sys.argv[1], "wb") as out:
    for x in xs:
        out.write(struct.pack("<d", x))
with open(sys.argv[2], "wb") as out:
    for n, x in pairs:
        out.write(struct.pack("<dd", n, x))
PY
  # cbrt's: the whole range, the subnormals, perfect cubes and their
  # neighbours, both signs and the specials; hypot's: pairs at every
  # exponent gap, near the overflow edge, both subnormal, one subnormal,
  # near Pythagorean triples, and the specials crossed.
  "$PY" - "$WORK/cbrt.in" "$WORK/hypot.in" "$WORK/atan2.in" <<'PY'
import math, random, struct, sys
random.seed(1637)
xs = [random.choice([1, -1]) * 2 ** random.uniform(-1074, 1023) for _ in range(80000)]
xs += [random.choice([1, -1]) * random.uniform(0, 2.2250738585072014e-308) for _ in range(5000)]
for k in range(1, 20000):
    c = float(k) ** 3 * 2.0 ** (3 * random.randint(-300, 300))
    xs += [c, math.nextafter(c, 0), math.nextafter(c, math.inf)]
xs += [0.0, -0.0, float("inf"), float("-inf"), float("nan"), 5e-324, 1.7976931348623157e308]
ps = []
for _ in range(80000):
    x = random.choice([1, -1]) * 2 ** random.uniform(-1000, 1000)
    ps.append((x, x * random.choice([1, -1]) * 2 ** random.uniform(-70, 70)))
for _ in range(10000):
    ps.append((random.uniform(1e307, 1.7e308), random.uniform(1e307, 1.7e308)))
    ps.append((random.uniform(0, 2.2250738585072014e-308), random.uniform(0, 2.2250738585072014e-308)))
    ps.append((random.uniform(0, 2.2250738585072014e-308), 2 ** random.uniform(-1022, -900)))
for _ in range(10000):
    a, b = random.randint(1, 10 ** 6), random.randint(1, 10 ** 6)
    s = 2.0 ** random.randint(-500, 500)
    ps.append(((a * a - b * b) * s, 2 * a * b * s))
sp = [0.0, -0.0, 1.0, float("inf"), float("-inf"), float("nan"), 5e-324, 1.7976931348623157e308]
ps += [(a, b) for a in sp for b in sp]
# atan2's: every quadrant at quotients from 2^-1100 to 2^1100 (past 53
# binades apart, its slow exact path), both near the halfway 1 and the
# table's 64ths, subnormals, the huge and the specials crossed.
qs = []
for _ in range(150000):
    ex = random.uniform(-500, 500)
    ey = ex + random.uniform(-1100, 1100)
    if -1074 < ey < 1023:
        qs.append((random.choice([1, -1]) * 2 ** ey, random.choice([1, -1]) * 2 ** ex))
for _ in range(60000):
    x = random.choice([1, -1]) * 2 ** random.uniform(-60, 60)
    t = random.randint(1, 64) / 64.0 * (1 + random.uniform(-1e-12, 1e-12))
    qs.append((random.choice([1, -1]) * x * t, x) if random.random() < 0.5 else (x, random.choice([1, -1]) * x * t))
for _ in range(10000):
    qs.append((random.uniform(-2.2250738585072014e-308, 2.2250738585072014e-308), random.choice([1, -1]) * 2 ** random.uniform(-1074, 0)))
    qs.append((random.uniform(-1.7e308, 1.7e308), random.uniform(-1.7e308, 1.7e308)))
sp = [0.0, -0.0, 1.0, -1.0, float("inf"), float("-inf"), float("nan"), 5e-324, -5e-324, 1.7976931348623157e308]
qs += [(a, b) for a in sp for b in sp]
for path, rows in ((sys.argv[1], [(x,) for x in xs]), (sys.argv[2], ps), (sys.argv[3], qs)):
    with open(path, "wb") as out:
        for row in rows:
            out.write(struct.pack("<%dd" % len(row), *row))
PY
  "$WORK/libm_oracle" exp "$WORK/exp.in" "$WORK/exp.bin" &&
    "$WORK/libm_oracle" pow "$WORK/pow.in" "$WORK/pow.bin" &&
    "$WORK/libm_oracle" log "$WORK/log.in" "$WORK/log.bin" &&
    "$WORK/libm_oracle" exp2 "$WORK/exp2.in" "$WORK/exp2.bin" &&
    "$WORK/libm_oracle" log2 "$WORK/log2.in" "$WORK/log2.bin" &&
    "$WORK/libm_oracle" log10 "$WORK/log10.in" "$WORK/log10.bin" &&
    "$WORK/libm_oracle" expm1 "$WORK/expm1.in" "$WORK/expm1.bin" &&
    "$WORK/libm_oracle" log1p "$WORK/log1p.in" "$WORK/log1p.bin" &&
    "$WORK/libm_oracle" sinh "$WORK/hyp.in" "$WORK/sinh.bin" &&
    "$WORK/libm_oracle" cosh "$WORK/hyp.in" "$WORK/cosh.bin" &&
    "$WORK/libm_oracle" tanh "$WORK/hyp.in" "$WORK/tanh.bin" &&
    ORACLE="$WORK/exp.bin $WORK/pow.bin $WORK/log.bin $WORK/exp2.bin $WORK/log2.bin $WORK/log10.bin $WORK/expm1.bin $WORK/log1p.bin $WORK/sinh.bin $WORK/cosh.bin $WORK/tanh.bin"
  if [ -n "$ORACLE" ] && [ -n "$CM_BUILT" ]; then
    "$WORK/libm_oracle_cm" erf "$WORK/erf.in" "$WORK/erf.bin" &&
      "$WORK/libm_oracle_cm" erfc "$WORK/erf.in" "$WORK/erfc.bin" &&
      "$WORK/libm_oracle_cm" asinh "$WORK/ash.in" "$WORK/asinh.bin" &&
      "$WORK/libm_oracle_cm" acosh "$WORK/ash.in" "$WORK/acosh.bin" &&
      "$WORK/libm_oracle_cm" atanh "$WORK/ash.in" "$WORK/atanh.bin" &&
      "$WORK/libm_oracle_cm" atan "$WORK/atan.in" "$WORK/atan.bin" &&
      "$WORK/libm_oracle_cm" asin "$WORK/asin.in" "$WORK/asin.bin" &&
      "$WORK/libm_oracle_cm" acos "$WORK/asin.in" "$WORK/acos.bin" &&
      "$WORK/libm_oracle_cm" tan "$WORK/trig.in" "$WORK/tan.bin" &&
      "$WORK/libm_oracle_cm" j0 "$WORK/bessel.in" "$WORK/j0.bin" &&
      "$WORK/libm_oracle_cm" j1 "$WORK/bessel.in" "$WORK/j1.bin" &&
      "$WORK/libm_oracle_cm" y0 "$WORK/bessel.in" "$WORK/y0.bin" &&
      "$WORK/libm_oracle_cm" y1 "$WORK/bessel.in" "$WORK/y1.bin" &&
      "$WORK/libm_oracle_cm" jn "$WORK/besseln.in" "$WORK/jn.bin" &&
      "$WORK/libm_oracle_cm" yn "$WORK/besseln.in" "$WORK/yn.bin" &&
      "$WORK/libm_oracle_cm" cbrt "$WORK/cbrt.in" "$WORK/cbrt.bin" &&
      "$WORK/libm_oracle_cm" hypot "$WORK/hypot.in" "$WORK/hypot.bin" &&
      "$WORK/libm_oracle_cm" atan2 "$WORK/atan2.in" "$WORK/atan2.bin" &&
      "$WORK/libm_oracle_cm" sin "$WORK/trig.in" "$WORK/sin.bin" &&
      "$WORK/libm_oracle_cm" cos "$WORK/trig.in" "$WORK/cos.bin" &&
      "$WORK/libm_oracle_cm" lgamma "$WORK/gamma.in" "$WORK/lgamma.bin" &&
      "$WORK/libm_oracle_cm" tgamma "$WORK/gamma.in" "$WORK/tgamma.bin" &&
      ORACLE_CM=1 &&
      ORACLE="$ORACLE $WORK/erf.bin $WORK/erfc.bin $WORK/asinh.bin $WORK/acosh.bin $WORK/atanh.bin $WORK/atan.bin $WORK/asin.bin $WORK/acos.bin $WORK/lgamma.bin $WORK/tgamma.bin $WORK/tan.bin $WORK/sin.bin $WORK/cos.bin $WORK/j0.bin $WORK/j1.bin $WORK/y0.bin $WORK/y1.bin $WORK/jn.bin $WORK/yn.bin $WORK/cbrt.bin $WORK/hypot.bin $WORK/atan2.bin"
  fi
fi

# `Math.fma`'s cases carry their exact answers, which python works out
# with fractions, so they need no C compiler and run wherever python does.
FMA=""
if [ -n "$PY" ] && "$PY" "$REPO/bench/std_math_fma.py" "$WORK/fma_doubles.bin" "$WORK/fma_singles.bin"; then
  export IYI_MATH_FMA_DOUBLES="$WORK/fma_doubles.bin" IYI_MATH_FMA_SINGLES="$WORK/fma_singles.bin"
  FMA=1
else
  echo "fma against the exact sum: not compared here, because there is no python3 to write the cases with"
fi
[ -z "$ORACLE" ] && echo "exp, exp2, expm1, log, log1p, log2, log10, pow, sinh, cosh and tanh against the oracle: not compared here, because there is no C compiler or no python3 to build and drive the oracle with"
[ -z "$ORACLE_CM" ] && echo "erf, erfc, asinh, acosh, atanh, atan, asin, acos, sin, cos, tan, lgamma, tgamma, the Bessel functions, cbrt, hypot and atan2 against the oracle: not compared here, because its CORE-MATH part did not build or run"

echo "== the std/math exercise, plain build"
build_and_run "plain" math-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/math-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every math section reported"
for phrase in "== sqrt" "== sincos" "== frexp and ldexp" "== log, log2, log10" "== exp, exp2, expm1, log1p" "== pow" "== atan, atan2, asin, acos" "== the hyperbolic functions and hypot, cbrt" "== gamma, lgamma" "== erf, erfc" "== fma, min, max, gcd" "== isqrt, pw2ceil, ilogb, logb, scalbn, scalbln" "== the Float32 overloads"; do
  if ! grep -q "$phrase" "$WORK/math-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
if [ -n "$ORACLE" ]; then
  for phrase in "== exp against Arm's exp, bit for bit" "== pow against Arm's pow, bit for bit" "== log against Arm's log, bit for bit" "== exp2 against Arm's exp2, bit for bit" "== log2 against Arm's log2, bit for bit" "== log10 against glibc's log10, bit for bit" "== expm1 against glibc's expm1, bit for bit" "== log1p against glibc's log1p, bit for bit" "== sinh against glibc's sinh, bit for bit" "== cosh against glibc's cosh, bit for bit" "== tanh against glibc's tanh, bit for bit"; do
    if ! grep -q "$phrase" "$WORK/math-plain.out" 2>/dev/null; then
      echo "  missing section: $phrase"
      status=1
    fi
  done
fi
if [ -n "$ORACLE_CM" ]; then
  for phrase in "== erf against glibc's erf, bit for bit" "== erfc against glibc's erfc, bit for bit" "== asinh against glibc's asinh, bit for bit" "== acosh against glibc's acosh, bit for bit" "== atanh against glibc's atanh, bit for bit" "== atan against CORE-MATH's atan, bit for bit" "== asin against CORE-MATH's asin, bit for bit" "== acos against CORE-MATH's acos, bit for bit" "== lgamma against glibc's lgamma, bit for bit" "== tgamma against glibc's tgamma, bit for bit" "== tan against CORE-MATH's tan, bit for bit" "== sin against CORE-MATH's sin, bit for bit" "== cos against CORE-MATH's cos, bit for bit" "== besselj0 against glibc's besselj0, bit for bit" "== bessely1 against glibc's bessely1, bit for bit" "== jn and yn against glibc's, bit for bit" "== cbrt against CORE-MATH's cbrt, bit for bit" "== hypot against CORE-MATH's hypot, bit for bit" "== atan2 against CORE-MATH's atan2, bit for bit"; do
    if ! grep -q "$phrase" "$WORK/math-plain.out" 2>/dev/null; then
      echo "  missing section: $phrase"
      status=1
    fi
  done
fi
if [ -n "$FMA" ] && ! grep -q "== fma against the exact sum rounded once, bit for bit" "$WORK/math-plain.out" 2>/dev/null; then
  echo "  missing section: == fma against the exact sum rounded once, bit for bit"
  status=1
fi
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" math-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/math-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

# x86_64 fuses with `vfmadd` where the processor has FMA3, which every CI
# runner's does, so musl's arm would go unrun there; the same exercise
# once more with the processor's answer taken to be no.
if [ -n "$FMA" ] && [ -n "$PY" ]; then
  echo
  echo "== fma's software arm, the processor's instruction refused"
  rm -rf "$WORK/software"
  mkdir -p "$WORK/software/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/software/iyi/"
  "$PY" - "$REPO/src/iyi/float.iyi" "$WORK/software/iyi/float.iyi" <<'PY'
import sys
src = open(sys.argv[1]).read()
old = "      fuses == 1\n"
if src.count(old) != 1:
    raise SystemExit("patch site missing")
open(sys.argv[2], "w").write(src.replace(old, "      false\n"))
PY
  if [ $? -ne 0 ]; then
    echo "  software: the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/software${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build --release -o "$WORK/software/program" \
         "$REPO/bench/std_math_exercise.iyi" > "$WORK/software/build" 2>&1 &&
       "$WORK/software/program" > "$WORK/software/out" 2>&1 &&
       grep -q "ALL CHECKS PASSED" "$WORK/software/out"; then
    grep -A1 "== fma against" "$WORK/software/out" | sed -n '2p'
  else
    echo "  software: musl's arm did not answer as the instruction does"
    tail -3 "$WORK/software/out" "$WORK/software/build" 2>/dev/null
    status=1
  fi
fi

echo
echo "== proving the checks can fail when the module is broken"
mutate() { # mutate <label> <old> <new> [<old2> <new2>]: math.iyi's, then the prelude's float.iyi's
  local label="$1" old="$2" new="$3" old2="${4:-}" new2="${5:-}"
  if [ -z "$PY" ]; then
    echo "  $label: skipped, no working python3 to make the broken copy with"
    return 0
  fi
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std" "$WORK/patched/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/patched/iyi/"
  OLD="$old" NEW="$new" OLD2="$old2" NEW2="$new2" "$PY" - <<PY
import os
from pathlib import Path
for name, o, n in (("std/math.iyi", os.environ["OLD"], os.environ["NEW"]),
                   ("iyi/float.iyi", os.environ["OLD2"], os.environ["NEW2"])):
    src = Path("$REPO/src/" + name).read_text()
    if o:
        if o not in src:
            raise SystemExit("patch site missing: " + o)
        src = src.replace(o, n, 1)
    Path("$WORK/patched/" + name).write_text(src)
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
  # `--` before the oracle's files: without it `iyi run` compiled them as
  # more source, the broken build failed on that, and every proof here
  # read "caught" without a check having seen the break - as did four
  # whose patch did not compile. So the failure has to be the program's:
  # a check's, or a panic the broken module ran into.
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_math_exercise.iyi" -- $ORACLE >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif grep -q "ASSERTION FAILED\|iyi: panic:" "$WORK/mut.out"; then
    echo "  $label: caught"
  else
    echo "  $label: failed, but at no check:"
    sed -n '1,4p' "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
mutate "a subnormal left unscaled by frexp" 'bits = IyiFloatText.bits_of(value * TWO_54)' 'bits = IyiFloatText.bits_of(value)'
# The proofs below change a function by a unit or two in the last place,
# which the relative checks above cannot see and the oracle can; without
# the oracle, or its CORE-MATH part, they are not proven here.
if [ -n "$ORACLE" ]; then
  mutate "exp's polynomial a term short" 'r2 * r2 * (EXP_C4 + r * EXP_C5)' 'r2 * r2 * EXP_C4'
  mutate "exp's reduction without ln2's low part" 'r = value + kd * EXP_NEGLN2HI + kd * EXP_NEGLN2LO' 'r = value + kd * EXP_NEGLN2HI'
  mutate "exp's subnormal result rounded twice" '      y = (hi + lo) - 1.0' '      y = y * 1.0'
  mutate "pow's logarithm a term short" 'ar2 * (POW_A5 + r * POW_A6)' 'ar2 * POW_A5'
  mutate "pow's product with y not split" '    ehi = yhi * lhi
    elo = ylo * lhi + exp * llo' '    ehi = exp * hi
    elo = exp * lo'
  mutate "pow's logarithm without its table's tail" '    lo1 = kd * POW_LN2LO + logctail' '    lo1 = kd * POW_LN2LO'
  mutate "log near one squaring r in one part" '      lo = lo + LOG_B0 * rlo * (rhi + r)' '      lo = lo * 1.0'
  mutate "log's reduction without c's low part" ' - IyiFloatText.from_bits(table[i * 4 + 3])) * invc' ') * invc'
  mutate "log's polynomial a term short" 'r2 * (LOG_A3 + r * LOG_A4)' 'r2 * LOG_A3'
  mutate "log10 without log10(2)'s low part" '    z = y * LOG10_2LO + LOG10_IVLN10 * log(x)' '    z = LOG10_IVLN10 * log(x)'
  mutate "expm1 without its reduction's correction" '    e = x * (e - c) - c' '    e = x * e'
  mutate "log1p without the correction for 1 + x" '        c = c / u' '        c = 0.0'
  mutate "exp2's polynomial a term short" 'r2 * r2 * (EXP2_C4 + r * EXP2_C5)' 'r2 * r2 * EXP2_C4'
  mutate "log2 near one with r in one part" '      hi = rhi * LOG2_INVLN2HI
      lo = rlo * LOG2_INVLN2HI + r * LOG2_INVLN2LO' '      hi = r * LOG2_INVLN2HI
      lo = r * LOG2_INVLN2LO'
  mutate "sinh's middle branch from 1 rather than 2^-28" '      return h * (2.0 * t - t * t / (t + 1.0)) if ix < 0x3ff00000_i64' '      return h * (2.0 * t - t * t / (t + 1.0)) if ix < 0x3e300000_i64'
  mutate "cosh by exp below 0.5 ln 2" '      if ix < 0x3fd62e43_i64' '      if ix < 0x3c800000_i64'
  mutate "tanh by one expm1 below 1" '      if ix >= 0x3ff00000_i64' '      if ix >= 0x3c800000_i64'
  mutate "log2's reduction without c's low part" ' - IyiFloatText.from_bits(table[i * 4 + 3])) * invc
    rhi' ') * invc
    rhi'
  # Edges the relative checks let through and the oracle does not.
  mutate "log10's exponent rounded the other way below one" '    i = k < 0_i64 ? 1_i64 : 0_i64' '    i = 0_i64'
  mutate "pow's odd power of a negative base positive" 'sign_bias = 0x40000_u64 if yint == 1' 'sign_bias = 0_u64 if yint == 1'
  mutate "exp2's overflow scale halved" '        return 2.0 * (scale + scale * tmp)' '        return scale + scale * tmp'
else
  echo "  the last-bit proofs of exp, exp2, expm1, log, log1p, log2, log10, pow, sinh, cosh and tanh: not run, no oracle here"
fi
if [ -n "$ORACLE_CM" ]; then
  # erf and erfc fall back to an exact path when the fast one cannot
  # prove its rounding, so what is broken here is shared by both.
  mutate "erf's fast two-sum without its low part" '    {hi, b - e}' '    {hi, 0.0}'
  mutate "erfc past 2.88 without 1/x's low part" '    yl = yh * fma(x * -1.0, yh, 1.0)' '    yl = 0.0'
  mutate "erfc of a negative with 1 + erf rounded" '      h, t = erf_fast_two_sum(1.0, h)' '      h, t = {1.0 + h, 0.0}'
  mutate "asinh's fast two-sum without its low part" '    {s, y - z}' '    {s, 0.0}'
  mutate "acosh near 1 without the square root's correction" '      sl = Math.fma(sh, sh, zt * -1.0) * (sh * iz)' '      sl = 0.0'
  mutate "atanh's 1 - |x| rounded" '    qh, ql = asinh_fast_two_sub(1.0, ax)' '    qh, ql = {1.0 - ax, 0.0}'
  mutate "atan's, asin's and acos's fast two-sum without its low part" '    {s, y - z}
  end

  private def self.invtrig_fastsum' '    {s, 0.0}
  end

  private def self.invtrig_fastsum'
  mutate "lgamma's and tgamma's fast two-sum without its low part" '    {s, y - z}
  end

  private def self.gamma_twosum' '    {s, 0.0}
  end

  private def self.gamma_twosum'
  mutate "sin's, cos's and tan's 128-bit product without its middle carry" '    hi = (xh &* yh) &+ lh.unsafe_shr(32_u64) &+ hl.unsafe_shr(32_u64) &+ mid.unsafe_shr(32_u64)' '    hi = (xh &* yh) &+ lh.unsafe_shr(32_u64) &+ hl.unsafe_shr(32_u64)'
  mutate "tan below 2 pi reduced without 1/(2 pi)'s low part" '      l = fma(-9.839338337591243e-18, x, l)
    else
      tt = TAN_T.to_unsafe' '      l = l * 1.0
    else
      tt = TAN_T.to_unsafe'
  mutate "cos below 2 pi reduced without 1/(2 pi)'s low part" '      l = fma(-9.839338337591243e-18, x, l)
      err1 = 4.554824318475813e-32 * h' '      l = l * 1.0
      err1 = 4.554824318475813e-32 * h'
  mutate "sin below 2^31 reduced without pi/2^14's low part" '    rl = k * -7.474650873702107e-21' '    rl = 0.0'
  mutate "j0 below 2 with its numerator a term short" '    r2 = r[3] + z * r[4]' '    r2 = r[3]'
  mutate "yn's recurrence adding where it subtracts" '        b = ((i &+ i).to_f64 / x) * b - a' '        b = ((i &+ i).to_f64 / x) * b + a'
  mutate "cbrt's residual without its cube's low part" '    y3l = fma(y, y2, y3 * -1.0) + y * y2l' '    y3l = 0.0'
  mutate "hypot's square without its low part" '    dx2 = fma(x, x, x2 * -1.0)' '    dx2 = 0.0'
  mutate "atan2's quotient without the divisor's low part" '    zl = rdh * (fma(dh, zh * -1.0, nh) + (nl - (nh * rdh) * dl))' '    zl = rdh * (fma(dh, zh * -1.0, nh) + nl)'
  mutate "atan2's slow product left unnormalised" '      rex = rex &- 1_i64' '      rex = rex &- 0_i64'
  # The software arm runs where the processor's instruction can be
  # refused: x86_64, whose proofs refuse it in the prelude. aarch64 always
  # fuses with its own instruction and never reaches `soft_fma`, so there
  # a break in it changes nothing - the proofs had read "caught" there only
  # while the oracle's files were compiled as source.
  case "$(uname -m)" in
    x86_64 | amd64 | AMD64)
      mutate "fma as a product and a sum" '      soft_fma(a, b, c)' '      a * b + c' '      fuses == 1' '      false'
      mutate "the software fma's fast path without its round to odd" '      if err != 0.0
        bits = IyiFloatText.bits_of(v)' '      if false
        bits = IyiFloatText.bits_of(v)' '      fuses == 1' '      false'
      mutate "fma's product not shifted to z's side" '          rhi = rhi.unsafe_shr(d.to_u64)' '          rhi = rhi &+ 0_u64' '      fuses == 1' '      false'
      mutate "a single's fma rounded twice" '        bits = bits | 1_u64' '        bits = bits &+ 0_u64' '      fuses == 1' '      false' ;;
    *)
      echo "  the software fma's four proofs: not run here, because $(uname -m) fuses with its own instruction and never runs the software arm" ;;
  esac
  # And the instruction with its operands in the wrong order, b * c + a,
  # where the instruction is what runs.
  if [ "$(uname -s) $(uname -m)" = "Linux x86_64" ] && grep -qw fma /proc/cpuinfo; then
    mutate "vfmadd with its operands in the wrong order" '' '' 'vfmadd213sd $3, $2, $0' 'vfmadd231sd $3, $2, $0'
  else
    echo "  vfmadd with its operands in the wrong order: not proven here, because this is not an x86_64 Linux with FMA3"
  fi
else
  echo "  the fma proofs: not run, no python3 to write the cases with"
fi
mutate "exp's overflow scale a power off" 'return 5.486124068793689e+303 * (scale + scale * tmp)' 'return 2.7430620343968443e+303 * (scale + scale * tmp)'
mutate "atan2 blind to the sign of zero" '        return y if ix == 0_u64' '        return y'
mutate "isqrt without halving its root" '        res = (res >> 1) + bit' '        res = res + bit'
mutate "ilogb one past the exponent" '    frexp(value)[1] - 1' '    frexp(value)[1]'
mutate "erf of a single answered as a double" '  def self.erf(value : Float32) : Float32
    erf(value.to_f64).to_f32' '  def self.erf(value : Float32) : Float64
    erf(value.to_f64)'
mutate "gcd on the positive side" 'x = signed && a > 0 ? zero - a : a' 'x = a.abs'
mutate "gcd of an unsigned pair on the negative side" 'signed = zero &- 1 < zero' 'signed = true'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/math exercise holds"
else
  echo "the std/math exercise did not hold"
fi
exit $status
