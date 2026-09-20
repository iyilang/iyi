# The oracle for the parser port: the current parser's AST, as a canonical
# S-expression a second implementation can be diffed against.
#
# A shape, not a dump of every field. Node kind, and the parts that carry
# meaning: a def's name, its argument names and restrictions, a call's name
# and receiver, a literal's value. Not locations, not the `var_scopes`
# bookkeeping, not the fields a later pass fills in - pinning those would make
# the port match an implementation rather than a language.
require "compiler/iyi/syntax"

def sexp(node : Iyi::ASTNode) : String
  case node
  when Iyi::Expressions
    "(exprs #{node.expressions.map { |e| sexp(e) }.join(" ")})"
  when Iyi::ModuleHeader
    "(module #{node.path.join("/")})"
  when Iyi::ModuleDef
    # The parser wraps a file's body in a ModuleDef named by its header. The
    # port has to produce the same nesting, not a flat list.
    "(moduledef #{sexp(node.name)} #{sexp(node.body)})"
  when Iyi::Def
    args = node.args.map { |a| sexp(a) }.join(" ")
    ret = node.return_type.try { |r| " -> #{sexp(r)}" } || ""
    "(def #{node.name} (args #{args})#{ret} #{sexp(node.body)})"
  when Iyi::Arg
    r = node.restriction.try { |x| " : #{sexp(x)}" } || ""
    "(arg #{node.name}#{r})"
  when Iyi::Call
    recv = node.obj.try { |o| "#{sexp(o)}." } || ""
    args = node.args.map { |a| sexp(a) }.join(" ")
    "(call #{recv}#{node.name}#{args.empty? ? "" : " " + args})"
  when Iyi::Assign
    "(assign #{sexp(node.target)} #{sexp(node.value)})"
  when Iyi::Var
    "(var #{node.name})"
  when Iyi::Path
    "(path #{node.names.join("::")})"
  when Iyi::ClassDef
    # `struct` and `class` are one node with a flag, and the flag decides
    # what the program means, so it is in the shape rather than beside it.
    kind = node.struct? ? "struct" : "class"
    vars = node.type_vars.try { |v| "(#{v.join(" ")})" } || ""
    sup = node.superclass.try { |s| " < #{sexp(s)}" } || ""
    "(#{kind} #{sexp(node.name)}#{vars}#{sup} #{sexp(node.body)})"
  when Iyi::TraitDef
    vars = node.type_vars.try { |v| "(#{v.join(" ")})" } || ""
    "(trait #{sexp(node.name)}#{vars} #{sexp(node.body)})"
  when Iyi::ImplDef
    # The trait, what it is implemented for, and the `forall` that
    # introduces the parameters: an impl is the three together.
    vars = node.type_vars.try { |v| " forall #{v.join(" ")}" } || ""
    "(impl #{sexp(node.trait)} for #{sexp(node.target)}#{vars} #{sexp(node.body)})"
  when Iyi::Generic
    args = node.type_vars.map { |a| sexp(a) }.join(" ")
    "(generic #{sexp(node.name)} #{args})"
  when Iyi::Include
    "(include #{sexp(node.name)})"
  when Iyi::Extend
    "(extend #{sexp(node.name)})"
  when Iyi::TypeDeclaration
    "(typedecl #{sexp(node.var)} : #{sexp(node.declared_type)})"
  when Iyi::InstanceVar
    "(ivar #{node.name})"
  when Iyi::Case
    # Exhaustive or not is the difference between `in` and `when`, and it
    # changes what the compiler checks, so it is in the shape.
    kind = node.exhaustive? ? "case-in" : "case"
    cond = node.cond.try { |c| sexp(c) } || "(nop)"
    arms = node.whens.map { |w| sexp(w) }.join(" ")
    els = node.else.try { |e| " else #{sexp(e)}" } || ""
    "(#{kind} #{cond} #{arms}#{els})"
  when Iyi::When
    conds = node.conds.map { |c| sexp(c) }.join(" ")
    "(when (#{conds}) #{sexp(node.body)})"
  when Iyi::EnumDef
    base = node.base_type.try { |b| " : #{sexp(b)}" } || ""
    members = node.members.map { |m| sexp(m) }.join(" ")
    "(enum #{sexp(node.name)}#{base} #{members})"
  when Iyi::Annotation
    "(annotation #{sexp(node.path)})"
  when Iyi::AssocTypeDecl
    # `type Elem = Int32` in a trait declares the requirement; the same
    # line in an impl answers it. Both are this node, and the value is
    # what tells them apart.
    node.value.try { |v| "(assoctype #{node.name} #{sexp(v)})" } || "(assoctype #{node.name})"
  when Iyi::If
    # The branches, not just the node. `(if)` on its own would let a port
    # that mis-read the condition agree with the oracle anyway.
    "(if #{sexp(node.cond)} #{sexp(node.then)} #{sexp(node.else)})"
  when Iyi::Unless
    "(unless #{sexp(node.cond)} #{sexp(node.then)} #{sexp(node.else)})"
  when Iyi::While
    "(while #{sexp(node.cond)} #{sexp(node.body)})"
  when Iyi::Return
    node.exp.try { |e| "(return #{sexp(e)})" } || "(return)"
  when Iyi::And
    "(and #{sexp(node.left)} #{sexp(node.right)})"
  when Iyi::Or
    "(or #{sexp(node.left)} #{sexp(node.right)})"
  when Iyi::Not
    "(not #{sexp(node.exp)})"
  when Iyi::BoolLiteral
    "(bool #{node.value})"
  when Iyi::NilLiteral
    "(nil)"
  when Iyi::NumberLiteral
    "(num #{node.value})"
  when Iyi::StringLiteral
    "(str #{node.value.inspect})"
  when Iyi::Nop
    "(nop)"
  else
    "(#{node.class.name.split("::").last.downcase})"
  end
end

path = ARGV[0]

# The filename, not just the source. `Lexer#filename=` is what turns iyi
# mode on (`@iyi = filename.ends_with?(".iyi")`), and without it the
# current parser reads an `.iyi` file as Crystal: `errors.iyi` died on the
# `!` that propagates, and every other file was being compared against a
# parse in the wrong language.
parser = Iyi::Parser.new(File.read(path))
parser.filename = path
puts sexp(parser.parse)
