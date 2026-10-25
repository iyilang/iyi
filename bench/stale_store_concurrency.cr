require "../src/compiler/requires"
require "../src/compiler/iyi/stale/store"

if ARGV.empty?
  STDERR.puts "Usage: stale_store_concurrency run <cache_root> <proc_id> <count>"
  STDERR.puts "       stale_store_concurrency verify <cache_root> <expected_count>"
  exit 1
end

mode = ARGV[0]

case mode
when "run"
  if ARGV.size < 4
    STDERR.puts "Usage: stale_store_concurrency run <cache_root> <proc_id> <count>"
    exit 1
  end

  cache_root = ARGV[1]
  proc_id = ARGV[2].to_i
  count = ARGV[3].to_i

  store = Iyi::Stale::Store.new(cache_root)
  store.ensure_directories!

  toolchain = Iyi::Stale.hex(Iyi::Stale::Toolchain.digest(cache_root)) rescue ("t" * 64)
  behavior = "b" * 64
  link = "l" * 64
  cenv = "c" * 64

  test = Iyi::Stale::TestId.new("src", "concurrency_test_#{proc_id}.iyi")

  count.times do |i|
    callpath = sprintf("%064x", i)
    build = sprintf("%064x", (proc_id.to_u64 << 32) | i.to_u64)
    profile_fp = sprintf("%064x", proc_id)
    trace_fp = sprintf("%064x", i)

    b = Iyi::Stale::ReceiptBuild.new(build, toolchain, behavior, callpath, link, cenv)
    p = Iyi::Stale::ReceiptProfile.new(
      profile_fp,
      [] of String,
      "null",
      "piped",
      test,
      60.0,
      18,
      {} of String => Int64,
      nil,
      "cleared",
      "target",
      "os",
      "kernel"
    )
    tr = Iyi::Stale::ReceiptTrace.new(trace_fp)

    rec = Iyi::Stale::Receipt.new(test, b, p, tr, newest: "pass")
    store.record(rec)
  end
when "verify"
  if ARGV.size < 3
    STDERR.puts "Usage: stale_store_concurrency verify <cache_root> <expected_count>"
    exit 1
  end

  cache_root = ARGV[1]
  expected_count = ARGV[2].to_i
  store = Iyi::Stale::Store.new(cache_root)

  parsed_count = 0
  records_dir = store.records_dir

  unless Dir.exists?(records_dir)
    STDERR.puts "Error: records directory #{records_dir} does not exist"
    exit 1
  end

  Dir.each_child(records_dir) do |ab|
    ab_dir = File.join(records_dir, ab)
    next unless Dir.exists?(ab_dir)

    Dir.each_child(ab_dir) do |fname|
      next unless fname.ends_with?(".json")
      fpath = File.join(ab_dir, fname)
      begin
        content = File.read(fpath)
        receipt = Iyi::Stale::Receipt.from_json(content)
        parsed_count += 1
      rescue ex
        STDERR.puts "Error: failed to parse #{fpath}: #{ex.message}"
        exit 1
      end
    end
  end

  seq_val = store.current_seq
  if parsed_count != expected_count
    STDERR.puts "Error: expected #{expected_count} records, found #{parsed_count}"
    exit 1
  end

  if seq_val != expected_count.to_u64
    STDERR.puts "Error: expected seq #{expected_count}, got #{seq_val}"
    exit 1
  end

  puts "OK: verified #{parsed_count} parseable records, seq=#{seq_val}"
else
  STDERR.puts "Unknown mode: #{mode}"
  exit 1
end
