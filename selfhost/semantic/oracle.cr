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
# 24 of the 27 samples answer and three do not: `collections`, `immutable`
# and `webapp` declare types whose bodies name something an import brings.
# Those three are the measure of what resolving imports would add, and
# they are left failing rather than skipped, so the number says so.
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
private def declared_in(type, path : String, found : Array(String)) : Nil
  type.types?.try &.each_value do |nested|
    next unless nested.responds_to?(:locations)
    locs = nested.locations
    next if locs.nil? || locs.empty?
    next unless locs.any? { |l| l.filename == path }

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
      defs.each { |_| methods << name.to_s }
    end
    methods.sort!.uniq!

    found << "(#{kind_of(nested)} #{nested.to_s}#{vars} (defs #{methods.join(" ")}))"
    declared_in(nested, path, found)
  end
end

path = ARGV[0]
source = File.read(path)

parser = Iyi::Parser.new(source)
parser.filename = path
node = parser.parse

program = Iyi::Program.new
program.filename = path
node = program.normalize(node)
program.top_level_semantic(node)

found = [] of String
declared_in(program, path, found)
puts found.sort.join(" ")
