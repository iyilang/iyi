#!/usr/bin/env bash
# Gate for S5b: RG2 (equivalence under observation), RG2a (equivalence with empty dir argument) and RG5 (trace half: load-bearing observers).
# Usage:
#     bash bench/stale_equivalence.sh [all|rg2|rg2a|rg5]
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
import concurrent.futures, glob, os, re, subprocess, sys

repo, iyi, work = sys.argv[1:]
sys.path.insert(0, os.path.join(repo, 'bench'))
from frames_equivalent import FRAME_RE, canonical_function
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
HEAVY_TIMEOUT = 300
HEAVY = {
    'bench/std_big_exercise.iyi', 'bench/std_bzip2_exercise.iyi',
    'bench/std_compress_exercise.iyi', 'bench/std_csv_exercise.iyi',
    'bench/std_curve25519_exercise.iyi', 'bench/std_digest_exercise.iyi',
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

def last_line(result):
    tail = result.stderr.strip().splitlines()[-1:] or result.stdout.strip().splitlines()[-1:]
    return tail[0].decode(errors='replace')[:160] if tail else '(no output)'

def lines(value):
    return value.splitlines(keepends=True)

NON_REUSABLE_STDOUT_PATTERNS = [
    re.compile(rb'^\s*mapped=\d+ since_collection=\d+ freed=\d+ kept=\d+ collections=\d+'),
    re.compile(rb'^\s*64 MiB copied with \d+ KiB allocated, compared with \d+ KiB'),
    re.compile(rb'^\s*wall clock steps: \d+ ns'),
]

def is_non_reusable_output(line):
    return any(p.match(line) for p in NON_REUSABLE_STDOUT_PATTERNS)

def normalize_stderr(raw):
    if not raw:
        return b''
    raw_lines = lines(raw)
    out = []
    for line in raw_lines:
        m = FRAME_RE.match(line.rstrip(b'\r\n'))
        if not m:
            out.append(line)
        else:
            idx = m.group(1)
            img = m.group(2)
            fn = canonical_function(m.group(3))
            out.append(b'  FRAME: ' + idx + b' ' + img + b' ' + fn + b'\n')
    return b''.join(out)

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
            if is_non_reusable_output(left) and is_non_reusable_output(right):
                continue
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
    stem = os.path.splitext(os.path.basename(program))[0]
    normal_dir = os.path.join(directory, 'normal')
    observed_dir = os.path.join(directory, 'observed')
    os.makedirs(normal_dir, exist_ok=True)
    os.makedirs(observed_dir, exist_ok=True)
    # The image column in backtraces records the executable's basename.
    # To compare normal and observed traces without masking the image column,
    # both binaries share the same basename in distinct directories.
    normal = os.path.join(normal_dir, stem)
    observed = os.path.join(observed_dir, stem)
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
        failed = first if first.returncode else second
        return 'excluded', name, 'normal runs disagree on exit (%d != %d): %s' % (first.returncode, second.returncode, last_line(failed))
    stdout_mask = calibrated_mask(first.stdout, second.stdout)
    norm_stderr1 = normalize_stderr(first.stderr)
    norm_stderr2 = normalize_stderr(second.stderr)
    stderr_mask = calibrated_mask(norm_stderr1, norm_stderr2)
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
        return 'fail', name, 'exit %d != observed %d: %s' % (first.returncode, observed_run.returncode, last_line(observed_run if observed_run.returncode else first))
    stdout_ok, stdout_reason = matches_outside_mask(first.stdout, observed_run.stdout, stdout_mask)
    if not stdout_ok:
        return 'fail', name, 'stdout ' + stdout_reason
    observed_stderr = normalize_stderr(observed_run.stderr)
    stderr_ok, stderr_reason = matches_outside_mask(norm_stderr1, observed_stderr, stderr_mask)
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
run_rg2a() {
  echo "== Running RG2a: equivalence with empty directory argument =="
  "$PY" -c "
import concurrent.futures, glob, os, re, subprocess, sys

repo, iyi, work = sys.argv[1:]
sys.path.insert(0, os.path.join(repo, 'bench'))
from frames_equivalent import FRAME_RE, canonical_function
samples = sorted(glob.glob(os.path.join(repo, 'samples/iyi/*.iyi')))
bench = sorted(glob.glob(os.path.join(repo, 'bench/std_*_exercise.iyi')))
programs = samples + bench

DEFAULT_TIMEOUT = 60
HEAVY_TIMEOUT = 300
HEAVY = {
    'bench/std_big_exercise.iyi', 'bench/std_bzip2_exercise.iyi',
    'bench/std_compress_exercise.iyi', 'bench/std_csv_exercise.iyi',
    'bench/std_curve25519_exercise.iyi', 'bench/std_digest_exercise.iyi',
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

def last_line(result):
    tail = result.stderr.strip().splitlines()[-1:] or result.stdout.strip().splitlines()[-1:]
    return tail[0].decode(errors='replace')[:160] if tail else '(no output)'

def lines(value):
    return value.splitlines(keepends=True)

NON_REUSABLE_STDOUT_PATTERNS = [
    re.compile(rb'^\s*mapped=\d+ since_collection=\d+ freed=\d+ kept=\d+ collections=\d+'),
    re.compile(rb'^\s*64 MiB copied with \d+ KiB allocated, compared with \d+ KiB'),
    re.compile(rb'^\s*wall clock steps: \d+ ns'),
]

def is_non_reusable_output(line):
    return any(p.match(line) for p in NON_REUSABLE_STDOUT_PATTERNS)

def normalize_stderr(raw):
    if not raw:
        return b''
    raw_lines = lines(raw)
    out = []
    for line in raw_lines:
        m = FRAME_RE.match(line.rstrip(b'\r\n'))
        if not m:
            out.append(line)
        else:
            idx = m.group(1)
            img = m.group(2)
            fn = canonical_function(m.group(3))
            out.append(b'  FRAME: ' + idx + b' ' + img + b' ' + fn + b'\n')
    return b''.join(out)

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
            if is_non_reusable_output(left) and is_non_reusable_output(right):
                continue
            return False, 'line %d differs outside normal-run mask' % (index + 1)
    return True, ''

def check_rg2a(item):
    index, program = item
    name = os.path.relpath(program, repo)
    timeout = timeout_for(name)
    directory = os.path.join(work, 'rg2a_' + str(index))
    os.makedirs(directory, exist_ok=True)
    cache = os.path.join(directory, 'cache')
    os.makedirs(cache, exist_ok=True)
    env = dict(os.environ, IYI_CACHE_DIR=cache)
    normal = os.path.join(directory, 'normal.bin')
    empty_dir = os.path.join(directory, 'empty_dir')
    os.makedirs(empty_dir, exist_ok=True)

    try:
        normal_build = run([iyi, 'build', '-o', normal, program], env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 'excluded', name, 'normal build exceeded %ss ceiling' % timeout
    if normal_build.returncode:
        return 'excluded', name, 'normal build failed: ' + normal_build.stderr.decode(errors='replace')[:100]

    # Calibration: two normal no-argument runs
    try:
        first = run([normal], timeout=timeout)
        second = run([normal], timeout=timeout)
    except subprocess.TimeoutExpired:
        return 'excluded', name, 'normal run exceeded %ss ceiling' % timeout

    if first.returncode != second.returncode:
        failed = first if first.returncode else second
        return 'excluded', name, 'normal runs disagree on exit (%d != %d): %s' % (first.returncode, second.returncode, last_line(failed))

    stdout_mask = calibrated_mask(first.stdout, second.stdout)
    norm_stderr1 = normalize_stderr(first.stderr)
    norm_stderr2 = normalize_stderr(second.stderr)
    stderr_mask = calibrated_mask(norm_stderr1, norm_stderr2)

    is_calib_excluded = (stdout_mask is None or stderr_mask is None)

    # Run once more with argv = [a fresh empty directory]
    try:
        empty_run = run([normal, empty_dir], timeout=timeout)
    except subprocess.TimeoutExpired:
        return 'fail', name, 'empty dir run exceeded %ss ceiling' % timeout

    # Programs excluded after calibration must still match on exit status
    if empty_run.returncode != first.returncode:
        return 'fail', name, 'exit %d != empty-dir exit %d: %s' % (first.returncode, empty_run.returncode, last_line(empty_run if empty_run.returncode else first))

    if is_calib_excluded:
        return 'excluded', name, 'normal runs change output shape (exit matched %d)' % first.returncode

    stdout_ok, stdout_reason = matches_outside_mask(first.stdout, empty_run.stdout, stdout_mask)
    if not stdout_ok:
        return 'fail', name, 'stdout ' + stdout_reason

    empty_stderr = normalize_stderr(empty_run.stderr)
    stderr_ok, stderr_reason = matches_outside_mask(norm_stderr1, empty_stderr, stderr_mask)
    if not stderr_ok:
        return 'fail', name, 'stderr ' + stderr_reason

    return 'pass', name, '%d masked stdout lines, %d masked stderr lines' % (len(stdout_mask), len(stderr_mask))

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
    results = list(executor.map(check_rg2a, enumerate(programs)))

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

print('RG2a: %d evaluated, %d passed, %d still excluded with reason, %d failures' %
      (len(programs) - len(excluded), passed, len(excluded), len(failures)))
for name, reason in excluded:
    print('  [excluded after calibration] %s: %s' % (name, reason))
for name, reason in failures:
    print('  FAILED: %s -> %s' % (name, reason), file=sys.stderr)
if failures:
    sys.exit(1)
print('RG2a PASSED: programs given one empty-directory argument match no-argument runs outside calibrated mask')
" "$REPO" "$IYI" "$WORK"
}


run_rg5() {
  echo "== Running RG5 (trace half): each observer call is load-bearing =="
  "$PY" -c "
import json, os, sys, shutil, subprocess

repo = sys.argv[1]
iyi = sys.argv[2]
work = sys.argv[3]

NOT_REUSABLE_CODES = {
    'clock': 32, 'entropy': 33, 'timer': 34, 'network': 35, 'process': 36,
    'signal': 37, 'runtime_timing': 38, 'code_location': 39,
    'dir_stream': 40, 'host_state': 41,
}

def taint_kinds(data):
    # Records are u32le length then payload: u8 type, u64le task, fields.
    # A TAINT (0x08) carries its kind as the first field byte.
    found, at = set(), 0
    while at + 4 <= len(data):
        size = int.from_bytes(data[at:at + 4], 'little')
        payload = data[at + 4:at + 4 + size]
        if len(payload) >= 10 and payload[0] == 0x08:
            found.add(payload[9])
        at += 4 + size
    return found

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
    'host_state',
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
    elif kind == 'host_state':
        with open(fixture_src, 'w') as f:
            f.write('''module test/fixture
import std/system_roots::{SystemRoots}
SystemRoots.load
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

    # Stub this kind's own observer: the body of its one
    # 'pub def __iyi_observe_<kind>' becomes a bare return. A patch that finds
    # no such def, or leaves the file as it was, would prove nothing, so it
    # fails the kind instead.
    observe_lines = orig_observe.split('\n')
    head = f'pub def __iyi_observe_{kind}'
    heads = [i for i, line in enumerate(observe_lines)
             if line.startswith(head + '(') or line.startswith(head + ' ')]
    if len(heads) != 1:
        failed_kinds.append((kind, f'expected one {head} in observe.iyi, found {len(heads)}'))
        continue
    tail = next((j for j in range(heads[0] + 1, len(observe_lines)) if observe_lines[j] == 'end'), None)
    if tail is None:
        failed_kinds.append((kind, f'{head} has no closing end'))
        continue
    patched_observe = '\n'.join(observe_lines[:heads[0] + 1] + ['  return'] + observe_lines[tail:])
    if patched_observe == orig_observe:
        failed_kinds.append((kind, f'stubbing {head} left observe.iyi unchanged'))
        continue
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
        code = NOT_REUSABLE_CODES.get(kind)
        if code is not None:
            # A not-reusable kind is load-bearing when its taint is in the
            # observed trace and gone from the patched one. Lengths prove
            # nothing: a run stops recording after its first taint, so a
            # different taint can take the dropped one's place.
            if code in taint_kinds(data_a) and code not in taint_kinds(data_pa):
                passed_kinds.append(kind)
                print(f'  [load-bearing] {kind}: observer is load-bearing')
            else:
                failed_kinds.append((kind, 'taint of this kind still recorded after dropping observer'))
            continue
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
method = 'pub def __iyi_observe_file_read'
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

run_rg2r() {
  echo "== Running RG2r: observed artifact round-trip probe equivalence =="
  "$PY" -c "
import concurrent.futures, json, os, subprocess, sys

repo, iyi, work = sys.argv[1:]
sys.path.insert(0, os.path.join(repo, 'bench'))
from frames_equivalent import compare_same_opt

probes = {
    'dir_probe': '''import std/dir::{Dir}

def attempt(label : String, &work : -> Int32) : Nil
  group do |g|
    task = g.spawn { work.call }
    outcome = task.value
    if outcome.is_a?(Panicked)
      puts label + \": refused: \" + outcome.message.to_s
    else
      puts label + \": answered\"
    end
    0
  end
end

attempt(\"dir\") { Dir.children(\"\").size }
''',
    'env_probe': '''import std/env::{ENV}

def attempt(label : String, &work : -> Int32) : Nil
  group do |g|
    task = g.spawn { work.call }
    outcome = task.value
    if outcome.is_a?(Panicked)
      puts label + \": refused: \" + outcome.message.to_s
    else
      puts label + \": answered\"
    end
    0
  end
end

attempt(\"env\") { ENV[\"A=B\"] = \"x\"; 0 }
''',
    'recursion_probe': '''def attempt(label : String, &work : -> Int32) : Nil
  group do |g|
    task = g.spawn { work.call }
    outcome = task.value
    if outcome.is_a?(Panicked)
      puts label + \": refused: \" + outcome.message.to_s
    else
      puts label + \": answered\"
    end
    0
  end
end

def down(n : Int32) : Int32
  raise \"bottom of #{n}\" if n == 0
  down(n - 1) + 1
end

attempt(\"recursion\") { down(3) }
attempt(\"capped\") { down(80) }
''',
}

rg2r_root = os.path.join(work, 'rg2r')
os.makedirs(rg2r_root, exist_ok=True)
timeout = 120

def check_probe(item):
    name, code = item
    directory = os.path.join(rg2r_root, name)
    os.makedirs(directory, exist_ok=True)
    src = os.path.join(directory, name + '.iyi')
    with open(src, 'w') as f:
        f.write(code)

    normal_dir = os.path.join(directory, 'normal')
    observed_dir = os.path.join(directory, 'observed')
    producer_dir = os.path.join(directory, 'producer')
    artifact_dir = os.path.join(directory, 'artifact')
    mods_dir = os.path.join(directory, 'mods')
    for d in [normal_dir, observed_dir, producer_dir, artifact_dir, mods_dir]:
        os.makedirs(d, exist_ok=True)

    normal_bin = os.path.join(normal_dir, name)
    observed_bin = os.path.join(observed_dir, name)
    producer_bin = os.path.join(producer_dir, name)
    artifact_bin = os.path.join(artifact_dir, name)

    # 1. normal build
    cache_n = os.path.join(directory, 'cache_n')
    os.makedirs(cache_n, exist_ok=True)
    res = subprocess.run([iyi, 'build', '-o', normal_bin, src],
                         env=dict(os.environ, IYI_CACHE_DIR=cache_n),
                         capture_output=True, timeout=timeout)
    if res.returncode != 0:
        return name, 'normal build failed: ' + res.stderr.decode()[:200]

    # 2. observed build (-Diyi_observe)
    cache_o = os.path.join(directory, 'cache_o')
    os.makedirs(cache_o, exist_ok=True)
    res = subprocess.run([iyi, 'build', '-Diyi_observe', '-o', observed_bin, src],
                         env=dict(os.environ, IYI_CACHE_DIR=cache_o),
                         capture_output=True, timeout=timeout)
    if res.returncode != 0:
        return name, 'observed build failed: ' + res.stderr.decode()[:200]

    # 3. producer build (-Diyi_observe --emit-iyimod mods)
    cache_p = os.path.join(directory, 'cache_p')
    os.makedirs(cache_p, exist_ok=True)
    res = subprocess.run([iyi, 'build', '-Diyi_observe', '--emit-iyimod', mods_dir, '-o', producer_bin, src],
                         env=dict(os.environ, IYI_CACHE_DIR=cache_p),
                         capture_output=True, timeout=timeout)
    if res.returncode != 0:
        return name, 'producer build failed: ' + res.stderr.decode()[:200]

    # 4. artifact build with --stale-key (cold 1)
    k1 = os.path.join(directory, 'k1.json')
    k2 = os.path.join(directory, 'k2.json')
    k3 = os.path.join(directory, 'k3.json')
    b2 = os.path.join(directory, 'rg9_2')
    b3 = os.path.join(directory, 'rg9_3')

    cache_a = os.path.join(directory, 'cache_a')
    os.makedirs(cache_a, exist_ok=True)

    res = subprocess.run([iyi, 'build', '-Diyi_observe', '--use-iyimod', mods_dir,
                         '--stale-key', k1, '-o', artifact_bin, src],
                         env=dict(os.environ, IYI_CACHE_DIR=cache_a),
                         capture_output=True, timeout=timeout)
    if res.returncode != 0:
        return name, 'artifact build failed: ' + res.stderr.decode()[:200]

    # Run all three from the probe directory
    trace_o = os.path.join(directory, 'trace_o.bin')
    trace_a = os.path.join(directory, 'trace_a.bin')

    run_n = subprocess.run([normal_bin], cwd=directory, capture_output=True, timeout=timeout)
    run_o = subprocess.run([observed_bin], cwd=directory, env=dict(os.environ, IYI_OBSERVE=trace_o),
                           capture_output=True, timeout=timeout)
    run_a = subprocess.run([artifact_bin], cwd=directory, env=dict(os.environ, IYI_OBSERVE=trace_a),
                           capture_output=True, timeout=timeout)

    if not (run_n.returncode == run_o.returncode == run_a.returncode):
        return name, f'exit status mismatch: n={run_n.returncode}, o={run_o.returncode}, a={run_a.returncode}'

    if not (run_n.stdout == run_o.stdout == run_a.stdout):
        return name, 'stdout not byte-equal across normal, observed, and artifact'

    lines_n = run_n.stderr.splitlines(keepends=True)
    lines_o = run_o.stderr.splitlines(keepends=True)
    lines_a = run_a.stderr.splitlines(keepends=True)

    oa_err = compare_same_opt(lines_o, lines_a)
    if oa_err != 0:
        return name, 'observed vs artifact stderr frames not equivalent'

    na_err = compare_same_opt(lines_n, lines_a)
    if na_err != 0:
        return name, 'normal vs artifact stderr frames not equivalent'

    if any(b'__iyi_effect_' in line for line in lines_o):
        return name, 'found __iyi_effect_ in observed stderr'
    if any(b'__iyi_effect_' in line for line in lines_a):
        return name, 'found __iyi_effect_ in artifact stderr'

    trace_o_size = os.path.getsize(trace_o) if os.path.exists(trace_o) else 0
    trace_a_size = os.path.getsize(trace_a) if os.path.exists(trace_a) else 0
    if trace_o_size == 0 or trace_a_size == 0:
        return name, f'empty trace: trace_o={trace_o_size}, trace_a={trace_a_size}'

    # RG9 on the artifact build:
    # Build a second time cold with --stale-key in separate process, and once more with IYI_WARM=1
    r2 = subprocess.run([iyi, 'build', '-Diyi_observe', '--use-iyimod', mods_dir,
                         '--stale-key', k2, '-o', b2, src],
                        env=dict(os.environ, IYI_CACHE_DIR=cache_a),
                        capture_output=True, timeout=timeout)
    if r2.returncode != 0:
        return name, 'RG9 cold 2 artifact build failed: ' + r2.stderr.decode()[:200]

    r3 = subprocess.run([iyi, 'build', '-Diyi_observe', '--use-iyimod', mods_dir,
                         '--stale-key', k3, '-o', b3, src],
                        env=dict(os.environ, IYI_CACHE_DIR=cache_a, IYI_WARM='1'),
                        capture_output=True, timeout=timeout)
    if r3.returncode != 0:
        return name, 'RG9 warm artifact build failed: ' + r3.stderr.decode()[:200]

    with open(k1) as f: jk1 = json.load(f)
    with open(k2) as f: jk2 = json.load(f)
    with open(k3) as f: jk3 = json.load(f)

    cp1 = jk1.get('portable', {}).get('callpath')
    cp2 = jk2.get('portable', {}).get('callpath')
    cp3 = jk3.get('portable', {}).get('callpath')

    if not (cp1 and cp1 == cp2 == cp3):
        return name, f'RG9 callpath mismatch: cp1={cp1}, cp2={cp2}, cp3={cp3}'

    m1 = jk1.get('reach', {}).get('mismatch', [])
    m2 = jk2.get('reach', {}).get('mismatch', [])
    m3 = jk3.get('reach', {}).get('mismatch', [])

    if m1 or m2 or m3:
        return name, f'RG9 reach.mismatch non-empty: m1={m1}, m2={m2}, m3={m3}'

    return name, None

with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
    results = list(executor.map(check_probe, probes.items()))

failures = []
for name, err in results:
    if err:
        failures.append((name, err))
    else:
        print(f'  [rg2r] {name}: frames equivalent, exit/stdout equal, RG9 3-way callpath match with 0 mismatch')

if failures:
    for name, reason in failures:
        print(f'  FAILED: {name} -> {reason}', file=sys.stderr)
    sys.exit(1)
print(f'RG2r PASSED: all {len(probes)} probes pass strict frame equivalence between normal, observed and artifact, plus RG9 artifact determinism')
" "$REPO" "$IYI" "$WORK"
}

case "$MODE" in
  rg2)
    run_rg2
    ;;
  rg2a)
    run_rg2a
    ;;
  rg5)
    run_rg5
    ;;
  rg2r)
    run_rg2r
    ;;
  rg5)
    run_rg5
    ;;
  all)
    run_rg2
    run_rg2a
    run_rg2r
    run_rg5
    ;;
  *)
    echo "Unknown mode: $MODE (expected: all, rg2, rg2a, rg2r, rg5)" >&2
    exit 1
    ;;
esac
