require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/stale/profile"

describe Iyi::Stale::Profile do
  it "keys a test's profile by the same inputs its fingerprint has always used" do
    host = Iyi::Stale::Profile.host("aarch64-apple-darwin")
    argv = ["/scratch/one"]
    cwd = Iyi::Stale::RootPath.new("src", "pkg")

    profile = Iyi::Stale::Profile.current(host: host, argv: argv, cwd: cwd, timeout: 60.0)

    # The argument list the per-test profile was built from before the host
    # was read once per run, with the same machine values.
    digest = Iyi::Stale::ReceiptProfile.compute_fp(
      argv: argv,
      stdin: "null",
      stdio: "piped",
      cwd: Iyi::Stale::TestId.new("src", "pkg"),
      timeout: 60.0,
      umask: host.umask,
      rlimits: host.rlimits,
      cgroup_mem: host.cgroup_mem,
      loader_vars: "cleared",
      target: "aarch64-apple-darwin",
      os: host.os,
      kernel: host.kernel
    )
    profile.fp.should eq Iyi::Stale.hex(digest)
    profile.cwd.should eq Iyi::Stale::TestId.new("src", "pkg")
    profile.target.should eq "aarch64-apple-darwin"
    profile.umask.should eq host.umask
    profile.rlimits.should eq host.rlimits
    profile.cgroup_mem.should eq host.cgroup_mem
    profile.os.should eq host.os
    profile.kernel.should eq host.kernel
  end

  it "gives every test of one run the same host values" do
    host = Iyi::Stale::Profile.host
    first = Iyi::Stale::Profile.current(host: host, argv: ["/scratch/a"], cwd: Iyi::Stale::RootPath.new("src", "."), timeout: 60.0)
    second = Iyi::Stale::Profile.current(host: host, argv: ["/scratch/b"], cwd: Iyi::Stale::RootPath.new("src", "."), timeout: 60.0)

    first.umask.should eq second.umask
    first.rlimits.should eq second.rlimits
    first.kernel.should eq second.kernel
    first.fp.should_not eq second.fp
  end

  it "clears Windows compatibility mode from test environments" do
    env = Iyi::Stale::Profile.clean_child_env("scratch", "trace", {"__COMPAT_LAYER" => "RunAsInvoker", "KEEP" => "yes"})
    env.has_key?("__COMPAT_LAYER").should be_false
    env["KEEP"].should eq("yes")
  end

  {% if flag?(:win32) %}
    it "records the real kernel version and selected job limits" do
      host = Iyi::Stale::Profile.host
      host.kernel.should match(/\A\d+\.\d+\.\d+\.\d+\z/)
      info = LibC::JOBOBJECT_EXTENDED_LIMIT_INFORMATION.new
      info.basicLimitInformation.limitFlags = LibC::JOB_OBJECT_LIMIT_PROCESS_MEMORY |
        LibC::JOB_OBJECT_LIMIT_JOB_MEMORY | LibC::JOB_OBJECT_LIMIT_ACTIVE_PROCESS | LibC::JOB_OBJECT_LIMIT_PROCESS_TIME
      info.basicLimitInformation.activeProcessLimit = 4_u32
      info.basicLimitInformation.perProcessUserTimeLimit = 123_i64
      info.processMemoryLimit = 1024_u64
      info.jobMemoryLimit = 2048_u64
      Iyi::Stale::Profile.job_limits(info).should eq({
        "job_process_memory" => 1024_i64,
        "job_memory" => 2048_i64,
        "job_active_processes" => 4_i64,
        "job_process_time" => 123_i64,
      })
      info.basicLimitInformation.limitFlags = 0_u32
      Iyi::Stale::Profile.job_limits(info).should be_empty
      env = Iyi::Stale::Profile.clean_child_env("scratch", "trace", {"__compat_layer" => "RunAsInvoker"})
      env.has_key?("__compat_layer").should be_false
    end
  {% end %}

  {% if flag?(:unix) %}
    it "reads the umask and leaves it as it was" do
      old = LibC.umask(0o027)
      begin
        Iyi::Stale::Profile.host.umask.should eq 0o027
        LibC.umask(0o027).should eq 0o027
      ensure
        LibC.umask(old)
      end
    end
  {% end %}
end
