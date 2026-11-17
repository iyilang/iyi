#!/usr/bin/env bash
# Exercise Process.run through hosted and native stage-one entry paths.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
export IYI_PATH="$REPO/src"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"
fixture="$REPO/bench/fixtures/native_process_run.iyi"
probe="$REPO/bench/fixtures/spawnshare_process.iyi"

run_monitored() {
  if [ -n "${IYI_MEMORY_MONITOR:-}" ]; then
    "$IYI_MEMORY_MONITOR" "$@"
  else
    "$@"
  fi
}

run_timed() {
  python3 - "$@" <<'PY'
import os, signal, subprocess, sys
seconds = int(sys.argv[1])
proc = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    status = proc.wait(timeout=seconds)
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
    print('FAIL: process timed out', file=sys.stderr)
    sys.exit(124)
sys.exit(status if status >= 0 else 128 - status)
PY
}

if ! run_monitored "$IYI" build -o "$WORK/hosted" "$fixture" > "$WORK/hosted.build" 2>&1; then
  echo 'FAIL: hosted process fixture did not build'; cat "$WORK/hosted.build"; exit 1
fi
if ! run_timed 120 "$WORK/hosted" > "$WORK/hosted.out" 2> "$WORK/hosted.err"; then
  echo 'FAIL: hosted process fixture'; cat "$WORK/hosted.out" "$WORK/hosted.err"; exit 1
fi
if ! run_monitored "$IYI" build -o "$WORK/stage1" "$REPO/src/compiler/stage1.iyi" > "$WORK/stage1.build" 2>&1; then
  echo 'FAIL: stage1 did not build'; cat "$WORK/stage1.build"; exit 1
fi

# Hosted early generic ancestry runs the default once; its late path currently
# runs the same ancestor twice. The port deliberately runs both once.
for shape in early late; do
  once_fixture="$REPO/bench/fixtures/ivar_initializer_${shape}.iyi"
  if ! run_monitored "$IYI" build -o "$WORK/$shape-hosted" "$once_fixture" > "$WORK/$shape-hosted.build" 2>&1; then
    echo "FAIL: hosted $shape initializer fixture did not build"; cat "$WORK/$shape-hosted.build"; exit 1
  fi
  hosted_status=0
  run_timed 120 "$WORK/$shape-hosted" > "$WORK/$shape-hosted.out" 2> "$WORK/$shape-hosted.err" || hosted_status=$?
  if [ "$shape" = early ]; then
    if [ "$hosted_status" -ne 0 ] || [ "$(cat "$WORK/$shape-hosted.out")" != 'value=1,count=1' ]; then
      echo 'FAIL: hosted early initializer behavior changed'; cat "$WORK/$shape-hosted.out" "$WORK/$shape-hosted.err"; exit 1
    fi
  elif [ "$hosted_status" -eq 0 ] || [ "$(cat "$WORK/$shape-hosted.out")" != 'value=2,count=2' ]; then
    echo 'FAIL: hosted late initializer discrepancy changed'; cat "$WORK/$shape-hosted.out" "$WORK/$shape-hosted.err"; exit 1
  fi
  if ! run_monitored "$WORK/stage1" build -o "$WORK/$shape-native" "$once_fixture" > "$WORK/$shape-native.build" 2>&1 ||
     ! codesign -v --strict "$WORK/$shape-native"; then
    echo "FAIL: native $shape initializer fixture did not build and sign"; cat "$WORK/$shape-native.build"; exit 1
  fi
  if ! run_timed 120 "$WORK/$shape-native" > "$WORK/$shape-native.out" 2> "$WORK/$shape-native.err" ||
     [ "$(cat "$WORK/$shape-native.out")" != 'value=1,count=1' ]; then
    echo "FAIL: native $shape initializer did not run once"; cat "$WORK/$shape-native.out" "$WORK/$shape-native.err"; exit 1
  fi
  echo "  $shape generic ancestor: hosted $(cat "$WORK/$shape-hosted.out"), native $(cat "$WORK/$shape-native.out")"
done
for case_name in specializations generic_module; do
  case_fixture="$REPO/bench/fixtures/ivar_initializer_${case_name}.iyi"
  if ! run_monitored "$IYI" build -o "$WORK/$case_name-hosted" "$case_fixture" > "$WORK/$case_name-hosted.build" 2>&1; then
    echo "FAIL: hosted $case_name initializer did not build"; cat "$WORK/$case_name-hosted.build"; exit 1
  fi
  if ! run_timed 120 "$WORK/$case_name-hosted" > "$WORK/$case_name-hosted.out" 2> "$WORK/$case_name-hosted.err" ||
     [ "$(cat "$WORK/$case_name-hosted.out")" != 'first=7,second=13' ]; then
    echo "FAIL: hosted $case_name initializer"; cat "$WORK/$case_name-hosted.out" "$WORK/$case_name-hosted.err"; exit 1
  fi
  if ! run_monitored "$WORK/stage1" build -o "$WORK/$case_name-native" "$case_fixture" > "$WORK/$case_name-native.build" 2>&1 ||
     ! codesign -v --strict "$WORK/$case_name-native"; then
    echo "FAIL: native $case_name initializer did not build and sign"; cat "$WORK/$case_name-native.build"; exit 1
  fi
  if ! run_timed 120 "$WORK/$case_name-native" > "$WORK/$case_name-native.out" 2> "$WORK/$case_name-native.err" ||
     [ "$(cat "$WORK/$case_name-native.out")" != 'first=7,second=13' ]; then
    echo "FAIL: native $case_name initializer"; cat "$WORK/$case_name-native.out" "$WORK/$case_name-native.err"; exit 1
  fi
  echo "  $case_name initializers: first=7,second=13"
done

# A generic module's parameter shadows a same-named class parameter. Current
# hosted builds reject this valid case; accept a future hosted fix as well.
shadow="$REPO/bench/fixtures/ivar_initializer_module_shadow.iyi"
if run_monitored "$IYI" build -o "$WORK/shadow-hosted" "$shadow" > "$WORK/shadow-hosted.build" 2>&1; then
  if ! run_timed 120 "$WORK/shadow-hosted" > "$WORK/shadow-hosted.out" 2> "$WORK/shadow-hosted.err" ||
     [ "$(cat "$WORK/shadow-hosted.out")" != 'value=7' ]; then
    echo 'FAIL: hosted module shadow result'; cat "$WORK/shadow-hosted.out" "$WORK/shadow-hosted.err"; exit 1
  fi
elif ! grep -F 'must be First, not Second' "$WORK/shadow-hosted.build" >/dev/null; then
  echo 'FAIL: unexpected hosted module shadow refusal'; cat "$WORK/shadow-hosted.build"; exit 1
fi
if ! run_monitored "$WORK/stage1" build -o "$WORK/shadow-native" "$shadow" > "$WORK/shadow-native.build" 2>&1 ||
   ! codesign -v --strict "$WORK/shadow-native"; then
  echo 'FAIL: native module shadow fixture did not build and sign'; cat "$WORK/shadow-native.build"; exit 1
fi
if ! run_timed 120 "$WORK/shadow-native" > "$WORK/shadow-native.out" 2> "$WORK/shadow-native.err" ||
   [ "$(cat "$WORK/shadow-native.out")" != 'value=7' ]; then
  echo 'FAIL: native module shadow result'; cat "$WORK/shadow-native.out" "$WORK/shadow-native.err"; exit 1
fi
echo '  shadowed module type parameter: value=7'

invalid="$REPO/bench/fixtures/ivar_initializer_invalid.iyi"
if run_monitored "$IYI" build -o "$WORK/invalid-hosted" "$invalid" > "$WORK/invalid-hosted.build" 2>&1 ||
   ! grep -F "instance variable '@value' of Box(Int32) must be Int32" "$WORK/invalid-hosted.build" >/dev/null; then
  echo 'FAIL: hosted invalid generic initializer was not rejected'; cat "$WORK/invalid-hosted.build"; exit 1
fi
if run_monitored "$WORK/stage1" build -o "$WORK/invalid-native" "$invalid" > "$WORK/invalid-native.build" 2>&1 ||
   [ -e "$WORK/invalid-native" ] ||
   ! grep -F "instance variable '@value' of Box(Int32) must be Int32" "$WORK/invalid-native.build" >/dev/null; then
  echo 'FAIL: native invalid generic initializer was not rejected'; cat "$WORK/invalid-native.build"; exit 1
fi
echo '  incompatible generic initializer: rejected'

terminating="$REPO/bench/fixtures/ivar_initializer_noreturn_arena.iyi"
if ! run_monitored "$IYI" build -o "$WORK/terminating-hosted" "$terminating" > "$WORK/terminating-hosted.build" 2>&1; then
  echo 'FAIL: hosted terminating arena initializer did not build'; cat "$WORK/terminating-hosted.build"; exit 1
fi
if ! run_monitored "$WORK/stage1" build -o "$WORK/terminating-native" "$terminating" > "$WORK/terminating-native.build" 2>&1 ||
   ! codesign -v --strict "$WORK/terminating-native"; then
  echo 'FAIL: native terminating arena initializer did not build and sign'; cat "$WORK/terminating-native.build"; exit 1
fi
hosted_status=0
native_status=0
run_timed 120 "$WORK/terminating-hosted" > "$WORK/terminating-hosted.out" 2> "$WORK/terminating-hosted.err" || hosted_status=$?
run_timed 120 "$WORK/terminating-native" > "$WORK/terminating-native.out" 2> "$WORK/terminating-native.err" || native_status=$?
if [ "$hosted_status" -ne 7 ] || [ "$native_status" -ne 7 ] ||
   ! cmp "$WORK/terminating-hosted.out" "$WORK/terminating-native.out" ||
   ! cmp "$WORK/terminating-hosted.err" "$WORK/terminating-native.err"; then
  echo 'FAIL: terminating arena initializer did not exit 7'; cat "$WORK/terminating-native.out" "$WORK/terminating-native.err"; exit 1
fi
echo '  terminating arena initializer: hosted and native exit 7'


if ! run_monitored "$WORK/stage1" build -o "$WORK/probe" "$probe" > "$WORK/probe.build" 2>&1; then
  echo 'FAIL: native process probe did not build'; cat "$WORK/probe.build"; exit 1
fi
if ! codesign -v --strict "$WORK/probe"; then
  echo 'FAIL: native probe signature'; exit 1
fi
if ! run_timed 120 "$WORK/probe" > "$WORK/probe.out" 2> "$WORK/probe.err" ||
   [ "$(cat "$WORK/probe.out")" != 'process-ok:parent-ok' ]; then
  echo 'FAIL: native process probe'; cat "$WORK/probe.out" "$WORK/probe.err"; exit 1
fi
if ! run_monitored "$WORK/stage1" build -o "$WORK/native" "$fixture" > "$WORK/native.build" 2>&1; then
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
if ! run_monitored "$WORK/stage1" run "$fixture" > "$WORK/run.out" 2> "$WORK/run.err" ||
   ! cmp -s "$WORK/hosted.out" "$WORK/run.out"; then
  echo 'FAIL: stage1 run differs'; cat "$WORK/run.out" "$WORK/run.err"; exit 1
fi

# A build error in the mutated compiler is invalid. A catch requires that it
# builds, then rejects the exact process spawn previously shown to compile.
check_cast_mutation() {
  if ! run_monitored "$IYI" build -o "$WORK/mutant-stage1" "$REPO/src/compiler/stage1.iyi" > "$WORK/mutant.build" 2>&1; then
    echo 'INVALID: mutant stage1 did not build'; cat "$WORK/mutant.build"; return 0
  fi
  run_monitored "$WORK/mutant-stage1" build -o "$WORK/mutant-probe" "$probe" > "$WORK/mutant.log" 2>&1
  local rc=$?
  local site
  site="$(grep -n 'g\.spawn.*\.as(String | Cancelled)' "$REPO/src/std/process.iyi" | cut -d: -f1)"
  if [ "$rc" -ne 0 ] && [ -n "$site" ] &&
     grep -E "spawn classification of .*std/process\\.iyi:${site}:[0-9]+ is not ported" "$WORK/mutant.log" >/dev/null; then
    echo 'mutant stage1 compiled and refused the cast spawn'
    return 1
  fi
  echo 'INVALID: cast mutant did not produce the expected refusal'; cat "$WORK/mutant.log"
  return 0
}
prove_mutation 'cast operand is not traversed' "$REPO/src/compiler/semantic/spawn_placement.iyi" \
  '    elsif node.is_a?(Cast)
      walk(node.as(Cast).obj)' '' -- check_cast_mutation || exit 1

# The compiler must build and the compiled probe must exhibit the original
# descriptor failure. A mutant that cannot build is not a behavioral catch.
check_initializer_mutation() {
  if ! run_monitored "$IYI" build -o "$WORK/ivar-mutant-stage1" "$REPO/src/compiler/stage1.iyi" > "$WORK/ivar-mutant.build" 2>&1; then
    echo 'INVALID: initializer mutant stage1 did not build'; cat "$WORK/ivar-mutant.build"; return 0
  fi
  if ! run_monitored "$WORK/ivar-mutant-stage1" build -o "$WORK/ivar-mutant-probe" "$probe" > "$WORK/ivar-mutant-probe.build" 2>&1 ||
     ! codesign -v --strict "$WORK/ivar-mutant-probe"; then
    echo 'INVALID: initializer mutant probe did not build and sign'; cat "$WORK/ivar-mutant-probe.build"; return 0
  fi
  if run_timed 120 "$WORK/ivar-mutant-probe" > "$WORK/ivar-mutant.out" 2> "$WORK/ivar-mutant.err" &&
     [ "$(cat "$WORK/ivar-mutant.out")" = 'process-ok:parent-ok' ]; then
    return 0
  fi
  if grep -F 'cat did not echo its input' "$WORK/ivar-mutant.out" "$WORK/ivar-mutant.err" >/dev/null; then
    return 1
  fi
  echo 'INVALID: initializer mutant failed for a different reason'
  cat "$WORK/ivar-mutant.out" "$WORK/ivar-mutant.err"
  return 0
}
prove_mutation 'instance defaults execute at allocation' "$REPO/src/compiler/lower/primitives.iyi" \
  '    entries.as(Array(InstanceVarInitializer)).each do |init|' \
  '    ([] of InstanceVarInitializer).each do |init|' -- check_initializer_mutation || exit 1
printf '%s\n' 'native Process.run matches hosted, including cancellation; mutation caught'
