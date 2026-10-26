require "../../spec_helper"
require "compiler/iyi/stale/trace"
require "compiler/iyi/stale/encoding"

module TraceSpecHelpers
  def self.encode_record(type : UInt8, task : UInt64, & : IO ->) : Bytes
    payload_io = IO::Memory.new
    payload_io.write_byte(type)
    payload_io.write_bytes(task, IO::ByteFormat::LittleEndian)
    yield payload_io
    payload = payload_io.to_slice

    rec_io = IO::Memory.new
    rec_io.write_bytes(payload.size.to_u32, IO::ByteFormat::LittleEndian)
    rec_io.write(payload)
    rec_io.to_slice
  end

  def self.encode_end(status : Int32, task : UInt64 = 0_u64) : Bytes
    encode_record(Iyi::Stale::Trace::TYPE_END, task) do |io|
      io.write_bytes(status, IO::ByteFormat::LittleEndian)
    end
  end

  def self.write_str(io : IO, s : String)
    io.write_bytes(s.bytesize.to_u32, IO::ByteFormat::LittleEndian)
    io.write(s.to_slice)
  end
end

describe "Iyi::Stale S5a: Trace reader and wire format" do
  roots = Iyi::Stale::Roots.new(
    src: "/workspace/project",
    toolchain: "/opt/iyi/share/iyi/src",
    pkg: "/cache/mod",
    scratch: "/tmp/scratch-123"
  )

  it "maps paths to logical roots correctly" do
    roots.map("/workspace/project/src/main.iyi").should eq(Iyi::Stale::RootPath.new("src", "src/main.iyi"))
    roots.map("/opt/iyi/share/iyi/src/iyi/prelude.iyi").should eq(Iyi::Stale::RootPath.new("toolchain", "iyi/prelude.iyi"))
    roots.map("/cache/mod/foo-1.0/lib.iyi").should eq(Iyi::Stale::RootPath.new("pkg", "foo-1.0/lib.iyi"))
    roots.map("/tmp/scratch-123/temp_out.txt").should eq(Iyi::Stale::RootPath.new("scratch", "temp_out.txt"))
    roots.map("/etc/passwd").should eq(Iyi::Stale::RootPath.new("abs", Iyi::Stale::Roots.real("/etc/passwd")))
  end

  it "parses a complete trace with all record types" do
    io = IO::Memory.new

    # 1. FILE record
    file_bytes = TraceSpecHelpers.encode_record(Iyi::Stale::Trace::TYPE_FILE, 0_u64) do |p|
      p.write_byte(1_u8) # kind: file_read
      TraceSpecHelpers.write_str(p, "data.txt")
      TraceSpecHelpers.write_str(p, "/workspace/project/data.txt")
      TraceSpecHelpers.write_str(p, "/workspace/project")
      p.write_bytes(0_u32, IO::ByteFormat::LittleEndian)         # open_flags
      p.write_byte(1_u8)                                         # present
      p.write_byte(1_u8)                                         # ftype (regular file)
      p.write_bytes(100_u64, IO::ByteFormat::LittleEndian)       # size
      p.write_bytes(123456789_i64, IO::ByteFormat::LittleEndian) # mtime_ns
    end
    io.write(file_bytes)

    # 2. DIR record
    dir_bytes = TraceSpecHelpers.encode_record(Iyi::Stale::Trace::TYPE_DIR, 0_u64) do |p|
      TraceSpecHelpers.write_str(p, "fixtures")
      TraceSpecHelpers.write_str(p, "/workspace/project/fixtures")
      TraceSpecHelpers.write_str(p, "/workspace/project")
      p.write_bytes(2_u32, IO::ByteFormat::LittleEndian) # n = 2
      TraceSpecHelpers.write_str(p, "a.txt")
      TraceSpecHelpers.write_str(p, "b.txt")
    end
    io.write(dir_bytes)

    # 3. ENV record
    env_bytes = TraceSpecHelpers.encode_record(Iyi::Stale::Trace::TYPE_ENV, 0_u64) do |p|
      TraceSpecHelpers.write_str(p, "MY_VAR")
      p.write_byte(1_u8) # present
      TraceSpecHelpers.write_str(p, "hello")
      p.write_byte(0_u8) # written_first: false
    end
    io.write(env_bytes)

    # 4. ENVALL record
    envall_bytes = TraceSpecHelpers.encode_record(Iyi::Stale::Trace::TYPE_ENVALL, 0_u64) { |_| }
    io.write(envall_bytes)

    # 5. CWD record
    cwd_bytes = TraceSpecHelpers.encode_record(Iyi::Stale::Trace::TYPE_CWD, 0_u64) do |p|
      TraceSpecHelpers.write_str(p, "/workspace/project")
    end
    io.write(cwd_bytes)

    # 6. HOST record
    host_bytes = TraceSpecHelpers.encode_record(Iyi::Stale::Trace::TYPE_HOST, 0_u64) do |p|
      TraceSpecHelpers.write_str(p, "build-host-1")
    end
    io.write(host_bytes)

    # 7. WRITE inside scratch (no taint)
    write_scratch = TraceSpecHelpers.encode_record(Iyi::Stale::Trace::TYPE_WRITE, 0_u64) do |p|
      p.write_byte(1_u8) # op: create
      TraceSpecHelpers.write_str(p, "/tmp/scratch-123/file.tmp")
      TraceSpecHelpers.write_str(p, "")
      p.write_byte(1_u8) # inside_scratch: true
    end
    io.write(write_scratch)

    # 8. WRITE outside scratch (taints shared-write)
    write_outside = TraceSpecHelpers.encode_record(Iyi::Stale::Trace::TYPE_WRITE, 0_u64) do |p|
      p.write_byte(1_u8) # op: create
      TraceSpecHelpers.write_str(p, "/shared/output.txt")
      TraceSpecHelpers.write_str(p, "")
      p.write_byte(0_u8) # inside_scratch: false
    end
    io.write(write_outside)

    # 9. END record with status 0
    io.write(TraceSpecHelpers.encode_end(0))

    io.rewind
    res = Iyi::Stale::Trace.parse(io, roots, check_disk_after_exit: false)
    res.complete.should be_true
    res.status.should eq(0)
    res.observations.size.should be >= 6

    # Verify taint was recorded for write outside scratch
    res.taints.size.should eq(1)
    res.taints.first.kind.should eq(48_u8)
    res.taints.first.site.should eq("/shared/output.txt")
  end

  it "marks trace incomplete on truncated record (unexpected EOF in length)" do
    io = IO::Memory.new(Slice[0x05_u8, 0x00_u8]) # only 2 bytes instead of 4
    res = Iyi::Stale::Trace.parse(io, roots, check_disk_after_exit: false)
    res.complete.should be_false
    res.incomplete_reason.should eq("truncated record")
  end

  it "marks trace incomplete on truncated record (unexpected EOF in payload)" do
    rec = IO::Memory.new
    rec.write_bytes(100_u32, IO::ByteFormat::LittleEndian) # claims 100 bytes
    rec.write_byte(1_u8)                                   # only 1 byte given
    res = Iyi::Stale::Trace.parse(rec.rewind, roots, check_disk_after_exit: false)
    res.complete.should be_false
    res.incomplete_reason.should eq("truncated record")
  end

  it "marks trace incomplete on missing END" do
    io = IO::Memory.new
    io.write(TraceSpecHelpers.encode_record(Iyi::Stale::Trace::TYPE_CWD, 0_u64) do |p|
      TraceSpecHelpers.write_str(p, "/workspace/project")
    end)
    res = Iyi::Stale::Trace.parse(io.rewind, roots, check_disk_after_exit: false)
    res.complete.should be_false
    res.incomplete_reason.should eq("missing END")
  end

  it "marks trace incomplete on trailing record after END" do
    io = IO::Memory.new
    io.write(TraceSpecHelpers.encode_end(0))
    # Extra record after END:
    io.write(TraceSpecHelpers.encode_record(Iyi::Stale::Trace::TYPE_CWD, 0_u64) do |p|
      TraceSpecHelpers.write_str(p, "/workspace/project")
    end)
    res = Iyi::Stale::Trace.parse(io.rewind, roots, check_disk_after_exit: false)
    res.complete.should be_false
    res.incomplete_reason.should eq("trailing record")
  end

  it "marks trace incomplete on reserved status code" do
    # 127 is command not found
    io = IO::Memory.new
    io.write(TraceSpecHelpers.encode_end(127))
    res = Iyi::Stale::Trace.parse(io.rewind, roots, check_disk_after_exit: false)
    res.complete.should be_false
    res.incomplete_reason.should eq("reserved status: 127")
    res.status.should eq(127)

    # 130 is SIGINT (128 + 2)
    io2 = IO::Memory.new
    io2.write(TraceSpecHelpers.encode_end(130))
    res2 = Iyi::Stale::Trace.parse(io2.rewind, roots, check_disk_after_exit: false)
    res2.complete.should be_false
    res2.incomplete_reason.should eq("reserved status: 130")

    # -1 is abnormal exit
    io3 = IO::Memory.new
    io3.write(TraceSpecHelpers.encode_end(-1))
    res3 = Iyi::Stale::Trace.parse(io3.rewind, roots, check_disk_after_exit: false)
    res3.complete.should be_false
    res3.incomplete_reason.should eq("reserved status: -1")
  end

  it "accepts normal test failure status 1 without marking reserved status" do
    io = IO::Memory.new
    io.write(TraceSpecHelpers.encode_end(1))
    res = Iyi::Stale::Trace.parse(io.rewind, roots, check_disk_after_exit: false)
    res.complete.should be_true
    res.status.should eq(1)
  end

  it "drops reads under scratch and reads of previously written files" do
    io = IO::Memory.new

    # Write to a file outside scratch
    io.write(TraceSpecHelpers.encode_record(Iyi::Stale::Trace::TYPE_WRITE, 0_u64) do |p|
      p.write_byte(1_u8) # create
      TraceSpecHelpers.write_str(p, "/workspace/project/created.txt")
      TraceSpecHelpers.write_str(p, "")
      p.write_byte(0_u8) # outside scratch
    end)

    # Read of the file that was just written -> should be dropped as internal
    io.write(TraceSpecHelpers.encode_record(Iyi::Stale::Trace::TYPE_FILE, 0_u64) do |p|
      p.write_byte(1_u8)
      TraceSpecHelpers.write_str(p, "created.txt")
      TraceSpecHelpers.write_str(p, "/workspace/project/created.txt")
      TraceSpecHelpers.write_str(p, "/workspace/project")
      p.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      p.write_byte(1_u8)
      p.write_byte(1_u8)
      p.write_bytes(50_u64, IO::ByteFormat::LittleEndian)
      p.write_bytes(1000_i64, IO::ByteFormat::LittleEndian)
    end)

    # Read under scratch directory -> should be dropped as internal
    io.write(TraceSpecHelpers.encode_record(Iyi::Stale::Trace::TYPE_FILE, 0_u64) do |p|
      p.write_byte(1_u8)
      TraceSpecHelpers.write_str(p, "scratch.txt")
      TraceSpecHelpers.write_str(p, "/tmp/scratch-123/scratch.txt")
      TraceSpecHelpers.write_str(p, "/tmp/scratch-123")
      p.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      p.write_byte(1_u8)
      p.write_byte(1_u8)
      p.write_bytes(20_u64, IO::ByteFormat::LittleEndian)
      p.write_bytes(2000_i64, IO::ByteFormat::LittleEndian)
    end)

    io.write(TraceSpecHelpers.encode_end(0))

    res = Iyi::Stale::Trace.parse(io.rewind, roots, check_disk_after_exit: false)
    res.complete.should be_true
    # Only the taint observation from write outside scratch should be present; the two reads were dropped
    res.observations.map(&.kind).should eq(["taint"])
  end

  describe "TraceFp" do
    it "computes deterministic digest for observation sequence" do
      ans1 = Iyi::Stale.d("test1") { |e| e.str("val1") }
      ans2 = Iyi::Stale.d("test2") { |e| e.str("val2") }
      obs = [
        Iyi::Stale::Observation.new(0_u64, "file_read", "src", "a.txt", ans1),
        Iyi::Stale::Observation.new(0_u64, "env_get", "env", "PORT", ans2),
      ]
      fp1 = Iyi::Stale::Trace.compute_trace_fp(obs)
      fp2 = Iyi::Stale::Trace.compute_trace_fp(obs)
      fp1.should eq(fp2)

      # Different observation -> different fp
      ans3 = Iyi::Stale.d("test3") { |e| e.str("val3") }
      obs2 = [
        Iyi::Stale::Observation.new(0_u64, "file_read", "src", "a.txt", ans3),
        Iyi::Stale::Observation.new(0_u64, "env_get", "env", "PORT", ans2),
      ]
      fp3 = Iyi::Stale::Trace.compute_trace_fp(obs2)
      fp3.should_not eq(fp1)
    end
  end

  describe "Keyer modes" do
    it "keys env and abs observations in local mode, but not in portable mode" do
      key = Bytes.new(32, 0x42_u8)
      local_keyer = Iyi::Stale::Keyer.local(key)
      port_keyer = Iyi::Stale::Keyer.portable

      ans_local = Iyi::Stale::Trace.compute_answer("env_get", "env", local_keyer) { |e| e.str("foo") }
      ans_port = Iyi::Stale::Trace.compute_answer("env_get", "env", port_keyer) { |e| e.str("foo") }
      ans_local.should_not eq(ans_port)

      ans_abs_local = Iyi::Stale::Trace.compute_answer("file_stat", "abs", local_keyer) { |e| e.str("bar") }
      ans_abs_port = Iyi::Stale::Trace.compute_answer("file_stat", "abs", port_keyer) { |e| e.str("bar") }
      ans_abs_local.should_not eq(ans_abs_port)

      # Non-env and non-abs roots are identical between local and portable
      ans_src_local = Iyi::Stale::Trace.compute_answer("file_stat", "src", local_keyer) { |e| e.str("bar") }
      ans_src_port = Iyi::Stale::Trace.compute_answer("file_stat", "src", port_keyer) { |e| e.str("bar") }
      ans_src_local.should eq(ans_src_port)
    end
  end

  describe "replay" do
    it "replays matching observations with nil and detects file changes" do
      tmp_dir = "/tmp/iyi_replay_spec_#{Process.pid}"
      Dir.mkdir_p(tmp_dir)
      file_path = File.join(tmp_dir, "test.txt")
      File.write(file_path, "initial content")

      roots_local = Iyi::Stale::Roots.new(src: tmp_dir, toolchain: "", pkg: "", scratch: "")
      keyer = Iyi::Stale::Keyer.portable
      content_hash = Iyi::Stale::Trace.hash_bytes("initial content".to_slice)

      ans = Iyi::Stale::Trace.compute_answer("file_read", "src", keyer) do |enc|
        enc.uint(0_u64)
        enc.bool(true)
        enc.uint(1_u64)
        enc.uint(15_u64)
        enc.digest(content_hash)
      end

      obs = [
        Iyi::Stale::Observation.new(0_u64, "file_read", "src", "test.txt", ans),
      ]

      # Replay with matching content
      Iyi::Stale::Trace.replay(obs, keyer, roots_local).should be_nil

      # Modify file content
      File.write(file_path, "changed content")
      mismatch = Iyi::Stale::Trace.replay(obs, keyer, roots_local)
      mismatch.should_not be_nil
      mismatch.not_nil!.should eq("run: test.txt changed")

      # Cleanup
      File.delete(file_path)
      Dir.delete(tmp_dir)
    end

    it "replays a cwd record against the recorded directory, not the runner's cwd" do
      tmp_dir = File.realpath(Dir.tempdir) + "/iyi_replay_cwd_#{Process.pid}"
      Dir.mkdir_p(File.join(tmp_dir, "sub"))
      roots_local = Iyi::Stale::Roots.new(src: tmp_dir, toolchain: "", pkg: "", scratch: "")
      keyer = Iyi::Stale::Keyer.portable
      ans = Iyi::Stale::Trace.compute_answer("cwd", "src", keyer) do |enc|
        enc.str("src")
        enc.str("sub")
      end
      obs = [Iyi::Stale::Observation.new(0_u64, "cwd", "src", "sub", ans)]

      # The runner never stands in tmp_dir/sub, and the record still holds.
      Dir.current.should_not eq(File.join(tmp_dir, "sub"))
      Iyi::Stale::Trace.replay(obs, keyer, roots_local).should be_nil

      # The directory the program stood in is gone: the run is not the same.
      Dir.delete(File.join(tmp_dir, "sub"))
      Iyi::Stale::Trace.replay(obs, keyer, roots_local).should eq("run: cwd sub is gone")

      Dir.delete(tmp_dir)
    end
  end

  describe "parse_file" do
    it "parses a real trace file written by std/observe" do
      hex = "1900000003000000000000000003000000464f4f0103000000626172000900000004000000000000000016000000050000000000000000090000002f746573742f6469721600000006000000000000000009000000746573742d686f737420000000070000000000000000010d0000002f746573742f6f75742e74787400000000001d000000080000000000000000200f0000007372633a746573742e6979693a31300d0000007f000000000000000000000000"
      tmp_trace = File.join(Dir.tempdir, "trace_parse_test_#{Process.pid}.bin")
      File.write(tmp_trace, hex.hexbytes)

      res = Iyi::Stale::Trace.parse_file(tmp_trace, roots, check_disk_after_exit: false)
      File.delete(tmp_trace)

      res.complete.should be_true
      res.status.should eq(0)
      res.observations.size.should eq(6)
      res.observations.map(&.kind).should eq(["env_get", "env_all", "cwd", "host", "taint", "taint"])
    end
  end
end
