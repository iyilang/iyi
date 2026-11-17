#!/usr/bin/env bash
# Fails when the typed lowering of constants and class variables (src/compiler/lower/{const,
# class_var,once}.iyi) stops agreeing with the hosted code generator's module for the same
# fixture. Written in the pattern of bench/selfhost_lower_core_exercise.sh and the calls gate;
# CI runs every bench/selfhost_*_exercise.sh, so this gate is one of them.
# every mutation is caught, and a fixture that refuses is named below.
#
# For each fixture (bench/fixtures/lowglob_*.iyi) the hosted compiler builds the program against
# --prelude empty, with --emit llvm-ir and --no-debug. Its module is read through the port's IR
# text parser; the port analyses the fixture, lowers it, and prints the module. The two normalised
# texts are compared function by function (bench/lib/lower_gate.iyi, shared with the other lowering
# gates). The oracle's direct calls get their function type from bench/lib/lower_oracle.sh.
#
# A fixture the port refuses by name is WAITING only when it is named in WAITING_FIXTURES below;
# an unnamed refusal fails the gate, and a named one that starts to match fails it too.
#
# Each fixture the port lowers identically is built to a native executable and run: the exit status
# and stdout must equal the hosted executable's. The fixtures return the constant through LibC.exit,
# so a wrong constant changes the status.
#
# Mutation proofs patch the ported code, rebuild the driver, and require the check to fail. A patch
# that changes nothing is refused by prove_mutation.
#
#   bash bench/selfhost_lower_globals_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
IYI="$REPO/bin/iyi"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/lower_oracle.sh"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")" || exit 1

# The shared comparator (bench/lib/lower_gate.iyi) counts only the functions it reproduces: a module-level item (a global,
# a declaration) that differs is reported but not counted. This gate also requires the module-level items to match.
module_same() { awk '/module-level: identical/ { found = 1 } END { exit !found }' "$1"; }

trap 'rm -rf "$WORK"' EXIT

# The class-variable reads on a class receiver (K.v) pass now that the calls lane lowers class-receiver calls (S2c8Calls).
WAITING_FIXTURES="lowglob_cvar_tls"
# The body pass does not flag an untyped @[ThreadLocal] declaration.
#
# The hosted lazy fixture is also run on its own below, and its flag-check mutation is tested.
echo "  wait_lowglob_const_large_struct: WAITING, a value above 128 bytes travels through memory (hosted fun.cr 635-693): not ported"


echo "== 1. Building the port driver"
if ! "$IYI" build -o "$WORK_NATIVE/port$EXE" "$REPO_NATIVE/bench/selfhost_lower_globals_exercise.iyi" > "$WORK/port.build.log" 2>&1; then
  echo "  the driver does not build"
  awk 'NR<=5' "$WORK/port.build.log"
  exit 1
fi
if "$WORK/port$EXE" > "$WORK/usage.out" 2>&1; then
  echo "  driver built, bare run exits 0"
else
  echo "  the driver's bare run fails (see $WORK/usage.out)"
  exit 1
fi

# The shared oracle normalizer must add the function type for an indirect call,
# but must not guess the type of an aggregate argument.
oracle_call_checks() {
  awk "$CALL_TYPES" "$REPO/bench/fixtures/lowglob_indirect.ll" > "$WORK/indirect.ir"
  "$1" oracle "$WORK_NATIVE/indirect.ir" > "$WORK/indirect.out" 2>&1 || return 1
  awk "$CALL_TYPES" "$REPO/bench/fixtures/lowglob_indirect_aggregate.ll" > "$WORK/aggregate.ir"
  cmp -s "$REPO/bench/fixtures/lowglob_indirect_aggregate.ll" "$WORK/aggregate.ir" || return 1
  "$1" oracle "$WORK_NATIVE/aggregate.ir" > "$WORK/aggregate.out" 2>&1 && return 1
  awk '/expected `\(` but found/ { found = 1 } END { exit !found }' "$WORK/aggregate.out"
}
if oracle_call_checks "$WORK/port$EXE"; then
  echo "  indirect oracle call parses; multiword argument is unchanged and refused"
else
  echo "  FAIL: indirect oracle normalization"
  status=1
fi


# A lazily initialised class variable needs the hosted compiler to look up __iyi_once. A prelude
# named empty leaves iyi_prelude? false, so that fixture is built against a prelude whose require
# name ends in iyi/prelude (bench/fixtures/lowglob_abi). The fixture declares IyiRuntimeLock.
hosted_module() {
  local name="$1" fixture="$2" out="$3" log="$4" built_in path_sep
  local target=() output="$out$EXE"
  if [ "$HOST_ID" != darwin-arm64 ] && [ "${5:-oracle}" != native ]; then
    target=(--cross-compile --target aarch64-apple-darwin)
    output="$out.o"
  fi
  case "$name" in
    lowglob_cvar_lazy*)
      built_in=$("$IYI" env | awk -F= '/^IYI_PATH=/ { print substr($0, index($0, "=") + 1); exit }')
      if [ "$HOST_OS" = windows ]; then path_sep=';'; else path_sep=':'; fi
      IYI_PATH="$REPO_NATIVE/bench/fixtures/lowglob_abi${path_sep}${built_in}" "$IYI" build "${target[@]}" --prelude iyi/prelude --emit llvm-ir --no-debug -o "$(native_path "$output")" "$(native_path "$fixture")" > "$log" 2>&1
      ;;
    *) "$IYI" build "${target[@]}" --prelude empty --emit llvm-ir --no-debug -o "$(native_path "$output")" "$(native_path "$fixture")" > "$log" 2>&1 ;;
  esac
}

# Exit 1 means the initializer's side effect happened exactly once. A dropped flag
# check makes the counter 2, even if the value global itself happens to look right.
hosted_once_check() {
  if ! hosted_module lowglob_cvar_lazy "$REPO/bench/fixtures/lowglob_cvar_lazy.iyi" "$WORK/once_check" "$WORK/once_check.log" native; then
    echo 'INVALID: hosted once fixture failed to build'
    cat "$WORK/once_check.log"
    return 2
  fi
  timeout 30 "$WORK/once_check$EXE" > "$WORK/once_check.out" 2>&1
  local result=$?
  if [ "$result" -eq 124 ] || [ "$result" -ge 128 ]; then
    echo 'INVALID: hosted once fixture timed out or terminated by signal'
    cat "$WORK/once_check.out"
    return 2
  fi
  [ "$result" -eq 1 ]
}

echo
echo "== 2. Each fixture: the hosted module against the port's lowering"
passed=0
waiting=0
diverged=0
e2e=""
for fixture in "$REPO"/bench/fixtures/lowglob_*.iyi; do
  name="$(basename "$fixture" .iyi)"
  if ! hosted_module "$name" "$fixture" "$WORK/$name" "$WORK/$name.oracle.log" || [ ! -s "$WORK/$name.ll" ]; then
    echo "  $name: the hosted compiler did not emit its module (see $WORK/$name.oracle.log)"
    awk 'NR<=15' "$WORK/$name.oracle.log"
    diverged=$((diverged + 1))
    continue
  fi
  awk "$CALL_TYPES" "$WORK/$name.ll" > "$WORK/$name.oracle.ll"
  if ! "$WORK/port$EXE" oracle "$WORK_NATIVE/$name.oracle.ll" > "$WORK/$name.oracle.txt" 2> "$WORK/$name.oracle.err"; then
    echo "  $name: the port's IR parser refuses the hosted module: $(awk 'NR==1' "$WORK/$name.oracle.err")"
    diverged=$((diverged + 1))
    continue
  fi
  named=0
  case " $WAITING_FIXTURES " in
    *" $name "*) named=1 ;;
  esac
  if ! "$WORK/port$EXE" lower "$(native_path "$fixture")" "$WORK_NATIVE/$name.oracle.ll" > "$WORK/$name.port.out" 2> "$WORK/$name.port.err"; then
    reason="$(awk 'NR==1' "$WORK/$name.port.err")"
    if [ "$named" = 1 ]; then
      echo "  $name: WAITING, named: $reason"
      waiting=$((waiting + 1))
    else
      echo "  $name: REFUSED, not named as waiting: $reason"
      diverged=$((diverged + 1))
    fi
    continue
  fi
  echo "  $name:"
  awk '!/^SUMMARY/' "$WORK/$name.port.out" | awk '{ print "    " $0 }'
  summary="$(awk '/^SUMMARY/ { print }' "$WORK/$name.port.out")"
  identical="$(echo "$summary" | awk '{ split($2, a, "="); print a[2] }')"
  total="$(echo "$summary" | awk '{ split($3, a, "="); print a[2] }')"
  if [ -n "$total" ] && [ "$total" -gt 0 ] && [ "$identical" = "$total" ] && module_same "$WORK/$name.port.out"; then
    if [ "$named" = 1 ]; then
      echo "    $name: now identical to the hosted module: remove it from WAITING_FIXTURES"
      diverged=$((diverged + 1))
    fi
    echo "    $name: PASSED, $identical of $total identical (module-level and functions)"
    passed=$((passed + 1))
    e2e="$e2e $name"
  else
    echo "    $name: DIVERGED, $identical of $total identical"
    diverged=$((diverged + 1))
  fi
done
lazy_host="$WORK/lowglob_cvar_lazy$EXE"
if [ "$HOST_ID" != darwin-arm64 ]; then
  if ! hosted_module lowglob_cvar_lazy "$REPO/bench/fixtures/lowglob_cvar_lazy.iyi" "$WORK/lazy-runtime" "$WORK/lazy-runtime.log" native; then
    echo 'FAIL: hosted lazy fixture did not build for this host'
    cat "$WORK/lazy-runtime.log"
    exit 1
  fi
  lazy_host="$WORK/lazy-runtime$EXE"
fi
timeout 30 "$lazy_host" > "$WORK/lazy-hosted.out" 2>&1
lazy_status=$?
if [ "$lazy_status" -eq 1 ]; then
  echo "  hosted lazy initialization: side effect occurred exactly once (status 1)"
else
  echo "  hosted lazy initialization: expected status 1, got $lazy_status"
  diverged=$((diverged + 1))
fi
echo "  fixtures: $passed passed, $waiting waiting (named), $diverged failed"
if [ "$diverged" -gt 0 ] || [ "$passed" -eq 0 ]; then
  status=1
fi

echo
echo "== 3. End to end: each fixture the port lowers identically, built to a native executable and run"
e2e_pass=0
e2e_fail=0
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "globals: AArch64 Mach-O execution and codesign require macOS arm64 ($HOST_ID checks and emits IR)"
fi
if "$IYI" build -o "$WORK_NATIVE/compile_native$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/tool.build.log" 2>&1; then
  for name in $e2e; do
    fixture="$REPO_NATIVE/bench/fixtures/$name.iyi"
    if ! "$WORK/port$EXE" emit "$fixture" "$WORK_NATIVE/$name.oracle.ll" > "$WORK/$name.port.ir" 2> "$WORK/$name.emit.err"; then
      echo "  $name: the port writes no module: $(awk 'NR==1' "$WORK/$name.emit.err")"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    if ! "$WORK/compile_native$EXE" "$WORK_NATIVE/$name.port.ir" -o "$WORK_NATIVE/$name.native" > "$WORK/$name.native.log" 2>&1; then
      echo "  $name: the native tool refuses the port's module: $(awk 'NR==1' "$WORK/$name.native.log")"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    if [ "$HOST_ID" != darwin-arm64 ]; then
      echo "  $name: AArch64 Mach-O emitted; native execution is host-limited"
      continue
    fi
    if ! codesign -v --strict "$WORK/$name.native" > "$WORK/$name.signature.log" 2>&1; then
      echo "  $name: native signature invalid"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    timeout 30 "$WORK/$name.native" > "$WORK/$name.native.out" 2>&1; ns=$?
    timeout 30 "$WORK/$name$EXE" > "$WORK/$name.hosted.out" 2>&1; hs=$?
    expected="$hs"
    case "$name" in
      lowglob_cvar_generic_struct) expected=37 ;;
      lowglob_cvar_lazy_aggregate) expected=1 ;;
      lowglob_cvar_tuple) expected=28 ;;
    esac
    if [ "$ns" = "$hs" ] && [ "$hs" = "$expected" ] && cmp -s "$WORK/$name.native.out" "$WORK/$name.hosted.out"; then
      echo "  $name: native executable runs to the hosted result (status $hs, stdout identical)"
      e2e_pass=$((e2e_pass + 1))
    else
      echo "  $name: native status $ns, hosted $hs; stdout differs or status differs"
      e2e_fail=$((e2e_fail + 1))
    fi
  done
else
  echo "  the native tool does not build"
  cat "$WORK/tool.build.log"
  e2e_fail=1
fi
echo "  end to end: $e2e_pass fixture(s) run to the hosted result, $e2e_fail failed"
if [ "$e2e_fail" -gt 0 ] || { [ "$HOST_ID" = darwin-arm64 ] && [ "$e2e_pass" -eq 0 ]; }; then
  status=1
fi

# This uses the real prelude's Atomic rather than the empty-prelude stand-in.
# Compile from source through the typed native pipeline, then run both binaries.
echo "== 3b. Real prelude Atomic class variable"
atomic_fixture="$REPO_NATIVE/bench/fixtures/aggregate_cvar_atomic.iyi"
if "$IYI" build -o "$WORK_NATIVE/atomic-hosted$EXE" "$atomic_fixture" > "$WORK/atomic-hosted.log" 2>&1 &&
   "$WORK/compile_native$EXE" "$atomic_fixture" -o "$WORK_NATIVE/atomic.ir" --pipeline typed --prelude --emit ir > "$WORK/atomic-native.log" 2>&1 &&
   { [ "$HOST_ID" != darwin-arm64 ] ||
     { codesign -v --strict "$WORK/compile_native$EXE" > "$WORK/atomic-signature.log" 2>&1 &&
       "$WORK/compile_native$EXE" "$atomic_fixture" -o "$WORK_NATIVE/atomic-native" --pipeline typed --prelude >> "$WORK/atomic-native.log" 2>&1 &&
       codesign -v --strict "$WORK/atomic-native" >> "$WORK/atomic-signature.log" 2>&1; }; }; then
  timeout 30 "$WORK/atomic-hosted$EXE" > "$WORK/atomic-hosted.out" 2>&1; hs=$?
  if [ "$hs" -ne 0 ] || ! grep -Fxq "atomic class variable: zero then nine" "$WORK/atomic-hosted.out"; then
    echo "  FAIL: hosted atomic class variable returned $hs or unexpected output"
    cat "$WORK/atomic-hosted.out"
    status=1
  elif [ "$HOST_ID" = darwin-arm64 ]; then
    timeout 30 "$WORK/atomic-native" > "$WORK/atomic-native.out" 2>&1; ns=$?
    if [ "$ns" -eq 0 ] && cmp -s "$WORK/atomic-hosted.out" "$WORK/atomic-native.out"; then
      echo "  hosted and signed native: $(cat "$WORK/atomic-native.out") (status 0)"
    else
      echo "  FAIL: atomic class variable native status $ns or output differs"
      cat "$WORK/atomic-native.out"
      status=1
    fi
  else
    echo "  hosted atomic class variable passed; typed AArch64 IR emitted"
  fi
else
  echo "  FAIL: real prelude Atomic source proof did not build or sign"
  for log in "$WORK/atomic-signature.log" "$WORK/atomic-hosted.log" "$WORK/atomic-native.log"; do
    [ ! -f "$log" ] || awk 'NR<=15' "$log"
  done
  status=1
fi

echo
echo "== 4. Mutation proofs: the gate must catch each patch to the ported code"
# The check rebuilds the driver from the patched source and requires every fixture to match the
# hosted module exactly. A build failure marks the gate invalid and cannot count as a caught mutation.
lowglob_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/port_m$EXE" "$REPO_NATIVE/bench/selfhost_lower_globals_exercise.iyi" > "$WORK/port_m.build.log" 2>&1; then
    echo "INVALID PROOF: global-lowering driver did not compile"
    cat "$WORK/port_m.build.log"
    return 2
  fi
  "$WORK/port_m$EXE" normalizer-check > "$WORK/normalizer-mut.out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 1 ] &&
       grep -Fxq 'iyi: panic: program global stripped from comparison' "$WORK/normalizer-mut.out" &&
       tr '\\' '/' < "$WORK/normalizer-mut.out" | grep -Fq 'bench/selfhost_lower_globals_exercise.iyi:19'; then
      return 1
    fi
    echo 'INVALID: normalizer check failed outside its expected assertion'
    cat "$WORK/normalizer-mut.out"
    return 2
  fi
  ( . "$REPO/bench/lib/lower_oracle.sh"; oracle_call_checks "$WORK/port_m$EXE" ) || return 1
  for fixture in "$REPO"/bench/fixtures/lowglob_*.iyi; do
    name="$(basename "$fixture" .iyi)"
    case " $WAITING_FIXTURES " in
      *" $name "*)
        "$WORK/port_m$EXE" lower "$(native_path "$fixture")" "$WORK_NATIVE/$name.oracle.ll" > "$WORK/m.out" 2> "$WORK/m.err"
        rc=$?
        if [ "$rc" -eq 0 ]; then return 1; fi
        if expected_refusal "$rc" "$WORK/m.err" src/compiler/lower/pending.iyi 'lower: @\[ThreadLocal\] on class variable .*the body pass does not flag an untyped declaration'; then continue; fi
        echo "INVALID: $name did not reach its named ThreadLocal refusal"
        cat "$WORK/m.err"
        return 2
        ;;
    esac
    if ! "$WORK/port_m$EXE" lower "$(native_path "$fixture")" "$WORK_NATIVE/$name.oracle.ll" > "$WORK/m.out" 2>&1; then
      echo "INVALID: $name mutant did not produce a comparison"
      cat "$WORK/m.out"
      return 2
    fi
    summary="$(awk '/^SUMMARY/ { print }' "$WORK/m.out")"
    identical="$(echo "$summary" | awk '{ split($2, a, "="); print a[2] }')"
    total="$(echo "$summary" | awk '{ split($3, a, "="); print a[2] }')"
    [ -n "$total" ] && [ "$total" -gt 0 ] && [ "$identical" = "$total" ] && module_same "$WORK/m.out" || return 1
  done
  return 0
}
echo "  the mutation check passes on the unmutated code:"
if lowglob_check && [ ! -e "$WORK/invalid-build" ]; then
  echo "    unmutated: every fixture identical"
prove_mutation "a program global is incorrectly stripped as a build constant" "$REPO/bench/lib/lower_gate.iyi" \
  "        if destination.starts_with?(prefix) && identity_names.includes?(destination[prefix.size..-1])" "        if destination.includes?(marker)" -- lowglob_check || status=1
prove_mutation "indirect calls are left without a function type" "$REPO/bench/lib/lower_oracle.sh" \
  "  if (at == 0) return line" "  if (indirect || at == 0) return line" -- lowglob_check || status=1
prove_mutation "lazy initializer ignores the once flag" "$REPO/bench/fixtures/lowglob_cvar_lazy.iyi" \
  "  if !flag.value" "  if true" -- hosted_once_check || status=1
prove_mutation "a nilable Proc initializer is not discarded" "$REPO/src/compiler/lower/class_var.iyi" \
  "  node.is_a?(NilLiteral) && cvar.type.is_a?(NilableProcType)" "  false" -- lowglob_check || status=1
prove_mutation "a pointer class variable is refused" "$REPO/src/compiler/lower/class_var.iyi" \
  "  if !(ir.int? || ir.float? || ir.pointer?)" "  if !(ir.int? || ir.float?)" -- lowglob_check || status=1
prove_mutation "a nil aggregate initializer is not discarded" "$REPO/src/compiler/lower/class_var.iyi" \
  "  if nilable_proc_initializer?(cvar, node) || nilable_aggregate_initializer?(cvar)" \
  "  if nilable_proc_initializer?(cvar, node)" -- lowglob_check || status=1
prove_mutation "a generic aggregate class variable is refused" "$REPO/src/compiler/lower/class_var.iyi" \
  '  if passed_by_value?(cvar.type)'$'\n''    if low.typer.passed_indirectly?(cvar.type)' \
  '  if cvar.type.is_a?(ClassType) && cvar.type.struct?'$'\n''    if low.typer.passed_indirectly?(cvar.type)' -- lowglob_check || status=1
prove_mutation "an aggregate class variable starts undefined instead of zero" "$REPO/src/compiler/lower/class_var.iyi" \
  '      global.initializer = low.builder.const_zero(ir)'$'\n''      value_type = low.analysed.type_of?(node).as(Type)' \
  '      global.initializer = low.builder.const_undef(ir)'$'\n''      value_type = low.analysed.type_of?(node).as(Type)' -- lowglob_check || status=1
prove_mutation "an aggregate initializer stores the old global instead of its result" "$REPO/src/compiler/lower/class_var.iyi" \
  '      global.initializer = low.builder.const_zero(ir)'$'\n''      value_type = low.analysed.type_of?(node).as(Type)'$'\n''      assign(low, global, cvar.type, value_type, val)' \
  '      global.initializer = low.builder.const_zero(ir)'$'\n''      value_type = low.analysed.type_of?(node).as(Type)'$'\n''      assign(low, global, cvar.type, value_type, global)' -- lowglob_check || status=1
prove_mutation "a class variable initializer loses its declaring scope" "$REPO/src/compiler/lower/class_var.iyi" \
  '  context = LowerContext.new(fn, fun_type, owner, Hash(String, LowerVar).new)' \
  '  context = LowerContext.new(fn, fun_type, nil, Hash(String, LowerVar).new)' -- lowglob_check || status=1
prove_mutation "an aggregate class variable is loaded instead of read by address" "$REPO/src/compiler/lower/class_var.iyi" \
  "  low.last = to_lhs(low, class_var_pointer(low, cvar), cvar.type)" \
  "  low.last = load_aligned(low, cvar_ir_type(low, cvar), class_var_pointer(low, cvar))" -- lowglob_check || status=1
prove_mutation "a by-value constant is loaded instead of read by address" "$REPO/src/compiler/lower/const.iyi" \
  "      low.last = to_lhs(low, g.as(Global), low.analysed.type_of?(c.value).as(Type))" \
  "      low.last = load_aligned(low, ir, g.as(Global))" -- lowglob_check || status=1
prove_mutation "a module class variable is refused as non-class" "$REPO/src/compiler/lower/class_var.iyi" \
  "  if o.full_name.includes?(\"(\")" \
  "  if !o.is_a?(ClassType) || o.full_name.includes?(\"(\")" -- lowglob_check || status=1
prove_mutation "a type path returns zero instead of its type id" "$REPO/src/compiler/lower/const.iyi" \
  "    low.last = type_id_value(low, typ.as(Type))" \
  "    low.last = low.builder.const_int(low.module.types.int32, 0_i64)" -- lowglob_check || status=1
prove_mutation "a floating constant global is initialized to zero" "$REPO/src/compiler/lower/const.iyi" \
  "    global.initializer = low.builder.const_float(ir, const.value.as(NumberLiteral).value.to_f)" \
  "    global.initializer = low.builder.const_float(ir, 0.0)" -- lowglob_check || status=1
prove_mutation "a symbol constant global has the wrong index" "$REPO/src/compiler/lower/const.iyi" \
  "    global.initializer = low.builder.const_int(ir, symbol_index(low, const.value.as(SymbolLiteral).value).to_i64)" \
  "    global.initializer = low.builder.const_int(ir, 1_i64)" -- lowglob_check || status=1
prove_mutation "a symbol class variable does not retain its literal index" "$REPO/src/compiler/lower/class_var.iyi" \
  "    value = low.builder.const_int(ir, symbol_index(low, node.as(SymbolLiteral).value).to_i64)" \
  "    value = low.builder.const_int(ir, symbol_index(low, node.as(SymbolLiteral).value).to_i64 + 1_i64)" -- lowglob_check || status=1
prove_mutation "a nil reference initializer is not discarded" "$REPO/src/compiler/lower/class_var.iyi" \
  "  node.is_a?(NilLiteral) && nilable_reference_type?(cvar.type)" \
  "  false" -- lowglob_check || status=1
prove_mutation "a namespaced class variable loses its qualified owner" "$REPO/src/compiler/lower/class_var.iyi" \
  "  owner.full_name + cvar_suffix(name)" \
  "  owner.name + cvar_suffix(name)" -- lowglob_check || status=1
prove_mutation "a literal integer constant is one more than its value" "$REPO/src/compiler/lower/const.iyi" \
  "    return low.builder.const_int(ir, text.to_i64)" \
  "    return low.builder.const_int(ir, text.to_i64 + 1_i64)" -- lowglob_check || status=1
prove_mutation "a true Bool constant is false" "$REPO/src/compiler/lower/const.iyi" \
  "      return int1(low, 1_i64)" "      return int1(low, 0_i64)" -- lowglob_check || status=1
prove_mutation "a literal constant is initialized at runtime rather than inlined" "$REPO/src/compiler/lower/const.iyi" \
  "  return value unless value.nil?" \
  "  return nil unless value.nil?" -- lowglob_check || status=1
prove_mutation "the initialiser is not called at the assignment" "$REPO/src/compiler/lower/const.iyi" \
  '  low.builder.call(ft, fn.as(Function), [] of Value, "")' \
  '  low.builder.const_int(low.module.types.int(1), 0_i64)' -- lowglob_check || status=1
prove_mutation "a constant with a constant value is stored at run time, not folded" "$REPO/src/compiler/lower/const.iyi" \
  "  if val.is_a?(Inst) && (val.as(Inst).op == Op::ConstInt || val.as(Inst).op == Op::ConstFloat)" "  if false" -- lowglob_check || status=1
prove_mutation "a read of an initialised constant is not a load" "$REPO/src/compiler/lower/const.iyi" \
  "  low.last = load_aligned(low, ir, g.as(Global))" "  low.last = llvm_nil(low)" -- lowglob_check || status=1
prove_mutation "the constant initialiser has the C convention, not iyi" "$REPO/src/compiler/lower/const.iyi" \
  "  fn.call_convention = CallConv::Iyi" "  fn.call_convention = CallConv::C" -- lowglob_check || status=1
prove_mutation "a class variable read is not a load of its global" "$REPO/src/compiler/lower/class_var.iyi" \
  "  low.last = to_lhs(low, class_var_pointer(low, cvar), cvar.type)" "  low.last = llvm_nil(low)" -- lowglob_check || status=1
prove_mutation "a literal class variable is initialised by a function, not stored at its declaration" "$REPO/src/compiler/lower/class_var.iyi" \
  "  if simple_literal?(node)" "  if false" -- lowglob_check || status=1
prove_mutation "a string constant's global is not emitted at the program's start" "$REPO/src/compiler/lower/const.iyi" \
  "initialize_simple_const(low, const)" \
  "low.last = llvm_nil(low)" -- lowglob_check || status=1
prove_mutation "a string constant's global is initialised with null, not its address" "$REPO/src/compiler/lower/const.iyi" \
  "global.initializer = str.as(Value)" \
  "global.initializer = low.builder.const_null(ir)" -- lowglob_check || status=1
prove_mutation "a string constant's assignment initialises it a second time" "$REPO/src/compiler/lower/const.iyi" \
  "if string_const?(c)" \
  "if false" -- lowglob_check || status=1
prove_mutation "a class variable assignment in a method stores the global's address, not the value" "$REPO/src/compiler/lower/class_var.iyi" \
  "  assign(low, ptr, cvar.type, value_type, value)" \
  "  assign(low, ptr, cvar.type, value_type, ptr)" -- lowglob_check || status=1
prove_mutation "a nilable reference class variable's global has no null initialiser" "$REPO/src/compiler/lower/class_var.iyi" \
  "    g.initializer = low.builder.const_null(ir)" "    g.initializer = nil" -- lowglob_check || status=1
prove_mutation "a @[ThreadLocal] class variable is lowered as a plain global (its refusal is lifted)" "$REPO/src/compiler/lower/lower.iyi" \
  '  if node.is_a?(Annotation) && node.as(Annotation).path.names.last == "ThreadLocal"' "  if false" -- lowglob_check || status=1
prove_mutation "a typed @[ThreadLocal] class variable is lowered as a plain global (its flag is ignored)" "$REPO/src/compiler/lower/class_var.iyi" \
  "  if cvar.thread_local" "  if false" -- lowglob_check || status=1
prove_mutation "a thread-local class variable is read through its global, not its accessor" "$REPO/src/compiler/lower/class_var.iyi" \
  "  thread_local_address(low, cvar, name, g)" "  g" -- lowglob_check || status=1
prove_mutation "a UInt64 literal above Int64 max loses its sign bit" "$REPO/src/compiler/lower/const.iyi" \
  ".to_i64 &- 9223372036854775807_i64 &- 1_i64" ".to_i64" -- lowglob_check || status=1
prove_mutation "a namespaced constant is named by its bare name, not its full name" "$REPO/src/compiler/lower/const.iyi" \
  "  return const.full_name" "  return const.name" -- lowglob_check || status=1
prove_mutation "a required file's class variable literal ignores its declared type" "$REPO/src/compiler/lower/class_var.iyi" \
  "    value = literal_of_type(low, node, declared)" \
  "    value = nil" -- lowglob_check || status=1
prove_mutation "pointerof of a class variable is refused" "$REPO/src/compiler/lower/lower.iyi" \
  "    if exp.is_a?(ClassVar)" \
  "    if false" -- lowglob_check || status=1
prove_mutation "a float class-variable literal is not stored" "$REPO/src/compiler/lower/const.iyi" \
  "    return low.builder.const_float(low.typer.llvm_type(typ), text.to_f)" \
  "    return nil" -- lowglob_check || status=1
prove_mutation "a class variable initializer stores null instead of its value" "$REPO/src/compiler/lower/class_var.iyi" \
  $'      global.initializer = low.builder.const_null(ir)\n      value_type = low.analysed.type_of?(node).as(Type)\n      assign(low, global, cvar.type, value_type, val)' \
  $'      global.initializer = low.builder.const_null(ir)\n      value_type = low.analysed.type_of?(node).as(Type)\n      assign(low, global, cvar.type, value_type, low.builder.const_null(ir))' -- lowglob_check || status=1
prove_mutation "the initialiser function is not passed to once" "$REPO/src/compiler/lower/const.iyi" \
  '  low.builder.call_aux(CallAux.new(ft, CallConv::C), once_fn, [flag.as(Value), fn.as(Value)] of Value, "")' \
  '  low.builder.call_aux(CallAux.new(ft, CallConv::C), once_fn, [flag.as(Value), flag.as(Value)] of Value, "")' -- lowglob_check || status=1
else
  echo "    FAIL: the unmutated code does not pass the check; mutations were not run"
  status=1
fi
[ ! -e "$WORK/invalid-build" ] || status=1


echo
if [ "$status" -eq 0 ]; then
  echo "lower globals gate: OK"
else
  echo "lower globals gate: FAILED"
fi
exit "$status"
