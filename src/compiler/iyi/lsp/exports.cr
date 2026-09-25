# iyi: the workspace's exported defs, from the parser alone — what
# auto-import completion offers. R-2 makes this a syntax question:
# `pub` is written at the declaration, so one parse of a module names
# its whole callable surface, no compile and no artifact needed. The
# walk covers module-level `pub def` only: those are the names a
# `import X::{...}` line can select and a bare call can reach.
require "../syntax/ast"
require "../syntax/parser"

module Iyi::Lsp
  module Exports
    # One offerable export: the def's name, the module path an `import`
    # line selects it from, and the signature as written.
    record Item, name : String, module_path : String, detail : String

    def self.of(text : String, path : String) : Array(Item)
      module_path = header_of(text)
      return [] of Item unless module_path

      parser = Parser.new(text)
      parser.filename = path
      parsed = parser.parse

      items = [] of Item
      collect(parsed, module_path, items)
      items
    rescue CodeError
      # Mid-edit a workspace file may not parse; it simply offers
      # nothing until it does.
      [] of Item
    end

    # The compilation-unit header: the first `module x` line, the same
    # reading `project_root_of` does.
    def self.header_of(text : String) : String?
      text.each_line do |line|
        line = line.strip
        next if line.empty? || line.starts_with?('#')
        return nil unless line.starts_with?("module ")
        module_path = line.lchop("module ").strip
        return nil if module_path.empty? || module_path.includes?(' ')
        return module_path
      end
      nil
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
      else
        # Types travel by name and are reachable qualified; a bare call
        # reaches defs, and defs are what completion inserts.
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
