require "./codegen"

# iyi: GC_DESIGN.md Stage 5 embeds the program's pointer maps into the binary
# itself, as the prelude's mark loop reads them. Stage 1 carried them in
# `.iyimod`'s `Layouts` section; that section travels between builds, but the
# collector that runs inside one program needs its own table in that
# program's own image, because two programs number their types differently and
# a `.iyimod` is not present at run time.
#
# The prelude holds an external global, `__iyi_gc_layouts`, and takes its
# address rather than its value. This file gives the symbol its one real
# definition. Emitting it unconditionally when `-Dgc_iyi` is set — rather
# than when the prelude references it — is deliberate: nothing would change
# on this platform today, but an artifact build that never asks for the
# marker must still link a program that does, and the symbol existing on
# demand is a promise a future build might quietly break.

# The prelude's allocator selection has its twin here: `iyi_gc_arena?` is
# the compiler's answer to "does this build's prelude allocate through the
# owned collector's arena", and it must equal the macro condition at the
# top of `src/iyi/prelude.iyi`'s allocator seam. It gates two emissions —
# the type id stored into the object header at every class allocation, and
# the layout table below — and the two sides disagreeing is not a
# degradation in one direction: a compiler that writes ids into a header
# the prelude did not allocate is memory corruption. Change both or
# neither.
class Iyi::Program
  # iyi's object layout, against Crystal's: an object is its fields and
  # nothing else, and its type id is the high half of the header word
  # under the pointer, at `P-4`, which every allocator mode of iyi's
  # prelude leaves there. Crystal's layout - the type id an `i32` at the
  # object's front - stays for a `--crystal` program (its runtime is
  # Crystal's, allocating through Boehm with nothing under the pointer)
  # and for the compiler's own bootstrap, which is such a program. The
  # ground truth is the prelude itself: a spec-built snippet carries the
  # default `iyi_prelude?` without ever loading it, and is JIT-run inside
  # the spec harness, whose allocator leaves no word under the pointer
  # either. `IyiRuntimeLock` is the prelude's, under every mode and on
  # every target.
  def iyi_object_layout? : Bool
    cached = @iyi_object_layout
    return cached unless cached.nil?
    @iyi_object_layout = iyi_prelude? && !types?.try(&.[]?("IyiRuntimeLock")).nil?
  end

  @iyi_object_layout : Bool?

  def iyi_gc_arena? : Bool
    # Own-prelude builds only: a `--crystal` program allocates through
    # Boehm, its types include the standard library's own lowerings, and
    # both halves of this gate would be wrong there — the layout walk
    # crashes on shapes the arena never allocates, and the id store would
    # scribble into Boehm's heap. CI taught this line by turning every
    # `--crystal` build red the first time the predicate forgot it.
    return false unless iyi_prelude?
    return false if has_flag?("gc_boehm") || has_flag?("gc_none")
    return false unless (has_flag?("linux") && (has_flag?("x86_64") || has_flag?("aarch64"))) ||
                        has_flag?("darwin") ||
                        has_flag?("win32") ||
                        has_flag?("wasm32")
    # And the ground truth over the flags: the header exists if and only if
    # the arena compiled in, and the arena is `IyiHeap`. A spec-built
    # program carries the default `iyi_prelude?` without ever loading the
    # prelude, and the compiler specs JIT such snippets inside their own
    # process — where an id store into libc-malloc'd memory is 'corrupted
    # size vs. prev_size' at the spec harness's next free. The type lookup
    # is what makes that impossible rather than unlikely.
    !types?.try(&.[]?("IyiHeap")).nil?
  end
end

class Iyi::CodeGenVisitor
  GC_LAYOUTS_NAME = "__iyi_gc_layouts"

  # The table's word layout, named here once so the prelude can be read
  # beside it rather than beside a number:
  #
  #     word 0                      entry count
  #     five words per entry, sorted by type id:
  #       +0  type_id               the header's `type_id`
  #       +1  alloc_size            as laid out, not rounded
  #       +2  scan_cap              unrounded instance size
  #       +3  scan_count            pointer fields, from `scan_offsets`
  #       +4  scan_index            into the offset words after the entries
  #     then every entry's offsets, one word each, concatenated
  GC_LAYOUT_WORDS_PER_ENTRY = 5

  def iyi_define_gc_layouts : Nil
    entries = collect_gc_layout_entries
    iyi_define_headed_bytes
    iyi_header_census(entries) if ENV["IYI_HEADER_CENSUS"]?

    # The marker reads the layout table for every object it touches, and a
    # missing entry means a conservative word-scan, never a crash. Sorting by
    # type id lets that lookup be a binary search in the prelude, and lets
    # this method keep the same determinism `collect_iyi_layouts` keeps for
    # the `.iyimod` section: the same program yields the same table.
    entries.sort_by! { |_, layout| layout.type_id }

    # The prelude's `IyiMark` reads the table by walking a base pointer
    # forward; it does not index by type id. So the type id in every entry
    # doubles as a sentinel for the binary search: if the table's count does
    # not agree with its sorted type ids, the search still terminates
    # without reading past the end.
    words = [] of UInt64
    words << entries.size.to_u64
    offset_words = [] of UInt64
    entries.each do |type, layout|
      words << layout.type_id.to_u64
      words << layout.alloc_size.to_u64
      words << layout.scan_cap.to_u64
      words << layout.scan_offsets.size.to_u64
      words << offset_words.size.to_u64
      layout.scan_offsets.each do |offset|
        offset_words << offset.to_u64
      end
    end
    words.concat offset_words

    # `@main_llvm_context` rather than the typer's: the typer has no context
    # accessor, and codegen already keeps the main module's context in that
    # ivar for exactly this reason (a global built in `@llvm_context` and
    # linked into `@main_mod` is two distinct types to LLVM even when the
    # dumped IR is identical, which the note beside `main_llvm_context_size_t`
    # records the hard way).
    initializer = @main_llvm_context.int64.const_array(words.map { |word| int64(word.to_i64) })
    table = @main_mod.globals.add(initializer.type, "#{GC_LAYOUTS_NAME}:table")
    table.linkage = LLVM::Linkage::Internal if @single_module
    table.global_constant = true
    table.initializer = initializer

    # The symbol the prelude declares. If the prelude already touched it,
    # `declare_lib_var` left it declared but without an initializer; give
    # it one now, or make the declaration whole if it did not.
    symbol = @main_mod.globals[GC_LAYOUTS_NAME]? ||
             @main_mod.globals.add(@main_llvm_context.void_pointer, GC_LAYOUTS_NAME)
    symbol.initializer = table
    symbol.dll_storage_class = LLVM::DLLStorageClass::Default
    unless @single_module
      symbol.linkage = LLVM::Linkage::External
    end

    # The marking flag the write barrier checks (GC_DESIGN.md Stage 9):
    # one byte, zero until the marker raises it, defined here beside the
    # table for the same reason — the prelude declares it, the program
    # must own it, and the collector's builds are the only ones with a
    # marker to raise it.
    flag = @main_mod.globals[MARKING_NAME]? ||
           @main_mod.globals.add(@main_llvm_context.int8, MARKING_NAME)
    flag.initializer = @main_llvm_context.int8.const_int(0)
    flag.dll_storage_class = LLVM::DLLStorageClass::Default
    unless @single_module
      flag.linkage = LLVM::Linkage::External
    end
  end

  # Which classes carry their type id in the object, a word ahead of it
  # at `P-4`, and which are their fields alone (GC_DESIGN.md, "The last
  # eight bytes"). A class needs the word when something reads it, and
  # what reads it is `object_type_id`: a virtual type over an ancestor of
  # the class that was ever made, or a reference union - thin pointers
  # dispatched by the object's own id - the class or an ancestor is a
  # member of. A class in a mixed union rides under the union's own tag,
  # and a nilable class is a null test. And a class whose id does not fit
  # the arena's sixteen-bit layout slot, which the mark would read for a
  # headless one. The answer is the *program's*: a module's object code
  # allocates through a `:headed` byte the program that links defines
  # (`iyi_define_all_type_ids`), the way it reads `:type_id`, because a
  # class one module never dispatches on is in a union the next one makes.
  # `String` is headed by rule: the prelude builds one from bytes
  # (`string.iyi`, `String.new`) and stores the id under it itself, and
  # the prelude cannot read the byte this decision becomes.
  def iyi_headed?(type : Type) : Bool
    return true if type == @program.string
    headed = @iyi_headed ||= iyi_headed_types
    headed.includes?(type) || @program.llvm_id.type_id(type) > UInt16::MAX
  end

  @iyi_headed : Set(Type)?

  # Every class's `:headed` byte, defined in the main module at the end
  # of codegen - the census is complete then, and every allocation site
  # has declared the byte it loads (`type_id.cr`, `iyi_headed_global`).
  # Every numbered class rather than the ones this program allocated,
  # for the reason `iyi_define_all_type_ids` defines every id: a unit's
  # object code allocates what this build never sees.
  private def iyi_define_headed_bytes : Nil
    @program.llvm_id.each_type do |type|
      next unless type.is_a?(NonGenericClassType) || type.is_a?(GenericClassInstanceType)
      name = "#{type.llvm_name}:headed"
      global = @main_mod.globals[name]? || @main_mod.globals.add(@main_llvm_context.int8, name)
      global.linkage = LLVM::Linkage::Internal if @single_module
      global.initializer = @main_llvm_context.int8.const_int(iyi_headed?(type) ? 1 : 0)
      global.global_constant = true
    end
  end

  # The classes asked are the ones the census lays out
  # (`collect_gc_layout_entries`): a plain class and an instantiated generic.
  # `Array(Any)` is the second and not a `ClassType`; a reference union it
  # is a member of - the one a `case` over `Nil | ... | Array(Any) |
  # Hash(Any, Any)` narrows to once the value arms are ruled out -
  # dispatches it by the word under the object, so the word must be there.
  private def iyi_headed_types : Set(Type)
    headed = Set(Type).new
    @program.llvm_id.each_type do |type|
      next unless iyi_headed_candidate?(type) && type.virtual_type_made?
      headed << type
      type.all_subclasses.each { |sub| headed << sub }
    end
    # The unions the program made, from the program's own cache: the id
    # table holds no union and no virtual type.
    @program.unions.each_value do |union|
      next unless union.is_a?(ReferenceUnionType) || union.is_a?(NilableReferenceUnionType)
      union.union_types.each do |member|
        member = member.remove_alias
        next unless iyi_headed_candidate?(member)
        headed << member
        member.all_subclasses.each { |sub| headed << sub }
      end
    end
    headed
  end

  private def iyi_headed_candidate?(type : Type) : Bool
    type.is_a?(NonGenericClassType) || type.is_a?(GenericClassInstanceType)
  end

  # The census, on `IYI_HEADER_CENSUS=1`: the decision above printed to
  # stderr, one line a class, then the count.
  private def iyi_header_census(entries : Array({Type, IyiMod::TypeLayout})) : Nil
    with_header = 0
    without = 0
    entries.each do |type, layout|
      needs = iyi_headed?(type)
      words = type.is_a?(InstanceVarContainer) ? type.all_instance_vars.size : 0
      STDERR.puts "header census: #{needs ? "headed  " : "headless"} #{type} (#{words} ivars, #{layout.scan_offsets.size} pointer fields)"
      needs ? (with_header += 1) : (without += 1)
    end
    STDERR.puts "header census: #{with_header} classes need the type id in the object, #{without} do not, of #{entries.size} laid out"
  end

  # The same filter `collect_iyi_layouts` applies to a module's own types,
  # widened to the whole program's type table: only a type laid out as an
  # object gets an entry, and a generic that was never instantiated does not
  # get one. A layout with a zero `type_id` would collide with the sentinel
  # for "no layout", and that id is `Nil`'s, which is never allocated — so
  # skip it rather than emit a conflicting entry.
  private def collect_gc_layout_entries : Array({Type, IyiMod::TypeLayout})
    entries = [] of {Type, IyiMod::TypeLayout}

    @program.llvm_id.each_type do |type|
      next unless type.is_a?(NonGenericClassType) || type.is_a?(GenericClassInstanceType)
      next if type.is_a?(GenericType) || type.is_a?(StaticArrayInstanceType)

      layout = @program.gc_type_layout(type)
      next if layout.type_id == 0

      entries << {type, layout}
    end

    entries
  end
end
