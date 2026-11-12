# The oracle for the semantic port's first slice: what a file *declares*.
#
# The parser answers what a file says; the top-level pass answers what it
# brings into being. That is the first question with an answer small enough
# to diff and large enough to be worth diffing: for each type the file
# declares, its kind, its path, its type parameters, and the methods and
# associated types on it.
#
# Not inference, not overload resolution, not a single expression's type.
# Those come after, and each gets its own slice and its own oracle, because
# a port checked against "the whole semantic pass" is checked against
# nothing anyone can read.
#
# The pass runs on the file alone, with no imports resolved, which is why
# 23 of the 27 samples answer and four do not: `collections`, `immutable`,
# `std_text` and `webapp` declare types whose bodies name something an
# import brings. Those four are the measure of what resolving imports
# would add, and they are left failing rather than skipped, so the number
# says so.
# `compiler/requires` is what the specs load, and it is the set that
# brings the semantic pass up with its dependencies in order.
require "compiler/requires"

private def kind_of(type) : String
  case type
  when Iyi::TraitType            then "trait"
  when Iyi::NonGenericClassType  then type.struct? ? "struct" : "class"
  when Iyi::GenericClassType     then type.struct? ? "struct" : "class"
  when Iyi::NonGenericModuleType then "module"
  when Iyi::GenericModuleType    then "module"
  when Iyi::EnumType             then "enum"
  else                                type.class.name.split("::").last.downcase
  end
end

# The names a program declared, as opposed to the ones its prelude did.
# Everything here comes from one file, so anything with a location in that
# file is the file's and everything else is furniture.
#
# The walk goes through every type, not only the ones this file located. A
# module can be declared by an import and nested into by this file:
# `module std/bzip2` nests `Std::Bzip2` under the `Std` that `std/int`
# declared first, so `Std` is located in `int.iyi` and the types the file
# declares are under it. Only what this file located is reported.
private def located_in?(type, path : String) : Bool
  locs = type.locations
  return false if locs.nil? || locs.empty?
  locs.any? { |l| (f = l.filename).is_a?(String) && File.expand_path(f) == File.expand_path(path) }
end

private def declared_in(type, path : String, found : Array(String), seen : Set(UInt64)) : Nil
  type.types?.try &.each_value do |nested|
    next unless nested.responds_to?(:locations)
    next if seen.includes?(nested.object_id)
    seen << nested.object_id
    if located_in?(nested, path)
      # `responds_to?` is not enough: a non-generic type answers it and then
      # raises "doesn't implement type_vars" when asked, so the question has
      # to be about the type's kind rather than its method set.
      vars = ""
      if nested.is_a?(Iyi::GenericType)
        tv = nested.type_vars
        vars = "(#{tv.join(" ")})" unless tv.empty?
      end

      methods = [] of String
      nested.defs.try &.each do |name, defs|
        methods << name.to_s if defs.any? { |d| (loc = d.def.location) && (f = loc.filename).is_a?(String) && File.expand_path(f) == File.expand_path(path) }
      end
      methods.sort!.uniq!

      found << "(#{kind_of(nested)} #{nested.to_s}#{vars} (defs #{methods.join(" ")}))"
    end
    declared_in(nested, path, found, seen)
  end
end

# The compile's own sequence, up to the top-level pass, reached from outside the
# class because `parse` and `new_program` are private to the compiler. An entry
# is the prelude followed by the file, as a compile builds an entry file. A file
# of the prelude itself is the prelude alone, since it cannot be an entry: it
# redefines the prelude's own methods.
class Iyi::Compiler
  def declare_program(source : Iyi::Compiler::Source, prelude_only : Bool) : Program
    program = new_program([source])
    node = if prelude_only
             location = Iyi::Location.new(program.filename, 1, 1)
             program.normalize(Iyi::Expressions.new([Iyi::Require.new(prelude).tap(&.iyi_prelude=(true)).at(location)] of Iyi::ASTNode))
           else
             parse(program, [source])
           end
    node, processor = program.top_level_semantic(node)
    program.semantic_after_top_level(node, processor, cleanup: false)
    program
  end
end

path = ARGV[0]
# Only the compiler's own prelude, `src/iyi`, is the prelude. A sample in
# `samples/iyi` shares the directory name and is an entry like any other.
prelude_dir = File.dirname(path)
prelude_only = File.basename(prelude_dir) == "iyi" && File.basename(File.dirname(prelude_dir)) == "src"
compiler = Iyi::Compiler.new
compiler.prelude = "iyi/prelude"
compiler.no_codegen = true
compiler.stdout = IO::Memory.new
compiler.stderr = IO::Memory.new

begin
  source = Iyi::Compiler::Source.new(path, File.read(path))
  program = compiler.declare_program(source, prelude_only)
  found = [] of String
  declared_in(program, path, found, Set(UInt64).new)
  STDERR.puts "compiler: the top-level pass declares no type in this file" if found.empty?
  puts found.sort.join(" ")
rescue error
  # The compile refused the file. The first line of its message goes to stderr,
  # and the gate prints it beside the file rather than as a difference.
  STDERR.puts "compiler: #{error.message.to_s.lines.first? || ""}"
end
