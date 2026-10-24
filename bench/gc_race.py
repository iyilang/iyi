#!/usr/bin/env python3
"""The collector against the two it is measured by: Boehm, which the
upstream compiler ships, and Go's.

The same three programs, written once in iyi and once in Go, built release,
run on an idle machine. Per arm: wall time (best of RUNS), peak RSS (the
worst of the same RUNS, from the kernel's own accounting), how many
collections ran, the longest stop-the-world pause and the total time spent
paused — each program prints its own collector's numbers on its last line,
and a row whose arms print different answers is refused rather than
reported.

    python3 bench/gc_race.py            # the table
    python3 bench/gc_race.py --check    # the table, and exit 1 if iyi loses
                                        # to Boehm on any pause or time cell

What the programs are for. `binary trees` is the benchmarks-game shape:
pointer-heavy, a long-lived tree beside short-lived ones, every object
typed, so the marker's precision and the sweep's cost are both on the
table. `live churn` holds a large live set and allocates garbage beside
it: a pause is proportional to what is live, so this is where a
stop-the-world collector shows its whole cost and a concurrent one shows
why it exists. `churn` allocates and drops with almost nothing live, the
allocator's fast path and the sweep's throughput and nothing else.

Boehm's pause is its full-collection total from `GC_get_full_gc_total_time`
(it does not keep a maximum); Go's is `runtime.MemStats`, whose pauses are
its stop-the-world phases only, the marking between them being concurrent
— which is the point of comparison, not a flaw in it. `GOMAXPROCS` is left
to Go: the machine is the machine.
"""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
# The exe itself where the caller names it: `bin/iyi` is a shell script,
# which Windows' python cannot start.
IYI = pathlib.Path(os.environ.get("IYI", ROOT / "bin" / "iyi"))
# Windows starts a program by its `.exe`, and both compilers write the name
# they are given, so every binary is named with it there.
EXE = ".exe" if os.name == "nt" else ""
RUNS = 5

IYI_STATS = '''
{% if flag?(:gc_boehm) %}
  lib LibGC
    fun start_performance_measurement = GC_start_performance_measurement : Nil
    fun full_gc_total_time = GC_get_full_gc_total_time : UInt64
    fun gc_no = GC_get_gc_no : UInt64
  end

  def stats_begin : Nil
    LibGC.start_performance_measurement
  end

  def stats_end : Nil
    puts "stats: collections=#{LibGC.gc_no.to_i64} pause_max_us=- pause_total_us=#{LibGC.full_gc_total_time.to_i64 * 1000_i64}"
  end
{% else %}
  def stats_begin : Nil
  end

  def stats_end : Nil
    puts "stats: collections=#{IyiMark.collections.to_i64} pause_max_us=#{IyiMark.pause_max_ns.to_i64 // 1000_i64} pause_total_us=#{IyiMark.pause_total_ns.to_i64 // 1000_i64}"
  end
{% end %}
'''

GO_STATS = '''
func statsEnd() {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	max := uint64(0)
	for _, p := range m.PauseNs {
		if p > max {
			max = p
		}
	}
	fmt.Printf("stats: collections=%d pause_max_us=%d pause_total_us=%d\\n", m.NumGC, max/1000, m.PauseTotalNs/1000)
}
'''

PROGRAMS = {
    "binary trees": {
        "iyi": '''
class Node
  @left : Node?
  @right : Node?

  def initialize(@left : Node?, @right : Node?)
  end

  def check : Int32
    left = @left
    right = @right
    return 1 if left.is_a?(Nil) || right.is_a?(Nil)
    1 + left.check + right.check
  end
end

def make(depth : Int32) : Node
  return Node.new(nil, nil) if depth == 0
  Node.new(make(depth - 1), make(depth - 1))
end

stats_begin
max_depth = 16
stretch = make(max_depth + 1)
puts "stretch tree of depth #{max_depth + 1}\\t check: #{stretch.check}"
long_lived = make(max_depth)
depth = 4
total = 0_i64
while depth <= max_depth
  iterations = 1.unsafe_shl(max_depth - depth + 4)
  check = 0_i64
  i = 0
  while i < iterations
    check = check + make(depth).check
    i = i + 1
  end
  puts "#{iterations}\\t trees of depth #{depth}\\t check: #{check}"
  total = total + check
  depth = depth + 2
end
puts "long lived tree of depth #{max_depth}\\t check: #{long_lived.check}"
stats_end
''',
        "go": '''
package main

import (
	"fmt"
	"runtime"
)

type Node struct {
	left, right *Node
}

func (n *Node) check() int32 {
	if n.left == nil || n.right == nil {
		return 1
	}
	return 1 + n.left.check() + n.right.check()
}

func make_(depth int32) *Node {
	if depth == 0 {
		return &Node{}
	}
	return &Node{make_(depth - 1), make_(depth - 1)}
}
%s
func main() {
	maxDepth := int32(16)
	stretch := make_(maxDepth + 1)
	fmt.Printf("stretch tree of depth %%d\\t check: %%d\\n", maxDepth+1, stretch.check())
	longLived := make_(maxDepth)
	var total int64
	for depth := int32(4); depth <= maxDepth; depth += 2 {
		iterations := 1 << (maxDepth - depth + 4)
		var check int64
		for i := 0; i < iterations; i++ {
			check += int64(make_(depth).check())
		}
		fmt.Printf("%%d\\t trees of depth %%d\\t check: %%d\\n", iterations, depth, check)
		total += check
	}
	fmt.Printf("long lived tree of depth %%d\\t check: %%d\\n", maxDepth, longLived.check())
	statsEnd()
}
''' % GO_STATS,
    },
    "live churn": {
        "iyi": '''
class Item
  @next_item : Item?
  @value : Int64
  @pad0 : Int64
  @pad1 : Int64

  def initialize(@next_item : Item?, @value : Int64)
    @pad0 = @value
    @pad1 = @value
  end

  def next_item : Item?
    @next_item
  end

  def value : Int64
    @value
  end
end

stats_begin
# A million live items, 48 bytes of payload each, held for the whole run.
head = nil.as(Item?)
i = 0_i64
while i < 1_000_000
  head = Item.new(head, i)
  i = i + 1
end
# 256 MiB of garbage beside it: 4 million 64-byte blocks, each touched.
sum = 0_u64
j = 0
while j < 4_000_000
  block = Pointer(UInt8).malloc(64_u64)
  block.value = 1_u8
  sum = sum &+ block.address
  j = j + 1
end
live = 0_i64
node = head
while node.is_a?(Item)
  live = live + node.value
  node = node.next_item
end
puts "live #{live} garbage #{(sum & 1023).to_i64}"
stats_end
''',
        "go": '''
package main

import (
	"fmt"
	"runtime"
)

type Item struct {
	next        *Item
	value       int64
	pad0, pad1  int64
}

type Block struct {
	bytes [64]byte
}

var sink *Block
%s
func main() {
	var head *Item
	for i := int64(0); i < 1000000; i++ {
		head = &Item{head, i, i, i}
	}
	var sum uint64
	for j := 0; j < 4000000; j++ {
		block := &Block{}
		block.bytes[0] = 1
		sink = block
		sum += uint64(uintptr(unsafePointer(block)))
	}
	var live int64
	for node := head; node != nil; node = node.next {
		live += node.value
	}
	fmt.Printf("live %%d garbage %%d\\n", live, sum&1023)
	statsEnd()
}
''' % GO_STATS,
    },
    "churn": {
        "iyi": '''
stats_begin
sum = 0_u64
i = 0
while i < 8_000_000
  block = Pointer(UInt8).malloc(64_u64)
  block.value = 1_u8
  sum = sum &+ block.address
  i = i + 1
end
puts "churn #{(sum & 1023).to_i64}"
stats_end
''',
        "go": '''
package main

import (
	"fmt"
	"runtime"
)

type Block struct {
	bytes [64]byte
}

var sink *Block
%s
func main() {
	var sum uint64
	for i := 0; i < 8000000; i++ {
		block := &Block{}
		block.bytes[0] = 1
		sink = block
		sum += uint64(uintptr(unsafePointer(block)))
	}
	fmt.Printf("churn %%d\\n", sum&1023)
	statsEnd()
}
''' % GO_STATS,
    },
}

# Go's answer for an address sum cannot equal iyi's (different heaps), so the
# address-derived word is masked to a value both print as data-dependent
# noise the comparison ignores: the answer compared is every line but the
# stats line with the masked word removed. See `answer_of`.
GO_UNSAFE = '''
import "unsafe"

func unsafePointer(p *Block) unsafe.Pointer { return unsafe.Pointer(p) }
'''

ARMS = ["iyi", "boehm", "go"]


def build_iyi(source: pathlib.Path, output: pathlib.Path, flags: list) -> None:
    command = [str(IYI), "build", "--release", *flags, "-o", str(output), str(source)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"build failed for {output.name}:\n{result.stderr[:1200]}")


def build_go(source: pathlib.Path, output: pathlib.Path) -> None:
    env = dict(os.environ, GOFLAGS="-mod=mod", GO111MODULE="off", CGO_ENABLED="0")
    result = subprocess.run(["go", "build", "-o", str(output), str(source)],
                            capture_output=True, text=True, env=env, cwd=source.parent)
    if result.returncode != 0:
        raise SystemExit(f"go build failed for {output.name}:\n{result.stderr[:1200]}")


def run_once(binary: pathlib.Path) -> tuple[float, int, str]:
    if os.name == "nt":
        return run_once_nt(binary)
    read_out, write_out = os.pipe()
    start = time.perf_counter()
    pid = os.posix_spawn(str(binary), [str(binary)], os.environ,
                         file_actions=[(os.POSIX_SPAWN_DUP2, write_out, 1)])
    os.close(write_out)
    chunks = []
    while True:
        piece = os.read(read_out, 65536)
        if not piece:
            break
        chunks.append(piece)
    os.close(read_out)
    _, status, rusage = os.wait4(pid, 0)
    elapsed = time.perf_counter() - start
    if os.waitstatus_to_exitcode(status) != 0:
        raise SystemExit(f"{binary.name} exited {os.waitstatus_to_exitcode(status)}")
    peak = rusage.ru_maxrss
    if sys.platform == "darwin":
        peak //= 1024
    return elapsed, peak, b"".join(chunks).decode()


def run_once_nt(binary: pathlib.Path) -> tuple[float, int, str]:
    """Windows has no `wait4`: the peak is the process's peak working set,
    the kernel's own accounting of resident pages, read off its handle
    after it exits and before the handle is closed - in KiB, as Linux's
    `ru_maxrss` is."""
    import ctypes
    from ctypes import wintypes

    class Counters(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                    ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]

    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
    start = time.perf_counter()
    process = subprocess.Popen([str(binary)], stdout=subprocess.PIPE)
    out, _ = process.communicate()
    elapsed = time.perf_counter() - start
    counters = Counters()
    counters.cb = ctypes.sizeof(Counters)
    if not psapi.GetProcessMemoryInfo(int(process._handle), ctypes.byref(counters), counters.cb):
        raise SystemExit(f"{binary.name}: GetProcessMemoryInfo failed ({ctypes.get_last_error()})")
    if process.returncode != 0:
        raise SystemExit(f"{binary.name} exited {process.returncode}")
    return elapsed, counters.PeakWorkingSetSize // 1024, out.decode()


STATS = re.compile(r"stats: collections=(\d+) pause_max_us=(-|\d+) pause_total_us=(\d+)")


def answer_of(output: str) -> str:
    lines = [line for line in output.strip().split("\n") if not line.startswith("stats:")]
    # The address-derived word differs per heap by construction.
    lines = [re.sub(r"(garbage|churn) \d+", r"\1 *", line) for line in lines]
    return "\n".join(lines)


def measure(binary: pathlib.Path) -> dict:
    best = None
    worst_rss = 0
    answer = None
    stats = None
    for _ in range(RUNS):
        elapsed, peak, out = run_once(binary)
        match = STATS.search(out)
        if not match:
            raise SystemExit(f"{binary.name} printed no stats line:\n{out[-400:]}")
        this = {
            "collections": int(match.group(1)),
            "pause_max_us": None if match.group(2) == "-" else int(match.group(2)),
            "pause_total_us": int(match.group(3)),
        }
        if best is None or elapsed < best:
            best = elapsed
            stats = this
        worst_rss = max(worst_rss, peak)
        answer = answer_of(out)
    return {"seconds": best, "rss_mib": worst_rss / 1024.0, "answer": answer, **stats}


def cell(m: dict) -> str:
    pause_max = "-" if m["pause_max_us"] is None else f"{m['pause_max_us'] / 1000.0:.2f}ms"
    return f"{m['seconds']:6.3f}s {m['rss_mib']:6.0f}M {m['collections']:5d}gc {pause_max:>8} {m['pause_total_us'] / 1000.0:7.1f}ms"


def main() -> int:
    check = "--check" in sys.argv
    if not IYI.exists():
        raise SystemExit("build the compiler first: make iyi")
    if shutil.which("go") is None:
        raise SystemExit("go is not on PATH; the race needs the thing it races")

    print("the same program, three collectors: iyi's own, Boehm (Crystal's, -Dgc_boehm), Go's.")
    print(f"per cell: wall (best of {RUNS}), peak RSS (worst of {RUNS}), collections, longest pause, total paused.")
    print()
    print(f"{'':16}" + "".join(f"{arm:>40}" for arm in ARMS))

    lost = []
    with tempfile.TemporaryDirectory() as work_dir:
        work = pathlib.Path(work_dir)
        for name, sources in PROGRAMS.items():
            stem = name.replace(" ", "_")
            iyi_source = work / f"{stem}.iyi"
            iyi_source.write_text(IYI_STATS + sources["iyi"])
            go_dir = work / f"{stem}_go"
            go_dir.mkdir()
            go_source = go_dir / "main.go"
            go_text = sources["go"]
            if "unsafePointer" in go_text:
                go_text = go_text.replace('import (\n\t"fmt"\n\t"runtime"\n)', 'import (\n\t"fmt"\n\t"runtime"\n)\n' + GO_UNSAFE, 1)
            go_source.write_text(go_text)

            results = {}
            build_iyi(iyi_source, work / f"{stem}-iyi", [])
            results["iyi"] = measure(work / f"{stem}-iyi")
            build_iyi(iyi_source, work / f"{stem}-boehm", ["-Dgc_boehm"])
            results["boehm"] = measure(work / f"{stem}-boehm")
            build_go(go_source, work / f"{stem}-go")
            results["go"] = measure(work / f"{stem}-go")

            answers = {results[arm]["answer"] for arm in ARMS}
            if len(answers) != 1:
                print(f"{name:16}  REFUSED: the arms printed different answers")
                for arm in ARMS:
                    print(f"  {arm}: {results[arm]['answer'][:200]!r}")
                return 1
            print(f"{name:16}" + "".join(f"{cell(results[arm]):>40}" for arm in ARMS))

            if check:
                iyi, boehm = results["iyi"], results["boehm"]
                if iyi["seconds"] > boehm["seconds"] * 1.1:
                    lost.append(f"{name}: iyi {iyi['seconds']:.3f}s against Boehm {boehm['seconds']:.3f}s")
                if iyi["pause_total_us"] > boehm["pause_total_us"] * 1.1 and boehm["pause_total_us"] > 0:
                    lost.append(f"{name}: iyi paused {iyi['pause_total_us'] / 1000:.1f}ms against Boehm {boehm['pause_total_us'] / 1000:.1f}ms")

    print()
    if check and lost:
        print("iyi lost to Boehm:")
        for line in lost:
            print("  " + line)
        return 1
    if check:
        print("iyi beats or ties Boehm on every time and pause cell.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
