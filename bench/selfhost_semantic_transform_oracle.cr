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
    else           res += s.byte_at(i).chr.to_s
    end
    i += 1
  end
  res + "\""
end

def names_text(names : Array(String)?) : String
  if n = names
    "[#{n.join(", ")}]"
  else
    "none"
  end
end

def dump_ast(node : Iyi::ASTNode?, indent : Int32 = 0) : String
  return ("  " * indent) + "nil\n" if node.nil?
  p = "  " * indent
  case node
  when Iyi::Expressions
    kw = case node.keyword
         when .none?  then "none"
         when .paren? then "paren"
         when .begin? then "begin"
         else              "none"
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
    s = "#{p}If ternary=#{node.ternary?} and=#{node.and?} or=#{node.or?} truthy=#{node.truthy?} falsey=#{node.falsey?}\n"
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
  when Iyi::Select
    s = "#{p}Select\n"
    node.whens.each { |w| s += dump_ast(w, indent + 1) }
    if el = node.else
      s += "#{p}  else:\n" + dump_ast(el, indent + 2)
    end
    s
  when Iyi::TypeOf
    s = "#{p}TypeOf\n"
    node.expressions.each { |e| s += dump_ast(e, indent + 1) }
    s
  when Iyi::PointerOf
    s = "#{p}PointerOf\n"
    s += dump_ast(node.exp, indent + 1)
    s
  when Iyi::ImportDecl
    "#{p}ImportDecl path=#{node.path.join("/")} exported=#{node.exported} glob=#{node.glob?} names=#{names_text(node.names)}\n"
  when Iyi::UsingDecl
    "#{p}UsingDecl path=#{node.path.join("/")} names=#{names_text(node.names)}\n"
  when Iyi::ModuleHeader
    "#{p}ModuleHeader path=#{node.path.join("/")}\n"
  when Iyi::MacroIf
    s = "#{p}MacroIf\n"
    s += "#{p}  cond:\n" + dump_ast(node.cond, indent + 2)
    s += "#{p}  then:\n" + dump_ast(node.then, indent + 2)
    s += "#{p}  else:\n" + dump_ast(node.else, indent + 2)
    s
  when Iyi::MacroFor
    s = "#{p}MacroFor\n"
    s += "#{p}  vars:\n"
    node.vars.each { |v| s += dump_ast(v, indent + 2) }
    s += "#{p}  exp:\n" + dump_ast(node.exp, indent + 2)
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::MagicConstant
    "#{p}MagicConstant name=#{node.name.to_s}\n"
  when Iyi::Require
    "#{p}Require string=#{escape_s(node.string)}\n"
  when Iyi::MacroExpression
    s = "#{p}MacroExpression output=#{node.output?}\n"
    s += dump_ast(node.exp, indent + 1)
    s
  when Iyi::Macro
    s = "#{p}Macro name=#{escape_s(node.name)}\n"
    s += "#{p}  args:\n"
    node.args.each { |a| s += dump_ast(a, indent + 2) }
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::SizeOf
    s = "#{p}SizeOf\n"
    s += dump_ast(node.exp, indent + 1)
    s
  when Iyi::ReadInstanceVar
    s = "#{p}ReadInstanceVar name=#{escape_s(node.name)}\n"
    s += "#{p}  obj:\n" + dump_ast(node.obj, indent + 2)
    s
  else
    STDERR.puts "UNCOVERED #{node.class.name}"
    "#{p}Node\n"
  end
end

class Counter < Iyi::Visitor
  getter count = 0

  def visit(node : Iyi::ASTNode) : Bool
    @count += 1
    true
  end
end

# The literal walk: the hosted expander lowers each literal when the walk
# reaches it, and the walk continues into the call it built, so a literal
# inside a lowered literal is lowered too. Range literals and string
# interpolations are lowered here so far.
class LiteralWalk < Iyi::Transformer
  def initialize(@program : Iyi::Program)
  end

  def transform(node : Iyi::RangeLiteral) : Iyi::ASTNode
    Iyi::LiteralExpander.new(@program).expand(node).transform(self)
  end

  def transform(node : Iyi::StringInterpolation) : Iyi::ASTNode
    Iyi::LiteralExpander.new(@program).expand(node).transform(self)
  end

  def transform(node : Iyi::ArrayLiteral) : Iyi::ASTNode
    expander = Iyi::LiteralExpander.new(@program)
    expanded = node.name ? expander.expand_named(node, nil) : expander.expand(node)
    expanded.transform(self)
  end

  def transform(node : Iyi::HashLiteral) : Iyi::ASTNode
    expander = Iyi::LiteralExpander.new(@program)
    expanded = node.name ? expander.expand_named(node, nil) : expander.expand(node)
    expanded.transform(self)
  end

  def transform(node : Iyi::Case) : Iyi::ASTNode
    Iyi::LiteralExpander.new(@program).expand(node).transform(self)
  end

  def transform(node : Iyi::MultiAssign) : Iyi::ASTNode
    Iyi::LiteralExpander.new(@program).expand(node).transform(self)
  end

  def transform(node : Iyi::Select) : Iyi::ASTNode
    Iyi::LiteralExpander.new(@program).expand(node).transform(self)
  end

  def transform(node : Iyi::And) : Iyi::ASTNode
    Iyi::LiteralExpander.new(@program).expand(node).transform(self)
  end

  def transform(node : Iyi::Or) : Iyi::ASTNode
    Iyi::LiteralExpander.new(@program).expand(node).transform(self)
  end
end

filename = ARGV[0]
src = File.read(filename)
parser = Iyi::Parser.new(src)
parser.filename = filename
node = parser.parse
node = Iyi::Program.new.normalize(node)

mode = ARGV.size > 1 ? ARGV[1] : ""
if mode == "literals" || mode == "literals-strict"
  walk_program = Iyi::Program.new
  walk_program.flags.add("strict_multi_assign") if mode == "literals-strict"
  node = node.transform(LiteralWalk.new(walk_program))
end

if mode == "cleanup"
  node = node.transform(Iyi::CleanupTransformer.new(Iyi::Program.new))
end

if ARGV.size > 1 && ARGV[1] == "--count"
  c = Counter.new
  node.accept(c)
  puts c.count
else
  print dump_ast(node)
end
