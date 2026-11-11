module Iyi
  # A layout fold is a `sizeof`, `alignof`, `instance_sizeof`, `instance_alignof`
  # or `offsetof` that typing folded to a literal. Typing can fold a layout
  # before it is final: a module gains implementors, or the shared typer cached
  # a tuple before one of its elements grew. Each record keeps the value the
  # typer saw, so settling can compare it with the final layout.
  enum LayoutFoldKind
    Size
    Align
    InstanceSize
    InstanceAlign
    Offset
    InstanceOffset
  end

  # `subject` is the type that the fold passed to `Program#size_of` and the
  # related methods. `index` is the element of an offset fold. `type_argument`
  # is true when the fold sits inside a type argument, so its value is part of a
  # type that is already built.
  record LayoutFold,
    node : ASTNode,
    kind : LayoutFoldKind,
    subject : Type,
    index : Int32?,
    value : UInt64,
    type_argument : Bool,
    owner : ASTNode?

  enum LayoutFoldState
    Unsettled
    Reported
    Patched
  end

  # What took a fold literal's value. `TypeArgument` built a type from it,
  # `EnumValue` is an enum member's value, `Macro` is a macro's output, and
  # `Typing` is any other typing decision the value shaped.
  enum LayoutFoldUseKind
    TypeArgument
    EnumValue
    Macro
    Typing
  end

  # One value a reader took from a fold literal. `adopted` is set when a type
  # variable took the literal itself, which keeps the literal.
  record LayoutFoldRead, fold : LayoutFold, literal : NumberLiteral, value : String, adopted : Bool

  # A value the MathInterpreter computed from fold literals. `result` is what
  # it gave for `root`, interpreted in `scope` for the `target` integer type.
  record LayoutFoldDerivation, root : ASTNode, scope : Type, target : IntegerType?, result : String

  # What replaying a macro under the final layout values showed about its output.
  enum MacroRerunOutcome
    # The output is the text the program compiled.
    Equal
    # The output differs, or the macro raises where it did not.
    Changed
    # The replay could not finish, so it shows nothing. The reason travels beside it.
    Unknown
  end

  # A macro expansion that read fold literals, kept so settling can replay it: the macro and its
  # call, or the inline macro node, as they were expanded, and the text the expansion gave.
  # `temp_vars_start` is where the compiler's temporary-name counters stood when it began.
  record LayoutFoldMacroDerivation,
    macro_def : Macro?,
    call : Call?,
    node : ASTNode?,
    scope : Type,
    path_lookup : Type,
    free_vars : Hash(String, TypeVar)?,
    a_def : Def?,
    temp_vars_start : Hash(String, Int32),
    original_output : String

  # One macro expansion in progress, with the fold literals it has read so far.
  class LayoutFoldMacroFrame
    getter reads = [] of LayoutFoldRead
  end

  # A decision that took fold values. `derivation` is set when the decision took
  # a computed value, and then `reads` are the literals that computation read.
  record LayoutFoldUse, kind : LayoutFoldUseKind, site : ASTNode?, reads : Array(LayoutFoldRead),
    derivation : LayoutFoldDerivation?,
    macro_derivation : LayoutFoldMacroDerivation? = nil

  # One entry on the reader stack. A derive frame collects the reads of one
  # computation. A consumer frame collects, as pending uses, what its block took.
  # Lists are created on the first read, so a frame that meets no fold allocates nothing.
  record LayoutFoldFrame, derive : Bool,
    pending : Array({Array(LayoutFoldRead), LayoutFoldDerivation?})? = nil,
    reads : Array(LayoutFoldRead)? = nil

  # A use whose value no longer matches the final layout. `changed` are the reads
  # that differ. `rerun` is what the use's derivation gives from the final values,
  # or nil when it gives none.
  record LayoutFoldHarm, use : LayoutFoldUse, changed : Array(LayoutFoldRead), rerun : String?

  # Finds the fold literals in a constant's value. `Program#layout_fold_constant_read`
  # reads each one as a macro's use.
  private class LayoutFoldLiteralReads < Visitor
    def initialize(@program : Program, @site : ASTNode?)
    end

    def visit(node : ASTNode)
      true
    end

    def visit(node : NumberLiteral)
      @program.layout_fold_use(node, LayoutFoldUseKind::Macro, @site)
      false
    end
  end

  # The by-value containment of the folded layouts. Each open container is a
  # node, joined to every open container it holds by value. Joined nodes form a
  # component whose layouts move together, so a type argument that pins one
  # node pins the whole component.
  class LayoutFoldGraph
    def initialize
      @parents = [] of Int32
      @witnesses = [] of Type
      @ids = Hash(Type, Int32).new.compare_by_identity
      @instance_ids = Hash(Type, Int32).new.compare_by_identity
    end

    # Whether the shape of `type` can still change: a module gains implementors,
    # and an abstract or virtual struct gains subtypes.
    def self.open_layout?(type : Type) : Bool
      type.module? || (type.abstract? && type.struct?) ||
        (type.is_a?(VirtualType) && type.base_type.struct?)
    end

    # The node for `type`'s layout, or for a class's instance struct when
    # `instance` is set. `witness` is the open type a node stands for in a report.
    def id_for(type : Type, instance : Bool, witness : Type? = nil) : Int32
      ids = instance ? @instance_ids : @ids
      if id = ids[type]?
        return id
      end

      id = @parents.size
      @parents << id
      @witnesses << (witness || type)
      ids[type] = id
      id
    end

    def witness_of(id : Int32) : Type
      @witnesses[id]
    end

    def find(id : Int32) : Int32
      root = id
      while @parents[root] != root
        root = @parents[root]
      end
      while id != root
        parent = @parents[id]
        @parents[id] = root
        id = parent
      end
      root
    end

    def union(a : Int32, b : Int32) : Nil
      root_a = find(a)
      root_b = find(b)
      @parents[root_b] = root_a unless root_a == root_b
    end

    # The open nodes that `type` reaches by value, through the containers
    # between them. A layout that is closed reaches none. A pointer, a class
    # reference, a metaclass or a primitive stops the walk. `path` holds the
    # types on the walk, so a cycle stops there rather than recurring.
    def roots_of(type : Type, instance : Bool, path : Array(Type)) : Array(Int32)
      if self.class.open_layout?(type)
        return [id_for(type, false)]
      end
      return [] of Int32 if path.any? { |visited| visited.same?(type) }

      path << type
      roots = instance ? instance_roots(type, path) : value_roots(type, path)
      path.pop
      roots
    end

    private def instance_roots(type : Type, path : Array(Type)) : Array(Int32)
      children = layout_field_types(type.devirtualize).flat_map { |field| roots_of(field, false, path) }
      container(type, children, true)
    end

    private def value_roots(type : Type, path : Array(Type)) : Array(Int32)
      case type
      when TypeDefType
        roots_of(type.typedef, false, path)
      when AliasType
        if aliased = type.aliased_type?
          roots_of(aliased, false, path)
        else
          [] of Int32
        end
      when UnionType
        type.union_types.flat_map { |member| roots_of(member, false, path) }
      when ReferenceStorageType
        # Lowered as `llvm_struct_type` of the reference type (llvm_typer.cr,
        # `create_llvm_type(ReferenceStorageType)`). A class or other field-bearing
        # type lowers to its instance struct; tuples and static arrays lower to
        # their value layout, as their `create_llvm_struct_type` overloads show.
        target = type.reference_type
        instance_target = target.is_a?(InstanceVarContainer) &&
                          !(target.is_a?(TupleInstanceType) || target.is_a?(NamedTupleInstanceType) || target.is_a?(StaticArrayInstanceType))
        container(type, roots_of(target, instance_target, path))
      when StaticArrayInstanceType
        container(type, roots_of(type.element_type, false, path))
      when TupleInstanceType
        container(type, type.tuple_types.flat_map { |element| roots_of(element, false, path) })
      when NamedTupleInstanceType
        container(type, type.entries.flat_map { |entry| roots_of(entry.type, false, path) })
      else
        if type.struct? && type.is_a?(InstanceVarContainer)
          container(type, layout_field_types(type).flat_map { |field| roots_of(field, false, path) })
        else
          [] of Int32
        end
      end
    end

    # A container is open when an open layout lies somewhere below it by value,
    # so it has a node only when it has open children.
    private def container(type : Type, children : Array(Int32), instance : Bool = false) : Array(Int32)
      return [] of Int32 if children.empty?

      id = id_for(type, instance, witness_of(children.first))
      children.each { |child| union(id, child) }
      [id]
    end

    # The fields of an instance of `type`, in layout order. A superclass's fields
    # come first, as `index_of_instance_var` numbers them.
    private def layout_field_types(type : Type) : Array(Type)
      fields = [] of Type
      if superclass = type.superclass
        fields.concat layout_field_types(superclass)
      end
      if type.is_a?(InstanceVarContainer)
        type.instance_vars.each_value { |var| fields << var.type }
      end
      fields
    end
  end

  class Program
    getter layout_folds = Hash(ASTNode, LayoutFold).new.compare_by_identity
    getter layout_fold_lines = [] of String
    property layout_fold_state = LayoutFoldState::Unsettled

    # Every record bumps the epoch. A patched settle keeps the epoch it saw and
    # whether a fold reached a layout that can still move, so a later call settles
    # again only when there is something new (a second `semantic_after_top_level`,
    # as the fork probe runs one).
    @layout_fold_epoch = 0
    @layout_fold_settled_epoch = -1
    @layout_fold_open = false
    # Set while codegen types code of its own (`codegen_visit_main`).
    @layout_fold_codegen = false
    # Whether the cleanup's typer has been replaced since the last settle.
    @layout_fold_typer_fresh = false
    # The open layouts that a settled fold reaches, each with its fingerprint at
    # settle time. The code codegen types afterwards is checked against them.
    @layout_fold_watch : Hash(Type, String)? = nil
    # Fold literals by identity. A reader that takes one of their values records a
    # use (`layout_fold_uses`), and settling judges every use taken so far.
    @layout_fold_literals = Hash(NumberLiteral, LayoutFold).new.compare_by_identity
    # Every use of a fold value, in the order it was taken. A later settle keeps
    # them, so the uses taken before it are judged again.
    getter layout_fold_uses = [] of LayoutFoldUse
    # The readers in progress, innermost last (`layout_fold_consumer`, `layout_fold_derive`).
    @layout_fold_frames = [] of LayoutFoldFrame
    # The macro expansion frames in progress (`layout_fold_macro_expand`).
    @layout_fold_macro_frames = [] of LayoutFoldMacroFrame
    # Set while a macro is replayed under the final layout values (`layout_fold_macro_rerun`): the
    # fold literals that have no final value. A replay records nothing, and reading one of these stops it.
    @layout_fold_replay : Set(NumberLiteral)? = nil

    # Records what a fold site folded during typing. The latest record for a node
    # wins, and settling compares that record with the final layout.
    def record_layout_fold(fold : LayoutFold) : Nil
      @layout_folds[fold.node] = fold
      if literal = fold.node.as(ExpandableNode).expanded.as?(NumberLiteral)
        @layout_fold_literals[literal] = fold
      end
      @layout_fold_epoch += 1
    end

    # The fold a literal holds, if it is a fold literal.
    def layout_fold_of(literal : NumberLiteral) : LayoutFold?
      @layout_fold_literals[literal]?
    end

    # A consumer takes the fold values its block reads. A truthy value from the
    # block means the block built the decision, so its reads become uses of `kind`
    # at `site`. Anything else drops them, so a failed lookup takes nothing.
    def layout_fold_consumer(kind : LayoutFoldUseKind, site : ASTNode?, &)
      frames = @layout_fold_frames
      frames << LayoutFoldFrame.new(derive: false)
      begin
        value = yield
      ensure
        frame = frames.pop
      end
      if value && (pending = frame.pending)
        pending.each { |reads, derivation| @layout_fold_uses << LayoutFoldUse.new(kind, site, reads, derivation) }
        @layout_fold_epoch += 1
      end
      value
    end

    # The MathInterpreter computes `root` in `scope` for `target`, and its reads are
    # gathered here. Inside a consumer the computed value becomes the derivation of
    # that consumer's uses. Inside another derivation the reads pass up to it. With
    # neither, the reads are dropped.
    def layout_fold_derive(root : ASTNode, scope : Type, target : IntegerType?, &)
      frames = @layout_fold_frames
      frames << LayoutFoldFrame.new(derive: true)
      begin
        value = yield
      ensure
        frame = frames.pop
      end
      if (reads = frame.reads) && (parent = frames.last?)
        derivation = parent.derive ? nil : LayoutFoldDerivation.new(root, scope, target, value.to_s)
        layout_fold_take(reads, derivation)
      end
      value
    end

    # The MathInterpreter read a fold literal. With no reader open, nothing is taken.
    def layout_fold_read(literal : NumberLiteral) : Nil
      return if layout_fold_replaying?(literal)
      return if @layout_fold_frames.empty?
      fold = @layout_fold_literals[literal]? || return
      layout_fold_take([LayoutFoldRead.new(fold, literal, literal.value, false)], nil)
    end

    # Whether a macro replay is running, in which case nothing is recorded. A replay that reads a
    # fold literal with no final value has no value to read, so it stops.
    private def layout_fold_replaying?(literal : NumberLiteral) : Bool
      missing = @layout_fold_replay
      return false unless missing
      if missing.includes?(literal) && (fold = @layout_fold_literals[literal]?)
        raise ReplayUnknownException.new("it reads #{layout_fold_node(fold)}, whose final value can't be computed")
      end
      true
    end

    # A type variable took a fold literal itself. Inside a reader, that reader takes
    # it. With none open, it is a type argument use at once.
    def layout_fold_adopt(literal : NumberLiteral) : Nil
      if @layout_fold_replay
        raise ReplayUnknownException.new("it gives a layout to a type as an argument")
      end
      fold = @layout_fold_literals[literal]? || return
      read = LayoutFoldRead.new(fold, literal, literal.value, true)
      if @layout_fold_frames.empty?
        @layout_fold_uses << LayoutFoldUse.new(LayoutFoldUseKind::TypeArgument, nil, [read], nil)
        @layout_fold_epoch += 1
      else
        layout_fold_take([read], nil)
      end
    end

    # A decision took a fold literal's value at `site`. Inside a derivation the read
    # joins it. Otherwise it is a use at once, and a consumer does not take it.
    def layout_fold_use(literal : NumberLiteral, kind : LayoutFoldUseKind, site : ASTNode?, adopted : Bool = false) : Nil
      return if layout_fold_replaying?(literal)
      fold = @layout_fold_literals[literal]? || return
      read = LayoutFoldRead.new(fold, literal, literal.value, adopted)
      if (frame = @layout_fold_frames.last?) && frame.derive
        layout_fold_take([read], nil)
        if kind == LayoutFoldUseKind::Macro && !@layout_fold_macro_frames.empty?
          @layout_fold_macro_frames.each { |f| f.reads << read }
        end
      elsif kind == LayoutFoldUseKind::Macro && !@layout_fold_macro_frames.empty?
        @layout_fold_macro_frames.each { |f| f.reads << read }
      else
        @layout_fold_uses << LayoutFoldUse.new(kind, site, [read], nil)
        @layout_fold_epoch += 1
      end
    end

    # A macro reads a constant. Once the constant is cleaned, each fold literal in
    # its value is a macro use at `site`.
    def layout_fold_constant_read(const : Const, site : ASTNode?) : Nil
      return if @layout_fold_literals.empty? || !const.cleaned_up?
      const.value.accept LayoutFoldLiteralReads.new(self, site)
    end

    # Runs one macro expansion and keeps what it read. An expansion that read a fold literal is one
    # use, kept with what settling needs to replay it. With no fold literal in the program there is
    # nothing to read, so nothing is kept.
    def layout_fold_macro_expand(macro_def : Macro?, call : Call?, node : ASTNode?, scope : Type, path_lookup : Type, free_vars : Hash(String, TypeVar)?, a_def : Def?, &)
      return yield if @layout_fold_literals.empty? || @layout_fold_replay

      frame = LayoutFoldMacroFrame.new
      @layout_fold_macro_frames << frame
      temp_vars_start = @temp_vars.dup
      finished = false
      begin
        result = yield
        finished = true
        unless frame.reads.empty?
          derivation = LayoutFoldMacroDerivation.new(
            macro_def: macro_def,
            call: call,
            node: node,
            scope: scope,
            path_lookup: path_lookup,
            free_vars: free_vars.try(&.dup),
            a_def: a_def,
            temp_vars_start: temp_vars_start,
            original_output: result[0]
          )
          @layout_fold_uses << LayoutFoldUse.new(
            kind: LayoutFoldUseKind::Macro,
            site: (call || node),
            reads: frame.reads.uniq(&.literal.object_id),
            derivation: nil,
            macro_derivation: derivation
          )
          @layout_fold_epoch += 1
        end
        result
      ensure
        @layout_fold_macro_frames.pop
        # An expansion that left by an exception still read what it read, and what it did before it
        # left stands: `skip_file` skips the rest of its file. It gave no output to replay, so the
        # read is a use that any change makes harmful.
        if !finished && !frame.reads.empty?
          @layout_fold_uses << LayoutFoldUse.new(LayoutFoldUseKind::Macro, call || node,
            frame.reads.uniq(&.literal.object_id), nil)
          @layout_fold_epoch += 1
        end
      end
    end

    # Gives reads to the innermost reader. A derive frame keeps them for its own
    # derivation. A consumer keeps them as one pending use, with the derivation if
    # there is one.
    private def layout_fold_take(reads : Array(LayoutFoldRead), derivation : LayoutFoldDerivation?) : Nil
      frames = @layout_fold_frames
      frame = frames[-1]
      if frame.derive
        own = frame.reads || [] of LayoutFoldRead
        own.concat reads
        frames[-1] = LayoutFoldFrame.new(derive: true, reads: own)
      else
        pending = frame.pending || [] of {Array(LayoutFoldRead), LayoutFoldDerivation?}
        pending << {reads, derivation}
        frames[-1] = LayoutFoldFrame.new(derive: false, pending: pending)
      end
    end

    # Settles every recorded fold, and every use of a fold value taken so far,
    # against the final layout.
    #
    # `semantic_after_top_level` calls this after the last code the compiler types,
    # including what the cleanup types itself: the raise it writes for an
    # unreachable enum branch or an untyped expression, a tuple or proc literal it
    # retypes, a splat it expands. It runs after `RecursiveStructChecker`, since the
    # fresh typer lowers every folded type.
    #
    # A use is harmful when a value it read differs from the final value of its fold
    # and the decision that value shaped would change. A use with a derivation is
    # harmful only when recomputing the derivation from the final values gives a
    # different result. Then:
    # - a native program refuses the first harmful use, at the use, before anything
    #   is written;
    # - `--crystal` keeps the value the use read and pins the layouts it read. Every
    #   fold sharing one of them keeps its value too, so the expressions agree with
    #   the decision. The use is reported;
    # - a literal a type variable adopted is never written, since a type was built
    #   from its value.
    #
    # Any other fold takes its final value, written in place into the literal the
    # program holds. The cleanup has already put that literal wherever the fold was
    # used.
    #
    # A fold that cannot be recomputed keeps its value and is reported. With
    # `patch: false`, nothing in the AST changes. A patched settle gives a native
    # program the settling typer as its shared typer, so the GC tables and the
    # barrier read final layouts.
    def settle_layout_folds(patch : Bool) : Nil
      if layout_fold_state == LayoutFoldState::Patched
        return unless patch
        return if @layout_fold_settled_epoch == @layout_fold_epoch && !@layout_fold_open
      elsif !patch && layout_fold_state == LayoutFoldState::Reported
        return
      end

      {% if flag?(:without_llvm) %}
        # The LLVM-free front end has no layouts to settle against. Its layout
        # queries raise before any fold is recorded (program.cr), so there is
        # nothing to settle, and the front end is unchanged by this pass.
        self.layout_fold_state = patch ? LayoutFoldState::Patched : LayoutFoldState::Reported
      {% else %}
        settle_with_layouts(patch)
      {% end %}
    end

    # A native program's cleanup folds the layouts it types with a typer that
    # cached nothing while typing, so a module that grew while typing is lowered as
    # it is now. `--crystal` keeps the shared typer, so a type argument its cleanup
    # folds keeps the value Crystal 1.21.0 gives it. Codegen's own typing keeps the
    # typer that settling left.
    def fresh_layout_typer_for_cleanup : Nil
      {% unless flag?(:without_llvm) %}
        return unless iyi_prelude?
        return if @layout_fold_codegen || @layout_fold_typer_fresh
        @layout_fold_typer_fresh = true
        @llvm_typer = LLVMTyper.new(self, LLVM::Context.new)
      {% end %}
    end

    # Codegen types code of its own through `visit_main` (the raise for a cast, and
    # the raise for a proc passed to C). That typing can grow an open layout that a
    # settled fold reaches. The fold's value was settled before, and codegen has
    # already read it, so nothing can correct it now. A native program is refused,
    # since iyi owns that rule. `--crystal` keeps the value Crystal 1.21.0 gives,
    # which its own codegen gives too, and reports it under IYI_LAYOUT_FOLD_REPORT.
    def codegen_visit_main(node : ASTNode, visitor : MainVisitor = MainVisitor.new(self)) : Nil
      watch = @layout_fold_watch
      previous = @layout_fold_codegen
      @layout_fold_codegen = true
      begin
        visit_main node, visitor: visitor
      ensure
        @layout_fold_codegen = previous
      end
      return unless watch

      watch.each do |type, stamp|
        next if layout_fingerprint(type) == stamp
        if iyi_prelude?
          node.raise "codegen types code that grows #{type}, a layout that a layout fold settled before codegen reaches, so that fold's value would be stale, and codegen can't correct a value it has already read"
        elsif ENV["IYI_LAYOUT_FOLD_REPORT"]?
          location = node.location.try(&.to_s) || "unknown location"
          STDERR.puts "layout fold codegen grew: #{location}: codegen typed code that grows #{type}, a layout a settled fold reaches: kept (--crystal, as Crystal 1.21.0 keeps it)"
        end
      end
    end

    # What a layout's implementors are now, as a string. A new implementor or a new
    # subtype changes it.
    private def layout_fingerprint(type : Type) : String
      if type.is_a?(VirtualType)
        type.subtypes.map(&.to_s).join(",")
      elsif type.module?
        type.including_types.to_s
      else
        type.subclasses.map(&.to_s).join(",")
      end
    end

    # Prints the settled folds on stderr when IYI_LAYOUT_FOLD_REPORT is set. A
    # program not yet settled is settled here without patching, so a `--crystal`
    # run reports what it would keep.
    def report_layout_folds : Nil
      return unless ENV["IYI_LAYOUT_FOLD_REPORT"]?

      settle_layout_folds(patch: false)
      layout_fold_lines.each { |line| STDERR.puts line }
    end

    {% unless flag?(:without_llvm) %}
    private def settle_with_layouts(patch : Bool) : Nil
      native = iyi_prelude?
      report = ENV["IYI_LAYOUT_FOLD_REPORT"]?
      typer = LLVMTyper.new(self, LLVM::Context.new)
      graph = LayoutFoldGraph.new

      # The final value of each fold, computed once per subject and kind. A raise
      # can leave the typer holding a half-lowered type: a tuple is cached as an
      # opaque struct before its elements are lowered (llvm_typer.cr,
      # `create_llvm_type(TupleInstanceType)`), so a later fold in the same typer
      # would read that struct. Later folds get a fresh one.
      final_values = {} of {LayoutFoldKind, UInt64, Int32?} => {UInt64?, String?}
      final_of = ->(fold : LayoutFold) {
        key = {fold.kind, fold.subject.object_id, fold.index}
        final_values[key]? || begin
          final : UInt64? = nil
          failure : String? = nil
          begin
            final = recompute_layout_fold(fold, typer)
          rescue error : Exception
            failure = error.message || error.class.name
            typer = LLVMTyper.new(self, LLVM::Context.new)
          end
          final_values[key] = {final, failure}
        end
      }

      # The own and root node ids of a fold's subject, once per subject and layout kind.
      nodes = {} of {UInt64, Bool} => {Int32, Array(Int32)}
      walk = ->(fold : LayoutFold) {
        instance = instance_layout_kind?(fold.kind)
        nodes[{fold.subject.object_id, instance}] ||= {graph.id_for(fold.subject, instance), graph.roots_of(fold.subject, instance, [] of Type)}
      }

      # Every record, and every fold a use read, is walked before anything is pinned,
      # so the graph is complete when the pins look up their components.
      current = layout_folds.values
      current.each { |fold| walk.call(fold) }
      layout_fold_uses.each do |use|
        use.reads.each { |read| walk.call(read.fold) }
      end

      # Judges every use in the order it was taken. A read whose final value differs
      # makes its use harmful, unless the use's derivation gives the same result from
      # the final values.
      harms = [] of LayoutFoldHarm
      # The macro uses a replay found unchanged, each with the reads that changed.
      unchanged_macros = [] of {LayoutFoldUse, Array(LayoutFoldRead)}
      layout_fold_uses.each do |use|
        finals = use.reads.map { |read| final_of.call(read.fold)[0] }
        changed = [] of LayoutFoldRead
        use.reads.each_with_index do |read, i|
          final = finals[i]
          changed << read if final.nil? || final.to_s != read.value
        end
        next if changed.empty?

        if derivation = use.derivation
          rerun = layout_fold_rerun(use, derivation, finals)
          next if rerun && rerun == derivation.result
          harms << LayoutFoldHarm.new(use, changed, rerun)
        elsif macro_derivation = use.macro_derivation
          outcome, reason = layout_fold_macro_rerun(macro_derivation, final_of)
          case outcome
          in .equal?   then unchanged_macros << {use, changed}
          in .changed? then harms << LayoutFoldHarm.new(use, changed, "changed")
          in .unknown? then harms << LayoutFoldHarm.new(use, changed, reason || "unproven: the replay gave no reason")
          end
        else
          harms << LayoutFoldHarm.new(use, changed, nil)
        end
      end

      # A literal a type variable adopted is never written.
      held = Set(NumberLiteral).new.compare_by_identity
      layout_fold_uses.each do |use|
        use.reads.each { |read| held << read.literal if read.adopted }
      end

      # Every harmful use pins the layouts of each fold it read. The first use to pin
      # a component gives the tie that is reported.
      pinned = {} of Int32 => {String, LayoutFoldUseKind}
      pin = ->(harm : LayoutFoldHarm) {
        harm.changed.each do |read|
          own, roots = walk.call(read.fold)
          site = layout_fold_at(harm.use.site || read.fold.node)
          ([own] + roots).each { |id| pinned[graph.find(id)] ||= {site, harm.use.kind} }
        end
      }
      harms.each { |harm| pin.call(harm) }

      # A replay ran with every layout at its final value. A literal that is held, pinned or without
      # a final value keeps the value it folded instead. So a macro that read one of those and one
      # that is corrected was replayed with values the program will not have: its output is unproven,
      # and it pins what it read. A pin can make another macro mixed, so this runs until none is.
      keeps = ->(read : LayoutFoldRead) {
        own, roots = walk.call(read.fold)
        held.includes?(read.literal) || final_of.call(read.fold)[0].nil? ||
          ([own] + roots).any? { |id| pinned.has_key?(graph.find(id)) }
      }
      loop do
        mixed, unchanged_macros = unchanged_macros.partition do |(_, changed)|
          kept = changed.count { |read| keeps.call(read) }
          kept > 0 && kept < changed.size
        end
        break if mixed.empty?
        mixed.each do |(use, changed)|
          harm = LayoutFoldHarm.new(use, changed, "unproven: another use keeps one of the layouts it read at the value it folded")
          harms << harm
          pin.call(harm)
        end
      end

      # A native program refuses the first harmful use, before anything is written.
      if native && patch && (refused = harms.first?)
        refused_read = refused.changed.first
        refused_final, refused_failure = final_of.call(refused_read.fold)
        refused_inner = TypeException.for_node(refused_read.fold.node, "#{layout_fold_node(refused_read.fold)} measured #{refused_read.value} here")
        (refused.use.site || refused_read.fold.node).raise layout_fold_harm_message(refused, refused_read, refused_final, refused_failure), inner: refused_inner
      end

      # The kind of harmful use that kept each fold literal. A type argument is named first.
      kept_by = Hash(NumberLiteral, LayoutFoldUseKind).new.compare_by_identity
      harms.each do |harm|
        harm.changed.each do |read|
          kind = harm.use.kind
          kept_by[read.literal] = kind if kept_by[read.literal]?.nil? || kind == LayoutFoldUseKind::TypeArgument
        end
      end

      lines = [] of String
      current.each do |fold|
        literal = fold.node.as(ExpandableNode).expanded.as?(NumberLiteral)
        final, failure = final_of.call(fold)
        own, roots = walk.call(fold)
        tie = ([own] + roots).compact_map { |id| pinned[graph.find(id)]? }.first?
        held_here = literal ? held.includes?(literal) : false

        # A pinned literal keeps the value its uses read.
        if patch && final && literal && !held_here && !tie
          target = final.to_s
          literal.value = target unless literal.value == target
        end

        if report && !roots.empty?
          lines << "layout fold open: #{layout_fold_location(fold)}: #{layout_fold_node(fold)} in #{layout_fold_owner(fold)}: #{fold.subject} holds #{graph.witness_of(roots.first)} by value"
        end
        next if final && final == fold.value
        next unless report

        kind = literal ? kept_by[literal]? : nil
        disposition =
          if final.nil?
            "kept (cannot recompute: #{failure})"
          elsif kind == LayoutFoldUseKind::TypeArgument
            "kept (type argument)"
          elsif kind == LayoutFoldUseKind::Typing || held_here
            "kept (used by later typing)"
          elsif tie
            "kept (tied to #{layout_fold_pin_name(tie[1])} at #{tie[0]})"
          elsif literal.nil?
            "kept (no literal)"
          elsif !patch
            "kept (--crystal)"
          else
            "corrected"
          end

        final_text = final ? final.to_s : "unknown"
        lines << "layout fold stale: #{layout_fold_location(fold)}: #{layout_fold_node(fold)} in #{layout_fold_owner(fold)}: folded #{fold.value}, final #{final_text}: #{disposition}"
      end

      if report
        harms.each do |harm|
          read = harm.changed.first
          lines << layout_fold_harm_line(harm, read, final_of.call(read.fold)[0])
        end
      end

      if patch
        watch = Hash(Type, String).new.compare_by_identity
        current.each do |fold|
          _, roots = walk.call(fold)
          roots.each do |id|
            witness = graph.witness_of(id)
            watch[witness] ||= layout_fingerprint(witness)
          end
        end
        @layout_fold_watch = watch
        @llvm_typer = typer if native
        @layout_fold_typer_fresh = false
        @layout_fold_settled_epoch = @layout_fold_epoch
        @layout_fold_open = current.any? { |fold| !walk.call(fold)[1].empty? }
      end
      @layout_fold_lines = lines
      self.layout_fold_state = patch ? LayoutFoldState::Patched : LayoutFoldState::Reported
    end

    # Recomputes a derivation from the final values of the literals its use read.
    # The rerun has no visitor and no reader open, so it takes nothing. A macro
    # call in it raises, and a missing final value gives no result. Either way the
    # rerun gives nil.
    private def layout_fold_rerun(use : LayoutFoldUse, derivation : LayoutFoldDerivation, finals : Array(UInt64?)) : String?
      values = Hash(NumberLiteral, String).new.compare_by_identity
      use.reads.each_with_index do |read, i|
        final = finals[i]
        return nil unless final
        values[read.literal] = final.to_s
      end
      interpreter = MathInterpreter.new(derivation.scope, nil, derivation.target, layout_values: values)
      layout_fold_interpret(interpreter, derivation.root).to_s
    rescue CodeError
      nil
    end

    # Replays a macro expansion with every fold literal at its final value, and says whether its
    # output is the text the program compiled.
    #
    # It is the same interpreter over the same macro and the same call. What differs is held here.
    # Every fold literal carries its final value while the replay runs and has its own back after
    # it, so a constant reads as it will once settling is done whatever shape its value has. The
    # temporary-name counters start where the expansion started them and are put back.
    # `@layout_fold_replay` stops every recorder, and the interpreter refuses whatever would reach
    # outside the compiler or change the program (`MacroInterpreter#replay?`). A replay that
    # stops says nothing about the output, and the reason it stopped travels with the outcome:
    # `external:` when the answer lies outside the compiler, `unproven:` when the replay is the limit.
    private def layout_fold_macro_rerun(derivation : LayoutFoldMacroDerivation,
                                        final_of : Proc(LayoutFold, {UInt64?, String?})) : {MacroRerunOutcome, String?}
      missing = Set(NumberLiteral).new.compare_by_identity
      restore = [] of {NumberLiteral, String}
      saved_temp_vars = @temp_vars
      begin
        @layout_fold_literals.each do |literal, fold|
          if final = final_of.call(fold)[0]
            target = final.to_s
            next if literal.value == target
            restore << {literal, literal.value}
            literal.value = target
          else
            missing << literal
          end
        end
        @temp_vars = derivation.temp_vars_start.dup
        @layout_fold_replay = missing

        if a_macro = derivation.macro_def
          call = derivation.call
          return {MacroRerunOutcome::Unknown, "unproven: the expansion kept no call to replay"} unless call
          interpreter = MacroInterpreter.new(self, derivation.scope, derivation.path_lookup, a_macro, call, derivation.a_def, in_macro: true)
          interpreter.replay = true
          a_macro.body.accept interpreter
        elsif node = derivation.node
          interpreter = MacroInterpreter.new(self, derivation.scope, derivation.path_lookup, node.location, def: derivation.a_def, in_macro: false)
          interpreter.free_vars = derivation.free_vars
          interpreter.replay = true
          node.accept interpreter
        else
          return {MacroRerunOutcome::Unknown, "unproven: the expansion kept no macro to replay"}
        end

        output = interpreter.to_s
        if output == derivation.original_output
          {MacroRerunOutcome::Equal, nil}
        elsif layout_fold_temp_name?(output) || layout_fold_temp_name?(derivation.original_output)
          {MacroRerunOutcome::Unknown, "unproven: its output holds names the compiler numbers as it goes, and the replay numbered them differently"}
        else
          {MacroRerunOutcome::Changed, nil}
        end
      rescue error : ReplayUnknownException
        {MacroRerunOutcome::Unknown, "#{error.external? ? "external" : "unproven"}: #{error.message}"}
      rescue MacroRaiseException
        # The macro raises under the final layout, and it did not when it ran.
        {MacroRerunOutcome::Changed, nil}
      rescue error : CodeError
        {MacroRerunOutcome::Unknown, "unproven: the replay stopped on an error the expansion did not meet: #{error.message}"}
      ensure
        @layout_fold_replay = nil
        @temp_vars = saved_temp_vars
        restore.each { |(literal, value)| literal.value = value }
      end
    end

    # Whether *text* holds a name `new_temp_var_name` gives.
    private def layout_fold_temp_name?(text : String) : Bool
      text.includes?("__temp_") || @temp_vars.each_key.any? { |prefix| text.includes?(prefix) }
    end

    # `MathInterpreter#interpret` is overloaded by node type, so the root is dispatched
    # on its type here. A root of any other type reaches the generic overload, which raises.
    private def layout_fold_interpret(interpreter : MathInterpreter, root : ASTNode)
      case root
      when NumberLiteral then interpreter.interpret(root)
      when Call          then interpreter.interpret(root)
      when Path          then interpreter.interpret(root)
      when Expressions   then interpreter.interpret(root)
      else                    interpreter.interpret(root)
      end
    end

    private def instance_layout_kind?(kind : LayoutFoldKind) : Bool
      case kind
      when LayoutFoldKind::InstanceSize, LayoutFoldKind::InstanceAlign, LayoutFoldKind::InstanceOffset
        true
      else
        false
      end
    end

    private def recompute_layout_fold(fold : LayoutFold, typer : LLVMTyper) : UInt64
      subject = fold.subject
      case fold.kind
      when LayoutFoldKind::Size
        size_of(subject, typer).to_u64
      when LayoutFoldKind::Align
        align_of(subject, typer).to_u64
      when LayoutFoldKind::InstanceSize
        instance_size_of(subject, typer).to_u64
      when LayoutFoldKind::InstanceAlign
        instance_align_of(subject, typer).to_u64
      when LayoutFoldKind::Offset
        offset_of(subject, fold.index.not_nil!, typer).to_u64
      else
        instance_offset_of(subject, fold.index.not_nil!, typer).to_u64
      end
    end
    {% end %}

    # The place a node is written, as a report names it.
    private def layout_fold_at(node : ASTNode) : String
      node.location.try(&.to_s) || "unknown location"
    end

    # What a harmful use is, in a report line.
    private def layout_fold_use_kind_name(kind : LayoutFoldUseKind) : String
      case kind
      when LayoutFoldUseKind::TypeArgument then "a type argument"
      when LayoutFoldUseKind::EnumValue    then "an enum value"
      when LayoutFoldUseKind::Macro        then "a macro"
      else                                      "typing"
      end
    end

    # What a use that tied a layout is, in a fold's disposition.
    private def layout_fold_pin_name(kind : LayoutFoldUseKind) : String
      case kind
      when LayoutFoldUseKind::TypeArgument then "type argument"
      when LayoutFoldUseKind::EnumValue    then "an enum value"
      when LayoutFoldUseKind::Macro        then "a macro read"
      else                                      "typing"
      end
    end

    # The refusal for a harmful use, from the read that changed. It says what the
    # final layout would change, and why nothing can correct that after the fact.
    private def layout_fold_harm_message(harm : LayoutFoldHarm, read : LayoutFoldRead, final : UInt64?, failure : String?) : String
      label = layout_fold_node(read.fold)
      derivation = harm.use.derivation
      case harm.use.kind
      when LayoutFoldUseKind::TypeArgument
        built = derivation ? "#{derivation.result} was computed from #{label} = #{read.value}" : "#{label} was #{read.value}"
        if final.nil?
          "#{built} when it was used as a type argument, but its final value can't be checked (#{failure}), so the type argument can't be verified"
        elsif derivation
          "#{built} when it was used as a type argument, but its final value is #{final}, which gives #{harm.rerun || "no value"}. " \
          "A type argument can't be corrected after it is used, so measure it after the layout is final, or use the value as an expression"
        else
          "#{built} when it was used as a type argument, but its final value is #{final}. " \
          "A type argument can't be corrected after it is used, so measure it after the layout is final, or use the value as an expression"
        end
      when LayoutFoldUseKind::EnumValue
        shown = derivation ? derivation.result : read.value
        source = derivation ? "computed from #{label} = #{read.value}" : "read from #{label}"
        if final.nil?
          "this enum value is #{shown}, #{source}, but its final value can't be checked (#{failure}), so the enum value can't be verified"
        else
          gives = derivation ? ", which gives #{harm.rerun || "no value"}" : ""
          "this enum value is #{shown}, #{source}, but its final value is #{final}#{gives}. " \
          "An enum's values are fixed when it is declared, so measure the layout after it is final"
        end
      when LayoutFoldUseKind::Macro
        rerun = harm.rerun
        if final.nil?
          "a macro read #{label} as #{read.value}, but its final value can't be checked (#{failure}), so the macro's output can't be verified"
        elsif rerun && rerun.starts_with?("external: ")
          "a macro read #{label} as #{read.value}, but its final value is #{final}. " \
          "Whether that changes the macro's output can't be known without running it again: #{rerun.lchop("external: ")}. " \
          "Measure it after the layout is final, or use the value as an expression"
        elsif rerun && rerun.starts_with?("unproven: ")
          "a macro read #{label} as #{read.value}, but its final value is #{final}. " \
          "The compiler could not show that the macro's output is unchanged: #{rerun.lchop("unproven: ")}. " \
          "Measure it after the layout is final, or use the value as an expression"
        else
          "a macro read #{label} as #{read.value}, but its final value is #{final}. " \
          "A macro's output can't be corrected, so measure it after the layout is final"
        end
      else
        if final.nil?
          "typing read #{label} as #{read.value} here, but its final value can't be checked (#{failure}), so the decision can't be verified"
        else
          "typing read #{label} as #{read.value} here, but its final value is #{final}. " \
          "That decision can't be undone, so measure it after the layout is final"
        end
      end
    end

    # The report line for one harmful use, from the read that changed.
    private def layout_fold_harm_line(harm : LayoutFoldHarm, read : LayoutFoldRead, final : UInt64?) : String
      site = harm.use.site || read.fold.node
      computed = ""
      if derivation = harm.use.derivation
        computed = ", computed #{derivation.result}, final gives #{harm.rerun || "no value"}"
      elsif harm.use.macro_derivation
        computed = ", macro output #{harm.rerun || "unknown"}"
      end
      final_text = final ? final.to_s : "unknown"
      "layout fold use stale: #{layout_fold_at(site)}: #{layout_fold_use_kind_name(harm.use.kind)} read #{layout_fold_node(read.fold)} at #{layout_fold_location(read.fold)} as #{read.value}, final #{final_text}#{computed}: kept (--crystal, as Crystal 1.21.0 keeps it)"
    end

    private def layout_fold_node(fold : LayoutFold) : String
      name = case fold.kind
             when LayoutFoldKind::Size then "sizeof"
             when LayoutFoldKind::Align then "alignof"
             when LayoutFoldKind::InstanceSize then "instance_sizeof"
             when LayoutFoldKind::InstanceAlign then "instance_alignof"
             else "offsetof"
             end
      "#{name}(#{fold.subject})"
    end

    private def layout_fold_location(fold : LayoutFold) : String
      fold.node.location.try(&.to_s) || "unknown location"
    end

    private def layout_fold_owner(fold : LayoutFold) : String
      fold.owner.as?(Def).try(&.name) || "main"
    end
  end
end
