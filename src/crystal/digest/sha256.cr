require "digest/digest"

# Implements the SHA-256 digest algorithm (FIPS 180-4).
class Crystal::Digest::SHA256 < ::Digest
  extend ::Digest::ClassMethods

  K = StaticArray[
    0x428a2f98_u32, 0x71374491_u32, 0xb5c0fbcf_u32, 0xe9b5dba5_u32,
    0x3956c25b_u32, 0x59f111f1_u32, 0x923f82a4_u32, 0xab1c5ed5_u32,
    0xd807aa98_u32, 0x12835b01_u32, 0x243185be_u32, 0x550c7dc3_u32,
    0x72be5d74_u32, 0x80deb1fe_u32, 0x9bdc06a7_u32, 0xc19bf174_u32,
    0xe49b69c1_u32, 0xefbe4786_u32, 0x0fc19dc6_u32, 0x240ca1cc_u32,
    0x2de92c6f_u32, 0x4a7484aa_u32, 0x5cb0a9dc_u32, 0x76f988da_u32,
    0x983e5152_u32, 0xa831c66d_u32, 0xb00327c8_u32, 0xbf597fc7_u32,
    0xc6e00bf3_u32, 0xd5a79147_u32, 0x06ca6351_u32, 0x14292967_u32,
    0x27b70a85_u32, 0x2e1b2138_u32, 0x4d2c6dfc_u32, 0x53380d13_u32,
    0x650a7354_u32, 0x766a0abb_u32, 0x81c2c92e_u32, 0x92722c85_u32,
    0xa2bfe8a1_u32, 0xa81a664b_u32, 0xc24b8b70_u32, 0xc76c51a3_u32,
    0xd192e819_u32, 0xd6990624_u32, 0xf40e3585_u32, 0x106aa070_u32,
    0x19a4c116_u32, 0x1e376c08_u32, 0x2748774c_u32, 0x34b0bcb5_u32,
    0x391c0cb3_u32, 0x4ed8aa4a_u32, 0x5b9cca4f_u32, 0x682e6ff3_u32,
    0x748f82ee_u32, 0x78a5636f_u32, 0x84c87814_u32, 0x8cc70208_u32,
    0x90befffa_u32, 0xa4506ceb_u32, 0xbef9a3f7_u32, 0xc67178f2_u32,
  ]

  @count : UInt64 = 0_u64
  @buf = StaticArray(UInt32, 8).new(0_u32)
  @in = StaticArray(UInt8, 64).new(0_u8)
  @offset : Int32 = 0

  def initialize
    reset
  end

  private def reset_impl : Nil
    @count = 0_u64
    @offset = 0
    @buf[0] = 0x6a09e667_u32
    @buf[1] = 0xbb67ae85_u32
    @buf[2] = 0x3c6ef372_u32
    @buf[3] = 0xa54ff53a_u32
    @buf[4] = 0x510e527f_u32
    @buf[5] = 0x9b05688c_u32
    @buf[6] = 0x1f83d9ab_u32
    @buf[7] = 0x5be0cd19_u32
  end

  private def update_impl(data : Bytes) : Nil
    return if data.empty?

    in_len = data.bytesize
    @count &+= in_len.to_u64

    ptr = data.to_unsafe
    rem = in_len

    if @offset > 0
      needed = 64 - @offset
      if rem < needed
        (@in.to_unsafe + @offset).copy_from(ptr, rem)
        @offset += rem
        return
      else
        (@in.to_unsafe + @offset).copy_from(ptr, needed)
        transform(@in.to_unsafe)
        ptr += needed
        rem -= needed
        @offset = 0
      end
    end

    while rem >= 64
      transform(ptr)
      ptr += 64
      rem -= 64
    end

    if rem > 0
      @in.to_unsafe.copy_from(ptr, rem)
      @offset = rem
    end
  end

  private PADDING = begin
    padding = StaticArray(UInt8, 64).new(0_u8)
    padding[0] = 0x80_u8
    padding
  end

  private def final_impl(dst : Bytes) : Nil
    bit_len = @count * 8_u64

    pad_len = (@offset < 56) ? (56 - @offset) : (120 - @offset)
    update_impl(PADDING.to_slice[0, pad_len])

    length_bytes = uninitialized UInt8[8]
    IO::ByteFormat::BigEndian.encode(bit_len, length_bytes.to_slice)
    update_impl(length_bytes.to_slice)

    8.times do |i|
      dst[i * 4] = (@buf[i] >> 24).to_u8!
      dst[i * 4 + 1] = ((@buf[i] >> 16) & 0xFF).to_u8!
      dst[i * 4 + 2] = ((@buf[i] >> 8) & 0xFF).to_u8!
      dst[i * 4 + 3] = (@buf[i] & 0xFF).to_u8!
    end
  end

  private def transform(block : Pointer(UInt8)) : Nil
    w = uninitialized UInt32[64]

    16.times do |t|
      w[t] = (block[t * 4].to_u32 << 24) |
             (block[t * 4 + 1].to_u32 << 16) |
             (block[t * 4 + 2].to_u32 << 8) |
             (block[t * 4 + 3].to_u32)
    end

    (16...64).each do |t|
      s0 = w[t - 15].rotate_right(7) ^ w[t - 15].rotate_right(18) ^ (w[t - 15] >> 3)
      s1 = w[t - 2].rotate_right(17) ^ w[t - 2].rotate_right(19) ^ (w[t - 2] >> 10)
      w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
    end

    a = @buf[0]
    b = @buf[1]
    c = @buf[2]
    d = @buf[3]
    e = @buf[4]
    f = @buf[5]
    g = @buf[6]
    h = @buf[7]

    64.times do |t|
      s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25)
      ch = (e & f) ^ (~e & g)
      temp1 = h &+ s1 &+ ch &+ K[t] &+ w[t]
      s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22)
      maj = (a & b) ^ (a & c) ^ (b & c)
      temp2 = s0 &+ maj

      h = g
      g = f
      f = e
      e = d &+ temp1
      d = c
      c = b
      b = a
      a = temp1 &+ temp2
    end

    @buf[0] &+= a
    @buf[1] &+= b
    @buf[2] &+= c
    @buf[3] &+= d
    @buf[4] &+= e
    @buf[5] &+= f
    @buf[6] &+= g
    @buf[7] &+= h
  end

  def digest_size : Int32
    32
  end
end
