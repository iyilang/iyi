require "./spec_helper"

# The build daemon analyses the prelude once and forks a child per build. What
# has to hold is that a build served this way is indistinguishable from a normal
# one: same exit status, same diagnostics, same binary behaviour, with `stdout`
# and `stderr` still separate. Speed is measured elsewhere (SPEC.md IV.1d) —
# these specs are about not being subtly wrong.
#
# The server needs a single-threaded compiler, because only the forking thread
# survives a `fork`. `make cli_spec` builds it; CRYSTAL_SPEC_DAEMON_BIN can point
# somewhere else.
CRYSTAL_DAEMON_BIN = ENV.fetch("CRYSTAL_SPEC_DAEMON_BIN") { Path[Dir.current, ".build", "crystal-daemon"].to_s }

private def daemon_available?
  File::Info.executable?(CRYSTAL_DAEMON_BIN)
end

# Starts a daemon on a private socket, yields the socket path, and stops it.
private def with_daemon(&)
  # Reported as pending rather than skipped silently: a daemon spec that passes
  # because it never ran is worse than one that fails.
  pending!("requires #{CRYSTAL_DAEMON_BIN} (`make crystal-daemon`)") unless daemon_available?

  with_tempfile("daemon") do |dir|
    Dir.mkdir_p(dir)
    socket = File.join(dir, "build.sock")
    log = File.join(dir, "daemon.log")

    process = File.open(log, "w") do |io|
      Process.new(CRYSTAL_DAEMON_BIN, ["daemon", "start", "--socket", socket],
        input: Process::Redirect::Close, output: io, error: io)
    end

    begin
      # Startup includes analysing the prelude, so allow real time for it — but
      # never wait forever, or a daemon that died at startup looks like a slow one.
      deadline = Time.instant + 120.seconds
      until File.exists?(socket)
        if Time.instant > deadline
          raise "daemon did not create #{socket} within 120s\n#{File.read(log)}"
        end
        unless process.exists?
          raise "daemon exited before listening\n#{File.read(log)}"
        end
        sleep 50.milliseconds
      end

      yield socket
    ensure
      process.terminate(graceful: false) rescue nil
      process.wait rescue nil
    end
  end
end

private def daemon_build(socket : String, *args : String, chdir : String? = nil)
  Process.capture_result(crystal, "daemon", "build", "--socket", socket, *args, chdir: chdir)
end

describe "`crystal daemon`" do
  it "refuses an explicit CRYSTAL_DAEMON that is not there" do
    # An explicit override is authoritative: falling back to whatever binary
    # happens to sit next to the compiler would run builds against one the user
    # did not choose, and say nothing. The path has to appear in the message,
    # because that is the thing they got wrong.
    #
    # The sibling-lookup message ("none installed anywhere, run
    # `make crystal-daemon`") is not covered here — this repository always has a
    # built server for the rest of these specs to use, so the search cannot be
    # made to fail without hiding it first.
    result = Process.capture_result(crystal, "daemon", "start",
      env: {"CRYSTAL_DAEMON" => "/nonexistent/crystal-daemon"})

    result.should be_failure(1)
    result.error.should contain("/nonexistent/crystal-daemon")
  end

  it "fails clearly when no daemon is listening" do
    # Short names on purpose. A unix socket's path is a fixed field in
    # `sockaddr_un` and darwin's takes 103 bytes; `with_tempfile` sits under
    # `$TMPDIR`, which on darwin is `/var/folders/xx/<thirty characters>/T/`,
    # and `daemon-absent/absent.sock` under it came to 106. The compiler
    # refused that path with its own sentence about the limit — correctly —
    # and this spec, which is about the *other* refusal, never reached it.
    with_tempfile("d") do |dir|
      Dir.mkdir_p(dir)
      socket = File.join(dir, "a.sock")

      result = Process.capture_result(crystal, "daemon", "build", "--socket", socket,
        fixture_path("hello-world.cr"))

      result.should be_failure(1)
      result.error.should contain("no daemon listening")
    end
  end

  it "builds a program that behaves like a normally built one" do
    with_daemon do |socket|
      with_temp_executable "daemon-hello" do |output_path|
        daemon_build(socket, "-o", output_path, fixture_path("hello-world.cr"))
          .should be_success

        File::Info.executable?(output_path).should be_true
        Process.capture_result(output_path)
          .should(be_success)
          .output.should(eq("hello world\n"))
      end
    end
  end

  it "serves more than one build from the same daemon" do
    # The child inherits the listening socket, and closing a `UNIXServer`
    # unlinks its path — so a daemon can serve one build and then quietly
    # become unreachable while still appearing to run.
    with_daemon do |socket|
      with_temp_executable "daemon-first" do |first|
        with_temp_executable "daemon-second" do |second|
          daemon_build(socket, "-o", first, fixture_path("hello-world.cr")).should be_success
          daemon_build(socket, "-o", second, fixture_path("hello-world.cr")).should be_success

          Process.capture_result(second).should(be_success).output.should(eq("hello world\n"))
        end
      end
    end
  end

  # The three specs below are one fact the daemon kept forgetting: **it runs in
  # its own directory and the client does not.** Every spec that was here
  # passed while two of these were broken, because every one of them passes an
  # absolute fixture path and starts the daemon where the runner happens to be.
  #
  # This first one is the statement of intent rather than the regression — it
  # passed even then, because the *build* always cd'd correctly. What did not
  # is below it.
  it "builds from a relative path, in the client's directory" do
    with_daemon do |socket|
      with_tempfile("daemon-relative") do |dir|
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "hello.cr"), %(puts "hello from #{File.basename(dir)}"\n))

        daemon_build(socket, "-o", "out", "hello.cr", chdir: dir).should be_success
        Process.capture_result(File.join(dir, "out"))
          .should(be_success).output.should(contain("hello from"))
      end
    end
  end

  it "survives a build it served from another directory" do
    # It did not. A finished build's arguments are re-read in the daemon to
    # work out which prelude to warm next, and they were read *here* — where
    # `hello.cr` is not a file. The option parser exits the process on a
    # missing file, so the daemon died after serving a build correctly, and
    # only ever for a client that typed a relative path.
    with_daemon do |socket|
      with_tempfile("daemon-survives") do |dir|
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "hello.cr"), %(puts "one"\n))

        daemon_build(socket, "-o", "out", "hello.cr", chdir: dir).should be_success
        daemon_build(socket, "-o", "out", "hello.cr", chdir: dir).should be_success
        daemon_build(socket, fixture_path("hello-world.cr"), "--no-codegen").should be_success
      end
    end
  end

  it "finds a shard in the client's lib, not in its own" do
    # `lib` is resolved against the directory the compiler's path was built in,
    # and a preanalysed prelude is built in the daemon's. Every shard-using
    # project, from any directory but the daemon's own, answered `require
    # "thing"` with "can't find file".
    with_daemon do |socket|
      with_tempfile("daemon-shard") do |dir|
        Dir.mkdir_p(File.join(dir, "lib", "thing", "src"))
        File.write(File.join(dir, "lib", "thing", "src", "thing.cr"),
          "module Thing\n  def self.greet\n    \"from a shard\"\n  end\nend\n")
        File.write(File.join(dir, "app.cr"), %(require "thing"\nputs Thing.greet\n))

        daemon_build(socket, "-o", "app", "app.cr", chdir: dir).should be_success
        Process.capture_result(File.join(dir, "app"))
          .should(be_success).output.should(eq("from a shard\n"))
      end
    end
  end

  # A fifth thing the daemon forgot, and the worst-behaved of them: the path
  # that adopts a preanalysed prelude never runs `new_program`, so every switch
  # that method turns into a setting on the program was whatever the *daemon*
  # had — which is none of them. Most are safe because they are in the prelude's
  # cache key. `--use-iyimod` is not: it was accepted, ignored, and the build
  # compiled every module from source without a word.
  #
  # Caught here by deleting the module's source, which is the only way to tell
  # the two apart from outside.
  it "compiles an import from its artifact, as a normal build does" do
    with_daemon do |socket|
      with_tempfile("daemon-iyimod") do |dir|
        Dir.mkdir_p(File.join(dir, "app"))
        File.write(File.join(dir, "app", "twice.iyi"), <<-IYI)
          module app/twice

          pub def twice(n : Int32) : Int32
            n + n
          end
          IYI
        File.write(File.join(dir, "main.iyi"), <<-IYI)
          module main

          import app/twice

          puts App::Twice.twice(21)
          IYI

        daemon_build(socket, "--emit-iyimod", "mods", "-o", "out", "main.iyi", chdir: dir)
          .should be_success
        File.delete(File.join(dir, "app", "twice.iyi"))

        daemon_build(socket, "--use-iyimod", "mods", "-o", "out", "main.iyi", chdir: dir)
          .should be_success
        Process.capture_result(File.join(dir, "out"))
          .should(be_success).output.should(eq("42\n"))
      end
    end
  end

  it "reports a semantic error exactly as a normal build does" do
    with_daemon do |socket|
      fixture = fixture_path("semantic-error.cr")

      normal = Process.capture_result(crystal, "build", "--no-codegen", fixture)
      served = daemon_build(socket, "--no-codegen", fixture)

      served.status.should eq(normal.status)
      served.error.should eq(normal.error)
      served.error.should contain("undefined method 'frobulate' for Int32")
    end
  end

  it "reports a syntax error exactly as a normal build does" do
    with_daemon do |socket|
      fixture = fixture_path("syntax-error.cr.txt")

      normal = Process.capture_result(crystal, "build", "--no-codegen", fixture)
      served = daemon_build(socket, "--no-codegen", fixture)

      served.status.should eq(normal.status)
      served.error.should eq(normal.error)
    end
  end

  it "keeps stdout and stderr apart" do
    # The child writes to pipes the daemon frames separately. If that framing
    # were dropped, diagnostics would arrive on stdout and scripts that read
    # a compiler's output would silently start seeing error text.
    with_daemon do |socket|
      served = daemon_build(socket, "--no-codegen", fixture_path("semantic-error.cr"))

      served.should be_failure(1)
      served.output.should eq("")
      served.error.should contain("Error:")
    end
  end

  it "refuses to build once the compiler it started from has been rebuilt" do
    # The daemon holds an analysed prelude *and* the compiler that produced it.
    # Rebuilding while it runs would otherwise have it keep serving builds from
    # the old compiler, and the output would look completely normal.
    with_daemon do |socket|
      File.touch(CRYSTAL_DAEMON_BIN)

      result = daemon_build(socket, "--no-codegen", fixture_path("hello-world.cr"))

      result.should be_failure(1)
      result.error.should contain("Restart the daemon")
    end
  end

  it "serves several builds at once, keeping each client's output its own" do
    # The daemon waits on every in-flight build from one fiber, via `poll`.
    # Getting this wrong does not merely serialise the builds — an earlier
    # fiber-per-connection version had children inherit each other's live
    # fibers and write into each other's pipes. So the property under test is
    # not speed: it is that four concurrent builds, one of which must fail,
    # each get their own result.
    with_daemon do |socket|
      with_tempfile("daemon-concurrent") do |dir|
        Dir.mkdir_p(dir)

        good = (1..3).map { |i| File.join(dir, "ok-#{i}") }
        processes = good.map do |path|
          Process.new(crystal, ["daemon", "build", "--socket", socket, "-o", path,
                                fixture_path("hello-world.cr")],
            input: Process::Redirect::Close, output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
        end

        failing = Process.new(crystal, ["daemon", "build", "--socket", socket, "--no-codegen",
                                        fixture_path("semantic-error.cr")],
          input: Process::Redirect::Close, output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
        failing_error = failing.error.gets_to_end
        failing_status = failing.wait

        processes.each_with_index do |process, index|
          process.error.gets_to_end
          process.wait.success?.should be_true
          Process.capture_result(good[index]).should(be_success).output.should(eq("hello world\n"))
        end

        failing_status.success?.should be_false
        failing_error.should contain("undefined method 'frobulate' for Int32")

        # And the daemon is still there afterwards.
        with_temp_executable "daemon-after-concurrent" do |path|
          daemon_build(socket, "-o", path, fixture_path("hello-world.cr")).should be_success
        end
      end
    end
  end

  it "builds anyway when CRYSTAL_DAEMON_SOCKET points at nothing" do
    # Opting in to a daemon must never be able to stop a build. A daemon that
    # died should cost the speedup and nothing else — but it has to say so,
    # rather than leave the impression that builds are still being served.
    with_temp_executable "daemon-env-absent" do |output_path|
      result = Process.capture_result(crystal, "build", "-o", output_path,
        fixture_path("hello-world.cr"),
        env: {"CRYSTAL_DAEMON_SOCKET" => "/nonexistent/build.sock"})

      result.should be_success
      result.error.should contain("building without it")
      Process.capture_result(output_path).should(be_success).output.should(eq("hello world\n"))
    end
  end

  it "serves an ordinary `crystal build` when CRYSTAL_DAEMON_SOCKET names a daemon" do
    with_daemon do |socket|
      with_temp_executable "daemon-env-served" do |output_path|
        result = Process.capture_result(crystal, "build", "-o", output_path,
          fixture_path("hello-world.cr"),
          env: {"CRYSTAL_DAEMON_SOCKET" => socket})

        result.should be_success
        result.error.should_not contain("building without it")
        Process.capture_result(output_path).should(be_success).output.should(eq("hello world\n"))
      end
    end
  end

  it "keeps preludes for different flag sets apart" do
    # The daemon caches a prelude per flag set and warms new ones from builds
    # that already succeeded. The hazard is not slowness, it is serving a build
    # the prelude analysed under someone else's flags — macros branch on flags,
    # so that would miscompile rather than merely misbehave. Each of these runs
    # twice: the second time is the one served from the cache.
    with_daemon do |socket|
      [[] of String, ["--release"], ["-Dspec_daemon_flag_set"]].each do |flags|
        2.times do
          with_temp_executable "daemon-flags" do |path|
            args = [crystal, "daemon", "build", "--socket", socket] + flags +
                   ["-o", path, fixture_path("hello-world.cr")]
            Process.capture_result(args).should be_success
            Process.capture_result(path).should(be_success).output.should(eq("hello world\n"))
          end
        end
      end
    end
  end

  it "still builds correctly when flags differ from the daemon's prelude" do
    # Macros branch on flags, so such a build cannot adopt the analysed
    # prelude and has to analyse its own. It must be correct, not just fast.
    with_daemon do |socket|
      with_temp_executable "daemon-flagged" do |output_path|
        daemon_build(socket, "-Dspec_daemon_unused_flag", "-o", output_path,
          fixture_path("hello-world.cr")).should be_success

        Process.capture_result(output_path).should(be_success).output.should(eq("hello world\n"))
      end
    end
  end
end
