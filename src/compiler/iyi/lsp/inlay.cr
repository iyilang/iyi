# iyi: inlay hints, off the typed graph. Three kinds, all facts the
# compiler already established and the source merely omits:
#
#   x = parse(input)        →  x: Parser::Result = parse(input)
#   move(3, 7)              →  move(x: 3, y: 7)
#   g.spawn { sum(part) }   →  g.spawn parallel { sum(part) }
#
# A type hint lands after a bare assignment's target — an assignment
# that spells its type already says it. A parameter hint lands before a
# positional literal argument — a variable passed by name documents
# itself, a bare `3` does not. A spawn hint lands after `spawn`, saying
# where the compiler decided the task runs (SPEC.md III.4.14):
# `parallel`, or `in its unit` with the capture that kept it there as
# the hint's tooltip. Instantiations dedupe by position: a generic def
# typed many ways is still one line of source, and a spawn one of whose
# instantiations stays in its unit is hinted as staying.
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
        @hints << Hint.new(line, column, reason ? "in its unit" : "parallel", KIND_NOTE, reason)
      end
      hints.sort_by! { |hint| {hint.line, hint.column} }
      hints
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

    # A `g.spawn`: one verdict per place, a serial one winning over a
    # parallel one from another instantiation.
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
