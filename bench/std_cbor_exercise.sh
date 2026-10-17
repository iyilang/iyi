#!/usr/bin/env bash
# Exercises `std/cbor`: RFC 8949's CBOR decoded, encoded in core
# deterministic encoding and written as diagnostic notation. The exercise
# reads every example of the RFC's Appendix A to the notation printed
# beside it and writes each back, refuses every example of Appendix F with
# its sentence, round-trips a generated corpus and three other
# serializations of each value, decodes 20,000 random and mutated inputs
# in a task that must not panic, nests to DEPTH_LIMIT, and derives beside
# std/json, std/yaml and std/toml. Python then decodes the same bytes with
# a decoder of its own written here over its standard library - `struct`
# for half, single and double floats, the strict UTF-8 codec, `int` for
# bignums, `json.dumps` for the strings of the notation - and must agree:
# the RFC's notation for its own examples, the same notation and the same
# deterministic encoding for every corpus value and variant, the same
# refusals, the same verdict on every fuzzed input, and each derived
# record's CBOR equal to its JSON. Broken copies of the module prove each
# check can fail, at the check that names what was broken.
#
#     bash bench/std_cbor_exercise.sh
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

# Python is the other decoder and the patcher; a machine can answer
# `python3` with a stub that prints a refusal instead of running, so the
# interpreter is proven to run, and to pack half floats (3.6 and later),
# before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import struct; struct.pack(">e", 1.0)' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
EXERCISE="$REPO/bench/std_cbor_exercise.iyi"

# What the person reading the gate sees: the exercise's own lines, not its
# records for Python, nor the sentences of the panics it provokes in tasks
# on purpose.
shown() {
  grep -v -E '^(RFC|CORPUS|VARIANT|INVALID|FUZZ|DERIVE) |^iyi: panic: ' "$1" | sed 's/^/  /'
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
    grep -m1 'ASSERTION FAILED' "$WORK/$name.out" | sed 's/^/  /'
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/cbor exercise, plain build"
build_and_run "plain" cbor-plain && shown "$WORK/cbor-plain.out"
if ! grep -q "ALL CHECKS PASSED" "$WORK/cbor-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every cbor section reported"
missing=0
for phrase in "== RFC 8949 appendix A, decoded to its notation" "== RFC 8949 appendix A, encoded" \
  "== RFC 8949 appendix F, not well-formed" "== integers and bignums" "== floats, every width" \
  "== deterministic encoding" "== text strings are UTF-8" "== a generated corpus round-tripped" \
  "== random and mutated bytes, decoded in a task" "== nesting, DEPTH_LIMIT and declared lengths" \
  "== diagnostic notation" "== Any" "== derive cbor_serializable"; do
  if ! grep -qxF "$phrase" "$WORK/cbor-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    missing=1
    status=1
  fi
done
[ "$missing" -eq 0 ] && echo "  all thirteen sections reported"

echo
echo "== the same program with optimisation on (--release)"
if build_and_run "release" cbor-release --release; then
  if ! grep -q "ALL CHECKS PASSED" "$WORK/cbor-release.out"; then
    echo "  release: missing pass sentinel"
    status=1
  elif cmp -s "$WORK/cbor-plain.out" "$WORK/cbor-release.out"; then
    echo "  passes, and prints every line and record the plain build prints"
  else
    echo "  passes, but prints otherwise than the plain build:"
    diff "$WORK/cbor-plain.out" "$WORK/cbor-release.out" | sed -n '1,6p' | sed 's/^/    /'
    status=1
  fi
fi

# The records against Python's own decoder: answers 0 when every record
# agrees, 1 on a disagreement, 2 with no records at all.
compare_records() {
  RECORDS="$1" "$PY" - <<'PY'
import json, math, os, struct, sys

LIMIT = 64  # the module's DEPTH_LIMIT

class Refused(Exception):
    pass

# A data item as a tuple: ("int", n), ("float", bits), ("bytes", b,
# chunks), ("text", s, chunks), ("array", items, indefinite), ("map",
# pairs, indefinite), ("tag", n, item), ("simple", n), ("false",),
# ("true",), ("null",), ("undefined",). Chunks are None for a definite
# string, else the list of chunk byte strings. Integers are Python's,
# bignums too; a float is its 64 bits.

def double_bits(x):
    return int.from_bytes(struct.pack(">d", x), "big")

def half_bits(h):
    if (h >> 10) & 0x1F == 0x1F:
        return ((h & 0x8000) << 48) | 0x7FF0000000000000 | ((h & 0x3FF) << 42)
    return double_bits(struct.unpack(">e", h.to_bytes(2, "big"))[0])

def single_bits(s):
    if (s >> 23) & 0xFF == 0xFF:
        return ((s & 0x80000000) << 32) | 0x7FF0000000000000 | ((s & 0x7FFFFF) << 29)
    return double_bits(struct.unpack(">f", s.to_bytes(4, "big"))[0])

def head(major, n):
    if n < 24:
        return bytes([major << 5 | n])
    for info, size in ((24, 1), (25, 2), (26, 4), (27, 8)):
        if n < 1 << (8 * size):
            return bytes([major << 5 | info]) + n.to_bytes(size, "big")
    raise ValueError(n)

# The shortest float holding the same 64 bits. A NaN is narrowed by its
# bits; anything else by packing and unpacking through `struct`, which
# raises OverflowError past a format's range.
def encode_float(bits):
    x = struct.unpack(">d", bits.to_bytes(8, "big"))[0]
    if x != x:
        sign, mant = bits >> 63, bits & ((1 << 52) - 1)
        if mant & ((1 << 42) - 1) == 0:
            return b"\xf9" + (sign << 15 | 0x7C00 | mant >> 42).to_bytes(2, "big")
        if mant & ((1 << 29) - 1) == 0:
            return b"\xfa" + (sign << 31 | 0x7F800000 | mant >> 29).to_bytes(4, "big")
        return b"\xfb" + bits.to_bytes(8, "big")
    for fmt, prefix in ((">e", b"\xf9"), (">f", b"\xfa")):
        try:
            packed = struct.pack(fmt, x)
        except OverflowError:
            continue
        if double_bits(struct.unpack(fmt, packed)[0]) == bits:
            return prefix + packed
    return b"\xfb" + bits.to_bytes(8, "big")

def encode(node):
    kind = node[0]
    if kind == "int":
        n = node[1]
        major, m = (0, n) if n >= 0 else (1, -1 - n)
        if m < 1 << 64:
            return head(major, m)
        raw = m.to_bytes((m.bit_length() + 7) // 8, "big")
        return head(6, 2 + major) + head(2, len(raw)) + raw
    if kind == "float":
        return encode_float(node[1])
    if kind == "bytes":
        return head(2, len(node[1])) + node[1]
    if kind == "text":
        raw = node[1].encode("utf-8")
        return head(3, len(raw)) + raw
    if kind == "array":
        return head(4, len(node[1])) + b"".join(encode(x) for x in node[1])
    if kind == "map":
        pairs = sorted((encode(k), encode(v)) for k, v in node[1])
        return head(5, len(pairs)) + b"".join(k + v for k, v in pairs)
    if kind == "tag":
        return head(6, node[1]) + encode(node[2])
    if kind == "simple":
        return bytes([0xE0 | node[1]]) if node[1] < 24 else bytes([0xF8, node[1]])
    return {"false": b"\xf4", "true": b"\xf5", "null": b"\xf6", "undefined": b"\xf7"}[kind]

def decode(data, deterministic=False):
    pos = 0
    problems = []
    n = len(data)

    def read_head():
        nonlocal pos
        if pos >= n:
            raise Refused("the data ends")
        b = data[pos]
        pos += 1
        major, info = b >> 5, b & 31
        if info < 24:
            return major, info, info
        if info < 28:
            size = 1 << (info - 24)
            if n - pos < size:
                raise Refused("the data ends in a head")
            arg = int.from_bytes(data[pos:pos + size], "big")
            pos += size
            if deterministic and major != 7 and arg < (24, 256, 65536, 1 << 32)[info - 24]:
                problems.append("a longer head than needed")
            return major, info, arg
        if info < 31:
            raise Refused("reserved additional information")
        return major, info, None

    def string(major, raw, chunks):
        if major == 2:
            return ("bytes", raw, chunks)
        try:
            for piece in (chunks if chunks is not None else [raw]):
                piece.decode("utf-8")
            return ("text", raw.decode("utf-8"), None if chunks is None else [c.decode("utf-8") for c in chunks])
        except UnicodeDecodeError:
            problems.append("not UTF-8")
            return ("text", raw.decode("utf-8", "replace"), None)

    def item(depth):
        nonlocal pos
        major, info, arg = read_head()
        if arg is None and major in (0, 1, 6):
            raise Refused("an indefinite length where there is none")
        if major == 0:
            return ("int", arg)
        if major == 1:
            return ("int", -1 - arg)
        if major in (2, 3):
            if arg is not None:
                if arg > n - pos:
                    raise Refused("a length past the data")
                raw = data[pos:pos + arg]
                pos += arg
                return string(major, raw, None)
            if deterministic:
                problems.append("an indefinite length")
            chunks = []
            while True:
                if pos >= n:
                    raise Refused("no break")
                if data[pos] == 0xFF:
                    pos += 1
                    break
                if data[pos] >> 5 != major or data[pos] & 31 == 31:
                    raise Refused("a chunk of the wrong kind")
                _, _, size = read_head()
                if size > n - pos:
                    raise Refused("a length past the data")
                chunks.append(data[pos:pos + size])
                pos += size
            return string(major, b"".join(chunks), chunks)
        if major == 4:
            if depth >= LIMIT:
                raise Refused("too deep")
            items = []
            if arg is not None:
                if arg > n - pos:
                    raise Refused("a count past the data")
                for _ in range(arg):
                    items.append(item(depth + 1))
                return ("array", items, False)
            if deterministic:
                problems.append("an indefinite length")
            while True:
                if pos >= n:
                    raise Refused("no break")
                if data[pos] == 0xFF:
                    pos += 1
                    return ("array", items, True)
                items.append(item(depth + 1))
        if major == 5:
            if depth >= LIMIT:
                raise Refused("too deep")
            if arg is None:
                if deterministic:
                    problems.append("an indefinite length")
            elif arg > n - pos:
                raise Refused("a count past the data")
            pairs, seen, previous, count = [], set(), None, 0
            while arg is None or count < arg:
                if arg is None:
                    if pos >= n:
                        raise Refused("no break")
                    if data[pos] == 0xFF:
                        pos += 1
                        break
                start = pos
                key = item(depth + 1)
                raw = data[start:pos]
                identity = encode(key)
                twice = identity in seen
                if twice:
                    problems.append("a key twice")
                seen.add(identity)
                if deterministic and previous is not None and not raw > previous:
                    problems.append("keys out of order")
                previous = raw
                value = item(depth + 1)
                if not twice:
                    pairs.append((key, value))
                count += 1
            return ("map", pairs, arg is None)
        if major == 6:
            if depth >= LIMIT:
                raise Refused("too deep")
            content = item(depth + 1)
            if arg not in (2, 3):
                return ("tag", arg, content)
            if content[0] != "bytes":
                problems.append("a bignum around something else")
                return ("tag", arg, content)
            magnitude = int.from_bytes(content[1], "big")
            if deterministic and (content[1][:1] == b"\x00" or magnitude < 1 << 64):
                problems.append("a bignum not preferred")
            return ("int", magnitude if arg == 2 else -1 - magnitude)
        if info < 20:
            return ("simple", info)
        if info < 24:
            return (("false",), ("true",), ("null",), ("undefined",))[info - 20]
        if info == 24:
            if arg < 32:
                raise Refused("a simple value under 32 in two bytes")
            return ("simple", arg)
        if info == 31:
            raise Refused("a break where an item was due")
        bits = half_bits(arg) if info == 25 else single_bits(arg) if info == 26 else arg
        if deterministic and len(encode_float(bits)) < 1 + (1 << (info - 24)):
            problems.append("a wider float than needed")
        return ("float", bits)

    node = item(0)
    if pos != n:
        raise Refused("bytes after the item")
    if problems:
        raise Refused(problems[0])
    return node

# ECMAScript's Number::toString over the shortest digits Python's repr
# finds, with a fraction always, as Appendix A writes floats.
def float_text(bits):
    x = struct.unpack(">d", bits.to_bytes(8, "big"))[0]
    if x != x:
        return "NaN"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    sign = "-" if bits >> 63 else ""
    if x == 0:
        return sign + "0.0"
    mantissa, _, exponent = repr(abs(x)).partition("e")
    whole, _, fraction = mantissa.partition(".")
    digits = whole + fraction
    point = len(whole) + (int(exponent) if exponent else 0)
    stripped = digits.lstrip("0")
    point -= len(digits) - len(stripped)
    digits = stripped.rstrip("0") or "0"
    k = len(digits)
    if k <= point <= 21:
        text = digits + "0" * (point - k) + ".0"
    elif 0 < point <= 21:
        text = digits[:point] + "." + digits[point:]
    elif -6 < point <= 0:
        text = "0." + "0" * -point + digits
    else:
        e = point - 1
        text = digits[0] + "." + (digits[1:] or "0") + "e" + ("+" if e > 0 else "-") + str(abs(e))
    return sign + text

def notation(node):
    kind = node[0]
    if kind == "int":
        return str(node[1])
    if kind == "float":
        return float_text(node[1])
    if kind == "bytes":
        if node[2] is None:
            return "h'" + node[1].hex() + "'"
        if not node[2]:
            return "''_"
        return "(_ " + ", ".join("h'" + c.hex() + "'" for c in node[2]) + ")"
    if kind == "text":
        if node[2] is None:
            return json.dumps(node[1])
        if not node[2]:
            return '""_'
        return "(_ " + ", ".join(json.dumps(c) for c in node[2]) + ")"
    if kind == "array":
        return "[" + ("_ " if node[2] else "") + ", ".join(notation(x) for x in node[1]) + "]"
    if kind == "map":
        return "{" + ("_ " if node[2] else "") + ", ".join(notation(k) + ": " + notation(v) for k, v in node[1]) + "}"
    if kind == "tag":
        return str(node[1]) + "(" + notation(node[2]) + ")"
    if kind == "simple":
        return "simple(" + str(node[1]) + ")"
    return kind

# What JSON makes of a derived record: a byte string is std/json's array
# of small integers.
def plain(node):
    kind = node[0]
    if kind in ("int", "text"):
        return node[1]
    if kind == "float":
        return struct.unpack(">d", node[1].to_bytes(8, "big"))[0]
    if kind == "bytes":
        return list(node[1])
    if kind == "array":
        return [plain(x) for x in node[1]]
    if kind == "map":
        return {plain(k): plain(v) for k, v in node[1]}
    return {"false": False, "true": True, "null": None}[kind]

def accepts(hexed, deterministic=False):
    try:
        decode(bytes.fromhex(hexed), deterministic)
        return True
    except Refused:
        return False

sys.setrecursionlimit(10000)
lines = open(os.environ["RECORDS"], encoding="utf-8", errors="replace").read().split("\n")
counts = {"RFC": 0, "CORPUS": 0, "VARIANT": 0, "INVALID": 0, "FUZZ": 0, "DERIVE": 0}
bad = 0
def disagree(n, what):
    global bad
    bad += 1
    if bad <= 12:
        print(f"    record {n}: {what}")
for n, line in enumerate(lines, 1):
    kind, _, rest = line.partition(" ")
    if kind not in counts:
        continue
    counts[kind] += 1
    fields = rest.split("\t")
    try:
        if kind == "RFC":
            said = notation(decode(bytes.fromhex(fields[0])))
            if said != fields[1]:
                disagree(n, f"Python writes {fields[0]} as {said}, the RFC as {fields[1]}")
        elif kind == "CORPUS":
            node = decode(bytes.fromhex(fields[0]), True)
            if notation(node) != fields[1]:
                disagree(n, f"Python writes {fields[0][:60]} as {notation(node)[:80]}, std/cbor as {fields[1][:80]}")
            if encode(node).hex() != fields[0]:
                disagree(n, f"Python encodes {fields[0][:60]} as {encode(node).hex()[:60]}")
        elif kind == "VARIANT":
            node = decode(bytes.fromhex(fields[0]))
            if notation(node) != fields[2]:
                disagree(n, f"Python writes {fields[0][:60]} as {notation(node)[:80]}, std/cbor as {fields[2][:80]}")
            if encode(node).hex() != fields[1]:
                disagree(n, f"Python encodes {fields[0][:60]} as {encode(node).hex()[:60]}, std/cbor as {fields[1][:60]}")
            if accepts(fields[0], True) != (fields[0] == fields[1]):
                disagree(n, f"Python's deterministic verdict on {fields[0][:60]} differs")
        elif kind == "INVALID":
            if accepts(fields[0], fields[1] == "1"):
                disagree(n, f"Python accepts {fields[0][:60]}, which std/cbor refuses")
        elif kind == "FUZZ":
            try:
                node = decode(bytes.fromhex(fields[0]))
            except Refused as error:
                if fields[1] == "1":
                    disagree(n, f"Python refuses {fields[0]} ({error}), which std/cbor reads")
                continue
            if fields[1] != "1":
                disagree(n, f"Python reads {fields[0]} as {notation(node)[:80]}, which std/cbor refuses")
            elif notation(node) != fields[2]:
                disagree(n, f"Python writes {fields[0]} as {notation(node)[:80]}, std/cbor as {fields[2][:80]}")
            elif accepts(fields[0], True) != (fields[3] == "1"):
                disagree(n, f"Python's deterministic verdict on {fields[0]} differs")
        else:
            node = decode(bytes.fromhex(fields[1]), True)
            if plain(node) != json.loads(fields[0]):
                disagree(n, "Python reads the record's CBOR to other data than its JSON")
            if encode(node).hex() != fields[1]:
                disagree(n, "Python encodes the record's CBOR otherwise")
    except Refused as error:
        disagree(n, f"{kind}: Python refuses {fields[0][:60]}: {error}")
    except Exception as error:
        disagree(n, f"{kind}: {type(error).__name__}: {error}")
print("    " + ", ".join(f"{counts[k]} {k}" for k in counts) + ": " + ("all agree" if bad == 0 else f"{bad} disagree"))
if sum(counts.values()) == 0:
    sys.exit(2)
sys.exit(1 if bad else 0)
PY
}

echo
echo "== Python's own decoder reads the same bytes to the same items"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so no other decoder was asked"
  status=1
else
  compare_records "$WORK/cbor-plain.out"
  case $? in
    0) ;;
    2) echo "  the exercise printed no records"; status=1 ;;
    *) echo "  Python and std/cbor disagree"; status=1 ;;
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

import std/cbor::{CBOR, Any, CBORTag, CBORSimple, cbor_serializable}

struct Spot
  getter x : Float64
  getter name : String

  derive cbor_serializable
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
refuse_program missing 'CBOR for Spot has no key "name"' 'Spot.from_cbor(CBOR.to_cbor({"x" => 1.0}))'
refuse_program map 'expected a map for Spot, not an array' 'Spot.new(Any.new([Any.new(1)]))'
refuse_program kind 'expected a float, not a text string' 'Spot.from_cbor(CBOR.to_cbor({"x" => "one", "name" => "a"}))'
refuse_program bytes 'the data ends where a data item was due at byte 3' 'Spot.from_cbor([0xA2_u8, 0x61_u8, 0x78_u8])'
refuse_program or_panic 'a break code where a data item was due at byte 0' 'CBOR.decode([0xFF_u8]).or_panic'
refuse_program uint8 'integer 256 out of UInt8 range' 'puts CBOR.from_cbor(CBOR.to_cbor(256), UInt8)'
refuse_program bignum_tag "CBORTag: tag 2 is a bignum, an integer's encoding: make the integer, with CBORBignum past Int64" 'CBORTag.new(2_u64, Any.new(1))'
refuse_program simple_bool 'CBORSimple: 21 is false, true or null, which are Bool and nil' 'CBORSimple.new(21)'
refuse_program simple_reserved 'CBORSimple: 24 is not a simple value; 24 to 31 are reserved' 'CBORSimple.new(24)'
refuse_program simple_range 'CBORSimple: 256 is outside 0 to 255' 'CBORSimple.new(256)'
refuse_program text 'CBOR.encode: a text string must be UTF-8, and this one is not at its byte 1' 'CBOR.encode(Any.new("a\xFFb"))'

# One proof per check: the module is copied with one site patched back to
# a plausible mistake, and the exercise must then fail at the check that
# names it, not merely fail. Each copy is built before it is run, so a
# patch that does not compile is not taken for a caught one.
mutations=0
patch_module() {
  local old="$1" new="$2" dest="$3"
  rm -rf "$dest"
  mkdir -p "$dest/std"
  OLD="$old" NEW="$new" "$PY" - "$REPO/src/std/cbor.iyi" "$dest/std/cbor.iyi" <<'PY'
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
  elif ! grep 'ASSERTION FAILED' "$WORK/mut.out" | head -1 | grep -qF -- "$message"; then
    echo "  the exercise failed, but not at \"$message\":"
    { grep -m1 'ASSERTION FAILED' "$WORK/mut.out" || tail -2 "$WORK/mut.out"; } | cut -c1-200 | sed 's/^/    /'
    status=1
  else
    echo "  caught: $(grep -m1 'ASSERTION FAILED' "$WORK/mut.out" | cut -c1-160)"
  fi
}

# Floats.
prove_caught "a float is shortened though its low bits are not zero" 'appendix A: fb3ff199999999999a is deterministic' \
  $'      return nil unless (m & lost) == 0_u64\n      return sign | (exp + bias)' '      return sign | (exp + bias)'
prove_caught "a NaN is shortened though its payload is not zero where it is cut" 'the float with bits 7ff0000000000001 encodes in the shortest width' \
  $'      return nil unless (m & lost) == 0_u64\n      return sign | ebits_max' '      return sign | ebits_max'
prove_caught "the least subnormal of a width is not shortened to it" 'appendix A encodes 5.960464477539063e-8' \
  'if exp >= -tiny && exp < 1 - bias' 'if exp > -tiny && exp < 1 - bias'
prove_caught "a half subnormal is read one binade low" 'appendix A decodes f90001' \
  'sign | (top - 24 + 1023)' 'sign | (top - 25 + 1023)'
prove_caught "the notation turns to an exponent below 1e-4, as Float64#to_s does, not below 1e-6" 'appendix A decodes f90400 to 0.00006103515625' \
  'elsif -6 < n && n <= 0' 'elsif -4 < n && n <= 0'

# Integers.
prove_caught "a negative integer is written as -n, not -1 - n" 'appendix A encodes -1' \
  'head(1, (-1_i64 - r).to_u64)' 'head(1, (0_i64 - r).to_u64)'
prove_caught "major type 1 is read as -n, not -1 - n" 'appendix A decodes 20 to -1' \
  'Any.new(negative ? -1_i64 - n.to_i64 : n.to_i64)' 'Any.new(negative ? 0_i64 - n.to_i64 : n.to_i64)'
prove_caught "tag 3 is read as a positive bignum" 'appendix A decodes c349010000000000000000' \
  'big = CBORBignum.new(number == 3_u64, bytes)' 'big = CBORBignum.new(false, bytes)'
prove_caught "-1 - n in decimal drops the carry past the top byte" 'appendix A decodes 3bffffffffffffffff to -18446744073709551616' \
  $'      digits.unshift(1_u8) if carry\n' ''

# Map keys.
prove_caught "map keys are sorted length first, as RFC 7049's canonical CBOR did" 'the keys of section 4.2.1 sort as it lists them' \
  'keyed.sort_in_place { |a, b| Encoder.compare(a[0], b[0]) }' 'keyed.sort_in_place { |a, b| a[0].size != b[0].size ? a[0].size - b[0].size : Encoder.compare(a[0], b[0]) }'
prove_caught "deterministic decoding takes keys out of order" 'accepted a2616201616102' \
  'if @deterministic && last_from >= 0 && !after?(last_from, last_to, from, @pos)' 'if false && @deterministic && last_from >= 0 && !after?(last_from, last_to, from, @pos)'
prove_caught "a map key may be written twice" 'the refusal of a201010102' \
  'twice = pairs.has_key?(key)' 'twice = false'

# Indefinite-length strings.
prove_caught "an indefinite-length string takes a chunk of another major type" 'appendix F refuses 5f00ff' \
  'if b >> 5 != major' 'if false'
prove_caught "an indefinite-length string takes an indefinite-length chunk" 'appendix F refuses 5f5f4100ffff' \
  'if b & 31 == 31' 'if false'

# Well-formedness, limits, determinism.
prove_caught "a simple value under 24 is read in the two-byte form" 'appendix F refuses f800' \
  'take", start) if v < 32' 'take", start) if v >= 24 && v < 32'
prove_caught "a count is not held to the bytes left" 'appendix F refuses 81' \
  $'    left = @size - @pos\n    if @arg > left.to_u64\n      fail("#{what}' $'    left = @size - @pos\n    if @arg > left.to_u64 + 65536_u64\n      fail("#{what}'
prove_caught "bytes after the item are passed over" 'accepted 0000' \
  $'    if @pos < @size\n      return CBORError' $'    if false\n      return CBORError'
prove_caught "arrays nest without bound" 'accepted 8181818181' \
  $'  private def array(depth : Int32, start : Int32) : Any?\n    return too_deep(depth, start) if depth >= DEPTH_LIMIT\n' $'  private def array(depth : Int32, start : Int32) : Any?\n'
prove_caught "deterministic decoding takes a longer head than needed" 'accepted 1817' \
  'if @deterministic && @major != 7 && v < Decoder.least_for(@info)' 'if false && @deterministic && @major != 7 && v < Decoder.least_for(@info)'

# UTF-8.
prove_caught "an overlong UTF-8 form is text" 'accepted 62c0af' \
  'if b >= 0xC2_u8 && b <= 0xDF_u8' 'if b >= 0xC0_u8 && b <= 0xDF_u8'
prove_caught "a UTF-8 surrogate is text" 'accepted 63eda080' \
  'high = 0x9F_u8 if b == 0xED_u8' 'high = 0xBF_u8 if b == 0xED_u8'

# The Python comparison is proven by a broken copy too: a tab written as
# `\u0009` in the notation, where `json.dumps` writes `\t`. The corpus
# records are printed before the notation section can stop the program,
# so Python sees the difference.
echo
echo "== proving the Python comparison can fail when a tab is written as \\u0009"
if [ -z "$PY" ]; then
  echo "  no python3, so the comparison could not be proven"
  status=1
elif ! patch_module '@out << "\\t"' 'escape(b)' "$WORK/patched_tab"; then
  echo "  the patch did not apply"
  status=1
elif ! IYI_PATH="$WORK/patched_tab${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/broken_tab" "$EXERCISE" >"$WORK/broken_tab.log" 2>&1; then
  echo "  the broken copy did not compile"
  status=1
else
  "$WORK/broken_tab" >"$WORK/broken_tab.out" 2>&1
  if compare_records "$WORK/broken_tab.out" >"$WORK/broken_tab.compare" 2>&1; then
    echo "  Python agreed with a notation that writes a tab as \\u0009"
    status=1
  else
    echo "  caught: $(tail -1 "$WORK/broken_tab.compare" | sed 's/^ *//')"
  fi
fi

echo
echo "== doc, format, other platforms and artifacts"
if "$IYI" doc "$REPO/src/std/cbor.iyi" >"$WORK/doc.txt" 2>&1; then
  echo "  iyi doc reads std/cbor ($(grep -c '^ *def ' "$WORK/doc.txt") methods)"
else
  echo "  iyi doc fails: $(grep -m1 -E 'Error|BUG' "$WORK/doc.txt")"
  status=1
fi
if [ -x "$REPO/bin/crystal" ]; then
  if "$REPO/bin/crystal" tool format --check "$REPO/src/std/cbor.iyi" "$EXERCISE" >"$WORK/format.log" 2>&1; then
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
  echo "the std/cbor exercise holds ($mutations broken copies caught)"
else
  echo "the std/cbor exercise did not hold"
fi
exit $status
