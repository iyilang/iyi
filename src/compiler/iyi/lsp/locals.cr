# iyi: the sites of one variable - a local or an instance variable - off the
# parse alone.
#
# `ReferencesVisitor` answers for defs and calls, off the typed graph, and a
# variable is neither: the cursor on `loud` in `loud = shout("iyi")` found
# no call and no def, and `documentHighlight` answered null. A variable
# needs no types to be found - its scope is written in the source - so this
# reads the buffer's parse, which also answers while the buffer does not
# compile.
#
# A local's scope is where the name is bound. A def, a class or module body
# and the file's own top level are each a scope of their own, and a block
# shares its enclosing one except for its parameters: `|count|` binds a new
# `count` for that block, and a `count` outside it is another variable. So
# the search walks out from the cursor to the first block that names the
# variable as a parameter, or else to the first def, type or file, and
# collects that scope's sites without entering a nested def or type, or a
# block that binds the same name again.
#
# An instance variable's scope is the class body it is written in, every
# def of it included, and no class nested inside. Its sites are every
# `@count`, and the name an accessor declares - `getter count : Int32` is
# the field's declaration. `def initialize(@count : Int32)` is a parameter
# and an assignment the parser writes at the same place, and that place is
# the instance variable's, not a local's.
#
# A site is a write where the variable is bound or assigned - a parameter,
# `x = …`, `x += …`, a declaration - and a read everywhere else.
#
# References and rename ride the same sites: the first write is the
# declaration, and a rename is refused when the new name is already used
# in the scope - as a variable, which the two would become one of, or as a
# bare call, which would start reading the variable instead. An instance
# variable is not renamed here: its accessors carry its name as methods,
# and they are the typed graph's.
require "../syntax/ast"
require "../syntax/visitor"

module Iyi::Lsp
  class LocalSites
    ACCESSORS = %w(getter getter? getter! property property? property! setter)

    getter name : String
    # The node whose body is the variable's scope.
    getter scope : ASTNode
    # {location of the name, its length, is a write}
    getter sites = [] of {Location, Int32, Bool}
    # Whether the scope calls a method of this name with no receiver and
    # no arguments, which reads exactly like the variable.
    property? called = false

    def initialize(@name : String, @scope : ASTNode)
    end

    def instance_var? : Bool
      @name.starts_with?('@')
    end

    # The sites in source order, as {references, declarations}: the first
    # write declares the variable, the rest refer to it.
    def split : {Array({Location, Int32}), Array({Location, Int32})}
      ordered = @sites.sort_by { |(location, _, _)| {location.line_number, location.column_number} }
      first = ordered.index { |(_, _, write)| write }
      references = [] of {Location, Int32}
      declarations = [] of {Location, Int32}
      ordered.each_with_index do |(location, size, _), index|
        (index == first ? declarations : references) << {location, size}
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

    # The variable under *target* in *root* and its sites in its scope, or
    # nil when the cursor is not on one.
    def self.at(root : ASTNode, target : Location, lines : Array(String)) : LocalSites?
      finder = Finder.new(target, lines)
      root.accept finder
      name = finder.name
      return nil unless name
      scope = finder.scope
      return nil if name.starts_with?('@') && scope.nil?
      collect(name, scope || root, lines)
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

    # Whether the source at *location* is an `@`: the parameter and the
    # variable the parser writes for `def m(@x)` stand there, and they are
    # the instance variable's.
    def self.at_sign?(location : Location?, lines : Array(String)) : Bool
      return false unless location
      line = lines[location.line_number - 1]?
      !!line && line[location.column_number - 1]? == '@'
    end

    def self.binds?(node : Block, name : String) : Bool
      node.args.any? { |arg| arg.name == name }
    end

    # The names an accessor call declares - `getter count : Int32`,
    # `property name = ""`, `getter count` - with where each is written.
    def self.accessor_names(node : Call) : Array({String, Location})
      names = [] of {String, Location}
      return names unless node.obj.nil? && ACCESSORS.includes?(node.name)
      node.args.each do |arg|
        var = case arg
              when TypeDeclaration then arg.var
              when Assign          then arg.target
              else                      arg
              end
        if var.is_a?(Var) && (location = var.location)
          names << {var.name, location}
        end
      end
      names
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

      def visit(node : InstanceVar)
        if hit?(node.name, node.location)
          @name = node.name
          @scope = owner
        end
        false
      end

      # An accessor's names are the field's, and not locals.
      def visit(node : Call)
        names = LocalSites.accessor_names(node)
        return true if names.empty? && !LocalSites::ACCESSORS.includes?(node.name)
        names.each do |(name, location)|
          if hit?(name, location)
            @name = "@#{name}"
            @scope = owner
          end
        end
        false
      end

      def visit(node : Var)
        return true if LocalSites.at_sign?(node.location, @lines)
        consider(node.name, node.location)
        true
      end

      def visit(node : Arg)
        location = node.location
        return true if LocalSites.at_sign?(location, @lines)
        consider(node.name, location && LocalSites.name_location(location, node.name, @lines))
        true
      end

      def visit(node)
        true
      end

      private def hit?(name : String, location : Location?) : Bool
        return false if @name || name.empty?
        return false unless location
        @target.line_number == location.line_number &&
          location.column_number <= @target.column_number <= location.column_number + name.size - 1
      end

      # The class an instance variable at the cursor belongs to: the
      # innermost class body around it.
      private def owner : ASTNode?
        @stack.reverse_each.find(&.is_a?(ClassDef))
      end

      private def consider(name : String, location : Location?) : Nil
        return if name == "self"
        return unless hit?(name, location)
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

      private def instance_var? : Bool
        @result.instance_var?
      end

      # A local stops at a nested def or type; an instance variable is its
      # class's in every def of the class, and stops at a nested type.
      def visit(node : Def)
        node.same?(@scope) || instance_var?
      end

      def visit(node : ClassDef | ModuleDef)
        node.same?(@scope)
      end

      def visit(node : Block)
        return true if node.same?(@scope) || instance_var?
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
        return false if LocalSites.at_sign?(node.location, @lines)
        if node.name == @name && (location = node.location) &&
           (at = LocalSites.name_location(location, @name, @lines))
          @result.sites << {at, @name.size, true}
        end
        node.default_value.try &.accept(self)
        false
      end

      def visit(node : Var)
        return false unless node.name == @name
        return false if LocalSites.at_sign?(node.location, @lines)
        if location = node.location
          scope = @scope
          bound = scope.is_a?(Block) && scope.args.any?(&.same?(node))
          @result.sites << {location, @name.size, bound}
        end
        false
      end

      def visit(node : InstanceVar)
        if node.name == @name && (location = node.location)
          @result.sites << {location, @name.size, false}
        end
        false
      end

      def visit(node : Call)
        if instance_var?
          names = LocalSites.accessor_names(node)
          unless names.empty?
            names.each do |(name, location)|
              @result.sites << {location, name.size, true} if "@#{name}" == @name
            end
            return false
          end
        end
        @result.called = true if node.name == @name && node.obj.nil? && node.args.empty? && node.named_args.nil?
        true
      end

      def visit(node)
        true
      end

      private def write(target : ASTNode) : Nil
        name = case target
               when InstanceVar then target.name
               when Var         then LocalSites.at_sign?(target.location, @lines) ? nil : target.name
               end
        if name == @name && (location = target.location)
          @result.sites << {location, @name.size, true}
        else
          target.accept self
        end
      end
    end
  end
end
