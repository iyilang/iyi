#!/usr/bin/env bash
# Exercises `std/big`: BigInt, BigDecimal and BigRational.
#
#     bash bench/std_big_exercise.sh
#
# Runs bench/std_big_exercise.iyi plain and with --release, requires every
# section to report, checks the arithmetic the program printed against
# python3 (`decimal` for BigDecimal, `fractions.Fraction` for BigRational,
# `int(digits, base)` for every base 2..36), proves that what the module
# refuses is refused with the prelude's sentence (`division by zero`,
# `modulo by zero`, `not a decimal: "12x"`), and proves the checks can fail by
# patching copies of std/big.iyi through IYI_PATH.
#
# A check that cannot fail is not a check. This script breaks addition,
# multiplication, negation, the modulo sign rule, bitwise and, exponentiation,
# abs, the constant one, BigInt hashing, BigDecimal hash normalisation,
# division rounding, exact-division detection, zero printing and rational
# reduction, and requires each break to be caught at a named check.
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
  grep -v '^oracle ' "$WORK/$name.out" | sed 's/^/  /'
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
for phrase in "construction and conversions:" "predicates and comparisons:" "basic arithmetic:" "division corner cases:" "bitwise operations:" "known large values:" "round trips:" "modular exponentiation:" "algebraic identities:" "karatsuba:" "hashing:" "decimal arithmetic:" "rational arithmetic:" "base round trips:"; do
  if ! grep -q "$phrase" "$WORK/big-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  construction, predicates, arithmetic, division, bitwise, known values, roundtrips, pow_mod, identities, karatsuba, hashing, decimals, rationals and bases all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" big-release --release
if ! grep -q "all std/big checks passed" "$WORK/big-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi
if ! diff <(grep '^oracle ' "$WORK/big-plain.out") <(grep '^oracle ' "$WORK/big-release.out") >/dev/null 2>&1; then
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

counts = {"dec": 0, "cmp": 0, "rat": 0, "base": 0}
bad = 0
for line in sys.stdin:
    if not line.startswith("oracle "):
        continue
    kind, rest = line[7:].split(": ", 1)
    lhs, got = rest.rstrip("\n").split(" = ")
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
floor = {"dec": 100, "cmp": 20, "rat": 60, "base": 70}
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

# ---------------------------------------------------------------------------
# What the module refuses, and the sentence it refuses with
# ---------------------------------------------------------------------------

echo
echo "== what std/big refuses"
big_panics_with() { # big_panics_with <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/big\nusing std/big::{BigInt, BigDecimal, BigRational}\n\nputs (%s).to_s\n' "$expression" > "$WORK/$name.iyi"
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
prove_fails "multiplication broken" no_mul "string: octal prefix" \
  's/r\[i + j\] = prod \& 0xFFFFFFFF_u64/r[i + j] = 0_u64/'

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

# 11. BigDecimal hash forgets to normalise the scale (1.10 != 1.1 as keys)
prove_fails "decimal hash skips normalisation" no_dec_norm "hash: decimal scale agreement" \
  's/n = normalized/n = self/'

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
  's/prefix = @sign < 0 [?] "-" : ""/prefix = ""/'

echo
if [ "$status" -eq 0 ]; then
  echo "Big number standard library: BigInt construction, predicates, arithmetic, division,"
  echo "bitwise logic, known large values, round trips, pow_mod, random identities and"
  echo "Karatsuba, BigDecimal and BigRational arithmetic checked against python3, hashes"
  echo "that agree with ==, every base 2..36, all pass plain and optimised; what the"
  echo "module refuses is refused with a sentence, and each check is proven to fail"
  echo "when its mechanism is broken."
else
  echo "std/big exercise driver: failures encountered"
fi
exit "$status"
