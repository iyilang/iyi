#!/usr/bin/env python3
"""Which jobs of .github/workflows/iyi.yml this run answers for.

    python3 scripts/ci_plan.py                      # in the workflow's `plan` job
    python3 scripts/ci_plan.py --event pull_request --files README.md bench/x.sh

A pull request runs the fast tier: the Linux build and the gates that answer in
minutes, plus the Windows binaries cross-compiled from it. Everything else - the
Windows, darwin and cursor shards, the samples round trip, the tarball - runs
for a push to master or to mt/next (the workflow's `on: push` names no other
branch), a tag, the nightly schedule and a manual dispatch. A pull
request does not stand in for those: a change that only the full set would
catch shows on master after the merge, and is reverted or fixed there.

The nightly run of a commit a nightly or dispatched run already passed on
master within `RECHECK_AFTER` selects nothing: it would answer what the last
run of that commit answered, and it held the queue behind it - the third full
run of one unchanged master took 44 jobs while three pull requests waited. A
push does not count: it builds only the broken copies of what it touched (see
below), and the nightly run is where every one of them is built. An unchanged
master is still run again once a week, for what moves under it: the runner
images, a tool installed at its latest. A run counts as a pass when a job past
the plan and the verdict succeeded in it: a nightly run that selected nothing
succeeds too, and counting it would move the week on every night. If the runs
cannot be asked about, the nightly run runs everything.

Within a pull request the changed files narrow it further:

  - only docs (`*.md`, `doc/`, `editors/`): the docs gates, and the editor
    client's package when `editors/vscode/` changed;
  - only `bench/` files, each run by some job: those jobs and the docs gates;
  - anything under `.github/` or this script: everything, because a change to
    how CI runs is only proven by running it;
  - otherwise: the fast tier, plus every job that runs a changed bench file.

A job runs a bench file when one of its steps names it, or names a bench
script that runs, sources or finds it by a glob - followed as far as it goes,
so a job that runs `std_siblings.sh` runs every `std_*_exercise.sh` and what
they source. Only code is read: a name in a comment ran nothing, and was
once credited to whichever job the comment happened to sit in.

A job is selected with the jobs it `needs`, so a selection never waits on a
skipped job. The selection is printed, and written to `$GITHUB_OUTPUT` as a
JSON list, `jobs=`, when that is set.

The exercises' broken copies (bench/mutations.sh) answer for the module they
break and the exercise that catches the break, not for the commit, and they
were most of a sibling shard's time: 53 to 74% of four shards in run
43713243986. So `mutations=` names the exercises whose copies this run builds
on Linux: a nightly run, a dispatch and a tag build every one; a push and a
pull request build those whose exercise, a bench file it reaches, or a module
it breaks changed. `mutations_elsewhere=` is the same for the Windows and
darwin jobs, and is `none` but where it is `all`: a proof breaks the module's
logic, which Linux answers for, and Windows' shards lost their runners inside
std/tls's copies.

`siblings=` narrows the sibling shards to what a pull request's bench files
reach: a change to `bench/std_zip_exercise.sh` runs that exercise and not
all 116. `*_shards=` are the shard numbers of each platform's sibling job,
four, or two on darwin when its copies are not built, and never more than
there are siblings to deal.
"""
import argparse
import fnmatch
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "iyi.yml"
BENCH = ROOT / "bench"

# A file a step or a script names: a basename, after `bench/` or `bench\`
# where it has one. `*`, `${VAR}` and `$VAR` in it stand for any name, which
# is how `std_siblings.sh` finds the module exercises and `module_test.sh`
# names a module's test.
FILE_NAME = re.compile(r"((?:bench[/\\])?)([A-Za-z0-9_*${}]+\.(?:sh|py|iyi|eiy|cr|c|go))\b")
# What can run, build or read another file here: a script, and a program
# that reads its own template or fixture. Their comments start with `#`.
CALLER_SUFFIXES = (".sh", ".py", ".iyi")
VARIABLE = re.compile(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*")

# The jobs a pull request runs whatever it touches. `docs` and `vscode` take
# seconds; the rest are the Linux build and what it feeds that finishes within
# the compiler specs' twenty-odd minutes.
FAST = ["build", "iyi", "compiler-specs", "stdlib-specs", "targets",
        "cross-objects", "cross-run", "windows-probe", "windows-collector",
        "windows-runtime", "docs", "vscode"]

# Not selected by this script: `plan` is the script, `result` reads every
# selected job's outcome, and `release` gates itself on a `v*` tag.
NOT_PLANNED = {"plan", "result", "release"}

FULL_EVENTS = {"push", "schedule", "workflow_dispatch"}
# The events that build every exercise's broken copies, on every platform;
# a `v*` tag does too, and is a push.
ALL_MUTATIONS_EVENTS = {"schedule", "workflow_dispatch"}

# The module exercises std_siblings.sh deals into shards, and how many shards
# each platform's job has: darwin's two when its broken copies are not built,
# four when they are.
SIBLINGS_SCRIPT = "std_siblings.sh"
SHARDS = {"linux": 4, "windows": 4, "darwin": 2}
DARWIN_SHARDS_WITH_MUTATIONS = 4

# A module a changed path is part of: `src/std/http.iyi`, `src/std/http/...`
# and `src/iyi/prelude.iyi` are `http`, `http` and `prelude`. And a module an
# exercise's code names by its file, `tls.iyi`, which is how a proof says
# which module it patches when that is not its own.
CHANGED_MODULE = re.compile(r"^src/(?:std|iyi)/([A-Za-z0-9_]+)(?:\.iyi$|/)")
MODULE_FILE = re.compile(r"\b([a-z0-9_]+)\.iyi\b")

# How long a commit's passing full run stands for it at night.
RECHECK_AFTER = timedelta(days=7)


def parse_jobs(text):
    """Each job's id, the ids it needs, and its block of the workflow."""
    jobs = {}
    lines = text.splitlines()
    try:
        first = lines.index("jobs:") + 1
    except ValueError:
        sys.exit("ci_plan: no top-level `jobs:` in the workflow")
    current = None
    for line in lines[first:]:
        header = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if header:
            current = header.group(1)
            jobs[current] = {"needs": [], "text": []}
        elif current:
            jobs[current]["text"].append(line)
    for job in jobs.values():
        block = "\n".join(job["text"])
        job["text"] = block
        found = re.search(r"^    needs:[ \t]*(.*?)$", block, re.M)
        if not found:
            continue
        value = found.group(1).strip()
        if value.startswith("["):
            # A flow list may wrap: read on to its closing bracket.
            rest = block[found.start(1):]
            value = rest[:rest.index("]") + 1]
            job["needs"] = [n.strip() for n in value.strip("[]").split(",") if n.strip()]
        elif value:
            job["needs"] = [value]
        else:
            after = block[found.end():].splitlines()[1:]
            for item in after:
                listed = re.match(r"^      - ([A-Za-z0-9_-]+)\s*$", item)
                if not listed:
                    break
                job["needs"].append(listed.group(1))
    return jobs


def pull_request_files(event_path, token, repository):
    with open(event_path, encoding="utf-8") as f:
        number = json.load(f)["pull_request"]["number"]
    files = []
    for page in range(1, 31):  # the API stops at 3000 files
        url = (f"https://api.github.com/repos/{repository}/pulls/{number}"
               f"/files?per_page=100&page={page}")
        request = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
        })
        with urllib.request.urlopen(request, timeout=30) as response:
            batch = json.load(response)
        files += [entry["filename"] for entry in batch]
        # A rename's old name was changed too: a moved gate still ran there.
        files += [entry["previous_filename"] for entry in batch if entry.get("previous_filename")]
        if len(batch) < 100:
            return files
    # Past the API's limit the list is not the change: run everything.
    return None


def github_get(url, token):
    request = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def pushed_files(event_path, token, repository):
    """What a push to a branch changed, from the commit before it to the one
    it pushed, or None where that is not known: a new branch has no commit
    before it, and past 300 files the compare API stops listing them."""
    with open(event_path, encoding="utf-8") as f:
        event = json.load(f)
    before, after = event.get("before") or "", event.get("after") or ""
    if not after or not before.strip("0"):
        return None
    batch = github_get(f"https://api.github.com/repos/{repository}/compare/{before}...{after}", token)["files"]
    if len(batch) >= 300:
        return None
    return ([entry["filename"] for entry in batch]
            + [entry["previous_filename"] for entry in batch if entry.get("previous_filename")])


def job_title(job_id, jobs):
    """The name a job's runs carry: its `name:`, or its id without one."""
    found = re.search(r'^    name:\s*"?([^"\n]*?)"?\s*$', jobs[job_id]["text"], re.M)
    return found.group(1) if found else job_id


def last_full_pass(runs, ran):
    """When the newest of *runs* that built every broken copy was made, or
    None: a nightly or dispatched run, and *ran(run)* - a job past the plan
    and the verdict that succeeded. A nightly run that selected nothing
    succeeds as well, and counted as a pass it moved the week on every night,
    so an unchanged master would never have been run again."""
    for run in sorted(runs, key=lambda run: run["created_at"], reverse=True):
        if run["event"] in ALL_MUTATIONS_EVENTS and ran(run):
            return datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
    return None


def full_set_passed(sha, token, repository, bookkeeping):
    """When the full set last passed on master at *sha*. *bookkeeping* is the
    names of the jobs every run has, which say nothing about what ran."""
    actions = f"https://api.github.com/repos/{repository}/actions"
    runs = github_get(f"{actions}/workflows/iyi.yml/runs?branch=master&head_sha={sha}&status=success&per_page=50",
                      token)["workflow_runs"]

    def ran(run):
        jobs = github_get(f"{actions}/runs/{run['id']}/jobs?per_page=100", token)["jobs"]
        return any(job["conclusion"] == "success" and job["name"] not in bookkeeping for job in jobs)

    return last_full_pass(runs, ran)


def is_doc(path):
    return path.endswith(".md") or path.startswith(("doc/", "editors/"))


def code(text):
    """*text* without its whole-line comments, in YAML, shell and Python alike."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def named_files(text, names):
    """The files of *names* that *text*'s code names, a glob or a variable in
    a name standing for any. A name that is nothing but a wildcard counts only
    after `bench/`: `"$WORK"/*.iyi` is a scratch directory, `bench\\*.iyi` is
    every program here."""
    found = set()
    for prefix, written in FILE_NAME.findall(code(text)):
        pattern = VARIABLE.sub("*", written)
        if not pattern.rsplit(".", 1)[0].strip("*") and not prefix:
            continue
        found.update(fnmatch.filter(names, pattern))
    return found


def bench_texts(directory=BENCH):
    """Each file directly under bench/, by name, with its text."""
    return {path.name: path.read_text(encoding="utf-8", errors="ignore")
            for path in directory.iterdir() if path.is_file()}


class Reach:
    """Who runs what: for each bench file the scripts whose code names it -
    what runs it, sources it or finds it by a glob - and for each job the
    bench files its steps name. Read once; a plan asks it once per file."""

    def __init__(self, jobs, bench):
        self.bench = bench
        names = list(bench)
        self.scripts = {name: code(text) for name, text in bench.items()
                        if name.endswith(CALLER_SUFFIXES)}
        self.called_by = {}
        for name, text in self.scripts.items():
            for callee in named_files(text, names) - {name}:
                self.called_by.setdefault(callee, set()).add(name)
        self.jobs = {name: code(job["text"]) for name, job in jobs.items() if name not in NOT_PLANNED}
        self.job_files = {name: named_files(text, names) for name, text in self.jobs.items()}

    def reaching(self, path, stop=()):
        """The bench scripts that reach `bench/...` *path* - the file itself,
        and what runs, sources or finds it, as far as the scripts go, but not
        past a script of *stop* - and, for a file in a directory under bench/
        (a fixture, an oracle's source), the scripts whose code names that
        directory, with a pattern for a step that names it."""
        parts = path.split("/")
        nested = None
        if len(parts) == 2 and parts[1] in self.bench:
            start = {parts[1]}
        else:
            directory = re.compile(rf"\b{re.escape(parts[1])}\b")
            start = {name for name, text in self.scripts.items() if directory.search(text)}
            nested = re.compile(rf"bench[/\\]{re.escape(parts[1])}\b")
        reached = set(start)
        pending = list(start)
        while pending:
            callee = pending.pop()
            if callee in stop:
                continue
            for caller in self.called_by.get(callee, ()):
                if caller not in reached:
                    reached.add(caller)
                    pending.append(caller)
        return reached, nested

    def running_jobs(self, path):
        """The jobs that run `bench/...` *path*: whose steps name it or a
        script that reaches it, or the directory it is in."""
        reached, nested = self.reaching(path)
        return {name for name, files in self.job_files.items()
                if files & reached or (nested is not None and nested.search(self.jobs[name]))}


def source_modules(root=ROOT):
    """The modules a changed path or an exercise can name: every file and
    directory of `src/std` and every file of `src/iyi`, by name."""
    names = set()
    for directory in (root / "src" / "std", root / "src" / "iyi"):
        if directory.is_dir():
            names |= {entry.stem for entry in directory.iterdir() if entry.suffix == ".iyi"}
            names |= {entry.name for entry in directory.iterdir() if entry.is_dir()}
    return names


def mutation_targets(bench, modules):
    """Each exercise whose broken copies bench/mutations.sh gates, by name
    without `.sh`, with the modules its proofs may break: its own, and every
    one of *modules* its code names by file."""
    targets = {}
    for name, text in bench.items():
        body = code(text)
        if not name.endswith(".sh") or "bench/mutations.sh" not in body:
            continue
        stem = name[:-len(".sh")]
        broken = {module for module in MODULE_FILE.findall(body) if module in modules}
        if stem.startswith("std_") and stem.endswith("_exercise") and stem != "std_exercise":
            broken.add(stem[len("std_"):-len("_exercise")])
        targets[stem] = broken
    return targets


def named_set(chosen, every):
    """`all`, `none`, or the names of *chosen*, sorted and spaced."""
    if not chosen:
        return "none"
    if chosen == every:
        return "all"
    return " ".join(sorted(chosen))


def mutation_scope(files, bench, reach, modules):
    """The exercises whose broken copies *files* call for, as `named_set`
    says them: those whose exercise or a bench file it reaches changed, and
    those whose proofs break a changed module. std_siblings.sh runs the
    siblings for std_exercise.sh, and a sibling's change is not one to the
    foundation's proofs, so a reach stops there."""
    targets = mutation_targets(bench, modules)
    wanted = set()
    for path in files:
        if path.startswith("bench/"):
            reached, _ = reach.reaching(path, stop={SIBLINGS_SCRIPT})
            wanted |= {name[:-len(".sh")] for name in reached} & set(targets)
        else:
            changed = CHANGED_MODULE.match(path)
            if changed:
                wanted |= {name for name, broken in targets.items() if changed.group(1) in broken}
    return named_set(wanted, set(targets))


def sibling_subset(files, bench, reach):
    """The module exercises a pull request's bench files reach, as
    `named_set` says them; every one when std_siblings.sh itself changed."""
    siblings = {name[:-len(".sh")] for name in bench
                if fnmatch.fnmatch(name, "std_*_exercise.sh") and name != "std_exercise.sh"}
    chosen = set()
    for path in files:
        if path == f"bench/{SIBLINGS_SCRIPT}":
            return "all"
        if path.startswith("bench/"):
            reached, _ = reach.reaching(path)
            chosen |= {name[:-len(".sh")] for name in reached} & siblings
    return named_set(chosen, siblings)


def sibling_shards(siblings, elsewhere):
    """Each platform's shard numbers for *siblings*: its own count, darwin's
    raised while it builds broken copies, and no more than there are
    siblings to deal."""
    count = {"all": None, "none": 1}.get(siblings, len(siblings.split()))
    shards = {}
    for platform, n in SHARDS.items():
        if platform == "darwin" and elsewhere == "all":
            n = DARWIN_SHARDS_WITH_MUTATIONS
        if count is not None:
            n = min(n, count)
        shards[platform] = list(range(1, n + 1))
    return shards


def close_over_needs(jobs, selected):
    pending = list(selected)
    while pending:
        for need in jobs[pending.pop()]["needs"]:
            if need not in selected and need not in NOT_PLANNED:
                selected.add(need)
                pending.append(need)
    return selected


def plan(jobs, event, ref, files, bench):
    """The selected job ids and the reason, in one sentence."""
    every = {name for name in jobs if name not in NOT_PLANNED}
    if event == "push" and ref.startswith("refs/tags/editor-v"):
        return {"vscode"}, "an editor client tag publishes the client and nothing else"
    if event in FULL_EVENTS:
        return every, f"`{event}` runs the full set"
    if event != "pull_request":
        sys.exit(f"ci_plan: no tier for the event `{event}`")
    if files is None:
        return every, "the pull request changes more files than the API lists"
    if any(f.startswith(".github/") or f == "scripts/ci_plan.py" for f in files):
        return every, "the change is to CI itself"

    code_files = [f for f in files if not is_doc(f)]
    selected = {"docs"}
    if any(f.startswith("editors/vscode/") for f in files):
        selected.add("vscode")
    if not code_files:
        return close_over_needs(jobs, selected), "only docs changed"

    changed_bench = [f for f in code_files if f.startswith("bench/")]
    reach = Reach(jobs, bench) if changed_bench else None
    running = {f: reach.running_jobs(f) for f in changed_bench}
    for found in running.values():
        selected |= found
    if len(changed_bench) == len(code_files) and all(running.values()):
        return close_over_needs(jobs, selected), "only bench files changed, each run by a job"
    selected |= set(FAST)
    return close_over_needs(jobs, selected), "the fast tier, and the jobs that run a changed bench file"


def scopes(event, ref, files, full, jobs, bench):
    """What the jobs this run selected build and deal: `mutations`,
    `mutations_elsewhere`, `siblings` and each platform's `*_shards`.
    *files* is what the push or the pull request changed, None where that is
    not known; *full* is whether every job was selected."""
    mutations = elsewhere = siblings = "all"
    if event not in ALL_MUTATIONS_EVENTS and not ref.startswith("refs/tags/"):
        elsewhere = "none"
        if files is not None:
            reach = Reach(jobs, bench)
            mutations = mutation_scope(files, bench, reach, source_modules())
            if event == "pull_request" and not full:
                siblings = sibling_subset(files, bench, reach)
    found = {"mutations": mutations, "mutations_elsewhere": elsewhere, "siblings": siblings}
    for platform, shards in sibling_shards(siblings, elsewhere).items():
        found[f"{platform}_shards"] = json.dumps(shards)
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_NAME"))
    parser.add_argument("--ref", default=os.environ.get("GITHUB_REF", ""))
    parser.add_argument("--files", nargs="*", help="the changed files, instead of asking the API")
    parser.add_argument("--sha", default=os.environ.get("GITHUB_SHA", ""), help="the commit a scheduled run tests")
    args = parser.parse_args()
    if not args.event:
        sys.exit("ci_plan: no event: pass --event or run under GitHub Actions")

    jobs = parse_jobs(WORKFLOW.read_text(encoding="utf-8"))
    missing = [name for name in FAST if name not in jobs]
    if missing:
        sys.exit(f"ci_plan: FAST names jobs the workflow does not have: {', '.join(missing)}")
    # `result` is the one check a ruleset requires, so a job it does not
    # need could fail and still let a change through.
    unread = sorted(set(jobs) - NOT_PLANNED - set(jobs["result"]["needs"]))
    if unread:
        sys.exit(f"ci_plan: `result` does not need {', '.join(unread)}")

    files = args.files
    if files is None and args.event == "pull_request":
        files = pull_request_files(os.environ["GITHUB_EVENT_PATH"], os.environ["GITHUB_TOKEN"],
                                   os.environ["GITHUB_REPOSITORY"])
    elif files is None and args.event == "push" and not args.ref.startswith("refs/tags/"):
        try:
            files = pushed_files(os.environ["GITHUB_EVENT_PATH"], os.environ["GITHUB_TOKEN"],
                                 os.environ["GITHUB_REPOSITORY"])
        except (KeyError, OSError, ValueError) as error:
            print(f"ci_plan: could not ask what the push changed ({error}), so every broken copy is built")

    bench = bench_texts()
    selected, reason = plan(jobs, args.event, args.ref, files, bench)
    planned = {name for name in jobs if name not in NOT_PLANNED}
    if args.event == "schedule":
        try:
            bookkeeping = {job_title("plan", jobs), job_title("result", jobs)}
            passed = full_set_passed(args.sha, os.environ["GITHUB_TOKEN"], os.environ["GITHUB_REPOSITORY"], bookkeeping)
        except (KeyError, OSError, ValueError) as error:
            passed = None
            print(f"ci_plan: could not ask whether {args.sha[:9]} passed already ({error}), so it runs")
        if passed is not None:
            age = datetime.now(timezone.utc) - passed
            if age < RECHECK_AFTER:
                hours = int(age.total_seconds() // 3600)
                selected, reason = set(), (f"{args.sha[:9]} passed the full set on master {hours} hours ago, "
                                           f"and a nightly run of it waits until that is {RECHECK_AFTER.days} days")
    ordered = sorted(selected)
    print(f"{reason}: {len(ordered)} of {len(jobs) - len(NOT_PLANNED)} jobs")
    for name in ordered:
        print(f"  {name}")
    skipped = sorted(set(jobs) - selected - NOT_PLANNED)
    if skipped:
        print(f"skipped: {', '.join(skipped)}")
    found = scopes(args.event, args.ref, files, selected == planned, jobs, bench)
    for key, value in found.items():
        print(f"{key}: {value}")

    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as f:
            f.write(f"jobs={json.dumps(ordered)}\n")
            f.write("".join(f"{key}={value}\n" for key, value in found.items()))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(f"**{reason}**: {len(ordered)} jobs\n\n")
            f.write("".join(f"- `{name}`\n" for name in ordered))
            if skipped:
                f.write(f"\nSkipped: {', '.join(f'`{n}`' for n in skipped)}\n")
            f.write("\n" + "".join(f"- {key}: `{value}`\n" for key, value in found.items()))


if __name__ == "__main__":
    main()
