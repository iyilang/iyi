require "../../spec_helper"
require "compiler/iyi/stale/encoding"

describe "Iyi::Stale S1: SHA-256, HMAC, canonical encoding" do
  describe "Crystal::Digest::SHA256" do
    it "passes FIPS 180-4 test vector 'abc'" do
      Crystal::Digest::SHA256.hexdigest("abc").should eq("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    end

    it "passes FIPS 180-4 test vector '' (empty message)" do
      Crystal::Digest::SHA256.hexdigest("").should eq("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    end

    it "passes FIPS 180-4 448-bit message (56 bytes)" do
      m448 = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
      m448.bytesize.should eq(56)
      Crystal::Digest::SHA256.hexdigest(m448).should eq("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    end

    it "passes FIPS 180-4 896-bit message (112 bytes)" do
      m896 = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
      m896.bytesize.should eq(112)
      Crystal::Digest::SHA256.hexdigest(m896).should eq("cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
    end

    it "passes FIPS 180-4 a million 'a's" do
      million_a = "a" * 1_000_000
      Crystal::Digest::SHA256.hexdigest(million_a).should eq("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    end

    it "has digest_size of 32" do
      Crystal::Digest::SHA256.new.digest_size.should eq(32)
    end

    it "resets state correctly for reuse" do
      hasher = Crystal::Digest::SHA256.new
      hasher.update("abc").hexfinal.should eq("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
      hasher.reset
      hasher.update("").hexfinal.should eq("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    end

    it "streamed updates split at 1, 55, 56, 63, 64 and 65 bytes equal one-shot digest" do
      msg = String.build do |str|
        130.times do |i|
          str << (65 + (i % 26)).chr
        end
      end
      msg.bytesize.should eq(130)
      one_shot = Crystal::Digest::SHA256.hexdigest(msg)

      [1, 55, 56, 63, 64, 65].each do |split_point|
        # Split into two updates: prefix and remainder
        hasher2 = Crystal::Digest::SHA256.new
        hasher2.update(msg[0...split_point])
        hasher2.update(msg[split_point..])
        hasher2.hexfinal.should eq(one_shot), "failed two-part split at #{split_point}"

        # Chunked stream in pieces of size split_point
        hasher_chunked = Crystal::Digest::SHA256.new
        offset = 0
        bytes = msg.to_slice
        while offset < bytes.size
          chunk_size = Math.min(split_point, bytes.size - offset)
          hasher_chunked.update(bytes[offset, chunk_size])
          offset += chunk_size
        end
        hasher_chunked.hexfinal.should eq(one_shot), "failed chunked stream with chunk size #{split_point}"
      end
    end
  end

  describe "Iyi::Stale.hmac (RFC 4231 vectors)" do
    it "passes Case 1" do
      key = Bytes.new(20, 0x0b_u8)
      data = "Hi There".to_slice
      res = Iyi::Stale.hmac(key, data)
      Iyi::Stale.hex(res).should eq("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    end

    it "passes Case 2" do
      key = "Jefe".to_slice
      data = "what do ya want for nothing?".to_slice
      res = Iyi::Stale.hmac(key, data)
      Iyi::Stale.hex(res).should eq("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    end

    it "passes Case 3" do
      key = Bytes.new(20, 0xaa_u8)
      data = Bytes.new(50, 0xdd_u8)
      res = Iyi::Stale.hmac(key, data)
      Iyi::Stale.hex(res).should eq("773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
    end

    it "passes Case 4" do
      key = Bytes[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
        0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14,
        0x15, 0x16, 0x17, 0x18, 0x19]
      data = Bytes.new(50, 0xcd_u8)
      res = Iyi::Stale.hmac(key, data)
      Iyi::Stale.hex(res).should eq("82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b")
    end

    it "passes Case 6 (key larger than block size 64 bytes)" do
      key = Bytes.new(131, 0xaa_u8)
      data = "Test Using Larger Than Block-Size Key - Hash Key First".to_slice
      res = Iyi::Stale.hmac(key, data)
      Iyi::Stale.hex(res).should eq("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    end

    it "passes Case 7 (larger than block size key and data)" do
      key = Bytes.new(131, 0xaa_u8)
      data = "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.".to_slice
      res = Iyi::Stale.hmac(key, data)
      Iyi::Stale.hex(res).should eq("9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2")
    end
  end

  describe "Iyi::Stale golden D() vectors" do
    it "encodes str (non-empty)" do
      d = Iyi::Stale.d("test.str") { |e| e.str("hello world") }
      Iyi::Stale.hex(d).should eq("c6d274aa8745ed84d102297a7f3af2b2409a388eb28e713695f8558f01111429")
    end

    it "encodes str (empty)" do
      d = Iyi::Stale.d("test.str_empty") { |e| e.str("") }
      Iyi::Stale.hex(d).should eq("6e022949cf6f786610f77b0bcf6b69f5093cd3fba948ed175e92d2a1140def2f")
    end

    it "encodes bytes" do
      d = Iyi::Stale.d("test.bytes") { |e| e.bytes(Bytes[0x00, 0xff, 0x42]) }
      Iyi::Stale.hex(d).should eq("45c1b9864786bd1a815041e4b845a0ba7c3032498eb97525d293bc9f6000a744")
    end

    it "encodes int (positive)" do
      d = Iyi::Stale.d("test.int_pos") { |e| e.int(42_i64) }
      Iyi::Stale.hex(d).should eq("238fafdeb3f82392ecb4eb02290129d3cb3cc148a8cf994fd2d35687b3851794")
    end

    it "encodes int (negative)" do
      d = Iyi::Stale.d("test.int_neg") { |e| e.int(-42_i64) }
      Iyi::Stale.hex(d).should eq("afdfdce834d2ac0efff3b6f8ee72a2236dce39916ad9707d79deb9b0ce6f2d96")
    end

    it "encodes int (Int64::MIN)" do
      d = Iyi::Stale.d("test.int_min") { |e| e.int(Int64::MIN) }
      Iyi::Stale.hex(d).should eq("c12993e198f2100e287d6fa49f4760a36a2c1f5d4a95b91d550f511a22f3a6ca")
    end

    it "encodes int (Int64::MAX)" do
      d = Iyi::Stale.d("test.int_max") { |e| e.int(Int64::MAX) }
      Iyi::Stale.hex(d).should eq("f70db9642b74aadf9039213e1d989e9c266a2db7994ab01581ab86d5f6a1092f")
    end

    it "encodes uint (zero)" do
      d = Iyi::Stale.d("test.uint_zero") { |e| e.uint(0_u64) }
      Iyi::Stale.hex(d).should eq("8d86239f0cd8d428d126a32b026edcdd24085909fef4c5dc798d5624192e489d")
    end

    it "encodes uint (UInt64::MAX)" do
      d = Iyi::Stale.d("test.uint_max") { |e| e.uint(UInt64::MAX) }
      Iyi::Stale.hex(d).should eq("41b4c672862e440f6a581b38e2810e5f87856ba8f976984689673d27102c548d")
    end

    it "encodes bool (true)" do
      d = Iyi::Stale.d("test.bool_true") { |e| e.bool(true) }
      Iyi::Stale.hex(d).should eq("a318e07ba9cfa0d7d96e4dc955f4b4033e080e03db64d6650fe6dec6f896f32a")
    end

    it "encodes bool (false)" do
      d = Iyi::Stale.d("test.bool_false") { |e| e.bool(false) }
      Iyi::Stale.hex(d).should eq("a7580cf7977e47ec94e1c72ca2e1e06703e6dc6a1584ecf754762bc2bd1bc740")
    end

    it "encodes absent" do
      d = Iyi::Stale.d("test.absent") { |e| e.absent }
      Iyi::Stale.hex(d).should eq("da89aaf365d74a2339d1a9285a305e44cdfc99763e5dc75f1beafbb666065dc5")
    end

    it "encodes digest" do
      raw_digest = uninitialized StaticArray(UInt8, 32)
      raw_digest.to_slice.copy_from(Crystal::Digest::SHA256.digest("abc"))
      d = Iyi::Stale.d("test.digest") { |e| e.digest(raw_digest) }
      Iyi::Stale.hex(d).should eq("87021faf6a92a49902d5eb50bbeba49f4be364b4acab5bcd3e5d457138310040")
    end

    it "encodes tag" do
      d = Iyi::Stale.d("test.tag") { |e| e.tag("MyType") }
      Iyi::Stale.hex(d).should eq("6381cf9c65d9d4b660c0391cebdb5d4c16546034434022406711cc0a08b8d94e")
    end

    it "encodes list" do
      d = Iyi::Stale.d("test.list") do |e|
        e.list(2) do
          e.str("first")
          e.str("second")
        end
      end
      Iyi::Stale.hex(d).should eq("029755afca1465dce224302e62edea8b99365929527b303d4fc2739f0dcb8376")
    end

    it "encodes multi-field record" do
      d = Iyi::Stale.d("test.multi") do |e|
        e.tag("Node")
        e.str("hello")
        e.int(123_i64)
        e.bool(true)
        e.absent
      end
      Iyi::Stale.hex(d).should eq("6e2567df04c657dc625f09c8c23d6b543881e670b0f9ac1038a39e477fb9745d")
    end
  end

  describe "Iyi::Stale.hex and parse_hex" do
    it "roundtrips 32-byte Digest" do
      d = Iyi::Stale.d("roundtrip") { |e| e.str("roundtrip-test") }
      hex_str = Iyi::Stale.hex(d)
      hex_str.size.should eq(64)
      parsed = Iyi::Stale.parse_hex(hex_str)
      parsed.should eq(d)
    end

    it "raises ArgumentError on invalid size" do
      expect_raises(ArgumentError, /Expected 64/) do
        Iyi::Stale.parse_hex("abcd")
      end
    end

    it "raises ArgumentError on invalid hex characters" do
      expect_raises(ArgumentError, /Invalid hex character/) do
        Iyi::Stale.parse_hex("z" * 64)
      end
    end
  end

  describe "Iyi::Stale::Keyer" do
    it "handles portable mode (identity)" do
      keyer = Iyi::Stale::Keyer.portable
      keyer.mode.should eq("portable")
      d = Iyi::Stale.d("test") { |e| e.str("abc") }
      keyer.k(d).should eq(d)
    end

    it "handles local mode (HMAC with machine key)" do
      key = "my-machine-key-123".to_slice
      keyer = Iyi::Stale::Keyer.local(key)
      keyer.mode.should eq("local")

      raw_d = uninitialized StaticArray(UInt8, 32)
      raw_d.to_slice.copy_from(Crystal::Digest::SHA256.digest("abc"))
      k_result = keyer.k(raw_d)
      Iyi::Stale.hex(k_result).should eq("d137dfc80fb59ef8fde95ba29b1a345511863dd0827a06aa8889ab6d62e989da")
    end
  end
end
