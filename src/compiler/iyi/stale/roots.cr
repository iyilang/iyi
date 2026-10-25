module Iyi::Stale
  record RootPath, root : String, path : String do
    def to_s(io : IO) : Nil
      io << root << ':' << path
    end
  end

  class Roots
    getter src : String
    getter toolchain : String
    getter pkg : String
    getter scratch : String
    getter abs : String

    # Roots are compared with real paths (the runtime records realpath), so
    # they are resolved the same way: `/tmp` is `/private/tmp` on darwin, and
    # an unresolved root mapped every recorded path to `abs`.
    def initialize(src : String, toolchain : String, pkg : String, scratch : String, abs : String = "/")
      @src = Roots.real(src)
      @toolchain = toolchain.empty? ? "" : Roots.real(toolchain)
      @pkg = pkg.empty? ? "" : Roots.real(pkg)
      @scratch = scratch.empty? ? "" : Roots.real(scratch)
      @abs = abs
    end

    # The real path when the directory exists, else the expanded path.
    def self.real(path : String) : String
      expanded = File.expand_path(path)
      File.exists?(expanded) ? (File.realpath(expanded) rescue expanded) : expanded
    end

    def self.default(program : Program, entry_filename : String? = nil, entry_code : String? = nil, cache_root : String? = nil) : Roots
      src = if entry_filename
              Compiler.entry_root_of(entry_filename, entry_code || "")
            else
              File.expand_path(".")
            end

      toolchain = ""
      IyiPath.default_paths.each do |entry|
        prelude = File.expand_path(File.join(entry, "iyi"))
        if File.file?(File.join(prelude, "prelude.iyi"))
          toolchain = File.expand_path(entry)
          break
        end
      end
      if toolchain.empty?
        toolchain = File.expand_path("src")
      end

      cache_dir = cache_root || (CacheDir.instance.dir rescue ".cache")
      pkg = File.expand_path(File.join(cache_dir, "mod"))

      scratch = ENV["TMPDIR"]? || ENV["TEMP"]? || ENV["TMP"]? || "/tmp"

      new(
        src: src,
        toolchain: toolchain,
        pkg: pkg,
        scratch: scratch,
        abs: "/"
      )
    end

    def self.default_for_file(entry_filename : String, entry_code : String? = nil, cache_root : String? = nil) : Roots
      src = Compiler.entry_root_of(entry_filename, entry_code || (File.read(entry_filename) rescue ""))
      toolchain = ""
      IyiPath.default_paths.each do |entry|
        prelude = File.expand_path(File.join(entry, "iyi"))
        if File.file?(File.join(prelude, "prelude.iyi"))
          toolchain = File.expand_path(entry)
          break
        end
      end
      if toolchain.empty?
        toolchain = File.expand_path("src")
      end
      cache_dir = cache_root || (CacheDir.instance.dir rescue ".cache")
      pkg = File.expand_path(File.join(cache_dir, "mod"))
      scratch = ENV["TMPDIR"]? || ENV["TEMP"]? || ENV["TMP"]? || "/tmp"

      new(
        src: src,
        toolchain: toolchain,
        pkg: pkg,
        scratch: scratch,
        abs: "/"
      )
    end

    def map(file_path : String) : RootPath
      candidate = if ::Path[file_path].absolute?
                    file_path
                  elsif File.exists?(File.join(@src, file_path))
                    File.join(@src, file_path)
                  else
                    File.expand_path(file_path)
                  end
      # Same resolution as the roots: a compiler location written through a
      # symlinked directory (/tmp on darwin) must land in its root, not `abs`.
      abs_path = Roots.real(candidate)

      if !@src.empty? && (rel = ::Path[abs_path].relative_to?(@src))
        rel_str = rel.to_s
        return RootPath.new("src", rel_str) unless rel_str.starts_with?("..")
      end

      if !@toolchain.empty? && (rel = ::Path[abs_path].relative_to?(@toolchain))
        rel_str = rel.to_s
        return RootPath.new("toolchain", rel_str) unless rel_str.starts_with?("..")
      end

      if !@pkg.empty? && (rel = ::Path[abs_path].relative_to?(@pkg))
        rel_str = rel.to_s
        return RootPath.new("pkg", rel_str) unless rel_str.starts_with?("..")
      end

      if !@scratch.empty? && (rel = ::Path[abs_path].relative_to?(@scratch))
        rel_str = rel.to_s
        return RootPath.new("scratch", rel_str) unless rel_str.starts_with?("..")
      end

      RootPath.new("abs", abs_path)
    end

    def resolve(root : String, path : String) : String
      case root
      when "src"       then File.join(@src, path)
      when "toolchain" then !@toolchain.empty? ? File.join(@toolchain, path) : path
      when "pkg"       then !@pkg.empty? ? File.join(@pkg, path) : path
      when "scratch"   then !@scratch.empty? ? File.join(@scratch, path) : path
      else                  path
      end
    end
  end
end
