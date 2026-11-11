#!/usr/bin/env python3
"""heap22 S4: names for a `-Dheap_verify` report.

The verifier (src/iyi/heap_verify.iyi) reports what the runtime knows:
type ids, field offsets, and sites and data words as offsets from the
image's base. This turns them into the names a reader wants, from the
compiler's type dump (`IYI_DUMP_TYPE_INFO=<json>` set while building) and
the binary's own symbols:

    python3 bench/heap_verify_names.py --types T.json --binary PROGRAM < report

Every `type_id=N` gains the type's name; a holder's `field +O` the
instance variable at that offset; `allocated at: image+0x...` and a data
segment word `image+0x...` the function and line or the symbol there
(nm; a PE's from its `.pdb` publics, by llvm-pdbutil). Sites are read
from the binary's debug information by addr2line (ELF), atos (Mach-O,
from the `.dwarf` companion the build leaves beside the program) or
llvm-symbolizer (PE, from its `.pdb`; ELF without addr2line). Lines it
cannot name are passed through unchanged.
"""

import argparse
import bisect
import json
import os
import re
import shutil
import struct
import subprocess
import sys


def load_types(path):
    by_id = {}
    with open(path) as handle:
        data = json.load(handle)
    for entry in data.get("types", []):
        by_id[entry["id"]] = entry
    return by_id


def image_base(binary):
    """The address image+0 is in the file's own address space: an ELF's
    first PT_LOAD less its file offset, a Mach-O's `__TEXT` vmaddr (where
    `_dyld_get_image_header` points), a PE's ImageBase (`GetModuleHandle`).
    Answers (format, base), or (None, None)."""
    try:
        with open(binary, "rb") as handle:
            head = handle.read(4096)
            if head[:4] == b"\x7fELF" and head[4] == 2:
                phoff = struct.unpack_from("<Q", head, 32)[0]
                phentsize, phnum = struct.unpack_from("<HH", head, 54)
                handle.seek(phoff)
                table = handle.read(phentsize * phnum)
                for index in range(phnum):
                    p_type = struct.unpack_from("<I", table, index * phentsize)[0]
                    if p_type == 1:
                        offset = struct.unpack_from("<Q", table, index * phentsize + 8)[0]
                        vaddr = struct.unpack_from("<Q", table, index * phentsize + 16)[0]
                        return "elf", vaddr - offset
                return None, None
            if head[:4] == b"\xcf\xfa\xed\xfe":
                ncmds, sizeofcmds = struct.unpack_from("<II", head, 16)
                commands = head[32:] + handle.read(max(0, 32 + sizeofcmds - len(head)))
                at = 0
                for _ in range(ncmds):
                    cmd, cmdsize = struct.unpack_from("<II", commands, at)
                    # LC_SEGMENT_64
                    if cmd == 0x19 and commands[at + 8:at + 24].rstrip(b"\0") == b"__TEXT":
                        return "macho", struct.unpack_from("<Q", commands, at + 24)[0]
                    at += cmdsize
                return None, None
            if head[:2] == b"MZ":
                pe = struct.unpack_from("<I", head, 0x3C)[0]
                if head[pe:pe + 4] != b"PE\0\0":
                    return None, None
                optional = pe + 24
                magic = struct.unpack_from("<H", head, optional)[0]
                if magic == 0x20B:
                    return "pe", struct.unpack_from("<Q", head, optional + 24)[0]
                if magic == 0x10B:
                    return "pe", struct.unpack_from("<I", head, optional + 28)[0]
    except (OSError, struct.error):
        return None, None
    return None, None


# A PE's symbol names keep the compiler's escapes, `.2A.` for `*`.
ESCAPE_RE = re.compile(r"\.([0-9A-F]{2})\.")
# atos: `fn (in program.dwarf) (file:line)`, or `fn (in program) + 12`.
ATOS_RE = re.compile(r"^(.*?) \(in [^)]*\)(?: \((.*)\)| \+ \d+)?$")
# llvm-pdbutil: a section header's `<hex> virtual address`, a public's
# name line and its `flags = ..., addr = <section>:<offset>` line.
PDB_SECTION_RE = re.compile(r"^\s*([0-9A-Fa-f]+) virtual address$", re.M)
PDB_NAME_RE = re.compile(r"S_PUB32 \[size = \d+\] `(.*)`$")
PDB_ADDR_RE = re.compile(r"flags = (.*), addr = (\d+):(\d+)$")


class Symbols:
    def __init__(self, binary):
        # Windows: the build writes `program.exe` for `-o program`.
        if binary and not os.path.exists(binary) and os.path.exists(binary + ".exe"):
            binary = binary + ".exe"
        self.binary = binary
        self.format, self.base = image_base(binary) if binary else (None, None)
        self.names = []
        self.addresses = []
        if binary and shutil.which("nm"):
            try:
                out = subprocess.run(["nm", "-C", "-n", binary], capture_output=True, text=True, check=False).stdout
            except OSError:
                out = ""
            for line in out.splitlines():
                parts = line.split(None, 2)
                if len(parts) == 3 and parts[1] in "bBdDrRsS":
                    try:
                        self.addresses.append(int(parts[0], 16))
                        self.names.append(parts[2])
                    except ValueError:
                        pass
        if self.format == "pe" and not self.addresses:
            self.pdb_publics()

    def pdb_publics(self):
        """A PE keeps no symbol table nm reads; its data symbols are the
        `.pdb`'s publics, each a section and an offset (llvm-pdbutil)."""
        pdb = os.path.splitext(self.binary)[0] + ".pdb"
        if not os.path.exists(pdb) or not shutil.which("llvm-pdbutil"):
            return
        try:
            heads = subprocess.run(["llvm-pdbutil", "dump", "--section-headers", pdb],
                                   capture_output=True, text=True, check=False).stdout
            publics = subprocess.run(["llvm-pdbutil", "dump", "--publics", pdb],
                                     capture_output=True, text=True, check=False).stdout
        except OSError:
            return
        starts = [int(m.group(1), 16) for m in PDB_SECTION_RE.finditer(heads)]
        found = []
        name = None
        for line in publics.splitlines():
            match = PDB_NAME_RE.search(line)
            if match:
                name = match.group(1)
                continue
            match = PDB_ADDR_RE.search(line)
            if match and name is not None:
                section, offset = int(match.group(2)), int(match.group(3))
                if "function" not in match.group(1) and 1 <= section <= len(starts):
                    found.append((self.base + starts[section - 1] + offset,
                                  ESCAPE_RE.sub(lambda m: chr(int(m.group(1), 16)), name)))
                name = None
        found.sort()
        self.addresses = [address for address, _ in found]
        self.names = [text for _, text in found]

    def vaddr(self, image_offset):
        if self.base is None:
            return None
        return self.base + image_offset

    def code(self, image_offset):
        address = self.vaddr(image_offset)
        if address is None:
            return None
        # The site is a return address: the call is the instruction before.
        address -= 1
        if self.format == "macho":
            return self.atos(address)
        if self.format == "elf" and shutil.which("addr2line"):
            command = ["addr2line", "-f", "-C", "-i", "-e", self.binary, hex(address)]
        elif shutil.which("llvm-symbolizer"):
            command = ["llvm-symbolizer", "--output-style=GNU", "-f", "-C", "-i", "--obj=" + self.binary, hex(address)]
        else:
            return None
        try:
            out = subprocess.run(command, capture_output=True, text=True, check=False).stdout.split("\n")
        except OSError:
            return None
        pairs = [(ESCAPE_RE.sub(lambda m: chr(int(m.group(1), 16)), out[i]), out[i + 1])
                 for i in range(0, len(out) - 1, 2) if out[i] and out[i] != "??"]
        if not pairs:
            return None
        return " <- ".join(f"{fn} ({where})" for fn, where in pairs[:4])

    def atos(self, address):
        if not shutil.which("atos"):
            return None
        dwarf = self.binary + ".dwarf"
        image = dwarf if os.path.exists(dwarf) else self.binary
        try:
            out = subprocess.run(["atos", "-o", image, "-l", hex(self.base), hex(address)],
                                 capture_output=True, text=True, check=False).stdout.strip()
        except OSError:
            return None
        match = ATOS_RE.match(out)
        if not match:
            return None
        return f"{match.group(1)} ({match.group(2)})" if match.group(2) else match.group(1)

    def data(self, image_offset):
        address = self.vaddr(image_offset)
        if address is None or not self.addresses:
            return None
        index = bisect.bisect_right(self.addresses, address) - 1
        if index < 0:
            return None
        return f"{self.names[index]}+{address - self.addresses[index]}"


TYPE_RE = re.compile(r"type_id=(\d+)")
FIELD_RE = re.compile(r"^(\s*field \+)(\d+)(.*)$")
SITE_RE = re.compile(r"(?:allocated at: |returns to )image\+0x([0-9a-f]+)")
WORD_RE = re.compile(r"\(image\+0x([0-9a-f]+)\)|word at image\+0x([0-9a-f]+)")


def field_name(entry, offset):
    best = None
    for ivar in entry.get("instance_vars", []):
        start = ivar.get("offset", 0)
        size = ivar.get("size", 8)
        if start <= offset < start + max(size, 1):
            best = ivar
            break
    if best is None:
        return None
    inner = offset - best.get("offset", 0)
    text = f"{best['name']} : {best.get('type_name', '?')}"
    return text if inner == 0 else f"{text} (+{inner})"


# A C1 crossing context's type id: IYI_C1_FIRST_ID plus the order the
# build made it in (the compiler's gc_closure_layout). The dump has no
# entry for it; its slots are named by offset.
C1_FIRST_ID = 0x40000000


def c1_context(type_id):
    if type_id < C1_FIRST_ID:
        return None
    return {"name": f"C1 context #{type_id - C1_FIRST_ID}", "instance_vars": [], "c1": True}


def annotate(lines, types, symbols, out):
    last_entry = None
    for raw in lines:
        line = raw.rstrip("\n")
        match = TYPE_RE.search(line)
        if match and ("holder" in line or "held by" in line or "chunk" in line):
            entry = types.get(int(match.group(1))) or c1_context(int(match.group(1)))
            if entry is not None:
                line = line.replace(match.group(0), f"{match.group(0)} {entry['name']}")
            last_entry = entry if ("holder" in line or "held by" in line) else last_entry
        elif "untyped memory" in line and ("holder" in line or "held by" in line):
            last_entry = None
        match = FIELD_RE.match(line)
        if match and last_entry is not None:
            if last_entry.get("c1"):
                name = f"+{match.group(2)}"
            else:
                name = field_name(last_entry, int(match.group(2)))
            if name:
                line = f"{line}  [{last_entry['name']}#{name}]"
        match = SITE_RE.search(line)
        if match:
            where = symbols.code(int(match.group(1), 16))
            if where:
                line = f"{line}  [{where}]"
        if "word at" in line:
            for found in WORD_RE.finditer(line):
                offset = found.group(1) or found.group(2)
                name = symbols.data(int(offset, 16))
                if name:
                    line = f"{line}  [{name}]"
                    break
        out.write(line + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--types", required=True, help="the IYI_DUMP_TYPE_INFO json of the build")
    parser.add_argument("--binary", help="the program, for sites and data symbols")
    parser.add_argument("report", nargs="?", help="the report (stdin when absent)")
    args = parser.parse_args()
    types = load_types(args.types)
    symbols = Symbols(args.binary)
    if args.report:
        with open(args.report, errors="replace") as handle:
            annotate(handle, types, symbols, sys.stdout)
    else:
        annotate(sys.stdin, types, symbols, sys.stdout)


if __name__ == "__main__":
    main()
