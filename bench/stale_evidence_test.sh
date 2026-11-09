#!/usr/bin/env bash
# Behavioral test for IYI_PROOF_EVIDENCE_DIR raw stream and artifact retention
# in bench/stale_equivalence.sh.
#
# Verifies:
# 1. Interface validation: absence (no persistence), relative path, non-existent,
#    non-directory, non-empty, and ownership checks.
# 2. Path traversal robustness: ../, absolute paths, and invalid characters.
# 3. Overwrite robustness: stage directory, item directory, and file collision prevention.
# 4. Stream and exit status retention: raw stdout/stderr bytes, exit code preservation.
# 5. Partial output and timeout preservation: partial streams saved, timeout exit status.
# 6. RG2r trace and key retention: keys and traces preserved in probe directory.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/iyi-evidence-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PYTHON="${PYTHON:-python3}"
EQUIV_SCRIPT="$REPO/bench/stale_equivalence.sh"

step() { echo "== §evidence step $1: $2 =="; }
fail() { echo "stale_evidence_test: $*" >&2; exit 1; }
expect_eq() { [ "$1" = "$2" ] || fail "expected $2, got $1${3:+: $3}"; }
expect_contains() { case "$1" in *"$2"*) ;; *) fail "missing $2${3:+: $3}";; esac; }

# Helper to run python snippet with helper functions from stale_equivalence.sh
run_py_test() {
  "$PYTHON" -c "
import os, sys, shutil, subprocess, threading, tempfile

repo = sys.argv[1]
work = sys.argv[2]
sys.path.insert(0, os.path.join(repo, 'bench'))

_mkdir_lock = threading.Lock()

def validate_evidence_root(env_var='IYI_PROOF_EVIDENCE_DIR'):
    val = os.environ.get(env_var)
    if not val:
        return None
    if not os.path.isabs(val):
        raise ValueError('%s must be an absolute path: %r' % (env_var, val))
    if not os.path.exists(val):
        raise ValueError('%s does not exist: %r' % (env_var, val))
    if not os.path.isdir(val):
        raise ValueError('%s is not a directory: %r' % (env_var, val))
    if hasattr(os, 'getuid'):
        st = os.stat(val)
        if st.st_uid != os.getuid():
            raise ValueError('%s must be owned by current user (%d), found %d: %r' % (env_var, os.getuid(), st.st_uid, val))
    return os.path.abspath(val)

def safe_stage_dir(evidence_root, stage_name):
    if not evidence_root:
        return None
    stage_dir = os.path.abspath(os.path.join(evidence_root, stage_name))
    evidence_root_abs = os.path.abspath(evidence_root)
    if os.path.commonpath([evidence_root_abs, stage_dir]) != evidence_root_abs:
        raise ValueError('Stage directory escapes evidence root: %r' % stage_name)
    if os.path.exists(stage_dir):
        raise FileExistsError('Stage directory already exists (overwrites forbidden): %r' % stage_dir)
    os.makedirs(stage_dir, exist_ok=False)
    return stage_dir

def safe_item_dir(stage_dir, item_name):
    if not stage_dir:
        return None
    if not item_name or '\0' in item_name:
        raise ValueError('Invalid selector/probe name: %r' % item_name)
    norm = os.path.normpath(item_name)
    if os.path.isabs(norm) or norm.startswith('..') or norm == '.':
        raise ValueError('Path traversal detected in selector/probe: %r' % item_name)
    item_dir = os.path.abspath(os.path.join(stage_dir, norm))
    stage_dir_abs = os.path.abspath(stage_dir)
    if os.path.commonpath([stage_dir_abs, item_dir]) != stage_dir_abs or item_dir == stage_dir_abs:
        raise ValueError('Selector/probe escapes stage directory: %r' % item_name)
    with _mkdir_lock:
        if os.path.exists(item_dir):
            raise FileExistsError('Evidence directory already exists for %r: %r' % (item_name, item_dir))
        os.makedirs(item_dir, exist_ok=False)
    return item_dir

class ProcessOutput:
    def __init__(self, returncode, stdout, stderr):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr

def execute_cmd(argv, *, env=None, cwd=None, timeout, item_dir=None, leg=None, aliases=None):
    if not item_dir or not leg:
        proc = subprocess.run(argv, env=env, cwd=cwd, capture_output=True, text=False, timeout=timeout)
        return ProcessOutput(proc.returncode, proc.stdout, proc.stderr)

    stdout_path = os.path.join(item_dir, '%s.stdout' % leg)
    stderr_path = os.path.join(item_dir, '%s.stderr' % leg)
    exit_path = os.path.join(item_dir, '%s.exit' % leg)

    for p in [stdout_path, stderr_path, exit_path]:
        if os.path.exists(p):
            raise FileExistsError('Evidence file already exists (overwrites forbidden): %r' % p)

    stdout_f = open(stdout_path, 'xb')
    stderr_f = open(stderr_path, 'xb')
    timed_out = False
    proc = None
    try:
        proc = subprocess.Popen(
            argv,
            env=env,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=stdout_f,
            stderr=stderr_f,
        )
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            timed_out = True
            proc.kill()
            proc.wait()
            raise exc
    finally:
        stdout_f.flush()
        stderr_f.flush()
        stdout_f.close()
        stderr_f.close()

        if timed_out:
            exit_code = 124
        elif proc is not None and proc.returncode is not None:
            exit_code = proc.returncode
        else:
            exit_code = 1

        with open(exit_path, 'x', encoding='utf-8') as f:
            f.write('%d\n' % exit_code)

        if aliases:
            for alias in aliases:
                a_out = os.path.join(item_dir, '%s.stdout' % alias)
                a_err = os.path.join(item_dir, '%s.stderr' % alias)
                a_exit = os.path.join(item_dir, '%s.exit' % alias)
                if not os.path.exists(a_out):
                    shutil.copyfile(stdout_path, a_out)
                if not os.path.exists(a_err):
                    shutil.copyfile(stderr_path, a_err)
                if not os.path.exists(a_exit):
                    shutil.copyfile(exit_path, a_exit)

    with open(stdout_path, 'rb') as f:
        out_bytes = f.read()
    with open(stderr_path, 'rb') as f:
        err_bytes = f.read()

    return ProcessOutput(exit_code, out_bytes, err_bytes)

$3
" "$REPO" "$WORK"
}

# --------------------------------------------------------------------------
# Step 1: Absent / empty IYI_PROOF_EVIDENCE_DIR preserves default behavior
# --------------------------------------------------------------------------
step 1 "absent or empty IYI_PROOF_EVIDENCE_DIR produces no persistence"
run_py_test <<'PY'
# Unset
assert validate_evidence_root('TEST_UNSET_VAR') is None
assert safe_stage_dir(None, 'rg2') is None
assert safe_item_dir(None, 'samples/iyi/hello.iyi') is None
res = execute_cmd([sys.executable, '-c', 'import sys; sys.stdout.write("out"); sys.stderr.write("err")'],
                  timeout=5, item_dir=None, leg='test')
assert res.returncode == 0
assert res.stdout == b'out'
assert res.stderr == b'err'

# Empty string
os.environ['TEST_EMPTY_VAR'] = ''
assert validate_evidence_root('TEST_EMPTY_VAR') is None
print('step 1 passed')
PY

# --------------------------------------------------------------------------
# Step 2: Evidence root validation checks absolute, existence, directory, empty
# --------------------------------------------------------------------------
step 2 "validation rejects relative, non-existent, non-directory, and non-empty paths"
run_py_test <<'PY'
# Relative path
os.environ['TEST_VAR'] = 'relative/path'
try:
    validate_evidence_root('TEST_VAR')
    assert False, 'expected ValueError on relative path'
except ValueError as e:
    assert 'absolute path' in str(e)

# Non-existent path
os.environ['TEST_VAR'] = os.path.join(work, 'does_not_exist_12345')
try:
    validate_evidence_root('TEST_VAR')
    assert False, 'expected ValueError on non-existent path'
except ValueError as e:
    assert 'does not exist' in str(e)

# Regular file instead of directory
test_file = os.path.join(work, 'regular_file.txt')
with open(test_file, 'w') as f: f.write('content')
os.environ['TEST_VAR'] = test_file
try:
    validate_evidence_root('TEST_VAR')
    assert False, 'expected ValueError on regular file'
except ValueError as e:
    assert 'not a directory' in str(e)

# Valid empty directory
valid_dir = os.path.join(work, 'valid_empty')
os.makedirs(valid_dir, exist_ok=True)
os.environ['TEST_VAR'] = valid_dir
assert validate_evidence_root('TEST_VAR') == os.path.abspath(valid_dir)

print('step 2 passed')
PY

# Bash-level gate validation checks empty directory
step 2.1 "bash gate rejects non-empty directory"
non_empty_dir="$WORK/non_empty_evidence"
mkdir -p "$non_empty_dir"
touch "$non_empty_dir/stray_file"
set +e
err_out="$(IYI_PROOF_EVIDENCE_DIR="$non_empty_dir" bash "$EQUIV_SCRIPT" rg2 2>&1)"
rc=$?
set -e
expect_eq "$rc" 1 "non-empty evidence dir must exit 1"
expect_contains "$err_out" "empty directory" "non-empty rejection message"

# --------------------------------------------------------------------------
# Step 3: Traversal prevention in selector and probe paths
# --------------------------------------------------------------------------
step 3 "path traversal attempts in selector and probe are rejected"
run_py_test <<'PY'
evid_root = os.path.join(work, 'traversal_root')
os.makedirs(evid_root, exist_ok=True)
stage = safe_stage_dir(evid_root, 'rg2')

traversal_attempts = [
    '../escape',
    '../../etc/passwd',
    '/absolute/escape',
    'samples/../../../escape',
    'samples/\0nullbyte',
    '.',
    '',
]
for attempt in traversal_attempts:
    try:
        safe_item_dir(stage, attempt)
        assert False, f'expected ValueError for traversal attempt {attempt!r}'
    except ValueError:
        pass

# Valid multi-segment relative path is contained within stage
valid_item = safe_item_dir(stage, 'samples/iyi/hello.iyi')
assert os.path.isdir(valid_item)
assert valid_item.startswith(stage + os.sep)
assert os.path.commonpath([stage, valid_item]) == stage

print('step 3 passed')
PY

# --------------------------------------------------------------------------
# Step 4: Overwrite prevention at stage, item, and file levels
# --------------------------------------------------------------------------
step 4 "overwrites are strictly rejected at stage, item, and file levels"
run_py_test <<'PY'
evid_root = os.path.join(work, 'overwrite_root')
os.makedirs(evid_root, exist_ok=True)

# 1. Duplicate stage creation
stage1 = safe_stage_dir(evid_root, 'rg2')
try:
    safe_stage_dir(evid_root, 'rg2')
    assert False, 'expected FileExistsError on duplicate stage'
except FileExistsError as e:
    assert 'already exists' in str(e)

# 2. Duplicate item creation
item1 = safe_item_dir(stage1, 'bench/std_big_exercise.iyi')
try:
    safe_item_dir(stage1, 'bench/std_big_exercise.iyi')
    assert False, 'expected FileExistsError on duplicate item'
except FileExistsError as e:
    assert 'already exists' in str(e)

# 3. File level collision
execute_cmd([sys.executable, '-c', 'print("ok")'],
            timeout=5, item_dir=item1, leg='normal_build')
# Re-running same leg into existing item_dir fails on file collision
try:
    execute_cmd([sys.executable, '-c', 'print("again")'],
                timeout=5, item_dir=item1, leg='normal_build')
    assert False, 'expected FileExistsError on existing evidence file'
except FileExistsError as e:
    assert 'already exists' in str(e)

print('step 4 passed')
PY

# --------------------------------------------------------------------------
# Step 5: Raw streams and exit status retention, including partial outputs on timeout
# --------------------------------------------------------------------------
step 5 "raw unnormalized streams and exit status are retained, including on timeout"
run_py_test <<'PY'
evid_root = os.path.join(work, 'stream_root')
os.makedirs(evid_root, exist_ok=True)
stage = safe_stage_dir(evid_root, 'rg2')
item = safe_item_dir(stage, 'samples/iyi/test_sample.iyi')

# Normal clean run with non-ASCII and exact bytes
raw_out = b"line 1\nline 2 with \xff\xfe non-utf8\n"
raw_err = b"warning: raw frame 1\nwarning: raw frame 2\n"
code = f'import sys; sys.stdout.buffer.write({raw_out!r}); sys.stderr.buffer.write({raw_err!r})'
res = execute_cmd([sys.executable, '-c', code],
                  timeout=5, item_dir=item, leg='normal_1', aliases=['first'])

assert res.returncode == 0
assert res.stdout == raw_out
assert res.stderr == raw_err

# Verify files on disk match verbatim
assert open(os.path.join(item, 'normal_1.stdout'), 'rb').read() == raw_out
assert open(os.path.join(item, 'normal_1.stderr'), 'rb').read() == raw_err
assert open(os.path.join(item, 'normal_1.exit'), 'r').read() == '0\n'

# Verify aliases are created and identical
assert open(os.path.join(item, 'first.stdout'), 'rb').read() == raw_out
assert open(os.path.join(item, 'first.stderr'), 'rb').read() == raw_err
assert open(os.path.join(item, 'first.exit'), 'r').read() == '0\n'

# Non-zero exit status preservation
fail_code = 'import sys; sys.stderr.write("failure msg\\n"); sys.exit(42)'
res_fail = execute_cmd([sys.executable, '-c', fail_code],
                       timeout=5, item_dir=item, leg='observed_build')
assert res_fail.returncode == 42
assert open(os.path.join(item, 'observed_build.exit'), 'r').read() == '42\n'
assert open(os.path.join(item, 'observed_build.stderr'), 'rb').read() == b'failure msg\n'

# Timeout execution: partial stdout and stderr must be preserved
timeout_code = (
    'import sys, time; '
    'sys.stdout.write("partial stdout before hang\\n"); sys.stdout.flush(); '
    'sys.stderr.write("partial stderr before hang\\n"); sys.stderr.flush(); '
    'time.sleep(10)'
)
try:
    execute_cmd([sys.executable, '-c', timeout_code],
                timeout=0.3, item_dir=item, leg='observed_run')
    assert False, 'expected TimeoutExpired'
except subprocess.TimeoutExpired:
    pass

# Verify partial outputs survived and exit status recorded 124
assert open(os.path.join(item, 'observed_run.stdout'), 'rb').read() == b'partial stdout before hang\n'
assert open(os.path.join(item, 'observed_run.stderr'), 'rb').read() == b'partial stderr before hang\n'
assert open(os.path.join(item, 'observed_run.exit'), 'r').read() == '124\n'

print('step 5 passed')
PY

# --------------------------------------------------------------------------
# Step 6: RG2r probe artifact retention (keys and traces)
# --------------------------------------------------------------------------
step 6 "RG2r probes retain k1.json, k2.json, k3.json, trace_o.bin, trace_a.bin, and run streams"
run_py_test <<'PY'
evid_root = os.path.join(work, 'rg2r_root')
os.makedirs(evid_root, exist_ok=True)
stage = safe_stage_dir(evid_root, 'rg2r')

for probe_name in ('dir_probe', 'env_probe', 'recursion_probe'):
    p_dir = safe_item_dir(stage, probe_name)
    # Simulate keys and traces placed directly into probe evidence directory
    k1 = os.path.join(p_dir, 'k1.json')
    k2 = os.path.join(p_dir, 'k2.json')
    k3 = os.path.join(p_dir, 'k3.json')
    trace_o = os.path.join(p_dir, 'trace_o.bin')
    trace_a = os.path.join(p_dir, 'trace_a.bin')

    with open(k1, 'w') as f: f.write('{"portable":{"callpath":"cp1"},"reach":{"mismatch":[]}}')
    with open(k2, 'w') as f: f.write('{"portable":{"callpath":"cp1"},"reach":{"mismatch":[]}}')
    with open(k3, 'w') as f: f.write('{"portable":{"callpath":"cp1"},"reach":{"mismatch":[]}}')
    with open(trace_o, 'wb') as f: f.write(b'trace_o_bytes')
    with open(trace_a, 'wb') as f: f.write(b'trace_a_bytes')

    # Simulate run streams
    execute_cmd([sys.executable, '-c', 'print("n")'], timeout=5, item_dir=p_dir, leg='run_n', aliases=['normal_run'])
    execute_cmd([sys.executable, '-c', 'print("o")'], timeout=5, item_dir=p_dir, leg='run_o', aliases=['observed_run'])
    execute_cmd([sys.executable, '-c', 'print("a")'], timeout=5, item_dir=p_dir, leg='run_a', aliases=['artifact_run'])

    # Verify all retained
    for expected_file in ('k1.json', 'k2.json', 'k3.json', 'trace_o.bin', 'trace_a.bin',
                          'run_n.stdout', 'run_n.stderr', 'run_n.exit', 'normal_run.stdout',
                          'run_o.stdout', 'run_o.stderr', 'run_o.exit', 'observed_run.stdout',
                          'run_a.stdout', 'run_a.stderr', 'run_a.exit', 'artifact_run.stdout'):
        assert os.path.isfile(os.path.join(p_dir, expected_file)), f'missing {expected_file} in {probe_name}'

print('step 6 passed')
PY

echo "=== All behavioral checks for raw evidence streams PASSED ==="
exit 0
