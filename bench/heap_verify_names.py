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
segment word `image+0x...` the function and line (addr2line) or the
symbol (nm) there. Lines it cannot name are passed through unchanged.
"""

import argparse
import bisect
import json
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


def first_load_vaddr(binary):
    """The first PT_LOAD's p_vaddr of an ELF file: what image+0 is."""
    try:
        with open(binary, "rb") as handle:
            head = handle.read(64)
            if head[:4] != b"\x7fELF" or head[4] != 2:
                return None
            phoff = struct.unpack_from("<Q", head, 32)[0]
            phentsize, phnum = struct.unpack_from("<HH", head, 54)
            handle.seek(phoff)
            table = handle.read(phentsize * phnum)
        for index in range(phnum):
            p_type = struct.unpack_from("<I", table, index * phentsize)[0]
            if p_type == 1:
                offset = struct.unpack_from("<Q", table, index * phentsize + 8)[0]
                vaddr = struct.unpack_from("<Q", table, index * phentsize + 16)[0]
                return vaddr - offset
    except OSError:
        return None
    return None


class Symbols:
    def __init__(self, binary):
        self.binary = binary
        self.base = first_load_vaddr(binary) if binary else None
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

    def vaddr(self, image_offset):
        if self.base is None:
            return None
        return self.base + image_offset

    def code(self, image_offset):
        address = self.vaddr(image_offset)
        if address is None or not shutil.which("addr2line"):
            return None
        # The site is a return address: the call is the instruction before.
        try:
            out = subprocess.run(["addr2line", "-f", "-C", "-i", "-e", self.binary, hex(address - 1)],
                                 capture_output=True, text=True, check=False).stdout.split("\n")
        except OSError:
            return None
        pairs = [(out[i], out[i + 1]) for i in range(0, len(out) - 1, 2) if out[i]]
        if not pairs:
            return None
        return " <- ".join(f"{fn} ({where})" for fn, where in pairs[:4])

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


def annotate(lines, types, symbols, out):
    last_entry = None
    for raw in lines:
        line = raw.rstrip("\n")
        match = TYPE_RE.search(line)
        if match and ("holder" in line or "held by" in line or "chunk" in line):
            entry = types.get(int(match.group(1)))
            if entry is not None:
                line = line.replace(match.group(0), f"{match.group(0)} {entry['name']}")
            last_entry = entry if ("holder" in line or "held by" in line) else last_entry
        elif "untyped memory" in line and ("holder" in line or "held by" in line):
            last_entry = None
        match = FIELD_RE.match(line)
        if match and last_entry is not None:
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
