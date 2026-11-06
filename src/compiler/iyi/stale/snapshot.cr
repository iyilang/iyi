require "json"
require "crystal/digest/sha256"
require "./encoding"
require "./receipt"
require "./store"
require "./roots"
require "./trace"

module Iyi::Stale
  # Producer context for exporting a snapshot
  record ProducerContext,
    target : String,
    repository : String? = nil,
    workflow : String? = nil,
    ref : String? = nil,
    run_id : Int64? = nil,
    run_attempt : Int32 = 1,
    sha : String? = nil,
    job : String? = nil,
    shard : String = "1/1",
    fresh : Bool = false,
    ci_producer : Bool? = nil do
    def ci_producer? : Bool
      if @ci_producer.nil?
        ENV["IYI_CI_PRODUCER"]? == "1"
      else
        @ci_producer == true
      end
    end

    def resolved_repository : String
      @repository || ENV["GITHUB_REPOSITORY"]? || "github.com/iyilang/iyi"
    end

    def resolved_workflow : String
      if w = @workflow
        return w
      end

      if wf_ref = ENV["GITHUB_WORKFLOW_REF"]?
        if parsed = Snapshot.workflow_path_from_ref(wf_ref)
          parsed
        else
          raise "GITHUB_WORKFLOW_REF is not <owner>/<repo>/<path>@<ref>: #{wf_ref}"
        end
      else
        ".github/workflows/iyi.yml"
      end
    end

    def resolved_ref : String
      @ref || ENV["GITHUB_REF"]? || "refs/heads/master"
    end

    def resolved_run_id : Int64
      @run_id || ENV["GITHUB_RUN_ID"]?.try(&.to_i64?) || 0_i64
    end

    def resolved_run_attempt : Int32
      @run_attempt
    end

    def resolved_sha : String
      @sha || ENV["GITHUB_SHA"]? || ""
    end

    def resolved_job : String
      @job || ENV["GITHUB_JOB"]? || "iyi"
    end
  end

  # Consumer / import context for validating and importing a snapshot
  record ImportContext,
    target : String,
    current_run_id : Int64? = nil,
    provenance_file : String? = nil,
    trusted_repository : String = "iyilang/iyi",
    trusted_ref : String = "refs/heads/master",
    trusted_workflow : String = ".github/workflows/iyi.yml" do
    def resolved_run_id : Int64?
      @current_run_id || ENV["GITHUB_RUN_ID"]?.try(&.to_i64?)
    end
  end

  # Result of an export operation
  record ExportResult,
    success : Bool,
    error : String?,
    json : String?,
    snapshot : Snapshot?,
    records_count : Int32 = 0 do
    def success? : Bool
      @success
    end
  end

  # Result of an import operation
  record ImportResult,
    success : Bool,
    error : String?,
    snapshot : Snapshot?,
    imported_path : String?,
    records_count : Int32 = 0 do
    def success? : Bool
      @success
    end
  end

  # Result of a shard union operation
  record UnionResult,
    success : Bool,
    error : String?,
    snapshot : Snapshot?,
    records_count : Int32 = 0 do
    def success? : Bool
      @success
    end
  end

  # Reopen Snapshot to add validation, export, import, and shard union capabilities
  struct Snapshot
    ALLOWED_ROOTS        = {"src", "toolchain", "pkg"}
    ALLOWED_OBS_ROOTS    = {"src", "toolchain", "pkg", "env"}
    TRUSTED_REPOSITORIES = {"github.com/iyilang/iyi", "iyilang/iyi"}
    TRUSTED_REFS         = {"refs/heads/master", "master"}

    # Without a Regex: a Regex links pcre2 into the compiler, which the
    # dependency floor forbids.
    def self.normalize_repo(repo : String) : String
      r = repo.lchop("https://").lchop("http://")
      r.lchop("github.com/")
    end

    def self.repos_match?(a : String, b : String) : Bool
      normalize_repo(a) == normalize_repo(b)
    end

    def self.workflow_path_from_ref(ref_str : String) : String?
      at_idx = ref_str.index('@')
      return nil if at_idx.nil? || at_idx == 0

      prefix = ref_str[0...at_idx]
      slash1 = prefix.index('/')
      return nil if slash1.nil? || slash1 == 0

      slash2 = prefix.index('/', slash1 + 1)
      return nil if slash2.nil? || slash2 <= slash1 + 1

      path = prefix[(slash2 + 1)..-1]
      return nil if path.empty?
      return nil unless path.starts_with?(".github/workflows/")
      return nil if path.size <= ".github/workflows/".size

      path
    end

    def self.hash_bytes_sha256(bytes : Bytes) : String
      hasher = Crystal::Digest::SHA256.new
      hasher.update(bytes)
      res = uninitialized StaticArray(UInt8, 32)
      hasher.final(res.to_slice)
      Stale.hex(res).downcase
    end

    def self.hash_file_sha256(path : String) : String
      hash_bytes_sha256(File.read(path).to_slice)
    end

    # Export receipts to a portable Snapshot JSON string
    def self.export(
      store : Store?,
      receipts : Array(Receipt),
      namespace : String,
      ctx : ProducerContext,
    ) : ExportResult
      # 1. Guard checks: only with --fresh and IYI_CI_PRODUCER=1
      unless ctx.fresh
        return ExportResult.new(
          success: false,
          error: "export is allowed only with --fresh",
          json: nil,
          snapshot: nil
        )
      end

      unless ctx.ci_producer?
        return ExportResult.new(
          success: false,
          error: "accidental export outside CI producer attestation flag is refused",
          json: nil,
          snapshot: nil
        )
      end

      # 2. Filter receipts:
      # - Must be passing and not contradicted
      # - Drops receipts with abs or host observations
      # - Drops receipts with roots outside src, toolchain, pkg
      eligible_by_test = Hash(String, Array(Receipt)).new

      receipts.each do |rec|
        next unless rec.pass? && !rec.contradicted

        # Test root check
        next unless ALLOWED_ROOTS.includes?(rec.test.root)

        # Observations check: permit env root only for env_get and env_all
        has_forbidden_obs = rec.trace.observations.any? do |obs|
          obs.root == "abs" || obs.root == "host" || obs.kind == "host" ||
            (obs.root == "env" ? (obs.kind != "env_get" && obs.kind != "env_all") : !ALLOWED_ROOTS.includes?(obs.root))
        end
        next if has_forbidden_obs

        # Explain keys check
        has_forbidden_explain = rec.explain.each_key.any? do |k|
          next false if k == "*"
          parts = k.split(':', 2)
          !ALLOWED_ROOTS.includes?(parts[0])
        end
        next if has_forbidden_explain

        (eligible_by_test[rec.test.to_s] ||= [] of Receipt) << rec
      end

      # 3. At most one receipt per test per snapshot (select newest seq or last)
      portable_records = [] of Receipt

      eligible_by_test.each_value do |recs|
        chosen = recs.max_by?(&.seq) || recs.last

        # The portable twin the runner recorded beside it: a local record's
        # build components are keyed under this machine's key and its
        # environment answers too, so only plain digests can be hit elsewhere.
        # A receipt without one (written by an older runner) is not exported.
        twin = chosen.portable_twin
        next unless twin

        portable_rec = Receipt.new(
          test: chosen.test,
          build: twin.build,
          profile: chosen.profile,
          trace: twin.trace,
          explain: twin.explain,
          version: FORMAT_VERSION,
          mode: "portable",
          newest: "pass",
          seq: 0_u64,
          contradicted: false,
          namespace: namespace
        )
        portable_rec.ensure_signature!
        portable_records << portable_rec
      end

      # 4. Records sorted by test
      portable_records.sort_by! { |r| r.test.to_s }

      # 5. Build producer metadata
      producer_hash = Hash(String, JSON::Any).new
      producer_hash["run_id"] = JSON::Any.new(ctx.resolved_run_id)
      producer_hash["run_attempt"] = JSON::Any.new(ctx.resolved_run_attempt.to_i64)
      producer_hash["sha"] = JSON::Any.new(ctx.resolved_sha)
      producer_hash["job"] = JSON::Any.new(ctx.resolved_job)
      producer_hash["shard"] = JSON::Any.new(ctx.shard)

      snapshot = Snapshot.new(
        format: "iyi-test-index",
        version: FORMAT_VERSION,
        namespace: namespace,
        repository: ctx.resolved_repository,
        workflow: ctx.resolved_workflow,
        ref: ctx.resolved_ref,
        target: ctx.target,
        producer: producer_hash,
        records: portable_records
      )

      json_str = snapshot.to_json

      ExportResult.new(
        success: true,
        error: nil,
        json: json_str,
        snapshot: snapshot,
        records_count: portable_records.size
      )
    end

    # Export directly to a file
    def self.export_to_file(
      path : String,
      store : Store?,
      receipts : Array(Receipt),
      namespace : String,
      ctx : ProducerContext,
    ) : ExportResult
      res = export(store, receipts, namespace, ctx)
      return res unless res.success?

      if json = res.json
        Store.atomic_write(path, json)
      end
      res
    end

    # Validate a snapshot file from disk according to all format and security rules
    def self.validate_file(
      file : String,
      namespace : String,
      ctx : ImportContext,
    ) : ImportResult
      # 1. File existence
      unless File.file?(file)
        return ImportResult.new(
          success: false,
          error: "snapshot file not found: #{file}",
          snapshot: nil,
          imported_path: nil
        )
      end

      # 2. JSON parsing
      content = File.read(file)
      snapshot = begin
        Snapshot.from_json(content)
      rescue ex
        return ImportResult.new(
          success: false,
          error: "invalid snapshot JSON: #{ex.message}",
          snapshot: nil,
          imported_path: nil
        )
      end

      # 3. Format and version
      if snapshot.format != "iyi-test-index"
        return ImportResult.new(
          success: false,
          error: "invalid format: expected 'iyi-test-index', got '#{snapshot.format}'",
          snapshot: nil,
          imported_path: nil
        )
      end

      if snapshot.version != FORMAT_VERSION
        return ImportResult.new(
          success: false,
          error: "unsupported version: #{snapshot.version}",
          snapshot: nil,
          imported_path: nil
        )
      end
      unless snapshot.records.all? { |rec| rec.version == FORMAT_VERSION && Trace.supported?(rec.trace.observations) }
        return ImportResult.new(
          success: false,
          error: "unsupported receipt or observation contract",
          snapshot: nil,
          imported_path: nil
        )
      end


      # 4. Namespace and target matching
      if snapshot.namespace != namespace
        return ImportResult.new(
          success: false,
          error: "namespace mismatch: expected '#{namespace}', got '#{snapshot.namespace}'",
          snapshot: nil,
          imported_path: nil
        )
      end

      if snapshot.target != ctx.target
        return ImportResult.new(
          success: false,
          error: "target mismatch: expected '#{ctx.target}', got '#{snapshot.target}'",
          snapshot: nil,
          imported_path: nil
        )
      end

      # 5. Sorted unique tests
      recs = snapshot.records
      if recs.size > 1
        (0...(recs.size - 1)).each do |i|
          t1 = recs[i].test.to_s
          t2 = recs[i + 1].test.to_s
          if t1 == t2
            return ImportResult.new(
              success: false,
              error: "duplicate test in snapshot: #{t1}",
              snapshot: nil,
              imported_path: nil
            )
          elsif t1 > t2
            return ImportResult.new(
              success: false,
              error: "records not sorted by test: #{t1} > #{t2}",
              snapshot: nil,
              imported_path: nil
            )
          end
        end
      end

      # 6. Roots of trace observations and explain entries restricted to src, toolchain, pkg
      recs.each do |rec|
        unless ALLOWED_ROOTS.includes?(rec.test.root)
          return ImportResult.new(
            success: false,
            error: "test root outside allowed roots: '#{rec.test.root}' in test #{rec.test}",
            snapshot: nil,
            imported_path: nil
          )
        end

        rec.trace.observations.each do |obs|
          if obs.root == "abs" || obs.root == "host" || obs.kind == "host"
            return ImportResult.new(
              success: false,
              error: "trace observation has forbidden root or kind: root='#{obs.root}' kind='#{obs.kind}' in test #{rec.test}",
              snapshot: nil,
              imported_path: nil
            )
          end
          if obs.root == "env"
            unless obs.kind == "env_get" || obs.kind == "env_all"
              return ImportResult.new(
                success: false,
                error: "env observation root has invalid kind: '#{obs.kind}' in test #{rec.test}",
                snapshot: nil,
                imported_path: nil
              )
            end
          elsif !ALLOWED_ROOTS.includes?(obs.root)
            return ImportResult.new(
              success: false,
              error: "trace observation root outside allowed roots: '#{obs.root}' in test #{rec.test}",
              snapshot: nil,
              imported_path: nil
            )
          end
        end

        rec.explain.each_key do |k|
          next if k == "*"
          parts = k.split(':', 2)
          root = parts[0]
          unless ALLOWED_ROOTS.includes?(root)
            return ImportResult.new(
              success: false,
              error: "explain entry root outside allowed roots: '#{root}' in '#{k}' in test #{rec.test}",
              snapshot: nil,
              imported_path: nil
            )
          end
        end
      end

      # 7. Namespace-specific validation
      # Case A: master namespace requires FILE.provenance.json sidecar and master provenance
      if namespace == "master"
        prov_path = ctx.provenance_file || "#{file}.provenance.json"
        unless File.file?(prov_path)
          return ImportResult.new(
            success: false,
            error: "missing provenance sidecar: #{prov_path}",
            snapshot: nil,
            imported_path: nil
          )
        end

        prov_json = begin
          JSON.parse(File.read(prov_path))
        rescue ex
          return ImportResult.new(
            success: false,
            error: "invalid provenance sidecar JSON: #{ex.message}",
            snapshot: nil,
            imported_path: nil
          )
        end

        sidecar_sha256 = prov_json["sha256"]?.try(&.as_s?.try(&.downcase))
        unless sidecar_sha256
          return ImportResult.new(
            success: false,
            error: "provenance sidecar missing sha256",
            snapshot: nil,
            imported_path: nil
          )
        end

        actual_sha256 = hash_file_sha256(file)
        if actual_sha256 != sidecar_sha256
          return ImportResult.new(
            success: false,
            error: "SHA-256 mismatch with provenance sidecar (expected #{sidecar_sha256}, got #{actual_sha256})",
            snapshot: nil,
            imported_path: nil
          )
        end

        # Validate run metadata fields presence on both sidecar and master snapshot
        # run_id
        sidecar_run_id = prov_json["run_id"]?.try { |v| v.as_i64? || v.as_s?.try(&.to_i64?) }
        if sidecar_run_id.nil?
          return ImportResult.new(
            success: false,
            error: "provenance sidecar missing run_id",
            snapshot: nil,
            imported_path: nil
          )
        end

        prod_run_id = snapshot.producer.try(&.["run_id"]?.try { |v| v.as_i64? || v.as_s?.try(&.to_i64?) })
        if prod_run_id.nil?
          return ImportResult.new(
            success: false,
            error: "master snapshot missing run_id",
            snapshot: nil,
            imported_path: nil
          )
        end

        # repository
        sidecar_repo = prov_json["repository"]?.try(&.as_s?).try { |s| s.empty? ? nil : s }
        if sidecar_repo.nil?
          return ImportResult.new(
            success: false,
            error: "provenance sidecar missing repository",
            snapshot: nil,
            imported_path: nil
          )
        end

        snap_repo = snapshot.repository.try { |s| s.empty? ? nil : s }
        if snap_repo.nil?
          return ImportResult.new(
            success: false,
            error: "master snapshot missing repository",
            snapshot: nil,
            imported_path: nil
          )
        end

        # workflow
        sidecar_wf = prov_json["workflow"]?.try(&.as_s?).try { |s| s.empty? ? nil : s }
        if sidecar_wf.nil?
          return ImportResult.new(
            success: false,
            error: "provenance sidecar missing workflow",
            snapshot: nil,
            imported_path: nil
          )
        end

        snap_wf = snapshot.workflow.try { |s| s.empty? ? nil : s }
        if snap_wf.nil?
          return ImportResult.new(
            success: false,
            error: "master snapshot missing workflow",
            snapshot: nil,
            imported_path: nil
          )
        end

        # ref
        sidecar_ref = prov_json["ref"]?.try(&.as_s?).try { |s| s.empty? ? nil : s }
        if sidecar_ref.nil?
          return ImportResult.new(
            success: false,
            error: "provenance sidecar missing ref",
            snapshot: nil,
            imported_path: nil
          )
        end

        snap_ref = snapshot.ref.try { |s| s.empty? ? nil : s }
        if snap_ref.nil?
          return ImportResult.new(
            success: false,
            error: "master snapshot missing ref",
            snapshot: nil,
            imported_path: nil
          )
        end

        # Equality checks
        if sidecar_run_id != prod_run_id
          return ImportResult.new(
            success: false,
            error: "forged run metadata: producer run_id #{prod_run_id} != sidecar run_id #{sidecar_run_id}",
            snapshot: nil,
            imported_path: nil
          )
        end

        if !repos_match?(sidecar_repo, snap_repo)
          return ImportResult.new(
            success: false,
            error: "forged run metadata: repository mismatch (#{snap_repo} vs #{sidecar_repo})",
            snapshot: nil,
            imported_path: nil
          )
        end

        if sidecar_wf != snap_wf
          return ImportResult.new(
            success: false,
            error: "forged run metadata: workflow mismatch (#{snap_wf} vs #{sidecar_wf})",
            snapshot: nil,
            imported_path: nil
          )
        end

        if sidecar_ref != snap_ref
          return ImportResult.new(
            success: false,
            error: "forged run metadata: ref mismatch (#{snap_ref} vs #{sidecar_ref})",
            snapshot: nil,
            imported_path: nil
          )
        end

        # Positive run_id requirement
        if sidecar_run_id <= 0
          return ImportResult.new(
            success: false,
            error: "master snapshot missing run_id",
            snapshot: nil,
            imported_path: nil
          )
        end

        # Trusted repository, ref, and workflow checks
        check_repo = snap_repo
        unless TRUSTED_REPOSITORIES.any? { |tr| repos_match?(check_repo, tr) }
          return ImportResult.new(
            success: false,
            error: "untrusted repository for master namespace: #{check_repo}",
            snapshot: nil,
            imported_path: nil
          )
        end

        check_ref = snap_ref
        unless TRUSTED_REFS.includes?(check_ref)
          return ImportResult.new(
            success: false,
            error: "untrusted ref for master namespace: #{check_ref}",
            snapshot: nil,
            imported_path: nil
          )
        end

        check_wf = snap_wf
        unless check_wf == ctx.trusted_workflow
          return ImportResult.new(
            success: false,
            error: "untrusted workflow for master namespace: #{check_wf}",
            snapshot: nil,
            imported_path: nil
          )
        end
      end

      # Case B: run:<id> namespace: consumed only within the same workflow run
      if namespace.starts_with?("run:")
        ns_run_id = namespace[4..-1]
        prod_run_id = snapshot.producer.try(&.["run_id"]?.try { |v| v.as_i64?.try(&.to_s) || v.as_s? })
        if prod_run_id != ns_run_id
          return ImportResult.new(
            success: false,
            error: "producer run_id does not match namespace run id (#{prod_run_id} != #{ns_run_id})",
            snapshot: nil,
            imported_path: nil
          )
        end

        curr_run_id = ctx.resolved_run_id.try(&.to_s)
        if curr_run_id.nil? || curr_run_id != prod_run_id
          return ImportResult.new(
            success: false,
            error: "GITHUB_RUN_ID does not match producer run (#{curr_run_id || "unset"} != #{prod_run_id})",
            snapshot: nil,
            imported_path: nil
          )
        end
      end

      # Set exact imported namespace in-memory on each receipt (excluded from JSON/signatures)
      snapshot.records.each do |rec|
        rec.namespace = snapshot.namespace
      end

      ImportResult.new(
        success: true,
        error: nil,
        snapshot: snapshot,
        imported_path: nil,
        records_count: snapshot.records.size
      )
    end

    # Import and validate snapshot from file into store
    def self.import(
      store : Store,
      namespace : String,
      file : String,
      ctx : ImportContext,
    ) : ImportResult
      res = validate_file(file, namespace, ctx)
      return res unless res.success? && (snapshot = res.snapshot)

      # Wholesale storage into store under imported/<hex D(namespace)>.json
      imported_path = store.import_snapshot(snapshot)

      ImportResult.new(
        success: true,
        error: nil,
        snapshot: snapshot,
        imported_path: imported_path,
        records_count: snapshot.records.size
      )
    end

    # Validate a group of shard files for a given namespace and return union
    def self.validate_shards(
      files : Array(String),
      namespace : String,
      ctx : ImportContext,
    ) : UnionResult
      if files.empty?
        return UnionResult.new(
          success: false,
          error: "no files provided for namespace '#{namespace}'",
          snapshot: nil
        )
      end

      if files.size == 1
        res = validate_file(files.first, namespace, ctx)
        if res.success? && (snap = res.snapshot)
          return UnionResult.new(
            success: true,
            error: nil,
            snapshot: snap,
            records_count: snap.records.size
          )
        else
          return UnionResult.new(
            success: false,
            error: res.error,
            snapshot: nil
          )
        end
      end

      snapshots = [] of Snapshot
      files.each do |f|
        res = validate_file(f, namespace, ctx)
        unless res.success? && (snap = res.snapshot)
          return UnionResult.new(
            success: false,
            error: res.error,
            snapshot: nil
          )
        end
        snapshots << snap
      end

      union_shards(snapshots)
    end

    # Import a group of shard files for a given namespace into the store atomically
    def self.import_shards(
      store : Store,
      namespace : String,
      files : Array(String),
      ctx : ImportContext,
    ) : ImportResult
      u_res = validate_shards(files, namespace, ctx)
      unless u_res.success? && (snap = u_res.snapshot)
        return ImportResult.new(
          success: false,
          error: u_res.error,
          snapshot: nil,
          imported_path: nil
        )
      end

      imported_path = store.import_snapshot(snap)

      ImportResult.new(
        success: true,
        error: nil,
        snapshot: snap,
        imported_path: imported_path,
        records_count: snap.records.size
      )
    end

    # Union of shard snapshots
    def self.union_shards(snapshots : Array(Snapshot)) : UnionResult
      if snapshots.empty?
        return UnionResult.new(
          success: false,
          error: "cannot union empty snapshot list",
          snapshot: nil
        )
      end
      unless snapshots.all? { |snap| snap.format == "iyi-test-index" && snap.version == FORMAT_VERSION && snap.records.all? { |rec| rec.version == FORMAT_VERSION && Trace.supported?(rec.trace.observations) } }
        return UnionResult.new(success: false, error: "unsupported snapshot contract", snapshot: nil)
      end


      first = snapshots.first
      if snapshots.size == 1
        return UnionResult.new(
          success: true,
          error: nil,
          snapshot: first,
          records_count: first.records.size
        )
      end

      first_run_id = first.producer.try(&.["run_id"]?.try { |v| v.as_i64?.try(&.to_s) || v.as_s? })

      snapshots[1..-1].each do |snap|
        if snap.format != first.format
          return UnionResult.new(success: false, error: "format mismatch across shards", snapshot: nil)
        end
        if snap.version != first.version
          return UnionResult.new(success: false, error: "version mismatch across shards", snapshot: nil)
        end
        if snap.namespace != first.namespace
          return UnionResult.new(success: false, error: "namespace mismatch across shards: #{snap.namespace} vs #{first.namespace}", snapshot: nil)
        end
        if snap.target != first.target
          return UnionResult.new(success: false, error: "target mismatch across shards: #{snap.target} vs #{first.target}", snapshot: nil)
        end

        snap_run_id = snap.producer.try(&.["run_id"]?.try { |v| v.as_i64?.try(&.to_s) || v.as_s? })
        if snap_run_id != first_run_id
          return UnionResult.new(
            success: false,
            error: "mixing shards across producer runs is rejected: run #{snap_run_id} vs #{first_run_id}",
            snapshot: nil
          )
        end
      end

      seen_tests = Set(String).new
      combined_records = [] of Receipt

      snapshots.each do |snap|
        snap.records.each do |rec|
          t_str = rec.test.to_s
          if seen_tests.includes?(t_str)
            return UnionResult.new(
              success: false,
              error: "duplicate test across shards: #{t_str}",
              snapshot: nil
            )
          end
          seen_tests << t_str
          combined_records << rec
        end
      end

      # Sort combined records by test and preserve in-memory namespace
      combined_records.sort_by! { |r| r.test.to_s }
      combined_records.each { |r| r.namespace = first.namespace }

      union_producer = if fp = first.producer
                         dup = fp.dup
                         dup["shard"] = JSON::Any.new("union")
                         dup
                       else
                         nil
                       end

      union_snapshot = Snapshot.new(
        format: first.format,
        version: first.version,
        namespace: first.namespace,
        repository: first.repository,
        workflow: first.workflow,
        ref: first.ref,
        target: first.target,
        producer: union_producer,
        records: combined_records
      )

      UnionResult.new(
        success: true,
        error: nil,
        snapshot: union_snapshot,
        records_count: combined_records.size
      )
    end

    # Union shard files directly from disk
    def self.union_shard_files(files : Array(String)) : UnionResult
      snapshots = [] of Snapshot
      files.each do |f|
        unless File.file?(f)
          return UnionResult.new(success: false, error: "shard file not found: #{f}", snapshot: nil)
        end
        begin
          snapshots << Snapshot.from_json(File.read(f))
        rescue ex
          return UnionResult.new(success: false, error: "invalid shard JSON in #{f}: #{ex.message}", snapshot: nil)
        end
      end
      union_shards(snapshots)
    end

    # Select candidate according to §8 precedence:
    # 1. Local masks and persistent contradiction markers block candidates
    # 2. Local passes take precedence over imported passes (newest first)
    # 3. Unmasked imported passes
    def self.select_candidate(store : Store, test : TestId, target : String) : Receipt?
      store.candidates(test, target).first?
    end
  end
end
