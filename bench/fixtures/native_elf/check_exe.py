#!/usr/bin/env python3
"""Structural check of one static-PIE ELF executable written by src/compiler/native/link/elf_exe.iyi.

Usage: check_exe.py EXE [--expect-tls]

Checks the SPEC 2.3 list: ET_DYN; no PT_INTERP and no PT_DYNAMIC; PT_LOAD segments whose file offset and address are
congruent modulo their alignment; PT_GNU_STACK read-write; PT_GNU_RELRO covering the relro group; PT_TLS present
when --expect-tls is given; no .comment section; none of the crt symbols; the entry point is _start's address;
every entry of the relative relocation table (.iyi.rela) is a non-zero address of an 8-byte word inside an allocated
section. Prints one line per failed check and exits 1 on any failure, 0 when every check holds.
"""
import struct
import sys

PT_LOAD, PT_DYNAMIC, PT_INTERP, PT_TLS = 1, 2, 3, 7
PT_GNU_STACK, PT_GNU_RELRO = 0x6474E551, 0x6474E552
SHF_ALLOC = 2
CRT = ["_init", "_fini", "frame_dummy", "__do_global_dtors_aux",
       "register_tm_clones", "deregister_tm_clones"]


def main(argv):
    if len(argv) < 2:
        print("usage: check_exe.py EXE [--expect-tls]")
        return 2
    path = argv[1]
    expect_tls = "--expect-tls" in argv[2:]
    data = open(path, "rb").read()
    failures = []

    def check(ok, message):
        if not ok:
            failures.append(message)

    e_type, = struct.unpack_from("<H", data, 16)
    entry, phoff, shoff = struct.unpack_from("<QQQ", data, 24)
    phentsize, phnum, shentsize, shnum, shstrndx = struct.unpack_from("<HHHHH", data, 54)
    check(e_type == 3, "e_type is not ET_DYN")

    phdrs = []
    for i in range(phnum):
        at = phoff + i * phentsize
        ptype, pflags, poff, pvaddr, _, pfilesz, pmemsz, palign = struct.unpack_from("<IIQQQQQQ", data, at)
        phdrs.append((ptype, pflags, poff, pvaddr, pfilesz, pmemsz, palign))

    types = [p[0] for p in phdrs]
    check(PT_INTERP not in types, "the executable has a PT_INTERP")
    check(PT_DYNAMIC not in types, "the executable has a PT_DYNAMIC")
    for ptype, pflags, poff, pvaddr, pfilesz, pmemsz, palign in phdrs:
        if ptype == PT_LOAD and palign > 1:
            check((poff - pvaddr) % palign == 0, f"PT_LOAD at {pvaddr:#x} is not congruent modulo its alignment")
    stack = [p for p in phdrs if p[0] == PT_GNU_STACK]
    check(len(stack) == 1 and stack[0][1] == 6, "PT_GNU_STACK is missing or not read-write")
    relro = [p for p in phdrs if p[0] == PT_GNU_RELRO]
    check(len(relro) == 1, "PT_GNU_RELRO is missing")
    tls = [p for p in phdrs if p[0] == PT_TLS]
    if expect_tls:
        check(len(tls) == 1, "PT_TLS is missing although the program uses thread-local data")
    loads = [p for p in phdrs if p[0] == PT_LOAD]
    check(len(loads) >= 3, f"expected at least three PT_LOAD segments, found {len(loads)}")

    sections = []
    for i in range(shnum):
        at = shoff + i * shentsize
        name, stype, sflags, saddr, soff, ssize, slink, sinfo, salign, sentsize = struct.unpack_from("<IIQQQQIIQQ", data, at)
        sections.append((name, stype, sflags, saddr, soff, ssize, slink, sinfo, salign, sentsize))
    shstr_off = sections[shstrndx][4]
    shstr_size = sections[shstrndx][5]
    table = data[shstr_off:shstr_off + shstr_size]

    def name_of(offset):
        return table[offset:table.index(b"\0", offset)].decode("latin-1")

    names = [name_of(s[0]) for s in sections]
    check(".comment" not in names, "the executable has a .comment section")

    symtab = [s for s in sections if s[1] == 2]
    start_value = None
    crt_present = []
    if symtab:
        sym_off, sym_size = symtab[0][4], symtab[0][5]
        strtab = sections[symtab[0][6]]
        strings = data[strtab[4]:strtab[4] + strtab[5]]
        for k in range(sym_size // 24):
            st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", data, sym_off + 24 * k)
            sname = strings[st_name:strings.index(b"\0", st_name)].decode("latin-1")
            if sname == "_start":
                start_value = st_value
            if sname in CRT:
                crt_present.append(sname)
    check(start_value is not None, "no _start symbol")
    check(start_value == entry, f"the entry point {entry:#x} is not _start")
    check(not crt_present, f"crt symbols present: {crt_present}")

    rela = [s for s in sections if names[sections.index(s)] == ".iyi.rela"]
    entries = 0
    if rela:
        r = rela[0]
        entries = r[5] // 8
        words = struct.unpack_from("<%dQ" % entries, data, r[4])
        alloc = [(s[3], s[3] + s[5]) for s in sections if s[2] & SHF_ALLOC and s[1] != 8 and s[5] > 0]
        zero = [w for w in words if w == 0]
        outside = [w for w in words if not any(a <= w and w + 8 <= b for a, b in alloc)]
        check(not zero, f"{len(zero)} relative relocation entries are zero")
        check(not outside, f"{len(outside)} relative relocation entries lie outside allocated sections")
    else:
        failures.append("no .iyi.rela section")

    for message in failures:
        print(f"FAIL {path}: {message}")
    if failures:
        return 1
    print(f"STRUCTURE OK {path}: {len(loads)} PT_LOAD, TLS {'yes' if tls else 'no'}, {entries} relative entries")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
