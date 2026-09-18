# iyi: `iyi bind` — every shard under `lib/`, behind a boundary, in one
# command (SPEC.md III.6).
#
# The boundary has existed for a while as two commands per shard, run in
# dependency order by a person who knows the order and each shard's root
# namespace: `tool bind -e Root --emit-bind mods --use-iyimod mods
# lib/x/src/x.cr`, then a build of the keep file it wrote, with
# `--iyi-keep Root --emit-bind .` so the object code lands in the
# artifact. Kemal is four shards and eight commands, and
# `samples/crystal/kemal/README.md` is the loop written out by hand. The
# loop is what this verb is: it reads `lib/` the way `shards install`
# left it, orders the shards by their own `shard.yml` dependencies, reads
# each root off its entry file, and runs the two steps as itself. What
# comes out is `mods/<shard>.iyimod` per shard, and a program that wrote
# `require "kemal"` writes `import kemal` and builds against the
# artifacts instead of the source.
#
# Nothing here is new analysis: the steps are the ones the gate
# (`bench/kemal_serves.sh`) runs, in the order it runs them, as
# subprocesses of this binary — the way `mcp` and the daemon re-run the
# verbs — so a failure is the step's own message and the artifacts of the
# shards before it stand.
class Iyi::Command
  # Which shard wrote which artifact this run. Two shards that declare
  # the same root would otherwise share one file; see the check in
  # `bind_boundary`.
  @bind_owners = {} of String => String

  private def bind
    mods = "mods"
    lib_dir = "lib"
    while option = options.first?
      case option
      when "--mods"
        options.shift
        # The flag's value, not whatever flag was written after it: `--mods`
        # with nothing behind it took `--lib` for a directory name and made
        # one. `flag_value!` is in migrate.cr, whose `--out` had it too.
        mods = flag_value!("--mods", "a directory")
      when "--lib"
        options.shift
        lib_dir = flag_value!("--lib", "a directory")
      when "--help", "-h"
        puts <<-USAGE
          Usage: #{Command.program_name} bind [--lib DIR] [--mods DIR] [SHARD ...]

          Bind the shards shard.yml depends on (what `shards install` put
          under lib/, development dependencies aside) as a .iyimod each
          under mods/, in dependency order, each against the ones before
          it. Name shards to bind those and what they depend on instead.
          Then `import <name>` in a program built with --crystal --use-iyimod mods;
          the name is the root namespace spelled for import (`Kemal` is
          `kemal`, `DB` is `d_b`), and the output says it.
          USAGE
        exit
      else
        break
      end
    end

    unless Dir.exists?(lib_dir)
      # A file that is there is not a directory that is missing: `--lib
      # shard.yml` answered "no shard.yml/ here; run `shards install`"
      # about the file the person had just named.
      abort! "bind: --lib needs the directory `shards install` wrote, and #{lib_dir} is a file", :USAGE_ERROR if File.exists?(lib_dir)
      abort! "bind: no #{lib_dir}/ here; run `shards install` first, or --lib DIR", :USAGE_ERROR
    end
    # And the other way: `--mods shard.yml` died of `mkdir`'s own words,
    # "shard.yml: File exists", which names no flag and blames nothing.
    if File.exists?(mods) && !Dir.exists?(mods)
      abort! "bind: --mods needs a directory for the .iyimod files, and #{mods} is a file", :USAGE_ERROR
    end

    # Artifact name is the root namespace, so two shards that both declare
    # `Shared` both write `mods/shared.iyimod`. The second used to overwrite
    # the first and exit 0. The owner is the shard that bound it, and a
    # later shard that would write the same file is refused.
    @bind_owners = {} of String => String

    shards = {} of String => Shard
    Dir.each_child(lib_dir) do |name|
      dir = File.join(lib_dir, name)
      next unless Dir.exists?(dir)
      entry = File.join(dir, "src", "#{name}.cr")
      unless File.file?(entry)
        STDERR.puts "bind: #{name}: no src/#{name}.cr, skipped"
        next
      end
      shards[name] = Shard.new(name, entry, shard_root(entry), shard_dependencies(dir, shards_available: lib_dir))
    end
    abort! "bind: nothing under #{lib_dir}/ has a src/<name>.cr", :USAGE_ERROR if shards.empty?

    # What to bind: the shards named, or the project's own `shard.yml`
    # dependencies — not its development ones, which are the tests' (a
    # spec framework under lib/ is not a boundary anybody's program
    # crosses) — or, with no manifest to read, everything under lib/.
    wanted =
      if !options.empty?
        options.dup
      elsif File.file?("shard.yml")
        listed = shard_dependencies(".", shards_available: lib_dir)
        abort! "bind: shard.yml lists no dependency that is under #{lib_dir}/", :USAGE_ERROR if listed.empty?
        listed
      else
        shards.keys
      end
    wanted.each do |name|
      abort! "bind: the shard name is empty, so it names nothing", :USAGE_ERROR if name.empty?
      abort! "bind: no shard named #{name} under #{lib_dir}/", :USAGE_ERROR unless shards[name]?
    end

    ordered = [] of Shard
    visiting = Set(String).new
    visit = uninitialized Proc(String, Nil)
    visit = ->(name : String) : Nil do
      return if ordered.any? { |s| s.name == name }
      abort! "bind: #{name} depends on itself through its dependencies", :USAGE_ERROR unless visiting.add?(name)
      shards[name].dependencies.each { |dependency| visit.call(dependency) }
      ordered << shards[name]
    end
    wanted.each { |name| visit.call(name) }

    executable = Process.executable_path || abort!("bind: cannot find the compiler's own executable", :USAGE_ERROR)
    # And one that is there and will not take a file: the first thing
    # written is the shard's bind log, and its "Permission denied" named
    # the log, not the flag.
    if Dir.exists?(mods) && !File.writable?(mods)
      abort! "bind: --mods #{mods} will not take the .iyimod files: no permission to write there", :USAGE_ERROR
    end
    Dir.mkdir_p(mods)
    mods_path = File.expand_path(mods)

    # The fill build runs inside mods/, where a relative `lib` on the path
    # would resolve under it; so the paths the subprocesses get are this
    # directory's, absolute, with lib/ where the default has it.
    lib_path = File.expand_path(lib_dir)
    search = IyiPath.default_paths.map { |path| path == "lib" ? lib_path : File.expand_path(path) }
    search.unshift(lib_path) unless search.includes?(lib_path)
    env = {"IYI_PATH" => search.join(Process::PATH_DELIMITER), "CRYSTAL_PATH" => search.join(Process::PATH_DELIMITER)}

    # A shard that fails is named and the rest go on: the ones before it
    # stand, and a shard that does not depend on it binds regardless.
    # The exit code says whether everything asked for was bound.
    failed = [] of String

    # Except that a shard whose whole surface is macros is not a dependency
    # anything can be missing: it has no declarations, no object code and no
    # artifact, because its macros travel with its *source* and expand into
    # whoever writes them. `validator` is written on `prop`'s macros, and
    # waiting on a boundary that cannot exist left it unbound over nothing.
    macros = [] of String
    puts "binding #{ordered.size} shard#{ordered.size == 1 ? "" : "s"} into #{mods}/, in dependency order:"
    ordered.each do |shard|
      print "  #{shard.name}"
      STDOUT.flush
      unless root = shard.root
        puts " — no top-level module, class or struct in #{shard.entry}; bind it by hand with `#{Command.program_name} tool bind --crystal -e Root ...`"
        failed << shard.name
        next
      end
      if (missing = shard.dependencies.find { |dependency| failed.includes?(dependency) && !macros.includes?(dependency) })
        puts " (#{root}) — skipped: depends on #{missing}, which did not bind"
        failed << shard.name
        next
      end
      print " (#{root})"
      STDOUT.flush

      # One boundary per namespace, and the shard's root is only the first.
      #
      # `pg` declares `PG` and `PQ` - its wire protocol - in one tree, and a
      # boundary is rooted at a namespace: `PG`'s units refer to
      # `Array(PQ::Field)`, whose declarations belong at the consumer's top
      # level rather than under `PG` and whose object code is a unit of its
      # own. Two namespaces, two artifacts, and `PG`'s imports `PQ`'s the way
      # it imports any other boundary.
      #
      # The root goes first because binding it is what *finds* the others -
      # `tool bind` reads them off the program and says so - and then it is
      # bound again, with those boundaries beside it to refer to.
      result = bind_namespaces(executable, env, mods, mods_path, shard,
        shard.entry, root, "  #{shard.name} (#{root})")

      macros << shard.name if result.macros
      report_boundary mods, result
      unless result.bound
        failed << shard.name
        next
      end

      # And the parts the entry does not load, each rooted at what it
      # declares. Last, so that they can refer to the boundary above: an
      # optional part is written against the shard it is part of. See
      # `optional_entries`.
      optional_entries(shard.entry).each do |part|
        next unless part_root = shard_root(part)
        next if part_root == root
        shard_dir = File.dirname(File.dirname(shard.entry))
        label = "    #{part_root} (#{Iyi.path_under?(part, shard_dir) || part})"
        print "\n#{label}"
        STDOUT.flush
        report_boundary mods, bind_namespaces(executable, env, mods, mods_path, shard,
          part, part_root, label)
      end
    end
    if failed.empty?
      puts "import any of them by that name from a program built with --crystal --use-iyimod #{mods}"
    else
      puts "#{ordered.size - failed.size} of #{ordered.size} bound; not bound: #{failed.join(", ")}"
      exit 1
    end
  end

  record Shard, name : String, entry : String, root : String?, dependencies : Array(String)

  # One entry file's namespaces, root first.
  #
  # A boundary is rooted at a namespace and a file need not declare only one:
  # `pg` declares `PG` and `PQ` - its wire protocol - in one tree, and `PG`'s
  # units refer to `Array(PQ::Field)`, whose declarations belong at the
  # consumer's top level rather than under `PG` and whose object code is a
  # unit of its own. Two namespaces, two artifacts, and `PG`'s imports `PQ`'s
  # the way it imports any other boundary.
  #
  # The root goes first because binding it is what *finds* the others -
  # `tool bind` reads them off the program and says so - and then it is bound
  # again, with those boundaries beside it to refer to.
  private def bind_namespaces(executable : String, env : Hash(String, String), mods : String,
                              mods_path : String, shard : Shard, entry : String,
                              root : String, label : String) : Boundary
    result = bind_boundary(executable, env, mods, mods_path, shard, entry, root)
    # Not one that already has an artifact: it was bound earlier, in
    # dependency order, and rebinding it here would put this run's edges the
    # wrong way round. An optional part sees the whole shard, so the shard's
    # own root is always among these.
    others = result.others.reject do |name|
      name == root || File.file?(File.join(mods_path, "#{Iyi.iyi_module_name(name)}.iyimod"))
    end
    return result if others.empty? || !result.bound

    # The root's artifact comes off the disk first, and the order is the whole
    # reason: a secondary bound while it is there numbers its types, takes an
    # import edge to it, and the root - which names the secondary's types in
    # its declarations - takes one back. An import graph is a DAG (R-1), and
    # the pair arrived as `Error: import cycle`. This pass was for discovery;
    # the artifact it left is rewritten below anyway.
    File.delete?(File.join(mods_path, "#{result.artifact}.iyimod"))
    others.each do |other|
      print "\n    #{other} (also declared here)"
      STDOUT.flush
      report_boundary mods, bind_boundary(executable, env, mods, mods_path, shard, entry, other)
    end

    # And the root again, now that they exist: the first run had nothing to
    # refer to, so its declarations named types it could not name.
    result = bind_boundary(executable, env, mods, mods_path, shard, entry, root)
    print "\n#{label}"
    STDOUT.flush
    result
  end

  # What one boundary's two builds answered.
  record Boundary,
    root : String,
    artifact : String,
    bound : Bool,
    macros : Bool,
    dropped : Array(String),
    message : String,
    others : Array(String)

  # Binds one namespace: the declarations, then the object code, then again
  # without whatever the fill build could not compile. See `DROP_CAP`.
  private def bind_boundary(executable : String, env : Hash(String, String), mods : String,
                            mods_path : String, shard : Shard, entry : String,
                            root : String) : Boundary
    artifact = Iyi.iyi_module_name(root)
    keep = File.join(mods_path, "#{artifact}_keep.cr")
    bind_log = File.join(mods_path, "#{artifact}.bind.log")
    fill_log = File.join(mods_path, "#{artifact}.fill.log")
    drop_path = File.join(mods_path, "#{artifact}.drop")
    owners = @bind_owners ||= {} of String => String
    if (owner = owners[artifact]?) && owner != shard.name
      return Boundary.new(root, artifact, false, false, [] of String,
        "#{shard.name} also declares #{root}, and #{owner} already wrote #{mods}/#{artifact}.iyimod",
        [] of String)
    end

    # Discovery is this run's, not the last one's: a shard fixed since then
    # binds whole, and a person who deleted a line gets it retried.
    File.delete?(drop_path)
    dropped = [] of String
    others = [] of String
    bound = false
    macros = false
    message = ""

    until bound
      step = run_step(executable, env, ["tool", "bind", "--crystal", "-e", root, "--emit-bind", mods_path, "--use-iyimod", mods_path, entry], chdir: nil, log: bind_log)
      unless step
        message = "binding failed; #{mods}/#{artifact}.bind.log has the compiler's answer"
        break
      end
      others = other_namespaces(bind_log)

      # A shard whose surface is macros - `prop`, say - has nothing R-2 can
      # write and `tool bind` writes no file; III.6 rule 4 says macros do
      # not cross, and this is where a person learns that about the shard.
      unless File.file?(keep)
        message = "nothing to bind: no method R-2 can write a signature for " \
                  "(a surface that is macros does not cross, SPEC.md III.6); " \
                  "#{mods}/#{artifact}.bind.log has the count"
        macros = true
        break
      end

      # `--error-trace`, because the frame this needs is the outermost one:
      # the compiler names the shard's own line by default, and which
      # method of the boundary reached it is the whole question here.
      if run_step(executable, env, ["build", "--crystal", "--error-trace", "--iyi-keep", root, "--emit-bind", ".", "-o", "keep_#{artifact}", "#{artifact}_keep.cr"], chdir: mods_path, log: fill_log)
        bound = true
        break
      end

      key = dropped.size < DROP_CAP ? failing_method(keep, fill_log, artifact) : nil
      if key.nil? || dropped.includes?(key)
        # The declarations without their object code would be found by
        # the next build's `--use-iyimod` and fail there, further from the
        # cause; the log stays, the half-artifact does not.
        File.delete?(File.join(mods_path, "#{artifact}.iyimod"))
        message = "filling the object code failed; #{mods}/#{artifact}.fill.log has the compiler's answer"
        break
      end
      dropped << key
      File.write drop_path, String.build { |io|
        io << "# Methods `iyi bind` left out of this boundary: their bodies do not\n"
        io << "# compile when instantiated, which the fill build found and\n"
        io << "# #{artifact}.fill.log recorded. Delete a line to have the next run\n"
        io << "# try it again; the spelling is the keep file's `# bind-drop:` marker.\n"
        dropped.each { |name| io << name << "\n" }
      }
    end

    owners[artifact] = shard.name if bound
    Boundary.new(root, artifact, bound, macros, dropped, message, others)
  end

  private def report_boundary(mods : String, boundary : Boundary) : Nil
    unless boundary.bound
      puts " \u2014 #{boundary.message}"
      return
    end
    if boundary.dropped.empty?
      puts " \u2014 #{mods}/#{boundary.artifact}.iyimod"
    else
      puts " \u2014 #{mods}/#{boundary.artifact}.iyimod " \
           "(#{boundary.dropped.size} method#{boundary.dropped.size == 1 ? "" : "s"} left out, " \
           "whose body does not compile: #{mods}/#{boundary.artifact}.drop names them)"
    end
  end

  # The namespaces `tool bind` found beside the one it was given. See
  # `Iyi.print_bind`.
  private def other_namespaces(log : String) : Array(String)
    return [] of String unless File.file?(log)
    File.each_line(log) do |line|
      next unless line.starts_with?("also declares: ")
      return line.lchop("also declares: ").split(", ").map(&.strip).reject(&.empty?)
    end
    [] of String
  end

  # Through `Iyi::Rx` rather than Crystal's `Regex`: pcre2 is on the list
  # iyi means to need nothing from, and `bench/dependency_floor.sh` fails
  # the build when a file here puts it back on the link line (SPEC.md
  # III.10, Appendix B #17).
  private SHARD_ROOT     = Rx::Pattern.compile("^(?:abstract[ \\t]+)?(?:module|class|struct)[ \\t]+([A-Z][A-Za-z0-9_]*)")
  private SHARD_REQUIRE  = Rx::Pattern.compile("^require[ \\t]+\"(\\.[^\"]+)\"")
  private MANIFEST_TOP   = Rx::Pattern.compile("^[^ \\t]")
  private MANIFEST_ENTRY = Rx::Pattern.compile("^  ([A-Za-z0-9_]+):")

  # The shard's root namespace: the first top-level `module`, `class` or
  # `struct` its entry file declares, which is what `-e` selects. A shard
  # whose entry only requires its parts declares nothing there, and then
  # the first part in require order that does is read instead.
  private def shard_root(entry : String) : String?
    seen = Set(String).new
    queue = [entry]
    while file = queue.shift?
      next unless seen.add?(file)
      next unless File.file?(file)
      File.each_line(file) do |line|
        if match = SHARD_ROOT.match(line)
          return match[1]
        end
        if match = SHARD_REQUIRE.match(line)
          required = File.expand_path(match[1] || "", File.dirname(file))
          # Asked of the posix reading: `File.expand_path` answers in the
          # platform's separators, so `require "./parts/*"` came back as
          # `…\parts\*` and this test saw no glob at all.
          posix = ::Path[required].to_posix.to_s
          if posix.ends_with?("/*") || posix.ends_with?("/**")
            Dir.glob(::Path[posix.rchop("*").rchop("*")].to_posix.join("**", "*.cr")).sort.each { |part| queue << part }
          else
            queue << (required.ends_with?(".cr") ? required : required + ".cr")
          end
        end
      end
    end
    nil
  end

  # The files under `src/` that the entry never requires, and that nothing
  # else in the shard requires either: a shard's *optional* parts.
  #
  # `bindata` ships `src/bindata/asn1.cr`, which its entry does not load - a
  # program that wants ASN.1 writes `require "bindata/asn1"` - and `jwt` is
  # such a program. Bound from the entry alone, `bindata`'s boundary carries
  # no `ASN1`, and `jwt`'s object code numbers `ASN1::BER`: `"j_w_t" numbers
  # `ASN1::BER`, and this build cannot name it`, with the type declared in a
  # file no boundary had read.
  #
  # Each is a boundary of its own, rooted at the first namespace it declares -
  # which is what it is: a part somebody requires by name.
  private def optional_entries(entry : String) : Array(String)
    source = File.dirname(entry)
    return [] of String unless Dir.exists?(source)

    # Expanded on both sides: a `require` resolves to an absolute path and a
    # glob answers in the spelling it was given, so comparing the two as they
    # come made every file of every part look like an entry of its own -
    # `asn1/identifier.cr` among them, which is one file of `asn1.cr`.
    reached = required_files(entry)
    rest = Dir.glob(::Path[source].to_posix.join("**", "*.cr")).map { |path| File.expand_path(path) }
      .sort.reject { |path| reached.includes?(path) }
    return [] of String if rest.empty?

    # A part somebody else requires is not an entry of its own: `asn1.cr`
    # requires `asn1/identifier.cr`, which is one file of the same part.
    inner = Set(String).new
    rest.each { |path| inner.concat required_files(path).reject { |file| file == path } }
    rest.reject { |path| inner.includes?(path) }
  end

  # Every file *file* reaches through its own relative requires, including it.
  private def required_files(file : String) : Set(String)
    seen = Set(String).new
    queue = [File.expand_path(file)]
    while current = queue.shift?
      next unless seen.add?(current)
      next unless File.file?(current)
      File.each_line(current) do |line|
        next unless match = SHARD_REQUIRE.match(line)
        required = File.expand_path(match[1] || "", File.dirname(current))
        posix = ::Path[required].to_posix.to_s
        if posix.ends_with?("/*") || posix.ends_with?("/**")
          Dir.glob(::Path[posix.rchop("*").rchop("*")].to_posix.join("**", "*.cr")).sort.each { |part| queue << part }
        else
          queue << (required.ends_with?(".cr") ? required : required + ".cr")
        end
      end
    end
    seen
  end

  # The shard's own `shard.yml` dependencies, by name, restricted to what
  # is installed: a dependency that is not under lib/ is not one this
  # verb can bind, and the compiler will say so when the shard's own
  # `require` misses it. `development_dependencies` are not read; they
  # are the shard's tests', not its consumers'.
  private def shard_dependencies(dir : String, shards_available : String) : Array(String)
    manifest = File.join(dir, "shard.yml")
    return [] of String unless File.file?(manifest)
    names = [] of String
    in_dependencies = false
    File.each_line(manifest) do |line|
      if MANIFEST_TOP.matches?(line)
        in_dependencies = line.starts_with?("dependencies:")
        next
      end
      next unless in_dependencies
      if match = MANIFEST_ENTRY.match(line)
        if (name = match[1]) && Dir.exists?(File.join(shards_available, name))
          names << name
        end
      end
    end
    names
  end

  # How many methods one shard may lose this way before the failure is the
  # shard's rather than a method's. Each one costs both builds again, and a
  # boundary losing a dozen methods is not a boundary anybody should trust
  # without reading why.
  private DROP_CAP = 12

  # `In kemal_keep.cr:804:10` - the keep file's own frame in a fill build's
  # error trace, which is the call that did not compile.
  private FILL_FRAME = Rx::Pattern.compile("^In ([^ :]+_keep\\.cr):([0-9]+)")

  # Which method the fill build stopped inside, or nil when the trace names
  # no call of the keep file's - a failure that dropping a method cannot fix.
  #
  # The trace's frames run outermost first, so the *last* one in the keep
  # file is the call itself: the first is `fun __bind_keep` around all of
  # them. Above that line sits the marker `keep_call` wrote, and `-` there
  # means the line belongs to no single method (see `@@drop` in tool bind).
  private def failing_method(keep : String, log : String, artifact : String) : String?
    line_number = nil
    File.each_line(log) do |line|
      if match = FILL_FRAME.match(line)
        next unless match[1] == "#{artifact}_keep.cr"
        line_number = match[2].try(&.to_i?) || line_number
      end
    end
    return nil unless line_number
    return nil unless File.file?(keep)

    lines = File.read_lines(keep)
    index = Math.min(line_number - 1, lines.size - 1)
    while index >= 0
      text = lines[index].strip
      if text.starts_with?("# bind-drop: ")
        key = text.lchop("# bind-drop: ").strip
        return key == "-" ? nil : key
      end
      index -= 1
    end
    nil
  end

  private def run_step(executable : String, env : Hash(String, String), args : Array(String), chdir : String?, log : String) : Bool
    File.open(log, "w") do |sink|
      status = Process.run(executable, args, env: env, chdir: chdir, output: sink, error: sink)
      status.success?
    end
  end
end
