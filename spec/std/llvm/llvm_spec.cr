require "spec"
require "llvm"

describe LLVM do
  it ".version" do
    LLVM.version.should eq LibLLVM::VERSION
  end

  # iyi: LLVM 23 added a kind between `ConstantInt` and `ConstantFP`, and
  # every kind after it read as the one before.
  it "names a value's kind as the LLVM it links does" do
    context = LLVM::Context.new
    mod = context.new_module("kinds")
    int32 = context.int32
    func = mod.functions.add("f", [] of LLVM::Type, int32)
    asm_type = LLVM::Type.function([] of LLVM::Type, int32)
    assembly = LLVM::Function.from_value(asm_type.inline_asm("", "=r"))
    call = nil.as(LLVM::Value?)
    func.basic_blocks.append("entry") do |builder|
      call = builder.call(asm_type, assembly, [] of LLVM::Value)
      builder.ret call.not_nil!
    end
    func.kind.should eq(LLVM::Value::Kind::Function)
    int32.const_int(1).kind.should eq(LLVM::Value::Kind::ConstantInt)
    context.double.const_double(1.0).kind.should eq(LLVM::Value::Kind::ConstantFP)
    assembly.to_value.kind.should eq(LLVM::Value::Kind::InlineAsm)
    call.not_nil!.kind.should eq(LLVM::Value::Kind::Instruction)
  end

  describe ".normalize_triple" do
    it "works" do
      LLVM.normalize_triple("x86_64-apple-macos").should eq("x86_64-apple-macos")
    end

    it "substitutes unknown for empty components" do
      LLVM.normalize_triple("x86_64-linux-gnu").should eq("x86_64-unknown-linux-gnu")
    end
  end

  it ".default_target_triple" do
    triple = LLVM.default_target_triple
    {% if flag?(:darwin) %}
      triple.should match(/-apple-(darwin|macosx)/)
    {% elsif flag?(:android) %}
      triple.should match(/-android$/)
    {% elsif flag?(:linux) %}
      triple.should match(/-linux/)
    {% elsif flag?(:windows) %}
      triple.should match(/-windows-/)
    {% elsif flag?(:freebsd) %}
      triple.should match(/-freebsd/)
    {% elsif flag?(:openbsd) %}
      triple.should match(/-openbsd/)
    {% elsif flag?(:dragonfly) %}
      triple.should match(/-dragonfly/)
    {% elsif flag?(:netbsd) %}
      triple.should match(/-netbsd/)
    {% elsif flag?(:solaris) %}
      triple.should match(/-solaris$/)
    {% elsif flag?(:wasi) %}
      triple.should match(/-wasi/)
    {% else %}
      pending! "Unknown operating system"
    {% end %}
  end
end
