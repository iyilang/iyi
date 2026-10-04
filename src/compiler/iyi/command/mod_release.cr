# iyi: `iyi mod release [VERSION]` - what the next release of this package
# has to be called, from what its exported surface did since the last one
# (SPEC.md III.7).
#
#     $ iyi mod release v1.3.0
#     compared with v1.2.0: 4 modules, 1 thing gone, 2 new
#       gone  liba: def greeting : String
#       new   liba: def greeting(name : String) : String
#       new   liba/extra: module
#     v1.3.0 is too small: something a consumer uses is gone, so the next
#     release is v2.0.0, at the path example.com/liba/v2
#
# Minimal version selection builds every consumer at the highest minimum
# anyone asked for, and that is only safe because a minor or patch release
# keeps what the one before it exported. Go leaves that to the author's
# memory; here it is read off the two commits. Each is checked out beside
# the tree, every module of the package that exports anything is compiled
# once, and the two artifacts' surfaces are compared line by line: a line
# gone is a break, a line or a module new is an addition, nothing moved is
# a patch. Two pairs read otherwise. A def gone whose line came back with
# only defaulted parameters after its own is an addition: every call still
# builds. An `abstract def` or associated type new on a type that was
# there is a break: every impl of it lacks it. Before v1 a break moves the
# minor and an addition the patch, the way Cargo reads a `0.x`. A break
# past v1 is a new major, which is a new module path (`/v2`), and the
# manifest has to say so first.
#
# It tags nothing: a release is `git tag` and a push, and this is the check
# that runs before them - exit 1 when VERSION understates the change.
require "file_utils"
require "../mod/installer"
require "../mod/reach"
require "../tools/using_rewrite"

class Iyi::Command
  private def mod_release
    proposed = nil
    while option = options.shift?
      case option
      when "--help", "-h"
        puts mod_release_usage
        exit
      when .starts_with?('-')
        abort! "mod release: unknown flag #{option}", :USAGE_ERROR
      else
        abort! "mod release: one version, and '#{option}' is a second", :USAGE_ERROR if proposed
        begin
          proposed = Mod::ModFile.check_module_version(option)
        rescue ex : Mod::ModError
          abort! "mod release: #{ex.message}", :USAGE_ERROR
        end
      end
    end

    dir = File.expand_path(Dir.current)
    manifest_path = File.join(dir, Mod::Installer::MANIFEST)
    unless File.file?(manifest_path)
      abort! "mod release: there is no iyi.mod in #{Iyi.relative_filename(dir)}; a release is of a package, " \
             "and a package is a directory with one", :USAGE_ERROR
    end
    root =
      begin
        Mod::ModFile.parse(File.read(manifest_path), manifest_path)
      rescue ex : Mod::ModError
        abort! "mod release: #{ex.message}", :USAGE_ERROR
      end

    top = mod_release_git(dir, "rev-parse", "--show-toplevel").try(&.strip)
    unless top
      abort! "mod release: #{Iyi.relative_filename(dir)} is not in a git repository; a release is a tag on one", :USAGE_ERROR
    end
    # Where the package sits in its repository, so both checkouts find it -
    # asked of git, not worked out from the two paths: on darwin the working
    # directory is `/var/...` and git's top level `/private/var/...`, and the
    # difference climbed out of the checkout back into the working tree, so
    # both "versions" compiled were the tree as it stood and nothing moved.
    inside = (mod_release_git(dir, "rev-parse", "--show-prefix") || "").strip.rchop('/')

    # The package has to be in HEAD, which is what a tag names: a package
    # not yet committed - or not yet its own repository, sitting untracked
    # in someone else's - has nothing a release could compare.
    manifest_at = ->(rev : String) { "#{rev}:#{inside.empty? ? "" : "#{inside}/"}#{Mod::Installer::MANIFEST}" }
    unless mod_release_git(dir, "cat-file", "-e", manifest_at.call("HEAD"))
      abort! "mod release: HEAD of the repository at #{Iyi.relative_filename(top)} has no #{Mod::Installer::MANIFEST} at " \
             "#{inside.empty? ? "its root" : inside}; a release is of what a commit holds, so commit the package first", :USAGE_ERROR
    end

    _, major = Mod::ModFile.split_major(root.path)
    released = [] of SemanticVersion
    (mod_release_git(dir, "tag", "--list", "v*", "--merged", "HEAD") || "").each_line do |line|
      next unless version = SemanticVersion.parse?(line.strip.lchop('v'))
      released << version if major ? version.major == major : version.major <= 1
    end
    # Measured from the last release, not the last tag: a pre-release
    # promises consumers nothing, so a break made in `v1.2.0-rc.1` is still
    # a break against v1.1.0. Measured from the rc, a def v1.1.0 exported
    # and the rc removed was never compared, and `v1.2.0` was approved as
    # "holds what changed". The highest pre-release only when there is no
    # release at all.
    # And only a tag that holds this package: in a repository that holds
    # other things the tags are theirs too. A new package inside another
    # repository took its `v0.16.2` for its last release, checked the whole
    # repository out to compare, and answered "v0.16.2 has no iyi.mod".
    ordered = released.sort_by { |version| {version.prerelease.identifiers.empty? ? 1 : 0, version} }.reverse!
    base = ordered.find { |version| mod_release_git(dir, "cat-file", "-e", manifest_at.call("v#{version}")) }

    if (wanted = proposed) && released.includes?(wanted)
      abort! "mod release: v#{wanted} is already a tag, and a version is released once", :USAGE_ERROR
    end
    unless (mod_release_git(dir, "status", "--porcelain", "--untracked-files=no", "--", ".") || "").strip.empty?
      puts "note: the tree has changes no commit holds; what is compared is HEAD, which is what a tag names"
    end

    unless base
      if wanted = proposed
        begin
          Mod::ModFile.check_major(root.path, wanted)
        rescue ex : Mod::ModError
          abort! "mod release: #{ex.message}", :USAGE_ERROR
        end
        puts "no release before this one: v#{wanted} starts #{root.path}"
      else
        puts "no release before this one: any version starts #{root.path}, as `git tag v0.1.0`"
      end
      return
    end

    scratch = File.tempname("iyi-release", nil)
    Dir.mkdir_p(scratch)
    begin
      before = mod_release_surface(top, "v#{base}", inside, File.join(scratch, "before"))
      after = mod_release_surface(top, "HEAD", inside, File.join(scratch, "after"))
    rescue ex : Mod::ModError
      abort! "mod release: #{ex.message}", :USAGE_ERROR
    ensure
      FileUtils.rm_rf(scratch)
    end

    gone = [] of String
    added = [] of String
    # New lines that break all the same: a requirement on a type that was
    # already there, which every impl of it now lacks.
    asked = [] of String
    # A def gone whose line came back with defaulted parameters after its
    # own: every call to it still compiles, so the pair is an addition.
    grown = [] of String
    before.each do |name, lines|
      if now = after[name]?
        appeared = now.keys - lines.keys
        (lines.keys - now.keys).each do |line|
          was = lines[line]
          wider = appeared.find do |candidate|
            mod_release_extends?(was, now[candidate])
          end
          if wider
            appeared.delete(wider)
            grown << "#{name}: #{line} -> #{wider}"
          else
            gone << "#{name}: #{line}"
          end
        end
        appeared.each do |line|
          entry = now[line]
          if entry.requirement && lines.each_value.any? { |other| other.declares == entry.owner }
            asked << "#{name}: #{line}"
          else
            added << "#{name}: #{line}"
          end
        end
      else
        gone << "#{name}: module"
      end
    end
    (after.keys - before.keys).each { |name| added << "#{name}: module" }

    news = added.size + asked.size + grown.size
    puts "compared with v#{base}: #{after.size} module#{after.size == 1 ? "" : "s"}, " \
         "#{gone.size} thing#{gone.size == 1 ? "" : "s"} gone, #{news} new"
    gone.sort.each { |line| puts "  gone  #{line}" }
    asked.sort.each { |line| puts "  new   #{line} - a requirement, which every impl of it has to add" }
    grown.sort.each { |line| puts "  grown #{line}" }
    added.sort.each { |line| puts "  new   #{line}" }

    breaking = !gone.empty? || !asked.empty?
    additive = news > 0
    next_version = mod_release_next(base, breaking, additive)
    why =
      if !gone.empty?
        "something a consumer uses is gone"
      elsif !asked.empty?
        "a type a consumer implements requires something new"
      elsif additive
        "something is new"
      else
        "the surface is as it was"
      end
    repository, _ = Mod::ModFile.split_major(root.path)
    next_path = next_version.major >= 2 ? "#{repository}/v#{next_version.major}" : repository

    unless wanted = proposed
      puts "the next release is v#{next_version}: #{why}"
      puts "and its path is #{next_path}, which iyi.mod has to say first" if next_path != root.path
      return
    end

    if wanted <= base
      puts "v#{wanted} is not after v#{base}, the release before it"
      exit 1
    end
    unless mod_release_enough?(base, wanted, breaking, additive)
      puts "v#{wanted} is too small: #{why}, so the next release is v#{next_version}" \
           "#{next_path != root.path ? ", at the path #{next_path}" : ""}"
      exit 1
    end
    begin
      Mod::ModFile.check_major(root.path, wanted)
    rescue ex : Mod::ModError
      puts "v#{wanted} holds what changed, and #{ex.message}"
      exit 1
    end
    puts "v#{wanted} holds what changed: `git tag v#{wanted}` and push it"
  end

  # The smallest version after *base* that says what changed. After a
  # pre-release - which is the base only when nothing was released - that
  # is its own release, whatever moved: a pre-release promises nothing.
  private def mod_release_next(base : SemanticVersion, breaking : Bool, additive : Bool) : SemanticVersion
    return SemanticVersion.new(base.major, base.minor, base.patch) unless base.prerelease.identifiers.empty?
    if base.major == 0
      return SemanticVersion.new(0, base.minor + 1, 0) if breaking
      return SemanticVersion.new(0, base.minor, base.patch + 1)
    end
    return SemanticVersion.new(base.major + 1, 0, 0) if breaking
    return SemanticVersion.new(base.major, base.minor + 1, 0) if additive
    SemanticVersion.new(base.major, base.minor, base.patch + 1)
  end

  # Whether *wanted* moves far enough from *base* for the change: anything
  # after a pre-release does.
  private def mod_release_enough?(base : SemanticVersion, wanted : SemanticVersion, breaking : Bool, additive : Bool) : Bool
    return true unless base.prerelease.identifiers.empty?
    return true if wanted.major > base.major
    if base.major == 0
      return wanted.minor > base.minor if breaking
      return true
    end
    return false if breaking
    return wanted.minor > base.minor if additive
    true
  end

  # Whether the def line *now* takes every call the gone line *was* took:
  # the same def, the same answer, its parameters the old ones and then
  # only defaulted ones, splats or a bare `*`. A requirement is not one -
  # an impl written to the old `abstract def` no longer matches the new
  # one. Compared line by line, `by : Int32 = 2` appended to `pub def
  # scale` was a def gone and one new, and the release a new major at a
  # `/v2` path although every `scale(x)` still built.
  private def mod_release_extends?(was : SurfaceLine, now : SurfaceLine) : Bool
    return false unless (old = was.signature) && (wide = now.signature) && was.owner == now.owner
    return false if old.required || wide.required
    return false unless old.name == wide.name && old.receiver == wide.receiver && old.visibility == wide.visibility &&
                        old.block_parameter == wide.block_parameter && old.return_type == wide.return_type &&
                        old.free_variables == wide.free_variables &&
                        old.free_variable_bounds == wide.free_variable_bounds && old.where_bounds == wide.where_bounds
    kept = old.parameters.size
    return false unless wide.parameters.size > kept && wide.parameters[0, kept] == old.parameters
    wide.parameters[kept..].all? { |parameter| parameter.starts_with?('*') || parameter.includes?(" = ") }
  end

  # The surface of the package at *rev* (`package_surface`), from the
  # commit checked out beside the tree - never into it.
  private def mod_release_surface(top : String, rev : String, inside : String, into : String) : Hash(String, Hash(String, SurfaceLine))
    unless mod_release_git(top, "worktree", "add", "--detach", "--quiet", into, rev)
      raise Mod::ModError.new("cannot check out #{rev}")
    end
    begin
      package = inside.empty? ? into : File.join(into, inside)
      unless File.file?(File.join(package, Mod::Installer::MANIFEST))
        raise Mod::ModError.new("#{rev} has no iyi.mod at #{inside.empty? ? "the repository's root" : inside}")
      end
      # HEAD is compiled as it is - a `using` there is what a consumer meets.
      package_surface(package, into, rev, respell: rev != "HEAD")
    ensure
      mod_release_git(top, "worktree", "remove", "--force", into)
    end
  end

  # Every module of the package at *package* that exports something, by
  # name, with its surface's lines (`iyi_surface_lines`): one entry
  # importing them all is compiled there, so the package's own requirements
  # resolve as they would for a consumer. *package* is a copy nobody builds
  # again - the entry is written into it. With *respell*, a version written
  # before `import X::{...}` replaced `using` is read the way `iyi fix`
  # would write it: the surface is the same. *label* names the version in a
  # refusal.
  private def package_surface(package : String, scratch : String, label : String, respell : Bool) : Hash(String, Hash(String, SurfaceLine))
    if respell
      Mod::Reach.sources(package).each do |file|
        if rewritten = UsingRewrite.rewrite(File.read(file), file)
          File.write(file, rewritten[0])
        end
      end
    end
    modules = mod_release_modules(package)
    return {} of String => Hash(String, SurfaceLine) if modules.empty?

    entry = File.join(package, "__iyi_release_entry.iyi")
    File.write(entry, modules.map { |name| "import #{name}\n" }.join)
    emit = File.join(scratch, "__iyi_release_mods")
    compiler = Compiler.new
    compiler.prelude = "iyi/prelude"
    compiler.no_codegen = true
    compiler.emit_iyimod = emit
    compiler.stdout = IO::Memory.new
    compiler.stderr = IO::Memory.new
    begin
      compiler.compile(Compiler::Source.new(entry, File.read(entry)), File.join(scratch, "unused"))
    rescue ex : Iyi::Error | Iyi::CodeError | Mod::ModError
      deepest = Iyi.deepest_error(ex)
      raise Mod::ModError.new("#{label} does not compile, so there is no surface to compare: #{deepest.message.to_s.lines.first?}")
    end

    surfaces = {} of String => Hash(String, SurfaceLine)
    Dir.glob(Iyi.glob_root(emit).join("**", "*.iyimod")) do |candidate|
      artifact = IyiMod.read(candidate) rescue next
      next unless modules.includes?(artifact.module_name)
      surfaces[artifact.module_name] = iyi_surface_lines(artifact)
    end
    surfaces
  end

  # The package's modules that export something: a file whose header is its
  # own path and which writes `pub` at its top level. A program beside the
  # library - an example, a tool - exports nothing and is no one's surface.
  # Read the way the lexer reads them: past a byte order mark, with a
  # comment after the header, and any space after `pub`. A module saved
  # with a BOM, headed `module rel # the library`, or written `pub<TAB>def`
  # was not found, and its whole surface was reported gone - "the next
  # release is v2.0.0" for a release that changed nothing.
  private def mod_release_modules(package : String) : Array(String)
    Mod::Reach.sources(package).compact_map do |file|
      name = ::Path[file].relative_to(package).to_posix.to_s.rchop(".iyi")
      lines = File.read(file).lchop('\uFEFF').lines
      next unless lines.any? { |line| line.partition('#')[0].split == ["module", name] }
      next unless lines.any? { |line| line.starts_with?("pub") && (after = line[3]?) && after.whitespace? }
      name
    end
  end

  # git's output in *dir*, or nil when it fails.
  private def mod_release_git(dir : String, *args : String) : String?
    output = IO::Memory.new
    status = Process.run("git", ["-C", dir] + args.to_a, output: output, error: IO::Memory.new)
    status.success? ? output.to_s : nil
  end

  private def mod_release_usage
    <<-USAGE
    Usage: #{Command.program_name} mod release [VERSION]

    Compare this package's exported surface at HEAD with the release before
    it - the highest `vX.Y.Z` tag HEAD contains, a pre-release only when
    there is no release - and say what the next release has to be: a thing
    gone, or a requirement new on a type an impl implements, is a new major
    (a new minor before v1), a thing new - a def that only gained defaulted
    parameters among them - is a new minor (a new patch before v1), nothing
    moved is a patch; after a pre-release, its own release. With VERSION,
    exit 1 when it is smaller than that, or when its major is not the one
    iyi.mod's path names. Tags nothing.
    USAGE
  end
end
