class LLVM::JITCompiler
  # Held so that the collector finalizes this engine before the module and
  # the context the module belongs to: disposing an engine disposes its
  # module, and a context already disposed under it was an access
  # violation in the compiler specs' nineteenth example.
  @module : LLVM::Module

  def initialize(mod)
    @module = mod
    # JIT compilers own an LLVM::Module, and when they are disposed the module is disposed,
    # so we must prevent the module from being dispose when the GC will want to free it.
    mod.take_ownership { raise "Can't create two JIT compilers for the same module" }

    # if LibLLVM.create_jit_compiler_for_module(out @unwrap, mod, 3, out error) != 0
    if LibLLVM.create_mc_jit_compiler_for_module(out @unwrap, mod, nil, 0, out error) != 0
      raise LLVM.string_and_dispose(error)
    end

    # FIXME: We need to disable global isel until https://reviews.llvm.org/D80898 is released,
    # or we fixed generating values for 0 sized types.
    # When removing this, also remove it from the ABI specs and Crystal::Codegen::Target.
    # See https://github.com/crystal-lang/crystal/issues/9297#issuecomment-636512270
    # for background info
    target_machine = LibLLVM.get_execution_engine_target_machine(@unwrap)
    {{ LibLLVM::IS_LT_180 ? LibLLVMExt : LibLLVM }}.set_target_machine_global_isel(target_machine, 0)

    @finalized = false
  end

  def self.new(mod, &)
    jit = new(mod)
    yield jit ensure jit.dispose
  end

  def run_function(func, context : Context)
    ret = LibLLVM.run_function(self, func, 0, nil)
    GenericValue.new(ret, context, self)
  end

  def run_function(func, args : Array(LLVM::GenericValue), context : Context)
    ret = LibLLVM.run_function(self, func, args.size, (args.to_unsafe.as(LibLLVM::GenericValueRef*)))
    GenericValue.new(ret, context, self)
  end

  def get_pointer_to_global(value)
    LibLLVM.get_pointer_to_global(self, value)
  end

  def function_address(name : String) : Void*
    Pointer(Void).new(LibLLVM.get_function_address(self, name.check_no_null_byte))
  end

  def to_unsafe
    @unwrap
  end

  # `dispose` set the flag and then called `finalize`, whose first line
  # returned on that flag, so no engine was ever disposed - not here and
  # not by the collector - and every module a process JIT-compiled kept its
  # memory. The compiler specs JIT one per example, about 14,000 a run, and
  # on Windows a module whose code and unwind table land more than 4 GB
  # apart cannot be relocated: LLVM aborts with "IMAGE_REL_AMD64_ADDR32NB
  # relocation requires an ordered section layout", which one CI run did.
  def dispose
    return if @finalized
    @finalized = true
    LibLLVM.dispose_execution_engine(@unwrap)
  end

  def finalize
    dispose
  end
end
