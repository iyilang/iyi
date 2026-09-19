struct LLVM::TargetData
  def initialize(@unwrap : LibLLVM::TargetDataRef)
  end

  def size_in_bits(type)
    LibLLVM.size_of_type_in_bits(self, type)
  end

  def size_in_bytes(type)
    size_in_bits = size_in_bits(type)
    size_in_bits // 8 &+ (size_in_bits & 0x7 != 0 ? 1 : 0)
  end

  def abi_size(type)
    LibLLVM.abi_size_of_type(self, type)
  end

  def abi_alignment(type)
    LibLLVM.abi_alignment_of_type(self, type)
  end

  def to_unsafe
    @unwrap
  end

  # A field past the last one is a compiler bug, and which bug is worth
  # saying: LLVM 20 and earlier answered a garbage offset, so the wrong
  # bytes turned up in a debugger, and LLVM 21 and later calls
  # `report_fatal_error` and takes the process down with a message
  # about scalable vectors that names nothing the caller did. The check
  # is two counts, on a path only `--debug` walks.
  def offset_of_element(struct_type, element)
    count = LibLLVM.count_struct_element_types(struct_type)
    unless element < count
      raise "BUG: asked for field #{element} of a struct that has #{count}"
    end
    LibLLVM.offset_of_element(self, struct_type, element)
  end

  def to_data_layout_string
    LLVM.string_and_dispose(LibLLVM.copy_string_rep_of_target_data(self))
  end
end
