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
# held in a register; on aarch64 Linux `tpidr_el0` plus the offset. Mach-O
# and COFF have no local-exec, and read it through the accessor every other
# thread-local takes there (`CodeGenVisitor#get_thread_local`).
module Iyi::PreemptChecks
  MARK = "iyi.preempt"

  # *flag* is the preemption word's global (`IyiWorkers::preempt`), and the
  # thread-local accessor is `*` and that name.
  def self.run(mod : LLVM::Module, flag : String, linux : Bool, aarch64 : Bool) : Nil
    ctx = mod.context
    kind = LibLLVM.get_md_kind_id_in_context(ctx, "llvm.loop", 9)
    builder = LLVM::Builder.new(LibLLVM.create_builder_in_context(ctx))
    fn = LibLLVM.get_first_function(mod)
    until fn.null?
      latches = [] of LibLLVM::BasicBlockRef
      block = LibLLVM.get_first_basic_block(fn)
      until block.null?
        terminator = LibLLVM.get_basic_block_terminator(block)
        latches << block if !terminator.null? && marked?(LibLLVM.get_metadata(terminator, kind))
        block = LibLLVM.get_next_basic_block(block)
      end
      unless latches.empty?
        anchor = entry_value(mod, builder, ctx, fn, flag, linux, aarch64)
        latches.each { |latch| check(mod, builder, ctx, latch, flag, linux, aarch64, anchor) }
      end
      fn = LibLLVM.get_next_function(fn)
    end
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

  # The latch's terminator moves into a block of its own, the successors'
  # phis follow it there, and the latch ends in the check instead.
  private def self.check(mod, builder, ctx, latch, flag, linux, aarch64, anchor) : Nil
    terminator = LibLLVM.get_basic_block_terminator(latch)
    fn = LibLLVM.get_basic_block_parent(latch)
    resume = LibLLVM.append_basic_block_in_context(ctx, fn, "preempt_resume")
    slow = LibLLVM.append_basic_block_in_context(ctx, fn, "preempt")
    LibLLVM.move_basic_block_after(resume, latch)
    LibLLVM.move_basic_block_after(slow, latch)

    LibLLVM.instruction_remove_from_parent(terminator)
    builder.position_at_end LLVM::BasicBlock.new(resume)
    LibLLVM.insert_into_builder(builder, terminator)

    successors = [] of LibLLVM::BasicBlockRef
    LibLLVM.get_num_successors(terminator).times do |index|
      successor = LibLLVM.get_successor(terminator, index)
      next if successors.includes?(successor)
      successors << successor
      retarget_phis(builder, successor, latch, resume)
    end

    builder.position_at_end LLVM::BasicBlock.new(latch)
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
  # block: on Linux the word's offset from the thread pointer, a link-time
  # constant the same on every thread; elsewhere the slot the accessor
  # writes the word's address into.
  private def self.entry_value(mod, builder, ctx, fn, flag, linux, aarch64) : LLVM::Value
    entry = LibLLVM.get_first_basic_block(fn)
    LibLLVM.position_builder_before(builder, LibLLVM.get_first_instruction(entry))
    return builder.alloca(ctx.pointer) unless linux
    int64 = ctx.int64
    global_value = mod.globals[flag]? || begin
      global = LibLLVM.add_global(mod, int64, flag)
      LibLLVM.set_thread_local_mode(global, LLVM::ThreadLocalMode::LocalExec)
      LLVM::Value.new(global)
    end
    text = aarch64 ? "movz $0, #:tprel_g1:${1:c}\n\tmovk $0, #:tprel_g0_nc:${1:c}" : "movq $$${1:P}@TPOFF, $0"
    asm_type = LLVM::Type.function([global_value.type], int64)
    assembly = LLVM::Function.from_value(asm_type.inline_asm(text, "=r,s", false, false, false, LLVM::InlineAsmDialect::ATT))
    offset = builder.call asm_type, assembly, [global_value]
    {"memory", "nounwind", "willreturn"}.each do |attribute|
      kind = LibLLVM.get_enum_attribute_kind_for_name(attribute, attribute.bytesize)
      LibLLVM.add_call_site_attribute(offset, LLVM::AttributeIndex::FunctionIndex, LibLLVM.create_enum_attribute(ctx, kind, 0_u64))
    end
    offset
  end

  # The word, volatile, through the thread pointer read here: x86-64's
  # `%fs` segment (address space 257) at the offset, aarch64's
  # `tpidr_el0` plus it, or the accessor's answer.
  private def self.load_word(mod, builder, ctx, flag, linux, aarch64, anchor) : LLVM::Value
    int64 = ctx.int64
    if linux && aarch64
      register_type = LLVM::Type.function([LLVM::Type.new(LibLLVM.metadata_type_in_context(ctx))], int64)
      register = mod.functions["llvm.read_register.i64"]? || LLVM::Function.new(LibLLVM.add_function(mod, "llvm.read_register.i64", register_type))
      name = LibLLVM.md_string_in_context2(ctx, "tpidr_el0", 9)
      node = LibLLVM.md_node_in_context2(ctx, pointerof(name), 1)
      pointer = builder.call register_type, register, [LLVM::Value.new(LibLLVM.metadata_as_value(ctx, node.as(LibLLVM::MetadataRef)))]
      address = builder.int2ptr(builder.add(pointer, anchor), ctx.pointer)
    elsif linux
      address = builder.int2ptr(anchor, ctx.pointer(257))
    else
      accessor_type = LLVM::Type.function([ctx.pointer], ctx.void)
      accessor = mod.functions["*#{flag}"]? || LLVM::Function.new(LibLLVM.add_function(mod, "*#{flag}", accessor_type))
      builder.call accessor_type, accessor, [anchor]
      address = builder.load(ctx.pointer, anchor)
    end
    word = builder.load(int64, address)
    word.volatile = true
    word
  end
end
