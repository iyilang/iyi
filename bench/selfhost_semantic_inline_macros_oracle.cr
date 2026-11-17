# Declaration oracle for bench/selfhost_semantic_inline_macros_exercise.sh.
#
#   selfhost_semantic_inline_macros_oracle <file.iyi>
#
# The same analysis and dump form as bench/selfhost_semantic_declarations_oracle.cr
# (the compile's own front end, bare, with the prelude and the closure of what the
# file imports and requires), with two differences that this gate needs.
#
# A declaration belongs to the file when its location is the file, and also when it
# was written by an inline macro the file holds: a macro's expansion is read from a
# virtual file, and the location of what it declares leads back, through the virtual
# file, to the site in the file. The declarations gate's oracle drops those.
#
# A def the file declares on a type it does not declare (a prelude type reopened by a
# macro loop, `Int32#zero` from `number.iyi`) is printed under a record of its own,
# `Type: Int32 (reopened)`, with the defs the file declares on it. The declarations
# gate's dump prints a def only under a type header, so it cannot see these.
require "compiler/requires"

class Iyi::Compiler
  # iyi: the entry file as a build reads it, in iyi's library, with the prelude.
  def declarations_program(source : Iyi::Compiler::Source) : {Program, ASTNode}
    self.prelude = "iyi/prelude"
    program = new_program([source])
    {program, parse(program, [source])}
  end
end

# The file a location was written in, following every virtual file an inline macro
# expansion went through back to the site. Empty when there is none.
def origin_file(loc : Iyi::Location) : String
  origin = loc.read_from
  while origin.is_a?(Iyi::VirtualFile)
    origin = origin.expanded_location.try(&.read_from)
  end
  origin.is_a?(String) ? File.expand_path(origin) : ""
end

# Whether a declaration with these locations belongs to the entry file. With no
# entry (the built-in types) everything belongs.
def declared_in?(locations : Array(Iyi::Location)?, entry : String?) : Bool
  return true unless entry
  return false unless locations
  locations.any? { |loc| origin_file(loc) == entry }
end

def def_declared?(d : Iyi::Def, entry : String?) : Bool
  return true unless entry
  loc = d.location
  return false unless loc
  origin_file(loc) == entry
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

# Every def a module type holds, its own and its metaclass's (`allocate` aside), that
# the entry declares.
def entry_defs(t : Iyi::ModuleType, entry : String?) : Array(Iyi::Def)
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
  all_defs.select { |d| def_declared?(d, entry) }
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

# A type the entry does not declare, with the defs the entry declares on it: one
# record, `(reopened)`, then each def. Walks every nested type.
def dump_reopened(t : Iyi::Type, io : IO, entry : String?)
  if t.is_a?(Iyi::ModuleType) && !declared_in?(t.locations, entry)
    picked = entry_defs(t, entry)
    unless picked.empty?
      io << "Type: " << t.full_name << " (reopened)\n"
      picked.sort_by { |d| "#{d.receiver ? "self." : ""}#{d.name}" }.each do |d|
        dump_def(d, io, "  ")
      end
    end
  end

  if t.is_a?(Iyi::NamedType) && !t.is_a?(Iyi::EnumType)
    t.types.keys.sort.each do |subname|
      dump_reopened(t.types[subname], io, entry)
    end
  end
end

# One type's own record: its header and properties, its defs. Its nested types
# are dumped by `dump_type`, whether or not this type is the entry's.
def dump_type_header(t : Iyi::Type, full_name : String, io : IO, indent : String, entry : String?)
  kind = case t
         when Iyi::EnumType   then "enum"
         when Iyi::TraitType  then "trait"
         when Iyi::ClassType  then t.struct? ? "struct" : "class"
         when Iyi::LibType    then "lib"
         when Iyi::ModuleType then "module"
         when Iyi::AliasType  then "alias"
         when Iyi::Const      then "constant"
         else                      "type"
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
    # Instance variables in declaration order, then their order, as the declarations oracle prints them.
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

  if t.is_a?(Iyi::TraitType)
    if t.is_a?(Iyi::TraitSupertraits) && (st = t.supertraits) && !st.empty?
      io << indent << "  supertraits: [" << st.map(&.to_s).sort.join(", ") << "]\n"
    end
    if t.is_a?(Iyi::GenericTraitType) && !t.assoc_types.empty?
      io << indent << "  assoc_types: [" << t.assoc_types.sort.join(", ") << "]\n"
    end
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
    all_defs = entry_defs(t, entry)
    all_defs.sort_by! { |d| "#{d.receiver ? "self." : ""}#{d.name}" }
    all_defs.each do |d|
      dump_def(d, io, "#{indent}  ")
    end
  end
end

def dump_declarations(node : Iyi::ASTNode, io : IO, program : Iyi::Program, entry : String?)
  initial_types = Iyi::Program.new.types.keys.to_set
  program.top_level_semantic(node)

  if pdefs = program.defs
    top_defs = [] of Iyi::Def
    pdefs.each_value { |list| list.each { |item| top_defs << item.def } }
    top_defs = top_defs.select { |d| def_declared?(d, entry) }
    top_defs.sort_by!(&.name)
    top_defs.each do |d|
      dump_def(d, io, "")
    end
  end

  # Every top-level type is walked, as the port does: the entry filter prints what the
  # entry declares, and a namespace named like a built-in holds declarations the built-in
  # set would have hidden.
  program.types.keys.sort.each do |name|
    dump_type(program.types[name], io, "", entry)
  end

  # Every type, built-in ones included, for the defs the entry adds to a type it does not declare.
  program.types.keys.sort.each do |name|
    dump_reopened(program.types[name], io, entry)
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

path = ARGV[0]? || abort("usage: selfhost_semantic_inline_macros_oracle <file.iyi>")
entry = File.expand_path(path)
buffer = IO::Memory.new
begin
  compiler = Iyi::Compiler.new
  program, node = compiler.declarations_program(Iyi::Compiler::Source.new(entry, File.read(entry)))
  dump_declarations(node, buffer, program, entry)
rescue ex : Exception
  first_line = ex.message.to_s.lines.first? || ""
  STDERR.puts "ERROR: #{first_line}"
  exit 2
end
print buffer.to_s
