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
    env.setdefault("LIBRARY_PATH", "/opt/homebrew/opt/bdw-gc/lib")
    if warm:
        env["IYI_WARM"] = "1"
    else:
        env.pop("IYI_WARM", None)
    return env


def build(compiler: str, repo: str, work: str, source: str, number: int, dump: bool, warm: bool) -> tuple[str, int, int]:
    base = os.path.basename(source)
    unique = f"{base}-{number}-{os.getpid()}-{time.time_ns()}"
    key = os.path.join(work, f"{unique}.key")
    out = os.path.join(work, f"{unique}.bin")
    elements = os.path.join(work, f"{unique}.elements.jsonl")
    cmd = [compiler, "build", "--stale-key", key]
    if dump:
        cmd += ["--stale-dump-elements", elements]
    cmd += ["-o", out, source]
    proc = subprocess.run(cmd, cwd=repo, env=env_for(repo, os.path.join(work, "cache"), warm), capture_output=True, text=True)
    if proc.returncode:
        raise GateFailure(f"{os.path.relpath(source, repo)} run {number}: build exited {proc.returncode}: {proc.stderr.strip()[-500:]}")
    with open(key, encoding="utf-8") as f:
        data = json.load(f)
    mismatch = data.get("reach", {}).get("mismatch", [])
    if mismatch:
        raise GateFailure(f"{os.path.relpath(source, repo)} run {number}: reach.mismatch={mismatch}")
    rows = []
    if dump:
        with open(elements, encoding="utf-8") as f:
            rows = [json.loads(line) for line in f if line.strip()]
    return data["portable"]["callpath"], len(rows), sum(row.get("encoded_bytes", 0) for row in rows)


def main() -> None:
    parser = argparse.ArgumentParser(description="RG9 determinism proof gate")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--compiler", required=True)
    parser.add_argument("--work", required=True)
    args = parser.parse_args()
    repo = os.path.abspath(args.repo)
    compiler = os.path.abspath(args.compiler)
    programs = sorted(glob.glob(os.path.join(repo, "samples/iyi/*.iyi")))
    programs += sorted(glob.glob(os.path.join(repo, "bench/std_*_exercise.iyi")))
    if not programs:
        raise GateFailure("RG9 corpus is empty")

    def check(source: str) -> tuple[str, int, int, str]:
        first, reached, encoded = build(compiler, repo, args.work, source, 1, True, False)
        second, _, _ = build(compiler, repo, args.work, source, 2, False, False)
        warm, _, _ = build(compiler, repo, args.work, source, 3, False, True)
        if first != second or first != warm:
            raise GateFailure(
                f"{os.path.relpath(source, repo)}: CallPathFp differs across processes/warm "
                f"({first}, {second}, {warm})"
            )
        return os.path.relpath(source, repo), reached, encoded, first

    workers = min(8, os.cpu_count() or 4)
    failures = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for future in pool.map(check, programs):
            name, reached, encoded, fingerprint = future
            print(f"  RG9 report: {name}: reached={reached} encoded_bytes={encoded} callpath={fingerprint}")
    if failures:
        raise GateFailure("; ".join(failures))
    print(f"RG9 PASSED: {len(programs)} corpus programs, two processes plus IYI_WARM=1")


if __name__ == "__main__":
    try:
        main()
    except GateFailure as ex:
        print(f"RG9 FAILED: {ex}", file=sys.stderr)
        sys.exit(1)
