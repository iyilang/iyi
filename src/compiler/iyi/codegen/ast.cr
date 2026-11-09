require "../syntax/ast"

module Iyi
  class ASTNode
    def no_returns?
      !!type?.try &.no_return?
    end
  end

  class Def
    property? abi_info = false

    def mangled_name(program, self_type)
      name = String.build do |str|
        str << '*'

        if owner = @owner
          if owner.metaclass?
            self_type.instance_type.llvm_name(str)
            if original_owner != self_type
              str << SYMBOL_JOIN
              original_owner.instance_type.llvm_name(str)
            end
            str << "::"
          elsif !owner.is_a?(Iyi::Program)
            self_type.llvm_name(str)
            if original_owner != self_type
              str << SYMBOL_JOIN
              original_owner.llvm_name(str)
            end
            str << '#'
          end
        end

        str << self.name.gsub('@', '.')

        next_def = self.next
        while next_def
          str << '\''
          next_def = next_def.next
        end

        if args.size > 0 || uses_block_arg?
          str << '<'
          if args.size > 0
            args.each_with_index do |arg, i|
              str << ", " if i > 0
              arg.type.llvm_name(str)
            end
          end
          if uses_block_arg?
            str << ", " if args.size > 0
            str << '&'
            block_arg.not_nil!.type.llvm_name(str)
          end
          str << '>'
        end
        if return_type = @type
          str << ':'
          iyi_mangled_return(return_type).llvm_name(str)
        end

        # iyi: a body that travels is compiled twice, and the two are not the
        # same function (SPEC.md IV.1g).
        #
        # The producer compiles it against declarations. Where the body calls
        # an `abstract def`, the producer's world may hold nothing that
        # answers it: `DB::Connection#fetch_or_build_prepared_statement` calls
        # `build_prepared_statement`, and in `db`'s own build no driver is
        # loaded, so what `db`'s artifact carries is a function whose `else`
        # branch returns its own argument. The consumer compiles the same body
        # against `SQLite3::Connection` and gets the right one.
        #
        # Both wore this name. The consumer's copy is private to the unit that
        # holds it, the producer's is global, so every call the consumer wrote
        # bound to the producer's — `DB.open` handed back a statement whose
        # `crystal_type_id` was 1, and `.class` on it hit the trap at the end
        # of a dispatch nothing matched.
        #
        # A suffix, rather than hiding the producer's: `db`'s own object code
        # calls that symbol by name, and so does `sqlite3`'s — `Statement#
        # do_close` calls `super`. Both keep reaching it. What changes is that
        # the consumer's copy is a different name, and the consumer's calls
        # reach the copy compiled where they stand.
        str << "~iyi" if iyi_body_travelled?
      end

      Iyi.safe_mangling(program, name)
    end

    # iyi: the return type a symbol is made of, for a def read from a `.iyimod`
    # (SPEC.md IV.1g).
    #
    # A declaration may not name a virtual type — `Foo+` is how one *prints*
    # and not a name anybody can write, which is why `infer_return`
    # devirtualises before writing it down. A symbol is made of the type the
    # method actually answers, and that is the virtual one:
    # `DB::Database#checkout` answers `DB::Connection+`, its declaration says
    # `Connection`, and a consumer calling it directly asked for
    # `*DB::Database#checkout:DB::Connection` — which nobody emitted. It never
    # showed through a travelling body, where the consumer compiles the call
    # and the symbol is its own.
    #
    # Two rules that were each right on their own, and this is where they meet.
    # A no-op for a class nothing inherits from, whose virtual type is itself.
    private def iyi_mangled_return(type : Iyi::Type) : Iyi::Type
      return type unless iyi_from_artifact?
      return type if iyi_body_travelled?
      return type unless type.responds_to?(:virtual_type)
      type.virtual_type
    end

    def varargs?
      false
    end

    def call_convention
      nil
    end

    @c_calling_convention : Bool? = nil
    property c_calling_convention

    # Returns `self` as an `External` if this Def is an External
    # that must respect the C calling convention.
    def c_calling_convention?
      if @c_calling_convention.nil?
        @c_calling_convention = compute_c_calling_convention
      end

      @c_calling_convention ? self : nil
    end

    def llvm_intrinsic?
      self.is_a?(External) && self.real_name.starts_with?("llvm.")
    end

    private def compute_c_calling_convention
      # One case where this is not true if for LLVM intrinsics.
      # For example overflow intrinsics return a tuple, like {i32, i1}:
      # in C ABI that is represented as i64, but we need to keep the original
      # type here, respecting LLVM types, not the C ABI.
      if self.is_a?(External)
        return !self.real_name.starts_with?("llvm.")
      end

      # Another case is when an argument is an external struct, in which
      # case we must respect the C ABI (this applies to Crystal methods
      # and procs too)

      # Only applicable to procs (no owner) for now
      owner = @owner
      if owner
        return false
      end

      proc_c_calling_convention?
    end

    def proc_c_calling_convention?
      # We use C ABI if:
      # - all arguments are allowed in lib calls (because then it can be passed to C)
      # - at least one argument type, or the return type, is an extern struct
      found_extern = false

      if (type = self.type?)
        type = type.remove_alias
        if type.extern?
          found_extern = true
        elsif !type.void? && !type.nil_type? && !type.allowed_in_lib?
          return false
        end
      end

      args.each do |arg|
        arg_type = arg.type.remove_alias
        if arg_type.extern?
          found_extern = true
        elsif !arg_type.allowed_in_lib?
          return false
        end
      end

      found_extern
    end
  end

  class Asm
    def dialect : LLVM::InlineAsmDialect
      intel? ? LLVM::InlineAsmDialect::Intel : LLVM::InlineAsmDialect::ATT
    end
  end
end
