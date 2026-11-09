# Parallelism plan

Status: **layers 1, 2 and 3 BUILT, with the chaos scheduler, on `mt/next`
for 0.21.0; layer 4 not started.** Written on 2026-11-03, after 0.20.0
had made std/http's `serve` answer on every core. It records what iyi does
about running work on many cores from 0.21.0 on, and what it deliberately does
not do. SPEC.md stays the description of what is built; a part of this plan
moved there, marked PROPOSED and then BUILT, as it landed.

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

### 1. Parallel by default, wherever the compiler can prove it safe (BUILT in 0.21)

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
src/std, 14 in iyi-db, 18 in iyi-pg and 467 in bench/. Every one was audited
for an ordering assumption before the default changed (SPEC.md III.4.15
part 8): of the spawns bench/ and samples/ reach, 125 locations run in
parallel, 289 stay in their spawner's unit and 6 differ by instantiation;
all 12 of std's stay in their unit. The gate steps that depended on a
unit's order spawn with `g.spawn(unit: :same)`.

BUILT: SPEC.md III.4.15 (placement, `--explain-spawn`, the inlay hint, a
pool that grows to the work), III.4.16 (one verb, the notes) and III.4.18
(units named, `Unit(T)`), held by `bench/spawn_eligible.sh` and
`bench/spawn_fuzz.sh`. `bench/spawn_fanout.iyi`, 64 plain spawns hashing
31 MiB, runs in 99 ms on one worker and 12 ms on twelve on Linux (12
vCPUs), 158 and 20 ms on ten on macOS 26.6 (Apple M2 Pro, 10 cores), and
95 and 10 ms on twelve on Windows 11 (12 logical processors), the last two
the user's machines; before, the same source ran on one thread whatever
the count.

### 2. Structured concurrency: already the only kind (BUILT)

Go's most costly gap is the goroutine that belongs to nothing: it leaks, it
cannot be cancelled, and its error goes nowhere. iyi has had no such task
since III.4.1: there is no bare spawn, a task is started inside an
`IyiGroup` whose block cannot be left until every task in it has finished,
cancellation flows down and errors flow up as values. Nothing is left to
build in this layer; it is listed so the plan reads whole.

### 3. Data parallelism as a library (BUILT in 0.21)

Most of the speed a program gets from more cores comes from a loop, not from
`spawn`. `each_parallel` and `map_parallel` over `Share` inputs, split into
chunks across the pool the way Rust's Rayon does, give that without the
program thinking about tasks or threads.

BUILT: SPEC.md III.4.14, `std/parallel`'s `each_parallel`, `map_parallel`,
`sum_parallel` and `reduce_parallel` on a `List`, an `Array` and an
integer range, held by `bench/std_parallel_exercise.sh`. Ten workers ran
two CPU-bound sums, SHA-256 of 20,000 strings and a string transform 6.4
to 7.4 times faster than one thread on macOS 26.6 (Apple M2 Pro, 10
cores); twelve ran the sums and SHA-256 6.4 to 7.9 times faster on
Windows 11 (12 logical processors), and the transform, which allocates,
3.8 times (both the user's machines). What is not built - a cutoff for
small inputs, `Slice`, `Deque`, `Hash` and `Set`, a parallel `find` and
its kin - is listed under III.4.14's Open.

### 4. A heap per unit (0.23 or later, research first)

This is the layer that can beat Go rather than match it. A value that is not
`Share` never leaves its unit, and the compiler already proves it. So each
unit can own its heap and collect it alone, with no stop of any other thread,
which is where Erlang's tail latency comes from; only `Share` values live in a
shared heap that needs a global collection.

It aims at iyi's two measured weaknesses against Go, both rooted in
collecting one shared heap. On Windows 11 with 12 logical processors (the
user's machine), issue #145's real app with mt/next's collector answers
608.5 requests a second against its Go port's 564.7 at the geometric mean
of the best of 11 GET endpoints, 1.08 times, but its p99 there is 159.7 ms
against Go's 102.2, and its peak working set 220 MB against 129 (3
interleaved rounds; CHANGELOG.md, Unreleased, "Idle threads no longer
raise the collection budget's floor"). Master decc9f1fb read 605.3, 171.0
ms and 493 MB in the same rounds. Go cannot take this route: its type
system does not know which values stay put.

Risks, named now: it is a redesign of the collector and allocator, and every
hole in the `Share` proof becomes a hole in the heap split. `@[SafeReach]`
is proven now (SPEC.md III.4.4), and III.13 is the rule `Pointer` needed:
a `Pointer`-typed value, `uninitialized`, a `lib` or `fun`, `asm`,
`@[Primitive]` and the trust marks are refused in every module not marked
`@[Unsafe("why")]`. `@[UnsafeReach]` still exists, as the claim taken on
trust, and only in such a module; in this tree it is on one class
variable each in `bench/arena_exercise.iyi` and `bench/thread_exercise.iyi`
and nowhere in src/. So the holes are named rather than gone: a marked
module - src/iyi's 13 marked files, src/std's 83 marked modules - and the
`@[UnsafeReach]`, `@[Share]` and `@[Share(owns: true)]` claims inside one
are where the heap split cannot lean on the proof and needs its own
answer before this starts. It begins as a prototype that is measured, and
is kept or dropped on the numbers.

## Deliberately not done

- Unchecked shared memory, Go's way.
- Coloured async functions. iyi's tasks are fibers, so a function does not
  have to say it may wait, and that stays true.
- Marking everything by hand, as Swift 6 asks.

## Order of work

| release | content | status |
|---|---|---|
| 0.21 | parallel-by-default `spawn` (layer 1); `each_parallel` / `map_parallel` (layer 3); the runtime work below. Structured groups (layer 2) are already the only kind (III.4.1) | BUILT on `mt/next` |
| 0.21 | a seeded, reproducible chaos scheduler in `iyi test` for logical races (SPEC.md III.4.17, `iyi test --chaos[=SEED] [--chaos-runs N]`). The compiler already rules out memory races; what is left is ordering, and a deterministic schedule fuzzer finds it more surely than a race detector does. Planned for 0.22, it landed in 0.21 | BUILT on `mt/next` |
| 0.23+ | a heap per unit (layer 4), prototype first and decided by measurement | not started |

The runtime work that 0.21 rests on, begun on 2026-11-03 as slices of branch
`mt/next`, all merged into it, each with its CHANGELOG.md Unreleased entry:
a lock per channel instead of the one scheduler lock (`mt/chan`, "Each
channel has a lock of its own"), collection pauses (`mt/debt`, "A
collection no longer waits for the threads it releases to run again"),
wake-up latency (`mt/wake`, "A task handed over by a task that computes
on starts on an idle worker" and "A fiber left in the ring of a worker
held a whole tick is stolen"), mark helpers when pool workers idle
(`mt/markhelp`, "On Windows a mark beside the program counts a waiting
worker's core free"), the working set (`mt/wset`, "A collection has a
ceiling" and "Idle threads no longer raise the collection budget's
floor"), and darwin's spin (`mt/dspin`, "darwin's spinners give their
core away"). When everything that can be parallel is, those are where it
would bottleneck first.
