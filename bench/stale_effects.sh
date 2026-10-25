#!/usr/bin/env bash
# Gate for S4a: RG3 unclassified runtime sites report and check.
# Usage:
#     bash bench/stale_effects.sh [report|check]
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

IYI="${IYI:-$REPO/bin/iyi}"
if [ ! -x "$IYI" ]; then
  echo "iyi compiler not found at $IYI. Building..." >&2
  export LIBRARY_PATH="${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}"
  export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-/tmp/iyi-stale-s4a-cache}"
  make -C "$REPO" -j8 iyi
fi

MODE="${1:-report}"

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

echo "== Running S4a: RG3 effects census (closure check over reached elements) =="

"$PY" -c "
import os, sys, glob, subprocess, json
from collections import defaultdict

repo = sys.argv[1]
iyi = sys.argv[2]
work = sys.argv[3]
mode = sys.argv[4]

c2_samples = sorted(glob.glob(os.path.join(repo, 'samples/iyi/*.iyi')))
c3_bench = sorted(glob.glob(os.path.join(repo, 'bench/std_*_exercise.iyi')))
all_progs = c2_samples + c3_bench

print(f'Checking {len(all_progs)} programs ({len(c2_samples)} C2 samples, {len(c3_bench)} C3 exercises)...')

all_unclassified_sites = set()
sites_per_program = {}
file_area_counts = defaultdict(set)
file_area_defs = defaultdict(set)
program_errors = 0

for prog in all_progs:
    rel_prog = os.path.relpath(prog, repo)
    key_file = os.path.join(work, 'effects.key')
    out_file = os.path.join(work, 'prog.bin')
    if os.path.exists(key_file):
        os.remove(key_file)
    if os.path.exists(out_file):
        os.remove(out_file)

    res = subprocess.run([iyi, 'build', '--stale-key', key_file, '-o', out_file, prog],
                         capture_output=True, text=True)
    if res.returncode != 0:
        print(f'  Build failed: {rel_prog} (exit {res.returncode})', file=sys.stderr)
        program_errors += 1
        continue

    if not os.path.exists(key_file):
        print(f'  Missing key file: {rel_prog}', file=sys.stderr)
        program_errors += 1
        continue

    try:
        with open(key_file) as f:
            data = json.load(f)
    except Exception as e:
        print(f'  JSON error in {rel_prog}: {e}', file=sys.stderr)
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

if program_errors > 0:
    print('FAILED: some corpus programs failed to build', file=sys.stderr)
    sys.exit(1)

if mode == 'check':
    if total_unique_sites > 0:
        print(f'RG3 CHECK FAILED: {total_unique_sites} unclassified runtime sites remain (expected 0 after S4b)', file=sys.stderr)
        sys.exit(1)
    else:
        print('RG3 CHECK PASSED: 0 unclassified runtime sites')
        sys.exit(0)
else:
    if total_unique_sites == 0:
        print('RG3 clean: 0 unclassified runtime sites')
    else:
        print(f'RG3 report complete: {total_unique_sites} unclassified sites listed for S4b.')
    sys.exit(0)
" "$REPO" "$IYI" "$WORK" "$MODE"
