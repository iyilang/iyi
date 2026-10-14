#!/usr/bin/env bash
# Exercises `std/tar`: tar archives read and written in iyi, against
# Python's `tarfile` as the oracle in both directions, and GNU tar where
# the machine has it.
#
#     bash bench/std_tar_exercise.sh
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

trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

# GNU tar, when `tar` is GNU's: bsdtar and busybox read and write other
# dialects and are not what this checks against.
GNUTAR=""
if command -v tar >/dev/null 2>&1 && tar --version 2>/dev/null | grep -q "GNU tar"; then
  GNUTAR=tar
fi

# The archives Python (and GNU tar) write, each with the `.expect` Python
# reads from it: per entry its name, kind, size, mode, mtime (a pax
# mtime as written, trailing zeros dropped), ids, user and group names,
# link target and the CRC-32 of a regular file's data. The exercise
# reads each archive and must print the same lines. `index.txt` lists
# them in order.
#
# Without an interpreter there is no oracle at all, and every comparison
# below would be against an empty directory: that is the gate's failure,
# said here, not the module's.
mkdir -p "$WORK/fixtures"
if [ -z "$PY" ]; then
  echo "no python3 on this machine: the oracle cannot be produced"
  exit 1
fi
cat > "$WORK/oracle.py" <<'PY'
import tarfile, zlib

def kind(ti):
    if ti.isreg():
        return "file"
    if ti.isdir():
        return "dir"
    if ti.issym():
        return "symlink"
    if ti.islnk():
        return "hardlink"
    if ti.ischr():
        return "chr"
    if ti.isblk():
        return "blk"
    if ti.isfifo():
        return "fifo"
    return "other"

def lines_of(path):
    out = []
    with tarfile.open(path) as t:
        for ti in t:
            m = ti.pax_headers.get("mtime")
            if m is None:
                mt = str(int(ti.mtime))
            else:
                mt = m.rstrip("0").rstrip(".") if "." in m else m
            crc = str(zlib.crc32(t.extractfile(ti).read())) if ti.isreg() else "-"
            out.append("\t".join(["entry", ti.name, kind(ti), str(ti.size), "%o" % ti.mode, mt, str(ti.uid), str(ti.gid),
                                  ti.uname, ti.gname, ti.linkname, crc]))
    return "".join(l + "\n" for l in out)
PY
if ! GNUTAR="$GNUTAR" "$PY" - "$WORK/fixtures" "$WORK/oracle.py" <<'PY'
import io, os, random, shutil, subprocess, sys, tarfile
sys.path.insert(0, os.path.dirname(sys.argv[2]))
from oracle import lines_of

d = sys.argv[1]
T = 1700000000
rng = random.Random(1)
binary = bytes(rng.getrandbits(8) for _ in range(70000))
text = b"".join(b"line %d of a text that compresses well\n" % i for i in range(20000))
index = []

def expect(name):
    path = os.path.join(d, name)
    stem = name[:-7] if name.endswith(".tar.gz") else name[:-4]
    with open(os.path.join(d, stem + ".expect"), "w", encoding="utf-8") as f:
        f.write(lines_of(path))
    index.append(name)

def info(name, type=tarfile.REGTYPE, mode=0o644, mtime=T, uid=0, gid=0, uname="", gname="", linkname="", pax=None):
    ti = tarfile.TarInfo(name)
    ti.type, ti.mode, ti.mtime, ti.uid, ti.gid = type, mode, mtime, uid, gid
    ti.uname, ti.gname, ti.linkname = uname, gname, linkname
    if pax:
        ti.pax_headers = pax
    return ti

def add(t, ti, data=None):
    if data is None:
        t.addfile(ti)
    else:
        ti.size = len(data)
        t.addfile(ti, io.BytesIO(data))

def common(t):
    add(t, info("hello.txt", uid=1000, gid=1000, uname="naruto", gname="users"), b"hello, world\n")
    add(t, info("binary.bin", mode=0o600), binary)
    add(t, info("text.txt"), text)
    add(t, info("empty"), b"")
    add(t, info("dir", tarfile.DIRTYPE, 0o755))
    add(t, info("dir/script.sh", mode=0o755), b"#!/bin/sh\necho hi\n")
    add(t, info("dir/" + "p" * 60 + "/" + "q" * 80 + ".txt"), b"split")
    add(t, info("dir/link", tarfile.SYMTYPE, 0o777, linkname="../hello.txt"))
    add(t, info("again.txt", tarfile.LNKTYPE, linkname="hello.txt"))

# ustar, as Python writes USTAR_FORMAT: a long name split by prefix,
# a UTF-8 name in the name field as it is.
for name, mode in (("py-ustar.tar", "w"), ("py-ustar.tar.gz", "w:gz")):
    with tarfile.open(os.path.join(d, name), mode, format=tarfile.USTAR_FORMAT, encoding="utf-8") as t:
        common(t)
        add(t, info("dir/çay ğ.txt"), "türkçe içerik\n".encode())
    expect(name)

# GNU_FORMAT: long names and link names through ././@LongLink, an id
# and a time out of octal's reach in base-256.
with tarfile.open(os.path.join(d, "py-gnu.tar"), "w", format=tarfile.GNU_FORMAT) as t:
    common(t)
    long_name = "d/" + "N" * 200
    add(t, info("d", tarfile.DIRTYPE, 0o755))
    add(t, info(long_name), b"a long name")
    add(t, info("d/long-link", tarfile.SYMTYPE, 0o777, linkname="T" * 150))
    add(t, info("d/long-hard", tarfile.LNKTYPE, linkname=long_name))
    add(t, info("d/big-ids.txt", uid=3000000, gid=4000000), b"ids")
    add(t, info("d/old.txt", mtime=-1000), b"before 1970")
expect("py-gnu.tar")

# PAX_FORMAT, with a global header: long and non-ASCII names, a time
# with nine digits of fraction, a negative one, ids and names past what
# ustar holds.
for name, mode in (("py-pax.tar", "w"), ("py-pax.tar.gz", "w:gz")):
    with tarfile.open(os.path.join(d, name), mode, format=tarfile.PAX_FORMAT, pax_headers={"comment": "written by python"}) as t:
        common(t)
        add(t, info("p/" + "N" * 200), b"a long name")
        add(t, info("p/日本語/ファイル.txt"), "こんにちは".encode())
        add(t, info("p/frac.txt", pax={"mtime": "1700000000.123456789"}), b"fraction")
        add(t, info("p/negative.txt", pax={"mtime": "-1.25"}), b"negative")
        add(t, info("p/old.txt", mtime=-1000), b"before 1970")
        add(t, info("p/big-ids.txt", uid=3000000, gid=4000000, uname="u" * 40, gname="kullanıcılar"), b"ids")
        add(t, info("p/long-link", tarfile.SYMTYPE, 0o777, linkname="T" * 150))
    expect(name)

# Devices and a FIFO, which extract refuses: listed, not extracted.
with tarfile.open(os.path.join(d, "py-special.tar"), "w", format=tarfile.USTAR_FORMAT) as t:
    c = info("dev/null", tarfile.CHRTYPE, 0o666)
    c.devmajor, c.devminor = 1, 3
    add(t, c)
    b = info("dev/sda", tarfile.BLKTYPE, 0o660)
    b.devmajor, b.devminor = 8, 0
    add(t, b)
    add(t, info("fifo", tarfile.FIFOTYPE))
    add(t, info("after.txt"), b"after the specials")
expect("py-special.tar")

# GNU tar's own, from a tree on disk, in each of its formats.
gnutar = os.environ.get("GNUTAR")
if gnutar:
    tree = os.path.join(d, "..", "tree")
    shutil.rmtree(tree, ignore_errors=True)
    os.makedirs(os.path.join(tree, "dir", "çay ğ"))
    os.makedirs(os.path.join(tree, "emptydir"))
    def put(rel, data, mode=0o644):
        p = os.path.join(tree, rel)
        with open(p, "wb") as f:
            f.write(data)
        os.chmod(p, mode)
    put("hello.txt", b"hello, world\n")
    put("binary.bin", binary, 0o600)
    put("dir/script.sh", b"#!/bin/sh\necho hi\n", 0o755)
    put("dir/çay ğ/日本語.txt", "こんにちは".encode())
    put("dir/" + "N" * 150, b"a long name")
    os.symlink("../hello.txt", os.path.join(tree, "dir", "link"))
    os.symlink("T" * 150, os.path.join(tree, "long-link"))
    os.link(os.path.join(tree, "hello.txt"), os.path.join(tree, "again.txt"))
    for root, dirs, files in os.walk(tree):
        for n in dirs + files:
            os.utime(os.path.join(root, n), (T, T), follow_symlinks=False)
    os.utime(tree, (T, T))
    everything = ["hello.txt", "binary.bin", "dir", "emptydir", "long-link", "again.txt"]
    short = ["hello.txt", "binary.bin", "emptydir", "again.txt"]
    for name, fmt, flags, members in (("gnu-gnu.tar", "gnu", [], everything),
                                      ("gnu-posix.tar", "posix", [], everything),
                                      ("gnu-posix.tar.gz", "posix", ["-z"], everything),
                                      ("gnu-ustar.tar", "ustar", [], short),
                                      ("gnu-v7.tar", "v7", [], short)):
        subprocess.run([gnutar, "--format=" + fmt] + flags + ["-C", tree, "-cf", os.path.join(d, name)] + members, check=True)
        expect(name)

with open(os.path.join(d, "index.txt"), "w") as f:
    f.write("\n".join(index) + "\n")
PY
then
  echo "the fixtures could not be written"
  exit 1
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_tar_exercise.iyi" \
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

echo "== the std/tar exercise, plain build"
build_and_run "plain" tar-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/tar-plain.out" 2>/dev/null; then
  echo "plain: ALL CHECKS PASSED missing"
  status=1
fi

echo
echo "== every tar section reported"
for phrase in "== round trips" "== streaming reads" "== headers" "== past 8 GiB" "== gzip" \
              "== refused as a value" "== extract" "== what python wrote" "== written for python"; do
  if ! grep -qF "$phrase" "$WORK/tar-plain.out"; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== what iyi wrote, read by Python's tarfile"
# Each archive the exercise wrote, read by Python: the entries as Python
# lists them, with their data's CRC-32, the lines the exercise said it
# asked for. And the archive with a byte flipped in its first header is
# refused by Python too.
"$PY" - "$WORK/fixtures" "$WORK/oracle.py" <<'PY' || status=1
import os, sys, tarfile
sys.path.insert(0, os.path.dirname(sys.argv[2]))
from oracle import lines_of
d = sys.argv[1]
failed = False
want = open(os.path.join(d, "out-round.expect"), encoding="utf-8").read()
for name in ("out-round.tar", "out-round.tar.gz"):
    got = lines_of(os.path.join(d, name))
    if got != want:
        print("  %s: Python read other entries:" % name)
        for a, b in zip(want.splitlines(), got.splitlines()):
            if a != b:
                print("    asked %r\n    read  %r" % (a, b))
        failed = True
    else:
        print("  %s: %d entries as they were asked for, pax long names, unicode names and all" % (name, want.count("entry\t")))
with tarfile.open(os.path.join(d, "out-round.tar")) as t:
    pax = [m.name for m in t if m.pax_headers]
print("  out-round.tar: %d entries carried pax records" % len(pax))
try:
    with tarfile.open(os.path.join(d, "out-corrupt.tar")) as t:
        t.getmembers()
    print("  out-corrupt.tar: Python read it"); failed = True
except tarfile.ReadError as e:
    print("  out-corrupt.tar: Python refuses it too (%s)" % e)
sys.exit(1 if failed else 0)
PY

if [ -n "$GNUTAR" ]; then
  echo
  echo "== what iyi wrote, read by GNU tar"
  # Listed, then extracted with permissions kept, and every entry on disk
  # what the exercise asked for: a file's bytes and mode, a directory, a
  # link's target, a hard link the same file as its target.
  for name in out-round.tar out-round.tar.gz; do
    dest="$WORK/gnu-x-$name"
    mkdir -p "$dest"
    if ! tar -tvf "$WORK/fixtures/$name" >"$WORK/gnu-t.out" 2>&1; then
      echo "  $name: tar -t refused it"; sed -n '1,6p' "$WORK/gnu-t.out"; status=1; continue
    fi
    if ! tar -xpf "$WORK/fixtures/$name" -C "$dest" >"$WORK/gnu-x.out" 2>&1; then
      echo "  $name: tar -x refused it"; sed -n '1,6p' "$WORK/gnu-x.out"; status=1; continue
    fi
    "$PY" - "$WORK/fixtures/out-round.expect" "$dest" "$name" <<'PY' || status=1
import os, stat, sys, zlib
expect, dest, name = sys.argv[1], sys.argv[2], sys.argv[3]
bad = 0
n = 0
for line in open(expect, encoding="utf-8").read().splitlines():
    _, ename, kind, size, mode, mtime, uid, gid, uname, gname, link, crc = line.split("\t")
    p = os.path.join(dest, ename)
    n += 1
    if kind == "file":
        data = open(p, "rb").read()
        ok = str(zlib.crc32(data)) == crc and stat.S_IMODE(os.stat(p).st_mode) == int(mode, 8)
        if ok and int(mtime) > 0:
            ok = int(os.stat(p).st_mtime) == int(mtime)
    elif kind == "dir":
        ok = os.path.isdir(p) and stat.S_IMODE(os.stat(p).st_mode) == int(mode, 8)
    elif kind == "symlink":
        ok = os.path.islink(p) and os.readlink(p) == link
    else:
        ok = os.path.samefile(p, os.path.join(dest, link))
    if not ok:
        print("  %s: %s %r is not what was asked for" % (name, kind, ename)); bad += 1
if not bad:
    print("  %s: tar -t lists it, tar -xp makes all %d entries as asked" % (name, n))
sys.exit(1 if bad else 0)
PY
  done
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" tar-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/tar-release.out" 2>/dev/null; then
  echo "release: ALL CHECKS PASSED missing"
  tail -3 "$WORK/tar-release.out"
  status=1
else
  echo "  ALL CHECKS PASSED"
fi

echo
echo "== what the module refuses, by name"
# A malformed archive is a TarError value, checked by the exercise; what
# panics is the caller's own mistake, and an error the caller chose to
# panic on (`or_panic`) panics with its sentence exactly.
refuses() { # refuses <label> <name> <phrase> <statements>
  local label="$1" name="$2" phrase="$3" statements="$4"
  printf 'module main\n\nimport std/tar::{TarReader, TarWriter, TarEntry, TarError}\nimport std/io::{Memory}\n\n%s\nputs "ANSWERED"\n' \
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
refuses "an add after finish" add_after "TarWriter: add after finish" \
  'w = TarWriter.new(Memory.new)
w.finish
w.add("a", "b")'
refuses "finish twice" finish_twice "TarWriter: finish was called twice" \
  'w = TarWriter.new(Memory.new)
w.finish
w.finish'
refuses "an empty name" empty_name "TarWriter: an entry needs a name" \
  'TarWriter.new(Memory.new).add("", "x")'
refuses "an absolute name" absolute "TarWriter: \"/etc/passwd\" is absolute; a name in an archive is relative" \
  'TarWriter.new(Memory.new).add("/etc/passwd", "x")'
refuses "a NUL in a name" nul_name 'TarWriter: "a\u0000b" holds a NUL byte, which ends a name in a tar header' \
  'TarWriter.new(Memory.new).add("a\u0000b", "x")'
refuses "a link without a target" no_target "TarWriter: the link \"l\" needs a target" \
  'TarWriter.new(Memory.new).add_symlink("l", "")'
refuses "a mode past 0o7777" big_mode "TarWriter: \"a\" has mode 0o10000; a mode is 0 to 0o7777" \
  'TarWriter.new(Memory.new).add("a", "x", mode: 0o10000)'
refuses "a negative uid" negative_uid "TarWriter: \"a\" has uid -1; an id is not negative" \
  'TarWriter.new(Memory.new).add("a", "x", uid: -1_i64)'
refuses "a negative size" negative_size "TarWriter: \"a\" is to hold -1 bytes; a size is not negative" \
  'TarWriter.new(Memory.new).add("a", Memory.new("x"), -1_i64)'
refuses "a source shorter than its size" short_source "TarWriter: \"a\" is to hold 10 bytes, and its source ended after 3" \
  'TarWriter.new(Memory.new).add("a", Memory.new("abc"), 10_i64)'
refuses "a read of no bytes" read_zero "TarEntry: read wants at least one byte, not 0" \
  'm = Memory.new
w = TarWriter.new(m)
w.add("a", "b")
w.finish
TarReader.new(Memory.new(m.to_s)).next_entry.or_panic.as(TarEntry).read(0)'
refuses "a read after the reader moved on" read_past "TarEntry: \"a\" was read past; its data is read before the next next_entry" \
  'm = Memory.new
w = TarWriter.new(m)
w.add("a", "b")
w.add("c", "d")
w.finish
r = TarReader.new(Memory.new(m.to_s))
a = r.next_entry.or_panic.as(TarEntry)
r.next_entry
a.read'
refuses "not an archive, or_panic" not_tar 'tar: the block at offset 0 is not a tar header: its checksum field holds "xxxxxxxx"' \
  'TarReader.new(Memory.new("x" * 600)).next_entry.or_panic'

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
src = Path("$REPO/src/std/tar.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing: " + os.environ["OLD"])
Path("$WORK/patched/std/tar.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  # Build first, then run: a patch that does not compile would also "fail",
  # and that proves nothing about whether the exercise catches the break.
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mut-$mutations.bin" "$REPO/bench/std_tar_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
  chmod -R u+rwX "$WORK/fixtures" 2>/dev/null
}
prove_broken "a checksum never compared" "a corrupted checksum is refused" \
  'unless stored == unsigned || stored == signed' 'unless true'
prove_broken "a signed checksum not accepted" "a signed checksum is accepted" \
  'unless stored == unsigned || stored == signed' 'unless stored == unsigned'
prove_broken "a ustar prefix ignored" "every entry read back as it was written" \
  'name = prefix + "/" + name unless prefix.empty?' 'name = name + "" unless prefix.empty?'
prove_broken "a pax path ignored" "every entry read back as it was written" \
  'when "path"     then name = v' 'when "pathX"     then name = v'
prove_broken "a GNU long name ignored" "GNU long name and long link name" \
  'long_name = TarBytes.cut_nul(data)' 'long_name = nil'
prove_broken "base-256 not read" "base-256 size 1000" \
  'if p[at] & 0x80_u8 != 0_u8' 'if false'
prove_broken "a negative base-256 number read as positive" "negative base-256 mtime" \
  'inv = p[at] & 0x40_u8 != 0_u8 ? 0xff_u8 : 0_u8' 'inv = 0_u8'
prove_broken "a pax mtime's fraction dropped" "a fractional pax mtime" \
  '        nanos = t[1]' '        nanos = 0'
prove_broken "a negative pax fraction added, not taken" "a negative fractional pax mtime" \
  '{-secs - 1_i64, 1000000000 - nanos}' '{-secs, nanos}'
prove_broken "a global pax header ignored" "a global pax header holds for every entry after it" \
  'TarReader.records(data, at, @global, true)!' 'TarReader.records(data, at, {} of String => String, true)!'
prove_broken "the v7 directory by its slash missed" "a v7 directory" \
  '@name.ends_with?("/") ? TarType::Directory : TarType::Regular' 'TarType::Regular'
prove_broken "a directory's size read as data" "a directory's size carries no data" \
  'when TarType::Hardlink, TarType::Symlink, TarType::CharDevice, TarType::BlockDevice, TarType::Directory, TarType::Fifo' 'when TarType::Hardlink'
prove_broken "the padding after data not read past" "round trip: refused with" \
  '@pad = @left == 0_i64 ? 0_i64 : pad' '@pad = 0_i64'
prove_broken "an entry cut short handed out" "an entry cut short" \
  '    if got.bytesize < n
      fault = TarError.new' '    if false
      fault = TarError.new'
prove_broken "no bound on an extended header" "an extended header past 1 MiB" \
  'if size > TarBytes::MAX_SPECIAL' 'if false'
prove_broken "gzip not recognised" "gzip read: every entry as it was written" \
  'first.to_unsafe[0] == 0x1f_u8' 'first.to_unsafe[0] == 0x1e_u8'
prove_broken "the gzip trailer never read" "a gzip CRC-32 that disagrees is refused at the end" \
  '        drain!
' ''
prove_broken "a size past 8 GiB written into its octal field" "past 8 GiB: a pax size record" \
  'if size > TarBytes::MAX_OCTAL11' 'if size > TarBytes::MAX_OCTAL11 * 4_i64'
prove_broken "a name that splits written with a pax header" "a pax header only where a field does not fit" \
  'parts = TarBytes.ascii?(name) ? split(name) : nil' 'parts = TarBytes.ascii?(name) && name.bytesize <= 100 ? split(name) : nil'
prove_broken "a non-ASCII name written without pax" "dir/çay ğ: a pax header only where a field does not fit (Ustar)" \
  'parts = TarBytes.ascii?(name) ? split(name) : nil' 'parts = split(name)'
prove_broken "a name climbing out with .. extracted" "tar slip ../evil.txt" \
  '    return "the name climbs out with .." if name.split('"'"'/'"'"').includes?("..")
' ''
prove_broken "a link climbing out made" "a symbolic link climbing out" \
  '        return "the target climbs out with .." if ups > depth
' ''
prove_broken "a link going down and back up made" "a link going down and back up" \
  '        return "the target goes down and back up with .., which extract does not follow" if down
' ''
prove_broken "an entry written through a link" "written through a symbolic link" \
  '        if info.symlink?
          return TarError.new("tar: #{name.inspect} would be written through' '        if false
          return TarError.new("tar: #{name.inspect} would be written through'
prove_broken "a hard link to a link made" "a hard link to a symbolic link is refused" \
  'unless tinfo && tinfo.file?' 'unless tinfo'
prove_broken "a device extracted as a file" "a device refused" \
  'unless e.file? || e.directory? || e.symlink? || e.hardlink?' 'if false'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/tar exercise holds ($mutations breaks caught)"
else
  echo "the std/tar exercise did not hold"
fi
exit $status
