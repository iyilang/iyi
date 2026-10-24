class LLVM::GenericValue
  # The engine that answered this value, when one did: a value can be a
  # pointer into the module the engine loaded - `to_string` of a string
  # the code returned - and that memory lives as long as the engine does.
  @engine : LLVM::JITCompiler?

  def initialize(@unwrap : LibLLVM::GenericValueRef, @context : LLVM::Context, @engine : LLVM::JITCompiler? = nil)
  end

  def to_i : Int32
    to_i64.to_i32!
  end

  def to_i64 : Int64
    LibLLVM.generic_value_to_int(self, is_signed: 1).to_i64!
  end

  def to_u64 : UInt64
    LibLLVM.generic_value_to_int(self, is_signed: 0)
  end

  def to_b : Bool
    to_i != 0
  end

  def to_f32 : Float32
    LibLLVM.generic_value_to_float(@context.float, self).to_f32
  end

  def to_f64 : Float64
    LibLLVM.generic_value_to_float(@context.double, self)
  end

  def to_string : String
    to_pointer.as(String)
  end

  def to_pointer : Void*
    LibLLVM.generic_value_to_pointer(self)
  end

  def to_unsafe
    @unwrap
  end

  def finalize
    LibLLVM.dispose_generic_value(@unwrap)
  end
end
