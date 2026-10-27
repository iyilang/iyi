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
    try:
        # One cache per program: parallel builds of different programs sharing
        # one cache directory would test the cache's locking, not determinism.
        cache = os.path.join(work, f"cache-{base}")
        proc = subprocess.run(cmd, cwd=repo, env=env_for(repo, cache, warm), capture_output=True, text=True)
        if proc.returncode:
            raise GateFailure(f"{os.path.relpath(source, repo)} run {number}: build exited {proc.returncode}: {proc.stderr.strip()[-500:]}")
        with open(key, encoding="utf-8") as f:
            data = json.load(f)
        mismatch = data.get("reach", {}).get("mismatch", [])
        if mismatch:
            raise GateFailure(f"{os.path.relpath(source, repo)} run {number}: reach.mismatch={mismatch}")
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


def main() -> None:
    parser = argparse.ArgumentParser(description="RG9 determinism proof gate")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--compiler", required=True)
    parser.add_argument("--work", required=True)
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

    def check(source: str) -> tuple[str, int, int, str, str | None]:
        name = os.path.relpath(source, repo)
        try:
            first, reached, encoded = build(compiler, repo, args.work, source, 1, True, False)
            second, _, _ = build(compiler, repo, args.work, source, 2, False, False)
            warm, _, _ = build(compiler, repo, args.work, source, 3, False, True)
        except GateFailure as ex:
            return name, 0, 0, "", str(ex)
        if first != second or first != warm:
            return name, reached, encoded, first, f"{name}: CallPathFp differs across processes/warm ({first}, {second}, {warm})"
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
    print(f"RG9 PASSED: {len(programs)} corpus programs, two processes plus IYI_WARM=1")


if __name__ == "__main__":
    try:
        main()
    except GateFailure as ex:
        print(f"RG9 FAILED: {ex}", file=sys.stderr)
        sys.exit(1)
