#!/usr/bin/env bash
# Exercises the self-hosting compiler AST model, visitor, transformer, and out-of-band NodeMap side storage.
#
#   bash bench/selfhost_ast_exercise.sh
#
# Verifies:
# 1. Plain compilation and execution of selfhost AST exercise
# 2. --release compilation and execution
# 3. Complete coverage of all 104 concrete AST node kinds across:
#    - Construction
#    - Cloning (with location, end_location, doc, visibility, and instance identity isolation)
#    - Structural equality and hash distribution
#    - to_s string formatting
# 4. Visitor and ToSVisitor traversal
# 5. Transformer framework tree modification
# 6. Out-of-band NodeMap side storage without reopening node types
# 7. Guarded mutation proofs verifying that test checks catch injected AST/visitor/transformer defects
#
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh"
require_test_host
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE="$(native_path "$REPO")"
WORK_NATIVE="$(native_path "$WORK")"
export IYI_PATH="$REPO_NATIVE/src"

. "$REPO/bench/lib/mutation.sh"

status=0

echo "== 1. Building and running selfhost AST exercise (plain mode)"
"$IYI" build -o "$WORK/exercise-plain" "$REPO/bench/selfhost_ast_exercise.iyi"
"$WORK/exercise-plain" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out"

echo
echo "== Checking reported verification counts in plain mode"
for phrase in \
  "testing construction of all 104 concrete AST node kinds... ok (104 node kinds constructed)" \
  "testing cloning for all 104 concrete AST node kinds... ok (104 node kinds cloned with location and identity isolation)" \
  "testing equality and hashing for all 104 concrete AST node kinds... ok (104 node kinds verified for structural equality and hashing)" \
  "testing to_s string formatting for all 104 concrete AST node kinds... ok (104 node kinds verified for to_s formatting)" \
  "testing Visitor and ToSVisitor traversal... ok (visitor traversal and ToSVisitor formatting verified)" \
  "testing Transformer framework... ok (transformer tree modification verified)" \
  "testing out-of-band NodeMap side storage (no reopening of node types)... ok (NodeMap out-of-band side storage verified)" \
  "ALL SELFHOST AST CHECKS PASSED SUCCESSFULLY!"; do
  # Join the exercise's two-line "testing ... ok (...)" pair before matching.
  joined="$(tr '\n' ' ' < "$WORK/plain.out")"
  if ! grep -qF "$phrase" <<< "$joined"; then
    echo "FAIL: Missing verification phrase in plain output:"
    echo "  $phrase"
    status=1
  fi
done

echo
echo "== 2. Building and running selfhost AST exercise (--release mode)"
"$IYI" build --release -o "$WORK/exercise-release" "$REPO/bench/selfhost_ast_exercise.iyi"
"$WORK/exercise-release" > "$WORK/release.out" 2>&1
cat "$WORK/release.out"

if ! grep -qF "ALL SELFHOST AST CHECKS PASSED SUCCESSFULLY!" "$WORK/release.out"; then
  echo "FAIL: selfhost AST exercise did not complete successfully in release mode"
  status=1
fi

echo
echo "== RangeLiteral clone and equality against the hosted AST"
cat > "$WORK/range-hosted.cr" <<'HOSTED_RANGE'
require "compiler/iyi/syntax"
inclusive = Iyi::RangeLiteral.new(Iyi::NumberLiteral.new("1"), Iyi::NumberLiteral.new("10"), false)
exclusive = Iyi::RangeLiteral.new(Iyi::NumberLiteral.new("1"), Iyi::NumberLiteral.new("10"), true)
puts inclusive.clone.as(Iyi::RangeLiteral).exclusive?
puts exclusive.clone.as(Iyi::RangeLiteral).exclusive?
puts inclusive == exclusive
puts exclusive == exclusive.clone.as(Iyi::RangeLiteral)
HOSTED_RANGE
cat > "$WORK/range-port.iyi" <<'PORT_RANGE'
import compiler/syntax/ast::{NumberLiteral, RangeLiteral}
inclusive = RangeLiteral.new(NumberLiteral.new("1"), NumberLiteral.new("10"), false)
exclusive = RangeLiteral.new(NumberLiteral.new("1"), NumberLiteral.new("10"), true)
puts inclusive.clone.exclusive
puts exclusive.clone.exclusive
puts inclusive == exclusive
puts exclusive == exclusive.clone
PORT_RANGE
CRYSTAL_PATH="$REPO_NATIVE/src" "$REPO/bin/crystal" build -o "$WORK_NATIVE/range-hosted$EXE" "$WORK_NATIVE/range-hosted.cr"
"$WORK/range-hosted$EXE" > "$WORK/range-hosted.out"
# A compiler or launch failure is not a caught behavioral mutation.
check_range_exclusive() {
  rm -f "$WORK/range-port$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/range-port$EXE" "$WORK_NATIVE/range-port.iyi" > "$WORK/range-build.log" 2>&1 ||
     ! "$WORK/range-port$EXE" > "$WORK/range-port.out" 2>&1; then
    echo "range probe could not build or run"
    cat "$WORK/range-build.log"
    [ "${_PM_ARMED:-0}" = 1 ] && return 0
    return 1
  fi
  cmp -s "$WORK/range-hosted.out" "$WORK/range-port.out"
}
if check_range_exclusive; then
  echo "  inclusive and exclusive range clones and equality match hosted AST"
else
  echo "FAIL: RangeLiteral clone or equality differs from hosted AST"
  status=1
fi

echo
echo "== 3. Guarded mutation proofs (verify patch applies, exercise fails, revert passes)"

# The exercise must fail on the mutated tree; a passing run is the surviving mutation.
check_ast_exercise_fails() {
  "$IYI" run "$REPO/bench/selfhost_ast_exercise.iyi"
}

# Mutation 1: Alter ASTNode#clone to drop doc preservation
prove_mutation "mutation 1: altering ASTNode#clone doc preservation" \
  "$REPO/src/compiler/syntax/ast.iyi" "c.doc = @doc" "c.doc = nil" \
  -- check_ast_exercise_fails || status=1

# Mutation 2: Alter Var#== structural equality. The original sed replaced every
# (@name == other.name) line (28 sites, Var among them), so every site is replaced.
prove_mutation_all "mutation 2: altering Var#== structural equality" \
  "$REPO/src/compiler/syntax/ast.iyi" \
  "(@name == other.name)" "false" \
  -- check_ast_exercise_fails || status=1

# Mutation 3: Alter NodeMap#[]= side storage assignment
prove_mutation "mutation 3: altering NodeMap#[]= key storage" \
  "$REPO/src/compiler/syntax/ast.iyi" \
  "@store[node.node_id] = value" "@store[0_u64] = value" \
  -- check_ast_exercise_fails || status=1

# Mutation 4: Alter Transformer#transform(Assign) target transformation. Every
# occurrence is replaced, as the original sed did (the Assign and OpAssign sites).
prove_mutation_all "mutation 4: altering Transformer#transform(Assign) target recursion" \
  "$REPO/src/compiler/syntax/transformer.iyi" \
  "node.target = node.target.transform(self)" "# node.target bypassed" \
  -- check_ast_exercise_fails || status=1

# Mutation 5: Alter ToSVisitor#visit formatting. Every node.to_s(@sb) is replaced,
# as the original sed did, so every visit method formats as "mutated".
prove_mutation_all "mutation 5: altering ToSVisitor#visit(Assign) formatting" \
  "$REPO/src/compiler/syntax/visitor.iyi" \
  "node.to_s(@sb)" "@sb << \"mutated\"" \
  -- check_ast_exercise_fails || status=1

prove_mutation "RangeLiteral clone drops exclusive" \
  "$REPO/src/compiler/syntax/ast.iyi" \
  "RangeLiteral.new(@from.clone, @to.clone, @exclusive)" \
  "RangeLiteral.new(@from.clone, @to.clone, false)" \
  -- check_range_exclusive || status=1
prove_mutation "RangeLiteral equality ignores exclusive" \
  "$REPO/src/compiler/syntax/ast.iyi" \
  "(@from == other.from) && (@to == other.to) && (@exclusive == other.exclusive)" \
  "(@from == other.from) && (@to == other.to)" \
  -- check_range_exclusive || status=1

echo
echo "== Verification clean state confirmed"
"$WORK/exercise-release" >/dev/null

echo
if [ "$status" -eq 0 ]; then
  echo "PASS: selfhost AST exercise and mutation suite passed cleanly"
else
  echo "FAIL: selfhost AST exercise had failures"
fi

exit $status
