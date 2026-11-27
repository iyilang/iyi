#!/usr/bin/env bash
# Exercise Process.run through hosted and native stage-one entry paths.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then echo 'a functional Python interpreter is required' >&2; exit 1; fi
REPO_NATIVE="$(native_path "$REPO")" || exit 1
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
export IYI_PATH="$REPO_NATIVE/src"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"
fixture="$REPO/bench/fixtures/native_process_run.iyi"
probe="$REPO/bench/fixtures/spawnshare_process.iyi"

run_monitored() {
  local executable="$1" arg
  shift
  local -a args=()
  for arg in "$@"; do
    case "$arg" in
      "$REPO"/*|"$WORK"/*) arg="$(native_path "$arg")" || return 2 ;;
    esac
    args+=("$arg")
  done
  if [ -n "${IYI_MEMORY_MONITOR:-}" ]; then
    "$IYI_MEMORY_MONITOR" "$executable" "${args[@]}"
  else
    "$executable" "${args[@]}"
  fi
}

run_timed() {
  local seconds="$1" executable="$2"
  shift 2
  "$PY" - "$seconds" "$(native_path "$executable")" "$@" <<'PY'
import os, signal, subprocess, sys
seconds = int(sys.argv[1])
proc = subprocess.Popen(sys.argv[2:], start_new_session=(os.name != 'nt'))
try:
    status = proc.wait(timeout=seconds)
except subprocess.TimeoutExpired:
    if os.name == 'nt':
        proc.terminate()
    else:
        os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if os.name == 'nt':
            proc.kill()
        else:
            os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
    print('FAIL: process timed out', file=sys.stderr)
    sys.exit(124)
sys.exit(status if status >= 0 else 128 - status)
PY
}

if ! run_monitored "$IYI" build -o "$WORK/hosted$EXE" "$fixture" > "$WORK/hosted.build" 2>&1; then
  echo 'FAIL: hosted process fixture did not build'; cat "$WORK/hosted.build"; exit 1
fi
if [ "$HOST_OS" != windows ]; then
  if ! run_timed 120 "$WORK/hosted$EXE" > "$WORK/hosted.out" 2> "$WORK/hosted.err"; then
    echo 'FAIL: hosted process fixture'; cat "$WORK/hosted.out" "$WORK/hosted.err"; exit 1
  fi
else
  host_limited 'native process: hosted process fixture executes /bin/sh, /bin/cat and /bin/sleep, which are Unix paths'
fi
if ! run_monitored "$IYI" build -o "$WORK/stage1$EXE" "$REPO/src/compiler/stage1.iyi" > "$WORK/stage1.build" 2>&1; then
  echo 'FAIL: stage1 did not build'; cat "$WORK/stage1.build"; exit 1
fi
if ! run_monitored "$IYI" build -o "$WORK/typed$EXE" "$REPO/src/compiler/tools/compile_native.iyi" > "$WORK/typed.build" 2>&1; then
  echo 'FAIL: typed compiler did not build'; cat "$WORK/typed.build"; exit 1
fi
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited 'native process: stage-one executable generation and execution require Darwin arm64; hosted and typed IR checks still run'
fi
check_port_ir() {
  local input="$1" name="$2"
  if ! run_monitored "$WORK/typed$EXE" "$input" -o "$WORK/$name.ir" --pipeline typed --prelude --emit ir >"$WORK/$name.ir.log" 2>&1 || [ ! -s "$WORK/$name.ir" ]; then
    echo "FAIL: typed IR for $name"; cat "$WORK/$name.ir.log"; return 1
  fi
}
check_port_ir "$probe" process-probe || exit 1
check_port_ir "$fixture" process-fixture || exit 1

# Hosted early generic ancestry runs the default once; its late path currently
# runs the same ancestor twice. The port deliberately runs both once.
for shape in early late; do
  once_fixture="$REPO/bench/fixtures/ivar_initializer_${shape}.iyi"
  if ! run_monitored "$IYI" build -o "$WORK/$shape-hosted$EXE" "$once_fixture" > "$WORK/$shape-hosted.build" 2>&1; then
    echo "FAIL: hosted $shape initializer fixture did not build"; cat "$WORK/$shape-hosted.build"; exit 1
  fi
  check_port_ir "$once_fixture" "$shape" || exit 1
  hosted_status=0
  run_timed 120 "$WORK/$shape-hosted$EXE" > "$WORK/$shape-hosted.out" 2> "$WORK/$shape-hosted.err" || hosted_status=$?
  if [ "$shape" = early ]; then
    if [ "$hosted_status" -ne 0 ] || [ "$(cat "$WORK/$shape-hosted.out")" != 'value=1,count=1' ]; then
      echo 'FAIL: hosted early initializer behavior changed'; cat "$WORK/$shape-hosted.out" "$WORK/$shape-hosted.err"; exit 1
    fi
  elif [ "$hosted_status" -ne 1 ] || [ "$(cat "$WORK/$shape-hosted.out")" != 'value=2,count=2' ] ||
       ! grep -Fq 'initializer did not run once per allocation' "$WORK/$shape-hosted.err"; then
    echo 'FAIL: hosted late initializer discrepancy changed'; cat "$WORK/$shape-hosted.out" "$WORK/$shape-hosted.err"; exit 1
  fi
  if [ "$HOST_ID" = darwin-arm64 ]; then
    if ! run_monitored "$WORK/stage1$EXE" build -o "$WORK/$shape-native" "$once_fixture" > "$WORK/$shape-native.build" 2>&1 ||
       ! codesign -v --strict "$WORK/$shape-native"; then
      echo "FAIL: native $shape initializer fixture did not build and sign"; cat "$WORK/$shape-native.build"; exit 1
    fi
    if ! run_timed 120 "$WORK/$shape-native" > "$WORK/$shape-native.out" 2> "$WORK/$shape-native.err" ||
       [ "$(cat "$WORK/$shape-native.out")" != 'value=1,count=1' ]; then
      echo "FAIL: native $shape initializer did not run once"; cat "$WORK/$shape-native.out" "$WORK/$shape-native.err"; exit 1
    fi
    echo "  $shape generic ancestor: hosted $(cat "$WORK/$shape-hosted.out"), native $(cat "$WORK/$shape-native.out")"
  fi
done
for case_name in specializations generic_module; do
  case_fixture="$REPO/bench/fixtures/ivar_initializer_${case_name}.iyi"
  if ! run_monitored "$IYI" build -o "$WORK/$case_name-hosted$EXE" "$case_fixture" > "$WORK/$case_name-hosted.build" 2>&1; then
    echo "FAIL: hosted $case_name initializer did not build"; cat "$WORK/$case_name-hosted.build"; exit 1
  fi
  check_port_ir "$case_fixture" "$case_name" || exit 1
  if ! run_timed 120 "$WORK/$case_name-hosted$EXE" > "$WORK/$case_name-hosted.out" 2> "$WORK/$case_name-hosted.err" ||
     [ "$(cat "$WORK/$case_name-hosted.out")" != 'first=7,second=13' ]; then
    echo "FAIL: hosted $case_name initializer"; cat "$WORK/$case_name-hosted.out" "$WORK/$case_name-hosted.err"; exit 1
  fi
  if [ "$HOST_ID" = darwin-arm64 ]; then
    if ! run_monitored "$WORK/stage1$EXE" build -o "$WORK/$case_name-native" "$case_fixture" > "$WORK/$case_name-native.build" 2>&1 ||
       ! codesign -v --strict "$WORK/$case_name-native"; then
      echo "FAIL: native $case_name initializer did not build and sign"; cat "$WORK/$case_name-native.build"; exit 1
    fi
    if ! run_timed 120 "$WORK/$case_name-native" > "$WORK/$case_name-native.out" 2> "$WORK/$case_name-native.err" ||
       [ "$(cat "$WORK/$case_name-native.out")" != 'first=7,second=13' ]; then
      echo "FAIL: native $case_name initializer"; cat "$WORK/$case_name-native.out" "$WORK/$case_name-native.err"; exit 1
    fi
  fi
  echo "  $case_name initializers: first=7,second=13"
done

# A generic module's parameter shadows a same-named class parameter. Current
# hosted builds reject this valid case; accept a future hosted fix as well.
shadow="$REPO/bench/fixtures/ivar_initializer_module_shadow.iyi"
if run_monitored "$IYI" build -o "$WORK/shadow-hosted$EXE" "$shadow" > "$WORK/shadow-hosted.build" 2>&1; then
  if ! run_timed 120 "$WORK/shadow-hosted$EXE" > "$WORK/shadow-hosted.out" 2> "$WORK/shadow-hosted.err" ||
     [ "$(cat "$WORK/shadow-hosted.out")" != 'value=7' ]; then
    echo 'FAIL: hosted module shadow result'; cat "$WORK/shadow-hosted.out" "$WORK/shadow-hosted.err"; exit 1
  fi
elif ! grep -F 'must be First, not Second' "$WORK/shadow-hosted.build" >/dev/null; then
  echo 'FAIL: unexpected hosted module shadow refusal'; cat "$WORK/shadow-hosted.build"; exit 1
fi
check_port_ir "$shadow" shadow || exit 1
if [ "$HOST_ID" = darwin-arm64 ]; then
  if ! run_monitored "$WORK/stage1$EXE" build -o "$WORK/shadow-native" "$shadow" > "$WORK/shadow-native.build" 2>&1 ||
     ! codesign -v --strict "$WORK/shadow-native"; then
    echo 'FAIL: native module shadow fixture did not build and sign'; cat "$WORK/shadow-native.build"; exit 1
  fi
  if ! run_timed 120 "$WORK/shadow-native" > "$WORK/shadow-native.out" 2> "$WORK/shadow-native.err" ||
     [ "$(cat "$WORK/shadow-native.out")" != 'value=7' ]; then
    echo 'FAIL: native module shadow result'; cat "$WORK/shadow-native.out" "$WORK/shadow-native.err"; exit 1
  fi
  echo '  shadowed module type parameter: value=7'
fi

invalid="$REPO/bench/fixtures/ivar_initializer_invalid.iyi"
if run_monitored "$IYI" build -o "$WORK/invalid-hosted$EXE" "$invalid" > "$WORK/invalid-hosted.build" 2>&1 ||
   ! grep -F "instance variable '@value' of Box(Int32) must be Int32" "$WORK/invalid-hosted.build" >/dev/null; then
  echo 'FAIL: hosted invalid generic initializer was not rejected'; cat "$WORK/invalid-hosted.build"; exit 1
fi
if run_monitored "$WORK/typed$EXE" "$invalid" -o "$WORK/invalid.ir" --pipeline typed --prelude --emit ir >"$WORK/invalid-ir.log" 2>&1 ||
   [ -e "$WORK/invalid.ir" ] ||
   ! grep -F "instance variable '@value' of Box(Int32) must be Int32" "$WORK/invalid-ir.log" >/dev/null; then
  echo 'FAIL: typed invalid generic initializer was not rejected'; cat "$WORK/invalid-ir.log"; exit 1
fi
if [ "$HOST_ID" = darwin-arm64 ]; then
  if run_monitored "$WORK/stage1$EXE" build -o "$WORK/invalid-native" "$invalid" > "$WORK/invalid-native.build" 2>&1 ||
     [ -e "$WORK/invalid-native" ] ||
     ! grep -F "instance variable '@value' of Box(Int32) must be Int32" "$WORK/invalid-native.build" >/dev/null; then
    echo 'FAIL: native invalid generic initializer was not rejected'; cat "$WORK/invalid-native.build"; exit 1
  fi
fi
echo '  incompatible generic initializer: rejected'

terminating="$REPO/bench/fixtures/ivar_initializer_noreturn_arena.iyi"
if ! run_monitored "$IYI" build -o "$WORK/terminating-hosted$EXE" "$terminating" > "$WORK/terminating-hosted.build" 2>&1; then
  echo 'FAIL: hosted terminating arena initializer did not build'; cat "$WORK/terminating-hosted.build"; exit 1
fi
check_port_ir "$terminating" terminating || exit 1
hosted_status=0
run_timed 120 "$WORK/terminating-hosted$EXE" > "$WORK/terminating-hosted.out" 2> "$WORK/terminating-hosted.err" || hosted_status=$?
if [ "$hosted_status" -ne 7 ]; then
  echo 'FAIL: hosted terminating arena initializer did not exit 7'; cat "$WORK/terminating-hosted.out" "$WORK/terminating-hosted.err"; exit 1
fi
if [ "$HOST_ID" = darwin-arm64 ]; then
  if ! run_monitored "$WORK/stage1$EXE" build -o "$WORK/terminating-native" "$terminating" > "$WORK/terminating-native.build" 2>&1 ||
     ! codesign -v --strict "$WORK/terminating-native"; then
    echo 'FAIL: native terminating arena initializer did not build and sign'; cat "$WORK/terminating-native.build"; exit 1
  fi
  native_status=0
  run_timed 120 "$WORK/terminating-native" > "$WORK/terminating-native.out" 2> "$WORK/terminating-native.err" || native_status=$?
  if [ "$native_status" -ne 7 ] ||
     ! cmp "$WORK/terminating-hosted.out" "$WORK/terminating-native.out" ||
     ! cmp "$WORK/terminating-hosted.err" "$WORK/terminating-native.err"; then
    echo 'FAIL: terminating arena initializer did not exit 7'; cat "$WORK/terminating-native.out" "$WORK/terminating-native.err"; exit 1
  fi
  echo '  terminating arena initializer: hosted and native exit 7'
fi


if [ "$HOST_ID" = darwin-arm64 ]; then
if ! run_monitored "$WORK/stage1$EXE" build -o "$WORK/probe" "$probe" > "$WORK/probe.build" 2>&1; then
  echo 'FAIL: native process probe did not build'; cat "$WORK/probe.build"; exit 1
fi
if ! codesign -v --strict "$WORK/probe"; then
  echo 'FAIL: native probe signature'; exit 1
fi
if ! run_timed 120 "$WORK/probe" > "$WORK/probe.out" 2> "$WORK/probe.err" ||
   [ "$(cat "$WORK/probe.out")" != 'process-ok:parent-ok' ]; then
  echo 'FAIL: native process probe'; cat "$WORK/probe.out" "$WORK/probe.err"; exit 1
fi
if ! run_monitored "$WORK/stage1$EXE" build -o "$WORK/native" "$fixture" > "$WORK/native.build" 2>&1; then
  echo 'FAIL: native process fixture did not build'; cat "$WORK/native.build"; exit 1
fi
if ! codesign -v --strict "$WORK/native"; then
  echo 'FAIL: native fixture signature'; exit 1
fi
if ! run_timed 120 "$WORK/native" > "$WORK/native.out" 2> "$WORK/native.err" ||
   ! cmp -s "$WORK/hosted.out" "$WORK/native.out" ||
   ! cmp -s "$WORK/hosted.err" "$WORK/native.err"; then
  echo 'FAIL: native process output differs'; cat "$WORK/native.out" "$WORK/native.err"; exit 1
fi
if ! run_monitored "$WORK/stage1$EXE" run "$fixture" > "$WORK/run.out" 2> "$WORK/run.err" ||
   ! cmp -s "$WORK/hosted.out" "$WORK/run.out"; then
  echo 'FAIL: stage1 run differs'; cat "$WORK/run.out" "$WORK/run.err"; exit 1
fi
fi

# A build error in the mutated compiler is invalid. A catch requires that it
# builds, then rejects the exact process spawn previously shown to compile.
check_cast_mutation() {
  if ! run_monitored "$IYI" build -o "$WORK/mutant-typed$EXE" "$REPO/src/compiler/tools/compile_native.iyi" > "$WORK/mutant.build" 2>&1; then
    echo 'INVALID: mutant typed compiler did not build'; cat "$WORK/mutant.build"; return 2
  fi
  local rc=0 site
  run_monitored "$WORK/mutant-typed$EXE" "$probe" -o "$WORK/mutant-probe.ir" --pipeline typed --prelude --emit ir \
    >"$WORK/mutant.out" 2>"$WORK/mutant.err" || rc=$?
  site="$(grep -n 'g\.spawn.*\.as(String | Cancelled)' "$REPO/src/std/process.iyi" | cut -d: -f1)"
  if [ -n "$site" ] &&
     expected_refusal "$rc" "$WORK/mutant.err" src/compiler/lower/pending.iyi "^lower: visit\\(spawn classification of .*std/process\\.iyi:${site}:[0-9]+ is not ported \\(hosted cleanup_transformer\\.cr classify_spawn\\)\\) \\(hosted codegen\\.cr\\) is not ported yet$"; then
    echo 'decisive: mutant compiler refused the exact cast spawn'
    return 1
  fi
  if [ "$rc" -eq 0 ] && [ -s "$WORK/mutant-probe.ir" ]; then return 0; fi
  echo 'INVALID: cast mutant did not produce the expected refusal'; cat "$WORK/mutant.out" "$WORK/mutant.err"
  return 2
}
prove_mutation 'cast operand is not traversed' "$REPO/src/compiler/semantic/spawn_placement.iyi" \
  '    elsif node.is_a?(Cast)
      walk(node.as(Cast).obj)' '    elsif node.is_a?(Cast)
      nil' -- check_cast_mutation || exit 1

# The allocation of Child must call Count.tick for its ancestor default.
# The native Darwin probe additionally holds the original process behavior.
check_initializer_mutation() {
  local baseline_calls mutant_calls
  baseline_calls="$(grep -Ec 'call .*Count::tick' "$WORK/early.ir" || true)"
  if [ "$baseline_calls" -eq 0 ]; then
    echo 'INVALID: baseline IR has no Count.tick initializer call'; return 2
  fi
  if ! run_monitored "$IYI" build -o "$WORK/ivar-mutant-typed$EXE" "$REPO/src/compiler/tools/compile_native.iyi" >"$WORK/ivar-mutant.build" 2>&1; then
    echo 'INVALID: initializer mutant compiler did not build'; cat "$WORK/ivar-mutant.build"; return 2
  fi
  if ! run_monitored "$WORK/ivar-mutant-typed$EXE" "$REPO/bench/fixtures/ivar_initializer_early.iyi" \
       -o "$WORK/ivar-mutant.ir" --pipeline typed --prelude --emit ir >"$WORK/ivar-mutant-ir.log" 2>&1 ||
     [ ! -s "$WORK/ivar-mutant.ir" ]; then
    echo 'INVALID: initializer mutant did not emit verified IR'; cat "$WORK/ivar-mutant-ir.log"; return 2
  fi
  mutant_calls="$(grep -Ec 'call .*Count::tick' "$WORK/ivar-mutant.ir" || true)"
  if [ "$mutant_calls" -ne 0 ]; then
    echo "initializer calls remain: $mutant_calls"; return 0
  fi
  if [ "$HOST_ID" = darwin-arm64 ]; then
    if ! run_monitored "$IYI" build -o "$WORK/ivar-mutant-stage1$EXE" "$REPO/src/compiler/stage1.iyi" >"$WORK/ivar-mutant-stage1.build" 2>&1; then
      echo 'INVALID: initializer mutant stage1 did not build'; cat "$WORK/ivar-mutant-stage1.build"; return 2
    fi
    if ! run_monitored "$WORK/ivar-mutant-stage1$EXE" build -o "$WORK/ivar-mutant-probe" "$probe" >"$WORK/ivar-mutant-probe.build" 2>&1 ||
       ! codesign -v --strict "$WORK/ivar-mutant-probe"; then
      echo 'INVALID: initializer mutant probe did not build and sign'; cat "$WORK/ivar-mutant-probe.build"; return 2
    fi
    local rc=0
    run_timed 120 "$WORK/ivar-mutant-probe" >"$WORK/ivar-mutant.out" 2>"$WORK/ivar-mutant.err" || rc=$?
    if [ "$rc" -ne 1 ] || ! grep -F 'cat did not echo its input' "$WORK/ivar-mutant.out" "$WORK/ivar-mutant.err" >/dev/null; then
      echo 'INVALID: initializer mutant did not produce the expected descriptor failure'
      cat "$WORK/ivar-mutant.out" "$WORK/ivar-mutant.err"; return 2
    fi
  fi
  echo 'decisive: verified mutant IR lost the Count.tick initializer call'
  return 1
}
prove_mutation 'instance defaults execute at allocation' "$REPO/src/compiler/lower/primitives.iyi" \
  '    entries.as(Array(InstanceVarInitializer)).each do |init|' \
  '    ([] of InstanceVarInitializer).each do |init|' -- check_initializer_mutation || exit 1
printf '%s\n' 'hosted and typed process checks completed; native execution checked on Darwin arm64'
