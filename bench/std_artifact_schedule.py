#!/usr/bin/env python3
"""Check the Windows artifact sweeps: helper fixtures, receipts, compiler payloads, and the workflow that runs them.

`fixtures`, `results`, `manifest` and `write-manifest` use only the standard
library. `workflow` needs PyYAML and is the only mode that reads the workflow.
"""

import argparse
import collections
import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHARDS = 4
TARGETS = ("aarch64-darwin", "x86_64-windows-msvc", "aarch64-linux-gnu", "x86_64-linux-musl")
EXEMPT = ("big", "gc", "time", "weak_ref")
SHA = re.compile(r"[0-9a-f]{64}\Z")
REV = re.compile(r"[0-9a-f]{40}\Z")
REVISION = "a" * 40
RUN_ID = "123"
COMPILER = "b" * 64

BUILD, CORE, ARTIFACTS, STABLE = "windows-std-build", "windows-std-core", "windows-std-artifacts", "windows-std"
STABLE_NAME = "The standard library foundation, gated on Windows"
BUILD_STEP = "Build the fork's compiler, then `iyi`"
BUILD_RUN = "make -f Makefile.win crystal || exit /b 1\nmake -f Makefile.win iyi"
PAYLOAD_STEP = "Publish the compiler payload and its manifest"
FOUNDATION_STEP = "The standard library's foundation, on Windows"
FOUNDATION_RUN = "bash bench/std_exercise.sh"
FOUNDATION_ENV = {"PYTHONUNBUFFERED": "1", "STD_SIBLINGS": "0", "STD_ARTIFACTS": "0"}
SHARD_STEP = "The artifact sweeps of this shard, on Windows"
NATIVE_RUN = 'bash bench/std_artifacts.sh native "${{ matrix.shard }}" 4 || failed=1'
CROSS_RUN = 'bash bench/std_artifacts.sh cross "${{ matrix.shard }}" 4 || failed=1'
SHARD_RUN = "failed=0\n" + NATIVE_RUN + "\n" + CROSS_RUN + '\nexit "$failed"'
SHA_EXPR = "${{ needs.windows-std-build.outputs.compiler-sha256 }}"
ATTEMPT_EXPR = "${{ needs.windows-std-build.outputs.attempt }}"
ARTIFACT_EXPR = "${{ needs.windows-std-build.outputs.compiler-artifact }}"
COMPILER_ARTIFACT = "std-windows-compiler-${{ github.run_id }}-${{ github.run_attempt }}"
SHARD_ENV = {
    "PYTHONUNBUFFERED": "1",
    "STD_ARTIFACT_REVISION": "${{ github.sha }}",
    "STD_ARTIFACT_RUN_ID": "${{ github.run_id }}",
    "STD_ARTIFACT_COMPILER_SHA256": SHA_EXPR,
    "STD_ARTIFACT_RECEIPT": "receipt-${{ matrix.shard }}.tsv",
}
AGGREGATE_STEP = "Every foundation part and every shard receipt"
AGGREGATE_ENV = {
    "RESULT_BUILD": "${{ needs.windows-std-build.result }}",
    "RESULT_CORE": "${{ needs.windows-std-core.result }}",
    "RESULT_ARTIFACTS": "${{ needs.windows-std-artifacts.result }}",
    "REVISION": "${{ github.sha }}",
    "RUN_ID": "${{ github.run_id }}",
    "COMPILER_SHA256": SHA_EXPR,
}
MANIFEST_MARK = "std_artifact_schedule.py manifest"
MANIFEST_FRAGMENTS = (
    "--manifest std-compiler/manifest.json --payload std-compiler",
    '--revision "${{ github.sha }}"',
    '--run-id "${{ github.run_id }}"',
    f'--attempt "{ATTEMPT_EXPR}"',
    f'--compiler-sha256 "{SHA_EXPR}"',
    "cp -R std-compiler/.build .",
)


class Invalid(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Invalid(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).digest()


def posix(path):
    # Git Bash takes forward slashes; a Windows backslash path is not a path to bash.
    return Path(path).as_posix()


def inventory(root):
    names = sorted((p.relative_to(root).as_posix() for p in (root / "bench").glob("std_*_exercise.iyi") if p.is_file()), key=lambda s: s.encode())
    require(names, "empty exercise inventory")
    return names


def expected(names, count):
    require(count > 0 and count <= len(names), "invalid shard count")
    return [(1 + i % count, name) for i, name in enumerate(names)]


def validate_plan(text, names, count):
    rows = []
    for line in text.splitlines():
        fields = line.split("\t")
        require(len(fields) == 2 and fields[0].isdigit(), "malformed plan row")
        rows.append((int(fields[0]), fields[1]))
    require(collections.Counter(rows) == collections.Counter(expected(names, count)), "plan does not match inventory and assignment")


def metadata(row, revision, run_id, compiler, count):
    require(len(row) == 6 and row[0] == "meta", "malformed receipt metadata")
    require(row[1:4] == [revision, run_id, compiler], "receipt identity mismatch")
    require(row[4].isdigit() and row[5].isdigit(), "malformed shard numbers")
    shard, total = int(row[4]), int(row[5])
    require(total == count and 1 <= shard <= count, "receipt shard mismatch")
    return shard


def receipts(paths, names, revision, run_id, compiler, count):
    require(REV.fullmatch(revision) and SHA.fullmatch(compiler) and run_id.isdigit(), "invalid expected identity")
    require(len(paths) == count, "missing or extra receipts")
    assigned = expected(names, count)
    shards = set()
    seen = collections.Counter()
    for path in paths:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
        require(lines, "empty receipt")
        shard = metadata(lines[0].split("\t"), revision, run_id, compiler, count)
        require(shard not in shards, "duplicate shard receipt")
        shards.add(shard)
        owned = {source for index, source in assigned if index == shard}
        for line in lines[1:]:
            row = line.split("\t")
            require(len(row) == 8 and row[0] == "unit", "malformed unit receipt")
            _, phase, target, source, verdict, source_status, artifact_status, elapsed = row
            require(source in owned and verdict == "success", "failed or unassigned unit")
            require(phase in ("native", "cross"), "unknown phase")
            require((phase == "native" and target == "host") or (phase == "cross" and target in TARGETS), "unknown target")
            require(source_status == "-" or source_status.isdigit(), "invalid source status")
            require(artifact_status == "-" or artifact_status.isdigit(), "invalid artifact status")
            require(re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", elapsed), "invalid elapsed time")
            if phase == "native":
                require(source_status.isdigit() and artifact_status == source_status, "native exit status mismatch")
            seen[(phase, target, source)] += 1
    want = collections.Counter((phase, target, source) for source in names for phase, targets in (("native", ("host",)), ("cross", TARGETS)) for target in targets)
    require(seen == want, "receipt unit inventory mismatch")


def manifest(path, payload, revision, run_id, attempt, compiler=None):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    require(isinstance(data, dict) and set(data) == {"schema", "revision", "run_id", "attempt", "platform", "files"}, "malformed manifest")
    require(data["schema"] == 1 and type(data["schema"]) is int, "unknown manifest schema")
    require(data["revision"] == revision and REV.fullmatch(revision), "manifest revision mismatch")
    require(str(data["run_id"]) == run_id and run_id.isdigit(), "manifest run mismatch")
    require(str(data["attempt"]) == attempt and attempt.isdigit() and int(attempt) > 0, "manifest producer attempt mismatch")
    require(data["platform"] == "windows-x86_64", "manifest platform mismatch")
    files = data["files"]
    require(isinstance(files, dict) and files, "missing manifest files")
    require({".build/iyi.exe", ".build/iyi.pdb", ".build/LLVM-C.dll"} <= set(files), "missing compiler payload dependency")
    if compiler is not None:
        require(SHA.fullmatch(compiler) and files[".build/iyi.exe"] == compiler, "compiler hash does not match the manifest")
    root = Path(payload).resolve()
    for name, value in files.items():
        require(isinstance(name, str) and re.fullmatch(r"\.build/[^/\\]+", name), "invalid payload path")
        require(isinstance(value, str) and SHA.fullmatch(value), "invalid payload digest")
        file = root / name
        require(file.is_file() and not file.is_symlink(), "missing or unsafe payload file")
        require(hashlib.sha256(file.read_bytes()).hexdigest() == value, "payload hash mismatch")
    actual = {p.relative_to(root).as_posix() for p in (root / ".build").glob("*.dll")}
    require(actual <= set(files), "unmanifested DLL")


def write_manifest(payload, revision, run_id, attempt, output):
    require(REV.fullmatch(revision) and run_id.isdigit() and attempt.isdigit() and int(attempt) > 0, "invalid manifest identity")
    root = Path(payload)
    names = [".build/iyi.exe", ".build/iyi.pdb"] + sorted(".build/" + p.name for p in (root / ".build").glob("*.dll"))
    require(".build/LLVM-C.dll" in names, "missing LLVM-C.dll payload")
    files = {}
    for name in names:
        file = root / name
        require(file.is_file() and not file.is_symlink(), "missing payload file: " + name)
        files[name] = hashlib.sha256(file.read_bytes()).hexdigest()
    document = {"schema": 1, "revision": revision, "run_id": run_id, "attempt": int(attempt), "platform": "windows-x86_64", "files": files}
    Path(output).write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return files[".build/iyi.exe"]


def run_helper(root, *args, env=None):
    return subprocess.run(["bash", posix(root / "bench/std_artifacts.sh"), *map(str, args)], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def reject(fn, label):
    try:
        fn()
    except (Invalid, OSError, ValueError, KeyError, TypeError):
        return
    raise Invalid("negative control accepted: " + label)


def fixture_checks(root):
    helper = root / "bench/std_artifacts.sh"
    filter_file = root / "bench/darwin_frames.sh"
    before = {p: digest(p) for p in (helper, filter_file, Path(__file__))}
    with tempfile.TemporaryDirectory(prefix="iyi-artifact-check-") as temporary:
        repo = Path(temporary)
        bench = repo / "bench"
        bench.mkdir()
        shutil.copy2(helper, bench / helper.name)
        shutil.copy2(filter_file, bench / filter_file.name)
        exercises = ["alpha", "beta", "later", *EXEMPT]
        for name in exercises:
            (bench / f"std_{name}_exercise.iyi").write_text("fixture\n", encoding="utf-8")
        names = inventory(repo)
        plan = run_helper(repo, "--plan", 4)
        require(plan.returncode == 0, "helper rejected valid plan: " + plan.stdout)
        validate_plan(plan.stdout, names, 4)
        rows = plan.stdout.splitlines()
        for altered in (rows[:-1], rows + rows[:1], rows + ["1\tbench/std_unknown_exercise.iyi"], ["bad"]):
            reject(lambda: validate_plan("\n".join(altered), names, 4), "malformed or incomplete plan")
        (bench / "std_new_exercise.iyi").write_text("new\n", encoding="utf-8")
        expanded = run_helper(repo, "--plan", 4)
        require(expanded.returncode == 0, "helper rejected expanded inventory")
        validate_plan(expanded.stdout, inventory(repo), 4)
        reject(lambda: validate_plan(plan.stdout, inventory(repo), 4), "new source omitted")
        (bench / "std_new_exercise.iyi").unlink()
        for arguments in (("--plan", "0"), ("native", "0", "4"), ("native", "5", "4"), ("cross", "x", "4"), ("--plan", "99")):
            require(run_helper(repo, *arguments).returncode != 0, "helper accepted invalid indices: " + repr(arguments))
        empty = repo / "empty"
        (empty / "bench").mkdir(parents=True)
        shutil.copy2(helper, empty / "bench/std_artifacts.sh")
        shutil.copy2(filter_file, empty / "bench/darwin_frames.sh")
        require(run_helper(empty, "--plan", 1).returncode != 0, "helper accepted empty inventory")
        compiler = repo / "fake-compiler"
        compiler.write_text(FAKE_COMPILER, encoding="utf-8")
        compiler.chmod(0o755)
        env = os.environ.copy()
        env.update(IYI=posix(compiler), STD_ARTIFACT_REVISION=REVISION, STD_ARTIFACT_RUN_ID=RUN_ID, STD_ARTIFACT_COMPILER_SHA256=COMPILER, STD_ARTIFACT_RECEIPT=posix(repo / "receipt"), FAKE_LOG=posix(repo / "calls"))
        for phase in ("native", "cross"):
            result = run_helper(repo, phase, 1, 1, env=env)
            require(result.returncode == 0, "fixture execution failed: " + result.stdout)
        receipts([repo / "receipt"], names, REVISION, RUN_ID, COMPILER, 1)
        original_receipt = (repo / "receipt").read_text(encoding="utf-8").splitlines()
        cross_rows = [row for row in original_receipt if row.startswith("unit\tcross\t")]
        require(cross_rows, "missing cross execution rows")
        altered_path = repo / "altered"
        for rows in (
            [row for row in original_receipt if row != cross_rows[0]],
            original_receipt + [cross_rows[0]],
            [row.replace(REVISION, "c" * 40) for row in original_receipt],
            [row.replace(COMPILER, "c" * 64) for row in original_receipt],
            [original_receipt[0]],
        ):
            altered_path.write_text("\n".join(rows) + "\n", encoding="utf-8")
            reject(lambda: receipts([altered_path], names, REVISION, RUN_ID, COMPILER, 1), "invalid receipt")
        shard_paths = []
        for shard in range(1, SHARDS + 1):
            path = repo / ("receipt-" + str(shard))
            shard_paths.append(path)
            env["STD_ARTIFACT_RECEIPT"] = posix(path)
            for phase in ("native", "cross"):
                result = run_helper(repo, phase, shard, SHARDS, env=env)
                require(result.returncode == 0, "sharded execution failed: " + result.stdout)
        receipts(shard_paths, names, REVISION, RUN_ID, COMPILER, SHARDS)
        reject(lambda: receipts(shard_paths[:-1], names, REVISION, RUN_ID, COMPILER, SHARDS), "missing shard")
        reject(lambda: receipts(shard_paths[:-1] + [shard_paths[0]], names, REVISION, RUN_ID, COMPILER, SHARDS), "duplicate shard")
        env["STD_ARTIFACT_RECEIPT"] = posix(repo / "receipt")
        payload = repo / "payload"
        (payload / ".build").mkdir(parents=True)
        files = {}
        for name in ("iyi.exe", "iyi.pdb", "LLVM-C.dll"):
            file = payload / ".build" / name
            file.write_bytes(name.encode())
            files[".build/" + name] = hashlib.sha256(file.read_bytes()).hexdigest()
        document = {"schema": 1, "revision": REVISION, "run_id": RUN_ID, "attempt": "1", "platform": "windows-x86_64", "files": files}
        manifest_file = repo / "manifest.json"

        def save_manifest(value):
            manifest_file.write_text(json.dumps(value), encoding="utf-8")

        save_manifest(document)
        manifest(manifest_file, payload, REVISION, RUN_ID, "1")
        manifest(manifest_file, payload, REVISION, RUN_ID, "1", files[".build/iyi.exe"])
        reject(lambda: manifest(manifest_file, payload, REVISION, RUN_ID, "1", "c" * 64), "compiler hash mismatch")
        reject(lambda: manifest(manifest_file, payload, "c" * 40, RUN_ID, "1"), "stale compiler revision")
        reject(lambda: manifest(manifest_file, payload, REVISION, "124", "1"), "stale compiler run")
        reject(lambda: manifest(manifest_file, payload, REVISION, RUN_ID, "2"), "wrong producer attempt")
        incomplete = dict(document)
        incomplete["files"] = {key: value for key, value in files.items() if key != ".build/LLVM-C.dll"}
        save_manifest(incomplete)
        reject(lambda: manifest(manifest_file, payload, REVISION, RUN_ID, "1"), "missing DLL metadata")
        save_manifest(document)
        (payload / ".build/LLVM-C.dll").unlink()
        reject(lambda: manifest(manifest_file, payload, REVISION, RUN_ID, "1"), "missing DLL payload")
        (payload / ".build/LLVM-C.dll").write_bytes(b"altered")
        reject(lambda: manifest(manifest_file, payload, REVISION, RUN_ID, "1"), "altered payload")
        # The producer's writer must agree with the consumer's verifier on a real layout.
        (payload / ".build/LLVM-C.dll").write_bytes(b"LLVM-C.dll")
        written = repo / "written.json"
        require(write_manifest(payload, REVISION, RUN_ID, "1", written) == files[".build/iyi.exe"], "writer disagrees with the compiler hash")
        manifest(written, payload, REVISION, RUN_ID, "1", files[".build/iyi.exe"])
        calls = (repo / "calls").read_text(encoding="utf-8")
        require("--emit-iyimod" in calls and "--use-iyimod" in calls and all(t in calls for t in TARGETS), "missing fake compiler calls")
        for failure in ("emit", "consume", "exit", "output"):
            (repo / "receipt").unlink(missing_ok=True)
            (repo / "calls").unlink(missing_ok=True)
            env["FAKE_FAILURE"] = failure
            result = run_helper(repo, "native", 1, 1, env=env)
            require(result.returncode != 0, "injected " + failure + " was accepted")
            require("std_later_exercise.iyi" in (repo / "calls").read_text(encoding="utf-8"), "failure stopped later units")
            if failure in ("emit", "consume"):
                (repo / "receipt").unlink(missing_ok=True)
                (repo / "calls").unlink(missing_ok=True)
                result = run_helper(repo, "cross", 1, 1, env=env)
                require(result.returncode != 0, "cross injected " + failure + " was accepted")
                require("std_later_exercise.iyi" in (repo / "calls").read_text(encoding="utf-8"), "cross failure stopped later units")
        env.pop("FAKE_FAILURE", None)
        # Every explicit exemption must allow differing output, not exit mismatch.
        for exemption in EXEMPT:
            (repo / "receipt").unlink(missing_ok=True)
            env["FAKE_EXEMPT"] = exemption
            result = run_helper(repo, "native", 1, 1, env=env)
            require(result.returncode == 0, "exemption failed: " + exemption + " " + result.stdout)
        env.pop("FAKE_EXEMPT", None)
        env["FAKE_NONZERO"] = "1"
        (repo / "receipt").unlink(missing_ok=True)
        require(run_helper(repo, "native", 1, 1, env=env).returncode == 0, "matching nonzero status rejected")
        frame = subprocess.run(["bash", "-c", '. "$1"; without_frames', "_", posix(filter_file)], input=b'0   program  0x000000010299550c symbol + 1\n4   program  0x12ab keep\nnonframe \xff\n', stdout=subprocess.PIPE, check=True)
        require(frame.stdout == b'4   program  0x12ab keep\nnonframe \xff\n', "frame filter lost nonframes or bytes")
    require(all(digest(p) == value for p, value in before.items()), "checker changed inspected source")


FAKE_COMPILER = r'''#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
source="${@: -1}"
case "$*" in *--emit-iyimod*) stage=emit;; *--use-iyimod*) stage=consume;; *) exit 22;; esac
if [[ "${FAKE_FAILURE:-}" == "$stage" && "$source" == *std_alpha_exercise.iyi ]]; then exit 11; fi
case "$*" in *--no-codegen*) exit 0;; esac
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then shift; out="$1"; break; fi
  shift
done
[ -n "$out" ] || exit 23
value=same
code=0
if [[ "$stage" == consume && "$source" == *std_alpha_exercise.iyi ]]; then
  [ "${FAKE_FAILURE:-}" = output ] && value=different
  [ "${FAKE_FAILURE:-}" = exit ] && code=7
fi
if [[ "$stage" == consume && -n "${FAKE_EXEMPT:-}" && "$source" == *std_${FAKE_EXEMPT}_exercise.iyi ]]; then value=different; fi
[ "${FAKE_NONZERO:-}" = 1 ] && code=7
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit %s\n' "$value" "$code" > "$out"
chmod +x "$out"
'''


def named(steps, name):
    matches = [step for step in steps if step.get("name") == name]
    require(len(matches) == 1, f"{name}: expected exactly one step, found {len(matches)}")
    return matches[0]


def run_of(step):
    return str(step.get("run", "")).strip()


def uses_of(job, prefix):
    return [step for step in job.get("steps", []) if str(step.get("uses", "")).startswith(prefix)]


def needs_of(job):
    value = job.get("needs", [])
    return [value] if isinstance(value, str) else list(value)


def check_consumer(name, job):
    require(len(uses_of(job, "ilammy/msvc-dev-cmd@")) == 1, f"{name}: MSVC environment")
    crystal = uses_of(job, "crystal-lang/install-crystal@")
    require(len(crystal) == 1 and crystal[0].get("with", {}).get("crystal") == "1.21.0", f"{name}: bootstrap toolchain")
    require(len(uses_of(job, "actions/setup-python@")) == 1, f"{name}: python3")
    download = uses_of(job, "actions/download-artifact@")
    require(len(download) == 1 and download[0].get("with", {}).get("name") == ARTIFACT_EXPR and download[0].get("with", {}).get("path") == "std-compiler", f"{name}: compiler download")
    manifests = [step for step in job.get("steps", []) if MANIFEST_MARK in run_of(step)]
    require(len(manifests) == 1, f"{name}: manifest verification")
    for fragment in MANIFEST_FRAGMENTS:
        require(fragment in manifests[0]["run"], f"{name}: manifest verification lacks {fragment!r}")
    require(not any("make -f Makefile.win" in run_of(step) for step in job.get("steps", [])), f"{name}: consumer builds the compiler")


def check_workflow(workflow):
    """Check the Windows topology and return the stable aggregate's shell body."""
    jobs = workflow["jobs"]
    for name in (BUILD, CORE, ARTIFACTS, STABLE):
        require(name in jobs, f"{name}: missing job")
    build, core, artifacts, stable = jobs[BUILD], jobs[CORE], jobs[ARTIFACTS], jobs[STABLE]
    require(build.get("runs-on") == "windows-2025", "compiler producer runner")
    require(core.get("runs-on") == "windows-2025", "foundation core runner")
    require(artifacts.get("runs-on") == "windows-2025", "artifact shard runner")
    require(stable.get("runs-on") == "ubuntu-24.04", "stable aggregate must validate on Ubuntu")
    require(stable.get("name") == STABLE_NAME, "stable check name")
    require(stable.get("if") == "${{ always() }}", "stable aggregate must run always()")
    require("needs" not in build, "compiler producer has needs")
    require(needs_of(core) == [BUILD], "foundation core needs")
    require(needs_of(artifacts) == [BUILD], "artifact shards need")
    require(sorted(needs_of(stable)) == sorted([BUILD, CORE, ARTIFACTS]), "stable aggregate needs")
    require(STABLE in jobs["release"].get("needs", []), "release does not need windows-std")
    for name in (BUILD, CORE, ARTIFACTS, STABLE):
        job = jobs[name]
        require(not job.get("continue-on-error"), f"{name}: continue-on-error")
        for step in job.get("steps", []):
            require("continue-on-error" not in step, f"{name}: step continue-on-error")
            if str(step.get("uses", "")).startswith("actions/checkout@"):
                with_ = step.get("with", {})
                require("ref" not in with_, f"{name}: checkout names another ref")
                require(with_.get("persist-credentials") is False, f"{name}: checkout keeps credentials")
    strategy = artifacts.get("strategy") or {}
    require(strategy.get("fail-fast") is False, "artifact shards must not fail fast")
    require(strategy.get("matrix") == {"shard": [1, 2, 3, 4]}, "artifact shard matrix")

    build_step = named(build["steps"], BUILD_STEP)
    require(build_step.get("shell") == "cmd" and run_of(build_step) == BUILD_RUN, "compiler build commands")
    payload = named(build["steps"], PAYLOAD_STEP)
    require(payload.get("id") == "payload" and payload.get("shell") == "bash", "payload step identity")
    for fragment in ("cp .build/iyi.exe .build/iyi.pdb std-compiler/.build/", "cp .build/*.dll std-compiler/.build/", "write-manifest --payload std-compiler", "--output std-compiler/manifest.json", '>> "$GITHUB_OUTPUT"'):
        require(fragment in run_of(payload), f"payload lacks {fragment!r}")
    uploads = uses_of(build, "actions/upload-artifact@")
    require(len(uploads) == 1 and uploads[0].get("with", {}).get("name") == COMPILER_ARTIFACT and uploads[0].get("with", {}).get("path") == "std-compiler" and uploads[0].get("with", {}).get("include-hidden-files") is True, "compiler payload upload")
    require(build.get("outputs") == {"compiler-artifact": COMPILER_ARTIFACT, "compiler-sha256": "${{ steps.payload.outputs.compiler-sha256 }}", "attempt": "${{ github.run_attempt }}"}, "compiler outputs")

    foundation = named(core["steps"], FOUNDATION_STEP)
    require(run_of(foundation) == FOUNDATION_RUN and foundation.get("env") == FOUNDATION_ENV, "foundation core invocation")
    require(sum(run_of(step) == "python3 bench/std_artifact_schedule.py fixtures" for step in core["steps"]) == 1, "fixture check on Windows")
    require(not any("std_artifacts.sh" in run_of(step) for step in core["steps"]), "core runs the artifact sweeps")
    check_consumer(CORE, core)

    shard = named(artifacts["steps"], SHARD_STEP)
    require(run_of(shard) == SHARD_RUN, "artifact shard phases or failure accumulation")
    require(shard.get("env") == SHARD_ENV, "artifact shard environment")
    receipt_uploads = uses_of(artifacts, "actions/upload-artifact@")
    require(len(receipt_uploads) == 1 and receipt_uploads[0].get("if") == "${{ always() }}" and receipt_uploads[0].get("with", {}).get("name") == "std-artifact-receipt-${{ matrix.shard }}" and receipt_uploads[0].get("with", {}).get("path") == "receipt-${{ matrix.shard }}.tsv" and receipt_uploads[0].get("with", {}).get("overwrite") is True, "artifact shard receipt upload")
    check_consumer(ARTIFACTS, artifacts)

    aggregate = named(stable["steps"], AGGREGATE_STEP)
    require(aggregate.get("shell") == "bash" and aggregate.get("env") == AGGREGATE_ENV, "stable aggregate inputs")
    downloads = uses_of(stable, "actions/download-artifact@")
    require(len(downloads) == 1 and downloads[0].get("with") == {"pattern": "std-artifact-receipt-*", "path": "receipts"}, "stable aggregate receipts")

    sweeps = [name for name, job in jobs.items() if str(job.get("runs-on", "")).startswith("windows") for step in job.get("steps", []) if "bench/std_exercise.sh" in run_of(step)]
    require(sweeps == [CORE], f"Windows foundation invocations: {sweeps}")
    settings = [(name, step["env"]["STD_ARTIFACTS"]) for name, job in jobs.items() for step in job.get("steps", []) if "STD_ARTIFACTS" in step.get("env", {})]
    require(settings == [(CORE, "0")], f"STD_ARTIFACTS settings: {settings}")
    wired = [name for name, job in jobs.items() if any("windows_gate_schedule.py" in run_of(step) for step in job.get("steps", []))]
    require(len(wired) == 1 and any("std_artifact_schedule.py workflow" in run_of(step) for step in jobs[wired[0]]["steps"]), "workflow check is not wired beside the Windows gate contract")
    return run_of(aggregate)


def mutations():
    def step(w, job, title):
        return named(w["jobs"][job]["steps"], title)

    def uses_step(w, job, prefix):
        matches = uses_of(w["jobs"][job], prefix)
        require(len(matches) == 1, f"{job}: expected one {prefix} step")
        return matches[0]

    def drop_manifest(w):
        w["jobs"][ARTIFACTS]["steps"] = [s for s in w["jobs"][ARTIFACTS]["steps"] if MANIFEST_MARK not in run_of(s)]

    def unwire(w):
        for job in w["jobs"].values():
            for s in job.get("steps", []):
                if "std_artifact_schedule.py workflow" in run_of(s):
                    s["run"] = "true"

    return {
        "shard omitted": lambda w: w["jobs"][ARTIFACTS]["strategy"]["matrix"].update({"shard": [1, 2, 3]}),
        "cross phase omitted": lambda w: step(w, ARTIFACTS, SHARD_STEP).update({"run": NATIVE_RUN + '\nexit "$failed"'}),
        "failure masked": lambda w: step(w, ARTIFACTS, SHARD_STEP).update({"run": SHARD_RUN.replace("|| failed=1", "|| true", 1)}),
        "shard continue-on-error": lambda w: w["jobs"][ARTIFACTS].update({"continue-on-error": True}),
        "shard runner moved": lambda w: w["jobs"][ARTIFACTS].update({"runs-on": "ubuntu-24.04"}),
        "shards fail fast": lambda w: w["jobs"][ARTIFACTS]["strategy"].update({"fail-fast": True}),
        "core checks out another ref": lambda w: uses_step(w, CORE, "actions/checkout@")["with"].update({"ref": "main"}),
        "core rebuilds the compiler": lambda w: w["jobs"][CORE]["steps"].append({"name": "rebuild", "shell": "cmd", "run": "make -f Makefile.win iyi"}),
        "core runs the sweeps": lambda w: step(w, CORE, FOUNDATION_STEP).update({"env": {**FOUNDATION_ENV, "STD_ARTIFACTS": "1"}}),
        "payload unverified": drop_manifest,
        "compiler hash unpublished": lambda w: w["jobs"][BUILD]["outputs"].pop("compiler-sha256"),
        "receipt overwrite dropped": lambda w: uses_step(w, ARTIFACTS, "actions/upload-artifact@")["with"].pop("overwrite"),
        "stable drops a shard": lambda w: w["jobs"][STABLE]["needs"].remove(ARTIFACTS),
        "stable not always": lambda w: w["jobs"][STABLE].pop("if"),
        "stable masks failure": lambda w: w["jobs"][STABLE].update({"continue-on-error": True}),
        "stable renamed": lambda w: w["jobs"][STABLE].update({"name": "gated"}),
        "release dependency removed": lambda w: w["jobs"]["release"]["needs"].remove(STABLE),
        "build flags changed": lambda w: step(w, BUILD, BUILD_STEP).update({"run": BUILD_RUN.replace("iyi", "iyi --debug", 1)}),
        "workflow check unwired": unwire,
    }


def aggregate_checks(body):
    """Run the workflow's own stable-gate body against synthetic receipts."""
    with tempfile.TemporaryDirectory(prefix="iyi-artifact-gate-") as temporary:
        base = Path(temporary)

        def fixture(label):
            root = base / label
            (root / "bench").mkdir(parents=True)
            shutil.copy2(Path(__file__), root / "bench/std_artifact_schedule.py")
            for item in ("alpha", "beta", "later", *EXEMPT):
                (root / "bench" / f"std_{item}_exercise.iyi").write_text("fixture\n", encoding="utf-8")
            write_receipts(root, inventory(root))
            return root

        def gate(root, **changes):
            env = dict(os.environ)
            env.update(RESULT_BUILD="success", RESULT_CORE="success", RESULT_ARTIFACTS="success", REVISION=REVISION, RUN_ID=RUN_ID, COMPILER_SHA256=COMPILER)
            env.update(changes)
            return subprocess.run(["bash", "-e", "-o", "pipefail", "-c", body], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).returncode

        require(gate(fixture("complete")) == 0, "aggregate rejected complete receipts")
        for key in ("RESULT_BUILD", "RESULT_CORE", "RESULT_ARTIFACTS"):
            for state in ("failure", "cancelled", "skipped", "", "unknown"):
                require(gate(fixture(f"{key}-{state or 'empty'}"), **{key: state}) != 0, f"aggregate accepted {key}={state!r}")
        root = fixture("missing")
        shutil.rmtree(root / "receipts" / f"std-artifact-receipt-{SHARDS}")
        require(gate(root) != 0, "aggregate accepted a missing shard receipt")
        root = fixture("duplicate")
        shutil.copytree(root / "receipts" / "std-artifact-receipt-1", root / "receipts" / "std-artifact-receipt-9")
        require(gate(root) != 0, "aggregate accepted a duplicate shard receipt")
        root = fixture("failed-unit")
        target = root / "receipts" / "std-artifact-receipt-2" / "receipt-2.tsv"
        target.write_text(target.read_text(encoding="utf-8").replace("\tsuccess\t", "\tfailure\t", 1), encoding="utf-8")
        require(gate(root) != 0, "aggregate accepted a failed unit")
        require(gate(fixture("run"), RUN_ID="124") != 0, "aggregate accepted another run's receipts")
        require(gate(fixture("compiler"), COMPILER_SHA256="c" * 64) != 0, "aggregate accepted another compiler")
        require(gate(fixture("revision"), REVISION="c" * 40) != 0, "aggregate accepted another revision")


def write_receipts(root, names, revision=REVISION, run_id=RUN_ID, compiler=COMPILER):
    assigned = expected(names, SHARDS)
    for shard in range(1, SHARDS + 1):
        folder = root / "receipts" / f"std-artifact-receipt-{shard}"
        folder.mkdir(parents=True, exist_ok=True)
        rows = [f"meta\t{revision}\t{run_id}\t{compiler}\t{shard}\t{SHARDS}"]
        for index, source in assigned:
            if index == shard:
                rows.append(f"unit\tnative\thost\t{source}\tsuccess\t0\t0\t1")
                rows.extend(f"unit\tcross\t{target}\t{source}\tsuccess\t-\t-\t1" for target in TARGETS)
        (folder / f"receipt-{shard}.tsv").write_text("\n".join(rows) + "\n", encoding="utf-8")


def workflow_checks(root):
    import yaml  # PyYAML is needed only here; the other modes stay standard library.

    path = root / ".github/workflows/iyi.yml"
    sources = {path: digest(path), Path(__file__): digest(Path(__file__))}
    workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
    body = check_workflow(workflow)
    for label, change in mutations().items():
        changed = copy.deepcopy(workflow)
        change(changed)
        reject(lambda: check_workflow(changed), label)
    aggregate_checks(body)
    require(all(digest(p) == value for p, value in sources.items()), "checker changed inspected source")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name, help_text in (("fixtures", "run the real helper against fake compilers"), ("workflow", "check the Windows topology, its mutations and the stable gate body")):
        command = sub.add_parser(name, help=help_text)
        command.add_argument("--root", type=Path, default=ROOT)
    result = sub.add_parser("results", help="verify completed shard receipts")
    result.add_argument("--root", type=Path, default=ROOT)
    result.add_argument("--revision", required=True)
    result.add_argument("--run-id", required=True)
    result.add_argument("--compiler-sha256", required=True)
    result.add_argument("--count", type=int, required=True)
    result.add_argument("receipts", nargs="+")
    compiler = sub.add_parser("manifest", help="verify a same-run compiler payload")
    compiler.add_argument("--manifest", type=Path, required=True)
    compiler.add_argument("--payload", type=Path, required=True)
    compiler.add_argument("--revision", required=True)
    compiler.add_argument("--run-id", required=True)
    compiler.add_argument("--attempt", required=True)
    compiler.add_argument("--compiler-sha256")
    writer = sub.add_parser("write-manifest", help="write a compiler payload's manifest and print its compiler hash")
    writer.add_argument("--payload", type=Path, required=True)
    writer.add_argument("--revision", required=True)
    writer.add_argument("--run-id", required=True)
    writer.add_argument("--attempt", required=True)
    writer.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "write-manifest":
        print(write_manifest(str(args.payload), args.revision, args.run_id, args.attempt, args.output))
        return
    if args.command == "fixtures":
        fixture_checks(args.root)
    elif args.command == "workflow":
        workflow_checks(args.root)
    elif args.command == "results":
        receipts(args.receipts, inventory(args.root.resolve()), args.revision, args.run_id, args.compiler_sha256, args.count)
    else:
        manifest(args.manifest, args.payload, args.revision, args.run_id, args.attempt, args.compiler_sha256)
    print(args.command + ": passed")


if __name__ == "__main__":
    try:
        main()
    except (Invalid, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("artifact schedule: " + str(error), file=sys.stderr)
        sys.exit(1)
