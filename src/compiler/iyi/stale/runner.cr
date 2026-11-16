require "json"
require "sync/mutex"
require "file_utils"
require "./encoding"
require "./machine_key"
require "./roots"
require "./receipt"
require "./store"
require "./trace"
require "./key_file"
require "./profile"
require "./snapshot"
require "./fast_record"
require "../compiler"

module Iyi::Stale
  class RunnerError < Exception
  end

  record TestResult,
    file : String,
    test : TestId,
    status : String,
    seconds : Float64,
    output : String = "",
    cached : Bool = false,
    source : String = "local",
    reuse : String = "miss",
    reason : String? = nil,
    portable_build : String? = nil,
    profile : String? = nil,
    roots : Hash(String, String) = Hash(String, String).new,
    blocked : Bool = false,
    check : String = "compiler",
    check_reason : String? = nil do
    def pass? : Bool
      @status == "pass"
    end

    def cached? : Bool
      @cached
    end
  end

  # What one test left for the run: its result, the receipt it wrote (if any),
  # the `--explain` line it earns (if asked) and the compiler processes it
  # started. The run reads these in file order once the pool has ended.
  record Outcome,
    result : TestResult,
    receipt : Receipt? = nil,
    explain : String? = nil,
    builds : Int32 = 0,
    audit : Audit? = nil

  # The audit's verdict on a test the fast path would have served: whether the
  # compiler agreed with the record, and the cause when it did not.
  record Audit, file : String, agreed : Bool, reason : String? = nil

  # What a run reads once for the fast path: the facts every record is compared
  # with, whether the audit is on, and the classes the audit drops.
  record FastPath, facts : FastFacts, audit : Bool, drop : Set(String)

  # The fast path's decision for one test: served from its record, or the first
  # cause that sends it to the compiler.
  record FastVerdict, served : Bool, reason : String? = nil, held : FastRecord? = nil

  class Runner
    def initialize(
      @files : Array(String)? = nil,
      @paths : Array(String) = ["."],
      @as_json : Bool = false,
      @timeout : Float64 = 60.0,
      @affected : Array(String) = [] of String,
      @cached : Bool = false,
      @fresh : Bool = false,
      @explain : Bool = false,
      @shard : String? = nil,
      @import_indices : Array(String) = [] of String,
      @export_indices : Array(String) = [] of String,
      @skipped : Int32 = 0,
      @discount_off : Array(String) = [] of String,
      @manifest_changed : Array(String) = [] of String,
      @unimported : Array(String) = [] of String,
      store : Store? = nil,
      target : String? = nil,
      @chaos : Bool = false,
      @parallel : Int32 = Command::TestPool.default_parallel,
    )
      @store = store || Store.new
      @target = target || Config.host_target.to_s
    end

    def run : Nil
      run_internal
    rescue ex : RunnerError
      STDERR.puts ex.message
      exit 1
    end

    def run_internal : Nil
      if @chaos
        abort! "cannot combine --chaos with stale runner", :USAGE_ERROR
      end

      # Validate export index constraints early
      unless @export_indices.empty?
        unless @fresh
          abort! "--export-index requires --fresh", :USAGE_ERROR
        end
        unless ENV["IYI_CI_PRODUCER"]? == "1"
          abort! "--export-index requires IYI_CI_PRODUCER=1", :USAGE_ERROR
        end
      end

      # Parse and validate shard early
      shard_k = 1
      shard_n = 1
      if shard = @shard
        parts = shard.split('/', 2)
        unless parts.size == 2 && (k = parts[0].to_i?) && (n = parts[1].to_i?) && k >= 1 && n >= 1 && k <= n
          abort! "--shard takes K/N where 1 <= K <= N", :USAGE_ERROR
        end
        shard_k = k
        shard_n = n
      end

      @store.ensure_directories!
      @store.prune_outdated_toolchains

      # Process imports: group repeated --import-index by namespace, validate and union shards, then store
      import_groups = Hash(String, Array(String)).new
      @import_indices.each do |entry|
        parts = entry.split('=', 2)
        unless parts.size == 2 && !parts[0].empty? && !parts[1].empty?
          abort! "--import-index takes NS=FILE", :USAGE_ERROR
        end
        ns, file = parts[0], parts[1]
        (import_groups[ns] ||= [] of String) << file
      end

      # Validate and union all shards for each namespace in memory before storing to avoid partial replacement
      snapshots_to_store = [] of Snapshot
      import_ctx = ImportContext.new(target: @target)

      import_groups.each do |ns, ns_files|
        res = Snapshot.validate_shards(ns_files, ns, import_ctx)
        unless res.success? && (snap = res.snapshot)
          abort! "import-index: #{res.error}", :USAGE_ERROR
        end
        snapshots_to_store << snap
      end

      # Atomically store all validated snapshots
      snapshots_to_store.each do |snap|
        @store.import_snapshot(snap)
      end

      files = if initial_files = @files
                initial_files
              else
                discovered = [] of String
                @paths.each do |path|
                  abort! "test takes paths, and '' is not one (no path at all runs the working directory)", :USAGE_ERROR if path.empty?
                  if File.directory?(path)
                    Dir.glob(Iyi.glob_root(path).join("**", "*_test.[iI][yY][iI]")) { |f| discovered << f }
                  elsif File.file?(path)
                    discovered << path
                  else
                    abort! "no such file or directory: #{path}", :USAGE_ERROR
                  end
                end
                discovered.uniq! { |f| Iyi.file_key(File.expand_path(f)) }.sort!
                discovered
              end

      if files.empty?
        abort! "no *_test.iyi found. A test is a plain iyi program that exits non-zero to fail", :USAGE_ERROR
      end

      skipped = @skipped
      discount_off = @discount_off
      manifest_changed = @manifest_changed
      unimported = @unimported

      if files.empty?
        if @as_json
          puts %({"tests": [], "passed": 0, "failed": 0, "skipped": #{skipped}, "cached": 0, "builds": 0, "audit": []})
        else
          puts "0 to run, #{skipped} skipped: no test's imports reach the change"
        end
        return
      end

      # C6: Ambiguous test id detection across ALL discovered tests before sharding
      file_test_ids = Hash(String, TestId).new
      id_counts = Hash(TestId, Int32).new(0)
      files.each do |file|
        code = File.read(file) rescue ""
        entry_root = Compiler.entry_root_of(file, code)
        rel_path = ::Path[File.expand_path(file)].relative_to(File.expand_path(entry_root)).to_s rescue file
        rel_path = rel_path[2..-1] if rel_path.starts_with?("./")
        tid = TestId.new("src", rel_path)
        file_test_ids[file] = tid
        id_counts[tid] += 1
      end

      # Handle --shard K/N round-robin dealing
      if @shard
        files = files.each_with_index.select { |_, idx| (idx % shard_n) == (shard_k - 1) }.map(&.[0]).to_a
        if files.empty?
          if @as_json
            puts %({"tests": [], "passed": 0, "failed": 0, "skipped": #{skipped}, "cached": 0, "builds": 0, "audit": []})
          else
            puts "0 to run: shard #{@shard} has no tests"
          end
          return
        end
      end

      machine_key = MachineKey.load_or_create(@store.cache_root)
      keyer_local = Keyer.local(machine_key)

      # Read once for the run: a test's profile is made from these values and
      # makes no syscalls of its own. The umask is flipped by `Profile.host`
      # and nowhere else.
      host = Profile.host(@target)
      run_cwd = Dir.current
      audit = ENV["IYI_STALE_FAST_AUDIT"]? == "1"
      fast = FastPath.new(FastFacts.current(run_cwd, @target), audit, Runner.fast_drop(audit, ENV["IYI_STALE_FAST_DROP"]?))

      # Every build and run leads a process group that these traps end, so an
      # interrupted run leaves no test running (exit 128 + the signal).
      Command::TestTree.trap_endings

      # Tests with one id share a scratch directory. Within this process they
      # take turns on a fiber mutex: a fiber that waited on the scratch's file
      # lock would hold the only thread, and the holder could never run to
      # release it. The file lock still excludes other processes.
      scratch_locks = Hash(String, Sync::Mutex).new
      files.each do |file|
        scratch_locks[scratch_path(file_test_ids[file])] ||= Sync::Mutex.new
      end

      outcomes = Command::TestPool.run(files.size, @parallel) do |index|
        file = files[index]
        test_id = file_test_ids[file]
        check_one(file, test_id, id_counts[test_id] > 1, host, keyer_local, run_cwd, scratch_locks, fast)
      end

      # The report is made here, once every test has ended, in file order.
      if @explain
        outcomes.each do |outcome|
          if line = outcome.explain
            puts line
          end
        end
      end
      results = outcomes.map(&.result)
      recorded_receipts = outcomes.compact_map(&.receipt)
      builds = outcomes.sum(&.builds)

      # Handle export indices
      unless @export_indices.empty?
        @export_indices.each do |entry|
          parts = entry.split('=', 2)
          ns, file = parts[0], parts[1]
          prod_ctx = ProducerContext.new(
            target: @target,
            shard: @shard || "1/1",
            fresh: @fresh,
            ci_producer: true
          )
          res = Snapshot.export_to_file(file, @store, recorded_receipts, ns, prod_ctx)
          unless res.success?
            abort! "export-index: #{res.error}", :USAGE_ERROR
          end
        end
      end

      # Print results
      failed = results.count { |r| r.status != "pass" }
      cached_count = results.count(&.cached?)

      if @as_json
        JSON.build(STDOUT) do |json|
          json.object do
            json.field "tests" do
              json.array do
                results.each do |result|
                  json.object do
                    json.field "file", result.file
                    json.field "test" do
                      json.object do
                        json.field "root", result.test.root
                        json.field "path", result.test.path
                      end
                    end
                    json.field "status", result.status
                    json.field "seconds", result.seconds
                    json.field "output", result.output unless result.output.empty?
                    json.field "cached", result.cached
                    json.field "source", result.source
                    json.field "reuse", result.reuse
                    json.field "check", result.check
                    json.field "check_reason", result.check_reason if result.check_reason
                    json.field "reason", result.reason if result.reason
                    json.field "portable_build", result.portable_build
                    json.field "profile", result.profile
                    json.field "roots" do
                      json.object do
                        result.roots.each do |k, v|
                          json.field k, v
                        end
                      end
                    end
                    json.field "blocked", result.blocked
                  end
                end
              end
            end
            json.field "passed", results.size - failed
            json.field "failed", failed
            json.field "skipped", skipped
            json.field "cached", cached_count
            json.field "builds", builds
            json.field "audit" do
              json.array do
                outcomes.compact_map(&.audit).each do |entry|
                  json.object do
                    json.field "file", entry.file
                    json.field "agreed", entry.agreed
                    json.field "reason", entry.reason if entry.reason
                  end
                end
              end
            end
            unless discount_off.empty?
              json.field "affected_not_found" do
                json.array { discount_off.each { |missing| json.scalar missing } }
              end
            end
            unless manifest_changed.empty?
              json.field "affected_manifest" do
                json.array { manifest_changed.each { |name| json.scalar name } }
              end
            end
            unless unimported.empty?
              json.field "affected_not_imported" do
                json.array { unimported.each { |name| json.scalar name } }
              end
            end
          end
        end
        STDOUT.puts
      else
        results.each do |result|
          next if result.status == "pass"
          STDOUT << result.file << ": " << result.status << '\n'
          result.output.each_line { |line| STDOUT << "  " << line << '\n' }
        end
        unless manifest_changed.empty?
          puts "#{manifest_changed.join(", ")} changed, so every test ran: the " \
               "requirements are what every package import resolves through"
        end
        unless unimported.empty?
          puts "#{unimported.join(", ")} is not a module an import can name, so every test ran: " \
               "the prelude, a file a macro reads and a fixture reach a test without an import"
        end
        unless discount_off.empty?
          puts "#{discount_off.join(", ")} is not there, so every test ran: " \
               "a file that is gone cannot be proven untouched by anything"
        end
        tail = skipped.zero? ? "" : ", #{skipped} skipped"
        if cached_count > 0
          puts "#{results.size - failed} passed (#{cached_count} from receipts), #{failed} failed#{tail}" + (failed.zero? ? "" : " — a failing test prints above")
        else
          puts "#{results.size - failed} passed, #{failed} failed#{tail}" + (failed.zero? ? "" : " — a failing test prints above")
        end
      end

      exit 1 unless failed.zero?
    end

    # The classes the audit drops, from `IYI_STALE_FAST_DROP`. Honored only
    # under the audit (`IYI_STALE_FAST_AUDIT=1`): it exists to show that the
    # gate fails when a class is ignored.
    def self.fast_drop(audit : Bool, raw : String?) : Set(String)
      drop = Set(String).new
      return drop unless audit
      return drop if raw.nil?
      unless ["ctime", "env", "compiler"].includes?(raw)
        raise RunnerError.new("IYI_STALE_FAST_DROP takes ctime, env or compiler")
      end
      drop << raw
      drop
    end

    # The fast path's verdict on one test. It serves a test only when every
    # condition holds: no block rule, a record of its last compiler run, nothing
    # the record stamped has changed, and a valid local receipt of the record's
    # Build. Otherwise it names the first cause, which the compiler path reports.
    private def fast_verdict(file : String, test_id : TestId, is_ambiguous : Bool,
                             profile : ReceiptProfile, roots : Roots, keyer : Keyer,
                             fast : FastPath) : FastVerdict
      return FastVerdict.new(false, "ambiguous test id") if is_ambiguous
      if @store.blockers(test_id).any? { |rec| block_rule?(rec, profile, roots, keyer) }
        return FastVerdict.new(false, "a contradicted receipt validates")
      end
      record = FastRecord.read(@store, test_id)
      return FastVerdict.new(false, "no record of the inputs") unless record
      if cause = record.unchanged_reason(file, fast.facts, fast.drop)
        return FastVerdict.new(false, cause)
      end
      matched = @store.candidates(test_id, @target, imported: false).any? do |rec|
        valid_candidate?(rec, profile, roots, keyer) &&
          rec.build.build.compare(record.local_build, case_insensitive: true) == 0
      end
      return FastVerdict.new(false, "no valid local receipt has the record's build") unless matched
      FastVerdict.new(true, nil, record)
    end

    private def valid_candidate?(rec : Receipt, profile : ReceiptProfile, roots : Roots, keyer : Keyer) : Bool
      rec.pass? && !rec.contradicted && rec.profile.fp == profile.fp &&
        Trace.replay(rec.trace.observations, keyer_for(rec, keyer), roots).nil?
    end

    private def block_rule?(rec : Receipt, profile : ReceiptProfile, roots : Roots, keyer : Keyer) : Bool
      rec.version != FORMAT_VERSION || !Trace.supported?(rec.trace.observations) ||
        (rec.profile.fp == profile.fp && Trace.replay(rec.trace.observations, keyer_for(rec, keyer), roots).nil?)
    end

    # A test the fast path serves: its result, with no compiler run.
    private def served_outcome(file : String, test_id : TestId, record : FastRecord,
                               profile : ReceiptProfile, roots_map : Hash(String, String),
                               entered : Time::Instant) : Outcome
      result = TestResult.new(
        file: file, test: test_id, status: "pass", seconds: elapsed(entered), output: "",
        cached: true, source: "local", reuse: "hit", reason: nil,
        portable_build: record.portable_build.empty? ? nil : record.portable_build,
        profile: profile.fp, roots: roots_map, blocked: false,
        check: "inputs", check_reason: nil)
      explain = @explain ? "#{file}: hit from local (inputs unchanged)" : nil
      Outcome.new(result: result, explain: explain)
    end

    # Whether the compiler, run for a served test, built the record's Build and
    # hit it: the audit's proof that the record and the check agree.
    private def audit_agrees?(key : KeyFile::KeyFileData?, record : FastRecord) : Bool
      return false unless key && key.hit
      local = key.local
      return false unless local
      local.build.compare(record.local_build, case_insensitive: true) == 0
    end

    # After a compiler run, the record of its inputs: the inputs file the build
    # wrote, or the reason the recorder refused to write one. It is written only
    # when the key file names this build's local Build, since a record of another
    # build would serve the wrong answer. The caller holds the scratch lock.
    private def record_fast_inputs(test_id : TestId, file : String, facts : FastFacts,
                                   inputs_path : String, key : KeyFile::KeyFileData?) : Nil
      return unless key && (local = key.local)
      portable_build = key.portable.try(&.build) || ""
      record = if File.file?(inputs_path)
                 FastRecord.from_inputs(inputs_path, test_id, file, facts, local.build, portable_build)
               elsif reason = key.inputs_refusal
                 FastRecord.refused(test_id, file, facts, local.build, portable_build, reason)
               end
      @store.write_fast(test_id, record.to_store_json) if record
    end

    # The same result under other tags: its check, and where given its status,
    # cache, reuse and reason.
    private def retag(result : TestResult, check : String, check_reason : String?,
                      status : String? = nil, cached : Bool? = nil, reuse : String? = nil,
                      reason : String? = nil) : TestResult
      TestResult.new(
        file: result.file, test: result.test, status: status || result.status,
        seconds: result.seconds, output: result.output,
        cached: cached.nil? ? result.cached : cached, source: result.source,
        reuse: reuse || result.reuse, reason: reason || result.reason,
        portable_build: result.portable_build, profile: result.profile,
        roots: result.roots, blocked: result.blocked,
        check: check, check_reason: check_reason)
    end

    private def scratch_path(test_id : TestId) : String
      File.expand_path(File.join(@store.root_dir, "scratch", Stale.hex(Store.d_test_id(test_id))))
    end

    # One test, built and run or answered by its receipt, as one slot of the
    # pool. It prints nothing: the run reports once the pool is done, in file
    # order. Under the scratch lock the test's body reaches its outcome and
    # leaves the block with `next`, so the lock is released in order.
    private def check_one(
      file : String,
      test_id : TestId,
      is_ambiguous : Bool,
      host : Profile::HostState,
      keyer_local : Keyer,
      run_cwd : String,
      scratch_locks : Hash(String, Sync::Mutex),
      fast : FastPath,
    ) : Outcome
      entered = Time.instant

      s = scratch_path(test_id)
      roots = Roots.default_for_file(file, cache_root: @store.cache_root)
      roots = Roots.new(
        src: roots.src,
        toolchain: roots.toolchain,
        pkg: roots.pkg,
        scratch: s,
        abs: roots.abs
      )
      roots_map = {
        "src"       => roots.src,
        "toolchain" => roots.toolchain,
        "pkg"       => roots.pkg,
        "scratch"   => roots.scratch,
        "abs"       => roots.abs,
      }
      test_argv = [s]
      current_profile = Profile.current(
        host: host,
        argv: test_argv,
        cwd: roots.map(run_cwd),
        timeout: @timeout
      )
      verdict = @cached && !@fresh ? fast_verdict(file, test_id, is_ambiguous, current_profile, roots, keyer_local, fast) : nil
      if verdict && verdict.served && !fast.audit
        return served_outcome(file, test_id, verdict.held.not_nil!, current_profile, roots_map, entered)
      end
      check_reason = verdict && !verdict.served ? verdict.reason : nil

      accept_rules = [] of KeyFile::StaleRule
      block_rules = [] of KeyFile::StaleRule
      newest_receipt : Receipt? = nil
      candidates = [] of Receipt

      unless @fresh || is_ambiguous
        candidates = @store.candidates(test_id, @target)
        blockers = @store.blockers(test_id)
        newest_receipt = candidates.first?

        valid = candidates.select { |rec| valid_candidate?(rec, current_profile, roots, keyer_local) }

        matching_blockers = blockers.select { |rec| block_rule?(rec, current_profile, roots, keyer_local) }
        if blockers.any? { |rec| rec.version != FORMAT_VERSION || !Trace.supported?(rec.trace.observations) }
          valid.clear
        end

        block_rules = matching_blockers.map { |b| KeyFile::StaleRule.new(b.mode, b.build.build) }
        valid_rules = valid.map { |v| KeyFile::StaleRule.new(v.mode, v.build.build) }

        accept_rules = valid_rules.reject do |vr|
          block_rules.any? { |br| br.mode == vr.mode && br.build.compare(vr.build, case_insensitive: true) == 0 }
        end
      end
      # Run test
      lock_path = s + ".lock"
      Dir.mkdir_p(File.dirname(lock_path))

      outcome : Outcome? = nil
      compiled_key : KeyFile::KeyFileData? = nil
      scratch_locks[s].synchronize do
        File.open(lock_path, "a") do |lock_file|
          lock_file.flock_exclusive do
            begin
              FileUtils.rm_r(s) if File.info?(s, follow_symlinks: false)
              Dir.mkdir(s)
            rescue ex : File::Error
              abort! "#{file}: cannot empty scratch directory #{s}: #{ex.message}"
            end

            started = Time.instant
            out_key_path = File.tempname("iyi-stale-key", ".json")
            accept_path = File.tempname("iyi-stale-accept", ".json")
            block_path = File.tempname("iyi-stale-block", ".json")
            binary = File.tempname("iyi-test", {{ flag?(:win32) ? ".exe" : nil }})
            trace_file = File.tempname("iyi-trace")
            inputs_path = File.tempname("iyi-stale-inputs", ".json")
            null_io : File? = nil
            tree : Command::TestTree? = nil
            builds = 0

            begin
              File.write(accept_path, accept_rules.to_json)
              File.write(block_path, block_rules.to_json)
              # The record is only ever the newest check's: a compiler run takes
              # it away first. An audit keeps it, so the audit can check it.
              @store.forget_fast(test_id) unless fast.audit

              build_out = IO::Memory.new

              # Build and test children are assigned before they can run.
              build_process, build_tree = Command::TestTree.start do |before_resume|
                Process.new(
                  Process.executable_path.not_nil!,
                  [
                    "build", file,
                    "-o", binary,
                    "-Diyi_observe",
                    "--stale-key", out_key_path,
                    "--stale-accept", accept_path,
                    "--stale-block", block_path,
                    "--stale-inputs", inputs_path,
                  ],
                  env: Profile.build_env,
                  clear_env: true,
                  input: Process::Redirect::Close,
                  output: build_out,
                  error: build_out,
                  process_group: true,
                  before_resume: before_resume
                )
              end
              builds += 1
              build_status = begin
                build_process.wait
              ensure
                build_tree.close
              end

              key_data = if File.file?(out_key_path)
                           KeyFile.parse(File.read(out_key_path)) rescue nil
                         else
                           nil
                         end
              compiled_key = key_data
              record_fast_inputs(test_id, file, fast.facts, inputs_path, key_data)

              # Case 1: Cached Hit!
              if key_data && (hit = key_data.hit)
                matching_rec = candidates.find do |c|
                  c.mode == hit.mode && c.build.build.compare(hit.build, case_insensitive: true) == 0
                end
                source = if matching_rec
                           if matching_rec.mode == "local"
                             "local"
                           else
                             matching_rec.namespace || "imported"
                           end
                         else
                           "local"
                         end
                p_build = key_data.portable.try(&.build) || (matching_rec && matching_rec.portable? ? matching_rec.build.build : nil)
                res = TestResult.new(
                  file: file,
                  test: test_id,
                  status: "pass",
                  seconds: elapsed(started),
                  output: "",
                  cached: true,
                  source: source,
                  reuse: "hit",
                  reason: nil,
                  portable_build: p_build,
                  profile: current_profile.fp,
                  roots: roots_map,
                  blocked: false
                )
                explain = @explain ? "#{file}: hit from #{source}" : nil
                outcome = Outcome.new(result: res, explain: explain, builds: builds)
                next
              end

              # Case 2: Build failed
              unless build_status.success?
                if key_data && (key_data.local || key_data.portable)
                  # Build failure after Build computed: revoke every receipt of test that validates now
                  @store.revoke(test_id) do |rec|
                    rec.profile.fp == current_profile.fp && Trace.replay(rec.trace.observations, keyer_for(rec, keyer_local), roots).nil?
                  end
                end
                p_build = key_data.try(&.portable.try(&.build))
                is_blocked = key_data.try(&.blocked) == true
                res = TestResult.new(
                  file: file,
                  test: test_id,
                  status: "does not build",
                  seconds: elapsed(started),
                  output: build_out.to_s,
                  cached: false,
                  source: "local",
                  reuse: "miss",
                  reason: nil,
                  portable_build: p_build,
                  profile: current_profile.fp,
                  roots: roots_map,
                  blocked: is_blocked
                )
                explain = @explain ? "#{file}: does not build" : nil
                outcome = Outcome.new(result: res, explain: explain, builds: builds)
                next
              end

              # Case 3: Build succeeded and was not a hit -> execute under profile
              child_env = Profile.clean_child_env(s, trace_file, ENV)
              run_out = IO::Memory.new
              null_io = File.open(File::NULL, "r")

              process, tree = Command::TestTree.start do |before_resume|
                Process.new(
                  binary,
                  args: test_argv,
                  env: child_env,
                  clear_env: true,
                  input: null_io,
                  output: run_out,
                  error: run_out,
                  process_group: true,
                  before_resume: before_resume
                )
              end

              done = ::Channel(Process::Status).new
              spawn { done.send(process.wait) }

              test_status : String = "fail"
              test_output : String = ""

              select
              when status = done.receive
                if status.success?
                  test_status = "pass"
                else
                  test_status = "fail"
                  evidence = run_out.to_s
                  unless status.exit_reason.normal?
                    evidence += "\n" unless evidence.empty? || evidence.ends_with?('\n')
                    evidence += Command.death_sentence(status) + "\n"
                  end
                  test_output = evidence
                end
              when timeout(@timeout.seconds)
                tree.try &.terminate
                done.receive
                test_status = "hung: killed at #{@timeout}s"
                test_output = run_out.to_s
              end

              # Process non-pass exit
              if test_status != "pass"
                # Non-pass exit (fail, signal, timeout kill, reserved status):
                # revoke every receipt of test that validates now (whatever trace state)
                @store.revoke(test_id) do |rec|
                  rec.profile.fp == current_profile.fp && Trace.replay(rec.trace.observations, keyer_for(rec, keyer_local), roots).nil?
                end
                p_build = key_data.try(&.portable.try(&.build))
                is_blocked = key_data.try(&.blocked) == true
                res = TestResult.new(
                  file: file,
                  test: test_id,
                  status: test_status,
                  seconds: elapsed(started),
                  output: test_output,
                  cached: false,
                  source: "local",
                  reuse: "miss",
                  reason: nil,
                  portable_build: p_build,
                  profile: current_profile.fp,
                  roots: roots_map,
                  blocked: is_blocked
                )
                explain = nil
                if @explain
                  explain_msg = compute_explain_reason(file, key_data, newest_receipt, current_profile, roots, keyer_local, is_ambiguous, nil)
                  explain = "#{file}: miss: #{explain_msg}"
                end
                outcome = Outcome.new(result: res, explain: explain, builds: builds)
                next
              end

              # Pass! Parse trace
              trace_res = if File.file?(trace_file)
                            File.open(trace_file) { |io| Trace.parse(io, roots, keyer_local, check_disk_after_exit: true) }
                          else
                            TraceResult.new(complete: false, incomplete_reason: "no trace file")
                          end

              if !trace_res.complete
                # Pass with trace incomplete: write nothing
                p_build = key_data.try(&.portable.try(&.build))
                is_blocked = key_data.try(&.blocked) == true
                res = TestResult.new(
                  file: file,
                  test: test_id,
                  status: "pass",
                  seconds: elapsed(started),
                  output: "",
                  cached: false,
                  source: "local",
                  reuse: "miss",
                  reason: "trace incomplete",
                  portable_build: p_build,
                  profile: current_profile.fp,
                  roots: roots_map,
                  blocked: is_blocked
                )
                explain = nil
                if @explain
                  explain_msg = compute_explain_reason(file, key_data, newest_receipt, current_profile, roots, keyer_local, is_ambiguous, "trace incomplete")
                  explain = "#{file}: miss: #{explain_msg}"
                end
                outcome = Outcome.new(result: res, explain: explain, builds: builds)
                next
              end

              # Trace complete!
              if @fresh
                @store.clear_marker(test_id)
              end

              taint_reason : String? = nil
              is_not_reusable = false

              if !trace_res.taints.empty?
                is_not_reusable = true
                taint = trace_res.taints.first
                kind = Iyi::EffectKind.from_value?(taint.kind).try(&.to_s.underscore) || "taint #{taint.kind}"
                taint_reason = "#{kind} at #{taint.site}"
              elsif !trace_res.a3_mismatches.empty?
                is_not_reusable = true
                taint_reason = trace_res.a3_mismatches.first
              elsif key_data && key_data.not_reusable && !key_data.not_reusable.not_nil!.empty?
                is_not_reusable = true
                nr = key_data.not_reusable.not_nil!.first
                taint_reason = nr.site ? "#{nr.reason} at #{nr.site}" : nr.reason
              elsif is_ambiguous
                is_not_reusable = true
                taint_reason = "ambiguous test id"
              end

              p_build = key_data.try(&.portable.try(&.build))
              is_blocked = key_data.try(&.blocked) == true
              if is_not_reusable
                reuse_tag = is_ambiguous ? "miss" : "not reusable"
                res = TestResult.new(
                  file: file,
                  test: test_id,
                  status: "pass",
                  seconds: elapsed(started),
                  output: "",
                  cached: false,
                  source: "local",
                  reuse: reuse_tag,
                  reason: taint_reason,
                  portable_build: p_build,
                  profile: current_profile.fp,
                  roots: roots_map,
                  blocked: is_blocked
                )
                explain = nil
                if @explain
                  explain_msg = compute_explain_reason(file, key_data, newest_receipt, current_profile, roots, keyer_local, is_ambiguous, taint_reason)
                  explain = "#{file}: miss: #{explain_msg}"
                end
                outcome = Outcome.new(result: res, explain: explain, builds: builds)
              else
                # Pass, complete, untainted, run inputs unchanged during run: write receipt!
                recorded : Receipt? = nil
                if key_data && (mode_build = key_data.local)
                  r_build = ReceiptBuild.new(
                    build: mode_build.build,
                    toolchain: mode_build.toolchain,
                    behavior: mode_build.behavior,
                    callpath: mode_build.callpath,
                    link: mode_build.link,
                    cenv: mode_build.cenv
                  )
                  r_trace = ReceiptTrace.new(
                    fp: Stale.hex(Trace.compute_trace_fp(trace_res.observations)),
                    observations: trace_res.observations
                  )
                  receipt = Receipt.new(
                    test: test_id,
                    build: r_build,
                    profile: current_profile,
                    trace: r_trace,
                    explain: mode_build.explain,
                    version: FORMAT_VERSION,
                    mode: "local",
                    newest: "pass"
                  )
                  # The twin a CI producer exports: the same run, keyed plainly.
                  if (portable_build = key_data.portable) && File.file?(trace_file)
                    portable_trace = File.open(trace_file) { |io| Trace.parse(io, roots, Keyer.portable, check_disk_after_exit: false) }
                    if portable_trace.complete
                      receipt.portable_twin = PortableRecord.new(
                        ReceiptBuild.new(
                          build: portable_build.build,
                          toolchain: portable_build.toolchain,
                          behavior: portable_build.behavior,
                          callpath: portable_build.callpath,
                          link: portable_build.link,
                          cenv: portable_build.cenv
                        ),
                        portable_build.explain,
                        ReceiptTrace.new(
                          fp: Stale.hex(Trace.compute_trace_fp(portable_trace.observations)),
                          observations: portable_trace.observations
                        )
                      )
                    end
                  end
                  @store.record(receipt)
                  recorded = receipt
                end

                p_build = key_data.try(&.portable.try(&.build))
                is_blocked = key_data.try(&.blocked) == true
                res = TestResult.new(
                  file: file,
                  test: test_id,
                  status: "pass",
                  seconds: elapsed(started),
                  output: "",
                  cached: false,
                  source: "local",
                  reuse: "miss",
                  reason: nil,
                  portable_build: p_build,
                  profile: current_profile.fp,
                  roots: roots_map,
                  blocked: is_blocked
                )
                explain = nil
                if @explain
                  explain_msg = compute_explain_reason(file, key_data, newest_receipt, current_profile, roots, keyer_local, is_ambiguous, nil)
                  explain = "#{file}: miss: #{explain_msg}"
                end
                outcome = Outcome.new(result: res, explain: explain, receipt: recorded, builds: builds)
              end
            ensure
              tree.try &.close
              null_io.try &.close rescue nil
              begin
                FileUtils.rm_r(s) if File.info?(s, follow_symlinks: false)
              rescue ex : File::Error
                STDERR.puts "#{file}: scratch directory #{s} was not removed: #{ex.message}"
              end
              File.delete(trace_file) if File.file?(trace_file) rescue nil
              File.delete(out_key_path) if File.file?(out_key_path) rescue nil
              File.delete(accept_path) if File.file?(accept_path) rescue nil
              File.delete(block_path) if File.file?(block_path) rescue nil
              File.delete(inputs_path) if File.file?(inputs_path) rescue nil
              File.delete(binary) if File.file?(binary) rescue nil
              {% if flag?(:win32) %}
                File.delete(binary.rchop(".exe") + ".pdb") rescue nil
              {% elsif flag?(:darwin) %}
                File.delete("#{binary}.dwarf") rescue nil
              {% end %}
            end
          end
        end
      end

      final = outcome.not_nil!
      final = Outcome.new(
        result: retag(final.result, "compiler", check_reason),
        receipt: final.receipt,
        explain: final.explain,
        builds: final.builds
      )
      if fast.audit && (decided = verdict) && decided.served && (held = decided.held)
        if audit_agrees?(compiled_key, held)
          final = Outcome.new(result: final.result, receipt: final.receipt, explain: final.explain,
            builds: final.builds, audit: Audit.new(file, true))
        else
          reason = if final.result.status != "pass"
                     "the test is #{final.result.status}"
                   elsif compiled_key.try(&.hit)
                     "the check built #{compiled_key.try(&.local.try(&.build)) || "nothing"}, and the record has #{held.local_build}"
                   else
                     compute_explain_reason(file, compiled_key, newest_receipt, current_profile, roots, keyer_local, is_ambiguous, final.result.reason)
                   end
          final = Outcome.new(
            result: retag(final.result, "compiler", check_reason, status: "fast path served what the check would not: #{reason}", cached: false, reuse: "miss", reason: reason),
            receipt: final.receipt,
            explain: final.explain,
            builds: final.builds,
            audit: Audit.new(file, false, reason))
        end
      end
      final
    end

    private def compute_explain_reason(
      file : String,
      key_data : KeyFile::KeyFileData?,
      newest : Receipt?,
      profile : ReceiptProfile,
      roots : Roots,
      keyer : Keyer,
      is_ambiguous : Bool,
      taint_reason : String?,
    ) : String
      return "ambiguous test id" if is_ambiguous
      return taint_reason if taint_reason

      unless newest
        return "fresh run"
      end

      local = newest.portable? ? key_data.try(&.portable) : key_data.try(&.local)
      unless local
        return "does not build"
      end

      # Order per §2.9 / §9: toolchain, behavior, compiler environment, link, call path, profile, run
      if local.toolchain != newest.build.toolchain
        return "toolchain changed"
      end

      if local.behavior != newest.build.behavior
        return "behavior changed"
      end

      if local.cenv != newest.build.cenv
        return "compiler environment changed"
      end

      if local.link != newest.build.link
        return "link changed"
      end

      if local.callpath != newest.build.callpath
        curr_explain = local.explain
        rec_explain = newest.explain
        all_keys = (curr_explain.keys + rec_explain.keys).uniq
        diff_files = all_keys.select { |k| curr_explain[k]? != rec_explain[k]? }
        clean_names = diff_files.reject { |k| k == "*" }.sort.map do |f|
          if f.starts_with?("src:")
            f[4..-1]
          elsif f.starts_with?("toolchain:")
            f[10..-1]
          elsif f.starts_with?("pkg:")
            f[4..-1]
          else
            f
          end
        end
        return "call path (#{clean_names.join(", ")})"
      end

      if profile.fp != newest.profile.fp
        return "profile changed"
      end

      if run_mismatch = Trace.replay(newest.trace.observations, keyer_for(newest, keyer), roots)
        return run_mismatch
      end

      "unclassified miss"
    end

    # An imported record's observations are plain digests; a local one's are
    # keyed under this machine's key.
    private def keyer_for(rec : Receipt, local : Keyer) : Keyer
      rec.portable? ? Keyer.portable : local
    end

    private def elapsed(started : Time::Instant) : Float64
      (Time.instant - started).total_seconds.round(3)
    end

    private def abort!(msg : String, code : Symbol = :USAGE_ERROR) : NoReturn
      raise RunnerError.new(msg)
    end
  end
end
