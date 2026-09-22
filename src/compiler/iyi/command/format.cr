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
      if files.empty?
        # iyi: both extensions, because this fork formats both languages and
        # a directory of `.iyi` files is the ordinary case here.
        files = Dir["./**/*.cr"] + Dir["./**/*.iyi"]
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
        format_many @files
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

    private def format_many(files)
      files.each do |filename|
        format_file_or_directory filename
      end
    end

    private def format_file_or_directory(filename)
      if File.file?(filename)
        unless @excludes.any? { |exclude| filename.starts_with?(exclude) }
          format_file filename
        end
      elsif Dir.exists?(filename)
        # Composed by `Path` rather than by interpolation, because a trailing
        # separator is its business: `chomp('/')` knew only the posix one, so
        # a `src\` would have made the pattern `src\/**/*.cr` and matched
        # nothing. Nothing arrives spelled that way while `normalize_path`
        # chops it first, and now nothing depends on that.
        directory = ::Path[filename].to_posix
        filenames = Dir[directory.join("**", "*.cr")] + Dir[directory.join("**", "*.iyi")]
        format_many filenames
      else
        # iyi: and a failure, which it was not. `--check` printed this and
        # exited 0, so `iyi tool format --check "$FILE" || exit 1` passed
        # on a path that does not exist — the one case where the check is
        # certainly not being performed.
        print_error "file or directory does not exist: #{filename}"
        @status_code = 1
      end
    end

    private def format_file(filename)
      source = File.read(filename)
      format_source filename, source
    end

    private def format_source(filename, source)
      result = format(filename, source)

      # iyi: written back with the line endings the file had. The formatter
      # emits `\n`, so a CRLF file came back with every one of its lines
      # changed — a diff of the whole file for a tool that was asked to fix
      # its indentation, on the platform this fork ships a binary for. And
      # `--check` said "produced changes" about a file whose code was
      # already formatted, naming neither the lines nor the reason.
      #
      # `iyi fix` has always kept them: it splices an edit into the bytes it
      # read. Two verbs over the same file disagreed about what a line ends
      # with, and this is the one that was rewriting.
      #
      # The first line ending in the file decides, which is `rustfmt`'s
      # `newline_style = Auto`. Normalised before it is applied so that a
      # raw CR already in the text cannot become `\r\r\n`.
      result = result.gsub("\r\n", "\n").gsub('\n', "\r\n") if iyi_crlf?(source)

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

    # iyi: whether this text's lines end with CRLF, decided by the first
    # line ending in it — a file is one thing or the other, and asking the
    # first is deterministic where counting is a tie away from surprising.
    private def iyi_crlf?(source : String) : Bool
      return false unless index = source.index('\n')
      index > 0 && source[index - 1] == '\r'
    end

    # This method is for mocking `Iyi.format` in test.
    private def format(filename, source)
      Iyi.format(source, filename: filename, report_warnings: STDERR)
    end

    private def print_error(msg)
      Iyi.print_error msg, @color, stderr: @stderr, leading_error: false
    end
  end
end
