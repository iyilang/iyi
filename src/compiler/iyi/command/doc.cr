# iyi: `iyi doc` — III.8's doc verb, a renderer over data that exists.
#
# What it prints is `IyiMod.surface`: the caller's view of a module —
# exported functions and types with their doc comments, no bodies, no
# private anything. The same document `iyi mod context` grounds an edit
# with, served for one module at a time, because "what can I call here"
# is a question a person asks too.
#
#     iyi doc lib/thing.iyimod    # from an artifact, source not needed
#     iyi doc src/thing.iyi       # from source: the module is compiled
#                                 # alone, front end only, and read back
#     iyi doc String              # a type of the prelude: what a String
#                                 # can do, the prelude's own comments
#     iyi doc prelude             # the prelude's types, one line each
#
# No HTML, no site, no theme. The document is text because the consumers
# are a terminal and a model, and III.7's registry index — `Exports`
# served as data — is where anything richer belongs.
require "file_utils"

class Iyi::Command
  private def doc
    filename = options.shift?
    case
    when filename.nil? || filename == "--help" || filename == "-h"
      puts doc_usage
      exit
    when filename.ends_with?(".iyimod")
      doc_file! filename, ".iyimod"
      artifact =
        begin
          IyiMod.read(filename)
        rescue ex : IyiMod::Error
          abort! ex.message.to_s, :USAGE_ERROR
        end
      IyiMod.surface artifact, STDOUT
    when filename.ends_with?(".iyi")
      doc_file! filename, ".iyi module"
      doc_from_source(File.expand_path(filename))
    when filename == "prelude"
      doc_prelude_index
    when prelude_type_name?(filename)
      doc_prelude_type(filename)
    when resolved = doc_module_path(filename)
      doc_from_source(resolved)
    else
      abort! "expected a module path (`#{Command.program_name} doc app/greeter`), " \
             "a .iyi file, a .iyimod artifact, or a type of the prelude " \
             "(`#{Command.program_name} doc String`)", :USAGE_ERROR
    end
  end

  # `String`, `Array`, `Hash::Entry`: a capital, then letters, digits,
  # underscores and `::`. Spelled out rather than a regex, which would put
  # libpcre on the compiler's floor (SPEC.md III.9).
  private def prelude_type_name?(name : String) : Bool
    return false unless name[0]?.try(&.ascii_uppercase?)
    name.each_char.all? { |char| char.ascii_alphanumeric? || char == '_' || char == ':' }
  end

  # iyi: the file a module path names, found the way `import` finds it —
  # the project root, then every `IYI_PATH` entry, `.iyi` before `.cr`
  # (R-1, IV.6).
  #
  # `iyi doc app/greeter` answered "expected a .iyi module, a .iyimod
  # artifact, or a type of the prelude" for the one spelling this language
  # is built on: a module's path *is* its file's path, it is what `import`
  # takes, what `mod context` prints as a header, and what every error
  # about a module names. Asking the doc verb for `std/set` — a module the
  # same binary will happily ground an edit against — was a usage error.
  private def doc_module_path(path : String) : String?
    return nil if path.empty? || path.starts_with?('-') || path.ends_with?(".cr")

    candidates = [File.join(Dir.current, "#{path}.iyi"), File.join(Dir.current, "#{path}.cr")]
    IyiPath.new(iyi_path_entries).entries.each do |entry|
      candidates << File.join(entry, "#{path}.iyi")
      candidates << File.join(entry, "#{path}.cr")
    end
    candidates.find { |candidate| File.file?(candidate) }
  end

  # The search path this process was given, or the default list when it
  # was given none — `IyiPath`'s own answer to an unset variable.
  private def iyi_path_entries : Array(String)
    if text = Config.env("PATH").presence
      IyiPath.expand_paths(text.split(Process::PATH_DELIMITER, remove_empty: true))
    else
      IyiPath.default_paths
    end
  end

  # iyi: "no such file" about a path that is there sends the reader to `ls`,
  # where they find it and learn nothing. A directory named `x.iyimod` is a
  # directory, and that is the fact to hand back.
  private def doc_file!(filename : String, kind : String) : Nil
    return if File.file?(filename)
    abort! "#{filename} is a directory, not a #{kind}", :USAGE_ERROR if Dir.exists?(filename)
    abort! "no such file: #{filename}", :USAGE_ERROR
  end

  # The prelude's types, one line each - the kind, the name, the first
  # line of the comment - for the reader who does not know what to ask
  # `iyi doc String` about. The runtime's own machinery (`Iyi*`, the
  # `Lib*` bindings, the `__` names) is not the program's to call and is
  # left out.
  private def doc_prelude_index : Nil
    program = doc_prelude_program
    rows = [] of {String, String, String}
    program.types.each do |name, type|
      next if name.starts_with?("Iyi") || name.starts_with?("Lib") || name.starts_with?("__")
      next if type.is_a?(LibType) || type.is_a?(AliasType)
      next unless type.is_a?(ClassType) || type.is_a?(ModuleType) || type.is_a?(EnumType)
      next if type.private?
      # Declared or reopened by the prelude's own files: the compiler
      # declares `Int128` and `Regex` for every program and the prelude
      # says nothing about them, so they are not what a program has.
      next unless type.locations.try &.any? { |location| in_prelude?(location) }
      summary = type.doc.try(&.lines.first?) || ""
      kind = type.type_desc.lchop("generic ")
      shown = name
      if type.is_a?(GenericType) && !type.type_vars.empty?
        shown = "#{name}(#{type.type_vars.join(", ")})"
      end
      rows << {kind, shown, summary}
    end
    rows.sort_by! { |row| row[1] }
    width = rows.max_of { |row| row[0].size + 1 + row[1].size }
    rows.each do |kind, shown, summary|
      head = "#{kind} #{shown}"
      STDOUT << head
      unless summary.empty?
        STDOUT << " " * (width - head.size + 2) << "# " << summary
      end
      STDOUT << '\n'
    end
  end

  private def in_prelude?(location : Location) : Bool
    # `original_filename`, because the number primitives are written by a
    # macro and a def's location is then the expansion's, a virtual file
    # whose real one is the prelude's.
    #
    # Asked of the posix reading: on Windows the expansion's real file is
    # spelled with `\`, and `iyi doc Int32` there listed `%`, `**` and `-`
    # — the three written by hand — and none of the operators the macro
    # writes: no `+`, no `<`, no `to_i64`. `bench/packages_resolve.sh`
    # said so the first time it ran on Windows.
    filename = location.original_filename
    return false unless filename.is_a?(String)
    posix = ::Path[filename].to_posix.to_s
    posix.includes?("/src/iyi/") || posix.starts_with?("src/iyi/")
  end

  private def doc_prelude_program : Program
    compiler = Compiler.new
    compiler.prelude = "iyi/prelude"
    compiler.no_codegen = true
    compiler.wants_doc = true
    compiler.stdout = IO::Memory.new
    compiler.stderr = IO::Memory.new
    begin
      compiler.top_level_semantic(Compiler::Source.new("doc.iyi", "")).program
    rescue ex : Iyi::Error | Iyi::CodeError
      abort! "the prelude does not compile: #{ex.message.to_s.lines.first?}", :USAGE_ERROR
    end
  end

  # A type of the prelude, the way a person or a model asks "what can a
  # String do": the prelude alone through the front end, the type looked
  # up, its public methods written the way `surface` writes a module's -
  # the header, each method's doc comment and signature, `end`. What the
  # compiler itself puts on every type (`allocate`, which has no line in
  # any file) is left out, as the artifact leaves it out; a primitive the
  # prelude *declares* - `Int32#+`, `<`, `to_i64`, `Proc#call` - is the
  # type's own surface, and leaving it out answered "what can an Int32
  # do" with `abs` and `times` and no arithmetic.
  private def doc_prelude_type(name : String) : Nil
    program = doc_prelude_program
    type = program.lookup_path(name.split("::"))
    unless type.is_a?(Type)
      abort! "the prelude has no type #{name}", :USAGE_ERROR
    end

    io = STDOUT
    if doc = type.doc
      doc.each_line { |line| io << "# " << line << '\n' }
    end
    io << type.type_desc.lchop("generic ") << ' ' << type
    if type.is_a?(GenericType) && !type.type_vars.empty?
      io << '(' << type.type_vars.join(", ") << ')'
    end
    if type.is_a?(ClassType) && (superclass = type.superclass) && superclass.to_s != "Reference" && superclass.to_s != "Struct" && superclass.to_s != "Object"
      io << " < " << superclass
    end
    io << '\n'

    signatures = [] of IyiMod::Signature
    [type, type.metaclass].each do |side|
      side.as?(ModuleType).try &.defs.try &.each_value do |items|
        items.each do |item|
          a_def = item.def
          if a_def.body.is_a?(Primitive)
            next unless (location = a_def.location) && in_prelude?(location)
          end
          next if a_def.visibility.private? || a_def.visibility.protected?
          # `allocate` is the compiler's; the two type-id hooks are Crystal's runtime ABI, which the prelude implements and no program calls.
          next if a_def.name.in?("allocate", "initialize", "crystal_type_id", "crystal_instance_type_id", "class_crystal_instance_type_id") || a_def.name.starts_with?("__")
          signatures << IyiMod.signature(a_def, check_block: false)
        end
      end
    end
    signatures.sort_by! { |signature| {signature.receiver, signature.name} }
    signatures.each do |signature|
      io << '\n'
      signature.doc.each_line { |line| io << "  # " << line << '\n' } unless signature.doc.empty?
      io << "  " << IyiMod.render_signature(signature) << '\n'
    end
    io << "end\n"
  end

  # The module compiled alone — R-1's promise worn as a verb, the same way
  # `mod context` wears it: a synthetic entry imports the module, the
  # front end runs, and the artifact it emits is the answer.
  private def doc_from_source(filename : String) : Nil
    source =
      begin
        File.read(filename)
      rescue ex : IO::Error
        # The rescue chain in `command.cr` would answer this too, but with
        # the runtime's own sentence, which names no path: "Input/output
        # error" on its own is not an answer to `iyi doc <file>`.
        abort! "#{filename} cannot be read: #{ex.os_error.try(&.message) || "the file could not be read"}", :USAGE_ERROR
      end
    unless source.valid_encoding?
      # The same sentence `Compiler#parse` gives for an entry file, because
      # it is the same mistake: `iyi doc` on four bytes of garbage printed
      # "Unhandled exception ... (InvalidByteSequenceError)", a dozen frames
      # of this compiler's own files, and an invitation to file an issue
      # against the other language's tracker.
      abort! "file '#{Iyi.relative_filename(filename)}' is not a valid iyi " \
             "source file: it holds bytes that are not UTF-8 text", :USAGE_ERROR
    end

    module_name = doc_module_header(source)
    unless module_name
      abort! "#{filename} declares no module, and a module is what `doc` reads", :USAGE_ERROR
    end
    module_root = doc_module_root(filename, module_name)
    unless File.expand_path(File.join(module_root, "#{module_name}.iyi")) == filename
      abort! "#{filename} declares `module #{module_name}`, and a module's path " \
             "is its file's path (SPEC.md R-1, IV.6): a module by that name is " \
             "read from #{module_name}.iyi", :USAGE_ERROR
    end

    emit_dir = File.tempname("iyi-doc", nil)
    Dir.mkdir_p(emit_dir)
    begin
      entry = File.join(emit_dir, "doc_entry.iyi")
      File.write(entry, "import #{module_name}\n")

      compiler = Compiler.new
      compiler.prelude = "iyi/prelude"
      compiler.no_codegen = true
      compiler.iyi_mod_table = Mod::Installer.table_for(module_root)
      # The artifacts a workspace keeps, for an import whose source is not
      # there — `check` and the language server read them the same way and
      # for the same reason. This module's own surface still comes from its
      # source, which is the file named on the command line.
      if artifacts = Compiler.workspace_artifacts(module_root)
        compiler.use_iyimod = artifacts
        compiler.iyi_prefers_source = true
      end
      compiler.emit_iyimod = emit_dir
      compiler.stdout = IO::Memory.new
      compiler.stderr = IO::Memory.new
      previous_path = ENV["IYI_PATH"]?
      begin
        # `IyiPath` splits this back apart on `Process::PATH_DELIMITER`,
        # and on Windows that is `;`: a colon-joined list arrives as one
        # entry with a drive letter in the middle of it.
        ENV["IYI_PATH"] = ([module_root] + (previous_path ? [previous_path] : IyiPath.default_paths)).join(Process::PATH_DELIMITER)
        compiler.compile(
          Compiler::Source.new(entry, File.read(entry)),
          File.join(emit_dir, "unused"))
      rescue ex : Iyi::Error | Iyi::CodeError
        # iyi: the diagnostic, not the wrapper around it. The entry imports
        # the module, so an error arrives wrapped in `while importing "X"`
        # (`SemanticVisitor#import_file`) and the first line of *that* names
        # the file the author has just typed and nothing they can act on:
        # `iyi doc twoheaders.iyi` answered `does not compile alone: while
        # importing "twoheaders"` where `iyi run` answered `a file declares
        # one module, and this one already declares 'main'`.
        deepest = Iyi.deepest_error(ex)
        abort! "#{filename} does not compile alone: #{deepest.message.to_s.lines.first?}", :USAGE_ERROR
      ensure
        previous_path ? (ENV["IYI_PATH"] = previous_path) : ENV.delete("IYI_PATH")
      end

      Dir.glob(::Path[emit_dir].to_posix.join("**", "*.iyimod")) do |candidate|
        begin
          artifact = IyiMod.read(candidate)
          if artifact.module_name == module_name
            IyiMod.surface artifact, STDOUT
            return
          end
        rescue IyiMod::Error
          next
        end
      end
      abort! "compiled, but no artifact carries module '#{module_name}'", :USAGE_ERROR
    ensure
      FileUtils.rm_rf(emit_dir)
    end
  end

  # iyi: the name a module *declares*, which is its identity. R-1 makes a
  # module's path its name, and a file's basename is only the last segment
  # of it: `iyi doc deep/inner/thing.iyi` took the basename, imported
  # `thing`, resolved nothing of the sort and printed `module thing` with an
  # empty surface at exit 0 — a documented module reported as exporting
  # nothing, which is the worst of the three answers a verb can give.
  private def doc_module_header(source : String) : String?
    source.each_line do |line|
      text = line.strip
      next if text.empty? || text.starts_with?('#')
      return text.lchop("module").strip if text.starts_with?("module ")
      break
    end
    nil
  end

  # And the directory that name is read from: `deep/inner/thing` is found
  # from the directory above `deep`, so the import resolves the module the
  # file declares rather than another file with the same basename.
  private def doc_module_root(filename : String, module_name : String) : String
    root = File.dirname(filename)
    (module_name.count('/')).times { root = File.dirname(root) }
    root
  end

  private def doc_usage
    <<-USAGE
    Usage: #{Command.program_name} doc MODULE | FILE | TYPE

    Prints a module's exported surface with its doc comments — functions,
    types, methods, impls; no bodies, nothing private. MODULE is a module
    path written the way `import` writes it — `app/greeter`, `std/set` —
    found under the project root and `IYI_PATH`. FILE is a `.iyimod`
    artifact (read directly, source not needed) or a `.iyi` module (compiled
    alone, front end only). TYPE is a type of the prelude - `String`,
    `Array`, `Hash`, `Program` - printed the same way: what it can do, with
    the prelude's own comments; `prelude` lists them all, one line each.
    USAGE
  end
end
