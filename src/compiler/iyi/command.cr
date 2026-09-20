# Here we process the compiler's command line options and
# execute the relevant commands.
#
# Some commands are implemented in the `commands` directory,
# some in `tools`, some here, and some create a Compiler and
# manipulate it.
#
# Other commands create a `Compiler` and use it to build
# an executable.

require "json"
require "./command/*"
require "./tools/*"

class Iyi::Command
  enum Exit
    # Successful exit
    OK = 0

    # Expected failure
    FAILURE = 1

    # User error (e.g. wrong CLI argument)
    USAGE_ERROR = 1

    # Code error (e.g. invalid source code)
    CODE_ERROR = 1

    # Internal compiler error
    SOFTWARE_ERROR = 1
  end

  # iyi: what this binary is called when it tells somebody how to call it.
  #
  # The same compiler ships under two names, and a person running `iyi mod`
  # was told "Usage: crystal mod" — the name of a program they had not
  # installed. `src/compiler/iyi.cr` sets this; nothing else does, so `crystal`
  # says `crystal`.
  class_property program_name : String = "crystal"

  USAGE = <<-USAGE
    Usage: crystal [command] [switches] [program file] [--] [arguments]

    Command:
        init                     generate a new project
        doc                      print a module's exported surface, docs included
        build                    build an executable
        clear_cache              clear the compiler cache
        check                    type-check only: no codegen, no binary; errors are the exit code
        fix                      apply the compiler's did-you-mean edits until the file is clean
        bind                     put every shard under lib/ behind a boundary, as .iyimod files
        migrate                  write a Crystal tree as iyi modules, the namespace as the path
        env                      print Crystal environment information
        eval                     eval code from args or standard input
        mod                      inspect a .iyimod module artifact
        lsp                      serve the language over stdio (editors, agents)
        mcp                      serve the compiler's verbs as MCP tools over stdio (agents)
        run (default)            build and run program
        spec                     build and run specs (in spec directory)
        test                     run every *_test.iyi: exit 0 passes, anything else fails
        vet                      report unreachable code; findings are the exit code
        tool                     run a tool
        help, --help, -h         show this help
        version, --version, -v   show version

    Run a command followed by --help to see command specific information, ex:
        crystal <command> --help
    USAGE

  # iyi: a method rather than a constant, because a constant interpolates
  # `program_name` when it is initialised, which is before `iyi.cr` has said
  # which binary this is. As a constant it told everybody running `iyi tool`
  # that they were running `crystal tool`.
  def self.commands_usage : String
    <<-USAGE
      Usage: #{Command.program_name} tool [tool] [switches] [program file] [--] [arguments]

      Tool:
          bind                     say what a Crystal shard would cost as an iyi module
          context                  show context for given location
          dependencies             show file dependency tree
          expand                   show macro expansion for given location
          flags                    print all macro `flag?` values
          format                   format project, directories and/or files
          hierarchy                show type hierarchy
          implementations          show implementations for given call in location
          macro_code_coverage      generate a macro code coverage report
          types                    show type of main variables
          unreachable              show methods that are never called
          --help, -h               show this help
      USAGE
  end

  def self.run(options = ARGV)
    new(options).run
  end

  private getter options
  @compiler : Compiler?

  def initialize(@options : Array(String))
    @color = Colorize.default_enabled?(STDOUT, STDERR)
    @error_trace = false
    @progress_tracker = ProgressTracker.new
  end

  def run
    command = options.first?
    case
    when !command
      puts USAGE
      exit
    when command == "init"
      options.shift
      init
    when "build".starts_with?(command)
      options.shift
      # A daemon named by the environment serves ordinary builds too, so the
      # speed does not depend on remembering to type `daemon build`.
      if socket = daemon_socket_from_env
        daemon_build(socket, fallback: true)
      end
      build
      report_warnings
      exit 1 if warnings_fail_on_exit?
    when "deps".starts_with?(command)
      STDERR.puts "Please use 'shards': 'crystal deps' has been removed"
      exit 1
    when command == "env"
      options.shift
      env
    when command == "eval"
      options.shift
      eval
    when command == "run"
      options.shift
      # `--sandbox` re-routes before the native pipeline parses anything:
      # a sandbox that fell back to native on a flag typo would be a lie.
      if options.includes?("--sandbox")
        options.delete("--sandbox")
        run_sandbox
      else
        run_command(single_file: false)
      end
    when "spec/".starts_with?(command)
      options.shift
      spec
    when command == "doc"
      # Exact: `d` would be ambiguous with `daemon` and `deps`.
      options.shift
      doc
    when command == "test"
      # Exact, like `doc`: `t` stays `tool`'s.
      options.shift
      test
    when command == "vet"
      # Exact, like `test`: `v` stays `version`'s.
      options.shift
      vet
    when command == "check"
      # Exact: `c` must not reach a verb by accident while `clear_cache`
      # holds its full name.
      options.shift
      check
    when command == "fix"
      # Exact: a verb that writes to files is not something to reach by
      # prefix.
      options.shift
      fix
    when command == "bind"
      # Exact: it writes artifacts and runs builds; not something to
      # reach by prefix.
      options.shift
      bind
    when command == "migrate"
      # Exact: it writes a tree of files.
      options.shift
      migrate
    when command == "lsp"
      # Exact: a server is not something to reach by accident from `l`.
      options.shift
      lsp
    when command == "mcp"
      # Exact, beside `lsp`: a server is not something to reach by prefix.
      options.shift
      mcp
    when "tool".starts_with?(command)
      options.shift
      tool
    when command == "clear_cache"
      options.shift
      clear_cache
    when command == "daemon"
      options.shift
      daemon
      # iyi: prefixes, like every other command here. `mo` and `m` reach it, and
      # nothing else in this list starts with an `m`.
    when "mod".starts_with?(command)
      options.shift
      mod
    when "help".starts_with?(command), "--help" == command, "-h" == command
      # `iyi help nonesuch` printed the whole usage and exited 0, which reads
      # as "yes, that is a command"; `iyi help build` did the same, as if
      # the verb had no help of its own. A verb's help is the verb's, and a
      # word that is no verb is said to be none.
      if (verb = options[1]?) && verb != "help"
        # A verb's own help, through the same door `iyi <verb> --help` uses.
        known = USAGE.lines.any? { |line| line.starts_with?("    #{verb} ") }
        abort! "help: there is no `#{verb}` command. Run `#{Command.program_name} help` for what there is", :USAGE_ERROR unless known
        Command.new([verb, "--help"]).run
        exit
      end
      puts USAGE
      exit
    when "version".starts_with?(command), "--version" == command, "-v" == command
      # `iyi version extra` printed the version and exited 0 with the extra
      # word dropped, the way `clear_cache extra` used to.
      if extra = options[1]?
        abort! "version takes no arguments, and '#{extra}' is one", :USAGE_ERROR
      end
      puts Iyi::Config.description
      exit
    when File.file?(command)
      run_command(single_file: true)
    else
      if command.ends_with?(".cr")
        abort! "file '#{command}' does not exist", :USAGE_ERROR
        # iyi: `git`-style subcommand extension, keyed on the name a person
        # typed. Hardcoded to `crystal-`, `iyi foo` could never find `iyi-foo`,
        # so the extension point existed for one of the two binaries only.
      elsif external_command = Process.find_executable("#{Command.program_name}-#{command}")
        options.shift

        iyi_exec_path = Iyi::Config.exec_path
        path = [iyi_exec_path, ENV["PATH"]?].compact!.join(Process::PATH_DELIMITER)

        {% if flag?(:win32) %}
          # FIXME: `Process.exec` doesn't work as expected on Windows, see https://github.com/crystal-lang/crystal/issues/14422
          options.unshift external_command
          exit_status, _ = Process.run(options, env: {
            "PATH"          => path,
            "IYI_EXEC_PATH" => iyi_exec_path,
          }, input: :inherit, output: :inherit, error: :inherit) do |process|
            # FIXME: There's a race condition between creating the sub-process and
            # registering the `on_terminate` callback.
            # Should be fixed with https://github.com/crystal-lang/crystal/issues/14422

            Process.on_terminate do
              process.terminate
            end
          end
          ::exit exit_status
        {% else %}
          Process.exec(external_command, options, env: {
            "PATH"          => path,
            "IYI_EXEC_PATH" => iyi_exec_path,
          })
        {% end %}
      else
        abort! "unknown command: #{command}", :USAGE_ERROR
      end
    end
  rescue ex : Iyi::CodeError
    report_warnings

    ex.color = @color
    ex.error_trace = @error_trace
    if @config.try(&.output_format) == "json"
      STDERR.puts ex.to_json
    else
      STDERR.puts ex
    end
    exit 1
  rescue ex : Iyi::Error
    report_warnings

    # This unwraps nested errors which could be caused by `require` which wraps
    # errors in order to trace the require path. The causes are listed similarly
    # to `#inspect_with_backtrace` but without the backtrace.
    while cause = ex.cause
      print_error ex.message
      ex = cause
    end

    abort! ex.message, :CODE_ERROR
  rescue ex : OptionParser::Exception
    abort! ex.message, :USAGE_ERROR
  rescue ex : CompilerError
    print_error ex.message
    ::exit ex.status
  rescue ex : IO::Error
    # iyi: `mod dump big.iyimod | head` is somebody reading, not a bug in a
    # compiler. The reader closing the pipe is how `head` says it has enough,
    # and every other tool on the machine treats it as the end of the output
    # rather than as a crash with a backtrace and an invitation to file an
    # issue.
    ::exit 0 if ex.os_error == Errno::EPIPE

    # iyi: and the rest of what the filesystem answers is a sentence too.
    # This clause used to `raise ex` here, and a `raise` inside a rescue
    # clause is not caught by the later clauses of the same `begin`: the
    # catch-all below never saw a `File::Error`, so `iyi doc` on a file
    # with mode 000 printed "Unhandled exception: Error opening file with
    # mode 'r' ... (File::AccessDeniedError)" and a dozen frames of this
    # compiler's own files. A permission bit is not a compiler bug.
    report_warnings
    abort! filesystem_sentence(ex), :FAILURE
  rescue ex
    report_warnings

    ex.inspect_with_backtrace STDERR
    # iyi: this fork's tracker, not the upstream project's. Whoever ran
    # this binary cannot tell which half of it crashed, and the half they
    # can reach is the one that ships it — `iyilang/iyi` carries the
    # fork's patches and every line of the compiler it built from.
    abort! "you've found a bug in the #{Command.program_name} compiler. Please open an issue, " \
           "including the trace above and source code that will allow us to reproduce it: " \
           "https://github.com/iyilang/iyi/issues", :SOFTWARE_ERROR
  end

  private def tool
    tool = options.first?
    case
    when !tool
      puts Command.commands_usage
      exit
    when "context".starts_with?(tool)
      options.shift
      context
    when "format".starts_with?(tool)
      options.shift
      format
    when "flags" == tool
      options.shift
      flags
    when "expand".starts_with?(tool)
      options.shift
      expand
    when "bind" == tool
      options.shift
      tool_bind
    when "hierarchy".starts_with?(tool)
      options.shift
      hierarchy
    when "dependencies".starts_with?(tool)
      options.shift
      dependencies
    when "implementations".starts_with?(tool)
      options.shift
      implementations
    when "types".starts_with?(tool)
      options.shift
      types
    when "unreachable".starts_with?(tool)
      options.shift
      unreachable
    when "macro_code_coverage".starts_with?(tool)
      options.shift
      macro_code_coverage
    when "--help" == tool, "-h" == tool
      puts Command.commands_usage
      exit
    else
      abort! "unknown tool: #{tool}", :USAGE_ERROR
    end
  end

  private def init
    Init.run(options)
  end

  # iyi: `iyi vet` — SPEC.md III.8 #3's row, closed the way the table
  # said: "a verb, not new analysis". The analysis is `tool
  # unreachable`; the verb is go vet's contract — findings are the exit
  # code, so CI can hold the line with no flag to remember.
  private def vet
    if options.first?.in?("--help", "-h")
      puts <<-USAGE
        Usage: #{Command.program_name} vet [switches] [program file]

        Report methods nothing can reach, and exit 1 when there are any.
        The analysis is `#{Command.program_name} tool unreachable`; this verb adds
        go vet's contract: findings are the exit code. All of that tool's
        switches (`-f json`, `--tallies`, ...) pass through.
        USAGE
      exit
    end
    options.unshift "--check"
    unreachable "vet"
  end

  private def build
    config = create_compiler "build"
    config.compile
  end

  # The compiler a `crystal build` with these arguments would use, so the daemon
  # can analyse the prelude those flags imply and have it ready next time.
  #
  # Only ever called with arguments a build has already parsed successfully:
  # option parsing exits the process on bad input, and doing that in a daemon
  # would take it down on a client's typo.
  protected def prelude_compiler_for_build : Compiler
    options.shift if options.first? == "build"
    create_compiler("build").compiler
  end

  # iyi: what it would take to put a Crystal shard behind an iyi boundary.
  #
  # `-e` names the shard's own namespace, borrowed from `hierarchy` because it
  # is the same question — which types are this shard's — asked for a different
  # reason. Not `top_level`, because a signature's return type is only known
  # once the method has been instantiated, and that is the whole measurement.
  private def tool_bind
    config, result = compile_no_codegen "tool bind", hierarchy: true
    @progress_tracker.stage("Tool (bind)") do
      Iyi.print_bind result.program, config.hierarchy_exp, STDOUT,
        artifact_dir: config.compiler.emit_bind,
        bound_dir: config.compiler.use_iyimod
    end
  end

  private def hierarchy
    config, result = compile_no_codegen "tool hierarchy", hierarchy: true, top_level: true
    @progress_tracker.stage("Tool (hierarchy)") do
      Iyi.print_hierarchy result.program, STDOUT, config.hierarchy_exp, config.output_format
    end
  end

  private def run_command(single_file = false)
    config = create_compiler "run", run: true, single_file: single_file
    if config.specified_output
      config.compile
      report_warnings
      exit 1 if warnings_fail_on_exit?
      return
    end

    output_filename = Iyi.temp_executable(config.output_filename)

    config.compile output_filename

    unless config.compiler.no_codegen?
      report_warnings
      exit 1 if warnings_fail_on_exit?

      execute output_filename, config.arguments, config.compiler
    end
  end

  private def types
    _, result = compile_no_codegen "tool types"
    @progress_tracker.stage("Tool (types)") do
      Iyi.print_types result.node
    end
  end

  private def compile_no_codegen(command, wants_doc = false, hierarchy = false, no_cleanup = false, cursor_command = false, top_level = false, path_filter = false, unreachable_command = false, allowed_formats = ["text", "json"])
    config = create_compiler command, no_codegen: true, hierarchy: hierarchy, cursor_command: cursor_command, path_filter: path_filter, unreachable_command: unreachable_command, allowed_formats: allowed_formats
    config.compiler.no_codegen = true
    config.compiler.no_cleanup = no_cleanup
    config.compiler.wants_doc = wants_doc
    result = top_level ? config.top_level_semantic : config.compile
    {config, result}
  end

  # iyi: what a program's death says, when the kernel ended it rather than
  # the program exiting. `Process::Status#description` speaks in the
  # kernel's terms - "Process terminated because of an invalid memory
  # access" - and for an iyi program, which outside `Pointer` cannot reach
  # memory it does not own, that sends a reader hunting for a null
  # dereference in a language whose nil is a type. The stack running out
  # is the program's own panic now (`IyiStackGuard`, on the targets with a
  # runtime), so a fault that reaches here is a `Pointer` the program
  # wrote, a stack on a target with no guard, or ours. Every other signal
  # is named, because "an unhandled signal" is a sentence with the fact
  # left out.
  def self.death_sentence(status : Process::Status) : String
    case status.exit_reason
    when .bad_memory_access?, .access_violation?
      "the program died of a memory fault. Outside `Pointer`, an iyi program cannot reach memory " \
      "it does not own: if the program uses `Pointer`, that is the place to look, and on a target " \
      "without iyi's runtime it can also be the stack running out. If neither, it is a bug in " \
      "#{program_name}'s own runtime, and ours to fix: https://github.com/iyilang/iyi/issues"
    else
      if signal = status.exit_signal?
        "the program was killed by signal #{signal} (#{status.description.lchop("Process ")})"
      else
        status.description
      end
    end
  end

  private def execute(output_filename, run_args, compiler, *, error_on_exit = false)
    time = @time && !@progress_tracker.stats?
    status, elapsed_time = @progress_tracker.stage("Execute") do
      elapsed = Time.measure do
        Process.run(output_filename, args: run_args, input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit) do |process|
          {% unless flag?(:wasm32) %}
            # Ignore the signal so we don't exit the running process
            # (the running process can still handle this signal)
            Process.ignore_interrupts!
          {% end %}

          # iyi: and pass on the one nobody delivers for us. `SIGINT`
          # reaches the program by itself, because a terminal signals the
          # whole foreground group; `SIGTERM` names one process, and that
          # process is this one. Without this line, killing `iyi run`
          # leaves the program it built running and holding whatever it
          # had open - a port, in every program worth running this way.
          # The editor's `▶ run` is what found it: the lens kills the
          # verb after thirty seconds and the server it started stayed up.
          {% unless flag?(:win32) || flag?(:wasm32) %}
            Signal::TERM.trap { process.terminate rescue nil }
            Signal::HUP.trap { process.terminate rescue nil }
          {% end %}

          # iyi: Windows delivers no signal to trap, and `TerminateProcess`
          # — which is what an editor, a CI step or `taskkill /F` uses —
          # runs no code in this process at all. Measured: `iyi run` on a
          # program that listens, then `taskkill /PID <runner> /F`, left
          # the child alive and the port still LISTENING; the next build
          # of the same program then failed to link, because the orphan
          # holds its own exe open (`LNK1104: cannot open file
          # iyi-run-....exe`). The kernel's own answer is a job object
          # with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: the last handle to
          # the job closing kills everything in it, and a dying process
          # closes its handles however it died.
          {% if flag?(:win32) %}
            kill_child_with_runner(process)
          {% end %}
        end
      end
      {$?, elapsed}
    ensure
      File.delete?(output_filename)

      # Delete related PDB generated by MSVC, if any exist
      {% if flag?(:msvc) %}
        unless compiler.debug.none?
          basename = output_filename.rchop(".exe")
          File.delete?("#{basename}.pdb")
        end
      {% end %}

      # Delete related dwarf generated by dsymutil, if any exist
      {% if flag?(:darwin) %}
        unless compiler.debug.none?
          File.delete?("#{output_filename}.dwarf")
        end
      {% end %}
    end

    if time
      puts "Execute: #{elapsed_time}"
    end

    if (exit_code = status.exit_code?) && !error_on_exit
      exit exit_code
    end

    unless status.exit_reason.normal?
      # iyi: in iyi's own words when the program is iyi's. A `--crystal`
      # program carries Crystal's runtime, which catches the fault itself
      # and exits saying so; only a program under iyi's library dies here.
      if compiler.prelude == "iyi/prelude"
        STDERR.puts "#{Command.program_name}: #{Command.death_sentence(status)}"
      else
        STDERR.puts status.description
      end
      STDERR.flush
    end

    exit 1
  end

  {% if flag?(:win32) %}
    # iyi: the job this runner's child lives in. Every call is one
    # `src/lib_c/x86_64-windows-msvc/c/jobapi2.cr` already binds, and the
    # handle is kept in a class variable because a job dies with its last
    # handle: a local would be closed by the collector and take the
    # running program with it while `iyi run` was still waiting for it.
    @@run_job : Void* = Pointer(Void).null

    # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, which winnt.cr does not spell.
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000_u32

    private def kill_child_with_runner(process)
      job = LibC.CreateJobObjectW(Pointer(LibC::SECURITY_ATTRIBUTES).null, Pointer(UInt16).null)
      return if job.null?
      limits = LibC::JOBOBJECT_EXTENDED_LIMIT_INFORMATION.new
      limits.basicLimitInformation.limitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
      if LibC.SetInformationJobObject(job, LibC::JOBOBJECTINFOCLASS::ExtendedLimitInformation,
           pointerof(limits).as(Void*),
           sizeof(LibC::JOBOBJECT_EXTENDED_LIMIT_INFORMATION).to_u32) == 0
        LibC.CloseHandle(job)
        return
      end
      # PROCESS_TERMINATE | PROCESS_SET_QUOTA, which is what assigning asks for.
      handle = LibC.OpenProcess(0x0001_u32 | 0x0100_u32, 0, process.pid.to_u32)
      if handle.null?
        LibC.CloseHandle(job)
        return
      end
      assigned = LibC.AssignProcessToJobObject(job, handle)
      LibC.CloseHandle(handle)
      if assigned == 0
        LibC.CloseHandle(job)
        return
      end
      @@run_job = job
    end
  {% end %}

  record CompilerConfig,
    compiler : Compiler,
    sources : Array(Compiler::Source),
    output_filename : String,
    emit_base_filename : String?,
    arguments : Array(String),
    specified_output : Bool,
    hierarchy_exp : String?,
    cursor_location : String?,
    output_format : String,
    includes : Array(String),
    excludes : Array(String),
    verbose : Bool,
    check : Bool,
    tallies : Bool do
    def compile(output_filename = self.output_filename)
      compiler.emit_base_filename = emit_base_filename || output_filename.rchop(File.extname(output_filename))
      compiler.compile sources, output_filename
    end

    def compile_configure_program(output_filename = self.output_filename, &)
      compiler.emit_base_filename = emit_base_filename || output_filename.rchop(File.extname(output_filename))
      compiler.compile_configure_program sources, output_filename do |program|
        yield program
      end
    end

    def top_level_semantic
      compiler.top_level_semantic sources
    end
  end

  private def create_compiler(command, no_codegen = false, run = false,
                              hierarchy = false, cursor_command = false,
                              single_file = false, dependencies = false,
                              path_filter = false, unreachable_command = false,
                              allowed_formats = ["text", "json"])
    compiler = new_compiler
    compiler.progress_tracker = @progress_tracker
    compiler.no_codegen = no_codegen
    link_flags = [] of String
    filenames = [] of String
    has_stdin_filename = false
    opt_filenames = nil
    opt_arguments = nil
    opt_output_filename = nil
    specified_output = false
    hierarchy_exp = nil
    cursor_location = nil
    output_format = nil
    excludes = [] of String
    includes = [] of String
    verbose = false
    check = false
    tallies = false
    specified_prelude = false

    option_parser = parse_with_iyi_opts do |opts|
      opts.banner = "Usage: #{Command.program_name} #{command} [options] [programfile] [--] [arguments]\n\nOptions:"

      unless no_codegen
        unless run
          opts.on("--cross-compile", "cross-compile") do |cross_compile|
            compiler.cross_compile = true
          end
        end
        opts.on("-d", "--debug", "Add full symbolic debug info") do
          compiler.debug = Iyi::Debug::All
        end
        opts.on("--no-debug", "Skip any symbolic debug info") do
          compiler.debug = Iyi::Debug::None
        end

        opts.on("--frame-pointers auto|always|non-leaf", "Control the preservation of frame pointers") do |value|
          if frame_pointers = FramePointers.parse?(value)
            compiler.frame_pointers = frame_pointers
          else
            abort! "Invalid value `#{value}` for frame-pointers", :USAGE_ERROR
          end
        end
      end

      opts.on("-D FLAG", "--define FLAG", "Define a compile-time flag") do |flag|
        compiler.flags << flag
      end

      unless no_codegen
        valid_emit_values = Compiler::EmitTarget.names
        valid_emit_values.map!(&.gsub('_', '-').downcase)

        opts.on("--emit [#{valid_emit_values.join('|')}]", "Comma separated list of types of output for the compiler to emit") do |emit_values|
          compiler.emit_targets |= validate_emit_values(emit_values.split(',').map(&.strip))
        end

        opts.on("--x86-asm-syntax att|intel", "X86 dialect for --emit=asm: AT&T (default), Intel") do |value|
          case value = LLVM::InlineAsmDialect.parse?(value)
          in Nil
            abort! "Invalid value `#{value}` for x86-asm-syntax", :USAGE_ERROR
          in .att?
            # Do nothing
          in .intel?
            LLVM.parse_command_line_options({"", "-x86-asm-syntax=intel"})
          end
        end
      end

      if hierarchy
        opts.on("-e NAME", "Filter types by NAME regex") do |exp|
          hierarchy_exp = exp
        end
      end

      if cursor_command
        opts.on("-c LOC", "--cursor LOC", "Cursor location with LOC as path/to/file.cr:line:column") do |cursor|
          cursor_location = cursor
        end
      end

      if dependencies
        opts.on("-i <path>", "--include <path>", "Include path") do |f|
          includes << f
        end

        opts.on("-e <path>", "--exclude <path>", "Exclude path (default: lib)") do |f|
          excludes << f
        end

        opts.on("--verbose", "Show skipped and filtered paths") do
          verbose = true
        end
      end

      opts.on("-f #{allowed_formats.join("|")}", "--format #{allowed_formats.join("|")}", "Output format: #{allowed_formats[0]} (default), #{allowed_formats[1..].join(", ")}") do |f|
        output_format = f
      end

      if unreachable_command
        opts.on("--tallies", "Print reachable methods and their call counts as well") do
          tallies = true
        end

        opts.on("--check", "Exits with error if there is any unreachable code") do |f|
          check = true
        end
      end

      opts.on("--error-trace", "Show full error trace") do
        compiler.show_error_trace = true
        @error_trace = true
      end

      opts.on("-h", "--help", "Show this message") do
        puts opts
        exit
      end

      if path_filter
        opts.on("-i <path>", "--include <path>", "Include path") do |f|
          includes << f
        end

        opts.on("-e <path>", "--exclude <path>", "Exclude path (default: lib)") do |f|
          excludes << f
        end
      end

      unless no_codegen
        opts.on("--ll", "Dump ll to Crystal's cache directory") do
          compiler.dump_ll = true
        end
        opts.on("--link-flags FLAGS", "Additional flags to pass to the linker") do |some_link_flags|
          link_flags << some_link_flags
        end
        target_specific_opts(opts, compiler)
        setup_compiler_warning_options(opts, compiler)
      end

      opts.on("--no-color", "Disable colored output") do
        @color = false
        compiler.color = false
      end

      unless no_codegen
        opts.on("--no-codegen", "Don't do code generation") do
          compiler.no_codegen = true
        end
        opts.on("-o FILE", "--output FILE", "Output path. If a directory, the filename is derived from the first source file (default: ./)") do |an_output_filename|
          # `-o ""` is what a shell produces from `-o "$OUT"` with `OUT`
          # unset, and it used to mean the current directory - the
          # program was written beside its source under a name nobody
          # typed, or, when that name was taken, `ld.lld: error: cannot
          # open output file <cwd>: Is a directory`.
          if an_output_filename.empty?
            abort! "-o takes a path", :USAGE_ERROR
          end
          opt_output_filename = an_output_filename
          specified_output = true
        end
      end

      opts.on("--prelude ", "Use given file as prelude") do |prelude|
        # `--prelude ""` went looking for a file called nothing and answered
        # with the other language's advice about shards. A name, or nothing.
        abort! "--prelude takes a file name", :USAGE_ERROR if prelude.empty?
        compiler.prelude = prelude
        specified_prelude = true
      end

      # iyi: write a `.iyimod` per imported module into DIR (SPEC.md IV.1).
      #
      # Emitting from an ordinary build rather than from a "compile this module
      # alone" command, because compiling a module alone is the thing the
      # artifact is *for* and cannot precede it.
      # iyi: which standard library this program has.
      #
      # `--prelude` is the mechanism and this is the question: a program built
      # with it gets Crystal's library, so `require` reaches the ecosystem and
      # means what it means in Crystal. The rules that make a module a module
      # are untouched — they are the language's, and a prelude is a library.
      opts.on("--crystal", "iyi: build against Crystal's standard library, so `require` works") do
        compiler.prelude = "prelude"
        compiler.crystal_library = true
        specified_prelude = true
      end

      opts.on("--iyi-keep NAMESPACE", "iyi: define rather than inline the methods under NAMESPACE") do |root|
        compiler.iyi_keep = root
      end

      # iyi: where `tool bind` writes what it generates.
      #
      # Its own switch rather than `--emit-iyimod`, because it is not that: it
      # writes one artifact it built itself, for a shard, under Crystal's
      # library — which is exactly the combination `--emit-iyimod` refuses.
      opts.on("--emit-bind DIR", "iyi: where `tool bind` writes the boundary it generates") do |dir|
        compiler.emit_bind = dir
      end

      opts.on("--emit-iyimod DIR", "iyi: write a .iyimod per imported module into DIR") do |dir|
        # iyi: answered here rather than by `Dir.mkdir_p` half an hour into a
        # build. A path that names a file, or a directory nobody may write to,
        # used to arrive as `Unable to create directory` and a stack trace.
        # And `""`, which is `"$DIR"` with `DIR` unset, arrived as
        # `--emit-iyimod cannot use : No such file or directory` - a sentence
        # with a hole where the name goes.
        abort! "--emit-iyimod takes a directory", :USAGE_ERROR if dir.empty?
        if File.exists?(dir) && !File.directory?(dir)
          abort! "--emit-iyimod needs a directory, and #{dir} is a file", :USAGE_ERROR
        end
        begin
          Dir.mkdir_p(dir)
        rescue ex : File::Error
          abort! "--emit-iyimod cannot use #{dir}: #{ex.os_error.try(&.message) || ex.message}", :USAGE_ERROR
        end
        compiler.emit_iyimod = dir
      end

      # iyi: read imported modules from DIR's `.iyimod` files (SPEC.md IV.1).
      #
      # No longer implies `--no-codegen`: an artifact carries its module's own
      # object code, the defs it declares are emitted as external declarations,
      # and the linker joins the two. IV.1g names what is still missing from
      # that, and what is missing shows up as an undefined symbol at link —
      # which is the honest failure for this stage, and a great deal more
      # useful than refusing to try.
      opts.on("--use-iyimod DIR", "iyi: compile imported modules from DIR's .iyimod files") do |dir|
        # iyi: a module with no artifact is ordinary — the first build of the
        # loop has none at all, and compiles from source. A *directory* that is
        # not there is a typo, and it used to be ignored: the build compiled
        # every module from source and looked like it had used artifacts.
        abort! "--use-iyimod takes a directory", :USAGE_ERROR if dir.empty?
        unless File.directory?(dir)
          # A file that is there is not a directory that is missing: `--use-iyimod
          # mods/app/lib.iyimod` answered "there is no mods/app/lib.iyimod" about
          # the artifact the author had just been looking at.
          if File.exists?(dir)
            abort! "--use-iyimod needs a directory of .iyimod files, and #{dir} is a file", :USAGE_ERROR
          end
          abort! "--use-iyimod needs a directory of .iyimod files, and there is no #{dir}", :USAGE_ERROR
        end
        compiler.use_iyimod = dir
      end

      unless no_codegen
        opts.on("--release", "Compile in release mode (-O3 --single-module)") do
          compiler.release!
        end
        opts.on("-O LEVEL", "Optimization mode: 0 (default), 1, 2, 3, s, z") do |level|
          if mode = Compiler::OptimizationMode.from_level?(level)
            compiler.optimization_mode = mode
          else
            raise Error.new("Invalid optimization mode: O#{level}")
          end
        end
      end

      opts.on("-s", "--stats", "Enable statistics output") do
        @progress_tracker.stats = true
      end

      opts.on("-p", "--progress", "Enable progress output") do
        @progress_tracker.progress = true
      end

      opts.on("-t", "--time", "Enable execution time output") do
        @time = true
      end

      unless no_codegen
        opts.on("--single-module", "Generate a single LLVM module") do
          compiler.single_module = true
        end
        opts.on("--threads NUM", "Maximum number of threads to use") do |n_threads|
          compiler.n_threads = n_threads.to_i? || raise Error.new("Invalid thread count: #{n_threads}")
        end
        unless run
          opts.on("--target TRIPLE", "Target triple") do |triple|
            compiler.codegen_target = Codegen::Target.new(triple)
          end
        end
        opts.on("--verbose", "Display executed commands") do
          compiler.verbose = true
        end
        opts.on("--static", "Link statically") do
          compiler.static = true
        end
      end

      opts.on("--stdin-filename ", "Source file name to be read from STDIN") do |stdin_filename|
        has_stdin_filename = true
        filenames << stdin_filename
      end

      if single_file
        opts.before_each do |arg|
          opts.stop if !arg.starts_with?('-') && arg.ends_with?(".cr")
          opts.stop if File.file?(arg)
        end
      end

      opts.unknown_args do |before, after|
        opt_filenames = before
        opt_arguments = after
      end
    end

    compiler.link_flags = link_flags.join(' ') unless link_flags.empty?

    filenames += opt_filenames.not_nil!
    arguments = opt_arguments.not_nil!

    if single_file && (files = filenames[1..-1]?)
      arguments = files + arguments
      filenames = [filenames[0]]
    end

    if filenames.size == 0 || (cursor_command && cursor_location.nil?)
      STDERR.puts option_parser
      exit 1
    end

    sources = [] of Compiler::Source
    if has_stdin_filename
      sources << Compiler::Source.new(filenames.shift, STDIN.gets_to_end)
    end
    sources.concat gather_sources(filenames)

    # iyi: an iyi program gets iyi's prelude (SPEC.md, "0.1.0", item 3).
    #
    # Decided by the entry file's extension, which is the only thing the
    # compiler knows before it reads anything. `--prelude` still wins, and a
    # `.cr` file is untouched — the two languages share this compiler and do
    # not share a standard library.
    if !specified_prelude && sources.first?.try(&.filename.ends_with?(".iyi"))
      compiler.prelude = "iyi/prelude"
    end

    output_extension = compiler.cross_compile? ? compiler.codegen_target.object_extension : compiler.codegen_target.executable_extension

    # FIXME: The explicit cast should not be necessary (#15472)
    output_path = ::Path[opt_output_filename.as?(String) || "./"]

    if output_path.ends_with_separator? || File.directory?(output_path)
      first_filename = sources.first.filename
      output_filename = (output_path / "#{::Path[first_filename].stem}#{output_extension}").normalize.to_s

      # Check if we'll overwrite the main source file
      if !compiler.no_codegen? && !run && first_filename == File.expand_path(output_filename)
        abort! "compilation will overwrite source file '#{Iyi.relative_filename(first_filename)}', either change its extension to '.cr' or specify an output file with '-o'", :USAGE_ERROR
      end
    else
      output_filename = output_path.to_s
      if output_path.extension.empty?
        output_filename += output_extension
      end

      # iyi: and the same question of a name the author typed. The check
      # above covers only the name the compiler derives itself, so
      # `-o good.iyi good.iyi` - one word, typed twice - read the source,
      # built it and linked the executable over it: the program's only
      # copy was 12 KB of ELF, exit 0. A module the entry imports is the
      # same mistake one step removed, and is refused once it is known
      # (`Compiler#codegen`), before anything is written.
      if !compiler.no_codegen? && !run
        expanded = File.expand_path(output_filename)
        if source = sources.find { |candidate| candidate.filename == expanded }
          abort! "-o #{output_filename} names #{Iyi.relative_filename(source.filename)}, the source it would build from, " \
                 "and linking there would replace it. Name the program something else", :USAGE_ERROR
        end
      end
    end

    output_format ||= allowed_formats[0]
    unless output_format.in?(allowed_formats)
      abort! "You have input an invalid format: #{output_format}. Supported formats: #{allowed_formats.join(", ")}", :USAGE_ERROR
    end

    abort! "maximum number of threads cannot be lower than 1", :USAGE_ERROR if compiler.n_threads < 1

    if !compiler.no_codegen? && !run && Dir.exists?(output_filename)
      abort! "can't use `#{output_filename}` as output filename because it's a directory", :USAGE_ERROR
    end

    # iyi: and the directory it would be written into, which nothing asked
    # about until the linker did: `-o nodir/prog` reached `ld.lld` and came
    # back as "ld.lld: error: cannot open output file ...: No such file or
    # directory" - a message from a program the author did not run, after a
    # whole compilation had already been paid for.
    if !compiler.no_codegen? && !run
      directory = File.dirname(output_filename)
      unless Dir.exists?(directory)
        abort! "there is no #{directory} to write #{File.basename(output_filename)} into", :USAGE_ERROR
      end

      # The same sentence for a directory that is there and will not take
      # the file. `-o ro/prog` under a mode-500 directory was three lines
      # of `ld.lld: error: cannot open output file`, once per link
      # attempt, for a permission bit.
      unless File.writable?(directory)
        abort! "#{directory} will not take #{File.basename(output_filename)}: no permission to write there", :USAGE_ERROR
      end
    end

    if run
      emit_base_filename = ::Path[sources.first.filename].stem
    end

    @config = CompilerConfig.new compiler, sources, output_filename, emit_base_filename,
      arguments, specified_output, hierarchy_exp, cursor_location, output_format.not_nil!,
      includes, excludes, verbose, check, tallies
  end

  private def gather_sources(filenames)
    filenames.map do |filename|
      # And the third is no name at all: `iyi run "$FILE"` with `FILE`
      # unset. `File.expand_path("")` is the working directory, so this
      # answered "Error:  is a directory, not a source file" - a sentence
      # with a hole in it, about a directory nobody named.
      abort! "the file name is empty, so it names nothing", :USAGE_ERROR if filename.empty?
      expanded = File.expand_path(filename)
      # iyi: the commonest thing to get wrong about a command is the name of
      # the file, and the answer to it was "Error: Error opening file with
      # mode 'r': '/…/typo.iyi': No such file or directory" — the word Error
      # twice, a mode nobody asked about, and the path spelled out twice over.
      unless File.file?(expanded)
        # And the second commonest is handing it a directory, which used to
        # come back as "no such file" about a path that is right there — so
        # the reader runs `ls`, finds it, and learns nothing. Same sentence
        # `doc` and `mod` give, because it is the same mistake.
        abort! "#{filename} is a directory, not a source file", :USAGE_ERROR if Dir.exists?(expanded)
        abort! "no such file: #{filename}", :USAGE_ERROR
      end
      Compiler::Source.new(expanded, File.read(expanded))
    end
  rescue exc : IO::Error
    abort! exc, :CODE_ERROR
  end

  private def setup_simple_compiler_options(compiler, opts)
    opts.on("-d", "--debug", "Add full symbolic debug info") do
      compiler.debug = Iyi::Debug::All
    end
    opts.on("--no-debug", "Skip any symbolic debug info") do
      compiler.debug = Iyi::Debug::None
    end
    opts.on("-D FLAG", "--define FLAG", "Define a compile-time flag") do |flag|
      compiler.flags << flag
    end
    opts.on("--error-trace", "Show full error trace") do
      @error_trace = true
      compiler.show_error_trace = true
    end
    opts.on("--release", "Compile in release mode (-O3 --single-module)") do
      compiler.release!
    end
    opts.on("-O LEVEL", "Optimization mode: 0 (default), 1, 2, 3, s, z") do |level|
      if mode = Compiler::OptimizationMode.from_level?(level)
        compiler.optimization_mode = mode
      else
        raise Error.new("Invalid optimization mode: O#{level}")
      end
    end
    opts.on("--single-module", "Generate a single LLVM module") do
      compiler.single_module = true
    end
    opts.on("--threads NUM", "Maximum number of threads to use") do |n_threads|
      compiler.n_threads = n_threads.to_i? || raise Error.new("Invalid thread count: #{n_threads}")
    end
    opts.on("-s", "--stats", "Enable statistics output") do
      compiler.progress_tracker.stats = true
    end
    opts.on("-p", "--progress", "Enable progress output") do
      compiler.progress_tracker.progress = true
    end
    opts.on("-t", "--time", "Enable execution time output") do
      @time = true
    end
    opts.on("-h", "--help", "Show this message") do
      puts opts
      exit
    end
    opts.on("--no-color", "Disable colored output") do
      @color = false
      compiler.color = false
    end
    target_specific_opts(opts, compiler)
    setup_compiler_warning_options(opts, compiler)
    opts.invalid_option { }
  end

  private def target_specific_opts(opts, compiler)
    opts.on("--mcpu CPU", "Target specific cpu type") do |cpu|
      if cpu == "native"
        compiler.mcpu = LLVM.host_cpu_name
      else
        compiler.mcpu = cpu
        if cpu == "help"
          # LLVM will display a help message the moment the target machine is
          # created, but "help" is not a valid CPU name, so exit immediately
          compiler.create_target_machine
          exit
        end
      end
    end
    opts.on("--mattr CPU", "Target specific features") do |features|
      compiler.mattr = features
    end
    opts.on("--mcmodel MODEL", "Target specific code model") do |mcmodel|
      compiler.mcmodel = case mcmodel
                         when "default" then LLVM::CodeModel::Default
                         when "tiny"    then LLVM::CodeModel::Tiny
                         when "small"   then LLVM::CodeModel::Small
                         when "kernel"  then LLVM::CodeModel::Kernel
                         when "medium"  then LLVM::CodeModel::Medium
                         when "large"   then LLVM::CodeModel::Large
                         else
                           abort! "--mcmodel should be one of: default, kernel, tiny, small, medium, large", :USAGE_ERROR
                         end
    end
  end

  private def setup_compiler_warning_options(opts, compiler)
    opts.on("--warnings all|none", "Which warnings to detect. (default: all)") do |w|
      compiler.warnings.level = case w
                                when "all"
                                  Iyi::WarningLevel::All
                                when "none"
                                  Iyi::WarningLevel::None
                                else
                                  abort! "--warnings should be all, or none", :USAGE_ERROR
                                end
    end
    opts.on("--error-on-warnings", "Treat warnings as errors.") do |w|
      compiler.warnings.error_on_warnings = true
    end
    opts.on("--exclude-warnings <path>", "Exclude warnings from path (default: lib)") do |f|
      compiler.warnings.exclude_lib_path = false
      compiler.warnings.exclude_path(f)
    end

    compiler.warnings.exclude_lib_path = true
  end

  private def validate_emit_values(values)
    emit_targets = Compiler::EmitTarget::None
    values.each do |value|
      if target = Compiler::EmitTarget.parse?(value.gsub('-', '_'))
        emit_targets |= target
      else
        abort! "invalid emit value '#{value}'", :USAGE_ERROR
      end
    end
    emit_targets
  end

  # iyi: what the filesystem said, as a sentence about the path the author
  # named. Crystal's own wording for a `File::Error` is "Error opening file
  # with mode 'r': '<path>': Permission denied" — it names an argument of
  # `open(2)` nobody passed, and prefixed with "Error: " it says the word
  # twice. The path and the reason are the two facts.
  private def filesystem_sentence(ex : IO::Error) : String
    reason = ex.os_error.try(&.message) || ex.message.to_s
    ex.is_a?(File::Error) ? "#{ex.file}: #{reason}" : reason
  end

  private def abort!(msg, exit : Command::Exit)
    print_error(msg)
    exit exit.to_i
  end

  private def print_error(msg)
    # This is for the case where the main command is wrong
    @color = false if ARGV.includes?("--no-color") || !Colorize.default_enabled?(STDOUT, STDERR)
    Iyi.print_error(msg, @color)
  end

  private def self.iyi_opts
    Config.env("OPTS").try { |opts| Process.parse_arguments(opts) }
  rescue ex
    raise Error.new("Failed to parse #{Command.program_name.upcase}_OPTS: #{ex.message}")
  end

  # Constructs an `OptionParser` from the given block and runs it twice, first
  # time with `IYI_OPTS`, second time with the given *options*.
  #
  # Only flags are accepted in the first run; positional arguments, invalid
  # options (where they might be treated as normal arguments), and `--` are all
  # disallowed. The option parser should not define any subcommands.
  def self.parse_with_iyi_opts(options, & : OptionParser ->)
    option_parser = OptionParser.new { |opts| yield opts }

    if iyi_opts = self.iyi_opts
      old_unknown_args = option_parser.@unknown_args
      old_invalid_option = option_parser.@invalid_option
      old_before_each = option_parser.@before_each

      option_parser.unknown_args { }
      option_parser.invalid_option { |opt| raise OptionParser::InvalidOption.new(opt) }
      option_parser.before_each do |opt|
        raise Error.new "IYI_OPTS may not contain --" if opt == "--"
      end

      option_parser.parse(iyi_opts)
      unless iyi_opts.empty?
        raise Error.new "IYI_OPTS may not contain positional arguments"
      end

      option_parser.unknown_args(&old_unknown_args) if old_unknown_args
      option_parser.invalid_option(&old_invalid_option)
      if old_before_each
        option_parser.before_each(&old_before_each)
      else
        option_parser.before_each { }
      end
    end

    option_parser.parse(options)
    option_parser
  end

  private def parse_with_iyi_opts(& : OptionParser ->)
    Command.parse_with_iyi_opts(@options) { |opts| yield opts }
  end

  private def new_compiler
    @compiler = Compiler.new
  end
end
