#!/usr/bin/env bash
# Exercises `std/zip`: ZIP archives read and written in iyi, against
# Python's `zipfile` as the oracle in both directions, and Info-ZIP's
# `zip` and `unzip` where the machine has them - stored and deflate, and
# the other methods: bzip2, LZMA, Zstandard and xz read from what
# Python 3.14 writes (xz through a hook, as zipfile does not write it),
# bzip2 and Zstandard written for Python to read, bzip2 both ways with
# `zip -Z bzip2` and `unzip`.
#
#     bash bench/std_zip_exercise.sh
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

# The archives Python writes, each with the `.expect` Python reads from
# it: a `comment` line (hex), then per entry its name, size, CRC-32,
# method, MS-DOS time and flags. The exercise reads each archive and must
# print the same lines. `index.txt` lists them in order.
#
# Without an interpreter there is no oracle at all, and every comparison
# below would be against an empty directory: that is the gate's failure,
# said here, not the module's.
mkdir -p "$WORK/fixtures"
if [ -z "$PY" ]; then
  echo "no python3 on this machine: the oracle cannot be produced"
  exit 1
fi
if ! "$PY" - "$WORK/fixtures" <<'PY'
import lzma, os, random, shutil, struct, subprocess, sys, zipfile, zlib

d = sys.argv[1]
T = (2023, 7, 14, 9, 30, 12)
rng = random.Random(1)
binary = bytes(rng.getrandbits(8) for _ in range(70000))
text = b"".join(b"line %d of a text that deflates well\n" % i for i in range(20000))
index = []

def info(name, method=zipfile.ZIP_DEFLATED):
    zi = zipfile.ZipInfo(name, T)
    zi.compress_type = method
    return zi

def lines_of(z):
    out = ["comment\t" + z.comment.hex()]
    for i in z.infolist():
        out.append("\t".join(["entry", i.filename, str(i.file_size), str(i.CRC), str(i.compress_type),
                              "%04d-%02d-%02d %02d:%02d:%02d" % i.date_time, str(i.flag_bits)]))
    return "\n".join(out) + "\n"

def expect(name):
    path = os.path.join(d, name)
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None, name
        for i in z.infolist():
            assert zlib.crc32(z.read(i)) == i.CRC, (name, i.filename)
        text_ = lines_of(z)
    # newline="": Windows' text mode wrote \r\n, which the listing is not.
    with open(path[:-4] + ".expect", "w", encoding="utf-8", newline="") as f:
        f.write(text_)
    index.append(name)

with zipfile.ZipFile(os.path.join(d, "py-stored.zip"), "w", zipfile.ZIP_STORED) as z:
    z.writestr(info("hello.txt", zipfile.ZIP_STORED), b"hello, world\n")
    z.writestr(info("empty", zipfile.ZIP_STORED), b"")
    z.writestr(info("binary.bin", zipfile.ZIP_STORED), binary)
    z.writestr(info("dir/", zipfile.ZIP_STORED), b"")
expect("py-stored.zip")

with zipfile.ZipFile(os.path.join(d, "py-deflated.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    for level in (1, 6, 9):
        z.writestr(info("text-%d.txt" % level), text, compresslevel=level)
    z.writestr(info("binary.bin"), binary)
    z.writestr(info("empty"), b"")
expect("py-deflated.zip")

with zipfile.ZipFile(os.path.join(d, "py-comment.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr(info("a.txt"), b"a comment follows the directory\n")
    z.comment = b"a comment, written by Python's zipfile"
expect("py-comment.zip")

# ZIP64 the way Python writes it when asked: the extended field in the
# local header of each entry streamed with force_zip64.
with zipfile.ZipFile(os.path.join(d, "py-zip64.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    with z.open(info("forced.txt"), "w", force_zip64=True) as f:
        f.write(text)
    with z.open(info("forced.bin", zipfile.ZIP_STORED), "w", force_zip64=True) as f:
        f.write(binary)
    z.writestr(info("plain.txt"), b"not forced")
expect("py-zip64.zip")

# And the way it writes past its limits, with the limit lowered so a
# small archive is past it: the extended field in the central directory
# for sizes and offsets, and the ZIP64 end records.
saved = zipfile.ZIP64_LIMIT
zipfile.ZIP64_LIMIT = 1000
with zipfile.ZipFile(os.path.join(d, "py-zip64-limit.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr(info("big.bin", zipfile.ZIP_STORED), binary)
    z.writestr(info("after.txt"), text)
    z.writestr(info("small.txt"), b"small")
zipfile.ZIP64_LIMIT = saved
expect("py-zip64-limit.zip")
raw = open(os.path.join(d, "py-zip64-limit.zip"), "rb").read()
assert b"PK\x06\x06" in raw and b"PK\x06\x07" in raw, "py-zip64-limit has no ZIP64 end records"

# More entries than 16 bits count: the ZIP64 end records, unasked.
with zipfile.ZipFile(os.path.join(d, "py-many.zip"), "w", zipfile.ZIP_STORED) as z:
    for i in range(66000):
        z.writestr(info("m/%d" % i, zipfile.ZIP_STORED), b"%d" % i if i % 997 == 0 else b"")
expect("py-many.zip")

# A stream Python cannot seek: every entry with a data descriptor.
class Unseekable:
    def __init__(self, f):
        self.f = f
    def write(self, b):
        return self.f.write(b)
    def flush(self):
        self.f.flush()
with open(os.path.join(d, "py-stream.zip"), "wb") as raw_f:
    with zipfile.ZipFile(Unseekable(raw_f), "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(info("streamed.txt"), text)
        z.writestr(info("streamed.bin", zipfile.ZIP_STORED), binary)
        z.writestr(info("empty"), b"")
expect("py-stream.zip")
with zipfile.ZipFile(os.path.join(d, "py-stream.zip")) as z:
    assert all(i.flag_bits & 8 for i in z.infolist()), "py-stream has no data descriptors"

with zipfile.ZipFile(os.path.join(d, "py-unicode.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr(info("çay/ğüş.txt"), "türkçe\n".encode())
    z.writestr(info("日本語.txt"), "日本\n".encode())
    z.writestr(info("emoji-🎉.txt"), b"party\n")
    z.writestr(info("plain-ascii.txt"), b"ascii\n")
expect("py-unicode.zip")

# Code page 437: Python writes only ASCII or UTF-8 names, so the name is
# written as ASCII and its bytes changed after, in both headers; 0x82 is
# é and 0x81 ü in the code page, and bit 11 is clear.
with zipfile.ZipFile(os.path.join(d, "py-cp437.zip"), "w", zipfile.ZIP_STORED) as z:
    z.writestr(info("caf_-m_nu.txt", zipfile.ZIP_STORED), b"cp437\n")
path = os.path.join(d, "py-cp437.zip")
data = open(path, "rb").read().replace(b"caf_-m_nu", b"caf\x82-m\x81nu")
open(path, "wb").write(data)
expect("py-cp437.zip")
with zipfile.ZipFile(path) as z:
    assert z.namelist() == ["café-münu.txt"], z.namelist()

# Info-ZIP's Unicode Path field (0x7075): a UTF-8 name beside the one in
# the header, taken when the CRC-32 it carries is the header name's, and
# passed over when it is stale (the header name changed after).
def unicode_path(header, utf8, crc):
    zi = info(header, zipfile.ZIP_STORED)
    zi.extra = struct.pack("<HHBI", 0x7075, 5 + len(utf8), 1, crc) + utf8
    return zi
with zipfile.ZipFile(os.path.join(d, "py-unicode-path.zip"), "w", zipfile.ZIP_STORED) as z:
    z.writestr(unicode_path("legacy-name.txt", "ünïcode-path.txt".encode(), zlib.crc32(b"legacy-name.txt")), b"taken\n")
    z.writestr(unicode_path("stale-name.txt", "never-used.txt".encode(), zlib.crc32(b"another-name")), b"passed over\n")
expect("py-unicode-path.zip")
with zipfile.ZipFile(os.path.join(d, "py-unicode-path.zip")) as z:
    assert z.namelist() == ["ünïcode-path.txt", "stale-name.txt"], z.namelist()

# A comment holding an end record's signature, a false record with
# nothing in it whose comment length does not reach the end: the real
# record is the one that does. Python's own scan takes the last
# signature and reads the false record, so the expectation is what the
# writing ZipFile listed.
path = os.path.join(d, "py-fakesig.zip")
with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr(info("real.txt"), b"the real directory has this\n")
    z.comment = b"before " + b"PK\x05\x06" + bytes(18) + b" after"
    listed = lines_of(z)
# The flags as the central directory holds them, read from the bytes at
# the real end record: a writing ZipFile's own listing carried 0x800 on
# darwin's Python where the archive it wrote has 0.
import struct
data = open(path, "rb").read()
end = len(data) - 22 - len(b"before " + b"PK\x05\x06" + bytes(18) + b" after")
directory = struct.unpack_from("<I", data, end + 16)[0]
flags = struct.unpack_from("<H", data, directory + 8)[0]
listed = "".join(l.rsplit("\t", 1)[0] + "\t" + str(flags) + "\n" if l.startswith("entry\t") else l + "\n" for l in listed.splitlines())
with open(path[:-4] + ".expect", "w", encoding="utf-8", newline="") as f:
    f.write(listed)
index.append("py-fakesig.zip")

# The other methods, as Python 3.14's zipfile writes them: bzip2 (12),
# LZMA (14, with its end marker and bit 1) and Zstandard (93) are its
# own; xz (95, in APPNOTE 4.4.5's list) it does not write, and is given
# it here through the three functions zipfile picks a method's
# compressor with, the entry's data an .xz stream. The content is
# written beside them for the exercise to compare whole:
# `method-big.bin`, past bzip2's 900,000-byte block so a bzip2 entry is
# more than one block, and the binary above.
big = b"".join(b"%06d: a line for the other methods, %d\n" % (i, i % 977) for i in range(28000))
assert len(big) > 900000
open(os.path.join(d, "method-big.bin"), "wb").write(big)
open(os.path.join(d, "method-binary.bin"), "wb").write(binary)
ZIP_XZ = 95
check_compression, get_compressor, get_decompressor = zipfile._check_compression, zipfile._get_compressor, zipfile._get_decompressor
def xz_check(method):
    if method != ZIP_XZ:
        check_compression(method)
def xz_compressor(method, level=None):
    if method == ZIP_XZ:
        return lzma.LZMACompressor(lzma.FORMAT_XZ, preset=6 if level is None else level)
    return get_compressor(method, level)
def xz_decompressor(method):
    if method == ZIP_XZ:
        return lzma.LZMADecompressor(lzma.FORMAT_XZ)
    return get_decompressor(method)
zipfile._check_compression, zipfile._get_compressor, zipfile._get_decompressor = xz_check, xz_compressor, xz_decompressor

def method_entry(name, method):
    zi = info(name, method)
    if method == ZIP_XZ:
        zi.extract_version = zi.create_version = 63
    return zi
def common(z, method):
    z.writestr(method_entry("big.txt", method), big)
    z.writestr(method_entry("binary.bin", method), binary)
    z.writestr(method_entry("empty", method), b"")
    z.writestr(method_entry("small.txt", method), b"hello, world\n")
with zipfile.ZipFile(os.path.join(d, "py-bzip2.zip"), "w") as z:
    common(z, zipfile.ZIP_BZIP2)
    # Blocks of 100,000 bytes: ten blocks.
    z.writestr(method_entry("big-1.txt", zipfile.ZIP_BZIP2), big, compresslevel=1)
expect("py-bzip2.zip")
with zipfile.ZipFile(os.path.join(d, "py-lzma.zip"), "w") as z:
    common(z, zipfile.ZIP_LZMA)
expect("py-lzma.zip")
with zipfile.ZipFile(os.path.join(d, "py-zstd.zip"), "w") as z:
    common(z, zipfile.ZIP_ZSTANDARD)
    z.writestr(method_entry("big-19.txt", zipfile.ZIP_ZSTANDARD), big, compresslevel=19)
    # Level 22 streamed names a window of 128 MiB, past the 8 MiB
    # ZstdReader takes unless asked; 200,000 bytes, as it is slow.
    z.writestr(method_entry("wide-22.txt", zipfile.ZIP_ZSTANDARD), big[:200000], compresslevel=22)
expect("py-zstd.zip")
with zipfile.ZipFile(os.path.join(d, "py-zstd.zip")) as z:
    at = z.getinfo("wide-22.txt").header_offset
raw = open(os.path.join(d, "py-zstd.zip"), "rb").read()
at += 30 + sum(struct.unpack_from("<HH", raw, at + 26))
assert raw[at:at + 4] == b"\x28\xb5\x2f\xfd" and raw[at + 4] & 0x20 == 0 and raw[at + 5] >> 3 >= 14, "wide-22.txt names no window past 8 MiB"
with zipfile.ZipFile(os.path.join(d, "py-xz.zip"), "w") as z:
    common(z, ZIP_XZ)
    z.writestr(method_entry("big-0.txt", ZIP_XZ), big, compresslevel=0)
expect("py-xz.zip")
# Every method to a stream Python cannot seek: data descriptors.
with open(os.path.join(d, "py-methods-stream.zip"), "wb") as raw_f:
    with zipfile.ZipFile(Unseekable(raw_f), "w") as z:
        for name, method in (("bzip2.txt", zipfile.ZIP_BZIP2), ("lzma.txt", zipfile.ZIP_LZMA),
                             ("zstd.txt", zipfile.ZIP_ZSTANDARD), ("xz.txt", ZIP_XZ)):
            z.writestr(method_entry(name, method), big)
expect("py-methods-stream.zip")
with zipfile.ZipFile(os.path.join(d, "py-methods-stream.zip")) as z:
    assert all(i.flag_bits & 8 for i in z.infolist()), "py-methods-stream has no data descriptors"

# Info-ZIP's zip, where it is installed: a tree, written to a file and
# to a pipe (which it cannot seek, so it writes data descriptors). Its
# names are not flagged UTF-8; the Unicode Path field carries them.
if shutil.which("zip"):
    tree = os.path.join(d, "tree")
    os.makedirs(os.path.join(tree, "sub", "deeper"))
    os.makedirs(os.path.join(tree, "empty"))
    files = {"a.txt": text[:5000], "sub/b.bin": binary, "sub/deeper/c.txt": b"deep\n",
             "zero": b"", "ünï.txt": "ünï\n".encode(), "sub/big.txt": big}
    for name, body in files.items():
        with open(os.path.join(tree, name), "wb") as f:
            f.write(body)
    stamp = 1700000000
    for root, dirs, names in os.walk(tree):
        for n in names + dirs:
            os.utime(os.path.join(root, n), (stamp, stamp))
    os.utime(tree, (stamp, stamp))
    subprocess.run(["zip", "-q", "-r", "zip-tree.zip", "tree"], cwd=d, check=True)
    expect("zip-tree.zip")
    piped = subprocess.run(["zip", "-q", "-r", "-", "tree"], cwd=d, check=True, stdout=subprocess.PIPE).stdout
    with open(os.path.join(d, "zip-stream.zip"), "wb") as out:
        out.write(piped)
    expect("zip-stream.zip")
    with zipfile.ZipFile(os.path.join(d, "zip-stream.zip")) as z:
        assert any(i.flag_bits & 8 for i in z.infolist()), "zip to a pipe wrote no data descriptors"
    # bzip2 (-Z bzip2) where this zip was built with it, to a file and to
    # a pipe; what does not shrink it stores, as it does with deflate.
    if b"BZIP2_SUPPORT" in subprocess.run(["zip", "-v"], check=True, stdout=subprocess.PIPE).stdout:
        subprocess.run(["zip", "-q", "-r", "-Z", "bzip2", "zip-bzip2.zip", "tree"], cwd=d, check=True)
        expect("zip-bzip2.zip")
        piped = subprocess.run(["zip", "-q", "-r", "-Z", "bzip2", "-", "tree"], cwd=d, check=True, stdout=subprocess.PIPE).stdout
        with open(os.path.join(d, "zip-bzip2-stream.zip"), "wb") as out:
            out.write(piped)
        expect("zip-bzip2-stream.zip")
        for name in ("zip-bzip2.zip", "zip-bzip2-stream.zip"):
            with zipfile.ZipFile(os.path.join(d, name)) as z:
                bz = [i.filename for i in z.infolist() if i.compress_type == zipfile.ZIP_BZIP2]
                assert "tree/sub/big.txt" in bz and "tree/a.txt" in bz, (name, bz)
    else:
        print("  zip(1) here has no bzip2: the zip -Z bzip2 archives are not compared")
    shutil.rmtree(tree)
else:
    print("  no zip(1) on this machine: the zip -r archives are not compared")

with open(os.path.join(d, "index.txt"), "w", newline="") as f:
    f.write("\n".join(index) + "\n")
PY
then
  echo "the fixtures could not be written"
  exit 1
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_zip_exercise.iyi" \
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

echo "== the std/zip exercise, plain build"
build_and_run "plain" zip-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/zip-plain.out" 2>/dev/null; then
  echo "plain: ALL CHECKS PASSED missing"
  status=1
fi

echo
echo "== every zip section reported"
for phrase in "== round trips" "== streaming reads" "== times" "== zip64" "== reading a file" \
              "== refused as a value" "== names" "== extract" "== other methods" "== what python wrote" \
              "== other methods, as python wrote them" "== written for python"; do
  if ! grep -qF "$phrase" "$WORK/zip-plain.out"; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== what iyi wrote, read by Python's zipfile"
# Each archive the exercise wrote, read by Python: every entry's CRC-32
# checked (`testzip`) and its content's CRC-32 taken again, and the
# entries as Python lists them the same lines the exercise wrote for
# them. Then what each one was written to show.
"$PY" - "$WORK/fixtures" <<'PY' || status=1
import os, sys, zipfile, zlib
d = sys.argv[1]
failed = False
def lines_of(z):
    out = ["comment\t" + z.comment.hex()]
    for i in z.infolist():
        out.append("\t".join(["entry", i.filename, str(i.file_size), str(i.CRC), str(i.compress_type),
                              "%04d-%02d-%02d %02d:%02d:%02d" % i.date_time, str(i.flag_bits)]))
    return "\n".join(out) + "\n"
for name in ("out-round", "out-zip64", "out-many", "out-empty", "out-bzip2", "out-zstd"):
    path = os.path.join(d, name + ".zip")
    with zipfile.ZipFile(path) as z:
        bad = z.testzip()
        if bad is not None:
            print("  %s: Python finds %r corrupt" % (name, bad)); failed = True; continue
        for i in z.infolist():
            if zlib.crc32(z.read(i)) != i.CRC:
                print("  %s: %s reads back with another CRC-32" % (name, i.filename)); failed = True
        got = lines_of(z)
        infos = z.infolist()
        comment = z.comment
    want = open(os.path.join(d, name + ".expect"), encoding="utf-8").read()
    if got != want:
        print("  %s: Python lists the entries differently" % name)
        for a, b in zip(got.splitlines(), want.splitlines()):
            if a != b:
                print("    python: %r\n    iyi:    %r" % (a, b)); break
        failed = True
        continue
    raw = open(path, "rb").read()
    if name == "out-round":
        with zipfile.ZipFile(path) as z:
            assert z.read("stored.txt") == b"hello, world"
            assert z.read("dir/nested/çay ğ.txt") == "türkçe içerik\n".encode()
        flagged = [i.filename for i in infos if i.flag_bits & 0x800]
        streamed = [i.filename for i in infos if i.flag_bits & 8]
        if flagged != ["dir/nested/çay ğ.txt", "日本語/ファイル.txt"] or streamed != ["streamed-deflated.txt", "streamed-stored.bin", "streamed-empty"] \
           or comment != b"the archive's comment" or b"PK\x06\x06" in raw:
            print("  out-round: flags %r, descriptors %r, comment %r" % (flagged, streamed, comment)); failed = True
        else:
            print("  out-round: %d entries, UTF-8 names flagged, streamed entries with descriptors" % len(infos))
    elif name == "out-zip64":
        wide = [i.filename for i in infos if i.extra[:2] == b"\x01\x00"]
        if len(wide) != len(infos) or b"PK\x06\x06" not in raw or b"PK\x06\x07" not in raw:
            print("  out-zip64: extended fields on %r, end records %s" % (wide, b"PK\x06\x06" in raw)); failed = True
        else:
            print("  out-zip64: %d entries, each with the ZIP64 field, and the ZIP64 end records" % len(infos))
    elif name == "out-many":
        if len(infos) != 70000 or b"PK\x06\x06" not in raw:
            print("  out-many: %d entries" % len(infos)); failed = True
        else:
            print("  out-many: 70000 entries through the ZIP64 end record")
    elif name in ("out-bzip2", "out-zstd"):
        method, version = (zipfile.ZIP_BZIP2, 46) if name == "out-bzip2" else (zipfile.ZIP_ZSTANDARD, 63)
        with zipfile.ZipFile(path) as z:
            small = z.read("small.txt")
        off = [(i.filename, i.compress_type, i.extract_version) for i in infos if i.compress_type != method or i.extract_version != version]
        if off or small != b"hello, world\n":
            print("  %s: entries in another method or version: %r" % (name, off)); failed = True
        else:
            print("  %s: %d entries, method %d, version needed %d.%d, each read to its CRC-32" % (name, len(infos), method, version // 10, version % 10))
    else:
        if infos or len(raw) != 22:
            print("  out-empty: %d entries in %d bytes" % (len(infos), len(raw))); failed = True
        else:
            print("  out-empty: no entries, the 22-byte end record alone")
sys.exit(1 if failed else 0)
PY

if command -v unzip >/dev/null 2>&1; then
  echo
  echo "== what iyi wrote, tested by Info-ZIP's unzip"
  # Not out-empty: unzip answers any empty archive with "zipfile is
  # empty" and exit 1, Python's included. out-bzip2 where this unzip was
  # built with bzip2; out-zstd never, as UnZip 6.0 has no Zstandard.
  names="out-round out-zip64 out-many out-file"
  if unzip -v 2>/dev/null | grep -q USE_BZIP2; then
    names="$names out-bzip2"
  else
    echo "  this unzip has no bzip2: out-bzip2 is not tested by it"
  fi
  for name in $names; do
    if unzip -tqq "$WORK/fixtures/$name.zip" >"$WORK/unzip.out" 2>&1; then
      echo "  $name: unzip -t finds no errors"
    else
      echo "  $name: unzip -t refused it"
      sed -n '1,6p' "$WORK/unzip.out" | sed 's/^/    /'
      status=1
    fi
  done
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" zip-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/zip-release.out" 2>/dev/null; then
  echo "release: ALL CHECKS PASSED missing"
  tail -3 "$WORK/zip-release.out"
  status=1
else
  echo "  ALL CHECKS PASSED"
fi

echo
echo "== what the module refuses, by name"
# A malformed archive is a ZipError value, checked by the exercise; what
# panics is the caller's own mistake, and an error the caller chose to
# panic on (`or_panic`) panics with its sentence exactly.
refuses() { # refuses <label> <name> <phrase> <statements>
  local label="$1" name="$2" phrase="$3" statements="$4"
  printf 'module main\n\nimport std/zip::{ZipReader, ZipWriter, ZipEntry, ZipError, ZipMethod}\nimport std/io::{Memory}\n\n%s\nputs "ANSWERED"\n' \
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
refuses "an add after finish" add_after "ZipWriter: add after finish" \
  'w = ZipWriter.new(Memory.new)
w.finish
w.add("a", "b")'
refuses "finish twice" finish_twice "ZipWriter: finish was called twice" \
  'w = ZipWriter.new(Memory.new)
w.finish
w.finish'
refuses "a name twice" twice "ZipWriter: \"a.txt\" is already in the archive" \
  'w = ZipWriter.new(Memory.new)
w.add("a.txt", "1")
w.add("a.txt", "2")'
refuses "an absolute name" absolute "ZipWriter: \"/etc/passwd\" is absolute; a name in an archive is relative" \
  'ZipWriter.new(Memory.new).add("/etc/passwd", "x")'
refuses "a name with a backslash" backslash 'ZipWriter: "a\\b" holds a \; a name in an archive separates with /' \
  'ZipWriter.new(Memory.new).add("a\\b", "x")'
refuses "an empty name" empty_name "ZipWriter: an entry needs a name" \
  'ZipWriter.new(Memory.new).add("", "x")'
refuses "a comment past 65535 bytes" long_comment "ZipWriter: the comment is 65536 bytes, and the format holds 65535" \
  'ZipWriter.new(Memory.new).finish("x" * 65536)'
refuses "a read of no bytes" read_zero "ZipEntryReader: read wants at least one byte, not 0" \
  'm = Memory.new
w = ZipWriter.new(m)
w.add("a", "b")
w.finish
z = ZipReader.open(m.to_s).or_panic
z.open(z.entries[0]).or_panic.read(0)'
refuses "an entry of another archive" foreign 'ZipReader: the entry "b" is not from this archive' \
  'm = Memory.new
w = ZipWriter.new(m)
w.add("a", "x", ZipMethod::Stored)
w.add("b", "y", ZipMethod::Stored)
w.finish
n = Memory.new
v = ZipWriter.new(n)
v.add("b", "y", ZipMethod::Stored)
v.finish
z = ZipReader.open(n.to_s).or_panic
other = ZipReader.open(m.to_s).or_panic
z.open(other.entries[1]).or_panic'
refuses "not an archive, or_panic" not_zip "zip: there is no end of central directory record: not a zip archive, or one cut short" \
  'ZipReader.open("not a zip").or_panic'
refuses "bzip2 asked of a streamed entry" streamed_bzip2 'ZipWriter: "s.bz2" is streamed, and bzip2 is written from a String, whole' \
  'ZipWriter.new(Memory.new).add("s.bz2", Memory.new("x"), ZipMethod::Bzip2)'
refuses "Zstandard asked of a streamed entry" streamed_zstd 'ZipWriter: "s.zst" is streamed, and Zstandard is written from a String, whole' \
  'ZipWriter.new(Memory.new).add("s.zst", Memory.new("x"), ZipMethod::Zstandard)'

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
src = Path("$REPO/src/std/zip.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing: " + os.environ["OLD"])
Path("$WORK/patched/std/zip.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  # Build first, then run: a patch that does not compile would also "fail",
  # and that proves nothing about whether the exercise catches the break.
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mut-$mutations.bin" "$REPO/bench/std_zip_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
prove_broken "a CRC-32 never compared" "a flipped byte is refused by its CRC-32" \
  'unless @crc == @entry.crc32' 'unless true'
prove_broken "the last piece handed out before the end is checked" "a bad last piece is not handed out" \
  'if piece.empty? || ended?' 'if piece.empty?'
prove_broken "content inflating past its declared size" "inflating past the declared size" \
  'if piece.bytesize.to_i64 > @entry.size - @got' 'if false'
prove_broken "overlapping entries not checked at open" "overlapping entries refused at open" \
  'if e.compressed_size > stop - e.offset - span' 'if false'
prove_broken "no limit on the total size" "the limit refuses one byte less" \
  'if size > limit - total' 'if false'
prove_broken "an encrypted entry read" "encrypted refused" \
  'which this reader does not decrypt") if entry.encrypted?' 'which this reader does not decrypt") if false'
prove_broken "a local header naming another file" "a local name that is not the directory's" \
  'unless local_name == entry.raw_name' 'unless true'
prove_broken "a data descriptor's CRC-32 never compared" "descriptor CRC that disagrees" \
  'unless said == @entry.crc32' 'unless true'
prove_broken "a name climbing out with .. extracted" "zip slip ../evil.txt" \
  '    return "the name climbs out with .." if name.split('"'"'/'"'"').includes?("..")
' ''
prove_broken "the end record scan taking a false one in the comment" "py-fakesig.zip: entries as Python read them" \
  '        return at if reach == n
' ''
prove_broken "the ZIP64 locator ignored" "70000 entries" \
  'if ZipBytes.u32(lp, 0) == ZipBytes::LOCATOR64' 'if false'
prove_broken "the ZIP64 field read out of order" "ZIP64 forced" \
  'usize = ZipBytes.u64(p, f)' 'usize = ZipBytes.u64(p, f + 8)'
prove_broken "code page 437 with a wrong é" "code page 437 decoded" \
  '0xc7, 0xfc, 0xe9,' '0xc7, 0xfc, 0xe8,'
prove_broken "a UTF-8 name written without bit 11" "utf8 flag set for a non-ASCII name" \
  'return 0x800 if p[i] >= 0x80_u8' 'return 0 if p[i] >= 0x80_u8'
prove_broken "a stale Unicode Path field taken" "py-unicode-path.zip: entries as Python read them" \
  'if ZipBytes.u32(p, body + 1) == CRC32.checksum(raw)' 'if true'
prove_broken "a streamed entry written without its descriptor flag" "streamed entries carry a data descriptor" \
  'flags = name_flags(name) | 8' 'flags = name_flags(name)'
prove_broken "seconds written whole, not in two-second steps" "modification time" \
  '(t.second // 2)}' 't.second}'
# The other methods.
prove_broken "xz not among the methods read" "py-xz.zip" \
  '|| m == 93 || m == 95' '|| m == 93'
prove_broken "an LZMA entry's own header handed to the decoder" "py-lzma.zip" \
  'skip = method == 14 ? 9_i64 : 0_i64' 'skip = method == 14 ? 4_i64 : 0_i64'
prove_broken "LZMA properties of any size taken" "LZMA properties that are not five bytes" \
  'unless props == 5' 'if false'
prove_broken "bit 1 ignored, an LZMA entry always ended by its size" "an LZMA entry with bit 1 is read to its marker" \
  'size = entry.flags & 2 != 0 ? 0xffffffffffffffff_u64 : entry.size.to_u64' 'size = entry.size.to_u64'
prove_broken "bit 1 ignored, an LZMA entry always ended by a marker" "an LZMA entry without bit 1 ends at its size" \
  'size = entry.flags & 2 != 0 ? 0xffffffffffffffff_u64 : entry.size.to_u64' 'size = 0xffffffffffffffff_u64'
prove_broken "Zstandard held to ZstdReader's 8 MiB window" "wide-22.txt" \
  'ZSTD_WINDOW = 536870912' 'ZSTD_WINDOW = 8388608'
prove_broken "LZMA held to XzReader's 64 MiB dictionary" "a 256 MiB LZMA dictionary" \
  'XzReader::DICT_MAX) do' 'XzReader::DICT_LIMIT) do'
prove_broken "bzip2 written needing 4.5 or less" "bzip2 needs version 4.6" \
  'return 46 if method == 12' 'return 46 if false'
prove_broken "Zstandard written needing 2.0" "zstd needs version 6.3" \
  'return 63 if method == 93' 'return 63 if false'
prove_broken "bzip2 asked for and the entry stored" "bzip2 written" \
  'when ZipMethod::Bzip2     then Bzip2.compress(data)' 'when ZipMethod::Bzip2     then data'
prove_broken "Zstandard asked for and the entry bzip2" "zstd written" \
  'when ZipMethod::Zstandard then Zstd.compress(data)' 'when ZipMethod::Zstandard then Bzip2.compress(data)'
prove_broken "a decoder's sentence dropped from its refusal" "a stored entry said to be bzip2" \
  'ZipError.new("zip: #{@entry.name.inspect}: #{got.message}")' 'ZipError.new("zip: #{@entry.name.inspect}")'

echo
echo "== doc, format, other platforms and artifacts"
if "$IYI" doc "$REPO/src/std/zip.iyi" >"$WORK/doc.txt" 2>&1 && grep -q "Zstandard = 93" "$WORK/doc.txt"; then
  echo "  iyi doc reads std/zip ($(grep -c '^ *def ' "$WORK/doc.txt") methods), ZipMethod with bzip2 and Zstandard"
else
  echo "  iyi doc fails: $(grep -m1 -E 'Error|BUG' "$WORK/doc.txt")"
  status=1
fi
if [ -x "$REPO/bin/crystal" ]; then
  if "$REPO/bin/crystal" tool format --check "$REPO/src/std/zip.iyi" "$REPO/bench/std_zip_exercise.iyi" >"$WORK/format.log" 2>&1; then
    echo "  the module and its exercise are formatted"
  else
    echo "  not formatted: $(grep -m1 produced "$WORK/format.log")"
    status=1
  fi
fi
apart=""
for target in x86_64-linux-gnu aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  if ! "$IYI" build --no-codegen --target "$target" -o "$WORK/cross" "$REPO/bench/std_zip_exercise.iyi" >"$WORK/cross.log" 2>&1; then
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
# With the fixtures, so the other methods' readers are among what the
# artifacts carry and run.
mkdir -p "$WORK/r1/mods"
if (cd "$WORK/r1" && "$IYI" build --emit-iyimod mods -o from-source "$REPO/bench/std_zip_exercise.iyi" \
  && "$IYI" build --use-iyimod mods -o from-artifact "$REPO/bench/std_zip_exercise.iyi") >"$WORK/r1/build.log" 2>&1; then
  "$WORK/r1/from-source" "$WORK/fixtures" >"$WORK/r1/source.out" 2>&1
  "$WORK/r1/from-artifact" "$WORK/fixtures" >"$WORK/r1/artifact.out" 2>&1
  if cmp -s "$WORK/r1/source.out" "$WORK/r1/artifact.out" && grep -q "ALL CHECKS PASSED" "$WORK/r1/artifact.out"; then
    echo "  built from its artifacts, the exercise prints what it prints from source ($(wc -l <"$WORK/r1/source.out" | tr -d ' ') lines)"
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
  echo "the std/zip exercise holds ($mutations broken copies caught)"
else
  echo "the std/zip exercise did not hold"
fi
exit $status
