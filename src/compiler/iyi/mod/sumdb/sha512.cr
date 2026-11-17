require "digest/digest"

# SHA-512 for the compiler's without_openssl build. The constants and round
# function follow FIPS 180-4 and src/std/digest.iyi. Not independently reviewed.
class Crystal::Digest::SHA512 < ::Digest
  extend ::Digest::ClassMethods

  K = UInt64.static_array(
    0x428a2f98d728ae22_u64, 0x7137449123ef65cd_u64, 0xb5c0fbcfec4d3b2f_u64, 0xe9b5dba58189dbbc_u64,
    0x3956c25bf348b538_u64, 0x59f111f1b605d019_u64, 0x923f82a4af194f9b_u64, 0xab1c5ed5da6d8118_u64,
    0xd807aa98a3030242_u64, 0x12835b0145706fbe_u64, 0x243185be4ee4b28c_u64, 0x550c7dc3d5ffb4e2_u64,
    0x72be5d74f27b896f_u64, 0x80deb1fe3b1696b1_u64, 0x9bdc06a725c71235_u64, 0xc19bf174cf692694_u64,
    0xe49b69c19ef14ad2_u64, 0xefbe4786384f25e3_u64, 0x0fc19dc68b8cd5b5_u64, 0x240ca1cc77ac9c65_u64,
    0x2de92c6f592b0275_u64, 0x4a7484aa6ea6e483_u64, 0x5cb0a9dcbd41fbd4_u64, 0x76f988da831153b5_u64,
    0x983e5152ee66dfab_u64, 0xa831c66d2db43210_u64, 0xb00327c898fb213f_u64, 0xbf597fc7beef0ee4_u64,
    0xc6e00bf33da88fc2_u64, 0xd5a79147930aa725_u64, 0x06ca6351e003826f_u64, 0x142929670a0e6e70_u64,
    0x27b70a8546d22ffc_u64, 0x2e1b21385c26c926_u64, 0x4d2c6dfc5ac42aed_u64, 0x53380d139d95b3df_u64,
    0x650a73548baf63de_u64, 0x766a0abb3c77b2a8_u64, 0x81c2c92e47edaee6_u64, 0x92722c851482353b_u64,
    0xa2bfe8a14cf10364_u64, 0xa81a664bbc423001_u64, 0xc24b8b70d0f89791_u64, 0xc76c51a30654be30_u64,
    0xd192e819d6ef5218_u64, 0xd69906245565a910_u64, 0xf40e35855771202a_u64, 0x106aa07032bbd1b8_u64,
    0x19a4c116b8d2d0c8_u64, 0x1e376c085141ab53_u64, 0x2748774cdf8eeb99_u64, 0x34b0bcb5e19b48a8_u64,
    0x391c0cb3c5c95a63_u64, 0x4ed8aa4ae3418acb_u64, 0x5b9cca4f7763e373_u64, 0x682e6ff3d6b2b8a3_u64,
    0x748f82ee5defb2fc_u64, 0x78a5636f43172f60_u64, 0x84c87814a1f0ab72_u64, 0x8cc702081a6439ec_u64,
    0x90befffa23631e28_u64, 0xa4506cebde82bde9_u64, 0xbef9a3f7b2c67915_u64, 0xc67178f2e372532b_u64,
    0xca273eceea26619c_u64, 0xd186b8c721c0c207_u64, 0xeada7dd6cde0eb1e_u64, 0xf57d4f7fee6ed178_u64,
    0x06f067aa72176fba_u64, 0x0a637dc5a2c898a6_u64, 0x113f9804bef90dae_u64, 0x1b710b35131c471b_u64,
    0x28db77f523047d84_u64, 0x32caab7b40c72493_u64, 0x3c9ebe0a15c9bebc_u64, 0x431d67c49c100d4c_u64,
    0x4cc5d4becb3e42b6_u64, 0x597f299cfc657e2a_u64, 0x5fcb6fab3ad6faec_u64, 0x6c44198c4a475817_u64,
  )

  @state = uninitialized UInt64[8]
  @block = uninitialized UInt8[128]
  @block_index = 0
  @length = 0_u128

  def initialize
    reset
  end

  private def reset_impl : Nil
    @length = 0_u128
    @block_index = 0
    @state[0] = 0x6a09e667f3bcc908_u64
    @state[1] = 0xbb67ae8584caa73b_u64
    @state[2] = 0x3c6ef372fe94f82b_u64
    @state[3] = 0xa54ff53a5f1d36f1_u64
    @state[4] = 0x510e527fade682d1_u64
    @state[5] = 0x9b05688c2b3e6c1f_u64
    @state[6] = 0x1f83d9abfb41bd6b_u64
    @state[7] = 0x5be0cd19137e2179_u64
  end

  private def update_impl(data : Bytes) : Nil
    @length &+= data.size.to_u128
    data.each do |byte|
      @block[@block_index] = byte
      @block_index += 1
      process_block if @block_index == 128
    end
  end

  private def final_impl(dst : Bytes) : Nil
    bits = @length &* 8_u128
    @block[@block_index] = 0x80_u8
    @block_index += 1
    if @block_index > 112
      while @block_index < 128
        @block[@block_index] = 0_u8
        @block_index += 1
      end
      process_block
    end
    while @block_index < 112
      @block[@block_index] = 0_u8
      @block_index += 1
    end
    16.times { |i| @block[112 + i] = (bits >> (8 * (15 - i))).to_u8! }
    process_block
    64.times { |i| dst[i] = (@state[i >> 3] >> (8 * (7 - (i & 7)))).to_u8! }
  end

  private def process_block : Nil
    w = uninitialized UInt64[80]
    16.times do |t|
      word = 0_u64
      8.times { |i| word = (word << 8) | @block[t * 8 + i].to_u64 }
      w[t] = word
    end
    (16...80).each do |t|
      x = w[t - 15]
      y = w[t - 2]
      s0 = x.rotate_right(1) ^ x.rotate_right(8) ^ (x >> 7)
      s1 = y.rotate_right(19) ^ y.rotate_right(61) ^ (y >> 6)
      w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
    end
    a, b, c, d, e, f, g, h = @state
    80.times do |t|
      s1 = e.rotate_right(14) ^ e.rotate_right(18) ^ e.rotate_right(41)
      ch = (e & f) ^ (~e & g)
      temp1 = h &+ s1 &+ ch &+ K[t] &+ w[t]
      s0 = a.rotate_right(28) ^ a.rotate_right(34) ^ a.rotate_right(39)
      maj = (a & b) ^ (a & c) ^ (b & c)
      temp2 = s0 &+ maj
      h, g, f, e, d, c, b, a = g, f, e, d &+ temp1, c, b, a, temp1 &+ temp2
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
    64
  end
end
