# iyi: `iyi get PATH[@VERSION]...` and `iyi get -u` - a requirement added,
# moved, or brought up to date, without writing the line by hand
# (SPEC.md III.7).
#
#     iyi get example.com/someone/lib          # the latest release
#     iyi get example.com/someone/lib@v1.2.0   # that version, up or down
#     iyi get -u                               # every requirement, latest
#
# The manifest stays the person's: the one `require` line is rewritten in
# place or appended, and nothing else in the file moves. Nothing is written
# until the whole graph has resolved under minimal version selection, every
# selection is checked out, and `iyi.sum` has agreed with every checkout it
# already knew - a `get` that fails leaves `iyi.mod` as it found it.
#
# What it says is what changed: a requirement added or moved, and any
# module whose selected version is not the one its `require` line names,
# because another module asks for more.
require "../mod/installer"

class Iyi::Command
  private def get
    upgrade_all = false
    wanted = [] of String
    while option = options.shift?
      case option
      when "--help", "-h"
        puts get_usage
        exit
      when "-u"
        upgrade_all = true
      when .starts_with?('-')
        abort! "get: unknown flag #{option}", :USAGE_ERROR
      else
        wanted << option
      end
    end

    if wanted.empty? && !upgrade_all
      abort! "get takes a module path, as `#{Command.program_name} get example.com/someone/lib`, " \
             "or `-u` for every requirement at its latest release", :USAGE_ERROR
    end
    if upgrade_all && !wanted.empty?
      abort! "get: `-u` brings every requirement up to date and takes no path; " \
             "a path alone is already brought to its latest release", :USAGE_ERROR
    end

    dir = Dir.current
    manifest_path = File.join(dir, Mod::Installer::MANIFEST)
    unless File.file?(manifest_path)
      abort! "get: there is no iyi.mod in #{Iyi.relative_filename(dir)}; a requirement is a line of one. " \
             "`#{Command.program_name} init MODULE` writes it", :USAGE_ERROR
    end

    text = File.read(manifest_path)
    begin
      root = Mod::ModFile.parse(text, manifest_path)
      before = root.requirements.to_h { |requirement| {requirement.path, requirement.version} }

      targets = [] of {String, SemanticVersion?}
      if upgrade_all
        root.requirements.each { |requirement| targets << {requirement.path, nil} }
      else
        wanted.each { |spec| targets << get_target(spec, root) }
      end

      # Every version is known before anything is fetched or written, so a
      # typo in the third path costs nothing the first two did.
      chosen = targets.map do |(path, version)|
        next {path, Mod::Fetcher.latest(path)} unless version
        # Asked of the tags before anything is cloned, so a version that is
        # not there is named beside the ones that are.
        known = Mod::Fetcher.versions(path)
        unless known.includes?(version)
          listed = known.empty? ? "none" : known.map { |v| "v#{v}" }.join(", ")
          raise Mod::ModError.new("#{path} has no v#{version}; its versions are #{listed}")
        end
        {path, version}
      end

      chosen.each do |(path, version)|
        text = Mod::ModFile.with_requirement(text, path, version)
      end
      updated = Mod::ModFile.parse(text, manifest_path)

      selections = Mod::Resolver.resolve(updated) do |path, version|
        Mod::Fetcher.manifest(path, version)
      end
      Mod::Sum.check(dir, selections) do |selection|
        Mod::Fetcher.checkout(selection.path, selection.version)
      end
    rescue ex : Mod::ModError
      abort! "get: #{ex.message}", :USAGE_ERROR
    end

    File.write(manifest_path, text)

    chosen.each do |(path, version)|
      if (was = before[path]?).nil?
        puts "added #{path} v#{version}"
      elsif was == version
        puts "#{path} is already at v#{version}"
      else
        puts "#{version > was ? "upgraded" : "downgraded"} #{path} v#{was} -> v#{version}"
      end
    end

    # MVS answers with the highest minimum, so a requirement another module
    # outbids is not the version that builds; saying so is the difference
    # between a downgrade that happened and one that only looks like it.
    required = updated.requirements.to_h { |requirement| {requirement.path, requirement.version} }
    selections.each do |selection|
      if (named = required[selection.path]?) && named != selection.version
        puts "#{selection.path} builds at v#{selection.version}: iyi.mod names v#{named}, " \
             "and another module asks for more"
      end
    end
    indirect = selections.count { |selection| !required.has_key?(selection.path) }
    puts "#{selections.size} module#{selections.size == 1 ? "" : "s"} selected " \
         "(#{indirect} through another module's requirements); iyi.sum records each"
  end

  # One `PATH[@VERSION]` argument: the version is `vX.Y.Z` or `latest`,
  # and left out it means `latest`.
  private def get_target(spec : String, root : Mod::ModFile) : {String, SemanticVersion?}
    path, at, version = spec.partition('@')
    Mod::ModFile.check_module_path(path)
    if path == root.path
      raise Mod::ModError.new("#{path} is this module; a module does not require itself")
    end
    return {path, nil} if at.empty? || version == "latest"
    if version.empty?
      raise Mod::ModError.new("'#{spec}' names no version after `@`; write `@v1.2.3` or `@latest`")
    end
    {path, Mod::ModFile.check_module_version(version)}
  end

  private def get_usage
    <<-USAGE
    Usage: #{Command.program_name} get PATH[@VERSION]...
           #{Command.program_name} get -u

    Add a requirement to iyi.mod, or move one: PATH at its latest release,
    or at VERSION (`v1.2.3`, up or down; `latest` is the default). `-u`
    brings every requirement already in iyi.mod to its latest release.

    A version is a git tag, `v1.2.3`, on the repository PATH names; the
    latest is the highest release, or the highest pre-release when there
    is no release. The graph is resolved by minimal version selection, the
    checkouts are fetched into the cache and recorded in iyi.sum, and only
    then is iyi.mod written - one line rewritten or added, nothing else
    touched. Run it where iyi.mod is.
    USAGE
  end
end
