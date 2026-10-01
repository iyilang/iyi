# iyi: the file's outline, from the parser alone. No semantic pass: an
# outline has to survive a file that does not compile yet, and names and
# nesting are syntax. The walk covers exactly what iyi lets a file
# declare at type scope — anything else has no name to list.
require "../syntax/ast"
require "../syntax/parser"

module Iyi::Lsp
  module Outline
    # LSP SymbolKind, by name rather than by memory.
    KIND_MODULE   =  2
    KIND_CLASS    =  5
    KIND_METHOD   =  6
    KIND_ENUM     = 10
    KIND_TRAIT    = 11 # Interface
    KIND_FUNCTION = 12
    KIND_CONSTANT = 14
    KIND_STRUCT   = 23

    record Sym,
      name : String,
      kind : Int32,
      line : Int32,
      name_line : Int32,
      name_column : Int32,
      end_line : Int32,
      children : Array(Sym)

    def self.build(text : String, path : String) : Array(Sym)
      parser = Parser.new(text)
      parser.filename = path
      walk(parser.parse)
    rescue CodeError | InvalidByteSequenceError
      # Mid-edit the file may not even parse; an empty outline is the
      # honest answer and the diagnostics channel already says why. A
      # file whose bytes are not UTF-8 (one saved as Windows-1254) has no
      # outline either: it raised past this, and workspace symbols failed
      # for every file in the workspace with -32603 "Unexpected byte 0xfe".
      [] of Sym
    end

    private def self.walk(node : ASTNode) : Array(Sym)
      symbols = [] of Sym
      collect(node, symbols)
      symbols
    end

    private def self.collect(node : ASTNode, into : Array(Sym)) : Nil
      case node
      when Expressions
        header = nil
        node.expressions.each do |child|
          header = child if child.is_a?(ModuleHeader)
          if header && child.is_a?(ModuleDef) && child.iyi_unit?
            # The file's own module, as its header writes it: `module
            # calc/lexer` is desugared to a `module Calc::Lexer` placed at
            # the keyword, and the outline named it that, a spelling the
            # file does not have, with a selectionRange of the keyword's
            # column for that name's length - `module calc`, and `mod` for
            # `module app`. The server finds the written name on the line.
            add(into, header.path.join('/'), KIND_MODULE, child, child.body)
          else
            collect(child, into)
          end
        end
      when VisibilityModifier
        collect(node.exp, into)
      when ClassDef
        add(into, node.name.to_s, node.struct? ? KIND_STRUCT : KIND_CLASS, node, node.body)
      when ModuleDef
        add(into, node.name.to_s, KIND_MODULE, node, node.body)
      when TraitDef
        add(into, node.name.to_s, KIND_TRAIT, node, node.body)
      when EnumDef
        add(into, node.name.to_s, KIND_ENUM, node, nil)
      when LibDef
        add(into, node.name.to_s, KIND_MODULE, node, node.body)
      when ImplDef
        add(into, "impl #{node.trait} for #{node.target}", KIND_TRAIT, node, node.body)
      when Def
        name = node.receiver ? "self.#{node.name}" : node.name
        add(into, name, node.receiver ? KIND_FUNCTION : KIND_METHOD, node, nil)
      when Macro
        add(into, node.name, KIND_FUNCTION, node, nil)
      when Assign
        if (target = node.target).is_a?(Path)
          add(into, target.to_s, KIND_CONSTANT, node, nil)
        end
      else
        # Statements; an outline lists declarations.
      end
    end

    private def self.add(into : Array(Sym), name : String, kind : Int32, node : ASTNode, body : ASTNode?) : Nil
      location = node.location
      return unless location

      name_location =
        if node.responds_to?(:name_location)
          node.name_location || location
        elsif node.is_a?(EnumDef)
          # An enum keeps no name location of its own, and its symbol's
          # selectionRange was `enum` for `enum Renk`; its name's path has one.
          node.name.location || location
        else
          location
        end
      end_line = node.end_location.try(&.line_number) || location.line_number

      children = [] of Sym
      collect(body, children) if body

      into << Sym.new(
        name: name,
        kind: kind,
        line: location.line_number,
        name_line: name_location.line_number,
        name_column: name_location.column_number,
        end_line: end_line,
        children: children)
    end
  end
end
