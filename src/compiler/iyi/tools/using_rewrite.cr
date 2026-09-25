# iyi: `iyi fix`'s rewrite of `using`, the keyword one `import` replaced
# (SPEC.md R-2b).
#
#     using app/greeter              ->  import app/greeter::*
#     using app/greeter::{polite}    ->  import app/greeter::{polite}
#
# and a bare `import app/greeter` of the same module, in the same scope,
# takes the names itself - the pair was one path written twice, and the
# rewrite leaves it written once, where the import was. A `pub import` is
# never folded: it hands the module on, and names in scope do not travel,
# so the two stay two lines.
#
# The file is read by the parser itself (`Parser#iyi_reads_using`), so a
# `using` is found where the language finds one and nowhere else - never
# in a string, a comment or a heredoc - and each edit is the node's own
# span. Running it on its own output changes nothing.
require "../syntax/parser"

module Iyi
  module UsingRewrite
    record Edit, line : Int32, column : Int32, from : String, to : String

    # *text* with every `using` rewritten, and the edits that did it; nil
    # when the file has no `using`, or does not parse for another reason -
    # which the compile after says.
    def self.rewrite(text : String, filename : String) : {String, Array(Edit)}?
      return nil unless text.includes?("using")
      parser = Parser.new(text)
      parser.filename = filename
      parser.iyi_reads_using = true
      parser.iyi_source_only = true
      nodes = parser.parse

      # One scope at a time: the file's top level, and each type's body.
      scopes = [] of Array(ASTNode)
      collect_scopes(nodes, scopes, top: true)
      return nil unless scopes.any?(&.any?(UsingDecl))

      starts = [0]
      text.each_char_with_index { |char, index| starts << index + 1 if char == '\n' }
      # {from, to, replacement}: character offsets, `to` exclusive.
      spans = [] of {Int32, Int32, String}
      edits = [] of Edit
      scopes.each do |scope|
        bare = {} of String => ImportDecl
        scope.each do |node|
          next unless node.is_a?(ImportDecl) && !node.exported && !node.scopes?
          bare[node.path.join('/')] ||= node
        end
        scope.each do |node|
          next unless node.is_a?(UsingDecl)
          written = node.path.join('/')
          now = node.names.try { |names| "import #{written}::{#{names.join(", ")}}" } || "import #{written}::*"
          from, to = span(text, starts, node)
          if alone_on_line?(text, from, to) && (bare_import = bare.delete(written))
            # The import takes the names; the `using` goes, and its line
            # with it when nothing else is on it.
            import_from, import_to = span(text, starts, bare_import)
            spans << {import_from, import_to, now}
            spans << removal(text, from, to)
          else
            spans << {from, to, now}
          end
          location = node.location.not_nil!
          edits << Edit.new(location.line_number, location.column_number, text[from...to], now)
        end
      end

      spans = close_gaps(text, spans.sort_by!(&.[0]))
      rewritten = String.build do |io|
        at = 0
        spans.each do |(from, to, replacement)|
          io << text[at...from] << replacement
          at = to
        end
        io << text[at..]
      end
      {rewritten, edits.sort_by! { |edit| {edit.line, edit.column} }}
    rescue CodeError
      nil
    end

    private def self.collect_scopes(node : ASTNode, into : Array(Array(ASTNode)), top : Bool) : Nil
      list = node.is_a?(Expressions) ? node.expressions : [node] of ASTNode
      scope = [] of ASTNode
      list.each do |child|
        inner = child.is_a?(VisibilityModifier) ? child.exp : child
        case inner
        when ModuleDef
          # A module header's body is the file's own scope; a type's is its own.
          if inner.iyi_unit?
            body = inner.body
            (body.is_a?(Expressions) ? body.expressions : [body]).each do |item|
              nested = item.is_a?(VisibilityModifier) ? item.exp : item
              if nested.is_a?(ClassDef) || nested.is_a?(ModuleDef)
                collect_scopes(nested.body, into, top: false)
              end
              scope << item
            end
          else
            collect_scopes(inner.body, into, top: false)
          end
        when ClassDef
          collect_scopes(inner.body, into, top: false)
        else
          scope << inner
        end
      end
      into << scope
    end

    # The node's characters, from its first to its last: the parser's end
    # location can run past the line into the whitespace after it.
    private def self.span(text : String, starts : Array(Int32), node : ASTNode) : {Int32, Int32}
      first = node.location.not_nil!
      last = node.end_location.not_nil!
      from = starts[first.line_number - 1] + first.column_number - 1
      to = Math.min(starts[last.line_number - 1] + last.column_number, text.size)
      while to > from && text[to - 1].whitespace?
        to -= 1
      end
      {from, to}
    end

    # Lines removed one after another are one block, and a block that
    # stood between two blank lines takes one of them with it: the
    # `using` lines of a header sat between the imports and the code, a
    # blank line on each side, and removing them left two.
    private def self.close_gaps(text : String, spans : Array({Int32, Int32, String})) : Array({Int32, Int32, String})
      merged = [] of {Int32, Int32, String}
      spans.each do |span|
        last = merged.last?
        if last && last[2].empty? && span[2].empty? && last[1] == span[0]
          merged[-1] = {last[0], span[1], ""}
        else
          merged << span
        end
      end
      merged.map do |(from, to, replacement)|
        whole_lines = replacement.empty? && (from == 0 || text[from - 1] == '\n') && to > 0 && text[to - 1] == '\n'
        blank_before = from == 0 || (from >= 2 && text[from - 2] == '\n')
        if whole_lines && blank_before && text[to]? == '\n'
          {from, to + 1, replacement}
        else
          {from, to, replacement}
        end
      end
    end

    # Whether the span is the only thing on its line. A `using` with a
    # comment after it is rewritten where it stands, so the comment keeps
    # the line it was written on.
    private def self.alone_on_line?(text : String, from : Int32, to : Int32) : Bool
      line_start, line_end = line_around(text, from, to)
      text[line_start...from].blank? && text[to...line_end].blank?
    end

    private def self.line_around(text : String, from : Int32, to : Int32) : {Int32, Int32}
      line_start = from
      while line_start > 0 && text[line_start - 1] != '\n'
        line_start -= 1
      end
      line_end = to
      while line_end < text.size && text[line_end] != '\n'
        line_end += 1
      end
      {line_start, line_end}
    end

    # The span's whole line, newline included: only asked of one alone on it.
    private def self.removal(text : String, from : Int32, to : Int32) : {Int32, Int32, String}
      line_start, line_end = line_around(text, from, to)
      {line_start, Math.min(line_end + 1, text.size), ""}
    end
  end
end
