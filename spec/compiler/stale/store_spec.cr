require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/receipt"
require "compiler/iyi/stale/store"
require "compiler/iyi/stale/machine_key"

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

  Iyi::Stale::Receipt.new(
    test: test,
    build: b,
    profile: prof,
    trace: tr,
    mode: mode,
    newest: newest,
    seq: seq,
    contradicted: contradicted
  )
end

describe "Iyi::Stale S6a: Store and Receipts" do
  it "creates the §2.8 directory layout under <cache root>/tests-v1/" do
    with_tempfile("store_layout") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!

      Dir.exists?(store.root_dir).should be_true
      Dir.exists?(store.records_dir).should be_true
      Dir.exists?(store.masks_dir).should be_true
      Dir.exists?(store.markers_dir).should be_true
      Dir.exists?(store.imported_dir).should be_true

      # Verify layout paths match §2.8
      store.root_dir.should eq(File.join(cache_root, "tests-v1"))
      store.records_dir.should eq(File.join(cache_root, "tests-v1", "records"))
      store.masks_dir.should eq(File.join(cache_root, "tests-v1", "masks"))
      store.markers_dir.should eq(File.join(cache_root, "tests-v1", "markers"))
      store.imported_dir.should eq(File.join(cache_root, "tests-v1", "imported"))
      store.lock_path.should eq(File.join(cache_root, "tests-v1", "lock"))
      store.seq_path.should eq(File.join(cache_root, "tests-v1", "seq"))
    end
  end

  it "writes atomically via temp file, fsync, and rename" do
    with_tempfile("store_atomic") do |cache_root|
      target_file = File.join(cache_root, "sub", "test.json")
      Iyi::Stale::Store.atomic_write(target_file, "{\"hello\": \"world\"}\n")

      File.file?(target_file).should be_true
      File.read(target_file).should eq("{\"hello\": \"world\"}\n")

      # Overwrite existing atomically
      Iyi::Stale::Store.atomic_write(target_file, "{\"hello\": \"updated\"}\n")
      File.read(target_file).should eq("{\"hello\": \"updated\"}\n")
    end
  end

  it "advances seq monotonically under flock_exclusive lock" do
    with_tempfile("store_seq") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!

      store.current_seq.should eq(0_u64)
      s1 = store.next_seq
      s1.should eq(1_u64)
      store.current_seq.should eq(1_u64)

      s2 = store.next_seq
      s2.should eq(2_u64)
      store.current_seq.should eq(2_u64)

      File.read(store.seq_path).strip.should eq("2")
    end
  end

  it "records a receipt and stores it under records/<ab>/<signature>.json" do
    with_tempfile("store_record") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!

      test = make_test_id("unit/sample_test.iyi")
      rec = make_receipt(test)
      store.record(rec)

      rec.seq.should eq(1_u64)
      rec.signature.size.should eq(64)

      prefix = rec.signature[0..1]
      expected_path = File.join(store.records_dir, prefix, "#{rec.signature}.json")
      File.file?(expected_path).should be_true

      loaded = Iyi::Stale::Receipt.from_json(File.read(expected_path))
      loaded.signature.should eq(rec.signature)
      loaded.seq.should eq(1_u64)
      loaded.test.path.should eq("unit/sample_test.iyi")
      loaded.newest.should eq("pass")
      loaded.contradicted.should be_false
    end
  end

  it "preserves contradicted: true on read-modify-write (sticky contradiction)" do
    with_tempfile("store_sticky") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!

      test = make_test_id("sticky_test.iyi")
      rec = make_receipt(test, contradicted: false)
      store.record(rec)

      # Mark contradicted in store
      path = store.record_path(rec.signature)
      loaded = Iyi::Stale::Receipt.from_json(File.read(path))
      loaded.contradicted = true
      Iyi::Stale::Store.atomic_write(path, loaded.to_json)

      # Record new pass with identical signature (contradicted = false)
      new_pass = make_receipt(test, contradicted: false)
      new_pass.signature.should eq(rec.signature)
      store.record(new_pass)

      # The read-modify-write must keep contradicted: true!
      reloaded = Iyi::Stale::Receipt.from_json(File.read(path))
      reloaded.contradicted.should be_true
      new_pass.contradicted.should be_true
    end
  end

  it "returns candidates: local passes newest first, then unmasked imported receipts by namespace" do
    with_tempfile("store_candidates") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!

      test = make_test_id("search_test.iyi")
      target = "x86_64-linux-gnu"

      # Local pass 1 (seq 1)
      rec1 = make_receipt(test, callpath: "1" * 64, target: target)
      store.record(rec1)

      # Local pass 2 (seq 2, newer)
      rec2 = make_receipt(test, callpath: "2" * 64, target: target)
      store.record(rec2)

      # Local failing test (must NOT be a candidate)
      fail_rec = make_receipt(test, callpath: "3" * 64, target: target, newest: "fail")
      store.record(fail_rec)

      # Local contradicted pass (must NOT be a candidate)
      contra_rec = make_receipt(test, callpath: "4" * 64, target: target, contradicted: true)
      store.record(contra_rec)

      # Imported snapshot from namespace "alpha"
      rec_alpha = make_receipt(test, callpath: "a" * 64, target: target, mode: "portable")
      snap_alpha = Iyi::Stale::Snapshot.new(
        namespace: "alpha",
        target: target,
        records: [rec_alpha]
      )
      store.import_snapshot(snap_alpha)

      # Imported snapshot from namespace "beta"
      rec_beta = make_receipt(test, callpath: "b" * 64, target: target, mode: "portable")
      snap_beta = Iyi::Stale::Snapshot.new(
        namespace: "beta",
        target: target,
        records: [rec_beta]
      )
      store.import_snapshot(snap_beta)

      # Imported snapshot for DIFFERENT target (must NOT be a candidate)
      rec_darwin = make_receipt(test, callpath: "d" * 64, target: "aarch64-darwin", mode: "portable")
      snap_darwin = Iyi::Stale::Snapshot.new(
        namespace: "darwin",
        target: "aarch64-darwin",
        records: [rec_darwin]
      )
      store.import_snapshot(snap_darwin)

      # Fetch candidates
      candidates = store.candidates(test, target)
      candidates.size.should eq(4)

      # 1. Local pass 2 (newest first, seq 4)
      candidates[0].signature.should eq(rec2.signature)
      candidates[0].local?.should be_true

      # 2. Local pass 1 (seq 1)
      candidates[1].signature.should eq(rec1.signature)
      candidates[1].local?.should be_true

      # 3. Imported alpha
      candidates[2].signature.should eq(rec_alpha.signature)
      candidates[2].portable?.should be_true

      # 4. Imported beta
      candidates[3].signature.should eq(rec_beta.signature)
      candidates[3].portable?.should be_true
    end
  end

  it "excludes masked imported receipts from candidates" do
    with_tempfile("store_mask_candidates") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!

      test = make_test_id("masked_test.iyi")
      target = "x86_64-linux-gnu"

      rec_imported = make_receipt(test, callpath: "5" * 64, target: target, mode: "portable")
      snap = Iyi::Stale::Snapshot.new(
        namespace: "master",
        target: target,
        records: [rec_imported]
      )
      store.import_snapshot(snap)

      # Before mask: candidate exists
      store.candidates(test, target).size.should eq(1)

      # Create mask for this imported receipt
      mask = Iyi::Stale::Mask.new(
        test: rec_imported.test,
        build: rec_imported.build,
        profile: rec_imported.profile,
        trace: rec_imported.trace,
        signature: rec_imported.signature
      )
      Iyi::Stale::Store.atomic_write(store.mask_path(rec_imported.signature), mask.to_json)

      # After mask: imported receipt is masked -> candidates is empty!
      store.is_masked?(rec_imported.signature).should be_true
      store.candidates(test, target).size.should eq(0)
    end
  end

  it "returns blockers for a test: local contradicted receipts and masks" do
    with_tempfile("store_blockers") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!

      test = make_test_id("block_test.iyi")

      # Local contradicted receipt
      local_contra = make_receipt(test, callpath: "1" * 64, contradicted: true)
      store.record(local_contra)

      # Local passing receipt (not a blocker)
      local_pass = make_receipt(test, callpath: "2" * 64, contradicted: false)
      store.record(local_pass)

      # Mask for an imported receipt
      imported = make_receipt(test, callpath: "3" * 64, mode: "portable")
      mask = Iyi::Stale::Mask.new(
        test: imported.test,
        build: imported.build,
        profile: imported.profile,
        trace: imported.trace,
        signature: imported.signature
      )
      Iyi::Stale::Store.atomic_write(store.mask_path(imported.signature), mask.to_json)

      blockers = store.blockers(test)
      blockers.size.should eq(2)

      local_blocker = blockers.find(&.local?).not_nil!
      local_blocker.signature.should eq(local_contra.signature)
      local_blocker.build.build.should eq(local_contra.build.build)
      local_blocker.contradicted.should be_true

      portable_blocker = blockers.find(&.portable?).not_nil!
      portable_blocker.signature.should eq(imported.signature)
      portable_blocker.build.build.should eq(imported.build.build)
      portable_blocker.contradicted.should be_true
    end
  end

  it "performs revocation-by-state across local HMAC vs portable plain digests (matching by state, not signature)" do
    with_tempfile("store_revoke_state") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!

      # Machine key for local HMAC
      machine_key = Iyi::Stale::MachineKey.load_or_create(cache_root)
      keyer_local = Iyi::Stale::Keyer.local(machine_key)
      keyer_portable = Iyi::Stale::Keyer.portable

      test = make_test_id("revocation_test.iyi")
      target = "x86_64-linux-gnu"

      # The underlying canonical plain state components
      plain_toolchain = "1" * 64
      plain_behavior = "2" * 64
      plain_callpath_digest = Iyi::Stale.parse_hex("3" * 64)
      plain_link_digest = Iyi::Stale.parse_hex("4" * 64)
      plain_cenv_digest = Iyi::Stale.parse_hex("5" * 64)

      # 1. Local receipt: Callpath, Link, Cenv are HMAC-keyed with machine_key
      local_callpath = Iyi::Stale.hex(keyer_local.k(plain_callpath_digest))
      local_link = Iyi::Stale.hex(keyer_local.k(plain_link_digest))
      local_cenv = Iyi::Stale.hex(keyer_local.k(plain_cenv_digest))

      local_receipt = make_receipt(
        test: test,
        toolchain: plain_toolchain,
        behavior: plain_behavior,
        callpath: local_callpath,
        link: local_link,
        cenv: local_cenv,
        target: target,
        mode: "local"
      )
      store.record(local_receipt)

      # 2. Imported snapshot receipt: Callpath, Link, Cenv are plain SHA-256 (no HMAC)
      portable_callpath = Iyi::Stale.hex(keyer_portable.k(plain_callpath_digest))
      portable_link = Iyi::Stale.hex(keyer_portable.k(plain_link_digest))
      portable_cenv = Iyi::Stale.hex(keyer_portable.k(plain_cenv_digest))

      portable_receipt = make_receipt(
        test: test,
        toolchain: plain_toolchain,
        behavior: plain_behavior,
        callpath: portable_callpath,
        link: portable_link,
        cenv: portable_cenv,
        target: target,
        mode: "portable"
      )

      snap = Iyi::Stale::Snapshot.new(
        namespace: "master",
        target: target,
        records: [portable_receipt]
      )
      store.import_snapshot(snap)

      # Verify that local and portable have DIFFERENT signatures due to HMAC vs plain!
      local_receipt.signature.should_not eq(portable_receipt.signature)
      local_receipt.build.build.should_not eq(portable_receipt.build.build)

      # Both start as candidates
      store.candidates(test, target).size.should eq(2)

      # Revoke by state: the runner passes a predicate matching the underlying state
      # For a local receipt: checks if receipt.build.callpath == HMAC(key, plain_callpath)
      # For an imported receipt: checks if receipt.build.callpath == plain_callpath
      local_revoked, imported_revoked = store.revoke(test) do |r|
        if r.local?
          r.build.callpath == local_callpath
        else
          r.build.callpath == portable_callpath
        end
      end

      local_revoked.should eq(1)
      imported_revoked.should eq(1)

      # Verify local receipt is marked contradicted
      reloaded_local = Iyi::Stale::Receipt.from_json(File.read(store.record_path(local_receipt.signature)))
      reloaded_local.contradicted.should be_true

      # Verify mask was written for portable receipt
      mask_file = store.mask_path(portable_receipt.signature)
      File.file?(mask_file).should be_true
      mask = Iyi::Stale::Mask.from_json(File.read(mask_file))
      mask.test.path.should eq(test.path)
      mask.build.build.should eq(portable_receipt.build.build)

      # Candidates is now 0 (both are revoked/masked)
      store.candidates(test, target).size.should eq(0)

      # Blockers contains both the local contradicted receipt and the mask
      blockers = store.blockers(test)
      blockers.size.should eq(2)
      blockers.any? { |b| b.local? && b.build.build == local_receipt.build.build }.should be_true
      blockers.any? { |b| b.portable? && b.build.build == portable_receipt.build.build }.should be_true
    end
  end

  it "persistent contradiction marker causes candidates to miss until clear_marker" do
    with_tempfile("store_marker") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!

      test = make_test_id("marker_test.iyi")
      target = "x86_64-linux-gnu"
      rec = make_receipt(test, target: target)
      store.record(rec)

      # Candidate is present
      store.candidates(test, target).size.should eq(1)
      store.has_marker?(test).should be_false

      # Write persistent contradiction marker
      store.write_marker(test, reason: "corrupt_record")
      store.has_marker?(test).should be_true

      marker_file = store.marker_path(test)
      File.file?(marker_file).should be_true
      marker_hex = File.basename(marker_file)
      expected_hex = Iyi::Stale.hex(Iyi::Stale::Store.d_test_id(test))
      marker_hex.should eq(expected_hex)

      # While marked: candidates returns empty (miss)!
      store.candidates(test, target).size.should eq(0)

      # Clear marker (called on a --fresh pass with complete trace)
      cleared = store.clear_marker(test)
      cleared.should be_true
      store.has_marker?(test).should be_false
      File.file?(marker_file).should be_false

      # Candidate is now returned again!
      store.candidates(test, target).size.should eq(1)
    end
  end

  it "replaces corrupt records under lock with a persistent contradiction marker" do
    with_tempfile("store_corrupt") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!

      test = make_test_id("corrupt_test.iyi")
      target = "x86_64-linux-gnu"

      rec = make_receipt(test, target: target)
      store.record(rec)

      path = store.record_path(rec.signature)
      File.file?(path).should be_true

      # Corrupt the file with truncated JSON that still carries the path
      corrupt_content = "{\"version\": 1, \"test\": {\"root\": \"src\", \"path\": \"corrupt_test.iyi\"}, \"corrupt\": true"
      File.write(path, corrupt_content)

      # Accessing candidates encounters corrupt file
      # It must replace the corrupt file under lock with a persistent marker!
      candidates = store.candidates(test, target)
      candidates.size.should eq(0)

      # Corrupt file is deleted
      File.file?(path).should be_false

      # Persistent contradiction marker is created
      store.has_marker?(test).should be_true
      marker_file = store.marker_path(test)
      File.file?(marker_file).should be_true
    end
  end

  it "prunes receipts from outdated toolchains while keeping current toolchain, masks, and markers" do
    with_tempfile("store_prune") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!

      current_tc = "1" * 64
      old_tc = "9" * 64

      test_current = make_test_id("current.iyi")
      test_old = make_test_id("old.iyi")

      rec_current = make_receipt(test_current, toolchain: current_tc)
      rec_old = make_receipt(test_old, toolchain: old_tc)

      store.record(rec_current)
      store.record(rec_old)

      # Add a mask and a marker
      mask = Iyi::Stale::Mask.new(
        test: test_old,
        build: rec_old.build,
        profile: rec_old.profile,
        trace: rec_old.trace,
        signature: rec_old.signature
      )
      Iyi::Stale::Store.atomic_write(store.mask_path(rec_old.signature), mask.to_json)
      store.write_marker(test_old)

      File.file?(store.record_path(rec_current.signature)).should be_true
      File.file?(store.record_path(rec_old.signature)).should be_true
      File.file?(store.mask_path(rec_old.signature)).should be_true
      File.file?(store.marker_path(test_old)).should be_true

      # Prune outdated toolchains
      pruned = store.prune_outdated_toolchains(current_toolchain: current_tc)
      pruned.should eq(1)

      # Current toolchain record is kept
      File.file?(store.record_path(rec_current.signature)).should be_true

      # Old toolchain record is deleted
      File.file?(store.record_path(rec_old.signature)).should be_false

      # Masks and markers are NEVER deleted by toolchain pruning
      File.file?(store.mask_path(rec_old.signature)).should be_true
      File.file?(store.marker_path(test_old)).should be_true
    end
  end

  it "survives two concurrent processes each recording 1,000 receipts (row 21)" do
    with_tempfile("store_concurrency") do |cache_root|
      bin_path = ".build/stale_store_concurrency"
      unless File.file?(bin_path)
        build_status = Process.run("./bin/crystal", ["build", "-o", bin_path, "bench/stale_store_concurrency.cr"])
        build_status.success?.should be_true
      end

      # Run 2 processes in parallel
      p1 = Process.new(bin_path, ["run", cache_root, "1", "1000"])
      p2 = Process.new(bin_path, ["run", cache_root, "2", "1000"])

      s1 = p1.wait
      s2 = p2.wait

      s1.success?.should be_true
      s2.success?.should be_true

      # Verify all 2,000 files parse cleanly and seq is 2,000
      verify_status = Process.run(bin_path, ["verify", cache_root, "2000"])
      verify_status.success?.should be_true
    end
  end
end
