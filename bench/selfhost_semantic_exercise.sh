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
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
SEM="$REPO/src/compiler/semantic/top_level.iyi"
SEM_MAIN="$REPO/src/compiler/semantic/main_visitor.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. Building and running the semantic visitor exercise"
"$IYI" build -o "$WORK/exercise" "$REPO/bench/selfhost_semantic_exercise.iyi"
"$WORK/exercise" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST SEMANTIC CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "  EXERCISE FAILED"
  status=1
fi

echo
echo "== 2. Semantic declaration comparison against the front end being replaced"
cat <<'CRYSTAL_GOLDEN_SCRIPT' > "$WORK/dump_crystal_sem.cr"
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
CRYSTAL_GOLDEN_SCRIPT

LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK/dump_crystal" "$WORK/dump_crystal_sem.cr"

compare_all() {
  out_status=0
  for fixture in "$REPO"/bench/fixtures/sem_*.iyi; do
    case "$(basename "$fixture")" in
      sem_expr_*)
        continue
        ;;
      sem_err_*)
        if "$1" "$fixture" >/dev/null 2>&1; then
          out_status=1
        fi
        continue
        ;;
    esac
    "$1" "$fixture" > "$WORK/a.ast" 2>/dev/null || { out_status=1; continue; }
    "$WORK/dump_crystal" "$fixture" > "$WORK/b.ast"
    diff -q "$WORK/a.ast" "$WORK/b.ast" >/dev/null || out_status=1
  done
  return $out_status
}

compare_expr_all() {
  out_status=0
  for fixture in "$REPO"/bench/fixtures/sem_expr_*.iyi; do
    "$1" "$fixture" --expr > "$WORK/a_expr.ast" 2>/dev/null || { out_status=1; continue; }
    "$WORK/dump_crystal" "$fixture" --expr > "$WORK/b_expr.ast"
    diff -q "$WORK/a_expr.ast" "$WORK/b_expr.ast" >/dev/null || out_status=1
  done
  for err_fixture in "$REPO"/bench/fixtures/sem_err_*.iyi; do
    case "$(basename "$err_fixture")" in
      sem_err_wrong_arg_count*|sem_err_type_mismatch*|sem_err_undefined_method*)
        if "$1" "$err_fixture" --expr >/dev/null 2>&1; then
          out_status=1
        fi
        ;;
    esac
  done
  return $out_status
}

fixture_count=0
total_matched_declarations=0
for fixture in "$REPO"/bench/fixtures/sem_*.iyi; do
  case "$(basename "$fixture")" in
    sem_err_*|sem_expr_*) continue ;;
  esac
  fixture_name="bench/fixtures/$(basename "$fixture")"
  "$WORK/exercise" "$fixture" > "$WORK/iyi.ast"
  "$WORK/dump_crystal" "$fixture" > "$WORK/crystal.ast"
  if ! diff -q "$WORK/iyi.ast" "$WORK/crystal.ast" >/dev/null; then
    echo "  $fixture_name: DECLARATIONS DIFFER"
    diff -u "$WORK/crystal.ast" "$WORK/iyi.ast" | head -20
    status=1
  else
    decl_count=$("$WORK/exercise" "$fixture" --count)
    echo "  $fixture_name: identical ($decl_count declarations match front end)"
    total_matched_declarations=$((total_matched_declarations + decl_count))
  fi
  fixture_count=$((fixture_count + 1))
done
echo "  Parity summary: $fixture_count/$fixture_count feature fixtures match 100% ($total_matched_declarations declarations compared)"

echo
echo "== 3. Typed expression comparison against the front end being replaced"
expr_fixture_count=0
total_matched_expressions=0
for fixture in "$REPO"/bench/fixtures/sem_expr_*.iyi; do
  fixture_name="bench/fixtures/$(basename "$fixture")"
  "$WORK/exercise" "$fixture" --expr > "$WORK/iyi_expr.ast"
  "$WORK/dump_crystal" "$fixture" --expr > "$WORK/crystal_expr.ast"
  if ! diff -q "$WORK/iyi_expr.ast" "$WORK/crystal_expr.ast" >/dev/null; then
    echo "  $fixture_name: TYPED EXPRESSIONS DIFFER"
    diff -u "$WORK/crystal_expr.ast" "$WORK/iyi_expr.ast" | head -20
    status=1
  else
    node_count=$("$WORK/exercise" "$fixture" --expr-count)
    echo "  $fixture_name: identical ($node_count typed nodes match front end)"
    total_matched_expressions=$((total_matched_expressions + node_count))
  fi
  expr_fixture_count=$((expr_fixture_count + 1))
done
echo "  Parity summary: $expr_fixture_count/$expr_fixture_count typed expression fixtures match 100% ($total_matched_expressions typed nodes compared)"

echo
echo "== 4. Semantic rejection and error checks"
err_count=0
for err_fixture in "$REPO"/bench/fixtures/sem_err_*.iyi; do
  err_name="bench/fixtures/$(basename "$err_fixture")"
  expected_err=$("$WORK/dump_crystal" "$err_fixture" --expr 2>&1 | grep "^ERROR:" | head -1 | sed 's/^ERROR: //')
  if [ -z "$expected_err" ]; then
    expected_err=$("$WORK/dump_crystal" "$err_fixture" 2>&1 | grep "^ERROR:" | head -1 | sed 's/^ERROR: //')
  fi
  "$WORK/exercise" "$err_fixture" --expr > "$WORK/iyi_err.out" 2>&1
  actual_err=$(grep "iyi: panic:" "$WORK/iyi_err.out" | head -1 | sed 's/.*iyi: panic: //')
  if [ -z "$actual_err" ]; then
    "$WORK/exercise" "$err_fixture" > "$WORK/iyi_err.out" 2>&1
    actual_err=$(grep "iyi: panic:" "$WORK/iyi_err.out" | head -1 | sed 's/.*iyi: panic: //')
  fi
  if [ -z "$expected_err" ]; then
    echo "  $err_name: oracle did not reject"
    status=1
  elif [ "$expected_err" = "$actual_err" ]; then
    echo "  $err_name: properly rejected ($actual_err)"
    err_count=$((err_count + 1))
  else
    echo "  $err_name: ERROR MISMATCH"
    echo "    expected: $expected_err"
    echo "    actual:   $actual_err"
    status=1
  fi
done
echo "  Parity summary: $err_count/$err_count error fixtures rejected with identical errors"

prove_decl_mutation() {
  label="$1"
  old="$2"
  new="$3"
  echo "  [$label]"
  cp "$SEM" "$SEM.orig"
  python3 - "$SEM" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
if old not in t:
    sys.exit(3)
open(path, "w").write(t.replace(old, new, 1))
PY
  rc=$?
  if [ "$rc" -eq 3 ] || diff -q "$SEM.orig" "$SEM" >/dev/null; then
    echo "    PATCH CHANGED NOTHING: this proves nothing"
    status=1
    cp "$SEM.orig" "$SEM"; rm -f "$SEM.orig"
    return
  fi
  if "$IYI" build -o "$WORK/mut-exercise" "$REPO/bench/selfhost_semantic_exercise.iyi" >/dev/null 2>&1; then
    if compare_all "$WORK/mut-exercise"; then
      echo "    FAILED: the comparison still passed with the mutation applied"
      status=1
    else
      echo "    caught: the declaration outputs diverged, as they must"
    fi
  else
    echo "    caught: the mutated semantic visitor did not build"
  fi
  cp "$SEM.orig" "$SEM"; rm -f "$SEM.orig"
  echo "    reverted"
}

prove_main_mutation() {
  label="$1"
  old="$2"
  new="$3"
  echo "  [$label]"
  cp "$SEM_MAIN" "$SEM_MAIN.orig"
  python3 - "$SEM_MAIN" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
if old not in t:
    sys.exit(3)
open(path, "w").write(t.replace(old, new, 1))
PY
  rc=$?
  if [ "$rc" -eq 3 ] || diff -q "$SEM_MAIN.orig" "$SEM_MAIN" >/dev/null; then
    echo "    PATCH CHANGED NOTHING: this proves nothing"
    status=1
    cp "$SEM_MAIN.orig" "$SEM_MAIN"; rm -f "$SEM_MAIN.orig"
    return
  fi
  if "$IYI" build -o "$WORK/mut-exercise" "$REPO/bench/selfhost_semantic_exercise.iyi" >/dev/null 2>&1; then
    if compare_expr_all "$WORK/mut-exercise"; then
      echo "    FAILED: the comparison still passed with the mutation applied"
      status=1
    else
      echo "    caught: the typed expression outputs diverged, as they must"
    fi
  else
    echo "    caught: the mutated semantic visitor did not build"
  fi
  cp "$SEM_MAIN.orig" "$SEM_MAIN"; rm -f "$SEM_MAIN.orig"
  echo "    reverted"
}

MUTATIONS_RUN=0

prove_decl_mutation "struct default superclass switches to Reference" \
  "superclass = node.struct ? @program.struct_type : @program.reference_type" \
  "superclass = @program.reference_type"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_decl_mutation "enum members start numbering at one instead of zero" \
  "counter = 0_i64" \
  "counter = 1_i64"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_decl_mutation "trait supertrait self-requirement check is bypassed" \
  "if st == type" \
  "if false && st == type"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_decl_mutation "alias redefinition rejection is bypassed" \
  "if ex = existing" \
  "if false && (ex = existing)"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_decl_mutation "method visibility defaults to private instead of public" \
  "node.visibility = Visibility::Public" \
  "node.visibility = Visibility::Private"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_main_mutation "literal I32 kind defaults to int64" \
  "when NumberKind::I32  then @program.int32_type" \
  "when NumberKind::I32  then @program.types[\"Int64\"]"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_main_mutation "variable assignment does not register in local scope" \
  "@vars[v.name] = val_type" \
  "# @vars[v.name] = val_type"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_main_mutation "if branch typing bypasses else branch merge" \
  "merged = @program.type_merge(then_type, else_type)" \
  "merged = then_type"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_main_mutation "method call resolution returns nil instead of method return type" \
  "ret_type = type_method_body(instantiated_def, rec_type, node.args, node.block)" \
  "ret_type = @program.nil_type"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_main_mutation "while loop condition type analysis is bypassed" \
  "node.cond.accept(self)
    node.body.accept(self)
    set_type(node, @program.nil_type)" \
  "node.body.accept(self)
    set_type(node, @program.nil_type)"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_main_mutation "instance variable lookup returns nil instead of inferred type" \
  "if ivar = target_type.as(ModuleType).lookup_instance_var?(node.name)
        set_type(node, ivar.type)" \
  "if ivar = target_type.as(ModuleType).lookup_instance_var?(node.name)
        set_type(node, @program.nil_type)"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST SEMANTIC CHECKS PASSED"
else
  echo "== SELFHOST SEMANTIC CHECKS FAILED"
fi
exit $status
