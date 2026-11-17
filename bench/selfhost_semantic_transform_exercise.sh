#!/usr/bin/env bash
# Fails when the iyi transformers stop agreeing with the hosted ones they replace.
#
# Slice S1e of the native self-host (SPEC.md Phase S). The hosted transformers
# are src/compiler/iyi/semantic/{normalizer,literal_expander,cleanup_transformer,
# math_interpreter}.cr; the port lives in src/compiler/semantic/{normalizer,
# literal_expander,cleanup,math_interpreter}.iyi. Every fixture bench/fixtures/
# semtx_*.iyi is parsed, rewritten by the oracle (the hosted pipeline) and by the
# port, both dumped with the same AST printer, and required byte-identical.
# A check that ran only the port would pass for a transformer that rewrote
# nothing at all.
#
# Transform table: hosted transform -> port, as of this increment
# (every row is the normalizer; "not ported" names what the gate cannot see):
#   Program#normalize            NormalizerProgram.normalize          ported
#                                macro_expansion (skip of the expansion's
#                                own Expressions/Defer lowering)      not ported:
#                                needs the VirtualFile location check and
#                                MainVisitor#iyi_splice_macro_defers
#   Expressions                  transform(Expressions)               ported
#   Defer                        transform(Defer)                     ported
#   apply_defers                 apply_defers                         ported
#   Call (group, super, cmp)     transform(Call)                      ported
#   Call group propagated flag   expand_iyi_group(node, propagated)   ported
#   Def (block arg pruning)      transform(Def)                       ported
#   Macro                        transform(Macro)                     ported
#   If                           transform(If)                        ported
#   Propagate (!)                transform(Propagate)                 ported
#                                (error_construct "end!"); iyi_bang_call
#                                not ported: IsA has no such field
#   Recover                      transform(Recover)                   ported
#   Unless                       transform(Unless)                    ported
#   Until                        transform(Until)                     ported
#   Assign                       transform(Assign)                    ported
#   OpAssign (call/index/simple) transform(OpAssign) + helpers        ported
#   StringInterpolation          transform(StringInterpolation)       ported
#   Block (unpacks)              transform(Block)                     ported (fixed:
#                                the body merge duplicated the unpacks and a
#                                single-expression body was dropped)
#   Union                        transform(Union)                     ported
#
# Mutation proofs follow the rule the other selfhost gates use: each patched
# file is compared against the original, and a patch that matched nothing is
# reported as proving nothing rather than passing quietly.
#
#   bash bench/selfhost_semantic_transform_exercise.sh
set -u
status=0
diverged=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")"
export IYI_PATH="$REPO_NATIVE/src"
IYI="$REPO/bin/iyi"
HOSTED_COMPILER="$REPO/bin/crystal"
NORM="$REPO/src/compiler/semantic/normalizer.iyi"
PORT_DRIVER="$REPO/bench/selfhost_semantic_transform_exercise.iyi"
ORACLE_SRC="$REPO/bench/selfhost_semantic_transform_oracle.cr"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")"
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"

# The port and the hosted oracle each carry one AST printer, in their own
# driver file: bench/selfhost_semantic_transform_exercise.iyi and
# bench/selfhost_semantic_transform_oracle.cr. Both print every node kind the
# normalizer gate prints, in the same layout, and both list TypeOf, which the
# expander writes for every untyped literal (an unlisted class would print
# only its name on one side). The gate reads no other gate's files, so moving
# a line in the normalizer gate cannot break this one.

echo "== 1. Building the port driver and the hosted oracle"
cp "$PORT_DRIVER" "$WORK/semtx_port.iyi"
cp "$ORACLE_SRC" "$WORK/semtx_oracle.cr"
if ! grep -qF "when TypeOf" "$WORK/semtx_port.iyi" || ! grep -qF "when Iyi::TypeOf" "$WORK/semtx_oracle.cr"; then
  echo "  the AST printer is missing from the driver files"
  exit 1
fi
"$IYI" build -o "$WORK_NATIVE/port_exercise$EXE" "$WORK_NATIVE/semtx_port.iyi" || { echo "  PORT DRIVER DOES NOT BUILD"; exit 1; }
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing \
    -o "$WORK_NATIVE/dump_hosted$EXE" "$WORK_NATIVE/semtx_oracle.cr" || { echo "  HOSTED ORACLE DOES NOT BUILD"; exit 1; }
if [ ! -x "$WORK/dump_hosted$EXE" ]; then
  echo "  HOSTED ORACLE DOES NOT BUILD"
  exit 1
fi

echo
echo "== 2. Rewritten tree comparison against the hosted transformers"
fixture_count=0
total_matched_nodes=0
for fixture in "$REPO"/bench/fixtures/semtx_*.iyi; do
  fixture_name="bench/fixtures/$(basename "$fixture")"
  "$WORK/port_exercise$EXE" "$(native_path "$fixture")" > "$WORK/iyi.ast" 2>"$WORK/iyi.err" || {
    echo "  $fixture_name: PORT FAILED"; cat "$WORK/iyi.err"; diverged=$((diverged + 1)); status=1; fixture_count=$((fixture_count + 1)); continue; }
  IYI_PATH="$REPO_NATIVE/src" "$WORK/dump_hosted$EXE" "$(native_path "$fixture")" > "$WORK/oracle.ast" 2>"$WORK/oracle.err" || {
    echo "  $fixture_name: HOSTED ORACLE FAILED"; cat "$WORK/oracle.err"; diverged=$((diverged + 1)); status=1; fixture_count=$((fixture_count + 1)); continue; }
  if ! cmp -s "$WORK/iyi.ast" "$WORK/oracle.ast"; then
    echo "  $fixture_name: REWRITTEN TREES DIFFER"
    diverged=$((diverged + 1))
    diff -u "$WORK/oracle.ast" "$WORK/iyi.ast" | head -40
    status=1
  else
    nodes_count=$(IYI_PATH="$REPO_NATIVE/src" "$WORK/dump_hosted$EXE" "$(native_path "$fixture")" --count)
    echo "  $fixture_name: identical ($nodes_count rewritten nodes match the hosted transformers)"
    total_matched_nodes=$((total_matched_nodes + nodes_count))
  fi
  fixture_count=$((fixture_count + 1))
done
echo "  Parity summary: $((fixture_count - diverged))/$fixture_count fixtures rewrite identically ($total_matched_nodes total nodes)"

echo
echo "== 3. Mutation proofs: each one must make the comparison above fail"
# A patch to the port that the gate must catch. The port driver is rebuilt
# from the patched normalizer and compared with the hosted oracle on every
# fixture; only a differing tree from a runnable mutant counts as caught.
MUTATIONS_RUN=0
check_transform_agrees() {
  "$IYI" build -o "$WORK_NATIVE/mut_port$EXE" "$WORK_NATIVE/semtx_port.iyi" > /dev/null 2>&1 || { echo "INVALID MUTANT: transform driver did not build"; return 0; }
  for fixture in "$REPO"/bench/fixtures/semtx_*.iyi; do
    "$WORK/mut_port$EXE" "$(native_path "$fixture")" > "$WORK/mut_iyi.ast" 2> /dev/null || { echo "INVALID MUTANT: transform driver or oracle failed"; return 0; }
    IYI_PATH="$REPO_NATIVE/src" "$WORK/dump_hosted$EXE" "$(native_path "$fixture")" > "$WORK/mut_hosted.ast" || { echo "INVALID MUTANT: transform driver or oracle failed"; return 0; }
    cmp -s "$WORK/mut_iyi.ast" "$WORK/mut_hosted.ast" || return 1
  done
  return 0
}

MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a group under a propagated bang keeps its join" "$NORM" 'rewritten << Call.new(group_var.clone, "join").at(node) unless propagated' 'rewritten << Call.new(group_var.clone, "join").at(node)' -- check_transform_agrees || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a bang on a group does not mark it propagated" "$NORM" '@propagating_group = true' '@propagating_group = false' -- check_transform_agrees || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "the propagated mark is never consumed" "$NORM" 'propagated = @propagating_group' 'propagated = false' -- check_transform_agrees || status=1
# The normalizer drops an unrestricted block parameter the def never reads, and what "reads" means is
# decided by the parser (semtx_block_arg_used.iyi: `keeps` reads it, `drops` only yields).
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a read of the block parameter does not mark the def as using it" "$REPO/src/compiler/syntax/parser.iyi" '@uses_block_arg = true if name == block_name' '@uses_block_arg = false if name == block_name' -- check_transform_agrees || status=1
echo "  $MUTATIONS_RUN mutation proofs run"

echo
echo "== 4. Math folding: the port's math interpreter against the hosted one"
MATH="$REPO/src/compiler/semantic/math_interpreter.iyi"
MATH_DRIVER="$REPO/bench/selfhost_semantic_math_exercise.iyi"
MATH_ORACLE_SRC="$REPO/bench/selfhost_semantic_math_oracle.cr"
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing \
    -o "$WORK_NATIVE/math_oracle$EXE" "$(native_path "$MATH_ORACLE_SRC")" > "$WORK/math_oracle.log" 2>&1 || { echo "  HOSTED MATH ORACLE DOES NOT BUILD"; cat "$WORK/math_oracle.log"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/math_port$EXE" "$(native_path "$MATH_DRIVER")" > "$WORK/math_port.log" 2>&1 || { echo "  MATH PORT DRIVER DOES NOT BUILD"; cat "$WORK/math_port.log"; exit 1; }
if "$WORK/math_port$EXE" > "$WORK/math_bare.log" 2>&1; then
  echo "  bare math driver: literal limits and error messages passed"
else
  echo "  bare math driver: FAILED"; cat "$WORK/math_bare.log"; status=1
fi
# When the port's driver dies on a fixture (a signal leaves no message), name what it printed last and the
# expressions that kill it alone, so the log of a host this was not written on says which fold it was.
math_failed_alone() {
  local fixture="$1" line n=0 rc
  echo "    the last lines the port printed before it stopped:"
  tail -n 3 "$WORK/math_iyi.txt" | sed 's/^/      /'
  echo "    expressions the port's driver fails on alone:"
  while IFS= read -r line; do
    case "$line" in '' | '#'*) continue ;; esac
    n=$((n + 1))
    printf '%s\n' "$line" > "$WORK/math_one.iyi"
    "$WORK/math_port$EXE" "$WORK_NATIVE/math_one.iyi" > /dev/null 2> "$WORK/math_one.err"
    rc=$?
    [ "$rc" -eq 0 ] || echo "      $n: $line (status $rc) $(head -n 1 "$WORK/math_one.err")"
  done < "$fixture"
}

math_count=0
math_diverged=0
math_matched=0
for fixture in "$REPO"/bench/fixtures/semtx_math_*.iyi; do
  name="bench/fixtures/$(basename "$fixture")"
  if [ "$(basename "$fixture")" = "semtx_math_refused.iyi" ]; then continue; fi
  math_count=$((math_count + 1))
  "$WORK/math_port$EXE" "$(native_path "$fixture")" > "$WORK/math_iyi.txt" 2> "$WORK/math_iyi.err" || {
    echo "  $name: MATH PORT FAILED"; cat "$WORK/math_iyi.err"; math_failed_alone "$fixture"; math_diverged=$((math_diverged + 1)); status=1; continue; }
  "$WORK/math_oracle$EXE" "$(native_path "$fixture")" > "$WORK/math_oracle.txt" 2> "$WORK/math_oracle.err" || {
    echo "  $name: HOSTED MATH ORACLE FAILED"; cat "$WORK/math_oracle.err"; math_diverged=$((math_diverged + 1)); status=1; continue; }
  if cmp -s "$WORK/math_iyi.txt" "$WORK/math_oracle.txt"; then
    n=$(grep -c ': value=\|: error=' "$WORK/math_oracle.txt")
    echo "  $name: identical ($n expressions fold to the same value or message)"
    math_matched=$((math_matched + n))
  else
    echo "  $name: FOLDS DIFFER"
    diff -u "$WORK/math_oracle.txt" "$WORK/math_iyi.txt" | head -40
    math_diverged=$((math_diverged + 1))
    status=1
  fi
done
echo "  Parity summary: math $((math_count - math_diverged))/$math_count fixtures fold identically ($math_matched expressions)"

# The refused fixture: the port must refuse every expression by name, so the
# hosted answer is not compared on it. A line that is answered instead fails.
REFUSED="$REPO/bench/fixtures/semtx_math_refused.iyi"
if "$WORK/math_port$EXE" "$(native_path "$REFUSED")" > "$WORK/math_refused.txt" 2>/dev/null \
   && [ "$(grep -c ': refused=' "$WORK/math_refused.txt")" -eq "$(grep -cv '^#\|^$' "$REFUSED")" ] \
   && ! grep -qv ': refused=' "$WORK/math_refused.txt"; then
  echo "  bench/fixtures/semtx_math_refused.iyi: every expression refused by name ($(grep -c ': refused=' "$WORK/math_refused.txt") lines)"
else
  echo "  bench/fixtures/semtx_math_refused.iyi: A LINE WAS ANSWERED, NOT REFUSED"
  cat "$WORK/math_refused.txt"
  status=1
fi

# A mutation must build and reach a differing result, not merely crash.
: > "$WORK/math-mutation-diffs.log"
check_math_agrees() {
  if ! "$IYI" build -o "$WORK_NATIVE/math_mut_port$EXE" "$(native_path "$MATH_DRIVER")" > "$WORK/math-mut-build.log" 2>&1; then
    echo "INVALID MUTANT: math driver did not build"
    cat "$WORK/math-mut-build.log" >> "$WORK/math-mut.invalid"
    return 0
  fi
  local bare_failed=0
  "$WORK/math_mut_port$EXE" > "$WORK/math-mut-bare.log" 2>&1 || bare_failed=1
  if [ "$#" -eq 0 ]; then
    set -- "$REPO"/bench/fixtures/semtx_math_*.iyi
  fi
  for fixture in "$@"; do
    if [ "$(basename "$fixture")" = "semtx_math_refused.iyi" ]; then continue; fi
    if ! "$WORK/math_mut_port$EXE" "$(native_path "$fixture")" > "$WORK/math_mut.txt" 2> "$WORK/math-mut-run.err"; then
      echo "INVALID MUTANT: math driver failed on $fixture"
      echo "mutant failed to execute $fixture" >> "$WORK/math-mut.invalid"
      cat "$WORK/math-mut-run.err" >> "$WORK/math-mut.invalid"
      return 0
    fi
    if ! "$WORK/math_oracle$EXE" "$(native_path "$fixture")" > "$WORK/math_mut_oracle.txt" 2> "$WORK/math-oracle-run.err"; then
      echo "INVALID MUTANT: math oracle failed on $fixture"
      echo "oracle failed to execute $fixture" >> "$WORK/math-mut.invalid"
      cat "$WORK/math-oracle-run.err" >> "$WORK/math-mut.invalid"
      return 0
    fi
    if ! cmp -s "$WORK/math_mut.txt" "$WORK/math_mut_oracle.txt"; then
      echo "  mutant differs on $(basename "$fixture"):" >> "$WORK/math-mutation-diffs.log"
      diff -u "$WORK/math_mut_oracle.txt" "$WORK/math_mut.txt" | head -20 >> "$WORK/math-mutation-diffs.log"
      return 1
    fi
  done
  if [ "$bare_failed" -ne 0 ]; then
    echo "INVALID MUTANT: math driver failed its bare limit checks without a fixture difference"
    echo "mutant failed the bare limit checks without a fixture difference" >> "$WORK/math-mut.invalid"
    cat "$WORK/math-mut-bare.log" >> "$WORK/math-mut.invalid"
    return 0
  fi
  return 0
}
MATH_MUTATIONS=0
MATH_MUTATIONS=$((MATH_MUTATIONS + 1))
prove_mutation "a wrapped result keeps the bits above its kind" "$MATH" 'low = value & mask_of(kind)' 'low = value' -- check_math_agrees || status=1
MATH_MUTATIONS=$((MATH_MUTATIONS + 1))
prove_mutation "a right shift past the width loses the sign of a negative value" "$MATH" 'MathValue.new(value.negative? ? umax : 0_u128, value.kind)' 'MathValue.new(0_u128, value.kind)' -- check_math_agrees || status=1
MATH_MUTATIONS=$((MATH_MUTATIONS + 1))
prove_mutation "a result one above the kind's limit is accepted" "$MATH" 'return MathError.new("Arithmetic overflow") if magnitude > upper_magnitude(kind)' 'return MathError.new("Arithmetic overflow") if magnitude > upper_magnitude(kind) && magnitude - upper_magnitude(kind) > 1_u128' -- check_math_agrees || status=1
MATH_MUTATIONS=$((MATH_MUTATIONS + 1))
prove_mutation "a mixed-signedness divisor is not reinterpreted" "$MATH" 'return right if left.kind.signed? == right.kind.signed?' 'return right' -- check_math_agrees || status=1
MATH_MUTATIONS=$((MATH_MUTATIONS + 1))
prove_mutation "a mixed divisor is narrowed to the left width" "$MATH" 'width = right.bit_width if right.bit_width > width' 'width = left.bit_width if right.bit_width > width' -- check_math_agrees "$REPO/bench/fixtures/semtx_math_division_width.iyi" || status=1
MATH_MUTATIONS=$((MATH_MUTATIONS + 1))
prove_mutation "the unsigned high bit is treated as a sign" "$MATH" '@kind.signed? && @high >= 9223372036854775808_u64' '@high >= 9223372036854775808_u64' -- check_math_agrees "$REPO/bench/fixtures/semtx_math_u128.iyi" || status=1
MATH_MUTATIONS=$((MATH_MUTATIONS + 1))
prove_mutation "the MIN / -1 overflow carries the wrong message" "$MATH" '"Overflow: #{kind_name(kind)}::MIN / -1"' '"Overflow: #{kind_name(kind)}::MIN/-1"' -- check_math_agrees || status=1
echo "  $MATH_MUTATIONS math mutation proofs run"
cat "$WORK/math-mutation-diffs.log"
if [ -e "$WORK/math-mut.invalid" ]; then
  echo "  FAIL: math mutation did not build or execute correctly"
  cat "$WORK/math-mut.invalid"
  status=1
fi

echo
echo "== 5. Literal expansion: range literals, the port's walk against the hosted walk"
# The literal fixtures (semtx_lit_*.iyi) are walked by the port (the driver's
# `literals` mode) and by the hosted walk (the oracle's `literals` mode), and
# the rewritten trees must match. Range literals, string interpolations, array and
# hash literals, and `case` with a subject or none are lowered so far.
# An interpolation made only of literal pieces is kept out of these fixtures:
# the hosted parser folds it into one string (consume_interpolation in
# src/compiler/iyi/syntax/parser.cr), and the port's parser keeps the pieces.
# That is the parser's divergence, not the expander's, so every adjacency case
# here carries a variable piece.
LITERAL="$REPO/src/compiler/semantic/literal_expander.iyi"
# Fixtures named semtx_lit_strict_* are walked with strict_multi_assign set on
# the program, as the hosted program is when that flag is given. Every other
# literal fixture is walked with no flags.
lit_mode() {
  case "$(basename "$1")" in
    semtx_lit_strict_*) echo literals-strict ;;
    *) echo literals ;;
  esac
}
lit_count=0
lit_diverged=0
for fixture in "$REPO"/bench/fixtures/semtx_lit_*.iyi; do
  name="bench/fixtures/$(basename "$fixture")"
  lit_count=$((lit_count + 1))
  "$WORK/port_exercise$EXE" "$(native_path "$fixture")" "$(lit_mode "$(native_path "$fixture")")" > "$WORK/lit_iyi.ast" 2> "$WORK/lit_iyi.err" || {
    echo "  $name: LITERAL PORT FAILED"; cat "$WORK/lit_iyi.err"; lit_diverged=$((lit_diverged + 1)); status=1; continue; }
  IYI_PATH="$REPO_NATIVE/src" "$WORK/dump_hosted$EXE" "$(native_path "$fixture")" "$(lit_mode "$(native_path "$fixture")")" > "$WORK/lit_oracle.ast" 2> "$WORK/lit_oracle.err" || {
    echo "  $name: HOSTED LITERAL WALK FAILED"; cat "$WORK/lit_oracle.err"; lit_diverged=$((lit_diverged + 1)); status=1; continue; }
  if cmp -s "$WORK/lit_iyi.ast" "$WORK/lit_oracle.ast"; then
    echo "  $name: identical (the literal walk lowers the same trees as the hosted walk)"
  else
    echo "  $name: LITERAL TREES DIFFER"
    diff -u "$WORK/lit_oracle.ast" "$WORK/lit_iyi.ast" | head -40
    lit_diverged=$((lit_diverged + 1))
    status=1
  fi
done
echo "  Parity summary: literal $((lit_count - lit_diverged))/$lit_count fixtures lower identically"

# A patch to the port's literal expander that the gate must catch. The copy of
# the port driver made at the start is rebuilt from the patched module and
# walked over every literal fixture; a runnable mutant must produce a difference.
check_literals_agree() {
  "$IYI" build -o "$WORK_NATIVE/lit_mut_port$EXE" "$WORK_NATIVE/semtx_port.iyi" > /dev/null 2>&1 || { echo "INVALID MUTANT: transform driver did not build"; return 0; }
  for fixture in "$REPO"/bench/fixtures/semtx_lit_*.iyi; do
    "$WORK/lit_mut_port$EXE" "$(native_path "$fixture")" "$(lit_mode "$(native_path "$fixture")")" > "$WORK/lit_mut.ast" 2> /dev/null || { echo "INVALID MUTANT: transform driver or oracle failed"; return 0; }
    IYI_PATH="$REPO_NATIVE/src" "$WORK/dump_hosted$EXE" "$(native_path "$fixture")" "$(lit_mode "$(native_path "$fixture")")" > "$WORK/lit_mut_oracle.ast" || { echo "INVALID MUTANT: transform driver or oracle failed"; return 0; }
    cmp -s "$WORK/lit_mut.ast" "$WORK/lit_mut_oracle.ast" || return 1
  done
  return 0
}
LIT_MUTATIONS=0
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a range literal's exclusive flag is inverted" "$LITERAL" 'BoolLiteral.new(node.exclusive)' 'BoolLiteral.new(!node.exclusive)' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a range literal names the wrong global type" "$LITERAL" 'Path.global(["Range"] of String)' 'Path.global(["Ranges"] of String)' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a range nested in a range is not lowered" "$LITERAL" 'call.transform(self)' 'call' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "adjacent string literals are not merged" "$LITERAL" 'if piece.is_a?(StringLiteral) && next_piece.is_a?(StringLiteral)' 'if false' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a merged literal keeps only the next piece's text" "$LITERAL" 'joined = piece.as(StringLiteral).value + next_piece.as(StringLiteral).value' 'joined = next_piece.as(StringLiteral).value' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a merged literal joins its pieces in reverse" "$LITERAL" 'joined = piece.as(StringLiteral).value + next_piece.as(StringLiteral).value' 'joined = next_piece.as(StringLiteral).value + piece.as(StringLiteral).value' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "the last pair of a run is not merged" "$LITERAL" 'if i < n - 1' 'if i < n - 2' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a typed empty array takes the typeof, not its type" "$LITERAL" 'type_var = of' 'type_var = typeof_exp(node.elements, temps)' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "the splat capacity counts the splats" "$LITERAL" 'capacity = count_non_splat(node.elements)' 'capacity = node.elements.size' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "buffer indices start at one" "$LITERAL" 'NumberLiteral.new(i.to_s), value_or_temp' 'NumberLiteral.new((i + 1).to_s), value_or_temp' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "every element is bound to a temporary" "$LITERAL" 'if plain_operand?(elem)' 'if false' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a named splat block variable takes a plain temporary name" "$LITERAL" 'yield_var = temp_var_for(elem)' 'yield_var = temp_var' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "the walk stops at the array expansion" "$LITERAL" 'expanded.transform(self)' 'expanded' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a hash key is bound to the value's temporary" "$LITERAL" 'if t = key_temps[i]' 'if t = value_temps[i]' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a hash stores each value under its key's text" "$LITERAL" 'value_exp = value_or_temp(values[i], value_temps[i])' 'value_exp = value_or_temp(keys[i], value_temps[i])' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "an untyped hash swaps its key and value types" "$LITERAL" '[typeof_key, typeof_value] of ASTNode' '[typeof_value, typeof_key] of ASTNode' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a typed hash swaps its declared key and value" "$LITERAL" '[of.key, of.value] of ASTNode' '[of.value, of.key] of ASTNode' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a when with several conditions keeps only its first" "$LITERAL" 'final = Or.new(final, comps[i])' 'final = Or.new(final, comps[0])' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a variable subject is copied into a temporary" "$LITERAL" 'if value.is_a?(Var) || value.is_a?(InstanceVar)' 'if false' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a type condition is tested with === not is_a?" "$LITERAL" 'if cond.is_a?(Path) || cond.is_a?(Generic)' 'if false' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a type chain drops the else of the when" "$LITERAL" 'cur = tail' 'cur = Nop.new' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a branch's it is not renamed to its temporary" "$LITERAL" 'if node.name == "it"' 'if false' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "the strict count check ignores the flag" "$LITERAL" 'checked = @program.has_flag?("strict_multi_assign") || middle_splat' 'checked = middle_splat' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a target after a splat is indexed from the front" "$LITERAL" 'index = i - count' 'index = i' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a splat with an underscore name is still assigned" "$LITERAL" 'if i == splat_at && splat_underscore' 'if i == splat_at && false' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a call target is assigned without the = suffix" "$LITERAL" 'call.name = call.name + "="' 'nil' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a negative end of a splat range does not count from the end" "$LITERAL" 'last = last + values.size' 'last = last + 0' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "several values are assigned to targets before their temporaries" "$LITERAL" 'to_temps.concat(from_temps)' 'from_temps.concat(to_temps)' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "the select's first bound arm is off by one" "$LITERAL" 'first_bound = i' 'first_bound = i + 1' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a select arm's body runs whether or not its operation happened" "$LITERAL" 'body = If.new(Var.new(happened_name), body)' 'nil' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a select action is named without its suffix" "$LITERAL" 'name + "_select_action"' 'name + "_select"' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a select with an else is not non-blocking" "$LITERAL" 'call_name = "non_blocking_select"' 'call_name = "select"' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "the select without an else raises a different bug" "$LITERAL" 'Call.global("raise", StringLiteral.new("BUG: invalid select index"))' 'Call.global("raise", StringLiteral.new("BUG"))' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "the select ignores the iyi prelude's happened flag" "$LITERAL" 'has_happened = @program.iyi_prelude' 'has_happened = false' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a select's branches bind it as a user case does" "$LITERAL" 'chain = expand_case(a_case, false)' 'chain = expand_case(a_case, true)' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "an and whose left side is an assignment falls back to the left side" "$LITERAL" 'If.new(left, node.right, left.as(Assign).target.clone)' 'If.new(left, node.right, left.clone)' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "an and binds a temporary and runs the right side on false" "$LITERAL" 'If.new(Assign.new(temp.clone, left), node.right, temp.clone)' 'If.new(Assign.new(temp.clone, left), temp.clone, node.right)' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "an or binds a temporary and runs the right side on true" "$LITERAL" 'If.new(Assign.new(temp.clone, left), temp.clone, node.right)' 'If.new(Assign.new(temp.clone, left), node.right, temp.clone)' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "an or is expanded as an and" "$LITERAL" 'expanded = expand_or(node)' 'expanded = expand_and(node)' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "an and is not marked as an and" "$LITERAL" 'a_if.from_and = true' 'a_if.from_and = false' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "an or is not marked as an or" "$LITERAL" 'a_if.from_or = true' 'a_if.from_or = false' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a tuple subject binds no temporaries for the when chain" "$LITERAL" 'tuple_temps = temps' 'tuple_temps = nil' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a tuple condition compares its underscore elements" "$LITERAL" 'if !lh.is_a?(Underscore)' 'if true' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a tuple condition's elements are or-ed" "$LITERAL" 'comp = And.new(prev, sub_comp)' 'comp = Or.new(prev, sub_comp)' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a condition against a tuple subject is tested with the first element" "$LITERAL" 'case_when_comparison(TupleLiteral.new(whole), cond)' 'case_when_comparison(temps[0], cond)' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "a definition's argument defaults are not lowered" "$LITERAL" 'transform_many(node.args)' 'node.args.size' -- check_literals_agree || status=1
LIT_MUTATIONS=$((LIT_MUTATIONS + 1))
prove_mutation "an enum's members are not lowered" "$LITERAL" 'transform_many(node.members)' 'node.members.size' -- check_literals_agree || status=1
echo "  $LIT_MUTATIONS literal mutation proofs run"

echo
echo "== 5b. Cleanup: the untyped part of the hosted cleanup transform"
# The cleanup fixtures (semtx_cleanup_*.iyi) are cleaned by the port (the driver's
# `cleanup` mode) and by the hosted cleanup transform (the oracle's `cleanup`
# mode), over the normalized tree; the two trees must match. The fixtures are
# literal-condition programs: no call, case, assignment or def, since the hosted
# transform refuses a call with no type and reads types for the rest.
CLEANUP="$REPO/src/compiler/semantic/cleanup.iyi"
cleanup_count=0
cleanup_diverged=0
for fixture in "$REPO"/bench/fixtures/semtx_cleanup_*.iyi; do
  name="bench/fixtures/$(basename "$fixture")"
  cleanup_count=$((cleanup_count + 1))
  "$WORK/port_exercise$EXE" "$(native_path "$fixture")" cleanup > "$WORK/cln_iyi.ast" 2> "$WORK/cln_iyi.err" || {
    echo "  $name: CLEANUP PORT FAILED"; cat "$WORK/cln_iyi.err"; cleanup_diverged=$((cleanup_diverged + 1)); status=1; continue; }
  IYI_PATH="$REPO_NATIVE/src" "$WORK/dump_hosted$EXE" "$(native_path "$fixture")" cleanup > "$WORK/cln_oracle.ast" 2> "$WORK/cln_oracle.err" || {
    echo "  $name: HOSTED CLEANUP FAILED"; cat "$WORK/cln_oracle.err"; cleanup_diverged=$((cleanup_diverged + 1)); status=1; continue; }
  if cmp -s "$WORK/cln_iyi.ast" "$WORK/cln_oracle.ast"; then
    echo "  $name: identical (the cleanup yields the same tree as the hosted transform)"
  else
    echo "  $name: CLEANUP TREES DIFFER"
    diff -u "$WORK/cln_oracle.ast" "$WORK/cln_iyi.ast" | head -40
    cleanup_diverged=$((cleanup_diverged + 1))
    status=1
  fi
done
echo "  Parity summary: cleanup $((cleanup_count - cleanup_diverged))/$cleanup_count fixtures clean identically"

# A patch to the port's cleanup that the gate must catch: the patched module is
# rebuilt into the port driver and walked over every cleanup fixture.
check_cleanup_agree() {
  "$IYI" build -o "$WORK_NATIVE/cln_mut_port$EXE" "$WORK_NATIVE/semtx_port.iyi" > /dev/null 2>&1 || { echo "INVALID MUTANT: transform driver did not build"; return 0; }
  for fixture in "$REPO"/bench/fixtures/semtx_cleanup_*.iyi; do
    "$WORK/cln_mut_port$EXE" "$(native_path "$fixture")" cleanup > "$WORK/cln_mut.ast" 2> /dev/null || { echo "INVALID MUTANT: transform driver or oracle failed"; return 0; }
    IYI_PATH="$REPO_NATIVE/src" "$WORK/dump_hosted$EXE" "$(native_path "$fixture")" cleanup > "$WORK/cln_mut_oracle.ast" || { echo "INVALID MUTANT: transform driver or oracle failed"; return 0; }
    cmp -s "$WORK/cln_mut.ast" "$WORK/cln_mut_oracle.ast" || return 1
  done
  return 0
}
CLN_MUTATIONS=0
CLN_MUTATIONS=$((CLN_MUTATIONS + 1))
prove_mutation "a true condition is not marked truthy" "$CLEANUP" 'if truth == 1' 'if truth == 9' -- check_cleanup_agree || status=1
CLN_MUTATIONS=$((CLN_MUTATIONS + 1))
prove_mutation "a false condition is not marked falsey" "$CLEANUP" 'elsif truth == -1' 'elsif truth == 9' -- check_cleanup_agree || status=1
CLN_MUTATIONS=$((CLN_MUTATIONS + 1))
prove_mutation "a dead branch is walked anyway" "$CLEANUP" 'if !node.falsey' 'if true' -- check_cleanup_agree || status=1
CLN_MUTATIONS=$((CLN_MUTATIONS + 1))
prove_mutation "a nil condition is not falsey" "$CLEANUP" 'if node.is_a?(NilLiteral) || node.is_a?(Nop)' 'if node.is_a?(Nop)' -- check_cleanup_agree || status=1
echo "  $CLN_MUTATIONS cleanup mutation proofs run"

echo
echo "== 6. Corpus: the transforms over the port's own source and prelude"
# Every .iyi file of the port's compiler and of the prelude is walked by the
# port and by the hosted walk, in the literal mode of section 5, and the two
# trees are compared. A file either side refuses is counted apart. The floor
# counts the identical files and may only rise: TRANSFORM_CORPUS_RAISE=1 writes
# the measured count to the floor file, and a count below the floor fails.
CORPUS_FLOOR="$REPO/bench/selfhost_semantic_transform_corpus.floor"
corpus_files=$({ find "$REPO/src/compiler" -name '*.iyi'; find "$REPO/src/iyi" -maxdepth 1 -name '*.iyi'; } | sort)
corpus_count=0
corpus_identical=0
corpus_refused=0
: > "$WORK/corpus_kinds.txt"
: > "$WORK/corpus_uncovered.txt"
for file in $corpus_files; do
  rel="${file#$REPO/}"
  corpus_count=$((corpus_count + 1))
  if ! "$WORK/port_exercise$EXE" "$(native_path "$file")" literals > "$WORK/corpus_port.ast" 2> "$WORK/corpus_port.err"; then
    corpus_refused=$((corpus_refused + 1))
    echo "  $rel: refused by the port: $(awk 'NR==1' "$WORK/corpus_port.err")"
    continue
  fi
  if ! IYI_PATH="$REPO_NATIVE/src" "$WORK/dump_hosted$EXE" "$(native_path "$file")" literals > "$WORK/corpus_oracle.ast" 2> "$WORK/corpus_oracle.err"; then
    corpus_refused=$((corpus_refused + 1))
    echo "  $rel: refused by the hosted walk: $(awk 'NR==1' "$WORK/corpus_oracle.err")"
    continue
  fi
  awk '/^UNCOVERED /' "$WORK/corpus_oracle.err" >> "$WORK/corpus_uncovered.txt"
  "$WORK/port_exercise$EXE" "$(native_path "$file")" kinds >> "$WORK/corpus_kinds.txt" 2> /dev/null
  if cmp -s "$WORK/corpus_port.ast" "$WORK/corpus_oracle.ast"; then
    corpus_identical=$((corpus_identical + 1))
  else
    echo "  $rel: first difference"
    diff -u "$WORK/corpus_oracle.ast" "$WORK/corpus_port.ast" | awk '/^@@/{n++} n==1' | awk 'NR<=10'
  fi
done
echo "  Corpus: $corpus_identical/$corpus_count files transform identically ($corpus_refused refused by one side)"
echo "  Constructs in that source, counted by the port's parser before any transform:"
awk '{t[$1]+=$2} END{for (k in t) printf "    %-22s %d\n", k, t[k]}' "$WORK/corpus_kinds.txt" | sort
echo "  Nodes the shared dump prints as Node (kind, count; their children are not compared):"
awk '{t[$2]+=1} END{for (k in t) printf "    %-22s %d\n", k, t[k]}' "$WORK/corpus_uncovered.txt" | sort -k2 -nr
corpus_floor=0
if [ -f "$CORPUS_FLOOR" ]; then
  corpus_floor=$(awk 'NR==1{print $1}' "$CORPUS_FLOOR")
fi
if [ "$corpus_identical" -lt "$corpus_floor" ]; then
  echo "  CORPUS FLOOR DROPPED: $corpus_identical < $corpus_floor"
  status=1
elif [ "${TRANSFORM_CORPUS_RAISE:-0}" = "1" ]; then
  printf '%s\n' "$corpus_identical" > "$CORPUS_FLOOR"
  echo "  Floor raised: $corpus_floor -> $corpus_identical"
else
  echo "  Floor: $corpus_identical >= $corpus_floor"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SELFHOST SEMANTIC TRANSFORM CHECKS PASSED SUCCESSFULLY!"
else
  echo "SELFHOST SEMANTIC TRANSFORM CHECKS FAILED"
fi
exit $status
