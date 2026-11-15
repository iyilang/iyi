require "../../spec_helper"
require "../../digest/spec_helper"
require "crystal/digest/sha256"

describe Crystal::Digest::SHA256 do
  it_acts_as_digest_algorithm Crystal::Digest::SHA256

  # The last four sit on either side of the padding's edges: 55 bytes is the
  # most one block holds beside its length, 56 the least that needs a second.
  [
    {"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
    {"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
    {"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
    {"a", "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"},
    {"0123456701234567012345670123456701234567012345670123456701234567", "8182cadb21af0e37c06414ece08e19c65bdb22c396d48ba7341012eea9ffdfdd"},
    {"fooø", "df81eea14671ce970fb1052e9f5dd6dbda652ed37423ed3624120ec1534784a7"},
    {"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"},
    {"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"},
    {"a" * 119, "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb"},
    {"a" * 1000, "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"},
  ].each do |(string, hexstring)|
    it "does digest for #{string.size > 70 ? "#{string.size} bytes" : string.inspect}" do
      Crystal::Digest::SHA256.digest(string).hexstring.should eq(hexstring)
    end

    it "does digest for #{string.size > 70 ? "#{string.size} bytes" : string.inspect} fed in pieces" do
      digest = Crystal::Digest::SHA256.new
      string.to_slice.each_slice(7) { |piece| digest.update Bytes.new(piece.to_unsafe, piece.size) }
      digest.hexfinal.should eq(hexstring)
    end
  end

  it "resets" do
    digest = Crystal::Digest::SHA256.new
    digest.update "abc"
    first = digest.final.hexstring
    digest.reset
    digest.update "abc"
    digest.final.hexstring.should eq(first)
  end

  it "can't call #final more than once" do
    digest = Crystal::Digest::SHA256.new
    digest.final
    expect_raises(Digest::FinalizedError) do
      digest.final
    end
  end

  it "returns the digest_size" do
    Crystal::Digest::SHA256.new.digest_size.should eq(32)
  end
end
