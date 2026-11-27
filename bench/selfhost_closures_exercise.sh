#!/usr/bin/env bash
# Compare lexical closure facts with the hosted compiler on the same fixture prelude.
# Floors only rise once proven on a green head. The semclos_local WIP-only 4
# counted an external lib fun, which has no body or lexical frame; corrected to 3.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
cd "$REPO" || exit 1
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
REPO_NATIVE="$(native_path "$REPO")"
WORK_NATIVE="$(native_path "$WORK")"
. "$REPO/bench/lib/mutation.sh"
if [ "$HOST_OS" = windows ]; then
  PRELUDE_PATH="$REPO_NATIVE/bench/fixtures/semclos_prelude;$REPO_NATIVE/src"
else
  PRELUDE_PATH="$REPO_NATIVE/bench/fixtures/semclos_prelude:$REPO_NATIVE/src"
fi
export CRYSTAL_PATH="$REPO_NATIVE/src" IYI_CONFIG_PATH="$REPO_NATIVE/src" IYI_PATH="$REPO_NATIVE/src"
HOSTED_COMPILER="$REPO/bin/crystal"
HOST_LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}"
ORACLE="$WORK/oracle$EXE"
PORT="$WORK/port$EXE"
FLOOR="$REPO/bench/selfhost_closures.floor"

printf '%s\n' '== 1. Building the oracle and closure facts driver'
if ! LLVM_CONFIG="$HOST_LLVM_CONFIG" "$HOSTED_COMPILER" build -Di_know_what_im_doing -o "$WORK_NATIVE/oracle$EXE" "$REPO_NATIVE/bench/selfhost_closure_oracle.cr" > "$WORK/oracle.log" 2>&1; then
  awk 'NR<=30' "$WORK/oracle.log"
  exit 1
fi
build_port() {
  rm -f "$PORT"
  "$REPO/bin/iyi" build -o "$WORK_NATIVE/port$EXE" "$REPO_NATIVE/bench/selfhost_closures_exercise.iyi" > "$WORK/port.log" 2>&1 && [ -x "$PORT" ] || { awk 'NR<=30' "$WORK/port.log"; return 1; }
}
build_port || exit 1
if ! "$PORT" > "$WORK/self-check.log" 2>&1; then
  awk 'NR<=30' "$WORK/self-check.log"
  exit 1
fi

compare_fixtures() {
  local fixture rel expected count
  for fixture in bench/fixtures/semclos_*.iyi; do
    rel="$fixture"
    IYI_PATH="$PRELUDE_PATH" "$ORACLE" "$fixture" > "$WORK/oracle.out" 2> "$WORK/oracle.err" || { awk 'NR<=10' "$WORK/oracle.err"; return 2; }
    "$PORT" "$fixture" > "$WORK/port.out" 2> "$WORK/port.err" || { awk 'NR<=10' "$WORK/port.err"; return 2; }
    if ! diff -u "$WORK/oracle.out" "$WORK/port.out"; then
      printf 'DIFFERENT: %s\n' "$rel"
      return 1
    fi
    count=$(awk 'END {print NR+0}' "$WORK/oracle.out")
    expected=$(awk -v name="$rel" '$1 == name { print $2 }' "$FLOOR")
    if [ -z "$expected" ] || [ "$count" != "$expected" ] || [ "$count" -eq 0 ]; then
      printf 'FLOOR MISMATCH: %s %s expected %s\n' "$rel" "$count" "${expected:-missing}"
      return 1
    fi
    printf '  %s: %s identical frames\n' "$rel" "$count"
  done
}

printf '%s\n' '== 2. Comparing closure facts'
compare_fixtures || exit 1
refusal_check() {
  "$PORT" --refusals bench/fixtures/semclos_literal_changing.iyi > "$WORK/refusals.out" 2>&1 || return 2
  awk '/^refusal: closured variable value assigned values of more than one type$/ { found=1 } END { exit !found }' "$WORK/refusals.out"
}
if ! refusal_check; then
  printf '%s\n' 'MISSING REFUSAL: changing captured variable type'
  exit 1
fi
invalid_mutant() {
  echo "INVALID MUTANT: $*"
  [ "${_PM_ARMED:-0}" = 1 ]
}
mutation_check() {
  local rc
  if ! build_port; then
    invalid_mutant "closure driver failed to build"
    return $?
  fi
  if compare_fixtures && refusal_check; then
    return 0
  else
    rc=$?
    if [ "$rc" -ne 1 ]; then
      invalid_mutant "closure oracle or driver could not run"
      return $?
    fi
    return 1
  fi
}

# An uncompilable mutant is not evidence that semantic facts changed.
check_implicit_self_mutant() {
  if ! build_port; then
    echo 'INVALID: implicit-self mutant did not build'
    return 0
  fi
  local fixture=bench/fixtures/semclos_implicit_self.iyi
  if ! IYI_PATH="$PRELUDE_PATH" "$ORACLE" "$fixture" > "$WORK/implicit.oracle" 2> "$WORK/implicit.err" ||
     ! "$PORT" "$fixture" > "$WORK/implicit.port" 2>> "$WORK/implicit.err"; then
    echo 'INVALID: implicit-self mutant did not analyse the fixture'
    return 0
  fi
  cmp -s "$WORK/implicit.oracle" "$WORK/implicit.port"
}

printf '%s\n' '== 3. Mutation proofs'
status=0
prove_mutation 'captured variable is omitted' "$REPO/src/compiler/semantic/closures.iyi" \
  'binding.captured = true' 'binding.captured = false' -- mutation_check || status=1
prove_mutation 'literal parameter does not shadow its outer variable' "$REPO/src/compiler/semantic/closures.iyi" \
  'proc_def.args.each do |arg|' '([] of Compiler::Syntax::Ast::Arg).each do |arg|' -- mutation_check || status=1
prove_mutation 'assignment does not declare a local' "$REPO/src/compiler/semantic/closures.iyi" \
  '@frame.bindings << ClosureBinding.new(ClosureVar.new(variable.name, type))' 'nil' -- mutation_check || status=1
prove_mutation 'blocks are independent closure contexts' "$REPO/src/compiler/semantic/closures.iyi" \
  'while current.kind == FrameKind::Block' 'while false && current.kind == FrameKind::Block' -- mutation_check || status=1
prove_mutation 'instance variable does not capture self' "$REPO/src/compiler/semantic/closures.iyi" \
  'def visit(node : InstanceVar) : Bool
    capture_self' 'def visit(node : InstanceVar) : Bool
    nil' -- mutation_check || status=1
prove_mutation 'implicit instance call does not capture self' "$REPO/src/compiler/semantic/closures.iyi" \
  'capture_self if node.is_a?(Call) && node.as(Call).obj.nil? && implicit_self_call?(node.as(Call))' \
  'nil' -- check_implicit_self_mutant || status=1
prove_mutation 'reassignment after capture is not mutable' "$REPO/src/compiler/semantic/closures.iyi" \
  'elsif assignment && binding.captured' 'elsif false && assignment && binding.captured' -- mutation_check || status=1
prove_mutation 'changing captured variable is not refused' "$REPO/src/compiler/semantic/closures.iyi" \
  'if binding.assigned_types.size > 1' 'if false && binding.assigned_types.size > 1' -- mutation_check || status=1
prove_mutation 'shadowed parameters lose outer insertion order' "$REPO/src/compiler/semantic/closures.iyi" \
  'parent.visible_names' '[] of String' -- mutation_check || status=1
prove_mutation 'loop assignment is not mutable' "$REPO/src/compiler/semantic/closures.iyi" \
  'binding.variable.mutably = true if @inside_while' 'binding.variable.mutably = false if @inside_while' -- mutation_check || status=1
prove_mutation 'captured block argument is omitted from its def frame' "$REPO/src/compiler/semantic/closures.iyi" \
  'if block_arg = def_node.block_arg' 'if block_arg = (false ? def_node.block_arg : nil)' -- mutation_check || status=1
prove_mutation 'block locals are owned by the enclosing frame' "$REPO/src/compiler/semantic/closures.iyi" \
  'node.body.accept(ClosureWalk.new(@facts, @visitor, frame, @inside_while))' 'node.body.accept(ClosureWalk.new(@facts, @visitor, @frame, @inside_while))' -- mutation_check || status=1
prove_mutation 'a proc that captures a variable has no closure context' "$REPO/src/compiler/semantic/closures.iyi" \
  'break if part.node.node_id == owner_context.node.node_id
            part.closure = true if part.kind == FrameKind::Proc' \
  'break if part.node.node_id == owner_context.node.node_id
            part.closure = false if part.kind == FrameKind::Proc' -- mutation_check || status=1
prove_mutation 'program frame omits captured thread block' "$REPO/src/compiler/semantic/closures.iyi" \
  'roots << {frame, "top"} if frame.kind == FrameKind::Program' 'roots << {frame, "top"} if false && frame.kind == FrameKind::Program' -- mutation_check || status=1
if [ "$status" -ne 0 ]; then
  printf '%s\n' '== SOME CLOSURE CHECKS FAILED'
  exit 1
fi
printf '%s\n' '== ALL CLOSURE CHECKS PASSED'
