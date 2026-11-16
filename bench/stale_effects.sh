#!/usr/bin/env bash
# Gate for S4a: RG3 unclassified runtime sites report and check.
# Usage:
#     bash bench/stale_effects.sh [report|check|test-discriminator]
#     RG3_TARGET=x86_64-windows-msvc bash bench/stale_effects.sh check
#     RG3_JOBS=4 RG3_OBSERVE=1 RG3_TARGET=x86_64-linux-gnu bash bench/stale_effects.sh report
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ]; then
  echo "python3 required for stale_effects gate" >&2
  exit 1
fi

MODE="${1:-report}"

if [ -z "${IYI:-}" ]; then
  if [ "$PSEP" = ';' ]; then
    IYI="$REPO/.build/iyi.exe"
  else
    IYI="$REPO/bin/iyi"
  fi
fi
if [ "$MODE" != "test-discriminator" ] && [ ! -x "$IYI" ]; then
  echo "iyi compiler not found at $IYI. Building..." >&2
  export LIBRARY_PATH="${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}"
  export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-/tmp/iyi-stale-s4a-cache}"
  make -C "$REPO" -j8 iyi
fi

export ZERO_AR_DATE=1
export SOURCE_DATE_EPOCH="$(git -C "$REPO" show -s --format=%ct HEAD 2>/dev/null || cat "$REPO/src/SOURCE_DATE_EPOCH" 2>/dev/null || echo 0)"
if [ "$PSEP" = ';' ]; then
  NATIVE_REPO="$(cygpath -m "$REPO")"
  NATIVE_IYI="$(cygpath -m "$IYI")"
else
  NATIVE_REPO="$REPO"
  NATIVE_IYI="$IYI"
fi
export IYI_PATH="$NATIVE_REPO/src${PSEP}$NATIVE_REPO/samples/iyi"
export IYI_LIBRARY_PATH="$NATIVE_REPO/lib"

WORK="$(mktemp -d /tmp/stale-effects-work.XXXXXX)"
if [ "$PSEP" = ';' ]; then
  NATIVE_WORK="$(cygpath -m "$WORK")"
else
  NATIVE_WORK="$WORK"
fi

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ "$MODE" = "test-discriminator" ]; then
  echo "== Running S4a: RG3 fake-compiler diagnostic discriminator =="
else
  echo "== Running S4a: RG3 effects census (closure check over reached elements) =="
  echo "RG3 targets: x86_64-linux-gnu, aarch64-linux-gnu, aarch64-darwin, x86_64-windows-msvc."
  echo "Excluded: x86_64-darwin has no concurrency runtime; the corpus cannot build for that target."
fi

"$PY" - "$NATIVE_REPO" "$NATIVE_IYI" "$NATIVE_WORK" "$MODE" <<'EOF'
import os, sys, glob, subprocess, json, io, itertools, threading
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

repo = sys.argv[1]
iyi = sys.argv[2]
work = sys.argv[3]
mode = sys.argv[4]

def print_build_failure(rel_prog, target, cmd, returncode, stdout, stderr):
    sys.stdout.flush()
    print(f'  Build failed: {rel_prog} (exit {returncode})', file=sys.stderr)
    print(f'    target: {target}', file=sys.stderr)
    print(f'    argv: {cmd}', file=sys.stderr)
    print(f'    exit code: {returncode}', file=sys.stderr)
    if stdout:
        print('    stdout:', file=sys.stderr)
        sys.stderr.write(stdout)
        if not stdout.endswith('\n'):
            sys.stderr.write('\n')
    else:
        print('    stdout: (empty)', file=sys.stderr)
    if stderr:
        print('    stderr:', file=sys.stderr)
        sys.stderr.write(stderr)
        if not stderr.endswith('\n'):
            sys.stderr.write('\n')
    else:
        print('    stderr: (empty)', file=sys.stderr)
    sys.stderr.flush()

def run_census(repo, iyi, work, mode, progs=None, worker_count=None):
    if progs is None:
        c2_samples = sorted(glob.glob(os.path.join(repo, 'samples/iyi/*.iyi')))
        c3_bench = sorted(glob.glob(os.path.join(repo, 'bench/std_*_exercise.iyi')))
        all_progs = c2_samples + c3_bench
        print(f'Checking {len(all_progs)} programs ({len(c2_samples)} C2 samples, {len(c3_bench)} C3 exercises)...', flush=True)
    else:
        all_progs = progs
        print(f'Checking {len(all_progs)} programs (discriminator mode)...', flush=True)

    all_unclassified_sites = set()
    sites_per_program = {}
    file_area_counts = defaultdict(set)
    file_area_defs = defaultdict(set)
    program_errors = 0
    static_eligible_programs = []
    target = os.environ.get('RG3_TARGET') or 'host'

    try:
        jobs = worker_count if worker_count is not None else (int(os.environ.get('RG3_JOBS', '2')) if progs is None else 1)
        if jobs < 1:
            raise ValueError('must be positive')
    except ValueError as e:
        print(f'Invalid RG3_JOBS: {e}', file=sys.stderr)
        return 1

    target_args = ['--cross-compile', '--target', os.environ['RG3_TARGET']] if os.environ.get('RG3_TARGET') else []
    if os.environ.get('RG3_OBSERVE') == '1':
        target_args.append('-Diyi_observe')
    worker_ids = itertools.count()
    local = threading.local()

    def build(prog):
        if not hasattr(local, 'directory'):
            local.directory = os.path.join(work, f'worker-{next(worker_ids)}')
            os.makedirs(os.path.join(local.directory, 'cache'), exist_ok=True)
        key_file = os.path.join(local.directory, 'effects.key')
        out_file = os.path.join(local.directory, 'prog.bin')
        for path in (key_file, out_file):
            if os.path.exists(path):
                os.remove(path)
        compiler = iyi if isinstance(iyi, list) else [iyi]
        cmd = [*compiler, 'build', '--stale-key', key_file, *target_args, '-o', out_file, prog]
        env = os.environ.copy()
        env['IYI_CACHE_DIR'] = os.path.join(local.directory, 'cache')
        res = subprocess.run(cmd, capture_output=True, env=env)
        try:
            with open(key_file, 'rb') as f:
                key_data = f.read()
        except FileNotFoundError:
            key_data = None
        return prog, key_file, cmd, res, key_data

    # Each worker owns its cache and output files. executor.map preserves
    # corpus order in diagnostics even though the compiler builds overlap.
    with ThreadPoolExecutor(max_workers=jobs) as pool:
      for prog, key_file, cmd, res, key_data in pool.map(build, all_progs):
        rel_prog = os.path.relpath(prog, repo)
        stdout = res.stdout.decode('utf-8', errors='backslashreplace')
        stderr = res.stderr.decode('utf-8', errors='backslashreplace')
        if res.returncode != 0:
            print_build_failure(rel_prog, target, cmd, res.returncode, stdout, stderr)
            program_errors += 1
            continue

        if key_data is None:
            sys.stdout.flush()
            print(f'  Missing key file: {rel_prog}', file=sys.stderr)
            print(f'    target: {target}', file=sys.stderr)
            print(f'    argv: {cmd}', file=sys.stderr)
            if stdout:
                print('    stdout:', file=sys.stderr)
                sys.stderr.write(stdout)
                if not stdout.endswith('\n'):
                    sys.stderr.write('\n')
            else:
                print('    stdout: (empty)', file=sys.stderr)
            if stderr:
                print('    stderr:', file=sys.stderr)
                sys.stderr.write(stderr)
                if not stderr.endswith('\n'):
                    sys.stderr.write('\n')
            else:
                print('    stderr: (empty)', file=sys.stderr)
            sys.stderr.flush()
            program_errors += 1
            continue

        try:
            data = json.loads(key_data)
        except Exception as e:
            sys.stdout.flush()
            print(f'  JSON error in {rel_prog}: {e}', file=sys.stderr)
            print(f'    target: {target}', file=sys.stderr)
            print(f'    argv: {cmd}', file=sys.stderr)
            sys.stderr.flush()
            program_errors += 1
            continue
        if (not isinstance(data, dict) or
                not isinstance(data.get('not_reusable'), list) or
                not all(isinstance(reason, dict) and isinstance(reason.get('reason'), str)
                        for reason in data['not_reusable']) or
                not isinstance(data.get('rg3'), list) or
                not all(isinstance(item, dict) and isinstance(item.get('site'), str)
                        and isinstance(item.get('detail'), str)
                        and (item.get('enclosing_def') is None or isinstance(item.get('enclosing_def'), str))
                        for item in data['rg3'])):
            print(f'  Invalid stale key schema: {rel_prog} (target: {target}; argv: {cmd})', file=sys.stderr)
            program_errors += 1
            continue


        reasons = [reason for reason in data['not_reusable']
                   if reason['reason'] != 'refused build mode: --cross-compile']
        if not reasons:
            static_eligible_programs.append(rel_prog)

        rg3 = data['rg3']
        prog_sites = []
        for item in rg3:
            site = item.get('site', '')
            enclosing_def = item.get('enclosing_def')
            detail = item.get('detail', '')
            prog_sites.append((site, enclosing_def, detail))
            triple = (site, enclosing_def, detail)
            all_unclassified_sites.add(triple)

            # Classify into file area:
            # site is like toolchain:iyi/prelude.iyi:123 or toolchain:std/file.iyi:456
            if site.startswith('toolchain:'):
                file_part = site[len('toolchain:'):].split(':', 1)[0]
                if file_part.startswith('iyi/'):
                    area = 'src/iyi'
                elif file_part.startswith('std/'):
                    # Extract std module name e.g. std/file -> src/std/file
                    mod = file_part.split('/')[1].split('.')[0]
                    area = f'src/std/{mod}'
                else:
                    area = 'other'
                file_area_counts[area].add(triple)
                if enclosing_def:
                    file_area_defs[area].add(f'{file_part}:{enclosing_def}')

        sites_per_program[rel_prog] = prog_sites

    print(f'Static eligibility excluding cross-compile refusal: {len(static_eligible_programs)}/{len(all_progs)} (runtime reuse not measured).')
    for program in static_eligible_programs:
        print(f'  statically eligible: {program}')

    print()
    print('=== RG3 Census Report: Unclassified Runtime Sites ===')
    print()
    print('Distinct (site, def, detail):')
    for site, enclosing, detail in sorted(all_unclassified_sites, key=lambda item: (item[0], item[1] or '', item[2])):
        print(f'  - {site} (in {enclosing or "<none>"}): {detail}')
    print()


    # Print detailed per-program report for programs with unclassified sites
    for rel_prog, sites in sites_per_program.items():
        if sites:
            print(f'{rel_prog} ({len(sites)} unclassified sites):')
            for site, enclosing, detail in sites:
                enc_str = f' (in {enclosing})' if enclosing else ''
                print(f'  - {site}{enc_str}: {detail}')
            print()

    print('=== Summary by File Area (for S4b partition) ===')
    total_unique_sites = len(all_unclassified_sites)
    for area in sorted(file_area_counts.keys()):
        sites_count = len(file_area_counts[area])
        defs_count = len(file_area_defs[area])
        print(f'  {area:16} : {sites_count:4} unique (site, def, detail) triples across {defs_count:3} defs')

    print('-' * 50)
    print(f'Total unique unclassified runtime sites: {total_unique_sites} (distinct site, def, detail triples)')
    print(f'Checked {len(all_progs)} programs, {program_errors} build errors.')
    sys.stdout.flush()

    if program_errors > 0:
        print('FAILED: some corpus programs failed to build', file=sys.stderr)
        sys.stderr.flush()
        return 1

    if mode == 'check':
        if total_unique_sites > 0:
            print(f'RG3 CHECK FAILED: {total_unique_sites} unclassified runtime sites remain (expected 0 after S4b)', file=sys.stderr)
            sys.stderr.flush()
            return 1
        else:
            print('RG3 CHECK PASSED: 0 unclassified runtime sites')
            sys.stdout.flush()
            return 0
    else:
        if total_unique_sites == 0:
            print('RG3 clean: 0 unclassified runtime sites')
        else:
            print(f'RG3 report complete: {total_unique_sites} unclassified sites listed for S4b.')
        sys.stdout.flush()
        return 0

def run_discriminator(repo, work):
    target = os.environ.get('RG3_TARGET') or 'host'
    fake_script = os.path.join(work, 'fake_iyi_discriminator.py')
    with open(fake_script, 'w') as f:
        f.write('''import json, os, sys, time
if sys.argv[1] != "build":
    sys.exit(99)
prog = sys.argv[-1]
if prog.endswith("markers.iyi"):
    sys.stdout.buffer.write(b"OUT first\\nOUT last")
    sys.stderr.buffer.write(b"ERR first\\nERR last")
    sys.exit(42)
if prog.endswith("empty.iyi"):
    sys.exit(17)
if prog.endswith("whitespace.iyi"):
    sys.stdout.buffer.write(b" \\t\\n")
    sys.stderr.buffer.write(b"\\t \\n")
    sys.exit(23)
if prog.endswith(".good.iyi"):
    time.sleep(0.05)
    key = sys.argv[sys.argv.index("--stale-key") + 1]
    worker = os.path.basename(os.path.dirname(os.environ["IYI_CACHE_DIR"]))
    with open(key, "w") as out:
        json.dump({"not_reusable": [], "rg3": [{"site": "toolchain:std/example.iyi:1", "enclosing_def": os.path.basename(prog), "detail": worker}]}, out)
    sys.exit(0)
sys.exit(99)
''')
    fake_compiler = [sys.executable, fake_script]
    sample = [os.path.join(work, name + '.iyi') for name in ('markers', 'empty', 'whitespace')]
    old_stdout, old_stderr = sys.stdout, sys.stderr
    cap_out, cap_err = io.StringIO(), io.StringIO()
    try:
        sys.stdout, sys.stderr = cap_out, cap_err
        rc = run_census(repo, fake_compiler, work, 'check', progs=sample)
    finally:
        sys.stdout, sys.stderr = old_stdout, old_stderr

    report, errors = cap_out.getvalue(), cap_err.getvalue()
    if rc != 1 or 'Checked 3 programs, 3 build errors.' not in report:
        raise RuntimeError(f'RG3 discriminator failed census: {rc}\n{report}\n{errors}')
    target_args = ['--cross-compile', '--target', os.environ['RG3_TARGET']] if os.environ.get('RG3_TARGET') else []
    if os.environ.get('RG3_OBSERVE') == '1':
        target_args.append('-Diyi_observe')
    cases = [
        (sample[0], 42, '    stdout:\nOUT first\nOUT last\n    stderr:\nERR first\nERR last\n'),
        (sample[1], 17, '    stdout: (empty)\n    stderr: (empty)\n'),
        (sample[2], 23, '    stdout:\n \t\n    stderr:\n\t \n'),
    ]
    for prog, code, streams in cases:
        cmd = [*fake_compiler, 'build', '--stale-key', os.path.join(work, 'worker-0', 'effects.key'),
               *target_args, '-o', os.path.join(work, 'worker-0', 'prog.bin'), prog]
        expected = (f'  Build failed: {os.path.relpath(prog, repo)} (exit {code})\n'
                    f'    target: {target}\n    argv: {cmd}\n    exit code: {code}\n{streams}')
        if expected not in errors:
            raise RuntimeError(f'RG3 discriminator missing diagnostic:\n{expected}\nGot:\n{errors}')
    if 'FAILED: some corpus programs failed to build' not in errors:
        raise RuntimeError(f'RG3 discriminator missed final failure:\n{errors}')

    # Equal source lines with different defs must remain separate, and each
    # concurrent compiler must use its worker's own cache and output files.
    samples = [os.path.join(work, f'{i}.good.iyi') for i in range(4)]
    cap_out, cap_err = io.StringIO(), io.StringIO()
    try:
        sys.stdout, sys.stderr = cap_out, cap_err
        rc = run_census(repo, fake_compiler, work, 'report', progs=samples, worker_count=2)
    finally:
        sys.stdout, sys.stderr = old_stdout, old_stderr
    report, errors = cap_out.getvalue(), cap_err.getvalue()
    if (rc != 0 or 'Checked 4 programs, 0 build errors.' not in report or
            'Total unique unclassified runtime sites: 4 ' not in report or
            'worker-0' not in report or 'worker-1' not in report):
        raise RuntimeError(f'RG3 parallel discriminator failed: {rc}\n{report}\n{errors}')
    print('RG3 fake-compiler diagnostic discriminator PASSED', flush=True)

if mode == 'test-discriminator':
    run_discriminator(repo, work)
    sys.exit(0)
if mode == 'check':
    run_discriminator(repo, work)
sys.exit(run_census(repo, iyi, work, mode))
EOF
