#!/usr/bin/env python3
"""Writes the Unicode tables of `src/std/unicode.iyi`.

    python3 scripts/generate_unicode_std.py

The source is `src/unicode/data.cr`, the table of the Unicode Character
Database that `scripts/generate_unicode_data.cr` downloads and writes for the
compatibility library, and `src/unicode/unicode.cr`, which names the UCD
version it was written from. Nothing is fetched: the repository already
carries the data, and both libraries answering from one table is what lets
`bench/std_unicode_exercise.sh` diff them.

What is written, between the `# tables-begin` and `# tables-end` lines of the
module, is one string constant per table: decimal integers separated by
commas, decoded once into an `Array(Int32)` the first time the table is
asked for. A string is one static blob in the binary and costs the compiler
nothing; an array literal of thirty thousand integers is thirty thousand
stores for LLVM to chew on and made every program that imports the module
several seconds slower to build.

Every table is sorted by its first column, which is what the module's binary
searches rely on.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DATA = REPO / "src" / "unicode" / "data.cr"
UNICODE = REPO / "src" / "unicode" / "unicode.cr"
MODULE = REPO / "src" / "std" / "unicode.iyi"

BEGIN = "  # tables-begin"
END = "  # tables-end"
WIDTH = 96


def read_tables(text: str) -> dict[str, list[tuple[int, ...]]]:
    """Every `class_getter NAME … do … end` block as a list of `put` rows."""
    tables: dict[str, list[tuple[int, ...]]] = {}
    current: str | None = None
    for line in text.splitlines():
        head = re.match(r"\s*private class_getter (\w+) :", line)
        if head:
            current = head.group(1)
            tables[current] = []
            continue
        if current is None:
            continue
        if re.match(r"\s*end\s*$", line):
            current = None
            continue
        row = re.match(r"\s*put\(data, (.*)\)\s*$", line)
        if not row:
            continue
        values = []
        for item in row.group(1).split(","):
            item = item.strip()
            item = re.sub(r"_(i64|u8|i32)$", "", item)
            if item.startswith("QuickCheckResult::"):
                item = "1" if item.endswith("No") else "2"
            values.append(int(item))
        tables[current].append(tuple(values))
    return tables


def version(text: str) -> str:
    found = re.search(r'VERSION = "([^"]+)"', text)
    if not found:
        sys.exit("no VERSION in " + str(UNICODE))
    return found.group(1)


def expand(strided: list[tuple[int, ...]]) -> set[int]:
    """The code points a `{from, to, stride}` table names."""
    points: set[int] = set()
    for start, stop, stride in strided:
        points.update(range(start, stop + 1, stride))
    return points


def runs(points: set[int]) -> list[tuple[int, int, int]]:
    """`{from, to, stride}` rows covering *points*, greedy and longest-first.

    A run of one point has stride 1; two points at any distance form a run
    of that stride, extended while the distance repeats.
    """
    ordered = sorted(points)
    rows: list[tuple[int, int, int]] = []
    index = 0
    while index < len(ordered):
        start = ordered[index]
        if index + 1 == len(ordered):
            rows.append((start, start, 1))
            break
        stride = ordered[index + 1] - start
        stop = ordered[index + 1]
        index += 2
        while index < len(ordered) and ordered[index] - stop == stride:
            stop = ordered[index]
            index += 1
        rows.append((start, stop, stride))
    return rows


def flat(rows: list[tuple[int, ...]]) -> list[int]:
    return [value for row in rows for value in row]


def literal(name: str, comment: str, values: list[int]) -> str:
    text = ",".join(str(value) for value in values)
    lines = []
    while text:
        if len(text) <= WIDTH:
            lines.append(text)
            break
        cut = text.rfind(",", 0, WIDTH) + 1
        lines.append(text[:cut])
        text = text[cut:]
    out = [f"  # {comment}"]
    prefix = f"  {name} = "
    pad = " " * len(prefix)
    if len(lines) == 1:
        out.append(f'{prefix}"{lines[0]}"')
    else:
        out.append(f'{prefix}"{lines[0]}" \\')
        for line in lines[1:-1]:
            out.append(f'{pad}"{line}" \\')
        out.append(f'{pad}"{lines[-1]}"')
    return "\n".join(out)


def main() -> None:
    tables = read_tables(DATA.read_text())
    ucd = version(UNICODE.read_text())

    def strided(*names: str) -> list[tuple[int, int, int]]:
        points: set[int] = set()
        for name in names:
            points |= expand(tables[name])
        return runs(points)

    def keyed(name: str, width: int) -> list[tuple[int, ...]]:
        rows = sorted(tables[name])
        for row in rows:
            if len(row) != width:
                sys.exit(f"{name}: expected {width} columns, found {row}")
        return rows

    letter = strided("category_Lu", "category_Ll", "category_Lt", "category_Lm", "category_Lo")
    number = strided("category_Nd", "category_Nl", "category_No")
    mark = strided("category_Mn", "category_Mc", "category_Me")
    whitespace = strided("category_Zs", "category_Zl", "category_Zp")
    control = strided("category_Cc", "category_Cf", "category_Cs", "category_Co", "category_Cn")
    lowercase = strided("category_Ll")
    uppercase = strided("category_Lu")
    titlecase = strided("category_Lt")

    upcase = keyed("upcase_ranges", 3)
    downcase = keyed("downcase_ranges", 3)
    alternate = keyed("alternate_ranges", 2)
    casefold = keyed("casefold_ranges", 3)
    special_upcase = keyed("special_cases_upcase", 4)
    special_downcase = keyed("special_cases_downcase", 4)
    special_titlecase = keyed("special_cases_titlecase", 4)
    special_fold = keyed("fold_cases", 4)
    ccc = keyed("canonical_combining_classes", 3)
    canonical = keyed("canonical_decompositions", 3)
    compat_data = [row[0] for row in tables["compatibility_decomposition_data"]]
    compat = keyed("compatibility_decompositions", 3)
    compositions = sorted(
        (key >> 21, key & 0x1FFFFF, result)
        for key, result in tables["canonical_compositions"]
    )

    sections = [
        f'  # The version of the Unicode Character Database the tables below were written from.\n  VERSION = "{ucd}"',
        literal("LETTER", f"{len(letter)} rows of {{from, to, stride}}: the code points of general category L (Lu, Ll, Lt, Lm, Lo).", flat(letter)),
        literal("NUMBER", f"{len(number)} rows of {{from, to, stride}}: general category N (Nd, Nl, No).", flat(number)),
        literal("MARK", f"{len(mark)} rows of {{from, to, stride}}: general category M (Mn, Mc, Me).", flat(mark)),
        literal("WHITESPACE", f"{len(whitespace)} rows of {{from, to, stride}}: general category Z (Zs, Zl, Zp).", flat(whitespace)),
        literal("CONTROL", f"{len(control)} rows of {{from, to, stride}}: general category C (Cc, Cf, Cs, Co).", flat(control)),
        literal("LOWERCASE", f"{len(lowercase)} rows of {{from, to, stride}}: general category Ll.", flat(lowercase)),
        literal("UPPERCASE", f"{len(uppercase)} rows of {{from, to, stride}}: general category Lu.", flat(uppercase)),
        literal("TITLECASE", f"{len(titlecase)} rows of {{from, to, stride}}: general category Lt.", flat(titlecase)),
        literal("UPCASE", f"{len(upcase)} rows of {{from, to, delta}}: the simple uppercase mapping of every code point in the range is itself plus delta.", flat(upcase)),
        literal("DOWNCASE", f"{len(downcase)} rows of {{from, to, delta}}: the simple lowercase mapping is itself plus delta.", flat(downcase)),
        literal("ALTERNATE", f"{len(alternate)} rows of {{from, to}}: ranges where the even code points are uppercase and the odd ones their lowercase.", flat(alternate)),
        literal("CASEFOLD", f"{len(casefold)} rows of {{from, to, delta}}: the single-code-point case folding is itself plus delta.", flat(casefold)),
        literal("SPECIAL_UPCASE", f"{len(special_upcase)} rows of {{code point, first, second, third}}: full uppercase mappings of more than one code point (0 ends a shorter one).", flat(special_upcase)),
        literal("SPECIAL_DOWNCASE", f"{len(special_downcase)} rows of {{code point, first, second, third}}: full lowercase mappings of more than one code point.", flat(special_downcase)),
        literal("SPECIAL_TITLECASE", f"{len(special_titlecase)} rows of {{code point, first, second, third}}: full titlecase mappings that differ from the uppercase mapping.", flat(special_titlecase)),
        literal("SPECIAL_FOLD", f"{len(special_fold)} rows of {{code point, first, second, third}}: full case foldings of more than one code point.", flat(special_fold)),
        literal("COMBINING_CLASS", f"{len(ccc)} rows of {{from, to, class}}: the non-zero canonical combining classes.", flat(ccc)),
        literal("CANONICAL_DECOMPOSITION", f"{len(canonical)} rows of {{code point, first, second}}: canonical decomposition mappings, Hangul syllables excluded (0 ends a singleton).", flat(canonical)),
        literal("COMPATIBILITY_DECOMPOSITION", f"{len(compat)} rows of {{code point, offset, count}}: compatibility decomposition mappings as windows of COMPATIBILITY_DATA.", flat(compat)),
        literal("COMPATIBILITY_DATA", f"{len(compat_data)} code points: the windows COMPATIBILITY_DECOMPOSITION names.", compat_data),
        literal("COMPOSITION", f"{len(compositions)} rows of {{first, second, composed}}: canonical compositions, the exclusions already left out, sorted by first then second.", flat(compositions)),
    ]

    module = MODULE.read_text()
    begin = module.index(BEGIN)
    end = module.index(END)
    generated = BEGIN + "\n" + "\n\n".join(sections) + "\n" + END
    MODULE.write_text(module[:begin] + generated + module[end + len(END):])
    total = sum(len(section) for section in sections)
    print(f"wrote {len(sections) - 1} tables ({total} bytes) for Unicode {ucd} into {MODULE.relative_to(REPO)}")


if __name__ == "__main__":
    main()
