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
  def self.native_path(path : String) : String
    {% if flag?(:win32) %}
      return path.tr("/", "\\") if path.includes?('/')
    {% end %}
    path
  end

  def self.print_error(msg, color, stderr = STDERR, leading_error = true)
    stderr.print "Error: ".colorize.toggle(color).red.bold if leading_error
    stderr.puts msg.colorize.toggle(color).bright
  end

  def self.tempfile(basename)
    CacheDir.instance.join("#{Iyi::Command.program_name}-run-#{basename}.tmp")
  end

  def self.temp_executable(basename)
    name = tempfile(basename)
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
