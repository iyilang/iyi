# What it costs, measured

The build-time, run-time and server measurements behind [README.md](README.md). Every
figure names the script that prints it; `python3 bench/machine_probe.py`
prints your machine beside three reference timings, so a figure taken
elsewhere can be compared with yours. SPEC.md has the design each one tests.

## The edit loop

One script writes the same program three times, in iyi, in Crystal and in Go:
**30 modules**, 10 types each, **7,207 lines**, and one `main` that calls all
thirty and prints the total. The benchmark changes a single number in one
function of one module, then rebuilds. One of the thirty, as iyi, with nine of
its ten types left out:

```crystal
module parts/mod0

pub struct Widget0
  @a : Int32
  @b : Int32

  def initialize(@a : Int32, @b : Int32)
  end

  def score : Int32
    ((@a * 3) + (@b * 5)) % 1000
  end

  def blend(other : Widget0) : Int32
    (score + other.score) % 1000
  end
end

pub def total0 : Int32
  edit_point = 0            # the line the benchmark changes, then rebuilds
  w0 = Widget0.new(0, 0)
  (edit_point + w0.score + w0.blend(w0)) % 100000
end
```

`python3 bench/incremental.py`, best of 7, release compiler, one idle Linux
box (AMD Ryzen AI 9 465 under WSL2, LLVM 19.1.7, Go 1.25.2), seconds:

| what changed | iyi | Crystal | `go build` |
|---|---|---|---|
| **one module's body** | **0.13** | 1.17 | 0.16 |
| the entry file only | **0.12** | 1.15 | 0.16 |
| nothing cached anywhere | 0.61 | 1.97 | 3.09 |
| the same edit, *without* artifacts | 0.23 | — | — |

The last row is what R-1 is worth on this project: with all thirty modules
read from source the edit costs 0.23 s; with the `.iyimod` files in hand the
other twenty-nine arrive as declarations and it costs 0.13 s. `go build` from
nothing also compiles its own dependencies once, so its 3.09 s is a first
build on a fresh machine rather than a claim about Go's compiler. Seconds are
a machine, not a language: other sessions on the same box read 0.16 / 1.29 /
0.19 and 0.22 / 1.81 / 0.27 on the first row. The ratios hold.

A build with nothing changed is not in the table, because `iyi build` no
longer compiles one: it reads back what the last build read, finds it all as
it was, and says `out is up to date` (`--force` builds anyway). On the
machine SPEC.md IV.3a measures that on, it takes 0.01 s, against
`go build`'s 0.04 s.

## The full build

The full build is the row iyi loses. `python3 bench/build_speed.py`, same
session:

| program | iyi | `go build` |
|---|---|---|
| `hello` (149 lines) | **0.07 s** | 0.08 s |
| generated pair, 6,912 lines | 0.24 s | **0.09 s** |

<sup>Both counts are `wc -l`: 149 for `samples/iyi/hello.iyi`, of which 44 are
code and the rest the commentary that makes it a sample, and 6,912 for what
`python3 bench/build_speed/generate_pair.py 300 <dir>` writes. The Go side of
each row is 11 lines and 6,016.</sup>

Compiling code it has never seen costs roughly 25 ms per thousand lines. The
front end alone is 0.034 s for `hello`, and 0.018 s of that is the process
starting up before it reads anything.

## Run time

`python3 bench/runtime.py` runs the same program under iyi's own library and
under Crystal's (under 1.00 is iyi ahead):

| workload | as it runs | with the collector off |
|---|---|---|
| arithmetic | 0.97x | 0.97x |
| array append and read | 0.74x | 0.78x |
| hash insert and read | 0.10x | 0.10x |
| string building | 1.23x | **1.80x** |

Where the two libraries do the same work they are within noise. `Hash` is
ahead on sequential integer keys, which flatter a compact table, and keeps
insertion order as Crystal's does. `String` building is slower, and the
collector masks part of that.

`python3 bench/gc_race.py` runs three programs written in iyi and in Go, under
iyi's collector, Boehm and Go's; [GC_DESIGN.md](GC_DESIGN.md) records the
machine and every figure.

## AES-GCM in a browser

The SIMD path processes eight AES counter blocks at once; WebCrypto still
leads it. `ctr` and `ghash` are iyi-only component measurements.

Apple M5 Max, 128 GiB memory, HeadlessChrome/156.0.8078.4, Node
v26.7.0, wasi-sdk 24. The programs target `wasm32-unknown-unknown` with
`--release`; the second also uses `--mattr +simd128`. AES-256-GCM uses a
12-byte nonce, 25 bytes of additional data and a 16-byte tag. Numbers are
decimal MB/s: best of five followed by the full [minimum, maximum] range.
Setup and output comparisons are outside the timed calls. Every timed seal,
open and CTR result was compared byte by byte with WebCrypto; the two GHASH
outputs matched each other. All three implementations refused a flipped tag.

```sh
PATH=/opt/homebrew/bin:/usr/bin:/bin \
LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib \
WASI_SDK_PATH="$TMPDIR/iyi-spike/sdk" \
IYI_CHROME="$HOME/Library/Caches/ms-playwright/chromium_headless_shell-1248/chrome-headless-shell-mac-arm64/chrome-headless-shell" \
bash bench/wasm_aead_speed.sh
```

| MiB | Operation | iyi scalar | iyi SIMD128 | WebCrypto |
|---:|---|---:|---:|---:|
| 1 | open | 201.6 [197.8, 201.6] | 262.1 [243.9, 262.1] | 5242.9 [2621.4, 5242.9] |
| 1 | seal | 205.6 [194.2, 205.6] | 262.1 [187.2, 262.1] | 3495.3 [2621.4, 3495.3] |
| 1 | ctr | 262.1 [243.9, 262.1] | 419.4 [388.4, 419.4] | n/a |
| 1 | ghash | 1165.1 [953.3, 1165.1] | 806.6 [749.0, 806.6] | n/a |
| 16 | open | 204.4 [194.9, 204.4] | 256.9 [244.6, 256.9] | 3289.7 [2892.6, 3289.7] |
| 16 | seal | 203.4 [198.8, 203.4] | 262.6 [246.7, 262.6] | 2943.4 [2621.4, 2943.4] |
| 16 | ctr | 256.1 [245.3, 256.1] | 405.2 [388.4, 405.2] | n/a |
| 16 | ghash | 1023.0 [981.1, 1023.0] | 795.1 [759.2, 795.1] | n/a |
| 64 | open | 203.0 [190.8, 203.0] | 266.4 [256.6, 266.4] | 3423.9 [3036.6, 3423.9] |
| 64 | seal | 201.5 [196.7, 201.5] | 267.9 [187.2, 267.9] | 3322.2 [2982.6, 3322.2] |
| 64 | ctr | 259.5 [251.5, 259.5] | 402.8 [383.0, 402.8] | n/a |
| 64 | ghash | 1032.4 [1027.7, 1032.4] | 803.7 [776.7, 803.7] | n/a |

At 16 and 64 MiB open, SIMD is 1.26x and 1.31x scalar; WebCrypto is 12.8x
and 12.9x SIMD. SPEC.md III.12.1 records the earlier baseline's unit correction,
the slower SIMD GHASH trial and the constant-time inspection.

## A web server's cores (issue #145)

Issue #145 ported a web API to iyi and found it never used more than 1.8
of twelve cores, while its Go port used 11. `Server.serve` now answers
connections on a pool of workers, one per core unless `workers:` says
otherwise. The table below compares it with `workers: 1` and a Go twin
that answers the same bytes. It covers the issue's kinds of endpoint,
without the issue's database: a bcrypt login, a `check_version` that
answers a few fields of JSON, and an `order` that reads, totals and
sorts sixteen items of JSON.

It was taken with `bench/web_cores.py`: wrk with 4 threads and 32
kept-alive connections, bcrypt at cost 10, `serve` on 1, 2, 4,
8 and 12 workers, best of 3 runs of 15 s (login) and 5 s (the others).
The machine was Linux on a twelve-thread VM, with other work keeping
about 2 of its cores busy. Each cell is requests a second over HTTP, with
the server's CPU in brackets:

| | login | check_version | order |
|---|---:|---:|---:|
| iyi `serve`, `workers: 1` | 27 (100%) | 46,241 (112%) | 33,665 (113%) |
| iyi `serve`, 12 workers | **247** (1,032%) | 205,879 (631%) | **131,160** (697%) |
| Go net/http | 242 (1,033%) | **216,298** (528%) | 90,732 (538%) |
| *the issue's iyi: Windows, with a database* | *9.9* | *5,308* | |
| *the issue's Go: Windows, with a database* | *108.2* | *21,099* | |

The italic rows are the issue's own figures, on another machine and with a
database behind every request; they show the gap that was reported, not a
measurement comparable with the rows above.

The login is now as fast as Go's: bcrypt takes the same CPU per hash in
both, and the gap was the number of cores in use. Past four workers, the
light endpoints are held back by the load generator and, when this table was
taken, also by the collector's allocation lock; that lock has since been
split by size class. SPEC.md III.4.13 has every worker count, HTTPS, the
latencies, the profile behind both claims, and the split measured again.
