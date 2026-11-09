require "./types"

lib LibLLVM
  fun link_modules2 = LLVMLinkModules2(dest : ModuleRef, src : ModuleRef) : Bool
end
