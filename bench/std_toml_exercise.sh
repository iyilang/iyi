#!/usr/bin/env bash
# Exercises `std/toml`: TOML 1.0.0 read and written, against Python's own
# reader. The exercise reads the spec's examples, a corpus of every
# construct, 20,000 fuzzed documents of headers and dotted keys and 256
# random documents written in random syntax, refuses what the format
# refuses with its line and column, dumps everything back, and derives;
# Python's `tomllib` then reads the same bytes to the same values (as
# tagged JSON, dates and times typed), refuses every document this reader
# refuses, accepts and refuses each fuzzed document as this reader did,
# reads every dump to the value it was dumped from, and reads each derived
# record's `to_toml` to what its `to_json` says. Broken copies of the module
# prove each check can fail, at the check that names what was broken.
#
#     bash bench/std_toml_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping (see
# bench/std_yaml_exercise.sh): both paths are handed over mixed.
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

# Python is the other reader and the patcher; a machine can answer
# `python3` with a stub that prints a refusal instead of running, so the
# interpreter is proven to run, and to have tomllib (3.11 and later),
# before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
EXERCISE="$REPO/bench/std_toml_exercise.iyi"

# What the person reading the gate sees: the exercise's own lines, not its
# records for Python.
shown() {
  grep -v -E '^(CORPUS|INVALID|OWN|DEEP|FUZZ|DUMP|DERIVE) ' "$1" | sed 's/^/  /'
}

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$EXERCISE" >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    shown "$WORK/$name.out"
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/toml exercise, plain build"
build_and_run "plain" toml-plain && shown "$WORK/toml-plain.out"
if ! grep -q "ALL CHECKS PASSED" "$WORK/toml-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every toml section reported"
missing=0
for phrase in "== the spec's own examples" "== the corpus of every construct" "== scalars, strings and keys" \
  "== dates and times" "== tables, arrays of tables, inline tables" "== what the reader refuses" \
  "== the redefinition rules" "== the redefinition rules, fuzzed" "== random documents in random syntax" \
  "== dump round trip" "== nesting and DEPTH_LIMIT" "== derive toml_serializable"; do
  if ! grep -qxF "$phrase" "$WORK/toml-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    missing=1
    status=1
  fi
done
[ "$missing" -eq 0 ] && echo "  all twelve sections reported"

echo
echo "== the same program with optimisation on (--release)"
if build_and_run "release" toml-release --release; then
  if ! grep -q "ALL CHECKS PASSED" "$WORK/toml-release.out"; then
    echo "  release: missing pass sentinel"
    status=1
  elif cmp -s "$WORK/toml-plain.out" "$WORK/toml-release.out"; then
    echo "  passes, and prints every line and record the plain build prints"
  else
    echo "  passes, but prints otherwise than the plain build:"
    diff "$WORK/toml-plain.out" "$WORK/toml-release.out" | sed -n '1,6p' | sed 's/^/    /'
    status=1
  fi
fi

# The records against Python's tomllib: answers 0 when every record
# agrees, 1 on a disagreement, 2 with no records at all.
compare_records() {
  RECORDS="$1" "$PY" - <<'PY'
import datetime, json, math, os, struct, sys, tomllib

# A value as the exercise's `canon` writes it: every scalar its type and
# its text, a float by its bits (nan, inf, -inf by name), a date or time
# to the microsecond, which is as far as `datetime` goes.
def tag(v):
    if isinstance(v, bool):
        return {"type": "bool", "value": "true" if v else "false"}
    if isinstance(v, int):
        return {"type": "integer", "value": str(v)}
    if isinstance(v, float):
        if v != v:
            s = "nan"
        elif v == math.inf:
            s = "inf"
        elif v == -math.inf:
            s = "-inf"
        else:
            s = struct.pack(">d", v).hex()
        return {"type": "float", "value": s}
    if isinstance(v, str):
        return {"type": "string", "value": v}
    if isinstance(v, datetime.datetime):
        d = f"{v.year:04d}-{v.month:02d}-{v.day:02d}T{v.hour:02d}:{v.minute:02d}:{v.second:02d}.{v.microsecond:06d}"
        if v.tzinfo is None:
            return {"type": "datetime-local", "value": d}
        off = int(v.utcoffset().total_seconds()) // 60
        sign = "-" if off < 0 else "+"
        off = abs(off)
        return {"type": "datetime", "value": f"{d}{sign}{off // 60:02d}:{off % 60:02d}"}
    if isinstance(v, datetime.date):
        return {"type": "date-local", "value": f"{v.year:04d}-{v.month:02d}-{v.day:02d}"}
    if isinstance(v, datetime.time):
        return {"type": "time-local", "value": f"{v.hour:02d}:{v.minute:02d}:{v.second:02d}.{v.microsecond:06d}"}
    if isinstance(v, list):
        return [tag(x) for x in v]
    if isinstance(v, dict):
        return {k: tag(x) for k, x in v.items()}
    raise TypeError(type(v))

# The bytes as a file holds them: text that is not UTF-8 is refused by
# the decoding, as tomllib.load refuses it.
def load(hexed):
    return tomllib.loads(bytes.fromhex(hexed).decode("utf-8"))

def without_none(v):
    if isinstance(v, dict):
        return {k: without_none(x) for k, x in v.items() if x is not None}
    if isinstance(v, list):
        return [without_none(x) for x in v]
    return v

lines = open(os.environ["RECORDS"], encoding="utf-8", errors="replace").read().split("\n")
counts = {"CORPUS": 0, "DUMP": 0, "INVALID": 0, "OWN": 0, "DEEP": 0, "FUZZ": 0, "DERIVE": 0}
bad = 0
for n, line in enumerate(lines, 1):
    kind, _, rest = line.partition(" ")
    if kind not in counts:
        continue
    counts[kind] += 1
    try:
        if kind in ("CORPUS", "DUMP"):
            hexed, want = rest.split("\t")
            if tag(load(hexed)) != json.loads(want):
                bad += 1
                print(f"    record {n}, {kind}: tomllib reads other data from {bytes.fromhex(hexed)[:160]!r}")
        elif kind == "INVALID":
            try:
                load(rest)
            except (tomllib.TOMLDecodeError, UnicodeDecodeError):
                pass
            else:
                bad += 1
                print(f"    record {n}: tomllib reads what std/toml refuses: {bytes.fromhex(rest)[:160]!r}")
        elif kind == "OWN":
            # Refused here for an integer past Int64, which the spec says
            # to refuse and tomllib reads: the difference is that, no other.
            numbers = [x for x in load(rest).values() if isinstance(x, int)]
            if not numbers or all(-2**63 <= x < 2**63 for x in numbers):
                bad += 1
                print(f"    record {n}: not an integer past Int64 to tomllib: {bytes.fromhex(rest)!r}")
        elif kind == "DEEP":
            # Refused here for nesting past DEPTH_LIMIT, this reader's
            # bound and not the format's: tomllib reads it.
            load(rest)
        elif kind == "FUZZ":
            hexed, verdict = rest.split("\t")
            try:
                load(hexed)
                reads = "1"
            except tomllib.TOMLDecodeError:
                reads = "0"
            if reads != verdict:
                bad += 1
                said = "reads" if reads == "1" else "refuses"
                print(f"    record {n}: tomllib {said} what std/toml does not: {bytes.fromhex(hexed)!r}")
        else:
            j, hexed = rest.split("\t")
            if load(hexed) != without_none(json.loads(j)):
                bad += 1
                print(f"    record {n}: tomllib reads to_toml to other data than to_json")
    except Exception as error:
        bad += 1
        print(f"    record {n}, {kind}: {type(error).__name__}: {error}")
print("    " + ", ".join(f"{counts[k]} {k}" for k in counts) + ": " + ("all agree" if bad == 0 else f"{bad} disagree"))
if sum(counts.values()) == 0:
    sys.exit(2)
sys.exit(1 if bad else 0)
PY
}

echo
echo "== Python's tomllib reads the same bytes to the same values"
if [ -z "$PY" ]; then
  echo "  no python3 with tomllib on this machine, so no other reader was asked"
  status=1
else
  compare_records "$WORK/toml-plain.out"
  case $? in
    0) ;;
    2) echo "  the exercise printed no records"; status=1 ;;
    *) echo "  tomllib and std/toml disagree"; status=1 ;;
  esac
fi

# A refusal that is a panic ends the program, and its sentence is the
# whole of what the person reading it gets: each runs as its own program
# and its exact sentence is checked.
echo
echo "== what is refused by panicking, each in its own program"
refuse_program() {
  local name="$1" sentence="$2" body="$3"
  cat >"$WORK/refuse_$name.iyi" <<IYI
module refuse_$name

import std/toml::{TOML, Any, TOMLDateTime, toml_serializable}

struct Spot
  getter x : Float64
  getter name : String

  derive toml_serializable
end

$body
puts "accepted"
IYI
  if "$IYI" run "$WORK/refuse_$name.iyi" >"$WORK/refuse_$name.out" 2>&1; then
    echo "  accepted: $body"
    status=1
  elif ! grep -qxF "iyi: panic: $sentence" "$WORK/refuse_$name.out"; then
    echo "  refused, but not with \"$sentence\":"
    sed 's/^/    /' "$WORK/refuse_$name.out"
    status=1
  else
    echo "  $sentence"
  fi
}
refuse_program missing 'TOML for Spot has no key "name"' 'Spot.from_toml("x = 1.0\n")'
refuse_program table 'expected a table for Spot, not an array' 'Spot.new(TOML.parse("a = [1]").or_panic["a"])'
refuse_program kind 'expected a float, not a string' 'Spot.from_toml("x = \"one\"\nname = \"a\"\n")'
refuse_program text 'a line break cannot start a value at line 1, column 5' 'Spot.from_toml("x = \n")'
refuse_program or_panic '01 has a leading zero, which only 0 may at line 2, column 5' 'TOML.parse("a = 1\nb = 01\n").or_panic'
refuse_program null 'TOML has no null, so a nil cannot be written' 'puts TOML.to_toml({"a" => [1, nil]})'
refuse_program uint64 'the UInt64 18446744073709551615 is past 9223372036854775807, the largest TOML integer' 'puts TOML.to_toml({"a" => 18446744073709551615_u64})'
refuse_program document 'TOML.dump: a document is a table, not an array' 'puts TOML.dump(Any.new([Any.new(1)]))'
refuse_program date 'TOMLDateTime: the month 13 is not 1 to 12' 'puts TOMLDateTime.local_date(2024, 13, 1)'
refuse_program offset 'TOMLDateTime: only an offset date-time has an offset' 'puts TOMLDateTime.new(TOMLDateTime::LOCAL_DATE_TIME, 2024, 1, 1, 0, 0, 0, 0, 60)'

# One proof per check: the module is copied with one site patched back to
# a plausible mistake, and the exercise must then fail at the check that
# names it, not merely fail. Each copy is built before it is run, so a
# patch that does not compile is not taken for a caught one.
mutations=0
patch_module() {
  local old="$1" new="$2" dest="$3"
  rm -rf "$dest"
  mkdir -p "$dest/std"
  OLD="$old" NEW="$new" "$PY" - "$REPO/src/std/toml.iyi" "$dest/std/toml.iyi" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
old = os.environ["OLD"]
if src.count(old) != 1:
    raise SystemExit(f"patch site found {src.count(old)} times, not once: {old!r}")
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, os.environ["NEW"], 1))
PY
}

prove_caught() {
  local what="$1" message="$2" old="$3" new="$4"
  mutations=$((mutations + 1))
  echo
  echo "== proving the checks can fail when $what"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the broken copy could not be made"
    status=1
    return
  fi
  if ! patch_module "$old" "$new" "$WORK/patched"; then
    echo "  the patch did not apply"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mut-$mutations" "$EXERCISE" >"$WORK/mut.out" 2>&1; then
    echo "  the broken copy did not compile:"
    grep -m2 -E 'Error|BUG' "$WORK/mut.out" | sed 's/^/    /'
    status=1
    return
  fi
  if timeout 120 "$WORK/mut-$mutations" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED with $what"
    status=1
  elif ! grep 'ASSERTION FAILED' "$WORK/mut.out" | grep -qF -- "$message"; then
    echo "  the exercise failed, but not at \"$message\":"
    grep -m1 'ASSERTION FAILED\|panic' "$WORK/mut.out" | cut -c1-200 | sed 's/^/    /'
    status=1
  else
    echo "  caught: $(grep -m1 'ASSERTION FAILED' "$WORK/mut.out" | cut -c1-160)"
  fi
}

# Numbers.
prove_caught "a leading zero is read" 'accepted "a = 01\n"' \
  'if @bytes[i] == 48_u8 && whole > i + 1' 'if false && @bytes[i] == 48_u8 && whole > i + 1'
prove_caught "underscores need not stand between digits" 'accepted "a = 1__0\n"' \
  $'        return -1 unless i + 1 < stop && radix_digit(@bytes[i + 1], radix) >= 0\n        i = i + 2' '        i = i + 1'
prove_caught "a hexadecimal integer may have a sign" 'accepted "a = +0x1\n"' \
  'which only a decimal number may have", start) if signed' 'which only a decimal number may have", start) if false'
prove_caught "the smallest integer is counted as a positive one" 'corpus document 39: refused with -9223372036854775808 is outside' \
  'limit = negative ? 9223372036854775808_u64 : 9223372036854775807_u64' 'limit = 9223372036854775807_u64'
prove_caught "the radix limit is one short" 'corpus document 39: refused with 0x7FFFFFFFFFFFFFFF is past' \
  'if value > (9223372036854775807_u64 - d.to_u64) // radix.to_u64' 'if value > (9223372036854775806_u64 - d.to_u64) // radix.to_u64'

# Strings.
prove_caught "an escape may name a surrogate" 'accepted "a = \"\\uD800\"\n"' \
  'if (point >= 0xD800 && point <= 0xDFFF) || point > 0x10FFFF' 'if point > 0x10FFFF'
prove_caught "a line-ending backslash keeps the next line's indentation" 'a line-ending backslash' \
  '            if c == 32_u8 || c == 9_u8 || c == 10_u8' '            if c == 10_u8'
prove_caught "the line break after the opening quotes is kept" 'the break after the opening quotes is dropped' \
  $'    if byte?(@pos, 10_u8)\n      @pos = @pos + 1\n    elsif' $'    if false\n      @pos = @pos + 1\n    elsif'
prove_caught "CRLF inside a multi-line string is kept as it is" 'CRLF inside a multi-line string reads as LF' \
  $'        return fail("a carriage return not followed by a line feed", @pos) unless byte?(@pos + 1, 10_u8)\n        text.write_byte(10_u8)\n        @pos = @pos + 2\n      elsif control?(b)\n        return fail("#{found(@pos)} in a string' \
  $'        return fail("a carriage return not followed by a line feed", @pos) unless byte?(@pos + 1, 10_u8)\n        text.write_byte(13_u8)\n        text.write_byte(10_u8)\n        @pos = @pos + 2\n      elsif control?(b)\n        return fail("#{found(@pos)} in a string'
prove_caught "six quotes may close a multi-line string" 'accepted "a = \"\"\"x\"\"\"\"\"\"\n"' \
  'quotes closing a multi-line string, where five is the most", @pos) if n > 5' 'quotes closing a multi-line string, where five is the most", @pos) if n > 6'

# Comments, line ends, encoding.
prove_caught "a control character is let into a comment" 'accepted "a = 1 # bell' \
  $'      if (b < 32_u8 && b != 9_u8) || b == 127_u8\n        return fail("#{found(@pos)} in a comment", @pos)' \
  $'      if false\n        return fail("#{found(@pos)} in a comment", @pos)'
prove_caught "a lone carriage return ends a line" 'accepted "a = 1\r"' \
  $'    return fail("a carriage return not followed by a line feed", @pos) if b == 13_u8\n    fail(' \
  $'    if b == 13_u8\n      @pos = @pos + 1\n      return nil\n    end\n    fail('
prove_caught "an overlong UTF-8 form is read" 'accepted "a = \"\xC0' \
  'if b >= 0xC2_u8 && b <= 0xDF_u8' 'if b >= 0xC0_u8 && b <= 0xDF_u8'
prove_caught "a UTF-8 surrogate is read" 'accepted "a = \"\xED' \
  '        high = 0x9F_u8 if b == 0xED_u8' '        high = 0xBF_u8 if b == 0xED_u8'

# Dates and times.
prove_caught "a day past its month's end is a date" '1900 is not a leap year' \
  'if day < 1 || day > last' 'if day < 1 || day > 31'
prove_caught "a leap second is read" 'accepted "a = 1979-05-27T23:59:60Z\n"' \
  'if second < 0 || second > 59' 'if second < 0 || second > 60'

# The redefinition rules.
prove_caught "a key may be given twice" 'accepted "name = \"Tom\"\nname = \"Pradyun\"\n"' \
  $'    unless t.slots[last]?.nil?\n      return fail(' $'    if false\n      return fail('
prove_caught "a table may be declared twice" 'accepted "[fruit]\napple = \"red\"\n\n[fruit]\n' \
  'is declared twice", starts[parts.size - 1]) if child.explicit' 'is declared twice", starts[parts.size - 1]) if false'
prove_caught "a super-table declared after its sub-table is not marked declared" 'accepted "[x.y]\n[x]\n[x]\n"' \
  $'        child.explicit = true\n' ''
prove_caught "a header may declare a table dotted keys made" 'accepted "[fruit]\napple.color = \"red\"\napple.taste.sweet = true\n\n[fruit.apple]\n"' \
  'declares a table dotted keys made", starts[parts.size - 1]) if child.dotted' 'declares a table dotted keys made", starts[parts.size - 1]) if false'
prove_caught "dotted keys going through a table do not mark it" 'accepted "[a.b.c]\n[a]\nb.d = 1\n[a.b]\n"' \
  $'        child.dotted = true\n' ''
prove_caught "dotted keys may add to a table a header declared" 'accepted "[a.b.c]\nz = 9\n[a]\nb.c.t = 9\n"' \
  $'        if child.explicit\n          return fail("dotted keys add' $'        if false\n          return fail("dotted keys add'
prove_caught "an inline table takes a trailing comma" 'refusal of "a = {b = 1,}\n"' \
  $'      return fail("a comma after the last pair of an inline table", @pos) if @bytes[@pos] == 125_u8\n' ''

# Bounds, values, the writer.
prove_caught "nesting is unbounded" 'accepted 135 bytes nested past DEPTH_LIMIT' \
  $'    if depth > DEPTH_LIMIT\n      return too_deep(depth)' $'    if false\n      return too_deep(depth)'
prove_caught "two NaNs are different values" 'reads to the value it was written from' \
  'x == y || (x != x && y != y)' 'x == y'
prove_caught "the dump writes control characters raw" 'the dump reads back: refused with' \
  'if b == 34_u8 || b == 92_u8 || b < 32_u8 || b == 127_u8' 'if b == 34_u8 || b == 92_u8'
prove_caught "the dump writes NaN as the prelude spells it" "the dump reads back: refused with 'N' cannot start a value" \
  $'    return "nan" if f != f\n' ''
prove_caught "the dump writes the empty key bare" 'cannot start a key' \
  $'    return quoted(key) if key.empty?\n' ''
prove_caught "an integer past Int32 is narrowed" 'an integer past Int32 is refused' \
  'raise "integer #{v} out of Int32 range" if v < -2147483648_i64 || v > 2147483647_i64' 'raise "integer #{v} out of Int32 range" if v < -2147483648_i64 || v > 4294967296_i64'
prove_caught "a field's default is not asked for" 'missing keys keep their defaults' \
  'ivar.has_default_value? } %}' 'ivar.has_default_value? && false } %}'

# The Python comparison is proven by a broken copy too: `\f` read as a
# vertical tab. The records are printed before any check of the reader's
# values can stop the program, so tomllib sees the difference.
echo
echo "== proving the Python comparison can fail when \\f is read as U+000B"
if [ -z "$PY" ]; then
  echo "  no python3 with tomllib, so the comparison could not be proven"
  status=1
elif ! patch_module $'    elsif e == 102_u8\n      simple = 12_u8' $'    elsif e == 102_u8\n      simple = 11_u8' "$WORK/patched_f"; then
  echo "  the patch did not apply"
  status=1
elif ! IYI_PATH="$WORK/patched_f${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/broken_f" "$EXERCISE" >"$WORK/broken_f.log" 2>&1; then
  echo "  the broken copy did not compile"
  status=1
else
  "$WORK/broken_f" >"$WORK/broken_f.out" 2>&1
  if compare_records "$WORK/broken_f.out" >"$WORK/broken_f.compare" 2>&1; then
    echo "  tomllib agreed with a reader that reads \\f wrongly"
    status=1
  else
    echo "  caught: $(grep -c 'tomllib reads other data' "$WORK/broken_f.compare") records read to other data"
  fi
fi

echo
echo "== doc, format, other platforms and artifacts"
if "$IYI" doc "$REPO/src/std/toml.iyi" >"$WORK/doc.txt" 2>&1; then
  echo "  iyi doc reads std/toml ($(grep -c '^ *def ' "$WORK/doc.txt") methods)"
else
  echo "  iyi doc fails: $(grep -m1 -E 'Error|BUG' "$WORK/doc.txt")"
  status=1
fi
if [ -x "$REPO/bin/crystal" ]; then
  if "$IYI" fmt --check "$REPO/src/std/toml.iyi" "$EXERCISE" >"$WORK/format.log" 2>&1; then
    echo "  the module and its exercise are formatted"
  else
    echo "  not formatted: $(grep -m1 produced "$WORK/format.log")"
    status=1
  fi
fi
apart=""
for target in x86_64-linux-gnu aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  if ! "$IYI" build --no-codegen --target "$target" -o "$WORK/cross" "$EXERCISE" >"$WORK/cross.log" 2>&1; then
    echo "  $target: $(grep -m1 -E 'Error|BUG' "$WORK/cross.log")"
    apart="$apart $target"
  fi
done
if [ -n "$apart" ]; then
  echo "  FAIL: the exercise does not typecheck for:$apart"
  status=1
else
  echo "  the exercise typechecks for x86_64-linux-gnu, aarch64-darwin, x86_64-windows-msvc, aarch64-linux-gnu, x86_64-linux-musl"
fi
mkdir -p "$WORK/r1/mods"
if (cd "$WORK/r1" && "$IYI" build --emit-iyimod mods -o from-source "$EXERCISE" \
  && "$IYI" build --use-iyimod mods -o from-artifact "$EXERCISE") >"$WORK/r1/build.log" 2>&1; then
  "$WORK/r1/from-source" >"$WORK/r1/source.out" 2>&1
  "$WORK/r1/from-artifact" >"$WORK/r1/artifact.out" 2>&1
  if cmp -s "$WORK/r1/source.out" "$WORK/r1/artifact.out" && grep -q "ALL CHECKS PASSED" "$WORK/r1/artifact.out"; then
    echo "  built from its artifacts, the exercise prints what it prints from source"
  else
    echo "  from its artifacts the exercise prints otherwise:"
    diff "$WORK/r1/source.out" "$WORK/r1/artifact.out" | sed -n '1,6p' | sed 's/^/    /'
    status=1
  fi
else
  echo "  the artifacts did not build: $(grep -m1 -E 'Error|BUG' "$WORK/r1/build.log")"
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/toml exercise holds ($mutations broken copies caught)"
else
  echo "the std/toml exercise did not hold"
fi
exit $status
