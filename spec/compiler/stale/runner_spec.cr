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
end
