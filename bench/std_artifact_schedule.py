#!/usr/bin/env python3
"""Check the Windows artifact sweeps: helper fixtures, receipts, and compiler payloads.

`fixtures`, `results`, `manifest` and `write-manifest` use only the standard library.
"""

import argparse
import collections
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


def bash_executable():
    # Windows Python resolves `bash` to System32's WSL launcher. Hosted
    # windows-2025 has no distribution, so the launcher exits before the helper
    # plans a shard. The workflow step uses Git Bash; invoke that binary.
    chosen = os.environ.get("STD_ARTIFACT_BASH")
    if chosen:
        return chosen
    if os.name != "nt":
        return "bash"
    skipped = ("\\system32\\bash.exe", "\\sysnative\\bash.exe")
    candidates = [str(Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git" / "bin" / "bash.exe")]
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidates.append(str(Path(directory) / "bash.exe"))
    for candidate in candidates:
        folded = candidate.replace("/", "\\").lower()
        if folded.endswith(skipped):
            continue
        if Path(candidate).is_file():
            return candidate
    return "bash"


def run_helper(root, *args, env=None):
    return subprocess.run([bash_executable(), posix(root / "bench/std_artifacts.sh"), *map(str, args)], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def reject(fn, label):
    try:
        fn()
    except (Invalid, OSError, ValueError, KeyError, TypeError):
        return
    raise Invalid("negative control accepted: " + label)

def require_lf(data):
    require(b"\r" not in data and data.startswith(b"#!/usr/bin/env bash\n"),
            "fake compiler must have an LF-only shebang and lines")


def validate_calls(lines, names, shard, count, phase):
    observed = collections.Counter()
    for line in lines:
        args = line.split("\t")
        require(args and args[0] == "build", "malformed compiler invocation")
        emit = args.count("--emit-iyimod")
        consume = args.count("--use-iyimod")
        require(emit + consume == 1, "compiler invocation has no unique stage")
        codegen = args.count("--no-codegen")
        target_count = args.count("--target")
        require(codegen <= 1 and target_count <= 1, "duplicate compiler flags")
        target = args[args.index("--target") + 1] if target_count else "host"
        source = "bench/" + args[-1].replace("\\", "/").rsplit("/", 1)[-1]
        observed[("emit" if emit else "consume", target, codegen, source)] += 1
    owned = [name for index, name in expected(names, count) if index == shard]
    targets = ("host",) if phase == "native" else TARGETS
    wanted = collections.Counter((stage, target, int(phase == "cross"), source)
                                 for source in owned for target in targets
                                 for stage in ("emit", "consume"))
    require(observed == wanted, "observed compiler calls do not match assigned units")


def check_observed_calls(path, names, shard, count, phase):
    lines = path.read_text(encoding="utf-8").splitlines()
    validate_calls(lines, names, shard, count, phase)
    require(lines, "compiler call log is empty")
    reject(lambda: validate_calls(lines[1:], names, shard, count, phase), "omitted observed compiler call")
    reject(lambda: validate_calls(lines + lines[:1], names, shard, count, phase), "duplicated observed compiler call")


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
        compiler.write_bytes(FAKE_COMPILER.encode("utf-8"))
        written_compiler = compiler.read_bytes()
        require_lf(written_compiler)
        reject(lambda: require_lf(written_compiler.replace(b"\n", b"\r\n")), "CRLF fake compiler")
        compiler.chmod(0o755)
        env = os.environ.copy()
        env.update(IYI=posix(compiler), STD_ARTIFACT_REVISION=REVISION, STD_ARTIFACT_RUN_ID=RUN_ID, STD_ARTIFACT_COMPILER_SHA256=COMPILER, STD_ARTIFACT_RECEIPT=posix(repo / "receipt"), FAKE_LOG=posix(repo / "calls"))
        for phase in ("native", "cross"):
            (repo / "calls").unlink(missing_ok=True)
            result = run_helper(repo, phase, 1, 1, env=env)
            require(result.returncode == 0, "fixture execution failed: " + result.stdout)
            check_observed_calls(repo / "calls", names, 1, 1, phase)
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
                (repo / "calls").unlink(missing_ok=True)
                result = run_helper(repo, phase, shard, SHARDS, env=env)
                require(result.returncode == 0, "sharded execution failed: " + result.stdout)
                check_observed_calls(repo / "calls", names, shard, SHARDS, phase)
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
        frame = subprocess.run([bash_executable(), "-c", '. "$1"; without_frames', "_", posix(filter_file)], input=b'0   program  0x000000010299550c symbol + 1\n4   program  0x12ab keep\nnonframe \xff\n', stdout=subprocess.PIPE, check=True)
        require(frame.stdout == b'4   program  0x12ab keep\nnonframe \xff\n', "frame filter lost nonframes or bytes")
        aggregate_checks()
    require(all(digest(p) == value for p, value in before.items()), "checker changed inspected source")


FAKE_COMPILER = r'''#!/usr/bin/env bash
printf '%s' "$1" >> "$FAKE_LOG"
printf '\t%s' "${@:2}" >> "$FAKE_LOG"
printf '\n' >> "$FAKE_LOG"
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


def aggregate_checks():
    """Run the aggregate gate logic against synthetic receipts."""
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
            py = posix(sys.executable)
            body = (
                'test "$RESULT_BUILD" = success || { echo "compiler build: $RESULT_BUILD" >&2; exit 1; }\n'
                'test "$RESULT_CORE" = success || { echo "foundation core: $RESULT_CORE" >&2; exit 1; }\n'
                'test "$RESULT_ARTIFACTS" = success || { echo "artifact shards: $RESULT_ARTIFACTS" >&2; exit 1; }\n'
                f'"{py}" bench/std_artifact_schedule.py results --root . --revision "$REVISION" --run-id "$RUN_ID" --compiler-sha256 "$COMPILER_SHA256" --count {SHARDS} receipts/*/*.tsv'
            )
            return subprocess.run([bash_executable(), "-e", "-o", "pipefail", "-c", body], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).returncode

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



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    fixtures_cmd = sub.add_parser("fixtures", help="run the real helper against fake compilers")
    fixtures_cmd.add_argument("--root", type=Path, default=ROOT)
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
