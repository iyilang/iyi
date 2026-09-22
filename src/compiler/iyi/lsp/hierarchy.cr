# iyi: the call graph, off the typed result — call hierarchy for the
# protocol, and the question agents ask most: who calls this, and what
# does this call. A node is a *written* def, keyed by its source
# location, so a generic's many instantiations collapse back to the one
# line the person wrote. Incoming answers merge across the session's
# open documents, the same way references do and for the same R-1
# reason: a def's callers live in its consumers' compiles.
require "../syntax/ast"
require "../compiler"
require "../tools/typed_def_processor"

module Iyi::Lsp
  # One def as a hierarchy node names it, in iyi's own units. `line`/
  # `column` are the def's start — the stable key every compile of the
  # same source reproduces.
  record HierarchySite,
    name : String,
    filename : String,
    line : Int32,
    column : Int32,
    name_line : Int32,
    name_column : Int32,
    name_size : Int32,
    end_line : Int32

  def self.site_of(a_def : Def) : HierarchySite?
    location = a_def.location
    return nil unless location && location.filename.is_a?(String)
    name_location = a_def.name_location || location
    HierarchySite.new(
      name: a_def.name,
      filename: location.filename.to_s,
      line: location.line_number,
      column: location.column_number,
      name_line: name_location.line_number,
      name_column: name_location.column_number,
      name_size: a_def.name.size,
      end_line: a_def.end_location.try(&.line_number) || location.line_number)
  end

  # A call site: {file, line, column, size} of the call's name.
  alias CallSite = {String, Int32, Int32, Int32}

  # prepare: the def(s) the cursor names — the def whose name it sits
  # on, or the target_defs of the call it sits on.
  class HierarchyTargetVisitor < Visitor
    include TypedDefProcessor

    getter defs = [] of Def
    @target_location : Location

    def initialize(@target_location : Location)
    end

    def process(result : Compiler::Result) : Array(Def)
      process_result result
      result.node.accept self
      defs
    end

    def process_typed_def(typed_def : Def) : Nil
      consider typed_def
      typed_def.accept self
    end

    def visit(node : Call)
      if node.location && @target_location.between?(node.name_location, node.name_end_location)
        node.target_defs.try &.each { |target| @defs << target }
      end
      true
    end

    def visit(node : Def)
      consider node
      true
    end

    def visit(node)
      true
    end

    private def consider(node : Def) : Nil
      name_location = node.name_location || node.location
      return unless name_location
      name_end = Location.new(
        name_location.filename, name_location.line_number,
        name_location.column_number + node.name.size - 1)
      @defs << node if @target_location.between?(name_location, name_end)
    end
  end

  # incoming: every call in one entry's compile that resolves to the
  # target def, grouped by the written def whose body carries it. A
  # caller of `nil` site is the file's main expressions.
  class IncomingCallsVisitor < Visitor
    include TypedDefProcessor

    getter calls = {} of {String, Int32, Int32} => {HierarchySite?, Array(CallSite)}
    @current : Def?
    @target_location : Location

    def initialize(@key : {String, Int32, Int32}, entry_file : String)
      @target_location = Location.new(entry_file, 1, 1)
    end

    def process(result : Compiler::Result) : Nil
      process_result result
      @current = nil
      result.node.accept self
    end

    def process_typed_def(typed_def : Def) : Nil
      @current = typed_def
      typed_def.accept self
      @current = nil
    end

    def visit(node : Call)
      name_location = node.name_location
      if name_location && (file = name_location.filename).is_a?(String) &&
         node.target_defs.try &.any? { |target| key?(target.location) }
        record name_location, file, node.name.size
      end
      true
    end

    def visit(node)
      true
    end

    # The file compared as a file, not a string: an importer's compile
    # names an imported def's file with the module path's `/` inside a
    # backslashed root on Windows (see `Location.same_file?`), and incoming
    # calls from a file nobody opened never matched the def they call.
    private def key?(location : Location?) : Bool
      return false unless location
      location.line_number == @key[1] && location.column_number == @key[2] &&
        Location.same_file?(location.filename.to_s, @key[0])
    end

    private def record(name_location : Location, file : String, size : Int32) : Nil
      site = @current.try { |caller| Lsp.site_of(caller) }
      group = site ? {site.filename, site.line, site.column} : {file, 0, 0}
      entry = @calls[group] ||= {site, [] of CallSite}
      entry[1] << {file, name_location.line_number, name_location.column_number, size}
    end
  end

  # outgoing: every def the target's body calls, grouped by callee.
  class OutgoingCallsVisitor < Visitor
    include TypedDefProcessor

    getter calls = {} of {String, Int32, Int32} => {HierarchySite, Array(CallSite)}
    @target_location : Location

    def initialize(@key : {String, Int32, Int32}, entry_file : String)
      @target_location = Location.new(entry_file, 1, 1)
    end

    def process(result : Compiler::Result) : Nil
      process_result result
    end

    def process_typed_def(typed_def : Def) : Nil
      location = typed_def.location
      return unless location
      return unless location.line_number == @key[1] && location.column_number == @key[2] &&
                    Location.same_file?(location.filename.to_s, @key[0])
      typed_def.accept self
    end

    def visit(node : Call)
      name_location = node.name_location
      if name_location && (file = name_location.filename).is_a?(String)
        node.target_defs.try &.each do |callee|
          site = Lsp.site_of(callee)
          next unless site
          entry = @calls[{site.filename, site.line, site.column}] ||= {site, [] of CallSite}
          entry[1] << {file, name_location.line_number, name_location.column_number, node.name.size}
        end
      end
      true
    end

    def visit(node)
      true
    end
  end

  # selectionRange: every parsed node whose span holds the position.
  # Syntax alone — expansion has to work in a buffer that does not
  # type-check, and nesting is what the parser already knows.
  class SpanCollector < Visitor
    getter spans = [] of {Location, Location}

    def initialize(@target : Location)
    end

    def visit(node)
      location = node.location
      end_location = node.end_location
      if location && end_location &&
         (file = location.filename).is_a?(String) && (target_file = @target.filename).is_a?(String) &&
         Location.same_file?(file, target_file) &&
         @target.between?(location, end_location)
        @spans << {location, end_location}
      end
      true
    end
  end
end
