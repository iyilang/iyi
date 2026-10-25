require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/reach"
require "compiler/iyi/semantic/effects"
require "compiler/iyi/semantic/observers"

describe "Iyi::Semantic::Observers (Slice S5b)" do
  runtime_file = File.join(Dir.current, "src", "std", "spec_observe_test.iyi")

  describe "C9 errors for yielding and splat defs" do
    it "raises C9 error when def yields with observed kind" do
      assert_error <<-CODE, "def 'read_with_yield' that yields cannot carry @[Effect(:file_read)]; annotate the non-yielding helper it calls instead", flags: "iyi_observe", filename: runtime_file
        @[Effect(:file_read)]
        def read_with_yield(path : String, &block : String -> Nil)
          yield path
        end
        CODE
    end

    it "raises C9 error when def has yield keyword with observed kind" do
      assert_error <<-CODE, "def 'yielding_def' that yields cannot carry @[Effect(:file_stat)]; annotate the non-yielding helper it calls instead", flags: "iyi_observe", filename: runtime_file
        @[Effect(:file_stat)]
        def yielding_def(path : String)
          yield path
        end
        CODE
    end

    it "raises C9 error when def yields with output kind" do
      assert_error <<-CODE, "def 'write_yield' that yields cannot carry @[Effect(:file_write)]; annotate the non-yielding helper it calls instead", flags: "iyi_observe", filename: runtime_file
        @[Effect(:file_write, :create)]
        def write_yield(path : String, &block : Nil)
          yield
        end
        CODE
    end

    it "raises C9 error when def yields with not-reusable kind" do
      assert_error <<-CODE, "def 'clock_yield' that yields cannot carry @[Effect(:clock)]; annotate the non-yielding helper it calls instead", flags: "iyi_observe", filename: runtime_file
        @[Effect(:clock)]
        def clock_yield(&block : Nil)
          yield
        end
        CODE
    end

    it "raises C9 error when def takes positional splat" do
      assert_error <<-CODE, "def 'splat_def' that takes splats cannot carry @[Effect(:entropy)]; annotate the non-yielding helper it calls instead", flags: "iyi_observe", filename: runtime_file
        @[Effect(:entropy)]
        def splat_def(*args)
          0
        end
        CODE
    end

    it "raises C9 error when def takes double splat" do
      assert_error <<-CODE, "def 'double_splat_def' that takes splats cannot carry @[Effect(:timer)]; annotate the non-yielding helper it calls instead", flags: "iyi_observe", filename: runtime_file
        @[Effect(:timer)]
        def double_splat_def(**kwargs)
          0
        end
        CODE
    end

    it "raises mismatched signature error for Dir#read with dir_list" do
      assert_error <<-CODE, "def 'read' cannot carry @[Effect(:dir_list)]: mismatched signature (observer expects (path, names)); annotate the non-yielding helper it calls instead", flags: "iyi_observe", filename: runtime_file
        class Dir
          @[Effect(:dir_list)]
          def read : String?
            nil
          end
        end
        CODE
    end

    it "raises mismatched signature error for zero-arg env_get (like Dir.tempdir)" do
      assert_error <<-CODE, "def 'tempdir' cannot carry @[Effect(:env_get)]: mismatched signature (observer expects (name, value?)); annotate the non-yielding helper it calls instead", flags: "iyi_observe", filename: runtime_file
        class Dir
          @[Effect(:env_get)]
          def self.tempdir : String
            "/tmp"
          end
        end
        CODE
    end

    it "raises mismatched signature error for file_read without path parameter (like lseek)" do
      assert_error <<-CODE, "def 'lseek' cannot carry @[Effect(:file_read)]: mismatched signature (observer expects path parameter); annotate the non-yielding helper it calls instead", flags: "iyi_observe", filename: runtime_file
        class File
          @[Effect(:file_read)]
          def self.lseek(fd : Int64, offset : Int64, whence : Int32) : Int64
            0_i64
          end
        end
        CODE
    end
    it "raises mismatched signature error for file_write(:rename) with fewer than 2 path parameters" do
      assert_error <<-CODE, "def 'rename_file' cannot carry @[Effect(:file_write, :rename)]: mismatched signature (observer expects two path parameters); annotate the non-yielding helper it calls instead", flags: "iyi_observe", filename: runtime_file
        class File
          @[Effect(:file_write, :rename)]
          def self.rename_file(old_path : String)
            nil
          end
        end
        CODE
    end
  end
  describe "wrapper generation and call order" do
    it "renames def to __iyi_effect_<name> and generates wrapper for observed kind (call order: def then observer)" do
      result = semantic(<<-CODE, flags: "iyi_observe", filename: runtime_file)
        class File
          @[Effect(:file_read)]
          def self.read_text(path : String) : String
            "hello"
          end
        end
        CODE

      file_type = result.program.types["File"].metaclass.as(Iyi::ModuleType)
      defs = file_type.defs.not_nil!

      # Original def was renamed
      defs.has_key?("__iyi_effect_read_text").should be_true
      renamed_def = defs["__iyi_effect_read_text"].first.def
      renamed_def.name.should eq("__iyi_effect_read_text")
      renamed_def.effect.not_nil!.kind.should eq(Iyi::EffectKind::FileRead)

      # Wrapper was created under original name
      defs.has_key?("read_text").should be_true
      wrapper = defs["read_text"].first.def
      wrapper.name.should eq("read_text")
      wrapper.effect.should be_nil

      # Wrapper body: def call first, then observer call
      body = wrapper.body.as(Iyi::Expressions)
      body.expressions.size.should eq(3)

      # First expression: assign result of __iyi_effect_read_text
      assign = body.expressions[0].as(Iyi::Assign)
      assign.target.as(Iyi::Var).name.should eq("__iyi_res")
      inner_call = assign.value.as(Iyi::Call)
      inner_call.name.should eq("__iyi_effect_read_text")

      # Second expression: observer call
      obs_call = body.expressions[1].as(Iyi::Call)
      obs_call.name.should eq("__iyi_observe_file_read")
      obs_call.obj.as(Iyi::Path).names.should eq(["Std", "Observe"])

      # Third expression: result variable
      body.expressions[2].as(Iyi::Var).name.should eq("__iyi_res")
    end

    it "generates exit wrapper with observer call BEFORE the def (C5)" do
      result = semantic(<<-CODE, flags: "iyi_observe", filename: runtime_file)
        class Process
          @[Effect(:exit)]
          def self.exit(status : Int32 = 0)
            status
          end
        end
        CODE

      proc_type = result.program.types["Process"].metaclass.as(Iyi::ModuleType)
      defs = proc_type.defs.not_nil!

      defs.has_key?("__iyi_effect_exit").should be_true
      defs.has_key?("exit").should be_true

      wrapper = defs["exit"].first.def
      body = wrapper.body.as(Iyi::Expressions)
      body.expressions.size.should eq(2)

      # First expression is the observer call (C5: exit observer before the def)
      obs_call = body.expressions[0].as(Iyi::Call)
      obs_call.name.should eq("__iyi_observe_exit")
      obs_call.obj.as(Iyi::Path).names.should eq(["Std", "Observe"])

      # Second expression is the def call
      inner_call = body.expressions[1].as(Iyi::Call)
      inner_call.name.should eq("__iyi_effect_exit")
    end

    it "formats site literal as root:path:line for not-reusable effects" do
      result = semantic(<<-CODE, flags: "iyi_observe", filename: runtime_file)
        class Time
          @[Effect(:clock)]
          def self.now_ticks : Int64
            12345_i64
          end
        end
        CODE

      time_type = result.program.types["Time"].metaclass.as(Iyi::ModuleType)
      wrapper = time_type.defs.not_nil!["now_ticks"].first.def

      body = wrapper.body.as(Iyi::Expressions)
      obs_call = body.expressions[1].as(Iyi::Call)
      obs_call.name.should eq("__iyi_observe_clock")

      site_arg = obs_call.args[0].as(Iyi::StringLiteral)
      site_arg.value.should match(/^(toolchain|src):.*:\d+$/)
    end

    it "does NOT wrap stdio or internal kinds" do
      result = semantic(<<-CODE, flags: "iyi_observe", filename: runtime_file)
        class Term
          @[Effect(:stdio)]
          def self.print_char(c : Char)
            c
          end
        end

        class Mem
          @[Effect(:memory)]
          def self.alloc(size : Int32)
            size
          end
        end
        CODE

      term_type = result.program.types["Term"].metaclass.as(Iyi::ModuleType)
      term_defs = term_type.defs.not_nil!
      term_defs.has_key?("__iyi_effect_print_char").should be_false
      term_defs["print_char"].first.def.name.should eq("print_char")

      mem_type = result.program.types["Mem"].metaclass.as(Iyi::ModuleType)
      mem_defs = mem_type.defs.not_nil!
      mem_defs.has_key?("__iyi_effect_alloc").should be_false
      mem_defs["alloc"].first.def.name.should eq("alloc")
    end
  end
    it "generates wrapper for file_write single-path (:mkdir) and two-path (:rename)" do
      result = semantic(<<-CODE, flags: "iyi_observe", filename: runtime_file)
        class File
          @[Effect(:file_write, :mkdir)]
          def self.make_dir(path : String) : Nil
          end

          @[Effect(:file_write, :rename)]
          def self.move_file(old_path : String, new_path : String) : Nil
          end
        end
        CODE

      file_type = result.program.types["File"].metaclass.as(Iyi::ModuleType)
      defs = file_type.defs.not_nil!

      defs.has_key?("__iyi_effect_make_dir").should be_true
      defs.has_key?("make_dir").should be_true
      wrapper1 = defs["make_dir"].first.def
      body1 = wrapper1.body.as(Iyi::Expressions)
      obs1 = body1.expressions[1].as(Iyi::Call)
      obs1.name.should eq("__iyi_observe_file_write")
      obs1.args[0].as(Iyi::SymbolLiteral).value.should eq("mkdir")
      obs1.args[2].is_a?(Iyi::NilLiteral).should be_true

      defs.has_key?("__iyi_effect_move_file").should be_true
      defs.has_key?("move_file").should be_true
      wrapper2 = defs["move_file"].first.def
      body2 = wrapper2.body.as(Iyi::Expressions)
      obs2 = body2.expressions[1].as(Iyi::Call)
      obs2.name.should eq("__iyi_observe_file_write")
      obs2.args[0].as(Iyi::SymbolLiteral).value.should eq("rename")
      obs2.args[2].is_a?(Iyi::Var).should be_true
    end

    it "generates wrapper for cwd and host" do
      result = semantic(<<-CODE, flags: "iyi_observe", filename: runtime_file)
        class Dir
          @[Effect(:cwd)]
          def self.current : String
            "/curr"
          end

          @[Effect(:cwd)]
          def self.change_dir(path : String) : Nil
          end
        end

        class System
          @[Effect(:host)]
          def self.hostname : String
            "myhost"
          end
        end
        CODE

      dir_type = result.program.types["Dir"].metaclass.as(Iyi::ModuleType)
      dir_defs = dir_type.defs.not_nil!
      wrapper_cur = dir_defs["current"].first.def
      body_cur = wrapper_cur.body.as(Iyi::Expressions)
      body_cur.expressions[1].as(Iyi::Call).name.should eq("__iyi_observe_cwd")

      wrapper_cd = dir_defs["change_dir"].first.def
      body_cd = wrapper_cd.body.as(Iyi::Expressions)
      body_cd.expressions[1].as(Iyi::Call).name.should eq("__iyi_observe_cwd")

      sys_type = result.program.types["System"].metaclass.as(Iyi::ModuleType)
      sys_defs = sys_type.defs.not_nil!
      wrapper_host = sys_defs["hostname"].first.def
      body_host = wrapper_host.body.as(Iyi::Expressions)
      body_host.expressions[1].as(Iyi::Call).name.should eq("__iyi_observe_host")
    end

    it "generates wrapper for env_all" do
      result = semantic(<<-CODE, flags: "iyi_observe", filename: runtime_file)
        class Env
          @[Effect(:env_all)]
          def self.all_vars : Hash(String, String)
            {} of String => String
          end
        end
        CODE

      env_type = result.program.types["Env"].metaclass.as(Iyi::ModuleType)
      wrapper = env_type.defs.not_nil!["all_vars"].first.def
      body = wrapper.body.as(Iyi::Expressions)
      obs = body.expressions[1].as(Iyi::Call)
      obs.name.should eq("__iyi_observe_env_all")
      obs.args.empty?.should be_true
    end

    it "forwards default arguments and named arguments" do
      code = <<-CODE
        module Std
          module Observe
            def self.__iyi_observe_file_stat(path : String) : Nil
            end
          end
        end

        class File
          @[Effect(:file_stat)]
          def self.info?(path : String, follow_symlinks : Bool = true) : Bool
            follow_symlinks
          end
        end

        # Call with default argument
        r1 = File.info?("/tmp/a")

        # Call with named arguments
        r2 = File.info?(follow_symlinks: false, path: "/tmp/b")
        CODE

      result = semantic(code, flags: "iyi_observe", filename: runtime_file)
      file_type = result.program.types["File"].metaclass.as(Iyi::ModuleType)
      wrapper = file_type.defs.not_nil!["info?"].first.def
      wrapper.args.size.should eq(2)
      wrapper.args[1].default_value.should_not be_nil
    end

    it "wraps instance methods and preserves annotations minus Effect" do
      result = semantic(<<-CODE, flags: "iyi_observe", filename: runtime_file)
        class MyFile
          getter path : String = "/tmp/f"

          @[AlwaysInline]
          @[Effect(:file_stat)]
          def touch(path : String) : Bool
            true
          end
        end
        CODE

      my_file_type = result.program.types["MyFile"].as(Iyi::ModuleType)
      defs = my_file_type.defs.not_nil!

      defs.has_key?("__iyi_effect_touch").should be_true
      defs.has_key?("touch").should be_true

      wrapper = defs["touch"].first.def
      wrapper.receiver.should be_nil

      # Check annotations: AlwaysInline preserved, Effect removed
      anns = wrapper.annotations.not_nil!
      anns.has_key?(result.program.always_inline_annotation).should be_true
      anns.has_key?(result.program.effect_annotation).should be_false
    end
  describe "idempotence" do
    it "is idempotent when run multiple times" do
      node = parse(<<-CODE, filename: runtime_file)
        class File
          @[Effect(:file_stat)]
          def self.stat_file(path : String) : Int32
            42
          end
        end
        CODE

      program = Iyi::Program.new
      program.color = false
      program.flags << "iyi_observe"

      # First run
      node, processor = program.top_level_semantic(node)

      file_type = program.types["File"].metaclass.as(Iyi::ModuleType)
      file_type.defs.not_nil!["stat_file"].size.should eq(1)
      file_type.defs.not_nil!["__iyi_effect_stat_file"].size.should eq(1)

      # Second run on the same program
      Iyi::Semantic::Observers.run(program)

      # No double-wrapping or mangling
      file_type.defs.not_nil!["stat_file"].size.should eq(1)
      file_type.defs.not_nil!["__iyi_effect_stat_file"].size.should eq(1)
      file_type.defs.not_nil!.has_key?("__iyi_effect___iyi_effect_stat_file").should be_false
    end
  end

  describe "user-scope name isolation" do
    it "works when program defines its own Observe class and observe def" do
      code = <<-CODE
        module Std
          module Observe
            def self.__iyi_observe_file_read(path : String) : Nil
            end
          end
        end

        class Observe
          def self.file_read(path : String)
            raise "User Observe should not be called"
          end
        end

        def observe
          "user observe"
        end

        class File
          @[Effect(:file_read)]
          def self.read_something(path : String) : String
            "data"
          end
        end

        observe
        File.read_something("/tmp/test")
        CODE

      result = semantic(code, flags: "iyi_observe", filename: runtime_file)
      file_type = result.program.types["File"].metaclass.as(Iyi::ModuleType)
      wrapper = file_type.defs.not_nil!["read_something"].first.def
      wrapper.name.should eq("read_something")
    end
  end
end
