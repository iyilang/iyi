# iyi: incremental text sync, in one place.
#
# `textDocument/didChange` carries ranges in wire units, and whoever
# keeps a buffer has to apply them the same way. Two processes keep one
# now — the server that compiles, and the proxy in front of it that
# outlives the server it spawns — so the arithmetic lives here rather
# than in each of them: a second implementation of "which byte is
# line 7, character 12" is a second set of off-by-ones.
module Iyi::Lsp::Text
  extend self

  # One contentChange: a range in wire units replaced by new text, or
  # the whole document when the range is absent.
  #
  # A change of the wrong shape is skipped and the text comes back as it
  # was. `change["text"].as_s` and `range[…]["line"].as_i` raised on a
  # change with no text, a line of 0.5 and a line of 2^40 ("Missing hash
  # key", "Cast from Float64", "Arithmetic overflow"); the worker rescued
  # that and dropped the frame, the proxy did not and the session ended
  # with exit 1. Both keep a buffer with this, so skipping here is
  # skipping in both, and the two buffers still agree.
  def apply(text : String, change : JSON::Any) : String
    return text unless new_text = change.as_h?.try(&.["text"]?).try(&.as_s?)
    return new_text unless range = change["range"]?
    return text unless (start = position(range, "start")) && (finish = position(range, "end"))

    start_offset = offset_at(text, *start)
    end_offset = offset_at(text, *finish)
    end_offset = start_offset if end_offset < start_offset
    String.build(text.bytesize + new_text.bytesize) do |io|
      io.write text.to_slice[0, start_offset]
      io << new_text
      io.write text.to_slice[end_offset, text.bytesize - end_offset]
    end
  end

  # A range's `start` or `end` as line and character, or nil where it is
  # the wrong shape: not two integers a position can hold. The protocol's
  # uinteger stops at 2^31 - 1, which is also where `Int32` does.
  private def position(range : JSON::Any, key : String) : {Int32, Int32}?
    return unless point = range.as_h?.try(&.[key]?).try(&.as_h?)
    line = point["line"]?.try(&.raw)
    character = point["character"]?.try(&.raw)
    return unless line.is_a?(Int64) && character.is_a?(Int64)
    return unless Int32::MIN <= line <= Int32::MAX && Int32::MIN <= character <= Int32::MAX
    {line.to_i32, character.to_i32}
  end

  # Byte offset of an LSP position: 0-based line, UTF-16 character.
  def offset_at(text : String, line : Int32, character : Int32) : Int32
    reader = Char::Reader.new(text)
    current = 0
    while current < line && reader.pos < text.bytesize
      current += 1 if reader.current_char == '\n'
      reader.next_char
    end
    units = 0
    while units < character && reader.pos < text.bytesize
      ch = reader.current_char
      # A character past the line's end is the line's end (LSP 3.17), and
      # a CRLF line ends before its `\r`: stopping at `\n` alone let an
      # edit's range past the end take the `\r`, and the server's buffer
      # stopped matching the editor's.
      break if ch == '\n' || (ch == '\r' && reader.peek_next_char == '\n')
      units += ch.ord >= 0x10000 ? 2 : 1
      reader.next_char
    end
    reader.pos
  end
end
