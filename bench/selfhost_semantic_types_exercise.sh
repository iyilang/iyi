#!/usr/bin/env bash
# Fails when the iyi type model stops agreeing with the hosted type model.
#
# Each fixture (bench/fixtures/semty_*.iyi) declares types and lists operations
# as `# op <receiver>.<member>` lines. The hosted oracle
# (bench/selfhost_semantic_types_oracle.cr) and the port's driver
# (bench/selfhost_semantic_types_exercise.iyi) each print one line per
# operation, `<op> => <result>`, and the two outputs must be byte-identical.
#
# Mutation proofs patch the ported code, rebuild the driver, and require the
# gate to fail. A patch that changes nothing is refused by prove_mutation.
#
#   bash bench/selfhost_semantic_types_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")"
export IYI_PATH="$REPO_NATIVE/src"
IYI="$REPO/bin/iyi"
HOSTED_COMPILER="$REPO/bin/crystal"
TYPES_FILE="$REPO/src/compiler/types/types.iyi"
MERGE_FILE="$REPO/src/compiler/types/merge.iyi"
INTERSECT_FILE="$REPO/src/compiler/types/intersect.iyi"
FILTERS_FILE="$REPO/src/compiler/types/filters.iyi"
TYPE_SYSTEM_FILE="$REPO/src/compiler/types/type_system.iyi"
TOP_LEVEL_FILE="$REPO/src/compiler/semantic/top_level.iyi"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")"
trap 'rm -rf "$WORK"' EXIT

. "$REPO/bench/lib/mutation.sh"

echo "== 1. Building the hosted oracle and the port driver"
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing \
    -o "$WORK_NATIVE/oracle$EXE" "$REPO_NATIVE/bench/selfhost_semantic_types_oracle.cr" || { echo "oracle build failed"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/port$EXE" "$REPO_NATIVE/bench/selfhost_semantic_types_exercise.iyi" || { echo "port driver build failed"; exit 1; }

echo
echo "== 2. Each fixture's operations, hosted oracle against the port"
compare_all() {
  local port_bin="$1" fixture rc first_difference=""
  local out_status=0
  for fixture in "$REPO"/bench/fixtures/semty_*.iyi; do
    "$port_bin" "$(native_path "$fixture")" > "$WORK/port.out" 2>"$WORK/port.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "type query driver died on $(basename "$fixture"): $(refusal_note "$rc" "$WORK/port.err")"
      return 2
    fi
    "$WORK/oracle$EXE" "$(native_path "$fixture")" > "$WORK/oracle.out" 2>"$WORK/oracle.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "type query oracle died on $(basename "$fixture"): $(refusal_note "$rc" "$WORK/oracle.err")"
      return 2
    fi
    cmp -s "$WORK/port.out" "$WORK/oracle.out"
    rc=$?
    case "$rc" in
      0) ;;
      1)
        [ -n "$first_difference" ] || first_difference="$(basename "$fixture")"
        out_status=1
        ;;
      *)
        echo "type query comparison failed on $(basename "$fixture") (exit $rc)"
        return 2
        ;;
    esac
  done
  if [ -n "$first_difference" ]; then
    echo "decisive: $first_difference: type query output differs from the hosted oracle"
  fi
  return "$out_status"
}

fixture_count=0
total_ops=0
diverged=0
for fixture in "$REPO"/bench/fixtures/semty_*.iyi; do
  fixture_name="bench/fixtures/$(basename "$fixture")"
  "$WORK/port$EXE" "$(native_path "$fixture")" > "$WORK/port.out" 2>"$WORK/port.err" || {
    echo "  $fixture_name: port driver failed: $(head -n 1 "$WORK/port.err")"
    status=1
    continue
  }
  "$WORK/oracle$EXE" "$(native_path "$fixture")" > "$WORK/oracle.out" 2>"$WORK/oracle.err" || {
    echo "  $fixture_name: hosted oracle failed: $(head -n 1 "$WORK/oracle.err")"
    status=1
    continue
  }
  if diff -u "$WORK/oracle.out" "$WORK/port.out" > "$WORK/diff.out"; then
    ops=$(awk 'END { print NR }' "$WORK/oracle.out")
    echo "  $fixture_name: identical ($ops operations)"
    fixture_count=$((fixture_count + 1))
    total_ops=$((total_ops + ops))
  else
    echo "  $fixture_name: DIVERGED from the hosted oracle"
    cat "$WORK/diff.out"
    diverged=$((diverged + 1))
    status=1
  fi
done
echo "  Parity summary: $fixture_count fixtures identical ($total_ops operations compared)"
if [ "$fixture_count" -eq 0 ]; then
  echo "  no fixtures compared: this proves nothing"
  status=1
fi

echo
echo "== 2b. Known divergences, waiting on later slices (reported, not compared)"
awk '/^# waiting /{ sub(/^# waiting /, ""); print "  known divergence, waiting on " $0 }' "$REPO"/bench/fixtures/semty_*.iyi > "$WORK/waiting.out"
cat "$WORK/waiting.out"
echo "  $(awk 'END { print NR }' "$WORK/waiting.out") operations wait on later slices"

echo
echo "== 3. Guarded mutation proofs (patch, rebuild, the gate must fail)"
MUTATIONS_RUN=0

# Only a successfully built and executed mutant can be a behavioral catch.
check_type_queries_diverge() {
  local rc
  rm -f "$WORK/mut-port$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut-port$EXE" "$REPO_NATIVE/bench/selfhost_semantic_types_exercise.iyi" >"$WORK/mut-build.log" 2>&1 ||
     [ ! -x "$WORK/mut-port$EXE" ]; then
    echo "INVALID MUTANT: type query driver did not build"
    cat "$WORK/mut-build.log"
    return 0
  fi
  if compare_all "$WORK/mut-port$EXE"; then
    return 0
  else
    rc=$?
    if [ "$rc" -ne 1 ]; then
      echo "INVALID MUTANT: type query oracle or driver failed"
      return 0
    fi
    return 1
  fi
}

prove_mutation "virtual_type leaf rule bypassed" "$TYPES_FILE" \
  "      return type if is_leaf && !is_abstract" \
  "      return type if false && is_leaf && !is_abstract" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "all_subclasses drops every later direct subclass" "$TYPES_FILE" \
  "    subclasses(type).each do |sub|" \
  "    subclasses(type).first(1).each do |sub|" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "reference_like? treats every generic instance as a reference" "$TYPES_FILE" \
  "      return !type.struct?" \
  "      return true" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "splat_index drops the generic class splat position" "$TYPES_FILE" \
  "      return type.as(GenericClassType).splat_index" \
  "      return nil" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "NoReturn elimination bypassed in merge_all" "$MERGE_FILE" \
  "kept << t unless TypeQueries.no_return?(t)" \
  "kept << t" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "base_descendent ignores declared parents" "$INTERSECT_FILE" \
  "    parents_of(t1).each do |parent|" \
  "    ([] of Type).each do |parent|" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "is_a? narrows to the tested value, not the target" "$FILTERS_FILE" \
  "        return TypeIntersect.common_descendent(program, other, target)" \
  "        return other" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "including types ignored in intersect" "$INTERSECT_FILE" \
  "    inc = including_union(program, mod)" \
  "    inc = nil" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "proc argument invariance bypassed in compatibility" "$INTERSECT_FILE" \
  "      return false unless t1.arg_types[i] == t2.arg_types[i]" \
  "      return false unless true" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "left alias removal bypassed in intersect" "$INTERSECT_FILE" \
  "      return common_descendent(program, TypeMerge.remove_alias(t1), t2)" \
  "      return nil" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "Void return cast to Nil bypassed in proc_of" "$REPO/src/compiler/types/instances.iyi" \
  "    ret = @program.nil_type if return_type.is_a?(VoidType)" \
  "    ret = return_type if false" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "generic instances stop registering with their generic type" "$TYPES_FILE" \
  "    @generic_type.register_subclass(sub)" \
  "    nil" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "generic type stands for itself bypassed in virtual_type" "$TYPES_FILE" \
  "    if type.is_a?(GenericClassType)" \
  "    if false" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "virtual type not kept on its class (virtual_type_made? and identity lost)" "$TYPES_FILE" \
  "      cls.virtual_type_cache = fresh" \
  "      cls.virtual_type_cache = nil" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "program union cache bypassed (same members make two unions)" "$REPO/src/compiler/types/unification.iyi" \
  "      return cached" \
  "      return build_union_of(program, unique)" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "union members printed by full name, not devirtualized" "$TOP_LEVEL_FILE" \
  "        non_nil_names << t.member_name" \
  "        non_nil_names << t.full_name" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "generic type hook bypassed in SemanticProgram lookup" "$TOP_LEVEL_FILE" \
  $'            type_args = g.type_vars.map { |t| lookup_type_node(t, current_type) }\n            return hook.instantiate_type(base_type, type_args)' \
  $'            type_args = g.type_vars.map { |t| lookup_type_node(t, current_type) }\n            return base_type' \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

LOOKUP_MUTATION_FILE="$REPO/src/compiler/types/lookup.iyi"
prove_mutation "lookup searches the enclosing namespaces for a first item not at all" "$LOOKUP_MUTATION_FILE" \
  "      if ns = scope.namespace" \
  "      if ns = nil" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "generic type argument count is not checked" "$LOOKUP_MUTATION_FILE" \
  "    elsif given != type_vars.size" \
  "    elsif false" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "unbound generic accepted as a written type argument" "$LOOKUP_MUTATION_FILE" \
  "      return false" \
  "      return true" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

RESTRICT_MUTATION_FILE="$REPO/src/compiler/types/to_restriction.iyi"
prove_mutation "proc returning Nil keeps its Nil output in the restriction" "$RESTRICT_MUTATION_FILE" \
  "    if !type.return_type.is_a?(NilType)" \
  "    if true" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "restriction paths drop their namespaces" "$RESTRICT_MUTATION_FILE" \
  "    append_namespace(type, names, common)" \
  "    nil" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "restriction names are written in lower case" "$RESTRICT_MUTATION_FILE" \
  "    names << type.name" \
  "    names << type.name.downcase" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "private types are written by their full path" "$RESTRICT_MUTATION_FILE" \
  "    if !fully_public?(type)" \
  "    if false" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "typedef removal bypassed" "$REPO/src/compiler/semantic/top_level.iyi" \
  "    @typedef.remove_typedef" \
  "    self" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "private types reached by a later path item are found" "$REPO/src/compiler/types/lookup.iyi" \
  "        return nil if !include_private && item.private?" \
  "        return nil if false" \
  -- check_type_queries_diverge || status=1

prove_mutation "unbound? true for any argument of a generic instance" "$REPO/src/compiler/types/types.iyi" \
  "      return true if unbound?(types[i])" \
  "      return true if true" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "unbound? true on a generic instance" "$REPO/src/compiler/types/types.iyi" \
  "      return any_unbound?(type.as(GenericInstanceType).type_vars.values)" \
  "      return true" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a module with includers stands for itself" "$REPO/src/compiler/types/indirection.iyi" \
  "        return including" \
  "        return type" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "an alias is not followed by remove_indirection" "$REPO/src/compiler/types/indirection.iyi" \
  "    return remove_indirection(type.as(AliasType).process_value)" \
  "    return type" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "generic instances do not take the modules of their generic type" "$REPO/src/compiler/types/instances.iyi" \
  "        inst.included_modules << parent" \
  "        nil" \
  -- check_type_queries_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST SEMANTIC TYPES CHECKS PASSED =="
else
  echo "== SELFHOST SEMANTIC TYPES CHECKS FAILED =="
fi
exit "$status"
