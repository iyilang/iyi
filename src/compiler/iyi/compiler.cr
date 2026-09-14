require "option_parser"
require "file_utils"
require "colorize"
require "crystal/digest/md5"
require "./optimization_mode"
require "./mod/installer"
{% if flag?(:msvc) %}
  require "./loader"
{% end %}
{% unless flag?(:without_mt) %}
  require "wait_group"
{% end %}

module Iyi
  # This exception describes an error in the compiler.
  # It usually leads to an unsuccessful process exit.
  class CompilerError < Exception
    getter status

    def self.new(message, exit : Command::Exit)
      new message, status: exit.to_i
    end

    def initialize(message, *, @status : Int32 = 1)
      super message
    end
  end

  @[Flags]
  enum Debug
    LineNumbers
    Variables
    Default     = LineNumbers
  end

  enum FramePointers
    Auto
    Always
    NonLeaf
  end

  # Main interface to the compiler.
  #
  # A Compiler parses source code, type checks it and
  # optionally generates an executable.
  class Compiler
    DEFAULT_LINKER = ENV["CC"]? || {{ env("IYI_CONFIG_CC") || "cc" }}
    MSVC_LINKER    = ENV["CC"]? || {{ env("IYI_CONFIG_CC") || "cl.exe" }}

    # A source to the compiler: its filename and source code.
    record Source,
      filename : String,
      code : String

    # The result of a compilation: the program containing all
    # the type and method definitions, and the parsed program
    # as an ASTNode.
    record Result,
      program : Program,
      node : ASTNode

    # If `true`, doesn't generate an executable but instead
    # creates a `.o` file and outputs a command line to link
    # it in the target machine.
    property? cross_compile = false

    # Compiler flags. These will be true when checked in macro
    # code by the `flag?(...)` macro method.
    property flags = [] of String

    # Controls generation of frame pointers.
    property frame_pointers = FramePointers::Auto

    # If `true`, the executable will be generated with debug code
    # that can be understood by `gdb` and `lldb`.
    property debug = Debug::Default

    # If `true`, `.ll` files will be generated in the default cache
    # directory for each generated LLVM module.
    property? dump_ll = false

    # Additional link flags to pass to the linker.
    property link_flags : String?

    # Sets the mcpu. Check LLVM docs to learn about this.
    property mcpu : String?

    # Sets the mattr (features). Check LLVM docs to learn about this.
    property mattr : String?

    # If `false`, color won't be used in output messages.
    property? color = true

    # If `true`, skip cleanup process on semantic analysis.
    property? no_cleanup = false

    # If `true`, no executable will be generated after compilation
    # (useful to type-check a program)
    property? no_codegen = false

    # iyi: whether this build's link is the one the compiler builds itself
    # rather than the one `cc` builds for it, and whether that has already been
    # tried and failed. See `iyi_direct_link_command`.
    @iyi_direct_link = false
    @iyi_link_driver_only = false

    # Maximum number of LLVM modules that are compiled in parallel
    property n_threads : Int32 = {% if Fiber.has_constant?(:ExecutionContext) %}
      Fiber::ExecutionContext.default_workers_count
    {% elsif flag?(:win32) %}
      1
    {% else %}
      8
    {% end %}

    # Default prelude file to use. This ends up adding a
    # `require "prelude"` (or whatever name is set here) to
    # the source file to compile.
    property prelude = "prelude"

    # iyi: directory to write a `.iyimod` per imported module into, or nil
    # (SPEC.md IV.1). Set by `--emit-iyimod`.
    property emit_iyimod : String? = nil

    # iyi: a prepared requirement table (III.7), for a caller that resolved
    # the manifest itself — `iyi mod context` compiles dependencies with the
    # *user's* table, from entries that have no manifest of their own.
    property iyi_mod_table : Array({String, String})? = nil

    # iyi: editor buffers for `iyi lsp`, handed through to the program —
    # see Program#iyi_file_overrides.
    property iyi_file_overrides = {} of String => String

    # iyi: the project root for `iyi lsp` — see Program#iyi_project_root.
    property iyi_project_root : String? = nil

    # iyi: the root the entry file's own header names, if its path ends with
    # it (IV.6 read backwards) — `module calc/parser` in
    # `/p/calc/parser.iyi` is `/p`. Tried *after* the entry's directory, so
    # building a nested module directly resolves its imports the way a build
    # from the root would, and a file whose header happens to end its path
    # does not change what a build that already worked resolves.
    property iyi_header_root : String? = nil

    # iyi: a namespace whose methods this build must define rather than inline.
    #
    # `--emit-iyimod` already says this about iyi modules, and the reason is the
    # same one: a method whose body is a literal is inlined and emits no symbol,
    # which is right for a whole-program build and wrong for one producing code
    # somebody else will call by name. A Crystal shard bound by `tool bind` is
    # that second thing and has no iyi modules to key on, so it says which
    # namespace it is producing.
    property iyi_keep : String? = nil

    # iyi: where `tool bind` writes the boundary it generates (SPEC.md Part V
    # item 12). Not `emit_iyimod`: that one writes this build's own modules and
    # refuses to run under Crystal's library, which is where a shard is read.
    property emit_bind : String? = nil

    # iyi: directory to read a `.iyimod` per imported module from, or nil
    # (SPEC.md IV.1). Set by `--use-iyimod`. An import that finds one there is
    # compiled against it and never opens the module's source, which is R-1's
    # contract and the reason the file exists.
    property use_iyimod : String? = nil

    # Sets the Optimization mode.
    property optimization_mode = OptimizationMode::O0

    # Sets the code model. Check LLVM docs to learn about this.
    property mcmodel = LLVM::CodeModel::Default

    # If `true`, generates a single LLVM module. By default
    # one LLVM module is created for each type in a program.
    # --release automatically enable this option
    property? single_module = false

    # A `ProgressTracker` object which tracks compilation progress.
    property progress_tracker = ProgressTracker.new

    # Codegen target to use in the compilation.
    # If not set, asks LLVM the default one for the current machine.
    property codegen_target = Config.host_target

    # If `true`, prints the link command line that is performed
    # to create the executable.
    property? verbose = false

    # If `true`, doc comments are attached to types and methods
    # and can later be used to generate API docs.
    property? wants_doc = false

    # Warning settings and all detected warnings.
    property warnings = WarningCollection.new

    @[Flags]
    enum EmitTarget
      ASM
      OBJ
      LLVM_BC
      LLVM_IR
    end

    # Can be set to a set of flags to emit other files other
    # than the executable file:
    # * asm: assembly files
    # * llvm-bc: LLVM bitcode
    # * llvm-ir: LLVM IR
    # * obj: object file
    property emit_targets : EmitTarget = EmitTarget::None

    # Base filename to use for `emit` output.
    property emit_base_filename : String?

    # By default the compiler cleans up the default cache directory
    # to keep the most recent 10 directories used. If this is set
    # to `false` that cleanup is not performed.
    property? cleanup = true

    # Default standard output to use in a compilation.
    property stdout : IO = STDOUT

    # Default standard error to use in a compilation.
    property stderr : IO = STDERR

    # Whether to show error trace
    property? show_error_trace = false

    # Whether to link statically
    property? static = false

    property dependency_printer : DependencyPrinter? = nil

    # Program that was created for the last compilation.
    property! program : Program

    # Compiles the given *source*, with *output_filename* as the name
    # of the generated executable.
    #
    # Raises `Iyi::CodeError` if there's an error in the
    # source code.
    #
    # Raises `InvalidByteSequenceError` if the source code is not
    # valid UTF-8.
    def compile(source : Source | Array(Source), output_filename : String) : Result
      # iyi: IV.6 read backwards, for every build and not only the server's.
      # A module's path is its file's path, so an entry whose header ends
      # its own path names the project root above both, and `import a/b`
      # from `<root>/x/y.iyi` resolves the way a build from the root would.
      # A tool that knows better has set the root already; an entry whose
      # header and path disagree, or that has none, keeps the entry-dir rule.
      if @iyi_header_root.nil? && (entry = source.is_a?(Source) ? source : source.first?)
        @iyi_header_root = Compiler.header_root_of(entry.filename, entry.code)
      end
      compile_configure_program(source, output_filename) { }
    end

    # The root the entry's header names, or nil: `module calc/parser` in
    # `/p/calc/parser.iyi` is `/p`.
    def self.header_root_of(path : String, text : String) : String?
      header = nil
      text.each_line do |line|
        line = line.strip
        next if line.empty? || line.starts_with?('#')
        header = line
        break
      end
      return nil unless header && header.starts_with?("module ")
      module_path = header.lchop("module ").strip
      return nil if module_path.empty? || module_path.includes?(' ')
      suffix = "/#{module_path}.iyi"
      return nil unless path.ends_with?(suffix)
      root = path[0, path.size - suffix.size]
      root.empty? ? "/" : root
    end

    # Compiles against an already-analysed prelude. This is the same split the
    # fork probe measures (SPEC.md IV.1a): the top-level pass runs over the user
    # file only, and every pass after it runs over both trees, because they walk
    # the prelude for reasons caching its analysis does not remove.
    private def compile_with_preanalysed_prelude(pre : Preanalysed, sources : Array(Source),
                                                 output_filename : String, & : Program -> Nil) : Result
      program = pre.program

      # The prelude was analysed against a placeholder filename. Adopt this
      # build's, so that anything derived from it — `__temp_` prefixes, error
      # locations — matches what a normal compile would produce.
      program.filename = sources.first.filename

      # And this build's directory. A daemon analyses the prelude in its own,
      # and `lib` is resolved relative to whatever directory the path was built
      # in — so a program that requires a shard looked for it beside the daemon
      # and reported "can't find file 'kemal'". Every shard-using project, from
      # any directory but the daemon's own.
      # Assigned back rather than mutated in place: `IyiPath` is a struct,
      # so the getter hands out a copy and setting a field on it changes
      # nothing.
      path = program.iyi_path
      path.current_dir = Dir.current
      program.iyi_path = path
      program.compiler = self
      program.progress_tracker = @progress_tracker

      # This path never runs `new_program`, so everything that method decides
      # about a build was decided by whoever analysed the prelude — a
      # `Compiler.new` in a daemon, with none of this build's switches.
      #
      # Most of it is safe by construction: the flags, the target, the
      # optimisation mode, `debug`, `static` and the prelude itself are all in
      # `prelude_cache_key`, so an analysis that differs in any of them is a
      # different analysis. These are the ones that are not, and leaving them
      # was not a degradation but a **silent lie**: `--use-iyimod` was accepted
      # and ignored, and the build compiled every module from source while
      # saying nothing.
      program.iyi_module_dir = @use_iyimod
      program.iyi_wants_object_code = !@no_codegen
      program.iyi_rewrites_artifacts = !@emit_iyimod.nil?
      # An emitting build parses docs whatever the adopted analysis wanted:
      # the artifact's `Docs` travel per module, and modules are parsed per
      # build — the prelude's own docs are nobody's surface.
      program.wants_doc = true unless @emit_iyimod.nil?
      # The manifest too, for the same reason as `--use-iyimod` above: the
      # analysis was made without this build's directory, and a table it
      # never computed is not one it can be said to have decided against.
      if table = @iyi_mod_table
        program.iyi_mod_table = table
      elsif filename = program.filename
        begin
          program.iyi_mod_table = Mod::Installer.table_for(File.dirname(filename))
        rescue ex : Mod::ModError
          raise Error.new(ex.message)
        end
      end
      program.warnings = @warnings
      program.iyi_file_overrides = @iyi_file_overrides
      program.iyi_project_root = @iyi_project_root
      program.iyi_header_root = @iyi_header_root
      program.color = color?
      program.stdout = stdout
      program.show_error_trace = show_error_trace?

      yield program

      node = @progress_tracker.stage("Parse") do
        nodes = sources.map do |source|
          program.requires.add source.filename
          parse(program, source).as(ASTNode)
        end
        program.normalize(Expressions.from(nodes))
      end

      begin
        node, processor = program.top_level_semantic(node, processor: pre.processor)
        node = program.semantic_after_top_level(
          Expressions.from([pre.node, node] of ASTNode), processor,
          cleanup: !no_cleanup?)
      rescue ex : SkipMacroCodeCoverageException
        program.macro_expansion_error_hook.try &.call(ex.cause)
      end

      prepared = prepare_iyimods program
      keep_iyi_namespace program

      units = codegen program, node, sources, output_filename unless @no_codegen

      write_iyimods program, prepared, units
      fill_bind_artifact program, units

      @progress_tracker.clear
      print_macro_run_stats(program)
      print_codegen_stats(units)

      Result.new program, node
    end

    # A prelude analysed ahead of a build, for a later compile to adopt instead
    # of analysing it again. The build daemon produces one before forking; the
    # child adopts it, which is where its speed comes from.
    class Preanalysed
      getter program : Program
      getter node : ASTNode
      getter processor : TypeDeclarationProcessor
      getter key : String

      # Every file the prelude pulled in, with the modification time it had when
      # it was read. A daemon outlives edits to its own sources, so serving a
      # build from an analysis of a since-edited prelude is the one way it can
      # be silently, confusingly wrong.
      getter fingerprint : Hash(String, Time)

      def initialize(@program, @node, @processor, @key)
        @fingerprint = {} of String => Time
        @program.requires.each do |filename|
          if info = File.info?(filename)
            @fingerprint[filename] = info.modification_time
          end
        end
      end

      # Whether the prelude on disk has moved out from under this analysis.
      # Files added since are not detectable from here — a new `require` in an
      # edited file shows up as that file's own mtime changing, which is what
      # actually triggers the reload.
      def stale? : Bool
        @fingerprint.any? do |filename, mtime|
          info = File.info?(filename)
          info.nil? || info.modification_time != mtime
        end
      end
    end

    # Set in the daemon before it forks, adopted by the child. Keyed by
    # `prelude_cache_key`, because a prelude analysed under one set of flags
    # cannot serve a build under another — macros branch on flags.
    class_property preanalysed = {} of String => Preanalysed

    # iyi: what each of this class's switches is to a preanalysed prelude.
    #
    # A cache key is a claim that everything not in it does not matter, and this
    # one was written when the only thing reading it was prelude analysis. Every
    # switch added since had to be checked against it by hand, silently, with
    # nothing enforcing the check — and `--use-iyimod` is what happened when
    # somebody did not: accepted, ignored, and the build compiled every module
    # from source without a word (SPEC.md IV.1d).
    #
    # So the claim is written down and `prelude_cache_key` refuses to compile
    # while any switch is missing from it. Three answers, and a new property has
    # to be given one of them:
    #
    # - it changes what the prelude analyses *to*, so it belongs in the key;
    # - it is the build's own and has to be re-applied to an adopted prelude,
    #   because that path never runs `new_program`;
    # - it reaches neither, which is most of them.
    IN_PRELUDE_KEY = %w(prelude codegen_target optimization_mode debug static wants_doc flags)

    # Re-applied by the adopt path above. `new_program` is what would otherwise
    # have set them, and adoption skips it.
    APPLIED_ON_ADOPT = %w(use_iyimod no_codegen emit_iyimod warnings color stdout show_error_trace iyi_mod_table iyi_file_overrides iyi_project_root iyi_header_root)

    # Neither, and two of these are judgements rather than facts. `mcpu`,
    # `mattr` and `mcmodel` reach the target machine and the target machine
    # reaches codegen, not analysis — a prelude analysed for one `-mcpu` is the
    # same analysis as for another. `progress_tracker` and `stderr` are where
    # output goes; `new_program` sets the first and the adopt path sets neither,
    # which is visible now rather than merely true.
    OUTSIDE_PRELUDE_ANALYSIS = %w(
      cleanup cross_compile dependency_printer dump_ll emit_base_filename
      emit_bind emit_targets frame_pointers iyi_direct_link iyi_keep
      iyi_link_driver_only link_flags mattr mcmodel mcpu n_threads no_cleanup
      program progress_tracker single_module stderr target_machine verbose
    )

    # Everything that changes what the prelude analyses *to*. Macros branch on
    # flags, so a build whose key differs cannot adopt a prelude analysed under
    # another one and has to analyse its own.
    def prelude_cache_key : String
      {% begin %}
        {% classified = IN_PRELUDE_KEY + APPLIED_ON_ADOPT + OUTSIDE_PRELUDE_ANALYSIS %}
        {% for ivar in @type.instance_vars %}
          {% unless classified.includes?(ivar.name.stringify) %}
            {% raise "Compiler##{ivar.name} is new, and nothing says what it is to a " +
                     "preanalysed prelude. A daemon serves builds from a key that claims " +
                     "everything not in it does not matter, so say which this is: add it to " +
                     "IN_PRELUDE_KEY, APPLIED_ON_ADOPT or OUTSIDE_PRELUDE_ANALYSIS in " +
                     "compiler.cr (SPEC.md IV.1d)." %}
          {% end %}
        {% end %}
      {% end %}

      String.build do |io|
        io << prelude << '|' << codegen_target << '|' << @optimization_mode << '|'
        io << debug << '|' << static? << '|' << wants_doc? << '|'
        io << @flags.sort.join(',')
      end
    end

    # Analyses the prelude on its own, so a later compile can start from it.
    # The filename is a placeholder: the build that adopts this has its own, and
    # sets it before compiling.
    def preanalyse_prelude : Preanalysed
      program = new_program([Source.new("", "")] of Source)
      location = Location.new(program.filename, 1, 1)
      node = program.normalize(Expressions.new([Require.new(prelude).tap(&.iyi_prelude=(true)).at(location)] of ASTNode))
      node, processor = program.top_level_semantic(node)
      @progress_tracker.clear
      Preanalysed.new(program, node, processor, prelude_cache_key)
    end

    # :ditto:
    #
    # Yields a `Program` instance before compiling.
    def compile_configure_program(source : Source | Array(Source), output_filename : String, & : Program -> Nil) : Result
      source = [source] unless source.is_a?(Array)
      return prelude_fork_probe(source, output_filename) if ENV["IYI_FORK_PROBE"]?

      # iyi: `IYI_WARM=1` — analyse the prelude and adopt it, in one process and
      # **without forking**, printing the two halves.
      #
      # The daemon does three things at once: it analyses a prelude, it keeps
      # it, and it forks a child to use it. When its numbers disappoint there is
      # no way to tell which of the three is at fault, and the answer decides
      # whether the daemon is worth having at all. This removes the fork and
      # leaves the rest, so the two can be priced apart.
      #
      # What it priced: adoption returns essentially the whole prelude analysis,
      # for a program requiring a shard as much as for one that does not, and
      # the fork costs 0.2 to 0.3 s of it (SPEC.md IV.1d). A measurement tool
      # rather than a mode — it analyses the prelude in the foreground, so it is
      # always slower overall than an ordinary build.
      if ENV["IYI_WARM"]? && !Compiler.preanalysed.has_key?(prelude_cache_key)
        warm = Time.instant
        pre = preanalyse_prelude
        Compiler.preanalysed[pre.key] = pre
        STDERR.puts "[warm] prelude #{warm.elapsed.total_seconds.round(3)}s"
        rest = Time.instant
        result = compile_with_preanalysed_prelude(pre, source, output_filename) { |program| yield program }
        STDERR.puts "[warm] rest    #{rest.elapsed.total_seconds.round(3)}s"
        return result
      end

      if pre = Compiler.preanalysed[prelude_cache_key]?
        return compile_with_preanalysed_prelude(pre, source, output_filename) { |program| yield program }
      end
      program = new_program(source)
      yield program
      node = parse program, source

      begin
        node = program.semantic node, cleanup: !no_cleanup?
      rescue ex : SkipMacroCodeCoverageException
        program.macro_expansion_error_hook.try &.call(ex.cause)
      end

      prepared = prepare_iyimods program
      keep_iyi_namespace program

      units = codegen program, node, source, output_filename unless @no_codegen

      write_iyimods program, prepared, units
      fill_bind_artifact program, units

      @progress_tracker.clear
      print_macro_run_stats(program)
      print_codegen_stats(units)
      Prof.report

      Result.new program, node
    end

    # iyi: describes a `.iyimod` per imported module (SPEC.md IV.1), when
    # `--emit-iyimod` asked for it. Everything but the object code, which does
    # not exist yet — see `write_iyimods`.
    #
    # Only imported modules. The entry file is a program rather than a
    # dependency, and nothing can import it — III.5 rule 1 puts its initialiser
    # last for the same reason.
    #
    # The file is named after the module path with `/` kept, so `app/greeter`
    # lands at `DIR/app/greeter.iyimod` and the layout mirrors the source tree.
    # IV.6 #6's segment rule is what makes that safe: two module paths cannot
    # collide, so two modules cannot claim one artifact.
    #
    # Run before codegen, because collecting a module's surface is where R-2 is
    # enforced — an exported signature missing a block annotation is refused
    # here. Refusing it after a full codegen and link would make the compiler
    # spend the whole build on a program it had already decided not to write.
    # iyi: `--iyi-keep Kemal`, the same rule `prepare_iyimods` applies to a
    # module it is writing, applied to a namespace named on the command line.
    private def keep_iyi_namespace(program : Program) : Nil
      return unless root = iyi_keep

      type = program.types?.try &.[]?(root)
      return unless type.is_a?(ModuleType)

      program.iyi_exported_owners << type
      collect_iyi_owners type, program.iyi_exported_owners
    end

    private def prepare_iyimods(program : Program) : Array({String, IyiMod::Artifact})?
      return unless dir = emit_iyimod

      flags = program.flags.to_a.sort!

      # Before codegen, because that is what it is for: a method whose body is
      # a literal is inlined and emits no symbol, and this build is producing
      # code somebody else will call by name.
      program.iyi_module_paths.each_value do |module_name|
        if type = program.iyi_module_type(module_name)
          program.iyi_exported_owners << type
          collect_iyi_owners type, program.iyi_exported_owners
        end
      end

      # iyi: and which of their bodies answer for an open set (SPEC.md III.6).
      #
      # Here, because this is where the owners are known and before the surface
      # below is collected: a body whose machine code enumerates a module's
      # including types is the whole program's answer, so it travels in
      # `MonoBodies` like a block-taking one. Before codegen for the same
      # reason the collection is — the keep file leaves a travelling body
      # alone, so nothing emits a symbol for it.
      @progress_tracker.stage("Open dispatch") do
        OpenTravel.mark program
      end

      prepared = program.iyi_module_paths.map do |filename, module_name|
        # Both hashes, because a dependency may have arrived either way and the
        # edge is keyed on a filename regardless. Asking only the source one
        # left an import read from a `.iyimod` recorded as the path of that
        # file — an edge naming a build's directory layout rather than a
        # module, which the next build cannot resolve.
        #
        # The edges are named here and hashed below: what a dependency compiled
        # in *this* build hashes to is only known once its own artifact has been
        # described (IV.3).
        imports = program.iyi_module_imports[filename]?.try do |dependencies|
          exported = program.iyi_exported_imports[filename]?
          dependencies.map do |dependency|
            name = program.iyi_module_paths[dependency]? ||
                   program.iyi_artifact_modules[dependency]? ||
                   dependency
            IyiMod::ImportEdge.new(name, exported: !exported.nil? && exported.includes?(dependency))
          end
        end

        # First, because collecting the surface is also what records which of
        # its bodies have to travel.
        exports = collect_iyi_exports(program, module_name, filename)

        artifact = IyiMod::Artifact.new(
          module_name: module_name,
          source_path: filename,
          # Not `Config.description`: that is the multi-line `--version` banner,
          # and this field is compared for equality (IV.5).
          compiler_version: IyiMod.compiler_version,
          target_triple: program.codegen_target.to_s,
          flags: flags,
          imports: imports || [] of IyiMod::ImportEdge,
          usings: program.iyi_usings[filename]? || [] of String,
          exports: exports,
          has_initialiser: program.iyi_module_initialisers.includes?(filename),
          mono_bodies: program.iyi_mono_bodies[filename]? || {} of String => String,
          macro_bodies: collect_iyi_macros(program, module_name),
          initialiser: program.iyi_module_initialiser_source[filename]? || "",
          requires: program.iyi_module_requires[filename]? || [] of String,
          crystal_library: !program.iyi_prelude?,
          # Always, for a module of iyi's own: the header it was written under
          # desugars to `extend self`, and a consumer reading these
          # declarations back has to get the same module. The field is what
          # says so now — the header a consumer reads them under supplies
          # nothing. See `Artifact#module_extends_self`.
          module_extends_self: true,
        )

        # Here rather than in `write_iyimods`, so that they are taken from the
        # front end alone: an artifact from a `--no-codegen` build and one from
        # a full build describe the same module and have to hash the same, or a
        # build that only typechecks would invalidate what a build that
        # generated code had just written (IV.3).
        artifact.hashes = IyiMod.hashes_for(artifact, File.read(filename))

        {File.join(dir, "#{module_name}.iyimod"), artifact}
      end

      # Now that every module in this build has been hashed, each edge can say
      # what the module on its far end hashed to — which is what lets the next
      # build ask whether that is still true (IV.3). A dependency that arrived
      # as an artifact is hashed already and was recorded when it was read.
      hashes = {} of String => IyiMod::Hashes
      prepared.each { |(_, artifact)| hashes[artifact.module_name] = artifact.hashes }
      program.iyi_artifact_hashes.each { |name, digests| hashes[name] ||= digests }

      prepared.each do |(_, artifact)|
        artifact.imports = artifact.imports.map do |edge|
          known = hashes[edge.module_name]?
          next edge unless known
          IyiMod::ImportEdge.new(edge.module_name, known.interface, known.implementation, edge.exported)
        end
      end

      prepared
    end

    # iyi: the object code of a namespace `tool bind` wrote a boundary for.
    #
    # `tool bind` runs without codegen — it reads and counts, and the artifact it
    # writes is declarations. The object code is this build's to add: the keep
    # file it generated is what forces every exported method to be emitted, and
    # compiling that file is where the units exist.
    #
    # Per unit rather than as one object, which is the whole point. A keep file
    # compiled with `--emit obj` merges into a single object carrying the whole
    # of Crystal's library with it, and a program can have that library once —
    # link it into a consumer that has none and the shard's state never starts,
    # link it into one that has it and every runtime global is defined twice. An
    # ordinary build leaves one object per type, and the ones this namespace owns
    # carry no runtime at all.
    private def fill_bind_artifact(program : Program, units : Array(CompilationUnit)?) : Nil
      return unless dir = emit_bind
      return unless root = iyi_keep
      return unless units

      type = program.types?.try &.[]?(root)
      return unless type.is_a?(ModuleType)

      names = [type.to_s] of String
      collect_iyi_unit_names type, names
      names.sort!.uniq!

      path = File.join(dir, "#{Iyi.iyi_module_name(root).gsub('/', '-')}.iyimod")
      return unless File.file?(path)

      artifact = IyiMod.read path
      units_by_name = units.to_h { |unit| {unit.original_name, unit} }
      artifact.object_code = collect_iyi_object_code(names, units_by_name)
      artifact.type_ids = collect_iyi_type_ids(program, names)
      artifact.constants = collect_iyi_constants(program, names)
      artifact.regexes = collect_iyi_regexes(program, artifact.constants)
      artifact.class_vars = collect_iyi_unit_class_vars(program, names)
      artifact.match_types = collect_iyi_match_types(program, names)
      artifact.symbols = collect_iyi_symbols(program, names)
      artifact.libs = collect_iyi_libs(program, names)
      artifact.layouts = collect_iyi_layouts(program, type)
      # Reached only if the keep file compiled, which is the whole of what this
      # says. A boundary whose fill died leaves every declaration on disk and no
      # machine code, and that is not the same thing as having none.
      artifact.filled = true

      add_bind_boundary_imports artifact, dir, path
      IyiMod.write artifact, path

      carried = artifact.object_code.sum { |unit| unit.code.size }
      stdout.puts "filled #{path}: #{artifact.object_code.size} units, " \
                  "#{carried} bytes, #{artifact.type_ids.size} type ids, " \
                  "#{artifact.constants.size} constants"
    end

    # iyi: a boundary this one *numbers* is a boundary this one depends on.
    #
    # A type id is the only place that dependency shows. `Kemal` names no
    # `Radix` type in any declaration and its object code refers to
    # `Array(Radix::Node(...))` — so a consumer that imported `kemal` had never
    # heard of `radix` and could not name what `kemal` numbered.
    #
    # Read from the boundaries sitting beside this one rather than from what
    # `tool bind` knew, because the two are different processes: `tool bind`
    # writes the declarations and this build fills the object code, and only
    # this one knows the type ids.
    private def add_bind_boundary_imports(artifact : IyiMod::Artifact, dir : String,
                                          own : String) : Nil
      edges = artifact.imports.map(&.module_name).to_set
      Dir.glob(File.join(dir, "*.iyimod")).sort.each do |path|
        next if File.expand_path(path) == File.expand_path(own)

        begin
          other = IyiMod.read path
        rescue
          next
        end
        next if edges.includes?(other.module_name)

        # By whole name, as the *producer* writes it. This was a substring
        # test over the bare declared names, and a bare name is a common word:
        # `DB` declares `Any` and `Kemal` declares `Config`, so every artifact
        # whose object code numbered a `JSON::Any` or a `Log::Configuration`
        # picked up an edge to a shard it had never heard of. `jwt` came out
        # importing eleven boundaries, nine of which it names nothing from,
        # and a program that wanted `jwt` was handed `p_g` — whose own
        # declarations it then could not satisfy, so nothing built at all.
        declared = Set(String).new
        prefix = other.class_root ? "" : other.module_name.split('/').map(&.camelcase).join("::")
        other.exports.types.each { |declaration| collect_bind_declared declaration, prefix, declared }
        next unless artifact.type_ids.any? { |id| type_id_names(id).any? { |name| declared.includes?(name) } }

        # Not if it already points here. Every one of these boundaries was bound
        # in a program that held all of them, so each one's units number the
        # others' instantiations — `Radix`'s number `Result(Kemal::Route)`,
        # which is Kemal's instantiation and not Radix's. Read as a dependency
        # both ways it is a cycle, and an import graph is a DAG (R-1).
        next if other.imports.any? { |edge| edge.module_name == artifact.module_name }

        artifact.imports << IyiMod::ImportEdge.new(other.module_name)
        edges << other.module_name
      end
    end

    # Every name *declared_by* one boundary, qualified the way the program the
    # fill build compiled spells it: a module root's declarations are written
    # under the module (`bin_data` declares `BitField`, which that program
    # calls `BinData::BitField`), a class root's are already absolute.
    private def collect_bind_declared(declaration : IyiMod::TypeDecl, prefix : String,
                                      into : Set(String)) : Nil
      qualified = prefix.empty? ? declaration.name : "#{prefix}::#{declaration.name}"
      into << qualified
      declaration.types.each { |nested| collect_bind_declared nested, qualified, into }
    end

    # The type names inside one type id: `Hash::Entry(String,
    # BinData::BitField)` names three. Every character that cannot be in a
    # name ends one, and a leading `::` is not part of it.
    private def type_id_names(id : String) : Array(String)
      names = [] of String
      from = -1
      id.each_char_with_index do |char, index|
        if char.ascii_alphanumeric? || char == '_' || char == ':'
          from = index if from < 0
        elsif from >= 0
          names << id[from...index].lchop("::")
          from = -1
        end
      end
      names << id[from..].lchop("::") if from >= 0
      names
    end

    # iyi: attaches each module's object code and writes the artifacts.
    #
    # After codegen, because that is when the object files exist. Writing here
    # also says something true: an artifact is written by a build that got all
    # the way through, so a build that failed in codegen leaves the previous
    # artifact in place rather than a newer one describing a program that does
    # not link.
    private def write_iyimods(program : Program, prepared : Array({String, IyiMod::Artifact})?,
                              units : Array(CompilationUnit)?) : Nil
      return unless prepared

      units_by_name = units.try &.to_h { |unit| {unit.original_name, unit} }

      prepared.each do |(path, artifact)|
        # iyi: a package's artifact is III.7 step 5's story — signatures,
        # signing, the registry — and is not written here, because the one
        # this loop would write is hollow: the exports collector keys on the
        # in-package type name and a canonical dotted path reaches nothing.
        # A dotted name is the discriminator IV.6 #6 guarantees: a local
        # module cannot carry one. Skipped loudly enough — an artifact that
        # is absent is a rebuild; one that lies is a debugging session.
        next if artifact.module_name.includes?('.')

        unit_names = iyi_unit_names(program, artifact.module_name)
        artifact.object_code = collect_iyi_object_code(unit_names, units_by_name)

        # The units whose object code actually travelled, which is not the same
        # list. `collect_iyi_object_code` drops a name with no compilation unit
        # behind it or no file on disk, and everything else here was still
        # answering for the whole of `unit_names` — so an artifact could
        # *claim* a symbol it did not carry. `db` claims
        # `*DB::SessionMethods::UnpreparedQuery(DB::Connection+,
        # DB::Statement+)@…#build<String>`, a generic's instantiation whose
        # object file is nobody's, and a consumer reading that claim skipped
        # compiling one of its own: `undefined symbol`, about a method whose
        # body was in the declarations all along.
        #
        # A list of what a module defines is only worth having if it is the
        # list of what it *has*.
        carried = artifact.object_code.map(&.name)
        artifact.type_ids = collect_iyi_type_ids(program, unit_names)
        artifact.constants = collect_iyi_constants(program, unit_names)
        artifact.regexes = collect_iyi_regexes(program, artifact.constants)
        artifact.class_vars = collect_iyi_unit_class_vars(program, unit_names)
        artifact.match_types = collect_iyi_match_types(program, unit_names)
        artifact.symbols = collect_iyi_symbols(program, carried)
        artifact.libs = collect_iyi_libs(program, unit_names)
        # With the object code, because it is about the object code's types:
        # a build that generated none has no lowered types to measure.
        if units
          if module_type = program.iyi_module_type(artifact.module_name)
            artifact.layouts = collect_iyi_layouts(program, module_type)
          end
        end
        artifact.filled = true
        IyiMod.write artifact, path
      end
    end

    # iyi: a module's public surface, for the artifact's `Exports` (IV.2).
    #
    # `pub` records a *name* on the module (R-2), so this walks those names and
    # takes the signature of each `def` they resolve to. A name can carry
    # several overloads and each is its own signature.
    #
    # Parameter and return types are the annotations as written. R-2 requires
    # them on anything exported, so an export missing one is not a signature to
    # infer but a rule that was broken somewhere else; it is recorded as `?`
    # rather than guessed at, which keeps that visible in `mod dump` instead of
    # inventing a type the author never wrote.
    private def collect_iyi_exports(program : Program, module_name : String,
                                    filename : String) : IyiMod::Exports
      functions = [] of IyiMod::Signature
      carried_functions = [] of IyiMod::Signature
      types = [] of IyiMod::TypeDecl

      if type = program.iyi_module_type(module_name)
        exported = type.exported_names
        exported.try &.to_a.sort!.each do |name|
          # A name is a function or a type, never both: they share one
          # namespace on the module, which is what makes `pub` a mark on a
          # name rather than on a kind of declaration.
          if signatures = type.defs.try &.[]?(name)
            signatures.each do |item|
              signature = IyiMod.signature(item.def)
              functions << signature
              # A module's own `pub def` that takes a block is the consumer's
              # to compile for the same reason, and the module name is the
              # container the far side looks it up under.
              if iyi_takes_block?(item.def) && !item.def.abstract?
                iyi_record_mono_body program, filename, module_name, signature, item.def
              end
            end
          elsif exported_type = type.types?.try &.[]?(name)
            # iyi: a constant is in the same table as a type and is not one.
            # `pub LIMIT = 42` reaches a consumer by being written back into
            # the initialiser, which travels as the module's own source, so
            # there is nothing to declare here.
            types << iyi_type_declaration(program, filename, name, exported_type) unless exported_type.is_a?(Const)
          end
        end

        # And the defs it does not export, for the reason the types below
        # travel: a body that travels calls them. An exported `run` that takes
        # a block is compiled by the consumer, and it may call a `helper` this
        # module kept to itself — a name nobody may reach is still a name the
        # consumer has to typecheck a call against, and a block-taking one is
        # a body it has to compile.
        type.defs.try &.each do |name, items|
          next if exported.try &.includes?(name)
          items.each do |item|
            next if item.def.abstract?
            next if item.def.body.is_a?(Primitive)

            signature = IyiMod.signature(item.def, check_block: false)
            carried_functions << signature
            if iyi_takes_block?(item.def)
              iyi_record_mono_body program, filename, module_name, signature, item.def
            end
          end
        end
        carried_functions.sort_by! &.name

        # And the ones it does not export, which travel as names and layouts
        # rather than as a surface. See `iyi_carried_types`.
        types.concat iyi_carried_types(program, filename, type, exported)
      end

      impls = program.iyi_impls[filename]? || [] of IyiMod::ImplRecord

      # The module's own class variables — the ones owned by the module unit
      # rather than by a type inside it. They belong to no `TypeDecl`, because
      # a module is not one, and a class variable is a global either way.
      module_class_vars = type ? collect_iyi_class_vars(type) : [] of IyiMod::ClassVarDecl

      IyiMod::Exports.new(functions, types, impls, carried_functions, module_class_vars)
    end

    # iyi: the machine code for a module's own definitions, for `ObjectCode`
    # (IV.1). Empty on a `--no-codegen` build, which generated none.
    #
    # Codegen already emits one LLVM module — and so one object file — per
    # owner type, and the split is a partition: measured on the Kemal port, no
    # symbol is defined by two of its 23 units. So a module's own code is a set
    # of whole object files, identified by naming the types the module declares
    # and taking the unit of each. A generic type contributes one unit per
    # instantiation, and a module's own `pub def`s are owned by the module type
    # itself, which is why that is in the set alongside the types under it.
    #
    # A module's bodies also instantiate *prelude* generics at its own types —
    # `Array(Kemal::Router::Router::RouteDefinition)` — and that unit is named
    # after `Array`, not after anything the module declares, so it is not here.
    # It does not have to be: a callee the emitting module does not own is
    # copied into the module's own unit with internal linkage, and a generic's
    # instantiated methods are callees like any other. What the copy leaves
    # behind is the type id it refers to, which is what `type_ids` carries.
    #
    # What is here is what the *consuming build* reached, not the module's
    # whole surface. Codegen is demand-driven, so `app/greeter`'s artifact
    # carries `polite` and not `title`, because `modules.iyi` calls one and not
    # the other. That is `--emit-iyimod` living inside an ordinary build: a
    # module compiled on its own would instantiate every exported def at the
    # signature R-2 makes it write down, and it is exactly the command that
    # cannot precede the artifact it produces.
    #
    # The sharp edge of that, because it links rather than refusing: a
    # parameter whose declared type is *wider* than the argument this build
    # passed is compiled at the argument's type, and the consumer - which
    # reads the declaration and widens the call to it, `iyi_artifact_arg_types`
    # - asks the linker for a symbol nobody emitted. Eight lines reproduce it:
    # `pub class Crate` with `property? note : String | Nil` in one module and
    # `crate.note = "hi"` in another emits `Crate#note=<String>` and links
    # against `Crate#note=<(String | Nil)>`. What the keep file does for
    # `iyi bind` - name every declared signature so the fill build compiles
    # it - is what this needs and does not have.
    private def collect_iyi_object_code(unit_names : Array(String),
                                        units_by_name : Hash(String, CompilationUnit)?) : Array(IyiMod::ObjectUnit)
      code = [] of IyiMod::ObjectUnit
      return code unless units_by_name

      unit_names.each do |name|
        next unless unit = units_by_name[name]?
        path = unit.object_name
        next unless File.file?(path)
        code << IyiMod::ObjectUnit.new(name, File.open(path, "rb", &.getb_to_end))
      end
      code
    end

    # The names of the units a module's object code is made of: the module type
    # itself, where its own `pub def`s are owned, and every non-generic type
    # declared under it.
    private def iyi_unit_names(program : Program, module_name : String) : Array(String)
      names = [] of String
      return names unless type = program.iyi_module_type(module_name)

      names << type.to_s
      collect_iyi_unit_names type, names
      names.sort!.uniq!
      names
    end

    # iyi: the types the module's object code refers to a type id of, by name,
    # for `TypeIds` (SPEC.md IV.1g).
    #
    # A type id is resolved by the linker from a definition in the consuming
    # program's `_main`, which is what lets one build's object file be linked
    # by another's — and a program defines an id for every type it *has*. The
    # types a module's own code numbers need not be among them:
    # `Array(Item)` exists in the producing build because of a body that stays
    # behind, and nothing the consumer reads would ever create it. So the name
    # travels and the consumer instantiates it.
    #
    # **Every one of them**, and the filters this used to have were each wrong
    # for a different reason.
    #
    # A **generic instance** may not exist in the consumer at all: `Array(Item)`
    # is in the producing build because of a body that stayed behind, and
    # nothing the consumer reads would create it. Naming it is what creates it.
    #
    # An **enum or a module** exists and is still unnumbered. Ids are handed out
    # by walking `Object`'s subclasses, and that walk reaches neither — both
    # take an id from the first code that asks for one, so a consumer whose own
    # code never mentions `Regex::MatchOptions` or `Backtracer::Backtrace::Parser`
    # numbers them nowhere and defines no id global.
    #
    # And a plain **class** was left out on the reasoning that the consumer has
    # it already — which is true only if the consumer *imports the module that
    # declares it*, and that import edge is derived from this very list.
    # `Kemal` numbers `ExceptionPage::Styles`, the name was filtered out here,
    # so no edge was added, so the consumer never read `exception_page` and
    # never had the class. The list is the dependency, so it has to be whole.
    #
    # The cost is a longer list — `Kemal` goes from 303 names to 642 — and a
    # name is a string.
    private def collect_iyi_type_ids(program : Program, unit_names : Array(String)) : Array(String)
      names = Set(String).new
      unit_names.each do |unit_name|
        program.iyi_unit_type_ids[unit_name]?.try &.each do |type|
          # A metaclass is numbered with its instance type, so instantiating
          # the one defines both. `Array(Item).class:type_id` was the first of
          # the two undefined symbols and the one that reads as a different
          # problem.
          instance = type.instance_type
          names << instance.to_s
        end
      end

      # Sorted, because a set's order is not a fact about the module and an
      # artifact that changed between two identical builds would defeat IV.3.
      names.to_a.sort!
    end

    # iyi: the constants the module's object code reads, by name, for
    # `Constants` (SPEC.md IV.1g).
    #
    # A constant is initialised where something reads it — `codegen_assign`
    # asks `const.used?` — and the reader on the far side of an artifact is
    # machine code the consumer never analysed. So the names travel and the
    # consumer marks them used; the initialiser that assigns them is already in
    # the module's own top level and already runs in III.5's order.
    private def collect_iyi_constants(program : Program, unit_names : Array(String)) : Array(String)
      names = Set(String).new
      unit_names.each do |unit_name|
        program.iyi_unit_constants[unit_name]?.try &.each { |const| names << const.to_s }
      end
      names.to_a.sort!
    end

    # iyi: the symbols the module's object code defines, for `Symbols` (SPEC.md
    # IV.1g).
    #
    # What a consumer needs in order to know what it has to compile for itself,
    # and the one thing no rule about the *shape* of a def gets right: an
    # artifact defines more than it declares and less than its types suggest.
    private def collect_iyi_symbols(program : Program,
                                    unit_names : Array(String)) : Array(String)
      names = Set(String).new
      unit_names.each do |unit_name|
        program.iyi_unit_symbols[unit_name]?.try &.each { |symbol| names << symbol }
      end
      names.to_a.sort!
    end

    # iyi: the `lib`s the module's object code calls into, by name, for `Libs`
    # (SPEC.md IV.1g).
    #
    # `Requires` says what the consumer has to have compiled and this says what
    # it has to have linked against. The consumer cannot work the second out
    # from the first: it has the `lib` and its `@[Link]` from the replayed
    # require, and drops the flag anyway, because a flag is collected from the
    # libs *this* build marked used and the call is in an object file it did
    # not compile.
    private def collect_iyi_libs(program : Program,
                                 unit_names : Array(String)) : Array(String)
      names = Set(String).new
      unit_names.each do |unit_name|
        program.iyi_unit_libs[unit_name]?.try &.each { |name| names << name }
      end
      names.to_a.sort!
    end

    # iyi: the types the module's object code asks `~match<T>` about, by name,
    # for `MatchTypes` (SPEC.md IV.1g).
    #
    # `collect_iyi_type_ids`' question asked of a match. The consumer defines
    # these with its own numbering, exactly as it defines the type ids, and for
    # the same reason: the numbering is the program's.
    #
    # A virtual one it could have found for itself, by taking the virtual form
    # of every class it numbers — that is what `iyi_define_all_match_funs`
    # does. A union it could not: `(Char | Iyi::Keyword | String | Nil)` is a
    # type the producer's code formed, and there is no walk over a program that
    # arrives at it.
    private def collect_iyi_match_types(program : Program,
                                        unit_names : Array(String)) : Array(String)
      names = Set(String).new
      unit_names.each do |unit_name|
        # `llvm_name`, not `to_s`, because the *symbol* is built from it:
        # `~match<(File::PReader | IO::FileDescriptor+ | ...)>` is what a
        # unit calls, and `to_s` prints that union without the `+`s. The
        # consumer defines the function under exactly the name that
        # travelled, so a name that is not the symbol's is a link error with
        # a mangled name in it and no way back to this line.
        program.iyi_unit_match_types[unit_name]?.try &.each { |type| names << type.llvm_name }
      end
      names.to_a.sort!
    end

    # iyi: the class variables the module's object code refers to, as
    # `Owner::@@name`, for `ClassVars` (SPEC.md IV.2).
    #
    # `collect_iyi_constants`' question asked of a global. A class variable's
    # global lives in the main module and a main module does not travel, so a
    # consumer that was not told the name emitted nothing and the link ended on
    # an undefined symbol.
    #
    # Not the same list as the declarations. A unit refers to the library's
    # class variables too — a shard that calls `String#upcase` refers to
    # `Unicode::@@upcase_ranges` — and those are already declared in the
    # consumer's own program, which compiles that library. What is missing
    # there is only that codegen never emitted the global, because it emits
    # what the consuming program *reaches* and the reader is a unit it did not
    # compile. One name answers both cases.
    #
    # The separator is `::@@` and it is unambiguous: a type's name may hold
    # `::` and cannot hold `@`.
    private def collect_iyi_unit_class_vars(program : Program,
                                            unit_names : Array(String)) : Array(IyiMod::ClassVarRef)
      lazy = {} of String => Bool
      unit_names.each do |unit_name|
        program.iyi_unit_class_vars[unit_name]?.try &.each do |name, through_read|
          lazy[name] = through_read || lazy[name]? || false
        end
      end
      lazy.keys.sort!.map { |name| IyiMod::ClassVarRef.new(name, lazy[name]) }
    end

    # iyi: what a consumer needs to *build* the synthesised regex constants in
    # `Constants`, for `Regexes` (SPEC.md IV.1g).
    #
    # Every other name in that list is one the consumer's own program already
    # has: its own library's `Int::DIGITS_BASE62`, or a constant this module
    # declared and whose initialiser travelled as source. A regex literal's is
    # neither. It is named for the literal rather than written by anybody, and
    # `$` keeps it out of the source channel — so the pattern travels here and
    # the consumer defines the constant under the name the object code asks for.
    #
    # Read from the names already collected rather than from the units again:
    # what a consumer has to build is exactly what it was told to read.
    private def collect_iyi_regexes(program : Program,
                                    constant_names : Array(String)) : Array(IyiMod::RegexConst)
      constant_names.compact_map do |name|
        next unless made = program.iyi_regex_constants[name]?
        pattern, options = made
        IyiMod::RegexConst.new(name, pattern, options.value.to_u32)
      end
    end

    # iyi: the pointer maps of the types this module owns, for the `Layouts`
    # section (GC_DESIGN.md Stage 1).
    #
    # The set is the walk `collect_iyi_unit_names` does, kept as types rather
    # than names, with one relaxation: a generic the module declares
    # contributes each instantiation this build has, because an instantiation
    # is monomorphic and has a layout. An uninstantiated generic contributes
    # nothing: one entry serving two instantiations by shape is R-4's
    # per-GC-shape keying, which nothing implements yet, so no entry pretends.
    #
    # Only a type laid out as an object gets a map: a class, a struct, or an
    # instantiation of one. `InstanceVarContainer` is not that filter, because
    # a module and a trait are containers too, and a trait's indirection is
    # the union of its implementors, which is exactly not a layout. A module,
    # an enum and an alias declare no fields of their own to scan in any
    # case.
    private def collect_iyi_layouts(program : Program, module_type : ModuleType) : Array({String, IyiMod::TypeLayout})
      types = [] of Type
      collect_iyi_layout_types module_type, types

      layouts = [] of {String, IyiMod::TypeLayout}
      types.each do |type|
        next unless type.is_a?(NonGenericClassType) || type.is_a?(GenericClassInstanceType)
        next if type.is_a?(GenericType) || type.is_a?(StaticArrayInstanceType)
        layouts << {type.to_s, program.gc_type_layout(type)}
      end

      # Sorted, for the reason `mono_bodies` is: a walk's order is not a fact
      # about the module, and an artifact that changed between two identical
      # builds would defeat IV.3.
      layouts.sort_by! &.[0]
      layouts
    end

    # The walk `collect_iyi_unit_names` does, keeping the types. A generic is
    # not collected itself (it has no layout); each instantiation of it in
    # this build is.
    private def collect_iyi_layout_types(type : ModuleType, types : Array(Type)) : Nil
      type.types?.try &.each_value do |declared|
        if declared.is_a?(GenericType)
          declared.instantiated_types.each do |instance|
            types << instance unless instance.unbound?
          end
        else
          types << declared
        end
        collect_iyi_layout_types declared, types if declared.is_a?(ModuleType)
      end
    end

    # The unit names of every type declared under *type*, recursively.
    #
    # A unit is named after the type that owns the methods in it, and **a
    # generic type's instantiations are deliberately not here**. `List(T)` has
    # no machine code; only `List(Int32)` does, and which instantiations exist
    # is decided by whoever writes `List(Int32)` — under separate compilation
    # the consumer, not this module. Those are `MonoBodies`' business (IV.2).
    #
    # Carrying them was tried and is wrong, in a way worth recording because it
    # looks right. `--emit-iyimod` runs inside an ordinary build, so the
    # producer's instantiations *are* the consumer's — it appears to work. It
    # does not: `List(Int32)::new` is synthesized from `initialize` rather than
    # read from the artifact, so the consumer generates its own and the link
    # fails on a duplicate symbol. Carrying an instantiation would also be true
    # only while the two builds are the same build, which is the arrangement
    # this file exists to end.
    private def collect_iyi_unit_names(type : ModuleType, names : Array(String)) : Nil
      type.types?.try &.each_value do |declared|
        unless declared.is_a?(GenericType)
          names << declared.to_s
          virtual = iyi_virtual_unit_name(declared)
          names << virtual unless virtual.empty?
        end
        collect_iyi_unit_names declared, names if declared.is_a?(ModuleType)
      end
    end

    # iyi: `Shard::Base+`, the second unit a class with subclasses has.
    #
    # A value of a class that something inherits from is held as that class's
    # *virtual* type, and codegen puts the methods reached through one in a
    # module of their own — `*Shard::Base+@Shard::Base#describe` lives in
    # `Shard::Base+`, not in `Shard::Base`. Naming only the plain form carried
    # the wrong half: the artifact held a `Shard::Base` unit with the
    # constructor in it and left every inherited method behind, and a consumer
    # calling one linked against nothing.
    #
    # Empty for a class nothing inherits from, whose virtual type is itself —
    # `names` is deduplicated, so an empty string would be the only thing to
    # guard against, and there is nothing to add.
    private def iyi_virtual_unit_name(type : Type) : String
      return "" unless type.responds_to?(:virtual_type)
      virtual = type.virtual_type
      virtual == type ? "" : virtual.to_s
    end

    # The same walk as `collect_iyi_unit_names`, keeping the types rather than
    # their names — `try_inline_call` is handed an owner, not a string.
    private def collect_iyi_owners(type : ModuleType, owners : Set(Type)) : Nil
      type.types?.try &.each_value do |declared|
        unless declared.is_a?(GenericType)
          owners << declared
          # And the virtual form, for the reason `iyi_virtual_unit_name` gives:
          # it is a second unit, it travels, and a unit that travels must have
          # its callees copied into it. Without this the `Shard::Base+` unit
          # arrived referring to `*String#+<String>:String` — a symbol in the
          # consumer's `String` unit only if the consumer's own code happened
          # to concatenate.
          if declared.responds_to?(:virtual_type)
            virtual = declared.virtual_type
            owners << virtual unless virtual == declared
          end
        end
        collect_iyi_owners declared, owners if declared.is_a?(ModuleType)
      end
    end

    # iyi: the pointer maps of the types this module owns, for the `Layouts`
    # section (GC_DESIGN.md Stage 1).
    #
    # The set is the walk `collect_iyi_unit_names` does, kept as types rather
    # than names, with one relaxation: a generic the module declares
    # contributes each instantiation this build has, because an instantiation
    # is monomorphic and has a layout. An uninstantiated generic contributes
    # nothing: one entry serving two instantiations by shape is R-4's
    # per-GC-shape keying, which nothing implements yet, so no entry pretends.
    #
    # Only a type laid out as an object gets a map: a class, a struct, or an
    # instantiation of one. `InstanceVarContainer` is not that filter, because
    # a module and a trait are containers too, and a trait's indirection is
    # the union of its implementors, which is exactly not a layout. A module,
    # an enum and an alias declare no fields of their own to scan in any
    # case.
    private def collect_iyi_layouts(program : Program, module_type : ModuleType) : Array({String, IyiMod::TypeLayout})
      types = [] of Type
      collect_iyi_layout_types module_type, types

      layouts = [] of {String, IyiMod::TypeLayout}
      types.each do |type|
        next unless type.is_a?(NonGenericClassType) || type.is_a?(GenericClassInstanceType)
        next if type.is_a?(GenericType) || type.is_a?(StaticArrayInstanceType)
        layouts << {type.to_s, program.gc_type_layout(type)}
      end

      # Sorted, for the reason `mono_bodies` is: a walk's order is not a fact
      # about the module, and an artifact that changed between two identical
      # builds would defeat IV.3.
      layouts.sort_by! &.[0]
      layouts
    end

    # The walk `collect_iyi_unit_names` does, keeping the types. A generic is
    # not collected itself (it has no layout); each instantiation of it in
    # this build is.
    private def collect_iyi_layout_types(type : ModuleType, types : Array(Type)) : Nil
      type.types?.try &.each_value do |declared|
        if declared.is_a?(GenericType)
          declared.instantiated_types.each do |instance|
            types << instance unless instance.unbound?
          end
        else
          types << declared
        end
        collect_iyi_layout_types declared, types if declared.is_a?(ModuleType)
      end
    end

    # A trait's methods are its whole point in the artifact: II.6 makes an impl
    # checkable against the trait's requirements, and a consumer can only run
    # that check if the requirements travel.
    #
    # A trait's **defaults travel with their bodies**, and so does every method
    # of a generic type, because in both cases the consumer is what compiles
    # them: a default is stencilled onto the implementing type and a generic's
    # method exists once per instantiation. Neither has a symbol any producer
    # could have emitted, which is what separates them from an ordinary method
    # — that one keeps its body and arrives as machine code (IV.2, IV.1g).
    private def iyi_type_declaration(program : Program, filename : String,
                                     name : String, type : Type) : IyiMod::TypeDecl
      # iyi: an annotation has no members at all - no fields, no methods, no
      # layout and no id. What a consumer needs is the *name*, so that
      # `@[Check::Checker]` in its own class resolves, and asking the walk
      # below for an annotation's instance variables ended the build on
      # "BUG: Shapes::Marked doesn't implement instance_vars".
      # iyi: an exported `alias` has neither a layout nor an id either, and
      # travels as what it resolved to - the same rule `iyi_carried_types`
      # applies to one declared *under* an exported type, because a name
      # that resolved where the module was read may not resolve here.
      if type.is_a?(AliasType)
        type.process_value
        return IyiMod::TypeDecl.new(
          name: name,
          kind: type.type_desc,
          type_parameters: [] of String,
          assoc_types: [] of String,
          supertraits: [] of String,
          fields: [] of {String, String, String},
          methods: [] of IyiMod::Signature,
          visibility: "pub",
          value: type.aliased_type?.try(&.to_s) || type.@value.to_s,
          doc: type.doc || "",
        )
      end

      if type.is_a?(AnnotationType)
        return IyiMod::TypeDecl.new(
          name: name,
          kind: type.type_desc,
          type_parameters: [] of String,
          assoc_types: [] of String,
          supertraits: [] of String,
          fields: [] of {String, String, String},
          methods: [] of IyiMod::Signature,
          visibility: "pub",
          doc: type.doc || "",
        )
      end

      # iyi: an `enum` travels as its members and the integer they are
      # numbered on (SPEC.md IV.2).
      #
      # Its *members* are the whole of what a consumer needs, and they travel
      # with their numbers rather than being renumbered: the module's own
      # object code was compiled against these, and a consumer that counted
      # from zero again would agree with it only by luck. Everything else an
      # enum has, the consumer's own compiler makes from this declaration —
      # `value`, `new` and a question method per member — so carrying them
      # would declare each of them twice.
      #
      # Fields are nobody's: an enum has no instance variables, and the walk
      # below asked for them anyway — `BUG: Level::Level doesn't implement
      # instance_vars`, on the first `pub enum` that reached an artifact.
      if type.is_a?(EnumType)
        members = [] of {String, String}
        type.types?.try &.each do |member, constant|
          next unless constant.is_a?(Const)
          # `None` and `All` are the compiler's, not the author's: a `@[Flags]`
          # enum gets both wherever it is declared, so writing them down means
          # the consumer is handed them twice — "flags enum can't redefine All
          # member. None and All are autogenerated", on its own copy.
          next if type.flags? && (member == "None" || member == "All")
          members << {member, constant.value.to_s}
        end

        return IyiMod::TypeDecl.new(
          name: name,
          kind: type.type_desc,
          type_parameters: [] of String,
          assoc_types: [] of String,
          supertraits: [] of String,
          fields: [] of {String, String, String},
          methods: [] of IyiMod::Signature,
          visibility: "pub",
          # Written even when it is the default, because a member's number is
          # only the same number if the width is.
          value: type.base_type.to_s,
          members: members,
          annotations: type.flags? ? ["@[Flags]"] : [] of String,
          doc: type.doc || "",
        )
      end

      travels = iyi_bodies_travel?(type)
      methods = [] of IyiMod::Signature

      # Both sides of the type. A `def self.zero` is stored on the metaclass
      # rather than on the type, so walking only the type's own defs dropped
      # every class method a module exported — `Counter.zero` was an undefined
      # method on the far side of an artifact that looked complete.
      #
      # The two are told apart by the signature's receiver, which
      # `render_signature` already writes back as `def self.zero`. Nothing else
      # needs to know: to a consumer it is one more name on the type.
      iyi_collect_type_methods program, filename, name, type, travels, methods
      iyi_collect_type_methods program, filename, name, type.metaclass, travels, methods
      methods.sort_by! &.name

      # A generic trait's type variables are its parameters followed by its
      # associated types, which is how they are stored and not how they are
      # declared. They are split apart again here, because II.6 makes them
      # different things to a consumer: it supplies the first at the `impl`
      # line and answers the second in the body.
      if generic_trait = type.as?(GenericTraitType)
        type_parameters = generic_trait.trait_params
        assoc_types = generic_trait.assoc_types
      else
        type_parameters = type.as?(GenericType).try(&.type_vars) || [] of String
        assoc_types = [] of String
      end

      # iyi: the `Share` marker travels with the declaration (SPEC.md
      # III.4.4): a type this build found shareable is exported wearing
      # `@[Share]`, and a consumer trusts that rather than recomputing
      # something it cannot — the bodies that said no field is assigned
      # outside `initialize` are not in the artifact. Only a struct or a
      # class has fields to be shareable over; a trait, alias or lib does
      # not carry the marker.
      annotations = [] of String
      if type.is_a?(ClassType) && Iyi::Share.shareable?(type)
        annotations << "@[Share]"
      end

      IyiMod::TypeDecl.new(
        name: name,
        kind: type.type_desc,
        type_parameters: type_parameters,
        assoc_types: assoc_types,
        supertraits: type.responds_to?(:supertraits) ? type.supertraits.map(&.to_s) : [] of String,
        fields: collect_iyi_fields(type),
        class_vars: collect_iyi_class_vars(type),
        methods: methods,
        visibility: "pub",
        types: iyi_carried_types(program, filename, type),
        macros: iyi_macros_on(type),
        annotations: annotations,
        doc: type.doc || "",
      )
    end

    # iyi: the types declared under *type* that a consumer needs to have rather
    # than to call, for `Exports` (SPEC.md IV.1g). *carried* is the names
    # already travelling as part of the module's surface.
    #
    # A module's own machine code refers to them. `Array(Secret):type_id` is
    # resolved from a definition in the consuming program and a program can
    # only number a type it has, so a type this module keeps to itself still
    # has to arrive — declared, and reachable from nowhere, which is exactly
    # what it is when the module is read from source. Nested types travel for
    # the same reason and inside their container, because R-2 governs the
    # module unit's own body and a type declared in a class belongs to the
    # class.
    #
    # Names, kinds, fields and nesting; no methods. The consumer cannot reach
    # them and the module's object code already defines them — and carrying
    # them would make R-2's block rule refuse a module over a *private*
    # method's unannotated block, which is a rule about what another module
    # reads.
    private def iyi_carried_types(program : Program, filename : String, type : Type,
                                  carried : Set(String)? = nil) : Array(IyiMod::TypeDecl)
      declarations = [] of IyiMod::TypeDecl
      type.types?.try &.each do |name, declared|
        next if carried.try &.includes?(name)

        # An alias has neither a layout nor an id, and it travels for the other
        # reason a declaration does: the text that travels names it. A carried
        # record's `handler : Handler` is what the module was written with, and
        # a consumer without the alias reads it as an undefined constant. It
        # arrives as what it resolved to, which is also how a field's type
        # arrives — the name it was written as resolved where the module was
        # read from source, and this file is read somewhere else.
        if declared.is_a?(AliasType)
          declared.process_value
          if aliased = declared.aliased_type?
            declarations << IyiMod::TypeDecl.new(
              name: name,
              kind: declared.type_desc,
              type_parameters: [] of String,
              assoc_types: [] of String,
              supertraits: [] of String,
              fields: [] of {String, String, String},
              methods: [] of IyiMod::Signature,
              visibility: declared.private? ? "private" : "",
              types: [] of IyiMod::TypeDecl,
              value: aliased.to_s,
            )
          end
          next
        end

        # A class or a struct, which is what has a layout and an id. A constant
        # lives in the same namespace and is neither, and it is IV.2's business
        # rather than this.
        next unless declared.is_a?(ClassType) || declared.is_a?(EnumType)

        declarations << IyiMod::TypeDecl.new(
          name: name,
          kind: declared.type_desc,
          type_parameters: declared.as?(GenericType).try(&.type_vars) || [] of String,
          assoc_types: [] of String,
          supertraits: [] of String,
          fields: collect_iyi_fields(declared),
          class_vars: collect_iyi_class_vars(declared),
          methods: iyi_carried_methods(program, filename, name, declared),
          visibility: declared.private? ? "private" : "",
          types: iyi_carried_types(program, filename, declared),
          macros: iyi_macros_on(declared),
        )
      end
      declarations.sort_by! &.name
    end

    # One side of a type's methods — its own, or its metaclass's.
    #
    # `new` is skipped. It is synthesized from `initialize` rather than written,
    # so the consumer generates its own from the `initialize` this artifact
    # does carry; carrying it as well would declare a method the consumer also
    # defines, and for a type whose object code travels it would be defined
    # twice over.
    private def iyi_collect_type_methods(program : Program, filename : String,
                                         container : String, type : Type,
                                         travels : Bool,
                                         methods : Array(IyiMod::Signature)) : Nil
      type.as?(ModuleType).try &.defs.try &.each_value do |items|
        # A method an `impl` defined is the impl's, and travels in its record.
        # The distinction is invisible here — an impl works by defining methods
        # on the target — which is why it is marked where it is made.
        items.each do |item|
          next if item.def.iyi_from_impl?
          next if item.def.new?

          # `allocate` is put on every metaclass by the compiler, not by the
          # author, and the consumer's compiler puts one there too. Anything
          # whose body is a `Primitive` is the compiler's rather than the
          # module's, and describing it as part of the module's surface would
          # be describing this compiler instead.
          next if item.def.body.is_a?(Primitive)

          signature = IyiMod.signature(item.def)
          methods << signature
          # A block-taking def travels whatever type it is on: it is
          # instantiated with the caller's block inside it, so the consumer is
          # what compiles it — the same reason a generic's method and a trait's
          # default travel (SPEC.md IV.1g).
          #
          # And a def whose machine code enumerates an open type's members, or
          # which calls one that does, for the reason III.6 gives: the set is
          # the whole program's, so the answer is too. `Iyi::OpenTravel` marked
          # it before this ran.
          if (travels || iyi_takes_block?(item.def) || item.def.iyi_open_travel?) &&
             !item.def.abstract?
            iyi_record_mono_body program, filename, container, signature, item.def
          end
        end
      end
    end

    # iyi: whether *type*'s method bodies have to travel (`MonoBodies`).
    #
    # Two cases, and the same reason under both: the consumer is what compiles
    # the method, so no machine code the producer emits could serve it. A
    # generic type's method exists once per instantiation, and instantiations
    # belong to whoever writes them. A trait's default is stencilled onto the
    # implementing type, which the producer has never heard of —
    # `Samples::Collections::Nums@Std::Enumerable::Enumerable#to_a` is not a
    # symbol any producer could have emitted under any name.
    private def iyi_bodies_travel?(type : Type) : Bool
      type.is_a?(GenericType) || type.is_a?(TraitType)
    end

    # iyi: the methods of a type the module keeps to itself.
    #
    # They travel because a *body* that travels calls them: the router's
    # `add_filter` is a block-taking method, so the consumer compiles it, and
    # it writes `FilterDefinition.new(kind: …)`. Without the signature the
    # consumer sees a `record` with no `initialize` and refuses the call.
    #
    # Headers, because the machine code is in this module's own object code and
    # the type is marked as the artifact's so the consumer declares rather than
    # defines — except for the one method that has no machine code here either.
    # A block-taking method is instantiated with the caller's block inside it
    # wherever it is written, and being unreachable does not change who the
    # caller is: `run` travels, `run` calls `Hidden#tweak`, so the consumer
    # compiles both. A header for it would promise a symbol nobody emitted.
    #
    # R-2's block rule is not applied to any of them, because it is about what
    # another module reads and nothing here is readable. It costs nothing to
    # skip: the annotation is what types a call to a def whose body stayed
    # behind, and these bodies do not stay behind.
    private def iyi_carried_methods(program : Program, filename : String,
                                    container : String, type : Type) : Array(IyiMod::Signature)
      signatures = [] of IyiMod::Signature
      type.as?(ModuleType).try &.defs.try &.each_value do |items|
        items.each do |item|
          next if item.def.new?
          next if item.def.body.is_a?(Primitive)
          next if item.def.abstract?

          signature = IyiMod.signature(item.def, check_block: false)
          signatures << signature
          # The same two reasons the exported side travels for: a block-taking
          # body is the caller's, and one whose code answers for an open set is
          # the program's (SPEC.md III.6). A header for either would promise a
          # symbol nobody emitted.
          if iyi_takes_block?(item.def) || item.def.iyi_open_travel?
            iyi_record_mono_body program, filename, container, signature, item.def
          end
        end
      end
      signatures.sort_by! &.name
    end

    # iyi: whether a def is instantiated per call site because it takes a
    # block — `&block : …` or a bare `yield` (SPEC.md IV.1g).
    private def iyi_takes_block?(a_def : Def) : Bool
      !!(a_def.block_arg || a_def.block_arity)
    end

    # Records one body against `IyiMod.mono_body_key`.
    #
    # Source text rather than serialised IR, which is what IV.1's table asks
    # for. It is the same choice `Exports` already made and for the same
    # reason: the parser that read the module is the one that reads it back,
    # and a second grammar here is a second thing to keep correct. The text is
    # the *normalised* body rather than the file's, because that is what
    # survives to this point — which makes it worth checking that what comes
    # out still parses, and `spec/compiler/iyimod_spec.cr` does.
    # iyi: the macros a module declares, as source text, for `MacroBodies`
    # (SPEC.md IV.1).
    #
    # A macro is not a declaration a consumer may reach — `pub` does not take
    # one — and it is not code that could arrive as machine code either. It
    # travels because a *body* that travels calls it: the consumer compiles a
    # block-taking `run`, `run` writes `twice(n)`, and `twice` is this module's
    # macro. Without it the artifact is refused on a name its own module has.
    #
    # Rendered from the node rather than sliced out of the file, which is what
    # the bodies beside it do. What the parser produced is what a parser can
    # read back, and the alternative — remembering where in the file it was —
    # is a fact about a file the consumer does not have.
    #
    # Read off the *metaclass*, which is where a macro is declared: `macro
    # twice` in a module body is added to the module's metaclass, the same way
    # `def self.zero` is, and the type's own `macros` is empty for a file full
    # of them.
    private def collect_iyi_macros(program : Program, module_name : String) : Array(String)
      iyi_macros_on(program.iyi_module_type(module_name))
    end

    # The macros declared on one type, which is the same question one level in:
    # a class may declare a macro and a method of that class may call it, and
    # the method's body is what travels.
    private def iyi_macros_on(type : Type?) : Array(String)
      sources = [] of String
      type.try &.metaclass.as?(ModuleType).try &.macros.try &.each_value do |overloads|
        overloads.each { |a_macro| sources << a_macro.to_s }
      end
      sources.sort!
    end

    private def iyi_record_mono_body(program : Program, filename : String,
                                     container : String, signature : IyiMod::Signature,
                                     a_def : Def) : Nil
      bodies = program.iyi_mono_bodies[filename] ||= {} of String => String
      bodies[IyiMod.mono_body_key(container, signature)] = a_def.body.to_s
    end

    # iyi: a type's own instance variables, for `TypeDecl#fields` (IV.2).
    #
    # Rendered from the resolved type rather than kept as the annotation the
    # author wrote, which is a departure from how signatures travel and is
    # deliberate: a field is not part of the surface a consumer writes against,
    # it is what the consumer has to *allocate*, and the resolved type is the
    # thing that answers that. For a generic type the resolution is in terms of
    # its own parameters — `List(T)`'s `@items` is `Array(T)` — which is what
    # lets the declaration stencil at any instantiation.
    #
    # In the order they were declared, which is not a presentation choice: it
    # is the layout. A field's offset is its position in this list, so the two
    # builds have to agree on it — sorting them by name was deterministic and
    # wrong, and it went unnoticed for as long as nothing the consumer compiled
    # touched a field of a type it had only imported. A block-taking method's
    # body is the first thing that does: the consumer's `add_route` wrote
    # `@routes` at the offset the producer's code reads `@filters` from.
    #
    # Deterministic all the same. What the sort was guarding against is a
    # hash's order being an accident, and this one is not — `instance_vars` is
    # insertion-ordered and the insertions are the declarations, in the order
    # the module's author wrote them.
    private def collect_iyi_fields(type : Type) : Array({String, String, String})
      fields = [] of {String, String, String}
      return fields unless type.responds_to?(:instance_vars)

      # The default the module wrote, where it wrote one. In place beside the
      # field rather than after the others, because a field's position in this
      # list is its position in the layout. See `IyiMod::TypeDecl#fields`.
      defaults = {} of String => String
      if type.responds_to?(:instance_vars_initializers)
        type.instance_vars_initializers.try &.each do |initializer|
          defaults[initializer.name] = initializer.written
        end
      end

      type.instance_vars.each do |name, variable|
        # A variable whose type never resolved is a rule broken elsewhere, and
        # recorded as `?` rather than guessed at — the same convention an
        # unannotated signature takes, and equally visible in `mod dump`.
        fields << {name, variable.type?.try(&.to_s) || "?", defaults[name]? || ""}
      end
      fields
    end

    # iyi: a type's own class variables, for `TypeDecl#class_vars` (SPEC.md
    # IV.2).
    #
    # A class variable is a *global*. The methods that read one travel as this
    # module's machine code and refer to it by name, and the global they refer
    # to is defined in the main module — the one part of a build that never
    # travels. So a module with a `@@seen` failed R-1's own round trip: build,
    # delete the source, build again, and the link ended on
    # `undefined symbol: App::Counter::Tally::seen`.
    #
    # Its type comes from the resolved type for the same reason a field's does:
    # what a consumer needs is not the annotation somebody wrote, it is the
    # thing it has to allocate a global of.
    #
    # Its *value* does not. The initialiser has to run on the far side, so what
    # travels is the node as written — the same channel a module's top-level
    # code takes, and faithful for the same reason: normalisation rewrites
    # control flow, not literals.
    #
    # Own only, and `class_vars?` rather than `class_vars` says so. Looking one
    # up walks ancestors and *copies* what it finds onto the asking type, so a
    # module that merely reads `@@x` from an included module would otherwise
    # declare a second one of its own.
    private def collect_iyi_class_vars(type : Type) : Array(IyiMod::ClassVarDecl)
      class_vars = [] of IyiMod::ClassVarDecl
      return class_vars unless type.responds_to?(:class_vars?)

      type.class_vars?.try &.each do |name, variable|
        initialiser = variable.iyi_initialiser_source
        # `@[ThreadLocal]` travels with it: a consumer that declared the
        # variable without it writes to a different global than this module's
        # object code does. See `IyiMod::ClassVarDecl`.
        annotations = variable.thread_local? ? ["@[ThreadLocal]"] : [] of String
        class_vars << IyiMod::ClassVarDecl.new(name, variable.type?.try(&.to_s) || "?",
          initialiser, annotations)
      end
      class_vars
    end

    # Measures what a compile costs when the prelude has already been analysed,
    # gated behind IYI_FORK_PROBE=1. Temporary instrumentation, like `Prof`.
    #
    # The parent runs the top-level passes over the prelude alone and forks. The
    # child then compiles the user program against a `Program` that already has
    # the prelude in it, so restoring the prelude costs it a `fork` — around a
    # millisecond, a floor no serialised `.iyimod` can beat. The child's elapsed
    # time is therefore the ceiling of the whole `.iyimod` idea, obtainable
    # without designing the format.
    #
    # Front-end only: the child stops after semantic analysis. Codegen and
    # linking are LLVM's and the linker's problem, and `.iyimod`'s object-code
    # section addresses them separately.
    #
    # Known limit: compiling the compiler itself still fails under both models —
    # a `NilAssertionError` in `add_instance_var_initializer` under the artifact
    # model, and an error during the top-level pass under the full one. The
    # split runs `TypeDeclarationProcessor` twice, and part of its work is
    # global rather than per-tree, so the second run does not see everything the
    # first established. The nine smaller programs in the gate do not exercise
    # that. This is the next thing to fix before the probe becomes a build
    # daemon, and it is a real defect rather than a measurement caveat.
    #
    # Set IYI_FORK_TRACE=1 to see how far the child gets, and
    # IYI_FORK_SELFTEST=1 to check the runtime facilities a build needs (file
    # write, flock, subprocess) before it starts.
    #
    # Two models, because they answer different questions:
    #
    # * `IYI_FORK_PROBE=1` — the artifact exactly as Part IV describes it. The
    #   parent runs only the *top-level* passes over the prelude, so the child
    #   still walks the combined tree in every pass after that, and three passes
    #   still walk the whole type graph. That residual is the work a `.iyimod`
    #   would not remove on its own.
    #
    # * `IYI_FORK_PROBE=full` — the artifact *plus* prelude-aware passes. The
    #   parent analyses the prelude completely and the child touches only its
    #   own nodes. This prices IV.1a's third row: what the later passes would
    #   have to become for the front end to reach its floor.
    #
    #   It is 10× faster than the artifact model on the small programs in the
    #   gate, where it also reports what a normal compile reports and emits an
    #   object with an identical symbol table.
    #
    #   It does not work on real code, and the reason is structural rather than
    #   incidental: analysing the prelude *through `main`* and then declaring new
    #   types into it re-enters machinery that assumes declaration precedes
    #   typing. Subclassing a prelude type is enough to trip it — see SPEC.md
    #   IV.1e. Part IV's artifact carries types and signatures, not typed method
    #   bodies, so this model measures more than `.iyimod` restores. Treat its
    #   numbers as a ceiling on a configuration that does not work.
    #
    #   One trap, because it looks like a soundness failure and is not. Give
    #   codegen only the user tree and it dies with:
    #
    #     Missing __crystal_raise_overflow function
    #
    #   That is a `fun` in `src/raise.cr`, and codegen emits `fun`s and top-level
    #   code by walking the AST — so the prelude's tree has to reach codegen no
    #   matter what the front end did with it. That is the artifact's
    #   object-code section, not its analysis cache: the two need the prelude for
    #   different reasons.
    private def prelude_fork_probe(sources : Array(Source), output_filename : String) : NoReturn
      {% unless flag?(:without_mt) %}
        STDERR.puts "IYI_FORK_PROBE needs a single-threaded compiler: make crystal sequential_codegen=1"
        exit 1
      {% else %}
        program = new_program(sources)
        full = ENV["IYI_FORK_PROBE"]? == "full"

        prelude_elapsed = Time.instant
        location = Location.new(program.filename, 1, 1)
        prelude_node = program.normalize(Expressions.new([Require.new(prelude).tap(&.iyi_prelude=(true)).at(location)] of ASTNode))
        prelude_node, prelude_processor = program.top_level_semantic(prelude_node)
        if full
          # Keep what it returns: the cleanup transformer rewrites the tree, and
          # codegen needs the rewritten one — the original still holds an
          # unexpanded `require`.
          prelude_node = program.semantic_after_top_level(prelude_node, prelude_processor, cleanup: !no_cleanup?)
        end
        prelude_taken = prelude_elapsed.elapsed
        @progress_tracker.clear

        probe_trace "[probe] parent: forking\n"
        pid = Crystal::System::Process.fork do
          probe_trace "[probe] child: alive\n"
          if ENV["IYI_FORK_SELFTEST"]?
            # Which runtime facility does a forked child actually lose? Each of
            # these is something a build needs, so whichever hangs is the one
            # standing between the probe and a real build daemon.
            probe_trace "[probe] selftest: file write\n"
            File.write("/tmp/iyi_probe_selftest", "x")
            probe_trace "[probe] selftest: flock\n"
            File.open("/tmp/iyi_probe_selftest", "w") { |f| f.flock_exclusive { } }
            probe_trace "[probe] selftest: subprocess\n"
            ::Process.run("true", shell: true)
            probe_trace "[probe] selftest: all passed\n"
          end
          child_elapsed = Time.instant
          begin
            nodes = sources.map do |source|
              program.requires.add source.filename
              parse(program, source).as(ASTNode)
            end
            probe_trace "[probe] child: parsed\n"
            user_node = program.normalize(Expressions.from(nodes))

            # Continue with the parent's processor: `Socket` is declared here but
            # includes `IO::Buffered`, which was declared there, and only a
            # shared processor gives the class the module's instance variables.
            user_node, processor = program.top_level_semantic(user_node, processor: prelude_processor)
            probe_trace "[probe] child: top level done\n"

            result = if full
                       # Prelude fully analysed in the parent, including its class-var
                       # check, so the child finishes over its own nodes alone.
                       program.semantic_after_top_level(user_node, processor, cleanup: !no_cleanup?)
                     else
                       # The prelude was processed by the parent's own processor, so its
                       # class-var check has to be threaded through as well, or the child
                       # would skip a check a normal compile performs.
                       combined = Expressions.from([prelude_node, user_node] of ASTNode)
                       program.semantic_after_top_level(combined, processor,
                         cleanup: !no_cleanup?, also_check: prelude_processor)
                     end
            probe_trace "[probe] child: semantic done\n"

            # Proving the child's typed program is *codegen-able* is a stronger
            # claim than proving it reports the same diagnostics, so
            # IYI_FORK_CODEGEN=1 goes on to emit object code. Pair it with
            # `--cross-compile` and expect it to write the object and then hang:
            # everything after the emit spawns a subprocess, which is the one
            # thing the forked child cannot do. Kill it and compare the object.
            #
            # It is a verification tool, not a timing one — it never completes,
            # so it stays off by default and out of every measurement.
            if !@no_codegen && ENV["IYI_FORK_CODEGEN"]?
              # Codegen emits `fun` definitions and top-level code by walking the
              # AST, so it needs the prelude's tree even when the front end did
              # not. That is not a fudge: it is what Part IV's object-code
              # section means — the prelude's machine code comes from the
              # artifact rather than from re-analysing its source. Skipping the
              # prelude in the *front end* is the claim under test; skipping it
              # in codegen too would just be leaving the program half-emitted.
              to_emit = full ? Expressions.from([prelude_node, result] of ASTNode) : result
              codegen program, to_emit, sources, output_filename
              probe_trace "[probe] child: codegen done\n"
            end
          rescue ex : Iyi::CodeError
            # Same decision the driver makes in `Command#run`, so the child's
            # diagnostics are byte-identical to a normal compile's.
            ex.color = color? && Colorize.default_enabled?(STDOUT, STDERR)
            ex.error_trace = show_error_trace?
            STDERR.puts ex
            report_probe(prelude_taken, child_elapsed.elapsed)
            STDOUT.flush
            STDERR.flush
            LibC._exit 1
          end

          report_probe(prelude_taken, child_elapsed.elapsed)
          STDOUT.flush
          STDERR.flush
          LibC._exit 0
        end

        status = ::Process.new(Crystal::System::Process.new(pid.not_nil!)).wait
        exit status.exit_code
      {% end %}
    end

    # Unbuffered and allocation-free, so it still reports if the child is wedged
    # on the event loop or on the collector. Pass string literals only.
    # Resolved in the parent, before the fork, so the child never has to touch
    # ENV (which allocates) just to decide whether to trace.
    PROBE_TRACE = !ENV["IYI_FORK_TRACE"]?.nil?

    private def probe_trace(msg : String) : Nil
      return unless PROBE_TRACE
      LibC.write(2, msg.to_unsafe.as(Void*), LibC::SizeT.new(msg.bytesize))
    end

    private def report_probe(prelude_taken : Time::Span, child_taken : Time::Span) : Nil
      @progress_tracker.clear
      Prof.report
      STDERR.puts
      STDERR.puts "=== IYI_FORK_PROBE ==="
      STDERR.puts "prelude top level (parent, paid once) #{prelude_taken}"
      STDERR.puts "front end with prelude already analysed #{child_taken}"
    end

    # Runs the semantic pass on the given source, without generating an
    # executable nor analyzing methods. The returned `Program` in the result will
    # contain all types and methods. This can be useful to generate
    # API docs, analyze type relationships, etc.
    #
    # Raises `Iyi::CodeError` if there's an error in the
    # source code.
    #
    # Raises `InvalidByteSequenceError` if the source code is not
    # valid UTF-8.
    def top_level_semantic(source : Source | Array(Source)) : Result
      source = [source] unless source.is_a?(Array)
      program = new_program(source)
      node = parse program, source
      node, _ = program.top_level_semantic(node)

      @progress_tracker.clear
      print_macro_run_stats(program)

      Result.new program, node
    end

    # Set maximum level of optimization.
    def release!
      @optimization_mode = OptimizationMode::O3
      @single_module = true
    end

    def release?
      @optimization_mode.o3? && @single_module
    end

    private def new_program(sources)
      @program = program = Program.new
      program.iyi_prelude = prelude.ends_with?("iyi/prelude")
      program.compiler = self
      program.filename = sources.first.filename
      program.codegen_target = codegen_target
      program.target_machine = create_target_machine
      program.flags << "release" if release?
      program.flags << "debug" unless debug.none?
      program.flags << "static" if static?
      program.flags.concat @flags
      program.define_crystal_constants
      program.wants_doc = wants_doc? || !@emit_iyimod.nil?
      program.color = color?
      program.stdout = stdout
      program.show_error_trace = show_error_trace?
      program.progress_tracker = @progress_tracker
      program.warnings = @warnings
      program.iyi_file_overrides = @iyi_file_overrides
      program.iyi_project_root = @iyi_project_root
      program.iyi_header_root = @iyi_header_root
      program.optimization_mode = @optimization_mode
      program.iyi_module_dir = @use_iyimod
      program.iyi_wants_object_code = !@no_codegen
      program.iyi_rewrites_artifacts = !@emit_iyimod.nil?
      # iyi: the manifest, if the entry file's directory has one (III.7) —
      # or the table a tool prepared, which wins because the tool resolved
      # the *user's* manifest and the entry may be a dependency with none.
      # A manifest failure is a build error with the manifest's name in it,
      # not a compiler bug banner.
      if table = @iyi_mod_table
        program.iyi_mod_table = table
      elsif filename = program.filename
        begin
          program.iyi_mod_table = Mod::Installer.table_for(File.dirname(filename))
        rescue ex : Mod::ModError
          raise Error.new(ex.message)
        end
      end
      program
    end

    private def parse(program, sources : Array)
      @progress_tracker.stage("Parse") do
        nodes = sources.map do |source|
          # We add the source to the list of required file,
          # so it can't be required again
          program.requires.add source.filename
          parse(program, source).as(ASTNode)
        end
        nodes = Expressions.from(nodes)

        # Prepend the prelude to the parsed program
        location = Location.new(program.filename, 1, 1)
        nodes = Expressions.new([Require.new(prelude).tap(&.iyi_prelude=(true)).at(location), nodes] of ASTNode)

        # And normalize
        program.normalize(nodes)
      end
    end

    private def parse(program, source : Source)
      parser = program.new_parser(source.code)
      parser.filename = source.filename
      parser.wants_doc = program.wants_doc?
      parser.parse
    rescue ex : InvalidByteSequenceError
      # iyi: whichever language the file is written in. A `.iyi` file full of
      # bytes that are not text was reported as "not a valid Crystal source
      # file", which names the other language for a file this one was asked
      # to read - the identity `bench/identity_floor.py` exists to keep.
      language = source.filename.ends_with?(".iyi") ? "iyi" : "Crystal"
      stderr.print colorize("Error: ").red.bold
      stderr.print colorize("file '#{Iyi.relative_filename(source.filename)}' is not a valid #{language} source file: ").bold
      stderr.puts ex.message
      exit 1
    end

    private def bc_flags_changed?(output_dir)
      bc_flags_changed = true
      current_bc_flags = "#{@codegen_target}|#{@mcpu}|#{@mattr}|#{@link_flags}|#{@mcmodel}"
      bc_flags_filename = "#{output_dir}/bc_flags#{optimization_mode.suffix}"
      if File.file?(bc_flags_filename)
        previous_bc_flags = File.read(bc_flags_filename).strip
        bc_flags_changed = previous_bc_flags != current_bc_flags
      end
      File.write(bc_flags_filename, current_bc_flags)
      bc_flags_changed
    end

    private def codegen(program, node : ASTNode, sources, output_filename)
      {% if LibLLVM::IS_LT_130 %}
        if @codegen_target.architecture == "aarch64"
          stderr.puts "Error: Target #{@codegen_target} requires a Crystal compiler built with LLVM 13 or a later version."
          exit 1
        end
      {% end %}

      llvm_modules = @progress_tracker.stage("Codegen (crystal)") do
        program.codegen node, debug: debug, frame_pointers: frame_pointers,
          single_module: @single_module || @cross_compile || !@emit_targets.none?
      end

      output_dir = CacheDir.instance.directory_for(sources)

      bc_flags_changed = bc_flags_changed? output_dir
      target_triple = target_machine.triple

      units = llvm_modules.map do |type_name, info|
        llvm_mod = info.mod
        llvm_mod.target = target_triple
        CompilationUnit.new(self, program, type_name, llvm_mod, output_dir, bc_flags_changed)
      end

      {% if LibLLVM::IS_LT_170 %}
        # initialize the legacy pass manager once in the main thread/process
        # before we start codegen in threads (MT) or processes (fork)
        init_llvm_legacy_pass_manager unless optimization_mode.o0?
      {% end %}

      if @cross_compile
        cross_compile program, units, output_filename
      else
        units = with_file_lock(output_dir) do
          codegen program, units, output_filename, output_dir
        end

        {% if flag?(:darwin) %}
          run_dsymutil(output_filename) unless debug.none?
        {% end %}

        {% if flag?(:msvc) %}
          copy_dlls(program, output_filename) unless static?
        {% end %}
      end

      CacheDir.instance.cleanup if @cleanup

      units
    end

    private def with_file_lock(output_dir, &)
      File.open(File.join(output_dir, "compiler.lock"), "w") do |file|
        file.flock_exclusive do
          yield
        end
      end
    end

    private def run_dsymutil(filename)
      dsymutil = Process.find_executable("dsymutil")
      return unless dsymutil

      @progress_tracker.stage("dsymutil") do
        Process.run(dsymutil, ["--flat", filename])
      end
    end

    private def copy_dlls(program, output_filename)
      not_found = nil
      output_directory = File.dirname(output_filename)

      program.each_dll_path do |path, found|
        if found
          dest = File.join(output_directory, File.basename(path))
          File.copy(path, dest) unless File.exists?(dest)
        else
          not_found ||= [] of String
          not_found << path
        end
      end

      if not_found
        stderr << "Warning: The following DLLs are required at run time, but Crystal is unable to locate them in IYI_LIBRARY_PATH, the compiler's directory, or PATH: "
        not_found.sort!.join(stderr, ", ")
      end
    end

    private def cross_compile(program, units, output_filename)
      unit = units.first
      llvm_mod = unit.llvm_mod

      @progress_tracker.stage("Codegen (bc+obj)") do
        optimize llvm_mod, target_machine unless @optimization_mode.o0?

        unit.emit(@emit_targets, emit_base_filename || output_filename)

        target_machine.emit_obj_to_file llvm_mod, output_filename
      end
      object_names = [output_filename]
      output_filename = output_filename.rchop(unit.object_extension)
      _, command, args = linker_command(program, object_names, output_filename, nil)
      print_command(command, args)
    end

    private def print_command(command, args)
      stdout.puts command.sub(%("${@}"), args && Process.quote(args))
    end

    private def linker_command(program : Program, object_names, output_filename, output_dir, expand = false)
      if program.has_flag? "msvc"
        lib_flags = program.lib_flags(@cross_compile)
        lib_flags = expand_lib_flags(lib_flags) if expand

        object_arg = Process.quote_windows(object_names)
        output_arg = Process.quote_windows("/Fe#{output_filename}")

        linker, link_args = program.msvc_compiler_and_flags
        linker = Process.quote_windows(linker)
        link_args.map! { |arg| Process.quote_windows(arg) }

        link_args << "/DEBUG:FULL /PDBALTPATH:%_PDB%" unless debug.none?
        link_args << "/INCREMENTAL:NO /STACK:0x800000"
        link_args << lib_flags
        @link_flags.try { |flags| link_args << flags }

        {% if flag?(:msvc) %}
          unless @cross_compile
            extra_suffix = static? ? "-static" : "-dynamic"
            search_result = Loader.search_libraries(Process.parse_arguments_windows(link_args.join(' ').gsub('\n', ' ')), extra_suffix: extra_suffix)
            if not_found = search_result.not_found?
              raise CompilerError.new("Cannot locate the .lib files for the following libraries: #{not_found.join(", ")}", :FAILURE)
            end

            link_args = search_result.remaining_args.concat(search_result.library_paths).map { |arg| Process.quote_windows(arg) }
          end
        {% end %}

        args = %(/nologo #{object_arg} #{output_arg} /link #{link_args.join(' ')}).gsub("\n", " ")
        cmd = "#{linker} #{args}"

        if cmd.to_utf16.size > 32000
          # The command line would be too big, pass the args through a UTF-16-encoded file instead.
          # TODO: Use a proper way to write encoded text to a file when that's supported.
          # The first character is the BOM; it will be converted in the same endianness as the rest.
          args_16 = "\ufeff#{args}".to_utf16
          args_bytes = args_16.to_unsafe_bytes

          args_filename = "#{output_dir}/linker_args.txt"
          File.write(args_filename, args_bytes)
          cmd = "#{linker} #{Process.quote_windows("@" + args_filename)}"
        end

        {linker, cmd, nil}
      elsif program.has_flag? "wasm32"
        # iyi: the compiler driver rather than `wasm-ld`, because a wasi program
        # is more than the module. wasi-libc's `crt1.o` is what exports `_start`
        # and calls `__main_argc_argv`; `wasm-ld -lc` on its own links a module
        # with no entry, which every host refuses to start. Only the driver knows
        # where its sysroot keeps that object, so naming the driver is the only
        # way to print a command that produces a program.
        link_flags = @link_flags || ""
        link_flags += " --target=wasm32-wasi"
        {DEFAULT_LINKER, %(#{DEFAULT_LINKER} "${@}" -o #{Process.quote_posix(output_filename)} #{link_flags} #{program.lib_flags(@cross_compile)}), object_names}
      elsif program.has_flag? "avr"
        link_flags = @link_flags || ""
        link_flags += " --target=avr-unknown-unknown -mmcu=#{@mcpu} -Wl,--gc-sections"
        {DEFAULT_LINKER, %(#{DEFAULT_LINKER} "${@}" -o #{Process.quote_posix(output_filename)} #{link_flags} #{program.lib_flags(@cross_compile)}), object_names}
      elsif program.has_flag?("win32") && program.has_flag?("gnu")
        link_flags = @link_flags || ""
        link_flags += " -Wl,--stack,0x800000"
        link_flags = use_modern_linker(link_flags)
        lib_flags = program.lib_flags(@cross_compile)
        lib_flags = expand_lib_flags(lib_flags) if expand
        cmd = %(#{DEFAULT_LINKER} #{Process.quote_windows(object_names)} -o #{Process.quote_windows(output_filename)} #{link_flags} #{lib_flags}).gsub('\n', ' ')

        if cmd.size > 32000
          # The command line would be too big, pass the args through a file instead.
          # GCC response file does not interpret those args as shell-escaped
          # arguments, we must rebuild the whole command line
          args_filename = "#{output_dir}/linker_args.txt"
          File.open(args_filename, "w") do |f|
            object_names.each do |object_name|
              f << object_name.gsub(GCC_RESPONSE_FILE_TR) << ' '
            end
            f << "-o " << output_filename.gsub(GCC_RESPONSE_FILE_TR) << ' '
            f << link_flags << ' ' << lib_flags
          end
          cmd = "#{DEFAULT_LINKER} #{Process.quote_windows("@" + args_filename)}"
        end

        {DEFAULT_LINKER, cmd, nil}
      else
        link_flags = @link_flags || ""
        link_flags += " -rdynamic"

        if program.has_flag?("freebsd") || program.has_flag?("openbsd")
          # pkgs are installed to usr/local/lib but it's not in LIBRARY_PATH by
          # default; we declare it to ease linking on these platforms:
          link_flags += " -L/usr/local/lib"
        end

        link_flags = use_modern_linker(link_flags)
        lib_flags = program.lib_flags(@cross_compile)

        if direct = iyi_direct_link_command(object_names, output_filename, link_flags, lib_flags)
          return direct
        end

        {DEFAULT_LINKER, %(#{DEFAULT_LINKER} "${@}" -o #{Process.quote_posix(output_filename)} #{link_flags} #{lib_flags}), object_names}
      end
    end

    # iyi: the link without the driver that works out how to do it.
    #
    # `cc` does not link. It computes a command — the dynamic linker's path,
    # `Scrt1.o`, `crti.o`, `crtbeginS.o`, the `-L` directories, `-lgcc -lc` and
    # the rest — and runs `collect2`, which scans the objects for constructors
    # and runs `ld`. Measured here, linking `hello.iyi`: 0.129 s through `cc`
    # and **0.014 s** running the same `ld` command directly. The linker is not
    # the cost and never was; three of them come out between 0.009 s and
    # 0.023 s. The driver and its scanner are 0.11 s of every build.
    #
    # So the driver is asked *once* for the command and the compiler runs `ld`
    # itself from then on. `cc -###` prints that command without linking
    # anything — including for object files that do not exist, which is what
    # makes a reusable template possible: the placeholder marks where this
    # build's objects go.
    #
    # `clang` does this already: it has no `collect2` and execs the linker
    # itself, which is why it measures 0.092 s where `cc` measures 0.129 s.
    # Skipping the scan is not a shortcut around something needed — a program
    # linked this way runs, and every clang-linked binary on the machine was
    # made without it.
    #
    # Nil when anything is unfamiliar, and the driver is used as before. The
    # template is cached against the flags it was computed for; a link that
    # fails with it is retried through the driver and the template is marked
    # unusable, so a machine this does not suit pays one extra link once.
    private def iyi_direct_link_command(object_names, output_filename, link_flags, lib_flags)
      return nil if @cross_compile
      return nil if @iyi_link_driver_only
      return nil if ENV["IYI_LINK_DRIVER"]?
      return nil unless DEFAULT_LINKER == "cc"
      # Where it has been measured, and nowhere else. The shape this parses is
      # a GNU driver's: `collect2`, an LTO plugin, `-fuse-ld=`. A macOS `cc`
      # prints `ld64` with different arguments, and the template would either
      # fail and fall back — one wasted link per set of flags — or work by
      # accident. Somebody with the machine to measure it can widen this.
      return nil unless codegen_target.linux?

      template = iyi_link_template(link_flags, lib_flags)
      return nil unless template

      linker, prefix, suffix = template
      output = Process.quote_posix(output_filename)
      command = "#{linker} #{prefix.gsub(IYI_LINK_OUTPUT, output)} \"${@}\" #{suffix.gsub(IYI_LINK_OUTPUT, output)}"
      @iyi_direct_link = true
      {linker, command, object_names}
    end

    # What stands where this build's objects and output go in the template.
    IYI_LINK_OBJECTS = "IYI-OBJECTS-PLACEHOLDER.o"
    IYI_LINK_OUTPUT  = "IYI-OUTPUT-PLACEHOLDER"

    # The linker command the driver would have built, as {linker, before, after}.
    private def iyi_link_template(link_flags, lib_flags)
      key = ::Crystal::Digest::MD5.hexdigest(
        "#{DEFAULT_LINKER}\n#{link_flags}\n#{lib_flags}\n#{codegen_target}\n1")
      # One file per set of flags, rather than one file: two programs in a
      # directory that link different libraries would otherwise take turns
      # overwriting each other's answer and asking the driver again each time.
      cache = CacheDir.instance.join("link-template-#{key}")

      if File.file?(cache)
        stored = File.read(cache).split('\n')
        if stored[0]? == key && stored[1]? == iyi_link_inputs_fingerprint(stored[3]?)
          return nil if stored[2]? == "unusable"
          if (linker = stored[2]?) && (prefix = stored[3]?) && (suffix = stored[4]?)
            return {linker, prefix, suffix}
          end
        end
      end

      template = iyi_ask_driver_for_link_template(link_flags, lib_flags)
      linker, prefix, suffix = template if template
      stamp = iyi_link_inputs_fingerprint(prefix)
      File.write(cache, template ? "#{key}\n#{stamp}\n#{linker}\n#{prefix}\n#{suffix}" : "#{key}\n#{stamp}\nunusable") rescue nil
      template
    end

    # What the template was computed against, so that a toolchain moving under
    # it is noticed rather than linked with.
    #
    # The template names absolute paths — `Scrt1.o`, `crti.o`, `crtbeginS.o`
    # and the directories around them — and a `libc` or `gcc` upgrade changes
    # them. Each is stat'ed, which is microseconds on files this local, and the
    # answer goes in beside the template: if one has moved, the driver is asked
    # again. Without this, an upgrade turns into a link failure, then a
    # fallback, and then a build that quietly uses the slow path for as long as
    # the flags stay the same.
    private def iyi_link_inputs_fingerprint(prefix : String?) : String
      return "" unless prefix
      stamped = String.build do |io|
        prefix.split(' ').each do |token|
          next unless token.ends_with?(".o") && token.starts_with?('/')
          io << token << ':'
          if info = File.info?(token)
            io << info.size << ':' << info.modification_time.to_unix
          else
            io << "gone"
          end
          io << '\n'
        end
      end
      ::Crystal::Digest::MD5.hexdigest(stamped)
    end

    # Asks the driver what it would run, and turns it into a template.
    #
    # Everything it prints is kept except the parts that belong to the driver
    # rather than to the link: the LTO plugin it loads into `collect2`, and the
    # `-fuse-ld=` that told it which linker to pick — which is read here to
    # pick the same one.
    private def iyi_ask_driver_for_link_template(link_flags, lib_flags)
      probe = "#{DEFAULT_LINKER} #{IYI_LINK_OBJECTS} -o #{IYI_LINK_OUTPUT} #{link_flags} #{lib_flags} -###"
      printed = IO::Memory.new
      status = Process.run(probe, shell: true, output: Process::Redirect::Close, error: printed)
      return nil unless status.success?

      line = printed.to_s.lines.reverse.find do |candidate|
        candidate.includes?(IYI_LINK_OBJECTS) && candidate.includes?(IYI_LINK_OUTPUT)
      end
      return nil unless line

      arguments = Process.parse_arguments(line.strip)
      return nil if arguments.size < 3

      linker = "ld"
      kept = [] of String
      skip_next = false
      arguments.each_with_index do |argument, index|
        next if index.zero?
        if skip_next
          skip_next = false
          next
        end
        case argument
        when "-plugin"
          skip_next = true
        when .starts_with?("-plugin-opt=")
          # the driver's, not the link's
        when .starts_with?("-fuse-ld=")
          named = "ld.#{argument.lchop("-fuse-ld=")}"
          return nil unless Process.find_executable(named)
          linker = named
        else
          kept << argument
        end
      end

      objects_at = kept.index(IYI_LINK_OBJECTS)
      return nil unless objects_at
      return nil unless Process.find_executable(linker)

      before = kept[0, objects_at].map { |argument| Process.quote_posix(argument) }.join(' ')
      after = kept[(objects_at + 1)..].map { |argument| Process.quote_posix(argument) }.join(' ')
      {linker, before, after}
    end

    # Records that the template does not work here, so the next build does not
    # try it. Called after a direct link failed and the driver succeeded.
    private def iyi_disable_direct_link(link_flags, lib_flags) : Nil
      key = ::Crystal::Digest::MD5.hexdigest(
        "#{DEFAULT_LINKER}\n#{link_flags}\n#{lib_flags}\n#{codegen_target}\n1")
      # An empty fingerprint, which is what a template with no inputs has: the
      # reader computes the same for this file and so believes it.
      File.write(CacheDir.instance.join("link-template-#{key}"), "#{key}\n\nunusable") rescue nil
      @iyi_direct_link = false
      @iyi_link_driver_only = true
    end

    # Tests if `mold` or `lld` are available and prefers them as linkers over
    # the default `ld`. Only works when `cc` is the linker driver and can be
    # disabled with `--link-flags=-fuse-ld=bfd`.
    private def use_modern_linker(link_flags)
      return link_flags unless DEFAULT_LINKER == "cc"
      return link_flags if link_flags.includes?("-fuse-ld=")

      flag = modern_linker_flag
      flag.empty? ? link_flags : link_flags + " " + flag
    end

    # iyi: which of `mold` and `lld` this machine has, asked once per `PATH`
    # rather than once per build.
    #
    # `Process.find_executable` walks `PATH`, and a name that is *not* there
    # costs a stat in every entry of it. That is a millisecond on an ordinary
    # Linux box and it is not one under WSL, where `PATH` carries the Windows
    # directories and a stat across that filesystem takes about 6 ms: measured
    # here, 0.062 s to fail to find `mold` and the same again to fail to find
    # `ld.lld`. Two searches, every build, on a warm build whose whole figure
    # is 0.30 s — **a third of it went looking for linkers nobody installed**,
    # and it was invisible because passing any `-fuse-ld=` skips this and made
    # the alternative look like the faster linker.
    #
    # The answer is written next to the object cache and read back while the
    # `PATH` it was found under is unchanged. Changing `PATH` re-asks, which is
    # what installing one of these usually does; installing one *into* a
    # directory already on `PATH` does not, and the escape hatches are
    # `--link-flags=-fuse-ld=mold` and deleting the file.
    private def modern_linker_flag : String
      path = ENV["PATH"]? || ""
      key = ::Crystal::Digest::MD5.hexdigest(path)
      cache = CacheDir.instance.join("linker-probe")

      if remembered = File.file?(cache) ? File.read(cache).split('\n', 2) : nil
        return remembered[1]? || "" if remembered[0]? == key
      end

      answer =
        if Process.find_executable("mold")
          "-fuse-ld=mold"
        elsif Process.find_executable("ld.lld")
          "-fuse-ld=lld"
        else
          ""
        end

      # Written and then renamed, because builds share a cache directory and a
      # half-written answer read by another one is a build linked with
      # something nobody chose. A cache that cannot be written at all is a slow
      # build rather than a failed one, which is the right way round for
      # something nobody asked for.
      begin
        staging = "#{cache}.#{Process.pid}"
        File.write(staging, "#{key}\n#{answer}")
        File.rename(staging, cache)
      rescue
      end

      answer
    end

    private GCC_RESPONSE_FILE_TR = {
      " ":  %q(\ ),
      "'":  %q(\'),
      "\"": %q(\"),
      "\\": "\\\\",
    }

    # iyi: linker flags may run `` `command` ``. Compiled once here, not per
    # call, and through Iyi::Rx, the compiler's own engine, so this file is
    # not one of the reasons pcre2 stays on the link line (SPEC.md III.10).
    private BACKTICK_SUBCOMMAND = Rx::Pattern.compile("`(.*?)`")

    private def expand_lib_flags(lib_flags)
      Rx.gsub(lib_flags, BACKTICK_SUBCOMMAND) do |match|
        # The group sits between the two backticks, so it always participated.
        command = match[1].not_nil!
        begin
          error_io = IO::Memory.new
          output = Process.run(command, shell: true, output: :pipe, error: error_io) do |process|
            process.output.gets_to_end
          end
          unless $?.success?
            error_io.rewind
            raise CompilerError.new("Error executing subcommand for linker flags: #{command.inspect}: #{error_io}", :FAILURE)
          end
          output.chomp
        rescue exc
          raise CompilerError.new("Error executing subcommand for linker flags: #{command.inspect}: #{exc}", :FAILURE)
        end
      end
    end

    private def codegen(program, units : Array(CompilationUnit), output_filename, output_dir)
      object_names = units.map &.object_filename
      object_names.concat write_iyi_artifact_objects(program, output_dir)

      @progress_tracker.stage("Codegen (bc+obj)") do
        @progress_tracker.stage_progress_total = units.size

        n_threads = @n_threads.clamp(1..units.size)

        if n_threads == 1
          sequential_codegen(units)
        else
          parallel_codegen(units, n_threads)
        end

        if units.size == 1
          units.first.emit(@emit_targets, emit_base_filename || output_filename)
        end
      end

      # We check again because maybe this directory was created in between (maybe with a macro run)
      if Dir.exists?(output_filename)
        raise CompilerError.new("can't use `#{output_filename}` as output filename because it's a directory", :USAGE_ERROR)
      end

      output_filename = File.expand_path(output_filename)

      # iyi: a build that exists to fill a boundary does not link.
      #
      # The keep file is not a program anybody runs — it is there so codegen
      # emits the methods a consumer will call, and what the boundary needs is
      # the objects rather than the executable they would have gone into.
      # Linking them is waste when it works and worse when it does not: forcing
      # the whole of `IO`'s surface produces a program that will not link, on
      # `Crystal::EventLoop::Polling` internals a demand-driven build never
      # reaches — and the units are written after the link, so a boundary that
      # had everything it needed got nothing.
      if emit_bind && iyi_keep
        @progress_tracker.clear
        return units
      end

      @progress_tracker.stage("Codegen (linking)") do
        Dir.cd(output_dir) do
          begin
            run_linker *linker_command(program, object_names, output_filename, output_dir, expand: true)
          rescue ex : CompilerError
            # A link the compiler built itself, on a machine where that does
            # not work: the driver is asked to do it instead and the template
            # is marked unusable, so this is paid once rather than every build.
            raise ex unless @iyi_direct_link
            iyi_disable_direct_link(@link_flags || "", program.lib_flags(@cross_compile))
            run_linker *linker_command(program, object_names, output_filename, output_dir, expand: true)
          end
        end
      end

      units
    end

    # iyi: unpacks the object files imported artifacts carried, into the same
    # directory the build's own units go to, and returns their names for the
    # link (SPEC.md IV.1g).
    #
    # Written out rather than handed to the linker from memory because a linker
    # takes paths. They are named after the module and the unit so that two
    # modules carrying a unit for the same type — which cannot happen under
    # R-3, and which a corrupt or hand-made artifact could still ask for —
    # collide as two files rather than as one silently overwritten.
    private def write_iyi_artifact_objects(program, output_dir) : Array(String)
      names = [] of String
      extension = codegen_target.object_extension

      program.iyi_artifact_objects.each do |module_name, units|
        units.each do |unit|
          name = "iyimod-#{safe_object_name(module_name)}-#{safe_object_name(unit.name)}#{extension}"
          path = File.join(output_dir, name)

          # Only when it is not already there. This runs on every build, and
          # the file it writes is a copy of bytes that came out of an artifact
          # whose hash the build already checked — so the second build of an
          # unchanged program was writing the module's machine code out again
          # to link exactly what it linked last time. Measured on the Kemal
          # port: a warm build from artifacts was 10% slower than the same
          # build from source, and this was the difference.
          #
          # Sized first because a size that differs settles it without reading,
          # and the bytes after that because a truncated or half-written copy
          # from a killed build has to be replaced rather than linked.
          info = File.info?(path)
          same = info && info.size == unit.code.size &&
                 File.open(path, "rb", &.getb_to_end) == unit.code
          File.write(path, unit.code) unless same

          names << name
        end
      end

      names
    end

    # A module path or a type name as a filename. Neither is one — `app/greeter`
    # has a separator in it and `List(Int32)` has parentheses — and the point is
    # only that two different names cannot produce one file.
    private def safe_object_name(name : String) : String
      # iyi: the `gsub(/[^A-Za-z0-9_]/)` written out, char by char — same map
      # (`A-Za-z0-9_` kept, anything else `-<ord>`, non-ASCII included), but
      # no regex engine behind it (zero-dep).
      String.build do |io|
        name.each_char do |char|
          if char == '_' || char.ascii_alphanumeric?
            io << char
          else
            io << '-' << char.ord
          end
        end
      end
    end

    private def sequential_codegen(units)
      units.each do |unit|
        unit.compile
        @progress_tracker.stage_progress += 1
      end
    end

    private def parallel_codegen(units, n_threads)
      {% if !flag?(:without_mt) %}
        raise "LLVM isn't multithreaded and cannot fork compiler in multithread mode." unless LLVM.multithreaded?
        mt_codegen(units, n_threads)
      {% else %}
        sequential_codegen(units)
      {% end %}
    end

    private def mt_codegen(units, n_threads)
      channel = Channel(CompilationUnit).new(n_threads * 2)
      wg = WaitGroup.new
      mutex = Sync::Mutex.new

      # iyi: kept, and raised after the workers are done.
      #
      # An exception in a spawned fiber prints itself and takes the fiber down,
      # and the build carried on to the link — which then reported the object
      # files nobody had written as the linker failing to find them. That is a
      # codegen failure told as a link failure, and it cost an hour of reading
      # linker output. The forking path already reports its workers' failures;
      # this is the same, for the threads.
      failure = nil.as(Exception?)

      n_threads.times do
        wg.spawn do
          while unit = channel.receive?
            begin
              unit.compile(isolate_context: true)
            rescue ex
              # Kept receiving rather than returning: a worker that stops
              # leaves the sender blocked on a channel nobody drains.
              mutex.synchronize { failure ||= ex }
              next
            end
            mutex.synchronize { @progress_tracker.stage_progress += 1 }
          end
        end
      end

      units.each do |unit|
        # We generate the bitcode in the main thread because LLVM contexts
        # must be unique per compilation unit, but we share different contexts
        # across many modules (or rely on the global context); trying to
        # codegen in parallel would segfault!
        #
        # Luckily generating the bitcode is quick and once the bitcode is
        # generated we don't need the global LLVM contexts anymore but can
        # parse the bitcode in an isolated context and we can parallelize the
        # slowest part: the optimization pass & compiling the object file.
        unit.generate_bitcode

        channel.send(unit)
      end
      channel.close

      wg.wait

      if ex = failure
        raise CompilerError.new("a codegen thread failed: #{ex.message} (#{ex.class})")
      end
    end

    private def print_macro_run_stats(program)
      return unless @progress_tracker.stats?
      return if program.compiled_macros_cache.empty?

      puts
      puts "Macro runs:"
      program.compiled_macros_cache.each do |filename, compiled_macro_run|
        print " - "
        print filename
        print ": "
        if compiled_macro_run.reused
          print "reused previous compilation (#{compiled_macro_run.elapsed})"
        else
          print compiled_macro_run.elapsed
        end
        puts
      end
    end

    private def print_codegen_stats(units)
      return unless @progress_tracker.stats?
      return unless units

      reused = units.count(&.reused_previous_compilation?)

      puts
      puts "Codegen (bc+obj):"
      case reused
      when units.size
        puts " - all previous .o files were reused"
      when .zero?
        puts " - no previous .o files were reused"
      else
        puts " - #{reused}/#{units.size} .o files were reused"
        puts
        puts "These modules were not reused:"
        units.each do |unit|
          next if unit.reused_previous_compilation?
          puts " - #{unit.original_name} (#{unit.name}.bc)"
        end
      end
    end

    getter(target_machine : LLVM::TargetMachine) do
      create_target_machine
    end

    def create_target_machine
      @codegen_target.to_target_machine(@mcpu || "", @mattr || "", @optimization_mode, @mcmodel)
    rescue ex : ArgumentError
      stderr.print colorize("Error: ").red.bold
      stderr.print "llc: "
      stderr.puts ex.message
      exit 1
    end

    {% if LibLLVM::IS_LT_170 %}
      property! pass_manager_builder : LLVM::PassManagerBuilder

      private def init_llvm_legacy_pass_manager
        registry = LLVM::PassRegistry.instance
        registry.initialize_all

        builder = LLVM::PassManagerBuilder.new
        builder.size_level = 0

        case optimization_mode
        in .o3?
          builder.opt_level = 3
          builder.use_inliner_with_threshold = 275
        in .o2?
          builder.opt_level = 2
          builder.use_inliner_with_threshold = 275
        in .o1?
          builder.opt_level = 1
          builder.use_inliner_with_threshold = 150
        in .o0?
          # default behaviour, no optimizations
        in .os?
          builder.opt_level = 2
          builder.size_level = 1
          builder.use_inliner_with_threshold = 50
        in .oz?
          builder.opt_level = 2
          builder.size_level = 2
          builder.use_inliner_with_threshold = 5
        end

        @pass_manager_builder = builder
      end

      private def optimize_with_pass_manager(llvm_mod)
        fun_pass_manager = llvm_mod.new_function_pass_manager
        pass_manager_builder.populate fun_pass_manager
        fun_pass_manager.run llvm_mod

        module_pass_manager = LLVM::ModulePassManager.new
        pass_manager_builder.populate module_pass_manager
        module_pass_manager.run llvm_mod
      end
    {% end %}

    protected def optimize(llvm_mod, target_machine)
      {% if LibLLVM::IS_LT_130 %}
        optimize_with_pass_manager(llvm_mod)
      {% else %}
        optimization_mode = @optimization_mode
        optimization_mode = OptimizationMode::O2 if optimization_mode.os? || optimization_mode.oz?

        LLVM::PassBuilderOptions.new do |options|
          LLVM.run_passes(llvm_mod, "default<#{optimization_mode}>", target_machine, options)
        end
      {% end %}
    end

    private def run_linker(linker_name, command, args)
      print_command(command, args) if verbose?

      begin
        Process.run(command, args, shell: true,
          input: Process::Redirect::Close, output: Process::Redirect::Inherit, error: Process::Redirect::Pipe) do |process|
          process.error.each_line(chomp: false) do |line|
            # iyi: the three `gsub(/... -l(\S+)\b/, "... \\1 hint")` rewrites,
            # by hand — the compiler's own code must not be what links pcre2
            # (zero-dep). A matching line gets the same hint; any other line
            # passes through unchanged, byte for byte.
            line = linker_library_hint(line, "cannot find -l")
            line = linker_library_hint(line, "unable to find library -l")
            line = linker_library_hint(line, "library not found for -l")
            STDERR << line
          end
        end
      rescue exc : File::AccessDeniedError | File::NotFoundError
        linker_not_found exc.class, linker_name
      end

      status = $?
      unless status.success?
        exit_code = status.exit_code?
        case exit_code
        when 126
          linker_not_found File::AccessDeniedError, linker_name
        when 127
          linker_not_found File::NotFoundError, linker_name
        when nil
          # abnormal exit
          exit_code = 1
        end
        raise CompilerError.new("execution of command failed with exit status #{status}: #{command}", status: exit_code)
      end
    end

    # Appends the "install the development package" hint to linker errors of
    # the form `#{marker}NAME` (`cannot find -lfoo` and friends). The regex
    # this replaces read `#{marker}(\S+)\b`: NAME is the longest non-blank run
    # after the marker that ends on a word boundary — `-lfoo!` hints about
    # `foo` — and a line without such a match is returned unchanged.
    private def linker_library_hint(line : String, marker : String) : String
      io = IO::Memory.new
      copied = 0
      search = 0
      while found = line.index(marker, search)
        tail = line[found + marker.size..]
        run_end = 0
        while (char = tail[run_end]?) && !char.whitespace?
          run_end += 1
        end

        # \b trims the run from the right until its last char sits on a word
        # boundary, exactly the greedy capture's own backtracking
        name_end = run_end
        while name_end > 0 && !word_boundary?(tail, name_end)
          name_end -= 1
        end

        if name_end > 0
          name = tail[0, name_end]
          hint = colorize("(this usually means you need to install the development package for lib#{name})").yellow.bold
          io << line[copied...found] << marker << name << ' ' << hint
          copied = search = found + marker.size + name_end
        else
          search = found + 1
        end
      end
      io << line[copied..]
      io.to_s
    end

    # `\b` between `string[name_end - 1]` and `string[name_end]?` (end of
    # string reads as non-word): a boundary iff exactly one side is a word
    # character. The regex ran UCP, where word chars are Unicode letters,
    # digits and `_` — `Char#alphanumeric?` plus `_`.
    private def word_boundary?(string : String, name_end : Int) : Bool
      before = word_char?(string[name_end - 1])
      after = string[name_end]?
      before != (after ? word_char?(after) : false)
    end

    private def word_char?(char : Char) : Bool
      char.alphanumeric? || char == '_'
    end

    private def linker_not_found(exc_class, linker_name)
      verbose_info = "\nRun with `--verbose` to print the full linker command." unless verbose?
      case exc_class
      when File::AccessDeniedError
        raise CompilerError.new("Could not execute linker: `#{linker_name}`: Permission denied#{verbose_info}", :FAILURE)
      else
        raise CompilerError.new("Could not execute linker: `#{linker_name}`: File not found#{verbose_info}", :FAILURE)
      end
    end

    # iyi: `color?` says whether the *caller* wants colour; this says whether
    # anything can read it. The three error paths that print through here —
    # a source file that is not text, a missing linker, a missing library —
    # colourised whatever they were writing into, so `iyi check` down a pipe
    # answered `\e[31;1mError: \e[39;22m…`, and those bytes reached a JSON
    # payload an agent parses (`iyi mcp`'s tool results) and every log a
    # redirect keeps. The `CodeError` path one screen up has consulted
    # `Colorize.default_enabled?` all along; this is the same question,
    # asked of the streams this compiler was actually given.
    private def colorize(obj)
      obj.colorize.toggle(@color && Colorize.default_enabled?(stdout, stderr))
    end

    # An LLVM::Module with information to compile it.
    class CompilationUnit
      getter compiler
      getter name
      getter original_name
      getter llvm_mod
      property? reused_previous_compilation = false
      getter object_extension : String
      @memory_buffer : LLVM::MemoryBuffer?
      @object_name : String?
      @bc_name : String?

      def initialize(@compiler : Compiler, program : Program, @name : String,
                     @llvm_mod : LLVM::Module, @output_dir : String, @bc_flags_changed : Bool)
        @name = "_main" if @name == ""
        @original_name = @name
        @name = String.build do |str|
          @name.each_char do |char|
            case char
            when 'a'..'z', '0'..'9', '_'
              str << char
            when 'A'..'Z'
              # Because OSX has case insensitive filenames, try to avoid
              # clash of 'a' and 'A' by using 'A-' for 'A'.
              str << char << '-'
            else
              str << char.ord
            end
          end
        end

        if @name.size > 50
          # 17 chars from name + 1 (dash) + 32 (md5) = 50
          @name = "#{@name[0..16]}-#{::Crystal::Digest::MD5.hexdigest(@name)}"
        end

        @name = "#{@name}#{@compiler.optimization_mode.suffix}"
        @object_extension = compiler.codegen_target.object_extension
      end

      def generate_bitcode
        @memory_buffer ||= llvm_mod.write_bitcode_to_memory_buffer
      end

      # To compile a file we first generate a `.bc` file and then create an
      # object file from it. These `.bc` files are stored in the cache
      # directory.
      #
      # On a next compilation of the same project, and if the compile flags
      # didn't change (a combination of the target triple, mcpu and link flags,
      # amongst others), we check if the new `.bc` file is exactly the same as
      # the old one. In that case the `.o` file will also be the same, so we
      # simply reuse the old one. Generating an `.o` file is what takes most
      # time.
      #
      # However, instead of directly generating the final `.o` file from the
      # `.bc` file, we generate it to a temporary name (`.o.tmp`) and then we
      # rename that file to `.o`. We do this because the compiler could be
      # interrupted while the `.o` file is being generated, leading to a
      # corrupted file that later would cause compilation issues. Moving a file
      # is an atomic operation so no corrupted `.o` file should be generated.
      def compile(isolate_context = false)
        if must_compile?
          isolate_module_context if isolate_context
          update_bitcode_cache
          compile_to_object
        else
          @reused_previous_compilation = true
        end
        dump_llvm_ir
      end

      private def must_compile?
        memory_buffer = generate_bitcode

        return true unless compiler.emit_targets.none?
        return true if @bc_flags_changed
        return true unless File.exists?(bc_name)
        return true unless File.exists?(object_name)

        # If the user cancelled a previous compilation
        # it might be that the .o file is empty
        return true if File.size(object_name) == 0

        # iyi: or that it is short, or that it is not an object at all.
        # The line above guards the one corruption this cache was known
        # to produce; the cache produces others. A directory deleted
        # mid-codegen by another build's cleanup (see
        # `CacheDir#directory_in_use?`, which exists because that
        # happened), a full disk, a killed process between `emit_obj` and
        # `File.rename` - each leaves bytes that are not an object, and
        # every later build linked them: `ld.lld: error: <file>:1:
        # unknown directive: garbage`, forever, until somebody thought to
        # run `clear_cache`. A cache is a cache. Anything in it that we
        # did not write is a miss.
        unless object_file_intact?
          STDERR.puts "#{Iyi::Command.program_name}: #{object_name} was in the cache but is not an object file; compiling it again"
          STDERR.flush
          return true
        end

        memory_io = IO::Memory.new(memory_buffer.to_slice)

        changed = File.open(bc_name) { |bc_file| !IO.same_content?(bc_file, memory_io) }

        memory_buffer.dispose unless changed

        changed
      end

      # Parse the previously generated bitcode into the LLVM module using a
      # dedicated context, so we can safely optimize & compile the module in
      # multiple threads (llvm contexts can't be shared across threads).
      private def isolate_module_context
        @llvm_mod = LLVM::Module.parse(@memory_buffer.not_nil!, LLVM::Context.new)
      end

      private def update_bitcode_cache
        return unless memory_buffer = @memory_buffer

        # Delete existing .o file. It cannot be used anymore.
        File.delete?(object_name)
        # Create the .bc file (for next compilations)
        File.write(bc_name, memory_buffer.to_slice)
        memory_buffer.dispose
      end

      private def compile_to_object
        temporary_object_name = self.temporary_object_name
        target_machine = compiler.create_target_machine
        compiler.optimize llvm_mod, target_machine unless compiler.optimization_mode.o0?
        target_machine.emit_obj_to_file llvm_mod, temporary_object_name
        File.rename(temporary_object_name, object_name)
      rescue ex
        # iyi: name the file. LLVM reports "No such file or directory" and
        # nothing else, which says neither which file nor which of the two
        # steps above, and that is an hour of somebody's evening.
        raise CompilerError.new(
          "#{ex.message} while writing #{temporary_object_name} for unit #{@name}")
      end

      private def dump_llvm_ir
        llvm_mod.print_to_file ll_name if compiler.dump_ll?
      end

      def emit(emit_targets : EmitTarget, output_filename)
        if emit_targets.asm?
          compiler.target_machine.emit_asm_to_file llvm_mod, "#{output_filename}.s"
        end
        if emit_targets.llvm_bc?
          FileUtils.cp(bc_name, "#{output_filename}.bc")
        end
        if emit_targets.llvm_ir?
          llvm_mod.print_to_file "#{output_filename}.ll"
        end
        if emit_targets.obj?
          FileUtils.cp(object_name, output_filename + @object_extension)
        end
      end

      def object_name
        Iyi.relative_filename("#{@output_dir}/#{object_filename}")
      end

      def object_filename
        @name + @object_extension
      end

      def temporary_object_name
        Iyi.relative_filename("#{@output_dir}/#{object_filename}.tmp")
      end

      # Four bytes: whether what the cache holds under `object_name` has
      # the shape of an object file for this target. Formats whose first
      # bytes are not a fixed magic - COFF opens with a machine number -
      # are judged by the size rule above and nothing more, because a
      # guess that refuses a good object would recompile the world on
      # every build.
      private def object_file_intact? : Bool
        header = Bytes.new(4)
        # `read_fully?` rather than `read`, which is allowed to answer with
        # fewer bytes than it was asked for: a short read is not a verdict
        # about the four bytes, and the four bytes are the question.
        return false unless File.open(object_name, "rb") { |file| file.read_fully?(header) }

        target = compiler.codegen_target
        if target.macos?
          # Mach-O, thin or fat, either endianness.
          {0xfeedfacf_u32, 0xcffaedfe_u32,
           0xfeedface_u32, 0xcefaedfe_u32,
           0xcafebabe_u32, 0xbebafeca_u32}
            .includes?(IO::ByteFormat::BigEndian.decode(UInt32, header))
        elsif target.architecture == "wasm32"
          header == "\0asm".to_slice
        elsif target.windows?
          true
        else
          header == "\x7fELF".to_slice
        end
      rescue File::Error
        false
      end

      def bc_name
        "#{@output_dir}/#{@name}.bc"
      end

      def bc_name_new
        "#{@output_dir}/#{@name}.new.bc"
      end

      def ll_name
        "#{@output_dir}/#{@name}.ll"
      end
    end
  end
end
