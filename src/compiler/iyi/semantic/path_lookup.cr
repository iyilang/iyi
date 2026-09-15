module Iyi
  class Type
    # Looks up a *path* (for example: `Foo::Bar::Baz`) relative to `self`.
    #
    # For example, given:
    #
    # ```
    # class Foo
    #   class Bar
    #     class Baz
    #     end
    #   end
    # end
    # ```
    #
    # If `self` is `Foo` and we invoke `lookup_path(["Bar", "Baz"])` on it,
    # we'll get `Foo::Bar::Baz` as the return value.
    #
    # The path is searched in the current type's ancestors, and optionally
    # in its namespace, according to *lookup_in_namespace*.
    #
    # Returns `nil` if the path can't be found.
    #
    # *include_private* controls whether private types are found inside
    # other types (when doing Foo::Bar, Bar won't be found if it's private).
    #
    # *location* can be passed and is the location where the lookup happens,
    # and is useful to find file-private types.
    #
    # The result can be an `ASTNode` in the case the path denotes a type variable
    # whose variable is an `ASTNode`. One such example is the `N` of `StaticArray(T, N)`
    # for some instantiated `StaticArray`.
    #
    # If the path is global (for example ::Foo::Bar), the search starts at
    # the top level.
    def lookup_path(path : Path, lookup_in_namespace = true, include_private = false, location = path.location) : Type | ASTNode | Nil
      location = nil if path.global?
      (path.global? ? program : self).lookup_path(path.names, lookup_in_namespace, include_private, location)
    end

    # :ditto:
    def lookup_path(names : Array(String), lookup_in_namespace = true, include_private = false, location = nil) : Type | ASTNode | Nil
      type = self
      names.each_with_index do |name, i|
        # The search must continue in the namespace only for the first path
        # item: for subsequent path items only the parents must be looked up
        type = type.lookup_path_item(name, i == 0, lookup_in_namespace && i == 0, i == 0 || include_private, location)
        return unless type

        # Stop if this is the last name
        break if i == names.size - 1

        # An intermediate match could be an ASTNode, for example
        # when searching T::N::X, and T denotes a static array:
        # in this case we can't continue searching past `N`
        return unless type.is_a?(Type)
      end

      # If this is a TypeParameter resulting from the formal argument of e.g. an
      # inherited generic instance, we must solve this immediately whenever
      # possible. For example:
      #
      # ```
      # class Foo(T1); end
      #
      # class Bar(T2) < Foo(T2); end
      # ```
      #
      # Looking up `T1` under `Bar(Int32)`'s context will return `T2`, which is
      # the formal argument in `Foo(T2)`, and we solve it to return `Int32`. On
      # the other hand, looking up `T1` under `Bar`'s context will return `nil`.
      if type.is_a?(TypeParameter)
        solved = type.solve?(self)
        if solved.is_a?(Var)
          return solved.type
        elsif solved
          # If the context were `Bar(1)` instead, then `solved` is that AST node
          # itself (i.e. `1`), rather than a `Var` with the type of the solved
          # type argument.
          return solved
        end
      end

      type
    end

    # Looks up a single path item relative to *self`.
    #
    # If *lookup_in_namespace* is `true`, if the type is not found
    # in `self` or `self`'s parents, the path item is searched in this
    # type's namespace. This parameter is useful because when writing
    # `Foo::Bar::Baz`, `Foo` should be searched in enclosing namespaces,
    # but `Bar` and `Baz` not.
    #
    # If *lookup_self* is `true`, if the type is not found under `self` but has
    # the same name as `self`, then `self` is returned. This has higher
    # precedence than ancestors and the enclosing namespace.
    #
    # iyi: a type found here that lives in a module this file has not
    # imported is not in scope (SPEC.md R-1) — a sibling unit `Std::Tuple`
    # reached by walking up from `Std::Enumerable` must not hide the
    # prelude's `::Tuple`. The walk goes on outward; the walled match is
    # kept only as the last answer, so that a name nothing else resolves
    # is still refused with the import wall's own sentence rather than
    # "undefined constant". Only for the first path item (the one looked
    # up lexically): `Std::Tuple` written out is a reach, not a shadow.
    def lookup_path_item(name : String, lookup_self, lookup_in_namespace, include_private, location) : Type | ASTNode | Nil
      walled = nil

      # First search in our types
      type = lookup_name(name)
      if type
        if type.private? && !include_private
          return nil
        end

        if lookup_in_namespace && program.iyi_walled_unit?(location, type)
          walled = type
        else
          return type
        end
      end

      # Try ourself for the first path item, unless we are the top-level
      if lookup_self && self != program
        if self.is_a?(NamedType) && name == self.name
          return self
        end
      end

      # Then try out parents, but don't search in our parents namespace
      parents.try &.each do |parent|
        match = parent.lookup_path_item(name, false, false, include_private, location)
        return match if match
      end

      # iyi: then the modules brought into this scope with `using` (SPEC.md
      # II.3). Placed after our own types and our parents, because a local
      # definition beats a used one; and before the namespace, so that a
      # `using` shadows an enclosing scope exactly the way a nested type does.
      if used = using_modules?
        match = lookup_using_path_item(used, name, location)
        return match if match
      end

      # Try our namespace, unless we are the top-level
      if lookup_in_namespace && self != program
        match = namespace.lookup_path_item(name, false, lookup_in_namespace, include_private, location)
        return match if match
      end

      walled
    end

    # iyi: resolves *name* against the modules `using` brought into this scope.
    #
    # Only each module's OWN types are considered — not what it inherits, and
    # not what it itself brought in with `using`. `using` grants access to a
    # module's exports, not to everything reachable from it, which is what
    # keeps a module's public surface something you can read off its own
    # source.
    #
    # Two used modules exporting the same name is not an error where the
    # `using` lines are written; it is an error here, at the point of use, and
    # only for the name actually used. That is SPEC.md II.3's rule, and it is
    # the reason this cannot be an `include`: ancestor order would silently
    # pick one.
    private def lookup_using_path_item(used : Array(UsingModule), name : String, location) : Type?
      found = nil
      found_in = nil

      used.each do |using_module|
        next unless using_module.exports?(name)

        match = using_module.type.lookup_name(name)
        next unless match
        next if match.private?

        if found && found != match
          message = String.build do |io|
            io << '\'' << name << "' is ambiguous here: it is exported by both "
            io << found_in << " and " << using_module.type
            io << ". Qualify it, or narrow one of the `using` directives."
          end
          if location
            ::raise TypeException.new(message, location.line_number, location.column_number, location.filename, name.size)
          else
            ::raise TypeException.new(message)
          end
        end

        found = match
        found_in = using_module.type
      end

      found
    end
  end

  class Program
    def lookup_path_item(name : String, lookup_self, lookup_in_namespace, include_private, location)
      # Check if there's a private type in location
      if location && (original_filename = location.original_filename) &&
         (file_module = file_module?(original_filename)) &&
         (item = file_module.types[name]?)
        return item
      end

      super
    end
  end

  module GenericType
    def lookup_path_item(name : String, lookup_self, lookup_in_namespace, include_private, location)
      # If we are Foo(T) and somebody looks up the type T, we return `nil` because we don't
      # know what type T is, and we don't want to continue search in the namespace
      if type_vars.includes?(name)
        return nil
      end
      super
    end
  end

  class GenericInstanceType
    def lookup_path_item(name : String, lookup_self, lookup_in_namespace, include_private, location)
      # Check if *name* is a type variable
      if type_var = type_vars[name]?
        if type_var.is_a?(Var)
          type_var.type
        else
          type_var
        end
      else
        generic_type.lookup_path_item(name, lookup_self, lookup_in_namespace, include_private, location)
      end
    end
  end

  class UnionType
    def lookup_path_item(name : String, lookup_self, lookup_in_namespace, include_private, location)
      # Union type does not currently inherit GenericClassInstanceType,
      # so we check if *name* is the only type variable of Union(*T)
      if name == "T"
        return program.tuple_of(union_types)
      end
      program.lookup_path_item(name, lookup_self, lookup_in_namespace, include_private, location)
    end
  end

  class AliasType
    def lookup_path_item(name : String, lookup_self, lookup_in_namespace, include_private, location)
      if aliased_type = aliased_type?
        aliased_type.lookup_path_item(name, lookup_self, lookup_in_namespace, include_private, location)
      else
        super
      end
    end
  end

  class TypeDefType
    delegate lookup_path, to: typedef
  end

  class MetaclassType
    delegate lookup_path, to: instance_type
  end

  class GenericClassInstanceMetaclassType
    delegate lookup_path, to: instance_type
  end

  class GenericModuleInstanceMetaclassType
    delegate lookup_path, to: instance_type
  end

  class VirtualType
    delegate lookup_path, to: base_type
  end

  class VirtualMetaclassType
    delegate lookup_path, to: instance_type
  end
end
