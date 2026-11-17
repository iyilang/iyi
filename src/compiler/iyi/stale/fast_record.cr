require "json"
require "sync/mutex"
require "../compiler"
require "./inputs_file"
require "./profile"
require "./receipt"
require "./store"
require "./toolchain"

module Iyi::Stale
  # One path a record stamped, with the stamp it had.
  record FastEntry, path : String, stamp : BuildInputs::Stamp

  # One `pkg-config` answer a record took: the module, whether static linking
  # was asked for, and the flags it gave (nil for none).
  record FastPkgConfig, mod : String, static : Bool, flags : String?

  # What one run reads once, and every record is compared with: the working
  # directory, the host, the compiler's own files, the environment a build
  # child starts with, and `pkg-config` answers, each asked at most once.
  class FastFacts
    getter cwd : String
    getter target : String
    getter workers : Int32
    getter compiler : Array(FastEntry)
    getter env : Hash(String, String)
    getter refusal : String?

    def initialize(@cwd : String, @target : String, @workers : Int32,
                   @compiler : Array(FastEntry), @env : Hash(String, String), @refusal : String? = nil)
      @pkg_config = {} of {String, Bool} => String?
      @pkg_config_lock = Sync::Mutex.new
    end

    # The facts of this run. Reads the compiler's files and the environment,
    # and makes no other call.
    def self.current(cwd : String, target : String) : FastFacts
      refusal = Toolchain.running_image_refusal
      compiler = [] of FastEntry
      unless refusal
        begin
          compiler = Toolchain.paths.map do |path|
            stamp = FileStamp.of(path)
            if stamp.kind.file? && stamp.digest.nil? && BuildInputs.racy?(Math.max(stamp.mtime, stamp.ctime), BuildInputs.now)
              stamp = stamp.copy_with(ctime: 0_i64)
            end
            FastEntry.new(path, stamp)
          end
        rescue ex : Toolchain::ImageChangedError
          refusal = ex.message || "loaded LLVM-C.dll cannot be identified"
        end
      end
      new(cwd, target, FastRecord.default_workers, compiler, Profile.build_env, refusal)
    end

    # The answer `pkg-config` gives for *mod*, asked once for the run. Tests
    # are checked on several threads, so the answers sit behind a lock.
    def pkg_config(mod : String, static : Bool) : String?
      @pkg_config_lock.synchronize do
        key = {mod, static}
        unless @pkg_config.has_key?(key)
          @pkg_config[key] = Program.pkg_config_query(mod, static)
        end
        @pkg_config[key]
      end
    end
  end

  # The fast-path record of a test: what its last compiler run read, stamped,
  # and the environment it started with. The runner writes it under the test's
  # scratch lock after a compiler run, and reads it without a lock; the write
  # is a rename, so a reader sees the old record or the new one. A missing,
  # corrupt, or other-format record is absent, and nothing is ever written
  # in its place. A record whose inputs the recorder refused (`refused`) names
  # the reason, so the next check can say why it compiles, and never serves.
  class FastRecord
    FORMAT  = "iyi-stale-fast"
    VERSION = 2

    getter test : TestId
    getter file : String
    getter cwd : String
    getter local_build : String
    getter portable_build : String
    getter host_target : String
    getter host_workers : Int32
    getter compiler : Array(FastEntry)
    getter observed_env : Hash(String, String?)
    getter? env_enumerated : Bool
    getter files : Array(FastEntry)
    getter listings : Hash(String, Array(String)?)
    getter pkg_config : Array(FastPkgConfig)
    getter refused : String?

    def initialize(@test : TestId, @file : String, @cwd : String, @local_build : String,
                   @portable_build : String, @host_target : String, @host_workers : Int32,
                   @compiler : Array(FastEntry), @observed_env : Hash(String, String?),
                   @env_enumerated : Bool, @files : Array(FastEntry),
                   @listings : Hash(String, Array(String)?),
                   @pkg_config : Array(FastPkgConfig), @refused : String? = nil)
    end

    # The worker count a build defaults to, which the behavior key encodes.
    # Mirrors `Compiler#n_threads`, which is a property and cannot be read
    # without building a compiler.
    def self.default_workers : Int32
      {% if Fiber.has_constant?(:ExecutionContext) %}
        Fiber::ExecutionContext.default_workers_count
      {% elsif flag?(:win32) %}
        1
      {% else %}
        8
      {% end %}
    end

    # The record of one compiler run, from the inputs file its build wrote.
    # Nil when the file is not this build's (another local build, another
    # format or version) or cannot be read.
    def self.from_inputs(path : String, test : TestId, file : String, facts : FastFacts,
                         local_build : String, portable_build : String) : FastRecord?
      json = JSON.parse(File.read(path))
      return nil unless json["format"]?.try(&.as_s?) == InputsFile::FORMAT
      return nil unless json["version"]?.try(&.as_i?) == InputsFile::VERSION
      return nil unless json["local_build"]?.try(&.as_s?) == local_build

      enumerated = json["env_enumerated"].as_bool
      observed = {} of String => String?
      json["observed_env"].as_h.each { |name, value| observed[name] = value.as_s? }
      # An enumerated build read the whole environment it started with, and
      # that whole environment is what the record must compare.
      facts.env.each { |name, value| observed[name] = value } if enumerated

      new(test, file, facts.cwd, local_build, portable_build, facts.target, facts.workers,
        facts.compiler, observed, enumerated,
        json["files"].as_a.map { |entry| entry_from(entry) },
        listings_from(json["listings"]),
        json["pkg_config"].as_a.map { |entry| pkg_from(entry) })
    rescue
      nil
    end

    # The record of a compiler run whose inputs the recorder refused to write.
    def self.refused(test : TestId, file : String, facts : FastFacts, local_build : String,
                     portable_build : String, reason : String) : FastRecord
      new(test, file, facts.cwd, local_build, portable_build, facts.target, facts.workers,
        facts.compiler, {} of String => String?, false, [] of FastEntry,
        {} of String => Array(String)?, [] of FastPkgConfig, reason)
    end

    # The record of *test*, or nil. Takes no lock and writes nothing.
    def self.read(store : Store, test : TestId) : FastRecord?
      found = parse(File.read(store.fast_path(test)))
      found if found && found.test == test
    rescue File::Error
      nil
    end

    # The record in *content*, or nil when it is corrupt, or of another format
    # or version.
    def self.parse(content : String) : FastRecord?
      json = JSON.parse(content)
      return nil unless json["format"]?.try(&.as_s?) == FORMAT
      return nil unless json["version"]?.try(&.as_i?) == VERSION

      observed = {} of String => String?
      json["observed_env"].as_h.each { |name, value| observed[name] = value.as_s? }
      host = json["host"]
      new(TestId.new(json["test"]["root"].as_s, json["test"]["path"].as_s),
        json["file"].as_s, json["cwd"].as_s, json["local_build"].as_s,
        json["portable_build"].as_s, host["target"].as_s, host["workers"].as_i,
        json["compiler"].as_a.map { |entry| entry_from(entry) },
        observed, json["env_enumerated"].as_bool,
        json["files"].as_a.map { |entry| entry_from(entry) },
        listings_from(json["listings"]),
        json["pkg_config"].as_a.map { |entry| pkg_from(entry) },
        json["refused"]?.try(&.as_s?))
    rescue
      nil
    end

    # The record as the store keeps it.
    def to_store_json : String
      JSON.build do |json|
        json.object do
          json.field "format", FORMAT
          json.field "version", VERSION
          json.field "test" do
            json.object do
              json.field "root", test.root
              json.field "path", test.path
            end
          end
          json.field "file", file
          json.field "cwd", cwd
          json.field "local_build", local_build
          json.field "portable_build", portable_build
          json.field "host" do
            json.object do
              json.field "target", host_target
              json.field "workers", host_workers
            end
          end
          json.field "compiler" do
            json.array { compiler.each { |entry| write_entry(json, entry) } }
          end
          json.field "observed_env" do
            json.object do
              observed_env.keys.sort!.each do |name|
                value = observed_env[name]
                json.field name do
                  if value
                    json.string value
                  else
                    json.null
                  end
                end
              end
            end
          end
          json.field "env_enumerated", env_enumerated?
          json.field "files" do
            json.array { files.each { |entry| write_entry(json, entry) } }
          end
          json.field "listings" do
            json.object do
              listings.keys.sort!.each do |dir|
                names = listings[dir]
                json.field dir do
                  if names
                    json.array { names.each { |entry| json.string entry } }
                  else
                    json.null
                  end
                end
              end
            end
          end
          json.field "pkg_config" do
            json.array do
              pkg_config.each do |entry|
                json.array do
                  json.string entry.mod
                  json.bool entry.static
                  if flags = entry.flags
                    json.string flags
                  else
                    json.null
                  end
                end
              end
            end
          end
          if reason = refused
            json.field "refused", reason
          else
            json.field "refused", nil
          end
        end
      end
    end

    # The first cause that makes this record stop describing the inputs now,
    # as a sentence, or nil when every recorded input is as it was. Causes come
    # cheapest and most telling first. *drop* names the classes the audit
    # ignores (`IYI_STALE_FAST_DROP`): "ctime", "env" or "compiler".
    def unchanged_reason(source : String, facts : FastFacts, drop : Set(String)) : String?
      return refused if refused
      return facts.refusal if facts.refusal
      return "the working directory changed" unless cwd == facts.cwd
      return "the build's file argument changed" unless file == source

      unless drop.includes?("compiler")
        return "the host target changed" unless host_target == facts.target
        return "the worker count changed" unless host_workers == facts.workers
        return "compiler changed: the set of compiler files changed" unless compiler.size == facts.compiler.size
        compiler.each_with_index do |entry, index|
          now = facts.compiler[index]
          unless entry.stamp.kind.file? && entry.stamp.ctime > 0 && now.stamp.kind.file? && now.stamp.ctime > 0
            return "compiler changed: #{File.basename(entry.path)} has no trusted change time"
          end
          if now.path != entry.path || FastRecord.changed?(entry.stamp, now.stamp, now.path, drop)
            return "compiler changed: #{File.basename(entry.path)}"
          end
        end
      end

      unless drop.includes?("env")
        observed_env.each do |name, value|
          return "environment changed: #{name}" unless facts.env[name]? == value
        end
        if env_enumerated?
          facts.env.each_key do |name|
            return "environment changed: #{name}" unless observed_env.has_key?(name)
          end
        end
      end

      files.each do |entry|
        if FastRecord.changed?(entry.stamp, FileStamp.of(entry.path), entry.path, drop)
          return "#{Iyi.relative_filename(entry.path)} changed"
        end
      end

      listings.each do |dir, names|
        return "#{Iyi.relative_filename(dir)} changed" unless BuildInputs.children(dir) == names
      end

      pkg_config.each do |entry|
        unless facts.pkg_config(entry.mod, entry.static) == entry.flags
          return "pkg-config answer for #{entry.mod} changed"
        end
      end

      nil
    end

    # Whether *recorded* no longer describes *now*, the stamp of *path* taken
    # now. A directory is compared by kind alone: its times move whenever
    # anything beside an input is written, and a directory whose entries
    # mattered has a listing. A file is compared by size and modification
    # time, then by change time, device and inode, then by its digest when one
    # was recorded (taken now when *now* has none). *drop* "ctime" leaves the
    # change time, device, inode and digest out.
    def self.changed?(recorded : BuildInputs::Stamp, now : BuildInputs::Stamp, path : String, drop : Set(String)) : Bool
      return true unless now.kind == recorded.kind
      return true if recorded.kind.other?
      return false unless recorded.kind.file?
      return true unless now.size == recorded.size && now.mtime == recorded.mtime
      return false if drop.includes?("ctime")
      return true unless now.ctime == recorded.ctime && now.dev == recorded.dev && now.ino == recorded.ino
      if digest = recorded.digest
        return (now.digest || FileStamp.fingerprint(path)) != digest
      end
      false
    end

    private def write_entry(json : JSON::Builder, entry : FastEntry) : Nil
      stamp = entry.stamp
      json.array do
        json.string entry.path
        json.string stamp.kind.to_s.downcase
        json.number stamp.size
        json.number stamp.mtime
        json.number stamp.ctime
        json.string stamp.dev.to_s
        json.string stamp.ino.to_s
        if digest = stamp.digest
          json.string digest
        else
          json.null
        end
      end
    end

    private def self.entry_from(value : JSON::Any) : FastEntry
      parts = value.as_a
      kind = case parts[1].as_s
             when "absent"    then BuildInputs::Kind::Absent
             when "file"      then BuildInputs::Kind::File
             when "directory" then BuildInputs::Kind::Directory
             when "other"     then BuildInputs::Kind::Other
             else                  raise ArgumentError.new("unknown stamp kind")
             end
      stamp = BuildInputs::Stamp.new(kind, parts[2].as_i64, parts[3].as_i64, parts[7].as_s?,
        parts[4].as_i64, parts[5].as_s.to_u64, parts[6].as_s.to_u64)
      FastEntry.new(parts[0].as_s, stamp)
    end

    private def self.pkg_from(value : JSON::Any) : FastPkgConfig
      parts = value.as_a
      FastPkgConfig.new(parts[0].as_s, parts[1].as_bool, parts[2].as_s?)
    end

    private def self.listings_from(value : JSON::Any) : Hash(String, Array(String)?)
      listings = {} of String => Array(String)?
      value.as_h.each do |dir, names|
        listings[dir] = names.as_a?.try(&.map(&.as_s))
      end
      listings
    end
  end
end
