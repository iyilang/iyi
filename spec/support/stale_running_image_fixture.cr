require "compiler/requires"
require "compiler/iyi/stale/toolchain"
require "file_utils"

root = ARGV[0]
cache = File.join(root, "toolchain")
Dir.mkdir_p(cache)
Iyi::Stale::Toolchain.digest(cache)
puts "ready"
STDOUT.flush
STDIN.gets
begin
  Iyi::Stale::Toolchain.digest(cache)
  puts "UNSAFE: replacement image accepted"
rescue ex
  puts "REFUSED: #{ex.message}"
end
