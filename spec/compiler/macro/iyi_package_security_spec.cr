require "../../spec_helper"
require "../spec_helper"

private MACRO_SECURITY_WIN32 = {{ flag?(:win32) }}

private def package_macro(body : String, definition : String, caller : String, root : String, dependency : String? = nil)
  program = Iyi::Program.new
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

  it "keeps Crystal macros able to read files outside their package" do
    with_tempdir("crystal_macro_read") do
      root = File.expand_path("app")
      Dir.mkdir_p(root)
      source = File.join(root, "macro.cr")
      outside = File.expand_path("outside")
      File.write(source, "")
      File.write(outside, "crystal compatibility")
      package_macro("{{ read_file(#{outside.inspect}) }}", source, source, root).should eq(%("crystal compatibility"))
    end
  end

  it "keeps Crystal shell macros working" do
    with_tempdir("crystal_macro_shell") do
      root = Dir.current
      source = File.join(root, "macro.cr")
      File.write(source, "")
      package_macro(%({{ system("echo crystal-compatible") }}), source, source, root).should contain("crystal-compatible")
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

  unless MACRO_SECURITY_WIN32
    it "refuses links outside the tree, even when the target is missing" do
      with_tempdir("iyi_macro_symlink") do
        root = File.expand_path("app")
        outside = File.expand_path("outside")
        Dir.mkdir_p(root)
        Dir.mkdir_p(outside)
        source = File.join(root, "main.iyi")
        File.write(source, "")
        File.write(File.join(outside, "secret"), "secret")
        File.symlink(outside, File.join(root, "link"))
        ["secret", "missing"].each do |name|
          path = File.join(root, "link", name)
          expect_raises(Iyi::TypeException, /compile-time paths must stay inside/) do
            package_macro("{{ file_exists?(#{path.inspect}) }}", source, source, root)
          end
        end
      end
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
