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
# a patch. Before v1 a break moves the minor and an addition the patch, the
# way Cargo reads a `0.x`. A break past v1 is a new major, which is a new
# module path (`/v2`), and the manifest has to say so first.
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
    # Where the package sits in its repository, so both checkouts find it.
    inside = ::Path[dir].relative_to(File.expand_path(top)).to_s
    inside = "" if inside == "."

    _, major = Mod::ModFile.split_major(root.path)
    released = [] of SemanticVersion
    (mod_release_git(dir, "tag", "--list", "v*", "--merged", "HEAD") || "").each_line do |line|
      next unless version = SemanticVersion.parse?(line.strip.lchop('v'))
      released << version if major ? version.major == major : version.major <= 1
    end
    base = released.max?

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
    before.each do |name, lines|
      if now = after[name]?
        (lines - now).each { |line| gone << "#{name}: #{line}" }
        (now - lines).each { |line| added << "#{name}: #{line}" }
      else
        gone << "#{name}: module"
      end
    end
    (after.keys - before.keys).each { |name| added << "#{name}: module" }

    puts "compared with v#{base}: #{after.size} module#{after.size == 1 ? "" : "s"}, " \
         "#{gone.size} thing#{gone.size == 1 ? "" : "s"} gone, #{added.size} new"
    gone.sort.each { |line| puts "  gone  #{line}" }
    added.sort.each { |line| puts "  new   #{line}" }

    breaking = !gone.empty?
    additive = !added.empty?
    next_version = mod_release_next(base, breaking, additive)
    why = breaking ? "something a consumer uses is gone" : additive ? "something is new" : "the surface is as it was"
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

  # The smallest version after *base* that says what changed.
  private def mod_release_next(base : SemanticVersion, breaking : Bool, additive : Bool) : SemanticVersion
    if base.major == 0
      return SemanticVersion.new(0, base.minor + 1, 0) if breaking
      return SemanticVersion.new(0, base.minor, base.patch + 1)
    end
    return SemanticVersion.new(base.major + 1, 0, 0) if breaking
    return SemanticVersion.new(base.major, base.minor + 1, 0) if additive
    SemanticVersion.new(base.major, base.minor, base.patch + 1)
  end

  # Whether *wanted* moves far enough from *base* for the change.
  private def mod_release_enough?(base : SemanticVersion, wanted : SemanticVersion, breaking : Bool, additive : Bool) : Bool
    return true if wanted.major > base.major
    if base.major == 0
      return wanted.minor > base.minor if breaking
      return true
    end
    return false if breaking
    return wanted.minor > base.minor if additive
    true
  end

  # The surface of the package at *rev* (`package_surface`), from the
  # commit checked out beside the tree - never into it.
  private def mod_release_surface(top : String, rev : String, inside : String, into : String) : Hash(String, Array(String))
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
  # name, with its surface as sorted lines: one entry importing them all is
  # compiled there, so the package's own requirements resolve as they would
  # for a consumer. *package* is a copy nobody builds again - the entry is
  # written into it. With *respell*, a version written before `import
  # X::{...}` replaced `using` is read the way `iyi fix` would write it: the
  # surface is the same. *label* names the version in a refusal.
  private def package_surface(package : String, scratch : String, label : String, respell : Bool) : Hash(String, Array(String))
    if respell
      Mod::Reach.sources(package).each do |file|
        if rewritten = UsingRewrite.rewrite(File.read(file), file)
          File.write(file, rewritten[0])
        end
      end
    end
    modules = mod_release_modules(package)
    return {} of String => Array(String) if modules.empty?

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

    surfaces = {} of String => Array(String)
    Dir.glob(::Path[emit].to_posix.join("**", "*.iyimod")) do |candidate|
      artifact = IyiMod.read(candidate) rescue next
      next unless modules.includes?(artifact.module_name)
      surfaces[artifact.module_name] = iyi_export_lines(artifact)
    end
    surfaces
  end

  # The package's modules that export something: a file whose header is its
  # own path and which writes `pub` at its top level. A program beside the
  # library - an example, a tool - exports nothing and is no one's surface.
  private def mod_release_modules(package : String) : Array(String)
    Mod::Reach.sources(package).compact_map do |file|
      name = ::Path[file].relative_to(package).to_posix.to_s.rchop(".iyi")
      text = File.read(file)
      next unless text.each_line.any? { |line| line.strip == "module #{name}" }
      next unless text.each_line.any?(&.starts_with?("pub "))
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
    it - the highest `vX.Y.Z` tag HEAD contains - and say what the next
    release has to be: a thing gone is a new major (a new minor before v1),
    a thing new is a new minor (a new patch before v1), nothing moved is a
    patch. With VERSION, exit 1 when it is smaller than that, or when its
    major is not the one iyi.mod's path names. Tags nothing.
    USAGE
  end
end
