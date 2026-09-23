require "./codegen"

class Iyi::CodeGenVisitor
  # The symbol each load `iyi_symbol_value` emitted reads, for the two places
  # that decide something about a symbol at compile time.
  @iyi_symbol_loads = {} of LLVM::Value => String

  # iyi: a symbol's value, read the way `type_id_impl` reads a type id
  # (SPEC.md IV.1g).
  #
  # A symbol is its index in this program's table, and the index is the
  # program's: a build numbers its symbols in the order it meets them. An
  # artifact's unit baked the producer's numbers in, so a consumer whose own
  # code met one symbol more, or met them in another order, compared
  # `:before` against a different number - `samples/webapp.iyi` built from
  # its artifacts counted no before-filter, because `case kind when :before`
  # in the router's unit never matched the `:before` the consumer passed.
  # It passed only while nothing moved the numbering; the prelude's
  # `IyiOnce` naming `:acquire` first moved it.
  #
  # So a unit reads the value from a global the main module defines, and the
  # main module's own code keeps the constant, which is every symbol of a
  # single-module build.
  def iyi_symbol_value(name : String) : LLVM::Value
    index = @symbols[name]
    return int(index) if @llvm_mod == @main_mod

    global_name = iyi_symbol_global_name(name)
    iyi_define_symbol_global(global_name, index) unless @main_mod.globals[global_name]?

    global = @llvm_mod.globals[global_name]?
    unless global
      global = @llvm_mod.globals.add(@llvm_context.int32, global_name)
      global.linkage = LLVM::Linkage::External
      global.global_constant = true

      # Which unit read it, so an artifact carrying the unit can say so: the
      # consumer has to have the name to number it, and a symbol only the
      # unit's own code spells is one the consumer never met. Recorded only
      # while writing artifacts, as `type_id_impl` records its types.
      unless @program.iyi_exported_owners.empty?
        (@program.iyi_unit_symbol_literals[@llvm_mod.name] ||= Set(String).new) << name
      end
    end

    value = load(@llvm_context.int32, global)
    @iyi_symbol_loads[value] = name
    value
  end

  # The symbol *value* names, whether it is the main module's constant or a
  # unit's load: a symbol autocast to an enum member is resolved by name here,
  # at compile time, and a load has no number to look up.
  def iyi_symbol_name(value : LLVM::Value) : String
    if value.constant?
      @symbols_by_index[value.const_int_get_sext_value]
    else
      @iyi_symbol_loads[value]? || raise "BUG: a symbol's value is neither its constant nor its load"
    end
  end

  # Every symbol's global, for an artifact's units: they read the ones they
  # spell, and this build cannot see which. The names they carried were added
  # to the program's symbols when the artifact was read, so each has a number
  # here (`iyi_define_all_type_ids` for the same reason).
  def iyi_define_all_symbol_values : Nil
    @symbols.each do |name, index|
      global_name = iyi_symbol_global_name(name)
      next if @main_mod.globals[global_name]?
      iyi_define_symbol_global(global_name, index)
    end
  end

  private def iyi_symbol_global_name(name : String) : String
    "~symbol:#{name}"
  end

  private def iyi_define_symbol_global(global_name : String, index : Int32) : Nil
    global = @main_mod.globals.add(@main_llvm_context.int32, global_name)
    global.linkage = LLVM::Linkage::Internal if @single_module
    global.initializer = @main_llvm_context.int32.const_int(index)
    global.global_constant = true
  end
end
