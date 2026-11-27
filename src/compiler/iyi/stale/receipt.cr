require "json"
require "./encoding"
require "./trace"
require "./machine_key"
require "./roots"

module Iyi::Stale
  FORMAT_VERSION = 2

  # Test identifier: (root "src", path relative to entry root)
  record TestId, root : String, path : String do
    include JSON::Serializable

    def to_s(io : IO) : Nil
      io << root << ':' << path
    end
  end

  # Reopen Observation to support JSON deserialization
  struct Observation
    def self.new(pull : JSON::PullParser)
      task = 0_u64
      kind = ""
      root = ""
      path = ""
      answer = StaticArray(UInt8, 32).new(0_u8)

      pull.read_object do |key|
        case key
        when "task"
          task = pull.read_int.to_u64
        when "kind"
          kind = pull.read_string
        when "root"
          root = pull.read_string
        when "path"
          path = pull.read_string
        when "answer"
          answer = Iyi::Stale.parse_hex(pull.read_string)
        else
          pull.skip
        end
      end

      new(task: task, kind: kind, root: root, path: path, answer: answer)
    end
  end

  struct ReceiptBuild
    include JSON::Serializable

    property build : String
    property toolchain : String
    property behavior : String
    property callpath : String
    property link : String
    property cenv : String

    def initialize(
      @build : String,
      @toolchain : String,
      @behavior : String,
      @callpath : String,
      @link : String,
      @cenv : String,
    )
    end
  end

  struct ReceiptProfile
    include JSON::Serializable

    property fp : String
    property argv : Array(String)
    property stdin : String
    property stdio : String
    property cwd : TestId
    property timeout : Float64
    property umask : Int32
    property rlimits : Hash(String, Int64)
    property cgroup_mem : Int64?
    property loader_vars : String
    property target : String
    property os : String
    property kernel : String

    def initialize(
      @fp : String,
      @argv : Array(String),
      @stdin : String,
      @stdio : String,
      @cwd : TestId,
      @timeout : Float64,
      @umask : Int32,
      @rlimits : Hash(String, Int64),
      @cgroup_mem : Int64?,
      @loader_vars : String,
      @target : String,
      @os : String,
      @kernel : String,
    )
    end

    def self.compute_fp(
      argv : Array(String),
      stdin : String,
      stdio : String,
      cwd : TestId,
      timeout : Float64,
      umask : Int32,
      rlimits : Hash(String, Int64),
      cgroup_mem : Int64?,
      loader_vars : String,
      target : String,
      os : String,
      kernel : String,
    ) : Digest
      Stale.d("profile") do |enc|
        enc.list(argv.size) do |e|
          argv.each { |arg| e.str(arg) }
        end
        enc.str(stdin)
        enc.str(stdio)
        enc.str(cwd.root)
        enc.str(cwd.path)
        enc.uint(timeout.unsafe_as(UInt64))
        enc.int(umask.to_i64)
        enc.list(rlimits.size) do |e|
          rlimits.keys.sort.each do |k|
            e.str(k)
            e.int(rlimits[k])
          end
        end
        if cg = cgroup_mem
          enc.int(cg)
        else
          enc.absent
        end
        enc.str(loader_vars)
        enc.str(target)
        enc.str(os)
        enc.str(kernel)
      end
    end
  end

  struct ReceiptTrace
    include JSON::Serializable

    property fp : String
    property observations : Array(Observation)

    def initialize(@fp : String, @observations : Array(Observation) = [] of Observation)
    end

    def self.compute_fp(observations : Array(Observation)) : Digest
      Trace.compute_trace_fp(observations)
    end
  end

  # What a CI producer exports: the same build, explain and trace as the local
  # record, keyed with plain digests instead of the machine key (§6, D10). A
  # local record's build components are HMACs under this machine's key, which
  # no other machine can reproduce, so a snapshot built from them could never
  # be hit anywhere else.
  struct PortableRecord
    include JSON::Serializable

    property build : ReceiptBuild
    property explain : Hash(String, String)
    property trace : ReceiptTrace

    def initialize(@build : ReceiptBuild, @explain : Hash(String, String), @trace : ReceiptTrace)
    end
  end

  class Receipt
    include JSON::Serializable

    property version : Int32 = 1
    property mode : String = "local" # "local" | "portable"
    property test : TestId
    property build : ReceiptBuild
    property explain : Hash(String, String) = Hash(String, String).new
    property profile : ReceiptProfile
    property trace : ReceiptTrace
    property signature : String = ""
    property newest : String = "pass" # "pass" | "fail" | "hung" | "build-failed"
    property seq : UInt64 = 0_u64
    property contradicted : Bool = false
    # Only on a local record the runner wrote; see `PortableRecord`.
    property portable_twin : PortableRecord? = nil
    # In-memory namespace provenance, excluded from serialized receipt/signatures
    @[JSON::Field(ignore: true)]
    property namespace : String? = nil

    def initialize(
      @test : TestId,
      @build : ReceiptBuild,
      @profile : ReceiptProfile,
      @trace : ReceiptTrace,
      @explain : Hash(String, String) = Hash(String, String).new,
      @version : Int32 = FORMAT_VERSION,
      @mode : String = "local",
      @newest : String = "pass",
      @seq : UInt64 = 0_u64,
      @contradicted : Bool = false,
      signature : String? = nil,
      @namespace : String? = nil,
    )
      if signature
        @signature = signature
      else
        sig_digest = Receipt.compute_signature(
          @test,
          @build.build,
          @profile.fp,
          @trace.fp
        )
        @signature = Stale.hex(sig_digest)
      end
    end

    def self.compute_signature(
      test : TestId,
      build : Digest,
      profile_fp : Digest,
      trace_fp : Digest,
    ) : Digest
      Stale.d("record") do |enc|
        enc.str(test.root)
        enc.str(test.path)
        enc.digest(build)
        enc.digest(profile_fp)
        enc.digest(trace_fp)
      end
    end

    def self.compute_signature(
      test : TestId,
      build_hex : String,
      profile_fp_hex : String,
      trace_fp_hex : String,
    ) : Digest
      compute_signature(
        test,
        Stale.parse_hex(build_hex),
        Stale.parse_hex(profile_fp_hex),
        Stale.parse_hex(trace_fp_hex)
      )
    end

    def ensure_signature! : String
      if @signature.empty?
        sig = Receipt.compute_signature(
          @test,
          @build.build,
          @profile.fp,
          @trace.fp
        )
        @signature = Stale.hex(sig)
      end
      @signature
    end

    def signature_digest : Digest
      Stale.parse_hex(ensure_signature!)
    end

    def local? : Bool
      @mode == "local"
    end

    def portable? : Bool
      @mode == "portable"
    end

    def pass? : Bool
      @version == FORMAT_VERSION && @newest == "pass"
    end
  end

  struct Mask
    include JSON::Serializable

    property test : TestId
    property build : ReceiptBuild
    property profile : ReceiptProfile
    property trace : ReceiptTrace
    property version : Int32 = 1
    @[JSON::Field(ignore: true)]
    property signature : String = ""

    def initialize(
      @test : TestId,
      @build : ReceiptBuild,
      @profile : ReceiptProfile,
      @trace : ReceiptTrace,
      @signature : String = "",
      @version : Int32 = FORMAT_VERSION,
    )
    end

    def to_receipt : Receipt
      Receipt.new(
        test: @test,
        build: @build,
        profile: @profile,
        trace: @trace,
        explain: Hash(String, String).new,
        version: @version,
        mode: "portable",
        newest: "pass",
        seq: 0_u64,
        contradicted: true,
        signature: @signature
      )
    end
  end

  struct Snapshot
    include JSON::Serializable

    property format : String = "iyi-test-index"
    property version : Int32 = 1
    property namespace : String
    property repository : String? = nil
    property workflow : String? = nil
    property ref : String? = nil
    property target : String
    property producer : Hash(String, JSON::Any)? = nil
    property records : Array(Receipt) = [] of Receipt

    def initialize(
      @namespace : String,
      @target : String,
      @records : Array(Receipt) = [] of Receipt,
      @repository : String? = nil,
      @workflow : String? = nil,
      @ref : String? = nil,
      @producer : Hash(String, JSON::Any)? = nil,
      @format : String = "iyi-test-index",
      @version : Int32 = FORMAT_VERSION,
    )
    end

    # D9: the two namespaces a snapshot is imported into. `master` holds the
    # receipts of master pushes and `run:<id>` those of one workflow run. Any
    # other name is refused, so an import cannot add a namespace of its own
    # that every later `--cached` run reads.
    def self.importable_namespace?(namespace : String) : Bool
      return true if namespace == "master"
      return false unless namespace.starts_with?("run:")
      id = namespace.lchop("run:")
      !id.empty? && id.each_char.all?(&.ascii_number?)
    end

    # Why an imported record may not be used, or nil. A record reaches store
    # files through its signature (a mask is named by it) and the files replay
    # reads through its observation paths, so neither is used until it is
    # checked: the record is a portable, uncontradicted pass's; every digest is
    # one `Stale.hex` writes; the trace fingerprint and the signature are the
    # ones its fields give; and no path leaves its root.
    def self.record_error(rec : Receipt, target : String) : String?
      return "mode is '#{rec.mode}', not 'portable'" unless rec.portable?
      return "the record is contradicted" if rec.contradicted
      build = rec.build
      {
        "signature" => rec.signature, "build.build" => build.build, "build.toolchain" => build.toolchain,
        "build.behavior" => build.behavior, "build.callpath" => build.callpath, "build.link" => build.link,
        "build.cenv" => build.cenv, "profile.fp" => rec.profile.fp, "trace.fp" => rec.trace.fp,
      }.each do |field, value|
        return "#{field} is not 64 lowercase hex characters" unless Stale.hex64?(value)
      end
      unless rec.trace.fp == Stale.hex(Trace.compute_trace_fp(rec.trace.observations))
        return "trace.fp is not the fingerprint of its observations"
      end
      unless rec.signature == Stale.hex(Receipt.compute_signature(rec.test, build.build, rec.profile.fp, rec.trace.fp))
        return "signature is not the one its test, build, profile and trace give"
      end
      windows = target.includes?("windows")
      rec.trace.observations.each do |obs|
        if error = observation_path_error(obs, windows)
          return "#{obs.kind} observation #{obs.root}:#{obs.path.inspect} #{error}"
        end
      end
      nil
    end

    # Why replay could leave the observation's root with its path, or nil. An
    # environment observation's path is a variable's name, not a file's. A
    # Windows target's runner writes a relative path with its own separator,
    # so there a backslash separates components; elsewhere it is refused.
    def self.observation_path_error(obs : Observation, windows : Bool) : String?
      path = obs.path
      return "holds a NUL byte" if path.includes?('\0')
      return nil if obs.root == "env"
      return "holds a backslash" if path.includes?('\\') && !windows
      path = path.tr("\\", "/") if windows
      if path.starts_with?('/') || (path.bytesize >= 2 && path[0].ascii_letter? && path[1] == ':')
        return "is absolute"
      end
      return "holds a '..' component" if path.split('/').includes?("..")
      nil
    end
  end
end
