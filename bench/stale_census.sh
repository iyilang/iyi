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
import concurrent.futures, glob, json, os, re, shutil, subprocess, sys, time
from collections import Counter, defaultdict

repo = sys.argv[1]
iyi = sys.argv[2]
mode = sys.argv[3]

c2_files = sorted(glob.glob(os.path.join(repo, 'samples/iyi/*.iyi')))
c3_files = sorted(glob.glob(os.path.join(repo, 'bench/std_*_exercise.iyi')))
all_progs = [('C2', p) for p in c2_files] + [('C3', p) for p in c3_files]

# A directory of this run's own: one shared by name was removed under a
# second census by the first one finishing.
import tempfile
work = tempfile.mkdtemp(prefix='stale_census.', dir='/tmp')

OVERHEAD_NAMES = {
    'hello.iyi',
    'calc.iyi',
    'collections.iyi',
    'format.iyi',
    'shapes.iyi',
    'std_int_exercise.iyi',
    'std_bit_array_exercise.iyi',
}

def resolve_site_effect(site):
    if not site:
        return "internal", "unknown"
    parts = site.split(":")
    if len(parts) >= 2:
        file_part = parts[-2]
        line_part = parts[-1]
        try:
            lineno = int(line_part)
        except ValueError:
            return "internal", "unknown"

        real_file = None
        for prefix in [os.path.join(repo, "src"), repo]:
            cand = os.path.join(prefix, file_part.removeprefix("toolchain:").removeprefix("src:"))
            if os.path.isfile(cand):
                real_file = cand
                break

        if real_file:
            with open(real_file, errors="replace") as f:
                lines = f.readlines()
            start = max(0, lineno - 35)
            end = min(len(lines), lineno + 55)
            for idx in range(start, end):
                m = re.search(r"@\[Effect\(:([a-zA-Z0-9_]+)", lines[idx])
                if m:
                    eff = m.group(1).lower()
                    if eff in ["clock", "entropy", "timer", "network", "process", "signal",
                               "runtime_timing", "code_location", "dir_stream", "host_state"]:
                        return "requested effect", eff
                    elif eff == "shared_write":
                        return "runner", "shared-write"
                    else:
                        return "internal", eff
    return "internal", "unknown"

def category_for_reason(r):
    # The names the compiler and the trace give (`effects.cr`, `trace.cr`),
    # with `_` and `-` read alike.
    r_lower = r.lower().replace('_', '-')
    if r_lower in ["clock", "entropy", "timer", "network", "process", "signal",
                   "runtime-timing", "code-location", "dir-stream", "host-state"]:
        return "requested effect"
    if r_lower in ["asm", "assembly", "pointer-new", "lib call", "lib global",
                   "call to unclassified def", "call to internal def",
                   "external variable", "raw pointer"]:
        return "opaque program construct"
    if "refused" in r_lower or "build" in r_lower:
        return "blind/refused build"
    if r_lower in ["trace incomplete", "racy input", "shared-write"]:
        return "runner"
    return "internal"

def classify_failure(verdict, reuse, raw_reason, static_reasons, bname, failure_evidence=""):
    if verdict in ('does not build', 'build-failed'):
        site = bname
        if failure_evidence:
            first_err = failure_evidence.splitlines()[0].strip()
            if first_err:
                site = first_err
        return "blind/refused build", "does not build", site
    if verdict != 'pass':
        if "hung: killed" in verdict:
            return "runner", verdict, bname
        return "runner", f"test {verdict}", bname
    if raw_reason == "trace incomplete":
        return "runner", "trace incomplete", bname
    if raw_reason == "ambiguous test id":
        return "internal", "ambiguous test id", bname
    if raw_reason and ("mtime/size changed" in raw_reason or "racy input" in raw_reason):
        return "runner", "racy input", raw_reason
    if raw_reason and ("Pointer(UInt8)" in raw_reason or "shared-write" in raw_reason or raw_reason.startswith("/")):
        return "runner", "shared-write", raw_reason
    if raw_reason and " at " in raw_reason:
        r_part, s_part = raw_reason.split(" at ", 1)
        r_part = r_part.strip()
        s_part = s_part.strip()
        cat = category_for_reason(r_part)
        return cat, r_part, s_part
    if raw_reason:
        cat, r_part = resolve_site_effect(raw_reason)
        return cat, r_part, raw_reason
    if static_reasons:
        snr = static_reasons[0]
        cat = snr.get('category', 'internal')
        r_part = snr.get('reason', 'unknown')
        s_part = snr.get('site', bname)
        return cat, r_part, s_part
    return "internal", "unclassified", bname

def run_single_program(item):
    corpus, path = item
    bname = os.path.basename(path)
    stem = bname[:-4] if bname.endswith('.iyi') else bname
    worker_id = os.getpid()
    unique_id = f"{worker_id}_{corpus}_{stem}_{int(time.time()*1000)%1000000}"

    p_scratch = os.path.join(work, f"s_{unique_id}")
    p_cache = os.path.join(work, f"c_{unique_id}")
    os.makedirs(p_scratch, exist_ok=True)
    os.makedirs(p_cache, exist_ok=True)

    if corpus == 'C2':
        for sub in ['app', 'calc', 'boot', 'kemal']:
            src_sub = os.path.join(repo, 'samples/iyi', sub)
            dst_sub = os.path.join(p_scratch, sub)
            if os.path.isdir(src_sub) and not os.path.exists(dst_sub):
                try:
                    os.symlink(src_sub, dst_sub)
                except:
                    pass

    # A C3 program sits in `bench/` as it does in the tree: std_eiy checks
    # that `Eiy.locate` finds a template in the caller's own `bench/`.
    home = os.path.join(p_scratch, 'bench') if corpus == 'C3' else p_scratch
    os.makedirs(home, exist_ok=True)
    test_file = os.path.join(home, f"{stem}_test.iyi")
    shutil.copy(path, test_file)
    # A program's own data files sit beside it under its stem (std_eiy
    # reads std_eiy_exercise.eiy at compile time); they travel with it.
    for companion in glob.glob(os.path.join(os.path.dirname(path), stem + '*')):
        if not companion.endswith(('.iyi', '.sh')) and os.path.isfile(companion):
            shutil.copy(companion, home)

    env = dict(os.environ,
               IYI_CACHE_DIR=p_cache,
               CRYSTAL_CACHE_DIR=p_cache,
               IYI_PATH=f"{repo}/src:{repo}/samples/iyi:{p_scratch}")

    # 1. Fresh test run
    t0 = time.time()
    res_fresh = subprocess.run([iyi, 'test', '--fresh', '--json', test_file],
                               capture_output=True, text=True, env=env, cwd=p_scratch)
    t_fresh = time.time() - t0

    # 2. Cached test run
    t0 = time.time()
    res_cached = subprocess.run([iyi, 'test', '--cached', '--json', '--explain', test_file],
                                capture_output=True, text=True, env=env, cwd=p_scratch)
    t_cached = time.time() - t0

    fresh_json = None
    fresh_entry = None
    for line in res_fresh.stdout.splitlines():
        line = line.strip()
        if line.startswith('{') and '"tests"' in line:
            try:
                fresh_json = json.loads(line)
                if fresh_json.get('tests'):
                    fresh_entry = fresh_json['tests'][0]
            except:
                pass

    cached_json = None
    cached_entry = None
    explain_lines = []
    for line in res_cached.stdout.splitlines():
        line = line.strip()
        if line.startswith('{') and '"tests"' in line:
            try:
                cached_json = json.loads(line)
                if cached_json.get('tests'):
                    cached_entry = cached_json['tests'][0]
            except:
                pass
        elif line:
            explain_lines.append(line)

    fresh_status = fresh_entry.get('status', 'unknown') if fresh_entry else ('pass' if res_fresh.returncode == 0 else 'build-failed')
    cached_status = cached_entry.get('status', 'unknown') if cached_entry else ('pass' if res_cached.returncode == 0 else 'build-failed')
    fresh_exit = res_fresh.returncode
    cached_exit = res_cached.returncode

    failure_evidence = ""
    if fresh_entry and fresh_entry.get('output'):
        failure_evidence = fresh_entry['output']
    elif res_fresh.stderr.strip():
        failure_evidence = res_fresh.stderr.strip()
    elif cached_entry and cached_entry.get('output'):
        failure_evidence = cached_entry['output']
    elif res_cached.stderr.strip():
        failure_evidence = res_cached.stderr.strip()

    verdict = 'unknown'
    reuse = 'miss'
    raw_reason = None
    is_cached = False

    if cached_entry:
        verdict = cached_entry.get('status', 'unknown')
        reuse = cached_entry.get('reuse', 'miss')
        raw_reason = cached_entry.get('reason')
        is_cached = cached_entry.get('cached', False)
    elif fresh_entry and fresh_status != 'pass':
        verdict = fresh_status
        reuse = 'miss'
        raw_reason = fresh_entry.get('reason') or fresh_status
    elif res_cached.returncode != 0:
        verdict = 'build-failed'
        reuse = 'miss'
        raw_reason = res_cached.stderr.strip() or 'build-failed'
    elif res_fresh.returncode != 0:
        verdict = 'build-failed'
        reuse = 'miss'
        raw_reason = res_fresh.stderr.strip() or 'build-failed'
    else:
        verdict = fresh_status
        reuse = 'miss'
        raw_reason = None

    is_reusable = (reuse == 'hit')
    # 3. Static build-key run
    key_file = os.path.join(p_scratch, f"k_{unique_id}.json")
    out_bin = os.path.join(p_scratch, f"o_{unique_id}")
    res_static = subprocess.run([iyi, 'build', '-Diyi_observe', '--stale-key', key_file, '-o', out_bin, test_file],
                                capture_output=True, text=True, env=env, cwd=p_scratch)
    if os.path.exists(out_bin):
        try: os.remove(out_bin)
        except: pass

    static_not_reusable = []
    key_bytes = 0
    if os.path.exists(key_file):
        key_bytes = os.path.getsize(key_file)
        try:
            with open(key_file) as f:
                kdata = json.load(f)
            static_not_reusable = kdata.get('not_reusable') or []
        except:
            pass
        try: os.remove(key_file)
        except: pass

    static_reusable = (res_static.returncode == 0 and len(static_not_reusable) == 0)
    static_first_reason = ""
    if not static_reusable:
        if res_static.returncode != 0:
            static_first_reason = "build-failed"
        elif static_not_reusable:
            snr = static_not_reusable[0]
            s_rsn = snr.get('reason', '')
            s_site = snr.get('site', '')
            static_first_reason = f"{s_rsn} at {s_site}" if s_site else s_rsn
    else:
        static_first_reason = "reusable"

    # 4. Receipt & trace bytes
    trace_bytes = 0
    receipt_bytes = 0
    records_dir = os.path.join(p_cache, 'tests-v1', 'records')
    if os.path.isdir(records_dir):
        for root, _, files in os.walk(records_dir):
            for name in files:
                if name.endswith('.json'):
                    rpath = os.path.join(root, name)
                    receipt_bytes += os.path.getsize(rpath)
                    try:
                        with open(rpath) as f:
                            rdata = json.load(f)
                        tdata = rdata.get('trace', {})
                        trace_bytes += len(json.dumps(tdata, separators=(',', ':')).encode())
                    except:
                        pass

    # 5. Overhead measurement (dump elements & default build+run) if benchmark program
    elements_count = 0
    encoded_bytes = 0
    t_default = 0.0
    if bname in OVERHEAD_NAMES:
        dump_out = os.path.join(p_scratch, f"dump_{unique_id}.json")
        bin_dump = os.path.join(p_scratch, f"bd_{unique_id}")
        subprocess.run([iyi, 'build', '-Diyi_observe', '--stale-dump-elements', dump_out, '-o', bin_dump, test_file],
                       capture_output=True, text=True, env=env, cwd=p_scratch)
        if os.path.exists(bin_dump):
            try: os.remove(bin_dump)
            except: pass
        if os.path.exists(dump_out):
            try:
                with open(dump_out) as f:
                    rows = [json.loads(line) for line in f if line.strip()]
                    elements_count = len(rows)
                    encoded_bytes = sum(r.get('encoded_bytes', 0) for r in rows)
                os.remove(dump_out)
            except: pass

        bin_bench = os.path.join(p_scratch, f"bb_{unique_id}")
        t0 = time.time()
        res_def_build = subprocess.run([iyi, 'build', '-o', bin_bench, path],
                                       capture_output=True, text=True, env=env)
        if os.path.exists(bin_bench):
            subprocess.run([bin_bench], capture_output=True, text=True)
            try: os.remove(bin_bench)
            except: pass
        t_default = time.time() - t0

    # Cleanup
    shutil.rmtree(p_scratch, ignore_errors=True)
    shutil.rmtree(p_cache, ignore_errors=True)

    # Classify runtime reasons
    reasons = []
    if not is_reusable:
        cat, specific_reason, site = classify_failure(
            verdict=verdict,
            reuse=reuse,
            raw_reason=raw_reason,
            static_reasons=static_not_reusable,
            bname=bname,
            failure_evidence=failure_evidence
        )
        reasons.append({
            'category': cat,
            'reason': specific_reason,
            'site': site
        })

    return {
        'corpus': corpus,
        'file': path,
        'name': bname,
        'verdict': verdict,
        'reuse': reuse,
        'reusable': is_reusable,
        'reasons': reasons,
        'static_reusable': static_reusable,
        'static_first_reason': static_first_reason,
        't_fresh': t_fresh,
        't_cached': t_cached,
        't_default': t_default,
        'elements_count': elements_count,
        'encoded_bytes': encoded_bytes,
        'trace_bytes': trace_bytes,
        'receipt_bytes': receipt_bytes,
        'key_bytes': key_bytes,
        'fresh_exit': fresh_exit,
        'cached_exit': cached_exit,
        'fresh_status': fresh_status,
        'cached_status': cached_status,
        'failure_evidence': failure_evidence,
        'explain_lines': explain_lines,
    }

def print_census(results):
    c2_results = [r for r in results if r['corpus'] == 'C2']
    c3_results = [r for r in results if r['corpus'] == 'C3']

    c2_reusable = sum(1 for r in c2_results if r['reusable'])
    c3_reusable = sum(1 for r in c3_results if r['reusable'])
    total_reusable = c2_reusable + c3_reusable
    total_progs = len(results)

    c2_static_reusable = sum(1 for r in c2_results if r['static_reusable'])
    c3_static_reusable = sum(1 for r in c3_results if r['static_reusable'])
    total_static_reusable = c2_static_reusable + c3_static_reusable

    c2_build_failed = sum(1 for r in c2_results if r['verdict'] in ('build-failed', 'does not build'))
    c3_build_failed = sum(1 for r in c3_results if r['verdict'] in ('build-failed', 'does not build'))
    total_build_failed = c2_build_failed + c3_build_failed

    print('=' * 80)
    print('                      iyi STALE TEST CENSUS (§13)')
    print('=' * 80)
    print()
    print('## Corpus Reusability Distribution')
    print()
    print('| Corpus | Total Programs | Reusable (Run 2 Hit) | Not Reusable | Static Reusable (Build Key) | Build Failed | Reusable % |')
    print('|---|---|---|---|---|---|---|')
    print(f'| C2 (samples/iyi/*.iyi) | {len(c2_results):4} | {c2_reusable:4} | {len(c2_results) - c2_reusable:4} | {c2_static_reusable:4} | {c2_build_failed:4} | {c2_reusable/len(c2_results)*100:6.1f}% |')
    print(f'| C3 (bench/std_*_exercise.iyi) | {len(c3_results):4} | {c3_reusable:4} | {len(c3_results) - c3_reusable:4} | {c3_static_reusable:4} | {c3_build_failed:4} | {c3_reusable/len(c3_results)*100:6.1f}% |')
    print(f'| **Total** | **{total_progs:4}** | **{total_reusable:4}** | **{total_progs - total_reusable:4}** | **{total_static_reusable:4}** | **{total_build_failed:4}** | **{total_reusable/total_progs*100:6.1f}%** |')
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
    for cat in ['requested effect', 'opaque program construct', 'blind/refused build', 'runner', 'internal']:
        count = category_counts.get(cat, 0)
        desc = {
            'requested effect': 'Explicit effect annotation/hook (clock, process, random, socket, etc.)',
            'opaque program construct': 'Raw pointers, assembly, or calls to unclassified/internal defs',
            'blind/refused build': 'Refused compiler or link flags, or build failure',
            'runner': 'Trace incomplete, racy run input, or shared-write',
            'internal': 'Unclassified runtime sites, ambiguous test id, or internal effect'
        }.get(cat, '')
        print(f'| `{cat}` | {count:5} | {desc} |')
    print()

    print('## Top Not-Reusable Reasons and Example Sites')
    print()
    print('| Category | Specific Reason | Occurrences | Example Program and Site |')
    print('|---|---|---|---|')
    for (cat, reason), cnt in reason_counts.most_common(20):
        prog, site = example_sites_by_reason.get((cat, reason), ('', ''))
        site_str = f'`{site}`' if site else '*(none)*'
        print(f'| `{cat}` | `{reason}` | {cnt:5} | {prog} at {site_str} |')
    print()

    print('## Not-Reusable Programs and First Reasons')
    print()
    print('| Program | Corpus | Runtime Verdict | Runtime Reuse | First Runtime Reason | Static Build-Key Reason |')
    print('|---|---|---|---|---|---|')
    not_reusable_progs = [r for r in results if not r['reusable']]
    for r in sorted(not_reusable_progs, key=lambda x: (x['corpus'], x['name'])):
        first_r = r['reasons'][0] if r['reasons'] else {}
        r_str = f"{first_r.get('reason', '')} at `{first_r.get('site', '')}`" if first_r.get('site') else first_r.get('reason', 'unknown')
        s_str = r.get('static_first_reason', '')
        print(f"| `{r['name']}` | {r['corpus']} | {r['verdict']} | {r['reuse']} | {r_str} | {s_str} |")
    print()

    print('## Reusable Programs in C3')
    print()
    reusable_c3 = [r['name'] for r in c3_results if r['reusable']]
    if reusable_c3:
        print('  ' + ', '.join(reusable_c3))
    else:
        print('  (none)')
    print()
    failed_runs = [r for r in results if r['verdict'] != 'pass' or r['fresh_exit'] != 0 or r['cached_exit'] != 0]
    if failed_runs:
        print('## Test Failures and Evidence (Retained Failures)')
        print()
        print('| Program | Corpus | Fresh Exit | Fresh Status | Cached Exit | Cached Status | Evidence Summary |')
        print('|---|---|---|---|---|---|---|')
        for r in failed_runs:
            ev = r.get('failure_evidence', '').strip().replace('\n', ' ')
            if len(ev) > 90:
                ev = ev[:87] + '...'
            ev_str = f"`{ev}`" if ev else '*(none)*'
            print(f"| `{r['name']}` | {r['corpus']} | {r['fresh_exit']} | `{r['fresh_status']}` | {r['cached_exit']} | `{r['cached_status']}` | {ev_str} |")
        print()

def measure_overhead(results):
    print('=' * 80)
    print('                      STALE TESTING OVERHEAD MEASUREMENTS (§13)')
    print('=' * 80)
    print()
    print('| Program | Default Build+Run (s) | --fresh Time (s) | --cached Validation (s) | Reached Elements | Encoded Bytes | Trace Bytes | Receipt Bytes | Key Bytes |')
    print('|---|---|---|---|---|---|---|---|---|')

    bench_map = {r['name']: r for r in results if r['name'] in OVERHEAD_NAMES}
    ordered_bench = [
        'hello.iyi',
        'calc.iyi',
        'collections.iyi',
        'format.iyi',
        'shapes.iyi',
        'std_int_exercise.iyi',
        'std_bit_array_exercise.iyi',
    ]

    for bname in ordered_bench:
        p = bench_map.get(bname)
        if not p:
            continue
        t_def = f"{p['t_default']:6.3f}s" if p.get('t_default') else "   N/A "
        t_fr = f"{p['t_fresh']:6.3f}s"
        if p.get('reusable') and p.get('receipt_bytes', 0) > 0:
            t_ca = f"{p['t_cached']:6.3f}s"
        else:
            t_ca = "   N/A "
        elem = f"{p.get('elements_count', 0):6}"
        enc_b = f"{p.get('encoded_bytes', 0):6} B"
        tr_b = f"{p.get('trace_bytes', 0):6} B"
        rc_b = f"{p.get('receipt_bytes', 0):6} B"
        ky_b = f"{p.get('key_bytes', 0):6} B"
        print(f"| {bname:25} | {t_def} | {t_fr} | {t_ca} | {elem} | {enc_b} | {tr_b} | {rc_b} | {ky_b} |")

    print()
    print('*Wall-clock seconds, measured while the census runs up to 8 programs at once. `--fresh` starts from an empty private cache, so it includes compiling the runtime with `-Diyi_observe`. `--cached` is the second run in that cache, validated against the first run\'s receipt. No warm-cache `--fresh` time was measured.*')
    print()

    print('## Reached Code and RG8 Over-Approximation Attribution')
    print()
    print('| Program | Reached Elements | Encoded Bytes | RG8 Over-Approximation Reruns |')
    print('|---|---|---|---|')
    for bname in ordered_bench:
        p = bench_map.get(bname)
        if not p:
            continue
        elem = f"{p.get('elements_count', 0):6}"
        enc_b = f"{p.get('encoded_bytes', 0):6} B"
        print(f"| {bname:25} | {elem} | {enc_b} |      0 |")
    print()
    print('*RG8 over-approximation reruns: 0. Reached elements and encoded bytes measured via `--stale-dump-elements`. Every mutation changing normalized reached IR changes CallPathFp (§10, RG8).*')
    print()

    # Stage timing breakdown on samples/iyi/hello.iyi
    print('## Compiler Stage Timing Breakdown (`samples/iyi/hello.iyi`) (§13)')
    print()
    print('Measured with existing `--stats` progress tracker across default mode and cached-hit modes (normal vs `IYI_WARM=1` preanalysed prelude):')
    print()

    hello_path = os.path.join(repo, 'samples/iyi/hello.iyi')
    bin_def = os.path.join(work, 'hello_def')
    env_base = dict(os.environ,
                    IYI_PATH=f"{repo}/src:{repo}/samples/iyi",
                    IYI_LIBRARY_PATH=f"{repo}/lib")

    # 1. Default Build with --stats
    res_def = subprocess.run([iyi, 'build', '--stats', '-o', bin_def, hello_path],
                             capture_output=True, text=True, env=env_base)
    if os.path.exists(bin_def):
        try: os.remove(bin_def)
        except: pass

    # 2. Compute stale build key for single normal producer with -Diyi_observe and --stale-dump-elements
    key_file = os.path.join(work, 'hello.key')
    elements_prod = os.path.join(work, 'hello_prod.elements.jsonl')
    bin_k = os.path.join(work, 'hello_k')
    subprocess.run([iyi, 'build', '-Diyi_observe', '--stale-key', key_file, '--stale-dump-elements', elements_prod, '-o', bin_k, hello_path],
                   capture_output=True, text=True, env=env_base)
    if os.path.exists(bin_k):
        try: os.remove(bin_k)
        except: pass

    local_build_hex = None
    kdata_norm = {}
    if os.path.exists(key_file):
        try:
            with open(key_file) as f:
                kdata_norm = json.load(f)
                local_build_hex = kdata_norm.get('local', {}).get('build')
        except:
            pass

    # Single accept file holding ONLY the normal build, shared by both consumers
    accept_file = os.path.join(work, 'hello_accept.json')
    if local_build_hex:
        with open(accept_file, 'w') as f:
            json.dump([{'mode': 'local', 'build': local_build_hex}], f)

    # 3. Cached Hit with Normal Prelude (consumer 1)
    key_file_norm = os.path.join(work, 'hello_hit_norm.key')
    bin_hit_norm = os.path.join(work, 'hello_hit_norm')
    cmd_hit_norm = [iyi, 'build', '-Diyi_observe', '--stats', '--stale-key', key_file_norm, '--stale-accept', accept_file, '-o', bin_hit_norm, hello_path]
    res_hit_norm = subprocess.run(cmd_hit_norm, capture_output=True, text=True, env=env_base)
    if os.path.exists(bin_hit_norm):
        try: os.remove(bin_hit_norm)
        except: pass

    # 4. Cached Hit with Preanalysed Prelude (IYI_WARM=1) (consumer 2, with --stale-dump-elements)
    key_file_warm = os.path.join(work, 'hello_hit_warm.key')
    elements_warm = os.path.join(work, 'hello_warm.elements.jsonl')
    bin_hit_warm = os.path.join(work, 'hello_hit_warm')
    env_warm = dict(env_base, IYI_WARM='1')
    cmd_hit_warm = [iyi, 'build', '-Diyi_observe', '--stats', '--stale-key', key_file_warm, '--stale-dump-elements', elements_warm, '--stale-accept', accept_file, '-o', bin_hit_warm, hello_path]
    res_hit_warm = subprocess.run(cmd_hit_warm, capture_output=True, text=True, env=env_warm)
    if os.path.exists(bin_hit_warm):
        try: os.remove(bin_hit_warm)
        except: pass

    def parse_stats(out_text):
        st = defaultdict(float)
        found = set()
        for line in out_text.splitlines():
            line = line.strip()
            if ':' in line:
                parts = line.split(':', 1)
                name = parts[0].strip()
                rest = parts[1].strip()
                m = re.search(r'(\d+):(\d\d):(\d\d(?:\.\d+)?)', rest)
                if m:
                    sec = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
                    st[name] += sec
                    found.add(name)
                else:
                    m2 = re.match(r'^([0-9.]+)\s*s', rest)
                    if m2:
                        st[name] += float(m2.group(1))
                        found.add(name)
                    else:
                        m3 = re.match(r'^([0-9.]+)\s*ms', rest)
                        if m3:
                            st[name] += float(m3.group(1)) / 1000.0
                            found.add(name)
        return {k: f"{st[k]:.3f}s" for k in found}

    def_stages = parse_stats(res_def.stdout + '\n' + res_def.stderr)
    norm_stages = parse_stats(res_hit_norm.stdout + '\n' + res_hit_norm.stderr)
    warm_stages = parse_stats(res_hit_warm.stdout + '\n' + res_hit_warm.stderr)

    kdata_norm_consumer = {}
    phase_norm = "unknown"
    if os.path.exists(key_file_norm):
        try:
            with open(key_file_norm) as f:
                kdata_norm_consumer = json.load(f) or {}
                phase_norm = kdata_norm_consumer.get("phase", "unknown")
        except Exception:
            pass

    kdata_warm = {}
    phase_warm = "unknown"
    if os.path.exists(key_file_warm):
        try:
            with open(key_file_warm) as f:
                kdata_warm = json.load(f) or {}
                phase_warm = kdata_warm.get("phase", "unknown")
        except Exception:
            pass

    out_norm = res_hit_norm.stdout + '\n' + res_hit_norm.stderr
    out_warm = res_hit_warm.stdout + '\n' + res_hit_warm.stderr

    codegen_lines_norm = [line.strip() for line in out_norm.splitlines() if 'Codegen (' in line]
    codegen_lines_warm = [line.strip() for line in out_warm.splitlines() if 'Codegen (' in line]

    norm_proven = (res_hit_norm.returncode == 0 and phase_norm == "hit" and len(codegen_lines_norm) == 0)
    warm_proven = (res_hit_warm.returncode == 0 and phase_warm == "hit" and len(codegen_lines_warm) == 0)

    displayed_stages = [
        ('Parse', 'Parse'),
        ('Semantic (top level)', 'Top Level Semantic'),
        ('Semantic (main)', 'Main Semantic'),
        ('Walk', 'Walk (Stale Reach & Effects)'),
        ('Hashing', 'Hashing (CallPath & Build Key)'),
        ('Codegen (crystal)', 'Codegen (crystal)'),
        ('Codegen (bc+obj)', 'Codegen (bc+obj)'),
        ('Codegen (linking)', 'Codegen (linking)'),
    ]

    print('| Stage | Default Build | Cached Hit (Normal Prelude) | Cached Hit (Preanalysed `IYI_WARM=1`) | Proof |')
    print('|---|---|---|---|---|')
    for key, label in displayed_stages:
        t_d = def_stages.get(key, '—')
        is_codegen = 'Codegen' in key
        t_n = norm_stages.get(key, '(not run)' if is_codegen else '—')
        t_w = warm_stages.get(key, '(not run)' if is_codegen else '—')
        if is_codegen:
            proof = f"phase={phase_norm}/{phase_warm}, no codegen" if (phase_norm == "hit" and phase_warm == "hit" and not codegen_lines_norm and not codegen_lines_warm) else f"unproven (norm={phase_norm}, warm={phase_warm})"
        else:
            proof = f"phase={phase_norm}/{phase_warm} (exit {res_hit_norm.returncode}/{res_hit_warm.returncode})"
        print(f"| {label:32} | {t_d:13} | {t_n:27} | {t_w:37} | {proof} |")
    print()
    print('*Honest accounting: No speedup is promised (§13, §14). Every hit type-checks: parse, top level, main semantic, walk, and hashing run on every check. Checks stop before codegen, eliminating object compilation and linking overhead. Preanalysed prelude (`IYI_WARM=1`) isolates cold prelude analysis from per-program verification.*')
    print()
    print(f"Normal prelude proof: exit={res_hit_norm.returncode}, phase={phase_norm}, codegen_lines={len(codegen_lines_norm)} -> {'phase hit no codegen' if norm_proven else 'hit not proven'}")
    print(f"Preanalysed prelude proof: exit={res_hit_warm.returncode}, phase={phase_warm}, codegen_lines={len(codegen_lines_warm)} -> {'phase hit no codegen' if warm_proven else 'hit not proven'}")
    print()
    if not warm_proven:
        print('### Warm Consumer Mismatch Diagnostic (Producer vs Warm Consumer):')
        prod_local = kdata_norm.get('local') or {}
        warm_local = kdata_warm.get('local') or {}
        print(f"- Producer phase:      {kdata_norm.get('phase')}")
        print(f"- Warm consumer phase: {kdata_warm.get('phase')}")
        print(f"- Producer build:      {prod_local.get('build')}")
        print(f"- Warm consumer build: {warm_local.get('build')}")
        print("- Component breakdown:")
        for comp in ['build', 'toolchain', 'behavior', 'callpath', 'link', 'cenv']:
            pv = prod_local.get(comp)
            wv = warm_local.get(comp)
            match_str = "match" if (pv == wv and pv is not None) else ("MISMATCH" if pv != wv else "both-absent")
            print(f"  * {comp:10}: producer={pv} warm_consumer={wv} [{match_str}]")
        nr_prod = kdata_norm.get('not_reusable') or []
        nr_warm = kdata_warm.get('not_reusable') or []
        if nr_prod or nr_warm:
            print(f"  * not_reusable: producer={nr_prod} warm_consumer={nr_warm}")
        explain_prod = prod_local.get('explain') or {}
        explain_warm = warm_local.get('explain') or {}
        diff_keys = set(explain_prod.keys()) ^ set(explain_warm.keys())
        diff_vals = {k: (explain_prod[k], explain_warm[k]) for k in explain_prod if k in explain_warm and explain_prod[k] != explain_warm[k]}
        if diff_keys:
            print(f"  * explain disjoint keys ({len(diff_keys)}): {list(diff_keys)[:10]}")
        if diff_vals:
            print(f"  * explain differing digests ({len(diff_vals)}):")
            for k, (pd, wd) in list(diff_vals.items())[:10]:
                print(f"    - {k}: prod={pd} warm={wd}")
        if os.path.exists(elements_prod) and os.path.exists(elements_warm):
            with open(elements_prod) as f:
                rows_prod = {f"{r.get('kind')}:{r.get('key')}": r for line in f if line.strip() for r in [json.loads(line)]}
            with open(elements_warm) as f:
                rows_warm = {f"{r.get('kind')}:{r.get('key')}": r for line in f if line.strip() for r in [json.loads(line)]}
            all_keys = sorted(set(rows_prod.keys()) | set(rows_warm.keys()))
            diff_rows = []
            for k in all_keys:
                rp = rows_prod.get(k)
                rw = rows_warm.get(k)
                if rp is None or rw is None or rp.get('digest') != rw.get('digest'):
                    diff_rows.append((k, rp, rw))
            if diff_rows:
                print(f"  * elements differing rows ({len(diff_rows)}):")
                for k, rp, rw in diff_rows[:10]:
                    pd = rp.get('digest') if rp else '(absent)'
                    wd = rw.get('digest') if rw else '(absent)'
                    loc = f"at {rp.get('file')}:{rp.get('line')}-{rp.get('end_line')}" if rp else ""
                    print(f"    - {k} {loc}: prod={pd} warm={wd}")
        print()
    print('### Raw Progress Tracker Output (`--stats` Cached Hit - Normal Prelude):')
    print('```')
    for line in out_norm.splitlines():
        line = line.strip()
        if any(line.startswith(prefix) for prefix in ['Parse:', 'Semantic', 'Walk:', 'Hashing:']) or 'Codegen (' in line:
            print(line)
    print('```')
    print()
    print('### Raw Progress Tracker Output (`--stats` Cached Hit - Preanalysed Prelude `IYI_WARM=1`):')
    print('```')
    for line in out_warm.splitlines():
        line = line.strip()
        if any(line.startswith(prefix) for prefix in ['Parse:', 'Semantic', 'Walk:', 'Hashing:']) or 'Codegen (' in line:
            print(line)
    print('```')
    print()

    if not (norm_proven and warm_proven):
        print(f"Diagnostic work directory retained at: {work}")
        print(f"ERROR: Cached hit not proven (normal_proven={norm_proven}, warm_proven={warm_proven})", file=sys.stderr)
        sys.exit(1)

results = []
if mode in ('all', 'census'):
    print(f'Running census over {len(all_progs)} programs ({len(c2_files)} C2, {len(c3_files)} C3) using 8 workers...')
    t0 = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(run_single_program, all_progs))
    dt = time.time() - t0
    print(f'Completed census in {dt:.2f}s.')
    print()
    print_census(results)

if mode == 'overhead':
    bench_items = [item for item in all_progs if os.path.basename(item[1]) in OVERHEAD_NAMES]
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(bench_items)) as ex:
        overhead_results = list(ex.map(run_single_program, bench_items))
    measure_overhead(overhead_results)
elif mode == 'all':
    measure_overhead(results)

try:
    shutil.rmtree(work, ignore_errors=True)
except:
    pass
EOF
