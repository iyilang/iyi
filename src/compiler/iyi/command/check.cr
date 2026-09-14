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
    if options.first?.in?("--help", "-h")
      puts <<-USAGE
        Usage: #{Command.program_name} check [switches] [program file]
               #{Command.program_name} check --affected CHANGED [--affected CHANGED]...

        Type-check the program and produce nothing: no codegen, no
        binary. Exit 0 means well-typed; errors print like a build's,
        and `-f json` makes each one data — file, line, column, size,
        message, the SPEC sections it cites, and, when the compiler
        knows the fix, a `suggested_edit` with the exact replacement.

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
        # `.presence`: `--affected ""` is `"$FILE"` with `FILE` unset, and
        # its consumers were whoever imported the working directory.
        value = options.shift?.presence
        abort! "--affected takes a changed file", :USAGE_ERROR unless value
        if Dir.exists?(value)
          abort! "#{value} is a directory, not a changed file", :USAGE_ERROR
        end
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

    # A changed file that is not there is either deleted or mistyped, and
    # the two look the same from here. Both get the same consumers - the
    # closure keeps an import's path after its file is gone - and the
    # verdict says which file it was, because "0 consumer(s) checked, all
    # compile" on a typo is a clean verdict about nothing.
    missing = changed.reject { |path| File.file?(path) }.map { |path| Iyi.relative_filename(path) }

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
          unless missing.empty?
            json.field "affected_not_found" do
              json.array { missing.each { |path| json.string path } }
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
      unless missing.empty?
        puts "#{missing.join(", ")} is not there, so the consumers are whoever imports that path"
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
end
