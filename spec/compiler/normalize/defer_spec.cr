require "../../spec_helper"

# iyi: `defer` — cleanup that runs however the scope is left (SPEC.md III.1.4).
#
# What it does on every exit — inline on an ordinary one, through the
# registry (the proc whose def is marked `iyi_defer`) on a panic, innermost
# first, once per scope — is held by bench/panics.sh, which runs it.
describe "Normalize: defer" do
  it "guards a defer that has nothing after it" do
    assert_normalize "defer x", "begin\nensure\n  x\nend", filename: "x.iyi"
  end

  it "leaves a Crystal file's `defer` alone" do
    assert_normalize "a\ndefer x\nb", "a\ndefer(x)\nb"
  end
end
