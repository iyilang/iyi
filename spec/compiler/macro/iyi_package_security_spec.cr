require "../../spec_helper"
require "../spec_helper"

{% if flag?(:win32) %}
  lib LibC
    fun GetShortPathNameW(path : UInt16*, buffer : UInt16*, size : UInt32) : UInt32
  end
{% end %}

private def package_link(target : String, link : String) : Nil
  {% if flag?(:win32) %}
    output = IO::Memory.new
    result = Process.run("cmd.exe", ["/c", "mklink", "/J", link, target], output: output, error: output)
    raise "could not create junction: #{output}" unless result.success?
  {% else %}
    File.symlink(target, link)
  {% end %}
end

private MACRO_SECURITY_WINDOWS = {{ flag?(:win32) }}

private def package_windows_spellings(path : String) : Array(String)
  {% if flag?(:win32) %}
    absolute = File.expand_path(path)
    verbatim = if absolute.starts_with?("\\\\")
                 "\\\\?\\UNC\\#{absolute[2..]}"
               else
                 "\\\\?\\#{absolute}"
               end
    spellings = [absolute.tr("\\", "/"), verbatim, absolute[0].to_s.downcase + absolute[1..]]
    buffer = Slice(UInt16).new(32768)
    size = LibC.GetShortPathNameW(Crystal::System.to_wstr(absolute), buffer, buffer.size)
    spellings << String.from_utf16(buffer[0, size]) if 0 < size < buffer.size
    spellings
  {% else %}
    [] of String
  {% end %}
end

private def package_macro(body : String, definition : String, caller : String, root : String, dependency : String? = nil, *, program : Iyi::Program = Iyi::Program.new)
  program.filename = File.join(root, "main.iyi")
  program.iyi_root_package = {"example.test/app", root}
  if dependency
    program.iyi_mod_table = [{"example.test/dep", dependency}]
  end
  program.top_level_semantic_complete = true
  parser = program.new_parser("macro check\n#{body}\nend")
  parser.filename = definition
  parsed_macro = parser.parse.as(Iyi::Macro)
  call = Iyi::Call.new("check", [] of Iyi::ASTNode)
  call.location = Iyi::Location.new(caller, 1, 1)
  program.expand_macro(parsed_macro, call, program, program)[0].chomp
end

describe "iyi package macro boundaries" do
  after_all do
    pending = Spec.cli.root_context.results_for(Spec::Status::Pending)
    own_pending = pending.select { |result| Iyi.same_file?(result.file, __FILE__) }
    raise "macro boundary examples must not be pending: #{own_pending.map(&.description).join(", ")}" unless own_pending.empty?
  end

  it "refuses system and backticks in a root file and in an imported macro" do
    with_tempdir("iyi_macro_shell") do
      root = File.expand_path("app")
      dep = File.expand_path("dep")
      Dir.mkdir_p(root)
      Dir.mkdir_p(dep)
      main = File.join(root, "main.iyi")
      other = File.join(dep, "dep.iyi")
      File.write(main, "")
      File.write(other, "")
      ["{{ system(\"echo macro-shell\") }}", "{{ `echo macro-shell` }}"].each do |body|
        [{main, main}, {other, main}].each do |definition, caller|
          ex = expect_raises(Iyi::TypeException) do
            package_macro(body, definition, caller, root, dep)
          end
          ex.message.not_nil!.should contain("compile-time shell commands are forbidden")
          ex.message.not_nil!.should contain(definition)
          ex.message.not_nil!.should contain(":2")
        end
      end
    end
  end

  it "also refuses shell commands in a Crystal macro expanded by an iyi file" do
    with_tempdir("iyi_macro_expansion") do
      root = Dir.current
      definition = File.join(root, "macro.cr")
      caller = File.join(root, "main.iyi")
      File.write(definition, "")
      File.write(caller, "")
      expect_raises(Iyi::TypeException, /compile-time shell commands are forbidden/) do
        package_macro("{{ system(\"echo macro-shell\") }}", definition, caller, root)
      end
    end
  end

  it "keeps .cr macros able to read files outside their package" do
    with_tempdir("compat_macro_read") do
      root = File.expand_path("app")
      Dir.mkdir_p(root)
      source = File.join(root, "macro.cr")
      outside = File.expand_path("outside")
      File.write(source, "")
      File.write(outside, "compatible")
      package_macro("{{ read_file(#{outside.inspect}) }}", source, source, root).should eq(%("compatible"))
    end
  end

  it "keeps .cr shell macros working" do
    with_tempdir("compat_macro_shell") do
      root = Dir.current
      source = File.join(root, "macro.cr")
      File.write(source, "")
      package_macro(%({{ system("echo compatible") }}), source, source, root).should contain("compatible")
    end
  end

  it "reads its own tree, accepts an internal parent component, and returns false for a missing file" do
    with_tempdir("iyi_macro_own_files") do
      root = File.expand_path("app")
      Dir.mkdir_p(File.join(root, "sub"))
      Dir.mkdir_p(File.join(root, "assets"))
      source = File.join(root, "sub", "main.iyi")
      asset = File.join(root, "assets", "font")
      File.write(source, "")
      File.write(asset, "font data")
      internal_parent = File.join(root, "sub", "..", "assets", "font")
      package_macro("{{ read_file(#{internal_parent.inspect}) }}", source, source, root).should eq(%("font data"))
      missing = File.join(root, "assets", "missing")
      package_macro("{{ file_exists?(#{missing.inspect}) }}", source, source, root).should eq("false")
      package_macro("{{ read_file?(#{missing.inspect}) }}", source, source, root).should eq("nil")
    end
  end

  it "refuses outside files for all three readers, including absent paths" do
    with_tempdir("iyi_macro_outside") do
      root = File.expand_path("app")
      Dir.mkdir_p(root)
      source = File.join(root, "main.iyi")
      outside = File.expand_path("app-other")
      Dir.mkdir_p(outside)
      File.write(source, "")
      File.write(File.join(outside, "secret"), "secret")
      ["read_file", "read_file?", "file_exists?"].each do |method|
        [File.join(outside, "secret"), File.join(root, "..", "app-other", "absent")].each do |path|
          expect_raises(Iyi::TypeException, /compile-time paths must stay inside/) do
            package_macro("{{ #{method}(#{path.inspect}) }}", source, source, root)
          end
        end
      end
    end
  end

  it "refuses a link or junction outside the tree, even for missing targets" do
    with_tempdir("iyi_macro_symlink") do
      root = File.expand_path("app")
      outside = File.expand_path("outside")
      Dir.mkdir_p(root)
      Dir.mkdir_p(outside)
      source = File.join(root, "main.iyi")
      File.write(source, "")
      File.write(File.join(outside, "secret"), "secret")
      package_link(outside, File.join(root, "link"))
      ["secret", "missing"].each do |name|
        path = File.join(root, "link", name)
        ["read_file", "read_file?", "file_exists?"].each do |method|
          expect_raises(Iyi::TypeException, /compile-time paths must stay inside/) do
            package_macro("{{ #{method}(#{path.inspect}) }}", source, source, root)
          end
        end
      end
      File.write(File.join(outside, "helper.cr"), "puts 123")
      helper = File.join(root, "link", "helper.cr")
      expect_raises(Iyi::TypeException, /compile-time paths must stay inside/) do
        package_macro("{{ run(#{helper.inspect}) }}", source, source, root)
      end
    end
  end

  it "keeps a nested dependency's privileges when its root uses an alias" do
    with_tempdir("iyi_macro_alias") do
      real = File.expand_path("real")
      alias_dir = File.expand_path("alias")
      dep = File.join(real, "app", "vendor", "dep")
      Dir.mkdir_p(dep)
      package_link(real, alias_dir)
      root = File.join(alias_dir, "app")
      source = File.join(root, "vendor", "dep", "dep.iyi")
      own = File.join(dep, "asset")
      secret = File.join(root, "secret")
      File.write(File.join(root, "main.iyi"), "")
      File.write(source, "")
      File.write(own, "inside")
      File.write(secret, "outside")
      package_macro("{{ read_file(#{own.inspect}) }}", source, source, root, dep).should eq(%("inside"))
      expect_raises(Iyi::TypeException, /compile-time paths must stay inside/) do
        package_macro("{{ read_file(#{secret.inspect}) }}", source, source, root, dep)
      end
      expect_raises(Iyi::TypeException, /not allowed in a dependency macro/) do
        package_macro(%({{ env("IYI_MACRO_CANARY") }}), source, source, root, dep)
      end
    end
  end

  it "follows links and parent components in the platform's order" do
    with_tempdir("iyi_macro_parent") do
      root = File.expand_path("app")
      inner = File.join(root, "inner")
      nested = File.join(root, "deep", "nested")
      Dir.mkdir_p(inner)
      Dir.mkdir_p(nested)
      source = File.join(root, "main.iyi")
      File.write(source, "")
      File.write(File.join(root, "deep", "asset"), "deep")
      File.write(File.join(inner, "asset"), "inner")
      package_link(nested, File.join(inner, "link"))
      path = File.join(inner, "link", "..", "asset")
      expected = MACRO_SECURITY_WINDOWS ? %("inner") : %("deep")
      package_macro("{{ read_file(#{path.inspect}) }}", source, source, root).should eq(expected)
    end
  end

  it "compares path casing according to the actual filesystem" do
    with_tempdir("iyi_macro_case") do
      root = File.expand_path("CaseApp")
      Dir.mkdir_p(root)
      source = File.join(root, "main.iyi")
      File.write(source, "")
      File.write(File.join(root, "asset"), "inside")
      alternate = File.join(File.dirname(root), "CASEAPP", "asset")
      if File.exists?(alternate)
        package_macro("{{ read_file(#{alternate.inspect}) }}", source, source, root).should eq(%("inside"))
      else
        expect_raises(Iyi::TypeException, /compile-time paths must stay inside/) do
          package_macro("{{ read_file?(#{alternate.inspect}) }}", source, source, root)
        end
      end
      package_windows_spellings(File.join(root, "asset")).each do |path|
        package_macro("{{ read_file(#{path.inspect}) }}", source, source, root).should eq(%("inside"))
      end
      outside = File.expand_path("outside")
      File.write(outside, "outside")
      package_windows_spellings(outside).each do |path|
        expect_raises(Iyi::TypeException, /compile-time paths must stay inside/) do
          package_macro("{{ read_file(#{path.inspect}) }}", source, source, root)
        end
      end
      if MACRO_SECURITY_WINDOWS
        unc_root = Iyi.path_key("\\\\server\\share\\pkg")
        unc_sibling = Iyi.path_key("\\\\?\\UNC\\server\\share\\pkg-evil\\file")
        Iyi.path_under?(unc_sibling, unc_root).should be_nil
      end
    end
  end

  it "reuses library roots only while they still name the same directories" do
    with_tempdir("iyi_macro_library_cache") do
      root = File.expand_path("app")
      library = File.expand_path("library")
      first = File.expand_path("first")
      second = File.expand_path("second")
      [root, first, second, File.join(library, "iyi")].each { |dir| Dir.mkdir_p(dir) }
      source = File.join(root, "main.iyi")
      File.write(source, "")
      File.write(File.join(library, "iyi", "prelude.iyi"), "")
      File.write(File.join(first, "asset"), "first")
      File.write(File.join(second, "asset"), "second")
      link = File.join(library, "std")
      package_link(first, link)
      program = Iyi::Program.new
      program.iyi_path = Iyi::IyiPath.new([library])
      first_asset = File.join(first, "asset")
      command = "{{ read_file(#{first_asset.inspect}) }}"
      package_macro(command, source, source, root, program: program).should eq(%("first"))
      cached = program.iyi_macro_library_roots[link]
      package_macro(command, source, source, root, program: program).should eq(%("first"))
      program.iyi_macro_library_roots[link].same?(cached).should be_true

      File.delete(link)
      package_link(second, link)
      second_asset = File.join(second, "asset")
      package_macro("{{ read_file(#{second_asset.inspect}) }}", source, source, root, program: program).should eq(%("second"))
      expect_raises(Iyi::TypeException, /compile-time paths must stay inside/) do
        package_macro(command, source, source, root, program: program)
      end
      Iyi.same_file?(program.iyi_macro_library_roots[link], second).should be_true
    end
  end

  it "does not give a dependency access to the consumer's files or environment" do
    with_tempdir("iyi_macro_dependency") do
      root = File.expand_path("app")
      dep = File.expand_path("dep")
      Dir.mkdir_p(root)
      Dir.mkdir_p(dep)
      main = File.join(root, "main.iyi")
      source = File.join(dep, "dep.iyi")
      secret = File.join(root, "secret")
      File.write(main, "")
      File.write(source, "")
      File.write(secret, "secret")
      own_file = File.join(dep, "asset")
      File.write(own_file, "dependency data")
      package_macro("{{ read_file(#{own_file.inspect}) }}", source, main, root, dep).should eq(%("dependency data"))
      standard = File.expand_path("../../../src/std/eiy.iyi", __DIR__)
      prelude = File.expand_path("../../../src/iyi/prelude.iyi", __DIR__)
      [standard, prelude].each do |path|
        package_macro("{{ file_exists?(#{path.inspect}) }}", source, main, root, dep).should eq("true")
      end
      expect_raises(Iyi::TypeException, /compile-time paths must stay inside/) do
        package_macro("{{ read_file(#{secret.inspect}) }}", source, main, root, dep)
      end
      expect_raises(Iyi::TypeException, /not allowed in a dependency macro/) do
        package_macro(%({{ env("IYI_MACRO_CANARY") }}), source, main, root, dep)
      end
      package_macro(%({{ env("IYI_MACRO_UNSET_CANARY") }}), main, main, root, dep).should eq("nil")
    end
  end

  it "refuses a run helper outside the defining package" do
    with_tempdir("iyi_macro_run") do
      root = File.expand_path("app")
      Dir.mkdir_p(root)
      source = File.join(root, "main.iyi")
      helper = File.expand_path("outside.cr")
      File.write(source, "")
      File.write(helper, "puts 123")
      expect_raises(Iyi::TypeException, /compile-time paths must stay inside/) do
        package_macro("{{ run(#{helper.inspect}) }}", source, source, root)
      end
    end
  end
end
