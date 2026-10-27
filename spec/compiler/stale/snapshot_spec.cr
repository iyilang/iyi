require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/receipt"
require "compiler/iyi/stale/store"
require "compiler/iyi/stale/snapshot"

private def make_test_id(path : String = "math_test.iyi", root : String = "src") : Iyi::Stale::TestId
  Iyi::Stale::TestId.new(root, path)
end

private def make_profile(test : Iyi::Stale::TestId, target : String = "x86_64-linux-gnu") : Iyi::Stale::ReceiptProfile
  argv = [] of String
  stdin = "null"
  stdio = "piped"
  cwd = test
  timeout = 60.0
  umask = 18
  rlimits = {} of String => Int64
  cgroup_mem = nil
  loader_vars = "cleared"
  os = "linux"
  kernel = "6.1.0"

  fp_digest = Iyi::Stale::ReceiptProfile.compute_fp(
    argv: argv,
    stdin: stdin,
    stdio: stdio,
    cwd: cwd,
    timeout: timeout,
    umask: umask,
    rlimits: rlimits,
    cgroup_mem: cgroup_mem,
    loader_vars: loader_vars,
    target: target,
    os: os,
    kernel: kernel
  )

  Iyi::Stale::ReceiptProfile.new(
    fp: Iyi::Stale.hex(fp_digest),
    argv: argv,
    stdin: stdin,
    stdio: stdio,
    cwd: cwd,
    timeout: timeout,
    umask: umask,
    rlimits: rlimits,
    cgroup_mem: cgroup_mem,
    loader_vars: loader_vars,
    target: target,
    os: os,
    kernel: kernel
  )
end

private def make_trace(observations : Array(Iyi::Stale::Observation) = [] of Iyi::Stale::Observation) : Iyi::Stale::ReceiptTrace
  fp_digest = Iyi::Stale::ReceiptTrace.compute_fp(observations)
  Iyi::Stale::ReceiptTrace.new(
    fp: Iyi::Stale.hex(fp_digest),
    observations: observations
  )
end

private def make_receipt(
  test : Iyi::Stale::TestId,
  toolchain : String = "1" * 64,
  behavior : String = "2" * 64,
  callpath : String = "3" * 64,
  link : String = "4" * 64,
  cenv : String = "5" * 64,
  target : String = "x86_64-linux-gnu",
  mode : String = "local",
  newest : String = "pass",
  seq : UInt64 = 0_u64,
  contradicted : Bool = false,
  observations : Array(Iyi::Stale::Observation) = [] of Iyi::Stale::Observation,
  explain : Hash(String, String) = Hash(String, String).new,
) : Iyi::Stale::Receipt
  build_digest = Iyi::Stale.d("build") do |enc|
    enc.digest(Iyi::Stale.parse_hex(toolchain))
    enc.digest(Iyi::Stale.parse_hex(behavior))
    enc.digest(Iyi::Stale.parse_hex(callpath))
    enc.digest(Iyi::Stale.parse_hex(link))
    enc.digest(Iyi::Stale.parse_hex(cenv))
  end

  b = Iyi::Stale::ReceiptBuild.new(
    build: Iyi::Stale.hex(build_digest),
    toolchain: toolchain,
    behavior: behavior,
    callpath: callpath,
    link: link,
    cenv: cenv
  )

  prof = make_profile(test, target)
  tr = make_trace(observations)

  receipt = Iyi::Stale::Receipt.new(
    test: test,
    build: b,
    profile: prof,
    trace: tr,
    explain: explain,
    mode: mode,
    newest: newest,
    seq: seq,
    contradicted: contradicted
  )
  # A runner-written record carries the twin an export ships.
  receipt.portable_twin = Iyi::Stale::PortableRecord.new(b, explain, tr)
  receipt
end

private def make_obs(kind : String, root : String, path : String, task : UInt64 = 0_u64) : Iyi::Stale::Observation
  ans = Iyi::Stale.d("obs") { |enc| enc.str("#{kind}:#{root}:#{path}") }
  Iyi::Stale::Observation.new(
    task: task,
    kind: kind,
    root: root,
    path: path,
    answer: ans
  )
end

describe "Iyi::Stale S8: Portable Snapshots" do
  describe "Row 20: Export validation and filtering" do
    it "refuses export when fresh is false" do
      ctx = Iyi::Stale::ProducerContext.new(
        target: "x86_64-linux-gnu",
        fresh: false,
        ci_producer: true
      )
      res = Iyi::Stale::Snapshot.export(nil, [] of Iyi::Stale::Receipt, "master", ctx)
      res.success?.should be_false
      res.error.not_nil!.should contain("only with --fresh")
    end

    it "refuses accidental export outside CI producer attestation flag" do
      # Accidental export outside CI producer attestation flag is refused
      ctx = Iyi::Stale::ProducerContext.new(
        target: "x86_64-linux-gnu",
        fresh: true,
        ci_producer: false
      )
      res = Iyi::Stale::Snapshot.export(nil, [] of Iyi::Stale::Receipt, "master", ctx)
      res.success?.should be_false
      res.error.not_nil!.should contain("accidental export outside CI producer attestation flag is refused")
    end

    it "drops receipts with abs or host observations during export" do
      ctx = Iyi::Stale::ProducerContext.new(
        target: "x86_64-linux-gnu",
        fresh: true,
        ci_producer: true,
        run_id: 100_i64
      )

      t_clean = make_test_id("clean_test.iyi")
      r_clean = make_receipt(t_clean, observations: [make_obs("file_read", "src", "clean.txt")])

      t_abs = make_test_id("abs_test.iyi")
      r_abs = make_receipt(t_abs, observations: [make_obs("file_read", "abs", "/etc/hosts")])

      t_host = make_test_id("host_test.iyi")
      r_host = make_receipt(t_host, observations: [make_obs("host", "host", "hostname")])

      res = Iyi::Stale::Snapshot.export(nil, [r_clean, r_abs, r_host], "master", ctx)
      res.success?.should be_true
      snap = res.snapshot.not_nil!
      snap.records.size.should eq(1)
      snap.records.first.test.should eq(t_clean)
      snap.records.first.mode.should eq("portable")
    end

    it "drops non-pass or contradicted receipts during export" do
      ctx = Iyi::Stale::ProducerContext.new(
        target: "x86_64-linux-gnu",
        fresh: true,
        ci_producer: true
      )

      t_pass = make_test_id("pass_test.iyi")
      r_pass = make_receipt(t_pass, newest: "pass", contradicted: false)

      t_fail = make_test_id("fail_test.iyi")
      r_fail = make_receipt(t_fail, newest: "fail")

      t_contra = make_test_id("contra_test.iyi")
      r_contra = make_receipt(t_contra, newest: "pass", contradicted: true)

      res = Iyi::Stale::Snapshot.export(nil, [r_pass, r_fail, r_contra], "master", ctx)
      res.success?.should be_true
      res.snapshot.not_nil!.records.size.should eq(1)
      res.snapshot.not_nil!.records.first.test.should eq(t_pass)
    end

    it "deduplicates by test keeping newest and sorts records by test" do
      ctx = Iyi::Stale::ProducerContext.new(
        target: "x86_64-linux-gnu",
        fresh: true,
        ci_producer: true
      )

      t_z = make_test_id("z_test.iyi")
      r_z = make_receipt(t_z, seq: 1_u64)

      t_a = make_test_id("a_test.iyi")
      r_a1 = make_receipt(t_a, link: "a" * 64, seq: 2_u64)
      r_a2 = make_receipt(t_a, link: "b" * 64, seq: 5_u64) # newer

      t_m = make_test_id("m_test.iyi")
      r_m = make_receipt(t_m, seq: 3_u64)

      res = Iyi::Stale::Snapshot.export(nil, [r_z, r_a1, r_m, r_a2], "master", ctx)
      res.success?.should be_true
      recs = res.snapshot.not_nil!.records
      recs.size.should eq(3)
      # Sorted by test: a, m, z
      recs[0].test.should eq(t_a)
      recs[0].build.link.should eq("b" * 64) # Picked newer seq
      recs[1].test.should eq(t_m)
      recs[2].test.should eq(t_z)
    end
  end

  describe "Row 20: Import refusal checks" do
    it "refuses snapshot with wrong format or version" do
      with_tempfile("snap_bad_fmt") do |cache_root|
        Dir.mkdir_p(cache_root)
        store = Iyi::Stale::Store.new(cache_root)
        ctx = Iyi::Stale::ImportContext.new(target: "x86_64-linux-gnu")

        bad_fmt = File.join(cache_root, "bad_fmt.json")
        File.write(bad_fmt, %({"format": "other-index", "version": 1, "namespace": "dev", "target": "x86_64-linux-gnu", "records": []}))
        res = Iyi::Stale::Snapshot.import(store, "dev", bad_fmt, ctx)
        res.success?.should be_false
        res.error.not_nil!.should contain("invalid format")

        bad_ver = File.join(cache_root, "bad_ver.json")
        File.write(bad_ver, %({"format": "iyi-test-index", "version": 99, "namespace": "dev", "target": "x86_64-linux-gnu", "records": []}))
        res2 = Iyi::Stale::Snapshot.import(store, "dev", bad_ver, ctx)
        res2.success?.should be_false
        res2.error.not_nil!.should contain("unsupported version")
      end
    end

    it "refuses snapshot with wrong namespace or wrong target" do
      with_tempfile("snap_mismatch") do |cache_root|
        Dir.mkdir_p(cache_root)
        store = Iyi::Stale::Store.new(cache_root)
        ctx = Iyi::Stale::ImportContext.new(target: "x86_64-linux-gnu")

        ns_file = File.join(cache_root, "ns.json")
        File.write(ns_file, %({"format": "iyi-test-index", "version": 1, "namespace": "prod", "target": "x86_64-linux-gnu", "records": []}))
        res = Iyi::Stale::Snapshot.import(store, "dev", ns_file, ctx)
        res.success?.should be_false
        res.error.not_nil!.should contain("namespace mismatch")

        target_file = File.join(cache_root, "target.json")
        File.write(target_file, %({"format": "iyi-test-index", "version": 1, "namespace": "dev", "target": "aarch64-darwin", "records": []}))
        res2 = Iyi::Stale::Snapshot.import(store, "dev", target_file, ctx)
        res2.success?.should be_false
        res2.error.not_nil!.should contain("target mismatch")
      end
    end

    it "refuses snapshot with duplicate tests or unsorted tests" do
      with_tempfile("snap_unsorted") do |cache_root|
        Dir.mkdir_p(cache_root)
        store = Iyi::Stale::Store.new(cache_root)
        ctx = Iyi::Stale::ImportContext.new(target: "x86_64-linux-gnu")

        t1 = make_test_id("a_test.iyi")
        t2 = make_test_id("b_test.iyi")
        r1 = make_receipt(t1, mode: "portable")
        r2 = make_receipt(t2, mode: "portable")

        # Duplicate test
        dup_file = File.join(cache_root, "dup.json")
        snap_dup = Iyi::Stale::Snapshot.new(
          namespace: "dev",
          target: "x86_64-linux-gnu",
          records: [r1, r1]
        )
        File.write(dup_file, snap_dup.to_json)
        res = Iyi::Stale::Snapshot.import(store, "dev", dup_file, ctx)
        res.success?.should be_false
        res.error.not_nil!.should contain("duplicate test")

        # Unsorted tests: b before a
        unsorted_file = File.join(cache_root, "unsorted.json")
        snap_unsorted = Iyi::Stale::Snapshot.new(
          namespace: "dev",
          target: "x86_64-linux-gnu",
          records: [r2, r1]
        )
        File.write(unsorted_file, snap_unsorted.to_json)
        res2 = Iyi::Stale::Snapshot.import(store, "dev", unsorted_file, ctx)
        res2.success?.should be_false
        res2.error.not_nil!.should contain("records not sorted by test")
      end
    end

    it "refuses snapshot with path/root outside src/toolchain/pkg" do
      with_tempfile("snap_roots") do |cache_root|
        Dir.mkdir_p(cache_root)
        store = Iyi::Stale::Store.new(cache_root)
        ctx = Iyi::Stale::ImportContext.new(target: "x86_64-linux-gnu")

        # 1. Test root outside allowed
        t_bad_root = make_test_id("bad.iyi", root: "abs")
        r_bad_root = make_receipt(t_bad_root, mode: "portable")
        f1 = File.join(cache_root, "bad_test_root.json")
        File.write(f1, Iyi::Stale::Snapshot.new(namespace: "dev", target: "x86_64-linux-gnu", records: [r_bad_root]).to_json)
        res1 = Iyi::Stale::Snapshot.import(store, "dev", f1, ctx)
        res1.success?.should be_false
        res1.error.not_nil!.should contain("test root outside allowed roots")

        # 2. Observation root outside allowed (e.g. abs)
        t_ok = make_test_id("ok.iyi")
        r_bad_obs = make_receipt(t_ok, mode: "portable", observations: [make_obs("file_read", "abs", "/etc/passwd")])
        f2 = File.join(cache_root, "bad_obs_root.json")
        File.write(f2, Iyi::Stale::Snapshot.new(namespace: "dev", target: "x86_64-linux-gnu", records: [r_bad_obs]).to_json)
        res2 = Iyi::Stale::Snapshot.import(store, "dev", f2, ctx)
        res2.success?.should be_false
        res2.error.not_nil!.should contain("forbidden root or kind")

        # 3. Explain key outside allowed roots
        r_bad_explain = make_receipt(t_ok, mode: "portable", explain: {"abs:/tmp/foo" => "1" * 64})
        f3 = File.join(cache_root, "bad_explain.json")
        File.write(f3, Iyi::Stale::Snapshot.new(namespace: "dev", target: "x86_64-linux-gnu", records: [r_bad_explain]).to_json)
        res3 = Iyi::Stale::Snapshot.import(store, "dev", f3, ctx)
        res3.success?.should be_false
        res3.error.not_nil!.should contain("explain entry root outside allowed roots")
      end
    end
  end

  describe "Row 19: Shard union and rejection rules" do
    it "unions shard k/3 snapshots from same producer run into unsharded snapshot" do
      t1 = make_test_id("a_test.iyi")
      t2 = make_test_id("b_test.iyi")
      t3 = make_test_id("c_test.iyi")

      r1 = make_receipt(t1, mode: "portable")
      r2 = make_receipt(t2, mode: "portable")
      r3 = make_receipt(t3, mode: "portable")

      prod1 = {"run_id" => JSON::Any.new(42_i64), "run_attempt" => JSON::Any.new(1_i64), "sha" => JSON::Any.new("abc"), "job" => JSON::Any.new("iyi"), "shard" => JSON::Any.new("1/3")}
      prod2 = {"run_id" => JSON::Any.new(42_i64), "run_attempt" => JSON::Any.new(1_i64), "sha" => JSON::Any.new("abc"), "job" => JSON::Any.new("iyi"), "shard" => JSON::Any.new("2/3")}
      prod3 = {"run_id" => JSON::Any.new(42_i64), "run_attempt" => JSON::Any.new(1_i64), "sha" => JSON::Any.new("abc"), "job" => JSON::Any.new("iyi"), "shard" => JSON::Any.new("3/3")}

      s1 = Iyi::Stale::Snapshot.new(namespace: "run:42", target: "x86_64-linux-gnu", producer: prod1, records: [r1])
      s2 = Iyi::Stale::Snapshot.new(namespace: "run:42", target: "x86_64-linux-gnu", producer: prod2, records: [r2])
      s3 = Iyi::Stale::Snapshot.new(namespace: "run:42", target: "x86_64-linux-gnu", producer: prod3, records: [r3])

      res = Iyi::Stale::Snapshot.union_shards([s2, s3, s1])
      res.success?.should be_true
      union = res.snapshot.not_nil!
      union.records.size.should eq(3)
      # Result is sorted [t1, t2, t3]
      union.records[0].test.should eq(t1)
      union.records[1].test.should eq(t2)
      union.records[2].test.should eq(t3)
      union.producer.not_nil!["run_id"].as_i64.should eq(42_i64)
      union.producer.not_nil!["shard"].as_s.should eq("union")
    end

    it "rejects mixing shards across producer runs" do
      t1 = make_test_id("a_test.iyi")
      t2 = make_test_id("b_test.iyi")

      r1 = make_receipt(t1, mode: "portable")
      r2 = make_receipt(t2, mode: "portable")

      prod1 = {"run_id" => JSON::Any.new(101_i64), "run_attempt" => JSON::Any.new(1_i64), "sha" => JSON::Any.new("abc"), "job" => JSON::Any.new("iyi"), "shard" => JSON::Any.new("1/2")}
      prod2 = {"run_id" => JSON::Any.new(102_i64), "run_attempt" => JSON::Any.new(1_i64), "sha" => JSON::Any.new("abc"), "job" => JSON::Any.new("iyi"), "shard" => JSON::Any.new("2/2")}

      s1 = Iyi::Stale::Snapshot.new(namespace: "dev", target: "x86_64-linux-gnu", producer: prod1, records: [r1])
      s2 = Iyi::Stale::Snapshot.new(namespace: "dev", target: "x86_64-linux-gnu", producer: prod2, records: [r2])

      res = Iyi::Stale::Snapshot.union_shards([s1, s2])
      res.success?.should be_false
      res.error.not_nil!.should contain("mixing shards across producer runs is rejected")
    end

    it "rejects duplicate tests across shards" do
      t1 = make_test_id("shared_test.iyi")
      r1 = make_receipt(t1, mode: "portable")
      r2 = make_receipt(t1, mode: "portable")

      prod1 = {"run_id" => JSON::Any.new(500_i64), "shard" => JSON::Any.new("1/2")}
      prod2 = {"run_id" => JSON::Any.new(500_i64), "shard" => JSON::Any.new("2/2")}

      s1 = Iyi::Stale::Snapshot.new(namespace: "dev", target: "x86_64-linux-gnu", producer: prod1, records: [r1])
      s2 = Iyi::Stale::Snapshot.new(namespace: "dev", target: "x86_64-linux-gnu", producer: prod2, records: [r2])

      res = Iyi::Stale::Snapshot.union_shards([s1, s2])
      res.success?.should be_false
      res.error.not_nil!.should contain("duplicate test across shards")
    end
  end

  describe "Row 27: Local half - Empty snapshot, target mismatch, wholesale replacement, and precedence" do
    it "empty snapshot imports cleanly and turns consumption off (0 candidates)" do
      with_tempfile("snap_empty_audit") do |cache_root|
        Dir.mkdir_p(cache_root)
        store = Iyi::Stale::Store.new(cache_root)
        store.ensure_directories!
        ctx = Iyi::Stale::ImportContext.new(target: "x86_64-linux-gnu")

        t1 = make_test_id("demo_test.iyi")

        # 1. First import a populated snapshot
        r1 = make_receipt(t1, mode: "portable")
        p_ctx = Iyi::Stale::ProducerContext.new(target: "x86_64-linux-gnu", fresh: true, ci_producer: true)
        f_pop = File.join(cache_root, "pop.json")
        Iyi::Stale::Snapshot.export_to_file(f_pop, store, [r1], "audit_ns", p_ctx)

        res1 = Iyi::Stale::Snapshot.import(store, "audit_ns", f_pop, ctx)
        res1.success?.should be_true
        store.candidates(t1, "x86_64-linux-gnu").size.should eq(1)

        # 2. Disagreeing audit run publishes empty snapshot
        f_empty = File.join(cache_root, "empty.json")
        Iyi::Stale::Snapshot.export_to_file(f_empty, store, [] of Iyi::Stale::Receipt, "audit_ns", p_ctx)

        # 3. Importing empty snapshot replaces older wholesale
        res2 = Iyi::Stale::Snapshot.import(store, "audit_ns", f_empty, ctx)
        res2.success?.should be_true
        res2.records_count.should eq(0)

        # 4. Candidates now returns 0 -> consumption turned off!
        store.candidates(t1, "x86_64-linux-gnu").size.should eq(0)
        Iyi::Stale::Snapshot.select_candidate(store, t1, "x86_64-linux-gnu").should be_nil
      end
    end

    it "target mismatch refuses import and leaves store empty" do
      with_tempfile("snap_target_mismatch") do |cache_root|
        Dir.mkdir_p(cache_root)
        store = Iyi::Stale::Store.new(cache_root)
        ctx = Iyi::Stale::ImportContext.new(target: "x86_64-linux-gnu")

        t1 = make_test_id("target_test.iyi")
        r1 = make_receipt(t1, mode: "portable")
        snap = Iyi::Stale::Snapshot.new(namespace: "demo", target: "aarch64-linux-gnu", records: [r1])

        snap_file = File.join(cache_root, "snap.json")
        File.write(snap_file, snap.to_json)

        res = Iyi::Stale::Snapshot.import(store, "demo", snap_file, ctx)
        res.success?.should be_false
        res.error.not_nil!.should contain("target mismatch")
        store.candidates(t1, "x86_64-linux-gnu").size.should eq(0)
      end
    end

    it "enforces precedence: local masks/contradictions > local passes > imported passes" do
      with_tempfile("snap_precedence") do |cache_root|
        Dir.mkdir_p(cache_root)
        store = Iyi::Stale::Store.new(cache_root)
        store.ensure_directories!
        ctx = Iyi::Stale::ImportContext.new(target: "x86_64-linux-gnu")

        t = make_test_id("precedence_test.iyi")

        # 1. Imported pass (valid 64-char hex for callpath)
        r_imported = make_receipt(t, callpath: "aa" * 32, mode: "portable")
        p_ctx = Iyi::Stale::ProducerContext.new(target: "x86_64-linux-gnu", fresh: true, ci_producer: true)
        f_imp = File.join(cache_root, "imp.json")
        Iyi::Stale::Snapshot.export_to_file(f_imp, store, [r_imported], "prec_ns", p_ctx)
        Iyi::Stale::Snapshot.import(store, "prec_ns", f_imp, ctx).success?.should be_true

        # With only imported pass:
        cand = Iyi::Stale::Snapshot.select_candidate(store, t, "x86_64-linux-gnu")
        cand.not_nil!.mode.should eq("portable")
        cand.not_nil!.build.callpath.should eq("aa" * 32)

        # 2. Add local pass: local pass must take precedence over imported pass!
        r_local = make_receipt(t, callpath: "bb" * 32, mode: "local", seq: 10_u64)
        store.record(r_local)

        candidates = store.candidates(t, "x86_64-linux-gnu")
        candidates.size.should eq(2)
        candidates[0].mode.should eq("local") # Local pass first!
        candidates[1].mode.should eq("portable")

        cand2 = Iyi::Stale::Snapshot.select_candidate(store, t, "x86_64-linux-gnu")
        cand2.not_nil!.mode.should eq("local")
        cand2.not_nil!.build.callpath.should eq("bb" * 32)

        # 3. Add local contradiction marker: persistent marker blocks candidates!
        store.write_marker(t, "test failed on fresh run")
        store.has_marker?(t).should be_true
        store.candidates(t, "x86_64-linux-gnu").size.should eq(0)
        Iyi::Stale::Snapshot.select_candidate(store, t, "x86_64-linux-gnu").should be_nil

        # Clear marker
        store.clear_marker(t)

        # 4. Mask the imported receipt: imported candidate is blocked!
        r_imported.ensure_signature!
        mask = Iyi::Stale::Mask.new(
          test: r_imported.test,
          build: r_imported.build,
          profile: r_imported.profile,
          trace: r_imported.trace,
          signature: r_imported.signature
        )
        Iyi::Stale::Store.atomic_write(store.mask_path(r_imported.signature), mask.to_json)
        store.is_masked?(r_imported.signature).should be_true

        cands_after_mask = store.candidates(t, "x86_64-linux-gnu")
        cands_after_mask.size.should eq(1) # Only local pass remains, imported is masked
        cands_after_mask[0].mode.should eq("local")
      end
    end
  end

  describe "Row 32: Master namespace sidecar provenance verification" do
    it "refuses master snapshot lacking .provenance.json sidecar" do
      with_tempfile("snap_missing_sidecar") do |cache_root|
        Dir.mkdir_p(cache_root)
        store = Iyi::Stale::Store.new(cache_root)
        ctx = Iyi::Stale::ImportContext.new(target: "x86_64-linux-gnu")

        snap_file = File.join(cache_root, "master_snap.json")
        snap = Iyi::Stale::Snapshot.new(
          namespace: "master",
          target: "x86_64-linux-gnu",
          repository: "github.com/iyilang/iyi",
          workflow: ".github/workflows/iyi.yml",
          ref: "refs/heads/master",
          producer: {"run_id" => JSON::Any.new(777_i64)}
        )
        File.write(snap_file, snap.to_json)

        res = Iyi::Stale::Snapshot.import(store, "master", snap_file, ctx)
        res.success?.should be_false
        res.error.not_nil!.should contain("missing provenance sidecar")
      end
    end

    it "refuses master snapshot with mismatched SHA-256 in sidecar" do
      with_tempfile("snap_sha_mismatch") do |cache_root|
        Dir.mkdir_p(cache_root)
        store = Iyi::Stale::Store.new(cache_root)
        ctx = Iyi::Stale::ImportContext.new(target: "x86_64-linux-gnu")

        snap_file = File.join(cache_root, "master_snap.json")
        snap = Iyi::Stale::Snapshot.new(
          namespace: "master",
          target: "x86_64-linux-gnu",
          repository: "github.com/iyilang/iyi",
          workflow: ".github/workflows/iyi.yml",
          ref: "refs/heads/master",
          producer: {"run_id" => JSON::Any.new(777_i64)}
        )
        File.write(snap_file, snap.to_json)

        sidecar_file = "#{snap_file}.provenance.json"
        sidecar = {
          "sha256"     => "0" * 64, # Wrong hash
          "run_id"     => 777_i64,
          "repository" => "github.com/iyilang/iyi",
          "workflow"   => ".github/workflows/iyi.yml",
          "ref"        => "refs/heads/master",
        }
        File.write(sidecar_file, sidecar.to_json)

        res = Iyi::Stale::Snapshot.import(store, "master", snap_file, ctx)
        res.success?.should be_false
        res.error.not_nil!.should contain("SHA-256 mismatch with provenance sidecar")
      end
    end

    it "refuses master snapshot with forged run metadata" do
      with_tempfile("snap_forged_meta") do |cache_root|
        Dir.mkdir_p(cache_root)
        store = Iyi::Stale::Store.new(cache_root)
        ctx = Iyi::Stale::ImportContext.new(target: "x86_64-linux-gnu")

        snap_file = File.join(cache_root, "master_snap.json")
        snap = Iyi::Stale::Snapshot.new(
          namespace: "master",
          target: "x86_64-linux-gnu",
          repository: "github.com/iyilang/iyi",
          workflow: ".github/workflows/iyi.yml",
          ref: "refs/heads/master",
          producer: {"run_id" => JSON::Any.new(888_i64)} # Producer says 888
        )
        File.write(snap_file, snap.to_json)
        actual_sha = Iyi::Stale::Snapshot.hash_file_sha256(snap_file)

        # 1. Run ID forged (sidecar says 777 vs producer 888)
        sidecar_file = "#{snap_file}.provenance.json"
        sidecar_forged_run = {
          "sha256"     => actual_sha,
          "run_id"     => 777_i64,
          "repository" => "github.com/iyilang/iyi",
          "workflow"   => ".github/workflows/iyi.yml",
          "ref"        => "refs/heads/master",
        }
        File.write(sidecar_file, sidecar_forged_run.to_json)
        res1 = Iyi::Stale::Snapshot.import(store, "master", snap_file, ctx)
        res1.success?.should be_false
        res1.error.not_nil!.should contain("forged run metadata: producer run_id 888 != sidecar run_id 777")

        # 2. Ref forged (not refs/heads/master)
        snap_branch = Iyi::Stale::Snapshot.new(
          namespace: "master",
          target: "x86_64-linux-gnu",
          repository: "github.com/iyilang/iyi",
          workflow: ".github/workflows/iyi.yml",
          ref: "refs/heads/feature-branch",
          producer: {"run_id" => JSON::Any.new(888_i64)}
        )
        File.write(snap_file, snap_branch.to_json)
        actual_sha2 = Iyi::Stale::Snapshot.hash_file_sha256(snap_file)
        sidecar_forged_ref = {
          "sha256"     => actual_sha2,
          "run_id"     => 888_i64,
          "repository" => "github.com/iyilang/iyi",
          "workflow"   => ".github/workflows/iyi.yml",
          "ref"        => "refs/heads/feature-branch",
        }
        File.write(sidecar_file, sidecar_forged_ref.to_json)
        res2 = Iyi::Stale::Snapshot.import(store, "master", snap_file, ctx)
        res2.success?.should be_false
        res2.error.not_nil!.should contain("untrusted ref for master namespace")

        # 3. Repository forged (not iyilang/iyi)
        snap_repo = Iyi::Stale::Snapshot.new(
          namespace: "master",
          target: "x86_64-linux-gnu",
          repository: "github.com/attacker/iyi",
          workflow: ".github/workflows/iyi.yml",
          ref: "refs/heads/master",
          producer: {"run_id" => JSON::Any.new(888_i64)}
        )
        File.write(snap_file, snap_repo.to_json)
        actual_sha3 = Iyi::Stale::Snapshot.hash_file_sha256(snap_file)
        sidecar_forged_repo = {
          "sha256"     => actual_sha3,
          "run_id"     => 888_i64,
          "repository" => "github.com/attacker/iyi",
          "workflow"   => ".github/workflows/iyi.yml",
          "ref"        => "refs/heads/master",
        }
        File.write(sidecar_file, sidecar_forged_repo.to_json)
        res3 = Iyi::Stale::Snapshot.import(store, "master", snap_file, ctx)
        res3.success?.should be_false
        res3.error.not_nil!.should contain("untrusted repository for master namespace")
      end
    end

    it "accepts and imports master snapshot with valid matching provenance sidecar" do
      with_tempfile("snap_valid_master") do |cache_root|
        Dir.mkdir_p(cache_root)
        store = Iyi::Stale::Store.new(cache_root)
        ctx = Iyi::Stale::ImportContext.new(target: "x86_64-linux-gnu")

        t1 = make_test_id("master_test.iyi")
        r1 = make_receipt(t1, mode: "portable")

        snap_file = File.join(cache_root, "master_snap.json")
        snap = Iyi::Stale::Snapshot.new(
          namespace: "master",
          target: "x86_64-linux-gnu",
          repository: "github.com/iyilang/iyi",
          workflow: ".github/workflows/iyi.yml",
          ref: "refs/heads/master",
          producer: {"run_id" => JSON::Any.new(9999_i64)},
          records: [r1]
        )
        File.write(snap_file, snap.to_json)
        actual_sha = Iyi::Stale::Snapshot.hash_file_sha256(snap_file)

        sidecar_file = "#{snap_file}.provenance.json"
        sidecar = {
          "sha256"     => actual_sha,
          "run_id"     => 9999_i64,
          "repository" => "github.com/iyilang/iyi",
          "workflow"   => ".github/workflows/iyi.yml",
          "ref"        => "refs/heads/master",
        }
        File.write(sidecar_file, sidecar.to_json)

        res = Iyi::Stale::Snapshot.import(store, "master", snap_file, ctx)
        res.success?.should be_true
        res.records_count.should eq(1)

        # Verified stored in imported/
        expected_path = store.imported_path("master")
        File.file?(expected_path).should be_true
        store.candidates(t1, "x86_64-linux-gnu").size.should eq(1)
      end
    end
  end

  describe "run:<id> namespace authorization" do
    it "refuses run:<id> snapshot when GITHUB_RUN_ID does not match" do
      with_tempfile("snap_run_mismatch") do |cache_root|
        Dir.mkdir_p(cache_root)
        store = Iyi::Stale::Store.new(cache_root)
        # ctx run_id is 12345, but namespace and producer say 99999
        ctx = Iyi::Stale::ImportContext.new(target: "x86_64-linux-gnu", current_run_id: 12345_i64)

        t1 = make_test_id("run_test.iyi")
        r1 = make_receipt(t1, mode: "portable")

        snap_file = File.join(cache_root, "run_snap.json")
        snap = Iyi::Stale::Snapshot.new(
          namespace: "run:99999",
          target: "x86_64-linux-gnu",
          producer: {"run_id" => JSON::Any.new(99999_i64)},
          records: [r1]
        )
        File.write(snap_file, snap.to_json)

        res = Iyi::Stale::Snapshot.import(store, "run:99999", snap_file, ctx)
        res.success?.should be_false
        res.error.not_nil!.should contain("GITHUB_RUN_ID does not match producer run")
      end
    end

    it "accepts run:<id> snapshot when GITHUB_RUN_ID matches" do
      with_tempfile("snap_run_match") do |cache_root|
        Dir.mkdir_p(cache_root)
        store = Iyi::Stale::Store.new(cache_root)
        ctx = Iyi::Stale::ImportContext.new(target: "x86_64-linux-gnu", current_run_id: 88888_i64)

        t1 = make_test_id("run_test.iyi")
        r1 = make_receipt(t1, mode: "portable")

        snap_file = File.join(cache_root, "run_snap.json")
        snap = Iyi::Stale::Snapshot.new(
          namespace: "run:88888",
          target: "x86_64-linux-gnu",
          producer: {"run_id" => JSON::Any.new(88888_i64)},
          records: [r1]
        )
        File.write(snap_file, snap.to_json)

        res = Iyi::Stale::Snapshot.import(store, "run:88888", snap_file, ctx)
        res.success?.should be_true
        res.records_count.should eq(1)
        store.candidates(t1, "x86_64-linux-gnu").size.should eq(1)
      end
    end
  end
end
