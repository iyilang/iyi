# iyi: the compiler under its own name.
#
# Everything here delegates to `Iyi::Command`, which is the same compiler
# doing the same work: iyi's compiler is built on Crystal's, and the version
# line says so rather than hiding it. What this file changes is the surface a
# person meets — the commands iyi has, a usage line that names them, and a
# version that puts the language first and what it is built on after.
#
# The commands left out are left out on purpose. `init` and `spec` belong to a
# language with a package layout and a spec runner, and iyi has neither. The
# playground and the documentation generator are not here at all: they went the
# way the interpreter went, for the reason SPEC.md V.11 gives — and so, now,
# has the `repl` slice that briefly reopened that call: a session on the macro
# evaluator answered iyi code with the other language's library, so `"ab" * -3`
# came back "Negative argument" where the compiler says "negative count: -3".
# Two implementations of the semantics is what V.11 objected to, and the
# smaller one is still one too many.
{% raise("Please use `make iyi` to build it, or set the i_know_what_im_doing flag if you know what you're doing") unless env("CRYSTAL_HAS_WRAPPER") || flag?("i_know_what_im_doing") %}

require "log"
require "./requires"

Log.setup_from_env(default_level: :warn, default_sources: "crystal.*")

{% if Fiber.has_constant?(:ExecutionContext) %}
  Fiber::ExecutionContext.default.resize(Fiber::ExecutionContext.default_workers_count)
{% end %}

module Iyi
  USAGE = <<-USAGE
    iyi — a language built for Developer & Agentic Experience, Portability,
    Performance, and Efficiency.

    Usage: iyi [command] [switches] [program file] [--] [arguments]

    Command:
        build                    build an executable
        run                      build and run a program (default)
        mod                      inspect a .iyimod module artifact
        doc                      print a module's exported surface, or a prelude type's
        test                     run every *_test.iyi: exit 0 passes, anything else fails
        vet                      report unreachable code; findings are the exit code
        check                    type-check only; errors are the exit code, `-f json` makes them data
        fix                      apply the compiler's did-you-mean edits until the file is clean
        bind                     put every shard under lib/ behind a boundary, as .iyimod files
        migrate                  write a Crystal tree as iyi modules, the namespace as the path
        lsp                      serve the language over stdio (editors, agents)
        mcp                      serve the compiler's verbs as MCP tools over stdio (agents)
        daemon                   hold the prelude analysed between builds
        env                      print environment information
        clear_cache              clear the compiler cache
        tool                     formatter and editor tools, Crystal's
        version                  print the version
        help                     print this text

    Switches worth knowing:
        --crystal                build against Crystal's standard library
        --emit-iyimod DIR        write a .iyimod per imported module into DIR
        --use-iyimod DIR         compile imports from DIR's .iyimod files
        --no-codegen             analyse only, produce nothing
        --release                optimise, and take longer about it

    A `.iyi` entry file gets iyi's prelude; `--crystal` gives it Crystal's
    instead, and there `require "kemal"` means what it means in Crystal. The
    rules do not change with the library. `iyi daemon` is for that second mode:
    it holds Crystal's library analysed between builds and halves them. See
    SPEC.md for the design and README.md for what is and is not here.
    USAGE

  # What the binary calls itself, read from `src/IYI_VERSION` — the same file
  # the artifact's compatibility check reads (SPEC.md IV.5) and the same one
  # the Makefile names the tarball after. One number, so a released binary, the
  # artifacts it writes and the file it arrived in cannot disagree.
  VERSION = Iyi::Config.iyi_version

  DELEGATED = %w(build run mod env clear_cache tool daemon test doc lsp vet check fix bind migrate mcp)

  # The ones that belong to Crystal and are still in the binary underneath.
  # Named rather than swallowed, because "unknown command" would be a lie.
  #
  # `eval` is here because of what it compiles: it has no filename, so it gets
  # Crystal's prelude and Crystal's rules, and `iyi eval 'require "json"'`
  # worked. A command that answers in another language is worse than one that
  # says where it went.
  CRYSTAL_ONLY = %w(init spec eval)

  def self.description : String
    String.build do |io|
      # The name first, then what it is built on. Both, because the licence
      # requires the second and the language is not the second's dialect.
      io << "iyi " << VERSION << " (built on " << Iyi::Config.description.lines.first << ")"
      io << "\n\nThe compiler was not built in release mode." unless Iyi::Config.release_mode?
    end
  end

  def self.run(options = ARGV) : Nil
    # The delegated commands print their own usage, and it used to name the
    # binary underneath instead of the one that was typed.
    Iyi::Command.program_name = "iyi"

    command = options.first?

    case command
    when nil
      puts USAGE
      exit
    when "help", "--help", "-h"
      # `iyi help nonesuch` printed the whole usage and exited 0, which read
      # as "yes, that is a command", and `iyi help build` did the same as if
      # the verb had no help of its own. A verb's help is the verb's.
      if (verb = options[1]?) && verb != "help"
        case verb
        when .in?(DELEGATED)
          Iyi::Command.run([verb, "--help"])
        when .in?(CRYSTAL_ONLY)
          STDERR.puts "iyi has no `#{verb}`: it belongs to Crystal, which this compiler is also built on."
          exit 1
        else
          STDERR.puts "iyi help: there is no `#{verb}` command. Run `iyi help` for what there is."
          exit 1
        end
      end
      puts USAGE
      exit
    when "version", "--version", "-v"
      # `iyi version extra` printed the version and dropped the word, the way
      # `clear_cache extra` used to.
      if extra = options[1]?
        STDERR.puts "iyi version takes no arguments, and '#{extra}' is one."
        exit 1
      end
      puts description
      exit
    when .in?(CRYSTAL_ONLY)
      STDERR.puts "iyi has no `#{command}`: it belongs to Crystal, which this compiler is also built on."
      STDERR.puts "Run it with the `crystal` binary in this checkout if you need it."
      exit 1
    when .in?(DELEGATED)
      Iyi::Command.run(options)
    else
      # A filename, which `crystal foo.iyi` reads as "run this". Kept, because
      # it is the shortest thing to type and the shell already made it a path.
      if File.file?(command)
        Iyi::Command.run(options)
      else
        STDERR.puts "iyi: unknown command or missing file: #{command}"
        STDERR.puts "Run `iyi help` for what there is."
        exit 1
      end
    end
  end
end

Iyi.run
