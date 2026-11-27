#!/usr/bin/env bash
# A reused captured ProcLiteral must bind the callee's free output on every call.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")" || exit 1
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"
fixture="$REPO_NATIVE/bench/fixtures/lowpool_generic_group_forward.iyi"
"$IYI" build -o "$WORK_NATIVE/hosted$EXE" "$fixture" > "$WORK/hosted.build.log" 2>&1 || { cat "$WORK/hosted.build.log"; exit 1; }
if [ -z "$PY" ]; then echo 'FAIL: Python is required to distinguish exits from signals'; exit 1; fi
run_fixture() {
  "$PY" - "$1" "$2" "$3" <<'PY'
import subprocess
import sys

try:
    with open(sys.argv[2], "wb") as output:
        result = subprocess.run([sys.argv[1]], stdout=output, stderr=subprocess.STDOUT, timeout=30)
except (OSError, subprocess.TimeoutExpired) as error:
    print("INVALID: fixture did not complete:", error)
    sys.exit(2)
if result.returncode < 0 or result.returncode > 255:
    print("INVALID: fixture terminated abnormally:", result.returncode)
    sys.exit(2)
with open(sys.argv[3], "w") as status:
    status.write(str(result.returncode))
PY
}
run_fixture "$WORK_NATIVE/hosted$EXE" "$WORK_NATIVE/hosted.out" "$WORK_NATIVE/hosted.status" || exit 1
hosted="$(< "$WORK/hosted.status")"

check_group_output() {
  if ! "$IYI" build -o "$WORK_NATIVE/stage$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/build.log" 2>&1; then
    echo 'INVALID: group-output compiler failed to build'
    cat "$WORK/build.log"
    return 2
  fi
  if [ "$HOST_OS" = darwin ] && ! codesign -v --strict "$WORK/stage$EXE"; then
    echo 'INVALID: group-output compiler signature verification failed'
    return 2
  fi
  local result=0
  "$WORK/stage$EXE" "$fixture" -o "$WORK_NATIVE/port.ir" --pipeline typed --prelude --probe-phase --emit ir > "$WORK/stage.log" 2>"$WORK/stage.err" || result=$?
  if [ "$result" -ne 0 ]; then
    if [ -f "$WORK/group.baseline" ] &&
       expected_refusal "$result" "$WORK/stage.err" refuse_port '^undefined constant T$' &&
       grep -Fxq '[phase] bodies: start' "$WORK/stage.log" &&
       ! grep -Fxq '[phase] bodies: pass' "$WORK/stage.log" &&
       awk -v prefix="  source: $fixture:7:" 'index($0, prefix) == 1 && substr($0, length(prefix) + 1) ~ /^[0-9]+$/ { found=1 } END { exit !found }' "$WORK/stage.err"; then
      echo "decisive: $fixture:7: captured-block type T was not bound"
      return 1
    fi
    echo 'INVALID: group-output compiler did not emit IR or reach the localized captured-block refusal'
    cat "$WORK/stage.log" "$WORK/stage.err"
    return 2
  fi
  [ -s "$WORK/port.ir" ] || { echo 'INVALID: group-output IR is empty'; return 2; }
  if ! "$WORK/stage$EXE" "$fixture" -o "$WORK_NATIVE/native" --pipeline typed --prelude --probe-phase > "$WORK/stage.log" 2>&1; then
    echo 'INVALID: group-output fixture did not link'
    cat "$WORK/stage.log"
    return 2
  fi
  if [ ! -f "$WORK/baseline.ir" ]; then
    cp "$WORK/port.ir" "$WORK/baseline.ir"
  elif [ "$HOST_ID" != darwin-arm64 ]; then
    cmp -s "$WORK/baseline.ir" "$WORK/port.ir" || return 1
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then return 0; fi
  codesign -v --strict "$WORK/native" || return 2
  run_fixture "$WORK_NATIVE/native" "$WORK_NATIVE/native.out" "$WORK_NATIVE/native.status" || return 2
  local actual
  actual="$(< "$WORK/native.status")"
  [ "$actual" = "$hosted" ] && cmp -s "$WORK/hosted.out" "$WORK/native.out"
}
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "group output: AArch64 Mach-O signature and execution require macOS arm64 ($HOST_ID checks typed IR and emits Mach-O)"
fi
check_group_output || { echo 'FAIL: nested group generic output does not match hosted'; exit 1; }
: > "$WORK/group.baseline"
prove_mutation 'a reused captured block does not bind the free output' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '                if captured_block_type.is_a?(ProcInstanceType)' \
  '                if false && captured_block_type.is_a?(ProcInstanceType)' -- check_group_output || exit 1
echo 'nested group generic output: baseline checked; mutation caught'
