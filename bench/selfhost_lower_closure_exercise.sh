#!/usr/bin/env bash
# Compare closure behavior through hosted and typed native compilation.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")" || exit 1
cd "$REPO" || exit 1
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")" || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/lower_oracle.sh"
export IYI_PATH="$REPO_NATIVE/src"

run_fixture() {
  [ -n "$PY" ] || { echo 'INVALID: Python is required to distinguish exits from signals'; return 2; }
  "$PY" - "$(native_path "$1")" "$(native_path "$2")" "$(native_path "$3")" <<'PY'
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

build_compiler() {
  "$IYI" build -o "$WORK_NATIVE/stage1$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/build.log" 2>&1
}
emit_fixture_ir() {
  local fixture="$1" output="$2"
  if ! "$WORK/stage1$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" -o "$(native_path "$output")" --pipeline typed --prelude --emit ir > "$WORK/emit.log" 2>&1; then
    echo "INVALID: $fixture did not emit typed IR"
    cat "$WORK/emit.log"
    return 2
  fi
  [ -s "$output" ] || { echo "INVALID: $fixture emitted empty IR"; return 2; }
}
check_fixture() {
  local fixture="$1"
  emit_fixture_ir "$fixture" "$WORK/$fixture.port.ir" || return 2
  if ! "$WORK/stage1$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" -o "$WORK_NATIVE/native" --pipeline typed --prelude > "$WORK/native.log" 2>&1; then
    echo "INVALID: $fixture did not link"
    cat "$WORK/native.log"
    return 2
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then return 0; fi
  codesign -v --strict "$WORK/native" || return 2
  run_fixture "$WORK/native" "$WORK/native.out" "$WORK/native.status" || return 2
  local result
  result="$(< "$WORK/native.status")"
  [ "$result" -eq 0 ] && cmp -s "$WORK/host-$fixture.out" "$WORK/native.out"
}
check_mutant() {
  local fixture="$1"
  if ! build_compiler; then
    echo 'INVALID: mutated compiler failed to build'
    cat "$WORK/build.log"
    return 2
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then
    emit_fixture_ir "$fixture" "$WORK/$fixture.mutant.ir" || return 2
    if ! "$WORK/stage1$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" -o "$WORK_NATIVE/native-mutant" --pipeline typed --prelude > "$WORK/native-mutant.log" 2>&1; then
      echo "INVALID: $fixture mutant did not emit Mach-O"
      cat "$WORK/native-mutant.log"
      return 2
    fi
    cmp -s "$WORK/$fixture.port.ir" "$WORK/$fixture.mutant.ir"
  else
    check_fixture "$fixture"
  fi
}

check_pointerof_mutant() {
  local result=0
  check_mutant lower_pointerof_arg || result=$?
  if [ "$result" -eq 0 ]; then return 0; fi
  if [ "$result" -eq 1 ] && [ "$HOST_ID" != darwin-arm64 ]; then return 1; fi
  if [ "$result" -eq 1 ] && [ -f "$WORK/native.status" ] && [ "$(< "$WORK/native.status")" = 221 ]; then
    echo 'decisive: pointerof wrote a copy; fixture exited 221 instead of 0'
    return 1
  fi
  echo 'INVALID: pointerof mutant did not produce the expected normal exit'
  return 2
}

check_specific_refusal() {
  local fixture="$1" site="$2" message="$3" result=0
  if [ ! -s "$WORK/$fixture.port.ir" ]; then
    echo "INVALID: $fixture has no passing baseline IR"
    return 2
  fi
  if ! build_compiler; then
    echo 'INVALID: mutated compiler failed to build'
    cat "$WORK/build.log"
    return 2
  fi
  "$WORK/stage1$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" -o "$WORK_NATIVE/$fixture.refusal.ir" --pipeline typed --prelude --emit ir > "$WORK/$fixture.refusal.out" 2>"$WORK/$fixture.refusal.err" || result=$?
  if [ "$result" -eq 0 ]; then return 0; fi
  if expected_refusal "$result" "$WORK/$fixture.refusal.err" "$site" "$message"; then
    echo "decisive: $fixture: $(refusal_note "$result" "$WORK/$fixture.refusal.err")"
    return 1
  fi
  echo "INVALID: $fixture failed outside its expected refusal"
  cat "$WORK/$fixture.refusal.out" "$WORK/$fixture.refusal.err"
  return 2
}

# Self mutants must build both the compiler and a runnable native fixture.
check_self_behavior_mutant() {
  local fixture="$1" result
  if ! build_compiler; then
    echo 'INVALID: self mutant compiler failed to build'
    cat "$WORK/build.log"
    return 2
  fi
  if ! "$WORK/stage1$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" -o "$WORK_NATIVE/native-mutant" --pipeline typed --prelude > "$WORK/native-mutant.log" 2>&1; then
    echo 'INVALID: self mutant did not emit Mach-O'
    cat "$WORK/native-mutant.log"
    return 2
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then
    emit_fixture_ir "$fixture" "$WORK/$fixture.mutant.ir" || return 2
    cmp -s "$WORK/$fixture.port.ir" "$WORK/$fixture.mutant.ir"
    return $?
  fi
  if ! codesign -v --strict "$WORK/native-mutant"; then
    echo 'INVALID: self mutant fixture failed to build and sign'
    cat "$WORK/native-mutant.log"
    return 2
  fi
  "$WORK/native-mutant" > "$WORK/native-mutant.out" 2>&1
  result=$?
  [ "$result" -eq 0 ] && cmp -s "$WORK/host-$fixture.out" "$WORK/native-mutant.out"
}

check_refusal() {
  local fixture="$1" message="$2" result phase=lower
  [ "$fixture" = noreturn_dead_instance_refuse ] && phase=bodies
  rm -f "$WORK/refused"
  "$WORK/stage1$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" -o "$WORK_NATIVE/refused" --pipeline typed --prelude --probe-phase --emit ir > "$WORK/refused.log" 2>&1
  result=$?
  if [ "$result" -eq 1 ] && [ ! -e "$WORK/refused" ] && grep -Fxq "$phase: fail: $message" "$WORK/refused.log"; then
    if [ "$phase" = bodies ] && ! tr '\\' '/' < "$WORK/refused.log" | grep -Eq 'bodies: refused at .*noreturn_dead_instance_refuse\.iyi:3:[0-9]+'; then
      echo 'INVALID: semantic refusal did not name the expected source site'
      cat "$WORK/refused.log"
      return 2
    fi
    return 0
  fi
  if [ "$result" -eq 0 ] && [ -s "$WORK/refused" ]; then return 1; fi
  echo "INVALID: $fixture did not reach the expected refusal"
  cat "$WORK/refused.log"
  return 2
}

check_refusal_mutant() {
  if ! build_compiler; then
    echo 'INVALID: refusal mutant compiler failed to build'
    cat "$WORK/build.log"
    return 2
  fi
  check_refusal "$1" "$2"
}

# An unsupported primitive must be refused. The mutant is caught only if it
# produces an executable, rather than failing to compile for another reason.
check_primitive_refusal_mutant() {
  if ! build_compiler; then
    echo 'INVALID: primitive mutant compiler failed to build'
    cat "$WORK/build.log"
    return 2
  fi
  rm -f "$WORK/primitive-mutant"
  if ! "$WORK/stage1$EXE" "$REPO_NATIVE/bench/fixtures/closure_self_refuse_primitive.iyi" -o "$WORK_NATIVE/primitive-mutant" --pipeline typed --prelude --emit ir > "$WORK/primitive-mutant.log" 2>&1; then
    echo 'INVALID: primitive mutant did not emit IR'
    cat "$WORK/primitive-mutant.log"
    return 2
  fi
  [ -s "$WORK/primitive-mutant" ] || { echo 'INVALID: primitive mutant emitted no IR'; return 2; }
  if ! "$WORK/stage1$EXE" "$REPO_NATIVE/bench/fixtures/closure_self_refuse_primitive.iyi" -o "$WORK_NATIVE/primitive-native" --pipeline typed --prelude > "$WORK/primitive-native.log" 2>&1; then
    echo 'INVALID: primitive mutant did not emit Mach-O'
    cat "$WORK/primitive-native.log"
    return 2
  fi
  if [ "$HOST_ID" = darwin-arm64 ]; then
    if ! codesign -v --strict "$WORK/primitive-native"; then
      echo 'INVALID: primitive mutant failed signature verification'
      return 2
    fi
    "$WORK/primitive-native" > "$WORK/primitive-mutant.out" 2>&1 || {
      echo 'INVALID: primitive mutant did not execute'
      cat "$WORK/primitive-mutant.out"
      return 2
    }
  fi
  return 1
}

# Check the whole IR module as well as runtime values: allocation kind and the
# null-context ABI are observable even when the immediate result is unchanged.
check_self_ir() {
  local fixture="$1" expected="$2"
  "$IYI" build --prelude empty --emit llvm-ir --no-debug -o "$WORK_NATIVE/$fixture$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" > "$WORK/$fixture.ir.log" 2>&1 || return 1
  awk "$CALL_TYPES" "$WORK/$fixture.ll" > "$WORK/$fixture.normalized.ll"
  "$WORK/core$EXE" lower "$REPO_NATIVE/bench/fixtures/$fixture.iyi" "$WORK_NATIVE/$fixture.normalized.ll" > "$WORK/$fixture.ir.out" 2>&1 || return 1
  grep -qx "SUMMARY identical=$expected total=$expected module=1" "$WORK/$fixture.ir.out" || return 1
  echo "$fixture: SUMMARY identical=$expected total=$expected module=1"
}

check_self_ir_mutant() {
  local fixture="$1" expected="$2"
  if ! build_compiler; then
    echo 'INVALID: IR mutant compiler failed to build'
    cat "$WORK/build.log"
    return 2
  fi
  emit_fixture_ir "$fixture" "$WORK/ir-native-mutant.ir" || return 2
  if ! "$WORK/stage1$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" -o "$WORK_NATIVE/ir-native-mutant" --pipeline typed --prelude > "$WORK/ir-native-mutant.log" 2>&1; then
    echo 'INVALID: IR mutant fixture did not emit Mach-O'
    cat "$WORK/ir-native-mutant.log"
    return 2
  fi
  if [ "$HOST_ID" = darwin-arm64 ] && ! codesign -v --strict "$WORK/ir-native-mutant"; then
    echo 'INVALID: IR mutant fixture failed signature verification'
    return 2
  fi
  if ! "$IYI" build -o "$WORK_NATIVE/core-mutant$EXE" "$REPO_NATIVE/bench/selfhost_lower_core_exercise.iyi" > "$WORK/core-mutant.log" 2>&1; then
    echo 'INVALID: IR mutant driver failed to build'
    cat "$WORK/core-mutant.log"
    return 2
  fi
  if ! "$WORK/core-mutant$EXE" lower "$REPO_NATIVE/bench/fixtures/$fixture.iyi" "$WORK_NATIVE/$fixture.normalized.ll" > "$WORK/$fixture.mutant.out" 2>&1; then
    echo 'INVALID: IR mutant did not lower the fixture'
    cat "$WORK/$fixture.mutant.out"
    return 2
  fi
  if ! grep -q '^SUMMARY identical=[0-9][0-9]* total=[0-9][0-9]* module=[01]$' "$WORK/$fixture.mutant.out"; then
    echo 'INVALID: IR mutant did not report a comparison'
    return 2
  fi
  grep -qx "SUMMARY identical=$expected total=$expected module=1" "$WORK/$fixture.mutant.out"
}

check_macro_ir() {
  local fixture=lower_macro_proc_locations
  "$IYI" build -o "$WORK_NATIVE/core$EXE" "$REPO_NATIVE/bench/selfhost_lower_core_exercise.iyi" > "$WORK/core.log" 2>&1 || return 1
  "$IYI" build --prelude empty --emit llvm-ir --no-debug -o "$WORK_NATIVE/macro$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" > "$WORK/macro.log" 2>&1 || return 1
  awk "$CALL_TYPES" "$WORK/macro.ll" > "$WORK/macro.normalized.ll"
  "$WORK/core$EXE" lower "$REPO_NATIVE/bench/fixtures/$fixture.iyi" "$WORK_NATIVE/macro.normalized.ll" > "$WORK/macro.out" 2>&1 || return 1
  grep -qx 'SUMMARY identical=6 total=6 module=1' "$WORK/macro.out"
}

check_macro_mutant() {
  if ! "$IYI" build -o "$WORK_NATIVE/core-mutant$EXE" "$REPO_NATIVE/bench/selfhost_lower_core_exercise.iyi" > "$WORK/core-mutant.log" 2>&1; then
    echo 'INVALID: macro mutant driver failed to build'
    cat "$WORK/core-mutant.log"
    return 2
  fi
  if ! "$WORK/core-mutant$EXE" lower "$REPO_NATIVE/bench/fixtures/lower_macro_proc_locations.iyi" "$WORK_NATIVE/macro.normalized.ll" > "$WORK/macro-mutant.out" 2>&1; then
    echo 'INVALID: macro mutant could not lower fixture'
    cat "$WORK/macro-mutant.out"
    return 2
  fi
  grep -Eq '^SUMMARY identical=[0-9]+ total=[0-9]+ module=[01]$' "$WORK/macro-mutant.out" || { echo 'INVALID: macro mutant produced no summary'; return 2; }
  grep -qx 'SUMMARY identical=6 total=6 module=1' "$WORK/macro-mutant.out"
}

check_defer_mutant() {
  if ! "$IYI" build -o "$WORK_NATIVE/core-mutant$EXE" "$REPO_NATIVE/bench/selfhost_lower_core_exercise.iyi" > "$WORK/core-mutant.log" 2>&1; then
    echo 'INVALID: defer mutant driver failed to build'
    cat "$WORK/core-mutant.log"
    return 2
  fi
  if ! "$WORK/core-mutant$EXE" lower "$REPO_NATIVE/bench/fixtures/lower_defer_closure.iyi" "$WORK_NATIVE/defer.normalized.ll" > "$WORK/defer-mutant.out" 2>&1; then
    echo 'INVALID: defer mutant could not lower fixture'
    cat "$WORK/defer-mutant.out"
    return 2
  fi
  grep -Eq '^SUMMARY identical=[0-9]+ total=[0-9]+ module=[01]$' "$WORK/defer-mutant.out" || { echo 'INVALID: defer mutant produced no summary'; return 2; }
  grep -qx 'SUMMARY identical=7 total=7 module=1' "$WORK/defer-mutant.out"
}


check_mark() {
  local fixture="$1"
  emit_fixture_ir "$fixture" "$WORK/$fixture.port.ir" || return 2
  "$WORK/stage1$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" -o "$WORK_NATIVE/mark" --pipeline typed --prelude > "$WORK/mark.build.log" 2>&1 || { cat "$WORK/mark.build.log"; return 2; }
  if [ "$HOST_ID" != darwin-arm64 ]; then return 0; fi
  codesign -v --strict "$WORK/mark" || return 1
  "$WORK/mark" > "$WORK/mark.out" 2>&1 || return 1
  grep -qx 'MARKING WHITE SHADED 42' "$WORK/mark.out"
}

# A missing or expired mark is invalid, not proof that a barrier mutation
# was caught. Only the explicitly observed white-but-unshaded state counts.
check_barrier_mutant() {
  local fixture result baseline_count mutant_count
  if ! build_compiler; then
    echo 'INVALID: barrier mutant compiler failed to build'
    cat "$WORK/build.log"
    return 2
  fi
  for fixture in closure_gc_marking closure_gc_marking_self; do
    if [ "$HOST_ID" != darwin-arm64 ]; then
      emit_fixture_ir "$fixture" "$WORK/$fixture.mutant.ir" || return 2
      if ! "$WORK/stage1$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" -o "$WORK_NATIVE/mark" --pipeline typed --prelude > "$WORK/mark.build.log" 2>&1; then
        echo "INVALID: barrier mutant $fixture did not emit Mach-O"
        cat "$WORK/mark.build.log"
        return 2
      fi
      baseline_count="$(awk '/call .*@__iyi_write_barrier\(/ { n++ } END { print n+0 }' "$WORK/$fixture.port.ir")"
      mutant_count="$(awk '/call .*@__iyi_write_barrier\(/ { n++ } END { print n+0 }' "$WORK/$fixture.mutant.ir")"
      if [ "$baseline_count" -eq 0 ]; then
        echo "INVALID: $fixture baseline has no write-barrier call"
        return 2
      fi
      if [ "$mutant_count" -ge "$baseline_count" ]; then return 0; fi
      echo "  $fixture: mutant removed write-barrier calls ($baseline_count to $mutant_count)"
      continue
    fi
    if ! "$WORK/stage1$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" -o "$WORK_NATIVE/mark" --pipeline typed --prelude > "$WORK/mark.build.log" 2>&1 ||
       ! codesign -v --strict "$WORK/mark"; then
      echo "INVALID: barrier mutant $fixture did not build and sign"
      cat "$WORK/mark.build.log"
      return 2
    fi
    "$WORK/mark" > "$WORK/mark.out" 2>&1
    result=$?
    if [ "$result" -ne 1 ] || ! grep -qx 'MARKING WHITE UNSHADED' "$WORK/mark.out"; then
      echo "INVALID: barrier mutant $fixture was not observed white and unshaded"
      cat "$WORK/mark.out"
      return 2
    fi
    echo "  $fixture: mutant left the active-mark target white"
  done
  return 1
}


build_compiler || { cat "$WORK/build.log"; exit 1; }
status=0
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "closure: AArch64 Mach-O codesign, runtime output, GC marking and panic cleanup execution require macOS arm64; typed IR and Mach-O emission run on $HOST_ID"
fi
for fixture in lower_closure_top_level lower_closure_nested_block lower_proc_yielded_blocks lowcall_recursive_named_mixed_inferred lowcall_noreturn_operand lower_pointerof_arg lower_pointerof_proc_arg lower_macro_closure lower_macro_proc_locations lower_closure_self_class lower_closure_self_struct lower_closure_self_nested lower_closure_self_unit_call closure_forward_recursion; do
  host_flags=(--prelude empty)
  [ "$fixture" = lower_proc_yielded_blocks ] && host_flags=()
  "$IYI" build "${host_flags[@]}" -o "$WORK_NATIVE/host$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" > "$WORK/host.build.log" 2>&1 || { cat "$WORK/host.build.log"; exit 1; }
  "$WORK/host$EXE" > "$WORK/host.out" 2>&1 || exit 1
  cp "$WORK/host.out" "$WORK/host-$fixture.out"
  if check_fixture "$fixture"; then
    if [ "$HOST_ID" = darwin-arm64 ]; then
      echo "$fixture: hosted and signed native exit 0 with identical output"
    else
      echo "$fixture: hosted exit 0 and typed AArch64 IR emitted"
    fi
  else
    [ ! -f "$WORK/native.log" ] || cat "$WORK/native.log"
    exit 1
  fi
done
check_macro_ir || { cat "$WORK/macro.out"; exit 1; }
check_self_ir closure_self_class_ir 10 || { cat "$WORK/closure_self_class_ir.ir.out" "$WORK/closure_self_class_ir.ir.log"; exit 1; }
check_self_ir closure_self_unit_ir 10 || { cat "$WORK/closure_self_unit_ir.ir.out" "$WORK/closure_self_unit_ir.ir.log"; exit 1; }
"$IYI" build --prelude empty --emit llvm-ir --no-debug -o "$WORK_NATIVE/defer$EXE" "$REPO_NATIVE/bench/fixtures/lower_defer_closure.iyi" > "$WORK/defer.log" 2>&1 || { cat "$WORK/defer.log"; exit 1; }
awk "$CALL_TYPES" "$WORK/defer.ll" > "$WORK/defer.normalized.ll"
"$WORK/core$EXE" lower "$REPO_NATIVE/bench/fixtures/lower_defer_closure.iyi" "$WORK_NATIVE/defer.normalized.ll" > "$WORK/defer.out" 2>&1 || { cat "$WORK/defer.out"; exit 1; }
grep -qx 'SUMMARY identical=7 total=7 module=1' "$WORK/defer.out" || { cat "$WORK/defer.out"; exit 1; }
for fixture in closure_gc_marking closure_gc_marking_self; do
  "$IYI" build -o "$WORK_NATIVE/mark-host$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" > "$WORK/mark.host.log" 2>&1 || { cat "$WORK/mark.host.log"; exit 1; }
  "$WORK/mark-host$EXE" > "$WORK/mark.host.out" 2>&1 || { cat "$WORK/mark.host.out"; exit 1; }
  grep -qx 'MARKING WHITE SHADED 42' "$WORK/mark.host.out" || exit 1
  check_mark "$fixture" || { [ ! -f "$WORK/mark.build.log" ] || cat "$WORK/mark.build.log"; exit 1; }
  if [ "$HOST_ID" = darwin-arm64 ]; then
    echo "$fixture: hosted and native MARKING WHITE SHADED 42"
  else
    echo "$fixture: hosted MARKING WHITE SHADED 42 and typed AArch64 IR emitted"
  fi
done
"$IYI" build -o "$WORK_NATIVE/panic-host$EXE" "$REPO_NATIVE/bench/fixtures/proc_defer_panic.iyi" > "$WORK/panic.host.log" 2>&1 || { cat "$WORK/panic.host.log"; exit 1; }
"$WORK/panic-host$EXE" > "$WORK/panic.host.out" 2>/dev/null || exit 1
emit_fixture_ir proc_defer_panic "$WORK/panic.ir" || exit 1
"$WORK/stage1$EXE" "$REPO_NATIVE/bench/fixtures/proc_defer_panic.iyi" -o "$WORK_NATIVE/panic-native" --pipeline typed --prelude > "$WORK/panic.native.log" 2>&1 || { cat "$WORK/panic.native.log"; exit 1; }
if [ "$HOST_ID" = darwin-arm64 ]; then
  codesign -v --strict "$WORK/panic-native" || exit 1
  "$WORK/panic-native" > "$WORK/panic.native.out" 2>/dev/null || exit 1
  cmp -s "$WORK/panic.host.out" "$WORK/panic.native.out" || exit 1
  echo 'proc_defer_panic: registered cleanup exits 0 with identical output'
else
  echo 'proc_defer_panic: hosted cleanup exits 0 and typed AArch64 IR emitted'
fi
check_refusal closure_self_refuse_primitive 'closure over self of Int32: only a class or a struct passed by pointer is ported (hosted malloc_closure, codegen.cr:2661-2668)' || { cat "$WORK/refused.log"; exit 1; }
check_refusal closure_self_refuse_nested 'proc literal: a nested proc, def or class inside a proc literal (hosted closure)' || { cat "$WORK/refused.log"; exit 1; }
check_refusal closure_refuse_nested_in_defer 'proc literal: a nested proc, def or class inside a proc literal (hosted closure)' || { cat "$WORK/refused.log"; exit 1; }
check_refusal noreturn_dead_instance_refuse "undefined method 'missing_method' for Int32" || { cat "$WORK/refused.log"; exit 1; }
echo 'unsupported primitive self and nested proc: refused without an output binary'
prove_mutation 'program closure facts omitted' "$REPO/src/compiler/lower/lower.iyi" \
  'low.current_context.closure_facts = facts' 'low.current_context.closure_facts = nil' -- check_mutant lower_closure_top_level || status=1
prove_mutation 'yielded block loses closure context' "$REPO/src/compiler/lower/block.iyi" \
  'body.copy_closure_from(caller)' 'nil' -- check_specific_refusal lower_closure_nested_block src/compiler/lower/pending.iyi '^proc literal reads outer, a local of the enclosing code without closure facts$' || status=1
prove_mutation 'forwarded closure loses its captured environment' "$REPO/src/compiler/lower/proc.iyi" \
  '  ctx = closure ? source.closure_ptr.as(Value) : low.builder.const_null(low.module.types.ptr(0)).as(Value)' \
  '  ctx = low.builder.const_null(low.module.types.ptr(0)).as(Value)' -- check_self_behavior_mutant closure_forward_recursion || status=1
prove_mutation 'macro proc loses call-site location' "$REPO/src/compiler/lower/proc.iyi" \
  'place = low.current_context.macro_origin || node.location' 'place = node.location' -- check_macro_mutant || status=1
prove_mutation 'address-taken parameter points to a temporary copy' "$REPO/src/compiler/lower/lower.iyi" \
  '      low.last = var.as(LowerVar).pointer' \
  '      low.last = var.as(LowerVar).pointer
      if low.current_context.fun.name == "*mutate<Int32>:Int32" && exp.as(Var).name == "value"
        copy_type = low.typer.llvm_type(var.as(LowerVar).type)
        copy = low.alloca(copy_type, "")
        store_aligned(low, load_aligned(low, copy_type, var.as(LowerVar).pointer), copy)
        low.last = copy
      end' -- check_pointerof_mutant || status=1
prove_mutation 'defer drops its personality' "$REPO/src/compiler/lower/ensure.iyi" \
  'low.current_context.fun.personality = personality' 'nil' -- check_defer_mutant || status=1
prove_mutation 'Darwin personality is internal' "$REPO/src/compiler/lower/lower.iyi" \
  '(low.module.target.darwin? && name == abi_name(low, "personality"))' 'false' -- check_defer_mutant || status=1
prove_mutation 'captured reference store lacks marking barrier' "$REPO/src/compiler/lower/cast.iyi" \
  'if low.analysed.program.types["IyiHeap"]?.nil? || !has_inner_pointers?(target) || stack_pointer?(pointer) || begin_fn.nil? || shade_fn.nil?' \
  'if true || low.analysed.program.types["IyiHeap"]?.nil? || !has_inner_pointers?(target) || stack_pointer?(pointer) || begin_fn.nil? || shade_fn.nil?' -- check_barrier_mutant || status=1
prove_mutation 'captured self is not stored' "$REPO/src/compiler/lower/closure.iyi" \
  'assign(low, slot, st, self_var.type, self_var.pointer)' 'nil' -- check_self_behavior_mutant lower_closure_self_class || status=1
prove_mutation 'captured struct self is not copied' "$REPO/src/compiler/lower/closure.iyi" \
  'assign(low, slot, st, self_var.type, self_var.pointer)' \
  'assign(low, slot, st, self_var.type, self_by_pointer?(st) ? low.builder.const_zero(low.typer.llvm_type(st)) : self_var.pointer)' -- check_self_behavior_mutant lower_closure_self_struct || status=1
prove_mutation 'captured self is recovered from the wrong field' "$REPO/src/compiler/lower/closure.iyi" \
  'self_index = source.closure_names.size' 'self_index = 0' -- check_self_behavior_mutant lower_closure_self_class || status=1
prove_mutation 'pointerful self uses atomic allocation' "$REPO/src/compiler/lower/closure.iyi" \
  'pointerful = true if has_inner_pointers?(st)' 'nil' -- check_self_ir_mutant closure_self_class_ir 10 || status=1
prove_mutation 'capture-free proc receives a context' "$REPO/src/compiler/lower/proc.iyi" \
  'closure = !frame.nil? && frame.closure' 'closure = !frame.nil? && (frame.closure || (node.def.args.empty? && !source.closure_ptr.nil? && !closure_self_type(source).nil?))' -- check_self_ir_mutant closure_self_class_ir 10 || status=1
prove_mutation 'unit call incorrectly captures self' "$REPO/src/compiler/semantic/closures.iyi" \
  'return false if owner.is_a?(ModuleType) && owner.as(ModuleType).iyi_unit' 'nil' -- check_self_ir_mutant closure_self_unit_ir 10 || status=1
prove_mutation 'primitive self is not refused' "$REPO/src/compiler/lower/closure.iyi" \
  'refuse_port("closure over self of #{st.full_name}: only a class or a struct passed by pointer is ported (hosted malloc_closure, codegen.cr:2661-2668)")' \
  'return st' -- check_primitive_refusal_mutant || status=1
prove_mutation 'typing-stack recursion answers NoReturn' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  'return frame.estimating ? frame.estimate : nil' 'return @program.no_return_type' -- check_mutant lowcall_recursive_named_mixed_inferred || status=1
prove_mutation 'abandoned instance keeps its provisional NoReturn' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '@def_instances.delete(abandoned)' 'nil' -- check_refusal_mutant noreturn_dead_instance_refuse "undefined method 'missing_method' for Int32" || status=1
prove_mutation 'call on a NoReturn receiver is looked up' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  'return true if !node.obj.nil? && rec_type.is_a?(NoReturnType)' 'nil' -- check_specific_refusal lowcall_noreturn_operand src/compiler/semantic/main_visitor.iyi "^undefined method '&\\+' for NoReturn$" || status=1
prove_mutation 'never-made call lowered as a call' "$REPO/src/compiler/lower/call.iyi" \
  '    lower_never_made_call(low, node)' '    nil' -- check_mutant lowcall_noreturn_operand || status=1
exit "$status"
