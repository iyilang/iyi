#!/usr/bin/env bash
# Exercises `std/compress`: DEFLATE, zlib and gzip in iyi, whole and a
# piece at a time (`Inflater`, `Deflater`), against the zlib Python
# carries as the oracle in both directions.
#
#     bash bench/std_compress_exercise.sh
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

# What zlib writes, at every level and in every envelope, for iyi to read;
# and a gzip header with every optional field set.
#
# Through `compressobj`, which every Python 3 has, rather than
# `zlib.compress(data, level, wbits=...)`, whose `wbits` arrived in 3.11.
# Under an older interpreter the generator died on the first stream, the
# gate carried on against an empty fixtures directory, and the verdict it
# printed was the decoder's — "DEFLATE: the stream ends inside a block" —
# about a file that was never written. An oracle that cannot be produced
# is the gate's failure, said here, not the module's.
mkdir -p "$WORK/fixtures"
# and without an interpreter there is no oracle at all: the exercise reads the
# fixtures directory, so every check below would be measuring an empty one.
if [ -z "$PY" ]; then
  echo "no python3 on this machine: the zlib oracle cannot be written, so std/compress goes unmeasured"
  exit 0
fi
if ! "$PY" - "$WORK/fixtures" "$REPO/src/std/compress.iyi" <<'PY'
import gzip, os, random, struct, sys, zlib
out, source = sys.argv[1], sys.argv[2]

def deflate(data, level, wbits):
    c = zlib.compressobj(level, zlib.DEFLATED, wbits)
    return c.compress(data) + c.flush()

rng = random.Random(20260915)
text = b"".join(b"line %d: the quick brown fox jumps over the lazy dog %d\n" % (i, i % 7) for i in range(400))
far = bytes(rng.getrandbits(8) for _ in range(3000))
corpora = {
    "text": text,
    "zeros": b"\0" * 100000,
    "bytes": bytes(range(256)) * 40,
    "random": bytes(rng.getrandbits(8) for _ in range(70000)),
    "far": far + bytes(rng.getrandbits(8) for _ in range(20000)) + far,
    "source": open(source, "rb").read(),
}
for name, data in corpora.items():
    open(os.path.join(out, name + ".bin"), "wb").write(data)
    for level in (0, 1, 6, 9):
        open(os.path.join(out, f"{name}.{level}.raw"), "wb").write(deflate(data, level, -15))
        open(os.path.join(out, f"{name}.{level}.zlib"), "wb").write(deflate(data, level, 15))
        open(os.path.join(out, f"{name}.{level}.gzip"), "wb").write(deflate(data, level, 31))
# FTEXT|FHCRC|FEXTRA|FNAME|FCOMMENT, a subfield, a name, a comment, and the header's own CRC-16.
header = bytes([0x1f, 0x8b, 8, 0x1f]) + struct.pack("<IBB", 0, 0, 255)
extra = b"AB" + struct.pack("<H", 4) + b"wxyz"
header += struct.pack("<H", len(extra)) + extra + b"a-name.txt\0" + b"a comment\0"
header += struct.pack("<H", zlib.crc32(header) & 0xffff)
body = deflate(text, 6, -15)
open(os.path.join(out, "fields.gzip"), "wb").write(header + body + struct.pack("<II", zlib.crc32(text), len(text)))
# Python's own gzip and zlib modules, for `Inflater` to read through tiny
# reads: noise, repetition, and three members of different levels.
prng = random.Random(20261014)
python = {
    "py_random": bytes(prng.getrandbits(8) for _ in range(100000)),
    "py_repeat": b"".join(b"%d: the same few words again and again\n" % (i % 50) for i in range(8000)),
}
for name, data in python.items():
    open(os.path.join(out, name + ".bin"), "wb").write(data)
    open(os.path.join(out, name + ".gz"), "wb").write(gzip.compress(data))
    open(os.path.join(out, name + ".zlib"), "wb").write(zlib.compress(data))
    open(os.path.join(out, name + ".raw"), "wb").write(deflate(data, 6, -15))
parts = [python["py_repeat"][:30000], python["py_random"][:20000], b"the last member\n"]
open(os.path.join(out, "py_members.bin"), "wb").write(b"".join(parts))
open(os.path.join(out, "py_members.gz"), "wb").write(gzip.compress(parts[0], 9) + gzip.compress(parts[1], 1) + gzip.compress(parts[2]))
# What iyi writes at every level, for zlib to read and to size against
# its own: prose (SPEC.md), source code, JSON, noise, repetition, nothing,
# one byte, and 10 MB of the repository's text - the std modules, the
# compiler's sources and the documents, in name order.
import glob, json
repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(source))))
def read(path):
    return open(os.path.join(repo, path), "rb").read()
lrng = random.Random(20261017)
records = [{"id": i, "name": "user%d" % i, "email": "user%d@example.com" % i, "score": lrng.randint(0, 999),
            "tags": lrng.sample(["alpha", "beta", "gamma", "delta", "epsilon", "zeta"], 2), "active": lrng.random() < 0.5}
           for i in range(4000)]
tree = sorted(glob.glob(os.path.join(repo, "src/std/*.iyi"))) + sorted(glob.glob(os.path.join(repo, "src/compiler/**/*.cr"), recursive=True)) \
    + sorted(glob.glob(os.path.join(repo, "*.md")))
big = b"".join(open(p, "rb").read() for p in tree)
big = (big * (10_000_000 // len(big) + 1))[:10_000_000]
levels = {
    "l_text": read("SPEC.md"),
    "l_source": read("src/std/json.iyi") + read("src/std/http.iyi"),
    "l_json": json.dumps(records, indent=1).encode(),
    "l_random": bytes(lrng.getrandbits(8) for _ in range(200000)),
    "l_repeat": b"".join(b"%d: the same few words again and again\n" % (i % 50) for i in range(8000)),
    "l_empty": b"",
    "l_one": b"x",
    "l_big": big,
}
for name, data in levels.items():
    open(os.path.join(out, name + ".bin"), "wb").write(data)
PY
then
  echo "the zlib oracle could not be written; nothing below would be measuring the module" >&2
  exit 2
fi
# Six corpora, each `.bin` plus four levels in three envelopes, and the
# gzip header with every field: 6 * 13 + 1; then Python's two corpora in
# three envelopes and its three members, each with its `.bin`: 2 * 4 + 2;
# then the eight corpora iyi writes at every level.
fixture_count="$(find "$WORK/fixtures" -type f | wc -l | tr -d ' ')"
if [ "$fixture_count" -ne 97 ]; then
  echo "the zlib oracle wrote $fixture_count files where 97 were expected" >&2
  exit 2
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_compress_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" "$WORK/fixtures" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/compress exercise, plain build"
build_and_run "plain" compress-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/compress-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every compress section reported"
for phrase in "== round trips" "== what the match finder finds" "== levels" "== block types" "== a code held to 15 bits" \
              "== the format's own words" "== streaming inflate" \
              "== refused as a value" "== gzip members and what follows" "== deflater" "== against zlib" \
              "== streaming zlib's streams" "== python's streams through tiny reads" "== every level, for zlib to read"; do
  if ! grep -q "$phrase" "$WORK/compress-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== what iyi wrote, read by zlib"
"$PY" - "$WORK/fixtures" <<'PY' || status=1
import os, sys, zlib
d = sys.argv[1]
bad = 0
for name in ("text", "zeros", "bytes", "random", "far", "source"):
    plain = open(os.path.join(d, name + ".bin"), "rb").read()
    for env, wbits in (("raw", -15), ("zlib", 15), ("gzip", 31)):
        path = os.path.join(d, f"{name}.iyi.{env}")
        if not os.path.exists(path):
            print(f"  {name}.{env}: iyi wrote nothing"); bad += 1; continue
        stream = open(path, "rb").read()
        try:
            back = zlib.decompress(stream, wbits)
        except zlib.error as e:
            print(f"  {name}.{env}: zlib refused it: {e}"); bad += 1; continue
        if back != plain:
            print(f"  {name}.{env}: zlib read {len(back)} bytes, not the {len(plain)} written"); bad += 1; continue
    raw = os.path.getsize(os.path.join(d, name + ".iyi.raw"))
    ref = os.path.getsize(os.path.join(d, name + ".6.raw"))
    print(f"  {name}: {len(plain)} bytes, iyi {raw} against zlib level 6's {ref}")
    if raw > ref * 1.02 + 8:
        print(f"  {name}: iyi's stream is more than 2% past zlib level 6's"); bad += 1
sys.exit(1 if bad else 0)
PY

echo
echo "== what the Deflater wrote, read by zlib"
# Six pieces, each a sync flush, then the final block: zlib reads the
# stream whole and 13 bytes at a time through a decompressobj, and the
# gzip one through Python's gzip module too.
"$PY" - "$WORK/fixtures" <<'PY' || status=1
import gzip, os, sys, zlib
d = sys.argv[1]
bad = 0
plain = open(os.path.join(d, "deflater.bin"), "rb").read()
for env, wbits in (("raw", -15), ("zlib", 15), ("gzip", 31)):
    path = os.path.join(d, "deflater." + env)
    if not os.path.exists(path):
        print(f"  deflater.{env}: iyi wrote nothing"); bad += 1; continue
    stream = open(path, "rb").read()
    try:
        back = zlib.decompress(stream, wbits)
        o = zlib.decompressobj(wbits)
        pieces = b"".join(o.decompress(stream[i:i + 13]) for i in range(0, len(stream), 13)) + o.flush()
        module = gzip.decompress(stream) if env == "gzip" else plain
    except (zlib.error, OSError) as e:
        print(f"  deflater.{env}: refused: {e}"); bad += 1; continue
    if back != plain or pieces != plain or module != plain:
        print(f"  deflater.{env}: read {len(back)}, {len(pieces)} and {len(module)} bytes, not the {len(plain)} written"); bad += 1; continue
    print(f"  deflater.{env}: {len(stream)} bytes, {len(plain)} back whole and 13 bytes at a time")
sys.exit(1 if bad else 0)
PY

echo
echo "== every level, read by zlib and sized against it"
# Each corpus at every level and in every envelope, read by zlib (and the
# gzip ones by Python's gzip module too), and its size held within 2% of
# what zlib writes at the same level, 8 bytes over for the tiny ones;
# zlib's own time over the 10 MB, for the speeds the release build prints.
"$PY" - "$WORK/fixtures" <<'PY' || status=1
import gzip, os, sys, time, zlib
d = sys.argv[1]
bad = 0
for name in ("l_text", "l_source", "l_json", "l_random", "l_repeat", "l_empty", "l_one", "l_big"):
    plain = open(os.path.join(d, name + ".bin"), "rb").read()
    ratios = []
    speeds = []
    for level in range(10):
        for env, wbits in (("raw", -15), ("zlib", 15), ("gzip", 31)):
            if env != "raw" and name == "l_big" and level != 6:
                continue
            path = os.path.join(d, f"{name}.{level}.iyi.{env}")
            if not os.path.exists(path):
                print(f"  {name} at level {level}, {env}: iyi wrote nothing"); bad += 1; continue
            stream = open(path, "rb").read()
            try:
                back = zlib.decompress(stream, wbits)
                module = gzip.decompress(stream) if env == "gzip" else back
            except (zlib.error, OSError) as e:
                print(f"  {name} at level {level}, {env}: refused: {e}"); bad += 1; continue
            if back != plain or module != plain:
                print(f"  {name} at level {level}, {env}: read {len(back)} bytes, not the {len(plain)} written"); bad += 1
        raw = os.path.getsize(os.path.join(d, f"{name}.{level}.iyi.raw"))
        c = zlib.compressobj(level, zlib.DEFLATED, -15)
        t0 = time.perf_counter()
        ref = len(c.compress(plain) + c.flush())
        took = time.perf_counter() - t0
        ratios.append(f"{raw / ref:.4f}")
        speeds.append(f"{level}: {took * 1000:.0f} ms, {len(plain) / took / 1e6:.0f} MB/s")
        if raw > ref * 1.02 + 8:
            print(f"  {name} at level {level}: iyi wrote {raw} bytes, more than 2% past zlib's {ref}"); bad += 1
    print(f"  {name}: {len(plain)} bytes, iyi's size over zlib's at levels 0 to 9: {' '.join(ratios)}")
    if name == "l_big":
        print(f"  speed of zlib {zlib.ZLIB_RUNTIME_VERSION} over {name}'s {len(plain)} bytes, level {'; '.join(speeds)}")
sys.exit(1 if bad else 0)
PY

echo
echo "== the Deflater's random pieces, read by zlib after each"
# Each piece's stream fed to one decompressobj as it was written: what
# zlib answers after it is every byte given so far, without the next.
"$PY" - "$WORK/fixtures" <<'PY' || status=1
import gzip, os, sys, zlib
d = sys.argv[1]
bad = 0
plain = open(os.path.join(d, "pieces.bin"), "rb").read()
count = 0
for level in (0, 1, 6, 9):
    for env, wbits in (("raw", -15), ("zlib", 15), ("gzip", 31)):
        path = os.path.join(d, f"pieces.{level}.{env}")
        if not os.path.exists(path):
            print(f"  pieces at level {level}, {env}: iyi wrote nothing"); bad += 1; continue
        stream = open(path, "rb").read()
        marks = [tuple(map(int, line.split())) for line in open(path + ".idx")]
        o = zlib.decompressobj(wbits)
        got = b""
        at = 0
        try:
            for k, (plain_end, stream_end) in enumerate(marks):
                got += o.decompress(stream[at:stream_end])
                at = stream_end
                if got != plain[:plain_end]:
                    print(f"  pieces at level {level}, {env}: after piece {k + 1} zlib gave {len(got)} bytes, not {plain_end}"); bad += 1
                    break
            got += o.flush()
            module = gzip.decompress(stream) if env == "gzip" else got
        except (zlib.error, OSError) as e:
            print(f"  pieces at level {level}, {env}: refused: {e}"); bad += 1; continue
        if got != plain or module != plain or not o.eof:
            print(f"  pieces at level {level}, {env}: the whole stream read {len(got)} bytes, not {len(plain)}"); bad += 1
        count += 1
        if env == "zlib":
            print(f"  level {level}: {len(marks) - 1} pieces, {len(stream)} bytes, every piece read at once")
print(f"  {count} streams read a piece at a time")
fib = open(os.path.join(d, "fibonacci.bin"), "rb").read()
try:
    if zlib.decompress(open(os.path.join(d, "fibonacci.raw"), "rb").read(), -15) != fib:
        print("  the block held to 15 bits reads back otherwise"); bad += 1
    else:
        print("  and the block held to 15 bits reads back")
except zlib.error as e:
    print(f"  the block held to 15 bits: refused: {e}"); bad += 1
sys.exit(1 if bad else 0)
PY

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" compress-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/compress-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi
# The speeds worth reading are the optimised build's, beside zlib's above.
grep "speed of iyi" "$WORK/compress-release.out" 2>/dev/null || { echo "  release: no speeds printed"; status=1; }

echo
echo "== what a stream refuses, by name"
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/compress::{Deflate, Zlib, Gzip, Deflater, Inflater, Envelope}\n\n\ndef bytes(values : Array(Int32)) : String\n  String.new(values.size) do |dst|\n    i = 0\n    while i < values.size\n      dst[i] = values[i].to_u8\n      i = i + 1\n    end\n  end\nend\n\nputs (%s).bytesize\n' \
    "$expression" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,8p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase' (exit $code, $(wc -c < "$WORK/$name.out") bytes said)"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" \
    "$(grep -m1 -o "$phrase.*" "$WORK/$name.out")"
}
refuses "a reserved block type" reserved "DEFLATE: block type 3 is reserved" \
  'Deflate.decompress(bytes([0x07]))'
refuses "a stream that ends inside a block" short "DEFLATE: the stream ends inside a block" \
  'Deflate.decompress(bytes([0x03]))'
refuses "a stored length that is not its complement" stored_len "DEFLATE: a stored block.s length does not match its complement" \
  'Deflate.decompress(bytes([0x01, 0x05, 0x00, 0x00, 0x00, 0x68]))'
refuses "a stored block cut short" stored_cut "DEFLATE: the stream ends inside a stored block" \
  'Deflate.decompress(bytes([0x01, 0x05, 0x00, 0xfa, 0xff, 0x68]))'
refuses "a zlib header that is not deflate" zlib_method "zlib: not a deflate stream (method 7)" \
  'Zlib.decompress(bytes([0x77, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]))'
refuses "a zlib header whose check fails" zlib_check "zlib: the header check failed" \
  'Zlib.decompress(bytes([0x78, 0x9d, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]))'
refuses "a zlib preset dictionary" zlib_dict "zlib: a preset dictionary is not supported" \
  'Zlib.decompress(bytes([0x78, 0xbb, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]))'
refuses "a zlib checksum that does not match" zlib_sum "zlib: the checksum does not match (00000001, stream says 00000002)" \
  'Zlib.decompress(bytes([0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x02]))'
refuses "a zlib stream cut before its checksum" zlib_cut "zlib: the stream ends before its checksum" \
  'Zlib.decompress(bytes([0x78, 0x9c, 0x03, 0x00, 0x00]))'
refuses "a gzip stream that is not one" gzip_magic "gzip: not a gzip stream" \
  'Gzip.decompress(bytes([0x1f, 0x8c, 8, 0, 0, 0, 0, 0, 0, 0xff, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]))'
refuses "a gzip checksum that does not match" gzip_crc "gzip: the checksum does not match" \
  'Gzip.decompress(bytes([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff, 3, 0, 1, 0, 0, 0, 0, 0, 0, 0]))'
refuses "a gzip length that does not match" gzip_len "gzip: the length does not match (0, stream says 5)" \
  'Gzip.decompress(bytes([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff, 3, 0, 0, 0, 0, 0, 5, 0, 0, 0]))'
refuses "a gzip name that never ends" gzip_name "gzip: the stream ends inside its header" \
  'Gzip.decompress(bytes([0x1f, 0x8b, 8, 8, 0, 0, 0, 0, 0, 0xff, 0x61, 0x62, 0x63]))'
# RFC 1952 2.3.1.2 makes a reserved flag an error, as zlib does.
refuses "a gzip header with a reserved flag" gzip_reserved "gzip: a reserved header flag is set (FLG 32)" \
  'Gzip.decompress(bytes([0x1f, 0x8b, 8, 0x20, 0, 0, 0, 0, 0, 0xff, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]))'
# A dynamic block's codes may leave bit patterns unused only when the code
# is one code of one bit; zlib and puff refuse every other incomplete set.
refuses "an incomplete literal/length code" lit_incomplete "DEFLATE: the literal/length code is incomplete" \
  'Deflate.decompress(bytes([0x05, 0xc0, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x13]))'
refuses "an incomplete code-length code" len_incomplete "DEFLATE: the code-length code is incomplete" \
  'Deflate.decompress(bytes([0x05, 0xc0, 0x01, 0x04, 0x00, 0x00, 0x00, 0xc0, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x42]))'
refuses "an incomplete distance code" dist_incomplete "DEFLATE: the distance code is incomplete" \
  'Deflate.decompress(bytes([0x0d, 0xc1, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xdf, 0x16]))'
refuses "a second gzip member cut short" gzip_member_cut "gzip: the stream is shorter than its header" \
  'Gzip.decompress(bytes([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x4b, 0x4c, 0x02, 0x00, 0x6d, 0x48, 0x83, 0x9e, 0x02, 0x00, 0x00, 0x00, 0x1f, 0x8b, 0x08]))'
# A stream refused by `Inflater` is a value the exercise checks; what is
# left to panic is the caller's own mistake: a stream finished twice or
# written after its end, and a read of no bytes.
refuses "a Deflater finished twice" deflater_twice "Deflater: finish was called twice" \
  '(d = Deflater.new(Envelope::Gzip); d.finish; d.finish)'
refuses "a Deflater written after its finish" deflater_after "Deflater: compress after finish" \
  '(d = Deflater.new(Envelope::Zlib); d.finish; d.compress("more"))'
refuses "a read of no bytes" read_zero "Inflater: read wants at least one byte, not 0" \
  '(Inflater.new(Envelope::Raw) { nil }.read(0); "")'
refuses "a level past 9" level_high "Deflate: level 10 is not 0 to 9" \
  'Gzip.compress("x", 10)'
refuses "a Deflater at level -1" level_low "Deflate: level -1 is not 0 to 9" \
  '(Deflater.new(Envelope::Raw, -1); "")'

echo
echo "== the gigabyte paths, at 70 KB"
# Past a gigabyte the positions are moved down a multiple of the window
# (`rebase`), and a whole string or a Deflater's piece is coded a
# gigabyte at a time; neither may change a byte of what is written. The
# exercise run with both at 70 KB and 100 KB must pass as it is, its
# pinned sizes included.
rm -rf "$WORK/small"
mkdir -p "$WORK/small/std"
if "$PY" - "$REPO/src/std/compress.iyi" "$WORK/small/std/compress.iyi" <<'PY'
import sys
src = open(sys.argv[1]).read()
for old, new in (("SEGMENT       = 1 << 30", "SEGMENT       = 70001"), ("REBASE        = 1 << 30", "REBASE        = 100000")):
    if old not in src:
        raise SystemExit("patch site missing: " + old)
    src = src.replace(old, new, 1)
open(sys.argv[2], "w").write(src)
PY
then
  if IYI_PATH="$WORK/small${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build --release -o "$WORK/small.bin" "$REPO/bench/std_compress_exercise.iyi" >"$WORK/small.log" 2>&1 \
     && "$WORK/small.bin" >"$WORK/small.out" 2>&1 && grep -q "ALL CHECKS PASSED" "$WORK/small.out"; then
    echo "  segments of 70,001 bytes and a rebase past 100,000: every check passes, every size as pinned"
  else
    echo "  FAIL: the exercise does not hold with small segments and rebases"
    tail -3 "$WORK/small.log" "$WORK/small.out" 2>/dev/null | sed 's/^/    /'
    status=1
  fi
else
  echo "  FAIL: the small-constant copy could not be written"
  status=1
fi

echo
echo "== the exercise's artifacts and other platforms"
# Built from the module's artifacts, the exercise must print what it
# printed from source (without a fixtures directory, so that no timing
# is printed); and it typechecks for the four other platforms std is
# held to.
mkdir -p "$WORK/r1/mods"
if (cd "$WORK/r1" && "$IYI" build --emit-iyimod mods -o from-source "$REPO/bench/std_compress_exercise.iyi" \
      && "$IYI" build --use-iyimod mods -o from-artifact "$REPO/bench/std_compress_exercise.iyi") > "$WORK/r1/build.log" 2>&1 \
   && "$WORK/r1/from-source" > "$WORK/r1/source.out" 2>&1 \
   && "$WORK/r1/from-artifact" > "$WORK/r1/artifact.out" 2>&1 \
   && cmp -s "$WORK/r1/source.out" "$WORK/r1/artifact.out" \
   && grep -q "ALL CHECKS PASSED" "$WORK/r1/artifact.out"; then
  echo "  from source and from its artifacts alike, $(wc -l < "$WORK/r1/artifact.out" | tr -d ' ') lines"
else
  echo "  FAIL: the exercise does not run the same from its artifacts"
  grep -m3 -E 'Error|panic|ASSERTION' "$WORK/r1/build.log" "$WORK/r1/source.out" "$WORK/r1/artifact.out" 2>/dev/null | sed 's/^/    /'
  status=1
fi
for target in x86_64-linux-gnu aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  if ! "$IYI" build --no-codegen --target "$target" -o "$WORK/cross-$target" "$REPO/bench/std_compress_exercise.iyi" > "$WORK/cross-$target.log" 2>&1; then
    echo "  FAIL: $target: $(grep -m1 -E 'Error|BUG' "$WORK/cross-$target.log" | cut -c1-140)"
    status=1
  fi
done
echo "  typechecks for x86_64-linux-gnu, aarch64-darwin, x86_64-windows-msvc, aarch64-linux-gnu, x86_64-linux-musl"
if "$IYI" doc "$REPO/src/std/compress.iyi" > "$WORK/doc.out" 2>&1 && grep -q "def self.compress(data : String, level : Int32 = 6)" "$WORK/doc.out"; then
  echo "  iyi doc reads the module, levels and all"
else
  echo "  FAIL: iyi doc src/std/compress.iyi"
  status=1
fi
if "$IYI" fmt --check "$REPO/src/std/compress.iyi" "$REPO/bench/std_compress_exercise.iyi" > "$WORK/format.log" 2>&1; then
  echo "  the module and its exercise are formatted"
else
  echo "  not formatted: $(grep -m1 produced "$WORK/format.log")"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mutations=0
mutate() { # mutate <label> <old> <new> [<phrase>] [small]
  # A binary of its own each: on Windows the last one's file can still be
  # held a moment after it ended, and the next link over it failed with
  # LNK1104.
  mutations=$((mutations + 1))
  local label="$1" old="$2" new="$3" phrase="${4:-}" small="${5:-}"
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if ! OLD="$old" NEW="$new" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/compress.iyi").read_text()
old = os.environ["OLD"]
if old not in src:
    raise SystemExit("patch site missing: " + old)
src = src.replace(old, os.environ["NEW"], 1)
# The rebase's own breaks are seen only where a rebase happens: with the
# constants the run above uses.
if "$small":
    src = src.replace("SEGMENT       = 1 << 30", "SEGMENT       = 70001", 1).replace("REBASE        = 1 << 30", "REBASE        = 100000", 1)
Path("$WORK/patched/std/compress.iyi").write_text(src)
PY
  then
    echo "  $label: the patch did not apply"
    status=1
  # Build first, then run: a patch that does not compile would also "fail",
  # and that proves nothing about whether the exercise catches the break.
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mut-$mutations.bin" "$REPO/bench/std_compress_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the broken copy did not compile"
    sed -n '1,6p' "$WORK/mut.out"
    status=1
  elif "$WORK/mut-$mutations.bin" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif [ -n "$phrase" ] && ! grep -qF "$phrase" "$WORK/mut.out"; then
    echo "  $label: failed, but not at the check that names '$phrase':"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  else
    echo "  $label: caught"
  fi
}
mutate "a back-reference copied from one byte off" 'dst[i] = src[i]' 'dst[i] = src[i + 1]'
mutate "a Huffman code written the wrong way round" '@code[i] = Tree.reverse(nxt[l], l)' '@code[i] = nxt[l]'
mutate "a match finder that never looks" 'if hash_head != 0 && prev_length < lazy && s - hash_head <= WSIZE' \
  'if false && hash_head != 0 && prev_length < lazy && s - hash_head <= WSIZE' "a 100,000-byte run"
mutate "a length table off by one" '@lbase = fill([3, 4, 5, 6' '@lbase = fill([3, 4, 5, 7'
mutate "a back-reference copied a word from one byte off" '(dst + i.to_i64).as(Pointer(UInt64)).value = (src + i.to_i64)' '(dst + i.to_i64).as(Pointer(UInt64)).value = (src + (i + 1).to_i64)'
mutate "a code table indexed by the code's bits unreversed" '(((code >> bit) & 1) << (len - 1 - bit))' '(((code >> bit) & 1) << bit)'
# The writing side's own: the length limit, the header's order, the lazy
# match, the distance codes, the block choice, and the rebase.
mutate "a code longer than 15 bits" 'MAX_BITS      =    15' 'MAX_BITS      =    20' "the Fibonacci block"
mutate "the code-length code's lengths sent in the wrong order" 'w.put(@bl.len[Inflate::ORDER[i]], 3)' 'w.put(@bl.len[Inflate::ORDER[18 - i]], 3)'
mutate "a lazy match written one byte off" 'full = tally_match(s - 1 - prev_match, prev_length)' 'full = tally_match(s - prev_match, prev_length)'
# A tie not taken holds a "match" at the next position whose start
# `longest` never set - finding nothing longer, it answers the held
# length - so the stream is wrong, and the first round trip says so.
mutate "a lazy match dropped on a tie" 'if prev_length >= MIN_MATCH && ml <= prev_length' 'if prev_length >= MIN_MATCH && ml < prev_length' \
  "round trip"
mutate "a distance code looked up a bit off" '@dist_code[256 + (d >> 7)]' '@dist_code[256 + (d >> 8)]'
mutate "a block never stored" 'if stored <= fixed && stored <= dynamic' 'if stored < 0' \
  "random bytes are stored"
mutate "the dearer of fixed and dynamic" 'elsif fixed <= dynamic' 'elsif fixed > dynamic'
mutate "a rebase off the window's multiple" 'delta = ((@strstart - 2 * WSIZE) // WSIZE) * WSIZE' 'delta = @strstart - 2 * WSIZE - 1' \
  "" small
# The streaming decoder's own: the slide that keeps the window, the
# trailers, the read that answers what it has, and what is left over.
mutate "a window slid one byte short" 'keep = @pos - WINDOW' 'keep = @pos - WINDOW + 1' \
  "matches from 32 KiB back"
mutate "a gzip CRC-32 never compared" 'unless @check == want_crc' 'unless true' \
  "Gzip with byte"
mutate "a zlib Adler-32 never compared" '#{Zlib.hex(want)})") unless @check == want' '#{Zlib.hex(want)})") unless true' \
  "Zlib with byte"
mutate "a read that waits for more input though it has bytes to give" 'SYMBOL_BITS = 48' 'SYMBOL_BITS = 0' \
  "the first read answered"
mutate "a leftover without the bytes loaded ahead" 'held = @count // 8
    rest = @in_end - @in_pos' 'held = 0
    rest = @in_end - @in_pos' \
  "what is left over is what was fed past the stream"

echo
if [ "$status" -eq 0 ]; then
  echo "the std/compress exercise holds"
else
  echo "the std/compress exercise did not hold"
fi
exit $status
