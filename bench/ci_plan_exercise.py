#!/usr/bin/env python3
"""`scripts/ci_plan.py` picks the jobs that run what a pull request changed.

    python3 bench/ci_plan_exercise.py [path/to/ci_plan.py]

The planner decides what a pull request is tested by, and it was tested by
nothing. It credited a gate to a job because the gate's name sat in a
comment, so a pull request that changed only `bench/std_tls_exercise.sh`
ran `windows-std-platforms` - which never runs it - and passed. And it did
not see a gate another script runs: 483 of the 590 files under bench/ were
run by no job it knew of, so a change to a module exercise ran none of them.

Three parts. The first runs the planner as CI does, on this tree, and names
the jobs each change must and must not select. It takes the planner's path,
so it can be pointed at an older one: the planner before this fix fails the
first three checks, and has no `Reach` for the second part. The second
builds a workflow and a bench directory of its own, for the shapes this tree
only has one of: a sourced helper, a glob, a variable in a name, a program's
template, a scratch glob that must not reach everything, a name in a
comment above the next job. The third holds `bench/gates_reachable.py`'s
stricter reading - what a line *runs*, not what it names - to a command, a
comment, a message, a `$( )` in quotes, a loop, a function and Python's
strings, reads and subprocesses.
"""
import importlib.util
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLANNER = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "scripts" / "ci_plan.py"

failures = []


def check(what, holds, evidence=""):
    print(f"  {'ok' if holds else 'FAIL'}: {what}")
    if not holds:
        failures.append(what)
        if evidence:
            print("    " + str(evidence).replace("\n", "\n    "))


def planned(*files):
    """The reason and the selected jobs, from the planner's own command line."""
    ran = subprocess.run([sys.executable, str(PLANNER), "--event", "pull_request", "--files", *files],
                         cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
    lines = ran.stdout.splitlines()
    if ran.returncode != 0 or not lines:
        return f"exit {ran.returncode}: {ran.stderr.strip()}", set()
    return lines[0], {line.strip() for line in lines[1:] if line.startswith("  ")}


def scoped(*args):
    """What the planner's command line says a run builds and deals, by key:
    `mutations`, `siblings`, the platforms' `*_shards`."""
    ran = subprocess.run([sys.executable, str(PLANNER), *args], cwd=ROOT, capture_output=True, text=True,
                         encoding="utf-8")
    found = {}
    for line in ran.stdout.splitlines():
        key, _, value = line.partition(": ")
        if key in ("mutations", "mutations_elsewhere", "siblings") or key.endswith("_shards"):
            found[key] = value
    return found


print("== this tree, as CI plans it")

reason, jobs = planned("bench/std_tls_exercise.sh")
check("a module exercise selects the jobs that run every sibling",
      {"std-siblings", "windows-std-siblings", "darwin-std-siblings"} <= jobs, f"{reason}: {sorted(jobs)}")
check("and not the job that only mentions it in a comment",
      "windows-std-platforms" not in jobs, f"{reason}: {sorted(jobs)}")

reason, jobs = planned("bench/std_base64_exercise.sh")
check("an exercise no step names is still run, through the siblings",
      "std-siblings" in jobs and reason.startswith("only bench files changed"), f"{reason}: {sorted(jobs)}")

reason, jobs = planned("bench/panics.sh")
check("a gate a job runs selects that job", "windows-native" in jobs, f"{reason}: {sorted(jobs)}")

# Spelled in two pieces: this file runs in the docs job, and a name written
# whole in its code would be a file the docs job runs.
reason, jobs = planned("bench/" + "share_count" + ".cr")
check("a file nothing runs falls back to the fast tier",
      reason.startswith("the fast tier") and "compiler-specs" in jobs, f"{reason}: {sorted(jobs)}")

reason, jobs = planned("README.md")
check("a doc selects the docs gates alone", jobs == {"docs"}, f"{reason}: {sorted(jobs)}")

reason, jobs = planned(".github/workflows/iyi.yml")
check("a change to CI runs everything", reason.startswith("the change is to CI itself"), reason)

print()
print("== what a run builds and deals: the broken copies and the sibling shards")

said = scoped("--event", "pull_request", "--files", "bench/std_zip_exercise.sh")
check("one exercise changed deals that sibling alone, in one shard on each platform",
      said.get("siblings") == "std_zip_exercise"
      and all(said.get(f"{p}_shards") == "[1]" for p in ("linux", "windows", "darwin")), said)
check("and builds its broken copies on Linux, and none elsewhere",
      "std_zip_exercise" in said.get("mutations", "").split() and said.get("mutations_elsewhere") == "none", said)

said = scoped("--event", "pull_request", "--files", "src/std/tls.iyi")
mutated = said.get("mutations", "").split()
check("a module changed builds the copies of every exercise whose proofs break it",
      {"std_tls_exercise", "std_http_exercise"} <= set(mutated) and "std_zip_exercise" not in mutated, said)

said = scoped("--event", "pull_request", "--files", "bench/std_siblings.sh")
check("the shard runner changed deals every sibling, and breaks nothing",
      said.get("siblings") == "all" and said.get("mutations") == "none"
      and said.get("linux_shards") == "[1, 2, 3, 4]", said)

said = scoped("--event", "push", "--ref", "refs/heads/master", "--files", "src/compiler/crystal.cr")
check("a push of the compiler alone runs every sibling and builds no broken copy",
      said.get("siblings") == "all" and said.get("mutations") == "none"
      and said.get("mutations_elsewhere") == "none" and said.get("darwin_shards") == "[1, 2]", said)

said = scoped("--event", "push", "--ref", "refs/tags/v9.9.9")
check("a tag builds every broken copy everywhere, darwin in four shards",
      said.get("mutations") == "all" and said.get("mutations_elsewhere") == "all"
      and said.get("darwin_shards") == "[1, 2, 3, 4]", said)

print()
print("== a workflow and a bench directory of this exercise's own")

spec = importlib.util.spec_from_file_location("ci_plan_under_test", PLANNER)
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)
if not hasattr(planner, "Reach"):
    check("the planner reads what runs what (`Reach`)", False, f"{PLANNER} has no Reach")
else:
    workflow = """jobs:
  plan:
    runs-on: x
  docs:
    needs: plan
    steps:
      - run: true
  alpha:
    needs: plan
    steps:
      - run: bash bench/runner.sh
  # bench/only_in_comment.sh is named here, above beta, and runs nowhere.
  beta:
    needs: [plan, alpha]
    steps:
      # bash bench/runner.sh, once, before it moved to alpha
      - run: bash bench/direct.sh
  result:
    needs: [docs, alpha, beta]
"""
    bench = {
        "runner.sh": 'for s in "$REPO"/bench/std_*_exercise.sh; do bash "$s"; done\n',
        "std_one_exercise.sh": 'MODULE=one\n. "$(dirname "$0")/helper.sh"\n',
        "helper.sh": 'TEST="$REPO/bench/std_${MODULE}_test.iyi"\n"$IYI" test "$TEST"\n',
        "std_one_test.iyi": 'test "page" { assert_eq "x", Eiy.render("std_one.eiy") }\n',
        "std_one.eiy": "<%= 1 %>\n",
        "direct.sh": 'for f in "$WORK"/*.iyi; do :; done\n# bash bench/lonely.sh\n',
        "only_in_comment.sh": "true\n",
        "lonely.sh": "true\n",
        "other.iyi": 'puts "nothing runs this"\n',
    }
    reach = planner.Reach(planner.parse_jobs(workflow), bench)
    for path, expected, what in [
        ("bench/std_one_exercise.sh", {"alpha"}, "a sibling, through the runner's glob"),
        ("bench/helper.sh", {"alpha"}, "a sourced helper, through what sources it"),
        ("bench/std_one_test.iyi", {"alpha"}, "a test a helper names with a variable"),
        ("bench/std_one.eiy", {"alpha"}, "a template its program reads"),
        ("bench/runner.sh", {"alpha"}, "a script named in code, not in a comment of another job"),
        ("bench/direct.sh", {"beta"}, "a script one job names"),
        ("bench/only_in_comment.sh", set(), "a name in a comment above a job"),
        ("bench/lonely.sh", set(), "a name in a script's comment"),
        ("bench/other.iyi", set(), "a program a scratch-directory glob does not reach"),
    ]:
        found = reach.running_jobs(path)
        check(f"{what}: {path} -> {sorted(expected) or 'nothing'}", found == expected, f"got {sorted(found)}")

    selected, reason = planner.plan(planner.parse_jobs(workflow), "pull_request", "", ["bench/std_one.eiy"], bench)
    check("a plan of one bench file is its jobs, what they need, and the docs gates",
          selected == {"alpha", "docs"} and reason.startswith("only bench files changed"), f"{reason}: {sorted(selected)}")

    gated = {
        "mutations.sh": "mutations_wanted() { :; }\n",
        "std_one_exercise.sh": '. "$REPO/bench/mutations.sh"\nmutate "x" old new two.iyi\n# three.iyi\n',
        "std_four_exercise.sh": 'echo "no broken copies here"\n',
        "std_five_exercise.sh": '. "$REPO/bench/mutations.sh"\n',
    }
    modules = {"one", "two", "three", "four", "five"}
    targets = planner.mutation_targets(gated, modules)
    check("an exercise's proofs break its own module and every module its code names by file",
          targets == {"std_one_exercise": {"one", "two"}, "std_five_exercise": {"five"}}, f"got {targets}")
    gated_reach = planner.Reach(planner.parse_jobs(workflow), gated)
    for files, expected, what in [
        (["src/std/two.iyi"], "std_one_exercise", "a module another exercise's proofs patch"),
        (["src/std/three.iyi"], "none", "a module named only in a comment"),
        (["src/std/one/part.iyi"], "std_one_exercise", "a file under a module's directory"),
        (["bench/mutations.sh"], "all", "the gate itself"),
    ]:
        found = planner.mutation_scope(files, gated, gated_reach, modules)
        check(f"{what}: {files[0]} -> {expected}", found == expected, f"got {found}")

print()
print("== and the reach gate, which asks the stricter question: what runs it")

# `bench/gates_reachable.py` reads names the planner's way and then asks
# whether a line runs what it names. A planner may choose too many jobs; that
# gate may not count too much as run, or an unrun gate passes it. It counted
# a comment, a message and a list of strings once.
spec = importlib.util.spec_from_file_location("gates_reachable_under_test", ROOT / "bench" / "gates_reachable.py")
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)
names = ["x.sh", "y.py", "z.iyi", "std_a_exercise.sh", "std_b_exercise.sh"]
for text, python, expected, what in [
    ("bash bench/x.sh\n", False, {"x.sh"}, "a command"),
    ("# bash bench/x.sh\n", False, set(), "a comment"),
    ('echo "  then bash bench/x.sh by hand"\n', False, set(), "a message"),
    ('out="$("$PY" "$REPO/bench/y.py" arg)"\n', False, {"y.py"}, "a command inside a quoted $( )"),
    ('if ! "$IYI" build -o p "$REPO/bench/z.iyi"; then\n', False, {"z.iyi"}, "a build after `if !`"),
    ('for s in "$REPO"/bench/std_*_exercise.sh; do\n  bash "$s"\ndone\n', False,
     {"std_a_exercise.sh", "std_b_exercise.sh"}, "a loop's files, run through its variable"),
    ('for s in "$REPO"/bench/std_*_exercise.sh; do\n  echo "$s"\ndone\n', False, set(), "a loop that only prints"),
    ('check() {\n  "$IYI" run "$1"\n}\ncheck "$REPO/bench/z.iyi"\n', False, {"z.iyi"}, "a call of a function that runs"),
    ('LISTED = ["x.sh", "y.py"]\n', True, set(), "a list of strings"),
    ('source = (REPO / "bench/y.py").read_text()\n', True, set(), "a file read for its text"),
    ('subprocess.run([sys.executable, str(BENCH / "y.py")])\n', True, {"y.py"}, "a subprocess"),
]:
    found = gates.runs(text, names, python)
    check(f"{what} -> {sorted(expected) or 'nothing'}", found == expected, f"got {sorted(found)}")

print()
if failures:
    print(f"ci_plan exercise: {len(failures)} check(s) failed")
    sys.exit(1)
print("ci_plan exercise: every check held")
