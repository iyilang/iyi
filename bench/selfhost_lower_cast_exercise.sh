#!/usr/bin/env bash
# Fails when the typed lowering of stores into mixed unions (src/compiler/lower/cast.iyi)
# stops agreeing with the hosted code generator's module for the same fixture.
#
# For each fixture (bench/fixtures/lowcast_*.iyi) the hosted compiler builds the program
# against --prelude empty, with --emit llvm-ir and --no-debug. The module is normalised by the
# shared oracle awk (bench/lib/lower_oracle.sh), read through the port's IR text parser, and
# compared function by function with the port's lowering (bench/lib/lower_gate.iyi).
#
# A fixture the port lowers identically is built natively and run: its exit status must equal
# the hosted executable's. A fixture waiting on another slice is WAITING, and the reason is
# named in waiting_on below; it is counted, never silently passed.
#
# Mutation proofs patch the ported code, rebuild the driver, and require the check to fail on
# a fixture that the unmutated port lowers identically. While no fixture is identical, the
# mutations cannot be proven, and the gate fails and says so: it does not pass on nothing.
#
#   bash bench/selfhost_lower_cast_exercise.sh
set -u
status=0
readonly REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then echo 'FAIL: a functional Python interpreter is required' >&2; exit 1; fi
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
IYI="$REPO/bin/iyi"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/lower_oracle.sh"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")" || exit 1

trap 'rm -rf "$WORK"' EXIT

# A failed compiler build is an invalid mutation proof, not a detected mutant.
cast_build() {
  if ! "$IYI" build "$@" > "$WORK/cast-build.log" 2>&1; then
    : > "$WORK/cast-mutant-build-failed"
    cat "$WORK/cast-build.log"
    return 2
  fi
}

cast_prove_mutation() {
  local mode="$1" label="$2" rc=0
  shift
  rm -f "$WORK/cast-mutant-build-failed"
  _prove_mutation_run "$mode" "$@" > "$WORK/cast-mutation.out" 2>&1 || rc=$?
  if [ -f "$WORK/cast-mutant-build-failed" ]; then
    echo "    NOT PROVEN: $label did not produce a valid mutant result"
    cat "$WORK/cast-mutation.out"
    [ ! -f "$WORK/cast-build.log" ] || cat "$WORK/cast-build.log"
    return 1
  fi
  cat "$WORK/cast-mutation.out"
  return "$rc"
}
prove_mutation() { cast_prove_mutation first "$@"; }
prove_mutation_all() { cast_prove_mutation all "$@"; }

echo "== 1. Building the port driver"
if ! "$IYI" build -o "$WORK_NATIVE/port$EXE" "$REPO_NATIVE/bench/selfhost_lower_cast_exercise.iyi" > "$WORK/port.build.log" 2>&1; then
  echo "  the port driver does not build"
  cat "$WORK/port.build.log"
  exit 1
fi
echo "  driver built"
if "$WORK/port$EXE" wrong_union_member > "$WORK/wrong_union.out" 2> "$WORK/wrong_union.err"; then
  echo "  FAIL: mixed union accepted a non-member"
  status=1
elif grep -Fq 'Char to (Bool | Int32): not a member' "$WORK/wrong_union.err"; then
  echo "  non-member mixed union store refused"
else
  echo "  FAIL: non-member store did not reach the membership refusal"
  status=1
fi
if "$WORK/port$EXE" union_representations > "$WORK/union-representations.out" 2> "$WORK/union-representations.err"; then
  echo "  plain and specialized mixed union aggregates produce valid IR and dynamic tags"
else
  echo "  FAIL: union representation probe"
  cat "$WORK/union-representations.err"
  status=1
fi
if "$WORK/port$EXE" tuple_downcast_inputs > "$WORK/tuple-inputs.out" 2> "$WORK/tuple-inputs.err"; then
  echo "  tuple and named-tuple inputs use fresh storage without extra copies; exact union members are readable"
else
  echo "  FAIL: tuple downcast input probe"
  cat "$WORK/tuple-inputs.err"
  status=1
fi
for mode in tuple_compatible_member named_tuple_compatible_member; do
  case "$mode" in
    tuple_compatible_member) expected='to Tuple(Int32, Int32) (hosted downcast_distinct, compatible tuple member)' ;;
    named_tuple_compatible_member) expected='to NamedTuple(b: Int32, a: Int32) (hosted downcast_distinct, compatible tuple member)' ;;
  esac
  if "$WORK/port$EXE" "$mode" > "$WORK/$mode.out" 2> "$WORK/$mode.err"; then
    echo "  FAIL: $mode accepted a non-member"
    status=1
  elif grep -Fq "$expected" "$WORK/$mode.err"; then
    echo "  $mode refused"
  else
    echo "  FAIL: $mode did not reach its compatible-member refusal"
    cat "$WORK/$mode.err"
    status=1
  fi
done
for mode in tuple_indirect_element named_tuple_indirect_element; do
  if "$WORK/port$EXE" "$mode" > "$WORK/$mode.out" 2> "$WORK/$mode.err"; then
    echo "  FAIL: $mode accepted an indirectly passed element"
    status=1
  elif grep -Fq 'downcast element Tuple(Int64, Int64' "$WORK/$mode.err" &&
       grep -Fq 'passed indirectly (hosted store_value, copy_value)' "$WORK/$mode.err"; then
    echo "  $mode refused"
  else
    echo "  FAIL: $mode did not reach its indirect-element refusal"
    cat "$WORK/$mode.err"
    status=1
  fi
done
for mode in tuple_size_mismatch named_tuple_size_mismatch named_tuple_missing_key; do
  case "$mode" in
    tuple_size_mismatch) expected='BUG: tuple sizes differ in downcast' ;;
    named_tuple_size_mismatch) expected='BUG: named tuple sizes differ in downcast' ;;
    named_tuple_missing_key) expected='BUG: named tuple key missing' ;;
  esac
  if "$WORK/port$EXE" "$mode" > "$WORK/$mode.out" 2> "$WORK/$mode.err"; then
    echo "  FAIL: $mode accepted an incompatible shape"
    status=1
  elif grep -Fq "$expected" "$WORK/$mode.err"; then
    echo "  $mode refused"
  else
    echo "  FAIL: $mode did not reach its shape refusal"
    cat "$WORK/$mode.err"
    status=1
  fi
done

# lowcast_proc_result types after s1d-bodies 5c5075083 and must pass.
# lowcast_struct_union waits on the union-in-generic type-id spelling.
waiting_on() {
  case "$1" in
    lowcast_struct_union) echo "Pointer((Robot | User)).class:type_id vs hosted Pointer(Robot | User).class:type_id (S1b29Declarations renderer 063610ce)" ;;
  esac
}

echo
echo "== 2. Each fixture: the hosted module against the port's lowering"
passed=0
e2e=""
diverged=0
waiting=0
for fixture in "$REPO"/bench/fixtures/lowcast_*.iyi "$REPO"/bench/fixtures/lowdowncast_nilable_as.iyi "$REPO"/bench/fixtures/lowdowncast_checked_oracle.iyi; do
  name="$(basename "$fixture" .iyi)"
  oracle_target=()
  oracle_output="$WORK_NATIVE/$name$EXE"
  if [ "$HOST_ID" != darwin-arm64 ]; then
    oracle_target=(--cross-compile --target aarch64-apple-darwin)
    oracle_output="$WORK_NATIVE/$name.o"
  fi
  if ! "$IYI" build "${oracle_target[@]}" --prelude empty --emit llvm-ir --no-debug -o "$oracle_output" "$(native_path "$fixture")" > "$WORK/$name.oracle.log" 2>&1 || [ ! -s "$WORK/$name.ll" ]; then
    echo "  $name: the hosted compiler did not emit its module (see $WORK/$name.oracle.log)"
    diverged=$((diverged + 1))
    continue
  fi
  awk "$CALL_TYPES" "$WORK/$name.ll" > "$WORK/$name.oracle.ll"

  if ! "$WORK/port$EXE" lower "$(native_path "$fixture")" "$WORK_NATIVE/$name.oracle.ll" > "$WORK/$name.port.out" 2> "$WORK/$name.port.err"; then
    if [ -n "$(waiting_on "$name")" ]; then
      if ! grep -Fq 'expected type Proc(Nil), got Proc(Int32)' "$WORK/$name.port.err"; then
        echo "  $name: stopped refusing by the named typing error: $(awk 'NR==1' "$WORK/$name.port.err")"
        diverged=$((diverged + 1))
        continue
      fi
      echo "  $name: WAITING, $(waiting_on "$name"): $(awk 'NR==1' "$WORK/$name.port.err")"
      waiting=$((waiting + 1))
      continue
    fi
    echo "  $name: REFUSED: $(awk 'NR==1' "$WORK/$name.port.err")"
    diverged=$((diverged + 1))
    continue
  fi
  echo "  $name:"
  awk '!/^SUMMARY/ { print "    " $0 }' "$WORK/$name.port.out"
  summary="$(awk '/^SUMMARY/ { print }' "$WORK/$name.port.out")"
  identical="$(echo "$summary" | awk '{ split($2, a, "="); print a[2] }')"
  total="$(echo "$summary" | awk '{ split($3, a, "="); print a[2] }')"
  if [ -n "$total" ] && [ "$total" -gt 0 ] && [ "$identical" = "$total" ]; then
    if [ -n "$(waiting_on "$name")" ]; then
      echo "    $name: passes now: take it off waiting_on in this gate"
      diverged=$((diverged + 1))
    fi
    echo "    $name: PASSED, $identical of $total functions identical"
    passed=$((passed + 1))
    e2e="$e2e $name"
  elif [ -n "$(waiting_on "$name")" ]; then
    echo "    $name: WAITING, $(waiting_on "$name"): $identical of $total functions identical"
    waiting=$((waiting + 1))
  else
    echo "    $name: DIVERGED, $identical of $total functions identical"
    diverged=$((diverged + 1))
  fi
done
echo "  fixtures: $passed passed, $waiting waiting (named above), $diverged diverged or refused"
if [ "$diverged" -gt 0 ] || [ "$passed" -eq 0 ]; then
  status=1
fi

echo
echo "== 3. End to end: each fixture the port lowers identically, built natively and run"
e2e_pass=0
e2e_fail=0
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "casts: AArch64 Mach-O signing and native execution require macOS arm64; $HOST_ID compares IR and emits Mach-O"
fi
if "$IYI" build -o "$WORK_NATIVE/compile_native$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/tool.build.log" 2>&1; then
  for name in $e2e; do
    fixture="$REPO_NATIVE/bench/fixtures/$name.iyi"
    if [ "$HOST_ID" = darwin-arm64 ]; then
      if ! "$IYI" build --prelude empty --no-debug -o "$WORK_NATIVE/$name.hosted$EXE" "$fixture" > "$WORK/$name.hosted.log" 2>&1; then
        echo "  $name: the hosted compiler cannot build it"
        cat "$WORK/$name.hosted.log"
        e2e_fail=$((e2e_fail + 1))
        continue
      fi
      "$WORK/$name.hosted$EXE" > "$WORK/$name.hosted.out" 2>&1
      hs=$?
    fi
    if ! "$WORK/port$EXE" emit "$fixture" "$WORK_NATIVE/$name.oracle.ll" > "$WORK/$name.port.ll" 2> "$WORK/$name.emit.err"; then
      echo "  $name: the port writes no module: $(awk 'NR==1' "$WORK/$name.emit.err")"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    if ! "$WORK/compile_native$EXE" "$WORK_NATIVE/$name.port.ll" -o "$WORK_NATIVE/$name.native" > "$WORK/$name.native.log" 2>&1; then
      echo "  $name: the native tool refuses it: $(awk 'NR==1' "$WORK/$name.native.log")"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    if [ "$HOST_ID" != darwin-arm64 ]; then
      echo "  $name: AArch64 Mach-O emitted; native execution is host-limited"
      continue
    fi
    if ! codesign -v --strict "$WORK/$name.native"; then
      echo "  $name: native executable failed signature validation"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    "$WORK/$name.native" > "$WORK/$name.native.out" 2>&1
    ns=$?
    if [ "$ns" -eq "$hs" ] && cmp -s "$WORK/$name.hosted.out" "$WORK/$name.native.out"; then
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

echo
echo "== Getter union casts: typed source to native against hosted"
getter_fixture="$REPO_NATIVE/bench/fixtures/getter_union_cast.iyi"
getter_ready=0
if "$IYI" build --prelude empty --no-debug -o "$WORK_NATIVE/getter.hosted$EXE" "$getter_fixture" > "$WORK/getter.hosted.log" 2>&1; then
  "$WORK/getter.hosted$EXE" > "$WORK/getter.hosted.out" 2>&1; getter_hosted=$?
  "$WORK/getter.hosted$EXE" wrong > "$WORK/getter.hosted-wrong.out" 2>&1; getter_hosted_wrong=$?
  if [ "$getter_hosted" -eq 97 ] && [ "$getter_hosted_wrong" -eq 91 ]; then
    getter_ready=1
  else
    echo "  FAIL: hosted fixture returned $getter_hosted and $getter_hosted_wrong, expected 97 and 91"
    status=1
  fi
else
  echo "  FAIL: hosted getter fixture did not build"
  tail -n 20 "$WORK/getter.hosted.log"
  status=1
fi

getter_native_check() {
  local tool="$1" result wrong
  if ! "$tool" "$getter_fixture" -o "$WORK_NATIVE/getter.ir" --pipeline typed --probe-phase --emit ir > "$WORK/getter.ir.log" 2>&1; then
    echo 'INVALID: getter fixture did not emit IR'
    cat "$WORK/getter.ir.log"
    : > "$WORK/cast-mutant-build-failed"
    return 2
  fi
  rm -f "$WORK/getter.native"
  if ! "$tool" "$getter_fixture" -o "$WORK_NATIVE/getter.native" --pipeline typed --probe-phase > "$WORK/getter.native.log" 2>&1; then
    echo 'INVALID: getter fixture did not emit Mach-O'
    cat "$WORK/getter.native.log"
    : > "$WORK/cast-mutant-build-failed"
    return 2
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then
    if [ ! -f "$WORK/getter.baseline.ir" ]; then
      cp "$WORK/getter.ir" "$WORK/getter.baseline.ir"
      return 0
    fi
    cmp -s "$WORK/getter.baseline.ir" "$WORK/getter.ir"
    return $?
  fi
  if ! codesign -v --strict "$WORK/getter.native"; then
    : > "$WORK/cast-mutant-build-failed"
    return 2
  fi
  "$WORK/getter.native" > "$WORK/getter.native.out" 2>&1; result=$?
  "$WORK/getter.native" wrong > "$WORK/getter.native-wrong.out" 2>&1; wrong=$?
  printf '%s %s\n' "$result" "$wrong" > "$WORK/getter.native.status"
  [ "$result" -eq "$getter_hosted" ] && [ "$wrong" -eq "$getter_hosted_wrong" ] &&
    cmp -s "$WORK/getter.hosted.out" "$WORK/getter.native.out" &&
    cmp -s "$WORK/getter.hosted-wrong.out" "$WORK/getter.native-wrong.out"
}

if [ "$getter_ready" -eq 1 ] && getter_native_check "$WORK/compile_native$EXE"; then
  if [ "$HOST_ID" = darwin-arm64 ]; then
    echo "  getter casts, nilable casts, is_a? and local union agree: success 97, wrong cast 91"
  else
    echo "  hosted getter returned 97 and 91; typed AArch64 IR emitted"
  fi
else
  echo "  FAIL: getter union native result differs or did not build"
  [ ! -f "$WORK/getter.native.log" ] || tail -n 20 "$WORK/getter.native.log"
  [ ! -f "$WORK/getter.native.status" ] || cat "$WORK/getter.native.status"
  status=1
fi

echo
echo "== 4. Mutation proofs: the gate must catch each patch to the ported code"
# The check rebuilds the driver from the patched source and requires the mixed-union fixture
# to be identical to the hosted module, which holds only when the store helpers are right.
getter_mutation_check() {
  cast_build -o "$WORK_NATIVE/getter-mutant$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/getter-mutant.build.log" 2>&1 || return 2
  getter_native_check "$WORK/getter-mutant$EXE"
}
if [ "$getter_ready" -eq 1 ]; then
  rm -f "$WORK/getter.native.status"
  prove_mutation "getter unions lose their runtime type tag" "$REPO/src/compiler/lower/cast.iyi" \
    '  if mixed_union_type?(rt)' '  if false' -- getter_mutation_check || status=1
  if [ "$HOST_ID" = darwin-arm64 ] && { [ ! -f "$WORK/getter.native.status" ] || [ "$(cat "$WORK/getter.native.status")" != "91 91" ]; }; then
    echo "  NOT PROVEN: the getter mutant did not build and reject the valid cast"
    status=1
  fi
fi
cast_check() {
  cast_build -o "$WORK_NATIVE/mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_cast_exercise.iyi" > "$WORK/mut.build.log" 2>&1 || return 2
  "$WORK/mut$EXE" lower "$REPO_NATIVE/bench/fixtures/lowcast_mixed.iyi" "$WORK_NATIVE/lowcast_mixed.oracle.ll" > "$WORK/mut.out" 2> "$WORK/mut.err" || { cat "$WORK/mut.err"; return 2; }
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); exit !(a[2] == b[2] && a[2] > 0) }' "$WORK/mut.out" && return 0
  return 1
}
cast_check || { echo "  baseline: mixed union differs"; status=1; }
prove_mutation "mixed union tag padding is not cleared" "$REPO/src/compiler/lower/cast.iyi" \
  '    clear_hole_range(low, pointer, 4_i64, value_offset, alignment)' \
  '    clear_hole_range(low, pointer, value_offset, value_offset, alignment)' -- cast_check || status=1
prove_mutation "mixed union payload padding is not cleared" "$REPO/src/compiler/lower/cast.iyi" \
  '    clear_hole_range(low, pointer, value_offset + payload, size, alignment)' \
  '    clear_hole_range(low, pointer, size, size, alignment)' -- cast_check || status=1


new_cast_check() {
  cast_build -o "$WORK_NATIVE/mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_cast_exercise.iyi" > "$WORK/mut.build.log" 2>&1 || return 2
  "$WORK/mut$EXE" lower "$REPO_NATIVE/bench/fixtures/lowcast_$cast_fixture.iyi" "$WORK_NATIVE/lowcast_$cast_fixture.oracle.ll" > "$WORK/mut.out" 2> "$WORK/mut.err" || { cat "$WORK/mut.err"; return 2; }
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); exit !(a[2] == b[2] && a[2] > 0) }' "$WORK/mut.out"
}

cast_refusal_check() {
  local fixture="$1" message="$2" built_marker="${3:-}" result=0 first
  if ! awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); if (a[2] == b[2] && b[2] > 0) ok=1 } END { exit !ok }' "$WORK/lowcast_$fixture.port.out"; then
    echo "INVALID: lowcast_$fixture has no passing comparison baseline"
    return 2
  fi
  cast_build -o "$WORK_NATIVE/mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_cast_exercise.iyi" > "$WORK/mut.build.log" 2>&1 || return 2
  [ -z "$built_marker" ] || : > "$WORK/$built_marker"
  "$WORK/mut$EXE" lower "$REPO_NATIVE/bench/fixtures/lowcast_$fixture.iyi" "$WORK_NATIVE/lowcast_$fixture.oracle.ll" > "$WORK/mut.out" 2>"$WORK/mut.err" || result=$?
  if [ "$result" -eq 0 ]; then return 0; fi
  first="$(awk 'NR == 1 { print; exit }' "$WORK/mut.err")"
  if [ "$result" -eq 1 ] && [ "$first" = "iyi: panic: $message" ] &&
     [ "$(refusal_site "$WORK/mut.err")" = "src/compiler/lower/pending.iyi:15" ]; then
    echo "decisive: lowcast_$fixture: $message"
    return 1
  fi
  echo "INVALID: lowcast_$fixture failed outside its expected refusal"
  cat "$WORK/mut.out" "$WORK/mut.err"
  return 2
}

checked_downcast_check() {
  cast_build -o "$WORK_NATIVE/mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_cast_exercise.iyi" > "$WORK/mut.build.log" 2>&1 || return 2
  "$WORK/mut$EXE" lower "$REPO_NATIVE/bench/fixtures/lowdowncast_checked_oracle.iyi" "$WORK_NATIVE/lowdowncast_checked_oracle.oracle.ll" > "$WORK/mut.out" 2> "$WORK/mut.err" || { cat "$WORK/mut.err"; return 2; }
  awk '/^SUMMARY/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/mut.out" || return 1
  "$WORK/mut$EXE" emit "$REPO_NATIVE/bench/fixtures/lowdowncast_checked_oracle.iyi" "$WORK_NATIVE/lowdowncast_checked_oracle.oracle.ll" > "$WORK/checked-port.ir" 2> "$WORK/mut.err" || { cat "$WORK/mut.err"; return 2; }
  "$PY" "$REPO_NATIVE/bench/compare_downcast_metadata.py" "$WORK_NATIVE/lowdowncast_checked_oracle.ll" "$WORK_NATIVE/checked-port.ir"
}
checked_downcast_check || { echo "  baseline: checked cast metadata differs"; status=1; }
prove_mutation "checked cast swaps target and location" "$REPO/src/compiler/lower/primitives.iyi" \
  '  low.builder.call(raise_fn.fn_type, raise_fn, [from_name, to_name, location] of Value, "")' '  low.builder.call(raise_fn.fn_type, raise_fn, [from_name, location, to_name] of Value, "")' -- checked_downcast_check || status=1

nilable_downcast_check() {
  cast_build -o "$WORK_NATIVE/mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_cast_exercise.iyi" > "$WORK/mut.build.log" 2>&1 || return 2
  "$WORK/mut$EXE" lower "$REPO_NATIVE/bench/fixtures/lowdowncast_nilable_as.iyi" "$WORK_NATIVE/lowdowncast_nilable_as.oracle.ll" > "$WORK/mut.out" 2> "$WORK/mut.err" || { cat "$WORK/mut.err"; return 2; }
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); exit !(a[2] == b[2] && a[2] > 0) }' "$WORK/mut.out"
}
nilable_downcast_check || { echo "  baseline: nilable reference downcast differs"; status=1; }
prove_mutation "nilable reference downcast reads the local slot instead of its value" "$REPO/src/compiler/lower/lower.iyi" \
  '    down_source = last_value' '    down_source = low.current_context.vars[node.obj.as(Var).name].pointer' -- nilable_downcast_check || status=1
alias_union_native_check() {
  cast_build -o "$WORK_NATIVE/alias-stage1$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/alias-build.log" 2>&1 || return 2
  if ! "$WORK/alias-stage1$EXE" "$REPO_NATIVE/bench/fixtures/lowcast_struct_union_nil.iyi" -o "$WORK_NATIVE/alias.ir" --pipeline typed --prelude --emit ir > "$WORK/alias-native.log" 2>&1; then
    cat "$WORK/alias-native.log"
    return 2
  fi
  "$WORK/alias-stage1$EXE" "$REPO_NATIVE/bench/fixtures/lowcast_struct_union_nil.iyi" -o "$WORK_NATIVE/alias-native" --pipeline typed --prelude > "$WORK/alias-native.log" 2>&1 || { cat "$WORK/alias-native.log"; return 2; }
  if [ "$HOST_ID" != darwin-arm64 ]; then return 0; fi
  codesign -v --strict "$WORK/alias-stage1$EXE" || return 2
  codesign -v --strict "$WORK/alias-native" || return 1
  "$WORK/alias-native"
  [ "$?" -eq 10 ]
}
representation_mutation_check() {
  cast_build -o "$WORK_NATIVE/representation-mutant$EXE" "$REPO_NATIVE/bench/selfhost_lower_cast_exercise.iyi" > "$WORK/representation-mutant.build.log" 2>&1 || return 2
  "$WORK/representation-mutant$EXE" union_representations > "$WORK/representation-mutant.out" 2> "$WORK/representation-mutant.err"
  local result=$?
  if [ "$result" -eq 0 ]; then return 0; fi
  if expected_refusal "$result" "$WORK/representation-mutant.err" src/compiler/lower/pending.iyi 'assign Int32 to \(Bool \| Int32\)'; then return 1; fi
  echo 'INVALID: representation mutant did not reach its named assignment refusal'
  cat "$WORK/representation-mutant.err"
  return 2
}
alias_union_native_check || { echo "  baseline: native aliased struct union differs"; status=1; }
prove_mutation "plain union loses mixed specialization" "$REPO/src/compiler/lower/cast.iyi" \
  '  if type.is_a?(UnionType) && !type.is_a?(MixedUnionType) && !type.is_a?(NilableProcType) && !reference_union?(type.as(UnionType))' '  if false' -- representation_mutation_check || status=1
cast_fixture=compatible_virtual
new_cast_check || { echo "  baseline: compatible virtual union differs"; status=1; }
prove_mutation "compatible virtual union member is refused" "$REPO/src/compiler/lower/cast.iyi" \
  '  if !member && TypeQueries.reference_like?(value_type)' '  if false' -- cast_refusal_check compatible_virtual 'lower: visit(assign Sub to (Base+ | Other): not a member (hosted cast.cr, compatible type)) (hosted codegen.cr) is not ported yet' || status=1
cast_fixture=tuple_upcast
new_cast_check || { echo "  baseline: tuple widening differs"; status=1; }
prove_mutation "tuple widening is refused" "$REPO/src/compiler/lower/cast.iyi" \
  '  if target.is_a?(TupleInstanceType) && value_type.is_a?(TupleInstanceType)' '  if false' -- cast_refusal_check tuple_upcast 'lower: visit(assign Tuple(Int32, String) to Tuple(Int32, String | Nil) (hosted assign_distinct, not ported)) (hosted codegen.cr) is not ported yet' || status=1
cast_fixture=named_tuple_upcast
new_cast_check || { echo "  baseline: named tuple widening differs"; status=1; }
prove_mutation "named tuple widening is refused" "$REPO/src/compiler/lower/cast.iyi" \
  '  if target.is_a?(NamedTupleInstanceType) && value_type.is_a?(NamedTupleInstanceType)' '  if false' -- cast_refusal_check named_tuple_upcast 'lower: visit(assign NamedTuple(count: Int32, text: String) to NamedTuple(count: Int32, text: String | Nil) (hosted assign_distinct, not ported)) (hosted codegen.cr) is not ported yet' || status=1
cast_fixture=tuple_upcast
new_cast_check || { echo "  baseline: tuple widening differs"; status=1; }
prove_mutation "tuple upcast is refused" "$REPO/src/compiler/lower/cast.iyi" \
  '  if (t.is_a?(TupleInstanceType) && f.is_a?(TupleInstanceType)) || (t.is_a?(NamedTupleInstanceType) && f.is_a?(NamedTupleInstanceType))' '  if false' -- cast_refusal_check tuple_upcast 'lower: visit(upcast Tuple(Int32, String) to Tuple(Int32, String | Nil) (hosted cast.cr: upcast_distinct)) (hosted codegen.cr) is not ported yet' || status=1
cast_fixture=tuple_narrow
new_cast_check || { echo "  baseline: tuple narrowing differs"; status=1; }
if ! awk '/^SUMMARY/ { split($4, a, "="); if (a[2] == 1) ok=1 } END { exit !ok }' "$WORK/mut.out"; then
  echo "  baseline: tuple narrowing module differs"
  status=1
fi
if grep -Eq '^  @.*: EXTRA in the port$' "$WORK/mut.out"; then
  echo "  baseline: tuple narrowing contains extra functions"
  status=1
fi
rm -f "$WORK/mut.out"
prove_mutation "named tuple narrowing uses the source field index" "$REPO/src/compiler/lower/cast.iyi" \
  '    target_ptr = aggregate_field(low, target, result, j)' '    target_ptr = aggregate_field(low, target, result, i)' -- new_cast_check || status=1
if [ ! -f "$WORK/mut.out" ] || ! awk '
  /named_order.*: differs at line/ { named=1 }
  /^SUMMARY/ { split($2, a, "="); split($3, b, "="); if (b[2] > 0 && a[2] < b[2]) summary=1 }
  END { exit !(named && summary) }
' "$WORK/mut.out"; then
  echo "  NOT PROVEN: named tuple index mutant did not produce a named_order IR difference"
  status=1
fi
cast_fixture=virtual_store
new_cast_check || { echo "  baseline: virtual assignment differs"; status=1; }
prove_mutation "virtual target assignment is refused" "$REPO/src/compiler/lower/cast.iyi" \
  '  if target.is_a?(VirtualType) || target.is_a?(VirtualMetaclassType)' '  if false' -- cast_refusal_check virtual_store 'lower: visit(assign Leaf to Node+ (hosted assign_distinct, not ported)) (hosted codegen.cr) is not ported yet' || status=1
cast_fixture=nilable_mixed
new_cast_check || { echo "  baseline: nilable union assignment differs"; status=1; }
prove_mutation "nullable union stores a constant type id" "$REPO/src/compiler/lower/cast.iyi" \
  '    return low.builder.select(is_null, nil_id, other_id)' '    return other_id' -- new_cast_check || status=1
prove_mutation "nullable union assignment is refused" "$REPO/src/compiler/lower/cast.iyi" \
  '  if target.is_a?(MixedUnionType) && (value_type.is_a?(NilableType) || value_type.is_a?(ReferenceUnionType) || value_type.is_a?(NilableReferenceUnionType))' '  if false' -- cast_refusal_check nilable_mixed 'lower: visit(assign (Box | Nil) to (Bool | Box | Nil) (union into a non-mixed target, hosted assign_distinct)) (hosted codegen.cr) is not ported yet' || status=1
prove_mutation "nullable mixed read drops the stored pointer" "$REPO/src/compiler/lower/cast.iyi" \
  '  to_lhs(low, value_ptr, to_type)' '  low.builder.const_null(low.module.types.ptr)' -- new_cast_check || status=1
cast_fixture=enum_mixed
new_cast_check || { echo "  baseline: enum union assignment differs"; status=1; }
prove_mutation "enum union stores are refused" "$REPO/src/compiler/lower/cast.iyi" \
  '  if kind == "int" || kind == "char" || kind == "symbol" || kind == "float" || value_type.is_a?(EnumType)' '  if kind == "int" || kind == "char" || kind == "symbol" || kind == "float"' -- cast_refusal_check enum_mixed 'lower: visit(store of Vis in (Int32 | Vis) (hosted store_value, not ported)) (hosted codegen.cr) is not ported yet' || status=1
cast_fixture=union_to_subunion
new_cast_check || { echo "  baseline: mixed subunion downcast differs"; status=1; }
prove_mutation "mixed subunion reads its payload as the union" "$REPO/src/compiler/lower/cast.iyi" \
  '  if from_type.is_a?(MixedUnionType) && to_type.is_a?(MixedUnionType)' '  if false' -- new_cast_check || status=1
cast_fixture=union_realign
new_cast_check || { echo "  baseline: mixed subunion realignment differs"; status=1; }
prove_mutation "mixed subunion realignment loses payload" "$REPO/src/compiler/lower/cast.iyi" \
  '  count = low.builder.const_int(low.typer.size_t, size)' '  count = low.builder.const_int(low.typer.size_t, 0_i64)' -- new_cast_check || status=1
prove_mutation "wide boolean union store uses scalar alignment" "$REPO/src/compiler/lower/cast.iyi" \
  '    stored.alignment = low.typer.pointer_size.to_i32' '    stored.alignment = low.typer.align_of(widened.type)' -- new_cast_check || status=1
cast_fixture=virtual_range
new_cast_check || { echo "  baseline: virtual range differs"; status=1; }
prove_mutation "an IsA restriction loses its virtual range" "$REPO/src/compiler/lower/lower.iyi" \
  '  ct = TypeQueries.virtual_type(ct)' '  ct = TypeIndirection.remove_indirection(ct)' -- new_cast_check || status=1
prove_mutation "virtual range excludes its first type id" "$REPO/src/compiler/lower/cast.iyi" \
  '      lower = low.builder.icmp(IntPredicate::SGE, param_tid, min_id)' '      lower = low.builder.icmp(IntPredicate::SGT, param_tid, min_id)' -- new_cast_check || status=1
no_return_check() {
  cast_build -o "$WORK_NATIVE/mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_cast_exercise.iyi" > "$WORK/mut.build.log" 2>&1 || return 2
  "$WORK/mut$EXE" skip_noreturn > "$WORK/mut.out" 2> "$WORK/mut.err"
  local result=$?
  if [ "$result" -eq 0 ]; then return 0; fi
  if expected_refusal "$result" "$WORK/mut.err" src/compiler/lower/pending.iyi 'assign NoReturn to \(Bool \| Int32\): not a member'; then return 1; fi
  echo 'INVALID: NoReturn mutant did not reach its named union-member refusal'
  cat "$WORK/mut.err"
  return 2
}
struct_union_check() {
  cast_build -o "$WORK_NATIVE/mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_cast_exercise.iyi" > "$WORK/mut.build.log" 2>&1 || return 2
  : > "$WORK/struct_mutant_built"
  "$WORK/mut$EXE" lower "$REPO_NATIVE/bench/fixtures/lowcast_struct_union.iyi" "$WORK_NATIVE/lowcast_struct_union.oracle.ll" > "$WORK/mut.out" 2> "$WORK/mut.err" || { cat "$WORK/mut.err"; return 2; }
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); exit !(a[2] == b[2] && a[2] > 0) }' "$WORK/mut.out"
}
if [ -n "$(waiting_on lowcast_struct_union)" ]; then
  if ! grep -Fq 'Pointer((Robot | User)).class:type_id' "$WORK/lowcast_struct_union.port.out"; then
    echo "  NOT PROVEN: struct union stopped showing the named renderer difference"
    status=1
  else
    echo "  struct union remains the named renderer difference"
  fi
else
  struct_union_check || { echo "  baseline: struct union fixture differs"; status=1; }
  rm -f "$WORK/struct_mutant_built"
  prove_mutation "a struct is refused from a mixed union" "$REPO/src/compiler/lower/cast.iyi" \
    '  if value_type.struct? && passed_by_value?(value_type)' '  if false' -- struct_union_check || status=1
  if [ ! -f "$WORK/struct_mutant_built" ]; then
    echo "  NOT PROVEN: struct union mutant failed to build"
    status=1
  fi
fi
aggregate_behavior_check() {
  cast_build -o "$WORK_NATIVE/aggregate_mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_cast_exercise.iyi" > "$WORK/aggregate_mut.build.log" 2>&1 || return 2
  "$WORK/aggregate_mut$EXE" emit "$REPO_NATIVE/bench/fixtures/lowcast_struct_union.iyi" "$WORK_NATIVE/lowcast_struct_union.oracle.ll" > "$WORK/aggregate_mut.ll" 2> "$WORK/aggregate_mut.emit.log" || { cat "$WORK/aggregate_mut.emit.log"; return 2; }
  "$WORK/compile_native$EXE" "$WORK_NATIVE/aggregate_mut.ll" -o "$WORK_NATIVE/aggregate_mut.native" > "$WORK/aggregate_mut.native.log" 2>&1 || { cat "$WORK/aggregate_mut.native.log"; return 2; }
  if [ "$HOST_ID" != darwin-arm64 ]; then
    if [ ! -f "$WORK/aggregate-baseline.ll" ]; then cp "$WORK/aggregate_mut.ll" "$WORK/aggregate-baseline.ll"; return 0; fi
    cmp -s "$WORK/aggregate-baseline.ll" "$WORK/aggregate_mut.ll"
    return $?
  fi
  codesign -v --strict "$WORK/aggregate_mut.native" || { echo 'INVALID: aggregate mutant signature failed'; return 2; }
  "$WORK/aggregate_mut.native" > "$WORK/aggregate_mut.out" 2>&1
  local result=$?
  echo "$result" > "$WORK/aggregate_mut.exit"
  [ "$result" -eq 7 ]
}
aggregate_behavior_check || { echo "  baseline: struct union native result differs"; status=1; }
rm -f "$WORK/aggregate_mut.exit"
prove_mutation "a union local receives a zero aggregate" "$REPO/src/compiler/lower/lower.iyi" \
  '      stored = load_aligned(low, low.typer.llvm_type(vt), v)' '      stored = low.builder.const_zero(low.typer.llvm_type(vt))' -- aggregate_behavior_check || status=1
if [ "$HOST_ID" = darwin-arm64 ] && { [ ! -f "$WORK/aggregate_mut.exit" ] || [ "$(cat "$WORK/aggregate_mut.exit")" != 200 ]; }; then
  echo "  NOT PROVEN: aggregate mutant did not build, link and exit 200"
  status=1
fi
proc_result_check() {
  cast_build -o "$WORK_NATIVE/mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_cast_exercise.iyi" > "$WORK/mut.build.log" 2>&1 || return 2
  : > "$WORK/proc_mutant_built"
  "$WORK/mut$EXE" lower "$REPO_NATIVE/bench/fixtures/lowcast_proc_result.iyi" "$WORK_NATIVE/lowcast_proc_result.oracle.ll" > "$WORK/mut.out" 2> "$WORK/mut.err" || { cat "$WORK/mut.err"; return 2; }
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); exit !(a[2] == b[2] && a[2] > 0) }' "$WORK/mut.out"
}
if [ -n "$(waiting_on lowcast_proc_result)" ]; then
  if ! grep -Fq 'expected type Proc(Nil), got Proc(Int32)' "$WORK/lowcast_proc_result.port.err"; then
    echo "  NOT PROVEN: proc result stopped refusing by the named typing error"
    status=1
  else
    echo "  proc result assignment remains the named typing refusal"
  fi
else
  proc_result_check || { echo "  baseline: proc result assignment fixture differs"; status=1; }
  rm -f "$WORK/proc_mutant_built"
  prove_mutation "a proc result assignment is refused" "$REPO/src/compiler/lower/cast.iyi" \
    '  if target.is_a?(ProcInstanceType) && value_type.is_a?(ProcInstanceType)' '  if false' -- cast_refusal_check proc_result 'lower: visit(assign Proc(Int32) to Proc(Nil) (hosted assign_distinct, not ported)) (hosted codegen.cr) is not ported yet' proc_mutant_built || status=1
  if [ ! -f "$WORK/proc_mutant_built" ]; then
    echo "  NOT PROVEN: proc result mutant failed to build"
    status=1
  fi
fi
nil_proc_check() {
  cast_build -o "$WORK_NATIVE/mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_cast_exercise.iyi" > "$WORK/mut.build.log" 2>&1 || return 2
  : > "$WORK/nil_proc_mutant_built"
  "$WORK/mut$EXE" lower "$REPO_NATIVE/bench/fixtures/lowcast_nil_proc.iyi" "$WORK_NATIVE/lowcast_nil_proc.oracle.ll" > "$WORK/mut.out" 2> "$WORK/mut.err" || { cat "$WORK/mut.err"; return 2; }
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); exit !(a[2] == b[2] && a[2] > 0) }' "$WORK/mut.out"
}
nil_proc_check || { echo "  baseline: nilable proc assignment fixture differs"; status=1; }
rm -f "$WORK/nil_proc_mutant_built"
prove_mutation "nil stored into a nilable proc is refused" "$REPO/src/compiler/lower/cast.iyi" \
  '  if target.is_a?(NilableProcType) && value_type.nil_type?' '  if false' -- cast_refusal_check nil_proc 'lower: visit(assign Nil to (Proc(Nil) | Nil) (hosted assign_distinct, not ported)) (hosted codegen.cr) is not ported yet' nil_proc_mutant_built || status=1
if [ ! -f "$WORK/nil_proc_mutant_built" ]; then
  echo "  NOT PROVEN: nilable proc mutant failed to build"
  status=1
fi

no_return_check || { echo "  baseline: no-return union fixture differs"; status=1; }
prove_mutation_all "a no-return union assignment stores a value" "$REPO/src/compiler/lower/cast.iyi" \
  '  return if at_terminator?(low) || TypeQueries.no_return?(value_type)' '  return if false' -- no_return_check || status=1
if [ "$passed" -eq 0 ]; then
  echo "  NOT PROVEN: no cast fixture is identical to the hosted module yet, so no mutation can be"
  echo "  shown to change the result. The three patches are listed in the gate's source; they run"
  echo "  as soon as lowcast_mixed (or another cast fixture) is identical."
  status=1
else
  prove_mutation "a true bool folds to zero" "$REPO/src/compiler/lower/cast.iyi" \
    "return low.builder.const_int(int_type, 1_i64)" "return low.builder.const_int(int_type, 0_i64)" -- cast_check || status=1
  prove_mutation "the value area is field zero" "$REPO/src/compiler/lower/cast.iyi" \
    "  index = low.builder.const_int(low.module.types.int32, 1_i64)" "  index = low.builder.const_int(low.module.types.int32, 0_i64)" -- cast_check || status=1
  prove_mutation "the type id load is not aligned" "$REPO/src/compiler/lower/cast.iyi" \
    "  load_aligned(low, low.module.types.int32, type_id_global(low, t))" "  low.builder.load(low.module.types.int32, type_id_global(low, t))" -- cast_check || status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL CAST LOWERING CHECKS PASSED"
else
  echo "CAST LOWERING GATE FAILED"
fi
exit "$status"
