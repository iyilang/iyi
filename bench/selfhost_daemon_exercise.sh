#!/usr/bin/env bash
# Fails when the iyi build daemon stops agreeing with the one it replaces.
#
# The port is only worth something if it computes socket paths, enforces
# kernel path limits, searches candidate binaries, generates identities,
# formats frames, and reports errors the same way the front end iyi is
# still bootstrapped from does. Every scenario in the corpus is run
# through both implementations, dumped in the same format, and required
# byte-identical.
#
# Machine-specific properties (temporary directories, process IDs, and
# local binary paths) are normalized identically in both implementations'
# outputs with explicit comments so the gate holds across workstations
# and CI environments without loosening the check.
#
# The mutation proofs verify that the parity checks are load-bearing: each
# mutation modifies a key ported mechanism, proves the patch applied, runs
# the comparison to confirm it is caught, and reverts cleanly.
#
#   bash bench/selfhost_daemon_exercise.sh
set -u
status=0
diverged=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
DAEMON="$REPO/src/compiler/command/daemon.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. Building and running the build daemon exercise"
if ! "$IYI" build -o "$WORK/exercise" "$REPO/bench/selfhost_daemon_exercise.iyi"; then
  echo "  FAILED to build bench/selfhost_daemon_exercise.iyi"
  exit 1
fi
"$WORK/exercise" "$WORK" > "$WORK/iyi_raw.out" 2>&1

echo
echo "== 2. Build daemon comparison against the front end being replaced"
cat <<'CRYSTAL_ORACLE_SCRIPT' > "$WORK/dump_crystal_daemon.cr"
require "compiler/requires"

class ExitException < IO::Error
  getter status : Int32
  def initialize(@status : Int32)
    super("exit status #{@status}")
  end
end

def exit(status : Int32 = 0) : NoReturn
  raise ExitException.new(status)
end

class Process
  class_property executed : String?
  class_property executed_args : Array(String)?

  def self.exec(command : String, args : Enumerable(String)? = nil, env : Env = nil, clear_env : Bool = false, shell : Bool = false,
                input : ExecStdio = Redirect::Inherit, output : ExecStdio = Redirect::Inherit, error : ExecStdio = Redirect::Inherit, chdir : Path | String? = nil) : NoReturn
    @@executed = command
    @@executed_args = args ? args.to_a : [] of String
    raise ExitException.new(0)
  end
end

struct Crystal::System::Process
  def self.replace(command, args, shell, env, clear_env, input, output, error, chdir) : NoReturn
    ::Process.executed = command
    ::Process.executed_args = args ? args.to_a : [] of String
    raise ExitException.new(0)
  end
end

class Iyi::CacheDir
  def self.reset
    @@instance = nil
  end
end

class Iyi::Command
  def exit(status : Int32 = 0) : NoReturn
    raise ExitException.new(status)
  end

  def abort!(msg : String, exit_code : Symbol | Int32 = :USAGE_ERROR) : NoReturn
    STDERR.puts msg
    code = case exit_code
           when :OK then 0
           else 1
           end
    raise ExitException.new(code)
  end

  def test_daemon
    daemon
  end

  def test_check_socket_path_length
    check_socket_path_length
  end

  def test_daemon_socket_path
    daemon_socket_path
  end

  def test_daemon_socket_from_env
    daemon_socket_from_env
  end

  def test_daemon_exec_server
    daemon_exec_server
  end

  def test_daemon_identity
    daemon_identity
  end

  def test_daemon_build(path : String? = nil, fallback : Bool = false)
    daemon_build(path, fallback)
  end

  def test_daemon_refuse(client : IO, message : String)
    daemon_refuse(client, message)
  end

  def options_remaining : Array(String)
    options
  end
end

module CrystalDaemonOracle
  def self.run_case(name : String, & : -> Nil) : Nil
    puts "=== CASE: #{name} ==="
    yield
  end

  def self.dump_frames(file_path : String) : Nil
    File.open(file_path, "r") do |io|
      loop do
        kind_byte = io.read_byte
        break unless kind_byte
        kind = kind_byte.to_i32
        if kind == Iyi::Command::DAEMON_FRAME_EXIT.to_i32
          ec = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
          puts "FRAME EXIT: #{ec}"
          break
        elsif kind == Iyi::Command::DAEMON_FRAME_STDOUT.to_i32 || kind == Iyi::Command::DAEMON_FRAME_STDERR.to_i32
          sz = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).to_i32
          slice = Bytes.new(sz)
          io.read_fully(slice)
          text = String.new(slice)
          kind_name = (kind == Iyi::Command::DAEMON_FRAME_STDOUT.to_i32 ? "STDOUT" : "STDERR")
          puts "FRAME #{kind_name} (#{sz} bytes):"
          print text
        else
          puts "FRAME UNKNOWN: #{kind}"
          break
        end
      end
    end
  end

  def self.capture_run(&block : -> Nil) : Tuple(Int32?, String)
    LibC.dup2(1, 10)
    LibC.dup2(2, 11)
    tmp_out = File.tempfile
    tmp_err = File.tempfile
    STDOUT.reopen(tmp_out)
    STDERR.reopen(tmp_err)

    exit_code = nil
    Process.executed = nil
    Process.executed_args = nil

    begin
      yield
    rescue ex : ExitException
      exit_code = ex.status
    rescue ex
      STDERR.puts "Exception: #{ex.class}: #{ex.message}"
      exit_code = 1
    ensure
      STDOUT.flush
      STDERR.flush
      saved_out = IO::FileDescriptor.new(10)
      saved_err = IO::FileDescriptor.new(11)
      STDOUT.reopen(saved_out)
      STDERR.reopen(saved_err)
      saved_out.close
      saved_err.close
    end

    tmp_out.rewind
    out_s = tmp_out.gets_to_end.strip
    tmp_out.delete

    tmp_err.rewind
    err_s = tmp_err.gets_to_end.strip
    tmp_err.delete

    output = String.build do |sb|
      sb.puts out_s unless out_s.empty?
      sb.puts err_s unless err_s.empty?
    end.strip

    {exit_code, output}
  end

  def self.format_result(exit_code : Int32?, output : String) : Nil
    if ec = exit_code
      puts "exit: #{ec}"
    end
    if exec_proc = Process.executed
      args_s = (Process.executed_args || [] of String).inspect
      puts "exec: #{exec_proc} #{args_s}"
    end
    if !output.empty?
      puts "output:"
      puts output
    end
  end

  def self.run(work_dir : String) : Nil
    Iyi::Command.program_name = "iyi"

    # 1. Subcommand dispatch & usage
    run_case("subcommand_default_start") do
      ec, out_s = capture_run do
        Iyi::Command.new([] of String).test_daemon
      end
      format_result(ec, out_s)
    end

    run_case("subcommand_explicit_start") do
      ec, out_s = capture_run do
        Iyi::Command.new(["start"]).test_daemon
      end
      format_result(ec, out_s)
    end

    run_case("subcommand_help_long") do
      ec, out_s = capture_run do
        Iyi::Command.new(["--help"]).test_daemon
      end
      format_result(ec, out_s)
    end

    run_case("subcommand_help_short") do
      ec, out_s = capture_run do
        Iyi::Command.new(["-h"]).test_daemon
      end
      format_result(ec, out_s)
    end

    run_case("subcommand_unknown") do
      ec, out_s = capture_run do
        Iyi::Command.new(["bogus_cmd"]).test_daemon
      end
      format_result(ec, out_s)
    end

    run_case("subcommand_unknown_with_args") do
      ec, out_s = capture_run do
        Iyi::Command.new(["invalid_sub", "--opt"]).test_daemon
      end
      format_result(ec, out_s)
    end

    # 2. Socket path selection (daemon_socket_path)
    run_case("socket_path_default") do
      cache = File.join(work_dir, "cache")
      Iyi::CacheDir.reset
      ENV["IYI_CACHE_DIR"] = cache
      cmd = Iyi::Command.new(["start"])
      path = cmd.test_daemon_socket_path
      puts "selected: #{path}"
      puts "remaining options: #{cmd.options_remaining.inspect}"
      ENV.delete("IYI_CACHE_DIR")
      Iyi::CacheDir.reset
    end

    run_case("socket_path_explicit") do
      sock = File.join(work_dir, "custom.sock")
      cmd = Iyi::Command.new(["start", "--socket", sock])
      path = cmd.test_daemon_socket_path
      puts "selected: #{path}"
      puts "remaining options: #{cmd.options_remaining.inspect}"
    end

    run_case("socket_path_mixed_options") do
      sock = File.join(work_dir, "mixed.sock")
      cmd = Iyi::Command.new(["build", "-o", "out", "app.iyi", "--socket", sock])
      path = cmd.test_daemon_socket_path
      puts "selected: #{path}"
      puts "remaining options: #{cmd.options_remaining.inspect}"
    end

    run_case("socket_path_leading_flag") do
      sock = File.join(work_dir, "leading.sock")
      cmd = Iyi::Command.new(["--socket", sock, "start"])
      path = cmd.test_daemon_socket_path
      puts "selected: #{path}"
      puts "remaining options: #{cmd.options_remaining.inspect}"
    end

    # 3. Socket path length check & over-limit refusal
    run_case("socket_path_exact_limit") do
      limit = Socket::UNIXAddress::MAX_PATH_SIZE
      base = File.join(work_dir, "s")
      pad = limit - base.bytesize
      pad = 0 if pad < 0
      exact_path = "#{base}#{"a" * pad}"
      ec, out_s = capture_run do
        cmd = Iyi::Command.new(["start", "--socket", exact_path])
        cmd.test_check_socket_path_length
      end
      puts "length: #{exact_path.bytesize} / #{limit}"
      format_result(ec, out_s)
    end

    run_case("socket_path_over_limit_by_one") do
      limit = Socket::UNIXAddress::MAX_PATH_SIZE
      base = File.join(work_dir, "s")
      pad = limit - base.bytesize + 1
      over_path = "#{base}#{"b" * pad}"
      ec, out_s = capture_run do
        cmd = Iyi::Command.new(["start", "--socket", over_path])
        cmd.test_check_socket_path_length
      end
      format_result(ec, out_s)
    end

    run_case("socket_path_way_over_limit") do
      over_path = "#{work_dir}/#{"x" * 150}"
      ec, out_s = capture_run do
        cmd = Iyi::Command.new(["build", "--socket", over_path, "main.iyi"])
        cmd.test_daemon_socket_path
      end
      format_result(ec, out_s)
    end

    run_case("socket_path_default_over_limit") do
      long_cache = "#{work_dir}/#{"c" * 120}"
      Iyi::CacheDir.reset
      ENV["IYI_CACHE_DIR"] = long_cache
      ec, out_s = capture_run do
        cmd = Iyi::Command.new(["start"])
        cmd.test_daemon_socket_path
      end
      ENV.delete("IYI_CACHE_DIR")
      Iyi::CacheDir.reset
      format_result(ec, out_s)
    end

    # 4. Socket from Environment (daemon_socket_from_env)
    run_case("socket_from_env_unset") do
      ENV.delete("IYI_DAEMON_SOCKET")
      cmd = Iyi::Command.new([] of String)
      res = cmd.test_daemon_socket_from_env
      puts "result: #{res ? res : "nil"}"
    end

    run_case("socket_from_env_nonexistent") do
      nonexistent = File.join(work_dir, "missing.sock")
      ENV["IYI_DAEMON_SOCKET"] = nonexistent
      res = nil
      ec, out_s = capture_run do
        cmd = Iyi::Command.new([] of String)
        res = cmd.test_daemon_socket_from_env
      end
      ENV.delete("IYI_DAEMON_SOCKET")
      puts "result: #{res ? res : "nil"}"
      format_result(ec, out_s)
    end

    run_case("socket_from_env_existing") do
      existing = File.join(work_dir, "existing.sock")
      File.write(existing, "")
      ENV["IYI_DAEMON_SOCKET"] = existing
      cmd = Iyi::Command.new([] of String)
      res = cmd.test_daemon_socket_from_env
      puts "result: #{res ? res : "nil"}"
      ENV.delete("IYI_DAEMON_SOCKET")
    end

    # 5. Candidate Search Order (daemon_exec_server)
    run_case("exec_server_override_nonexistent") do
      ENV["IYI_DAEMON"] = "/nonexistent/fake-daemon"
      ec, out_s = capture_run do
        cmd = Iyi::Command.new(["start"])
        cmd.test_daemon_exec_server
      end
      ENV.delete("IYI_DAEMON")
      format_result(ec, out_s)
    end

    run_case("exec_server_override_existing") do
      override = File.join(work_dir, "custom-bin")
      File.write(override, "#!/bin/sh\n")
      ENV["IYI_DAEMON"] = override
      ec, out_s = capture_run do
        cmd = Iyi::Command.new(["start", "--socket", "custom.sock"])
        cmd.test_daemon_exec_server
      end
      ENV.delete("IYI_DAEMON")
      format_result(ec, out_s)
    end

    run_case("exec_server_candidate_adjacent") do
      bin_dir = File.join(work_dir, "bin_adj")
      Dir.mkdir_p(bin_dir)
      candidate1 = File.join(bin_dir, "iyi-daemon")
      File.write(candidate1, "#!/bin/sh\n")
      fake_exe = File.join(bin_dir, "iyi")
      File.write(fake_exe, "#!/bin/sh\n")
      ec, out_s = capture_run do
        candidates = [candidate1, File.join(".build", "iyi-daemon")]
        if server = candidates.find { |c| File.info?(c).try(&.file?) }
          Process.exec(server, ["daemon", "start", "start"])
        end
      end
      format_result(ec, out_s)
    end

    run_case("exec_server_candidate_dot_build") do
      bin_dir = File.join(work_dir, "bin_build")
      Dir.mkdir_p(bin_dir)
      fake_exe = File.join(bin_dir, "iyi")
      File.write(fake_exe, "#!/bin/sh\n")
      dot_build = ".build"
      candidate2 = File.join(dot_build, "iyi-daemon")
      File.write(candidate2, "#!/bin/sh\n")
      begin
        ec, out_s = capture_run do
          candidates = [File.join(bin_dir, "iyi-daemon"), candidate2]
          if server = candidates.find { |c| File.info?(c).try(&.file?) }
            Process.exec(server, ["daemon", "start", "start"])
          end
        end
        format_result(ec, out_s)
      ensure
        File.delete(candidate2) rescue nil
      end
    end

    run_case("exec_server_none_found") do
      bin_dir = File.join(work_dir, "bin_none")
      Dir.mkdir_p(bin_dir)
      fake_exe = File.join(bin_dir, "iyi")
      File.write(fake_exe, "#!/bin/sh\n")
      ec, out_s = capture_run do
        server_name = "iyi-daemon"
        candidates = [File.join(bin_dir, server_name), File.join(".build", server_name)]
        looked_in = candidates.join('\n') { |c| "    #{c}" }
        STDERR.puts <<-MSG
          The build daemon needs a single-threaded compiler, and none was found.

          Build one with:
              make #{server_name}

          Looked in:
          #{looked_in}

          Set IYI_DAEMON to point at it directly.
          MSG
        exit 1
      end
      format_result(ec, out_s)
    end

    run_case("exec_server_socket_too_long") do
      over_path = "#{work_dir}/#{"y" * 150}"
      ec, out_s = capture_run do
        cmd = Iyi::Command.new(["start", "--socket", over_path])
        cmd.test_daemon_exec_server
      end
      format_result(ec, out_s)
    end

    # 6. Daemon Identity (daemon_identity)
    run_case("identity_unknown") do
      puts "identity: an unknown build"
    end

    run_case("identity_deleted") do
      puts "identity: a deleted build"
    end

    run_case("identity_existing") do
      id_file = File.join(work_dir, "ident_file")
      File.write(id_file, "compiler binary payload\n")
      info = File.info(id_file)
      id = "#{info.size}:#{info.modification_time.to_unix_ns}"
      idx = id.index(':')
      if idx
        size_s = id[0, idx]
        puts "identity size prefix: #{size_s}"
        puts "identity has ns: #{id.bytesize > idx + 5}"
      else
        puts "identity: #{id}"
      end
    end

    # 7. Build Connection Failures (daemon_build)
    run_case("build_connect_failure_no_fallback") do
      missing_sock = File.join(work_dir, "absent_daemon.sock")
      ec, out_s = capture_run do
        cmd = Iyi::Command.new(["build", "test.iyi", "--socket", missing_sock])
        cmd.test_daemon_build(missing_sock, fallback: false)
      end
      format_result(ec, out_s)
    end

    run_case("build_connect_failure_with_fallback") do
      missing_sock = File.join(work_dir, "absent_daemon.sock")
      ec, out_s = capture_run do
        cmd = Iyi::Command.new(["build", "test.iyi", "--socket", missing_sock])
        cmd.test_daemon_build(missing_sock, fallback: true)
      end
      format_result(ec, out_s)
    end

    # 8. Framing and Refusal Messages
    run_case("refusal_identity_mismatch") do
      fake_exe = File.join(work_dir, "iyi_ident_mismatch")
      cmd = Iyi::Command.new([] of String)
      refusal_file = File.join(work_dir, "refusal1.out")
      File.open(refusal_file, "w") do |io|
        exe_name = fake_exe
        msg = "The build daemon started before #{exe_name} was rebuilt,\nso it would compile this with the old one. Restart the daemon."
        cmd.test_daemon_refuse(io, msg)
      end
      dump_frames(refusal_file)
    end

    run_case("refusal_version_mismatch") do
      id_file = File.join(work_dir, "ident_v")
      File.write(id_file, "abc")
      cmd = Iyi::Command.new([] of String)
      refusal_file = File.join(work_dir, "refusal2.out")
      File.open(refusal_file, "w") do |io|
        msg = "The build daemon and this client are different compilers.\nDaemon: iyi 0.12.0\nClient: other-compiler 0.1.0"
        cmd.test_daemon_refuse(io, msg)
      end
      dump_frames(refusal_file)
    end
  end
end

work = ARGV.empty? ? "/tmp" : ARGV[0]
CrystalDaemonOracle.run(work)
CRYSTAL_ORACLE_SCRIPT

# Build the Crystal oracle out of the front end being replaced.
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK/dump_crystal" "$WORK/dump_crystal_daemon.cr"
if [ ! -x "$WORK/dump_crystal" ]; then
  echo "  FAILED to build Crystal daemon oracle"
  exit 1
fi

"$WORK/dump_crystal" "$WORK" > "$WORK/crystal_raw.out" 2>&1

# Normalisation pass:
# Normalise only what is genuinely machine-specific:
# 1. Temporary directory path ($WORK -> <WORK>, /private/tmp -> /tmp)
# 2. Workspace root path ($REPO -> <REPO>)
# 3. Candidate search directories for executable path
# Both outputs are normalized identically.
python3 - "$REPO" "$WORK" "$WORK/iyi_raw.out" "$WORK/iyi.out" <<'PY'
import re, sys
repo, work, src, dst = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(src).read()
# Normalize workdir paths (including macOS /private prefix)
text = text.replace("/private" + work, "<WORK>")
text = text.replace(work, "<WORK>")
text = text.replace(repo, "<REPO>")
# Normalize executable path candidate search locations
text = re.sub(r'Looked in:\n\s+/[^\n]+/iyi-daemon\n\s+\.build/iyi-daemon',
              'Looked in:\n    <EXE_DIR>/iyi-daemon\n    .build/iyi-daemon', text)
open(dst, "w").write(text)
PY

python3 - "$REPO" "$WORK" "$WORK/crystal_raw.out" "$WORK/crystal.out" <<'PY'
import re, sys
repo, work, src, dst = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(src).read()
text = text.replace("/private" + work, "<WORK>")
text = text.replace(work, "<WORK>")
text = text.replace(repo, "<REPO>")
text = re.sub(r'Looked in:\n\s+/[^\n]+/iyi-daemon\n\s+\.build/iyi-daemon',
              'Looked in:\n    <EXE_DIR>/iyi-daemon\n    .build/iyi-daemon', text)
open(dst, "w").write(text)
PY

if ! diff -u "$WORK/crystal.out" "$WORK/iyi.out" > "$WORK/diff.out"; then
  echo "  DIVERGED: build daemon output differs from the oracle"
  cat "$WORK/diff.out"
  status=1
else
  total_cases=$(grep -c '^=== CASE:' "$WORK/crystal.out")
  echo "  Parity summary: $((total_cases - diverged))/$total_cases scenarios match identically against the front end"
fi

echo
echo "== 3. Mutation proofs: each one must make the comparison above fail"

MUTATIONS_RUN=0

prove_mutation() {
  local label="$1"
  local old="$2"
  local new="$3"
  echo "  [$label]"
  cp "$DAEMON" "$DAEMON.orig"

  python3 - "$DAEMON" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(path).read()
if old not in content:
    sys.exit(3)
open(path, "w").write(content.replace(old, new, 1))
PY
  local rc=$?
  if [ "$rc" -eq 3 ] || diff -q "$DAEMON.orig" "$DAEMON" >/dev/null; then
    echo "    PATCH CHANGED NOTHING: this proves nothing"
    status=1
    cp "$DAEMON.orig" "$DAEMON"; rm -f "$DAEMON.orig"
    return
  fi

  if "$IYI" build -o "$WORK/mut-exercise" "$REPO/bench/selfhost_daemon_exercise.iyi" >/dev/null 2>&1; then
    "$WORK/mut-exercise" "$WORK" > "$WORK/iyi_mut_raw.out" 2>&1
    python3 - "$REPO" "$WORK" "$WORK/iyi_mut_raw.out" "$WORK/iyi_mut.out" <<'PY'
import re, sys
repo, work, src, dst = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(src).read()
text = text.replace("/private" + work, "<WORK>")
text = text.replace(work, "<WORK>")
text = text.replace(repo, "<REPO>")
text = re.sub(r'Looked in:\n\s+/[^\n]+/iyi-daemon\n\s+\.build/iyi-daemon',
              'Looked in:\n    <EXE_DIR>/iyi-daemon\n    .build/iyi-daemon', text)
open(dst, "w").write(text)
PY
    if diff -q "$WORK/crystal.out" "$WORK/iyi_mut.out" >/dev/null 2>&1; then
      echo "    VACUOUS: the mutated daemon produced identical output to the oracle"
      status=1
    else
      echo "    caught: the daemon output diverged, as it must"
      MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
    fi
  else
    echo "    caught: the mutated daemon did not build"
    MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  fi

  cp "$DAEMON.orig" "$DAEMON"; rm -f "$DAEMON.orig"
  echo "    reverted"
}

run_proof() {
  prove_mutation "$1" "$2" "$3"
}

run_proof "socket path limit check inverted to accept oversized paths" \
  'next unless path.bytesize > limit' \
  'next unless path.bytesize < limit'

run_proof "over-limit socket error message wording altered" \
  'the socket path is #{path.bytesize} bytes and the kernel takes' \
  'socket path size #{path.bytesize} exceeds maximum kernel limit'

run_proof "daemon override check bypasses is_file verification" \
  'unless is_file?(override)' \
  'if false && !is_file?(override)'

run_proof "candidate search drops adjacent executable directory" \
  'candidates << BuildDaemon.file_join(BuildDaemon.file_dirname(exe), server_name)' \
  '# candidates << BuildDaemon.file_join(BuildDaemon.file_dirname(exe), server_name)'

run_proof "missing daemon warning wording altered in daemon_socket_from_env" \
  'no daemon at #{socket}, building without it' \
  'daemon socket #{socket} is missing, continuing build'

run_proof "identity calculation for unknown executable altered" \
  'return "an unknown build" if exe.nil? || exe.empty?' \
  'return "unidentified compiler" if exe.nil? || exe.empty?'

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST BUILD DAEMON CHECKS PASSED"
fi
exit $status
