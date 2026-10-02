# Implementation of the `crystal tool format` command
#
# This is just the command-line part. The formatter
# logic is in `crystal/tools/formatter.cr`.

class Iyi::Command
  private def format
    excludes = ["lib"] of String
    includes = [] of String
    check = false
    show_backtrace = false
    stdin_filename = nil.as(String?)

    OptionParser.parse(@options) do |opts|
      opts.banner = <<-USAGE
        Usage: #{Command.program_name} tool format [options] [- | file or directory ...]

        Formats iyi and Crystal code in place.

        If a file or directory is omitted,
        iyi and Crystal source files beneath the working directory are formatted.

        To format STDIN to STDOUT, use '-' in place of any path arguments.
        Which language those bytes are read as is a question a path answers
        and a pipe does not: stdin is read as iyi, and --stdin-filename says
        where it came from when it is Crystal, or when an editor wants its
        own path in the errors.

        Options:
        USAGE

      opts.on("--check", "Checks that formatting code produces no changes") do |f|
        check = true
      end

      opts.on("-i <path>", "--include <path>", "Include path") do |f|
        includes << f
      end

      opts.on("-e <path>", "--exclude <path>", "Exclude path (default: lib)") do |f|
        excludes << f
      end

      opts.on("--stdin-filename <path>", "Path the piped source came from (its extension picks the language)") do |f|
        stdin_filename = f
      end

      opts.on("-h", "--help", "Show this message") do
        puts opts
        exit
      end

      opts.on("--no-color", "Disable colored output") do
        @color = false
      end

      opts.on("--show-backtrace", "Show backtrace on a bug (used only for debugging)") do
        show_backtrace = true
      end
    end

    files = options

    # `tool format ""` - `"$FILE"` with `FILE` unset - normalised to `./`
    # and rewrote every source under the working directory, in place. No
    # path at all means the working directory on purpose; "" is not that.
    if files.any?(&.empty?)
      abort! "format takes a path, and '' is not one (no path at all formats the working directory)", :USAGE_ERROR
    end

    # A flag that is quietly ignored is worse than one that is refused: the
    # editor that passed it would go on believing the language was settled.
    if stdin_filename && !(files.size == 1 && files[0] == "-")
      abort! "--stdin-filename says where stdin's bytes came from, so pass '-' to read them", :USAGE_ERROR
    end

    format_command = FormatCommand.new(
      files,
      includes,
      excludes,
      check,
      show_backtrace,
      @color,
      stdin_filename: stdin_filename,
    )
    format_command.run
    exit format_command.status_code
  end

  class FormatCommand
    @format_stdin : Bool
    @files : Array(String)
    @excludes : Array(String)

    getter status_code = 0

    def initialize(
      files : Array(String),
      includes = [] of String, excludes = [] of String,
      @check : Bool = false,
      @show_backtrace : Bool = false,
      @color : Bool = true,
      # stdio is injectable for testing
      @stdin : IO = STDIN, @stdout : IO = STDOUT, @stderr : IO = STDERR,
      @stdin_filename : String? = nil,
    )
      @format_stdin = files.size == 1 && files[0] == "-"

      includes.map! { |p| Iyi.normalize_path p }
      excludes.map! { |p| Iyi.normalize_path p }
      excludes = excludes - includes
      @walk_all = files.empty?
      if files.empty?
        # iyi: both extensions, because this fork formats both languages and
        # a directory of `.iyi` files is the ordinary case here. The `.iyi`
        # one in any case, so that `UP.IYI` is refused by name
        # (`Lexer.iyi_miscased?`) rather than walked past at exit 0.
        files = Dir["./**/*.cr"] + Dir["./**/*.[iI][yY][iI]"]
      else
        files.map! { |p| Iyi.normalize_path p }
      end

      @files = files
      @excludes = excludes
    end

    def run
      if @format_stdin
        format_stdin
      else
        format_many @files, (walk_excludes(".") if @walk_all)
      end
    end

    # Which language a pipe carries is the one thing a path says and a pipe
    # does not, and the whole compiler reads it off the extension: `!` is a
    # token in a `.iyi` file and a different one in a `.cr` file. `"STDIN"`
    # ends in neither, so stdin was read as Crystal — the one language this
    # binary is not for. `iyi tool format -` answered valid iyi source with
    # a syntax error on `!`, with "expecting identifier 'end'" on a `pub
    # trait`, and an `import` line with "there's a bug formatting 'STDIN',
    # please report a bug", because Crystal's rules made the imported path
    # a division and the formatter's re-lex disagreed with the parse.
    #
    # So stdin is iyi unless the caller names the file it came from, which
    # is what an editor formatting a buffer knows and wants in its errors.
    private def format_stdin
      source = @stdin.gets_to_end
      format_source(@stdin_filename || "STDIN.iyi", source)
    end

    private def format_many(files, excludes : Array(String)?)
      files.each do |filename|
        format_file_or_directory filename, excludes
      end
    end

    # The excludes a walk from *root* prunes with, spelled as `path_key`s:
    # under an exclude as a path is, not as a string starts - `fmt --check
    # .` and `fmt --check <absolute dir>` walked to `.\.\lib\x.iyi` and
    # `C:\...\lib\x.iyi`, which never start with `.\lib`, and checked the
    # `lib` the bare `fmt --check` leaves alone.
    #
    # An exclude prunes what a walk finds; it does not take back a path the
    # caller named, which is Black's rule for `--exclude`. `fmt --check
    # lib/x.iyi` and `fmt --check lib` checked nothing and exited 0, because
    # the default exclude, `lib`, held them: a CI step written for one
    # vendored module passed without reading it. So a named file is never
    # excluded, and a named directory drops the excludes that hold it.
    private def walk_excludes(root) : Array(String)
      root = Iyi.path_key(File.expand_path(root))
      @excludes.compact_map do |exclude|
        base = Iyi.path_key(File.expand_path(exclude))
        base unless root == base || Iyi.path_under?(root, base)
      end
    end

    private def excluded?(filename, excludes : Array(String)) : Bool
      full = Iyi.path_key(File.expand_path(filename))
      excludes.any? { |base| full == base || !Iyi.path_under?(full, base).nil? }
    end

    # *excludes* is nil for a path the caller named, and the walk's for one
    # a walk found.
    private def format_file_or_directory(filename, excludes : Array(String)?)
      if File.file?(filename)
        # A name the caller typed is read as the one stored: a walk's names
        # already are, and on Windows `MAIN.IYI` typed for a stored
        # `main.iyi` is that iyi file (`Lexer.stored_name`), not a
        # `Lexer.iyi_miscased?` one.
        format_file(excludes ? filename : Lexer.stored_name(filename)) unless excludes && excluded?(filename, excludes)
      elsif Dir.exists?(filename)
        # Composed by `Path` rather than by interpolation, because a trailing
        # separator is its business: `chomp('/')` knew only the posix one, so
        # a `src\` would have made the pattern `src\/**/*.cr` and matched
        # nothing. Nothing arrives spelled that way while `normalize_path`
        # chops it first, and now nothing depends on that.
        directory = Iyi.glob_root(filename)
        # And `.iyi` in any case, as above (`Lexer.iyi_miscased?`).
        filenames = Dir[directory.join("**", "*.cr")] + Dir[directory.join("**", "*.[iI][yY][iI]")]
        format_many filenames, walk_excludes(filename)
      else
        # iyi: and a failure, which it was not. `--check` printed this and
        # exited 0, so `iyi tool format --check "$FILE" || exit 1` passed
        # on a path that does not exist — the one case where the check is
        # certainly not being performed.
        print_error "file or directory does not exist: #{filename}"
        @status_code = 1
      end
    rescue ex : File::Error
      # A file that cannot be read is reported, and the walk goes on to the
      # next. Asking what the path is, and reading it, were outside every
      # rescue: on Windows a file this user may not read cannot be asked
      # either, and one such file ended `fmt DIR` with "Error:
      # .\.\a_noread.iyi: Access is denied." before the files after it were
      # looked at.
      print_error "cannot read '#{filename}': #{ex.os_error.try(&.message) || ex.message}"
      @status_code = 1
    end

    private def format_file(filename)
      format_source filename, File.read(filename)
    end

    private def format_source(filename, source)
      # Read as the other language, `UP.IYI` answered `unexpected token:
      # "!"` about valid iyi (`Lexer.iyi_miscased?`).
      if Lexer.iyi_miscased?(filename)
        print_error Lexer.iyi_miscased_sentence(filename)
        @status_code = 1
        return
      end
      result = format(filename, source)

      # Written back with the line endings and the byte order mark the file
      # had (`Iyi.as_written`).
      result = Iyi.as_written(filename, source, result)

      @stdout.print result if @format_stdin
      return if result == source

      if @check
        print_error "formatting '#{filename}' produced changes"
        @status_code = 1
      else
        unless @format_stdin
          File.write filename, result
          @stdout << "Format".colorize(:green).toggle(@color) << ' ' << filename << '\n'
        end
      end
    rescue ex : InvalidByteSequenceError
      # The same question the compiler asks: whichever language the file is
      # written in, not whichever one this command was forked from.
      language = filename.ends_with?(".iyi") ? "iyi" : "Crystal"
      print_error "file '#{filename}' is not a valid #{language} source file: #{ex.message}"
      @status_code = 1
    rescue ex : Iyi::SyntaxException
      print_error "syntax error in '#{filename}:#{ex.line_number}:#{ex.column_number}': #{ex.message}"
      @status_code = 1
    rescue ex : File::Error
      # The file system's refusal - a read-only file, which is common on
      # Windows (a locked checkout, an extracted archive) - and not the
      # formatter's: it was reported as a formatter bug, with a request to
      # file one.
      print_error "cannot write '#{filename}': #{ex.os_error.try(&.message) || ex.message}"
      @status_code = 1
    rescue ex
      # iyi: this fork's tracker and this fork's command name. The advice
      # was `crystal tool format --show-backtrace`, which is a command the
      # reader may not have, about a repository that does not ship the
      # formatter that just failed on them.
      if @show_backtrace
        ex.inspect_with_backtrace @stderr
        @stderr.puts
        print_error "couldn't format '#{filename}', please report a bug including the contents of it: https://github.com/iyilang/iyi/issues"
      else
        print_error "there's a bug formatting '#{filename}', to show more information, please run:\n\n  $ #{File.basename(PROGRAM_NAME)} tool format --show-backtrace #{@format_stdin ? "-" : "'#{filename}'"}\n"
      end
      @status_code = 1
    end

    # This method is for mocking `Iyi.format` in test.
    private def format(filename, source)
      Iyi.format(source, filename: filename)
    end

    private def print_error(msg)
      Iyi.print_error msg, @color, stderr: @stderr, leading_error: false
    end
  end
end
