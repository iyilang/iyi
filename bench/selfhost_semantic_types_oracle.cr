# Type-model oracle for bench/selfhost_semantic_types_exercise.sh.
#
#   selfhost_semantic_types_oracle <fixture.iyi>
#
# Builds the fixture's declarations into the hosted Program, then evaluates each
# operation line of the form `# op <op>` in the fixture and prints one line:
#
#   <op> => <result>
#
# Results use the hosted type's to_s form. Booleans print as true or false, a
# list of types as [A, B], an absent type as nil, and an integer as its digits.
# The port's driver (bench/selfhost_semantic_types_exercise.iyi) prints the same
# lines for the same fixtures, and the gate requires them byte-identical.
#
# Type names in an operation may be written with arguments: `Box(Int32)`,
# `Pair(Int32, String)`, `Proc(Int32, Int32)` (the last argument is the return
# type). Commas inside parentheses do not separate operands.
#
# Operations:
#   T.<member>                     the receiver is a type name, or `T.class` for
#                                  its metaclass, or a generic instance. Members:
#     nil_type? pointer? proc? void? no_return? virtual? metaclass?
#     virtual_metaclass? struct? reference_like? leaf? subclasses
#     all_subclasses instance_type virtual_type splat_index proc? remove_alias remove_typedef
#   merge(A, B) merge(A, B, C)     Program#type_merge (types/merge.iyi)
#   intersect(T, U)                Type.common_descendent (types/intersect.iyi)
#   filter(T, kind[, args])        a type filter applied to T (types/filters.iyi):
#     is_a, U | nil? | not_is_a, U | not_nil? | truthy | not_truthy |
#     responds_to, name | or_is_a, U, V | and_is_a, U, V
require "compiler/requires"

def type_text(t : Iyi::Type?) : String
  return "nil" if t.nil?
  t.to_s
end

def bool_text(b : Bool) : String
  b ? "true" : "false"
end

def list_text(types : Array(Iyi::Type)) : String
  "[#{types.map { |t| type_text(t) }.join(", ")}]"
end

# Splits operands at the commas that are outside every parenthesis.
def split_top(text : String) : Array(String)
  parts = [] of String
  depth = 0
  current = String::Builder.new
  text.each_char do |c|
    if c == ',' && depth == 0
      parts << current.to_s.strip
      current = String::Builder.new
      next
    end
    depth += 1 if c == '('
    depth -= 1 if c == ')'
    current << c
  end
  last = current.to_s.strip
  parts << last unless last.empty?
  parts
end

def resolve(program : Iyi::Program, name : String) : Iyi::Type
  name = name.strip
  if name.ends_with?(".class")
    return resolve(program, name[0...-6]).metaclass
  end
  if open = name.index('(')
    raise "unknown generic #{name}" unless name.ends_with?(")")
    base_name = name[0...open]
    args = split_top(name[(open + 1)...-1]).map { |arg| resolve(program, arg) }
    if base_name == "Proc"
      return program.proc_of(args)
    end
    base = resolve(program, base_name)
    unless base.is_a?(Iyi::GenericClassType)
      raise "#{base_name} takes no type arguments"
    end
    return base.as(Iyi::GenericClassType).instantiate(args.map { |arg| arg.as(Iyi::TypeVar) })
  end
  if name.includes?("::")
    found = program.lookup_path(Iyi::Path.new(name.split("::")))
    raise "unknown type #{name}" if found.nil?
    return found.as(Iyi::Type)
  end
  t = program.types[name]?
  raise "unknown type #{name}" if t.nil?
  t
end

def evaluate_merge(program : Iyi::Program, op : String) : String
  parts = split_top(op[6...-1])
  case parts.size
  when 2
    type_text(program.type_merge(resolve(program, parts[0]), resolve(program, parts[1])))
  when 3
    type_text(program.type_merge([resolve(program, parts[0]), resolve(program, parts[1]), resolve(program, parts[2])] of Iyi::Type?))
  else
    raise "merge takes two or three types: #{op}"
  end
end

def evaluate_same_merge(program : Iyi::Program, op : String) : String
  parts = split_top(op[11...-1])
  raise "same_merge takes four types: #{op}" unless parts.size == 4
  first = program.type_merge(resolve(program, parts[0]), resolve(program, parts[1]))
  second = program.type_merge(resolve(program, parts[2]), resolve(program, parts[3]))
  bool_text(first.object_id == second.object_id)
end

def evaluate_intersect(program : Iyi::Program, op : String) : String
  parts = split_top(op[10...-1])
  raise "intersect takes two types: #{op}" unless parts.size == 2
  type_text(Iyi::Type.common_descendent(resolve(program, parts[0]), resolve(program, parts[1])))
end

def evaluate_filter(program : Iyi::Program, op : String) : String
  parts = split_top(op[7...-1])
  t = resolve(program, parts[0])
  nil_t = resolve(program, "Nil")
  filter = case parts[1]
           when "is_a"        then Iyi::SimpleTypeFilter.new(resolve(program, parts[2]))
           when "nil?"        then Iyi::SimpleTypeFilter.new(nil_t)
           when "not_is_a"    then Iyi::SimpleTypeFilter.new(resolve(program, parts[2])).not
           when "not_nil?"    then Iyi::SimpleTypeFilter.new(nil_t).not
           when "truthy"      then Iyi::TruthyFilter.instance
           when "not_truthy"  then Iyi::TruthyFilter.instance.not
           when "responds_to" then Iyi::RespondsToTypeFilter.new(parts[2])
           when "or_is_a"
             Iyi::OrTypeFilter.new(Iyi::SimpleTypeFilter.new(resolve(program, parts[2])), Iyi::SimpleTypeFilter.new(resolve(program, parts[3])))
           when "and_is_a"
             Iyi::AndTypeFilter.new(Iyi::SimpleTypeFilter.new(resolve(program, parts[2])), Iyi::SimpleTypeFilter.new(resolve(program, parts[3])))
           else raise "unknown filter #{parts[1]}"
           end
  type_text(filter.apply(t))
end

# The scope a lookup starts in: `program`, or a type's path such as `Outer::Inner`.
def scope_of(program : Iyi::Program, name : String) : Iyi::Type
  return program if name == "program"
  found = program.lookup_path(Iyi::Path.new(name.split("::")))
  raise "unknown scope #{name}" if found.nil?
  found.as(Iyi::Type)
end

# `lookup(scope, written)`: the type the written type names, or `error: <message>`
# with the first line of the message the hosted lookup raises.
def evaluate_lookup(program : Iyi::Program, op : String) : String
  parts = split_top(op[7...-1])
  scope = scope_of(program, parts[0])
  node = Iyi::Parser.new(parts[1..].join(", ")).parse
  type_text(scope.lookup_type(node))
rescue ex : Exception
  "error: #{ex.message.to_s.lines.first? || ""}"
end

# `restriction(scope, written)`: the restriction the written type converts to in
# the scope, as hosted TypeToRestriction writes it, or `nil` when it has none.
# The hosted converter is overloaded by static type, so the type is dispatched here.
# A metaclass is written `T.class`: the hosted parser reads that in expression
# position as a call, so it is resolved by name, as the other operations do.
def evaluate_restriction(program : Iyi::Program, op : String) : String
  parts = split_top(op[12...-1])
  scope = scope_of(program, parts[0])
  written = parts[1..].join(", ")
  t = written.ends_with?(".class") ? resolve(program, written) : scope.lookup_type(Iyi::Parser.new(written).parse)
  converter = Iyi::TypeToRestriction.new(scope)
  restriction = case t
                when Iyi::NilType                then converter.convert(t)
                when Iyi::IntegerType            then converter.convert(t)
                when Iyi::NonGenericClassType    then converter.convert(t)
                when Iyi::NonGenericModuleType   then converter.convert(t)
                when Iyi::AliasType              then converter.convert(t)
                when Iyi::UnionType              then converter.convert(t)
                when Iyi::MetaclassType          then converter.convert(t)
                when Iyi::TupleInstanceType      then converter.convert(t)
                when Iyi::NamedTupleInstanceType then converter.convert(t)
                when Iyi::ProcInstanceType       then converter.convert(t)
                when Iyi::GenericInstanceType    then converter.convert(t)
                when Iyi::GenericClassType       then converter.convert(t)
                when Iyi::GenericModuleType      then converter.convert(t)
                else                                  raise "no restriction for #{t.class}"
                end
  return "nil" if restriction.nil?
  restriction.to_s
rescue ex : Exception
  "error: #{ex.message.to_s.lines.first? || ""}"
end

def evaluate(program : Iyi::Program, op : String) : String
  return evaluate_merge(program, op) if op.starts_with?("merge(")
  return evaluate_intersect(program, op) if op.starts_with?("intersect(")
  return evaluate_filter(program, op) if op.starts_with?("filter(")
  return evaluate_lookup(program, op) if op.starts_with?("lookup(")
  return evaluate_restriction(program, op) if op.starts_with?("restriction(")
  return evaluate_same_merge(program, op) if op.starts_with?("same_merge(")
  # The receiver may carry arguments, so the member starts after the last
  # dot that is outside parentheses.
  dot = nil
  depth = 0
  op.each_char_with_index do |c, i|
    depth += 1 if c == '('
    depth -= 1 if c == ')'
    dot = i if c == '.' && depth == 0
  end
  raise "malformed operation #{op}" if dot.nil?
  t = resolve(program, op[0...dot])
  member = op[(dot + 1)..]
  case member
  when "nil_type?"          then bool_text(t.nil_type?)
  when "pointer?"           then bool_text(t.pointer?)
  when "proc?"              then bool_text(t.proc?)
  when "void?"              then bool_text(t.void?)
  when "no_return?"         then bool_text(t.no_return?)
  when "virtual?"           then bool_text(t.virtual?)
  when "metaclass?"         then bool_text(t.metaclass?)
  when "virtual_metaclass?" then bool_text(t.virtual_metaclass?)
  when "leaf?"              then bool_text(t.leaf?)
  when "struct?"            then bool_text(t.struct?)
  when "reference_like?"    then bool_text(t.reference_like?)
  when "subclasses"         then list_text(t.subclasses)
  when "all_subclasses"     then list_text(t.all_subclasses)
  when "instance_type"      then type_text(t.instance_type)
  when "virtual_type"       then type_text(t.virtual_type)
  when "virtual_type_made?" then bool_text(t.virtual_type_made?)
  when "virtual_identical"  then bool_text(t.virtual_type.object_id == t.virtual_type.object_id)
  when "remove_alias"       then type_text(t.remove_alias)
  when "remove_typedef"     then type_text(t.remove_typedef)
  when "unbound?"           then bool_text(t.unbound?)
  when "remove_indirection" then type_text(t.remove_indirection)
  when "extern?"            then bool_text(t.extern?)
  when "extern_union?"      then bool_text(t.extern_union?)
  when "packed?"            then bool_text(t.packed?)
  when "including_types"    then type_text(t.including_types)
  when "simple?"            then bool_text(t.as(Iyi::AliasType).simple?)
  when "splat_index"
    idx = t.splat_index
    idx.nil? ? "nil" : idx.to_s
  else
    raise "unknown operation #{member}"
  end
end

begin
  path = ARGV[0]? || abort("usage: selfhost_semantic_types_oracle <fixture.iyi>")
  source = File.read(path)
  program = Iyi::Program.new
  node = Iyi::Parser.new(source).parse
  node.accept Iyi::TopLevelVisitor.new(program)
  source.each_line do |line|
    next unless line.starts_with?("# op ")
    op = line[5..].strip
    puts "#{op} => #{evaluate(program, op)}"
  end
rescue ex : Exception
  STDERR.puts "ERROR: #{ex.message.to_s.lines.first? || ""}"
  exit 2
end
