# iyi: `iyi migrate SRC --out DIR` — a Crystal source tree written out as
# iyi modules (SPEC.md III.6, "What a migration would need, measured").
#
# Every rule here was found by migrating a real application rather than
# designed, and each is mechanical:
#
#   1. **A Crystal namespace is an iyi path.** `module A::B` wrapping a
#      file, or `class A::B::C` declared at its top, places the file at
#      `a/b/c` — segments spelled the way `Iyi.iyi_module_name` spells
#      them, so `DB` is `d_b` and comes back `DB` — and the wrapper comes
#      off, because the path *is* the namespace.
#   2. **A type's qualified name changes with it.** Every constant path
#      the tree declares is resolved the way Crystal resolves one —
#      innermost namespace outwards, through `include` — and rewritten to
#      the bare name the declaring module exports, under a `using` line.
#      Two modules offering one name: the second stays qualified, and the
#      note says which.
#   3. **What other files reach is `pub`.** A Crystal file cannot say
#      otherwise, and the compiler refuses an unexported name at its use.
#   4. **`require "./x"` is `import`; `require "shard"` stays.** Shard
#      requires are global in Crystal and a module's own here, so every
#      module gets the tree's set.
#   5. **A cycle is one module.** R-1 refuses an import cycle (III.5 rule
#      1) and Crystal's global namespace never had one to refuse, so each
#      strongly connected set of modules is written as one, its members in
#      require order, and named.
#   6. **A reopening of a type the tree does not own stays Crystal.** R-3
#      is the one rule no rewrite satisfies, and it has a mechanical home:
#      a `.cr` file beside the module, `require`d from it, where open
#      classes are Crystal's rule.
#   7. **`!` is III.1.7a's.** `x.not_nil!` becomes `(x || raise …)`, and
#      any other `foo!` its non-bang spelling, each site named in a note
#      because the copy and the mutation are not the same program.
#
# Everything else stays as written — `getter`, `include` into a type,
# `rescue`, macros, an untyped `def` nobody exports — because the
# measurement said it compiles as it is under `--crystal`. What does not
# is reported rather than guessed at: `--check` compiles every module
# written and prints the first refusal of each, which is the list a
# person works through.
#
# Text, not syntax, and the reason it can be: II.3 rule 4 makes the
# header block line-shaped, a Crystal file's namespace wrappers and
# top-level declarations are line-shaped too, and constant paths are
# lexically distinctive. String contents are skipped; a `# comment` is
# left alone. `--check` is what says whether that was enough.
class Iyi::Command
  private def migrate
    out_dir = nil
    check = false
    annotate = false
    verbose = false
    src = nil
    while option = options.first?
      case option
      when "--out"
        options.shift
        out_dir = flag_value!("--out", "a directory")
      when "--check"
        options.shift
        check = true
      when "--annotate"
        options.shift
        annotate = true
      when "--verbose", "-v"
        options.shift
        verbose = true
      when "--help", "-h"
        puts <<-USAGE
          Usage: #{Command.program_name} migrate SRC --out DIR [--annotate] [--check] [--verbose]

          Write every .cr under SRC as an iyi module under DIR: the
          namespace as the path, the wrapper off, `pub` on the top level,
          relative requires as imports, and every constant path this tree
          declares as the bare name its module exports, under a `using`
          line. Import cycles are written as one module; a reopening of a
          type the tree does not own is kept as Crystal in a `.cr` file
          beside its module.

          --annotate write the types R-2 wants where the Crystal never had
                    them, read off the calls the compiler resolved in every
                    program the tree has - each entry file, and the spec
                    suite, which is where a library's calls are. A
                    parameter two of them bound differently is left
                    alone and named, with what is missing
          --check   compile every module written (`check --crystal`) and
                    print the first refusal of each
          --verbose every note, rather than the first few of each kind

          The modules build with `--crystal`, which is the library the tree
          was written against; `#{Command.program_name} bind` puts its shards
          behind a boundary after that. The whole of it, on a project:

              #{Command.program_name} migrate src --out iyi --annotate --check
              cd iyi && #{Command.program_name} build --crystal -o app <entry>.iyi
          USAGE
        exit
      else
        if src
          abort! "migrate: one tree at a time; unexpected '#{option}'", :USAGE_ERROR
        end
        src = options.shift
      end
    end

    src ||= abort!("migrate: which tree? Usage: #{Command.program_name} migrate SRC --out DIR", :USAGE_ERROR)

    # One file at a time, which is the other way to do this. A `.iyi`
    # module may `require` a `.cr` file and not the other way round (R-2
    # and R-3 are what an artifact is made of, and a `.cr` file provides
    # neither), so a project converts *top down*: the file nothing
    # requires becomes a module first, its own requires stay Crystal, and
    # the program keeps building at every step.
    single = nil
    out_named = out_dir
    if File.file?(src) && src.ends_with?(".cr")
      single = File.expand_path(src)
      src = File.dirname(single)
      out_dir ||= src
    end
    abort! "migrate: no such directory: #{src}", :USAGE_ERROR unless Dir.exists?(src)
    out_dir ||= abort!("migrate: --out DIR is where the modules go", :USAGE_ERROR)
    src = File.expand_path(src)
    out_dir = File.expand_path(out_dir)
    # Writing the modules into the tree being read mixes the two languages
    # in one directory and hands the *next* run its own output as source.
    # `--out src` did it, and left a `src/src` behind. One file is the
    # exception: `x.cr` becomes `x.iyi` beside it, which is what converting
    # a file at a time means, and an import prefers the `.iyi`.
    # Asked of `Path` rather than of a string prefix: `--out` and the tree
    # both arrive from `File.expand_path`, which spells them with `\` on
    # Windows, so `starts_with?(src + "/")` answered no for a directory that
    # was inside the tree and the run wrote its modules into its own source.
    if single.nil? && Iyi.path_under?(out_dir, src)
      abort! "migrate: --out #{out_dir} is inside the tree it reads (#{src}); the modules go beside it, not into it", :USAGE_ERROR
    end
    # `--out` naming a file died of `mkdir`'s own "File exists", which
    # names no flag; and a directory that will not take a file died of
    # the first module's "Permission denied".
    if File.exists?(out_dir) && !Dir.exists?(out_dir)
      abort! "migrate: --out needs a directory for the modules, and #{out_dir} is a file", :USAGE_ERROR
    end
    if Dir.exists?(out_dir) && !File.writable?(out_dir)
      abort! "migrate: --out #{out_dir} will not take the modules: no permission to write there", :USAGE_ERROR
    end

    # A project root is not a source tree. A shards project keeps its
    # library in `src` and its *programs* beside the manifest - a spec
    # suite, an `examples/`, a `bin/` - and reading all of them together
    # is what a person never means: pointed at Kemal's root this read 79
    # files instead of 34 and merged 24 of them into one module, because
    # the specs and the examples require each other and the library. The
    # library is migrated and the narrowing is printed; a spec suite or an
    # example directory is migrated by naming it.
    library_root = File.join(src, "src")
    if single.nil? && File.file?(File.join(src, MANIFEST_FILE)) && Dir.exists?(library_root)
      puts "#{src} is a project root, so its library is what is migrated: #{library_root}"
      puts "everything else beside the manifest - a spec suite, an example, a `bin` - is a program of its own; name one to migrate it"
      puts
      src = library_root
    end

    manifest = File.join(File.dirname(src), MANIFEST_FILE)
    if File.file?(manifest)
      @project_name = File.read_lines(manifest).compact_map { |line|
        line.starts_with?("name:") ? line.lchop("name:").strip : nil
      }.first? || ""
    end

    # Walked up to the manifest, because the source root is not always one
    # level down: `src/kemal` is where a person runs the verb on one file,
    # and the `lib` its shards are in is two directories above it.
    project_root = src
    walking = src
    # Up while there is somewhere to go, which is not "up while this is not
    # `/`": `File.dirname` of `C:\` answers `C:\`, so on Windows a tree with
    # no manifest above it walked the same directory for ever and the verb
    # never printed anything at all.
    while !walking.empty?
      up = File.dirname(walking)
      break if up == walking
      if File.file?(File.join(walking, MANIFEST_FILE))
        project_root = walking
        break
      end
      walking = up
    end

    files = single ? [single] : Dir.glob(::Path[src].to_posix.join("**", "*.cr")).sort

    # One file at a time only works from the *top*: a `.cr` file cannot
    # require an iyi module, and a `require` that finds one gets a
    # compilation unit rather than names - so a file something else
    # requires would be defined twice, or not at all. The file nothing
    # requires is the one that can go first, which is a program's entry or
    # a script.
    still_crystal = nil
    if single
      requirers = Dir.glob(::Path[project_root].to_posix.join("**", "*.{cr,iyi}")).sort.reject do |file|
        file == single || shards_install?(file, project_root)
      end.select do |file|
        here = File.dirname(file)
        File.read_lines(file).any? do |line|
          next false unless (match = MigrateUnit::REQUIRE.match(line))
          target = match[1] || ""
          next false unless target.starts_with?('.')
          resolved = File.expand_path(target, here)
          resolved == single || resolved + ".cr" == single ||
            (target.ends_with?("*") && Iyi.path_under?(single, File.dirname(resolved)) != nil)
        end
      end
      # A *module* that requires it is the one that breaks: a `require`
      # that finds a `.iyi` gets a compilation unit and none of its names,
      # so that consumer has to `import` it - which is the whole tree's
      # job. Crystal files are unaffected, because Crystal's own `require`
      # only ever finds the `.cr`, which stays where it is: what they
      # build and what a module builds are then two programs from one
      # source, and that is worth saying rather than discovering.
      by_module = requirers.select(&.ends_with?(".iyi"))
      unless by_module.empty?
        named = by_module.first(4).map { |file| Iyi.path_under?(file, project_root) || file }.join(", ")
        more = by_module.size > 4 ? " and #{by_module.size - 4} more" : ""
        abort! "migrate: #{by_module.size} module#{by_module.size == 1 ? "" : "s"} already require #{Iyi.path_under?(single, project_root) || single} (#{named}#{more}); " \
               "a `require` that finds a `.iyi` gets a compilation unit and none of its names, so that consumer needs an `import` - which is the whole tree's job: " \
               "#{Command.program_name} migrate #{File.dirname(single)} --out DIR", :USAGE_ERROR
      end
      by_crystal = requirers.reject(&.ends_with?(".iyi"))
      unless by_crystal.empty?
        named = by_crystal.first(3).map { |file| Iyi.path_under?(file, project_root) || file }.join(", ")
        more = by_crystal.size > 3 ? " and #{by_crystal.size - 3} more" : ""
        still_crystal = "#{by_crystal.size} Crystal file#{by_crystal.size == 1 ? "" : "s"} still require #{Iyi.path_under?(single, project_root) || single} (#{named}#{more}); they keep reading the `.cr`, which stays where it is - so what they build and what a module builds are two programs over one source until they are migrated too"
      end
    end
    # A shards directory is other projects' source. `shards install`
    # writes it to a `lib/` beside the manifest, and this tree reaches
    # what is in there through its own `require "kemal"`, which becomes
    # an import of `crystal_shards` - not through a copy. `migrate .` on
    # an application read 889 files, 756 of them somebody else's, and
    # merged 359 into one module.
    vendored = files.count { |file| shards_install?(file, src) }
    files.reject! { |file| shards_install?(file, src) }
    abort! "migrate: no .cr under #{src}", :USAGE_ERROR if files.empty?

    # A file that does not parse is not Crystal yet, and a rewrite of its
    # lines is not a module: `module A` with no `end` was written through
    # and noted as "left nested", a finding about the wrong thing. The
    # parser says where, in the words a `--crystal` build would use, and
    # the migration waits for the tree to be a tree.
    files.each do |file|
      parser = Parser.new(migrate_source(file))
      parser.filename = file
      parser.parse
    rescue ex : SyntaxException
      abort! "migrate: #{Iyi.relative_filename(file)}:#{ex.line_number}:#{ex.column_number}: does not parse as Crystal, so there is nothing to migrate yet: #{ex.message}", :CODE_ERROR
    end

    # Which root namespaces are the tree's own, and which belong to the
    # library it is written against. A declaration under a name the library
    # already owns is a reopening (rule 6) whether it is written qualified
    # or not, and the compiler is asked rather than guessed at.
    #
    # Asked about *this tree's* library, not a bare prelude: `HTTP` is not
    # declared until something requires `http/client`, so `module HTTP;
    # struct Headers` - halite reopening Crystal's headers - was read as a
    # module of the tree's own and compiled as a new type, and the module
    # it was written beside then imported it in a cycle. The probe requires
    # everything the tree requires by name; a require this machine cannot
    # resolve takes the probe back to the prelude alone, which is what a
    # tree that does not compile as Crystal gets anyway.
    required_by_tree = Set(String).new
    # The whole source root even for one file: a module is a compilation
    # unit and has to require what it uses, and what one file uses was
    # required by another - `base_log_handler.cr` names `HTTP::Handler`
    # and requires nothing.
    (single ? Dir.glob(::Path[src].to_posix.join("**", "*.cr")).sort.reject { |file| shards_install?(file, src) } : files).each do |file|
      migrate_source(file).each_line do |line|
        next unless (match = MigrateUnit::REQUIRE.match(line))
        target = match[1] || ""
        required_by_tree << target unless target.starts_with?('.') || target.includes?('*')
      end
    end
    library_names = read_library_names(required_by_tree) ||
                    read_library_names(Set(String).new) ||
                    abort!("migrate: could not read Crystal's library to see which names it owns", :CODE_ERROR)

    tree_roots = Set(String).new
    files.each { |file| MigrateUnit.collect_roots(migrate_source(file), tree_roots) }
    tree_roots.reject! { |name| library_names.includes?(name) }

    notes = Notes.new
    still_crystal.try { |message| notes.add "vendored", message }
    notes.add "vendored", "#{vendored} files under a `lib/` beside a manifest are other projects' source and stayed there; this tree reaches them through its own requires" if vendored > 0
    units = files.map { |file| MigrateUnit.read(file, migrate_source(file), src, tree_roots, notes) }
    by_source = units.to_h { |unit| {unit.source, unit} }
    by_namespace = {} of String => MigrateUnit
    units.each { |unit| by_namespace[unit.namespace.join("::")] ||= unit unless unit.namespace.empty? }

    shard_requires = [] of String
    units.each do |unit|
      unit.shard_requires.each { |name| shard_requires << name unless shard_requires.includes?(name) }
    end
    # One file at a time has to carry what the *tree* requires, not what
    # this file wrote: a module is a compilation unit, and
    # `base_log_handler.cr` names `HTTP::Handler` without requiring
    # anything - the require is in the file at the top of the tree. With
    # only its own, the module refused with `undefined constant
    # HTTP::Handler` in code that had not changed.
    if single
      required_by_tree.each { |name| shard_requires << name unless shard_requires.includes?(name) }
    end

    # The symbol table: every constant path the tree declares, and the
    # aliases `include` gives it. `module AcikTurkiye; include Logging`
    # makes `AcikTurkiye::Log` another spelling of `AcikTurkiye::Logging::Log`,
    # which is the lookup Crystal performs and the one reference in this
    # application that nothing else explains.
    exports = {} of String => Export
    units.each do |unit|
      unit.exports.each { |name| exports[unit.qualified(name)] ||= Export.new(unit, name) }
    end
    units.each do |unit|
      unit.includes.each do |included|
        target = resolve_namespace(included, unit, by_namespace)
        next unless target
        prefix = unit.namespace.join("::")
        target.exports.each do |name|
          key = prefix.empty? ? name : "#{prefix}::#{name}"
          exports[key] ||= Export.new(target, name)
        end
      end
    end

    # The directory the *original* program was built from, which is where
    # a template's path is written from: `ECR.embed("src/views/x.ecr")`
    # resolves against the build's working directory, so the copy has to
    # sit at that same path under the migrated tree. This was the process's
    # own cwd, so migrating from anywhere but the project root put every
    # asset under a directory the build does not look in, and the first
    # template refused with `No such file or directory`.
    inferred = annotate ? infer_types(units, src, notes) : nil
    # Every `def` this tree names with a bang, so a call to one is known
    # to be the tree's own: `node.sort!` is a method here and loses the
    # bang, where `array.sort!` is Crystal's and needs the copy assigned
    # back. Gathered over the whole tree, because the call is rarely in
    # the file that defines it.
    tree_bangs = Set(String).new
    units.each do |unit|
      unit.lines.each do |line|
        next unless (match = MigrateUnit::DEF_NAME.match(line))
        name = match[1] || ""
        tree_bangs << name.rchop if name.ends_with?('!')
      end
    end
    tree_sources = Set(String).new
    units.each { |unit| tree_sources << File.expand_path(unit.source) }
    units.each do |unit|
      unit.render(by_source, by_namespace, exports, notes, project_root, inferred, tree_bangs, tree_sources)
    end

    # Before the `pub` pass below, because a sidecar names the tree's
    # types too and what it names has to cross: `HeadRequestHandler`'s
    # `NullIO` is reached from the reopening beside it and from nowhere
    # else, and a `pub` taken off it left the module refusing its own
    # sidecar. The rewrite also records an import per name it reached.
    units.each do |unit|
      next if unit.sidecar.empty?
      unit.sidecar_text = unit.rewrite_sidecar(exports, notes)
    end

    # Everything under the tree that is not Crystal travels with it: a
    # view, a fixture, a JSON file the program reads. A *template* is
    # code — a macro splices it into whichever module renders it — so its
    # constant paths are rewritten too, inside its `<% %>` regions, and
    # the names it ends up using are handed to every module that names a
    # template, since which module renders which is a shard's macro's
    # business rather than something this text can see.
    template_names = MigrateUnit.new(src, "", [] of String, "", [] of String,
      [] of String, [] of String, 0, [] of String, [] of String)
    # One file at a time leaves the tree alone: its assets, its manifest
    # and its `lib` are where they were, and the module is written beside
    # them. Copying them onto themselves is all that would happen.
    assets = 0
    Dir.glob(single ? [] of String : ::Path[src].to_posix.join("**", "*").to_s).sort.each do |file|
      next unless File.file?(file)
      next if file.ends_with?(".cr")
      next if shards_install?(file, src)
      relative_asset = Iyi.path_under?(file, project_root) || file
      target = File.join(out_dir, relative_asset)
      Dir.mkdir_p(File.dirname(target))
      if TEMPLATE_EXTENSIONS.any? { |extension| file.ends_with?(extension) }
        File.write(target, template_names.rewrite_template(File.read(file), exports, notes))
        notes.add "embed", "#{relative_asset} travelled with the tree, its constant paths rewritten"
      else
        File.copy(file, target)
      end
      assets += 1
    end
    # The manifest travels too, because a macro reads it: a shard's
    # `version.cr` is `{{ `shards version #{__DIR__}` }}`, which walks up
    # from the module's own directory looking for `shard.yml`, and a tree
    # written out without one refuses to compile at all. It is the same
    # rule as a template's - what the tree read while it was being built
    # is part of the tree.
    # The shards the tree was written against, reached from the tree that
    # is now written: a migrated `require "exception_page"` is resolved
    # from `./lib` relative to wherever the compiler is run, and the
    # modules are somewhere else - so every module refused with `can't
    # find file 'exception_page'` until a person exported CRYSTAL_PATH by
    # hand. The manifest travels beside this, so `shards install` in the
    # migrated tree replaces the link with its own copy.
    shards_dir = File.join(File.dirname(src), "lib")
    linked = File.join(out_dir, "lib")
    if single.nil? && Dir.exists?(shards_dir) && !File.exists?(linked) && !File.symlink?(linked)
      Dir.mkdir_p(out_dir)
      File.symlink(shards_dir, linked)
      notes.add "vendored", "lib -> #{shards_dir}, the shards this tree requires; `shards install` here writes its own copy over it"
    end

    [MANIFEST_FILE, "shard.lock"].each do |manifest|
      next if single
      source_manifest = File.join(File.dirname(src), manifest)
      next unless File.file?(source_manifest)
      Dir.mkdir_p(out_dir)
      File.copy(source_manifest, File.join(out_dir, manifest))
      notes.add "embed", "#{manifest} travelled with the tree - a macro reads it for the version"
      assets += 1
    end

    used_by_templates = template_names.usings
    unless used_by_templates.empty?
      units.each do |unit|
        next unless unit.body.any? do |line|
                      TEMPLATE_EXTENSIONS.any? { |extension| line.includes?("#{extension}\"") }
                    end
        used_by_templates.each do |imported, names|
          unit.imports << imported
          (unit.usings[imported] ||= Set(String).new).concat(names)
        end
      end
    end

    # `pub` is what *another* module names. Marking every top-level
    # declaration was the first rule and it was too wide: R-2 then asks a
    # signature of every one of them, including a class the tree
    # instantiates nowhere and a helper nobody outside calls, and the
    # types for those cannot be read off a program that never ran them.
    # What the rewrite already knows is exactly which names cross, since
    # it wrote every `using` line and every qualified spelling.
    needed = {} of String => Set(String)
    units.each do |unit|
      unit.usings.each do |target, names|
        (needed[target] ||= Set(String).new).concat(names)
      end
      unit.body.each do |line|
        MigrateUnit.marks(line).each do |(target, name)|
          (needed[target] ||= Set(String).new) << name unless name.empty?
        end
      end
      MigrateUnit.marks(unit.sidecar_text).each do |(target, name)|
        (needed[target] ||= Set(String).new) << name unless name.empty?
      end
    end
    kept_in = 0
    units.each do |unit|
      wanted = needed[unit.path]? || Set(String).new
      unit.pub_sites.each do |(index, name, source_line)|
        next if wanted.includes?(name)
        # A program called it, which for a library is the only surface
        # there is: `Valid.email?` is called by validator's own specs and
        # by nothing in its `src`, so taking `pub` off left a migrated
        # library whose whole API was unreachable - it compiled, module by
        # module, and answered nothing from outside.
        next if inferred.try(&.called?({unit.source, source_line}))
        line = unit.body[index]?
        next unless line && line.starts_with?("pub ")
        unit.body[index] = line.lchop("pub ")
        kept_in += 1
      end
    end
    notes.add "unexported", "#{kept_in} declarations no other module names stayed the module's own, so R-2 asks nothing of them" if kept_in > 0

    # Which module asks R-2's question of which name, so the list below
    # can say why a def has to carry types and not only that it must.
    askers = {} of {String, String} => Set(String)
    units.each do |unit|
      unit.usings.each do |target, names|
        names.each { |name| (askers[{target, name}] ||= Set(String).new) << unit.path }
      end
      unit.body.each do |line|
        MigrateUnit.marks(line).each do |(target, name)|
          (askers[{target, name}] ||= Set(String).new) << unit.path unless name.empty?
        end
      end
    end
    units.each { |unit| unit.note_untyped_surface(notes, askers) }

    # A cycle is one unit of compilation whatever its files were - and
    # merging one can *make* a cycle, which is why this repeats until it
    # cannot. `shards.cr` requires `commands/*`, `commands/build` reaches
    # `commands/command`, and `command` is in a cycle with `shards`: the
    # first merge joined those two and left `M -> build -> M`, an import
    # cycle in a tree that had none, refused by R-1 in fourteen modules.
    remap = {} of String => String
    merged = {} of String => Array(String)
    holders = {} of String => Array(MigrateUnit)
    units.each { |unit| (holders[unit.path] ||= [] of MigrateUnit) << unit }
    loop do
      graph = {} of String => Set(String)
      holders.each do |node, members|
        edges = Set(String).new
        members.each do |member|
          member.imports.each do |imported|
            target = remap[imported]? || imported
            edges << target if target != node && holders.has_key?(target)
          end
        end
        graph[node] = edges
      end
      cycles = strongly_connected_paths(graph).select { |nodes| nodes.size > 1 }
      break if cycles.empty?
      cycles.each do |nodes|
        members = nodes.flat_map { |node| holders[node] }.sort_by { |unit| units.index(unit) || 0 }
        path = merged_path(members)
        nodes.each { |node| holders.delete(node) }
        holders[path] = members
        members.each { |member| remap[member.path] = path }
        merged[path] = members.map(&.path)
      end
    end
    merged.each do |path, members|
      notes.add "cycle", "#{path} is #{members.size} files R-1 cannot separate (#{members.join(", ")}); split it by moving what the later ones reach for into one module they can all import"
    end

    written = {} of String => String
    written_paths = {} of String => String
    modules = {} of String => Array(MigrateUnit)
    units.each { |unit| (modules[remap[unit.path]? || unit.path] ||= [] of MigrateUnit) << unit }
    modules.each do |module_path, members|
      members = required_first(members, by_source) if members.size > 1
      imports = Set(String).new
      usings = {} of String => Set(String)
      members.each do |member|
        member.imports.each do |imported|
          target = remap[imported]? || imported
          imports << target unless target == module_path
        end
        member.usings.each do |imported, names|
          target = remap[imported]? || imported
          next if target == module_path
          (usings[target] ||= Set(String).new).concat(names)
        end
      end

      sidecars = members.reject(&.sidecar.empty?)
      sidecars.each do |member|
        sidecar_path = File.join(out_dir, File.dirname(module_path), "#{File.basename(member.path)}_crystal.cr")
        Dir.mkdir_p(File.dirname(sidecar_path))
        # `""` for the module path, because a sidecar is outside every
        # module: no name collapses to the bare spelling, all of them are
        # written in full.
        File.write(sidecar_path,
          "# Reopenings of types this tree does not own, kept as Crystal: R-3 closes\n" \
          "# a type where it is written, and these are somebody else's (SPEC.md III.6).\n" +
          MigrateUnit.resolve_marks(member.sidecar_text, remap, "").strip + "\n")
      end

      written[module_path] = String.build do |io|
        io << "module " << module_path << "\n\n"
        shard_requires.each { |name| io << "require \"" << name << "\"\n" }
        # A shard's top-level code runs once, in whichever module the
        # compiler required it from first — and `pg` registering its
        # driver there is a program that opens a connection before the
        # registration when that module is not the first initialised.
        # III.5 makes an import's initialiser run before its importer's,
        # so one module requires the shards and every other imports it:
        # the effects land in a module that is initialised first, by rule
        # rather than by the order files happened to compile in.
        io << "import " << SHARDS_MODULE << '\n' if single.nil? && !shard_requires.empty? && module_path != SHARDS_MODULE
        # One file at a time: what it required stays required, because
        # those files are still Crystal. A `.iyi` module may require a
        # `.cr` file; the other direction is what R-2 and R-3 forbid.
        if single
          members.each do |member|
            # Relative to where this module is *written*, which is beside
            # the source unless `--out` said otherwise.
            here = out_named.nil? ? File.dirname(single) : File.expand_path(File.dirname(module_path), out_dir)
            member.required_paths(here).each { |path| io << "require \"" << path << "\"\n" }
          end
        end
        sidecars.each { |member| io << "require \"./" << File.basename(member.path) << "_crystal.cr\"\n" }
        io << '\n' unless shard_requires.empty? && sidecars.empty?
        imports.to_a.sort.each { |imported| io << "import " << imported << '\n' }
        usings.to_a.sort_by(&.[0]).each do |(imported, names)|
          io << "using " << imported << "::{" << names.to_a.sort.join(", ") << "}\n"
        end
        io << '\n' unless imports.empty?
        members.each do |member|
          io << "# ── " << member.relative << " ──\n\n" if members.size > 1
          text = MigrateUnit.resolve_marks(member.body.join('\n').strip, remap, module_path)
          io << text << '\n'
          io << '\n' if members.size > 1
        end
      end
    end

    if single.nil? && !shard_requires.empty?
      written[SHARDS_MODULE] = String.build do |io|
        io << "# The shards this tree was written against, required once and\n"
        io << "# imported by every module: III.5 initialises an import before\n"
        io << "# its importer, so a shard's top-level code — `pg` registering\n"
        io << "# its driver — runs before anything that uses it.\n"
        io << "module " << SHARDS_MODULE << "\n\n"
        shard_requires.each { |name| io << "require \"" << name << "\"\n" }
      end
    end

    written.each do |module_path, text|
      # One file at a time goes *beside* its source, under its own name.
      # The header still says `module kemal/base_log_handler`, which is
      # what an importer writes and where the file already sits under the
      # tree's source root - `out_dir/kemal/base_log_handler.iyi` from a
      # run inside that directory made a second `kemal/` under it.
      target =
        if single && out_named.nil?
          File.join(File.dirname(single), "#{File.basename(module_path)}.iyi")
        else
          File.join(out_dir, "#{module_path}.iyi")
        end
      Dir.mkdir_p(File.dirname(target))
      File.write(target, text)
      written_paths[module_path] = target
    end

    if single
      puts "#{Iyi.relative_filename(single)} → #{Iyi.relative_filename(written_paths.values.first? || "")}"
      puts "its own requires stayed Crystal: those files are still the other language, and a module may require them"
    else
      # The directory as it is, without a separator glued on the end to say
      # it is one: that separator is only the platform's on posix, and the
      # sentence read `under C:\...\out1/` on Windows.
      puts "#{units.size} files → #{written.size} modules under #{out_dir}"
    end
    if verbose
      units.each do |unit|
        target = remap[unit.path]? || unit.path
        also = target == unit.path ? "" : " (one of #{merged[target].size})"
        puts "  #{unit.relative} → #{target}.iyi#{also}"
      end
    end
    notes.print(verbose)

    if check
      puts
      puts "checking every module against Crystal's library:"
      executable = Process.executable_path || abort!("migrate: cannot find the compiler's own executable", :USAGE_ERROR)
      clean = [] of String
      broke = [] of {String, String}
      written.keys.sort.each do |module_path|
        output = IO::Memory.new
        # From the migrated tree, which is a project of its own: the
        # templates a macro embeds were copied into it at the paths their
        # `embed` names, and their constant paths were rewritten with the
        # module that embeds them.
        # One file at a time is checked where it sits, from the project's
        # own root: its `require`s are relative to it and its shards are
        # under the root's `lib`, both of which the tree it belongs to
        # already resolves.
        written_at = written_paths[module_path]
        where_from = single ? project_root : out_dir
        status = Process.run(executable,
          ["check", "--crystal", "--no-color", written_at],
          chdir: where_from, output: output, error: output)
        if status.success?
          clean << module_path
        else
          text = output.to_s
          at = text.lines.index { |line| line.starts_with?("Error:") }
          message = (at ? text.lines[at] : text.lines.last?) || "(no message)"
          where = at ? text.lines[0...at].reverse.find(&.starts_with?("In ")).try(&.lchop("In ").strip) : nil
          via = where && !where.starts_with?("#{module_path}.iyi") ? " (in #{where})" : ""
          broke << {module_path, message.lchop("Error: ").strip + via}
        end
      end
      broke.each { |(module_path, message)| puts "  #{module_path}: #{message}" }
      puts "#{clean.size} of #{written.size} modules compile; #{broke.size} carry what is listed above"

      # Whose each refusal is, because the three are worked on by different
      # people. A missing `require` is the *environment's*: the source tree
      # does not compile here either, and `shards install` is the answer, not
      # a rewrite. R-2's question is the *author's*. What is left is this
      # verb's, and that is the count worth reading first.
      unless broke.empty?
        missing = Set(String).new
        asks = 0
        mixins = 0
        mine = 0
        broke.each do |(_, message)|
          if (at = message.index("can't find file '"))
            rest = message[(at + "can't find file '".size)..]
            missing << (rest.index('\'').try { |close| rest[0, close] } || rest)
          elsif message.includes?("is exported and does not say what")
            asks += 1
          elsif message.includes?("extends it") || message.includes?("is not a module, it's a")
            # A module mixed into a type: iyi spells that a trait and an
            # `impl`, this verb does not write those, and the notes above
            # name every site. The compiler's own message for it names a
            # module extending itself, which points nowhere useful.
            mixins += 1
          else
            mine += 1
          end
        end
        puts
        unless missing.empty?
          puts "#{broke.size - asks - mine} of them are a `require` this machine cannot resolve " \
               "(#{missing.to_a.sort.join(", ")}): the tree does not compile as Crystal here either, so `shards install` comes first"
        end
        puts "#{asks} #{asks == 1 ? "is" : "are"} R-2 asking for a signature, which is a person's to write: the list above says which name and why" if asks > 0
        puts "#{mixins} #{mixins == 1 ? "is a module mixed" : "are modules mixed"} into a type, which iyi spells as a `trait` and an `impl` (SPEC.md II.6): the notes above name every site, and this verb does not rewrite them" if mixins > 0
        puts "#{mine} #{mine == 1 ? "is" : "are"} neither, and that is the migration's own: please report it with the module and the message" if mine > 0
      end
      exit 1 unless broke.empty?
      if single
        written_path = written_paths.values.first? || ""
        puts
        puts "#{Iyi.path_under?(written_path, project_root) || written_path} is a module now, and the rest of the tree is still Crystal."
        puts "Convert top down: the next file is one that requires this one, since a `.iyi` module may require a `.cr` file and not the other way round."
        return
      end
      entry = written.keys.find { |module_path| !module_path.includes?('/') && module_path != SHARDS_MODULE }
      puts
      puts "the tree is iyi's now. From #{out_dir}:"
      puts "  #{Command.program_name} build --crystal -o app #{entry || "<entry>"}.iyi"
      puts "  #{Command.program_name} check --crystal <one module>.iyi        # what an editor asks per change"
      puts "  #{Command.program_name} bind                                     # the shards behind a boundary, next"
    elsif single
      written_path = written_paths.values.first? || ""
      puts
      puts "next: #{Command.program_name} check --crystal #{Iyi.path_under?(written_path, project_root) || written_path}   # from #{project_root}"
    else
      puts
      puts "next: #{Command.program_name} migrate #{src} --out #{out_dir} --check"
    end
  end

  # A flag's value, which is not the flag written after it. `--out` only
  # tested for the end of argv, so `migrate tree --out --check` took
  # `--check` for the directory, made one by that name and exited 0.
  # `bind.cr` calls this for `--mods` and `--lib`, which had it too.
  private def flag_value!(flag : String, what : String) : String
    value = options.shift? || abort!("#{flag} takes #{what}", :USAGE_ERROR)
    if value.starts_with?('-')
      abort! "#{flag} takes #{what}, and #{value} is a flag", :USAGE_ERROR
    end
    value
  end

  # A file's text, and the one place this verb decides the bytes are text at
  # all. `File.read` hands back whatever bytes are in the file and never
  # raises; the rewriting below walks the text character by character, and
  # every byte sequence that is not UTF-8 comes out of that as U+FFFD - so a
  # file carrying four stray bytes was written into the output with four
  # replacement characters where they had been, and the run reported success.
  # A migration is a copy of what it reads, and a file this is true of does
  # not compile as Crystal either, so it is refused by name rather than
  # rewritten.
  private def migrate_source(file : String) : String
    text = File.read(file)
    unless text.valid_encoding?
      abort! "migrate: file '#{Iyi.relative_filename(file)}' is not a valid Crystal source file: " \
             "it holds bytes that are not UTF-8 text, and a migration copies the bytes it reads", :USAGE_ERROR
    end
    text
  end

  # One name a module exports, and the module.
  record Export, unit : MigrateUnit, name : String

  # The module that owns the tree's shard requires.
  SHARDS_MODULE = "crystal_shards"

  # The manifest a `shards version` macro walks up the tree to read.
  MANIFEST_FILE = "shard.yml"

  # What counts as code a macro splices rather than data a program reads.
  TEMPLATE_EXTENSIONS = %w(.ecr .slang .slim .mustache .cr.erb)

  # Notes, grouped by kind so a hundred files do not print a hundred
  # variations of one finding.
  class Notes
    getter groups = {} of String => Array(String)

    def add(kind : String, note : String) : Nil
      list = @groups[kind] ||= [] of String
      list << note unless list.includes?(note)
    end

    HEADINGS = {
      "cycle"      => "import cycles, written as one module each",
      "require"    => "relative requires of files the tree does not have, dropped",
      "reopen"     => "reopenings of types this tree does not own, kept as Crystal",
      "collide"    => "one name offered by two modules, the second left qualified",
      "bang"       => "`!` is III.1.7a's: rewritten, and worth reading",
      "include"    => "`include` of a namespace, which is a `using` line here",
      "nested"     => "modules left nested, which nothing outside can reach",
      "mixin"      => "a module mixed into a type, which is a trait here and needs a person",
      "untyped"    => "exports whose types the compiler still has to be told",
      "annotate"   => "types written from what the calls said (--annotate)",
      "unexported" => "declarations no other module names, left unexported",
      "embed"      => "templates embedded at compile time, named from the project root",
      "vendored"   => "what is not this tree's to migrate, and what is",
    }

    def print(verbose : Bool) : Nil
      return if @groups.empty?
      HEADINGS.each do |kind, heading|
        list = @groups[kind]?
        next unless list
        puts
        puts "#{heading} (#{list.size}):"
        shown = verbose ? list : list.first(6)
        shown.each { |note| puts "  #{note}" }
        puts "  … and #{list.size - shown.size} more (--verbose)" if list.size > shown.size
      end
    end
  end

  # The types the tree's own calls say its untyped parameters are. The
  # program is compiled once, as Crystal, from the file nothing requires —
  # the entry — because that is the compile that resolves every call.
  private def infer_types(units : Array(MigrateUnit), src : String, notes : Notes) : ParamTypes?
    required = Set(String).new
    by_source = units.to_h { |unit| {unit.source, unit} }
    units.each { |unit| unit.required_units(by_source).each { |target| required << target.source } }
    entries = units.reject { |unit| required.includes?(unit.source) }
    # Every file nothing requires is a program of its own — the app, a
    # migration runner, a seeder — and a def only one of them calls is
    # typed only there. All of them are read, and the readings merged.
    programs = entries.map { |entry| {entry.relative, entry.source, File.read(entry.source)} }

    # A library has no program of its own, and its specs are the calls it
    # was written for: `spec/jwt_spec.cr` requires the shard and hands its
    # methods arguments, which is the reading R-2 wants. The suite is
    # compiled the way it runs, as one program, because a front end per
    # file would cost a minute on a project with fifty of them.
    spec_dir = File.join(File.dirname(src), "spec")
    specs = Dir.glob(::Path[spec_dir].to_posix.join("**", "*_spec.cr")).sort
    unless specs.empty?
      # Named one by one rather than as `spec/**`, because the requires are
      # resolved from this source's own directory and a glob of them is
      # not: the file is written into the spec directory so every relative
      # `require` inside a spec still means what it meant.
      suite = String.build do |io|
        specs.each do |spec|
          # The path is native so it can be chopped against `spec_dir`, and
          # posix again inside the `require`: that string is Crystal's to
          # resolve, and its grammar has one separator.
          io << %(require ".) << ::Path[spec.lchop(spec_dir).rchop(".cr")].to_posix << %("\n)
        end
      end
      programs << {"#{specs.size} spec file#{specs.size == 1 ? "" : "s"}",
                   File.join(spec_dir, "iyi-migrate-specs.cr"), suite}
    end

    if programs.empty?
      notes.add "annotate", "every file is required by another and there are no specs, so there is no program to read: --annotate needs one"
      return nil
    end

    merged = nil
    read = [] of String
    programs.each do |(name, filename, text)|
      compiler = Compiler.new
      compiler.no_codegen = true
      compiler.stdout = IO::Memory.new
      compiler.stderr = IO::Memory.new
      begin
        result = compiler.compile(
          Compiler::Source.new(filename, text),
          File.tempname("iyi-migrate-types", nil))
      rescue ex : CodeError | Iyi::Error
        notes.add "annotate", "#{name} does not compile as Crystal, so its calls said nothing: #{ex.message.to_s.lines.first?}"
        next
      end
      types = Iyi.param_types(result)
      read << name
      if first = merged
        first.merge!(types)
      else
        merged = types
      end
    end
    notes.add "annotate", "read from #{read.size} program#{read.size == 1 ? "" : "s"}: #{read.join(", ")}" unless read.empty?
    merged
  end

  # A cycle's members in require order: what a member required comes
  # first, so an `include` follows the module it names.
  private def required_first(members : Array(MigrateUnit), by_source : Hash(String, MigrateUnit)) : Array(MigrateUnit)
    member_set = members.to_set
    ordered = [] of MigrateUnit
    seen = Set(MigrateUnit).new
    visit = uninitialized Proc(MigrateUnit, Nil)
    visit = ->(unit : MigrateUnit) : Nil do
      return unless seen.add?(unit)
      before, after = unit.requires_split(by_source)
      before.each { |required| visit.call(required) if member_set.includes?(required) }
      ordered << unit
      after.each { |required| visit.call(required) if member_set.includes?(required) }
    end
    members.each { |member| visit.call(member) }
    ordered
  end

  # The type names a program that requires *these* names declares, or nil
  # when that program does not compile - a shard that is not installed, a
  # `require` with a path this machine does not have.
  private def read_library_names(requires : Set(String)) : Set(String)?
    probe = Compiler.new
    probe.no_codegen = true
    probe.stdout = IO::Memory.new
    probe.stderr = IO::Memory.new
    source = requires.to_a.sort.join { |name| "require \"#{name}\"\n" }
    result = probe.compile(
      Compiler::Source.new(File.join(Dir.tempdir, "iyi-migrate-probe.cr"), source),
      File.tempname("iyi-migrate", nil))
    (result.program.types?.try(&.keys) || [] of String).to_set
  rescue ex : CodeError | Iyi::Error
    nil
  end

  # Whether this file is in a shards install directory: a `lib/` with a
  # manifest beside it, which is where `shards install` puts the source of
  # every project this one depends on. A `lib` a person wrote themselves,
  # with no manifest above it, is their code and is migrated.
  private def shards_install?(file : String, src : String) : Bool
    dir = File.dirname(file)
    while dir.size > src.size && dir.starts_with?(src)
      if File.basename(dir) == "lib" && File.file?(File.join(File.dirname(dir), MANIFEST_FILE))
        return true
      end
      dir = File.dirname(dir)
    end
    false
  end

  # `include Logging` inside `module AcikTurkiye`: the namespace it names,
  # resolved outwards the way Crystal resolves a constant.
  private def resolve_namespace(name : String, from : MigrateUnit, by_namespace : Hash(String, MigrateUnit)) : MigrateUnit?
    name = name.lchop("::")
    from.namespace.size.downto(0) do |depth|
      prefix = from.namespace[0, depth]
      candidate = (prefix + name.split("::")).join("::")
      if unit = by_namespace[candidate]?
        return unit unless unit == from
      end
    end
    nil
  end

  # Tarjan's strongly connected components over the import graph.
  # Tarjan's strongly connected components over a graph of module paths,
  # which is what the merge condenses one round at a time.
  private def strongly_connected_paths(graph : Hash(String, Set(String))) : Array(Array(String))
    index = 0
    indices = {} of String => Int32
    lowlink = {} of String => Int32
    on_stack = Set(String).new
    stack = [] of String
    components = [] of Array(String)
    visit = uninitialized Proc(String, Nil)
    visit = ->(path : String) : Nil do
      indices[path] = lowlink[path] = index
      index += 1
      stack << path
      on_stack << path
      (graph[path]? || Set(String).new).each do |next_path|
        next unless graph.has_key?(next_path)
        if !indices.has_key?(next_path)
          visit.call(next_path)
          lowlink[path] = Math.min(lowlink[path], lowlink[next_path])
        elsif on_stack.includes?(next_path)
          lowlink[path] = Math.min(lowlink[path], indices[next_path])
        end
      end
      if lowlink[path] == indices[path]
        component = [] of String
        loop do
          popped = stack.pop
          on_stack.delete(popped)
          component << popped
          break if popped == path
        end
        components << component
      end
    end
    graph.each_key { |path| visit.call(path) unless indices.has_key?(path) }
    components
  end

  private def strongly_connected(units : Array(MigrateUnit)) : Array(Array(MigrateUnit))
    by_path = units.to_h { |unit| {unit.path, unit} }
    index = 0
    indices = {} of String => Int32
    lowlink = {} of String => Int32
    on_stack = Set(String).new
    stack = [] of String
    components = [] of Array(MigrateUnit)
    visit = uninitialized Proc(String, Nil)
    visit = ->(path : String) : Nil do
      indices[path] = lowlink[path] = index
      index += 1
      stack << path
      on_stack << path
      (by_path[path]?.try(&.imports) || Set(String).new).each do |next_path|
        next unless by_path.has_key?(next_path)
        if !indices.has_key?(next_path)
          visit.call(next_path)
          lowlink[path] = Math.min(lowlink[path], lowlink[next_path])
        elsif on_stack.includes?(next_path)
          lowlink[path] = Math.min(lowlink[path], indices[next_path])
        end
      end
      if lowlink[path] == indices[path]
        component = [] of MigrateUnit
        loop do
          popped = stack.pop
          on_stack.delete(popped)
          component << by_path[popped]
          break if popped == path
        end
        components << component.sort_by { |unit| units.index(unit) || 0 }
      end
    end
    units.each { |unit| visit.call(unit.path) unless indices.has_key?(unit.path) }
    components
  end

  # One path for a cycle's modules: their common directory, then their own
  # names joined, or the first and "and_others" when that runs long.
  # The name the manifest gives the project, which is the name of the file
  # every other one is reached through when a tree cannot be separated.
  @project_name = ""

  private def merged_path(members : Array(MigrateUnit)) : String
    dirs = members.map { |member| member.path.includes?('/') ? File.dirname(member.path) : "" }
    common = dirs.first.split('/')
    dirs.each do |dir|
      parts = dir.split('/')
      common = common.zip?(parts).take_while { |(a, b)| a == b }.map(&.[0])
    end
    stems = members.map { |member| File.basename(member.path) }.sort
    name = stems.join('_')
    if name.size > 40
      # The name a person would give the merged unit is the project's own:
      # the manifest says `name: kemal`, and one of these files is
      # `kemal.cr`. Joining the stems alphabetically called the twenty-four
      # files of a framework `cli_and_others`, which names nothing.
      own = @project_name
      root = members.find { |member| File.basename(member.path) == own } ||
             members.min_by { |member| {member.path.count('/'), member.path.size, member.path} }
      name = "#{File.basename(root.path)}_and_others"
    end
    prefix = common.reject(&.empty?).join('/')
    prefix.empty? ? name : "#{prefix}/#{name}"
  end

  # One Crystal file, read for what places it, what it declares, and what
  # it reaches for.
  class MigrateUnit
    getter source : String
    getter relative : String
    getter namespace : Array(String)
    getter path : String
    getter exports : Array(String)
    getter includes : Array(String)
    getter lines : Array(String)
    getter wrappers : Int32
    getter shard_requires : Array(String)
    # Reopenings of types the tree does not own, kept as Crystal.
    getter sidecar : Array(String)
    # The sidecar with the tree's own paths written in full, and the
    # markers the driver resolves once the merges are known.
    property sidecar_text : String = ""
    getter imports = Set(String).new
    getter usings = {} of String => Set(String)
    getter body = [] of String
    # Where a `pub` was written and what it exports, so the driver can
    # take it back off: what no other module names is not the module's
    # surface, and R-2 asks a signature only of what is.
    # Where a `pub` was written, what it exports, and which line of the
    # source it came from - the last so the driver can ask whether any
    # program called it.
    getter pub_sites = [] of {Int32, String, Int32}

    # Through `Iyi::Rx`, the compiler's own engine, and not Crystal's
    # `Regex`: pcre2 is on the list iyi means to need nothing from, and
    # `bench/dependency_floor.sh` fails the build when a file here puts it
    # back on the link line (SPEC.md III.10, Appendix B #17).
    # A class or struct declaration with a superclass, for the one case
    # where the two names are the same.
    SELF_SUPER = Rx::Pattern.compile("^[ \\t]*(?:pub[ \\t]+)?(?:(?:private|protected)[ \\t]+)?(?:abstract[ \\t]+)?(class|struct)[ \\t]+([A-Z][A-Za-z0-9_]*)[ \\t]*<[ \\t]*([A-Z][A-Za-z0-9_]*)[ \\t]*$")
    DECL       = Rx::Pattern.compile("^([ \\t]*)(?:(private|protected)[ \\t]+)?(?:abstract[ \\t]+)?(class|struct|module|enum|alias|annotation|lib)[ \\t]+([A-Z][A-Za-z0-9_:]*)")
    DEF        = Rx::Pattern.compile("^([ \\t]*)(?:(private|protected)[ \\t]+)?(def|macro)[ \\t]+(?:self\\.)?([A-Za-z0-9_?!=<>+*/%\\[\\]-]+)")
    CONST      = Rx::Pattern.compile("^([ \\t]*)([A-Z][A-Za-z0-9_]*)[ \\t]*=[^=]")
    REQUIRE    = Rx::Pattern.compile("^[ \\t]*require[ \\t]+\"([^\"]+)\"")
    INCLUDE    = Rx::Pattern.compile("^([ \\t]*)(?:include|extend)[ \\t]+(::)?([A-Z][A-Za-z0-9_:]*)[ \\t]*$")
    MODULE     = Rx::Pattern.compile("^[ \\t]*module[ \\t]+([A-Z][A-Za-z0-9_:]*)[ \\t]*$")
    PATH       = Rx::Pattern.compile("^(::)?[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)+")
    # `Shop::Names.title(x)` and `Shop.banner`: a namespace and a method
    # of it, which is how a module function is called in the other language
    # and is not a constant path.
    PATH_CALL = Rx::Pattern.compile("^(::)?[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\\.[a-z_][A-Za-z0-9_]*[?!]?")
    BANG      = Rx::Pattern.compile("\\.([a-z_]+)!")
    # `getter! x : T` and `property! x : T`: Crystal's accessor whose
    # reader raises where nil, which is `not_nil!` written by a macro.
    BANG_ACCESSOR      = Rx::Pattern.compile("^([ \\t]*)((?:private|protected)[ \\t]+)?(getter|property)!\\s+([a-z_][A-Za-z0-9_]*)\\s*:\\s*(.+)$")
    BANG_ACCESSOR_BARE = Rx::Pattern.compile("^[ \\t]*(?:(?:private|protected)[ \\t]+)?(getter|property)!\\s+(.+)$")
    # A bang call that is the whole statement, on a name that can be
    # assigned to: an identifier, an `@ivar`, or a dotted path of them.
    BANG_STATEMENT = Rx::Pattern.compile("^([ \\t]*)(@?[a-z_][A-Za-z0-9_]*(?:\\.[a-z_][A-Za-z0-9_]*)*)\\.([a-z_][A-Za-z0-9_]*)!((?:\\(.*\\))?(?:\\s*(?:\\{.*\\}|do\\b.*))?)\\s*$")
    # A call to a bang method with no receiver written - `validate_typ!(x)`
    # inside the type that defines it. Only rewritten for names this tree
    # defines, which is what keeps `!=`, a prefix `!` and a `"boom!"` out.
    BARE_BANG = Rx::Pattern.compile("(^|[^.\\w@:$])([a-z_][A-Za-z0-9_]*)!")
    # A def's or a macro's own name, bang and all: a macro cannot carry a
    # `!` either, and `macro is!` is called as `is!(...)` from the module
    # that defines it and from the ones that import it.
    DEF_NAME = Rx::Pattern.compile("^\\s*(?:private\\s+|protected\\s+)?(?:abstract\\s+)?(?:def|macro)\\s+(?:self\\.)?([A-Za-z_][A-Za-z0-9_]*[?!]?)")
    EXPORTED = Rx::Pattern.compile("^pub def[ \\t]+([A-Za-z0-9_?!]+)\\(([^)]*)\\)")

    def initialize(@source, @relative, @namespace, @path, @exports, @includes,
                   @lines, @wrappers, @shard_requires, @sidecar)
    end

    # Every root namespace a file declares unqualified: the tree's own. Reads
    # the text the command has already read and checked rather than the file.
    def self.collect_roots(source : String, into : Set(String)) : Nil
      source.each_line do |line|
        next unless (match = DECL.match(line)) && (match[1] || "").empty?
        name = match[4] || ""
        into << name unless name.includes?("::") || name.empty?
      end
    end

    def self.read(file : String, source : String, root : String, tree_roots : Set(String), notes : Notes) : MigrateUnit
      all = source.split('\n')
      relative = Iyi.path_under?(file, root) || file
      # A file name is not a module name: `micrate-wrapper.cr` gave
      # `module micrate-wrapper`, which parses as a subtraction and left
      # the module refusing its own header. Everything a name cannot
      # carry becomes `_`, which is what the path already is.
      stem = File.basename(file, ".cr").gsub { |char|
        char.ascii_alphanumeric? || char == '_' ? char : '_'
      }

      # Rule 6 first, because a reopening at the end of a file is what
      # stops the module before it from being read as the file's wrapper.
      lines = [] of String
      sidecar = [] of String
      inside = nil
      all.each do |line|
        if indent = inside
          sidecar << line
          inside = nil if line.strip == "end" && (line.size - line.lstrip.size) == indent
          next
        end
        if (match = DECL.match(line)) && (match[1] || "").empty? &&
           !tree_roots.includes?((match[4] || "").split("::").first)
          inside = 0
          sidecar << line
          notes.add "reopen", "#{relative}: `#{match[3]} #{match[4]}`"
          next
        end
        lines << line
      end

      wrappers = [] of String
      index = 0
      while index < lines.size
        line = lines[index]
        stripped = line.strip
        if stripped.empty? || stripped.starts_with?('#') || stripped.starts_with?("require ")
          index += 1
          next
        end
        # A wrapper is a `module` whose `end` closes what encloses it:
        # peeled one at a time, so `module Shop` around `module Counter`
        # around the code is the path `shop/counter` and neither line
        # stays in the file. A module left nested cannot be `pub` —
        # nothing outside could reach into it — so peeling is what makes
        # the namespace addressable.
        if (match = MODULE.match(line)) && closes_block?(lines, index, wrappers.size)
          wrappers << (match[1] || "")
          index += 1
          next
        end
        break
      end
      namespace = wrappers.flat_map(&.split("::"))

      declared_name = nil
      lines[index..].each do |line|
        next if line.strip.empty? || line.strip.starts_with?('#')
        if (match = DECL.match(line)) && (match[1] || "").empty?
          declared_name = match[4]
        end
        break
      end
      if declared_name && declared_name.includes?("::") && namespace.empty?
        parts = declared_name.split("::")
        namespace = parts[0..-2]
        declared_name = parts.last
      end

      depth = wrappers.size * 2
      exports = [] of String
      includes = [] of String
      lines[index..].each do |line|
        next unless (line.size - line.lstrip.size) == depth
        if match = DECL.match(line)
          next if match[2] == "private"
          exports << (match[4] || "").split("::").last
        elsif match = DEF.match(line)
          next if match[2] == "private" || match[2] == "protected"
          exports << (match[4] || "")
        elsif match = CONST.match(line)
          exports << (match[2] || "")
        elsif match = INCLUDE.match(line)
          includes << (match[3] || "")
        end
      end
      exports.uniq!

      segments = namespace.map { |segment| Iyi.iyi_module_name(segment) }
      own =
        if declared_name && !declared_name.includes?("::") && exports.size == 1 && exports.first == declared_name
          Iyi.iyi_module_name(declared_name)
        elsif !wrappers.empty? && Iyi.iyi_module_name(namespace.last).delete('_') == stem.delete('_').downcase
          nil
        else
          stem
        end
      path = (own ? segments + [own] : segments).join("/")
      path = stem if path.empty?

      shard_requires = lines.compact_map do |line|
        (match = REQUIRE.match(line)) && !(match[1] || "").starts_with?('.') ? match[1] : nil
      end.uniq

      new(file, relative, namespace, path, exports, includes, lines,
        wrappers.size, shard_requires, sidecar)
    end

    # Whether the block opened at `index` closes the region `peeled`
    # wrappers deep: its `end` is the last line before those wrappers'
    # own `end`s, and everything between sits deeper. That makes it the
    # region's only construct — a wrapper, as opposed to a declaration
    # among siblings.
    private def self.closes_block?(lines : Array(String), index : Int32, peeled : Int32) : Bool
      opener_indent = lines[index].size - lines[index].lstrip.size
      rest = lines[(index + 1)..].reject { |line| line.strip.empty? || line.strip.starts_with?('#') }
      # The wrappers already peeled each contribute a closing `end` at the
      # tail, and this block's own `end` is the first one at its indent.
      return false if rest.size <= peeled
      closing_at = rest.index do |line|
        line.strip == "end" && (line.size - line.lstrip.size) == opener_indent
      end
      return false unless closing_at
      return false unless rest[0, closing_at].all? { |line| (line.size - line.lstrip.size) > opener_indent }

      # What follows the `end`. Nothing is the ordinary case; the `validator`
      # shard is the other one - `module Validator` with `alias Valid =
      # Validator` under it, where refusing to peel left the module nested
      # and every consumer's `using validator::{Validator}` refused.
      #
      # Only a name for a type may trail it. Anything else is code that ran
      # *outside* the module and may name it: `halite/error.cr` closes
      # `module Exception` and then, still inside `module Halite`, loops
      # `{% for cls in Exception.constants %}` to re-export every class of
      # it. Peeling the inner module leaves that macro naming a namespace
      # that is gone - it found the *other* language's `Exception` and
      # aliased its constants over the module's own classes.
      trailing = rest[(closing_at + 1)..]
      return false if trailing.size < peeled
      trailing = trailing[0, trailing.size - peeled]
      trailing.all? do |line|
        indent = line.size - line.lstrip.size
        next true if indent > opener_indent || line.strip == "end"
        # A `require` under the wrapper's `end` is how a Crystal file pulls
        # in the directory beside it - `require "./features/*"` after
        # `module Halite` - and it names nothing, so it does not stop the
        # peel. Refusing it collapsed every such file onto one module path.
        next true if REQUIRE.matches?(line)
        next false unless indent == opener_indent
        (match = DECL.match(line)) && (match[3] || "").in?("alias", "annotation")
      end
    end

    def qualified(name : String) : String
      (namespace + [name]).join("::")
    end

    # The module's own name for a constant path it declares, spelled the
    # way a consumer writes it when the bare name is taken: `d_b/tag` and
    # `Tag` is `AcikTurkiye::DB::Tag::Tag`.
    # A name whose module is not known until import cycles have been
    # merged rides through the body between these, and the driver
    # resolves it: `MARK path MARK Name MARK`. A private-use codepoint,
    # because it cannot occur in Crystal source.
    MARK = '\ue000'

    # Every `MARK path MARK name MARK` in a line, as pairs.
    def self.marks(text : String) : Array({String, String})
      found = [] of {String, String}
      return found unless text.includes?(MARK)
      rest = text
      while (at = rest.index(MARK))
        rest = rest[(at + 1)..]
        owner_end = rest.index(MARK) || break
        owner = rest[0, owner_end]
        rest = rest[(owner_end + 1)..]
        name_end = rest.index(MARK) || break
        name = rest[0, name_end]
        rest = rest[(name_end + 1)..]
        # An empty name is the namespace itself, and what the module has to
        # export is then the method called on it: `Shop::Config.banner`
        # rides as the namespace plus `.banner`.
        if name.empty? && rest.starts_with?('.')
          method = rest[1..].each_char.take_while { |char| char.alphanumeric? || char == '_' || char == '?' || char == '!' }.join
          name = method
        end
        found << {owner, name}
      end
      found
    end

    def self.resolve_marks(text : String, remap : Hash(String, String), module_path : String) : String
      return text unless text.includes?(MARK)
      String.build do |io|
        rest = text
        while (at = rest.index(MARK))
          io << rest[0, at]
          rest = rest[(at + 1)..]
          owner_end = rest.index(MARK) || break
          owner = rest[0, owner_end]
          rest = rest[(owner_end + 1)..]
          name_end = rest.index(MARK) || break
          name = rest[0, name_end]
          rest = rest[(name_end + 1)..]
          target = remap[owner]? || owner
          if name.empty?
            io << namespace_of(target)
          else
            io << (target == module_path ? name : spelled(target, name))
          end
        end
        io << rest
      end
    end

    # One `def` line, with the types its calls said. The parameters are
    # rewritten between the outermost parentheses; a parameter that was
    # passed two types is left as the author wrote it and named, because a
    # `pub def` cannot be two defs and choosing would be inventing a
    # program.
    private def annotate_def(line : String, source_index : Int32, inferred : ParamTypes, notes : Notes) : String
      key = {source, source_index + 1}
      seen = inferred.params(key)
      answers = inferred.answer(key)
      return line unless seen || answers

      # A parameter list that runs over several lines is not this line's to
      # rewrite. `def before_check(` has no `)` to put a return type after,
      # and putting one after the `(` wrote `def before_check( : ::Nil` -
      # a file that does not parse, from a def whose types were known.
      opens = line.count('(') - line.count(')')
      unless opens.zero?
        notes.add "annotate", "#{path}:#{source_index + 1}: this def's parameter list runs over several lines, so the types read off its calls were not written - write them where the parameters are"
        return line
      end

      # The *parameter list*, matched: `def self.get_all : Array(City)?`
      # has a paren and no parameters, and taking the last `)` in the line
      # read its return type as one — which appended a second.
      def_name = (DEF.match(line).try(&.[4])) || ""
      span = MigrateUnit.param_span(line, def_name)
      open_at = span.try(&.[0])
      close_at = span.try(&.[1])
      if open_at && close_at && seen
        inside = line[(open_at + 1)...close_at]
        parts = inside.split(',')
        rewritten = parts.map do |part|
          name = part.strip
          next part if name.empty? || name.includes?(':') || name.starts_with?('&') || name.starts_with?('*')
          bare = name.lchop('@').split(' ').last
          types = seen[bare]? || seen[name]?
          next part unless types
          if types.size > 1
            notes.add "annotate", "#{path}: `#{bare}` is passed #{types.to_a.sort.join(" and ")} — R-2 wants one, so it is left as written"
            next part
          end
          spelling = MigrateUnit.absolute_type(types.first)
          next part unless spelling
          notes.add "annotate", "#{path}: `#{bare} : #{spelling}`, read off its calls"
          "#{part.rstrip} : #{spelling}"
        end
        line = line[0, open_at + 1] + rewritten.join(",") + line[close_at..]
      end

      # The answer, where the def wrote none and every caller was handed
      # one type. `initialize` answers what it is defined on, and a setter
      # answers what it was handed, so neither wants one.
      if answers && answers.size == 1 && !def_name.empty?
        name = def_name
        tail = line.rstrip
        # Whether a return type is already written: what follows the
        # parameter list, or the name when there is none.
        after = MigrateUnit.param_span(tail, name)
        rest =
          if span_now = after
            tail[(span_now[1] + 1)..]
          elsif (name_at = tail.index(name))
            tail[(name_at + name.size)..]
          else
            ":"
          end
        unless rest.includes?(':') || name == "initialize" || name.ends_with?('=')
          answer = MigrateUnit.absolute_type(answers.first)
          if answer
            # Before a `forall`, not after it: `def f(x : Hash(String, V))
            # forall V` took the return type onto the end and wrote
            # `forall V : ::Hash(...)`, which reads as a bound on `V` and
            # does not parse. The clause stays last, where it belongs.
            if (at = tail.index(" forall "))
              line = tail[0, at] + " : " + answer + tail[at..]
            else
              line = tail + " : " + answer
            end
            notes.add "annotate", "#{path}: `#{name}` answers #{answer}, read off its calls"
          end
        end
      end
      line
    end

    # Where a `def` line's parameter list opens and closes, matched, or
    # nil when it has none: the `(` that follows the name, and its own `)`.
    def self.param_span(line : String, name : String) : {Int32, Int32}?
      return nil if name.empty?
      at = line.index(name)
      return nil unless at
      index = at + name.size
      while (char = line[index]?) && (char == ' ' || char == '\t')
        index += 1
      end
      return nil unless line[index]? == '('
      open_at = index
      depth = 0
      while (char = line[index]?)
        depth += 1 if char == '('
        if char == ')'
          depth -= 1
          return {open_at, index} if depth.zero?
        end
        index += 1
      end
      nil
    end

    # A type as the compiler prints it, spelled so a module cannot mistake
    # it for one of its own: every path in it becomes absolute, because a
    # tree that declares `AcikTurkiye::DB` would otherwise read the `db`
    # shard's `DB::ExecResult` as its own. Nil when the compiler's spelling
    # is not something a person could have written — a virtual type, an
    # anonymous one — and then nothing is written.
    def self.absolute_type(text : String) : String?
      return nil if text.includes?('+') || text.includes?('#') || text.includes?("(anonymous")
      String.build do |io|
        index = 0
        while index < text.size
          char = text[index]
          previous = index > 0 ? text[index - 1] : ' '
          if char.ascii_uppercase? && !(previous.alphanumeric? || previous == '_' || previous == ':')
            io << "::"
          end
          io << char
          index += 1
        end
      end
    end

    # Whether `line` names `word` on its own: not part of a longer name, not
    # after a `.`, `:` or `@`. Hand-written, because a pattern built from a
    # name would be compiled per name and per line.
    def self.names?(line : String, word : String) : Bool
      from = 0
      while (at = line.index(word, from))
        from = at + word.size
        before = at > 0 ? line[at - 1] : ' '
        after = line[from]?
        next if before.alphanumeric? || before == '_' || before == '.' || before == ':' || before == '@'
        next if after && (after.alphanumeric? || after == '_')
        return true
      end
      false
    end

    # Whether this module's own namespace plus the exported name *is*
    # another module's namespace, in which case the bare name reaches the
    # module rather than what it exports.
    private def shadowed?(export : Export) : Bool
      MigrateUnit.namespace_of(path) + "::" + export.name == MigrateUnit.namespace_of(export.unit.path)
    end

    # `d_b/tag` is the namespace `AcikTurkiye::DB::Tag`.
    def self.namespace_of(module_path : String) : String
      module_path.split('/').map { |segment| segment.split('_').map(&.capitalize).join }.join("::")
    end

    def self.spelled(module_path : String, name : String) : String
      namespace_of(module_path) + "::" + name
    end

    @by_namespace = {} of String => MigrateUnit
    # Names this file defines in both spellings: the bang one is renamed
    # rather than stripped, here and at its calls in this file.
    @bang_renames = Set(String).new
    # Every bang def in the tree - a call to one of these is a call to a
    # method that lost its bang, not to Crystal's mutating member.
    @tree_bangs = Set(String).new
    # Every `.cr` the tree is migrating, so a resolved call can be told
    # apart from one into Crystal's library.
    @tree_sources = Set(String).new

    def render(by_source : Hash(String, MigrateUnit), by_namespace : Hash(String, MigrateUnit),
               exports : Hash(String, Export), notes : Notes, project_root : String,
               inferred : ParamTypes? = nil, tree_bangs : Set(String) = Set(String).new,
               tree_sources : Set(String) = Set(String).new) : Nil
      @by_namespace = by_namespace
      @tree_bangs = tree_bangs
      @tree_sources = tree_sources
      claimed = {} of String => String
      @exports.each { |name| claimed[name] = path }
      depth = wrappers * 2
      opened = 0

      # A `def` named with a `!` cannot be written in a `.iyi` file at all
      # (III.1.7), so the bang comes off the definition and off its calls -
      # they agree because both drop it. Where the file wrote *both*
      # spellings, which is Crystal's pair convention, dropping it would
      # make one def silently replace the other, so the mutating one says
      # what it does instead (III.1.7a's amendment) and its calls in this
      # file follow.
      plain_defs = Set(String).new
      bang_defs = Set(String).new
      lines.each do |line|
        next unless (match = DEF_NAME.match(line))
        name = match[1] || ""
        name.ends_with?('!') ? bang_defs << name.rchop : plain_defs << name
      end
      @bang_renames = bang_defs & plain_defs
      @bang_renames.each do |name|
        notes.add "bang", "#{path}: `def #{name}!` became `def #{name}_in_place` - both spellings are here, and `!` is III.1.7a's"
      end

      lines.each_with_index do |line, source_index|
        stripped = line.strip
        if match = REQUIRE.match(line)
          target = match[1] || ""
          if target.starts_with?('.')
            found = resolve_require(target, by_source)
            found.each { |unit| imports << unit.path unless unit.path == path }
            note_unresolved_require(target, notes) if found.empty?
          end
          next # a shard require rides in the header
        end
        if opened < wrappers && stripped.starts_with?("module ") && MODULE.matches?(line)
          opened += 1
          next
        end
        if wrappers > 0 && stripped == "end" && (line.size - line.lstrip.size) < depth
          next
        end
        line = line[depth..]? || "" if depth > 0 && line.size >= depth && line[0, depth].strip.empty?

        # Rule: `include Logging` at the namespace's own level is Crystal's
        # way of saying "and these names are mine too"; here the names come
        # through `using`, which the rewrite below writes.
        if (match = INCLUDE.match(line)) && (match[1] || "").empty?
          if target = Command.resolve_namespace_for(match[3] || "", self, by_namespace)
            notes.add "include", "#{path}: `include #{match[3]}` is #{target.path}'s names; they arrive by `using`"
            next
          end
        end

        # An `include` *inside a type* is a different thing entirely: the
        # module is a mixin, and iyi spells a mixin as a `trait` with an
        # `impl` per type (R-3's orphan rule, II.6). A mixin migrated as a
        # module puts what `macro included` writes at the module's own
        # level, where a module extends itself - `can't declare instance
        # variables in DB::Disposable because DB::Disposable extends it`,
        # which names nothing a person can act on. It is named here
        # instead, and it is the one shape this verb does not rewrite.
        if (match = INCLUDE.match(line)) && !(match[1] || "").empty?
          if target = Command.resolve_namespace_for(match[3] || "", self, by_namespace)
            notes.add "mixin", "#{path}: `include #{match[3]}` mixes #{target.path} into a type; iyi spells that a `trait` and an `impl` for each type that has it (SPEC.md II.6), which this verb does not write - the two modules need a person"
          end
        end

        if (match = DECL.match(line)) && (match[1] || "").empty? && (match[4] || "").includes?("::")
          line = line.sub(match[4].not_nil!, match[4].not_nil!.split("::").last)
        end
        if (match = DECL.match(line)) && (match[1] || "").empty? && match[2].nil?
          if match[3] == "module"
            notes.add "nested", "#{path}: `module #{match[4]}` stays nested, and `pub` does not apply to a module — nothing outside can reach into it"
          else
            # A *type* keeps its `pub` whether the tree names it or not: a
            # macro in a shard names the class that includes it —
            # `Kemal::Handler`'s `only` expands `{{@type}}` — and that
            # reference is qualified, so an unexported class is refused
            # inside its own module. Defs and constants have no such
            # reader, and those are the ones taken back below.
            line = "pub " + line
          end
        elsif (match = DEF.match(line)) && (match[1] || "").empty? && match[2].nil?
          line = annotate_def(line, source_index, inferred, notes) if inferred
          pub_sites << {body.size, match[4] || "", source_index + 1}
          # `def self.banner` at a module's top level is Crystal saying
          # "a module function"; an iyi module extends itself, so the
          # module function is the plain spelling and `def self.` would
          # put it on the metaclass — reachable from source and *not*
          # through an artifact, which is where the difference shows.
          line = line.sub("def self.", "def ")
          line = "pub " + line
        elsif (match = CONST.match(line)) && (match[1] || "").empty?
          pub_sites << {body.size, match[2] || "", source_index + 1}
          line = "pub " + line
        end

        if inferred && (match = DEF.match(line)) && !(match[1] || "").empty? && match[2].nil?
          line = annotate_def(line, source_index, inferred, notes)
        end
        # `class Error < Error`, which is what `shards/script.cr` writes:
        # a class cannot inherit from itself, so the superclass is the one
        # the *enclosing* namespace offers - Crystal resolves it outwards
        # before the new name exists. Written bare it read as this
        # module's own, and iyi answered `Error is not a class, it's a
        # trait`, naming its own error trait in a file nobody wrote.
        if (match = SELF_SUPER.match(line)) && (match[2] || "") == (match[3] || "")
          name = match[2] || ""
          outer = exports.each_value.find do |export|
            export.unit != self && export.name == name
          end
          if outer
            imports << outer.unit.path
            line = line.sub("< #{name}", "< #{MARK}#{outer.unit.path}#{MARK}#{name}#{MARK}")
            notes.add "collide", "#{path}: `class #{name} < #{name}` inherits the one #{outer.unit.path} offers, written out - a class cannot inherit from itself"
          else
            line = line.sub("< #{name}", "< ::#{name}")
            notes.add "collide", "#{path}: `class #{name} < #{name}` inherits the library's `::#{name}`, written out - a class cannot inherit from itself"
          end
        end
        line = rewrite_paths(line, exports, claimed, notes)
        if (match = BANG_ACCESSOR.match(line))
          # A bang accessor is `not_nil!` a macro wrote: the reader answers
          # or raises. `!` is III.1.7a's, so the raise is written where a
          # reader can see it, and `?` keeps the question the macro also
          # answered - the same three entry points, one of them visible.
          indent = match[1] || ""
          # `protected getter! segment : String` - the visibility rides on
          # both the accessor and the reader, and leaving it out of the
          # pattern left the bang in a name, which does not parse.
          visibility = match[2] || ""
          kind = match[3] || ""
          name = match[4] || ""
          bare = (match[5] || "").strip
          bare = bare[0, bare.size - 1].strip if bare.ends_with?('?')
          while bare.ends_with?("| Nil") || bare.ends_with?("|Nil")
            bare = bare[0, bare.rindex('|') || bare.size].strip
          end
          notes.add "bang", "#{path}: `#{kind}! #{name}` became `#{kind}? #{name}` and a reader that raises - `!` is III.1.7a's"
          body << "#{indent}#{visibility}#{kind}? #{name} : #{bare} | Nil"
          body << "#{indent}#{visibility}def #{name} : #{bare}"
          body << "#{indent}  @#{name} || raise \"#{name} is not set\""
          body << "#{indent}end"
          next
        elsif (match = BANG_ACCESSOR_BARE.match(line))
          notes.add "bang", "#{path}: `#{(match[1] || "")}! #{(match[2] || "").strip}` needs its type written before the reader that raises can be - `!` is III.1.7a's"
        end
        line = rewrite_bangs(line, notes, source_index + 1, inferred)
        body << line
      end

      # A bare name resolves outwards, the way Crystal resolves one: this
      # file's namespace first, then the one above it, to the top. So
      # `ENVIRONMENT` inside `AcikTurkiye::Logging` is `AcikTurkiye`'s and
      # arrives by `using` rather than by having been in scope.
      bare_lookup = {} of String => Export
      namespace.size.downto(0) do |depth|
        prefix = namespace[0, depth].join("::")
        exports.each do |qualified_name, export|
          parts = qualified_name.split("::")
          next unless parts.size - 1 == depth
          next unless depth.zero? || qualified_name.starts_with?(prefix + "::")
          bare_lookup[export.name] ||= export
        end
      end
      bare_lookup.each do |bare, export|
        next if export.unit == self
        next if shadowed?(export)
        next if (owner = claimed[bare]?) && owner != export.unit.path
        next unless body.any? do |line|
                      !line.strip.starts_with?('#') &&
                      MigrateUnit.names?(line, bare)
                    end
        imports << export.unit.path
        (usings[export.unit.path] ||= Set(String).new) << bare
        claimed[bare] = export.unit.path
      end
      imports.delete(path)
    end

    # What R-2 still wants, named before `--check` has to say it: an
    # exported def with an untyped parameter, or with no return type.
    # `--annotate` writes the ones the program's own calls answered; what
    # is left is a def nothing in any of them calls, so there was nothing
    # to read. A `pub def` at the module's top level and every public
    # method of an exported type - R-2 asks both.
    #
    # Run after the `pub` pass rather than during the rewrite: a
    # declaration no other module names loses its `pub` and R-2 asks it
    # nothing, and naming it here anyway was a list with entries a person
    # could not act on. The return type was missing from the list
    # altogether, so `zip_types is exported and does not say what it
    # returns` arrived as a compiler refusal instead of a note.
    def note_untyped_surface(notes : Notes, askers : Hash({String, String}, Set(String))) : Nil
      exported_type = nil
      body.each do |line|
        indent = line.size - line.lstrip.size
        if indent.zero?
          if line.starts_with?("pub class ") || line.starts_with?("pub struct ") ||
             line.starts_with?("pub abstract class ") || line.starts_with?("pub abstract struct ")
            exported_type = line.lstrip.split(' ')[2]?.try(&.split('(')[0])
          elsif line.rstrip == "end"
            exported_type = nil
          end
        end
        surface = indent.zero? ? line.starts_with?("pub def ") : !exported_type.nil?
        next unless surface
        next unless (match = DEF.match(line)) && match[2].nil? && match[3] == "def"
        name = match[4] || ""
        span = MigrateUnit.param_span(line, name)
        where = exported_type && indent > 0 ? "#{exported_type}##{name}" : name
        # Who asks, which is the first question a person has of this list:
        # R-2 is asking because *that* module names this one.
        asked_by = askers[{path, exported_type || name}]?
        because = (asked_by.try(&.to_a.sort.first?)) || "another module"
        # And *when* it is asked, because the two are different moments: a
        # module's own `pub def` is refused by the next compile, and a
        # public method of an exported type is refused when the module
        # becomes an artifact - which is why a tree can compile clean with
        # this list still long.
        asked_when = indent.zero? ? "the next compile of this module refuses it" : "refused when this module becomes an artifact"

        if span
          bare = line[(span[0] + 1)...span[1]].split(',').map(&.strip).select do |part|
            next false if part.empty? || part.includes?(':') || part.includes?("->")
            next false if part.starts_with?('&') || part.starts_with?('*')
            # A parameter's name, and not a piece of somebody's block type:
            # `&block : Context, Exception -> _` splits on the comma, and
            # `Exception` was reported as an untyped parameter. Crystal
            # names parameters in lower case; a type is not one.
            first = part[0]
            first.ascii_lowercase? || first == '_' || first == '@'
          end
          unless bare.empty?
            named = bare.map { |part| "`#{part.split(' ').first.split('=').first.strip}`" }.join(", ")
            notes.add "untyped", "#{path}: `#{where}` does not say what #{named} #{bare.size == 1 ? "is" : "are"} - #{because} names it and nothing in the program calls it, so nothing could be read; #{asked_when}"
          end
        end

        # And the answer. `initialize` answers what it is defined on and a
        # setter answers what it was handed, so neither is asked for one.
        next if name == "initialize" || name.ends_with?('=')
        tail = line.rstrip
        rest =
          if span
            tail[(span[1] + 1)..]
          elsif (at = tail.index(name))
            tail[(at + name.size)..]
          else
            ":"
          end
        next if rest.includes?(':')
        notes.add "untyped", "#{path}: `#{where}` does not say what it returns - #{because} names it and nothing in the program calls it, so nothing could be read; #{asked_when}"
      end
    end

    # A template is code inside `<% %>`; the rest is text a rewrite must
    # not touch, since HTML is full of quotes and capital letters.
    def rewrite_template(text : String, exports : Hash(String, Export), notes : Notes) : String
      claimed = {} of String => String
      String.build do |io|
        rest = text
        while (open_at = rest.index("<%"))
          io << rest[0, open_at]
          rest = rest[open_at..]
          close_at = rest.index("%>")
          unless close_at
            io << rest
            return io.to_s
          end
          code = rest[0, close_at + 2]
          io << rewrite_paths(code, exports, claimed, notes)
          rest = rest[(close_at + 2)..]
        end
        io << rest
      end
    end

    # This file's own relative requires, as a module written into
    # *out_dir* has to spell them: the files they name are still Crystal,
    # sitting where they were, so the path is theirs relative to where the
    # module now is - `require "./config"` beside the source, and
    # `require "../src/config"` from a directory next to it.
    def required_paths(out_dir : String) : Array(String)
      here = File.dirname(source)
      lines.compact_map do |line|
        next unless (match = REQUIRE.match(line))
        target = match[1] || ""
        next unless target.starts_with?('.')
        resolved = File.expand_path(target, here)
        MigrateUnit.relative_to(resolved, out_dir)
      end
    end

    # `to` seen from `from_dir`, with a `./` or as many `../` as it takes.
    #
    # Both sides are filesystem paths and the answer is posix, because it is
    # written into a `require`: `/` resolves on every platform and a `\`
    # inside the literal is an escape. `lchop(from_dir + "/")` asked with a
    # separator neither side uses on Windows, so a file inside *from_dir* was
    # never seen to be one, and the walk that then looked for a shared
    # directory stopped at `"/"` — which `File.dirname` of `C:\` never
    # answers. `migrate a.cr --out elsewhere` spun at 100% CPU appending
    # `..` and printed nothing at all.
    #
    # Sharing nothing but the root keeps the absolute spelling the caller
    # handed over, which is what the walk did when it ran out of directories
    # above `/`.
    def self.relative_to(to : String, from_dir : String) : String
      base = ::Path[from_dir]
      return to unless relative = ::Path[to].relative_to?(base)
      return to if relative.parts.count("..") >= base.parts.size - (base.anchor ? 1 : 0)
      posix = relative.to_posix.to_s
      posix.starts_with?("..") ? posix : "./" + posix
    end

    # Every unit this file's relative requires name, split by whether the
    # `require` is above this file's own code or below it. Crystal runs a
    # required file where the `require` is written, so `exception_page.cr`
    # - a class body with `require "./exception_page/*"` under it - is
    # loaded *before* the files that reopen the class, and a merge that
    # put them first made the reopening the first definition and the
    # `abstract class` a second one Crystal ignores.
    def requires_split(by_source : Hash(String, MigrateUnit)) : {Array(MigrateUnit), Array(MigrateUnit)}
      body_at = lines.index do |line|
        stripped = line.strip
        !stripped.empty? && !stripped.starts_with?('#') && !REQUIRE.match(line)
      end || lines.size
      before = [] of MigrateUnit
      after = [] of MigrateUnit
      lines.each_with_index do |line, index|
        next unless (match = REQUIRE.match(line)) && (match[1] || "").starts_with?('.')
        resolve_require(match[1] || "", by_source).each do |unit|
          (index < body_at ? before : after) << unit
        end
      end
      {before, after}
    end

    # Every unit this file's relative requires name, in order.
    def required_units(by_source : Hash(String, MigrateUnit)) : Array(MigrateUnit)
      before, after = requires_split(by_source)
      before + after
    end

    private def resolve_require(target : String, by_source : Hash(String, MigrateUnit)) : Array(MigrateUnit)
      base = File.expand_path(target, File.dirname(source))
      # Asked of the posix reading: `File.expand_path` answers in the
      # platform's separators, so `require "./parts/*"` came back as
      # `…\parts\*` and neither test saw a glob at all.
      posix = ::Path[base].to_posix.to_s
      if posix.ends_with?("/**") || posix.ends_with?("/*")
        dir = posix.rchop("*").rchop("*").rchop("/")
        pattern = posix.ends_with?("/**") ? ::Path[dir].to_posix.join("**", "*.cr") : ::Path[dir].to_posix.join("*.cr")
        Dir.glob(pattern).sort.compact_map { |file| by_source[file]? }
      else
        file = base.ends_with?(".cr") ? base : base + ".cr"
        (unit = by_source[file]?) ? [unit] : [] of MigrateUnit
      end
    end

    # A relative require that names no file of the tree was dropped without
    # a word, and a module that imports nothing where the Crystal required
    # something either compiles by accident or refuses in another module's
    # name. Whether the file is missing or merely outside the tree is worth
    # the sentence, because the fixes differ.
    private def note_unresolved_require(target : String, notes : Notes) : Nil
      base = File.expand_path(target, File.dirname(source))
      if base.ends_with?("*")
        notes.add "require", "#{path}: `require \"#{target}\"` matches no .cr the tree has; the line is dropped"
        return
      end
      file = base.ends_with?(".cr") ? base : base + ".cr"
      if File.file?(file)
        notes.add "require", "#{path}: `require \"#{target}\"` is #{Iyi.relative_filename(file)}, outside the tree; the line is dropped, and the module does not reach it"
      else
        notes.add "require", "#{path}: `require \"#{target}\"` names #{Iyi.relative_filename(file)}, which is not there; the line is dropped"
      end
    end

    # `!` is error propagation here (III.1.7a), so a Crystal bang cannot
    # be written at all. `not_nil!` becomes the narrowing it stands for;
    # every other bang becomes the spelling without it, which is the copy
    # where Crystal's was the mutation — hence the note.
    private def rewrite_bangs(line : String, notes : Notes, source_line : Int32 = 0, inferred : ParamTypes? = nil) : String
      return line if line.strip.starts_with?('#')
      if (match = DEF_NAME.match(line)) && (name = match[1] || "").ends_with?('!')
        bare = name.rchop
        renamed = @bang_renames.includes?(bare) ? bare + "_in_place" : bare
        notes.add "bang", "#{path}: `def #{name}` became `def #{renamed}` - `!` can't be part of a name (III.1.7)" unless @bang_renames.includes?(bare)
        return line.sub(name, renamed)
      end
      # A bang call that *is* the statement was there for the mutation and
      # nothing reads the copy. Whose method it is decides the rewrite, and
      # only the compiler knows: Crystal's mutating member needs the copy
      # put back where the mutation would have landed, and one this tree
      # defines lost its bang with its definition, so the call just drops
      # it. Where nothing in the program called it there is no reading, and
      # the line is named rather than guessed at quietly.
      if (match = BANG_STATEMENT.match(line)) && !@bang_renames.includes?(match[3] || "") &&
         !return_position?(source_line)
        indent = match[1] || ""
        target = match[2] || ""
        verb = match[3] || ""
        tail = match[4] || ""
        reading = bang_reading(verb, source_line, inferred)
        # An `@ivar` is the one receiver whose assignment cannot mean
        # something else. A bare name here is either a local or this
        # type's own getter, and `name = name.verb` on a getter declares a
        # local that shadows it and quietly does nothing - so the line is
        # named for a person instead of being rewritten into silence.
        if reading == :foreign && target.starts_with?('@')
          notes.add "bang", "#{path}: `#{target}.#{verb}!` became `#{target} = #{target}.#{verb}` - the copy goes back where the mutation was; another name for the same object does not see it"
          return "#{indent}#{target} = #{target}.#{verb}#{tail}"
        elsif reading != :own
          why = reading == :foreign ? "it is the other language's, which mutated in place" : "nothing in the program calls it, so whose `#{verb}!` this is could not be read"
          notes.add "bang", "#{source}:#{source_line}: `#{target}.#{verb}!` became `#{target}.#{verb}` and nothing reads the copy - #{why}; the line a person writes is `#{target} = #{target}.#{verb}#{tail}`, where `#{target}` is a name this file can assign"
          return "#{indent}#{target}.#{verb}#{tail}"
        end
      end
      # `.not_nil!` on a line of its own ends a chain the line does not
      # contain: the receiver is on the lines above, and a line-local
      # narrowing wrote `( || raise …)`, which does not parse. `||` binds
      # looser than a chain, so the composing spelling takes all of it -
      # which is what `not_nil!` meant where it sat.
      if line.strip.starts_with?(".not_nil!")
        indent = line[0, line.index('.') || 0]
        rest = line.strip.lchop(".not_nil!")
        if rest.empty? && !chain_continues?(source_line)
          notes.add "bang", "#{path}: a chain's `.not_nil!` became `.try { |value| value } || raise …` - the receiver is on the lines above it"
          return "#{indent}.try { |value| value } || raise \"nil where a value was expected\""
        end
        # Mid-chain: the `||` would swallow the steps after it, so the
        # narrowing is left undone and named. The types then refuse at
        # the use, which is where a person can see what to write.
        notes.add "bang", "#{source}:#{source_line}: `.not_nil!` mid-chain became `.try { |value| value }`, which does not narrow - the raise is a person's to place"
        return "#{indent}.try { |value| value }#{rest}"
      end
      while (at = line.index(".not_nil!"))
        start = receiver_start(line, at)
        receiver = line[start...at]
        line = line[0, start] + "(#{receiver} || raise \"nil where a value was expected\")" + line[(at + ".not_nil!".size)..]
        notes.add "bang", "#{path}: `not_nil!` became `(x || raise …)`"
      end
      line = Rx.gsub(line, BARE_BANG) do |match|
        name = match[2].not_nil!
        if @bang_renames.includes?(name)
          "#{match[1]}#{name}_in_place"
        elsif @tree_bangs.includes?(name)
          notes.add "bang", "#{path}: `#{name}!` became `#{name}` - its definition here lost the bang too"
          "#{match[1]}#{name}"
        else
          match[0].not_nil!
        end
      end
      Rx.gsub(line, BANG) do |match|
        name = match[1].not_nil!
        after = line[(match.end(0))]?
        if after && (after == '=' || after == '~' || after.alphanumeric? || after == '_')
          match[0].not_nil!
        elsif @bang_renames.includes?(name)
          ".#{name}_in_place"
        elsif bang_reading(name, source_line, inferred) == :own
          notes.add "bang", "#{path}: `#{name}!` became `#{name}` - its definition here lost the bang too"
          ".#{name}"
        else
          notes.add "bang", "#{path}: `#{name}!` became `#{name}` - the other language's mutated in place, this answers a copy; check the callers"
          ".#{name}"
        end
      end
    end

    # Whether the next thing in the file is an `end`, which makes this
    # line a body's last expression - what it answers is read, so it is
    # not a statement whose copy nobody wanted.
    # Whether the chain on this line goes on below it: the next thing in
    # the file is another `.step`.
    private def chain_continues?(source_line : Int32) : Bool
      index = source_line
      while index < lines.size
        stripped = lines[index].strip
        return stripped.starts_with?('.') unless stripped.empty? || stripped.starts_with?('#')
        index += 1
      end
      false
    end

    private def return_position?(source_line : Int32) : Bool
      index = source_line
      while index < lines.size
        stripped = lines[index].strip
        return stripped.starts_with?("end") unless stripped.empty? || stripped.starts_with?('#')
        index += 1
      end
      true
    end

    # Whose bang method the call on this line reaches: `:foreign` for
    # Crystal's, `:own` for one this tree defines and rewrote, `:unknown`
    # where nothing in the program called it, so there was nothing to read
    # - a library with no program of its own is all `:unknown`.
    private def bang_reading(verb : String, source_line : Int32, inferred : ParamTypes?) : Symbol
      if inferred && (targets = inferred.bang_targets({source, source_line, verb}))
        return targets.all? { |file| @tree_sources.includes?(file) } ? :own : :foreign
      end
      return :own if @bang_renames.includes?(verb)
      @tree_bangs.includes?(verb) ? :unknown : :foreign
    end

    # Where the primary expression ending at `at` begins: identifiers,
    # dots, instance variables and balanced brackets, walking left.
    private def receiver_start(line : String, at : Int32) : Int32
      index = at
      depth = 0
      while index > 0
        char = line[index - 1]
        case char
        when ')', ']', '}'
          depth += 1
        when '(', '[', '{'
          break if depth == 0
          depth -= 1
        when '.', '@', '_', '?', ':'
          # part of the chain: a name, a call, a constant path
        else
          break unless char.alphanumeric? || depth > 0
        end
        index -= 1
      end
      index
    end

    # Every constant path this tree declares, rewritten to the bare name
    # its module exports. Resolved outwards from this file's namespace,
    # the way Crystal resolves a constant; string contents are skipped.
    # A sidecar is Crystal, not an iyi module: it reopens somebody else's
    # type and is `require`d by the module beside it. It has no `using`
    # line to reach a name through, so every path it names that the tree
    # declares is written in full - `Radix::Result(Kemal::Route)` becomes
    # `Radix::Result(CliAndOthers::Route)`, because that is where `Route`
    # went. Left alone, a sidecar names types that no longer exist, which
    # is `undefined constant` in a file a person did not write.
    def rewrite_sidecar(exports : Hash(String, Export), notes : Notes) : String
      claimed = {} of String => String
      sidecar.map { |line| rewrite_paths(line, exports, claimed, notes, qualify: true) }.join('\n')
    end

    private def rewrite_paths(line : String, exports : Hash(String, Export),
                              claimed : Hash(String, String), notes : Notes,
                              qualify : Bool = false) : String
      return line if line.strip.starts_with?('#')
      String.build do |io|
        index = 0
        in_string = false
        # `"a #{Foo::BAR} b"` is a string with code in it, and the code is
        # a constant path like any other — found by hand rather than by
        # skipping every quoted span, which is how the first version
        # missed `"#{AcikTurkiye::NAME}.*"`.
        interpolation = 0
        while index < line.size
          char = line[index]
          escaped = index > 0 && line[index - 1] == '\\'
          if in_string && interpolation.zero? && char == '#' && line[index + 1]? == '{' && !escaped
            interpolation = 1
            io << '#' << '{'
            index += 2
            next
          end
          if interpolation > 0
            case char
            when '{' then interpolation += 1
            when '}' then interpolation -= 1
            end
            if interpolation.zero?
              io << char
              index += 1
              next
            end
          elsif char == '"' && !escaped
            in_string = !in_string
            io << char
            index += 1
            next
          end
          previous = index > 0 ? line[index - 1] : ' '
          # A path starts at an upper-case letter, or at the `::` of an
          # absolute one — which is how a Crystal file writes
          # `::DB::ExecResult` and how `--annotate` writes an inferred
          # type, so both have to be resolved rather than stepped over.
          absolute_here = char == ':' && line[index + 1]? == ':' &&
                          (line[index + 2]?.try(&.ascii_uppercase?) || false) &&
                          !(previous.alphanumeric? || previous == '_' || previous == ':')
          starts_here = absolute_here ||
                        (char.ascii_uppercase? &&
                         !(previous.alphanumeric? || previous == '_' || previous == ':'))
          unless starts_here && !(in_string && interpolation.zero?)
            io << char
            index += 1
            next
          end
          # Anchored: both patterns start with `^`, so a match from this
          # position is a match *at* it. `Rx` sweeps from a byte offset and
          # `^` still means the start of the subject, so the slice is what
          # is handed over.
          rest = line[index..]
          match = PATH_CALL.match(rest)
          match = PATH.match(rest) unless match
          unless match
            io << char
            index += 1
            next
          end
          token = match[0].not_nil!
          io << rewrite_path(token, exports, claimed, notes, qualify)
          index += token.size
        end
      end
    end

    private def rewrite_path(token : String, exports : Hash(String, Export),
                             claimed : Hash(String, String), notes : Notes,
                             qualify : Bool = false) : String
      # `Shop::Names.title` is a namespace and a method: the method is one
      # module's export, and naming it bare under a `using` is what R-2b
      # says a consumer writes.
      if at = token.index('.')
        head = token[0, at]
        method = token[(at + 1)..]
        # This module's own namespace, calling its own module function:
        # `Deep.run` inside `module Deep` is `run` here, because the
        # wrapper became the module. `resolve_namespace_for` answers nil
        # for self, so the call was left qualified and R-2 refused it -
        # `Deep does not export 'run'`, in a file nobody wrote.
        # ...and the name has to be *this* module's. Two files can share a
        # source namespace - `module Shop` in `shop.cr` and in
        # `shop/config.cr` - and `Shop.banner` written in the first is the
        # second's module function, which arrives by import.
        # `@exports` and not `exports`: the parameter is the tree's table
        # and shadows this unit's own list of what it declares.
        if namespace_names?(head) && @exports.includes?(method)
          return method unless qualify
          imports << path
          return "#{MARK}#{path}#{MARK}#{MARK}.#{method}"
        end
        if unit = (qualify ? @by_namespace[head.lchop("::")]? : Command.resolve_namespace_for(head, self, @by_namespace))
          # Qualified rather than bare under a `using`: a module function
          # called from inside a type's body does not resolve as a bare
          # name, and `Module::Path.method` is what R-2b names as the
          # other spelling. It reads the same as the Crystal it came from.
          return method if unit == self && !qualify
          imports << unit.path
          return "#{MARK}#{unit.path}#{MARK}#{MARK}.#{method}"
        end
        return rewrite_path(head, exports, claimed, notes, qualify) + "." + method
      end

      absolute = token.starts_with?("::")
      parts = token.lchop("::").split("::")
      # The longest prefix of the path that names something the tree
      # declares, resolved from this namespace outwards.
      (parts.size).downto(1) do |take|
        head = parts[0, take]
        tail = parts[take..]
        # A sidecar resolves *absolutely* and nothing else. It reopens
        # somebody else's type, so the names in its body mean what they
        # mean in that type's scope, not in this module's: `Log::Metadata`
        # there is the other language's `Log`, and resolving it outwards
        # from `AcikTurkiye::Logging` found this tree's own `Log` constant
        # and turned a reopening of a foreign type into a redefinition of
        # the tree's - 4 of 91 modules compiling, from 91.
        depths = (absolute || qualify) ? [0] : (0..namespace.size).to_a.reverse
        depths.each do |depth|
          candidate = (namespace[0, depth] + head).join("::")
          export = exports[candidate]?
          next unless export
          suffix = tail.empty? ? "" : "::" + tail.join("::")
          if qualify
            imports << export.unit.path
            return "#{MARK}#{export.unit.path}#{MARK}#{export.name}#{MARK}" + suffix
          end
          if export.unit == self
            return export.name + suffix
          end
          imports << export.unit.path
          # Shadowed: inside module `shop`, the name `Report` is the
          # namespace of the module `shop/report` before it is that
          # module's export, so the bare name reaches a module and not the
          # class. The qualified spelling is what a consumer writes then.
          if shadowed?(export)
            return "#{MARK}#{export.unit.path}#{MARK}#{export.name}#{MARK}" + suffix
          end
          if (owner = claimed[export.name]?) && owner != export.unit.path
            notes.add "collide", "#{path}: `#{export.name}` is #{owner}'s here, so #{export.unit.path}'s stays qualified"
            # The qualified spelling is the *final* module's, and modules
            # that form an import cycle are merged after this runs — so a
            # marker rides through and the driver resolves it.
            return "#{MigrateUnit::MARK}#{export.unit.path}#{MigrateUnit::MARK}#{export.name}#{MigrateUnit::MARK}" + suffix
          end
          (usings[export.unit.path] ||= Set(String).new) << export.name
          claimed[export.name] = export.unit.path
          return export.name + suffix
        end
      end
      # Not a declaration: perhaps the namespace itself, which a module
      # function is called on and a nested name is reached through.
      if unit = (qualify ? @by_namespace[token.lchop("::")]? : Command.resolve_namespace_for(token, self, @by_namespace))
        # This module's own namespace, named on its own: it is the module,
        # so the spelling is the namespace the path became. Erasing it wrote
        # `alias Valid = ` where the source said `alias Valid = Validator`.
        return MigrateUnit.namespace_of(path) if unit == self && !qualify
        imports << unit.path
        return "#{MARK}#{unit.path}#{MARK}#{MARK}"
      end
      # This module's own namespace, named from a sidecar: `Kemal::Route`
      # where `Kemal` is what this module became.
      if qualify && namespace_names?(token)
        imports << path
        return "#{MARK}#{path}#{MARK}#{MARK}"
      end
      token
    end

    # Whether `token` is this module's own namespace, written out.
    private def namespace_names?(token : String) : Bool
      MigrateUnit.namespace_of(path) == token.lchop("::")
    end
  end

  # `resolve_namespace` reached from a unit while it renders.
  def self.resolve_namespace_for(name : String, from : MigrateUnit, by_namespace : Hash(String, MigrateUnit)) : MigrateUnit?
    name = name.lchop("::")
    from.namespace.size.downto(0) do |depth|
      candidate = (from.namespace[0, depth] + name.split("::")).join("::")
      if unit = by_namespace[candidate]?
        return unit unless unit == from
      end
    end
    nil
  end
end
