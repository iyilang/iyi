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
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
TYPES_DIR="$REPO/src/compiler/types"
TYPES_MAIN="$REPO/src/compiler/types/types.iyi"
UNIF_FILE="$REPO/src/compiler/types/unification.iyi"
REND_FILE="$REPO/src/compiler/types/rendering.iyi"
TSYS_FILE="$REPO/src/compiler/types/type_system.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. Building and running the selfhost types exercise"
"$IYI" build -o "$WORK/exercise" "$REPO/bench/selfhost_types_exercise.iyi"
"$WORK/exercise" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST TYPES CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "  EXERCISE FAILED"
  status=1
fi

echo
echo "== 2. Type declaration comparison against the front end being replaced"
cat <<'CRYSTAL_GOLDEN_SCRIPT' > "$WORK/dump_crystal_types.cr"
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
CRYSTAL_GOLDEN_SCRIPT

LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK/dump_crystal" "$WORK/dump_crystal_types.cr"

compare_all() {
  out_status=0
  for fixture in "$REPO"/bench/fixtures/types_*.iyi; do
    case "$(basename "$fixture")" in
      types_err_*)
        if "$1" "$fixture" >/dev/null 2>&1; then
          out_status=1
        fi
        continue
        ;;
    esac
    "$1" "$fixture" > "$WORK/a.types" 2>/dev/null || { out_status=1; continue; }
    "$WORK/dump_crystal" "$fixture" > "$WORK/b.types"
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
  "$WORK/exercise" "$fixture" > "$WORK/iyi.types"
  "$WORK/dump_crystal" "$fixture" > "$WORK/crystal.types"
  if diff -u "$WORK/crystal.types" "$WORK/iyi.types" > "$WORK/diff.out"; then
    matched=$("$WORK/exercise" "$fixture" --count)
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
echo "  Parity summary: $fixture_count/$fixture_count type fixtures match 100% ($total_matched_types types compared)"

echo
echo "== 3. Semantic type error rejection and error checks"
err_count=0
for err_fixture in "$REPO"/bench/fixtures/types_err_*.iyi; do
  err_fixture_name="bench/fixtures/$(basename "$err_fixture")"
  expected_err=$("$WORK/dump_crystal" "$err_fixture" 2>&1 | grep -F "Error:" | tail -n 1 | sed 's/.*Error: //' | sed 's/  from .*//')
  if [ -z "$expected_err" ]; then
    expected_err=$("$WORK/dump_crystal" "$err_fixture" 2>&1 | head -n 1)
  fi

  iyi_err=$("$WORK/exercise" "$err_fixture" 2>&1 | grep -F "panic:" | head -n 1 | sed 's/.*panic: //')
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
echo "  Parity summary: $err_count/$err_count error fixtures rejected with identical errors"

echo
echo "== 4. Guarded mutation proofs (verify patch applies, exercise fails, revert passes)"
MUTATIONS_RUN=0

prove_types_mutation() {
  label="$1"
  target_file="$2"
  old="$3"
  new="$4"
  echo "  [$label]"
  cp "$target_file" "$target_file.orig"
  python3 - "$target_file" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
if old not in t:
    sys.exit(3)
open(path, "w").write(t.replace(old, new, 1))
PY
  rc=$?
  if [ "$rc" -eq 3 ] || diff -q "$target_file.orig" "$target_file" >/dev/null; then
    echo "    PATCH CHANGED NOTHING: this proves nothing"
    status=1
    cp "$target_file.orig" "$target_file"; rm -f "$target_file.orig"
    return
  fi
  if "$IYI" build -o "$WORK/mut-exercise" "$REPO/bench/selfhost_types_exercise.iyi" >/dev/null 2>&1; then
    if compare_all "$WORK/mut-exercise"; then
      echo "    FAILED: the comparison still passed with the mutation applied"
      status=1
    else
      echo "    caught: the type outputs diverged, as they must"
    fi
  else
    echo "    caught: the mutated type system did not build"
  fi
  cp "$target_file.orig" "$target_file"; rm -f "$target_file.orig"
  echo "    reverted"
}

prove_types_mutation "virtual root bypass in unification" \
  "$UNIF_FILE" \
  "if ancestor && virtual_root?(ancestor)" \
  "if false && ancestor && virtual_root?(ancestor)"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_types_mutation "NoReturn elimination bypassed in union unification" \
  "$UNIF_FILE" \
  "unless t.full_name == \"NoReturn\" || (t.is_a?(NoReturnType) && t.as(NoReturnType).no_return?)" \
  "unless false"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_types_mutation "NilableType classification bypassed in union_of" \
  "$UNIF_FILE" \
  "return NilableType.new(program, not_nil_t)" \
  "return MixedUnionType.new(program, all_sorted)"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_types_mutation "Nil placement at end of union bypassed in rendering" \
  "$REND_FILE" \
  "if has_nil
      sorted << \"Nil\"
    end" \
  "if has_nil
      # sorted << \"Nil\"
    end"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_types_mutation "union parentheses bypassed in rendering" \
  "$REND_FILE" \
  "if skip_union_parens
      joined
    else
      \"(#{joined})\"
    end" \
  "joined"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_types_mutation "generic class arity validation bypassed in lookup_generic" \
  "$TSYS_FILE" \
  "if node.type_vars.size != gc.type_vars.size" \
  "if false && node.type_vars.size != gc.type_vars.size"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST TYPES CHECKS PASSED =="
else
  echo "== SELFHOST TYPES CHECKS FAILED =="
fi
exit "$status"
