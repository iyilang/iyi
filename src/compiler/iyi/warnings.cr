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

    # iyi: `--explain-spawn` (SPEC.md III.4.15): a note for each `g.spawn`,
    # saying whether it runs in parallel and, when it stays in its
    # spawner's unit, what kept it there - the program's own spawns, or
    # with `--explain-spawn=all` std's and the prelude's too. A note is
    # not a warning: nothing is detected, so `--error-on-warnings` does not
    # count one, and a build that asked for none prints none.
    enum ExplainSpawn
      None
      Program
      All
    end

    property explain_spawn = ExplainSpawn::None

    # Each note as where it is and what it says, in the order the cleanup
    # met the spawns.
    getter notes = [] of {Location, String}

    def add_note(location : Location, message : String) : Nil
      @notes << {location, message}
    end

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

      # A SyntaxException either way: the front end built without semantic/
      # (std specs, a shard's build) has no TypeException. Line 0 is no place.
      report = if location
                 SyntaxException.new message, location.line_number, location.column_number, location.filename
               else
                 SyntaxException.new message, 0, 0, nil
               end
      report.warning = true
      @reports << report
    end

    # A warning built by its raise site, which carries more than a node and
    # a message: an edit (`TypeException#suggestion`) for `iyi fix`.
    def add_report(report : CodeError, location : Location?)
      return unless @level.all?
      return if ignore_warning_due_to_location?(location)

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

      filename = location.original_read_from
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
      warnings = compiler.warnings
      if @json_output
        json_report { } unless warnings.reports.empty? && warnings.notes.empty?
      else
        # A note is one line, `file:line:column: note: ...`, the shape an
        # editor's quickfix list and `grep` read.
        warnings.notes.each do |(location, message)|
          STDERR.puts "#{location}: note: #{message}"
        end
        warnings.report(STDERR)
      end
    end

    # iyi: what `-f json` writes to standard error, whatever ends the run: one
    # JSON array, the frames the block writes and then every warning, marked
    # `"severity": "warning"`, then every note (`--explain-spawn`), marked
    # `"severity": "note"`. Warnings were printed there as text, so
    # `check -f json` on a file with one answered `In colon2.iyi:3:17 ...
    # Warning: ...` and exit 0, and a caller parsing it as JSON got nothing.
    def json_report(& : JSON::Builder ->) : Nil
      STDERR.puts(JSON.build do |json|
        json.array do
          yield json
          @compiler.try &.warnings.reports.each(&.to_json_single(json))
          @compiler.try &.warnings.notes.each do |(location, message)|
            json.object do
              json.field "file", location.filename.to_s
              json.field "line", location.line_number
              json.field "column", location.column_number
              json.field "size", 0
              json.field "message", message
              json.field "severity", "note"
            end
          end
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
