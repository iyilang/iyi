require "../syntax/ast"
require "../syntax/visitor"
require "../types"

module Iyi
  # iyi: one `@[SafeReach("why")]` or `@[UnsafeReach("why")]` on a constant
  # or a class variable: the state, how messages spell it, the reason, the
  # annotation (where a refusal is reported) and whether it is the unsafe
  # spelling (SPEC.md III.4.4).
  record ReachClaim, state : Const | MetaTypeVar, label : String, reason : String, annotation : Annotation, unsafe : Bool do
    def unsafe? : Bool
      unsafe
    end

    def type? : Type?
      state = self.state
      state.is_a?(Const) ? state.value.type? : state.type?
    end
  end

  class Program
    # Every reach claim, once per state, in the order they were met.
    getter iyi_reach_claims = [] of ReachClaim

    def iyi_reach_claim?(state : Const | MetaTypeVar) : ReachClaim?
      @iyi_reach_claims.find(&.state.same?(state))
    end

    def iyi_claim_reach(claim : ReachClaim) : Nil
      @iyi_reach_claims << claim unless iyi_reach_claim?(claim.state)
    end
  end

  # iyi: `@[SafeReach("why")]` proven, not trusted (SPEC.md III.4.4). The
  # mark quiets the reach warning for its state and lets a spawn that
  # reaches it run in parallel (III.4.15), so it is a claim that every
  # thread may reach the state safely; until this was built nothing checked
  # it, and `bench/parallel_exercise.sh` carried a constant whose one method
  # assigned a field from two parallel tasks under the claim that one task
  # asked. The claim is accepted when one of three things holds:
  #
  # (a) the state's type is `Share`: an `Atomic`, a `Mutex`, a `Channel`, a
  #     `List` or a value nothing writes once it is made;
  # (b) every write to it is behind one lock the compiler can name - the
  #     block of a `Mutex#lock` (or another method of an owning type) whose
  #     receiver is a constant or a class variable, or a bracket
  #     `IyiSchedLock.lock ... IyiSchedLock.unlock` (or `IyiRuntimeLock`'s)
  #     written in the prelude - and so is every read that may run once a
  #     parallel task can, since a write behind a lock is no protection to
  #     a reader beside it;
  # (c) every write comes before the first parallel task can start: in the
  #     program's top-level code, a module's initialiser included, before
  #     the first statement that may start one, and in the defs only such
  #     code calls.
  #
  # Anything else refuses the annotation, naming a write that breaks it and
  # where that write may run from.
  #
  # What is a write is decided through std and the prelude too, because
  # `Array#<<` writes its receiver only by way of `Pointer#[]=`: whether a
  # def may write or let escape its receiver or a parameter - an instance
  # variable assigned, an address taken, memory set through a pointer, a
  # value stored there or in a field, a value handed to a C function - is
  # a reachability from the bodies that do so directly, through every
  # call that passes the value on. It is read only from where claimed
  # state is: the callables that name it or call one that answers it, and
  # the callees they hand it to, slot by slot (`analyze`). A value derived
  # from the state - read from it by a call whose answer is not `Share`,
  # held in a local, yielded to a block, answered by a def that answers
  # the state - is the state, so `kept = Pairs.kept; kept << pair` is a
  # write as `@@kept << pair` is. A `Share` value is never followed: what
  # an `Atomic` or a `Mutex` does to itself is synchronised. A proc call
  # reaches every block and proc literal of its type in the program, and
  # a literal that answers claimed state hands it on where it is written.
  #
  # Where a write runs is the other half: each def's contexts - before the
  # first parallel task, behind which lock, or anywhere - are the union of
  # its callers', and a block kept to run later (a captured block, a proc)
  # runs anywhere, as does the block a parallel task runs. A call the walk
  # cannot place is anywhere. This half reads every callable the program
  # may run, once, for its calls alone.
  #
  # The walk runs only when the program has a `SafeReach` on state whose
  # type is not `Share`; every other program pays nothing. On a small
  # server with three claims it takes 0.10 s and 15 MB of RSS beside a
  # 1.9 to 2.3 s check, and on iyi-web's `examples/security.iyi` given
  # two claims 0.10 to 0.11 s and 20 MB beside 2.5 to 2.7 s (`--stats`,
  # three runs each, Linux). Before the writes were read only from where
  # the state is, and before `Share` was asked only of what a type
  # declares, the first took 3.9 s and 3.5 GB.
  class ReachProof
    enum RootKind
      # The receiver (slot 0), a parameter (slot n) of the callable, or the
      # value of the block it is given (slot -1, what a `yield` answers).
      Slot
      # A claimed state.
      State
      # What a callable answers or yields, when that may be claimed state.
      Out
    end

    record Root, kind : RootKind, slot : Int32 = 0, key : UInt64 = 0_u64

    SELF = Root.new(RootKind::Slot, 0)
    # What the block a callable is given answers: what its `yield` answers.
    BLOCK_VALUE = Root.new(RootKind::Slot, -1)

    # A lock the compiler can name: the constant or class variable a
    # `Mutex#lock` is called on, or a prelude bracket's class.
    record Lock, key : UInt64, name : String

    # Why code runs where it does, innermost first: a top-level statement,
    # the block a parallel task runs, a block kept to run later, a lock's
    # block, a lock the compiler cannot name, an initializer.
    class Origin
      enum Kind
        TopLevel
        Parallel
        Stored
        Locked
        UnnamedLock
        Initializer
      end

      getter kind : Kind
      getter index : Int32
      getter lock : Lock?
      getter text : String
      # Where it was written, rendered only for a refusal.
      getter at : Location?

      def initialize(@kind : Kind, @text : String, @index : Int32 = -1, @lock : Lock? = nil, @at : Location? = nil)
      end
    end

    # How a value reaches a write: the callable writes it itself (*how*), or
    # hands it to slot *slot* of *callee*, or to slot *slot* of every
    # literal of *proc_type*. An *escape* keeps a copy where the walk
    # cannot follow it - stored in a field or in memory, answered from a
    # proc - so whatever writes through the copy may do so anywhere,
    # later.
    record Cause, callee : Callable? = nil, slot : Int32 = 0, proc_type : Type? = nil, how : String? = nil, escape : Bool = false

    # One place a body may write a root: what the root is, why, the
    # expression as written and what it does with the root (*suffix*),
    # where, and the innermost origin around it.
    record Event, root : Root, cause : Cause, node : ASTNode, suffix : String, at : Location?, origin : Origin?

    # A call to *callee* written in a callable, under *origin*, in
    # top-level statement *stmt* (-1 elsewhere).
    record Site, callee : Callable, origin : Origin?, stmt : Int32

    # A proc call of *type*, for the start graph.
    record ProcSite, type : Type, stmt : Int32

    # A claimed state named in a body: a read, for (b).
    record Occurrence, key : UInt64, callable : Callable, origin : Origin?, at : Location?

    # A def, a block or proc literal, the top level, or an initializer: a
    # body and the parameters its slots stand for.
    class Callable
      getter id : Int32
      getter body : ASTNode
      getter params : Array(String)
      getter label : String
      getter a_def : Def?
      # A literal is scanned for what it writes of its parameters; its
      # body's events, sites and reads are its enclosing callable's.
      getter? literal : Bool
      getter sites = [] of Site
      getter proc_sites = [] of ProcSite
      getter events = [] of Event
      getter out_roots = Set(Root).new
      property? starts = false
      property? direct_start = false
      # The contexts it runs in: before the first parallel task, anywhere,
      # behind these locks; and the caller and origin that first made it
      # run anywhere.
      property? init = false
      property? free = false
      getter locks = [] of Lock
      property free_caller : Callable? = nil
      property free_origin : Origin? = nil
      # What `prepare` found: each local's roots, and the slots the body
      # may answer; and whether it is being prepared, which a recursion
      # back into it meets.
      property vars : Hash(String, Set(Root))? = nil
      property answered : Set(Int32)? = nil
      property? preparing = false
      property? answers_state = false
      # The top level's statements, or an initializer's origin: how the
      # body is read rather than as one expression.
      property statements : Array(ASTNode)? = nil
      property base_origin : Origin? = nil
      # It names a claimed state; `analyze` found it may answer or yield
      # one; its writes have been read.
      property? names_state = false
      property? answerer = false
      property? writes_read = false

      def initialize(@id : Int32, @body : ASTNode, @params : Array(String), @label : String, @a_def : Def?, @literal : Bool)
      end

      def reached? : Bool
        @init || @free || !@locks.empty?
      end

      # How a message names it: a def in backticks, anything else as is.
      def named : String
        @a_def ? "`#{@label}`" : @label
      end
    end

    @callables = [] of Callable
    # By identity: a def's `==` compares its text.
    @by_def = ({} of Def => Callable).compare_by_identity
    @by_node = {} of UInt64 => Callable
    @literals = {} of Type => Array(Callable)
    @queue = Deque(Callable).new
    @share = {} of Type => Bool
    @tracked = {} of UInt64 => ReachClaim
    @occurrences = [] of Occurrence
    @prelude = {} of String => Bool
    @statement_starts = [] of Bool
    # The top-level statements that never run: `if false`, which is how
    # R-2c's definition-site probes call each fully declared def once
    # (`DefinitionTyping`), prepended to the program. They are read for
    # the defs they call, so a def only a probe calls is still read, and
    # are not a start: a probe calling a def that spawns made statement 0
    # the first parallel task, and refused every claim written at module
    # init after it (`bench/spawn_fuzz.py`).
    @dead_statements = Set(Int32).new
    # For each top-level statement, the first statement at or before it
    # that may start a parallel task its module can see (`settle_starts`),
    # or `Int32::MAX`.
    @start_before = [] of Int32
    @written = Written.new
    @escaped = Written.new
    @state_out = {} of Int32 => Set(UInt64)

    def initialize(@program : Program, @root : ASTNode)
    end

    def self.run(program : Program, root : ASTNode) : Nil
      claims = program.iyi_reach_claims
      return if claims.empty?
      new(program, root).run
    end

    def run : Nil
      check_unsafe_places
      robust = @program.iyi_reach_robust
      @program.iyi_reach_claims.each do |claim|
        # An `UnsafeReach` is the author's word, and holds wherever the
        # module is imported as it does here.
        if claim.unsafe?
          robust << claim.state.object_id
          next
        end
        type = claim.type?
        next if type.nil?
        # (a), by what the type declares: nothing to walk.
        if share?(type)
          robust << claim.state.object_id
          next
        end
        @tracked[claim.state.object_id] = claim
      end
      return if @tracked.empty?

      walk
      analyze
      compute_starts
      propagate_contexts
      compute_written
      @program.iyi_reach_claims.each do |claim|
        next unless @tracked.has_key?(claim.state.object_id)
        unless refusal = refusal_of(claim)
          robust << claim.state.object_id if robust?(claim)
          next
        end
        # (a), structurally: a value nothing writes once it is made. Read
        # only for a claim the walk would refuse, since it expands every
        # macro of every def of the type and its ancestors: asked of the
        # three claims of a small server it took 55 ms, a third of the
        # proof (`--stats`, Linux).
        if (type = claim.type?) && Iyi::Share.shareable?(type)
          robust << claim.state.object_id
          next
        end
        claim.annotation.raise refusal
      end
    end

    # Whether a proven claim holds in every program that imports the
    # module declaring the state, which is what a consumer reading the
    # module's artifact has to know (SPEC.md III.4.4, III.4.15): it has the
    # module's declarations and not its bodies, and cannot prove the claim
    # again. (c) and (b) were proven of where this program's code calls the
    # module's functions from, and another program may call them from a
    # parallel task. So: every write is a statement of the module's own
    # initialiser, before any parallel task, which runs first in every
    # program; nothing keeps a copy; no function answers the state; and a
    # constant is not exported, so no other module's code names it.
    private def robust?(claim : ReachClaim) : Bool
      state = claim.state
      key = state.object_id
      at = claim.annotation.location
      file = at.try { |place| (place.expanded_location || place).filename }
      return false unless file.is_a?(String)
      if state.is_a?(Const)
        namespace = state.namespace
        return false if namespace.is_a?(ModuleType) && namespace.exported_names.try(&.includes?(state.name))
      end
      @callables.each do |callable|
        next if callable.literal?
        return false if callable.a_def && callable.answerer? && state_out(callable).includes?(key)
        callable.events.each do |event|
          next if event.root.kind.slot?
          next unless states_of(event.root).includes?(key)
          return false if fired?(event.cause, escapes: true)
          next unless fired?(event.cause, escapes: false)
          origin = event.origin
          return false unless origin && origin.kind.top_level? && before_start?(origin.index)
          written = event.at.try { |place| (place.expanded_location || place).filename }
          return false unless written == file
        end
      end
      true
    end

    # --- where UnsafeReach may be written --------------------------------

    # `@[UnsafeReach]` is the claim nothing checks, so it is kept where
    # nothing is checked already: the prelude and runtime (`src/iyi`), and
    # a file that uses `Pointer`, whose raw memory no proof covers either.
    private def check_unsafe_places : Nil
      unsafe = @program.iyi_reach_claims.select(&.unsafe?)
      return if unsafe.empty?
      pointer_files = PointerFiles.new
      @root.accept pointer_files
      unsafe.each do |claim|
        file = claim.annotation.location.try(&.original_filename)
        next if file && (prelude_file?(file) || pointer_files.files.includes?(file))
        claim.annotation.raise "@[UnsafeReach] on `#{claim.label}` is not allowed here: it is the claim the compiler takes on trust, and it is kept for the prelude and runtime (src/iyi) and for a file that already uses `Pointer`. Say @[SafeReach(\"...\")], which the compiler proves, or make the state Share - a `Mutex`, an `Atomic`, a `List` (SPEC.md III.4.4)"
      end
    end

    # The files that name `Pointer` or take an address with `pointerof`,
    # read off the program as written (def bodies are still in the tree).
    class PointerFiles < Visitor
      getter files = Set(String).new

      def visit(node : Path) : Bool
        note(node) if node.names.size == 1 && node.names.first == "Pointer"
        false
      end

      def visit(node : PointerOf) : Bool
        note(node)
        true
      end

      def visit(node : ASTNode) : Bool
        true
      end

      private def note(node : ASTNode) : Nil
        if file = node.location.try(&.original_filename)
          @files << file
        end
      end
    end

    # Whether *file* is the prelude's own: in the directory that holds
    # `prelude.iyi` (`src/iyi`), not merely beneath it as std is.
    def prelude_file?(file : String) : Bool
      @prelude.fetch(file) do
        @prelude[file] = File.file?(File.join(File.dirname(File.expand_path(file)), "prelude.iyi"))
      end
    end

    def prelude_at?(location : Location?) : Bool
      file = location.try(&.original_filename)
      !!file && prelude_file?(file)
    end

    # --- the walk ---------------------------------------------------------

    # Whether a value of *type* is not followed: Share by what its type
    # declares - a number, a string, an `@[Share]` type such as `Atomic`,
    # `Mutex`, `Channel` or `List` - and never by reading its structure.
    # The structural reading expands every macro of every def of a type's
    # ancestors, and asked of each type the walk meets it cost 3.5 GB and
    # 3.6 s on a small server (`--stats`, Linux: the proof took 3.87 s to
    # 4,069 MB RSS, then 0.31 s to 596 MB); a structurally immutable value
    # is followed instead, and nothing it reaches is written.
    def share?(type : Type) : Bool
      @share.fetch(type) { @share[type] = declared_share?(type, 0) }
    end

    # Share read in full, structure included: asked only of a value a
    # callable whose writes are read stores away, so of a few types.
    def deep_share?(type : Type) : Bool
      @deep_share.fetch(type) { @deep_share[type] = share?(type) || Iyi::Share.shareable?(type) }
    end

    @deep_share = {} of Type => Bool

    private def declared_share?(type : Type, depth : Int32) : Bool
      return false if depth > 8
      case type
      when NilType, BoolType, CharType, IntegerType, FloatType, SymbolType, VoidType, NoReturnType, EnumType,
           MetaclassType, GenericClassInstanceMetaclassType, VirtualMetaclassType
        true
      when AliasType
        declared_share?(type.aliased_type, depth + 1)
      when TupleInstanceType
        type.tuple_types.all? { |member| declared_share?(member, depth + 1) }
      when NamedTupleInstanceType
        type.entries.all? { |entry| declared_share?(entry.type, depth + 1) }
      when UnionType
        type.union_types.all? { |member| declared_share?(member, depth + 1) }
      when GenericClassInstanceType
        generic = type.generic_type
        return false unless generic.iyi_share_trusted?
        return true if generic.iyi_share_owns?
        type.type_vars.each_value.all? do |var|
          !var.is_a?(Var) || (argument = var.type?).nil? || declared_share?(argument, depth + 1)
        end
      when NonGenericClassType
        type.iyi_share_trusted? || type == type.program.string
      else
        false
      end
    end

    def tracked?(key : UInt64) : Bool
      @tracked.has_key?(key)
    end

    def callable_for(a_def : Def) : Callable
      @by_def[a_def] ||= begin
        callable = Callable.new(@callables.size, a_def.body, a_def.args.map(&.name), ShareReach.called(a_def), a_def, false)
        @callables << callable
        @queue << callable
        callable
      end
    end

    def literal_for(node : ASTNode, body : ASTNode, params : Array(String), type : Type?) : Callable
      @by_node[node.object_id] ||= begin
        callable = Callable.new(@callables.size, body, params, "a block", nil, true)
        @callables << callable
        @queue << callable
        (@literals[type] ||= [] of Callable) << callable if type
        callable
      end
    end

    # Reads a callable's aliases and what it answers, once, before its
    # writes are read and before any caller asks what a call to it
    # answers.
    def prepare(callable : Callable) : Nil
      return if callable.vars || callable.preparing?
      callable.preparing = true
      vars, answered, answers_state = Scanner.new(self, callable, !callable.literal?, Scanner::Mode::Collect).prepare
      callable.vars = vars
      callable.answered = answered
      callable.answers_state = answers_state
      callable.preparing = false
    end

    # The slots a call to *target* may answer (0 its receiver, n its
    # parameter n, -1 its block's value), or nil for all of them: a def
    # still being prepared, which only a recursion meets, answers whatever
    # it was handed.
    def answered(target : Def) : Set(Int32)?
      callable = callable_for(target)
      prepare(callable)
      callable.preparing? ? nil : callable.answered
    end

    # The callable for *target* when a call to it may answer or yield
    # claimed state: only then is its answer followed as the state. Which
    # do is settled by `analyze` before any write is read.
    def state_answerer(target : Def) : Callable?
      callable = @by_def[target]?
      callable if callable && callable.answers_state?
    end

    def literals_of(type : Type) : Array(Callable)
      @literals[type]? || [] of Callable
    end

    def note_occurrence(occurrence : Occurrence) : Nil
      @occurrences << occurrence
    end

    def note_statement_start(index : Int32) : Nil
      @statement_starts[index] = true if index >= 0 && !@dead_statements.includes?(index)
    end

    # Every callable the program may run, read once for its calls, where
    # each runs from and the claimed state it names (`Scanner::Mode::Graph`).
    private def walk : Nil
      statements = [] of ASTNode
      flatten(@root, statements)
      @statement_starts = Array.new(statements.size, false)
      statements.each_with_index do |statement, index|
        cond = statement.as?(If).try(&.cond)
        @dead_statements << index if cond.is_a?(BoolLiteral) && !cond.value
      end
      main = Callable.new(@callables.size, @root, [] of String, "the program's top level", nil, false)
      main.statements = statements
      @callables << main
      @main = main
      graph(main)

      # Class variable initializers run when the variable is first read,
      # wherever that is; an instance variable's, wherever its object is
      # made. Either may run anywhere.
      @program.class_var_initializers.each do |initializer|
        scan_initializer(initializer.node, "the initializer of `#{initializer.name}`")
      end
      @program.after_inference_types.each { |type| scan_type_initializers(type) }
      # A `fun` with a body is called from outside - the runtime's fiber
      # trampoline, a signal handler - on whatever thread calls it.
      @callbacks.each do |fun_def|
        next unless (external = fun_def.external?) && external.body
        scan_initializer(external.body, "the function `#{fun_def.name}`, which is called from outside the program's code, on any thread")
      end

      while callable = @queue.shift?
        graph(callable)
      end
    end

    private def graph(callable : Callable) : Nil
      Scanner.new(self, callable, !callable.literal?, Scanner::Mode::Graph).run
    end

    # The writes are read only where claimed state may be: in a callable
    # that names it or calls one that may answer or yield it, and in each
    # callee such a callable hands the state to, through every callee that
    # passes it on. Reading every callable's writes, std's included, took
    # 0.22 s of the proof's 0.31 s on a small server (`--stats`, Linux).
    private def analyze : Nil
      callers = {} of Int32 => Array(Callable)
      holders = [] of Callable
      @callables.each do |callable|
        next if callable.literal?
        holders << callable if callable.names_state?
        callable.sites.each { |site| (callers[site.callee.id] ||= [] of Callable) << callable }
      end

      # Which callables may answer or yield claimed state: those that
      # name it, and their callers, read again whenever a callee is found
      # to, until none is.
      queue = Deque(Callable).new
      queued = Set(Int32).new
      holders.each do |holder|
        queue << holder
        queued << holder.id
      end
      while callable = queue.shift?
        queued.delete(callable.id)
        callable.vars = nil
        prepare(callable)
        next unless callable.answers_state? && !callable.answerer?
        callable.answerer = true
        callers[callable.id]?.try &.each do |caller|
          queue << caller if queued.add?(caller.id)
        end
      end
      @callables.each do |callable|
        next if callable.literal? || callable.names_state?
        holders << callable if callable.sites.any?(&.callee.answerer?)
      end
      holders.each { |holder| read_writes(holder) }

      # Each callee a holder hands claimed state to, at that slot, and
      # each callee that one hands the slot to in turn.
      pending = Deque({Callable, Int32}).new
      holders.each do |holder|
        holder.events.each { |event| demand(event.cause, pending) unless event.root.kind.slot? }
      end
      seen = Set({Int32, Int32}).new
      while entry = pending.shift?
        callable, slot = entry
        next unless seen.add?({callable.id, slot})
        read_writes(callable)
        callable.events.each do |event|
          root = event.root
          demand(event.cause, pending) if root.kind.slot? && root.slot == slot
        end
      end
    end

    private def demand(cause : Cause, pending : Deque({Callable, Int32})) : Nil
      if callee = cause.callee
        pending << {callee, cause.slot}
      elsif type = cause.proc_type
        literals_of(type).each { |literal| pending << {literal, cause.slot} }
      end
    end

    private def read_writes(callable : Callable) : Nil
      return if callable.writes_read?
      callable.writes_read = true
      prepare(callable)
      Scanner.new(self, callable, !callable.literal?, Scanner::Mode::Events).run
    end

    private def scan_initializer(node : ASTNode, text : String) : Nil
      callable = Callable.new(@callables.size, node, [] of String, text, nil, false)
      callable.base_origin = Origin.new(Origin::Kind::Initializer, "#{text}, which may run anywhere")
      @callables << callable
      graph(callable)
    end

    @callbacks = [] of FunDef

    private def scan_type_initializers(type : Type) : Nil
      case type
      when GenericClassType
        type.each_instantiated_type { |instance| scan_type_initializers(instance) }
      when GenericClassInstanceType, ClassType
        type.instance_vars_initializers.try &.each do |initializer|
          scan_initializer(initializer.value, "the initializer of `#{type}`'s `#{initializer.name}`")
        end
      end
    end

    # The top level as the statements it runs in order: a file's body, a
    # module's initializer, a class body's code, and nothing a declaration
    # only declares. A class variable's declaration is its initializer,
    # read above.
    private def flatten(node : ASTNode, into : Array(ASTNode)) : Nil
      case node
      when Expressions
        node.expressions.each { |exp| flatten(exp, into) }
      when FileNode
        flatten(node.node, into)
      when ClassDef
        node.hook_expansions.try &.each { |hook| flatten(hook, into) }
        flatten(node.body, into)
      when ModuleDef, ImplDef, TraitDef
        flatten(node.body, into)
      when MacroIf, MacroFor, MacroExpression
        node.expanded.try { |expanded| flatten(expanded, into) }
      when Call
        if expanded = node.expanded
          flatten(expanded, into)
        else
          into << node
        end
      when FunDef
        @callbacks << node if node.body
      when Def, Macro, LibDef, AnnotationDef, Alias, Nop, Require, TypeDef, EnumDef
        # declarations
      when Assign
        into << node unless node.target.is_a?(ClassVar)
      when TypeDeclaration
        into << node unless node.var.is_a?(ClassVar)
      else
        into << node
      end
    end

    # --- what starts a parallel task --------------------------------------

    # Whether the call *node* to *target* may start a parallel task: a
    # kernel thread, any of a group's spawns (one the compiler leaves in its
    # spawner's unit is counted too: whether it moves depends on the claims
    # this proves), or a def that keeps its block for other threads.
    def parallel_start?(target : Def) : Bool
      owner = target.owner
      name = target.name
      if name == "start" && owner.metaclass?
        return true if owner.instance_type.to_s == "IyiThread"
      elsif name.starts_with?("spawn") && !owner.metaclass?
        return true if owner.to_s == "IyiGroup"
      end
      target.iyi_share_block?
    end

    private def compute_starts : Nil
      callers = {} of Int32 => Array(Callable)
      proc_callers = {} of Type => Array(Callable)
      queue = Deque(Callable).new
      @callables.each do |callable|
        callable.sites.each { |site| (callers[site.callee.id] ||= [] of Callable) << callable }
        callable.proc_sites.each { |site| (proc_callers[site.type] ||= [] of Callable) << callable }
        if callable.direct_start?
          callable.starts = true
          queue << callable
        end
      end
      literal_type = {} of Int32 => Type
      @literals.each { |type, list| list.each { |literal| literal_type[literal.id] = type } }
      while callable = queue.shift?
        mark = ->(caller : Callable) do
          unless caller.starts?
            caller.starts = true
            queue << caller
          end
        end
        callers[callable.id]?.try &.each { |caller| mark.call(caller) }
        if (type = literal_type[callable.id]?)
          proc_callers[type]?.try &.each { |caller| mark.call(caller) }
        end
      end

      main = @main.not_nil!
      main.sites.each do |site|
        next if @dead_statements.includes?(site.stmt)
        @statement_starts[site.stmt] = true if site.stmt >= 0 && site.callee.starts?
      end
      main.proc_sites.each do |site|
        next if @dead_statements.includes?(site.stmt)
        if site.stmt >= 0 && literals_of(site.type).any?(&.starts?)
          @statement_starts[site.stmt] = true
        end
      end
      settle_starts
    end

    # A statement of a module's initialiser runs before the initialisers
    # of the modules importing it and after those of the modules it
    # imports, and in an order among the others that each program's
    # imports decide. A task started by a module it neither imports nor is
    # imported by cannot reach its state - that code names none of it - and
    # is joined by its group before the next statement runs, or is a thread
    # whose work the module's state reaches only once code importing it
    # hands it some, after its initialiser. So the start that matters to a
    # statement is the first at or before it in its own module or in one it
    # imports, at any depth; a statement whose file is not a module this
    # build read from source, the program's top level included, sees every
    # start. Taking the program's first start for every statement refused
    # a claim written only by its module's initialiser in a program whose
    # imports ran an unrelated module's `LOCK = Mutex.new { 0 }` first,
    # while the build that wrote the module's artifact, importing them the
    # other way, proved it - and left it out of `Reaches` as holding for
    # every importer (`robust?`), so the two builds disagreed about the same
    # module (`bench/spawn_fuzz.py`).
    private def settle_starts : Nil
      files = Array(String?).new(@statement_starts.size) do |index|
        @statement_locations[index]?.try { |at| (at.expanded_location || at).filename.as?(String) }
      end
      starts = [] of Int32
      @start_before = Array.new(@statement_starts.size, Int32::MAX)
      @statement_starts.each_with_index do |starts_here, index|
        starts << index if starts_here
        if first = starts.find { |start| sees?(files[index], files[start]) }
          @start_before[index] = first
        end
      end
    end

    # Whether a statement written in *file* may run beside a task a
    # statement written in *start* started.
    private def sees?(file : String?, start : String?) : Bool
      return true if file.nil? || start.nil? || file == start
      modules = @program.iyi_module_paths
      return true unless modules.has_key?(file) && modules.has_key?(start) && file != @program.filename
      imported_by(file).includes?(start)
    end

    # Every file *file* imports, at any depth.
    private def imported_by(file : String) : Set(String)
      @imported_by[file] ||= begin
        found = Set(String).new
        queue = (@program.iyi_module_imports[file]? || [] of String).dup
        while other = queue.pop?
          next unless found.add?(other)
          @program.iyi_module_imports[other]?.try { |more| queue.concat(more) }
        end
        found
      end
    end

    @imported_by = {} of String => Set(String)

    # Whether the top-level statement at *index* runs before any parallel
    # task it may run beside has started.
    private def before_start?(index : Int32) : Bool
      (@start_before[index]? || Int32::MAX) == Int32::MAX
    end

    @statement_locations = [] of Location?

    def note_statement_location(index : Int32, location : Location?) : Nil
      @statement_locations << location if index == @statement_locations.size
    end

    # --- where each callable runs -----------------------------------------

    private def propagate_contexts : Nil
      queue = Deque(Callable).new
      @callables.each do |callable|
        next if callable.literal?
        callable.sites.each do |site|
          origin = site.origin
          next unless origin
          queue << site.callee if contribute(site.callee, callable, origin)
        end
      end
      while callable = queue.shift?
        callable.sites.each do |site|
          next if site.origin
          queue << site.callee if inherit(site.callee, callable)
        end
      end
    end

    # The context *origin* gives: before the first parallel task, behind a
    # lock, or anywhere.
    private def origin_context(origin : Origin) : {Bool, Bool, Lock?}
      case origin.kind
      when .top_level?
        before_start?(origin.index) ? {true, false, nil} : {false, true, nil}
      when .locked?
        {false, false, origin.lock}
      else
        {false, true, nil}
      end
    end

    private def contribute(callee : Callable, caller : Callable, origin : Origin) : Bool
      init, free, lock = origin_context(origin)
      merge(callee, caller, init, free, lock ? [lock] : [] of Lock, origin)
    end

    private def inherit(callee : Callable, caller : Callable) : Bool
      merge(callee, caller, caller.init?, caller.free?, caller.locks, nil)
    end

    private def merge(callee : Callable, caller : Callable, init : Bool, free : Bool, locks : Array(Lock), origin : Origin?) : Bool
      changed = false
      if init && !callee.init?
        callee.init = true
        changed = true
      end
      if free && !callee.free?
        callee.free = true
        callee.free_caller = caller
        callee.free_origin = origin
        changed = true
      end
      locks.each do |lock|
        unless callee.locks.includes?(lock)
          callee.locks << lock
          changed = true
        end
      end
      changed
    end

    # --- what each callable writes ----------------------------------------

    alias Written = Hash({Int32, Int32}, {Callable?, Int32, Event})

    # (callable, slot) -> how it is written: the callee and slot it is
    # handed to, or nil when the body writes it itself; and the event.
    # Twice: every write, and only the escapes - a copy kept where the
    # walk cannot follow it, through which anything may write later.
    private def compute_written : Nil
      reverse = {} of {Int32, Int32} => Array({Callable, Int32, Event})
      seeds = [] of {Int32, Int32, Event}
      @callables.each do |callable|
        callable.events.each do |event|
          root = event.root
          next unless root.kind.slot?
          cause = event.cause
          if cause.how
            seeds << {callable.id, root.slot, event}
          elsif callee = cause.callee
            (reverse[{callee.id, cause.slot}] ||= [] of {Callable, Int32, Event}) << {callable, root.slot, event}
          elsif type = cause.proc_type
            literals_of(type).each do |literal|
              (reverse[{literal.id, cause.slot}] ||= [] of {Callable, Int32, Event}) << {callable, root.slot, event}
            end
          end
        end
      end
      spread(@written, seeds, reverse, false)
      spread(@escaped, seeds, reverse, true)
    end

    private def spread(into : Written, seeds : Array({Int32, Int32, Event}), reverse : Hash({Int32, Int32}, Array({Callable, Int32, Event})), escapes : Bool) : Nil
      queue = Deque({Int32, Int32}).new
      seeds.each do |(id, slot, event)|
        next if escapes && !event.cause.escape
        key = {id, slot}
        next if into.has_key?(key)
        into[key] = {nil, 0, event}
        queue << key
      end
      while key = queue.shift?
        reverse[key]?.try &.each do |(caller, slot, event)|
          caller_key = {caller.id, slot}
          next if into.has_key?(caller_key)
          into[caller_key] = {@callables[key[0]], key[1], event}
          queue << caller_key
        end
      end
    end

    private def fired?(cause : Cause, escapes : Bool) : Bool
      return !escapes || cause.escape if cause.how
      map = escapes ? @escaped : @written
      if callee = cause.callee
        return map.has_key?({callee.id, cause.slot})
      end
      if type = cause.proc_type
        return literals_of(type).any? { |literal| map.has_key?({literal.id, cause.slot}) }
      end
      false
    end

    # How a cause writes, for a message: the callees it goes through and
    # what the last one does, `Array#<<` → `Array#push` → `Pointer#[]=`,
    # which writes the memory it points at.
    private def explain(cause : Cause, escapes : Bool) : String
      return cause.how.not_nil! if cause.how
      map = escapes ? @escaped : @written
      start = if callee = cause.callee
                {callee.id, cause.slot}
              else
                literal = literals_of(cause.proc_type.not_nil!).find { |lit| map.has_key?({lit.id, cause.slot}) }
                {literal.not_nil!.id, cause.slot}
              end
      path = [] of String
      key = start
      how = ""
      16.times do
        entry = map[key]?
        break unless entry
        path << "`#{@callables[key[0]].label}`" unless path.last? == "`#{@callables[key[0]].label}`"
        callee, slot, event = entry
        if callee
          key = {callee.id, slot}
        else
          how = "#{event.cause.how}, in #{text_of(event)}"
          break
        end
      end
      "#{path.join(" → ")} #{how}".strip
    end

    # The states a callable may answer or yield, through what its callees
    # answer.
    private def state_out(callable : Callable) : Set(UInt64)
      @state_out[callable.id] ||= begin
        found = Set(UInt64).new
        seen = Set(Int32).new
        stack = [callable]
        while current = stack.pop?
          next unless seen.add?(current.id)
          current.out_roots.each do |root|
            case root.kind
            when .state?
              found << root.key
            when .out?
              stack << @callables[root.slot]
            end
          end
        end
        found
      end
    end

    private def states_of(root : Root) : Set(UInt64)
      case root.kind
      when .state?
        Set{root.key}
      when .out?
        state_out(@callables[root.slot])
      else
        Set(UInt64).new
      end
    end

    # --- the verdict -------------------------------------------------------

    record Write, event : Event, callable : Callable, init : Bool, free : Bool, locks : Array(Lock), escape : Bool = false

    private def context_of(callable : Callable, origin : Origin?) : {Bool, Bool, Array(Lock)}
      if origin
        init, free, lock = origin_context(origin)
        {init, free, lock ? [lock] : [] of Lock}
      elsif callable.reached?
        {callable.init?, callable.free?, callable.locks}
      else
        # A def the walk met but could not place: anywhere.
        {false, true, [] of Lock}
      end
    end

    # Why the claim is refused, or nil when the walk proves it.
    private def refusal_of(claim : ReachClaim) : String?
      key = claim.state.object_id
      writes = [] of Write
      @callables.each do |callable|
        next if callable.literal?
        callable.events.each do |event|
          next if event.root.kind.slot?
          next unless states_of(event.root).includes?(key)
          if fired?(event.cause, escapes: true)
            # A copy kept out of the walk's sight may be written through
            # anywhere, whenever: before the first task, or under a lock,
            # the keeping proves nothing about the writes.
            writes << Write.new(event, callable, false, true, [] of Lock, escape: true)
          elsif fired?(event.cause, escapes: false)
            init, free, locks = context_of(callable, event.origin)
            writes << Write.new(event, callable, init, free, locks)
          end
        end
      end
      writes.sort_by! { |write| location_key(write.event.at) }

      # (c): every write before the first parallel task.
      return nil if writes.all? { |write| !write.free && write.locks.empty? }

      if bad = writes.find(&.free)
        if bad.escape
          return refusal(claim, bad, "whatever writes through that copy may do so anywhere, once a parallel task has started")
        end
        return refusal(claim, bad, "it may run once a parallel task has started, behind no lock the compiler can name: #{where_free(bad.callable, bad.event.origin)}")
      end

      # (b): one lock around every later write, and every later read.
      locks = writes.flat_map(&.locks).uniq
      if locks.size > 1
        first = writes.find { |write| write.locks.includes?(locks[0]) }.not_nil!
        other = writes.find { |write| write.locks.includes?(locks[1]) }.not_nil!
        return refusal(claim, other, "it is behind `#{locks[1].name}`'s lock, and #{text_of(first.event)} at #{show(first.event.at)} writes it behind `#{locks[0].name}`'s: two locks do not exclude each other")
      end
      lock = locks.first
      reads = @occurrences.select(&.key.==(key)).sort_by { |read| location_key(read.at) }
      reads.each do |read|
        init, free, read_locks = context_of(read.callable, read.origin)
        next if !free && read_locks.all?(&.==(lock))
        write = writes.find { |w| !w.locks.empty? }.not_nil!
        where = free ? "with no lock: #{where_free(read.callable, read.origin)}" : "behind `#{read_locks.reject(&.==(lock)).first.name}`'s lock"
        return "@[SafeReach] on `#{claim.label}` is refused: #{text_of(write.event)} at #{show(write.event.at)} writes it behind `#{lock.name}`'s lock, but `#{claim.label}` is read at #{show(read.at)}, #{where}, and a reader beside a locked writer races it. Read it behind `#{lock.name}`'s lock too. #{PROOFS}"
      end
      nil
    end

    PROOFS = "SafeReach is proven when the state's type is Share (a `Mutex`, an `Atomic`, a `List`, a value nothing writes), when every write - and every read once a parallel task may run - is behind one lock the compiler can name (a `Mutex#lock` on a constant or a class variable), or when every write comes before the first parallel task can start: in its initializer, at module init, or in top-level code before the first spawn (SPEC.md III.4.4)"

    private def refusal(claim : ReachClaim, write : Write, why : String) : String
      cause = explain(write.event.cause, write.escape)
      what = cause.empty? ? "" : " (#{cause})"
      verb = write.escape ? "keeps a copy of it where the proof cannot follow" : "writes it"
      "@[SafeReach] on `#{claim.label}` is refused: nothing proves every thread may reach it safely. #{text_of(write.event)} in #{write.callable.named} at #{show(write.event.at)} #{verb}#{what}, and #{why}. #{PROOFS}"
    end

    # An event's expression as a message spells it: a call that takes a
    # block by its receiver and name, anything else as written, on one
    # line and cut at 80 characters.
    def text_of(event : Event) : String
      node = event.node
      text = if node.is_a?(Call) && (node.block || node.block_arg)
               node.obj ? "`#{one_line(node.obj.to_s)[0, 60]}.#{node.name} { ... }`" : "`#{node.name} { ... }`"
             else
               plain = one_line(node.to_s)
               plain = "#{plain[0, 77]}..." if plain.size > 80
               "`#{plain}`"
             end
      "#{text}#{event.suffix}"
    end

    # Each run of whitespace as one space, by hand: a regex literal here
    # put pcre2 on the compiler's link line, and the release job's floor
    # build, which has no libpcre2-8, failed to link (CI run 41860072716).
    private def one_line(text : String) : String
      String.build(text.bytesize) do |io|
        spaced = false
        text.each_char do |char|
          if char.ascii_whitespace?
            io << ' ' unless spaced
            spaced = true
          else
            io << char
            spaced = false
          end
        end
      end
    end

    # Where a callable runs anywhere from: the callers back to the origin.
    private def where_free(callable : Callable, origin : Origin?) : String
      return origin_text(origin) if origin
      path = [] of String
      current = callable
      32.times do
        path << current.named
        if found = current.free_origin
          return "#{origin_text(found)}, which calls #{path.reverse.join(" → ")}"
        end
        caller = current.free_caller
        break unless caller
        current = caller
      end
      "#{path.reverse.join(" → ")} is called from somewhere the proof cannot place"
    end

    private def origin_text(origin : Origin) : String
      if origin.kind.top_level?
        "#{origin.text} at #{show(origin.at)}, after the statement at #{show(@statement_locations[@start_before[origin.index]? || Int32::MAX]?)} may start the first parallel task"
      elsif at = origin.at
        "#{origin.text}, at #{show(at)}"
      else
        origin.text
      end
    end

    # A place as the error's own header spells it: relative to the working
    # directory when it is beneath it.
    def show(location : Location?) : String
      file, line, column = source_place(location)
      return "an unknown place" if file.empty?
      here = Dir.current + "/"
      file = file[here.size..] if file.starts_with?(here)
      "#{file}:#{line}:#{column}"
    end

    # The file, line and column a location was written at. Code an inline
    # macro expanded - a bench's `{% if flag?(...) %}` - is placed on the
    # line of the file it was written on (`VirtualFile#line_origins`), not
    # on the `{% if` line every line of it expands at.
    private def source_place(location : Location?) : {String, Int32, Int32}
      return {"", 0, 0} unless location
      line = location.line_number
      column = location.column_number
      while (virtual = location.filename).is_a?(VirtualFile)
        outer = virtual.expanded_location
        origin = virtual.line_origins.try &.[line]?
        break unless outer && origin
        location = outer
        line = origin
      end
      if location.filename.is_a?(VirtualFile)
        location = location.expanded_location || location
        line = location.line_number
        column = location.column_number
      end
      {location.filename.to_s, line, column}
    end

    # Whether a start is the program's: written outside std and the
    # prelude. The runtime starts threads of its own - a collection can -
    # and those run its code, never the program's: the program's code
    # crosses to another thread only through a start it writes, or a
    # `@[Share]` def it calls, whose call it writes too.
    def program_site?(location : Location?) : Bool
      !@program.iyi_share_reach.std_at?(location)
    end

    private def location_key(location : Location?) : {String, Int32, Int32}
      source_place(location)
    end

    @main : Callable? = nil

    # --- one body ----------------------------------------------------------

    # Reads one callable's body, in one of three ways. `Graph`, every
    # callable once: the calls, where each runs from, the starts and the
    # reads of claimed state. `Collect`, for `prepare`: what each local may
    # hold (by name, every assignment at once, until nothing changes) and
    # which of its receiver and parameters it may answer. `Events`, only
    # for the callables `ReachProof#analyze` picks: the writes and the
    # state it answers.
    class Scanner < Visitor
      enum Mode
        Graph
        Collect
        Events
      end

      EMPTY      = Set(Root).new
      SELF_ONLY  = Set{SELF}
      BLOCK_ONLY = Set{BLOCK_VALUE}

      @vars = {} of String => Set(Root)
      @origins = [] of Origin
      @changed = false
      @stmt = -1

      def initialize(@proof : ReachProof, @callable : Callable, @full : Bool, @mode : Mode)
        if vars = @callable.vars
          @vars = vars
        else
          @callable.params.each_with_index do |name, index|
            @vars[name] = Set{Root.new(RootKind::Slot, index + 1)}
          end
        end
      end

      private def collect? : Bool
        @mode.collect?
      end

      private def graph? : Bool
        @mode.graph?
      end

      private def events? : Bool
        @mode.events?
      end

      # The alias table; the slots the body may answer, its value's and
      # every `return`'s; and whether it may answer or yield claimed state.
      def prepare : {Hash(String, Set(Root)), Set(Int32), Bool}
        if statements = @callable.statements
          collect { statements.each &.accept(self) }
          return {@vars, Set(Int32).new, false}
        end
        body = @callable.body
        collect { body.accept self }
        answered = roots(body).dup
        state = false
        Returns.each(body) do |exp, yielded|
          exp_roots = roots(exp)
          if yielded
            state ||= exp_roots.any? { |root| !root.kind.slot? }
          else
            answered.concat(exp_roots)
          end
        end
        state ||= answered.any? { |root| !root.kind.slot? }
        {@vars, answered.select(&.kind.slot?).map(&.slot).to_set, state}
      end

      # Reads the callable in this scanner's mode, `Graph` or `Events`.
      def run : Nil
        if statements = @callable.statements
          scan_statements(statements)
          return
        end
        if origin = @callable.base_origin
          @origins << origin
        end
        body = @callable.body
        body.accept self
        @callable.out_roots.concat(outward(roots(body))) if @mode.events?
      end

      # The `return`s and `yield`s of a body, not those of a proc literal
      # or a def in it.
      class Returns < Visitor
        def self.each(body : ASTNode, &block : ASTNode?, Bool ->) : Nil
          body.accept new(block)
        end

        def initialize(@block : ASTNode?, Bool ->)
        end

        def visit(node : Return) : Bool
          @block.call(node.exp, false)
          true
        end

        def visit(node : Yield) : Bool
          node.exps.each { |exp| @block.call(exp, true) }
          true
        end

        def visit(node : ProcLiteral | Def | TypeOf) : Bool
          false
        end

        def visit(node : ASTNode) : Bool
          true
        end
      end

      private def scan_statements(statements : Array(ASTNode)) : Nil
        statements.each_with_index do |statement, index|
          @stmt = index
          @proof.note_statement_location(index, statement.location) if graph?
          @origins << Origin.new(Origin::Kind::TopLevel, "the program's top level", index, at: statement.location)
          statement.accept self
          @origins.pop
        end
        @stmt = -1
      end

      private def collect(&) : Nil
        mode = @mode
        @mode = Mode::Collect
        8.times do
          @changed = false
          yield
          break unless @changed
        end
        @mode = mode
      end

      private def add_var(name : String, roots : Set(Root)) : Nil
        return if roots.empty?
        set = @vars[name] ||= Set(Root).new
        before = set.size
        set.concat(roots)
        @changed = true if set.size != before
      end

      private def outward(roots : Set(Root)) : Set(Root)
        roots.reject(&.kind.slot?).to_set
      end

      private def origin : Origin?
        @origins.last?
      end

      # --- what a value may be ------------------------------------------

      # What a value may be: the receiver, a parameter, the block's value,
      # a claimed state or what a callable answering one answers. The set
      # answered is never changed by its caller: `SELF_ONLY` and a local's
      # own set are answered as they are.
      def roots(node : ASTNode?) : Set(Root)
        return EMPTY unless node
        if (type = node.type?) && @proof.share?(type)
          return EMPTY unless node.is_a?(PointerOf)
        end
        case node
        when Var
          node.name == "self" ? SELF_ONLY : (@vars[node.name]? || EMPTY)
        when InstanceVar
          SELF_ONLY
        when ReadInstanceVar
          roots(node.obj)
        when ClassVar
          state_root(node.var?)
        when Path
          state_root(node.target_const)
        when Call
          (expanded = node.expanded) ? roots(expanded) : call_roots(node)
        when Assign
          roots(node.value)
        when Expressions
          roots(node.expressions.last?)
        when If
          union(roots(node.then), roots(node.else))
        when Cast
          roots(node.obj)
        when NilableCast
          roots(node.obj)
        when ExceptionHandler
          found = union(roots(node.body), roots(node.else))
          node.rescues.try &.each { |a_rescue| found = union(found, roots(a_rescue.body)) }
          found
        when PointerOf
          address_roots(node.exp)
        when TupleLiteral
          node.elements.reduce(EMPTY) { |acc, element| union(acc, roots(element)) }
        when Yield
          BLOCK_ONLY
        when ExpandableNode
          (expanded = node.expanded) ? roots(expanded) : EMPTY
        else
          EMPTY
        end
      end

      # Both, without a new set when either is empty.
      private def union(left : Set(Root), right : Set(Root)) : Set(Root)
        return left if right.empty?
        return right if left.empty?
        left + right
      end

      private def call_roots(node : Call) : Set(Root)
        receiver = receiver_roots(node)
        targets = node.target_defs
        found = EMPTY
        if targets.nil? || targets.empty?
          node.args.each { |arg| found = union(found, roots(arg)) }
          return union(found, receiver)
        end
        args = node.args.map { |arg| roots(arg) }
        block = node.block
        value = block ? block_value(block) : EMPTY
        handed = !receiver.empty? || !value.empty? || args.any? { |arg| !arg.empty? }
        count = args.size
        targets.each do |target|
          if proc_call?(target)
            # A proc's answer is its literal's, and a literal that answers
            # claimed state is counted where it is written, as a write
            # (`escape_from_literal`); what it was handed it may answer.
            args.each { |arg| found = union(found, arg) }
          elsif primitive?(target) || target.is_a?(External)
            # `self + offset` answers memory its receiver points into.
            found = union(found, receiver)
            args.each { |arg| found = union(found, arg) }
          else
            if handed
              # What the callee may answer of its receiver, parameters and
              # block; all of them while it is being read, which a
              # recursion meets. Asked only when something is handed.
              answered = @proof.answered(target)
              found = union(found, receiver) if answered.nil? || answered.includes?(0)
              args.each_with_index do |arg, index|
                slot = slot_of(target, index, count)
                found = union(found, arg) if answered.nil? || slot.nil? || answered.includes?(slot)
              end
              found = union(found, value) if answered.nil? || answered.includes?(-1)
            end
            if answerer = @proof.state_answerer(target)
              found = union(found, Set{Root.new(RootKind::Out, slot: answerer.id)})
            end
          end
        end
        found
      end

      private def state_root(state : Const | MetaTypeVar | Nil) : Set(Root)
        return EMPTY unless state
        return EMPTY if state.is_a?(MetaTypeVar) && state.thread_local?
        key = state.object_id
        @proof.tracked?(key) ? Set{Root.new(RootKind::State, key: key)} : EMPTY
      end

      # What `pointerof(exp)` points into: a field of self, a claimed
      # state's cell, or whatever a local holds.
      private def address_roots(exp : ASTNode) : Set(Root)
        case exp
        when InstanceVar
          SELF_ONLY
        when ClassVar
          state_root(exp.var?)
        when Path
          state_root(exp.target_const)
        else
          roots(exp)
        end
      end

      private def receiver_roots(node : Call) : Set(Root)
        if obj = node.obj
          roots(obj)
        elsif implicit_self?(node)
          SELF_ONLY
        else
          EMPTY
        end
      end

      # A receiverless call to an instance method is a call on self.
      private def implicit_self?(node : Call) : Bool
        node.target_defs.try(&.any? do |target|
          owner = target.owner
          !owner.metaclass? && !owner.is_a?(Program) && !owner.is_a?(FileModule)
        end) || false
      end

      private def primitive?(target : Def) : Bool
        target.body.is_a?(Primitive)
      end

      private def proc_call?(target : Def) : Bool
        (body = target.body).is_a?(Primitive) && body.name == "proc_call"
      end

      # Primitives that write the memory their receiver points at, or
      # free it, or a C struct's field: everything else a primitive does
      # is a read or a new value.
      WRITING_PRIMITIVES = {"pointer_set", "pointer_realloc", "store_atomic", "atomicrmw", "cmpxchg", "struct_or_union_set"}

      # --- events --------------------------------------------------------

      # An event on each root: *node* is the expression as written, and
      # *suffix* what it does with the root; the text is rendered only for
      # a refusal (`ReachProof#text_of`).
      private def event(roots : Set(Root), cause : Cause, node : ASTNode, at : Location?, suffix : String = "") : Nil
        return unless events?
        roots.each do |root|
          next if !@full && !root.kind.slot?
          @callable.events << Event.new(root, cause, node, suffix, at, origin)
        end
      end

      private def direct(roots : Set(Root), how : String, node : ASTNode, at : Location?, suffix : String = "") : Nil
        event(roots, Cause.new(how: how), node, at, suffix)
      end

      # An event for a copy kept where the walk cannot follow it.
      private def escape(roots : Set(Root), how : String, node : ASTNode, at : Location?, suffix : String = "") : Nil
        event(roots, Cause.new(how: how, escape: true), node, at, suffix)
      end

      # What storing *value* keeps: nothing when its type is Share, read in
      # full - a value nothing writes once it is made, an array of which
      # `ROUTES.select` copies - since nothing can write through the copy.
      private def stored(value : ASTNode) : Set(Root)
        found = roots(value)
        return found if found.empty?
        (type = value.type?) && @proof.deep_share?(type) ? EMPTY : found
      end

      # --- visits --------------------------------------------------------

      def visit(node : Expressions) : Bool
        exps = node.expressions
        index = 0
        while index < exps.size
          exp = exps[index]
          lock = collect? ? nil : bracket(exp, "lock")
          unless lock
            exp.accept self
            index += 1
            next
          end
          exp.accept self
          index += 1
          @origins << Origin.new(Origin::Kind::Locked, "behind `#{lock.name}`", lock: lock)
          while index < exps.size && !Unlocks.any?(exps[index], lock.name)
            exps[index].accept self
            index += 1
          end
          # `begin ... ensure X.unlock end`: the body is still held.
          if index < exps.size && (handler = exps[index]).is_a?(ExceptionHandler) &&
             !Unlocks.any?(handler.body, lock.name) && handler.rescues.nil? && handler.else.nil?
            handler.body.accept self
            @origins.pop
            handler.ensure.try &.accept self
            index += 1
          else
            @origins.pop
          end
        end
        false
      end

      # `IyiSchedLock.lock` or `IyiRuntimeLock.lock` (*verb*), as a
      # statement written in the prelude.
      private def bracket(node : ASTNode, verb : String) : Lock?
        return nil unless node.is_a?(Call) && node.name == verb && node.args.empty? && node.block.nil?
        obj = node.obj
        return nil unless obj.is_a?(Path)
        name = obj.names.last
        return nil unless name == "IyiSchedLock" || name == "IyiRuntimeLock"
        return nil unless @proof.prelude_at?(node.location)
        type = obj.type?
        Lock.new(type ? type.object_id : name.hash, name)
      end

      # Whether a statement unlocks *name* anywhere in it.
      class Unlocks < Visitor
        getter? found = false

        def initialize(@name : String)
        end

        def self.any?(node : ASTNode?, name : String) : Bool
          return false unless node
          visitor = new(name)
          node.accept visitor
          visitor.found?
        end

        def visit(node : Call) : Bool
          obj = node.obj
          @found = true if node.name == "unlock" && obj.is_a?(Path) && obj.names.last == @name
          !@found
        end

        def visit(node : ASTNode) : Bool
          !@found
        end
      end

      def visit(node : Assign) : Bool
        target = node.target
        if target.is_a?(Path)
          # A constant declared here: its initializer runs here, as long as
          # it is used at all.
          if (const = target.target_const) && const.used?
            const.value.accept self
          end
          return false
        end
        if collect?
          add_var(target.name, roots(node.value)) if target.is_a?(Var)
        elsif events?
          case target
          when InstanceVar
            direct(SELF_ONLY, "assigns `#{target.name}`", node, node.location)
          when ClassVar
            direct(state_root(target.var?), "assigns it", node, node.location)
          when ReadInstanceVar
            direct(roots(target.obj), "assigns `#{target.name}`", node, node.location)
          end
          if slot_roots = escaping(target, node.value)
            escape(slot_roots, "stores it", node, node.location)
          end
        end
        node.value.accept self
        false
      end

      # A value stored where the walk cannot follow it - a field, a class
      # variable - escapes: whatever later writes through the copy writes
      # the original.
      private def escaping(target : ASTNode, value : ASTNode) : Set(Root)?
        return nil if target.is_a?(Var)
        found = stored(value)
        found.empty? ? nil : found
      end

      def visit(node : TypeDeclaration) : Bool
        var = node.var
        value = node.value
        if var.is_a?(Var) && value
          add_var(var.name, roots(value)) if collect?
        elsif var.is_a?(ClassVar) && value
          direct(state_root(var.var?), "assigns it", node, node.location) if events?
        end
        value.try &.accept self
        false
      end

      def visit(node : PointerOf) : Bool
        direct(address_roots(node.exp), "takes its address with `pointerof`", node, node.location) if events?
        true
      end

      def visit(node : Return | Next) : Bool
        @callable.out_roots.concat(outward(roots(node.exp))) if events?
        true
      end

      def visit(node : Yield) : Bool
        if events?
          node.exps.each { |exp| @callable.out_roots.concat(outward(roots(exp))) }
        end
        true
      end

      def visit(node : Path) : Bool
        read(node.target_const, node.location)
        false
      end

      def visit(node : ClassVar) : Bool
        read(node.var?, node.location)
        false
      end

      private def read(state : Const | MetaTypeVar | Nil, at : Location?) : Nil
        return unless graph? && @full && state
        key = state.object_id
        return unless @proof.tracked?(key)
        @callable.names_state = true
        @proof.note_occurrence(Occurrence.new(key, @callable, origin, at))
      end

      def visit(node : Call) : Bool
        if expanded = node.expanded
          expanded.accept self
          return false
        end
        targets = node.target_defs || [] of Def
        obj = node.obj
        block = node.block

        case @mode
        in .collect?
          if block
            flow = receiver_roots(node).dup
            node.args.each { |arg| flow.concat(roots(arg)) }
            targets.each do |target|
              next if primitive?(target) || target.is_a?(External)
              if answerer = @proof.state_answerer(target)
                flow << Root.new(RootKind::Out, slot: answerer.id)
              end
            end
            block.args.each do |arg|
              next if (type = arg.type?) && @proof.share?(type)
              add_var(arg.name, flow)
            end
          end
        in .graph?
          record_sites(node, targets)
        in .events?
          record_events(node, targets)
        end

        obj.try &.accept self
        node.args.each &.accept(self)
        if block
          block_origin = collect? ? nil : origin_of_block(node, block, targets)
          @origins << block_origin if block_origin
          if fun_literal = block.fun_literal
            if graph?
              @proof.literal_for(block, block.body, block.args.map(&.name), fun_literal.type?)
            elsif events?
              escape_from_literal(block.body, false, fun_literal.type?, node, node.name_location || node.location)
            end
          end
          block.body.accept self
          @origins.pop if block_origin
        end
        node.block_arg.try &.accept self
        false
      end

      # The calls, for where each callee runs and what starts a task.
      private def record_sites(node : Call, targets : Array(Def)) : Nil
        at = node.name_location || node.location
        targets.each do |target|
          if proc_call?(target)
            @callable.proc_sites << ProcSite.new(target.owner, @stmt)
            next
          end
          next if target.body.is_a?(Primitive) || target.is_a?(External)
          callee = @proof.callable_for(target)
          if @full
            @callable.sites << Site.new(callee, origin, @stmt)
          else
            @callable.sites << Site.new(callee, nil, -1)
          end
          if @proof.parallel_start?(target) && @proof.program_site?(at)
            @callable.direct_start = true
            @proof.note_statement_start(@stmt)
          end
        end
      end

      # What the call writes of what it is handed, or hands on.
      private def record_events(node : Call, targets : Array(Def)) : Nil
        receiver = receiver_roots(node)
        at = node.name_location || node.location
        count = node.args.size
        targets.each do |target|
          if proc_call?(target)
            node.args.each_with_index do |arg, index|
              event(roots(arg), Cause.new(proc_type: target.owner, slot: index + 1), node, at, ", which hands it to a proc")
            end
            next
          end
          if (body = target.body).is_a?(Primitive)
            if WRITING_PRIMITIVES.includes?(body.name)
              direct(receiver, "writes the memory it points at", node, at)
              # A value stored escapes as one stored in a field does: what
              # reads it back and writes through it writes the original,
              # so `[WORDS].first << "x"` writes `WORDS`.
              node.args.each { |arg| escape(stored(arg), "stores it in memory", node, at) }
            end
            next
          end
          if target.is_a?(External)
            node.args.each do |arg|
              handed = roots(arg)
              direct(handed, "hands it to the C function `#{target.real_name}`", node, at) unless handed.empty?
            end
            next
          end
          callee = @proof.callable_for(target)
          event(receiver, Cause.new(callee: callee, slot: 0), node, at)
          node.args.each_with_index do |arg, index|
            arg_roots = roots(arg)
            next if arg_roots.empty?
            if slot = slot_of(target, index, count)
              event(arg_roots, Cause.new(callee: callee, slot: slot), node, at, ", which is handed it")
            else
              escape(arg_roots, "hands it to a parameter the proof cannot follow", node, at, ", which is handed it")
            end
          end
          # A block whose value the callee writes, through what its
          # `yield` answers.
          if (block = node.block) && !(value = block_value(block)).empty?
            event(value, Cause.new(callee: callee, slot: -1), node, at, ", whose block answers it")
          end
        end
      end

      # What a block answers to the `yield` that runs it.
      def block_value(block : Block) : Set(Root)
        roots(block.body)
      end

      # A block kept to run later, or a proc, that may answer claimed
      # state hands it to whoever calls the proc, which the walk does not
      # follow: it is counted as stored where the literal runs (its
      # origin, a block kept or a parallel task's, which runs anywhere).
      # A literal answering nothing (`Proc(Nil)`, a spawn's) keeps none.
      # A proc literal answers its `return`s too; a block's `return`
      # leaves the def around it.
      private def escape_from_literal(body : ASTNode, returns : Bool, type : Type?, node : ASTNode, at : Location?) : Nil
        return unless events? && @full
        if type.is_a?(ProcInstanceType)
          answer = type.return_type
          return if answer.nil_type? || answer.void? || @proof.share?(answer) || @proof.deep_share?(answer)
        end
        state = outward(roots(body))
        if returns
          Returns.each(body) { |exp, yielded| state.concat(outward(roots(exp))) unless yielded }
        end
        escape(state, "answers it from a proc the proof does not follow", node, at) unless state.empty?
      end

      # The parameter call argument *index* binds, counted from 1 (0 is
      # the receiver), through a splat; nil past the end.
      private def slot_of(target : Def, index : Int32, count : Int32) : Int32?
        size = target.args.size
        if splat = target.splat_index
          in_splat = count - (size - 1)
          return index + 1 if index < splat
          return splat + 1 if index < splat + in_splat
          return index - in_splat + 2
        end
        index < size ? index + 1 : nil
      end

      # The origin a block's body runs under: the block a parallel task
      # runs, a lock's block, a block kept to run later; nil for one run
      # inline (yielded to, or the constructor of an owning type).
      private def origin_of_block(node : Call, block : Block, targets : Array(Def)) : Origin?
        target = targets.first?
        at = node.name_location || node.location
        if target
          if @proof.parallel_start?(target)
            return Origin.new(Origin::Kind::Parallel, "the block `#{spelled(target.name)}` runs as a parallel task", at: at)
          end
          owner = target.owner
          if owning?(owner)
            return nil if owner.metaclass?
            if lock = lock_of(node.obj)
              return Origin.new(Origin::Kind::Locked, "behind `#{lock.name}`", lock: lock)
            end
            return Origin.new(Origin::Kind::UnnamedLock, "behind `#{node.obj}`'s lock, which the compiler cannot name (a constant or a class variable it can)", at: at)
          end
        end
        return nil unless block.fun_literal
        Origin.new(Origin::Kind::Stored, "a block kept to run later", at: at)
      end

      # A spawn as it is written: the def `spawn:parallel` that
      # `g.spawn(parallel: true)` expands to by that spelling.
      private def spelled(name : String) : String
        verb, _, flag = name.partition(':')
        flag.empty? ? verb : "#{verb}(#{flag}: true)"
      end

      private def owning?(owner : Type) : Bool
        type = owner.metaclass? ? owner.instance_type : owner
        type = type.generic_type.as(Type) if type.is_a?(GenericClassInstanceType)
        type.iyi_share_owns?
      end

      private def lock_of(obj : ASTNode?) : Lock?
        case obj
        when Path
          (const = obj.target_const) ? Lock.new(const.object_id, const.name) : nil
        when ClassVar
          (var = obj.var?) ? Lock.new(var.object_id, var.name) : nil
        else
          nil
        end
      end

      def visit(node : ProcLiteral) : Bool
        if collect?
          node.def.body.accept self
          return false
        end
        @proof.literal_for(node, node.def.body, node.def.args.map(&.name), node.type?) if graph?
        @origins << Origin.new(Origin::Kind::Stored, "a proc, which may run whenever it is called", at: node.location)
        escape_from_literal(node.def.body, true, node.type?, node, node.location)
        node.def.body.accept self
        @origins.pop
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

      def visit(node : TypeOf | Def | Macro | LibDef | AnnotationDef | ClassDef | ModuleDef) : Bool
        false
      end

      def visit(node : ASTNode) : Bool
        true
      end
    end
  end
end
