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
