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
node = Iyi::Parser.parse(File.read(path))
puts sexp(node)
