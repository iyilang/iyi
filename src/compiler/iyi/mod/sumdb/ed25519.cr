require "./base"
require "./sha512"

# Verification only. Ported from src/std/curve25519.iyi and RFC 8032.
# This implementation has not had independent cryptographic review. Its
# arithmetic and branches operate exclusively on public verification inputs.
module Iyi::Mod::SumDB::Ed25519
  ORDER = Bytes[0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
    0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10]

  def self.verify(public_key : Bytes, message : Bytes, signature : Bytes) : Bool
    return false unless public_key.size == 32 && signature.size == 64
    return false unless below_order?(signature[32, 32])
    point = Point.decode(public_key)
    return false unless point
    # A small-order trust key admits trivial forgeries and is never a valid
    # generated Ed25519 key. The signature equation alone would accept one.
    return false if point.double.double.double.identity?
    digest = ::Crystal::Digest::SHA512.new
    digest.update(signature[0, 32])
    digest.update(public_key)
    digest.update(message)
    challenge = reduce(digest.final)
    base = Point.base.cached
    minus_a = point.cached
    result = Point.identity
    255.downto(0) do |i|
      result = result.double
      result = result.add(base) if signature[32 + i // 8] & (1 << (i % 8)) != 0
      result = result.sub(minus_a) if challenge[i // 8] & (1 << (i % 8)) != 0
    end
    result.encode == signature[0, 32]
  end

  private def self.below_order?(bytes : Bytes) : Bool
    31.downto(0) do |i|
      return true if bytes[i] < ORDER[i]
      return false if bytes[i] > ORDER[i]
    end
    false
  end

  # Reduce one public SHA-512 output a byte at a time, as CurveScalar in
  # std/curve25519 does. Each quotient estimate is exact or one too high.
  private def self.reduce(bytes : Bytes) : Bytes
    l0 = 0x5812631a5cf5d3ed_u64
    l1 = 0x14def9dea2f79cd6_u64
    l3 = 0x1000000000000000_u64
    r0 = r1 = r2 = r3 = 0_u64
    63.downto(0) do |i|
      r4 = r3 >> 56
      r3 = (r3 << 8) | (r2 >> 56)
      r2 = (r2 << 8) | (r1 >> 56)
      r1 = (r1 << 8) | (r0 >> 56)
      r0 = (r0 << 8) | bytes[i].to_u64
      q = (r3 >> 60) | (r4 << 4)
      m = q.to_u128 &* l0.to_u128
      n = q.to_u128 &* l1.to_u128 &+ (m >> 64)
      d = r0.to_u128 &- m.to_u64!.to_u128
      r0 = d.to_u64!
      b = d >> 127
      d = r1.to_u128 &- n.to_u64!.to_u128 &- b
      r1 = d.to_u64!
      b = d >> 127
      d = r2.to_u128 &- (n >> 64) &- b
      r2 = d.to_u64!
      b = d >> 127
      d = r3.to_u128 &- (q << 60).to_u128 &- b
      r3 = d.to_u64!
      b = d >> 127
      d = r4.to_u128 &- (q >> 4).to_u128 &- b
      back = 0_u64 &- (d >> 127).to_u64!
      s = r0.to_u128 &+ (l0 & back).to_u128
      r0 = s.to_u64!
      s = r1.to_u128 &+ (l1 & back).to_u128 &+ (s >> 64)
      r1 = s.to_u64!
      s = r2.to_u128 &+ (s >> 64)
      r2 = s.to_u64!
      r3 = r3 &+ (l3 & back) &+ (s >> 64).to_u64!
    end
    result = Bytes.new(32)
    {r0, r1, r2, r3}.each_with_index do |word, j|
      8.times { |i| result[j * 8 + i] = (word >> (8 * i)).to_u8! }
    end
    result
  end

  private struct Field
    MASK = 0x7ffffffffffff_u64
    getter l0 : UInt64, l1 : UInt64, l2 : UInt64, l3 : UInt64, l4 : UInt64

    def initialize(@l0 : UInt64, @l1 : UInt64, @l2 : UInt64, @l3 : UInt64, @l4 : UInt64)
    end

    def self.zero : Field
      new(0_u64, 0_u64, 0_u64, 0_u64, 0_u64)
    end

    def self.one : Field
      new(1_u64, 0_u64, 0_u64, 0_u64, 0_u64)
    end

    def self.d : Field
      new(0x34dca135978a3_u64, 0x1a8283b156ebd_u64, 0x5e7a26001c029_u64, 0x739c663a03cbb_u64, 0x52036cee2b6ff_u64)
    end

    def self.d2 : Field
      new(0x69b9426b2f159_u64, 0x35050762add7a_u64, 0x3cf44c0038052_u64, 0x6738cc7407977_u64, 0x2406d9dc56dff_u64)
    end

    def self.sqrt_m1 : Field
      new(0x61b274a0ea0b0_u64, 0xd5a5fc8f189d_u64, 0x7ef5e9cbd0c60_u64, 0x78595a6804c9e_u64, 0x2b8324804fc1d_u64)
    end

    def self.load64(b : Bytes, offset : Int32) : UInt64
      word = 0_u64
      8.times { |i| word |= b[offset + i].to_u64 << (8 * i) }
      word
    end

    def self.from_bytes(b : Bytes) : Field
      w0, w1, w2, w3 = {load64(b, 0), load64(b, 8), load64(b, 16), load64(b, 24)}
      new(w0 & MASK, ((w0 >> 51) | (w1 << 13)) & MASK,
        ((w1 >> 38) | (w2 << 26)) & MASK,
        ((w2 >> 25) | (w3 << 39)) & MASK, (w3 >> 12) & MASK)
    end

    def to_bytes : Bytes
      r = reduced
      words = {r.l0 | (r.l1 << 51), (r.l1 >> 13) | (r.l2 << 38),
               (r.l2 >> 26) | (r.l3 << 25), (r.l3 >> 39) | (r.l4 << 12)}
      bytes = Bytes.new(32)
      4.times { |j| 8.times { |i| bytes[j * 8 + i] = (words[j] >> (8 * i)).to_u8! } }
      bytes
    end

    def self.carried(l0 : UInt64, l1 : UInt64, l2 : UInt64, l3 : UInt64, l4 : UInt64) : Field
      new((l0 & MASK) &+ (l4 >> 51) &* 19_u64, (l1 & MASK) &+ (l0 >> 51),
        (l2 & MASK) &+ (l1 >> 51), (l3 & MASK) &+ (l2 >> 51), (l4 & MASK) &+ (l3 >> 51))
    end

    def reduced : Field
      v = Field.carried(@l0, @l1, @l2, @l3, @l4)
      c = (v.l0 &+ 19_u64) >> 51
      c = (v.l1 &+ c) >> 51
      c = (v.l2 &+ c) >> 51
      c = (v.l3 &+ c) >> 51
      c = (v.l4 &+ c) >> 51
      r0 = v.l0 &+ c &* 19_u64
      r1 = v.l1 &+ (r0 >> 51)
      r2 = v.l2 &+ (r1 >> 51)
      r3 = v.l3 &+ (r2 >> 51)
      r4 = v.l4 &+ (r3 >> 51)
      Field.new(r0 & MASK, r1 & MASK, r2 & MASK, r3 & MASK, r4 & MASK)
    end

    def +(o : Field) : Field
      Field.carried(@l0 &+ o.l0, @l1 &+ o.l1, @l2 &+ o.l2, @l3 &+ o.l3, @l4 &+ o.l4)
    end

    def -(o : Field) : Field
      Field.carried((@l0 &+ 0xfffffffffffda_u64) &- o.l0, (@l1 &+ 0xffffffffffffe_u64) &- o.l1,
        (@l2 &+ 0xffffffffffffe_u64) &- o.l2, (@l3 &+ 0xffffffffffffe_u64) &- o.l3,
        (@l4 &+ 0xffffffffffffe_u64) &- o.l4)
    end

    def negate : Field
      Field.zero - self
    end

    private def m(a : UInt64, b : UInt64) : UInt128
      a.to_u128 &* b.to_u128
    end

    def *(o : Field) : Field
      a0, a1, a2, a3, a4 = {@l0, @l1, @l2, @l3, @l4}
      b0, b1, b2, b3, b4 = {o.l0, o.l1, o.l2, o.l3, o.l4}
      a1_19, a2_19, a3_19, a4_19 = {a1 &* 19_u64, a2 &* 19_u64, a3 &* 19_u64, a4 &* 19_u64}
      r0 = m(a0, b0) &+ m(a1_19, b4) &+ m(a2_19, b3) &+ m(a3_19, b2) &+ m(a4_19, b1)
      r1 = m(a0, b1) &+ m(a1, b0) &+ m(a2_19, b4) &+ m(a3_19, b3) &+ m(a4_19, b2)
      r2 = m(a0, b2) &+ m(a1, b1) &+ m(a2, b0) &+ m(a3_19, b4) &+ m(a4_19, b3)
      r3 = m(a0, b3) &+ m(a1, b2) &+ m(a2, b1) &+ m(a3, b0) &+ m(a4_19, b4)
      r4 = m(a0, b4) &+ m(a1, b3) &+ m(a2, b2) &+ m(a3, b1) &+ m(a4, b0)
      Field.wide(r0, r1, r2, r3, r4)
    end

    def square : Field
      a0, a1, a2, a3, a4 = {@l0, @l1, @l2, @l3, @l4}
      r0 = m(a0, a0) &+ m(a1 &* 38_u64, a4) &+ m(a2 &* 38_u64, a3)
      r1 = m(a0 &* 2_u64, a1) &+ m(a2 &* 38_u64, a4) &+ m(a3 &* 19_u64, a3)
      r2 = m(a0 &* 2_u64, a2) &+ m(a1, a1) &+ m(a3 &* 38_u64, a4)
      r3 = m(a0 &* 2_u64, a3) &+ m(a1 &* 2_u64, a2) &+ m(a4 &* 19_u64, a4)
      r4 = m(a0 &* 2_u64, a4) &+ m(a1 &* 2_u64, a3) &+ m(a2, a2)
      Field.wide(r0, r1, r2, r3, r4)
    end

    def self.wide(r0 : UInt128, r1 : UInt128, r2 : UInt128, r3 : UInt128, r4 : UInt128) : Field
      carried((r0.to_u64! & MASK) &+ (r4 >> 51).to_u64! &* 19_u64,
        (r1.to_u64! & MASK) &+ (r0 >> 51).to_u64!, (r2.to_u64! & MASK) &+ (r1 >> 51).to_u64!,
        (r3.to_u64! & MASK) &+ (r2 >> 51).to_u64!, (r4.to_u64! & MASK) &+ (r3 >> 51).to_u64!)
    end

    def square_times(n : Int32) : Field
      r = self
      n.times { r = r.square }
      r
    end

    def pow_2_250_1 : {Field, Field}
      z2 = square
      z9 = z2.square.square * self
      z11 = z9 * z2
      t5 = z11.square * z9
      t10 = t5.square_times(5) * t5
      t20 = t10.square_times(10) * t10
      t40 = t20.square_times(20) * t20
      t50 = t40.square_times(10) * t10
      t100 = t50.square_times(50) * t50
      t200 = t100.square_times(100) * t100
      {t200.square_times(50) * t50, z11}
    end

    def invert : Field
      t, z11 = pow_2_250_1
      t.square_times(5) * z11
    end

    def pow22523 : Field
      t, _ = pow_2_250_1
      t.square_times(2) * self
    end

    def parity : UInt8
      (reduced.l0 & 1_u64).to_u8
    end

    def zero? : Bool
      r = reduced
      (r.l0 | r.l1 | r.l2 | r.l3 | r.l4) == 0_u64
    end

    def equals?(other : Field) : Bool
      (self - other).zero?
    end
  end

  private struct Cached
    getter ypx : Field, ymx : Field, z2 : Field, t2d : Field

    def initialize(@ypx : Field, @ymx : Field, @z2 : Field, @t2d : Field)
    end
  end

  private struct Point
    def initialize(@x : Field, @y : Field, @z : Field, @t : Field)
    end

    def self.identity : Point
      new(Field.zero, Field.one, Field.one, Field.zero)
    end

    def identity? : Bool
      @x.zero? && @y.equals?(@z)
    end

    def self.base : Point
      new(Field.new(0x62d608f25d51a_u64, 0x412a4b4f6592a_u64, 0x75b7171a4b31d_u64, 0x1ff60527118fe_u64, 0x216936d3cd6e5_u64),
        Field.new(0x6666666666658_u64, 0x4cccccccccccc_u64, 0x1999999999999_u64, 0x3333333333333_u64, 0x6666666666666_u64),
        Field.one,
        Field.new(0x68ab3a5b7dda3_u64, 0xeea2a5eadbb_u64, 0x2af8df483c27e_u64, 0x332b375274732_u64, 0x67875f0fd78b7_u64))
    end

    def double : Point
      a = @x.square
      b = @y.square
      zz = @z.square
      c = zz + zz
      h = a + b
      e = h - (@x + @y).square
      g = a - b
      f = c + g
      Point.new(e * f, g * h, f * g, e * h)
    end

    def cached : Cached
      Cached.new(@y + @x, @y - @x, @z + @z, @t * Field.d2)
    end

    def add(q : Cached) : Point
      a = (@y - @x) * q.ymx
      b = (@y + @x) * q.ypx
      c = @t * q.t2d
      d = @z * q.z2
      e, f, g, h = {b - a, d - c, d + c, b + a}
      Point.new(e * f, g * h, f * g, e * h)
    end

    def sub(q : Cached) : Point
      a = (@y - @x) * q.ypx
      b = (@y + @x) * q.ymx
      c = @t * q.t2d
      d = @z * q.z2
      e, f, g, h = {b - a, d + c, d - c, b + a}
      Point.new(e * f, g * h, f * g, e * h)
    end

    def encode : Bytes
      inverse = @z.invert
      out = (@y * inverse).to_bytes
      out[31] |= (@x * inverse).parity << 7
      out
    end

    def self.decode(bytes : Bytes) : Point?
      y = Field.from_bytes(bytes)
      canonical = y.to_bytes
      31.times { |i| return nil unless canonical[i] == bytes[i] }
      return nil unless canonical[31] == (bytes[31] & 127)
      sign = bytes[31] >> 7
      yy = y.square
      u = yy - Field.one
      v = yy * Field.d + Field.one
      v3 = v.square * v
      x = u * v3 * (u * v3.square * v).pow22523
      vxx = v * x.square
      unless vxx.equals?(u)
        return nil unless vxx.equals?(u.negate)
        x = x * Field.sqrt_m1
      end
      return nil if sign == 1 && x.zero?
      x = x.negate unless x.parity == sign
      new(x, y, Field.one, x * y)
    end
  end
end
