# iyi: the piece that turns a manifest into search roots. `iyi build` calls
# this once, before semantic: if the entry file's directory has an
# `iyi.mod`, its requirements are resolved (MVS, resolver.cr), every
# selection is checked out (fetcher.cr), and the program gets a prefix
# table the import resolver consults — longest prefix first, so
# `github.com/user/lib/v2` wins over `github.com/user/lib` when both are
# required, which is how a major version is a different module (III.7).
#
# No manifest, no table, no behaviour change: the manifest is the opt-in.
require "./resolver"
require "./sum"
require "./fetcher"
require "./reach"

module Iyi::Mod
  module Installer
    MANIFEST = "iyi.mod"

    # The prefix table for the program whose entry file sits in
    # *entry_dir*, or an empty one when there is no manifest to serve.
    def self.table_for(entry_dir : String) : Array({String, String})
      manifest_path = File.join(entry_dir, MANIFEST)
      return [] of {String, String} unless File.file?(manifest_path)

      root = ModFile.parse(File.read(manifest_path), manifest_path)
      table = resolve(entry_dir, root).map { |(selection, dir)| {selection.path, dir} }
      # Longest prefix first, so the most specific module answers an import.
      table.sort_by! { |(prefix, _)| -prefix.size }
      table.concat(short_name_rows(root))
      table
    end

    # The short names a manifest gives (`require <path> v1 as web`), as rows
    # of the same table: `{"@web", "<path>"}`. They travel with the prefixes
    # because every verb that compiles already carries the table - a build,
    # `check`, `doc`, `test`, `mod context`, the language server - and no
    # import can start with `@`, so every prefix match passes over them
    # without being told. `expand` is the one reader.
    SHORT_NAME = '@'

    def self.short_name_rows(manifest : ModFile) : Array({String, String})
      manifest.requirements.compact_map do |requirement|
        name = requirement.short_name
        {"#{SHORT_NAME}#{name}", requirement.path} if name
      end
    end

    # *written* with a short name at its front replaced by the path it
    # names in *table*: `web/dsl` is `github.com/sdogruyol/iyi-web/dsl`.
    # Anything else comes back as written.
    def self.expand(written : String, table : Array({String, String})) : String
      first, slash, rest = written.partition('/')
      key = "#{SHORT_NAME}#{first}"
      row = table.find { |(prefix, _)| prefix == key }
      return written unless row
      slash.empty? ? row[1] : "#{row[1]}/#{rest}"
    end

    # A package's own short names, from the manifest at its checkout: its
    # files wrote them, and they mean what its manifest says wherever the
    # package is used. Empty for a directory with no manifest.
    def self.short_names_in(dir : String) : Array({String, String})
      file = File.join(dir, MANIFEST)
      return [] of {String, String} unless File.file?(file)
      short_name_rows(ModFile.parse(File.read(file), file))
    end

    # Every module *root*'s graph selects, with the directory it builds
    # from: its checkout in the cache, or the directory the manifest in
    # *dir* replaces it with. The one resolution every verb uses - a build,
    # `get`, the language server - so a replacement means the same thing to
    # each of them.
    def self.resolve(dir : String, root : ModFile) : Array({Selection, String})
      replaced = replaced_directories(dir, root)
      selections = self.selections(dir, root)

      # Fact against policy, before anything is compiled: every selection's
      # checkout is hashed against `iyi.sum`, a mismatch is a refusal, and a
      # missing entry is recorded — the tool writes facts down (III.7 step 2).
      # A replaced module is none of that: it is a directory somebody is
      # editing, and a hash of it would refuse the next keystroke.
      # A `reaches` limit, before anything is recorded: a version that
      # reaches past what its line allows is refused by name, and neither
      # iyi.sum nor - in a `get` - iyi.mod is written. Paid only by lines
      # that write one.
      root.requirements.each do |requirement|
        next unless allowed = requirement.reaches
        next unless selection = selections.find { |candidate| candidate.path == requirement.path }
        checkout = replaced[selection.path]? || Fetcher.checkout(selection.path, selection.version)
        over = Reach.of(checkout).beyond(allowed)
        next if over.empty?
        raise ModError.new(
          "#{selection} reaches #{over.join(", ")}, which its line in iyi.mod does not allow " \
          "(`reaches #{allowed.empty? ? "nothing" : allowed.join(", ")}`). Add what it now needs to the line if that " \
          "is wanted, or stay on a version that reaches less; `#{Iyi::Command.program_name} mod reach` lists each module's")
      end

      fetched = selections.reject { |selection| replaced.has_key?(selection.path) }
      Sum.check(dir, fetched) do |selection|
        Fetcher.checkout(selection.path, selection.version)
      end

      selections.map do |selection|
        {selection, replaced[selection.path]? || Fetcher.checkout(selection.path, selection.version)}
      end
    end

    # What *root*'s graph selects, and nothing else: no checkout beyond the
    # manifests the walk reads, and `iyi.sum` neither checked nor written.
    # The question `mod tidy` asks of manifests it has not written yet.
    def self.selections(dir : String, root : ModFile) : Array(Selection)
      replaced = replaced_directories(dir, root)
      manifests = {} of String => ModFile
      Resolver.resolve(root) do |path, version|
        if local = replaced[path]?
          manifests[path] ||= local_manifest(path, local, root.replacements[path])
        else
          Fetcher.manifest(path, version)
        end
      end
    end

    # Each replacement's directory, made absolute against the manifest's
    # own directory - `../lib` means beside the project, wherever the build
    # was started from.
    def self.replaced_directories(dir : String, root : ModFile) : Hash(String, String)
      root.replacements.to_h do |path, target|
        {path, File.expand_path(target, dir)}
      end
    end

    # The manifest at a replacement's directory, which has to be the module
    # it stands in for: a directory is not a module until its `iyi.mod`
    # says whose it is, and a replacement pointed at the wrong checkout is
    # the mistake this catches before any import resolves into it.
    private def self.local_manifest(path : String, local : String, written : String) : ModFile
      file = File.join(local, MANIFEST)
      unless File.file?(file)
        detail = Dir.exists?(local) ? "has no iyi.mod" : "does not exist"
        raise ModError.new("replace #{path} => #{written}: #{local} #{detail}; " \
                           "a replacement is a directory holding the module it replaces")
      end
      manifest = ModFile.parse(File.read(file), file)
      unless manifest.path == path
        raise ModError.new("replace #{path} => #{written}: #{file} says it is '#{manifest.path}'; " \
                           "a replacement is the module it replaces, under the same path")
      end
      manifest
    end
  end
end
