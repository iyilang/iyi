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
  def apply(text : String, change : JSON::Any) : String
    new_text = change["text"].as_s
    range = change["range"]?
    return new_text unless range

    start_offset = offset_at(text, range["start"]["line"].as_i, range["start"]["character"].as_i)
    end_offset = offset_at(text, range["end"]["line"].as_i, range["end"]["character"].as_i)
    end_offset = start_offset if end_offset < start_offset
    String.build(text.bytesize + new_text.bytesize) do |io|
      io.write text.to_slice[0, start_offset]
      io << new_text
      io.write text.to_slice[end_offset, text.bytesize - end_offset]
    end
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
      break if ch == '\n'
      units += ch.ord >= 0x10000 ? 2 : 1
      reader.next_char
    end
    reader.pos
  end
end
