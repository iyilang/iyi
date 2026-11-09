#!/usr/bin/env python3
"""The default-allocator decision, measured before it is made.

The collector's own record says moving the default is "a measurement and a
decision, not a side effect", and this is the measurement. The same program,
iyi's own prelude, three allocators:

  * **default** — the owned collector, triggering itself by allocation
    pressure. It became the default on the strength of this file's own
    table.
  * **-Dgc_none** — the bump pointer: allocate, never free. The fastest
    path, the unbounded one, and the default this file retired.
  * **-Dgc_boehm** — libgc, the collector 0.1.0 shipped and the dependency
    the floor exists to refuse.

Two numbers per cell, because the flip trades them against each other: wall
time (best of five) and peak RSS (worst of the same five, read from the
kernel's own accounting via wait4). A row whose three outputs differ is
refused rather than reported.

    python3 bench/gc_default.py

What the workloads are for. `arithmetic` allocates nothing and is the
control: any spread there is noise or a trigger firing when it should not.
`live set` allocates and keeps everything: a collector pays its marks for
no reclaimed byte, which is its worst honest case. `churn` and `string
churn` allocate and drop: the bump pointer's RSS is the garbage itself,
and a collector's RSS is the live set — this is the case a default that
never frees cannot serve, and the reason the question exists.

Release builds. Run it on an idle machine.
"""

import os
import pathlib
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
IYI = ROOT / "bin" / "iyi"

RUNS = 5

ARMS = {
    "default": [],          # the collector, since the flip this file argued for
    "gc_none": ["-Dgc_none"],   # the bump pointer, the old default
    "gc_boehm": ["-Dgc_boehm"],
}

PROGRAMS = {
    "arithmetic": """
      total = 0_i64
      i = 0
      while i < 60_000_000
        total = total + (i % 7)
        i = i + 1
      end
      puts total
    """,
    "live set": """
      items = [] of Int32
      i = 0
      while i < 8_000_000
        items << i
        i = i + 1
      end
      sum = 0_i64
      index = 0
      while index < items.size
        sum = sum + items[index]
        index = index + 1
      end
      puts sum
    """,
    "churn": """
      # 512 MiB allocated, ~64 bytes live at a time: the case the question
      # exists for. The sum is data dependence, so no pass deletes the loop.
      # The blocks are raw memory, so the program says so (SPEC.md III.13).
      @[Unsafe("the garbage is raw 64-byte blocks, each touched once and dropped")]
      sum = 0_u64
      i = 0
      while i < 8_000_000
        block = Pointer(UInt8).malloc(64_u64)
        block.value = 1_u8
        sum = sum &+ block.address
        i = i + 1
      end
      puts sum & 1023
    """,
    "string churn": """
      # Each pass drops the previous string: live is one string, garbage is
      # all of them.
      text = ""
      i = 0
      while i < 40_000
        text = text + "x"
        i = i + 1
      end
      puts text.size
    """,
}


def build(source: pathlib.Path, output: pathlib.Path, flags: list) -> None:
    command = [str(IYI), "build", "--release", *flags, "-o", str(output), str(source)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"build failed for {output.name}:\n{result.stderr[:800]}")


def run_once(binary: pathlib.Path) -> tuple[float, int, str]:
    """One run: seconds, peak RSS in KiB, and what it printed."""
    read_out, write_out = os.pipe()
    start = time.perf_counter()
    pid = os.posix_spawn(str(binary), [str(binary)], os.environ,
                         file_actions=[(os.POSIX_SPAWN_DUP2, write_out, 1)])
    os.close(write_out)
    chunks = []
    while True:
        piece = os.read(read_out, 65536)
        if not piece:
            break
        chunks.append(piece)
    os.close(read_out)
    _, status, rusage = os.wait4(pid, 0)
    elapsed = time.perf_counter() - start
    if os.waitstatus_to_exitcode(status) != 0:
        raise SystemExit(f"{binary.name} exited {os.waitstatus_to_exitcode(status)}")
    peak = rusage.ru_maxrss  # KiB on Linux, bytes on darwin
    if sys.platform == "darwin":
        peak //= 1024
    return elapsed, peak, b"".join(chunks).decode().strip()


def measure(binary: pathlib.Path) -> tuple[float, int, str]:
    fastest = None
    worst_rss = 0
    answer = None
    for _ in range(RUNS):
        elapsed, peak, out = run_once(binary)
        fastest = elapsed if fastest is None else min(fastest, elapsed)
        worst_rss = max(worst_rss, peak)
        answer = out
    return fastest, worst_rss, answer


def main() -> int:
    if not IYI.exists():
        raise SystemExit("build the compiler first: make iyi release=1")

    print("the same program, iyi's own prelude, three allocators.")
    print("seconds are best of %d, RSS is the worst peak of the same %d, MiB." % (RUNS, RUNS))
    print()
    header = f"{'':24}" + "".join(f"{arm:>20}" for arm in ARMS)
    print(header)

    refused = False
    with tempfile.TemporaryDirectory() as work_dir:
        work = pathlib.Path(work_dir)
        for name, body in PROGRAMS.items():
            source = work / (name.replace(" ", "_") + ".iyi")
            source.write_text("\n".join(line[6:] if line.startswith(" " * 6) else line
                                        for line in body.strip("\n").split("\n")) + "\n")
            cells = []
            answers = set()
            for arm, flags in ARMS.items():
                binary = work / (source.stem + "-" + arm)
                build(source, binary, flags)
                seconds, rss_kib, answer = measure(binary)
                answers.add(answer)
                cells.append(f"{seconds:8.3f}s {rss_kib / 1024.0:7.1f}M")
            if len(answers) != 1:
                print(f"{name:24}  REFUSED: the three arms printed different answers")
                refused = True
                continue
            print(f"{name:24}" + "".join(f"{cell:>20}" for cell in cells))

    print()
    print("the flip's question is the churn rows: the bump pointer's RSS is")
    print("its garbage, a collector's is its live set, and the time column is")
    print("what that costs.")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main())
