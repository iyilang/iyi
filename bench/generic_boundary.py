#!/usr/bin/env python3
"""R-4, measured: what a generic crossing a module boundary costs today.

R-4 says a generic call across a boundary passes a dictionary keyed on
GC shape, and monomorphisation stays inside a module. Nothing in the
compiler does that; what the compiler does instead is R-1's other rule
taken literally: a generic's *body* travels in the artifact and every
consumer compiles it again for the types it uses. So a module made of
generics ships no object code at all, and a consumer's build carries the
library's bodies whether it asked for them or not. That is the design
this repository actually has, and until this file it was "specified and
unmeasured" in the README.

Two readings, both from the artifacts the sample corpus emits:

  1. what travels — per module, bytes by section: exports (the
     declarations a consumer compiles against), mono bodies (what it
     compiles again), macro bodies, object code (what it links and
     never compiles). Read straight off the section table, no decoder.
  2. what it buys — a consumer of a fully generic module, built from
     source and from artifacts, front end only, minimum of ROUNDS: the
     artifact arm still compiles the bodies, so the difference is what
     the declarations save, and what R-4's dictionary would add to it.

Two structural facts are asserted, because they are R-4 as built:
a module with no generic and no macro ships object code and no body;
a module that is all generics ships every body and no object code.
And the share of the corpus that is bodies is held under a line set
from the first measurement with headroom, the way context_pack.py
holds the pack: not a target, a tripwire, so the number in the SPEC
cannot drift without this file saying so.

    python3 bench/generic_boundary.py
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time

IYI = os.path.abspath(os.environ.get("IYI", "./bin/iyi"))
SAMPLES = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "samples", "iyi"))
ROUNDS = 5

# Section kinds, iyimod.cr's enum.
SECTIONS = {1: "header", 2: "hashes", 3: "imports", 4: "exports", 5: "macro bodies",
            6: "mono bodies", 7: "object code", 8: "initialiser", 9: "type ids",
            10: "constants", 11: "requires", 12: "regexes", 13: "class vars",
            14: "match types", 15: "symbols", 16: "top level", 17: "reopened",
            18: "libs", 19: "top level funs", 20: "inputs", 64: "layouts"}
MAGIC = b"IYIMOD\0\0"

# The entries whose imports pull the corpus's modules through the emitter.
ENTRIES = ["immutable.iyi", "collections.iyi", "derive.iyi", "calc.iyi",
           "webapp.iyi", "modules.iyi"]

# R-4 as built, pinned on two modules at the ends of the spectrum.
ALL_GENERIC = "std/list"    # every def is on List(T): bodies travel, no object code
NO_GENERIC = "calc/lexer"   # no type parameter, no macro: object code, no body

# Of what a consumer's front end reads from an artifact - exports, mono
# bodies, macro bodies; object code is the linker's - the share that is
# bodies it compiles again. First measurement on this corpus: 37%. The
# line is that with headroom, and a corpus that grows past it is a
# corpus this file asks about rather than one that quietly moved.
BODIES_CEILING = 0.50


def sections_of(path):
    with open(path, "rb") as f:
        assert f.read(8) == MAGIC, path
        version, count = struct.unpack("<II", f.read(8))
        table = [struct.unpack("<HHIQ", f.read(16)) for _ in range(count)]
    return {SECTIONS.get(kind, str(kind)): size for kind, _, size, _ in table}


def run(args, cwd):
    proc = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"failed: {' '.join(args)}\n{proc.stdout}{proc.stderr}")
    return proc.stdout


def main():
    failures = []
    work = tempfile.mkdtemp(prefix="iyi-r4-")
    try:
        corpus = os.path.join(work, "samples")
        shutil.copytree(SAMPLES, corpus)
        mods = os.path.join(work, "mods")
        for entry in ENTRIES:
            # A full build: object code is codegen's, and codegen is what
            # says which module has some.
            run([IYI, "build", "--emit-iyimod", mods, "-o",
                 os.path.join(work, "out"), entry], cwd=corpus)

        rows = []
        for dirpath, _, names in os.walk(mods):
            for name in sorted(names):
                if not name.endswith(".iyimod"):
                    continue
                path = os.path.join(dirpath, name)
                # A module's name is written with `/` on every platform;
                # the path it came from is `calc\lexer.iyimod` on Windows.
                module = os.path.relpath(path, mods)[:-len(".iyimod")].replace(os.sep, "/")
                rows.append((module, os.path.getsize(path), sections_of(path)))
        rows.sort()

        print(f"{'module':<16} {'bytes':>7} {'exports':>8} {'bodies':>7} {'macros':>7} {'object':>7}  bodies/read")
        totals = {"bytes": 0, "exports": 0, "mono bodies": 0, "macro bodies": 0, "object code": 0}
        by_module = {}
        reopening = []
        for module, size, sections in rows:
            bodies = sections.get("mono bodies", 0)
            macros = sections.get("macro bodies", 0)
            obj = sections.get("object code", 0)
            exports = sections.get("exports", 0)
            share = (bodies + macros) / (exports + bodies + macros)
            # A module that is nothing but additions to types it does not
            # own - `std/int` is `struct ::Int` and the tower - has no unit
            # of its own to ship: its machine code sits in the owner's, and
            # every body travels (`Section::Reopened`). Counted apart, since
            # the line is about how much of a module's *own* surface travels
            # as bodies; what would take these out is codegen owning a
            # reopening's code by the module that wrote it, and that is the
            # number this row keeps visible until it does.
            if sections.get("reopened", 0) and exports <= 32:
                reopening.append(module)
                print(f"{module:<16} {size:>7} {exports:>8} {bodies:>7} {macros:>7} {obj:>7}  {share:>5.0%}  (reopens a prelude type; apart)")
                by_module[module] = sections
                continue
            print(f"{module:<16} {size:>7} {exports:>8} {bodies:>7} {macros:>7} {obj:>7}  {share:>5.0%}")
            totals["bytes"] += size
            totals["exports"] += exports
            totals["mono bodies"] += bodies
            totals["macro bodies"] += macros
            totals["object code"] += obj
            by_module[module] = sections
        read = totals["exports"] + totals["mono bodies"] + totals["macro bodies"]
        bodies_share = (totals["mono bodies"] + totals["macro bodies"]) / read
        print(f"{'all':<16} {totals['bytes']:>7} {totals['exports']:>8} {totals['mono bodies']:>7} "
              f"{totals['macro bodies']:>7} {totals['object code']:>7}  {bodies_share:>5.0%}")
        without_code = [m for m, s in by_module.items() if s.get("object code", 0) == 0]
        print(f"\nof the {read:,} bytes a consumer's front end reads, {bodies_share:.0%} is bodies it compiles again;")
        print(f"{len(without_code)} of {len(rows)} modules ship no object code: {', '.join(sorted(without_code))}")
        if reopening:
            print(f"{len(reopening)} of them only reopen a prelude type, every body travelling, apart from the line: {', '.join(sorted(reopening))}")

        generic = by_module.get(ALL_GENERIC)
        if not generic:
            failures.append(f"{ALL_GENERIC} was not emitted")
        elif generic.get("object code", 0) != 0 or generic.get("mono bodies", 0) == 0:
            failures.append(f"{ALL_GENERIC} is R-4's all-generic case and should ship bodies and no object code: {generic}")
        plain = by_module.get(NO_GENERIC)
        if not plain:
            failures.append(f"{NO_GENERIC} was not emitted")
        elif plain.get("object code", 0) == 0 or plain.get("mono bodies", 0) != 0:
            failures.append(f"{NO_GENERIC} has no generic and should ship object code and no body: {plain}")
        if bodies_share > BODIES_CEILING:
            failures.append(f"bodies are {bodies_share:.0%} of what a consumer reads, over the {BODIES_CEILING:.0%} line")

        # What the declarations buy a consumer of an all-generic module,
        # front end only, arms alternated, minimum of ROUNDS. The artifact
        # arm compiles List(T)'s bodies too; R-4's dictionary is what
        # would take that out, and this is the room it has.
        consumer = "immutable.iyi"
        source_t, artifact_t = [], []
        for _ in range(ROUNDS):
            for arm, extra, bucket in (("source", [], source_t),
                                       ("artifact", ["--use-iyimod", mods], artifact_t)):
                start = time.monotonic()
                run([IYI, "build", "--no-codegen", "-o", os.path.join(work, "out"), consumer] + extra, cwd=corpus)
                bucket.append(time.monotonic() - start)
        print(f"\n{consumer} <- {ALL_GENERIC}, front end, min of {ROUNDS}: "
              f"from source {min(source_t) * 1000:.0f} ms, from artifacts {min(artifact_t) * 1000:.0f} ms "
              f"({min(artifact_t) / min(source_t):.2f}x)")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if failures:
        print()
        for failure in failures:
            print(f"FAIL  {failure}")
        return 1
    print("\nR-4 as built: bodies travel, object code stays, and the share is under the line")
    return 0


if __name__ == "__main__":
    sys.exit(main())
