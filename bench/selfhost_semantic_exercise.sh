#!/usr/bin/env bash
# Fails when the iyi semantic declaration or expression pass stops agreeing
# with the one it replaces.
#
# Every fixture is analyzed twice, once by each implementation, dumped in one
# text form, and required byte-identical.
#
# The mutation proofs follow the rule the other selfhost gates use: the patched
# file is compared against the original, and a patch that matched nothing is
# reported as proving nothing rather than passing quietly.
#
#   bash bench/selfhost_semantic_exercise.sh
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
SEM="$REPO/src/compiler/semantic/top_level.iyi"
SEM_MAIN="$REPO/src/compiler/semantic/main_visitor.iyi"
SEM_REC="$REPO/src/compiler/semantic/recursive_struct_checker.iyi"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")"
trap 'rm -rf "$WORK"' EXIT

. "$REPO/bench/lib/mutation.sh"

echo "== 1. Building and running the semantic visitor exercise"
"$IYI" build -o "$WORK_NATIVE/exercise$EXE" "$REPO_NATIVE/bench/selfhost_semantic_exercise.iyi" || exit 1
"$WORK/exercise$EXE" > "$WORK/plain.out" 2>&1 || { cat "$WORK/plain.out"; exit 1; }
cat "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST SEMANTIC CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "  EXERCISE FAILED"
  status=1
fi

echo
echo "== 2. Semantic declaration comparison against the front end being replaced"
cat <<'HOSTED_GOLDEN_SCRIPT' > "$WORK/dump_hosted_sem.cr"
require "compiler/requires"

filename = ARGV[0]
src = File.read(filename)

def dump_def(d : Iyi::Def, io : IO, indent : String)
  io << indent << "Def: " << (d.receiver ? "self." : "") << d.name << "\n"
  vis_str = case d.visibility
            when .private? then "private"
            else                "public"
            end
  io << indent << "  visibility: " << vis_str << "\n"
  io << indent << "  abstract: " << d.abstract? << "\n"
  args_strs = d.args.map do |arg|
    s = arg.name
    s += " : #{arg.restriction}" if arg.restriction
    s += " = #{arg.default_value}" if arg.default_value
    s
  end
  io << indent << "  args: [" << args_strs.join(", ") << "]\n"
  ret_str = d.return_type ? d.return_type.to_s : "nil"
  ret_str = ret_str.sub(/^::/, "")
  io << indent << "  return_type: " << ret_str << "\n"
end

def dump_type(t : Iyi::Type, io : IO, indent : String)
  full_name = t.is_a?(Iyi::NamedType) ? t.full_name : t.to_s
  kind = case t
         when Iyi::EnumType then "enum"
         when Iyi::TraitType then "trait"
         when Iyi::ClassType then t.struct? ? "struct" : "class"
         when Iyi::ModuleType then "module"
         when Iyi::AliasType then "alias"
         when Iyi::Const then "constant"
         else "type"
         end
  io << indent << "Type: " << full_name << " (" << kind << ")\n"
  vis_str = (t.is_a?(Iyi::NamedType) && t.private?) ? "private" : "public"
  io << indent << "  visibility: " << vis_str << "\n"
  io << indent << "  abstract: " << t.abstract? << "\n"

  if t.is_a?(Iyi::GenericType)
    io << indent << "  type_vars: [" << t.type_vars.join(", ") << "]\n"
  end

  if t.is_a?(Iyi::ClassType) && (sc = t.superclass)
    io << indent << "  superclass: " << sc.to_s << "\n"
  end

  if t.is_a?(Iyi::ModuleType) && !t.parents.empty?
    io << indent << "  parents: [" << t.parents.map(&.to_s).sort.join(", ") << "]\n"
  end

  if t.is_a?(Iyi::TraitType)
    if t.is_a?(Iyi::TraitSupertraits) && (st = t.supertraits) && !st.empty?
      io << indent << "  supertraits: [" << st.map(&.to_s).sort.join(", ") << "]\n"
    end
    if t.is_a?(Iyi::GenericTraitType) && !t.assoc_types.empty?
      io << indent << "  assoc_types: [" << t.assoc_types.sort.join(", ") << "]\n"
    end
  end

  if t.is_a?(Iyi::EnumType)
    members = t.types.map do |k, v|
      val_s = v.as(Iyi::Const).value.to_s
      val_s = val_s.split('_').first if val_s.includes?('_')
      "#{k}=#{val_s}"
    end.sort
    io << indent << "  enum_members: [" << members.join(", ") << "]\n"
  end

  if t.is_a?(Iyi::AliasType)
    t.process_value
    io << indent << "  aliased_type: " << t.aliased_type.to_s << "\n"
  end

  if t.is_a?(Iyi::Const)
    io << indent << "  const_value: " << t.value.to_s << "\n"
  end

  if t.is_a?(Iyi::ModuleType)
    all_defs = [] of Iyi::Def
    t.defs.try &.each_value { |list| list.each { |item| all_defs << item.def } }
    if (meta = t.metaclass) && meta.is_a?(Iyi::ModuleType)
      meta.defs.try &.each_value do |list|
        list.each do |item|
          next if item.def.name == "allocate"
          next if item.def.name == "new" && t.is_a?(Iyi::EnumType)
          all_defs << item.def
        end
      end
    end
    all_defs.sort_by! { |d| "#{d.receiver ? "self." : ""}#{d.name}" }
    all_defs.each do |d|
      dump_def(d, io, "#{indent}  ")
    end
  end

  if t.is_a?(Iyi::NamedType) && !t.is_a?(Iyi::EnumType)
    t.types.keys.sort.each do |subname|
      sub = t.types[subname]
      dump_type(sub, io, "#{indent}  ")
    end
  end
end

def dump_typed_node(node : Iyi::ASTNode, io : IO, indent : String = "")
  type_str = node.type?.try { |t| t.is_a?(Iyi::NamedType) ? t.full_name : t.to_s } || "nil"
  type_str = type_str.sub(/^::/, "")
  node_name = node.class.name.sub(/^Iyi::/, "")
  io << indent << node_name << ": " << type_str << "\n"

  case node
  when Iyi::Expressions
    node.expressions.each { |e| dump_typed_node(e, io, indent + "  ") }
  when Iyi::Assign
    io << indent << "  target:\n"
    dump_typed_node(node.target, io, indent + "    ")
    io << indent << "  value:\n"
    dump_typed_node(node.value, io, indent + "    ")
  when Iyi::Var, Iyi::InstanceVar, Iyi::ClassVar
    io << indent << "  name: " << node.name << "\n"
  when Iyi::Path
    io << indent << "  names: [" << node.names.join("::") << "]\n"
  when Iyi::NumberLiteral
    io << indent << "  value: " << node.to_s << "\n"
  when Iyi::StringLiteral, Iyi::BoolLiteral, Iyi::CharLiteral, Iyi::SymbolLiteral, Iyi::NilLiteral
    io << indent << "  value: " << node.to_s << "\n"
  when Iyi::If
    io << indent << "  cond:\n"
    dump_typed_node(node.cond, io, indent + "    ")
    io << indent << "  then:\n"
    dump_typed_node(node.then, io, indent + "    ")
    if els = node.else
      io << indent << "  else:\n"
      dump_typed_node(els, io, indent + "    ")
    end
  when Iyi::While
    io << indent << "  cond:\n"
    dump_typed_node(node.cond, io, indent + "    ")
    io << indent << "  body:\n"
    dump_typed_node(node.body, io, indent + "    ")
  when Iyi::Yield
    unless node.exps.empty?
      io << indent << "  yield_exps:\n"
      node.exps.each { |e| dump_typed_node(e, io, indent + "    ") }
    end
  when Iyi::Return
    if exp = node.exp
      io << indent << "  exp:\n"
      dump_typed_node(exp, io, indent + "    ")
    end
  when Iyi::Call
    io << indent << "  name: " << node.name << "\n"
    if obj = node.obj
      io << indent << "  obj:\n"
      dump_typed_node(obj, io, indent + "    ")
    end
    unless node.args.empty?
      io << indent << "  args:\n"
      node.args.each { |a| dump_typed_node(a, io, indent + "    ") }
    end
    if block = node.block
      io << indent << "  block:\n"
      dump_typed_node(block, io, indent + "    ")
    end
    if (defs = node.target_defs) && (td = defs.first?) && td.name != "new"
      io << indent << "  target_def: " << td.name << ": " << (td.type?.try(&.to_s) || "nil") << "\n"
      if body = td.body
        io << indent << "  target_body:\n"
        dump_typed_node(body, io, indent + "    ")
      end
    end
  when Iyi::Block
    unless node.args.empty?
      io << indent << "  block_args: [" << node.args.map { |a| "#{a.name}: #{a.type?}" }.join(", ") << "]\n"
    end
    io << indent << "  body:\n"
    dump_typed_node(node.body, io, indent + "    ")
  when Iyi::Def
    io << indent << "  name: " << node.name << "\n"
  when Iyi::ClassDef
    io << indent << "  name: " << node.name.to_s << "\n"
  end
end

begin
  parser = Iyi::Parser.new(src)
  parser.filename = filename
  node = parser.parse

  if ARGV.size > 1 && ARGV[1] == "--expr"
    program = Iyi::Program.new
    node = program.normalize(node)
    node = program.semantic(node)
    dump_typed_node(node, STDOUT)
    exit 0
  end

  program = Iyi::Program.new
  program.filename = filename
  initial_types = program.types.keys.to_set
  visitor = Iyi::TopLevelVisitor.new(program)
  node.accept(visitor)

  if pdefs = program.defs
    top_defs = [] of Iyi::Def
    pdefs.each_value { |list| list.each { |item| top_defs << item.def } }
    top_defs.sort_by!(&.name)
    top_defs.each do |d|
      dump_def(d, STDOUT, "")
    end
  end

  user_types = program.types.reject { |k, _| initial_types.includes?(k) }
  user_types.keys.sort.each do |name|
    t = user_types[name]
    dump_type(t, STDOUT, "")
  end
rescue ex : Iyi::TypeException
  first_line = ex.message.to_s.lines.first? || ""
  puts "ERROR: #{first_line}"
rescue ex : Exception
  first_line = ex.message.to_s.lines.first? || ""
  puts "ERROR: #{first_line}"
end
HOSTED_GOLDEN_SCRIPT

LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing \
    -o "$WORK_NATIVE/dump_hosted$EXE" "$WORK_NATIVE/dump_hosted_sem.cr" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing \
  -o "$WORK_NATIVE/declarations_oracle$EXE" "$REPO_NATIVE/bench/selfhost_semantic_declarations_oracle.cr" || exit 1
"$IYI" build -o "$WORK_NATIVE/declarations_port$EXE" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" || exit 1


compare_all() {
  out_status=0
  for fixture in "$REPO"/bench/fixtures/sem_*.iyi; do
    case "$(basename "$fixture")" in
      sem_expr_*)
        continue
        ;;
      sem_err_wrong_arg_count*|sem_err_type_mismatch*|sem_err_undefined_method*|sem_err_cvar_*|sem_err_recursive_*|sem_err_ivar_*|sem_err_top_level_*|sem_err_ambiguous_call*|sem_err_no_overload_matches*|sem_err_class_nil*|sem_err_class_symbol*)
        continue
        ;;
      sem_err_*)
        if "$2" "$(native_path "$fixture")" >/dev/null 2>&1; then
          out_status=1
        fi
        continue
        ;;
    esac
    "$1" "$(native_path "$fixture")" > "$WORK/a.ast" 2>/dev/null || return 2
    "$WORK/declarations_oracle$EXE" "$(native_path "$fixture")" > "$WORK/b.ast" 2>/dev/null || return 2
    diff -q "$WORK/a.ast" "$WORK/b.ast" >/dev/null || out_status=1
  done
  return $out_status
}

# Return the first behavioral divergence (1). A failed oracle or a mutant
# that only crashes is invalid (2); a matching mutant returns 0.
compare_expr_all() {
  local fixture err_fixture name rc died=""
  for fixture in "$REPO"/bench/fixtures/sem_expr_*.iyi; do
    name="$(basename "$fixture")"
    if ! "$WORK/dump_hosted$EXE" "$(native_path "$fixture")" --expr > "$WORK/b_expr.ast" 2> "$WORK/b_expr.err"; then
      echo "hosted dump failed on $name: $(awk 'NR == 1 { print; exit }' "$WORK/b_expr.err")"
      return 2
    fi
    "$1" "$(native_path "$fixture")" --expr > "$WORK/a_expr.ast" 2> "$WORK/a_expr.err"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      cmp -s "$WORK/a_expr.ast" "$WORK/b_expr.ast" && continue
      echo "decisive: $name: the typed trees differ from the hosted dump"
      return 1
    fi
    if port_refusal "$rc" "$WORK/a_expr.err" &&
       "$WORK/exercise$EXE" "$(native_path "$fixture")" --expr > "$WORK/base_expr.ast" 2>/dev/null &&
       cmp -s "$WORK/base_expr.ast" "$WORK/b_expr.ast"; then
      echo "decisive: $name: refused, and the unmutated driver matches the hosted dump: $(refusal_note "$rc" "$WORK/a_expr.err")"
      return 1
    fi
    [ -n "$died" ] || died="$name: $(refusal_note "$rc" "$WORK/a_expr.err")"
  done
  for err_fixture in "$REPO"/bench/fixtures/sem_err_*.iyi; do
    case "$(basename "$err_fixture")" in
      sem_err_wrong_arg_count*|sem_err_type_mismatch*|sem_err_undefined_method*|sem_err_cvar_*|sem_err_recursive_*|sem_err_ivar_*|sem_err_top_level_*|sem_err_ambiguous_call*|sem_err_no_overload_matches*|sem_err_class_nil*|sem_err_class_symbol*)
        if "$1" "$(native_path "$err_fixture")" --expr >/dev/null 2>&1; then
          echo "decisive: $(basename "$err_fixture"): the mutant accepts a program the port rejects"
          return 1
        fi
        ;;
    esac
  done
  if [ -n "$died" ]; then
    echo "not evidence: the mutant died on $died"
    return 2
  fi
  return 0
}

fixture_count=0
total_matched_declarations=0
for fixture in "$REPO"/bench/fixtures/sem_*.iyi; do
  case "$(basename "$fixture")" in
    sem_err_*|sem_expr_*) continue ;;
    # The shared declaration oracle and driver resolve imports and compare
    # whole-program instance variable declarations.
  esac
  fixture_name="bench/fixtures/$(basename "$fixture")"
  port_ok=0
  oracle_ok=0
  "$WORK/declarations_port$EXE" "$(native_path "$fixture")" > "$WORK/iyi.ast" || port_ok=1
  "$WORK/declarations_oracle$EXE" "$(native_path "$fixture")" > "$WORK/hosted.ast" || oracle_ok=1
  if [ "$port_ok" -ne 0 ] || [ "$oracle_ok" -ne 0 ] || ! diff -q "$WORK/iyi.ast" "$WORK/hosted.ast" >/dev/null; then
    echo "  $fixture_name: DECLARATIONS DIFFER"
    diverged=$((diverged + 1))
    diff -u "$WORK/hosted.ast" "$WORK/iyi.ast" | head -20
    status=1
  else
    decl_count=$(awk '/^ *(Type|Def): / { n++ } END { print n+0 }' "$WORK/iyi.ast")
    echo "  $fixture_name: identical ($decl_count declarations match front end)"
    total_matched_declarations=$((total_matched_declarations + decl_count))
  fi
  fixture_count=$((fixture_count + 1))
done
echo "  Parity summary: $((fixture_count - diverged))/$fixture_count feature fixtures match 100% ($total_matched_declarations declarations compared)"

echo
echo "== 3. Typed expression comparison against the front end being replaced"
expr_fixture_count=0
expr_diverged=0
total_matched_expressions=0
for fixture in "$REPO"/bench/fixtures/sem_expr_*.iyi; do
  fixture_name="bench/fixtures/$(basename "$fixture")"
  "$WORK/exercise$EXE" "$(native_path "$fixture")" --expr > "$WORK/iyi_expr.ast"
  "$WORK/dump_hosted$EXE" "$(native_path "$fixture")" --expr > "$WORK/hosted_expr.ast"
  if ! diff -q "$WORK/iyi_expr.ast" "$WORK/hosted_expr.ast" >/dev/null; then
    echo "  $fixture_name: TYPED EXPRESSIONS DIFFER"
    expr_diverged=$((expr_diverged + 1))
    diff -u "$WORK/hosted_expr.ast" "$WORK/iyi_expr.ast" | head -20
    status=1
  else
    node_count=$("$WORK/exercise$EXE" "$(native_path "$fixture")" --expr-count)
    echo "  $fixture_name: identical ($node_count typed nodes match front end)"
    total_matched_expressions=$((total_matched_expressions + node_count))
  fi
  expr_fixture_count=$((expr_fixture_count + 1))
done
echo "  Parity summary: $((expr_fixture_count - expr_diverged))/$expr_fixture_count typed expression fixtures match 100% ($total_matched_expressions typed nodes compared)"

echo
echo "== 4. Semantic rejection and error checks"
total_err_count=0
matched_err_count=0
for err_fixture in "$REPO"/bench/fixtures/sem_err_*.iyi; do
  total_err_count=$((total_err_count + 1))
  err_name="bench/fixtures/$(basename "$err_fixture")"
  expected_err=$("$WORK/dump_hosted$EXE" "$(native_path "$err_fixture")" --expr 2>&1 | grep "^ERROR:" | head -1 | sed 's/^ERROR: //')
  if [ -z "$expected_err" ]; then
    expected_err=$("$WORK/dump_hosted$EXE" "$(native_path "$err_fixture")" 2>&1 | grep "^ERROR:" | head -1 | sed 's/^ERROR: //')
  fi
  "$WORK/exercise$EXE" "$(native_path "$err_fixture")" --expr > "$WORK/iyi_err.out" 2>&1
  actual_err=$(grep "iyi: panic:" "$WORK/iyi_err.out" | head -1 | sed 's/.*iyi: panic: //')
  if [ -z "$actual_err" ]; then
    "$WORK/exercise$EXE" "$(native_path "$err_fixture")" > "$WORK/iyi_err.out" 2>&1
    actual_err=$(grep "iyi: panic:" "$WORK/iyi_err.out" | head -1 | sed 's/.*iyi: panic: //')
  fi
  if [ -z "$expected_err" ]; then
    echo "  $err_name: oracle did not reject"
    status=1
  elif [ "$expected_err" = "$actual_err" ]; then
    echo "  $err_name: properly rejected ($actual_err)"
    matched_err_count=$((matched_err_count + 1))
  else
    echo "  $err_name: ERROR MISMATCH"
    echo "    expected: $expected_err"
    echo "    actual:   $actual_err"
    status=1
  fi
done
echo "  Parity summary: $matched_err_count/$total_err_count error fixtures rejected with identical errors"

# A build or oracle failure is not a behavioral catch.
check_decl_outputs_diverge() {
  local rc
  if ! "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_semantic_exercise.iyi" >"$WORK/mut-build.log" 2>&1 ||
     ! "$IYI" build -o "$WORK_NATIVE/mut-declarations$EXE" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" >>"$WORK/mut-build.log" 2>&1; then
    echo "INVALID MUTANT: semantic driver did not build"
    cat "$WORK/mut-build.log"
    return 0
  fi
  if compare_all "$WORK/mut-declarations$EXE" "$WORK/mut-exercise$EXE" && compare_expr_all "$WORK/mut-exercise$EXE"; then
    return 0
  else
    rc=$?
    if [ "$rc" -ne 1 ]; then
      echo "INVALID MUTANT: semantic oracle or driver failed"
      return 0
    fi
    return 1
  fi
}

check_expr_outputs_diverge() {
  local rc
  if ! "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_semantic_exercise.iyi" >"$WORK/mut-build.log" 2>&1; then
    echo "INVALID MUTANT: semantic driver did not build"
    cat "$WORK/mut-build.log"
    return 0
  fi
  if compare_expr_all "$WORK/mut-exercise$EXE"; then
    return 0
  else
    rc=$?
    if [ "$rc" -ne 1 ]; then
      echo "INVALID MUTANT: semantic oracle or driver failed"
      return 0
    fi
    return 1
  fi
}

check_wrong_arity_diverge() {
  if ! "$IYI" build -o "$WORK_NATIVE/mut-error$EXE" "$REPO_NATIVE/bench/selfhost_semantic_exercise.iyi" >/dev/null 2>&1; then
    echo "INVALID MUTANT: visitor driver did not build"
    return 0
  fi
  local fixture="$REPO/bench/fixtures/sem_err_wrong_arg_count.iyi"
  local expected actual
  expected=$("$WORK/dump_hosted$EXE" "$(native_path "$fixture")" --expr 2>&1 | grep "^ERROR:" | head -1 | sed 's/^ERROR: //')
  "$WORK/mut-error$EXE" "$(native_path "$fixture")" --expr > "$WORK/mut-error.out" 2>&1
  actual=$(grep "iyi: panic:" "$WORK/mut-error.out" | head -1 | sed 's/.*iyi: panic: //')
  [ -n "$expected" ] && [ -n "$actual" ] || return 0
  [ "$actual" = "$expected" ]
}

check_declaration_order_diverge() {
  if ! "$IYI" build -o "$WORK_NATIVE/mut-order$EXE" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" >/dev/null 2>&1; then
    echo "INVALID MUTANT: visitor driver did not build"
    return 0
  fi
  local fixture="$REPO/bench/fixtures/sem_declaration_order.iyi"
  "$WORK/declarations_oracle$EXE" "$(native_path "$fixture")" > "$WORK/order-oracle.ast" 2>/dev/null || return 0
  "$WORK/mut-order$EXE" "$(native_path "$fixture")" > "$WORK/order-mutant.ast" 2>/dev/null || return 0
  cmp -s "$WORK/order-oracle.ast" "$WORK/order-mutant.ast"
}

check_super_order_diverge() {
  if ! "$IYI" build -o "$WORK_NATIVE/mut-super$EXE" "$REPO_NATIVE/bench/selfhost_semantic_exercise.iyi" >/dev/null 2>&1; then
    echo "INVALID MUTANT: visitor driver did not build"
    return 0
  fi
  local fixture="$REPO/bench/fixtures/sem_expr_super_forward_overload.iyi"
  "$WORK/dump_hosted$EXE" "$(native_path "$fixture")" --expr > "$WORK/super-oracle.ast" 2>/dev/null || return 0
  "$WORK/exercise$EXE" "$(native_path "$fixture")" --expr > "$WORK/super-baseline.ast" 2>/dev/null || return 0
  cmp -s "$WORK/super-oracle.ast" "$WORK/super-baseline.ast" || return 0
  "$WORK/mut-super$EXE" "$(native_path "$fixture")" --expr > "$WORK/super-mutant.ast" 2>/dev/null || return 0
  grep -Fq 'target_def: choose: String' "$WORK/super-oracle.ast" || return 0
  grep -Fq 'target_def: choose: Int32' "$WORK/super-mutant.ast" || return 0
  cmp -s "$WORK/super-oracle.ast" "$WORK/super-mutant.ast"
}

check_ordinary_order_diverge() {
  if ! "$IYI" build -o "$WORK_NATIVE/mut-ordinary$EXE" "$REPO_NATIVE/bench/selfhost_semantic_exercise.iyi" >/dev/null 2>&1; then
    echo "INVALID MUTANT: visitor driver did not build"
    return 0
  fi
  local fixture="$REPO/bench/fixtures/sem_expr_ordinary_forward_overload.iyi"
  "$WORK/dump_hosted$EXE" "$(native_path "$fixture")" --expr > "$WORK/ordinary-oracle.ast" 2>/dev/null || return 0
  "$WORK/exercise$EXE" "$(native_path "$fixture")" --expr > "$WORK/ordinary-baseline.ast" 2>/dev/null || return 0
  cmp -s "$WORK/ordinary-oracle.ast" "$WORK/ordinary-baseline.ast" || return 0
  "$WORK/mut-ordinary$EXE" "$(native_path "$fixture")" --expr > "$WORK/ordinary-mutant.ast" 2>/dev/null || return 0
  grep -Fq 'target_def: ordinary_choose: String' "$WORK/ordinary-oracle.ast" || return 0
  grep -Fq 'target_def: ordinary_choose: Int32' "$WORK/ordinary-mutant.ast" || return 0
  cmp -s "$WORK/ordinary-oracle.ast" "$WORK/ordinary-mutant.ast"
}

check_ivar_dump_diverge() {
  "$IYI" build -o "$WORK_NATIVE/mut-declarations$EXE" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" >/dev/null 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; return 0; }
  "$WORK/mut-declarations$EXE" "$REPO_NATIVE/bench/fixtures/sem_bodies_ivar_read.iyi" > "$WORK/mut-ivar.ast" 2>/dev/null || { echo "INVALID MUTANT: declaration driver failed"; return 0; }
  cmp -s "$WORK/mut-ivar.ast" "$WORK/ivar-oracle.ast"
}

MUTATIONS_RUN=0

prove_mutation "struct default superclass switches to Reference" "$SEM" \
  "superclass = node.struct ? @program.struct_type : @program.reference_type" \
  "superclass = @program.reference_type" \
  -- check_decl_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "enum members start numbering at one instead of zero" "$SEM" \
  "counter = @enum_flags ? 1_i64 : 0_i64" \
  "counter = @enum_flags ? 1_i64 : 1_i64" \
  -- check_decl_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

ivar_fixture="$REPO/bench/fixtures/sem_bodies_ivar_read.iyi"
if "$WORK/declarations_oracle$EXE" "$(native_path "$ivar_fixture")" > "$WORK/ivar-oracle.ast" &&
   "$WORK/declarations_port$EXE" "$(native_path "$ivar_fixture")" > "$WORK/ivar-port.ast" &&
   cmp -s "$WORK/ivar-oracle.ast" "$WORK/ivar-port.ast" &&
   grep -q 'Ivar: ' "$WORK/ivar-oracle.ast"; then
  prove_mutation "declared instance variable is omitted from the dump" "$SEM" \
    '      io << indent << "  Ivar: " << t.full_name << "#" << ivar_name << "\n"' \
    '      nil' \
    -- check_ivar_dump_diverge || status=1
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
else
  echo "  NOT RUN: instance variable baseline differs or has no ivar"
  status=1
fi

prove_mutation "trait supertrait self-requirement check is bypassed" "$SEM" \
  "if st == type" \
  "if false && st == type" \
  -- check_decl_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "alias redefinition rejection is bypassed" "$SEM" \
  "if ex = existing" \
  "if false && (ex = existing)" \
  -- check_decl_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "method visibility defaults to private instead of public" "$SEM" \
  "node.visibility = Visibility::Public" \
  "node.visibility = Visibility::Private" \
  -- check_decl_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "predefined Nil built as a plain class instead of NilType" "$SEM" \
  "nil_t = NilType.new(self, self, \"Nil\", val)" \
  "nil_t = NonGenericClassType.new(self, self, \"Nil\", val)" \
  -- check_decl_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "predefined struct Symbol is marked as class instead of struct" "$SEM" \
  "sym_t.struct = true" \
  "sym_t.struct = false" \
  -- check_decl_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "predefined Proc type registration is bypassed" "$SEM" \
  '@types["Proc"] = proc_t' \
  '# @types["Proc"] = proc_t' \
  -- check_decl_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "union type resolution in lookup_type_node is bypassed" "$SEM" \
  "type_merge(types)" \
  "types.first" \
  -- check_decl_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "literal I32 kind defaults to int64" "$SEM_MAIN" \
  "when NumberKind::I32  then @program.int32_type" \
  "when NumberKind::I32  then @program.types[\"Int64\"]" \
  -- check_expr_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "variable assignment does not register in local scope" "$SEM_MAIN" \
  "@vars[v.name] = val_type" \
  "# @vars[v.name] = val_type" \
  -- check_expr_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "if branch typing bypasses else branch merge" "$SEM_MAIN" \
  "merged = merge_flow(then_type, else_type)" \
  "merged = then_type" \
  -- check_expr_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "method call resolution returns nil instead of method return type" "$SEM_MAIN" \
  "ret_type = call_result(node, body_ret)" \
  "ret_type = @program.nil_type" \
  -- check_expr_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "while loop condition type analysis is bypassed" "$SEM_MAIN" \
  "node.cond.accept(self)
      @needs_type_filters = @needs_type_filters - 1
      cond_type_filters = @type_filters" \
  "@needs_type_filters = @needs_type_filters - 1
      cond_type_filters = @type_filters" \
  -- check_expr_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "instance variable lookup returns nil instead of inferred type" "$SEM_MAIN" \
  "if ivar = target_type.as(ModuleType).lookup_instance_var?(node.name)
        set_type(node, ivar.type)" \
  "if ivar = target_type.as(ModuleType).lookup_instance_var?(node.name)
        set_type(node, @program.nil_type)" \
  -- check_expr_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "class variable non-nilable initializer check is bypassed" "$SEM_MAIN" \
  "if cvar.initializer.nil? && !cvar.type.nilable?" \
  "if false && cvar.initializer.nil?" \
  -- check_expr_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "recursive struct check cycle detection is bypassed" "$SEM_REC" \
  "if target.full_name == current.full_name" \
  "if false && target.full_name == current.full_name" \
  -- check_expr_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "wrong arity is reported as a type mismatch" "$SEM_MAIN" \
  '      if wrong = CallError.wrong_number_for(method_name, args.size, compatible, candidates.size)' \
  '      if wrong = (args.size < 0 ? CallError.wrong_number_for(method_name, args.size, compatible, candidates.size) : nil)' \
  -- check_wrong_arity_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "declaration overload order ignores strictness" "$SEM" \
  '            break if DeclarationOrder.before?(a_def, l[at], self, yields)' \
  '            break if false && DeclarationOrder.before?(a_def, l[at], self, yields)' \
  -- check_declaration_order_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "super lookup re-ranks declaration-ordered overloads" "$SEM_MAIN" \
  '      selected = exact_matches.first' \
  '      selected = exact_matches.first
      exact_matches.each do |candidate|
        next if candidate.args.empty? || selected.args.empty?
        candidate_restriction = candidate.args[0].restriction
        selected_restriction = selected.args[0].restriction
        if candidate_restriction && selected_restriction
          candidate_type = restriction_type(candidate_restriction, rec_type)
          selected_type = restriction_type(selected_restriction, rec_type)
          if candidate_type && selected_type && candidate_type != selected_type && candidate_type.subtype_of?(selected_type)
            selected = candidate
          end
        end
      end' \
  -- check_super_order_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "ordinary lookup re-ranks declaration-ordered overloads" "$SEM_MAIN" \
  '      ordered = defs.as(Array(Def))' \
  '      ordered = [] of Def
      defs.as(Array(Def)).each do |candidate|
        at = 0
        while at < ordered.size
          other = ordered[at]
          unless candidate.args.empty? || other.args.empty?
            candidate_restriction = candidate.args.last.restriction
            other_restriction = other.args.last.restriction
            if candidate_restriction && other_restriction
              candidate_type = restriction_type(candidate_restriction, owner)
              other_type = restriction_type(other_restriction, owner)
              if candidate_type && other_type && candidate_type != other_type && candidate_type.subtype_of?(other_type)
                break
              end
            end
          end
          at += 1
        end
        ordered.insert(at, candidate)
      end' \
  -- check_ordinary_order_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "union receiver multiple dispatch bypasses return type merge" "$SEM_MAIN" \
  "merged_ret = @program.type_merge(ret_types)" \
  "merged_ret = ret_types.first" \
  -- check_expr_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "closure variable mutation propagation into enclosing scope is bypassed" "$SEM_MAIN" \
  "old_vars[k] = @program.type_merge(old_v, new_v)" \
  "# old_vars[k] = @program.type_merge(old_v, new_v)" \
  -- check_expr_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "macro expansion in semantic traversal is bypassed" "$SEM_MAIN" \
  "if expand_macro(node)" \
  "if false && expand_macro(node)" \
  -- check_expr_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a macro site in a nested body forgets the locals typed before it" "$SEM_MAIN" \
  "    @vars.keys.each { |name| names << name unless names.includes?(name) }" \
  "    nil" \
  -- check_expr_outputs_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST SEMANTIC CHECKS PASSED"
else
  echo "== SELFHOST SEMANTIC CHECKS FAILED"
fi
exit $status
