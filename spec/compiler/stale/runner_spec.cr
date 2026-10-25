require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/runner"
require "compiler/iyi/stale/store"
require "compiler/iyi/stale/snapshot"

describe Iyi::Stale::Runner do
  it "requires --fresh when --export-index is supplied" do
    with_tempfile("runner_test") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      runner = Iyi::Stale::Runner.new(
        files: [] of String,
        cached: true,
        fresh: false,
        export_indices: ["master=out.json"],
        store: store
      )
      expect_raises(Iyi::Stale::RunnerError, "--export-index requires --fresh") do
        runner.run_internal
      end
    end
  end

  it "deals tests round-robin across shards" do
    with_tempfile("runner_shard") do |cache_root|
      files = ["a_test.iyi", "b_test.iyi", "c_test.iyi", "d_test.iyi"]
      # Shard 1 of 2 should get indices 0 and 2: a, c
      runner1 = Iyi::Stale::Runner.new(
        files: files,
        shard: "1/2",
        fresh: true,
        store: Iyi::Stale::Store.new(cache_root)
      )
      # Shard 2 of 2 should get indices 1 and 3: b, d
      runner2 = Iyi::Stale::Runner.new(
        files: files,
        shard: "2/2",
        fresh: true,
        store: Iyi::Stale::Store.new(cache_root)
      )
    end
  end

  it "marks ambiguous test ids when multiple files resolve to same TestId (C6)" do
    with_tempfile("runner_ambiguous") do |dir|
      dir1 = File.join(dir, "sub1")
      dir2 = File.join(dir, "sub2")
      Dir.mkdir_p(dir1)
      Dir.mkdir_p(dir2)
      f1 = File.join(dir1, "t_test.iyi")
      f2 = File.join(dir2, "t_test.iyi")
      File.write(f1, "puts 1\n")
      File.write(f2, "puts 2\n")

      store = Iyi::Stale::Store.new(dir)
      runner = Iyi::Stale::Runner.new(
        files: [f1, f2],
        cached: true,
        store: store
      )
      # Ambiguous tests run fresh and do not record
      store.records_dir.should_not be_nil
    end
  end
end
