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
  # The text of a macro literal (what stands between `{% if %}` and `{% end %}`) is not
  # parsed with the text around it, since which of it survives is the macro's to say. It
  # is code all the same, and a consumer expands it where the root has been stripped, so
  # each run of it is read on its own: parsed where it stands as source by itself, and
  # searched for names where it does not (`when Root::A` whose `case` is outside it).
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
      paths(text, entry, iyi, parameters, index, 0)
    end

    # *depth* counts the macro literals this text is inside.
    private def self.paths(text : String, entry : Entry, iyi : Bool,
                           parameters : Array(String), index : Int32?, depth : Int32) : Array(BoundPathOccurrence)
      failure = nil
      ([entry] + Entry.values.reject { |other| other == entry }).each do |candidate|
        begin
          before, after = wrapper(candidate, parameters, index)
          return read(text, candidate, iyi, before, after, parameters, depth)
        rescue error : CodeError | ArgumentError | InvalidByteSequenceError | IndexError
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

    # A parser that keeps every path it reads and where its first segment started, and the
    # bytes of every macro literal token.
    class PathReader < Parser
      getter paths = [] of {Array(String), Location}
      getter macro_literals = [] of {Int32, Int32}

      def parse_path(global, location)
        # The first segment's token: a leading `::` has been read already.
        first = @token.location
        path = super
        @paths << {path.names.dup, first}
        path
      end

      def next_macro_token(macro_state, skip_whitespace)
        token = super
        if token.type.macro_literal?
          # The token's value is the bytes it was read from, and the reader stands after them.
          finish = current_pos
          @macro_literals << {finish - token.value.to_s.bytesize, finish}
        end
        token
      end

      # What a lookahead that failed read is read again, so it is not kept twice or kept
      # for a reading the parser gave up.
      def lookahead(preserve_token_on_fail = false, &)
        count = @paths.size
        literals = @macro_literals.size
        result = super(preserve_token_on_fail) { yield }
        unless result
          @paths.pop(@paths.size - count)
          @macro_literals.pop(@macro_literals.size - literals)
        end
        result
      end
    end

    private def self.read(text : String, entry : Entry, iyi : Bool, before : String, after : String,
                          parameters : Array(String), depth : Int32) : Array(BoundPathOccurrence)
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
      found = occurrences(text, source, before.bytesize, parser.paths)

      literal_runs(parser.macro_literals, before.bytesize, text.bytesize).each do |(start, finish)|
        literal_paths(text.byte_slice(start, finish - start), iyi, parameters, depth).each do |(names, offset)|
          path = occurrence(text, start + offset, names)
          found << path unless found.includes?(path)
        end
      end

      found.sort_by!(&.start)
      found.each_cons_pair do |earlier, later|
        raise ArgumentError.new("parsed paths overlap") if later.start < earlier.finish
      end
      found
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
        path = occurrence(text, start, names)
        found << path unless found.includes?(path)
      end
      found
    end

    # The path *names* at byte *start* of *text*, with the bytes beside it.
    private def self.occurrence(text : String, start : Int32, names : Array(String)) : BoundPathOccurrence
      finish = start + names.join("::").bytesize
      bytes = text.to_unsafe
      first_end = start + names[0].bytesize
      BoundPathOccurrence.new(start, finish, names,
        start > 0 ? bytes[start - 1] : nil,
        first_end < text.bytesize ? bytes[first_end] : nil,
        finish < text.bytesize ? bytes[finish] : nil)
    end

    # The runs of macro literal text in the bound text: the tokens' bytes, less the
    # *base* bytes of source before the text, joined where one token ends as the next
    # begins. A literal is lexed a line at a time, and a run is what reads as source.
    private def self.literal_runs(tokens : Array({Int32, Int32}), base : Int32, size : Int32) : Array({Int32, Int32})
      runs = [] of {Int32, Int32}
      tokens.uniq.sort!.each do |(token_start, token_finish)|
        start = Math.max(token_start - base, 0)
        finish = Math.min(token_finish - base, size)
        next unless start < finish
        if (last = runs.last?) && start <= last[1]
          runs[-1] = {last[0], Math.max(last[1], finish)}
        else
          runs << {start, finish}
        end
      end
      runs
    end

    # The paths of one run of macro literal text, each with its byte offset in the run.
    private def self.literal_paths(run : String, iyi : Bool, parameters : Array(String), depth : Int32) : Array({Array(String), Int32})
      # A literal inside a literal's text is searched, not read again.
      return scan(run) if depth > 0
      paths(run, Entry::Body, iyi, parameters, nil, depth + 1).map { |path| {path.names, path.start} }
    rescue ArgumentError
      scan(run)
    end

    # The names in text that does not read as source: every run of `Name` and
    # `Name::Name` that starts where no name is already under way. This is what a
    # search finds, a name inside a string included.
    private def self.scan(text : String) : Array({Array(String), Int32})
      found = [] of {Array(String), Int32}
      bytes = text.to_slice
      index = 0
      while index < bytes.size
        unless upper?(bytes[index]) && (index == 0 || !name_byte?(bytes[index - 1]))
          index += 1
          next
        end
        start = index
        names = [] of String
        loop do
          segment = index
          while index < bytes.size && name_byte?(bytes[index])
            index += 1
          end
          names << String.new(bytes[segment, index - segment])
          break unless index + 2 < bytes.size && bytes[index] == 0x3A_u8 && bytes[index + 1] == 0x3A_u8 && upper?(bytes[index + 2])
          index += 2
        end
        found << {names, start}
      end
      found
    end

    private def self.upper?(byte : UInt8) : Bool
      byte >= 0x41_u8 && byte <= 0x5A_u8
    end

    private def self.name_byte?(byte : UInt8) : Bool
      byte == 0x5F_u8 || upper?(byte) ||
        (byte >= 0x30_u8 && byte <= 0x39_u8) ||
        (byte >= 0x61_u8 && byte <= 0x7A_u8)
    end
  end
end
