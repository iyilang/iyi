#!/usr/bin/env bash
# Exercises `std/compress`: DEFLATE, zlib and gzip in iyi, against the
# zlib Python carries as the oracle in both directions.
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
import os, random, struct, sys, zlib
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
PY
then
  echo "the zlib oracle could not be written; nothing below would be measuring the module" >&2
  exit 2
fi
# Six corpora, each `.bin` plus four levels in three envelopes, and the
# gzip header with every field: 6 * 13 + 1.
fixture_count="$(find "$WORK/fixtures" -type f | wc -l | tr -d ' ')"
if [ "$fixture_count" -ne 79 ]; then
  echo "the zlib oracle wrote $fixture_count files where 79 were expected" >&2
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
for phrase in "== round trips" "== what the match finder finds" "== the format's own words" "== against zlib"; do
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
    ref = os.path.getsize(os.path.join(d, name + ".1.raw"))
    print(f"  {name}: {len(plain)} bytes, iyi {raw} against zlib level 1's {ref}")
    if name in ("text", "zeros", "source") and raw > ref * 3:
        print(f"  {name}: iyi's stream is more than three times zlib level 1's"); bad += 1
sys.exit(1 if bad else 0)
PY

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" compress-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/compress-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what a stream refuses, by name"
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/compress\n\nusing std/compress::{Deflate, Zlib, Gzip}\n\ndef bytes(values : Array(Int32)) : String\n  String.new(values.size) do |dst|\n    i = 0\n    while i < values.size\n      dst[i] = values[i].to_u8\n      i = i + 1\n    end\n  end\nend\n\nputs (%s).bytesize\n' \
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
    echo "  $label: refused, but not with '$phrase'"
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

echo
echo "== proving the checks can fail when the module is broken"
mutate() { # mutate <label> <old> <new>
  local label="$1" old="$2" new="$3"
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if ! OLD="$old" NEW="$new" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/compress.iyi").read_text()
old = os.environ["OLD"]
if old not in src:
    raise SystemExit("patch site missing: " + old)
Path("$WORK/patched/std/compress.iyi").write_text(src.replace(old, os.environ["NEW"], 1))
PY
  then
    echo "  $label: the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_compress_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  else
    echo "  $label: caught"
  fi
}
mutate "a back-reference copied from one byte off" '@data[@size + i] = @data[src + i]' '@data[@size + i] = @data[src + i + 1]'
mutate "a Huffman code written the wrong way round" 'put(rev, len)' 'put(code, len)'
mutate "a match finder that never looks" 'chain < 64' 'chain < 0'
mutate "a length table off by one" '@lbase = fill([3, 4, 5, 6' '@lbase = fill([3, 4, 5, 7'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/compress exercise holds"
else
  echo "the std/compress exercise did not hold"
fi
exit $status
