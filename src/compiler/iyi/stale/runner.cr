require "json"
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
require "../compiler"

module Iyi::Stale
  class RunnerError < Exception
  end

  record TestResult,
    file : String,
    status : String,
    seconds : Float64,
    output : String = "",
    cached : Bool = false,
    source : String = "local",
    reuse : String = "miss",
    reason : String? = nil do
    def pass? : Bool
      @status == "pass"
    end

    def cached? : Bool
      @cached
    end
  end

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

      # Process imports
      @import_indices.each do |entry|
        parts = entry.split('=', 2)
        unless parts.size == 2 && !parts[0].empty? && !parts[1].empty?
          abort! "--import-index takes NS=FILE", :USAGE_ERROR
        end
        ns, file = parts[0], parts[1]
        import_ctx = ImportContext.new(target: @target)
        res = Snapshot.import(@store, ns, file, import_ctx)
        unless res.success?
          abort! "import-index: #{res.error}", :USAGE_ERROR
        end
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
          puts %({"tests": [], "passed": 0, "failed": 0, "skipped": #{skipped}})
        else
          puts "0 to run, #{skipped} skipped: no test's imports reach the change"
        end
        return
      end

      # Handle --shard K/N round-robin dealing
      if @shard
        files = files.each_with_index.select { |_, idx| (idx % shard_n) == (shard_k - 1) }.map(&.[0]).to_a
        if files.empty?
          if @as_json
            puts %({"tests": [], "passed": 0, "failed": 0, "skipped": #{skipped}})
          else
            puts "0 to run: shard #{@shard} has no tests"
          end
          return
        end
      end

      # C6: Ambiguous test id detection
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

      machine_key = MachineKey.load_or_create(@store.cache_root)
      keyer_local = Keyer.local(machine_key)
      current_profile = Profile.current(timeout: @timeout, target: @target)

      active_tree : Command::TestTree? = nil
      Signal::INT.trap do
        active_tree.try &.terminate
        exit 130
      end

      results = [] of TestResult
      recorded_receipts = [] of Receipt
      audit_list = [] of Hash(String, JSON::Any)

      files.each do |file|
        test_id = file_test_ids[file]
        is_ambiguous = id_counts[test_id] > 1
        roots = Roots.default_for_file(file, cache_root: @store.cache_root)

        accept_rules = [] of KeyFile::StaleRule
        block_rules = [] of KeyFile::StaleRule
        newest_receipt : Receipt? = nil
        candidates = [] of Receipt

        unless @fresh || is_ambiguous
          candidates = @store.candidates(test_id, @target)
          blockers = @store.blockers(test_id)
          newest_receipt = candidates.first?

          valid = candidates.select do |rec|
            rec.pass? && !rec.contradicted &&
              rec.profile.fp == current_profile.fp &&
              Trace.replay(rec.trace.observations, keyer_local, roots).nil?
          end

          matching_blockers = blockers.select do |rec|
            rec.profile.fp == current_profile.fp &&
              Trace.replay(rec.trace.observations, keyer_local, roots).nil?
          end

          block_rules = matching_blockers.map { |b| KeyFile::StaleRule.new(b.mode, b.build.build) }
          valid_rules = valid.map { |v| KeyFile::StaleRule.new(v.mode, v.build.build) }

          accept_rules = valid_rules.reject do |vr|
            block_rules.any? { |br| br.mode == vr.mode && br.build.compare(vr.build, case_insensitive: true) == 0 }
          end
        end

        # Run test
        started = Time.instant
        out_key_path = File.tempname("iyi-stale-key", ".json")
        accept_path = File.tempname("iyi-stale-accept", ".json")
        block_path = File.tempname("iyi-stale-block", ".json")
        binary = File.tempname("iyi-test", {{ flag?(:win32) ? ".exe" : nil }})
        scratch_dir = File.tempname("iyi-test-scratch")
        Dir.mkdir_p(scratch_dir)
        trace_file = File.tempname("iyi-trace")
        null_io : File? = nil

        begin
          File.write(accept_path, accept_rules.to_json)
          File.write(block_path, block_rules.to_json)

          build_out = IO::Memory.new
          build_env = ENV.to_h
          build_env.delete("IYI_DAEMON_SOCKET")

          build_status = Process.run(
            Process.executable_path.not_nil!,
            [
              "build", file,
              "-o", binary,
              "-Diyi_observe",
              "--stale-key", out_key_path,
              "--stale-accept", accept_path,
              "--stale-block", block_path,
            ],
            env: build_env,
            output: build_out,
            error: build_out
          )

          key_data = if File.file?(out_key_path)
                       KeyFile.parse(File.read(out_key_path)) rescue nil
                     else
                       nil
                     end

          # Case 1: Cached Hit!
          if key_data && (hit = key_data.hit)
            matching_rec = candidates.find do |c|
              c.mode == hit.mode && c.build.build.compare(hit.build, case_insensitive: true) == 0
            end
            source = matching_rec ? (matching_rec.mode == "local" ? "local" : "imported") : "local"
            res = TestResult.new(
              file: file,
              status: "pass",
              seconds: elapsed(started),
              output: "",
              cached: true,
              source: source,
              reuse: "hit",
              reason: nil
            )
            results << res
            if @explain
              puts "#{file}: hit from #{source}"
            end
            next
          end

          # Case 2: Build failed
          unless build_status.success?
            if key_data && (key_data.local || key_data.portable)
              # Build failure after Build computed: revoke every receipt of test that validates now
              @store.revoke(test_id) do |rec|
                rec.profile.fp == current_profile.fp && Trace.replay(rec.trace.observations, keyer_local, roots).nil?
              end
            end
            res = TestResult.new(
              file: file,
              status: "does not build",
              seconds: elapsed(started),
              output: build_out.to_s,
              cached: false,
              source: "local",
              reuse: "miss",
              reason: nil
            )
            results << res
            if @explain
              puts "#{file}: does not build"
            end
            next
          end

          # Case 3: Build succeeded and was not a hit -> execute under profile
          child_env = Profile.clean_child_env(scratch_dir, trace_file, ENV)
          run_out = IO::Memory.new
          null_io = File.open(File::NULL, "r")

          process = Process.new(
            binary,
            env: child_env,
            input: null_io,
            output: run_out,
            error: run_out,
            new_pgroup: true
          )
          tree = Command::TestTree.new(process)
          active_tree = tree

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
            tree.terminate
            done.receive
            test_status = "hung: killed at #{@timeout}s"
            test_output = run_out.to_s
          end

          # Process non-pass exit
          if test_status != "pass"
            # Non-pass exit (fail, signal, timeout kill, reserved status):
            # revoke every receipt of test that validates now (whatever trace state)
            @store.revoke(test_id) do |rec|
              rec.profile.fp == current_profile.fp && Trace.replay(rec.trace.observations, keyer_local, roots).nil?
            end
            res = TestResult.new(
              file: file,
              status: test_status,
              seconds: elapsed(started),
              output: test_output,
              cached: false,
              source: "local",
              reuse: "miss",
              reason: nil
            )
            results << res
            if @explain
              explain_msg = compute_explain_reason(file, key_data, newest_receipt, current_profile, roots, keyer_local, is_ambiguous, nil)
              puts "#{file}: miss: #{explain_msg}"
            end
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
            res = TestResult.new(
              file: file,
              status: "pass",
              seconds: elapsed(started),
              output: "",
              cached: false,
              source: "local",
              reuse: "miss",
              reason: "trace incomplete"
            )
            results << res
            if @explain
              explain_msg = compute_explain_reason(file, key_data, newest_receipt, current_profile, roots, keyer_local, is_ambiguous, "trace incomplete")
              puts "#{file}: miss: #{explain_msg}"
            end
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

          if is_not_reusable
            reuse_tag = is_ambiguous ? "miss" : "not reusable"
            res = TestResult.new(
              file: file,
              status: "pass",
              seconds: elapsed(started),
              output: "",
              cached: false,
              source: "local",
              reuse: reuse_tag,
              reason: taint_reason
            )
            results << res
            if @explain
              explain_msg = compute_explain_reason(file, key_data, newest_receipt, current_profile, roots, keyer_local, is_ambiguous, taint_reason)
              puts "#{file}: miss: #{explain_msg}"
            end
          else
            # Pass, complete, untainted, run inputs unchanged during run: write receipt!
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
                version: 1,
                mode: "local",
                newest: "pass"
              )
              @store.record(receipt)
              recorded_receipts << receipt
            end

            res = TestResult.new(
              file: file,
              status: "pass",
              seconds: elapsed(started),
              output: "",
              cached: false,
              source: "local",
              reuse: "miss",
              reason: nil
            )
            results << res
            if @explain
              explain_msg = compute_explain_reason(file, key_data, newest_receipt, current_profile, roots, keyer_local, is_ambiguous, nil)
              puts "#{file}: miss: #{explain_msg}"
            end
          end
        ensure
          active_tree.try &.close
          active_tree = nil
          null_io.try &.close rescue nil
          FileUtils.rm_rf(scratch_dir) if Dir.exists?(scratch_dir) rescue nil
          File.delete(trace_file) if File.file?(trace_file) rescue nil
          File.delete(out_key_path) if File.file?(out_key_path) rescue nil
          File.delete(accept_path) if File.file?(accept_path) rescue nil
          File.delete(block_path) if File.file?(block_path) rescue nil
          File.delete(binary) if File.file?(binary) rescue nil
          {% if flag?(:win32) %}
            File.delete(binary.rchop(".exe") + ".pdb") rescue nil
          {% elsif flag?(:darwin) %}
            File.delete("#{binary}.dwarf") rescue nil
          {% end %}
        end
      end

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
                    json.field "status", result.status
                    json.field "seconds", result.seconds
                    json.field "output", result.output unless result.output.empty?
                    json.field "cached", result.cached
                    json.field "source", result.source
                    json.field "reuse", result.reuse
                    json.field "reason", result.reason if result.reason
                  end
                end
              end
            end
            json.field "passed", results.size - failed
            json.field "failed", failed
            json.field "skipped", skipped
            json.field "cached", cached_count
            json.field "audit" do
              json.array do
                audit_list.each { |a| a.to_json(json) }
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

      local = key_data.try(&.local)
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
        clean_names = diff_files.map do |f|
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

      if run_mismatch = Trace.replay(newest.trace.observations, keyer, roots)
        return run_mismatch
      end

      "unclassified miss"
    end

    private def elapsed(started : Time::Instant) : Float64
      (Time.instant - started).total_seconds.round(3)
    end

    private def abort!(msg : String, code : Symbol = :USAGE_ERROR) : NoReturn
      raise RunnerError.new(msg)
    end
  end
end
