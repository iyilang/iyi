#!/usr/bin/env python3
"""Typing every written def at its definition costs each def once.

    python3 bench/definition_typing_scale.py

R-2c types a fully written def where it is written, caller or no caller:
the compiler puts one probe per def at the top of the program, an
`if false` that calls it once. The probes' variables were merged into the
program's after each probe, as any branch's are, so every probe copied and
merged every variable the probes before it had made, and the front end
grew with the square of the defs a program declares. 4,000 one-line
methods took 2.16 s to type against 0.08 for 500 - twenty-seven times the
time for eight times the code - with 0.15.4's release compiler; the
generated pair `bench/build_speed.py` builds, 900 probed defs, spent half
its semantic pass there.

This builds the same shape at 500 and 4,000 defs with `--no-codegen`, best
of three each, and fails when eight times the defs cost more than twelve
times the time: linear typing measures 2 to 3 here, the square 19 to 27.
The ratio, not a time, is the check, so a slow machine does not fail it
and a fast one does not hide it.

And a variable assigned many times costs each assignment once. Every
assignment binds the variable to one more value and merges all of them
again, and the merge built an array as long as the value list to do it:
16,000 lines of `x = x + 1` took 838 MB to type against 70 for 2,000 with
0.15.4's release compiler. The same values of one type are now answered
by comparison. This types both and fails when eight times the lines take
more than three times the peak memory: 1.2 now, 12 before. Memory rather
than time, because a release compiler made the square cheap in time and
not in space.

And a union of many unrelated classes costs each member once. A variable
given one of 1,200 classes a branch at a time grows its union a member per
assignment, and each growth asked every pair of members for their common
ancestor, a walk up both superclass chains, then scanned the list for each
member it added: 1,200 took 7.9 s against 0.18 for 300 with 0.15.4's
release compiler, forty-four times the time for four times the classes.
Plain classes now combine by their topmost virtual root, found once per
member and looked up in a hash, and the list keeps a set once it is long.
This types both and fails past twelve times the time: 5.5 now.
"""
import os
import pathlib
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
IYI = os.environ.get("IYI", str(ROOT / "bin" / "iyi"))
SMALL, LARGE = 500, 4000
LIMIT = 12.0
RUNS = 3
LINES_SMALL, LINES_LARGE = 2000, 16000
MEMORY_LIMIT = 3.0
CLASSES_SMALL, CLASSES_LARGE = 300, 1200


def program(count: int) -> str:
    return "".join(
        f"struct W{i}\n  def label(x : Int32) : Int32\n    x + {i}\n  end\nend\n"
        for i in range(count)
    ) + "puts 1\n"


def best(path: pathlib.Path) -> float:
    times = []
    for _ in range(RUNS):
        started = time.perf_counter()
        result = subprocess.run([IYI, "build", "--no-codegen", str(path)],
                                capture_output=True, text=True)
        times.append(time.perf_counter() - started)
        if result.returncode != 0:
            print(f"{path.name} did not type:\n{result.stdout}{result.stderr}")
            sys.exit(1)
    return min(times)


def reassignments(count: int) -> str:
    return "x = 1\n" + "".join(f"x = x + {i % 7}\n" for i in range(count)) + "puts x\n"


def wide_union(count: int) -> str:
    return ("".join(f"class D{i}\nend\n" for i in range(count))
            + "r = Program.args.size\ny = nil\n"
            + "".join(f"y = D{i}.new if r == {i}\n" for i in range(count))
            + "puts y.class\n")


def peak_kb(path: pathlib.Path) -> int:
    """The child's own peak resident set, from its own rusage."""
    child = subprocess.Popen([IYI, "build", "--no-codegen", str(path)],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = child.stdout.read()
    _, status, usage = os.wait4(child.pid, 0)
    child.returncode = os.waitstatus_to_exitcode(status)
    if child.returncode != 0:
        print(f"{path.name} did not type:\n{output.decode(errors='replace')}")
        sys.exit(1)
    # Kilobytes on Linux, bytes on darwin.
    return usage.ru_maxrss // 1024 if sys.platform == "darwin" else usage.ru_maxrss


def main() -> None:
    work = pathlib.Path(tempfile.mkdtemp())
    measured = {}
    for count in (SMALL, LARGE):
        path = work / f"defs_{count}.iyi"
        path.write_text(program(count))
        measured[count] = best(path)
    ratio = measured[LARGE] / measured[SMALL]
    print(f"{SMALL} written defs typed in {measured[SMALL]:.3f} s, "
          f"{LARGE} in {measured[LARGE]:.3f} s: {ratio:.1f}x the time "
          f"for {LARGE // SMALL}x the defs")
    if ratio > LIMIT:
        print(f"FAIL: past {LIMIT:.0f}x, so typing a def at its definition "
              "costs more for every def before it")
        sys.exit(1)
    print("definition typing: each written def costs its own typing")

    peaks = {}
    for count in (LINES_SMALL, LINES_LARGE):
        path = work / f"reassigned_{count}.iyi"
        path.write_text(reassignments(count))
        peaks[count] = peak_kb(path)
    grown = peaks[LINES_LARGE] / peaks[LINES_SMALL]
    print(f"{LINES_SMALL} assignments to one variable typed in "
          f"{peaks[LINES_SMALL] // 1024} MB, {LINES_LARGE} in "
          f"{peaks[LINES_LARGE] // 1024} MB: {grown:.1f}x the memory for "
          f"{LINES_LARGE // LINES_SMALL}x the lines")
    if grown > MEMORY_LIMIT:
        print(f"FAIL: past {MEMORY_LIMIT:.0f}x, so each assignment's merge "
              "costs every value the variable had before it")
        sys.exit(1)
    print("reassignment typing: each assignment costs its own merge")

    unions = {}
    for count in (CLASSES_SMALL, CLASSES_LARGE):
        path = work / f"union_{count}.iyi"
        path.write_text(wide_union(count))
        unions[count] = best(path)
    widened = unions[CLASSES_LARGE] / unions[CLASSES_SMALL]
    print(f"a union of {CLASSES_SMALL} classes typed in "
          f"{unions[CLASSES_SMALL]:.3f} s, of {CLASSES_LARGE} in "
          f"{unions[CLASSES_LARGE]:.3f} s: {widened:.1f}x the time for "
          f"{CLASSES_LARGE // CLASSES_SMALL}x the members")
    if widened > LIMIT:
        print(f"FAIL: past {LIMIT:.0f}x, so each member a union gains is "
              "compared with every member it had")
        sys.exit(1)
    print("union typing: each member costs its own place")


if __name__ == "__main__":
    main()
