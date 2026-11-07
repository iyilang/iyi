# Parallelism plan

Status: **agreed direction, not built.** Written on 2026-11-03, after 0.20.0
had made std/http's `serve` answer on every core. It records what iyi does
about running work on many cores from 0.21.0 on, and what it deliberately does
not do. SPEC.md stays the description of what is built; a part of this plan
moves there, marked PROPOSED and then done, as it lands.

## The decision: not Go's model

Go runs every goroutine on any thread and leaves data races to the program and
to a race detector that runs only under test, slowly. The mental model is
simple and the cost is real: a race is found at run time if at all, and one
collector walks one shared heap.

iyi already knows something Go does not. The compiler proves which values may
cross threads (`Share`, III.4.13), refuses a parallel task's capture that is
not, and walks what a block reaches through calls (`SafeReach`). Copying Go
would throw that proof away. The plan keeps it and builds on it: Go's
ergonomics, the safety Swift 6 and Rust check at compile time, and the
latency Erlang gets from isolated heaps.

## Four layers

### 1. Parallel by default, wherever the compiler can prove it safe (0.21)

Every task lives in an isolation domain, which iyi already has under the name
*unit*: units run in parallel with each other, the tasks of one unit one at a
time. A plain `spawn` whose captures are all `Share`, and whose reach finds no
unannotated module state, starts a unit of its own on the worker pool, so it
runs in parallel with no new keyword. Any other `spawn` stays in its spawner's
unit exactly as today, so nothing that compiles now breaks or changes meaning
for its non-`Share` data.

This is Swift 6's isolation model without its annotation load: the domains are
inferred, not declared. The price of inference is that one capture can flip a
`spawn` to serial from a distance, so the compiler says so where the author
looks (SPEC.md III.4.16): `iyi check` notes each spawn kept in its unit with
the capture, field and module that kept it there, the language server hints
it, and a rebuild that moves a library's spawn prints one line naming it. No
new warning, so `--error-on-warnings` builds keep building.

What changes for an eligible `spawn` is ordering, not memory safety: today a
child does not run until its spawner parks, and once eligible it may start at
once on another core. One verb carries both answers: `g.spawn(unit: :same)`
keeps the old ordering for one spawn and `g.spawn(unit: :new)` asks for
the pool; `spawn_serial` and `spawn_parallel` are gone (III.4.16).

Measured starting point (master decc9f1fb): `spawn` appears at 27 sites in
src/std, 14 in iyi-db, 18 in iyi-pg and 467 in bench/. Every one is audited
for an ordering assumption before the default changes.

Being built on branch `mt/spawn`.

### 2. Structured concurrency: already the only kind (BUILT)

Go's most costly gap is the goroutine that belongs to nothing: it leaks, it
cannot be cancelled, and its error goes nowhere. iyi has had no such task
since III.4.1: there is no bare spawn, a task is started inside an
`IyiGroup` whose block cannot be left until every task in it has finished,
cancellation flows down and errors flow up as values. Nothing is left to
build in this layer; it is listed so the plan reads whole.

### 3. Data parallelism as a library (0.21)

Most of the speed a program gets from more cores comes from a loop, not from
`spawn`. `each_parallel` and `map_parallel` over `Share` inputs, split into
chunks across the pool the way Rust's Rayon does, give that without the
program thinking about tasks or threads.

Being built on branch `mt/datapar`, its API written into SPEC.md as
III.4.14, PROPOSED.

### 4. A heap per unit (0.23 or later, research first)

This is the layer that can beat Go rather than match it. A value that is not
`Share` never leaves its unit, and the compiler already proves it. So each
unit can own its heap and collect it alone, with no stop of any other thread,
which is where Erlang's tail latency comes from; only `Share` values live in a
shared heap that needs a global collection.

It aims at iyi's two measured weaknesses against Go, both rooted in
collecting one shared heap. On Windows 11 with 12 logical processors, issue
#145's real app on master 1ae9e94db answers 1.08 times its Go port at the
geometric mean of 11 GET endpoints, but its p99 on the heavy endpoints is 246
to 352 ms against Go's 152 to 260, and its peak working set 430 MB against
139 (CHANGELOG.md, 0.20.0, Known). Go cannot take this route: its type
system does not know which values stay put.

Risks, named now: it is a redesign of the collector and allocator, and every
hole in the `Share` proof becomes a hole in the heap split. `@[SafeReach]`
is proven now (SPEC.md III.4.4); `Pointer`, and `@[UnsafeReach]`, kept for
src/iyi and for files that use `Pointer`, still let a program claim what
the compiler did not check, and need a rule before this starts. It begins
as a prototype that is measured, and is kept or dropped on the numbers.

## Deliberately not done

- Unchecked shared memory, Go's way.
- Coloured async functions. iyi's tasks are fibers, so a function does not
  have to say it may wait, and that stays true.
- Marking everything by hand, as Swift 6 asks.

## Order of work

| release | content |
|---|---|
| 0.21 | parallel-by-default `spawn` (layer 1); `each_parallel` / `map_parallel` (layer 3); the runtime work below. Structured groups (layer 2) are already the only kind (III.4.1) |
| 0.22 | a seeded, reproducible chaos scheduler in `iyi test` for logical races. The compiler already rules out memory races; what is left is ordering, and a deterministic schedule fuzzer finds it more surely than a race detector does |
| 0.23+ | a heap per unit (layer 4), prototype first and decided by measurement |

The runtime work that 0.21 rests on, begun on 2026-11-03 as slices of branch
`mt/next`: a lock per channel instead of the one scheduler lock (`mt/chan`),
collection pauses (`mt/debt`), wake-up latency (`mt/wake`), mark helpers when
pool workers idle (`mt/markhelp`), the working set (`mt/wset`), and darwin's
spin (`mt/dspin`). When everything that can be parallel is, those are where it
would bottleneck first.
