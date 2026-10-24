require "json"
require "crystal/digest/md5"

module Iyi
  # iyi: the up-to-date check. When nothing an output was built from has
  # changed since it was built, `iyi build` says so and compiles nothing, as
  # `go build` does (SPEC.md V.9 (e)).
  #
  # A build that finishes writes down what it was built from — `BuildInputs`
  # — beside its objects in the compiler cache, one file per output. The next
  # build of that output with the same command line reads it back before
  # anything is parsed, and looks again at every file, listing, environment
  # value and `pkg-config` answer in it, at the output itself, and at the
  # compiler. All the same: up to date. Anything not: the build runs, and its
  # own record replaces this one.
  #
  # A record is deleted before a build starts and written only when one has
  # finished, so a build that fails or is interrupted leaves nothing that
  # could vouch for an output it did not finish.
  class UpToDate
    FORMAT = 1

    # The switches that change what a build prints and not what it builds,
    # left out of the comparison so that asking `-s` for the phases of a
    # rebuild does not make it one.
    DISPLAY_ONLY = %w(-s --stats -p --progress -t --time --verbose --no-color --error-trace --force)

    getter path : String
    getter output : String
    getter checked = 0
    @arguments : Array(String)
    @cwd : String
    @extra_outputs : Array(String)

    def initialize(@output : String, sources : Array(Compiler::Source), arguments : Array(String), @extra_outputs : Array(String))
      @output = File.expand_path(@output)
      @arguments = arguments.reject(&.in?(DISPLAY_ONLY))
      @cwd = Dir.current
      dir = CacheDir.instance.directory_for(sources)
      @path = File.join(dir, "up-to-date-#{::Crystal::Digest::MD5.hexdigest(@output)}.json")
    end

    # What the compiler is, so that a rebuilt compiler, an upgrade, or the
    # daemon's binary in place of this one does not reuse an output another
    # compiler wrote. The binary's own size and time, since two builds of one
    # commit are two compilers as far as their output is concerned.
    def self.compiler_identity : String
      String.build do |io|
        io << Config.iyi_version << '|' << Config.description
        if exe = Process.executable_path
          stamp = BuildInputs.stamp(exe)
          io << '|' << exe << '|' << stamp.size << '|' << stamp.mtime
        end
      end
    end

    # Nil when the output is current; otherwise the first thing found that
    # says it is not, as a sentence for `-s` and `--verbose`.
    def stale_reason : String?
      BuildInputs.paused { compare }
    rescue ex : KeyError | TypeCastError | IndexError | JSON::Error
      # A record in the cache that is not the shape this writes is a cache to
      # rebuild, whatever made it so.
      "the record of what it was built from could not be read (#{ex.message})"
    end

    private def compare : String?
      text = File.read(@path) rescue nil
      return "this output has no record of what it was built from" unless text
      record = JSON.parse(text) rescue nil
      return "the record of what it was built from could not be read" unless record
      return "the record was written by another version of this check" unless record["format"]?.try(&.as_i?) == FORMAT
      return "the compiler is not the one that built it" unless record["compiler"]?.try(&.as_s?) == UpToDate.compiler_identity
      return "the working directory is not the one it was built in" unless record["cwd"]?.try(&.as_s?) == @cwd
      was = record["arguments"]?.try(&.as_a?.try(&.map(&.as_s)))
      unless was == @arguments
        return "the command line is `#{Process.quote(@arguments)}`, and was `#{was.try { |list| Process.quote(list) }}`"
      end

      record["env"].as_h.each do |name, value|
        @checked += 1
        now = Crystal::System::Env.get(name)
        unless now == value.as_s?
          return "#{name} is #{now ? now.inspect : "unset"}, and was #{value.as_s?.try(&.inspect) || "unset"}"
        end
      end

      record["files"].as_a.each do |entry|
        @checked += 1
        fields = entry.as_a
        path = fields[0].as_s
        was = BuildInputs::Stamp.new(BuildInputs::Kind.new(fields[1].as_i.to_u8), fields[2].as_i64, fields[3].as_i64, fields[4].as_s?)
        if reason = changed(path, was)
          return reason
        end
      end

      record["listings"].as_h.each do |dir, names|
        @checked += 1
        now = BuildInputs.children(dir)
        was = names.as_a?.try(&.map(&.as_s))
        return "the entries of #{Iyi.relative_filename(dir)} changed" unless now == was
      end

      record["pkg_config"].as_a.each do |entry|
        @checked += 1
        fields = entry.as_a
        mod, static = fields[0].as_s, fields[1].as_bool
        now = Program.pkg_config_query(mod, static)
        return "pkg-config answers differently for #{mod}" unless now == fields[2].as_s?
      end
      nil
    end

    private def changed(path : String, was : BuildInputs::Stamp) : String?
      now = BuildInputs.stamp(path)
      name = Iyi.relative_filename(path)
      if now.kind != was.kind
        return "#{name} is gone" if now.kind.absent?
        return "#{name} is new" if was.kind.absent?
        return "#{name} is not what it was"
      end
      return nil unless now.kind.file?
      return "#{name} changed" unless now.size == was.size && now.mtime == was.mtime
      if digest = was.digest
        content = File.read(path) rescue nil
        return "#{name} changed" unless content && ::Crystal::Digest::MD5.hexdigest(content) == digest
      end
      nil
    end

    # Forgets the record, before a build that may not finish.
    def forget : Nil
      File.delete?(@path) rescue nil
    end

    # Writes the record of a build that has finished, or says why there is
    # none: nil when written, otherwise the reasons.
    def record(inputs : BuildInputs) : Array(String)?
      return inputs.reasons unless inputs.reasons.empty?
      unless File.file?(@output)
        return ["the build wrote no #{Iyi.relative_filename(@output)}"]
      end

      outputs = inputs.written.to_a
      outputs << inputs.key(@output)
      @extra_outputs.each { |extra| outputs << inputs.key(extra) if File.exists?(extra) }

      json = JSON.build do |builder|
        builder.object do
          builder.field "format", FORMAT
          builder.field "compiler", UpToDate.compiler_identity
          builder.field "cwd", @cwd
          builder.field "arguments", @arguments
          builder.field "env" do
            builder.object do
              inputs.env.to_a.sort_by!(&.[0]).each { |name, value| builder.field name, value }
            end
          end
          builder.field "files" do
            builder.array do
              inputs.files.each do |path, stamp|
                next if outputs.includes?(path)
                stamp_json(builder, path, stamp)
              end
              # What the build wrote, as it is now that the build is done.
              outputs.uniq.each { |path| stamp_json(builder, path, BuildInputs.stamp(path)) }
            end
          end
          builder.field "listings" do
            builder.object do
              inputs.listings.each { |dir, names| builder.field dir, names }
            end
          end
          builder.field "pkg_config" do
            builder.array do
              inputs.pkg_config.each do |mod, static, flags|
                builder.array do
                  builder.string mod
                  builder.bool static
                  flags ? builder.string(flags) : builder.null
                end
              end
            end
          end
        end
      end

      staging = "#{@path}.#{Process.pid}"
      File.write(staging, json)
      File.rename(staging, @path)
      nil
    end

    private def stamp_json(builder : JSON::Builder, path : String, stamp : BuildInputs::Stamp) : Nil
      builder.array do
        builder.string path
        builder.number stamp.kind.value
        builder.number stamp.size
        builder.number stamp.mtime
        (digest = stamp.digest) ? builder.string(digest) : builder.null
      end
    end
  end
end
