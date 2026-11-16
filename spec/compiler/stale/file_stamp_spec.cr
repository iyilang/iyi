require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/stale/fast_record"

describe Iyi::Stale::FileStamp do
  it "trusts only local NTFS on a current Windows build" do
    {
      {"NTFS", false, 17763, 3_u32, true},
      {"NTFS", false, 17134, 3_u32, false},
      {"NTFS", true, 26100, 3_u32, false},
      {"NTFS", false, 26100, 0_u32, false}, # unknown or path lookup failed
      {"NTFS", false, 26100, 2_u32, false}, # removable
      {"NTFS", false, 26100, 4_u32, false}, # remote
      {"ReFS", false, 26100, 3_u32, false},
      {"FAT32", false, 26100, 3_u32, false},
      {"exFAT", false, 26100, 3_u32, false},
      {"", false, 26100, 3_u32, false},
    }.each do |filesystem, remote, build, drive_type, expected|
      Iyi::Stale::FileStamp.trusted_volume?(filesystem, remote, build, drive_type).should eq(expected)
    end
  end

  it "checks locality for every handle even when volume serials match" do
    serial = 0x3141592653589793_u64
    probes = 0
    local = Iyi::Stale::FileStamp.volume_trusted?(serial) do
      probes += 1
      {"NTFS", false, 26100, 3_u32}
    end
    shared = Iyi::Stale::FileStamp.volume_trusted?(serial) do
      probes += 1
      {"NTFS", true, 26100, 4_u32}
    end
    local.should be_true
    shared.should be_false
    probes.should eq(2)
    Iyi::Stale::FileStamp.volume_trusted?(serial) { {"NTFS", true, 26100, 3_u32} }.should be_false
    Iyi::Stale::FileStamp.volume_trusted?(serial) { {"NTFS", false, 26100, 4_u32} }.should be_false
    Iyi::Stale::FileStamp.volume_trusted?(serial) { {"", true, 0, 0_u32} }.should be_false
  end

  it "round trips UInt64 identities in both v2 record formats and refuses v1" do
    with_tempfile("stale-stamp-inputs.json") do |path|
      stamp = Iyi::BuildInputs::Stamp.new(Iyi::BuildInputs::Kind::File, 1_i64, 2_i64, nil,
        3_i64, UInt64::MAX, UInt64::MAX)
      inputs = Iyi::BuildInputs.new(nil, stale: true)
      inputs.files["large-id.iyi"] = stamp
      Iyi::Stale::InputsFile.write(path, inputs, "local", "portable")
      original = File.read(path)
      values = JSON.parse(original)["files"].as_a.first.as_a
      values[5].as_s.should eq(UInt64::MAX.to_s)
      values[6].as_s.should eq(UInt64::MAX.to_s)

      test_id = Iyi::Stale::TestId.new("src", "large-id.iyi")
      facts = Iyi::Stale::FastFacts.new("cwd", "target", 1, [] of Iyi::Stale::FastEntry, {} of String => String)
      record = Iyi::Stale::FastRecord.from_inputs(path, test_id, "large-id.iyi", facts, "local", "portable").not_nil!
      record.files.first.stamp.dev.should eq(UInt64::MAX)
      record.files.first.stamp.ino.should eq(UInt64::MAX)
      json = record.to_store_json
      parsed = Iyi::Stale::FastRecord.parse(json).not_nil!
      parsed.files.first.stamp.dev.should eq(UInt64::MAX)
      parsed.files.first.stamp.ino.should eq(UInt64::MAX)
      Iyi::Stale::FastRecord.parse(json.sub(%("version":2), %("version":1))).should be_nil
      File.write(path, original.sub(%("version":2), %("version":1)))
      Iyi::Stale::FastRecord.from_inputs(path, test_id, "large-id.iyi", facts, "local", "portable").should be_nil
    end
  end

  it "never serves a record with an untrusted compiler stamp" do
    stamp = Iyi::BuildInputs::Stamp.new(Iyi::BuildInputs::Kind::File, 1_i64, 2_i64)
    compiler = [Iyi::Stale::FastEntry.new("compiler", stamp)]
    facts = Iyi::Stale::FastFacts.new("cwd", "target", 1, compiler, {} of String => String)
    record = Iyi::Stale::FastRecord.new(Iyi::Stale::TestId.new("src", "x"), "x", "cwd", "local", "portable",
      "target", 1, compiler, {} of String => String?, false, [] of Iyi::Stale::FastEntry,
      {} of String => Array(String)?, [] of Iyi::Stale::FastPkgConfig)
    record.unchanged_reason("x", facts, Set(String).new).not_nil!.should contain("no trusted change time")
  end

  it "preserves a missing LLVM identity as a refusal even during an audit" do
    reason = "loaded LLVM-C.dll cannot be identified"
    compiler = [] of Iyi::Stale::FastEntry
    facts = Iyi::Stale::FastFacts.new("cwd", "target", 1, compiler, {} of String => String, reason)
    record = Iyi::Stale::FastRecord.new(Iyi::Stale::TestId.new("src", "x"), "x", "cwd", "local", "portable",
      "target", 1, compiler, {} of String => String?, false, [] of Iyi::Stale::FastEntry,
      {} of String => Array(String)?, [] of Iyi::Stale::FastPkgConfig)
    record.unchanged_reason("x", facts, Set{"compiler"}).should eq(reason)
  end

  {% if flag?(:unix) %}
    it "refuses a FIFO input instead of serving its unchanged metadata" do
      with_tempfile("stale-input.fifo") do |path|
        LibC.mkfifo(path, 0o600).should eq(0)
        inputs = Iyi::BuildInputs.new(nil, stale: true)
        inputs.looked_at(path)
        stamp = inputs.files[Iyi::BuildInputs.key(path)]
        stamp.kind.other?.should be_true
        inputs.reasons.any?(&.includes?("not a regular file or directory")).should be_true
        Iyi::Stale::FastRecord.changed?(stamp, stamp, path, Set(String).new).should be_true
      end
    end
  {% end %}

  {% if flag?(:win32) %}
    it "observes a write before the writer closes and not an unchanged read" do
      with_tempfile("win-open-write.txt") do |path|
        File.write(path, "aaaa")
        sleep 250.milliseconds
        File.open(path, "r+") do |writer|
          before = Iyi::Stale::FileStamp.of(path)
          before.ctime.should be > 0
          File.read(path).should eq("aaaa")
          after_read = Iyi::Stale::FileStamp.of(path)
          {after_read.mtime, after_read.ctime, after_read.dev, after_read.ino}.should eq({before.mtime, before.ctime, before.dev, before.ino})
          writer.write("bbbb".to_slice)
          writer.flush
          after_write = Iyi::Stale::FileStamp.of(path)
          after_write.ctime.should_not eq(before.ctime)
        end
      end
    end

    it "sees restored mtime and rename through change time and file id" do
      with_tempfile("win-stamp.txt", "win-stamp-new.txt") do |path, replacement|
        File.write(path, "aaaa")
        sleep 250.milliseconds
        before = Iyi::Stale::FileStamp.of(path)
        before.ctime.should be > 0
        timestamp = File.info(path).modification_time
        File.write(path, "bbbb")
        File.utime(timestamp, timestamp, path)
        changed = Iyi::Stale::FileStamp.of(path)
        changed.mtime.should eq(before.mtime)
        changed.ctime.should_not eq(before.ctime)
        File.write(replacement, "cccc")
        File.rename(replacement, path)
        Iyi::Stale::FileStamp.of(path).ino.should_not eq(changed.ino)
      end
    end

    it "includes the loaded LLVM DLL in toolchain paths" do
      Iyi::Stale::Toolchain.paths.any? { |path| File.basename(path).downcase == "llvm-c.dll" }.should be_true
    end
  {% end %}
end
