# Does every string constructor leave room for the terminator a C API reads?
#
# `String` is NUL-terminated for exactly one reason: something outside the
# language calls `strlen` on it. LLVM does, on every function name the
# compiler hands it. So the terminator is not decoration, it is part of what
# the buffer must hold, and a constructor that allocates `header + bytesize`
# has written one byte into whatever comes next.
#
# bdw-gc cannot show that: it rounds a block up to a size class and never
# reissues an address something still points at, so the byte lands in padding
# nobody reads. `malloc_size` under `-Dgc_none` is exactly what was asked for,
# which is why this probe is only meaningful there and why the bug it catches
# survived for as long as it did.
#
# Run by bench/collector_free_floor.sh. Exits non-zero and names the
# constructor and the lengths, because the failing lengths are the tell: they
# are where `header + bytesize` lands exactly on a power of two.
lib LibTerminatorRoom
  fun malloc_size(ptr : Void*) : LibC::SizeT
end

LENGTHS = 1..3000

def room?(s : String) : Bool
  base = s.as(Void*)
  header = s.to_unsafe.address - base.address
  LibTerminatorRoom.malloc_size(base) >= header + s.bytesize + 1
end

short = [] of Int32
bad = {} of String => Array(Int32)

record = ->(kind : String, n : Int32) do
  (bad[kind] ||= [] of Int32) << n
end

LENGTHS.each do |n|
  # Grown one byte at a time from a capacity of 1: the growth path.
  sb = String::Builder.new(1)
  n.times { sb << "z" }
  record.call("String::Builder grown", n) unless room?(sb.to_s)

  # What String.build uses, through IO.
  built = String.build { |io| n.times { io << "a" } }
  record.call("String.build", n) unless room?(built)

  # Interpolation, which is how the compiler writes generated names.
  interpolated = "#{"a" * (n - 1)}b"
  record.call("interpolation", n) unless room?(interpolated)

  # The direct constructor with a known capacity.
  made = String.new(n) do |buf|
    n.times { |k| buf[k] = 'c'.ord.to_u8 }
    {n, n}
  end
  record.call("String.new", n) unless room?(made)

  # Concatenation through the builder.
  joined = ["x" * (n // 2), "y" * (n - n // 2)].join
  record.call("join", n) unless room?(joined)
end

if bad.empty?
  puts "every constructor leaves room, #{LENGTHS.size} lengths each"
  exit 0
end

bad.each do |kind, lengths|
  puts "NO ROOM #{kind}: #{lengths.size} lengths, first #{lengths.first(6).join(", ")}"
end
puts "A string whose terminator is outside its allocation corrupts whatever is"
puts "allocated next. See src/string/builder.cr and SPEC.md III.9."
exit 1
