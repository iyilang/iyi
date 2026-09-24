require "./config"
require "./error"

module Iyi
  struct IyiPath
    class NotFoundError < Iyi::Error
      getter filename
      getter relative_to

      def initialize(@filename : String, @relative_to : String?)
        if relative_to = @relative_to
          super "can't find #{@filename.inspect} relative to #{relative_to.inspect}"
        else
          super "can't find #{@filename.inspect}"
        end
      end
    end

    private DEFAULT_LIB_PATH = "lib"

    def self.default_paths : Array(String)
      if path = Config.env("PATH")
        path_array = path.split(Process::PATH_DELIMITER, remove_empty: true)
      elsif path = Iyi::Config.path.presence
        path_array = path.split(Process::PATH_DELIMITER, remove_empty: true)
        unless path_array.includes?(DEFAULT_LIB_PATH)
          path_array.unshift DEFAULT_LIB_PATH
        end
      else
        path_array = [DEFAULT_LIB_PATH]
      end

      expand_paths(path_array)

      path_array
    end

    def self.default_path : String
      default_paths.join(Process::PATH_DELIMITER)
    end

    # iyi: the entries a module is looked for under, for a program whose
    # project is at *roots*: each entry as it is, and a relative one - the
    # default `lib`, above all - also under each root. As it is, a relative
    # entry is the working directory's, which is Crystal's reading, and it
    # made `import iyi_web/dsl` from a project's `lib/` a build that worked
    # only when started in the project: `iyi run C:\app\app.iyi` from
    # anywhere else, and the language server, whose working directory is
    # the editor's, answered "can't find module". The working directory's
    # answer comes first, so a build that resolved before resolves the same.
    def self.rooted(entries : Array(String), roots : Array(String)) : Array(String)
      rooted = [] of String
      entries.each do |entry|
        rooted << entry
        next if ::Path[entry].absolute?
        roots.each do |root|
          under = File.join(root, entry)
          next if File.expand_path(under) == File.expand_path(entry)
          rooted << under
        end
      end
      rooted.uniq
    end

    # Expand `$ORIGIN` in the paths to the directory where the compiler binary
    # is located (at runtime).
    # For install locations like
    #    `/path/prefix/bin/crystal`         for the compiler
    #    `/path/prefix/share/crystal/src`   for the standard library
    # the path `$ORIGIN/../share/crystal/src` resolves to
    # the standard library location.
    # This generic path can be passed into the compiler via IYI_CONFIG_PATH
    # to produce a portable binary that resolves the standard library path
    # relative to the compiler location, independent of the absolute path.
    def self.expand_paths(paths, origin)
      paths.map! do |path|
        if (chopped = path.lchop?("$ORIGIN")) && chopped[0].in?(::Path::SEPARATORS)
          if origin.nil?
            raise "Missing executable path to expand $ORIGIN path"
          end
          File.join(origin, chopped)
        else
          path
        end
      end
    end

    # Resolved once and pinned: a language server outlives rebuilds of
    # its own binary, and on Linux a rebuilt (unlinked) executable makes
    # `Process.executable_path` return nil for the rest of the process —
    # which turned every later compile in a running session into
    # "Missing executable path to expand $ORIGIN path". Where the binary
    # started is where its library lives; that answer cannot change
    # mid-process, so it is computed exactly once.
    @@origin_resolved = false
    @@origin : String?

    def self.origin : String?
      unless @@origin_resolved
        if executable_path = Process.executable_path
          @@origin = File.dirname(executable_path)
        end
        @@origin_resolved = true
      end
      @@origin
    end

    def self.expand_paths(paths)
      expand_paths(paths, origin)
    end

    property entries : Array(String)

    # The directory a relative entry — `lib`, above all — is resolved against.
    #
    # Captured at construction, and settable because of the daemon: a
    # preanalysed prelude is built in the daemon's directory and adopted by a
    # build running somewhere else, and it carried this with it. `require
    # "kemal"` then looked for `lib/kemal` beside the daemon and reported "can't
    # find file", which is every shard-using project built from anywhere but the
    # daemon's own directory.
    property current_dir : String

    # What was searched, in order. A "can't find file" that does not name
    # the path it looked down is a question rather than an answer.
    getter entries : Array(String)

    def initialize(@entries : Array(String) = IyiPath.default_paths, codegen_target = Config.host_target)
      add_target_path(codegen_target)
      @current_dir = Dir.current
    end

    private def add_target_path(codegen_target)
      target = "#{codegen_target.architecture}-#{codegen_target.os_name}"

      @entries.each do |path|
        path = File.join(path, "lib_c", target)
        if Dir.exists?(path)
          @entries << path unless @entries.includes?(path)
          return
        end
      end
    end

    def find(filename, relative_to = nil) : Array(String)
      relative_to = File.dirname(relative_to) if relative_to.is_a?(String)

      if filename.starts_with? '.'
        result = find_in_path_relative_to_dir(filename, relative_to)
      else
        result = find_in_iyi_path(filename)
      end

      unless result
        raise NotFoundError.new(filename, relative_to)
      end

      result = [result] if result.is_a?(String)
      result
    end

    private def find_in_path_relative_to_dir(filename, relative_to)
      return unless relative_to.is_a?(String)

      # Check if it's a wildcard.
      if filename.ends_with?("/*") || (recursive = filename.ends_with?("/**"))
        filename_dir_index = filename.rindex!('/')
        filename_dir = filename[0..filename_dir_index]
        relative_dir = "#{relative_to}/#{filename_dir}"
        if File.exists?(relative_dir)
          files = [] of String
          gather_dir_files(relative_dir, files, recursive)
          return files
        end

        return nil
      end

      each_file_expansion(filename, relative_to) do |path|
        absolute_path = File.expand_path(path, dir: @current_dir)
        return absolute_path if File.file?(absolute_path)
      end

      nil
    end

    def each_file_expansion(filename, relative_to, &)
      relative_filename = "#{relative_to}/#{filename}"

      # iyi: a `require` may name an iyi file, and it wins over a `.cr` of the
      # same name — the precedence `import` already uses, for the same reason.
      # `--prelude` resolves through here, and 0.1.0's prelude is written in
      # iyi (SPEC.md, "0.1.0", item 3).
      unless relative_filename.ends_with?(".cr")
        yield relative_filename.ensure_suffix(".iyi")
      end

      # Check if .cr file exists.
      yield relative_filename.ensure_suffix(".cr")

      filename_is_relative = filename.starts_with?('.')

      shard_name, _, shard_path = filename.partition("/")
      shard_path = shard_path.presence

      if !filename_is_relative && shard_path
        shard_src = "#{relative_to}/#{shard_name}/src"
        shard_path_stem = shard_path.rchop(".cr")

        # If it's "foo/bar/baz", check if "foo/src/bar/baz.cr" exists (for a shard, non-namespaced structure)
        yield "#{shard_src}/#{shard_path_stem}.cr"

        # Then check if "foo/src/foo/bar/baz.cr" exists (for a shard, namespaced structure)
        yield "#{shard_src}/#{shard_name}/#{shard_path_stem}.cr"

        # If it's "foo/bar/baz", check if "foo/bar/baz/baz.cr" exists (std, nested)
        basename = File.basename(relative_filename, ".cr")
        yield "#{relative_filename}/#{basename}.cr"

        # If it's "foo/bar/baz", check if "foo/src/foo/bar/baz/baz.cr" exists (shard, non-namespaced, nested)
        yield "#{shard_src}/#{shard_path}/#{shard_path_stem}.cr"

        # If it's "foo/bar/baz", check if "foo/src/foo/bar/baz/baz.cr" exists (shard, namespaced, nested)
        yield "#{shard_src}/#{shard_name}/#{shard_path}/#{shard_path_stem}.cr"
      else
        basename = File.basename(relative_filename, ".cr")

        # If it's "foo", check if "foo/foo.cr" exists (for the std, nested)
        yield "#{relative_filename}/#{basename}.cr"

        unless filename_is_relative
          # If it's "foo", check if "foo/src/foo.cr" exists (for a shard)
          yield "#{relative_filename}/src/#{basename}.cr"
        end
      end
    end

    private def gather_dir_files(dir, files_accumulator, recursive)
      files = [] of String
      dirs = [] of String

      Dir.each_child(dir) do |filename|
        full_name = "#{dir}/#{filename}"

        if File.directory?(full_name)
          if recursive
            dirs << filename
          end
        else
          if filename.ends_with?(".cr")
            files << full_name
          end
        end
      end

      files.sort!
      dirs.sort!

      files.each do |file|
        files_accumulator << File.expand_path(file, dir: @current_dir)
      end

      dirs.each do |subdir|
        gather_dir_files("#{dir}/#{subdir}", files_accumulator, recursive)
      end
    end

    private def find_in_iyi_path(filename)
      @entries.each do |path|
        required = find_in_path_relative_to_dir(filename, path)
        return required if required
      end

      nil
    end
  end
end
