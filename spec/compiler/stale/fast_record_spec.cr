require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/fast_record"
require "file_utils"

# The directories the examples below made, removed once each has ended. They
# were left behind: 28 of them stood in the temporary directory after a few
# runs of this file.
FAST_SPEC_DIRS = [] of String

Spec.after_each do
  FAST_SPEC_DIRS.each { |dir| FileUtils.rm_rf(dir) }
  FAST_SPEC_DIRS.clear
end

private def fast_dir : String
  dir = File.tempname("iyi-fast")
  Dir.mkdir_p(dir)
  FAST_SPEC_DIRS << dir
  dir
end

private def fast_test : Iyi::Stale::TestId
  Iyi::Stale::TestId.new("src", "fast_test.iyi")
end

private def fast_facts(cwd : String, env : Hash(String, String) = {} of String => String,
                       compiler : Array(Iyi::Stale::FastEntry) = [] of Iyi::Stale::FastEntry,
                       target : String = "x86_64-linux-gnu", workers : Int32 = 4) : Iyi::Stale::FastFacts
  Iyi::Stale::FastFacts.new(cwd, target, workers, compiler, env)
end

# A record of a build of *source* that read *files* and the environment
# *observed*, stamped as the files are now.
private def fast_record(facts : Iyi::Stale::FastFacts, source : String,
                        files : Array(String) = [] of String,
                        observed : Hash(String, String?) = {} of String => String?,
                        enumerated : Bool = false,
                        listings : Hash(String, Array(String)?) = {} of String => Array(String)?) : Iyi::Stale::FastRecord
  entries = files.map { |path| Iyi::Stale::FastEntry.new(path, Iyi::Stale::FileStamp.of(path)) }
  Iyi::Stale::FastRecord.new(fast_test, source, facts.cwd, "local-build", "portable-build",
    facts.target, facts.workers, facts.compiler, observed, enumerated, entries, listings,
    [] of Iyi::Stale::FastPkgConfig)
end

# Sets *path*'s modification time back to *nanoseconds*, leaving its change time
# to the kernel.
private def restore_mtime(path : String, nanoseconds : Int64) : Nil
  time = Time.unix(nanoseconds // 1_000_000_000) + (nanoseconds % 1_000_000_000).nanoseconds
  File.utime(time, time, path)
end

private NO_DROP = Set(String).new

# Ends an example that needs a change time where the file system reports none
# (Windows). There a build that read a file writes no record at all
# (`BuildInputs#looked_at_stale`), so there is no record to ask.
private def needs_change_time(path : String) : Nil
  return if Iyi::Stale::FileStamp.of(path).ctime > 0
  pending!("this file system reports no change time, and a build writes no fast record on it")
end

describe Iyi::Stale::FastRecord do
  it "round trips through its store form and still describes the inputs" do
    dir = fast_dir
    file = File.join(dir, "a.iyi")
    File.write(file, "1")
    facts = fast_facts(dir, {"FAST_X" => "1"})
    record = fast_record(facts, "src/x.iyi", [file], {"FAST_X" => "1"} of String => String?)

    parsed = Iyi::Stale::FastRecord.parse(record.to_store_json).not_nil!
    parsed.unchanged_reason("src/x.iyi", facts, NO_DROP).should be_nil
  end

  it "names a file rewritten with the same size and the same modification time" do
    dir = fast_dir
    file = File.join(dir, "a.iyi")
    File.write(file, "1234")
    needs_change_time(file)
    before = Iyi::Stale::FileStamp.of(file)
    record = fast_record(fast_facts(dir), "src/x.iyi", [file])

    File.write(file, "5678")
    restore_mtime(file, before.mtime)
    after = Iyi::Stale::FileStamp.of(file)
    after.mtime.should eq before.mtime
    after.ctime.should_not eq before.ctime

    record.unchanged_reason("src/x.iyi", fast_facts(dir), NO_DROP).not_nil!.should contain("a.iyi changed")
  end

  it "names a file replaced by rename, even when its size and time match" do
    dir = fast_dir
    file = File.join(dir, "a.iyi")
    File.write(file, "1234")
    needs_change_time(file)
    before = Iyi::Stale::FileStamp.of(file)
    record = fast_record(fast_facts(dir), "src/x.iyi", [file])

    replacement = File.join(dir, "a.iyi.new")
    File.write(replacement, "5678")
    restore_mtime(replacement, before.mtime)
    File.rename(replacement, file)

    record.unchanged_reason("src/x.iyi", fast_facts(dir), NO_DROP).not_nil!.should contain("a.iyi changed")
  end

  it "compares a recorded digest with the content, not only the stamp" do
    dir = fast_dir
    file = File.join(dir, "a.iyi")
    File.write(file, "1234")
    stamp = Iyi::Stale::FileStamp.of(file)
    wrong = Iyi::BuildInputs::Stamp.new(stamp.kind, stamp.size, stamp.mtime, "0" * 32, stamp.ctime, stamp.dev, stamp.ino)
    recorded = Iyi::Stale::FastRecord.new(fast_test, "src/x.iyi", dir, "local-build", "portable-build",
      "x86_64-linux-gnu", 4, [] of Iyi::Stale::FastEntry, {} of String => String?, false,
      [Iyi::Stale::FastEntry.new(file, wrong)], {} of String => Array(String)?, [] of Iyi::Stale::FastPkgConfig)

    recorded.unchanged_reason("src/x.iyi", fast_facts(dir), NO_DROP).not_nil!.should contain("a.iyi changed")
  end

  it "names a listing that gained an entry" do
    dir = fast_dir
    File.write(File.join(dir, "one.iyi"), "1")
    record = fast_record(fast_facts(dir), "src/x.iyi", listings: {dir => Iyi::BuildInputs.children(dir)})

    File.write(File.join(dir, "two.iyi"), "2")
    record.unchanged_reason("src/x.iyi", fast_facts(dir), NO_DROP).not_nil!.should contain("changed")
  end

  it "tells an environment value that is absent from one that is empty" do
    dir = fast_dir
    record = fast_record(fast_facts(dir), "src/x.iyi", observed: {"FAST_X" => nil} of String => String?)

    reason = record.unchanged_reason("src/x.iyi", fast_facts(dir, {"FAST_X" => ""}), NO_DROP)
    reason.should eq "environment changed: FAST_X"
  end

  it "names a new variable when the build enumerated the environment" do
    dir = fast_dir
    record = fast_record(fast_facts(dir, {"A" => "1"}), "src/x.iyi",
      observed: {"A" => "1"} of String => String?, enumerated: true)

    reason = record.unchanged_reason("src/x.iyi", fast_facts(dir, {"A" => "1", "NEW" => "2"}), NO_DROP)
    reason.should eq "environment changed: NEW"
  end

  it "names the compiler when one of its files changed" do
    dir = fast_dir
    compiler_file = File.join(dir, "iyi")
    File.write(compiler_file, "compiler v1")
    entries = [Iyi::Stale::FastEntry.new(compiler_file, Iyi::Stale::FileStamp.of(compiler_file))]
    record = fast_record(fast_facts(dir, compiler: entries), "src/x.iyi")

    File.write(compiler_file, "compiler v2 is longer")
    now = [Iyi::Stale::FastEntry.new(compiler_file, Iyi::Stale::FileStamp.of(compiler_file))]
    record.unchanged_reason("src/x.iyi", fast_facts(dir, compiler: now), NO_DROP).not_nil!.should contain("compiler")
  end

  it "names a change of host target or worker count" do
    dir = fast_dir
    record = fast_record(fast_facts(dir), "src/x.iyi")

    record.unchanged_reason("src/x.iyi", fast_facts(dir, target: "aarch64-darwin"), NO_DROP).should eq "the host target changed"
    record.unchanged_reason("src/x.iyi", fast_facts(dir, workers: 2), NO_DROP).should eq "the worker count changed"
  end

  it "names a change of working directory or file argument" do
    dir = fast_dir
    record = fast_record(fast_facts(dir), "src/x.iyi")

    record.unchanged_reason("src/x.iyi", fast_facts(File.join(dir, "elsewhere")), NO_DROP).should eq "the working directory changed"
    record.unchanged_reason("other/x.iyi", fast_facts(dir), NO_DROP).should eq "the build's file argument changed"
  end

  it "reports a recorded refusal as the reason, and never serves it" do
    dir = fast_dir
    record = Iyi::Stale::FastRecord.refused(fast_test, "src/x.iyi", fast_facts(dir), "local-build",
      "portable-build", "a macro ran a program, `run(\"gen\")`, and what it read cannot be listed")

    record.unchanged_reason("src/x.iyi", fast_facts(dir), NO_DROP).not_nil!.should contain("a macro ran a program")
  end

  it "takes a record of another version or format as absent" do
    dir = fast_dir
    record = fast_record(fast_facts(dir), "src/x.iyi")
    stale = record.to_store_json.sub("\"version\":1", "\"version\":0")

    Iyi::Stale::FastRecord.parse(stale).should be_nil
    Iyi::Stale::FastRecord.parse(record.to_store_json.sub("iyi-stale-fast", "iyi-stale-key")).should be_nil
  end

  it "takes corrupt JSON as absent" do
    Iyi::Stale::FastRecord.parse("{").should be_nil
    Iyi::Stale::FastRecord.parse("").should be_nil
  end

  it "does not count a directory whose times moved" do
    dir = fast_dir
    sub = File.join(dir, "lib")
    Dir.mkdir_p(sub)
    before = Iyi::Stale::FileStamp.of(sub)
    record = fast_record(fast_facts(dir), "src/x.iyi", [sub])

    File.write(File.join(sub, "sibling.iyi"), "moved")
    moved = Iyi::Stale::FileStamp.of(sub)
    moved.kind.should eq before.kind

    record.unchanged_reason("src/x.iyi", fast_facts(dir), NO_DROP).should be_nil
  end

  it "reads and writes the record of a test through the store, and takes a missing or corrupt one as absent" do
    dir = fast_dir
    store = Iyi::Stale::Store.new(dir)
    store.ensure_directories!
    test = fast_test
    Iyi::Stale::FastRecord.read(store, test).should be_nil

    store.write_fast(test, fast_record(fast_facts(dir), "src/x.iyi").to_store_json)
    Iyi::Stale::FastRecord.read(store, test).not_nil!.test.should eq test

    File.write(store.fast_path(test), "{")
    Iyi::Stale::FastRecord.read(store, test).should be_nil
  end
end

describe Iyi::Stale::Runner do
  it "ignores the drop switch unless the audit is on" do
    Iyi::Stale::Runner.fast_drop(false, "ctime").should eq Set(String).new
    Iyi::Stale::Runner.fast_drop(true, "ctime").should eq Set{"ctime"}
    Iyi::Stale::Runner.fast_drop(true, nil).should eq Set(String).new
  end
end
