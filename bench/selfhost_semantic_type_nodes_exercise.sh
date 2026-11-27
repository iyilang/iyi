#!/usr/bin/env bash
# Fails when the iyi typing of type-shaped nodes in bodies (Generic, Union,
# ProcNotation, Metaclass, Self and FunDef, src/compiler/semantic/type_nodes.iyi)
# stops agreeing with the hosted pass, or when the type names those nodes print
# (GenericClassType, GenericInstanceType, union arguments) drift from it.
#
# Every fixture bench/fixtures/typenodes_*.iyi is analysed twice: by the
# hosted pass (bench/selfhost_typed_oracle.cr, --bare) and by the port's typed
# dump (src/compiler/tools/typed_dump.iyi). The two dumps must be byte-identical.
#
# The cast upcast flag (Cast#upcast, NilableCast#upcast) is compared by its own
# driver pair, bench/selfhost_cast_upcast_oracle.cr and bench/selfhost_cast_upcast_dump.iyi,
# over bench/fixtures/typenodes_cast_*.iyi: the typed dump prints types only, and the
# typed parity gate's oracle must not change.
#
# The mutation proofs follow the rule the other selfhost gates use: each patch
# is applied to one file, the comparison must then diverge, and a patch that
# matched nothing is reported as proving nothing.
#
#   bash bench/selfhost_semantic_type_nodes_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")"
IYI="$REPO/bin/iyi"
HOSTED_COMPILER="$REPO/bin/crystal"
DUMP_SRC="$REPO/src/compiler/tools/typed_dump.iyi"
TYPE_NODES="$REPO/src/compiler/semantic/type_nodes.iyi"
TOP_LEVEL="$REPO/src/compiler/semantic/top_level.iyi"
TYPES_FILE="$REPO/src/compiler/types/types.iyi"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")"
trap 'rm -rf "$WORK"' EXIT
export IYI_CACHE_DIR="$WORK_NATIVE/cache" IYI_PATH="$REPO_NATIVE/src"

. "$REPO/bench/lib/mutation.sh"

ORACLE="$WORK/oracle$EXE"
DUMP="$WORK/typed_dump$EXE"
CAST_ORACLE="$WORK/cast_oracle$EXE"
CAST_DUMP="$WORK/cast_dump$EXE"
CAST_DUMP_SRC="$REPO/bench/selfhost_cast_upcast_dump.iyi"

echo "== 1. Building the hosted oracle and the port's typed dump"
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" CRYSTAL_PATH="$REPO_NATIVE/src" IYI_CONFIG_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing \
  -o "$WORK_NATIVE/oracle$EXE" "$REPO_NATIVE/bench/selfhost_typed_oracle.cr" > "$WORK/oracle_build.log" 2>&1 \
  || { cat "$WORK/oracle_build.log"; echo "FAILED to build the hosted oracle"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/typed_dump$EXE" "$(native_path "$DUMP_SRC")" > "$WORK/dump_build.log" 2>&1 \
  || { cat "$WORK/dump_build.log"; echo "FAILED to build src/compiler/tools/typed_dump.iyi"; exit 1; }
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" CRYSTAL_PATH="$REPO_NATIVE/src" IYI_CONFIG_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing \
  -o "$WORK_NATIVE/cast_oracle$EXE" "$REPO_NATIVE/bench/selfhost_cast_upcast_oracle.cr" > "$WORK/cast_oracle_build.log" 2>&1 \
  || { cat "$WORK/cast_oracle_build.log"; echo "FAILED to build the hosted cast oracle"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/cast_dump$EXE" "$(native_path "$CAST_DUMP_SRC")" > "$WORK/cast_dump_build.log" 2>&1 \
  || { cat "$WORK/cast_dump_build.log"; echo "FAILED to build the port's cast dump"; exit 1; }
echo "  built: oracle, typed_dump"

echo
echo "== 2. Each fixture: the port's typed dump against the hosted oracle"
fixture_count=0
diverged=0
total_nodes=0
for fixture in "$REPO"/bench/fixtures/typenodes_*.iyi; do
  base="$(basename "$fixture" .iyi)"
  fixture_count=$((fixture_count + 1))
  "$ORACLE" "$(native_path "$fixture")" --bare > "$WORK/$base.oracle" 2> "$WORK/$base.oracle.err"
  if [ $? -ne 0 ]; then
    echo "  FAIL: the hosted oracle refused $base: $(head -n 1 "$WORK/$base.oracle.err")"
    diverged=$((diverged + 1))
    continue
  fi
  if ! "$DUMP" "$(native_path "$fixture")" > "$WORK/$base.port" 2>&1; then
    echo "  FAIL: the port could not analyse $base"
    diverged=$((diverged + 1))
    continue
  fi
  if cmp -s "$WORK/$base.oracle" "$WORK/$base.port"; then
    nodes=$(wc -l < "$WORK/$base.oracle" | tr -d ' ')
    total_nodes=$((total_nodes + nodes))
    echo "  ok: $base ($nodes typed nodes identical)"
  else
    echo "  FAIL: $base diverges from the hosted oracle:"
    diff "$WORK/$base.oracle" "$WORK/$base.port" | head -n 12
    diverged=$((diverged + 1))
  fi
done
echo "  Parity summary: $((fixture_count - diverged))/$fixture_count type-node fixtures match 100% ($total_nodes typed nodes compared)"
if [ "$fixture_count" -eq 0 ] || [ "$diverged" -ne 0 ]; then
  status=1
fi

echo
echo "== 2b. Each cast fixture: the port's upcast flags against the hosted cast oracle"
cast_count=0
cast_diverged=0
for fixture in "$REPO"/bench/fixtures/typenodes_cast_*.iyi; do
  base="$(basename "$fixture" .iyi)"
  cast_count=$((cast_count + 1))
  "$CAST_ORACLE" "$(native_path "$fixture")" --bare > "$WORK/$base.cast_oracle" 2> "$WORK/$base.cast_oracle.err"
  if [ $? -ne 0 ]; then
    echo "  FAIL: the hosted cast oracle refused $base: $(head -n 1 "$WORK/$base.cast_oracle.err")"
    cast_diverged=$((cast_diverged + 1))
    continue
  fi
  if ! "$CAST_DUMP" "$(native_path "$fixture")" > "$WORK/$base.cast_port" 2>&1; then
    echo "  FAIL: the cast port could not analyse $base"
    cast_diverged=$((cast_diverged + 1))
    continue
  fi
  if cmp -s "$WORK/$base.cast_oracle" "$WORK/$base.cast_port"; then
    echo "  ok: $base ($(wc -l < "$WORK/$base.cast_oracle" | tr -d ' ') cast nodes identical)"
  else
    echo "  FAIL: $base diverges from the hosted cast oracle:"
    diff "$WORK/$base.cast_oracle" "$WORK/$base.cast_port" | head -n 12
    cast_diverged=$((cast_diverged + 1))
  fi
done
echo "  Cast upcast summary: $((cast_count - cast_diverged))/$cast_count cast fixtures match 100%"
if [ "$cast_count" -eq 0 ] || [ "$cast_diverged" -ne 0 ]; then
  status=1
fi

# A mutant must build and execute before its output can establish divergence.
check_outputs_match() {
  rm -f "$WORK/mut_dump$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut_dump$EXE" "$(native_path "$DUMP_SRC")" > "$WORK/mut_build.log" 2>&1 ||
     [ ! -x "$WORK/mut_dump$EXE" ]; then
    echo "INVALID MUTANT: typed dump did not build"
    cat "$WORK/mut_build.log"
    return 0
  fi
  for fixture in "$REPO"/bench/fixtures/typenodes_*.iyi; do
    base="$(basename "$fixture" .iyi)"
    if [ ! -f "$WORK/$base.oracle" ] ||
       ! "$WORK/mut_dump$EXE" "$(native_path "$fixture")" > "$WORK/$base.mut" 2>&1; then
      echo "INVALID MUTANT: typed dump or baseline oracle failed for $base"
      return 0
    fi
    cmp -s "$WORK/$base.oracle" "$WORK/$base.mut" || return 1
  done
  return 0
}

check_cast_outputs_match() {
  rm -f "$WORK/mut_cast$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut_cast$EXE" "$(native_path "$CAST_DUMP_SRC")" > "$WORK/mut_cast_build.log" 2>&1 ||
     [ ! -x "$WORK/mut_cast$EXE" ]; then
    echo "INVALID MUTANT: cast dump did not build"
    cat "$WORK/mut_cast_build.log"
    return 0
  fi
  for fixture in "$REPO"/bench/fixtures/typenodes_cast_*.iyi; do
    base="$(basename "$fixture" .iyi)"
    if [ ! -f "$WORK/$base.cast_oracle" ] ||
       ! "$WORK/mut_cast$EXE" "$(native_path "$fixture")" > "$WORK/$base.cast_mut" 2>&1; then
      echo "INVALID MUTANT: cast dump or baseline oracle failed for $base"
      return 0
    fi
    cmp -s "$WORK/$base.cast_oracle" "$WORK/$base.cast_mut" || return 1
  done
  return 0
}

echo
echo "== 3. Guarded mutation proofs"
MUTATIONS_RUN=0

prove_mutation "generic is typed as its instance, not its metaclass" "$TYPE_NODES" \
  "meta = type_node_metaclass(instance)" \
  "meta = instance" \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "type arguments are not bracketed as type arguments" "$TYPE_NODES" \
  "visitor.bracket_type_args(1)" \
  "visitor.bracket_type_args(0)" \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "union type arguments print with their outer parentheses" "$TYPES_FILE" \
  "@type_args.map { |a| a.devirtualize.arg_full_name }" \
  "@type_args.map { |a| a.devirtualize.full_name }" \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "unbound generic name drops its type variables" "$TOP_LEVEL" \
  '"#{base_full_name}(#{@type_vars.join(", ")})"' \
  '"#{base_full_name}"' \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "nilable cast is typed as its target without Nil" "$TYPE_NODES" \
  "visitor.program.type_merge(TypeQueries.virtual_type(result), visitor.program.nil_type)" \
  "TypeQueries.virtual_type(result)" \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a generic in a type argument is typed as its metaclass" "$TYPE_NODES" \
  "  if visitor.in_type_args?" \
  "  if false" \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "generic instance metaclass drops the generic class's class methods" "$TYPES_FILE" \
  $'    parents << instance_type.generic_type.as(ModuleType).metaclass\n  end\n\n  def generic_instance_type : GenericClassInstanceType\n    @instance_type.as(GenericClassInstanceType)\n  end\n\n  # The class methods of a generic instance are the generic class\'s own (hosted\n  # `delegate defs, macros, to: generic_type`, types.cr 3400).\n  def defs : Hash(String, Array(Def))\n    generic_instance_type.generic_type.as(GenericClassType).metaclass.defs' \
  $'    nil\n  end\n\n  def generic_instance_type : GenericClassInstanceType\n    @instance_type.as(GenericClassInstanceType)\n  end\n\n  # The class methods of a generic instance are the generic class\'s own (hosted\n  # `delegate defs, macros, to: generic_type`, types.cr 3400).\n  def defs : Hash(String, Array(Def))\n    Hash(String, Array(Def)).new' \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "pointerof types its operand, not a pointer to it" "$TYPE_NODES" \
  "visitor.set_type(node, type_node_system(visitor.program).pointer_of(t.as(Type)))" \
  "visitor.set_type(node, t.as(Type))" \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "enum definition is not typed" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  "visit_enum_def(self, node)" \
  "true" \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "uninitialized local is recorded as Nil" "$TYPE_NODES" \
  "visitor.vars[name] = declared" \
  "visitor.vars[name] = visitor.program.nil_type" \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "fun argument is typed from nothing, not the declared record" "$TYPE_NODES" \
  "vars[node.args[i].name] = arg_types[i]" \
  "vars[node.args[i].name] = visitor.program.nil_type" \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "enum members are not walked before the enum is typed" "$TYPE_NODES" \
  "    member.accept(visitor)" \
  "    member.to_s" \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a fun's declared types are not re-resolved by the type system" "$TOP_LEVEL" \
  '              resolved_args.each { |arg_type| f.arg_types << arg_type }' \
  '              node.args.each { |arg| f.arg_types << object_type }' \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a pointerof of a local is refused, in a fun body or anywhere" "$TYPE_NODES" \
  "  if exp.is_a?(Var)" \
  "  if false" \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a generic whose name fails in scope is not rebuilt from its typed arguments" "$TYPE_NODES" \
  "  resolved = generic_of_typed_args(visitor, node)" \
  $'  resolved = type_node_lookup(visitor).lookup(visitor.current_type, node)\n  resolved = nil if resolved.is_a?(LookupError)' \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a union inside a generic owner ignores its visited type arguments" "$TYPE_NODES" \
  "  visitor.set_type(node, visitor.program.type_merge(types))" \
  $'  resolved_u = type_node_lookup(visitor).lookup(visitor.current_type, node)\n  return false if resolved_u.is_a?(LookupError)\n  visitor.set_type(node, resolved_u.as(Type))' \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "self type node ignores scope_type and fails in top-level current_type" "$TYPE_NODES" \
  "  the_self : Type = visitor.scope_type || visitor.current_type" \
  "  the_self : Type = visitor.current_type" \
  -- check_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a cast's upcast flag is not recorded" "$TYPE_NODES" \
  "  node.upcast = upcast
  result = to_type
  if !upcast
    if f = filtered
      result = f.as(Type)
    end
  end
  visitor.set_type(node, TypeQueries.virtual_type(result))" \
  "  node.upcast = false
  result = to_type
  if !upcast
    if f = filtered
      result = f.as(Type)
    end
  end
  visitor.set_type(node, TypeQueries.virtual_type(result))" \
  -- check_cast_outputs_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SELFHOST SEMANTIC TYPE-NODE CHECKS PASSED SUCCESSFULLY!"
else
  echo "SELFHOST SEMANTIC TYPE-NODE CHECKS FAILED"
fi
exit "$status"
