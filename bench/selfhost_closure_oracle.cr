# Closure facts from the hosted semantic pass with the fixture prelude.
require "compiler/requires"

class Iyi::Compiler
  def closure_oracle_program(source : Iyi::Compiler::Source) : {Program, ASTNode}
    program = new_program([source])
    node = parse(program, [source])
    node, processor = program.top_level_semantic(node)
    node = program.semantic_after_top_level(node, processor, cleanup: false)
    {program, node}
  end
end

class ClosureOracleWalk < Iyi::Visitor
  getter lines = [] of String

  def initialize(@file : String)
    @absolute = File.expand_path(@file)
    @instance = "top"
    @visited = Set(UInt64).new
  end

  private def label(type : Iyi::Type) : String
    (type.is_a?(Iyi::NamedType) ? type.full_name : type.to_s).sub(/^::/, "")
  end

  private def emit(node : Iyi::ASTNode, kind : String, vars : Iyi::MetaVars?, closure : String, self_closured : String) : Nil
    loc = node.location
    return unless loc && (filename = loc.filename).is_a?(String) && File.expand_path(filename) == @absolute
    captured = [] of String
    mutable = [] of String
    if vars
      vars.each do |name, var|
        if var.closure_in?(node) && (type = var.type?)
          captured << "#{name}:#{label(type)}"
          mutable << name if var.mutably_closured?
        end
      end
    end
    @lines << "#{loc.line_number}:#{loc.column_number} #{kind} in #{@instance} closure=#{closure} self=#{self_closured} vars=#{captured.join(",")} mut=#{mutable.join(",")}"
  end

  private def bit(value : Bool) : String
    value ? "1" : "0"
  end

  def visit(node : Iyi::ASTNode) : Bool
    true
  end

  def visit(node : Iyi::Def) : Bool
    false
  end

  def visit(node : Iyi::Call) : Bool
    if defs = node.target_defs
      defs.each do |target|
        next unless @visited.add?(target.object_id)
        prior = @instance
        owner = target.owner
        # External lib funs have no body or lexical frame.
        next if owner.is_a?(Iyi::LibType)
        owner_name = owner.is_a?(Iyi::Program) ? "top" : label(owner)
        args = target.args.map { |arg| arg.type?.try { |type| label(type) } || "?" }.join(",")
        @instance = "#{owner_name}##{target.name}(#{args})"
        emit(target, "Def", target.vars, bit(target.closure?), bit(target.self_closured?))
        target.body.accept(self)
        @instance = prior
      end
    end
    true
  end

  def visit(node : Iyi::Block) : Bool
    if vars = node.vars
      emit(node, "Block", vars, "-", "-")
    end
    if literal = node.fun_literal
      literal.accept(self)
      false
    else
      true
    end
  end

  def visit(node : Iyi::ProcLiteral) : Bool
    literal_def = node.def
    emit(literal_def, "Proc", literal_def.vars, bit(literal_def.closure?), "-")
    literal_def.body.accept(self)
    false
  end
end

path = ARGV[0]? || abort("usage: selfhost_closure_oracle <file.iyi>")
begin
  compiler = Iyi::Compiler.new
  compiler.prelude = "iyi/prelude"
  compiler.no_codegen = true
  compiler.stdout = IO::Memory.new
  compiler.stderr = IO::Memory.new
  source = Iyi::Compiler::Source.new(path, File.read(path))
  _, root = compiler.closure_oracle_program(source)
  walk = ClosureOracleWalk.new(path)
  root.accept(walk)
  walk.lines.sort.uniq.each { |line| puts line }
rescue ex : Exception
  STDERR.puts "ERROR: #{ex.inspect_with_backtrace}"
  exit 2
end
