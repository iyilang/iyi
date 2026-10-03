# iyi: the workspace's exports, from the parser alone — what completion
# offers. R-2 makes this a syntax question: `pub` is written at the
# declaration, so one parse of a module names its whole surface, no
# compile and no artifact needed. The walk covers what a module exports
# at its own level: `pub def` and `pub macro`, the names a bare call
# reaches, and the `pub` types, which an `import X::{...}` line selects
# as well.
require "../syntax/ast"
require "../syntax/parser"

module Iyi::Lsp
  module Exports
    # One offerable export: its name, the module path an `import` line
    # selects it from, the signature as written, and its LSP
    # CompletionItemKind (3 a function or macro, 7 a class, 8 a trait,
    # 13 an enum, 22 a struct).
    record Item, name : String, module_path : String, detail : String, kind : Int32 = 3

    FUNCTION = 3

    def self.of(text : String, path : String) : Array(Item)
      module_path = header_of(text)
      return [] of Item unless module_path

      parser = Parser.new(text)
      parser.filename = path
      parsed = parser.parse

      items = [] of Item
      collect(parsed, module_path, items)
      items
    rescue CodeError | InvalidByteSequenceError
      # Mid-edit a workspace file may not parse; it simply offers
      # nothing until it does. Nor does one that is not UTF-8: it raised
      # past this, and completing `sho` in any other file answered -32603.
      [] of Item
    end

    # The compilation-unit header, read the way a build reads it.
    def self.header_of(text : String) : String?
      Compiler.module_header_of(text)
    end

    private def self.collect(node : ASTNode, module_path : String, into : Array(Item)) : Nil
      case node
      when Expressions
        node.expressions.each { |child| collect(child, module_path, into) }
      when ModuleDef
        collect(node.body, module_path, into)
      when VisibilityModifier
        collect(node.exp, module_path, into)
      when Def
        into << Item.new(node.name, module_path, signature_of(node)) if node.exported?
      when Macro
        into << Item.new(node.name, module_path, "macro #{macro_signature_of(node)}") if node.exported?
      when ClassDef
        into << Item.new(node.name.to_s, module_path, "#{node.struct? ? "struct" : "class"} #{node.name}", node.struct? ? 22 : 7) if node.exported?
      when TraitDef
        into << Item.new(node.name.to_s, module_path, "trait #{node.name}", 8) if node.exported?
      when EnumDef
        into << Item.new(node.name.to_s, module_path, "enum #{node.name}", 13) if node.exported?
      else
        # Constants and aliases are reached qualified.
      end
    end

    # A macro's name and parameters, as `iyi doc` lists it.
    private def self.macro_signature_of(a_macro : Macro) : String
      String.build do |io|
        io << a_macro.name
        unless a_macro.args.empty?
          io << '('
          a_macro.args.each_with_index do |arg, index|
            io << ", " unless index.zero?
            arg.to_s(io)
          end
          io << ')'
        end
      end
    end

    # The signature as the author wrote it — same rendering hover uses.
    private def self.signature_of(a_def : Def) : String
      String.build do |io|
        io << a_def.name
        unless a_def.args.empty?
          io << '('
          a_def.args.each_with_index do |arg, index|
            io << ", " unless index.zero?
            arg.to_s(io)
          end
          io << ')'
        end
        if return_type = a_def.return_type
          io << " : "
          return_type.to_s(io)
        end
      end
    end
  end
end
