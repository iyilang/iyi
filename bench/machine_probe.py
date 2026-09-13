#!/usr/bin/env python3
"""Three figures that separate "the code got slower" from "the machine did",
under a fingerprint saying whose machine they came from.

Run it twice under the two states worth comparing (on battery and plugged in,
or before and after whatever changed) and read the ratios. The point is which
of the three moves together:

* the loop is pure CPU and nothing else,
* startup is the compiler linking libLLVM and doing no work,
* the front end is the figure the release gate is decided on.

`build_speed.py` divides by startup, and startup is mostly the loader. If the
front end moves and startup does not, the gate is measuring a machine it
cannot see, and it says NOT MET where it means UNDECIDED.

The fingerprint is here because every timing README.md and SPEC.md publish is
quoted with a machine attached, and no script in `bench/` emitted one: the
machine was typed in by hand, and two of the published sets name two different
machines. What a reader needs in order to re-take one of those figures is what
is printed below — CPU and cores, memory, OS and kernel, libc, LLVM, the
compiler's own version line with its commit, the revision of this checkout,
the date, and the command with its arguments. It costs a fraction of a second
and the run stays under three.

Nothing is printed for a build that failed. This probe reported `front end
0.009 s` against a 50 ms target, which is not a fast compiler but a failure
with a stopwatch on it: `timed()` never read `returncode`, and the environment
set `IYI_PATH` for a binary that answers `CRYSTAL_PATH`, so every build in it
died with `can't find file 'iyi/prelude'`. That is the defect CHANGELOG 0.3.0
records under Fixed for `build_speed.py` and again for `incremental.py` — both
of which now check the answer rather than the exit status, because an exit code
cannot see an empty string. This one checks both, and refuses by name instead
of printing a number.
"""
import os
import platform
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The binary `make crystal` writes, which is the one the specs and the rest of
# `bench/` time. This used to be `.build/crystal-release`, a copy taken by hand
# after `make crystal release=1` — and a copy goes stale in silence. The one in
# this tree was three weeks older than `src/iyi` and could not compile it at
# all, so the probe timed a compiler error. Whether the binary is optimised is
# read off its own version line below rather than assumed from a filename: a
# debug front end is about 1.5x, which is worth printing and not worth refusing
# over, since this probe is read as a ratio against its own second run.
CRYSTAL = ROOT / ".build" / "crystal"
HELLO = ROOT / "samples" / "iyi" / "hello.iyi"
SOURCES = ROOT / "src"

# The variable this binary answers. `crystal env IYI_PATH` is not a synonym —
# the two command surfaces answer in their own vocabularies by design — and
# setting a name the binary never reads leaves the build with no search path,
# which is the whole of the defect above.
PATH_VAR = "CRYSTAL_PATH"
ENV = {PATH_VAR: f"lib:{SOURCES}", "PATH": "/usr/bin:/bin"}

LOOP_ROUNDS = 5
RUN_ROUNDS = 7


class Refusal(Exception):
    """A named reason there is no number to print."""


def loop(rounds=LOOP_ROUNDS):
    best = None
    for _ in range(rounds):
        start = time.perf_counter()
        total = 0
        for i in range(3_000_000):
            total += i * i
        best = min(best or 1e9, time.perf_counter() - start)
    return best


def timed(argv, rounds=RUN_ROUNDS):
    """Fastest of `rounds`, or a refusal naming the command that failed.

    The exit code is read every round, because a build that fails fails in a
    fraction of the time one that succeeds takes: an unchecked failure does not
    read here as an error, it reads as a very fast compiler.
    """
    best = None
    for _ in range(rounds):
        start = time.perf_counter()
        result = subprocess.run(
            argv, env=ENV, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        elapsed = time.perf_counter() - start
        if result.returncode != 0:
            raise Refusal(
                f"{shown(argv)} exited {result.returncode} after {elapsed:.3f} s"
                + said(result.stderr))
        best = min(best or 1e9, elapsed)
    return best


def shown(argv):
    """The command as a reader would retype it, with the repo root elided."""
    root = str(ROOT) + os.sep
    return " ".join(part.replace(root, "") for part in argv)


def said(output, keep=6):
    """The first lines of what a failing command printed, indented."""
    lines = [line for line in output.decode("utf-8", "replace").splitlines()
             if line.strip()][:keep]
    return "".join(f"\n    {line}" for line in lines)


def asked(argv):
    """Run `argv` for its answer, in this machine's own environment."""
    result = subprocess.run(
        argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return result.returncode, result.stdout.decode("utf-8", "replace"), result.stderr


def check_search_path():
    """Whether a build in `ENV` can find the prelude at all.

    Two questions, and the first is the one an exit status cannot answer. The
    binary has to name `PATH_VAR` itself, because the surface that does not
    know the variable prints an empty line and exits 0 — that is how the two
    benches this one copies its fix from built nothing for a release. And the
    tree `PATH_VAR` points at has to hold the prelude the build will ask for,
    because a search path that resolves nothing fails the same way.
    """
    prelude = SOURCES / "iyi" / "prelude.iyi"
    if not prelude.exists():
        raise Refusal(f"{shown([str(prelude)])} is missing, so no build here "
                      f"can find 'iyi/prelude'")
    code, answer, errors = asked([str(CRYSTAL), "env", PATH_VAR])
    if code != 0 or not answer.strip():
        raise Refusal(
            f"{shown([str(CRYSTAL)])} does not answer {PATH_VAR}, so setting it "
            f"would leave the build with no search path" + said(errors or answer.encode()))


def compiler():
    """What the compiler says it is: version line with commit, LLVM, target.

    It already knows whether it was built in release mode — the version line
    says so when it was not — so this asks rather than guessing from a size or
    a filename.
    """
    code, text, errors = asked([str(CRYSTAL), "--version"])
    if code != 0:
        raise Refusal(f"{shown([str(CRYSTAL), '--version'])} exited {code}" + said(errors))
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    version = lines[0] if lines else "unknown"
    if "not built in release mode" in text:
        version += ", not built in release mode"
    return version, found(r"^LLVM: *(.+)$", text), found(r"^Default target: *(.+)$", text)


def found(pattern, text, otherwise="unknown"):
    match = re.search(pattern, text, re.MULTILINE)
    return match.group(1).strip() if match else otherwise


def sysctl(name):
    """macOS: the only place the CPU's own name is not in a file."""
    try:
        result = subprocess.run(
            ["sysctl", "-n", name], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return ""
    return result.stdout.decode("utf-8", "replace").strip() if result.returncode == 0 else ""


def cpu():
    model = ""
    info = Path("/proc/cpuinfo")
    if info.exists():
        for line in info.read_text("utf-8", "replace").splitlines():
            if line.startswith(("model name", "Model")):
                model = line.split(":", 1)[1].strip()
                break
    model = model or sysctl("machdep.cpu.brand_string") or platform.processor()
    return f"{model or platform.machine()}, {os.cpu_count()} logical cores"


def memory():
    try:
        total = os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")
    except (AttributeError, OSError, ValueError):
        return "unknown"
    return f"{total / 2 ** 30:.1f} GiB"


def git(*argv):
    try:
        result = subprocess.run(
            ["git", "-C", str(ROOT), *argv],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return ""
    return result.stdout.decode("utf-8", "replace").strip() if result.returncode == 0 else ""


def revision():
    """The commit a figure taken now would belong to, and whether it is clean.

    A number read off a tree with uncommitted changes in it cannot be retaken
    by anyone else, so the fingerprint says that rather than naming a commit
    that does not describe what ran.
    """
    head = git("rev-parse", "--short", "HEAD")
    if not head:
        return "not a git checkout"
    return head + (" + uncommitted changes" if git("status", "--porcelain") else "")


def fingerprint(label):
    """Everything a reader needs to attribute the three timings below."""
    version, llvm, target = compiler()
    script = Path(__file__).resolve()
    command = " ".join(["python3", str(script.relative_to(ROOT)), *sys.argv[1:]])
    return [
        ("label", label),
        ("when", datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %z")),
        ("revision", revision()),
        ("command", command),
        ("compiler", f"{shown([str(CRYSTAL)])}: {version}"),
        ("llvm", llvm),
        ("target", target),
        ("cpu", cpu()),
        ("memory", memory()),
        ("os", f"{platform.system()} {platform.release()} ({platform.machine()})"),
        ("libc", " ".join(part for part in platform.libc_ver() if part) or "unknown"),
    ]


def main():
    label = sys.argv[1] if len(sys.argv) > 1 else "unlabelled"
    if not CRYSTAL.exists():
        print(f"refusing: {CRYSTAL} is missing (make crystal)", file=sys.stderr)
        return 1
    try:
        check_search_path()
        for key, value in fingerprint(label):
            print(f"{key:>16}  {value}")
        cpu_loop = loop()
        startup = timed([str(CRYSTAL), "--version"])
        front = timed([str(CRYSTAL), "build", "--no-codegen", str(HELLO)])
    except Refusal as refusal:
        print(f"refusing: {refusal}", file=sys.stderr)
        return 1
    print(f"{label:>16}  cpu loop {cpu_loop:.3f} s   startup {startup:.3f} s   "
          f"front end {front:.3f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
