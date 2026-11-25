#!/usr/bin/env python3
"""RG9: CallPathFp determinism across processes and a preanalysed prelude."""

from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor


class GateFailure(RuntimeError):
    pass


def env_for(repo: str, cache: str, warm: bool) -> dict[str, str]:
    env = os.environ.copy()
    env["IYI_CACHE_DIR"] = cache
    env["IYI_PATH"] = f"{repo}/src{os.pathsep}{repo}/samples/iyi"
    env["IYI_LIBRARY_PATH"] = f"{repo}/lib"
    if sys.platform == "darwin":
        env.setdefault("LIBRARY_PATH", "/opt/homebrew/opt/bdw-gc/lib")
    if warm:
        env["IYI_WARM"] = "1"
    else:
        env.pop("IYI_WARM", None)
    return env


def build(compiler: str, repo: str, work: str, source: str, number: int, dump: bool, warm: bool, observe: bool = False) -> tuple[str, int, int]:
    base = os.path.basename(source)
    tag = f"{number}-obs" if observe else f"{number}"
    unique = f"{base}-{tag}-{os.getpid()}-{time.time_ns()}"
    key = os.path.join(work, f"{unique}.key")
    out = os.path.join(work, f"{unique}.bin")
    elements = os.path.join(work, f"{unique}.elements.jsonl")
    cmd = [compiler, "build", "--stale-key", key]
    if observe:
        cmd += ["-Diyi_observe"]
    if dump:
        cmd += ["--stale-dump-elements", elements]
    cmd += ["-o", out, source]
    try:
        # One cache per program: parallel builds of different programs sharing
        # one cache directory would test the cache's locking, not determinism.
        cache = os.path.join(work, f"cache-{base}")
        proc = subprocess.run(cmd, cwd=repo, env=env_for(repo, cache, warm), capture_output=True, text=True)
        if proc.returncode:
            raise GateFailure(f"{os.path.relpath(source, repo)} run {tag}: build exited {proc.returncode}: {proc.stderr.strip()[-500:]}")
        with open(key, encoding="utf-8") as f:
            data = json.load(f)
        mismatch = data.get("reach", {}).get("mismatch", [])
        if mismatch:
            raise GateFailure(f"{os.path.relpath(source, repo)} run {tag}: reach.mismatch={mismatch}")
        rows = []
        if dump and os.path.exists(elements):
            with open(elements, encoding="utf-8") as f:
                rows = [json.loads(line) for line in f if line.strip()]
        return data["portable"]["callpath"], len(rows), sum(row.get("encoded_bytes", 0) for row in rows)
    finally:
        for p in (key, out, elements):
            if os.path.exists(p):
                try: os.remove(p)
                except OSError: pass

def inputs_leg(compiler: str, repo: str, work: str, source: str, number: int, with_inputs: bool) -> tuple[str, dict, dict | None]:
    base = os.path.basename(source)
    unique = f"{base}-inputs{number}-{os.getpid()}-{time.time_ns()}"
    key = os.path.join(work, f"{unique}.key")
    out = os.path.join(work, f"{unique}.bin")
    record = os.path.join(work, f"{unique}.inputs.json") if with_inputs else None
    cmd = [compiler, "build", "--stale-key", key]
    if record:
        cmd += ["--stale-inputs", record]
    cmd += ["-o", out, source]
    cache = os.path.join(work, f"cache-{base}")
    try:
        proc = subprocess.run(cmd, cwd=repo, env=env_for(repo, cache, False), capture_output=True, text=True)
        if proc.returncode:
            raise GateFailure(f"{os.path.relpath(source, repo)} inputs leg {number}: build exited {proc.returncode}: {proc.stderr.strip()[-500:]}")
        with open(key, encoding="utf-8") as f:
            local = json.load(f)["local"]
        data = None
        if record and os.path.exists(record):
            with open(record, encoding="utf-8") as f:
                data = json.load(f)
        return local["build"], local, data
    finally:
        for p in (key, out, record):
            if p and os.path.exists(p):
                try: os.remove(p)
                except OSError: pass

def run_inputs_check(compiler: str, repo: str, work: str, programs: list[str]) -> None:
    def check(source: str) -> tuple[str, dict | None, str | None]:
        name = os.path.relpath(source, repo)
        try:
            plain, plain_local, _ = inputs_leg(compiler, repo, work, source, 1, False)
            with_inputs, with_local, data = inputs_leg(compiler, repo, work, source, 2, True)
        except GateFailure as ex:
            return name, None, str(ex)
        if plain != with_inputs:
            # Name the parts of the key that differ, so a failure says what moved
            # (toolchain, behavior, callpath, link, cenv or build) rather than two hashes.
            moved = sorted(k for k in set(plain_local) | set(with_local) if plain_local.get(k) != with_local.get(k))
            return name, None, f"{name}: local.build differs with --stale-inputs ({plain}, {with_inputs}); parts that differ: {', '.join(moved) or 'none'}"
        if data is not None and data.get("format") != "iyi-stale-inputs":
            return name, None, f"{name}: --stale-inputs wrote a record of another format"
        return name, data, None

    workers = min(8, os.cpu_count() or 4)
    failures = []
    recorded = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for name, data, failure in pool.map(check, programs):
            if failure:
                failures.append(failure)
                print(f"  RG9 inputs FAIL: {failure}")
            elif data is None:
                print(f"  RG9 inputs: {name}: no record (its build has a reason the record cannot hold)")
            else:
                recorded += 1
    if failures:
        raise GateFailure("; ".join(failures))
    print(f"RG9 inputs PASSED: {len(programs)} programs, local.build equal with and without --stale-inputs, {recorded} wrote a record")

def main() -> None:
    parser = argparse.ArgumentParser(description="RG9 determinism proof gate")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--compiler", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--inputs-check", action="store_true", help="check that --stale-inputs keeps local.build")
    args = parser.parse_args()
    os.makedirs(args.work, exist_ok=True)
    repo = os.path.abspath(args.repo)
    compiler = os.path.abspath(args.compiler)
    # Plan §10: every C2 and C3 program. IYI_RG9_C3_SAMPLE bounds C3 for a
    # quick local loop; unset, the whole corpus is checked.
    c2 = sorted(glob.glob(os.path.join(repo, "samples/iyi/*.iyi")))
    c3 = sorted(glob.glob(os.path.join(repo, "bench/std_*_exercise.iyi")))
    c3_limit = int(os.environ.get("IYI_RG9_C3_SAMPLE", str(len(c3))))
    c3_sample = c3[:c3_limit]
    programs = c2 + c3_sample
    print(f"RG9 corpus: C2={len(c2)} programs, deterministic C3 sample={len(c3_sample)}/{len(c3)}")
    if not programs:
        raise GateFailure("RG9 corpus is empty")

    if args.inputs_check:
        run_inputs_check(compiler, repo, args.work, programs)
        return

    def check(source: str) -> tuple[str, int, int, str, str | None]:
        name = os.path.relpath(source, repo)
        try:
            # Plain legs
            first, reached, encoded = build(compiler, repo, args.work, source, 1, True, False, observe=False)
            second, _, _ = build(compiler, repo, args.work, source, 2, False, False, observe=False)
            warm, _, _ = build(compiler, repo, args.work, source, 3, False, True, observe=False)

            # Observed legs
            obs_first, obs_reached, obs_encoded = build(compiler, repo, args.work, source, 4, True, False, observe=True)
            obs_second, _, _ = build(compiler, repo, args.work, source, 5, False, False, observe=True)
            obs_warm, _, _ = build(compiler, repo, args.work, source, 6, False, True, observe=True)
        except GateFailure as ex:
            return name, 0, 0, "", str(ex)
        if first != second or first != warm:
            return name, reached, encoded, first, f"{name}: plain CallPathFp differs across processes/warm ({first}, {second}, {warm})"
        if obs_first != obs_second or obs_first != obs_warm:
            return name, obs_reached, obs_encoded, obs_first, f"{name}: observed CallPathFp differs across processes/warm ({obs_first}, {obs_second}, {obs_warm})"
        return name, reached, encoded, first, None
    workers = min(8, os.cpu_count() or 4)
    failures = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for name, reached, encoded, fingerprint, failure in pool.map(check, programs):
            if failure:
                failures.append(failure)
                print(f"  RG9 FAIL: {failure}")
            else:
                print(f"  RG9 report: {name}: reached={reached} encoded_bytes={encoded} callpath={fingerprint}")
    if failures:
        raise GateFailure("; ".join(failures))
    print(f"RG9 PASSED: {len(programs)} corpus programs, plain and observed legs (two processes plus IYI_WARM=1)")


if __name__ == "__main__":
    try:
        main()
    except GateFailure as ex:
        print(f"RG9 FAILED: {ex}", file=sys.stderr)
        sys.exit(1)
