require "../../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/build_inputs"
require "compiler/iyi/stale/encoding"
require "compiler/iyi/stale/compiler_env"

describe "Iyi::Stale S3c: env-only recorder, CompilerEnvFp" do
  describe "Iyi::Stale::CompilerEnv variable classification" do
    it "classifies locator variables" do
      locators = %w(
        IYI_OPTS CRYSTAL_OPTS
        IYI_PATH CRYSTAL_PATH
        IYI_CACHE_DIR CRYSTAL_CACHE_DIR
        HOME XDG_CACHE_HOME
        LOCALAPPDATA USERPROFILE
      )
      locators.each do |var|
        Iyi::Stale::CompilerEnv.variable_class(var).should eq(Iyi::Stale::CompilerEnv::VariableClass::Locator), "expected #{var} to be locator"
        Iyi::Stale::CompilerEnv.locator_class?(var).should be_true
        Iyi::Stale::CompilerEnv.value_class?(var).should be_false
      end
    end

    it "classifies display variables" do
      displays = %w(
        DUMP IYI_DUMP_TYPE_INFO IYI_DUMP_TYPE_ID IYI_TDF IYI_SYM
        IYI_HEADER_CENSUS IYI_DEBUG_CODEGEN IYI_PROF IYI_WARM
        IYI_FORK_TRACE NO_COLOR TERM
      )
      displays.each do |var|
        Iyi::Stale::CompilerEnv.variable_class(var).should eq(Iyi::Stale::CompilerEnv::VariableClass::Display), "expected #{var} to be display"
        Iyi::Stale::CompilerEnv.display_class?(var).should be_true
        Iyi::Stale::CompilerEnv.value_class?(var).should be_false
      end
    end

    it "classifies excluded variables (CHILD_ENV)" do
      Iyi::BuildInputs::CHILD_ENV.each do |var|
        Iyi::Stale::CompilerEnv.variable_class(var).should eq(Iyi::Stale::CompilerEnv::VariableClass::Excluded), "expected #{var} to be excluded"
        Iyi::Stale::CompilerEnv.excluded_class?(var).should be_true
        Iyi::Stale::CompilerEnv.value_class?(var).should be_false
      end
    end

    it "classifies everything else as value class" do
      %w(APP_PORT DATABASE_URL SECRET_KEY CUSTOM_SETTING MY_VAR).each do |var|
        Iyi::Stale::CompilerEnv.variable_class(var).should eq(Iyi::Stale::CompilerEnv::VariableClass::Value), "expected #{var} to be value"
        Iyi::Stale::CompilerEnv.value_class?(var).should be_true
      end
    end
  end

  describe "Iyi::Stale::CompilerEnv.fp" do
    it "matches golden vectors computed in Python hashlib" do
      empty_fp = Iyi::Stale::CompilerEnv.fp({} of String => String?)
      Iyi::Stale.hex(empty_fp).should eq("2a4a5fc7f3a736820884f1e4bf2a0aa8a2e6e7c1eab8eb1a49bc05f47f700509")

      foo_fp = Iyi::Stale::CompilerEnv.fp({"FOO" => "bar"})
      Iyi::Stale.hex(foo_fp).should eq("eeea422d610a911e47abd3970db9478e89510d578e9cefea0f02f92ebdc9e8f2")

      absent_fp = Iyi::Stale::CompilerEnv.fp({"FOO" => nil})
      Iyi::Stale.hex(absent_fp).should eq("0e8b655a468c704c05349e4f46c401745e5a73a71d8e3db08115ca58818bef5d")
    end

    it "ignores display and locator variables and changes with a value variable" do
      base_fp = Iyi::Stale::CompilerEnv.fp({"MY_VALUE_VAR" => "initial"})

      # Adding display variables does not change fingerprint
      display_fp = Iyi::Stale::CompilerEnv.fp({
        "MY_VALUE_VAR"     => "initial",
        "DUMP"             => "1",
        "IYI_DUMP_TYPE_ID" => "1",
        "NO_COLOR"         => "1",
        "TERM"             => "xterm",
      })
      display_fp.should eq(base_fp)

      # Adding locator variables does not change fingerprint
      locator_fp = Iyi::Stale::CompilerEnv.fp({
        "MY_VALUE_VAR"   => "initial",
        "HOME"           => "/tmp/home",
        "IYI_PATH"       => "/tmp/path",
        "IYI_CACHE_DIR"  => "/tmp/cache",
        "XDG_CACHE_HOME" => "/tmp/xdg",
      })
      locator_fp.should eq(base_fp)

      # Adding excluded variables (CHILD_ENV) does not change fingerprint when not enumerated
      excluded_fp = Iyi::Stale::CompilerEnv.fp({
        "MY_VALUE_VAR" => "initial",
        "PATH"         => "/usr/bin:/bin",
        "LIBRARY_PATH" => "/usr/lib",
      })
      excluded_fp.should eq(base_fp)

      # Changing a value variable changes fingerprint
      changed_val_fp = Iyi::Stale::CompilerEnv.fp({"MY_VALUE_VAR" => "changed"})
      changed_val_fp.should_not eq(base_fp)

      # Adding a value variable changes fingerprint
      added_val_fp = Iyi::Stale::CompilerEnv.fp({
        "MY_VALUE_VAR" => "initial",
        "ANOTHER_VAL"  => "extra",
      })
      added_val_fp.should_not eq(base_fp)

      # Value variable becoming absent changes fingerprint
      absent_val_fp = Iyi::Stale::CompilerEnv.fp({"MY_VALUE_VAR" => nil})
      absent_val_fp.should_not eq(base_fp)
    end

    it "sorts variable reads deterministically regardless of insertion order" do
      fp1 = Iyi::Stale::CompilerEnv.fp({"B_VAR" => "2", "A_VAR" => "1", "C_VAR" => "3"})
      fp2 = Iyi::Stale::CompilerEnv.fp({"C_VAR" => "3", "A_VAR" => "1", "B_VAR" => "2"})
      fp1.should eq(fp2)
    end

    it "enumeration adds every non-display non-locator variable" do
      # When enumerated is true, non-display non-locator variables are included
      env_data = {
        "MY_APP_VAR" => "hello",
        "PATH"       => "/usr/local/bin",
        "DUMP"       => "1",
        "HOME"       => "/home/iyi",
      }

      fp_enum = Iyi::Stale::CompilerEnv.fp(env_data, enumerated: true)
      # Display and locator are still ignored under enumeration
      fp_enum_no_disp_loc = Iyi::Stale::CompilerEnv.fp({
        "MY_APP_VAR" => "hello",
        "PATH"       => "/usr/local/bin",
      }, enumerated: true)

      fp_enum.should eq(fp_enum_no_disp_loc)

      # But a changed non-display non-locator variable changes the fingerprint
      fp_enum_changed = Iyi::Stale::CompilerEnv.fp({
        "MY_APP_VAR" => "hello",
        "PATH"       => "/usr/bin",
      }, enumerated: true)
      fp_enum.should_not eq(fp_enum_changed)
    end
  end

  describe "BuildInputs env-only mode" do
    it "makes file, directory, link, and run-declared hooks no-ops" do
      inputs = Iyi::BuildInputs.new(nil, env_only: true)
      inputs.env_only?.should be_true

      inputs.looked_at("/some/file.txt")
      inputs.files.should be_empty

      inputs.opening("/some/other.txt", "w")
      inputs.files.should be_empty
      inputs.written.should be_empty

      inputs.wrote("/some/out.bin")
      inputs.written.should be_empty

      inputs.deleted("/some/del.bin")
      inputs.written.should be_empty

      inputs.renamed("/from.bin", "/to.bin")
      inputs.written.should be_empty

      inputs.listed("/some/dir")
      inputs.listings.should be_empty

      inputs.pkg_config_read("glib-2.0", false, "-lglib-2.0")
      inputs.pkg_config.should be_empty

      inputs.run_declared("script.cr", ["/input.txt"], 0_i64)
      inputs.files.should be_empty

      inputs.linked("ld -o app /lib/crt0.o -lc", nil)
      inputs.files.should be_empty

      inputs.cannot("a reason that would stop UpToDate")
      inputs.reasons.should be_empty
    end

    it "ENV['X']?, fetch and has_key? are recorded" do
      inputs = Iyi::BuildInputs.new(nil, env_only: true)
      Iyi::BuildInputs.current = inputs
      begin
        # Read variable that is absent
        ENV["__IYI_SPEC_ABSENT_VAR__"]?
        # Read variable that is present
        ENV["__IYI_SPEC_PRESENT_VAR__"] = "present_val"
        ENV["__IYI_SPEC_PRESENT_VAR__"]?
        # Fetch with default
        ENV.fetch("__IYI_SPEC_FETCH_VAR__", "fallback")
        # Has key
        ENV.has_key?("__IYI_SPEC_HAS_KEY_VAR__")
      ensure
        Iyi::BuildInputs.current = nil
        ENV.delete("__IYI_SPEC_PRESENT_VAR__")
      end

      inputs.env.has_key?("__IYI_SPEC_ABSENT_VAR__").should be_true
      inputs.env["__IYI_SPEC_ABSENT_VAR__"].should be_nil

      inputs.env.has_key?("__IYI_SPEC_PRESENT_VAR__").should be_true
      inputs.env["__IYI_SPEC_PRESENT_VAR__"].should eq("present_val")

      inputs.env.has_key?("__IYI_SPEC_FETCH_VAR__").should be_true
      inputs.env["__IYI_SPEC_FETCH_VAR__"].should be_nil

      inputs.env.has_key?("__IYI_SPEC_HAS_KEY_VAR__").should be_true
      inputs.env["__IYI_SPEC_HAS_KEY_VAR__"].should be_nil
    end

    it "an enumeration is recorded whole" do
      inputs = Iyi::BuildInputs.new(nil, env_only: true)
      inputs.env_enumerated?.should be_false

      Iyi::BuildInputs.current = inputs
      begin
        ENV.each { }
      ensure
        Iyi::BuildInputs.current = nil
      end

      inputs.env_enumerated?.should be_true
      inputs.env.size.should be > 0

      # All host environment variables are recorded
      Crystal::System::Env.each do |key, value|
        inputs.env.has_key?(key).should be_true
        inputs.env[key].should eq(value)
      end
    end

    it "macro env('Y') is not recorded under an env-only recorder, and is recorded under an UpToDate recorder" do
      ENV["__IYI_SPEC_MACRO_TEST__"] = "macro_val"

      # 1. Under env-only recorder: macro env("Y") must NOT be recorded
      env_only_inputs = Iyi::BuildInputs.new(nil, env_only: true)
      Iyi::BuildInputs.current = env_only_inputs
      begin
        assert_macro %({{env("__IYI_SPEC_MACRO_TEST__")}}), %("macro_val")
      ensure
        Iyi::BuildInputs.current = nil
      end
      env_only_inputs.env.has_key?("__IYI_SPEC_MACRO_TEST__").should be_false

      # 2. Under UpToDate recorder: macro env("Y") MUST be recorded
      uptodate_inputs = Iyi::BuildInputs.new(nil, env_only: false)
      Iyi::BuildInputs.current = uptodate_inputs
      begin
        assert_macro %({{env("__IYI_SPEC_MACRO_TEST__")}}), %("macro_val")
      ensure
        Iyi::BuildInputs.current = nil
        ENV.delete("__IYI_SPEC_MACRO_TEST__")
      end
      uptodate_inputs.env.has_key?("__IYI_SPEC_MACRO_TEST__").should be_true
      uptodate_inputs.env["__IYI_SPEC_MACRO_TEST__"].should eq("macro_val")
    end

    it "macro read_file, file_exists?, and system are paused under env-only recorder" do
      env_only_inputs = Iyi::BuildInputs.new(nil, env_only: true)
      Iyi::BuildInputs.current = env_only_inputs
      begin
        assert_macro %({{file_exists?("src/compiler/iyi.cr")}}), %(true)
        assert_macro %({{read_file?("nonexistent_spec_file.txt")}}), %(nil)
        assert_macro %({{system("echo hello").strip}}), %(hello)
      ensure
        Iyi::BuildInputs.current = nil
      end

      # Nothing recorded in files or reasons
      env_only_inputs.files.should be_empty
      env_only_inputs.reasons.should be_empty
    end
  end

  describe "build verb wiring in command.cr" do
    it "stale build sets compiler.stale_key from --stale-key flag" do
      compiler = Iyi::Compiler.new
      compiler.stale_key.should be_nil

      cmd = Iyi::Command.new(%w(build --stale-key /tmp/out.json src/compiler/iyi.cr))
      compiler = cmd.prelude_compiler_for_build
      compiler.stale_key.should eq("/tmp/out.json")
    end
  end
end
