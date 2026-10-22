#!/usr/bin/env python3
"""Seconds each std sibling took, read from the logs of std_siblings.sh shards.

    python3 bench/sibling_times.py LOG...                 # sibling x platform
    python3 bench/sibling_times.py --sections std_http LOG...
    python3 bench/sibling_times.py --predict 4 LOG...     # shard totals, interleaved and planned

LOG is a GitHub Actions job log, every line led by its timestamp (the
"Download log" of a job, or `gh run view --log --job`). The platform is read
from the runner's "Operating System" group, the shard from the summary line
std_siblings.sh ends with. A sibling runs from its `-- running sibling:` line
to the memory line printed when it ends (or to the next sibling, or to the
shard's summary, where no memory was traced); a section from its `== ` line
to the next section's or the sibling's end.

--predict adds the measured seconds up per shard twice: as the shards were
dealt before the weights (by sorted place, interleaved) and as
`bash bench/std_siblings.sh --plan N` deals them now. A sibling not measured
on a platform counts as nothing there.
"""
import os
import re
import subprocess
import sys
from datetime import datetime

STAMP = re.compile(r"^\ufeff?(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z ?(.*)$")
PLATFORMS = ("Ubuntu", "macOS", "Windows")


def stamp(text):
    # Seven fractional digits; datetime takes six.
    day, frac = text.split(".")
    return datetime.fromisoformat(f"{day}.{frac[:6]}").timestamp()


def read_log(path):
    """(platform, {sibling: (seconds, [(section, seconds)])})"""
    platform = None
    sibling_runs = {}
    current = None  # [name, start, sections]
    section = None  # [title, start]
    os_next = False

    def close_section(at):
        nonlocal section
        if current and section:
            current[2].append((section[0], at - section[1]))
        section = None

    def close_sibling(at):
        nonlocal current
        close_section(at)
        if current:
            sibling_runs[current[0]] = (at - current[1], current[2])
        current = None

    with open(path, encoding="utf-8", errors="replace") as log:
        for raw in log:
            m = STAMP.match(raw.rstrip("\n"))
            if not m:
                continue
            at, text = stamp(m.group(1)), m.group(2)
            if os_next:
                os_next = False
                for p in PLATFORMS:
                    if text.startswith(p) or (p == "Windows" and "Windows" in text):
                        platform = p
            if text.endswith("##[group]Operating System"):
                os_next = True
                continue
            if text.startswith("-- running sibling: "):
                close_sibling(at)
                name = text[len("-- running sibling: "):].strip()
                current = [name.removesuffix(".sh").removesuffix("_exercise"), at, []]
            elif current and text.startswith("   memory: "):
                close_sibling(at)
            elif text.startswith("== shard "):
                close_sibling(at)
            elif current and text.startswith("== "):
                close_section(at)
                section = [text[3:], at]
    return platform, sibling_runs


def siblings_sorted(repo):
    names = sorted(
        f for f in os.listdir(os.path.join(repo, "bench"))
        if f.startswith("std_") and f.endswith("_exercise.sh") and f != "std_exercise.sh"
    )
    return [n.removesuffix(".sh").removesuffix("_exercise") for n in names]


def plan(repo, shards):
    out = subprocess.run(
        ["bash", os.path.join(repo, "bench", "std_siblings.sh"), "--plan", str(shards)],
        check=True, capture_output=True, text=True,
    ).stdout
    dealt = {}
    for line in out.splitlines():
        m = re.match(r"^(\d+) (\d+) (\S+)$", line)
        if m:
            dealt[m.group(3).removesuffix("_exercise")] = int(m.group(1))
    return dealt


def main(argv):
    mode, arg = None, None
    if argv and argv[0] in ("--sections", "--predict"):
        mode, arg, argv = argv[0], argv[1], argv[2:]
    if not argv:
        print(__doc__.strip().splitlines()[2])
        return 2
    times = {p: {} for p in PLATFORMS}
    for path in argv:
        platform, runs = read_log(path)
        if platform is None:
            print(f"{path}: no Operating System group, skipped", file=sys.stderr)
            continue
        times[platform].update(runs)
    seen = [p for p in PLATFORMS if times[p]]

    if mode == "--sections":
        for p in seen:
            if arg not in times[p]:
                continue
            total, sections = times[p][arg]
            print(f"# {arg} on {p}: {total:.0f} s")
            for title, secs in sections:
                print(f"{secs:8.1f}  {title}")
        return 0

    if mode == "--predict":
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        n = int(arg)
        everyone = siblings_sorted(repo)
        before = {name: i % n + 1 for i, name in enumerate(everyone)}
        after = plan(repo, n)
        for p in seen:
            for label, dealt in (("interleaved", before), ("weighted", after)):
                sums = [0.0] * n
                for name, k in dealt.items():
                    sums[k - 1] += times[p].get(name, (0, None))[0]
                cells = "  ".join(f"{s:6.0f}" for s in sums)
                print(f"{p:8} {label:12} {cells}   max {max(sums):5.0f} s")
        return 0

    names = sorted({n for p in seen for n in times[p]}, key=lambda n: -max(times[p].get(n, (0,))[0] for p in seen))
    print("sibling".ljust(16) + "".join(p.rjust(9) for p in seen))
    for name in names:
        cells = "".join(
            (f"{times[p][name][0]:9.0f}" if name in times[p] else "        -") for p in seen
        )
        print(name.ljust(16) + cells)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
