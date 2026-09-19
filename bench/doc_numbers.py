#!/usr/bin/env python3
"""Fails when a number the docs state as current has drifted from the tree.

The docs quote sizes as facts a reader can check, and the convention is
`wc -l` (README says so where it first quotes one). Three times now a number
has gone stale without anyone noticing: PR #3 corrected a batch, the 0.2.0
merge left the prelude at 1,184 lines when it was 1,989, and the same figure
was repeated in eleven places across four files.

    python3 bench/doc_numbers.py          # check
    python3 bench/doc_numbers.py --list   # every occurrence found
    python3 bench/doc_numbers.py --json   # what the tree measures, for the site

Only CURRENT claims are checked. A release note saying "0.1.0 had a
1,184-line prelude" is a statement about the past and stays; the check looks
for the phrasings the docs use to describe the tree as it is now.

What this does NOT check is whether a sentence is true, only whether a number
matches what the tree measures. `bench/identity_floor.py` is the same idea for
a different kind of claim.
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent


def wc(paths) -> int:
    return sum(len(p.read_text().splitlines()) for p in paths)


def bang_names() -> int:
    """Distinct method names ending in `!` in Crystal's standard library.

    README says `!` propagates an error in iyi, so a Crystal method whose name
    ends in one cannot be called from a `.iyi` file, and quotes how many such
    names there are. `src/compiler/` is excluded because the compiler is not the
    standard library, and `__crystal_pseudo_!` is excluded because it is a
    compiler intrinsic rather than a name a person calls.
    """
    names: set[str] = set()
    for p in (REPO / "src").rglob("*.cr"):
        if "/compiler/" in str(p):
            continue
        try:
            text = p.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for m in re.finditer(r"^\s*def\s+([a-z_][A-Za-z0-9_]*!)", text, re.M):
            names.add(m.group(1))
    names.discard("__crystal_pseudo_!")
    return len(names)


def generated_project_lines() -> int:
    """What `bench/incremental/generate_project.py` writes, as iyi.

    The edit-loop numbers are about a generated 30-module project and the docs
    quote its size. The generator is the authority, so it is asked rather than
    remembered: two places said 7,208 while it emitted 7,207.
    """
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory() as work:
        subprocess.run(
            [sys.executable, "bench/incremental/generate_project.py", work],
            cwd=REPO, capture_output=True, text=True, check=True,
        )
        return wc(sorted((pathlib.Path(work) / "iyi").rglob("*.iyi")))


# The spec files that exist because of iyi's own rules, named rather than
# globbed. A glob for "iyi" in the path is the obvious measure and it is wrong:
# the namespace rename moved a dozen of Crystal's tool specs under
# `spec/compiler/iyi/`, and counting those claims Crystal's testing as iyi's.
# `iyi_path_spec.cr`, `iyi-daemon_spec.cr` and `iyi/tools/unreachable_spec.cr`
# are the same trap wearing an iyi name: each is a Crystal spec that was renamed.
#
# A missing file raises rather than counting short, because a rename that this
# list does not follow would otherwise report a smaller number as though the
# specs had shrunk.
IYI_SPECS = (
    "spec/compiler/iyimod_spec.cr",             # the artifact format
    "spec/compiler/iyi_import_spec.cr",         # the import path
    "spec/compiler/iyi_derive_spec.cr",         # derive, R-5
    "spec/compiler/semantic/iyi_spec.cr",       # iyi's own semantics
    "spec/compiler/iyi/rx_spec.cr",             # the engine, differential
    "spec/compiler/formatter/iyi_formatter_spec.cr",  # `pub`, which Crystal has no word for
    "spec/compiler/object_header_spec.cr",      # the collector's header, GC_DESIGN.md Stage 1
)


def iyi_spec_lines() -> int:
    paths = []
    for rel in IYI_SPECS:
        path = REPO / rel
        if not path.exists():
            raise SystemExit(
                f"doc_numbers: {rel} is gone, so the spec count cannot be measured. "
                "If it moved, follow it here; the number is not allowed to shrink quietly."
            )
        paths.append(path)
    return wc(paths)


def measured() -> dict[str, int]:
    """The numbers, measured the way the docs say they are measured."""
    return {
        "prelude": wc(sorted((REPO / "src/iyi").glob("*.iyi"))),
        "prelude_library": prelude_library_lines(),
        # The platform floor the rule above excludes, and the library with it
        # still in: both are stated in SPEC.md beside the figure itself, so
        # that what the ceiling does not count is as visible as what it does.
        "platform_floor": platform_floor_lines(),
        "library_with_floor": library_with_floor_lines(),
        "std": wc(sorted((REPO / "src/std").glob("*.iyi"))),
        "compiler": wc(sorted((REPO / "src/compiler").rglob("*.cr"))),
        "samples": len(sorted((REPO / "samples/iyi").glob("*.iyi"))),
        "samples_roundtrip": samples_roundtrip(),
        # Bytes on disk, not lines: the docs quote the library's size as a
        # download, which is what a person unpacking the tarball sees.
        "prelude_kb": round(
            sum(p.stat().st_size for p in sorted((REPO / "src/iyi").glob("*.iyi"))) / 1024
        ),
        # The other half of that download, quoted the same way: the modules
        # `import std/...` resolves to, which the tarball shipped none of
        # until 0.12.0.
        "std_kb": round(
            sum(p.stat().st_size for p in sorted((REPO / "src/std").glob("*.iyi"))) / 1024
        ),
        "bang_names": bang_names(),
        "generated": generated_project_lines(),
        "spec_iyi": iyi_spec_lines(),
        "targets": targets(),
        "iyimod_format": iyimod_format(),
    }


# The other language's 0.1.0 core library: 3,551 lines of core files plus 183
# of fibers over pthreads, remeasured from that tree (SPEC.md I.4). The number
# iyi's own library is held under, and a check rather than a habit since the
# night Windows' floor walked 508 lines over it and nothing failed.
CEILING = 3_734


def prelude_library_lines() -> int:
    """The figure SPEC.md holds to the 3,734-line ceiling: the library
    without any platform's floor.

    Everything under `src/iyi/` except two things. First, what Crystal's
    0.1.0 core got from outside its own count - the allocator and collector
    (Boehm's libgc; the block between two marks in prelude.iyi), the
    scheduler and kernel thread (pthreads and libevent, beyond the 183 lines
    the ceiling already carries for fibers), and the float printer and parser
    (libc's printf and strtod). Second, every platform's floor
    (`platform_floor_lines`), which is the rule SPEC.md I.4 settled after
    Windows: 0.1.0's own floor was libc and was not in its 3,734 either, so
    counting iyi's kernel32, syscall and libSystem arms compared a library
    that carries its floor against one that did not.

    `library_with_floor` is the same walk without that second exclusion, and
    is stated beside this everywhere this is, because a reader opening
    `src/iyi/` sees those lines too.
    """
    return library_with_floor_lines() - platform_floor_lines()


def library_with_floor_lines() -> int:
    """The library with every platform's floor still in it: the number a
    reader counts by opening the files. See `prelude_library_lines`."""
    files = sorted((REPO / "src/iyi").glob("*.iyi"))
    outside = {"concurrency.iyi", "thread.iyi", "float.iyi"}
    total = 0
    for path in files:
        lines = path.read_text().splitlines()
        if path.name in outside:
            continue
        if path.name == "prelude.iyi":
            start = next(i for i, l in enumerate(lines) if l.startswith("# ── The memory layer"))
            end = next(i for i, l in enumerate(lines) if l.startswith("# ── end of the memory layer"))
            total += len(lines) - (end - start + 1)
        else:
            total += len(lines)
    return total


# The OS, architecture and ABI flags. A build-configuration flag
# (`gc_boehm`, `release`, `preview_mt`) is not one: its arm is a choice
# about this build, not a platform's floor, and it stays in the count.
PLATFORM_FLAGS = frozenset("""
    linux darwin win32 wasm32 wasi unix bsd openbsd freebsd netbsd dragonfly
    solaris android musl gnu msvc x86_64 aarch64 arm armhf i386 avr bits32 bits64
""".split())

MACRO_DIRECTIVE = re.compile(r"\{%-?\s*(if|unless|elsif|else|end)\b(.*?)-?%\}")
MACRO_FLAG = re.compile(r"flag\?\(\s*:(\w+)")


def platform_floor_lines(only: str | None = None) -> int:
    """Lines of the library that exist only for a platform: inside a macro
    conditional whose condition names an OS, architecture or ABI flag.

    Every arm of such a conditional counts, `else` included: an `else` under
    `flag?(:linux)` is the code the other platforms take, and it exists for
    the same reason. Measured over exactly what `prelude_library_lines`
    counts, so the two subtract.

    SPEC.md I.4 holds the library to 3,734 lines and records that Windows
    breached it. This is the number that says what closing the breach by
    rule rather than by rewrite would cost, and it is measured rather than
    counted by hand: the two figures the breach was first written with
    disagreed, one of them having subtracted Windows' arms alone from a
    sentence about every platform's.

    *only* narrows it to the arms naming one flag, for the breakdown.
    """
    files = sorted((REPO / "src/iyi").glob("*.iyi"))
    outside = {"concurrency.iyi", "thread.iyi", "float.iyi"}
    total = 0
    for path in files:
        if path.name in outside:
            continue
        lines = path.read_text().splitlines()
        if path.name == "prelude.iyi":
            start = next(i for i, l in enumerate(lines) if l.startswith("# ── The memory layer"))
            end = next(i for i, l in enumerate(lines) if l.startswith("# ── end of the memory layer"))
            lines = lines[:start] + lines[end + 1:]
        stack: list[bool] = []
        for line in lines:
            inside_before = any(stack)
            for kind, rest in MACRO_DIRECTIVE.findall(line):
                named = set(MACRO_FLAG.findall(rest))
                if only is None:
                    platform = bool(named) and named <= PLATFORM_FLAGS
                else:
                    platform = only in named
                if kind in ("if", "unless"):
                    stack.append(platform)
                elif kind in ("elsif", "else"):
                    if stack:
                        stack[-1] = stack[-1] or platform
                elif kind == "end":
                    if stack:
                        stack.pop()
            # The line carrying `{% if flag?(:win32) %}` is the arm's own.
            if inside_before or any(stack):
                total += 1
    return total


def samples_roundtrip() -> int:
    """The samples `bench/samples_roundtrip.sh` builds a second time from
    artifacts, with the source of every module they import deleted.

    The script's own list is the authority rather than a count typed beside it:
    the list names six and two files went on saying five.
    """
    text = (REPO / "bench/samples_roundtrip.sh").read_text()
    m = re.search(r'^SAMPLES="([^"]*)"', text, re.M)
    if not m:
        raise SystemExit(
            "doc_numbers: bench/samples_roundtrip.sh no longer names its samples "
            'in a `SAMPLES="..."` line, so this check cannot find them and is '
            "not checking anything"
        )
    return len(m.group(1).split())


def targets() -> int:
    """Distinct targets CI type-checks the library for.

    Read out of the workflow rather than counted by hand, which is how the docs
    came to say eight while the workflow listed nine. `x86_64-w64-mingw32` and
    `x86_64-windows-gnu` are the same platform spelled by two vendors, so the
    audit list adds nothing the type-check list does not already name.
    """
    text = (REPO / ".github/workflows/iyi.yml").read_text()
    m = re.search(
        r"Type-check the standard library.*?for target in (.*?); do", text, re.S
    )
    if not m:
        raise SystemExit(
            "doc_numbers: the workflow's type-check target list moved; "
            "this check cannot find it and so is not checking anything"
        )
    return len([t for t in m.group(1).replace("\\", "").split() if t])


def iyimod_format() -> int:
    """The `.iyimod` format version the compiler writes.

    SPEC.md quotes it as a current fact about the artifact, and it said v19
    while the compiler wrote v51 — thirty-three bumps, none of which anyone
    thought to carry into the sentence. Read out of the constant, like every
    other number here.
    """
    text = (REPO / "src/compiler/iyi/iyimod.cr").read_text()
    m = re.search(r"^\s*FORMAT_VERSION = (\d+)_u32", text, re.M)
    if not m:
        raise SystemExit(
            "doc_numbers: src/compiler/iyi/iyimod.cr no longer states "
            "`FORMAT_VERSION = N_u32`, so this check cannot find it and is "
            "not checking anything"
        )
    return int(m.group(1))


# Each entry: the measured key, the pattern that quotes it as current, the file,
# and how many times that pattern is expected to appear there. The count is
# load-bearing: two sites in one file shared a pattern, and dropping one of them
# left the other matching, so the check went on passing while a sentence it was
# meant to cover had gone. A pattern must capture the number in group 1.
CLAIMS: list[tuple[str, str, str, int]] = [
    ("prelude", r"iyi's own library is ([\d,]+) lines", "README.md", 2),
    ("prelude", r"iyi's own library, ([\d,]+) lines", "README.md", 1),
    ("prelude", r"standard library instead of ([\d,]+)", "README.md", 1),
    ("prelude", r"iyi's own prelude \| ([\d,]+) lines", "SPEC.md", 1),
    ("prelude_library", r"of which ([\d,]+) are the library held to the", "SPEC.md", 1),
    ("platform_floor", r"the platform floor measures \*\*([\d,]+) lines\*\*", "SPEC.md", 1),
    ("platform_floor", r"floor of ([\d,]+) lines", "SPEC.md", 1),
    ("library_with_floor", r"([\d,]+) with every platform's floor", "SPEC.md", 1),
    ("library_with_floor", r"pening `src/iyi/` counts ([\d,]+)", "SPEC.md", 1),
    ("prelude_library", r"of which the library is ([\d,]+)", "SPEC.md", 1),
    ("prelude_library", r"the library:\n\*\*([\d,]+) lines\*\* of the", "SPEC.md", 1),
    ("prelude", r"still true of iyi's own ([\d,]+) lines", "SPEC.md", 1),
    ("prelude", r"Done: ([\d,]+) lines", "SPEC.md", 1),
    ("prelude", r"\| ([\d,]+)-line own prelude", "SPEC.md", 1),
    ("prelude", r"against iyi's own ([\d,]+)-line prelude", "SPEC.md", 1),
    ("prelude", r"against iyi's own ([\d,]+)-line library", "CHANGELOG.md", 1),
    ("prelude", r"against iyi's own ([\d,]+)-line", "samples/iyi/calc.iyi", 1),
    ("std", r"own prelude \+ ([\d,]+) in std", "SPEC.md", 1),
    ("compiler", r"\| ([\d,]+) lines, Crystal, forked", "SPEC.md", 1),
    # The other place the compiler's size is stated as current, and the reason
    # one file disagreed with itself by 25,747 lines: the row above covers the
    # comparison table, this one the release's own numbers table, and only the
    # first of them existed.
    ("compiler", r"\| ([\d,]+) lines, none of it written in iyi", "SPEC.md", 1),
    ("spec_iyi", r"\| ([\d,]+) for iyi \|", "SPEC.md", 1),
    # The artifact format, which drifted furthest of anything here: the
    # sentence said v19 while the compiler wrote v51.
    ("iyimod_format", r"`\.iyimod` v([\d,]+), checksum per section", "SPEC.md", 1),
    ("prelude_kb", r"library is ([\d,]+) KB on disk", "README.md", 1),
    ("prelude_kb", r"iyi's own ([\d,]+) KB prelude", "README.md", 1),
    ("std_kb", r"the ([\d,]+) KB of `src/std`", "README.md", 1),
    ("std_kb", r"the directory's ([\d,]+) KB is a second", "Makefile", 1),
    ("prelude_kb", r"beside `bin/iyi` is ([\d,]+) KB", "Makefile", 1),
    ("prelude_kb", r"ships only iyi's own ([\d,]+) KB", "Makefile", 1),
    ("prelude_kb", r"its own, and it is ([\d,]+) KB", "Makefile", 1),
    ("bang_names", r"standard library has \*\*([\d,]+) such names\*\*", "README.md", 1),
    ("generated", r"edit one module in a ([\d,]+)-line project", "README.md", 1),
    ("generated", r"on the same ([\d,]+) lines", "README.md", 1),
    # The same generated project, quoted seven more times in SPEC.md — the
    # numbers table at the top of it included — and every one of the seven said
    # 7,208 while the generator emitted 7,207. The two rows above name
    # README.md, so the correction landed there and nowhere else. The file that
    # states a number most often is the one that most needs a pattern.
    ("generated", r"rebuild \(30 modules, ([\d,]+) lines\)", "SPEC.md", 1),
    # Two sites, and the second wraps between "300" and "types", which is why
    # this matches whitespace rather than a space.
    ("generated", r"300\s+types, ([\d,]+) lines", "SPEC.md", 2),
    ("generated", r"30 modules and ([\d,]+) lines", "SPEC.md", 1),
    ("generated", r"it pays it on a ([\d,]+)-line project", "SPEC.md", 1),
    ("generated", r"one module edited in a ([\d,]+)-line project", "SPEC.md", 1),
    ("generated", r"30-module, ([\d,]+)-line project", "SPEC.md", 1),
    # The same project again as one row of the size sweep, which is where the
    # figure was right while the seven sentences above it were wrong.
    ("generated", r"30 modules of 10 types, ([\d,]+) lines", "SPEC.md", 1),
    ("targets", r"compiles for \*\*(\w+) targets\*\*", "README.md", 1),
    ("targets", r"for (\w+) targets and was tested on one", "SPEC.md", 1),
    ("targets", r"Four of the (\w+) now", "SPEC.md", 1),
    # The count of sample programs was quoted as a word and drifted by three
    # before anything noticed, because the digit patterns above cannot see a
    # spelled-out number.
    # `[\w-]+` rather than `\w+`: past twenty the spelled-out number is
    # hyphenated, and `\w+` silently stopped matching the sentence at
    # "twenty-three" rather than reporting the count had moved.
    ("samples", r"\| ([\w-]+) programs:", "README.md", 1),
    # The same count in SPEC.md's numbers table, where it said 9 — the number
    # of samples there were when the row was written.
    ("samples", r"\| samples \| ([\d,]+) programs,", "SPEC.md", 1),
    # And the other half of that row, which is a count of the roundtrip's list
    # rather than of the directory, and had drifted the same way.
    ("samples_roundtrip", r"of which ([\d,]+) rebuild from artifacts", "SPEC.md", 1),
]

# The prose spells small numbers as words and should keep doing so, so the
# check reads words as well as digits rather than pushing digits into a
# sentence to suit itself.
WORDS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
    "twenty-one": 21, "twenty-two": 22, "twenty-three": 23,
    "twenty-four": 24, "twenty-five": 25, "twenty-six": 26,
    "twenty-seven": 27, "twenty-eight": 28, "twenty-nine": 29, "thirty": 30,
}


def as_number(raw: str) -> int | None:
    bare = raw.replace(",", "")
    if bare.isdigit():
        return int(bare)
    return WORDS.get(bare.lower())


def main() -> int:
    show_all = "--list" in sys.argv
    truth = measured()
    # The site reads these rather than transcribing them, so the page and this
    # gate agree by construction: one measurement function, two consumers. A
    # number typed into a template is the artifact this project argues against.
    if "--json" in sys.argv:
        import json

        print(json.dumps(truth, indent=2, sort_keys=True))
        return 0
    wrong: list[str] = []
    found: list[str] = []

    for key, pattern, rel, expected in CLAIMS:
        fp = REPO / rel
        text = fp.read_text()
        hits = list(re.finditer(pattern, text))
        if len(hits) != expected:
            wrong.append(
                f"{rel}: /{pattern}/ appears {len(hits)} time(s), expected "
                f"{expected}. A sentence this was written to cover was reworded "
                f"or removed, so the check stopped checking it"
            )
            if not hits:
                continue
        for m in hits:
            line = text[: m.start()].count("\n") + 1
            stated = as_number(m.group(1))
            if stated is None:
                wrong.append(
                    f"{rel}:{line}  captured {m.group(1)!r}, which is neither a "
                    f"number nor a word this check knows. Add it to WORDS or "
                    f"tighten the pattern"
                )
                continue
            ok = stated == truth[key]
            found.append(f"{'ok  ' if ok else 'WRONG'}  {rel}:{line}  {key}={stated}")
            if not ok:
                wrong.append(
                    f"{rel}:{line}  says {key} is {stated:,}, tree measures {truth[key]:,}"
                )

    # The ceiling itself, which was prose and a habit until Windows walked
    # 508 lines over it and nothing failed. SPEC.md I.4 holds the library -
    # the figure above, every platform's floor excluded - to the lines that
    # core carried, and the rule is that a method entering
    # the library moves another out first. That is a number, so it is a
    # check: a library over the ceiling fails here, with what it is over by.
    if truth["prelude_library"] > CEILING:
        wrong.append(
            f"the library is {truth['prelude_library']:,} lines, {truth['prelude_library'] - CEILING:,} "
            f"over the {CEILING:,} ceiling (SPEC.md I.4). What enters the library moves something "
            f"out of it first, or moves to `src/std/`, which this figure does not count"
        )

    if show_all:
        for f in found:
            print(f)
        print()

    print("measured:", ", ".join(f"{k}={v:,}" for k, v in sorted(truth.items())))

    if not wrong:
        print("the numbers the docs state are the numbers the tree has")
        return 0

    print("\nA NUMBER THE DOCS STATE AS CURRENT HAS DRIFTED\n")
    for w in wrong:
        print(f"  {w}")
    print(
        "\nUpdate the sentence, or update this script if what it measures is no "
        "longer what the sentence means. Counts are `wc -l`, which is the "
        "convention README states where it first quotes one."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
