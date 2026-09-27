# iyi: the sites of one local variable, off the parse alone.
#
# `ReferencesVisitor` answers for defs and calls, off the typed graph, and a
# variable is neither: the cursor on `loud` in `loud = shout("iyi")` found
# no call and no def, and `documentHighlight` answered null. A local needs no
# types to be found - its scope is written in the source - so this reads the
# buffer's parse, which also answers while the buffer does not compile.
#
# The scope is where the name is bound. A def, a class or module body and
# the file's own top level are each a scope of their own, and a block shares
# its enclosing one except for its parameters: `|count|` binds a new
# `count` for that block, and a `count` outside it is another variable. So
# the search walks out from the cursor to the first block that names the
# variable as a parameter, or else to the first def, type or file, and
# collects that scope's sites without entering a nested def or type, or a
# block that binds the same name again.
#
# A site is a write where the variable is bound or assigned - a parameter,
# `x = …`, `x += …`, a declaration - and a read everywhere else.
#
# References and rename ride the same sites: the first write is the
# declaration, and a rename is refused when the new name is already used
# in the scope - as a variable, which the two would become one of, or as a
# bare call, which would start reading the variable instead.
require "../syntax/ast"
require "../syntax/visitor"

module Iyi::Lsp
  class LocalSites
    getter name : String
    # The node whose body is the variable's scope.
    getter scope : ASTNode
    # {location of the name, is a write}
    getter sites = [] of {Location, Bool}
    # Whether the scope calls a method of this name with no receiver and
    # no arguments, which reads exactly like the variable.
    property? called = false

    def initialize(@name : String, @scope : ASTNode)
    end

    # The sites in source order, as {references, declarations}: the first
    # write declares the variable, the rest refer to it.
    def split : {Array({Location, Int32}), Array({Location, Int32})}
      ordered = @sites.sort_by { |(location, _)| {location.line_number, location.column_number} }
      first = ordered.index { |(_, write)| write }
      references = [] of {Location, Int32}
      declarations = [] of {Location, Int32}
      ordered.each_with_index do |(location, _), index|
        (index == first ? declarations : references) << {location, @name.size}
      end
      {references, declarations}
    end

    # Whether *other* is already a name in this variable's scope.
    def taken?(other : String, lines : Array(String)) : Bool
      found = self.class.collect(other, @scope, lines)
      !found.sites.empty? || found.called?
    end

    def self.collect(name : String, scope : ASTNode, lines : Array(String)) : LocalSites
      collector = Collector.new(name, scope, lines)
      scope.accept collector
      collector.result
    end

    # The local under *target* in *root* and its sites in its scope, or nil
    # when the cursor is not on a local.
    def self.at(root : ASTNode, target : Location, lines : Array(String)) : LocalSites?
      finder = Finder.new(target, lines)
      root.accept finder
      name = finder.name
      return nil unless name
      collect(name, finder.scope || root, lines)
    end

    # Where *name* is written on the line of *location*, from that column
    # on: an `Arg`'s location is its external name's when it has one.
    def self.name_location(location : Location, name : String, lines : Array(String)) : Location?
      line = lines[location.line_number - 1]?
      return nil unless line
      from = location.column_number - 1
      while index = line.index(name, from)
        before = index == 0 ? nil : line[index - 1]
        after = line[index + name.size]?
        word = ->(char : Char?) { char && (char.alphanumeric? || char == '_') }
        unless word.call(before) || word.call(after)
          return Location.new(location.filename, location.line_number, index + 1)
        end
        from = index + 1
      end
      nil
    end

    def self.scope?(node : ASTNode) : Bool
      node.is_a?(Def) || node.is_a?(ClassDef) || node.is_a?(ModuleDef) || node.is_a?(Block)
    end

    def self.binds?(node : Block, name : String) : Bool
      node.args.any? { |arg| arg.name == name }
    end

    # Pass one: the name under the cursor, and the scope that binds it.
    class Finder < Visitor
      getter name : String?
      getter scope : ASTNode?
      @stack = [] of ASTNode

      def initialize(@target : Location, @lines : Array(String))
      end

      def visit(node : Def | ClassDef | ModuleDef | Block)
        @stack << node
        true
      end

      def end_visit(node : Def | ClassDef | ModuleDef | Block)
        @stack.pop
      end

      def visit(node : Var)
        consider(node.name, node.location)
        true
      end

      def visit(node : Arg)
        location = node.location
        consider(node.name, location && LocalSites.name_location(location, node.name, @lines))
        true
      end

      def visit(node)
        true
      end

      private def consider(name : String, location : Location?) : Nil
        return if @name || name == "self" || name.empty?
        return unless location
        last = Location.new(location.filename, location.line_number, location.column_number + name.size - 1)
        return unless @target.line_number == location.line_number &&
                      location.column_number <= @target.column_number <= last.column_number
        @name = name
        @scope = @stack.reverse_each.find do |scope|
          !scope.is_a?(Block) || LocalSites.binds?(scope, name)
        end
      end
    end

    # Pass two: every site of the name in the scope.
    class Collector < Visitor
      @result : LocalSites

      def initialize(@name : String, @scope : ASTNode, @lines : Array(String))
        @result = LocalSites.new(@name, @scope)
      end

      def result : LocalSites
        @result
      end

      def visit(node : Def | ClassDef | ModuleDef)
        node.same?(@scope)
      end

      def visit(node : Block)
        return true if node.same?(@scope)
        !LocalSites.binds?(node, @name)
      end

      def visit(node : Assign)
        write(node.target)
        node.value.accept self
        false
      end

      def visit(node : OpAssign)
        write(node.target)
        node.value.accept self
        false
      end

      def visit(node : MultiAssign)
        node.targets.each { |target| write(target) }
        node.values.each &.accept(self)
        false
      end

      def visit(node : TypeDeclaration)
        write(node.var)
        node.value.try &.accept(self)
        false
      end

      def visit(node : UninitializedVar)
        write(node.var)
        false
      end

      def visit(node : Arg)
        if node.name == @name && (location = node.location) &&
           (at = LocalSites.name_location(location, @name, @lines))
          @result.sites << {at, true}
        end
        node.default_value.try &.accept(self)
        false
      end

      def visit(node : Var)
        return false unless node.name == @name
        if location = node.location
          scope = @scope
          bound = scope.is_a?(Block) && scope.args.any?(&.same?(node))
          @result.sites << {location, bound}
        end
        false
      end

      def visit(node : Call)
        @result.called = true if node.name == @name && node.obj.nil? && node.args.empty? && node.named_args.nil?
        true
      end

      def visit(node)
        true
      end

      private def write(target : ASTNode) : Nil
        if target.is_a?(Var) && target.name == @name
          if location = target.location
            @result.sites << {location, true}
          end
        else
          target.accept self
        end
      end
    end
  end
end
