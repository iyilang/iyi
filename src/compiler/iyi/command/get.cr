# iyi: `iyi get PATH[@VERSION]...` and `iyi get -u` - a requirement added,
# moved, or brought up to date, without writing the line by hand
# (SPEC.md III.7).
#
#     iyi get example.com/someone/lib          # the latest release
#     iyi get example.com/someone/lib@v1.2.0   # that version, up or down
#     iyi get -u                               # every requirement, latest
#     iyi get -u --check                       # which are behind; exit 1 if any
#     iyi get example.com/someone/lib --as lib # and a short name for it
#
# The manifest stays the person's: the one `require` line is rewritten in
# place or appended, and nothing else in the file moves. Nothing is written
# until the whole graph has resolved under minimal version selection, every
# selection is checked out, and `iyi.sum` has agreed with every checkout it
# already knew - a `get` that fails leaves `iyi.mod` as it found it.
#
# What it says is what changed: a requirement added or moved, any module
# whose selected version is not the one its `require` line names, because
# another module asks for more, and what the change reaches: every module
# new to the build with its reach, and every module that moved with what
# it reaches now that it did not, or no longer does (`Mod::Reach`).
require "../mod/installer"
require "../mod/reach"

class Iyi::Command
  private def get
    upgrade_all = false
    check_only = false
    short_name = nil
    wanted = [] of String
    while option = options.shift?
      case option
      when "--help", "-h"
        puts get_usage
        exit
      when "-u"
        upgrade_all = true
      when "--check"
        check_only = true
      when "--as"
        short_name = options.shift? || abort!("get: `--as` takes a short name, as `--as web`", :USAGE_ERROR)
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
    if short_name && wanted.size != 1
      abort! "get: `--as` names one requirement, and this get names #{wanted.size}", :USAGE_ERROR
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

      # `--check` stops here: the answer is the tags against the lines,
      # and nothing is cloned or written to reach it.
      if check_only
        behind = 0
        chosen.each do |(path, version)|
          was = before[path]?
          if was.nil?
            behind += 1
            puts "would add #{path} v#{version}"
          elsif was != version
            behind += 1
            puts "would #{version > was ? "upgrade" : "downgrade"} #{path} v#{was} -> v#{version}"
          else
            puts "#{path} is at v#{version}, its latest" if upgrade_all
            puts "#{path} is already at v#{version}" unless upgrade_all
          end
        end
        exit(behind > 0 ? 1 : 0)
      end

      if name = short_name
        Mod::ModFile.check_module_short_name(name)
        if (taken = root.requirements.find { |r| r.short_name == name }) && taken.path != chosen.first[0]
          raise Mod::ModError.new("`#{name}` already names #{taken.path}")
        end
      end
      chosen.each do |(path, version)|
        text = Mod::ModFile.with_requirement(text, path, version, short_name)
      end
      updated = Mod::ModFile.parse(text, manifest_path)

      resolved = Mod::Installer.resolve(dir, updated)
      selections = resolved.map(&.first)
      # What built before, so the reach of what moved has something to be
      # compared with. A manifest that no longer resolves has nothing to
      # compare, and every module is new to it.
      previous =
        begin
          Mod::Installer.selections(dir, root).to_h { |selection| {selection.path, selection.version} }
        rescue Mod::ModError
          {} of String => SemanticVersion
        end
      reach_lines = get_reach_lines(dir, root, previous, resolved)
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
    # A replaced module builds from its directory whatever its line says,
    # and a `get` that moved the line did not move what builds.
    updated.replacements.each do |path, target|
      puts "#{path} builds from #{target}, which replaces it" if required.has_key?(path)
    end
    indirect = selections.count { |selection| !required.has_key?(selection.path) }
    fetched = selections.count { |selection| !updated.replacements.has_key?(selection.path) }
    puts "#{selections.size} module#{selections.size == 1 ? "" : "s"} selected " \
         "(#{indirect} through another module's requirements); " \
         "iyi.sum records the #{fetched} fetched from #{fetched == 1 ? "its tag" : "their tags"}"
    unless reach_lines.empty?
      puts "what the change reaches:"
      reach_lines.each { |line| puts "  #{line}" }
    end
  end

  # One line for each module new to the build, with its reach, and one
  # for each that moved and reaches something it did not or no longer
  # does. A module that moved without its reach moving says nothing: the
  # lines are for reading, and a quiet upgrade is the common one.
  private def get_reach_lines(dir : String, root : Mod::ModFile, previous : Hash(String, SemanticVersion), resolved : Array({Mod::Selection, String})) : Array(String)
    lines = [] of String
    replaced = Mod::Installer.replaced_directories(dir, root)
    resolved.each do |(selection, checkout)|
      was = previous[selection.path]?
      if was.nil?
        lines << "#{selection}, new: #{Mod::Reach.of(checkout)}"
        next
      end
      next if was == selection.version
      old_checkout =
        begin
          replaced[selection.path]? || Mod::Fetcher.checkout(selection.path, was)
        rescue Mod::ModError
          # The version it moved from cannot be fetched any more - a tag
          # deleted - so there is nothing to compare, and it is said whole.
          lines << "#{selection}, v#{was} no longer fetchable: #{Mod::Reach.of(checkout)}"
          next
        end
      next if old_checkout == checkout
      old_reach = Mod::Reach.of(old_checkout)
      new_reach = Mod::Reach.of(checkout)
      gained = new_reach - old_reach
      lost = old_reach - new_reach
      next if gained.empty? && lost.empty?
      said = [] of String
      said << "now reaches #{gained}" unless gained.empty?
      said << "no longer reaches #{lost}" unless lost.empty?
      lines << "#{selection.path} v#{was} -> v#{selection.version}: #{said.join("; ")}"
    end
    lines
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
    parsed = Mod::ModFile.check_module_version(version)
    Mod::ModFile.check_major(path, parsed)
    {path, parsed}
  end

  private def get_usage
    <<-USAGE
    Usage: #{Command.program_name} get [--check] PATH[@VERSION]... [--as NAME]
           #{Command.program_name} get [--check] -u

    Add a requirement to iyi.mod, or move one: PATH at its latest release,
    or at VERSION (`v1.2.3`, up or down; `latest` is the default). `-u`
    brings every requirement already in iyi.mod to its latest release.

    A version is a git tag, `v1.2.3`, on the repository PATH names; the
    latest is the highest release, or the highest pre-release when there
    is no release. The graph is resolved by minimal version selection, the
    checkouts are fetched into the cache and recorded in iyi.sum, and only
    then is iyi.mod written - one line rewritten or added, nothing else
    touched. Run it where iyi.mod is.

    `--as NAME` gives the one PATH a short name this project's files write
    in its place: `iyi get github.com/someone/web --as web` makes
    `using web/dsl` the module `github.com/someone/web/dsl`.

    `--check` says what the same `get` would change - `get -u --check`
    lists every requirement behind its latest release - from the tags
    alone, writes nothing, and exits 1 when anything would change.
    USAGE
  end
end
