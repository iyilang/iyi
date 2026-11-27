#!/usr/bin/env python3
"""Compare checked-cast table contents and call arguments without LLVM's global suffixes."""
import re
import sys
from pathlib import Path

GLOBAL = re.compile(r'(@"[^"\n]+")')
STRING = re.compile(r'^(?P<name>@"[^"\n]+") = private constant .*?c"(?P<value>(?:\\.|[^"\\])*)"', re.M)
TABLE = re.compile(r'^@__crystal_type_id_to_class_name_map = .*$', re.M)
CALL = re.compile(r'^\s*call\s+void(?:\s*\([^\n]*?\))?\s+@__crystal_raise_cast_failed\((.*)\)', re.M)


def extract(path):
    text = Path(path).read_text()
    strings = {m["name"]: m["value"] for m in STRING.finditer(text)}
    table_match = TABLE.search(text)
    calls = CALL.findall(text)
    if not table_match or not calls:
        raise ValueError(f"{path}: missing class-name table or checked-cast call")
    references = GLOBAL.findall(table_match.group())
    expected = re.search(r'\[(\d+) x ptr\]', table_match.group())
    if not expected or len(references) != int(expected.group(1)):
        raise ValueError(f"{path}: table entries are not all named string constants")
    table = [strings[ref] for ref in references]
    call_values = []
    for call in calls:
        refs = GLOBAL.findall(call)
        call_values.append([strings[ref] for ref in refs])
        if len(refs) != 2:
            raise ValueError(f"{path}: expected target and location strings in {call}")
    return table, call_values


try:
    oracle, port = (extract(path) for path in sys.argv[1:])
    if oracle != port:
        for label, a, b in zip(("class-name table", "call strings"), oracle, port):
            if a != b:
                print(f"{label} differs: hosted={a!r} port={b!r}", file=sys.stderr)
        sys.exit(1)
    print(f"checked-cast metadata identical: {len(oracle[0])} table entries, {len(oracle[1])} calls")
except (ValueError, KeyError, OSError) as exc:
    print(exc, file=sys.stderr)
    sys.exit(1)
