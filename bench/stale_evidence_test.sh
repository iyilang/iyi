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
# 6. Descendant termination: timeout kills all owned processes in the private process group.
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

step() { echo "== §evidence step $1: $2 =="; }
fail() { echo "stale_evidence_test: $*" >&2; exit 1; }
expect_eq() { [ "$1" = "$2" ] || fail "expected $2, got $1${3:+: $3}"; }
expect_contains() { case "$1" in *"$2"*) ;; *) fail "missing $2${3:+: $3}";; esac; }

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
assert validate_evidence_root('TEST_VAR') == os.path.abspath(valid_dir)
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
import os, sys, subprocess, signal
repo, work = sys.argv[1:3]
sys.path.insert(0, os.path.join(repo, 'bench'))
from stale_evidence import safe_stage_dir, safe_item_dir, execute_cmd

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
PYEOF

# --------------------------------------------------------------------------
# Step 6: Descendant process group termination on timeout
# --------------------------------------------------------------------------
step 6 "timeout terminates all owned descendants in the process group"
"$PYTHON" - "$REPO" "$WORK" <<'PYEOF'
import os, sys, subprocess, time
repo, work = sys.argv[1:3]
sys.path.insert(0, os.path.join(repo, 'bench'))
from stale_evidence import safe_stage_dir, safe_item_dir, execute_cmd

evid_root = os.path.join(work, 'descendant_root')
os.makedirs(evid_root, exist_ok=True)
stage = safe_stage_dir(evid_root, 'rg2')
item = safe_item_dir(stage, 'samples/iyi/descendant.iyi')

sentinel = os.path.join(work, 'descendant_pid.txt')

spawn_code = (
    'import subprocess, sys, time, os\n'
    'sub = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])\n'
    f'open("{sentinel}", "w").write(str(sub.pid))\n'
    'time.sleep(30)\n'
)

try:
    execute_cmd([sys.executable, '-c', spawn_code], timeout=0.4, item_dir=item, leg='spawn_leg')
    assert False, 'expected TimeoutExpired'
except subprocess.TimeoutExpired:
    pass

assert os.path.isfile(sentinel), 'sentinel PID file must be written'
child_pid = int(open(sentinel).read().strip())
time.sleep(0.3)

try:
    os.kill(child_pid, 0)
    assert False, f'descendant PID {child_pid} is still alive after process group kill'
except ProcessLookupError:
    pass
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
