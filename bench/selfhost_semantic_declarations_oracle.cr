# Declaration oracle for bench/selfhost_semantic_declarations_exercise.sh.
#
#   selfhost_semantic_declarations_oracle <file.iyi>
#   selfhost_semantic_declarations_oracle --initial
#
# Loads the file through the compile's own front end, bare (no prelude), together
# with the closure of what it imports and requires: each imported file is read,
# parsed and declared by the same top-level pass a build runs, with the search
# path IYI_PATH. Then it prints one text dump of the declarations the file itself
# makes: its top-level defs, then each user type with its nested types, defs and
# constants. A type or a def is printed when its location is the file, so what an
# imported file declares is not repeated here. The port's dump prints the same
# form, and the gate requires the two to agree record by record.
#
# On failure the first line of the message goes to stderr and the exit status is
# 2; the gate reports such a file as unmeasured, with that reason.
require "compiler/requires"

class Iyi::Compiler
  # iyi: the entry file as a build reads it, bare, in iyi's library (the prelude
  # name selects it, so `import std/x` is iyi's own). `parse` is private to the
  # compiler, so this reaches it from inside the class, as the typed oracle does.
  def declarations_program(source : Iyi::Compiler::Source) : {Program, ASTNode}
    self.prelude = "iyi/prelude"
    program = new_program([source])
    {program, parse(program, source)}
  end
end

# Whether a declaration with these locations belongs to the entry file. With no
# entry (the built-in types) everything belongs.
def declared_in?(locations : Array(Iyi::Location)?, entry : String?) : Bool
  return true unless entry
  return false unless locations
  locations.any? { |loc| File.expand_path(loc.filename.to_s) == entry }
end

def def_declared?(d : Iyi::Def, entry : String?) : Bool
  return true unless entry
  loc = d.location
  return false unless loc
  File.expand_path(loc.filename.to_s) == entry
end

def dump_def(d : Iyi::Def, io : IO, indent : String)
  io << indent << "Def: " << (d.receiver ? "self." : "") << d.name << "\n"
  vis_str = case d.visibility
            when .private? then "private"
            else                "public"
            end
  io << indent << "  visibility: " << vis_str << "\n"
  if d.is_a?(Iyi::External)
    io << indent << "  real_name: " << d.real_name << "\n"
    io << indent << "  varargs: " << d.varargs? << "\n"
  end
  io << indent << "  abstract: " << d.abstract? << "\n"
  args_strs = d.args.map do |arg|
    s = arg.name
    s += " : #{arg.restriction}" if arg.restriction
    s += " = #{arg.default_value}" if arg.default_value
    s
  end
  io << indent << "  args: [" << args_strs.join(", ") << "]\n"
  ret_str = d.return_type ? d.return_type.to_s : "nil"
  ret_str = ret_str.sub(/^::/, "")
  io << indent << "  return_type: " << ret_str << "\n"
  if prev = d.previous
    io << indent << "  previous: " << prev.def.name << "\n"
  end
end

def dump_type(t : Iyi::Type, io : IO, indent : String, entry : String?)
  full_name = t.is_a?(Iyi::NamedType) ? t.full_name : t.to_s
  if declared_in?(t.locations, entry)
    dump_type_header(t, full_name, io, indent, entry)
  end

  if t.is_a?(Iyi::NamedType) && !t.is_a?(Iyi::EnumType)
    t.types.keys.sort.each do |subname|
      sub = t.types[subname]
      dump_type(sub, io, "#{indent}  ", entry)
    end
  end
end

# One type's own record: its header and properties, its defs. Its nested types
# are dumped by `dump_type`, whether or not this type is the entry's.
def dump_type_header(t : Iyi::Type, full_name : String, io : IO, indent : String, entry : String?)
  kind = case t
         when Iyi::EnumType                         then "enum"
         when Iyi::TraitType, Iyi::GenericTraitType then "trait"
         when Iyi::ClassType                        then t.struct? ? "struct" : "class"
         when Iyi::LibType                          then "lib"
         when Iyi::ModuleType                       then "module"
         when Iyi::AliasType                        then "alias"
         when Iyi::Const                            then "constant"
         else                                            "type"
         end
  io << indent << "Type: " << full_name << " (" << kind << ")\n"
  vis_str = (t.is_a?(Iyi::NamedType) && t.private?) ? "private" : "public"
  io << indent << "  visibility: " << vis_str << "\n"
  io << indent << "  abstract: " << t.abstract? << "\n"

  if t.is_a?(Iyi::GenericType)
    io << indent << "  type_vars: [" << t.type_vars.join(", ") << "]\n"
  end

  if t.is_a?(Iyi::ClassType) && (sc = t.superclass)
    io << indent << "  superclass: " << sc.to_s << "\n"
  end

  if t.is_a?(Iyi::InstanceVarContainer)
    t.instance_vars.keys.each do |ivar_name|
      io << indent << "  Ivar: " << full_name << "#" << ivar_name << "\n"
      io << indent << "    type: " << t.instance_vars[ivar_name].type.to_s << "\n"
    end
    if t.is_a?(Iyi::ClassType) && !t.instance_vars.empty?
      io << indent << "  IvarOrder: [" << t.instance_vars.keys.join(", ") << "]\n"
    end
  end

  if t.is_a?(Iyi::ModuleType) && !t.parents.empty?
    io << indent << "  parents: [" << t.parents.map(&.to_s).sort.join(", ") << "]\n"
  end

  if t.is_a?(Iyi::TraitSupertraits) && (st = t.supertraits) && !st.empty?
    io << indent << "  supertraits: [" << st.map(&.to_s).sort.join(", ") << "]\n"
  end
  if t.is_a?(Iyi::GenericTraitType) && !t.assoc_types.empty?
    io << indent << "  assoc_types: [" << t.assoc_types.sort.join(", ") << "]\n"
  end

  if t.is_a?(Iyi::EnumType)
    members = t.types.map do |k, v|
      val_s = v.as(Iyi::Const).value.to_s
      val_s = val_s.split('_').first if val_s.includes?('_')
      "#{k}=#{val_s}"
    end.sort
    io << indent << "  enum_members: [" << members.join(", ") << "]\n"
  end

  if t.is_a?(Iyi::AliasType)
    t.process_value
    io << indent << "  aliased_type: " << t.aliased_type.to_s << "\n"
  end

  if t.is_a?(Iyi::Const)
    io << indent << "  const_value: " << t.value.to_s << "\n"
  end

  if t.is_a?(Iyi::ModuleType)
    all_defs = [] of Iyi::Def
    t.defs.try &.each_value { |list| list.each { |item| all_defs << item.def } }
    if (meta = t.metaclass) && meta.is_a?(Iyi::ModuleType) && !meta.same?(t)
      meta.defs.try &.each_value do |list|
        list.each do |item|
          next if item.def.name == "allocate"
          next if item.def.name == "new" && t.is_a?(Iyi::EnumType)
          all_defs << item.def
        end
      end
    end
    all_defs = all_defs.select { |d| def_declared?(d, entry) }
    all_defs.sort_by! { |d| "#{d.receiver ? "self." : ""}#{d.name}" }
    all_defs.each do |d|
      dump_def(d, io, "#{indent}  ")
    end
  end
end

def dump_declarations(node : Iyi::ASTNode, io : IO, program : Iyi::Program, entry : String?, typed : Bool = false)
  initial_types = Iyi::Program.new.types.keys.to_set
  visitor = Iyi::TopLevelVisitor.new(program)
  node.accept(visitor)
  # The hosted type declaration pass: explicit and guessed instance variables.
  Iyi::TypeDeclarationProcessor.new(program).process(node)

  if pdefs = program.defs
    top_defs = [] of Iyi::Def
    pdefs.each_value { |list| list.each { |item| top_defs << item.def } }
    top_defs = top_defs.select { |d| def_declared?(d, entry) }
    top_defs.sort_by!(&.name)
    top_defs.each do |d|
      dump_def(d, io, "")
    end
  end

  # Every top-level type is walked, as the port does: the entry filter prints only what the
  # entry declares, and a namespace named like a built-in holds declarations the built-in set
  # would have hidden.
  user_types = program.types
  user_types.keys.sort.each do |name|
    dump_type(user_types[name], io, "", entry)
  end
  if typed
    dump_instances(program, io, initial_types, entry)
  end
end

# The instances of the program's own generic classes, with their instance variables, in the
# typed mode only: the hosted pass always makes them, the port's untyped pass does not, so the
# gate asks for them with `--typed` on the typed fixtures alone. Each instance is a record of its
# own, sorted by its name, as the port's driver prints them. A generic is the entry's only when
# declared_in? says so, the same test dump_type uses, so a prelude or imported generic's
# instances are not records of this file.
def dump_instances(program : Iyi::Program, io : IO, initial_types : Set(String), entry : String?)
  program.types.keys.sort.each do |name|
    next if initial_types.includes?(name)
    generic = program.types[name]
    next unless generic.is_a?(Iyi::GenericClassType)
    next unless declared_in?(generic.locations, entry)
    generic.instantiated_types.sort_by(&.to_s).each do |inst|
      next unless inst.is_a?(Iyi::GenericClassInstanceType)
      full = inst.to_s
      io << "Type: " << full << " (instance)\n"
      ivars = inst.instance_vars
      ivars.keys.each do |ivar_name|
        io << "  Ivar: " << full << "#" << ivar_name << "\n"
        io << "    type: " << ivars[ivar_name].type.to_s << "\n"
      end
      unless ivars.empty?
        io << "  IvarOrder: [" << ivars.keys.join(", ") << "]\n"
      end
    end
  end
end

# `--initial` dumps the program's own built-in types (every name a new program
# holds before any file is read), which the gate compares with the port's.
if ARGV[0]? == "--initial"
  buffer = IO::Memory.new
  initial = Iyi::Program.new
  initial.types.keys.sort.each do |name|
    dump_type(initial.types[name], buffer, "", nil)
  end
  print buffer.to_s
  exit 0
end

# The parent chain of one type, each parent on its own line, indented by depth.
def chain_show(t : Iyi::Type, depth : Int32, indent : String) : String
  line = indent + t.to_s + "\n"
  return line if depth == 0
  if t.is_a?(Iyi::ModuleType)
    t.parents.each do |p|
      line = line + chain_show(p, depth - 1, indent + "  ")
    end
  end
  line
end

# `--chain` loads the file the way the dump does, then prints the parent chain of the
# types the gate names. The prelude is loaded by the file's own require.
if ARGV[0]? == "--chain"
  chain_path = ARGV[1]? || abort("usage: selfhost_semantic_declarations_oracle --chain <file.iyi>")
  chain_entry = File.expand_path(chain_path)
  chain_compiler = Iyi::Compiler.new
  chain_program, chain_node = chain_compiler.declarations_program(Iyi::Compiler::Source.new(chain_entry, File.read(chain_entry)))
  chain_node.accept(Iyi::TopLevelVisitor.new(chain_program))
  ["Nil", "Object", "Reference", "Value", "Int32", "String", "Mine"].each do |name|
    if t = chain_program.types[name]?
      print chain_show(t, 4, "")
    else
      print "#{name} missing\n"
    end
  end
  ["Object", "Mine", "Int32"].each do |name|
    if (t = chain_program.types[name]?) && t.is_a?(Iyi::ModuleType)
      print chain_show(t.metaclass, 4, "")
    end
  end
  exit 0
end

# `--link-annotations` loads the file the way the dump does, then prints the `@[Link]`
# annotations the lib named LibA records, one line each, in the order they were recorded.
# The port's `--link-annotations` pin prints the same lines.
if ARGV[0]? == "--link-annotations"
  link_path = ARGV[1]? || abort("usage: selfhost_semantic_declarations_oracle --link-annotations <file.iyi>")
  link_entry = File.expand_path(link_path)
  link_compiler = Iyi::Compiler.new
  link_program, link_node = link_compiler.declarations_program(Iyi::Compiler::Source.new(link_entry, File.read(link_entry)))
  link_node.accept(Iyi::TopLevelVisitor.new(link_program))
  if (link_lib = link_program.types["LibA"]?) && link_lib.is_a?(Iyi::LibType)
    (link_lib.link_annotations || [] of Iyi::LinkAnnotation).each do |rec|
      print "link lib=#{rec.lib || "-"} ldflags=#{rec.ldflags || "-"} static=#{rec.static?} framework=#{rec.framework || "-"} pkg_config=#{rec.pkg_config || "-"} dll=#{rec.dll || "-"}\n"
    end
  end
  exit 0
end

if ARGV[0]? == "--lib-starstar"
  path = File.expand_path(ARGV[1])
  compiler = Iyi::Compiler.new
  program, node = compiler.declarations_program(Iyi::Compiler::Source.new(path, File.read(path)))
  node.accept(Iyi::TopLevelVisitor.new(program))
  Iyi::TypeDeclarationProcessor.new(program).process(node)
  library = program.types["LibBytes"].as(Iyi::LibType)
  ["raw", "wrapped"].each do |name|
    external = library.defs.not_nil![name].first.def
    puts "lib LibBytes.#{name}: #{external.args.map(&.type).join(", ")} -> #{external.type}"
  end
  exit 0
end

if ARGV[0]? == "--enum-annotations"
  path = File.expand_path(ARGV[1])
  compiler = Iyi::Compiler.new
  program, node = compiler.declarations_program(Iyi::Compiler::Source.new(path, File.read(path)))
  node.accept(Iyi::TopLevelVisitor.new(program))
  ["MarkedEnum", "PlainEnum"].each do |name|
    enum_type = program.types[name].as(Iyi::EnumType)
    puts "#{name} Flags=#{!enum_type.annotation(program.flags_annotation).nil?}"
  end
  exit 0
end

if ARGV[0]? == "--enum-primitives"
  path = File.expand_path(ARGV[1])
  compiler = Iyi::Compiler.new
  program, node = compiler.declarations_program(Iyi::Compiler::Source.new(path, File.read(path)))
  node.accept(Iyi::TopLevelVisitor.new(program))
  ["SmallEnum", "WideEnum"].each do |name|
    enum_type = program.types[name].as(Iyi::EnumType)
    [enum_type.defs.not_nil!["value"].first.def, enum_type.metaclass.as(Iyi::ModuleType).defs.not_nil!["new"].first.def].each do |definition|
      primitive = definition.body.as(Iyi::Primitive)
      restriction = definition.args.empty? ? "-" : definition.args[0].restriction.to_s
      puts "#{name} #{definition.name} #{primitive.name} #{primitive.type} #{restriction}"
    end
  end
  exit 0
end

if ARGV[0]? == "--def-owner"
  path = File.expand_path(ARGV[1])
  compiler = Iyi::Compiler.new
  program, node = compiler.declarations_program(Iyi::Compiler::Source.new(path, File.read(path)))
  node.accept(Iyi::TopLevelVisitor.new(program))
  base = program.types["OwnerBase"].as(Iyi::ModuleType)
  instance_def = base.defs.not_nil!["inherited"].first.def
  class_def = base.metaclass.as(Iyi::ModuleType).defs.not_nil!["class_method"].first.def
  puts "instance #{instance_def.owner}"
  puts "class #{class_def.owner}"
  exit 0
end

if ARGV[0]? == "--virtual-subtype"
  path = File.expand_path(ARGV[1])
  compiler = Iyi::Compiler.new
  program, node = compiler.declarations_program(Iyi::Compiler::Source.new(path, File.read(path)))
  node.accept(Iyi::TopLevelVisitor.new(program))
  base = program.types["SubtypeNode"].as(Iyi::ClassType)
  leaf = program.types["SubtypeLeaf"].as(Iyi::ClassType)
  other = program.types["SubtypeOther"].as(Iyi::ClassType)
  virtual = base.virtual_type
  virtual_meta = virtual.metaclass
  puts "leaf virtual #{leaf.implements?(virtual)}"
  puts "base virtual #{base.implements?(virtual)}"
  puts "other virtual #{other.implements?(virtual)}"
  puts "virtual leaf #{virtual.implements?(leaf)}"
  puts "leaf meta virtual #{leaf.metaclass.implements?(virtual_meta)}"
  puts "other meta virtual #{other.metaclass.implements?(virtual_meta)}"
  puts "virtual meta leaf #{virtual_meta.implements?(leaf.metaclass)}"
  exit 0
end

typed_mode = ARGV[0]? == "--typed"
path = (typed_mode ? ARGV[1]? : ARGV[0]?) || abort("usage: selfhost_semantic_declarations_oracle [--typed] <file.iyi>")
entry = File.expand_path(path)
buffer = IO::Memory.new
begin
  compiler = Iyi::Compiler.new
  program, node = compiler.declarations_program(Iyi::Compiler::Source.new(entry, File.read(entry)))
  dump_declarations(node, buffer, program, entry, typed_mode)
rescue ex : Exception
  first_line = ex.message.to_s.lines.first? || ""
  STDERR.puts "ERROR: #{first_line}"
  exit 2
end
print buffer.to_s
