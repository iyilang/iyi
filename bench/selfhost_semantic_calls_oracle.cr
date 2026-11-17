# Call-lookup oracle for bench/selfhost_semantic_calls_exercise.sh.
#
#   selfhost_semantic_calls_oracle <fixture.iyi>
#
# Compiles the fixture the way a build compiles an entry file: the prelude, then
# the fixture, through the top-level pass and the main pass (as the typed oracle
# does). Then it evaluates each line of two kinds and prints one line for each:
#
#   # call <expr>   =>  <expr> => <matches> | none | error: <first line of the message>
#   # error <expr>  =>  <expr> => ok | error: <first line of the message>
#   # defining <expr> => <expr> => defining=<found-on> owner=<receiver>
#   # expand <call>  =>  <call> => <argument list> (the one match's arguments after default expansion)
# A call is `name(args)` (the program's own defs and the prelude's), `Type.name(args)`
# (the metaclass of a type: its class methods and the ones it inherits), or
# `<receiver call>.name(args)` (an instance: the receiver call must have exactly
# one match and a declared return type, and its return is the receiver). A receiver
# written `virtual(T)` is the value typed T+. Arguments are literals: an integer is
# Int32, a string String, true or false Bool, and nil Nil. A call may write named
# arguments (`name: literal`) and a block (`{ ... }`).
#
# A receiver that is a union is looked up one member at a time, in member order,
# as the hosted call pass dispatches it, and the matches are joined.
#
# A `# call` line is the hosted lookup (`Type#lookup_matches`, analyze_all off),
# the first step of the hosted call pass. Its matches are listed in the hosted
# order, joined by "; ", as
#
#   <owner>::<name>(<restrictions>) -> <return>
#
# The owner is the receiver's type, as the hosted context names it. A restriction is
# the type its written form names, relative to the type the def was found on, or `_`
# when it has none. The return is the def's declared return type, or `needs body
# typing` when it has none. A match list that covers every argument combination
# ends with ` [cover all]`.
#
# An `# error` line runs the whole hosted compile of the prelude and the fixture
# with the call as its last expression, and reports the first line of the error it
# raises, or `ok`.
#
# The port's driver (bench/selfhost_semantic_calls_exercise.iyi) prints the same
# lines for the same fixtures, and the gate requires them byte-identical.
#
# Numeric autocast is the hosted second lookup pass: a number literal matches
# when its value fits, and a typed integer matches when its whole range fits.
# Symbol autocast is not covered here.
require "compiler/requires"

RECEIVER_ERROR = "receiver is not resolvable"

# The hosted compile of a source with the prelude, through the main pass.
class Iyi::Compiler
  def prelude_pass(source : Iyi::Compiler::Source) : Iyi::Program
    program = new_program([source])
    node = parse(program, [source])
    node, processor = program.top_level_semantic(node)
    program.semantic_after_top_level(node, processor, cleanup: false)
    program
  end

  def typed_node(source : Iyi::Compiler::Source) : Iyi::ASTNode
    program = new_program([source])
    node = parse(program, [source])
    node, processor = program.top_level_semantic(node)
    program.semantic_after_top_level(node, processor, cleanup: false)
    node
  end
end

# A compiler configured the way the typed oracle configures it, with the prelude.
def new_compiler : Iyi::Compiler
  compiler = Iyi::Compiler.new
  compiler.prelude = "iyi/prelude"
  compiler.no_codegen = true
  compiler.stdout = IO::Memory.new
  compiler.stderr = IO::Memory.new
  compiler
end

# The type of a literal argument, as the hosted type of the literal.
def literal_type(program : Iyi::Program, node : Iyi::ASTNode) : Iyi::Type
  if node.is_a?(Iyi::NumberLiteral)
    return program.types["Int32"].as(Iyi::Type)
  end
  if node.is_a?(Iyi::StringLiteral)
    return program.types["String"].as(Iyi::Type)
  end
  if node.is_a?(Iyi::BoolLiteral)
    return program.types["Bool"].as(Iyi::Type)
  end
  if node.is_a?(Iyi::NilLiteral)
    return program.types["Nil"].as(Iyi::Type)
  end
  if node.is_a?(Iyi::Call) && node.name == "abs" && node.args.empty? && node.obj
    return literal_type(program, node.obj.not_nil!)
  end
  if node.is_a?(Iyi::Call) && node.as(Iyi::Call).name == "instance" && node.as(Iyi::Call).obj.nil?
    call = node.as(Iyi::Call)
    if call.args.size == 1
      return program.lookup_type(call.args[0])
    end
  end
  raise "argument is not a literal"
end

# The signature of a call: its literal arguments, named arguments and block, as the
# hosted call pass builds it.
def signature_of(program : Iyi::Program, call : Iyi::Call) : Iyi::CallSignature
  arg_types = call.args.map { |arg| literal_type(program, arg) }
  named = call.named_args
  named_types = named.nil? ? nil : named.map { |na| Iyi::NamedArgumentType.new(na.name, literal_type(program, na.value)) }
  Iyi::CallSignature.new(call.name, arg_types, call.block, named_types)
end

# The matches of a signature on a receiver, and whether they cover every argument
# combination. A union receiver is one lookup per member, in member order.
# *analyze_all* is the hosted second pass: every overload is tried so a numeric
# autocast can report an ambiguity.
def dispatch_matches(receiver : Iyi::Type, signature : Iyi::CallSignature, analyze_all = false) : {Array(Iyi::Match), Bool}
  if receiver.is_a?(Iyi::UnionType)
    all = [] of Iyi::Match
    cover = true
    receiver.as(Iyi::UnionType).union_types.each do |member|
      found, member_cover = dispatch_matches(member, signature, analyze_all)
      all.concat(found)
      cover = false unless member_cover
    end
    return {all, cover}
  end
  # A trait receiver is looked up over the types that implement it, as the hosted
  # call pass dispatches it (NonGenericModuleType#including_types), not over the
  # trait's own abstract defs.
  if receiver.is_a?(Iyi::TraitType)
    including = receiver.as(Iyi::TraitType).including_types
    return {[] of Iyi::Match, false} if including.nil?
    return dispatch_matches(including.as(Iyi::Type), signature, analyze_all)
  end
  matches = receiver.lookup_matches(signature, analyze_all: analyze_all)
  {matches.matches || [] of Iyi::Match, matches.cover_all? == true}
end

# True when *node* is a number literal, or a harness `instance(T)` of an integer
# whose kind is at most 64 bits (or Float32): the hosted supports_autocast?
# (semantic/ast.cr:19-35) for the arguments this driver can type. Symbol autocast
# is not this increment.
def numeric_autocast?(program : Iyi::Program, node : Iyi::ASTNode) : Bool
  return true if node.is_a?(Iyi::NumberLiteral)
  return false unless node.is_a?(Iyi::Call)
  t = literal_type(program, node)
  if t.is_a?(Iyi::IntegerType)
    return t.kind.bytesize <= 64
  end
  t.is_a?(Iyi::FloatType) && t.kind.f32?
end

# The argument type the hosted second pass uses: a NumberAutocastType around the
# literal, or around a node typed as the harness type for `instance(T)`.
def autocast_type_of(program : Iyi::Program, node : Iyi::ASTNode) : Iyi::Type
  base = literal_type(program, node)
  if node.is_a?(Iyi::NumberLiteral)
    node.set_type(base)
    return Iyi::NumberAutocastType.new(program, node)
  end
  if numeric_autocast?(program, node) && (base.is_a?(Iyi::IntegerType) || base.is_a?(Iyi::FloatType))
    holder = Iyi::Nop.new
    holder.set_type(base)
    return Iyi::NumberAutocastType.new(program, holder)
  end
  base
end

def signature_autocast(program : Iyi::Program, call : Iyi::Call) : Iyi::CallSignature
  arg_types = call.args.map { |arg| autocast_type_of(program, arg) }
  named = call.named_args
  named_types = named.nil? ? nil : named.map { |na| Iyi::NamedArgumentType.new(na.name, autocast_type_of(program, na.value)) }
  Iyi::CallSignature.new(call.name, arg_types, call.block, named_types)
end

def wants_numeric_autocast?(program : Iyi::Program, call : Iyi::Call) : Bool
  return true if call.args.any? { |arg| numeric_autocast?(program, arg) }
  named = call.named_args
  return false if named.nil?
  named.any? { |na| numeric_autocast?(program, na.value) }
end

# The type named by a receiver written as a path, such as `Foo` or `Outer::Foo`.
def receiver_scope(program : Iyi::Program, name : String) : Iyi::Type
  found = program.lookup_path(Iyi::Path.new(name.split("::")))
  raise RECEIVER_ERROR if found.nil?
  found.as(Iyi::Type)
end

# The position of the last dot outside parentheses, or nil.
def last_dot(expr : String) : Int32?
  depth = 0
  found = nil
  expr.each_char_with_index do |c, i|
    depth += 1 if c == '('
    depth -= 1 if c == ')'
    found = i if c == '.' && depth == 0
  end
  found
end

# The type a receiver text names: `virtual(T)` is T's virtual form; a path or a
# generic (`Pointer(UInt8)`) names its metaclass; a call names the type of its
# single declared return.
def receiver_type(program : Iyi::Program, text : String) : Iyi::Type
  if text.starts_with?("virtual(") && text.ends_with?(")")
    return receiver_scope(program, text[8...-1]).virtual_type
  end
  node = Iyi::Parser.new(text).parse
  if node.is_a?(Iyi::Path) || node.is_a?(Iyi::Generic)
    return program.lookup_type(node).metaclass
  end
  unless node.is_a?(Iyi::Call)
    return receiver_scope(program, text).metaclass
  end
  call = node.as(Iyi::Call)
  scope = call_scope(program, text)
  found, _ = dispatch_matches(scope, signature_of(program, call))
  raise RECEIVER_ERROR if found.size != 1
  ret = found[0].def.return_type
  raise RECEIVER_ERROR if ret.nil?
  found[0].context.defining_type.lookup_type(ret).as(Iyi::Type)
end

# The type a call's own receiver is, for the call written as `text`.
def call_scope(program : Iyi::Program, text : String) : Iyi::Type
  if dot = last_dot(text)
    return receiver_type(program, text[0...dot])
  end
  program
end

def restriction_text(owner : Iyi::Type, restriction : Iyi::ASTNode?) : String
  return "_" if restriction.nil?
  owner.lookup_type(restriction).to_s
end

def match_text(m : Iyi::Match) : String
  scope = m.context.defining_type
  restrictions = m.def.args.map { |arg| restriction_text(scope, arg.restriction) }
  ret = m.def.return_type
  ret_text = ret.nil? ? "needs body typing" : scope.lookup_type(ret).to_s
  "#{m.context.instantiated_type.to_s}::#{m.def.name}(#{restrictions.join(", ")}) -> #{ret_text}"
end

# The type the one match was found on, and the receiver it was invoked on.
# They differ when the method is inherited (match.cr: defining_type vs instantiated_type).
def defining_text(program : Iyi::Program, expr : String) : String
  node = Iyi::Parser.new(expr).parse
  raise "not a call: #{expr}" unless node.is_a?(Iyi::Call)
  call = node.as(Iyi::Call)
  receiver = call_scope(program, expr)
  found, _ = dispatch_matches(receiver, signature_of(program, call))
  if found.empty? && wants_numeric_autocast?(program, call)
    found, _ = dispatch_matches(receiver, signature_autocast(program, call), true)
  end
  raise "expected one match" unless found.size == 1
  m = found[0]
  "defining=#{m.context.defining_type} owner=#{m.context.instantiated_type}"
rescue ex : Exception
  "error: #{ex.message.to_s.lines.first? || ""}"
end

# The instantiated argument types of the target after the hosted call pass.
# Its inferred return type belongs to the body typing gate.
def instance_text(path : String, fixture : String, expr : String) : String
  node = new_compiler.typed_node(Iyi::Compiler::Source.new(path, fixture + "\n" + expr + "\n"))
  current = node
  while current.is_a?(Iyi::Expressions)
    exps = current.as(Iyi::Expressions).expressions
    raise "empty file" if exps.empty?
    current = exps.last
  end
  raise "not a call: #{expr}" unless current.is_a?(Iyi::Call)
  td = current.as(Iyi::Call).target_def
  parts = td.args.map { |arg| arg.type.to_s }
  "args=#{parts.join(",")} body=pending"
rescue ex : Exception
  "error: #{ex.message.to_s.lines.first? || ""}"
end

def evaluate(program : Iyi::Program, expr : String) : String
  node = Iyi::Parser.new(expr).parse
  raise "not a call: #{expr}" unless node.is_a?(Iyi::Call)
  call = node.as(Iyi::Call)
  receiver = call_scope(program, expr)
  found, cover = dispatch_matches(receiver, signature_of(program, call))
  # The hosted call pass retries with numeric autocast when the first lookup
  # finds nothing and an argument supports it (call.cr lookup_matches).
  if found.empty? && wants_numeric_autocast?(program, call)
    sig = signature_autocast(program, call)
    found, cover = dispatch_matches(receiver, sig, true)
    sig.arg_types.each &.check_restriction_exception
    sig.named_args.try &.each &.type.check_restriction_exception
  end
  return "none" if found.empty?
  parts = found.map { |m| match_text(m) }
  text = parts.join("; ")
  text += " [cover all]" if cover
  text
rescue ex : Exception
  "error: #{ex.message.to_s.lines.first? || ""}"
end

# The argument list the call's matched def is called with after the hosted
# expansion (Def#expand_default_arguments): the given positional arguments, then
# each further parameter's named argument, or else the default value the hosted
# expansion assigns to it. The defaults are read from the hosted expansion's body
# (its assignments), not computed here. An expansion that is the def itself (the
# named arguments cover every default in order) has no assignments, so each
# parameter is taken from the call.
def expand_text(program : Iyi::Program, expr : String) : String
  node = Iyi::Parser.new(expr).parse
  raise "not a call: #{expr}" unless node.is_a?(Iyi::Call)
  call = node.as(Iyi::Call)
  receiver = call_scope(program, expr)
  found, _ = dispatch_matches(receiver, signature_of(program, call))
  raise "expected one match" unless found.size == 1
  definition = found[0].def
  named = call.named_args
  named_names = named.nil? ? nil : named.map { |na| na.name }
  expansion = definition.expand_default_arguments(program, call.args.size, named_names)
  defaults = {} of String => String
  unless expansion.object_id == definition.object_id
    expansion.body.as(Iyi::Expressions).expressions.each do |item|
      assign = item
      assign = item.as(Iyi::AssignWithRestriction).assign if item.is_a?(Iyi::AssignWithRestriction)
      next unless assign.is_a?(Iyi::Assign)
      target = assign.as(Iyi::Assign).target
      next unless target.is_a?(Iyi::Var)
      defaults[target.as(Iyi::Var).name] = assign.as(Iyi::Assign).value.to_s
    end
  end
  texts = [] of String
  definition.args.each_with_index do |arg, k|
    if k < call.args.size
      texts << call.args[k].to_s
    else
      given = named.nil? ? nil : named.find { |n| n.name == arg.external_name }
      if given
        texts << given.value.to_s
      else
        texts << defaults.fetch(arg.name, "?")
      end
    end
  end
  texts.join(", ")
rescue ex : Exception
  "error: #{ex.message.to_s.lines.first? || ""}"
end

# The wrapper the hosted expansion builds for the call (Def#expand_default_arguments), as
# its name, its parameter names and its body's statements, or `self` when the expansion
# is the def itself. An AssignWithRestriction prints as its assignment, as the driver
# prints a plain one.
def wrapper_text(program : Iyi::Program, expr : String) : String
  node = Iyi::Parser.new(expr).parse
  raise "not a call: #{expr}" unless node.is_a?(Iyi::Call)
  call = node.as(Iyi::Call)
  receiver = call_scope(program, expr)
  found, _ = dispatch_matches(receiver, signature_of(program, call))
  raise "expected one match" unless found.size == 1
  definition = found[0].def
  named = call.named_args
  named_names = named.nil? ? nil : named.map { |na| na.name }
  expansion = definition.expand_default_arguments(program, call.args.size, named_names)
  return "self" if expansion.object_id == definition.object_id
  names = expansion.args.map { |arg| arg.name }
  statements = [] of String
  expansion.body.as(Iyi::Expressions).expressions.each do |item|
    assign = item
    assign = item.as(Iyi::AssignWithRestriction).assign if item.is_a?(Iyi::AssignWithRestriction)
    statements << (assign.is_a?(Iyi::Expressions) ? "generated body" : assign.to_s)
  end
  "#{expansion.name}(#{names.join(", ")}) { #{statements.join("; ")} }"
rescue ex : Exception
  "error: #{ex.message.to_s.lines.first? || ""}"
end

# The first line of the error the hosted compile raises for `expr` after the prelude
# and the fixture, or `ok` when it raises none.
def error_text(path : String, fixture : String, expr : String) : String
  new_compiler.prelude_pass(Iyi::Compiler::Source.new(path, fixture + "\n" + expr + "\n"))
  "ok"
rescue ex : Exception
  "error: #{ex.message.to_s.lines.first? || ""}"
end

# The free variables the one match bound, `B=Int32,E=Nil`, or `matched` when the
# call matches and binds none, or `none`. A `# bound` line is how a generic
# restriction with free variables is compared: the match text cannot print a
# restriction until those names are bound.
def bound_text(program : Iyi::Program, expr : String) : String
  node = Iyi::Parser.new(expr).parse
  raise "not a call: #{expr}" unless node.is_a?(Iyi::Call)
  call = node.as(Iyi::Call)
  receiver = call_scope(program, expr)
  found, _ = dispatch_matches(receiver, signature_of(program, call))
  return "none" if found.empty?
  vars = found[0].context.bound_free_vars
  return "matched" if vars.nil? || vars.empty?
  parts = vars.keys.sort.map { |name| "#{name}=#{vars[name]}" }
  parts.join(",")
rescue ex : Exception
  "error: #{ex.message.to_s.lines.first? || ""}"
end

def tuple_text(path : String, fixture : String, expr : String) : String
  node = new_compiler.typed_node(Iyi::Compiler::Source.new(path, fixture + "\n" + expr + "\n"))
  while node.is_a?(Iyi::Expressions)
    node = node.expressions.last
  end
  body = node.as(Iyi::Call).target_def.body
  return "nil" if body.is_a?(Iyi::NilLiteral)
  return "normal" unless body.is_a?(Iyi::TupleIndexer)
  index = body.index
  if index.is_a?(Range)
    last = index.end - (index.excludes_end? ? 1 : 0)
    "index=#{index.begin},#{last},range=true"
  else
    "index=#{index},#{index},range=false"
  end
rescue ex : Exception
  "error: #{ex.message.to_s.lines.first? || ""}"
end

begin
  path = ARGV[0]? || abort("usage: selfhost_semantic_calls_oracle <fixture.iyi>")
  source = File.read(path)
  program = new_compiler.prelude_pass(Iyi::Compiler::Source.new(path, source))
  source.each_line do |line|
    if line.starts_with?("# call ")
      expr = line[7..].strip
      puts "#{expr} => #{evaluate(program, expr)}"
    elsif line.starts_with?("# bound ")
      expr = line[8..].strip
      puts "#{expr} => #{bound_text(program, expr)}"
    elsif line.starts_with?("# error ")
      expr = line[8..].strip
      puts "#{expr} => #{error_text(path, source, expr)}"
    elsif line.starts_with?("# defining ")
      expr = line[11..].strip
      puts "#{expr} => #{defining_text(program, expr)}"
    elsif line.starts_with?("# instance ")
      expr = line[11..].strip
      puts "#{expr} => #{instance_text(path, source, expr)}"
    elsif line.starts_with?("# tuple ")
      expr = line[8..].strip
      puts "#{expr} => #{tuple_text(path, source, expr)}"
    elsif line.starts_with?("# expand ")
      expr = line[9..].strip
      puts "#{expr} => #{expand_text(program, expr)}"
    elsif line.starts_with?("# wrapper ")
      expr = line[10..].strip
      puts "#{expr} => #{wrapper_text(program, expr)}"
    end
  end
rescue ex : Exception
  STDERR.puts "ERROR: #{ex.message.to_s.lines.first? || ""}"
  exit 2
end
