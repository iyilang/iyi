# Typed-node oracle for bench/selfhost_typed_parity_exercise.sh.
#
#   selfhost_typed_oracle <file.iyi> [--bare | --prelude-only]
#
# Prints one line per expression node of <file.iyi> that the full semantic
# pass typed, as "<line>:<col> <Kind> <type>", in tree order.
#
# The program the file belongs to is chosen by the flag:
#   (default)       the prelude followed by the file, as a compile builds an
#                   entry file (`Compiler#parse` prepends the prelude and
#                   normalizes). For std, samples and the compiler's source.
#   --prelude-only  the prelude alone. The prelude's own files (src/iyi) are
#                   part of it, and they cannot be analysed as entries: they
#                   redefine the prelude's methods.
#   --bare          the file alone, with no prelude, which is the program the
#                   selfhost semantic fixtures are compared under.
#
# Not counted: the root block of the program and the prelude's own `require`,
# which the compile adds around the program and which carry no source text of
# the file. The port's dump skips the same two nodes, so the comparison is
# symmetric.
#
# Stops before codegen. The main pass runs with `cleanup: false` so the tree
# keeps the nodes it was parsed into. On failure, the first line of the
# compiler's message goes to stderr and the exit status is 2.
require "compiler/requires"

class Iyi::Compiler
  # iyi: the compile's own sequence (parse and prelude, top-level pass, main
  # pass), reached from outside the class because `parse` and `new_program`
  # are private to the compiler.
  def typed_oracle_program(source : Iyi::Compiler::Source, mode : Symbol) : {Program, ASTNode}
    program = new_program([source])
    node = case mode
           when :bare
             program.normalize(parse(program, source))
           when :prelude_only
             location = Iyi::Location.new(program.filename, 1, 1)
             program.normalize(Iyi::Expressions.new([Iyi::Require.new(prelude).tap(&.iyi_prelude=(true)).at(location)] of Iyi::ASTNode))
           else
             parse(program, [source])
           end
    node, processor = program.top_level_semantic(node)
    node = program.semantic_after_top_level(node, processor, cleanup: false)
    {program, node}
  end
end

class TypedNodeWalk < Iyi::Visitor
  getter lines = [] of String

  # Locations name a file as the compile reached it: the entry as given, and a
  # required file by its absolute path. Compare both as absolute paths.
  def initialize(@file : String, @root : Iyi::ASTNode)
    @absolute = File.expand_path(@file)
  end

  # A require carries the tree of the file it loaded as `expanded`, which the
  # children walk does not reach, so the walk enters it here. The prelude's own
  # require is the one synthetic node that is not printed.
  def visit_any(node)
    return true if node.object_id == @root.object_id
    if node.is_a?(Iyi::Require)
      if expanded = node.expanded
        expanded.accept(self)
      end
      return true if node.iyi_prelude?
    end
    if (loc = node.location) && (name = loc.filename).is_a?(String) && File.expand_path(name) == @absolute && (t = node.type?)
      type_str = (t.is_a?(Iyi::NamedType) ? t.full_name : t.to_s).sub(/^::/, "")
      kind = node.class.name.sub(/^Iyi::/, "")
      @lines << "#{loc.line_number}:#{loc.column_number} #{kind} #{type_str}"
    end
    true
  end

  def visit(node)
    true
  end
end

path = ARGV.find { |arg| !arg.starts_with?("--") } || abort("usage: selfhost_typed_oracle <file.iyi> [--bare | --prelude-only]")
mode = if ARGV.includes?("--bare")
         :bare
       elsif ARGV.includes?("--prelude-only")
         :prelude_only
       else
         :entry
       end

begin
  compiler = Iyi::Compiler.new
  compiler.prelude = "iyi/prelude"
  compiler.no_codegen = true
  compiler.stdout = IO::Memory.new
  compiler.stderr = IO::Memory.new
  source = Iyi::Compiler::Source.new(path, File.read(path))
  _, node = compiler.typed_oracle_program(source, mode)
  walk = TypedNodeWalk.new(path, node)
  node.accept(walk)
  walk.lines.each { |line| puts line }
rescue ex : Exception
  STDERR.puts "ERROR: #{ex.message.to_s.lines.first? || ""}"
  exit 2
end
