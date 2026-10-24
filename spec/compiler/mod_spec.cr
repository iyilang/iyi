require "../spec_helper"
require "../../src/compiler/iyi/mod/resolver"

# iyi: the manifest and the resolver — SPEC.md III.7 step 1. The fetch is a
# seam, so everything here runs from tables; the gate
# (`bench/packages_resolve.sh`) is where git and the mirror get exercised.

private def version(spelling : String) : SemanticVersion
  SemanticVersion.parse(spelling)
end

private def manifest(text : String) : Iyi::Mod::ModFile
  Iyi::Mod::ModFile.parse(text, "test.mod")
end

describe Iyi::Mod::ModFile do
  it "parses a module line and requirements" do
    parsed = manifest <<-MOD
      # the program's own manifest
      module github.com/user/app

      require github.com/user/lib v1.2.0
      require gitlab.com/other/dep-two v0.3.1
      MOD

    parsed.path.should eq "github.com/user/app"
    parsed.requirements.map(&.to_s).should eq [
      "require github.com/user/lib v1.2.0",
      "require gitlab.com/other/dep-two v0.3.1",
    ]
  end

  it "refuses a manifest with no module line" do
    expect_raises(Iyi::Mod::ModError, /no `module` line/) do
      manifest "require github.com/user/lib v1.0.0"
    end
  end

  it "refuses a second module line" do
    expect_raises(Iyi::Mod::ModError, /already did/) do
      manifest "module a/b\nmodule c/d"
    end
  end

  it "names the line of a malformed require" do
    expect_raises(Iyi::Mod::ModError, /test\.mod:2/) do
      manifest "module a/b\nrequire c/d"
    end
  end

  it "refuses a version without its v" do
    expect_raises(Iyi::Mod::ModError, /git tag/) do
      manifest "module a/b\nrequire c/d 1.0.0"
    end
  end

  it "refuses a path that could not be one" do
    expect_raises(Iyi::Mod::ModError, /not a module path/) do
      manifest "module a/b\nrequire Bad/Path v1.0.0"
    end
  end
end

describe Iyi::Mod::Resolver do
  # A table of manifests standing in for the network: {path, version} to
  # manifest text.
  it "takes the highest of the minimums, transitively" do
    graph = {
      {"dep/a", "1.0.0"} => "module dep/a",
      {"dep/a", "1.1.0"} => "module dep/a",
      {"dep/b", "1.0.0"} => "module dep/b\nrequire dep/a v1.1.0",
    }

    root = manifest <<-MOD
      module app/main
      require dep/a v1.0.0
      require dep/b v1.0.0
      MOD

    selections = Iyi::Mod::Resolver.resolve(root) do |path, ver|
      text = graph[{path, ver.to_s}]? || raise Iyi::Mod::ModError.new("unexpected fetch #{path} v#{ver}")
      Iyi::Mod::ModFile.parse(text, "#{path}/iyi.mod")
    end

    selections.map(&.to_s).should eq ["dep/a v1.1.0", "dep/b v1.0.0"]
  end

  it "asks for each manifest once, even when it loses" do
    fetched = [] of String
    graph = {
      {"dep/a", "1.0.0"} => "module dep/a",
      {"dep/a", "1.2.0"} => "module dep/a",
      {"dep/b", "1.0.0"} => "module dep/b\nrequire dep/a v1.0.0",
      {"dep/c", "1.0.0"} => "module dep/c\nrequire dep/a v1.2.0\nrequire dep/b v1.0.0",
    }

    root = manifest <<-MOD
      module app/main
      require dep/b v1.0.0
      require dep/c v1.0.0
      MOD

    selections = Iyi::Mod::Resolver.resolve(root) do |path, ver|
      fetched << "#{path}@#{ver}"
      Iyi::Mod::ModFile.parse(graph[{path, ver.to_s}], "#{path}/iyi.mod")
    end

    selections.map(&.to_s).should eq ["dep/a v1.2.0", "dep/b v1.0.0", "dep/c v1.0.0"]
    fetched.sort.should eq ["dep/a@1.0.0", "dep/a@1.2.0", "dep/b@1.0.0", "dep/c@1.0.0"]
  end

  it "refuses a checkout that says it is someone else" do
    root = manifest "module app/main\nrequire dep/a v1.0.0"
    expect_raises(Iyi::Mod::ModError, /identity is the path/) do
      Iyi::Mod::Resolver.resolve(root) do |path, ver|
        Iyi::Mod::ModFile.parse("module dep/impostor", "#{path}/iyi.mod")
      end
    end
  end

  it "refuses a module that requires itself" do
    root = manifest "module app/main\nrequire app/main v1.0.0"
    expect_raises(Iyi::Mod::ModError, /requires itself/) do
      Iyi::Mod::Resolver.resolve(root) { |path, ver| root }
    end
  end
end
