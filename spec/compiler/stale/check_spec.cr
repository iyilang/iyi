require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/check"
require "compiler/iyi/stale/machine_key"
require "compiler/iyi/stale/key_file"

describe "Iyi::Stale S3g: Check, MachineKey, KeyFile, Accept/Block" do
  describe "Iyi::Stale::MachineKey" do
    it "creates 32-byte machine key with mode 0600 under tests-v1/key" do
      cache_tmp = File.tempname("mach_key_test")
      Dir.mkdir_p(cache_tmp)
      begin
        key = Iyi::Stale::MachineKey.load_or_create(cache_tmp)
        key.size.should eq(32)

        key_file = File.join(cache_tmp, "tests-v1", "key")
        File.file?(key_file).should be_true
        File.read(key_file).to_slice.should eq(key)

        {% if flag?(:unix) %}
          File.info(key_file).permissions.value.to_s(8).should eq("600")
        {% end %}

        # Second load returns identical key
        key2 = Iyi::Stale::MachineKey.load_or_create(cache_tmp)
        key2.should eq(key)
      ensure
        FileUtils.rm_rf(cache_tmp)
      end
    end
  end

  describe "Iyi::Stale::KeyFile" do
    it "reads accept and block rules" do
      with_tempfile("rules.json") do |rule_path|
        File.write(rule_path, %([{"mode": "local", "build": "abcd1234"}, {"mode": "portable", "build": "5678efaa"}]))
        rules = Iyi::Stale::KeyFile.read_rules(rule_path)
        rules.size.should eq(2)
        rules[0].mode.should eq("local")
        rules[0].build.should eq("abcd1234")
        rules[1].mode.should eq("portable")
        rules[1].build.should eq("5678efaa")
      end
    end

    it "handles missing or corrupt rule files gracefully" do
      Iyi::Stale::KeyFile.read_rules("/nonexistent/path/rules.json").should be_empty

      with_tempfile("corrupt.json") do |rule_path|
        File.write(rule_path, "not json")
        Iyi::Stale::KeyFile.read_rules(rule_path).should be_empty
      end
    end

    it "writes and parses valid key file format §2.4" do
      with_tempfile("out.key") do |key_path|
        local = Iyi::Stale::KeyFile::ModeBuild.new(
          build: "a" * 64,
          toolchain: "b" * 64,
          behavior: "c" * 64,
          callpath: "d" * 64,
          link: "e" * 64,
          cenv: "f" * 64,
          explain: {"src:a.iyi" => "1" * 64, "*" => "2" * 64}
        )
        portable = Iyi::Stale::KeyFile::ModeBuild.new(
          build: "1" * 64,
          toolchain: "b" * 64,
          behavior: "c" * 64,
          callpath: "3" * 64,
          link: "4" * 64,
          cenv: "5" * 64,
          explain: {"src:a.iyi" => "6" * 64, "*" => "7" * 64}
        )
        not_reusable = [
          Iyi::Stale::KeyFile::NotReusable.new("refused build mode", "refused build mode: --no-cleanup", nil),
        ]
        hit = Iyi::Stale::KeyFile::Hit.new("local", "a" * 64)
        reach = Iyi::Stale::Reach.new

        Iyi::Stale::KeyFile.write_out(
          path: key_path,
          phase: "hit",
          test_root: "src",
          test_path: "rel/test.iyi",
          local: local,
          portable: portable,
          not_reusable: not_reusable,
          hit: hit,
          blocked: false,
          reach: reach
        )

        File.file?(key_path).should be_true
        parsed = Iyi::Stale::KeyFile.parse(File.read(key_path))
        parsed.format.should eq("iyi-stale-key")
        parsed.version.should eq(1)
        parsed.phase.should eq("hit")
        parsed.test["root"].should eq("src")
        parsed.test["path"].should eq("rel/test.iyi")
        parsed.local.not_nil!.build.should eq("a" * 64)
        parsed.portable.not_nil!.build.should eq("1" * 64)
        parsed.not_reusable.not_nil!.size.should eq(1)
        parsed.not_reusable.not_nil![0].category.should eq("refused build mode")
        parsed.hit.not_nil!.mode.should eq("local")
        parsed.blocked.should eq(false)
        parsed.reach.not_nil!["checked"].as_bool.should eq(false)
      end
    end
  end

  describe "Iyi::Stale::Check" do
    it "first check writes phase checked with valid Build" do
      program = Iyi::Program.new
      program.color = false
      parser = program.new_parser("def foo(x); x; end; a = foo(41)")
      node = program.semantic(program.normalize(parser.parse))

      with_tempfile("first.key") do |key_path|
        compiler = create_spec_compiler
        compiler.stale_key = key_path
        source = Iyi::Compiler::Source.new("test_bare.iyi", "def foo(x); x; end; a = foo(41)")

        res = Iyi::Stale::Check.run(compiler, program, node, source)
        res.hit?.should be_false
        res.blocked?.should be_false
        res.not_reusable.should be_empty
        res.local_build_hex.size.should eq(64)
        res.portable_build_hex.size.should eq(64)

        File.file?(key_path).should be_true
        data = Iyi::Stale::KeyFile.parse(File.read(key_path))
        data.format.should eq("iyi-stale-key")
        data.version.should eq(1)
        data.phase.should eq("checked")
        data.local.not_nil!.build.should eq(res.local_build_hex)
        data.portable.not_nil!.build.should eq(res.portable_build_hex)
        data.hit.should be_nil
        data.blocked.should eq(false)
      end
    end

    it "second check hits when --stale-accept holds local Build" do
      program = Iyi::Program.new
      program.color = false
      parser = program.new_parser("def foo(x); x; end; a = foo(41)")
      node = program.semantic(program.normalize(parser.parse))

      with_tempfile("run1.key") do |key1_path|
        compiler = create_spec_compiler
        compiler.stale_key = key1_path
        source = Iyi::Compiler::Source.new("test_bare.iyi", "def foo(x); x; end; a = foo(41)")

        res1 = Iyi::Stale::Check.run(compiler, program, node, source)
        local_build = res1.local_build_hex

        with_tempfile("run2.key") do |key2_path|
          with_tempfile("accept.json") do |accept_path|
            File.write(accept_path, %([{"mode": "local", "build": "#{local_build}"}]))

            compiler2 = create_spec_compiler
            compiler2.stale_key = key2_path
            compiler2.stale_accept = accept_path

            res2 = Iyi::Stale::Check.run(compiler2, program, node, source)
            res2.hit?.should be_true
            res2.hit.not_nil!.mode.should eq("local")
            res2.hit.not_nil!.build.should eq(local_build)

            File.file?(key2_path).should be_true
            data2 = Iyi::Stale::KeyFile.parse(File.read(key2_path))
            data2.phase.should eq("hit")
            data2.hit.not_nil!.mode.should eq("local")
            data2.hit.not_nil!.build.should eq(local_build)
          end
        end
      end
    end

    it "second check hits when --stale-accept holds portable Build" do
      program = Iyi::Program.new
      program.color = false
      parser = program.new_parser("def foo(x); x; end; a = foo(41)")
      node = program.semantic(program.normalize(parser.parse))

      with_tempfile("run1.key") do |key1_path|
        compiler = create_spec_compiler
        compiler.stale_key = key1_path
        source = Iyi::Compiler::Source.new("test_bare.iyi", "def foo(x); x; end; a = foo(41)")

        res1 = Iyi::Stale::Check.run(compiler, program, node, source)
        port_build = res1.portable_build_hex

        with_tempfile("run2.key") do |key2_path|
          with_tempfile("accept.json") do |accept_path|
            File.write(accept_path, %([{"mode": "portable", "build": "#{port_build}"}]))

            compiler2 = create_spec_compiler
            compiler2.stale_key = key2_path
            compiler2.stale_accept = accept_path

            res2 = Iyi::Stale::Check.run(compiler2, program, node, source)
            res2.hit?.should be_true
            res2.hit.not_nil!.mode.should eq("portable")
            res2.hit.not_nil!.build.should eq(port_build)

            File.file?(key2_path).should be_true
            data2 = Iyi::Stale::KeyFile.parse(File.read(key2_path))
            data2.phase.should eq("hit")
            data2.hit.not_nil!.mode.should eq("portable")
            data2.hit.not_nil!.build.should eq(port_build)
          end
        end
      end
    end

    it "matching block entry wins over accept: blocked: true, hit: nil" do
      program = Iyi::Program.new
      program.color = false
      parser = program.new_parser("def foo(x); x; end; a = foo(41)")
      node = program.semantic(program.normalize(parser.parse))

      with_tempfile("run1.key") do |key1_path|
        compiler = create_spec_compiler
        compiler.stale_key = key1_path
        source = Iyi::Compiler::Source.new("test_bare.iyi", "def foo(x); x; end; a = foo(41)")

        res1 = Iyi::Stale::Check.run(compiler, program, node, source)
        local_build = res1.local_build_hex

        with_tempfile("run2.key") do |key2_path|
          with_tempfile("accept.json") do |accept_path|
            with_tempfile("block.json") do |block_path|
              File.write(accept_path, %([{"mode": "local", "build": "#{local_build}"}]))
              File.write(block_path, %([{"mode": "local", "build": "#{local_build}"}]))

              compiler2 = create_spec_compiler
              compiler2.stale_key = key2_path
              compiler2.stale_accept = accept_path
              compiler2.stale_block = block_path

              res2 = Iyi::Stale::Check.run(compiler2, program, node, source)
              res2.blocked?.should be_true
              res2.hit?.should be_false

              data2 = Iyi::Stale::KeyFile.parse(File.read(key2_path))
              data2.blocked.should eq(true)
              data2.phase.should eq("checked")
              data2.hit.should be_nil
            end
          end
        end
      end
    end

    it "--no-cleanup refuses and prevents hit" do
      program = Iyi::Program.new
      program.color = false
      parser = program.new_parser("def foo; 10; end; a = foo")
      node = program.semantic(program.normalize(parser.parse))

      with_tempfile("nc.key") do |key_path|
        compiler = create_spec_compiler
        compiler.stale_key = key_path
        compiler.no_cleanup = true
        source = Iyi::Compiler::Source.new("test_nc.iyi", "def foo; 10; end; a = foo")

        res = Iyi::Stale::Check.run(compiler, program, node, source)
        res.not_reusable.any? do |nr|
          nr.category == "refused build mode" && nr.reason.includes?("--no-cleanup")
        end.should be_true
        res.hit?.should be_false
      end
    end

    it "crystal_library gives category crystal reason" do
      program = Iyi::Program.new
      program.color = false
      parser = program.new_parser("def foo; 20; end; a = foo")
      node = program.semantic(program.normalize(parser.parse))

      with_tempfile("cr.key") do |key_path|
        compiler = create_spec_compiler
        compiler.stale_key = key_path
        compiler.crystal_library = true
        source = Iyi::Compiler::Source.new("test_cr.iyi", "def foo; 20; end; a = foo")

        res = Iyi::Stale::Check.run(compiler, program, node, source)
        crystal_reasons = res.not_reusable.select { |nr| nr.category == "crystal" }
        crystal_reasons.size.should be >= 1
        crystal_reasons[0].reason.should eq("Crystal library effects are not classified")
        res.hit?.should be_false
      end
    end

    it "dumps elements with --stale-dump-elements" do
      program = Iyi::Program.new
      program.color = false
      parser = program.new_parser("def test_dump; 600; end; x = test_dump")
      node = program.semantic(program.normalize(parser.parse))

      with_tempfile("dump.key") do |key_path|
        with_tempfile("dump.jsonl") do |dump_path|
          compiler = create_spec_compiler
          compiler.stale_key = key_path
          compiler.stale_dump_elements = dump_path
          source = Iyi::Compiler::Source.new("test_dump.iyi", "def test_dump; 600; end; x = test_dump")

          Iyi::Stale::Check.run(compiler, program, node, source)

          File.file?(dump_path).should be_true
          lines = File.read_lines(dump_path)
          lines.size.should be > 0
          lines.each do |line|
            json = JSON.parse(line)
            json["kind"]?.should_not be_nil
            json["key"]?.should_not be_nil
            json["digest"]?.should_not be_nil
          end
        end
      end
    end
  end

  describe "Compiler error behavior with stale_key" do
    it "writes no key file on semantic error and raises exception" do
      with_tempfile("type_err.key") do |key_path|
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.stale_key = key_path

        code = <<-IYI
        a = 1 + "foo"
        IYI

        source = Iyi::Compiler::Source.new("test_type_err.iyi", code)
        bin_path = File.tempname("test_type_err", nil)

        expect_raises(Iyi::TypeException) do
          compiler.compile(source, bin_path)
        end

        File.file?(key_path).should be_false
      end
    end

    it "leaves phase checked when link fails after check" do
      with_tempfile("link_fail.key") do |key_path|
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.stale_key = key_path

        code = <<-IYI
        lib MissingLib
          fun missing_symbol_12345 : Void
        end
        MissingLib.missing_symbol_12345
        IYI

        source = Iyi::Compiler::Source.new("test_link_fail.iyi", code)
        bin_path = File.tempname("test_link_fail", nil)

        expect_raises(Iyi::CompilerError) do
          compiler.compile(source, bin_path)
        end

        File.file?(key_path).should be_true
        data = Iyi::Stale::KeyFile.parse(File.read(key_path))
        data.phase.should eq("checked")
        data.local.not_nil!.build.size.should eq(64)
      end
    end
  end
end
