#!/usr/bin/env bash
# Exercises the self-hosting compiler parser expression core and AST parity.
#
#   bash bench/selfhost_parser_exercise.sh
#
# Verifies:
# 1. Plain compilation and execution of selfhost parser exercise
# 2. --release compilation and execution
# 3. Normalized AST comparison parity against the hosted frontend across syntax fixtures
# 4. Malformed-input and boundary rejection handling
# 5. Guarded mutation proofs verifying that test checks catch injected parser defects
#
# The golden oracle is a script for the hosted front end. It parses each .iyi
# fixture in iyi mode: it sets `parser.filename` to the file before
# `parser.parse`, so the iyi lexer and parser rules apply, not the compatibility
# compiler's default rules. Its dump names every node kind the port emits (module headers,
# imports, using, asm and asm operands, casts, type queries, pointerof/sizeof,
# require, select, exception handlers, proc literals and more). A kind the dump
# does not name falls back to the generic `ASTNode` label on the port side.
#

set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh"
require_test_host
IYI="$REPO/bin/iyi"
HOSTED_COMPILER="$REPO/bin/crystal"
PARSER="$REPO/src/compiler/syntax/parser.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE="$(native_path "$REPO")"
WORK_NATIVE="$(native_path "$WORK")"
export IYI_PATH="$REPO_NATIVE/src"
. "$REPO/bench/lib/mutation.sh"
cd "$REPO"

status=0
diverged=0

echo "== 1. Building and running selfhost parser exercise (plain mode)"
"$IYI" build -o "$WORK_NATIVE/exercise-plain$EXE" "$REPO_NATIVE/bench/selfhost_parser_exercise.iyi"
"$WORK/exercise-plain$EXE" > "$WORK/plain.out" 2>&1
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
  "testing real syntax fixtures parsing... ok (2549 nodes across 38 fixtures)" \
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
"$IYI" build --release -o "$WORK_NATIVE/exercise-release$EXE" "$REPO_NATIVE/bench/selfhost_parser_exercise.iyi"
"$WORK/exercise-release$EXE" > "$WORK/release.out" 2>&1
cat "$WORK/release.out"

if ! grep -qF "ALL SELFHOST PARSER CHECKS PASSED SUCCESSFULLY!" "$WORK/release.out"; then
  echo "  RELEASE RUN FAILED"
  status=1
else
  echo "  release mode verification passed"
fi

echo
echo "== 3. Golden normalized AST stream comparison vs hosted frontend"

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
# 4. Class namespace prefixes (`Iyi::` in the hosted frontend vs `Compiler::Syntax::Ast::` in iyi):
#    Stripped to the canonical unqualified node name so node types match identically.
#
# What is PRESERVED and strictly verified:
# - Exact AST node hierarchy and types (Call, Assign, OpAssign, If, Block, Splat, etc.)
# - Exact operator precedence and associativity (e.g. tree depth and child placement)
# - Exact literal values, signs, and number kinds (e.g. i32 vs f64)
# - Exact variable names and scope classifications (Var vs Call, InstanceVar, ClassVar)
# - Exact call arguments, named arguments, splat arguments, and block structure
# - Exact control flow conditions, then/else branches, ternary flags, and case whens

cat <<'HOSTED_GOLDEN_SCRIPT' > "$WORK/dump_hosted_ast.cr"
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
    if ARGV[0]?.try(&.ends_with?("syntax_call_spans.iyi"))
      if loc = node.end_location
        s += "#{p}  end=#{loc.line_number}:#{loc.column_number}\n"
      else
        s += "#{p}  end=nil\n"
      end
    end
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
    if unpacks = node.unpacks
      unpacks.each do |index, expressions|
        s += "#{p}  unpack[#{index}]:\n" + dump_ast(expressions, indent + 2)
      end
    end
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
  when Iyi::MagicConstant
    "#{p}MagicConstant name=#{node.name.to_s.downcase}\n"
  when Iyi::ModuleHeader
    "#{p}ModuleHeader path=#{escape_s(node.path.join("/"))}\n"
  when Iyi::ImportDecl
    names_s = (n = node.names) ? "[#{n.join(", ")}]" : "nil"
    "#{p}ImportDecl path=#{escape_s(node.path.join("/"))} exported=#{node.exported} glob=#{node.glob?} names=#{names_s}\n"
  when Iyi::UsingDecl
    names_s = (n = node.names) ? "[#{n.join(", ")}]" : "nil"
    "#{p}UsingDecl path=#{escape_s(node.path.join("/"))} names=#{names_s}\n"
  when Iyi::Asm
    s = "#{p}Asm text=#{escape_s(node.text)} volatile=#{node.volatile?} alignstack=#{node.alignstack?} intel=#{node.intel?} can_throw=#{node.can_throw?}\n"
    if outs = node.outputs
      s += "#{p}  outputs:\n"
      outs.each { |o| s += dump_ast(o, indent + 2) }
    end
    if ins = node.inputs
      s += "#{p}  inputs:\n"
      ins.each { |i| s += dump_ast(i, indent + 2) }
    end
    if cls = node.clobbers
      s += "#{p}  clobbers=[#{cls.map { |c| escape_s(c) }.join(", ")}]\n"
    end
    s
  when Iyi::AsmOperand
    s = "#{p}AsmOperand constraint=#{escape_s(node.constraint)}\n"
    s += dump_ast(node.exp, indent + 1)
    s
  when Iyi::Cast
    s = "#{p}Cast\n"
    s += "#{p}  obj:\n" + dump_ast(node.obj, indent + 2)
    s += "#{p}  to:\n" + dump_ast(node.to, indent + 2)
    s
  when Iyi::NilableCast
    s = "#{p}NilableCast\n"
    s += "#{p}  obj:\n" + dump_ast(node.obj, indent + 2)
    s += "#{p}  to:\n" + dump_ast(node.to, indent + 2)
    s
  when Iyi::IsA
    s = "#{p}IsA nil_check=#{node.nil_check?}\n"
    s += "#{p}  obj:\n" + dump_ast(node.obj, indent + 2)
    s += "#{p}  const:\n" + dump_ast(node.const, indent + 2)
    s
  when Iyi::RespondsTo
    s = "#{p}RespondsTo name=#{escape_s(node.name)}\n"
    s += "#{p}  obj:\n" + dump_ast(node.obj, indent + 2)
    s
  when Iyi::ReadInstanceVar
    s = "#{p}ReadInstanceVar name=#{escape_s(node.name)}\n"
    s += "#{p}  obj:\n" + dump_ast(node.obj, indent + 2)
    s
  when Iyi::TypeOf
    s = "#{p}TypeOf\n"
    node.expressions.each { |e| s += dump_ast(e, indent + 1) }
    s
  when Iyi::PointerOf
    "#{p}PointerOf\n" + dump_ast(node.exp, indent + 1)
  when Iyi::SizeOf
    "#{p}SizeOf\n" + dump_ast(node.exp, indent + 1)
  when Iyi::InstanceSizeOf
    "#{p}InstanceSizeOf\n" + dump_ast(node.exp, indent + 1)
  when Iyi::AlignOf
    "#{p}AlignOf\n" + dump_ast(node.exp, indent + 1)
  when Iyi::InstanceAlignOf
    "#{p}InstanceAlignOf\n" + dump_ast(node.exp, indent + 1)
  when Iyi::Out
    "#{p}Out\n" + dump_ast(node.exp, indent + 1)
  when Iyi::Propagate
    "#{p}Propagate\n" + dump_ast(node.exp, indent + 1)
  when Iyi::Defer
    "#{p}Defer\n" + dump_ast(node.exp, indent + 1)
  when Iyi::Recover
    s = "#{p}Recover\n"
    s += "#{p}  exp:\n" + dump_ast(node.exp, indent + 2)
    s += "#{p}  default:\n" + dump_ast(node.default, indent + 2)
    s
  when Iyi::OffsetOf
    s = "#{p}OffsetOf\n"
    s += "#{p}  offsetof_type:\n" + dump_ast(node.offsetof_type, indent + 2)
    s += "#{p}  offset:\n" + dump_ast(node.offset, indent + 2)
    s
  when Iyi::Require
    "#{p}Require string=#{escape_s(node.string)}\n"
  when Iyi::Select
    s = "#{p}Select\n"
    s += "#{p}  whens:\n"
    node.whens.each { |w| s += dump_ast(w, indent + 2) }
    if el = node.else
      s += "#{p}  else:\n" + dump_ast(el, indent + 2)
    end
    s
  when Iyi::ExceptionHandler
    s = "#{p}ExceptionHandler implicit=#{node.implicit} suffix=#{node.suffix}\n"
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    if rescues = node.rescues
      s += "#{p}  rescues:\n"
      rescues.each { |r| s += dump_ast(r, indent + 2) }
    end
    if el = node.else
      s += "#{p}  else:\n" + dump_ast(el, indent + 2)
    end
    if en = node.ensure
      s += "#{p}  ensure:\n" + dump_ast(en, indent + 2)
    end
    s
  when Iyi::Rescue
    s = "#{p}Rescue name=#{(n = node.name) ? escape_s(n) : "nil"}\n"
    if types = node.types
      s += "#{p}  types:\n"
      types.each { |t| s += dump_ast(t, indent + 2) }
    end
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::ProcLiteral
    "#{p}ProcLiteral\n" + dump_ast(node.def, indent + 1)
  when Iyi::ProcPointer
    s = "#{p}ProcPointer name=#{escape_s(node.name)} global=#{node.global?}\n"
    if o = node.obj
      s += "#{p}  obj:\n" + dump_ast(o, indent + 2)
    end
    if !node.args.empty?
      s += "#{p}  args:\n"
      node.args.each { |a| s += dump_ast(a, indent + 2) }
    end
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
parser = Iyi::Parser.new(src)
parser.filename = filename
node = parser.parse

if ARGV.size > 1 && ARGV[1] == "--count"
  c = Counter.new
  node.accept(c)
  puts c.count
else
  print dump_ast(node)
end
HOSTED_GOLDEN_SCRIPT

CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -o "$WORK_NATIVE/dump_hosted$EXE" "$WORK_NATIVE/dump_hosted_ast.cr"

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
  "$REPO"/bench/fixtures/expr_asm.iyi \
  "$REPO"/bench/fixtures/expr_select.iyi \
  "$REPO"/bench/fixtures/decl_classes_and_structs.iyi \
  "$REPO"/bench/fixtures/decl_getter_type_leak.iyi \
  "$REPO"/bench/fixtures/decl_def.iyi \
  "$REPO"/bench/fixtures/decl_enums.iyi \
  "$REPO"/bench/fixtures/decl_lib_and_fun.iyi \
  "$REPO"/bench/fixtures/decl_modules_and_inclusion.iyi \
  "$REPO"/bench/fixtures/decl_operators.iyi \
  "$REPO"/bench/fixtures/decl_traits_and_impls.iyi \
  "$REPO"/bench/fixtures/decl_types_and_vars.iyi \
  "$REPO"/bench/fixtures/decl_visibility_and_annotations.iyi \
  "$REPO"/bench/fixtures/syntax_macro_control_grammar.iyi \
  "$REPO"/bench/fixtures/syntax_string_concat_and_magic.iyi \
  "$REPO"/bench/fixtures/syntax_macro_text_splits.iyi \
  "$REPO"/bench/fixtures/syntax_macro_keywords_and_escapes.iyi \
  "$REPO"/bench/fixtures/syntax_proc_literals.iyi \
  "$REPO"/bench/fixtures/syntax_proc_pointers.iyi \
  "$REPO"/bench/fixtures/syntax_scope_locals.iyi \
  "$REPO"/bench/fixtures/syntax_index_tuples_and_keyword_names.iyi \
  "$REPO"/bench/fixtures/syntax_control_keyword_names.iyi \
  "$REPO"/bench/fixtures/syntax_type_list_then_call.iyi \
  "$REPO"/bench/fixtures/syntax_heredoc_command_and_folds.iyi \
  "$REPO"/bench/fixtures/syntax_block_unpacks.iyi \
  "$REPO"/bench/fixtures/syntax_named_forward_block.iyi \
  "$REPO"/bench/fixtures/syntax_call_spans.iyi \
  "$REPO"/bench/fixtures/syntax_begin_shorthand_and_comma_lines.iyi; do
  fixture_name="${fixture#"$REPO/"}"
  fixture_native="$(native_path "$fixture")"
  "$WORK/exercise-plain$EXE" "$fixture_native" > "$WORK/iyi.ast"
  "$WORK/dump_hosted$EXE" "$fixture_native" > "$WORK/hosted.ast"

  if ! cmp -s "$WORK/iyi.ast" "$WORK/hosted.ast"; then
    echo "  $fixture_name: MISMATCH"
    diff -u "$WORK/hosted.ast" "$WORK/iyi.ast" | head -20
    diverged=$((diverged + 1))
    status=1
  else
    nodes_count=$("$WORK/dump_hosted$EXE" "$fixture_native" --count)
    echo "  $fixture_name: identical ($nodes_count normalized nodes match hosted frontend)"
    total_matched_nodes=$((total_matched_nodes + nodes_count))
  fi
  fixture_count=$((fixture_count + 1))
done

echo "  Parity summary: $((fixture_count - diverged))/$fixture_count syntax fixtures match ($total_matched_nodes total nodes)"

echo "== Unspaced sign and regex forms after a local, against the hosted parser"
# Written here, not kept as a fixture: the repository's format check rewrites `x -1` as `x - 1` in every tracked
# .iyi file, which would take away the form under test.
cat > "$WORK/unspaced_forms.iyi" <<'UNSPACED_FORMS'
x = 1
minus = x -1
divided = x /2
number_minus = 1 -1
UNSPACED_FORMS
# check_unspaced_forms EXERCISE: succeeds when the exercise's tree for the input equals the hosted tree.
check_unspaced_forms() {
  if ! "$1" "$WORK_NATIVE/unspaced_forms.iyi" > "$WORK/unspaced_port.ast" 2> "$WORK/unspaced_port.err"; then
    return 1
  fi
  "$WORK/dump_hosted$EXE" "$WORK_NATIVE/unspaced_forms.iyi" > "$WORK/unspaced_hosted.ast"
  cmp -s "$WORK/unspaced_port.ast" "$WORK/unspaced_hosted.ast"
}
if check_unspaced_forms "$WORK/exercise-plain$EXE"; then
  echo "  unspaced sign and regex forms match the hosted parser"
else
  echo "  unspaced sign and regex forms differ from the hosted parser"
  cat "$WORK/unspaced_port.err"
  status=1
fi

echo "== Require and empty-array locations against the hosted parser"
cat > "$WORK/require_locations.iyi" <<'IYI_LOCATIONS'
import compiler/syntax/ast::{ASTNode, ArrayLiteral, Require}
import compiler/syntax/parser::{Parser}
import compiler/syntax/visitor::{Visitor}
class RequireLocations < Visitor
  def visit(node : Require) : Bool
    if loc = node.location
      puts "#{loc.line_number}:#{loc.column_number}"
    else
      puts "missing"
    end
    false
  end
  def visit(node : ArrayLiteral) : Bool
    if loc = node.location
      puts "#{loc.line_number}:#{loc.column_number}"
    else
      puts "missing"
    end
    false
  end
end
node = Parser.new(File.read(Program.args[0]), Program.args[0]).parse
node.accept(RequireLocations.new)
IYI_LOCATIONS
cat > "$WORK/require_locations.cr" <<'HOSTED_LOCATIONS'
require "compiler/iyi/syntax"
class RequireLocations < Iyi::Visitor
  def visit(node)
    true
  end
  def visit(node : Iyi::Require)
    if loc = node.location
      puts "#{loc.line_number}:#{loc.column_number}"
    else
      puts "missing"
    end
    false
  end
  def visit(node : Iyi::ArrayLiteral)
    if loc = node.location
      puts "#{loc.line_number}:#{loc.column_number}"
    else
      puts "missing"
    end
    false
  end
end
parser = Iyi::Parser.new(File.read(ARGV[0]))
parser.filename = ARGV[0]
parser.parse.accept(RequireLocations.new)
HOSTED_LOCATIONS
# The input is written here rather than kept as a fixture. Its second and third lines are
# indented on purpose, so that the expected columns are not 1, and the repository's format
# check straightens every tracked .iyi file.
cat > "$WORK/require_input.iyi" <<'REQUIRE_INPUT'
require "./first"
  require "./second"
  [] of Int32
REQUIRE_INPUT
CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -o "$WORK_NATIVE/require_hosted$EXE" "$WORK_NATIVE/require_locations.cr"
"$WORK/require_hosted$EXE" "$WORK_NATIVE/require_input.iyi" > "$WORK/require_hosted.out"
printf '1:1\n2:3\n3:3\n' > "$WORK/require_expected.out"
if ! cmp -s "$WORK/require_expected.out" "$WORK/require_hosted.out"; then
  echo "  hosted require locations differ from the expected 1:1, 2:3, 3:3"
  status=1
fi
check_require_locations() {
  if ! "$IYI" build -o "$WORK_NATIVE/require_port$EXE" "$WORK_NATIVE/require_locations.iyi" > "$WORK/require_build.log" 2>&1; then
    invalid_mutant "require location probe did not build"
    return $?
  fi
  if ! "$WORK/require_port$EXE" "$WORK_NATIVE/require_input.iyi" > "$WORK/require_port.out"; then
    invalid_mutant "require location probe did not run"
    return $?
  fi
  cmp -s "$WORK/require_hosted.out" "$WORK/require_port.out"
}
if ! check_require_locations; then
  echo "  port require locations differ from hosted parser"
  status=1
fi
prove_mutation "require loses its source location" "$PARSER" \
  'node = Require.new(literal.as(StringLiteral).value).at(location)' \
  'node = Require.new(literal.as(StringLiteral).value)' -- check_require_locations || status=1
prove_mutation "empty array loses its source location" "$PARSER" \
  'ArrayLiteral.new([] of ASTNode, of_type).at(location)' \
  'ArrayLiteral.new([] of ASTNode, of_type)' -- check_require_locations || status=1

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
  if "$WORK/exercise-plain$EXE" -e "$bad" > "$WORK/invalid-expr.log" 2>&1; then
    echo "  FAILED TO REJECT: $bad"
    status=1
  elif grep -qF "Syntax error" "$WORK/invalid-expr.log"; then
    echo "  properly rejected: $bad"
  else
    echo "  ERROR: invalid expression failed without a parser syntax error: $bad"
    cat "$WORK/invalid-expr.log"
    status=1
  fi
done

echo "== Block parameter rejection parity"
for bad in \
  'f { |(x, x)| x }' \
  'f { |x, (y, x)| x }' \
  'f { |*x, *y| x }' \
  'f { |(x, *y, *z)| x }' \
  'f { |(x, (y, *z, *w))| x }' \
  'f { |(x, 1)| x }' \
  'f { |(x, if)| x }'; do
  printf '%s\n' "$bad" > "$WORK/invalid-block.iyi"
  if "$WORK/exercise-plain$EXE" "$WORK_NATIVE/invalid-block.iyi" > "$WORK/invalid-block-port.log" 2>&1; then
    echo "  native accepted invalid: $bad"
    status=1
  elif ! grep -qF "Syntax error" "$WORK/invalid-block-port.log"; then
    echo "  native failed without a parser syntax error: $bad"
    cat "$WORK/invalid-block-port.log"
    status=1
  elif "$WORK/dump_hosted$EXE" "$WORK_NATIVE/invalid-block.iyi" > "$WORK/invalid-block-hosted.log" 2>&1; then
    echo "  hosted accepted invalid: $bad"
    status=1
  elif ! grep -qF "Iyi::SyntaxException" "$WORK/invalid-block-hosted.log"; then
    echo "  hosted failed without a parser syntax exception: $bad"
    cat "$WORK/invalid-block-hosted.log"
    status=1
  else
    echo "  both rejected: $bad"
  fi
done

echo "== Named and forwarded block argument rejection parity"
for bad in \
  'f(value: 1, &handler, 2)' \
  'f(value: 1, &handler, extra: 2)'; do
  printf '%s\n' "$bad" > "$WORK/invalid-named-forward.iyi"
  if "$WORK/exercise-plain$EXE" "$WORK_NATIVE/invalid-named-forward.iyi" > "$WORK/invalid-named-port.log" 2>&1; then
    echo "  native accepted invalid: $bad"
    status=1
  elif ! grep -qF "Syntax error" "$WORK/invalid-named-port.log"; then
    echo "  native failed without a parser syntax error: $bad"
    cat "$WORK/invalid-named-port.log"
    status=1
  elif "$WORK/dump_hosted$EXE" "$WORK_NATIVE/invalid-named-forward.iyi" > "$WORK/invalid-named-hosted.log" 2>&1; then
    echo "  hosted accepted invalid: $bad"
    status=1
  elif ! grep -qF "Iyi::SyntaxException" "$WORK/invalid-named-hosted.log"; then
    echo "  hosted failed without a parser syntax exception: $bad"
    cat "$WORK/invalid-named-hosted.log"
    status=1
  else
    echo "  both rejected: $bad"
  fi
done

echo "== Proc pointer rejection parity"
# Each source is refused by both parsers. The mutation proofs below run the same list.
proc_pointer_refusals=(
  '->x.foo'
  $'x = 1\n->::x.foo'
  '->::@x.foo'
  '->::@@x.foo'
  '->@x.foo.bar'
  '->foo()'
  '->:Int32 { 1 }'
  '->1'
  '->Foo.'
  '->@x'
  '->Foo'
  $'x = 1\ndef foo\n  ->x.bar\nend'
)
for bad in "${proc_pointer_refusals[@]}"; do
  printf '%s\n' "$bad" > "$WORK/invalid-pointer.iyi"
  if "$WORK/exercise-plain$EXE" "$WORK_NATIVE/invalid-pointer.iyi" > "$WORK/invalid-pointer-port.log" 2>&1; then
    echo "  native accepted invalid: $bad"
    status=1
  elif ! grep -qF "Syntax error" "$WORK/invalid-pointer-port.log"; then
    echo "  native failed without a parser syntax error: $bad"
    cat "$WORK/invalid-pointer-port.log"
    status=1
  elif "$WORK/dump_hosted$EXE" "$WORK_NATIVE/invalid-pointer.iyi" > "$WORK/invalid-pointer-hosted.log" 2>&1; then
    echo "  hosted accepted invalid: $bad"
    status=1
  elif ! grep -qF "Iyi::SyntaxException" "$WORK/invalid-pointer-hosted.log"; then
    echo "  hosted failed without a parser syntax exception: $bad"
    cat "$WORK/invalid-pointer-hosted.log"
    status=1
  else
    echo "  both rejected: $bad"
  fi
done

# A check for the refusal mutations: a mutant that accepts a refused source is caught.
proc_pointer_refusals_hold() {
  local bad
  if ! build_mutant_exercise; then
    invalid_mutant "parser exercise failed to build"
    return $?
  fi
  for bad in "${proc_pointer_refusals[@]}"; do
    printf '%s\n' "$bad" > "$WORK/mut-pointer.iyi"
    if "$WORK/mut-exercise$EXE" "$WORK_NATIVE/mut-pointer.iyi" > "$WORK/mut-pointer.log" 2>&1; then
      return 1
    fi
    if ! grep -qF "Syntax error" "$WORK/mut-pointer.log"; then
      invalid_mutant "a refused pointer failed without a syntax error: $bad"
      return $?
    fi
  done
  return 0
}

echo "== Variable scope refusal parity"
scope_refusals=(
  'x = x'
  'x += 1'
  '::x = 1'
)
for bad in "${scope_refusals[@]}"; do
  printf '%s\n' "$bad" > "$WORK/invalid-scope.iyi"
  if "$WORK/exercise-plain$EXE" "$WORK_NATIVE/invalid-scope.iyi" > "$WORK/invalid-scope-port.log" 2>&1; then
    echo "  native accepted invalid: $bad"
    status=1
  elif ! grep -qF "Syntax error" "$WORK/invalid-scope-port.log"; then
    echo "  native failed without a parser syntax error: $bad"
    cat "$WORK/invalid-scope-port.log"
    status=1
  elif "$WORK/dump_hosted$EXE" "$WORK_NATIVE/invalid-scope.iyi" > "$WORK/invalid-scope-hosted.log" 2>&1; then
    echo "  hosted accepted invalid: $bad"
    status=1
  elif ! grep -qF "Iyi::SyntaxException" "$WORK/invalid-scope-hosted.log"; then
    echo "  hosted failed without a parser syntax exception: $bad"
    cat "$WORK/invalid-scope-hosted.log"
    status=1
  else
    echo "  both rejected: $bad"
  fi
done

echo
echo "== 5. Guarded mutation proofs (verify patch applies, exercise fails, revert passes)"

# The mutation helper treats a nonzero check as caught, so invalid builds and
# oracle failures must return success during a mutation and fail the proof.
invalid_mutant() {
  echo "INVALID MUTANT: $*"
  [ "${_PM_ARMED:-0}" = 1 ]
}

build_mutant_exercise() {
  rm -f "$WORK/mut-exercise$EXE"
  if "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_parser_exercise.iyi" > "$WORK/mut-build.log" 2>&1 &&
     [ -x "$WORK/mut-exercise$EXE" ]; then
    return 0
  fi
  cat "$WORK/mut-build.log"
  return 1
}

check_parser_exercise() {
  if ! build_mutant_exercise; then
    invalid_mutant "parser exercise failed to build"
    return $?
  fi
  if "$WORK/mut-exercise$EXE" > "$WORK/mut-run.log" 2>&1; then
    return 0
  fi
  if grep -qE 'Assertion failed:|Syntax error' "$WORK/mut-run.log"; then
    return 1
  fi
  cat "$WORK/mut-run.log"
  invalid_mutant "parser exercise failed without an assertion or syntax error"
}

run_proof() {
  prove_mutation "$1" "$PARSER" "$2" "$3" -- check_parser_exercise || status=1
}

named_forward_syntax_matches() {
  local rc
  if ! build_mutant_exercise; then
    invalid_mutant "parser exercise failed to build"
    return $?
  fi
  if ! "$WORK/dump_hosted$EXE" "$REPO_NATIVE/bench/fixtures/syntax_named_forward_block.iyi" > "$WORK/named_forward.hosted"; then
    invalid_mutant "hosted parser failed on the named-forward fixture"
    return $?
  fi
  if ! "$WORK/mut-exercise$EXE" "$REPO_NATIVE/bench/fixtures/syntax_named_forward_block.iyi" > "$WORK/named_forward.port" 2> "$WORK/named_forward.err"; then
    if grep -qF "Syntax error" "$WORK/named_forward.err"; then return 1; fi
    cat "$WORK/named_forward.err"
    invalid_mutant "parser exercise failed without a syntax error"
    return $?
  fi
  if diff -u "$WORK/named_forward.hosted" "$WORK/named_forward.port"; then
    return 0
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then return 1; fi
    invalid_mutant "could not compare named-forward ASTs"
    return $?
  fi
}
named_forward_syntax_matches || status=1
prove_mutation "parenthesized named arguments cannot precede a forwarded block" "$PARSER" \
  '          # Hosted parse_call_args_named_args permits a trailing &block.
          next if @token.type == TokenKind::OP_AMP' \
  '          # Hosted parse_call_args_named_args permits a trailing &block.
          nil' -- named_forward_syntax_matches || status=1
prove_mutation "unparenthesized named arguments cannot precede a forwarded block" "$PARSER" \
  '        # The unparenthesized form permits the same trailing &block.
        next if @token.type == TokenKind::OP_AMP' \
  '        # The unparenthesized form permits the same trailing &block.
        nil' -- named_forward_syntax_matches || status=1

# Mutation 1: break operator precedence in parse_add_or_sub
run_proof "mutation 1: altering operator precedence in parse_add_or_sub" \
  'left = parse_mul_or_div' 'left = parse_prefix'

run_proof_all() {
  prove_mutation_all "$1" "$PARSER" "$2" "$3" -- check_parser_exercise || status=1
}

# Mutation 2: break operator right-associativity in parse_pow. The original sed
# replaced every `right = parse_pow`, the parse_mul_or_div site and the parse_pow
# site alike, so every occurrence is replaced here too.
run_proof_all "mutation 2: altering operator right-associativity in parse_pow" \
  'right = parse_pow' 'right = parse_prefix'

# Mutation 3: break block recognition. The original sed replaced all four
# `if @token.keyword == Keyword::DO` checks, and so does this proof.
run_proof_all "mutation 3: altering block recognition in parse_block" \
  'if @token.keyword == Keyword::DO' 'if false && @token.keyword == Keyword::DO'

# Mutation 4: break modifier form recognition
run_proof "mutation 4: altering modifier if form recognition" \
  'If.new(exp, res, Nop.new)' 'Unless.new(exp, res, Nop.new)'

# Mutation 5: remove the splat wrapper without matching DoubleSplat's suffix.
run_proof "mutation 5: altering splat argument parsing in parse_call_arg" \
  '      Splat.new(parse_op_assign_no_control).at(location)' '      parse_op_assign_no_control'

# Mutation 6: break return type parsing in parse_def_helper
run_proof "mutation 6: altering return type parsing in parse_def_helper" \
  'end_location = return_type.end_location' 'return_type = nil; end_location = nil'

# Mutation 7: break superclass parsing in parse_class_def
run_proof "mutation 7: altering superclass parsing in parse_class_def" \
  'superclass = parse_generic(false, @token.location, false)' 'superclass = nil'

# Mutation 8: break enum member value parsing in parse_enum_body_expressions
run_proof "mutation 8: altering enum member value parsing in parse_enum_body_expressions" \
  'constant_value = parse_logical_or' 'constant_value = nil'

# Mutation 9: break trait implementation target parsing in parse_impl_def
run_proof "mutation 9: altering trait implementation target parsing in parse_impl_def" \
  'target = parse_path(false, @token.location)' 'target = parse_path(true, @token.location)'

# Mutation 10: break adjacent string concatenation across backslash-newline
run_proof "mutation 10: altering adjacent string concatenation in parse_delimiter" \
  'if want_skip_space && delimiter_state.kind == DelimiterKind::STRING' 'if false && want_skip_space'

# Mutation 11: break magic constant parsing in parse_param
run_proof "mutation 11: altering magic constant default value parsing in parse_param" \
  'if @token.type.magic?' 'if false && @token.type.magic?'

# Mutation 12: declare a name from a type declaration that is a call argument
# (`getter name : String`), which the oracle does not. The leaked name then parses as Var.
run_proof "mutation 12: pushing a call-argument type declaration as a local variable" \
  'push_var(type_declaration) unless @call_args_start_locations.includes?(name_location)' \
  'push_var(type_declaration) unless false && @call_args_start_locations.includes?(name_location)'

# Mutation 13: read the volatile option from the alignstack flag. The asm check
# reads `volatile` back, so a parser that mixed the options up fails.
run_proof "mutation 13: mixing up the asm volatile and alignstack options" \
  'options.includes?("volatile"),' 'options.includes?("alignstack"),'

# Mutation 14: refuse the assignment form of a select `when`. The select check
# reads an assignment back, so a parser that refuses it fails.
run_proof "mutation 14: refusing the assignment form of a select when" \
  'if node.is_a?(Assign)' 'if false && node.is_a?(Assign)'

# Mutations 15-27: each fixed rule of this slice, reverted in the file that holds it.
# The exercise run above checks only its own assertions, not the tree, so a fixture
# proof checks the rebuilt exercise's tree against the hosted parser's, for the new fixtures.
new_fixtures_match() {
  local fixture fixture_native rc
  if ! build_mutant_exercise; then
    invalid_mutant "parser exercise failed to build"
    return $?
  fi
  for fixture in \
    "$REPO"/bench/fixtures/syntax_macro_text_splits.iyi \
    "$REPO"/bench/fixtures/syntax_macro_keywords_and_escapes.iyi \
    "$REPO"/bench/fixtures/syntax_proc_literals.iyi \
    "$REPO"/bench/fixtures/syntax_proc_pointers.iyi \
    "$REPO"/bench/fixtures/syntax_scope_locals.iyi \
    "$REPO"/bench/fixtures/syntax_index_tuples_and_keyword_names.iyi \
    "$REPO"/bench/fixtures/syntax_type_list_then_call.iyi \
    "$REPO"/bench/fixtures/syntax_control_keyword_names.iyi \
    "$REPO"/bench/fixtures/syntax_heredoc_command_and_folds.iyi \
    "$REPO"/bench/fixtures/syntax_call_spans.iyi \
    "$REPO"/bench/fixtures/syntax_begin_shorthand_and_comma_lines.iyi; do
    if ! fixture_native="$(native_path "$fixture")"; then
      invalid_mutant "could not convert fixture path: $fixture"
      return $?
    fi
    if ! "$WORK/dump_hosted$EXE" "$fixture_native" > "$WORK/mut_cr.ast" 2> "$WORK/mut-hosted.err"; then
      cat "$WORK/mut-hosted.err"
      invalid_mutant "hosted parser failed on fixture: $fixture"
      return $?
    fi
    if ! "$WORK/mut-exercise$EXE" "$fixture_native" > "$WORK/mut.ast" 2> "$WORK/mut-port.err"; then
      if grep -qF "Syntax error" "$WORK/mut-port.err"; then return 1; fi
      cat "$WORK/mut-port.err"
      invalid_mutant "parser exercise failed without a syntax error: $fixture"
      return $?
    fi
    if cmp -s "$WORK/mut.ast" "$WORK/mut_cr.ast"; then
      continue
    else
      rc=$?
      if [ "$rc" -eq 1 ]; then return 1; fi
      invalid_mutant "could not compare fixture ASTs: $fixture"
      return $?
    fi
  done
  return 0
}
run_proof_in() {
  prove_mutation "$1" "$2" "$3" "$4" -- new_fixtures_match || status=1
}

LEXER="$REPO/src/compiler/syntax/lexer.iyi"
run_proof_in "mutation 15: no string state push for a #{ interpolation in macro text" "$LEXER" \
  $'if peek_next_char == \'{\'\n            char = next_char\n            @macro_curly_count' \
  $'if false && peek_next_char == \'{\'\n            char = next_char\n            @macro_curly_count'
run_proof_in "mutation 16: iyi impl no longer opens a macro block" "$LEXER" \
  "if @iyi && char_sequence?('p', 'l')" "if false && char_sequence?('p', 'l')"
run_proof_in "mutation 17: iyi end! no longer closes a macro block" "$LEXER" \
  "if whitespace && (!ident_part_or_end?(peek_next_char) || (@iyi && peek_next_char == '!'))" \
  "if whitespace && (!ident_part_or_end?(peek_next_char) || false)"
PARSER="$REPO/src/compiler/syntax/parser.iyi"
run_proof_in "mutation 18: -> is not a call argument start" "$PARSER" \
  "TokenKind::OP_TILDE, TokenKind::UNDERSCORE, TokenKind::OP_MINUS_GT" "TokenKind::OP_TILDE, TokenKind::UNDERSCORE"
run_proof_in "mutation 19: index arguments refuse a tuple literal" "$PARSER" \
  "parse_call_args_space_consumed(true, true, true)" "parse_call_args_space_consumed(false, true)"
run_proof_in "mutation 20: a keyword name followed by a colon is refused in call arguments" "$PARSER" \
  "        return nil unless next_comes_colon_space?" "        return nil"
run_proof_in "mutation 21: a constant always starts a type in a bare proc type list" "$PARSER" \
  $'      type_path_start?\n    when TokenKind::OP_COLON_COLON' $'      true\n    when TokenKind::OP_COLON_COLON'
run_proof_in "mutation 22: a literal interpolation is not folded into the string" "$PARSER" \
  "if interp_exp.is_a?(StringLiteral) && delimiter_state.kind != DelimiterKind::HEREDOC" \
  "if false && interp_exp.is_a?(StringLiteral) && delimiter_state.kind != DelimiterKind::HEREDOC"
run_proof_in "mutation 23: a command literal is not a backtick call" "$PARSER" \
  "    return node unless kind == DelimiterKind::COMMAND" "    return node"
run_proof_in "mutation 24: a heredoc is not read with its indent removed" "$PARSER" \
  $'if delimiter_state.kind == DelimiterKind::HEREDOC\n      return StringInterpolation' \
  $'if false && delimiter_state.kind == DelimiterKind::HEREDOC\n      return StringInterpolation'
run_proof_in "mutation 25: a begin block gets the paren keyword" "$PARSER" \
  "        body.keyword = Expressions::Keyword::Begin" "        body.keyword = Expressions::Keyword::Paren"
run_proof_in "mutation 26: &.name with a local of that name reads the local" "$PARSER" \
  "      if is_var && !call_only" "      if is_var"
run_proof_in "mutation 27: a comma does not continue a call across the line break" "$PARSER" \
  $'        next_token_skip_space_or_newline\n        if (@token.keyword == Keyword::END' \
  $'        next_token_skip_space\n        if (@token.keyword == Keyword::END'
run_proof_in "mutation 28: a control keyword before a colon is refused as a void value" "$PARSER" \
  'syntax_error("void value expression", @token.location) unless next_comes_colon_space?' \
  'syntax_error("void value expression", @token.location)'
run_proof_in "mutation 29: discard the closing call delimiter location" "$PARSER" \
  'CallArgs.new(args, block, block_arg, named_args, false, end_location, true)' \
  'CallArgs.new(args, block, block_arg, named_args, false, nil, true)'
run_proof_in "mutation 30: an opening parenthesis or brace after a type list starts a type" "$PARSER" \
  $'    while @token.type == TokenKind::OP_LPAREN || @token.type == TokenKind::OP_LCURLY\n      next_token_skip_space_or_newline\n    end\n' \
  $'    return true if @token.type == TokenKind::OP_LPAREN || @token.type == TokenKind::OP_LCURLY\n'
run_proof_in "mutation 31: self after a type list starts a type whatever follows it" "$PARSER" \
  $'        next_token_skip_space\n        delimiter_or_type_suffix?\n' \
  $'        true\n'
run_proof_in "mutation 32: a global path after a type list starts a type whatever follows it" "$PARSER" \
  $'    when TokenKind::OP_COLON_COLON\n      next_token\n      type_path_start?\n' \
  $'    when TokenKind::OP_COLON_COLON\n      true\n'

# Mutations 33-38: the proc pointer rules. The refused sources are run by the check
# proc_pointer_refusals_hold; the parser fixture trees by new_fixtures_match.
# Mutation 33: an arrow followed by an identifier goes back to the proc-literal path,
# which refuses it for want of `do` or `{`.
run_proof_in "mutation 33: an arrow followed by an identifier goes back to the proc-literal path" "$PARSER" \
  "      return parse_fun_pointer unless @token.keyword == Keyword::DO" \
  "      nil"
# Mutation 34: a proc pointer drops its argument type list, so the typed pointers lose their args.
run_proof_in "mutation 34: a proc pointer drops its argument type list" "$PARSER" \
  "    ProcPointer.new(obj, name, types, global_call).at_end(end_location)" \
  "    ProcPointer.new(obj, name, [] of ASTNode, global_call).at_end(end_location)"
# Mutation 35: a receiver that names no variable in scope is accepted.
prove_mutation "mutation 35: a proc pointer accepts an undefined variable as its receiver" "$PARSER" \
  '        if name != "self" && !@var_scopes.last.includes?(name)' \
  '        if false && name != "self" && !@var_scopes.last.includes?(name)' -- proc_pointer_refusals_hold || status=1
# Mutation 36: a global prefix on a local receiver is accepted.
prove_mutation "mutation 36: a proc pointer accepts a global prefix on a local receiver" "$PARSER" \
  '        syntax_error("ProcPointer of local variable cannot be global", location) if global' \
  '        nil' -- proc_pointer_refusals_hold || status=1
# Mutation 37: a setter name loses its equals sign, so `->reset=` names `reset`.
run_proof_in "mutation 37: a proc pointer setter loses its equals sign" "$PARSER" \
  $'        name = "#{name}="\n      elsif @token.type == TokenKind::OP_PERIOD' \
  $'        name = "#{name}"\n      elsif @token.type == TokenKind::OP_PERIOD'
# Mutation 38: a top-level proc pointer loses its global prefix.
run_proof_in "mutation 38: a top-level proc pointer loses its global flag" "$PARSER" \
  "      global_call = global" \
  "      global_call = false"

# A mutant of the variable scope rules is caught by the scope fixture, or by the unspaced forms against the hosted tree,
# or by a refused source that it accepts.
scope_refusals_hold() {
  local bad
  if ! build_mutant_exercise; then
    invalid_mutant "parser exercise failed to build"
    return $?
  fi
  for bad in "${scope_refusals[@]}"; do
    printf '%s\n' "$bad" > "$WORK/mut-scope.iyi"
    if "$WORK/mut-exercise$EXE" "$WORK_NATIVE/mut-scope.iyi" > "$WORK/mut-scope.log" 2>&1; then
      return 1
    fi
    if ! grep -qF "Syntax error" "$WORK/mut-scope.log"; then
      invalid_mutant "a refused variable form failed without a syntax error: $bad"
      return $?
    fi
  done
  return 0
}
unspaced_forms_hold() {
  if ! build_mutant_exercise; then
    invalid_mutant "parser exercise failed to build"
    return $?
  fi
  if check_unspaced_forms "$WORK/mut-exercise$EXE"; then
    return 0
  fi
  return 1
}
# Mutation 39: var? searches every enclosing scope, as it did before the innermost-scope rule.
run_proof_in "mutation 39: var? searches every enclosing scope, not only the innermost" "$PARSER" \
  "    var_in_scope?(name)" \
  $'    i = @var_scopes.size - 1\n    while i >= 0\n      return true if @var_scopes[i].includes?(name)\n      i = i - 1\n    end\n    false'
# Mutation 40: a proc literal is isolated, so an outer local inside it is a call.
run_proof_in "mutation 40: a proc literal is isolated, so an outer local is a call" "$PARSER" \
  $'    with_lexical_var_scope do\n      params.each' \
  $'    with_isolated_var_scope do\n      params.each'
# Mutation 41: a block is isolated, so an outer local inside it is a call.
run_proof_in "mutation 41: a block is isolated, so an outer local is a call" "$PARSER" \
  $'    body = with_lexical_var_scope do\n      all_names' \
  $'    body = with_isolated_var_scope do\n      all_names'
# Mutation 42: a constant's value shares the enclosing scope.
run_proof_in "mutation 42: a constant's value parses in the enclosing scope" "$PARSER" \
  "            needs_new_scope = atomic.is_a?(Path) || (" \
  "            needs_new_scope = false || ("
# Mutation 43: a local followed by a plus or minus is a call, so `x -1` is a call with an argument.
prove_mutation "mutation 43: a local followed by a plus or minus is a call" "$PARSER" \
  "    if is_var && next_comes_plus_or_minus?" \
  "    if false && next_comes_plus_or_minus?" -- unspaced_forms_hold || status=1
# Mutation 44: a number that begins with a sign after an operand is not a binary operator.
prove_mutation "mutation 44: a signed number after an operand is not a binary operator" "$PARSER" \
  '        if sign == "+" || sign == "-"' \
  '        if false' -- unspaced_forms_hold || status=1
# Mutation 45: $~ and $? are globals even when an assignment follows them.
run_proof_in "mutation 45: \$~ and \$? are globals even when assigned" "$PARSER" \
  "      if next_comes_assign_after_space?" \
  "      if false"
# Mutation 46: typeof reads the enclosing locals as calls, as an isolated scope would.
run_proof_in "mutation 46: typeof reads the enclosing locals as calls" "$PARSER" \
  "    exps = with_lexical_var_scope do" \
  "    exps = with_isolated_var_scope do"
# Mutation 47: a name used inside its own assignment is accepted.
prove_mutation "mutation 47: a name used inside its own assignment is accepted" "$PARSER" \
  "        if !call_only && !global && @assigned_vars.includes?(name)" \
  "        if false" -- scope_refusals_hold || status=1
# Mutation 48: an operator assignment to a name that is not yet defined is accepted.
prove_mutation "mutation 48: an operator assignment to an undefined name is accepted" "$PARSER" \
  '          if atomic.is_a?(Call) && atomic.name != "[]" && !var_in_scope?(atomic.name)' \
  '          if atomic.is_a?(Call) && atomic.name != "[]" && false' -- scope_refusals_hold || status=1
# Mutation 49: a global name is assigned as a local.
prove_mutation "mutation 49: a ::name is assigned as a local" "$PARSER" \
  '    return unless atomic.is_a?(Call) && atomic.global && atomic.obj.nil? && atomic.args.empty?' \
  '    return' -- scope_refusals_hold || status=1
# Mutation 50: a local followed by a space reads / as a regex.
prove_mutation "mutation 50: a local followed by a space reads / as a regex" "$PARSER" \
  '      @wants_regex = !is_var' \
  '      @wants_regex = true' -- unspaced_forms_hold || status=1

echo
echo "== Rebuilding and running restored parser exercise"
"$IYI" build --release -o "$WORK_NATIVE/exercise-restored$EXE" "$REPO_NATIVE/bench/selfhost_parser_exercise.iyi"
"$WORK/exercise-restored$EXE" >/dev/null
echo "== Verification clean state confirmed"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST PARSER EXERCISE CHECKS PASSED!"
else
  echo "== SELFHOST PARSER EXERCISE CHECKS FAILED"
fi

exit $status
