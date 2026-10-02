# iyi: the compiler's own regular expression engine.
#
# The compiler used to reach matching through Crystal's `Regex`, which links
# libpcre2-8. pcre2 sits on Crystal's required-libraries list and iyi means to
# need nothing on it, so matching is owned here. The guarantee recorded in
# SPEC.md III.10 and Appendix B decision 17 is RE2's: linear time always, no
# construct whose cost can grow with the subject.
#
# That guarantee is about cost, not about power, and the two were confused here
# once. RE2 refuses lookaround, so this engine did too, and the reason given was
# that lookaround needs a backtracker. It does not. A lookaround over a regular
# inner pattern is itself a regular property of a position, so it is answered by
# a pre-pass that costs one state set per character and nothing per position.
# Both senses of both directions are supported, nested to any depth, and
# lookbehind is not length-limited the way pcre2's is.
#
# What the trade actually costs is the constructs that are not regular:
# backreferences, recursion, subroutine calls and conditionals. Those are
# refused because no simulation answers them and no care makes them linear.
# Atomic groups and possessive quantifiers are refused for a different reason:
# they are controls for a backtracker, and there is none here to control. A
# capturing group inside an assertion is refused because the pre-pass never
# performs the sub-match that would set it, and reporting empty captures where
# pcre2 reports real ones is the kind of quiet difference this file exists to
# avoid.
#
# Four parts, one file:
#   1. Parser, pattern source to AST.
#   2. Compiler, AST to a Thompson NFA program.
#   3. Assertion pre-pass, one bitmap per assertion per subject.
#   4. Pike VM, runs the program while tracking capture slots.
#
# Match extents and captures agree with the pcre2 the compiler used to link, and
# `spec/compiler/iyi/rx_spec.cr` holds that agreement by running both engines
# over the same corpus, including exhaustive codepoint sweeps for the character
# classes. Agreement is with pcre2 as the stdlib builds it, PCRE2_UTF |
# PCRE2_UCP, so `\w` reads é as a word character and é|b is not a word boundary,
# because that is what every pattern the compiler used to run saw.
#
# Three places state a reading rather than inherit one, and all three are now
# narrow:
#
#   `\d` is any Unicode number, where pcre2 means \p{Nd} exactly, so ½ and Ⅴ
#   count here and do not there. No public stdlib predicate answers Nd on its
#   own: `Char#number?` is Nd plus Nl plus No, and everything finer is `:nodoc:`.
#   Shipping a case table to close one class is worse than saying this, so
#   `\p{Nd}` is refused rather than approximated.
#
#   `(?i)` folds through `Char#downcase(Unicode::CaseOptions::Fold)`, which is
#   simple case folding, the same relation pcre2 uses. It is exact for every
#   codepoint but one pair: ẞ full-folds to "ss", so the stdlib leaves it alone
#   and pcre2 pairs it with ß through simple case mapping. Chasing that one pair
#   with an extra downcase comparison opens others, because simple lowercase is
#   not symmetric.
#
#   Lookbehind follows the union law where pcre2 does not. `(?<=A|B)` holds
#   exactly where `(?<=A)` or `(?<=B)` holds; pcre2's unanchored search reports
#   a grouped mixed-length alternation as holding at positions its own anchored
#   evaluation denies. The spec pins pcre2's per-branch answers and never its
#   answer for the pair.
#
# Anything outside the supported subset raises `SyntaxError` when the pattern
# compiles; refusing loudly beats matching with quietly different semantics.
module Iyi::Rx
  # iyi: `{n,m}` is expanded by repetition at compile time, so the caps are what
  # stand between a pattern and an enormous program. 1000 is RE2's and Go's
  # repeat cap, chosen for the same reason: bounded work, loud refusal.
  MAX_REPEAT =    1000
  MAX_PROG   = 200_000

  # One bit per byte position per lookaround assertion: `maps[k][i]` says whether
  # assertion k holds at byte i. Computed once for a subject and reused for every
  # start offset a sweep over it visits.
  alias LookMaps = Array(Array(Bool))

  class SyntaxError < Exception
    # Byte offset into the pattern source where the refusal happened.
    getter position : Int32

    def initialize(message : String, @position : Int32)
      super(message)
    end
  end

  # One successful match: byte offsets for group 0 and every capturing group.
  struct Match
    getter subject : String

    @slots : Array(Int32)
    @group_count : Int32
    @names : Hash(String, Int32)

    def initialize(@subject : String, @slots : Array(Int32), @group_count : Int32, @names : Hash(String, Int32))
    end

    # Capturing groups, excluding group 0.
    def group_count : Int32
      @group_count
    end

    # Byte offset where the group starts, -1 when the group did not participate.
    def begin(group : Int32 = 0) : Int32
      check_group group
      @slots[group * 2]
    end

    # Exclusive byte offset where the group ends, -1 when it did not participate.
    def end(group : Int32 = 0) : Int32
      check_group group
      @slots[group * 2 + 1]
    end

    # The group's text, nil when the group did not participate. A group that
    # matched empty returns "", which is how a caller tells the two apart.
    def [](group : Int32) : String?
      from = self.begin(group)
      to = self.end(group)
      return nil if from < 0 || to < 0
      Rx.byte_slice(@subject, from, to)
    end

    # Every name the pattern declared, mapped to the group it names. A caller
    # that has to render a whole match, rather than ask for one group, needs the
    # set: the macro layer builds a capture hash and a name absent from it is a
    # capture the macro author wrote and cannot read.
    def names : Hash(String, Int32)
      @names
    end

    # A named group is also a numbered one, so a name reaches exactly what its
    # number reaches.
    def [](name : String) : String?
      self[index_of(name)]
    end

    def begin(name : String) : Int32
      self.begin(index_of(name))
    end

    def end(name : String) : Int32
      self.end(index_of(name))
    end

    private def index_of(name : String) : Int32
      @names.fetch(name) do
        raise KeyError.new("no capture group named #{name.inspect} in this pattern")
      end
    end

    private def check_group(group : Int32) : Nil
      if group < 0 || group > @group_count
        raise IndexError.new("no capture group #{group} in this pattern (0..#{@group_count})")
      end
    end
  end

  # A compiled pattern: an NFA program plus its character class table. Immutable
  # after compilation, so one pattern is safe to match with repeatedly.
  class Pattern
    getter source : String

    @prog : Array(Inst)
    @classes : Array(ClassData)
    @group_count : Int32
    @names : Hash(String, Int32)
    @assertions : Array(Assertion)

    def initialize(@source : String, @prog : Array(Inst), @classes : Array(ClassData),
                   @group_count : Int32, @names : Hash(String, Int32), @assertions : Array(Assertion))
    end

    def self.compile(source : String, ignore_case : Bool = false) : Pattern
      parser = Parser.new(source, ignore_case)
      root = parser.parse
      budget = Budget.new
      assertions = parser.looks.map do |look|
        # A lookahead asks the same question a lookbehind asks, read backwards,
        # so its body is reversed here and its automaton runs backward over the
        # subject. See Part 4 for why that is the whole of it.
        body = look.ahead? ? Rx.reverse(look.body) : look.body
        prog, classes = Compiler.new(budget).compile_assertion(body)
        Assertion.new(prog, classes, look.ahead?)
      end
      prog, classes = Compiler.new(budget).compile(root)
      new(source, prog, classes, parser.group_count, parser.group_names, assertions)
    end

    # Searches for the leftmost match at or after `start`, which is a byte
    # offset. `^` and `\A` still mean the start of the subject, never `start`,
    # so scanning a subject piece by piece cannot invent line starts.
    def match(subject : String, start : Int32 = 0) : Match?
      # A start past the end is no match, not an error: that is what the stdlib's
      # match_at_byte_index answers, and scanning loops lean on it.
      return nil unless 0 <= start <= subject.bytesize
      match_at(subject, start, look_maps(subject))
    end

    # The lookaround bitmaps for *subject*, empty when the pattern has none. They
    # cover the whole subject and say nothing about where matching begins, so a
    # caller sweeping a subject builds them once and hands them to every
    # `match_at` in the sweep.
    def look_maps(subject : String) : LookMaps
      Rx.look_maps(@assertions, subject)
    end

    # `match`, with the bitmaps already in hand.
    def match_at(subject : String, start : Int32, looks : LookMaps) : Match?
      return nil unless 0 <= start <= subject.bytesize
      slots = VM.new(@prog, @classes, @group_count, looks).run(subject, start)
      return nil unless slots
      Match.new(subject, slots, @group_count, @names)
    end

    def matches?(subject : String, start : Int32 = 0) : Bool
      !match(subject, start).nil?
    end
  end

  def self.match(subject : String, pattern : Pattern) : Match?
    pattern.match(subject)
  end

  def self.matches?(subject : String, pattern : Pattern) : Bool
    pattern.matches?(subject)
  end

  def self.gsub(subject : String, pattern : Pattern, replacement : String) : String
    gsub_impl(subject, pattern) { |m| expand_replacement(m, replacement) }
  end

  def self.gsub(subject : String, pattern : Pattern, &block : Match -> String) : String
    gsub_impl(subject, pattern) { |m| block.call(m) }
  end

  def self.sub(subject : String, pattern : Pattern, replacement : String) : String
    sub_impl(subject, pattern) { |m| expand_replacement(m, replacement) }
  end

  def self.sub(subject : String, pattern : Pattern, &block : Match -> String) : String
    sub_impl(subject, pattern) { |m| block.call(m) }
  end

  def self.scan(subject : String, pattern : Pattern) : Array(Match)
    bytes = subject.to_slice
    size = bytes.size
    found = [] of Match
    # The bitmaps once for the sweep rather than once per start offset, which is
    # what keeps a scan linear in the subject instead of quadratic in it.
    looks = pattern.look_maps(subject)
    pos = 0
    while pos <= size
      m = pattern.match_at(subject, pos, looks)
      break unless m
      found << m
      from = m.begin(0)
      to = m.end(0)
      if to > from
        pos = to
      elsif from < size
        # An empty match cannot advance the scan by itself, so step one whole
        # character past it. Stepping one byte would split a UTF-8 sequence.
        _, width = decode(bytes, from, size)
        pos = from + width
      else
        break
      end
    end
    found
  end

  # Fields between matches. Two rules keep this identical to the pcre2-backed
  # `String#split(Regex)` this replaces, and both come from what an empty match
  # means: an empty match sitting exactly where the current field starts yields
  # no field at all, which is why a leading empty match and one landing right
  # after a match are both swallowed, and an empty match always advances one
  # whole character so the scan cannot loop. Trailing empty fields are kept.
  # A capturing pattern interleaves its groups after the field they closed, the
  # way the stdlib does, and a group that did not participate contributes
  # nothing rather than an empty field.
  def self.split(subject : String, pattern : Pattern) : Array(String)
    bytes = subject.to_slice
    size = bytes.size
    parts = [] of String
    looks = pattern.look_maps(subject)
    field = 0
    pos = 0
    while pos < size
      m = pattern.match_at(subject, pos, looks)
      break unless m
      from = m.begin(0)
      to = m.end(0)
      if to == field
        pos = to + char_width(bytes, to, size)
        next
      end
      parts << byte_slice(subject, field, from)
      field = to
      1.upto(m.group_count) do |group|
        text = m[group]
        parts << text if text
      end
      pos = to
      pos = to + char_width(bytes, to, size) if to == from
    end
    parts << byte_slice(subject, field, size)
    parts
  end

  private def self.gsub_impl(subject : String, pattern : Pattern, &append : Match -> String) : String
    bytes = subject.to_slice
    size = bytes.size
    buf = String::Builder.new
    looks = pattern.look_maps(subject)
    pos = 0
    while pos <= size
      m = pattern.match_at(subject, pos, looks)
      break unless m
      from = m.begin(0)
      to = m.end(0)
      buf << byte_slice(subject, pos, from)
      buf << append.call(m)
      if to > from
        pos = to
      elsif from < size
        # Empty match: keep the character sitting here and step past it.
        # Without this, gsub of /b*/ over "abc" would replace forever.
        _, width = decode(bytes, from, size)
        buf << byte_slice(subject, from, from + width)
        pos = from + width
      else
        # An empty match at the very end. Everything up to it is already in the
        # buffer, so the cursor has to move with it: leaving it behind would copy
        # the text between the cursor and the end a second time when the tail is
        # appended below. /$/ over "abc" is the smallest case, and reaches this
        # with no lookaround in sight.
        pos = to
        break
      end
    end
    buf << byte_slice(subject, pos, size)
    buf.to_s
  end

  private def self.sub_impl(subject : String, pattern : Pattern, &append : Match -> String) : String
    m = pattern.match(subject, 0)
    return subject unless m
    buf = String::Builder.new
    buf << byte_slice(subject, 0, m.begin(0))
    buf << append.call(m)
    buf << byte_slice(subject, m.end(0), subject.bytesize)
    buf.to_s
  end

  # `\0` to `\9` name groups and an absent group contributes nothing. `\\` is a
  # literal backslash; any other escaped pair passes through as written, so a
  # replacement carrying Windows paths survives.
  #
  # iyi: `\k<name>` names a group too, now that the engine has named groups:
  # it passed through as written, so `gsub(/(?<w>b)/, "[\\k<w>]")` wrote the
  # reference instead of the capture. A name the pattern does not declare, or
  # a `\k<` with no `>`, fails with the other compiler's messages; a named
  # group that did not participate contributes nothing, as its number does.
  private def self.expand_replacement(m : Match, replacement : String) : String
    return replacement unless replacement.includes?('\\')
    buf = String::Builder.new
    bytes = replacement.to_slice
    size = bytes.size
    i = 0
    while i < size
      b = bytes[i]
      if b == 0x5C && i + 1 < size
        n = bytes[i + 1]
        if 0x30 <= n <= 0x39
          group = (n - 0x30).to_i32
          if group <= m.group_count
            text = m[group]
            buf << text if text
          end
          i += 2
          next
        elsif n == 0x5C
          buf.write_byte 0x5C_u8
          i += 2
          next
        elsif n == 0x6B && i + 2 < size && bytes[i + 2] == 0x3C
          close = replacement.byte_index('>', i + 3)
          raise ArgumentError.new("Missing ending '>' for '\\\\k<...'") unless close
          name = replacement.byte_slice(i + 3, close - i - 3)
          group = m.names[name]?
          raise IndexError.new("Undefined group name reference: #{name.inspect}") unless group
          text = m[group]
          buf << text if text
          i = close + 1
          next
        end
      end
      buf.write_byte b
      i += 1
    end
    buf.to_s
  end

  protected def self.byte_slice(subject : String, from : Int32, to : Int32) : String
    return "" if to <= from
    String.new(subject.to_slice[from, to - from])
  end

  # One definition of a word character, shared by `\w` and by the word sense of
  # `\b`. pcre2 compiled with PCRE2_UCP, which is how the stdlib compiles it and
  # therefore how every pattern the compiler used to run behaved, reads a word
  # character as \p{L}, \p{N} or underscore. `Char#alphanumeric?` is exactly
  # \p{L} plus \p{N}, so this needs no tables of its own.
  protected def self.word_char?(c : Char) : Bool
    c.alphanumeric? || c == '_'
  end

  # pcre2's `\s` under UCP is \p{Xps}: the ASCII spaces, NEL, and \p{Z}.
  # `Char#whitespace?` covers all of that except NEL, which is added here.
  protected def self.space_char?(c : Char) : Bool
    c.whitespace? || c == '\u{0085}'
  end

  # pcre2's `\h`, horizontal whitespace, which is what `\h` means in pcre2 and
  # Perl. It is not a hex digit; that reading is Ruby's, and taking it here would
  # have made `\h+` match "1F" where the engine this replaces matches nothing.
  protected def self.horizontal_space_char?(c : Char) : Bool
    case c
    when '\t', ' ', '\u{00A0}', '\u{1680}', '\u{202F}', '\u{205F}', '\u{3000}'
      true
    else
      '\u{2000}' <= c <= '\u{200A}'
    end
  end

  # pcre2's `\v`, vertical whitespace: the three ASCII line breaks plus VT and
  # FF, then NEL, LINE SEPARATOR and PARAGRAPH SEPARATOR. Seven characters, so
  # they are listed rather than derived; `Char#whitespace?` would also take the
  # horizontal ones.
  protected def self.vertical_space_char?(c : Char) : Bool
    case c
    when '\v', '\n', '\f', '\r', '\u{0085}', '\u{2028}', '\u{2029}'
      true
    else
      false
    end
  end

  # Bytes in the character at `pos`, or 1 at or past the end so a caller
  # stepping past an empty match at the very end walks off the loop instead of
  # reading out of bounds.
  private def self.char_width(bytes : Bytes, pos : Int32, size : Int32) : Int32
    return 1 if pos >= size
    _, width = decode(bytes, pos, size)
    width
  end

  # Decodes one UTF-8 character. Offsets stay byte offsets while matching is per
  # character, which is what lets `.` and classes mean a character and
  # `Match#begin` mean a byte. A malformed or truncated sequence yields its lead
  # byte and a width of one, so damaged input cannot wedge the loop.
  protected def self.decode(bytes : Bytes, pos : Int32, size : Int32) : {Char, Int32}
    b0 = bytes[pos]
    return {b0.unsafe_chr, 1} if b0 < 0x80
    if b0 >= 0xF0
      width = 4
      mask = 0x07_u8
    elsif b0 >= 0xE0
      width = 3
      mask = 0x0F_u8
    elsif b0 >= 0xC0
      width = 2
      mask = 0x1F_u8
    else
      return {b0.unsafe_chr, 1}
    end
    return {b0.unsafe_chr, 1} if pos + width > size
    codepoint = (b0 & mask).to_i32
    1.upto(width - 1) do |k|
      b = bytes[pos + k]
      return {b0.unsafe_chr, 1} if (b & 0xC0) != 0x80
      codepoint = (codepoint << 6) | (b & 0x3F).to_i32
    end
    {codepoint.unsafe_chr, width}
  end

  # ---------------------------------------------------------------------------
  # Part 1: the parser, pattern source to AST.
  #
  # Recursive descent over bytes, decoding whole characters only where a literal
  # can appear. Positions in errors are byte offsets into the pattern.
  # ---------------------------------------------------------------------------

  private enum Anchor
    LineStart     # ^, and with no multiline mode this is \A
    LineEnd       # $, the end or just before one final newline
    TextStart     # \A
    TextEnd       # \z
    TextEndNl     # \Z
    WordBorder    # \b
    NotWordBorder # \B
  end

  # The built-in sets, read the way pcre2 under PCRE2_UCP reads them, because
  # that is how every pattern the compiler used to run behaved: `\w` is \p{L},
  # \p{N} or underscore, `\s` is \p{Xps}, `\h` is horizontal whitespace, `\v` is
  # vertical whitespace, and `\d` is a decimal digit. `\D \W \S \H \V` are their
  # complements, and the class level negation in `[^...]` composes with them.
  #
  # The last five are the general categories `\p{...}` accepts, carried as
  # built-in sets because a property is a set membership test like any other and
  # composes with negation and with class union the same way.
  private enum Builtin
    Digit      # \d
    Word       # \w
    Space      # \s
    Horizontal # \h
    Vertical   # \v
    Letter     # \p{L}
    Upper      # \p{Lu}
    Lower      # \p{Ll}
    Number     # \p{N}
    Mark       # \p{M}
  end

  private abstract class Node
  end

  # Matches the empty string. Also what a bare `(?i)` leaves behind: a flag
  # change is not an atom, which is why a quantifier after one is refused.
  private class EmptyNode < Node
  end

  private class CharNode < Node
    getter char : Char
    getter? fold : Bool

    def initialize(@char : Char, @fold : Bool)
    end
  end

  # `.`, any character except a newline.
  private class AnyNode < Node
  end

  private class ClassNode < Node
    getter members : Array(ClassData::Member)
    getter? negated : Bool
    getter? fold : Bool

    def initialize(@members : Array(ClassData::Member), @negated : Bool, @fold : Bool)
    end
  end

  private class AssertNode < Node
    getter anchor : Anchor

    def initialize(@anchor : Anchor)
    end
  end

  private class CatNode < Node
    getter items : Array(Node)

    def initialize(@items : Array(Node))
    end
  end

  private class AltNode < Node
    getter alts : Array(Node)

    def initialize(@alts : Array(Node))
    end
  end

  private class GroupNode < Node
    getter body : Node
    getter index : Int32? # nil for a non-capturing group

    def initialize(@body : Node, @index : Int32?)
    end
  end

  private class RepeatNode < Node
    getter body : Node
    getter min : Int32
    getter max : Int32? # nil means unbounded
    getter? lazy : Bool
    getter pos : Int32 # the quantifier's offset, for the expansion cap error

    def initialize(@body : Node, @min : Int32, @max : Int32?, @lazy : Bool, @pos : Int32)
    end
  end

  # A lookaround. Its body is not here: it compiles to an automaton of its own,
  # and `index` names the bitmap that automaton fills in for the whole subject.
  # `negated?` picks which way to read that one bit.
  private class LookNode < Node
    getter index : Int32
    getter? negated : Bool

    def initialize(@index : Int32, @negated : Bool)
    end
  end

  # A lookaround as the parser found it, before compilation. `ahead?` is which
  # side of the position it looks at; the direction its automaton runs is the
  # other one.
  private struct LookSpec
    getter body : Node
    getter? ahead : Bool

    def initialize(@body : Node, @ahead : Bool)
    end
  end

  # The same language read right to left, which is what turns a lookahead into a
  # backward pass. Only concatenation carries an order, so only concatenation
  # changes: an alternation's branches and a repetition's bounds mean the same
  # thing either way, and a zero-width node is a property of a position rather
  # than of a direction, which is why a nested lookaround comes through
  # untouched and still lands at the position it named. Reversing the AST rather
  # than the compiled program is what keeps this five lines instead of an edge
  # rewrite.
  protected def self.reverse(n : Node) : Node
    case n
    when CatNode    then CatNode.new(n.items.reverse.map { |item| reverse(item) })
    when AltNode    then AltNode.new(n.alts.map { |branch| reverse(branch) })
    when GroupNode  then GroupNode.new(reverse(n.body), n.index)
    when RepeatNode then RepeatNode.new(reverse(n.body), n.min, n.max, n.lazy?, n.pos)
    else                 n
    end
  end

  private class Parser
    getter group_count : Int32
    getter group_names : Hash(String, Int32)
    getter looks : Array(LookSpec)

    def initialize(source : String, ignore_case : Bool)
      @bytes = source.to_slice
      @size = source.bytesize
      @pos = 0
      @group_count = 0
      @ignore_case = ignore_case
      @group_names = {} of String => Int32
      @looks = [] of LookSpec
      # How many lookaround bodies enclose the position being parsed. Nothing
      # about matching needs it; refusing a capturing group inside one does.
      @look_depth = 0
    end

    def parse : Node
      root = parse_alternation
      # Alternation only stops early at ')', so anything left is unbalanced.
      error "unbalanced parenthesis" if @pos < @size
      root
    end

    private def parse_alternation : Node
      alts = [parse_concat]
      while peek_byte == '|'.ord
        @pos += 1
        alts << parse_concat
      end
      alts.size == 1 ? alts.first : AltNode.new(alts)
    end

    private def parse_concat : Node
      items = [] of Node
      while @pos < @size
        b = @bytes[@pos]
        break if b == '|'.ord || b == ')'.ord
        items << parse_quantified
      end
      items.size == 1 ? items.first : CatNode.new(items)
    end

    private def parse_quantified : Node
      atom = parse_atom
      quant_pos = @pos
      min = 0
      max : Int32? = nil
      case peek_byte
      when '*'.ord
        @pos += 1
        min = 0
        max = nil
      when '+'.ord
        @pos += 1
        min = 1
        max = nil
      when '?'.ord
        @pos += 1
        min = 0
        max = 1
      when '{'.ord
        if pair = try_braces
          min, max = pair
        end
      end
      # try_braces rewinds when the braces are not a quantifier, so an
      # unmoved position means no quantifier followed this atom.
      return atom if @pos == quant_pos

      if atom.is_a?(EmptyNode)
        error "quantifier does not follow a repeatable atom", quant_pos
      end

      lazy = false
      case peek_byte
      when '?'.ord
        @pos += 1
        lazy = true
      when '+'.ord
        # A possessive quantifier is a backtracking control. There is nothing to
        # control here and honouring it would be a lie, so it is refused.
        error "possessive quantifiers are not supported", @pos
      when '*'.ord
        error "quantifier does not follow a repeatable atom", @pos
      end
      RepeatNode.new(atom, min, max, lazy, quant_pos)
    end

    private def parse_atom : Node
      case peek_byte
      when '('.ord
        @pos += 1
        parse_group
      when '['.ord
        parse_class
      when '.'.ord
        @pos += 1
        AnyNode.new
      when '^'.ord
        @pos += 1
        AssertNode.new(Anchor::LineStart)
      when '$'.ord
        @pos += 1
        AssertNode.new(Anchor::LineEnd)
      when '\\'.ord
        parse_escape
      when '*'.ord, '+'.ord, '?'.ord
        error "quantifier does not follow a repeatable atom"
      when '{'.ord
        # A brace that cannot form a quantifier is a literal brace, as in RE2.
        # One that could is a quantifier with nothing to repeat.
        error "quantifier does not follow a repeatable atom" if quantifier_ahead?
        @pos += 1
        CharNode.new('{', @ignore_case)
      else
        c, width = Rx.decode(@bytes, @pos, @size)
        @pos += width
        CharNode.new(c, @ignore_case)
      end
    end

    # '(' is already consumed. Everything past `(?` that is not a group, a
    # lookaround or an `i` flag is a construct this engine refuses by design.
    private def parse_group : Node
      open = @pos - 1
      if peek_byte == '?'.ord
        @pos += 1
        case peek_byte
        when ':'.ord
          @pos += 1
          parse_group_body
        when 'i'.ord
          parse_inline_fold
        when '='.ord
          @pos += 1
          lookaround ahead: true, negated: false
        when '!'.ord
          @pos += 1
          lookaround ahead: true, negated: true
        when '<'.ord
          # `(?<` is three constructs sharing two bytes. The lookbehinds are
          # settled by the third byte; anything else opens a name.
          case peek_byte_at(1)
          when '='.ord
            @pos += 2
            lookaround ahead: false, negated: false
          when '!'.ord
            @pos += 2
            lookaround ahead: false, negated: true
          else
            @pos += 1
            named_group '>'.ord, open
          end
        when '\''.ord
          @pos += 1
          named_group '\''.ord, open
        when 'P'.ord
          case peek_byte_at(1)
          when '<'.ord
            @pos += 2
            named_group '>'.ord, open
          when '='.ord
            error "backreferences are not supported"
          when '>'.ord
            error "recursion is not supported"
          else
            error "unsupported group construct after (?"
          end
        when '>'.ord
          error "atomic groups are not supported"
        when '('.ord
          error "conditionals are not supported"
        when 'R'.ord, '&'.ord, '+'.ord
          error "recursion is not supported"
        when 'C'.ord
          error "callouts are not supported"
        else
          b = peek_byte
          error "recursion is not supported" if 0x30 <= b <= 0x39
          error "unsupported group construct after (?"
        end
      else
        capture_group nil, open
      end
    end

    # `(?=`, `(?!`, `(?<=` or `(?<!`, with the marker consumed. The body is
    # recorded only once it has been parsed, which orders the table innermost
    # first and is exactly the order the bitmaps have to be computed in.
    private def lookaround(ahead : Bool, negated : Bool) : Node
      @look_depth += 1
      body = parse_group_body
      @look_depth -= 1
      index = @looks.size
      @looks << LookSpec.new(body, ahead)
      LookNode.new(index, negated)
    end

    # `(?<name>`, `(?'name'` and `(?P<name>` all arrive here with the name's
    # first byte next and *closer* being the byte that ends it. A named group is
    # also a numbered one, numbered in source order beside the unnamed ones,
    # which is pcre2's rule and the reason `match[1]` and `match["name"]` can
    # name the same group.
    private def named_group(closer : Int32, open : Int32) : Node
      start = @pos
      while (b = peek_byte) >= 0 && name_byte?(b)
        @pos += 1
      end
      name = String.new(@bytes[start, @pos - start])
      if name.empty? || peek_byte != closer || 0x30 <= @bytes[start] <= 0x39
        error "a group name must be letters, digits or underscores and cannot start with a digit", start
      end
      @pos += 1
      capture_group name, open
    end

    private def name_byte?(b : Int32) : Bool
      b == 0x5F || 0x30 <= b <= 0x39 || 0x41 <= b <= 0x5A || 0x61 <= b <= 0x7A
    end

    # Opens a capturing group, named or not.
    private def capture_group(name : String?, open : Int32) : Node
      # iyi: a capturing group inside a lookaround would need that lookaround's
      # own sub-match, and the construction that keeps a lookaround linear never
      # runs one: it answers "does L reach this position" for every position of
      # the subject at once and never learns where L's groups fell. The only way
      # to answer that is a sub-VM at every position, which is the linear-time
      # guarantee gone (SPEC.md III.10), so it is refused rather than quietly
      # dropped. `(?:...)` inside a lookaround is unaffected.
      if @look_depth > 0
        error "a capturing group inside a lookaround assertion is not supported", open
      end
      @group_count += 1
      index = @group_count
      if name
        # pcre2 as the stdlib builds it passes PCRE2_DUPNAMES and so accepts a
        # repeated name, resolving it to the leftmost group that participated.
        # Refusing is the honest answer here: a name that stands for two groups
        # is a pattern whose author meant one of them, and guessing which is
        # worse than saying so.
        error "duplicate group name #{name.inspect}", open if @group_names.has_key?(name)
        @group_names[name] = index
      end
      GroupNode.new(parse_group_body, index)
    end

    # A flag set inside a group ends at that group's closing parenthesis, which
    # is pcre2's rule, so every group body saves and restores the fold flag.
    private def parse_group_body : Node
      saved = @ignore_case
      body = parse_alternation
      error "missing closing parenthesis" unless peek_byte == ')'.ord
      @pos += 1
      @ignore_case = saved
      body
    end

    private def parse_inline_fold : Node
      while peek_byte == 'i'.ord
        @pos += 1
      end
      terminator = peek_byte
      unless terminator == ')'.ord || terminator == ':'.ord
        # Only `i` exists here. `(?m)`, `(?s)`, `(?-i)` and friends would change
        # what anchors and `.` mean, and none of that is in the supported set.
        error "unsupported inline flag"
      end
      @pos += 1
      if terminator == ')'.ord
        @ignore_case = true
        EmptyNode.new
      else
        saved = @ignore_case
        @ignore_case = true
        body = parse_alternation
        error "missing closing parenthesis" unless peek_byte == ')'.ord
        @pos += 1
        @ignore_case = saved
        body
      end
    end

    private def parse_class : Node
      @pos += 1 # '['
      negated = false
      if peek_byte == '^'.ord
        negated = true
        @pos += 1
      end
      members = [] of ClassData::Member
      first = true
      while true
        b = peek_byte
        error "unterminated character class" if b < 0
        if b == ']'.ord && !first
          @pos += 1
          break
        end
        first = false
        item = parse_class_item
        if item.is_a?(ClassData::Member)
          members << item
          if peek_byte == '-'.ord && (nxt = peek_byte_at(1)) >= 0 && nxt != ']'.ord
            error "invalid range in character class"
          end
        else
          lo = item
          if peek_byte == '-'.ord && (nxt = peek_byte_at(1)) >= 0 && nxt != ']'.ord
            @pos += 1
            rhs = parse_class_item
            error "invalid range in character class" unless rhs.is_a?(Char)
            error "range out of order in character class" if lo > rhs
            members << ClassData::Member.range(lo, rhs)
          else
            members << ClassData::Member.range(lo, lo)
          end
        end
      end
      ClassNode.new(members, negated, @ignore_case)
    end

    # A class member is either a built-in set or a single character; a character
    # may then become the low end of a range.
    private def parse_class_item : ClassData::Member | Char
      if peek_byte == '\\'.ord
        @pos += 1
        b = peek_byte
        error "trailing backslash in character class" if b < 0
        case b
        when 'n'.ord then @pos += 1; '\n'
        when 't'.ord then @pos += 1; '\t'
        when 'r'.ord then @pos += 1; '\r'
        when 'f'.ord then @pos += 1; '\f'
        when 'v'.ord then @pos += 1; ClassData::Member.builtin(Builtin::Vertical, false)
        when 'V'.ord then @pos += 1; ClassData::Member.builtin(Builtin::Vertical, true)
        when '0'.ord
          @pos += 1
          octal_escape
        when 'x'.ord
          @pos += 1
          hex_escape
        when 'b'.ord
          # Inside a class `\b` is a backspace, as in pcre2. The word boundary
          # sense has no meaning where a single character is expected.
          @pos += 1
          8.unsafe_chr
        when 'd'.ord then @pos += 1; ClassData::Member.builtin(Builtin::Digit, false)
        when 'D'.ord then @pos += 1; ClassData::Member.builtin(Builtin::Digit, true)
        when 'w'.ord then @pos += 1; ClassData::Member.builtin(Builtin::Word, false)
        when 'W'.ord then @pos += 1; ClassData::Member.builtin(Builtin::Word, true)
        when 's'.ord then @pos += 1; ClassData::Member.builtin(Builtin::Space, false)
        when 'S'.ord then @pos += 1; ClassData::Member.builtin(Builtin::Space, true)
        when 'h'.ord then @pos += 1; ClassData::Member.builtin(Builtin::Horizontal, false)
        when 'H'.ord then @pos += 1; ClassData::Member.builtin(Builtin::Horizontal, true)
        when 'p'.ord
          @pos += 1
          ClassData::Member.builtin(property_kind, false)
        when 'P'.ord
          @pos += 1
          ClassData::Member.builtin(property_kind, true)
        else
          c, width = Rx.decode(@bytes, @pos, @size)
          error "unsupported escape \\#{c} in character class" if c.ascii_alphanumeric?
          @pos += width
          c
        end
      else
        c, width = Rx.decode(@bytes, @pos, @size)
        @pos += width
        c
      end
    end

    private def parse_escape : Node
      @pos += 1 # backslash
      b = peek_byte
      error "trailing backslash" if b < 0
      case b
      when 'n'.ord then @pos += 1; CharNode.new('\n', @ignore_case)
      when 't'.ord then @pos += 1; CharNode.new('\t', @ignore_case)
      when 'r'.ord then @pos += 1; CharNode.new('\r', @ignore_case)
      when 'f'.ord then @pos += 1; CharNode.new('\f', @ignore_case)
      when 'v'.ord then @pos += 1; builtin_class Builtin::Vertical, false
      when 'V'.ord then @pos += 1; builtin_class Builtin::Vertical, true
      when '0'.ord
        @pos += 1
        CharNode.new(octal_escape, @ignore_case)
      when 'x'.ord
        @pos += 1
        CharNode.new(hex_escape, @ignore_case)
      when 'b'.ord then @pos += 1; AssertNode.new(Anchor::WordBorder)
      when 'B'.ord then @pos += 1; AssertNode.new(Anchor::NotWordBorder)
      when 'A'.ord then @pos += 1; AssertNode.new(Anchor::TextStart)
      when 'z'.ord then @pos += 1; AssertNode.new(Anchor::TextEnd)
      when 'Z'.ord then @pos += 1; AssertNode.new(Anchor::TextEndNl)
      when 'd'.ord then @pos += 1; builtin_class Builtin::Digit, false
      when 'D'.ord then @pos += 1; builtin_class Builtin::Digit, true
      when 'w'.ord then @pos += 1; builtin_class Builtin::Word, false
      when 'W'.ord then @pos += 1; builtin_class Builtin::Word, true
      when 's'.ord then @pos += 1; builtin_class Builtin::Space, false
      when 'S'.ord then @pos += 1; builtin_class Builtin::Space, true
      when 'h'.ord then @pos += 1; builtin_class Builtin::Horizontal, false
      when 'H'.ord then @pos += 1; builtin_class Builtin::Horizontal, true
      when 0x31..0x39
        # A backreference is the one construct that makes matching superlinear.
        # SPEC.md III.10 trades it away; saying so is better than approximating.
        error "backreferences are not supported"
      when 'p'.ord
        @pos += 1
        builtin_class property_kind, false
      when 'P'.ord
        @pos += 1
        builtin_class property_kind, true
      when 'G'.ord
        error "\\G is not supported"
      when 'K'.ord
        error "\\K is not supported"
      else
        c, width = Rx.decode(@bytes, @pos, @size)
        error "unsupported escape \\#{c}" if c.ascii_alphanumeric?
        @pos += width
        CharNode.new(c, @ignore_case)
      end
    end

    private def builtin_class(kind : Builtin, negated : Bool) : Node
      ClassNode.new([ClassData::Member.builtin(kind, negated)], false, @ignore_case)
    end

    # `\0` takes up to two further octal digits, matching pcre2.
    private def octal_escape : Char
      value = 0
      2.times do
        b = peek_byte
        break if b < 0x30 || b > 0x37
        value = value * 8 + (b - 0x30)
        @pos += 1
      end
      value.unsafe_chr
    end

    # `\xHH`, and `\x{...}` for anything a two digit escape cannot name.
    private def hex_escape : Char
      return braced_hex_escape if peek_byte == '{'.ord
      value = 0
      count = 0
      while count < 2
        digit = hex_value(peek_byte)
        break if digit < 0
        value = value * 16 + digit
        @pos += 1
        count += 1
      end
      error "malformed \\x escape, expected \\xHH or \\x{...}" if count == 0
      value.unsafe_chr
    end

    # `\x{...}`, pcre2's arbitrary codepoint escape. Any number of digits is
    # accepted, so leading zeroes cost nothing, and the ceiling is checked once
    # per digit: a long run of digits would overflow Int32 long before a check
    # made only after the loop could compare it.
    #
    # A surrogate is refused because pcre2 in UTF mode refuses one too, and
    # accepting it would put a codepoint in the program that no UTF-8 subject can
    # ever produce, so the two engines stay in agreement by refusing together.
    private def braced_hex_escape : Char
      open = @pos
      @pos += 1 # '{'
      value = 0
      count = 0
      while (digit = hex_value(peek_byte)) >= 0
        value = value * 16 + digit
        error "codepoint in \\x{...} is above U+10FFFF", open if value > 0x10FFFF
        @pos += 1
        count += 1
      end
      error "no digits in \\x{...}", open if count == 0
      error "missing closing brace in \\x{...}", open unless peek_byte == '}'.ord
      @pos += 1
      error "codepoint in \\x{...} is a surrogate", open if 0xD800 <= value <= 0xDFFF
      value.unsafe_chr
    end

    # `\p{Name}` and its short form `\pN`, and `\P` for either read the other
    # way. pcre2 knows every general category and every script; only the five a
    # public stdlib predicate answers EXACTLY are accepted here, because a
    # property that quietly means something a little different from pcre2 is
    # worse than one that is refused. \p{Nd} is the case in point: the stdlib
    # exposes numbers only as Nd plus Nl plus No, so it is refused rather than
    # approximated, and `\d` carries the same reading for the same reason.
    private def property_kind : Builtin
      start = @pos
      if peek_byte == '{'.ord
        @pos += 1
        from = @pos
        while (b = peek_byte) >= 0 && b != '}'.ord
          @pos += 1
        end
        error "missing closing brace in \\p{...}", start if peek_byte < 0
        name = String.new(@bytes[from, @pos - from])
        @pos += 1 # '}'
      else
        b = peek_byte
        # The short form takes exactly one ASCII letter, so `[\p]` reads as a
        # malformed property rather than as a property named ']'.
        error "malformed \\p escape, expected \\p{Name} or \\pN", start unless ascii_letter_byte?(b)
        name = b.unsafe_chr.to_s
        @pos += 1
      end
      case name
      when "L"  then Builtin::Letter
      when "Lu" then Builtin::Upper
      when "Ll" then Builtin::Lower
      when "N"  then Builtin::Number
      when "M"  then Builtin::Mark
      else
        error "unsupported unicode property #{name.inspect}, only L, Lu, Ll, N and M are supported", start
      end
    end

    private def ascii_letter_byte?(b : Int32) : Bool
      0x41 <= b <= 0x5A || 0x61 <= b <= 0x7A
    end

    private def hex_value(b : Int32) : Int32
      case b
      when 0x30..0x39 then b - 0x30
      when 0x41..0x46 then b - 0x37
      when 0x61..0x66 then b - 0x57
      else                 -1
      end
    end

    # Reads `{n}`, `{n,}`, `{n,m}` or `{,m}` and rewinds when the braces are
    # something else, which leaves the '{' to be parsed as a literal. pcre2 reads
    # `{,m}` as `{0,m}` and `{,}` as literal text, so this follows it there
    # rather than taking RE2's stricter reading and refusing a pattern pcre2
    # compiles.
    private def try_braces : {Int32, Int32?}?
      saved = @pos
      @pos += 1
      lower = parse_digits
      if peek_byte == ','.ord
        @pos += 1
        upper = parse_digits
        if peek_byte == '}'.ord && (lower >= 0 || upper >= 0)
          @pos += 1
          min = lower < 0 ? 0 : lower
          max = upper < 0 ? nil : upper
          error "numbers out of order in {} quantifier" if max && max < min
          check_repeat_cap min
          check_repeat_cap max if max
          return {min, max}
        end
      elsif lower >= 0 && peek_byte == '}'.ord
        @pos += 1
        check_repeat_cap lower
        return {lower, lower}
      end
      @pos = saved
      nil
    end

    private def quantifier_ahead? : Bool
      i = skip_digits(@pos + 1)
      saw_lower = i > @pos + 1
      saw_upper = false
      if i < @size && @bytes[i] == ','.ord
        j = skip_digits(i + 1)
        saw_upper = j > i + 1
        i = j
      end
      (saw_lower || saw_upper) && i < @size && @bytes[i] == '}'.ord
    end

    private def skip_digits(i : Int32) : Int32
      while i < @size && 0x30 <= @bytes[i] <= 0x39
        i += 1
      end
      i
    end

    private def parse_digits : Int32
      value = 0
      count = 0
      while 0x30 <= (b = peek_byte) <= 0x39
        value = value * 10 + (b - 0x30)
        return 1_000_000 if value >= 1_000_000
        count += 1
        @pos += 1
      end
      count == 0 ? -1 : value
    end

    private def check_repeat_cap(count : Int32) : Nil
      if count > MAX_REPEAT
        error "repeat count #{count} exceeds the #{MAX_REPEAT} limit"
      end
    end

    private def peek_byte : Int32
      @pos < @size ? @bytes[@pos].to_i32 : -1
    end

    private def peek_byte_at(offset : Int32) : Int32
      i = @pos + offset
      i < @size ? @bytes[i].to_i32 : -1
    end

    private def error(message : String, pos : Int32 = @pos) : NoReturn
      raise SyntaxError.new(message, pos)
    end
  end

  # ---------------------------------------------------------------------------
  # Part 2: the compiler, AST to a Thompson NFA program.
  #
  # Straight-line code with Split for choice and Save for capture slots. Split's
  # `a` target is the preferred branch: leftmost-first alternation and greed both
  # come out of which target is explored first, never from scores on states.
  # ---------------------------------------------------------------------------

  private struct Inst
    enum Kind
      Char     # consume one character equal to a's codepoint
      Class    # consume one character inside classes[a]
      Any      # consume one character that is not a newline
      Split    # fork: a preferred, b deferred
      Jmp      # continue at a
      Again    # a loop's back edge: a is the loop's split, b is the loop's exit
      Save     # slots[a] = current position
      Match    # accept
      Bol      # ^
      Eol      # $
      Bot      # \A
      Eot      # \z
      EotNl    # \Z
      WordB    # \b
      NotWordB # \B
      Look     # a lookaround: a names the assertion, b is 1 for a negative form
    end

    getter kind : Kind
    property a : Int32
    property b : Int32
    getter? fold : Bool

    def initialize(@kind : Kind, @a : Int32 = 0, @b : Int32 = 0, @fold : Bool = false)
    end
  end

  # A character class: a union of members with one overall negation, so `[^\d_]`
  # is the negation of a two member union rather than a rewritten set.
  private struct ClassData
    struct Member
      getter lo : Char
      getter hi : Char
      getter builtin : Builtin?
      getter? negated : Bool

      def initialize(@lo : Char, @hi : Char, @builtin : Builtin?, @negated : Bool)
      end

      def self.range(lo : Char, hi : Char) : Member
        new(lo, hi, nil, false)
      end

      def self.builtin(kind : Builtin, negated : Bool) : Member
        new('\0', '\0', kind, negated)
      end
    end

    getter members : Array(Member)
    getter? negated : Bool
    getter? fold : Bool

    # Whether any member names a character above ASCII. Computed once here
    # because it decides which of the two fold paths below a subject takes, and
    # a class is immutable after compilation.
    @non_ascii_members : Bool

    def initialize(@members : Array(Member), @negated : Bool, @fold : Bool)
      @non_ascii_members = @members.any? { |m| m.builtin.nil? && m.hi.ord > 0x7F }
    end

    def matches?(c : Char) : Bool
      hit = @members.any? { |m| hit?(m, c) }
      hit = fold_hit?(c) if !hit && @fold
      hit != @negated
    end

    # iyi: fold the SUBJECT, never the class. A folded range cannot be tested by
    # folding its endpoints, because folding is not monotonic: [À-Þ] folds to a
    # set that is not a range, so the only sound test is whether some character
    # caseless-equal to the subject falls inside the range as written. That keeps
    # `[a-z]` under (?i) at one range test per candidate rather than an expanded
    # class, which is what holds the linear guarantee.
    #
    # The candidates are the subject's fold, its simple upcase, its simple
    # downcase, and the upcase of its fold, and each is kept only when it folds
    # to what the subject folds to. That filter is load-bearing: without it
    # simple upcase would pair ı (U+0131) with I and simple downcase would pair
    # İ (U+0130) with i, and pcre2 pairs neither, so `(?i)[a-z]` would match İ
    # here and not there. The fold's upcase is the one that looks redundant and
    # is not: the KELVIN SIGN (U+212A) is already uppercase, so its own upcase is
    # itself and only its fold's upcase reaches the ASCII K that `(?i)[A-Z]`
    # holds. The OHM SIGN (U+2126) reaches Ω the same way.
    #
    # A single character member gets one further test, fold against fold, which
    # is the only way `[É]` reaches é and `[ſ]` reaches s: neither is any case
    # mapping of the other.
    #
    # What this cannot reach is a character sitting INSIDE a range that no case
    # mapping of the subject lands on, so `(?i)[Ā-ſ]` misses s where pcre2 finds
    # it through ſ. Closing that needs the reverse of the fold, which is a table.
    private def fold_hit?(c : Char) : Bool
      # An ASCII subject against an all-ASCII class: the equivalence class is the
      # letter and its one other case, so arithmetic answers it and nothing above
      # ASCII can be reached anyway.
      if !@non_ascii_members && c.ascii?
        return false unless c.ascii_letter?
        other = c.ascii_uppercase? ? c + 32 : c - 32
        return @members.any? { |m| hit?(m, other) }
      end

      folded = Rx.fold_char(c)
      {folded, c.upcase, c.downcase, folded.upcase}.each do |candidate|
        next if candidate == c
        next unless Rx.fold_char(candidate) == folded
        return true if @members.any? { |m| hit?(m, candidate) }
      end
      @members.any? { |m| m.builtin.nil? && m.lo == m.hi && Rx.fold_char(m.lo) == folded }
    end

    private def hit?(m : Member, c : Char) : Bool
      if kind = m.builtin
        # Exhaustive on purpose: `case ... in` makes a Builtin added without a
        # reading here a compile error rather than a set that quietly answers
        # like whichever branch the else happened to be.
        inside = case kind
                 in .digit?      then c.number?
                 in .word?       then Rx.word_char?(c)
                 in .space?      then Rx.space_char?(c)
                 in .horizontal? then Rx.horizontal_space_char?(c)
                 in .vertical?   then Rx.vertical_space_char?(c)
                 in .letter?     then c.letter?
                 in .upper?      then c.uppercase?
                 in .lower?      then c.lowercase?
                 in .number?     then c.number?
                 in .mark?       then c.mark?
                 end
        inside != m.negated?
      else
        m.lo <= c <= m.hi
      end
    end
  end

  # The instruction cap is one budget for the whole pattern, the main program and
  # every assertion's program together, because an expansion split between them
  # is still one expansion.
  private class Budget
    property spent : Int32 = 0
  end

  private class Compiler
    def initialize(@budget : Budget)
      @prog = [] of Inst
      @classes = [] of ClassData
      @repeat_pos = 0
    end

    def compile(root : Node) : {Array(Inst), Array(ClassData)}
      emit Inst::Kind::Save, 0
      node root
      emit Inst::Kind::Save, 1
      emit Inst::Kind::Match
      {@prog, @classes}
    end

    # An assertion's program answers membership and nothing else, so it carries
    # no capture slots: the pre-pass that runs it has no thread to hang them on.
    def compile_assertion(root : Node) : {Array(Inst), Array(ClassData)}
      node root
      emit Inst::Kind::Match
      {@prog, @classes}
    end

    private def node(n : Node)
      case n
      when CatNode
        n.items.each { |item| node item }
      when CharNode
        emit Inst::Kind::Char, n.char.ord, fold: n.fold?
      when AnyNode
        emit Inst::Kind::Any
      when ClassNode
        index = @classes.size
        @classes << ClassData.new(n.members, n.negated?, n.fold?)
        emit Inst::Kind::Class, index
      when AssertNode
        emit anchor_kind(n.anchor)
      when LookNode
        emit Inst::Kind::Look, n.index, n.negated? ? 1 : 0
      when GroupNode
        # Two slots per group, and slots 0 and 1 belong to the whole match.
        if index = n.index
          emit Inst::Kind::Save, index * 2
          node n.body
          emit Inst::Kind::Save, index * 2 + 1
        else
          node n.body
        end
      when AltNode
        alternation(n.alts) { |branch| node branch }
      when RepeatNode
        repeat n
      else
        # EmptyNode: no instructions, it already matches.
      end
    end

    private def alternation(branches : Array(Node), &compile : Node ->)
      jumps = [] of Int32
      last = branches.size - 1
      branches.each_with_index do |branch, i|
        if i < last
          split = emit Inst::Kind::Split
          set_a split, @prog.size # preferred: this branch, in source order
          compile.call branch
          jumps << emit(Inst::Kind::Jmp)
          set_b split, @prog.size # deferred: the branches after it
        else
          compile.call branch
        end
      end
      jumps.each { |j| set_a j, @prog.size }
    end

    # Can this expression match the empty string? An unbounded loop over a body
    # that can decides whether the empty tail round below is compiled.
    private def nullable?(n : Node) : Bool
      case n
      when CharNode, AnyNode, ClassNode then false
      when CatNode                      then n.items.all? { |item| nullable?(item) }
      when AltNode                      then n.alts.any? { |branch| nullable?(branch) }
      when GroupNode                    then nullable?(n.body)
      when RepeatNode                   then n.min == 0 || nullable?(n.body)
      else                                   true # EmptyNode, the anchors and the lookarounds
      end
    end

    # Emits only the paths through `n` that consume nothing, assertions included.
    # Never called on an expression that cannot match empty, which is why the
    # consuming nodes are unreachable here.
    private def epsilon(n : Node)
      case n
      when CatNode
        n.items.each { |item| epsilon item }
      when AltNode
        alternation(n.alts.select { |branch| nullable?(branch) }) { |branch| epsilon branch }
      when GroupNode
        if index = n.index
          emit Inst::Kind::Save, index * 2
          epsilon n.body
          emit Inst::Kind::Save, index * 2 + 1
        else
          epsilon n.body
        end
      when RepeatNode
        if n.min == 0
          epsilon n.body if nullable?(n.body)
        else
          n.min.times { epsilon n.body }
        end
      when AssertNode
        emit anchor_kind(n.anchor)
      when LookNode
        emit Inst::Kind::Look, n.index, n.negated? ? 1 : 0
      else
        # EmptyNode: nothing to emit, which is the whole point of it.
      end
    end

    # pcre2 runs one more round of an unbounded loop whose body can match empty,
    # stops because that round consumed nothing, and reports that round's
    # captures: `(a*)*` over "aaa" gives group 1 "" at byte 3, not "aaa". The loop
    # cannot produce the round here, because the machine admits each program
    # counter once per position and the earlier round already holds the ones the
    # body needs. Compiling the body's empty path once more, after the loop, puts
    # the round back without a second thread at any counter, so captures agree
    # while the machine stays linear (SPEC.md III.10).
    private def empty_tail_round(n : RepeatNode)
      split = emit Inst::Kind::Split
      if n.lazy?
        set_b split, @prog.size
        epsilon n.body
        set_a split, @prog.size # lazy would rather not take the round
      else
        set_a split, @prog.size # greedy takes it, as pcre2 does
        epsilon n.body
        set_b split, @prog.size
      end
    end

    private def repeat(n : RepeatNode)
      saved_pos = @repeat_pos
      @repeat_pos = n.pos
      min = n.min
      max = n.max
      if max == min
        min.times { node n.body }
      elsif max.nil?
        if min == 1
          plus n
        else
          min.times { node n.body }
          star n
        end
        empty_tail_round n if nullable?(n.body)
      else
        min.times { node n.body }
        bounded n, max - min
      end
      @repeat_pos = saved_pos
    end

    private def star(n : RepeatNode)
      split = emit Inst::Kind::Split
      if n.lazy?
        set_b split, @prog.size
        node n.body
        back = emit Inst::Kind::Again, split
        set_a split, @prog.size # lazy prefers leaving the loop
      else
        set_a split, @prog.size # greedy prefers another turn through the body
        node n.body
        back = emit Inst::Kind::Again, split
        set_b split, @prog.size
      end
      # A turn that consumed nothing must not re-enter the body, and it must not
      # die either: it continues at the exit, which is the next instruction and
      # is where empty_tail_round lands when the body is nullable. That keeps the
      # empty turn at the priority pcre2 gives it, inside the turn's own subtree
      # rather than behind the loop's exit branch, which is what `(a*?)*` needs.
      set_b back, @prog.size
    end

    private def plus(n : RepeatNode)
      # One mandatory copy with the loop after it, rather than compiling `e e*`
      # and doubling the body.
      body = @prog.size
      node n.body
      split = emit Inst::Kind::Split
      if n.lazy?
        set_a split, @prog.size
        set_b split, body
      else
        set_a split, body
        set_b split, @prog.size
      end
    end

    private def bounded(n : RepeatNode, count : Int32)
      # `{n,m}` becomes n copies and then m-n nested optionals. Nested, not a
      # flat run of `e?`, so leaving early skips every remaining copy at once.
      return if count <= 0
      split = emit Inst::Kind::Split
      if n.lazy?
        set_b split, @prog.size
        node n.body
        bounded n, count - 1
        set_a split, @prog.size
      else
        set_a split, @prog.size
        node n.body
        bounded n, count - 1
        set_b split, @prog.size
      end
    end

    private def anchor_kind(anchor : Anchor) : Inst::Kind
      case anchor
      when .line_start?  then Inst::Kind::Bol
      when .line_end?    then Inst::Kind::Eol
      when .text_start?  then Inst::Kind::Bot
      when .text_end?    then Inst::Kind::Eot
      when .text_end_nl? then Inst::Kind::EotNl
      when .word_border? then Inst::Kind::WordB
      else                    Inst::Kind::NotWordB
      end
    end

    private def emit(kind : Inst::Kind, a : Int32 = 0, b : Int32 = 0, fold : Bool = false) : Int32
      # The cap turns expansion bombs like ((a{1000}){1000}) into a refusal at
      # the offending quantifier instead of a program nothing can hold.
      if @budget.spent >= MAX_PROG
        raise SyntaxError.new("compiled pattern exceeds #{MAX_PROG} instructions", @repeat_pos)
      end
      @budget.spent += 1
      @prog << Inst.new(kind, a, b, fold)
      @prog.size - 1
    end

    private def set_a(i : Int32, v : Int32) : Nil
      inst = @prog[i]
      inst.a = v
      @prog[i] = inst
    end

    private def set_b(i : Int32, v : Int32) : Nil
      inst = @prog[i]
      inst.b = v
      @prog[i] = inst
    end
  end

  # ---------------------------------------------------------------------------
  # Part 3: the Pike VM, running the program while tracking capture slots.
  #
  # One thread list per subject position, threads held in priority order. Two
  # rules produce pcre2's answers without pcre2's worst case:
  #   a Split adds its preferred branch first, so list order is the order a
  #   backtracking engine would explore, and
  #   a pc joins a position's list at most once, so work per position is bounded
  #   by the program and total work is linear in the subject.
  # ---------------------------------------------------------------------------

  # Character equality with the pattern's fold flag applied. Module level rather
  # than private to the machine, because the assertion pre-pass below runs the
  # same instructions and must read them the same way.
  #
  # Both sides are folded rather than one side's other case tried, because case
  # is not a pair past ASCII: s, S and ſ are one equivalence class, and so are
  # σ, ς and Σ. Folding maps every member of a class to the same representative,
  # so one comparison answers the whole class.
  protected def self.char_eq?(got : Char, want : Char, fold : Bool) : Bool
    return true if got == want
    return false unless fold
    fold_char(got) == fold_char(want)
  end

  # Simple case folding, which is what pcre2 compares under PCRE2_CASELESS.
  # `Char#downcase(Fold)` is the stdlib's public spelling of it and needs no
  # tables here. ASCII is answered arithmetically because it is the overwhelming
  # majority of what the compiler's own patterns ever see, and A-Z to a-z is one
  # bit.
  #
  # One documented gap, and it is the stdlib's: a character whose FULL folding is
  # several characters is returned unchanged, so ẞ (U+1E9E) does not fold to ß
  # the way pcre2's simple folding pairs them. `(?i)ß` therefore misses ẞ here.
  # Reaching it with an extra downcase comparison would close that one pair and
  # open others, because simple lowercase is not symmetric: it would also pair
  # İ (U+0130) with i, which pcre2 refuses to do.
  protected def self.fold_char(c : Char) : Char
    code = c.ord
    return (code | 0x20).unsafe_chr if 0x41 <= code <= 0x5A
    return c if code < 0x80
    c.downcase(Unicode::CaseOptions::Fold)
  end

  # The zero-width anchors, read at byte *pos*. Shared for the same reason, so a
  # `^` inside a lookaround means exactly what it means outside one.
  protected def self.anchor_holds?(kind : Inst::Kind, bytes : Bytes, pos : Int32, size : Int32) : Bool
    case kind
    when .bol?, .bot?    then pos == 0
    when .eol?, .eot_nl? then pos == size || (pos + 1 == size && bytes[pos] == 0x0A)
    when .eot?           then pos == size
    when .word_b?        then word_before?(bytes, pos) != word_at?(bytes, pos, size)
    else                      word_before?(bytes, pos) == word_at?(bytes, pos, size)
    end
  end

  # Reads one assertion's precomputed answer at *pos*. `a` names the assertion
  # and `b` is 1 for the negative forms, which share the positive form's bitmap
  # and complement it here: "L does not start here" is the negation of "L starts
  # here", so one automaton answers both readings.
  protected def self.look_holds?(looks : LookMaps, inst : Inst, pos : Int32) : Bool
    held = looks[inst.a][pos]
    inst.b == 1 ? !held : held
  end

  # `\b` compares the word-ness of the characters either side of the position,
  # and the ends of the subject count as non-word, so `\bdog\b` matches "dog"
  # standing alone.
  protected def self.word_at?(bytes : Bytes, pos : Int32, size : Int32) : Bool
    return false unless pos < size
    c, _ = decode(bytes, pos, size)
    word_char? c
  end

  protected def self.word_before?(bytes : Bytes, pos : Int32) : Bool
    return false unless pos > 0
    i = pos - 1
    # Walk back over UTF-8 continuation bytes to the character's first byte.
    while i > 0 && (bytes[i] & 0xC0) == 0x80
      i -= 1
    end
    c, _ = decode(bytes, i, pos)
    word_char? c
  end

  private struct Thread
    getter pc : Int32
    getter slots : Array(Int32)

    def initialize(@pc : Int32, @slots : Array(Int32))
    end
  end

  private class VM
    def initialize(@prog : Array(Inst), @classes : Array(ClassData), @group_count : Int32, @looks : LookMaps)
      @marks = Array(Int32).new(@prog.size, 0)
      @stamp = 0
      @stack = Array({Int32, Array(Int32)}).new
    end

    # Returns the winning capture slots, or nil when nothing matched.
    def run(subject : String, start : Int32) : Array(Int32)?
      bytes = subject.to_slice
      size = bytes.size
      # Never mutated: Save copies before writing, so every restart can share it.
      initial = Array(Int32).new((@group_count + 1) * 2, -1)

      clist = Array(Thread).new
      nlist = Array(Thread).new
      best : Array(Int32)? = nil

      @stamp += 1
      pos = start
      while pos <= size
        # Unanchored search without a `.*?` prefix: seed one start thread per
        # position, appended behind every survivor so an earlier start always
        # outranks a later one. @stamp still names this position's list, so a
        # seed duplicating a survivor's pc is dropped by the same dedup. Nothing
        # is seeded once a match exists, since a later start could only lose.
        # Seeding at the top of the step rather than the end of the previous one
        # matters for a pattern that opens with an assertion: `\Bo` leaves the
        # list empty at position 0 and still has to be tried further along.
        add_thread(clist, 0, initial, pos, bytes, size) unless best
        break if clist.empty? && best

        if pos < size
          c, width = Rx.decode(bytes, pos, size)
        else
          c = nil
          width = 1
        end

        nlist.clear
        @stamp += 1
        cut = false
        i = 0
        while i < clist.size && !cut
          thread = clist[i]
          inst = @prog[thread.pc]
          case inst.kind
          when .char?
            if c && Rx.char_eq?(c, inst.a.unsafe_chr, inst.fold?)
              add_thread nlist, thread.pc + 1, thread.slots, pos + width, bytes, size
            end
          when .class?
            if c && @classes[inst.a].matches?(c)
              add_thread nlist, thread.pc + 1, thread.slots, pos + width, bytes, size
            end
          when .any?
            if c && c != '\n'
              add_thread nlist, thread.pc + 1, thread.slots, pos + width, bytes, size
            end
          else
            # Match. Record it and abandon the rest of this list: those threads
            # are lower priority, so no continuation of theirs can win. Threads
            # already carried forward are higher priority and may still improve
            # on this, which is how /a|ab/ keeps "a" while /ac|a/ takes "ac".
            best = thread.slots.dup
            cut = true
          end
          i += 1
        end

        clist, nlist = nlist, clist
        pos += width
      end
      best
    end

    # Follows control flow eagerly so the step loop only ever sees consumers and
    # Match. Iterative with an explicit stack rather than recursive: a program
    # near the instruction cap can be one long chain of splits, and recursion
    # there would overflow instead of matching.
    private def add_thread(list : Array(Thread), pc : Int32, slots : Array(Int32), pos : Int32, bytes : Bytes, size : Int32) : Nil
      stack = @stack
      stack.clear
      stack.push({pc, slots})
      while entry = stack.pop?
        pc, slots = entry
        next if @marks[pc] == @stamp
        @marks[pc] = @stamp
        inst = @prog[pc]
        case inst.kind
        when .jmp?
          stack.push({inst.a, slots})
        when .again?
          # A loop's back edge. When the loop's split was already expanded at this
          # position, this turn consumed nothing, so re-entering the body could
          # not terminate: continue at the exit instead of dropping the thread.
          # pcre2 ends a loop on a turn that consumed nothing in the same place,
          # which is why the priority comes out the same.
          stack.push({@marks[inst.a] == @stamp ? inst.b : inst.a, slots})
        when .split?
          # Push the deferred branch first so the preferred branch pops first
          # and reaches the list first. Stack order is the priority order.
          stack.push({inst.b, slots})
          stack.push({inst.a, slots})
        when .save?
          # iyi: copy at the point of mutation. The alternative, copying on every
          # Split as the classic Pike VM does, isolates the same writes but
          # allocates per branch instead of per capture and would force a fresh
          # slot array for every restart.
          slots = slots.dup
          slots[inst.a] = pos
          stack.push({pc + 1, slots})
        when .bol?, .bot?, .eol?, .eot_nl?, .eot?, .word_b?, .not_word_b?
          stack.push({pc + 1, slots}) if Rx.anchor_holds?(inst.kind, bytes, pos, size)
        when .look?
          # A lookaround is one bit read out of a table computed for this subject
          # before the match started, so it costs what `^` costs and sits in the
          # same place: a filter inside the closure, leaving stack order alone
          # and therefore leaving leftmost-first alone.
          stack.push({pc + 1, slots}) if Rx.look_holds?(@looks, inst, pos)
        else
          list << Thread.new(pc, slots)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Part 4: lookaround assertions.
  #
  # `(?=L)`, `(?!L)`, `(?<=L)` and `(?<!L)` are not sub-matches here. A
  # lookaround over a regular inner pattern is itself a regular property of a
  # position, so it can be answered for every position of the subject at once,
  # in one pass, before the main match starts:
  #
  #   `(?<=L)` holds at i exactly when the text ending at i is in `Σ* L`. An NFA
  #   for L, seeded at every position so the `Σ*` needs no instructions of its
  #   own, run forward over the subject once, accepting at i, answers it for
  #   every i together. A variable length L costs the same as a fixed one, which
  #   is strictly more than pcre2 offers.
  #
  #   `(?=L)` holds at i exactly when the text starting at i is in `L Σ*`, which
  #   is the same statement read backwards: reverse L, seed at every position,
  #   run backward over the subject once.
  #
  # The negative forms share their positive form's bitmap and complement it at
  # the test site, so `(?!L)` builds no automaton of its own.
  #
  # Nesting works because an inner assertion's answer depends only on the
  # subject, never on the outer match: bitmaps are computed innermost first and
  # an inner one is already a finished table by the time the outer one runs. The
  # parser records an assertion only after parsing its body, which puts the
  # table in that order to begin with.
  #
  # Cost is one state set stepped per character per assertion, O(states) each,
  # so an assertion is O(1) amortised per input character. Running a sub-VM at
  # every start position, which is how a backtracking engine does this, is the
  # construction that would cost the linear-time guarantee (SPEC.md III.10).
  # ---------------------------------------------------------------------------

  # One compiled assertion. `backward?` is the direction its automaton runs, not
  # the direction it looks: a lookahead is a reversed pattern run backward.
  private struct Assertion
    getter prog : Array(Inst)
    getter classes : Array(ClassData)
    getter? backward : Bool

    def initialize(@prog : Array(Inst), @classes : Array(ClassData), @backward : Bool)
    end
  end

  # Every assertion's bitmap for *subject*, in table order, which is innermost
  # first. Once per subject, never once per start offset, so sweeping a subject
  # stays linear in it.
  protected def self.look_maps(assertions : Array(Assertion), subject : String) : LookMaps
    maps = LookMaps.new(assertions.size)
    return maps if assertions.empty?
    bytes = subject.to_slice
    size = bytes.size
    bounds = char_bounds(bytes, size)
    assertions.each do |assertion|
      runner = LookRunner.new(assertion.prog, assertion.classes)
      maps << runner.run(bytes, size, bounds, assertion.backward?, maps)
    end
    maps
  end

  # Every character boundary in the subject, `size` included, so the pre-pass can
  # walk characters in either direction. Built once and shared by every
  # assertion. The walk starts at byte 0, which is where the machine's own walk
  # starts, so the two visit the same positions for any start offset that sits on
  # a character. A byte inside a character is not a position in the subject and
  # neither engine defines matching from one; pcre2 rejects the offset outright.
  private def self.char_bounds(bytes : Bytes, size : Int32) : Array(Int32)
    bounds = [] of Int32
    pos = 0
    while pos < size
      bounds << pos
      _, width = decode(bytes, pos, size)
      pos += width
    end
    bounds << size
    bounds
  end

  # Runs one assertion's program over the whole subject and answers one bit per
  # byte position. No capture tracking and no thread priority: the question is
  # membership, so a plain state set is enough and a position's work is bounded
  # by the program rather than by the subject.
  private class LookRunner
    def initialize(@prog : Array(Inst), @classes : Array(ClassData))
      @marks = Array(Int32).new(@prog.size, 0)
      @stamp = 0
      @stack = Array(Int32).new
      @matched = false
    end

    def run(bytes : Bytes, size : Int32, bounds : Array(Int32), backward : Bool, looks : LookMaps) : Array(Bool)
      holds = Array(Bool).new(size + 1, false)
      live = [] of Int32
      spare = [] of Int32
      last = bounds.size - 1
      index = backward ? last : 0

      @stamp += 1
      @matched = false
      add live, bounds[index], bytes, size, looks
      holds[bounds[index]] = @matched

      while backward ? index > 0 : index < last
        # The character this step crosses, which starts at the lower of the two
        # boundaries whichever way we are walking.
        c, _ = Rx.decode(bytes, backward ? bounds[index - 1] : bounds[index], size)
        index += backward ? -1 : 1
        target = bounds[index]

        spare.clear
        @stamp += 1
        @matched = false
        live.each do |pc|
          inst = @prog[pc]
          consumed = case inst.kind
                     when .char?  then Rx.char_eq?(c, inst.a.unsafe_chr, inst.fold?)
                     when .class? then @classes[inst.a].matches?(c)
                     else              c != '\n' # Any, which never crosses a newline
                     end
          follow spare, pc + 1, target, bytes, size, looks if consumed
        end
        add spare, target, bytes, size, looks
        holds[target] = @matched
        live, spare = spare, live
      end
      holds
    end

    # Seeds the program's first instruction at *pos*. This is the `Σ*` prefix
    # both constructions need, spelled as an unanchored search instead of as
    # instructions, which is the same automaton for less program.
    private def add(list : Array(Int32), pos : Int32, bytes : Bytes, size : Int32, looks : LookMaps) : Nil
      follow list, 0, pos, bytes, size, looks
    end

    # The epsilon closure at *pos*: drops whatever the position rules out and
    # collects the instructions that consume a character. Iterative for the same
    # reason the machine's closure is, a program near the instruction cap can be
    # one long chain of splits. A program counter joins a position at most once,
    # which is what bounds the work here.
    private def follow(list : Array(Int32), pc : Int32, pos : Int32, bytes : Bytes, size : Int32, looks : LookMaps) : Nil
      stack = @stack
      stack.clear
      stack.push pc
      while at = stack.pop?
        next if @marks[at] == @stamp
        @marks[at] = @stamp
        inst = @prog[at]
        case inst.kind
        when .jmp?
          stack.push inst.a
        when .again?
          stack.push(@marks[inst.a] == @stamp ? inst.b : inst.a)
        when .split?
          stack.push inst.b
          stack.push inst.a
        when .save?
          # An assertion's program is compiled without capture slots, so a Save
          # cannot appear. Treating it as the plain epsilon it is keeps this
          # total over the instruction set rather than quietly wrong if one ever
          # does.
          stack.push at + 1
        when .match?
          @matched = true
        when .look?
          stack.push(at + 1) if Rx.look_holds?(looks, inst, pos)
        when .char?, .class?, .any?
          list << at
        else
          stack.push(at + 1) if Rx.anchor_holds?(inst.kind, bytes, pos, size)
        end
      end
    end
  end
end
