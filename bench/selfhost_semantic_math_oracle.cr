# The oracle for the math interpreter: the hosted `Iyi::MathInterpreter`
# folds each constant expression of a fixture, one per line, and prints the
# value with the Crystal type it answers with (the kind), or the message the
# hosted compiler raises. A comment line `# target: u8` (any integer kind, or
# `# target: none`) sets the target type for the lines after it, as an enum
# value or a StaticArray size does. The port's driver prints the same lines.
require "compiler/requires"

KIND_NAMES = {
  "i8" => Iyi::NumberKind::I8, "i16" => Iyi::NumberKind::I16,
  "i32" => Iyi::NumberKind::I32, "i64" => Iyi::NumberKind::I64,
  "i128" => Iyi::NumberKind::I128, "u8" => Iyi::NumberKind::U8,
  "u16" => Iyi::NumberKind::U16, "u32" => Iyi::NumberKind::U32,
  "u64" => Iyi::NumberKind::U64, "u128" => Iyi::NumberKind::U128,
}

def kind_name(value) : String
  case value
  when Int8    then "i8"
  when Int16   then "i16"
  when Int32   then "i32"
  when Int64   then "i64"
  when Int128  then "i128"
  when UInt8   then "u8"
  when UInt16  then "u16"
  when UInt32  then "u32"
  when UInt64  then "u64"
  when UInt128 then "u128"
  else              "other"
  end
end

filename = ARGV[0]
program = Iyi::Program.new
target_name = "none"
File.read_lines(filename).each_with_index do |line, index|
  text = line.strip
  if text =~ /\A# target: (\w+)\z/
    target_name = $1
    next
  end
  next if text.empty? || text.starts_with?("#")
  target = nil
  if target_name != "none"
    target = Iyi::IntegerType.new(program, program, target_name.upcase, nil, 8, 2, KIND_NAMES[target_name])
  end
  begin
    parser = Iyi::Parser.new(text)
    parser.filename = filename
    node = parser.parse
  rescue ex : Exception
    puts "#{index + 1}: syntax=#{ex.message}"
    next
  end
  begin
    value = Iyi::MathInterpreter.new(program, nil, target).interpret(node)
    puts "#{index + 1}: value=#{value} kind=#{kind_name(value)}"
  rescue ex : Exception
    puts "#{index + 1}: error=#{ex.message}"
  end
end
