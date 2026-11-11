require "crystal/digest/md5"

module Iyi
  # iyi: what one build read, and what it wrote: the record `UpToDate` checks
  # before the next build of the same output compiles anything (SPEC.md V.9
  # (e)).
  #
  # Kept by watching rather than by declaring. A list of the places the
  # compiler opens files would be one more list to keep in step with the
  # compiler, and the first place it missed would be a stale program that
  # runs. So `File`, `Dir` and `ENV` are reopened below, and while a build
  # holds a recorder every file it opens or asks about, every directory it
  # lists and every environment variable it reads is written down — the
  # compiler's own reads, the prelude's and the packages', a macro's
  # `read_file`, `file_exists?` and `env`, the artifacts a build reads, the
  # probes an import makes for files that are not there. Nothing is recorded
  # while no build holds one, which is every other verb, the language server
  # included.
  #
  # Some of what a build consumes cannot be watched from here: a command a
  # macro runs (`system`, `` ` ``), a `run` program that does not say what it
  # read, a linker flag that runs a command. Those say so through `cannot`,
  # and a build that heard one records nothing, so the next build compiles.
  class BuildInputs
    enum Kind : UInt8
      Absent
      File
      Directory
      Other
    end

    # What a path was when the build looked at it. Size and modification time
    # for a file; the kind alone for a directory, whose time moves whenever
    # anything beside an input is written. `digest` is the content's MD5, and
    # it is taken only for a file whose time cannot vouch for it — see
    # `racy?`.
    record Stamp, kind : Kind, size : Int64, mtime : Int64, digest : String? = nil

    ABSENT = Stamp.new(Kind::Absent, 0_i64, 0_i64)

    # What the processes a build starts read from the environment. The
    # compiler's own reads are recorded as they happen; the linker, the
    # driver in front of it and `pkg-config` are other programs, so the
    # variables those are documented to read are recorded whether or not this
    # build asked for them.
    CHILD_ENV = %w(PATH CC LIBRARY_PATH LD_LIBRARY_PATH LD_RUN_PATH COMPILER_PATH GCC_EXEC_PREFIX
      SDKROOT MACOSX_DEPLOYMENT_TARGET LIB LIBPATH LINK _LINK_)

    @@current : BuildInputs?

    # The recorder of the build running in this process, or nil.
    def self.current : BuildInputs?
      @@current
    end

    def self.current=(@@current : BuildInputs?)
    end

    # Runs the block with no recorder, for the reads that belong to the
    # check itself rather than to a build.
    def self.paused(&)
      held = @@current
      @@current = nil
      begin
        yield
      ensure
        @@current = held
      end
    end

    getter files = {} of String => Stamp
    getter written = Set(String).new
    getter listings = {} of String => Array(String)?
    getter env = {} of String => String?
    getter pkg_config = [] of {String, Bool, String?}
    getter reasons = [] of String
    # The files read whole to fingerprint them, and their bytes, for `-s`:
    # the price of a racy stamp, and the one place where the recorder's cost
    # grows with a file's size rather than with the number of files.
    getter fingerprinted = [] of String
    getter fingerprinted_bytes = 0_i64

    @mutex = Mutex.new

    # *cache_root* may be unknown when recording starts — `iyi build` starts
    # before its options are read, and the cache directory is one of them —
    # and is then set with `cache_root=`, which drops what it excludes.
    @cache_root : String? = nil
    @packages : String? = nil

    def initialize(cache_root : String?)
      @ignored = Set(String).new
      CHILD_ENV.each { |name| @env[name] = Crystal::System::Env.get(name) }
      cache_root.try { |root| self.cache_root = root }
    end

    def cache_root=(root : String) : Nil
      prefix = comparable(root.rstrip("/\\")) + KEY_SEPARATOR
      @cache_root = prefix
      @packages = prefix + "mod" + KEY_SEPARATOR
      purge
    end

    # The separator a `key` is spelled with. Not `File::SEPARATOR`, which is
    # `/` on Windows too: the cache root ended in `/`, no key spelled with `\`
    # began with it, nothing in the cache was excluded, and every build there
    # recorded the cache's own entries and was never up to date (job
    # 120816113919; the trace of the debug run that found it, 40075729028).
    KEY_SEPARATOR = {% if flag?(:win32) %} "\\" {% else %} "/" {% end %}

    # A path this build writes and records itself — the output — so that
    # nothing the compiler asks about it on the way is taken for an input.
    def ignore(path : String) : Nil
      @ignored << comparable(path)
      purge
    end

    private def purge : Nil
      @mutex.synchronize do
        @files.reject! { |path, _| excluded?(path) }
        @written.select { |path| excluded?(path) }.each { |path| @written.delete(path) }
        @listings.reject! { |dir, _| excluded?(dir) }
      end
    end

    # The absolute spelling every entry is kept under. On Windows a path can
    # arrive verbatim (`\\?\C:\...`) or with either separator, and the cache's
    # own files have to be recognised whichever way they were spelled.
    def key(path : String) : String
      BuildInputs.key(path)
    end

    # :ditto:
    def self.key(path : String) : String
      expanded = ::File.expand_path(path)
      {% if flag?(:win32) %}
        expanded = Iyi.unverbatim(expanded).tr("/", "\\")
      {% end %}
      expanded
    end

    # A `key` as names compare on this platform: without case on Windows.
    def comparable(path : String) : String
      BuildInputs.comparable(path)
    end

    # :ditto:
    def self.comparable(path : String) : String
      path = key(path)
      {% if flag?(:win32) %}
        path = path.downcase
      {% end %}
      path
    end

    # Not an input: a build's own directory in the compiler cache (its
    # objects, its macro programs, the link templates), the output, and the
    # kernel's pseudo-files. A package checkout is in the cache too, under
    # `mod/`, and it is source.
    def excluded?(path : String) : Bool
      # Compared as Windows compares names, whatever case each was spelled in.
      # *path* is already a `key`: asked under the recorder's lock (`purge`),
      # and `key` expands it, which may ask the file system again.
      {% if flag?(:win32) %}
        return true if @ignored.includes?(path.downcase)
      {% else %}
        return true if @ignored.includes?(path)
      {% end %}
      {% if flag?(:unix) %}
        return true if path.starts_with?("/proc/") || path.starts_with?("/sys/") || path.starts_with?("/dev/")
      {% end %}
      return false unless (cache_root = @cache_root) && (packages = @packages)
      {% if flag?(:win32) %}
        path = path.downcase
      {% end %}
      # The root itself too: the cleaner lists it after every build, and what
      # it holds is other programs' builds.
      return true if path.size == cache_root.size - 1 && cache_root.starts_with?(path)
      path.starts_with?(cache_root) && !path.starts_with?(packages)
    end

    # A path the build asked about or opened, with the answer it got when it
    # asked with symlinks followed, or `nil` to work the answer out here.
    def looked_at(path : String, info : ::File::Info? = nil, answered : Bool = false) : Nil
      path = key(path)
      return if excluded?(path)
      return if @mutex.synchronize { @files.has_key?(path) || @written.includes?(path) }

      stamp = answered ? BuildInputs.stamp_of(info) : BuildInputs.stamp(path)
      first = @mutex.synchronize do
        next false if @files.has_key?(path)
        @files[path] = stamp
        true
      end
      return unless first && stamp.kind.file? && BuildInputs.racy?(stamp.mtime, BuildInputs.now)

      # Written within the time its own clock can tell apart from now: a
      # same-size edit a moment later would leave size and time as they are,
      # so the content is what this build vouches for. Read before the
      # compiler's own read, so an edit between the two reaches the compiler
      # and not this digest, and the next build sees the difference.
      begin
        content = ::File.read(path)
        digest = ::Crystal::Digest::MD5.hexdigest(content)
        @mutex.synchronize do
          @files[path] = stamp.copy_with(digest: digest)
          @fingerprinted << path
          @fingerprinted_bytes += content.bytesize
        end
      rescue ex : IO::Error
        cannot("#{path} could not be read to fingerprint it: #{ex.message}")
      end
    end

    def opening(path : String, mode : String) : Nil
      if mode.includes?('w') || mode.includes?('a') || mode.includes?('+')
        wrote(path)
      else
        looked_at(path)
      end
    end

    # A path this build created or replaced. It is an output rather than an
    # input, and what is recorded for it is what it is once the build is done.
    def wrote(path : String) : Nil
      path = key(path)
      return if excluded?(path)
      @mutex.synchronize { @written << path }
    end

    # A path this build removed, which it made itself or does not depend on.
    def deleted(path : String) : Nil
      path = key(path)
      return if excluded?(path)
      @mutex.synchronize do
        @written.delete(path)
        @files.delete(path)
      end
    end

    def renamed(from : String, to : String) : Nil
      deleted(from)
      wrote(to)
    end

    # A directory whose entries the build read. What is kept is the names, so
    # a file added or removed there — a `require "./x/*"`, a glob — is seen.
    def listed(dir : String) : Nil
      dir = key(dir)
      return if excluded?(dir)
      first = @mutex.synchronize do
        next false if @listings.has_key?(dir)
        @listings[dir] = nil
        true
      end
      return unless first
      children = BuildInputs.children(dir)
      @mutex.synchronize { @listings[dir] = children }
    end

    def env_read(name : String, value : String?) : Nil
      @mutex.synchronize { @env[name] = value unless @env.has_key?(name) }
    end

    def pkg_config_read(mod : String, static : Bool, flags : String?) : Nil
      @mutex.synchronize { @pkg_config << {mod, static, flags} }
    end

    # Something this build consumed that cannot be written down, or did that a
    # skipped build could not do again. Any one of them and nothing is
    # recorded, so the next build compiles.
    def cannot(reason : String) : Nil
      @mutex.synchronize { @reasons << reason unless @reasons.includes?(reason) }
    end

    # Another recorder's inputs as this build's own: a prelude the build
    # daemon analysed before forking this build was read under that recorder.
    def merge(other : BuildInputs) : Nil
      other.files.each { |path, stamp| @files[path] = stamp unless @files.has_key?(path) }
      other.listings.each { |dir, names| @listings[dir] = names unless @listings.has_key?(dir) }
      other.env.each { |name, value| @env[name] = value unless @env.has_key?(name) }
      @pkg_config.concat(other.pkg_config)
      other.reasons.each { |reason| cannot(reason) }
    end

    # The files a `run` program said it read (`Program::RUN_INPUTS`), nil
    # when it said nothing — a program that has read what it pleased, as far
    # as anything here can tell.
    def run_declared(program : String, declared : Array(String)?, started : Int64) : Nil
      program = Iyi.relative_filename(program)
      unless declared
        cannot("`run(\"#{program}\")` did not say which files it read (a program `run` at compile time names them, " \
               "one a line, in the file $#{Program::RUN_INPUTS} names)")
        return
      end
      declared.each do |line|
        path = key(line)
        next if excluded?(path)
        stamp = BuildInputs.stamp(path)
        # The program read it before this stamp was taken. A time inside the
        # run says it may have changed in between, and a digest taken now
        # would vouch for what the program never saw.
        if stamp.kind.file? && BuildInputs.racy?(stamp.mtime, started)
          cannot("#{Iyi.relative_filename(path)} changed while `run(\"#{program}\")` was reading it")
        else
          @mutex.synchronize { @files[path] = stamp unless @files.has_key?(path) }
        end
      end
    end

    # The files a link reads, from the command the compiler ran: the absolute
    # paths in it, and the library each `-lname` names, found the way the
    # linker finds it. The objects are this build's own and in its cache.
    def linked(command : String, args : Array(String)?) : Nil
      tokens = {% if flag?(:win32) %} Process.parse_arguments_windows(command) {% else %} Process.parse_arguments_posix(command) {% end %}
      args.try { |extra| tokens.concat(extra) }
      tokens = tokens.flat_map { |token| response_file(token) || [token] }

      search = [] of String
      libraries = [] of String
      skip_next = false
      tokens.each_with_index do |token, index|
        if skip_next
          skip_next = false
          next
        end
        case token
        when "-o"
          skip_next = true
        when "-L"
          tokens[index + 1]?.try { |dir| search << key(dir) }
          skip_next = true
        when "-l"
          tokens[index + 1]?.try { |name| libraries << name }
          skip_next = true
        when .starts_with?("-L")
          search << key(token[2..])
        when .starts_with?("-l")
          libraries << token[2..]
        when .starts_with?("-Wl,")
          token[4..].split(',').each { |part| link_file(part) }
        when .starts_with?("/LIBPATH:"), .starts_with?("-LIBPATH:")
          search << key(token[9..])
        when .starts_with?("/OUT:"), .starts_with?("/Fe")
          # the output
        else
          if token.ends_with?(".lib") && !::Path[token].absolute?
            libraries << token
          else
            link_file(token)
          end
        end
      end

      # The linker's own variables, not the compiler's `IYI_LIBRARY_PATH`,
      # which `lib_flags` has already turned into `-L`.
      ENV["LIBRARY_PATH"]?.try &.split(Process::PATH_DELIMITER, remove_empty: true).each { |dir| search << key(dir) }
      ENV["LIB"]?.try &.split(Process::PATH_DELIMITER, remove_empty: true).each { |dir| search << key(dir) }
      search.concat(DEFAULT_LIBRARY_DIRS)
      {% if flag?(:darwin) %}
        # Since macOS 11 the system's libraries are not on disk: the driver
        # links the `.tbd` stubs in the SDK, which it finds as `xcrun` does.
        darwin_sdk.try { |sdk| search << key(::File.join(sdk, "usr", "lib")) }
      {% end %}
      search.uniq!

      libraries.each { |name| link_library(name, search) }
    end

    # Where a linker looks after the directories it is told about. A library
    # found in none of these and none of those is one the check cannot see,
    # and says so.
    DEFAULT_LIBRARY_DIRS = {% if flag?(:win32) %}
                             [] of String
                           {% else %}
                             %w(/lib /usr/lib /usr/local/lib /lib64 /usr/lib64 /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu
                               /lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu)
                           {% end %}

    {% if flag?(:darwin) %}
      # `SDKROOT` when it is set, which is what the driver reads first, and
      # otherwise `xcrun`'s answer. Nil when neither answers, and a library
      # only the SDK has is then one the check says it cannot see.
      private def darwin_sdk : String?
        if sdk = ENV["SDKROOT"]?.presence
          return sdk
        end
        output = IO::Memory.new
        status = Process.run("xcrun", {"--show-sdk-path"}, output: output, error: Process::Redirect::Close)
        status.success? ? output.to_s.strip.presence : nil
      rescue IO::Error
        nil
      end
    {% end %}

    private def link_file(token : String) : Nil
      return if token.empty? || token.starts_with?('-')
      # A `/DEBUG:FULL` is a switch on Windows, where it is not absolute.
      return unless ::Path[token].absolute?
      looked_at(token)
    end

    private def link_library(name : String, search : Array(String)) : Nil
      candidates =
        if name.ends_with?(".lib")
          [name]
        elsif name.starts_with?(':')
          [name[1..]]
        else
          {% if flag?(:darwin) %}
            ["lib#{name}.dylib", "lib#{name}.tbd", "lib#{name}.a"]
          {% else %}
            ["lib#{name}.so", "lib#{name}.a"]
          {% end %}
        end
      search.each do |dir|
        candidates.each do |candidate|
          path = key(::File.join(dir, candidate))
          looked_at(path)
          return if @mutex.synchronize { @files[path]?.try(&.kind.file?) }
        end
      end
      cannot("the linker found `#{name}` somewhere this check cannot see")
    end

    # The arguments in a response file (`@file`), which a link uses when its
    # command line would be too long — on Windows a large program's always is.
    # The compiler writes two kinds (`linker_command`): UTF-16 with a byte
    # order mark for the MSVC linker, read the way Windows reads a command
    # line; and GCC's, where a backslash escapes the character after it.
    private def response_file(token : String) : Array(String)?
      return nil unless token.starts_with?('@') && token.size > 1
      bytes = ::File.open(token[1..], "rb", &.getb_to_end)
      if bytes.size >= 2 && bytes[0] == 0xFF_u8 && bytes[1] == 0xFE_u8
        units = Slice.new((bytes.to_unsafe + 2).as(UInt16*), (bytes.size - 2) // 2)
        String.from_utf16(units).lines.flat_map { |line| Process.parse_arguments_windows(line) }
      else
        BuildInputs.gcc_response_arguments(String.new(bytes))
      end
    rescue IO::Error
      cannot("the link read its arguments from #{token[1..]}, which could not be read back")
      [] of String
    end

    def self.gcc_response_arguments(text : String) : Array(String)
      arguments = [] of String
      current = String::Builder.new
      started = false
      escaped = false
      text.each_char do |char|
        if escaped
          current << char
          escaped = false
        elsif char == '\\'
          escaped = true
          started = true
        elsif char.ascii_whitespace?
          if started
            arguments << current.to_s
            current = String::Builder.new
            started = false
          end
        else
          current << char
          started = true
        end
      end
      arguments << current.to_s if started
      arguments
    end

    # Nanoseconds since the epoch, the unit every stamp is kept in.
    def self.now : Int64
      nanoseconds(Time.utc)
    end

    def self.nanoseconds(time : Time) : Int64
      time.to_unix * 1_000_000_000_i64 + time.nanosecond
    end

    # Whether a file stamped at *at* could still change without its size and
    # time saying so. A file system that keeps nanoseconds still takes the
    # time from a clock that ticks every few milliseconds (a jiffy on Linux,
    # 15.6 ms on Windows), and one that keeps whole seconds — FAT keeps two —
    # writes `.000000000`, which is how the two are told apart. Inside that
    # tick, a second write of the same size leaves the stamp as it was.
    def self.racy?(mtime : Int64, at : Int64) : Bool
      margin = mtime % 1_000_000_000_i64 == 0 ? 2_000_000_000_i64 : 100_000_000_i64
      mtime >= at - margin
    end

    def self.stamp(path : String) : Stamp
      stamp_of(Crystal::System::File.info?(path, true))
    end

    def self.stamp_of(info : ::File::Info?) : Stamp
      return ABSENT unless info
      case info.type
      when .file?
        Stamp.new(Kind::File, info.size, nanoseconds(info.modification_time))
      when .directory?
        Stamp.new(Kind::Directory, 0_i64, 0_i64)
      else
        Stamp.new(Kind::Other, 0_i64, 0_i64)
      end
    end

    # The names in *dir*, sorted, or nil when it cannot be listed.
    def self.children(dir : String) : Array(String)?
      BuildInputs.paused { Dir.children(dir).sort! }
    rescue File::Error
      nil
    end
  end
end

# The reads, observed. Each calls through to the definition it replaces; the
# recorder sees the path only when a build holds one.
class File
  def self.info?(path : Path | String, follow_symlinks = true) : Info?
    info = previous_def
    if inputs = Iyi::BuildInputs.current
      follow_symlinks ? inputs.looked_at(path.to_s, info, answered: true) : inputs.looked_at(path.to_s)
    end
    info
  end

  def self.info(path : Path | String, follow_symlinks = true) : Info
    info = previous_def
    if inputs = Iyi::BuildInputs.current
      follow_symlinks ? inputs.looked_at(path.to_s, info, answered: true) : inputs.looked_at(path.to_s)
    end
    info
  rescue ex : File::Error
    Iyi::BuildInputs.current.try &.looked_at(path.to_s)
    raise ex
  end

  def self.exists?(path : Path | String) : Bool
    answer = previous_def
    Iyi::BuildInputs.current.try &.looked_at(path.to_s)
    answer
  end

  protected def self.new_internal(filename, mode = "r", perm = DEFAULT_CREATE_PERMISSIONS, encoding = nil, invalid = nil, blocking = nil)
    Iyi::BuildInputs.current.try &.opening(filename.to_s, mode)
    previous_def
  end

  def self.delete(path : Path | String) : Nil
    previous_def
    Iyi::BuildInputs.current.try &.deleted(path.to_s)
  end

  def self.delete?(path : Path | String) : Bool
    answer = previous_def
    Iyi::BuildInputs.current.try &.deleted(path.to_s)
    answer
  end

  def self.rename(old_filename : Path | String, new_filename : Path | String) : Nil
    previous_def
    Iyi::BuildInputs.current.try &.renamed(old_filename.to_s, new_filename.to_s)
  end
end

class Dir
  def initialize(path : Path | String)
    previous_def
    Iyi::BuildInputs.current.try &.listed(@path)
  end

  def self.mkdir(path : Path | String, mode : Int32 = 0o777) : Nil
    previous_def
    Iyi::BuildInputs.current.try &.wrote(path.to_s)
  end
end

module ENV
  def self.fetch(key : String, &block : String -> T) : String | T forall T
    value = Crystal::System::Env.get(key)
    Iyi::BuildInputs.current.try &.env_read(key, value)
    value ? value : yield key
  end

  def self.has_key?(key : String) : Bool
    value = Crystal::System::Env.get(key)
    Iyi::BuildInputs.current.try &.env_read(key, value)
    !value.nil?
  end
end
