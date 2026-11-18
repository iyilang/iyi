# iyi: the pass that turns the lowered types into pointer maps, which the
# `Layouts` section of a `.iyimod` carries (GC_DESIGN.md Stage 1).
#
# The collector this feeds never discovers an object's shape at run time: the
# compiler knows which words in an object are pointers, and this is where that
# knowledge is written down. Heap-layout precision is the one REQUIREMENT
# SPEC.md II.5 makes, and it is cheap precisely because the table is computed
# here, beside the typer that lowered the type.
#
# Every byte offset is LLVM's data layout answering about the emitted struct,
# never field sizes added up by hand. Padding and alignment are the target's
# business, and a hand-summed map that gets them wrong misses fields silently,
# which is the one failure a pointer map must not have.
#
# The walk below classifies each field: a reference, a `Pointer(T)`, a proc's
# context word, or an inline aggregate to recurse into. Where the exact shape
# is runtime business (a union's live arm, a C union's overlap), the map marks
# every word the field could put a pointer in. That asymmetry is the whole
# safety argument: over-marking retains an object too long, under-marking
# loses a live one.
#
# What is not here: a cross-module shape key. A generic that is not
# instantiated in this build has no layout to emit, and one entry serving two
# instantiations by shape is R-4's per-GC-shape keying, which nothing
# implements yet. `Type#gc_shape` exists and is not that key: it is a
# depth-bounded string built for a conservative measurement, collapsing
# pointers and references to one "PTR" and falling back to the exact type
# name at its depth limit. Fine for a lower bound, not fine as the identity
# of a pointer map. Its `pointer?` and `reference_like?` predicates, on the
# other hand, are exactly the distinction the walk below wants, and they are
# what it uses.

module Iyi
  class Program
    # The `IyiMod::TypeLayout` for one lowered type.
    #
    # *type* must be a concrete instance-variable container: a class, a
    # struct, or an instantiated generic one. Callers filter, because an
    # uninstantiated generic has no layout and a module or enum has no fields
    # to map - and a static array lowers to an LLVM array, not a struct: no
    # fields, every word an element, so it gets no entry and the marker
    # word-scans it to its size, which is exactly the elements.
    def gc_type_layout(type : Type) : IyiMod::TypeLayout
      typer = llvm_typer
      struct_type = typer.llvm_struct_type(type)

      scan_offsets = [] of UInt64
      gc_scan_offsets(type, struct_type, 0_u64, scan_offsets)
      scan_offsets.sort!.uniq!

      # The format's offsets are u32. A type with a pointer word past 4 GiB
      # is refused rather than written down wrong: a truncated offset is a
      # field the collector never marks.
      scan_offsets.each do |offset|
        if offset > UInt32::MAX
          raise Iyi::Error.new(
            "#{type} holds a pointer word at byte offset #{offset}, which a " \
            "TypeLayout offset (u32) cannot say. The format caps a mapped " \
            "object at 4 GiB; this type is past it.")
        end
      end

      IyiMod::TypeLayout.new(
        type_id: llvm_id.type_id(type),
        alloc_size: typer.size_of(struct_type).to_u32,
        scan_cap: gc_scan_cap(type, struct_type).to_u32,
        scan_offsets: scan_offsets.map(&.to_u32),
        noscan_offsets: [] of UInt32,
      )
    end

    # The layout of a heap22 C1 closure context (`CodeGenVisitor
    # #iyi_c1_proc`): *struct_type*, laid out by *typer*, whose slots hold
    # values of *slot_types* in order. No type stands behind it, so the
    # map is built from the slots.
    def gc_closure_layout(type_id : Int32, typer : LLVMTyper, struct_type : LLVM::Type, slot_types : Array(Type)) : IyiMod::TypeLayout
      scan_offsets = [] of UInt64
      slot_types.each_with_index do |slot_type, index|
        gc_field_offsets(slot_type, typer.offset_of(struct_type, index), scan_offsets)
      end
      scan_offsets.sort!.uniq!
      size = typer.size_of(struct_type)
      IyiMod::TypeLayout.new(
        type_id: type_id,
        alloc_size: size.to_u32,
        scan_cap: size.to_u32,
        scan_offsets: scan_offsets.map(&.to_u32),
        noscan_offsets: [] of UInt32,
      )
    end

    # The pointer words of one type's own fields, at *base* within the object
    # being mapped. *struct_type* is the type's emitted struct, whose element
    # order is `all_instance_vars` order - under iyi's layout the type id is
    # under the object, not in it, and the table is only ever emitted for
    # that layout - so `index_of_instance_var` is the element index.
    private def gc_scan_offsets(type : Type, struct_type : LLVM::Type, base : UInt64, into : Array(UInt64)) : Nil
      if type.extern_union?
        # A C union's fields overlap, so which one is live is runtime
        # business. Every word goes in if any field could hold a pointer.
        if type.instance_vars.any? { |_, ivar| ivar.type.has_inner_pointers? }
          gc_conservative_words(struct_type, base, into)
        end
        return
      end

      type.all_instance_vars.each do |name, ivar|
        index = type.index_of_instance_var(name).not_nil!
        gc_field_offsets(ivar.type, base + llvm_typer.offset_of(struct_type, index), into,
          extern: type.extern?)
      end
    end

    # The pointer words inside one field of *field_type*, at *base* within the
    # object being mapped.
    #
    # *extern* says the field sits in a C struct, where a proc field is one
    # raw function pointer rather than the two-word `{fun, ctx}` an iyi proc
    # is.
    private def gc_field_offsets(field_type : Type, base : UInt64, into : Array(UInt64), extern = false) : Nil
      type = field_type.remove_indirection
      type = type.typedef.remove_indirection if type.is_a?(TypeDefType)

      # A `Nil` field stores nothing, so there is no word to mark.
      return if type.is_a?(NilType)
      return unless type.has_inner_pointers?

      typer = llvm_typer

      # The field is itself one pointer word: a class reference, a
      # `Pointer(T)`, a nilable or union of references, or a virtual class.
      # Mark it and let the collector recurse into what it points at.
      if type.pointer? || type.reference_like?
        into << base
        return
      end

      case type
      when ProcInstanceType, NilableProcType
        if extern
          into << base
        else
          # A proc is `{fun_ptr, ctx_ptr}`. The context word retains a
          # closure's captures; the function word is a code address and never
          # a heap object.
          into << base + typer.offset_of(typer.proc_type, 1)
        end
      when StaticArrayInstanceType
        stride = typer.size_of(typer.llvm_embedded_type(type.element_type))
        count = type.size.as(NumberLiteral).value.to_i64
        count.times do |index|
          gc_field_offsets(type.element_type, base + index.to_u64 * stride, into, extern: extern)
        end
      when TupleInstanceType
        llvm_type = typer.llvm_type(type)
        type.tuple_types.each_with_index do |element, index|
          gc_field_offsets(element, base + typer.offset_of(llvm_type, index), into, extern: extern)
        end
      when NamedTupleInstanceType
        llvm_type = typer.llvm_type(type)
        type.entries.each_with_index do |entry, index|
          gc_field_offsets(entry.type, base + typer.offset_of(llvm_type, index), into, extern: extern)
        end
      when UnionType
        # A mixed union is `{i32 tag, bytes}` and any arm may be live, so the
        # scan set is the union of every arm's pointer words, each arm laid
        # out where the union stores it. An integer arm's word landing in the
        # set can only over-mark.
        llvm_type = typer.llvm_type(type)
        value = typer.offset_of(llvm_type, 1)
        type.union_types.each do |arm|
          gc_field_offsets(arm, base + value, into, extern: extern)
        end
      when InstanceVarContainer
        # A struct field is stored inline, so its own pointer words are the
        # object's, shifted by where the field sits. (A class field returned
        # above: it is one word here, and its own map is the collector's
        # recursion, not this walk.)
        nested = typer.llvm_struct_type(type)
        gc_scan_offsets(type, nested, base, into)
      when MetaclassType, GenericClassInstanceMetaclassType,
           GenericModuleInstanceMetaclassType, VirtualMetaclassType, LibType
        # A metaclass value is an i32 type id, not a pointer.
      else
        # Anything else that claims inner pointers gets its words marked
        # rather than its shape guessed. A virtual struct field lands here:
        # stored as a pointer-sized value whose pointee's shape is the live
        # subtype's, so the word is all this map can say.
        gc_conservative_words(typer.llvm_embedded_type(type), base, into)
      end
    end

    # Every aligned word of an extent, for a field whose exact shape this walk
    # cannot say. Over-marking retains; a missed word loses a live object.
    private def gc_conservative_words(llvm_type : LLVM::Type, base : UInt64, into : Array(UInt64)) : Nil
      typer = llvm_typer
      size = typer.size_of(llvm_type)
      word = typer.pointer_size
      offset = base
      while offset + word <= base + size
        into << offset
        offset += word
      end
    end

    # The unrounded instance size: the end of the last field, before tail
    # padding. A collector that finds no layout for an object word-scans it
    # only this far, and tail padding is not a field.
    private def gc_scan_cap(type : Type, struct_type : LLVM::Type) : UInt64
      typer = llvm_typer
      return typer.size_of(struct_type) if type.extern_union?

      count = type.all_instance_vars.size
      # A class with no fields carries nothing either: its type id is under
      # the object, not in it, and this table is iyi's layout's only.
      return 0_u64 if count == 0

      last = count - 1
      element = struct_type.struct_element_types[last]
      typer.offset_of(struct_type, last) + typer.size_of(element)
    end
  end
end
