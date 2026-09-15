#!/usr/bin/env bash
# Big integer standard library exercise driver.
# Runs the big integer exercise in plain and release mode, checks every section
# reported, proves division by zero raises rather than trapping, and proves
# the checks can fail by patching copies of std/big.iyi.
#
#     bash bench/std_big_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# addition, multiplication, division, modulo sign rules, bitwise operations,
# negation, power-of-two exponentiation, and base constants.
#
# Exits non-zero if any check fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
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
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the big integer exercise, plain build"
run_case "plain" big-plain
if ! grep -q "all std/big checks passed" "$WORK/big-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every big integer section reported"
for phrase in "construction and conversions:" "predicates and comparisons:" "basic arithmetic:" "division corner cases:" "bitwise operations:" "known large values:" "round trips:" "modular exponentiation:" "algebraic identities:" "karatsuba:"; do
  if ! grep -q "$phrase" "$WORK/big-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  construction, predicates, arithmetic, division, bitwise, known values, roundtrips, pow_mod, identities, and karatsuba all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" big-release --release
if ! grep -q "all std/big checks passed" "$WORK/big-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving division by zero raises rather than trapping"
cat > "$WORK/div_zero.iyi" << 'EOF'
import std/big
using std/big::{BigInt}
_ = 42.to_big // 0.to_big
EOF

if ! "$IYI" build -o "$WORK/div_zero_bin" "$WORK/div_zero.iyi" >"$WORK/div_zero_build.log" 2>&1; then
  echo "  division by zero probe failed to build"
  status=1
else
  "$WORK/div_zero_bin" >"$WORK/div_zero.out" 2>&1
  exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  division by zero probe unexpectedly succeeded"
    status=1
  elif grep -q "division by zero" "$WORK/div_zero.out"; then
    echo "  division by zero: correctly raised (panicked with 'division by zero', exit $exit_code)"
  else
    echo "  division by zero: exited $exit_code without division by zero message"
    cat "$WORK/div_zero.out"
    status=1
  fi
fi

cat > "$WORK/mod_zero.iyi" << 'EOF'
import std/big
using std/big::{BigInt}
_ = 42.to_big % 0.to_big
EOF

if ! "$IYI" build -o "$WORK/mod_zero_bin" "$WORK/mod_zero.iyi" >"$WORK/mod_zero_build.log" 2>&1; then
  echo "  modulo by zero probe failed to build"
  status=1
else
  "$WORK/mod_zero_bin" >"$WORK/mod_zero.out" 2>&1
  exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  modulo by zero probe unexpectedly succeeded"
    status=1
  elif grep -q "division by zero" "$WORK/mod_zero.out"; then
    echo "  modulo by zero: correctly raised (panicked with 'division by zero', exit $exit_code)"
  else
    echo "  modulo by zero: exited $exit_code without division by zero message"
    cat "$WORK/mod_zero.out"
    status=1
  fi
fi

echo
echo "== proving the checks can fail when big integer operations are broken"

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
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
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
prove_fails "addition carry dropped" no_add_carry "overflow: i64 pos nil" \
  's/sum = va + vb + carry/sum = va + vb/'

# 2. Multiplication broken (returns zero for limbs)
prove_fails "multiplication broken" no_mul "string: underscores" \
  's/res\[i + j\] = prod & 0xFFFFFFFF_u64/res[i + j] = 0_u64/'

# 3. Negation broken (identity instead of negate)
prove_fails "negate broken" no_negate "overflow: i64 neg nil" \
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

echo
if [ "$status" -eq 0 ]; then
  echo "Big integer standard library: construction, predicates, arithmetic, division,"
  echo "bitwise logic, known large values, round trips, pow_mod, random identities,"
  echo "and Karatsuba crossover all pass plain and optimised, division by zero raises,"
  echo "and each check is proven to fail when its mechanism is broken."
else
  echo "std/big exercise driver: failures encountered"
fi
exit "$status"
