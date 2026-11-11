#!/usr/bin/env python3
"""The edit loop on programs shaped like real ones (SPEC.md IV.3a).

    python3 bench/edit_loop.py [COMPILER] [--runs N] [--json OUT]

`bench/incremental.py` times the loop on one generated project against Go and
the language this fork began as. Issue #142 timed a real application of about
the same size and found it 28x slower than that table, so this times the loop
on programs that are
not the generated one, and on the generated one again beside them:

  * IV.3a's generated project (`incremental/generate_project.py`);
  * a generated web application (`incremental/generate_webapp.py`): generic
    repositories, unions, `derive serializable`, EIY templates, an `env` macro;
  * `samples/iyi/webapp.iyi`, with the `kemal` and `app` modules it imports;
  * `bench/std_http_exercise.iyi`, the largest single program here.

Each is built in two modes, from source and with `--emit-iyimod mods
--use-iyimod mods` (the IV.3 loop), each mode in a cache of its own. Per mode:
one cold build; RUNS rebuilds with nothing changed; the same RUNS again with
`--force`, when the compiler has it, which is what a rebuild costs when it does
compile (SPEC.md V.9 (e)); and RUNS rebuilds each after a one-line edit.
Medians, wall clock, of the `iyi build` process. One more of the unchanged and
the edited build is run under `-s`, and its phases are kept in the JSON.

The programs are run too: after the unchanged rebuilds each prints what it
printed after its first build, and an edit the program can see changes what it
prints. A rebuild that is fast because it kept a stale program would fail here
rather than read as a good number.

COMPILER defaults to `.build/iyi`. The seconds are this machine's; read them
with `bench/machine_probe.py`'s fingerprint, and from a release compiler (`make
iyi release=1`): a debug one is refused, as `incremental.py` refuses one.
"""
import argparse
import json
import os
import pathlib
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "bench" / "incremental"))
import generate_project  # noqa: E402
import generate_webapp  # noqa: E402

ARTIFACTS = ["--emit-iyimod", "mods", "--use-iyimod", "mods"]


def projects(work):
    """Each program, copied or generated under *work*, with its one-line edit.

    `old` is the line the edit replaces and `new` its replacement, `{n}` the
    edit's number, so that every edit is a change and the program can see it.
    A program with no line to change that the program prints gets a comment
    appended instead (`new` is None), which the compiler reads and the program
    cannot see.
    """
    found = []

    root = work / "generated"
    generate_project.write_project(root)
    found.append(dict(name="IV.3a's generated project", root=root / "iyi", entry="main.iyi",
                      edit="parts/mod7.iyi", old="  edit_point = 0\n", new="  edit_point = {n}\n"))

    root = work / "webapp-generated"
    generate_webapp.generate(str(root), generate_webapp.CONTROLLERS)
    found.append(dict(name=f"generated web app ({generate_webapp.CONTROLLERS} controllers)", root=root,
                      entry="main.iyi", edit="web/controllers/c7.iyi", old="  total = reports7\n",
                      new="  total = reports7 + {n}\n"))

    root = work / "webapp"
    root.mkdir()
    for sub in ("kemal", "app"):
        shutil.copytree(REPO / "samples" / "iyi" / sub, root / sub)
    shutil.copy(REPO / "samples" / "iyi" / "webapp.iyi", root / "webapp.iyi")
    found.append(dict(name="samples/iyi/webapp.iyi (kemal, app)", root=root, entry="webapp.iyi",
                      edit="webapp.iyi", old="  42\n", new="  {n}42\n"))

    root = work / "std_http_exercise"
    root.mkdir()
    shutil.copy(REPO / "bench" / "std_http_exercise.iyi", root / "std_http_exercise.iyi")
    found.append(dict(name="bench/std_http_exercise.iyi", root=root, entry="std_http_exercise.iyi",
                      edit="std_http_exercise.iyi", old=None, new=None))
    return found


def size_of(root):
    """Files and lines of iyi and EIY source, `wc -l`'s count."""
    files = [p for p in pathlib.Path(root).rglob("*") if p.suffix in (".iyi", ".eiy") and "mods" not in p.parts]
    return len(files), sum(p.read_bytes().count(b"\n") for p in files)


class Loop:
    def __init__(self, compiler, project, flags, cache):
        self.compiler = compiler
        self.project = project
        self.flags = flags
        self.env = dict(os.environ, IYI_CACHE_DIR=str(cache))
        self.edits = 0
        self.current = project["old"]

    def build(self, *extra):
        cmd = [self.compiler, "build", *self.flags, *extra, "-o", "prog", self.project["entry"]]
        start = time.perf_counter()
        proc = subprocess.run(cmd, cwd=self.project["root"], env=self.env, capture_output=True, text=True)
        elapsed = time.perf_counter() - start
        if proc.returncode != 0:
            sys.exit(f"edit_loop: `{' '.join(cmd)}` failed in {self.project['root']}:\n{proc.stdout}{proc.stderr}")
        return elapsed, proc.stdout

    def prints(self):
        proc = subprocess.run([str(self.project["root"] / "prog")], cwd=self.project["root"],
                              capture_output=True, text=True, timeout=120)
        return proc.stdout

    def edit(self):
        self.edits += 1
        path = self.project["root"] / self.project["edit"]
        text = path.read_text()
        if self.project["new"] is None:
            lines = [line for line in text.rstrip("\n").split("\n") if not line.startswith("# edit_loop ")]
            path.write_text("\n".join(lines) + f"\n# edit_loop {self.edits}\n")
            return
        if self.current not in text:
            sys.exit(f"edit_loop: {path} no longer has {self.current!r} to edit")
        replacement = self.project["new"].format(n=self.edits)
        path.write_text(text.replace(self.current, replacement, 1))
        self.current = replacement

    def undo(self):
        path = self.project["root"] / self.project["edit"]
        text = path.read_text()
        if self.project["new"] is None:
            lines = [line for line in text.rstrip("\n").split("\n") if not line.startswith("# edit_loop ")]
            path.write_text("\n".join(lines) + "\n")
        elif self.current != self.project["old"]:
            path.write_text(text.replace(self.current, self.project["old"], 1))
            self.current = self.project["old"]


def phases(text):
    """`-s`'s stage lines as seconds, and the up-to-date check's own lines."""
    found = {}
    for line in text.splitlines():
        match = re.match(r"^(.+?)\s*:\s+(\d+):(\d+):(\d+\.\d+)", line)
        if match:
            name, hours, minutes, seconds = match.groups()
            found[name.strip()] = round(int(hours) * 3600 + int(minutes) * 60 + float(seconds), 3)
        elif line.startswith("Up-to-date check:") or line.endswith(" is up to date"):
            found.setdefault("notes", []).append(line.strip())
    return found


def median(values):
    return round(statistics.median(values), 3)


def measure(compiler, project, mode, flags, cache, runs, force):
    loop = Loop(compiler, project, flags, cache)
    row = dict(program=project["name"], mode=mode)
    row["files"], row["lines"] = size_of(project["root"])
    row["cold"] = round(loop.build()[0], 3)
    # Settled: the artifacts written and read back once, the objects cached.
    loop.build("--force") if force else loop.build()
    first = loop.prints()

    unchanged = [loop.build()[0] for _ in range(runs)]
    row["unchanged"] = median(unchanged)
    row["unchanged_phases"] = phases(loop.build("-s")[1])
    if loop.prints() != first:
        sys.exit(f"edit_loop: {project['name']} ({mode}) prints something else after a rebuild with nothing changed")
    if force:
        forced = [loop.build("--force")[0] for _ in range(runs)]
        row["unchanged_forced"] = median(forced)
        row["unchanged_forced_phases"] = phases(loop.build("--force", "-s")[1])

    edited = []
    before = first
    for index in range(runs + 1):
        loop.edit()
        if index < runs:
            edited.append(loop.build()[0])
        else:
            row["edited_phases"] = phases(loop.build("-s")[1])
        after = loop.prints()
        if project["new"] is not None and after == before:
            sys.exit(f"edit_loop: {project['name']} ({mode}) prints what it printed before edit {loop.edits}")
        if project["new"] is None and after != first:
            sys.exit(f"edit_loop: {project['name']} ({mode}) prints something else after a comment was added")
        before = after
    row["edited"] = median(edited)
    loop.undo()
    return row


def table(rows, force):
    head = "| program | files, lines | mode | cold | nothing changed |"
    rule = "|---|---|---|---:|---:|"
    if force:
        head += " nothing changed, `--force` |"
        rule += "---:|"
    head += " one-line edit |"
    rule += "---:|"
    out = [head, rule]
    for row in rows:
        cells = [row["program"], f"{row['files']}, {row['lines']:,}", row["mode"],
                 f"{row['cold']:.2f}", f"{row['unchanged']:.3f}"]
        if force:
            cells.append(f"{row['unchanged_forced']:.2f}")
        cells.append(f"{row['edited']:.2f}")
        out.append("| " + " | ".join(cells) + " |")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("compiler", nargs="?", default=str(REPO / ".build" / "iyi"))
    parser.add_argument("--runs", type=int, default=7)
    parser.add_argument("--json")
    parser.add_argument("--allow-debug", action="store_true",
                        help="time a compiler not built in release mode, for ratios only")
    args = parser.parse_args()
    compiler = os.path.abspath(args.compiler)

    version = subprocess.run([compiler, "--version"], capture_output=True, text=True).stdout
    if "not built in release mode" in version and not args.allow_debug:
        sys.exit(f"edit_loop: {compiler} is not a release build; `make iyi release=1`, or --allow-debug for ratios")
    helped = subprocess.run([compiler, "build", "--help"], capture_output=True, text=True).stdout
    force = "--force" in helped

    rows = []
    with tempfile.TemporaryDirectory(prefix="iyi-edit-loop-") as raw:
        work = pathlib.Path(raw)
        for project in projects(work):
            for mode, flags in (("source", []), ("artifacts", ARTIFACTS)):
                shutil.rmtree(project["root"] / "mods", ignore_errors=True)
                cache = work / "cache" / f"{project['root'].name}-{mode}"
                row = measure(compiler, project, mode, flags, cache, args.runs, force)
                rows.append(row)
                print(json.dumps({key: row[key] for key in row if not key.endswith("phases")}), flush=True)

    print()
    print(f"{version.splitlines()[0]}, medians of {args.runs}, seconds")
    print(table(rows, force))
    if args.json:
        with open(args.json, "w") as handle:
            json.dump(dict(compiler=compiler, version=version, runs=args.runs, rows=rows), handle, indent=1)


if __name__ == "__main__":
    main()
