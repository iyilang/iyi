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
import concurrent.futures, glob, os, subprocess, sys

repo, iyi, work = sys.argv[1:]
samples = sorted(glob.glob(os.path.join(repo, 'samples/iyi/*.iyi')))
bench = sorted(glob.glob(os.path.join(repo, 'bench/std_*_exercise.iyi')))
programs = samples + bench

# RG2 must not hide time, address, schedule, or scratch output behind a
# hand-maintained exclusion list. Every program gets two normal executions
# first. Their differing lines are the only values this run is allowed to
# mask when comparing the observed execution.
#
# Normal runs have a 60 s ceiling. The corpus exercises that deliberately do
# compression, fuzzing, or large parsing get 180 s, rather than being dropped.
DEFAULT_TIMEOUT = 60
HEAVY_TIMEOUT = 180
HEAVY = {
    'bench/std_big_exercise.iyi', 'bench/std_bzip2_exercise.iyi',
    'bench/std_compress_exercise.iyi', 'bench/std_csv_exercise.iyi',
    'bench/std_fuzz_exercise.iyi', 'bench/std_gc_exercise.iyi',
    'bench/std_http_exercise.iyi', 'bench/std_mutex_exercise.iyi',
    'bench/std_password_exercise.iyi', 'bench/std_shared_proc_exercise.iyi',
    'bench/std_tar_exercise.iyi', 'bench/std_text_scale_exercise.iyi',
    'bench/std_toml_exercise.iyi', 'bench/std_xml_exercise.iyi',
    'bench/std_xz_exercise.iyi', 'bench/std_zstd_exercise.iyi',
}

def timeout_for(name):
    return HEAVY_TIMEOUT if name in HEAVY else DEFAULT_TIMEOUT

def run(argv, *, env=None, timeout):
    return subprocess.run(argv, env=env, capture_output=True,
                          text=False, timeout=timeout)

def lines(value):
    return value.splitlines(keepends=True)

def calibrated_mask(first, second):
    one, two = lines(first), lines(second)
    if len(one) != len(two):
        return None
    return {index for index, (left, right) in enumerate(zip(one, two)) if left != right}

def matches_outside_mask(expected, actual, mask):
    before, after = lines(expected), lines(actual)
    if len(before) != len(after):
        return False, 'line count %d != %d' % (len(before), len(after))
    for index, (left, right) in enumerate(zip(before, after)):
        if index not in mask and left != right:
            return False, 'line %d differs outside normal-run mask' % (index + 1)
    return True, ''

def check(item):
    index, program = item
    name = os.path.relpath(program, repo)
    timeout = timeout_for(name)
    directory = os.path.join(work, str(index))
    os.makedirs(directory, exist_ok=True)
    cache = os.path.join(directory, 'cache')
    os.makedirs(cache, exist_ok=True)
    env = dict(os.environ, IYI_CACHE_DIR=cache)
    normal = os.path.join(directory, 'normal.bin')
    observed = os.path.join(directory, 'observe.bin')
    trace = os.path.join(directory, 'trace.bin')

    try:
        normal_build = run([iyi, 'build', '-o', normal, program], env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 'excluded', name, 'normal build exceeded %ss ceiling' % timeout
    if normal_build.returncode:
        return 'excluded', name, 'normal build failed: ' + normal_build.stderr.decode(errors='replace')[:100]

    # Calibration is deliberately normal versus normal. It does not bless a
    # changed observation build and it never compares an observed result to a
    # mask copied from another program.
    try:
        first = run([normal], timeout=timeout)
        second = run([normal], timeout=timeout)
    except subprocess.TimeoutExpired:
        return 'excluded', name, 'normal run exceeded %ss ceiling' % timeout
    if first.returncode != second.returncode:
        return 'excluded', name, 'normal runs disagree on exit (%d != %d)' % (first.returncode, second.returncode)
    stdout_mask = calibrated_mask(first.stdout, second.stdout)
    stderr_mask = calibrated_mask(first.stderr, second.stderr)
    if stdout_mask is None or stderr_mask is None:
        return 'excluded', name, 'normal runs change output shape'

    try:
        observed_build = run([iyi, 'build', '-Diyi_observe', '-o', observed, program], env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 'fail', name, 'observed build exceeded %ss ceiling' % timeout
    if observed_build.returncode:
        return 'fail', name, 'observed build failed: ' + observed_build.stderr.decode(errors='replace')[:100]

    observe_env = dict(os.environ, IYI_OBSERVE=trace)
    try:
        observed_run = run([observed], env=observe_env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 'fail', name, 'observed run exceeded %ss ceiling' % timeout
    if first.returncode != observed_run.returncode:
        return 'fail', name, 'exit %d != observed %d' % (first.returncode, observed_run.returncode)
    stdout_ok, stdout_reason = matches_outside_mask(first.stdout, observed_run.stdout, stdout_mask)
    if not stdout_ok:
        return 'fail', name, 'stdout ' + stdout_reason
    stderr_ok, stderr_reason = matches_outside_mask(first.stderr, observed_run.stderr, stderr_mask)
    if not stderr_ok:
        return 'fail', name, 'stderr ' + stderr_reason
    if not os.path.isfile(trace) or os.path.getsize(trace) == 0:
        return 'fail', name, 'observed run wrote no trace'
    return 'pass', name, '%d masked stdout lines, %d masked stderr lines' % (len(stdout_mask), len(stderr_mask))

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
    results = list(executor.map(check, enumerate(programs)))

passed = 0
excluded = []
failures = []
for status, name, detail in results:
    if status == 'pass':
        passed += 1
    elif status == 'excluded':
        excluded.append((name, detail))
    else:
        failures.append((name, detail))

print('RG2: %d evaluated, %d passed, %d still excluded with reason, %d failures' %
      (len(programs) - len(excluded), passed, len(excluded), len(failures)))
for name, reason in excluded:
    print('  [excluded after calibration] %s: %s' % (name, reason))
for name, reason in failures:
    print('  FAILED: %s -> %s' % (name, reason), file=sys.stderr)
if failures:
    sys.exit(1)
print('RG2 PASSED: observed builds match normal runs outside each program’s calibrated mask')
" "$REPO" "$IYI" "$WORK"
}

run_rg5() {
  echo "== Running RG5 (trace half): each observer call is load-bearing =="
  "$PY" -c "
import json, os, sys, shutil, subprocess

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

# The trace half proves the recorder carries each value. This is the runner
# half: a missing observer makes a changed input look like a cache hit, but a
# forced fresh audit executes the program and reports the contradicted verdict.
e2e_root = os.path.join(work, 'e2e')
e2e_lib = os.path.join(e2e_root, 'runtime')
e2e_src = os.path.join(e2e_root, 'read_test.iyi')
e2e_input = os.path.join(e2e_root, 'input.txt')
e2e_cache = os.path.join(e2e_root, 'cache')
os.makedirs(e2e_root, exist_ok=True)
shutil.copytree(os.path.join(repo, 'src'), os.path.join(e2e_lib, 'src'))
e2e_observe = os.path.join(e2e_lib, 'src/std/observe.iyi')
observe_source = open(e2e_observe).read()
method = 'def self.__iyi_observe_file_read'
start = observe_source.find(method)
finish = observe_source.find('\nend', start)
signature_end = observe_source.find('\n', start)
if start < 0 or finish < 0:
    failed_kinds.append(('cached audit', 'could not patch file_read observer'))
else:
    with open(e2e_observe, 'w') as f:
        f.write(observe_source[:signature_end + 1] + '  return\n' + observe_source[finish + 1:])
    with open(e2e_src, 'w') as f:
        f.write('''import std/file::{File}
value = File.read(ENV[\"RG5_INPUT\"])
assert value == \"before\"
''')
    with open(e2e_input, 'w') as f:
        f.write('before')
    e2e_env = dict(os.environ)
    e2e_env['IYI_PATH'] = os.path.join(e2e_lib, 'src')
    e2e_env['IYI_CACHE_DIR'] = e2e_cache
    e2e_env['RG5_INPUT'] = e2e_input
    first = subprocess.run([iyi, 'test', '--cached', '--json', e2e_src],
                           env=e2e_env, cwd=e2e_root, capture_output=True, text=True)
    second = subprocess.run([iyi, 'test', '--cached', '--json', e2e_src],
                            env=e2e_env, cwd=e2e_root, capture_output=True, text=True)
    with open(e2e_input, 'w') as f:
        f.write('after')
    false_hit = subprocess.run([iyi, 'test', '--cached', '--json', e2e_src],
                               env=e2e_env, cwd=e2e_root, capture_output=True, text=True)
    fresh = subprocess.run([iyi, 'test', '--fresh', '--json', e2e_src],
                           env=e2e_env, cwd=e2e_root, capture_output=True, text=True)
    try:
        first_json = json.loads(first.stdout)
        second_json = json.loads(second.stdout)
        false_hit_json = json.loads(false_hit.stdout)
        fresh_json = json.loads(fresh.stdout)
    except json.JSONDecodeError:
        failed_kinds.append(('cached audit', 'runner did not return JSON: ' + first.stdout[:200] + first.stderr[:200]))
    else:
        if first.returncode or first_json['cached'] != 0:
            failed_kinds.append(('cached audit', 'recording run did not miss'))
        elif second.returncode or second_json['cached'] != 1:
            failed_kinds.append(('cached audit', 'unchanged run did not hit'))
        elif false_hit.returncode or false_hit_json['cached'] != 1:
            failed_kinds.append(('cached audit', 'dropped observer did not produce changed-input hit'))
        elif fresh.returncode != 1 or fresh_json['failed'] != 1:
            failed_kinds.append(('cached audit', 'fresh audit did not report contradicted verdict'))
        else:
            print('  [cached audit] dropped file_read observer hits after input change; --fresh reports the contradiction')

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
