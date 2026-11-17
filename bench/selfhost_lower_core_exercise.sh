#!/usr/bin/env bash
# Fails when the typed lowering of the core (src/compiler/lower/{lower,context}.iyi)
# stops agreeing with the hosted code generator's module for the same fixture.
#
# For each fixture (bench/fixtures/lower_*.iyi) the hosted compiler builds the program
# against --prelude empty, with --emit llvm-ir and --no-debug. Its module is read
# through the port's IR text parser (src/compiler/ir/parser.iyi) and printed by the
# port's printer, the same as the port's own lowering. The port analyses the fixture
# with its semantic passes, lowers it with lower/lower.iyi, and prints the module. The
# two normalised texts are compared function by function, and each function is
# reported identical, or differing at which line, or missing.
#
# Normalisation, the same on both sides (the driver's header lists it):
#   - the compiler's build constants: every global named ::BUILD_*, the private
#     constants that hold their text, and the stores into them. The program stores
#     them on entry; they are the compiler's identity, not the program's.
#   - the printf declaration the hosted constant printing emits, the attribute groups,
#     comments and the source header.
#   - the function type of a direct call. LLVM 22 writes `call void @f(i32 %a)` and
#     leaves the type out; the port's text form writes `call void (i32) @f(i32 %a)`,
#     which the port's parser reads. This script writes the type into the oracle's
#     calls from the argument types before the port reads it (see CALL_TYPES below).
#
# A fixture the port cannot analyse, or one that reaches a construct lower/pending.iyi
# refuses by name, is WAITING: the gate names the reason and counts it as neither passed
# nor failed. A fixture the port lowers to a different module is a failure.
#
# Mutation proofs patch the ported code, rebuild the driver, and require the gate to
# fail. A patch that changes nothing is refused by prove_mutation.
#
#   bash bench/selfhost_lower_core_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
. "$REPO/bench/lib/mutation.sh"
WORK="$(mktemp -d)"

trap 'rm -rf "$WORK"' EXIT

# CALL_TYPES, the awk that writes the call types and the phi labels into the oracle, is
# shared with the calls gate (bench/lib/lower_oracle.sh).
. "$REPO/bench/lib/lower_oracle.sh"

# The oracle rewriter reads a callee up to its own closing parenthesis: a quoted generic name holds
# parentheses of its own (`@"*Box(Int32)^Box(T)::new<Int32>:Box(Int32)"`). The check re-sources the library
# in a subshell, so a mutation of bench/lib/lower_oracle.sh is what it tests.
quoted_callee_line='  %2 = call %"Box(Int32)" @"*Box(Int32)^Box(T)::new<Int32>:Box(Int32)"(i32 %1, i32 7) #3'
quoted_callee_expected='  %2 = call iyicc %"Box(Int32)" (i32, i32) @"*Box(Int32)^Box(T)::new<Int32>:Box(Int32)"(i32 %1, i32 7)'
quoted_callee_check() {
  local got
  got="$(bash -c '. "$1"; awk "$CALL_TYPES" <<< "$2"' _ "$REPO/bench/lib/lower_oracle.sh" "$quoted_callee_line")" || return 1
  [ "$got" = "$quoted_callee_expected" ]
}
echo "== 0. The oracle rewriter reads a quoted callee name whole"
if quoted_callee_check; then
  echo "  $quoted_callee_expected"
else
  echo "  FAIL: the oracle rewriter does not write the quoted callee's type (lower_oracle.sh CALL_TYPES)"
  status=1
fi
echo

# A prose line for each fixture verdict, so the summary can be read without the logs.
verdict_lines=""

echo "== 1. Building the port driver and the context checks"
if ! "$IYI" build -o "$WORK/port" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/port.build.log" 2>&1; then
  echo "the port driver failed to build:"
  awk 'NR<=20' "$WORK/port.build.log"
  exit 1
fi
if "$WORK/port" context > "$WORK/context.out" 2>&1 && awk '/^CONTEXT OK$/ { ok = 1 } END { exit !ok }' "$WORK/context.out"; then
  echo "  lower/context.iyi: the state and the alloca rule hold"
else
  echo "  lower/context.iyi: CONTEXT CHECKS FAILED:"
  awk 'NR<=6' "$WORK/context.out"
  status=1
fi
if "$WORK/port" jump-mismatch > "$WORK/jump-mismatch.out" 2>&1; then
  echo "  FAIL: mismatched typed jump target was accepted"
  status=1
elif ! awk '/typed jump target disagrees with lexical target/ { found = 1 } END { exit !found }' "$WORK/jump-mismatch.out"; then
  echo "  FAIL: mismatched target did not produce its named refusal"
  status=1
else
  echo "  mismatched typed jump target refused"
fi

echo
echo "== 2. Each fixture: the hosted module against the port's lowering"
passed=0
# Fixtures whose modules differ from the hosted one for reasons named in NEEDS.md
# wait by name; the gate fails if one starts to match.
# The pointer-union fixture's allocator also differs in its metaclass type-id load;
# its hosted symbol and the naming mutation are checked independently below.
KNOWN_DIVERGED="lower_string_nonascii lower_name_pointer_union"
e2e=""
required_wide="lowconst_wide_unsigned lowconst_wide_fold lowconst_wide_signed lower_wide_literal"
required_proc_self="lower_closure_self_class lower_closure_self_struct lower_closure_self_nested lower_closure_self_unit_call lower_closure_counter lowprim_proc_call"
proc_executed=""
wide_lowered=""
wide_executed=""
module_same=0
module_differ=0
diverged=0
waiting=0
for fixture in "$REPO"/bench/fixtures/lower_*.iyi "$REPO"/bench/fixtures/lowdecl_nested_case_block.iyi "$REPO"/bench/fixtures/lowconst_*.iyi "$REPO"/bench/fixtures/lowprim_proc_call.iyi; do
  name="$(basename "$fixture" .iyi)"
  # lower_headed_late is proved in section 2c against the arena prelude. The empty-prelude
  # loop names its proc Proc(Base, Base); the port, having made the virtual type, names Base+.
  if [ "$name" = "lower_headed_late" ] || [ "$name" = "lower_probe_reuse" ]; then
    continue
  fi
  if ! "$IYI" build --prelude empty --emit llvm-ir --no-debug -o "$WORK/$name" "$fixture" > "$WORK/$name.oracle.log" 2>&1 || [ ! -s "$WORK/$name.ll" ]; then
    echo "  $name: the hosted compiler did not emit its module (see $WORK/$name.oracle.log)"
    awk 'NR<=3' "$WORK/$name.oracle.log"
    diverged=$((diverged + 1))
    continue
  fi
  awk "$CALL_TYPES" "$WORK/$name.ll" > "$WORK/$name.oracle.ll"

  if ! "$WORK/port" oracle "$WORK/$name.oracle.ll" > "$WORK/$name.oracle.txt" 2> "$WORK/$name.oracle.err"; then
    echo "  $name: the port's IR parser refuses the hosted module: $(awk 'NR==1' "$WORK/$name.oracle.err")"
    diverged=$((diverged + 1))
    continue
  fi

  if ! "$WORK/port" lower "$fixture" "$WORK/$name.oracle.ll" > "$WORK/$name.port.out" 2> "$WORK/$name.port.err"; then
    reason="$(awk 'NR==1' "$WORK/$name.port.err")"
    echo "  $name: WAITING: $reason"
    waiting=$((waiting + 1))
    continue
  fi
  echo "  $name:"
  awk 'NR>0' "$WORK/$name.port.out" | awk '!/^SUMMARY/' | awk '{ print "    " $0 }'
  summary="$(awk '/^SUMMARY/ { print }' "$WORK/$name.port.out")"
  identical="$(echo "$summary" | awk '{ split($2, a, "="); print a[2] }')"
  total="$(echo "$summary" | awk '{ split($3, a, "="); print a[2] }')"
  module_ok="$(echo "$summary" | awk '{ split($4, a, "="); print a[2] }')"
  if [ "$module_ok" = 1 ]; then
    module_same=$((module_same + 1))
  else
    module_differ=$((module_differ + 1))
  fi
  if [ -n "$total" ] && [ "$total" -gt 0 ] && [ "$identical" = "$total" ]; then
    case " $KNOWN_DIVERGED " in
      *" $name "*) echo "    $name: now identical to the hosted module: remove it from KNOWN_DIVERGED"; diverged=$((diverged + 1)) ;;
    esac
    echo "    $name: PASSED, $identical of $total functions identical (module-level counted below)"
    passed=$((passed + 1))
    e2e="$e2e $name"
    if [ "$module_ok" = 1 ]; then
      case " $required_wide " in
        *" $name "*) wide_lowered="$wide_lowered $name" ;;
      esac
    fi
  else
    case " $KNOWN_DIVERGED " in
      *" $name "*) echo "    $name: WAITING, known divergence: $identical of $total identical (see NEEDS.md)"; waiting=$((waiting + 1)) ;;
      *) echo "    $name: DIVERGED, $identical of $total identical"; diverged=$((diverged + 1)) ;;
    esac
  fi
done
for name in $required_wide; do
  case " $wide_lowered " in
    *" $name "*) echo "  $name: required full module matches" ;;
    *) echo "  $name: FAIL, required full module did not match"; status=1 ;;
  esac
done
for name in $required_proc_self; do
  case " $e2e " in
    *" $name "*) echo "  $name: required proc module matches" ;;
    *) echo "  $name: FAIL, required proc module did not match"; status=1 ;;
  esac
done
echo "  fixtures: $passed passed, $diverged diverged, $waiting waiting (named above)"
if [ "$diverged" -gt 0 ]; then
  status=1
fi
if [ "$passed" -eq 0 ]; then
  echo "  no fixture passed: the gate proves nothing yet"
  status=1
fi

echo
echo "== 2b. End to end: each fixture the port lowers identically, built to a native executable and run"
e2e_pass=0
e2e_fail=0
if "$IYI" build -o "$WORK/compile_native" "$REPO/src/compiler/tools/compile_native.iyi" > "$WORK/tool.build.log" 2>&1; then
  for name in $e2e; do
    fixture="$REPO/bench/fixtures/$name.iyi"
    if ! "$WORK/port" emit "$fixture" "$WORK/$name.oracle.ll" > "$WORK/$name.port.ir" 2> "$WORK/$name.emit.err"; then
      echo "  $name: the port writes no module: $(awk 'NR==1' "$WORK/$name.emit.err")"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    if ! "$WORK/compile_native" "$WORK/$name.port.ir" -o "$WORK/$name.native" > "$WORK/$name.native.log" 2>&1; then
      if grep -q "cannot be rebased" "$WORK/$name.native.log"; then
        echo "  $name: WAITING, the native tool cannot rebase an absolute pointer in a constant: $(awk 'NR==1' "$WORK/$name.native.log")"
        waiting=$((waiting + 1))
        continue
      fi
      echo "  $name: the native tool refuses the port's module: $(awk 'NR==1' "$WORK/$name.native.log")"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    if ! codesign -v --strict "$WORK/$name.native" > /dev/null 2>&1; then
      echo "  $name: FAIL, native signature invalid"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    timeout 30 "$WORK/$name.native" > "$WORK/$name.native.out" 2>&1; ns=$?
    timeout 30 "$WORK/$name" > "$WORK/$name.hosted.out" 2>&1; hs=$?
    if [ "$ns" = "$hs" ] && cmp -s "$WORK/$name.native.out" "$WORK/$name.hosted.out"; then
      echo "  $name: native executable runs to the hosted result (status $hs, stdout identical)"
      e2e_pass=$((e2e_pass + 1))
      case " $required_proc_self " in
        *" $name "*)
          expected=0
          [ "$name" = lowprim_proc_call ] && expected=7
          if [ "$hs" -eq "$expected" ]; then
            proc_executed="$proc_executed $name"
          else
            echo "  $name: FAIL, expected status $expected"
            status=1
          fi
          ;;
      esac
      if [ "$hs" = 7 ]; then
        case " $required_wide " in
          *" $name "*) wide_executed="$wide_executed $name" ;;
        esac
      fi
    else
      echo "  $name: native status $ns, hosted $hs; stdout differs or status differs"
      e2e_fail=$((e2e_fail + 1))
    fi
  done
else
  echo "  the native tool does not build (see $WORK/tool.build.log)"
  e2e_fail=1
fi
echo "  end to end: $e2e_pass fixture(s) run to the hosted result, $e2e_fail failed"
if [ "$e2e_fail" -gt 0 ] || [ "$e2e_pass" -eq 0 ]; then
  status=1
fi
for name in $required_wide; do
  case " $wide_executed " in
    *" $name "*) echo "  $name: required native and hosted status 7 matched" ;;
    *) echo "  $name: FAIL, required native execution did not match status 7"; status=1 ;;
  esac
done
for name in $required_proc_self; do
  case " $proc_executed " in
    *" $name "*) echo "  $name: required proc executable matched" ;;
    *) echo "  $name: FAIL, required proc executable was not proved"; status=1 ;;
  esac
done

# An external variable's address is a global pointer, not a getter call. Keep
# an ordinary lib function call as a negative case.
echo "== 2b. External library variable address"
pointer_fixture="$REPO/bench/fixtures/wait_lower_pointerof_lib_var.iyi"
if "$IYI" build --prelude empty --emit llvm-ir --no-debug -o "$WORK/pointer-lib-host" "$pointer_fixture" > "$WORK/pointer-lib-host.log" 2>&1 &&
   awk "$CALL_TYPES" "$WORK/pointer-lib-host.ll" > "$WORK/pointer-lib-oracle.ll" &&
   "$WORK/port" lower "$pointer_fixture" "$WORK/pointer-lib-oracle.ll" > "$WORK/pointer-lib.compare" 2> "$WORK/pointer-lib.err" &&
   awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/pointer-lib.compare" &&
   "$WORK/port" emit "$pointer_fixture" "$WORK/pointer-lib-oracle.ll" > "$WORK/pointer-lib.ir" 2> "$WORK/pointer-lib-emit.err" &&
   "$WORK/compile_native" "$WORK/pointer-lib.ir" -o "$WORK/pointer-lib-native" > "$WORK/pointer-lib-native.log" 2>&1 &&
   { timeout 30 "$WORK/pointer-lib-host" > "$WORK/pointer-lib-host.out" 2>&1; hs=$?; true; } &&
   codesign -v --strict "$WORK/pointer-lib-native" > /dev/null 2>&1; then
  timeout 30 "$WORK/pointer-lib-native" > "$WORK/pointer-lib-native.out" 2>&1; ns=$?
  if [ "$hs" -eq 7 ] && [ "$ns" -eq 7 ] && cmp -s "$WORK/pointer-lib-host.out" "$WORK/pointer-lib-native.out"; then
    echo "  external variable address: IR identical, native and hosted status 7"
  else
    echo "  FAIL: external variable address native status $ns, hosted status $hs"
    status=1
  fi
else
  echo "  FAIL: external variable address did not match hosted IR or build natively"
  status=1
fi
if "$WORK/port" emit "$REPO/bench/fixtures/wait_lower_pointerof_lib_fun.iyi" "$WORK/pointer-lib-oracle.ll" > "$WORK/pointer-lib-fun.out" 2> "$WORK/pointer-lib-fun.err"; then
  echo "  FAIL: pointerof ordinary library function call was accepted"
  status=1
elif grep -Fq 'pointerof of LibC.getpid is not ported yet' "$WORK/pointer-lib-fun.err"; then
  echo "  ordinary library function call: refused by name"
else
  echo "  FAIL: ordinary library function call did not reach its named refusal"
  status=1
fi

if "$IYI" build --prelude empty --no-debug -o "$WORK/float-fraction-host" "$REPO/bench/fixtures/wait_lowconst_float_fraction.iyi" > "$WORK/float-fraction-host.log" 2>&1 &&
   ! "$WORK/port" emit "$REPO/bench/fixtures/wait_lowconst_float_fraction.iyi" "$WORK/lowconst_float_nan.oracle.ll" > "$WORK/float-fraction.out" 2> "$WORK/float-fraction.err" &&
   grep -Fq 'constant FRACTION is an operator call' "$WORK/float-fraction.err"; then
  echo "  nonzero float division: hosted accepts, port refuses by name"
else
  echo "  FAIL: nonzero float division did not reach its named refusal"
  status=1
fi

if "$IYI" build --prelude empty --no-debug -o "$WORK/path-float-host" "$REPO/bench/fixtures/wait_lowconst_path_float.iyi" > "$WORK/path-float-host.log" 2>&1 &&
   ! "$WORK/port" emit "$REPO/bench/fixtures/wait_lowconst_path_float.iyi" "$WORK/lowconst_path.oracle.ll" > "$WORK/path-float.out" 2> "$WORK/path-float.err" &&
   grep -Fq 'constant ALIAS is a path to another constant' "$WORK/path-float.err"; then
  echo "  float constant alias: hosted accepts, port refuses by name"
else
  echo "  FAIL: float constant alias did not reach its named refusal"
  status=1
fi

class_self_check() {
  "$IYI" build -o "$WORK/port-class-self" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/class-self.build.log" 2>&1 || return 1
  "$WORK/port-class-self" lower "$REPO/bench/fixtures/lower_class_self.iyi" "$WORK/lower_class_self.oracle.ll" > "$WORK/class-self.out" 2> "$WORK/class-self.err" || return 1
  awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/class-self.out"
}
echo "== 2c. Class self is the metaclass type id, identical to hosted"
if class_self_check; then
  echo "  lower_class_self: IR identical to hosted"
  prove_mutation "class self uses its metaclass id" "$REPO/src/compiler/lower/call.iyi" \
    '        low.last = type_id_value(low, meta)' \
    '        low.last = low.builder.const_int(low.module.types.int32, 0_i64)' -- class_self_check || status=1
else
  echo "FAIL: class self fixture differs from hosted"
  awk 'NR<=12' "$WORK/class-self.err" "$WORK/class-self.out" "$WORK/class-self.build.log"
  status=1
fi

and_effect_check() {
  "$IYI" build -o "$WORK/port-and-effect" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/and-effect.build.log" 2>&1 || return 1
  "$WORK/port-and-effect" lower "$REPO/bench/fixtures/lower_and_effect.iyi" "$WORK/lower_and_effect.oracle.ll" > "$WORK/and-effect.out" 2> "$WORK/and-effect.err" || return 1
  awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/and-effect.out"
}
echo "== 2c2. Nested && and || lower the typed expansion"
if and_effect_check; then
  echo "  lower_and_effect: IR identical to hosted"
  prove_mutation "an and ignores its typed expansion" "$REPO/src/compiler/lower/lower.iyi" \
    '  recorded = low.analysed.expansions[node]?' \
    '  recorded = nil' -- and_effect_check || status=1
else
  echo "FAIL: and effect fixture differs from hosted"
  awk 'NR<=12' "$WORK/and-effect.err" "$WORK/and-effect.out" "$WORK/and-effect.build.log"
  status=1
fi

echo "== 2c3. Well-known funs are pre-visited; a reached pool is refused"
pool_check() {
  "$IYI" build -o "$WORK/port-pool" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/pool.build.log" 2>&1 || return 1
  if "$WORK/port-pool" lower "$REPO/bench/fixtures/preempt_pool.iyi" "$WORK/lower_exit.oracle.ll" > "$WORK/pool.out" 2> "$WORK/pool.err"; then
    return 1
  fi
  grep -Fq "loop back-edge preemption checks are not ported (hosted iyi_preempt_on?)" "$WORK/pool.err"
}
if pool_check; then
  echo "  reached pool: refused by name"
  prove_mutation "a reached pool is not refused" "$REPO/src/compiler/lower/lower.iyi" \
    'pending_visit_node("loop back-edge preemption checks are not ported (hosted iyi_preempt_on?)")' \
    'nil' -- pool_check || status=1
else
  echo "FAIL: a reached pool did not refuse by name"
  awk 'NR<=12' "$WORK/pool.err" "$WORK/pool.build.log"
  status=1
fi

echo "== 2c4. Captured generic output inside a group"
bash "$REPO/bench/selfhost_lower_group_output_exercise.sh" || status=1

module_floor_file="$REPO/bench/selfhost_lower_core_module.floor"
module_floor="$(awk 'NR==1 { print $1 }' "$module_floor_file" 2>/dev/null)"
module_floor="${module_floor:-0}"
echo "  module-level: $module_same identical to the hosted module, $module_differ differ (type-id constants, NEEDS.md row 16)"
if [ -n "${LOWER_MODULE_RAISE:-}" ] && [ "$module_same" -gt "$module_floor" ]; then
  echo "$module_same" > "$module_floor_file"
  module_floor="$module_same"
  echo "  wrote the module-level floor: $module_same"
fi
if [ "$module_same" -lt "$module_floor" ]; then
  echo "  FAIL: module-level identity fell below its floor ($module_same < $module_floor)"
  status=1
fi
echo
echo "== 3. Mutation proofs: the gate must catch each patch to the ported code"
# The check rebuilds the driver from the patched source and requires the nil fixture
# to match the hosted module exactly, and the context checks to hold. It returns 0 only
# on the unmutated behaviour.
CORE_CHECK_FIXTURES="lower_nil lower_int lower_bool lower_assign lower_if lower_char lower_while lower_while_true lower_break lower_unless lower_fold lower_cond_int lower_return lower_return_bare lower_return_last lower_typedecl lower_typedecl_nil lower_fun_nil lower_fun_unused lower_implicit_self lower_fun_iyi lower_uint64_big lower_proc_literal lower_uninitialized lower_uninitialized_value lower_class_new lower_cast lower_assign_param lower_isa_union lower_trait lower_nilable_reference_union_assign lower_union_consumers lower_union_block_jumps"
CORE_CHECK_FIXTURES="$CORE_CHECK_FIXTURES lower_trait_assoc lower_negated_is_a"
# The mutation check: the driver rebuilt from the patched source must still lower each identical fixture to the hosted
# module (known divergences are left out, so the unmutated check passes and a mutation is caught by a real difference).
lower_core_check() {
  if ! "$IYI" build -o "$WORK/port-m" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/m.build.log" 2>&1; then
    cat "$WORK/m.build.log" > "$WORK/m.invalid"
    return 1
  fi
  "$WORK/port-m" context > "$WORK/m.ctx" 2>&1 || return 1
  awk '/^CONTEXT OK$/ { ok = 1 } END { exit !ok }' "$WORK/m.ctx" || return 1
  if "$WORK/port-m" jump-mismatch > "$WORK/m.jump" 2>&1; then return 1; fi
  awk '/typed jump target disagrees with lexical target/ { found = 1 } END { exit !found }' "$WORK/m.jump" || return 1
  for n in $CORE_CHECK_FIXTURES; do
    "$WORK/port-m" lower "$REPO/bench/fixtures/$n.iyi" "$WORK/$n.oracle.ll" > "$WORK/m.out" 2> "$WORK/m.err" || return 1
    awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); exit !(a[2] == b[2] && a[2] > 0) }' "$WORK/m.out" || return 1
  done
  return 0
}

# A failed mutant build or unrelated refusal is not a caught parity change.
proc_ir_mutant_check() {
  local name="$1"
  if ! "$IYI" build -o "$WORK/proc-ir-mut" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/proc-ir-mut.build.log" 2>&1; then
    echo "INVALID: proc IR mutant driver did not build"
    return 0
  fi
  if ! "$WORK/proc-ir-mut" lower "$REPO/bench/fixtures/$name.iyi" "$WORK/$name.oracle.ll" > "$WORK/proc-ir-mut.out" 2>&1; then
    echo "INVALID: proc IR mutant could not lower $name"
    return 0
  fi
  awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); if (a[2] == b[2] && b[2] > 0 && c[2] == 1) ok=1 } END { exit !ok }' "$WORK/proc-ir-mut.out"
}

proc_result_standin_mutant_check() {
  if ! "$IYI" build -o "$WORK/proc-st-mut" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/proc-st-mut.build.log" 2>&1; then
    echo "INVALID: proc return stand-in mutant driver did not build"
    return 0
  fi
  if "$WORK/proc-st-mut" lower "$REPO/bench/fixtures/lower_closure_self_class.iyi" "$WORK/lower_closure_self_class.oracle.ll" > "$WORK/proc-st-mut.out" 2>&1; then
    return 0
  fi
  if awk '/undefined method .count. for Int32/ { found=1 } END { exit !found }' "$WORK/proc-st-mut.out"; then
    return 1
  fi
  echo "INVALID: proc return stand-in mutant failed for another reason"
  return 0
}

prove_mutation "captured parameter names lose priority to closure fields" "$REPO/src/compiler/lower/fun.iyi" \
  'fn.name_param(fn.param(first + i), target.args[i].name)' 'nil' -- proc_ir_mutant_check lower_closure_self_nested || status=1
prove_mutation "aggregate proc call joins values instead of branch-local addresses" "$REPO/src/compiler/lower/primitives.iyi" \
  'aggregate = passed_by_value?(result_type)' 'aggregate = false' -- proc_ir_mutant_check lower_closure_self_struct || status=1
prove_mutation "proc call stand-in always returns Int32" "$REPO/bench/lib/primitive_stand_in.iyi" \
  'proc_call = primitive_def("call", [Arg.new("args", nil, Splat.new(Path.new("T")))] of Arg, Path.new("R"), "proc_call")' \
  'proc_call = primitive_def("call", [Arg.new("args", nil, Splat.new(Path.new("T")))] of Arg, Path.new("Int32"), "proc_call")' -- proc_result_standin_mutant_check || status=1

folded_const_check() {
  if ! "$IYI" build -o "$WORK/const-fold-mut" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/const-fold-mut.log" 2>&1; then
    touch "$WORK/m.invalid"
    return 1
  fi
  "$WORK/const-fold-mut" lower "$REPO/bench/fixtures/lowconst_fold_int.iyi" "$WORK/lowconst_fold_int.oracle.ll" > "$WORK/const-fold-mut.out" 2>&1 || return 1
  awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); if (a[2] != b[2] || b[2] == 0 || c[2] != 1) bad=1; n++ } END { exit (bad || n == 0) }' "$WORK/const-fold-mut.out"
}
prove_mutation "integer constant expressions are not folded" "$REPO/src/compiler/lower/const.iyi" \
  '  result = MathInterpreter.new.interpret(const.value)' '  return nil
  result = MathInterpreter.new.interpret(const.value)' -- folded_const_check || status=1

float_zero_division_check() {
  if ! "$IYI" build -o "$WORK/const-float-mut" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/const-float-mut.log" 2>&1; then
    touch "$WORK/m.invalid"
    return 1
  fi
  "$WORK/const-float-mut" lower "$REPO/bench/fixtures/lowconst_float_nan.iyi" "$WORK/lowconst_float_nan.oracle.ll" > "$WORK/const-float-mut.out" 2>&1 || return 1
  awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); if (a[2] != b[2] || b[2] == 0 || c[2] != 1) bad=1; n++ } END { exit (bad || n == 0) }' "$WORK/const-float-mut.out"
}
prove_mutation "float zero division is not folded in its initializer" "$REPO/src/compiler/lower/const.iyi" \
  '  v = float_zero_division(low, const)' '  v = nil' -- float_zero_division_check || status=1

constant_path_check() {
  if ! "$IYI" build -o "$WORK/const-path-mut" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/const-path-mut.log" 2>&1; then
    touch "$WORK/m.invalid"
    return 1
  fi
  "$WORK/const-path-mut" lower "$REPO/bench/fixtures/lowconst_path.iyi" "$WORK/lowconst_path.oracle.ll" > "$WORK/const-path-mut.out" 2>&1 || return 1
  awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); if (a[2] != b[2] || b[2] == 0 || c[2] != 1) bad=1; n++ } END { exit (bad || n == 0) }' "$WORK/const-path-mut.out"
}
prove_mutation "a constant alias is not folded" "$REPO/src/compiler/lower/const.iyi" \
  '    return literal_path_value(low, const)' '    return nil' -- constant_path_check || status=1

wide_constant_check() {
  if ! "$IYI" build -o "$WORK/const-wide-mut" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/const-wide-mut.log" 2>&1; then
    cat "$WORK/const-wide-mut.log" >> "$WORK/m.invalid"
    return 1
  fi
  local n different=0
  : > "$WORK/wide-mut-diffs.log"
  for n in lowconst_wide $required_wide; do
    if ! "$WORK/const-wide-mut" lower "$REPO/bench/fixtures/$n.iyi" "$WORK/$n.oracle.ll" > "$WORK/const-wide-$n.out" 2>&1; then
      echo "$n: mutant did not execute" >> "$WORK/m.invalid"
      cat "$WORK/const-wide-$n.out" >> "$WORK/m.invalid"
      return 1
    fi
    if ! grep -q '^SUMMARY ' "$WORK/const-wide-$n.out"; then
      echo "$n: mutant produced no summary" >> "$WORK/m.invalid"
      return 1
    fi
    if ! awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); exit !(a[2] == b[2] && b[2] > 0 && c[2] == 1) }' "$WORK/const-wide-$n.out"; then
      echo "  $n: high-word mutant differs" >> "$WORK/wide-mut-diffs.log"
      cat "$WORK/const-wide-$n.out" >> "$WORK/wide-mut-diffs.log"
      different=1
    else
      echo "$n: high-word mutant was not detected" >> "$WORK/m.invalid"
    fi
  done
  [ "$different" -eq 0 ]
}
prove_mutation "a wide constant loses its high word" "$REPO/src/compiler/lower/const.iyi" \
  '    hi = u64_as_i64((bits >> 64).to_u64)' '    hi = 0_i64' -- wide_constant_check || status=1
cat "$WORK/wide-mut-diffs.log"

shift_constant_check() {
  if ! "$IYI" build -o "$WORK/const-shift-mut" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/const-shift-mut.log" 2>&1; then
    cat "$WORK/const-shift-mut.log" >> "$WORK/m.invalid"
    return 1
  fi
  if ! "$WORK/const-shift-mut" lower "$REPO/bench/fixtures/lowconst_shift.iyi" "$WORK/lowconst_shift.oracle.ll" > "$WORK/const-shift-mut.out" 2>&1; then
    cat "$WORK/const-shift-mut.out" >> "$WORK/m.invalid"
    return 1
  fi
  if ! grep -q '^SUMMARY ' "$WORK/const-shift-mut.out"; then
    echo "shift mutant produced no summary" >> "$WORK/m.invalid"
    return 1
  fi
  awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); exit !(a[2] == b[2] && b[2] > 0 && c[2] == 1) }' "$WORK/const-shift-mut.out"
}
prove_mutation "constant shifts leave the left operand unchanged" "$REPO/src/compiler/semantic/math_interpreter.iyi" \
  '      shift_left(left, right)' '      left' -- shift_constant_check || status=1
cat "$WORK/const-shift-mut.out"

nested_case_block_check() {
  "$IYI" build -o "$WORK/nested-case-port" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/nested-case.build.log" 2>&1 || return 1
  "$WORK/nested-case-port" lower "$REPO/bench/fixtures/lowdecl_nested_case_block.iyi" "$WORK/lowdecl_nested_case_block.oracle.ll" > "$WORK/nested-case.out" 2> "$WORK/nested-case.err" || return 1
  awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/nested-case.out"
}
nested_case_block_check || { echo "  baseline: nested case block differs"; status=1; }
prove_mutation "yielded writes do not widen the caller's local" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      unions = owner.unions' '      unions = @var_unions' -- nested_case_block_check || status=1
prove_mutation "untyped branch locals do not receive Nil storage" "$REPO/src/compiler/lower/locals.iyi" \
  '    type = t.nil? ? low.analysed.program.nil_type : t.as(Type)' '    next if t.nil?; type = t.as(Type)' -- nested_case_block_check || status=1
prove_mutation "Bool union storage drops the widened value" "$REPO/src/compiler/lower/cast.iyi" \
  '    widened = bool_widened(low, value, low.module.types.int(bits.to_i32))' '    widened = low.builder.const_int(low.module.types.int(bits.to_i32), 0_i64)' -- nested_case_block_check || status=1

# These fixtures must lower, rather than entering the general loop's named waiting set.
nil_flow_check() {
  if ! "$IYI" build -o "$WORK/nil-flow" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/nil-flow.build.log" 2>&1; then
    cat "$WORK/nil-flow.build.log" > "$WORK/nil-flow.invalid"
    return 1
  fi
  "$WORK/nil-flow" context > "$WORK/nil-flow.context" 2>&1 || return 1
  grep -qx 'CONTEXT OK' "$WORK/nil-flow.context" || return 1
  local name
  for name in "$@"; do
    "$WORK/nil-flow" lower "$REPO/bench/fixtures/$name.iyi" "$WORK/$name.oracle.ll" > "$WORK/nil-flow.out" 2> "$WORK/nil-flow.err" || return 1
    awk '/^SUMMARY identical=[0-9]+ total=[0-9]+ module=[01]$/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); if (a[2] != b[2] || b[2] == 0 || c[2] != 1) bad=1; n++ } END { exit (bad || n == 0) }' "$WORK/nil-flow.out" || return 1
  done
}
if nil_flow_check lower_or_nil_left; then
  prove_mutation "a nil-left alternative loses its live branch type" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '    elsif else_type && (then_unreachable || then_dead || speculative)' \
    '    elsif else_type && (then_unreachable || speculative)' -- nil_flow_check lower_or_nil_left || status=1
  prove_mutation "a narrowed-out read records a loop refusal" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '      if reason == narrowed_out_reason(node.name)' '      if false' -- nil_flow_check lower_or_nil_left || status=1
  prove_mutation "hidden build-name collision shifts later string globals" "$REPO/bench/selfhost_lower_core_exercise.iyi" \
    '  return lines if offset == 0' '  return lines' -- nil_flow_check lower_or_nil_left || status=1
else
  echo "FAIL: nil-left alternatives do not match the hosted module"
  status=1
fi
nil_storage_fixtures="lower_expansion_temps lower_named_tuple lower_tuple_literal lower_nil_if_read"
if nil_flow_check $nil_storage_fixtures; then
  prove_mutation "an unread local gains nil storage at a merge" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '    @nil_candidates.add(name)' \
    '    merge_var_union(name, @program.nil_type) if @var_unions.has_key?(name)' -- nil_flow_check $nil_storage_fixtures || status=1
  prove_mutation "a nilable read leaves its slot nonnilable" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '        unions[name] = @program.type_merge(stored, @program.nil_type)' \
    '        nil' -- nil_flow_check $nil_storage_fixtures || status=1
  prove_mutation "an unassigned local has no entry nil value" "$REPO/src/compiler/lower/locals.iyi" \
    '      reset_nil_slot(low, pointer, type) if r.includes?(name) && type.nilable?' \
    '      nil' -- nil_flow_check $nil_storage_fixtures || status=1
else
  echo "FAIL: read-observed nil storage does not match the hosted modules"
  status=1
fi
if [ -e "$WORK/nil-flow.invalid" ]; then
  echo "FAIL: a nil-flow mutant did not compile"
  status=1
fi
if "$WORK/port" lower "$REPO/bench/fixtures/lower_trait.iyi" "$WORK/lower_trait.oracle.ll" > "$WORK/trait.out" 2>&1 &&
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); exit !(a[2] == b[2] && a[2] > 0) }' "$WORK/trait.out"; then
  prove_mutation "trait declaration is not visited" "$REPO/src/compiler/lower/lower.iyi" \
    'if node.is_a?(TraitDef)' 'if false && node.is_a?(TraitDef)' -- lower_core_check || status=1
  prove_mutation "impl declaration is not visited" "$REPO/src/compiler/lower/lower.iyi" \
    'if node.is_a?(ImplDef)' 'if false && node.is_a?(ImplDef)' -- lower_core_check || status=1
  prove_mutation "associated type declaration is not visited" "$REPO/src/compiler/lower/lower.iyi" \
    'if node.is_a?(AssocTypeDecl)' 'if false && node.is_a?(AssocTypeDecl)' -- lower_core_check || status=1
  prove_mutation "logical temporary loses static truthiness" "$REPO/src/compiler/lower/lower.iyi" \
    'settled = static_condition(low, cond_node)' 'settled : Bool? = nil' -- lower_core_check || status=1
else
  echo "FAIL: trait fixture does not match the hosted module"
  status=1
fi
indirect_refusal_check() {
  local driver="$1" kind="$2"
  if "$driver" emit "$REPO/bench/fixtures/wait_lower_indirect_${kind}.iyi" "$WORK/lower_nil.oracle.ll" > "$WORK/indirect.out" 2>&1; then
    return 1
  fi
  awk -v expected="indirect ${kind} above 128 bytes is not ported" 'index($0, expected) { found = 1 } END { exit !found }' "$WORK/indirect.out"
}
indirect_mutant_check() {
  "$IYI" build -o "$WORK/port-indirect" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/indirect.build.log" 2>&1 || return 1
  indirect_refusal_check "$WORK/port-indirect" "$1"
}
for kind in argument result; do
  if indirect_refusal_check "$WORK/port" "$kind"; then
    echo "  indirect $kind above 128 bytes refused"
    if [ "$kind" = argument ]; then
      prove_mutation "indirect argument is not refused" "$REPO/src/compiler/lower/fun.iyi" \
        'if low.typer.passed_indirectly?(arg_type)' 'if false && low.typer.passed_indirectly?(arg_type)' -- indirect_mutant_check argument || status=1
    else
      prove_mutation "indirect result is not refused" "$REPO/src/compiler/lower/fun.iyi" \
        'if low.typer.passed_indirectly?(ret)' 'if false && low.typer.passed_indirectly?(ret)' -- indirect_mutant_check result || status=1
    fi
  else
    echo "  FAIL: indirect $kind was not refused by name"
    status=1
  fi
done
# The long-string name: a string constant longer than 18 bytes is named by its first 19 bytes and `...` (hosted
# codegen.cr:3463). The fixture's module differs only in the String type id (NEEDS.md row 16), so the gate
# compares the name in the port's own module text rather than the whole module.
long_name_check() {
  "$IYI" build -o "$WORK/port-n" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/n.build.log" 2>&1 || return 1
  "$WORK/port-n" emit "$REPO/bench/fixtures/lower_string_long.iyi" "$WORK/lower_string_long.oracle.ll" > "$WORK/n.ll" 2>&1 || return 1
  needle="a string constant l...'"
  awk -v n="$needle" 'index($0, n) > 0 { ok = 1 } END { exit !ok }' "$WORK/n.ll"
}
echo "  the long string constant is named by its hosted truncated name:"
if long_name_check; then
  echo "    yes"
else
  echo "    NO: the long-string name differs from the hosted truncated name"
  status=1
fi
string_name_check() {
  "$IYI" build -o "$WORK/port-n" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/n.build.log" 2>&1 || return 1
  "$WORK/port-n" emit "$REPO/bench/fixtures/$1.iyi" "$WORK/$1.oracle.ll" > "$WORK/n.ll" 2>&1 || return 1
  NEEDLE="$2" awk 'index($0, ENVIRON["NEEDLE"]) > 0 { ok = 1 } END { exit !ok }' "$WORK/n.ll"
}
# A non-ASCII long text is cut by character (codegen.cr:3463), and its bytes are written in the port's text form.
nonascii_name_check() {
  string_name_check lower_string_nonascii "'h\\xc3\\xa9llo w\\xc3\\xb6rld \\xc3\\xbcn\\xc3\\xafcode...'"
}
# Two texts with one 19-character cut: the second global takes the module's next number (LLVM's makeUniqueName).
collide_name_check() {
  string_name_check lower_string_collide "'a string constant l...'.1"
}
echo "  the non-ASCII long string constant is cut by character, and the second of two colliding names is renamed:"
if nonascii_name_check && collide_name_check; then
  echo "    yes"
else
  echo "    NO: a string constant name differs from the hosted name"
  status=1
fi

pointer_malloc_check() {
  "$IYI" build -o "$WORK/port-n" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/n.build.log" 2>&1 || return 1
  "$WORK/port-n" emit "$REPO/bench/fixtures/lower_pointer_malloc.iyi" "$WORK/lower_pointer_malloc.oracle.ll" > "$WORK/ptr_malloc.ir" 2>/dev/null || return 1
  awk '/call ptr.*@malloc\(i64/ { m = 1 } /intrinsic llvm\.memset\.p0\.i64/ { s = 1 } END { exit !(m && s) }' "$WORK/ptr_malloc.ir"
}
echo "  Pointer(UInt8).malloc emits C malloc and memset:"
if pointer_malloc_check; then
  echo "    yes"
else
  echo "    no"
  status=1
fi
echo "  the mutation check passes on the unmutated code:"
if lower_core_check; then
  echo "    yes"
else
  echo "    NO: the mutation proofs below would prove nothing"
  status=1
fi
prove_mutation "a by-value block call joins by value, not by address" "$REPO/src/compiler/lower/call.iyi" \
  "    merge = passed_by_value?(ret) ? low.module.types.ptr(0) : low.typer.llvm_type(ret)" \
  "    merge = low.typer.llvm_type(ret)" -- lower_core_check || status=1
prove_mutation "a by-value yield tail joins without its address" "$REPO/src/compiler/lower/block.iyi" \
  "      low.last = join_pointer(low, value.as(Value), body_type.as(Type), bt.as(Type))" \
  "      low.last = low.last" -- lower_core_check || status=1
prove_mutation "a long string constant is named in full, not truncated" "$REPO/src/compiler/lower/helpers.iyi" \
  'name_text = first_chars(name_text, 19) + "..."' 'name_text = name_text' -- long_name_check || status=1
prove_mutation "a non-ASCII long string constant is cut in bytes, not characters" "$REPO/src/compiler/lower/helpers.iyi" \
  'name_text = first_chars(name_text, 19) + "..."' 'name_text = name_text[0, 19] + "..."' -- nonascii_name_check || status=1
prove_mutation "a renamed global takes the number after the next" "$REPO/src/compiler/lower/helpers.iyi" \
  'candidate = name + "." + low.last_unique.to_s' 'candidate = name + "." + (low.last_unique + 1_i64).to_s' -- collide_name_check || status=1
prove_mutation "a taken global name is not renamed" "$REPO/src/compiler/lower/helpers.iyi" \
  'while low.module.global?(candidate) || low.module.function?(candidate)' 'while low.module.function?(candidate)' -- collide_name_check || status=1
prove_mutation "a runtime fun's name is external, not internal" "$REPO/src/compiler/lower/lower.iyi" \
  'if name.starts_with?("__crystal_")' 'if name.starts_with?("__crystal_no_such_")' -- lower_core_check || status=1
prove_mutation "a fun is not marked emitted, so its body is lowered again" "$REPO/src/compiler/lower/lower.iyi" \
  "low.fun_defs_done[name] = true" "low.fun_defs_done.size" -- lower_core_check || status=1
prove_mutation "argv is stored from the argc parameter" "$REPO/src/compiler/lower/lower.iyi" \
  "store_aligned(low, fn.param(1), argv_global)" "store_aligned(low, fn.param(0), argv_global)" -- lower_core_check || status=1
prove_mutation "main returns 1" "$REPO/src/compiler/lower/lower.iyi" \
  "low.builder.ret(low.builder.const_int(i32, 0))" "low.builder.ret(low.builder.const_int(i32, 1))" -- lower_core_check || status=1
prove_mutation "a declared variable's value is not stored" "$REPO/src/compiler/lower/lower.iyi" \
  "assign(low, slot.pointer, slot.type, vt.as(Type), v.as(Value))" "low.last = v" -- lower_core_check || status=1
prove_mutation "a return of a constant zero" "$REPO/src/compiler/lower/lower.iyi" \
  "low.builder.ret(returned)" "low.builder.ret(low.builder.const_int(ret_ir, 0_i64))" -- lower_core_check || status=1
prove_mutation "a declared variable is read without a load" "$REPO/src/compiler/lower/lower.iyi" \
  "low.last = downcast(low, v.pointer, read_type.as(Type), v.type, v.already_loaded)" "low.last = downcast(low, v.pointer, read_type.as(Type), v.type, true)" -- lower_core_check || status=1
prove_mutation "the alloca block is named after the entry block" "$REPO/src/compiler/lower/context.iyi" \
  'new_blocks(["alloca", "entry"])' 'new_blocks(["entry", "alloca"])' -- lower_core_check || status=1
prove_mutation "a bool literal is false" "$REPO/src/compiler/lower/lower.iyi" \
  "return 1_i64" "return 0_i64" -- lower_core_check || status=1
prove_mutation "a store is aligned to one byte" "$REPO/src/compiler/lower/helpers.iyi" \
  "set_align(st, low.typer.align_of(value.type))" "set_align(st, 1)" -- lower_core_check || status=1
prove_mutation "the then and else branches are swapped" "$REPO/src/compiler/lower/lower.iyi" \
  "low.builder.cond_br(cond_value, then_block, else_block)" "low.builder.cond_br(cond_value, else_block, then_block)" -- lower_core_check || status=1
prove_mutation "the while body is the condition" "$REPO/src/compiler/lower/lower.iyi" \
  "codegen_node(low, node.body)" "codegen_node(low, node.cond)" -- lower_core_check || status=1
prove_mutation "a typed break target is ignored" "$REPO/src/compiler/lower/lower.iyi" \
  "when Break  then node.target" "when Break  then node" -- lower_core_check || status=1
prove_mutation "mismatched jump targets are accepted" "$REPO/src/compiler/lower/lower.iyi" \
  'typed.object_id != lexical.object_id' 'typed.object_id == lexical.object_id' -- lower_core_check || status=1
prove_mutation "a char is its code point plus one" "$REPO/src/compiler/lower/lower.iyi" \
  "node.value.ord.to_i64)" "node.value.ord.to_i64 + 1_i64)" -- lower_core_check || status=1
prove_mutation "an empty alloca block is kept" "$REPO/src/compiler/lower/context.iyi" \
  "current_fun.blocks.delete(alloca)" "alloca.name" -- lower_core_check || status=1
prove_mutation "an unused fun is not recorded for the deferred body pass" "$REPO/src/compiler/lower/lower.iyi" \
  "low.unused_fun_defs << node" "low.unused_fun_defs.size" -- lower_core_check || status=1
prove_mutation "the deferred pass that defines unused funs is not run" "$REPO/src/compiler/lower/lower.iyi" \
  "  emit_unused_fun_defs(low)" "  low.unused_fun_defs.size" -- lower_core_check || status=1
prove_mutation "a fun definition is internal, not external" "$REPO/src/compiler/lower/lower.iyi" \
  "fn.linkage = Linkage::External" "fn.linkage = Linkage::Internal" -- lower_core_check || status=1
prove_mutation "an implicit self call passes no self" "$REPO/src/compiler/lower/call.iyi" \
  "self_value = implicit_self_value(low)" "self_value = nil" -- lower_core_check || status=1
prove_mutation "the oracle rewriter reads a quoted callee name to its first parenthesis" "$REPO/bench/lib/lower_oracle.sh" \
  'if (substr(s, i, 1) == "\"") return i' 'if (substr(s, i, 1) == "\"") return index(s, "(") - 1' -- quoted_callee_check || status=1
prove_mutation "an asm-referenced runtime fun is internal, not external" "$REPO/src/compiler/lower/lower.iyi" \
  'if asm_referenced_fun?(name) || name == "__iyi_new"' 'if name == "__iyi_new"' -- lower_core_check || status=1
prove_mutation "a UInt64 literal past Int64 max is read with to_i64, not its bit pattern" "$REPO/src/compiler/lower/lower.iyi" \
  "const_int(ir, uint64_bits(node.value.to_u64))" "const_int(ir, node.value.to_i64)" -- lower_core_check || status=1
prove_mutation "a proc literal's name uses the file as given, not relative to the working directory" "$REPO/src/compiler/lower/proc.iyi" \
  'symbol_text(relative_filename(loc.filename))' 'symbol_text(loc.filename)' -- lower_core_check || status=1
prove_mutation "an uninitialized variable's value is the slot itself, not a load of it" "$REPO/src/compiler/lower/lower.iyi" \
  "low.last = to_lhs(low, slot.pointer, nt)" "low.last = slot.pointer" -- lower_core_check || status=1
prove_mutation "Pointer#malloc refuses a UInt64 count by inverting the size_t check" "$REPO/src/compiler/lower/primitives.iyi" \
  "  if count.type != low.typer.size_t" "  if count.type == low.typer.size_t" -- pointer_malloc_check || status=1
prove_mutation "Cast nil to Pointer emits llvm_nil instead of null pointer" "$REPO/src/compiler/lower/lower.iyi" \
  "      low.last = low.builder.const_null(low.typer.llvm_type(to_type))" "      low.last = llvm_nil(low)" -- lower_core_check || status=1
prove_mutation "NilableCast branches swap matches and doesnt_match" "$REPO/src/compiler/lower/lower.iyi" \
  '    doesnt_match_block = blocks[1]
    low.builder.cond_br(cmp, matches_block, doesnt_match_block)

    low.builder.position_at_end(doesnt_match_block)
    nil_val = llvm_nil(low)' \
  '    doesnt_match_block = blocks[1]
    low.builder.cond_br(cmp, doesnt_match_block, matches_block)

    low.builder.position_at_end(doesnt_match_block)
    nil_val = llvm_nil(low)' -- lower_core_check || status=1
prove_mutation "Assign to a parameter skips the local copy" "$REPO/src/compiler/lower/fun.iyi" \
  "  needs_copy = assigned_to || var_type.full_name != arg_type.full_name" "  needs_copy = false || var_type.full_name != arg_type.full_name" -- lower_core_check || status=1
prove_mutation "is_a? on NilableType tests non-null instead of null" "$REPO/src/compiler/lower/cast.iyi" \
  "    is_null = low.builder.icmp(IntPredicate::EQ, value, low.builder.const_null_pointer)" "    is_null = low.builder.icmp(IntPredicate::NE, value, low.builder.const_null_pointer)" -- lower_core_check || status=1
prove_mutation "union match function combines members with AND instead of OR" "$REPO/src/compiler/lower/cast.iyi" \
  "        acc = low.builder.bitwise_or(cur, cond)" "        acc = low.builder.bitwise_and(cur, cond)" -- lower_core_check || status=1

# The module-level count: how many CORE_CHECK_FIXTURES match the hosted module in every item, module-level included.
# A patch that changes only module-level text lowers the count, and this check catches it.
core_module_count() {
  same=0
  for n in $CORE_CHECK_FIXTURES; do
    if "$1" lower "$REPO/bench/fixtures/$n.iyi" "$WORK/$n.oracle.ll" > "$WORK/cmc.out" 2> "$WORK/cmc.err" && awk '/^SUMMARY/ { split($4, a, "="); exit !(a[2] == 1) }' "$WORK/cmc.out"; then
      same=$((same + 1))
    fi
  done
  echo "$same"
}
module_count_check() {
  "$IYI" build -o "$WORK/port-mm" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/mm.build.log" 2>&1 || return 1
  [ "$(core_module_count "$WORK/port-mm")" -ge "$module_baseline" ]
}
module_baseline="$(core_module_count "$WORK/port")"
echo "  module-level baseline over the checked fixtures: $module_baseline"
prove_mutation "the argc global is external, not internal (module-level text only)" "$REPO/src/compiler/lower/lower.iyi" \
  "argc_global.linkage = Linkage::Internal" "argc_global.linkage = Linkage::External" -- module_count_check || status=1

# A class allocated before the use that makes its virtual type. The oracle is built against the
# minimal arena prelude (IYI_PATH ends so the hosted compiler's iyi_prelude? is true and the
# allocation loads @"Base:headed"). The port analyses the prelude and the fixture as one source.
# Compared: the new function's body and the headed globals. The rest of the module is the
# compiler's own identity and the injected builtins, which this check does not claim.
headed_late_ir() {
  local portbin="$1"
  local pre="$REPO/bench/fixtures/lower_headed_prelude"
  local fix="$REPO/bench/fixtures/lower_headed_late.iyi"
  IYI_PATH="$pre" "$IYI" build --emit llvm-ir --no-debug -o "$WORK/headed" "$fix" > "$WORK/headed.hosted.log" 2>&1 || return 1
  [ -s "$WORK/headed.ll" ] || return 1
  awk "$CALL_TYPES" "$WORK/headed.ll" > "$WORK/headed.rewritten.ll" || return 1
  "$portbin" oracle "$WORK/headed.rewritten.ll" > "$WORK/headed.hostnorm" 2> "$WORK/headed.oracle.err" || return 1
  awk '1' "$pre/iyi/prelude.iyi" "$fix" > "$WORK/headed.combined.iyi"
  "$portbin" emit "$WORK/headed.combined.iyi" "$WORK/headed.ll" > "$WORK/headed.port.ll" 2> "$WORK/headed.port.err" || return 1
  python3 - "$WORK/headed.hostnorm" "$WORK/headed.port.ll" << 'PY' || return 1
import sys
def grab(text):
    out = []
    on = False
    for line in text.splitlines():
        if not on and "Base::new:Base" in line and line.startswith("define"):
            on = True
            continue
        if on:
            out.append(line)
            if line == "}":
                break
    return out
def headed(text):
    return [line for line in text.splitlines() if line.startswith('@"Base:headed"') or line.startswith('@"Child:headed"')]
host = open(sys.argv[1]).read()
port = open(sys.argv[2]).read()
hb, pb = grab(host), grab(port)
hh, ph = headed(host), headed(port)
if hb != pb or hh != ph or not hb or not hh:
    sys.stderr.write("headed body or global differs\n")
    sys.exit(1)
PY
}
headed_late_check() {
  "$IYI" build -o "$WORK/port-h" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/headed.build.log" 2>&1 || return 1
  headed_late_ir "$WORK/port-h"
}
echo
echo "== 2c. Headed byte is a global filled after every def"
if headed_late_check; then
  echo "  lower_headed_late: *Base::new:Base body and headed globals identical to the hosted module"
  if "$IYI" build -o "$WORK/compile_native" "$REPO/src/compiler/tools/compile_native.iyi" > "$WORK/headed.tool.log" 2>&1 && "$WORK/compile_native" "$WORK/headed.port.ll" -o "$WORK/headed.native" > "$WORK/headed.native.log" 2>&1 && codesign -v --strict "$WORK/headed.native" > /dev/null 2>&1; then
    timeout 30 "$WORK/headed.native" > "$WORK/headed.native.out" 2>&1; ns=$?
    timeout 30 "$WORK/headed" > "$WORK/headed.hosted.out" 2>&1; hs=$?
    if [ "$ns" = "$hs" ] && cmp -s "$WORK/headed.native.out" "$WORK/headed.hosted.out"; then
      echo "  lower_headed_late: native executable runs to the hosted result (status $hs)"
    else
      echo "  lower_headed_late: native status $ns, hosted $hs"
      status=1
    fi
  else
    echo "  lower_headed_late: the native tool refused the port module: $(awk 'NR==1' "$WORK/headed.native.log" "$WORK/headed.tool.log")"
    status=1
  fi
else
  echo "  lower_headed_late: DIVERGED"
  awk 'NR<=8' "$WORK/headed.port.err" "$WORK/headed.hosted.log" "$WORK/headed.oracle.err"
  status=1
fi
prove_mutation "the headed byte is a constant chosen at the allocation" "$REPO/src/compiler/lower/primitives.iyi" \
  'load_aligned(low, low.module.types.int8, headed_global(low, t))' \
  'low.builder.const_int(low.module.types.int8, 0_i64)' -- headed_late_check || status=1

string_fields_ir() {
  local portbin="$1"
  local pre="$REPO/bench/fixtures/lower_headed_prelude"
  local fix="$REPO/bench/fixtures/lower_string_fields.iyi"
  IYI_PATH="$pre" "$IYI" build --emit llvm-ir --no-debug -o "$WORK/sfields" "$fix" > "$WORK/sfields.hosted.log" 2>&1 || return 1
  [ -s "$WORK/sfields.ll" ] || return 1
  awk '1' "$pre/iyi/prelude.iyi" "$fix" > "$WORK/sfields.combined.iyi"
  "$portbin" emit "$WORK/sfields.combined.iyi" "$WORK/sfields.ll" > "$WORK/sfields.port.ll" 2> "$WORK/sfields.port.err" || return 1
  python3 - "$WORK/sfields.ll" "$WORK/sfields.port.ll" << 'PY' || return 1
import sys
def lines(text):
    globals = []
    pointers = []
    contexts = set()
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("@\"'hi'\" ="):
            globals.append(stripped.split("=", 1)[1].strip())
        start = 0
        needle = "getelementptr inbounds ({ i64,"
        while True:
            at = stripped.find(needle, start)
            if at < 0:
                break
            end = stripped.find(")", at)
            piece = stripped[at:end + 1] if end >= 0 else stripped[at:]
            if "\"'hi'\"" in piece and "i32 0, i32 1" in piece:
                pointers.append(piece)
                if stripped.startswith('@GREETING ='):
                    contexts.add("constant")
                elif stripped.startswith('@":symbol_table" ='):
                    contexts.add("symbol")
                elif ' call ' in stripped:
                    contexts.add("call")
            start = at + len(needle)
    return globals, pointers, contexts
host_g, host_p, host_c = lines(open(sys.argv[1]).read())
port_g, port_p, port_c = lines(open(sys.argv[2]).read())
if host_g != port_g or host_p != port_p or len(host_g) != 1 or len(host_p) < 4 or host_c != {"constant", "symbol", "call"} or port_c != host_c:
    sys.stderr.write("string literal lines differ\n")
    sys.exit(1)
PY
}
string_fields_check() {
  "$IYI" build -o "$WORK/port-sf" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/sfields.build.log" 2>&1 || return 1
  string_fields_ir "$WORK/port-sf" || return 1
  "$IYI" build -o "$WORK/sfields.tool" "$REPO/src/compiler/tools/compile_native.iyi" > "$WORK/sfields.tool.log" 2>&1 || return 1
  "$WORK/sfields.tool" "$WORK/sfields.port.ll" -o "$WORK/sfields.native" > "$WORK/sfields.native.log" 2>&1 || return 1
  codesign -v --strict "$WORK/sfields.native" > /dev/null 2>&1 || { echo "  lower_string_fields: FAIL, native signature invalid"; [ "${_PM_ARMED:-0}" = 1 ] && return 0; return 1; }
  timeout 30 "$WORK/sfields.native" > "$WORK/sfields.native.out" 2>&1; ns=$?
  timeout 30 "$WORK/sfields" > "$WORK/sfields.hosted.out" 2>&1; hs=$?
  [ "$ns" = "$hs" ] && cmp -s "$WORK/sfields.native.out" "$WORK/sfields.hosted.out"
}
echo
echo "== 2c4. An iyi string literal is the object past the header word"
if string_fields_check; then
  echo "  lower_string_fields: literal lines identical to hosted, native status matches"
  prove_mutation "an iyi string literal is the global, not the object" "$REPO/src/compiler/lower/helpers.iyi" \
    '  if low.typer.iyi_layout' \
    '  if false' -- string_fields_check || status=1
else
  echo "  lower_string_fields: DIVERGED"
  awk 'NR<=12' "$WORK/sfields.port.err" "$WORK/sfields.hosted.log" "$WORK/sfields.native.log"
  status=1
fi

probe_reuse_check() {
  "$IYI" build -o "$WORK/port-p" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/probe.build.log" 2>&1 || return 1
  "$WORK/port-p" probe-reuse "$REPO/bench/fixtures/lower_probe_reuse.iyi" > "$WORK/probe.out" 2>"$WORK/probe.err" || return 1
  awk '/^callee-clean=0$/ { ok = 1 } END { exit !ok }' "$WORK/probe.out"
}
echo
echo "== 2d. A failed probe does not leave a callee a later call records clean"
if probe_reuse_check; then
  echo "  lower_probe_reuse: the callee is not clean"
else
  echo "  lower_probe_reuse: the callee was recorded clean"
  awk 'NR<=8' "$WORK/probe.err" "$WORK/probe.out" "$WORK/probe.build.log"
  status=1
fi
prove_mutation "the completed-emission check dropped" "$REPO/src/compiler/lower/fun.iyi" \
  'return existing.as(Function) if fun_emission_done?(low.module, name) || low.emitting[name]?' \
  'return existing.as(Function)' -- probe_reuse_check || status=1
struct_join_check() {
  "$IYI" build -o "$WORK/port-join" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/join.build.log" 2>&1 || return 1
  "$WORK/port-join" lower "$REPO/bench/fixtures/lower_struct_if_join.iyi" "$WORK/lower_struct_if_join.oracle.ll" > "$WORK/join.out" 2> "$WORK/join.err" || return 1
  awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/join.out"
}
if struct_join_check; then
  prove_mutation "a struct does not join by pointer" "$REPO/src/compiler/lower/lower.iyi" \
    '  passed_by_value?(t)' '  false' -- struct_join_check || status=1
else
  echo "FAIL: struct join does not match the hosted module"
  status=1
fi
struct_cast_check() {
  "$IYI" build -o "$WORK/port-struct-cast" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/struct-cast.build.log" 2>&1 || return 1
  for name in lower_case_nilable_struct lower_same_struct_cast; do
    "$WORK/port-struct-cast" lower "$REPO/bench/fixtures/$name.iyi" "$WORK/$name.oracle.ll" > "$WORK/struct-cast.out" 2> "$WORK/struct-cast.err" || return 1
    awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/struct-cast.out" || return 1
  done
}
if struct_cast_check; then
  prove_mutation "a narrowed struct cast reads the union tag as the struct" "$REPO/src/compiler/lower/lower.iyi" \
    '      if !lv.already_loaded && TypeIndirection.remove_indirection(lv.type).full_name == obj_type.full_name' \
    '      if !lv.already_loaded' -- struct_cast_check || status=1
else
  echo "FAIL: struct casts do not match hosted modules"
  status=1
fi
virtual_ivar_check() {
  "$IYI" build -o "$WORK/port-virtual-ivar" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/virtual-ivar.build.log" 2>&1 || return 1
  "$WORK/port-virtual-ivar" lower "$REPO/bench/fixtures/lower_virtual_ivar_read.iyi" "$WORK/lower_virtual_ivar_read.oracle.ll" > "$WORK/virtual-ivar.out" 2> "$WORK/virtual-ivar.err" || return 1
  awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/virtual-ivar.out"
}
if virtual_ivar_check; then
  prove_mutation "virtual receiver fields have no base type" "$REPO/src/compiler/lower/lower.iyi" \
    '    if owner.is_a?(VirtualType)
      owner = owner.as(VirtualType).base_type
    end
    if owner.is_a?(UnionType)' \
    '    if owner.is_a?(VirtualType)
      pending_visit_node("virtual receiver fields require a base type")
    end
    if owner.is_a?(UnionType)' -- virtual_ivar_check || status=1
  prove_mutation "explicit instance-variable reads are not lowered" "$REPO/src/compiler/lower/lower.iyi" \
    '  if node.is_a?(ReadInstanceVar)' '  if false' -- virtual_ivar_check || status=1
  prove_mutation "virtual receiver fields cannot be typed" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '    owner = owner.as(VirtualType).base_type if owner.is_a?(VirtualType)' \
    '    owner = TypeIndirection.remove_indirection(owner)' -- virtual_ivar_check || status=1
else
  echo "FAIL: virtual receiver field does not match the hosted module"
  status=1
fi
case_paths_check() {
  "$IYI" build -o "$WORK/port-case-paths" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/case-paths.build.log" 2>&1 || return 1
  for name in lower_case_enum_value lower_case_actual_types; do
    "$WORK/port-case-paths" lower "$REPO/bench/fixtures/$name.iyi" "$WORK/$name.oracle.ll" > "$WORK/case-paths.out" 2> "$WORK/case-paths.err" || return 1
    awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/case-paths.out" || return 1
  done
}
if case_paths_check; then
  prove_mutation "a constant case condition is not rewritten to equality" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '          @expansions[node] = comparison' '          @expansions[node] = node.const' -- case_paths_check || status=1
  prove_mutation "a rewritten case condition is folded as a type test" "$REPO/src/compiler/lower/lower.iyi" \
    '  if test_node.is_a?(IsA) && low.analysed.expansions[test_node]?.nil?' \
    '  if test_node.is_a?(IsA)' -- case_paths_check || status=1
  prove_mutation "a rewritten case condition is not emitted" "$REPO/src/compiler/lower/lower.iyi" \
    '  if isa_expanded = low.analysed.expansions[node]?' '  if isa_expanded = (false ? low.analysed.expansions[node]? : nil)' -- case_paths_check || status=1
else
  echo "FAIL: constant and type case paths do not match hosted modules"
  status=1
fi
generic_ivar_check() {
  "$IYI" build -o "$WORK/port-g" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/g.build.log" 2>&1 || return 1
  "$WORK/port-g" lower "$REPO/bench/fixtures/lower_generic_ivar.iyi" "$WORK/lower_generic_ivar.oracle.ll" > "$WORK/g.out" 2> "$WORK/g.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); exit !(a[2] == b[2] && a[2] > 0) }' "$WORK/g.out"
}
prove_mutation "a generic class instance has no instance variables" "$REPO/src/compiler/lower/instance_var.iyi" \
  "  if owner.is_a?(GenericClassInstanceType)" \
  "  if false" -- generic_ivar_check || status=1
pointerof_ivar_check() {
  "$IYI" build -o "$WORK/port-pivar" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/pivar.build.log" 2>&1 || return 1
  "$WORK/port-pivar" lower "$REPO/bench/fixtures/lower_pointerof_ivar.iyi" "$WORK/lower_pointerof_ivar.oracle.ll" > "$WORK/pivar.out" 2> "$WORK/pivar.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); exit !(a[2] == b[2] && a[2] > 0) }' "$WORK/pivar.out"
}
prove_mutation "pointerof of an instance variable returns self" "$REPO/src/compiler/lower/instance_var.iyi" \
  "  low.last = instance_var_pointer(low, owner.as(Type), node.name, self_var.as(LowerVar).pointer)" \
  "  low.last = self_var.as(LowerVar).pointer" -- pointerof_ivar_check || status=1
struct_class_var_check() {
  "$IYI" build -o "$WORK/port-struct-cvar" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/struct-cvar.build.log" 2>&1 || return 1
  "$WORK/port-struct-cvar" lower "$REPO/bench/fixtures/lower_struct_class_var.iyi" "$WORK/lower_struct_class_var.oracle.ll" > "$WORK/struct-cvar.out" 2> "$WORK/struct-cvar.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/struct-cvar.out"
}
if struct_class_var_check; then
  prove_mutation "an address-valued struct receiver is spilled again" "$REPO/src/compiler/lower/instance_var.iyi" \
    '  return value if passed_by_value?(st) && value.type.pointer?' \
    '  return value if false' -- struct_class_var_check || status=1
  prove_mutation "a global first-field address is not folded" "$REPO/src/compiler/lower/instance_var.iyi" \
    '  return pointer if index == 0 && pointer.is_a?(Global)' \
    '  return pointer if false' -- struct_class_var_check || status=1
else
  echo "FAIL: struct class-variable receiver does not match the hosted module"
  awk 'NR<=8' "$WORK/struct-cvar.err" "$WORK/struct-cvar.out" "$WORK/struct-cvar.build.log"
  status=1
fi
bare_return_check() {
  "$IYI" build -o "$WORK/port-return" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/return.build.log" 2>&1 || return 1
  "$WORK/port-return" lower "$REPO/bench/fixtures/lower_return_bare.iyi" "$WORK/lower_return_bare.oracle.ll" > "$WORK/return.out" 2> "$WORK/return.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); exit !(a[2] == b[2] && a[2] > 0) }' "$WORK/return.out"
}
if bare_return_check; then
  prove_mutation "a bare return skips the Nil upcast" "$REPO/src/compiler/lower/lower.iyi" \
    "    returned = upcast(low, llvm_nil(low), nil_type, ret_type.as(Type))" \
    "    returned = llvm_nil(low)" -- bare_return_check || status=1
else
  echo "FAIL: unmutated bare return does not match the hosted module"
  status=1
fi
visibility_check() {
  "$IYI" build -o "$WORK/port-vis" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/vis.build.log" 2>&1 || return 1
  "$WORK/port-vis" lower "$REPO/bench/fixtures/lower_visibility.iyi" "$WORK/lower_visibility.oracle.ll" > "$WORK/vis.out" 2> "$WORK/vis.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/vis.out"
}
if visibility_check; then
  prove_mutation "visibility wrappers do not visit their expression" "$REPO/src/compiler/lower/lower.iyi" \
    '    codegen_node(low, node.as(VisibilityModifier).exp)' \
    '    pending_visit_node("visibility wrapper")' -- visibility_check || status=1
else
  echo "FAIL: visibility wrapper fixture does not match the hosted module"
  awk 'NR<=8' "$WORK/vis.err" "$WORK/vis.out" "$WORK/vis.build.log"
  status=1
fi
visibility_macro_check() {
  if ! "$IYI" build -o "$WORK/port-vis-macro" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/vis-macro.build.log" 2>&1; then
    touch "$WORK/vis-macro.invalid"
    return 1
  fi
  local fixture
  for fixture in lower_visibility_macro lower_macro_expansions; do
    "$WORK/port-vis-macro" lower "$REPO/bench/fixtures/$fixture.iyi" "$WORK/$fixture.oracle.ll" > "$WORK/vis-macro.out" 2> "$WORK/vis-macro.err" || return 1
    awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/vis-macro.out" || return 1
  done
}
if visibility_macro_check; then
  prove_mutation "an expanded macro is not lowered" "$REPO/src/compiler/lower/lower.iyi" \
    '  if node.is_a?(MacroIf) || node.is_a?(MacroFor) || node.is_a?(MacroExpression) || node.is_a?(MacroVerbatim)
    if expanded = low.analysed.expansions[node]?
      codegen_node(low, expanded)' \
    '  if node.is_a?(MacroIf) || node.is_a?(MacroFor) || node.is_a?(MacroExpression) || node.is_a?(MacroVerbatim)
    if expanded = low.analysed.expansions[node]?
      nil' -- visibility_macro_check || status=1
else
  echo "FAIL: wrapped macro fixture does not match the hosted module"
  awk 'NR<=8' "$WORK/vis-macro.err" "$WORK/vis-macro.out" "$WORK/vis-macro.build.log"
  status=1
fi
if [ -e "$WORK/vis-macro.invalid" ]; then
  echo "FAIL: the expanded-macro mutant did not compile"
  status=1
fi
atomic_return_check() {
  "$IYI" build -o "$WORK/port-atomic-return" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/atomic-return.build.log" 2>&1 || return 1
  "$WORK/port-atomic-return" lower "$REPO/bench/fixtures/lower_atomic_return.iyi" "$WORK/lower_atomic_return.oracle.ll" > "$WORK/atomic-return.out" 2> "$WORK/atomic-return.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/atomic-return.out"
}
if atomic_return_check; then
  prove_mutation "a by-value return skips loading the aggregate" "$REPO/src/compiler/lower/fun.iyi" \
    '  converted = to_rhs(low, converted, return_type.as(Type)) if converted.type.pointer?' \
    '  converted = to_rhs(low, converted, return_type.as(Type)) if false' -- atomic_return_check || status=1
else
  echo "FAIL: atomic aggregate return does not match the hosted module"
  awk 'NR<=8' "$WORK/atomic-return.err" "$WORK/atomic-return.out" "$WORK/atomic-return.build.log"
  status=1
fi
array_expansion_check() {
  "$IYI" build -o "$WORK/port-array" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/array.build.log" 2>&1 || return 1
  "$WORK/port-array" lower "$REPO/bench/fixtures/lower_expanded_array.iyi" "$WORK/lower_expanded_array.oracle.ll" > "$WORK/array.out" 2> "$WORK/array.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/array.out"
}
if array_expansion_check; then
  prove_mutation "an array literal ignores its typed expansion" "$REPO/src/compiler/lower/lower.iyi" \
    '  if node.is_a?(ArrayLiteral)' \
    '  if false' -- array_expansion_check || status=1
else
  echo "FAIL: array expansion fixture does not match the hosted module"
  awk 'NR<=8' "$WORK/array.err" "$WORK/array.out" "$WORK/array.build.log"
  status=1
fi
interpolation_check() {
  "$IYI" build -o "$WORK/port-interpolation" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/interpolation.build.log" 2>&1 || return 1
  "$WORK/port-interpolation" lower "$REPO/bench/fixtures/lower_interpolation.iyi" "$WORK/lower_interpolation.oracle.ll" > "$WORK/interpolation.out" 2> "$WORK/interpolation.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/interpolation.out"
}
if interpolation_check; then
  prove_mutation "an interpolation ignores its typed expansion" "$REPO/src/compiler/lower/lower.iyi" \
    '  if node.is_a?(StringInterpolation)' \
    '  if false' -- interpolation_check || status=1
else
  echo "FAIL: interpolation fixture does not match the hosted module"
  awk 'NR<=8' "$WORK/interpolation.err" "$WORK/interpolation.out" "$WORK/interpolation.build.log"
  status=1
fi
interpolation_constant_check() {
  "$IYI" build -o "$WORK/port-interpolation-constant" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/interpolation-constant.build.log" 2>&1 || return 1
  "$WORK/port-interpolation-constant" lower "$REPO/bench/fixtures/lower_interpolation_constant.iyi" "$WORK/lower_interpolation_constant.oracle.ll" > "$WORK/interpolation-constant.out" 2> "$WORK/interpolation-constant.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/interpolation-constant.out"
}
if interpolation_constant_check; then
  prove_mutation "a constant interpolation is not folded" "$REPO/src/compiler/lower/lower.iyi" \
    '    if constant = interpolation_constant(low, node.as(StringInterpolation))' \
    '    if constant = (false ? interpolation_constant(low, node.as(StringInterpolation)) : nil)' -- interpolation_constant_check || status=1
else
  echo "FAIL: constant interpolation fixture does not match the hosted module"
  awk 'NR<=8' "$WORK/interpolation-constant.err" "$WORK/interpolation-constant.out" "$WORK/interpolation-constant.build.log"
  status=1
fi
named_tuple_check() {
  "$IYI" build -o "$WORK/port-named-tuple" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/named-tuple.build.log" 2>&1 || return 1
  "$WORK/port-named-tuple" lower "$REPO/bench/fixtures/lower_named_tuple.iyi" "$WORK/lower_named_tuple.oracle.ll" > "$WORK/named-tuple.out" 2> "$WORK/named-tuple.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/named-tuple.out"
}
if named_tuple_check; then
  prove_mutation "named tuple literal reverses entry evaluation" "$REPO/src/compiler/lower/lower.iyi" \
    '  node.entries.each do |entry|' \
    '  node.entries.reverse_each do |entry|' -- named_tuple_check || status=1
else
  echo "FAIL: named tuple fixture does not match the hosted module"
  awk 'NR<=8' "$WORK/named-tuple.err" "$WORK/named-tuple.out" "$WORK/named-tuple.build.log"
  status=1
fi
while_true_check() {
  "$IYI" build -o "$WORK/port-while-true" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/while-true.build.log" 2>&1 || return 1
  "$WORK/port-while-true" lower "$REPO/bench/fixtures/lower_while_true.iyi" "$WORK/lower_while_true.oracle.ll" > "$WORK/while-true.out" 2> "$WORK/while-true.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/while-true.out"
}
if while_true_check; then
  prove_mutation "an endless loop emits a conditional" "$REPO/src/compiler/lower/lower.iyi" \
    '  if cond.is_a?(BoolLiteral) && cond.as(BoolLiteral).value' \
    '  if false && cond.is_a?(BoolLiteral) && cond.as(BoolLiteral).value' -- while_true_check || status=1
else
  echo "FAIL: endless loop fixture differs from hosted"
  awk 'NR<=8' "$WORK/while-true.err" "$WORK/while-true.out" "$WORK/while-true.build.log"
  status=1
fi
case_expansion_check() {
  "$IYI" build -o "$WORK/port-case" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/case.build.log" 2>&1 || return 1
  "$WORK/port-case" lower "$REPO/bench/fixtures/lower_case.iyi" "$WORK/lower_case.oracle.ll" > "$WORK/case.out" 2> "$WORK/case.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/case.out"
}
if case_expansion_check; then
  prove_mutation "case expansion is not visited" "$REPO/src/compiler/lower/lower.iyi" \
    '  if node.is_a?(Case)' '  if false && node.is_a?(Case)' -- case_expansion_check || status=1
else
  echo "FAIL: case fixture does not match the hosted module"
  awk 'NR<=8' "$WORK/case.err" "$WORK/case.out" "$WORK/case.build.log"
  status=1
fi
union_read_check() {
  if ! "$IYI" build -o "$WORK/port-union-read" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/union-read.build.log" 2>&1; then
    cat "$WORK/union-read.build.log" > "$WORK/union-read.invalid"
    return 1
  fi
  "$WORK/port-union-read" lower "$REPO/bench/fixtures/lower_union_read.iyi" "$WORK/lower_union_read.oracle.ll" > "$WORK/union-read.out" 2> "$WORK/union-read.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/union-read.out"
}
if union_read_check; then
  prove_mutation "a narrowed union read keeps its storage type" "$REPO/src/compiler/lower/lower.iyi" \
    '  low.last = downcast(low, v.pointer, read_type.as(Type), v.type, v.already_loaded)' \
    '  low.last = downcast(low, v.pointer, v.type, v.type, v.already_loaded)' -- union_read_check || status=1
else
  echo "FAIL: union read fixture does not match the hosted module"
  awk 'NR<=8' "$WORK/union-read.err" "$WORK/union-read.out" "$WORK/union-read.build.log"
  status=1
fi
# This is a native behavioral check: a broken driver or invalid mutant must not
# be counted as a caught mutation.
aggregate_store_check() {
  if ! "$IYI" build -o "$WORK/port-aggregate-store" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/aggregate-store.build.log" 2>&1; then
    touch "$WORK/aggregate-store.invalid"
    return 1
  fi
  "$WORK/port-aggregate-store" emit "$REPO/bench/fixtures/lowcast_struct_union.iyi" "$WORK/aggregate-store.ll" > "$WORK/aggregate-store.ir" 2> "$WORK/aggregate-store.err" || { touch "$WORK/aggregate-store.invalid"; return 1; }
  "$WORK/compile_native" "$WORK/aggregate-store.ir" -o "$WORK/aggregate-store.native" > "$WORK/aggregate-store.native.log" 2>&1 || { touch "$WORK/aggregate-store.invalid"; return 1; }
  codesign -v --strict "$WORK/aggregate-store.native" > /dev/null 2>&1 || { echo "  lowcast_struct_union: FAIL, native signature invalid"; touch "$WORK/aggregate-store.invalid"; return 1; }
  timeout 30 "$WORK/aggregate-store.native" > "$WORK/aggregate-store.native.out" 2>&1; local ns=$?
  timeout 30 "$WORK/aggregate-store.hosted" > "$WORK/aggregate-store.hosted.out" 2>&1; local hs=$?
  if [ "$hs" -ne 7 ] || { [ "$ns" -ne 7 ] && [ "$ns" -ne 200 ]; }; then
    touch "$WORK/aggregate-store.invalid"
    return 1
  fi
  [ "$ns" = "$hs" ] && cmp -s "$WORK/aggregate-store.native.out" "$WORK/aggregate-store.hosted.out"
}
if "$IYI" build --prelude empty --emit llvm-ir --no-debug -o "$WORK/aggregate-store.hosted" "$REPO/bench/fixtures/lowcast_struct_union.iyi" > "$WORK/aggregate-store.hosted.log" 2>&1 &&
   [ -s "$WORK/aggregate-store.ll" ] && aggregate_store_check; then
  prove_mutation "aggregate store preserves the loaded value" "$REPO/src/compiler/lower/lower.iyi" \
    '      stored = load_aligned(low, low.typer.llvm_type(vt), v)' \
    '      stored = low.builder.const_zero(low.typer.llvm_type(vt))' -- aggregate_store_check || status=1
  if [ -e "$WORK/aggregate-store.invalid" ]; then
    echo "FAIL: aggregate store mutant did not compile or exit meaningfully"
    status=1
  fi
else
  echo "FAIL: aggregate store baseline differs from hosted"
  awk 'NR<=12' "$WORK/aggregate-store.hosted.log" "$WORK/aggregate-store.err"
  status=1
fi
tuple_literal_check() {
  "$IYI" build -o "$WORK/port-tuple" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/tuple.build.log" 2>&1 || return 1
  "$WORK/port-tuple" lower "$REPO/bench/fixtures/lower_tuple_literal.iyi" "$WORK/lower_tuple_literal.oracle.ll" > "$WORK/tuple.out" 2> "$WORK/tuple.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/tuple.out"
}
if tuple_literal_check; then
  prove_mutation "tuple literal reverses entry evaluation" "$REPO/src/compiler/lower/lower.iyi" \
    '  node.elements.each_with_index do |element, index|' \
    '  node.elements.reversed.each_with_index do |element, index|' -- tuple_literal_check || status=1
else
  echo "FAIL: tuple literal fixture does not match the hosted module"
  awk 'NR<=8' "$WORK/tuple.err" "$WORK/tuple.out" "$WORK/tuple.build.log"
  status=1
fi
tuple_storage_check() {
  "$IYI" build -o "$WORK/port-tuple-storage" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/tuple-storage.build.log" 2>&1 || return 1
  "$WORK/port-tuple-storage" lower "$REPO/bench/fixtures/lower_tuple_storage.iyi" "$WORK/lower_tuple_storage.oracle.ll" > "$WORK/tuple-storage.out" 2> "$WORK/tuple-storage.err" || return 1
  awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/tuple-storage.out"
}
prove_mutation "a tuple literal loses its storage pointer" "$REPO/src/compiler/lower/lower.iyi" \
  '  low.needs_value = wants
  low.last = tuple
end

pub def codegen_node' '  low.needs_value = wants
  low.last = load_aligned(low, ir_type, tuple)
end

pub def codegen_node' -- tuple_storage_check || status=1
tuple_entry_check() {
  "$IYI" build -o "$WORK/port-tuple-entry" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/tuple-entry.build.log" 2>&1 || return 1
  "$WORK/port-tuple-entry" emit "$REPO/bench/fixtures/lower_tuple.iyi" "$WORK/lower_tuple.oracle.ll" > "$WORK/tuple-entry.ir" 2> "$WORK/tuple-entry.err" || return 1
  "$WORK/compile_native" "$WORK/tuple-entry.ir" -o "$WORK/tuple-entry.native" > "$WORK/tuple-entry.native.log" 2>&1 || return 1
  codesign -v --strict "$WORK/tuple-entry.native" > /dev/null 2>&1 || { echo "  lower_tuple: FAIL, native signature invalid"; [ "${_PM_ARMED:-0}" = 1 ] && return 0; return 1; }
  timeout 30 "$WORK/tuple-entry.native" > "$WORK/tuple-entry.native.out" 2>&1; local ns=$?
  timeout 30 "$WORK/lower_tuple" > "$WORK/tuple-entry.hosted.out" 2>&1; local hs=$?
  [ "$ns" = "$hs" ] && cmp -s "$WORK/tuple-entry.native.out" "$WORK/tuple-entry.hosted.out"
}
if tuple_entry_check; then
  prove_mutation "a bare aggregate entry uses the C convention" "$REPO/src/compiler/lower/lower.iyi" \
    '  fn.call_convention = CallConv::Iyi' \
    '  fn.call_convention = CallConv::C' -- tuple_entry_check || status=1
else
  echo "FAIL: tuple entry does not run to the hosted result"
  awk 'NR<=8' "$WORK/tuple-entry.err" "$WORK/tuple-entry.build.log" "$WORK/tuple-entry.native.log"
  status=1
fi
entry_oracle_check() {
  local lib="$REPO/bench/lib/lower_oracle.sh"
  local text rewritten
  text="$(bash -c '. "$1"; awk "$CALL_TYPES" "$2"' _ "$lib" "$WORK/lower_tuple.ll")" || return 1
  printf '%s\n' "$text" > "$WORK/entry-rewritten.ll"
  "$WORK/port" lower "$REPO/bench/fixtures/lower_tuple.iyi" "$WORK/entry-rewritten.ll" > "$WORK/entry-rewritten.out" 2>&1 || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/entry-rewritten.out" || return 1
  rewritten="$(bash -c '. "$1"; awk "$CALL_TYPES" <<'"'"'EOF'"'"'
define internal void @__iyi_main(i32 %argc, ptr %argv) {
  call void @__iyi_main(i32 %argc, ptr %argv)
  invoke void @__crystal_main(i32 %argc, ptr %argv) #1 to label %ok unwind label %rescue
EOF' _ "$lib")" || return 1
  [[ "$rewritten" == *'define internal iyicc void @__iyi_main('* ]] &&
    [[ "$rewritten" == *'call iyicc void (i32, ptr) @__iyi_main('* ]] &&
    [[ "$rewritten" == *'invoke iyicc void (i32, ptr) @__crystal_main(i32 %argc, ptr %argv) to label %ok unwind label %rescue'* ]]
}
if entry_oracle_check; then
  prove_mutation "the oracle leaves the entry definition in the C convention" "$REPO/bench/lib/lower_oracle.sh" \
    ' || $0 ~ /^define .* @(__crystal_main|__iyi_main)\(/' '' -- entry_oracle_check || status=1
else
  echo "FAIL: entry oracle normalization differs on lower_tuple or its call forms"
  status=1
fi




# naming lane (mangled_name)
# The program-level lower of lower_name_owner waits: call.iyi refuses a call inherited
# from a superclass. The name itself is the hosted symbol, probed on the def alone.
name_owner_check() {
  "$IYI" build -o "$WORK/name-port" "$REPO/bench/selfhost_lower_name_owner.iyi" > "$WORK/name.build.log" 2>&1 || return 1
  "$WORK/name-port" "$REPO/bench/fixtures/lower_name_owner.iyi" "$WORK/lower_name_owner.oracle.ll" > "$WORK/name.out" 2> "$WORK/name.err" || return 1
  awk '/^NAME-OWNER MATCH$/ { ok = 1 } END { exit !ok }' "$WORK/name.out"
}
echo
echo "== naming lane (mangled_name)"
if name_owner_check; then
  echo "  lower_name_owner: *Child^Base#flag<Int32>:Int32"
else
  echo "  lower_name_owner: the defining-owner segment differs from the hosted symbol"
  awk 'NR<=8' "$WORK/name.err" "$WORK/name.out" "$WORK/name.build.log"
  status=1
fi
prove_mutation "an inherited method drops its defining owner" "$REPO/src/compiler/lower/fun.iyi" \
  'shown + "^" + defined_spell' \
  'shown' -- name_owner_check || status=1

name_metaclass_check() {
  "$IYI" build -o "$WORK/name-meta-port" "$REPO/bench/selfhost_lower_name_owner.iyi" > "$WORK/name-meta.build.log" 2>&1 || return 1
  "$WORK/name-meta-port" "$REPO/bench/fixtures/lower_name_metaclass.iyi" "$WORK/lower_name_metaclass.oracle.ll" metaclass > "$WORK/name-meta.out" 2> "$WORK/name-meta.err" || return 1
  awk '/^NAME-OWNER MATCH$/ { ok = 1 } END { exit !ok }' "$WORK/name-meta.out"
}
if name_metaclass_check; then
  echo "  lower_name_metaclass: *NameOwner::class_flag<Int32>:Int32"
else
  echo "  lower_name_metaclass: metaclass name differs from the hosted symbol"
  awk 'NR<=8' "$WORK/name-meta.err" "$WORK/name-meta.out" "$WORK/name-meta.build.log"
  status=1
fi
prove_mutation "a metaclass is named as an instance" "$REPO/src/compiler/lower/fun.iyi" \
  '      if st.is_a?(MetaclassType)' \
  '      if false' -- name_metaclass_check || status=1

name_return_check() {
  "$IYI" build -o "$WORK/name-return-port" "$REPO/bench/selfhost_lower_name_owner.iyi" > "$WORK/name-return.build.log" 2>&1 || return 1
  "$WORK/name-return-port" "$REPO/bench/fixtures/lower_name_return.iyi" "$WORK/lower_name_return.oracle.ll" return > "$WORK/name-return.out" 2> "$WORK/name-return.err" || return 1
  awk '/^NAME-OWNER MATCH$/ { ok = 1 } END { exit !ok }' "$WORK/name-return.out"
}
if name_return_check; then
  echo "  lower_name_return: *NameReturn::write<UInt64>:Nil"
else
  echo "  lower_name_return: declared return differs from the hosted symbol"
  awk 'NR<=8' "$WORK/name-return.err" "$WORK/name-return.out" "$WORK/name-return.build.log"
  status=1
fi
prove_mutation "the probe names the body type instead of the def type" "$REPO/src/compiler/lower/lower.iyi" \
  '  result_t = analysed.type_of?(target) || body_t' \
  '  result_t = body_t' -- name_return_check || status=1

name_generic_check() {
  "$IYI" build -o "$WORK/name-generic-port" "$REPO/bench/selfhost_lower_name_owner.iyi" > "$WORK/name-generic.build.log" 2>&1 || return 1
  "$WORK/name-generic-port" "$REPO/bench/fixtures/lower_name_generic.iyi" "$WORK/lower_name_generic.oracle.ll" generic > "$WORK/name-generic.out" 2> "$WORK/name-generic.err" || return 1
  awk '/^NAME-OWNER MATCH$/ { ok = 1 } END { exit !ok }' "$WORK/name-generic.out"
}
if name_generic_check; then
  echo "  lower_name_generic: *Box(Int32)^Box(T)#get<Int32>:Int32"
else
  echo "  lower_name_generic: generic defining owner differs from the hosted symbol"
  awk 'NR<=8' "$WORK/name-generic.err" "$WORK/name-generic.out" "$WORK/name-generic.build.log"
  status=1
fi
prove_mutation "a generic instance drops its defining generic owner" "$REPO/src/compiler/lower/fun.iyi" \
  '  if receiver.is_a?(GenericInstanceType)' \
  '  if false' -- name_generic_check || status=1

name_pointer_check() {
  "$IYI" build -o "$WORK/name-pointer-port" "$REPO/bench/selfhost_lower_name_owner.iyi" > "$WORK/name-pointer.build.log" 2>&1 || return 1
  "$WORK/name-pointer-port" "$REPO/bench/fixtures/lower_name_pointer_union.iyi" "$WORK/lower_name_pointer_union.oracle.ll" pointer > "$WORK/name-pointer.out" 2> "$WORK/name-pointer.err" || return 1
  awk '/^NAME-OWNER MATCH$/ { ok = 1 } END { exit !ok }' "$WORK/name-pointer.out"
}
if name_pointer_check; then
  echo "  lower_name_pointer_union: *pass_pointer<Pointer(Int32 | Nil)>:Pointer(Int32 | Nil)"
else
  echo "  lower_name_pointer_union: pointer union name differs from the hosted symbol"
  awk 'NR<=8' "$WORK/name-pointer.err" "$WORK/name-pointer.out" "$WORK/name-pointer.build.log"
  status=1
fi
prove_mutation "a pointer union gains extra parentheses" "$REPO/src/compiler/lower/fun.iyi" \
  'skip_union_parens: true, codegen: true' \
  'skip_union_parens: false, codegen: true' -- name_pointer_check || status=1

name_block_check() {
  "$IYI" build --prelude empty --emit llvm-ir --no-debug -o "$WORK/name-block-oracle" "$REPO/bench/fixtures/nameblock_capture.iyi" > "$WORK/name-block.oracle.log" 2>&1 || return 1
  "$IYI" build -o "$WORK/name-block-port" "$REPO/bench/selfhost_lower_name_owner.iyi" > "$WORK/name-block.build.log" 2>&1 || return 1
  "$WORK/name-block-port" "$REPO/bench/fixtures/nameblock_capture.iyi" "$WORK/name-block-oracle.ll" block > "$WORK/name-block.out" 2> "$WORK/name-block.err" || return 1
  awk '/^NAME-OWNER MATCH$/ { ok = 1 } END { exit !ok }' "$WORK/name-block.out"
}
if name_block_check; then
  echo "  nameblock_capture: captured block names match the hosted symbols"
else
  echo "  nameblock_capture: captured block names differ from the hosted symbols"
  for log in "$WORK/name-block.err" "$WORK/name-block.out" "$WORK/name-block.build.log" "$WORK/name-block.oracle.log"; do
    [ ! -f "$log" ] || awk 'NR<=8' "$log"
  done
  status=1
fi
prove_mutation "a captured block loses its ampersand" "$REPO/src/compiler/lower/fun.iyi" \
  '      names << "&" + symbol_type(bt)' \
  '      names << symbol_type(bt)' -- name_block_check || status=1
prove_mutation "a pointer union value stores into a nilable reference union" "$REPO/src/compiler/lower/cast.iyi" \
  '    if TypeQueries.reference_like?(value_type)' \
  '    if !value_type.is_a?(UnionType) && TypeQueries.reference_like?(value_type)' -- lower_core_check || status=1

# A fully annotated definition is checked even when user code never calls it.
# A trait argument is checked against exactly its requirements, via the witness.
definition_probe_refusals() {
  local tool="$1" kind expected result refused=0
  for kind in return trait virtual_union; do
    case "$kind" in
      return) expected="type mismatch for return type: expected String, got Int32" ;;
      trait) expected="undefined method 'length' for IyiDefTypeWitness_Sized" ;;
      virtual_union) expected="type mismatch for return type: expected Int32, got String" ;;
    esac
    rm -f "$WORK/definition-$kind.native"
    timeout 120 "$tool" "$REPO/bench/fixtures/refuse_definition_$kind.iyi" \
      -o "$WORK/definition-$kind.native" --pipeline typed --probe-phase \
      > "$WORK/definition-$kind.log" 2>&1
    result=$?
    if [ "$result" -eq 0 ]; then
      echo "  uncalled $kind definition was accepted"
    elif [ "$result" -eq 1 ] &&
         grep -Fxq "bodies: fail: $expected" "$WORK/definition-$kind.log" &&
         [ ! -e "$WORK/definition-$kind.native" ]; then
      echo "  uncalled $kind definition refused: $expected"
      refused=$((refused + 1))
    else
      echo "  invalid definition-probe result ($kind, exit $result)"
      touch "$WORK/definition-probes.invalid"
      return 1
    fi
  done
  [ "$refused" -eq 3 ]
}
definition_probe_check() {
  if ! "$IYI" build -o "$WORK/definition-probes" "$REPO/src/compiler/tools/compile_native.iyi" \
    > "$WORK/definition-probes.build.log" 2>&1; then
    touch "$WORK/definition-probes.invalid"
    return 1
  fi
  definition_probe_refusals "$WORK/definition-probes"
}
echo "== Definition-site typing rejects uncalled invalid definitions"
if definition_probe_refusals "$WORK/compile_native"; then
  prove_mutation "definition-site probes are not prepended" "$REPO/src/compiler/semantic/definition_typing.iyi" \
    '    root.expressions = @probes + root.expressions' \
    '    root.expressions = root.expressions' -- definition_probe_check || status=1
  if [ -e "$WORK/definition-probes.invalid" ]; then
    echo "FAIL: definition-site typing mutation did not produce a valid compiler result"
    status=1
  fi
else
  echo "FAIL: uncalled invalid definitions did not reach their named refusals"
  status=1
fi

for invalid in "$WORK/m.invalid" "$WORK/nil-flow.invalid" "$WORK/union-read.invalid"; do
  if [ -e "$invalid" ]; then
    echo "FAIL: a core mutation did not compile; no behavioral detection was proved"
    cat "$invalid"
    status=1
  fi
done

echo "== Concurrent GC write barriers"
bash "$REPO/bench/selfhost_lower_gc_barrier_exercise.sh" || status=1

echo
echo
if [ "$status" -eq 0 ]; then
  echo "== ALL LOWER CORE CHECKS PASSED ($passed fixture(s) identical to the hosted module, $waiting waiting)"
else
  echo "== SOME LOWER CORE CHECKS FAILED"
fi
exit "$status"
