require "./util"
require "./error"
require "colorize"

module Iyi
  # Base class for all errors related to specific user code.
  abstract class CodeError < Error
    property? color = false
    property? error_trace = false
    property? warning = false

    @filename : String | VirtualFile | Nil

    def to_s(io) : Nil
      to_s_with_source(io, nil)
    end

    abstract def to_s_with_source(io : IO, source)

    def to_json(json : JSON::Builder)
      json.array do
        to_json_single(json)
      end
    end

    def true_filename(filename = @filename) : String
      if filename.is_a? VirtualFile
        loc = filename.expanded_location
        if loc
          true_filename loc.filename
        else
          ""
        end
      else
        if filename
          filename
        else
          ""
        end
      end
    end

    def to_s_with_source(source)
      String.build do |io|
        to_s_with_source(io, source)
      end
    end

    def relative_filename(filename)
      Iyi.relative_filename(filename)
    end

    def colorize(obj)
      obj.colorize.toggle(@color)
    end

    def with_color
      Colorize.with.toggle(@color)
    end

    def replace_leading_tabs_with_spaces(line)
      found_non_space = false
      line.gsub do |char|
        if found_non_space
          char
        elsif char == '\t'
          ' '
        elsif char.ascii_whitespace?
          char
        else
          found_non_space = true
          char
        end
      end
    end
  end

  # iyi: more than one error, each found on its own — the definition-site
  # probes (semantic/definition_typing.cr) type one def apiece, and a def
  # whose body is wrong says nothing about the next one's. `check` over a
  # file with three broken defs answered with the first, and the loop was
  # fix, re-run, fix, re-run; each is reported here, in the order the defs
  # are written. Text prints them one after another; `-f json` is the same
  # array of frames a single error writes, each error's frames in turn;
  # the language server makes one diagnostic apiece.
  class CodeErrors < CodeError
    getter errors : Array(CodeError)

    def initialize(@errors : Array(CodeError))
      super(@errors.first.message)
    end

    def color=(@color : Bool)
      @errors.each(&.color=(color))
      color
    end

    def error_trace=(@error_trace : Bool)
      @errors.each(&.error_trace=(error_trace))
      error_trace
    end

    def warning=(@warning : Bool)
      @errors.each(&.warning=(warning))
      warning
    end

    def to_s_with_source(io : IO, source)
      @errors.each_with_index do |error, index|
        io << "\n\n" if index > 0
        error.to_s_with_source(io, source)
      end
      io << "\n\n" << @errors.size << " errors, one per definition that does not type"
    end

    def has_location?
      @errors.first.has_location?
    end

    def append_to_s(io : IO, source)
      to_s_with_source(io, source)
    end

    def deepest_error_message
      @errors.first.deepest_error_message
    end

    def to_json(json : JSON::Builder)
      json.array do
        @errors.each(&.to_json_single(json))
      end
    end

    def to_json_single(json)
      @errors.each(&.to_json_single(json))
    end
  end

  # iyi: text a build parsed under a filename that is not a file to read.
  #
  # The declarations from a `.iyimod` are parsed under the artifact's own path,
  # so that a location points at the module an error came from rather than at
  # nothing. The artifact is binary, so showing "the line" showed the bytes of
  # the container the declarations travelled in — a screen of mojibake under a
  # message that was otherwise exact. The text is registered here on the way in
  # and found here on the way out.
  #
  # Keyed by that path and overwritten at each import, which is what keeps it
  # honest in a process that serves more than one build: the declarations are
  # registered before anything can be typechecked against them, so the entry an
  # error reads is the one this build read.
  @@iyi_declaration_lines = {} of String => Array(String)

  def self.register_iyi_declarations(filename : String, source : String) : Nil
    @@iyi_declaration_lines[filename] = source.lines
  end

  def self.iyi_declaration_lines?(filename : String) : Array(String)?
    @@iyi_declaration_lines[filename]?
  end

  module ErrorFormat
    MACRO_LINES_TO_SHOW               = 3
    OFFSET_FROM_LINE_NUMBER_DECORATOR = 6

    def error_body(source, default_message) : String | Nil
      case filename = @filename
      in VirtualFile
        return format_macro_error(filename)
      in String
        if Iyi.iyi_declaration_lines?(filename) || File.file?(filename)
          return format_error_from_file(filename)
        end
      in Nil
        # go on
      end

      return format_error(source) if source
      default_message
    end

    def line_number_decorator(line_number)
      " #{line_number} | "
    end

    def append_error_indicator(io, offset, column_number, size = 0)
      size ||= 0
      io << '\n'
      io << (" " * (offset + column_number - 1))
      with_color.green.bold.surround(io) do
        io << '^'
        if size > 0
          io << ("-" * (size - 1))
        end
      end
    end

    def filename_row_col_message(filename, line_number, column_number)
      String.build do |io|
        io << colorize("#{relative_filename(filename)}:#{line_number}:#{column_number}").underline
      end
    end

    def format_error(filename, lines, line_number, column_number, size = 0)
      return "#{relative_filename(filename)}" unless line_number

      unless line = lines[line_number - 1]?
        return filename_row_col_message(filename, line_number, column_number)
      end

      String.build do |io|
        case filename
        in String
          io << filename_row_col_message(filename, line_number, column_number)
        in VirtualFile
          io << "macro '" << colorize("#{filename.macro.name}").underline << '\''
        in Nil
          io << "unknown location"
        end

        decorator = line_number_decorator(line_number)
        lstripped_line = line.lstrip
        space_delta = line.size - lstripped_line.size
        # Column number should start at `1`. We're using `0` to track bogus passed
        # `column_number`.
        final_column_number = (column_number - space_delta).clamp(0..)

        io << "\n\n"
        io << colorize(decorator).dim << colorize(lstripped_line.chomp).bold
        append_error_indicator(io, decorator.size, final_column_number, size || 0)
      end
    end

    def format_error_from_file(filename : String)
      lines = Iyi.iyi_declaration_lines?(filename) || File.read_lines(filename)
      formatted_error = format_error(
        filename: @filename,
        lines: lines,
        line_number: @line_number,
        column_number: @column_number,
        size: @size
      )
      "In #{formatted_error}"
    end

    def format_macro_error(virtual_file : VirtualFile)
      show_where_macro_expanded = !(@error_trace && self.responds_to?(:error_trace=))
      String.build do |io|
        io << "There was a problem expanding macro '#{virtual_file.macro.name}'"
        io << "\n\n"
        if show_where_macro_expanded
          append_where_macro_expanded(io, virtual_file)
          io << '\n'
        end
        io << "Called macro defined in "
        append_macro_definition_location(io, virtual_file)
        io << "\n\n"
        io << "Which expanded to:"
        io << "\n\n"
        append_expanded_macro(io, virtual_file.source)
      end
    end

    def remaining(lines : Array(String))
      String.build do |io|
        return if lines.empty?
        io << "\n\n"
        io << lines.skip_while(&.blank?).join('\n')
      end
    end

    def source_lines(filename)
      case filename
      in Nil
        nil
      in String
        if lines = Iyi.iyi_declaration_lines?(filename)
          lines
        elsif File.file? filename
          File.read_lines(filename)
        else
          nil
        end
      in VirtualFile
        filename.source.lines
      end
    end

    def append_macro_definition_location(io, filename : VirtualFile)
      macro_source = filename.macro.location
      source_filename = macro_source.try &.filename
      line_number = macro_source.try &.line_number
      column_number = macro_source.try &.column_number

      case source_filename
      in String
        io << colorize("#{relative_filename(source_filename)}:#{line_number}:#{column_number}").underline
      in VirtualFile
        io << "macro '" << colorize("#{source_filename.macro.name}").underline << '\''
      in Nil
        "unknown location"
      end

      lines = source_lines(source_filename)

      if lines && line_number
        io << "\n\n"
        io << colorize(line_number_decorator(line_number)).dim
        io << lines[line_number - 1].lstrip
      end
    end

    def minimize_indentation(source)
      min_leading_white_space =
        source.min_of? { |line| leading_white_space(line) } || 0

      if min_leading_white_space > 0
        source = source.map do |line|
          replace_leading_tabs_with_spaces(line).lchop(" " * min_leading_white_space)
        end
      end

      {source, min_leading_white_space}
    end

    # iyi: the `/^(\s+)\S/` this was, counted straight off the line. The
    # compiler's own code must not reach for a regex engine for this, since
    # pcre2 is on the list of libraries iyi does not want. The regex ran under
    # UCP, where `\s` is `Char#whitespace?`, and its trailing `\S` is why an
    # all-blank line counts 0 exactly as a non-match did.
    private def leading_white_space(line)
      count = 0
      while line[count]?.try(&.whitespace?)
        count += 1
      end

      # the regex wanted a non-blank char after the run
      return 0 unless count > 0 && line[count]?

      count
    end

    def append_expanded_macro(io, source)
      line_number = @line_number
      if @error_trace || !line_number
        source, _ = minimize_indentation(source.lines)
        io << Iyi.with_line_numbers(source, line_number, @color)
      else
        to_index = line_number.clamp(0..source.lines.size)
        from_index = {0, to_index - MACRO_LINES_TO_SHOW}.max
        source_slice = source.lines[from_index...to_index]
        source_slice, spaces_removed = minimize_indentation(source_slice)

        io << Iyi.with_line_numbers(source_slice, line_number, @color, from_index + 1)
        offset = OFFSET_FROM_LINE_NUMBER_DECORATOR + line_number.to_s.size - spaces_removed
        append_error_indicator(io, offset, @column_number, @size)
      end
    end

    def append_where_macro_expanded(io, filename : VirtualFile)
      expanded_source = filename.expanded_location
      return unless expanded_source
      source_filename = expanded_source.filename
      lines = source_lines(source_filename)
      return unless lines

      io << "Code in " << format_error(
        filename: source_filename,
        lines: lines,
        line_number: expanded_source.line_number,
        column_number: expanded_source.column_number,
      )
    end
  end
end
