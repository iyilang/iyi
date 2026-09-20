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
        Mod::Installer.table_for(entry_dir)
      rescue ex : Mod::ModError
        abort! ex.message.to_s, :USAGE_ERROR
      end

    emit_dir = File.tempname("iyi-context", nil)
    Dir.mkdir_p(emit_dir)
    begin
      blocks = imports.map do |written|
        mod_context_block(written, entry_dir, table, emit_dir)
      end

      if as_json
        JSON.build(STDOUT) do |json|
          json.object do
            json.field "file", filename
            json.field "imports" do
              json.array do
                blocks.each do |(written, artifact, failure)|
                  json.object do
                    json.field "import", written
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
        blocks.each do |(written, artifact, failure)|
          puts "── import #{written} ──"
          if artifact
            print mod_context_consumer_lines(written, artifact)
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
  private def mod_context_budgeted(blocks : Array({String, IyiMod::Artifact?, String}), budget : Int32) : Nil
    if blocks.empty?
      puts "(imports nothing; the context is the prelude)"
      return
    end

    render = ->(block : {String, IyiMod::Artifact?, String}, docs : Bool) do
      written, artifact, failure = block
      String.build do |io|
        io << "── import " << written << " ──\n"
        if artifact
          io << mod_context_consumer_lines(written, artifact)
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
      written = blocks[index][0]
      cost = tokens.call(texts[index])
      header = "── import #{written} ── (surface elided: ~#{cost} tokens; raise --budget to see it)\n\n"
      total -= cost - tokens.call(header)
      texts[index] = header
    end

    texts.each { |text| STDOUT << text }
    puts "# pack: ~#{total} tokens of #{budget} budgeted"
  end

  # The two lines a consumer writes to reach what the block shows, spelled
  # out with every exported name in them. The surface says what a module
  # offers and nothing about how a file names it; the raw sources a pack
  # replaces carry their *own* `import`/`using` lines and so show the
  # spelling by accident, and the rounds arm of `bench/context_pack.py`
  # lost a round to exactly that — a model that wrote `import kemal/dsl`,
  # called `before_all` bare, and was refused for the missing `using`
  # (AI_FIRST.md §5, the third run). The language server's completion
  # attaches the same pair to every export it offers.
  private def mod_context_consumer_lines(written : String, artifact : IyiMod::Artifact) : String
    names = artifact.exports.functions.map(&.name)
    artifact.exports.types.each do |declaration|
      names << declaration.name if declaration.visibility == "pub"
    end
    names.uniq!
    String.build do |io|
      io << "# A file that uses this writes, after its own `module` line:\n"
      io << "#   import " << written << '\n'
      unless names.empty?
        io << "#   using " << written << "::{"
        names.join(io, ", ")
        io << "}   # or `using " << written << "` for every name\n"
      end
    end
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
  private def mod_context_block(written : String, entry_dir : String, table : Array({String, String}), emit_dir : String) : {String, IyiMod::Artifact?, String}
    source_path, expected_name = mod_context_resolve(written, entry_dir, table)
    unless source_path
      return {written, nil, "does not resolve: no file and no requirement covers it"}
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
      return {written, nil, "does not compile alone: #{ex.message.to_s.lines.first?}"}
    ensure
      previous_path ? (ENV["IYI_PATH"] = previous_path) : ENV.delete("IYI_PATH")
    end

    Dir.glob(::Path[emit_dir].to_posix.join("**", "*.iyimod")) do |candidate|
      begin
        artifact = IyiMod.read(candidate)
        return {written, artifact, ""} if artifact.module_name == expected_name
      rescue IyiMod::Error
        next
      end
    end
    {written, nil, "compiled, but no artifact carries module '#{expected_name}'"}
  end

  # The same resolution order the build uses: the requirement table by
  # longest prefix, then the entry file's directory, then `IYI_PATH`. The
  # name an artifact carries is the in-package path for a package, the
  # written path otherwise.
  private def mod_context_resolve(written : String, entry_dir : String, table : Array({String, String})) : {String?, String}
    candidate, name = mod_context_names(written, entry_dir, table)
    {File.file?(candidate) ? candidate : nil, name}
  end

  # The file an import names and the module name it means, whether or not
  # the file is there. A module's path is its file's path (SPEC.md R-1), so
  # `import app/lib` names `app/lib.iyi` after the file is deleted exactly
  # as it did before — which is what lets `check --affected app/lib.iyi`
  # find the importers a deletion breaks.
  private def mod_context_names(written : String, entry_dir : String, table : Array({String, String})) : {String, String}
    table.each do |(prefix, checkout)|
      inner =
        if written == prefix
          prefix.rpartition('/')[2]
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
