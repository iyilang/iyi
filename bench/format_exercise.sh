#!/usr/bin/env bash
# Format strings, exercised and driven. Runs the format exercise plain and
# optimised, checks every section reported, and proves the checks can fail
# by patching copies of the format library via IYI_PATH.
#
#     bash bench/format_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# each capability: width padding, left-alignment, zero-padding, float
# precision rounding, integer base conversion, sign handling, and boundary
# handling for zero-precision integers.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/format_exercise.iyi" \
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

echo "== the format exercise, plain build"
run_case "plain" format-plain
if ! grep -q "all format checks passed" "$WORK/format-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every format section reported"
for phrase in "width:" "alignment:" "zero pad:" "precision:" "base:" "negative:" "boundary:"; do
  grep -q "$phrase" "$WORK/format-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  width, alignment, zero pad, precision, base, negative, and boundary all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" format-release --release
if ! grep -q "all format checks passed" "$WORK/format-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when formatting is broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  # The library the program imports, not the prelude: `std/format` is a
  # module now, so the patched copy is `std/` and `IYI_PATH` finds it first.
  mkdir -p "$WORK/$dir/std"
  cp -R "$REPO/src/std/." "$WORK/$dir/std/"
  sed -e "$sed_script" "$REPO/src/std/format.iyi" > "$WORK/$dir/std/format.iyi"
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/format_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched format library did not build"
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

# 1. Width padding removed
prove_fails "width padding broken" no_width "format: width" \
  's/pad = " " \* (width - res\.size)/pad = ""/'

# 2. Alignment reversed
prove_fails "alignment ignored" no_align "format: alignment" \
  's/minus ? res + pad : pad + res/pad + res/'

# 3. Zero padding replaced with spaces
prove_fails "zero pad broken" no_zero "format: zero pad" \
  's/sign + prefix + ("0" \* pad_count) + digits/sign + prefix + (" " * pad_count) + digits/'

# 4. Float rounding dropped (always rounds down): the half-to-even test in
#    `scaled_digits` is the one place every float digit is decided.
prove_fails "precision rounding broken" no_prec "format: precision float round up" \
  's/^    if c > 0 || (c == 0 \&\& quotient.low_bit == 1_u64)$/    if false/'

# 4b. The tie decided away from zero again, which is what every reference
#     formatter disagrees with and what this file pinned before.
prove_fails "a tie rounds away from zero" no_even "format: precision float tie to even" \
  's/^    if c > 0 || (c == 0 \&\& quotient.low_bit == 1_u64)$/    if c >= 0/'

# 4c. The digits past the shortest ones dropped: a bignum rendered without
#     its zero-led chunks prints 1e22 as 10000.000, which is what a printer
#     that pads the shortest digits with zeros was never able to see.
prove_fails "the digits are the value's, all of them" no_exact "format: exact large zeros" \
  's/^      text = text + ("0" \* (9 - chunk\.size)) + chunk$/      text = text + chunk/'

# 5. Base conversion broken (binary emits decimal)
prove_fails "base conversion broken" no_base "format: base" \
  's/format_int64(val\.to_i64, 2, false, false/format_int64(val.to_i64, 10, false, false/'

# 6. Negative number sign flag broken (space flag dropped)
prove_fails "sign flag broken" no_neg "format: sign space positive" \
  's/sign = " "/sign = ""/'

# 7. Boundary case broken (precision 0 on value 0 produces "0" instead of "")
prove_fails "boundary zero precision broken" no_bound "format: boundary" \
  's/digits = precision == 0 ? "" : "0"/digits = "0"/'

echo
if [ "$status" -eq 0 ]; then
  echo "Format strings: width, alignment, zero pad, precision, bases, negatives,"
  echo "and boundary cases all pass plain and optimised, and each check is"
  echo "proven to fail when its mechanism is broken."
else
  echo "Format strings: something above failed."
fi
exit "$status"
