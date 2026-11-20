require "crystal/digest/md5"

module Iyi
  # Manages cache files in the ".iyi" directory.
  #
  # For each compiled program a directory is created in the cache
  # that stores .bc and .o files that could possibly be reused
  # from a previous compilation.
  #
  # To keep the cache dir small, only the 10 most recently used
  # directories are kept. We use the directory's modification
  # time for this.
  class CacheDir
    def self.instance
      @@instance ||= new
    end

    @dir : String?

    private def initialize
    end

    # Returns the directory where cache files related to the
    # given sources will be stored. The directory will be
    # created if it doesn't exist.
    def directory_for(sources : Array(Compiler::Source))
      directory_for(sources.first.filename)
    end

    # Returns the directory where cache files related to the
    # given filenames will be stored. The directory will be
    # created if it doesn't exist.
    def directory_for(filename : String)
      dir = compute_dir

      # iyi: without a verbatim prefix (`Iyi.unverbatim`): `::Path` reads
      # `\\?\C:\p\main.iyi` as the anchor `\\?\` and the parts `C:`, `p`,
      # ..., and the name came out `\-C:-p-main.iyi`, which Windows refuses
      # for its colon - `iyi run`, `build` and `test` of such an entry
      # stopped at "The directory name is invalid".
      filename = ::Path[Iyi.unverbatim(filename)]
      name = String.build do |io|
        filename.each_part do |part|
          if io.empty?
            if part == "#{filename.anchor}"
              part = "#{filename.drive}"[..0]
            end
          else
            io << '-'
          end
          io << part
        end
      end
      {% if flag?(:win32) %}
        # And a name Windows keeps as written, which one holding a colon -
        # the verbatim prefix's leftover above - is not, nor one ending in a
        # space: Win32 drops a trailing space from the last part of a path
        # and keeps it everywhere else, so for `iyi run "hello.iyi "` the
        # directory was made as `...-hello.iyi` and then written into as
        # `...-hello.iyi \`: "The system cannot find the path specified".
        name = name.gsub { |char| char.in?('<', '>', ':', '"', '/', '\\', '|', '?', '*') || char.ord < 32 ? '-' : char }
        name += "-" if name.ends_with?(' ') || name.ends_with?('.')
      {% end %}
      output_dir = File.join(dir, bounded_name(name, dir))
      Dir.mkdir_p(output_dir)
      output_dir
    end

    # iyi: the name is the source's whole path, and a path is longer than a
    # name may be. A file's path of 255 characters or more made a name no
    # file system takes, on any platform; on Windows the cache directory's
    # own path passes MAX_PATH far sooner - a program at a 222-character
    # path, which Windows opens, did not build: "The system cannot find the
    # path specified", for a cache directory 262 characters long. Past the
    # limit the name keeps its end - the file and the directories nearest
    # it, the part a person reads - behind a digest of the whole, which is
    # what keeps two deep paths that end alike apart.
    NAME_LIMIT = 100

    # On Windows the limit is also what MAX_PATH leaves after the cache root
    # and the longest file written inside: a unit's object is at most 50
    # characters of name, the optimization suffix and `.obj.tmp`, and the
    # separators. A fixed 100 assumed a short root, and IYI_CACHE_DIR is the
    # author's: under a 101-character root a program's 96-character name
    # left its 61-character object 260 characters long, and `iyi run`
    # stopped at "a codegen thread failed: Error renaming file ...: The
    # system cannot find the path specified".
    WINDOWS_PATH_LIMIT = 259
    OBJECT_NAME_SIZE   =  61

    private def bounded_name(name : String, root : String) : String
      limit = NAME_LIMIT
      {% if flag?(:win32) %}
        limit = Math.min(limit, WINDOWS_PATH_LIMIT - root.size - 1 - 1 - OBJECT_NAME_SIZE)
        # A digest and one character of the path is the shortest name that
        # is still this program's; a root that leaves less than that leaves
        # no room for any build, and saying so beats a failed rename.
        if limit < 34
          raise Iyi::Error.new("the cache directory #{root} is #{root.size} characters long, and the files a build " \
                               "writes under it would pass Windows' #{WINDOWS_PATH_LIMIT + 1}-character path limit. " \
                               "Point #{cache_dir_variable} at a directory of at most #{WINDOWS_PATH_LIMIT - 2 - OBJECT_NAME_SIZE - 34} characters")
        end
      {% end %}
      return name if name.size <= limit
      digest = ::Crystal::Digest::MD5.hexdigest(name)
      "#{digest}-#{name[(name.size - (limit - digest.size - 1))..]}"
    end

    # Keeps the 10 most recently used directories in the cache,
    # and removes all others. Directories a compiler is working in right now
    # are kept whatever their age (see `#hold` and `#remove`).
    #
    # iyi: and a macro's `run` program counts only against the others, ten
    # of them kept apart (`MACRO_RUN`). It is the program's to build again
    # whenever it is gone, inside `Semantic (main)`, and every program that
    # runs it shares it: counted with the builds, ten builds of anything
    # else removed std/eiy's, and the next build of a 10,700-line
    # application that renders templates, nothing in it changed, took
    # 6.03 to 14.17 s in `Semantic (main)` instead of 3.28 to 3.81 - 2.06 to
    # 4.47 s building the helper again, and once 9.21 s for its 51 runs,
    # a program Windows had not yet seen starting (Windows 11, five rounds).
    # Kept apart, the same five rounds took 3.44 to 4.11 s. And the files at
    # the root that builds share - reach verdicts and link templates - are
    # kept by their own counts (`#cleanup_used`).
    def cleanup(dir = compute_dir)
      entries = gather_cache_entries(dir)
      cleanup_dirs(entries)
      cleanup_used(entries, REACH, REACH_KEPT)
      cleanup_used(entries, LINK_TEMPLATE, LINK_KEPT)
    end

    # What a macro's `run` program is called in its directory.
    MACRO_RUN = "macro_run"

    # How many directories of each kind the rotation keeps.
    KEPT = 10

    # iyi: what a std module's reach verdict is called at the cache root,
    # before its key (`ReachProof#verdict_path`). A verdict is keyed by its
    # module's bytes, the flags and this compiler's executable, so every
    # program importing the module reads the one any of them wrote, and
    # every rebuild of the compiler starts a new set: ~/.cache/iyi on the
    # project's Mac held 24,428 of them (59.6 MB), this Linux box's 16,660,
    # nearly all for compilers long gone. One a build finds gone, before or
    # while reading it, is proven again over the build's own code as in a
    # cold cache, and stored again with the same answer.
    REACH = "reach-"

    # The std modules that hold a `@[SafeReach]` claim, each of which a build
    # reads or writes one verdict for: twelve today (`bench/rebuild_reuse.py`
    # step 8 counts them).
    REACH_MODULES = 12

    # How many verdicts the rotation keeps: every verdict the builds and the
    # helpers it keeps may each have used last.
    REACH_KEPT = 2 * KEPT * REACH_MODULES

    # iyi: what the linker command a driver computed is called at the cache
    # root, before its key (`Compiler#iyi_link_template`, Linux only). The
    # key is the driver, the link and library flags and the target, so each
    # set of libraries a program links, and each linker its flags pick, has
    # one, the compiler's own `crystal` builds of `iyi` among them: this
    # Linux box held 166, written over two months. One a build finds gone is
    # asked of the driver again (`cc -###`) and stored again.
    LINK_TEMPLATE = "link-template-"

    # How many link templates the rotation keeps: a build or a helper links
    # once, through one template.
    LINK_KEPT = 2 * KEPT

    # Returns a filename that has prepended the cache directory.
    def join(filename)
      dir = compute_dir
      File.join(dir, filename)
    end

    # Returns the cache directory.
    def dir
      compute_dir
    end

    private def compute_dir
      dir = @dir
      return dir if dir

      # iyi: a blank one names no directory. `IYI_CACHE_DIR=""` is what a
      # shell makes of `IYI_CACHE_DIR="$DIR"` with `DIR` unset, and
      # `File.expand_path("")` is the working directory — so a build wrote
      # its `.bc` and `.o` files, its linker probe and its link templates
      # beside the source under names nobody typed, and `clear_cache`,
      # which is `rm -rf` on this answer, took the whole project with it:
      # sources, notes and all, exit 0. The same shell accident as `-o ""`,
      # and the same answer. Quoted in the message because the value is
      # what is wrong with it and an unquoted one prints as nothing.
      if (named = Config.env("CACHE_DIR")) && named.blank?
        raise Iyi::Error.new("#{cache_dir_variable} is #{named.inspect} and that names no directory. " \
                             "Point it at one, or unset it for #{Iyi::Command.program_name}'s own")
      end

      # Try to use one of these as a cache directory, in order
      candidates = {% begin %}
        [
          Config.env("CACHE_DIR"),
          {% if flag?(:windows) %}
            ENV["LOCALAPPDATA"]?.try { |dir| "#{dir}/iyi/cache" },
            ENV["USERPROFILE"]?.try { |home| "#{home}/.cache/iyi" },
            ENV["USERPROFILE"]?.try { |home| "#{home}/.iyi" },
          {% else %}
            ENV["XDG_CACHE_HOME"]?.try { |home| "#{home}/iyi" },
            ENV["HOME"]?.try { |home| "#{home}/.cache/iyi" },
            ENV["HOME"]?.try { |home| "#{home}/.iyi" },
          {% end %}
          ".iyi",
        ]
      {% end %}
      candidates = candidates
        .compact
        .map! { |file| File.expand_path(file) }
        .uniq!

      # Return the first one for which we could create a directory
      candidates.each_with_index do |candidate, index|
        Dir.mkdir_p(candidate)
        return @dir = candidate
      rescue File::Error
        # iyi: unless it is the one the author named. The list below it
        # is defaults, and falling through defaults is what a default is
        # for; `IYI_CACHE_DIR` is an instruction. Pointed at a path that
        # cannot be a directory it was skipped in silence, and the build
        # went on writing megabytes into `~/.cache/iyi` — which is the
        # whole thing the variable was set to stop.
        if index.zero? && Config.env("CACHE_DIR")
          raise Iyi::Error.new("#{cache_dir_variable} is #{candidate} and that cannot be a directory. " \
                               "Point it somewhere writable, or unset it for #{Iyi::Command.program_name}'s own")
        end
        # Try next one
      end

      msg = String.build do |io|
        io.puts "Error: can't create cache directory."
        io.puts
        io.puts "#{Iyi::Command.program_name} needs a cache directory. These directories were candidates for it:"
        io.puts
        candidates.each do |candidate|
          io << " - " << candidate << '\n'
        end
        io.puts
        io.puts "but none of them are writable."
        io.puts
        io.puts "Please specify a writable cache directory by setting the IYI_CACHE_DIR environment variable."
      end

      puts msg
      exit 1
    end

    # Which of the two names above the author actually set: a sentence
    # about `IYI_CACHE_DIR` read by somebody who set `CRYSTAL_CACHE_DIR`
    # names a variable they do not have, and this compiler answers under
    # both names (see `Config.env`). Neither set is the default's, and
    # IYI_CACHE_DIR is the one to set.
    private def cache_dir_variable : String
      ENV["IYI_CACHE_DIR"]? || !ENV["CRYSTAL_CACHE_DIR"]? ? "IYI_CACHE_DIR" : "CRYSTAL_CACHE_DIR"
    end

    private def cleanup_dirs(entries)
      helpers, builds = entries
        .select { |dir| Dir.exists?(dir) }
        .partition { |dir| File.exists?(File.join(dir, MACRO_RUN)) }
      {builds, helpers}.each do |dirs|
        dirs
          .sort_by! { |dir| File.info?(dir).try(&.modification_time) || Time.unix(0) }
          .reverse!
          .skip(KEPT)
          .each { |dir| remove(dir) }
      end
    end

    # iyi: keeps the *kept* files named *prefix* that were used last and
    # removes the others: reach verdicts (`REACH`) and link templates
    # (`LINK_TEMPLATE`). The rotation passed over files, and nothing removed
    # these. Each is shared by every program whose key is the same, so it
    # belongs to no build directory, and is kept by its last use as a
    # directory is: its modification time, which a build that reads it moves
    # (`#used`), and as many as the builds and helpers the rotation keeps may
    # each have used last.
    #
    # No lock: a build that finds one gone, before or while reading it,
    # computes it again as it does in a cold cache and stores it again (see
    # each prefix), so a removal under a concurrent build costs it that and
    # never changes what it builds. One already read is in memory, and an
    # open read survives the delete (unlinked on POSIX, opened with
    # FILE_SHARE_DELETE on Windows). A writer's `.tmp`, left by one that
    # died, goes by the same rule; one being written is the newest there is.
    private def cleanup_used(entries, prefix : String, kept : Int32)
      entries
        .compact_map do |path|
          next unless File.basename(path).starts_with?(prefix)
          info = File.info?(path)
          {path, info.modification_time} if info && info.file?
        end
        .sort_by! { |(_, time)| time }
        .reverse!
        .skip(kept)
        .each do |(path, _)|
          begin
            File.delete?(path)
          rescue File::Error
          end
        end
    end

    # iyi: marks the file at *path*, one the rotation keeps by its last use
    # (`#cleanup_used`), used now: one every build reads and none writes
    # again would otherwise age out under the builds that need it. Not
    # `File.touch`, which makes the file when a rotation has just removed
    # it, an empty one the next build reads as none.
    def used(path : String) : Nil
      now = Time.utc
      File.utime(now, now, path)
    rescue File::Error
    end

    # The file a build's directory is held by (`#hold`), which a removal
    # holds too (`#remove`).
    LOCK = "compiler.lock"

    # iyi: holds *dir* for a build, made if it is not there, and returns the
    # locked file; the directory is the build's until the file is closed.
    #
    # The rule above is "keep the ten most recently used", and a directory's
    # last use is read from its modification time — which stops moving while a
    # build sits in an optimization pass, writing nothing, and does not move at
    # all for a build that reuses every object. A build held its directory for
    # its codegen and link only, and a removal asked whether anyone held it and
    # then deleted it, holding nothing: a build that took its directory after
    # the question and before the last file was gone kept the objects it found
    # and linked after they were deleted. On the self-hosted Mac, three CI jobs
    # sharing one cache, a broken copy of the std/secure_dns exercise stopped
    # at "clang: error: no such file or directory: 'P-ointer40U-I-nt841.o0.o'"
    # (job 135882647898) while another job built nine samples, each ending in
    # a rotation. Now a removal holds the lock while it deletes, and the lock
    # file goes last: a build that waited on it, or took it while the removal
    # was about to delete it, finds the file it holds is no longer the one at
    # `compiler.lock`, and makes the directory again.
    def hold(dir : String) : File
      lock = File.join(dir, LOCK)
      loop do
        Dir.mkdir_p(dir)
        begin
          file = File.open(lock, "a")
        rescue File::NotFoundError
          # Removed between the two lines above.
          next
        end
        begin
          file.flock_exclusive
          return file if File.info?(lock).try(&.same_file?(file.info))
        rescue ex
          file.close
          raise ex
        end
        file.close
      end
    end

    # iyi: removes a build's directory unless a build holds it (`#hold`),
    # holding its lock until everything else in it is gone. Each entry on its
    # own and its errors passed over: a build starting outside the hold
    # forgets its up-to-date record (`UpToDate#forget`), and one entry gone first
    # stopped the whole removal, 50,000 files left behind. A directory that
    # cannot be locked is left for a later rotation, and one that cannot be
    # emptied keeps what is left, which a build reads as it reads any cache:
    # an object without its bitcode is compiled again.
    private def remove(dir : String) : Nil
      lock = File.join(dir, LOCK)
      File.open(lock, "a") do |file|
        begin
          file.flock_exclusive(blocking: false)
        rescue IO::Error
          return
        end
        Dir.children(dir).each { |name| FileUtils.rm_rf(File.join(dir, name)) unless name == LOCK }
        File.delete(lock)
      end
      Dir.delete(dir)
    rescue File::Error | IO::Error
    end

    # iyi: what the cache root holds besides build directories, which the
    # rotation leaves alone. `mod` is every package checkout `iyi get` made
    # (`Mod::Fetcher`), and a checkout is what iyi.sum pins, not a build's
    # leftovers: its modification time moves only when a new host's
    # directory is made under it, so eleven builds after a `get` it was the
    # oldest entry and was deleted, and a project that had built a minute
    # earlier answered "cannot fetch example.com/me/greet v0.1.0" offline.
    # `clear_cache` still removes it. The root's files - `msvc-probe`,
    # `linker-probe`, a runner's leftovers (`Iyi.sweep_run_leftovers`) - are
    # not directories and the rotation passes over them, all but the reach
    # verdicts and the link templates, which it keeps by a rule of their own
    # (`#cleanup_used`).
    NOT_BUILDS = {"mod"}

    private def gather_cache_entries(dir)
      Dir.children(dir).reject!(&.in?(NOT_BUILDS)).map! { |name| File.join(dir, name) }
    end
  end
end
