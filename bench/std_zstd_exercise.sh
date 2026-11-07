#!/usr/bin/env bash
# Exercises `std/zstd`: Zstandard frames read whole and a piece at a time
# (`ZstdReader`), and written (`Zstd.compress`), against the zstd Python
# 3.14 carries (`compression.zstd`) as the oracle in both directions.
#
#     bash bench/std_zstd_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The oracle is `compression.zstd`, which arrived in Python 3.14: an older
# interpreter is no interpreter here.
PY=""
for candidate in python3.14 python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import compression.zstd' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
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
  echo "no python with compression.zstd (3.14 or later) on this machine: the zstd oracle cannot be written, so std/zstd goes unmeasured"
  exit 0
fi

# What Python's zstd writes, for iyi to read; what it refuses, for iyi to
# refuse; and what iyi is to write, for Python to read. `index.txt` lists
# them a line each, tab-separated:
#
#   ok      <stream> <plain> <window limit>   decompressed equal to <plain>
#   refuse  <stream> <phrase> <window limit>  refused, the error saying <phrase>
#   huge    <stream> <crc-32> <bytes> <window> read through a bounded reader
#   write   <plain>                           compressed by iyi to <plain>.iyi.zst
mkdir -p "$WORK/fixtures"
if ! "$PY" - "$WORK/fixtures" "$REPO/src/std/zstd.iyi" <<'PY'
import os, random, struct, sys, time, zlib
from compression import zstd
CP = zstd.CompressionParameter
out, source = sys.argv[1], sys.argv[2]
index = []
LIMIT = 8388608

def put(name, data):
    with open(os.path.join(out, name), "wb") as f:
        f.write(data)

# The blocks of every frame of a stream, as (kind, literals, size format,
# sequence-count bytes, modes) - what the coverage check below counts.
def blocks(data):
    seen = []
    i = 0
    while i < len(data):
        magic = struct.unpack_from("<I", data, i)[0]
        if magic & 0xFFFFFFF0 == 0x184D2A50:
            seen.append(("skippable",))
            i += 8 + struct.unpack_from("<I", data, i + 4)[0]
            continue
        assert magic == 0xFD2FB528, hex(magic)
        fhd = data[i + 4]
        single = fhd >> 5 & 1
        i += 5 + (0 if single else 1) + (0, 1, 2, 4)[fhd & 3] + (single, 2, 4, 8)[fhd >> 6]
        while True:
            h = int.from_bytes(data[i:i + 3], "little")
            last, kind, size = h & 1, h >> 1 & 3, h >> 3
            i += 3
            if kind == 0:
                seen.append(("raw block",))
            elif kind == 1:
                seen.append(("RLE block",))
                size = 1
            else:
                b = data[i:i + size]
                lk, sf = b[0] & 3, b[0] >> 2 & 3
                if lk < 2:
                    head = (1, 2, 1, 3)[sf]
                    regen = b[0] >> 3 if sf & 1 == 0 else (b[0] >> 4) + (b[1] << 4) + ((b[2] << 12) if sf == 3 else 0)
                    lend = head + (regen if lk == 0 else 1)
                else:
                    head = (3, 3, 4, 5)[sf]
                    c = int.from_bytes(b[:5], "little")
                    lend = head + {3: c >> 14 & 0x3ff, 4: c >> 18 & 0x3fff, 5: c >> 22 & 0x3ffff}[head]
                    if lk == 2:
                        seen.append(("Huffman weights", "direct" if b[head] >= 128 else "FSE"))
                b0 = b[lend]
                nbytes = 0 if b0 == 0 else (1 if b0 < 128 else (2 if b0 < 255 else 3))
                seen.append(("literals", ("raw", "RLE", "Huffman", "treeless")[lk], "1 stream" if lk >= 2 and sf == 0 else ("4 streams" if lk >= 2 else "")))
                seen.append(("sequence count in bytes", nbytes))
                if nbytes:
                    m = b[lend + nbytes]
                    for kind_name, mode in zip(("literals length", "offset", "match length"), (m >> 6, m >> 4 & 3, m >> 2 & 3)):
                        seen.append((kind_name + " table", ("predefined", "RLE", "FSE", "repeat")[mode]))
            i += size
            if last:
                break
        if fhd & 4:
            i += 4
    return seen

rng = random.Random(20261017)
text = b"".join(b"line %d: the quick brown fox jumps over the lazy dog %d\n" % (i, i % 7) for i in range(40000))
words = [bytes(rng.choice(b"abcdefghijklmnopqrstuvwxyz") for _ in range(rng.randrange(2, 9))) for _ in range(5000)]
prose = b" ".join(rng.choice(words) for _ in range(400000))
tokens = [rng.randbytes(3) for _ in range(4096)]
base = bytes(rng.randrange(1, 256) for _ in range(65536))
splice = [base]
for _ in range(9000):
    s = rng.randrange(0, 65000)
    splice.append(b"\0" + base[s:s + rng.randrange(20, 50)])
corpora = {
    "empty": b"",
    "one": b"a",
    "hello": b"hello",
    "small": bytes(rng.choice(b"etaoinshrdlucmfwypvbgkjqxz      ,.\n") for _ in range(200)),
    "skewed": bytes(min(int(rng.expovariate(0.5)), 4) for _ in range(400)),
    "text": text,
    "prose": prose,
    "random": rng.randbytes(1000000),
    "zeros": b"\0" * 1000000,
    "repeat": b"abc" * 400000,
    "lowmatch": bytes(rng.choice(range(64, 192)) for _ in range(40000)),
    "tokens": b"".join(rng.choice(tokens) for _ in range(200000)),
    "splice": b"".join(splice),
    "source": open(source, "rb").read(),
}
for name, data in corpora.items():
    put(name + ".bin", data)
    index.append(("write", name + ".bin"))
    for level in (1, 3, 19):
        # With and without a checksum and a content size: the two
        # variants between them set and clear each flag.
        for ck, cs in ((0, 1), (1, 0)):
            stream = zstd.compress(data, options={CP.compression_level: level, CP.checksum_flag: ck, CP.content_size_flag: cs})
            z = f"{name}.{level}.{ck}{cs}.zst"
            put(z, stream)
            index.append(("ok", z, name + ".bin", LIMIT))

# Long-distance matching with a 16 MiB window: a megabyte of noise met
# again eleven megabytes on. Streamed, so the frame says its window and
# not its size; refused under the default limit, read under 16 MiB.
noise = rng.randbytes(1 << 20)
middle = b"".join(b"%08d the middle of a long stream\n" % i for i in range(300000))
ldm_plain = noise + middle + noise
c = zstd.ZstdCompressor(options={CP.compression_level: 3, CP.enable_long_distance_matching: 1, CP.window_log: 24, CP.checksum_flag: 1})
ldm = c.compress(ldm_plain) + c.flush()
assert ldm[4] & 0x20 == 0 and ldm[5] == (24 - 10) << 3, "the long-distance frame names a 16 MiB window"
put("ldm.bin", ldm_plain)
put("ldm.zst", ldm)
index.append(("ok", "ldm.zst", "ldm.bin", 16777216))
index.append(("refuse", "ldm.zst", "needs a window of 16777216 bytes, past the limit of 8388608", LIMIT))

# Many frames, levels and flags mixed, with skippable frames between.
parts, plain = [], b""
for k in range(60):
    piece = (text, prose, corpora["random"], corpora["zeros"])[k % 4][k * 1000:k * 1000 + rng.randrange(0, 5000)]
    parts.append(zstd.compress(piece, options={CP.compression_level: (1, 3, 19)[k % 3], CP.checksum_flag: k & 1, CP.content_size_flag: k >> 1 & 1}))
    plain += piece
    if k % 5 == 0:
        payload = rng.randbytes(rng.randrange(0, 300))
        parts.append(struct.pack("<II", 0x184D2A50 + k % 16, len(payload)) + payload)
put("frames.zst", b"".join(parts))
put("frames.bin", plain)
index.append(("ok", "frames.zst", "frames.bin", LIMIT))
put("skips.zst", struct.pack("<II", 0x184D2A5F, 3) + b"abc" + struct.pack("<II", 0x184D2A50, 0))
put("nothing.bin", b"")
index.append(("ok", "skips.zst", "nothing.bin", LIMIT))

# 64 MiB through a reader that must not hold it: its CRC-32, not its bytes.
c = zstd.ZstdCompressor(options={CP.compression_level: 3})
huge, crc, size = [], 0, 0
for k in range(64):
    chunk = b"".join(b"%07d %07d some words of a large stream\n" % (k, i) for i in range(23831))[:1 << 20]
    crc = zlib.crc32(chunk, crc)
    size += len(chunk)
    huge.append(c.compress(chunk))
huge.append(c.flush())
huge = b"".join(huge)
put("huge.zst", huge)
wd = huge[5]
window = (1 << (10 + (wd >> 3))) + ((1 << (10 + (wd >> 3))) >> 3) * (wd & 7)
index.append(("huge", "huge.zst", "%08x" % crc, size, window))
t0 = time.perf_counter()
zstd.decompress(huge)
print(f"  python decompresses the {size >> 20} MiB stream in {(time.perf_counter() - t0) * 1000:.0f} ms", file=sys.stderr)

# Refused, by Python and by iyi, each with its sentence.
def refuse(name, data, phrase, limit=LIMIT, python_refuses=True):
    try:
        zstd.decompress(data)
        refused = False
    except zstd.ZstdError:
        refused = True
    if refused != python_refuses:
        raise SystemExit(f"python {'refuses' if refused else 'reads'} {name}")
    put(name, data)
    index.append(("refuse", name, phrase, limit))

good = zstd.compress(text[:30000], options={CP.compression_level: 19, CP.checksum_flag: 1})
for cut in (1, 4, 5, 6, 9, 12, len(good) // 2, len(good) - 5, len(good) - 1):
    refuse(f"cut{cut}.zst", good[:cut], "ends")
refuse("badsum.zst", good[:-1] + bytes([good[-1] ^ 1]), "content checksum does not match")
# The first FSE-described literals-length table, its accuracy log made 20.
i = 4 + 1 + 2 + 3
b = good[i:]
lk, sf = b[0] & 3, b[0] >> 2 & 3
assert lk == 2
c = int.from_bytes(b[:5], "little")
head = (3, 3, 4, 5)[sf]
lend = head + {3: c >> 14 & 0x3ff, 4: c >> 18 & 0x3fff, 5: c >> 22 & 0x3ffff}[head]
nb = 1 if b[lend] < 128 else 2
assert b[lend + nb] >> 6 == 2, "the first block describes its literals-length table"
at = i + lend + nb + 1
refuse("badfse.zst", good[:at] + bytes([good[at] | 0x0f]) + good[at + 1:], "accuracy log of 20 is past 9")
# A repeat two megabytes back, in a frame whose window says one.
far = rng.randbytes(100000)
c = zstd.ZstdCompressor(options={CP.compression_level: 3, CP.window_log: 22})
farwin = c.compress(far + rng.randbytes(2000000) + far) + c.flush()
assert farwin[4] & 0x20 == 0 and farwin[4] & 3 == 0
# Python reads it: its one-shot decoder keeps the whole output and does
# not hold an offset to the window the frame declares. RFC 8878
# 3.1.1.4 does ("must be smaller than Window_Size"), and a decoder that
# keeps only the window - this one - cannot read it.
refuse("farwindow.zst", farwin[:5] + bytes([(20 - 10) << 3]) + farwin[6:], "reaches past the window of 1048576 bytes", python_refuses=False)
# A frame that needs a dictionary.
samples = [b'{"id": %d, "name": "user %d", "tags": ["a", "b", "%d"], "active": %s}' % (k, k * 7, k % 13, b"true" if k % 3 else b"false") for k in range(2000)]
d = zstd.train_dict(samples, 4096)
refuse("dict.zst", zstd.compress(samples[5], zstd_dict=d), f"needs dictionary {d.dict_id}, and this decoder has none")

# Sequences made by hand, with the predefined tables, for the cases an
# encoder never writes: an offset before the frame began, an offset of 0
# (the first repeat offset less one, when it is 1), more literals than the
# block has. And one that is meant: repeat codes with and without
# literals before them.
LL_NORM = [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1]
ML_NORM = [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1] + [1] * 30 + [-1] * 7
OF_NORM = [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1]
LL_BASE = list(range(16)) + [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
LL_BITS = [0] * 16 + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
ML_BASE = list(range(3, 35)) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539]
ML_BITS = [0] * 32 + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]

def ctable(norm, log):
    size = 1 << log
    high, sym, cumul = size - 1, [0] * size, [0] * (len(norm) + 1)
    for s, p in enumerate(norm):
        if p == -1:
            cumul[s + 1] = cumul[s] + 1
            sym[high] = s
            high -= 1
        else:
            cumul[s + 1] = cumul[s] + p
    step, pos = (size >> 1) + (size >> 3) + 3, 0
    for s, p in enumerate(norm):
        for _ in range(max(p, 0)):
            sym[pos] = s
            pos = (pos + step) & (size - 1)
            while pos > high:
                pos = (pos + step) & (size - 1)
    states = [0] * size
    for u in range(size):
        states[cumul[sym[u]]] = size + u
        cumul[sym[u]] += 1
    tt, total = [], 0
    for p in norm:
        if p in (-1, 1):
            tt.append(((log << 16) - size, total - 1))
            total += 1
        else:
            shed = log - ((p - 1).bit_length() - 1)
            tt.append(((shed << 16) - (p << shed), total - p))
            total += p
    return states, tt, log

# One frame of a 1 KiB window and no content size (so no block maximum
# but the window's stands in the way), one compressed block.
def craft(literals, seqs):
    tables = (ctable(LL_NORM, 6), ctable(OF_NORM, 5), ctable(ML_NORM, 6))
    acc = [0, 0]
    def add(v, n):
        acc[0] |= (v & ((1 << n) - 1)) << acc[1]
        acc[1] += n
    def start(t, s):
        st, tt, _ = t
        db, df = tt[s]
        nb = (db + (1 << 15)) >> 16
        return st[(((nb << 16) - db) >> nb) + df]
    def enc(t, state, s):
        st, tt, _ = t
        db, df = tt[s]
        nb = (state + db) >> 16
        add(state, nb)
        return st[(state >> nb) + df]
    def code(v, base):
        k = len(base) - 1
        while base[k] > v:
            k -= 1
        return k
    codes = [(code(l, LL_BASE), o.bit_length() - 1, code(m, ML_BASE)) for l, o, m in seqs]
    def extra(k):
        (l, o, m), (lc, oc, mc) = seqs[k], codes[k]
        add(l - LL_BASE[lc], LL_BITS[lc])
        add(m - ML_BASE[mc], ML_BITS[mc])
        add(o - (1 << oc), oc)
    ls, os_, ms = (start(tables[0], codes[-1][0]), start(tables[1], codes[-1][1]), start(tables[2], codes[-1][2]))
    extra(len(seqs) - 1)
    for k in range(len(seqs) - 2, -1, -1):
        lc, oc, mc = codes[k]
        os_ = enc(tables[1], os_, oc)
        ms = enc(tables[2], ms, mc)
        ls = enc(tables[0], ls, lc)
        extra(k)
    add(ms, 6)
    add(os_, 5)
    add(ls, 6)
    add(1, 1)
    body = bytes([len(literals) << 3]) + literals + bytes([len(seqs), 0]) + acc[0].to_bytes((acc[1] + 7) // 8, "little")
    return bytes.fromhex("28b52ffd") + bytes([0x00, 0x00]) + ((len(body) << 3) | 5).to_bytes(3, "little") + body

made = craft(b"abcdefgh", [(3, 3 + 3, 4), (2, 1, 5), (0, 1, 4), (3, 2, 3)])
assert zstd.decompress(made) == b"abcabcadeadeadddddfghfgh"
put("repeats.zst", made)
put("repeats.bin", b"abcabcadeadeadddddfghfgh")
# First among what is read, so a decoder that moves the repeat offsets
# wrongly is named by the stream made to show it.
index.insert(0, ("ok", "repeats.zst", "repeats.bin", LIMIT))
refuse("before.zst", craft(b"ab", [(2, 5 + 3, 10)]), "an offset of 5 reaches before the frame began")
refuse("zero.zst", craft(b"ab", [(2, 1, 3), (0, 3, 4)]), "an offset of 0 reaches before the frame began")
refuse("lits.zst", craft(b"ab", [(3, 2 + 3, 4)]), "a sequence asks for more literals than its block has")

# What the corpus exercises, counted over every stream above: a mode no
# stream uses is a decoder path no check reaches.
seen = set()
for entry in index:
    if entry[0] in ("ok", "huge"):
        seen.update(blocks(open(os.path.join(out, entry[1]), "rb").read()))
wanted = [("raw block",), ("RLE block",), ("skippable",),
          ("literals", "raw", ""), ("literals", "RLE", ""), ("literals", "Huffman", "1 stream"), ("literals", "Huffman", "4 streams"),
          ("literals", "treeless", "1 stream"), ("literals", "treeless", "4 streams"),
          ("Huffman weights", "direct"), ("Huffman weights", "FSE"),
          ("sequence count in bytes", 0), ("sequence count in bytes", 1), ("sequence count in bytes", 2), ("sequence count in bytes", 3)]
for kind in ("literals length", "offset", "match length"):
    for mode in ("predefined", "RLE", "FSE", "repeat"):
        wanted.append((kind + " table", mode))
missing = [w for w in wanted if w not in seen]
if missing:
    raise SystemExit(f"the corpus never uses {missing}")
print(f"  the corpus uses all {len(wanted)} block, literals and sequence modes", file=sys.stderr)

with open(os.path.join(out, "index.txt"), "w") as f:
    for entry in index:
        f.write("\t".join(str(x) for x in entry) + "\n")
PY
then
  echo "the zstd oracle could not be written; nothing below would be measuring the module" >&2
  exit 2
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_zstd_exercise.iyi" \
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

echo "== the std/zstd exercise, plain build"
build_and_run "plain" zstd-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/zstd-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every zstd section reported"
for phrase in "== the format's own words" "== round trips" "== what the matcher finds" "== streaming" "== refused as a value" \
              "== against python's zstd" "== python's refusals" "== a 64 MiB stream in bounded memory" "== written for python"; do
  if ! grep -q "$phrase" "$WORK/zstd-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== what iyi wrote, read by python"
# Whole, and through a decompressor fed 13 bytes at a time.
"$PY" - "$WORK/fixtures" <<'PY' || status=1
import os, sys
from compression import zstd
out = sys.argv[1]
names = [l.split("\t")[1].strip() for l in open(os.path.join(out, "index.txt")) if l.startswith("write\t")]
total = 0
for name in names:
    plain = open(os.path.join(out, name), "rb").read()
    stream = open(os.path.join(out, name + ".iyi.zst"), "rb").read()
    if zstd.decompress(stream) != plain:
        raise SystemExit(f"  {name}: python reads something else")
    d = zstd.ZstdDecompressor()
    got = b"".join(d.decompress(stream[i:i + 13]) for i in range(0, len(stream), 13))
    if got != plain or not d.eof:
        raise SystemExit(f"  {name}: python's streaming decompressor reads something else")
    total += 1
print(f"  {total} streams iyi wrote, read back by python whole and 13 bytes at a time")
PY

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" zstd-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/zstd-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi
# Its timings, which the plain build's are not.
grep " took " "$WORK/zstd-release.out" | sed 's/^/  release:/'

echo
echo "== what a caller's mistake panics with"
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/zstd::{Zstd, ZstdReader, ZstdError}\n\nputs (%s)\n' "$expression" > "$WORK/$name.iyi"
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
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(grep -m1 -oF "$phrase" "$WORK/$name.out")"
}
# Corrupt input is a value the exercise checks; what panics is the
# caller's own mistake.
refuses "a read of no bytes" read_zero "ZstdReader: read wants at least one byte, not 0" \
  '(ZstdReader.new { nil }.read(0); "")'
refuses "a window limit under 1 KiB" small_limit "zstd: a window limit of 512 bytes is outside 1 KiB to 512 MiB" \
  'Zstd.decompress("", 512).to_s'
refuses "a window limit past 512 MiB" big_limit "zstd: a window limit of 1073741824 bytes is outside 1 KiB to 512 MiB" \
  '(ZstdReader.new(1073741824) { nil }; "")'

echo
echo "== proving the checks can fail when the module is broken"
# Each broken copy is built, then run over the fixtures; it must fail at
# the check that names <phrase>.
mutations=0
mutate() { # mutate <label> <old> <new> <phrase> [<file>]
  mutations=$((mutations + 1))
  local label="$1" old="$2" new="$3" phrase="$4" file="${5:-zstd}"
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if ! OLD="$old" NEW="$new" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/$file.iyi").read_text()
old = os.environ["OLD"]
if old not in src:
    raise SystemExit("patch site missing: " + old)
Path("$WORK/patched/std/$file.iyi").write_text(src.replace(old, os.environ["NEW"], 1))
PY
  then
    echo "  $label: the patch did not apply"
    status=1
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mut-$mutations.bin" "$REPO/bench/std_zstd_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
# The decoder's tables, against the streams made to show them.
mutate "a predefined literals-length distribution not the RFC's" 'LL_NORM = [4, 3, 2, 2' 'LL_NORM = [4, 2, 3, 2' \
  "repeats.zst"
mutate "an FSE table spread with the wrong step" '    step = (size >> 1) + (size >> 3) + 3
    mask' '    step = (size >> 1) + (size >> 3) + 5
    mask' \
  "python's 1,000 a's"
mutate "repeat offsets not shifted where no literals precede the match" '(ll == 0 ? 1 : 0)' '0' \
  "repeats.zst"
mutate "an FSE description read a bit long per short probability" '        off = off + nb - 1' '        off = off + nb' \
  "one Huffman stream, FSE tables"
mutate "four Huffman streams cut at a quarter rounded down" 'seg = (regen + 3) // 4' 'seg = regen // 4' \
  "four Huffman streams"
mutate "the end of FSE-compressed Huffman weights missed" '      if @rpos < 0
        @weights[n] = t.symbol[s2]' '      if @rpos < -1
        @weights[n] = t.symbol[s2]' \
  "text.1.01.zst"
# The writer sends RLE literals too, so its own round trip sees this first.
mutate "RLE literals of the wrong byte" '        @lits[i] = b' '        @lits[i] = 0_u8' \
  "3 MiB of lines, past one window"
mutate "a treeless literals block refused" '      elsif @huf_bits == 0' '      elsif true' \
  "text.3.01.zst"
mutate "a short-distance match copied from a word back" 'd = d * ((7 + d) // d)' 'd = 8' \
  "repeat.1.01.zst"
# What a frame says, held to it.
mutate "a content checksum never compared" 'unless got == want' 'unless true' \
  "a checksum one bit off"
mutate "a content size never compared" 'if @sized && @produced != @content_size' 'if false' \
  "a content size the frame does not fill"
mutate "a block maximum never applied" "    return fail(\"zstd: a block of #{size} bytes is past the frame's block maximum of #{@block_max}\") if size > @block_max
" '' \
  "a block past the content size of a single segment"
mutate "a dictionary let through" 'if did != 0_u64' 'if false' \
  "a dictionary"
mutate "a window limit never applied" 'if window > @limit.to_u64' 'if false' \
  "over a limit one byte less"
mutate "offsets not held to the window" 'if offset > @window.to_i64' 'if false' \
  "farwindow.zst"
# The reader's own: the slide that bounds it, and what it leaves over.
mutate "a buffer that never slides" 'if keep > 0 && (keep >= @window || @cap >= bound)' 'if keep > 0 && false' \
  "bytes kept alive"
mutate "a leftover that forgets the bytes in hand" '    n = @in_end - @in_pos
    src = @in + @in_pos.to_i64
    String.new(n)' '    n = 0
    src = @in + @in_pos.to_i64
    String.new(n)' \
  "what follows the last frame is left over"
# The writer's, each caught by its own decoder before Python sees it.
mutate "match lengths sent a bit long" 's.bits((@seq_ml[k] - c.ml_base[mlc]).to_i64, c.ml_bits[mlc])' 's.bits((@seq_ml[k] - c.ml_base[mlc]).to_i64, c.ml_bits[mlc] + 1)' \
  "repetitive text"
mutate "offsets kept from a block sent raw" '      @rep1, @rep2, @rep3 = reps
' '' \
  "a raw block between two compressed ones"
mutate "the Huffman weights' two states ended in the wrong order" '      s.bits(s2.to_i64, 6)
      s.bits(s1.to_i64, 6)' '      s.bits(s1.to_i64, 6)
      s.bits(s2.to_i64, 6)' \
  "repetitive text"
mutate "a table description's short probabilities sent full width" 'sink.bits(count.to_i64, count < max ? nb - 1 : nb)' 'sink.bits(count.to_i64, nb)' \
  "repetitive text"
mutate "code lengths past 11 folded into an incomplete code" '        count[j + 1] = count[j + 1] + 2' '        count[j + 1] = count[j + 1] + 1' \
  "folding to 11 bits"
# And the checksum the frames carry, from std/digest.
mutate "an XXH64 that drops the stripe in progress" '      (@stripe + @fill.to_i64).copy_from(data, take)
' '' \
  "content checksum does not match" digest
echo
if [ "$status" -eq 0 ]; then
  echo "the std/zstd exercise holds"
else
  echo "the std/zstd exercise did not hold"
fi
exit $status
