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
#
# A commit no tag names has a pseudo-version, Go's spelling:
# `v0.0.0-20260801120000-abcdef123456` when no version tag is behind it,
# `v1.2.4-0.20260801120000-abcdef123456` after v1.2.3, and
# `v1.3.0-rc.1.0.20260801120000-abcdef123456` after a pre-release. The
# time is the commit's, in UTC, and the hash its first twelve hex digits.
# It sorts above the tag it follows and below the next release, so minimal
# version selection orders it among the tags without knowing it is not
# one. A pseudo-version is fetched by its commit from a whole clone, and is
# refused unless the commit's own time and tags spell exactly it.
require "file_utils"
require "./modfile"
require "../codegen/cache_dir"

module Iyi::Mod
  module Fetcher
    # The checkout directory for *path* at *version*, fetched if absent.
    def self.checkout(path : String, version : SemanticVersion) : String
      target = cache_target(path, version)
      return target if File.exists?(File.join(target, "iyi.mod"))
      ModFile.check_major(path, version)

      remote = remote_for(path)
      tag = "v#{version}"
      parent = File.dirname(target)
      Dir.mkdir_p(parent)

      # Into a temp name, renamed on success, so a killed fetch cannot
      # leave a directory that looks fetched.
      staging = File.tempname("fetch", nil, dir: parent)
      if prefix = pseudo_commit(version)
        begin
          clone_history(path, staging)
          sha = commit(staging, prefix)
          unless sha
            raise ModError.new("cannot fetch #{path} v#{version}: #{remote} has no commit #{prefix}")
          end
          spelled = version_of(staging, path, sha)
          unless spelled == version
            raise ModError.new(
              "#{path} v#{version} is not that commit's version: #{prefix} is v#{spelled}. " \
              "A pseudo-version is the commit's own time and hash after the version tag behind it; " \
              "`iyi get #{path}@#{prefix}` writes it")
          end
          git(staging, "checkout", "--quiet", "--detach", sha) ||
            raise ModError.new("cannot check out #{prefix} of #{path}")
        rescue ex : ModError
          FileUtils.rm_rf(staging)
          raise ex
        end
      else
        args = ["clone", "--quiet", "--depth", "1", "--branch", tag, "--", remote, staging]
        output = IO::Memory.new
        status = Process.run("git", args, output: output, error: output)
        unless status.success?
          FileUtils.rm_rf(staging)
          raise ModError.new(
            "cannot fetch #{path} v#{version} from #{remote}:\n#{output.to_s.strip}\n" \
            "A version is a git tag, `#{tag}`, on the repository the path names.")
        end
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
      # Only the versions this path can have: its suffix's major, or v0 and
      # v1 for a path without one. The repository's v2 tags are
      # `<path>/v2`'s, and a `get` of the plain path must not cross into them.
      _, major = ModFile.split_major(path)
      found.select! { |version| major ? version.major == major : version.major <= 1 }
      found.sort!
    end

    # The version `iyi get` means by "latest": the highest release, or the
    # highest pre-release when there is no release at all. A pre-release is
    # something its author has not called done, and nobody asked for one by
    # asking for the latest. A repository with no version tag at all has
    # its default branch, as a pseudo-version.
    def self.latest(path : String) : SemanticVersion
      versions = self.versions(path)
      return version_at(path, "HEAD") if versions.empty?
      versions.reverse.find { |version| version.prerelease.identifiers.empty? } || versions.last
    end

    # The version *ref* - a branch, a tag, or a commit - names in *path*'s
    # repository: the commit's own version tag when it has one, else its
    # pseudo-version. What `iyi get PATH@main` writes.
    def self.version_at(path : String, ref : String) : SemanticVersion
      if ref.starts_with?('-')
        raise ModError.new("'#{ref}' is not a branch, a tag or a commit")
      end
      parent = Iyi::CacheDir.instance.join("mod")
      Dir.mkdir_p(parent)
      scratch = File.tempname("ref", nil, dir: parent)
      begin
        clone_history(path, scratch)
        sha = commit(scratch, ref) || commit(scratch, "origin/#{ref}")
        unless sha
          raise ModError.new("#{path} has no `#{ref}` at #{remote_for(path)}; `@` names a version, a branch, a tag or a commit")
        end
        version_of(scratch, path, sha)
      ensure
        FileUtils.rm_rf(scratch)
      end
    end

    # The commit a pseudo-version names - its hash prefix - or nil for a
    # tag's version.
    def self.pseudo_commit(version : SemanticVersion) : String?
      last = version.prerelease.identifiers.last?
      return unless last.is_a?(String)
      stamp, dash, hash = last.partition('-')
      return unless dash == "-" && stamp.size == 14 && stamp.each_char.all?(&.ascii_number?)
      return unless hash.size == 12 && hash.each_char.all? { |c| c.ascii_number? || c.in?('a'..'f') }
      hash
    end

    # *sha*'s version in the clone at *dir*, for *path*: the highest version
    # tag on the commit itself, else the pseudo-version after the highest
    # version tag behind it. Only tags the path can have count, as in
    # `versions`: a v2 tag is `<path>/v2`'s.
    private def self.version_of(dir : String, path : String, sha : String) : SemanticVersion
      _, major = ModFile.split_major(path)
      tags = ->(filter : String) do
        found = [] of SemanticVersion
        (git(dir, "tag", "--list", "v*", filter, sha) || "").each_line do |line|
          next unless version = SemanticVersion.parse?(line.strip.lchop('v'))
          found << version if major ? version.major == major : version.major <= 1
        end
        found.max?
      end
      if own = tags.call("--points-at")
        return own
      end
      seconds = (git(dir, "show", "-s", "--format=%ct", sha) || "").strip.to_i64? ||
                raise ModError.new("cannot read the time of #{sha[0, 12]} in #{path}")
      stamp = "#{Time.unix(seconds).to_s("%Y%m%d%H%M%S")}-#{sha[0, 12]}"
      spelled =
        if base = tags.call("--merged")
          if base.prerelease.identifiers.empty?
            "#{base.major}.#{base.minor}.#{base.patch + 1}-0.#{stamp}"
          else
            "#{base.major}.#{base.minor}.#{base.patch}-#{base.prerelease}.0.#{stamp}"
          end
        else
          "#{major || 0}.0.0-#{stamp}"
        end
      SemanticVersion.parse(spelled)
    end

    # A whole clone of *path*'s repository at *into*: a pseudo-version's
    # commit is on no tag a shallow clone could ask for, and its version
    # needs the tags behind it.
    private def self.clone_history(path : String, into : String) : Nil
      remote = remote_for(path)
      output = IO::Memory.new
      status = Process.run("git", ["clone", "--quiet", "--no-checkout", "--", remote, into], output: output, error: output)
      unless status.success?
        raise ModError.new("cannot fetch #{path} from #{remote}:\n#{output.to_s.strip}")
      end
    end

    # The full hash of the commit *ref* names in the clone at *dir*.
    private def self.commit(dir : String, ref : String) : String?
      git(dir, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}").try(&.strip.presence)
    end

    # git's output in *dir*, or nil when it fails.
    private def self.git(dir : String, *args : String) : String?
      output = IO::Memory.new
      status = Process.run("git", ["-C", dir] + args.to_a, output: output, error: IO::Memory.new)
      status.success? ? output.to_s : nil
    end

    # The repository *path* is fetched from: a `/vN` suffix is a major
    # version of the repository without it, not a repository of its own.
    def self.remote_for(path : String) : String
      repository, _ = ModFile.split_major(path)
      if mirror = ENV["IYI_MOD_MIRROR"]?
        File.join(mirror, repository)
      else
        "https://#{repository}.git"
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
