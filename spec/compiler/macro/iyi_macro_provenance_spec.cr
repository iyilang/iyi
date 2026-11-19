require "../../spec_helper"
require "../spec_helper"

private def provenance_semantic(code : String, filename : String)
  program = Iyi::Program.new
  program.filename = filename
  parser = program.new_parser(code)
  parser.filename = filename
  program.semantic(program.normalize(parser.parse))
end

private def provenance_marker_command : String
  {% if flag?(:win32) %}
    "cmd.exe /d /c echo executed > executed"
  {% else %}
    "printf executed > executed"
  {% end %}
end

describe "iyi package macro boundaries" do
  after_all do
    pending = Spec.cli.root_context.results_for(Spec::Status::Pending)
    own_pending = pending.select { |result| Iyi.same_file?(result.file, __FILE__) }
    raise "macro provenance examples must not be pending: #{own_pending.map(&.description).join(", ")}" unless own_pending.empty?
  end

  it "keeps a caller's yielded macro expression under the caller's package" do
    with_tempdir("iyi_macro_yield_owner") do
      root = File.expand_path("app")
      dep = File.expand_path("dep")
      Dir.mkdir_p(root)
      Dir.mkdir_p(dep)
      caller = File.join(root, "main.iyi")
      source = File.join(dep, "dep.iyi")
      File.write(caller, "")
      File.write(source, "")
      program = Iyi::Program.new
      program.filename = caller
      program.iyi_root_package = {"example.test/app", root}
      program.iyi_mod_table = [{"example.test/dep", dep}]
      program.top_level_semantic_complete = true
      parser = program.new_parser("macro check\n{{ yield }}\nend")
      parser.filename = source
      parsed_macro = parser.parse.as(Iyi::Macro)
      call_parser = program.new_parser("check do\n{{ env(\"IYI_MACRO_UNSET_CANARY\") }}\nend")
      call_parser.filename = caller
      call = call_parser.parse.as(Iyi::Call)
      expanded, pragmas = program.expand_macro(parsed_macro, call, program, program)
      parser = program.new_parser(expanded)
      parser.filename = Iyi::VirtualFile.new(parsed_macro, expanded, call.location)
      parser.macro_expansion_pragmas = pragmas
      program.semantic(program.normalize(parser.parse))
    end
  end

  it "refuses shell execution when an iyi source forges a Crystal location" do
    with_tempdir("iyi_macro_provenance") do
      source = File.join(Dir.current, "main.iyi")
      marker = File.join(Dir.current, "executed")
      command = provenance_marker_command
      code = "module main\n#<loc:\"forged.cr\",1,1>\n{% system(#{command.inspect}) %}\n"
      File.write(source, code)
      expect_raises(Iyi::TypeException, /compile-time shell commands are forbidden/) do
        provenance_semantic(code, source)
      end
      File.exists?(marker).should be_false
    end
  end

  it "keeps a Crystal source's shell macro after a forged iyi location" do
    with_tempdir("cr_macro_provenance") do
      source = File.join(Dir.current, "main.cr")
      marker = File.join(Dir.current, "executed")
      command = provenance_marker_command
      code = "#<loc:\"forged.iyi\",1,1>\n{% system(#{command.inspect}) %}\n"
      File.write(source, code)
      provenance_semantic(code, source)
      File.exists?(marker).should be_true
      File.read(marker).strip.should eq("executed")
    end
  end

  it "keeps generated macro code owned by its defining iyi source" do
    with_tempdir("iyi_macro_generated") do
      source = File.join(Dir.current, "main.iyi")
      marker = File.join(Dir.current, "executed")
      command = provenance_marker_command
      code = "module main\nmacro writer\n\\{{ system(#{command.inspect}) }}\nend\nwriter\n"
      File.write(source, code)
      expect_raises(Iyi::TypeException, /compile-time shell commands are forbidden/) do
        provenance_semantic(code, source)
      end
      File.exists?(marker).should be_false
    end
  end

  it "does not let a dependency forge its source into the root package" do
    with_tempdir("iyi_macro_forged_owner") do
      root = File.expand_path("app")
      dep = File.expand_path("dep")
      Dir.mkdir_p(root)
      Dir.mkdir_p(dep)
      source = File.join(dep, "dep.iyi")
      caller = File.join(root, "main.iyi")
      File.write(source, "")
      File.write(caller, "")
      program = Iyi::Program.new
      program.filename = caller
      program.iyi_root_package = {"example.test/app", root}
      program.iyi_mod_table = [{"example.test/dep", dep}]
      program.top_level_semantic_complete = true
      parser = program.new_parser("#<loc:#{caller.inspect},1,1>\nmacro check\n{{ env(\"IYI_MACRO_CANARY\") }}\nend")
      parser.filename = source
      parsed_macro = parser.parse.as(Iyi::Macro)
      call = Iyi::Call.new("check", [] of Iyi::ASTNode)
      call.location = Iyi::Location.new(caller, 1, 1)
      expect_raises(Iyi::TypeException, /not allowed in a dependency macro/) do
        program.expand_macro(parsed_macro, call, program, program)
      end
    end
  end
end
