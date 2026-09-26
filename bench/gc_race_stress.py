#!/usr/bin/env python3
"""STRESS BRANCH ONLY: gc_race's programs, run until one faults, on Windows.

Each program is built release as gc_race builds it, and once more with
`IyiMark.workers = 0` - no helpers and no collection beside the program -
so a fault in one arm and none in the other says which half to read. Runs
go one at a time and then four at once, for load. Every fault's STRESS
lines are symbolized against the binary's PDB.
"""
import concurrent.futures, os, pathlib, re, shutil, subprocess, sys, tempfile, time, importlib.util

ROOT = pathlib.Path(__file__).resolve().parent.parent
IYI = os.environ.get("IYI", str(ROOT / "bin" / "iyi"))
spec = importlib.util.spec_from_file_location("gc_race", ROOT / "bench" / "gc_race.py")
race = importlib.util.module_from_spec(spec)
spec.loader.exec_module(race)

SYMBOLIZER = shutil.which("llvm-symbolizer") or r"C:\Program Files\LLVM\bin\llvm-symbolizer.exe"
BUDGET = float(os.environ.get("STRESS_MINUTES", "70")) * 60
started = time.time()
work = pathlib.Path(tempfile.mkdtemp())

def build(name, source):
    src = work / f"{name}.iyi"
    src.write_text(source)
    exe = work / (name + (".exe" if os.name == "nt" else ""))
    r = subprocess.run([IYI, "build", "--release", "-o", str(exe), str(src)], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"build failed {name}: {r.stdout[-800:]}{r.stderr[-800:]}", flush=True)
        sys.exit(1)
    return exe

def symbolize(exe, text):
    lines = []
    for off in re.findall(r"\+0x([0-9a-f]+)", text)[:24]:
        if not os.path.exists(SYMBOLIZER):
            break
        r = subprocess.run([SYMBOLIZER, "--relative-address", f"--obj={exe}", f"0x{off}"], capture_output=True, text=True)
        where = " | ".join(l for l in r.stdout.splitlines() if l.strip())[:220]
        lines.append(f"    +0x{off}: {where}")
    return "\n".join(lines)

arms = {}
for name, sources in race.PROGRAMS.items():
    stem = name.replace(" ", "_")
    program = race.IYI_STATS + sources["iyi"]
    arms[stem] = build(stem, program)
    arms[stem + "-alone"] = build(stem + "-alone", "IyiMark.workers = 0_u64\n" + program)

counts = {arm: [0, 0] for arm in arms}
shown = 0

def one(arm):
    exe = arms[arm]
    r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=600)
    return arm, r.returncode, (r.stdout or "") + (r.stderr or "")

def record(arm, code, out):
    global shown
    counts[arm][0] += 1
    if code != 0:
        counts[arm][1] += 1
        if shown < 12:
            shown += 1
            print(f"\n=== FAULT {arm} exit {code} (run {counts[arm][0]})", flush=True)
            for line in out.splitlines():
                if "STRESS" in line or "fault" in line or "panic" in line:
                    print("  " + line[:900], flush=True)
            print(symbolize(arms[arm], out), flush=True)

order = ["binary_trees", "binary_trees-alone", "live_churn", "live_churn-alone", "churn", "churn-alone"]
round_no = 0
while time.time() - started < BUDGET:
    round_no += 1
    for arm in order:
        record(*one(arm))
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        for result in pool.map(one, [a for a in order for _ in range(2)]):
            record(*result)
    if round_no % 10 == 0:
        print(f"round {round_no}, {int(time.time() - started)} s: " +
              ", ".join(f"{a} {f}/{n}" for a, (n, f) in counts.items()), flush=True)

print("\nfinal: " + ", ".join(f"{a} {f} faults in {n}" for a, (n, f) in counts.items()), flush=True)
