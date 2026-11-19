# Cast upcast oracle for bench/selfhost_semantic_type_nodes_exercise.sh.
#
#   selfhost_cast_upcast_oracle <file.iyi> --bare
#
# Prints one line per cast node (`x.as(T)` and `x.as?(T)`) of <file.iyi> that the
# full semantic pass typed, as "<line>:<col> <Kind> <type> upcast=<true|false>", in
# tree order. The program is the file alone, with no prelude, as the typed-node
# fixtures are compared. The port's dump (bench/selfhost_cast_upcast_dump.iyi)
# prints the same lines. Kept apart from bench/selfhost_typed_oracle.cr so that the
# typed parity gate's output does not change.
require "compiler/requires"

class Iyi::Compiler
  # iyi: the compile's own sequence (parse, top-level pass, main pass) for a file
  # with no prelude, reached from outside the class because `parse` and
  # `new_program` are private to the compiler.
  def cast_upcast_program(source : Iyi::Compiler::Source) : {Program, ASTNode}
    program = new_program([source])
    node = program.normalize(parse(program, source))
    node, processor = program.top_level_semantic(node)
    node = program.semantic_after_top_level(node, processor, cleanup: false)
    {program, node}
  end
end

class CastUpcastWalk < Iyi::Visitor
  getter lines = [] of String

  # Locations name a file as the compile reached it: compare absolute paths.
  def initialize(@file : String, @root : Iyi::ASTNode)
    @absolute = File.expand_path(@file)
  end

  # A require carries the tree of the file it loaded as `expanded`, which the
  # children walk does not reach, so the walk enters it here.
  def visit_any(node)
    return true if node.object_id == @root.object_id
    if node.is_a?(Iyi::Require)
      if expanded = node.expanded
        expanded.accept(self)
      end
      return true if node.iyi_prelude?
    end
    if (node.is_a?(Iyi::Cast) || node.is_a?(Iyi::NilableCast)) && (loc = node.location) && (name = loc.filename).is_a?(String) && File.expand_path(name) == @absolute && (t = node.type?)
      type_str = (t.is_a?(Iyi::NamedType) ? t.full_name : t.to_s).sub(/^::/, "")
      kind = node.is_a?(Iyi::NilableCast) ? "NilableCast" : "Cast"
      upcast = node.is_a?(Iyi::NilableCast) ? node.as(Iyi::NilableCast).upcast? : node.as(Iyi::Cast).upcast?
      @lines << "#{loc.line_number}:#{loc.column_number} #{kind} #{type_str} upcast=#{upcast}"
    end
    true
  end

  def visit(node)
    true
  end
end

path = ARGV.find { |arg| !arg.starts_with?("--") } || abort("usage: selfhost_cast_upcast_oracle <file.iyi> --bare")

begin
  compiler = Iyi::Compiler.new
  compiler.prelude = "iyi/prelude"
  compiler.no_codegen = true
  compiler.stdout = IO::Memory.new
  compiler.stderr = IO::Memory.new
  source = Iyi::Compiler::Source.new(path, File.read(path))
  _, node = compiler.cast_upcast_program(source)
  walk = CastUpcastWalk.new(path, node)
  node.accept(walk)
  walk.lines.each { |line| puts line }
rescue ex : Exception
  STDERR.puts "ERROR: #{ex.message.to_s.lines.first? || ""}"
  exit 2
end
