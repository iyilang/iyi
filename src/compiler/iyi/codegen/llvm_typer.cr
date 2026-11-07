require "../types"
require "llvm"

module Iyi
  class LLVMTyper
    getter landing_pad_type : LLVM::Type

    alias TypeCache = Hash(Type, LLVM::Type)

    @layout : LLVM::TargetData
    @landing_pad_type : LLVM::Type

    @@closure_counter = 0

    def initialize(@program : Program, @llvm_context : LLVM::Context)
      @cache = TypeCache.new
      @struct_cache = TypeCache.new

      # For union types we just need to know the maximum size of their types.
      # It might happen that we have a recursive type, for example:
      #
      # ```
      # struct Foo
      #   def initialize
      #     @x = uninitialized Pointer(Int32 | Foo)
      #   end
      # end
      # ```
      #
      # In that case, when we are computing the llvm type of Foo, we will
      # need to compute the llvm type of `@x`. Its type is a pointer to
      # a union. In order to compute the llvm type of a union we need
      # to compute the size of each type. For this, we compute the llvm
      # type of each type in the union and then get their size. The problem
      # here is that we are computing `Foo`, so we can't know its size yet.
      #
      # To solve this, when computing the llvm type of the union types,
      # we do it with a `wants_size` flag. In the case of pointers we
      # can just return a word size (using size_of(LLVM::VoidPointer)) instead
      # of computing the llvm type of the pointer element. This avoids the
      # recursion.
      #
      # We still need a separate cache for this types that we use to compute
      # types, because there can be cycles.
      @wants_size_cache = TypeCache.new
      @wants_size_struct_cache = TypeCache.new

      @structs = {} of String => LLVM::Type

      machine = program.target_machine
      @layout = machine.data_layout
      @landing_pad_type = @llvm_context.struct([@llvm_context.void_pointer, @llvm_context.int32], "landing_pad")
    end

    def type_id_pointer
      @llvm_context.int32.pointer
    end

    @proc_type : LLVM::Type?

    def proc_type
      @proc_type ||= @structs["->"] ||= @llvm_context.struct [@llvm_context.void_pointer, @llvm_context.void_pointer], "->"
    end

    @nil_type : LLVM::Type?

    def nil_type
      @nil_type ||= @structs["Nil"] ||= @llvm_context.struct([] of LLVM::Type, "Nil")
    end

    def nil_value
      nil_type.null
    end

    # A string literal's global. Under iyi's layout: the object header
    # word first - the type id in its high half, where every object
    # carries it (GC_DESIGN.md Stage 5, `object_header.cr`) - then the
    # object itself, which is what the program's pointer names; the word
    # is eight bytes and keeps the object eight-aligned. Under Crystal's:
    # the type id in front, as an `i32`.
    def llvm_string_type(bytesize)
      if @program.iyi_object_layout?
        @llvm_context.struct [
          @llvm_context.int64, # the object header word
          llvm_string_object_type(bytesize),
        ]
      else
        @llvm_context.struct [
          @llvm_context.int32,                    # type_id
          @llvm_context.int32,                    # @bytesize
          @llvm_context.int32,                    # @length
          @llvm_context.int8.array(bytesize + 1), # @c
        ]
      end
    end

    def llvm_string_object_type(bytesize)
      @llvm_context.struct [
        @llvm_context.int32,                    # @bytesize
        @llvm_context.int32,                    # @length
        @llvm_context.int8.array(bytesize + 1), # @c
      ]
    end

    def llvm_type(type, wants_size = false)
      type = type.remove_indirection

      if wants_size
        @wants_size_cache[type] ||= create_llvm_type(type, wants_size: true)
      else
        @cache[type] ||= create_llvm_type(type, wants_size)
      end
    end

    private def create_llvm_type(type : NoReturnType, wants_size)
      @llvm_context.void
    end

    private def create_llvm_type(type : VoidType, wants_size)
      @llvm_context.void
    end

    private def create_llvm_type(type : NilType, wants_size)
      nil_type
    end

    private def create_llvm_type(type : BoolType, wants_size)
      @llvm_context.int1
    end

    private def create_llvm_type(type : CharType, wants_size)
      @llvm_context.int32
    end

    private def create_llvm_type(type : IntegerType, wants_size)
      @llvm_context.int(8 * type.bytes)
    end

    private def create_llvm_type(type : FloatType, wants_size)
      type.bytes == 4 ? @llvm_context.float : @llvm_context.double
    end

    private def create_llvm_type(type : SymbolType, wants_size)
      @llvm_context.int32
    end

    private def create_llvm_type(type : EnumType, wants_size)
      llvm_type(type.base_type)
    end

    private def create_llvm_type(type : ProcInstanceType, wants_size)
      proc_type
    end

    private def create_llvm_type(type : InstanceVarContainer, wants_size)
      # The size of a class is the same as the size of a pointer
      if wants_size && !type.struct?
        return @llvm_context.void_pointer
      end

      final_type = llvm_struct_type(type, wants_size)
      unless type.struct?
        final_type = final_type.pointer
      end
      final_type
    end

    private def create_llvm_type(type : MetaclassType, wants_size)
      @llvm_context.int32
    end

    private def create_llvm_type(type : LibType, wants_size)
      @llvm_context.int32
    end

    private def create_llvm_type(type : GenericClassInstanceMetaclassType, wants_size)
      @llvm_context.int32
    end

    private def create_llvm_type(type : GenericModuleInstanceMetaclassType, wants_size)
      @llvm_context.int32
    end

    private def create_llvm_type(type : VirtualMetaclassType, wants_size)
      @llvm_context.int32
    end

    private def create_llvm_type(type : PointerInstanceType, wants_size)
      if wants_size
        return @llvm_context.void_pointer
      end

      pointed_type = llvm_embedded_type(type.element_type, wants_size)
      pointed_type = @llvm_context.int8 if pointed_type.void?
      pointed_type.pointer
    end

    private def create_llvm_type(type : StaticArrayInstanceType, wants_size)
      pointed_type = llvm_embedded_type(type.element_type, wants_size)
      pointed_type = @llvm_context.int8 if pointed_type.void?
      pointed_type.array type.size.as(NumberLiteral).value.to_i
    end

    private def create_llvm_type(type : TupleInstanceType, wants_size)
      llvm_name = llvm_name(type, wants_size)

      if s = @structs[llvm_name]?
        return s
      end

      @llvm_context.struct(llvm_name) do |a_struct|
        if wants_size
          @wants_size_cache[type] = a_struct
        else
          @cache[type] = a_struct
          @structs[llvm_name] = a_struct
        end

        type.tuple_types.map { |tuple_type| llvm_embedded_type(tuple_type, wants_size).as(LLVM::Type) }
      end
    end

    private def create_llvm_type(type : NamedTupleInstanceType, wants_size)
      llvm_name = llvm_name(type, wants_size)
      if s = @structs[llvm_name]?
        return s
      end

      @llvm_context.struct(llvm_name) do |a_struct|
        if wants_size
          @wants_size_cache[type] = a_struct
        else
          @cache[type] = a_struct
          @structs[llvm_name] = a_struct
        end

        type.entries.map { |entry| llvm_embedded_type(entry.type, wants_size).as(LLVM::Type) }
      end
    end

    private def create_llvm_type(type : NilableType, wants_size)
      llvm_type(type.not_nil_type, wants_size)
    end

    private def create_llvm_type(type : ReferenceUnionType, wants_size)
      type_id_pointer
    end

    private def create_llvm_type(type : NilableReferenceUnionType, wants_size)
      type_id_pointer
    end

    private def create_llvm_type(type : NilableProcType, wants_size)
      proc_type
    end

    private def create_llvm_type(type : TypeDefType, wants_size)
      llvm_type(type.typedef, wants_size)
    end

    private def create_llvm_type(type : VirtualType, wants_size)
      type_id_pointer
    end

    private def create_llvm_type(type : AliasType, wants_size)
      llvm_type(type.remove_alias, wants_size)
    end

    private def create_llvm_type(type : ReferenceStorageType, wants_size)
      llvm_struct_type(type.reference_type, wants_size)
    end

    private def create_llvm_type(type : NonGenericModuleType | GenericClassType, wants_size)
      # This can only be reached if the module or generic class don't have implementors
      @llvm_context.int1
    end

    private def create_llvm_type(type : Type, wants_size)
      raise "BUG: called create_llvm_type for #{type}"
    end

    def llvm_struct_type(type, wants_size = false)
      type = type.remove_indirection

      if wants_size
        @wants_size_struct_cache[type] ||= create_llvm_struct_type(type, wants_size: true)
      else
        @struct_cache[type] ||= create_llvm_struct_type(type, wants_size)
      end
    end

    private def create_llvm_struct_type(type : StaticArrayInstanceType, wants_size)
      llvm_type(type, wants_size)
    end

    private def create_llvm_struct_type(type : TupleInstanceType, wants_size)
      llvm_type(type, wants_size)
    end

    private def create_llvm_struct_type(type : NamedTupleInstanceType, wants_size)
      llvm_type(type, wants_size)
    end

    private def create_llvm_struct_type(type : InstanceVarContainer, wants_size)
      if type.extern_union?
        return create_llvm_c_union_struct_type(type, wants_size)
      end

      llvm_name = llvm_name(type, wants_size)
      if s = @structs[llvm_name]?
        return s
      end

      @llvm_context.struct(llvm_name, type.packed?) do |a_struct|
        if wants_size
          @wants_size_struct_cache[type] = a_struct
        else
          @struct_cache[type] = a_struct
          @structs[llvm_name] = a_struct
        end

        # iyi: under iyi's layout a class's fields and nothing before
        # them. The type id is not a field: it is the high half of the
        # object header word under the pointer, at `P-4`, in every
        # allocator mode (GC_DESIGN.md Stage 5), and an object that
        # carried it twice - there and here - was eight bytes larger than
        # its fields for every class in the program, binary trees' node a
        # 32-byte chunk where Go's is 16. Crystal's layout keeps the id
        # in front (`iyi_object_layout?` says whose program this is).
        ivars = type.all_instance_vars
        id_in_front = !type.struct? && !@program.iyi_object_layout?
        element_types = Array(LLVM::Type).new(ivars.size + (id_in_front ? 1 : 0))
        element_types.push @llvm_context.int32 if id_in_front # For the type id

        ivars.each do |name, ivar|
          if type.extern?
            element_types.push llvm_embedded_c_type(ivar.type, wants_size)
          else
            element_types.push llvm_embedded_type(ivar.type, wants_size)
          end
        end

        element_types
      end
    end

    private def create_llvm_c_union_struct_type(type, wants_size)
      llvm_name = llvm_name(type, wants_size)
      if s = @structs[llvm_name]?
        return s
      end

      @llvm_context.struct(llvm_name) do |a_struct|
        if wants_size
          @wants_size_struct_cache[type] = a_struct
        else
          @struct_cache[type] = a_struct
          @structs[llvm_name] = a_struct
        end

        # We are going to represent the union like this:
        # 1. Find out what's the type with the largest alignment
        # 2. Find out what's the type's size
        # 3. Have the first member of the union be an array
        #    of ints that match that alignment, up to that type's
        #    size, followed by another member that is just bytes
        #    to fill the rest of the union's size.
        #
        # So for example if we have this:
        #
        # struct Foo
        #   x : Int8
        #   y : Int32
        # end
        #
        # union Bar
        #   foo : Foo
        #   padding : UInt8[24]
        # end
        #
        # We have that for Bar, the largest alignment of its types
        # is 4 (for Foo's Int32). Foo's size is 8 bytes (4 for x, 4 for y).
        # Then for the first union member we'll have [2 x i32].
        # The total size of the union is 24 bytes. We already filled
        # 8 bytes so we still need 16 bytes.
        # The resulting union is { [2 x i32], [16 x i8] }.

        max_size = 0
        max_align = 0
        max_align_type = nil
        max_align_type_size = 0

        type.instance_vars.each do |name, var|
          var_type = var.type
          unless var_type.void?
            llvm_type = llvm_embedded_c_type(var_type, wants_size: true)
            size = size_of(llvm_type)
            align = align_of(llvm_type)

            if size > max_size
              max_size = size
            end

            if align > max_align
              max_align = align
              max_align_type = llvm_type
              max_align_type_size = size
            end
          end
        end

        filler = @llvm_context.int(max_align * 8)
        filler_size = max_align_type_size // max_align

        union_fill = [filler.array(filler_size)] of LLVM::Type
        if max_align_type_size < max_size
          union_fill << @llvm_context.int8.array(max_size - max_align_type_size)
        end

        union_fill
      end
    end

    private def create_llvm_struct_type(type : Type, wants_size)
      raise "BUG: called llvm_struct_type for #{type}"
    end

    def llvm_embedded_type(type, wants_size = false)
      type = type.remove_indirection
      case type
      when NoReturnType, VoidType
        @llvm_context.int8
      else
        llvm_type(type, wants_size)
      end
    end

    def llvm_embedded_c_type(type : ProcInstanceType, wants_size = false)
      proc_type(type).pointer
    end

    def llvm_embedded_c_type(type, wants_size = false)
      llvm_embedded_type(type, wants_size)
    end

    def llvm_c_type(type : ProcInstanceType)
      proc_type(type).pointer
    end

    def llvm_c_type(type : NilableProcType)
      proc_type(type.proc_type).pointer
    end

    def llvm_c_type(type : TupleInstanceType)
      llvm_struct_type(type)
    end

    def llvm_c_type(type)
      if type.extern?
        llvm_struct_type(type)
      elsif type.passed_by_value?
        # C types that are passed by value must be considered,
        # for the ABI, as being passed behind a pointer
        llvm_type(type).pointer
      else
        llvm_type(type)
      end
    end

    # StaticArray can only be "returned" in lib externs,
    # not in C functions, and there it must not be a pointer.
    def llvm_c_return_type(type : StaticArrayInstanceType)
      llvm_struct_type(type)
    end

    def llvm_c_return_type(type : NilType)
      @llvm_context.void
    end

    def llvm_c_return_type(type)
      llvm_c_type(type)
    end

    def llvm_return_type(type : NilType)
      @llvm_context.void
    end

    def llvm_return_type(type)
      llvm_type(type)
    end

    # Since LLVM 15, LLVM intrinsics must return unnamed structs, and instances
    # of the named `Tuple` struct are no longer substitutable
    # This happens when binding to intrinsics like `llvm.sadd.with.overflow.*`
    # as lib funs directly
    def llvm_intrinsic_return_type(type : TupleInstanceType)
      @llvm_context.struct(type.tuple_types.map { |tuple_type| llvm_embedded_type(tuple_type).as(LLVM::Type) })
    end

    def llvm_intrinsic_return_type(type : NamedTupleInstanceType)
      @llvm_context.struct(type.entries.map { |entry| llvm_embedded_type(entry.type).as(LLVM::Type) })
    end

    def llvm_intrinsic_return_type(type : Type)
      llvm_return_type(type)
    end

    def closure_type(type : ProcInstanceType)
      function_type(type.arg_types, type.return_type, closure: true)
    end

    def proc_type(type : ProcInstanceType)
      function_type(type.arg_types, type.return_type, closure: false)
    end

    private def function_type(arg_types : Array(Type), return_type : Type, *, closure : Bool)
      llvm_args = arg_types.map do |arg_type|
        (passed_indirectly?(arg_type) ? @llvm_context.void_pointer : llvm_type(arg_type)).as(LLVM::Type)
      end
      llvm_args.insert(0, @llvm_context.void_pointer) if closure
      if passed_indirectly?(return_type)
        llvm_args << @llvm_context.void_pointer
        LLVM::Type.function(llvm_args, @llvm_context.void)
      else
        LLVM::Type.function(llvm_args, llvm_type(return_type))
      end
    end

    # iyi: the bytes above which a value travels between iyi functions in
    # memory rather than as an LLVM first-class aggregate. Above it an
    # argument is a pointer to the caller's value, which the callee copies
    # into its own slot on entry, and a result is written through a pointer
    # to the caller's slot, passed last; every copy of such a value between
    # two places in memory is an `llvm.memcpy` or `llvm.memmove`.
    #
    # An aggregate in a register is what LLVM spills and reloads an element
    # at a time without optimisation: in a debug build for darwin arm64,
    # `StaticArray(UInt8, 1000).new` returned its value as 1,000 bytes
    # loaded and 1,000 stored, in a 9,888-byte frame of 14,479 instructions,
    # and is a 2,048-byte frame of 25 instructions this way.
    #
    # The line is where --release stops caring. Through memory, debug frames
    # are smaller from 32 bytes up: a function returning a copy of its
    # argument and its caller took 168 bytes of frame between them on Linux
    # x86_64 for a 32-byte value against 264, and 480 for a 64-byte one
    # against 640. But a P-256 signature check, whose points are 96 bytes
    # and numbers 32, took 58,191 ns in --release with the line at 32
    # against 52,664 (three runs), 52,549 at 64 against 51,681 (best of
    # fifteen), and 51,821 at 128: unchanged. Issue #130's program, debug,
    # in a task on Linux x86_64, ran 120 frames deep with the line at 64 and
    # 119 at 128, where it ran 47 before. It is a constant rather than a
    # choice per build, because a `.iyimod`'s object code and its consumer
    # must agree on it whichever way each was built.
    INDIRECT_ABOVE = 128_u64

    # Whether a value of *type* is passed and returned through memory by an
    # iyi function (see `INDIRECT_ABOVE`). A C function's are its ABI's,
    # and an `extern` struct is left to that ABI whoever declares it.
    def passed_indirectly?(type : Type) : Bool
      return false unless type.passed_by_value?
      return false if type.extern?
      size_of(llvm_type(type)) > INDIRECT_ABOVE
    end

    def closure_context_type(vars, parent_llvm_type, self_type)
      @@closure_counter += 1
      llvm_name = "closure_#{@@closure_counter}"

      has_inner_pointers = !parent_llvm_type.nil?
      closure_type = @llvm_context.struct(llvm_name) do |a_struct|
        @structs[llvm_name] = a_struct

        elems = Array(LLVM::Type).new(vars.size + (parent_llvm_type ? 1 : 0) + (self_type ? 1 : 0))

        vars.each do |var|
          elems << llvm_type(var.type)
          has_inner_pointers ||= var.type.has_inner_pointers?
        end

        # Make sure to copy the given LLVM::Type to this context
        if parent_llvm_type
          elems << copy_type(parent_llvm_type).pointer
        end

        if self_type
          elems << llvm_type(self_type)
          has_inner_pointers ||= self_type.has_inner_pointers?
        end

        elems
      end

      {closure_type, has_inner_pointers}
    end

    # Copy existing LLVM types, possibly from another context,
    # into this typer's context.
    def copy_types(types : Array(LLVM::Type))
      types.map do |type|
        copy_type(type).as(LLVM::Type)
      end
    end

    # Copy an existing LLVM type, possibly from another context,
    # into this typer's context.
    def copy_type(type : LLVM::Type)
      case type.kind
      when .void?
        @llvm_context.void
      when .integer?
        @llvm_context.int(type.int_width)
      when .float?
        @llvm_context.float
      when .double?
        @llvm_context.double
      when .pointer?
        {% if LibLLVM::IS_LT_150 %}
          copy_type(type.element_type).pointer
        {% else %}
          @llvm_context.pointer
        {% end %}
      when .array?
        copy_type(type.element_type).array(type.array_size)
      when .vector?
        copy_type(type.element_type).vector(type.vector_size)
      when .function?
        params_types = copy_types(type.params_types)
        ret_type = copy_type(type.return_type)
        LLVM::Type.function(params_types, ret_type, type.varargs?)
      when .struct?
        llvm_name = type.struct_name
        if llvm_name
          @structs[llvm_name] ||= begin
            @llvm_context.struct(llvm_name, type.packed_struct?) do |the_struct|
              @structs[llvm_name] = the_struct
              copy_types(type.struct_element_types)
            end
          end
        else
          # The case of an anonymous struct (only happens with C bindings and C ABI,
          # where structs like `{ double, double }` are generated)
          @llvm_context.struct(copy_types(type.struct_element_types), packed: type.packed_struct?)
        end
      else
        raise "don't know how to copy type: #{type} (#{type.kind})"
      end
    end

    def llvm_name(type, wants_size)
      llvm_name = type.llvm_name
      llvm_name = "#{llvm_name}.wants_size" if wants_size
      llvm_name
    end

    def size_of(type)
      if type.void?
        0_u64
      else
        @layout.size_in_bytes type
      end
    end

    def offset_of(type, element_index)
      @layout.offset_of_element(type, element_index)
    end

    def align_of(type)
      if type.void?
        1_u32
      else
        @layout.abi_alignment(type)
      end
    end

    def size_t
      @llvm_context.int(@program.size_bit_width)
    end

    @pointer_size : UInt64?

    def pointer_size
      @pointer_size ||= size_of(@llvm_context.void_pointer)
    end
  end
end
