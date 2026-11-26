# The oracle for integer layouts: LLVM's own DataLayout for one target, through the bindings the compiler hosted in Crystal
# links. It prints the lines `ir_core structs` prints for the two named structs of layout/wide_structs.ir.in, in that
# file's order, so the two outputs compare line for line.
#
#   CRYSTAL_PATH=src bin/crystal build -o llvm_layout bench/fixtures/ir/layout/llvm_layout.cr
#   ./llvm_layout TRIPLE
#   ./llvm_layout --predicates FILE
require "llvm"

{% for name in %w(aarch64 x86 webassembly) %}
LibLLVM.initialize_{{name.id}}_target_info
LibLLVM.initialize_{{name.id}}_target
LibLLVM.initialize_{{name.id}}_target_mc
{% end %}

# `--predicates FILE` prints, for each icmp and fcmp in FILE in order, the predicate name LLVM reads there, as IR text
# writes it (`fcmp ogt`, `icmp ule`). bench/native_ir_exercise.sh compares these with `ir_core predicates FILE`, which
# names each predicate from the port's own enum: the two number their floating predicates differently, so names are
# what they share.

# The spelling of a floating predicate in IR text: LLVM's enum names it, except that its false and true members are
# written false and true.
def llvm_real_text(predicate : LLVM::RealPredicate) : String
  return "false" if predicate == LLVM::RealPredicate::PredicateFalse
  return "true" if predicate == LLVM::RealPredicate::PredicateTrue
  predicate.to_s.downcase
end

lib LibLLVM
  fun get_fcmp_predicate = LLVMGetFCmpPredicate(inst : ValueRef) : Int32
  fun get_icmp_predicate = LLVMGetICmpPredicate(inst : ValueRef) : Int32
  fun is_a_fcmp_inst = LLVMIsAFCmpInst(val : ValueRef) : ValueRef
  fun is_a_icmp_inst = LLVMIsAICmpInst(val : ValueRef) : ValueRef
end

if ARGV[0] == "--predicates"
  parsed = LLVM::Context.new.parse_ir(LLVM::MemoryBuffer.from_file(ARGV[1]))
  fn = LibLLVM.get_first_function(parsed.to_unsafe)
  until fn.null?
    bb = LibLLVM.get_first_basic_block(fn)
    until bb.null?
      inst = LibLLVM.get_first_instruction(bb)
      until inst.null?
        unless LibLLVM.is_a_fcmp_inst(inst).null?
          puts "fcmp #{llvm_real_text(LLVM::RealPredicate.new(LibLLVM.get_fcmp_predicate(inst)))}"
        end
        unless LibLLVM.is_a_icmp_inst(inst).null?
          puts "icmp #{LLVM::IntPredicate.new(LibLLVM.get_icmp_predicate(inst)).to_s.downcase}"
        end
        inst = LibLLVM.get_next_instruction(inst)
      end
      bb = LibLLVM.get_next_basic_block(bb)
    end
    fn = LibLLVM.get_next_function(fn)
  end
  exit
end

triple = ARGV[0]
ctx = LLVM::Context.new
data = LLVM::Target.from_triple(triple).create_target_machine(triple).data_layout

# The same field lists as the fixture, in the same order.
shapes = {"Wide" => [ctx.int(8), ctx.int(192), ctx.int(33)], "Mid" => [ctx.int(65), ctx.int(256), ctx.int(9)]}
shapes.each do |name, fields|
  st = ctx.struct(fields)
  puts "struct #{name} size=#{data.abi_size(st)} align=#{data.abi_alignment(st)}"
  fields.each_with_index do |f, i|
    bytes = (data.size_in_bits(f) + 7) // 8
    puts "field #{i} offset=#{data.offset_of_element(st, i)} size=#{bytes}"
  end
end
