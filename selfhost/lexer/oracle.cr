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
count = 0
in_string = false
loop do
  # Reset before every call: the lexer sets it back to true as it goes, on
  # the assumption a parser is driving and will say otherwise each time.
  lexer.slash_is_regex = false
  lexer.wants_regex = false
  token = in_string ? lexer.next_string_token(lexer.token.delimiter_state) : lexer.next_token
  case token.type
  when .delimiter_start? then in_string = true
  when .delimiter_end?   then in_string = false
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
  # one line.
  shown = value.gsub("\\", "\\\\").gsub("\n", "\\n").gsub("\t", "\\t").gsub("\0", "\\0")
  puts "#{token.type}\t#{token.line_number}\t#{token.column_number}\t#{shown}"
  count += 1
  break if count > 200_000
end
