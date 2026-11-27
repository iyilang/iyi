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
      Dir.exists?(store.fast_dir).should be_true

      # Verify layout paths match §2.8
      store.root_dir.should eq(File.join(cache_root, "tests-v1"))
      store.records_dir.should eq(File.join(cache_root, "tests-v1", "records"))
      store.masks_dir.should eq(File.join(cache_root, "tests-v1", "masks"))
      store.markers_dir.should eq(File.join(cache_root, "tests-v1", "markers"))
      store.imported_dir.should eq(File.join(cache_root, "tests-v1", "imported"))
      store.fast_dir.should eq(File.join(cache_root, "tests-v1", "fast"))
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

  it "keeps each test's receipts in its own directory and reads them back" do
    with_tempfile("store_per_test") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!
      target = "x86_64-linux-gnu"

      test_a = make_test_id("per_a_test.iyi")
      test_b = make_test_id("per_b_test.iyi")
      rec_a = make_receipt(test_a, callpath: "1" * 64, target: target)
      rec_b = make_receipt(test_b, callpath: "2" * 64, target: target)
      store.record(rec_a)
      store.record(rec_b)

      store.test_dir(test_a).should eq(File.join(store.records_dir, Iyi::Stale.hex(Iyi::Stale::Store.d_test_id(test_a))))
      path_a = store.record_path(test_a, rec_a.signature)
      File.file?(path_a).should be_true
      File.file?(store.record_path(test_b, rec_b.signature)).should be_true
      File.file?(store.record_path(test_b, rec_a.signature)).should be_false

      loaded = Iyi::Stale::Receipt.from_json(File.read(path_a))
      loaded.to_json.should eq(File.read(path_a))
      loaded.seq.should eq(rec_a.seq)
      loaded.signature.should eq(rec_a.signature)

      store.candidates(test_a, target, imported: false).map(&.signature).should eq([rec_a.signature])
      store.candidates(test_b, target, imported: false).map(&.signature).should eq([rec_b.signature])
    end
  end

  it "records a receipt under records/<hex D(test)>/<signature>.json" do
    with_tempfile("store_record") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!

      test = make_test_id("unit/sample_test.iyi")
      rec = make_receipt(test)
      store.record(rec)

      rec.seq.should eq(1_u64)
      rec.signature.size.should eq(64)

      digest_dir = Iyi::Stale.hex(Iyi::Stale::Store.d_test_id(test))
      expected_path = File.join(store.records_dir, digest_dir, "#{rec.signature}.json")
      expected_path.should eq(store.record_path(test, rec.signature))
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
      path = store.record_path(test, rec.signature)
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

      # Imported snapshot from namespace "master"
      rec_alpha = make_receipt(test, callpath: "a" * 64, target: target, mode: "portable")
      snap_alpha = Iyi::Stale::Snapshot.new(
        namespace: "master",
        target: target,
        records: [rec_alpha]
      )
      store.import_snapshot(snap_alpha)

      # Imported snapshot from namespace "run:7"
      rec_beta = make_receipt(test, callpath: "b" * 64, target: target, mode: "portable")
      snap_beta = Iyi::Stale::Snapshot.new(
        namespace: "run:7",
        target: target,
        records: [rec_beta]
      )
      store.import_snapshot(snap_beta)

      # Imported snapshot for DIFFERENT target (must NOT be a candidate)
      rec_darwin = make_receipt(test, callpath: "d" * 64, target: "aarch64-darwin", mode: "portable")
      snap_darwin = Iyi::Stale::Snapshot.new(
        namespace: "run:8",
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

      # 3. Imported master
      candidates[2].signature.should eq(rec_alpha.signature)
      candidates[2].portable?.should be_true

      # 4. Imported run:7
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
      reloaded_local = Iyi::Stale::Receipt.from_json(File.read(store.record_path(test, local_receipt.signature)))
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

      path = store.record_path(test, rec.signature)
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

      File.file?(store.record_path(test_current, rec_current.signature)).should be_true
      File.file?(store.record_path(test_old, rec_old.signature)).should be_true
      File.file?(store.mask_path(rec_old.signature)).should be_true
      File.file?(store.marker_path(test_old)).should be_true

      # Prune outdated toolchains
      pruned = store.prune_outdated_toolchains(current_toolchain: current_tc)
      pruned.should eq(1)

      # Current toolchain record is kept
      File.file?(store.record_path(test_current, rec_current.signature)).should be_true

      # Old toolchain record is deleted
      File.file?(store.record_path(test_old, rec_old.signature)).should be_false

      # Masks and markers are NEVER deleted by toolchain pruning
      File.file?(store.mask_path(rec_old.signature)).should be_true
      File.file?(store.marker_path(test_old)).should be_true
    end
  end

  it "a lookup for one test never reads another test's directory" do
    with_tempfile("store_isolated_dir") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!
      target = "x86_64-linux-gnu"
      test_x = make_test_id("isolated_x_test.iyi")
      test_y = make_test_id("isolated_y_test.iyi")

      rec_x = make_receipt(test_x, callpath: "1" * 64, target: target)
      store.record(rec_x)
      rec_y = make_receipt(test_y, callpath: "2" * 64, target: target)
      store.record(rec_y)

      # Corrupt Y's only receipt. Looking up X would have found and replaced it
      # when lookups read every directory.
      y_path = store.record_path(test_y, rec_y.signature)
      corrupt = "{\"version\": 1, \"test\": {\"root\": \"src\", \"path\": \"isolated_y_test.iyi\"}, \"corrupt\": true"
      File.write(y_path, corrupt)

      store.candidates(test_x, target).map(&.signature).should eq([rec_x.signature])
      store.blockers(test_x).size.should eq(0)
      store.has_marker?(test_x).should be_false
      File.read(y_path).should eq(corrupt)

      store.revoke(test_x) { |_| true }.should eq({1, 0})
      File.read(y_path).should eq(corrupt)

      # Y's own lookup still meets its corrupt record and marks Y
      store.candidates(test_y, target).size.should eq(0)
      store.has_marker?(test_y).should be_true
    end
  end

  it "ignores old two-character record directories and prunes them" do
    with_tempfile("store_old_layout") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!
      target = "x86_64-linux-gnu"
      test = make_test_id("old_layout_test.iyi")
      tc = "1" * 64

      # A receipt written in the old layout, under records/<first two hex of its signature>/
      old_rec = make_receipt(test, toolchain: tc, callpath: "7" * 64, target: target)
      old_dir = File.join(store.records_dir, old_rec.signature[0..1])
      Dir.mkdir_p(old_dir)
      old_file = File.join(old_dir, "#{old_rec.signature}.json")
      File.write(old_file, old_rec.to_json)

      store.candidates(test, target).size.should eq(0)
      File.file?(old_file).should be_true

      new_rec = make_receipt(test, toolchain: tc, callpath: "8" * 64, target: target)
      store.record(new_rec)
      store.candidates(test, target, imported: false).map(&.signature).should eq([new_rec.signature])

      store.prune_outdated_toolchains(current_toolchain: tc).should eq(1)
      Dir.exists?(old_dir).should be_false
      File.file?(store.record_path(test, new_rec.signature)).should be_true
    end
  end

  it "candidates with imported: false returns local passes and reads no snapshot" do
    with_tempfile("store_local_only") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!
      target = "x86_64-linux-gnu"
      test = make_test_id("local_only_test.iyi")

      local = make_receipt(test, callpath: "1" * 64, target: target)
      store.record(local)
      imported = make_receipt(test, callpath: "a" * 64, target: target, mode: "portable")
      store.import_snapshot(Iyi::Stale::Snapshot.new(namespace: "master", target: target, records: [imported]))

      store.candidates(test, target, imported: false).map(&.signature).should eq([local.signature])
      store.imported_parses.should eq(0)

      store.candidates(test, target).size.should eq(2)
      store.imported_parses.should eq(1)
    end
  end

  it "parses each imported snapshot once per store and re-reads it when its file changes" do
    with_tempfile("store_imported_index") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!
      target = "x86_64-linux-gnu"
      test = make_test_id("indexed_test.iyi")
      other = make_test_id("indexed_other.iyi")

      first = make_receipt(test, callpath: "a" * 64, target: target, mode: "portable")
      store.import_snapshot(Iyi::Stale::Snapshot.new(namespace: "master", target: target, records: [first]))

      3.times { store.candidates(other, target).size.should eq(0) }
      3.times { store.candidates(test, target).map(&.signature).should eq([first.signature]) }
      store.imported_parses.should eq(1)

      # Another process replaces the file. Its size and mtime change, so the next
      # lookup parses the new content once and serves it from the index after that.
      second = make_receipt(test, callpath: "b" * 64, target: target, mode: "portable")
      extra = make_receipt(other, callpath: "c" * 64, target: target, mode: "portable")
      replaced = Iyi::Stale::Snapshot.new(namespace: "master", target: target, records: [second, extra])
      Iyi::Stale::Store.atomic_write(store.imported_path("master"), replaced.to_json)

      store.candidates(test, target).map(&.signature).should eq([second.signature])
      store.candidates(test, target).map(&.signature).should eq([second.signature])
      store.imported_parses.should eq(2)
    end
  end

  it "forgets a replaced or missing snapshot even when its stamp is reused" do
    with_tempfile("store_imported_invalidation") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!
      target = "x86_64-linux-gnu"
      test = make_test_id("invalidation_test.iyi")
      first = make_receipt(test, callpath: "a" * 64, target: target, mode: "portable")
      second = make_receipt(test, callpath: "b" * 64, target: target, mode: "portable")
      store.import_snapshot(Iyi::Stale::Snapshot.new(namespace: "master", target: target, records: [first]))
      store.candidates(test, target).map(&.signature).should eq([first.signature])

      path = store.imported_path("master")
      stamp = File.info(path)
      store.import_snapshot(Iyi::Stale::Snapshot.new(namespace: "master", target: target, records: [second]))
      File.utime(stamp.modification_time, stamp.modification_time, path)
      File.info(path).size.should eq(stamp.size)
      File.info(path).modification_time.should eq(stamp.modification_time)
      store.candidates(test, target).map(&.signature).should eq([second.signature])
      store.imported_parses.should eq(2)

      contents = File.read(path)
      File.delete(path)
      store.candidates(test, target).should be_empty
      File.write(path, contents)
      File.utime(stamp.modification_time, stamp.modification_time, path)
      store.candidates(test, target).map(&.signature).should eq([second.signature])
      store.imported_parses.should eq(3)
    end
  end

  it "parses an imported snapshot once when concurrent lookups share it" do
    with_tempfile("store_imported_concurrent") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!
      target = "x86_64-linux-gnu"
      test = make_test_id("concurrent_test.iyi")
      receipt = make_receipt(test, callpath: "a" * 64, target: target, mode: "portable")
      store.import_snapshot(Iyi::Stale::Snapshot.new(namespace: "master", target: target, records: [receipt]))

      ready = Channel(Nil).new
      start = Channel(Nil).new
      results = Channel(Array(String) | Exception).new
      16.times do
        spawn do
          ready.send(nil)
          start.receive
          begin
            results.send(store.candidates(test, target).map(&.signature))
          rescue ex
            results.send(ex)
          end
        end
      end
      16.times { ready.receive }
      16.times { start.send(nil) }
      16.times { results.receive.should eq([receipt.signature]) }
      store.imported_parses.should eq(1)
    end
  end

  it "F1: names no mask or record by anything but a signature" do
    with_tempfile("store_f1_names") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      test = make_test_id("f1_names_test.iyi")
      ["../../../../.bash_aliases", "a" * 63, "A" * 64, ""].each do |bad|
        expect_raises(ArgumentError, "not a receipt signature") { store.mask_path(bad) }
        expect_raises(ArgumentError, "not a receipt signature") { store.record_path(test, bad) }
      end
      store.mask_path("a" * 64).should eq(File.join(store.masks_dir, "a" * 64))
    end
  end

  it "F1: never reads a stored snapshot whose records fail the import checks" do
    with_tempfile("store_f1_stored") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!
      target = "x86_64-linux-gnu"
      test = make_test_id("f1_stored_test.iyi")
      good = make_receipt(test, callpath: "a" * 64, target: target, mode: "portable")
      forged = make_receipt(test, callpath: "b" * 64, target: target, mode: "portable")
      forged.signature = "../../../../.bash_aliases"
      # As an import from before the checks would have left it.
      store.import_snapshot(Iyi::Stale::Snapshot.new(namespace: "master", target: target, records: [good, forged]))

      store.candidates(test, target).should be_empty
      store.revoke(test) { |_| true }.should eq({0, 1})
      Dir.children(store.masks_dir).should eq([good.signature])
      File.exists?(File.join(cache_root, ".bash_aliases")).should be_false
    end
  end

  it "F2: a revocation that cannot rewrite a receipt leaves the test's marker" do
    with_tempfile("store_f2_marker") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!
      target = "x86_64-linux-gnu"
      test = make_test_id("f2_marker_test.iyi")
      rec = make_receipt(test, target: target)
      store.record(rec)
      store.write_fast(test, "{}")

      store.revoke(test) { |_| raise "the check failed" }
      store.has_marker?(test).should be_true
      File.read(store.marker_path(test)).should contain("revocation failed")
      File.exists?(store.fast_path(test)).should be_false
      store.candidates(test, target).should be_empty
    end
  end

  {% unless flag?(:win32) %}
    it "F2: a receipt the store cannot rewrite is not served, and a marker it cannot write stops the run" do
      with_tempfile("store_f2_write") do |cache_root|
        store = Iyi::Stale::Store.new(cache_root)
        store.ensure_directories!
        target = "x86_64-linux-gnu"
        test = make_test_id("f2_write_test.iyi")
        rec = make_receipt(test, target: target)
        store.record(rec)
        if LibC.getuid == 0
          pending! "root writes into a directory without write permission"
        end
        File.chmod(store.test_dir(test), 0o500)
        begin
          store.revoke(test) { |_| true }.should eq({0, 0})
          store.has_marker?(test).should be_true
          store.candidates(test, target).should be_empty
        ensure
          File.chmod(store.test_dir(test), 0o700)
        end

        other = make_test_id("f2_nomarker_test.iyi")
        store.record(make_receipt(other, target: target))
        FileUtils.rm_r(store.markers_dir)
        File.write(store.markers_dir, "a file where the markers directory was")
        File.chmod(store.test_dir(other), 0o500)
        begin
          expect_raises(Iyi::Stale::StoreError, "nor write its contradiction marker") do
            store.revoke(other) { |_| true }
          end
        ensure
          File.chmod(store.test_dir(other), 0o700)
        end
      end
    end
  {% end %}

  it "F2: a marker that cannot be written stops the run" do
    with_tempfile("store_f2_abort") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!
      test = make_test_id("f2_abort_test.iyi")
      store.record(make_receipt(test))
      FileUtils.rm_r(store.markers_dir)
      File.write(store.markers_dir, "a file where the markers directory was")
      expect_raises(Iyi::Stale::StoreError, "nor write its contradiction marker") do
        store.revoke(test) { |_| raise "the check failed" }
      end
    end
  end

  it "F3: lists and clears imports, and never reads one under another namespace" do
    with_tempfile("store_f3_imports") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!
      target = "x86_64-linux-gnu"
      test = make_test_id("f3_imports_test.iyi")
      master = make_receipt(test, callpath: "a" * 64, target: target, mode: "portable")
      other = make_receipt(test, callpath: "b" * 64, target: target, mode: "portable")
      store.import_snapshot(Iyi::Stale::Snapshot.new(namespace: "master", target: target, records: [master]))
      # As an import from before namespaces were checked would have left it.
      store.import_snapshot(Iyi::Stale::Snapshot.new(namespace: "any", target: target, records: [other]))

      store.candidates(test, target).map(&.signature).should eq([master.signature])
      listed = store.imports.map { |_, file| {file.namespace, file.records, file.usable?} }.sort_by(&.[0])
      listed.should eq([{"any", 1, false}, {"master", 1, true}])

      store.clear_imports.should eq(2)
      store.imports.should be_empty
      store.candidates(test, target).should be_empty
    end
  end

  {% unless flag?(:win32) %}
    it "F4: keeps the store to its user: directories 0700, files 0600" do
      with_tempfile("store_f4_modes") do |cache_root|
        Dir.mkdir_p(File.join(cache_root, "tests-v1"), 0o755)
        File.chmod(File.join(cache_root, "tests-v1"), 0o755)
        store = Iyi::Stale::Store.new(cache_root)
        store.ensure_directories!
        test = make_test_id("f4_modes_test.iyi")
        rec = make_receipt(test)
        store.record(rec)
        store.write_fast(test, "{}")
        (File.info(store.root_dir).permissions.value & 0o777).should eq(0o700)
        [store.records_dir, store.masks_dir, store.markers_dir, store.imported_dir, store.fast_dir, store.test_dir(test)].each do |dir|
          (File.info(dir).permissions.value & 0o077).should eq(0)
        end
        [store.record_path(test, rec.signature), store.fast_path(test), store.seq_path, store.lock_path].each do |file|
          (File.info(file).permissions.value & 0o777).should eq(0o600)
        end
      end
    end
  {% end %}

  it "F6: blockers pass over names the store never writes and name a mask that does not parse" do
    with_tempfile("store_f6_blockers") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!
      test = make_test_id("f6_blockers_test.iyi")
      contradicted = make_receipt(test, callpath: "1" * 64, contradicted: true)
      store.record(contradicted)
      # What an interrupted atomic write leaves beside a mask and a record.
      File.write(File.join(store.masks_dir, "#{"a" * 64}.tmp.123.abcd"), "{\"te")
      File.write(store.record_path(test, contradicted.signature) + ".tmp.123.abcd", "{\"te")
      File.write(File.join(store.test_dir(test), "notes.json"), "{\"te")

      store.blockers(test).map(&.signature).should eq([contradicted.signature])
      store.has_marker?(test).should be_false

      corrupt = File.join(store.masks_dir, "c" * 64)
      File.write(corrupt, "{\"te")
      ex = expect_raises(Iyi::Stale::StoreError) { store.blockers(test) }
      ex.message.not_nil!.should contain(corrupt)
      ex.message.not_nil!.should contain("delete this file to go on")
      File.exists?(corrupt).should be_true
    end
  end

  it "F6: a corrupt receipt among blockers gives way to the test's marker" do
    with_tempfile("store_f6_record") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      store.ensure_directories!
      test = make_test_id("f6_record_test.iyi")
      rec = make_receipt(test)
      store.record(rec)
      File.write(store.record_path(test, rec.signature), "{\"te")
      store.blockers(test).should be_empty
      store.has_marker?(test).should be_true
      File.exists?(store.record_path(test, rec.signature)).should be_false
    end
  end

  # On Windows the shared gate uses the native Crystal launcher and starts
  # both helper processes from Python; POSIX can run them directly.
  {% if flag?(:win32) %}
    it "survives two concurrent processes each recording 1,000 receipts (row 21)" do
      # `bash` alone finds System32's WSL launcher or the store's alias first
      # on a runner with no distribution installed (the alias even refuses a
      # `stat`); the gate is written for the Git for Windows shell, so take
      # the first real bash.exe on PATH, then where Git for Windows installs it.
      directories = ENV["PATH"].split(';')
      {"ProgramFiles", "ProgramW6432"}.each do |variable|
        root = ENV[variable]?
        next unless root
        directories << File.join(root, "Git", "bin")
        directories << File.join(root, "Git", "usr", "bin")
      end
      bash = directories.compact_map do |directory|
        candidate = File.join(directory, "bash.exe")
        lowered = candidate.downcase
        next if lowered.includes?("\\system32\\") || lowered.includes?("\\windowsapps\\")
        candidate if (File.file?(candidate) rescue false)
      end.first?
      bash.should_not be_nil
      Process.run(bash.not_nil!, ["bench/stale_store_concurrency.sh"],
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).success?.should be_true
    end
  {% else %}
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
  {% end %}
end
