require "./codegen"

# iyi: what LLVM is told about an `Array`'s memory (src/iyi/array.iyi).
#
# An array is two allocations: the object, whose fields are `@size`,
# `@capacity` and `@buffer`, and the buffer its elements live in, which is
# `Pointer(T).malloc`'s or a step into it and never an array's fields. LLVM
# could not know that. In plb2's matrix product, `ci[j] += t * bk[j]`
# stores a `Float64` into `ci`'s buffer, and for all LLVM knew that store
# had changed `ci`'s or `bk`'s size or buffer, so the inner loop loaded all
# four again for every element, checked both sizes against them, and was
# not vectorised: 1.9 times Go's time.
#
# So each access says which of the two it touches, as type-based alias
# analysis metadata (`!tbaa`) with two sibling tags under one root: an
# array's own field (an instance variable of an `Array` instance, read or
# assigned) or one of its elements (`Pointer#array_slot`, which array.iyi
# reads and writes its buffer with and nothing else does). LLVM takes two
# accesses with the two tags for distinct memory. Every other access stays
# untagged, which LLVM takes as one that may touch anything, as before;
# the tag names a place, not a type, so a union element's type id under
# the element tag is still an element's memory.
#
# An element read whose type is a class (not a struct, a union or a
# virtual type) is also marked `!nonnull`, `!dereferenceable` and `!align`
# for that class's fields: array.iyi reads only elements below the size,
# which are written (`unsafe_build`'s and `unsafe_set_size`'s promise), so
# the value is an object. That is what lets LLVM load `bk`'s size ahead of
# the branch that guards that load in the loop, and so out of the loop.
class Iyi::CodeGenVisitor
  # The two access tags per LLVM context, keyed by the context's address.
  @iyi_array_tbaa = {} of {UInt64, Bool} => LLVM::Value

  # Set while `assign` stores an array's field or element: the pointer it
  # stores to and whether it is an element (`store_value` marks the store).
  @iyi_array_store : {LLVM::Value, Bool}? = nil

  # Whether *type* is an instance of `Array`, whose fields are marked.
  def iyi_array_instance?(type : Type) : Bool
    type = type.remove_typedef
    type.is_a?(GenericClassInstanceType) && type.generic_type == @program.array
  end

  # Marks *value* with the field's (*element* false) or the element's tag
  # when it is a load from *pointer*; anything else is left as it is.
  def iyi_array_load(value : LLVM::Value, pointer : LLVM::Value, element : Bool) : Nil
    return if LibLLVM.is_a_load_inst(value).null?
    return unless LibLLVM.get_operand(value, 0) == pointer.to_unsafe

    iyi_set_metadata value, "tbaa", iyi_array_tbaa(element)
  end

  # Runs the block, in which `store_value` marks a store to *pointer* with
  # the field's or the element's tag.
  def iyi_array_stores(pointer : LLVM::Value, element : Bool, &)
    @iyi_array_store = {pointer, element}
    begin
      yield
    ensure
      @iyi_array_store = nil
    end
  end

  # `store_value`'s half of `iyi_array_stores`. After a `NoReturn` the
  # builder answers a constant instead of a store, which is left alone.
  def iyi_array_store(stored : LLVM::Value, pointer : LLVM::Value) : Nil
    pending = @iyi_array_store
    return unless pending && pending[0].to_unsafe == pointer.to_unsafe
    return if LibLLVM.is_a_store_inst(stored).null?

    iyi_set_metadata stored, "tbaa", iyi_array_tbaa(pending[1])
  end

  # An element *value* just loaded, of *type*: an object when *type* is a
  # class, which the load then says.
  def iyi_array_object(value : LLVM::Value, type : Type) : Nil
    return if LibLLVM.is_a_load_inst(value).null?

    type = type.remove_typedef
    return unless type.is_a?(NonGenericClassType) || type.is_a?(GenericClassInstanceType)
    return if type.struct? || type.abstract? || type.extern?

    iyi_set_metadata value, "nonnull", iyi_md_value(iyi_md_node([] of LibLLVM::ValueRef))

    struct_type = llvm_struct_type(type)
    size = llvm_typer.size_of(struct_type)
    return if size == 0

    iyi_set_metadata value, "dereferenceable", iyi_md_value(iyi_md_node([iyi_md_int(size)]))
    iyi_set_metadata value, "align", iyi_md_value(iyi_md_node([iyi_md_int(llvm_typer.align_of(struct_type).to_u64)]))
  end

  private def iyi_array_tbaa(element : Bool) : LLVM::Value
    @iyi_array_tbaa.put_if_absent({llvm_context.to_unsafe.address, element}) do
      zero = iyi_md_int(0_u64)
      root = iyi_md_node([iyi_md_string("iyi array memory")])
      name = element ? "Array element" : "Array field"
      scalar = iyi_md_node([iyi_md_string(name), root, zero])
      iyi_md_value(iyi_md_node([scalar, scalar, zero]))
    end
  end

  private def iyi_set_metadata(instruction : LLVM::Value, kind : String, node : LLVM::Value) : Nil
    LibLLVM.set_metadata(instruction, LibLLVM.get_md_kind_id_in_context(llvm_context, kind, kind.bytesize), node)
  end

  # The metadata-level pieces, as `LLVMMDNodeInContext2` takes them.
  private def iyi_md_string(text : String) : LibLLVM::ValueRef
    LibLLVM.md_string_in_context2(llvm_context, text, text.bytesize)
  end

  private def iyi_md_int(value : UInt64) : LibLLVM::ValueRef
    LibLLVM.value_as_metadata(int64(value)).as(LibLLVM::ValueRef)
  end

  private def iyi_md_node(operands : Array(LibLLVM::ValueRef)) : LibLLVM::ValueRef
    LibLLVM.md_node_in_context2(llvm_context, operands.to_unsafe, operands.size)
  end

  private def iyi_md_value(node : LibLLVM::ValueRef) : LLVM::Value
    LLVM::Value.new LibLLVM.metadata_as_value(llvm_context, node.as(LibLLVM::MetadataRef))
  end
end
