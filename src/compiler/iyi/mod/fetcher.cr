# iyi: the fetcher — a module path at an exact version becomes a checkout
# in the cache, once. Source only (III.7 first version, step 1); the
# artifact half of the registry design waits for its signature story.
#
# A path fetches from `https://<path>.git` at tag `v<version>`, shallow.
# `IYI_MOD_MIRROR=<dir>` redirects every fetch to `<dir>/<path>` instead —
# the offline hook the gates run on, and the reason nothing here needs a
# network to be tested. The checkout lands in
# `<cache>/mod/<path>@v<version>/` and is treated as immutable once its
# manifest is readable: a second build reads, never refetches.
require "file_utils"
require "./modfile"
require "../codegen/cache_dir"

module Iyi::Mod
  module Fetcher
    # The checkout directory for *path* at *version*, fetched if absent.
    def self.checkout(path : String, version : SemanticVersion) : String
      target = cache_target(path, version)
      return target if File.exists?(File.join(target, "iyi.mod"))

      remote = remote_for(path)
      tag = "v#{version}"
      parent = File.dirname(target)
      Dir.mkdir_p(parent)

      # Into a temp name, renamed on success, so a killed fetch cannot
      # leave a directory that looks fetched.
      staging = File.tempname("fetch", nil, dir: parent)
      args = ["clone", "--quiet", "--depth", "1", "--branch", tag, "--", remote, staging]
      output = IO::Memory.new
      status = Process.run("git", args, output: output, error: output)
      unless status.success?
        FileUtils.rm_rf(staging)
        raise ModError.new(
          "cannot fetch #{path} v#{version} from #{remote}:\n#{output.to_s.strip}\n" \
          "A version is a git tag, `#{tag}`, on the repository the path names.")
      end

      unless File.exists?(File.join(staging, "iyi.mod"))
        FileUtils.rm_rf(staging)
        raise ModError.new(
          "#{path} v#{version} has no iyi.mod at its root; " \
          "a module says whose it is before anything can require it")
      end

      FileUtils.rm_rf(File.join(staging, ".git"))
      File.rename(staging, target)
      target
    rescue ex : File::AlreadyExistsError
      # Two builds raced; the winner's checkout is as good as ours.
      cache_target(path, version)
    end

    # The manifest of *path* at *version* — the resolver's fetch seam,
    # bound to git.
    def self.manifest(path : String, version : SemanticVersion) : ModFile
      dir = checkout(path, version)
      file = File.join(dir, "iyi.mod")
      ModFile.parse(File.read(file), file)
    end

    # The versions *path* has, from its repository's tags: every `vX.Y.Z`
    # (with or without a pre-release), highest last. A tag that is not a
    # version is some other tag, and is not one to choose.
    def self.versions(path : String) : Array(SemanticVersion)
      remote = remote_for(path)
      output = IO::Memory.new
      errors = IO::Memory.new
      status = Process.run("git", ["ls-remote", "--tags", "--refs", "--", remote], output: output, error: errors)
      unless status.success?
        raise ModError.new(
          "cannot list the versions of #{path} at #{remote}:\n#{errors.to_s.strip}\n" \
          "A module's path names its repository, and its versions are that repository's `v1.2.3` tags.")
      end
      found = [] of SemanticVersion
      output.to_s.each_line do |line|
        ref = line.split('\t')[1]?
        next unless ref && ref.starts_with?("refs/tags/v")
        begin
          found << SemanticVersion.parse(ref.lchop("refs/tags/v"))
        rescue ArgumentError
        end
      end
      found.sort!
    end

    # The version `iyi get` means by "latest": the highest release, or the
    # highest pre-release when there is no release at all. A pre-release is
    # something its author has not called done, and nobody asked for one by
    # asking for the latest.
    def self.latest(path : String) : SemanticVersion
      versions = self.versions(path)
      if versions.empty?
        raise ModError.new(
          "#{path} has no version at #{remote_for(path)}: no tag spelled `v1.2.3`. " \
          "A version is a git tag; its author tags one before anything can require it.")
      end
      versions.reverse.find { |version| version.prerelease.identifiers.empty? } || versions.last
    end

    def self.remote_for(path : String) : String
      if mirror = ENV["IYI_MOD_MIRROR"]?
        File.join(mirror, path)
      else
        "https://#{path}.git"
      end
    end

    private def self.cache_target(path : String, version : SemanticVersion) : String
      # One entry under the compiler's cache root. The cache keeps its ten
      # most recent build directories and `mod` rides the same policy: a
      # pruned checkout is a refetch, which is what a cache being a cache
      # means.
      Iyi::CacheDir.instance.join(File.join("mod", "#{path}@v#{version}"))
    end
  end
end
