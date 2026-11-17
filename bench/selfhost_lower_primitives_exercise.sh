#!/usr/bin/env bash
# Fails when the typed lowering of primitives (src/compiler/lower/primitives.iyi) stops
# agreeing with the hosted code generator's module for the same fixture.
#
# For each fixture (bench/fixtures/lowprim_*.iyi) the hosted compiler builds the program
# against --prelude empty, with --emit llvm-ir and --no-debug. The builtin primitives are
# the library's own (src/primitives.cr), so a fixture calls them directly and declares
# none. Its module is read through the port's IR text parser and printed by the port's
# printer. The port analyses the fixture (the builtin stand-in,
# bench/lib/primitive_stand_in.iyi, declares the library's builtin operators until the
# semantic pass does), lowers it, and prints the module. The two normalised texts are
# compared function by function (bench/lib/lower_gate.iyi, shared with the other gates).
#
# Each fixture the port lowers identically is then built to a native executable by the
# native tool and run: its exit status and stdout must equal the hosted executable's.
#
# Mutation proofs patch the ported code, rebuild the driver, and require the check to
# fail. A patch that changes nothing is refused by prove_mutation.
#
#   bash bench/selfhost_lower_primitives_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/lower_oracle.sh"
WORK="$(mktemp -d)"

trap 'rm -rf "$WORK"' EXIT
# LLVM writes switch cases on separate lines without separators; the IR reader
# accepts comma-separated cases on one line. Reject malformed input, not just
# unterminated switches, before handing it to the reader.
normalize_switches() {
  awk '
    in_switch {
      if ($0 ~ /^[[:space:]]*][[:space:]]*$/) { print line " ]"; in_switch=0; next }
      if ($0 !~ /^[[:space:]]*i[0-9]+ -?[0-9]+, label %[^[:space:]]+[[:space:]]*$/) { bad=1; exit 1 }
      sub(/^[[:space:]]*/, "")
      line=line (count++ ? ", " : " ") $0
      next
    }
    /switch .*\[$/ { line=$0; in_switch=1; count=0; next }
    { print }
    END { if (in_switch || bad) exit 1 }
  '
}
switch_result="$(printf '  switch i32 %%x, label %%else [\n    i32 1, label %%a\n    i32 2, label %%b\n  ]\n' | normalize_switches)"
if [ "$switch_result" != '  switch i32 %x, label %else [ i32 1, label %a, i32 2, label %b ]' ] ||
   printf 'switch i32 %%x, label %%else [\n i32 1, label %%a\n' | normalize_switches >/dev/null ||
   printf 'switch i32 %%x, label %%else [\n nonsense\n]\n' | normalize_switches >/dev/null; then
  echo "switch normalization regression"
  exit 1
fi


echo "== 1. Building the port driver"
if ! "$IYI" build -o "$WORK/port" "$REPO/bench/selfhost_lower_primitives_exercise.iyi" > "$WORK/port.build.log" 2>&1; then
  echo "the port driver failed to build:"
  awk '!/^ld: warning/ && NR<=20' "$WORK/port.build.log"
  exit 1
fi
echo "  driver built"

echo
echo "== 2. Each fixture: the hosted module against the port's lowering"
passed=0
e2e=""
diverged=0
waiting=0
# Fixtures that wait on a NEEDS.md row, by name. The port refuses them and the gate reports them
# WAITING, naming the row; a waiting fixture that starts to pass fails the gate until it is
# taken off this list, so a wait cannot outlive its cause unnoticed.
waiting_on() {
  case "$1" in
  esac
}

# Fixtures that lower with a known divergence, named, not yet fixed. The gate fails if one starts to match,
# so the list stays honest.
known_divergence() {
  case "$1" in
  esac
}
# Fixtures identical to the hosted module whose native executable waits by name. None now: defs are emitted Iyi
# (fun.iyi), so the native tool builds lowprim_alloc_struct.
e2e_waiting_on() {
  case "$1" in
  esac
}
for fixture in "$REPO"/bench/fixtures/lowprim_*.iyi; do
  name="$(basename "$fixture" .iyi)"
  oracle_options=(--prelude empty)
  if [ "$name" = "lowprim_atomic_rmw" ]; then
    # Otherwise the hosted module is printed after LLVM has expanded atomicrmw to a cmpxchg loop.
    oracle_options+=(--mattr +lse)
    echo "  $name: oracle uses --mattr +lse to preserve atomicrmw in the emitted module"
  fi
  if ! "$IYI" build "${oracle_options[@]}" --emit llvm-ir --no-debug -o "$WORK/$name" "$fixture" > "$WORK/$name.oracle.log" 2>&1 || [ ! -s "$WORK/$name.ll" ]; then
    echo "  $name: the hosted compiler did not emit its module (see $WORK/$name.oracle.log)"
    diverged=$((diverged + 1))
    continue
  fi
  if ! awk "$CALL_TYPES" "$WORK/$name.ll" | normalize_switches > "$WORK/$name.oracle.ll"; then
    echo "  $name: malformed switch in hosted module"
    diverged=$((diverged + 1))
    continue
  fi

  if ! "$WORK/port" lower "$fixture" "$WORK/$name.oracle.ll" > "$WORK/$name.port.out" 2> "$WORK/$name.port.err"; then
    if [ -n "$(waiting_on "$name")" ]; then
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
    echo "    $name: PASSED, $identical of $total functions identical"
    passed=$((passed + 1))
    e2e="$e2e $name"
    if [ -n "$(waiting_on "$name")" ] || [ -n "$(known_divergence "$name")" ]; then
      echo "    $name: passes now: take it off the WAITING or KNOWN_DIVERGED list in this gate"
      diverged=$((diverged + 1))
    fi
  else
    if [ -n "$(known_divergence "$name")" ]; then
      echo "    $name: WAITING, known divergence: $identical of $total functions identical: $(known_divergence "$name")"
      waiting=$((waiting + 1))
    else
      echo "    $name: DIVERGED, $identical of $total functions identical"
      diverged=$((diverged + 1))
    fi
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
e2e_waiting=0
if "$IYI" build -o "$WORK/compile_native" "$REPO/src/compiler/tools/compile_native.iyi" > "$WORK/tool.build.log" 2>&1; then
  for name in $e2e; do
    fixture="$REPO/bench/fixtures/$name.iyi"
    if ! "$WORK/port" emit "$fixture" "$WORK/$name.oracle.ll" > "$WORK/$name.port.ir" 2> "$WORK/$name.emit.err"; then
      echo "  $name: the port writes no module: $(awk 'NR==1' "$WORK/$name.emit.err")"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    if ! "$WORK/compile_native" "$WORK/$name.port.ir" -o "$WORK/$name.native" > "$WORK/$name.native.log" 2>&1; then
      if [ -n "$(e2e_waiting_on "$name")" ]; then
        echo "  $name: WAITING, $(e2e_waiting_on "$name"): $(awk 'NR==1' "$WORK/$name.native.log")"
        e2e_waiting=$((e2e_waiting + 1))
        continue
      fi
      echo "  $name: the native tool refuses the port's module: $(awk 'NR==1' "$WORK/$name.native.log")"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    if ! codesign -v --strict "$WORK/$name.native"; then
      echo "  $name: native executable failed strict signature verification"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    timeout 30 "$WORK/$name.native" > "$WORK/$name.native.out" 2>&1; ns=$?
    timeout 30 "$WORK/$name" > "$WORK/$name.hosted.out" 2>&1; hs=$?
    if [ "$ns" = "$hs" ] && cmp -s "$WORK/$name.native.out" "$WORK/$name.hosted.out"; then
      echo "  $name: native executable runs to the hosted result (status $hs, stdout identical)"
      e2e_pass=$((e2e_pass + 1))
      if [ -n "$(e2e_waiting_on "$name")" ]; then
        echo "    $name: runs now: take it off E2E_WAITING in this gate"
        e2e_fail=$((e2e_fail + 1))
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
  echo "  end to end: $e2e_pass fixture(s) run to the hosted result, $e2e_waiting waiting by name, $e2e_fail failed"
if [ "$e2e_fail" -gt 0 ] || [ "$e2e_pass" -eq 0 ]; then
  status=1
fi

echo
binary_union_check() {
  for side in left right; do
    if "$1" binary_union "$REPO/bench/fixtures/prim_refuse_union.iyi" "$side" > "$WORK/union.out" 2> "$WORK/union.err"; then
      return 1
    fi
    awk '/lower: visit\(binary <= with operand IR types .* inconsistent with Int64 and Int64 \(hosted codegen_binary_op\)\)/ { found = 1 } END { exit !found }' "$WORK/union.err" || return 1
  done
}
convert_refusal_check() {
  local driver="$1"
  for spec in "UInt128 Float32 checked checked UInt128 to Float32" \
              "Float64 Float32 checked checked float narrowing"; do
    set -- $spec
    from=$1; to=$2; check=$3; shift 3
    if "$driver" convert_refusal "$from" "$to" "$check" > "$WORK/refuse.out" 2> "$WORK/refuse.err"; then
      return 1
    fi
    awk -v reason="$*" 'index($0, reason) { found=1 } END { exit !found }' "$WORK/refuse.err" || return 1
  done
}
if binary_union_check "$WORK/port"; then
  echo "  union comparison: both operand positions refused by name"
else
  echo "  union comparison: missing named refusal"
  status=1
fi
if ! convert_refusal_check "$WORK/port"; then
  echo "  conversion: missing named refusal"
  status=1
fi

echo "== 4. Mutation proofs: the gate must catch each patch to the ported code"
# The check rebuilds the driver from the patched source and requires every primitive fixture
# to match the hosted module exactly. It returns 0 only on the unmutated behaviour.
lower_primitives_check() {
  "$IYI" build -o "$WORK/mut" "$REPO/bench/selfhost_lower_primitives_exercise.iyi" > "$WORK/mut.build.log" 2>&1 || { touch "$WORK/mutation-build-failed"; return 1; }
  for fixture in "$REPO"/bench/fixtures/lowprim_*.iyi; do
    name="$(basename "$fixture" .iyi)"
    # A fixture waiting by name cannot pass the check; the check covers the rest.
    [ -n "$(waiting_on "$name")" ] && continue
    [ -n "$(known_divergence "$name")" ] && continue
    "$WORK/mut" lower "$fixture" "$WORK/$name.oracle.ll" > "$WORK/mut.out" 2>/dev/null || return 1
    awk '/^SUMMARY identical=[0-9]+ total=[0-9]+ module=[01]$/ { split($2, a, "="); split($3, b, "="); if (a[2] != b[2] || b[2] == 0) bad = 1; n++ } END { exit (bad || n == 0) }' "$WORK/mut.out" || return 1
  done
  "$WORK/mut" generic_pointerful > "$WORK/mut.pointerful" 2>"$WORK/mut.pointerful.err" || return 1
  awk '/^generic_pointerful=1$/ { found = 1 } END { exit !found }' "$WORK/mut.pointerful" || return 1
  binary_union_check "$WORK/mut" || return 1
  convert_refusal_check "$WORK/mut" || return 1
  return 0
}
pointer_check() {
  "$IYI" build -o "$WORK/pointer_mut" "$REPO/bench/selfhost_lower_primitives_exercise.iyi" > "$WORK/pointer_mut.build.log" 2>&1 || return 1
  : > "$WORK/pointer_mut_built"
  "$WORK/pointer_mut" lower "$REPO/bench/fixtures/lowprim_ptr.iyi" "$WORK/lowprim_ptr.oracle.ll" > "$WORK/pointer_mut.out" 2> "$WORK/pointer_mut.err" || return 1
  awk '/^SUMMARY/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); exit !(a[2] == b[2] && a[2] > 0 && c[2] == 1) }' "$WORK/pointer_mut.out"
}
pointer_check || { echo "  baseline: pointer fixture differs"; status=1; }
rm -f "$WORK/pointer_mut_built"
prove_mutation "a generic pointer metaclass receiver is not evaluated" "$REPO/src/compiler/lower/primitives.iyi" \
  '        type_id_value(low, receiver_type(low, receiver))' '        llvm_nil(low)' -- pointer_check || status=1
if [ ! -f "$WORK/pointer_mut_built" ]; then echo "  NOT PROVEN: pointer metaclass mutant failed to build"; status=1; fi
rm -f "$WORK/pointer_mut_built"
prove_mutation "pointer addition loses inbounds" "$REPO/src/compiler/lower/primitives.iyi" \
  '    low.last = low.builder.inbounds_gep(low.typer.llvm_embedded_type(elem), values[0], [values[1]] of Value)' '    low.last = low.builder.gep(low.typer.llvm_embedded_type(elem), values[0], [values[1]] of Value)' -- pointer_check || status=1
if [ ! -f "$WORK/pointer_mut_built" ]; then echo "  NOT PROVEN: pointer addition mutant failed to build"; status=1; fi
program_allocator_check() {
  "$IYI" build -o "$WORK/alloc_mut" "$REPO/bench/selfhost_lower_primitives_exercise.iyi" > "$WORK/alloc_mut.build.log" 2>&1 || return 1
  : > "$WORK/alloc_mut_built"
  for name in lowprim_malloc_program_atomic lowprim_malloc_program_full lowprim_alloc_program_atomic lowprim_malloc_program_fallback; do
    "$WORK/alloc_mut" lower "$REPO/bench/fixtures/$name.iyi" "$WORK/$name.oracle.ll" > "$WORK/alloc_mut.out" 2> "$WORK/alloc_mut.err" || return 1
    awk '/^SUMMARY identical=[0-9]+ total=[0-9]+ module=[01]$/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); if (a[2] != b[2] || b[2] == 0 || c[2] != 1) bad = 1; n++ } END { exit (bad || n == 0) }' "$WORK/alloc_mut.out" || return 1
  done
  return 0
}
program_allocator_check || { echo "  baseline: program allocator fixtures differ"; status=1; }
rm -f "$WORK/alloc_mut_built"
prove_mutation "Pointer#malloc selects the wrong program allocator kind" "$REPO/src/compiler/lower/primitives.iyi" \
  '  suffix = has_inner_pointers?(elem) ? "malloc64" : "malloc_atomic64"' '  suffix = has_inner_pointers?(elem) ? "malloc_atomic64" : "malloc64"' -- program_allocator_check || status=1
if [ ! -f "$WORK/alloc_mut_built" ]; then echo "  NOT PROVEN: pointer allocator kind mutant failed to build"; status=1; fi
rm -f "$WORK/alloc_mut_built"
prove_mutation "allocate_malloc_class selects the wrong program allocator kind" "$REPO/src/compiler/lower/primitives.iyi" \
  '  suffix = class_pointerful?(t) ? "malloc64" : "malloc_atomic64"' '  suffix = class_pointerful?(t) ? "malloc_atomic64" : "malloc64"' -- program_allocator_check || status=1
if [ ! -f "$WORK/alloc_mut_built" ]; then echo "  NOT PROVEN: class allocator kind mutant failed to build"; status=1; fi
rm -f "$WORK/alloc_mut_built"
prove_mutation "Pointer#malloc falls back to the other program allocator kind when its own is absent" "$REPO/src/compiler/lower/primitives.iyi" \
  '  callee = prog_alloc.nil? ? c_malloc_function(low) : prog_alloc.as(Function)' '  callee = prog_alloc.nil? ? (program_allocator(low, "malloc64") || c_malloc_function(low)) : prog_alloc.as(Function)' -- program_allocator_check || status=1
if [ ! -f "$WORK/alloc_mut_built" ]; then echo "  NOT PROVEN: fallback-to-other-kind mutant failed to build"; status=1; fi
# The baseline: the unmutated port must pass the check, or every mutation below is caught for the wrong reason.
lower_primitives_check || { echo "  baseline: the unmutated primitives do not pass the check"; status=1; }
prove_mutation "a concrete metaclass type id is loaded twice" "$REPO/src/compiler/lower/primitives.iyi" \
  '    if t1.is_a?(MetaclassType) || t1.is_a?(VirtualMetaclassType)
      low.last = recv' '    if t1.is_a?(MetaclassType) || t1.is_a?(VirtualMetaclassType)
      low.last = type_id_value(low, t1)' -- lower_primitives_check || status=1
prove_mutation "binary union operand is not refused" "$REPO/src/compiler/lower/primitives.iyi" \
  '    if p1.type.key != low.typer.llvm_type(t1).key || p2.type.key != low.typer.llvm_type(t2).key' '    if false' -- lower_primitives_check || status=1
prove_mutation "the wrapping add is a subtraction" "$REPO/src/compiler/lower/primitives.iyi" \
  "    return low.builder.add(p1, p2)" "    return low.builder.sub(p1, p2)" -- lower_primitives_check || status=1
prove_mutation "the signed less-than is unsigned" "$REPO/src/compiler/lower/primitives.iyi" \
  "signed_pred(t1.signed, IntPredicate::SLT, IntPredicate::ULT)" "signed_pred(t1.signed, IntPredicate::ULT, IntPredicate::ULT)" -- lower_primitives_check || status=1
prove_mutation "the wrong side is extended" "$REPO/src/compiler/lower/primitives.iyi" \
  "    return ExtendedInts.new(t2, extend_int(low, t1, t2, p1), p2)" "    return ExtendedInts.new(t2, extend_int(low, t2, t1, p1), p2)" -- lower_primitives_check || status=1
prove_mutation "a sign extension is a zero extension" "$REPO/src/compiler/lower/primitives.iyi" \
  "    return low.builder.sext(value, to.ir)" "    return low.builder.zext(value, to.ir)" -- lower_primitives_check || status=1
prove_mutation "a mixed-sign less-than uses the unsigned predicate" "$REPO/src/compiler/lower/primitives.iyi" \
  "      widened = low.builder.icmp(IntPredicate::SLT, p1, extend_int(low, t2, t1, p2))" "      widened = low.builder.icmp(IntPredicate::ULT, p1, extend_int(low, t2, t1, p2))" -- lower_primitives_check || status=1
prove_mutation "a by-value pointer_get loads" "$REPO/src/compiler/lower/primitives.iyi" \
  "      low.last = values[0]" "      low.last = load_aligned(low, low.typer.llvm_embedded_type(elem), values[0])" -- lower_primitives_check || status=1
prove_mutation "a Bool pointer_set stores zero" "$REPO/src/compiler/lower/primitives.iyi" \
  "      bool_stored = values[1]" "      bool_stored = int1(low, 0_i64)" -- lower_primitives_check || status=1
prove_mutation "a generic instance ignores its class variables" "$REPO/src/compiler/lower/primitives.iyi" \
  "    return t.as(GenericClassInstanceType).all_instance_vars" "    return Hash(String, MetaTypeVar).new" -- lower_primitives_check || status=1
prove_mutation "a nilable reference union reads the nil id from the object" "$REPO/src/compiler/lower/cast.iyi" \
  "    phi.add(low, object_type_id(low, value), true)" "    phi.add(low, type_id_value(low, low.analysed.program.nil_type), true)" -- lower_primitives_check || status=1
prove_mutation "an implicit-self primitive uses a constant instead of self" "$REPO/src/compiler/lower/primitives.iyi" \
  "    recv = sv.as(LowerVar).pointer" "    recv = int1(low, 0_i64)" -- lower_primitives_check || status=1
prove_mutation "a reference pointer_set stores the pointer slot" "$REPO/src/compiler/lower/primitives.iyi" \
  "      ref_stored = values[1]" "      ref_stored = values[0]" -- lower_primitives_check || status=1
prove_mutation "a by-value pointer_set copies the destination" "$REPO/src/compiler/lower/primitives.iyi" \
  '    assign(low, values[0], target, actual, values[1])
    low.last = values[1]
    return
  end
  pending_visit_node("primitive #{name} (hosted codegen_primitive, primitives.cr)")' \
  '    assign(low, values[0], target, actual, values[0])
    low.last = values[1]
    return
  end
  pending_visit_node("primitive #{name} (hosted codegen_primitive, primitives.cr)")' -- lower_primitives_check || status=1
prove_mutation "checked addition returns its overflow bit" "$REPO/src/compiler/lower/primitives.iyi" \
  "  pair[0]" "  pair[1]" -- lower_primitives_check || status=1
prove_mutation "an acquire atomic load is sequentially consistent" "$REPO/src/compiler/lower/primitives.iyi" \
  '  when "acquire"                 then Ordering::Acquire' '  when "acquire"                 then Ordering::SeqCst' -- lower_primitives_check || status=1
prove_mutation "a release atomic store is sequentially consistent" "$REPO/src/compiler/lower/primitives.iyi" \
  '  when "release"                 then Ordering::Release' '  when "release"                 then Ordering::SeqCst' -- lower_primitives_check || status=1
prove_mutation "an atomic read-modify-write always exchanges" "$REPO/src/compiler/lower/primitives.iyi" \
  '  inst = low.builder.atomicrmw(op, ptr.as(Value), value, ordering, flag.as(BoolLiteral).value)' '  inst = low.builder.atomicrmw("xchg", ptr.as(Value), value, ordering, flag.as(BoolLiteral).value)' -- lower_primitives_check || status=1
prove_mutation "an atomic read-modify-write ignores its ordering" "$REPO/src/compiler/lower/primitives.iyi" \
  '  ordering = atomic_ordering(node.args[3])' '  ordering = Ordering::Monotonic' -- lower_primitives_check || status=1
prove_mutation "compare-exchange ignores its failure ordering" "$REPO/src/compiler/lower/primitives.iyi" \
  '  result = low.builder.cmpxchg(ptr.as(Value), compare, replacement, success, failure)' '  result = low.builder.cmpxchg(ptr.as(Value), compare, replacement, success, success)' -- lower_primitives_check || status=1
if [ -n "$(waiting_on lowprim_enum)" ]; then
  echo "  NOT RUN: enum mutation waits for enum member typing"
else
  prove_mutation "an enum value is not lowered" "$REPO/src/compiler/lower/primitives.iyi" \
    '  if name == "enum_value"' '  if name == "wrong_enum_value"' -- lower_primitives_check || status=1
fi
prove_mutation "checked conversion omits its lower bound" "$REPO/src/compiler/lower/primitives.iyi" \
  '  low.builder.build_or(below, above)' '  above' -- lower_primitives_check || status=1
prove_mutation "checked conversion omits its upper bound" "$REPO/src/compiler/lower/primitives.iyi" \
  '  low.builder.build_or(below, above)' '  below' -- lower_primitives_check || status=1
prove_mutation "a tuple index selects the first member" "$REPO/src/compiler/lower/primitives.iyi" \
  '  first = primitive.tuple_index' '  first = 0' -- lower_primitives_check || status=1
prove_mutation "object_id returns zero instead of the receiver address" "$REPO/src/compiler/lower/primitives.iyi" \
  '    low.last = low.builder.ptr_to_int(values[0], low.module.types.int64)' '    low.last = low.builder.const_int(low.module.types.int64, 0_i64)' -- lower_primitives_check || status=1
prove_mutation "runtime type id returns Nil's id" "$REPO/src/compiler/lower/primitives.iyi" \
  '      low.last = type_id_of_value(low, obj || node, values[0], t1)' '      low.last = type_id_value(low, low.analysed.program.nil_type)' -- lower_primitives_check || status=1
prove_mutation "proc call omits the closure context" "$REPO/src/compiler/lower/primitives.iyi" \
  '  closure_args = [ctx.as(Value)] of Value' '  closure_args = [] of Value' -- lower_primitives_check || status=1
prove_mutation "tuple metaclass indexing returns Nil's type id" "$REPO/src/compiler/lower/primitives.iyi" \
  '    low.last = type_id_value(low, result.as(Type))' '    low.last = type_id_value(low, low.analysed.program.nil_type)' -- lower_primitives_check || status=1
prove_mutation "the Char less-than is less-or-equal" "$REPO/src/compiler/lower/primitives.iyi" \
  "    if op == \"<\"" "    if op == \"<=\"" -- lower_primitives_check || status=1
prove_mutation "the Bool equality tests inequality" "$REPO/src/compiler/lower/primitives.iyi" \
  "    if op == \"==\"" "    if op == \"!=\"" -- lower_primitives_check || status=1
prove_mutation "the class type id is stored one struct over" "$REPO/src/compiler/lower/primitives.iyi" \
  "  zero = low.builder.const_int(low.module.types.int32, 0_i64)" "  zero = low.builder.const_int(low.module.types.int32, 1_i64)" -- lower_primitives_check || status=1
prove_mutation "integer to Char uses the wrong signed width" "$REPO/src/compiler/lower/primitives.iyi" \
  '    return codegen_convert_int(low, from, low.analysed.program.int32_type, value, checked)' '    return value' -- lower_primitives_check || status=1
prove_mutation "Char to equal width integer extends" "$REPO/src/compiler/lower/primitives.iyi" \
  '    if value.type.key == low.typer.llvm_type(to).key' '    if false' -- lower_primitives_check || status=1
prove_mutation "signed integer to float uses unsigned conversion" "$REPO/src/compiler/lower/primitives.iyi" \
  '      return low.builder.si_to_fp(value, low.typer.llvm_type(to))' '      return low.builder.ui_to_fp(value, low.typer.llvm_type(to))' -- lower_primitives_check || status=1
prove_mutation "float less-than uses less-or-equal" "$REPO/src/compiler/lower/primitives.iyi" \
  '    return low.builder.fcmp(RealPredicate::OLT, left, right)' '    return low.builder.fcmp(RealPredicate::OLE, left, right)' -- lower_primitives_check || status=1
prove_mutation "float equality uses inequality" "$REPO/src/compiler/lower/primitives.iyi" \
  '    return low.builder.fcmp(RealPredicate::OEQ, left, right)' '    return low.builder.fcmp(RealPredicate::UNE, left, right)' -- lower_primitives_check || status=1
prove_mutation "float inequality uses equality" "$REPO/src/compiler/lower/primitives.iyi" \
  '    return low.builder.fcmp(RealPredicate::UNE, left, right)' '    return low.builder.fcmp(RealPredicate::OEQ, left, right)' -- lower_primitives_check || status=1
prove_mutation "float less-or-equal uses greater-than" "$REPO/src/compiler/lower/primitives.iyi" \
  '    return low.builder.fcmp(RealPredicate::OLE, left, right)' '    return low.builder.fcmp(RealPredicate::OGT, left, right)' -- lower_primitives_check || status=1
prove_mutation "float greater-than uses less-than" "$REPO/src/compiler/lower/primitives.iyi" \
  '    return low.builder.fcmp(RealPredicate::OGT, left, right)' '    return low.builder.fcmp(RealPredicate::OLT, left, right)' -- lower_primitives_check || status=1
prove_mutation "float greater-or-equal uses less-than" "$REPO/src/compiler/lower/primitives.iyi" \
  '    return low.builder.fcmp(RealPredicate::OGE, left, right)' '    return low.builder.fcmp(RealPredicate::OLT, left, right)' -- lower_primitives_check || status=1
prove_mutation "float addition uses subtraction" "$REPO/src/compiler/lower/primitives.iyi" \
  '    result = low.builder.fadd(left, right)' '    result = low.builder.fsub(left, right)' -- lower_primitives_check || status=1
prove_mutation "float subtraction uses addition" "$REPO/src/compiler/lower/primitives.iyi" \
  '    result = low.builder.fsub(left, right)' '    result = low.builder.fadd(left, right)' -- lower_primitives_check || status=1
prove_mutation "float multiplication uses division" "$REPO/src/compiler/lower/primitives.iyi" \
  '    result = low.builder.fmul(left, right)' '    result = low.builder.fdiv(left, right)' -- lower_primitives_check || status=1
prove_mutation "float division uses multiplication" "$REPO/src/compiler/lower/primitives.iyi" \
  '    result = low.builder.fdiv(left, right)' '    result = low.builder.fmul(left, right)' -- lower_primitives_check || status=1
prove_mutation "integer left float operand skips conversion" "$REPO/src/compiler/lower/primitives.iyi" \
  '    return codegen_float_binary_op(low, op, t2, t2, codegen_primitive_convert(low, t1, t2, p1, false), p2)' '    return p1' -- lower_primitives_check || status=1
prove_mutation "integer right float operand skips conversion" "$REPO/src/compiler/lower/primitives.iyi" \
  '    return codegen_float_binary_op(low, op, t1, t1, p1, codegen_primitive_convert(low, t2, t1, p2, false))' '    return p2' -- lower_primitives_check || status=1
prove_mutation "left narrow float skips extension" "$REPO/src/compiler/lower/primitives.iyi" \
  '    left = low.builder.fp_ext(left, low.typer.llvm_type(t2))' '    left = p1' -- lower_primitives_check || status=1
prove_mutation "right narrow float skips extension" "$REPO/src/compiler/lower/primitives.iyi" \
  '    right = low.builder.fp_ext(right, low.typer.llvm_type(t1))' '    right = p2' -- lower_primitives_check || status=1
prove_mutation "unsigned integer converts as signed float" "$REPO/src/compiler/lower/primitives.iyi" \
  '    return low.builder.ui_to_fp(value, low.typer.llvm_type(to))' '    return low.builder.si_to_fp(value, low.typer.llvm_type(to))' -- lower_primitives_check || status=1
prove_mutation "float widening skips extension" "$REPO/src/compiler/lower/primitives.iyi" \
  '      return low.builder.fp_ext(value, low.typer.llvm_type(to))' '      return value' -- lower_primitives_check || status=1
prove_mutation "float narrowing skips truncation" "$REPO/src/compiler/lower/primitives.iyi" \
  '      return low.builder.fp_trunc(value, low.typer.llvm_type(to))' '      return value' -- lower_primitives_check || status=1
prove_mutation "mixed float result skips truncation" "$REPO/src/compiler/lower/primitives.iyi" \
  '    return low.builder.fp_trunc(result, low.typer.llvm_type(t1))' '    return result' -- lower_primitives_check || status=1
prove_mutation "pointer difference divides without exact" "$REPO/src/compiler/lower/primitives.iyi" \
  '    low.last = low.builder.exact_sdiv(bytes, size)' '    low.last = low.builder.sdiv(bytes, size)' -- lower_primitives_check || status=1
prove_mutation "pointer difference omits inbounds" "$REPO/src/compiler/lower/primitives.iyi" \
  '    offset = low.builder.const_gep(low.typer.llvm_embedded_type(elem), zero, [one] of Value, true)' '    offset = low.builder.const_gep(low.typer.llvm_embedded_type(elem), zero, [one] of Value, false)' -- lower_primitives_check || status=1
prove_mutation "static class returns the receiver type id" "$REPO/src/compiler/lower/primitives.iyi" \
  '      low.last = type_id_value(low, meta.as(Type))' '      low.last = type_id_value(low, t1)' -- lower_primitives_check || status=1
prove_mutation "virtual class returns the runtime type id" "$REPO/src/compiler/lower/primitives.iyi" \
  '      low.last = primitive_metaclass_id(low, tid)' '      low.last = tid' -- lower_primitives_check || status=1
prove_mutation "metaclass switch returns the type id" "$REPO/src/compiler/lower/primitives.iyi" \
  '        low.builder.ret(low.builder.const_int(low.module.types.int32, meta.as(Int32).to_i64))' '        low.builder.ret(low.builder.const_int(low.module.types.int32, id.to_i64))' -- lower_primitives_check || status=1
prove_mutation "checked UInt128 to Float32 must refuse" "$REPO/src/compiler/lower/primitives.iyi" \
  '      pending_visit_node("checked UInt128 to Float32 (hosted codegen_out_of_range)")' '      return value' -- lower_primitives_check || status=1
prove_mutation "checked float narrowing must refuse" "$REPO/src/compiler/lower/primitives.iyi" \
  '        pending_visit_node("checked float narrowing #{from.full_name} to #{to.full_name} (hosted codegen_out_of_range)")' '        return value' -- lower_primitives_check || status=1
prove_mutation "a saturating conversion to an unsigned integer is signed" "$REPO/src/compiler/lower/primitives.iyi" \
  '  id = signed ? IntrinsicId::FPToSISat : IntrinsicId::FPToUISat' '  id = IntrinsicId::FPToSISat' -- lower_primitives_check || status=1
prove_mutation "a checked conversion to an unsigned integer truncates as signed" "$REPO/src/compiler/lower/primitives.iyi" \
  '    return signed ? low.builder.fp_to_si(value, to_ir) : low.builder.fp_to_ui(value, to_ir)' '    return low.builder.fp_to_si(value, to_ir)' -- lower_primitives_check || status=1
prove_mutation "the other library lower float bound is ordered" "$REPO/src/compiler/lower/primitives.iyi" \
  '  below = low.builder.fcmp(RealPredicate::ULT, value, low.builder.const_float(float_ir, minimum))' '  below = low.builder.fcmp(RealPredicate::OLT, value, low.builder.const_float(float_ir, minimum))' -- lower_primitives_check || status=1
prove_mutation "the other library upper float bound is rounded" "$REPO/src/compiler/lower/primitives.iyi" \
  '  maximum = past <= precision ? pow2_f64(past) - 1.0 : pow2_f64(past) - pow2_f64(past - precision)' '  maximum = pow2_f64(past) - 1.0' -- lower_primitives_check || status=1

echo
echo "== 5. Checked arithmetic in an isolated def from a required runtime"
required="$REPO/bench/fixtures/lower_overflow_required"
if IYI_PATH="$required/prelude" "$IYI" build --emit llvm-ir --no-debug -o "$WORK/required-oracle" "$required/main.iyi" > "$WORK/required-oracle.log" 2>&1; then
  awk "$CALL_TYPES" "$WORK/required-oracle.ll" > "$WORK/required-oracle.normal.ll"
  "$WORK/port" oracle "$WORK/required-oracle.normal.ll" > "$WORK/required-host.txt" 2> "$WORK/required-host.err" || status=1
  awk '/^define .*checked_sum/{p=1; n++} p{print} p && /^}/{p=0} END {if (n != 1) exit 1}' "$WORK/required-host.txt" > "$WORK/required-host.fn" || status=1
else
  echo "  required-unit oracle failed:"
  awk 'NR<=15' "$WORK/required-oracle.log"
  status=1
fi
required_overflow_check() {
  "$IYI" build -o "$WORK/required-port" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/required-build.log" 2>&1 || { touch "$WORK/mutation-build-failed"; return 1; }
  (cd "$required" && "$WORK/required-port" probe-required runtime.iyi main.iyi "$WORK/required-oracle.normal.ll") > "$WORK/required.ir" 2> "$WORK/required.err" || return 1
  awk '/^declare external void @__iyi_raise_overflow/ {found=1} END {exit !found}' "$WORK/required.ir" || return 1
  "$WORK/port" oracle "$WORK/required.ir" > "$WORK/required-port.txt" 2> "$WORK/required-port.err" || return 1
  awk '/^define .*checked_sum/{p=1; n++} p{print} p && /^}/{p=0} END {if (n != 1) exit 1}' "$WORK/required-port.txt" > "$WORK/required-port.fn" || return 1
  cmp -s "$WORK/required-host.fn" "$WORK/required-port.fn"
}
if required_overflow_check; then
  echo "  required-unit overflow: function identical to the hosted module"
else
  echo "  required-unit overflow: refused or differs from the hosted module"
  awk 'NR<=12' "$WORK/required.err" "$WORK/required-build.log"
  status=1
fi
prove_mutation "the required overflow function has the wrong name" "$REPO/src/compiler/lower/primitives.iyi" \
  '    fn = low.module.add_function(name, fn_type, CallConv::C)' '    fn = low.module.add_function(name + "_wrong", fn_type, CallConv::C)' -- required_overflow_check || status=1

echo
echo "== 6. Checked float conversions under the iyi prelude, in isolated defs from a required runtime"
float_names="f32_i8 f32_i16 f32_i32 f32_i64 f32_i128 f32_u8 f32_u16 f32_u32 f32_u64 f32_u128 f64_i8 f64_i16 f64_i32 f64_i64 f64_i128 f64_u8 f64_u16 f64_u32 f64_u64 f64_u128"
if IYI_PATH="$required/prelude" "$IYI" build --emit llvm-ir --no-debug -o "$WORK/float-oracle" "$required/float_int.iyi" > "$WORK/float-oracle.log" 2>&1; then
  awk "$CALL_TYPES" "$WORK/float-oracle.ll" > "$WORK/float-oracle.normal.ll"
  "$WORK/port" oracle "$WORK/float-oracle.normal.ll" > "$WORK/float-host.txt" 2> "$WORK/float-host.err" || status=1
else
  echo "  float-conversion oracle failed:"
  awk 'NR<=15' "$WORK/float-oracle.log"
  status=1
fi
# The one define of a normalised module named NAME (quoted, `@"*NAME<`); fails unless exactly one matches.
one_def() {
  awk -v n="@\"*$1<" 'index($0, "define ") == 1 && index($0, n) { p = 1; c++ } p { print } p && /^}/ { p = 0 } END { exit c != 1 }' "$2"
}
float_iyi_check() {
  "$IYI" build -o "$WORK/float-port" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/float-build.log" 2>&1 || { touch "$WORK/mutation-build-failed"; return 1; }
  (cd "$required" && "$WORK/float-port" probe-iyi runtime.iyi float_int.iyi "$WORK/float-oracle.normal.ll" $float_names) > "$WORK/float.ir" 2> "$WORK/float.err" || return 1
  "$WORK/port" oracle "$WORK/float.ir" > "$WORK/float-port.txt" 2> "$WORK/float-port.err" || return 1
  for name in $float_names; do
    one_def "$name" "$WORK/float-host.txt" > "$WORK/float-host.fn" || return 1
    one_def "$name" "$WORK/float-port.txt" > "$WORK/float-port.fn" || return 1
    cmp -s "$WORK/float-host.fn" "$WORK/float-port.fn" || return 1
  done
}
if float_iyi_check; then
  echo "  iyi-prelude float conversions: 20 functions identical to the hosted module"
else
  echo "  iyi-prelude float conversions: refused or differ from the hosted module"
  awk 'NR<=12' "$WORK/float.err" "$WORK/float-build.log"
  status=1
fi
prove_mutation "a checked float conversion ignores the prelude in use" "$REPO/src/compiler/lower/primitives.iyi" \
  '  if low.analysed.program.iyi_prelude?' '  if false' -- float_iyi_check || status=1
prove_mutation "the iyi prelude's upper float bound is excluded" "$REPO/src/compiler/lower/primitives.iyi" \
  '      above = low.builder.fcmp(RealPredicate::OGE, value, low.builder.const_float(float_ir, pow2_f64(past)))' \
  '      above = low.builder.fcmp(RealPredicate::OGT, value, low.builder.const_float(float_ir, pow2_f64(past)))' -- float_iyi_check || status=1

if [ -e "$WORK/mutation-build-failed" ]; then
  echo "  NOT PROVEN: a mutation driver failed to build"
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "PRIMITIVES LOWERING GATE PASSED"
else
  echo "PRIMITIVES LOWERING GATE FAILED"
fi
exit "$status"
