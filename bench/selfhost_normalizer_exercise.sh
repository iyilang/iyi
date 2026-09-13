#!/usr/bin/env bash
# Fails when the iyi normalizer stops agreeing with the one it replaces.
#
# The port is only worth something if it rewrites a tree the same way the front
# end iyi is still bootstrapped from does. Every fixture is parsed and
# normalised twice, once by each implementation, dumped in one text form, and
# required byte-identical. A check that ran only the iyi side would pass for a
# normalizer that rewrote nothing at all.
#
# The mutation proofs follow the rule the other selfhost gates use: the patched
# file is compared against the original, and a patch that matched nothing is
# reported as proving nothing rather than passing quietly.
#
#   bash bench/selfhost_normalizer_exercise.sh
set -u
status=0
diverged=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
NORM="$REPO/src/compiler/semantic/normalizer.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. Building and running the normalizer exercise"
"$IYI" build -o "$WORK/exercise" "$REPO/bench/selfhost_normalizer_exercise.iyi"
"$WORK/exercise" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST NORMALIZER CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "  EXERCISE FAILED"
  status=1
fi

echo
echo "== 2. Normalised tree comparison against the front end being replaced"
cat <<'CRYSTAL_GOLDEN_SCRIPT' > "$WORK/dump_crystal_norm.cr"
# The oracle is the compiler being replaced, minus its command layer:
# requiring `compiler/iyi` would run the CLI and print nothing at all.
# `llvm` leads because the compiler reads LibLLVM version constants at
# macro-expansion time, and it is Crystal's own binding that defines them.
# `compiler/requires` is the graph the compiler itself loads, in its own
# order. Requiring the pieces by hand reopens classes before the files that
# declare them, and requiring `compiler/iyi` would run the CLI instead.
require "compiler/requires"

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
    s = "#{p}IsA\n"
    s += "#{p}  obj:\n" + dump_ast(node.obj, indent + 2)
    s += "#{p}  const:\n" + dump_ast(node.const, indent + 2)
    s
  when Iyi::RespondsTo
    s = "#{p}RespondsTo name=#{escape_s(node.name)}\n"
    s += "#{p}  obj:\n" + dump_ast(node.obj, indent + 2)
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
  when Iyi::ExceptionHandler
    s = "#{p}ExceptionHandler\n"
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    if rescues = node.rescues
      rescues.each do |r|
        s += "#{p}  rescue:\n"
        s += "#{p}    name=#{escape_s(r.name || "")}\n"
        if types = r.types
          s += "#{p}    types:\n"
          types.each { |t| s += dump_ast(t, indent + 3) }
        end
        s += "#{p}    body:\n" + dump_ast(r.body, indent + 3)
      end
    end
    if else_body = node.else
      s += "#{p}  else:\n" + dump_ast(else_body, indent + 2)
    end
    if ensure_body = node.ensure
      s += "#{p}  ensure:\n" + dump_ast(ensure_body, indent + 2)
    end
    s
  when Iyi::ProcLiteral
    s = "#{p}ProcLiteral\n"
    s += dump_ast(node.def, indent + 1)
    s
  when Iyi::Propagate
    s = "#{p}Propagate\n"
    s += dump_ast(node.exp, indent + 1)
    s
  when Iyi::Defer
    s = "#{p}Defer\n"
    s += dump_ast(node.exp, indent + 1)
    s
  when Iyi::Recover
    s = "#{p}Recover\n"
    s += "#{p}  exp:\n" + dump_ast(node.exp, indent + 2)
    if d = node.default
      s += "#{p}  default:\n" + dump_ast(d, indent + 2)
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
# The front end decides it is reading iyi from the filename, and that
# decision reaches the grammar: `group` is only a reserved name in an iyi
# file. A parser handed source with no filename reads Crystal, and would
# hand the normalizer a tree that never had a group in it.
parser = Iyi::Parser.new(src)
parser.filename = filename
node = parser.parse
node = Iyi::Program.new.normalize(node)

if ARGV.size > 1 && ARGV[1] == "--count"
  c = Counter.new
  node.accept(c)
  puts c.count
else
  print dump_ast(node)
end
CRYSTAL_GOLDEN_SCRIPT

# The oracle is the compiler being replaced, so it is built the way that
# compiler is: LLVM_CONFIG is what gives its LibLLVM its version constants.
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK/dump_crystal" "$WORK/dump_crystal_norm.cr"
if [ ! -x "$WORK/dump_crystal" ]; then
  # Without the oracle there is nothing to compare against, and every check
  # below would report a difference, or a catch, that means nothing at all.
  echo "  THE ORACLE DID NOT BUILD: this gate cannot conclude anything"
  exit 1
fi

# Every fixture, both implementations, byte for byte.
compare_all() {
  out_status=0
  for fixture in "$REPO"/bench/fixtures/norm_*.iyi; do
    "$1" "$fixture" > "$WORK/a.ast" 2>/dev/null || { out_status=1; continue; }
    IYI_PATH="$REPO/src" IYI_PATH="$REPO/src" "$WORK/dump_crystal" "$fixture" > "$WORK/b.ast"
    cmp -s "$WORK/a.ast" "$WORK/b.ast" || out_status=1
  done
  return $out_status
}

fixture_count=0
total_matched_nodes=0
for fixture in "$REPO"/bench/fixtures/norm_*.iyi; do
  fixture_name="bench/fixtures/$(basename "$fixture")"
  "$WORK/exercise" "$fixture" > "$WORK/iyi.ast"
  IYI_PATH="$REPO/src" "$WORK/dump_crystal" "$fixture" > "$WORK/crystal.ast"
  if ! cmp -s "$WORK/iyi.ast" "$WORK/crystal.ast"; then
    echo "  $fixture_name: NORMALISED TREES DIFFER"
    diverged=$((diverged + 1))
    diff -u "$WORK/crystal.ast" "$WORK/iyi.ast" | head -20
    status=1
  else
    nodes_count=$(IYI_PATH="$REPO/src" "$WORK/dump_crystal" "$fixture" --count)
    echo "  $fixture_name: identical ($nodes_count normalised nodes match the front end)"
    total_matched_nodes=$((total_matched_nodes + nodes_count))
  fi
  fixture_count=$((fixture_count + 1))
done
echo "  Parity summary: $((fixture_count - diverged))/$fixture_count fixtures normalise identically ($total_matched_nodes total nodes)"

echo
echo "== 3. Mutation proofs: each one must make the comparison above fail"

prove_mutation() {
  label="$1"
  old="$2"
  new="$3"
  echo "  [$label]"
  cp "$NORM" "$NORM.orig"
  python3 - "$NORM" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
if old not in t:
    sys.exit(3)
open(path, "w").write(t.replace(old, new, 1))
PY
  rc=$?
  if [ "$rc" -eq 3 ] || diff -q "$NORM.orig" "$NORM" >/dev/null; then
    echo "    PATCH CHANGED NOTHING: this proves nothing"
    status=1
    cp "$NORM.orig" "$NORM"; rm -f "$NORM.orig"
    return
  fi
  if "$IYI" build -o "$WORK/mut-exercise" "$REPO/bench/selfhost_normalizer_exercise.iyi" >/dev/null 2>&1; then
    if compare_all "$WORK/mut-exercise"; then
      echo "    FAILED: the comparison still passed with the mutation applied"
      status=1
    else
      echo "    caught: the normalised trees diverged, as they must"
    fi
  else
    echo "    caught: the mutated normalizer did not build"
  fi
  cp "$NORM.orig" "$NORM"; rm -f "$NORM.orig"
  echo "    reverted"
}

MUTATIONS_RUN=0
run_proof() {
  prove_mutation "$1" "$2" "$3"
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
}

run_proof "unless keeps its branches instead of swapping them"   "If.new(node.cond, node.else, node.then)"   "If.new(node.cond, node.then, node.else)"

run_proof "until loops on its condition instead of its negation"   "not_exp = Not.new(node.cond).at(node.cond)"   "not_exp = node.cond"

run_proof "defer stops becoming an exception handler"   "ExceptionHandler.new(Nop.new, nil, nil, node.exp.transform(self)).at(node)"   "node.exp.transform(self)"

run_proof "a chained comparison stops joining with and"   "and_node = And.new(left, right).at(left)"   "and_node = right"

run_proof "recover stops guarding on its check"   "value = If.new(check, recovery, temp_var.clone).at(node)"   "value = If.new(check, temp_var.clone, recovery).at(node)"


echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST NORMALIZER CHECKS PASSED"
else
  echo "== SELFHOST NORMALIZER CHECKS FAILED"
fi
exit $status
