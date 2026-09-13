"""The numbers the docs quote from an instrument, checked against the instrument.

    python3 bench/measured_numbers.py

`bench/doc_numbers.py` keeps the *counted* numbers honest: it measures the
tree — lines, kilobytes, targets — and fails when a sentence has drifted. The
numbers that came from a *measurement* had no keeper at all, and eleven of
the scripts that produce them run nowhere: a published second, megabyte or
ratio could stop being true and nothing would say so.

A shared runner cannot re-measure them. `bench/build_speed.py` says why in
its own words — the same binary measured 0.048 s, 0.109 s and 0.061 s
minutes apart, and the first invocation after a machine has been idle reads
about 40% high — and most of the scripts refuse outright unless the compiler
is a release build. So this file does not time anything. It checks the half
that *is* the same on every machine and in every second: that the sentence
and the instrument still describe the same experiment.

  * a table row the instrument can no longer produce is a table about a
    measurement nobody can repeat;
  * a column named after a flag that no longer exists is a column a reader
    cannot re-run;
  * a size, a count or a parameter quoted in prose is a fact about the
    generator, not about the clock, and drifts silently.

Three of the four stale figures found in the survey behind this file were of
exactly those kinds, and none of them was a timing. What this cannot check —
the seconds, the megabytes and the ratios themselves — is listed at the
bottom of the output, by name, so the gap is stated rather than implied.

Exits non-zero and names the disagreement.
"""

from __future__ import annotations

import importlib.util
import pathlib
import re
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent


def load(relative: str):
    """A bench script as a module, so its constants are read rather than retyped."""
    path = REPO / relative
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"measured_numbers: cannot load {relative}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def doc(relative: str) -> str:
    return (REPO / relative).read_text()


def quoted(text: str, pattern: str, where: str, wrong: list[str]) -> list[str]:
    """Every match of *pattern*'s first group, or a complaint that the sentence moved.

    A pattern that stops matching is the failure mode `doc_numbers.py` was
    bitten by twice: the check goes on passing while the sentence it was
    written for has been reworded away. So no match is an error here, never a
    silent pass.
    """
    hits = [m.group(1) for m in re.finditer(pattern, text)]
    if not hits:
        wrong.append(
            f"{where}: /{pattern}/ matches nothing. The sentence it was written "
            f"for was reworded or removed, so this check stopped checking it"
        )
    return hits


def check_bind_speed(wrong: list[str], held: list[str]) -> None:
    """SPEC.md quotes the generated shards' line counts; the generator writes them."""
    bind = load("bench/bind_speed.py")
    text = doc("SPEC.md")
    published = quoted(text, r"\| ([\d,]+) lines \| [\d.]+ s \|", "SPEC.md", wrong)
    if not published:
        return
    measured = []
    with tempfile.TemporaryDirectory() as raw:
        for types, methods in bind.SIZES:
            directory = pathlib.Path(raw) / f"s{types}x{methods}"
            directory.mkdir()
            bind.write_shard(directory, types, methods)
            measured.append(len((directory / "shard.cr").read_text().splitlines()))
    want = [int(value.replace(",", "")) for value in published]
    if want != measured:
        wrong.append(
            f"SPEC.md: the boundary table's shard sizes are {want}, "
            f"bench/bind_speed.py writes {measured}"
        )
        return
    held.append(f"bind_speed's three shards are {measured} lines, as SPEC.md says")


def check_build_pair(wrong: list[str], held: list[str]) -> None:
    """README.md quotes the generated head-to-head pair's two line counts."""
    text = doc("README.md")
    iyi_lines = quoted(text, r"and ([\d,]+) for what\n`[^`]*generate_pair\.py 300", "README.md", wrong)
    go_lines = quoted(text, r"each row is \d+ lines and ([\d,]+)", "README.md", wrong)
    if not iyi_lines or not go_lines:
        return
    with tempfile.TemporaryDirectory() as raw:
        subprocess.run(
            [sys.executable, str(REPO / "bench/build_speed/generate_pair.py"), "300", raw],
            check=True, capture_output=True,
        )
        measured_iyi = len((pathlib.Path(raw) / "medium.iyi").read_text().splitlines())
        measured_go = len((pathlib.Path(raw) / "medium.go").read_text().splitlines())
    want_iyi = int(iyi_lines[0].replace(",", ""))
    want_go = int(go_lines[0].replace(",", ""))
    if (want_iyi, want_go) != (measured_iyi, measured_go):
        wrong.append(
            f"README.md: the head-to-head pair is quoted as {want_iyi} iyi and {want_go} Go "
            f"lines, the generator writes {measured_iyi} and {measured_go}"
        )
        return
    held.append(f"the generated pair is {measured_iyi} iyi and {measured_go} Go lines, as README.md says")


def check_gc_arms(wrong: list[str], held: list[str]) -> None:
    """GC_DESIGN.md's columns must be arms `bench/gc_default.py` still has.

    This is the check that catches a table nobody can re-run: the default
    allocator was flipped on the strength of that very table, the script's
    arm names moved with the flip, and the header row kept naming a flag
    (`-Dgc_iyi`) the script no longer passes.
    """
    gc = load("bench/gc_default.py")
    text = doc("GC_DESIGN.md")
    header = quoted(text, r"\| workload \| (.+) \|\n\|---", "GC_DESIGN.md", wrong)
    if not header:
        return
    columns = [cell.strip() for cell in header[0].split("|")]
    if len(columns) != len(gc.ARMS):
        wrong.append(
            f"GC_DESIGN.md: the table has {len(columns)} measured columns, "
            f"bench/gc_default.py has {len(gc.ARMS)} arms ({', '.join(gc.ARMS)})"
        )
        return
    for arm, flags in gc.ARMS.items():
        needle = flags[0] if flags else "default"
        if not any(needle in column for column in columns):
            wrong.append(
                f"GC_DESIGN.md: no column names `{needle}`, which is how "
                f"bench/gc_default.py spells its `{arm}` arm today"
            )
    if not wrong:
        held.append(f"GC_DESIGN.md's columns are gc_default.py's {len(gc.ARMS)} arms")


def check_macro_sizes(wrong: list[str], held: list[str]) -> None:
    """Every N in SPEC.md's macro tables must be a size `macro_cost.py` sweeps."""
    source = (REPO / "bench/macro_cost.py").read_text()
    swept = {
        int(n)
        for group in re.findall(r"compare\(\s*\"[^\"]+\",[^()]*?\(([\d,\s]+)\)\s*\)", source, re.S)
        for n in re.findall(r"\d+", group)
    }
    if not swept:
        wrong.append("bench/macro_cost.py: no `compare(..., (sizes))` call found; this check is blind")
        return
    text = doc("SPEC.md")
    published = {
        int(row)
        for row in re.findall(r"^\| (\d+) \| [\d.]+ s \| [\d.]+ s \| [\d.]+", text, re.M)
    }
    if not published:
        wrong.append("SPEC.md: the macro-cost tables' rows no longer match /| N | s | s | ratio/")
        return
    orphans = sorted(published - swept)
    if orphans:
        wrong.append(
            f"SPEC.md: the macro tables publish N={orphans}, which bench/macro_cost.py "
            f"does not sweep (it sweeps {sorted(swept)}) — a row nobody can re-measure"
        )
        return
    held.append(f"every macro-cost row SPEC.md publishes is a size the script sweeps ({sorted(published)})")


def check_daemon_shape(wrong: list[str], held: list[str]) -> None:
    """SPEC.md spells the daemon measurement's shape in words; the script holds the numbers."""
    daemon = load("bench/daemon_full_build.py")
    text = doc("SPEC.md")
    words = {
        "twelve": 12, "eight": 8, "twenty": 20, "thirty": 30,
        "four": 4, "five": 5, "six": 6, "ten": 10,
    }
    modules = quoted(text, r"which builds (\w+) modules under `--crystal`", "SPEC.md", wrong)
    pairs = quoted(text, r"with codegen and a link, (\w+) alternating pairs", "SPEC.md", wrong)
    if not modules or not pairs:
        return
    if words.get(modules[0]) != daemon.MODULES or words.get(pairs[0]) != daemon.PAIRS:
        wrong.append(
            f"SPEC.md: the daemon measurement is described as {modules[0]} modules and "
            f"{pairs[0]} pairs, bench/daemon_full_build.py runs {daemon.MODULES} and {daemon.PAIRS}"
        )
        return
    held.append(f"the daemon measurement is {daemon.MODULES} modules and {daemon.PAIRS} pairs in both")


def check_context_threshold(wrong: list[str], held: list[str]) -> None:
    """AI_FIRST.md states the line the context-pack gate holds; the gate holds a constant."""
    pack = load("bench/context_pack.py")
    text = doc("AI_FIRST.md")
    stated = quoted(text, r"the pack must stay under (\d+)% of the raw closure", "AI_FIRST.md", wrong)
    if not stated:
        return
    if int(stated[0]) != round(pack.THRESHOLD * 100):
        wrong.append(
            f"AI_FIRST.md: the line is stated as {stated[0]}%, "
            f"bench/context_pack.py holds {round(pack.THRESHOLD * 100)}%"
        )
        return
    held.append(f"the context pack's line is {stated[0]}% in both")


# What no gate on a shared runner can check, named rather than left implied.
# Each is a figure the docs state in the present tense and only a quiet,
# release-built machine can produce; `bench/machine_probe.py` prints the
# fingerprint a reader needs to attribute one.
UNCHECKABLE = [
    "the front-end and end-to-end seconds (bench/build_speed.py, needs a release compiler and go)",
    "the edit-loop table and its 1.8x (bench/incremental.py, needs a release compiler and go)",
    "the artifact-vs-source front end (bench/artifact_speed.py, needs a release compiler)",
    "the boundary's percentages (bench/bind_speed.py, needs two release compilers)",
    "the daemon's seconds and its 26% (bench/daemon_full_build.py, needs a release daemon)",
    "the allocator table's seconds and RSS (bench/gc_default.py, needs release builds)",
    "the macro tables' seconds (bench/macro_cost.py, needs a release compiler)",
    "the resident-set band (bench/resident_probe.py, needs a release build)",
    "the runtime ratios (bench/runtime.py, needs release builds of both libraries)",
]


def main() -> int:
    wrong: list[str] = []
    held: list[str] = []
    for check in (
        check_bind_speed,
        check_build_pair,
        check_gc_arms,
        check_macro_sizes,
        check_daemon_shape,
        check_context_threshold,
    ):
        check(wrong, held)

    if wrong:
        print("A MEASUREMENT THE DOCS QUOTE NO LONGER MATCHES ITS INSTRUMENT\n")
        for line in wrong:
            print(f"  {line}")
        print(
            "\nFix the sentence, or fix the script it cites. A published measurement "
            "whose instrument has moved is a measurement nobody can repeat."
        )
        return 1

    for line in held:
        print(f"  {line}")
    print("\nthe experiments the docs describe are the experiments the scripts run")
    print("not checked here, because a shared runner cannot measure them:")
    for line in UNCHECKABLE:
        print(f"  - {line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
