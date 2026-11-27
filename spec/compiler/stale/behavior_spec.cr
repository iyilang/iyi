require "../../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/toolchain"

describe "Iyi::Stale S2: behavior key, toolchain digest, refused modes" do
  describe "Compiler#behavior_key" do
    it "-s leaves behavior_key unchanged" do
      c1 = Iyi::Compiler.new
      key1 = c1.behavior_key

      c2 = Iyi::Compiler.new
      c2.progress_tracker = Iyi::ProgressTracker.new
      key2 = c2.behavior_key

      key1.should eq(key2)
    end

    it "--verbose leaves behavior_key unchanged" do
      c1 = Iyi::Compiler.new
      key1 = c1.behavior_key

      c2 = Iyi::Compiler.new
      c2.verbose = true
      key2 = c2.behavior_key

      key1.should eq(key2)
    end

    it "stale paths leave behavior_key unchanged" do
      c1 = Iyi::Compiler.new
      key1 = c1.behavior_key

      c2 = Iyi::Compiler.new
      c2.stale_key = "/tmp/out.json"
      c2.stale_accept = "/tmp/accept.json"
      c2.stale_block = "/tmp/block.json"
      c2.stale_dump_elements = "/tmp/elements.json"
      key2 = c2.behavior_key

      key1.should eq(key2)
    end

    it "--release changes behavior_key" do
      c1 = Iyi::Compiler.new
      key1 = c1.behavior_key

      c2 = Iyi::Compiler.new
      c2.release!
      key2 = c2.behavior_key

      key1.should_not eq(key2)
    end

    it "distinguishes --release from equivalent optimization and module settings" do
      released = Iyi::Compiler.new
      released.release!

      optimized = Iyi::Compiler.new
      optimized.optimization_mode = released.optimization_mode
      optimized.single_module = true

      released.behavior_key.should_not eq(optimized.behavior_key)
    end

    it "-Dx changes behavior_key" do
      c1 = Iyi::Compiler.new
      key1 = c1.behavior_key

      c2 = Iyi::Compiler.new
      c2.flags << "x"
      key2 = c2.behavior_key

      key1.should_not eq(key2)
    end

    it "--mcpu changes behavior_key" do
      c1 = Iyi::Compiler.new
      key1 = c1.behavior_key

      c2 = Iyi::Compiler.new
      c2.mcpu = "cortex-a53"
      key2 = c2.behavior_key

      key1.should_not eq(key2)
    end
  end

  describe "Compiler#stale_refusals" do
    it "yields reason for --no-cleanup" do
      c = Iyi::Compiler.new
      c.no_cleanup = true
      refusals = c.stale_refusals
      refusals.should_not be_empty
      refusals.any?(&.includes?("--no-cleanup")).should be_true
    end

    it "yields reason for --emit" do
      c = Iyi::Compiler.new
      c.emit_targets = Iyi::Compiler::EmitTarget::OBJ
      refusals = c.stale_refusals
      refusals.should_not be_empty
      refusals.any?(&.includes?("--emit")).should be_true
    end

    it "yields reason for --emit-iyimod" do
      c = Iyi::Compiler.new
      c.emit_iyimod = "/tmp/iyimod"
      refusals = c.stale_refusals
      refusals.should_not be_empty
      refusals.any?(&.includes?("--emit-iyimod")).should be_true
    end

    it "yields reason for --emit-bind" do
      c = Iyi::Compiler.new
      c.emit_bind = "/tmp/bind"
      refusals = c.stale_refusals
      refusals.should_not be_empty
      refusals.any?(&.includes?("--emit-bind")).should be_true
    end

    it "yields reason for --iyi-keep" do
      c = Iyi::Compiler.new
      c.iyi_keep = "Calc"
      refusals = c.stale_refusals
      refusals.should_not be_empty
      refusals.any?(&.includes?("--iyi-keep")).should be_true
    end

    it "yields reason for --cross-compile" do
      c = Iyi::Compiler.new
      c.cross_compile = true
      refusals = c.stale_refusals
      refusals.should_not be_empty
      refusals.any?(&.includes?("--cross-compile")).should be_true
    end

    it "yields reason for --no-codegen" do
      c = Iyi::Compiler.new
      c.no_codegen = true
      refusals = c.stale_refusals
      refusals.should_not be_empty
      refusals.any?(&.includes?("--no-codegen")).should be_true
    end

    it "yields reason for IYI_FORK_PROBE" do
      c = Iyi::Compiler.new
      ENV["IYI_FORK_PROBE"] = "1"
      begin
        refusals = c.stale_refusals
        refusals.should_not be_empty
        refusals.any?(&.includes?("IYI_FORK_PROBE")).should be_true
      ensure
        ENV.delete("IYI_FORK_PROBE")
      end
    end

    it "is empty when no refused modes are active" do
      c = Iyi::Compiler.new
      c.stale_refusals.should be_empty
    end
  end

  describe "Stale::Toolchain.digest" do
    it "is equal across calls and differs for a different executable" do
      with_tempfile("stale_toolchain_cache") do |cache_dir|
        Dir.mkdir_p(cache_dir)
        # The spec executable was just linked; let its racy interval pass.
        sleep 250.milliseconds
        d1 = Iyi::Stale::Toolchain.digest(cache_dir)
        d2 = Iyi::Stale::Toolchain.digest(cache_dir)
        d1.should eq(d2)

        memo_dir = File.join(cache_dir, "tests-v1", "toolchain")
        Dir.exists?(memo_dir).should be_true
        Dir.children(memo_dir).should_not be_empty

        # Different executable yields different digest
        with_tempfile("dummy_exe_1") do |exe1|
          File.write(exe1, "compiler_binary_v1")
          File.chmod(exe1, 0o755)

          with_tempfile("dummy_exe_2") do |exe2|
            File.write(exe2, "compiler_binary_v2_different_content")
            File.chmod(exe2, 0o755)

            d_exe1 = Iyi::Stale::Toolchain.digest(cache_dir, exe1)
            d_exe2 = Iyi::Stale::Toolchain.digest(cache_dir, exe2)
            d_exe1.should_not eq(d_exe2)
          end
        end
      end
    end
  end

  describe "Stale::Toolchain required inputs" do
    it "does not identify an import thunk or a missing LLVM module as static" do
      compiler = "/app/iyi.exe"
      dll = "/app/LLVM-C.dll"
      Iyi::Stale::Toolchain.windows_llvm_identity(compiler, dll, false).should eq({dll, true})
      Iyi::Stale::Toolchain.windows_llvm_identity(compiler, nil, true).should eq({"static", false})
      expect_raises(Iyi::Stale::Toolchain::ImageChangedError, "loaded LLVM-C.dll cannot be identified") do
        Iyi::Stale::Toolchain.windows_llvm_identity(compiler, compiler, false)
      end
      expect_raises(Iyi::Stale::Toolchain::ImageChangedError, "loaded LLVM-C.dll cannot be identified") do
        Iyi::Stale::Toolchain.windows_llvm_identity(compiler, nil, false)
      end
    end

    it "does not turn an unreadable input into a digest" do
      with_tempfile("missing_toolchain_dir") do |dir|
        Dir.mkdir_p(dir)
        expect_raises(File::Error) do
          Iyi::Stale::Toolchain.file_sha256(File.join(dir, "missing"))
        end
      end
    end

    it "rehashes a copied linker after a same-size edit with restored mtime" do
      with_tempfile("stale_toolchain_cache") do |cache_dir|
        Dir.mkdir_p(cache_dir)
        with_tempfile("linker_original") do |original|
          with_tempfile({{ flag?(:win32) ? "linker_copy" : "linker\\copy" }}) do |linker|
            File.write(original, "linker fixture A")
            File.copy(original, linker)
            timestamp = Time.utc(2020, 1, 2)
            File.utime(timestamp, timestamp, linker)
            sleep 250.milliseconds

            first = Iyi::Stale::Toolchain.digest(cache_dir, linker_override: linker)
            Iyi::Stale::Toolchain.digest(cache_dir, linker_override: linker).should eq(first)
            memo_dir = File.join(cache_dir, "tests-v1", "toolchain")
            memo_names = Dir.children(memo_dir)
            memo_names.should_not be_empty
            memo = JSON.parse(File.read(File.join(memo_dir, memo_names.first)))
            memo["linker_path"].as_s.should eq(File.realpath(linker))
            memo["toolchain"].as_s.should eq(Iyi::Stale.hex(first))

            File.write(linker, "linker fixture B")
            File.utime(timestamp, timestamp, linker)
            File.info(linker).modification_time.should eq(timestamp)
            Iyi::Stale::Toolchain.digest(cache_dir, linker_override: linker).should_not eq(first)
          end
        end
      end
    end
  end

  describe "Config.build_inputs" do
    it "returns string or nil when absent" do
      bi = Iyi::Config.build_inputs
      if bi
        bi.should match(/\A[0-9a-f]{64}\z/)
      end
    end
  end
end
