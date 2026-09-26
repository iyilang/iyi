# iyi: `iyi.mod` — the manifest III.7 step 1 names. Policy, written by a
# person: the module's own identity and the *minimums* it asks for. Fact —
# what actually arrived — is `iyi.sum`'s job and step 2's.
#
# The shape is Go's, because the design is (SPEC.md III.7): line-oriented,
# two directives, nothing clever enough to have a bad day.
#
#     module github.com/user/app
#
#     require github.com/user/lib v1.2.0
#     require github.com/other/dep v0.3.1
#
#     replace github.com/user/lib => ../lib
#
#     require github.com/sdogruyol/iyi-web v0.1.0 as web
#
# `as web` gives a requirement a short name for this project's own files:
# `import web/dsl` and `import web/dsl::*` mean the module at
# `github.com/sdogruyol/iyi-web/dsl`. The path is identity and stays here,
# written once; the files write the name. A package's own short names
# are its files', read from its own manifest, and never its consumer's.
#
# `replace` builds a required module from a directory on this machine
# instead of its tag: the module being written beside the one that uses
# it, or a fork checked out to try. It is the program's own decision, so
# only the manifest beside the entry file is obeyed; one in a dependency's
# manifest is read and ignored, as Go does, or a library could redirect
# its consumers' builds. The target is spelled as a directory - `./`,
# `../` or absolute - so it can never be mistaken for a module path.
#
# `#` comments a line out. Versions are `vMAJOR.MINOR.PATCH` — the `v` is
# part of the spelling because it is part of the git tag the fetcher asks
# for, and a spelling that round-trips beats one that is reassembled.
require "semantic_version"

module Iyi::Mod
  # One `require` line: the path that identifies a module and the minimum
  # version this manifest is known to work with.
  # `reaches`, when written, is what the package may touch outside the
  # language (`Mod::Reach`): std modules by path, `File`, and `C` for C it
  # declares itself; empty is `reaches nothing`. Nil is no limit.
  record Requirement, path : String, version : SemanticVersion, short_name : String? = nil,
    reaches : Array(String)? = nil do
    def to_s(io : IO) : Nil
      io << "require " << path << " v" << version
      io << " as " << short_name if short_name
      if limit = reaches
        io << " reaches " << (limit.empty? ? "nothing" : limit.join(", "))
      end
    end
  end

  class ModFile
    getter path : String
    getter requirements : Array(Requirement)
    # Module path to the directory it builds from, as written.
    getter replacements : Hash(String, String)

    def initialize(@path : String, @requirements : Array(Requirement),
                   @replacements = {} of String => String)
    end

    # Parses manifest text. *source* names the file in errors, because a
    # manifest three dependencies deep is not the one the person is editing.
    def self.parse(text : String, source : String) : ModFile
      module_path = nil
      requirements = [] of Requirement
      replacements = {} of String => String

      text.each_line.with_index(1) do |raw, line_number|
        line = raw.strip
        next if line.empty? || line.starts_with?('#')
        fields = line.split

        case fields.first
        when "module"
          unless fields.size == 2
            raise ModError.new("#{source}:#{line_number}: `module` takes exactly one path")
          end
          if module_path
            raise ModError.new("#{source}:#{line_number}: a manifest declares one module, and this one already did")
          end
          module_path = check_path(fields[1], source, line_number)
        when "require"
          usage = "`require` takes a path and a version, as `require <path> v1.2.3`, a short name after `as` " \
                  "if it wants one, and what the package may reach after `reaches` - `reaches std/file, C`"
          raise ModError.new("#{source}:#{line_number}: #{usage}") if fields.size < 3
          rest = fields[3..]
          short_word = nil
          if rest.first? == "as"
            raise ModError.new("#{source}:#{line_number}: #{usage}") if rest.size < 2
            short_word = rest[1]
            rest = rest[2..]
          end
          reaches = nil
          if rest.first? == "reaches"
            reaches = check_reaches(rest[1..], source, line_number)
            rest = [] of String
          end
          raise ModError.new("#{source}:#{line_number}: #{usage}") unless rest.empty?
          path = check_path(fields[1], source, line_number)
          version = check_version(fields[2], source, line_number)
          short_name = nil
          if short_word
            short_name = check_short_name(short_word, source, line_number)
            if taken = requirements.find { |other| other.short_name == short_name }
              raise ModError.new("#{source}:#{line_number}: `#{short_name}` already names #{taken.path}; a short name is one module's")
            end
          end
          begin
            ModFile.check_major(path, version)
          rescue ex : ModError
            raise ModError.new("#{source}:#{line_number}: #{ex.message}")
          end
          requirements << Requirement.new(path, version, short_name, reaches)
        when "replace"
          unless fields.size == 4 && fields[2] == "=>"
            raise ModError.new("#{source}:#{line_number}: `replace` takes a path and a directory, as `replace <path> => ../dir`")
          end
          path = check_path(fields[1], source, line_number)
          if replacements.has_key?(path)
            raise ModError.new("#{source}:#{line_number}: #{path} is already replaced; one directory builds it")
          end
          replacements[path] = check_directory(fields[3], source, line_number)
        else
          raise ModError.new("#{source}:#{line_number}: `#{fields.first}` is not a directive; `module`, `require` and `replace` are the three")
        end
      end

      unless module_path
        raise ModError.new("#{source}: no `module` line; a manifest starts by saying whose it is")
      end

      new(module_path, requirements, replacements)
    end

    # Checks *path* by the manifest's own grammar, for a path that arrives
    # on a command line rather than in a file; the sentence is the one a
    # hand-written `require` line would draw.
    def self.check_module_path(path : String) : String
      check_path(path, "", 0)
    rescue ex : ModError
      raise ModError.new(ex.message.to_s.lchop(":0: "))
    end

    # Checks a short name as it is given on a command line, `--as web`.
    def self.check_module_short_name(name : String) : String
      check_short_name(name, "", 0)
    rescue ex : ModError
      raise ModError.new(ex.message.to_s.lchop(":0: "))
    end

    # Checks a version as it is spelled on a command line, `v1.2.3`.
    def self.check_module_version(spelling : String) : SemanticVersion
      check_version(spelling, "", 0)
    rescue ex : ModError
      raise ModError.new(ex.message.to_s.lchop(":0: "))
    end

    # The repository a module path lives in, and the major version the
    # path names: `example.com/lib/v2` is `{"example.com/lib", 2}`, and a
    # path without a `vN` last segment names none. Go's rule, and SPEC.md
    # III.7's: a major version past 1 is a different module, spelled by a
    # suffix, in the same repository, so v1 and v2 can both be required.
    # The name a package's modules live under: its path's last segment, a
    # `/vN` suffix left off and `-` written `_` - `github.com/sdogruyol/
    # iyi-web` is `iyi_web`, `example.com/lib/v2` is `lib`. Nil when that
    # is not a module name, which a segment like `lib.x` is not.
    def self.package_name(path : String) : String?
      name = split_major(path)[0].rpartition('/')[2].gsub('-', '_')
      return nil unless name.size > 0 && name[0].ascii_lowercase?
      return nil unless name.each_char.all? { |c| c.ascii_lowercase? || c.ascii_number? || c == '_' }
      return nil if name.includes?("__") || name.ends_with?('_')
      name
    end

    def self.split_major(path : String) : {String, Int32?}
      repository, slash, last = path.rpartition('/')
      return {path, nil} if slash.empty? || last.size < 2 || last[0] != 'v'
      digits = last[1..]
      return {path, nil} unless digits.each_char.all?(&.ascii_number?) && digits[0] != '0'
      major = digits.to_i?
      return {path, nil} unless major && major >= 2
      {repository, major}
    end

    # Whether *version* can be *path*'s: the major the suffix names, or 0
    # and 1 for a path with no suffix. Refused with the path that version
    # belongs to, which is the line the person meant to write.
    def self.check_major(path : String, version : SemanticVersion) : Nil
      repository, major = split_major(path)
      if major
        return if version.major == major
        raise ModError.new("#{path} is major version #{major}, and v#{version} is not; " \
                           "v#{version} is #{version.major <= 1 ? repository : "#{repository}/v#{version.major}"}'s")
      end
      return if version.major <= 1
      raise ModError.new("v#{version} of #{path} is #{path}/v#{version.major}: " \
                         "a major version past 1 is its own module path, and v0 and v1 are this one's")
    end

    # *text* with *path* required at *version*: its own `require` line
    # rewritten in place when it has one, or a new line after the last
    # `require` - after everything when there is none. Everything else the
    # person wrote, comments and order and blank lines, stays as it was:
    # the manifest is theirs, and a tool that rewrote it whole would turn
    # every `get` into a diff of the file.
    def self.with_requirement(text : String, path : String, version : SemanticVersion, short_name : String? = nil) : String
      newline = text.includes?("\r\n") ? "\r\n" : "\n"
      line = "require #{path} v#{version}"
      line += " as #{short_name}" if short_name
      lines = text.split(newline)
      # A trailing newline leaves an empty last element; it is put back.
      ended = !lines.empty? && lines.last.empty?
      lines.pop if ended
      last_require = nil
      lines.each_with_index do |raw, index|
        fields = raw.strip.split
        next unless fields.first? == "require"
        last_require = index
        next unless fields[1]? == path
        indent = raw[0, raw.size - raw.lstrip.size]
        # A short name already on the line stays, unless another was given,
        # and so does a `reaches` limit: a `get` moves the version only.
        kept = !short_name && fields[3]? == "as" && (name = fields[4]?) ? " as #{name}" : ""
        if at = fields.index("reaches")
          kept += " " + fields[at..].join(' ')
        end
        lines[index] = indent + line + kept
        return lines.join(newline) + (ended ? newline : "")
      end
      if at = last_require
        lines.insert(at + 1, line)
      else
        lines << "" unless lines.empty? || lines.last.strip.empty?
        lines << line
      end
      lines.join(newline) + newline
    end

    # *text* without *path*'s `require` line; every other line as it was.
    def self.without_requirement(text : String, path : String) : String
      newline = text.includes?("\r\n") ? "\r\n" : "\n"
      lines = text.split(newline)
      lines.reject! do |raw|
        fields = raw.strip.split
        fields.first? == "require" && fields[1]? == path
      end
      lines.join(newline)
    end

    # A module path is a URL's path half (III.7): host-shaped segments may
    # carry `.` and `-`, every segment is lower-case, and nothing here maps
    # to a type name — the in-package path does that, under IV.6 #6's own
    # grammar, checked where files load.
    private def self.check_path(path : String, source : String, line_number : Int32) : String
      ok = !path.empty? && !path.starts_with?('/') && !path.ends_with?('/') && !path.includes?("//") &&
           path.each_char.all? { |c| c.ascii_lowercase? || c.ascii_number? || c.in?('/', '.', '-', '_') } &&
           !path.split('/').any? { |s| s.empty? || s.starts_with?('.') || s.ends_with?('.') || s.includes?("..") }
      unless ok
        raise ModError.new("#{source}:#{line_number}: '#{path}' is not a module path; a path is lower-case segments joined by `/`, with `.` and `-` allowed inside a segment")
      end
      path
    end

    # What a `reaches` clause names: `std/...` modules, `File` and `C`, split
    # on commas and spaces alike, or `nothing` alone for a package that
    # touches nothing outside the language.
    def self.check_reaches(words : Array(String), source : String, line_number : Int32) : Array(String)
      items = words.join(' ').split(',').flat_map(&.split).reject(&.empty?)
      if items.empty?
        raise ModError.new("#{source}:#{line_number}: `reaches` names what the package may touch - `std/socket`, `File`, `C` - or `nothing`")
      end
      return [] of String if items == ["nothing"]
      items.each do |item|
        next if item == "File" || item == "C"
        if item.starts_with?("std/")
          check_path(item, source, line_number)
          next
        end
        raise ModError.new("#{source}:#{line_number}: `#{item}` is not something a package reaches; " \
                           "`reaches` takes std modules (`std/socket`), `File`, `C`, or `nothing` alone")
      end
      items.uniq
    end

    # A short name: one lower-case segment, as a module path's first segment
    # is spelled, and never `std`, which is iyi's own library in every file.
    def self.check_short_name(name : String, source : String, line_number : Int32) : String
      ok = !name.empty? && name[0].ascii_lowercase? &&
           name.each_char.all? { |c| c.ascii_lowercase? || c.ascii_number? || c == '_' }
      unless ok
        raise ModError.new("#{source}:#{line_number}: '#{name}' is not a short name; one is a single lower-case word, as `web` or `json_x`")
      end
      if name == "std"
        raise ModError.new("#{source}:#{line_number}: `std` is iyi's standard library in every file, and cannot name a requirement")
      end
      name
    end

    # A replacement's target: a directory, spelled so it cannot be read as
    # a module path - `./x`, `../x`, `/abs`, or on Windows `C:\x` and `C:/x`.
    private def self.check_directory(target : String, source : String, line_number : Int32) : String
      drive = target.size >= 3 && target[0].ascii_letter? && target[1] == ':' && target[2].in?('/', '\\')
      unless target.starts_with?("./") || target.starts_with?("../") || target.starts_with?('/') ||
             target == "." || target == ".." || drive
        raise ModError.new("#{source}:#{line_number}: '#{target}' is not a directory; a replacement is spelled `./dir`, `../dir` or an absolute path, so it is never a module path")
      end
      target
    end

    private def self.check_version(spelling : String, source : String, line_number : Int32) : SemanticVersion
      unless spelling.starts_with?('v')
        raise ModError.new("#{source}:#{line_number}: '#{spelling}' does not start with `v`; a version is spelled the way its git tag is, `v1.2.3`")
      end
      SemanticVersion.parse(spelling.lchop('v'))
    rescue ex : ArgumentError
      raise ModError.new("#{source}:#{line_number}: #{ex.message}")
    end
  end

  class ModError < ::Exception
  end
end
