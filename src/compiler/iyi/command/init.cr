# iyi: `iyi init MODULE [DIR]` — a project, from nothing.
#
# `go mod init example.com/me/hello` writes `go.mod` and stops; this writes
# the manifest and the one file the name promises, and stops there too:
#
#     iyi init kemal          # iyi.mod (module kemal) and kemal.iyi
#     iyi run kemal.iyi
#
# The file is the project's root module - `module kemal`, which is what a
# consumer's `import kemal` of the package reads - and it runs as it lands.
# It wrote four files before: an entry, a `greet.iyi` it imported and a
# test of it, a tutorial every project began by deleting.
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
    # `iyi.mod` would draw on the first build. Asked of the path alone: it
    # was asked of a whole manifest, `module <path>`, and a path holding a
    # newline was two directives - `x<LF>require a.b/c v1.0.0<LF>#/hello`
    # wrote `module x` and a `require` nobody asked for, beside `hello.iyi`.
    begin
      Mod::ModFile.check_module_path(module_path)
    rescue ex : Mod::ModError
      abort! "init: #{ex.message}", :USAGE_ERROR
    end

    directory ||= Dir.current
    if File.file?(directory)
      abort! "#{directory} is a file, not a directory to write the project into", :USAGE_ERROR
    end

    # The root module's name is the path's last segment, as a package's is
    # (`split_major`: `/v2` is a version, not a name). A repository name
    # with `-` is a module name with `_`, the grammar allowing no dash.
    name = Mod::ModFile.package_name(module_path)
    unless name
      last = Mod::ModFile.split_major(module_path)[0].rpartition('/')[2]
      abort! "init: '#{last}', the last segment of #{module_path}, cannot name a module: a module name is " \
             "lower-case letters and digits with single `_` between them. Name the project so its last segment is one", :USAGE_ERROR
    end
    files = iyi_init_files(module_path, name)
    taken = files.keys.select { |name| File.exists?(File.join(directory, name)) }
    unless taken.empty?
      abort! "#{Iyi.relative_filename(directory)} already has #{taken.map { |name| "`#{name}`" }.join(", ")}; " \
             "init writes a new project and never over an old one", :USAGE_ERROR
    end

    Dir.mkdir_p(directory)
    files.each do |name, text|
      File.write(File.join(directory, name), "#{text}\n")
      puts "wrote #{Iyi.relative_filename(File.join(directory, name))}"
    end

    # Two lines, not one joined with `&&`: Windows PowerShell 5.1 refuses
    # `&&` ("not a valid statement separator"), and no one separator means
    # the same in cmd, PowerShell and a POSIX shell. None when it is this
    # directory, however it was spelled.
    puts
    unless Iyi.same_file?(directory, Dir.current)
      puts "cd #{iyi_init_shell_word(Iyi.relative_filename(directory))}"
    end
    puts "#{Command.program_name} run #{name}.iyi    # builds and runs it"
  end

  # *path* as one word to `cd`: as it is when every character means itself
  # to every shell, else in double quotes, which cmd, PowerShell and a
  # POSIX shell all read alike - unless it holds what double quotes still
  # expand in PowerShell and a POSIX shell (`$`, a backquote, `!`), where
  # single quotes are the ones that hold it. It was quoted only for a
  # space, and `cd ./x;y` ran `cd ./x` and then `y`; `cd ./d$x` went to
  # `./d`; `cd ./a&b` ran `b` in cmd.
  private def iyi_init_shell_word(path : String) : String
    return path if path.each_char.all? { |c| c.alphanumeric? || c.in?('.', '_', '/', '\\', ':', '-') }
    return %("#{path}") unless path.each_char.any?(&.in?('$', '`', '!', '"'))
    # A quote inside single quotes: PowerShell doubles it, a POSIX shell
    # closes, escapes and reopens.
    {% if flag?(:win32) %}
      "'#{path.gsub('\'', "''")}'"
    {% else %}
      "'#{path.gsub('\'', %q('\''))}'"
    {% end %}
  end

  # The two files, in the order they are written.
  private def iyi_init_files(module_path : String, name : String) : Hash(String, String)
    {
      "iyi.mod" => <<-MOD,
        # `iyi get example.com/someone/lib` adds a dependency here.
        module #{module_path}
        MOD
      "#{name}.iyi" => <<-IYI,
        module #{name}

        puts "hello from #{name}"
        IYI
    }
  end

  private def iyi_init_usage
    <<-USAGE
    Usage: #{Command.program_name} init MODULE [DIR]

    Write a new project: `iyi.mod` naming MODULE, and NAME.iyi, its root
    module, where NAME is MODULE's last segment (`-` written `_`) - `iyi
    init kemal` writes iyi.mod and kemal.iyi. DIR is where, and the current
    directory when it is left out. Nothing that is already there is
    overwritten.

    MODULE is the path other projects would import this one by — a URL's
    path half, `example.com/me/hello` — or a bare name like `hello` for a
    project nobody else will import.
    USAGE
  end
end
