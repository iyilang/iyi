# iyi: the preemption check at a loop's back-edge (SPEC.md III.4.13, part 9),
# put in after LLVM has optimised the module and before it generates code.
#
# Codegen marks the back-edge of every loop that may give its worker up -
# a loop of a def in a program with a pool, not the prelude's (`codegen.cr`,
# `iyi_back_edge`) - with a loop property, `!"iyi.preempt"`, in the loop's
# `!llvm.loop` metadata, and emits nothing else there. Emitted as code at
# that point, the check was a volatile load inside the loop, and LLVM
# vectorises no loop with one: summing a million `Int64`s 500 times took
# 126 ms against 48 without it. A loop property is what LLVM carries through
# its own loop passes - rotated, unrolled, vectorised, the vector body and
# the scalar remainder both keep it - so the check goes in here, once per
# latch that is left, where it costs a load and a branch per vector
# iteration rather than a vector loop.
#
# The check is the worker's preemption word read through the thread pointer
# as it is at the back-edge (a parallel task may resume on another worker
# after the call), a branch, and the call to `__iyi_preempt` on the cold
# side: on x86-64 Linux `cmpq $0, %fs:off`, the offset a link-time constant
# held in a register; on aarch64 Linux a volatile `mrs` of `tpidr_el0` plus
# the offset, the read every thread-local takes there
# (`CodeGenVisitor#iyi_tpidr_el0`). Mach-O and COFF have no local-exec, and
# every other thread-local there is read through an accessor call
# (`CodeGenVisitor#get_thread_local`), which the check took at first too:
# a call per turn cost a vectorised sum 5.3 to 5.8 times its unchecked twin
# on a darwin arm64 runner and 3.4 to 4.9 times on a Windows one. So x86-64
# Windows reads a TEB slot of the pool's own, `cmpq $0, %gs:off` as Linux
# reads `%fs`, and darwin arm64 the thread's pthread slots through
# `tpidrro_el0`, each a read no optimisation moves out of a loop, the
# offset and the slot's index from the function's entry (`entry_value`).
# x86-64 darwin and arm64 Windows keep the accessor call.
#
# Recursion with no loop in it has no back-edge, and gets the same check at
# the entry of each function on a call cycle (`mark_recursion`).
module Iyi::PreemptChecks
  MARK = "iyi.preempt"

  # The call that stands for a check at a function's entry from codegen
  # until optimisation is done (`mark_recursion`), and that `run` replaces
  # with one.
  ENTRY = "__iyi_preempt_entry"

  # `memory(inaccessiblemem: readwrite)` as the `memory` attribute's
  # integer: two bits per location, read and write both set (3), for
  # inaccessible memory, location 1 in every LLVM since the attribute
  # replaced `readnone` and its kin (LLVM 16). What aarch64's thread
  # pointer read is marked with, so LLVM neither merges two of them nor
  # moves one out of a loop.
  INACCESSIBLE_READ_WRITE = 3_u64 << 2

  # darwin's and Windows' checks made the first way, the accessor called
  # at every back-edge (`-Dpreempt_check_accessor`, `Compiler#preempt_checks`).
  class_property? accessor_only = false

  # darwin's anchor made in the entry block, as it was before `Loops`
  # (`-Dpreempt_anchor_entry`, `Compiler#preempt_checks`).
  class_property? anchor_at_entry = false

  # *flag* is the preemption word's global (`IyiWorkers::preempt`), and the
  # thread-local accessor is `*` and that name.
  def self.run(mod : LLVM::Module, flag : String, linux : Bool, aarch64 : Bool) : Nil
    ctx = mod.context
    kind = LibLLVM.get_md_kind_id_in_context(ctx, "llvm.loop", 9)
    builder = LLVM::Builder.new(LibLLVM.create_builder_in_context(ctx))
    entries = entry_calls(mod)
    fn = LibLLVM.get_first_function(mod)
    until fn.null?
      latches = [] of LibLLVM::BasicBlockRef
      block = LibLLVM.get_first_basic_block(fn)
      until block.null?
        terminator = LibLLVM.get_basic_block_terminator(block)
        latches << block if !terminator.null? && marked?(LibLLVM.get_metadata(terminator, kind))
        block = LibLLVM.get_next_basic_block(block)
      end
      calls = entries[fn.address]?
      unless latches.empty? && calls.nil?
        sites = latches.map { |latch| {latch, LibLLVM.get_basic_block_terminator(latch)} }
        if calls
          # The instruction after each call that is not itself one: two
          # functions on a cycle inlined one into the other leave their
          # calls side by side, and the first call's next instruction was
          # the second, erased before its check went in - a check on a
          # freed instruction, which crashed the compiler on
          # bench/std_http_latency.iyi in --release. Two calls in a row
          # make one check.
          erased = calls.map(&.address).to_set
          seen = Set(UInt64).new
          calls.each do |call|
            following = LibLLVM.get_next_instruction(call)
            while erased.includes?(following.address)
              following = LibLLVM.get_next_instruction(following)
            end
            sites << {LibLLVM.get_instruction_parent(following), following} if seen.add?(following.address)
          end
          calls.each { |call| LibLLVM.instruction_erase_from_parent(call) }
        end
        # Every anchor first, on the function as optimisation left it, and
        # then every check, which splits the blocks it is in.
        anchors = if placed?(mod, linux, aarch64)
                    loops = Loops.new(fn)
                    made = {} of UInt64 => LLVM::Value
                    sites.map do |block, _|
                      spot = loops.outside(block)
                      made.put_if_absent(spot.try(&.address) || 0_u64) { entry_value(mod, builder, ctx, fn, flag, linux, aarch64, spot) }
                    end
                  else
                    anchor = entry_value(mod, builder, ctx, fn, flag, linux, aarch64, nil)
                    sites.map { anchor }
                  end
        # A check's block is asked where it is now: one check before it
        # may have moved its instruction into a block of its own.
        sites.each_with_index do |(_, first), index|
          check(mod, builder, ctx, LibLLVM.get_instruction_parent(first), first, flag, linux, aarch64, anchors[index])
        end
      end
      fn = LibLLVM.get_next_function(fn)
    end
    if entry = mod.functions[ENTRY]?
      LibLLVM.delete_function(entry)
    end
  end

  # The calls to `ENTRY` left after optimisation, by the address of the
  # function each is in.
  private def self.entry_calls(mod : LLVM::Module) : Hash(UInt64, Array(LibLLVM::ValueRef))
    calls = {} of UInt64 => Array(LibLLVM::ValueRef)
    return calls unless entry = mod.functions[ENTRY]?
    use = LibLLVM.get_first_use(entry)
    until use.null?
      call = LibLLVM.get_user(use)
      fn = LibLLVM.get_basic_block_parent(LibLLVM.get_instruction_parent(call))
      (calls[fn.address] ||= [] of LibLLVM::ValueRef) << call
      use = LibLLVM.get_next_use(use)
    end
    calls
  end

  # iyi: a check at the entry of every function on a call cycle among the
  # functions whose loops check (*names*, `Program#iyi_preempt_funs`), put
  # in before optimisation across every module of the program, since a
  # cycle may cross them. A naive `fib` has no loop and so no back-edge,
  # and held a worker for as long as it recursed.
  #
  # What goes in is a call to `ENTRY`, a function LLVM is told touches
  # only memory nothing else names, so it optimises around it as around
  # nothing - except that it never removes it nor moves it out of a loop -
  # and `run` replaces it with the check once optimisation is done. Put in
  # here rather than there, because LLVM turns a call in tail position
  # into a branch back to the function's top: the call to `ENTRY` at the
  # top is then in the loop that made, and checks at every turn of it.
  #
  # A cycle is found among direct calls, so recursion through a `Proc` is
  # not one.
  def self.mark_recursion(mods : Array(LLVM::Module), names : Array(String)) : Nil
    return if names.empty?
    ids = {} of String => Int32
    names.each { |name| ids[name] ||= ids.size }
    # Every function of those names, by address - its definition, or the
    # declaration another module's calls name it by - and its node.
    node_of = {} of UInt64 => Int32
    bodies = [] of {LLVM::Module, LibLLVM::ValueRef, Int32}
    mods.each do |mod|
      fn = LibLLVM.get_first_function(mod)
      until fn.null?
        name = LibLLVM.get_value_name2(fn, out length)
        if id = ids[String.new(name, length)]?
          node_of[fn.address] = id
          bodies << {mod, fn, id} unless LibLLVM.get_first_basic_block(fn).null?
        end
        fn = LibLLVM.get_next_function(fn)
      end
    end
    calls = Array(Array(Int32)).new(ids.size) { [] of Int32 }
    bodies.each do |_, fn, id|
      block = LibLLVM.get_first_basic_block(fn)
      until block.null?
        inst = LibLLVM.get_first_instruction(block)
        until inst.null?
          unless LibLLVM.is_a_call_inst(inst).null? && LibLLVM.is_a_invoke_inst(inst).null?
            callee = LibLLVM.get_operand(inst, (LibLLVM.get_num_operands(inst) - 1).to_u32)
            if target = node_of[callee.address]?
              calls[id] << target
            end
          end
          inst = LibLLVM.get_next_instruction(inst)
        end
        block = LibLLVM.get_next_basic_block(block)
      end
    end
    cyclic = on_cycle(calls)
    bodies.each do |mod, fn, id|
      next unless cyclic[id]
      ctx = mod.context
      builder = LLVM::Builder.new(LibLLVM.create_builder_in_context(ctx))
      # After the entry block's allocas, which stay where LLVM promotes them.
      inst = LibLLVM.get_first_instruction(LibLLVM.get_first_basic_block(fn))
      until LibLLVM.is_a_alloca_inst(inst).null?
        inst = LibLLVM.get_next_instruction(inst)
      end
      LibLLVM.position_builder_before(builder, inst)
      type = LLVM::Type.function([] of LLVM::Type, ctx.void)
      builder.call type, entry_fun(mod, type)
    end
  end

  private def self.entry_fun(mod : LLVM::Module, type : LLVM::Type) : LLVM::Function
    mod.functions[ENTRY]? || begin
      entry = LibLLVM.add_function(mod, ENTRY, type)
      {"memory" => INACCESSIBLE_READ_WRITE, "nounwind" => 0_u64, "willreturn" => 0_u64}.each do |attribute, value|
        kind = LibLLVM.get_enum_attribute_kind_for_name(attribute, attribute.bytesize)
        LibLLVM.add_attribute_at_index(entry, LLVM::AttributeIndex::FunctionIndex, LibLLVM.create_enum_attribute(mod.context, kind, value))
      end
      LLVM::Function.new(entry)
    end
  end

  # Which nodes of the graph *calls* are on a cycle: Tarjan's strongly
  # connected components, kept on a stack of its own rather than the
  # compiler's, a component of one node only when the node calls itself.
  private def self.on_cycle(calls : Array(Array(Int32))) : Array(Bool)
    count = calls.size
    order = Array(Int32).new(count, -1)
    low = Array(Int32).new(count, 0)
    held = Array(Bool).new(count, false)
    cyclic = Array(Bool).new(count, false)
    stack = [] of Int32
    work = [] of {Int32, Int32}
    counter = 0
    count.times do |root|
      next if order[root] >= 0
      order[root] = low[root] = counter
      counter += 1
      stack << root
      held[root] = true
      work << {root, 0}
      until work.empty?
        node, at = work.last
        if at < calls[node].size
          work[-1] = {node, at + 1}
          callee = calls[node][at]
          if order[callee] < 0
            order[callee] = low[callee] = counter
            counter += 1
            stack << callee
            held[callee] = true
            work << {callee, 0}
          elsif held[callee]
            low[node] = Math.min(low[node], order[callee])
          end
          next
        end
        work.pop
        if low[node] == order[node]
          size = 0
          while true
            member = stack.pop
            held[member] = false
            size += 1
            cyclic[member] = true
            break if member == node
          end
          cyclic[node] = calls[node].includes?(node) if size == 1
        end
        if caller = work.last?
          low[caller[0]] = Math.min(low[caller[0]], low[node])
        end
      end
    end
    cyclic
  end

  # Whether a loop ID carries the property.
  private def self.marked?(loop_id : LibLLVM::ValueRef) : Bool
    return false if loop_id.null?
    count = LibLLVM.get_md_node_num_operands(loop_id)
    operands = Array(LibLLVM::ValueRef).new(count) { Pointer(Void).null.as(LibLLVM::ValueRef) }
    LibLLVM.get_md_node_operands(loop_id, operands.to_unsafe)
    operands.any? do |operand|
      next false if operand.null? || LibLLVM.is_a_md_node(operand).null?
      next false if LibLLVM.get_md_node_num_operands(operand) == 0
      inner = Pointer(LibLLVM::ValueRef).malloc(LibLLVM.get_md_node_num_operands(operand))
      LibLLVM.get_md_node_operands(operand, inner)
      text = LibLLVM.get_md_string(inner[0], out length)
      !text.null? && String.new(text, length) == MARK
    end
  end

  # The check at *first*: it and what follows it in *block* - a latch's
  # terminator, or what followed an entry's `ENTRY` call - move into a block
  # of its own, the successors' phis follow them there, and *block* ends in
  # the check instead.
  private def self.check(mod, builder, ctx, block, first, flag, linux, aarch64, anchor) : Nil
    fn = LibLLVM.get_basic_block_parent(block)
    resume = LibLLVM.append_basic_block_in_context(ctx, fn, "preempt_resume")
    slow = LibLLVM.append_basic_block_in_context(ctx, fn, "preempt")
    LibLLVM.move_basic_block_after(resume, block)
    LibLLVM.move_basic_block_after(slow, block)

    builder.position_at_end LLVM::BasicBlock.new(resume)
    inst = first
    until inst.null?
      following = LibLLVM.get_next_instruction(inst)
      LibLLVM.instruction_remove_from_parent(inst)
      LibLLVM.insert_into_builder(builder, inst)
      inst = following
    end
    terminator = LibLLVM.get_basic_block_terminator(resume)

    successors = [] of LibLLVM::BasicBlockRef
    LibLLVM.get_num_successors(terminator).times do |index|
      successor = LibLLVM.get_successor(terminator, index)
      next if successors.includes?(successor)
      successors << successor
      retarget_phis(builder, successor, block, resume)
    end

    builder.position_at_end LLVM::BasicBlock.new(block)
    word = load_word(mod, builder, ctx, flag, linux, aarch64, anchor)
    asked = builder.icmp LLVM::IntPredicate::NE, word, ctx.int64.const_int(0)
    builder.cond asked, LLVM::BasicBlock.new(slow), LLVM::BasicBlock.new(resume)

    builder.position_at_end LLVM::BasicBlock.new(slow)
    preempt_type = LLVM::Type.function([] of LLVM::Type, ctx.void)
    builder.call preempt_type, preempt_fun(mod, preempt_type)
    builder.br LLVM::BasicBlock.new(resume)
  end

  # Each phi of *block* that names *from* as a predecessor, remade naming
  # *to*: the C API reads a phi's blocks and cannot write them.
  private def self.retarget_phis(builder, block, from, to) : Nil
    inst = LibLLVM.get_first_instruction(block)
    until inst.null? || LibLLVM.is_a_phi_node(inst).null?
      following = LibLLVM.get_next_instruction(inst)
      count = LibLLVM.count_incoming(inst)
      if (0...count).any? { |index| LibLLVM.get_incoming_block(inst, index) == from }
        LibLLVM.position_builder_before(builder, inst)
        phi = LibLLVM.build_phi(builder, LibLLVM.type_of(inst), "")
        count.times do |index|
          value = LibLLVM.get_incoming_value(inst, index)
          incoming = LibLLVM.get_incoming_block(inst, index)
          incoming = to if incoming == from
          LibLLVM.add_incoming(phi, pointerof(value), pointerof(incoming), 1)
        end
        LibLLVM.replace_all_uses_with(inst, phi)
        LibLLVM.instruction_erase_from_parent(inst)
      end
      inst = following
    end
  end

  private def self.preempt_fun(mod, type) : LLVM::Function
    mod.functions["__iyi_preempt"]? || LLVM::Function.new(LibLLVM.add_function(mod, "__iyi_preempt", type))
  end

  # What every check in function *fn* starts from, made once in its entry
  # block, or on darwin arm64 at the end of *spot* (`Loops#outside`): on
  # Linux the word's offset from the thread pointer, a link-time
  # constant the same on every thread; on x86-64 Windows the word's
  # offset from `%gs`, a TEB slot the pool claims (`IyiWorkers::preempt_slot`,
  # the flag's global and `_slot`); on darwin arm64 a pair, the index of
  # this program's slot in the thread's pthread slots and the word's
  # offset in the block that slot points to; elsewhere the slot the
  # accessor writes the word's address into.
  #
  # darwin: the slot is dyld's pthread key for this image's thread-locals,
  # the 32 bits at 8 in the word's TLV descriptor (`_tlv_get_addr` reads
  # it there: a `long` before dyld's second thunk layout, the 32 bits
  # little-endian all the same). The offset sits after it in the
  # descriptor too, at 16 in the first layout and at 12 in the second, so
  # it is not read there: the accessor is called once, which also makes
  # this thread's block if it had none, and the offset is its answer less
  # the block this thread's slot holds. A worker has read the word before
  # it runs a task (`preempt_word`), so a task that resumes on another
  # worker finds a block in that worker's slot.
  #
  # That call was in the entry block once, and every call of a function
  # with a loop paid it, whether the loop ran or not: `String::Builder#<<`,
  # whose loops a short string never enters, at every append. On an M2
  # Pro (macOS 26.6, release, best of seven, eleven interleaved rounds,
  # load 3 to 18) a join of 1,000,000 strings took 1.37x to 1.43x what it
  # took with the library unchecked. It is made where the outermost loop
  # around the checks it serves is entered, so a loop that never runs
  # costs nothing and an inner loop's entries from its outer one make no
  # call: the join then took 1.08x to 1.18x over three such runs, and a
  # sort of 1,000,000 `Int64`s 1.08x to 1.14x against 1.10x to 1.12x
  # before. What is left is the check's own read; one that loaded a plain
  # global instead, a probe that preempts nothing, cost the sort 1.05x to
  # 1.07x and the join 1.07x to 1.12x.
  private def self.entry_value(mod, builder, ctx, fn, flag, linux, aarch64, spot) : LLVM::Value
    entry = LibLLVM.get_first_basic_block(fn)
    LibLLVM.position_builder_before(builder, LibLLVM.get_first_instruction(entry))
    int64 = ctx.int64
    if linux
      global_value = thread_local(mod, flag, int64, LLVM::ThreadLocalMode::LocalExec)
      text = aarch64 ? "movz $0, #:tprel_g1:${1:c}\n\tmovk $0, #:tprel_g0_nc:${1:c}" : "movq $$${1:P}@TPOFF, $0"
      return pure_asm(builder, ctx, int64, text, global_value)
    end
    windows = windows?(mod)
    unless ((windows && !aarch64) || (!windows && aarch64)) && !accessor_only?
      return builder.alloca(ctx.pointer)
    end
    if windows
      slot_name = "#{flag}_slot"
      slot_global = mod.globals[slot_name]? || LLVM::Value.new(LibLLVM.add_global(mod, int64, slot_name))
      return builder.load(int64, slot_global)
    end
    # The accessor's answer is a slot in the frame, in the entry block
    # where LLVM keeps a frame's slots; the rest goes at the end of *spot*.
    answer = builder.alloca(ctx.pointer)
    LibLLVM.position_builder_before(builder, LibLLVM.get_basic_block_terminator(spot)) if spot
    global_value = thread_local(mod, flag, int64, LLVM::ThreadLocalMode::GeneralDynamic)
    descriptor = pure_asm(builder, ctx, int64, "adrp $0, ${1:c}@TLVPPAGE\n\tldr $0, [$0, ${1:c}@TLVPPAGEOFF]", global_value)
    key_address = builder.int2ptr(builder.add(descriptor, int64.const_int(8)), ctx.pointer)
    slot = builder.zext(builder.load(ctx.int32, key_address), int64)
    accessor_type = LLVM::Type.function([ctx.pointer], ctx.void)
    builder.call accessor_type, accessor(mod, flag, accessor_type), [answer]
    word_address = builder.ptr2int(builder.load(ctx.pointer, answer), int64)
    offset = builder.sub(word_address, thread_block(builder, ctx, slot))
    pair_type = ctx.struct([int64, int64])
    pair = LibLLVM.build_insert_value(builder, pair_type.undef, slot, 0, "")
    LLVM::Value.new(LibLLVM.build_insert_value(builder, pair, offset, 1, ""))
  end

  # The word, volatile, through the thread pointer read here: x86-64's
  # `%fs` (address space 257) or on Windows `%gs` (256) at the offset,
  # aarch64 Linux's `tpidr_el0` plus it, darwin's block of this thread's
  # slot plus the pair's offset, or the accessor's answer.
  private def self.load_word(mod, builder, ctx, flag, linux, aarch64, anchor) : LLVM::Value
    int64 = ctx.int64
    if linux && aarch64
      address = builder.int2ptr(builder.add(thread_pointer(builder, ctx, "mrs $0, tpidr_el0"), anchor), ctx.pointer)
    elsif anchor.type.kind.integer?
      address = builder.int2ptr(anchor, ctx.pointer(linux ? 257 : 256))
    elsif anchor.type.kind.struct?
      block = thread_block(builder, ctx, builder.extract_value(anchor, 0))
      address = builder.int2ptr(builder.add(block, builder.extract_value(anchor, 1)), ctx.pointer)
    else
      accessor_type = LLVM::Type.function([ctx.pointer], ctx.void)
      builder.call accessor_type, accessor(mod, flag, accessor_type), [anchor]
      address = builder.load(ctx.pointer, anchor)
    end
    word = builder.load(int64, address)
    word.volatile = true
    word
  end

  # The block darwin's pthread slot *slot* holds on the thread as it is
  # here: `tpidrro_el0` is the thread's slots, its low three bits cleared
  # as `_tlv_get_addr` clears them.
  private def self.thread_block(builder, ctx, slot) : LLVM::Value
    int64 = ctx.int64
    table = builder.and(thread_pointer(builder, ctx, "mrs $0, tpidrro_el0"), int64.const_int(0xFFFFFFFFFFFFFFF8_u64))
    builder.load(int64, builder.gep(int64, builder.int2ptr(table, ctx.pointer), slot))
  end

  # An aarch64 thread register, read where it is: a volatile asm marked as
  # touching memory nothing else can name, so LLVM neither merges two
  # reads nor moves one out of a loop.
  private def self.thread_pointer(builder, ctx, text) : LLVM::Value
    read_type = LLVM::Type.function([] of LLVM::Type, ctx.int64)
    assembly = LLVM::Function.from_value(read_type.inline_asm(text, "=r", true, false, false, LLVM::InlineAsmDialect::ATT))
    pointer = builder.call read_type, assembly, [] of LLVM::Value
    {"memory" => INACCESSIBLE_READ_WRITE, "nounwind" => 0_u64, "willreturn" => 0_u64}.each do |attribute, value|
      kind = LibLLVM.get_enum_attribute_kind_for_name(attribute, attribute.bytesize)
      LibLLVM.add_call_site_attribute(pointer, LLVM::AttributeIndex::FunctionIndex, LibLLVM.create_enum_attribute(ctx, kind, value))
    end
    pointer
  end

  # A link-time constant of *global*'s, by asm with no effects of its own.
  private def self.pure_asm(builder, ctx, type, text, global_value) : LLVM::Value
    asm_type = LLVM::Type.function([global_value.type], type)
    assembly = LLVM::Function.from_value(asm_type.inline_asm(text, "=r,s", false, false, false, LLVM::InlineAsmDialect::ATT))
    value = builder.call asm_type, assembly, [global_value]
    {"memory", "nounwind", "willreturn"}.each do |attribute|
      kind = LibLLVM.get_enum_attribute_kind_for_name(attribute, attribute.bytesize)
      LibLLVM.add_call_site_attribute(value, LLVM::AttributeIndex::FunctionIndex, LibLLVM.create_enum_attribute(ctx, kind, 0_u64))
    end
    value
  end

  # The word's global, declared here as a thread-local where this module
  # only names it.
  private def self.thread_local(mod, flag, type, mode) : LLVM::Value
    mod.globals[flag]? || begin
      global = LibLLVM.add_global(mod, type, flag)
      LibLLVM.set_thread_local_mode(global, mode)
      LLVM::Value.new(global)
    end
  end

  private def self.accessor(mod, flag, type) : LLVM::Function
    mod.functions["*#{flag}"]? || LLVM::Function.new(LibLLVM.add_function(mod, "*#{flag}", type))
  end

  private def self.windows?(mod) : Bool
    String.new(LibLLVM.get_target(mod)).includes?("windows")
  end

  # Whether a check's anchor goes where its loops are entered rather than
  # in the entry block: darwin arm64's, the one that calls the accessor
  # (`entry_value`). Linux's is a constant and Windows' one load, and they
  # stay where they were measured.
  private def self.placed?(mod, linux, aarch64) : Bool
    !linux && aarch64 && !windows?(mod) && !accessor_only? && !anchor_at_entry?
  end

  # A function's natural loops, found from its dominator tree, for where
  # an anchor goes (`outside`).
  private class Loops
    @blocks = [] of LibLLVM::BasicBlockRef
    @order = {} of UInt64 => Int32
    @predecessors = [] of Array(Int32)
    @idom = [] of Int32
    # Each header's loop: the blocks of every back-edge to it.
    @bodies = {} of Int32 => Set(Int32)

    def initialize(fn : LibLLVM::ValueRef)
      number(fn)
      dominators
      @blocks.each_with_index do |block, index|
        each_successor(block) do |successor|
          header = @order[successor.address]
          next unless dominates?(header, index)
          body = @bodies[header] ||= Set{header}
          stack = [index]
          until stack.empty?
            at = stack.pop
            next unless body.add?(at)
            @predecessors[at].each { |predecessor| stack << predecessor }
          end
        end
      end
    end

    # The block whose end an anchor for a check in *block* goes at: the
    # one way into the outermost loop around *block*, or that loop
    # header's immediate dominator where there are more ways in. Nil for
    # a block in no loop, whose anchor goes in the entry block.
    def outside(block : LibLLVM::BasicBlockRef) : LibLLVM::BasicBlockRef?
      return nil unless at = @order[block.address]?
      header = -1
      size = 0
      @bodies.each do |head, body|
        next unless body.size > size && body.includes?(at)
        header = head
        size = body.size
      end
      return nil if header < 0
      body = @bodies[header]
      ways = @predecessors[header].reject { |predecessor| body.includes?(predecessor) }
      @blocks[ways.size == 1 ? ways[0] : @idom[header]]
    end

    private def each_successor(block, &) : Nil
      terminator = LibLLVM.get_basic_block_terminator(block)
      return if terminator.null?
      LibLLVM.get_num_successors(terminator).times { |at| yield LibLLVM.get_successor(terminator, at) }
    end

    # The blocks reached from the entry, numbered in reverse postorder,
    # and each one's predecessors among them.
    private def number(fn) : Nil
      entry = LibLLVM.get_first_basic_block(fn)
      postorder = [] of LibLLVM::BasicBlockRef
      seen = Set{entry.address}
      stack = [{entry, 0}]
      until stack.empty?
        block, at = stack.last
        terminator = LibLLVM.get_basic_block_terminator(block)
        if !terminator.null? && at < LibLLVM.get_num_successors(terminator)
          stack[-1] = {block, at + 1}
          successor = LibLLVM.get_successor(terminator, at)
          stack << {successor, 0} if seen.add?(successor.address)
        else
          postorder << stack.pop[0]
        end
      end
      @blocks = postorder.reverse!
      @blocks.each_with_index { |block, index| @order[block.address] = index }
      @predecessors = Array(Array(Int32)).new(@blocks.size) { [] of Int32 }
      @blocks.each_with_index do |block, index|
        each_successor(block) { |successor| @predecessors[@order[successor.address]] << index }
      end
    end

    # Cooper, Harvey and Kennedy's "A Simple, Fast Dominance Algorithm":
    # each block's immediate dominator by number, the entry its own.
    private def dominators : Nil
      @idom = Array(Int32).new(@blocks.size, -1)
      @idom[0] = 0
      changed = true
      while changed
        changed = false
        (1...@blocks.size).each do |index|
          found = -1
          @predecessors[index].each do |predecessor|
            next if @idom[predecessor] < 0
            found = found < 0 ? predecessor : meet(predecessor, found)
          end
          next if found == @idom[index]
          @idom[index] = found
          changed = true
        end
      end
    end

    private def meet(a : Int32, b : Int32) : Int32
      while a != b
        while a > b
          a = @idom[a]
        end
        while b > a
          b = @idom[b]
        end
      end
      a
    end

    # Whether block *a* dominates block *b*, by number: *b*'s chain of
    # immediate dominators, each numbered before the block below it,
    # reaches *a*.
    private def dominates?(a : Int32, b : Int32) : Bool
      while b > a
        b = @idom[b]
      end
      b == a
    end
  end
end
