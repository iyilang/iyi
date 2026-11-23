module Iyi
  # iyi: which constants of the program's own files code that runs reads
  # (SPEC.md III.5).
  #
  # A constant is initialised at its declaration when something read it
  # (`codegen_assign`), and `visit(Path)` called it read the first time it
  # typed it. Definition-site typing (`DefinitionTyping`) types every
  # fully declared def of the entry file and of every module it imports,
  # under an `if false` that never runs, so every constant such a def
  # names was read, and initialised as its module started in every
  # program importing the module.
  #
  # So `MainVisitor` notes, for each body it types, the constants it reads
  # and the calls and proc literals it makes, a probe's own statements left
  # out, and once the program is typed the bodies are followed from the
  # code that runs as the program starts: its top level, every
  # initializer, each function the outside calls. A constant met there is
  # reached, and so is what its own initializer reads. One that is not is
  # still typed and still `used?`, so the reach proof (`ReachProof`), the
  # cleanup and every check see what they saw; only its declaration does
  # not run it, and its first read does, once (`__iyi_once`, born in the
  # shared heap under `-Dheap_partitions`), if anything ever reads it. A
  # body the walk misses costs that order, never the value.
  #
  # Only the program's own files are walked: the prelude's constants are
  # initialised where they always were, since the runtime reads some from
  # code the compiler writes rather than from a call the walk can follow.
  #
  # `IYI_SPAWN_BROKEN=probeused` counts a probe's statements as code that
  # runs, as before; `bench/std_lazy_tables_exercise.sh` must fail on it.
  class Program
    @iyi_reach_consts = ({} of Def => Array(Const)).compare_by_identity
    @iyi_reach_nodes = ({} of Def => Array(ASTNode)).compare_by_identity
    @iyi_root_consts = [] of Const
    @iyi_root_nodes = [] of ASTNode
    # Whether `iyi_mark_reached_constants` ran: a program typed some other
    # way initialises every constant read at its declaration, as before.
    getter? iyi_reached_marked = false

    # One read or call of the body of *owner*, or of code that runs as the
    # program starts when *owner* is nil.
    def iyi_note_reach(owner : Def?, target : Const | ASTNode) : Nil
      if owner
        if target.is_a?(Const)
          (@iyi_reach_consts[owner] ||= [] of Const) << target
        else
          (@iyi_reach_nodes[owner] ||= [] of ASTNode) << target
        end
      elsif target.is_a?(Const)
        @iyi_root_consts << target
      else
        @iyi_root_nodes << target
      end
    end

    # Marks `Const#iyi_reached?` on every constant code that runs reads.
    def iyi_mark_reached_constants : Nil
      @iyi_reached_marked = true
      files = Set(String).new
      filename.try { |entry| files << entry }
      iyi_module_imports.each do |file, imports|
        files << file
        imports.each { |imported| files << imported }
      end
      const_initializers.each do |const|
        file = const.locations.try(&.first?).try(&.read_from)
        const.iyi_reached = true unless file.is_a?(String) && files.includes?(file)
      end

      seen = Set(Def).new.compare_by_identity
      queue = [] of Def
      reach = ->(a_def : Def) do
        queue << a_def if seen.add?(a_def)
        nil
      end
      reach_node = ->(node : ASTNode) do
        case node
        when Call
          node.target_defs.try &.each { |target| reach.call(target) }
        when ProcLiteral
          reach.call(node.def)
        end
        nil
      end
      reach_const = ->(const : Const) do
        const.iyi_reached = true
        const.fake_def.try { |value| reach.call(value) }
        nil
      end

      @iyi_root_consts.each { |const| reach_const.call(const) }
      @iyi_root_nodes.each { |node| reach_node.call(node) }
      # A `fun` with a body is called from outside - the fiber trampoline,
      # a signal handler, C - and `finalize` by the collector.
      @iyi_reach_consts.each_key { |owner| reach.call(owner) if iyi_called_from_outside?(owner) }
      @iyi_reach_nodes.each_key { |owner| reach.call(owner) if iyi_called_from_outside?(owner) }
      while a_def = queue.pop?
        @iyi_reach_consts[a_def]?.try &.each { |const| reach_const.call(const) }
        @iyi_reach_nodes[a_def]?.try &.each { |node| reach_node.call(node) }
      end
    end

    private def iyi_called_from_outside?(a_def : Def) : Bool
      a_def.is_a?(External) || a_def.name == "finalize"
    end
  end
end
