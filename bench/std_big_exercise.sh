#!/usr/bin/env bash
# Exercises `std/big`: BigInt, BigDecimal and BigRational.
#
#     bash bench/std_big_exercise.sh
#
# Runs bench/std_big_exercise.iyi plain and with --release, requires every
# section to report, checks the arithmetic the program printed against
# python3 (`decimal` for BigDecimal, `fractions.Fraction` for BigRational,
# `int(digits, base)` for every base 2..36, `pow(b, e, m)` for 3000 modular
# exponentiations), sets the release build's 2048-, 3072- and 4096-bit
# `pow_mod` times beside python's and the square-and-multiply it replaced,
# proves that what the module refuses is refused with the prelude's sentence
# (`division by zero`, `modulo by zero`, `not a decimal: "12x"`), reads the
# module with `iyi doc`, checks the formatting, typechecks the exercise for
# five targets, builds it again from `--emit-iyimod` artifacts, and proves
# the checks can fail by patching copies of std/big.iyi through IYI_PATH.
#
# A check that cannot fail is not a check. This script breaks addition,
# multiplication, negation, the modulo sign rule, bitwise and, exponentiation,
# abs, the constant one, BigInt hashing, BigDecimal hash normalisation,
# division rounding, exact-division detection, zero printing, rational
# reduction, the unbalanced Karatsuba split, the split that prints and
# parses long values and the recursive division a long print splits by,
# Montgomery's n', its final subtraction, both window tables, the even
# modulus' exponent bits and the correction of a one-limb quotient, and
# requires each break to be caught at a named check.
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

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_big_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  grep -v '^oracle \|^powmod: \|^powtime: ' "$WORK/$name.out" | sed 's/^/  /'
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the big number exercise, plain build"
run_case "plain" big-plain
if ! grep -q "all std/big checks passed" "$WORK/big-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every big number section reported"
for phrase in "construction and conversions:" "predicates and comparisons:" "basic arithmetic:" "division corner cases:" "bitwise operations:" "known large values:" "round trips:" "modular exponentiation:" "algebraic identities:" "karatsuba:" "hashing:" "decimal arithmetic:" "rational arithmetic:" "base round trips:" "long print:" "binary floats:"; do
  if ! grep -q "$phrase" "$WORK/big-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  construction, predicates, arithmetic, division, bitwise, known values, roundtrips, pow_mod, identities, karatsuba, hashing, decimals, rationals, bases and long prints all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" big-release --release
if ! grep -q "all std/big checks passed" "$WORK/big-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi
if ! diff <(grep '^oracle \|^powmod: ' "$WORK/big-plain.out") <(grep '^oracle \|^powmod: ' "$WORK/big-release.out") >/dev/null 2>&1; then
  echo "  release build printed different oracle lines than the plain build"
  status=1
fi

# ---------------------------------------------------------------------------
# The oracle: every `oracle ...` line the program printed, recomputed in python3
# ---------------------------------------------------------------------------
#   oracle dec:  A op B = R    op in + - * / // %   BigDecimal, checked with
#                              decimal + fractions (exact + - * // %; / rounded
#                              half away from zero to 20 places, an exact
#                              quotient with its trailing zeros dropped)
#   oracle cmp:  A <=> B = R   BigDecimal three-way comparison
#   oracle rat:  A op B = R    op in + - * / ** <=>  BigRational, fractions.Fraction
#   oracle base: N digits = V  BigInt#to_s(N), checked with int(digits, N)

echo
echo "== decimal, rational and base arithmetic against python3"
cat > "$WORK/oracle.py" << 'EOF'
import sys
from decimal import Decimal
from fractions import Fraction

# The base lines carry values of thousands of digits, past the 4,300 that
# python 3.11 converts by default.
if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)

def fmt(n, scale):
    # std/big's BigDecimal#to_s: zero is "0"; a negative scale is multiplied out.
    if n == 0:
        return "0"
    if scale < 0:
        n, scale = n * 10 ** (-scale), 0
    sign, s = ("-" if n < 0 else ""), str(abs(n))
    if scale == 0:
        return sign + s
    s = s.rjust(scale + 1, "0")
    return sign + s[:-scale] + "." + s[-scale:]

def scaled(q, scale):
    n = q * Fraction(10) ** scale
    assert n.denominator == 1, (q, scale)
    return fmt(n.numerator, scale)

def dec(a, op, b):
    A, B = Fraction(Decimal(a)), Fraction(Decimal(b))
    sa, sb = -Decimal(a).as_tuple().exponent, -Decimal(b).as_tuple().exponent
    if op == "+": return scaled(A + B, max(sa, sb))
    if op == "-": return scaled(A - B, max(sa, sb))
    if op == "*": return scaled(A * B, sa + sb)
    if op == "//": return fmt(int(A / B), 0)
    if op == "%": return scaled(A - int(A / B) * B, max(sa, sb))
    if op == "/":
        n20 = (A / B) * 10 ** 20
        if n20.denominator == 1:
            n, scale = n20.numerator, 20
            while scale > 0 and n % 10 == 0:
                n, scale = n // 10, scale - 1
            return fmt(n, scale)
        n = int(abs(n20) + Fraction(1, 2))  # half away from zero
        return fmt(-n if n20 < 0 else n, 20)
    raise ValueError(op)

def frac(s):
    n, _, d = s.partition("/")
    return Fraction(int(n), int(d or 1))

def rat(a, op, b):
    A = frac(a)
    if op == "**": return str(A ** int(b))
    B = frac(b)
    if op == "<=>": return str((A > B) - (A < B))
    if op == "/": return str(A / B)
    return str({"+": A + B, "-": A - B, "*": A * B}[op])

import math

# BigFloat: a value rounded to p bits, ties to even, from its exact value.
def round_bits(x, p):
    if x == 0:
        return Fraction(0)
    sign, a = (-1 if x < 0 else 1), abs(x)
    n, d = a.numerator, a.denominator
    k = n.bit_length() - d.bit_length() - p
    while True:
        num, den = n << max(-k, 0), d << max(k, 0)
        q, r = divmod(num, den)
        if q.bit_length() > p:
            k += 1
            continue
        if q.bit_length() < p:
            k -= 1
            continue
        if 2 * r > den or (2 * r == den and q % 2):
            q += 1
        if q.bit_length() > p:
            q >>= 1
            k += 1
        return sign * Fraction(q) * Fraction(2) ** k

# The square root rounded to p bits, from integer square roots: y below is
# the root's square in units of its last place.
def sqrt_bits(x, p):
    if x == 0:
        return Fraction(0)
    k = (x.numerator.bit_length() - x.denominator.bit_length()) // 2 - p
    while True:
        y = x / Fraction(4) ** k
        q = math.isqrt(y.numerator // y.denominator)
        if q.bit_length() > p:
            k += 1
            continue
        if q.bit_length() < p:
            k -= 1
            continue
        half = Fraction(2 * q + 1, 2) ** 2
        if y > half or (y == half and q % 2):
            q += 1
        if q.bit_length() > p:
            q >>= 1
            k += 1
        return Fraction(q) * Fraction(2) ** k

# BigFloat#to_s's layout: positional for a leading digit from 10^-4 to
# 10^14, an exponent outside.
def place(digits, point):
    if -4 <= point < 15:
        if point >= 0:
            whole = point + 1
            if len(digits) <= whole:
                return digits + "0" * (whole - len(digits)) + ".0"
            return digits[:whole] + "." + digits[whole:]
        return "0." + "0" * (-1 - point) + digits
    return digits[0] + "." + (digits[1:] or "0") + "e" + ("-" if point < 0 else "+") + str(abs(point))

# The fewest significant digits that read back at p bits, found by trying
# one, two, three ... the nearest of each, ties to even.
def shortest(v, p):
    if v == 0:
        return "0.0"
    a = abs(v)
    lead = len(str(a.numerator)) - len(str(a.denominator))
    while Fraction(10) ** lead > a:
        lead -= 1
    while Fraction(10) ** (lead + 1) <= a:
        lead += 1
    n = 1
    while True:
        last = lead - n + 1
        t = a / Fraction(10) ** last
        q = t.numerator // t.denominator
        rest = t - q
        if rest > Fraction(1, 2) or (rest == Fraction(1, 2) and q % 2):
            q += 1
        if round_bits(Fraction(q) * Fraction(10) ** last, p) == a:
            break
        n += 1
    digits = str(q).rstrip("0") or "0"
    return ("-" if v < 0 else "") + place(digits, last + len(str(q)) - 1)

def flt(lhs, got):
    p, op, a, b = lhs.split(" ")
    p = int(p)
    if op == "parse":
        return frac(got) == round_bits(Fraction(Decimal(a)), p), "the rounded decimal"
    A = frac(a)
    if op == "str":
        want = shortest(A, p)
        return got == want, want
    if op == "f64":
        return float(got) == float(A), repr(float(A))
    if op == "sqrt":
        want = sqrt_bits(A, p)
    elif op in ("round", "floor", "ceil", "trunc"):
        whole = {"round": round(A), "floor": math.floor(A), "ceil": math.ceil(A), "trunc": int(A)}[op]
        want = round_bits(Fraction(whole), p)
    elif op == "pow":
        want = round_bits(A ** int(b), p)
    else:
        B = frac(b)
        want = round_bits({"add": A + B, "sub": A - B, "mul": A * B, "div": A / B if B else None}[op], p)
    return frac(got) == want, str(want)

counts = {"dec": 0, "cmp": 0, "rat": 0, "base": 0, "flt": 0}
bad = 0
for line in sys.stdin:
    if not line.startswith("oracle "):
        continue
    kind, rest = line[7:].split(": ", 1)
    lhs, got = rest.rstrip("\n").split(" = ")
    if kind == "flt":
        counts[kind] += 1
        held, want = flt(lhs, got)
        if not held:
            bad += 1
            print(f"  oracle disagrees: flt {lhs[:160]}: std/big said {got[:160]}, python said {want[:160]}")
        continue
    if kind == "base":
        base, digits = lhs.split(" ")
        want = str(int(digits, int(base)))
    else:
        a, op, b = lhs.split(" ")
        if kind == "dec":
            want = dec(a, op, b)
        elif kind == "cmp":
            A, B = Fraction(Decimal(a)), Fraction(Decimal(b))
            want = str((A > B) - (A < B))
        else:
            want = rat(a, op, b)
    counts[kind] += 1
    if want != got:
        bad += 1
        print(f"  oracle disagrees: {kind} {lhs}: std/big said {got}, python said {want}")
print(f"  oracle lines checked: {counts}")
floor = {"dec": 100, "cmp": 20, "rat": 60, "base": 70, "flt": 4000}
for kind, need in floor.items():
    if counts[kind] < need:
        bad += 1
        print(f"  too few {kind} oracle lines: {counts[kind]} < {need}")
sys.exit(1 if bad else 0)
EOF
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the arithmetic oracle is unmeasured"
elif [ -f "$WORK/big-plain.out" ]; then
  if ! "$PY" "$WORK/oracle.py" < "$WORK/big-plain.out"; then
    echo "  python3 disagrees with std/big"
    status=1
  fi
else
  echo "  no program output to check"
  status=1
fi
# The oracle itself has to be able to disagree.
if [ -z "$PY" ]; then
  echo "  and with no interpreter the oracle's own failure mode is unmeasured too"
elif sed 's|^oracle dec: 2 / 3 = 0.66666666666666666667$|oracle dec: 2 / 3 = 0.66666666666666666666|' "$WORK/big-plain.out" \
     | "$PY" "$WORK/oracle.py" >"$WORK/oracle-broken.out" 2>&1; then
  echo "  the oracle accepted a wrong quotient, so it checks nothing"
  status=1
else
  echo "  the oracle rejects a quotient one unit off in the last place"
fi
# And a binary float one unit off in its last place: the first product
# that is not zero, moved by one place of its precision.
if [ -n "$PY" ]; then
  if "$PY" - "$WORK/big-plain.out" >"$WORK/flt-broken.out" 2>&1 <<'PY'
import sys
from fractions import Fraction
lines = open(sys.argv[1]).read().splitlines()
for i, line in enumerate(lines):
    if line.startswith("oracle flt: ") and " mul " in line and not line.endswith(" = 0"):
        lhs, got = line.rsplit(" = ", 1)
        n, _, d = got.partition("/")
        value = Fraction(int(n), int(d or 1))
        p = int(lhs.split(" ")[2])
        k = abs(value).numerator.bit_length() - abs(value).denominator.bit_length() - p
        lines[i] = lhs + " = " + str(value + Fraction(2) ** k)
        break
print("\n".join(lines))
PY
  then
    if "$PY" "$WORK/oracle.py" <"$WORK/flt-broken.out" >"$WORK/oracle-flt-broken.out" 2>&1; then
      echo "  the oracle accepted a product one place off, so it checks no binary float"
      status=1
    else
      echo "  the oracle rejects a binary float product one place off"
    fi
  else
    echo "  the broken binary float line could not be made"
    status=1
  fi
fi

echo
echo "== modular exponentiation against python's pow"
# Every `powmod: b e m = r` line (hex) recomputed with pow(b, e, m), with a
# floor on how many of each kind of case there were; then the release
# build's `powtime: bits b e m = r pow_mod pow_mod_secret before` lines
# (microseconds) checked the same way and timed against python's own pow
# on the same operands, best of three.
cat > "$WORK/pow.py" << 'EOF'
import sys, time
if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)
bad = 0
seen = {"cases": 0, "odd moduli": 0, "even moduli": 0, "over 2048 bits": 0, "exponent 0": 0,
        "exponent 1": 0, "exponents over 2048 bits": 0, "base 0": 0, "base past the modulus": 0,
        "negative base": 0, "modulus 1": 0}
timed = []
for line in open(sys.argv[1]):
    kind, _, rest = line.rstrip("\n").partition(": ")
    if kind not in ("powmod", "powtime"):
        continue
    lhs, got = rest.split(" = ")
    words = lhs.split(" ")
    if kind == "powtime":
        bits, words = int(words[0]), words[1:]
        got, *micros = got.split(" ")
    b, e, m = (int(w, 16) for w in words)
    want = format(pow(b, e, m), "x")
    if got != want:
        bad += 1
        print(f"  python disagrees: pow({lhs[:60]}...) is {want[:40]}, std/big said {got[:40]}")
    if kind == "powtime":
        runs = []
        for _ in range(3):
            started = time.perf_counter()
            pow(b, e, m)
            runs.append(time.perf_counter() - started)
        timed.append((bits, [int(x) for x in micros], min(runs) * 1e6))
        continue
    seen["cases"] += 1
    seen["odd moduli" if m % 2 else "even moduli"] += 1
    seen["over 2048 bits"] += m.bit_length() > 2048
    seen["exponent 0"] += e == 0
    seen["exponent 1"] += e == 1
    seen["exponents over 2048 bits"] += e.bit_length() > 2048
    seen["base 0"] += b == 0
    seen["base past the modulus"] += b >= m
    seen["negative base"] += b < 0
    seen["modulus 1"] += m == 1
floor = {"cases": 3000, "odd moduli": 2000, "even moduli": 600, "over 2048 bits": 60, "exponent 0": 40,
         "exponent 1": 40, "exponents over 2048 bits": 60, "base 0": 50, "base past the modulus": 50,
         "negative base": 200, "modulus 1": 1}
print("  " + ", ".join(f"{v} {k}" for k, v in seen.items()))
for k, need in floor.items():
    if seen[k] < need:
        bad += 1
        print(f"  too few cases of {k}: {seen[k]} < {need}")
for bits, (fast, secret, before), python in timed:
    print(f"  {bits} bits: pow_mod {fast / 1000:.1f} ms, pow_mod_secret {secret / 1000:.1f} ms,"
          f" square-and-multiply {before / 1000:.1f} ms, python's pow {python / 1000:.1f} ms")
    if len(sys.argv) > 2 and fast >= python:
        bad += 1
        print(f"  pow_mod at {bits} bits is not faster than python's pow")
sys.exit(1 if bad else 0)
EOF
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so pow_mod's oracle is unmeasured"
else
  if [ -f "$WORK/big-plain.out" ] && "$PY" "$WORK/pow.py" "$WORK/big-plain.out" >"$WORK/pow-plain.verdict" 2>&1; then
    sed -n '1p' "$WORK/pow-plain.verdict"
    echo "  python's pow agrees with every case of the plain build"
  else
    sed -n '1,6p' "$WORK/pow-plain.verdict" 2>/dev/null
    echo "  python's pow disagrees with the plain build"
    status=1
  fi
  if [ -f "$WORK/big-release.out" ] && "$PY" "$WORK/pow.py" "$WORK/big-release.out" timed >"$WORK/pow-release.verdict" 2>&1; then
    sed -n '2,$p' "$WORK/pow-release.verdict"
    echo "  and with the release build's, which is faster than python's pow at every size"
  else
    sed -n '1,8p' "$WORK/pow-release.verdict" 2>/dev/null
    echo "  python's pow disagrees with the release build, or is faster than it"
    status=1
  fi
  # The pow oracle has to be able to disagree too: one result one hex digit
  # longer.
  awk '!done && /^powmod: / { $0 = $0 "1"; done = 1 } { print }' "$WORK/big-plain.out" >"$WORK/pow-broken.out"
  if "$PY" "$WORK/pow.py" "$WORK/pow-broken.out" >"$WORK/pow-broken.verdict" 2>&1; then
    echo "  the pow oracle accepted a wrong result, so it checks nothing"
    status=1
  else
    echo "  the pow oracle rejects one result off by a digit"
  fi
fi

# ---------------------------------------------------------------------------
# What the module refuses, and the sentence it refuses with
# ---------------------------------------------------------------------------

echo
echo "== what std/big refuses"
big_panics_with() { # big_panics_with <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/big::{BigInt, BigDecimal, BigRational}\n\nputs (%s).to_s\n' "$expression" > "$WORK/$name.iyi"
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
big_panics_with "integer division by zero" div_zero "division by zero" '42.to_big // 0.to_big'
big_panics_with "integer modulo by zero" mod_zero "modulo by zero" '42.to_big % 0.to_big'
big_panics_with "decimal division by zero" dec_div_zero "division by zero" 'BigDecimal.new("1.5") / BigDecimal.new("0.0")'
big_panics_with "decimal modulo by zero" dec_mod_zero "modulo by zero" 'BigDecimal.new("1.5") % BigDecimal.new("0")'
big_panics_with "a negative division precision" dec_neg_prec "negative precision: -1" 'BigDecimal.new("1").div(BigDecimal.new("3"), -1)'
big_panics_with "a rational with denominator zero" rat_zero "division by zero" 'BigRational.new(1, 0)'
big_panics_with "the inverse of zero" rat_inv_zero "division by zero" 'BigRational.zero.inv'
big_panics_with "a decimal with letters" dec_letters 'not a decimal: "12x"' 'BigDecimal.new("12x")'
big_panics_with "a decimal with two points" dec_points 'not a decimal: "1.2.3"' 'BigDecimal.new("1.2.3")'
big_panics_with "an exponent with no digits" dec_exp 'not a decimal: "1e"' 'BigDecimal.new("1e")'
big_panics_with "an empty decimal" dec_empty 'not a decimal: ""' 'BigDecimal.new("")'
big_panics_with "a digit the base does not have" bad_digit "invalid BigInt digit: 9 for base 8" 'BigInt.new("79", 8)'
big_panics_with "a base past 36" bad_base "invalid base: 37 (must be 2..36)" 'BigInt.new("1").to_s(37)'
big_panics_with "a negative exponent" neg_exp "negative exponent: -1" '2.to_big ** -1'
big_panics_with "a value too wide for Int64" i64_overflow "does not fit in Int64" 'BigInt.new("18446744073709551615").to_i64'
big_panics_with "a string of underscores" no_digits 'invalid BigInt: no digits in "_"' 'BigInt.new("_")'
big_panics_with "a sign and underscores" sign_no_digits 'invalid BigInt: no digits in "-_"' 'BigInt.new("-_")'
big_panics_with "a decimal exponent past Int32" dec_exp_range 'decimal exponent out of range: "1e99999999999"' 'BigDecimal.new("1e99999999999")'
big_panics_with "pow_mod modulo zero" pow_zero "modulo by zero" '3.to_big.pow_mod(5.to_big, 0.to_big)'
big_panics_with "pow_mod modulo a negative" pow_neg_mod "modulus must be positive" '3.to_big.pow_mod(5.to_big, -(7.to_big))'
big_panics_with "pow_mod with a negative exponent" pow_neg_exp "negative exponent in pow_mod: -1" '3.to_big.pow_mod(-(1.to_big), 7.to_big)'
big_panics_with "pow_mod_secret modulo an even number" pow_secret_even "pow_mod_secret needs an odd modulus, not 10" '3.to_big.pow_mod_secret(5.to_big, 10.to_big)'
big_panics_with "pow_mod_secret with a negative exponent" pow_secret_neg "negative exponent in pow_mod_secret: -2" '3.to_big.pow_mod_secret(-(2.to_big), 7.to_big)'

# ---------------------------------------------------------------------------
# Negative proofs: each check is proven to fail when its mechanism is broken
# ---------------------------------------------------------------------------

echo
echo "== proving the checks can fail when big number operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/big.iyi" > "$WORK/$dir/std/big.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/big.iyi" "$WORK/$dir/std/big.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_big_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched big library did not build"
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
    echo "  $label: failed, but not at expected check (expected '$phrase')"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

# 1. Addition carry broken (dropped carry addition)
prove_fails "addition carry dropped" no_add_carry "known: fib(100)" \
  's/sum = x\[i\] \&+ y\[i\] \&+ carry/sum = x[i] \&+ y[i]/'

# 2. Multiplication broken (returns zero for limbs)
prove_fails "multiplication broken" no_mul "arith: mul" \
  's/r\[i + j\] = prod \& 0xFFFFFFFF_u64/r[i + j] = 0_u64/'

# Bytes read little-endian, and a value too wide for its width cut short
prove_fails "bytes read in the wrong order" bytes_order "bytes: from_bytes" \
  's/bytes\[n - 1 - i\]\.to_u64 << /bytes[i].to_u64 << /'
prove_fails "a value cut to its width" bytes_cut "bytes: too wide refused" \
  's/          return nil unless byte == 0_u8/          next_byte = byte/'

# 3. Negation broken (identity instead of negate)
prove_fails "negate broken" no_negate "negate: positive" \
  's/BigInt\.new(-@sign, @limbs\.dup)/self/'

# 4. Divisor larger than dividend sign rule broken
prove_fails "modulo sign rule broken" no_mod_sign "div: quadrant identity" \
  's/r_sign = @sign/r_sign = other.sign/'

# 5. Bitwise AND broken
prove_fails "bitwise and broken" no_bit_and "bit: and" \
  's/res << (@limbs\[i\] & other\.limbs\[i\])/res << 0_u64/'

# 6. Exponentiation broken
prove_fails "exponentiation broken" no_pow "pow: one exp" \
  's/res = res \* base if (e & 1_i64) == 1_i64/res = BigInt.zero/'

# 7. Abs broken
prove_fails "abs broken" no_abs "abs: negative" \
  's/@sign < 0 [?] BigInt\.new(1, @limbs\.dup) : self/self/'

# 8. Factory one broken
prove_fails "constant one broken" no_one "construct: one" \
  's/arr << 1_u64/arr << 2_u64/'

# 9. BigInt hash ignores the limbs (every magnitude hashes alike)
prove_fails "bigint hash ignores limbs" no_hash_limbs "hash: neighbour differs" \
  's/h = (h ^ @limbs\[i\]) &\* 1099511628211_u64/h = h ^ 0_u64/'

# 10. BigInt hash ignores the sign
prove_fails "bigint hash ignores sign" no_hash_sign "hash: negative differs" \
  's/h = (h ^ (@sign + 1)\.to_u64) &\* 1099511628211_u64/h = h ^ 0_u64/'

# 11. BigDecimal hash keeps the trailing zeros, so 1.10 and 1.1 (or 1e1000000
# and 1 followed by a million zeros) differ as keys
prove_fails "decimal hash skips normalisation" no_dec_norm "hash: decimal scale agreement" \
  's/stripped = strip_zeros(2147483647)/stripped = {@value, 0}/'

# 12. Division truncates instead of rounding
prove_fails "decimal division truncates" no_dec_round "decimal: div rounds half away" \
  's/if ((r\.abs \* 2) <=> den\.abs) >= 0/if ((r.abs * 2) <=> den.abs) > 2/'

# 13. Exact quotients keep their trailing zeros
prove_fails "exact division not detected" no_dec_exact "decimal: exact division is short" \
  's/return BigDecimal\.new(q, precision)\.normalized if r\.zero?/return BigDecimal.new(q, precision) if r.zero?/'

# 14. Zero prints with a fraction
prove_fails "decimal zero prints 0.0" no_dec_zero "decimal: zero prints 0" \
  's/return "0" if @value\.zero?/return "0.0" if @value.zero?/'

# 15. Rationals stay unreduced
prove_fails "rational not reduced" no_rat_reduce "hash: rational reduced" \
  's|@numerator = numerator // g|@numerator = numerator|'

# 16. Base conversion drops the sign
prove_fails "base conversion drops sign" no_base_sign "rational: round trip" \
  's/negative = @sign < 0$/negative = false/'

# 17. A Karatsuba split that takes k limbs off a side shorter than k
prove_fails "karatsuba splits a short side" no_unbalanced "negative capacity" \
  's/if a.size < k || b.size < k$/if false/'

# 18. A split print whose low half loses its leading zeros
prove_fails "split print drops inner zeros" no_pad "base: long round trip" \
  's/while sink.size < start + width$/while false/'

# 19. A split parse that forgets what the low half's digits stand for
prove_fails "split parse adds the halves" no_join "base: long round trip" \
  's/return high \* powers\[level\] + /return high + /'

# 20. Printing that copies the value per chunk of digits, as appending each
#     chunk to the text so far did
prove_fails "printing copies per chunk" no_print_split "base: printing 7 costs its digits" \
  's/if level >= 0 \&\& @limbs.size >= DIGITS_SPLIT_LIMBS$/if false/;s/^      while size > 0 \&\& w\[size - 1\] == 0_u64$/      while size > 0 \&\& w[size - 1] == 0_u64 + @limbs.dup.size.to_u64 * 0_u64/'

# 21. Parsing that copies the value per chunk of digits, as a new BigInt
#     per digit did
prove_fails "parsing copies per chunk" no_parse_split "base: parsing 7 costs its digits" \
  's/if count > per \* DIGITS_SPLIT_LIMBS$/if false/;s/^      carry = value$/      carry = value + limbs.dup.size.to_u64 * 0_u64/'

# 22. Printing that splits by long division, quadratic in the length.
#     `divmod_long`, not `divmod`: `divmod` itself takes the recursion
#     for a divisor this long now.
prove_fails "printing splits by long division" no_print_recursive "base: printing a long value costs what parsing it does" \
  's/halves = divmod_recursive(powers\[level\])$/halves = divmod_long(powers[level])/'

# 23. A long division's remainder without the dividend's sign, and 24.
#     long division for every divisor, as `//`, `%` and `divmod` had.
prove_fails "a long division's remainder unsigned" no_div_sign "div: long" \
  's/@sign < 0 ? r.negate : r}$/r}/'
prove_fails "long division for a long divisor" no_div_recursive "div: a long division took" \
  's/if divisor_bits > DIVIDE_RECURSIVE_BITS \&\& /if false \&\& /'

# A rational's float through twenty decimal places again, and its
# halfway rounded up rather than to even.
prove_fails "rational to_f64 through BigDecimal" no_rat_f64 "rational: to_f64 tiny" \
  's/^    return 0.0 if zero?$/    return to_big_d.to_f64/'
prove_fails "rational to_f64 ties away from even" no_rat_even "rational: to_f64 subnormal ties to even" \
  's/^    q = q + half if (q \& half) != 0_i64 \&\& (q \& (3_i64 \* half - 1_i64)) != 0_i64$/    q = q + half if (q \& half) != 0_i64/'

# BigFloat's rounding, each taken out of a copy that compiles: four the
# exercise's own checks stop at, and one only the exact oracle can see,
# which must then reject the copy's binary float lines of that operation.
prove_fails "binary float ties rounded away from even" no_flt_even "flt: ties to even" \
  's/q = q + BigInt.one if twice > 0 || (twice == 0 \&\& q.odd?)/q = q + BigInt.one if twice >= 0/'
prove_fails "a binary float addend dropped too soon" no_flt_sum "flt: an addend under the last place" \
  's/gap > precision.to_i64 + 2_i64/gap > 2_i64/'
prove_fails "a binary float rounded to an integer away from even" no_flt_round "flt: round, floor, ceil" \
  's/whole = whole + BigInt.one if against > 0 || (against == 0 \&\& whole.odd?)/whole = whole + BigInt.one if against >= 0/'
oracle_fails() { # oracle_fails <label> <dir> <op> <sed script>
  local label="$1" dir="$2" op="$3" sed_script="$4"
  if [ -z "$PY" ]; then
    echo "  $label: no python3 to judge the copy with, unmeasured"
    return
  fi
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/big.iyi" > "$WORK/$dir/std/big.iyi"
  if cmp -s "$REPO/src/std/big.iyi" "$WORK/$dir/std/big.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -o "$WORK/$dir/program" "$REPO/bench/std_big_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched big library did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  if "$PY" "$WORK/oracle.py" <"$WORK/$dir/out" >"$WORK/$dir/verdict" 2>&1; then
    echo "  $label: the oracle passed the copy, so it does not test this"
    status=1
  elif ! grep -q "oracle disagrees: flt [0-9]* $op " "$WORK/$dir/verdict"; then
    echo "  $label: the oracle failed the copy, but not on $op"
    sed -n '1,3p' "$WORK/$dir/verdict"
    status=1
  else
    echo "  $label: the oracle rejects $(grep -c "oracle disagrees: flt [0-9]* $op " "$WORK/$dir/verdict") $op lines"
  fi
}
oracle_fails "a square root without its sticky bit" no_flt_sticky sqrt \
  's/sticky = root \* root == square ? BigInt.zero : BigInt.one/sticky = BigInt.zero/'
# Digits past the fewest that read back: the 256-bit root of two is
# written longer than its known 77 digits.
prove_fails "a decimal longer than it needs" no_flt_shortest "flt: the square root of two to 256 bits" \
  's/^        high = middle$/        low = middle + 1/'

# Montgomery: n' right to 48 bits of 64 (four Newton steps, not five);
# a product's final subtraction dropped, its t copied out whatever it is;
# the sliding window's table one power of g apart where it should be two
# (g^(i+1) where g^(2i+1) belongs); the fixed window's lookup one entry
# low; and an even modulus reading its exponent's bits sixteen to a limb.
prove_fails "montgomery n' right to 48 bits" no_mont_inverse "pow_mod: short exponents modulo a modulus with room in its top word" \
  's/^    5.times { x = x \&\* (2_u64 \&- m0 \&\* x) }$/    4.times { x = x \&* (2_u64 \&- m0 \&* x) }/'
prove_fails "a product's final subtraction dropped" no_mont_subtract "pow_mod: short exponents modulo a modulus that fills its top word" \
  's/^    reduce(t, t\[n\], r)$/    n.times { |j| r[j] = t[j] }/'
prove_fails "the sliding window's table one power apart" no_mont_table "exponent through the window table" \
  's/mul(tp + ((i - 1) \* n).to_i64, g2.to_unsafe, tp + (i \* n).to_i64)/mul(tp + ((i - 1) * n).to_i64, tp, tp + (i * n).to_i64)/'
prove_fails "the fixed window's lookup one entry low" no_fixed_lookup "pow_mod_secret: agrees with pow_mod" \
  's/^        d = e.to_u64 ^ value$/        d = (e + 1).to_u64 ^ value/'
prove_fails "an even modulus' exponent read sixteen bits a limb" no_even_bits "pow_mod: an even modulus" \
  's/exp.limbs\[i >> 5\].unsafe_shr((i \& 31).to_u64)/exp.limbs[i >> 5].unsafe_shr((i \& 15).to_u64)/'

# A one-limb quotient left at its estimate, which can be up to three
# short: the divisor no longer taken off what is left.
prove_fails "a one-limb quotient left at its estimate" no_one_limb_fix "div: a one-limb quotient" \
  's/^    while BigInt.limbs_at_least(r, n, v, m)$/    while false \&\& BigInt.limbs_at_least(r, n, v, m)/'

echo
echo "== documentation, formatting and the five targets"
if "$IYI" doc "$REPO/src/std/big.iyi" >"$WORK/doc.out" 2>&1 && grep -q "pow_mod_secret" "$WORK/doc.out"; then
  echo "  iyi doc reads std/big, pow_mod_secret included"
else
  echo "  FAIL: iyi doc: $(tail -2 "$WORK/doc.out")"
  status=1
fi
if [ -x "$REPO/bin/crystal" ]; then
  if "$REPO/bin/crystal" tool format --check "$REPO/src/std/big.iyi" "$REPO/bench/std_big_exercise.iyi" >"$WORK/format.out" 2>&1; then
    echo "  the module and the exercise are formatted"
  else
    echo "  FAIL: not formatted: $(head -3 "$WORK/format.out")"
    status=1
  fi
fi
crossed=0
for target in x86_64-linux-gnu aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  if ! "$IYI" build --no-codegen --target "$target" "$REPO/bench/std_big_exercise.iyi" -o "$WORK/cross" >"$WORK/cross.log" 2>&1; then
    echo "  FAIL: the exercise does not typecheck for $target: $(grep -m1 Error "$WORK/cross.log")"
    status=1
    crossed=1
  fi
done
[ "$crossed" -eq 0 ] && echo "  the exercise typechecks for x86_64-linux-gnu, aarch64-darwin, x86_64-windows-msvc, aarch64-linux-gnu and x86_64-linux-musl"

echo
echo "== the same answers from artifacts"
# Built once with --emit-iyimod and again from those artifacts: a method
# whose body the artifact keeps as text must read back as it was written.
# The timing lines are left out of the comparison, being times.
mkdir -p "$WORK/art"
if ! (cd "$WORK/art" && "$IYI" build --emit-iyimod mods -o from-source "$REPO/bench/std_big_exercise.iyi") >"$WORK/art.log" 2>&1; then
  echo "  FAIL: the build that writes the artifacts: $(tail -2 "$WORK/art.log")"
  status=1
elif ! (cd "$WORK/art" && "$IYI" build --use-iyimod mods -o from-artifact "$REPO/bench/std_big_exercise.iyi") >"$WORK/art.log" 2>&1; then
  echo "  FAIL: the build from the artifacts: $(grep -m1 -A2 'In mods' "$WORK/art.log" | tr '\n' ' ')"
  status=1
else
  "$WORK/art/from-source" 2>&1 | grep -v '^powtime: ' >"$WORK/art/source.out"
  "$WORK/art/from-artifact" 2>&1 | grep -v '^powtime: ' >"$WORK/art/artifact.out"
  if cmp -s "$WORK/art/source.out" "$WORK/art/artifact.out" && grep -q "ALL CHECKS PASSED" "$WORK/art/artifact.out"; then
    echo "  built from artifacts, the exercise prints what it prints from source"
  else
    echo "  FAIL: from artifacts the exercise printed otherwise: $(diff "$WORK/art/source.out" "$WORK/art/artifact.out" | sed -n '1,3p' | tr '\n' ' ')"
    status=1
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "Big number standard library: BigInt construction, predicates, arithmetic, division,"
  echo "bitwise logic, known large values, round trips, pow_mod and pow_mod_secret against"
  echo "python's pow, random identities and Karatsuba, BigDecimal and BigRational arithmetic"
  echo "checked against python3, hashes that agree with ==, every base 2..36, all pass plain"
  echo "and optimised; what the module refuses is refused with a sentence, and each check is"
  echo "proven to fail when its mechanism is broken."
  echo "ALL CHECKS PASSED"
else
  echo "std/big exercise driver: failures encountered"
fi
exit "$status"
