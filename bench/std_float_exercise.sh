#!/usr/bin/env bash
# Exercises `std/float`: Float32 arithmetic and constants, the conversions
# to the integers, the exact comparison against them, and `%` and `//`.
#
#     bash bench/std_float_exercise.sh
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
for phrase in "== arithmetic" "== constants" "== narrowing" "== conversions to integers" "== comparison with integers" "== modulo and floored division" "== traits"; do
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
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/float.iyi").read_text()
old = 'MAX          =  3.40282347e+38_f32'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/float.iyi").write_text(src.replace(old, 'MAX          =  1.0_f32', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_float_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken float is caught"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/float exercise holds"
else
  echo "the std/float exercise did not hold"
fi
exit $status
