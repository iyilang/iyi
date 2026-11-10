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

  # iyi: the module state a parallel unit reaches through the defs it calls
  # (SPEC.md III.4.5). `CleanupTransformer#check_share_boundary` refuses
  # what the block names in its own text; a constant read one call away was
  # not seen, and that is where a program keeps its database pool: a
  # parallel block calling `ask`, which ran `DATABASE.query_one`, compiled
  # silently and at 12 workers answered other requests' rows (#148). This
  # walks the typed call graph from the block and lists every constant and
  # class variable met on the way, each with the shortest path of defs that
  # reaches it; the boundary check refuses those whose type is not Share
  # and that no proven `@[SafeReach]` covers.
  #
  # The walk covers std and the prelude as it covers the program and its
  # packages: a unit that prints reaches `STDOUT` as surely as one that asks
  # reaches `DATABASE`, and a unit's heap (III.4.19) is broken by std's
  # state as by the program's. It stops where the capture check does: a
  # constant typed `Mutex`, `Atomic`, `List` or another trusted `@[Share]`
  # type is Share, and is not refused. A block given to a lock
  # (`MUTEX.lock { ask }`) is walked like any other: the lock guards what it
  # holds, not the constants the block reaches. Every target of a call is
  # walked, so a virtual call reaches each override, and a def met twice,
  # by recursion or by two paths, is walked once.
  #
  # A proc call is followed to the literals it may run, and only to those
  # (R6, local://heap22-h1rescue.md): a literal is reached by the code that
  # makes it, since its body is read as part of that code. A def calling
  # its own parameter adds nothing more - the literal behind it was made, or
  # handed on, by the code that called the def, which reaches it. A literal
  # made in a def that calls one of the def's parameters reaches what the
  # parameter is bound to: the literals handed to it at every call, through
  # forwarded parameters. A call that hands a def a proc it did not make
  # and did not get as a parameter reaches every literal of that proc's
  # type, and so does a call of any other proc (one read from a field or
  # answered by a call). The runtime's own dispatch is not followed:
  # `IyiDeferNode#run`, the fiber trampoline and the spawn verbs run a proc
  # in the unit that handed it over or in a unit of its own, which is a
  # parallel block of its own (`DROPPED`); followed by type, the fiber
  # trampoline's `Proc(Nil)` reached every route of a server.
  # `IYI_SPAWN_BROKEN=creation` reads no kept literal as the code of its
  # maker and follows no proc handed on, `allruntime` follows no proc call
  # std or the prelude makes - `Hash#[]`'s default block included - and
  # `captured` binds no parameter a literal captures: each a copy
  # `bench/reach_rule.sh` catches.
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

    # A proc call in a body: of a parameter of *home*, the def the body is
    # in, from inside a literal made there (*param*), or of any other proc
    # of *type*. A def's call of its own parameter is not kept.
    record ProcCall, type : Type, home : Def? = nil, param : String? = nil

    # A proc a call hands a def's parameter (*param*; nil when a splat
    # hides which): a literal made at the call, or the caller's own
    # parameter *from*, forwarded, or else any proc of *type*. *defer* is
    # a literal or a type handed to `IyiDeferNode.new` outside the runtime.
    record Arg, target : Def, param : String?, literal : Def? = nil, from : {Def, String}? = nil, type : Type? = nil, defer : Bool = false

    # What one body names, the defs it calls, the proc calls it makes, the
    # procs it hands on that it did not make (nil: an `IyiDeferNode`), and
    # whether its proc calls are the runtime's dispatch (`DROPPED`).
    record Facts, named : Array(Named), calls : Array(Def), procs : Array(ProcCall), passes : Array(Type?), dropped : Bool

    # A named thing the walk found, and the defs that lead to it from the
    # block: the first is one the block calls, the last the one naming it.
    # Or what a function read from an artifact reaches, as its artifact
    # recorded it, the last def being that function; a record with an
    # empty *kind* says the artifact recorded nothing (`remote_of`).
    record Found, named : Named | IyiMod::ReachRecord, path : Array(Def)

    # The program's typed top level, set before the cleanup: where the
    # index of literals and bindings starts.
    property main : ASTNode?

    def initialize(@program : Program)
      @facts = {} of Def => Facts
      @facts.compare_by_identity
      @std_files = {} of String => Bool
      @std_dirs = {} of String => Bool
      @packages = {} of String => {String, String}?
      @literals = {} of Type => Array(Def)
      @literal_home = {} of Def => {Def?, Array(String)}
      @literal_home.compare_by_identity
      @args = [] of Arg
      @bindings = {} of {UInt64, String} => {Set(Def), Set(Type)}
      @open = Set(UInt64).new
      @assigned = {} of UInt64 => Set(String)
      @defer_literals = [] of Def
      @defer_types = Set(Type).new
    end

    @indexed = false

    # Everything the block whose body is *block_def*'s reaches through the
    # defs it calls, each once, by the shortest path (fewest defs; the
    # first written among equals). What the block names in its own text is
    # left out: the boundary check asks about that, and refuses it.
    def reach(block_def : Def) : Array(Found)
      index
      start = facts_of(block_def)
      seen = Set(UInt64).new
      start.named.each { |named| seen << named.key }
      walk(start, seen)
    end

    # The walk from what *start* calls, past what *seen* holds. A function
    # read from an artifact has no body here (SPEC.md IV.1g): what it
    # reaches is what its artifact recorded when the body was there, and
    # the walk does not go past it. Each def met keeps the one it was met
    # from, so a path is built only for what is found.
    private def walk(start : Facts, seen : Set(UInt64)) : Array(Found)
      remote = Set({String, String}).new
      parent = {} of Def => Def?
      parent.compare_by_identity
      queue = Deque(Def).new
      enqueue(start, nil, parent, queue)
      found = [] of Found
      while a_def = queue.shift?
        if header?(a_def)
          remote_of(a_def).each do |record|
            found << Found.new(record, path_to(a_def, parent)) if remote.add?({record.module_name, record.label})
          end
          next
        end
        facts = facts_of(a_def)
        facts.named.each do |named|
          found << Found.new(named, path_to(a_def, parent)) if seen.add?(named.key)
        end
        enqueue(facts, a_def, parent, queue)
      end
      found
    end

    private def path_to(a_def : Def, parent : Hash(Def, Def?)) : Array(Def)
      path = [a_def]
      while step = parent[path.last]?
        path << step
      end
      path.reverse!
    end

    private def enqueue(facts : Facts, from : Def?, parent : Hash(Def, Def?), queue : Deque(Def)) : Nil
      add = ->(target : Def) do
        unless parent.has_key?(target)
          parent[target] = from
          queue << target
        end
        nil
      end
      facts.calls.each do |target|
        next if SPAWN_BROKEN.includes?("callbacks") && std?(target)
        add.call(target)
      end
      return if facts.dropped || SPAWN_BROKEN.includes?("creation")
      facts.procs.each do |call|
        home = call.home
        param = call.param
        if home && param
          bound(home, param) { |literal| add.call(literal) }
        else
          @literals[call.type]?.try &.each { |literal| add.call(literal) }
        end
      end
      facts.passes.each { |type| passed(type) { |literal| add.call(literal) } }
    end

    # The literals a proc handed on may be: every literal of *type*, or
    # (nil) every literal an `IyiDeferNode` may hold.
    private def passed(type : Type?, & : Def ->) : Nil
      if type
        @literals[type]?.try &.each { |literal| yield literal }
      else
        @defer_literals.each { |literal| yield literal }
        @defer_types.each { |defer_type| @literals[defer_type]?.try &.each { |literal| yield literal } }
      end
    end

    # The literals *home*'s parameter *param* may be bound to. A def whose
    # parameters a call may fill unseen - a splat's, an implicit `super`'s -
    # has them bound to every literal of the proc's type. A `@[Share]`
    # def's block is bound to none: every block given to it is a parallel
    # block of its own, checked where it is given.
    private def bound(home : Def, param : String, & : Def ->) : Nil
      return if home.iyi_share_block? && home.block_arg.try(&.name) == param
      return if SPAWN_BROKEN.includes?("captured")
      if @open.includes?(home.object_id)
        types = home.args.select(&.name.==(param)).compact_map(&.type?)
        home.block_arg.try { |arg| arg.type?.try { |type| types << type } if arg.name == param }
        types.each do |type|
          concrete(type) { |member| passed(member) { |literal| yield literal } if member.is_a?(ProcInstanceType) }
        end
        return
      end
      binding = @bindings[{home.object_id, param}]?
      return unless binding
      binding[0].each { |literal| yield literal }
      binding[1].each { |type| passed(type) { |literal| yield literal } }
    end

    # Each member of *type*: a union's, or the type itself.
    def concrete(type : Type, & : Type ->) : Nil
      if type.is_a?(UnionType)
        type.union_types.each { |member| yield member }
      else
        yield type
      end
    end

    # Every literal of the program by its type, where each was made, and
    # what each def's proc parameters are bound to: read once, from the
    # typed top level through every def it may call, before the first walk.
    private def index : Nil
      return if @indexed
      @indexed = true
      queue = Deque(Def).new
      seen = Set(Def).new.compare_by_identity
      visit = ->(facts : Facts) do
        facts.calls.each { |target| queue << target if seen.add?(target) }
        nil
      end
      @main.try { |main| visit.call(scan(main, nil, 0, [] of String)) }
      @program.class_var_initializers.each { |initializer| visit.call(scan(initializer.node, nil, 0, [] of String)) }
      @program.const_initializers.each { |const| visit.call(scan(const.value, nil, 0, [] of String)) }
      while a_def = queue.shift?
        next if header?(a_def)
        visit.call(facts_of(a_def))
      end
      resolve
    end

    # Each parameter's bindings: the literals made at its calls, the types
    # of the other procs handed to it, and through a forwarded parameter
    # what that one is bound to.
    private def resolve : Nil
      forwards = {} of {UInt64, String} => Array({UInt64, String})
      @args.each do |arg|
        if arg.defer
          if literal = arg.literal
            @defer_literals << literal
          elsif type = arg.type
            @defer_types << type
          end
          next
        end
        param = arg.param
        next unless param
        key = {arg.target.object_id, param}
        if from = arg.from
          (forwards[{from[0].object_id, from[1]}] ||= [] of {UInt64, String}) << key
          next
        end
        binding = @bindings[key] ||= {Set(Def).new.compare_by_identity, Set(Type).new}
        arg.literal.try { |literal| binding[0] << literal }
        arg.type.try { |type| binding[1] << type }
      end
      @args.clear
      queue = Deque({UInt64, String}).new
      forwards.each_key { |from| queue << from }
      while from = queue.shift?
        source = @bindings[from]?
        next unless source
        forwards[from]?.try &.each do |to|
          into = @bindings[to] ||= {Set(Def).new.compare_by_identity, Set(Type).new}
          before = into[0].size + into[1].size
          into[0].concat(source[0])
          into[1].concat(source[1])
          queue << to if into[0].size + into[1].size != before
        end
      end
    end

    # Noted by the scanner as it reads a body: a literal made there, with
    # the def it is made in and the names bound around it.
    def note_literal(literal : Def, type : Type?, home : Def?, bound : Array(String)) : Nil
      return if @literal_home.has_key?(literal)
      @literal_home[literal] = {home, bound + literal.args.map(&.name)}
      (@literals[type] ||= [] of Def) << literal if type.is_a?(ProcInstanceType)
    end

    def note_arg(arg : Arg) : Nil
      @args << arg
    end

    def note_open(target : Def) : Nil
      @open << target.object_id
    end

    # Whether *name* is a parameter of *a_def* its body never assigns, so
    # what a call of it runs is what the def was handed.
    def param?(a_def : Def, name : String) : Bool
      return false unless a_def.args.any?(&.name.==(name)) || a_def.block_arg.try(&.name) == name
      assigned = @assigned.fetch(a_def.object_id) do
        scan = Assigned.new
        a_def.body.accept scan
        @assigned[a_def.object_id] = scan.names
      end
      !assigned.includes?(name)
    end

    # The runtime's proc calls the walk does not follow, by the file and
    # the def they are in (a literal's: the def that makes it): each runs a
    # proc the unit running it handed over (a `defer`'s, a test's block, a
    # constant's initializer), or one that runs as a unit or a thread of
    # its own (the fiber trampoline, the spawn verbs, a thread's body). And
    # `SharedProc#call`, whose proc is only ever a block `SharedProc.of`
    # was given, a parallel block of its own. The runtime's other proc
    # calls - a `Hash`'s default block, the stack maker, the collector's
    # visitors - run a proc kept and called by whichever unit asks, and are
    # followed.
    DROPPED = {
      {"prelude.iyi", "run"}, {"thread.iyi", "run"}, {"concurrency.iyi", "run_spawned_fiber"},
      {"concurrency.iyi", "spawn"}, {"concurrency.iyi", "in_unit"}, {"concurrency.iyi", "pooled"},
      {"concurrency.iyi", "on_main"}, {"concurrency.iyi", "on_pool"}, {"concurrency.iyi", "spawn_new"},
      {"concurrency.iyi", "spawn_pooled"}, {"concurrency.iyi", "crossing_task"}, {"concurrency.iyi", "unit_work"},
      {"testing.iyi", "test"}, {"testing.iyi", "assert_panics"}, {"shared_proc.iyi", "call"},
    }

    def dropped?(home : Def?) : Bool
      return false unless home
      location = home.location
      file = location.try(&.original_filename)
      return false unless file && std_at?(location)
      return true if SPAWN_BROKEN.includes?("allruntime")
      DROPPED.includes?({File.basename(file), home.name.split(':').first})
    end

    # The names a body assigns, so a parameter it assigns is not read as
    # what the def was handed.
    class Assigned < Visitor
      getter names = Set(String).new

      def visit(node : Assign) : Bool
        target = node.target
        @names << target.name if target.is_a?(Var)
        true
      end

      def visit(node : MultiAssign) : Bool
        node.targets.each { |target| @names << target.name if target.is_a?(Var) }
        true
      end

      def visit(node : ASTNode) : Bool
        true
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
      index
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

    # A def's body, read with its parameters as its own; a literal's, read
    # standalone when a proc call or a binding reaches it, with the def it
    # was made in and the names bound around it.
    private def facts_of(a_def : Def) : Facts
      @facts[a_def] ||= begin
        if made = @literal_home[a_def]?
          scan(a_def.body, made[0], 1, made[1])
        else
          scan(a_def.body, a_def, 0, [] of String)
        end
      end
    end

    private def scan(body : ASTNode, home : Def?, depth : Int32, bound : Array(String)) : Facts
      scanner = Scanner.new(self, home, depth, bound)
      body.accept scanner
      Facts.new(scanner.named, scanner.calls, scanner.procs, scanner.passes, dropped?(home))
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
      if a_def.name == "->"
        return "the block at #{a_def.location.try { |at| "#{File.basename((at.expanded_location || at).filename.to_s)}:#{(at.expanded_location || at).line_number}" }}"
      end
      owner = a_def.owner
      name = a_def.name.split(':').first
      type = owner.metaclass? ? owner.instance_type : owner
      return name if type.is_a?(Program) || type.is_a?(FileModule) || (owner.metaclass? && type.iyi_unit?)
      short = type.to_s.split('(').first.split("::").last
      owner.metaclass? ? "#{short}.#{name}" : "#{short}##{name}"
    end

    # Whether *location* is in the prelude's own directory (`src/iyi`), the
    # runtime's, rather than merely under std's.
    def prelude_at?(location : Location?) : Bool
      file = location.try(&.original_filename)
      return false unless file
      @prelude_files.fetch(file) do
        @prelude_files[file] = File.file?(File.join(File.dirname(File.expand_path(file)), "prelude.iyi"))
      end
    end

    @prelude_files = {} of String => Bool

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
    # each, every def it calls, the proc calls it makes and the procs it
    # hands on that it did not make. Macro code and the nodes the typer
    # expanded are read as their expansions, the blocks given to calls as
    # part of the body, and a proc's body too: the code that makes a
    # literal reaches it. *home* is the def the body is in (nil at the top
    # level), *depth* how many literals deep the scan is - a literal read
    # standalone starts at 1 - and *bound* the names the literals and
    # blocks around it bind, which shadow the def's parameters.
    class Scanner < Visitor
      getter named = [] of Named
      getter calls = [] of Def
      getter procs = [] of ProcCall
      getter passes = [] of Type?

      def initialize(@reach : ShareReach, @home : Def?, @depth : Int32, @bound : Array(String))
        @keys = Set(UInt64).new
        @defs = Set(Def).new.compare_by_identity
        @bound = @bound.dup
      end

      def visit(node : Call) : Bool
        if expanded = node.expanded
          expanded.accept self
          return false
        end
        node.target_defs.try &.each do |target|
          if (body = target.body).is_a?(Primitive) && body.name == "proc_call"
            proc_call(node, target)
            next
          end
          @calls << target if @defs.add?(target)
          hands(node, target)
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

      # A call of the def's own parameter adds nothing; of one captured by
      # a literal made in the def, what the parameter is bound to; of any
      # other proc, every literal of its type.
      private def proc_call(node : Call, target : Def) : Nil
        type = target.owner
        if (name = own_param(node.obj))
          @procs << ProcCall.new(type, @home, name) if @depth > 0
          return
        end
        @procs << ProcCall.new(type)
      end

      # The parameter of the def around the scan that *exp* reads, unless
      # a literal or a block around it binds the name itself.
      private def own_param(exp : ASTNode?) : String?
        home = @home
        return nil unless home && exp.is_a?(Var)
        name = exp.name
        return nil if @bound.includes?(name)
        @reach.param?(home, name) ? name : nil
      end

      # What procs the call hands *target*: a literal made at the call is
      # this body's, and binds the parameter; the def's own parameter is
      # forwarded; any other proc may be any literal of its type, and the
      # call reaches them all.
      private def hands(node : Call, target : Def) : Nil
        splat = !target.splat_index.nil? || !target.double_splat.nil? || node.args.any? { |arg| arg.is_a?(Splat) || arg.is_a?(DoubleSplat) }
        implicit = (node.name == "super" || node.name == "previous_def") && node.args.empty? && !target.args.empty?
        @reach.note_open(target) if splat || implicit
        defer = target.name == "new" && (owner = target.owner).metaclass? && owner.instance_type.to_s == "IyiDeferNode" &&
                !@reach.prelude_at?(@home.try(&.location))
        node.args.each_with_index do |arg, index|
          hand(target, splat ? nil : target.args[index]?.try(&.name), arg, defer)
        end
        node.named_args.try &.each do |named|
          hand(target, target.args.find(&.external_name.==(named.name)).try(&.name), named.value, defer)
        end
        if block_arg = node.block_arg
          hand(target, target.block_arg.try(&.name), block_arg, defer)
        elsif (block = node.block) && (literal = block.fun_literal).is_a?(ProcLiteral)
          @reach.note_arg(Arg.new(target, target.block_arg.try(&.name), literal: literal.def))
        end
      end

      private def hand(target : Def, param : String?, arg : ASTNode, defer : Bool) : Nil
        if arg.is_a?(ProcLiteral)
          @reach.note_arg(Arg.new(target, param, literal: arg.def, defer: defer))
          return
        end
        type = arg.type?
        return unless type
        @reach.concrete(type) do |member|
          if member.is_a?(ProcInstanceType)
            if !defer && (name = own_param(arg))
              @reach.note_arg(Arg.new(target, param, from: {@home.not_nil!, name}))
            else
              @reach.note_arg(Arg.new(target, param, type: member, defer: defer))
              @passes << member unless defer
            end
          elsif member.to_s == "IyiDeferNode"
            @passes << nil
          end
        end
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
        @reach.note_literal(node.def, node.type?, @home, @bound)
        return false if SPAWN_BROKEN.includes?("creation")
        inside(node.def.args.map(&.name), true) { node.def.body.accept self }
        false
      end

      # A block's body is this body's code; a block the call keeps (one
      # made a literal) runs later, as a literal.
      def visit(node : Block) : Bool
        literal = node.fun_literal
        kept = literal.is_a?(ProcLiteral)
        if literal.is_a?(ProcLiteral)
          @reach.note_literal(literal.def, literal.type?, @home, @bound)
          return false if SPAWN_BROKEN.includes?("creation")
        end
        inside(node.args.map(&.name), kept) { node.body.accept self }
        false
      end

      private def inside(names : Array(String), literal : Bool, &) : Nil
        @bound.concat(names)
        @depth += 1 if literal
        yield
        @depth -= 1 if literal
        @bound.pop(names.size)
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

      private def note(state : Const | MetaTypeVar, label : String, type : Type, use : String, at : Location?) : Nil
        return unless @keys.add?(state.object_id)
        @named << Named.new(state, label, type, use, at)
      end
    end
  end
end
