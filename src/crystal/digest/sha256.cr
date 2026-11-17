require "digest/digest"

# Implements the SHA-256 digest algorithm (FIPS 180-4), without OpenSSL.
#
# The compiler is built `-Dwithout_openssl`, so `Digest::SHA256` is not there
# for it; this is the copy it carries, beside `Crystal::Digest::SHA1` and
# `Crystal::Digest::MD5` and for the same reason.
class Crystal::Digest::SHA256 < ::Digest
  extend ::Digest::ClassMethods

  K = UInt32.static_array(
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  )

  @state = uninitialized UInt32[8]
  @block = uninitialized UInt8[64]
  @block_index = 0
  @length = 0_u64 # in bytes

  def initialize
    reset
  end

  private def reset_impl : Nil
    @length = 0_u64
    @block_index = 0
    @state[0] = 0x6a09e667_u32
    @state[1] = 0xbb67ae85_u32
    @state[2] = 0x3c6ef372_u32
    @state[3] = 0xa54ff53a_u32
    @state[4] = 0x510e527f_u32
    @state[5] = 0x9b05688c_u32
    @state[6] = 0x1f83d9ab_u32
    @state[7] = 0x5be0cd19_u32
  end

  private def update_impl(data : Bytes) : Nil
    @length &+= data.size
    data.each do |byte|
      @block[@block_index] = byte
      @block_index += 1
      process_block if @block_index == 64
    end
  end

  private def final_impl(dst : Bytes) : Nil
    bits = @length &* 8

    @block[@block_index] = 0x80_u8
    @block_index += 1
    # The length takes the block's last eight bytes; a block with no room
    # left for it is closed with zeroes and the length goes in the next.
    if @block_index > 56
      while @block_index < 64
        @block[@block_index] = 0_u8
        @block_index += 1
      end
      process_block
    end
    while @block_index < 56
      @block[@block_index] = 0_u8
      @block_index += 1
    end
    8.times { |i| @block[56 + i] = (bits >> (8 * (7 - i))).to_u8! }
    process_block

    32.times { |i| dst[i] = (@state[i >> 2] >> (8 * (3 - (i & 3)))).to_u8! }
  end

  private def process_block : Nil
    w = uninitialized UInt32[64]
    16.times do |t|
      w[t] = (@block[t * 4].to_u32 << 24) | (@block[t * 4 + 1].to_u32 << 16) |
             (@block[t * 4 + 2].to_u32 << 8) | @block[t * 4 + 3].to_u32
    end
    (16...64).each do |t|
      s0 = w[t - 15].rotate_right(7) ^ w[t - 15].rotate_right(18) ^ (w[t - 15] >> 3)
      s1 = w[t - 2].rotate_right(17) ^ w[t - 2].rotate_right(19) ^ (w[t - 2] >> 10)
      w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
    end

    a, b, c, d, e, f, g, h = @state

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

    @state[0] &+= a
    @state[1] &+= b
    @state[2] &+= c
    @state[3] &+= d
    @state[4] &+= e
    @state[5] &+= f
    @state[6] &+= g
    @state[7] &+= h

    @block_index = 0
  end

  def digest_size : Int32
    32
  end
end
