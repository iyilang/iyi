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
set -uo pipefail
status=0
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd -P)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  echo "  FAILED: a functional Python interpreter is required" >&2
  exit 1
fi
if ! command -v perl >/dev/null 2>&1; then
  echo "  FAILED: perl is required for the mutation proofs" >&2
  exit 1
fi
. "$REPO/bench/lib/mutation.sh"
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
DAEMON="$REPO/src/compiler/command/daemon.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE="$(native_path "$REPO")" || exit 1
WORK_NATIVE="$(native_path "$WORK")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
SANDBOX="$WORK/cwd"
mkdir -p "$SANDBOX/.build"
# Every socket and override used here belongs to this exercise.
unset IYI_DAEMON CRYSTAL_DAEMON IYI_DAEMON_SOCKET CRYSTAL_DAEMON_SOCKET

echo "== 1. Building and running the build daemon exercise"
if ! "$IYI" build -o "$WORK_NATIVE/exercise$EXE" "$REPO_NATIVE/bench/selfhost_daemon_exercise.iyi" > "$WORK/build.log" 2>&1; then
  echo "  FAILED to build the daemon exercise"
  cat "$WORK/build.log"
  exit 1
fi
if ! "$WORK/exercise$EXE" "$WORK_NATIVE" </dev/null > "$WORK/iyi_raw.out" 2> "$WORK/iyi_run.err"; then
  echo "  FAILED to run the daemon exercise"
  cat "$WORK/iyi_run.err"
  exit 1
fi
if [ -s "$WORK/iyi_run.err" ]; then
  echo "  FAILED: unexpected daemon exercise stderr"
  cat "$WORK/iyi_run.err"
  exit 1
fi

echo
echo "== 2. Build daemon comparison against the front end being replaced"
cat <<'HOSTED_ORACLE_SCRIPT' > "$WORK/dump_hosted_daemon.cr"
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
  class_property executable_override : String?
  class_property use_executable_override : Bool = false

  def self.executable_path : String?
    return @@executable_override if @@use_executable_override
    previous_def
  end

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

  def test_daemon_socket_option
    daemon_socket_option
  end

  def test_daemon_refuse_long_socket(path : String)
    daemon_refuse_long_socket(path)
  end

  def test_daemon_start
    daemon_start
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

module HostedDaemonOracle
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
        elsif kind == Iyi::Command::DAEMON_FRAME_REFUSE.to_i32
          sz = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).to_i32
          slice = Bytes.new(sz)
          io.read_fully(slice)
          puts "FRAME REFUSE (#{sz} bytes):"
          puts String.new(slice)
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
    STDOUT.flush
    STDERR.flush
    {% if flag?(:win32) %}
      saved_out = IO::FileDescriptor.from_stdio(1)
      saved_err = IO::FileDescriptor.from_stdio(2)
      saved_out.close_on_finalize = false
      saved_err.close_on_finalize = false
    {% else %}
      saved_out = IO::FileDescriptor.new(LibC.dup(STDOUT.fd), close_on_finalize: false)
      saved_err = IO::FileDescriptor.new(LibC.dup(STDERR.fd), close_on_finalize: false)
    {% end %}
    tmp_out = File.tempfile(dir: ARGV[0])
    tmp_err = File.tempfile(dir: ARGV[0])
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
      STDOUT.reopen(saved_out)
      STDERR.reopen(saved_err)
      {% unless flag?(:win32) %}
        saved_out.close
        saved_err.close
      {% end %}
    end

    tmp_out.rewind
    out_raw = tmp_out.gets_to_end
    out_s = out_raw.strip
    tmp_out.delete

    tmp_err.rewind
    err_raw = tmp_err.gets_to_end
    err_s = err_raw.strip
    tmp_err.delete

    output = String.build do |sb|
      sb.puts out_s unless out_s.empty?
      sb.puts err_s unless err_s.empty?
      unless out_s.empty? && err_s.empty?
        sb.puts "stdout:"
        sb.print out_raw
        sb.puts "\nend stdout"
        sb.puts "stderr:"
        sb.print err_raw
        sb.puts "\nend stderr"
      end
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
        if path = cmd.test_daemon_socket_option
          cmd.test_daemon_refuse_long_socket(path)
        end
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
        if path = cmd.test_daemon_socket_option
          cmd.test_daemon_refuse_long_socket(path)
        end
      end
      format_result(ec, out_s)
    end

    run_case("socket_path_way_over_limit") do
      over_path = File.join(work_dir, "x" * 150)
      ec, out_s = capture_run do
        cmd = Iyi::Command.new(["build", "--socket", over_path, "main.iyi"])
        cmd.test_daemon_socket_path
      end
      format_result(ec, out_s)
    end

    run_case("socket_path_default_over_limit") do
      long_cache = File.join(work_dir, "c" * 120)
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
      ENV["IYI_DAEMON"] = File.join(work_dir, "missing-daemon")
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
        Process.executable_override = fake_exe
        Process.use_executable_override = true
        begin
          Iyi::Command.new(["start"]).test_daemon_exec_server
        ensure
          Process.use_executable_override = false
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
          Process.executable_override = fake_exe
          Process.use_executable_override = true
          begin
            Iyi::Command.new(["start"]).test_daemon_exec_server
          ensure
            Process.use_executable_override = false
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
        Process.executable_override = fake_exe
        Process.use_executable_override = true
        begin
          Iyi::Command.new(["start"]).test_daemon_exec_server
        ensure
          Process.use_executable_override = false
        end
      end
      format_result(ec, out_s)
    end

    run_case("exec_server_socket_too_long") do
      over_path = File.join(work_dir, "y" * 150)
      ec, out_s = capture_run do
        cmd = Iyi::Command.new(["start", "--socket", over_path])
        cmd.test_daemon_start
      end
      format_result(ec, out_s)
    end

    # 6. Daemon Identity (daemon_identity)
    run_case("identity_unknown") do
      Process.executable_override = nil
      Process.use_executable_override = true
      begin
        puts "identity: #{Iyi::Command.new([] of String).test_daemon_identity}"
      ensure
        Process.use_executable_override = false
      end
    end

    run_case("identity_deleted") do
      Process.executable_override = File.join(work_dir, "deleted_file")
      Process.use_executable_override = true
      begin
        puts "identity: #{Iyi::Command.new([] of String).test_daemon_identity}"
      ensure
        Process.use_executable_override = false
      end
    end

    run_case("identity_existing") do
      id_file = File.join(work_dir, "ident_file")
      File.write(id_file, "compiler binary payload\n") unless File.exists?(id_file)
      Process.executable_override = id_file
      Process.use_executable_override = true
      id = ""
      begin
        id = Iyi::Command.new([] of String).test_daemon_identity
      ensure
        Process.use_executable_override = false
      end
      idx = id.index(':')
      if idx
        size_s = id[0, idx]
        puts "identity size prefix: #{size_s}"
        puts "identity has ns: #{id.bytesize > idx + 5}"
      else
        puts "identity: #{id}"
      end
      puts "identity exact: #{id}"
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

work = File.expand_path(ARGV[0])
Dir.mkdir_p(File.join(work, "cwd", ".build"))
Dir.cd(File.join(work, "cwd"))
HostedDaemonOracle.run(work)
HOSTED_ORACLE_SCRIPT

if ! CRYSTAL_PATH="$REPO_NATIVE/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK_NATIVE/hosted-oracle$EXE" "$WORK_NATIVE/dump_hosted_daemon.cr" > "$WORK/oracle-build.log" 2>&1; then
  echo "  FAILED to build hosted daemon oracle"
  cat "$WORK/oracle-build.log"
  exit 1
fi
if ! "$WORK/hosted-oracle$EXE" "$WORK_NATIVE" </dev/null > "$WORK/hosted_raw.out" 2> "$WORK/hosted_run.err"; then
  echo "  FAILED to run hosted daemon oracle"
  cat "$WORK/hosted_run.err"
  exit 1
fi
if [ -s "$WORK/hosted_run.err" ]; then
  echo "  FAILED: unexpected hosted oracle stderr"
  cat "$WORK/hosted_run.err"
  exit 1
fi

# Only the work and repository roots differ by machine. Preserve the
# candidate paths, diagnostics, stream boundaries, and exit statuses.
normalize_daemon() {
  REPO_POSIX="$REPO" REPO_NATIVE_ROOT="$REPO_NATIVE" WORK_POSIX="$WORK" WORK_NATIVE_ROOT="$WORK_NATIVE" \
    "$PY" - "$(native_path "$1")" "$(native_path "$2")" <<'PY'
import os, sys
src, dst = sys.argv[1:]
with open(src, encoding="utf-8") as source:
    text = source.read()
replacements = []
for key, label in (("WORK", "<WORK>"), ("REPO", "<REPO>")):
    posix = os.environ[key + "_POSIX"]
    native = os.environ[key + "_NATIVE_ROOT"]
    roots = {posix, native, posix.replace("/", "\\"), native.replace("/", "\\")}
    if posix.startswith("/"):
        roots.add("/private" + posix)
    roots |= {root.replace("\\", "\\\\") for root in roots}
    replacements.extend((root, label) for root in roots if root)
for root, label in sorted(replacements, key=lambda item: len(item[0]), reverse=True):
    text = text.replace(root, label)
with open(dst, "w", encoding="utf-8", newline="") as output:
    output.write(text)
PY
}

normalize_daemon "$WORK/iyi_raw.out" "$WORK/iyi.out" || exit 1
normalize_daemon "$WORK/hosted_raw.out" "$WORK/hosted.out" || exit 1
if [ "$(grep -c '^=== CASE:' "$WORK/hosted.out")" -ne 30 ] || [ "$(grep -c '^=== CASE:' "$WORK/iyi.out")" -ne 30 ]; then
  echo "  FAILED: expected 30 daemon scenarios from each implementation"
  exit 1
fi
if ! diff -u "$WORK/hosted.out" "$WORK/iyi.out" > "$WORK/diff.out"; then
  echo "  DIVERGED: build daemon output differs from the oracle"
  cat "$WORK/diff.out"
  status=1
else
  echo "  Parity summary: 30/30 scenarios match identically against the front end"
fi

echo
echo "== 3. Mutation proofs: each one must make the comparison above fail"

MUTATIONS_RUN=0
check_daemon_mutant() {
  rm -f "$WORK/mut-exercise$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_daemon_exercise.iyi" > "$WORK/mut-build.log" 2>&1 || [ ! -f "$WORK/mut-exercise$EXE" ]; then
    echo "  INVALID MUTANT: daemon exercise did not build"
    cat "$WORK/mut-build.log"
    touch "$WORK/invalid-mutant"
    return 0
  fi
  if ! "$WORK/mut-exercise$EXE" "$WORK_NATIVE" </dev/null > "$WORK/iyi_mut_raw.out" 2> "$WORK/mut-run.err" || [ -s "$WORK/mut-run.err" ]; then
    echo "  INVALID MUTANT: daemon exercise did not run cleanly"
    cat "$WORK/mut-run.err"
    touch "$WORK/invalid-mutant"
    return 0
  fi
  if [ "$(grep -c '^=== CASE:' "$WORK/iyi_mut_raw.out")" -ne 30 ] ||
     ! normalize_daemon "$WORK/iyi_mut_raw.out" "$WORK/iyi_mut.out"; then
    echo "  INVALID MUTANT: daemon exercise output was incomplete"
    touch "$WORK/invalid-mutant"
    return 0
  fi
  local diff_status=0
  diff -u "$WORK/hosted.out" "$WORK/iyi_mut.out" > "$WORK/mut-diff.log" || diff_status=$?
  if [ "$diff_status" -eq 0 ]; then
    return 0
  elif [ "$diff_status" -eq 1 ]; then
    echo "  DIVERGED: build daemon output differs from the oracle"
    return 1
  fi
  echo "  INVALID MUTANT: comparison failed"
  touch "$WORK/invalid-mutant"
  return 0
}

prove_mutation "socket path limit check inverted to accept oversized paths" "$DAEMON" \
  'return if path.bytesize <= limit' \
  'return if path.bytesize >= limit' \
  -- check_daemon_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "over-limit socket error message wording altered" "$DAEMON" \
  'the socket path is #{path.bytesize} bytes and the kernel takes' \
  'socket path size #{path.bytesize} exceeds maximum kernel limit' \
  -- check_daemon_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "daemon override check bypasses is_file verification" "$DAEMON" \
  'unless is_file?(override)' \
  'if false && !is_file?(override)' \
  -- check_daemon_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "candidate search drops adjacent executable directory" "$DAEMON" \
  'candidates << BuildDaemon.file_join(BuildDaemon.file_dirname(exe), server_name)' \
  '# candidates << BuildDaemon.file_join(BuildDaemon.file_dirname(exe), server_name)' \
  -- check_daemon_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "missing daemon warning wording altered in daemon_socket_from_env" "$DAEMON" \
  'no daemon at #{socket}, building without it' \
  'daemon socket #{socket} is missing, continuing build' \
  -- check_daemon_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "identity calculation for unknown executable altered" "$DAEMON" \
  'return "an unknown build" if exe.nil? || exe.empty?' \
  'return "unidentified compiler" if exe.nil? || exe.empty?' \
  -- check_daemon_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo "  $MUTATIONS_RUN mutation proofs run"
if [ -e "$WORK/invalid-mutant" ]; then
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST BUILD DAEMON CHECKS PASSED"
fi
exit $status
