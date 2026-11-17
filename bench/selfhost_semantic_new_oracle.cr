# New-method oracle for bench/selfhost_semantic_new_exercise.sh.
#
#   selfhost_semantic_new_oracle <fixture.iyi>
#
# Analyses the fixture bare (no prelude) through the hosted top-level pass, the hosted
# new pass and the main pass, then prints, sorted, one line per generated or explicit
# `new` on a user class's metaclass and one per explicit `initialize`, then one line
# per `new` call written in the file, in tree order:
#
#   def <Type>.new(<arg names>) vis <v> body <node kinds>[ init(<args>)]
#   init <Type>#initialize(<arg names>) vis <v>
#   call <line>:<col> <receiver>.new(<arg types>) -> <result type> target <name>(<arg names>) targets <n>
#
# Node kinds are the names kind_text gives (anything else is Other). The port's driver
# (bench/selfhost_semantic_new_exercise.iyi) prints the same lines for the same fixture,
# and the gate requires them byte-identical. On failure the first line of the message
# goes to stderr and the exit status is 2.
require "compiler/requires"

class Iyi::Compiler
  # iyi: the bare analysis, as the typed oracle runs it, reached from outside the class
  # because `parse` and `new_program` are private to the compiler.
  def new_oracle_program(source : Iyi::Compiler::Source) : {Program, ASTNode}
    program = new_program([source])
    node = program.normalize(parse(program, source))
    node, processor = program.top_level_semantic(node)
    node = program.semantic_after_top_level(node, processor, cleanup: false)
    {program, node}
  end
end

def type_text(t : Iyi::Type?) : String
  return "nil" if t.nil?
  (t.is_a?(Iyi::NamedType) ? t.full_name : t.to_s).sub(/^::/, "")
end

# The kinds of node a generated body is described by. Other nodes print as Other.
def kind_text(node : Iyi::ASTNode) : String
  case node
  when Iyi::Assign      then "Assign"
  when Iyi::Call        then "Call"
  when Iyi::If          then "If"
  when Iyi::Var         then "Var"
  when Iyi::Nop         then "Nop"
  when Iyi::Expressions then "Expressions"
  when Iyi::Splat       then "Splat"
  when Iyi::DoubleSplat then "DoubleSplat"
  when Iyi::RespondsTo  then "RespondsTo"
  when Iyi::Path        then "Path"
  when Iyi::Generic     then "Generic"
  when Iyi::InstanceVar then "InstanceVar"
  when Iyi::Primitive   then "Primitive"
  else                       "Other"
  end
end

def body_text(body : Iyi::ASTNode) : String
  if body.is_a?(Iyi::Expressions)
    "[" + body.as(Iyi::Expressions).expressions.map { |e| kind_text(e) }.join(",") + "]"
  else
    kind_text(body)
  end
end

# One argument of an initialize call: a variable, or a splat of one.
def arg_text(node : Iyi::ASTNode) : String
  case node
  when Iyi::Var         then node.as(Iyi::Var).name
  when Iyi::Splat       then "*" + arg_text(node.as(Iyi::Splat).exp)
  when Iyi::DoubleSplat then "**" + arg_text(node.as(Iyi::DoubleSplat).exp)
  else                       kind_text(node)
  end
end

# The arguments of the initialize call a generated new makes (its second expression),
# positional first, then named, so the argument order is part of the record.
def init_text(body : Iyi::ASTNode) : String
  return "" unless body.is_a?(Iyi::Expressions)
  exps = body.as(Iyi::Expressions).expressions
  return "" if exps.size < 2
  c = exps[1]
  return "" unless c.is_a?(Iyi::Call)
  parts = c.as(Iyi::Call).args.map { |a| arg_text(a) }
  if named = c.as(Iyi::Call).named_args
    named.each do |na|
      parts << "#{na.name}:#{arg_text(na.value)}"
    end
  end
  " init(#{parts.join(",")})"
end

def vis_text(d : Iyi::Def) : String
  v = d.visibility
  return "protected" if v.protected?
  return "private" if v.private?
  "public"
end

# Collects the `new` calls written in the entry file, in tree order.
class NewCallWalk < Iyi::Visitor
  getter calls = [] of Iyi::Call

  def initialize(@absolute : String)
  end

  def visit_any(node)
    if node.is_a?(Iyi::Call) && node.as(Iyi::Call).name == "new"
      if (loc = node.location) && (name = loc.filename).is_a?(String) && File.expand_path(name) == @absolute
        @calls << node.as(Iyi::Call)
      end
    end
    true
  end

  def visit(node)
    true
  end
end

path = ARGV[0]? || abort("usage: selfhost_semantic_new_oracle <fixture.iyi>")
entry = File.expand_path(path)
buffer = IO::Memory.new
begin
  compiler = Iyi::Compiler.new
  compiler.prelude = "iyi/prelude"
  compiler.no_codegen = true
  compiler.stdout = IO::Memory.new
  compiler.stderr = IO::Memory.new
  initial = Iyi::Program.new.types.keys.to_set
  program, node = compiler.new_oracle_program(Iyi::Compiler::Source.new(entry, File.read(entry)))

  def_lines = [] of String
  program.types.each do |name, t|
    next if initial.includes?(name)
    next unless t.is_a?(Iyi::ModuleType) && t.is_a?(Iyi::ClassType)
    meta = t.metaclass
    if meta.is_a?(Iyi::ModuleType) && (list = meta.defs.try(&.["new"]?))
      list.each do |item|
        d = item.def
        arg_names = d.args.map(&.name).join(", ")
        def_lines << "def #{type_text(t)}.new(#{arg_names}) vis #{vis_text(d)} body #{body_text(d.body)}#{init_text(d.body)}"
      end
    end
    if inits = t.defs.try(&.["initialize"]?)
      inits.each do |item|
        d = item.def
        arg_names = d.args.map(&.name).join(", ")
        def_lines << "init #{type_text(t)}#initialize(#{arg_names}) vis #{vis_text(d)}"
      end
    end
  end
  def_lines.sort.each { |line| buffer << line << "\n" }

  walk = NewCallWalk.new(entry)
  node.accept(walk)
  walk.calls.each do |call|
    loc = call.location.not_nil!
    recv = call.obj
    recv_text = recv.is_a?(Iyi::Path) ? recv.as(Iyi::Path).names.join("::") : (recv.nil? ? "self" : kind_text(recv))
    arg_types = call.args.map { |a| type_text(a.type?) }.join(", ")
    targets = call.target_defs
    if targets && (first = targets.first?)
      target_text = "target #{first.name}(#{first.args.map(&.name).join(", ")}) targets #{targets.size}"
    else
      target_text = "target none"
    end
    buffer << "call #{loc.line_number}:#{loc.column_number} #{recv_text}.new(#{arg_types}) -> #{type_text(call.type?)} #{target_text}\n"
    if result_type = call.type?
      if result_type.is_a?(Iyi::GenericClassInstanceType) && result_type.type_vars.has_key?("T")
        resolved = result_type.lookup_type(Iyi::Path.new(["T"]))
        buffer << "lookup T on #{type_text(result_type)} -> #{type_text(resolved.as?(Iyi::Type))}\n"
      end
    end
  end
rescue ex : Exception
  STDERR.puts "ERROR: #{ex.message.to_s.lines.first? || ""}"
  exit 2
end
print buffer.to_s
