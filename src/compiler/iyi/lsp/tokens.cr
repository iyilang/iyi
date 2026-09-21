# iyi: semantic tokens, from the lexer alone. iyi is a young language:
# no editor ships a grammar for it, so the server's token stream *is*
# the syntax highlighting — any LSP client colors `.iyi` correctly on
# day one with zero client-side configuration. The walk is the same
# protocol `Crystal::SyntaxHighlighter` proved: `next_token` in normal
# state, `next_string_token` through delimiters, interpolations recurse
# until the matching `}`, heredoc bodies drain at the newline that ends
# their header line. Malformed input keeps the prefix: the lexer raises
# on the first broken literal and the tokens before it still color.
require "../syntax/lexer"

module Iyi::Lsp
  module Tokens
    # The legend, in the order the wire indexes it. Standard LSP names,
    # so every client theme already has colors for them.
    TYPES = %w(keyword string number comment type function variable
      property operator regexp macro enumMember parameter)

    KEYWORD     =  0
    STRING      =  1
    NUMBER      =  2
    COMMENT     =  3
    TYPE        =  4
    FUNCTION    =  5
    VARIABLE    =  6
    PROPERTY    =  7
    OPERATOR    =  8
    REGEXP      =  9
    MACRO       = 10
    ENUM_MEMBER = 11
    PARAMETER   = 12

    # One colored span, single-line, in iyi's units: 1-based line,
    # 1-based codepoint column. The server converts to UTF-16 deltas.
    record Tok, line : Int32, column : Int32, size : Int32, type : Int32

    def self.scan(text : String, path : String? = nil) : Array(Tok)
      scanner = Scanner.new(text, path)
      scanner.scan
      scanner.toks
    end

    private class Scanner
      getter toks = [] of Tok

      def initialize(text : String, path : String? = nil)
        @lexer = Lexer.new(text)
        # The one thing about a file the lexer cannot read out of the
        # source: which language it is in, which it takes off the name.
        @lexer.filename = path if path
        @lexer.comments_enabled = true
        @lexer.count_whitespace = true
        @lexer.wants_raw = true
      end

      def scan : Nil
        scan_normal(break_on_rcurly: false)
      rescue CodeError
        # The lexer has no recovery: an unterminated literal raises and
        # the spans collected so far are the honest answer. The
        # diagnostics channel already names the break.
      end

      private def scan_normal(break_on_rcurly : Bool) : Nil
        last_is_def = false
        heredocs = [] of Token
        last_type : Token::Kind? = nil
        space_before = false

        while true
          previous_delimiter_state = @lexer.token.delimiter_state
          token = @lexer.next_token

          case token.type
          when .eof?
            break
          when .op_rcurly?
            break if break_on_rcurly
            emit token, OPERATOR
          when .delimiter_start?
            case
            when last_is_def && token.raw.in?("`", "/")
              # `def /` names a method; the slash is its name.
              emit token, FUNCTION
            when token.raw == "/" && slash_is_not_regex?(last_type, space_before)
              emit token, OPERATOR
            when token.delimiter_state.kind.heredoc?
              heredocs << token.dup
              emit token, STRING
            else
              scan_delimited token
              token.delimiter_state = previous_delimiter_state
            end
          when .string_array_start?, .symbol_array_start?
            scan_string_array token
          else
            classify token, last_is_def, after_dot: last_type.try(&.op_period?) || false
          end

          if token.type.newline? && !heredocs.empty?
            heredocs.each_with_index do |heredoc, index|
              scan_delimited heredoc, heredoc: true
              unless index == heredocs.size - 1
                between = @lexer.next_token
                break if between.type.eof?
                classify between, last_is_def, after_dot: false
              end
            end
            heredocs.clear
          end

          unless token.type.space?
            last_type = token.type
            last_is_def = token.keyword?(Keyword::DEF)
          end
          space_before = token.type.space?
        end
      end

      private def scan_delimited(token : Token, heredoc : Bool = false) : Nil
        kind = token.delimiter_state.kind.regex? ? REGEXP : STRING
        emit token, kind unless heredoc
        while true
          token = @lexer.next_string_token(token.delimiter_state)
          case token.type
          when .delimiter_end?
            emit token, kind
            break
          when .eof?
            break
          when .interpolation_start?
            emit token, OPERATOR
            scan_normal(break_on_rcurly: true)
          else
            emit token, kind
          end
        end
      end

      private def scan_string_array(token : Token) : Nil
        emit token, STRING
        while true
          consume_space_or_newline
          token = @lexer.next_string_token(token.delimiter_state)
          case token.type
          when .string?
            emit token, STRING
          when .string_array_end?
            emit token, STRING
            break
          when .interpolation_start?
            emit token, OPERATOR
            scan_normal(break_on_rcurly: true)
          when .eof?
            break
          else
            break
          end
        end
      end

      private def consume_space_or_newline : Nil
        while true
          char = @lexer.current_char
          if char == '\n'
            @lexer.next_char
            @lexer.incr_line_number 1
          elsif char.ascii_whitespace?
            @lexer.next_char
          else
            break
          end
        end
      end

      # The lexer cannot know whether `/` divides or opens a regex; the
      # token before it can (SyntaxHighlighter's rule, verbatim).
      private def slash_is_not_regex?(last_type : Token::Kind?, space_before : Bool) : Bool
        case last_type
        when Nil
          false
        when .number?, .const?, .instance_var?, .class_var?, .op_rparen?, .op_rsquare?, .op_rcurly?
          true
        when .op_lparen?, .op_lsquare?, .op_lcurly?
          false
        else
          !space_before
        end
      end

      private def classify(token : Token, last_is_def : Bool, after_dot : Bool = false) : Nil
        case token.type
        when .newline?, .space?
          # Layout is the client's business.
        when .comment?
          emit token, COMMENT
        when .number?
          emit token, NUMBER
        when .char?
          emit token, STRING
        when .symbol?
          emit token, ENUM_MEMBER
        when .const?
          emit token, TYPE
        when .instance_var?, .class_var?, .global?, .global_match_data_index?
          emit token, PROPERTY
        when .magic?
          emit token, MACRO
        when .macro_literal?, .macro_expression_start?, .macro_control_start?, .macro_var?, .macro_end?
          emit token, MACRO
        when .ident?
          if last_is_def
            emit token, FUNCTION
          else
            case token.value
            when Keyword
              emit token, KEYWORD
            else
              # A bare name. The lexer cannot resolve it, but the next
              # character can classify it the way every reader already
              # does: `name(` calls, `.name` calls, `name:` labels an
              # argument, and what remains reads as a variable.
              next_char = @lexer.current_char
              if next_char == '('
                emit token, FUNCTION
              elsif next_char == ':' && @lexer.peek_next_char != ':'
                emit token, PARAMETER
              elsif after_dot
                emit token, FUNCTION
              else
                emit token, VARIABLE
              end
            end
          end
        when .op_lparen?, .op_rparen?, .op_lsquare?, .op_rsquare?, .op_lcurly?, .op_at_lsquare?,
             .op_comma?, .op_period?, .op_period_period?, .op_period_period_period?,
             .op_colon?, .op_semicolon?, .op_question?, .op_dollar_question?, .op_dollar_tilde?
          # Punctuation stays plain, the way every theme expects.
        when .operator?
          emit token, last_is_def ? FUNCTION : OPERATOR
        when .underscore?
          # Plain.
        else
          # Plain.
        end
      end

      private def emit(token : Token, type : Int32) : Nil
        text = text_of(token)
        return if text.empty?

        line = token.line_number
        column = token.column_number
        text.each_line(chomp: false) do |segment|
          chomped = segment.chomp
          @toks << Tok.new(line, column, chomped.size, type) unless chomped.empty?
          line += 1
          column = 1
        end
      end

      # The lexer reuses one Token and does not clear `raw` between
      # kinds, so an ident can carry the previous number's bytes. Read
      # `raw` only for the kinds `wants_raw` actually writes — the
      # SyntaxHighlighter's own discipline; everything else spells
      # itself exactly through `to_s`.
      private def text_of(token : Token) : String
        case token.type
        when .number?, .char?, .symbol?, .delimiter_start?, .delimiter_end?,
             .string?, .string_array_start?, .symbol_array_start?,
             .string_array_end?, .interpolation_start?,
             .macro_literal?, .macro_expression_start?, .macro_control_start?,
             .macro_var?, .macro_end?
          raw = token.raw
          raw.empty? ? token.to_s : raw
        when .comment?, .space?
          token.value.to_s
        else
          token.to_s
        end
      end
    end
  end
end
