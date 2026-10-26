require "./encoding"
require "./receipt"
require "../codegen/target"
require "../config"

{% if flag?(:darwin) %}
  lib LibC
    struct Utsname
      sysname : UInt8[256]
      nodename : UInt8[256]
      release : UInt8[256]
      version : UInt8[256]
      machine : UInt8[256]
    end

    fun uname(name : Utsname*) : Int
  end
{% elsif flag?(:linux) %}
  lib LibC
    struct Utsname
      sysname : UInt8[65]
      nodename : UInt8[65]
      release : UInt8[65]
      version : UInt8[65]
      machine : UInt8[65]
      domainname : UInt8[65]
    end

    fun uname(name : Utsname*) : Int
  end
{% end %}

module Iyi::Stale::Profile
  LOADER_VARS = {
    "LD_PRELOAD",
    "LD_LIBRARY_PATH",
    "GLIBC_TUNABLES",
    "DYLD_INSERT_LIBRARIES",
    "DYLD_LIBRARY_PATH",
  }

  def self.current(timeout : Float64 = 60.0, cwd_test_id : TestId? = nil, target : String? = nil) : ReceiptProfile
    argv = [] of String
    stdin = "null"
    stdio = "piped"
    cwd = cwd_test_id || TestId.new("src", ".")
    target_str = target || Iyi::Config.host_target.to_s
    os = {{ flag?(:darwin) ? "darwin" : (flag?(:linux) ? "linux" : (flag?(:win32) ? "windows" : "unknown")) }}

    umask = current_umask
    rlimits = current_rlimits
    cgroup_mem = current_cgroup_mem
    loader_vars = "cleared"
    kernel = current_kernel

    fp_digest = ReceiptProfile.compute_fp(
      argv: argv,
      stdin: stdin,
      stdio: stdio,
      cwd: cwd,
      timeout: timeout,
      umask: umask,
      rlimits: rlimits,
      cgroup_mem: cgroup_mem,
      loader_vars: loader_vars,
      target: target_str,
      os: os,
      kernel: kernel
    )

    ReceiptProfile.new(
      fp: Stale.hex(fp_digest),
      argv: argv,
      stdin: stdin,
      stdio: stdio,
      cwd: cwd,
      timeout: timeout,
      umask: umask,
      rlimits: rlimits,
      cgroup_mem: cgroup_mem,
      loader_vars: loader_vars,
      target: target_str,
      os: os,
      kernel: kernel
    )
  end

  def self.clean_child_env(scratch_dir : String, trace_file : String, base_env = ENV) : Hash(String, String)
    env = Hash(String, String).new
    base_env.each do |k, v|
      next if LOADER_VARS.includes?(k)
      next if k == "IYI_DAEMON_SOCKET"
      env[k] = v
    end

    env["TMPDIR"] = scratch_dir
    env["TEMP"] = scratch_dir
    env["TMP"] = scratch_dir
    env["IYI_OBSERVE"] = trace_file

    env
  end

  def self.current_umask : Int32
    {% if flag?(:unix) %}
      cur = LibC.umask(0)
      LibC.umask(cur)
      cur.to_i32
    {% else %}
      18
    {% end %}
  end

  def self.current_rlimits : Hash(String, Int64)
    rlimits = Hash(String, Int64).new
    {% if flag?(:unix) %}
      {% if flag?(:darwin) %}
        map = {
          "stack" => 3,
          "open_files" => 8,
          "address_space" => 5,
          "data" => 2,
          "cpu_time" => 0,
          "file_size" => 1,
        }
      {% else %}
        map = {
          "stack" => 3,
          "open_files" => 7,
          "address_space" => 9,
          "data" => 2,
          "cpu_time" => 0,
          "file_size" => 1,
        }
      {% end %}

      map.each do |name, res|
        if LibC.getrlimit(res, out rlim) == 0
          # RLIM_INFINITY is the largest UInt64 on Linux: unlimited is one
          # value, not an overflow.
          current = rlim.rlim_cur.to_u64
          rlimits[name] = current > Int64::MAX.to_u64 ? Int64::MAX : current.to_i64
        end
      end
    {% end %}
    rlimits
  end

  def self.current_cgroup_mem : Int64?
    {% if flag?(:linux) %}
      if File.file?("/sys/fs/cgroup/memory.max")
        content = File.read("/sys/fs/cgroup/memory.max").strip rescue nil
        if content && content != "max"
          return content.to_i64?
        end
      elsif File.file?("/sys/fs/cgroup/memory/memory.limit_in_bytes")
        content = File.read("/sys/fs/cgroup/memory/memory.limit_in_bytes").strip rescue nil
        if content
          return content.to_i64?
        end
      end
    {% end %}
    nil
  end

  def self.current_kernel : String
    {% if flag?(:unix) %}
      uts = uninitialized LibC::Utsname
      if LibC.uname(pointerof(uts)) == 0
        String.new(uts.release.to_unsafe)
      else
        "unknown"
      end
    {% else %}
      "windows"
    {% end %}
  end
end
