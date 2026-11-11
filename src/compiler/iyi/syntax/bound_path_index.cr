require "./parser"

module Iyi
  # One path of bound text. Offsets are byte offsets into the text.
  #
  # `before` and `after` are the bytes either side of the whole path. `after_first`
  # is the byte after its first segment.
  record BoundPathOccurrence, start : Int32, finish : Int32, names : Array(String),
    before : UInt8?, after_first : UInt8?, after : UInt8?

  # Which paths a bound rewrite touches.
  module BoundPathRules
    # `Root::X` for the root `Root`. A path that is the root itself is not rooted
    # at it, and neither is a global `::Root::X` or an interior `Other::Root::X`.
    def self.rooted_at?(path : BoundPathOccurrence, segments : Array(String)) : Bool
      path.names.size > segments.size && path.names[0, segments.size] == segments && !continued_before?(path)
    end

    # A path whose first segment is the bound name *name*.
    def self.headed_by?(path : BoundPathOccurrence, name : String) : Bool
      path.names[0] == name && !continued_before?(path) && !identifier_byte_at?(path.after_first)
    end

    # The single-segment path *name*, with no `::` neighbour.
    def self.alias_of?(path : BoundPathOccurrence, name : String) : Bool
      path.names.size == 1 && path.names[0] == name && !continued_before?(path) && !scope_or_identifier_at?(path.after)
    end

    # A name does not start right after `:` or an identifier byte.
    private def self.continued_before?(path : BoundPathOccurrence) : Bool
      byte = path.before
      return false unless byte
      byte == 0x3A_u8 || identifier_byte?(byte)
    end

    private def self.identifier_byte_at?(byte : UInt8?) : Bool
      byte ? identifier_byte?(byte) : false
    end

    private def self.scope_or_identifier_at?(byte : UInt8?) : Bool
      return false unless byte
      byte == 0x3A_u8 || identifier_byte?(byte)
    end

    private def self.identifier_byte?(byte : UInt8) : Bool
      byte == 0x5F_u8 ||
        (byte >= 0x30_u8 && byte <= 0x39_u8) ||
        (byte >= 0x41_u8 && byte <= 0x5A_u8) ||
        (byte >= 0x61_u8 && byte <= 0x7A_u8)
    end
  end

  # The paths in a piece of bound text, read by the parser.
  #
  # `tool bind` rewrites names in text it has already printed: a body, a restriction, a
  # parameter, a `fun` line. Searching that text for a name also finds the name inside a
  # string, a regex or a comment, and telling those apart needs the parser: only it knows
  # whether `/` divides or opens a regex, where an interpolation ends, and what a heredoc
  # holds. So the text is parsed, and the paths are the ones the parser read, at the
  # byte offsets it read them from.
  #
  # Text inside a macro literal is not parsed, so it holds no path.
  module BoundPathIndex
    # What the text is, which decides how it is parsed.
    enum Entry
      # A method body.
      Body
      # A value: a field's default, a class variable's or a constant's value.
      Expression
      # A type: a restriction, a return type, a superclass.
      Type
      # One parameter of a signature, a block parameter included.
      Parameter
      # One line of a `lib` body.
      FunLine
    end

    # The paths of *text*, in order. *entry* is tried first and the other entries after
    # it, because a caller holding text does not always know which of them it is. Text
    # that parses as none of them raises: rewriting it by search would be a guess.
    #
    # *parameters* are the parameters of the signature the text belongs to, the block
    # parameter last. A body is read inside a def that declares them, because the parser
    # reads `x = x.abs`, `n -= 1` and `->obj.call` only where `x`, `n` and `obj` are
    # variables. A parameter is read at *index* among them, because a default may name an
    # earlier parameter and a bare `*` must be followed by one.
    def self.paths(text : String, entry : Entry, iyi : Bool,
                   parameters : Array(String) = [] of String, index : Int32? = nil) : Array(BoundPathOccurrence)
      failure = nil
      ([entry] + Entry.values.reject { |other| other == entry }).each do |candidate|
        begin
          before, after = wrapper(candidate, parameters, index)
          return read(text, candidate, iyi, before, after)
        rescue error : CodeError | ArgumentError | InvalidByteSequenceError
          failure ||= error
        end
      end
      raise ArgumentError.new("bound text cannot be read as source: #{failure.try(&.message)}: #{text.inspect}")
    end

    # The source *text* is parsed inside: what stands before it and what stands after it.
    private def self.wrapper(entry : Entry, parameters : Array(String), index : Int32?) : {String, String}
      case entry
      in .body?
        {"def __iyi_bound__(#{parameters.join(", ")})\n", "\nend"}
      in .expression?, .type?
        {"", ""}
      in .parameter?
        earlier = index ? parameters[0, index] : [] of String
        later = index ? parameters[index + 1..] : [] of String
        {"def __iyi_bound__(#{earlier.map { |parameter| "#{parameter}, " }.join}",
         "#{later.map { |parameter| ", #{parameter}" }.join})\nend"}
      in .fun_line?
        {"lib LibIyiBound\n", "\nend"}
      end
    end

    # A parser that keeps every path it reads and where its first segment started.
    class PathReader < Parser
      getter paths = [] of {Array(String), Location}

      def parse_path(global, location)
        # The first segment's token: a leading `::` has been read already.
        first = @token.location
        path = super
        @paths << {path.names.dup, first}
        path
      end

      # What a lookahead that failed read is read again, so it is not kept twice or kept
      # for a reading the parser gave up.
      def lookahead(preserve_token_on_fail = false, &)
        count = @paths.size
        result = super(preserve_token_on_fail) { yield }
        @paths.pop(@paths.size - count) unless result
        result
      end
    end

    private def self.read(text : String, entry : Entry, iyi : Bool, before : String, after : String) : Array(BoundPathOccurrence)
      source = "#{before}#{text}#{after}"
      parser = PathReader.new(source)
      parser.iyi = iyi
      if entry.type?
        parser.next_token
        parser.parse_bare_proc_type
        parser.check :EOF
      else
        parser.parse
      end
      occurrences(text, source, before.bytesize, parser.paths)
    end

    # The paths of *source* that lie in *text*, which starts *base* bytes into it.
    private def self.occurrences(text : String, source : String, base : Int32,
                                 paths : Array({Array(String), Location})) : Array(BoundPathOccurrence)
      # The byte each line of the source starts at.
      line_starts = [0]
      source.to_slice.each_with_index { |byte, index| line_starts << index + 1 if byte == 0x0A_u8 }

      found = [] of BoundPathOccurrence
      paths.each do |(names, location)|
        line_start = line_starts[location.line_number - 1]? || raise ArgumentError.new("parsed path lies outside the bound text")
        # A column counts characters, and an offset counts bytes.
        reader = Char::Reader.new(source, line_start)
        (location.column_number - 1).times { reader.next_char }
        start = reader.pos - base
        finish = start + names.join("::").bytesize
        # A name of the wrapper, not of the text.
        next if finish <= 0 || start >= text.bytesize
        raise ArgumentError.new("parsed path crosses the bound text") if start < 0 || finish > text.bytesize
        unless text.byte_slice(start, finish - start) == names.join("::")
          raise ArgumentError.new("parsed path is not written as its segments")
        end
        bytes = text.to_unsafe
        first_end = start + names[0].bytesize
        occurrence = BoundPathOccurrence.new(start, finish, names,
          start > 0 ? bytes[start - 1] : nil,
          first_end < text.bytesize ? bytes[first_end] : nil,
          finish < text.bytesize ? bytes[finish] : nil)
        found << occurrence unless found.includes?(occurrence)
      end

      found.sort_by!(&.start)
      found.each_cons_pair do |earlier, later|
        raise ArgumentError.new("parsed paths overlap") if later.start < earlier.finish
      end
      found
    end
  end
end
