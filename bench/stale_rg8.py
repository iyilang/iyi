#!/usr/bin/env python3
"""RG8: compare normalized IR and CallPathFp under reach-derived mutations."""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

from stale_ir_normalize import normalize_ir
from stale_mutate import Mutation, generate_mutations_for_source


@dataclass
class Build:
    source: str
    callpath: str
    link: str
    build: str
    ir: str
    reach_count: int
    encoded_bytes: int
    mismatch: list[str]


class GateFailure(RuntimeError):
    pass


def compiler_env(repo: str, cache: str) -> dict[str, str]:
    env = os.environ.copy()
    env["IYI_CACHE_DIR"] = cache
    env["IYI_PATH"] = f"{repo}/src{os.pathsep}{repo}/samples/iyi"
    env["IYI_LIBRARY_PATH"] = f"{repo}/lib"
    env.setdefault("LIBRARY_PATH", "/opt/homebrew/opt/bdw-gc/lib")
    env["DUMP"] = "1"
    env["IYI_DUMP_TYPE_ID"] = "1"
    return env


def compile_source(
    compiler: str,
    repo: str,
    work: str,
    source: str,
    label: str,
    dump_elements: bool = False,
) -> tuple[Build, list[dict]]:
    stem = label.replace("/", "_").replace(" ", "_")
    key = os.path.join(work, f"{stem}.key")
    out = os.path.join(work, f"{stem}.bin")
    dump = os.path.join(work, f"{stem}.elements.jsonl")
    cmd = [compiler, "build", "--stale-key", key]
    if dump_elements:
        cmd += ["--stale-dump-elements", dump]
    cmd += ["-o", out, source]
    proc = subprocess.run(
        cmd,
        cwd=repo,
        env=compiler_env(repo, os.path.join(work, "cache")),
        capture_output=True,
        text=True,
    )
    if proc.returncode:
        raise GateFailure(f"{label}: build exited {proc.returncode}: {proc.stderr.strip()[-1000:]}")
    if not os.path.exists(key):
        raise GateFailure(f"{label}: stale key missing")
    with open(key, encoding="utf-8") as f:
        data = json.load(f)
    mismatch = data.get("reach", {}).get("mismatch", [])
    if mismatch:
        raise GateFailure(f"{label}: reach.mismatch is not empty: {mismatch}")
    try:
        ir, _ = normalize_ir(proc.stderr, proc.stdout)
    except Exception as ex:
        raise GateFailure(f"{label}: normalized IR failed: {ex}") from ex
    rows = []
    if dump_elements:
        with open(dump, encoding="utf-8") as f:
            rows = [json.loads(line) for line in f if line.strip()]
    portable = data["portable"]
    return (
        Build(
            source=source,
            callpath=portable["callpath"],
            link=portable["link"],
            build=portable["build"],
            ir=ir,
            reach_count=len(rows),
            encoded_bytes=sum(row.get("encoded_bytes", 0) for row in rows),
            mismatch=mismatch,
        ),
        rows,
    )




def reports_for_corpus(compiler: str, repo: str, work: str, programs: list[str]) -> dict[str, tuple[Build, list[dict]]]:
    def one(prog: str) -> tuple[str, tuple[Build, list[dict]]]:
        name = os.path.relpath(prog, repo)
        return name, compile_source(compiler, repo, work, prog, f"baseline-{name}", True)

    workers = min(8, os.cpu_count() or 4)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        reports = dict(pool.map(one, programs))
    for name in sorted(reports):
        build, _ = reports[name]
        print(f"  RG8 report: {name}: reached={build.reach_count} encoded_bytes={build.encoded_bytes} overapprox=0")
    return reports


def choose_mutations(
    repo: str,
    reports: dict[str, tuple[Build, list[dict]]],
    kinds: set[str] | None,
) -> list[tuple[str, Mutation]]:
    chosen: dict[str, tuple[str, Mutation]] = {}
    for rel in sorted(reports):
        source = os.path.join(repo, rel)
        _, elements = reports[rel]
        for mutation in generate_mutations_for_source(source, elements, kinds=kinds):
            chosen.setdefault(mutation.kind, (source, mutation))
    if kinds:
        missing = sorted(kinds - set(chosen))
        if missing:
            raise GateFailure(f"mutation generator produced no mutation for: {', '.join(missing)}")
    return [chosen[kind] for kind in sorted(chosen)]


def run_mutations(
    compiler: str,
    repo: str,
    work: str,
    reports: dict[str, tuple[Build, list[dict]]],
    mutations: list[tuple[str, Mutation]],
    expect_failure_kind: str | None,
) -> int:
    failures: list[str] = []
    overapprox: list[str] = []
    observed_expected_failure = False
    mutation_dir = os.path.join(work, "mutations")
    os.makedirs(mutation_dir, exist_ok=True)
    for index, (source, mutation) in enumerate(mutations):
        rel = os.path.relpath(source, repo)
        baseline, _ = reports[rel]
        mutated_source = os.path.join(mutation_dir, f"{index}-{os.path.basename(source)}")
        Path(mutated_source).write_text(mutation.mutated_source, encoding="utf-8")
        try:
            changed, _ = compile_source(compiler, repo, work, mutated_source, f"mut-{index}-{mutation.kind}")
        except GateFailure as ex:
            failures.append(f"{mutation.kind} on {rel}: {ex}")
            continue

        ir_changed = baseline.ir != changed.ir
        fp_changed = baseline.callpath != changed.callpath
        if mutation.special == "link_annotation" and baseline.link == changed.link:
            failures.append(f"{mutation.kind} on {rel}: LinkFp did not change")
        if mutation.in_reach:
            if ir_changed and not fp_changed:
                message = f"{mutation.kind} on {rel}: normalized IR changed but CallPathFp did not"
                if mutation.kind == expect_failure_kind:
                    print(f"  RG8 mutation proof caught: {message}")
                    observed_expected_failure = True
                else:
                    failures.append(message)
            elif fp_changed and not ir_changed:
                overapprox.append(f"{mutation.kind}:{rel}")
            elif not ir_changed and not fp_changed:
                failures.append(f"{mutation.kind} on {rel}: mutation changed neither normalized IR nor CallPathFp")
        elif ir_changed or fp_changed:
            failures.append(
                f"{mutation.kind} on {rel}: outside-reach mutation changed "
                f"{'normalized IR' if ir_changed else 'CallPathFp'}"
            )
        print(
            f"  RG8 mutation: {mutation.kind} {rel}: "
            f"ir_changed={ir_changed} callpath_changed={fp_changed}"
        )

    print(f"RG8 over-approximation reruns: {len(overapprox)}" + (f" ({', '.join(overapprox)})" if overapprox else ""))
    if expect_failure_kind:
        if failures:
            raise GateFailure("mutation proof had unexpected failures: " + "; ".join(failures))
        if not observed_expected_failure:
            raise GateFailure(f"mutation proof did not fail naming {expect_failure_kind}")
        return 0
    if failures:
        raise GateFailure("RG8 failures: " + "; ".join(failures))
    return len(overapprox)


def main() -> None:
    parser = argparse.ArgumentParser(description="RG8 mutation proof gate")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--compiler", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--kind", action="append", dest="kinds")
    parser.add_argument("--expect-failure-kind")
    args = parser.parse_args()

    os.makedirs(args.work, exist_ok=True)
    repo = os.path.abspath(args.repo)
    programs = sorted(glob.glob(os.path.join(repo, "samples/iyi/*.iyi")))
    programs += sorted(glob.glob(os.path.join(repo, "bench/std_*_exercise.iyi")))
    if not programs:
        raise GateFailure("RG8 corpus is empty")
    reports = reports_for_corpus(os.path.abspath(args.compiler), repo, args.work, programs)
    kinds = set(args.kinds) if args.kinds else None
    mutations = choose_mutations(repo, reports, kinds)
    run_mutations(
        os.path.abspath(args.compiler),
        repo,
        args.work,
        reports,
        mutations,
        args.expect_failure_kind,
    )
    print(f"RG8 PASSED: {len(programs)} corpus programs, {len(mutations)} mutation kinds")


if __name__ == "__main__":
    try:
        main()
    except GateFailure as ex:
        print(f"RG8 FAILED: {ex}", file=sys.stderr)
        sys.exit(1)
