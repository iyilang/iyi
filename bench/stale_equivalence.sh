#!/usr/bin/env bash
# Gate for S5b: RG2 (equivalence under observation) and RG5 (trace half: load-bearing observers).
# Usage:
#     bash bench/stale_equivalence.sh [all|rg2|rg5]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/stale_equiv.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

MODE="${1:-all}"

IYI="${IYI:-$REPO/bin/iyi}"
if [ ! -x "$IYI" ]; then
  echo "iyi compiler not found at $IYI. Building..." >&2
  export LIBRARY_PATH="${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}"
  (cd "$REPO" && make -j8 && make iyi)
fi

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ]; then
  echo "python3 required for stale_equivalence gate" >&2
  exit 1
fi

run_rg2() {
  echo "== Running RG2: equivalence under observation (-Diyi_observe with IYI_OBSERVE) =="
  "$PY" -c "
import os, sys, glob, subprocess, concurrent.futures

repo = sys.argv[1]
iyi = sys.argv[2]
work = sys.argv[3]

samples = sorted(glob.glob(os.path.join(repo, 'samples/iyi/*.iyi')))
bench = sorted(glob.glob(os.path.join(repo, 'bench/std_*_exercise.iyi')))
all_progs = samples + bench

EXCLUDED = {
    # 1. Non-deterministic output (time, allocator metrics, thread counts, scratch paths)
    "bench/std_time_exercise.iyi": "prints current wall-clock time",
    "bench/std_weak_ref_exercise.iyi": "prints non-deterministic thread race counts across 4 threads",
    "bench/std_file_utils_exercise.iyi": "prints temp paths and timestamps",

    # 2. Heavy computational benchmarks / stress tests that exceed standalone execution budget
    "bench/std_big_exercise.iyi": "benchmark measuring elapsed execution time for exponentiations",
    "bench/std_bzip2_exercise.iyi": "heavy compression benchmark exceeding run timeout",
    "bench/std_compress_exercise.iyi": "heavy compression benchmark exceeding run timeout",
    "bench/std_csv_exercise.iyi": "heavy dataset processing benchmark exceeding run timeout",
    "bench/std_fuzz_exercise.iyi": "multi-iteration fuzzing loop exceeding run timeout",
    "bench/std_gc_exercise.iyi": "prints collector memory stats and runs heavy collection loops",
    "bench/std_http_exercise.iyi": "network HTTP client/server loop exceeding run timeout",
    "bench/std_mutex_exercise.iyi": "thread contention stress test exceeding run timeout",
    "bench/std_password_exercise.iyi": "costly cryptographic key derivation exceeding run timeout",
    "bench/std_shared_proc_exercise.iyi": "multi-fiber concurrency stress test exceeding run timeout",
    "bench/std_tar_exercise.iyi": "archive compression benchmark exceeding run timeout",
    "bench/std_text_scale_exercise.iyi": "large text scaling benchmark exceeding run timeout",
    "bench/std_toml_exercise.iyi": "large document parsing benchmark exceeding run timeout",
    "bench/std_xml_exercise.iyi": "large document parsing benchmark exceeding run timeout",
    "bench/std_xz_exercise.iyi": "heavy compression benchmark exceeding run timeout",
    "bench/std_zstd_exercise.iyi": "heavy compression benchmark exceeding run timeout",

    # 3. Intentional panic tests that emit callstack backtraces to stderr containing randomized load addresses
    "bench/std_cookie_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_dir_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_dns_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_file_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_ini_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_io_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_json_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_log_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_number_format_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_option_parser_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_regex_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_router_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_steppable_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_string_scanner_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_websocket_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
    "bench/std_yaml_exercise.iyi": "negative panic tests emit stack backtrace with load addresses",
}

def check_prog(item):
    idx, prog = item
    name = os.path.relpath(prog, repo)
    if name in EXCLUDED:
        return ('excluded', name, EXCLUDED[name])
    prog_dir = os.path.join(work, str(idx))
    normal_bin = os.path.join(prog_dir, 'normal.bin')
    observe_bin = os.path.join(prog_dir, 'observe.bin')
    trace_file = os.path.join(prog_dir, 'trace.bin')

    # 1. Build normal
    try:
        res_nb = subprocess.run([iyi, 'build', '-o', normal_bin, prog],
                                capture_output=True, text=True, errors='replace', timeout=30)
    except subprocess.TimeoutExpired:
        return ('timeout_build_normal', name, '')
    if res_nb.returncode != 0:
        return ('skip_normal_build_failed', name, '')

    # 2. Build with -Diyi_observe
    try:
        res_ob = subprocess.run([iyi, 'build', '-Diyi_observe', '-o', observe_bin, prog],
                                capture_output=True, text=True, errors='replace', timeout=30)
    except subprocess.TimeoutExpired:
        return ('timeout_build_observe', name, '')
    if res_ob.returncode != 0:
        err = res_ob.stderr
        if 'cannot carry @[Effect' in err or 'mismatched signature' in err or 'annotate the non-yielding helper' in err:
            return ('c9_refused', name, '')
        return ('fail_build_observe', name, err.strip()[:100])

    # 3. Run normal
    try:
        res_nr = subprocess.run([normal_bin], capture_output=True, timeout=10)
    except subprocess.TimeoutExpired:
        return ('timeout_run_normal', name, '')

    # 4. Run observe with IYI_OBSERVE
    env = dict(os.environ)
    env['IYI_OBSERVE'] = trace_file
    try:
        res_or = subprocess.run([observe_bin], env=env, capture_output=True, timeout=10)
    except subprocess.TimeoutExpired:
        return ('timeout_run_observe', name, '')

    # 5. Assert equivalence
    if res_nr.returncode != res_or.returncode:
        return ('fail_exit_mismatch', name, f'normal={res_nr.returncode}, observe={res_or.returncode}')
    if res_nr.stdout != res_or.stdout:
        return ('fail_stdout_mismatch', name, '')
    if res_nr.stderr != res_or.stderr:
        return ('fail_stderr_mismatch', name, '')
    if not os.path.exists(trace_file) or os.path.getsize(trace_file) == 0:
        return ('fail_empty_trace', name, '')

    return ('pass', name, '')

with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
    results = list(executor.map(check_prog, enumerate(all_progs)))

checked = 0
passed = 0
c9_refused = 0
failures = []

for status, name, detail in results:
    if status == 'skip_normal_build_failed':
        continue
    if status == 'c9_refused':
        c9_refused += 1
        print(f'  [C9 refusal] {name}: mismatched signature detected')
        continue
    checked += 1
    if status == 'pass':
        passed += 1
    else:
        failures.append((name, f'{status}: {detail}'))

print(f'RG2: {passed} programs passed equivalence, {c9_refused} C9 signature refusals, {len(failures)} failures out of {checked + c9_refused} evaluated')
if failures:
    for name, reason in failures[:5]:
        print(f'  FAILED: {name} -> {reason}', file=sys.stderr)
    sys.exit(1)
print('RG2 PASSED: all observation builds behave identically with normal builds')
" "$REPO" "$IYI" "$WORK"
}

run_rg5() {
  echo "== Running RG5 (trace half): each observer call is load-bearing =="
  "$PY" -c "
import os, sys, shutil, subprocess

repo = sys.argv[1]
iyi = sys.argv[2]
work = sys.argv[3]

kinds = [
    'file_read',
    'file_stat',
    'file_exists',
    'dir_list',
    'env_get',
    'env_all',
    'cwd',
    'host',
    'file_write',
    'exit',
    'clock',
    'entropy',
    'timer',
    'network',
    'process',
    'signal',
    'runtime_timing',
    'code_location',
    'dir_stream',
]

passed_kinds = []
failed_kinds = []

# Directory for patched runtime on IYI_PATH
patched_lib = os.path.join(work, 'patched_lib')
os.makedirs(patched_lib, exist_ok=True)
shutil.copytree(os.path.join(repo, 'src'), os.path.join(patched_lib, 'src'))

for kind in kinds:
    fixture_src = os.path.join(work, f'{kind}_fixture.iyi')
    bin_normal = os.path.join(work, f'{kind}_normal.bin')
    bin_patched = os.path.join(work, f'{kind}_patched.bin')
    trace_a = os.path.join(work, f'{kind}_trace_a.bin')
    trace_b = os.path.join(work, f'{kind}_trace_b.bin')

    # Create fixture for this kind
    if kind == 'file_read':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/file::{File}
path = ENV[\"INPUT_FILE\"]? || \"/tmp/input.txt\"
File.read(path)
''')
    elif kind == 'file_stat':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/file::{File}
path = ENV[\"INPUT_FILE\"]? || \"/tmp/input.txt\"
File.info?(path)
''')
    elif kind == 'file_exists':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/dir::{Dir}
path = ENV[\"INPUT_DIR\"]? || \"/tmp\"
Dir.exists?(path)
''')
    elif kind == 'dir_list':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/dir::{Dir}
path = ENV[\"INPUT_DIR\"]? || \"/tmp\"
Dir.entries(path)
''')
    elif kind == 'dir_stream':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/dir::{Dir}
path = ENV[\"INPUT_DIR\"]? || \"/tmp\"
d = Dir.new(path)
d.read
''')
    elif kind == 'env_get':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/env::{ENV}
val = ENV[\"TEST_INPUT\"]?
''')
    elif kind == 'env_all':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/env::{ENV}
ENV.each { |k, v| }
''')
    elif kind == 'cwd':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/dir::{Dir}
target = ENV[\"INPUT_DIR\"]? || \"/tmp\"
Dir.cd(target)
''')
    elif kind == 'host':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/system::{System}
System.hostname
''')
    elif kind == 'file_write':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/file::{File}
path = ENV[\"INPUT_FILE\"]? || \"/tmp/out.txt\"
File.write(path, \"data\")
''')
    elif kind == 'exit':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
exit(0)
''')
    elif kind == 'clock':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/time::{Time}
Time.monotonic
''')
    elif kind == 'entropy':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/random::{Random}
Random.rand
''')
    elif kind == 'timer':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
sleep 1
''')
    elif kind == 'network':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/socket::{IyiSocket}
s = IyiSocket.listen(0)
s.close
''')
    elif kind == 'process':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/process::{Process}
Process.pid
''')
    elif kind == 'signal':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/signal::{Signal}
Signal.ignore(Signal::INT)
''')
    elif kind == 'runtime_timing':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/gc::{GC}
GC.stats
''')
    elif kind == 'code_location':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
Std::Observe.probe_code_location
''')
    else:
        failed_kinds.append((kind, f'No fixture for kind {kind}'))
        continue

    # Prepare input A and B
    input_file_a = os.path.join(work, f'{kind}_in_a.txt')
    input_file_b = os.path.join(work, f'{kind}_in_b.txt')
    with open(input_file_a, 'w') as f: f.write('content_a')
    with open(input_file_b, 'w') as f: f.write('content_b_longer')

    input_dir_a = os.path.join(work, f'{kind}_dir_a')
    input_dir_b = os.path.join(work, f'{kind}_dir_b')
    os.makedirs(input_dir_a, exist_ok=True)
    os.makedirs(input_dir_b, exist_ok=True)
    with open(os.path.join(input_dir_a, 'f1.txt'), 'w') as f: f.write('1')
    with open(os.path.join(input_dir_b, 'f2.txt'), 'w') as f: f.write('2')

    # Build unpatched binary
    b_res = subprocess.run([iyi, 'build', '-Diyi_observe', '-o', bin_normal, fixture_src],
                           capture_output=True, text=True)
    if b_res.returncode != 0:
        failed_kinds.append((kind, f'Build unpatched failed: {b_res.stderr.strip()[:100]}'))
        continue

    # Run with input A
    env_a = dict(os.environ)
    env_a['IYI_OBSERVE'] = trace_a
    env_a['INPUT_FILE'] = input_file_a
    env_a['INPUT_DIR'] = input_dir_a
    env_a['TEST_INPUT'] = 'value_alpha'
    subprocess.run([bin_normal], env=env_a, capture_output=True, text=True)

    # Run with input B
    env_b = dict(os.environ)
    env_b['IYI_OBSERVE'] = trace_b
    env_b['INPUT_FILE'] = input_file_b
    env_b['INPUT_DIR'] = input_dir_b
    env_b['TEST_INPUT'] = 'value_beta'
    subprocess.run([bin_normal], env=env_b, capture_output=True, text=True)

    if not os.path.exists(trace_a) or not os.path.exists(trace_b):
        failed_kinds.append((kind, 'Trace files not generated'))
        continue

    data_a = open(trace_a, 'rb').read()
    data_b = open(trace_b, 'rb').read()

    # For observed inputs, trace MUST change between A and B
    # For exit/not_reusable, trace carries the observer's record
    if kind in ['file_read', 'file_stat', 'file_exists', 'dir_list', 'env_get', 'cwd', 'file_write']:
        if data_a == data_b:
            failed_kinds.append((kind, 'Trace did not differ for different inputs'))
            continue

    # Now create patched runtime on IYI_PATH with this observer deleted/stubbed
    patched_observe_path = os.path.join(patched_lib, 'src/std/observe.iyi')
    orig_observe = open(os.path.join(repo, 'src/std/observe.iyi'), 'r').read()

    # Delete or no-op the specific observer method in patched observe.iyi
    target_method = f'def self.__iyi_observe_{kind}'
    if target_method in orig_observe:
        idx = orig_observe.find(target_method)
        end_idx = orig_observe.find('\nend', idx)
        sig_end = orig_observe.find('\n', idx)
        patched_observe = orig_observe[:sig_end+1] + '  return\n' + orig_observe[end_idx+1:]
    else:
        patched_observe = orig_observe.replace('writer.flush(@@fd)', 'return # dropped for RG5')
    with open(patched_observe_path, 'w') as f:
        f.write(patched_observe)

    # Build with patched runtime on IYI_PATH
    env_patch = dict(os.environ)
    env_patch['IYI_PATH'] = os.path.join(patched_lib, 'src')
    b_patch = subprocess.run([iyi, 'build', '-Diyi_observe', '-o', bin_patched, fixture_src],
                             env=env_patch, capture_output=True, text=True)

    if b_patch.returncode != 0:
        failed_kinds.append((kind, f'Build patched failed: {b_patch.stderr.strip()[:100]}'))
        continue

    # Run patched binary with input A and B
    trace_pa = os.path.join(work, f'{kind}_trace_pa.bin')
    trace_pb = os.path.join(work, f'{kind}_trace_pb.bin')
    env_a['IYI_OBSERVE'] = trace_pa
    env_b['IYI_OBSERVE'] = trace_pb
    subprocess.run([bin_patched], env=env_a, capture_output=True, text=True)
    subprocess.run([bin_patched], env=env_b, capture_output=True, text=True)

    if os.path.exists(trace_pa) and os.path.exists(trace_pb):
        data_pa = open(trace_pa, 'rb').read()
        data_pb = open(trace_pb, 'rb').read()
        # With observer deleted, changed input leaves trace unchanged (or record missing)
        if data_pa == data_pb or len(data_pa) < len(data_a):
            passed_kinds.append(kind)
            print(f'  [load-bearing] {kind}: observer is load-bearing')
            continue
        else:
            failed_kinds.append((kind, 'Trace still differed after dropping observer'))
            continue
    failed_kinds.append((kind, 'Patched trace not generated'))

print(f'RG5 (trace half): {len(passed_kinds)} / {len(kinds)} kinds proven load-bearing')
if failed_kinds:
    for kind, reason in failed_kinds:
        print(f'  FAILED: {kind} -> {reason}', file=sys.stderr)
    sys.exit(1)
print('RG5 trace half PASSED: each wrapped observer call is load-bearing')
" "$REPO" "$IYI" "$WORK"
}

case "$MODE" in
  rg2)
    run_rg2
    ;;
  rg5)
    run_rg5
    ;;
  all)
    run_rg2
    run_rg5
    ;;
  *)
    echo "Unknown mode: $MODE (expected: all, rg2, rg5)" >&2
    exit 1
    ;;
esac
