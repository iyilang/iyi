#!/usr/bin/env python3
"""Check artifact sweep assignments, execution receipts, and Windows routing."""

import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TARGETS = ("aarch64-darwin", "x86_64-windows-msvc", "aarch64-linux-gnu", "x86_64-linux-musl")
EXEMPT = ("big", "gc", "time", "weak_ref")
SHA = re.compile(r"[0-9a-f]{64}\Z")
REV = re.compile(r"[0-9a-f]{40}\Z")


class Invalid(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Invalid(message)


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


def manifest(path, payload, revision, run_id, attempt):
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
    root = Path(payload).resolve()
    for name, digest in files.items():
        require(isinstance(name, str) and re.fullmatch(r"\.build/[^/\\]+", name), "invalid payload path")
        require(isinstance(digest, str) and SHA.fullmatch(digest), "invalid payload digest")
        file = root / name
        require(file.is_file() and not file.is_symlink(), "missing or unsafe payload file")
        require(hashlib.sha256(file.read_bytes()).hexdigest() == digest, "payload hash mismatch")
    actual = {p.relative_to(root).as_posix() for p in (root / ".build").glob("*.dll")}
    require(actual <= set(files), "unmanifested DLL")


def run_helper(root, *args, env=None):
    return subprocess.run(["bash", str(root / "bench/std_artifacts.sh"), *map(str, args)], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def reject(fn, label):
    try:
        fn()
    except (Invalid, OSError, ValueError, KeyError, TypeError):
        return
    raise Invalid("negative control accepted: " + label)


def fixture_checks(root):
    helper = root / "bench/std_artifacts.sh"
    filter_file = root / "bench/darwin_frames.sh"
    before = {p: hashlib.sha256(p.read_bytes()).digest() for p in (helper, filter_file, Path(__file__))}
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
        env.update(IYI=str(compiler), STD_ARTIFACT_REVISION="a" * 40, STD_ARTIFACT_RUN_ID="123", STD_ARTIFACT_COMPILER_SHA256="b" * 64, STD_ARTIFACT_RECEIPT=str(repo / "receipt"), FAKE_LOG=str(repo / "calls"))
        for phase in ("native", "cross"):
            result = run_helper(repo, phase, 1, 1, env=env)
            require(result.returncode == 0, "fixture execution failed: " + result.stdout)
        receipts([repo / "receipt"], names, "a" * 40, "123", "b" * 64, 1)
        original_receipt = (repo / "receipt").read_text(encoding="utf-8").splitlines()
        cross_rows = [row for row in original_receipt if row.startswith("unit\tcross\t")]
        require(cross_rows, "missing cross execution rows")
        altered_path = repo / "altered"
        for rows in (
            [row for row in original_receipt if row != cross_rows[0]],
            original_receipt + [cross_rows[0]],
            [row.replace("a" * 40, "c" * 40) for row in original_receipt],
            [row.replace("b" * 64, "c" * 64) for row in original_receipt],
            [original_receipt[0]],
        ):
            altered_path.write_text("\n".join(rows) + "\n", encoding="utf-8")
            reject(lambda: receipts([altered_path], names, "a" * 40, "123", "b" * 64, 1), "invalid receipt")
        shard_paths = []
        for shard in range(1, 5):
            path = repo / ("receipt-" + str(shard))
            shard_paths.append(path)
            env["STD_ARTIFACT_RECEIPT"] = str(path)
            for phase in ("native", "cross"):
                result = run_helper(repo, phase, shard, 4, env=env)
                require(result.returncode == 0, "sharded execution failed: " + result.stdout)
        receipts(shard_paths, names, "a" * 40, "123", "b" * 64, 4)
        reject(lambda: receipts(shard_paths[:-1], names, "a" * 40, "123", "b" * 64, 4), "missing shard")
        reject(lambda: receipts(shard_paths[:-1] + [shard_paths[0]], names, "a" * 40, "123", "b" * 64, 4), "duplicate shard")
        env["STD_ARTIFACT_RECEIPT"] = str(repo / "receipt")
        payload = repo / "payload"
        (payload / ".build").mkdir(parents=True)
        files = {}
        for name in ("iyi.exe", "iyi.pdb", "LLVM-C.dll"):
            file = payload / ".build" / name
            file.write_bytes(name.encode())
            files[".build/" + name] = hashlib.sha256(file.read_bytes()).hexdigest()
        document = {"schema": 1, "revision": "a" * 40, "run_id": "123", "attempt": "1", "platform": "windows-x86_64", "files": files}
        manifest_file = repo / "manifest.json"
        def save_manifest(value):
            manifest_file.write_text(json.dumps(value), encoding="utf-8")
        save_manifest(document)
        manifest(manifest_file, payload, "a" * 40, "123", "1")
        reject(lambda: manifest(manifest_file, payload, "c" * 40, "123", "1"), "stale compiler revision")
        reject(lambda: manifest(manifest_file, payload, "a" * 40, "124", "1"), "stale compiler run")
        reject(lambda: manifest(manifest_file, payload, "a" * 40, "123", "2"), "wrong producer attempt")
        incomplete = dict(document)
        incomplete["files"] = {key: value for key, value in files.items() if key != ".build/LLVM-C.dll"}
        save_manifest(incomplete)
        reject(lambda: manifest(manifest_file, payload, "a" * 40, "123", "1"), "missing DLL metadata")
        save_manifest(document)
        (payload / ".build/LLVM-C.dll").unlink()
        reject(lambda: manifest(manifest_file, payload, "a" * 40, "123", "1"), "missing DLL payload")
        (payload / ".build/LLVM-C.dll").write_bytes(b"altered")
        reject(lambda: manifest(manifest_file, payload, "a" * 40, "123", "1"), "altered payload")
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
        frame = subprocess.run(["bash", "-c", '. "$1"; without_frames', "_", str(filter_file)], input=b'0   program  0x000000010299550c symbol + 1\n4   program  0x12ab keep\nnonframe \xff\n', stdout=subprocess.PIPE, check=True)
        require(frame.stdout == b'4   program  0x12ab keep\nnonframe \xff\n', "frame filter lost nonframes or bytes")
    require(all(hashlib.sha256(p.read_bytes()).digest() == value for p, value in before.items()), "checker changed inspected source")


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    fixture = sub.add_parser("fixtures", help="exercise the actual helper with fake compilers")
    fixture.add_argument("--root", type=Path, default=ROOT)
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
    args = parser.parse_args()
    if args.command == "fixtures":
        fixture_checks(args.root)
    elif args.command == "results":
        receipts(args.receipts, inventory(args.root), args.revision, args.run_id, args.compiler_sha256, args.count)
    else:
        manifest(args.manifest, args.payload, args.revision, args.run_id, args.attempt)
    print(args.command + ": passed")


if __name__ == "__main__":
    try:
        main()
    except (Invalid, OSError, ValueError, subprocess.SubprocessError) as error:
        print("artifact schedule: " + str(error), file=sys.stderr)
        sys.exit(1)
