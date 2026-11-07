#!/usr/bin/env python3
"""The runtime reaches no preemption check (SPEC.md III.4.13, part 9).

    python3 bench/preempt_audit.py program.ll

Reads the LLVM IR of a program with a pool - `iyi build --emit llvm-ir`,
which writes it after the checks went in, with its debug line tables - and
fails if a function compiled from one of the runtime's files, or any
function one of them reaches by direct calls, holds a check: a call to
`__iyi_preempt`, the check's slow half.

The runtime's files are the files that define the scheduler, the pool,
threads, the allocator and the collector - wherever a function named after
one of them (`ANCHORS`) was written - whatever those files are called: a
copy of the prelude that renames the scheduler's file, which the compiler
then takes for a library's, is what this is for.
A check inside the scheduler, the allocator, the collector or the thread
code would give a worker up with a worker's structures half changed, or
with one worker's state in hand across a move to another; and a check in
a library def the runtime calls would do the same from one call further
down, which is why the compiler gives the runtime a copy of each, compiled
without one (`codegen.cr#iyi_runtime_copy?`). Indirect calls - a `Proc` -
are not followed: the runtime calls a task's body that way, and the task's
own code checks. Nor is `__iyi_main`, the program's top-level code, which
the entry point calls by name for the same reason.

bench/parallel_exercise.sh runs it on bench/parallel_preempt_lib.iyi, and
on a copy of the prelude whose scheduler the compiler does not recognise.
"""
import os
import re
import sys

# Names that only the runtime defines functions under, and its entry point
# and the check's slow half.
ANCHORS = ("*IyiScheduler::", "*IyiWorkers::", "*IyiThread", "*IyiHeap::", "*IyiMark::",
           "*IyiRoots::", "*IyiSchedLock::", "*IyiRuntimeLock::")
ENTRY_POINTS = {"main", "__iyi_preempt"}
SLOW = "__iyi_preempt"
PROGRAM = "__iyi_main"
NAME = r'@("(?:[^"\\]|\\.)*"|[-\w.$]+)'
# A definition's header line, and its body up to the closing brace: the
# first global the header names is the function, since a personality
# routine comes after the parameters.
DEFINE = re.compile(r"^define ([^\n]*)\{\n(.*?)^\}", re.M | re.S)
CALL = re.compile(r"\b(?:call|invoke)\b[^\n]*?" + NAME + r"\(")
DIFILE = re.compile(r"^!(\d+) = !DIFile\(([^\n]*)\)$", re.M)
FIELD = r'\b%s: "((?:[^"\\]|\\.)*)"'
SUBPROGRAM = re.compile(r"^!(\d+) = distinct !DISubprogram\(([^\n]*)\)$", re.M)


def unquote(name: str) -> str:
    return name[1:-1] if name.startswith('"') else name


def path_of(fields: str) -> str:
    """A DIFile's file name, under its directory unless it is absolute."""
    found = {key: re.search(FIELD % key, fields) for key in ("directory", "filename")}
    directory, filename = (f[1].replace("\\\\", "/").replace("\\", "/") if f else "" for f in found.values())
    if not directory or filename.startswith("/") or re.match(r"[A-Za-z]:/", filename):
        return filename
    return f"{directory}/{filename}"


def main(path: str) -> int:
    text = open(path, encoding="utf-8", errors="replace").read()
    files = {m[1]: path_of(m[2]) for m in DIFILE.finditer(text)}
    subprogram_file = {}
    for m in SUBPROGRAM.finditer(text):
        found = re.search(r"\bfile: !(\d+)", m[2])
        subprogram_file[m[1]] = files.get(found[1]) if found else None

    calls: dict[str, set[str]] = {}
    checked: set[str] = set()
    file_of: dict[str, str] = {}
    for m in DEFINE.finditer(text):
        named = re.search(NAME, m[1])
        if not named:
            continue
        name = unquote(named[1])
        callees = {unquote(c) for c in CALL.findall(m[2])}
        if SLOW in callees:
            checked.add(name)
        calls[name] = callees
        dbg = re.search(r"!dbg !(\d+)", m[1])
        if dbg and subprogram_file.get(dbg[1]):
            file_of[name] = subprogram_file[dbg[1]]
    runtime_files = {file_of[name] for name in file_of
                     if name in ENTRY_POINTS or (name.startswith(ANCHORS) and not name.endswith("$runtime"))}
    runtime = [name for name in calls if file_of.get(name) in runtime_files]
    if not runtime:
        print(f"preempt audit: {path} names no function of the runtime's files; built without debug line tables?")
        return 1
    if not checked:
        print(f"preempt audit: {path} has no check at all; a program with no pool?")
        return 1

    # Everything the runtime's functions reach by direct calls, and the
    # caller each was first reached from, to name a path.
    reached = {name: None for name in runtime}
    work = list(runtime)
    while work:
        caller = work.pop()
        for callee in calls.get(caller, ()):
            if callee in calls and callee not in reached and callee != PROGRAM:
                reached[callee] = caller
                work.append(callee)

    bad = sorted(name for name in reached if name in checked and name != SLOW)
    copies = sum(1 for name in reached if name.endswith("$runtime"))
    if bad:
        print(f"preempt audit: {len(bad)} function(s) the runtime reaches hold a preemption check:")
        for name in bad[:8]:
            chain = [name]
            while reached[chain[-1]] is not None and len(chain) < 6:
                chain.append(reached[chain[-1]])
            print("  " + " -> ".join(reversed(chain)))
        return 1
    names = ", ".join(sorted(os.path.basename(f) for f in runtime_files))
    print(f"preempt audit: {len(runtime)} functions of the runtime's files ({names}) reach "
          f"{len(reached) - len(runtime)} others ({copies} of them copies compiled for the runtime), "
          f"and none of them checks; {len(checked)} functions elsewhere do")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2].strip())
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
