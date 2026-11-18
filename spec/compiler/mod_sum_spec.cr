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
  "s1:#{digest.hexfinal}"
end

private def selection(path : String, version : String) : Iyi::Mod::Selection
  Iyi::Mod::Selection.new(path, SemanticVersion.parse(version))
end

private def check_trees(dir : String, selections : Array(Iyi::Mod::Selection), notices : IO = STDERR, &checkout : Iyi::Mod::Selection -> String) : Nil
  checks = Iyi::Mod::Sum.checker(dir, notices)
  checks.trees(selections, &checkout)
  checks.write
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

  describe "checking manifests" do
    it "records the exact manifest bytes under a separate key" do
      with_tempdir do
        Dir.mkdir "app"
        picked = selection("example.test/user/liba", "1.0.0")
        text = "module example.test/user/liba\r\n"
        expected = "h2:4a6850226dc7aa494309c54e2e34dfbe7fdfb0702fbdba441a0b4a9d387ca6ae"
        checks = Iyi::Mod::Sum.checker("app")
        checks.manifest(picked, text)
        File.exists?("app/iyi.sum").should be_false
        checks.write
        File.read("app/iyi.sum").should eq "example.test/user/liba v1.0.0/iyi.mod #{expected}\n"

        checks = Iyi::Mod::Sum.checker("app")
        checks.manifest(picked, text)
        checks.pending?.should be_false
      end
    end

    it "refuses a changed manifest with both hashes and leaves the sum alone" do
      with_tempdir do
        Dir.mkdir "app"
        picked = selection("example.test/user/liba", "1.0.0")
        original = "module example.test/user/liba\n"
        changed = "#{original}require example.test/user/libb v1.0.0\n"
        checks = Iyi::Mod::Sum.checker("app")
        checks.manifest(picked, original)
        checks.write
        written = File.read("app/iyi.sum")
        expected = Iyi::Mod::Sum.manifest_hash(original)
        actual = Iyi::Mod::Sum.manifest_hash(changed)

        checks = Iyi::Mod::Sum.checker("app")
        expect_raises(Iyi::Mod::ModError, /v1\.0\.0\/iyi\.mod is not what it was: .* says #{expected}, the manifest hashes to #{actual}/) do
          checks.manifest(picked, changed)
        end
        File.read("app/iyi.sum").should eq written
      end
    end

    it "fails when a missing manifest line cannot be written" do
      with_tempdir do
        Dir.mkdir "app"
        written = "example.test/user/liba v1.0.0 h2:#{"0" * 64}\n"
        File.write "app/iyi.sum", written
        File.chmod "app/iyi.sum", 0o444
        begin
          pending! "this user writes a read-only file" if File::Info.writable?("app/iyi.sum")
          checks = Iyi::Mod::Sum.checker("app")
          checks.manifest(selection("example.test/user/liba", "1.0.0"), "module example.test/user/liba\n")
          expect_raises(File::Error) { checks.write }
          File.read("app/iyi.sum").should eq written
        ensure
          File.chmod "app/iyi.sum", 0o644
        end
      end
    end

    it "retains outbid manifest keys while pruning entries outside the graph" do
      with_tempdir do
        Dir.mkdir "app"
        checkout = tree "liba", {"liba.iyi" => "x\n"}
        lower = selection("example.test/user/liba", "1.0.0")
        selected = selection("example.test/user/liba", "1.1.0")
        unused = selection("example.test/user/unused", "1.0.0")
        checks = Iyi::Mod::Sum.checker("app")
        {lower, selected, unused}.each { |item| checks.manifest(item, "module #{item.path}\n") }
        checks.trees([selected, unused]) { checkout }
        checks.write

        manifests = [lower, selected]
        Iyi::Mod::Sum.stale("app", [selected], manifests).should eq [
          "example.test/user/unused v1.0.0",
          "example.test/user/unused v1.0.0/iyi.mod",
        ]
        Iyi::Mod::Sum.prune("app", [selected], manifests).should eq 2
        kept = File.read("app/iyi.sum")
        kept.should contain("example.test/user/liba v1.0.0/iyi.mod ")
        kept.should contain("example.test/user/liba v1.1.0/iyi.mod ")
        kept.should contain("example.test/user/liba v1.1.0 h2:")
        kept.should_not contain("example.test/user/unused")
      end
    end
  end

  describe "checking trees" do
    it "records a requirement with no entry as `h2:`, and is silent when it matches" do
      with_tempdir do
        checkout = tree "liba", {"liba.iyi" => "x\n"}
        Dir.mkdir "app"
        picked = [selection("example.test/user/liba", "1.0.0")]

        check_trees("app", picked) { checkout }
        written = File.read("app/iyi.sum")
        written.should eq "example.test/user/liba v1.0.0 #{Iyi::Mod::Sum.tree_hash(checkout)}\n"
        written.should match(/ h2:[0-9a-f]{64}\n\z/)

        check_trees("app", picked) { checkout }
        File.read("app/iyi.sum").should eq written
      end
    end

    it "refuses a checkout that is not what its `h2:` line says" do
      with_tempdir do
        checkout = tree "liba", {"liba.iyi" => "x\n"}
        Dir.mkdir "app"
        picked = [selection("example.test/user/liba", "1.0.0")]
        check_trees("app", picked) { checkout }
        written = File.read("app/iyi.sum")

        File.write "liba/liba.iyi", "y\n"
        expect_raises(Iyi::Mod::ModError, /is not what it was/) do
          check_trees("app", picked) { checkout }
        end
        File.read("app/iyi.sum").should eq written
      end
    end

    # An `s1:` line could not tell two trees apart, so it is not left in
    # the file - but it is held to its checkout the way it was written
    # first, or the build after an upgrade would pin whatever it found.
    it "refuses a checkout that is not what its `s1:` line says, and writes nothing" do
      with_tempdir do
        checkout = tree "liba", {"sub/liba.iyi" => "x\n"}
        Dir.mkdir "app"
        written = "example.test/user/liba v1.0.0 #{unframed({"sub/liba.iyi" => "y\n"})}\n"
        File.write "app/iyi.sum", written

        expect_raises(Iyi::Mod::ModError, /is not what it was: .* says s1:[0-9a-f]{40}, the checkout hashes to #{unframed({"sub/liba.iyi" => "x\n"})}\./) do
          check_trees("app", [selection("example.test/user/liba", "1.0.0")]) { checkout }
        end
        File.read("app/iyi.sum").should eq written
      end
    end

    it "writes an `s1:` line its checkout matches again as `h2:`" do
      with_tempdir do
        checkout = tree "liba", {"sub/liba.iyi" => "x\n", "iyi.mod" => "module example.test/user/liba\n"}
        Dir.mkdir "app"
        File.write "app/iyi.sum", <<-SUM
          example.test/user/liba v1.0.0 #{unframed({"sub/liba.iyi" => "x\n", "iyi.mod" => "module example.test/user/liba\n"})}
          example.test/user/libz v2.0.0 s1:f6b216a60000000000000000000000000000dead

          SUM

        check_trees("app", [selection("example.test/user/liba", "1.0.0")]) { checkout }
        # The line for a version this build did not use is not this build's
        # to restate: nothing was checked out to hash.
        File.read("app/iyi.sum").should eq <<-SUM
          example.test/user/liba v1.0.0 #{Iyi::Mod::Sum.tree_hash(checkout)}
          example.test/user/libz v2.0.0 s1:f6b216a60000000000000000000000000000dead

          SUM
      end
    end

    # The restatement is a courtesy to the next build, and this one has
    # already compared the line. A read-only `iyi.sum` - a mounted source
    # tree, a build as another user - printed "is recorded again" and then
    # failed the build with the system's error.
    it "builds under matching `s1:` lines it cannot write again, and says so" do
      with_tempdir do
        checkout = tree "liba", {"sub/liba.iyi" => "x\n"}
        Dir.mkdir "app"
        written = "example.test/user/liba v1.0.0 #{unframed({"sub/liba.iyi" => "x\n"})}\n"
        File.write "app/iyi.sum", written
        File.chmod "app/iyi.sum", 0o444
        begin
          # An administrator on POSIX writes it whatever its mode says.
          pending! "this user writes a read-only file" if File::Info.writable?("app/iyi.sum")

          notices = IO::Memory.new
          check_trees("app", [selection("example.test/user/liba", "1.0.0")], notices) { checkout }
          said = notices.to_s
          said.should match(/iyi\.sum: 1 entry said `s1:`.* it matched its checkout and could not be recorded again as `h2:`: the file could not be written \(.+[^.]\)\. The build goes on under the `s1:` line\n\z/)
          said.should_not contain("is recorded again")
          File.read("app/iyi.sum").should eq written

          # A requirement with no line is not a restatement: it has to be
          # recorded, and a file that cannot take it fails as it did.
          expect_raises(File::Error) do
            check_trees("app", [selection("example.test/user/liba", "1.0.0"),
                                selection("example.test/user/libz", "2.0.0")], notices) { checkout }
          end
          notices.to_s.should eq said
          File.read("app/iyi.sum").should eq written
        ensure
          File.chmod "app/iyi.sum", 0o644
        end

        # Writable again, it is written and only then said.
        notices = IO::Memory.new
        check_trees("app", [selection("example.test/user/liba", "1.0.0")], notices) { checkout }
        notices.to_s.should match(/1 entry said `s1:`.* it matched its checkout and is recorded again as `h2:`\n\z/)
        File.read("app/iyi.sum").should eq "example.test/user/liba v1.0.0 #{Iyi::Mod::Sum.tree_hash(checkout)}\n"
      end
    end

    # A dependency's own `iyi.sum`, read where the dependency was fetched
    # to: nothing is written under the cache's `mod/`, so the line is not
    # restated there, and for a while it was not compared either - a line
    # of forty zeros passed.
    it "holds an `s1:` line to its checkout inside the module cache, and writes nothing there" do
      with_tempdir do
        checkout = tree "liba", {"sub/liba.iyi" => "x\n"}
        cached = File.join(Iyi::CacheDir.instance.join("mod"), "spec-sum-#{Random::Secure.hex(8)}@v1.0.0")
        Dir.mkdir_p cached
        begin
          sum = File.join(cached, "iyi.sum")
          picked = [selection("example.test/user/liba", "1.0.0")]
          held = unframed({"sub/liba.iyi" => "x\n"})

          wrong = "example.test/user/liba v1.0.0 s1:#{"0" * 40}\n"
          File.write sum, wrong
          expect_raises(Iyi::Mod::ModError, /is not what it was: .* says s1:0{40}, the checkout hashes to #{held}\./) do
            check_trees(cached, picked) { checkout }
          end
          File.read(sum).should eq wrong

          right = "example.test/user/liba v1.0.0 #{held}\n"
          File.write sum, right
          check_trees(cached, picked) { checkout }
          File.read(sum).should eq right
        ensure
          FileUtils.rm_rf cached
        end
      end
    end

    it "refuses a line that is neither" do
      with_tempdir do
        checkout = tree "liba", {"liba.iyi" => "x\n"}
        Dir.mkdir "app"
        File.write "app/iyi.sum", "example.test/user/liba v1.0.0 md5:00\n"
        expect_raises(Iyi::Mod::ModError, /not a sum line.*h2:/) do
          check_trees("app", [selection("example.test/user/liba", "1.0.0")]) { checkout }
        end
      end
    end
  end
end
