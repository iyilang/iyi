#!/usr/bin/env bash
# Gate for S4a: RG3 unclassified runtime sites report and check.
# Usage:
#     bash bench/stale_effects.sh [report|check|test-discriminator]
#     RG3_TARGET=x86_64-windows-msvc bash bench/stale_effects.sh check
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

IYI="${IYI:-$REPO/bin/iyi}"
if [ "$MODE" != "test-discriminator" ] && [ ! -x "$IYI" ]; then
  echo "iyi compiler not found at $IYI. Building..." >&2
  export LIBRARY_PATH="${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}"
  export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-/tmp/iyi-stale-s4a-cache}"
  make -C "$REPO" -j8 iyi
fi

export ZERO_AR_DATE=1
export SOURCE_DATE_EPOCH="$(/usr/bin/git -C "$REPO" show -s --format=%ct HEAD 2>/dev/null || cat "$REPO/src/SOURCE_DATE_EPOCH" 2>/dev/null || echo 0)"
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
export IYI_LIBRARY_PATH="$REPO/lib"

WORK="$(mktemp -d /tmp/stale-effects-work.XXXXXX)"
CACHE="$WORK/cache"
mkdir -p "$CACHE"
export IYI_CACHE_DIR="$CACHE"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ "$MODE" = "test-discriminator" ]; then
  echo "== Running S4a: RG3 fake-compiler diagnostic discriminator =="
else
  echo "== Running S4a: RG3 effects census (closure check over reached elements) =="
fi

"$PY" - "$REPO" "$IYI" "$WORK" "$MODE" <<'EOF'
import os, sys, glob, subprocess, json, io
from collections import defaultdict

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

def run_census(repo, iyi, work, mode, progs=None):
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
    target = os.environ.get('RG3_TARGET') or 'host'

    for prog in all_progs:
        rel_prog = os.path.relpath(prog, repo)
        key_file = os.path.join(work, 'effects.key')
        out_file = os.path.join(work, 'prog.bin')
        if os.path.exists(key_file):
            os.remove(key_file)
        if os.path.exists(out_file):
            os.remove(out_file)

        # RG3_TARGET=x86_64-windows-msvc (or another target triple) classifies the
        # arms that target compiles, from any host: the closure check runs in the
        # front end, so nothing is linked or run.
        target_args = ['--cross-compile', '--target', os.environ['RG3_TARGET']] if os.environ.get('RG3_TARGET') else []
        cmd = [iyi, 'build', '--stale-key', key_file, *target_args, '-o', out_file, prog]
        res = subprocess.run(cmd, capture_output=True)
        stdout = res.stdout.decode('utf-8', errors='backslashreplace')
        stderr = res.stderr.decode('utf-8', errors='backslashreplace')
        if res.returncode != 0:
            print_build_failure(rel_prog, target, cmd, res.returncode, stdout, stderr)
            program_errors += 1
            continue

        if not os.path.exists(key_file):
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
            with open(key_file) as f:
                data = json.load(f)
        except Exception as e:
            sys.stdout.flush()
            print(f'  JSON error in {rel_prog}: {e}', file=sys.stderr)
            print(f'    target: {target}', file=sys.stderr)
            print(f'    argv: {cmd}', file=sys.stderr)
            sys.stderr.flush()
            program_errors += 1
            continue

        rg3 = data.get('rg3', [])
        prog_sites = []
        for item in rg3:
            site = item.get('site', '')
            enclosing_def = item.get('enclosing_def')
            detail = item.get('detail', '')
            prog_sites.append((site, enclosing_def, detail))
            all_unclassified_sites.add(site)

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
                file_area_counts[area].add(site)
                if enclosing_def:
                    file_area_defs[area].add(f'{file_part}:{enclosing_def}')

        sites_per_program[rel_prog] = prog_sites

    print()
    print('=== RG3 Census Report: Unclassified Runtime Sites ===')
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
        print(f'  {area:16} : {sites_count:4} unique sites across {defs_count:3} defs')

    print('-' * 50)
    print(f'Total unique unclassified runtime sites: {total_unique_sites}')
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
    fake_compiler = os.path.join(work, 'fake_iyi_discriminator')
    with open(fake_compiler, 'w') as f:
        f.write('''#!/bin/sh
case "$1" in build) ;; *) exit 99 ;; esac
for arg do prog="$arg"; done
case "$prog" in
  *markers.iyi)
    printf 'OUT first\\nOUT last'
    printf 'ERR first\\nERR last' >&2
    exit 42 ;;
  *empty.iyi) exit 17 ;;
  *whitespace.iyi)
    printf ' \\t\\n'
    printf '\\t \\n' >&2
    exit 23 ;;
  *) exit 99 ;;
esac
''')
    os.chmod(fake_compiler, 0o755)
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
    cases = [
        (sample[0], 42, '    stdout:\nOUT first\nOUT last\n    stderr:\nERR first\nERR last\n'),
        (sample[1], 17, '    stdout: (empty)\n    stderr: (empty)\n'),
        (sample[2], 23, '    stdout:\n \t\n    stderr:\n\t \n'),
    ]
    for prog, code, streams in cases:
        cmd = [fake_compiler, 'build', '--stale-key', os.path.join(work, 'effects.key'),
               *target_args, '-o', os.path.join(work, 'prog.bin'), prog]
        expected = (f'  Build failed: {os.path.relpath(prog, repo)} (exit {code})\n'
                    f'    target: {target}\n    argv: {cmd}\n    exit code: {code}\n{streams}')
        if expected not in errors:
            raise RuntimeError(f'RG3 discriminator missing diagnostic:\n{expected}\nGot:\n{errors}')
    if 'FAILED: some corpus programs failed to build' not in errors:
        raise RuntimeError(f'RG3 discriminator missed final failure:\n{errors}')
    print('RG3 fake-compiler diagnostic discriminator PASSED', flush=True)

if mode == 'test-discriminator':
    run_discriminator(repo, work)
    sys.exit(0)
if mode == 'check':
    run_discriminator(repo, work)
sys.exit(run_census(repo, iyi, work, mode))
EOF
