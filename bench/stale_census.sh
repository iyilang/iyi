#!/usr/bin/env bash
# Census and overhead measurement for stale testing (§13).
#
#     bash bench/stale_census.sh [all|census|overhead]
#
# Records verdict, reusable or not, reason category and site over:
#   - C2: samples/iyi/*.iyi (27 programs)
#   - C3: bench/std_*_exercise.iyi (114 programs)
#
# Measures overhead:
#   - Wall time of --fresh against default mode
#   - Per-hit validation time (--cached)
#   - Trace and receipt bytes per program
#   - Reached elements and encoded bytes per program
#   - Stage timings (parse, top level, main semantic, stale check/walk)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ]; then
  echo "python3 required for stale_census.sh" >&2
  exit 1
fi

IYI="${IYI:-$REPO/bin/iyi}"
if [ ! -x "$IYI" ]; then
  if [ -x "$REPO/.build/iyi" ]; then
    IYI="$REPO/.build/iyi"
  fi
fi

MODE="${1:-all}"

export ZERO_AR_DATE=1
export SOURCE_DATE_EPOCH="$(/usr/bin/git -C "$REPO" show -s --format=%ct HEAD 2>/dev/null || cat "$REPO/src/SOURCE_DATE_EPOCH" 2>/dev/null || echo 0)"
export IYI_PATH="$REPO/src:$REPO/samples/iyi"
export IYI_LIBRARY_PATH="$REPO/lib"

"$PY" - "$REPO" "$IYI" "$MODE" <<'EOF'
import concurrent.futures, glob, json, os, subprocess, sys, time
from collections import Counter, defaultdict

repo = sys.argv[1]
iyi = sys.argv[2]
mode = sys.argv[3]

c2_files = sorted(glob.glob(os.path.join(repo, 'samples/iyi/*.iyi')))
c3_files = sorted(glob.glob(os.path.join(repo, 'bench/std_*_exercise.iyi')))
all_progs = [('C2', p) for p in c2_files] + [('C3', p) for p in c3_files]

work = '/tmp/stale_census_work'
os.makedirs(work, exist_ok=True)

def run_single_program(item):
    corpus, path = item
    bname = os.path.basename(path)
    pid = os.getpid()
    key_file = os.path.join(work, f'k_{pid}_{bname}.json')
    out_bin = os.path.join(work, f'o_{pid}_{bname}')

    t0 = time.time()
    res = subprocess.run([iyi, 'build', '--stale-key', key_file, '-o', out_bin, path],
                         capture_output=True, text=True)
    dt = time.time() - t0

    if os.path.exists(out_bin):
        try: os.remove(out_bin)
        except: pass

    if res.returncode != 0:
        if os.path.exists(key_file):
            try: os.remove(key_file)
            except: pass
        return {
            'corpus': corpus,
            'file': path,
            'name': bname,
            'verdict': 'build-failed',
            'reusable': False,
            'time': dt,
            'reasons': []
        }

    if not os.path.exists(key_file):
        return {
            'corpus': corpus,
            'file': path,
            'name': bname,
            'verdict': 'no-key',
            'reusable': False,
            'time': dt,
            'reasons': []
        }

    with open(key_file) as f:
        data = json.load(f)
    try: os.remove(key_file)
    except: pass

    not_reusable = data.get('not_reusable') or []
    is_reusable = (len(not_reusable) == 0)

    reasons = []
    for item in not_reusable:
        reasons.append({
            'category': item.get('category', 'unknown'),
            'reason': item.get('reason', ''),
            'site': item.get('site', '')
        })

    return {
        'corpus': corpus,
        'file': path,
        'name': bname,
        'verdict': 'pass',
        'reusable': is_reusable,
        'time': dt,
        'reasons': reasons
    }

def print_census(results):
    c2_results = [r for r in results if r['corpus'] == 'C2']
    c3_results = [r for r in results if r['corpus'] == 'C3']

    c2_reusable = sum(1 for r in c2_results if r['reusable'])
    c3_reusable = sum(1 for r in c3_results if r['reusable'])
    total_reusable = c2_reusable + c3_reusable
    total_progs = len(results)

    print('=' * 80)
    print('                      iyi STALE TEST CENSUS (§13)')
    print('=' * 80)
    print()
    print('## Corpus Reusability Distribution')
    print()
    print(f'| Corpus | Total Programs | Reusable | Not Reusable | Build Failed | Reusable % |')
    print(f'|---|---|---|---|---|---|')
    print(f'| C2 (samples/iyi/*.iyi) | {len(c2_results):4} | {c2_reusable:4} | {len(c2_results) - c2_reusable:4} | {sum(1 for r in c2_results if r["verdict"] == "build-failed"):4} | {c2_reusable/len(c2_results)*100:6.1f}% |')
    print(f'| C3 (bench/std_*_exercise.iyi) | {len(c3_results):4} | {c3_reusable:4} | {len(c3_results) - c3_reusable:4} | {sum(1 for r in c3_results if r["verdict"] == "build-failed"):4} | {c3_reusable/len(c3_results)*100:6.1f}% |')
    print(f'| **Total** | **{total_progs:4}** | **{total_reusable:4}** | **{total_progs - total_reusable:4}** | **0** | **{total_reusable/total_progs*100:6.1f}%** |')
    print()

    category_counts = Counter()
    reason_counts = Counter()
    example_sites_by_reason = {}

    for r in results:
        for item in r['reasons']:
            cat = item['category']
            reason = item['reason']
            site = item['site']
            category_counts[cat] += 1
            reason_counts[(cat, reason)] += 1
            if (cat, reason) not in example_sites_by_reason:
                example_sites_by_reason[(cat, reason)] = (r['name'], site)

    print('## Reason Categories Breakdown')
    print()
    print('| Reason Category | Total Occurrences | Description / Scope |')
    print('|---|---|---|')
    for cat in ['requested effect', 'opaque program construct', 'refused build mode', 'runner', 'internal']:
        count = category_counts.get(cat, 0)
        desc = {
            'requested effect': 'Explicit effect annotation/hook (clock, process, random, socket, etc.)',
            'opaque program construct': 'Raw pointers, assembly, or calls to unclassified/internal defs',
            'refused build mode': 'Refused compiler or link flags',
            'runner': 'Trace incomplete or racy run input',
            'internal': 'Unclassified runtime sites or internal effect as reason'
        }.get(cat, '')
        print(f'| `{cat}` | {count:5} | {desc} |')
    print()

    print('## Top Not-Reusable Reasons and Example Sites')
    print()
    print('| Category | Specific Reason | Occurrences | Example Program and Site |')
    print('|---|---|---|---|')
    for (cat, reason), cnt in reason_counts.most_common(15):
        prog, site = example_sites_by_reason.get((cat, reason), ('', ''))
        site_str = f'`{site}`' if site else '*(none)*'
        print(f'| `{cat}` | `{reason}` | {cnt:5} | {prog} at {site_str} |')
    print()

    print('## Reusable Programs in C3')
    reusable_c3 = [r['name'] for r in c3_results if r['reusable']]
    if reusable_c3:
        print('  ' + ', '.join(reusable_c3))
    else:
        print('  (none)')
    print()

def measure_overhead():
    print('=' * 80)
    print('                      STALE TESTING OVERHEAD MEASUREMENTS (§13)')
    print('=' * 80)
    print()

    test_programs = [
        os.path.join(repo, 'samples/iyi/hello.iyi'),
        os.path.join(repo, 'samples/iyi/calc.iyi'),
        os.path.join(repo, 'samples/iyi/collections.iyi'),
        os.path.join(repo, 'samples/iyi/format.iyi'),
        os.path.join(repo, 'samples/iyi/shapes.iyi'),
        os.path.join(repo, 'bench/std_int_exercise.iyi'),
        os.path.join(repo, 'bench/std_bit_array_exercise.iyi'),
    ]

    print('| Program | Default Build+Run (s) | --fresh Time (s) | --cached Validation (s) | Reached Elements | Trace Bytes | Receipt Bytes | Key Bytes |')
    print('|---|---|---|---|---|---|---|---|')

    cache_dir = os.path.join(work, 'bench_cache')
    os.makedirs(cache_dir, exist_ok=True)
    bench_env = dict(os.environ, IYI_CACHE_DIR=cache_dir)

    for prog in test_programs:
        # Each program receives a fresh store: receipt and trace sizes then
        # describe this program rather than an earlier run in the same cache.
        subprocess.run(['rm', '-rf', cache_dir], check=True)
        os.makedirs(cache_dir, exist_ok=True)
        bname = os.path.basename(prog)
        bin_out = os.path.join(work, f'bench_{bname}.bin')
        dump_out = os.path.join(work, f'dump_{bname}.json')
        key_out = os.path.join(work, f'key_{bname}.json')

        # 1. Default mode: build + run
        t0 = time.time()
        res_build = subprocess.run([iyi, 'build', '-o', bin_out, prog],
                                   capture_output=True, text=True, env=bench_env)
        if os.path.exists(bin_out):
            res_run = subprocess.run([bin_out], capture_output=True, text=True)
            try: os.remove(bin_out)
            except: pass
        t_default = time.time() - t0

        # 2. Fresh test mode: records receipt
        t0 = time.time()
        res_fresh = subprocess.run([iyi, 'test', '--fresh', '--json', prog],
                                   capture_output=True, text=True, env=bench_env)
        t_fresh = time.time() - t0

        # 3. Cached hit validation mode
        t0 = time.time()
        res_cached = subprocess.run([iyi, 'test', '--cached', '--json', prog],
                                    capture_output=True, text=True, env=bench_env)
        t_cached = time.time() - t0

        # 4. Elements dump and key file
        subprocess.run([iyi, 'build', '--stale-dump-elements', dump_out, '--stale-key', key_out, '-o', bin_out, prog],
                       capture_output=True, text=True, env=bench_env)
        if os.path.exists(bin_out):
            try: os.remove(bin_out)
            except: pass

        elements_count = 0
        if os.path.exists(dump_out):
            with open(dump_out) as f:
                elements_count = sum(1 for _ in f)
            try: os.remove(dump_out)
            except: pass

        trace_bytes = 0
        receipt_bytes = 0
        records_dir = os.path.join(cache_dir, 'tests-v1', 'records')
        if os.path.isdir(records_dir):
            for root, _, files in os.walk(records_dir):
                for name in files:
                    if not name.endswith('.json'):
                        continue
                    receipt_path = os.path.join(root, name)
                    receipt_bytes += os.path.getsize(receipt_path)
                    with open(receipt_path) as f:
                        receipt = json.load(f)
                    trace_bytes += len(json.dumps(receipt.get('trace', {}), separators=(',', ':')).encode())

        key_bytes = 0
        if os.path.exists(key_out):
            key_bytes = os.path.getsize(key_out)
            try: os.remove(key_out)
            except: pass

        print(f'| {bname:25} | {t_default:6.3f}s | {t_fresh:6.3f}s | {t_cached:6.3f}s | {elements_count:6} | {trace_bytes:6} B | {receipt_bytes:6} B | {key_bytes:6} B |')

    print()

    # Stage timing breakdown on samples/iyi/hello.iyi
    print('## Compiler Stage Timing Breakdown (`samples/iyi/hello.iyi`)')
    print()
    res_stats = subprocess.run([iyi, 'build', '--stats', os.path.join(repo, 'samples/iyi/hello.iyi'), '-o', '/tmp/stat_out'],
                               capture_output=True, text=True)
    if os.path.exists('/tmp/stat_out'):
        try: os.remove('/tmp/stat_out')
        except: pass

    stage_lines = []
    for line in res_stats.stderr.splitlines() + res_stats.stdout.splitlines():
        line = line.strip()
        if ':' in line and ('Parse:' in line or 'Semantic' in line or 'Codegen' in line or 'Up-to-date' in line):
            if any(c.isdigit() for c in line):
                stage_lines.append(line)

    print('```')
    for sl in stage_lines[:12]:
        print(sl)
    print('```')
    print()

if mode in ('all', 'census'):
    print(f'Running census over {len(all_progs)} programs ({len(c2_files)} C2, {len(c3_files)} C3) using 8 workers...')
    t0 = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(run_single_program, all_progs))
    dt = time.time() - t0
    print(f'Completed census in {dt:.2f}s.')
    print()
    print_census(results)

if mode in ('all', 'overhead'):
    measure_overhead()
EOF
