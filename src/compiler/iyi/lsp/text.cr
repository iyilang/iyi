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

  # A frame's body with every lone UTF-16 surrogate escape (`\ud83d` with
  # no low half after it, or a low half alone) written as `\ufffd`, or
  # nil where it has none. The escape is valid JSON, an editor's buffer
  # can hold one (half an emoji, deleted mid-pair), and `JSON.stringify`
  # writes it as is - but no UTF-8 string can hold it, and the JSON
  # library refused the whole frame: a didOpen carrying one was answered
  # -32700 and never opened, and every later answer read the disk. U+FFFD
  # is one UTF-16 unit, as the surrogate was, so the editor's positions
  # still land on the same characters.
  #
  # Every backslash in a JSON text is inside a string, so no string
  # state is kept: an escape is two bytes, or six for `\uXXXX`, and
  # `\\u` is a backslash followed by text.
  def mend(body : Bytes) : Bytes?
    mended = nil
    copied = 0
    i = 0
    while i < body.size
      unless body[i] == '\\'.ord
        i += 1
        next
      end
      unit = body[i + 1]? == 'u'.ord ? hex_unit(body, i + 2) : nil
      unless unit && 0xD800 <= unit <= 0xDFFF
        i += unit ? 6 : 2
        next
      end
      if unit <= 0xDBFF && body[i + 6]? == '\\'.ord && body[i + 7]? == 'u'.ord &&
         (low = hex_unit(body, i + 8)) && 0xDC00 <= low <= 0xDFFF
        i += 12
        next
      end
      mended ||= IO::Memory.new(body.size)
      mended.write body[copied, i - copied]
      mended << "\\ufffd"
      i += 6
      copied = i
    end
    return unless mended
    mended.write body[copied, body.size - copied]
    mended.to_slice
  end

  # The four hex digits at *at*, or nil where there are not four.
  private def hex_unit(body : Bytes, at : Int32) : Int32?
    return unless at + 4 <= body.size
    unit = 0
    4.times do |k|
      return unless digit = body[at + k].unsafe_chr.to_i?(16)
      unit = unit << 4 | digit
    end
    unit
  end
end
