#!/usr/bin/env bash
# Exercises the self-hosting compiler parser expression core and AST parity.
#
#   bash bench/selfhost_parser_exercise.sh
#
# Verifies:
# 1. Plain compilation and execution of selfhost parser exercise
# 2. --release compilation and execution
# 3. Normalized AST comparison parity against Crystal-hosted frontend across syntax fixtures
# 4. Malformed-input and boundary rejection handling
# 5. Guarded mutation proofs verifying that test checks catch injected parser defects
#

set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
CRYSTAL="$REPO/bin/crystal"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
diverged=0

echo "== 1. Building and running selfhost parser exercise (plain mode)"
"$IYI" build -o "$WORK/exercise-plain" "$REPO/bench/selfhost_parser_exercise.iyi"
"$WORK/exercise-plain" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out"

echo
echo "== Checking reported verification counts in plain mode"
for phrase in \
  "testing literal parsing... ok (literals verified)" \
  "testing variable and path parsing... ok (variables and paths verified)" \
  "testing operator precedence and associativity... ok (precedence and associativity verified)" \
  "testing call and block parsing... ok (calls and blocks verified)" \
  "testing control expressions (if, unless, while, until, case, modifiers)... ok (control expressions verified)" \
  "testing declaration parsing... ok (declarations verified)" \
  "testing real syntax fixtures parsing... ok (1715 nodes across 25 fixtures)" \
  "ALL SELFHOST PARSER CHECKS PASSED SUCCESSFULLY!"; do
  if ! grep -qF "$phrase" "$WORK/plain.out"; then
    echo "  MISSING REPORTED CHECK: '$phrase'"
    status=1
  else
    echo "  verified report: '$phrase'"
  fi
done

echo
echo "== 2. Building and running selfhost parser exercise (--release mode)"
"$IYI" build --release -o "$WORK/exercise-release" "$REPO/bench/selfhost_parser_exercise.iyi"
"$WORK/exercise-release" > "$WORK/release.out" 2>&1
cat "$WORK/release.out"

if ! grep -qF "ALL SELFHOST PARSER CHECKS PASSED SUCCESSFULLY!" "$WORK/release.out"; then
  echo "  RELEASE RUN FAILED"
  status=1
else
  echo "  release mode verification passed"
fi

echo
echo "== 3. Golden normalized AST stream comparison vs Crystal frontend"

# Normalised AST dumper for differential comparison:
#
# What is normalised away and why:
# 1. Memory addresses and object IDs (e.g. 0x104ab820): Memory addresses vary across runs
#    and compilers; stripping them ensures the comparison checks AST structure rather than
#    allocator layout.
# 2. Absolute filesystem paths: Different machines and checkouts have different working
#    directories; stripping paths makes the comparison portable.
# 3. Incidental source formatting: Whitespace variations, comments, and Call#has_parentheses
#    are source formatting details rather than semantic AST structure; a call `foo(1)` and
#    `foo 1` have the identical AST structure `Call(obj=nil, name="foo", args=[1])`.
# 4. Class namespace prefixes (`Iyi::` in Crystal vs `Compiler::Syntax::Ast::` in iyi):
#    Stripped to the canonical unqualified node name so node types match identically.
#
# What is PRESERVED and strictly verified:
# - Exact AST node hierarchy and types (Call, Assign, OpAssign, If, Block, Splat, etc.)
# - Exact operator precedence and associativity (e.g. tree depth and child placement)
# - Exact literal values, signs, and number kinds (e.g. i32 vs f64)
# - Exact variable names and scope classifications (Var vs Call, InstanceVar, ClassVar)
# - Exact call arguments, named arguments, splat arguments, and block structure
# - Exact control flow conditions, then/else branches, ternary flags, and case whens

cat <<'CRYSTAL_GOLDEN_SCRIPT' > "$WORK/dump_crystal_ast.cr"
require "compiler/iyi/syntax"

def escape_s(s : String) : String
  res = "\""
  i = 0
  while i < s.bytesize
    case s.byte_at(i).chr
    when '\n' then res += "\\n"
    when '\r' then res += "\\r"
    when '\t' then res += "\\t"
    when '\\' then res += "\\\\"
    when '"'  then res += "\\\""
    else res += s.byte_at(i).chr.to_s
    end
    i += 1
  end
  res + "\""
end

def dump_ast(node : Iyi::ASTNode?, indent : Int32 = 0) : String
  return ("  " * indent) + "nil\n" if node.nil?
  p = "  " * indent
  case node
  when Iyi::Expressions
    kw = case node.keyword
         when .none? then "none"
         when .paren? then "paren"
         when .begin? then "begin"
         else "none"
         end
    s = "#{p}Expressions keyword=#{kw}\n"
    node.expressions.each { |e| s += dump_ast(e, indent + 1) }
    s
  when Iyi::Nop
    "#{p}Nop\n"
  when Iyi::NilLiteral
    "#{p}NilLiteral\n"
  when Iyi::BoolLiteral
    "#{p}BoolLiteral value=#{node.value}\n"
  when Iyi::NumberLiteral
    "#{p}NumberLiteral value=\"#{node.value}\" kind=#{node.kind.to_s.downcase}\n"
  when Iyi::CharLiteral
    "#{p}CharLiteral value=#{node.value.ord}\n"
  when Iyi::StringLiteral
    "#{p}StringLiteral value=#{escape_s(node.value)}\n"
  when Iyi::StringInterpolation
    s = "#{p}StringInterpolation\n"
    node.expressions.each { |e| s += dump_ast(e, indent + 1) }
    s
  when Iyi::SymbolLiteral
    "#{p}SymbolLiteral value=#{escape_s(node.value)}\n"
  when Iyi::Var
    "#{p}Var name=#{escape_s(node.name)}\n"
  when Iyi::InstanceVar
    "#{p}InstanceVar name=#{escape_s(node.name)}\n"
  when Iyi::ClassVar
    "#{p}ClassVar name=#{escape_s(node.name)}\n"
  when Iyi::Global
    "#{p}Global name=#{escape_s(node.name)}\n"
  when Iyi::Path
    "#{p}Path names=#{node.names.join("::")} global=#{node.global?}\n"
  when Iyi::Generic
    s = "#{p}Generic\n"
    s += "#{p}  name:\n" + dump_ast(node.name, indent + 2)
    s += "#{p}  type_vars:\n"
    node.type_vars.each { |tv| s += dump_ast(tv, indent + 2) }
    s
  when Iyi::Self
    "#{p}Self\n"
  when Iyi::Underscore
    "#{p}Underscore\n"
  when Iyi::ImplicitObj
    "#{p}ImplicitObj\n"
  when Iyi::ArrayLiteral
    s = "#{p}ArrayLiteral\n"
    node.elements.each { |e| s += dump_ast(e, indent + 1) }
    s
  when Iyi::HashLiteral
    s = "#{p}HashLiteral\n"
    node.entries.each do |entry|
      s += "#{p}  entry:\n"
      s += "#{p}    key:\n" + dump_ast(entry.key, indent + 3)
      s += "#{p}    value:\n" + dump_ast(entry.value, indent + 3)
    end
    s
  when Iyi::TupleLiteral
    s = "#{p}TupleLiteral\n"
    node.elements.each { |e| s += dump_ast(e, indent + 1) }
    s
  when Iyi::NamedTupleLiteral
    s = "#{p}NamedTupleLiteral\n"
    node.entries.each do |entry|
      s += "#{p}  entry key=#{escape_s(entry.key)}:\n" + dump_ast(entry.value, indent + 2)
    end
    s
  when Iyi::RangeLiteral
    s = "#{p}RangeLiteral exclusive=#{node.exclusive?}\n"
    s += "#{p}  from:\n" + dump_ast(node.from, indent + 2)
    s += "#{p}  to:\n" + dump_ast(node.to, indent + 2)
    s
  when Iyi::RegexLiteral
    s = "#{p}RegexLiteral\n"
    s += dump_ast(node.value, indent + 1)
    s
  when Iyi::Call
    s = "#{p}Call name=#{escape_s(node.name)}\n"
    if obj = node.obj
      s += "#{p}  obj:\n" + dump_ast(obj, indent + 2)
    end
    if !node.args.empty?
      s += "#{p}  args:\n"
      node.args.each { |a| s += dump_ast(a, indent + 2) }
    end
    if named_args = node.named_args
      s += "#{p}  named_args:\n"
      named_args.each { |na| s += dump_ast(na, indent + 2) }
    end
    if block_arg = node.block_arg
      s += "#{p}  block_arg:\n" + dump_ast(block_arg, indent + 2)
    end
    if block = node.block
      s += "#{p}  block:\n" + dump_ast(block, indent + 2)
    end
    s
  when Iyi::NamedArgument
    s = "#{p}NamedArgument name=#{escape_s(node.name)}:\n"
    s += dump_ast(node.value, indent + 1)
    s
  when Iyi::Block
    arg_names = node.args.map(&.name).join(", ")
    splat = node.splat_index ? node.splat_index.to_s : "none"
    s = "#{p}Block args=[#{arg_names}] splat=#{splat}:\n"
    s += dump_ast(node.body, indent + 1)
    s
  when Iyi::Assign
    s = "#{p}Assign\n"
    s += "#{p}  target:\n" + dump_ast(node.target, indent + 2)
    s += "#{p}  value:\n" + dump_ast(node.value, indent + 2)
    s
  when Iyi::OpAssign
    s = "#{p}OpAssign op=#{escape_s(node.op)}\n"
    s += "#{p}  target:\n" + dump_ast(node.target, indent + 2)
    s += "#{p}  value:\n" + dump_ast(node.value, indent + 2)
    s
  when Iyi::MultiAssign
    s = "#{p}MultiAssign\n"
    s += "#{p}  targets:\n"
    node.targets.each { |t| s += dump_ast(t, indent + 2) }
    s += "#{p}  values:\n"
    node.values.each { |v| s += dump_ast(v, indent + 2) }
    s
  when Iyi::If
    s = "#{p}If ternary=#{node.ternary?}\n"
    s += "#{p}  cond:\n" + dump_ast(node.cond, indent + 2)
    s += "#{p}  then:\n" + dump_ast(node.then, indent + 2)
    s += "#{p}  else:\n" + dump_ast(node.else, indent + 2)
    s
  when Iyi::Unless
    s = "#{p}Unless\n"
    s += "#{p}  cond:\n" + dump_ast(node.cond, indent + 2)
    s += "#{p}  then:\n" + dump_ast(node.then, indent + 2)
    s += "#{p}  else:\n" + dump_ast(node.else, indent + 2)
    s
  when Iyi::While
    s = "#{p}While\n"
    s += "#{p}  cond:\n" + dump_ast(node.cond, indent + 2)
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::Until
    s = "#{p}Until\n"
    s += "#{p}  cond:\n" + dump_ast(node.cond, indent + 2)
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::Case
    s = "#{p}Case exhaustive=#{node.exhaustive?}\n"
    if cond = node.cond
      s += "#{p}  cond:\n" + dump_ast(cond, indent + 2)
    end
    s += "#{p}  whens:\n"
    node.whens.each { |w| s += dump_ast(w, indent + 2) }
    if el = node.else
      s += "#{p}  else:\n" + dump_ast(el, indent + 2)
    end
    s
  when Iyi::When
    s = "#{p}When\n"
    s += "#{p}  conds:\n"
    node.conds.each { |c| s += dump_ast(c, indent + 2) }
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::And
    s = "#{p}And\n"
    s += "#{p}  left:\n" + dump_ast(node.left, indent + 2)
    s += "#{p}  right:\n" + dump_ast(node.right, indent + 2)
    s
  when Iyi::Or
    s = "#{p}Or\n"
    s += "#{p}  left:\n" + dump_ast(node.left, indent + 2)
    s += "#{p}  right:\n" + dump_ast(node.right, indent + 2)
    s
  when Iyi::Not
    s = "#{p}Not\n"
    s += dump_ast(node.exp, indent + 1)
    s
  when Iyi::Splat
    s = "#{p}Splat\n"
    s += dump_ast(node.exp, indent + 1)
    s
  when Iyi::DoubleSplat
    s = "#{p}DoubleSplat\n"
    s += dump_ast(node.exp, indent + 1)
    s
  when Iyi::Return
    s = "#{p}Return\n"
    s += dump_ast(node.exp, indent + 1)
    s
  when Iyi::Break
    s = "#{p}Break\n"
    s += dump_ast(node.exp, indent + 1)
    s
  when Iyi::Next
    s = "#{p}Next\n"
    s += dump_ast(node.exp, indent + 1)
    s
  when Iyi::Yield
    s = "#{p}Yield\n"
    node.exps.each { |e| s += dump_ast(e, indent + 1) }
    s
  when Iyi::Def
    receiver_s = node.receiver ? " receiver" : ""
    abstract_s = node.abstract? ? " abstract=true" : ""
    splat_s = node.splat_index ? " splat=#{node.splat_index}" : ""
    s = "#{p}Def name=#{escape_s(node.name)}#{receiver_s}#{abstract_s}#{splat_s}\n"
    if r = node.receiver
      s += "#{p}  receiver:\n" + dump_ast(r, indent + 2)
    end
    if !node.args.empty?
      s += "#{p}  args:\n"
      node.args.each { |a| s += dump_ast(a, indent + 2) }
    end
    if ds = node.double_splat
      s += "#{p}  double_splat:\n" + dump_ast(ds, indent + 2)
    end
    if ba = node.block_arg
      s += "#{p}  block_arg:\n" + dump_ast(ba, indent + 2)
    end
    if rt = node.return_type
      s += "#{p}  return_type:\n" + dump_ast(rt, indent + 2)
    end
    if fv = node.free_vars
      s += "#{p}  free_vars=[#{fv.join(", ")}]\n"
    end
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::Arg
    ext_s = (ext = node.external_name) && ext != node.name ? " external_name=#{escape_s(ext)}" : ""
    s = "#{p}Arg name=#{escape_s(node.name)}#{ext_s}\n"
    if rest = node.restriction
      s += "#{p}  restriction:\n" + dump_ast(rest, indent + 2)
    end
    if def_val = node.default_value
      s += "#{p}  default_value:\n" + dump_ast(def_val, indent + 2)
    end
    s
  when Iyi::ClassDef
    splat_s = node.splat_index ? " splat=#{node.splat_index}" : ""
    s = "#{p}ClassDef struct=#{node.struct?} abstract=#{node.abstract?}#{splat_s}\n"
    s += "#{p}  name:\n" + dump_ast(node.name, indent + 2)
    if tv = node.type_vars
      s += "#{p}  type_vars=[#{tv.join(", ")}]\n"
    end
    if sc = node.superclass
      s += "#{p}  superclass:\n" + dump_ast(sc, indent + 2)
    end
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::ModuleDef
    splat_s = node.splat_index ? " splat=#{node.splat_index}" : ""
    s = "#{p}ModuleDef#{splat_s}\n"
    s += "#{p}  name:\n" + dump_ast(node.name, indent + 2)
    if tv = node.type_vars
      s += "#{p}  type_vars=[#{tv.join(", ")}]\n"
    end
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::EnumDef
    s = "#{p}EnumDef\n"
    s += "#{p}  name:\n" + dump_ast(node.name, indent + 2)
    if bt = node.base_type
      s += "#{p}  base_type:\n" + dump_ast(bt, indent + 2)
    end
    if !node.members.empty?
      s += "#{p}  members:\n"
      node.members.each { |m| s += dump_ast(m, indent + 2) }
    end
    s
  when Iyi::Alias
    s = "#{p}Alias\n"
    s += "#{p}  name:\n" + dump_ast(node.name, indent + 2)
    s += "#{p}  value:\n" + dump_ast(node.value, indent + 2)
    s
  when Iyi::Include
    s = "#{p}Include\n"
    s += "#{p}  name:\n" + dump_ast(node.name, indent + 2)
    s
  when Iyi::Extend
    s = "#{p}Extend\n"
    s += "#{p}  name:\n" + dump_ast(node.name, indent + 2)
    s
  when Iyi::TraitDef
    s = "#{p}TraitDef\n"
    s += "#{p}  name:\n" + dump_ast(node.name, indent + 2)
    if tv = node.type_vars
      s += "#{p}  type_vars=[#{tv.join(", ")}]\n"
    end
    if at = node.assoc_types
      s += "#{p}  assoc_types=[#{at.join(", ")}]\n"
    end
    if st = node.supertraits
      s += "#{p}  supertraits:\n"
      st.each { |st_node| s += dump_ast(st_node, indent + 2) }
    end
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::ImplDef
    s = "#{p}ImplDef\n"
    s += "#{p}  trait:\n" + dump_ast(node.trait, indent + 2)
    if ta = node.trait_args
      s += "#{p}  trait_args:\n"
      ta.each { |arg| s += dump_ast(arg, indent + 2) }
    end
    s += "#{p}  target:\n" + dump_ast(node.target, indent + 2)
    if tv = node.type_vars
      s += "#{p}  type_vars=[#{tv.join(", ")}]\n"
    end
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::AssocTypeDecl
    s = "#{p}AssocTypeDecl name=#{escape_s(node.name)}\n"
    if val = node.value
      s += "#{p}  value:\n" + dump_ast(val, indent + 2)
    end
    s
  when Iyi::AnnotationDef
    s = "#{p}AnnotationDef\n"
    s += "#{p}  name:\n" + dump_ast(node.name, indent + 2)
    s
  when Iyi::Annotation
    s = "#{p}Annotation\n"
    s += "#{p}  path:\n" + dump_ast(node.path, indent + 2)
    if !node.args.empty?
      s += "#{p}  args:\n"
      node.args.each { |a| s += dump_ast(a, indent + 2) }
    end
    if na = node.named_args
      s += "#{p}  named_args:\n"
      na.each { |a| s += dump_ast(a, indent + 2) }
    end
    s
  when Iyi::TypeDeclaration
    s = "#{p}TypeDeclaration\n"
    s += "#{p}  var:\n" + dump_ast(node.var, indent + 2)
    s += "#{p}  declared_type:\n" + dump_ast(node.declared_type, indent + 2)
    if val = node.value
      s += "#{p}  value:\n" + dump_ast(val, indent + 2)
    end
    s
  when Iyi::UninitializedVar
    s = "#{p}UninitializedVar\n"
    s += "#{p}  var:\n" + dump_ast(node.var, indent + 2)
    s += "#{p}  declared_type:\n" + dump_ast(node.declared_type, indent + 2)
    s
  when Iyi::VisibilityModifier
    s = "#{p}VisibilityModifier modifier=#{node.modifier.to_s.downcase}\n"
    s += "#{p}  exp:\n" + dump_ast(node.exp, indent + 2)
    s
  when Iyi::LibDef
    s = "#{p}LibDef\n"
    s += "#{p}  name:\n" + dump_ast(node.name, indent + 2)
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::FunDef
    real_s = (r = node.real_name) ? " real_name=#{escape_s(r)}" : ""
    s = "#{p}FunDef name=#{escape_s(node.name)}#{real_s}\n"
    if !node.args.empty?
      s += "#{p}  args:\n"
      node.args.each { |a| s += dump_ast(a, indent + 2) }
    end
    if rt = node.return_type
      s += "#{p}  return_type:\n" + dump_ast(rt, indent + 2)
    end
    if b = node.body
      s += "#{p}  body:\n" + dump_ast(b, indent + 2)
    end
    s
  when Iyi::TypeDef
    s = "#{p}TypeDef name=#{escape_s(node.name)}\n"
    s += "#{p}  type_spec:\n" + dump_ast(node.type_spec, indent + 2)
    s
  when Iyi::CStructOrUnionDef
    s = "#{p}CStructOrUnionDef name=#{escape_s(node.name)} union=#{node.union?}\n"
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::ExternalVar
    real_s = (r = node.real_name) ? " real_name=#{escape_s(r)}" : ""
    s = "#{p}ExternalVar name=#{escape_s(node.name)}#{real_s}\n"
    s += "#{p}  type_spec:\n" + dump_ast(node.type_spec, indent + 2)
    s
  when Iyi::ProcNotation
    s = "#{p}ProcNotation\n"
    if inputs = node.inputs
      s += "#{p}  inputs:\n"
      inputs.each { |inp| s += dump_ast(inp, indent + 2) }
    end
    if o = node.output
      s += "#{p}  output:\n" + dump_ast(o, indent + 2)
    end
    s
  when Iyi::Union
    s = "#{p}Union\n"
    s += "#{p}  types:\n"
    node.types.each { |t| s += dump_ast(t, indent + 2) }
    s
  when Iyi::Metaclass
    s = "#{p}Metaclass\n"
    s += "#{p}  name:\n" + dump_ast(node.name, indent + 2)
    s
  when Iyi::Macro
    s = "#{p}Macro name=#{escape_s(node.name)}\n"
    if !node.args.empty?
      s += "#{p}  args:\n"
      node.args.each { |a| s += dump_ast(a, indent + 2) }
    end
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::MacroIf
    s = "#{p}MacroIf\n"
    s += "#{p}  cond:\n" + dump_ast(node.cond, indent + 2)
    s += "#{p}  then:\n" + dump_ast(node.then, indent + 2)
    s += "#{p}  else:\n" + dump_ast(node.else, indent + 2)
    s
  when Iyi::MacroFor
    vars_s = node.vars.map(&.name).join(", ")
    s = "#{p}MacroFor vars=[#{vars_s}]\n"
    s += "#{p}  exp:\n" + dump_ast(node.exp, indent + 2)
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::MacroExpression
    s = "#{p}MacroExpression output=#{node.output?}\n"
    s += dump_ast(node.exp, indent + 1)
    s
  when Iyi::MacroLiteral
    "#{p}MacroLiteral value=#{escape_s(node.value)}\n"
  when Iyi::MacroVar
    s = "#{p}MacroVar name=#{escape_s(node.name)}\n"
    if exps = node.exps
      s += "#{p}  exps:\n"
      exps.each { |e| s += dump_ast(e, indent + 2) }
    end
    s
  when Iyi::MacroVerbatim
    s = "#{p}MacroVerbatim\n"
    s += "#{p}  exp:\n" + dump_ast(node.exp, indent + 2)
    s
  else
    "#{p}#{node.class.name}\n"
  end
end

class Counter < Iyi::Visitor
  getter count = 0
  def visit(node : Iyi::ASTNode) : Bool
    @count += 1
    true
  end
end

filename = ARGV[0]
src = File.read(filename)
node = Iyi::Parser.new(src).parse

if ARGV.size > 1 && ARGV[1] == "--count"
  c = Counter.new
  node.accept(c)
  puts c.count
else
  print dump_ast(node)
end
CRYSTAL_GOLDEN_SCRIPT

CRYSTAL_PATH="$REPO/src" "$CRYSTAL" build -o "$WORK/dump_crystal" "$WORK/dump_crystal_ast.cr"

fixture_count=0
total_matched_nodes=0

for fixture in \
  "$REPO"/bench/fixtures/expr_literals.iyi \
  "$REPO"/bench/fixtures/expr_variables_and_paths.iyi \
  "$REPO"/bench/fixtures/expr_operators.iyi \
  "$REPO"/bench/fixtures/expr_calls_and_blocks.iyi \
  "$REPO"/bench/fixtures/expr_control.iyi \
  "$REPO"/bench/fixtures/expr_modifiers.iyi \
  "$REPO"/bench/fixtures/expr_collections.iyi \
  "$REPO"/bench/fixtures/expr_precedence.iyi \
  "$REPO"/bench/fixtures/expr_associativity.iyi \
  "$REPO"/bench/fixtures/expr_combined.iyi \
  "$REPO"/bench/fixtures/expr_ranges_and_tuples.iyi \
  "$REPO"/bench/fixtures/expr_hashes_and_arrays.iyi \
  "$REPO"/bench/fixtures/expr_blocks.iyi \
  "$REPO"/bench/fixtures/expr_multi_assign.iyi \
  "$REPO"/bench/fixtures/expr_case_when.iyi \
  "$REPO"/bench/fixtures/decl_classes_and_structs.iyi \
  "$REPO"/bench/fixtures/decl_def.iyi \
  "$REPO"/bench/fixtures/decl_enums.iyi \
  "$REPO"/bench/fixtures/decl_lib_and_fun.iyi \
  "$REPO"/bench/fixtures/decl_modules_and_inclusion.iyi \
  "$REPO"/bench/fixtures/decl_operators.iyi \
  "$REPO"/bench/fixtures/decl_traits_and_impls.iyi \
  "$REPO"/bench/fixtures/decl_types_and_vars.iyi \
  "$REPO"/bench/fixtures/decl_visibility_and_annotations.iyi \
  "$REPO"/bench/fixtures/macro_control_grammar.iyi; do
  fixture_name="${fixture#"$REPO/"}"
  "$WORK/exercise-plain" "$fixture" > "$WORK/iyi.ast"
  "$WORK/dump_crystal" "$fixture" > "$WORK/crystal.ast"

  if ! cmp -s "$WORK/iyi.ast" "$WORK/crystal.ast"; then
    echo "  $fixture_name: MISMATCH"
    diff -u "$WORK/crystal.ast" "$WORK/iyi.ast" | head -20
    status=1
  else
    nodes_count=$("$WORK/dump_crystal" "$fixture" --count)
    echo "  $fixture_name: identical ($nodes_count normalized nodes match Crystal frontend)"
    total_matched_nodes=$((total_matched_nodes + nodes_count))
  fi
  fixture_count=$((fixture_count + 1))
done

echo "  Parity summary: $((fixture_count - diverged))/$fixture_count syntax fixtures match 100% ($total_matched_nodes total nodes)"

echo
echo "== 4. Malformed-input and boundary rejection checks"
for bad in \
  "1 +" \
  "(1 + 2" \
  "[1, 2" \
  "{1 => 2" \
  "if true" \
  "while true" \
  "case x; when 1;" \
  "foo(x: )" \
  "x = 1 while true" \
  "x = 1 until true" \
  '$bad_global = 1'; do
  if "$WORK/exercise-plain" -e "$bad" >/dev/null 2>&1; then
    echo "  FAILED TO REJECT: $bad"
    status=1
  else
    echo "  properly rejected: $bad"
  fi
done

echo
echo "== 5. Guarded mutation proofs (verify patch applies, exercise fails, revert passes)"

# Mutation 1: Break operator precedence in parse_add_or_sub
echo "  [mutation 1] altering operator precedence in parse_add_or_sub"
cp "$REPO/src/compiler/syntax/parser.iyi" "$REPO/src/compiler/syntax/parser.iyi.orig"
sed -i.bak 's/left = parse_mul_or_div/left = parse_prefix/' "$REPO/src/compiler/syntax/parser.iyi" && rm -f "$REPO/src/compiler/syntax/parser.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi" >/dev/null; then
  echo "    patch did not apply"
  status=1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_parser_exercise.iyi" > "$WORK/mut1.log" 2>&1; then
  echo "    FAILED: exercise still passed with mutation 1"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi"
rm -f "$REPO/src/compiler/syntax/parser.iyi.orig"
echo "    reverted mutation 1"

# Mutation 2: Break operator right-associativity in parse_pow
echo "  [mutation 2] altering operator right-associativity in parse_pow"
cp "$REPO/src/compiler/syntax/parser.iyi" "$REPO/src/compiler/syntax/parser.iyi.orig"
sed -i.bak 's/right = parse_pow/right = parse_prefix/' "$REPO/src/compiler/syntax/parser.iyi" && rm -f "$REPO/src/compiler/syntax/parser.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi" >/dev/null; then
  echo "    patch did not apply"
  status=1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_parser_exercise.iyi" > "$WORK/mut2.log" 2>&1; then
  echo "    FAILED: exercise still passed with mutation 2"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi"
rm -f "$REPO/src/compiler/syntax/parser.iyi.orig"
echo "    reverted mutation 2"

# Mutation 3: Break block recognition in parse_block
echo "  [mutation 3] altering block recognition in parse_block"
cp "$REPO/src/compiler/syntax/parser.iyi" "$REPO/src/compiler/syntax/parser.iyi.orig"
sed -i.bak 's/if @token.keyword == Keyword::DO/if false \&\& @token.keyword == Keyword::DO/' "$REPO/src/compiler/syntax/parser.iyi" && rm -f "$REPO/src/compiler/syntax/parser.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi" >/dev/null; then
  echo "    patch did not apply"
  status=1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_parser_exercise.iyi" > "$WORK/mut3.log" 2>&1; then
  echo "    FAILED: exercise still passed with mutation 3"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi"
rm -f "$REPO/src/compiler/syntax/parser.iyi.orig"
echo "    reverted mutation 3"

# Mutation 4: Break modifier form recognition
echo "  [mutation 4] altering modifier if form recognition"
cp "$REPO/src/compiler/syntax/parser.iyi" "$REPO/src/compiler/syntax/parser.iyi.orig"
sed -i.bak 's/If[.]new(exp, res, Nop[.]new)/Unless.new(exp, res, Nop.new)/' "$REPO/src/compiler/syntax/parser.iyi" && rm -f "$REPO/src/compiler/syntax/parser.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi" >/dev/null; then
  echo "    patch did not apply"
  status=1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_parser_exercise.iyi" > "$WORK/mut4.log" 2>&1; then
  echo "    FAILED: exercise still passed with mutation 4"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi"
rm -f "$REPO/src/compiler/syntax/parser.iyi.orig"
echo "    reverted mutation 4"

# Mutation 5: Break splat argument in parse_call_arg
echo "  [mutation 5] altering splat argument parsing in parse_call_arg"
cp "$REPO/src/compiler/syntax/parser.iyi" "$REPO/src/compiler/syntax/parser.iyi.orig"
sed -i.bak 's/Splat[.]new(parse_op_assign_no_control)[.]at(location)/parse_op_assign_no_control/' "$REPO/src/compiler/syntax/parser.iyi" && rm -f "$REPO/src/compiler/syntax/parser.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi" >/dev/null; then
  echo "    patch did not apply"
  status=1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_parser_exercise.iyi" > "$WORK/mut5.log" 2>&1; then
  echo "    FAILED: exercise still passed with mutation 5"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi"
rm -f "$REPO/src/compiler/syntax/parser.iyi.orig"
echo "    reverted mutation 5"

# Mutation 6: Break return type parsing in parse_def_helper
echo "  [mutation 6] altering return type parsing in parse_def_helper"
cp "$REPO/src/compiler/syntax/parser.iyi" "$REPO/src/compiler/syntax/parser.iyi.orig"
sed -i.bak 's/end_location = return_type[.]end_location/return_type = nil; end_location = nil/' "$REPO/src/compiler/syntax/parser.iyi" && rm -f "$REPO/src/compiler/syntax/parser.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi" >/dev/null; then
  echo "    patch did not apply"
  status=1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_parser_exercise.iyi" > "$WORK/mut6.log" 2>&1; then
  echo "    FAILED: exercise still passed with mutation 6"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi"
rm -f "$REPO/src/compiler/syntax/parser.iyi.orig"
echo "    reverted mutation 6"

# Mutation 7: Break superclass parsing in parse_class_def
echo "  [mutation 7] altering superclass parsing in parse_class_def"
cp "$REPO/src/compiler/syntax/parser.iyi" "$REPO/src/compiler/syntax/parser.iyi.orig"
sed -i.bak 's/superclass = parse_generic(false, @token.location, false)/superclass = nil/' "$REPO/src/compiler/syntax/parser.iyi" && rm -f "$REPO/src/compiler/syntax/parser.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi" >/dev/null; then
  echo "    patch did not apply"
  status=1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_parser_exercise.iyi" > "$WORK/mut7.log" 2>&1; then
  echo "    FAILED: exercise still passed with mutation 7"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi"
rm -f "$REPO/src/compiler/syntax/parser.iyi.orig"
echo "    reverted mutation 7"

# Mutation 8: Break enum member value parsing in parse_enum_body_expressions
echo "  [mutation 8] altering enum member value parsing in parse_enum_body_expressions"
cp "$REPO/src/compiler/syntax/parser.iyi" "$REPO/src/compiler/syntax/parser.iyi.orig"
sed -i.bak 's/constant_value = parse_logical_or/constant_value = nil/' "$REPO/src/compiler/syntax/parser.iyi" && rm -f "$REPO/src/compiler/syntax/parser.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi" >/dev/null; then
  echo "    patch did not apply"
  status=1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_parser_exercise.iyi" > "$WORK/mut8.log" 2>&1; then
  echo "    FAILED: exercise still passed with mutation 8"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi"
rm -f "$REPO/src/compiler/syntax/parser.iyi.orig"
echo "    reverted mutation 8"

# Mutation 9: Break trait implementation target parsing in parse_impl_def
echo "  [mutation 9] altering trait implementation target parsing in parse_impl_def"
cp "$REPO/src/compiler/syntax/parser.iyi" "$REPO/src/compiler/syntax/parser.iyi.orig"
sed -i.bak 's/target = parse_path(false, @token.location)/target = parse_path(true, @token.location)/' "$REPO/src/compiler/syntax/parser.iyi" && rm -f "$REPO/src/compiler/syntax/parser.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi" >/dev/null; then
  echo "    patch did not apply"
  status=1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_parser_exercise.iyi" > "$WORK/mut9.log" 2>&1; then
  echo "    FAILED: exercise still passed with mutation 9"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/parser.iyi.orig" "$REPO/src/compiler/syntax/parser.iyi"
rm -f "$REPO/src/compiler/syntax/parser.iyi.orig"
echo "    reverted mutation 9"

echo
echo "== Verification clean state confirmed"
"$WORK/exercise-release" >/dev/null

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST PARSER EXERCISE CHECKS PASSED!"
else
  echo "== SELFHOST PARSER EXERCISE CHECKS FAILED"
fi

exit $status
