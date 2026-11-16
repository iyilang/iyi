require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/runner"
require "compiler/iyi/stale/store"
require "compiler/iyi/stale/snapshot"

describe Iyi::Stale::Runner do
  it "cannot reuse a key or inputs from an earlier compiler attempt" do
    with_tempfile("attempt-key.json", "attempt-inputs.json") do |key_path, inputs_path|
      hit = %({"format":"iyi-stale-key","version":1,"phase":"hit","test":{},"hit":{"mode":"local","build":"abc"}})
      status, key = Iyi::Stale::Runner.build_attempt(key_path, inputs_path) do
        File.write(key_path, hit)
        File.write(inputs_path, "first attempt")
        Process::Status[0]
      end
      Iyi::Stale::Runner.build_hit(status, key).not_nil!.build.should eq("abc")

      status, key = Iyi::Stale::Runner.build_attempt(key_path, inputs_path) do
        Process::Status[1] # The retry fails before the compiler writes a key.
      end
      status.success?.should be_false
      key.should be_nil
      File.exists?(key_path).should be_false
      File.exists?(inputs_path).should be_false
      Iyi::Stale::Runner.build_hit(status, key).should be_nil
    end
  end

  it "does not serve a hit emitted by a failed compiler" do
    with_tempfile("failed-key.json", "failed-inputs.json") do |key_path, inputs_path|
      status, key = Iyi::Stale::Runner.build_attempt(key_path, inputs_path) do
        File.write(key_path, %({"format":"iyi-stale-key","version":1,"phase":"hit","test":{},"hit":{"mode":"local","build":"abc"}}))
        Process::Status[1]
      end
      key.not_nil!.hit.should_not be_nil
      Iyi::Stale::Runner.build_hit(status, key).should be_nil
    end
  end

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

  it "requires IYI_CI_PRODUCER=1 when --export-index is supplied" do
    old_val = ENV["IYI_CI_PRODUCER"]?
    ENV.delete("IYI_CI_PRODUCER")
    begin
      with_tempfile("runner_producer_test") do |cache_root|
        store = Iyi::Stale::Store.new(cache_root)
        runner = Iyi::Stale::Runner.new(
          files: [] of String,
          cached: false,
          fresh: true,
          export_indices: ["master=out.json"],
          store: store
        )
        expect_raises(Iyi::Stale::RunnerError, "--export-index requires IYI_CI_PRODUCER=1") do
          runner.run_internal
        end
      end
    ensure
      if old = old_val
        ENV["IYI_CI_PRODUCER"] = old
      else
        ENV.delete("IYI_CI_PRODUCER")
      end
    end
  end

  it "refuses chaos mode with stale runner" do
    with_tempfile("runner_chaos_test") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      runner = Iyi::Stale::Runner.new(
        files: [] of String,
        cached: true,
        fresh: false,
        chaos: true,
        store: store
      )
      expect_raises(Iyi::Stale::RunnerError, "cannot combine --chaos with stale runner") do
        runner.run_internal
      end
    end
  end
end

describe Iyi::Command::TestPool do
  it "returns each item's result in item order, with no more than the parallel count at once" do
    running = 0
    peak = 0
    results = Iyi::Command::TestPool.run(10, 3) do |index|
      running += 1
      peak = running if running > peak
      Fiber.yield
      running -= 1
      index * 2
    end
    results.should eq((0...10).map { |index| index * 2 })
    peak.should eq 3
  end

  it "raises an item's exception once the others have ended" do
    finished = [] of Int32
    expect_raises(Exception, "item 1 failed") do
      Iyi::Command::TestPool.run(4, 2) do |index|
        raise "item 1 failed" if index == 1
        Fiber.yield
        finished << index
        index
      end
    end
    finished.sort.should eq [0, 2, 3]
  end
end

describe "Iyi::Stale::Runner with -p" do
  # The `-p` refusal lived in the command, which the runner never sees. This
  # runner takes a parallel count with the receipt modes; with no tests it
  # stops at the same abort every run does, before the pool starts. The
  # parallel behaviour itself is proven by the TestPool examples above and by
  # `iyi test --cached -p N` runs.
  it "takes a parallel count with the receipt modes and stops at the empty-file abort" do
    with_tempfile("runner_parallel_test") do |cache_root|
      store = Iyi::Stale::Store.new(cache_root)
      runner = Iyi::Stale::Runner.new(files: [] of String, cached: true, parallel: 4, store: store)
      # Nothing to run, so the run gets as far as the empty test list and no
      # further: the count was not refused on the way.
      error = expect_raises(Iyi::Stale::RunnerError) { runner.run_internal }
      error.message.not_nil!.should contain "no *_test.iyi found"
    end
  end
end
