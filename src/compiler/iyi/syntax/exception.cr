require "../exception"

module Iyi
  # iyi: the SPEC sections an error message cites, pulled out of the prose
  # so a machine consumer of `-f json` gets them as data. Nil when the
  # message cites nothing, so the field is absent rather than empty.
  #
  # A hand-rolled walk rather than a `Regex`, and not out of taste: a
  # regex literal here links PCRE2 into the compiler, and
  # `bench/dependency_floor.sh` forbids that library by name — it caught
  # the first version of this method within the hour.
  def self.iyi_spec_references(message : String) : Array(String)?
    refs = [] of String
    reader = Char::Reader.new(message)
    marker = "SPEC.md"

    while (start = message.byte_index(marker, reader.pos))
      reader.pos = start + marker.size
      # An optional `,` or `:`, then optional spaces, then the section.
      reader.next_char if reader.current_char.in?(',', ':')
      while reader.current_char == ' '
        reader.next_char
      end

      section = String.build do |io|
        # Groups of roman numerals or digits, joined by dots.
        while reader.current_char.in?('I', 'V', 'X') || reader.current_char.ascii_number?
          io << reader.current_char
          reader.next_char
          if reader.current_char == '.' && (reader.peek_next_char.ascii_number? || reader.peek_next_char.in?('I', 'V', 'X'))
            io << '.'
            reader.next_char
          end
        end
        # A trailing subsection letter: `IV.1d`.
        if reader.current_char.ascii_lowercase? && !reader.peek_next_char.ascii_letter?
          io << reader.current_char
          reader.next_char
        end
      end

      refs << section unless section.empty?
    end

    refs.uniq!
    refs.empty? ? nil : refs
  end
end

module Iyi
  class SyntaxException < CodeError
    include ErrorFormat

    getter line_number : Int32
    getter column_number : Int32
    getter filename
    getter size : Int32?

    def initialize(message, @line_number, @column_number, @filename, @size = nil)
      super(message)
    end

    def has_location?
      @filename || @line_number
    end

    def to_json_single(json)
      json.object do
        json.field "file", true_filename
        json.field "line", @line_number
        json.field "column", @column_number
        # iyi: `0`, not `null`, where the span is unknown. `-f json`
        # promises "file, line, column, size, message" as data, and a
        # type error's size is always an integer; a syntax error's was
        # `null`, so `e["size"]` arithmetic in an agent's loop broke on
        # exactly the error class it meets first. Zero is what the LSP
        # already makes of it.
        json.field "size", @size || 0
        json.field "message", @message
        if (message = @message) && (refs = Iyi.iyi_spec_references(message))
          json.field "spec" do
            json.array do
              refs.each { |ref| json.string ref }
            end
          end
        end
      end
    end

    def append_to_s(io : IO, source)
      msg = @message.to_s
      error_message_lines = msg.lines

      io << error_body(source, default_message)
      io << '\n'
      io << colorize("#{@warning ? "Warning" : "Error"}: #{error_message_lines.shift}").yellow.bold
      io << remaining error_message_lines
    end

    def default_message
      if (filename = @filename) && (line_number = @line_number)
        "#{@warning ? "warning" : "syntax error"} in #{filename}:#{line_number}"
      end
    end

    def to_s_with_source(io : IO, source)
      append_to_s io, source
    end

    def deepest_error_message
      @message
    end
  end
end
