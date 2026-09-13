#!/usr/bin/env bash
# Text processing standard library exercise driver.
# Runs the text exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std/text.iyi.
#
#     bash bench/std_text_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# character inspection, case conversion, base conversion, chomp line-ending
# removal, string splitting, substitution, UTF-8 reverse preservation, and
# multi-byte character encoding.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_text_exercise.iyi" \
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

echo "== the text exercise, plain build"
run_case "plain" text-plain
if ! grep -q "all std/text checks passed" "$WORK/text-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every text section reported"
for phrase in "char inspection:" "case conversion:" "base conversion:" "strip and chomp:" "split and partition:" "search and index:" "substitution:" "transformations:" "utf8 awareness:"; do
  grep -q "$phrase" "$WORK/text-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  char inspection, case, base, strip/chomp, split/partition, search/index, substitution, transformations, and utf8 all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" text-release --release
if ! grep -q "all std/text checks passed" "$WORK/text-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when text operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/text.iyi" > "$WORK/$dir/std/text.iyi"
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_text_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched text library did not build"
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

# 1. ASCII letter predicate broken
prove_fails "ascii letter predicate broken" no_letter "char: ascii_letter lowercase" \
  's/def ascii_letter? : Bool/def ascii_letter? : Bool; return false/'

# 2. String capitalize broken
prove_fails "string capitalize broken" no_capitalize "string: capitalize standard" \
  's/b0 - 32_u8/b0/'

# 3. Base parsing broken (every digit read as zero). The parser accumulates
#    a negative magnitude, so `Int32::MIN` reads back; the line moved with
#    that fix and this proof moved with it.
prove_fails "base parsing broken" no_base "string: to_i base 16" \
  's/^      value = value \* base - digit$/      value = 0/'

# 4. Chomp CRLF broken
prove_fails "chomp crlf broken" no_chomp "string: chomp crlf" \
  's/return byte_slice(0, bytesize - 2)/return self/'

# 5. String split broken
prove_fails "string split broken" no_split "string: split str" \
  's/byte_slice(start, idx - start)/"broken"/'

# 6. String substitution broken
prove_fails "string substitution broken" no_sub "string: sub str" \
  's/byte_slice(0, idx) + replacement/byte_slice(0, idx) + "wrong"/'

# 7. UTF-8 reverse broken
prove_fails "utf8 reverse broken" no_reverse "utf8: reverse content" \
  's/def reverse : String/def reverse : String; return "broken"/'

# The two the prelude owns: `Char#to_s` encodes and `String#each_char`
# decodes, and they are its own because the prelude counts code points in
# `size` and has to agree with itself. Patched where they live.
prove_fails_prelude() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  sed -e "$sed_script" "$REPO/src/iyi/string.iyi" > "$WORK/$dir/iyi/string.iyi"
  if cmp -s "$REPO/src/iyi/string.iyi" "$WORK/$dir/iyi/string.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_text_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched prelude did not build"
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

# 8. Multi-byte char to_s encoding broken, in the prelude
prove_fails_prelude "char utf8 encoding broken" no_encode "utf8: char to_s" \
  's/buffer\[1\] = (0x80 | (point \& 0x3F)).to_u8/buffer[1] = 0_u8/'

# 9. And the decoder the same string's `size` already agrees with
prove_fails_prelude "utf8 each_char decoding broken" no_decode "utf8: chars size" \
  's/index = index + 2$/index = index + 1/'

# 10. Padding measured in bytes again, which is what it did
prove_fails_prelude "padding width in bytes" no_width "utf8: ljust width" \
  's/^    count = size$/    count = @bytesize/'

# 11. And the pad written as one byte, which cut a multi-byte one in half
prove_fails_prelude "wide pad truncated" no_wide "utf8: wide pad bytes" \
  's/^    pad_bytes = padding.bytesize$/    pad_bytes = 1/'

echo
echo "== the prelude's own String at its edges, which is a panic with a name"
# `[](start, count)` has said for a long time that a negative count "is not
# a wrap, it is a mistake"; `*` did not, and `"ab" * -3` answered `""` where
# Crystal raises. `"abcd" * 600_000_000` answered "arithmetic overflow",
# which names the machine's adder rather than the string that does not fit.
# Driven here rather than asserted in the exercise: a panicking program has
# no next line to check.
panics_with() { # panics_with <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nputs (%s).to_s\n' "$expression" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of panicking"
    status=1
    return
  fi
  if [ "$code" -ne 1 ]; then
    echo "  $label: died with exit $code rather than a panic"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$name.out"; then
    echo "  $label: panicked, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits 1 at "%s"\n' "$label" \
    "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}

panics_with "a negative repeat" mul_negative "negative count: -3" '"ab" * -3'
panics_with "a repeat that does not fit" mul_overflow \
  "past the 2147483647 bytes a string holds" '"abcd" * 600_000_000'
panics_with "a negative slice count" slice_negative "negative count: -1" '"abc"[0, -1]'
panics_with "an index past the end" index_past \
  "out of range for a string of 3 bytes" '"abc"[9]'
echo
if [ "$status" -eq 0 ]; then
  echo "Text standard library: inspection, cases, conversions, strip, chomp, split,"
  echo "search, sub, transformations, and UTF-8 handling all pass plain and optimised,"
  echo "and each check is proven to fail when its mechanism is broken."
else
  echo "Text standard library: something above failed."
fi
exit "$status"
