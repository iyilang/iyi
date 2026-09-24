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
# `#` comments a line out. Versions are `vMAJOR.MINOR.PATCH` — the `v` is
# part of the spelling because it is part of the git tag the fetcher asks
# for, and a spelling that round-trips beats one that is reassembled.
require "semantic_version"

module Iyi::Mod
  # One `require` line: the path that identifies a module and the minimum
  # version this manifest is known to work with.
  record Requirement, path : String, version : SemanticVersion do
    def to_s(io : IO) : Nil
      io << "require " << path << " v" << version
    end
  end

  class ModFile
    getter path : String
    getter requirements : Array(Requirement)

    def initialize(@path : String, @requirements : Array(Requirement))
    end

    # Parses manifest text. *source* names the file in errors, because a
    # manifest three dependencies deep is not the one the person is editing.
    def self.parse(text : String, source : String) : ModFile
      module_path = nil
      requirements = [] of Requirement

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
          unless fields.size == 3
            raise ModError.new("#{source}:#{line_number}: `require` takes a path and a version, as `require <path> v1.2.3`")
          end
          path = check_path(fields[1], source, line_number)
          requirements << Requirement.new(path, check_version(fields[2], source, line_number))
        else
          raise ModError.new("#{source}:#{line_number}: `#{fields.first}` is not a directive; `module` and `require` are the two")
        end
      end

      unless module_path
        raise ModError.new("#{source}: no `module` line; a manifest starts by saying whose it is")
      end

      new(module_path, requirements)
    end

    # Checks *path* by the manifest's own grammar, for a path that arrives
    # on a command line rather than in a file; the sentence is the one a
    # hand-written `require` line would draw.
    def self.check_module_path(path : String) : String
      check_path(path, "", 0)
    rescue ex : ModError
      raise ModError.new(ex.message.to_s.lchop(":0: "))
    end

    # Checks a version as it is spelled on a command line, `v1.2.3`.
    def self.check_module_version(spelling : String) : SemanticVersion
      check_version(spelling, "", 0)
    rescue ex : ModError
      raise ModError.new(ex.message.to_s.lchop(":0: "))
    end

    # *text* with *path* required at *version*: its own `require` line
    # rewritten in place when it has one, or a new line after the last
    # `require` - after everything when there is none. Everything else the
    # person wrote, comments and order and blank lines, stays as it was:
    # the manifest is theirs, and a tool that rewrote it whole would turn
    # every `get` into a diff of the file.
    def self.with_requirement(text : String, path : String, version : SemanticVersion) : String
      newline = text.includes?("\r\n") ? "\r\n" : "\n"
      line = "require #{path} v#{version}"
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
        lines[index] = indent + line
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
