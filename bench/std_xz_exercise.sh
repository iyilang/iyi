#!/usr/bin/env bash
# Exercises `std/xz`: .xz and .lzma decompression in iyi, whole and a
# piece at a time (`XzReader`), against the liblzma Python carries and
# XZ Utils' own `xz` as the oracles, and against XZ Utils' test files
# (`bench/std_xz_fixture`: `tests/files` of XZ Utils 5.8.1, 0BSD, the
# good, bad and unsupported files whose README says what each holds).
#
#     bash bench/std_xz_exercise.sh
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
# A native compiler cannot resolve this shell's own path mapping (see
# bench/std_compress_exercise.sh): the paths it is given are Windows'.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

if [ -z "$PY" ]; then
  echo "no python3 on this machine: the lzma oracle cannot be written, so std/xz goes unmeasured"
  exit 0
fi
if ! "$PY" -c 'import lzma' >/dev/null 2>&1; then
  echo "this python has no lzma module: the oracle cannot be written, so std/xz goes unmeasured"
  exit 0
fi

# What liblzma writes, through Python's `lzma`: eight corpora - nothing, a
# byte, text, zeros, noise, this module's source, a repeat from 1.5 MB
# back, 2 MB of prose - each at presets 0, 6, 9 and 9e, with each of the
# four check types, as .lzma, and through the delta and x86 filters; a
# megabyte of a real program through x86; streams joined with stream
# padding between and after; and 64 MiB for the memory bound. Where
# `xz` is there, what it writes too: blocks of 64 KiB (`--block-size`),
# and the same with SHA-256 and the threaded encoder. Each `.xz`'s line
# in the manifest names the file it decompresses to, and whether it is
# read one to seven bytes at a time too ("pieces") or, being large, one
# to seven bytes a piece with 64 KiB reads ("whole").
mkdir -p "$WORK/fixtures/suite"
if ! XZ="$(command -v xz || true)" "$PY" - "$WORK/fixtures" "$REPO/src/std/xz.iyi" <<'PY'
import lzma, os, random, subprocess, sys, zlib
out, source = sys.argv[1], sys.argv[2]
xz = os.environ.get("XZ")
rng = random.Random(20261017)
manifest = []

def put(name, data):
    with open(os.path.join(out, name), "wb") as f:
        f.write(data)

def stream(name, data, plain, fmt="xz", pieces=True):
    put(name, data)
    manifest.append(f"{name} {fmt} {plain} {'pieces' if pieces else 'whole'}")

text = b"".join(b"line %d: the quick brown fox jumps over the lazy dog %d\n" % (i, i % 7) for i in range(4000))
words = [bytes(rng.choice(b"abcdefghijklmnopqrstuvwxyz") for _ in range(rng.randint(2, 9))) for _ in range(3000)]
prose = b"\n".join(b" ".join(rng.choice(words) for _ in range(12)) for _ in range(30000))
far = rng.randbytes(100000)
corpora = {
    "empty": b"",
    "byte": b"x",
    "text": text,
    "zeros": b"\0" * 300000,
    "random": rng.randbytes(200000),
    "source": open(source, "rb").read(),
    "far": far + rng.randbytes(1500000) + far,
    "prose": prose,
}
large = {"far", "prose"}
X86 = [{"id": lzma.FILTER_X86}, {"id": lzma.FILTER_LZMA2, "preset": 6}]
for name, data in corpora.items():
    put(name + ".bin", data)
    small = name not in large
    for preset, tag in ((0, "p0"), (6, "p6"), (9, "p9"), (9 | lzma.PRESET_EXTREME, "p9e")):
        stream(f"{name}.{tag}.xz", lzma.compress(data, preset=preset), name + ".bin", pieces=small)
    for check, tag in ((lzma.CHECK_NONE, "none"), (lzma.CHECK_CRC32, "crc32"), (lzma.CHECK_CRC64, "crc64"), (lzma.CHECK_SHA256, "sha256")):
        stream(f"{name}.{tag}.xz", lzma.compress(data, check=check, preset=1), name + ".bin", pieces=small)
    stream(f"{name}.lzma", lzma.compress(data, format=lzma.FORMAT_ALONE), name + ".bin", "lzma", pieces=small)
    stream(f"{name}.delta.xz", lzma.compress(data, filters=[{"id": lzma.FILTER_DELTA, "dist": 4}, {"id": lzma.FILTER_LZMA2, "preset": 6}]), name + ".bin", pieces=small)
    stream(f"{name}.x86.xz", lzma.compress(data, filters=X86), name + ".bin", pieces=small)
    # lc, lp and pb other than the presets' 3, 0 and 2.
    stream(f"{name}.props.xz", lzma.compress(data, filters=[{"id": lzma.FILTER_LZMA2, "lc": 1, "lp": 2, "pb": 0}]), name + ".bin", pieces=small)
    stream(f"{name}.props.lzma", lzma.compress(data, format=lzma.FORMAT_ALONE, filters=[{"id": lzma.FILTER_LZMA1, "lc": 0, "lp": 4, "pb": 4}]), name + ".bin", "lzma", pieces=small)
# A program's own bytes, where the x86 filter has CALLs and JMPs to undo,
# with a start offset and without.
with open(sys.executable, "rb") as f:
    f.seek(1 << 20)
    code = f.read(1 << 20)
put("code.bin", code)
stream("code.x86.xz", lzma.compress(code, filters=X86), "code.bin", pieces=False)
stream("code.x86-offset.xz", lzma.compress(code, filters=[{"id": lzma.FILTER_X86, "start_offset": 4096}, {"id": lzma.FILTER_LZMA2}]), "code.bin", pieces=False)
stream("code.x86-delta.xz", lzma.compress(code, filters=[{"id": lzma.FILTER_X86}, {"id": lzma.FILTER_DELTA, "dist": 2}, {"id": lzma.FILTER_LZMA2}]), "code.bin", pieces=False)
# Streams joined, with stream padding between and after (xz file format
# §2.2), each with its own check: what `cat a.xz b.xz` makes, padded.
parts = [text[:5000], b"", corpora["random"][:7000], b"the last stream\n"]
joined = (lzma.compress(parts[0], check=lzma.CHECK_CRC32) + b"\0" * 4 + lzma.compress(parts[1]) +
          lzma.compress(parts[2], check=lzma.CHECK_SHA256) + b"\0" * 8 + lzma.compress(parts[3], check=lzma.CHECK_NONE) + b"\0" * 4)
put("joined.bin", b"".join(parts))
stream("joined.xz", joined, "joined.bin")
# What `xz` itself writes, where it is installed: blocks of 64 KiB, so
# a stream of many blocks and an index of many records, and the threaded
# encoder, which writes the same shape.
if xz:
    for tag, flags in (("blocks", ["--block-size=65536"]), ("blocks-sha256", ["--block-size=100000", "--check=sha256"]),
                       ("threads", ["-T4", "--block-size=200000"]), ("lzma", ["--format=lzma"])):
        made = subprocess.run([xz, "-c", "-6"] + flags, input=prose, capture_output=True, check=True).stdout
        stream(f"prose.xz-{tag}." + ("lzma" if tag == "lzma" else "xz"), made, "prose.bin", "lzma" if tag == "lzma" else "xz", pieces=False)
# 64 MiB with an 8 MiB dictionary, and its CRC-32 for the exercise to
# compare without holding it.
big = b"".join(b"%08d: a line of the sixty-four mebibytes, %d\n" % (i, i % 1000) for i in range(1450000))[: 64 << 20]
big = big + b"z" * ((64 << 20) - len(big))
put("big.xz", lzma.compress(big, preset=6))
put("big.crc", str(zlib.crc32(big)).encode())
with open(os.path.join(out, "manifest.txt"), "w", newline="") as f:
    f.write("\n".join(manifest) + "\n")
PY
then
  echo "the lzma oracle could not be written; nothing below would be measuring the module" >&2
  exit 2
fi

# XZ Utils' test files, and what each good one decompresses to: by `xz`
# where it is installed, and by Python's liblzma in any case - stream by
# stream, past the stream padding Python's `lzma.decompress` does not
# take - the two agreeing. The bad and unsupported ones carry the
# sentence they are refused with; three good ones use the ARM64 and
# PowerPC BCJ filters, which std/xz refuses by name.
cp "$REPO"/bench/std_xz_fixture/*.xz "$REPO"/bench/std_xz_fixture/*.lzma "$WORK/fixtures/suite/"
cat > "$WORK/fixtures/suite.txt" <<'SUITE'
bad-0-backward_size.xz	xz: the stream footer's index size does not match the index
bad-0-empty-truncated.xz	xz: the stream ends inside its footer
bad-0-footer_magic.xz	xz: the stream footer's magic bytes are not YZ
bad-0-header_magic.xz	xz: not an xz stream (the magic bytes are not FD 37 7A 58 5A 00)
bad-0-nonempty_index.xz	xz: the index lists 1 blocks where the stream has 0
bad-0cat-alone.xz	xz: what follows the stream is neither padding nor another stream
bad-0cat-header_magic.xz	xz: not an xz stream (the magic bytes are not FD 37 7A 58 5A 00)
bad-0catpad-empty.xz	xz: the stream padding is not a multiple of four bytes
bad-0pad-empty.xz	xz: the stream padding is not a multiple of four bytes
bad-1-block_header-1.xz	xz: a filter's properties run past its block header
bad-1-block_header-2.xz	xz: a block header's filter is not a number
bad-1-block_header-3.xz	xz: a block header's CRC32 does not match
bad-1-block_header-4.xz	xz: a block header's compressed size is past what a block can hold
bad-1-block_header-5.xz	xz: a block header gives a compressed size of zero
bad-1-block_header-6.xz	xz: the index lists 2240 blocks where the stream has 0
bad-1-check-crc32-2.xz	xz: a block's CRC32 does not match (15a2a343, stream says ffa2a343)
bad-1-check-crc32.xz	xz: a block's CRC32 does not match (15a2a343, stream says 14a2a343)
bad-1-check-crc64.xz	xz: a block's CRC64 does not match (ca963f9d11882eef, stream says cb963f9d11882eef)
bad-1-check-sha256.xz	xz: a block's SHA-256 does not match
bad-1-lzma2-1.xz	LZMA2: the first chunk does not reset the dictionary
bad-1-lzma2-10.xz	xz: a block's data runs past the compressed size its header gives
bad-1-lzma2-11.xz	xz: a block's data runs past the compressed size its header gives
bad-1-lzma2-2.xz	LZMA2: a distance reaches before the output began
bad-1-lzma2-3.xz	LZMA2: lc + lp is past 4
bad-1-lzma2-4.xz	LZMA2: a chunk without properties where they are needed
bad-1-lzma2-5.xz	LZMA2: a chunk without properties where they are needed
bad-1-lzma2-6.xz	LZMA2: control byte 0x03 is not one LZMA2 defines
bad-1-lzma2-7.xz	LZMA2: a chunk's data ends before its compressed size
bad-1-lzma2-8.xz	LZMA2: a chunk without properties where they are needed
bad-1-lzma2-9.xz	xz: a block's data runs past the compressed size its header gives
bad-1-stream_flags-1.xz	xz: the stream footer's flags do not match its header
bad-1-stream_flags-2.xz	xz: the stream header's CRC32 does not match
bad-1-stream_flags-3.xz	xz: the stream footer's CRC32 does not match
bad-1-vli-1.xz	xz: a block header's uncompressed size is not a number
bad-1-vli-2.xz	xz: a block header's uncompressed size is not a number
bad-2-compressed_data_padding.xz	xz: a block's padding is not zero
bad-2-index-1.xz	xz: the index does not match the blocks
bad-2-index-2.xz	xz: the index does not match the blocks
bad-2-index-3.xz	xz: the index's padding is not zero
bad-2-index-4.xz	xz: the index's CRC32 does not match
bad-2-index-5.xz	xz: an index record's unpadded size is not one a block can have
bad-3-index-uncomp-overflow.xz	xz: the index's uncompressed sizes add up past 2^63
bad-too_big_size-with_eopm.lzma	lzma: the end marker comes before the uncompressed size its header gives
bad-too_small_size-without_eopm-1.lzma	lzma: the data goes on past the uncompressed size its header gives
bad-too_small_size-without_eopm-2.lzma	lzma: the data goes on past the uncompressed size its header gives
bad-too_small_size-without_eopm-3.lzma	lzma: the data goes on past the uncompressed size its header gives
bad-unknown_size-without_eopm.lzma	lzma: the stream ends inside the LZMA data
good-0-empty.xz
good-0cat-empty.xz
good-0catpad-empty.xz
good-0pad-empty.xz
good-1-3delta-lzma2.xz
good-1-arm64-lzma2-1.xz	xz: filter 0x0a (ARM64 BCJ) is not supported
good-1-arm64-lzma2-2.xz	xz: filter 0x0a (ARM64 BCJ) is not supported
good-1-block_header-1.xz
good-1-block_header-2.xz
good-1-block_header-3.xz
good-1-check-crc32.xz
good-1-check-crc64.xz
good-1-check-none.xz
good-1-check-sha256.xz
good-1-delta-lzma2.tiff.xz
good-1-empty-bcj-lzma2.xz	xz: filter 0x05 (PowerPC BCJ) is not supported
good-1-lzma2-1.xz
good-1-lzma2-2.xz
good-1-lzma2-3.xz
good-1-lzma2-4.xz
good-1-lzma2-5.xz
good-2-lzma2.xz
good-known_size-with_eopm.lzma
good-known_size-without_eopm.lzma
good-unknown_size-with_eopm.lzma
unsupported-block_header.xz	xz: a block header's padding is not zero
unsupported-check.xz	xz: check type 2 is not one this reader verifies (none, CRC32, CRC64 or SHA-256)
unsupported-filter_flags-1.xz	xz: the last filter is not LZMA2
unsupported-filter_flags-2.xz	xz: the last filter is not LZMA2
unsupported-filter_flags-3.xz	xz: LZMA2 is not the last filter
SUITE
if ! XZ="$(command -v xz || true)" "$PY" - "$WORK/fixtures" <<'PY'
import lzma, os, subprocess, sys
d = sys.argv[1]
xz = os.environ.get("XZ")
listed = set()
for line in open(os.path.join(d, "suite.txt"), encoding="utf-8"):
    name = line.rstrip("\n").split("\t")[0]
    listed.add(name)
    if "\t" in line:
        continue
    path = os.path.join(d, "suite", name)
    data = open(path, "rb").read()
    fmt = lzma.FORMAT_ALONE if name.endswith(".lzma") else lzma.FORMAT_XZ
    plain = b""
    while True:
        dec = lzma.LZMADecompressor(fmt)
        plain += dec.decompress(data)
        if not dec.eof:
            raise SystemExit(f"python's liblzma did not reach the end of {name}")
        data = dec.unused_data
        while data[:4] == b"\0\0\0\0":
            data = data[4:]
        if not data or fmt == lzma.FORMAT_ALONE:
            break
    if xz:
        flags = ["--format=lzma"] if name.endswith(".lzma") else []
        theirs = subprocess.run([xz, "-dc"] + flags + [path], capture_output=True, check=True).stdout
        if theirs != plain:
            raise SystemExit(f"xz and python's liblzma disagree about {name}")
    with open(path + ".out", "wb") as f:
        f.write(plain)
present = {n for n in os.listdir(os.path.join(d, "suite")) if not n.endswith(".out")}
if present != listed:
    raise SystemExit(f"bench/std_xz_fixture and the table disagree: {sorted(present ^ listed)}")
print(f"  {len(listed)} files of XZ Utils' suite, the good ones' bytes from python's liblzma" + (" and xz, agreeing" if xz else ""))
PY
then
  echo "XZ Utils' suite could not be read by the oracle" >&2
  exit 2
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_xz_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" "$WORK/fixtures" >"$WORK/$name.out" 2>"$WORK/$name.err"
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    tail -3 "$WORK/$name.err"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/xz exercise, plain build"
build_and_run "plain" xz-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/xz-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every xz section reported"
for phrase in "== the format's own words" "== streaming" "== refused as a value" "== memory" \
              "== against python's lzma" "== xz utils' own files" "== 64 MiB in bounded memory"; do
  if ! grep -qF "$phrase" "$WORK/xz-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" xz-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/xz-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
else
  echo "  ALL CHECKS PASSED"
fi

echo
echo "== timings (release; liblzma through python for scale)"
cat "$WORK/xz-release.err"
"$PY" - "$WORK/fixtures" <<'PY'
import lzma, sys, time
d = sys.argv[1]
for name in ("big.xz", "prose.p6.xz"):
    data = open(f"{d}/{name}", "rb").read()
    best = None
    for _ in range(3):
        t0 = time.perf_counter()
        n = len(lzma.decompress(data))
        t = time.perf_counter() - t0
        best = t if best is None or t < best else best
    print(f"  python's liblzma: {name}, {len(data)} bytes to {n}, in {int(best * 1000)} ms")
PY

echo
echo "== built from its artifacts, the exercise says the same"
mkdir -p "$WORK/r1/mods"
if ! (cd "$WORK/r1" && "$IYI" build --emit-iyimod mods -o from-source "$REPO/bench/std_xz_exercise.iyi") >"$WORK/r1/emit.log" 2>&1; then
  echo "  the artifacts could not be written: $(grep -m1 -E 'Error|BUG' "$WORK/r1/emit.log")"
  status=1
elif ! (cd "$WORK/r1" && "$IYI" build --use-iyimod mods -o from-artifact "$REPO/bench/std_xz_exercise.iyi") >"$WORK/r1/use.log" 2>&1; then
  echo "  the program did not build from its artifacts: $(grep -m1 -E 'Error|BUG|undefined' "$WORK/r1/use.log")"
  status=1
else
  "$WORK/r1/from-source" >"$WORK/r1/source.out" 2>&1
  "$WORK/r1/from-artifact" >"$WORK/r1/artifact.out" 2>&1
  if diff -q "$WORK/r1/source.out" "$WORK/r1/artifact.out" >/dev/null && grep -q "ALL CHECKS PASSED" "$WORK/r1/artifact.out"; then
    echo "  from source and from artifacts, the same $(wc -l < "$WORK/r1/source.out" | tr -d ' ') lines"
  else
    echo "  from source and from artifacts the exercise printed different things"
    diff "$WORK/r1/source.out" "$WORK/r1/artifact.out" | head -6
    status=1
  fi
fi

echo
echo "== on the platforms this runner is not"
for target in x86_64-linux-gnu aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  if "$IYI" build --no-codegen --target "$target" -o "$WORK/cross" "$REPO/bench/std_xz_exercise.iyi" >"$WORK/cross.log" 2>&1; then
    echo "  $target: typechecks"
  else
    echo "  $target: $(grep -m1 -E 'Error|BUG' "$WORK/cross.log")"
    status=1
  fi
done

echo
echo "== what a stream refuses, by name"
# A stream refused by `XzReader` is a value the exercise checks; what is
# left to panic is the caller's own mistake, and an `or_panic` on the
# value says the stream's sentence.
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/xz::{Xz, XzReader, XzFormat, XzError}\n\nputs (%s).bytesize\n' \
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
  if ! grep -qF "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase' (exit $code)"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$phrase"
}
refuses "a read of no bytes" read_zero "XzReader: read wants at least one byte, not 0" \
  '(XzReader.new { nil }.read(0); "")'
refuses "a dictionary limit under 4 KiB" limit_low "XzReader: a dictionary limit is 4 KiB to 1.5 GiB, not 100 bytes" \
  '(XzReader.new(XzFormat::Xz, 100_i64) { nil }; "")'
refuses "a dictionary limit past 1.5 GiB" limit_high "XzReader: a dictionary limit is 4 KiB to 1.5 GiB, not 4294967296 bytes" \
  '(XzReader.new(XzFormat::Lzma, 4294967296_i64) { nil }; "")'
refuses "nothing at all, or_panic" empty "xz: the stream is shorter than its header" \
  'Xz.decompress("").or_panic'
refuses "a .lzma properties byte past 224, or_panic" props "lzma: the properties byte is past 224 (225)" \
  'Xz.decompress("\xE1" + "\u0000" * 12, XzFormat::Lzma).or_panic'

echo
echo "== proving the checks can fail when the module is broken"
# Each on a copy of std/xz with one thing broken, the exercise run with
# the fixtures, and failing at the check that names <phrase>.
mutations=0
mutate() { # mutate <label> <old> <new> <phrase>
  mutations=$((mutations + 1))
  local label="$1" old="$2" new="$3" phrase="$4"
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if ! OLD="$old" NEW="$new" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/xz.iyi").read_text()
old = os.environ["OLD"]
if old not in src:
    raise SystemExit("patch site missing: " + old)
Path("$WORK/patched/std/xz.iyi").write_text(src.replace(old, os.environ["NEW"], 1))
PY
  then
    echo "  $label: the patch did not apply"
    status=1
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mut-$mutations.bin" "$REPO/bench/std_xz_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the broken copy did not compile"
    sed -n '1,6p' "$WORK/mut.out"
    status=1
  elif "$WORK/mut-$mutations.bin" "$WORK/fixtures" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF "$phrase" "$WORK/mut.out"; then
    echo "  $label: failed, but not at the check that names '$phrase':"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  else
    echo "  $label: caught"
  fi
}
# The LZMA decoder's own.
mutate "a literal after a match decoded without the match byte" 'if st < 7
          symbol = tree(base, 0x100)' 'if true
          symbol = tree(base, 0x100)' \
  "good-1-lzma2-1.xz, whole"
mutate "the range coder normalised a byte late" 'if @range < 0x1000000_u32' 'if @range < 0x10000_u32' \
  "good-1-lzma2-1.xz, whole"
mutate "a probability that learns at the wrong rate" '(2048_u32 - prob).unsafe_shr(5)' '(2048_u32 - prob).unsafe_shr(4)' \
  "good-1-lzma2-1.xz, whole"
mutate "a match copied from one byte further back" 'copy_match(@rep0.to_i32 + 1, n)' 'copy_match(@rep0.to_i32 + 2, n)' \
  "good-1-lzma2-1.xz, whole"
mutate "a distance's aligned bits in the wrong order" 'r = r.unsafe_shl(4) | reverse(DIST_ALIGN, 4)' 'r = r.unsafe_shl(4) | direct(4)' \
  "good-1-lzma2-1.xz, whole"
mutate "the literal position bits ignored" 'base = LITERAL + 0x300 * ((((@written & lit_mask.to_i64).to_i32) << @lc)' 'base = LITERAL + 0x300 * (((0) << @lc)' \
  "good-1-lzma2-1.xz, whole"
# The ring: its growth, its wrap, and what read takes from it.
mutate "a ring that never grows past its first 64 KiB" 'if @dcap < @dsize
      cap = @dcap.to_i64 * 2_i64' 'if false
      cap = @dcap.to_i64 * 2_i64' \
  "text.p0.xz, whole"
mutate "a ring that wraps a byte early" '    else
      @dpos = 0
    end' '    else
      @dpos = 1
    end' \
  "far.p0.xz, whole"
mutate "a read across the ring's end that takes its second part from a byte on" '(dst + first.to_i64).copy_from(ring, n - first) if n > first' '(dst + first.to_i64).copy_from(ring + 1_i64, n - first) if n > first' \
  "a piece at a time"
mutate "a symbol begun with one byte in hand" 'SYMBOL_BYTES =    21' 'SYMBOL_BYTES =     1' \
  "pieces of [1]"
mutate "a read that waits for more input though it has bytes to give" '          if @pending > 0 && dry?
            @waiting = true
            return
          end
          break unless fill' '          break unless fill' \
  "the first read answered"
# The container's checks.
mutate "a CRC64 never compared" 'unless want == @crc64' 'unless true' \
  "bad-1-check-crc64.xz read"
mutate "a CRC32 never compared" 'unless want == @crc32' 'unless true' \
  "bad-1-check-crc32.xz read"
mutate "a SHA-256 never compared" 'return fail("xz: a block'"'"'s SHA-256 does not match") unless digest[i] == c[i]' 'return fail("xz: a block'"'"'s SHA-256 does not match") unless true' \
  "bad-1-check-sha256.xz read"
mutate "an index never held to the blocks" 'unless sum_unpadded == @sum_unpadded && sum_uncomp == @sum_uncomp && records == @records' 'unless true' \
  "bad-2-index-1.xz read"
mutate "an index CRC32 never compared" 'unless le32(@buf + @in_pos.to_i64) == want' 'unless true' \
  "bad-2-index-4.xz read"
mutate "stream padding of any length" 'return fail("xz: the stream padding is not a multiple of four bytes") unless (zeros & 3) == 0
        @state = DONE' '@state = DONE' \
  "bad-0pad-empty.xz read"
mutate "a dictionary past the limit allocated" 'if dict > @dict_limit' 'if false' \
  "an 8 MiB dictionary under a 4 MiB limit"
mutate "a chunk's compressed size not held to the block header's" 'at + head.to_i64 + packed.to_i64 - @data_start >= @declared_comp' 'false' \
  "bad-1-lzma2-10.xz refused with"
# The filters.
mutate "an x86 CALL made relative to the wrong address" 'dest = src &- (pos &+ i.to_u32 &+ 5_u32)' 'dest = src &- (pos &+ i.to_u32 &+ 4_u32)' \
  "random.x86.xz, whole"
mutate "an x86 filter that forgets its start offset" '@fx86pos[slot] = plen == 4 ? le32(props) : 0_u32' '@fx86pos[slot] = 0_u32' \
  "code.x86-offset.xz, whole"
mutate "a delta filter one byte off" 'b = p[i] &+ hist[(distance + pos) & 255]' 'b = p[i] &+ hist[(distance + pos + 1) & 255]' \
  "good-1-3delta-lzma2.xz, whole"
mutate "an x86 filter that forgets what the bytes before an E8 were" 'prev_mask = (prev_mask.unsafe_shl(gap - 1)) & 7_u32' 'prev_mask = 0_u32' \
  "code.x86.xz, whole"
# .lzma.
mutate "a .lzma end marker taken without its range coder at zero" 'unless @code == 0_u32
    return fail("lzma: the end marker comes before' 'unless true
    return fail("lzma: the end marker comes before' \
  "a .lzma whose last byte but 0 changed is refused"

echo
if [ "$status" -eq 0 ]; then
  echo "the std/xz exercise holds ($mutations breaks caught)"
else
  echo "the std/xz exercise did not hold"
fi
exit $status
