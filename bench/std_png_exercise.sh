#!/usr/bin/env bash
# Exercises `std/png`: PNG images decoded and encoded in iyi, against
# Pillow (and a decoder written here in Python over zlib, where Pillow
# reads a file otherwise than the specification says) in both directions.
#
#     bash bench/std_png_exercise.sh
#
# The official PngSuite is not on this machine and is not fetched: the
# corpus is built here instead, PngSuite's families by its own names
# (`basn`/`basi` every color type at every depth, `f0X` one filter each,
# `s01`-`s40` sizes, `tbb` transparency, `z0X` zlib levels, `oiX` split
# IDAT, `ccwn` ancillary chunks, `x*` broken files), each with the samples
# and RGBA8 the specification gives for it, and Pillow made to agree with
# that wherever it reads the file the same way.
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
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

# Without Python and Pillow there is no oracle at all, and every comparison
# below would be against an empty directory: that is the gate's failure,
# said here, not the module's.
if [ -z "$PY" ] || ! "$PY" -c 'import PIL' >/dev/null 2>&1; then
  echo "FAIL: this gate needs Python 3 with Pillow (PIL) as its oracle"
  exit 1
fi

echo "== the corpus, written by Python"
# Each `<name>.png` with the `.samples` its `Image` must hold, the `.rgba`
# its `to_rgba8` must answer and an `.info` with the header and metadata
# lines the exercise must print; `index.txt` lists them, and the broken
# files with the phrase each is refused with.
mkdir -p "$WORK/fixtures"
cat > "$WORK/corpus.py" <<'PY'
import io, os, random, struct, sys, zlib, warnings
from PIL import Image, PngImagePlugin

warnings.simplefilter("ignore")
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
index = []

SIG = b"\x89PNG\r\n\x1a\n"
CH = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))


def pack_row(vals, depth):
    if depth == 8:
        return bytes(vals)
    if depth == 16:
        return b"".join(struct.pack(">H", v) for v in vals)
    o = bytearray()
    acc = n = 0
    for v in vals:
        acc = (acc << depth) | v
        n += depth
        if n == 8:
            o.append(acc)
            acc = n = 0
    if n:
        o.append(acc << (8 - n))
    return bytes(o)


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def filt(ft, row, prev, bpp):
    o = bytearray()
    for i in range(len(row)):
        a = row[i - bpp] if i >= bpp else 0
        b = prev[i]
        c = prev[i - bpp] if i >= bpp else 0
        pred = (0, a, b, (a + b) // 2, paeth(a, b, c))[ft]
        o.append((row[i] - pred) & 255)
    return bytes(o)


def raw_data(w, h, ctype, depth, px, interlace, filters):
    ch = CH[ctype]
    bpp = max(1, ch * depth // 8)
    raw = bytearray()
    rowno = 0
    for (x0, y0, dx, dy) in (ADAM7 if interlace else [(0, 0, 1, 1)]):
        xs, ys = range(x0, w, dx), range(y0, h, dy)
        if not xs or not ys:
            continue
        prev = bytes(len(pack_row([0] * ch * len(xs), depth)))
        for y in ys:
            row = pack_row([s for x in xs for s in px[y][x]], depth)
            ft = filters(rowno)
            rowno += 1
            raw.append(ft)
            raw += filt(ft, row, prev, bpp)
            prev = row
    return bytes(raw)


def build(w, h, ctype, depth, px, interlace=False, filters=lambda r: r % 5, plte=None, trns=None,
          level=6, split=None, before=(), after=(), raw=None):
    if raw is None:
        raw = raw_data(w, h, ctype, depth, px, interlace, filters)
    z = zlib.compress(raw, level)
    f = SIG + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, depth, ctype, 0, 0, 1 if interlace else 0))
    for t, d in before:
        f += chunk(t, d)
    if plte is not None:
        f += chunk(b"PLTE", bytes(c for e in plte for c in e))
    if trns is not None:
        f += chunk(b"tRNS", trns)
    if split:
        for i in range(0, len(z), split):
            f += chunk(b"IDAT", z[i:i + split])
    else:
        f += chunk(b"IDAT", z)
    for t, d in after:
        f += chunk(t, d)
    return f + chunk(b"IEND", b"")


def expected(w, h, ctype, depth, px, plte=None, trns=None):
    """The Image's samples and its RGBA8, from the specification."""
    samples = bytearray()
    rgba = bytearray()
    key = None
    if trns is not None and ctype in (0, 2):
        key = struct.unpack(">%dH" % (len(trns) // 2), trns)
    alphas = trns if (trns is not None and ctype == 3) else b""
    scale = 255 // ((1 << depth) - 1) if depth < 8 else 1
    for y in range(h):
        for x in range(w):
            p = px[y][x]
            if ctype == 3:
                r, g, b = plte[p[0]]
                a = alphas[p[0]] if p[0] < len(alphas) else 255
                samples += bytes((r, g, b, a) if trns is not None else (r, g, b))
                rgba += bytes((r, g, b, a))
                continue
            if depth == 16:
                samples += b"".join(struct.pack(">H", v) for v in p)
                e8 = [v >> 8 for v in p]
            else:
                samples += bytes(v * scale for v in p)
                e8 = [v * scale for v in p]
            if ctype == 0:
                a = 0 if key is not None and p[0] == key[0] else 255
                rgba += bytes((e8[0], e8[0], e8[0], a))
            elif ctype == 2:
                a = 0 if key is not None and tuple(p) == tuple(key) else 255
                rgba += bytes(e8 + [a])
            elif ctype == 4:
                rgba += bytes((e8[0], e8[0], e8[0], e8[1]))
            else:
                rgba += bytes(e8)
    return bytes(samples), bytes(rgba)


def layout(ctype, trns):
    return {0: "Gray", 2: "RGB", 3: "RGBA" if trns is not None else "RGB", 4: "GrayAlpha", 6: "RGBA"}[ctype]


def info_line(png):
    w, h, d, c, _, _, i = struct.unpack(">IIBBBBB", png[16:29])
    has_trns = b"tRNS" in png and c == 3
    lay = layout(c, b"" if has_trns else None)
    return "%dx%d color_type=%d bit_depth=%d interlaced=%s layout=%s depth=%d" % (
        w, h, c, d, "true" if i else "false", lay, 16 if d == 16 else 8)


def pixels(w, h, ctype, depth, rnd, smooth=True):
    """Samples per pixel: a gradient with noise at 8 and 16 bits, so that
    the filters have something to predict; uniform at lower depths."""
    top = (1 << depth) - 1
    ch = CH[ctype]
    px = []
    for y in range(h):
        row = []
        for x in range(w):
            if ctype == 3:
                row.append((rnd.randrange(0, 1 << depth),))
            elif depth < 8 or not smooth:
                row.append(tuple(rnd.randrange(0, top + 1) for _ in range(ch)))
            else:
                row.append(tuple(min(top, max(0, ((x * 37 + y * 23 + c * 61) * (top // 255) + rnd.randrange(0, (top // 255) * 9 + 1)) % (top + 1))) for c in range(ch)))
        px.append(row)
    return px


def palette(n, rnd):
    return [(rnd.randrange(256), rnd.randrange(256), rnd.randrange(256)) for _ in range(n)]


def pil_rgba(png):
    im = Image.open(io.BytesIO(png))
    im.load()
    return im.convert("RGBA").tobytes()


def emit(name, png, samples, rgba, meta=(), pil=True):
    """Writes a fixture; where Pillow reads the same file, its RGBA must be
    the specification's, or the oracle itself is wrong."""
    with open(os.path.join(out, name + ".png"), "wb") as f:
        f.write(png)
    with open(os.path.join(out, name + ".samples"), "wb") as f:
        f.write(samples)
    with open(os.path.join(out, name + ".rgba"), "wb") as f:
        f.write(rgba)
    with open(os.path.join(out, name + ".info"), "w") as f:
        f.write(info_line(png) + "\n")
        for m in meta:
            f.write(m + "\n")
    if pil:
        w, h, d, c, _, _, i = struct.unpack(">IIBBBBB", png[16:29])
        if c == 0 and d == 16:
            # Pillow reads 16-bit gray as I;16 and clips it to 255 on the way
            # to RGBA: its samples are what is compared, before reduction.
            im = Image.open(io.BytesIO(png))
            im.load()
            if im.mode != "I;16" or im.tobytes("raw", "I;16B") != samples:
                raise SystemExit("oracle: Pillow reads %s's 16-bit samples differently from the specification" % name)
        elif pil_rgba(png) != rgba:
            raise SystemExit("oracle: Pillow reads %s differently from the specification" % name)
    index.append(name)


rnd = random.Random(15948)
FILTER_NAMES = ["none", "sub", "up", "average", "paeth"]

# f0Xn2c08 / f0Xn0g08: one filter for every row (PngSuite's filter family).
for ft in range(5):
    for ctype, tag in ((2, "c"), (0, "g")):
        w, h = 32, 32
        px = pixels(w, h, ctype, 8, rnd)
        png = build(w, h, ctype, 8, px, filters=lambda r, ft=ft: ft)
        s, r = expected(w, h, ctype, 8, px)
        emit("f%02dn%d%s08" % (ft, ctype, tag), png, s, r)

# basn / basi: every color type at every bit depth, plain and Adam7, each row
# filtered by the next of the five in turn.
COMBOS = [(0, d) for d in (1, 2, 4, 8, 16)] + [(2, 8), (2, 16)] + [(3, d) for d in (1, 2, 4, 8)] + \
         [(4, 8), (4, 16), (6, 8), (6, 16)]
TAGS = {0: "g", 2: "c", 3: "p", 4: "g", 6: "c"}
for interlace in (False, True):
    for ctype, depth in COMBOS:
        w, h = 32, 32
        px = pixels(w, h, ctype, depth, rnd)
        plte = palette(1 << depth, rnd) if ctype == 3 else None
        png = build(w, h, ctype, depth, px, interlace=interlace, plte=plte)
        s, r = expected(w, h, ctype, depth, px, plte=plte)
        emit("bas%s%d%s%02d" % ("i" if interlace else "n", ctype, TAGS[ctype], depth), png, s, r)

# s01..s40: sizes 1 to 40, odd ones among them, where Adam7's passes are
# empty or one pixel wide (PngSuite's size family), palette at 4 bits and
# RGB at 8.
for size in (1, 2, 3, 4, 5, 6, 7, 8, 9, 13, 32, 33, 34, 35, 36, 37, 38, 39, 40):
    for interlace in (False, True):
        px = pixels(size, size, 3, 4, rnd)
        plte = palette(16, rnd)
        png = build(size, size, 3, 4, px, interlace=interlace, plte=plte)
        s, r = expected(size, size, 3, 4, px, plte=plte)
        emit("s%02d%s3p04" % (size, "i" if interlace else "n"), png, s, r)
for (w, h) in ((1, 7), (7, 1), (3, 17), (17, 3), (9, 9), (31, 2)):
    for interlace in (False, True):
        for ctype, depth in ((2, 8), (0, 1), (0, 16)):
            px = pixels(w, h, ctype, depth, rnd)
            png = build(w, h, ctype, depth, px, interlace=interlace)
            s, r = expected(w, h, ctype, depth, px)
            emit("r%dx%d%s%d_%02d" % (w, h, "i" if interlace else "n", ctype, depth), png, s, r)

# tRNS: gray at every depth, RGB at 8 and 16, palette at every depth with
# some entries given alpha; plain and interlaced. Some pixels are the key.
for interlace in (False, True):
    il = "i" if interlace else "n"
    for depth in (1, 2, 4, 8, 16):
        w, h = 16, 16
        px = pixels(w, h, 0, depth, rnd)
        k = px[3][5][0]
        trns = struct.pack(">H", k)
        png = build(w, h, 0, depth, px, interlace=interlace, trns=trns)
        s, r = expected(w, h, 0, depth, px, trns=trns)
        # Pillow keeps a 2- or 4-bit gray tRNS unscaled and compares it with
        # samples it has scaled to 8 bits, so no pixel matches it (its 2-bit
        # key 2 meets 170 and is not transparent); libpng and the
        # specification compare at the file's depth. The oracle there is the
        # specification alone.
        emit("tbb%s0g%02d" % (il, depth), png, s, r, pil=depth not in (2, 4))
    for depth in (8, 16):
        w, h = 16, 16
        px = pixels(w, h, 2, depth, rnd)
        px[0][0] = px[7][9] = px[15][15]
        trns = struct.pack(">3H", *px[0][0])
        png = build(w, h, 2, depth, px, interlace=interlace, trns=trns)
        s, r = expected(w, h, 2, depth, px, trns=trns)
        # Pillow reduces 16-bit RGB to 8 bits and then looks for the 16-bit
        # key among the reduced pixels, where it cannot be: there the
        # specification is the oracle.
        emit("tbb%s2c%02d" % (il, depth), png, s, r, pil=depth != 16)
    for depth in (1, 2, 4, 8):
        w, h = 16, 16
        n = 1 << depth
        px = pixels(w, h, 3, depth, rnd)
        plte = palette(n, rnd)
        trns = bytes(rnd.randrange(256) for _ in range(max(1, n - 1)))
        png = build(w, h, 3, depth, px, interlace=interlace, plte=plte, trns=trns)
        s, r = expected(w, h, 3, depth, px, plte=plte, trns=trns)
        emit("tbb%s3p%02d" % (il, depth), png, s, r)

# A palette shorter than the bit depth allows, and indices that keep to it.
px = [[(rnd.randrange(0, 5),) for x in range(20)] for y in range(10)]
plte = palette(5, rnd)
emit("pp5n3p08", build(20, 10, 3, 8, px, plte=plte), *expected(20, 10, 3, 8, px, plte=plte))

# z0X: zlib levels 0 (stored blocks), 1, 6 and 9 (dynamic Huffman).
for level in (0, 1, 6, 9):
    px = pixels(32, 32, 2, 8, rnd)
    emit("z%02dn2c08" % level, build(32, 32, 2, 8, px, level=level), *expected(32, 32, 2, 8, px))

# oi: IDAT split into chunks of 1, 2 and 7 bytes, and an empty IDAT among them.
for split in (1, 2, 7):
    px = pixels(16, 16, 6, 16, rnd)
    emit("oi%dn6a16" % split, build(16, 16, 6, 16, px, split=split), *expected(16, 16, 6, 16, px))

# Ancillary chunks: the ones read, and ones skipped by name.
px = pixels(8, 8, 2, 8, rnd)
icc = bytes(rnd.randrange(256) for _ in range(300))
before = [
    (b"gAMA", struct.pack(">I", 45455)),
    (b"sRGB", b"\x00"),
    (b"iCCP", b"my profile\x00\x00" + zlib.compress(icc)),
    (b"tEXt", b"Title\x00caf\xe9 au lait"),
    (b"zTXt", b"Comment\x00\x00" + zlib.compress(b"compressed \xa9 text" * 20)),
    (b"iTXt", b"Author\x00\x00\x00tr\x00Yazar\x00" + "Çağrı ışık".encode()),
    (b"iTXt", b"Description\x00\x01\x00en\x00\x00" + zlib.compress("ünïcödé ✓".encode())),
    (b"pHYs", struct.pack(">IIB", 2835, 2835, 1)),
    (b"prVt", b"private data"),
]
after = [(b"tIME", struct.pack(">HBBBBB", 2026, 10, 17, 12, 0, 0)), (b"zzZz", b"")]
meta = [
    "gamma 45455",
    "srgb 0",
    "icc my profile %08x %d" % (zlib.crc32(icc), len(icc)),
    "text tEXt Title |café au lait||",
    "text zTXt Comment |%s||" % ("compressed © text" * 20),
    "text iTXt Author |Çağrı ışık|tr|Yazar",
    "text iTXt Description |ünïcödé ✓|en|",
    "skipped pHYs prVt tIME zzZz",
]
emit("ccwn2c08", build(8, 8, 2, 8, px, before=before, after=after), *expected(8, 8, 2, 8, px), meta=meta)

# Pillow's own writer: every mode it writes PNG from.
def pil_fixture(name, im, **kw):
    b = io.BytesIO()
    im.save(b, "PNG", **kw)
    png = b.getvalue()
    re = Image.open(io.BytesIO(png))
    re.load()
    if re.mode == "I;16":
        samples = re.tobytes("raw", "I;16B")
        rgba = b"".join(bytes((v >> 8, v >> 8, v >> 8, 255)) for v in struct.unpack(">%dH" % (len(samples) // 2), samples))
        check = False
    else:
        has_alpha = re.mode in ("LA", "RGBA") or (re.mode == "P" and "transparency" in re.info)
        if re.mode == "1":
            samples = re.convert("L").tobytes()
        elif re.mode == "P":
            samples = re.convert("RGBA" if has_alpha else "RGB").tobytes()
        else:
            samples = re.tobytes()
        if "transparency" in re.info and re.mode in ("L", "RGB"):
            samples = re.tobytes()
        rgba = re.convert("RGBA").tobytes()
        check = True
    emit(name, png, samples, rgba, pil=check)


def photo(mode, w, h):
    im = Image.new("RGBA", (w, h))
    im.putdata([((x * 255) // w, (y * 255) // h, ((x + y) * 7) % 256, (x * y) % 256) for y in range(h) for x in range(w)])
    return im.convert(mode)


for mode in ("1", "L", "LA", "RGB", "RGBA"):
    pil_fixture("pil-%s" % mode, photo(mode, 47, 31))
    pil_fixture("pil-%s-opt" % mode, photo(mode, 47, 31), optimize=True)
for bits in (1, 2, 4, 8):
    im = photo("RGB", 40, 24).quantize(1 << bits)
    pil_fixture("pil-P%d" % bits, im, bits=bits)
    im2 = photo("RGB", 40, 24).quantize(1 << bits)
    pil_fixture("pil-P%d-trns" % bits, im2, bits=bits, transparency=bytes(range(0, 256, 255 // ((1 << bits) - 1) or 1))[: 1 << bits])
im = Image.new("I;16", (37, 23))
im.putdata([(x * 1771 + y * 2111) % 65536 for y in range(23) for x in range(37)])
pil_fixture("pil-I16", im)
pil_fixture("pil-L-trns", photo("L", 30, 20), transparency=40)
pil_fixture("pil-RGB-trns", photo("RGB", 30, 20), transparency=(0, 0, 0))
info = PngImagePlugin.PngInfo()
info.add_text("Software", "Pillow")
info.add_text("Note", "zipped " * 30, zip=True)
info.add_itxt("Überschrift", "türkçe", lang="tr", tkey="Title")
b = io.BytesIO()
photo("RGB", 10, 10).save(b, "PNG", pnginfo=info)
png = b.getvalue()
re = Image.open(io.BytesIO(png)).convert("RGBA")
emit("pil-text", png, Image.open(io.BytesIO(png)).tobytes(), re.tobytes(),
     meta=["text tEXt Software |Pillow||", "text zTXt Note |%s||" % ("zipped " * 30), "text iTXt Überschrift |türkçe|tr|Title"])

# Files that are not PNG as the format allows, each refused with a phrase.
refuse = []


def bad(name, png, phrase):
    with open(os.path.join(out, name + ".png"), "wb") as f:
        f.write(png)
    refuse.append((name, phrase))


good_px = pixels(8, 8, 0, 8, rnd)
good = build(8, 8, 0, 8, good_px)
bad("xs1n0g08", b"\x89PNG\r\n\x1a\x0a"[:7] + b"X" + good[8:], "the 8-byte signature is not there")
bad("xcrn0g08", good[:30] + bytes([good[30] ^ 1]) + good[31:], "IHDR chunk at offset 8 fails its CRC-32")
bad("xhdn0g08", SIG + good[33:], "the first chunk is IDAT; IHDR comes first")
bad("xc9n2c08", build(8, 8, 9, 8, good_px, raw=b""), "color type 9 at bit depth 8 is not a pair")
bad("xd3n2c08", build(8, 8, 2, 3, good_px, raw=b""), "color type 2 at bit depth 3 is not a pair")
bad("xdtn0g08", good[:33] + chunk(b"IEND", b""), "the file has no IDAT chunk")
z = zlib.compress(raw_data(8, 8, 0, 8, good_px, False, lambda r: r % 5))
cut = SIG + good[8:33] + chunk(b"IDAT", z[: len(z) // 2]) + chunk(b"IEND", b"")
bad("xtrn0g08", cut, "the image data's zlib stream")
raw = bytearray(raw_data(8, 8, 0, 8, good_px, False, lambda r: 0))
raw[9 * 3] = 5
bad("xf5n0g08", build(8, 8, 0, 8, good_px, raw=bytes(raw)), "row 3 has filter type 5")
pal_px = pixels(8, 8, 3, 2, rnd)
pal = palette(4, rnd)
p3 = build(8, 8, 3, 2, pal_px, plte=pal)
ihdr_end = 33
idat_at = p3.index(b"IDAT") - 4
plte_at = p3.index(b"PLTE") - 4
bad("xpln3p02", p3[:ihdr_end] + p3[idat_at:p3.index(b"IEND") - 4] + p3[plte_at:idat_at] + chunk(b"IEND", b""),
    "IDAT comes before PLTE in a palette image")
bad("xcun0g08", good[:33] + chunk(b"CRIT", b"x") + good[33:], "the chunk CRIT at offset 33 is critical")
bad("xien0g08", good[:-12], "without an IEND chunk")
bad("xbmn0g08", build(100000, 100000, 0, 8, good_px, raw=b""), "past the limit of 89478485")
bad("xpin3p02", build(8, 8, 3, 2, pal_px, plte=pal[:2]), "palette index is")

with open(os.path.join(out, "index.txt"), "w") as f:
    for n in index:
        f.write("ok %s\n" % n)
    for n, phrase in refuse:
        f.write("refuse %s %s\n" % (n, phrase))
print("  %d files to decode, %d to refuse" % (len(index), len(refuse)))
PY
if ! "$PY" "$WORK/corpus.py" "$WORK/fixtures"; then
  echo "FAIL: the corpus could not be written"
  exit 1
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_png_exercise.iyi" \
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

echo
echo "== the std/png exercise, plain build"
build_and_run "plain" png-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/png-plain.out" 2>/dev/null; then
  echo "plain: ALL CHECKS PASSED missing"
  status=1
fi

echo
echo "== every png section reported"
for phrase in "== decoded from bytes built here" "== round trips" "== filters" "== refused as a value" \
              "== bounded" "== what python wrote" "== written for python" "== timings"; do
  if ! grep -qF "$phrase" "$WORK/png-plain.out"; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== what iyi wrote, read by Pillow and by a decoder written here"
cat > "$WORK/check.py" <<'PY'
import glob, io, os, struct, sys, zlib, warnings
from PIL import Image

warnings.simplefilter("ignore")
work = sys.argv[1]
ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
CH = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def predict(ft, row, prev, i, bpp):
    a = row[i - bpp] if i >= bpp else 0
    b = prev[i]
    c = prev[i - bpp] if i >= bpp else 0
    return (0, a, b, (a + b) // 2, paeth(a, b, c))[ft]


def heuristic(row, prev, bpp):
    """Section 12.8: the first filter whose output, read as signed bytes,
    has the least sum of absolute values."""
    best, best_sum = 0, None
    for ft in range(5):
        s = 0
        for i in range(len(row)):
            v = (row[i] - predict(ft, row, prev, i, bpp)) & 255
            s += v if v < 128 else 256 - v
        if best_sum is None or s < best_sum:
            best, best_sum = ft, s
    return best


def decode(png, name):
    """A PNG decoder of its own, over zlib: the samples the `Image` holds,
    and the rows whose filter the heuristic is checked against."""
    assert png[:8] == b"\x89PNG\r\n\x1a\n", name
    at, chunks = 8, []
    while at < len(png):
        n, = struct.unpack(">I", png[at:at + 4])
        t = png[at + 4:at + 8]
        d = png[at + 8:at + 8 + n]
        assert struct.unpack(">I", png[at + 8 + n:at + 12 + n])[0] == zlib.crc32(t + d), name + ": CRC-32 of " + t.decode()
        chunks.append((t, d))
        at += 12 + n
    w, h, depth, ctype, _, _, il = struct.unpack(">IIBBBBB", chunks[0][1])
    plte = b"".join(d for t, d in chunks if t == b"PLTE")
    trns = b"".join(d for t, d in chunks if t == b"tRNS")
    raw = zlib.decompress(b"".join(d for t, d in chunks if t == b"IDAT"))
    ch = CH[ctype]
    bpp = max(1, ch * depth // 8)
    och = (4 if trns else 3) if ctype == 3 else ch
    sb = 2 if depth == 16 else 1
    out = bytearray(w * h * och * sb)
    pos = 0
    for (x0, y0, dx, dy) in (ADAM7 if il else [(0, 0, 1, 1)]):
        xs, ys = range(x0, w, dx), range(y0, h, dy)
        if not xs or not ys:
            continue
        n = (len(xs) * ch * depth + 7) // 8
        prev = bytes(n)
        for y in ys:
            ft = raw[pos]
            row = bytearray(raw[pos + 1:pos + 1 + n])
            pos += 1 + n
            for i in range(n):
                row[i] = (row[i] + predict(ft, row, prev, i, bpp)) & 255
            want = 0 if ctype == 3 else heuristic(row, prev, bpp)
            if ft != want:
                raise SystemExit("%s: row %d (pass from %d,%d) carries filter %d; section 12.8's heuristic chooses %d" % (name, y, x0, y0, ft, want))
            prev = bytes(row)
            for k, x in enumerate(xs):
                o = (y * w + x) * och * sb
                if depth >= 8:
                    px = row[k * ch * sb:(k + 1) * ch * sb]
                    if ctype == 3:
                        i = px[0]
                        out[o:o + 3] = plte[i * 3:i * 3 + 3]
                        if och == 4:
                            out[o + 3] = trns[i] if i < len(trns) else 255
                    else:
                        out[o:o + len(px)] = px
                else:
                    bit = k * depth
                    v = (row[bit >> 3] >> (8 - depth - (bit & 7))) & ((1 << depth) - 1)
                    out[o:o + 3] = plte[v * 3:v * 3 + 3]
                    if och == 4:
                        out[o + 3] = trns[v] if v < len(trns) else 255
    assert pos == len(raw), name + ": image data past the image"
    return bytes(out), (w, h, depth, ctype, il), chunks


count = 0
for path in sorted(glob.glob(os.path.join(work, "out-*.png"))):
    name = os.path.basename(path)[:-4]
    png = open(path, "rb").read()
    samples = open(path[:-4] + ".samples", "rb").read()
    rgba = open(path[:-4] + ".rgba", "rb").read()
    mine, (w, h, depth, ctype, il), chunks = decode(png, name)
    if mine != samples:
        raise SystemExit("%s: decoded here, its samples are not the ones the exercise wrote" % name)
    im = Image.open(io.BytesIO(png))
    im.load()
    if (im.info.get("interlace", 0) != 0) != bool(il):
        raise SystemExit("%s: Pillow reads interlace %r" % (name, im.info.get("interlace")))
    if ctype == 0 and depth == 16:
        if im.mode != "I;16" or im.tobytes("raw", "I;16B") != samples:
            raise SystemExit("%s: Pillow's 16-bit samples differ" % name)
    elif im.convert("RGBA").tobytes() != rgba:
        raise SystemExit("%s: Pillow's RGBA differs from the exercise's" % name)
    if "-trns" not in name and not name.startswith("out-P"):
        if im.text != {"Software": "iyi std/png", "Überschrift": "ılık"}:
            raise SystemExit("%s: Pillow reads the texts as %r" % (name, im.text))
        kinds = [t for t, d in chunks if t in (b"tEXt", b"iTXt")]
        if kinds != [b"tEXt", b"iTXt"]:
            raise SystemExit("%s: the texts are written as %r, not a tEXt and an iTXt" % (name, kinds))
    count += 1
if count < 26:
    raise SystemExit("only %d out-* files were there to read" % count)
print("  %d files: Pillow decodes each to the exercise's pixels (16-bit gray to its samples), a decoder" % count)
print("  written here over zlib to its samples, every row's filter the one section 12.8 chooses, the texts")
print("  read back as tEXt and iTXt")
PY
"$PY" "$WORK/check.py" "$WORK/fixtures" || status=1

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" png-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/png-release.out" 2>/dev/null; then
  echo "release: ALL CHECKS PASSED missing"
  tail -3 "$WORK/png-release.out"
  status=1
else
  echo "  ALL CHECKS PASSED"
  grep -A2 "== timings" "$WORK/png-release.out" | sed -n '2,3p'
fi

echo
echo "== Pillow on the same 2048x2048 RGBA picture"
# What the release build's timings above are next to: Pillow over C zlib
# and its C filters, decoding the file the exercise wrote and encoding the
# same pixels at its default level.
"$PY" - "$WORK/fixtures/timing.png" <<'PY' || status=1
import io, sys, time
from PIL import Image
data = open(sys.argv[1], "rb").read()
best = None
for _ in range(3):
    t = time.perf_counter()
    im = Image.open(io.BytesIO(data))
    im.load()
    best = min(best or 1e9, time.perf_counter() - t)
enc = None
for _ in range(3):
    t = time.perf_counter()
    b = io.BytesIO()
    im.save(b, "PNG")
    enc = min(enc or 1e9, time.perf_counter() - t)
print("  Pillow: decoded in %d ms, encoded in %d ms to %d bytes" % (best * 1000, enc * 1000, len(b.getvalue())))
PY

echo
echo "== the exercise's artifacts and other platforms"
# Built from the module's artifacts, the exercise must print what it
# printed from source (without a work directory, so that no timing is
# printed); and it typechecks for the four other platforms std is held to.
mkdir -p "$WORK/r1/mods"
if (cd "$WORK/r1" && "$IYI" build --emit-iyimod mods -o from-source "$REPO/bench/std_png_exercise.iyi" \
      && "$IYI" build --use-iyimod mods -o from-artifact "$REPO/bench/std_png_exercise.iyi") > "$WORK/r1/build.log" 2>&1 \
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
  if ! "$IYI" build --no-codegen --target "$target" -o "$WORK/cross-$target" "$REPO/bench/std_png_exercise.iyi" > "$WORK/cross-$target.log" 2>&1; then
    echo "  FAIL: $target: $(grep -m1 -E 'Error|BUG' "$WORK/cross-$target.log" | cut -c1-140)"
    status=1
  fi
done
echo "  typechecks for x86_64-linux-gnu, aarch64-darwin, x86_64-windows-msvc, aarch64-linux-gnu, x86_64-linux-musl"
if "$IYI" doc "$REPO/src/std/png.iyi" > "$WORK/doc.out" 2>&1 && grep -q "def self.decode" "$WORK/doc.out"; then
  echo "  iyi doc reads the module"
else
  echo "  FAIL: iyi doc src/std/png.iyi"
  status=1
fi
# Pure computation: no platform module, no binding.
if grep -nE '^import std/(random|time|file|dir|env|socket|process|udp|signal|system|user|errno)\b|^\s*(lib [A-Z]|fun [a-z_]|asm\(|@\[Link)' "$REPO/src/std/png.iyi"; then
  echo "  FAIL: std/png reaches the platform"
  status=1
else
  echo "  std/png imports std/compress and std/digest and nothing of the platform"
fi

echo
echo "== what the module refuses, by name"
# A malformed file is a PngError value, checked by the exercise; what
# panics is the caller's own mistake, and an error the caller chose to
# panic on (`or_panic`) panics with its sentence exactly.
refuses() { # refuses <label> <name> <phrase> <statements>
  local label="$1" name="$2" phrase="$3" statements="$4"
  printf 'module main\n\nimport std/png::{Png, Image, Layout, PngError}\n\n%s\nputs "ANSWERED"\n' \
    "$statements" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,8p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ] || grep -q ANSWERED "$WORK/$name.out"; then
    echo "  $label: it answered instead of refusing"
    status=1
    return
  fi
  if ! grep -qxF "iyi: panic: $phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase' (exit $code)"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$phrase"
}
refuses "samples that do not fill the image" short_samples "Image: 2x2 RGB at 8 bits is 12 bytes of samples, not 3" \
  'Image.new(2, 2, Layout::RGB, 8, "abc")'
refuses "a 12-bit sample" depth12 "Image: a sample is 8 or 16 bits, not 12" \
  'Image.new(1, 1, Layout::Gray, 12, "ab")'
refuses "an empty image" empty "Image: a width and height are at least 1, not 0x5" \
  'Image.new(0, 5, Layout::Gray, 8, "")'
refuses "a transparent color with alpha" key_alpha "Image: a transparent color is for a Gray or RGB image, which has no alpha; this one is RGBA" \
  'Image.new(1, 1, Layout::RGBA, 8, "abcd", [1, 2, 3])'
refuses "a transparent sample past the depth" key_range "Image: a transparent sample is 0 to 255, not 256" \
  'Image.new(1, 1, Layout::Gray, 8, "a", [256])'
refuses "a sample outside the image" outside "Image: no sample 0 at (5, 0) in a 2x2 Gray image" \
  'Image.new(2, 2, Layout::Gray, 8, "abcd").sample(5, 0, 0)'
refuses "an index past the palette" index_past "Png: index 3 at pixel 1 is past the palette's 2 entries" \
  'Png.encode_indexed(2, 1, "\u0000\u0003", [{0, 0, 0, 255}, {1, 1, 1, 255}])'
refuses "an empty palette" empty_palette "Png: a palette has 1 to 256 entries, not 0" \
  'Png.encode_indexed(1, 1, "\u0000", [] of {Int32, Int32, Int32, Int32})'
refuses "a keyword with a space at its end" keyword "Png: \"Title \" is not a keyword: 1 to 79 printable Latin-1 characters, no space at either end or two together" \
  'Png.encode(Image.new(1, 1, Layout::Gray, 8, "a"), texts: [{"Title ", "x"}])'
refuses "not a PNG file, or_panic" not_png "png: not a PNG file: the 8-byte signature is not there" \
  'Png.decode("GIF89a").or_panic'

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new>: the exercise must fail on a
# copy of the module with <old> replaced, at the check that names <phrase>.
mutations=0
prove_broken() {
  mutations=$((mutations + 1))
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/png.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing: " + os.environ["OLD"])
Path("$WORK/patched/std/png.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  # Build first, then run: a patch that does not compile would also "fail",
  # and that proves nothing about whether the exercise catches the break.
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mut-$mutations.bin" "$REPO/bench/std_png_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the $1 copy did not compile"
    sed -n '1,6p' "$WORK/mut.out"
    status=1
  elif "$WORK/mut-$mutations.bin" "$WORK/fixtures" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $1"
    status=1
  elif grep -qF "$2" "$WORK/mut.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not where it should have:"
    { grep -m2 -E 'panic|ASSERTION' "$WORK/mut.out" || tail -2 "$WORK/mut.out"; } | sed 's/^/    /'
    status=1
  fi
}
# A tie between the left and the upper byte is a tie between equal bytes,
# so the first comparison's `<=` cannot be told from `<`: the tie that
# matters is the upper against the upper-left.
prove_broken "Paeth's ties decided for the upper-left byte" "filter 4 (Paeth) rows decode" \
  '    elsif pb <= pc' '    elsif pb < pc'
prove_broken "Average rounding up" "filter 3 (Average) rows decode" \
  'cur[i] = cur[i] &+ ((a + prev[i].to_i32) >> 1).to_u8' 'cur[i] = cur[i] &+ ((a + prev[i].to_i32 + 1) >> 1).to_u8'
prove_broken "a filter type past 4 read as Paeth" "a filter type past 4" \
  '          if f > 4' '          if f > 5'
prove_broken "Adam7's third pass a row step of 4" "Adam7 pass placement" \
  'DY = [8, 8, 8, 4, 4, 2, 2]' 'DY = [8, 8, 4, 4, 4, 2, 2]'
prove_broken "Adam7's sixth and seventh passes' columns swapped" "Adam7 pass placement" \
  'X0 = [0, 4, 0, 2, 0, 1, 0]' 'X0 = [0, 4, 0, 2, 0, 0, 1]'
prove_broken "packed samples read from the low bits" "the bit order of packed samples" \
  '(row[bit >> 3].to_i32 >> (8 - bits - (bit & 7))) & mask' '(row[bit >> 3].to_i32 >> (bit & 7)) & mask'
prove_broken "low-depth gray not scaled" "scaling to 8 bits" \
  '    scale = bits < 8 ? 255 // mask : 1' '    scale = 1'
prove_broken "a gray or RGB tRNS ignored" "tRNS: a 4-bit gray pixel" \
  'return nil if @trns.empty? || @ctype == 3' 'return nil'
prove_broken "a palette tRNS ignored" "tRNS: palette entry" \
  'dst[o + 3] = v < alphas ? alpha[v] : 255_u8 if och == 4' 'dst[o + 3] = 255_u8 if och == 4'
prove_broken "a 16-bit key compared after the reduction" "compared at 16 bits, before the reduction" \
  'dst[o + 3] = v0 == k0 && v1 == k1 && v2 == k2 ? 0_u8 : 255_u8' 'dst[o + 3] = v0 >> 8 == k0 >> 8 && v1 >> 8 == k1 >> 8 && v2 >> 8 == k2 >> 8 ? 0_u8 : 255_u8'
prove_broken "a 16-bit sample reduced to its low byte" "python's basn0g16: to_rgba8" \
  'g = (wide ? v0 >> 8 : v0).to_u8' 'g = (wide ? v0 & 255 : v0).to_u8'
prove_broken "the heuristic summing unsigned bytes" "the filter heuristic" \
  'sum = sum + (b < 128 ? b : 256 - b).to_i64' 'sum = sum + b.to_i64'
prove_broken "the heuristic keeping the last of equals" "the filter heuristic" \
  'if sum < best_sum' 'if sum <= best_sum'
prove_broken "a palette image's rows filtered" "a palette image's rows are not filtered" \
  'adaptive = @ctype != 3 && @depth >= 8' 'adaptive = @depth >= 8'
prove_broken "a CRC-32 never compared" "a corrupted IHDR fails its CRC-32" \
  'if stored != sum' 'if false'
prove_broken "an unknown critical chunk skipped" "an unknown critical chunk" \
  'if p[at + 4] & 0x20_u8 == 0_u8' 'if false'
prove_broken "IDAT before PLTE taken" "IDAT before PLTE" \
  '        if ctype == 3 && !seen_plte' '        if false'
prove_broken "no limit on the pixels a header claims" "a 10^10-pixel header" \
  'if width.to_i64 * height.to_i64 > max_pixels' 'if false'
prove_broken "image data that ends early taken" "image data shorter than the image" \
  '    if got < want' '    if false'
prove_broken "no bound on a compressed text" "a zTXt bomb" \
  'if io.bytesize + piece.bytesize > MAX_METADATA' 'if false'
prove_broken "tEXt's Latin-1 kept as bytes" "a Latin-1 text is a tEXt" \
  'PngText.new(name, keyword, PngBytes.latin1(PngBytes.slice(p, z + 1, limit - z - 1)))' 'PngText.new(name, keyword, PngBytes.slice(p, z + 1, limit - z - 1))'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/png exercise holds ($mutations breaks caught)"
else
  echo "the std/png exercise did not hold"
fi
exit $status
