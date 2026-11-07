# iyi: inlay hints, off the typed graph. Three kinds, all facts the
# compiler already established and the source merely omits:
#
#   x = parse(input)        →  x: Parser::Result = parse(input)
#   move(3, 7)              →  move(x: 3, y: 7)
#   g.spawn { sum(part) }   →  g.spawn in a unit of its own { sum(part) }
#   g.spawn { log << 1 }    →  g.spawn in its spawner's unit: the block captures `log : Array(Int32)`, which is not Share { log << 1 }
#
# A type hint lands after a bare assignment's target — an assignment
# that spells its type already says it. A parameter hint lands before a
# positional literal argument — a variable passed by name documents
# itself, a bare `3` does not. A spawn hint lands after a plain `spawn`,
# saying which unit the compiler decided the task runs in (SPEC.md
# III.4.15, III.4.18): `in a unit of its own`, or `in its spawner's
# unit: ` and the first clause of what kept it there, with the whole
# reason and what a unit is as the hint's tooltip. A spawn that spells
# its placement, `unit: :new`, `unit: :same` or `in: u`, is hinted
# nothing: the text says it. Instantiations dedupe by position: a generic
# def typed many ways is still one line of source, and a spawn one of
# whose instantiations stays in its unit is hinted as staying.
require "../syntax/ast"
require "../compiler"
require "../tools/typed_def_processor"

module Iyi::Lsp
  class InlayVisitor < Visitor
    include TypedDefProcessor

    KIND_NOTE      = 0
    KIND_TYPE      = 1
    KIND_PARAMETER = 2

    # line/column are iyi's 1-based units, naming the insertion point. A
    # note has no LSP kind, and may carry a tooltip.
    record Hint, line : Int32, column : Int32, label : String, kind : Int32, tooltip : String? = nil

    getter hints = [] of Hint
    @seen = Set({Int32, Int32, String}).new

    # TypedDefProcessor wants a target to name the file module; the
    # hints themselves filter by @file and the line range.
    @target_location : Location

    def initialize(@file : String, @from_line : Int32, @to_line : Int32)
      @target_location = Location.new(@file, @from_line, 1)
    end

    # Var names already hinted in the def being walked: only a
    # variable's *first* assignment is its declaration, and the
    # declaration is the one place a type hint informs rather than
    # nags.
    @scope_vars = Set(String).new

    # The program's cleanup, which judges each spawn (`spawn_reason_for`),
    # and the def being walked, whose `self` a spawn's block may capture;
    # and each spawn's verdict by where its hint goes.
    @program : Program?
    @in_def : Def?
    @spawns = {} of {Int32, Int32} => String?

    def process(result : Compiler::Result) : Array(Hint)
      @program = result.program
      process_result result
      @scope_vars.clear
      @in_def = nil
      result.node.accept self
      @spawns.each do |(line, column), reason|
        label = reason ? "in its spawner's unit: #{InlayVisitor.spawn_clause(reason)}" : "in a unit of its own"
        tooltip = reason ? "#{reason}\n\n#{UNIT_DEFINITION}" : "#{PARALLEL_TOOLTIP}\n\n#{UNIT_DEFINITION}"
        @hints << Hint.new(line, column, label, KIND_NOTE, tooltip)
      end
      hints.sort_by! { |hint| {hint.line, hint.column} }
      hints
    end

    # What a unit is, under every spawn hint's reason (SPEC.md III.4.18).
    UNIT_DEFINITION = "A unit is a set of tasks of which at most one runs at any instant, and which switch only where one parks: " \
                      "its tasks may share values that are not Share. A spawn runs in its spawner's unit, in a unit of its own, " \
                      "or in a `Unit` it names (SPEC.md III.4.18)."

    # Why a spawn runs in a unit of its own, the compiler's words for it.
    PARALLEL_TOOLTIP = "Every capture is Share, and nothing it reaches is module state that is not, so the compiler runs it " \
                       "in a unit of its own, in parallel with its spawner (SPEC.md III.4.15)."

    # The reason's first clause, which is what a reader scanning the line
    # wants - what is captured or reached, and that it is not Share - and
    # not the chain after it, which the tooltip carries: everything before
    # its first ": " outside backticks (`log : Array(Int32)` is a name and
    # its type, not a clause's end), past a leading "line N: ", and cut at
    # a word near 100 characters.
    def self.spawn_clause(reason : String) : String
      body = reason
      lead = ""
      if body.starts_with?("line ") && (colon = body.index(": ")) && body[5...colon].to_i?
        lead = body[0, colon + 2]
        body = body[(colon + 2)..]
      end
      quoted = false
      ends = body.size
      body.each_char_with_index do |char, index|
        quoted = !quoted if char == '`'
        if !quoted && char == ':' && body[index + 1]? == ' '
          ends = index
          break
        end
      end
      clause = body[0, ends]
      if clause.size > 100
        cut = clause.rindex(' ', 100) || 100
        clause = "#{clause[0, cut]}…"
      end
      lead + clause
    end

    def process_typed_def(typed_def : Def) : Nil
      @scope_vars.clear
      @in_def = typed_def
      typed_def.accept self
    end

    def visit(node : Assign)
      target = node.target
      if target.is_a?(Var) && (location = target.location)
        first = @scope_vars.add?(target.name)
        # A literal's type is on the screen already; hinting `x = 0`
        # with `: Int32` is noise wearing information's clothes.
        if first && !literal?(node.value) && wanted?(location) && (type = target.type?)
          add location.line_number,
            location.column_number + target.name.size,
            ": #{PrettyTypeNameJsonConverter.pretty_type_name(type)}",
            KIND_TYPE
        end
      end
      true
    end

    def visit(node : Call)
      defs = node.target_defs
      spawn_hint(node, defs) if defs && defs.size == 1
      # Parentheses are the gate: `f(3)` earns a parameter name,
      # `a % b` and a paren-less `puts x` read as prose already —
      # an operator wearing `other:` was this rule's discovery.
      if defs && defs.size == 1 && !node.expansion? && node.has_parentheses?
        params = defs.first.args
        node.args.each_with_index do |arg, index|
          break if index >= params.size
          next unless literal?(arg)
          location = arg.location
          next unless location && wanted?(location)
          name = params[index].external_name
          next if name.empty? || name.starts_with?('_')
          add location.line_number, location.column_number, "#{name}:", KIND_PARAMETER
        end
      end
      true
    end

    # A `g.spawn`: one verdict per place, one kept in its spawner's unit
    # winning over one in a unit of its own from another instantiation.
    private def spawn_hint(node : Call, defs : Array(Def)) : Nil
      return unless CleanupTransformer.spawn_def?(defs.first)
      program = @program
      location = node.name_location
      return unless program && location && wanted?(location)
      key = {location.line_number, location.column_number + "spawn".size}
      return if @spawns[key]?
      @spawns[key] = program.cleanup_transformer.spawn_reason_for(node, @in_def)
    end

    def visit(node)
      true
    end

    private def literal?(node : ASTNode) : Bool
      node.is_a?(NumberLiteral) || node.is_a?(StringLiteral) ||
        node.is_a?(CharLiteral) || node.is_a?(BoolLiteral) ||
        node.is_a?(NilLiteral) || node.is_a?(SymbolLiteral)
    end

    private def wanted?(location : Location) : Bool
      location.filename == @file &&
        location.line_number >= @from_line &&
        location.line_number <= @to_line
    end

    private def add(line : Int32, column : Int32, label : String, kind : Int32) : Nil
      @hints << Hint.new(line, column, label, kind) if @seen.add?({line, column, label})
    end
  end
end
