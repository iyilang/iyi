#!/usr/bin/env python3
"""The rebuild, measured — and the prediction it corrects.

The naive reading of R-1 says an artifact rebuild should beat a source
rebuild: imports read, not compiled. Measured, it does not — not on the
sample corpus (~1.0x) and not on a 400-type semantic-heavy fixture
(~0.85x): the front end types lazily, so unused import surface is
nearly free to compile, while the artifact arm pays decode and
re-declaration for everything it reads. The wall-time dividend R-1
actually delivers lives elsewhere, and each home is separately gated:
the LSP's per-module verdict (bench/lsp_latency.py), building with the
library's *source deleted* (bench/samples_roundtrip.sh), and the
interface hash that rebuilds nobody on a doc edit (iyimod specs).

What this file gates is what the loop still owes: the edit-rebuild
round trip stays cheap in absolute terms on either arm, and the
artifact read never becomes ruinously slower than the compile it
replaces — a regression band, so decode cost cannot quietly grow.
Arms alternate, an edit precedes every build, minimums are reported.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time

IYI = os.path.abspath(os.environ.get("IYI", "./bin/iyi"))
SAMPLES = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "samples", "iyi"))
# `std` moved out of the samples into the library, so it is copied from there.
# Copying the whole of it does not change what this measures: the entry imports
# `std/list` and the front end types lazily, so the modules nobody imports are
# never compiled. The copy happens before the clock starts either way.
STD = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src", "std"))
ROUNDS = 5

ENTRY = """module main

import calc/lexer::{scan}
import calc/parser
import calc/ast
import kemal/dsl
import kemal/router
import app/greeter::{polite}
import app/formal
import std/list

pub def check(source : String) : String
  tokens = scan(source)
  return "lex error" if tokens.is_a?(Error)
  "ok"
end

puts polite("rebuild")
puts check("1 + 2 * 3")
"""


def run(args, cwd):
    proc = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"build failed: {' '.join(args)}\n{proc.stdout}{proc.stderr}")


def timed_build(cwd, extra, tick):
    # The edit first: an unedited entry lets per-program object caching
    # serve codegen, and then the measurement flatters everybody.
    with open(os.path.join(cwd, "main.iyi"), "a") as f:
        f.write(f"# tick {tick}\n")
    start = time.monotonic()
    run([IYI, "build", "-o", "app"] + extra + ["main.iyi"], cwd)
    return time.monotonic() - start


def main():
    work = tempfile.mkdtemp(prefix="iyi-rebuild-speed")
    for sub in ("calc", "kemal", "app"):
        shutil.copytree(os.path.join(SAMPLES, sub), os.path.join(work, sub))
    shutil.copytree(STD, os.path.join(work, "std"))
    with open(os.path.join(work, "main.iyi"), "w") as f:
        f.write(ENTRY)

    # The artifacts the artifact arm reads, written once — the producer
    # side of R-1, off the clock the way a library build is.
    run([IYI, "build", "--emit-iyimod", "mods", "-o", "app", "main.iyi"], work)

    source, artifact = [], []
    for round_no in range(ROUNDS):
        source.append(timed_build(work, [], f"s{round_no}"))
        artifact.append(timed_build(work, ["--use-iyimod", "mods"], f"a{round_no}"))
    src = min(source)
    art = min(artifact)
    print(f"rebuild after an edit, {ROUNDS} alternating rounds, minimums:")
    print(f"  from source     {src * 1000:7.0f} ms   (eight imports compiled every time)")
    print(f"  from artifacts  {art * 1000:7.0f} ms   (eight imports read, entry compiled)")
    print(f"  ratio           {art / src:7.2f}x  (the honest finding: reading does not beat lazy compiling at this size)")

    if art > src * 1.5:
        sys.exit(f"REGRESSION: the artifact read costs {art / src:.2f}x the compile it replaces (band 1.5x)")
    if src > 2.0 or art > 2.0:
        sys.exit("REGRESSION: an edit-rebuild left the two-second budget")
    print("\nrebuild speed: the loop is cheap on both arms, and the read stays in its band")


if __name__ == "__main__":
    main()
