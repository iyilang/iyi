#!/usr/bin/env bash
# `Float64#to_s` and `String#to_f` (src/iyi/float.iyi): the shortest
# decimal that reads back as the same double, in Crystal's notation, and
# the correctly rounded double a decimal names. Runs bench/float_text.iyi
# plain and optimised - forty-odd printed cases, two dozen parsed, twenty
# thousand doubles printed and read back to their bits - then proves the
# check fails by name when the printer is broken: the bignum digit loop's
# stop condition removed (every value it prints has seventeen digits, no
# longer the shortest), the notation's range widened (ten to the
# fifteenth prints in fixed form), Grisu's proof skipped, the fast
# parser's halfway case rounded up, a truncated word trusted without
# checking the one above it, and the bignum parser's rounding made
# truncation.
set -euo pipefail

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

echo "== the exercise"
for flags in "" "--release"; do
  if ! "$IYI" build $flags -o "$WORK/program" "$REPO/bench/float_text.iyi" > "$WORK/build.log" 2>&1; then
    echo "  build failed ($flags)"; cat "$WORK/build.log" | tail -5; status=1; continue
  fi
  if "$WORK/program" > "$WORK/out" 2>&1 && grep -q "every case printed" "$WORK/out"; then
    echo "  ${flags:-plain}: $(cat "$WORK/out")"
  else
    echo "  ${flags:-plain}: FAILED"; cat "$WORK/out"; status=1
  fi
done

# $1 label, $2 directory, $3 the phrase the failing check prints, $4 awk
# program over float.iyi.
prove_fails() {
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  awk "$script" "$REPO/src/iyi/float.iyi" > "$WORK/$dir/iyi/float.iyi"
  if cmp -s "$WORK/$dir/iyi/float.iyi" "$REPO/src/iyi/float.iyi"; then
    echo "  $label: the awk found nothing to change"; status=1; return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -o "$WORK/$dir/program" "$REPO/bench/float_text.iyi" > "$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched prelude did not build"; tail -3 "$WORK/$dir/build.log"; status=1; return
  fi
  set +e
  "$WORK/$dir/program" > "$WORK/$dir/out" 2>&1
  local code=$?
  set -e
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"; status=1; return
  fi
  if grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: exits $code at \"$(grep -m1 "$phrase" "$WORK/$dir/out")\""
  else
    echo "  $label: failed, but not at the expected check"; cat "$WORK/$dir/out"; status=1
  fi
}

echo
echo "== the check fails when the printer is broken"
prove_fails "digits never stop short" longform "float text:" \
  '{ if ($0 ~ /^      if !low && !high$/) { print "      if count < 17"; next } print }'
prove_fails "notation range widened" widerange "float text: 1.234567890123456e+15" \
  '{ if ($0 ~ /^    if k > -4 && k <= 15$/) { print "    if k > -4 && k <= 16"; next } print }'
prove_fails "the fast printer's proof skipped" unproven "float text:" \
  '{ if ($0 ~ /^    \{digits, 2_u64 &\* unit <= rest && rest <= unsafe_interval &- 4_u64 &\* unit\}$/) { print "    {digits, true}"; next } print }'
prove_fails "halfway rounded up, not to even" noeven "float text: 9007199254740993 read as" \
  '{ if ($0 ~ /^    if low <= 1_u64 && q >= -4 && q <= 23 && mantissa & 3_u64 == 1_u64$/) { print "    if false"; next } print }'
prove_fails "a truncated word trusted" trusted "float text: 9007199254740993.000000000000000000001" \
  '{ if ($0 ~ /^    return parse_exact\(text\) if truncated && /) { next } print }'
prove_fails "parser truncates" truncate "float text:" \
  '{ if ($0 ~ /^    if half != 0_u64 && \(remainder \|\| \(q & 1_u64\) != 0_u64\)$/) { print "    if false"; next } print }'

echo
if [ "$status" -eq 0 ]; then
  echo "Float text: every case is the shortest decimal that reads back, in"
  echo "Crystal's notation, and the check fails in both directions."
else
  echo "Float text: something above failed."
fi
exit "$status"
