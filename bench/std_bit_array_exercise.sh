#!/usr/bin/env bash
# Exercises `std/bit_array`.
#
#     bash bench/std_bit_array_exercise.sh
#
# Proves the exercise holds plain and --release, that broken operations are
# caught (toggle, word boundary crossing, unused bit masking, invert), and
# what BitArray refuses: negative size, out-of-bounds index reads, out-of-bounds
# index writes, out-of-bounds toggle, first/last of an empty array, and out-of-bounds
# fill start - each a panic with the module's sentence.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_bit_array_exercise.iyi" \
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

echo "== the std/bit_array exercise, plain build"
build_and_run "plain" bit_array-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/bit_array-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every bit_array section reported"
for phrase in "== construction and size" \
              "== bit indexing and toggle" \
              "== reads at first and last" \
              "== word boundaries" \
              "== bulk operations and predicates" \
              "== equality, hashing, copying, slicing" \
              "== iteration, reverse, rotate"; do
  if ! grep -q "$phrase" "$WORK/bit_array-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" bit_array-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/bit_array-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"

prove_fails() {
  local label="$1" name="$2" old="$3" new="$4"
  mkdir -p "$WORK/patched-$name/std"
  if [ -z "$PY" ]; then
    echo "  $label: no python3 on this machine, so the broken-module proof is unmeasured"
    return
  fi
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/bit_array.iyi").read_text()
old = """$old"""
new = """$new"""
if old not in src:
    raise SystemExit(f"patch site missing for {old!r}")
Path("$WORK/patched-$name/std/bit_array.iyi").write_text(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi

  if IYI_PATH="$WORK/patched-$name${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_bit_array_exercise.iyi" >"$WORK/$name.mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  else
    echo "  $label: a broken bit_array is caught"
  fi
}

prove_fails "toggle sets instead of XOR" broken_toggle \
  '@bits[word_idx] = @bits[word_idx] ^ mask' \
  '@bits[word_idx] = @bits[word_idx] | mask'

prove_fails "word boundary indexing collapsed" broken_words \
  'word_idx = idx // 64' \
  'word_idx = 0'

prove_fails "last returns first element" broken_last \
  'unsafe_fetch(@size - 1)' \
  'unsafe_fetch(0)'

prove_fails "invert does nothing" broken_invert \
  'while i < words' \
  'while i < 0'

prove_fails "count ignores bit values" broken_count \
  'ones += 1 if unsafe_fetch(i)' \
  'ones += 1'

prove_fails "hash ignores bit values" broken_hash \
  'h = (31 &* h) &+ (unsafe_fetch(i) ? 1 : 0)' \
  'h = (31 &* h)'

prove_fails "fill start+count overflows Int32" broken_fill_overflow \
  'limit = (c > @size - s) ? @size : (s + c)' \
  'limit = (s + c > @size) ? @size : (s + c)'

prove_fails "rotate goes through Int32" broken_rotate_i32 \
  'k64 = n.to_i64 % @size.to_i64' \
  'k64 = n.to_i.to_i64 % @size.to_i64'
echo
echo "== what bit_array refuses"

refuses() {
  local label="$1" name="$2" phrase="$3" body="$4"
  cat <<EOF > "$WORK/$name.iyi"
module main

import std/bit_array::{BitArray}

$body
EOF

  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}

refuses "negative size" neg_size "Negative bit array size: -5" 'BitArray.new(-5)'
refuses "index past end" oob_pos "Index out of bounds: 10 (size: 10)" 'ba = BitArray.new(10); ba[10]'
refuses "negative index past start" oob_neg "Index out of bounds: -11 (size: 10)" 'ba = BitArray.new(10); ba[-11]'
refuses "assignment past end" assign_oob "Index out of bounds: 5 (size: 5)" 'ba = BitArray.new(5); ba[5] = true'
refuses "toggle past end" toggle_oob "Index out of bounds: 8 (size: 8)" 'ba = BitArray.new(8); ba.toggle(8)'
refuses "first of empty array" first_empty "Empty BitArray" 'ba = BitArray.new(0); ba.first'
refuses "last of empty array" last_empty "Empty BitArray" 'ba = BitArray.new(0); ba.last'
refuses "fill start out of bounds" fill_oob "Start out of bounds" 'ba = BitArray.new(10); ba.fill(true, 12, 1)'
refuses "size above Int32" size_too_large "Bit array size too large: 2147483648" 'BitArray.new(2147483648_i64)'
refuses "negative size below Int32" neg_i64 "Negative bit array size: -2147483649" 'BitArray.new(-2147483649_i64)'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/bit_array exercise holds"
else
  echo "the std/bit_array exercise did not hold"
fi
exit $status
