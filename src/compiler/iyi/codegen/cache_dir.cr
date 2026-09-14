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

      filename = ::Path[filename]
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
      output_dir = File.join(dir, name)
      Dir.mkdir_p(output_dir)
      output_dir
    end

    # Keeps the 10 most recently used directories in the cache,
    # and removes all others. Directories a compiler is working in right now
    # are kept whatever their age (see `#directory_in_use?`).
    def cleanup(dir = compute_dir)
      entries = gather_cache_entries(dir)
      cleanup_dirs(entries)
    end

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
    # both names (see `Config.env`).
    private def cache_dir_variable : String
      ENV["IYI_CACHE_DIR"]? ? "IYI_CACHE_DIR" : "CRYSTAL_CACHE_DIR"
    end

    private def cleanup_dirs(entries)
      entries
        .select { |dir| Dir.exists?(dir) }
        .sort_by! { |dir| File.info?(dir).try(&.modification_time) || Time.unix(0) }
        .reverse!
        .skip(10)
        .each { |name| FileUtils.rm_rf(name) unless directory_in_use?(name) }
    end

    # iyi: whether a compiler is working in this directory right now.
    #
    # The rule above is "keep the ten most recently used", and a directory's
    # last use is read from its modification time — which stops moving while a
    # build sits in an optimization pass, writing nothing. Ten other builds in
    # that window and this one's directory was deleted underneath it, from
    # another process, mid-codegen. What came out was an object file that could
    # not be written, or a linker asking for object files nobody had written.
    #
    # A build already says it is using its directory: it holds `compiler.lock`
    # there for the whole of codegen and linking. This asks.
    def directory_in_use?(dir : String) : Bool
      lock = File.join(dir, "compiler.lock")
      return false unless File.exists?(lock)

      File.open(lock, "r") do |file|
        begin
          file.flock_exclusive(blocking: false)
        rescue IO::Error
          return true
        end
        file.flock_unlock
      end
      false
    rescue File::Error
      # The directory answered nothing we can read. Deleting it is the one
      # thing that can lose someone else's work, so don't.
      true
    end

    private def gather_cache_entries(dir)
      Dir.children(dir).map! { |name| File.join(dir, name) }
    end
  end
end
