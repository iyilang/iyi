require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/reach"

describe "Iyi::Stale predefined constants" do
  it "omits unread predefined constants from reach walk and LLVM IR globals" do
    result = semantic("x = 1")
    reach = Iyi::Stale::ReachWalk.walk(result.program, result.node)
    const_names = reach.consts.map(&.to_s).to_set
    const_names.should contain("ARGC_UNSAFE")
    const_names.should contain("ARGV_UNSAFE")
    const_names.any?(&.starts_with?("Crystal::")).should be_false

    mod = result.program.codegen(result.node, single_module: true)[""].mod
    mod.globals["Crystal::CACHE_DIR"]?.should be_nil
  end

  it "includes referenced predefined constant in reach walk, LLVM IR, and execution" do
    result = semantic("x = Crystal::CACHE_DIR")
    reach = Iyi::Stale::ReachWalk.walk(result.program, result.node)
    const_names = reach.consts.map(&.to_s).to_set
    const_names.should contain("Crystal::CACHE_DIR")

    mod = result.program.codegen(result.node, single_module: true)[""].mod
    mod.globals["Crystal::CACHE_DIR"]?.should_not be_nil

    output = run(<<-CODE).to_string
      require "prelude"
      puts Crystal::CACHE_DIR
      CODE
    output.strip.should eq(Iyi::CacheDir.instance.dir)
  end
end
