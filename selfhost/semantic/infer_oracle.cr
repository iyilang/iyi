# The current compiler's answer for the first inference slice: inferred return
# types of internal methods a call actually instantiates.
#
# `top_level_semantic` only registers declarations. `semantic` performs the
# call-driven typing this oracle measures, and `def_instances` is where those
# typed method instances live. A definition that no call reaches has no row.
require "compiler/requires"

private def collect(type, path : String, rows : Array(String)) : Nil
  if type.is_a?(Iyi::DefInstanceContainer)
    type.def_instances.each_value do |typed_def|
      location = typed_def.location
      next unless location && location.filename == path
      rows << "#{type}##{typed_def.name}=#{typed_def.type?}"
    end
  end

  type.types?.try &.each_value { |inner| collect(inner, path, rows) }
  if type.is_a?(Iyi::GenericType)
    type.each_instantiated_type { |instance| collect(instance, path, rows) }
  end
  collect(type.metaclass, path, rows) if type.metaclass != type
end

path = ARGV[0]
source = File.read(path)
parser = Iyi::Parser.new(source)
parser.filename = path
node = parser.parse

program = Iyi::Program.new
program.filename = path
node = program.normalize(node)
program.semantic(node)

rows = [] of String
collect(program, path, rows)
puts rows.sort.uniq.join(" ")
