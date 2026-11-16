require "./ed25519"

# Note parsing and verifier key format follow golang.org/x/mod/sumdb/note.
# Copyright 2019 The Go Authors. See GO_LICENSE.
module Iyi::Mod::SumDB
  # A C2SP verifier key. The key ID binds the name, algorithm and key bytes.
  class Verifier
    getter name : String, id : UInt32
    @public_key : Bytes

    def initialize(encoded : String)
      parts = encoded.split('+', 3)
      raise Error.new("sumdb: invalid verifier key") unless parts.size == 3
      @name = parts[0]
      unless valid_name?(@name) && parts[1].size == 8 && parts[1].each_char.all? { |c| c.ascii_number? || ('a' <= c && c <= 'f') }
        raise Error.new("sumdb: invalid verifier key name or ID")
      end
      @id = parts[1].to_u32(16)
      key = SumDB.decode_base64(parts[2])
      raise Error.new("sumdb: verifier key must be Ed25519") unless key.size == 33 && key[0] == 1
      hash = ::Crystal::Digest::SHA256.new
      hash.update(@name)
      hash.update("\n")
      hash.update(key)
      expected = hash.final
      actual_id = IO::ByteFormat::BigEndian.decode(UInt32, expected)
      raise Error.new("sumdb: verifier key ID does not match key") unless @id == actual_id
      @public_key = key[1, 32].dup
    end

    def verify(message : Bytes, signature : Bytes) : Bool
      Ed25519.verify(@public_key, message, signature)
    end

    def valid_name?(name : String) : Bool
      !name.empty? && name.valid_encoding? && name.each_char.none? { |c| c.whitespace? || c == '+' || c.ord < 32 || c.ord == 127 }
    end
  end

  module Note
    # Return text only after at least one trusted signature has verified.
    # Unknown keys are ignored; an invalid signature from a known key is not.
    def self.open(note : String, keys : Array(Verifier)) : String
      raise Error.new("sumdb: signed note contains CR; expected LF line endings") if note.includes?('\r')
      if !note.valid_encoding? || note.each_byte.any? { |b| b < 32 && b != 10 }
        raise Error.new("sumdb: invalid signed note text")
      end
      raise Error.new("sumdb: signed note missing final newline") unless note.ends_with?('\n')
      separator = note.rindex("\n\n")
      raise Error.new("sumdb: signed note missing signature separator") unless separator
      text = note[0, separator + 1]
      signatures = note[(separator + 2)..]
      lines = signatures.lines
      raise Error.new("sumdb: signed note has no signatures") if lines.empty?
      raise Error.new("sumdb: too many note signatures") if lines.size > 100
      identities = Set(Tuple(String, UInt32)).new
      keys.each do |key|
        raise Error.new("sumdb: ambiguous verifier key #{key.name}") unless identities.add?({key.name, key.id})
      end
      seen = Set(Tuple(String, UInt32)).new
      verified = false
      lines.each do |line|
        fields = line.chomp.split(' ')
        unless fields.size == 3 && fields[0] == "\u2014" && !fields[1].empty? && fields[1].each_char.none?(&.whitespace?) && !fields[1].includes?('+')
          raise Error.new("sumdb: malformed signature line")
        end
        raw = SumDB.decode_base64(fields[2])
        raise Error.new("sumdb: malformed signature") if raw.size < 5
        id = IO::ByteFormat::BigEndian.decode(UInt32, raw)
        raise Error.new("sumdb: duplicate note signature") unless seen.add?({fields[1], id})
        key = keys.find { |candidate| candidate.name == fields[1] && candidate.id == id }
        next unless key
        unless raw.size == 68 && key.verify(text.to_slice, raw[4, 64])
          raise Error.new("sumdb: invalid signature for #{key.name}")
        end
        verified = true
      end
      raise Error.new("sumdb: no trusted signature") unless verified
      text
    end
  end
end
