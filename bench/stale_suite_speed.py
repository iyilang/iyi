#!/usr/bin/env python3
"""What `iyi test --cached` gives back on a suite, against plain `iyi test`.

    python3 bench/stale_suite_speed.py [--tests 1000] [--compiler PATH] [--audit] [--expect-faster]

The point of stale testing is time back on a large suite, and the census
(`bench/stale_census.sh`) cannot say whether it gives any: it times one test
at a time, six small programs. This writes an application with many test
files, and times the whole suite both ways through the edits a day of work
is made of:

  record      the first run: plain, and `--fresh`, which records receipts
  unchanged   nothing edited since
  leaf        one test file edited
  module      one library module edited, which some tests import
  unreached   a shared file edited in a def no test reaches
  reached     a shared file edited in a def every test reaches

For each it prints the wall time of `iyi test` and of `iyi test --cached`,
how many tests the cached run served from receipts, and how many it should
have: a run that serves a test it should have rerun is wrong, and one that
reruns what it could have served is slow, and both are counted.

The application is `--tests` test files at its root, a tenth as many
library modules under `mods/`, each imported by about twenty tests in a
thousand, and one module under `shared/` that every test imports. A test
does arithmetic in a loop and reads no clock, file or environment, so every
one of them is reusable. Seven in ten end at once, two in ten take about
`--medium` seconds and one in ten about `--slow`, by loop counts measured on
this machine before the suite is written (`--iterations` fixes them).

It also says, per test, whether the cached check cost more than running the
test would have: the input to deciding which tests are worth checking at
all.

A tool, not a gate: it prints seconds, and a shared runner's seconds are
weather. Exits non-zero if a run failed or served a wrong number of tests.
`--audit` sets IYI_STALE_FAST_AUDIT=1 on the cached runs, so every fast serve
is also checked against the compiler's own answer. `--expect-faster` also
requires the unchanged cached run to start no compiler and to be quicker than
plain. The `builds` column counts the compiler processes a cached run started,
and `reasons` counts the tests whose check gave a reason; a dash means the
compiler does not report it yet.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCENARIOS = ["record", "unchanged", "leaf", "module", "unreached", "reached"]
MODULUS = 1000003


def module_source(index, step):
    name = f"m{index:04d}"
    return f"""module mods/{name}

pub def work_{name}(n : Int64, seed : Int64) : Int64
  acc = seed
  i = 0_i64
  while i < n
    acc = (acc * 31_i64 + i + {step}_i64) % {MODULUS}_i64
    i = i + 1_i64
  end
  acc
end
"""


def shared_source(reached_step, unreached_step):
    return f"""module shared/core

pub def common(x : Int64) : Int64
  (x + {reached_step}_i64) % {MODULUS}_i64
end

pub def unused(x : Int64) : Int64
  (x * {unreached_step}_i64) % {MODULUS}_i64
end
"""


def test_source(index, modules, iterations, seed):
    first, second = modules
    a, b = f"m{first:04d}", f"m{second:04d}"
    return f"""module main

import shared/core::{{common}}
import mods/{a}::{{work_{a}}}
import mods/{b}::{{work_{b}}}

first = work_{a}({iterations}_i64, {seed}_i64)
second = work_{b}(1000_i64, first)
answer = common(first + second)
assert_eq true, answer >= 0_i64 && answer < {MODULUS}_i64, "t{index:05d} stays in range"
"""


class Suite:
    def __init__(self, root, tests, modules, iterations):
        self.root = root
        self.tests = tests
        self.modules = modules
        self.iterations = iterations
        self.module_steps = [5] * modules
        self.reached_step = 1
        self.unreached_step = 3
        self.seeds = [17 + index for index in range(tests)]

    def tier(self, index):
        slot = index % 10
        return 2 if slot == 9 else 1 if slot >= 7 else 0

    def imports(self, index):
        first = index % self.modules
        second = (index * 7 + 3) % self.modules
        if second == first:
            second = (second + 1) % self.modules
        return first, second

    def test_name(self, index):
        return f"t{index:05d}_test.iyi"

    def write_module(self, index):
        self.put(os.path.join("mods", f"m{index:04d}.iyi"), module_source(index, self.module_steps[index]))

    def write_shared(self):
        self.put(os.path.join("shared", "core.iyi"), shared_source(self.reached_step, self.unreached_step))

    def write_test(self, index):
        self.put(self.test_name(index),
                 test_source(index, self.imports(index), self.iterations[self.tier(index)], self.seeds[index]))

    def put(self, relative, text):
        path = os.path.join(self.root, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    def write_all(self):
        self.write_shared()
        for index in range(self.modules):
            self.write_module(index)
        for index in range(self.tests):
            self.write_test(index)

    def importers(self, module):
        return [index for index in range(self.tests) if module in self.imports(index)]


def run(compiler, args, cwd, env, timeout=None):
    started = time.time()
    done = subprocess.run([compiler, *args], cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    return time.time() - started, done


def suite_run(compiler, mode, cwd, env):
    """One whole-suite run. *mode* is "plain", "fresh" or "cached"."""
    flags = {"plain": [], "fresh": ["--fresh"], "cached": ["--cached"]}[mode]
    wall, done = run(compiler, ["test", *flags, "--json", "."], cwd, env)
    text = done.stdout
    try:
        data = json.loads(text[text.index("{"):])
    except ValueError:
        return {"wall": wall, "exit": done.returncode, "error": (done.stdout + done.stderr)[-600:]}
    tests = data.get("tests", [])
    return {
        "wall": wall,
        "exit": done.returncode,
        "passed": data.get("passed", 0),
        "failed": data.get("failed", 0),
        "served": sum(1 for test in tests if test.get("cached")),
        # The compiler processes this run started, from the JSON's `builds`.
        # None from a compiler that does not report it yet, which the table shows as a dash.
        "builds": data.get("builds"),
        # Tests whose check gave a reason. A check served from the recorded inputs
        # gives none, so this counts the checks that ran the compiler.
        "check_reasons": sum(1 for test in tests if test.get("check_reason")),
        "seconds": {os.path.basename(test["file"]): test.get("seconds", 0.0) for test in tests},
        # With what the test printed: "does not build" under a loaded machine
        # is a finding about the runner, and the status alone cannot say which.
        "not_passing": [os.path.basename(test["file"]) + ": " + str(test.get("status"))
                        + " | " + str(test.get("output", ""))[-400:]
                        for test in tests if test.get("status") != "pass"][:5],
    }


def calibrate(compiler, work, env, targets):
    """Loop counts for the tiers, from how fast this machine runs the loop."""
    probe = Suite(os.path.join(work, "probe"), 1, 1, [20_000_000, 0, 0])
    probe.write_shared()
    probe.write_module(0)
    probe.put("probe.iyi", test_source(0, (0, 0), 20_000_000, 17).replace(
        "import mods/m0000::{work_m0000}\nimport mods/m0000::{work_m0000}\n", "import mods/m0000::{work_m0000}\n"))
    binary = os.path.join(probe.root, "probe-bin" + (".exe" if os.name == "nt" else ""))
    _, built = run(compiler, ["build", "-o", binary, "probe.iyi"], probe.root, env, timeout=600)
    if built.returncode != 0:
        sys.exit("the calibration program does not build:\n" + (built.stdout + built.stderr)[-800:])
    best = min(run(binary, [], probe.root, env, timeout=600)[0] for _ in range(3))
    per_second = 20_000_000 / max(best, 1e-3)
    return [0] + [int(per_second * target) for target in targets], per_second


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--tests", type=int, default=1000)
    parser.add_argument("--modules", type=int, default=0, help="library modules; a tenth of --tests unless given")
    parser.add_argument("--compiler", default=os.environ.get("IYI") or
                        os.path.join(REPO, ".build", "iyi.exe") if os.name == "nt"
                        else os.environ.get("IYI") or os.path.join(REPO, "bin", "iyi"))
    parser.add_argument("--work", default="", help="where to write the suite; a temporary directory unless given")
    parser.add_argument("--scenarios", default=",".join(SCENARIOS))
    parser.add_argument("--medium", type=float, default=0.1, help="seconds a medium test's loop should take")
    parser.add_argument("--slow", type=float, default=1.0, help="seconds a slow test's loop should take")
    parser.add_argument("--iterations", default="", help="MEDIUM,SLOW loop counts, instead of measuring them")
    parser.add_argument("--json", default="", help="write every number to this file")
    parser.add_argument("--keep", action="store_true", help="leave the suite and its cache where they are")
    parser.add_argument("--audit", action="store_true",
                        help="set IYI_STALE_FAST_AUDIT=1 on cached runs: each fast serve must agree with the compiler check")
    parser.add_argument("--expect-faster", action="store_true",
                        help="exit 1 unless the unchanged cached run starts no compiler and is quicker than plain")
    args = parser.parse_args()

    wanted = [name for name in args.scenarios.split(",") if name]
    unknown = [name for name in wanted if name not in SCENARIOS]
    if unknown:
        sys.exit("no such scenario: " + ", ".join(unknown) + " (there are " + ", ".join(SCENARIOS) + ")")
    compiler = os.path.abspath(args.compiler)
    if not os.path.exists(compiler):
        sys.exit(f"no compiler at {compiler}; build one or pass --compiler")
    modules = args.modules or max(2, args.tests // 10)

    work = os.path.abspath(args.work) if args.work else tempfile.mkdtemp(prefix="iyi-suite-speed.")
    os.makedirs(work, exist_ok=True)
    scratch = os.path.join(work, "tmp")
    os.makedirs(scratch, exist_ok=True)
    env = dict(os.environ, IYI_CACHE_DIR=os.path.join(work, "cache"), TMPDIR=scratch, TMP=scratch, TEMP=scratch)

    if args.iterations:
        medium, slow = (int(count) for count in args.iterations.split(","))
        iterations, per_second = [0, medium, slow], None
    else:
        iterations, per_second = calibrate(compiler, work, env, [args.medium, args.slow])

    suite = Suite(os.path.join(work, "app"), args.tests, modules, iterations)
    suite.write_all()
    counts = [sum(1 for index in range(args.tests) if suite.tier(index) == tier) for tier in range(3)]
    print(f"{args.tests} tests, {modules} modules, in {suite.root}")
    print(f"  loop counts: {counts[0]} tests at 0, {counts[1]} at {iterations[1]:,}, {counts[2]} at {iterations[2]:,}"
          + (f" ({per_second / 1e6:.0f} million iterations a second here)" if per_second else ""))
    load = os.getloadavg()[0] if hasattr(os, "getloadavg") else None
    print(f"  {os.cpu_count()} cores" + (f", load average {load:.0f}" if load is not None else ", load average unavailable"))
    print()

    report = {"tests": args.tests, "modules": modules, "iterations": iterations, "cores": os.cpu_count(),
              "load_average": load, "compiler": compiler, "scenarios": {}}
    wrong = []
    recorded = False
    # --audit checks each fast serve against the compiler's own answer (RG10); plain runs never set it.
    cached_env = dict(env, IYI_STALE_FAST_AUDIT="1") if args.audit else env
    header = f"{'scenario':10s} {'plain':>9s} {'--cached':>9s} {'ratio':>7s} {'served':>7s} {'should':>7s} {'builds':>7s} {'reasons':>8s}  note"
    print(header)

    def edit(name):
        """Applies the scenario's edit and returns how many tests it should rerun."""
        if name == "leaf":
            suite.seeds[0] += 1
            suite.write_test(0)
            return 1
        if name == "module":
            suite.module_steps[0] += 1
            suite.write_module(0)
            return len(suite.importers(0))
        if name == "unreached":
            suite.unreached_step += 1
            suite.write_shared()
            return 0
        if name == "reached":
            suite.reached_step += 1
            suite.write_shared()
            return args.tests
        return 0

    for name in wanted:
        if name == "record":
            plain = suite_run(compiler, "plain", suite.root, env)
            cached = suite_run(compiler, "fresh", suite.root, env)
            should_serve = 0
            recorded = True
        else:
            if not recorded:
                suite_run(compiler, "fresh", suite.root, env)
                recorded = True
            reruns = edit(name)
            should_serve = args.tests - reruns
            plain = suite_run(compiler, "plain", suite.root, env)
            cached = suite_run(compiler, "cached", suite.root, cached_env)

        notes = []
        for label, result in (("plain", plain), ("cached", cached)):
            if "error" in result:
                notes.append(f"{label} gave no report")
                wrong.append(f"{name}: {label} run gave no report: {result['error'][-200:]}")
            elif result["failed"] or result["passed"] != args.tests:
                notes.append(f"{label}: {result['passed']} passed, {result['failed']} failed")
                wrong.append(f"{name}: {label} run passed {result['passed']} of {args.tests}: {result['not_passing']}")
        served = cached.get("served", 0)
        if "error" not in cached and name != "record":
            if served > should_serve:
                notes.append("served a test it should have rerun")
                wrong.append(f"{name}: served {served}, at most {should_serve} are unchanged")
            elif served < should_serve:
                notes.append(f"reran {should_serve - served} it could have served")
        ratio = cached["wall"] / plain["wall"] if plain["wall"] else 0.0
        mode = "--fresh" if name == "record" else "--cached"
        builds = cached.get("builds")
        builds_text = "-" if builds is None else str(builds)
        reasons_text = str(cached["check_reasons"]) if "check_reasons" in cached else "-"
        print(f"{name:10s} {plain['wall']:8.1f}s {cached['wall']:8.1f}s {ratio:6.1f}x {served:7d} {should_serve:7d} "
              f"{builds_text:>7s} {reasons_text:>8s}  " + (f"({mode}) " if name == "record" else "") + "; ".join(notes), flush=True)
        report["scenarios"][name] = {"plain": plain, "cached": cached, "should_serve": should_serve, "mode": mode}
        if args.json:
            with open(args.json, "w", encoding="utf-8") as handle:
                json.dump(report, handle)

    unchanged = report["scenarios"].get("unchanged")
    if unchanged and "seconds" in unchanged["plain"] and "seconds" in unchanged["cached"]:
        print()
        print("per test, nothing changed (seconds: a plain build and run, and a cached check)")
        for tier, label in enumerate(["ends at once", "medium", "slow"]):
            names = [suite.test_name(index) for index in range(args.tests) if suite.tier(index) == tier]
            plain_s = sorted(unchanged["plain"]["seconds"].get(name, 0.0) for name in names)
            check_s = sorted(unchanged["cached"]["seconds"].get(name, 0.0) for name in names)
            if not names:
                continue
            dearer = sum(1 for name in names
                         if unchanged["cached"]["seconds"].get(name, 0.0) > unchanged["plain"]["seconds"].get(name, 0.0))
            print(f"  {label:13s} {len(names):5d} tests: plain median {plain_s[len(plain_s) // 2]:.2f}, "
                  f"check median {check_s[len(check_s) // 2]:.2f}; the check cost more than the run for {dearer}")
        report["per_test_note"] = "both columns are measured with several tests in flight, as many as each run's -p default"
        print("  (both runs keep several tests in flight, so a test's seconds include waiting on the others)")

    if args.expect_faster:
        unchanged = report["scenarios"].get("unchanged")
        if unchanged is None:
            wrong.append("--expect-faster: the unchanged scenario did not run")
        else:
            plain_wall, cached_wall = unchanged["plain"]["wall"], unchanged["cached"]["wall"]
            if not cached_wall < plain_wall:
                wrong.append(f"--expect-faster: unchanged cached run took {cached_wall:.1f}s, plain took {plain_wall:.1f}s")
            if unchanged["cached"].get("builds") != 0:
                wrong.append(f"--expect-faster: unchanged cached run started {unchanged['cached'].get('builds')!r} compiler processes, not 0")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(report, handle)
    if not args.keep and not args.work:
        shutil.rmtree(work, ignore_errors=True)
    if wrong:
        print()
        for line in wrong:
            print("WRONG: " + line)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
