# iyi: a `--release` program optimised on every core, and still optimised as
# one program.
#
# `--release` builds one LLVM module, because that is what lets LLVM inline
# across the whole program: a method of `Array(Int32)` into the loop that
# calls it, a type id folded into a constant where `is_a?` reads it. And one
# module is optimised on one core. `samples/iyi/cores.iyi` spent 17.2 s of a
# 19.4 s build there, 11.3 s of it optimising and 5.9 s generating code
# (`opt -O3` and `llc -O3` on its bitcode, LLVM 21, Linux).
#
# So the module is cut into partitions after codegen and before optimisation,
# and each partition is optimised and compiled on a core of its own — the
# shape of LLVM's ThinLTO, done in the compiler with nothing but the C API,
# because Windows' `LLVM-C.dll` exports that and no more (no `thinlto_*`, no
# C++). What keeps it one program is *import*:
#
# * every defined function has exactly one partition that **owns** it, and
#   every global variable is owned by partition 0;
# * a partition also gets its own copy of the small functions its code calls,
#   wherever they are owned, and of the constants it reads. LLVM inlines and
#   folds those as it would in one module, so the call into
#   `Array#unsafe_fetch` still disappears and a type id is still a constant.
#   A copy of a local function is local to the partition; a copy of an
#   external one, `__iyi_new` that every `new` calls, is
#   `available_externally`, there to be inlined and dropped after;
# * whatever is local to the module and still reached from a partition that
#   does not own it is **promoted**: given a name of its own and hidden
#   external linkage, so the partitions link to each other and to nothing
#   else.
#
# The cut depends on the module and on nothing about the machine: the same
# program gives the same partitions, the same objects and the same binary on
# two cores or twelve (`partition_count`). What the machine decides is only
# how many of them are compiled at once.
module Iyi::ReleasePartition
  # Instructions per partition, before optimisation. The count is a function
  # of the program only, so the output is too.
  PARTITION_SIZE = 20_000

  # More partitions than this cost more in what each one imports than they
  # save in balance.
  MAX_PARTITIONS = 32

  # A callee is imported when it has at most this many instructions before
  # optimisation, and a callee of an imported function at `IMPORT_DECAY`
  # times its caller's limit, as ThinLTO decays its own. A copy the inliner
  # turns down is optimised and compiled anyway, once in every partition
  # that has it. `samples/iyi/cores.iyi` on a shared 12-vCPU Linux VM: at
  # 300, 42.1 s of processor in 7.55 s and 3.23 MB of text; at 100, 28.1 s
  # in 5.76 s and 2.28 MB; at 50, 21.4 s in 5.25 s and 1.89 MB; the one
  # module, 19.0 s in 19.1 s and 1.90 MB. At 50 the JSON benchmark ran
  # 1.065x its one-module time on macOS 26.6, Apple M2 Pro, 10 cores (the
  # user's machine), best of 15 interleaved, against 1.028x at 100.
  IMPORT_LIMIT = 100
  IMPORT_DECAY = 0.7

  # Appended to a promoted name. Promotion happens once, before the module
  # is written for the partitions, so every partition reads the same name.
  PROMOTED = ".iyi.part"

  # What every partition is built from: who owns each function and what each
  # partition imports, by position in the module, which bitcode keeps.
  class Plan
    getter count : Int32
    # Per function, in module order: its owning partition, or -1 for a
    # declaration.
    getter owner : Array(Int32)
    # Per partition: the positions of the functions it gets a copy of.
    getter imports : Array(Array(Int32))
    # Per function: whether a copy of it is `available_externally`, there
    # only to be inlined, because the function is external and its owner's
    # definition answers every call the copy does not take (`copyable?`).
    getter external : Array(Bool)

    def initialize(@count, @owner, @imports, @external)
    end
  end

  # The partitions for *mod*, or nil when it is too small to be worth more
  # than one or *count* says one. Promotes, in *mod*, what the partitions
  # share; *mod* is written out after this and each partition is read back
  # from that. *named* is what something will look up by name after
  # optimisation (`PreemptChecks.named`), which keeps its name.
  # *import_limit* is `IMPORT_LIMIT` unless a build says otherwise.
  def self.plan(mod : LLVM::Module, count : Int32? = nil, named : Array(String) = [] of String,
                import_limit : Int32 = IMPORT_LIMIT) : Plan?
    return nil if count == 1
    functions = [] of LibLLVM::ValueRef
    position = {} of UInt64 => Int32
    fn = LibLLVM.get_first_function(mod)
    until fn.null?
      position[fn.address] = functions.size
      functions << fn
      fn = LibLLVM.get_next_function(fn)
    end

    sizes = Array(Int32).new(functions.size, 0)
    callees = Array(Array(Int32)).new(functions.size) { [] of Int32 }
    copyable = Array(Bool).new(functions.size, false)
    external = Array(Bool).new(functions.size, false)
    total = 0_i64
    never_inlined = {"noinline", "naked"}.map { |name| LibLLVM.get_enum_attribute_kind_for_name(name, name.bytesize) }
    functions.each_with_index do |function, index|
      next if declaration?(function)
      size, labels = scan(function, position, callees[index])
      sizes[index] = size
      total += size
      external[index] = LibLLVM.get_linkage(function).external?
      copyable[index] = !labels && inlinable?(function, never_inlined) &&
                        (external[index] || (local?(function) && only_called?(function)))
    end

    count ||= partition_count(total)
    return nil if count < 2

    owner = assign(functions, sizes, total, count)
    imports = Array(Array(Int32)).new(count) { |partition| import_list(partition, owner, sizes, callees, copyable, import_limit) }

    importers = Array(Array(Int32)?).new(functions.size, nil)
    imports.each_with_index do |list, partition|
      list.each { |index| (importers[index] ||= [] of Int32) << partition }
    end

    promote(mod, position, owner, importers, named)
    Plan.new(count, owner, imports, external)
  end

  def self.partition_count(instructions : Int64) : Int32
    size = PARTITION_SIZE.to_i64
    ((instructions + size - 1) // size).clamp(1_i64, MAX_PARTITIONS.to_i64).to_i32
  end

  # Instructions in *function*, and whether any inline assembly in it may
  # define a symbol (`defines_symbol?`); the defined functions it calls
  # directly go into *callees*, once each.
  private def self.scan(function, position, callees) : {Int32, Bool}
    size = 0
    labels = false
    block = LibLLVM.get_first_basic_block(function)
    until block.null?
      inst = LibLLVM.get_first_instruction(block)
      until inst.null?
        size += 1
        if call?(inst)
          callee = LibLLVM.get_called_value(inst)
          case LibLLVM.get_value_kind(callee)
          when .function?
            if (index = position[callee.address]?) && !declaration?(callee) && !callees.includes?(index)
              callees << index
            end
          when .inline_asm?
            labels ||= defines_symbol?(callee)
          end
        end
        inst = LibLLVM.get_next_instruction(inst)
      end
      block = LibLLVM.get_next_basic_block(block)
    end
    {size, labels}
  end

  # Whether the inline assembly *value* may define a symbol, which two
  # copies of it would define twice: a statement that starts with a name
  # and a colon (`1:`, `loop:`), or with a directive (`.set`, `.globl`).
  # Every one in the prelude is neither: a system call, `pause`, and on
  # Linux each thread-local read (`movq $$sym@TPOFF, $0`), which put every
  # function that read one, `IyiHeap.cache` among them, out of reach of a
  # copy. LLVM before 18 cannot say what the text is, so there any inline
  # assembly may.
  private def self.defines_symbol?(value) : Bool
    {% if LibLLVM::IS_LT_180 %}
      true
    {% else %}
      text = String.new(LibLLVM.get_inline_asm_asm_string(value, out length), length)
      text.tr(";", "\n").each_line.any? do |statement|
        statement = statement.lstrip
        next true if statement.starts_with?('.')
        colon = statement.index(':')
        colon && colon > 0 && statement[0, colon].each_char.all? { |char| char.alphanumeric? || char.in?('_', '$') }
      end
    {% end %}
  end

  # Whether LLVM may inline *function* at all: a copy of one it may not is
  # one more body to optimise and compile, and inlined nowhere.
  private def self.inlinable?(function, never_inlined) : Bool
    never_inlined.none? do |kind|
      !LibLLVM.get_enum_attribute_at_index(function, LLVM::AttributeIndex::FunctionIndex, kind).null?
    end
  end

  # Whether a copy of *function* can stand in for it as a local of the
  # partition that has it: nothing but a direct call names it, so no
  # partition can tell its copy from the original by address.
  private def self.only_called?(function) : Bool
    use = LibLLVM.get_first_use(function)
    until use.null?
      return false unless direct_call?(LibLLVM.get_user(use), function)
      use = LibLLVM.get_next_use(use)
    end
    true
  end

  private def self.call?(value) : Bool
    !LibLLVM.is_a_call_inst(value).null? || !LibLLVM.is_a_invoke_inst(value).null?
  end

  # *user* calls *function* and does not also pass it along.
  private def self.direct_call?(user, function) : Bool
    return false unless call?(user)
    return false unless LibLLVM.get_called_value(user) == function
    LibLLVM.get_num_arg_operands(user).times do |index|
      return false if LibLLVM.get_operand(user, index) == function
    end
    true
  end

  private def self.local?(value) : Bool
    linkage = LibLLVM.get_linkage(value)
    linkage.internal? || linkage.private?
  end

  # Contiguous runs of the module's functions, of about equal size. Codegen
  # emits a function where it is first called, so a run is mostly a caller
  # and what it calls, which keeps both the imports and the promotions few.
  private def self.assign(functions, sizes, total, count) : Array(Int32)
    owner = Array(Int32).new(functions.size, -1)
    before = 0_i64
    functions.each_index do |index|
      size = sizes[index]
      next if size == 0
      owner[index] = Math.min(count - 1, ((before + size // 2) * count // total).to_i32)
      before += size
    end
    owner
  end

  # What *partition* gets a copy of: the functions of at most
  # *import_limit* instructions its own code calls, then theirs at a decayed
  # limit, keeping for each function the largest limit it was reached at.
  private def self.import_list(partition, owner, sizes, callees, copyable, import_limit) : Array(Int32)
    best = {} of Int32 => Float64
    work = [] of {Int32, Float64}
    consider = ->(index : Int32, limit : Float64) do
      return if owner[index] == partition || owner[index] < 0 || !copyable[index]
      return if sizes[index] > limit
      return if (seen = best[index]?) && seen >= limit
      best[index] = limit
      work << {index, limit}
    end
    owner.each_with_index do |owning, index|
      next unless owning == partition
      callees[index].each { |callee| consider.call(callee, import_limit.to_f) }
    end
    until work.empty?
      index, limit = work.pop
      callees[index].each { |callee| consider.call(callee, limit * IMPORT_DECAY) }
    end
    best.keys.sort!
  end

  # Every local function or global that a partition other than its owner
  # still reaches gets a name of its own and hidden external linkage: a
  # call a partition has its own copy for does not count. A global's owner
  # is partition 0. What a global's initialiser refers to is promoted
  # whatever reads it, since a constant travels to every partition that
  # reads it and takes its references along.
  #
  # A *named* one is made visible under the name it has, whoever reaches it
  # now: what names it after optimisation may be in any partition. On
  # x86-64 Linux the preemption word was internal, the checks went into
  # partition 1 by name and linked to nothing: `undefined reference to
  # 'IyiWorkers::preempt'`.
  private def self.promote(mod, position, owner, importers, named) : Nil
    anonymous = 0
    each_definition(mod) do |value, is_function|
      next unless local?(value)
      name = String.new(LibLLVM.get_value_name2(value, out length), length)
      unless named.includes?(name)
        index = is_function ? position[value.address] : nil
        home = index ? owner[index] : 0
        next unless reached_elsewhere?(value, index, home, position, owner, importers)
        name = "__iyi_part_anonymous.#{anonymous += 1}" if name.empty?
        name += PROMOTED
        LibLLVM.set_value_name2(value, name, name.bytesize)
      end
      LibLLVM.set_linkage(value, LLVM::Linkage::External)
      LibLLVM.set_visibility(value, LLVM::Visibility::Hidden)
    end
  end

  # `LibLLVM::Bool` is a C `int`, and every `int` is truthy.
  private def self.declaration?(value : LibLLVM::ValueRef) : Bool
    LibLLVM.is_declaration(value) != 0
  end

  private def self.each_definition(mod, &) : Nil
    fn = LibLLVM.get_first_function(mod)
    until fn.null?
      yield fn, true unless declaration?(fn)
      fn = LibLLVM.get_next_function(fn)
    end
    global = LibLLVM.get_first_global(mod)
    until global.null?
      yield global, false unless declaration?(global)
      global = LibLLVM.get_next_global(global)
    end
  end

  # Whether *value*, owned by partition *home*, is named by code that ends up
  # in another partition. *index* is its position when it is a function,
  # for the calls a partition has a copy of it for.
  private def self.reached_elsewhere?(value, index, home, position, owner, importers) : Bool
    use = LibLLVM.get_first_use(value)
    until use.null?
      user = LibLLVM.get_user(use)
      case LibLLVM.get_value_kind(user)
      when .instruction?
        function = LibLLVM.get_basic_block_parent(LibLLVM.get_instruction_parent(user))
        copied = index && direct_call?(user, value) ? importers[index] : nil
        return true if in_elsewhere?(function, home, position, owner, importers, copied)
      when .function?
        # A personality, a prefix: the function that names it.
        return true if in_elsewhere?(user, home, position, owner, importers, nil)
      when .constant_expr?, .constant_array?, .constant_struct?, .constant_vector?, .block_address?
        return true if reached_elsewhere?(user, nil, home, position, owner, importers)
      else
        # A global's initialiser, or anything not foreseen here.
        return true
      end
      use = LibLLVM.get_next_use(use)
    end
    false
  end

  # Whether *function* has a body in a partition other than *home* - its
  # owner's, or one with a copy - that is not one of *copied*, the
  # partitions with a copy of what is being asked about.
  private def self.in_elsewhere?(function, home, position, owner, importers, copied) : Bool
    return true unless index = position[function.address]?
    owning = owner[index]
    return true if owning != home && !copied.try(&.includes?(owning))
    importers[index].try &.each do |partition|
      return true if partition != home && !copied.try(&.includes?(partition))
    end
    false
  end

  # Partition *partition* of the module in *buffer*, read into a context of
  # its own so that partitions can be built on as many threads at once.
  # Returns the module ready for the optimiser.
  #
  # Read lazily, and linked into an empty module: a body is read only when
  # the partition keeps it. Read whole, every partition held the whole
  # program for as long as it took to cut it down, which is the program
  # times the threads at once — on `samples/iyi/cores.iyi`, 1.4 GB of
  # resident memory against 0.77 GB for the one module, and 0.16 s of
  # reading per partition against 0.04 s.
  def self.materialize(buffer : LLVM::MemoryBuffer, plan : Plan, partition : Int32,
                       target_machine : LLVM::TargetMachine) : LLVM::Module
    context = LLVM::Context.new(dispose_on_finalize: false)
    # A view of the shared bytes, which the lazy module owns and frees
    # when it is linked away; the bytes stay the caller's.
    bytes = buffer.to_slice
    view = LibLLVM.create_memory_buffer_with_memory_range(bytes.to_unsafe, LibC::SizeT.new(bytes.size), "partition", 0)
    if LibLLVM.get_bitcode_module_in_context2(context, view, out lazy) != 0
      raise "BUG: partition #{partition} could not read the module's bitcode"
    end

    imported = Array(Bool).new(plan.owner.size, false)
    plan.imports[partition].each { |index| imported[index] = true }

    # A body this partition neither owns nor copies goes, through LLVM's
    # own pass for it and before anything reads it. A copy of a local is
    # local here: every call to it in this partition is to the copy, and
    # nothing else names it (`only_called?`). A copy of an external
    # function stays whole through that pass, which would take its body,
    # and is `available_externally` once the partition is linked.
    inline_only = [] of String
    index = 0
    fn = LibLLVM.get_first_function(lazy)
    until fn.null?
      owner = plan.owner[index]? || raise "BUG: partition #{partition} read more functions than its plan has"
      if owner >= 0 && owner != partition
        if imported[index] && plan.external[index]
          inline_only << String.new(LibLLVM.get_value_name2(fn, out length), length)
        elsif imported[index]
          LibLLVM.set_linkage(fn, LLVM::Linkage::Internal)
          LibLLVM.set_visibility(fn, LLVM::Visibility::Default)
        else
          LibLLVM.set_linkage(fn, LLVM::Linkage::AvailableExternally)
        end
      end
      index += 1
      fn = LibLLVM.get_next_function(fn)
    end
    # The plan is by position, and reading the module back must not have
    # moved one.
    raise "BUG: partition #{partition} read #{index} functions, its plan has #{plan.owner.size}" unless index == plan.owner.size

    eliminate_available_externally(lazy, context, target_machine)
    LibLLVM.set_module_inline_asm2(lazy, "", 0) unless partition == 0

    # The linker reads what it links and nothing else: every external
    # definition, and a local one only where something it linked refers to
    # it. That is the partition, and it is the import LLVM's own ThinLTO
    # does with the same linker.
    mod = context.new_module("partition")
    if LibLLVM.link_modules2(mod, lazy) != 0
      raise "BUG: partition #{partition} could not be linked"
    end
    globals_to_partition_zero(mod, context, target_machine) unless partition == 0
    inline_only.each do |name|
      LibLLVM.set_linkage(mod.functions[name], LLVM::Linkage::AvailableExternally)
    end
    mod
  end

  # Every global is partition 0's: elsewhere a variable is a declaration
  # and a constant is `available_externally`, kept for what it folds to.
  #
  # After the link and not before it. The module is read lazily, and a
  # body not yet read names the constants it uses by their place in the
  # reader's table; dropping a global's initialiser there destroyed a
  # constant one of those bodies then read back as the argument of some
  # other function: "Referring to an argument in another function", on
  # partition 1 of `samples/iyi/cores.iyi`.
  private def self.globals_to_partition_zero(mod, context, target_machine) : Nil
    constants = [] of LibLLVM::ValueRef
    doomed = [] of LibLLVM::ValueRef
    global = LibLLVM.get_first_global(mod)
    until global.null?
      unless declaration?(global)
        linkage = LibLLVM.get_linkage(global)
        if linkage.appending?
          # `llvm.global_ctors` and its kind: once, in partition 0.
          doomed << global
        elsif LibLLVM.is_global_constant(global) != 0 && !(linkage.internal? || linkage.private?)
          constants << global
        else
          LibLLVM.set_linkage(global, LLVM::Linkage::AvailableExternally)
        end
      end
      global = LibLLVM.get_next_global(global)
    end
    doomed.each { |global| LibLLVM.delete_global(global) }

    eliminate_available_externally(mod.to_unsafe, context, target_machine)
    constants.each { |constant| LibLLVM.set_linkage(constant, LLVM::Linkage::AvailableExternally) }
  end

  # Only reached with LLVM 13 or later (`Compiler#codegen`).
  private def self.eliminate_available_externally(mod : LibLLVM::ModuleRef, context, target_machine) : Nil
    {% unless LibLLVM::IS_LT_130 %}
      LLVM::PassBuilderOptions.new do |options|
        LLVM.run_passes(LLVM::Module.new(mod, context), "elim-avail-extern", target_machine, options)
      end
    {% end %}
  end
end
