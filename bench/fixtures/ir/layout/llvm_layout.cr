# The oracle for integer layouts: LLVM's own DataLayout for one target, through the bindings the compiler hosted in Crystal
# links. It prints the lines `ir_core structs` prints for the two named structs of layout/wide_structs.ir.in, in that
# file's order, so the two outputs compare line for line.
#
#   CRYSTAL_PATH=src bin/crystal build -o llvm_layout bench/fixtures/ir/layout/llvm_layout.cr
#   ./llvm_layout TRIPLE
require "llvm"

{% for name in %w(aarch64 x86 webassembly) %}
LibLLVM.initialize_{{name.id}}_target_info
LibLLVM.initialize_{{name.id}}_target
LibLLVM.initialize_{{name.id}}_target_mc
{% end %}

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
