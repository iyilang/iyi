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
Setup and output comparisons are outside the timed calls. Every timed result
was compared byte by byte with WebCrypto, and all three refused a flipped tag.

```sh
PATH=/opt/homebrew/bin:/usr/bin:/bin \
LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib \
WASI_SDK_PATH="$TMPDIR/iyi-spike/sdk" \
IYI_CHROME="$HOME/Library/Caches/ms-playwright/chromium_headless_shell-1248/chrome-headless-shell-mac-arm64/chrome-headless-shell" \
bash bench/wasm_aead_speed.sh
```

| MiB | Operation | iyi scalar | iyi SIMD128 | WebCrypto |
|---:|---|---:|---:|---:|
| 1 | open | 205.6 [184.0, 205.6] | 243.9 [238.3, 243.9] | 3495.3 [2621.4, 3495.3] |
| 1 | seal | 197.8 [187.2, 197.8] | 243.9 [228.0, 243.9] | 3495.3 [2097.2, 3495.3] |
| 1 | ctr | 243.9 [218.5, 243.9] | 374.5 [361.6, 374.5] | n/a |
| 1 | ghash | 953.3 [806.6, 953.3] | 806.6 [699.1, 806.6] | n/a |
| 16 | open | 189.4 [185.6, 189.4] | 243.9 [241.4, 243.9] | 2995.9 [2750.4, 2995.9] |
| 16 | seal | 196.2 [183.8, 196.2] | 254.6 [237.6, 254.6] | 2843.6 [2750.4, 2843.6] |
| 16 | ctr | 246.7 [227.3, 246.7] | 374.5 [367.1, 374.5] | n/a |
| 16 | ghash | 998.6 [937.3, 998.6] | 773.1 [742.4, 773.1] | n/a |
| 64 | open | 193.6 [185.6, 193.6] | 250.8 [243.4, 250.8] | 3106.9 [2784.6, 3106.9] |
| 64 | seal | 190.1 [181.2, 190.1] | 251.9 [234.2, 251.9] | 2905.1 [2494.8, 2905.1] |
| 64 | ctr | 239.0 [234.6, 239.0] | 382.8 [368.3, 382.8] | n/a |
| 64 | ghash | 994.2 [933.4, 994.2] | 796.1 [748.1, 796.1] | n/a |

At 16 and 64 MiB open, SIMD is about 1.29x scalar and WebCrypto is 12.3x
and 12.4x SIMD. SPEC.md III.12.1 records the earlier baseline's unit correction,
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
