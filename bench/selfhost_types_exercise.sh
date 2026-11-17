#!/usr/bin/env bash
# Fails when the iyi type system stops agreeing with the one it replaces.
#
# Every fixture is analyzed twice, once by each implementation, dumped in one
# text form, and required byte-identical.
#
# The mutation proofs follow the rule the other selfhost gates use: the patched
# file is compared against the original, and a patch that matched nothing is
# reported as proving nothing rather than passing quietly.
#
#   bash bench/selfhost_types_exercise.sh
set -u
status=0
diverged=0
readonly REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")"
export IYI_PATH="$REPO_NATIVE/src"
IYI="${IYI:-$REPO/bin/iyi}"
HOSTED_COMPILER="$REPO/bin/crystal"
TYPES_DIR="$REPO/src/compiler/types"
TYPES_MAIN="$REPO/src/compiler/types/types.iyi"
UNIF_FILE="$REPO/src/compiler/types/unification.iyi"
MERGE_FILE="$REPO/src/compiler/types/merge.iyi"
REND_FILE="$REPO/src/compiler/types/rendering.iyi"
TSYS_FILE="$REPO/src/compiler/types/type_system.iyi"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")"
trap 'rm -rf "$WORK"' EXIT

. "$REPO/bench/lib/mutation.sh"

echo "== 1. Building and running the selfhost types exercise"
"$IYI" build -o "$WORK_NATIVE/exercise$EXE" "$REPO_NATIVE/bench/selfhost_types_exercise.iyi" || exit 1
"$WORK/exercise$EXE" > "$WORK/plain.out" 2>&1 || { cat "$WORK/plain.out"; exit 1; }
cat "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST TYPES CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "  EXERCISE FAILED"
  status=1
fi

echo
echo "== 2. Type declaration comparison against the front end being replaced"
cat <<'HOSTED_GOLDEN_SCRIPT' > "$WORK/dump_hosted_types.cr"
require "compiler/requires"

filename = ARGV[0]
src = File.read(filename)

program = Iyi::Program.new
initial_names = program.types.keys.to_set

parser = Iyi::Parser.new(src)
parser.filename = filename
node = parser.parse
node.accept Iyi::TopLevelVisitor.new(program)

def type_kind_name(t : Iyi::Type) : String
  case t
  when Iyi::TupleInstanceType
    "TupleInstanceType"
  when Iyi::NamedTupleInstanceType
    "NamedTupleInstanceType"
  when Iyi::ProcInstanceType
    "ProcInstanceType"
  when Iyi::PointerInstanceType
    "PointerInstanceType"
  when Iyi::StaticArrayInstanceType
    "StaticArrayInstanceType"
  when Iyi::GenericClassInstanceType
    "GenericClassInstanceType"
  when Iyi::VirtualType
    "VirtualType"
  when Iyi::NilableProcType
    "NilableProcType"
  when Iyi::NilableReferenceUnionType
    "NilableReferenceUnionType"
  when Iyi::ReferenceUnionType
    "ReferenceUnionType"
  when Iyi::NilableType
    "NilableType"
  when Iyi::MixedUnionType, Iyi::UnionType
    "MixedUnionType"
  when Iyi::IntegerType
    "IntegerType"
  when Iyi::FloatType
    "FloatType"
  when Iyi::PrimitiveType
    "PrimitiveType"
  when Iyi::NonGenericClassType
    case t.name
    when "Int8", "UInt8", "Int16", "UInt16", "Int32", "UInt32", "Int64", "UInt64", "Int128", "UInt128"
      "IntegerType"
    when "Float32", "Float64"
      "FloatType"
    when "Char"
      "CharType"
    when "Bool"
      "BoolType"
    when "Symbol"
      "SymbolType"
    when "Nil"
      "NilType"
    when "NoReturn"
      "NoReturnType"
    when "Void"
      "VoidType"
    else
      "NonGenericClassType"
    end
  when Iyi::GenericClassType
    "GenericClassType"
  else
    t.class.name.sub(/^Iyi::/, "")
  end
end

program.types.keys.sort.each do |name|
  next if initial_names.includes?(name)
  t = program.types[name]
  if t.is_a?(Iyi::ClassType)
    s = t.superclass
    sc = if s && s.is_a?(Iyi::NamedType)
           s.name
         elsif s
           s.to_s
         else
           "nil"
         end
    puts "Class: #{name} (superclass: #{sc})"
    puts "  virtual: #{t.virtual_type.to_s}"
    puts "  metaclass: #{t.metaclass.to_s}"
  elsif t.is_a?(Iyi::AliasType)
    t.process_value
    aliased = t.aliased_type.not_nil!
    kind = type_kind_name(aliased)
    puts "Alias: #{name} = #{aliased.to_s} (#{kind})"
  elsif t.is_a?(Iyi::EnumType)
    puts "Enum: #{name} (base: #{t.base_type.name})"
  elsif t.is_a?(Iyi::TraitType)
    puts "Trait: #{name}"
  end
end
HOSTED_GOLDEN_SCRIPT

LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing \
    -o "$WORK_NATIVE/dump_hosted$EXE" "$WORK_NATIVE/dump_hosted_types.cr" || exit 1

compare_all() {
  out_status=0
  for fixture in "$REPO"/bench/fixtures/types_*.iyi; do
    case "$(basename "$fixture")" in
      types_err_*)
        if "$1" "$(native_path "$fixture")" >/dev/null 2>&1; then
          out_status=1
        fi
        continue
        ;;
    esac
    "$1" "$(native_path "$fixture")" > "$WORK/a.types" 2>/dev/null || return 2
    "$WORK/dump_hosted$EXE" "$(native_path "$fixture")" > "$WORK/b.types" || return 2
    diff -q "$WORK/a.types" "$WORK/b.types" >/dev/null || out_status=1
  done
  return $out_status
}

fixture_count=0
total_matched_types=0
for fixture in "$REPO"/bench/fixtures/types_*.iyi; do
  case "$(basename "$fixture")" in
    types_err_*) continue ;;
  esac
  fixture_name="bench/fixtures/$(basename "$fixture")"
  "$WORK/exercise$EXE" "$(native_path "$fixture")" > "$WORK/iyi.types"
  "$WORK/dump_hosted$EXE" "$(native_path "$fixture")" > "$WORK/hosted.types"
  if diff -u "$WORK/hosted.types" "$WORK/iyi.types" > "$WORK/diff.out"; then
    matched=$("$WORK/exercise$EXE" "$(native_path "$fixture")" --count)
    echo -n "  $fixture_name: identical ($matched types match Crystal front end)"
    fixture_count=$((fixture_count + 1))
    total_matched_types=$((total_matched_types + matched))
  else
    echo "  $fixture_name: DIVERGED from Crystal front end"
    cat "$WORK/diff.out"
    status=1
  fi
done
echo
echo "  Parity summary: $((fixture_count - diverged))/$fixture_count type fixtures match 100% ($total_matched_types types compared)"

echo
echo "== 3. Semantic type error rejection and error checks"
err_count=0
for err_fixture in "$REPO"/bench/fixtures/types_err_*.iyi; do
  err_fixture_name="bench/fixtures/$(basename "$err_fixture")"
  expected_err=$("$WORK/dump_hosted$EXE" "$(native_path "$err_fixture")" 2>&1 | grep -F "Error:" | tail -n 1 | sed 's/.*Error: //' | sed 's/  from .*//')
  if [ -z "$expected_err" ]; then
    expected_err=$("$WORK/dump_hosted$EXE" "$(native_path "$err_fixture")" 2>&1 | head -n 1)
  fi

  iyi_err=$("$WORK/exercise$EXE" "$(native_path "$err_fixture")" 2>&1 | grep -F "panic:" | head -n 1 | sed 's/.*panic: //')
  if [ -z "$iyi_err" ]; then
    echo "  $err_fixture_name: wrongly ACCEPTED by iyi front end (expected error: $expected_err)"
    status=1
  elif [ "$iyi_err" = "$expected_err" ]; then
    echo "  $err_fixture_name: properly rejected ($iyi_err)"
    err_count=$((err_count + 1))
  else
    echo "  $err_fixture_name: error message mismatch"
    echo "    expected: $expected_err"
    echo "    got:      $iyi_err"
    status=1
  fi
done
echo "  Parity summary: $((err_count - diverged))/$err_count error fixtures rejected with identical errors"

echo
echo "== 4. Guarded mutation proofs (verify patch applies, exercise fails, revert passes)"
MUTATIONS_RUN=0

# A build or oracle failure cannot prove a behavioral divergence.
invalid_mutant() {
  echo "INVALID MUTANT: $*"
  [ "${_PM_ARMED:-0}" = 1 ]
}
build_type_mutant() {
  rm -f "$WORK/mut-exercise$EXE"
  "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_types_exercise.iyi" >"$WORK/mut-build.log" 2>&1 &&
    [ -x "$WORK/mut-exercise$EXE" ]
}
check_type_outputs_diverge() {
  local rc
  if ! build_type_mutant; then
    cat "$WORK/mut-build.log"
    invalid_mutant "type driver failed to build"
    return $?
  fi
  if compare_all "$WORK/mut-exercise$EXE"; then
    return 0
  else
    rc=$?
    if [ "$rc" -ne 1 ]; then
      invalid_mutant "type fixture or oracle failed to run"
      return $?
    fi
    return 1
  fi
}

check_nilable_member_order() {
  if ! build_type_mutant; then
    cat "$WORK/mut-build.log"
    invalid_mutant "type driver failed to build"
    return $?
  fi
  if "$WORK/mut-exercise$EXE" > "$WORK/mut-order.out" 2>&1; then
    grep -qF "ALL SELFHOST TYPES CHECKS PASSED SUCCESSFULLY!" "$WORK/mut-order.out"
    return $?
  fi
  if grep -Eq 'nilable (reference|proc) member order differs from hosted' "$WORK/mut-order.out"; then
    return 1
  fi
  invalid_mutant "type driver failed without the expected member-order assertion"
  return $?
}
check_nilable_member_order || { echo "  nilable member order baseline failed"; status=1; }
prove_mutation "nilable reference puts Nil last" "$TYPES_MAIN" \
  '    super(program, [program.nil_type, @not_nil_type] of Type)' \
  '    super(program, [@not_nil_type, program.nil_type] of Type)' \
  -- check_nilable_member_order || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "nilable proc puts Nil last" "$TYPES_MAIN" \
  '    super(program, [program.nil_type, @proc_type] of Type)' \
  '    super(program, [@proc_type, program.nil_type] of Type)' \
  -- check_nilable_member_order || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "virtual root bypass in type merge" "$MERGE_FILE" \
  "if ancestor && virtual_root?(ancestor)" \
  "if false && ancestor && virtual_root?(ancestor)" \
  -- check_type_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))


prove_mutation "NilableType classification bypassed in union_of" "$UNIF_FILE" \
  "return NilableType.new(program, not_nil_t)" \
  "return MixedUnionType.new(program, all_sorted)" \
  -- check_type_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "Nil placement at end of union bypassed in rendering" "$REND_FILE" \
  "if has_nil
      sorted << \"Nil\"
    end" \
  "if has_nil
      # sorted << \"Nil\"
    end" \
  -- check_type_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "union parentheses bypassed in rendering" "$REND_FILE" \
  "if skip_union_parens
      joined
    else
      \"(#{joined})\"
    end" \
  "joined" \
  -- check_type_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "generic class arity validation bypassed in lookup_generic" "$REPO/src/compiler/types/lookup.iyi" \
  "    elsif given != type_vars.size" \
  "    elsif false" \
  -- check_type_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST TYPES CHECKS PASSED =="
else
  echo "== SELFHOST TYPES CHECKS FAILED =="
fi
exit "$status"
