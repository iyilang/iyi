require "../spec_helper"
require "crystal/digest/sha1"
require "../../src/compiler/iyi/mod/sum"

# iyi: `iyi.sum` — SPEC.md III.7 step 2. The hash is computed here from
# trees written on the spot; the gates (`bench/packages_resolve.sh`,
# `bench/packages_get.sh`) are where a tag, a mirror and a build meet it.

private def tree(root : String, files : Hash(String, String)) : String
  files.each do |relative, bytes|
    path = File.join(root, relative)
    Dir.mkdir_p File.dirname(path)
    File.write path, bytes
  end
  root
end

# What `iyi.sum` held before `h2:`, kept here as the measure of the two
# trees below: every file, sorted, as `<relpath>\0<bytes>\0`, under SHA-1.
private def unframed(files : Hash(String, String)) : String
  digest = Crystal::Digest::SHA1.new
  files.keys.sort!.each do |relative|
    digest.update relative
    digest.update "\0"
    digest.update files[relative]
    digest.update "\0"
  end
  digest.hexfinal
end

private def selection(path : String, version : String) : Iyi::Mod::Selection
  Iyi::Mod::Selection.new(path, SemanticVersion.parse(version))
end

describe Iyi::Mod::Sum do
  describe ".tree_hash" do
    it "is the SHA-256 of a list of each file's SHA-256, kind and path" do
      with_tempdir do
        tree "pkg", {"iyi.mod" => "module example.test/user/liba\n", "sub/extra.iyi" => "x\n"}
        # sha256("<sha256(bytes)> f <path>\n" for each path, sorted), by
        # another program's SHA-256.
        Iyi::Mod::Sum.tree_hash("pkg").should eq "h2:bd9d142dd4d34bfde43caf17301ee6c8b07331f79c28155e063a616fb7abb64a"
      end
    end

    # The two trees a moved tag was made of: a data file that holds, after
    # a zero byte, the next file's name and another body for it. With no
    # lengths in what was hashed, the bytes moved from the data file into
    # the source file and the stream read the same.
    it "tells apart two trees whose bytes moved across a file's edge" do
      benign = "module liba\n\npub def greeting : String\n  \"benign\"\nend\n"
      hostile = "module liba\n\npub def greeting : String\n  \"hostile\"\nend\n"
      reviewed = {
        "liba.dat" => "DATA\0liba.iyi\0#{hostile}\0liba.iyz\0JUNK",
        "liba.iyi" => benign,
      }
      moved = {
        "liba.dat" => "DATA",
        "liba.iyi" => hostile,
        "liba.iyz" => "JUNK\0liba.iyi\0#{benign}",
      }
      unframed(moved).should eq unframed(reviewed)

      with_tempdir do
        tree "reviewed", reviewed
        tree "moved", moved
        Iyi::Mod::Sum.tree_hash("moved").should_not eq Iyi::Mod::Sum.tree_hash("reviewed")
      end
    end

    it "moves when a file is renamed, and when one byte of one changes" do
      with_tempdir do
        first = Iyi::Mod::Sum.tree_hash(tree "a", {"one.iyi" => "x\n", "two.iyi" => "y\n"})
        Iyi::Mod::Sum.tree_hash(tree "b", {"one.iyi" => "x\n", "three.iyi" => "y\n"}).should_not eq first
        Iyi::Mod::Sum.tree_hash(tree "c", {"one.iyi" => "x\n", "two.iyi" => "z\n"}).should_not eq first
        Iyi::Mod::Sum.tree_hash(tree "d", {"one.iyi" => "x\n", "two.iyi" => "y\n"}).should eq first
      end
    end

    it "spells a nested file's path with `/` on every platform" do
      with_tempdir do
        tree "nested", {"sub/extra.iyi" => "x\n"}
        list = "#{Crystal::Digest::SHA256.hexdigest("x\n")} f sub/extra.iyi\n"
        Iyi::Mod::Sum.tree_hash("nested").should eq "h2:#{Crystal::Digest::SHA256.hexdigest(list)}"
      end
    end

    {% if flag?(:win32) %}
      # Making a link is a privilege on Windows, and a file name cannot hold
      # a line break there.
      pending "tells a symbolic link from a file that holds its target's name"
      pending "refuses a file whose name has a line break in it"
    {% else %}
      it "tells a symbolic link from a file that holds its target's name" do
        with_tempdir do
          tree "linked", {"target.iyi" => "x\n"}
          File.symlink "target.iyi", "linked/alias"
          tree "copied", {"target.iyi" => "x\n", "alias" => "target.iyi"}
          Iyi::Mod::Sum.tree_hash("linked").should_not eq Iyi::Mod::Sum.tree_hash("copied")
        end
      end

      it "refuses a file whose name has a line break in it" do
        with_tempdir do
          tree "broken", {"one\ntwo" => "x\n"}
          expect_raises(Iyi::Mod::ModError, /line break/) do
            Iyi::Mod::Sum.tree_hash("broken")
          end
        end
      end
    {% end %}
  end

  describe ".check" do
    it "records a requirement with no entry as `h2:`, and is silent when it matches" do
      with_tempdir do
        checkout = tree "liba", {"liba.iyi" => "x\n"}
        Dir.mkdir "app"
        picked = [selection("example.test/user/liba", "1.0.0")]

        Iyi::Mod::Sum.check("app", picked) { checkout }
        written = File.read("app/iyi.sum")
        written.should eq "example.test/user/liba v1.0.0 #{Iyi::Mod::Sum.tree_hash(checkout)}\n"
        written.should match(/ h2:[0-9a-f]{64}\n\z/)

        Iyi::Mod::Sum.check("app", picked) { checkout }
        File.read("app/iyi.sum").should eq written
      end
    end

    it "refuses a checkout that is not what its `h2:` line says" do
      with_tempdir do
        checkout = tree "liba", {"liba.iyi" => "x\n"}
        Dir.mkdir "app"
        picked = [selection("example.test/user/liba", "1.0.0")]
        Iyi::Mod::Sum.check("app", picked) { checkout }
        written = File.read("app/iyi.sum")

        File.write "liba/liba.iyi", "y\n"
        expect_raises(Iyi::Mod::ModError, /is not what it was/) do
          Iyi::Mod::Sum.check("app", picked) { checkout }
        end
        File.read("app/iyi.sum").should eq written
      end
    end

    # An `s1:` line could not tell two trees apart, so it is not held
    # against the checkout - whatever it says - and not left in the file.
    it "reads an `s1:` line as no entry, and writes it again as `h2:`" do
      with_tempdir do
        checkout = tree "liba", {"liba.iyi" => "x\n"}
        Dir.mkdir "app"
        File.write "app/iyi.sum", <<-SUM
          example.test/user/liba v1.0.0 s1:0aa369130079195ed2d02d149a8f3557ac343a11
          example.test/user/libz v2.0.0 s1:f6b216a60000000000000000000000000000dead

          SUM

        Iyi::Mod::Sum.check("app", [selection("example.test/user/liba", "1.0.0")]) { checkout }
        # The line for a version this build did not use is not this build's
        # to restate: nothing was checked out to hash.
        File.read("app/iyi.sum").should eq <<-SUM
          example.test/user/liba v1.0.0 #{Iyi::Mod::Sum.tree_hash(checkout)}
          example.test/user/libz v2.0.0 s1:f6b216a60000000000000000000000000000dead

          SUM
      end
    end

    it "refuses a line that is neither" do
      with_tempdir do
        checkout = tree "liba", {"liba.iyi" => "x\n"}
        Dir.mkdir "app"
        File.write "app/iyi.sum", "example.test/user/liba v1.0.0 md5:00\n"
        expect_raises(Iyi::Mod::ModError, /not a sum line.*h2:/) do
          Iyi::Mod::Sum.check("app", [selection("example.test/user/liba", "1.0.0")]) { checkout }
        end
      end
    end
  end
end
