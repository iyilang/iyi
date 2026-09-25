# iyi: `crystal mod dump FILE` — read a `.iyimod` back as text.
#
# Under the eventual `iyi` binary this reads `iyi mod dump`, which is the
# spelling SPEC.md IV.1 uses. It is required rather than optional there, and the
# reason is worth keeping in view: an opaque cache format is one nobody can
# debug, and a build cache that cannot be inspected is a build cache that gets
# distrusted and disabled.
class Iyi::Command
  private def mod
    case options.first?
    when "dump"
      options.shift
      mod_dump
    when "diff"
      options.shift
      mod_diff
    when "context"
      options.shift
      mod_context
    when "tidy"
      options.shift
      mod_tidy
    when "reach"
      options.shift
      mod_reach
    when "release"
      options.shift
      mod_release
    when nil, "--help", "-h"
      puts mod_usage
      exit
    else
      abort! "unknown mod subcommand: #{options.first}", :USAGE_ERROR
    end
  end

  private def mod_usage
    <<-USAGE
    Usage: #{Command.program_name} mod [subcommand]

    Subcommand:
        tidy [--check]           make iyi.mod and iyi.sum say what the source
                                 imports: add what is missing, remove what
                                 nothing uses, drop sums nothing builds
        reach                    say what every module the build selects
                                 touches outside the language: std modules,
                                 File, C libraries and functions
        release [VERSION]        say what the next release of this package has
                                 to be called, from what its exported surface
                                 did since the last tag; exit 1 when VERSION
                                 understates it
        context FILE.iyi         print what a change to this module is allowed
                                 to know: the exact exported surface of every
                                 module it imports, and nothing's body. This is
                                 the grounding a model needs (AI_FIRST.md §2);
                                 `--json` makes it data
        diff OLD NEW             say whether a change reaches this module's
                                 consumers, and what changed if it does.
                                 `--exit-code` exits 1 when it does
        dump FILE                print a .iyimod as text
        dump --declarations FILE print the iyi declarations a consumer compiles
                                 against, which is what `import` reads instead
                                 of the module's source
        dump --json FILE         print the module's exported surface as JSON:
                                 exact signatures, types, fields, impls, and
                                 the interface hash they are keyed by

    A .iyimod is a module's compiled interface: what another module reads
    instead of this one's source (SPEC.md Part IV). Produced by
    `#{Command.program_name} build --emit-iyimod DIR`.
    USAGE
  end

  # iyi: what each subcommand takes, for a `--help` asked of the
  # subcommand rather than of `mod`.
  #
  # `iyi mod context --help` answered "mod context: unknown flag --help",
  # which is the one sentence that is certainly wrong: the flag list is
  # how a harness discovers a verb, AI_FIRST.md §2b names `mod context
  # --budget N` as one of the loop's seven, and every other verb in this
  # binary — `check`, `fix`, `test`, `run`, `build`, `doc`, `bind` —
  # answers `--help` with its usage.
  private def mod_context_usage
    <<-USAGE
    Usage: #{Command.program_name} mod context [--json] [--budget N] FILE.iyi

    Print what a change to this module is allowed to know: the exact
    exported surface of every module FILE.iyi imports, and nothing's body.

    Switches:
        --json          the same pack as data, one object per import
        --budget N      cut the text pack to about N tokens by a defined
                        ladder — docs off from the last import backwards,
                        then surfaces collapse to a header naming the
                        module and what eliding it cost. Every import is
                        named at every budget. A token is four bytes
    USAGE
  end

  private def mod_diff_usage
    <<-USAGE
    Usage: #{Command.program_name} mod diff [--exit-code] OLD.iyimod NEW.iyimod

    Say whether a change reaches this module's consumers, and what changed
    if it does: interface, implementation, source, and the dependencies it
    was compiled against.

    Switches:
        --exit-code     exit 1 when consumers have to be rebuilt, 0 when
                        they do not — for a branch in a script
    USAGE
  end

  private def mod_dump_usage
    <<-USAGE
    Usage: #{Command.program_name} mod dump [--declarations | --json] FILE.iyimod

    Print a .iyimod as text: what a module offers a consumer, read back out
    of the artifact itself.

    Switches:
        --declarations  the iyi declarations a consumer compiles against,
                        which is what `import` reads instead of the source
        --json          the module's exported surface as data: signatures,
                        types, fields, impls, and the interface hash
    USAGE
  end

  private def mod_dump
    # Not a flag on the command, because it selects between two whole outputs:
    # the file as it is stored, and the file as the compiler reads it. The
    # second exists so that a diagnostic pointing into a `.iyimod` can be
    # looked at — the text it names is the text this prints.
    #
    # Read from either side of the path, because that is where a person writes
    # them: the two flags used to be looked for only *before* the filename, so
    # `mod dump FILE --json` printed the prose and exited 0 with the flag
    # discarded, and a second path was dropped without a word.
    declarations = false
    as_json = false
    filename = nil
    while option = options.shift?
      case option
      when "--declarations"
        declarations = true
      when "--json"
        as_json = true
      when "--help", "-h"
        puts mod_dump_usage
        exit
      when .starts_with?('-')
        abort! "mod dump: unknown flag #{option}", :USAGE_ERROR
      else
        if filename
          abort! "unexpected '#{option}' after the .iyimod path", :USAGE_ERROR
        end
        filename = option
      end
    end

    # `.presence`: `mod dump ""` answered `no such file: `, a sentence with
    # a hole where the name goes.
    filename = filename.presence
    unless filename
      abort! "expected a .iyimod path", :USAGE_ERROR
    end
    if declarations && as_json
      abort! "--declarations and --json are two different outputs; ask for one", :USAGE_ERROR
    end

    unless File.file?(filename)
      # A directory is there, so "no such file" was not true of it. The
      # sentence says which of the two it is; `no such file` is kept for a
      # path that really is not there.
      if Dir.exists?(filename)
        abort! "#{filename} is a directory, not a .iyimod", :USAGE_ERROR
      end
      abort! "no such file: #{filename}", :USAGE_ERROR
    end

    begin
      # The one reader that wants the object code. `import` does not — it is a
      # front-end reader and seeks past the section — but a dump that silently
      # left out the largest thing in the file would be the opposite of what
      # this command is for.
      artifact = IyiMod.read(filename, want_object_code: !(declarations || as_json))
      if declarations
        IyiMod.declarations artifact, STDOUT
      elsif as_json
        JSON.build(STDOUT, indent: 2) { |json| IyiMod.api_json(artifact, json) }
        STDOUT.puts
      else
        IyiMod.dump artifact, STDOUT
      end
    rescue ex : IyiMod::Error
      abort! ex.message.to_s, :USAGE_ERROR
    end
  end

  # iyi: `iyi mod diff OLD NEW` — did this change reach anybody?
  #
  # The question every consumer of a module asks and nobody could ask the
  # artifact: a change that leaves the interface alone cannot make a consumer
  # recompile, and one that does not is the only kind that can (SPEC.md IV.3).
  # The three hashes already answer it — they are in `dump` — and what was
  # missing was a command that compares two files and says which of the three
  # moved.
  #
  # The names beneath it are for when the answer is "yes": knowing that the
  # interface changed is worth less than knowing that `title` is gone.
  private def mod_diff
    # `git diff`'s spelling, and for its reason: "the interface moved" is an
    # answer rather than a failure, so it is worth an exit code only when
    # somebody has asked for one to branch on.
    #
    # Either side of the paths, and nothing left over: a third path used to be
    # dropped in silence, and `--exit-code` after them went unread.
    exit_code = false
    paths = [] of String
    while option = options.shift?
      case option
      when "--exit-code"
        exit_code = true
      when "--help", "-h"
        puts mod_diff_usage
        exit
      when .starts_with?('-')
        abort! "mod diff: unknown flag #{option}", :USAGE_ERROR
      else
        if paths.size == 2
          abort! "unexpected '#{option}' after the two .iyimod paths", :USAGE_ERROR
        end
        paths << option
      end
    end

    unless paths.size == 2
      abort! "expected two .iyimod paths", :USAGE_ERROR
    end
    old_path = paths[0]
    new_path = paths[1]

    old_artifact = read_iyimod(old_path)
    new_artifact = read_iyimod(new_path)

    if old_artifact.module_name != new_artifact.module_name
      abort! "these are different modules: #{old_artifact.module_name} and #{new_artifact.module_name}", :USAGE_ERROR
    end

    old_hashes = old_artifact.hashes
    new_hashes = new_artifact.hashes
    interface_moved = old_hashes.interface != new_hashes.interface

    # Each line says what it is about, because the three are easy to confuse and
    # the middle one is the surprising one: an ordinary body stays behind as
    # machine code and moves nothing here, while a macro's body travels and
    # does.
    moved = ->(before : String, after : String) { before == after ? "unchanged" : "changed  " }

    puts "module          #{new_artifact.module_name}"
    puts "interface       #{moved.call(old_hashes.interface, new_hashes.interface)}  what a consumer type-checks against"
    puts "implementation  #{moved.call(old_hashes.implementation, new_hashes.implementation)}  the bodies a consumer compiles: macros, generics, the initialiser"
    puts "source          #{moved.call(old_hashes.source, new_hashes.source)}  the file"

    # The fourth thing an artifact records, and the one a source-shaped
    # reading misses: what it was compiled *against*. A module whose own
    # file, interface and bodies are identical is a different artifact when
    # a dependency moved under it — `iyi.mod` bumped from `liba v1.0.0` to
    # `v1.1.0` left every line above reading "unchanged" while the program
    # printed something else. IV.3 keeps those hashes on the edge for
    # exactly this, and the verdict has to read them.
    old_edges = old_artifact.imports.to_h { |edge| {edge.module_name, edge} }
    new_edges = new_artifact.imports.to_h { |edge| {edge.module_name, edge} }
    dependencies_moved = [] of String
    (old_edges.keys | new_edges.keys).sort!.each do |name|
      before_edge = old_edges[name]?
      after_edge = new_edges[name]?
      case
      when before_edge.nil?
        dependencies_moved << "#{name} — new"
      when after_edge.nil?
        dependencies_moved << "#{name} — gone"
      when before_edge.interface != after_edge.interface
        dependencies_moved << "#{name} — interface"
      when before_edge.implementation != after_edge.implementation
        dependencies_moved << "#{name} — implementation"
      end
    end
    puts "dependencies    #{dependencies_moved.empty? ? "unchanged" : "changed  "}  what this module was compiled against"

    # The verdict is over *both* of the first two lines, and the second one
    # is why: a body that travels is compiled by the consumer, so moving
    # one moves the consumer's own machine code. Read on the interface
    # alone this said "consumers do not have to be rebuilt" about a
    # block-taking `def` whose body had changed — a build system branching
    # on it would have kept a program printing the old answer, which is
    # the one way a boundary can be wrong quietly rather than loudly.
    #
    # An ordinary body is not in either hash and rightly moves nothing: it
    # stays behind as machine code, and a consumer relinks it without
    # compiling anything. A doc edit moves neither — the interface is
    # encoded without docs and a comment is not part of a body — so the
    # rebuild-nobody case the loop is named for is still the common one.
    implementation_moved = old_hashes.implementation != new_hashes.implementation

    if interface_moved
      before = iyi_export_lines(old_artifact)
      after = iyi_export_lines(new_artifact)

      puts
      (before - after).each { |line| puts "  gone   #{line}" }
      (after - before).each { |line| puts "  new    #{line}" }
      puts
      puts "Consumers have to be rebuilt: what they compile against moved."
      exit 1 if exit_code
    elsif implementation_moved
      # Nothing to list: no name changed. What changed is a body the
      # consumer compiles for itself.
      puts
      puts "Consumers have to be rebuilt: what they compile against is the same, and a body they compile moved."
      exit 1 if exit_code
    elsif !dependencies_moved.empty?
      # This module's own three hashes agree and it is still another
      # artifact: it was compiled against something that moved. Its
      # consumers relink it, so what they need is this file rebuilt — and
      # a build system reading "nothing to do" here would ship the old one.
      puts
      dependencies_moved.each { |line| puts "  moved  #{line}" }
      puts
      puts "This module has to be rebuilt: its own surface is the same, and what it was compiled against moved."
      exit 1 if exit_code
    else
      puts
      puts "Consumers do not have to be rebuilt: what they compile against is the same."
    end
  end

  # What a consumer can name, as text, so that two of them can be compared.
  # A module's surface, one line per thing a consumer can name - what
  # `mod diff` lists as gone and new, and what `mod release` weighs: functions, `pub`
  # types with their parameters, their methods and the types inside them,
  # impls and macros.
  private def iyi_export_lines(artifact : IyiMod::Artifact) : Array(String)
    lines = [] of String
    exports = artifact.exports
    # A private def travels with the generic bodies that call it, and is
    # nobody's to call: not surface.
    exports.functions.each { |signature| lines << IyiMod.render_signature(signature) unless signature.visibility == "private" }
    exports.types.each { |declaration| iyi_export_type_lines(declaration, "", lines) }
    exports.impls.each do |entry|
      named = entry.trait_arguments.empty? ? entry.trait_name : "#{entry.trait_name}(#{entry.trait_arguments.join(", ")})"
      lines << "impl #{named} for #{entry.type_name}"
    end
    artifact.macro_bodies.each { |source| lines << source.lines.first.strip }
    lines.uniq!.sort!
  end

  private def iyi_export_type_lines(declaration : IyiMod::TypeDecl, outer : String, lines : Array(String)) : Nil
    return unless declaration.visibility == "pub"
    name = "#{outer}#{declaration.name}"
    parameters = declaration.type_parameters.empty? ? "" : "(#{declaration.type_parameters.join(", ")})"
    lines << "#{declaration.kind} #{name}#{parameters}"
    declaration.methods.each do |signature|
      lines << "#{name}.#{IyiMod.render_signature(signature)}" unless signature.visibility == "private"
    end
    declaration.types.each { |inner| iyi_export_type_lines(inner, "#{name}::", lines) }
  end

  private def read_iyimod(path : String) : IyiMod::Artifact
    unless File.file?(path)
      if Dir.exists?(path)
        abort! "#{path} is a directory, not a .iyimod", :USAGE_ERROR
      end
      abort! "no such file: #{path}", :USAGE_ERROR
    end

    IyiMod.read(path)
  rescue ex : IyiMod::Error
    abort! ex.message.to_s, :USAGE_ERROR
  end
end
