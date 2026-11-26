# Typed bodies of reachable method instances in one fixture. The existing
# typed oracle walks the entry AST, whose original Def bodies are not typed;
# Call#target_defs instead points at the specialized, typed clones.
require "compiler/requires"

class Iyi::Compiler
  def typed_bodies_program(source : Iyi::Compiler::Source, bare : Bool) : Iyi::ASTNode
    program = new_program([source])
    node = if bare
             program.normalize(parse(program, source))
           else
             parse(program, [source])
           end
    node, processor = program.top_level_semantic(node)
    program.semantic_after_top_level(node, processor, cleanup: false)
  end
end

def body_type_label(type : Iyi::Type) : String
  (type.is_a?(Iyi::NamedType) ? type.full_name : type.to_s).sub(/^::/, "")
end

class BodyNodeWalk < Iyi::Visitor
  getter lines = [] of String

  def initialize(@file : String, @signature : String)
  end

  def visit_any(node)
    if (loc = node.location) && (name = loc.filename).is_a?(String) && File.expand_path(name) == @file && (type = node.type?)
      kind = node.class.name.sub(/^Iyi::/, "")
      @lines << "#{@signature}|#{loc.line_number}:#{loc.column_number} #{kind} #{body_type_label(type)}"
    end
    true
  end

  def visit(node)
    true
  end
end

class BodyDiscovery < Iyi::Visitor
  getter lines = [] of String
  getter instances = 0

  def initialize(file : String)
    @file = File.expand_path(file)
    @seen = Set(Iyi::Def).new.compare_by_identity
  end

  def visit(node : Iyi::Call)
    node.target_defs.try &.each do |definition|
      next unless @seen.add?(definition)
      loc = definition.location
      if loc && (name = loc.filename).is_a?(String) && File.expand_path(name) == @file
        args = definition.args.map { |arg| arg.type?.try { |type| body_type_label(type) } || "?" }.join(",")
        signature = "#{loc.line_number}:#{loc.column_number} #{definition.name}(#{args})"
        walk = BodyNodeWalk.new(@file, signature)
        definition.body.accept(walk)
        @instances += 1
        @lines.concat(walk.lines)
      end
      definition.body.accept(self)
    end
    true
  end

  def visit(node)
    true
  end
end

path = ARGV.find { |arg| !arg.starts_with?("-") } || abort("usage: selfhost_typed_bodies_oracle [--bare] file.iyi")
begin
  compiler = Iyi::Compiler.new
  compiler.flags.concat((ENV["IYI_TYPED_ORACLE_FLAGS"]? || "").split)
  compiler.prelude = "iyi/prelude"
  compiler.no_codegen = true
  compiler.stdout = IO::Memory.new
  compiler.stderr = IO::Memory.new
  source = Iyi::Compiler::Source.new(path, File.read(path))
  node = compiler.typed_bodies_program(source, ARGV.includes?("--bare"))
  discovery = BodyDiscovery.new(path)
  node.accept(discovery)
  discovery.lines.each { |line| puts line }
  STDERR.puts "instances: #{discovery.instances}"
rescue ex : Exception
  STDERR.puts "ERROR: #{ex.message.to_s.lines.first? || ""}"
  exit 2
end
