require "crystal/digest/sha256"

module Iyi::Stale
  alias Digest = StaticArray(UInt8, 32)

  # D(tag, x) = SHA-256("iyi.stale.v1." + tag + "\0" + enc(x))
  def self.d(tag : String, & : Encoder ->) : Digest
    hasher = Crystal::Digest::SHA256.new
    hasher.update("iyi.stale.v1.")
    hasher.update(tag)
    hasher.update(Slice[0_u8])
    encoder = Encoder.new(hasher)
    yield encoder
    res = uninitialized StaticArray(UInt8, 32)
    hasher.final(res.to_slice)
    res
  end

  class Encoder # streams into SHA-256; every value self-delimiting
    @hasher : Crystal::Digest::SHA256

    def initialize(@hasher : Crystal::Digest::SHA256)
    end

    def str(s : String) # 0x01 u64be(bytesize) utf8 bytes
      write_prefix_and_u64(0x01_u8, s.bytesize.to_u64)
      @hasher.update(s.to_slice)
    end

    def bytes(b : Bytes) # 0x02 u64be(size) bytes
      write_prefix_and_u64(0x02_u8, b.size.to_u64)
      @hasher.update(b)
    end

    def int(i : Int64) # 0x03 8 bytes big-endian two's complement
      write_prefix_and_u64(0x03_u8, i.to_u64!)
    end

    def uint(u : UInt64) # 0x04 8 bytes big-endian
      write_prefix_and_u64(0x04_u8, u)
    end

    def bool(b : Bool) # 0x05 0x00 | 0x01
      buf = uninitialized UInt8[2]
      buf[0] = 0x05_u8
      buf[1] = b ? 0x01_u8 : 0x00_u8
      @hasher.update(buf.to_slice)
    end

    def absent # 0x06
      @hasher.update(Slice[0x06_u8])
    end

    def digest(x : Digest) # 0x07 32 raw bytes
      @hasher.update(Slice[0x07_u8])
      @hasher.update(x.to_slice)
    end

    def list(n : Int, &) # 0x08 u64be(n), then the block writes n values
      write_prefix_and_u64(0x08_u8, n.to_u64)
      yield self
    end

    def tag(name : String) # 0x09 u64be(bytesize) bytes (node and type class tags)
      write_prefix_and_u64(0x09_u8, name.bytesize.to_u64)
      @hasher.update(name.to_slice)
    end

    private def write_prefix_and_u64(prefix : UInt8, val : UInt64) : Nil
      buf = uninitialized UInt8[9]
      buf[0] = prefix
      IO::ByteFormat::BigEndian.encode(val, buf.to_slice[1, 8])
      @hasher.update(buf.to_slice)
    end
  end

  def self.hmac(key : Bytes, data : Bytes) : Digest # RFC 2104, block 64
    k_buf = StaticArray(UInt8, 64).new(0_u8)
    if key.size > 64
      hashed_key = Crystal::Digest::SHA256.digest(key)
      k_buf.to_slice[0, 32].copy_from(hashed_key.to_slice)
    else
      k_buf.to_slice[0, key.size].copy_from(key)
    end

    k_ipad = uninitialized UInt8[64]
    k_opad = uninitialized UInt8[64]
    64.times do |i|
      k_ipad[i] = k_buf[i] ^ 0x36_u8
      k_opad[i] = k_buf[i] ^ 0x5c_u8
    end

    inner_hasher = Crystal::Digest::SHA256.new
    inner_hasher.update(k_ipad.to_slice)
    inner_hasher.update(data)
    inner_digest = uninitialized UInt8[32]
    inner_hasher.final(inner_digest.to_slice)

    outer_hasher = Crystal::Digest::SHA256.new
    outer_hasher.update(k_opad.to_slice)
    outer_hasher.update(inner_digest.to_slice)
    res = uninitialized StaticArray(UInt8, 32)
    outer_hasher.final(res.to_slice)
    res
  end

  struct Keyer # K()
    @mode : String
    @key : Bytes?

    def self.local(key : Bytes) : Keyer
      new("local", key.dup)
    end

    def self.portable : Keyer
      new("portable", nil)
    end

    def initialize(@mode : String, @key : Bytes?)
    end

    def k(x : Digest) : Digest # HMAC(machine key, x) | x
      if @mode == "local"
        Iyi::Stale.hmac(@key.not_nil!, x.to_slice)
      else
        x
      end
    end

    def mode : String # "local" | "portable"
      @mode
    end
  end

  def self.hex(x : Digest) : String
    x.to_slice.hexstring
  end

  def self.parse_hex(s : String) : Digest
    raise ArgumentError.new("Expected 64 hex characters, got #{s.size}") unless s.size == 64
    res = uninitialized StaticArray(UInt8, 32)
    bytes = s.to_slice
    32.times do |i|
      hi = hex_char_to_val(bytes[i * 2])
      lo = hex_char_to_val(bytes[i * 2 + 1])
      res[i] = ((hi << 4) | lo).to_u8
    end
    res
  end

  private def self.hex_char_to_val(byte : UInt8) : UInt8
    case byte
    when 48_u8..57_u8 # '0'..'9'
      byte - 48_u8
    when 97_u8..102_u8 # 'a'..'f'
      byte - 87_u8
    when 65_u8..70_u8 # 'A'..'F'
      byte - 55_u8
    else
      raise ArgumentError.new("Invalid hex character: #{byte.chr.inspect}")
    end
  end
end
