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
    selfhost = false
    OptionParser.parse(@options) do |opts|
      opts.banner = <<-USAGE
        Usage: #{Command.program_name} tool format [options] [- | file or directory ...]

        Formats iyi and Crystal code in place.

        If a file or directory is omitted,
        Crystal source files beneath the working directory are formatted.

        To format STDIN to STDOUT, use '-' in place of any path arguments.

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

      opts.on("--selfhost", "Use the pure iyi self-hosted formatter") do
        selfhost = true
      end
    end

    if selfhost && !FormatCommand.find_selfhost_format_tool
      abort! "iyi tool format: self-host tool not found. Build it with `make iyi-format` or set IYI_FORMAT_BIN", :SOFTWARE_ERROR
    end

    files = options

    format_command = FormatCommand.new(
      files,
      includes,
      excludes,
      check,
      show_backtrace,
      @color,
      selfhost: selfhost,
    )
    format_command.run
    exit format_command.status_code
  end

  class FormatCommand
    @format_stdin : Bool
    @files : Array(String)
    @excludes : Array(String)

    @selfhost : Bool
    getter status_code = 0

    def initialize(
      files : Array(String),
      includes = [] of String, excludes = [] of String,
      @check : Bool = false,
      @show_backtrace : Bool = false,
      @color : Bool = true,
      # stdio is injectable for testing
      @stdin : IO = STDIN, @stdout : IO = STDOUT, @stderr : IO = STDERR,
      @selfhost : Bool = false,
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

    private def format_stdin
      source = @stdin.gets_to_end
      format_source "STDIN", source
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
        filename = ::Path[filename.chomp('/')].to_posix
        filenames = Dir["#{filename}/**/*.cr"] + Dir["#{filename}/**/*.iyi"]
        format_many filenames
      else
        print_error "file or directory does not exist: #{filename}"
      end
    end

    private def format_file(filename)
      source = File.read(filename)
      format_source filename, source
    end

    private def format_source(filename, source)
      result = format(filename, source)
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
      if @show_backtrace
        ex.inspect_with_backtrace @stderr
        @stderr.puts
        print_error "couldn't format '#{filename}', please report a bug including the contents of it: https://github.com/crystal-lang/crystal/issues"
      else
        print_error "there's a bug formatting '#{filename}', to show more information, please run:\n\n  $ crystal tool format --show-backtrace #{@format_stdin ? "-" : "'#{filename}'"}\n"
      end
      @status_code = 1
    end

    # This method is for mocking `Iyi.format` in test.
    private def format(filename, source)
      if @selfhost
        run_selfhost_format(filename, source)
      else
        Iyi.format(source, filename: filename, report_warnings: STDERR)
      end
    end

    private def run_selfhost_format(filename : String, source : String) : String
      tool = FormatCommand.find_selfhost_format_tool
      unless tool
        print_error "iyi tool format: self-host tool not found. Build it with `make iyi-format` or set IYI_FORMAT_BIN"
        @status_code = 1
        return source
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
        out_io.to_s
      else
        err_msg = err_io.to_s.strip
        err_msg = "error formatting '#{filename}'" if err_msg.empty?
        print_error err_msg
        @status_code = 1
        source
      end
    end

    def self.find_selfhost_format_tool : String?
      if env = Config.env("FORMAT_BIN")
        return env if File.file?(env)
      end

      tool_name = "iyi-format"
      candidates = [] of String
      if exec = Process.executable_path
        candidates << File.join(File.dirname(exec), tool_name)
        candidates << File.join(File.dirname(exec), "selfhost-formatter")
      end
      candidates << File.join(".build", tool_name)
      candidates << File.join(".build", "selfhost-formatter")

      if found = candidates.find { |c| File.file?(c) }
        return found
      end

      nil
    end

    private def print_error(msg)
      Iyi.print_error msg, @color, stderr: @stderr, leading_error: false
    end
  end
end
