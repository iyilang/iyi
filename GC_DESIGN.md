# iyi Garbage Collector Design

**Status:** Stages 1 to 7 and 9 built, and **the collector is the
default allocator on POSIX**: a plain build allocates from the arena,
collects under its own allocation-pressure trigger, and hands memory back.
The flip followed the measurement below. `-Dgc_none` opts out to the bump
pointer, `-Dgc_boehm` to libgc. Stage 4 is the stop-the-world over kernel
threads the runtime has (`src/iyi/thread.iyi`, the section below); Stage 7
is the parallel marker on helper threads; Stage 9 is the mark beside the
program, on the compiler's write barrier, with two stops of tens of
microseconds where the mark was one stop of milliseconds (the section
after Stage 4's). The heap's footprint follows the live set: a one-word
header, size classes eight bytes apart, pages handed back to the kernel
by the sweep and taken up again by the carve, and Go's two answers to
a mutator outrunning the mark - allocate black, and assist (the section
after Stage 9's). Stage 8 is the sweep beside the program: in slices,
by the helpers after every collection and by an allocating thread only
for the slice it needs (the section after the footprint's). Stage 10
is design.

Stage 6: the sweep. One walk over every carved chunk, a white object's chunk
goes back on its class's free list, a black one survives and is repainted white
for the next cycle. Large objects walk their own list with `next` read before
the node is released. The proof is reuse rather than a counter: 300 objects
nothing references, collect, 300 more allocations, and 299 of them come back
from addresses the sweep reclaimed. A rooted object keeps every byte, comes out
white, and its chunk is not handed out again.

Finalizers and weak references are not built, and not for lack of time.
Nothing in this language defines a finalizer, there is no `def finalize`
anywhere in `src/iyi` or `samples/iyi`, so a finalizer queue would be a
mechanism no program could put an entry in. Weak references are registration
based and the standard library's `WeakRef` is on the `--crystal` side, so there
is no table here to walk and null out. Both wait on the language having the
feature. Statistics are the honest subset, counted as the walk goes: chunks
swept, chunks kept, bytes freed, collections run.

Stage 5: the mark phase. Roots go gray through Stage 3's walker, a queue in its
own mapping drains, each object's payload is scanned to the bound its size
header carries, and what is still white when the queue empties is unreachable.
The object header is real now, and it is one word: with `P` the pointer a
program holds, `P-8` is the mark word - colour, flags, and the `type_id`
in its high half - and `P` the user data. The size is the chunk's, which
the arena knows (the section on the heap's footprint, below, says what
the three-word header it replaced cost).

Marking is **precise for typed objects and conservative for the rest**.
Codegen stores the `type_id` into the header at the allocation site
(`allocate_aggregate`), the mark loop binary-searches the embedded layout
table (`__iyi_gc_layouts`) and scans exactly the offsets the `TypeLayout`
names, so an integer field holding an address retains nothing through a
typed object. A zero id — a `Pointer(T).malloc` buffer, a closure
environment — and an id the table does not carry both word-scan
conservatively, which is what Boehm does in production and errs in the
safe direction: a false positive retains a dead object, only a false
negative frees a live one. `bench/mark_exercise.sh` proves the precision
differentially and proves the check fails when the lookup is disabled.

Stage 6 sweeps what this stage decided, and the collector runs *itself*: an
allocation-pressure trigger in the allocator's one funnel runs a collection
when the bytes allocated since the last one cross the budget, and the budget
after each collection is twice what survived it, floored at a MiB — churn
against a small live set collects often, against a big one rarely, and a
program under a MiB never pays. `bench/collect_trigger.sh` proves it with
nobody calling `collect`: the heap stays bounded, a rooted survivor and a
parked fiber's only reference both live through triggered collections, and
the checks fail when the trigger or the budget growth is removed. The
trigger's steady state is also what turned the freed-chunk check into the
mark word's FREE flag: the free-list walk this design called "fine until a
profile asks" made every sweep quadratic the day one did, 106 seconds of
exercise against 0.1 after the flag.

The heap breathes in both directions now. A sweep that finds an arena with
no live chunk hands the whole mapping back to the kernel — the class's
free list stripped first, the arena unlinked from the heap's own walk,
then the `munmap` — with one warm arena per class kept as the cushion
that spares a spike-then-idle program the mmap on its next allocation.
And the pauses have numbers rather than adjectives: a collection times
itself on the kernel's own monotonic clock (a raw syscall on Linux into a
page of the collector's own, libSystem's `clock_gettime_nsec_np` on
darwin), and `last`/`max`/`total` ride the statistics.
`bench/collect_trigger.sh` holds both: a 64 MiB spike's arenas go back
when the root drops — the check fails by name when the scavenge is
disabled — and the pause line is printed from a real run, reported
rather than asserted because a budget would be a number the gate made
up.

The default-allocator question now has its measurement (`bench/gc_default.py`,
release builds, best of five, worst peak RSS of the same five). The columns
are the arms that script passes *today*: the flip below renamed both of the
first two — what was `default` when this was measured is `-Dgc_none` now, and
what was `-Dgc_iyi` is the default — so the header said, for a while, to run
a flag the script no longer has:

| workload | default (the collector) | `-Dgc_none` (the bump pointer) | `-Dgc_boehm` |
|---|---|---|---|
| arithmetic (no allocation) | 0.039 s / 15 MiB | 0.038 s / 15 MiB | 0.046 s / 15 MiB |
| live set (8M-element array) | 0.017 s / 84 MiB | 0.018 s / 66 MiB | 0.018 s / 74 MiB |
| churn (512 MiB, ~64 B live) | **0.048 s / 15 MiB** | 0.125 s / 551 MiB | 0.091 s / 15 MiB |
| string churn (40k rebuilds) | **0.218 s / 34 MiB** | 0.387 s / 767 MiB | 0.257 s / 15 MiB |

The owned collector wins or ties every time column and holds RSS at the live
set where the bump pointer holds it at the garbage. The first reading was not
this one: the live-set row started at 0.187 s, ten times the bump pointer,
and the cause was the header having no way to say *atomic* — a 32 MiB
`Array(Int32)` buffer was word-scanned at every triggered collection.
`ATOMIC_FLAG` (mark-word bit 3, set where `clear` is false, carried across
`realloc`) is the fix, and it is Boehm's own contract: `GC_malloc_atomic`
memory is never opened. **The flip followed:** with the table above as the
evidence and every stage gated, the default moved to the collector, and
the doors out are `-Dgc_none` and `-Dgc_boehm`. The selection lives in two
places that must agree — the prelude's allocator seam and
`Program#iyi_gc_arena?` in the compiler — and both name each other.

Stage 1: the artifact carries a pointer map per type it owns (`.iyimod` format
v43, `Layouts` section 64), and the object header and its CAS-safe mark word
exist and are tested as a unit. Stage 1's own tasks 3 and 4, work distribution
and write barriers, are design here and deferred to Stage 6 by their own text;
they were not built.

Stage 2: a size-class arena allocator — the default's, since the flip — on
Linux x86_64 and aarch64 and on darwin. Size classes to 16 KiB, 16 MiB
arenas, free lists, large objects by their own mapping and released with
`munmap`, and the two properties Stage 3 needs: a pointer resolves to its
arena and class, and the arena list walks. On Linux it costs no symbol and
no library — mmap and munmap are raw syscalls — and on darwin it costs
libSystem's `mmap`/`munmap`, named in the floor's list with the flip as
the reason.

What it does not do yet: Windows and wasm32 keep their existing
allocators — the first's memory diagnosis (the prelude memset's stride)
retired after thirty-six clean builds of CI's twenty-run watch, which is a
gate now; the second has no mmap and its watermark arena is a separate
design.
Threads, and with them Stages 4, 7, 8 and 9, were waiting when this was
written; the sections after the next one are their account.

## What the staging above got wrong, and what the rebase onto 0.6.0 corrected

This plan was written assuming iyi has threads and fibers, and when the first
three stages were built it had neither. That half inverted while the work was
in flight: 0.4.0 shipped structured concurrency — a cooperative scheduler,
`spawn`/`group`, `Channel`, 256 KiB mmap'd fiber stacks in
`src/iyi/concurrency.iyi`. Threads are still absent, and III.9's reason
stands.

What that does to the stages, restated against the tree as it is:

* **Stage 3's fiber enumeration is closed.** The scheduler keeps an
  all-fibers registry — its wait queues could not serve the walk, since a
  channel-parked fiber lives in the channel's own nodes — and
  `each_fiber_root` scans every suspended fiber from its saved stack
  pointer to its stack top; the running stack's own scan caps at the
  current fiber's top rather than the thread base, because the gap
  between the two mappings is unmapped. `bench/root_exercise.sh` holds
  it both ways: an address held only on a suspended fiber's stack is
  found, and a prelude with the fiber walk removed exits 1 at that
  check's own name.
* **Stage 4's thread suspension is built**, because there are threads to
  suspend: `IyiThread.start` is a kernel thread in the runtime, a
  collection takes the runtime lock and stops every other thread by
  signal, each stopped thread's registers and stack are roots, and
  `bench/thread_exercise.sh` holds it — the section "Threads in the
  runtime, and the stop" below is the account. Register capture, the
  part that was real with one thread, had moved into Stage 3; the
  stopped threads' capture is the same spill, written by the handler.
* **Stages 7 and 8**, parallel marking and concurrent sweeping, are the
  reason the owner chose to own a collector, and they wait on nothing
  now: the threads exist, the mark word is CAS-safe on the prelude's own
  `Atomic`, and the header already reserves its bits. The thread
  exercise's price table is their case — eight threads idle through
  every pause a single thread sweeps.
* **Stage 9** is conditional on measuring Stage 7.

This is worth stating plainly rather than leaving the plan to read as ten
achievable steps: the collector can reach a working single-fiber
mark-and-sweep today, a fiber-aware one after Stage 3's registry walk, and
the parallelism the decision was made for arrives after threads do.

So the point of no return, Stage 5, is still ahead.

**What a thread costs is now measured, before the design that needs one
is written** (`bench/thread_floor.iyi`, driven by `bench/thread_floor.sh`,
in CI beside the dependency floor with its aarch64 arm under emulation).
III.9's fear was exact: a scheduler that reached for pthreads would put
libc back on the link line. So the probe reaches for the kernel instead —
`clone` with the thread flags onto a stack of the program's own mapping,
the child's whole life inside the asm, `futex` on the tid word the kernel
clears at exit for the join — and the binary keeps the floor: the five
C-template names and nothing else, plain and release, and the aarch64
object is as empty as any sample's. The stop-the-world is the same
probe: `rt_sigaction` with the kernel's own four-word struct (a
two-instruction `rt_sigreturn` restorer on x86_64, the vdso's on aarch64),
`tgkill` to every thread, a handler that counts itself in, parks on a
futex, and counts itself out on one wake. That is Stage 4's mechanism
entire, and the part between the two counts is in the probe now too:
the handler reads the interrupted thread's sp and pc out of the
`ucontext` — the kernel's on Linux, at 160/168 on x86_64 and 432/440
on aarch64 past the 128-byte sigmask; libSystem's on darwin, through
the mcontext pointer at 48 to sp at 264 and pc at 272 — and asserts
the sp is on that thread's own stack, because a context that is not
the thread's would scan the wrong stack and root nothing; the driver's
third failure proof moves one offset by a word and every handler says
so. Stage 3's register capture, generalised to the thread that did
not ask. The handler also records how far below the interrupted sp it
ran, and that number is a design input: 5.7 KB on x86_64 Linux and 4.7
KB on aarch64 Linux (the kernel's frame carries the vector state), 1.2
KB on darwin. A signal lands on whatever stack the thread is on, and a
scheduler thread is on a fiber's 256 KiB mapping most of the time, so
Stage 4 either keeps 8 KB above every fiber stack's guard page spare
for the frame or gives each scheduler thread a `sigaltstack` — one
more name on darwin, a syscall on Linux — and the number says the
first is affordable.

The numbers, release build, 20 cores, 200 rounds, threads spinning the
whole time (the case a stop has to handle; a parked thread is the easy
one): stop 1 thread best 2.1 µs / mean 2.3 µs; 4 threads 5.0 / 5.9 µs; 8
threads 8.2 / 11.5 µs; 16 threads 22 / 31 µs; 64 threads 84 / 139 µs
with a 0.6 ms worst. Resume: 0.6 / 0.8 µs for 1 thread, 2.9 / 4.0 µs
for 4, 4.3 / 36 µs for 8, 11 µs best but 0.42 ms mean for 16, and 6.4
ms best / 11.9 ms mean for 64. The shape is the finding. Below the core
count the pause is a signal per thread, roughly a microsecond each. Past
it the stop stays bounded, because a handler that parks gives its core
up and the next signalled thread runs its handler on it at once; the
resume is the timeslice, because every woken thread goes straight back
to spinning and the last one to count itself out waits for the kernel's
scheduler to reach it — the same shape darwin's section below reads off
XNU's quantum. (A first reading put the milliseconds on the stop and
called the resume one wake: the release probe's `xchg` store had
clobbered the register its counters were zeroed from, so no thread
parked; CHANGELOG.md's Fixed entry has the instruction.) Two decisions
follow for Stages 4 and 7: marking workers never exceed the core count,
and the mutator side is M:N with M bounded the same way, or a resume is
milliseconds by construction.

The first run had no thread pointer at all — no `CLONE_SETTLS` — and the
child still ran compiled iyi code (a `fun`, atomics by inline asm,
syscalls), so the compiler emits nothing thread-relative for a body that
neither allocates nor raises. That located the real first cost of
threads, which is not the thread: `IyiScheduler.current`, the poller fd,
the arena's free lists and the collector's own state are all class
variables today, one thread's globals. The second run answered where
per-thread state can live, and it is the language's own
`@[ThreadLocal]`, on the floor. The compiler now emits such a variable
local-exec outright — one `%fs:`-relative or `tpidr_el0`-relative load at
a link-time offset, inside the `noinline` address accessor the compiler
keeps for every thread-local so a fiber that changes threads never
reads a cached address — because a program iyi links is always an
executable; the general-dynamic default was relaxed to the same
instructions by the linker but left `__tls_get_addr` undefined in the
dynamic symbol table, a name the floor counts for a call never made,
and that name is gone. The probe lays out each thread's block the way a
static libc's startup does: PT_TLS found by walking the program headers
from `__ehdr_start`, the initialised image copied, the rest zero, the
pointer placed by the ABI's variant (below the block with a self-pointer
at `%fs:0` on x86_64, above a 16-byte control block on aarch64) and
handed to `clone`. Every thread then saw the image's initialiser in its
own copy and its own tid in its own slot for the whole run, the main
thread's slot survived them all, and dropping the one flag bit — the
driver's failure proof — makes every thread share the main thread's
block and the program name the clash. So a thread-local class variable
is the mechanism, and the runtime's cutover is a spelling — but not the
one this paragraph first wrote. Every scheduler field its own
`@[ThreadLocal]` costs a `noinline` accessor call per field per entry
(the touch line above: three times a class variable's), and it puts the
run queue's head in a TLS block the root walk cannot see. **The
scheduler is cut over now, the other way:** every field lives on one
`IyiSchedulerState` — the running fiber, the run queue, the sleep and io
lists, the poller and its buffer — and one `@[ThreadLocal]` pointer
names the thread's own, Go's `g`. An entry pays one accessor, then
plain loads; the object roots itself the way the fibers do, on a global
list every state is linked to when it is made, so the walk that scans
the image's data reaches it and the thread-local is a cache of a
pointer the globals already hold. `bench/collect_trigger.sh` holds
that: the state lives through 64 triggered collections with nothing on
the stack naming it, and the proof unlinks the list and reads the
sweep's own free flag off the chunk. The price, measured by
`bench/defer_cost.sh` (a `defer` reaches `IyiScheduler.current` twice):
about 8 ns per defer against about 5, the accessor's two calls, and
one `mrs TPIDR_EL0`/`%fs:` load in the whole scheduler where there were
none. **The allocator is cut over the same way.** `IyiHeap` is a cache
per thread and a centre everything shares: the cache is one page a
`@[ThreadLocal]` address names, laid out as the old directory was (a
free-list head and a fill arena per class) and linked on `@@caches`
for the scavenge; the centre is the class lists the sweep fills, the
arena list and the large list, behind one spin lock on the prelude's
`Atomic`. The fast path — pop the cache, or carve the cache's own
arena — takes no lock and touches no shared word; a cache that runs
dry takes the centre's whole list for the class under the lock (one
pointer swap; a bounded batch is the fairness a two-thread profile may
ask for, not guessed); `free` goes to the caller's own cache, because
a grow-by-doubling loop that sent it to the centre paid two lock
cycles a step and measured 61 ns an alloc+free pair against 27; the
sweep links an arena's white chunks as it walks and splices them to
the centre under one take of the lock, and pause totals in
`bench/collect_trigger.sh` fell from 86 ms to 70 ms over 87
collections with the batching. The price of the split, on
`bench/arena_exercise.sh` which now measures release builds too: 4 ns
to 6 ns an allocation in release (the one `%fs:` load), 23 ns to 27
in a plain build (one call). **And a Stage 4 design input this
decides:** a thread stopped while it holds the heap lock — inside a
refill, a carve that maps, a large free — deadlocks the sweep that
needs it, so the stop handler must not park a thread holding it; the
lock word is the thread's own to check, and a held lock defers the
park to the release. Go's "no preemption inside mallocgc", arrived at
from the other end. What is still one thread's is the trigger's
`allocated_since`, a class variable every `take` adds to; it becomes
a per-cache count folded at the collection, and that waits for the
thread that would race it. The other absence
is closed: the prelude has `Atomic(T)` now (`src/iyi/atomic.iyi`, SPEC.md
III.4.10), built for the probe as its first caller and gated by it —
`get`, `set`, `add`, `sub`, `swap`, `compare_and_set` on the four
arithmetic integers, sequentially consistent and nothing else, the
compiler's `atomicrmw`/`cmpxchg` rather than asm, and no name on the
floor. The mark word's CAS is `compare_and_set` on a `UInt64`, and every
shared counter is an `add`; what Stage 7 measures decides whether a
weaker verb is ever added.

**Threads in the runtime, and the stop — Stage 4, built.** The probe's
mechanism is `src/iyi/thread.iyi` now: `IyiThread.start { }` is a
kernel thread — raw `clone` onto a mapping of its own with a guard
page and a TLS block laid out from PT_TLS on Linux, `pthread_create`
on darwin — and `join` is the futex on the tid word the kernel clears,
or `pthread_join`. A thread gets a scheduler state and a heap cache on
first touch, so it spawns fibers and allocates without a lock, and it
is not a task: no group owns it, nothing cancels it, no channel
crosses it, and what crosses threads today is `Atomic(T)` — which is
`Share`'s obligation, now with a second thread to refuse things for.

A collection takes the runtime lock first, so no thread it stops can
be holding it; then signals every other registered thread and waits
for each to count itself in. The handler copies the interrupted
general registers out of the ucontext onto the thread's line, records
sp and pc, and parks — futex on Linux, a pipe per thread on darwin —
and the collector scans each stopped thread's spill and its stack from
that sp to the top of whichever mapping holds it, the thread's own or
a fiber's, found by asking every fiber. Two threads are not parked
where they stand, and both are the Go rule this document reached from
the allocator's side: one inside `IyiHeap.take` — between reading a
cache list's head and popping it, a stop would leave a chunk claimed
by nobody the sweep could then unmap — finds the handler leaving a
request on its cache page and parks itself on the way out, spilling
its own callee-saved registers; and one spinning for the runtime lock
parks inside the spin, where it holds nothing. `SA_RESTART` restarts
the syscalls a stop interrupts, and the poller already read EINTR as
a wakeup with no news. A thread's last act returns its cache to the
centre, lets its fill arenas go, and leaves the list a stop walks;
the stop that began before it left waited for it.

What the build found, and what it decided. The trigger's count moved
off the class variable onto the centre's atomic, folded per cache
every 64 KiB, and the decision to collect is made twice — on the count
as seen, and again under the lock, because two threads cross the
budget in the same instant and the second must not collect a heap the
first just swept. A whole-list refill let one of eight threads take
every chunk the sweep freed and the other seven carve, and the heap
and every sweep grew with it; the centre keeps a class's chunks as a
stack of the sweep's own per-arena batches now and a refill takes one.
And a budget floored at a MiB met eight allocating threads as 4,000
collections a second, each a stop of eight and a sweep of eleven
arenas, 300 µs where one thread's was 15: **the budget is floored at
half of what the sweep walked**, so a collection costs a bounded
amount per byte allocated however many arenas the threads carved —
the single-thread gates keep their arithmetic exactly (64 MiB of churn
is 64 collections), and eight threads went from 634 ns an allocation
to 239. The stop's own cost is the floor's table: 22 µs for seven
threads, 7% of the pause. The frame question was answered by use
rather than by a mechanism: the handler runs on whatever stack the
thread is on, a 256 KiB fiber stack included, and the probe's 5.7 KB
frame is what a fiber has to have spare above its guard page when a
stop lands. The exercise's fibers take stops on their own stacks. A
`sigaltstack` per thread — a syscall on Linux, one name on darwin —
is the answer if a program's fiber is ever that deep, and it is not
built ahead of one.

`bench/thread_exercise.sh` holds it, plain and release, on Linux and
darwin, with the aarch64 arm run under emulation: eight threads
allocating from their own caches while collections run from whichever
crosses the budget, each holding a live list in nothing but its own
frames through those collections and finding it intact by checksum and
by the sweep's own free flag — after one explicit collection with
every worker spinning on its list, and after twenty bursts of churn —
each running fibers of its own with a parked one holding an object's
only reference, then 32 threads past the core count; the floor read
off the binary, five names on Linux; and the failure proof removes the
thread-root walk from a copy of the prelude and the spinning threads'
lists are swept out from under them by name. The price, release, 20
cores: 76 ns an allocation with one thread, 162 with four, 268 with
eight — wall time per allocation per thread, every pause included,
which is what Stages 7 and 8 exist to bring down: every thread stands
still for a sweep one thread runs.

**The mark runs beside the program, on the compiler's write barrier —
Stage 9, built, and Stage 7's other half.** The parallel marker made a
mark of a million nodes 6 ms on twenty cores; it was still a stop of 6
ms. The stop is two now, and neither is the mark. The first, on the
triggering thread under the runtime lock: the world stopped, the roots
grayed onto the pool, a byte raised (`__iyi_marking`), the helpers
woken, the world resumed — 15 to 35 µs, roots and nothing else. The
helpers drain beside the program. The second, on helper 0 once every
helper found the pool empty: every thread's barrier stack flushed, the
roots again, and what those found drained; then the scavenge, the
sweep's beginning, the budget, and the byte lowered.

What the program does between the stops is what the barrier is for.
Codegen wraps every store that can put a heap pointer into heap memory
— an instance variable, a class variable, an ivar initialiser, a tuple
element, a `Pointer#value=` (which is what `Pointer#[]=` and every
collection's store come to), a C struct's field, a closure's captured
variables, its parent and its `self` — in a
test of the byte and, while it is up, a call after the store with the
destination's words: each heap pointer among them is grayed and queued
on the storing thread's own stack (Dijkstra's insertion barrier, done
by re-reading the destination rather than by passing the value, so one
shape serves a word and a struct alike). Stores into stack slots — an
`alloca`, or a field or element of one, walked through the casts and
GEPs codegen puts between a local and its parts — are not wrapped: the
stack is rescanned at the second stop. The test is a byte load and a
branch, and `bench/defer_cost.sh` still reads 15 ns a defer; a store
under a running mark pays the call. Objects born under the mark are
born gray and queued the same way, and a `realloc`'s copy is shaded
whole. The bracket around a store — a depth counter on the thread's
cache page, the same one the allocator uses — is what keeps a thread
from being parked between a pointer store and the barrier that shades
it, or the second stop's rescan could miss what the store just put
into a black object.

Two things the second stop found, and what it does about them. A
pointer a thread loaded from a white object into a register is a
whole structure the marker never reached — 200 000 nodes of a chain,
2 ms walked inside the stop — and what the program published between
the helpers finding the pool empty and the stop can be as large. So
the stop looks before it drains: a white root, or a pool past sixteen
batches, and it resumes the program, marks beside it once more, and
stops again, up to eight times — Go's mark termination makes the same
check and the same retreat. What the last stop still finds is drained
alone: waking fifteen helpers inside a stop cost 0.1 to 1.5 ms of
scheduling for the thousand entries they were woken for.

Three things the build corrected. A program that never started a
thread had a main thread with no line, so a helper's stop stopped
nobody and swept beside it; the trigger registers the main thread
before its first concurrent collection, before the lock, because
registering takes it. The pool's page was made by whichever thread
reached it first, and with the helpers started before the stop, two
threads reached it at once and counted ready on different pages; the
collector makes it before the first helper exists. And a mark-worker's
32 MiB stack, touched at one end, was given a transparent huge page at
its first touch: 2 MB resident per worker for 4 KB used, 34 MB across
sixteen, so the stacks refused huge pages by `madvise` - and begin at
64 KB now and grow, the footprint section says.

The budget is twice what survived, and what was allocated under the
mark did not survive anything: born gray, so counted marked, but not
live in the sense the budget wants, and counted the other way a program
allocating through every mark doubled its heap each cycle. Those bytes
are the first of the next budget's instead. The first collection of a
program has no live-set estimate and went beside the program too, the
helpers spawned before its stop; stopped, it was the longest pause in
every table.

`bench/concurrent_mark.sh` holds it: twenty-four rounds each build a
200 000-node chain with a payload on its last node, allocate until the
byte is up, move the payload from the chain's tail into a holder the
marker blackened first and cut the tail's edge — a barrier-only
object — and read it back after the collection, its header without the
sweep's free flag and its bytes the pattern written; and the failure
proof removes the barrier's shade from a copy of the prelude and the
first payload is freed by name. The numbers, release, 20 cores: the
same chain marked stopped is 1.9 ms; beside the program the longest
first stop is 0.6 ms (the trigger's second collection, its helpers'
first spawn) and the longest second 0.2 ms, with about twenty of
forty-eight second stops retreating once. On `bench/gc_race.py` against
Go, the table `python3 bench/gc_race.py` prints — release builds, best
wall of five, worst resident of five, longest and total pause — read on
this machine (20 cores) the day Stage 9 landed:

| program | iyi wall | RSS | pause max | paused | Boehm wall | RSS | paused | Go wall | RSS | pause max | paused |
|---|---|---|---|---|---|---|---|---|---|---|---|
| binary trees | 0.276 s | 62 MB | 0.10 ms | 2.6 ms | 0.170 s | 18 MB | 63 ms | 0.149 s | 18 MB | 0.19 ms | 2.1 ms |
| live churn | 0.160 s | 316 MB | 0.47 ms | 1.1 ms | 0.149 s | 91 MB | 92 ms | 0.225 s | 134 MB | 0.10 ms | 0.3 ms |
| churn | 0.047 s | 38 MB | 0.03 ms | 0.3 ms | 0.078 s | 15 MB | 40 ms | 0.069 s | 15 MB | 0.48 ms | 3.6 ms |

The pauses are Go's now or under them, on every program (binary trees'
longest was 2.3 ms with the parallel marker alone, 2.7 before it).
Wall time is Boehm's column on two of three: the write barrier's
test is on every pointer store, and the helpers share the cores the
program runs on. Resident memory was Go's column by three times, and
the section below is what closed it.

**The footprint follows the live set: a one-word header, eight-byte
classes, pages handed back, allocate-black and the assist.** Binary
trees held 6 MB live in 62 MB resident, and the reasons were four.

The header was three words - a size, a type id, a mark word - ahead of
every object, so a 16-byte object cost 40 bytes of heap where Go's and
Boehm's cost 16. The size is the chunk's, which the arena knows
(`IyiHeap.size_of` reads it there, or off a large object's node); the
type id is 32 bits and the mark word had 58 to spare; so the header is
one word at `P-8`, colour and flags in its low bits and the type id in
its high half, stored by codegen as a u32 at `P-4`. A free chunk's link
and its batch's chain ride in the payload, which is nobody's while it
is free. (The object carried the id twice until 0.10.0, once here and
once as an `i32` at its front, Crystal's layout; the section on one
type id, below, is where the second copy went. And since 0.11.0 the
word is there only for a class something reads the id off, the
collector's bits and the other classes' ids being tables at the
arena's head: "The header round, built", below.) The size classes were
powers of two, so a 24-byte object - two pointers behind its type id,
the commonest shape a program has - took a 32-byte class and a 40-byte
object a 64-byte one; they are
eight-byte steps to 128 and four to each doubling above, 67 classes,
and the waste is capped at eight bytes below 128 and a fifth above. A
16-byte object costs 24 bytes now, a 24-byte one 32: Boehm's granule.

Then the pages. A collector that frees chunks but never pages has a
resident size that is its high-water mark. The sweep hands runs of dead
pages back to the kernel with `madvise(MADV_DONTNEED)` (darwin:
`MADV_FREE_REUSABLE`), a bit per page in the arena's first page saying
so, and the carve takes a run up again as its bump region before it
touches the frontier - which it now carves a slab at a time, 64 KB, so
that the heap fills from its low addresses and the frontier stays cold.
A chunk is on a released page when its head is; such a chunk is on no
list, reads as zero, and the mark, the sweep and the root walk refuse it
by the bit. Three things the build found. Every free list is dropped at
the pause, the centre's and each stopped thread's cache's: a chunk left
on a list between two dead ones broke the run they would have made and
kept its page resident, and with the lists carried across an arena of
40-byte chunks holding 1.5 MB live kept 12 MB of pages. Released on
sight, every page the program churns through went back and came back
each cycle, a syscall per run and a fault per page, and a 64-byte
allocation cost 220 ns where it had cost 21: the epoch's sweeps keep a
budget's worth of free pages resident - what the program will allocate
before the next collection - and release what is free beyond it. And a
16 MB arena touched at one end was given a transparent huge page, two
megabytes resident for a class with ten objects in it, so the marker's
stacks and the heap's first eight arenas refused them by `madvise`;
past 128 MB of arenas the two megabytes were taken as a rounding of the
heap, since the page walk they save is what a large heap pays most -
live churn, 48 MB live, ran 17% faster on huge pages. The rule is per
arena now, and says so below (the resident set's second cycle): an
arena's first four megabytes refuse huge pages and the rest is the
kernel's default.

Then what Go does about a mutator outrunning the mark, both halves.
Objects born under the mark are born black: their fields are empty and
every store into them goes through the barrier, so there is nothing to
scan - born gray, they fed the pool a batch per sixty-four allocations
from every thread and the mark could not find the pool empty to end.
And the assist: a mutator that allocated a slice (64 KB) under a
running mark scans a thousand objects of the pool's before it goes on,
counting itself active on the pool while it holds a batch. Thirty-two
threads allocating through a mark bore 13 MB beside a 4 MB budget, and
every collection's end was the next one's trigger.

Two things moved out of the stop on the way. The scavenge's unmap: the
kernel frees a resident 16 MB mapping in half a millisecond, ten of
them were the whole of a 5 ms stop, and a released arena - off the
list, out of the directory - is nobody's to touch, so the unmap waits
for the program to be running again. And the allocator's sweep runs
outside the runtime lock, claimed by epoch: with every list dropped at
the pause every thread refills at once after a collection, and
thirty-two threads sweeping one arena each in turn under one lock were
a convoy the thread exercise measured as a hang. An arena is one
cache's at a time, claimed under the lock when a region is set in it,
so two caches never bump one cursor; a region is never set in an arena
a walk holds; a walk that parked through a pause discards its batch as
the old epoch's; and the scavenge leaves alone an arena that is
claimed, or walked, or whose mapping a parked walker still names.

The table, read on the tree 0.10.0 shipped: the lock-free carve, the
growth default of 200, Stage 8's slices, one type id and the sweep
round's retry all in, one run of `bench/gc_race.py` on mains, the
median of four:

| program | iyi wall | RSS | pause max | paused | Boehm wall | RSS | paused | Go wall | RSS | pause max | paused |
|---|---|---|---|---|---|---|---|---|---|---|---|
| binary trees | 0.207 s | 29 MB | 0.59 ms | 6.7 ms | 0.188 s | 18 MB | 76 ms | 0.214 s | 16 MB | 0.14 ms | 3.2 ms |
| live churn | 0.110 s | 224 MB | 0.37 ms | 1.0 ms | 0.163 s | 91 MB | 106 ms | 0.248 s | 130 MB | 0.12 ms | 0.5 ms |
| churn | 0.059 s | 15 MB | 0.01 ms | 0.5 ms | 0.078 s | 15 MB | 40 ms | 0.082 s | 15 MB | 0.17 ms | 3.9 ms |

The wall time is under Go's on all three and under Boehm's on two -
binary trees is a tenth behind Boehm and a hundredth under Go - and the
total paused is a fortieth to a tenth of Boehm's. The longest pause is
under Go's on churn, three times Go's on live churn and four times on
binary trees, whose second stop retreats over a 200,000-node chain
held on a register; the spread across the four runs is the tell -
binary trees paused 4.4 ms, 6.7, 8.1 and 10.0 while Go paused 3.1 to
3.3 - and the retreat is what Stage 9's own section says is the one
stop it does not bound.

The spread, same four runs: binary trees 0.197 to 0.223 s and 26 to 29
MB, live churn 0.110 to 0.117 s and 186 to 238 MB, churn 0.051 to
0.060 s and 15 MB. Live churn's resident set moves because the budget
is what the last mark found live times the growth, and which
collection the run ends on decides the peak; binary trees' moves with
where its collections fall in the iteration. Against 0.9.0 on this
machine the wall time is a little better on binary trees (0.227 to
0.207) and live churn (0.136 to 0.110) and unchanged on churn, and the
resident set is what the layout bought: a 200,000-node list marks
200,000 times eight bytes fewer, which shows in live churn's floor
(249 MB to 186) more than in binary trees' (29 to 26-29, its peak
being a budget rather than a live set). On battery, under the
`powersave` governor, every arm of this table reads about twice as
slow, so a run that is to be compared with it is a run on mains.

The sweep round's retry landed after the previous reading of this
table and is in this one. Interleaved against the build before it, on
the same machine, minimum of eight: binary trees 402 ms to 367 on
battery, with churn and live churn where they were. Churn's footprint is Go's and Boehm's; binary trees' is within a
budget of Go's (its live set doubles into the next budget the same
way, and Go's 16-byte node was our 32-byte one, its type id ahead of
two pointers - a 24-byte one since the type id left the object, below);
live churn's is two budgets over Go's, which is the
growth default applied to a 40 MB live set. The policy is a knob with
Go's meaning: `IyiMark.growth = percent` is what the program may
allocate before the next collection, in hundredths of the live set -
Go's default is 100, iyi's 200, because its collections are concurrent
and its allocation path is where it pays; at 100 binary trees traded a
fifth of its wall time for a smaller peak. What remained was the wall
time, and the next section measures where it went.

**The resident set, measured, and what it was made of.** 0.11.0's first
cycle began from a probe (`bench/resident_probe.iyi`, driven by
`bench/resident_probe.py`: peak RSS per process from `wait4`, the pages
every arena has touched, the sweep's page counters, one tree
interleaved against another): a 500,000-node live list of 48-byte
chunks, 22 MB, under 384 MB of churn in a class of its own, 64-byte
blocks in 72-byte chunks. Where the design says live set plus a budget
- 22 + 38 MB - the tree 0.10.0 shipped touched 55 to 151 MB of arenas
from run to run and peaked at 103 to 225 MB resident, on two and on
eight cores. The spread is the
first finding: the churn class allocates 10 to 17 MB while a mark of
the 22 MB list runs beside it, born black and dead only at the next
sweep, and how much depends on where the mark falls, so the probe's
own number moves by a third between runs of one tree. What was
supposed to be the gap - a budget's worth of pages kept warm that the
carve never took up - was not there: the kept pages were consumed
every epoch, and where they went was three other places.

The kept pages did not survive a pause. Whole pages of dead chunks were
kept warm as chunks on the sweep's batch, and a pause drops every
list, so whatever of a budget's worth the program had not got to was
gone at the next collection: the next epoch's sweep found and linked
the same pages again while the program carved the frontier or waited
on a slice. Now the sweep lists their pages as well
(`OFF_LISTED_PAGES`), a refill that takes a batch unlists the batch's
pages, and the pause turns what is still listed into idle warm pages -
a bit per page, which a pause does not drop. The refill threads a run
of them into the cache's list before it sweeps a slice or carves a
slab, and the sweep meets them as idle and ages them against the
epoch's budget, so a class the program stopped allocating keeps a
budget's worth at most. The sweep exercise's `warm` check is the gate:
four thousand chunks, a collection, a second collection before
anything takes the batch, and the next four thousand come from the
first's pages, cleared, with the class's high water where it was.

The budget was overshot by a run and undershot by the header. A run
kept or released whole overshot the budget by the run, and a run is an
arena when the arena is all dead: 13 MB warm for a 4 MB budget. The
run is split at the budget now. And the budget was counted in pages
against bytes the program asks for; a 64-byte class's page holds an
eighth less payload than its bytes, so the warm pages held an eighth
less than the epoch's demand and the carve took the difference from the
frontier every epoch. The count is of payload.

The scavenge unmapped a churning class's arenas every pause - every
one of them is dead at every mark - and every epoch mapped fresh ones
and faulted a budget's worth of pages in again: 9 to 14 arenas released
over 11 collections, 21 to 27 mapped in all. This one stays as it is.
Sparing an arena the epoch had allocated from (an epoch stamp per
arena) kept the mappings and the faults away, and the trigger
exercise's mappings from 5 to 2 on a churn two arenas wide - and the
probe read 140 MB median against 129 without it, on two cores, with
the race table the same either way: a churning class's dead arena is
resident garbage until the sweep reaches it, and the kernel should have
it back. Sparing only arenas holding warm pages spared nothing a churn
leaves, since a churn consumes its kept pages. Both were built,
measured and taken out.

Three more things were built on the way and measured out. Warm runs as
bump regions the carve took up first, no fault and no slice: the carve
became the allocator's main path, and the carve's ordered cursor store
and a refill's worth of loads per allocation ran churn 48 ms to 73.
Warm runs threaded into a list the moment the sweep closed them: a
pass over memory the sweep had just made, and churn ran 67. A refill
that spun for a helper's slice to end when the warm pages it wanted
were inside it: the wait is the refill's own slice, as it was. Kept:
a run that continues one a slice's end cut begins on its own first
page rather than the next, so the page a slice ended in is nobody's no
longer; the two places a page is released late - a cold part of a run
continuing another, and an idle page aged cold - leave the first page
alone when a chunk of the page before reaches into it, because that
chunk may be an object by the time the `madvise` lands and the
`madvise` would zero its tail; a free chunk of the current epoch's
parity is a live list's and the sweep leaves it where it is, which is
also what makes a hand-freed chunk safe from the sweep of its own
epoch; and the sweep's own loop tests the parity first, two tests for
a dead chunk where it was three.

Two more levers on that garbage were tried in the second cycle and
are not in the tree. A prefetch of a shaded object's line at its push:
a million-node tree marked in 14.2 ms alone against 14.5 with it, the
tree and the probe's list both allocated in the order they are
walked, which the hardware prefetches already. And Go's pacer - the
mark started early by what the last mark saw allocated beside it, so
the heap peaks at the budget: the trigger already charges a mark's
allocation to the next epoch (`allocated_word` starts the epoch at
`born`), so starting early by the same amount charged it twice, the
epochs shortened, and the probe read 138 MB median against 106.

What the probe reads now, interleaved against the tree before, nine
runs each, on two cores: peak RSS 103 to 150 MB against 103 to 153,
the medians 121 and 132 on two sittings against 131 and 118 - inside
the probe's own spread, which is the mark's. The table, read the same
way as the one above on the same machine, the median of four, with the
tree before it read in the same sitting for reference:

| program | iyi wall | RSS | pause max | paused | Boehm wall | RSS | paused | Go wall | RSS | pause max | paused |
|---|---|---|---|---|---|---|---|---|---|---|---|
| binary trees | 0.150 s | 25 MB | 0.60 ms | 5.5 ms | 0.184 s | 18 MB | 76 ms | 0.156 s | 16 MB | 0.12 ms | 1.6 ms |
| live churn | 0.111 s | 214 MB | 0.09 ms | 0.3 ms | 0.160 s | 92 MB | 103 ms | 0.190 s | 131 MB | 0.07 ms | 0.2 ms |
| churn | 0.044 s | 15 MB | 0.01 ms | 0.3 ms | 0.077 s | 15 MB | 39 ms | 0.064 s | 15 MB | 0.16 ms | 2.1 ms |

The tree before, same sitting: binary trees 0.180 s and 26 MB, live
churn 0.111 s and 205 MB, churn 0.052 s and 15 MB. Binary trees and
churn run a sixth faster: the budget counted in pages fell short of
the epoch's demand, so the tail of every epoch's dead pages went cold
and was faulted in again - churn released and reopened 5,444 pages
over its 122 collections, and releases none now - and the sweep's
loop is two tests a dead chunk where it was three; taking the split, the continuation, the
listing or the refill's early carve out one at a time moved neither
program, so the gain is the two things every variant shared. Both are
under Boehm's wall, binary trees under Go's; live churn is where it
was, its resident set moving with where its last collection falls,
194 to 234 MB across the eight runs of both trees. The resident set
this cycle set out to cut is the mark's floating garbage and the edges
runs lose to it, and the next cycles' terms - the pool region and the
workers' stacks - are the heap's neighbours, not the heap.

**The heap's neighbours, read from `/proc/self/smaps`.** The second
cycle began by reading every mapping's resident size at the end of
binary trees and of the probe, rather than the terms the first cycle
had been handed, and the terms were not what had been said. The
marker's pool region, a 64 MB mapping bump-allocated and reset each
mark, was 2 MB resident: its first touch was a transparent huge page,
for 425 KB of batches in binary trees and 12 KB in the probe. The
workers' stacks, 32 MB reserved each, were 40 KB resident across eight
- a mark's deepest stack was thirty entries - but 272 MB of address
space and overcommit. The arena directory, 16 MB committed a page at a
time, was 2 MB resident for the same reason as the pool. And five
arenas of binary trees' were exactly 2 MB resident each, 10 MB of a 33
MB set: the ninth arena and after took huge pages, and the ninth arena
is not the large one, the large one is.

So: a batch taken from the pool is a batch's words free again, on a
free list pushed without the lock and popped under it, and new words
come from 64 KB pieces that refuse huge pages - the pool holds the most
batches ever in it at once, 64 KB through eleven marks of a million
nodes with fifteen helpers, and the 64 MB reservation and its "pool
region is full" are gone. A worker's stack begins at 8,192 entries and
doubles when a push or a taken batch needs more, the entries copied and
the old mapping given back (`grow_stack`); the drains read the stack's
address per pop, since a push inside a scan may have moved it. The
directory refuses huge pages. And an arena's first `HUGE_AT` bytes,
four megabytes, refuse them, with the rest of the mapping left to the
kernel's default: a class of a few objects never touches the tail,
and an arena carved past the line is large, its tail faulting in huge
where THP is `always`, so the page walk a large heap pays is still
saved. Asking for the tail outright with `MADV_HUGEPAGE` was built
and measured out: under the common `defer+madvise` defrag setting an
asked-for region is compacted for on the fault path, and a mutator
stalled in a fault answers a stop late - live churn's longest pause
read 4 to 10 ms in three runs of twelve where it reads 0.1 to 0.3 -
where the default policy defers compaction and stalls nobody. Binary
trees' resident set at its end fell from 33 MB to 16 on this machine,
the race table's peak from 26 to 22-24, live churn's from 194-206 to
173-186, and the resident-set probe's median from 123-140 to 100 on two
cores; the parallel mark exercise gates the pool's size and the
stack's growth by name, and the arena exercise reads the kernel's own
books - resident pages from `statm` for twelve one-object arenas, and
the flags it holds for an arena's two halves from `smaps`, `nh` on
the first and not the second - with what it gave reported from
`AnonHugePages`, because what it gives is its own.

**The last eight bytes: what the next round decides, measured first.**
An object is a one-word header and its fields; Go's node is its
fields. Taking the word out is the only way to Go's 16-byte node, and
what it buys is the header's share of each program's chunks: binary
trees' nodes are 16-byte objects in 24-byte chunks, a third of every
chunk, and its 21 MB peak would read some 15; live churn's items are
32 in 40, a fifth, 8 MB of 178; the probe's nodes 40 in 48, a sixth.
What the word carries has to go somewhere. The five bits - two of
colour, free, atomic, the epoch's parity - would go to a byte per
chunk at the arena's head, and that was built first, on its own, for
everyone, with the type id left at `P-4`: a byte for every sixteen
bytes of the mapping, a megabyte an arena resident where chunks are,
the mark's shade a compare-and-set on the byte, the sweep reading and
restamping the byte, `free_listed?` reading it, neither touching a
live object's line. It was measured out. The mark of a million-node
tree ran 14.1 ms to 15.7 alone and 6.3 to 7.2 with helpers, churn 40
ms to 48, binary trees and live churn 5% slower: the object's line is
loaded for its fields whatever the header holds, so dirtying it costs
almost nothing, and the byte is a second dependent line and an arena
lookup on every shade, every scan and every pop. (A byte per chunk by
the arena's reciprocal, tried before the sixteenth, was worse: two
loads and a multiply per pop, churn 54.) So the bits stay in the word,
and any headerless layout pays that mark for the objects it takes the
word from. The type id, 32 bits, is the decision, because it is what
dynamic dispatch reads - the three loads of `type_id.cr` - and it has
three homes:

- *In the object, as now:* `P-4`, one load on a line the method body
  is about to touch anyway.
- *One per arena:* arenas per (class, type), the id at the arena's
  head, one mask and one load; every type of a size class gets a
  mapping of its own with its own partial pages, and the atomic and
  untyped allocations of the class share one.
- *A byte or a word per chunk in the arena's head:* the chunk's index
  by a multiply-and-shift reciprocal of the chunk size held at the
  arena's head, then a load; the chunks of a class share arenas as
  they do now.

Measured, one million 24-byte objects in 16 MB arenas visited in a
shuffled order, the object's first field read in every arm so the
line the method needs is loaded in all of them, one core: the header
5.2 ns a dispatch, the arena's head 5.8, the side table 7.3 - the
table is a second dependent line, and with the objects out of cache
it is what a cache miss costs; at a hundred thousand objects, in
cache, 0.65 against 0.83 and 1.02. So the side table is the layout
that changes nothing about how arenas are shared and costs a dispatch
a fifth in cache and half out of it; the arena's head is the cheaper
dispatch and the one that multiplies mappings by types. Either moves
the object layout every module was compiled against - `.iyimod` v45 -
and the two gates that pin the header (`object_header_spec.cr`, the
arena exercise's `header:` check).

The fourth home is the one the numbers point at: *nowhere, for the
classes nothing reads it from.* What reads an object's type id is
`object_type_id`, and it is reached from exactly two shapes of static
type - a virtual type over an ancestor of the class, and a reference
union the class or an ancestor is a member of; a class in a mixed union
rides under the union's own tag, and a nilable class is a null test.
The compiler can say which classes those are, and the census says it
(`IYI_HEADER_CENSUS=1 iyi build`, one line a class on stderr,
`gc_layouts.cr`): binary trees, 0 of 58 classes laid out need the id
in the object; live churn 0 of 57; the probe 0 of 62; the web sample
with its router 0 of 76; the concurrency exercise 0 of 108; calc's
three modules 0 of 74. A program written to dispatch - two classes
under a virtual type, two in a reference union - reads 3 of 59. So
Go's 16 bytes are reachable for every object these programs allocate
without touching how dispatch reads an id, because these programs do
not dispatch; what stands in the way is not the language but separate
compilation: the layout is in a module's object code, and a module
that allocates a class cannot know that a consumer will put it under a
virtual type. The shape that fits is a descriptor a class - size,
whether it wears its id, its arena class - a weak global every module
defines as "headed" and the final program's codegen defines strong
with the census's answer, the allocation path reading it; the field
offsets do not move either way, only the chunk's size and the id's
store, so a module's code is right under both. A headerless object's
five collector bits go to the byte table this cycle measured, and its
layout for the mark to the arena's head, arenas per (class, layout)
rather than per type - layouts per class being a handful - and the
mark's arena lookup, which was the byte table's whole cost when the id
stayed in the word, is then the read that replaces the header's. What
the round pays and buys, on the numbers here: the mark some 5% for the
table's line, allocation a byte store for a word store, a third of
every 16-byte chunk and a fifth of every 32-byte one back.

**The header round, built.** An object is its fields. A class carries
its type id in a word ahead of the object only when the program that
links says so - `gc_layouts.cr`'s `iyi_headed?`: a virtual type over
an ancestor was ever made, a reference union has it or an ancestor,
the id does not fit sixteen bits, or it is `String`, the one class the
prelude builds from bytes and stores the id under itself - and the
answer is a byte per class, `Name:headed` beside `Name:type_id`,
defined in the main module and referenced from a unit's object code
the way the id is, so a module allocates right under a consumer that
dispatches on a class it never did (`.iyimod` v45). Codegen allocates
an instance through `__iyi_new(size, type_id, flags)`; untyped memory
- `Pointer.malloc`'s - is headless whatever the class, and a 4096-byte
buffer is a 4096-byte chunk where it was 5120. Past the top class an
object is a mapping and headed, its bits in the word as before.

What the word carried moved to the arena's head, in two tables, both
indexed by the chunk's number on the grid (a multiply by the chunk
size's reciprocal, held with the grid's origin in one word of the
header's first line). The *entry*, three bytes a chunk: the
allocator's flags - free, atomic, the epoch's parity, headed, untyped
- and a headless object's sixteen-bit type id, because the mark reads
both for every object and a tree's objects are anywhere. The *colour*,
a byte a chunk in a table of its own, because the allocator writes the
entry and the mark's helpers write the colour, and with the two in one
byte the carve and the marker fought over a line twenty-one chunks
wide for the whole of every concurrent mark. A chunk on the grid costs
its bytes and four: 16-byte nodes are 20 where they were 24 and Go's
are 16; a 40-byte node 44 where it was 48.

What the round measured and turned back, in order. The grid
arithmetic on the allocation's path: two words of the header two
lines down were churn 50 ms to 63, packed into the first line changed
nothing, and what did was taking the arithmetic off the path - a free
chunk's second word is its grid index, written by whoever freed it,
the carve keeps the entry of its cursor's chunk beside the cursor, and
the type id goes into the entry with the stamp rather than by a second
lookup. A walk of a batch for its pages at the refill, in place of the
range the header word had stashed: churn 50 to 62, the pass over
memory the allocation was about to touch; the range rides in the high
sixteen bits of the batch head's two words now. The epoch's parity
read before the refill rather than at the stamp: a refill's lock parks
for a pause, whose sweep turns the epoch, and the thread exercise
found its live lists freed. A free colour in the mark table so the
mark's inner loop never reads the entry: no measurable gain, and a
store on the mark line at every pop, turned back. Born-white objects,
alive to the sweep by their parity, so the mutator never writes the
mark table: every store of a fresh object into a fresh parent then
grayed and pushed it and the helpers marked the whole of what the
program built under the mark - binary trees 169 ms to 175, against
151 before; allocate-black stays, one byte store on a line the next
sixty-three allocations share. A barrier that pushed without
graying, for the worker to gray at its pop: 175, the same reason. The
barrier's compare-and-set without a read first: a failed one is a
locked write of the line, and the barrier's usual object is black.

The table, read as the ones above, the median of four:

| program | iyi wall | RSS | pause max | paused | Boehm wall | RSS | paused | Go wall | RSS | pause max | paused |
|---|---|---|---|---|---|---|---|---|---|---|---|
| binary trees | 0.158 s | 19 MB | 0.32 ms | 5.3 ms | 0.217 s | 18 MB | 93 ms | 0.163 s | 15 MB | 0.35 ms | 1.9 ms |
| live churn | 0.112 s | 199 MB | 0.05 ms | 0.3 ms | 0.186 s | 91 MB | 124 ms | 0.182 s | 127 MB | 0.04 ms | 0.2 ms |
| churn | 0.045 s | 15 MB | 0.01 ms | 0.4 ms | 0.078 s | 15 MB | 40 ms | 0.066 s | 15 MB | 0.16 ms | 2.1 ms |

Binary trees' resident set is Go's now, 25 MB to 19 against Go's 18,
and the rest of the price is wall on eight cores: binary trees 0.150 s
to 0.158, forty-one interleaved runs 141 to 152 ms at the minimum,
live churn and churn inside their spread; on one core the three are
where they were (binary trees 233 ms against 231, churn 48 against 48).
The eight-core cost was the mark's, and half of it was false sharing
in the arena's header: the chunk size, the grid word and the mark
table's address, read by the helpers for every pointer shaded, sat on
the two lines the carve writes its cursor and its cursor's entry to,
and were fetched again from the carving core at every shade; on a
line of their own, with the frontier and the idle bitmap no longer
read either (a carved bit in the entry, set with every stamp, and an
uncarved chunk's entry is zero), binary trees reads 4% over the tree
before at the minimum of forty-one, live churn 3% under. What is left
is a shade being two table lines and the object's where it was the
object's alone. And the growth knob at Go's 100 rather than 200, read
after the round on the same machine, eleven runs each: live churn 176
MB median to 162 for 101 ms to 113, binary trees 16 to 13 for 138 to
141 - live churn's set is the mark's floating garbage more than the
budget, and the wall is the allocation path's, so 200 stays. The
probe reads 19 MB
live in 40-byte chunks where it read 22 in 48, and its peak, the
mark's floating garbage, where it was.

**Stage 8: the sweep beside the program, in slices.** Two
measurements first, both on this tree's release builds. The barrier:
a prelude with `__iyi_write_barrier_begin` renamed makes codegen emit
no barrier at all (binary trees' object carries 26 loads of
`__iyi_marking`, then 5, the runtime's own), and under a stop-the-world
mark, where the barrier is only its load and branch, binary trees ran
239 ms without it against 242 with, live churn 134 against 136, churn
64 against 63: one percent, not the gap. The sweep on the allocating
thread, timed with `rdtsc` around the allocator's own walks: 41 ms of
binary trees' 214 (a fifth), a third of live churn's, a fifth of
churn's - and binary trees' whole gap to Go was 15 ms. A sweep is a
walk of every chunk header in the heap, at memory's speed, 1.6 ns a
chunk; a heap three times the live set is walked once per collection,
and the thread that allocates was walking it.

The first cut, recorded above as taken out, put whole arenas on the
helpers and made the allocating thread wait for the first arena's
batch or carve fresh chunks: it waited a whole arena, or carved, and a
page faulted in costs what sweeping a hundred chunks does. The shape
that works sweeps in *slices*: 64 KB of arena from a cursor the arena
carries (`OFF_SWEEP_CURSOR`, `SWEEP_DONE` past the high water), by
whoever needs the chunks or has the time. An allocating thread that
finds nothing swept for its class takes one slice of an arena of that
class - a few microseconds - and allocates from it; the helpers, after
every collection, take slice after slice until nothing is left, and
hand each slice's batch to the centre as they go. The walk claim
(`OFF_SWEEPING`) is held for one slice, so three helpers are on one
arena at once and the arena a program churns through is swept three
times faster; a thread that finds every arena of its class inside
another's slice spins off the lock for the batch that is microseconds
away. The cursor is written before anything can stop the writer - a
mutator is inside the allocator, a helper is counted in - so it is
accurate whenever no slice is in flight, and a pause takes no claim:
every thread is stopped where no slice is, and it finishes whatever is
left from the cursors. The triggering thread does the same before it
stops anything, under a claim with the lock released for the walk,
because a half-swept arena wears two epochs' colours and the mark
reads one; what a thread was inside a slice of at that moment is
finished under the stop, a slice per thread at most.

The round: opened at a collection's end before the stopped threads are
released (opened after, the first refill found no round and swept the
arena it wanted, the largest, itself), woken after the lock is
released (seven helpers woken inside the stop preempted the waker and
made a 90 µs pause 1.6 ms - the first cut's other failure), and taken
by `SWEEP_HELPERS` = 3 of the helpers through permits and a futex wake
of that many: a sweep outruns an allocating thread's consumption
tenfold, and fifteen helpers beside binary trees cost it its core's
other half and ran slower than none. The next collection closes the
round under the lock and waits out the slices in flight with the lock
released, since a slice's end wants it. A per-class count of arenas
with sweeping left, on the centre's page, is the allocator's answer
without the lock: the first cut of the slices took the lock on every
refill of a class with nothing left and made eight threads' 269 ns
allocation 8 µs.

A helper that finds every arena with work inside another's slice does
not leave the round: a program whose nodes fit one arena would then be
swept by the thread allocating out of it, 471 slices to 34 on binary
trees. Nor does it look again at once. Every look takes the runtime
lock and walks the arena list, and a look after 64 pause hints - the
first cut of the wait - meant 450 looks for every slice a helper
swept, 4.6 million across binary trees. The wait is `SWEEP_BUSY_SPINS`
= 4096 pause hints, which is `SWEEP_SPAN` bytes of walking, ended
early when `POOL_SWEEPERS` falls, because a claim is let go at some
walker's slice end and that is the event waited for: 71,000 looks, five
a slice, and the helpers take more slices than the short wait did
(13,258 against 10,292). What the short wait cost is the darwin
section below.

The numbers, release builds, pinned to this machine's four fast cores
and interleaved, minimum and median of ten: binary trees 222 / 228 ms
to 199 / 201, live churn 102 / 107 to 101 / 104, churn 52 / 53 to 40
/ 40. The pauses did not move (binary trees' longest 72 to 105 µs
with one 278, live churn's 66 to 78, churn's 15). The thread exercise's
allocation under four threads is 104 ns to the old 99, under eight 282
to 269, and under thirty-two 10 µs to 19. Two things found on the way:
the pause clock wrote its timespec into one page shared by every
caller, and a probe that read it from an allocation while helper 0
read it under the lock saw time go backwards (the runtime's own calls
were all under the lock; the stamp is on the stack now); and the
runtime lock's spin was a CAS, which takes the line for writing on
every failed try, so fifteen helpers spinning on it slowed whoever
held it - it reads first now, and pauses between tries.

**darwin's race, for the record.** The darwin job runs the same
`bench/gc_race.py` on GitHub's arm64 runner (an M-series machine with
three cores the parallel mark sees, shared, not a machine to gate on),
so darwin's numbers are in every log; the run that landed this step,
release builds, best of five:

| program | iyi wall | RSS | pause max | paused | Boehm wall | RSS | paused | Go wall | RSS | pause max | paused |
|---|---|---|---|---|---|---|---|---|---|---|---|
| binary trees | 0.271 s | 23 MB | 0.78 ms | 8.9 ms | 0.290 s | 17 MB | 108 ms | 0.241 s | 15 MB | 0.98 ms | 5.8 ms |
| live churn | 0.160 s | 173 MB | 0.87 ms | 1.6 ms | 0.218 s | 101 MB | 146 ms | 0.202 s | 292 MB | 0.10 ms | 0.3 ms |
| churn | 0.077 s | 6 MB | 0.04 ms | 1.1 ms | 0.099 s | 3 MB | 37 ms | 0.100 s | 10 MB | 0.11 ms | 5.9 ms |

The same shape as Linux's with three cores in place of twenty: the wall
time under Boehm's on all three programs, under Go's on churn and live
churn and a tenth over it on binary trees, where three cores give the
mark two helpers and the sweep round two; the footprint 23 MB where
Linux reads 25 and under Go's on live churn, whose 292 MB is the same
live set at Go's own budget on a machine with less memory to spare; and
the pauses under a millisecond, in a run where Go's own longest was
0.98 ms.

How much of that table is the machine: between this run and the one
before it, on the same commit tree but for one constant, Boehm's binary
trees moved 0.241 s to 0.290 and Go's 0.211 to 0.241, a fifth of the
wall time, with iyi's arm moving with them. It is a shared runner and it
reads like one, which is why it is here for the record and why the
comparisons that decided anything in this cycle were made interleaved
on one machine, minimum of nine or fifteen rounds, with `IyiMark.workers
= 2` where the point was to stand where three cores stand.

**Which thread a mark runs on is measured, not estimated.** A mark
beside the program costs two stops and a helper's wake; a mark inside
one stop costs the live set. Until 0.10.0 the choice came from an
estimate - the last mark's live bytes against `PARALLEL_FROM`, a
megabyte - and an estimate is the last mark's, not this one's. Binary
trees' second mark read sixteen bytes, the stretch tree having gone,
and marked the three-megabyte long-lived tree inside its pause: 2 ms,
in a table whose other rows are tens of microseconds. Bounding the
estimate the other way (the last mark's bytes plus what was allocated
since, which is what could be live) put churn's 122 tiny marks beside
the program, and waking fifteen helpers 122 times cost churn three
times its wall time.

So there is no estimate. Every collection stops the world, pays the
sweep debt, shades the roots and then marks up to `STW_MARK_BOUND` =
1024 objects on the triggering thread, with nothing running and no
barrier needed. A mark that ends inside the bound *was* the whole
mark: the collection finishes in that one stop, no helper woken, no
second stop - churn's every collection, 87 µs at its longest. One that
does not is a large live set: the triggering thread hands what is left
of its stack to the pool in batches, raises the marking flag, releases
the threads and wakes the helpers, and helper 0 finishes with the
second stop as before. The bound is a thousand objects because that is
about ten microseconds of scanning, which is the price of finding out.

Both platforms measure, and darwin came to it late. It kept the
estimate for most of this cycle on a measurement of a rule without its
drain: `concurrent_possible?` was opened to every collection while the
bounded mark stayed behind a Linux-only flag, so every collection on
darwin went beside the program whatever it found, and churn's 122 of
them cost 0.49 s against 0.075 - a true number for a rule nobody would
ship, read as the bound's price. With the drain on both, churn's 122
marks all end inside the bound: one stop each, 18 µs at their longest,
none beside the program, and its wall time does not move. What the
estimate cost is a stop the bound has no room for: binary trees' second
collection, on darwin with the two helpers three cores give, read
sixteen bytes of last mark, marked 2,097,568 bytes stopped and paused
2.1 ms where every other stop in that run is under 230 µs. Whether a
run lands on that collection is luck - 0.9.0's runner read 0.06 ms and
this cycle's, whose smaller objects moved the collection points, read
2.56 ms on the same three cores - and with the bound there is no such
stop to land on: 0.10 ms, and the wall times below.

What the mark asks for changed with it. A concurrent mark asks every
helper there is, where sizing it by the live set (one per megabyte) cost
binary trees a tenth of its wall time: inside a pause the wake and the
end-detection are on the critical path, so fifteen helpers over three
megabytes cost twice what three did, but beside the program the mark's
length is what the mutator pays for - in barrier work, in assists, in a
budget it cannot reset - and the cores are otherwise idle. A mark's
permits are as many helpers as it asks, and a helper woken without one
parks again without counting itself in; on Linux each helper parks on a
word of its own, a cache line apart, so waking three wakes three
threads rather than fifteen.

**One type id: the object is its fields.** Crystal's object layout
puts the type id at the object's front, an `i32` before the first
field, and the header above put it in the mark word's high half too:
every class object carried it twice, eight bytes past its fields, and
binary trees' node - two pointers - was a 32-byte chunk where Go's is
16. In 0.10.0 the front copy is gone. The compiler's `LLVMTyper` lays
a class out as its instance variables and nothing before them; every
dynamic type-id read (`type_id.cr`'s three loads, which every dispatch,
`is_a?`, cast and union unboxing go through) is the u32 at `P-4`;
`offsetof`, the layout tables and the type-info dump lost their shift
of one; and a string literal's global is `{header word, {bytesize,
length, bytes}}` with the program's pointer past the word. The word
has to be there under every allocator, or a module's object code would
link under one and corrupt under another: the arena had it; the bump
pointer and wasm's linear memory keep their size word at `P-16` and
leave `P-8` for it; Boehm's and the process heap's blocks are eight
bytes larger with the pointer eight bytes in, an interior pointer
libgc follows by default. A `--crystal` program keeps Crystal's layout
- its runtime is Crystal's, allocating through Boehm with nothing under
the pointer - and so does the compiler's own bootstrap, which is such
a program; `Program#iyi_object_layout?` is the switch, true when the
iyi prelude is loaded, and the spec harness's JIT-run snippets, which
carry the default without loading it, keep Crystal's layout for the
same reason. `.iyimod` is v44: the layouts a module carries are laid
out differently, and a 0.9.0 artifact is rejected and rebuilt.

The footprint: binary trees 29 MB resident to 25, live churn 249 to
186, churn unchanged at 15 - a class object is eight bytes smaller and
the size classes are eight bytes apart, so the saving is every object's.
The live-churn program's own accounting says the same thing from the
other side: its 200,000-node list marked 14,400,096 bytes under 0.9.0's
layout and 12,800,272 under this one, which is 200,000 times eight.
Two things found on the way. A helper at the sweep round that found
every arena with work inside another's slice went back to its park as if
nothing were left, and the allocating thread swept the heap itself,
slice after slice; smaller objects and a smaller heap made the one arena
of binary trees' nodes always somebody's, and the round was worth
nothing until the helper learned to wait a slice and look again - how
long that wait has to be is darwin's story below. And the concurrent
mark's failure proof assumed the holder it moves a payload into is black
when the move happens; when it turns black is the workers' order of
business, and with objects eight bytes smaller the 200,000-cell chain
came first on the same stacks and the holder last, so the move now waits
for the holder's colour, which is the property the proof's message
always claimed.

**darwin's throughput, which the release waited on: it was the round's
retry, and its longest pause was the estimate.** Every gate passed on
darwin, its pauses were microseconds and its footprint fell with
everyone's - and its wall time on `bench/gc_race.py` was five times what
0.9.0 measured on the same three-core runner: binary trees 1.56 s
against 0.23, churn 0.74 against 0.075, live churn 0.47 against 0.10. It
was the wait in the sweep round's retry, above: a helper that finds
every arena with work inside another's slice looked again after 64 pause
hints, and every look takes the runtime lock and walks the arena list.
That is the lock every refill takes. On the shared path it came to 4.6
million looks across binary trees where the slice-long wait comes to
71,000 - the count is the code's, not the platform's, and what differed
is what a look cost the thread that wanted the lock: twenty cores and
parked helpers absorbed it, three cores and helpers that spin rather
than park did not, and the allocating thread paid for it in refills.

What the wait is worth, on a ten-core M2 Pro, unpinned, interleaved,
minimum of nine rounds: binary trees 1.33 s to 0.33, churn 0.32 to
0.061, live churn 0.33 to 0.124, where 0.9.0's own compiler measures
0.30, 0.082 and 0.116 on the same machine and the same programs. With
`IyiMark.workers = 2`, the two helpers a three-core runner gets:
binary trees 0.39 s to 0.19, churn 0.17 to 0.051, live churn 0.15 to
0.087, against 0.9.0's 0.21, 0.068 and 0.085. The round is not weaker
for the longer wait - the helpers take 13,258 slices where the short
wait took 10,292, and the allocating thread sweeps 34 where the short
wait left it 7 and no retry at all left it 471 - and every gate still
passes, `collect_trigger`'s among them, whose helpers begin 218 arenas
to the allocator's 10.

With the walls back, the pause was left, and it was the estimate's:
the longest stop in a binary trees run was 2.0 ms - one collection in
fifty-three, the one the estimate mispredicted, marking two megabytes
stopped while every other stop in the run was under 230 µs. darwin
measures the bound now too, which costs its walls nothing (churn 0.050
s against the estimate's 0.049, live churn 0.095 against 0.094, binary
trees 0.199 against 0.203, fifteen interleaved rounds each) and takes
that stop out: the same rounds read binary trees' longest stop 88 µs
against 0.9.0's 283, churn's 20 against 54, live churn's 65 against 40.
Against 0.9.0 on the same machine, with the two helpers three cores
give: binary trees 0.199 s against 0.217, churn 0.050 against 0.066,
live churn 0.095 against 0.091 at 173 MB resident against 187. That is
where the release was cut.

What the wall time was not, each measured: the helpers' park (the pipe
was built, measured and refused; they spin as they did), the
thread-local (Mach-O keeps its accessor), the two hangs found on
few-core machines (both fixed, both in this document's Stage 8 and 9
sections), the 16-kilobyte page against `RELEASE_PAGES` (churn hands
no page back and takes none up - its counters are zero in every one of
these runs - so the resident set that moved between runs is not the
sweep's `madvise` traffic, and it moves under 0.9.0's compiler too,
6.7 MB on one run and 26 on the next), and the layout, which this
cycle changed for every program and which measures at 0.9.0's numbers
once the wait is a slice. The mark's thread was not the wall either -
it reads the same under both rules - but it was darwin's longest
*pause*, and the rule is the measured bound there now: "Which thread a
mark runs on is measured, not estimated" above has the numbers.

**This machine's cores are not alike, and the race's numbers move
with placement.** The Ryzen AI 9 465 has four Zen 5 cores and six Zen
5c: binary trees pinned to one of the first runs 241 ms, to one of the
second 358, and an unpinned run lands where the scheduler puts it - so
do Go's and Boehm's. The tables in this document are unpinned, as a
person runs a program; the comparisons between builds above were made
pinned and interleaved, which is the only way two builds' difference
was readable through it.

**darwin's thread is measured too, and it is the pthreads price by
name.** III.9's rule there is the opposite of Linux's: raw syscalls are
not a stable ABI and libSystem is the platform, so the same probe
(`{% elsif flag?(:darwin) %}`, the same table, atomics, run and
assertions) is `pthread_create`, `pthread_join`, `pthread_kill`,
`pthread_threadid_np` for the tid both the thread and its parent can
ask for, and `sigaction` with libSystem's sixteen-byte struct and
libSystem's own trampoline for the handler's return. The park is where
darwin differs in kind: there is no futex, and the `__ulock_wait`
beneath libSystem's locks is private ABI, so a stopped thread parks on
what libSystem exports. Three were measured. A mutex and condition are
four names; one `os_unfair_lock` the main thread holds is two, but the
kernel hands it waiter to waiter and the resume becomes a chain at some
40 µs a link (177 µs mean for 4 threads, 415 µs for 8); one
`os_unfair_lock` per thread, on its line, taken by the main thread
before it signals and released by N unlocks issued back to back, is two
names and resumes as fast as the broadcast. That was the probe's park
for a day, and it has a defect the numbers cannot show:
`os_unfair_lock_lock` is not on Apple's list of what a signal handler
may call, so a stop built on it works with no promise. The question
was asked again with async-signal-safety in it, and two parks that
POSIX does promise were measured against the lock: `sigsuspend` on a
mask that lets a second signal through, released by one `pthread_kill`
per thread — Boehm's stop on every POSIX, one name, and a resume that
pays the kill loop twice (711 µs mean for 8 threads against the lock's
135) — and a pipe per thread, the handler blocked in `read` and the
main thread releasing it with one `write` per thread, which is the
lock's numbers below the core count (stop 2.0 / 20 / 50 µs best for 1,
4, 8 threads; resume 0.8 µs, 27 µs, 122 µs mean) for `pipe` and `read`
where the lock cost its two calls. The pipe is the probe's park now,
and the handler finds its own pipe through a `@[ThreadLocal]`, which
is what Stage 4's handler will do for the thread's state. Past the
core count the pipe's stop mean is several times the lock's (3.6 ms
against 0.5 for 16 threads) for a reason not yet read, and outside the
regime the design lives in. `sched_yield` was measured and left out:
it is a name, its own reschedule is 4 µs on the one-thread stop, and a
`yield` hint in the main thread's spin costs neither. The floor is
therefore held as an exact list by `bench/thread_floor.sh`: the
runtime's twelve names, plus these eight — the five above, `pipe` and
`read`, and `__tlv_bootstrap` — with each refused variant held to a
list of its own.

Go's stop was weighed too, and it is the one this probe cannot build
without the compiler's help. Go's handler blocks nowhere: it
rewrites the interrupted context so the thread, on return from the
signal, runs a trampoline that saves every register, parks in ordinary
code where any lock is legal, restores every register and jumps back
to the instruction it was interrupted at. The jump back is the
problem: after every register is restored there must be one left to
hold the address, and aarch64 has no jump through memory. Go's
compiler reserves R27 for exactly this (and preempts only at safe
points where it knows R27 is dead); LLVM reserves nothing for iyi, and
x18, the one register darwin reserves, is zeroed by the kernel on any
exception return, so a jump through it has a window a context switch
can hit. On x86_64 `ret` pops the way back and no register is needed.
So the Go-shaped stop on aarch64 is a codegen decision — reserve a
register the way Go does, at the cost of one fewer for every
function, and emit safe-point information or accept preempting
anywhere — and Stage 4 records it as the option that buys a handler
with no blocking call in it, against the pipe, which blocks in the
one call POSIX promises. The pipe is the default until that decision
is measured.

`__tlv_bootstrap` is what a thread-local costs darwin. There is no
local-exec on Mach-O: the compiler emits `adrp`/`add` to a 24-byte
descriptor in `__thread_vars`, loads its thunk and calls it, and the
thunk the linker wrote is `__tlv_bootstrap`, which dyld rebinds to its
own `tlv_get_addr` at load. Every `@[ThreadLocal]` access on darwin is
that call. And on Linux it is a call too, which the IR says and the
earlier "one load" did not: the compiler wraps every thread-local
class variable's address in a `noinline` function (`*Tls::slot` in the
release IR of both targets), on purpose — a fiber can move between
threads, so the address must never be cached across a context switch
— and the local-exec load lives inside it. Measured, because the
cutover puts the scheduler's current fiber behind it: the probe's
release build does ten million read-modify-writes of a
`@[ThreadLocal]` and of a plain class variable, each in its own
`@[NoInline]` frame, and the thread-local costs 3.2 ns to the plain
2.0 on darwin (two accessor calls, one for the load and one for the
store, each a thunk call inside, dyld's fast path being a
`tpidrro_el0` read and a table lookup) and 4.7 to 3.0 on aarch64 Linux
in a container. The price is the accessor call, not the platform; a
call, but not a cost the cutover has to design around. The block
itself costs nothing:
dyld lays it out per thread from `__thread_data` on first touch,
however the thread was made, so `Tls.make` has no darwin arm and the
probe's proof is the assertion alone — every thread read the image's 7
in its own copy and its own tid in its own slot for the whole run — and
the driver's failure proof is to delete the annotation, after which the
slots are one thread's class variables and the program names the clash
on the first thread joined. One more name appeared in a darwin
`--release` binary and it was not the thread's: `bzero`, the aarch64
back end's lowering of a memset it will not inline, and the compiler
zeroes every `Pointer.malloc` with one — a plain binary has only small
constant ones, a release binary inlines the allocator and keeps its
variable-length ones, and a plain binary with a large constant one (the
root exercise's 1.5 MiB object) named it too. A release `hello` carried
it and `bench/dependency_floor.sh`, which builds plain, never saw it.
It is the program's own now: the prelude defines `bzero` beside its
`memset`, in inline-asm stores because the loop-idiom pass would turn
a zeroing loop in a function of any other name back into the intrinsic
(the first version tail-called itself), and a darwin binary asks
libSystem to clear nothing — which is where Go stands on darwin, with
its own `memclr` and libSystem only for the kernel's door.

The numbers, release build, an M2 Pro (10 cores, 6 performance and 4
efficiency), 200 rounds, threads spinning the whole time, read on the
24 MHz counter (CLOCK_MONOTONIC_RAW, which is the prelude's darwin
clock now, because CLOCK_MONOTONIC there is rounded to the
microsecond): stop 1 thread best 2.0 µs / mean 2.2 µs; 4
threads 23 / 35 µs; 8 threads 54 / 100 µs with a 1.9 ms worst; 16
threads best 90 µs but mean 0.95 ms and worst 15 ms; 64 threads best
0.5 ms, mean 2.2 ms, worst 35–54 ms. Resume: 0.2 µs for 1 thread, 10 /
45 µs for 4, 18 / 155 µs for 8 — and then 4 ms best and 20 ms mean for
16, 13–44 ms best and 110 ms mean for 64. Two readings. The stop is the
`pthread_kill` loop itself: timing the loop apart from the handlers'
arrival gives 0.5 µs for one kill and 24, 83 and 612 µs for 4, 8 and
16, so every kill after the first costs 6–7 µs in the call — delivery
is serialised somewhere the sender waits on — where Linux's `tgkill`
costs about one, and a darwin stop below the core count is linear in
threads at that slope. Past the core count the resume, not the stop,
is the timeslice: the released threads run and spin, and a thread the
unlock woke has to wait for one of them to be descheduled, which on
XNU's default 10 ms quantum is the 4 ms best and 20 ms mean 16 threads
show — the same half of the pause Linux's oversubscribed resume lands
on, at the larger quantum. The two decisions above
stand on darwin with more force: marking workers and the mutator's M
are bounded by the core count, or a resume is tens of milliseconds by
construction.

The obvious other darwin stop was measured and refused. A signal is not
the only way to hold a thread there: Mach's `thread_suspend` on the
port `pthread_mach_thread_np` answers returns with the thread held —
XNU waits for it — and `thread_get_state` with ARM_THREAD_STATE64 then
reads its registers with no handler and no park, which is what Boehm
does on darwin. Four libSystem names for the signal arm's four, and it
is kept under `-Dtf_mach` with its own exact list and its own table in
the driver, because the comparison should stay a measurement. Same
machine, same rounds: stop 1 thread 3.8 µs best to the signal's 2.0;
4 threads 24 / 52 µs to 23 / 35; 8 threads 58 µs / 160 µs to 54 / 100;
16 threads best 110 µs but mean 5.4 ms to 0.95; 64 threads mean 31 ms
to 2.2. Resume is worse still past 4 threads: 3 ms mean for 8 against
155 µs. The reading is serial against parallel: each `thread_suspend`
returns only once its target has been through a core and stopped, and
the next begins after it, where N `pthread_kill`s are queued at once
and the handlers stop in parallel as their threads get a core. So
Stage 4's darwin stop is the signal and the per-thread pipe, and its
register capture is the handler's `ucontext`, as on Linux.

**Owner's Decision:** Own the garbage collector. Concurrency, parallelism, and performance control are the reasons. gcry is prior art: measurements, design hints, and a record of what has already been tried and cost what. iyi writes the heap, the STW mechanism, root discovery, and finalizers from scratch.

---

## The Cost of Ownership

iyi is now responsible for what gcry has working: a memory allocator with size classes, stop-the-world synchronization across threads and fibers, root discovery including the suspended-register cases that took gcry until v0.19 to close, finalizer execution, and weak reference handling. This is not an implementation of an algorithm; it is infrastructure. **Point of no return: Stage 5 (Marking).** Once the compiler emits pointer maps and marks live objects, bdw-gc can no longer be the fallback. The compiler's parallel codegen depends on collection; a broken collector breaks the compiler.

What iyi gains: exact control over concurrent marking (parallel work distribution, work stealing), tight coupling between codegen and collector (pointer maps, object headers, write barriers), and a performance baseline measured against real workloads rather than inherited from Boehm.

---

## The Two Precision Requirements (SPEC.md II.5)

1. **Heap-layout precision (REQUIRED):** Which words inside an object are pointers. R-4 stencils one compiled body per GC shape, so pointer maps travel with shapes. The compiler has this table exactly; no discovery needed.

2. **Stack-root precision (DEFERRED):** Which stack slots hold pointers. Requires stack maps from codegen and a frame walker at runtime. gcry measured this at approximately 2x cost with no RSS win (FINDINGS from github.com/sdogruyol/gcry/blob/master/docs/STACK_MAPS.md: "**stack-map precision is correctness-stable and NOT an RSS win**"). That result is worth inheriting rather than repeating. Do not implement; measure first if workloads differ.

---

## Staged Implementation Plan

Each stage is independently verifiable; the tree is never left broken between them.

### Stage 1: Pointer Map Emission & Parallel Marking Infrastructure

**What is TRUE at the end:** Every type has a `TypeLayout` in `.iyimod`, keyed by `type_id`. Object headers include a mark word designed for parallel concurrent marking (tri-color bits, CAS-safe). The architecture accommodates parallel work distribution.

**Tasks:**

1. **Pointer Map Emission:**
   - Extend `.iyimod` with a `Layouts` section: `type_id` → `TypeLayout` entries.
   - `TypeLayout` struct: `type_id: Int32`, `alloc_size: UInt32`, `scan_cap: UInt32` (unrounded instance size, caps conservative fallback), `scan_offsets: Array(UInt16)` (pointer field byte offsets, mark and recurse), `noscan_offsets: Array(UInt16)` (pointer-containing fields that are not themselves traced, e.g., weak references, integer tables like `Array` buffer).
   - Codegen pass: after all types are lowered, walk the type table and emit a `TypeLayout` for each monomorphic instance (within-module) or per GC shape (cross-module).
   - Compiler embeds layouts into every binary; no runtime discovery.

2. **Object Header Design (Parallel Marking):**
   - Object layout: `[header][user_data]`.
   - Header includes:
     - `type_id: u32` (index into layout table).
     - `mark_word: u64` (atomic, CAS-safe, holds three pieces of information):
       - Bits 0-1: color bits (00=white, 01=gray, 10=black). Tri-color invariant: a black object has no pointers to white objects.
       - Bits 2-5: reserved for future flags (e.g., has_finalizer, is_pinned).
       - Bits 6-63: can be repurposed for forwarding pointer if moving collection is added later.
   - Mark word allows atomic CAS to change color (e.g., `cas(&mark_word, white, gray)` in marking, `cas(&mark_word, gray, black)` in scan completion).

3. **Concurrent Marking Work Distribution (Design):**
   - Global work queue: thread-safe, lock-free (or fine-grained locks for now; optimize later).
   - Each marking worker thread: pop a gray object from the queue, scan its pointer fields, enqueue any white targets it finds as gray.
   - Load balancing: work stealing (if one worker's queue is empty, steal from another's). Deferred to Stage 6; for now, a shared queue is sufficient.
   - Mark word state transitions: only the marking phase changes colors; mutators do not touch the mark word (write barriers observe the mark word but do not change it).

4. **Write Barrier Design (for concurrent marking):**
   - When a mutator writes a pointer to a heap object: if source is black and target is white, change target to gray (add to marking queue).
   - Implementation: codegen inserts a check before every heap-to-heap pointer write (Stage 2 inserts the instrumentation, Stage 6 does the marking from it).
   - No barrier needed for writes from stack (stack is re-scanned each collection).

**Verification:** `iyi build` produces `.iyimod` with `Layouts` section; object headers are the right size; mark word bit manipulations are CAS-safe.

---

### Stage 2: Allocator: mmap-backed Size Classes

**What is TRUE at the end:** Memory allocation uses size-class arenas; arena growth is via mmap; allocation and free are O(1) on average; heap is addressable and traversable.

**Tasks:**

1. **Size Classes:**
   - Define size classes: 16, 32, 64, 128, 256, 512, 1024, ... bytes, up to ~1 MB.
   - Each size class has a free list and an arena (one or more mmap regions).
   - Allocation: find size class for the requested size (round up), pop from free list. If empty, mmap a new arena and populate its free list.
   - Free (after mark): add chunk back to its size class's free list.

2. **Arena Structure:**
   - One arena = one contiguous mmap region (e.g., 16 MB or 32 MB per arena).
   - Arena header: size, number of free chunks, free list.
   - Chunks within the arena are sized uniformly (all chunks in a size-16 arena are 16 bytes).
   - Arena is addressable: given a pointer, the allocator can find its containing arena and size class.

3. **Large Objects (> ~1 MB):**
   - Allocated via direct mmap, one object per mmap region.
   - Freed directly via munmap.
   - Tracked separately (large-object list).

4. **Platform Integration:**

   **Linux (x86_64, aarch64):**
   - `mmap(PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)`.
   - `munmap(addr, size)` to free.
   - Page size: 4 KiB (portable; do not assume).

   **macOS (x86_64, arm64):**
   - `mmap(PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)`.
   - `munmap(addr, size)` to free.
   - Mach VM is available but mmap is sufficient.

   **Windows (x86_64, arm64):**
   - `VirtualAlloc(NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE)`.
   - `VirtualFree(addr, size, MEM_RELEASE)`.
   - Granularity: 64 KiB allocation granule, 4 KiB page granule.

   **wasm32 (wasi):**
   - No mmap. Use `memory.grow(delta_pages)` (iyi has this primitive per decision #4).
   - Manage heap manually within linear memory: watermark allocator for now (allocate from the end of used memory; no freeing until next collection).
   - Deferred complexity: fragmentation management via free lists in wasm32 heap.

5. **Allocator State:**
   - Global allocator lock (fine-grained or per-arena later).
   - Arena list: traversable for GC root scanning and heap statistics.
   - Free lists: per size class, per arena or global (measure before choosing).

**Verification:** Allocate and free objects of various sizes; verify no corruption; inspect arena structure; measure allocation speed (should be O(1) or close).

---

### Stage 3: Root Discovery (Conservative, Precise in Scope)

**What is TRUE at the end:** STW is not implemented yet, but the mechanisms to find roots are in place: stack bounds are recorded, global segment ranges are known, Fibers are enumerable, and the logic to identify heap pointers exists.

**Tasks:**

1. **Stack Bounds (per Thread/Fiber):**
   - At thread creation: record `stack_base` (highest address) and estimate initial `stack_top` (lowest address used so far).
   - At fiber creation: record fiber's stack boundaries from the fiber's structure.
   - Conservative stack scanning: every word from `stack_top` to `stack_base` is a potential pointer. If it points into an allocated chunk, mark the target.

2. **Register Scanning (Deferred to Stage 4 with STW):**
   - At STW, read registers from suspended threads.
   - Treat register contents as roots.

3. **Global Segment Scanning:**
   - Identify static memory ranges:
     - **Linux:** `__data_start` to `__bss_end` (from link script or symbols).
     - **macOS:** `__DATA` and `__DATA_CONST` segments (from Mach headers).
     - **Windows:** `.data` and `.bss` sections (from PE header).
     - **wasm32:** Static memory region (compile-time known; no runtime discovery).
   - Conservative scan: every word in the segment is a potential pointer.

4. **Fiber Enumeration:**
   - Maintain a registry of live Fibers (Fiber struct includes a linked-list node or an array index).
   - At GC time, enumerate all Fibers.
   - For each Fiber, scan its stack conservatively.

5. **Pointer Validation:**
   - Given a word-sized value, determine if it is a valid heap pointer:
     - Is it within any arena's address range? (use arena list).
     - Is it within an allocated chunk's bounds? (use chunk headers or a bitmap).
   - If yes, it is a pointer; mark the target object.
   - False positives are safe (conservative scanning); false negatives (missing a live pointer) are bugs.

**Verification:** Write a test that allocates objects and embeds pointers in global memory, stack, and registers; verify that manual root discovery finds them.

---

### Stage 4: Stop-the-World Synchronization

**What is TRUE at the end:** All threads and fibers can be paused simultaneously; their registers and stacks are accessible; the program is paused long enough for a collection phase.

**Tasks:**

1. **Threading Model (iyi/Crystal):**
   - iyi inherits Crystal's Fiber-based concurrency. Fibers are lightweight; many can run on one thread.
   - Threads exist (System threads that run Fibers). At STW, all threads must pause.
   - Main thread initiates collection (a GC trigger: either an allocation request or an explicit call to `GC.collect()`).

2. **Platform-Specific STW:**

   **Linux:**
   - Use `SIGSTOP` (better) or `SIGUSR1` (compatible) to pause threads.
   - `raise(SIGSTOP)` on other threads; they pause.
   - Parent thread waits for all to pause (via `/proc/<pid>/stat` checking thread state, or a barrier).
   - Run collection.
   - `SIGCONT` to resume all threads.
   - Alternative: `ptrace(PTRACE_ATTACH)` on each thread, but `SIGSTOP` is lighter.

   **macOS:**
   - Use Mach `thread_suspend()` to pause threads.
   - Enumerate threads via Mach kernel; call `thread_suspend()` on each.
   - Run collection.
   - `thread_resume()` to resume all.

   **Windows:**
   - Use `SuspendThread(thread_handle)` on each thread.
   - Get thread context via `GetThreadContext()` to access registers.
   - Run collection.
   - `ResumeThread(thread_handle)` to resume.

   **wasm32:**
   - Single-threaded; no STW needed. Collection happens at a cooperative yield point (e.g., at the end of a Fiber's `yield`).

3. **Safe Points:**
   - A thread can only be paused safely if it is not inside an atomic operation or a signal handler.
   - For now (Stage 4), assume all threads are at safe points (i.e., in user code, not in libc).
   - Deferred: add explicit safe-point checks for long-running operations (e.g., polling inside a library).

4. **Register & Stack Access:**
   - At STW, read the suspended thread's registers and stack:
     - **Linux:** Read from `/proc/<pid>/task/<tid>/regs` (via `ptrace`).
     - **macOS:** Extract from Mach `thread_state`.
     - **Windows:** `GetThreadContext()`.
   - Use registers and stacks as additional roots (Stage 3 prepared for this).

**Verification:** Pause a running program with multiple threads; verify they are paused; resume them; verify they continue correctly (no crashes).

---

### Stage 5: Marking Phase (Tri-Color, Single-Threaded STW)

**What is TRUE at the end:** Live objects are correctly marked. Unreachable objects remain white. The mark representation (tri-color) supports the parallel marking of Stage 6.

**This is the point of no return.** Once the compiler emits pointer maps and the GC marks heap objects, bdw-gc is no longer a fallback. The compiler's parallel codegen depends on garbage collection.

**Tasks:**

1. **Tri-Color Marking:**
   - White: unreachable (to be swept).
   - Gray: reachable but not yet scanned.
   - Black: scanned, live.
   - Invariant: no black object has a pointer to a white object.

2. **Root Marking:**
   - At STW, shade all root pointers gray:
     - Stack: scan conservatively (Stage 3).
     - Registers: scan (Stage 4).
     - Globals: scan conservatively (Stage 3).
     - Fibers: enumerate and shade from their roots.
   - Add all gray objects to a work queue.

3. **Mark Loop (Single-Threaded for now):**
   - While the work queue is not empty:
     - Pop a gray object.
     - Read its `TypeLayout` from the layout table (keyed by `type_id`).
     - If `TypeLayout` is found and matches the object's size, use `scan_offsets` to find pointer fields. Otherwise, conservatively word-scan.
     - For each pointer found: if the target is white, shade it gray and enqueue.
     - After scanning, shade the object black.

4. **Mark Word Atomicity:**
   - Color transitions use CAS on the `mark_word` to be thread-safe (even though marking is single-threaded here; this prepares for Stage 6).
   - E.g., `cas(&obj.mark_word, white, gray)` to shade gray; `cas(&obj.mark_word, gray, black)` to shade black.

5. **False Positives:**
   - Conservative scanning may find pointers that are not actually pointers (integers that happen to alias valid heap addresses).
   - This is safe: marking a white object as gray and then black does not hurt; it is a false negative (failing to mark a reachable object) that is a bug.

**Verification:** Mark the heap manually (with the above algorithm); compare the marked set against Boehm's mark set for the same roots on small programs; confirm match or identify differences.

---

### Stage 6: Sweep Phase & Finalizers

**What is TRUE at the end:** Unreachable objects are freed; heap space is reclaimed; finalizers run.

**Tasks:**

1. **Sweep Iteration:**
   - Iterate over all allocated objects (via arena list and chunk headers).
   - For each white object: add its chunk back to the size class's free list. Re-shade it white for the next collection.
   - For each black object: shade it white (reset for next cycle).

2. **Finalizer Execution:**
   - Before freeing a white object, check if its type has a registered finalizer.
   - Run the finalizer in a safe context (not in an arbitrary Fiber; use a dedicated finalizer queue or thread).
   - Then free the object.
   - Finalizers must not allocate or spawn tasks (enforce in design docs; runtime check deferred).

3. **Weak References:**
   - A weak reference is a pointer that does not prevent marking.
   - At the end of the mark phase, before sweep, walk weak-reference tables and null out pointers to white objects.
   - A weak reference returning `nil` after a collection is expected behavior; no finalizer or error.

4. **Heap Statistics:**
   - Track: bytes allocated, bytes freed, pause time, number of collections, objects finalized.
   - Expose via `GC.stats()` for observability.
   - Emit to metrics if the program links a metrics library (deferred).

**Verification:** Allocate objects with finalizers; collect garbage; verify finalizers run in the right order and at the right time; check RSS before and after collection.

---

### Stage 7: Parallel Marking (Concurrent STW, Multi-Worker)

**What is TRUE at the end:** Multiple threads participate in marking concurrently. Work is distributed and stolen fairly. The object header's mark word supports concurrent color transitions via CAS.

**This is where concurrency and parallelism are realized.** The owner said they want them; this stage delivers them.

**Tasks:**

1. **Work Distribution:**
   - Marking is no longer single-threaded. Multiple worker threads mark concurrently.
   - Shared work queue: thread-safe, append-only until marking is done.
   - Each worker: pop gray objects from the queue, scan them, enqueue pointer targets.
   - Synchronization: work queue uses locks or atomic CAS. Optimize after correctness.

2. **Work Stealing:**
   - If a worker's local queue is empty, it steals from other workers' queues.
   - Reduces global lock contention.
   - Deferred to Stage 7b (measure first).

3. **Mark Completion:**
   - When all workers' queues are empty and no worker is scanning, marking is complete.
   - Coordinate via a barrier or a completion counter (atomic decrement until zero).

4. **Write Barriers (Active, from Stage 1 Design):**
   - Mutators continue to run during marking (concurrent marking); they emit write barriers.
   - Write barrier: before a heap-to-heap pointer write, check if source is black and target is white. If yes, shade target gray.
   - Implementation: codegen (instrumented in Stage 1) calls a barrier function or inlines the check.
   - Barrier function is cheap: an atomic CAS on the mark word; most writes do not cross the black-white boundary.

5. **Pause Phases:**
   - Brief initial pause (STW): shade roots gray; start marking threads.
   - Concurrent marking: mark runs while mutators run and emit barriers.
   - Brief final pause (STW): rescan roots and stack (changed while marking ran); mark any new gray objects; mark all workers as black.
   - Sweep: not STW; can happen concurrently with mutators (deferred; measure first).

**Verification:** Spawn multiple tasks; allocate heavily; verify mark completes correctly; check for missed or over-marked objects; measure pause time and throughput.

---

### Stage 8: Concurrent Sweeping & Finalization

**What is TRUE at the end:** Sweep does not require STW. Finalizers run asynchronously in a dedicated thread. Memory is reclaimed while the program runs.

**Tasks:**

1. **Non-STW Sweep:**
   - After mark phase (all workers idle), start a dedicated sweep thread.
   - Sweep iterates over arenas and chunks; does not hold a lock (or minimal locking).
   - Mutators can allocate from un-swept arenas (using a different free list or bitmap).
   - Built, not as planned: no dedicated thread, but slices of an arena from a cursor, taken by the mark's helpers after every collection and by an allocating thread for the slice it needs (the footprint section's account of Stage 8).

2. **Finalizer Thread:**
   - Finalizers run in a dedicated thread (not in the marking threads, not in mutator threads).
   - Finalizer queue: populated during sweep.
   - Finalizer thread: dequeue and run, one at a time.
   - If a finalizer allocates, it can trigger the next collection immediately; ensure no deadlock.

**Verification:** Collect garbage; verify finalizers run asynchronously; measure time between sweep start and mutator resume.

---

### Stage 9: Incremental Marking (Measured, Optional)

**What is TRUE at the end:** Pause time is predictable and small (e.g., < 10 ms). Marking happens in incremental bursts instead of one long STW.

**Only if:**
- Measurements show concurrent marking from Stage 7 is insufficient (pause still > 100 ms on large heaps).
- Predictability is a requirement (e.g., interactive apps with strict latency budgets).

**Approach:**
- Divide marking into multiple STW bursts, each < 10 ms.
- Between bursts, mutators run (with write barriers active).
- On the next burst, resume from where the previous burst left off.
- Requires careful synchronization (work queue, barrier).

**Decision:** Measure first (Stage 7). Do not implement unless needed.

---

### Stage 10: All Four Platforms (Windows & wasm32)

**What is TRUE at the end:** GC works on all four targets: Linux, macOS, Windows, and wasm32. Pointer maps account for platform-specific sizes and alignments.

**Tasks:**

1. **Windows Integration:** (Completed for x86_64)
   - STW: `SuspendThread()` and `GetThreadContext()` for register capture.
   - Allocator: `VirtualAlloc()` / `VirtualFree()` arenas, MAP-aligned via reserve/release/commit loop; `PAGE_READWRITE`, and a page release that decommits and commits again, so a released page reads zero the way `MADV_DONTNEED` leaves one (`MEM_RESET` did not: `bench/reuse_integrity.sh`).
   - Root discovery: PE header parsing for `.data` and `.bss` ranges (omitting `.rdata` to avoid scanning read-only constants); TEB stack bounds (`StackBase` at `gs:0x08`, `StackLimit` at `gs:0x10`); callee-saved registers (rbx, rbp, rdi, rsi, r12-r15) via `spill_registers` (64 bytes).
   - Test: `bench/windows_exercise.iyi` and `bench/windows_exercise.sh`, executed in CI on `windows-2022` (`windows-collector` job).

2. **wasm32 Integration:** (Completed for wasm32-wasi)
   - Allocator: linear memory watermark with 64 KiB size-classed arenas, chunk headers, and free list reuse.
   - Root discovery: linear memory scan from stacksave to __heap_base, and globals from 0 to __data_end.
   - Mark and sweep: mark-queue with layout table traversal; sweep into free lists and large object tracking.
   - Verified: bench/wasm32_exercise.sh passes under wasmtime in default and release modes.

3. **Platform-Specific Pointer Maps:** (Measured and verified)
   - Codegen emits target-specific TypeLayout entries for each build target based on LLVM target data.
   - On wasm32, pointer fields and allocations take 32-bit sizes and alignments (e.g. 16 bytes vs 32 bytes on 64-bit host).
   - .iyimod artifacts strictly record target_triple in their header and reject mismatched imports at compile time; entries do not need extra target keying.

**Verification:** Build and run samples on all four platforms; verify collection works; measure RSS and pause time.

---

## The Asymmetry: Pointer Maps as iyi's Advantage

gcry's layout.cr reverse-engineers type layouts from outside the compiler:
- Walks `Reference` subclasses with a macro.
- Maintains a blacklist of unsafe prefixes (`Crystal::`, `LibC::`) whose layout cannot be trusted.
- Hardcodes field offsets for Crystal's `Hash` internals.
- Falls back to conservative word-scanning when unsure.

From github.com/sdogruyol/gcry/blob/master/src/gcry/layout.cr:
```
# Compile-time prefix blacklist. Types whose ivar layout Crystal guarantees
# to keep stable across versions (built-in stdlib) get precise offsets via
# the macro walk below; types in these prefixes ("Cry", "Crystal::",
# "LibC::") change shape across versions or carry platform-specific
# conditional fields that the macro cannot see. Skip them: they keep
# conservative scanning, which is safe.
UNSAFE_PREFIXES = {"Cry", "Crystal::", "LibC::"}
```

**iyi emits the same table exactly**, for every type, with no macro walk, no blacklist, no hardcoded offsets, and no fallback to conservative scanning (except when a type is genuinely unknown at runtime, which is an error or a dynamic load). The compiler has the layouts; it computes them while building the type; it emits them directly into `.iyimod`. This is the fundamental asymmetry that justifies ownership.

---

## Concurrency Coupling to III.4 (Structured Concurrency)

III.4 defines structured concurrency: tasks are spawned inside a `group`, and the group's block cannot exit until all tasks finish. The GC must respect this boundary.

**Stage 7 Integration:**
- Each spawned task is a Fiber. The task group is a collection of Fibers.
- During STW, only Fibers in the active task set are paused. Fibers from completed groups are not live (they are not roots).
- The GC can enumerate active task groups and pause their Fibers selectively.
- No task can escape an STW pause (enforce in the task scheduler; a task cannot block or run during marking).

**Write Barriers & Cancellation:**
- A task can be cancelled by its group. Cancellation is a control-flow event (not an exception, not a signal).
- Write barriers do not need to know about cancellation; barriers run before the write happens.
- If a task is cancelled, it unwinds (or stops gracefully); any objects it allocated are reclaimed by the next collection.

---

## What gcry Measured (Prior Art)

From github.com/sdogruyol/gcry/blob/master/README.md and docs/:

**Throughput:** "gcry runs at ~87% of Boehm's throughput with ~0.80x the RSS (Linux)." On Kemal (a web framework):
- Kemal `/json` throughput: ~87% of Boehm.
- Post-GC RSS: ~0.80x Boehm.
- Kemal `/` throughput: ~82% of Boehm.

**What moved RSS:**
> "Finalizer correctness and a retain policy closed the fat-app gap while precise stacks did not."

From docs/STACK_MAPS.md and measurement data: Stack-map precision cost approximately 2x overhead with no RSS win on the tested workloads.

**Root-Discovery Bugs:**
- gcry took until v0.19 to close suspended-register cases (reading the suspended thread's register state correctly).
- Fiber stack scrubbing (writing specific patterns to detect whether a stack slot was ever used) was measured as throughput-neutral (~0.1% on Kemal).
- Static root blacklisting (ignoring certain global segments to reduce false positives) did not hurt RSS but caught some edge cases.

**Implication for iyi:** The same bugs (suspended-register cases, fiber stack bounds) will appear in iyi's collector. Inherit the solutions; do not rediscover them. Use similar stress and fuzz testing to catch them early.

---

## Correctness: Stress, Fuzz, Soak, Invariants

### Stress Testing

- Allocate, write, read, deallocate in a tight loop.
- Vary object sizes, reference graph shapes, collection frequency.
- Run for hours; measure peak memory, pause time, output correctness.
- Environment: `GC_STRESS=1` (trigger collection every N allocations, e.g., 100). Finds bugs that appear only when collection is frequent.

### Fuzzing

- Generate random object types and allocations.
- Allocate, build reference graphs, collect.
- Verify live objects are reachable from roots, dead objects are freed.
- Tool: libFuzzer or similar. iyi's samples are good fuzz inputs.

### Soak Testing

- Web server (Kemal) under synthetic load for 24+ hours.
- Monitor RSS, pause time, response latency.
- Trigger manual collections to verify pause/resume.

### Heap Invariant Checker

- Build flag: `GC_DEBUG_INVARIANTS=1`.
- Checks at collection boundaries:
  - Every object has a valid `type_id`.
  - Every scan offset is within `[0, scan_cap)`.
  - Every marked object is reachable from a root.
  - Free list is consistent.
- Crash on violation; dump heap state.

---

## The Verification Gate

**File:** `bench/dependency_floor.sh` (extended).

**Enforces:**
1. An iyi program compiled with `-Dgc_none` (default, no collection) links only libc (Linux), libSystem (macOS), kernel32 (Windows), wasi (wasm32).
2. An iyi program compiled with `-Dgc_gcry_internal` (iyi's own collector, once Stage 2 is done) links only platform libc plus atomic/concurrency symbols (pthreads on some platforms, Mach primitives on macOS).
3. New symbols must be justified by SPEC.md or Appendix B.
4. Regression detected: CI fails if a commit adds a symbol.

**Behavior:**
- Green: program links only expected symbols.
- Red: new symbol found. Author updates the expected list with SPEC.md justification.

**Example:**
```bash
iyi build samples/hello.iyi -o hello
nm -u hello | awk '{print $1}' | sort > /tmp/actual.txt

# Expected (Stage 4+):
# Linux: write, exit, memset, malloc, realloc
#        + mmap, munmap, signal (STW)
#        + pthread_atfork (fork reinit)
# macOS: + above but from libSystem
# Windows: VirtualAlloc, VirtualFree, SuspendThread, GetThreadContext, ... (kernel32)
# wasm32: wasi_fd_write, wasi_proc_exit (+ libc malloc/realloc for wasm32)

# Compare
diff /tmp/expected.txt /tmp/actual.txt > /dev/null || {
  echo "ERROR: New symbols found"
  comm -13 /tmp/expected.txt /tmp/actual.txt
  exit 1
}
```

---

## Summary: The Stages in Order

1. **Stage 1:** Pointer maps in `.iyimod`, object header design for tri-color marking, write barrier infrastructure.
2. **Stage 2:** mmap-backed allocator, size classes, arenas, platform integration.
3. **Stage 3:** Root discovery mechanisms (stack bounds, globals, fibers), pointer validation.
4. **Stage 4:** STW synchronization (platform-specific signals/Mach/Windows APIs).
   - **Point of no return:** Compiler depends on collection; bdw-gc fallback is gone.
5. **Stage 5:** Tri-color marking (single-threaded STW).
6. **Stage 6:** Sweep, finalizers, weak references.
7. **Stage 7:** Parallel marking (concurrent STW, multiple workers, work stealing, write barriers active).
8. **Stage 8:** Concurrent sweep, finalizer thread (optional; measure if necessary).
9. **Stage 9:** Incremental marking (optional; measure if necessary).
10. **Stage 10:** Windows and wasm32 support.

---

## The One Decision That Most Changes Its Size

**Parallel marking as a built-in design principle (Stage 1), not an add-on (Stage 7).**

The object header's mark word, the tri-color invariant, the write barrier infrastructure, and the work queue are all designed in Stage 1 to support concurrent marking. If parallel marking were an afterthought (added in Stage 7 by redesigning the mark representation), the cost would be a rewrite of Stages 1 to 6. By designing for parallelism from the start, Stage 7 is an implementation detail (adding worker threads), not a redesign. This is the difference between owning a collector and reimplementing gcry's single-threaded shape.
