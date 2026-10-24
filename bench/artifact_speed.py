#!/usr/bin/env python3
"""What reading a module from its `.iyimod` costs, against reading its source.

SPEC.md IV.1a asked this before the artifact existed and answered it with the
fork probe, which is a ceiling rather than a measurement of the thing. This is
the thing: the same program, built from four modules' source and then from four
modules' artifacts with every one of those sources deleted.

Run it after `make crystal` — ideally after `make crystal release=1`, since a
debug compiler is about 1.5x here and both columns pay it.

    python3 bench/artifact_speed.py

What it does not measure is whether the two builds produce the same program;
`spec/compiler/iyimod_spec.cr` and the samples do that, and a speed harness
that also checked correctness would be believed about neither.
"""

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
CRYSTAL = ROOT / ".build" / "crystal"
SAMPLES = ROOT / "samples" / "iyi"

# The Kemal port: the largest import graph here, and the only sample whose
# modules are a library rather than an illustration.
PROGRAM = "webapp.iyi"

# The directories `webapp.iyi` imports from, which is what gets deleted so that
# the second column cannot fall back to the source it is supposed to replace.
MODULE_DIRS = ("app", "std", "boot", "kemal")

RUNS = 5


def env_for(cache):
    env = dict(os.environ)
    env["IYI_PATH"] = f"./lib:{ROOT / 'src'}"
    env["IYI_CACHE_DIR"] = str(cache)
    return env


def run(argv, cwd, cache):
    return subprocess.run(
        argv, cwd=str(cwd), env=env_for(cache),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def best(argv, cwd, cache, cold, runs=RUNS):
    """Fastest of `runs`, or None if the build failed.

    The minimum rather than the median, for the reason `build_speed.py` gives:
    a build has a floor and noise only ever adds to it.
    """
    if not cold:
        if not run(argv, cwd, cache):
            return None
    fastest = None
    for _ in range(runs):
        if cold:
            shutil.rmtree(cache, ignore_errors=True)
            cache.mkdir(parents=True, exist_ok=True)
        started = time.monotonic()
        ok = run(argv, cwd, cache)
        taken = time.monotonic() - started
        if not ok:
            return None
        fastest = taken if fastest is None else min(fastest, taken)
    return fastest


def show(value):
    return "    —" if value is None else f"{value:5.3f}"


def main():
    if not CRYSTAL.exists():
        sys.exit(f"no compiler at {CRYSTAL} — run `make crystal` first")

    with tempfile.TemporaryDirectory(prefix="iyi-artifact-speed-") as tmp:
        root = pathlib.Path(tmp)
        source_dir, artifact_dir = root / "from-source", root / "from-artifact"
        shutil.copytree(SAMPLES, source_dir)
        shutil.copytree(SAMPLES, artifact_dir)

        # Written by a build that generates code, because an artifact from a
        # `--no-codegen` build carries declarations and nothing to link, and
        # the consumer would be measured failing rather than building.
        writing = [str(CRYSTAL), "build", "--emit-iyimod", "mods", "-o", "out", PROGRAM]
        if not run(writing, artifact_dir, root / "cache-emit"):
            sys.exit("could not write the artifacts")

        # The half that makes this a measurement rather than a claim.
        for name in MODULE_DIRS:
            shutil.rmtree(artifact_dir / name, ignore_errors=True)

        # `--force`: a warm row is a reused cache, not an output the up-to-date
        # check would find current and not compile at all.
        from_source = [str(CRYSTAL), "build", "--force", "-o", "out", PROGRAM]
        from_artifact = [str(CRYSTAL), "build", "--force", "--use-iyimod", "mods", "-o", "out", PROGRAM]
        front_source = from_source + ["--no-codegen"]
        front_artifact = from_artifact + ["--no-codegen"]

        rows = [
            ("front end (--no-codegen)",
             best(front_source, source_dir, root / "c1", cold=False),
             best(front_artifact, artifact_dir, root / "c2", cold=False)),
            ("cold full build",
             best(from_source, source_dir, root / "c3", cold=True, runs=3),
             best(from_artifact, artifact_dir, root / "c4", cold=True, runs=3)),
            ("warm full build",
             best(from_source, source_dir, root / "c5", cold=False),
             best(from_artifact, artifact_dir, root / "c6", cold=False)),
        ]

    print()
    print(f"what the artifact buys — {PROGRAM}, best of {RUNS} runs, seconds")
    print()
    print("  stage                       from source   from artifacts")
    print("  " + "-" * 58)
    for label, left, right in rows:
        print(f"  {label:<26}      {show(left)}          {show(right)}")
    print()
    print("  The modules' source is deleted before the right-hand column runs,")
    print("  so it cannot fall back to what it is replacing. An artifact is")
    print("  declarations in text: the consumer parses them and runs the")
    print("  top-level pass over them, which is what it did to the source.")
    print("  See SPEC.md IV.1a.")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
