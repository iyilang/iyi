#!/usr/bin/env python3
"""Build speed — the number SPEC.md's 0.1.0 section exists to produce.

    python3 bench/build_speed.py

The claim iyi is built around is compile speed against Go, and it is the one
claim the project had no committed harness for. This is that harness, and it is
also the release gate: it exits non-zero while the front-end target is unmet,
so "0.1.0 is ready" is a command that passes rather than a judgement.

What is measured
----------------

* **front end** — `crystal build --no-codegen`. Parse and semantic analysis,
  no LLVM. This is the number `.iyimod` (Part IV) and prelude-skipping passes
  (IV.1d) move, and the one the target is set on.
* **end to end** — `crystal build`. Reported even though LLVM and the linker
  dominate it, so the claim cannot quietly become a front-end-only claim.
* **go build** — the same program in Go, timed here rather than quoted. This
  document is not entitled to a Go number it did not measure.

Cold and warm mean an empty and a reused compiler cache. Both compilers are
pointed at a temporary cache directory, so neither the user's `~/.cache/crystal`
nor their `GOCACHE` is touched or warmed by this.

Each figure is the **best** of N runs, not the mean: build time has a floor and
noise only ever adds, so the minimum is the better estimate of the floor. The
figure the target is decided on takes `GATE_RUNS` of them, because three did not
reach that floor reliably, and the slowest is printed beside it so that a busy
machine is visible rather than averaged in.

Limits, stated because they bound the result
--------------------------------------------

* **The compiler is timed as a binary**, not through `bin/crystal`. See the
  comment on `CRYSTAL` below for why, and subtract nothing: the earlier runs
  recorded in SPEC.md were timed through the wrapper and carry its 30 ms.
* **The compiler has to be a release build, and this says so.** The compiler is
  itself a Crystal program, and a debug build of it is **1.5x** slower here —
  measured by alternating the two binaries so the machine's state cancels, 7
  rounds, 0.104 s against 0.068 s. That is an order of magnitude more than the
  margin the target is decided by. The gate used to depend on how
  `.build/crystal` happened to have been built, which is a fact nobody wrote
  down and the report did not carry: the same command, in the same checkout, on
  the same day, said MET or NOT MET. It now asks the compiler how it was built,
  prints the answer, and refuses to decide the target from a debug build rather
  than blaming the compiler for it.
* **The machine's state moves this more than anything the compiler does, and
  it is not fully solved here.** On one binary, minutes apart, the front end
  measured 0.048 s, 0.109 s and 0.061 s. Part of that was three samples being
  too few — fifteen put the floor at 0.048, 0.042 and 0.045 s across three
  sessions — so the gated figure now takes `GATE_RUNS` samples after two
  discarded warm-up runs, and prints the slowest beside the fastest.

  What remains after that is a pattern worth writing down rather than
  averaging: **the first invocation after the machine has been idle reads about
  40% high**, and the ones a minute later do not, with every sample in that
  first invocation slow rather than a few of them. Neither probe here isolates
  it — a fixed integer loop held to 4% across the same swing, and startup moves
  with it only partly. So the honest reading of a single run is that a MET is
  worth more than a NOT MET, and a NOT MET on a machine that has been asleep is
  worth running again.
* **The corpus is one program.** `hello` is the only pair where "the equivalent
  Go program" is unambiguous, and iyi has no larger program to offer: its
  samples explain rules rather than do work. `webapp.iyi` is timed too, but
  for iyi alone — its Kemal-shaped router against Go's `net/http` would compare
  three small files with a large precompiled stdlib package, which is not a
  like-for-like build.
* A `hello` comparison measures the fixed cost of a build and nothing about how
  either compiler scales. That is deliberate: IV.1d found user code stays nearly
  free until a program is large, so the fixed cost *is* what small frequent
  builds pay, and it is where build-speed complaints come from.
* Wall clock on one machine. Nothing here is portable between machines; the
  point is the ratio in one column against another, measured together.
"""

import os
import pathlib
import re
import shutil
import sys as _sys
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent

# The compiler binary, not `bin/crystal`.
#
# `bin/crystal` is development scaffolding: a POSIX-sh script that resolves
# symlinks with recursive shell functions, shells out to `uname` and `readlink`,
# warns which compiler it found, and then `exec`s this binary. It costs **30 ms**
# — half of what the front end costs now — and no released compiler would ship
# it. `go build` is timed as a bare binary, so timing iyi through a shell
# wrapper measures this repository's ergonomics against Go's compiler.
#
# It was worth timing while the front end cost 1.3 s and the wrapper was 2% of
# it. At 0.03 s it is not.
CRYSTAL = ROOT / ".build" / "crystal"
# iyi: asked for paths, so it has to be the surface that knows them by the
# names below. `crystal env IYI_PATH` is not an error — the two command
# surfaces answer in their own vocabularies by design, so it prints an empty
# line and exits 0, which is the shape that made this bench build nothing at
# all for as long as it pointed here.
WRAPPER = ROOT / "bin" / "iyi"

# iyi: the front end as its own binary, when `make crystal-front` has built one.
#
# It is the same analysis without the code generator linked, so the row it adds
# is what the target's figure looks like once the 0.026 s of libLLVM
# initialisers is not in it. Timed rather than argued about.
FRONT = ROOT / ".build" / "crystal-front"

# SPEC.md 0.1.0, "Done is a number": IV.1a already ran a front end that never
# walks the prelude at 0.049 s and emitted an object with an identical symbol
# table. The target is to make that configuration the ordinary one.
FRONT_END_TARGET = 0.05

RUNS = 3

# The second pair, generated rather than written: see
# `bench/build_speed/generate_pair.py` for why, and for what it emits. 300
# types is about 6,900 lines of iyi and 6,000 of Go — enough that user code is
# the bill rather than the fixed costs, which is the thing `hello` cannot say.
MEDIUM_TYPES = 300

_sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "build_speed"))
import generate_pair  # noqa: E402

# Runs for the one figure the target is decided on.
#
# Three was too few, and the way that showed is the point: three consecutive
# runs of this bench measured 0.062 s, 0.074 s and 0.046 s — across the target,
# on one binary, minutes apart. Fifteen runs put the floor at 0.048, 0.042 and
# 0.045 s in three sessions, while their medians ranged 0.048 to 0.070 and
# their slowest reached 0.084. So the floor is reproducible and everything
# above it is noise that more samples find their way under, which is what
# best-of-N assumes and what three samples did not deliver.
#
# It costs about a second. The other rows keep `RUNS`, because nothing is
# decided on them.
GATE_RUNS = 15

# What starting the compiler costs, and what it cost when the target was set.
#
# A figure in seconds is a claim about a machine, and this one measured 0.048 s
# and 0.109 s on the same binary within an hour. Repeating the run does not fix
# that: best-of-N finds the floor, and it is the floor that moves.
#
# The reference this bench divides by is **the compiler starting up and doing
# nothing** — `crystal --version`: the same binary, the same loader, the same
# runtime, none of the compiling. A fixed integer loop was tried first and
# rejected on measurement: it held to within 4% across the period that moved
# the compiler by 2x, so it is not a probe for whatever is moving.
#
# Startup is not a complete probe either, and the report prints both numbers
# rather than implying it is. What it does buy is a term worth knowing on its
# own, and it is the larger one: **starting the compiler and doing nothing
# costs 0.029 s here against a 0.042 s front end**, and 0.026 s of that is
# linking libLLVM. Measured with a C program that does nothing: 0.001 s built
# plainly, 0.026 s built with a `NEEDED` entry on libLLVM and no call to it.
# So it is the library's own load-time initialisers, paid by every process that
# links it whether or not it generates code — `clang --version` pays the same
# 0.023 s. See SPEC.md 0.1.0.
#
# Re-record `STARTUP_BASELINE` when the machine changes **or the binary does**,
# from the figure this prints. It is a property of a machine and a binary, not
# of iyi, and a stale one is worse than none: it silently switches the guard
# below off.
#
# That is not hypothetical. This sat at 0.040 s, recorded when the compiler
# still carried the interpreter, the playground and the documentation
# generator. Today's binary starts in 0.018 s, so every run divided by a
# reference nearly twice its own size, reported "0.71x — faster than the
# machine the target was set on", and went on to decide. Two runs on a
# machine that was busy compiling something else then reported **NOT MET at
# 0.063 s** against a 0.050 s target. The same bench on the same binary an
# hour later, with nothing else running, measured **0.037 s and MET**. The
# guard existed for exactly that run and could not fire.
#
# Recorded 2026-08-16: release compiler 68e24da0a, machine idle, on mains.
STARTUP_BASELINE = 0.018
STARTUP_ROUNDS = GATE_RUNS

# How much slower than the baseline this machine may start the compiler before
# the target stops meaning anything. The target is decided by a few percent, so
# this is already generous.
SLOW = 1.15


def compiler_env():
    """The environment `bin/crystal` would have set, asked for once.

    The wrapper is what knows where this checkout's sources and its `libgc`
    are. Asking it once and passing the answer to the binary is the same build
    the wrapper would have run, without paying for the shell on every one.
    """
    result = subprocess.run(
        [str(WRAPPER), "env", "IYI_PATH", "IYI_LIBRARY_PATH"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    lines = result.stdout.decode().split() if result.returncode == 0 else []

    # An exit status is not the check. `env` prints an empty line for a name it
    # does not know and exits 0, so asking the wrong surface answered "" twice
    # and this returned `{}` — leaving the compiler with no search path at all
    # and every row of the report a dash. The compiler said `can't find file
    # 'iyi/prelude'` on every run and the bench went on printing a table.
    #
    # So the answer is checked rather than the status, and a bench that cannot
    # find the path says which one it wanted rather than measuring nothing.
    if not lines or not lines[0]:
        fallback = f"lib:{ROOT / 'src'}"
        print(f"  note: {WRAPPER.name} did not answer IYI_PATH; using {fallback}",
              file=sys.stderr)
        return {"IYI_PATH": fallback}

    env = {"IYI_PATH": lines[0]}
    if len(lines) > 1 and lines[1]:
        env["IYI_LIBRARY_PATH"] = lines[1]
    return env


CRYSTAL_ENV = {}


def time_startup():
    """The compiler starting and doing nothing — `--version`.

    The same binary, the same loader, the same runtime, and no compiling: what
    is left is the fixed cost every build here pays before it reads a line.
    """
    return best(STARTUP_ROUNDS, lambda: run([str(CRYSTAL), "--version"]))


def compiler_build():
    """What the compiler says it is: its version line, and whether it is release.

    The compiler already knows — `Crystal::Config.description` prints a line
    saying so when it was not built in release mode — so this asks rather than
    guesses at a binary's size or its build flags. A timing that does not say
    which compiler produced it is not a measurement, and the gate is a command
    that passes rather than a judgement, so the command has to know.
    """
    result = subprocess.run(
        [str(CRYSTAL), "--version"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    text = result.stdout.decode("utf-8", "replace")
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    version = lines[0] if lines else "unknown"
    return version, "not built in release mode" not in text


def best(runs, fn, warmup = 0):
    """Fastest and slowest of `runs`, or None if the command failed.

    The fastest is the figure; the slowest is kept because it is what says
    whether the machine was quiet. A build has a floor and noise only ever
    adds, so the minimum is the better estimate — but a gate that reads NOT MET
    because something else was compiling is the same defect as one that reads
    MET because of how the compiler happened to be built.

    `warmup` runs are made and thrown away first. The first invocation in a
    session measured half again what the ones after it did, and none of that
    difference is the compiler: it is whatever the machine had to fetch before
    it could run one.
    """
    for _ in range(warmup):
        if not fn():
            return None
    times = []
    for _ in range(runs):
        started = time.monotonic()
        ok = fn()
        elapsed = time.monotonic() - started
        if not ok:
            return None
        times.append(elapsed)
    return min(times), max(times)


def run(argv, env=None, cwd=None):
    full = dict(os.environ)
    full.update(env or {})
    result = subprocess.run(
        argv, env=full, cwd=cwd,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr.decode("utf-8", "replace"))
    return result.returncode == 0


def time_crystal(source, out_dir, codegen, cold, runs = RUNS, linker = None):
    """Time one `crystal build`, in a cache directory this bench owns.

    `linker` names an alternative to the one `cc` picks, timed the same way.
    The warm build is mostly the link, so which linker is on the machine moves
    this table more than anything in the compiler does.
    """
    suffix = f"_{linker}" if linker else ""
    cache = out_dir / (("cache_cold" if cold else "cache_warm") + suffix)

    def once():
        if cold and cache.exists():
            shutil.rmtree(cache)
        cache.mkdir(parents=True, exist_ok=True)
        # `--force`: warm means a reused cache, not an output that is already
        # current, which the up-to-date check would answer without compiling.
        argv = [str(CRYSTAL), "build", "--force", "-o", str(out_dir / f"out{suffix}")]
        if not codegen:
            argv.append("--no-codegen")
        if linker:
            argv.append(f"--link-flags=-fuse-ld={linker}")
        argv.append(str(source))
        env = dict(CRYSTAL_ENV)
        env["IYI_CACHE_DIR"] = str(cache)
        return run(argv, env=env)

    if not cold:
        # Warm means the second build onward, so pay for the first here.
        cache.mkdir(parents=True, exist_ok=True)
        once()
    return best(runs, once, warmup=2 if runs > RUNS else 0)


# Alternatives to whatever `cc` links with, fastest-first as they are usually
# reported. Only the ones this machine has are timed: a row for a linker nobody
# has is a claim about somebody else's machine.
LINKERS = ("mold", "lld", "gold")


def available_linkers():
    return [name for name in LINKERS if shutil.which(f"ld.{name}") or shutil.which(name)]


def link_seconds(source, out_dir):
    """What the compiler says the link took, out of a warm build's total.

    Asked of `--stats` rather than subtracted from the rows above, because the
    subtraction would carry every difference between two runs into a figure
    that is supposed to be one stage of one run.
    """
    cache = out_dir / "cache_stats"
    cache.mkdir(parents=True, exist_ok=True)
    argv = [str(CRYSTAL), "build", "--force", "--stats", "-o", str(out_dir / "out_stats"), str(source)]
    env = dict(os.environ)
    env.update(CRYSTAL_ENV)
    env["IYI_CACHE_DIR"] = str(cache)
    subprocess.run(argv, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    result = subprocess.run(argv, env=env, capture_output=True)
    text = (result.stdout + result.stderr).decode("utf-8", "replace")
    total = link = None
    for line in text.splitlines():
        found = re.search(r"(\d\d):(\d\d):(\d\d\.\d+)", line)
        if not found:
            continue
        seconds = int(found.group(1)) * 3600 + int(found.group(2)) * 60 + float(found.group(3))
        total = seconds if total is None else total + seconds
        if "Codegen (linking)" in line:
            link = seconds
    return link, total


def same_program(iyi_source, go_source, out_dir):
    """Whether the generated pair really is one program, asked of the binaries.

    The pair is generated from one loop, so the two files are the same shape by
    construction — but "by construction" is the kind of claim this bench exists
    to replace with a run. Both are built and both are run, and if they print
    different things the rows are dropped rather than reported.
    """
    cache = out_dir / "cache_same"
    cache.mkdir(parents=True, exist_ok=True)
    iyi_binary, go_binary = out_dir / "same_iyi", out_dir / "same_go"

    # False and None are different answers and the caller acts on the
    # difference. False is "do not report these rows": the iyi half did not
    # build, or the two printed different things, and either way there is
    # nothing here worth a number. None is "there is no Go on this machine",
    # which withholds the comparison and nothing else — iyi's own figures at
    # this size are the ones SPEC.md's scale question is about, and refusing to
    # print them because a second toolchain is absent is how a machine without
    # Go came to report nothing at all about the size that matters.
    if not run([str(CRYSTAL), "build", "-o", str(iyi_binary), str(iyi_source)],
               env={**CRYSTAL_ENV, "IYI_CACHE_DIR": str(cache)}):
        return False
    if shutil.which("go") is None:
        return None
    if not run(["go", "build", "-o", str(go_binary), go_source.name],
               env={"GOCACHE": str(out_dir / "gocache_same"), "GOFLAGS": "-mod=mod"},
               cwd=str(go_source.parent)):
        return None

    printed = []
    for binary in (iyi_binary, go_binary):
        result = subprocess.run([str(binary)], capture_output=True)
        if result.returncode != 0:
            return None
        printed.append(result.stdout)
    return printed[0] == printed[1]


def time_link_floor(out_dir):
    """What linking anything at all costs here: one C object, through `cc`.

    The row exists because the link is most of a warm build, and a figure for
    it means nothing without knowing what the machine charges for a link. iyi's
    own link is eleven objects and libgc; if this row is close to it, the time
    is the platform's rather than the compiler's.
    """
    if shutil.which("cc") is None:
        return None
    source = out_dir / "link_floor.c"
    source.write_text('#include <stdio.h>\nint main(void){puts("hi");return 0;}\n')
    obj = out_dir / "link_floor.o"
    if not run(["cc", "-c", str(source), "-o", str(obj)]):
        return None
    return best(RUNS, lambda: run(["cc", str(obj), "-o", str(out_dir / "link_floor")]), warmup=1)


def time_go(source, out_dir, cold):
    if shutil.which("go") is None:
        return None
    cache = out_dir / ("gocache_cold" if cold else "gocache_warm")

    def once():
        if cold and cache.exists():
            shutil.rmtree(cache)
        cache.mkdir(parents=True, exist_ok=True)
        return run(
            ["go", "build", "-o", str(out_dir / "hello_go"), source.name],
            env={"GOCACHE": str(cache), "GOFLAGS": "-mod=mod"},
            cwd=str(source.parent),
        )

    if not cold:
        cache.mkdir(parents=True, exist_ok=True)
        once()
    return best(RUNS, once)


def show(measurement):
    return "     —" if measurement is None else f"{measurement[0]:6.2f}"


def main():
    if not CRYSTAL.exists():
        sys.exit(f"no compiler at {CRYSTAL} — run `make crystal` first")

    CRYSTAL_ENV.update(compiler_env())
    version, release = compiler_build()

    hello_iyi = ROOT / "samples" / "iyi" / "hello.iyi"
    webapp_iyi = ROOT / "samples" / "iyi" / "webapp.iyi"
    hello_go = ROOT / "bench" / "build_speed" / "hello.go"

    with tempfile.TemporaryDirectory(prefix="iyi-build-speed-") as tmp:
        out = pathlib.Path(tmp)

        front_hello = time_crystal(hello_iyi, out, codegen=False, cold=True, runs=GATE_RUNS)
        front_webapp = time_crystal(webapp_iyi, out, codegen=False, cold=True)
        e2e_cold = time_crystal(hello_iyi, out, codegen=True, cold=True)
        e2e_warm = time_crystal(hello_iyi, out, codegen=True, cold=False)
        go_cold = time_go(hello_go, out, cold=True)
        go_warm = time_go(hello_go, out, cold=False)

        front_only = None
        if FRONT.exists():
            front_only = best(GATE_RUNS, lambda: run([str(FRONT), str(hello_iyi)], env=CRYSTAL_ENV), warmup=2)

        # Where the warm build actually goes, and what a different linker does
        # about it. Both are measured here rather than described in SPEC.md,
        # for the reason the Go column is.
        # The pair that has user code in it. Written into the temp directory
        # rather than the repository, because ten thousand generated lines in
        # git are a thing nobody reads and everybody diffs.
        medium_iyi, medium_go = generate_pair.write_pair(out, MEDIUM_TYPES)
        medium_agrees = same_program(medium_iyi, medium_go, out)
        if medium_agrees is not False:
            medium_front = time_crystal(medium_iyi, out, codegen=False, cold=True)
            medium_cold = time_crystal(medium_iyi, out, codegen=True, cold=True)
            medium_warm = time_crystal(medium_iyi, out, codegen=True, cold=False)
            medium_go_cold = time_go(medium_go, out, cold=True)
            medium_go_warm = time_go(medium_go, out, cold=False)
        else:
            medium_front = medium_cold = medium_warm = None
            medium_go_cold = medium_go_warm = None

        link_taken, stats_total = link_seconds(hello_iyi, out)
        link_floor = time_link_floor(out)
        alternatives = [
            (name, time_crystal(hello_iyi, out, codegen=True, cold=False, linker=name))
            for name in available_linkers()
        ]

    # After the builds rather than before them, so it sees the machine in the
    # state they left it in. That errs towards calling the machine slow, which
    # is the direction to err in: it withholds a MET rather than inventing one.
    startup, _ = time_startup()
    factor = startup / STARTUP_BASELINE

    print()
    print("build speed — best of", RUNS, "runs, seconds")
    print()
    print(f"  compiler: {version}, {'release' if release else 'DEBUG'} build")
    print(f"  startup:  {startup:.3f} s doing nothing, against a "
          f"{STARTUP_BASELINE:.3f} s baseline — {factor:.2f}x")
    print()
    print("  program        stage                        cold    warm")
    print("  " + "-" * 56)
    print(f"  hello.iyi      front end (--no-codegen)   {show(front_hello)}       —")
    print(f"  hello.iyi      end to end                 {show(e2e_cold)}  {show(e2e_warm)}")
    print(f"  hello.go       go build                   {show(go_cold)}  {show(go_warm)}")
    print("  " + "-" * 56)
    if medium_agrees is not False:
        lines = f"{MEDIUM_TYPES} types"
        print(f"  medium.iyi     front end (--no-codegen)   {show(medium_front)}       —")
        print(f"  medium.iyi     end to end                 {show(medium_cold)}  {show(medium_warm)}")
        print(f"  medium.go      go build                   {show(medium_go_cold)}  {show(medium_go_warm)}")
        if medium_agrees:
            print(f"                 generated pair, {lines}, verified to print the same")
        else:
            print(f"                 generated pair, {lines}; no Go here, so the two")
            print("                 were not run against each other and only iyi's")
            print("                 half of this block is a measurement")
    elif medium_agrees is False:
        print("  medium.iyi/.go the generated pair printed different things —")
        print("                 not timed, because it is not one program")
    print("  " + "-" * 56)
    print(f"  webapp.iyi     front end (iyi only)       {show(front_webapp)}       —")
    if front_only:
        print("  " + "-" * 56)
        print(f"  hello.iyi      front end, no LLVM linked  {show(front_only)}       —")
    print()

    if link_taken and stats_total:
        # Of the stages the compiler times, which is not the wall clock above:
        # starting the process is not a stage, and it is most of the rest.
        print(f"  of the {stats_total:.3f} s the compiler times in a warm build, the link is "
              f"{link_taken:.3f} s — {link_taken / stats_total * 100:.0f}%")
        if link_floor:
            # Through `cc`, which is what a C program pays and what iyi paid
            # until the compiler started building the link itself. Kept as the
            # comparison it now is rather than the floor it used to be.
            print(f"    linking one C object through cc costs{show(link_floor)} here")
        if alternatives:
            for name, measurement in alternatives:
                print(f"    with -fuse-ld={name:<6}{show(measurement)}  against "
                      f"{show(e2e_warm)} from the linker cc picks")
        else:
            print("    no other linker on this machine to compare against")
        print()

    if go_cold is None:
        print("  go was not found, so there is no head-to-head in this run.")
        print()

    if front_hello is None:
        sys.exit("front end did not build; nothing to check against the target")

    fastest, slowest = front_hello

    print(f"  front-end target (SPEC.md 0.1.0): {FRONT_END_TARGET:.3f} s")
    print(f"  measured:                         {fastest:.3f} s")
    print(f"  slowest of the {GATE_RUNS}:                {slowest:.3f} s")
    # Said out loud, because it is most of the figure above and none of it is
    # analysis: what the front end costs over starting the compiler is the part
    # `.iyimod` and the prelude move.
    print(f"  of which startup:                 {startup:.3f} s, "
          f"leaving {max(fastest - startup, 0.0):.3f} s of front end")

    # Measured, not judged. A debug build of the compiler is about 1.5x slower
    # here than a release one, and the target is decided by a few percent, so
    # the number above says more about how this binary was built than about
    # whether iyi meets its target.
    if not release:
        print()
        print("  UNDECIDED — this compiler was not built in release mode, so what")
        print("  was timed is a debug build of the compiler rather than the")
        print("  compiler. That is about 1.5x on this bench, against a target")
        print("  decided by a few percent. Build it and run this again:")
        print()
        print("    rm -f .build/crystal && make crystal release=1")
        print()
        print("  The `rm` is not decoration. make takes an existing binary for")
        print("  up to date whatever it was built with, so `make crystal")
        print("  release=1` on its own can leave a debug build in place and say")
        print("  nothing about it.")
        print()
        return 1

    # A figure in seconds is a claim about a machine, so a machine measurably
    # slower than the one the target was set on cannot answer for it either
    # way. Reported with what the figure would have been at baseline speed,
    # which is an estimate and is labelled as one.
    if factor > SLOW:
        print()
        print(f"  UNDECIDED — this machine starts the compiler {factor:.2f}x slower than")
        print("  the one the target was recorded on, and startup is most of the")
        print("  figure, so what is above is a measurement of the machine. Rest it")
        print("  and run this again, or re-record the baseline if this is the")
        print("  machine now.")
        print()
        return 1

    if fastest <= FRONT_END_TARGET:
        print("  MET.")
        print()
        return 0

    print(f"  NOT MET — {fastest / FRONT_END_TARGET:.1f}x over.")
    print()
    print("  The prelude is iyi's own now (0.1.0 item 3), which is what took")
    print("  this from 26x over to here. What is left is startup and one pass:")
    print("  the figure above is mostly a process that links LLVM before doing")
    print("  no codegen, and the analysis under it is the top-level pass over a")
    print("  prelude read from source on every build. The later passes are")
    print("  measured and are not it — see SPEC.md 0.1.0 item 2.")
    print()
    return 1


if __name__ == "__main__":
    sys.exit(main())
