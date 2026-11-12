require "../../spec_helper"

# A typer sizes its own context's types, whatever another context held.
#
# LLVM's `DataLayout` caches a struct's layout under the struct type's address
# and keeps the entry after the type's context is disposed. Typers used to
# share the target machine's one `DataLayout`, so a typer whose context was
# dropped while the program compiled on left its structs' layouts behind, and
# the next context to put a struct at one of those addresses was told the dead
# struct's size. Two modules' typers then disagreed on whether a type is
# passed through memory, and LLVM refused the call between them.
#
# Whether a later context gets the dead address is the allocator's choice. On
# the machines this was measured on it did every time; where it does not, the
# example says so rather than passing on nothing.
describe "Code gen: a typer's layouts" do
  it "sizes a struct by its own fields at an address a disposed context's struct had" do
    program = semantic(<<-CRYSTAL).program
      struct Wide
        @a = 0_i64
        @b = 0_i64
        @c = 0_i64
        @d = 0_i64
        @e = 0_i64
        @f = 0_i64
        @g = 0_i64
        @h = 0_i64
        @i = 0_i64
        @j = 0_i64
        @k = 0_i64
        @l = 0_i64
        @m = 0_i64
        @n = 0_i64
        @o = 0_i64
        @p = 0_i64
        @q = 0_i64
        @r = 0_i64
        @s = 0_i64
        @t = 0_i64
      end

      struct Narrow
        @a = 0_i8
      end
      CRYSTAL
    wide = program.types["Wide"]
    narrow = program.types["Narrow"]

    dead_context = LLVM::Context.new(dispose_on_finalize: false)
    dead_typer = Iyi::LLVMTyper.new(program, dead_context)
    dead_struct = dead_typer.llvm_type(wide)
    dead_typer.size_of(dead_struct).should eq(160)
    dead_address = dead_struct.to_unsafe.address
    LibLLVM.dispose_context(dead_context)

    reused = 0
    64.times do
      context = LLVM::Context.new(dispose_on_finalize: false)
      typer = Iyi::LLVMTyper.new(program, context)
      type = typer.llvm_type(narrow)
      at_dead_address = type.to_unsafe.address == dead_address
      size = typer.size_of(type)
      LibLLVM.dispose_context(context)

      if at_dead_address
        reused += 1
        size.should eq(1)
      end
    end

    pending! "no later context put a struct at the disposed struct's address" if reused == 0
  end
end
