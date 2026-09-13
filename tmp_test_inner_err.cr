require "compiler/requires"

src = "alias BadTuple = Tuple(1)"
filename = "eval.iyi"

begin
  program = Iyi::Program.new
  parser = Iyi::Parser.new(src)
  parser.filename = filename
  node = parser.parse
  node.accept Iyi::TopLevelVisitor.new(program)
rescue ex : Iyi::CodeError
  curr : Exception? = ex
  while inner = curr.as?(Iyi::CodeError).try(&.inner)
    curr = inner
  end
  puts "Deepest error: #{curr.try(&.message)}"
rescue ex
  puts "Error: #{ex.message}"
end
