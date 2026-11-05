require "../syntax/ast"
require "../syntax/visitor"
require "../types"

module Iyi
  class Program
    getter(iyi_share_reach : ShareReach) { ShareReach.new(self) }

    # What the functions of the modules read from artifacts reach of
    # module state (`IyiMod::Section::Reaches`), by `ShareReach.reach_key`,
    # every artifact's together: a function an artifact's object code holds
    # an instance of may be declared by another module.
    getter iyi_artifact_reaches = {} of String => Array(IyiMod::ReachRecord)

    # The artifacts read without a `Reaches` section, by path, each with its
    # module: what their functions reach is not known.
    getter iyi_artifacts_without_reaches = {} of String => String

    # The claims `ReachProof` found hold for every program that imports
    # the module declaring the state, by the state's `object_id`: what
    # they reach is left out of the module's `Reaches`. A claim itself
    # never crosses an artifact - the annotation does not travel - so a
    # consumer naming the state in a body that travelled reads it as
    # unclaimed.
    getter iyi_reach_robust = Set(UInt64).new

    # Records what the artifact at *path* says its functions reach, or
    # that it does not say.
    def iyi_record_artifact_reaches(path : String, artifact : IyiMod::Artifact) : Nil
      reaches = artifact.reaches
      unless reaches
        @iyi_artifacts_without_reaches[path] = artifact.module_name
        return
      end
      reaches.each do |record|
        (@iyi_artifact_reaches[record.function] ||= [] of IyiMod::ReachRecord) << record
      end
    end

    # The module whose artifact *location* was read from, or nil for one
    # read from source.
    def iyi_artifact_module_at(location : Location?) : String?
      file = location.try(&.original_artifact)
      file ? (@iyi_artifact_modules[file]? || @iyi_artifacts_without_reaches[file]?) : nil
    end
  end

  # iyi: the module state a block that crosses threads reaches through the
  # defs it calls (SPEC.md III.4.4). `CleanupTransformer#check_share_boundary`
  # refuses what the block names in its own text; a constant read one call
  # away was not seen, and that is where a program keeps its database pool:
  # a parallel block calling `ask`, which ran `DATABASE.query_one`, compiled
  # silently and at 12 workers answered other requests' rows (#148). This
  # walks the typed call graph from the block and lists every constant and
  # class variable met on the way, each with the shortest path of defs that
  # reaches it; the boundary check warns for those whose type is not Share.
  #
  # The walk covers the program's own modules and the packages it depends
  # on, and never std or the prelude, nor a constant std declares: a
  # dependency keeps module state the program cannot see as surely as the
  # program's own files do, and std's is its own to keep safe, which its
  # boundaries check where it is written. It stops where the capture check
  # does: a constant typed `Mutex`, `Atomic`, `List` or another trusted
  # `@[Share]` type is Share, and is not warned about, and their methods
  # are std's. A block given to a lock (`MUTEX.lock { ask }`) is walked like
  # any other: the lock guards what it holds, not the constants the block
  # reaches, which other code reaches without it - the reason a block
  # behind a lock may not name one either. Every target of a call is
  # walked, so a virtual call reaches each override, and a def met twice,
  # by recursion or by two paths, is walked once.
  #
  # A module read from its `.iyimod` has declarations and no bodies, and
  # the walk read each of its functions as reaching nothing: a spawn
  # calling a dependency's `note`, which appended to an unguarded `Array`,
  # was placed in parallel and lost appends (SPEC.md III.4.15). The build
  # writing the artifact records what each function reaches
  # (`summarise`), and a consumer's walk reads that where the body is not
  # (`remote_of`); an artifact without the record is "not known".
  #
  # What each def names and calls is read once per compilation and kept, so
  # a hundred routes reaching the same model functions read them once.
  class ShareReach
    # A constant or class variable a body names: *state* is the constant or
    # the class variable's cell, *label* how the source spells it, *use* the
    # expression it is used in (`DATABASE.query_one`), *at* where that
    # expression is.
    record Named, state : Const | MetaTypeVar, label : String, type : Type, use : String, at : Location? do
      def key : UInt64
        state.object_id
      end

      # Where the state is declared: a constant's assignment, and for a
      # class variable, which only its class's own code can name, the
      # place it is named.
      def declared : Location?
        state = self.state
        state.is_a?(Const) ? (state.locations.try(&.first?) || state.value.location) : at
      end
    end

    # What one body names, the defs it calls that the walk enters, and the
    # defs of std and the prelude it calls, which the walk passes through
    # for what they call back (`exits_of`).
    record Facts, named : Array(Named), calls : Array(Def), std_calls : Array(Def)

    # A named thing the walk found, and the defs that lead to it from the
    # block: the first is one the block calls, the last the one naming it.
    # Or what a function read from an artifact reaches, as its artifact
    # recorded it, the last def being that function; a record with an
    # empty *kind* says the artifact recorded nothing (`remote_of`).
    record Found, named : Named | IyiMod::ReachRecord, path : Array(Def)

    def initialize(@program : Program)
      @facts = {} of Def => Facts
      @facts.compare_by_identity
      @exits = {} of Def => Array(Def)
      @exits.compare_by_identity
      @std_files = {} of String => Bool
      @std_dirs = {} of String => Bool
      @packages = {} of String => {String, String}?
    end

    # Everything the block whose body is *block_def*'s reaches through the
    # defs it calls, each once, by the shortest path (fewest defs; the
    # first written among equals). What the block names in its own text is
    # left out: the boundary check asks about that, and refuses it.
    def reach(block_def : Def) : Array(Found)
      start = scan(block_def.body)
      seen = Set(UInt64).new
      start.named.each { |named| seen << named.key }
      walk(start, seen)
    end

    # The walk from what *start* calls, past what *seen* holds. A function
    # read from an artifact has no body here (SPEC.md IV.1g): what it
    # reaches is what its artifact recorded when the body was there, and
    # the walk does not go past it. A def of std or the prelude is passed
    # through to the program's own defs it calls back, each on the path
    # after it: `Array#includes?` → `Key#==`.
    private def walk(start : Facts, seen : Set(UInt64)) : Array(Found)
      remote = Set({String, String}).new
      visited = Set(Def).new.compare_by_identity
      queue = Deque({Def, Array(Def)}).new
      enqueue(start, [] of Def, visited, queue)
      found = [] of Found
      while entry = queue.shift?
        a_def, path = entry
        if header?(a_def)
          remote_of(a_def).each do |record|
            found << Found.new(record, path) if remote.add?({record.module_name, record.label})
          end
          next
        end
        facts = facts_of(a_def)
        facts.named.each do |named|
          found << Found.new(named, path) if seen.add?(named.key)
        end
        enqueue(facts, path, visited, queue)
      end
      found
    end

    private def enqueue(facts : Facts, path : Array(Def), visited : Set(Def), queue : Deque({Def, Array(Def)})) : Nil
      facts.calls.each do |target|
        queue << {target, path + [target]} if visited.add?(target)
      end
      facts.std_calls.each do |std_def|
        exits_of(std_def).each do |target|
          queue << {target, path + [std_def, target]} if visited.add?(target)
        end
      end
    end

    # The program's own defs *std_def*, written in std or the prelude, may
    # call back through std alone: an `==` that `Array#includes?` asks, a
    # `to_s` an interpolation asks. The walk stopped at std, and a spawn
    # whose block interpolated a value whose `to_s` appended to an
    # unguarded `Array` ran in parallel and lost appends (8,095 to 8,100 of
    # 8,102 on four workers, Linux; `bench/spawn_fuzz.py` seed 27). std's
    # own state is still std's to keep safe: only the defs it calls that
    # are not its own come out. Kept per def, since every block that
    # prints goes through the same few. `IYI_SPAWN_BROKEN=callbacks`
    # answers none, the walk as it was.
    private def exits_of(std_def : Def) : Array(Def)
      @exits.fetch(std_def) do
        exits = [] of Def
        unless SPAWN_BROKEN.includes?("callbacks")
          visited = Set(Def).new.compare_by_identity
          visited << std_def
          queue = Deque(Def).new
          queue << std_def
          while a_def = queue.shift?
            facts = facts_of(a_def)
            facts.calls.each { |target| exits << target if visited.add?(target) }
            facts.std_calls.each { |target| queue << target if visited.add?(target) }
          end
        end
        @exits[std_def] = exits
      end
    end

    # A def read from an artifact with no body under it: the module's
    # machine code is elsewhere, and so is what it reaches. Not an
    # `abstract def`, whose answers are the overrides a call reaches too.
    # `IYI_SPAWN_BROKEN=headers` reads it as the body it lacks, which
    # reaches nothing: the walk as it was before artifacts recorded it.
    private def header?(a_def : Def) : Bool
      a_def.iyi_from_artifact? && a_def.body.is_a?(Nop) && !a_def.abstract? && !SPAWN_BROKEN.includes?("headers")
    end

    NONE = [] of IyiMod::ReachRecord

    # What *a_def*, read from an artifact, reaches as the artifact said:
    # nothing when its artifact has the section and no record for it, and
    # one record naming the module, with no *kind*, when its artifact has
    # no section at all.
    private def remote_of(a_def : Def) : Array(IyiMod::ReachRecord)
      file = a_def.location.try(&.original_artifact)
      if file && (module_name = @program.iyi_artifacts_without_reaches[file]?)
        return [IyiMod::ReachRecord.new(ShareReach.called(a_def), "", "", "", "", [] of String, "", module_name)]
      end
      @program.iyi_artifact_reaches[ShareReach.reach_key(a_def)]? || NONE
    end

    # A function as a typed call to it names it in every program: the type
    # that declares it, as both sides print it, and its name without a
    # named-argument expansion's suffix. Overloads and instantiations share
    # one, so what one reaches is said of all, which may keep a spawn in
    # its unit that the source build would not and never the other way.
    def self.reach_key(a_def : Def) : String
      owner = a_def.original_owner? || a_def.owner
      "#{owner}##{a_def.name.split(':').first}"
    end

    # The `Reaches` section of the artifact for the module written in
    # *file* (SPEC.md III.4.15): for each function this build typed there,
    # what it reaches that is not safe for every thread of every program
    # importing the module. State under a claim that holds in every such
    # program (`ReachProof#robust?`) is left out; under one proven only
    # for this program, it is recorded, saying so.
    def summarise(file : String) : Array(IyiMod::ReachRecord)
      records = [] of IyiMod::ReachRecord
      recorded = Set({String, String, String}).new
      instances_in(file).each do |a_def|
        next if a_def.iyi_from_artifact?
        key = ShareReach.reach_key(a_def)
        own = facts_of(a_def)
        seen = Set(UInt64).new
        found = [] of Found
        own.named.each { |named| found << Found.new(named, [] of Def) if seen.add?(named.key) }
        found.concat walk(own, seen)
        found.each do |entry|
          record = summary_record(key, entry, file)
          records << record if record && recorded.add?({key, record.module_name, record.label})
        end
      end
      # In one order whatever order this build typed them in, since the
      # interface hash is over them.
      records.sort_by! { |record| {record.function, record.module_name, record.label} }
    end

    # One found thing as the record *key*'s function keeps: nil for state
    # that is Share or claimed safe for every importer.
    # `IYI_SPAWN_BROKEN=robust` takes every claim this build proved as one
    # that holds for every importer.
    private def summary_record(key : String, entry : Found, file : String) : IyiMod::ReachRecord?
      steps = entry.path.map { |target| ShareReach.called(target) }
      case named = entry.named
      in IyiMod::ReachRecord
        named.copy_with(function: key, path: steps + named.path)
      in Named
        state = named.state
        robust = @program.iyi_reach_robust.includes?(state.object_id) || SPAWN_BROKEN.includes?("robust")
        return nil if state.iyi_safe_reach && robust
        why = Iyi::Share.reason(named.type, file)
        return nil unless why
        if state.iyi_safe_reach
          why = "#{why}; its @[SafeReach] is proven for the program that wrote this artifact and not for every program importing the module: it is written outside the module's initialiser, named outside the module, or answered by a function"
        end
        declared = named.declared
        declared_file = declared.try { |at| (at.expanded_location || at).filename }.as?(String)
        owner = declared_file.try { |path| @program.iyi_module_paths[path]? } ||
                @program.iyi_artifact_module_at(declared) || ""
        kind = state.is_a?(Const) ? "the constant" : "the class variable"
        IyiMod::ReachRecord.new(key, named.label, named.type.to_s, kind, named.use, steps, why, owner)
      end
    end

    # Every def instance this build typed whose def is written in *file*,
    # a macro's by where the macro was called: every one an artifact's
    # object code may hold, since a block-taking one, which no type keeps,
    # travels as its body (SPEC.md IV.1g). Indexed once per build.
    private def instances_in(file : String) : Array(Def)
      index = @instances ||= begin
        by_file = {} of String => Array(Def)
        seen = Set(UInt64).new
        collect_instances(@program, by_file, seen)
        @program.file_modules.each_value { |file_module| collect_instances(file_module, by_file, seen) }
        by_file
      end
      index[file]? || [] of Def
    end

    @instances : Hash(String, Array(Def))?

    private def collect_instances(type : Type, by_file : Hash(String, Array(Def)), seen : Set(UInt64)) : Nil
      if type.is_a?(NamedType) || type.is_a?(Program) || type.is_a?(FileModule)
        type.types?.try &.each_value { |inner| collect_instances(inner, by_file, seen) }
      end
      if type.is_a?(GenericType)
        type.each_instantiated_type { |instance| collect_instances(instance, by_file, seen) }
      end
      collect_instances(type.metaclass, by_file, seen) if type.metaclass != type
      return unless type.is_a?(DefInstanceContainer)
      type.def_instances.each_value do |instance|
        next unless seen.add?(instance.object_id)
        at = instance.location
        written = (at.try(&.expanded_location) || at).try(&.filename)
        (by_file[written] ||= [] of Def) << instance if written.is_a?(String)
      end
    end

    # A def of std or the prelude is read for its calls alone: what it
    # names is std's to keep safe.
    private def facts_of(a_def : Def) : Facts
      @facts[a_def] ||= scan(a_def.body, names: walks?(a_def))
    end

    private def scan(body : ASTNode, names : Bool = true) : Facts
      scanner = Scanner.new(self, names)
      body.accept scanner
      Facts.new(scanner.named, scanner.calls, scanner.std_calls)
    end

    # The reason `@[SafeReach("...")]` or `@[UnsafeReach("...")]` on a
    # constant or a class variable gives: one string with something in it,
    # since the reason is the claim, and a bare mark would document nothing.
    def self.claim(ann : Annotation, what : String) : String
      reason = ann.args.first?
      unless ann.args.size == 1 && ann.named_args.nil? && reason.is_a?(StringLiteral) && !reason.value.blank?
        name = ann.path.names.last
        ann.raise "#{name} takes one string, the reason every thread may reach #{what} through a call: `@[#{name}(\"set once at startup, then only read\")]`"
      end
      reason.value
    end

    # The def as a path names it: `ask`, `Model.find`, `Pool#checkout`. A
    # function of an iyi module (`module main`) by its bare name, which is
    # how its own module and an import write it.
    def self.called(a_def : Def) : String
      owner = a_def.owner
      name = a_def.name.split(':').first
      type = owner.metaclass? ? owner.instance_type : owner
      return name if type.is_a?(Program) || type.is_a?(FileModule) || (owner.metaclass? && type.iyi_unit?)
      short = type.to_s.split('(').first.split("::").last
      owner.metaclass? ? "#{short}.#{name}" : "#{short}##{name}"
    end

    # Whether the walk goes into *a_def*: one written in the program or a
    # package.
    def walks?(a_def : Def) : Bool
      !std?(a_def)
    end

    # Whether *node* was written in std or the prelude: in a directory, or
    # under one, that holds `iyi/prelude.iyi`, which is where every module
    # of iyi's own library sits beside the prelude (`src/std/http.iyi`,
    # `src/iyi/prelude.iyi`). Read off the file rather than off the
    # directory the prelude was required from (`Program#iyi_prelude_dir`):
    # under `bin/iyi` that prefix matched none of std's files as the defs'
    # locations spell them, and the walk entered std's own `Server.serve`.
    def std?(node : ASTNode) : Bool
      std_at?(node.location)
    end

    # Whether *location* is in std or the prelude, as `std?` reads it.
    def std_at?(location : Location?) : Bool
      file = location.try(&.original_filename)
      return false unless file
      @std_files.fetch(file) do
        @std_files[file] = std_dir?(File.dirname(File.expand_path(file)))
      end
    end

    # The package whose checkout holds *location*'s file, as `{module
    # path, file inside the checkout}` (`{"github.com/iyilang/db",
    # "db/core.iyi"}`), from the program's requirements (*table*,
    # `Program#iyi_mod_table`, absolute directories, a replacement's too);
    # nil for a file of the program's own. The warning says it, since a
    # dependency's constant is fixed in the dependency: iyiturkiye's 1251
    # warnings on Linux were 1057 about iyi-pg's, iyi-db's and iyi-web's
    # constants, two of them `TLS_VERSIONS` and `DECODERS`, which read as
    # std's with nothing to say whose they were.
    def package_at(location : Location?, table : Array({String, String})) : {String, String}?
      file = location.try(&.original_filename)
      return nil unless file
      @packages.fetch(file) do
        path = ::Path[File.expand_path(file)].to_posix.to_s
        row = table.find do |(prefix, dir)|
          !prefix.starts_with?(Mod::Installer::SHORT_NAME) && path.starts_with?(checkout_root(dir))
        end
        @packages[file] = row.try { |(prefix, dir)| {prefix, path[checkout_root(dir).size..]} }
      end
    end

    private def checkout_root(dir : String) : String
      ::Path[File.expand_path(dir)].to_posix.to_s.rchop('/') + "/"
    end

    private def std_dir?(dir : String) : Bool
      @std_dirs.fetch(dir) do
        parent = File.dirname(dir)
        @std_dirs[dir] = File.file?(File.join(dir, "iyi", "prelude.iyi")) || (parent != dir && std_dir?(parent))
      end
    end

    # One body's facts: every constant and class variable it names, once
    # each (none for std's, *names* false), every def it calls that the
    # walk enters, and every def of std it calls. Macro code and the nodes
    # the typer expanded are read as their expansions, the blocks given to
    # calls as part of the body, and a proc's body too, since the block may
    # call it.
    class Scanner < Visitor
      getter named = [] of Named
      getter calls = [] of Def
      getter std_calls = [] of Def

      def initialize(@reach : ShareReach, @names : Bool = true)
        @keys = Set(UInt64).new
        @defs = Set(Def).new.compare_by_identity
      end

      def visit(node : Call) : Bool
        if expanded = node.expanded
          expanded.accept self
          return false
        end
        node.target_defs.try &.each do |target|
          next unless @defs.add?(target)
          (@reach.walks?(target) ? @calls : @std_calls) << target
        end
        case obj = node.obj
        when Path
          if (const = obj.target_const) && (type = obj.type?)
            note(const, obj.to_s, type, "#{obj}.#{node.name}", obj.location)
          end
        when ClassVar
          if (var = obj.var?) && !var.thread_local? && (type = var.type?)
            note(var, obj.name, type, "#{obj.name}.#{node.name}", obj.location)
          end
        end
        true
      end

      def visit(node : Path) : Bool
        if (const = node.target_const) && (type = node.type?)
          note(const, node.to_s, type, node.to_s, node.location)
        end
        false
      end

      def visit(node : ClassVar) : Bool
        if (var = node.var?) && !var.thread_local? && (type = var.type?)
          note(var, node.name, type, node.name, node.location)
        end
        false
      end

      def visit(node : ProcLiteral) : Bool
        node.def.body.accept self
        false
      end

      def visit(node : ProcPointer) : Bool
        node.expanded.try &.accept self
        false
      end

      def visit(node : ExpandableNode) : Bool
        if expanded = node.expanded
          expanded.accept self
          return false
        end
        true
      end

      # Not run: what `typeof` asks about is a type, and a nested
      # definition is not this body's code.
      def visit(node : TypeOf | Def | Macro | LibDef | AnnotationDef) : Bool
        false
      end

      def visit(node : ASTNode) : Bool
        true
      end

      # A constant std declares is std's to keep safe, as its defs are:
      # `STDOUT.puts` in a function a parallel block called warned that
      # `STDOUT : IyiIO` is not Share while `puts`, which writes the same
      # stream from inside std, said nothing. Read off the constant's
      # declaration, which is where it was written whatever the cleanup
      # makes of its value.
      private def note(state : Const | MetaTypeVar, label : String, type : Type, use : String, at : Location?) : Nil
        return unless @names && @keys.add?(state.object_id)
        named = Named.new(state, label, type, use, at)
        @named << named unless state.is_a?(Const) && @reach.std_at?(named.declared)
      end
    end
  end
end
