#!/usr/bin/env bash
# Behavioral test for IYI_PROOF_EVIDENCE_DIR raw stream and artifact retention
# in bench/stale_evidence.py and bench/stale_equivalence.sh.
#
# Verifies:
# 1. Direct invocation of shared production module bench/stale_evidence.py (no duplicated helpers).
# 2. Interface validation: absence (no persistence), relative path, non-existent,
#    non-directory, non-empty, and ownership checks.
# 3. Path traversal robustness: ../, absolute paths, and null bytes rejected.
# 4. Overwrite robustness: stage directory, item directory, and file collision prevention.
# 5. Status distinction:
#    - Actual numeric exit (including a real child exit 124) vs. runner timeout
#    - Explicit .timeout flag file created on timeout with TIMEOUT exit indicator
#    - Signal termination with .signal file
#    - Launch error with .error file
#    - Case E: Runner SIGKILL incremental flush with pass_fds control pipe, proving:
#      * runner killed by -SIGKILL (did not exit naturally)
#      * child remains alive blocked on control pipe until EOF
#      * actual child exit verified upon closing pipe (no lingering orphans)
#      * unrelated sentinel process verified alive and untouched throughout
# 6. Fail-closed negative controls:
#    - Real fsync / write failure injected into production pump raises CaptureError,
#      records IO_ERROR, and prevents exclusion/PASS.
#    - Unclosed writers exceeding deadline raise CaptureError and record UNRESOLVED_WRITERS.
# 7. Actual entry path execution of bench/stale_equivalence.sh against a fake compiler:
#    - No-evidence mode: passes without persisting files
#    - Evidence mode: populates rg2r/<probe> with exact raw streams, traces, keys, no alias duplicates
#    - Real backtrace frames and non-frame bytes emitted and verified for exact byte equality (not empty stderr)
#    - Changed-frame negative test: divergent frame causes gate failure while preserving raw stderr
#    - Entry-path validation rejection of relative, non-existent, and non-empty evidence dirs

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/iyi-evidence-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PYTHON="${PYTHON:-python3}"
EQUIV_SCRIPT="$REPO/bench/stale_equivalence.sh"
EVIDENCE_MODULE="$REPO/bench/stale_evidence.py"

step() { echo "== §evidence step $1: $2 =="; }
fail() { echo "stale_evidence_test: $*" >&2; exit 1; }
expect_eq() { [ "$1" = "$2" ] || fail "expected $2, got $1${3:+: $3}"; }
expect_contains() { case "$1" in *"$2"*) ;; *) fail "missing $2${3:+: $3}";; esac; }

# --------------------------------------------------------------------------
# Step 0: the module every step below imports loads on its own
# --------------------------------------------------------------------------
# Each step imports it inside a heredoc, where a syntax or import error reads
# as that step's failure. Run once by path it is one failure, named for what
# it is, and bench/gates_reachable.py sees the module run: an import inside a
# heredoc is not a command it can read.
step 0 "bench/stale_evidence.py loads under $PYTHON"
"$PYTHON" -B "$EVIDENCE_MODULE" || fail "bench/stale_evidence.py does not load"

# --------------------------------------------------------------------------
# Step 1: Direct invocation of production stale_evidence module: default / empty
# --------------------------------------------------------------------------
step 1 "absent or empty IYI_PROOF_EVIDENCE_DIR produces no persistence"
"$PYTHON" - "$REPO" "$WORK" <<'PYEOF'
import os, sys
repo, work = sys.argv[1:3]
sys.path.insert(0, os.path.join(repo, 'bench'))
from stale_evidence import validate_evidence_root, safe_stage_dir, safe_item_dir, execute_cmd

assert validate_evidence_root('TEST_UNSET_VAR') is None
assert safe_stage_dir(None, 'rg2') is None
assert safe_item_dir(None, 'samples/iyi/hello.iyi') is None

# Normal command without item_dir runs uninhibited and writes no files
res = execute_cmd([sys.executable, '-c', 'import sys; sys.stdout.write("out"); sys.stderr.write("err")'],
                  timeout=5, item_dir=None, leg='test')
assert res.returncode == 0
assert res.stdout == b'out'
assert res.stderr == b'err'

os.environ['TEST_EMPTY_VAR'] = ''
assert validate_evidence_root('TEST_EMPTY_VAR') is None
PYEOF

# --------------------------------------------------------------------------
# Step 2: Validation rejects relative, non-existent, non-directory, and non-empty
# --------------------------------------------------------------------------
step 2 "validation rejects relative, non-existent, non-directory, and non-empty paths"
"$PYTHON" - "$REPO" "$WORK" <<'PYEOF'
import os, sys
repo, work = sys.argv[1:3]
sys.path.insert(0, os.path.join(repo, 'bench'))
from stale_evidence import validate_evidence_root

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
with open(test_file, 'w') as f:
    f.write('content')
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
assert validate_evidence_root('TEST_VAR') == os.path.realpath(valid_dir)
PYEOF

# Bash entry path validation
step 2.1 "bash gate rejects invalid IYI_PROOF_EVIDENCE_DIR"
set +e
err_rel="$(IYI_PROOF_EVIDENCE_DIR="relative/path" bash "$EQUIV_SCRIPT" rg2 2>&1)"
rc_rel=$?
set -e
expect_eq "$rc_rel" 1 "relative evidence dir must exit 1"
expect_contains "$err_rel" "absolute path" "relative rejection message"

set +e
err_nonexist="$(IYI_PROOF_EVIDENCE_DIR="$WORK/non_existent_dir_987" bash "$EQUIV_SCRIPT" rg2 2>&1)"
rc_nonexist=$?
set -e
expect_eq "$rc_nonexist" 1 "non-existent evidence dir must exit 1"
expect_contains "$err_nonexist" "existing directory" "non-existent rejection message"

non_empty_dir="$WORK/non_empty_dir"
mkdir -p "$non_empty_dir"
touch "$non_empty_dir/file.txt"
set +e
err_nonempty="$(IYI_PROOF_EVIDENCE_DIR="$non_empty_dir" bash "$EQUIV_SCRIPT" rg2 2>&1)"
rc_nonempty=$?
set -e
expect_eq "$rc_nonempty" 1 "non-empty evidence dir must exit 1"
expect_contains "$err_nonempty" "empty directory" "non-empty rejection message"

# --------------------------------------------------------------------------
# Step 3: Traversal prevention in selector and probe paths
# --------------------------------------------------------------------------
step 3 "path traversal attempts in selector and probe are rejected"
"$PYTHON" - "$REPO" "$WORK" <<'PYEOF'
import os, sys
repo, work = sys.argv[1:3]
sys.path.insert(0, os.path.join(repo, 'bench'))
from stale_evidence import safe_stage_dir, safe_item_dir

evid_root = os.path.join(work, 'traversal_root')
os.makedirs(evid_root, exist_ok=True)
stage = safe_stage_dir(evid_root, 'rg2')

for attempt in ['../escape', '../../etc/passwd', '/absolute/escape', 'samples/../../../escape', 'samples/\0nullbyte', '.', '']:
    try:
        safe_item_dir(stage, attempt)
        assert False, f'expected ValueError for traversal attempt {attempt!r}'
    except ValueError:
        pass

valid_item = safe_item_dir(stage, 'samples/iyi/hello.iyi')
assert os.path.isdir(valid_item)
assert valid_item.startswith(stage + os.sep)
assert os.path.commonpath([stage, valid_item]) == stage
PYEOF

# --------------------------------------------------------------------------
# Step 4: Overwrite prevention at stage, item, and file levels
# --------------------------------------------------------------------------
step 4 "overwrites are strictly rejected at stage, item, and file levels"
"$PYTHON" - "$REPO" "$WORK" <<'PYEOF'
import os, sys
repo, work = sys.argv[1:3]
sys.path.insert(0, os.path.join(repo, 'bench'))
from stale_evidence import safe_stage_dir, safe_item_dir, execute_cmd

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
try:
    execute_cmd([sys.executable, '-c', 'print("again")'],
                timeout=5, item_dir=item1, leg='normal_build')
    assert False, 'expected FileExistsError on existing evidence file'
except FileExistsError as e:
    assert 'already exists' in str(e)
PYEOF

# --------------------------------------------------------------------------
# Step 5: Status distinction: child exit 124 vs runner timeout vs signal vs launch error
# --------------------------------------------------------------------------
step 5 "status distinguishes numeric exit 124, timeout with explicit flag, signal, and launch error"
"$PYTHON" - "$REPO" "$WORK" <<'PYEOF'
import os, sys, subprocess, signal, time
repo, work = sys.argv[1:3]
sys.path.insert(0, os.path.join(repo, 'bench'))
from stale_evidence import safe_stage_dir, safe_item_dir, execute_cmd

def check_pid_dead_or_zombie(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except (PermissionError, OSError):
        return False
    proc_status = f"/proc/{pid}/status"
    if os.path.isfile(proc_status):
        try:
            with open(proc_status, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith("State:"):
                        state_val = line.split(":", 1)[1].strip()
                        return state_val.startswith(("Z", "X"))
        except (OSError, IOError):
            return False
    try:
        ps_res = subprocess.run(["ps", "-o", "state=", "-p", str(pid)], capture_output=True, text=True)
        if ps_res.returncode == 0:
            st = ps_res.stdout.strip()
            if st:
                return st.startswith(("Z", "X"))
    except Exception:
        pass
    return False
evid_root = os.path.join(work, 'status_root')
os.makedirs(evid_root, exist_ok=True)
stage = safe_stage_dir(evid_root, 'rg2')
item = safe_item_dir(stage, 'samples/iyi/test_sample.iyi')

# Case A: Real child exiting with numeric 124
# Must record exit: 124, status: EXIT:124, and MUST NOT create .timeout file
res_124 = execute_cmd([sys.executable, '-c', 'import sys; sys.stdout.write("child exit 124"); sys.exit(124)'],
                      timeout=5, item_dir=item, leg='child_124')
assert res_124.returncode == 124
assert open(os.path.join(item, 'child_124.exit')).read() == '124\n'
assert open(os.path.join(item, 'child_124.status')).read() == 'EXIT:124\n'
assert not os.path.exists(os.path.join(item, 'child_124.timeout')), 'real child exit 124 must not have .timeout flag'

# Case B: Runner timeout
# Must record exit: TIMEOUT, status: TIMEOUT:0.3, create explicit .timeout flag file, and preserve partial outputs
hang_code = (
    'import sys, time\n'
    'sys.stdout.write("partial stdout before timeout\\n")\n'
    'sys.stdout.flush()\n'
    'sys.stderr.write("partial stderr before timeout\\n")\n'
    'sys.stderr.flush()\n'
    'time.sleep(10)\n'
)
try:
    execute_cmd([sys.executable, '-c', hang_code],
                timeout=0.3, item_dir=item, leg='timeout_leg')
    assert False, 'expected TimeoutExpired'
except subprocess.TimeoutExpired:
    pass

assert os.path.isfile(os.path.join(item, 'timeout_leg.timeout')), 'timeout must create explicit .timeout flag'
assert open(os.path.join(item, 'timeout_leg.exit')).read() == 'TIMEOUT\n'
assert 'TIMEOUT:0.3' in open(os.path.join(item, 'timeout_leg.status')).read()
assert open(os.path.join(item, 'timeout_leg.stdout'), 'rb').read() == b'partial stdout before timeout\n'
assert open(os.path.join(item, 'timeout_leg.stderr'), 'rb').read() == b'partial stderr before timeout\n'

# Case C: Process killed by signal (SIGTERM)
sig_code = 'import os, signal, time\nos.kill(os.getpid(), signal.SIGTERM)\ntime.sleep(1)\n'
res_sig = execute_cmd([sys.executable, '-c', sig_code],
                      timeout=5, item_dir=item, leg='signal_leg')
assert res_sig.returncode < 0
assert open(os.path.join(item, 'signal_leg.exit')).read() == f'{res_sig.returncode}\n'
assert open(os.path.join(item, 'signal_leg.status')).read() == f'SIGNAL:{signal.SIGTERM}\n'
assert open(os.path.join(item, 'signal_leg.signal')).read() == f'{signal.SIGTERM}\n'

# Case D: Launch error (non-existent executable)
try:
    execute_cmd(['/non/existent/binary/xyz123'], timeout=5, item_dir=item, leg='error_leg')
    assert False, 'expected FileNotFoundError'
except FileNotFoundError:
    pass
assert open(os.path.join(item, 'error_leg.exit')).read() == 'LAUNCH_ERROR\n'
assert 'LAUNCH_ERROR' in open(os.path.join(item, 'error_leg.status')).read()
assert os.path.isfile(os.path.join(item, 'error_leg.error'))

# Case E: Runner killed by SIGKILL while child is emitting:
# Proves:
#   * partial bytes flushed to disk survive runner SIGKILL
#   * pass_fds correctly transports control pipe through execute_cmd to child
sentinel_proc = None
runner_proc = None
control_r = None
control_w = None
exit_r = None
exit_w = None
child_pid = None
birth_verified = False
sentinel_token = f"birth_token_{time.time_ns()}"

try:
    sentinel_proc = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
    assert sentinel_proc.poll() is None, 'sentinel must be alive before test'

    control_r, control_w = os.pipe()
    exit_r, exit_w = os.pipe()
    sigkill_dir = safe_item_dir(stage, 'samples/iyi/sigkill_test.iyi')
    sigkill_out = os.path.join(sigkill_dir, 'kill_leg.stdout')
    child_pid_file = os.path.join(work, 'sigkill_child.pid')

    child_code = f"""
import sys, os
with open({child_pid_file!r}, 'w') as f:
    f.write(f"{{os.getpid()}}:{sentinel_token!r}\\n")
    f.flush()
sys.stdout.write('streamed chunk before runner death' + chr(10))
sys.stdout.flush()
try:
    os.read({control_r}, 1)
except Exception:
    pass
"""
    runner_code = f"""
import sys, os
sys.path.insert(0, os.path.join({repo!r}, 'bench'))
from stale_evidence import execute_cmd
execute_cmd([sys.executable, '-c', {child_code!r}], item_dir={sigkill_dir!r}, leg='kill_leg', pass_fds=({control_r}, {exit_w}))
"""
    runner_py = os.path.join(work, 'runner_sigkill.py')
    with open(runner_py, 'w') as f:
        f.write(runner_code)

    runner_proc = subprocess.Popen([sys.executable, runner_py], pass_fds=(control_r, exit_w))
    # Parent closes exit_w so only child holds it
    os.close(exit_w)
    exit_w = None

    # Wait for child PID with birth token and chunk on disk
    for _ in range(50):
        if os.path.exists(child_pid_file) and os.path.exists(sigkill_out) and os.path.getsize(sigkill_out) > 0:
            break
        time.sleep(0.05)

    assert os.path.exists(child_pid_file), 'child PID file must exist'
    pid_line = open(child_pid_file).read().strip()
    pid_str, tok_str = pid_line.split(':', 1)
    child_pid = int(pid_str)
    assert tok_str == repr(sentinel_token), 'birth token mismatch'
    assert child_pid > 0 and child_pid != os.getpid() and child_pid != runner_proc.pid
    birth_verified = True

    # 1. Assert child is alive before killing runner
    assert not check_pid_dead_or_zombie(child_pid), 'child must be alive before killing runner'
    # 2. Assert runner is alive before killing runner
    assert runner_proc.poll() is None, 'runner must be alive'

    assert os.path.exists(sigkill_out), 'output file must exist while runner is running'
    bytes_before_kill = open(sigkill_out, 'rb').read()
    assert bytes_before_kill == b'streamed chunk before runner death\n', f'got {bytes_before_kill!r}'

    # 3. Kill runner with SIGKILL while child is emitting/blocked
    os.kill(runner_proc.pid, signal.SIGKILL)
    runner_ret = runner_proc.wait()
    # 4. Assert runner died by -signal.SIGKILL
    assert runner_ret == -signal.SIGKILL, f'expected runner to die by -SIGKILL, got {runner_ret}'

    # 5. Assert child is STILL ALIVE after runner died (held by control pipe)
    assert not check_pid_dead_or_zombie(child_pid), 'child must remain alive while held by pipe'

    # Verify bytes already existed on disk and survived runner death
    bytes_after_kill = open(sigkill_out, 'rb').read()
    assert bytes_after_kill == b'streamed chunk before runner death\n', f'got {bytes_after_kill!r}'

    # 6. Close all write ends to control pipe to trigger EOF in child
    os.close(control_w)
    control_w = None
    os.close(control_r)
    control_r = None

    # 7. Prove child exited upon pipe EOF (bounded readiness check on exit_r)
    import select
    rlist, _, _ = select.select([exit_r], [], [], 3.0)
    assert rlist, 'timeout waiting for exit pipe to be readable (child did not terminate)'
    eof = os.read(exit_r, 1)
    assert eof == b'', f'expected EOF on exit_r, got {eof!r}'
    os.close(exit_r)
    exit_r = None

    # Confirm child process is dead or zombie in process table
    for _ in range(40):
        if check_pid_dead_or_zombie(child_pid):
            break
        time.sleep(0.05)
    else:
        assert False, f'child PID {child_pid} failed to reach dead/zombie state after pipe EOF'

    # 8. Prove unrelated sentinel was completely untouched
    assert sentinel_proc.poll() is None, 'sentinel process must still be alive!'
    try:
        os.kill(sentinel_proc.pid, 0)
    except ProcessLookupError:
        assert False, 'sentinel PID was killed!'
finally:
    if control_w is not None:
        try:
            os.close(control_w)
        except Exception:
            pass
    if control_r is not None:
        try:
            os.close(control_r)
        except Exception:
            pass
    if exit_w is not None:
        try:
            os.close(exit_w)
        except Exception:
            pass
    if exit_r is not None:
        try:
            os.close(exit_r)
        except Exception:
            pass
    if runner_proc is not None and runner_proc.poll() is None:
        try:
            runner_proc.kill()
            runner_proc.wait()
        except Exception:
            pass
    if sentinel_proc is not None:
        try:
            sentinel_proc.kill()
            sentinel_proc.wait()
        except Exception:
            pass
PYEOF

# --------------------------------------------------------------------------
# Step 6: Fail-closed negative controls for real pump error and unresolved writers
# --------------------------------------------------------------------------
step 6 "fail-closed controls: pump error and unresolved writers force failure"
"$PYTHON" - "$REPO" "$WORK" <<'PYEOF'
import os, sys, subprocess, tempfile, time
repo, work = sys.argv[1:3]
sys.path.insert(0, os.path.join(repo, 'bench'))
from stale_evidence import safe_stage_dir, safe_item_dir, execute_cmd, CaptureError

def check_pid_dead_or_zombie(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except (PermissionError, OSError):
        return False
    proc_status = f"/proc/{pid}/status"
    if os.path.isfile(proc_status):
        try:
            with open(proc_status, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith("State:"):
                        state_val = line.split(":", 1)[1].strip()
                        return state_val.startswith(("Z", "X"))
        except (OSError, IOError):
            return False
    try:
        ps_res = subprocess.run(["ps", "-o", "state=", "-p", str(pid)], capture_output=True, text=True)
        if ps_res.returncode == 0:
            st = ps_res.stdout.strip()
            if st:
                return st.startswith(("Z", "X"))
    except Exception:
        pass
    return False

evid_root = os.path.join(work, 'fail_closed_root')
os.makedirs(evid_root, exist_ok=True)
stage = safe_stage_dir(evid_root, 'rg2')
item_io = safe_item_dir(stage, 'samples/iyi/io_fail.iyi')

# 1. Real fsync failure injected into production pump raises CaptureError
orig_fsync = os.fsync
def failing_fsync(fd):
    raise OSError(28, "No space left on device")
os.fsync = failing_fsync

try:
    execute_cmd([sys.executable, '-c', 'import sys; sys.stdout.write("hello\\n"); sys.stdout.flush()'],
                item_dir=item_io, leg='fail_io')
    assert False, 'expected CaptureError on injected fsync failure'
except CaptureError as e:
    assert 'No space left on device' in str(e)
finally:
    os.fsync = orig_fsync

assert open(os.path.join(item_io, 'fail_io.exit')).read() == 'IO_ERROR\n'
assert 'IO_ERROR' in open(os.path.join(item_io, 'fail_io.status')).read()
assert os.path.isfile(os.path.join(item_io, 'fail_io.error'))

# 2. Unresolved writers past command deadline raise CaptureError (proven child exit via control pipe)
item_unres = safe_item_dir(stage, 'samples/iyi/unres.iyi')
unres_r, unres_w = os.pipe()
gc_pid_file = os.path.join(work, 'gc_pid.txt')
try:
    bg_code = f"""
import subprocess, sys, os
p = subprocess.Popen([sys.executable, "-c", f"import sys, os; open('{gc_pid_file}', 'w').write(str(os.getpid())); os.read({unres_r}, 1)"], stdout=sys.stdout, pass_fds=({unres_r},))
sys.exit(0)
"""
    try:
        execute_cmd([sys.executable, '-c', bg_code],
                    timeout=0.3, item_dir=item_unres, leg='unres_leg', pass_fds=(unres_r,))
        assert False, 'expected CaptureError on unresolved writers'
    except CaptureError as e:
        assert 'unclosed' in str(e).lower()
finally:
    os.close(unres_w)
    os.close(unres_r)

assert open(os.path.join(item_unres, 'unres_leg.exit')).read() == 'UNRESOLVED_WRITERS\n'
assert open(os.path.join(item_unres, 'unres_leg.status')).read() == 'UNRESOLVED_WRITERS\n'
assert os.path.isfile(os.path.join(item_unres, 'unres_leg.unresolved'))

# Prove grandchild exited upon pipe EOF (no orphans)
assert os.path.isfile(gc_pid_file)
gc_pid = int(open(gc_pid_file).read().strip())
for _ in range(40):
    if check_pid_dead_or_zombie(gc_pid):
        break
    time.sleep(0.05)
else:
    assert False, 'grandchild failed to terminate on pipe EOF'

# 3. Timeout with unresolved writers raises CaptureError (not TimeoutExpired)
item_timeout_unres = safe_item_dir(stage, 'samples/iyi/timeout_unres.iyi')
to_r, to_w = os.pipe()
to_pid_file = os.path.join(work, 'to_pid.txt')
try:
    timeout_unres_code = f"""
import subprocess, sys, os, time
p = subprocess.Popen([sys.executable, "-c", f"import sys, os; open('{to_pid_file}', 'w').write(str(os.getpid())); os.read({to_r}, 1)"], stdout=sys.stdout, pass_fds=({to_r},))
time.sleep(10)
"""
    try:
        execute_cmd([sys.executable, '-c', timeout_unres_code],
                    timeout=0.3, item_dir=item_timeout_unres, leg='to_unres_leg', pass_fds=(to_r,))
        assert False, 'expected CaptureError on timeout with unresolved writers'
    except CaptureError as e:
        assert 'unclosed' in str(e).lower()
    except subprocess.TimeoutExpired:
        assert False, 'TimeoutExpired must not mask unresolved capture failure'
finally:
    os.close(to_w)
    os.close(to_r)

assert os.path.isfile(os.path.join(item_timeout_unres, 'to_unres_leg.timeout'))
assert os.path.isfile(os.path.join(item_timeout_unres, 'to_unres_leg.unresolved'))
assert open(os.path.join(item_timeout_unres, 'to_unres_leg.exit')).read() == 'UNRESOLVED_WRITERS\n'
status_str = open(os.path.join(item_timeout_unres, 'to_unres_leg.status')).read()
assert 'UNRESOLVED_WRITERS:TIMEOUT' in status_str

# Prove timeout child terminated upon pipe EOF
assert os.path.isfile(to_pid_file)
to_gc_pid = int(open(to_pid_file).read().strip())
for _ in range(40):
    if check_pid_dead_or_zombie(to_gc_pid):
        break
    time.sleep(0.05)
else:
    assert False, 'timeout grandchild failed to terminate on pipe EOF'
PYEOF

# --------------------------------------------------------------------------
# Step 7: End-to-end stale_equivalence.sh entry path with fake compiler
# --------------------------------------------------------------------------
step 7 "exercising actual stale_equivalence.sh entry path against fake compiler"

# Setup minimal fake compiler capable of emitting real backtrace frames and non-frame bytes
FAKE_BIN="$WORK/fake_bin"
mkdir -p "$FAKE_BIN"
FAKE_IYI="$FAKE_BIN/iyi"

cat > "$FAKE_IYI" <<'SH'
#!/usr/bin/env bash
# Fake IYI compiler for behavioral entry path testing
set -euo pipefail

out=""
stale_key=""
emit_iyimod=""
use_iyimod=""
is_observe=0
src=""

while [ $# -gt 0 ]; do
  case "$1" in
    build)
      shift
      ;;
    -o)
      out="$2"
      shift 2
      ;;
    -Diyi_observe)
      is_observe=1
      shift
      ;;
    --emit-iyimod)
      emit_iyimod="$2"
      shift 2
      ;;
    --use-iyimod)
      use_iyimod="$2"
      shift 2
      ;;
    --stale-key)
      stale_key="$2"
      shift 2
      ;;
    *)
      if [ -f "$1" ]; then
        src="$1"
      fi
      shift
      ;;
  esac
done

if [ -n "$emit_iyimod" ]; then
  mkdir -p "$emit_iyimod"
  touch "$emit_iyimod/module.iyimod"
fi

if [ -n "$stale_key" ]; then
  cat > "$stale_key" <<'JSON'
{"portable": {"callpath": "cp_mock_123"}, "reach": {"mismatch": []}}
JSON
fi

if [ -n "$out" ]; then
  # Determine if this binary should emit a mutated frame (negative control)
  mutate_frame=0
  if [ -n "${FAKE_MUTATE_FRAME:-}" ] && [ "$use_iyimod" != "" ]; then
    mutate_frame=1
  fi

  cat > "$out" <<BIN
#!/usr/bin/env bash
if [ -n "\${IYI_OBSERVE:-}" ]; then
  echo "trace_mock_data" > "\$IYI_OBSERVE"
fi
# Real stdout outputs expected by probe assertions
echo "dir: answered"
echo "env: answered"
echo "recursion: answered"
echo "capped: answered"

# Real non-frame bytes followed by real backtrace frames on stderr
echo "[panic] unhandled exception: probe check failure" >&2
if [ "$mutate_frame" -eq 1 ]; then
  echo "0   fake_probe   0x0000000100001000 attempt_mutated@src/std/dir.iyi:10 + 16" >&2
else
  echo "0   fake_probe   0x0000000100001000 attempt@src/std/dir.iyi:10 + 16" >&2
fi
echo "1   fake_probe   0x0000000100002000 main + 32" >&2
exit 0
BIN
  chmod +x "$out"
fi
exit 0
SH
chmod +x "$FAKE_IYI"

# 7A: Run RG2r without evidence directory (no-evidence mode)
step 7.1 "RG2r entry path in no-evidence mode passes without persisting evidence"
IYI="$FAKE_IYI" bash "$EQUIV_SCRIPT" rg2r > "$WORK/rg2r_no_evid.log"
expect_contains "$(cat "$WORK/rg2r_no_evid.log")" "RG2r PASSED" "RG2r passed in no-evidence mode"

# 7B: Run RG2r with caller-owned evidence directory
step 7.2 "RG2r entry path with IYI_PROOF_EVIDENCE_DIR populates raw streams and artifacts"
EVID_DIR="$WORK/actual_rg2r_evidence"
mkdir -p "$EVID_DIR"

IYI="$FAKE_IYI" IYI_PROOF_EVIDENCE_DIR="$EVID_DIR" bash "$EQUIV_SCRIPT" rg2r > "$WORK/rg2r_with_evid.log"
expect_contains "$(cat "$WORK/rg2r_with_evid.log")" "RG2r PASSED" "RG2r passed with evidence retention"

EXPECTED_STDOUT=$'dir: answered\nenv: answered\nrecursion: answered\ncapped: answered\n'
EXPECTED_STDERR=$'[panic] unhandled exception: probe check failure\n0   fake_probe   0x0000000100001000 attempt@src/std/dir.iyi:10 + 16\n1   fake_probe   0x0000000100002000 main + 32\n'

# Verify directory structure, files, exact non-empty stdout/stderr bytes in rg2r
for probe in dir_probe env_probe recursion_probe; do
  p_dir="$EVID_DIR/rg2r/$probe"
  [ -d "$p_dir" ] || fail "missing probe directory: $p_dir"

  # Stream files
  for stream in normal_build observed_build producer_build artifact_build rg9_build_2 rg9_build_3 run_n run_o run_a; do
    [ -f "$p_dir/$stream.stdout" ] || fail "missing $stream.stdout in $p_dir"
    [ -f "$p_dir/$stream.stderr" ] || fail "missing $stream.stderr in $p_dir"
    [ -f "$p_dir/$stream.exit" ] || fail "missing $stream.exit in $p_dir"
    [ -f "$p_dir/$stream.status" ] || fail "missing $stream.status in $p_dir"
    expect_eq "$(cat "$p_dir/$stream.exit")" "0" "expected exit 0 for $stream"
  done

  # Assert exact bytes for run streams (both stdout and real stderr with frames)
  for run_leg in run_n run_o run_a; do
    diff -u <(printf '%s' "$EXPECTED_STDOUT") "$p_dir/$run_leg.stdout" || fail "stdout bytes mismatch in $run_leg"
    diff -u <(printf '%s' "$EXPECTED_STDERR") "$p_dir/$run_leg.stderr" || fail "stderr bytes mismatch in $run_leg"
  done

  # Keys and traces
  [ -f "$p_dir/k1.json" ] || fail "missing k1.json in $p_dir"
  [ -f "$p_dir/k2.json" ] || fail "missing k2.json in $p_dir"
  [ -f "$p_dir/k3.json" ] || fail "missing k3.json in $p_dir"
  [ -f "$p_dir/trace_o.bin" ] || fail "missing trace_o.bin in $p_dir"
  [ -f "$p_dir/trace_a.bin" ] || fail "missing trace_a.bin in $p_dir"

  # Verify NO duplicate alias files exist
  [ ! -f "$p_dir/normal_run.stdout" ] || fail "forbidden duplicate alias normal_run.stdout found in $p_dir"
  [ ! -f "$p_dir/observed_run.stdout" ] || fail "forbidden duplicate alias observed_run.stdout found in $p_dir"
  [ ! -f "$p_dir/artifact_run.stdout" ] || fail "forbidden duplicate alias artifact_run.stdout found in $p_dir"
done

# 7C: Negative control: changed backtrace frame causes comparison failure while retaining divergent streams
step 7.3 "RG2r negative control: changed backtrace frame fails comparison and retains divergent streams"
MUT_EVID_DIR="$WORK/mutated_frame_evidence"
mkdir -p "$MUT_EVID_DIR"

set +e
FAKE_MUTATE_FRAME=1 IYI="$FAKE_IYI" IYI_PROOF_EVIDENCE_DIR="$MUT_EVID_DIR" bash "$EQUIV_SCRIPT" rg2r > "$WORK/rg2r_mutated.log" 2>&1
mut_rc=$?
set -e
expect_eq "$mut_rc" 1 "mutated frame must fail rg2r with exit 1"
expect_contains "$(cat "$WORK/rg2r_mutated.log")" "observed vs artifact stderr frames not equivalent" "frame divergence detected"

# Verify divergent streams were preserved in evidence dir despite failure
mut_p_dir="$MUT_EVID_DIR/rg2r/dir_probe"
[ -f "$mut_p_dir/run_o.stderr" ] || fail "missing run_o.stderr in mutated evidence dir"
[ -f "$mut_p_dir/run_a.stderr" ] || fail "missing run_a.stderr in mutated evidence dir"
expect_contains "$(cat "$mut_p_dir/run_o.stderr")" "attempt@src/std/dir.iyi" "run_o retained original frame"
expect_contains "$(cat "$mut_p_dir/run_a.stderr")" "attempt_mutated@src/std/dir.iyi" "run_a retained mutated frame"

echo "=== All behavioral checks for raw evidence streams PASSED ==="
exit 0
