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


if __name__ == "__main__":
    main()
