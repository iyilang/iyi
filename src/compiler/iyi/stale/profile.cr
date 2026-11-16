require "./encoding"
require "./receipt"
require "./roots"
require "../codegen/target"
require "../config"
require "./win_version"

{% if flag?(:win32) %}
  require "c/jobapi2"
  require "c/processthreadsapi"
{% end %}

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
    "__COMPAT_LAYER",
  }
  DAEMON_VARS  = {"IYI_DAEMON_SOCKET", "CRYSTAL_DAEMON_SOCKET"}
  SCRATCH_VARS = {"TMPDIR", "TEMP", "TMP"}

  # What the machine gives every test's profile, read once per run: the umask,
  # rlimits, cgroup memory, kernel, target and os. A test's profile is then
  # made from values already in hand, with no syscalls. The umask is read by
  # setting it to 0 and back, which is why only `host` reads it: a second
  # caller would race that flip.
  record HostState,
    umask : Int32,
    rlimits : Hash(String, Int64),
    cgroup_mem : Int64?,
    kernel : String,
    target : String,
    os : String

  def self.host(target : String? = nil) : HostState
    HostState.new(
      umask: current_umask,
      rlimits: current_rlimits,
      cgroup_mem: current_cgroup_mem,
      kernel: current_kernel,
      target: target || Iyi::Config.host_target.to_s,
      os: {{ flag?(:darwin) ? "darwin" : (flag?(:linux) ? "linux" : (flag?(:win32) ? "windows" : "unknown")) }}
    )
  end

  # One test's profile: its argv and cwd and the run's timeout, with the
  # machine's host state. The fingerprint is the one a receipt has always
  # been keyed by; its inputs have not changed.
  def self.current(
    host : HostState,
    argv : Array(String) = [] of String,
    cwd : RootPath | TestId = TestId.new("src", "."),
    timeout : Float64 = 60.0,
  ) : ReceiptProfile
    stdin = "null"
    stdio = "piped"
    cwd_id = cwd.is_a?(TestId) ? cwd : TestId.new(cwd.root, cwd.path)
    loader_vars = "cleared"

    fp_digest = ReceiptProfile.compute_fp(
      argv: argv,
      stdin: stdin,
      stdio: stdio,
      cwd: cwd_id,
      timeout: timeout,
      umask: host.umask,
      rlimits: host.rlimits,
      cgroup_mem: host.cgroup_mem,
      loader_vars: loader_vars,
      target: host.target,
      os: host.os,
      kernel: host.kernel
    )

    ReceiptProfile.new(
      fp: Stale.hex(fp_digest),
      argv: argv,
      stdin: stdin,
      stdio: stdio,
      cwd: cwd_id,
      timeout: timeout,
      umask: host.umask,
      rlimits: host.rlimits,
      cgroup_mem: host.cgroup_mem,
      loader_vars: loader_vars,
      target: host.target,
      os: host.os,
      kernel: host.kernel
    )
  end

  def self.clean_child_env(scratch_dir : String, trace_file : String, base_env = ENV) : Hash(String, String)
    env = Hash(String, String).new
    base_env.each do |k, v|
      name = k
      {% if flag?(:win32) %}
        name = k.upcase
      {% end %}
      next if LOADER_VARS.includes?(name) || DAEMON_VARS.includes?(name)
      env[k] = v
    end
    SCRATCH_VARS.each { |k| env[k] = scratch_dir }
    env["IYI_OBSERVE"] = trace_file
    env
  end

  def self.program_env(base_env = ENV) : Hash(String, String)
    env = clean_child_env("scratch", "", base_env)
    env.delete("IYI_OBSERVE") # the runtime unsets it before program code (observe.iyi:383-387)
    env
  end

  def self.build_env(base_env = ENV) : Hash(String, String)
    env = Hash(String, String).new
    base_env.each { |k, v| env[k] = v unless DAEMON_VARS.includes?(k) }
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
    {% elsif flag?(:win32) %}
      if LibC.IsProcessInJob(LibC.GetCurrentProcess, LibC::HANDLE.null, out in_job) == 0
        raise RuntimeError.from_winerror("IsProcessInJob")
      end
      if in_job != 0
        limits = LibC::JOBOBJECT_EXTENDED_LIMIT_INFORMATION.new
        if LibC.QueryInformationJobObject(LibC::HANDLE.null, LibC::JOBOBJECTINFOCLASS::ExtendedLimitInformation,
             pointerof(limits).as(Void*), sizeof(LibC::JOBOBJECT_EXTENDED_LIMIT_INFORMATION), nil) == 0
          raise RuntimeError.from_winerror("QueryInformationJobObject")
        end
        rlimits = job_limits(limits)
      end
    {% end %}
    rlimits
  end

  {% if flag?(:win32) %}
    def self.job_limits(info : LibC::JOBOBJECT_EXTENDED_LIMIT_INFORMATION) : Hash(String, Int64)
      limits = {} of String => Int64
      basic = info.basicLimitInformation
      flags = basic.limitFlags
      limits["job_process_memory"] = info.processMemoryLimit.to_i64! if flags.bits_set?(LibC::JOB_OBJECT_LIMIT_PROCESS_MEMORY)
      limits["job_memory"] = info.jobMemoryLimit.to_i64! if flags.bits_set?(LibC::JOB_OBJECT_LIMIT_JOB_MEMORY)
      limits["job_active_processes"] = basic.activeProcessLimit.to_i64 if flags.bits_set?(LibC::JOB_OBJECT_LIMIT_ACTIVE_PROCESS)
      limits["job_process_time"] = basic.perProcessUserTimeLimit if flags.bits_set?(LibC::JOB_OBJECT_LIMIT_PROCESS_TIME)
      limits
    end
  {% end %}

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
    {% elsif flag?(:win32) %}
      WinVersion.kernel
    {% else %}
      "unknown"
    {% end %}
  end
end
