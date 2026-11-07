require "c/signal"
require "c/unistd"

# iyi: `posix_spawn` where the C library has every file action a spawn here
# asks for, `fork` + `exec` everywhere else.
#
# `fork` copies the parent's page tables and write-protects every page it
# has, so what one costs grows with the parent. A compiler built without a
# collector never hands memory back, and it starts the EIY helper once per
# template inside `Semantic (main)`: 100 `Process.run` of `/bin/true` from a
# process holding 0, 256 and 1,024 MB took 0.73, 5.82 and 22.39 ms each with
# `fork` and 0.52, 0.49 and 0.47 ms with `posix_spawn`, and on a 12,000-line
# generated web app 240 helper runs took 3.87 s of a 7.12 s
# `Semantic (main)` that the same 240 runs from a shell finish in 0.21 s
# (#143). glibc and musl spawn with `CLONE_VM | CLONE_VFORK`, and darwin's
# is a system call, so neither copies anything.
#
# glibc 2.29, musl 1.1.24 and macOS 10.15 are where
# `posix_spawn_file_actions_addchdir_np` arrived, and it is the one action
# a `chdir:` needs; the release tarball's floor is glibc 2.31. A target this
# list does not name keeps `fork`.
{% if (flag?(:linux) && (flag?(:gnu) || flag?(:musl))) || flag?(:darwin) %}
  lib LibC
    # Opaque here: these are only ever handed back to the library by
    # pointer, so the storage needs to be at least as large and as aligned as
    # each C library's own (80 and 336 bytes on 64-bit glibc and musl, one
    # pointer on darwin), and 512 bytes of `UInt64` is.
    alias PosixSpawnFileActionsT = UInt64[64]
    alias PosixSpawnattrT = UInt64[64]

    # The same value in glibc, musl and darwin.
    POSIX_SPAWN_SETSIGMASK = 0x08
    POSIX_SPAWN_SETPGROUP  = 0x02

    fun posix_spawn(pid : PidT*, path : Char*, file_actions : PosixSpawnFileActionsT*, attrp : PosixSpawnattrT*, argv : Char**, envp : Char**) : Int
    fun posix_spawnp(pid : PidT*, file : Char*, file_actions : PosixSpawnFileActionsT*, attrp : PosixSpawnattrT*, argv : Char**, envp : Char**) : Int
    fun posix_spawn_file_actions_init(file_actions : PosixSpawnFileActionsT*) : Int
    fun posix_spawn_file_actions_destroy(file_actions : PosixSpawnFileActionsT*) : Int
    fun posix_spawn_file_actions_adddup2(file_actions : PosixSpawnFileActionsT*, fd : Int, newfd : Int) : Int
    fun posix_spawn_file_actions_addclose(file_actions : PosixSpawnFileActionsT*, fd : Int) : Int
    fun posix_spawn_file_actions_addchdir_np(file_actions : PosixSpawnFileActionsT*, path : Char*) : Int
    fun posix_spawnattr_init(attr : PosixSpawnattrT*) : Int
    fun posix_spawnattr_destroy(attr : PosixSpawnattrT*) : Int
    fun posix_spawnattr_setflags(attr : PosixSpawnattrT*, flags : Short) : Int
    fun posix_spawnattr_setsigmask(attr : PosixSpawnattrT*, sigmask : SigsetT*) : Int
    fun posix_spawnattr_setpgroup(attr : PosixSpawnattrT*, pgroup : PidT) : Int
  end
{% end %}

lib LibC
  fun setpgid(pid : PidT, pgid : PidT) : Int
end

struct Crystal::System::Process
  def self.spawn(prepared_args, shell, env, clear_env, input, output, error, chdir, new_pgroup : Bool = false, &)
    envp = Env.make_envp(env, clear_env)

    {% if LibC.has_method?(:posix_spawn_file_actions_addchdir_np) %}
      if pid = posix_spawn(prepared_args, envp, input, output, error, chdir, new_pgroup) { |errno, command| yield errno, command }
        return pid
      end
    {% end %}

    r, w = FileDescriptor.system_pipe

    pid = self.fork_for_exec(new_pgroup)
    if !pid
      LibC.close(r)
      begin
        self.try_replace(prepared_args, envp, input, output, error, chdir)
        byte = 1_u8
        errno = Errno.value.to_i32
        FileDescriptor.write_fully(w, pointerof(byte))
        FileDescriptor.write_fully(w, pointerof(errno))
      rescue ex
        byte = 0_u8
        message = ex.inspect_with_backtrace
        FileDescriptor.write_fully(w, pointerof(byte))
        FileDescriptor.write_fully(w, message.to_slice)
      ensure
        LibC.close(w)
        LibC._exit 127
      end
    end

    LibC.close(w)
    reader_pipe = IO::FileDescriptor.new(r)

    begin
      case reader_pipe.read_byte
      when nil
        # Pipe was closed, no error
      when 0
        # Error message coming
        message = reader_pipe.gets_to_end
        raise RuntimeError.new("Error executing process: '#{prepared_args[0]}': #{message}")
      when 1
        # Errno coming
        # can't use IO#read_bytes(Int32) because we skipped system/network
        # endianness check when writing the integer while read_bytes would;
        # we thus read it in the same as order as written
        buf = uninitialized StaticArray(UInt8, 4)
        reader_pipe.read_fully(buf.to_slice)
        raise_exception_from_errno(prepared_args[0], Errno.new(buf.unsafe_as(Int32))) do |errno, command|
          yield errno, command
        end
      else
        raise RuntimeError.new("BUG: Invalid error response received from subprocess")
      end
    ensure
      reader_pipe.close
    end

    pid
  end

  {% if LibC.has_method?(:posix_spawn_file_actions_addchdir_np) %}
    # What `try_replace` does in a forked child, as file actions, or nil
    # where one of them has no action that does exactly the same, and the
    # caller forks instead:
    #
    # * each standard stream is `dup2`ed onto 0, 1 or 2, or that descriptor
    #   closed where the stream is closed;
    # * the descriptor's file status is made blocking. That flag belongs to
    #   the open file description, which parent and child share, so doing it
    #   here is what the child's `fcntl` did;
    # * the child clears close-on-exec on 0, 1 and 2. `dup2` onto another
    #   descriptor clears it, and a stream that already is 0, 1 or 2 is
    #   passed as it is - unless it is close-on-exec here, which a file
    #   action cannot undo on every platform, so that one forks;
    # * `chdir`, then the program, looked up on the parent's `PATH` as
    #   `execvpe` does. A program the kernel will not execute (`ENOEXEC`)
    #   forks too: glibc's `execvpe` runs it with `/bin/sh` and
    #   `posix_spawnp` does not.
    #
    # The child starts with no signal blocked, as the forked one did. Every
    # other descriptor is close-on-exec already (`FileDescriptor.system_pipe`,
    # `O_CLOEXEC`), and closes as it did.
    private def self.posix_spawn(prepared_args, envp, input, output, error, chdir, new_pgroup : Bool = false, &) : LibC::PidT?
      streams = {input, output, error}
      targets = {ORIGINAL_STDIN, ORIGINAL_STDOUT, ORIGINAL_STDERR}

      3.times do |i|
        source = streams[i]
        next if source.closed?
        return nil if to_real_fd(source).fd == targets[i].fd && to_real_fd(source).close_on_exec?
      end

      actions = uninitialized LibC::PosixSpawnFileActionsT
      attributes = uninitialized LibC::PosixSpawnattrT
      return nil unless LibC.posix_spawn_file_actions_init(pointerof(actions)) == 0
      unless LibC.posix_spawnattr_init(pointerof(attributes)) == 0
        LibC.posix_spawn_file_actions_destroy(pointerof(actions))
        return nil
      end

      begin
        3.times do |i|
          source, target = streams[i], targets[i].fd
          if source.closed?
            if LibC.fcntl(target, LibC::F_GETFD) != -1
              return nil unless LibC.posix_spawn_file_actions_addclose(pointerof(actions), target) == 0
            end
          else
            source = to_real_fd(source)
            FileDescriptor.set_blocking(source.fd, true)
            unless source.fd == target
              return nil unless LibC.posix_spawn_file_actions_adddup2(pointerof(actions), source.fd, target) == 0
            end
          end
        end

        if chdir
          return nil unless LibC.posix_spawn_file_actions_addchdir_np(pointerof(actions), chdir.check_no_null_byte) == 0
        end

        mask = uninitialized LibC::SigsetT
        LibC.sigemptyset(pointerof(mask))
        return nil unless LibC.posix_spawnattr_setsigmask(pointerof(attributes), pointerof(mask)) == 0
        flags = LibC::POSIX_SPAWN_SETSIGMASK
        if new_pgroup
          flags |= LibC::POSIX_SPAWN_SETPGROUP
          return nil unless LibC.posix_spawnattr_setpgroup(pointerof(attributes), 0) == 0
        end
        return nil unless LibC.posix_spawnattr_setflags(pointerof(attributes), flags.to_i16) == 0

        file, argv = prepared_args
        pid = uninitialized LibC::PidT
        ret = lock_write do
          pthread_disable_cancelstate do
            {% if LibC.has_method?("execvpe") && !flag?("execvpe_impl") %}
              LibC.posix_spawnp(pointerof(pid), file, pointerof(actions), pointerof(attributes), argv, envp)
            {% else %}
              # No `execvpe` here, so the fork path searches `PATH` with
              # `execvpe_impl`, and so does this, one `posix_spawn` per
              # candidate where that one makes one `execve`. Nothing tried
              # (an empty name, one too long) leaves its error in `Errno`.
              found = -1
              execvpe_impl(file) do |candidate|
                found = LibC.posix_spawn(pointerof(pid), candidate, pointerof(actions), pointerof(attributes), argv, envp)
                Errno.value = Errno.new(found)
                break if found == 0
              end
              found == 0 ? 0 : Errno.value.value
            {% end %}
          end
        end

        return pid if ret == 0
        return nil if ret == Errno::ENOEXEC.value

        raise_exception_from_errno(file, Errno.new(ret)) do |errno, command|
          yield errno, command
        end
      ensure
        LibC.posix_spawnattr_destroy(pointerof(attributes))
        LibC.posix_spawn_file_actions_destroy(pointerof(actions))
      end
    end
  {% end %}

  private def self.fork_for_exec(new_pgroup : Bool = false)
    pid, errno = lock_write do
      pthread_disable_cancelstate do
        block_signals do |sigmask|
          pid = LibC.fork
          if pid == 0
            # forked process

            Crystal::System::Signal.after_fork_before_exec

            if new_pgroup
              LibC.setpgid(0, 0)
            end
            # reset sigmask (inherited on exec)
            LibC.sigemptyset(sigmask)
          end
          {pid, Errno.value}
        end
      end
    end

    case pid
    when 0
      # forked process
      nil
    when -1
      # forking process: error
      raise RuntimeError.from_os_error("fork", errno)
    else
      # forking process: success
      pid
    end
  end

  # This method is similar to `.replace` (used for `Process.exec`) with some
  # differences because we're limited in what we can do in the pre-exec phase
  # between `fork` and `exec`.
  private def self.try_replace(prepared_args, envp, input, output, error, chdir)
    reopen_io(input, ORIGINAL_STDIN)
    reopen_io(output, ORIGINAL_STDOUT)
    reopen_io(error, ORIGINAL_STDERR)

    if chdir
      if 0 != LibC.chdir(chdir)
        return
      end
    end

    execvpe(*prepared_args, envp)
  end
end
