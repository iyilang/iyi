module Iyi
  # Which warnings to detect.
  enum WarningLevel
    None
    All
  end

  # This collection handles warning detection, reporting, and related options.
  # It is shared between a `Iyi::Compiler` and other components that need to
  # produce warnings.
  class WarningCollection
    # Which kind of warnings we want to detect.
    property level : WarningLevel = :all

    @excluded_paths = [] of String
    @lib_path : String?

    # Whether to ignore the "lib" path for warning detection. Turned off by
    # the `--exclude-warnings` command-line option.
    def exclude_lib_path? : Bool
      !@lib_path.nil?
    end

    def exclude_lib_path=(exclude : Bool)
      @lib_path = exclude ? File.expand_path(Iyi.normalize_path("lib")) : nil
    end

    # Detected warnings, each kept as the exception that renders it: text for
    # a person (`infos`, `report`) and frames for `-f json`, which used to
    # get them as text in front of the JSON (`Command#json_report`).
    getter reports = [] of CodeError

    # The detected warnings as text, one each.
    def infos : Array(String)
      @reports.map(&.to_s_with_source(nil))
    end

    # Whether the compiler will error if any warnings are detected.
    property? error_on_warnings = false

    def exclude_path(path : ::Path | String)
      @excluded_paths << File.expand_path(Iyi.normalize_path(path))
    end

    def add_warning(node : ASTNode, message : String)
      return unless @level.all?
      return if ignore_warning_due_to_location?(node.location)

      @reports << node.warning(message)
    end

    def add_warning_at(location : Location?, message : String)
      return unless @level.all?
      return if ignore_warning_due_to_location?(location)

      report = if location
                 SyntaxException.new message, location.line_number, location.column_number, location.filename
               else
                 TypeException.new message
               end
      report.warning = true
      @reports << report
    end

    def report(io : IO)
      unless @reports.empty?
        @reports.each do |report|
          io.puts report.to_s_with_source(nil)
          io.puts "\n"
        end
        io.puts "A total of #{@reports.size} warnings were found."
      end
    end

    def ignore_warning_due_to_location?(location : Location?)
      return false unless location

      filename = location.original_filename
      return false unless filename

      if lib_path = @lib_path
        return true if filename.starts_with?(lib_path)
      end

      @excluded_paths.any? do |path|
        filename.starts_with?(path)
      end
    end
  end

  class ASTNode
    def warning(message, inner = nil, exception_type = Iyi::TypeException)
      exception = exception_type.for_node(self, message, inner)
      exception.warning = true
      exception
    end
  end

  class Command
    def report_warnings
      return unless compiler = @compiler
      if @json_output
        json_report { } unless compiler.warnings.reports.empty?
      else
        compiler.warnings.report(STDERR)
      end
    end

    # iyi: what `-f json` writes to standard error, whatever ends the run: one
    # JSON array, the frames the block writes and then every warning, marked
    # `"severity": "warning"`. Warnings were printed there as text, so
    # `check -f json` on a file with one answered `In colon2.iyi:3:17 ...
    # Warning: ...` and exit 0, and a caller parsing it as JSON got nothing.
    def json_report(& : JSON::Builder ->) : Nil
      STDERR.puts(JSON.build do |json|
        json.array do
          yield json
          @compiler.try &.warnings.reports.each(&.to_json_single(json))
        end
      end)
    end

    def warnings_fail_on_exit?
      compiler = @compiler
      return false unless compiler

      warnings = compiler.warnings
      warnings.error_on_warnings? && !warnings.reports.empty?
    end
  end
end
