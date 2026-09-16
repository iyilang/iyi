# iyi: a front-end build links no LLVM, because linking it costs 0.026 s of
# load-time initialisers whether or not anything generates code — see
# `llvm_shim.cr`.
{% if flag?(:without_llvm) %}
  require "./llvm_shim"
{% else %}
  require "llvm"
{% end %}
require "json"
require "./types"
require "crystal/digest/md5"

module Iyi
  # A program contains all types and top-level methods related to one
  # compilation of a program.
  #
  # It also carries around all information needed to compile a bunch
  # of files: the unions, the symbols used, all global variables,
  # all required files, etc. Because of this, a Program is usually passed
  # around in every step of a compilation to record and query this information.
  #
  # In a way, a Program is an alternative implementation to having global variables
  # for all of this data, but modeled this way one can easily test and exercise
  # programs because each one has its own definition of the types created,
  # methods instantiated, etc.
  #
  # Additionally, a Program acts as a regular type (a module) that can have
  # types (the top-level types) and methods (the top-level methods), and which
  # can also include other modules (this happens when you do `include Module`
  # at the top-level).
  class Program < NonGenericModuleType
    include DefInstanceContainer

    # All symbols (:foo, :bar) found in the program
    getter symbols = Set(String).new

    # Hash that prevents recursive splat expansions. For example:
    #
    # ```
    # def foo(*x)
    #   foo(x)
    # end
    #
    # foo(1)
    # ```
    #
    # Here x will be {Int32}, then {{Int32}}, etc.
    #
    # The way we detect this is by remembering the types of the splat,
    # associated to a def's object id (the UInt64), and on an instantiation
    # we compare the new type with the previous ones and check if they all
    # contain each other once the method is invoked a number of times recursively
    # (currently 5 times or more).
    getter splat_expansions : Hash(Def, Array(Type)) = ({} of Def => Array(Type)).compare_by_identity

    # All FileModules indexed by their filename.
    # These store file-private defs, and top-level variables in files other
    # than the main file.
    getter file_modules = {} of String => FileModule

    # Types that have instance vars initializers which need to be visited
    # (transformed) by `CleanupTransformer` once the semantic analysis finishes.
    #
    # TODO: this probably isn't needed and we can just traverse all types at the
    # end, and analyze all instance variables initializers that we found. This
    # should simplify a bit of code.
    getter after_inference_types = Set(Type).new

    # Top-level variables found in a program (only in the main file).
    getter vars = MetaVars.new

    # If `true`, doc comments are attached to types and methods.
    property? wants_doc = false

    # If `true`, error messages can be colorized
    property? color = true

    # All required files. The set stores absolute files. This way
    # files loaded by `require` nodes are only processed once.
    getter requires = Set(String).new

    # iyi: the imported modules of the program, in the order their initialisers
    # must run (SPEC.md III.5 rule 1).
    #
    # `import` fills this rather than expanding the module where it was
    # written, so a module's top-level code is held apart from the site that
    # imported it and the compiler is the one that decides when it runs.
    # `top_level_semantic` empties it into the tree.
    property iyi_module_inits = [] of ASTNode

    # iyi: the files whose module has runnable code the artifact **cannot**
    # carry, by absolute filename (SPEC.md III.5, IV.1g).
    #
    # A module's own top level travels (see `iyi_module_initialiser_source`).
    # A class variable's initialiser does not: it belongs to the type rather
    # than to the module, and nothing in the artifact holds it. A codegen build
    # reading such an artifact is refused rather than given a module that half
    # sets itself up.
    getter iyi_module_initialisers = Set(String).new

    # iyi: each module's own top-level code as source text, by absolute
    # filename (SPEC.md III.5, IV.1g).
    #
    # `iyi_module_inits` holds the nodes and is emptied into the tree by the
    # top-level pass; this survives it, because an artifact is written later
    # and the initialiser is the one part of a module that is not a
    # declaration and has to run anyway. The consumer parses it back into the
    # module's own namespace and it takes its place in III.5's DAG order like
    # any other module's, because that order is over modules and not over text.
    getter iyi_module_initialiser_source = {} of String => String

    # iyi: which modules each file imports, by absolute filename (SPEC.md
    # III.5 rule 2). `iyi_module_inits` is one order the DAG allows; these are
    # the edges, which is what makes every *other* order it allows computable.
    getter iyi_module_imports = {} of String => Array(String)

    # iyi: the subset of the edges above that were written `pub import` —
    # importing file => the files it re-exports. `using`'s reachability
    # walk follows ordinary edges one step and these edges any depth: a
    # facade may hand its dependencies on, a private import may not.
    getter iyi_exported_imports = {} of String => Set(String)

    # iyi: every file that arrived through an `import` edge, source or
    # artifact — the set the qualified-name wall consults: a unit in no
    # edge exists because the current source declared it, and a file
    # always reaches what it wrote.
    getter iyi_imported_files = Set(String).new

    @iyi_reach_cache = {} of String => Set(String)

    # The import wall for a qualified name (SPEC.md R-1): `resolved`
    # lives in an imported unit ⇒ the file that wrote `node` must reach
    # that unit — its own imports, then onward only through `pub import`
    # edges. Anchored at the node, which is the line to fix.
    def iyi_check_import_reach(node : ASTNode, resolved : Type) : Nil
      unit = iyi_walled_unit?(node.location, resolved)
      return unless unit

      node.raise "`#{unit}` is not imported here — it is in the program " \
                 "only because some other file imported it. Add an import " \
                 "in this file, or have a module this file imports " \
                 "re-export it with `pub import` (SPEC.md R-1)"
    end

    # The wall as a question: the unit `resolved` lives in, when the file
    # that wrote `location` does not reach it; nil when the name is free
    # to be used. Constant lookup asks it while walking enclosing
    # namespaces, so that a sibling module namespace this file never
    # imported (`Std::Tuple` seen from `Std::Enumerable`) does not hide
    # the prelude's `::Tuple` — a unit the file cannot name is not in
    # scope, and lexical lookup goes on outward.
    def iyi_walled_unit?(location : Location?, resolved : Type) : NamedType?
      # iyi's law, not Crystal's: a `--crystal` build consumes bound
      # shards whose signatures name each other's types transitively —
      # that world keeps Crystal's rules, which is the mode's whole
      # contract. The CI bind chain (kemal over backtracer) is the case
      # that taught it.
      return unless iyi_prelude?

      base = resolved
      base = base.generic_type if base.is_a?(GenericClassInstanceType)
      unit = base
      while unit
        break if unit.is_a?(NamedType) && unit.iyi_unit?
        unit =
          if unit.is_a?(NamedType) && (namespace = unit.namespace) != unit
            namespace
          else
            nil
          end
      end
      return unless unit.is_a?(NamedType)

      unit_file = unit.locations.try(&.first?).try(&.filename).as?(String)
      return unless unit_file && iyi_imported_files.includes?(unit_file)

      writer = location.try(&.filename).as?(String)
      return unless writer
      return if writer == unit_file
      # Only writers this build read as files: the entry and everything
      # imported (artifact declaration replays included — their path is
      # an edge value). A mono body or initialiser replayed out of an
      # artifact carries its *far machine's* source path; it was checked
      # when its own module built, and refusing it here would sanction
      # code nobody on this machine wrote.
      return unless writer == filename || iyi_imported_files.includes?(writer)
      return if iyi_reachable_files(writer).includes?(unit_file)

      unit
    end

    # The files reachable from `from`: every direct import, then onward
    # only through `pub import` edges. Cached only once the top-level
    # pass is complete — before that the edge lists are still growing
    # and a cached answer would be a stale refusal.
    private def iyi_reachable_files(from : String) : Set(String)
      if top_level_semantic_complete? && (cached = @iyi_reach_cache[from]?)
        return cached
      end
      reachable = Set(String).new
      queue = (iyi_module_imports[from]? || [] of String).dup
      while file = queue.pop?
        next unless reachable.add?(file)
        iyi_exported_imports[file]?.try &.each { |handed| queue << handed }
      end
      @iyi_reach_cache[from] = reachable if top_level_semantic_complete?
      reachable
    end

    # iyi: the module path each imported file was named by, e.g.
    # `/…/app/greeter.iyi => "app/greeter"`. The edges above are keyed on
    # filenames because that is what load-once is keyed on; a `.iyimod` names
    # modules, so it needs the way back (SPEC.md IV.1).
    getter iyi_module_paths = {} of String => String

    # iyi: the same, for a module that arrived as an artifact — keyed by the
    # `.iyimod`'s own path (SPEC.md IV.1).
    #
    # Two hashes rather than one because they answer different questions.
    # `iyi_module_paths` is the set `--emit-iyimod` writes from, and a module
    # read from a `.iyimod` must not be in it: it already has an artifact and
    # this build has not seen enough of it to write another. But the import
    # edges are keyed on filenames whichever way the module arrived, so naming
    # those edges needs the way back for both — without this, an artifact's
    # `Imports` section records `mods/std/list.iyimod` where it means
    # `std/list`.
    getter iyi_artifact_modules = {} of String => String

    # iyi: true only while a `derive`'s macro is expanding (SPEC.md R-5, II.4).
    # A derive reads the declaration it is attached to, and the types that
    # declaration names. The macro questions that answer with the whole program
    # instead are refused while this is set, because their answers are not facts
    # a module's artifact can carry.
    property? expanding_derive : Bool = false

    # iyi: where to look for a `.iyimod` before falling back to a module's
    # source, or nil (SPEC.md IV.1). Set by `--use-iyimod`.
    property iyi_module_dir : String? = nil

    # iyi: the manifest's answer — `{module path prefix, checkout dir}`,
    # longest prefix first, filled from `iyi.mod` by `Mod::Installer` before
    # semantic runs (SPEC.md III.7). Empty when the program has no manifest,
    # which is every program until it writes one.
    property iyi_mod_table = [] of {String, String}

    # iyi: editor buffers, keyed by the absolute path the file would have —
    # `iyi lsp` compiles what the person sees, saved or not. Consulted in
    # exactly two places: `resolve_import` counts an overridden path as
    # existing, and `import_file` reads the buffer instead of the disk.
    # Empty everywhere else, so a build costs one hash lookup per import.
    property iyi_file_overrides = {} of String => String

    # iyi: the project root, when a tool knows better than "the entry
    # file's directory". `iyi lsp` derives it from the file's own module
    # header — IV.6 read backwards: a file whose path ends with its
    # header's path names the root above both — so opening a nested
    # module resolves its imports the way a build from the root would.
    # Nil for every build a person runs; the entry-dir rule stands.
    property iyi_project_root : String? = nil

    # iyi: the root the entry's own header names (IV.6 read backwards),
    # tried after the entry's directory.
    property iyi_header_root : String? = nil

    # iyi: whether this build is writing artifacts as well as reading them
    # (SPEC.md IV.3). Set by the compiler from `--emit-iyimod`.
    #
    # It decides what a *stale* artifact means. A build that only reads them
    # asked to be compiled against artifacts, so one that no longer describes
    # its module is an error that names what changed — quietly compiling the
    # source instead would make such a build slower than it looks and prove
    # nothing. A build that also writes them is the incremental loop itself:
    # there, recompiling the module and rewriting its artifact is the whole
    # point.
    property iyi_rewrites_artifacts : Bool = false

    # iyi: what each module read from a `.iyimod` hashed to (SPEC.md IV.3), by
    # module path.
    #
    # Kept because an artifact this build *writes* records, for each module it
    # imports, what that module hashed to — and a dependency may itself have
    # arrived as an artifact rather than from source.
    getter iyi_artifact_hashes = {} of String => IyiMod::Hashes

    # iyi: why a module's artifact is not the module any more, or nil if it
    # still is (SPEC.md IV.3). Memoised, because the answer for one module is
    # part of the answer for everything that imports it.
    getter iyi_artifact_staleness = {} of String => String?

    # iyi: whether an imported artifact's `ObjectCode` is worth reading.
    #
    # False for a front-end-only build, which is most of them: the section is
    # the largest thing in the file and a build that generates no code has no
    # use for it, so it is seeked past. Set by the compiler from `--no-codegen`.
    property iyi_wants_object_code : Bool = false

    # iyi: the object files each imported artifact carried, by module path
    # (SPEC.md IV.1g). What the linker is given in place of the code this build
    # did not generate, because it never saw the bodies.
    getter iyi_artifact_objects = {} of String => Array(IyiMod::ObjectUnit)

    # iyi: types whose methods must be emitted as real functions because their
    # module's `.iyimod` is being written (SPEC.md IV.1g).
    #
    # Codegen inlines a method whose body is a literal and emits no symbol for
    # it. That is right for a whole-program build and wrong for a module that
    # somebody else will link against: the consumer has no body to inline and
    # calls the symbol, which the artifact then turns out not to define. Empty
    # unless `--emit-iyimod` asked for artifacts.
    getter iyi_exported_owners = Set(Type).new

    # iyi: true when this program was built against iyi's own prelude.
    #
    # `require` is refused in a `.iyi` file because there is no standard
    # library to require — and that reason stops being true the moment the
    # prelude is Crystal's. A program built `--crystal` has one, so a
    # `.iyi` file in it may reach a shard the way a `.cr` file does. The rules
    # that make a module a module are unaffected: they are the language's, and
    # the prelude is a library.
    property? iyi_prelude = true

    # iyi: true when building with `--crystal`, targeting Crystal's standard library and ABI.
    property? crystal_library = false

    # iyi: true when this program's runtime symbols are `__iyi_*`.
    #
    # The prelude decides, because the prelude is what defines them: iyi's
    # declares `__iyi_main`, `__iyi_raise` and the rest, Crystal's declares
    # `__crystal_*`. A `.iyi` entry built against Crystal's library (the
    # `.iyimod` specs do this without `--crystal`) has Crystal's runtime and
    # must call it by Crystal's names; the entry's extension says nothing
    # about which prelude was loaded, and deciding by it linked against
    # symbols the prelude did not have. The ground truth is the prelude
    # itself rather than the flag, as `iyi_object_layout?` reads it: a
    # spec-built snippet carries the default `iyi_prelude?` and requires
    # Crystal's prelude, or none. `IyiRuntimeLock` is iyi's prelude's, on
    # every target and under every mode.
    def iyi_abi? : Bool
      iyi_prelude? && !types?.try(&.[]?("IyiRuntimeLock")).nil?
    end

    def abi_prefix : String
      iyi_abi? ? "__iyi_" : "__crystal_"
    end

    def abi_name(suffix : String) : String
      "#{abi_prefix}#{suffix}"
    end

    def main_name
      abi_name("main")
    end

    def raise_name
      abi_name("raise")
    end

    def raise_overflow_name
      abi_name("raise_overflow")
    end

    def raise_cast_failed_name
      abi_name("raise_cast_failed")
    end

    def malloc_name
      abi_name("malloc64")
    end

    def malloc_atomic_name
      abi_name("malloc_atomic64")
    end

    def realloc_name
      abi_name("realloc64")
    end

    def get_exception_name
      abi_name("get_exception")
    end

    def once_init_name
      abi_name("once_init")
    end

    def once_name
      abi_name("once")
    end

    def type_id_to_class_name_map_name
      abi_name("type_id_to_class_name_map")
    end

    # iyi: the directory the prelude was loaded from, once it has been.
    #
    # Every prelude file sits beside `prelude.iyi`, so this is what tells a
    # def written in the prelude from a def written in a program or in an
    # `src/std/` module — the question R-3 asks before it refuses a
    # replacement (`TopLevelVisitor#iyi_refuse_override`). Nil under
    # `--crystal`, where the library is the other language's and the `.cr`
    # half of that rule answers instead.
    property iyi_prelude_dir : String? = nil

    # iyi: the types each object-code unit refers to a type id of, by unit name
    # (SPEC.md IV.1g).
    #
    # A type id is an external reference — the number is the program's, not the
    # module's — so a unit that travels in an artifact leaves `Array(Item):
    # type_id` undefined and the consumer's `_main` defines it. It can only
    # define ids for types it *has*, and `Array(Item)` exists in the producing
    # build because of a body that stays behind. So which ones a unit refers to
    # has to be collected here and carried, or the consumer has no way to know
    # the type was ever wanted. Empty unless `--emit-iyimod` asked for
    # artifacts.
    getter iyi_unit_type_ids = {} of String => Set(Type)

    # iyi: the constants each object-code unit reads, by unit name (SPEC.md
    # IV.1g).
    #
    # A constant is initialised only if something *read* it — `codegen_assign`
    # asks `const.used?` — and what reads a module's constant on the far side of
    # an artifact is the module's own machine code, which the consumer's
    # semantic pass never sees. So `kemal/dsl`'s unit called through
    # `Kemal::Dsl::APP` from every exported method and nothing defined it. The
    # names travel and the consumer marks them used, which puts them back on the
    # ordinary path: the initialiser is already spliced in III.5's order, so it
    # runs where it should. Empty unless `--emit-iyimod` asked for artifacts.
    getter iyi_unit_constants = {} of String => Set(Const)

    # iyi: the class variables each unit's object code refers to, by unit name
    # (SPEC.md IV.2).
    #
    # `iyi_unit_constants` above, asked of a global that nobody wrote a name
    # for. A class variable's global is defined in the *main module*, which is
    # the one part of a build that never travels, and the methods that read one
    # travel as this module's machine code referring to it by symbol. So
    # `App::Counter::Tally::seen` was a global nothing defined, and a module
    # with a `@@seen` failed R-1's own round trip.
    #
    # The declaration travelling is not enough on its own and that was measured:
    # `@@cache : String? = nil` has its initialiser dropped before this point —
    # a nil initialiser assigns nothing — so the consumer read the declaration,
    # made no initialiser out of it, and codegen never emitted the global. What
    # closes it is the consumer being told the name and declaring it, which is
    # what this carries.
    #
    # The `Bool` is *how* the unit refers to it: true when it calls
    # `~Owner::name:read`, the main-module function that initialises on first
    # use, false when it reads the global directly. The consumer owes exactly
    # the one that was emitted, and neither side can guess the other's — see
    # `iyi_record_unit_class_var`.
    #
    # Recorded only while writing artifacts, like the constants above.
    # Keyed by `Owner::@@name`, and the qualified name is the whole of it. This
    # was keyed by the variable itself, and `MetaTypeVar` is a `Var`, whose
    # equality is `def_equals_and_hash name` — its *name*, with nothing of its
    # owner in it. A class variable declared on a superclass is copied onto
    # every subclass that reads it, so `bindata`'s `@@bit_fields` is six
    # variables and one hash key: the unit `ASN1::BER` reads four of them and
    # the last write took the entry. The consumer was told about one, made one
    # read function, and the link ended on `undefined symbol:
    # ~ASN1::BER::bit_fields:read`.
    getter iyi_unit_class_vars = {} of String => Hash(String, Bool)

    # iyi: the types an imported artifact's object code refers to a type id of,
    # resolved (SPEC.md IV.1g).
    #
    # The consumer defines an id for every type it has *numbered*, and numbering
    # comes from walking `Object`'s subclasses — which reaches a class and does
    # not reach an enum. An enum gets its id from the first code that asks for
    # one, and nothing in a consumer's own program asks for
    # `Regex::MatchOptions`. So these are numbered explicitly, at codegen, from
    # the names the artifact carried.
    getter iyi_artifact_numbered_types = Set(Type).new

    # iyi: one name an imported artifact's object code refers to, waiting for
    # every import to be in before it is resolved (SPEC.md IV.1g).
    #
    # A type id is a *program-wide* question and was asked per import, which is
    # a stricter order than the thing it is asking about. `pg` declares `PG`
    # and `PQ`: `PG`'s signatures name `PQ::Field` and `PQ`'s object code
    # numbers `PG::Error`, so whichever of the two is read first names a type
    # the other has not declared yet - and no ordering of two boundaries fixes
    # it, because the dependency runs both ways while an import graph is a DAG
    # (R-1). Asked once, after the top-level pass has read every import, both
    # are ordinary names.
    #
    # *match* tells the two questions apart: a type id is numbered, a match
    # type has a function built for it, and the refusals read differently.
    record IyiArtifactRef,
      module_name : String,
      name : String,
      node : ASTNode,
      match : Bool

    getter iyi_artifact_refs = [] of IyiArtifactRef

    # iyi: the types each unit's object code asks `~match<T>` about, by unit
    # name (SPEC.md IV.1g).
    #
    # `iyi_unit_type_ids`' question asked of a *match*. A match against a union
    # or a virtual type is a comparison against a range of the program's own
    # type ids, so the function belongs to the program and the artifact carries
    # a name rather than a copy — a copy compiled by the producer would compare
    # the consumer's ids against the producer's numbers and answer wrongly with
    # no symptom.
    #
    # Recorded only while writing artifacts.
    getter iyi_unit_match_types = {} of String => Set(Type)

    # iyi: a def's body as it was written, by the location it was written at
    # (SPEC.md IV.1g).
    #
    # A body that travels has to be *source*, and the node a `Def` holds stops
    # being that as soon as anything instantiates it: `Route.new(method, path,
    # &handler)` becomes `_.initialize(method, path, &handler)`, and an
    # underscore is not a receiver anybody can write. Recorded in the top-level
    # pass, which runs before any of that, and only while a boundary is being
    # written.
    getter iyi_def_bodies = {} of String => String

    # iyi: the key one of those is stored under.
    #
    # The place and the name, which is what a `Def` and its declaration share —
    # and for a macro-written one the place is not a place. A `Location` whose
    # filename is a `VirtualFile` prints as `expanded macro: <name>`, with no
    # file and no line in it, so every def a macro of that name wrote collapses
    # to one key. `Log` has two `{% for %}` loops that write a `def info` each,
    # one on the instance and one on the class, and the second took the first's
    # body: the consumer read `Log#info` as `Top.info(…) { yield }`, which is
    # `Log#info` calling itself — `recursive block expansion: blocks that yield
    # are always inlined`.
    #
    # So a macro-written def is keyed on where the macro was *invoked*, which
    # is a real file and line, plus where it sits inside the expansion. Both
    # halves are needed: the first tells two macro calls apart and the second
    # tells two defs inside one expansion apart.
    def self.iyi_def_body_key(location : Location, name : String) : String
      return "#{location}##{name}" if location.filename.is_a?(String)

      site = location.expanded_location
      "#{site}|#{location.line_number}:#{location.column_number}##{name}"
    end

    # iyi: the symbols each unit's object code defines, by unit name (SPEC.md
    # IV.1g).
    #
    # An artifact defines more than it declares and less than its types
    # suggest. More, because its own units call methods from Crystal's library —
    # `RouteHandler`'s unit calls `FilterHandler#next=`, and `next=` is
    # `HTTP::Handler`'s. Less, because a method like `Reference::new` is
    # instantiated per receiver and exists only where something reached it.
    #
    # Every rule that tried to derive this from the shape of a def was wrong on
    # one side or the other: guessing "the artifact has it" left
    # `Kemal::FilterHandler@Reference::new` undefined, guessing the reverse made
    # it a duplicate, and compiling a private copy in the consumer put the
    # definition where `_main` could not see it. So the producer says what it
    # emitted.
    #
    # Recorded only while writing artifacts.
    getter iyi_unit_symbols = {} of String => Set(String)

    # iyi: the `lib`s a unit calls into, by name (SPEC.md IV.1g, `Libs`).
    #
    # Which C libraries a boundary's object code needs is the other half of
    # what `Requires` answers, and nothing was answering it. `link_annotations`
    # walks the program for a `LibType` that is `used?`, and used is a question
    # about this build's own code: the call to `yaml_parser_parse` is in the
    # artifact's `YAML::PullParser` unit, which the consumer did not compile.
    # So the consumer had the `lib` from a replayed `require "yaml"`, never
    # marked it, and never passed `-lyaml`.
    #
    # Recorded only while writing artifacts.
    getter iyi_unit_libs = {} of String => Set(String)

    # iyi: how deep `Call#instantiate` may recurse before it gives up, and how
    # deep it is now.
    #
    # Nil for every ordinary build. `tool bind` sets one because it asks a
    # question a shard's own compilation never asks — what does this method
    # answer, called on nothing in particular — and for some methods the answer
    # is that instantiating it does not terminate. A stack overflow is a signal
    # rather than an exception, so the tool's own `rescue` cannot see one; a
    # limit turns it into a refusal the tool already knows how to report.
    property iyi_instantiation_limit : Int32? = nil
    property iyi_instantiation_depth = 0

    # iyi: the `lib`s an imported artifact's object code calls into.
    #
    # The consumer's half. Marking one used is the whole of it: everything the
    # link line needs — `pkg_config`, `ldflags`, `framework`, static — is on
    # the consumer's own copy of the annotation already.
    getter iyi_artifact_libs = Set(String).new

    # iyi: the symbols an imported artifact's object code defines.
    #
    # The consumer's half. A method whose mangled name is in here is declared
    # rather than compiled; everything else this build compiles for itself.
    getter iyi_artifact_symbols = Set(String).new

    # iyi: the types an imported artifact's object code asks `~match<T>` about,
    # resolved (SPEC.md IV.1g).
    #
    # The consumer's half. A virtual type it could have enumerated from its own
    # classes; a union it could not — `(Char | Iyi::Keyword | String | Nil)` is
    # a type kemal's code formed and a consumer of kemal's never would.
    # Keyed by the name the artifact carried, because that is the name its
    # object code calls: a set of types the producer's build formed is not
    # always the set this one forms. `(Socket::IPAddress | Socket::UNIXAddress)`
    # is a union there and collapses to `Socket::Address+` here — the same
    # types, the same answer, a different symbol — so the function is defined
    # under the name that travelled and built from the type resolved here.
    getter iyi_artifact_match_types = {} of String => Type

    # iyi: the reads appended for an artifact's `Constants`, kept so codegen
    # can define the `~NAME:const_read` its object code calls (SPEC.md IV.1g).
    # See `read_iyi_artifact_constants`.
    getter iyi_artifact_constant_reads = [] of Path

    # iyi: the class variables an imported artifact's object code refers to, as
    # `Owner::@@name` (SPEC.md IV.2).
    #
    # The consumer's half of `iyi_unit_class_vars`. Names rather than the
    # variables themselves, because at the point an artifact is read the
    # declarations have only just been parsed — an instance variable's type is
    # settled by a later pass over the tree, and a class variable's is too. So
    # codegen resolves them, which is also where they are needed.
    getter iyi_artifact_class_vars = {} of String => Bool

    # iyi: what a synthesised regex constant was made from, by name (SPEC.md
    # IV.1g).
    #
    # A regex literal becomes a program-level constant, and the name it gets is
    # a digest of the pattern rather than anything anybody wrote — see
    # `regex_const_name`. That name is all `iyi_unit_constants` above can carry,
    # and a consumer handed only a name has nothing to build: `$` is not legal
    # in a constant, so it cannot travel as the source `Exports` is, and a
    # digest cannot be read backwards into the pattern that made it. So the
    # pattern and the flags are kept here, travel in their own section, and the
    # consumer rebuilds the constant under the name its object code asks for.
    #
    # Filled by `LiteralExpander` for every literal this program expands, which
    # includes the ones a consumer defined from an artifact — that is what makes
    # a second artifact naming the same pattern share the constant rather than
    # define it twice.
    getter iyi_regex_constants = {} of String => {String, RegexOptions}

    # The name a regex literal's constant gets: `$Regex:` and a digest of what
    # it was written as.
    #
    # `$` keeps it unwritable, which is the half the old name already had. The
    # digest is the half it did not: a name that means the same thing in a
    # program that never compiled this source. Both halves matter to the
    # linker — a unit reading the constant refers to `~<name>:const_read` —
    # and only the digest makes that reference safe to resolve against
    # somebody else's program.
    #
    # The flags are in the digest because they are in the pattern's meaning,
    # and the length is in it because a pattern may hold anything at all: two
    # different literals must not be able to spell the same key by moving the
    # separator.
    def self.regex_const_name(pattern : String, options : RegexOptions) : String
      key = "#{options.value}:#{pattern.bytesize}:#{pattern}"
      "$Regex:#{::Crystal::Digest::MD5.hexdigest(key)}"
    end

    # iyi: the `using` directives each file's module unit writes, by absolute
    # filename and as written (SPEC.md II.3).
    #
    # In the artifact because a signature is stored as the annotation the
    # author wrote, and an annotation is written in a context: `pub def
    # handle(ctx : Context)` means what it means because of a `using` further
    # up the file. Carrying the annotation without the context that resolves it
    # was enough for `std/list`, whose signatures name only its own types, and
    # not for the Kemal port, whose first exported signature names an imported
    # one.
    getter iyi_usings = {} of String => Array(String)

    # iyi: under `--crystal`, the library files each `.iyi` file required, by
    # absolute filename and in the order they were required (SPEC.md IV.1g,
    # `Requires`).
    #
    # A module's object code refers to Crystal's types by name, and only the
    # program that required the same library has those names to define. So they
    # travel in the artifact and the consumer replays them.
    getter iyi_module_requires = {} of String => Array(String)

    # iyi: the library-name requires a *Crystal* source made, with where each
    # one resolved. `tool bind` needs them and the map above cannot hold them:
    # it is keyed on `.iyi` files, and a shard has none.
    getter iyi_crystal_requires = {} of String => String

    # iyi: the method bodies each file's module has to ship, by absolute
    # filename and then by `IyiMod.mono_body_key` (SPEC.md IV.2, `MonoBodies`).
    #
    # A body travels when the consumer is the one that has to compile it: a
    # method of a generic type, which exists once per instantiation and the
    # instantiations are the consumer's, and a trait's default method, which is
    # stencilled onto the implementing type and so has no symbol any producer
    # could have emitted. Everything else stays behind and arrives as machine
    # code in `ObjectCode`.
    getter iyi_mono_bodies = {} of String => Hash(String, String)

    # iyi: the defs whose bodies travel because their machine code enumerates an
    # open type's members, by the location each was written at (SPEC.md III.6).
    #
    # Filled by `Iyi::OpenTravel`, which marks the def itself as well. The
    # location is here for the one reader that has no `Def` to ask: `iyi tool
    # bind` decides what a Crystal shard's boundary carries from its own record
    # of each method, and a location names one def in one build.
    getter iyi_open_travel_defs = Set(String).new

    # iyi: the macros each file declares, as source text, by absolute filename
    # (SPEC.md IV.1, `MacroBodies`).
    #
    # A macro is not code that runs, so nothing about it can arrive as machine
    # code — and a body that travels may call one. `run` takes a block, so the
    # consumer compiles it; if `run` writes `twice(n)` and `twice` is a macro
    # this module declared, the consumer has the call and not the macro, and
    # the artifact is refused on a name the module has.
    getter iyi_macro_bodies = {} of String => Array(String)

    # iyi: the `(Trait, Type)` pairs each file provides, by absolute filename
    # (SPEC.md IV.2, "Impl records").
    #
    # Collected as they are declared rather than recovered afterwards, because
    # an impl leaves no record of its own: it works by making the target type
    # include the trait, and by the time analysis is over that is
    # indistinguishable from any other ancestor.
    getter iyi_impls = {} of String => Array(IyiMod::ImplRecord)

    # iyi: the type a module path denotes — `"app/greeter"` to `App::Greeter`.
    #
    # Resolved by segment rather than remembered, which is only safe because
    # IV.6 #6 made the path-to-name mapping injective: two module paths cannot
    # denote one type, so this lookup cannot answer for the wrong module.
    def iyi_module_type(module_path : String) : ModuleType?
      module_path.split('/').reduce(self.as(ModuleType?)) do |scope, segment|
        return nil unless scope
        scope.types?.try(&.[]?(segment.camelcase)).as?(ModuleType)
      end
    end

    # iyi: every name an imported artifact's object code refers to, resolved
    # (SPEC.md IV.1g).
    #
    # Once, after the top-level pass has read every import, because that is the
    # scope of the question: a type id is resolved from a definition in *this
    # program*, not from whatever had been read by the time one artifact was
    # opened. See `IyiArtifactRef`.
    def resolve_iyi_artifact_refs : Nil
      refs = @iyi_artifact_refs
      return if refs.empty?
      @iyi_artifact_refs = [] of IyiArtifactRef

      refs.each do |ref|
        if ref.match
          iyi_artifact_match_types[ref.name] = iyi_match_type_named(ref.name)
        else
          parser = new_parser(ref.name)
          parser.next_token
          type_node = parser.parse_bare_proc_type
          parser.check :EOF
          # Reaching what the module keeps to itself, which is what these names
          # are made of: `Array(Router::RouteDefinition)` names a `private
          # record` and the artifact carries it as one. R-2b is not weakened by
          # that - the type arrives declared and unreachable, exactly as it is
          # when the module is read from source, and this is the compiler
          # restoring the module's own instantiation rather than anybody naming
          # it.
          #
          # Kept, not just resolved. Creating a class puts it in the numbering,
          # because ids are handed out by walking `Object`'s subclasses - but
          # that walk does not reach an enum, which gets its id from the first
          # code that asks. Nothing in this program asks for
          # `Regex::MatchOptions`, so codegen numbers these itself.
          iyi_artifact_numbered_types << lookup_type(type_node, include_private: true)
        end
      rescue CodeError
        # A name this build cannot resolve. The module's own types travel with
        # the artifact, unexported ones included, so what is left is a type of
        # a module this program did not import - reachable from neither.
        # Refused with both names rather than left to the linker, which would
        # report the mangled symbol and no module at all.
        if ref.match
          ref.node.raise <<-MESSAGE
            "#{ref.module_name}" matches against `#{ref.name}`, and this build cannot name it

            Its object code calls a function that compares a value's type id
            against that type, and the comparison is built from this program's
            own numbering - so this program has to have the type (SPEC.md
            IV.1g).

            Build the module from source, or import the module that declares it.
            MESSAGE
        else
          ref.node.raise <<-MESSAGE
            "#{ref.module_name}" numbers `#{ref.name}`, and this build cannot name it

            Its object code refers to that type's id, which is resolved from a
            definition in this program - so this program has to have the type.
            This module's own types travel with its artifact, so the one it
            cannot name belongs to a module this program did not import
            (SPEC.md IV.1g).

            Build the module from source, or import the module that declares it.
            MESSAGE
        end
      end
    end

    # iyi: one match type, from the name its symbol carries.
    #
    # The name is a *printed* type rather than source: `IPSocket+` is a virtual
    # type, `Random::Secure:Module` is a module used as a value, and
    # `(File::PReader | IO::FileDescriptor+ | OpenSSL::SSL::Socket+)` is a union
    # of both kinds. None of the three is anything a program can write, which is
    # why this reads the parts and asks the program for each: parsing the whole
    # string refused every union whose members are not plain names, and refusing
    # is how `faker` and `quartz` stopped - one with an error naming a type
    # nobody can spell, the other with an undefined `~match<...>` at link time.
    private def iyi_match_type_named(name : String) : Type
      body = name.strip
      body = body[1..-2].strip if iyi_wrapped_in_parens?(body)

      members = iyi_split_union(body)
      if members.size > 1
        return union_of(members.map { |member| iyi_match_type_named(member) }).not_nil!
      end

      metaclass = body.ends_with?(".class")
      body = body.rchop(".class").strip if metaclass
      # A module used as a value prints this way and is reached as the module's
      # metaclass, which is what holds its class methods.
      module_value = body.ends_with?(":Module")
      body = body.rchop(":Module").strip if module_value
      virtual = body.ends_with?('+')
      body = body.rchop('+').strip if virtual

      type = iyi_match_base_type(body)
      type = type.virtual_type if virtual
      type = type.metaclass if metaclass || module_value
      type
    end

    # One printed type with no suffix left on it: a name, or a generic
    # instantiated with types that may carry suffixes of their own.
    #
    # `DB::PoolResourceLost(DB::Connection+)` is the case that needs the second
    # half: the argument is a virtual type, which no parser takes, so the head
    # and the arguments are resolved apart and the generic is instantiated here.
    private def iyi_match_base_type(body : String) : Type
      if body.ends_with?(')') && (open = body.index('(')) && open > 0
        head = body[0...open].strip
        arguments = iyi_split_arguments(body[(open + 1)..-2])
        unless arguments.empty?
          generic = iyi_match_named_type(head)
          if generic.is_a?(GenericType)
            type_vars = arguments.map do |argument|
              if argument.to_i?
                NumberLiteral.new(argument).as(TypeVar)
              else
                iyi_match_type_named(argument).as(TypeVar)
              end
            end
            return generic.instantiate(type_vars)
          end
        end
      end

      iyi_match_named_type body
    end

    private def iyi_match_named_type(body : String) : Type
      parser = new_parser(body)
      parser.next_token
      type_node = parser.parse_bare_proc_type
      parser.check :EOF
      lookup_type(type_node, include_private: true)
    end

    # Whether one pair of parentheses encloses the whole of *text*, so `(A | B)`
    # unwraps and `(A) | (B)` does not.
    private def iyi_wrapped_in_parens?(text : String) : Bool
      return false unless text.starts_with?('(') && text.ends_with?(')')
      depth = 0
      text.each_char_with_index do |char, index|
        case char
        when '(' then depth += 1
        when ')'
          depth -= 1
          return index == text.size - 1 if depth.zero?
        end
      end
      false
    end

    # `A, B(C, D), 16` as three, splitting only where the depth is zero.
    private def iyi_split_arguments(text : String) : Array(String)
      arguments = [] of String
      depth = 0
      from = 0
      text.each_char_with_index do |char, index|
        case char
        when '(', '[', '{' then depth += 1
        when ')', ']', '}' then depth -= 1
        when ','
          if depth.zero?
            arguments << text[from...index].strip
            from = index + 1
          end
        end
      end
      arguments << text[from..].strip
      arguments.reject(&.empty?)
    end

    # `A | B+ | C(D | E)` as three, splitting only where the depth is zero.
    private def iyi_split_union(text : String) : Array(String)
      members = [] of String
      depth = 0
      from = 0
      text.each_char_with_index do |char, index|
        case char
        when '(', '[', '{' then depth += 1
        when ')', ']', '}' then depth -= 1
        when '|'
          if depth.zero?
            members << text[from...index].strip
            from = index + 1
          end
        end
      end
      members << text[from..].strip
      members.reject(&.empty?)
    end

    # All created unions in a program, indexed by an array of opaque
    # ids of each type in the union. The array (the key) is sorted
    # by this opaque id.
    #
    # A program caches them this way so a union of `String | Int32`
    # or `Int32 | String` is represented by a single, unique type
    # in the program.
    getter unions = {} of Array(UInt64) => UnionType

    # A String pool to avoid creating the same strings over and over.
    # This pool is passed to the parser, macro expander, etc.
    getter string_pool = StringPool.new

    record ConstSliceInfo, name : String, element_type : NumberKind, args : Array(ASTNode) do
      def to_bytes : Bytes
        element_size = element_type.bytesize // 8
        bytesize = args.size * element_size
        buffer = Pointer(UInt8).malloc(bytesize)
        ptr = buffer

        args.each do |arg|
          num = arg.as(NumberLiteral)
          case element_type
          in .i8?   then ptr.as(Int8*).value = num.value.to_i8
          in .i16?  then ptr.as(Int16*).value = num.value.to_i16
          in .i32?  then ptr.as(Int32*).value = num.value.to_i32
          in .i64?  then ptr.as(Int64*).value = num.value.to_i64
          in .i128? then ptr.as(Int128*).value = num.value.to_i128
          in .u8?   then ptr.as(UInt8*).value = num.value.to_u8
          in .u16?  then ptr.as(UInt16*).value = num.value.to_u16
          in .u32?  then ptr.as(UInt32*).value = num.value.to_u32
          in .u64?  then ptr.as(UInt64*).value = num.value.to_u64
          in .u128? then ptr.as(UInt128*).value = num.value.to_u128
          in .f32?  then ptr.as(Float32*).value = num.value.to_f32
          in .f64?  then ptr.as(Float64*).value = num.value.to_f64
          end
          ptr += element_size
        end

        buffer.to_slice(bytesize)
      end
    end

    # All constant slices constructed via the `Slice.literal` compiler built-in,
    # indexed by their buffers' internal names (e.g. `$Slice:0`).
    getter const_slices = {} of String => ConstSliceInfo

    # Here we store constants, in the
    # order that they are used. They will be initialized as soon
    # as the program starts, before the main code.
    getter const_initializers = [] of Const

    # The class var initializers stored to be used by the cleanup transformer
    getter class_var_initializers = [] of ClassVarInitializer

    # Counters for the `__temp_*` temporary variables. Each prefix has its own
    # counter, see `#new_temp_var_name` for details.
    @temp_vars = Hash(String, Int32).new { |hash, prefix| hash[prefix] = 1 }

    # The constant for ARGC_UNSAFE
    getter! argc : Const

    # The constant for ARGV_UNSAFE
    getter! argv : Const

    # Default standard output to use in a program, while compiling.
    property stdout : IO = STDOUT

    # Whether to show error trace
    property? show_error_trace = false

    # The main filename of this program
    property filename : String?

    # A `ProgressTracker` object which tracks compilation progress.
    property progress_tracker = ProgressTracker.new

    getter codegen_target = Config.host_target

    getter predefined_constants = Array(Const).new

    # iyi: absent from a front-end build — a `Compiler` is the driver that
    # generates code, and this is the binary that does not (see `llvm_shim.cr`).
    # The passes that reach for it do so through `try`, so there it is nil
    # rather than missing.
    {% if flag?(:without_llvm) %}
      def compiler : Nil
        nil
      end
    {% else %}
      property compiler : Compiler?
    {% end %}

    property optimization_mode = Compiler::OptimizationMode::O0

    def initialize
      super(self, self, "main")

      # Every crystal program comes with some predefined types that we initialize here,
      # like Object, Value, Reference, etc.
      types = self.types

      types["Object"] = object = @object = NonGenericClassType.new self, self, "Object", nil
      object.can_be_stored = false
      object.abstract = true

      types["Reference"] = reference = @reference = NonGenericClassType.new self, self, "Reference", object
      reference.can_be_stored = false

      types["Value"] = value = @value = NonGenericClassType.new self, self, "Value", object
      abstract_value_type(value)

      types["Number"] = number = @number = NonGenericClassType.new self, self, "Number", value
      abstract_value_type(number)

      types["NoReturn"] = @no_return = NoReturnType.new self, self, "NoReturn"
      types["Void"] = @void = VoidType.new self, self, "Void"
      types["Nil"] = @nil = NilType.new self, self, "Nil", value, 1
      types["Bool"] = @bool = BoolType.new self, self, "Bool", value, 1
      types["Char"] = @char = CharType.new self, self, "Char", value, 4

      types["Int"] = int = @int = NonGenericClassType.new self, self, "Int", number
      abstract_value_type(int)

      types["Int8"] = @int8 = IntegerType.new self, self, "Int8", int, 1, 1, :i8
      types["UInt8"] = @uint8 = IntegerType.new self, self, "UInt8", int, 1, 2, :u8
      types["Int16"] = @int16 = IntegerType.new self, self, "Int16", int, 2, 3, :i16
      types["UInt16"] = @uint16 = IntegerType.new self, self, "UInt16", int, 2, 4, :u16
      types["Int32"] = @int32 = IntegerType.new self, self, "Int32", int, 4, 5, :i32
      types["UInt32"] = @uint32 = IntegerType.new self, self, "UInt32", int, 4, 6, :u32
      types["Int64"] = @int64 = IntegerType.new self, self, "Int64", int, 8, 7, :i64
      types["UInt64"] = @uint64 = IntegerType.new self, self, "UInt64", int, 8, 8, :u64
      types["Int128"] = @int128 = IntegerType.new self, self, "Int128", int, 16, 9, :i128
      types["UInt128"] = @uint128 = IntegerType.new self, self, "UInt128", int, 16, 10, :u128

      types["Float"] = float = @float = NonGenericClassType.new self, self, "Float", number
      abstract_value_type(float)

      types["Float32"] = @float32 = FloatType.new self, self, "Float32", float, 4, 9
      types["Float64"] = @float64 = FloatType.new self, self, "Float64", float, 8, 10

      types["Symbol"] = @symbol = SymbolType.new self, self, "Symbol", value, 4
      types["Pointer"] = pointer = @pointer = PointerType.new self, self, "Pointer", value, ["T"]
      pointer.struct = true
      pointer.can_be_stored = false

      types["Tuple"] = tuple = @tuple = TupleType.new self, self, "Tuple", value, ["T"]
      tuple.can_be_stored = false

      types["NamedTuple"] = named_tuple = @named_tuple = NamedTupleType.new self, self, "NamedTuple", value, ["T"]
      named_tuple.can_be_stored = false

      types["StaticArray"] = static_array = @static_array = StaticArrayType.new self, self, "StaticArray", value, ["T", "N"]
      static_array.struct = true
      static_array.declare_instance_var("@buffer", static_array.type_parameter("T"))
      static_array.can_be_stored = false

      types["String"] = string = @string = NonGenericClassType.new self, self, "String", reference
      string.declare_instance_var("@bytesize", int32)
      string.declare_instance_var("@length", int32)
      string.declare_instance_var("@c", uint8)

      types["Class"] = klass = @class = MetaclassType.new(self, object, value, "Class")
      klass.can_be_stored = false

      types["Struct"] = struct_t = @struct_t = NonGenericClassType.new self, self, "Struct", value
      abstract_value_type(struct_t)

      types["Enumerable"] = @enumerable = GenericModuleType.new self, self, "Enumerable", ["T"]
      types["Indexable"] = @indexable = GenericModuleType.new self, self, "Indexable", ["T"]

      types["Array"] = @array = GenericClassType.new self, self, "Array", reference, ["T"]
      types["Hash"] = @hash_type = GenericClassType.new self, self, "Hash", reference, ["K", "V"]
      types["Regex"] = @regex = NonGenericClassType.new self, self, "Regex", reference
      types["Range"] = range = @range = GenericClassType.new self, self, "Range", struct_t, ["B", "E"]
      range.struct = true
      types["Slice"] = slice = @slice = GenericClassType.new self, self, "Slice", struct_t, ["T"]
      slice.struct = true

      types["Exception"] = @exception = NonGenericClassType.new self, self, "Exception", reference

      types["Enum"] = enum_t = @enum = NonGenericClassType.new self, self, "Enum", value
      abstract_value_type(enum_t)

      types["Proc"] = @proc = ProcType.new self, self, "Proc", value, ["T", "R"]
      types["Union"] = @union = GenericUnionType.new self, self, "Union", value, ["T"]
      types["Crystal"] = @crystal = NonGenericModuleType.new self, self, "Crystal"

      # iyi: everything above, recorded rather than written down again.
      #
      # `tool bind` asks whether a program could name a type without requiring
      # anything, and for these the answer is yes by construction: they are here
      # before the first line of any prelude is read, iyi's included. It used to
      # ask a literal list kept beside the tool, and that list was wrong in both
      # directions — it claimed `Void`, `UInt32` and `Float64`, which iyi's
      # prelude never declares, and omitted `Slice`, `Int` and `Tuple`, which
      # are created right here. A list is a claim that everything not in it is
      # somebody else's work, and nothing was enforcing the claim.
      @builtin_type_names = types.keys.to_set

      types["ARGC_UNSAFE"] = @argc = argc_unsafe = Const.new self, self, "ARGC_UNSAFE", Primitive.new("argc", int32)
      types["ARGV_UNSAFE"] = @argv = argv_unsafe = Const.new self, self, "ARGV_UNSAFE", Primitive.new("argv", pointer_of(pointer_of(uint8)))

      argc_unsafe.no_init_flag = true
      argv_unsafe.no_init_flag = true

      predefined_constants << argc_unsafe
      predefined_constants << argv_unsafe

      # Make sure to initialize `ARGC_UNSAFE` and `ARGV_UNSAFE` as soon as the program starts
      const_initializers << argc_unsafe
      const_initializers << argv_unsafe

      types["GC"] = gc = NonGenericModuleType.new self, self, "GC"
      gc.metaclass.as(ModuleType).add_def Def.new("add_finalizer", [Arg.new("object")], Nop.new)

      # Built-in annotations
      types["AlwaysInline"] = @always_inline_annotation = AnnotationType.new self, self, "AlwaysInline"
      types["CallConvention"] = @call_convention_annotation = AnnotationType.new self, self, "CallConvention"
      types["Extern"] = @extern_annotation = AnnotationType.new self, self, "Extern"
      types["Flags"] = @flags_annotation = AnnotationType.new self, self, "Flags"
      types["Link"] = @link_annotation = AnnotationType.new self, self, "Link"
      types["Naked"] = @naked_annotation = AnnotationType.new self, self, "Naked"
      types["NoInline"] = @no_inline_annotation = AnnotationType.new self, self, "NoInline"
      types["Packed"] = @packed_annotation = AnnotationType.new self, self, "Packed"
      types["Primitive"] = @primitive_annotation = AnnotationType.new self, self, "Primitive"
      types["Raises"] = @raises_annotation = AnnotationType.new self, self, "Raises"
      types["ReturnsTwice"] = @returns_twice_annotation = AnnotationType.new self, self, "ReturnsTwice"
      types["ThreadLocal"] = @thread_local_annotation = AnnotationType.new self, self, "ThreadLocal"
      types["Deprecated"] = @deprecated_annotation = AnnotationType.new self, self, "Deprecated"
      types["Experimental"] = @experimental_annotation = AnnotationType.new self, self, "Experimental"
      types["TargetFeature"] = @target_feature_annotation = AnnotationType.new self, self, "TargetFeature"
      # iyi: `@[Share]` on a struct or class is the trust half of SPEC.md
      # III.4.4's marker — the type is shareable whenever its type arguments
      # are, whatever its fields do — for the short list that owns what it
      # holds: `Atomic(T)` in the prelude, `List(T)` in the samples. The
      # structural half needs no annotation; `Iyi::Share` computes it. A
      # producer writes `@[Share]` into an artifact's type declaration for
      # every type it found shareable, and a consumer reads that and never
      # recomputes: the bodies that would tell it are not in the artifact.
      types["Share"] = @share_annotation = AnnotationType.new self, self, "Share"

      # iyi: the marker that makes a union member an error member (SPEC.md
      # III.1.1). Created here rather than declared in the prelude because the
      # compiler has to recognise this exact trait — `!`, `.or` and `.or_panic`
      # all ask whether a member implements it — and a name the prelude happened
      # to define could be shadowed or replaced. Nothing else about it is
      # special: it is an ordinary trait, implemented with an ordinary `impl`.
      types["Error"] = @error_trait = TraitType.new self, self, "Error"
      error_message = Def.new("message", return_type: Path.global(["String"]))
      error_message.abstract = true
      error_trait.add_def error_message

      # definition in `macros/types.cr`
      define_macro_types
    end

    # iyi: the types the compiler creates for every program, whatever its
    # prelude. Snapshotted in `initialize`, so a built-in added later is in here
    # without anybody remembering to add it.
    getter builtin_type_names = Set(String).new

    # Returns a new `Parser` for the given *source*, sharing the string pool and
    # warnings with this program.
    def new_parser(source : String, var_scopes = [Set(String).new])
      Parser.new(source, string_pool, var_scopes, warnings)
    end

    # Returns a `LiteralExpander` useful to expand literal like arrays and hashes
    # into simpler forms.
    getter(literal_expander) { LiteralExpander.new self }

    # Returns a `IyiPath` for this program.
    # Settable, not only readable, and the reason is that this is a **struct**.
    # A build that adopts a preanalysed prelude has to move the path's working
    # directory to its own (see `compile_with_preanalysed_prelude`), and
    # `program.iyi_path.current_dir = ...` through a getter mutates the copy
    # the getter returned and throws it away — silently, with the daemon still
    # resolving `lib` beside itself.
    property(iyi_path) { IyiPath.new(codegen_target: codegen_target) }

    # Returns a `Var` that has `Nil` as a type.
    # This variable is bound to other nodes in the semantic phase for things
    # that need to be nilable, for example to a variable that's only declared
    # in one branch of an `if` expression.
    getter(nil_var) { Var.new("<nil_var>", nil_type) }

    # Defines a predefined constant in the Crystal module, such as BUILD_DATE and VERSION.
    def define_crystal_constants
      if build_commit = Iyi::Config.build_commit
        build_commit_const = define_crystal_string_constant "BUILD_COMMIT", build_commit
      else
        build_commit_const = define_crystal_nil_constant "BUILD_COMMIT"
      end
      build_commit_const.doc = <<-MD
        The build commit identifier of the Crystal compiler.
        MD

      define_crystal_string_constant "BUILD_DATE", Iyi::Config.date, <<-MD
        The build date of the Crystal compiler.
        MD
      define_crystal_string_constant "CACHE_DIR", CacheDir.instance.dir, <<-MD
        The cache directory configured for the Crystal compiler.

        The value is defined by the environment variable `IYI_CACHE_DIR` and
        defaults to the user's configured cache directory.
        MD
      define_crystal_string_constant "DEFAULT_PATH", Iyi::Config.path, <<-MD
        The default Crystal path configured in the compiler. This value is baked
        into the compiler and usually points to the accompanying version of the
        standard library.
        MD
      define_crystal_string_constant "DESCRIPTION", Iyi::Config.description, <<-MD
        Full version information of the Crystal compiler. Equivalent to `crystal --version`.
        MD
      define_crystal_string_constant "PATH", Iyi::IyiPath.default_path, <<-MD
        Colon-separated paths where the compiler searches for required source files.

        The value is defined by the environment variable `IYI_PATH`
        and defaults to `DEFAULT_PATH`.
        MD
      define_crystal_string_constant "LIBRARY_PATH", Iyi::IyiLibraryPath.default_path, <<-MD
        Colon-separated paths where the compiler searches for (binary) libraries.

        The value is defined by the environment variables `IYI_LIBRARY_PATH`.
        MD
      define_crystal_string_constant "VERSION", Iyi::Config.version, <<-MD
        The version of the Crystal compiler.
        MD
      define_crystal_string_constant "LLVM_VERSION", LLVM.version, <<-MD
        The version of LLVM used by the Crystal compiler.
        MD
      define_crystal_string_constant "HOST_TRIPLE", Iyi::Config.host_target.to_s, <<-MD
        The LLVM target triple of the host system (the machine that the compiler runs on).
        MD
      define_crystal_string_constant "TARGET_TRIPLE", codegen_target.to_s, <<-MD
        The LLVM target triple of the target system (the machine that the compiler builds for).
        MD
    end

    private def define_crystal_string_constant(name, value, doc = nil)
      define_crystal_constant name, StringLiteral.new(value).tap(&.set_type(string)), doc
    end

    private def define_crystal_nil_constant(name, doc = nil)
      define_crystal_constant name, NilLiteral.new.tap(&.set_type(self.nil)), doc
    end

    private def define_crystal_constant(name, value, doc = nil) : Const
      crystal.types[name] = const = Const.new self, crystal, name, value
      const.no_init_flag = true
      const.doc = doc

      predefined_constants << const
      const
    end

    # iyi: `sizeof` and its neighbours are answered from LLVM's data layout,
    # which a front-end build has no library to ask. They live in `codegen.cr`
    # with the typer that answers them, so without it they are simply absent —
    # and the semantic pass calls them for a program that writes `sizeof`.
    #
    # Nothing in iyi's prelude or samples does. So this says what it cannot do,
    # where a wrong number would travel into a constant and be believed. See
    # `llvm_shim.cr`.
    {% if flag?(:without_llvm) %}
      {% for query in %w(size_of instance_size_of align_of instance_align_of) %}
        def {{ query.id }}(type)
          raise Iyi::Error.new("`{{ query.id }}` is answered from a data layout, and this compiler links no LLVM to hold one")
        end
      {% end %}

      {% for query in %w(offset_of instance_offset_of) %}
        def {{ query.id }}(type, element_index)
          raise Iyi::Error.new("`{{ query.id }}` is answered from a data layout, and this compiler links no LLVM to hold one")
        end
      {% end %}
    {% end %}

    # iyi: absent from a front-end build, which is the point of one — a target
    # machine is LLVM's, and the passes that ask for it are codegen's. The one
    # exception outside codegen is an AVR flag; see `semantic/flags.cr`.
    {% unless flag?(:without_llvm) %}
      property(target_machine : LLVM::TargetMachine) { codegen_target.to_target_machine }
    {% end %}

    def codegen_target=(@codegen_target : Codegen::Target) : Codegen::Target
      @codegen_target
    end

    # Returns the `Type` for `Array(type)`
    def array_of(type)
      array.instantiate [type] of TypeVar
    end

    # Returns the `Type` for `Hash(key_type, value_type)`
    def hash_of(key_type, value_type)
      hash_type.instantiate [key_type, value_type] of TypeVar
    end

    # Returns the `Type` for `Range(begin_type, end_type)`
    def range_of(begin_type, end_type)
      range.instantiate [begin_type, end_type] of TypeVar
    end

    # Returns the `Type` for `Tuple(*types)`
    def tuple_of(types)
      type_vars = types.map &.as(TypeVar)
      tuple.instantiate(type_vars)
    end

    # Returns the `Type` for `NamedTuple(**entries)`
    def named_tuple_of(entries : Hash(String, Type) | NamedTuple)
      entries = entries.map { |k, v| NamedArgumentType.new(k.to_s, v.as(Type)) }
      named_tuple_of(entries)
    end

    # :ditto:
    def named_tuple_of(entries : Array(NamedArgumentType))
      named_tuple.instantiate_named_args(entries)
    end

    # Returns the `Type` for `type | Nil`
    def nilable(type)
      case type
      when self.nil, self.no_return
        # Nil | Nil      # => Nil
        # NoReturn | Nil # => Nil
        self.nil
      when UnionType
        types = Array(Type).new(type.union_types.size + 1)
        types.concat type.union_types
        types << self.nil unless types.includes? self.nil
        union_of types
      else
        union_of self.nil, type
      end
    end

    # Returns the `Type` for `type1 | type2`
    def union_of(type1, type2)
      # T | T # => T
      return type1 if type1 == type2

      union_of([type1, type2] of Type).not_nil!
    end

    # Returns the `Type` for `Union(*types)`
    def union_of(types : Array)
      case types.size
      when 0
        nil
      when 1
        types.first
      else
        types.sort_by! &.opaque_id
        opaque_ids = types.map(&.opaque_id)
        unions[opaque_ids] ||= make_union_type(types, opaque_ids)
      end
    end

    private def make_union_type(types, opaque_ids)
      # NilType has opaque_id == 0
      has_nil = opaque_ids.first == 0

      if has_nil
        # Check if it's a Nilable type
        if types.size == 2
          other_type = types[1]
          if other_type.reference_like? && !other_type.virtual?
            return NilableType.new(self, other_type)
          else
            untyped_type = other_type.remove_typedef
            if untyped_type.proc?
              return NilableProcType.new(self, other_type)
            end
          end
        end

        # Remove the Nil type now and later insert it at the end
        nil_type = types.shift
      end

      # Sort by name so a same union type, say `Int32 | String`, always is named that
      # way, regardless of the actual order of the types. However, we always put
      # Nil at the end, inside the `nil_type` check.
      types.sort_by! &.to_s

      if nil_type
        types.push nil_type

        if types.all?(&.reference_like?)
          return NilableReferenceUnionType.new(self, types)
        else
          return MixedUnionType.new(self, types)
        end
      end

      if types.all? &.reference_like?
        return ReferenceUnionType.new(self, types)
      end

      MixedUnionType.new(self, types)
    end

    # Returns the `Type` for `Proc(*types)`
    def proc_of(types : Array)
      type_vars = types.map &.as(TypeVar)
      unless type_vars.empty?
        type_vars[-1] = self.nil if type_vars[-1].is_a?(VoidType)
      end
      proc.instantiate(type_vars)
    end

    # Returns the `Type` for `Proc(*nodes.map(&.type), return_type)`
    def proc_of(nodes : Array(ASTNode), return_type : Type)
      type_vars = Array(TypeVar).new(nodes.size + 1)
      nodes.each do |node|
        type_vars << node.type
      end
      return_type = self.nil if return_type.void?
      type_vars << return_type
      proc.instantiate(type_vars)
    end

    # Returns the `Type` for `Pointer(type)`
    def pointer_of(type)
      pointer.instantiate([type] of TypeVar)
    end

    # Returns the `Type` for `StaticArray(type, size)`
    def static_array_of(type, size)
      static_array.instantiate([type, NumberLiteral.new(size)] of TypeVar)
    end

    record RecordedRequire, filename : String, relative_to : String? do
      include JSON::Serializable
    end
    property recorded_requires = [] of RecordedRequire

    # Remembers that the program depends on this require.
    def record_require(filename, relative_to) : Nil
      recorded_requires << RecordedRequire.new(filename, relative_to)
    end

    def run_requires(node : Require, filenames, &) : Nil
      dependency_printer = compiler.try(&.dependency_printer)

      filenames.each do |filename|
        unseen_file = requires.add?(filename)

        dependency_printer.try(&.enter_file(filename, unseen_file))

        if unseen_file
          yield filename
        end

        dependency_printer.try(&.leave_file)
      end
    end

    # Finds *filename* in the configured IYI_PATH for this program,
    # relative to *relative_to*.
    def find_in_path(filename, relative_to = nil) : Array(String)?
      iyi_path.find filename, relative_to
    end

    {% for name in %w(object no_return value number reference void nil bool char int int8 int16 int32 int64 int128
                     uint8 uint16 uint32 uint64 uint128 float float32 float64 string symbol pointer enumerable indexable
                     array static_array exception tuple named_tuple proc union enum range slice regex crystal
                     packed_annotation thread_local_annotation no_inline_annotation target_feature_annotation
                     always_inline_annotation naked_annotation returns_twice_annotation
                     raises_annotation primitive_annotation call_convention_annotation
                     flags_annotation link_annotation extern_annotation deprecated_annotation experimental_annotation
                     share_annotation error_trait) %}
      def {{name.id}}
        @{{name.id}}.not_nil!
      end
    {% end %}

    # Returns the `Nil` type
    def nil_type
      @nil.not_nil!
    end

    # Returns the `Hash` type
    def hash_type
      @hash_type.not_nil!
    end

    def type_from_literal_kind(kind : NumberKind)
      case kind
      in .i8?   then int8
      in .i16?  then int16
      in .i32?  then int32
      in .i64?  then int64
      in .i128? then int128
      in .u8?   then uint8
      in .u16?  then uint16
      in .u32?  then uint32
      in .u64?  then uint64
      in .u128? then uint128
      in .f32?  then float32
      in .f64?  then float64
      end
    end

    def int_type(signed, size)
      if signed
        case size
        when  1 then int8
        when  2 then int16
        when  4 then int32
        when  8 then int64
        when 16 then int128
        else
          raise "BUG: Invalid int size: #{size}"
        end
      else
        case size
        when  1 then uint8
        when  2 then uint16
        when  4 then uint32
        when  8 then uint64
        when 16 then uint128
        else
          raise "BUG: Invalid int size: #{size}"
        end
      end
    end

    # Returns the `IntegerType` that matches the given Int value
    def int?(int)
      case int
      when Int8    then int8
      when Int16   then int16
      when Int32   then int32
      when Int64   then int64
      when Int128  then int128
      when UInt8   then uint8
      when UInt16  then uint16
      when UInt32  then uint32
      when UInt64  then uint64
      when UInt128 then uint128
      else
        nil
      end
    end

    # Returns the `Struct` type
    def struct
      @struct_t.not_nil!
    end

    # Returns the `Class` type
    def class_type
      @class.not_nil!
    end

    def new_temp_var(node : ASTNode) : Var
      # TODO: is it safe to add `.at(node)` here?
      Var.new(new_temp_var_name(node))
    end

    def new_temp_var(prefix : String? = nil) : Var
      Var.new(new_temp_var_name(prefix))
    end

    # Returns a unique variable name associated with the given AST *node*.
    #
    # Nodes with a location include the first 8 digits of the filename's MD5
    # digest as part of the prefix, e.g. all names originating from `foo.cr` use
    # the prefix `__temp_cd6ae5dd_*`. This localizes the impact on incremental
    # object file generation to all types defined or reopened in that same file.
    def new_temp_var_name(node : ASTNode) : String
      if filename = node.location.try(&.original_filename)
        # the parser creates `Location`s with an empty filename by default,
        # assume they are equivalent to `nil` to make compiler specs less noisy
        unless filename == ""
          prefix = "__temp_#{Crystal::Digest::MD5.hexdigest(filename)[0, 8]}_"
        end
      end

      new_temp_var_name(prefix)
    end

    # Returns a unique variable name associated with the given *prefix*.
    #
    # By convention, the prefix must start with `__temp_`, and defaults to it as
    # well.
    def new_temp_var_name(prefix : String? = nil) : String
      prefix ||= "__temp_"
      id = @temp_vars.update(prefix, &.succ)
      "#{prefix}#{id}"
    end

    # Colorizes the given object, depending on whether this program
    # is configured to use colors.
    def colorize(obj)
      obj.colorize.toggle(@color)
    end

    private def abstract_value_type(type)
      type.abstract = true
      type.struct = true
      type.can_be_stored = false
    end

    # Next come overrides for the type system

    def metaclass
      self
    end

    def type_desc
      "main"
    end

    def add_def(node : Def)
      if file_module = check_private(node)
        file_module.add_def node
      else
        super
      end
    end

    def add_macro(node : Macro)
      if file_module = check_private(node)
        file_module.add_macro node
      else
        super
      end
    end

    def lookup_private_matches(filename, signature, analyze_all = false)
      file_module?(filename).try &.lookup_matches(signature, analyze_all: analyze_all)
    end

    def file_module?(filename)
      file_modules[filename]?
    end

    def file_module(filename)
      file_modules[filename] ||= FileModule.new(self, self, filename)
    end

    def check_private(node)
      return nil unless node.visibility.private?

      filename = node.location.try &.original_filename
      return nil unless filename

      file_module(filename)
    end

    def to_s(io : IO) : Nil
      io << "<Program>"
    end
  end
end
