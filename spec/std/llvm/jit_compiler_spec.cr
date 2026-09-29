require "spec"
require "llvm"

private def jit_module(context : LLVM::Context) : LLVM::Module
  mod = context.new_module("jit_dispose")
  mod.functions.add("answer", [] of LLVM::Type, context.int32) do |func|
    func.basic_blocks.append "entry" do |builder|
      builder.ret context.int32.const_int(42)
    end
  end
  mod
end

describe LLVM::JITCompiler do
  # `dispose` set its flag and then called `finalize`, which returned on
  # that flag: no engine was ever disposed, and every module a process
  # JIT-compiled kept its memory - about 14,000 in one run of the compiler
  # specs. Asked on Windows, where the memory's state is one call away and
  # where the leak ended a run.
  {% if flag?(:win32) %}
    it "runs a function and answers its value" do
      LLVM.init_x86
      context = LLVM::Context.new
      mod = jit_module(context)
      jit = LLVM::JITCompiler.new(mod)
      jit.run_function(mod.functions["answer"], context).to_i.should eq(42)
    end

    it "gives the loaded module's memory back on dispose" do
      LLVM.init_x86
      context = LLVM::Context.new
      jit = LLVM::JITCompiler.new(jit_module(context))
      code = jit.function_address("answer")
      code.null?.should be_false
      jit.dispose
      info = uninitialized LibC::MEMORY_BASIC_INFORMATION
      LibC.VirtualQuery(code, pointerof(info), sizeof(LibC::MEMORY_BASIC_INFORMATION))
      # MEM_FREE
      info.state.should eq(0x10000)
    end
  {% end %}
end
