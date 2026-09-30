require "path"

module Iyi
  def self.relative_filename(filename)
    return filename unless filename.is_a?(String)

    if base_file = filename.lchop? Dir.current
      ::Path::SEPARATORS.each do |sep|
        if file_prefix = base_file.lchop? sep
          return file_prefix
        end
      end
      # iyi: the directory is a prefix of the string without being a prefix of
      # the path. Working in `/tmp/x/crystal` with a cache in
      # `/tmp/x/crystal-cache`, chopping gives `-cache/…`: a relative path to
      # nowhere. The compiler then tries to write an object file there and
      # reports "No such file or directory", which is how this was found —
      # after being blamed on parallel codegen, on the cache cleaner and on a
      # debug build in turn. Only a separator makes a prefix a directory.
      return filename
    end
    filename
  end

  # iyi: whether *name* names a variable this compiler wrote rather than one
  # somebody typed.
  #
  # Three spellings, because two compilers wrote them. Crystal's internal
  # variables are `#`-prefixed — a name no source can produce — or
  # `__temp_`; iyi's definition typing writes `__iyi_dt_*`, the
  # `uninitialized` receiver, arguments and return value it puts in an `if
  # false` to check a def against its own declaration. Those probes live in
  # the scope the file's top level lives in, which is where every surface
  # that answers "what is in scope here" reads from: `iyi tool types` on
  # `samples/iyi/calc.iyi` answered with twenty-three of them and one
  # variable the author wrote, `tool context` printed them in its table,
  # and the language server offered `__iyi_dt_1_r` and `__iyi_dt_1_v` to an
  # editor as the first two completions in the list, kind "Variable" on
  # each.
  #
  # One predicate rather than a prefix test at each surface, because the
  # two that existed — `'#'` in the types visitor, `__temp_` in the context
  # visitor — were each written for the other language's names and neither
  # knew this one's.
  def self.compiler_variable?(name : String) : Bool
    name.starts_with?("__iyi_") || name.starts_with?("__temp_") ||
      name.starts_with?('#')
  end

  # iyi: the diagnostic inside the wrappers around it.
  #
  # An error raised while an import is read arrives wrapped in `while
  # importing "X"` (`SemanticVisitor#import_file`), and the first line of
  # *that* names the file the author already typed and nothing they can
  # act on. `iyi doc` unwrapped it and `iyi mod context` did not, so the
  # grounding answer for a module with a bad line in it was `(does not
  # compile alone: while importing "kit/all")` where `iyi check` said
  # ``can't apply `pub` to const``, with the line and the column.
  #
  # `inner` before `cause`, because a `TypeException` carries what it
  # wrapped in `inner`.
  def self.deepest_error(error : Exception) : Exception
    deepest = error
    loop do
      nested = deepest.responds_to?(:inner) ? deepest.inner : nil
      nested ||= deepest.cause
      break unless nested.is_a?(Iyi::Error | Iyi::CodeError)
      deepest = nested
    end
    deepest
  end

  # iyi: *path* written with the separators this platform uses.
  #
  # A module path is posix by grammar (R-1) and `File.join` translates nothing
  # inside a part it is handed, so `mods` and `m1/a` came out as
  # `mods\m1/a.iyimod` — half native, half not, in a sentence naming a file the
  # reader has to go and open. `Dir.glob` needs none of this: it splits its
  # pattern on `/` and rejoins with `File.join`, so a posix pattern still
  # answers in the platform's own separators.
  #
  # Swapped rather than normalised: `Path#normalize` also collapses `./` and
  # `//`, which would change what a POSIX build prints, and `Path#to_native`
  # translates no separators at all — it only relabels the kind.
  # iyi: *dir* as the literal start of a glob pattern: posix, since a
  # backslash is an escape in a pattern and not a separator, and with the
  # pattern's own characters escaped, since a directory's name is a name.
  # `proj [v2]` and `x{a,b}` were read as a character class and a brace,
  # matched nothing, and `iyi test` found no tests there while `iyi fmt
  # --check` passed having checked nothing.
  def self.glob_root(dir : String | ::Path) : ::Path
    posix = ::Path[dir].to_posix.to_s
    escaped = String.build do |io|
      posix.each_char do |char|
        io << '\\' if char.in?('*', '?', '[', ']', '{', '}')
        io << char
      end
    end
    ::Path.posix(escaped)
  end

  def self.native_path(path : String) : String
    {% if flag?(:win32) %}
      return path.tr("/", "\\") if path.includes?('/')
    {% end %}
    path
  end

  # iyi: *path* as it reads from under *base*, or nil when it is not under it.
  #
  # Both sides are filesystem paths, so the question is `Path`'s and not a
  # string's. `path.lchop(base + "/")` is the same sentence on posix and
  # answers nothing on Windows: `File.expand_path` and `Dir.current` both
  # spell a path with `\` there, the prefix never matched, and every verb that
  # chops a root off a path to print it short printed the absolute path
  # instead — `migrate` said `C:\...\out\app.iyi` where it meant `app.iyi`,
  # and copied an asset under a name still carrying its leading separator.
  #
  # A path that is not under *base* answers nil rather than a `../..` climb,
  # because the callers print what they get: the short name when there is one
  # and the full path when there is not.
  def self.path_under?(path : String, base : String) : String?
    return nil unless relative = ::Path[path].relative_to?(base)
    first = relative.parts.first?
    return nil if first.nil? || first == ".."
    relative.to_s
  end

  # iyi: *path* spelled the way the platform's file system compares names:
  # as it is on Linux, and on Windows with one separator and one case,
  # because NTFS does not tell `C:\App\Util.iyi` from `c:/app/util.iyi`.
  # For a path that may not exist yet, or a set of them, where
  # `same_file?` cannot ask. Every comparison that did not do this
  # answered differently for a drive letter an editor lowercased.
  def self.path_key(path : String) : String
    {% if flag?(:win32) %}
      path.tr("/", "\\").downcase
    {% else %}
      path
    {% end %}
  end

  # iyi: whether a file can be made in *directory*. `File.writable?` of a
  # directory answers from its attributes, and on Windows the permission
  # is an ACL they do not carry: a directory that refused this user every
  # new file answered yes, and `-o` there came back as the linker's
  # LNK1104 after a whole compilation. So Windows is asked by making a
  # file, which is the question.
  # iyi: on Windows, *path* made free for a new file: false only when it is
  # there, cannot be opened for writing - a running program, a read-only
  # file - and cannot be renamed either. Moved to `*.old`, or `*.old-<pid>`
  # when an earlier one is still running and cannot be deleted.
  def self.move_aside_if_busy(path : String) : Bool
    return true unless File.file?(path)
    begin
      File.open(path, "r+") { }
      return true
    rescue File::Error
    end
    aside = "#{path}.old"
    begin
      File.delete(aside) if File.exists?(aside)
    rescue File::Error
      aside = "#{path}.old-#{Process.pid}"
    end
    File.rename(path, aside)
    true
  rescue File::Error
    false
  end

  def self.writable_directory?(directory : String) : Bool
    {% if flag?(:win32) %}
      probe = File.join(directory, ".iyi-write-probe-#{Process.pid}")
      begin
        File.write(probe, "")
      rescue File::Error
        return false
      end
      File.delete?(probe)
      true
    {% else %}
      File.writable?(directory)
    {% end %}
  end

  # iyi: `path_key` of the file's real path, when there is a file: Windows
  # has one more spelling a string cannot fold, the 8.3 short name - a CI
  # runner's temporary directory is `C:\Users\RUNNER~1\...` to `mktemp`
  # and `C:\Users\runneradmin\...` to `Dir.current` - and only the file
  # system knows the two are one. A path that is not there keeps its own.
  def self.file_key(path : String) : String
    return path_key(path) unless File.exists?(path)
    real = File.realpath(path)
    {% if flag?(:win32) %}
      # `realpath` there is `GetFullPathNameW`, which keeps a short name
      # as it is; `GetLongPathNameW` spells every component out.
      wide = Crystal::System.to_wstr(real)
      buffer = Slice(UInt16).new(260)
      length = LibC.GetLongPathNameW(wide, buffer, buffer.size)
      if length >= buffer.size
        buffer = Slice(UInt16).new(length)
        length = LibC.GetLongPathNameW(wide, buffer, buffer.size)
      end
      real = String.from_utf16(buffer[0, length]) if 0 < length < buffer.size
    {% end %}
    path_key(real)
  rescue File::Error
    path_key(path)
  end

  # iyi: whether *a* and *b* name one file - asked of the file system,
  # which is the only thing that knows. A string compare of the expanded
  # paths is the same answer on Linux and wrong on Windows, where NTFS
  # ignores case and Win32 drops a trailing space or dot: `-o PROG.iyi
  # prog.iyi`, `-o c:\...\main.iyi` and `-o "prog.iyi "` each linked the
  # program over its only source, exit 0. Two paths that do not both
  # exist are the same file only if they are the same string.
  def self.same_file?(a : String, b : String) : Bool
    return true if File.expand_path(a) == File.expand_path(b)
    File.exists?(a) && File.exists?(b) && File.same?(a, b, follow_symlinks: true)
  rescue File::Error
    false
  end

  def self.print_error(msg, color, stderr = STDERR, leading_error = true)
    stderr.print "Error: ".colorize.toggle(color).red.bold if leading_error
    stderr.puts msg.colorize.toggle(color).bright
  end

  def self.tempfile(basename)
    CacheDir.instance.join("#{Iyi::Command.program_name}-run-#{basename}.tmp")
  end

  # iyi: the temporary programs runners left behind: a runner removes its
  # own when the program ends, and one ended from outside - `taskkill /F`,
  # an editor's stop button, which is `TerminateProcess` and runs nothing -
  # leaves its program and its `.pdb` in the cache. Named one per runner
  # (below), they would pile up; so each run takes away what an hour-old
  # runner left. An hour, because a younger file may be a program another
  # runner has just linked and not yet started; on Windows a running one
  # refuses the delete anyway.
  def self.sweep_run_leftovers : Nil
    dir = CacheDir.instance.dir
    prefix = "#{Iyi::Command.program_name}-run-"
    cutoff = Time.utc - 1.hour
    Dir.each_child(dir) do |name|
      next unless name.starts_with?(prefix) && name.includes?(".tmp")
      path = File.join(dir, name)
      next unless (info = File.info?(path)) && info.modification_time < cutoff
      File.delete?(path) rescue nil
    end
  rescue File::Error
  end

  # iyi: one per runner, by its process id. It was one per basename, and
  # Windows will not write over an executable that is running: two `iyi
  # run main.iyi` at once - two different programs in two directories,
  # or one twice - and the second failed to link, `LNK1104: cannot open
  # file ...\iyi-run-main.exe.tmp.exe`.
  def self.temp_executable(basename)
    name = tempfile("#{basename}-#{Process.pid}")
    {% if flag?(:win32) %}
      name += ".exe"
    {% end %}
    name
  end

  def self.with_line_numbers(
    source : String | Array(String),
    highlight_line_number = nil,
    color = false,
    line_number_start = 1,
  )
    source = source.lines if source.is_a? String
    line_number_padding = (source.size + line_number_start).to_s.size
    source.map_with_index do |line, i|
      line = line.to_s.chomp
      line_number = (i + line_number_start).to_s.rjust(line_number_padding)
      target = i + line_number_start == highlight_line_number
      if target
        if color
          " > #{line_number} | ".colorize.green.to_s + line.colorize.bold.to_s
        else
          " > #{line_number} | " + line
        end
      else
        if color
          " > #{line_number} | ".colorize.dim.to_s + line
        else
          "   #{line_number} | " + line
        end
      end
    end.join '\n'
  end

  def self.normalize_path(path)
    path = ::Path[path].normalize
    path = ::Path["."] / path unless path.anchor
    path.to_s
  end
end
