# iyi: heap22's code generation (SPEC.md III.4.19, PROPOSED): what a
# `-Dheap_partitions` build emits so that a pointer never crosses from one
# unit's heap into another's unpublished. Without the flag none of it is
# emitted and the program is byte for byte what it was.
#
# - A trusted type the runtime implements a crossing for (`Mutex`,
#   `Channel`, `Unit`'s handle, and the runtime's fibers, units, waiters,
#   send nodes and threads) is born in the shared heap: `__iyi_new_shared`
#   rather than `__iyi_new` (`allocate_aggregate`).
# - A class variable's store of a value with pointers publishes it
#   (`__iyi_publish`), outside the prelude: a unit may store a graph of its
#   own into a Share class variable another unit reads, or into a
#   thread-local one the next unit on the thread reads.
# - A crossing block's closure (C1) is a typed context of its own holding
#   only what the block captures, copied in where the block is made, with
#   no link to the scope's context, whose other slots would otherwise be
#   published with it (`visit(ProcLiteral)`). A struct it captures is
#   boxed: the scope's variable lives in a cell of its own and the context
#   holds the cell's address (`MetaVar#iyi_boxed?`).
#
# `IYI_SPAWN_BROKEN` takes `c1`, `classvar-publish` and `new-shared`, each
# turning one of these off, for the verifier's broken copies.
class Iyi::CodeGenVisitor
  IYI_NEW_SHARED_NAME = "__iyi_new_shared"
  IYI_PUBLISH_NAME    = "__iyi_publish"

  # The runtime's own types, born in the shared heap whatever unit makes
  # them (heap22 row 14), and std's trusted types whose constructors keep
  # every pointer they store shared (rows 3, 4, 4b). A library's `@[Share]`
  # type is not one: its constructor stores what its caller hands it, and
  # a shared object holding a unit's pointer is what the partition forbids.
  IYI_BORN_SHARED = {"IyiFiber", "IyiUnit", "IyiWaiter", "IyiSendNode", "IyiThread", "Mutex", "Channel", "Unit"}

  # The ids C1 contexts are typed with, above every id the program's types
  # take (`LLVMId` numbers those from 1, and a program has nowhere near a
  # billion), and the layout each one has, for the collector's table.
  IYI_C1_FIRST_ID = 0x4000_0000

  @iyi_c1_layouts = [] of IyiMod::TypeLayout
  @iyi_born_shared = {} of Type => Bool
  @iyi_heap_partitions : Bool?
  @iyi_new_shared_fun : LLVMTypedFunction?

  def iyi_heap_partitions? : Bool
    flag = @iyi_heap_partitions
    return flag unless flag.nil?
    @iyi_heap_partitions = @program.has_flag?("heap_partitions") && @program.iyi_gc_arena?
  end

  getter iyi_c1_layouts

  # Whether *type*'s instances are born shared (`IYI_BORN_SHARED`).
  def iyi_born_shared?(type : Type) : Bool
    return false unless iyi_heap_partitions?
    return false if SPAWN_BROKEN.includes?("new-shared")
    @iyi_born_shared.fetch(type) do
      base = type.is_a?(GenericClassInstanceType) ? type.generic_type.as(Type) : type
      @iyi_born_shared[type] = !type.struct? && base.is_a?(NamedType) &&
                               IYI_BORN_SHARED.includes?(base.name) && iyi_born_shared_home?(base) &&
                               @program.iyi_share_reach.std_at?(base.locations.try(&.first?))
    end
  end

  # Where a born-shared type is declared: the prelude's at the top level,
  # std's in the module of its own name (`Std::Mutex::Mutex`,
  # `Std::Unit::Unit`; a std module's types are in `Std::<module>`).
  private def iyi_born_shared_home?(type : NamedType) : Bool
    namespace = type.namespace
    return true if namespace.is_a?(Program)
    return false unless namespace.is_a?(NamedType) && namespace.name == type.name
    std = namespace.namespace
    std.is_a?(NamedType) && std.name == "Std" && std.namespace.is_a?(Program)
  end

  def iyi_new_shared_fun
    new_fun = @iyi_new_shared_fun ||= fetch_typed_fun(@main_mod, IYI_NEW_SHARED_NAME) do
      int64 = @main_llvm_context.int64
      LLVM::Type.function([int64, int64, int64], @main_llvm_context.void_pointer)
    end
    check_main_fun IYI_NEW_SHARED_NAME, new_fun
  end

  def iyi_publish_fun
    publish = fetch_typed_fun(@main_mod, IYI_PUBLISH_NAME) do
      LLVM::Type.function([@main_llvm_context.void_pointer], @main_llvm_context.void)
    end
    check_main_fun IYI_PUBLISH_NAME, publish
  end

  # After a class variable's store at *pointer*: each word of the stored
  # value handed to `__iyi_publish`, which answers at once for a word that
  # is no pointer into the running unit's own heap. Not in the prelude,
  # whose class variables are the runtime's, claimed `@[UnsafeReach]` and
  # written in the shared heap, some of them on every switch.
  def iyi_publish_class_var_store(pointer : LLVM::Value, type : Type, node : ASTNode) : Nil
    return unless iyi_heap_partitions?
    return if SPAWN_BROKEN.includes?("classvar-publish")
    return unless type.has_inner_pointers?
    return if @program.iyi_share_reach.prelude_at?(node.location)
    publish = iyi_publish_fun
    words = llvm_typer.size_of(llvm_type(type)) // 8
    return if words == 0
    base = pointer_cast(pointer, llvm_context.int64.pointer)
    words.times do |index|
      word = load(llvm_context.int64, gep(llvm_context.int64, base, index.to_i32))
      call publish, [builder.int2ptr(word, llvm_context.void_pointer)]
    end
  end

  # heap22 C1: the context a crossing block's proc is made with, in place
  # of the scope's. Answers the proc's function and the context pointer, or
  # nil when the block captures something the scope does not hold as a
  # variable here, or a struct that was not boxed, and the scope's context
  # is used as before.
  def iyi_c1_proc(node : ProcLiteral, fun_literal_name : String, host) : {LLVMTypedFunction, LLVM::Value}?
    return nil unless iyi_heap_partitions? && node.iyi_crossing?
    return nil if SPAWN_BROKEN.includes?("c1")
    a_def = node.def
    metas = [] of MetaVar
    sources = [] of LLVMVar
    def_vars = a_def.vars
    node.iyi_capture_names.each do |name|
      meta = def_vars.try &.[name]?
      next unless meta && meta.closured? && !meta.belongs_to?(a_def) && (meta_type = meta.type?)
      return nil unless meta.iyi_boxed? || ProcLiteral.iyi_copyable?(meta_type)
      source = context.vars[name]?
      return nil unless source && source.type == meta_type
      return nil if meta.iyi_boxed? && source.already_loaded
      metas << meta
      sources << source
    end
    # A struct `self` is no variable to box: the scope's context holds the
    # copy it took where that context was made (`malloc_closure`), and a
    # copy taken here could differ from it, so the block keeps the scope's
    # context, which is published whole: sound, and what it costs is the
    # retention of the scope's other slots.
    self_type = iyi_chain_self(context)
    return nil if metas.empty? && self_type.nil?
    return nil if self_type && !ProcLiteral.iyi_copyable?(self_type)

    closure_type, pointerful = llvm_typer.closure_context_type(metas, nil, self_type)
    closure_ptr = iyi_c1_allocate(closure_type, pointerful, metas, self_type)

    metas.each_with_index do |meta, index|
      source = sources[index]
      slot = gep(closure_type, closure_ptr, 0, index, meta.name)
      if meta.iyi_boxed?
        iyi_with_write_barrier(slot, @program.pointer_of(meta.type)) do
          store source.pointer, slot
        end
      else
        value = source.already_loaded ? source.pointer : load(llvm_type(meta.type), source.pointer)
        iyi_with_write_barrier(slot, meta.type) do
          store value, slot
        end
      end
    end
    if self_type
      slot = gep(closure_type, closure_ptr, 0, metas.size, "self")
      iyi_with_write_barrier(slot, self_type) do
        store_value llvm_self, self_type, slot, fresh: true
      end
    end

    saved_vars = context.closure_vars
    saved_type = context.closure_type
    saved_ptr = context.closure_ptr
    saved_skip = context.closure_skip_parent
    saved_parent = context.closure_parent_context
    saved_self = context.closure_self
    context.closure_vars = metas
    context.closure_type = closure_type
    context.closure_ptr = closure_ptr
    context.closure_skip_parent = false
    context.closure_parent_context = nil
    context.closure_self = self_type
    begin
      the_fun = codegen_fun fun_literal_name, a_def, context.type,
        fun_module_info: host || @main_module_info, is_fun_literal: true,
        is_closure: true, iyi_internal: !host.nil?
    ensure
      context.closure_vars = saved_vars
      context.closure_type = saved_type
      context.closure_ptr = saved_ptr
      context.closure_skip_parent = saved_skip
      context.closure_parent_context = saved_parent
      context.closure_self = saved_self
    end
    {the_fun, closure_ptr}
  end

  # The `self` the scope's closure chain holds, as `setup_closure_vars`
  # would find it for a proc made here.
  private def iyi_chain_self(ctx : Context) : Type?
    if ctx.closure_skip_parent
      parent = ctx.closure_parent_context
      return parent ? iyi_chain_self(parent) : nil
    end
    if (parent = ctx.closure_parent_context) && parent.closure_vars
      iyi_chain_self(parent)
    else
      ctx.closure_self
    end
  end

  # A C1 context: through `__iyi_new` with an id of its own and a layout in
  # the collector's table, so the mark, the publication walk and the
  # verifier read it precisely; untyped in a build that writes artifacts,
  # whose object code another program links with its own numbering.
  private def iyi_c1_allocate(closure_type : LLVM::Type, pointerful : Bool, metas : Array(MetaVar), self_type : Type?) : LLVM::Value
    if @iyi_closure_host.nil? && @program.iyi_exported_owners.empty? && (new_fun = iyi_new_fun)
      id = IYI_C1_FIRST_ID + @iyi_c1_layouts.size
      slots = metas.map { |meta| meta.iyi_boxed? ? @program.pointer_of(meta.type) : meta.type }
      slots << self_type if self_type
      @iyi_c1_layouts << @program.gc_closure_layout(id, llvm_typer, closure_type, slots)
      flags = pointerful ? 1_i64 : 3_i64
      pointer_cast call(new_fun, [closure_type.size, int64(id), int64(flags)]), closure_type.pointer
    else
      pointerful ? malloc(closure_type) : malloc_atomic(closure_type)
    end
  end
end
