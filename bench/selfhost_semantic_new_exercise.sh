#!/usr/bin/env bash
# Fails when the port's generated `new` methods stop agreeing with the hosted front
# end's (specification S1n: `new`, the generated `new` of each initialize, the
# default `new`, and the targets calls to `new` are given).
#
# Each bench/fixtures/semnew_*.iyi is analysed bare, through the top-level pass, the
# new pass and the main pass, by the hosted oracle (bench/selfhost_semantic_new_oracle.cr)
# and by the port's driver (bench/selfhost_semantic_new_exercise.iyi). Both print the
# same lines: each generated `new` (its signature and body shape) and each `new` call
# (receiver, argument types, result, target). The outputs must be byte-identical.
#
# Mutation proofs patch the port's ported code, rebuild the driver, and require a
# divergence from the hosted oracle. A patch that changes nothing is refused.
#
#   bash bench/selfhost_semantic_new_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")"
IYI="$REPO/bin/iyi"
HOSTED_COMPILER="$REPO/bin/crystal"
NEW_FILE="$REPO/src/compiler/semantic/new.iyi"
TOP_LEVEL_FILE="$REPO/src/compiler/semantic/top_level.iyi"
MAIN_VISITOR_FILE="$REPO/src/compiler/semantic/main_visitor.iyi"
RESTRICTIONS_FILE="$REPO/src/compiler/semantic/restrictions.iyi"
MATCH_FILE="$REPO/src/compiler/semantic/match.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK_NATIVE="$(native_path "$WORK")"

. "$REPO/bench/lib/mutation.sh"
export IYI_PATH="$REPO_NATIVE/src"

echo "== 1. Building the hosted oracle and the port driver"
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing \
  -o "$WORK_NATIVE/oracle$EXE" "$REPO_NATIVE/bench/selfhost_semantic_new_oracle.cr" > "$WORK/oracle_build.log" 2>&1 \
  || { cat "$WORK/oracle_build.log"; echo "FAILED to build the oracle"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/port$EXE" "$REPO_NATIVE/bench/selfhost_semantic_new_exercise.iyi" > "$WORK/port_build.log" 2>&1 \
  || { cat "$WORK/port_build.log"; echo "FAILED to build the port driver"; exit 1; }
echo "  built: oracle, port driver"

echo
echo "== 2. Fixtures: every generated new and new call printed identically by both sides"
fixture_count=0
fixture_bad=0
total_lines=0
for fixture in "$REPO"/bench/fixtures/semnew_*.iyi; do
  fixture_count=$((fixture_count + 1))
  name="$(basename "$fixture")"
  if ! "$WORK/oracle$EXE" "$(native_path "$fixture")" > "$WORK/o.txt" 2> "$WORK/oe.txt"; then
    echo "  ORACLE REFUSED $name: $(head -1 "$WORK/oe.txt")"
    fixture_bad=$((fixture_bad + 1))
    continue
  fi
  if ! "$WORK/port$EXE" "$(native_path "$fixture")" > "$WORK/p.txt" 2> "$WORK/pe.txt"; then
    echo "  PORT FAILED $name: $(head -1 "$WORK/pe.txt")"
    fixture_bad=$((fixture_bad + 1))
    continue
  fi
  if cmp -s "$WORK/o.txt" "$WORK/p.txt"; then
    lines=$(wc -l < "$WORK/o.txt" | tr -d ' ')
    total_lines=$((total_lines + lines))
    echo "  identical: $name ($lines lines)"
  else
    fixture_bad=$((fixture_bad + 1))
    echo "  DIVERGED: $name"
    diff "$WORK/o.txt" "$WORK/p.txt" | awk '{ print "    " $0 }' | head -20
  fi
done
echo "  Parity summary: $((fixture_count - fixture_bad))/$fixture_count fixtures identical ($total_lines lines compared)"
if [ "$fixture_count" -eq 0 ] || [ "$fixture_bad" -ne 0 ]; then
  status=1
fi

# A check for the mutation proofs: rebuilds the port driver from the (patched)
# sources and requires its output to match the hosted oracle on every fixture.
# Returns non-zero when a divergence is found, which is the catch.
invalid_mutant() {
  echo "INVALID MUTANT: $*"
  [ "${_PM_ARMED:-0}" = 1 ]
}
check_new_diverge() {
  rm -f "$WORK/port_m$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/port_m$EXE" "$REPO_NATIVE/bench/selfhost_semantic_new_exercise.iyi" > "$WORK/port_m_build.log" 2>&1 ||
     [ ! -x "$WORK/port_m$EXE" ]; then
    cat "$WORK/port_m_build.log"
    invalid_mutant "new-method driver failed to build"
    return $?
  fi
  for fixture in "$REPO"/bench/fixtures/semnew_*.iyi; do
    if ! "$WORK/oracle$EXE" "$(native_path "$fixture")" > "$WORK/mo.txt" 2>/dev/null ||
       ! "$WORK/port_m$EXE" "$(native_path "$fixture")" > "$WORK/mp.txt" 2>/dev/null; then
      invalid_mutant "new-method oracle or driver failed"
      return $?
    fi
    cmp -s "$WORK/mo.txt" "$WORK/mp.txt" || return 1
  done
  return 0
}

echo
echo "== 3. Guarded mutation proofs (patch, rebuild, the gate must fail)"
MUTATIONS_RUN=0

prove_mutation "allocate's type not given the instance type" "$MAIN_VISITOR_FILE" \
  "          set_type(node, instance)" \
  "          set_type(node, sc)" \
  -- check_new_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "generated new drops its finalizer" "$NEW_FILE" \
  "  exps << If.new(RespondsTo.new(Var.new(\"_\"), \"finalize\"), Call.new(Path.global(\"GC\"), \"add_finalizer\", [Var.new(\"_\")] of ASTNode))" \
  "  exps << Nop.new" \
  -- check_new_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "generated new passes its arguments in the wrong order" "$NEW_FILE" \
  "      new_vars << passed" \
  "      new_vars.insert(0, passed)" \
  -- check_new_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "explicit initialize is left public" "$NEW_FILE" \
  "    if ex.original.visibility == Visibility::Public" \
  "    if false" \
  -- check_new_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# The binding moved out of MainVisitor#restriction_type into ArgRestriction.lookup_bound, which
# restriction_type now calls: the mutation follows the code that answers the question.
prove_mutation "a generic receiver does not bind its type parameters in a restriction" "$RESTRICTIONS_FILE" \
  "    if owner.is_a?(GenericInstanceType)" \
  "    if false" \
  -- check_new_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a generic class inherits its default new instead of owning one" "$NEW_FILE" \
  '      define_default_generic_new(program, sub.as(GenericClassType))' \
  '      nil' \
  -- check_new_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a generic receiver does not bind its type parameters in a lookup" "$MAIN_VISITOR_FILE" \
  $'if instance = receiver_instance(owner)\n      found = ArgRestriction.lookup_bound(type_node_system(@program), @current_type, node, instance)' \
  $'if instance = receiver_instance(owner)\n      found = LookupError.new("unbound")' \
  -- check_new_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a generic receiver does not bind its type parameters in a restriction" "$MATCH_FILE" \
  "restriction = ArgRestriction.of_bound(ts, defining, arg, owner, bound)" \
  "restriction = ArgRestriction.of_bound(ts, defining, arg, nil, bound)" \
  -- check_new_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a generic child copies initializers beyond the first ancestor" "$NEW_FILE" \
  '  inits = first_initializer_defs(type)' \
  '  inits = MethodLookup.all_defs(type, "initialize", [] of Def)' \
  -- check_new_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "OK: the port's new methods agree with the hosted front end on every fixture and mutation is caught"
else
  echo "FAILED: the port's new methods diverge from the hosted front end (see above)"
fi
exit "$status"
