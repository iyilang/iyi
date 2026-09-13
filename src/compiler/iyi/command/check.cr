# iyi: `iyi check` — the front end's verdict and nothing else.
#
# The cheapest question an agent can ask the compiler is "is this
# program well-typed?". `check` is `build --no-codegen` with its name
# said plainly — no object files, no linker, no artifact; the verdict is
# the exit code, and under `-f json` every error arrives as data,
# `suggested_edit` included.
#
# The blind spot this verb once patched is now the language's own rule:
# definition-site typing (semantic/definition_typing.cr) types every
# fully declared def at its definition, in every compile — so `check`
# is one pass again, and a build, the LSP and this verb cannot disagree
# about what "clean" means. The verb that grew the probe kept none of
# it; the compiler did.
require "../mod/installer"

class Iyi::Command
  private def check
    selfhost = options.delete("--selfhost") != nil
    parse_only = options.delete("--parse-only") != nil

    if options.first?.in?("--help", "-h")
      puts <<-USAGE
        Usage: #{Command.program_name} check [switches] [program file]
               #{Command.program_name} check --parse-only [--selfhost] [file or directory ...]
               #{Command.program_name} check --affected CHANGED [--affected CHANGED]...

        Type-check the program and produce nothing: no codegen, no
        binary. Exit 0 means well-typed; errors print like a build's,
        and `-f json` makes each one data — file, line, column, size,
        message, the SPEC sections it cites, and, when the compiler
        knows the fix, a `suggested_edit` with the exact replacement.

        `--parse-only` checks syntax only without semantic or type analysis.
        Combine with `--selfhost` to use the pure iyi self-hosted parser.

        Every def with a fully written signature is typed even if
        nothing calls it — definition-site typing is the language's
        rule, and R-2's declared types stand in for the missing caller.

        `--affected CHANGED` (repeatable) checks the ripple instead of
        one file: every .iyi under the current directory whose imports
        reach a changed file is compiled alone, and every failure is
        named.
        USAGE
      exit
    end

    if selfhost && !parse_only
      abort! "iyi check: --selfhost currently requires --parse-only (full self-hosted pipeline is not yet wired)", :USAGE_ERROR
    end

    if parse_only
      check_parse_only(selfhost: selfhost)
      return
    end

    # `--affected CHANGED...`: the ripple check. `test --affected` answers
    # "which tests re-run"; this answers the sibling question "does
    # everyone who imports the change still compile" — every .iyi file
    # whose parsed import closure reaches a changed file is compiled
    # alone, and every failure is named. A deleted changed file fails its
    # consumers here naturally, which is the loud answer this verb owes
    # (test selection, which cannot afford to guess, turns its discount
    # off instead).
    if options.includes?("--affected")
      return check_affected
    end

    compile_no_codegen "check"

    # Nothing to print on success: the verdict is the exit code, the
    # same contract `test` and `vet` keep. Errors never reach this line —
    # they raise out to the one rescue that serves every verb.
    report_warnings
    exit 1 if warnings_fail_on_exit?
  end

  # Everyone the change can reach, each compiled alone. The universe is
  # every .iyi file under the current directory; membership is the same
  # parsed closure `test --affected` trusts. Failures are collected, not
  # raised: the caller asked about the whole ripple, and stopping at the
  # first consumer would answer a smaller question than the one asked.
  private def check_affected : Nil
    as_json = false
    changed = [] of String
    while option = options.shift?
      case option
      when "--affected"
        value = options.shift?
        abort! "--affected takes a changed file", :USAGE_ERROR unless value
        changed << File.expand_path(value)
      when "-f"
        as_json = options.shift? == "json"
      when "--json"
        as_json = true
      else
        abort! "check --affected takes only changed files; unexpected '#{option}'", :USAGE_ERROR
      end
    end
    abort! "check --affected: name at least one changed file", :USAGE_ERROR if changed.empty?

    consumers = [] of String
    Dir.glob("**/*.iyi") do |candidate|
      closure = test_import_closure(candidate)
      consumers << candidate if closure.nil? || changed.any? { |path| closure.includes?(path) }
    end
    consumers.sort!

    failures = [] of {String, CodeError}
    consumers.each do |consumer|
      if error = check_one_alone(consumer)
        failures << {consumer, error}
      end
    end

    if as_json
      JSON.build(STDOUT) do |json|
        json.object do
          json.field "checked" do
            json.array { consumers.each { |consumer| json.string consumer } }
          end
          json.field "failed" do
            json.array do
              failures.each do |(consumer, error)|
                json.object do
                  json.field "file", consumer
                  json.field "errors" { json.raw error.to_json }
                end
              end
            end
          end
        end
      end
      STDOUT.puts
    else
      failures.each do |(consumer, error)|
        deepest = error.is_a?(TypeException) ? error.deepest_error_message.to_s : error.message.to_s
        puts "#{consumer}: #{deepest.lines.first?}"
      end
      verdict = failures.empty? ? "all compile" : "#{failures.size} broke"
      puts "#{consumers.size} consumer(s) checked, #{verdict}"
    end

    exit failures.empty? ? 0 : 1
  end

  # One consumer, compiled alone. Definition-site typing rides in the
  # compiler itself now, so this is a plain front-end compile.
  private def check_one_alone(path : String) : CodeError?
    expanded = File.expand_path(path)
    compiler = Compiler.new
    compiler.prelude = "iyi/prelude"
    compiler.no_codegen = true
    compiler.stdout = IO::Memory.new
    compiler.stderr = IO::Memory.new
    compiler.iyi_project_root = closure_root_of(expanded)
    compiler.iyi_mod_table = Mod::Installer.table_for(File.dirname(expanded))
    compiler.compile(
      Compiler::Source.new(expanded, File.read(expanded)),
      File.tempname("iyi-check", nil))
    nil
  rescue ex : CodeError
    ex
  end

  private def check_parse_only(selfhost : Bool) : Nil
    files = options.dup
    format_stdin = files.size == 1 && files[0] == "-"

    if files.empty?
      files = Dir["./**/*.iyi"]
    end

    if selfhost && !find_selfhost_parse_tool
      abort! "iyi check: self-host parse tool not found. Build it with `make iyi-parse` or set IYI_PARSE_BIN", :SOFTWARE_ERROR
    end

    status_code = 0

    if format_stdin
      source = STDIN.gets_to_end
      code = check_parse_source("STDIN", source, selfhost: selfhost)
      status_code = code if code != 0
    else
      files.each do |filename|
        if File.file?(filename)
          source = File.read(filename)
          code = check_parse_source(filename, source, selfhost: selfhost)
          status_code = code if code != 0
        elsif Dir.exists?(filename)
          dir_files = Dir["#{filename.chomp('/')}/**/*.iyi"]
          dir_files.each do |df|
            source = File.read(df)
            code = check_parse_source(df, source, selfhost: selfhost)
            status_code = code if code != 0
          end
        else
          print_error "file or directory does not exist: #{filename}"
          status_code = 1
        end
      end
    end

    exit status_code
  end

  private def check_parse_source(filename : String, source : String, selfhost : Bool) : Int32
    if selfhost
      run_selfhost_parse(filename, source)
    else
      begin
        parser = Iyi::Parser.new(source)
        parser.filename = (filename == "STDIN") ? "STDIN.iyi" : filename
        parser.parse
        0
      rescue ex : Iyi::SyntaxException
        print_syntax_error(filename, ex.line_number, ex.column_number, ex.message)
        1
      rescue ex
        print_error "syntax error in '#{filename}': #{ex.message}"
        1
      end
    end
  end

  private def run_selfhost_parse(filename : String, source : String) : Int32
    tool = find_selfhost_parse_tool
    unless tool
      print_error "iyi check: self-host parse tool not found. Build it with `make iyi-parse` or set IYI_PARSE_BIN"
      return 1
    end

    out_io = IO::Memory.new
    err_io = IO::Memory.new

    args = (filename == "STDIN" || !File.file?(filename)) ? ["-"] : [filename]
    status = if args == ["-"]
               Process.run(tool, args, input: IO::Memory.new(source), output: out_io, error: err_io)
             else
               Process.run(tool, args, output: out_io, error: err_io)
             end

    if status.success?
      0
    else
      err_text = err_io.to_s
      out_text = out_io.to_s
      combined = "#{err_text}\n#{out_text}"
      matched = false
      combined.each_line do |l|
        next if matched
        if s_idx = l.index("Syntax error in ")
          rest = l[(s_idx + 16)..-1]
          parts = rest.split(':')
          if parts.size >= 4
            line_num = parts[1]?.try(&.to_i?) || 1
            col_num = parts[2]?.try(&.to_i?) || 1
            msg = parts[3..-1].join(':').strip
            if site_idx = msg.index("(site_")
              msg = msg[0...site_idx].strip
            end
            print_syntax_error(filename, line_num, col_num, msg)
            matched = true
          end
        elsif s_idx = l.index("SYNTAX ERROR:")
          rest = l[(s_idx + 13)..-1].strip
          if at_idx = rest.rindex(" at ")
            msg = rest[0...at_idx].strip
            loc = rest[(at_idx + 4)..-1].strip
            loc_parts = loc.split(':')
            line_num = loc_parts[0]?.try(&.to_i?) || 1
            col_num = loc_parts[1]?.try(&.to_i?) || 1
            if site_idx = msg.index("(site_")
              msg = msg[0...site_idx].strip
            end
            print_syntax_error(filename, line_num, col_num, msg)
            matched = true
          end
        end
      end

      unless matched
        err_msg = err_text.strip
        err_msg = "syntax error in '#{filename}'" if err_msg.empty?
        print_error err_msg
      end
      1
    end
  end

  private def find_selfhost_parse_tool : String?
    if env = Config.env("PARSE_BIN")
      return env if File.file?(env)
    end

    tool_name = "iyi-parse"
    candidates = [] of String
    if exec = Process.executable_path
      candidates << File.join(File.dirname(exec), tool_name)
      candidates << File.join(File.dirname(exec), "selfhost-parser")
    end
    candidates << File.join(".build", tool_name)
    candidates << File.join(".build", "selfhost-parser")

    if found = candidates.find { |c| File.file?(c) }
      return found
    end

    nil
  end

  private def print_syntax_error(filename : String, line : Int32, col : Int32, message : String?)
    msg = message ? ": #{message}" : ""
    Iyi.print_error "syntax error in '#{filename}:#{line}:#{col}'#{msg}", @color, leading_error: false
  end
end
