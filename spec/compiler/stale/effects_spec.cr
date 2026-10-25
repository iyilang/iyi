require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/reach"
require "compiler/iyi/stale/check"
require "compiler/iyi/semantic/effects"

private def create_test_program
  p = Iyi::Program.new
  p.color = false
  p
end

describe "Iyi::Stale S4a: @[Effect] annotation and closure check" do
  describe "placement rules" do
    it "errors when @[Effect] is placed on a class" do
      assert_error <<-CODE, "@[Effect] is only permitted on defs in runtime library files"
        @[Effect(:file_read)]
        class MyClass
        end
        CODE
    end

    it "errors when @[Effect] is placed on a struct" do
      assert_error <<-CODE, "@[Effect] is only permitted on defs in runtime library files"
        @[Effect(:file_read)]
        struct MyStruct
        end
        CODE
    end

    it "errors when @[Effect] is placed on a module" do
      assert_error <<-CODE, "@[Effect] is only permitted on defs in runtime library files"
        @[Effect(:file_read)]
        module MyModule
        end
        CODE
    end

    it "errors when @[Effect] is placed on an enum" do
      assert_error <<-CODE, "@[Effect] is only permitted on defs in runtime library files"
        @[Effect(:file_read)]
        enum MyEnum
          A
        end
        CODE
    end

    it "errors when @[Effect] is placed on an alias" do
      assert_error <<-CODE, "@[Effect] is only permitted on defs in runtime library files"
        @[Effect(:file_read)]
        alias MyInt = Int32
        CODE
    end

    it "errors when @[Effect] is placed on a def in a program file" do
      assert_error <<-CODE, "@[Effect] is only permitted on defs in runtime library files"
        @[Effect(:file_read)]
        def user_def
          42
        end
        CODE
    end

    it "errors when @[Effect] has no arguments" do
      runtime_file = File.join(Dir.current, "src", "std", "spec_test.iyi")
      assert_error <<-CODE, "@[Effect] requires at least one argument specifying the effect kind", filename: runtime_file
        @[Effect]
        def my_def
          42
        end
        CODE
    end

    it "errors when @[Effect] has named arguments" do
      runtime_file = File.join(Dir.current, "src", "std", "spec_test.iyi")
      assert_error <<-CODE, "@[Effect] takes no named arguments", filename: runtime_file
        @[Effect(kind: :file_read)]
        def my_def
          42
        end
        CODE
    end

    it "errors when @[Effect] has a non-symbol argument" do
      runtime_file = File.join(Dir.current, "src", "std", "spec_test.iyi")
      assert_error <<-CODE, "expected first argument of @[Effect] to be a Symbol literal", filename: runtime_file
        @[Effect(123)]
        def my_def
          42
        end
        CODE
    end

    it "errors when @[Effect] has an unknown kind" do
      runtime_file = File.join(Dir.current, "src", "std", "spec_test.iyi")
      assert_error <<-CODE, "unknown or disallowed effect kind :invalid_kind", filename: runtime_file
        @[Effect(:invalid_kind)]
        def my_def
          42
        end
        CODE
    end

    it "errors when @[Effect] uses shared_write (taint only)" do
      runtime_file = File.join(Dir.current, "src", "std", "spec_test.iyi")
      assert_error <<-CODE, "unknown or disallowed effect kind :shared_write", filename: runtime_file
        @[Effect(:shared_write)]
        def my_def
          42
        end
        CODE
    end

    it "errors when @[Effect(:file_write)] lacks an op argument" do
      runtime_file = File.join(Dir.current, "src", "std", "spec_test.iyi")
      assert_error <<-CODE, "@[Effect(:file_write)] requires an operation argument", filename: runtime_file
        @[Effect(:file_write)]
        def my_write
          42
        end
        CODE
    end

    it "errors when @[Effect(:file_write)] has an invalid op" do
      runtime_file = File.join(Dir.current, "src", "std", "spec_test.iyi")
      assert_error <<-CODE, "unknown file_write operation :invalid_op", filename: runtime_file
        @[Effect(:file_write, :invalid_op)]
        def my_write
          42
        end
        CODE
    end

    it "errors when @[Effect] has extra arguments for non-file_write kind" do
      runtime_file = File.join(Dir.current, "src", "std", "spec_test.iyi")
      assert_error <<-CODE, "too many arguments for @[Effect(:file_read)] (expected 1)", filename: runtime_file
        @[Effect(:file_read, :extra)]
        def my_read
          42
        end
        CODE
    end
  end

  describe "Def#effect on runtime library files" do
    it "sets Def#effect for observed kind :file_read" do
      runtime_file = File.join(Dir.current, "src", "std", "spec_test.iyi")
      result = semantic(<<-CODE, filename: runtime_file)
        @[Effect(:file_read)]
        def runtime_read
          10
        end

        runtime_read
        CODE

      target_def = result.program.lookup_first_def("runtime_read", false).not_nil!
      effect = target_def.effect
      effect.should_not be_nil
      effect.not_nil!.kind.should eq(Iyi::EffectKind::FileRead)
      effect.not_nil!.observed?.should be_true
      effect.not_nil!.output?.should be_false
      effect.not_nil!.not_reusable?.should be_false
      effect.not_nil!.internal?.should be_false
    end

    it "sets Def#effect for output kind :file_write with op" do
      runtime_file = File.join(Dir.current, "src", "std", "spec_test.iyi")
      result = semantic(<<-CODE, filename: runtime_file)
        @[Effect(:file_write, :create)]
        def runtime_write
          20
        end

        runtime_write
        CODE

      target_def = result.program.lookup_first_def("runtime_write", false).not_nil!
      effect = target_def.effect
      effect.should_not be_nil
      effect.not_nil!.kind.should eq(Iyi::EffectKind::FileWrite)
      effect.not_nil!.op.should eq(Iyi::FileWriteOp::Create)
      effect.not_nil!.output?.should be_true
    end

    it "sets Def#effect for not-reusable kind :clock" do
      runtime_file = File.join(Dir.current, "src", "std", "spec_test.iyi")
      result = semantic(<<-CODE, filename: runtime_file)
        @[Effect(:clock)]
        def runtime_clock
          30
        end

        runtime_clock
        CODE

      target_def = result.program.lookup_first_def("runtime_clock", false).not_nil!
      effect = target_def.effect
      effect.should_not be_nil
      effect.not_nil!.kind.should eq(Iyi::EffectKind::Clock)
      effect.not_nil!.not_reusable?.should be_true
    end

    it "sets Def#effect for internal kind :memory" do
      runtime_file = File.join(Dir.current, "src", "std", "spec_test.iyi")
      result = semantic(<<-CODE, filename: runtime_file)
        @[Effect(:memory)]
        def runtime_mem
          40
        end

        runtime_mem
        CODE

      target_def = result.program.lookup_first_def("runtime_mem", false).not_nil!
      effect = target_def.effect
      effect.should_not be_nil
      effect.not_nil!.kind.should eq(Iyi::EffectKind::Memory)
      effect.not_nil!.internal?.should be_true
    end
  end

  describe "closure check: opaque program constructs with root:path:line (row 12)" do
    it "flags program asm as opaque program construct" do
      program_file = File.join(Dir.current, "src", "program_asm_test.iyi")
      result = semantic(<<-CODE, filename: program_file)
        def do_asm
          asm("nop")
        end
        do_asm
        CODE

      reach = Iyi::Stale::ReachWalk.walk(result.program, result.node)
      closure = Iyi::Effects.closure_check(result.program, reach)

      reasons = closure.not_reusable.select { |r| r.category == "opaque program construct" }
      reasons.size.should be >= 1
      asm_reason = reasons.find { |r| r.reason == "asm" }.not_nil!
      asm_reason.site.not_nil!.should match(/^src:.*program_asm_test\.iyi:\d+$/)
    end

    it "flags program lib call as opaque program construct" do
      program_file = File.join(Dir.current, "src", "program_lib_call_test.iyi")
      result = semantic(<<-CODE, filename: program_file)
        lib LibC
          fun getpid : Int32
        end

        def call_c
          LibC.getpid
        end
        call_c
        CODE

      reach = Iyi::Stale::ReachWalk.walk(result.program, result.node)
      closure = Iyi::Effects.closure_check(result.program, reach)

      reasons = closure.not_reusable.select { |r| r.category == "opaque program construct" }
      reasons.size.should be >= 1
      lib_call_reason = reasons.find { |r| r.reason == "lib call" }.not_nil!
      lib_call_reason.site.not_nil!.should match(/^src:.*program_lib_call_test\.iyi:\d+$/)
    end

    it "flags program lib global as opaque program construct" do
      program_file = File.join(Dir.current, "src", "program_lib_global_test.iyi")
      result = semantic(<<-CODE, filename: program_file)
        lib LibC
          $my_global : Int32
        end

        def read_global
          LibC.my_global
        end
        read_global
        CODE

      reach = Iyi::Stale::ReachWalk.walk(result.program, result.node)
      closure = Iyi::Effects.closure_check(result.program, reach)

      reasons = closure.not_reusable.select { |r| r.category == "opaque program construct" }
      reasons.size.should be >= 1
      lib_global_reason = reasons.find { |r| r.reason == "lib global" }.not_nil!
      lib_global_reason.site.not_nil!.should match(/^src:.*program_lib_global_test\.iyi:\d+$/)
    end

    it "flags program pointer_new primitive as opaque program construct" do
      program_file = File.join(Dir.current, "src", "program_pointer_test.iyi")
      result = semantic(<<-CODE, filename: program_file)
        struct Pointer(T)
          @[Primitive(:pointer_new)]
          def self.new(address : UInt64)
          end
        end

        def convert_ptr
          Pointer(Int32).new(1234_u64)
        end
        convert_ptr
        CODE

      reach = Iyi::Stale::ReachWalk.walk(result.program, result.node)
      closure = Iyi::Effects.closure_check(result.program, reach)

      reasons = closure.not_reusable.select { |r| r.category == "opaque program construct" }
      reasons.size.should be >= 1
      ptr_reason = reasons.find { |r| r.reason == "pointer_new" }.not_nil!
      ptr_reason.site.not_nil!.should match(/^src:.*program_pointer_test\.iyi:\d+$/)
    end

    it "flags program call to an internal-class def (C8) as opaque program construct" do
      runtime_file = File.join(Dir.current, "src", "std", "internal_worker.iyi")
      program_file = File.join(Dir.current, "src", "call_internal_test.iyi")

      # First compile runtime module with @[Effect(:memory)]
      program = create_test_program
      program.iyi_prelude_dir = File.join(Dir.current, "src", "iyi")
      parser1 = program.new_parser(<<-CODE)
        @[Effect(:memory)]
        def worker_internal_stat
          42
        end
        CODE
      parser1.filename = runtime_file
      node1 = program.normalize(parser1.parse)
      program.semantic(node1)

      # Now compile program code that calls the internal def
      parser2 = program.new_parser(<<-CODE)
        def user_code
          worker_internal_stat
        end
        user_code
        CODE
      parser2.filename = program_file
      node2 = program.normalize(parser2.parse)
      final_node = program.semantic(node2)

      reach = Iyi::Stale::ReachWalk.walk(program, final_node)
      closure = Iyi::Effects.closure_check(program, reach)

      reasons = closure.not_reusable.select { |r| r.category == "opaque program construct" }
      reasons.size.should be >= 1
      internal_reason = reasons.find { |r| r.reason.starts_with?("call to internal def:") }.not_nil!
      internal_reason.site.not_nil!.should match(/^src:.*call_internal_test\.iyi:\d+$/)
    end
  end

  describe "closure check: runtime files and RG3 reporting" do
    it "flags unclassified runtime lib fun calls outside annotated defs as RG3 sites" do
      runtime_file = File.join(Dir.current, "src", "std", "unannotated_runtime.iyi")

      program = create_test_program
      program.iyi_prelude_dir = File.join(Dir.current, "src", "iyi")
      parser = program.new_parser(<<-CODE)
        lib LibSys
          fun getpid : Int32
        end

        def runtime_unannotated_getpid
          LibSys.getpid
        end

        runtime_unannotated_getpid
        CODE
      parser.filename = runtime_file
      node = program.semantic(program.normalize(parser.parse))

      reach = Iyi::Stale::ReachWalk.walk(program, node)
      closure = Iyi::Effects.closure_check(program, reach)

      closure.rg3_sites.size.should be >= 1
      site_entry = closure.rg3_sites.find { |s| s.detail.includes?("getpid") }.not_nil!
      site_entry.site.should match(/^toolchain:std\/unannotated_runtime\.iyi:\d+$/)
      site_entry.enclosing_def.should eq("runtime_unannotated_getpid")

      internal_reasons = closure.not_reusable.select { |r| r.category == "internal" && r.reason == "unclassified runtime site" }
      internal_reasons.size.should be >= 1
    end

    it "does not flag lib fun calls inside an annotated runtime def" do
      runtime_file = File.join(Dir.current, "src", "std", "annotated_runtime.iyi")

      program = create_test_program
      program.iyi_prelude_dir = File.join(Dir.current, "src", "iyi")
      parser = program.new_parser(<<-CODE)
        lib LibSys
          fun getpid : Int32
        end

        @[Effect(:process)]
        def runtime_annotated_getpid
          LibSys.getpid
        end

        runtime_annotated_getpid
        CODE
      parser.filename = runtime_file
      node = program.semantic(program.normalize(parser.parse))

      reach = Iyi::Stale::ReachWalk.walk(program, node)
      closure = Iyi::Effects.closure_check(program, reach)

      # Because the runtime def carries @[Effect(:process)], the lib call is classified!
      closure.rg3_sites.should be_empty
      closure.not_reusable.select { |r| r.reason == "unclassified runtime site" }.should be_empty
    end

    it "treats llvm.* intrinsics as compiler operations rather than lib calls (no RG3 site, not opaque)" do
      runtime_file = File.join(Dir.current, "src", "std", "math_intrinsic.iyi")
      program_file = File.join(Dir.current, "src", "program_math.iyi")

      program = create_test_program
      program.iyi_prelude_dir = File.join(Dir.current, "src", "iyi")
      parser1 = program.new_parser(<<-CODE)
        lib LibLLVMMath
          fun sqrt = "llvm.sqrt.f64"(x : Float64) : Float64
        end

        def runtime_sqrt(x : Float64) : Float64
          LibLLVMMath.sqrt(x)
        end
        CODE
      parser1.filename = runtime_file
      node1 = program.normalize(parser1.parse)
      program.semantic(node1)

      parser2 = program.new_parser(<<-CODE)
        def user_code
          runtime_sqrt(4.0)
        end
        user_code
        CODE
      parser2.filename = program_file
      node2 = program.normalize(parser2.parse)
      final_node = program.semantic(node2)

      reach = Iyi::Stale::ReachWalk.walk(program, final_node)
      closure = Iyi::Effects.closure_check(program, reach)

      # Neither RG3 site nor opaque program construct should be reported for llvm.* intrinsic
      closure.rg3_sites.should be_empty
      closure.not_reusable.select { |r| r.category == "opaque program construct" }.should be_empty
      closure.not_reusable.select { |r| r.reason == "unclassified runtime site" }.should be_empty
    end
  end
end
