# iyi: wasm32's collector finds its roots by reading linear memory - the
# shadow stack from the stack pointer to `__heap_base`, and the data
# segment. A WebAssembly local is not in linear memory, and nothing can
# read one: an object held only by a value the backend kept in a local was
# freed by a collection that came while it was held. Optimised builds keep
# nearly every value in locals; plain builds too, for a temporary such as
# the first argument of `pair(Box.new(40), Box.new(2))` while the second
# is made (GC_DESIGN.md, Stage 10).
#
# So before code generation every value that may still be needed after a
# call is also written to a stack slot of its own, right where it is made:
# an alloca, which the backend places in linear memory, and a volatile
# store, which nothing may remove. SSA values never change, so one store
# where the value is defined keeps it reachable for as long as the frame
# lives; a stale slot holds an object one frame longer, which a
# conservative scan of the stack does anyway.
#
# Which values: the function's parameters and every instruction whose type
# can carry an address - a pointer; an integer of 32 bits or more, as the
# allocator answers an address and a union made in place holds its payload
# (bench/wasm32_exercise.sh fails without either); a struct or an array -
# unless it is an alloca, whose memory is already scanned. No program found
# yet keeps an aggregate across a call (wasm32 returns one through memory),
# and nothing that runs after this pass deletes a store today: aggregates
# and `volatile` are kept as guarantees, not because a case needed them. Which of those: a value used in
# another block or by a phi, or used later in its own block with a call
# between - any call but an LLVM intrinsic may allocate, and allocating may
# collect. A use only as the call's own argument is the callee's to keep:
# it arrives there as a parameter, which this pass spills in the callee.
module Iyi::WasmRoots
  def self.run(mod : LLVM::Module) : Nil
    builder = LibLLVM.create_builder_in_context(LibLLVM.get_module_context(mod.to_unsafe))
    fn = LibLLVM.get_first_function(mod.to_unsafe)
    until fn.null?
      spill(fn, builder) unless LibLLVM.get_first_basic_block(fn).null?
      fn = LibLLVM.get_next_function(fn)
    end
    LibLLVM.dispose_builder(builder)
  end

  private def self.spill(fn : LibLLVM::ValueRef, builder : LibLLVM::BuilderRef) : Nil
    # Every instruction's place, and every block's calls by position.
    place = {} of LibLLVM::ValueRef => {Int32, Int32}
    calls = [] of Array(Int32)
    blocks = [] of LibLLVM::BasicBlockRef
    any_call = false
    block = LibLLVM.get_first_basic_block(fn)
    until block.null?
      index = blocks.size
      blocks << block
      positions = [] of Int32
      at = 0
      inst = LibLLVM.get_first_instruction(block)
      until inst.null?
        place[inst] = {index, at}
        if collecting_call?(inst)
          positions << at
          any_call = true
        end
        at += 1
        inst = LibLLVM.get_next_instruction(inst)
      end
      calls << positions
      block = LibLLVM.get_next_basic_block(block)
    end
    return unless any_call

    predecessors = Hash(LibLLVM::BasicBlockRef, Int32).new(0)
    blocks.each do |b|
      terminator = LibLLVM.get_basic_block_terminator(b)
      next if terminator.null?
      LibLLVM.get_num_successors(terminator).times do |i|
        predecessors[LibLLVM.get_successor(terminator, i)] += 1
      end
    end

    spilled = [] of LibLLVM::ValueRef
    LibLLVM.get_count_params(fn).times do |i|
      param = LibLLVM.get_param(fn, i)
      spilled << param if carries_address?(param) && live_across_call?(param, 0, -1, place, calls)
    end
    blocks.each_with_index do |b, index|
      inst = LibLLVM.get_first_instruction(b)
      until inst.null?
        if carries_address?(inst) && LibLLVM.is_a_alloca_inst(inst).null? && live_across_call?(inst, index, place[inst][1], place, calls)
          # An invoke (the other library's code raises; iyi's does not)
          # ends its block: its result is stored where its normal edge
          # lands, when that block has no other way in. With another, the
          # result dominates no block, so only that block's phis read it,
          # and no call comes between: the phis are this pass's to keep.
          spilled << inst if LibLLVM.is_a_invoke_inst(inst).null? || predecessors[LibLLVM.get_normal_dest(inst)]? == 1
        end
        inst = LibLLVM.get_next_instruction(inst)
      end
    end
    return if spilled.empty?

    # The slots go first in the entry block; a parameter is stored after
    # the allocas that were there, before anything else runs.
    entry = blocks[0]
    first = LibLLVM.get_first_instruction(entry)
    after_allocas = first
    until after_allocas.null? || LibLLVM.is_a_alloca_inst(after_allocas).null?
      after_allocas = LibLLVM.get_next_instruction(after_allocas)
    end
    spilled.each do |value|
      LibLLVM.position_builder_before(builder, first)
      slot = LibLLVM.build_alloca(builder, LibLLVM.type_of(value), "")
      LibLLVM.position_builder_before(builder, store_point(value, after_allocas))
      LibLLVM.set_volatile(LibLLVM.build_store(builder, value, slot), true)
    end
  end

  # Where *value*'s store goes: after the entry's allocas for a parameter,
  # after the block's phis (and landing pad) for a phi, at the start of the
  # normal edge's block for an invoke, right after the instruction for any
  # other.
  private def self.store_point(value : LibLLVM::ValueRef, after_allocas : LibLLVM::ValueRef) : LibLLVM::ValueRef
    return after_allocas unless LibLLVM.is_a_argument(value).null?
    if !LibLLVM.is_a_invoke_inst(value).null?
      block = LibLLVM.get_normal_dest(value)
    elsif LibLLVM.is_a_phi_node(value).null?
      return LibLLVM.get_next_instruction(value)
    else
      block = LibLLVM.get_instruction_parent(value)
    end
    inst = LibLLVM.get_first_instruction(block)
    while !LibLLVM.is_a_phi_node(inst).null? || !LibLLVM.is_a_landing_pad_inst(inst).null?
      inst = LibLLVM.get_next_instruction(inst)
    end
    inst
  end

  private def self.live_across_call?(value : LibLLVM::ValueRef, block : Int32, at : Int32,
                                     place : Hash(LibLLVM::ValueRef, {Int32, Int32}), calls : Array(Array(Int32))) : Bool
    use = LibLLVM.get_first_use(value)
    until use.null?
      user = LibLLVM.get_user(use)
      where = place[user]?
      # A user that is no instruction of this function, a phi, or one in
      # another block: kept, without asking further.
      return true if where.nil? || !LibLLVM.is_a_phi_node(user).null? || where[0] != block
      return true if calls[block].any? { |c| c > at && c < where[1] }
      use = LibLLVM.get_next_use(use)
    end
    false
  end

  private def self.collecting_call?(inst : LibLLVM::ValueRef) : Bool
    return false if LibLLVM.is_a_call_inst(inst).null? && LibLLVM.is_a_invoke_inst(inst).null?
    LibLLVM.is_a_intrinsic_inst(inst).null?
  end

  private def self.carries_address?(value : LibLLVM::ValueRef) : Bool
    type = LibLLVM.type_of(value)
    case LibLLVM.get_type_kind(type)
    when .pointer?, .struct?, .array?
      true
    when .integer?
      LibLLVM.get_int_type_width(type) >= 32
    else
      false
    end
  end
end
