#!/usr/bin/env python3
"""Checks the width the Mach-O reader gave each PAGEOFF12 relocation against the instruction the hosted compiler wrote.

Usage: check_pageoff.py [--require KIND]... OBJECT DRIVER_OUTPUT [OBJECT DRIVER_OUTPUT]...

An ARM64_RELOC_PAGEOFF12 record does not say what it patches. A linker adds the offset to an ADD as it is, and scales it
by the width of the access for a load or store, which only the size field of the instruction says. The native reader
reads that field into a relocation kind (A64AddLo12, A64Ldst8Lo12 ... A64Ldst128Lo12), and the writer, the round trip and
the relinked program all work the same whichever width the kind names: a reader that took one width for another still
round-trips and relinks. So the kind is compared here with the hosted compiler's own object, decoded from the Arm
Architecture Reference Manual's encodings and not from the reader's code:

  ADD (immediate)                          bits 28:23 are 100010
  LDR/STR (immediate, unsigned offset)     bits 29:27 are 111 and bits 25:24 are 01; the access is 8 << size bits wide,
                                           size being bits 31:30, except that size 00 with V (bit 26) set and opc (bits
                                           23:22) 11 is a 128-bit SIMD register

OBJECT is the hosted compiler's Mach-O arm64 object. DRIVER_OUTPUT is what bench's obj_macho driver printed for it: one
"site SECTION OFFSET KIND" line for each PAGEOFF12 record, SECTION counting the object's sections from 0.

--require KIND fails the check, with status 2, when no record of that kind was found in any object, so a width the corpus
does not exercise cannot pass vacuously. Status 1 is a difference between the driver and the instruction: the first one
is printed as "decisive: ...". Status 2 is a check that could not compare anything.
"""
import struct
import sys

PAGEOFF12 = 4
WIDTH_KINDS = ("A64Ldst8Lo12", "A64Ldst16Lo12", "A64Ldst32Lo12", "A64Ldst64Lo12")
ALL_KINDS = ("A64AddLo12",) + WIDTH_KINDS + ("A64Ldst128Lo12",)
INSTRUCTION = {
    "A64AddLo12": "an ADD (immediate)",
    "A64Ldst8Lo12": "a byte load or store",
    "A64Ldst16Lo12": "a halfword load or store",
    "A64Ldst32Lo12": "a word load or store",
    "A64Ldst64Lo12": "a doubleword load or store",
    "A64Ldst128Lo12": "a 128-bit SIMD load or store",
}


def decode(word):
    """The kind an instruction word calls for, or None when it is neither an ADD nor a load or store."""
    if (word >> 23) & 0x3F == 0x22:
        return "A64AddLo12"
    if (word >> 27) & 7 == 7 and (word >> 24) & 3 == 1:
        size = (word >> 30) & 3
        vector = (word >> 26) & 1
        opc = (word >> 22) & 3
        if vector == 1 and size == 0 and opc == 3:
            return "A64Ldst128Lo12"
        return WIDTH_KINDS[size]
    return None


def object_sites(path):
    """{(section, offset): (kind, instruction word)} for every PAGEOFF12 record of a Mach-O 64-bit object."""
    with open(path, "rb") as handle:
        data = handle.read()
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        raise ValueError(f"{path} is not a 64-bit Mach-O object")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    sections = []
    at = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, at)
        if cmd == 0x19:
            nsects = struct.unpack_from("<I", data, at + 64)[0]
            for k in range(nsects):
                header = at + 72 + 80 * k
                offset, _align, reloff, nreloc = struct.unpack_from("<IIII", data, header + 48)
                sections.append((offset, reloff, nreloc))
        at += size
    sites = {}
    for index, (offset, reloff, nreloc) in enumerate(sections):
        for r in range(nreloc):
            address, info = struct.unpack_from("<iI", data, reloff + 8 * r)
            if (info >> 28) & 15 != PAGEOFF12:
                continue
            word = struct.unpack_from("<I", data, offset + address)[0]
            kind = decode(word)
            if kind is None:
                raise ValueError(f"{path}: section {index} offset {address}: a PAGEOFF12 record patches {word:#010x}, "
                                 "which is neither an ADD nor a load or store")
            sites[(index, address)] = (kind, word)
    return sites


def driver_sites(path):
    """{(section, offset): kind} for the site lines the driver printed."""
    sites = {}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) == 4 and parts[0] == "site":
                sites[(int(parts[1]), int(parts[2]))] = parts[3]
    return sites


def main(argv):
    required = []
    args = argv[1:]
    while len(args) >= 2 and args[0] == "--require":
        required.append(args[1])
        args = args[2:]
    if not args or len(args) % 2 != 0:
        print("usage: check_pageoff.py [--require KIND]... OBJECT DRIVER_OUTPUT [OBJECT DRIVER_OUTPUT]...")
        return 2
    counts = dict.fromkeys(ALL_KINDS, 0)
    failures = []
    objects = 0
    for obj, output in zip(args[0::2], args[1::2]):
        try:
            expected = object_sites(obj)
            actual = driver_sites(output)
        except (OSError, ValueError, struct.error) as error:
            print(f"cannot compare {obj}: {error}")
            return 2
        objects += 1
        for key in sorted(set(expected) | set(actual)):
            section, offset = key
            want = expected.get(key)
            got = actual.get(key)
            if want is not None:
                counts[want[0]] += 1
            if want is None:
                failures.append(f"{obj}: section {section} offset {offset}: the driver printed a {got} site "
                                "where the object has no PAGEOFF12 record")
            elif got is None:
                failures.append(f"{obj}: section {section} offset {offset}: the object has a PAGEOFF12 record at "
                                f"{want[1]:#010x}, {INSTRUCTION[want[0]]}, and the driver printed no site there")
            elif got != want[0]:
                failures.append(f"{obj}: section {section} offset {offset}: the driver read {got}, and the "
                                f"instruction {want[1]:#010x} is {INSTRUCTION[want[0]]} ({want[0]})")
    total = sum(counts.values())
    summary = ", ".join(f"{kind} {counts[kind]}" for kind in ALL_KINDS)
    if failures:
        print(f"decisive: {failures[0]}")
        for message in failures[:20]:
            print(f"FAIL {message}")
        if len(failures) > 20:
            print(f"FAIL ... and {len(failures) - 20} more")
        print(f"PAGEOFF12 records in {objects} objects: {total} ({summary}); {len(failures)} differ")
        return 1
    missing = [kind for kind in required if counts.get(kind, 0) == 0]
    if missing:
        print(f"no PAGEOFF12 record of kind {', '.join(missing)} in {objects} objects ({summary}); "
              "the check would prove nothing about it")
        return 2
    print(f"PAGEOFF12 records in {objects} objects: {total}, each read as the width its instruction encodes ({summary})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
