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
import json
import os
import subprocess
import sys
import tempfile
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


def planned(*files, base=None):
    """The reason and the selected jobs, from the planner's own command line. *base* is the base
    branch's workflow; with none, and none of CI's credentials in the environment, it cannot be read."""
    command = [sys.executable, str(PLANNER), "--event", "pull_request", "--files", *files]
    if base is not None:
        command += ["--base-workflow", str(base)]
    env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_EVENT_PATH", "GITHUB_TOKEN", "GITHUB_REPOSITORY")}
    ran = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", env=env)
    lines = ran.stdout.splitlines()
    if ran.returncode != 0 or not lines:
        return f"exit {ran.returncode}: {ran.stderr.strip()}", set()
    return lines[0], {line.strip() for line in lines[1:] if line.startswith("  ")}


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

workflow_text = (ROOT / ".github" / "workflows" / "iyi.yml").read_text(encoding="utf-8")
with tempfile.TemporaryDirectory() as scratch:
    same = Path(scratch) / "same.yml"
    same.write_text(workflow_text, encoding="utf-8")
    reason, jobs = planned(".github/workflows/iyi.yml", base=same)
    check("a change to CI that edits no job runs the fast tier, and no darwin job",
          reason.startswith("the fast tier") and "compiler-specs" in jobs and not any(j.startswith("darwin") for j in jobs),
          f"{reason}: {sorted(jobs)}")
    edited = Path(scratch) / "edited.yml"
    edited.write_text(workflow_text.replace("\n  darwin:\n", "\n  darwin:\n    env: {BASE: x}\n", 1), encoding="utf-8")
    reason, jobs = planned(".github/workflows/iyi.yml", base=edited)
    check("a job the change edits runs with it, and the jobs it needs", "darwin" in jobs and "compiler-specs" in jobs,
          f"{reason}: {sorted(jobs)}")
reason, jobs = planned(".github/workflows/iyi.yml")
check("a change to CI whose base workflow cannot be read runs everything",
      reason.startswith("the change is to CI itself") and "darwin" in jobs, f"{reason}: {sorted(jobs)}")

# Each compiler component change selects macOS, Linux and Windows.
for files, what in [
    (["src/compiler/codegen/codegen.iyi"], "a self-host compiler source"),
    (["bench/selfhost_lexer_exercise.sh"], "a self-host gate"),
    (["bench/native_elf_run.sh"], "the native Linux ELF execution gate"),
    (["bench/native_ir_exercise.sh"], "a native compiler gate"),
    (["bench/lib/host.sh"], "the shared test-host helper"),
    (["bench/fixtures/compile_stdout.iyi"], "a fixture the self-host gates read"),
    (["bench/selfhost_gates.sh", "src/compiler/syntax/lexer.iyi"], "a mixed change to the self-host gates and the compiler"),
    (["src/compiler/ir/builder.iyi"], "an IR compiler source"),
    (["bench/" + "native_ir" + "_exercise.sh"], "the native IR gate"),
    (["bench/" + "selfhost_ir_fold" + "_exercise.iyi"], "the IR folding exercise"),
    (["bench/fixtures/" + "ir/valid/everything.ir"], "an IR fixture"),
    (["bench/" + "native_codegen" + "_exercise.sh"], "the AArch64 codegen gate"),
    (["bench/" + "native_encode" + "_exercise.sh"], "the AArch64 encoder gate"),
    (["bench/" + "native_regalloc" + "_exercise.sh"], "the register allocator gate"),
    (["src/compiler/tools/native_cg.iyi"], "the native codegen driver"),
    (["bench/fixtures/native_cg/narrow_signext.ir"], "a restored narrow codegen fixture"),
    (["bench/fixtures/native_cg/rt_stub.c"], "the native runtime comparison stub"),
    (["src/compiler/native/rt/builtins.ir"], "the native IR runtime"),
    (["README.md", "src/compiler/native/rt/builtins.ir"], "a mixed documentation and native IR change"),
]:
    reason, jobs = planned(*files)
    check(f"{what} selects all three hosts and native Linux arm64 execution",
          {"selfhost", "selfhost-darwin", "selfhost-windows", "selfhost-linux-arm64"} <= jobs,
          f"{reason}: {sorted(jobs)}")

reason, jobs = planned("src/iyi/string.iyi")
check("an ordinary prelude change does not select component-only jobs",
      not {"selfhost", "selfhost-darwin", "selfhost-windows", "selfhost-linux-arm64"} & jobs,
      f"{reason}: {sorted(jobs)}")

print()
print("== a workflow and a bench directory of this exercise's own")

spec = importlib.util.spec_from_file_location("ci_plan_under_test", PLANNER)
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)

# Execute the workflow's result command: selected jobs must have actually run.
actual_jobs = planner.parse_jobs((ROOT / ".github" / "workflows" / "iyi.yml").read_text(encoding="utf-8"))
result_lines = actual_jobs["result"]["text"].splitlines()
command_lines = []
for line in result_lines[result_lines.index("        run: |") + 1:]:
    if line.strip() and not line.startswith("          "):
        break
    command_lines.append(line[10:])
result_command = "\n".join(command_lines)
for what, selected, verdicts, passes in [
    ("selected success permits unselected skips", ["probe"], {"probe": "success", "unused": "skipped"}, True),
    ("a selected skip blocks the result", ["probe"], {"probe": "skipped"}, False),
    ("a missing selected job blocks the result", ["probe"], {}, False),
    ("a skipped plan blocks the result", ["probe"], {"plan": "skipped", "probe": "success"}, False),
    ("an intentionally empty plan can pass", [], {"unused": "skipped"}, True),
]:
    results = {name: {"result": verdict} for name, verdict in verdicts.items()}
    results.setdefault("plan", {"result": "success"})["outputs"] = {"jobs": json.dumps(selected)}
    ran = subprocess.run(["bash", "-c", result_command], cwd=ROOT, capture_output=True, text=True,
                         env={**os.environ, "RESULTS": json.dumps(results)})
    check(what, (ran.returncode == 0) == passes, ran.stdout + ran.stderr)

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
