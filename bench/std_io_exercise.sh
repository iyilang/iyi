#!/usr/bin/env bash
# Exercises `std/io`: `Memory`, the `IyiIO` additions, `Sized`, `Delimited`,
# `MultiWriter`, `Hexdump` and `ByteFormat`.
#
#     bash bench/std_io_exercise.sh
#
# Proves:
#   * The exercise holds plain and --release: Memory read/write/lines/read_all/
#     gets, the additions on a file read four bytes at a time, ByteFormat round
#     trips, Sized/Delimited byte-exact on UTF-8, Hexdump lines, MultiWriter.
#   * Every ByteFormat encoding the program prints (negative, minimum, maximum
#     Int32/Int64, UInt64, UInt8, both byte orders) equals python3 `struct`'s.
#   * The Hexdump lines the program prints equal python3's `hexdump -C` for the
#     same bytes.
#   * The Delimited and Sized answers on UTF-8 input are the exact bytes.
#   * Negative proofs: a patched copy of the module that breaks the two's
#     complement, the delimiter match, or the line end is caught by name.
#   * What the module refuses: a negative count, a position past the buffer, a
#     write to a reader, a read from a writer, a decode that runs out of bytes,
#     malformed UTF-8 (a stray continuation byte, a lead byte that is not one,
#     an overlong form, a surrogate, a code point past U+10FFFF), a read after
#     close - each a panic with a sentence.
#   * Dependency floor: the exercise binary asks the machine for nothing new.
#
# Needs bin/iyi, python3, `nm`, and `otool` on Darwin or `readelf` on
# Linux. Exits non-zero if any check fails.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/floor_base.sh"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

export IYI_PATH="$REPO/src:$REPO/samples/iyi"

symbols() {
  nm -u "$1" 2>/dev/null |
    sed -e 's/^ *//' -e 's/^U  *//' -e 's/@.*$//' |
    awk '{ print $NF }' |
    sed -e 's/^_//' |
    grep -v '^$' |
    sort -u
}

libraries() {
  if command -v otool >/dev/null 2>&1; then
    otool -L "$1" 2>/dev/null | sed -n '2,$p' | awk '{ print $1 }' | sed 's|.*/||' | sort -u
  else
    readelf -d "$1" 2>/dev/null |
      sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' |
      sed 's|.*/||' | sort -u
  fi
}

unexpected() {
  local allowed="$1" found="$2" item keep ok
  for item in $found; do
    keep=no
    for ok in $allowed; do
      case "$item" in "$ok"*) keep=yes ;; esac
    done
    [ "$keep" = no ] && printf '%s\n' "$item"
  done
  return 0
}

build_and_run() {
  local label="$1" name="$2" source="$3"
  shift 3
  if ! "$IYI" build "$@" -o "$WORK/$name" "$source" >"$WORK/$name.build.log" 2>&1; then
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

echo "== the std/io exercise"
build_and_run "std_io" exercise-io "$REPO/bench/std_io_exercise.iyi"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "std_io, release" exercise-io-release "$REPO/bench/std_io_exercise.iyi" --release >/dev/null
if grep -q "ALL CHECKS PASSED" "$WORK/exercise-io-release.out" 2>/dev/null; then
  echo "  the release build reached the end"
else
  echo "  MISSING: the release build did not reach the end"
  status=1
fi

echo
echo "== every io check reported"
for check in "== memory" "== descriptor stream" "== byte format" "== sized and delimited" "== hexdump" "== multi writer" "ALL CHECKS PASSED"; do
  if ! grep -q "$check" "$WORK/exercise-io.out" 2>/dev/null; then
    echo "  MISSING: $check"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  memory, descriptor stream, byte format, sized/delimited, hexdump and multi writer all reported"

# ---------------------------------------------------------------------------
# Oracles: python3's struct for every encoding, python3's hexdump -C for every dump
# ---------------------------------------------------------------------------

echo
echo "== every ByteFormat encoding against python3 struct"
grep -E '^  (LE|BE) (Int32|Int64|UInt64|UInt8) ' "$WORK/exercise-io.out" > "$WORK/encodings.iyi.txt"
python3 - "$WORK/encodings.iyi.txt" > "$WORK/encodings.py.txt" <<'PY'
import struct, sys
codes = {"Int32": "i", "Int64": "q", "UInt64": "Q", "UInt8": "B"}
for line in open(sys.argv[1]):
    order, kind, value, _ = line.split()
    fmt = ("<" if order == "LE" else ">") + codes[kind]
    print(f"  {order} {kind} {value} {struct.pack(fmt, int(value)).hex()}")
PY
encoded="$(wc -l < "$WORK/encodings.iyi.txt")"
if [ "$encoded" -lt 60 ]; then
  echo "  only $encoded encodings printed; the table has shrunk"
  status=1
elif diff "$WORK/encodings.iyi.txt" "$WORK/encodings.py.txt" > "$WORK/encodings.diff"; then
  echo "  all $encoded encodings (Int32, Int64, UInt64, UInt8; LE and BE; negative, min, max) agree with struct.pack"
else
  echo "  encodings differ from python3 struct:"
  sed 's/^/    /' "$WORK/encodings.diff"
  status=1
fi
for needed in "LE Int32 -1 ffffffff" "BE Int32 -2147483648 80000000" "LE Int64 -9223372036854775808 0000000000000080" "BE Int64 9223372036854775807 7fffffffffffffff" "LE UInt64 18446744073709551615 ffffffffffffffff" "BE UInt8 255 ff"; do
  if ! grep -qF -- "  $needed" "$WORK/encodings.iyi.txt"; then
    echo "  MISSING encoding: $needed"
    status=1
  fi
done

echo
echo "== every Hexdump line against python3's hexdump -C"
grep -E '^[0-9a-f]{8}  ' "$WORK/exercise-io.out" > "$WORK/dumps.iyi.txt"
python3 - "$WORK/dumps.oracle.txt" <<'PY'
import sys

def dump_c(data: bytes) -> str:
    if not data:
        return ""
    lines = []
    for offset in range(0, len(data), 16):
        chunk = data[offset:offset + 16]
        n = len(chunk)
        parts = []
        for i in range(16):
            if i == 8:
                parts.append("")
            parts.append(f"{chunk[i]:02x}" if i < n else "  ")
        ascii_str = "".join(chr(b) if 32 <= b <= 126 else "." for b in chunk)
        lines.append(f"{offset:08x}  {' '.join(parts)}  |{ascii_str}|")
    return "\n".join(lines) + "\n"

chunks = [
    b"Hello, iyi!\x00\xc3\xbf",
    bytes((i * 7 + 30) % 256 for i in range(40)),
    b"to stdout",
]
with open(sys.argv[1], "w") as out:
    for chunk in chunks:
        out.write(dump_c(chunk))
PY
if [ "$(wc -l < "$WORK/dumps.iyi.txt")" -ne 5 ]; then
  echo "  expected five dump lines on stdout, found $(wc -l < "$WORK/dumps.iyi.txt")"
  status=1
elif diff "$WORK/dumps.iyi.txt" "$WORK/dumps.oracle.txt" > "$WORK/dumps.diff"; then
  echo "  five lines (a short line, three lines of forty bytes, a stdout dump) equal hexdump -C's"
else
  echo "  dump lines differ from hexdump -C:"
  sed 's/^/    /' "$WORK/dumps.diff"
  status=1
fi

echo
echo "== Delimited and Sized answers, byte-exact"
for line in "  delimited: héllo" "  delimited: wörld" "  sized: héllo"; do
  if grep -qxF -- "$line" "$WORK/exercise-io.out"; then
    printf '%s\n' "$line"
  else
    echo "  MISSING line: $line"
    status=1
  fi
done

# ---------------------------------------------------------------------------
# Negative failure proofs
# ---------------------------------------------------------------------------

patched_fails() { # patched_fails <label> <dir> <check phrase> <python replacement expression>
  local label="$1" dir="$2" phrase="$3" replacement="$4"
  mkdir -p "$WORK/$dir/std"
  cp "$REPO/src/std/io.iyi" "$WORK/$dir/std/io.iyi"
  python3 - "$WORK/$dir/std/io.iyi" "$replacement" <<'PY'
import sys
path, replacement = sys.argv[1], sys.argv[2]
old, new = replacement.split("=>", 1)
content = open(path).read()
if old not in content:
    sys.exit("the patch found nothing to change: " + old)
open(path, "w").write(content.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi
  if (IYI_PATH="$WORK/$dir:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_io_exercise.iyi" >"$WORK/$dir.out" 2>&1); then
    echo "  $label: the exercise PASSED with the module broken (it should have failed):"
    head -15 "$WORK/$dir.out" | sed 's/^/    /'
    status=1
  elif ! grep -qF -- "$phrase" "$WORK/$dir.out"; then
    echo "  $label: the exercise failed, but not at '$phrase':"
    grep -m1 'panic' "$WORK/$dir.out" | sed 's/^/    /'
    status=1
  else
    echo "  $label: caught at '$phrase'"
  fi
}

echo
echo "== negative proof: a broken two's complement is caught"
patched_fails "Int64 negatives off by one" patched_bits "LE Int64 round trip of -1" \
  '0xFFFFFFFFFFFFFFFF_u64 - (-(value + 1_i64)).to_u64=>0xFFFFFFFFFFFFFFFE_u64 - (-(value + 1_i64)).to_u64'
patched_fails "Int32 negatives off by one" patched_sign "LE Int32 round trip of -1" \
  '(bits.to_i64 - 0x100000000_i64).to_i32=>(bits.to_i64 - 0x100000000_i64 + 1_i64).to_i32'

echo
echo "== negative proof: a delimiter match that never restarts is caught"
patched_fails "held prefix dropped on mismatch" patched_delim "a partial match that restarts is content" \
  '      i = 1
      while i < held
        feed(pattern[i])
        i = i + 1
      end
      feed(b)=>      feed(b)'

echo
echo "== negative proof: a line end that is not dropped is caught"
patched_fails "chomp drops the last byte instead" patched_chomp "gets(chomp) drops the line end" \
  '      len = len - 1 if len > 0 && @buffer[start + len - 1] == 10_u8=>      len = len - 1 if len > 0 && @buffer[start + len - 1] != 10_u8'

echo
echo "== negative proof: a Sized that ignores its limit is caught"
patched_fails "Sized reads past its limit" patched_sized "read_bytes on a Sized is cut to the limit" \
  '    take = count < @remaining ? count : @remaining=>    take = count'

# ---------------------------------------------------------------------------
# What the module refuses
# ---------------------------------------------------------------------------

echo
echo "== what the module refuses"
io_panics_with() { # io_panics_with <label> <name> <phrase> <program body>
  local label="$1" name="$2" phrase="$3" body="$4"
  printf 'module main\n\nimport std/io\nusing std/io::{Memory, Sized, Delimited, MultiWriter, Hexdump, ByteFormat}\n\n%s\n' "$body" > "$WORK/$name.iyi"
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
io_panics_with "a negative count" neg_count "negative count: -1" \
  'puts Memory.new("abc").read_bytes(-1)'
io_panics_with "a negative limit" neg_limit "negative limit: -3" \
  'puts Sized.new(Memory.new("abc"), -3).read_all'
io_panics_with "a negative copy limit" neg_copy "negative limit: -2" \
  'puts IyiIO.copy(Memory.new("abc"), Memory.new, -2)'
io_panics_with "a position past the buffer" pos_past "position 9 out of range for 3 bytes" \
  'm = Memory.new("abc")
m.pos = 9
puts m.read_all'
io_panics_with "a negative position" pos_neg "position -1 out of range for 3 bytes" \
  'm = Memory.new("abc")
m.pos = -1
puts m.read_all'
io_panics_with "a read after close" closed_read "cannot read from closed IO" \
  'm = Memory.new("abc")
m.close
puts m.read_all'
io_panics_with "a write after close" closed_write "cannot write to closed IO" \
  'm = Memory.new
m.close
m.puts("late")'
io_panics_with "a write to a Sized" sized_write "cannot write to a Sized reader" \
  'Sized.new(Memory.new("abc"), 2).puts("no")'
io_panics_with "a write to a Delimited" delim_write "cannot write to a Delimited reader" \
  'Delimited.new(Memory.new("abc"), "-").puts("no")'
io_panics_with "an empty delimiter" delim_empty "empty delimiter" \
  'puts Delimited.new(Memory.new("abc"), "").read_all'
io_panics_with "a read from a MultiWriter" multi_read "cannot read from a MultiWriter" \
  'puts MultiWriter.new([Memory.new] of IyiIO).read_all'
io_panics_with "a decode that runs out of bytes" short_decode "unexpected end of input: needed 8 bytes, got 3" \
  'puts ByteFormat::BigEndian.decode_int64(Memory.new("abc"))'
io_panics_with "a lead byte that is a continuation byte" utf8_lead "malformed UTF-8: byte 169 cannot begin a character" \
  'm = Memory.new
m.write_byte(0xa9_u8)
m.rewind
puts m.read_char'
io_panics_with "a character the stream ends inside" utf8_short "truncated UTF-8: the stream ended inside a character starting with byte 226" \
  'm = Memory.new
m.write_byte(0xe2_u8)
m.write_byte(0x82_u8)
m.rewind
puts m.read_char'
io_panics_with "a continuation byte that is not one" utf8_follow "malformed UTF-8: byte 65 cannot continue a character starting with byte 195" \
  'm = Memory.new
m.write_byte(0xc3_u8)
m.write_byte(0x41_u8)
m.rewind
puts m.read_char'
# Each of these decoded before (C0 80 to U+0000, ED A0 80 to a surrogate,
# F4 90 80 80 and F7 BF BF BF to code points past U+10FFFF): the first
# continuation byte is held to the range its lead allows.
io_panics_with "an overlong two-byte lead (C0)" utf8_overlong2 "malformed UTF-8: byte 192 cannot begin a character" \
  'm = Memory.new
m.write_byte(0xc0_u8)
m.write_byte(0x80_u8)
m.rewind
puts m.read_char'
io_panics_with "an overlong three-byte form (E0 80)" utf8_overlong3 "malformed UTF-8: byte 128 cannot continue a character starting with byte 224" \
  'm = Memory.new
m.write_byte(0xe0_u8)
m.write_byte(0x80_u8)
m.write_byte(0x80_u8)
m.rewind
puts m.read_char'
io_panics_with "an overlong four-byte form (F0 80)" utf8_overlong4 "malformed UTF-8: byte 128 cannot continue a character starting with byte 240" \
  'm = Memory.new
m.write_byte(0xf0_u8)
m.write_byte(0x80_u8)
m.write_byte(0x80_u8)
m.write_byte(0x80_u8)
m.rewind
puts m.read_char'
io_panics_with "a surrogate (ED A0)" utf8_surrogate "malformed UTF-8: byte 160 cannot continue a character starting with byte 237" \
  'm = Memory.new
m.write_byte(0xed_u8)
m.write_byte(0xa0_u8)
m.write_byte(0x80_u8)
m.rewind
puts m.read_char'
io_panics_with "a code point past U+10FFFF (F4 90)" utf8_past_max "malformed UTF-8: byte 144 cannot continue a character starting with byte 244" \
  'm = Memory.new
m.write_byte(0xf4_u8)
m.write_byte(0x90_u8)
m.write_byte(0x80_u8)
m.write_byte(0x80_u8)
m.rewind
puts m.read_char'
io_panics_with "a lead byte past F4" utf8_lead_f7 "malformed UTF-8: byte 247 cannot begin a character" \
  'm = Memory.new
m.write_byte(0xf7_u8)
m.write_byte(0xbf_u8)
m.write_byte(0xbf_u8)
m.write_byte(0xbf_u8)
m.rewind
puts m.read_char'

# ---------------------------------------------------------------------------
# Dependency floor audit
# ---------------------------------------------------------------------------

echo
echo "== the dependency floor, measured against the std_io exercise binary"
case "$(uname -s)" in
  Linux)
    allowed_symbols="$FLOOR_BASE_LINUX"
    if ! command -v readelf >/dev/null 2>&1; then
      echo "  readelf is required on Linux to read NEEDED entries" >&2
      exit 2
    fi
    ;;
  *)
    # The base is every darwin program's (bench/floor_base.sh); the socket
    # and file names beside it are what this exercise's binary asks for on
    # top, each libSystem's, which the `allowed_libs` check below proves.
    allowed_symbols="$FLOOR_BASE_DARWIN accept bind chmod close connect getsockname listen open recv send setsockopt socket unlink"
    ;;
esac
allowed_libs="$FLOOR_LIBS_PROGRAM"

for binary in exercise-io exercise-io-release; do
  if [ -x "$WORK/$binary" ]; then
    io_syms="$(symbols "$WORK/$binary")"
    io_libs="$(libraries "$WORK/$binary")"
    printf '  %s symbols   %s\n' "$binary" "$(echo $io_syms)"
    printf '  %s libraries %s\n' "$binary" "$(echo $io_libs)"

    extra_syms="$(unexpected "$allowed_symbols" "$(echo $io_syms)")"
    if [ -n "$extra_syms" ]; then
      echo "  std/io asks the machine for something new:"
      echo "$extra_syms" | sed 's/^/    /'
      echo "  Each is a dependency being taken on. If that is the decision, record it"
      echo "  here and in the commit (SPEC.md III.9)."
      status=1
    fi

    extra_libs="$(unexpected "$allowed_libs" "$(echo $io_libs)")"
    if [ -n "$extra_libs" ]; then
      echo "  std/io links something new:"
      echo "$extra_libs" | sed 's/^/    /'
      status=1
    fi
    [ -z "$extra_syms$extra_libs" ] && echo "  nothing new: std/io costs zero new symbols and zero new libraries ($binary)"
  else
    echo "  no $binary binary to audit"
    status=1
  fi
done

echo
if [ "$status" -eq 0 ]; then
  echo "the std/io exercise holds"
else
  echo "the std/io exercise did not hold"
fi
exit $status
