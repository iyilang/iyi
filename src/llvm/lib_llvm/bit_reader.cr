require "./types"

lib LibLLVM
  fun parse_bitcode_in_context2 = LLVMParseBitcodeInContext2(c : ContextRef, mb : MemoryBufferRef, m : ModuleRef*) : Int
  fun get_bitcode_module_in_context2 = LLVMGetBitcodeModuleInContext2(c : ContextRef, mb : MemoryBufferRef, m : ModuleRef*) : Bool
end
