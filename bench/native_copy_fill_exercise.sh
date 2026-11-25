#!/usr/bin/env bash
# Copy/fill call targets, byte-for-byte hosted parity, and behavioral mutations.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
. bench/lib/host.sh || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  echo "a functional Python interpreter is required" >&2
  exit 1
fi
if [ "$HOST_OS" = darwin ]; then
  export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"
  export LIBRARY_PATH=${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}
fi
export IYI_PATH="$(native_path "$REPO/src")"
unset IYI_NATIVE_REGALLOC
WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-copy-fill.XXXXXX") || exit 1
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
failed=0
fail() { echo "FAIL: $*"; failed=1; }
. bench/lib/native_signature.sh
. bench/lib/mutation.sh
export NATIVE_SIGNATURE_FAILURE_FILE="$WORK/signature-failure"
FIX=bench/fixtures/native_copy_fill
DRV="$WORK/native_cg$EXE"

build_driver() {
  ./bin/iyi build -o "$(native_path "$1")" "$(native_path src/compiler/tools/native_cg.iyi)" >"$WORK/build.$(basename "$1").log" 2>&1
}

# Exit 1 is an observed timeout, 2 is an execution setup failure. A signal or
# nonzero program status remains observable and is compared with the reference.
bounded_run() {
  "$PY" - "$1" "$2" <<'PY'
import subprocess
import sys
from pathlib import Path

exe, prefix = sys.argv[1:]
for suffix in ('.out', '.status', '.timeout'):
    Path(prefix + suffix).unlink(missing_ok=True)
try:
    proc = subprocess.run([exe], stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
except subprocess.TimeoutExpired:
    Path(prefix + '.timeout').touch()
    print('decisive: execution timed out')
    sys.exit(1)
except OSError as exc:
    print('INVALID: cannot execute fixture:', exc)
    sys.exit(2)
Path(prefix + '.out').write_bytes(proc.stdout)
Path(prefix + '.status').write_text(str(proc.returncode) + '\n')
sys.exit(0)
PY
}

emit_obj() {
  local drv=$1 clean=$2 key=$3 prefix=$4
  [ -x "$drv" ] && [ -f "$WORK/$key.ir" ] || return 2
  IYI_NATIVE_MIR_CLEAN=$clean "$drv" obj "$(native_path "$WORK/$key.ir")" "$(native_path "$prefix.o")" >"$prefix.obj.log" 2>&1 || return 2
  [ -s "$prefix.o" ] || return 2
}

check_output() {
  local drv=$1 clean=$2 key=$3 reference=$4 prefix="$WORK/check.$3.$2" rc ext
  [ -f "$WORK/expected.$reference.out" ] && [ -f "$WORK/expected.$reference.status" ] || return 2
  emit_obj "$drv" "$clean" "$key" "$prefix" || { cat "$prefix.obj.log" 2>/dev/null || true; return 2; }
  cc "$prefix.o" "$WORK/runtime.o" -o "$prefix.bin" >"$prefix.link.log" 2>&1 || { cat "$prefix.link.log"; return 2; }
  native_signature_ok "$prefix.bin" || return 2
  bounded_run "$prefix.bin" "$prefix"
  rc=$?
  [ "$rc" -ne 1 ] || { echo "decisive: $key timed out"; return 1; }
  [ "$rc" -eq 0 ] || return 2
  for ext in out status; do
    cmp -s "$prefix.$ext" "$WORK/expected.$reference.$ext"
    rc=$?
    [ "$rc" -ne 1 ] || { echo "decisive: $key $ext differs from the hosted twin"; return 1; }
    [ "$rc" -eq 0 ] || return 2
  done
  return 0
}

echo "== 1. build the native driver and assemble fixtures"
if ! build_driver "$DRV"; then
  cat "$WORK/build.$(basename "$DRV").log"
  echo "SOME NATIVE COPY FILL CHECKS FAILED"
  exit 1
fi
cat "$FIX/header.ir" "$FIX/defined.ir" "$FIX/operations.ir" >"$WORK/defined.ir"
cat "$FIX/header.ir" "$FIX/declared.ir" "$FIX/operations.ir" >"$WORK/declared.ir"
cat "$FIX/header.ir" "$FIX/operations.ir" >"$WORK/absent.ir"
cat "$FIX/header.ir" "$FIX/cycle.ir" >"$WORK/cycle.ir"
cat "$FIX/header.ir" "$FIX/defined.ir" "$FIX/benchmark.ir" >"$WORK/benchmark.ir"

cat >"$WORK/check_shape.py" <<'PY'
import os
import re
import subprocess
import sys
from pathlib import Path

driver, folder = sys.argv[1:]
folder = Path(folder)
errors = []
defects = []
checks = 0

def symbols(fixture):
    text = (folder / (fixture + '.ir')).read_text()
    names = re.findall(r'^(?:define|declare)\b[^@\n]*@([A-Za-z0-9_]+)\(', text, re.M)
    for name in ('__iyi_native_memcpy', '__iyi_native_memmove', '__iyi_native_memset',
                 '__iyi_native_fptosi_sat_i128', '__iyi_native_fptoui_sat_i128',
                 '__iyi_native_udivti3', '__iyi_native_umodti3', '__iyi_native_divti3', '__iyi_native_modti3'):
        if name not in names:
            names.append(name)
    return {name: index for index, name in enumerate(names)}

def expect(fixture, function, expected, clean):
    global checks
    env = dict(os.environ, IYI_NATIVE_MIR_CLEAN=str(clean))
    try:
        proc = subprocess.run([driver, 'mir', str(folder / (fixture + '.ir')), function],
                              env=env, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as exc:
        errors.append(f'{fixture}/{function}: MIR unavailable: {exc}')
        return
    if proc.returncode or not proc.stdout.startswith('function ' + function + '\n'):
        errors.append(f'{fixture}/{function}: invalid MIR: {proc.stderr.strip()}')
        return
    checks += 1
    found = [int(x) for x in re.findall(r'^  Bl/\d+\s+sym=(\d+)', proc.stdout, re.M)]
    table = symbols(fixture)
    try:
        wanted = [table[name] for name in expected]
    except KeyError as exc:
        errors.append(f'{fixture}/{function}: absent symbol {exc}')
        return
    if found != wanted:
        defects.append(f'{fixture}/{function} clean={clean}: calls {found}, expected {wanted} ({expected})')

for fixture in ('defined', 'declared', 'absent'):
    for clean in (0, 1):
        for operation in ('copy', 'move', 'set'):
            for size in ('zero', 'small'):
                expect(fixture, operation + '_' + size, [], clean)
            target = {'copy': 'memcpy', 'move': 'memmove', 'set': 'memset'}[operation]
            if fixture != 'defined':
                target = '__iyi_native_' + target
            for size in ('large', 'dynamic'):
                expect(fixture, operation + '_' + size, [target], clean)
for clean in (0, 1):
    expect('cycle', 'memcpy', ['__iyi_native_memcpy', '__iyi_native_memset'], clean)
    expect('cycle', 'memmove', ['__iyi_native_memmove'], clean)
    expect('cycle', 'memset', ['__iyi_native_memset'], clean)
for message in errors:
    print('INVALID:', message)
for message in defects:
    print('decisive:', message)
print(f'MIR target checks: {checks}')
if errors or not checks:
    sys.exit(2)
if defects:
    sys.exit(1)
PY

echo "== 2. assert defined, declared, absent, inline and cycle call shapes"
if ! "$PY" "$(native_path "$WORK/check_shape.py")" "$(native_path "$DRV")" "$(native_path "$WORK")"; then
  fail "MIR target checks"
fi

echo "== 3. compare native execution with hosted twins"
if [ "$HOST_ID" = darwin-arm64 ]; then
  if ! command -v cc >/dev/null 2>&1; then
    fail "cc is required"
    echo "SOME NATIVE COPY FILL CHECKS FAILED"
    exit 1
  fi
  if ! "$DRV" obj "$(native_path src/compiler/native/rt/builtins.ir)" "$(native_path "$WORK/runtime.o")" >"$WORK/runtime.log" 2>&1; then
    cat "$WORK/runtime.log"
    fail "native runtime did not build"
  fi
  for reference in operations cycle benchmark; do
    if ! ./bin/iyi build -o "$(native_path "$WORK/$reference.hosted$EXE")" "$(native_path "$FIX/$reference.iyi")" >"$WORK/$reference.hosted.log" 2>&1; then
      cat "$WORK/$reference.hosted.log"
      fail "$reference: hosted twin did not build"
      continue
    fi
    if ! bounded_run "$WORK/$reference.hosted$EXE" "$WORK/expected.$reference"; then
      fail "$reference: hosted twin could not be observed"
      continue
    fi
    if [ "$(cat "$WORK/expected.$reference.status")" != 0 ]; then
      fail "$reference: hosted twin exited nonzero"
    fi
  done
  for key in defined declared absent cycle benchmark; do
    reference=$key
    case $key in defined|declared|absent) reference=operations ;; esac
    parity_ok=1
    for clean in 0 1; do
      if ! check_output "$DRV" "$clean" "$key" "$reference"; then
        parity_ok=0
        fail "$key: clean=$clean differs from hosted"
      fi
    done
    [ "$parity_ok" -eq 0 ] || echo "parity: $key (clean=0,1)"
  done
else
  host_limited "Darwin objects cannot be linked or executed on $HOST_ID"
fi

MUTATION_INVALID="$WORK/mutation.invalid"
check_mutant() {
  local key=$1 reference=$2 mutant="$WORK/mutant$EXE" rc
  if ! build_driver "$mutant"; then
    cat "$WORK/build.$(basename "$mutant").log"
    touch "$MUTATION_INVALID"
    return 2
  fi
  check_output "$mutant" 1 "$key" "$reference"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    touch "$MUTATION_INVALID"
    return 2
  fi
  if [ "$key" = cycle ] && [ "$rc" -eq 1 ]; then
    if [ -e "$WORK/check.cycle.1.timeout" ]; then
      echo "timeout" >"$WORK/cycle.runaway"
    elif [ -f "$WORK/check.cycle.1.status" ]; then
      case "$(cat "$WORK/check.cycle.1.status")" in
        -10|-11) echo "signal $(cat "$WORK/check.cycle.1.status")" >"$WORK/cycle.runaway" ;;
        *) touch "$MUTATION_INVALID"; return 2 ;;
      esac
    else
      touch "$MUTATION_INVALID"
      return 2
    fi
  fi
  return "$rc"
}
prove_copy_mutation() {
  local label=$1 old=$2 new=$3 key=$4 reference=$5
  rm -f "$MUTATION_INVALID"
  if ! prove_mutation "$label" src/compiler/native/aarch64/isel.iyi "$old" "$new" -- check_mutant "$key" "$reference"; then
    fail "mutation was not caught: $label"
  fi
  [ ! -e "$MUTATION_INVALID" ] || fail "mutation check had invalid setup: $label"
}

echo "== 4. mutation proofs"
if [ "$HOST_ID" = darwin-arm64 ]; then
  prove_copy_mutation "overlap: move calls the module copy routine" \
    '    name = memory_target(overlap ? "memmove" : "memcpy", overlap ? "__iyi_native_memmove" : "__iyi_native_memcpy") # copy-fill-transfer-target' \
    '    name = memory_target("memcpy", overlap ? "__iyi_native_memmove" : "__iyi_native_memcpy") # copy-fill-transfer-target' defined operations
  prove_copy_mutation "cycle: routine body can call itself" \
    '    return fallback if @fn.name == "memcpy" || @fn.name == "memmove" || @fn.name == "memset" # copy-fill-cycle-guard' \
    '    return fallback if false # copy-fill-cycle-guard' cycle cycle
  if [ -e "$WORK/cycle.runaway" ]; then
    echo "    detected: runaway recursion ($(cat "$WORK/cycle.runaway"))"
  fi
  prove_copy_mutation "fill: swap byte and length" \
    '    call_helper(name, dst, value, len) # copy-fill-argument-order' \
    '    call_helper(name, dst, len, value) # copy-fill-argument-order' defined operations
else
  host_limited "runtime copy/fill mutation proofs (macOS arm64)"
fi
[ ! -e "$NATIVE_SIGNATURE_FAILURE_FILE" ] || fail "a native executable failed signature verification"
echo
if [ "$failed" -eq 0 ]; then
  echo "ALL NATIVE COPY FILL CHECKS PASSED!"
  exit 0
fi
echo "SOME NATIVE COPY FILL CHECKS FAILED"
exit 1
