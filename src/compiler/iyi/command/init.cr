# iyi: `iyi init MODULE [DIR]` — a project, from nothing.
#
# `go mod init example.com/me/hello` writes `go.mod` and stops; `cargo init`
# writes a manifest and a `main.rs` that builds. This is between the two:
# the manifest (`iyi.mod`), an entry file, one module the entry imports and
# one test of it — the four files that show `module`, `import`, `using`,
# `pub` and `iyi test` in a tree that runs the moment it is written.
#
#     iyi init example.com/me/hello
#     iyi run main.iyi
#     iyi test
#
# It was refused before this: `init` sat in the list of verbs that belong to
# Crystal, because Crystal's `init` writes a shard — `shard.yml`, `src/x.cr`,
# a `spec/` directory — which is the wrong shape for a language whose
# module is a file and whose test is a program. The refusal told the reader
# to run it "with the `crystal` binary in this checkout", and a person who
# installed the zip has neither.
#
# Nothing is ever overwritten: a file that is already there is a refusal
# before anything is written, so `iyi init` twice is one project, not a
# damaged one.
class Iyi::Command
  private def iyi_init
    module_path = nil
    directory = nil
    while option = options.shift?
      case option
      when "--help", "-h"
        puts iyi_init_usage
        exit
      when .starts_with?('-')
        abort! "init: unknown flag #{option}", :USAGE_ERROR
      else
        if module_path.nil?
          module_path = option
        elsif directory.nil?
          directory = option
        else
          abort! "unexpected '#{option}' after the module path and the directory", :USAGE_ERROR
        end
      end
    end

    unless module_path
      abort! "init takes a module path: `#{Command.program_name} init example.com/me/hello`, " \
             "or a bare name like `hello` for a project nobody else will import", :USAGE_ERROR
    end

    # The manifest's own grammar decides what a module path is (III.7), and
    # its sentences say why one is not — the same ones a hand-written
    # `iyi.mod` would draw on the first build.
    begin
      Mod::ModFile.parse("module #{module_path}\n", "init")
    rescue ex : Mod::ModError
      # Without the `file:line:` a manifest error carries, because there is
      # no file yet; the sentence after it is the one that matters. Chopped
      # by hand rather than by a regex: a regex literal here puts PCRE on
      # the compiler's floor (SPEC.md III.9), and `bench/dependency_floor.sh`
      # on Windows said so — `pcre2-8.dll` gained — the first time this
      # line was written with one.
      sentence = ex.message.to_s.lchop("init:")
      digits = 0
      while (char = sentence[digits]?) && char.ascii_number?
        digits += 1
      end
      sentence = sentence[digits..].lchop(':').lchop(' ')
      abort! "init: #{sentence}", :USAGE_ERROR
    end

    directory ||= Dir.current
    if File.file?(directory)
      abort! "#{directory} is a file, not a directory to write the project into", :USAGE_ERROR
    end

    files = iyi_init_files(module_path)
    taken = files.keys.select { |name| File.exists?(File.join(directory, name)) }
    unless taken.empty?
      abort! "#{Iyi.relative_filename(directory)} already has #{taken.map { |name| "`#{name}`" }.join(", ")}; " \
             "init writes a new project and never over an old one", :USAGE_ERROR
    end

    Dir.mkdir_p(directory)
    files.each do |name, text|
      File.write(File.join(directory, name), text)
      puts "wrote #{Iyi.relative_filename(File.join(directory, name))}"
    end

    where = directory == Dir.current ? "" : "cd #{Iyi.relative_filename(directory)} && "
    puts
    puts "#{where}#{Command.program_name} run main.iyi    # builds and runs it"
    puts "#{where}#{Command.program_name} test            # runs main_test.iyi"
  end

  # The four files, in the order they are written. The entry has no
  # `module` header because an entry is a program, not a module anyone
  # imports; the module's path is its file's path (R-1), so `greet.iyi` is
  # `import greet` from the directory beside it.
  private def iyi_init_files(module_path : String) : Hash(String, String)
    {
      "iyi.mod" => <<-MOD,
        # This project's manifest. The module line is the path other projects
        # would import it by; a dependency is one line each, which
        # `iyi get example.com/someone/lib` writes:
        #
        #     require example.com/someone/lib v1.2.0
        #
        # and `replace example.com/someone/lib => ../lib` builds one from a
        # directory instead of its tag. `iyi build` fetches what is required
        # and writes iyi.sum beside this.
        module #{module_path}
        MOD
      "greet.iyi" => <<-IYI,
        # A module. Its path is its file's path: `import greet` reads greet.iyi
        # from the directory of the file that imports it.
        module greet

        # `pub` is what another file may reach; a def without it is this
        # module's own.
        pub def hello(name : String) : String
          "hello, \#{name}"
        end
        IYI
      "main.iyi" => <<-IYI,
        # The program. `#{Command.program_name} run main.iyi` builds and runs it.
        import greet
        using greet::{hello}

        puts hello("iyi")
        IYI
      "main_test.iyi" => <<-IYI,
        # A test is a program that passes by exiting 0: `#{Command.program_name} test` runs
        # every *_test.iyi in this directory, and `assert` panics — exit 1 —
        # when what it is handed does not hold.
        import greet
        using greet::{hello}

        assert hello("iyi") == "hello, iyi"
        IYI
    }
  end

  private def iyi_init_usage
    <<-USAGE
    Usage: #{Command.program_name} init MODULE [DIR]

    Write a new project: `iyi.mod` naming MODULE, an entry `main.iyi`, a
    module `greet.iyi` it imports, and `main_test.iyi`. DIR is where, and
    the current directory when it is left out. Nothing that is already
    there is overwritten.

    MODULE is the path other projects would import this one by — a URL's
    path half, `example.com/me/hello` — or a bare name like `hello` for a
    project nobody else will import.
    USAGE
  end
end
