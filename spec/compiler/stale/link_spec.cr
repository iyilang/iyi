require "../../spec_helper"
require "compiler/iyi/stale/link"
require "compiler/iyi/stale/encoding"
require "compiler/iyi/program"

describe "Iyi::Stale S3d: LinkFp, refusal, link once" do
  describe "Iyi::Stale::Link.refusal" do
    it "returns nil for normal flags" do
      Iyi::Stale::Link.refusal("-lm", "-rdynamic").should be_nil
      Iyi::Stale::Link.refusal("-L'/tmp/a b' -lm", nil).should be_nil
    end

    it "refuses backtick in lib_flags" do
      reason = Iyi::Stale::Link.refusal("`pkg-config --libs m`", nil)
      reason.should_not be_nil
      reason.not_nil!.should contain("contains '`'")
    end

    it "refuses $ in lib_flags" do
      reason = Iyi::Stale::Link.refusal("-L$HOME/lib", nil)
      reason.should_not be_nil
      reason.not_nil!.should contain("contains '$'")
    end

    it "refuses * in lib_flags" do
      reason = Iyi::Stale::Link.refusal("-L/opt/*/lib", nil)
      reason.should_not be_nil
      reason.not_nil!.should contain("contains '*'")
    end

    it "refuses ? in lib_flags" do
      reason = Iyi::Stale::Link.refusal("-L/opt/lib?", nil)
      reason.should_not be_nil
      reason.not_nil!.should contain("contains '?'")
    end

    it "refuses [ in lib_flags" do
      reason = Iyi::Stale::Link.refusal("-L/opt/[a-z]/lib", nil)
      reason.should_not be_nil
      reason.not_nil!.should contain("contains '['")
    end

    it "refuses ~ in lib_flags" do
      reason = Iyi::Stale::Link.refusal("-L~/lib", nil)
      reason.should_not be_nil
      reason.not_nil!.should contain("contains '~'")
    end

    it "refuses special characters in link_flags as well" do
      Iyi::Stale::Link.refusal("-lm", "-Wl,-rpath,$ORIGIN").should_not be_nil
      Iyi::Stale::Link.refusal("-lm", "-L~").should_not be_nil
      Iyi::Stale::Link.refusal("-lm", "-L*").should_not be_nil
      Iyi::Stale::Link.refusal("-lm", "-L?").should_not be_nil
      Iyi::Stale::Link.refusal("-lm", "-L[a]").should_not be_nil
      Iyi::Stale::Link.refusal("-lm", "`echo`").should_not be_nil
    end
  end

  describe "Iyi::Stale::Link.fp" do
    it "matches golden Python hashlib test vector 1" do
      env = Hash(String, String?).new
      fp = Iyi::Stale::Link.fp("-lm", nil, false, env)
      Iyi::Stale.hex(fp).should eq("b22cae1488c42e25762a3a849e9b66fe6b45f10596b2627a52fca826bb4de0ef")
    end

    it "matches golden Python hashlib test vector 2" do
      env = {
        "LIBRARY_PATH" => "/usr/local/lib",
        "CC"           => "clang",
      }
      fp = Iyi::Stale::Link.fp("-lm -lpcre2-8", "-rdynamic", true, env)
      Iyi::Stale.hex(fp).should eq("ffb68a08af19519cde972a6d866351c326e5cee5a9db185f83fb9fc6a03c714f")
    end

    it "changes with LIBRARY_PATH" do
      env1 = {"LIBRARY_PATH" => "/opt/lib1"}
      env2 = {"LIBRARY_PATH" => "/opt/lib2"}
      fp1 = Iyi::Stale::Link.fp("-lm", nil, false, env1)
      fp2 = Iyi::Stale::Link.fp("-lm", nil, false, env2)
      fp1.should_not eq(fp2)
    end

    it "changes with shim / pkg-config answer in lib_flags" do
      env = Hash(String, String?).new
      fp1 = Iyi::Stale::Link.fp("-lfoo", nil, false, env)
      fp2 = Iyi::Stale::Link.fp("-lbar", nil, false, env)
      fp1.should_not eq(fp2)
    end

    it "changes with link_flags" do
      env = Hash(String, String?).new
      fp1 = Iyi::Stale::Link.fp("-lm", nil, false, env)
      fp2 = Iyi::Stale::Link.fp("-lm", "-rdynamic", false, env)
      fp1.should_not eq(fp2)
    end

    it "changes with static flag" do
      env = Hash(String, String?).new
      fp1 = Iyi::Stale::Link.fp("-lm", nil, false, env)
      fp2 = Iyi::Stale::Link.fp("-lm", nil, true, env)
      fp1.should_not eq(fp2)
    end

    it "does NOT change with variables outside CHILD_ENV" do
      env1 = {"RANDOM_VAR" => "foo"}
      env2 = {"RANDOM_VAR" => "bar"}
      fp1 = Iyi::Stale::Link.fp("-lm", nil, false, env1)
      fp2 = Iyi::Stale::Link.fp("-lm", nil, false, env2)
      fp1.should eq(fp2)
    end
  end

  describe "Program#lib_flags caching for stale builds" do
    it "caches lib_flags when stale_build is true" do
      program = Iyi::Program.new
      program.stale_build = true
      flags1 = program.lib_flags
      flags2 = program.lib_flags
      flags1.should eq(flags2)
      flags1.same?(flags2).should be_true
    end
  end
end
