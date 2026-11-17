#!/usr/bin/env python3
"""Compare emitted collector rows with the existing hosted type oracle."""
import re
import sys
from pathlib import Path


def blocks(text):
    result = {}
    for part in text.split("== ")[1:]:
        name, _, body = part.partition("\n")
        result[name.strip()] = body
    return result


def check(ir, ids_text, rows_text):
    match = re.search(r'@"__iyi_gc_layouts:table" = internal constant \[(\d+) x i64\] \[(.*?)\]', ir)
    if not match:
        raise ValueError("missing internal GC layout table")
    words = [int(word) for word in re.findall(r'i64\s+(-?\d+)', match.group(2))]
    if len(words) != int(match.group(1)) or not words:
        raise ValueError("table length differs from its type")
    count = words[0]
    if count < 0 or len(words) < 1 + 5 * count:
        raise ValueError("entry count exceeds table")
    entries = {}
    offsets = words[1 + 5 * count:]
    next_offset = 0
    last_id = 0
    for i in range(count):
        ident, size, cap, n, start = words[1 + 5 * i:6 + 5 * i]
        if ident <= last_id or n < 0 or start != next_offset or start + n > len(offsets):
            raise ValueError("unsorted type ids or noncontiguous offsets")
        scan = offsets[start:start + n]
        if scan != sorted(set(scan)) or any(offset < 0 or offset + 8 > cap for offset in scan):
            raise ValueError("invalid pointer offsets")
        entries[ident] = (size, cap, scan)
        last_id = ident
        next_offset += n
    if next_offset != len(offsets):
        raise ValueError("unreferenced offset words")
    ids = blocks(ids_text)
    rows = blocks(rows_text)
    for name in ("Leaf", "Base", "Container", "ScalarOnly"):
        id_match = re.search(r'^type_id: (\d+)$', ids[name], re.M)
        row_match = re.search(r'^layout: alloc=(\d+) cap=(\d+) scan=(.*)$', rows[name], re.M)
        if not id_match or not row_match:
            raise ValueError(f"hosted oracle has no id or gc_type_layout for {name}")
        scan_text = row_match.group(3)
        scan = [] if scan_text == "-" else [int(part) for part in scan_text.split()]
        expected = (int(row_match.group(1)), int(row_match.group(2)), scan)
        if entries.get(int(id_match.group(1))) != expected:
            raise ValueError(f"{name} differs from hosted gc_type_layout: {expected}")
    # The existing hosted oracle does not expose gc_type_layout for generic
    # instances. This fixture's Box(Leaf) is one inline reference field.
    box_id = re.search(r'^type_id: (\d+)$', ids["Box(Leaf)"], re.M)
    if not box_id or entries.get(int(box_id.group(1))) != (8, 8, [0]):
        raise ValueError("Box(Leaf) does not describe its one reference field")
    if not re.search(r'@__iyi_gc_layouts = .*global ptr @"__iyi_gc_layouts:table"', ir):
        raise ValueError("GC layout symbol does not point to the table")
    if not re.search(r'@__iyi_marking = .*global i8 0', ir):
        raise ValueError("marking flag is not defined as zero")
    print(f"GC TABLE OK: {count} sorted entries, {len(offsets)} offsets; four hosted rows and generic Box")


if __name__ == "__main__":
    try:
        check(*(Path(path).read_text() for path in sys.argv[1:4]))
    except (ValueError, KeyError, IndexError) as error:
        print(f"GC TABLE FAIL: {error}", file=sys.stderr)
        sys.exit(1)
