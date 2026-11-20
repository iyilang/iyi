# The oracle for the lexer port: the token stream the current lexer produces,
# in a form a second implementation can be diffed against byte for byte.
#
# Kind, line, column and value only. Not `raw`, not the delimiter or macro
# state: those are lexer bookkeeping, and pinning them would make the port
# match an implementation rather than a language.
require "compiler/iyi/syntax"

path = ARGV[0]
source = File.read(path)
lexer = Iyi::Lexer.new(source)
lexer.filename = path
# The parser tells the lexer whether a `/` can start a regex; a bare driver
# does not, so `module samples/visited` lexed as a regex literal and swallowed
# the rest of the file. This slice has no regex literals in scope, so the
# honest setting for a lexer-only diff is: a slash is division.
lexer.slash_is_regex = false

# Inside a string the lexer needs `next_string_token`, and a driver that only
# ever calls `next_token` lexes the body as code: `"/home"` came out as an
# IDENT and two slashes. That was the oracle being wrong, not the port.
# An interpolation is code, and the parser is what tells the lexer so. A
# driver that keeps asking for string tokens after `INTERPOLATION_START`
# reads `#{name}!` as the string `name}!`, which is the instrument being
# wrong rather than the port. The contexts nest: a string can hold an
# interpolation and that can hold another string.
count = 0
# Each entry is the delimiter state to resume with once the interpolation
# it opened closes; an empty stack is ordinary code.
resume = [] of Iyi::Token::DelimiterState
in_string = false
braces = [] of Int32
lines = [] of String
begin
  loop do
    # Reset before every call: the lexer sets it back to true as it goes, on
    # the assumption a parser is driving and will say otherwise each time.
    lexer.slash_is_regex = false
    lexer.wants_regex = false
    token = in_string ? lexer.next_string_token(lexer.token.delimiter_state) : lexer.next_token
    case token.type
    when .delimiter_start?
      in_string = true
    when .delimiter_end?
      # A string written inside an interpolation ends back into that
      # interpolation's code, not into the string around it. Only the `}`
      # that closes the interpolation resumes a body, so popping the
      # resume stack here threw away the state that `}` needed and the
      # quote after it opened a second string that ran to end of file.
      in_string = false
    when .interpolation_start?
      # The body is code until the `}` that matches this one.
      resume << lexer.token.delimiter_state
      braces << 0
      in_string = false
    when .op_lcurly?
      braces[-1] = braces[-1] + 1 unless braces.empty?
    when .op_rcurly?
      unless braces.empty?
        if braces[-1] == 0
          braces.pop
          state = resume.pop?
          if state
            lexer.token.delimiter_state = state
            in_string = true
          end
        else
          braces[-1] = braces[-1] - 1
        end
      end
    end
    break if token.type.eof?
    value =
      case v = token.value
      when Nil    then token.type.to_s
      when Char   then v.to_s
      when String then v
      else             v.to_s
      end
    # Same reason as the port: escapes print as escapes, so one token stays
    # one line. A carriage return is one of them, and leaving it raw made a
    # `\r` in a string look like a difference the port had invented.
    shown = value.gsub("\\", "\\\\").gsub("\n", "\\n").gsub("\r", "\\r")
      .gsub("\t", "\\t").gsub("\0", "\\0")
    lines << "#{token.type}\t#{token.line_number}\t#{token.column_number}\t#{shown}"
    count += 1
    break if count > 200_000
  end
rescue error
  # The lexer raised, so this file has no oracle rather than a short one.
  STDERR.puts "  oracle stopped: #{error.message}"
  exit 0
end

# Printed only once the whole file has been read. A stream that stops
# where the lexer raised is not an oracle: `src/iyi/prelude.iyi` reaches
# a `{%` the lexer wants a parser's macro state for, and the tokens
# before it looked like agreement and then a difference that was ours.
lines.each { |line| puts line }
