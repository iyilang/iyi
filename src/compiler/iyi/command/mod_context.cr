# iyi: `iyi mod context FILE.iyi` — the context pack (AI_FIRST.md §2 #2).
#
# The minimal text a model needs before editing one module: the exact
# exported surface of every module the file imports, and nothing's body.
# R-2 makes that a *defined set* — the interface is what `pub` wrote — and
# R-1 makes it cheap to produce: every import is compiled alone, front end
# only, against nothing but its own imports' declarations. The file itself
# is never compiled, because the caller is presumed to be mid-edit; a pack
# you can only get from a program that already builds would ground nothing.
#
# Output is one block per import, in import order: a header naming the path
# as the file wrote it, then the same declaration text `import` itself
# reads (`mod dump --declarations`). `--json` emits the same surfaces as
# data, each with its interface hash — the cache key: unchanged hash,
# unchanged everything.
#
# An import that fails to resolve or compile degrades to a block that says
# so; the pack for the others still prints, because a half-broken tree is
# the normal state of a tree being edited.
require "file_utils"
require "../mod/installer"

class Iyi::Command
  # One import's block in the pack: what the file wrote, the surface it
  # resolved to, why it did not, and — for a module handed on by a
  # facade's `pub import` — the import that hands it on.
  alias ContextBlock = {String, IyiMod::Artifact?, String, String?}

  # `── import app/thing ──`, and for a re-export the facade it came
  # through, because that is the line a reader has to write to reach it.
  private def mod_context_header(written : String, via : String?) : String
    return "── import #{written} ──" unless via
    "── import #{via} → #{written} (re-exported) ──"
  end

  # iyi: the modules a facade hands on. `pub import` is a promise to the
  # consumer — a file that imports the facade may import names from the module the
  # facade re-exported, without an import of its own (R-2b) — and the pack
  # showed only what the file's own import lines named. So a consumer
  # reading its context saw a facade with two functions on it, wrote
  # `import deep/core::{core_value}` anyway because the compiler accepts
  # it, and had no way to learn what `deep/core` offered. Every module the
  # consumer may name is in the pack now, marked with the facade that
  # hands it on, and the budget ladder cuts them like any other block.
  #
  # Breadth-first and by module name, so a facade of a facade arrives once
  # and a cycle cannot spin: the artifacts are the ones each block's own
  # compile already emitted into the same directory.
  private def mod_context_reexports(blocks : Array(ContextBlock), emit_dir : String, artifact_root : String) : Nil
    seen = Set(String).new(blocks.map(&.[0]))
    index = 0
    while index < blocks.size
      written, artifact, _, _ = blocks[index]
      index += 1
      next unless artifact
      artifact.imports.each do |edge|
        next unless edge.exported
        next unless seen.add?(edge.module_name)
        handed = mod_context_emitted(edge.module_name, emit_dir) ||
                 mod_context_artifact(edge.module_name, artifact_root)
        next unless handed
        blocks << {edge.module_name, handed, "", written}
      end
    end
  end

  # An artifact this run's own compiles wrote: `--emit-iyimod DIR` names a
  # file after the module path, so a re-exported module is already on disk
  # by the time the facade's block is read back.
  private def mod_context_emitted(name : String, emit_dir : String) : IyiMod::Artifact?
    path = Iyi.native_path(File.join(emit_dir, "#{name}.iyimod"))
    return nil unless File.file?(path)
    IyiMod.read(path)
  rescue IyiMod::Error
    nil
  end

  private def mod_context
    # Read from either side of the path, and refuse what is left over. The
    # loop used to stop at the first word that was not a flag, so
    # `mod context file.iyi --json` printed the *text* pack and exited 0 —
    # the flag the caller wrote was dropped on the floor, and a caller
    # piping that into a JSON reader learns about it somewhere else
    # entirely. A second path went the same way. `mod dump` and `mod diff`
    # read their arguments this way for the same reason.
    as_json = false
    budget = nil
    filename = nil
    while option = options.shift?
      case option
      when "--json"
        as_json = true
      when "--budget"
        value = options.shift?
        budget = value.try(&.to_i?)
        abort! "--budget takes a token count", :USAGE_ERROR unless budget && budget > 0
      when "--help", "-h"
        puts mod_context_usage
        exit
      when .starts_with?('-')
        abort! "mod context: unknown flag #{option}", :USAGE_ERROR
      else
        if filename
          abort! "unexpected '#{option}' after the .iyi path", :USAGE_ERROR
        end
        filename = option
      end
    end
    if as_json && budget
      abort! "--budget shapes the text pack; --json is already data — slice it yourself", :USAGE_ERROR
    end

    unless filename && filename.ends_with?(".iyi")
      abort! "expected a .iyi file", :USAGE_ERROR
    end
    unless File.file?(filename)
      # A directory that is there is not a file that is missing: "no such
      # file" sends the reader to `ls`, where they find it. The sentence is
      # `doc`'s and `mod dump`'s, because it is the same mistake.
      if Dir.exists?(filename)
        abort! "#{filename} is a directory, not a .iyi module", :USAGE_ERROR
      end
      abort! "no such file: #{filename}", :USAGE_ERROR
    end
    filename = File.expand_path(filename)
    entry_dir = File.dirname(filename)

    imports = mod_context_imports(filename)
    table =
      begin
        @mod_context_table = Mod::Installer.table_for(entry_dir)
      rescue ex : Mod::ModError
        abort! ex.message.to_s, :USAGE_ERROR
      end

    emit_dir = File.tempname("iyi-context", nil)
    Dir.mkdir_p(emit_dir)
    begin
      # The workspace root rather than the entry's directory, for the
      # artifacts alone: IV.6 read backwards, the way the server and
      # `iyi test` read it. A file whose path ends with its own `module`
      # header's path names the root above both, and that is where a
      # workspace keeps `mods`.
      artifact_root = Compiler.header_root_of(filename, File.read(filename)) || entry_dir
      blocks = [] of ContextBlock
      imports.each do |written|
        blocks << mod_context_block(written, entry_dir, table, emit_dir, artifact_root)
      end
      mod_context_reexports(blocks, emit_dir, artifact_root)

      if as_json
        JSON.build(STDOUT) do |json|
          json.object do
            json.field "file", filename
            json.field "imports" do
              json.array do
                blocks.each do |(written, artifact, failure, via)|
                  json.object do
                    json.field "import", written
                    json.field "via", via if via
                    if artifact
                      json.field "api" { IyiMod.api_json(artifact, json) }
                    else
                      json.field "error", failure
                    end
                  end
                end
              end
            end
          end
        end
        STDOUT.puts
      elsif budget
        mod_context_budgeted(blocks, budget)
      else
        if blocks.empty?
          puts "#{filename} imports nothing; its context is the prelude."
        end
        blocks.each do |(written, artifact, failure, via)|
          puts mod_context_header(written, via)
          if artifact
            print mod_context_consumer_lines(written, artifact, via)
            IyiMod.surface artifact, STDOUT
          else
            puts "  (#{failure})"
          end
          puts
        end
      end
    ensure
      FileUtils.rm_rf(emit_dir)
    end
  end

  # The pack, cut to a token budget by a defined ladder — never by
  # truncation. A token is counted as four bytes of UTF-8: crude, stated,
  # and the same on every machine, which is what a budget needs.
  #
  # Two passes, both from the *last* import backwards, because import
  # order is the file's own statement of what matters most: first the
  # docs come off (signatures survive — they are the contract, docs are
  # the commentary), then whole surfaces collapse to a header that names
  # the module and what eliding it cost. Every import is always named:
  # a pack that silently dropped an import would ground a wrong edit.
  private def mod_context_budgeted(blocks : Array(ContextBlock), budget : Int32) : Nil
    if blocks.empty?
      puts "(imports nothing; the context is the prelude)"
      return
    end

    render = ->(block : ContextBlock, docs : Bool) do
      written, artifact, failure, via = block
      String.build do |io|
        io << mod_context_header(written, via) << '\n'
        if artifact
          io << mod_context_consumer_lines(written, artifact, via)
          IyiMod.surface artifact, io, docs: docs
        else
          io << "  (" << failure << ")\n"
        end
        io << '\n'
      end
    end
    tokens = ->(text : String) { (text.bytesize + 3) // 4 }

    texts = blocks.map { |block| render.call(block, true) }
    total = texts.sum { |text| tokens.call(text) }

    (blocks.size - 1).downto(0) do |index|
      break if total <= budget
      lean = render.call(blocks[index], false)
      total -= tokens.call(texts[index]) - tokens.call(lean)
      texts[index] = lean
    end

    (blocks.size - 1).downto(0) do |index|
      break if total <= budget
      written, _, _, via = blocks[index]
      cost = tokens.call(texts[index])
      header = "#{mod_context_header(written, via)} (surface elided: ~#{cost} tokens; raise --budget to see it)\n\n"
      total -= cost - tokens.call(header)
      texts[index] = header
    end

    texts.each { |text| STDOUT << text }
    puts "# pack: ~#{total} tokens of #{budget} budgeted"
  end

  # The two lines a consumer writes to reach what the block shows, spelled
  # out with every exported name in them. The surface says what a module
  # offers and nothing about how a file names it; the raw sources a pack
  # replaces carry their *own* `import` lines and so show the
  # spelling by accident, and the rounds arm of `bench/context_pack.py`
  # lost a round to exactly that — a model that wrote `import kemal/dsl`,
  # called `before_all` bare, and was refused for the missing `using`
  # (the keyword `import X::{...}` replaced; AI_FIRST.md §5, the third
  # run). The language server's completion attaches the same pair to
  # every export it offers.
  private def mod_context_consumer_lines(written : String, artifact : IyiMod::Artifact, via : String? = nil) : String
    names = artifact.exports.functions.map(&.name)
    artifact.exports.types.each do |declaration|
      names << declaration.name if declaration.visibility == "pub"
    end
    names.uniq!
    String.build do |io|
      io << "# A file that uses this writes, after its own `module` line:\n"
      if names.empty?
        # Nothing to bring into scope, so the import alone. A module handed
        # on by a facade is reached by importing the facade: `pub import`
        # is what makes it reachable without an edge of its own (R-2b).
        io << "#   import " << (via || written) << '\n'
      else
        # One line loads the module and names what it brings into scope.
        io << "#   import " << written << "::{"
        names.join(io, ", ")
        io << "}   # or `import " << written << "::*` for every name\n"
      end
      # A package module's qualified name is under the package's name, and
      # nothing in its own `module` line below says so.
      if qualified = mod_context_package_type(written)
        io << "# qualified, the module is " << qualified << ": " << qualified << ".name\n"
      end
    end
  end

  @mod_context_table = [] of {String, String}

  # `Liba::Colors` for `example.com/liba/colors`, when *written* is a
  # package module the package's name is put in front of; nil otherwise.
  private def mod_context_package_type(written : String) : String?
    path = Mod::Installer.expand(written, @mod_context_table)
    @mod_context_table.each do |(prefix, _)|
      next if prefix.starts_with?('@')
      inner =
        if path == prefix
          Mod::ModFile.split_major(prefix)[0].rpartition('/')[2]
        elsif path.starts_with?("#{prefix}/")
          path[(prefix.size + 1)..]
        else
          next
        end
      segments = inner.split('/')
      package = Mod::ModFile.package_name(prefix)
      return nil unless package && segments.first? != package
      return ([package] + segments).map(&.camelcase).join("::")
    end
    nil
  end

  # The file's imports, in order, by parsing — never by compiling. A file
  # being edited has to be parseable to be grounded, and no more.
  private def mod_context_imports(filename : String) : Array(String)
    parser = Parser.new(File.read(filename))
    parser.filename = filename
    nodes = parser.parse
    imports = [] of String
    mod_context_collect(nodes, imports)
    imports.uniq!
  rescue ex : CodeError
    abort! "cannot parse #{filename}: #{ex.message}", :USAGE_ERROR
  end

  private def mod_context_collect(node : ASTNode, into : Array(String)) : Nil
    case node
    when ImportDecl
      into << node.path.join('/')
    when Expressions
      node.expressions.each { |child| mod_context_collect(child, into) }
    when ModuleDef
      mod_context_collect(node.body, into)
    else
      # Anything else cannot hold a top-level import.
    end
  end

  # One import's surface: resolve the path the way a build would, compile
  # that module alone with the front end, and read back the artifact it
  # emitted. `{written, artifact or nil, failure or ""}`.
  #
  # The compile is of a synthetic one-line entry that *imports* the module,
  # because artifacts are written for what a build imports, not for what it
  # is. The module's root travels as `IYI_PATH` and the import is the
  # in-package path, so a package's surface is produced without a manifest
  # — which is the point: the module compiles alone (R-1), and this is that
  # fact worn as a tool.
  private def mod_context_block(written : String, entry_dir : String, table : Array({String, String}), emit_dir : String, artifact_root : String) : ContextBlock
    source_path, expected_name = mod_context_resolve(written, entry_dir, table)
    unless source_path
      # No source anywhere, which is how a library arrives (III.7): the
      # artifact *is* the surface, and reading one costs nothing next to
      # the compile this method does for a module that has a file. A
      # workspace that builds with `--use-iyimod mods` was told its
      # imports do not resolve — the same hole the language server had,
      # in the answer a model reads.
      if artifact = mod_context_artifact(written, artifact_root)
        return {written, artifact, "", nil}
      end
      return {written, nil, "does not resolve: no file, no artifact and no requirement covers it", nil}
    end
    # The root the module path hangs under, reached by dropping a directory
    # per segment of it. Chomping the name off the end arrived there only by
    # coincidence: `File.join` leaves a module path's own `/` alone and
    # spells the joint with `\`, so the tail matched while the `chomp("/")`
    # after it fired on no Windows path at all and the root kept a separator
    # glued to its end. `Path` needs neither coincidence.
    root = ::Path[source_path]
    (expected_name.count('/') + 1).times { root = root.parent }
    module_root = root.to_s

    entry = File.join(emit_dir, "context_entry.iyi")
    File.write(entry, "import #{expected_name}\n")

    compiler = Compiler.new
    compiler.prelude = "iyi/prelude"
    compiler.no_codegen = true
    compiler.iyi_mod_table = table
    # And the workspace's artifacts, for what *this* module imports: a
    # module with a file can depend on one without (III.7), and compiling
    # it alone without them answered "does not compile alone" about a
    # program that builds. See `Compiler.workspace_artifacts`.
    if artifacts = Compiler.workspace_artifacts(artifact_root)
      compiler.use_iyimod = artifacts
      compiler.iyi_prefers_source = true
    end
    compiler.emit_iyimod = emit_dir
    compiler.stdout = IO::Memory.new
    compiler.stderr = IO::Memory.new
    previous_path = ENV["IYI_PATH"]?
    begin
      # The delimiter is the platform's, because `IyiPath` splits on the
      # platform's: a `:`-joined list is one unusable entry on Windows.
      ENV["IYI_PATH"] = ([module_root] + (previous_path ? [previous_path] : IyiPath.default_paths)).join(Process::PATH_DELIMITER)
      compiler.compile(
        Compiler::Source.new(entry, File.read(entry)),
        File.join(emit_dir, "unused"))
    rescue ex : Iyi::Error | Iyi::CodeError
      # The diagnostic rather than the wrapper `while importing "X"` it
      # arrives in — the same unwrapping `iyi doc` does, and for the same
      # reason: this answer is what a reader acts on.
      deepest = Iyi.deepest_error(ex)
      return {written, nil, "does not compile alone: #{deepest.message.to_s.lines.first?}", nil}
    ensure
      previous_path ? (ENV["IYI_PATH"] = previous_path) : ENV.delete("IYI_PATH")
    end

    Dir.glob(::Path[emit_dir].to_posix.join("**", "*.iyimod")) do |candidate|
      begin
        artifact = IyiMod.read(candidate)
        return {written, artifact, "", nil} if artifact.module_name == expected_name
      rescue IyiMod::Error
        next
      end
    end
    {written, nil, "compiled, but no artifact carries module '#{expected_name}'", nil}
  end

  # The same resolution order the build uses: the requirement table by
  # longest prefix, then the entry file's directory, then `IYI_PATH`. The
  # name an artifact carries is the in-package path for a package, the
  # written path otherwise.
  private def mod_context_resolve(written : String, entry_dir : String, table : Array({String, String})) : {String?, String}
    candidate, name = mod_context_names(written, entry_dir, table)
    {File.file?(candidate) ? candidate : nil, name}
  end

  # iyi: the artifact a workspace keeps for *written*, or nil. `mods`
  # beside the root, which is the name the tree's every example uses and
  # the one `Lsp::Analysis` looks under.
  private def mod_context_artifact(written : String, artifact_root : String) : IyiMod::Artifact?
    path = Iyi.native_path(File.join(artifact_root, Compiler::ARTIFACT_DIR, "#{written}.iyimod"))
    return nil unless File.file?(path)
    IyiMod.read(path)
  rescue IyiMod::Error
    nil
  end

  # The file an import names and the module name it means, whether or not
  # the file is there. A module's path is its file's path (SPEC.md R-1), so
  # `import app/lib` names `app/lib.iyi` after the file is deleted exactly
  # as it did before — which is what lets `check --affected app/lib.iyi`
  # find the importers a deletion breaks.
  private def mod_context_names(written : String, entry_dir : String, table : Array({String, String})) : {String, String}
    # A short name the manifest gives is the path it names, as in a build.
    written = Mod::Installer.expand(written, table)
    table.each do |(prefix, checkout)|
      inner =
        if written == prefix
          # A `/vN` suffix is a major version, not the package's name.
          Mod::ModFile.split_major(prefix)[0].rpartition('/')[2]
        elsif written.starts_with?("#{prefix}/")
          written[(prefix.size + 1)..]
        else
          next
        end
      return {File.join(checkout, "#{inner}.iyi"), inner}
    end

    local = File.join(entry_dir, "#{written}.iyi")
    return {local, written} if File.file?(local)

    # Then the search path, which is where the library lives: a build
    # resolves `import std/path` from `IYI_PATH` and this did not look
    # there at all, so every import of a std module — every import most
    # programs have — was reported as "does not resolve: no file and no
    # requirement covers it" about a module the same file compiles
    # against. `iyi mod context` is the grounding AI_FIRST.md §2 offers a
    # model, and it was answering that the standard library is not there.
    #
    # Probed rather than assumed, and only after the entry's own
    # directory, because a file that is *missing* has to keep naming the
    # path it would have had: `check --affected app/lib.iyi` finds the
    # importers a deletion breaks by that name.
    IyiPath.default_paths.each do |entry|
      candidate = File.join(entry, "#{written}.iyi")
      return {candidate, written} if File.file?(candidate)
    end

    {local, written}
  end
end
