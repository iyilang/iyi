require "socket"

{% if flag?(:without_mt) %}
  require "c/poll"

  # `poll(2)`, for the build daemon's single-fiber server loop. Declared here
  # because reopening `lib LibC` inside a class would define a nested lib of the
  # same name rather than extending the real one.
  lib LibC
    struct PollFd
      fd : Int
      events : Short
      revents : Short
    end

    fun poll(fds : PollFd*, nfds : ULong, timeout : Int) : Int
  end
{% end %}

# A build daemon: analyse the prelude once, then fork a child per build so each
# build starts from a `Program` that already has it.
#
# The measurements behind this are in SPEC.md IV.1a/IV.1b. The prelude is ~87% of
# a small build's front end, and a fork restores it in about a millisecond, which
# is a floor no serialised artifact can beat. So the daemon is not a substitute
# for `.iyimod` — it cannot cross machines or sessions, and it is not the basis
# of separate compilation — but it delivers the same front-end win today.
#
# The output of a build has to reach the client as it happens, with `stdout` and
# `stderr` still distinguishable and the exit status intact. The child therefore
# writes to a pair of pipes rather than to the connection, and the daemon frames
# what it reads:
#
#     1 byte kind, 0 = exit, 1 = stdout, 2 = stderr
#     4 bytes little-endian length (or the exit code, for kind 0)
#     that many bytes
#
# Requests are a little-endian length followed by that many bytes of JSON,
# `{"cwd": ..., "args": [...], "version": ..., "env": {...}}`. The environment
# is the client's and the child runs with it; `IYI_PATH` is compared rather
# than applied, because the prelude a daemon holds came from its own. The
# version is checked, along
# with the server's own executable, so that a rebuilt compiler cannot be served
# from silently.
class Iyi::Command
  DAEMON_FRAME_EXIT   = 0_u8
  DAEMON_FRAME_STDOUT = 1_u8
  DAEMON_FRAME_STDERR = 2_u8
  # A daemon that cannot serve *this* build — rebuilt compiler, other
  # version, other library — rather than a build that failed. Its own frame
  # because the answer depends on who asked: `iyi daemon build` wanted this
  # daemon and is told no, while a build that only found `IYI_DAEMON_SOCKET`
  # in the environment wanted a binary and gets one, built without it.
  DAEMON_FRAME_REFUSE = 3_u8

  private def daemon
    subcommand = options.first?

    case subcommand
    when nil, "start"
      options.shift?
      daemon_start
    when "build"
      options.shift
      daemon_build
    when "--help", "-h"
      puts <<-USAGE
        Usage: #{Command.program_name} daemon [start|build] [switches]

        Analyses the prelude once and forks a child per build, so a build does
        not re-analyse it. Start a daemon in one terminal and send builds to it
        from another:

            #{Command.program_name} daemon start
            #{Command.program_name} daemon build hello.iyi

        Command:
            start (default)      run the daemon in the foreground
            build                send a build to a running daemon

        Switches:
            --socket PATH        socket to listen on / connect to

        Set IYI_DAEMON_SOCKET and an ordinary `#{Command.program_name} build`
        is served by that daemon too, falling back to a normal build if it is
        not there.
        USAGE
      exit
    else
      abort! "unknown daemon subcommand: #{subcommand}", :USAGE_ERROR
    end
  end

  # Hands the server over to the single-threaded daemon binary.
  #
  # The daemon forks a child per build, and only the forking thread survives a
  # fork — a multi-threaded runtime would give the child a broken one, which is
  # why Crystal refuses `fork` in such a build at compile time. So the server
  # half lives in its own binary. The client half does not fork and runs
  # anywhere, which is why only `start` is redirected.
  private def daemon_exec_server : NoReturn
    # An explicit override is authoritative. Falling back to some other binary
    # because the named one is missing would run a build against a compiler the
    # user did not ask for, and say nothing about it.
    if (override = Config.env("DAEMON")) && !override.empty?
      unless File.info?(override).try(&.file?)
        STDERR.puts "IYI_DAEMON points at #{override}, which is not a file"
        exit 1
      end
      Process.exec(override, ["daemon", "start"] + options)
    end

    # iyi: named after the binary that was typed, because there are two of
    # them. `iyi` and `crystal` are the same compiler with different preludes
    # and different command surfaces, and a server is the compiler it was built
    # from — an `iyi daemon start` served by `crystal-daemon` would hold the
    # wrong prelude and answer `iyi help` questions in the wrong language.
    server_name = "#{Command.program_name}-daemon"

    candidates = [] of String
    if executable = Process.executable_path
      candidates << File.join(File.dirname(executable), server_name)
    end
    candidates << File.join(".build", server_name)

    if server = candidates.find { |candidate| File.info?(candidate).try(&.file?) }
      Process.exec(server, ["daemon", "start"] + options)
    end

    STDERR.puts <<-MSG
      The build daemon needs a single-threaded compiler, and none was found.

      Build one with:
          make #{server_name}

      Looked in:
      #{candidates.join('\n') { |candidate| "    #{candidate}" }}

      Set IYI_DAEMON to point at it directly.
      MSG
    exit 1
  end

  # Lets `crystal build` go through a daemon without the user retyping the
  # command: set IYI_DAEMON_SOCKET and ordinary builds are served by it.
  #
  # Opt-in, and it falls back to building normally when nothing is listening —
  # with a line saying so, because a daemon that quietly died should not look
  # like a daemon that is working.
  private def daemon_socket_from_env : String?
    socket = Config.env("DAEMON_SOCKET")
    return nil if socket.nil? || socket.empty?

    unless File.exists?(socket)
      STDERR.puts "#{Command.program_name}: no daemon at #{socket}, building without it"
      return nil
    end

    socket
  end

  # iyi: the one place a socket path is decided, and every verb that opens or
  # connects to a socket comes through here. A unix socket's path is a fixed
  # field in the kernel's `sockaddr_un` — 107 bytes on Linux, 103 on darwin —
  # and handing it a longer one raised Crystal's `ArgumentError` out of
  # `Socket::UNIXAddress`: `iyi daemon start --socket <long path>` died with
  # "Path size exceeds the maximum size of 107 bytes (ArgumentError)" and a
  # stack trace through `src/socket/address.cr`, which names a file the author
  # never opened and says nothing about the socket they asked for. The length
  # check is `daemon_refuse_long_socket` below, because one verb refuses the
  # path before it ever decides one.
  private def daemon_socket_path : String
    path = nil
    options.each_with_index do |opt, i|
      if opt == "--socket"
        path = options[i + 1]?
        # The flag's value, not the flag after it, and not silence: with
        # nothing behind it `--socket` fell through to the default path,
        # so `iyi daemon build --socket` talked to a daemon the author had
        # not named. `--out`, `--mods`, `--lib` and `--affected` refuse the
        # same mistake in the same words.
        # And not `""` either, which is `"$SOCK"` with `SOCK` unset: it
        # answered "no daemon listening on " and a hole where the path goes.
        if path.nil? || path.empty?
          abort! "--socket takes a path", :USAGE_ERROR
        elsif path.starts_with?('-')
          abort! "--socket takes a path, and #{path} is a flag", :USAGE_ERROR
        end
        options.delete_at(i, 2)
        break
      end
    end
    path ||= File.join(CacheDir.instance.dir, "daemon.sock")

    # A unix socket is neither of these, and "no daemon listening" about a
    # directory names the wrong thing: nothing could ever listen there.
    if Dir.exists?(path)
      abort! "#{path} is a directory, not a socket", :USAGE_ERROR
    end

    daemon_refuse_long_socket(path)
    path
  end

  # iyi: the same `--socket`, read without being consumed, for the half of
  # `daemon start` that never opens the socket itself: it execs the server
  # binary with these arguments, so taking the flag out here would hand the
  # server a default path and listen somewhere the user did not ask for.
  # The `--socket` value as typed, before the server binary is executed:
  # whatever is wrong with it is wrong on this side of the exec too, and
  # the far side reports it as a failure to start a daemon.
  private def daemon_socket_option : String?
    options.each_with_index do |opt, i|
      next unless opt == "--socket"
      path = options[i + 1]?
      if path.nil? || path.empty?
        abort! "--socket takes a path", :USAGE_ERROR
      elsif path.starts_with?('-')
        abort! "--socket takes a path, and #{path} is a flag", :USAGE_ERROR
      elsif Dir.exists?(path)
        abort! "#{path} is a directory, not a socket", :USAGE_ERROR
      end
      return path
    end
    nil
  end

  private def daemon_refuse_long_socket(path : String) : Nil
    limit = Socket::UNIXAddress::MAX_PATH_SIZE
    return if path.bytesize <= limit

    abort! "the socket path is #{path.bytesize} bytes and the kernel takes " \
           "#{limit}: #{path}. A unix socket's path is a fixed field in " \
           "`sockaddr_un`, so this is the machine's limit rather than " \
           "this compiler's. Pass a shorter `--socket`, or set TMPDIR to " \
           "a shorter directory and let the default sit under it",
      :FAILURE
  end

  private def daemon_start
    {% unless flag?(:without_mt) %}
      # iyi: the path the user typed is refused here, before a server binary
      # is looked for. Whether this machine has a single-threaded compiler has
      # nothing to do with whether a path fits in `sockaddr_un`, and on a
      # machine without one the answer to a 147-byte `--socket` was a page
      # about `make iyi-daemon` that never mentioned the socket at all.
      if socket = daemon_socket_option
        daemon_refuse_long_socket(socket)
      end
      daemon_exec_server
    {% else %}
      # Before the socket exists, so that what is recorded is the compiler this
      # daemon actually started from. A client can appear the instant the socket
      # does, and anything sampled after that races with it.
      identity = daemon_identity

      path = daemon_socket_path
      Dir.mkdir_p(File.dirname(path))

      # `File.delete?` takes the path from whoever holds it, and it used to
      # run unconditionally: a second `daemon start` on a live socket
      # unlinked the first daemon's address and listened on a new one with
      # the same name. The first daemon went on running — a warm prelude
      # and a compiler, holding a socket with no name, that no client could
      # ever reach again and nothing would ever reap.
      #
      # Connecting is the only way to ask a unix socket whether anyone is
      # home. A connection that says nothing is not an error on the other
      # side (see `daemon_accept`), so this costs the incumbent one accept
      # and no log line.
      if File.exists?(path)
        live = begin
          UNIXSocket.new(path).close
          true
        rescue Socket::Error
          false
        end

        if live
          abort! "a daemon is already listening on #{path}. " \
                 "Build against it, or give this one its own `--socket`", :FAILURE
        end
      end

      File.delete?(path)
      server = UNIXServer.new(path)

      # The whole point: pay for the prelude once, here, rather than in every
      # build. Children adopt this and start from it.
      # iyi: Crystal's prelude, under `iyi` too, and that is the right default
      # rather than an oversight. `--crystal` sets `prelude = "prelude"`, which
      # is what `Compiler.new` already has, so an `iyi build --crystal` hits
      # this analysis on its first request — and that is the mode the daemon is
      # for (SPEC.md IV.1d). An ordinary `.iyi` build wants `iyi/prelude`,
      # misses, and warms it after the first build: 0.03 s, which is the whole
      # reason the daemon is not for that mode.
      elapsed = Time.instant
      preanalysed = Compiler.new.preanalyse_prelude
      Compiler.preanalysed[preanalysed.key] = preanalysed

      STDERR.puts "#{Command.program_name} daemon listening on #{path}"
      STDERR.puts "prelude analysed in #{elapsed.elapsed.total_seconds.round(3)}s"
      STDERR.flush

      daemon_loop(server, identity) do
        if preanalysed.stale?
          elapsed = Time.instant
          # Every cached prelude came from the same sources, so they are all
          # stale together.
          Compiler.preanalysed.clear
          preanalysed = Compiler.new.preanalyse_prelude
          Compiler.preanalysed[preanalysed.key] = preanalysed
          STDERR.puts "prelude changed, re-analysed in #{elapsed.elapsed.total_seconds.round(3)}s"
          STDERR.flush
        end
      end
    {% end %}
  end

  {% if flag?(:without_mt) %}
    # `poll(2)`, because the server has to wait on many descriptors from a single
    # fiber. Crystal has no `IO.select`, and a fiber per stream is what broke the
    # first attempt at concurrency: a forked child inherits the parent's live
    # fibers, and the scheduler runs them as soon as the child blocks on IO, so
    # another build's relay writes to descriptors this child has closed.
    #
    # One fiber, one `poll`, no inherited relays.
    # A build in flight: the connection to report to, the child's two output
    # pipes, and how many of them are still open.
    private class DaemonBuild
      getter client : UNIXSocket
      getter out_r : IO::FileDescriptor
      getter err_r : IO::FileDescriptor
      getter pid : LibC::PidT
      getter args : Array(String)

      # The directory the client ran in. The child builds there, and the warm
      # that follows has to read the same arguments in the same place — see
      # `daemon_warm`.
      getter cwd : String
      property open : Int32

      def initialize(@client, @out_r, @err_r, @pid, @args, @cwd)
        @open = 2
      end

      def stream(kind : UInt8) : IO::FileDescriptor
        kind == DAEMON_FRAME_STDOUT ? @out_r : @err_r
      end
    end

    private def daemon_loop(server, identity : String, &refresh) : Nil
      builds = [] of DaemonBuild
      warm = [] of {String, Array(String)}
      buffer = Bytes.new(16384)

      loop do
        # Rebuilt each round: which descriptors matter changes as builds start
        # and finish, and the set is small enough that this is not worth caching.
        fds = [] of LibC::PollFd
        owners = [] of {DaemonBuild?, UInt8}

        fds << LibC::PollFd.new(fd: server.fd, events: LibC::POLLIN.to_i16, revents: 0)
        owners << {nil, 0_u8}

        builds.each do |build|
          {DAEMON_FRAME_STDOUT, DAEMON_FRAME_STDERR}.each do |kind|
            stream = build.stream(kind)
            next if stream.closed?
            fds << LibC::PollFd.new(fd: stream.fd, events: LibC::POLLIN.to_i16, revents: 0)
            owners << {build, kind}
          end
        end

        ready = LibC.poll(fds.to_unsafe, fds.size.to_u64, -1)
        next if ready < 0 # interrupted; rebuild the set and wait again

        finished = [] of DaemonBuild

        fds.each_with_index do |pollfd, index|
          next if pollfd.revents == 0

          build, kind = owners[index]

          unless build
            daemon_accept(server, identity, builds) { refresh.call }
            next
          end

          # `poll` said readable, so this does not block: it returns data, or 0
          # at end of stream once the child has exited and closed its end.
          stream = build.stream(kind)
          read = begin
            stream.read(buffer)
          rescue IO::Error
            0
          end

          if read == 0
            stream.close rescue nil
            build.open -= 1
            finished << build if build.open == 0
          else
            daemon_frame(build.client, kind, buffer[0, read]) rescue nil
          end
        end

        finished.each do |build|
          warm << {build.cwd, build.args} if daemon_finish(build)
          builds.delete(build)
        end

        # Only while nothing is in flight: analysing a prelude takes about a
        # second, and this loop is the only thing relaying output.
        if builds.empty? && !warm.empty?
          cwd, args = warm.shift
          daemon_warm(cwd, args)
        end
      end
    end

    # Accepts one connection and starts its build, or refuses it. Returns
    # without starting anything if the request is rejected.
    private def daemon_accept(server, identity : String, builds : Array(DaemonBuild), &refresh) : Nil
      client = server.accept

      # One client's mistake is one client's mistake. Every read below can
      # fail on something the daemon does not control — a client killed
      # mid-frame is `End of file reached`, a length header that does not
      # match the body is the same, a body that is not JSON is a
      # `JSON::ParseException`, a request without `cwd` is a `KeyError` —
      # and none of it was caught, so the exception left `daemon_loop`,
      # left `main`, and took the daemon down with the analysed prelude
      # every other client was waiting on. Ctrl-C during a build did it.
      # So did one connection from anything that probes ports.
      request = begin
        daemon_read_request(client)
      rescue ex : IO::Error | JSON::ParseException | Socket::Error
        # Not `daemon_refuse`: a client that could not finish a frame is
        # usually gone, and writing to it raises in turn.
        STDERR.puts "#{Command.program_name} daemon: a client sent no usable request (#{ex.message}); still listening"
        STDERR.flush
        client.close rescue nil
        return
      end

      # Connected and said nothing: `daemon start` asking whether this
      # socket has an incumbent, or a client that was interrupted before it
      # wrote its first byte. Neither is worth a line in the log.
      if request.nil?
        client.close rescue nil
        return
      end

      cwd = request["cwd"]?.try(&.as_s?)
      args = request["args"]?.try(&.as_a?).try(&.map(&.as_s?))
      if cwd.nil? || args.nil? || args.any?(&.nil?)
        daemon_refuse(client, "That is not a build request: a daemon takes " \
                              "{\"cwd\": <path>, \"args\": [<argument>...]}.")
        client.close rescue nil
        return
      end
      args = args.map(&.not_nil!)

      # A daemon holds an analysed prelude *and* the compiler that analysed it.
      # Rebuild the compiler and it would keep serving builds from the old one,
      # silently, with output that looks like a normal build's.
      if daemon_identity != identity
        daemon_refuse(client, <<-MSG)
          The build daemon started before #{Process.executable_path || "the compiler"} was rebuilt,
          so it would compile this with the old one. Restart the daemon.
          MSG
        client.close rescue nil
        return
      end

      if (client_version = request["version"]?.try(&.as_s)) && client_version != Iyi::Config.description
        daemon_refuse(client, <<-MSG)
          The build daemon and this client are different compilers.
          Daemon: #{Iyi::Config.description}
          Client: #{client_version}
          Restart the daemon, from a build of this compiler.
          MSG
        client.close rescue nil
        return
      end

      client_env = request["env"]?.try(&.as_h?)
      if client_env
        # The library, not the spelling: an unset `IYI_PATH` and one naming
        # the directory the default already resolves to are the same library,
        # and refusing over the difference would refuse most of the gates
        # that pass a path explicitly. `default_paths` is what an unset one
        # means, and `expand_paths` is what the compiler itself compares.
        theirs = client_env["IYI_PATH"]?.try(&.as_s?)
        ours = ENV["IYI_PATH"]?
        if daemon_library_key(theirs) != daemon_library_key(ours)
          daemon_refuse(client, <<-MSG)
            The build daemon analysed a different library than this build asks for.
            Daemon: IYI_PATH=#{ours || "(unset)"} -> #{daemon_library_key(ours)}
            Client: IYI_PATH=#{theirs || "(unset)"} -> #{daemon_library_key(theirs)}
            The prelude is what a daemon holds, so this one cannot serve that
            build. Start a daemon in that environment, or build without one.
            MSG
          client.close rescue nil
          return
        end
      end

      refresh.call

      out_r, out_w = IO.pipe(read_blocking: false, write_blocking: true)
      err_r, err_w = IO.pipe(read_blocking: false, write_blocking: true)

      pid = Crystal::System::Process.fork do
        # Nothing of the daemon's, and nothing of any *other* build's: an
        # inherited connection or pipe read-end left open here outlives this
        # build. Note `delete: false` — `UNIXServer#close` unlinks the socket
        # file, which would take the daemon's address away from every later
        # client while the daemon went on listening, apparently healthy.
        server.close(delete: false) rescue nil
        client.close rescue nil
        out_r.close rescue nil
        err_r.close rescue nil
        builds.each do |other|
          other.client.close rescue nil
          other.out_r.close rescue nil
          other.err_r.close rescue nil
        end

        LibC.dup2(out_w.fd, 1)
        LibC.dup2(err_w.fd, 2)

        # The request's environment, whole: every variable the compiler reads
        # is the client's — where the cache is, which mirror a package comes
        # from, which linker `PATH` finds — and a variable the daemon carries
        # that the client does not is not this build's either.
        if client_env
          ENV.keys.each { |name| ENV.delete(name) unless client_env.has_key?(name) }
          client_env.each do |name, value|
            if text = value.as_s?
              ENV[name] = text
            end
          end
        end

        Dir.cd(cwd)
        Iyi::Command.run(args)
        LibC._exit 0
      end

      out_w.close
      err_w.close

      builds << DaemonBuild.new(client, out_r, err_r, pid.not_nil!, args, cwd)
    end

    # Which library an `IYI_PATH` means, by the one file that decides it.
    # Comparing the paths themselves says no to builds that mean yes: unset
    # resolves to a list — `lib`, the installed share, the tree beside the
    # binary — and a path naming one of those directories resolves to itself,
    # so the two spellings differ while the prelude they find is the same
    # file. That file is what a daemon holds.
    # Both of them, because a daemon holds both: it analyses Crystal's at
    # start — that is the mode it is for (IV.1d) — and warms iyi's after the
    # first `.iyi` build. A path that finds either somewhere else is another
    # library.
    private def daemon_library_key(value : String?) : String
      paths =
        if text = value.presence
          Iyi::IyiPath.expand_paths(text.split(Process::PATH_DELIMITER, remove_empty: true))
        else
          Iyi::IyiPath.default_paths
        end
      ["iyi/prelude.iyi", "prelude.cr"].join(" ") do |name|
        found = paths.each do |directory|
          candidate = File.join(directory, name)
          break candidate if File.file?(candidate)
        end
        resolved = found.is_a?(String) ? (File.real_path(found) rescue found) : "(none)"
        "#{name}=#{resolved}"
      end
    end

    private def daemon_finish(build : DaemonBuild) : Bool
      status = ::Process.new(Crystal::System::Process.new(build.pid)).wait

      begin
        build.client.write_byte(DAEMON_FRAME_EXIT)
        build.client.write_bytes(status.exit_code, IO::ByteFormat::LittleEndian)
        build.client.flush
      rescue IO::Error
        # The client hung up before its build finished; nothing left to tell it.
      end

      build.client.close rescue nil
      status.success?
    end

    # Analyses the prelude for a flag set some build actually used, so the next
    # build with those flags is fast too. Macros branch on flags, so `--release`
    # and `-Dfoo` each need their own.
    #
    # Driven by builds that already *succeeded*, which is what makes it safe:
    # turning arguments into a compiler means running the option parser, and the
    # option parser exits the process on bad input. Doing that here on arguments
    # a client made up would take the daemon down on a typo.
    #
    # **In the client's directory, and that is not a detail.** The reasoning
    # above was incomplete: a succeeded build's arguments are still bad input
    # somewhere else, and `-o out app.iyi` names two relative paths. Parsed
    # here, in the daemon's own directory, `gather_sources` could not find the
    # file and `abort!` exited — so the daemon died *after serving a build
    # correctly*, on the ordinary case of a client that typed a relative path.
    # Nothing in the specs caught it because they pass absolute fixture paths.
    #
    # Safe to `cd` the daemon itself: this runs only while no build is in
    # flight, and the process is single-threaded, which is what lets it fork at
    # all.
    private def daemon_warm(cwd : String, args : Array(String)) : Nil
      limit = (Config.env("DAEMON_PRELUDES").try(&.to_i?) || 3)
      return if Compiler.preanalysed.size >= limit

      here = Dir.current
      begin
        Dir.cd(cwd)
      rescue
        # The client's directory is gone. Nothing to warm from, and nothing
        # worth taking the daemon down for.
        return
      end

      begin
        daemon_warm_in_place(args, limit)
      ensure
        Dir.cd(here) rescue nil
      end
    end

    private def daemon_warm_in_place(args : Array(String), limit : Int32) : Nil
      compiler = Iyi::Command.new(args.dup).prelude_compiler_for_build
      return if Compiler.preanalysed.has_key?(compiler.prelude_cache_key)

      elapsed = Time.instant
      preanalysed = compiler.preanalyse_prelude
      Compiler.preanalysed[preanalysed.key] = preanalysed

      switches = args.select(&.starts_with?("-")).join(' ')
      switches = "(default flags)" if switches.empty?
      STDERR.puts "prelude for #{switches} analysed in #{elapsed.elapsed.total_seconds.round(3)}s (#{Compiler.preanalysed.size}/#{limit} cached)"
      STDERR.flush
    rescue ex
      # A flag set we cannot pre-analyse just stays slow.
      STDERR.puts "daemon: could not pre-analyse a prelude: #{ex.message}"
      STDERR.flush
    end
  {% end %}

  private def daemon_frame(io : IO, kind : UInt8, bytes : Bytes) : Nil
    io.write_byte(kind)
    io.write_bytes(bytes.size.to_u32, IO::ByteFormat::LittleEndian)
    io.write(bytes)
    io.flush
  end

  # Identifies the running server's own executable, so a rebuild is noticed.
  # The version string alone cannot see it: two builds of the same commit
  # describe themselves identically, and during development that is the normal
  # case rather than the exception.
  private def daemon_identity : String
    executable = Process.executable_path
    return "an unknown build" unless executable

    info = File.info?(executable)
    return "a deleted build" unless info

    # Nanoseconds, not seconds: a rebuild that lands in the same second as the
    # daemon's start is exactly the case this has to catch.
    "#{info.size}:#{info.modification_time.to_unix_ns}"
  end

  # Writes a refusal and the exit frame. Every byte goes to a socket the
  # daemon does not own the far end of, so all of it is `rescue`d: a client
  # that hung up between its request and this answer is EPIPE, and EPIPE
  # reaching `Command#run` means `::exit 0` — the `mod dump | head` rule,
  # correct for a command writing to a pipe and fatal for a server writing
  # to one of its clients. The daemon exited 0, quietly, mid-refusal.
  private def daemon_refuse(client, message : String) : Nil
    daemon_frame(client, DAEMON_FRAME_REFUSE, message.chomp.to_slice)
    client.write_byte(DAEMON_FRAME_EXIT)
    client.write_bytes(1, IO::ByteFormat::LittleEndian)
    client.flush
  rescue IO::Error | Socket::Error
    # Nothing left to tell it. The daemon goes on serving everyone else.
  end

  # A build request is a command line and a directory. The largest one this
  # compiler can be handed is bounded by `ARG_MAX`, two megabytes on Linux
  # and one on macOS, so eight is past anything real and small enough that
  # a client claiming it costs the daemon nothing to find out. Without a
  # bound, `Bytes.new(size)` on a 4 GB header was an `OverflowError` out of
  # the accept loop, which killed the daemon — the same fault as a
  # truncated frame, arriving through the allocator.
  DAEMON_MAX_REQUEST = 8 * 1024 * 1024

  # Nil when the client closed before its first byte, which is a question
  # ("is anyone listening here?") rather than a malformed request.
  private def daemon_read_request(client) : JSON::Any?
    header = Bytes.new(4)
    first = client.read(header)
    return nil if first.zero?
    client.read_fully(header[first, 4 - first]) if first < 4

    size = IO::ByteFormat::LittleEndian.decode(UInt32, header)
    if size > DAEMON_MAX_REQUEST
      raise IO::Error.new("a request of #{size} bytes, past the #{DAEMON_MAX_REQUEST} a build request can be")
    end
    bytes = Bytes.new(size)
    client.read_fully(bytes)
    JSON.parse(String.new(bytes))
  end

  # Returns only when *fallback* is set and no daemon answered; otherwise it
  # runs the build to completion and exits with the daemon's status.
  private def daemon_build(path : String? = nil, fallback : Bool = false)
    path ||= daemon_socket_path

    begin
      client = UNIXSocket.new(path)
    rescue ex : Socket::Error | File::Error
      if fallback
        STDERR.puts "#{Command.program_name}: daemon at #{path} did not answer, building without it"
        return
      end
      # A path that is there but is not a socket is a different mistake
      # from an absent daemon, and it has a different remedy: a daemon
      # that was killed leaves its socket file behind, and starting a new
      # one on the same path answers "Address already in use" until the
      # stale file goes.
      if (info = File.info?(path)) && !info.type.socket?
        abort! "#{path} is a file, not a socket: nothing can listen there. " \
               "Remove it, or pass a `--socket` that is one", :FAILURE
      end
      abort! "no daemon listening on #{path} (start one with `#{Command.program_name} daemon start`)", :FAILURE
    end

    # The child runs a full command line, so put back the subcommand this one
    # consumed: `crystal daemon build -o x y.cr` is `crystal build -o x y.cr`.
    # The environment travels with the request. A daemon is a held prelude
    # and not a second shell: the child it forks inherited *its* variables,
    # so a build sent from a terminal with `IYI_CACHE_DIR` or
    # `IYI_MOD_MIRROR` set was resolved without them — a package went to the
    # network instead of to the mirror beside it. `IYI_PATH` is the one a
    # daemon cannot take, because the prelude it holds came from its own;
    # the server refuses that rather than compiling against a library this
    # build did not ask for.
    request = {cwd: Dir.current, args: ["build"] + options,
               version: Iyi::Config.description, env: ENV.to_h}.to_json
    client.write_bytes(request.bytesize.to_u32, IO::ByteFormat::LittleEndian)
    client.write(request.to_slice)
    client.flush

    loop do
      kind = client.read_byte
      break unless kind

      case kind
      when DAEMON_FRAME_EXIT
        exit client.read_bytes(Int32, IO::ByteFormat::LittleEndian)
      when DAEMON_FRAME_REFUSE
        size = client.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        bytes = Bytes.new(size)
        client.read_fully(bytes)
        STDERR.puts String.new(bytes)
        # The build asked for a binary, not for this daemon.
        if fallback
          STDERR.puts "#{Command.program_name}: building without it"
          client.close rescue nil
          return
        end
        exit 1
      when DAEMON_FRAME_STDOUT, DAEMON_FRAME_STDERR
        size = client.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        bytes = Bytes.new(size)
        client.read_fully(bytes)
        io = kind == DAEMON_FRAME_STDOUT ? STDOUT : STDERR
        io.write(bytes)
        io.flush
      else
        abort! "daemon sent an unknown frame #{kind}", :SOFTWARE_ERROR
      end
    end

    # End of stream without an exit frame means the daemon died mid-build.
    abort! "daemon closed the connection without reporting a result", :SOFTWARE_ERROR
  end
end
