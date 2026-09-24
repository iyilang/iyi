# iyi: `iyi mod tidy` - `iyi.mod` and `iyi.sum` made to say what the
# project's source asks for, and nothing else (SPEC.md III.7).
#
# The source is every `.iyi` file under the manifest's directory - tests
# included, since a test's imports are requirements too - except hidden
# directories, `lib/` (Crystal shards behind boundaries, not iyi.mod's),
# and any directory with an `iyi.mod` of its own, which is another module.
#
# Three changes, each a rule rather than a guess:
#
# - An import no `require` covers gets one. A module the graph already
#   selects through another requirement is required at the version it
#   builds at, so tidying never moves what builds; one the graph lacks is
#   found by the import's own prefixes, longest first, and required at its
#   latest release.
# - A `require` nothing imports is removed - unless removing it would
#   change what builds: a line naming a module another requirement pulls
#   in at a lower version is the program raising it, and that is kept and
#   said. Go spells that line `// indirect`; here it is decided by asking
#   the resolver, so there is no second kind of line to keep in step.
# - `iyi.sum` keeps an entry for each module that builds, and none for a
#   version nothing builds.
#
# `--check` answers the same question and writes nothing: exit 1 when a
# change is due, which is what a CI step wants.
require "../mod/installer"

class Iyi::Command
  private def mod_tidy
    check_only = false
    while option = options.shift?
      case option
      when "--help", "-h"
        puts mod_tidy_usage
        exit
      when "--check"
        check_only = true
      else
        abort! "mod tidy: unexpected '#{option}'; it tidies the iyi.mod in this directory", :USAGE_ERROR
      end
    end

    dir = Dir.current
    manifest_path = File.join(dir, Mod::Installer::MANIFEST)
    unless File.file?(manifest_path)
      abort! "mod tidy: there is no iyi.mod in #{Iyi.relative_filename(dir)}; " \
             "`#{Command.program_name} init MODULE` writes one", :USAGE_ERROR
    end

    # The manifest's short names, so `web/dsl` counts as the requirement
    # it names.
    short_names =
      begin
        Mod::Installer.short_name_rows(Mod::ModFile.parse(File.read(manifest_path), manifest_path))
      rescue ex : Mod::ModError
        abort! "mod tidy: #{ex.message}", :USAGE_ERROR
      end

    # Every package the source imports, and the first file that does.
    importers = {} of String => String
    mod_tidy_sources(dir).each do |file|
      imports = test_imports_of(file)
      unless imports
        abort! "mod tidy: #{Iyi.relative_filename(file)} does not parse, so what it imports is not known; " \
               "a tidy that guessed would remove a requirement it uses", :USAGE_ERROR
      end
      imports.each do |written|
        path = Mod::Installer.expand(written, short_names)
        importers[path] ||= file if path.includes?('.')
      end
    end

    text = File.read(manifest_path)
    added = [] of {String, SemanticVersion, String}
    removed = [] of {String, SemanticVersion}
    kept = [] of {String, SemanticVersion, SemanticVersion}
    begin
      root = Mod::ModFile.parse(text, manifest_path)
      selected = Mod::Installer.selections(dir, root).to_h { |s| {s.path, s.version} }
      required = root.requirements.map(&.path)

      # Missing: imported, covered by no `require`.
      importers.keys.sort!.each do |imported|
        next if mod_tidy_cover(imported, required)
        if (through = mod_tidy_cover(imported, selected.keys))
          version = selected[through]
          added << {through, version, importers[imported]}
          required << through
        else
          module_path, version = mod_tidy_find(imported)
          added << {module_path, version, importers[imported]}
          required << module_path
        end
        text = Mod::ModFile.with_requirement(text, added.last[0], added.last[1])
      end

      # Unused: required, imported by nothing. Each is asked against the
      # manifest as it stands after the ones before it, in path order, so
      # the answer is the same every run.
      current = Mod::ModFile.parse(text, manifest_path)
      current.requirements.sort_by(&.path).each do |requirement|
        next if importers.keys.any? { |imported| mod_tidy_cover(imported, [requirement.path]) }
        before = Mod::Installer.selections(dir, current).to_h { |s| {s.path, s.version} }
        trial_text = Mod::ModFile.without_requirement(text, requirement.path)
        trial = Mod::ModFile.parse(trial_text, manifest_path)
        after = Mod::Installer.selections(dir, trial).to_h { |s| {s.path, s.version} }
        if (lower = after[requirement.path]?) && lower != before[requirement.path]
          kept << {requirement.path, before[requirement.path], lower}
          next
        end
        removed << {requirement.path, requirement.version}
        text = trial_text
        current = trial
      end

      final = Mod::ModFile.parse(text, manifest_path)
      final_selections = Mod::Installer.selections(dir, final)
      fetched = final_selections.reject { |s| final.replacements.has_key?(s.path) }
      stale = Mod::Sum.stale(dir, fetched)

      added.each { |(path, version, file)| puts "#{check_only ? "would add" : "added"} #{path} v#{version}: #{Iyi.relative_filename(file)} imports it" }
      removed.each { |(path, version)| puts "#{check_only ? "would remove" : "removed"} #{path} v#{version}: nothing imports it" }
      kept.each do |(path, version, lower)|
        puts "kept #{path} v#{version}: nothing imports it, but without the line another module's requirement would build v#{lower}"
      end
      unless stale.empty?
        puts "#{check_only ? "would drop" : "dropped"} #{stale.size} iyi.sum #{stale.size == 1 ? "entry" : "entries"} for a version nothing builds"
      end

      changed = !added.empty? || !removed.empty? || !stale.empty?
      unless changed
        puts "iyi.mod and iyi.sum say what the source imports"
        return
      end
      exit 1 if check_only

      File.write(manifest_path, text)
      # What builds now is fetched and recorded, and then only that stays.
      Mod::Installer.resolve(dir, final)
      Mod::Sum.prune(dir, fetched)
    rescue ex : Mod::ModError
      abort! "mod tidy: #{ex.message}", :USAGE_ERROR
    end
  end

  # The longest of *paths* that is *import* or a directory above it.
  private def mod_tidy_cover(imported : String, paths : Array(String)) : String?
    paths.select { |path| imported == path || imported.starts_with?("#{path}/") }.max_by?(&.size)
  end

  # The module an import no requirement covers belongs to: the longest of
  # its prefixes whose repository has a version, tried from the whole path
  # down to two segments, since a host alone is never a module.
  private def mod_tidy_find(imported : String) : {String, SemanticVersion}
    segments = imported.split('/')
    tried = [] of String
    segments.size.downto(2) do |count|
      candidate = segments[0, count].join('/')
      tried << candidate
      begin
        return {candidate, Mod::Fetcher.latest(candidate)}
      rescue Mod::ModError
      end
    end
    raise Mod::ModError.new("no module provides #{imported}: none of #{tried.join(", ")} is a repository with a version tag")
  end

  # The `.iyi` files that are this module's source.
  private def mod_tidy_sources(dir : String) : Array(String)
    found = [] of String
    Dir.each_child(dir) do |entry|
      full = File.join(dir, entry)
      if File.directory?(full)
        next if entry.starts_with?('.') || entry == "lib"
        next if File.file?(File.join(full, Mod::Installer::MANIFEST))
        found.concat(mod_tidy_sources(full))
      elsif entry.ends_with?(".iyi")
        found << full
      end
    end
    found.sort!
  end

  private def mod_tidy_usage
    <<-USAGE
    Usage: #{Command.program_name} mod tidy [--check]

    Make iyi.mod and iyi.sum say what this module's source imports: a
    `require` for each package imported without one - at the version the
    build already selects, or the latest release - none for a package
    nothing imports, unless the line raises a version another module pulls
    in, and no iyi.sum entry for a version nothing builds.

    The source is every .iyi file under this directory, tests included,
    except hidden directories, lib/, and directories with an iyi.mod of
    their own. `--check` writes nothing and exits 1 when a change is due.
    USAGE
  end
end
