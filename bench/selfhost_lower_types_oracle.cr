# Lowering-types oracle for bench/selfhost_lower_types_exercise.sh.
#
#   selfhost_lower_types_oracle <fixture.iyi> <target triple>
#
# Declares the fixture into a hosted Program for the target, then prints one
# block per `# type: <expr>` line of the fixture. The port's driver
# (bench/selfhost_lower_types_exercise.iyi) prints the same blocks, and the gate
# requires the two outputs byte-identical.
#
# A block:
#
#   == <expr>
#   llvm_type: <type>                  the hosted llvm_type(type)
#   llvm_type(wants_size): <type>      llvm_type(type, wants_size: true)
#   llvm_struct_type: <type | ->       llvm_struct_type(type), where it applies
#   offsets: <n n ... | ->             the byte offset of each element of that struct
#   llvm_embedded_type: <type>
#   size: <bytes>                      size_of(llvm_type(type))
#   align: <bytes>                     align_of(llvm_type(type))
#   passed_by_value: <true|false>
#
# Normalisation, so the two printers agree. The hosted LLVM text form is not the
# IR's, so LLVM types are written here the way the IR writes them: void, iN,
# float, double, ptr, [N x T], { ... } and <{ ... }> for a literal struct, and
# %name for a named struct, the name quoted by the IR's own rule. A named
# struct's body is not printed: its fields are the `offsets:` line. A pointer's
# address space is not printed, because no fixture uses one.
#
# The layout is iyi's when the fixture declares `IyiRuntimeLock`, as the hosted
# `Program#iyi_object_layout?` decides it; the port's driver reads the same fact.
require "compiler/requires"

def ir_name_text(name : String) : String
  return name if name =~ /\A[A-Za-z_.$][A-Za-z0-9_.$]*\z/
  String.build do |io|
    io << '"'
    name.each_byte do |b|
      if b == 34_u8
        io << "\\\""
      elsif b == 92_u8
        io << "\\\\"
      elsif b < 32_u8 || b >= 127_u8
        io << "\\x" << b.to_s(16).rjust(2, '0')
      else
        io << b.chr
      end
    end
    io << '"'
  end
end

def llvm_text(t : LLVM::Type) : String
  kind = t.kind
  if kind.void?
    "void"
  elsif kind.integer?
    "i#{t.int_width}"
  elsif kind.float?
    "float"
  elsif kind.double?
    "double"
  elsif kind.pointer?
    "ptr"
  elsif kind.array?
    "[#{t.array_size} x #{llvm_text(t.element_type)}]"
  elsif kind.struct?
    if name = t.struct_name
      "%#{ir_name_text(name)}"
    else
      inner = t.struct_element_types.map { |e| llvm_text(e) }.join(", ")
      if t.packed_struct?
        inner.empty? ? "<{}>" : "<{ #{inner} }>"
      else
        inner.empty? ? "{}" : "{ #{inner} }"
      end
    end
  else
    raise "no text for an LLVM #{kind} type"
  end
end

# Where the hosted typer lays a type out as a struct: a class or struct with
# instance variables, a tuple, a named tuple, a static array. Primitives, nil,
# pointers, procs, enums, metaclasses and unions have no struct of their own.

# A generic class instance laid out as a struct of its own fields. Pointer and proc instances are
# not measured here (their layout is a pointer or a function, the typer's other branches).
def plain_generic_instance?(type : Iyi::Type) : Bool
  type.is_a?(Iyi::GenericClassInstanceType) && !type.is_a?(Iyi::PointerInstanceType) && !type.is_a?(Iyi::ProcInstanceType)
end

def struct_applies?(type : Iyi::Type) : Bool
  return true if type.is_a?(Iyi::TupleInstanceType) || type.is_a?(Iyi::NamedTupleInstanceType)
  return true if type.is_a?(Iyi::StaticArrayInstanceType)
  return true if plain_generic_instance?(type)
  type.is_a?(Iyi::NonGenericClassType) && !type.is_a?(Iyi::NilType)
end

# An LLVM function type as the IR writes it: `ret (params)`.
def llvm_function_text(t : LLVM::Type) : String
  params = t.params_types.map { |p| llvm_text(p) }
  "#{llvm_text(t.return_type)} (#{params.join(", ")})"
end

# The instance variables of a user class, in declaration order: `name:Type` (the name keeps its @), or `-`.
def ivars_text(type : Iyi::Type) : String
  return "-" unless (type.is_a?(Iyi::NonGenericClassType) && !type.is_a?(Iyi::NilType)) || plain_generic_instance?(type)
  ivars = type.is_a?(Iyi::GenericClassInstanceType) ? type.as(Iyi::GenericClassInstanceType).all_instance_vars : type.as(Iyi::NonGenericClassType).all_instance_vars
  parts = ivars.map { |name, ivar| "#{name}:#{ivar.type}" }
  parts.empty? ? "-" : parts.join(" ")
end

# The `ids` mode's block: the type id and the id range the hosted LLVMId gives the type, or `-`.
def ids_block(name : String, program : Iyi::Program, type : Iyi::Type) : String
  program.llvm_id.type_id(type)
  mm = program.llvm_id.min_max_type_id(type)
  String.build do |io|
    io << "== " << name << "\n"
    if mm
      io << "type_id: " << mm[1] << "\n"
      io << "type_range: " << mm[0] << " " << mm[1] << "\n"
      meta = program.llvm_id.id_to_metaclass[mm[1]]?
      io << "metaclass_id: " << (meta ? meta.to_s : "-") << "\n"
    else
      io << "type_id: -\n"
      io << "type_range: -\n"
      io << "metaclass_id: -\n"
    end
  end
end

# The `table` mode: every type the hosted LLVMId numbered, in id order, as `id name meta=<id|->`. The
# metaclass id is the hosted `id_to_metaclass` entry of the type's id. Metaclasses are rows of their own,
# so the whole numbering of two programs can be diffed row by row.
def table_text(program : Iyi::Program) : String
  llvm = program.llvm_id
  rows = [] of {Int32, String}
  llvm.each_type do |type|
    mm = llvm.min_max_type_id(type)
    rows << {mm[1], type.to_s} if mm
  end
  rows.sort_by! { |row| row[0] }
  String.build do |io|
    rows.each do |row|
      meta = llvm.id_to_metaclass[row[0]]?
      io << row[0] << " " << row[1] << " meta=" << (meta ? meta.to_s : "-") << "\n"
    end
  end
end

# The hosted census (gc_layouts.cr 204-221): the classes a virtual type over them was made of, their
# subclasses, and the members of the program's reference unions, with their subclasses.
def hosted_headed_candidate?(type : Iyi::Type) : Bool
  type.is_a?(Iyi::NonGenericClassType) || type.is_a?(Iyi::GenericClassInstanceType)
end

def hosted_headed_census(program : Iyi::Program) : Array(Iyi::Type)
  headed = [] of Iyi::Type
  program.llvm_id.each_type do |type|
    next unless hosted_headed_candidate?(type) && type.virtual_type_made?
    headed << type
    type.all_subclasses.each { |sub| headed << sub }
  end
  program.unions.each_value do |union|
    next unless union.is_a?(Iyi::ReferenceUnionType) || union.is_a?(Iyi::NilableReferenceUnionType)
    union.union_types.each do |member|
      member = member.remove_alias
      next unless hosted_headed_candidate?(member)
      headed << member
      member.all_subclasses.each { |sub| headed << sub }
    end
  end
  headed
end

# The `headed` mode's block: `1` or `0`, the hosted `iyi_headed?` (gc_layouts.cr 173-177) of the type.
def headed_block(name : String, program : Iyi::Program, type : Iyi::Type) : String
  headed = type.to_s == "String" || program.llvm_id.type_id(type) > 65535 || hosted_headed_census(program).includes?(type)
  "== #{name}\nheaded: #{headed ? "1" : "0"}\n"
end

# The pointer map of a user class under iyi's object layout, as `alloc`, `cap` and the scan
# offsets; the hosted type id is not printed (it is numbered differently, NEEDS.md row 16).
def layout_text(program : Iyi::Program, type : Iyi::Type) : String
  return "-" unless type.is_a?(Iyi::NonGenericClassType) && !type.is_a?(Iyi::NilType) && program.iyi_object_layout?
  row = program.gc_type_layout(type)
  scan = row.scan_offsets.map { |o| o.to_s }.join(" ")
  "alloc=#{row.alloc_size} cap=#{row.scan_cap} scan=#{scan.empty? ? "-" : scan}"
end

def block_text(name : String, program : Iyi::Program, typer : Iyi::LLVMTyper, type : Iyi::Type) : String
  String.build do |io|
    io << "== " << name << "\n"
    io << "llvm_type: " << llvm_text(typer.llvm_type(type)) << "\n"
    io << "llvm_type(wants_size): " << llvm_text(typer.llvm_type(type, wants_size: true)) << "\n"
    if struct_applies?(type)
      st = typer.llvm_struct_type(type)
      io << "llvm_struct_type: " << llvm_text(st) << "\n"
      if st.kind.struct?
        offsets = (0...st.struct_element_types.size).map { |i| typer.offset_of(st, i).to_s }
        io << "offsets: " << (offsets.empty? ? "-" : offsets.join(" ")) << "\n"
      else
        io << "offsets: -\n"
      end
    else
      io << "llvm_struct_type: -\n"
      io << "offsets: -\n"
    end
    io << "llvm_embedded_type: " << llvm_text(typer.llvm_embedded_type(type)) << "\n"
    io << "size: " << typer.size_of(typer.llvm_type(type)) << "\n"
    io << "align: " << typer.align_of(typer.llvm_type(type)) << "\n"
    io << "passed_by_value: " << (type.passed_by_value? ? "true" : "false") << "\n"
    io << "ivars: " << ivars_text(type) << "\n"
    io << "layout: " << layout_text(program, type) << "\n"
    io << "c_type: " << llvm_text(typer.llvm_c_type(type)) << "\n"
    io << "c_return_type: " << llvm_text(typer.llvm_c_return_type(type)) << "\n"
    io << "embedded_c_type: " << llvm_text(typer.llvm_embedded_c_type(type)) << "\n"
    io << "intrinsic_return_type: " << llvm_text(typer.llvm_intrinsic_return_type(type)) << "\n"
    io << "passed_indirectly: " << (typer.passed_indirectly?(type) ? "true" : "false") << "\n"
    if type.is_a?(Iyi::ProcInstanceType)
      io << "proc_function: " << llvm_function_text(typer.proc_type(type)) << "\n"
      io << "closure_function: " << llvm_function_text(typer.closure_type(type)) << "\n"
    end
  end
end

# Splits operands at the commas outside every parenthesis.
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

# Splits at a separator character outside every parenthesis, trimmed, keeping empty parts.
def split_outside(text : String, sep : Char) : Array(String)
  parts = [] of String
  depth = 0
  current = String::Builder.new
  text.each_char do |c|
    if c == sep && depth == 0
      parts << current.to_s.strip
      current = String::Builder.new
      next
    end
    depth += 1 if c == '('
    depth -= 1 if c == ')'
    current << c
  end
  parts << current.to_s.strip
  parts
end

# The hosted type a written type names: `Int32`, `Color`, `Pointer(Int32)`, `Color.class`.
def resolve(program : Iyi::Program, name : String) : Iyi::Type
  name = name.strip
  # A union is its members merged, `A | B`, and a nilable type is the type merged with Nil, `A?`.
  bars = split_outside(name, '|')
  if bars.size > 1
    members = bars.map { |b| resolve(program, b).as(Iyi::Type?) }
    return program.type_merge(members).as(Iyi::Type)
  end
  if name.ends_with?("?") && name.size > 1
    inner = resolve(program, name[0...-1]).as(Iyi::Type?)
    return program.type_merge([inner, resolve(program, "Nil").as(Iyi::Type?)]).as(Iyi::Type)
  end
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
  t = program.types[name]?
  raise "unknown type #{name}" if t.nil?
  t
end

class Iyi::Compiler
  # The entry file as a build reads it, with the closure of what it imports, in the same program
  # (`parse` is private to the compiler, so this reaches it from inside the class).
  def declarations_program(source : Iyi::Compiler::Source) : {Program, ASTNode}
    self.prelude = "iyi/prelude"
    program = new_program([source])
    {program, parse(program, source)}
  end
end

# Whether a declaration with these locations belongs to the entry file.
def declared_in?(locations : Array(Iyi::Location)?, entry : String?) : Bool
  return true unless entry
  return false unless locations
  locations.any? { |loc| File.expand_path(loc.filename.to_s) == entry }
end

# Every type the entry declares, nested types included: the hosted dump's rule.
def own_collect(t : Iyi::Type, entry : String, found : Array(Iyi::Type)) : Nil
  found << t if declared_in?(t.locations, entry) && !t.is_a?(Iyi::Const)
  if t.is_a?(Iyi::NamedType) && !t.is_a?(Iyi::EnumType)
    t.types.keys.sort.each do |sub|
      own_collect(t.types[sub], entry, found)
    end
  end
  nil
end

# Whole-program mode (`--own <file> <triple>`): the file and its import closure declared as a
# build declares them (the declarations pass and the instance variable pass), then one block per
# type the file declares. A type that fails to lower prints `== name` and an `ERROR:` line in place
# of its block, so one unported type does not hide the rest.
def own_text(path : String, triple : String) : String
  entry = File.expand_path(path)
  source = File.read(entry)
  compiler = Iyi::Compiler.new
  program, node = compiler.declarations_program(Iyi::Compiler::Source.new(entry, source))
  # The hosted build prepends the prelude's require to the parsed program (program.cr, `prelude`).
  prelude_require = Iyi::Require.new("iyi/prelude")
  prelude_require.iyi_prelude = true
  prelude_require.at(Iyi::Location.new(entry, 1, 1))
  node = Iyi::Expressions.new([prelude_require.as(Iyi::ASTNode), node.as(Iyi::ASTNode)] of Iyi::ASTNode)
  program.top_level_semantic(node)
  program.codegen_target = Iyi::Codegen::Target.new(triple)
  typer = program.llvm_typer
  types = [] of Iyi::Type
  program.types.keys.sort.each do |name|
    own_collect(program.types[name], entry, types)
  end
  String.build do |io|
    types.each do |t|
      name = t.is_a?(Iyi::NamedType) ? t.full_name : t.to_s
      begin
        io << block_text(name, program, typer, t)
      rescue ex : Exception
        io << "== " << name << "\nERROR: " << (ex.message.to_s.lines.first? || "") << "\n"
      end
    end
  end
end

if ARGV[0]? == "--own"
  own_path = ARGV[1]? || abort("usage: selfhost_lower_types_oracle --own <file.iyi> <target triple>")
  own_triple = ARGV[2]? || abort("usage: selfhost_lower_types_oracle --own <file.iyi> <target triple>")
  print own_text(own_path, own_triple)
  exit 0
end

begin
  path = ARGV[0]? || abort("usage: selfhost_lower_types_oracle <fixture.iyi> <target triple>")
  triple = ARGV[1]? || abort("usage: selfhost_lower_types_oracle <fixture.iyi> <target triple>")
  source = File.read(path)
  program = Iyi::Program.new
  program.codegen_target = Iyi::Codegen::Target.new(triple)
  node = Iyi::Parser.new(source).parse
  # The hosted declaration passes: top-level declarations, then the instance variable
  # declarations and the types guessed from assignments (program.cr top_level_semantic).
  program.top_level_semantic(node)
  typer = program.llvm_typer
  mode = ARGV[2]? || "blocks"
  # Every line is resolved before any block is printed, so the hosted LLVMId (created at its first
  # use) numbers the instances the fixture names, as the port driver does.
  pending = [] of {String, Iyi::Type}
  source.each_line do |line|
    next unless line.starts_with?("# type: ")
    expr = line[8..].strip
    pending << {expr, resolve(program, expr)}
  end
  if mode == "table"
    print table_text(program)
    exit 0
  end
  pending.each do |expr, type|
    if mode == "ids"
      puts ids_block(expr, program, type)
    elsif mode == "headed"
      puts headed_block(expr, program, type)
    else
      puts block_text(expr, program, typer, type)
    end
  end
rescue ex : Exception
  STDERR.puts "ERROR: #{ex.message.to_s.lines.first? || ""}"
  exit 2
end
