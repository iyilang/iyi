require "./codegen"

class Iyi::CodeGenVisitor
  def type_id(value, type)
    type_id_impl(value, type.remove_indirection)
  end

  def type_id(type)
    type_id_impl(type.remove_indirection)
  end

  private def type_id_impl(value, type : NilableType)
    builder.select null_pointer?(value), type_id(@program.nil), type_id(type.not_nil_type)
  end

  private def type_id_impl(value, type : ReferenceUnionType)
    object_type_id(value)
  end

  private def type_id_impl(value, type : VirtualType)
    object_type_id(value)
  end

  # iyi: an object's dynamic type id. Under iyi's layout it is the high
  # half of the header word under the object, a u32 at `P-4` on the
  # little-endian targets this reaches (GC_DESIGN.md Stage 5,
  # `object_header.cr`), in every allocator mode, and the object's own
  # words are its fields and nothing else; under Crystal's it is the
  # `i32` at the object's front.
  def object_type_id(value)
    if @program.iyi_object_layout?
      load(llvm_context.int32, gep(llvm_context.int8, value, -4, "type_id"))
    else
      load(llvm_context.int32, value)
    end
  end

  private def type_id_impl(value, type : NilableReferenceUnionType)
    nil_block, not_nil_block, exit_block = new_blocks "nil", "not_nil", "exit"
    phi_table = LLVM::PhiTable.new

    cond null_pointer?(value), nil_block, not_nil_block

    position_at_end nil_block
    phi_table.add insert_block, type_id(@program.nil)
    br exit_block

    position_at_end not_nil_block
    phi_table.add insert_block, object_type_id(value)
    br exit_block

    position_at_end exit_block
    phi llvm_context.int32, phi_table
  end

  private def type_id_impl(value, type : NilableProcType)
    fun_ptr = extract_value value, 0
    builder.select null_pointer?(fun_ptr), type_id(@program.nil), type_id(type.proc_type)
  end

  private def type_id_impl(value, type : VirtualMetaclassType)
    value
  end

  private def type_id_impl(value, type : Program)
    type_id(type)
  end

  private def type_id_impl(value, type : FileModule)
    type_id(type)
  end

  private def type_id_impl(value, type : AliasType)
    type_id value, type.aliased_type
  end

  private def type_id_impl(value, type)
    type_id(type)
  end

  # iyi: defines a type-id global for every type in the program (SPEC.md IV.1g).
  #
  # An artifact's object code refers to type ids by name, and this build has no
  # way to see which names an object file needs. Emitted on demand, they exist
  # only where *this* program happened to want one — which is why linking
  # against `String#+` from a module failed on `String:type_id` while the same
  # program built from source linked fine. An `i32` per type is not a cost worth
  # a cleverer answer.
  def iyi_define_all_type_ids : Nil
    # Numbered first, because the loop below defines what is numbered and an
    # enum is numbered by nothing else. Ids come from walking `Object`'s
    # subclasses, and that walk reaches a class and not an enum — an enum takes
    # its id from the first code that asks for one, and a consumer whose own
    # code never mentions `Regex::MatchOptions` never asks. The artifact says
    # which ones its object code refers to; this is where they are given a
    # number to define (SPEC.md IV.1g).
    @program.iyi_artifact_numbered_types.each do |type|
      next if type.is_a?(VirtualType) || type.is_a?(VirtualMetaclassType)
      @program.llvm_id.type_id(type)

      # And its metaclass, which is a second id and not always derived from the
      # first. `Backtracer::Backtrace::Parser:Module` *is* the metaclass of a
      # module — that suffix is how one prints — and the object code refers to
      # its id while the walk that numbers metaclasses only reaches classes.
      # Carrying the instance and stopping there defined
      # `…::Parser:type_id` for code that wanted `…::Parser:Module:type_id`.
      metaclass = type.metaclass
      @program.llvm_id.type_id(metaclass) unless metaclass.is_a?(VirtualMetaclassType)
    end

    @program.llvm_id.each_type do |type|
      next if type.is_a?(VirtualType) || type.is_a?(VirtualMetaclassType)

      name = "#{type.llvm_name}:type_id"
      next if @main_mod.globals[name]?

      global = @main_mod.globals.add(@main_llvm_context.int32, name)
      global.linkage = LLVM::Linkage::Internal if @single_module
      global.initializer = @main_llvm_context.int32.const_int(@program.llvm_id.type_id(type))
      global.global_constant = true
    end

    # iyi: a witness the producing build typed against and this one does not
    # have (`Program#iyi_artifact_phantom_types`). Ids count up from 0, so -1
    # is one no value carries, and a dispatch arm that tests for it is never
    # taken - which is what it was in the build that compiled it.
    @program.iyi_artifact_phantom_types.each do |witness|
      name = "#{witness}:type_id"
      next if @main_mod.globals[name]?

      global = @main_mod.globals.add(@main_llvm_context.int32, name)
      global.linkage = LLVM::Linkage::Internal if @single_module
      global.initializer = @main_llvm_context.int32.const_int(-1)
      global.global_constant = true
    end
  end

  # iyi: the class's `:headed` byte beside its `:type_id`, for the arena's
  # `__iyi_new` (`gc_layouts.cr`, `iyi_headed?`). Declared in the main
  # module here, at the first allocation site, and given its value at the
  # end of codegen (`iyi_define_headed_bytes`): the census reads which
  # virtual types were made, and codegen makes some late - the match
  # functions an artifact carries force one per class - so a value fixed
  # at the first site could be the wrong one by the last.
  private def iyi_headed_global(type) : LLVM::Value
    name = "#{type.llvm_name}:headed"
    @main_mod.globals[name]? || @main_mod.globals.add(@main_llvm_context.int8, name)
  end

  # iyi: the `:headed` byte of the class being allocated, loaded the way
  # `type_id_impl` loads the id - a constant the optimiser folds in a
  # single module, a reference the linker resolves from a unit.
  def iyi_headed_flag(type) : LLVM::Value
    global = iyi_headed_global(type)
    if @llvm_mod != @main_mod
      name = "#{type.llvm_name}:headed"
      unit_global = @llvm_mod.globals[name]?
      unless unit_global
        unit_global = @llvm_mod.globals.add(@llvm_context.int8, name)
        unit_global.linkage = LLVM::Linkage::External
        unit_global.global_constant = true
      end
      global = unit_global
    end
    load(@llvm_context.int8, global)
  end

  private def type_id_impl(type)
    type_id_name = "#{type.llvm_name}:type_id"

    global = @main_mod.globals[type_id_name]?
    unless global
      global = @main_mod.globals.add(@main_llvm_context.int32, type_id_name)
      global.linkage = LLVM::Linkage::Internal if @single_module
      global.initializer = @main_llvm_context.int32.const_int(@program.llvm_id.type_id(type))
      global.global_constant = true
    end

    if @llvm_mod != @main_mod
      global = @llvm_mod.globals[type_id_name]?
      unless global
        global = @llvm_mod.globals.add(@llvm_context.int32, type_id_name)
        global.linkage = LLVM::Linkage::External
        global.global_constant = true

        # iyi: which unit wanted it, so an artifact carrying that unit can say
        # so (SPEC.md IV.1g). This is the reference the linker resolves from
        # somebody else's `_main`, and the somebody else has to have the type
        # before it can number it. Recorded only while writing artifacts —
        # every other build defines what it refers to by construction.
        unless @program.iyi_exported_owners.empty?
          types = @program.iyi_unit_type_ids[@llvm_mod.name] ||= Set(Type).new
          types << type
        end
      end
    end

    load(@llvm_context.int32, global)
  end
end
