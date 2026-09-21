#!/usr/bin/env python3
"""Every gate in `bench/` is reached by something.

    python3 bench/gates_reachable.py

A gate that nothing runs is a gate that passes on the machine that wrote it
and nowhere else. This repository has been bitten by that three times in one
release: `format_exercise`, `io_exercise` and `socket_exercise` all existed,
all held, and were named in the workflow by nothing — nine seconds for the
three of them, which is what an unrun gate was saving. `bench/panics.sh` was
the fourth, in a narrower form: it ran on Linux and darwin and the sentence
it asserts is Windows' own, so the one platform it was about was the one
platform nothing checked it on.

So this is that lesson, made a check. A script counts as reached when

  * a workflow step names it,
  * another script under `bench/` runs or sources it — including
    `bench/std_exercise.sh`'s discovery glob, which is how the sixty
    `std_*_exercise.sh` siblings run,
  * the `Makefile` or `Makefile.win` names it, or
  * a script under `scripts/` or a spec names it.

Measured on this tree, the last two arms carry nothing: every reached
script is named by a workflow step or by another bench script, so the
`Makefile` and `scripts/` arms are there for a way of running a gate that
nothing uses yet rather than for one it relies on. A mention in a target
no job invokes would count as reached, which is the one way this check can
be too generous — worth knowing where the generosity is.

What is left is either a gate nobody runs — the thing to fix — or a *tool*,
which is a different kind of file: it takes an argument and answers a
question a person asked, rather than passing or failing. Those are listed
below with what they are for, and the list is short on purpose: a file that
is neither run nor explained is what this exists to name.

Exits non-zero if anything is unreached and unexplained.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(os.path.dirname(__file__)))
BENCH = os.path.join(ROOT, "bench")
REFERENCE = re.compile(r"bench/([A-Za-z0-9_]+\.(?:sh|py))")

# A tool, not a gate: it takes a path and prints a measurement, so there is
# nothing for a job to pass or fail. Each says where its answer is used,
# because "not a gate" is a claim and this is where it is written down.
TOOLS = {
    # `python3 bench/migrate_count.py <src dir>` counts the shapes a
    # file-per-module language has to answer for in a Crystal tree. Its
    # numbers on one 8,079-line application are read in SPEC.md III.6,
    # "What a migration would need, measured"; the application is not in
    # this repository, so there is no tree here to point it at.
    "migrate_count.py",
}


def scripts():
    return {f for f in os.listdir(BENCH) if f.endswith((".sh", ".py"))}


def text_of(path):
    with open(path, errors="ignore") as handle:
        return handle.read()


def reached(every):
    """Every script something names, and who names it."""
    by = {}

    def note(name, who):
        if name in every:
            by.setdefault(name, set()).add(who)

    workflow = os.path.join(ROOT, ".github", "workflows")
    for directory, _, files in os.walk(workflow):
        for name in files:
            path = os.path.join(directory, name)
            for found in REFERENCE.findall(text_of(path)):
                note(found, os.path.relpath(path, ROOT))

    for name in sorted(every):
        # This script names other scripts in order to explain them, and a
        # mention is not a run: counting its own prose reported the tool
        # below as reached and would report the next unrun gate the same
        # way, as long as somebody had written its name down here.
        if name == os.path.basename(__file__):
            continue
        body = text_of(os.path.join(BENCH, name))
        for found in REFERENCE.findall(body):
            if found != name:
                note(found, f"bench/{name}")
        # The discovery glob: `std_exercise.sh` runs every sibling it finds,
        # which is how sixty module exercises reach CI without sixty steps.
        if "std_*_exercise.sh" in body:
            for sibling in every:
                if sibling.startswith("std_") and sibling.endswith("_exercise.sh"):
                    note(sibling, f"bench/{name} (discovered)")

    for extra in ("Makefile", "Makefile.win"):
        path = os.path.join(ROOT, extra)
        if os.path.isfile(path):
            for found in REFERENCE.findall(text_of(path)):
                note(found, extra)

    for tree in ("scripts", "spec"):
        base = os.path.join(ROOT, tree)
        for directory, _, files in os.walk(base):
            for name in files:
                path = os.path.join(directory, name)
                for found in REFERENCE.findall(text_of(path)):
                    note(found, os.path.relpath(path, ROOT))

    return by


def main():
    every = scripts()
    by = reached(every)
    unreached = sorted(every - set(by))
    unexplained = [name for name in unreached if name not in TOOLS]

    print(f"{len(every)} scripts under bench/, {len(by)} of them reached")
    for name in unreached:
        why = "a tool, not a gate" if name in TOOLS else "REACHED BY NOTHING"
        print(f"  {name:34s} {why}")

    missing_tools = sorted(TOOLS - every)
    if missing_tools:
        print()
        print("TOOLS names a file that is not there: " + ", ".join(missing_tools))
        print("Remove it from the list, in the same commit as the file.")
        return 1

    named_tools = sorted(TOOLS & set(by))
    if named_tools:
        print()
        print("TOOLS names a file something runs: " + ", ".join(named_tools))
        print("It is a gate then, so take it off the list — the list is for")
        print("files nothing runs, and an entry that is run hides the next one.")
        return 1

    if unexplained:
        print()
        print("A gate nothing runs passes on the machine that wrote it:")
        for name in unexplained:
            print(f"    bench/{name}")
        print()
        print("Name it in a workflow job — the job whose platform the gate is")
        print("about — or, if it is a tool rather than a gate, add it to TOOLS")
        print("in this script with what its answer is for, in the same commit.")
        return 1

    print()
    print("every gate under bench/ is reached by something that runs it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
