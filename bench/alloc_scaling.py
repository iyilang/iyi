#!/usr/bin/env python3
"""How the allocator scales across a pool's workers, and where its time goes.

    ~/.cache/heavy.sh python3 bench/alloc_scaling.py                # the curve
    ~/.cache/heavy.sh python3 bench/alloc_scaling.py --sample 20    # and stacks
    python3 bench/alloc_scaling.py --traceable CMD ARGS...          # start CMD
    python3 bench/alloc_scaling.py --pid PID --sample 20            # sample it

Builds `bench/alloc_scaling.iyi` (release) and runs it on a pool of 1, 2,
4, 8 and 12 workers, every worker doing the same ROUNDS requests' worth of
small allocations, best of RUNS, so a pool that scales holds the wall time
flat. Prints each row's wall time, requests a second per worker, and that
rate as a share of one worker's - the per-core efficiency, 100% for an
allocator that costs a worker nothing to share - with the collections the
run took, the bytes its arenas ever carved (fresh memory, beside what the
sweep handed back out), and the load average it started under.

`--sample N` stops the program N times with gdb while the widest pool runs
(or the process `--pid` names, a server under wrk say) and reads every
thread's stack: how many were inside the runtime lock (`IyiRuntimeLock`,
spinning, yielding or parked in its spin) and how many inside a class's
lock on the centre (`IyiHeap.class_lock`), each by the allocator function
that took it. perf is closed to unprivileged users on the machine this was
written on (paranoid 4), and Yama's ptrace scope 1 lets gdb attach only to
its own descendants, so a process to be sampled is started through
`--traceable`, which allows any tracer (`PR_SET_PTRACER`) and execs it.

Not a gate, and nothing runs it: the numbers are a machine's and a moment's,
and a shared twelve-thread machine moves them by whatever else is running.
`bench/measured_numbers.py` names it among the figures a shared runner cannot
check. Needs a compiler at bin/iyi; the program is built with `--release`
whatever the compiler was built with.
"""

from __future__ import annotations

import argparse
import collections
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
IYI = ROOT / "bin" / "iyi"

WORKERS = (1, 2, 4, 8, 12)
ROUNDS = 200000
RUNS = 3

# The allocator's functions a lock is taken in, innermost first: a stack
# inside a lock is put down to the first of these below the lock's frame,
# or to the first frame below it that is not the lock's own.
CALLERS = (
    "free_batch", "thread_warm_of", "reopen_pages", "map_arena", "sweep_one", "sweep_for",
    "sweep_one_helper", "sweep_one_before_stop", "refill", "take_large", "free_unswept", "free",
    "first_touch", "retire_cache", "collect_if_due", "collect", "register", "unregister",
)
LOCK_FRAMES = {"lock", "lock_turn", "class_lock", "yield_cpu", "__iyi_conc_syscall3", "park_if_requested", "stop_here", "park"}

# Yama's PR_SET_PTRACER and its "any process" argument (linux/prctl.h).
PR_SET_PTRACER = 0x59616D61
PTRACER_ANY = 0xFFFFFFFFFFFFFFFF


def build(work: pathlib.Path) -> pathlib.Path:
    out = work / "alloc_scaling"
    done = subprocess.run(
        [str(IYI), "build", "--release", "-o", str(out), str(ROOT / "bench/alloc_scaling.iyi")],
        capture_output=True, text=True,
    )
    if done.returncode != 0:
        raise SystemExit(f"bench/alloc_scaling.iyi did not build:\n{done.stdout}{done.stderr}")
    return out


def run(binary: pathlib.Path, workers: int, rounds: int) -> dict:
    process = subprocess.Popen(traceable([str(binary), str(workers), str(rounds)]), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        stdout, stderr = process.communicate(timeout=120)
    except subprocess.TimeoutExpired:
        # A run is a second at most: two minutes is a hang, and its stacks
        # are what says where.
        stacks = subprocess.run(
            ["gdb", "-p", str(process.pid), "-batch", "-nx", "-ex", "set pagination off", "-ex", "thread apply all bt 16"],
            capture_output=True, text=True, timeout=120,
        ).stdout
        process.kill()
        process.communicate()
        raise SystemExit(f"alloc_scaling {workers} {rounds} hung; its threads:\n{stacks}")
    found = re.search(r"wall_us=(\d+) collections=(\d+) carved_kb=(\d+)", stdout)
    if process.returncode != 0 or found is None:
        raise SystemExit(f"alloc_scaling {workers} {rounds} failed:\n{stdout}{stderr}")
    return {"wall": int(found.group(1)) / 1e6, "collections": int(found.group(2)), "carved": int(found.group(3)) / 1024}


def frame(line: str) -> tuple[str, str]:
    """A backtrace line's function and file: `#4  0x5810 in lock () at /x/prelude.iyi:91`."""
    found = re.match(r"#\d+\s+(?:0x[0-9a-f]+ in )?(\S+) \(.*?\)(?: at (\S+?):\d+)?", line)
    return (found.group(1), pathlib.Path(found.group(2) or "").name) if found else ("", "")


def classify(frames: list[tuple[str, str]]) -> str | None:
    """Which lock a thread's stack is inside, and taken by whom; None for neither.

    The runtime lock is `IyiRuntimeLock.lock` and its spin's `lock_turn`, which
    a release build's frames name `lock` and `lock_turn` in prelude.iyi and
    thread.iyi; a class's lock is `IyiHeap.class_lock`.
    """
    for depth, (name, where) in enumerate(frames):
        if name == "class_lock" or (name in ("lock", "lock_turn") and where in ("prelude.iyi", "thread.iyi")):
            lock = "class lock" if name == "class_lock" else "runtime lock"
            for below, _ in frames[depth + 1:]:
                if below in CALLERS:
                    return f"{lock} <- {below}"
            other = next((below for below, _ in frames[depth + 1:] if below not in LOCK_FRAMES), "?")
            return f"{lock} <- {other}"
    return None


def sample(pid: int, stops: int, gap: float) -> tuple[int, int, collections.Counter]:
    """`stops` gdb stops of `pid`, every thread's stack read: the stacks seen,
    those on a task's fiber (`__iyi_fiber_main`), and where the locked ones were."""
    seen = 0
    tasks = 0
    where: collections.Counter = collections.Counter()
    for _ in range(stops):
        done = subprocess.run(
            ["gdb", "-p", str(pid), "-batch", "-nx", "-ex", "set pagination off", "-ex", "thread apply all bt 40"],
            capture_output=True, text=True, timeout=120,
        )
        for block in re.split(r"\n(?=Thread \d+ )", done.stdout):
            if not block.startswith("Thread "):
                continue
            frames = [frame(line) for line in block.splitlines() if line.startswith("#")]
            if not frames:
                continue
            seen += 1
            tasks += any(name == "__iyi_fiber_main" for name, _ in frames)
            answer = classify(frames)
            if answer is not None:
                where[answer] += 1
        time.sleep(gap)
    return seen, tasks, where


def report(seen: int, tasks: int, where: collections.Counter, stops: int) -> None:
    inside = sum(where.values())
    print(f"\n{stops} gdb stops, {seen} thread stacks, {tasks} on a task's fiber, {inside} inside a lock:")
    for name, count in where.most_common():
        print(f"  {count:5d}  {name}")


def traceable(command: list[str]) -> list[str]:
    """`command` prefixed so that it starts traceable by any process (`--traceable`)."""
    return [sys.executable, str(pathlib.Path(__file__).resolve()), "--traceable", *command]


def main() -> int:
    if len(sys.argv) > 2 and sys.argv[1] == "--traceable":
        import ctypes

        ctypes.CDLL(None).prctl(PR_SET_PTRACER, ctypes.c_ulong(PTRACER_ANY), 0, 0, 0)
        os.execv(sys.argv[2], sys.argv[2:])
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--runs", type=int, default=RUNS)
    parser.add_argument("--rounds", type=int, default=ROUNDS)
    parser.add_argument("--workers", default=",".join(str(w) for w in WORKERS))
    parser.add_argument("--sample", type=int, default=0, help="gdb stops while the widest pool runs")
    parser.add_argument("--pid", type=int, help="sample this process instead, and run nothing")
    parser.add_argument("--work", help="build into this directory and keep it")
    options = parser.parse_args()
    if options.pid:
        seen, tasks, where = sample(options.pid, options.sample or 20, 0.25)
        report(seen, tasks, where, options.sample or 20)
        return 0
    if not IYI.exists():
        raise SystemExit("needs a compiler at bin/iyi: make iyi")
    work = pathlib.Path(options.work) if options.work else pathlib.Path(tempfile.mkdtemp(prefix="alloc_scaling."))
    work.mkdir(parents=True, exist_ok=True)
    try:
        binary = build(work)
        widths = [int(w) for w in options.workers.split(",") if w]
        cpu = next((line.split(":", 1)[1].strip() for line in pathlib.Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "?")
        print(f"{os.cpu_count()} hardware threads ({cpu}), {options.rounds} requests a worker, best of {options.runs}")
        print(f"load average before: {pathlib.Path('/proc/loadavg').read_text().split()[0]}")
        print("| workers | wall s | requests/s per worker | per worker, of one's | collections | carved MB |")
        print("|---:|---:|---:|---:|---:|---:|")
        alone = None
        for workers in widths:
            best = min((run(binary, workers, options.rounds) for _ in range(options.runs)), key=lambda r: r["wall"])
            rate = options.rounds / best["wall"]
            alone = alone or rate
            print(f"| {workers} | {best['wall']:.3f} | {rate:,.0f} | {rate / alone:.0%} | {best['collections']} | {best['carved']:.0f} |", flush=True)
        if options.sample:
            widest = max(widths)
            # Long enough for every stop, and killed after the last.
            process = subprocess.Popen(traceable([str(binary), str(widest), str(options.rounds * 1000)]), stdout=subprocess.DEVNULL)
            try:
                time.sleep(0.5)
                seen, tasks, where = sample(process.pid, options.sample, 0.1)
            finally:
                process.kill()
                process.wait()
            print(f"\nat {widest} workers:", end="")
            report(seen, tasks, where, options.sample)
    finally:
        if not options.work:
            shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
