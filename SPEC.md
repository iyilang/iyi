# iyi Language Specification: Draft 0

**iyi is a language built for Developer & Agentic Experience, Portability,
Performance, and Efficiency.** This document is the design under that sentence:
one rule — a module is compiled against its dependencies' declarations, never
their bodies — and what every other part of a language has to become for it to
hold. iyi is compatible with Crystal — the same compiler builds `.cr` files and
an iyi program can require a shard — and it is its own language, because the
rules below are ones Crystal does not have and cannot have. The compiler being
built on Crystal's is a fact about provenance rather than about the language.

**Status: draft for discussion. Parts of it are built. Each section says which,
and a heading that does not say so is a heading to distrust.** The current
compiler reports `0.2.0-dev`; Part I records what 0.1.0 proved.

This draft deliberately does *not* re-describe the six rules. Each has been
validated on its own: by the Kemal port, by the instantiation census, by the
runtime benchmark. What has never been checked is how they behave **against each
other**, and that is where language projects fail. So Part II, the interaction
matrix, is the substance of this document.

Decisions are marked:

- **SETTLED**: follows from measurement or from a rule already accepted.
- **PROPOSED**: my recommendation, with reasoning; yours to accept or reject.
- **OPEN**: genuinely undecided, needs a call.

---

## Part I: Premises

The compilation model, stated only as far as Part II needs it.

| Rule | Premise |
|---|---|
| R-1 | A module is the unit of compilation. `import` forms a DAG. Compiling a module reads only its dependencies' **export metadata**, never their bodies. |
| R-2 | Everything a module exports (`pub`) carries full parameter and return types. Non-exported code infers. |
| R-2b | `using` brings a module's exported names into unqualified scope, written by the consumer. A `using` imports the module it names. |
| R-2c | **Definition-site typing.** A def whose parameters and return are all written is typed at its definition, caller or no caller — R-2's declared types stand in for the missing call. A trait-restricted parameter is typed too: the bound is written, and a bound is enough — the compiler synthesizes one witness type per simple trait, implements its abstract requirements as stubs, and types the body against exactly the bound, so a generic body cannot quietly use what it did not declare (the half duck-typed generics never check and Rust checks always). `pub` is not the condition: a module's unmarked function, a type's `private def`, a type the module never marked `pub`, and a method an `impl` block gives a type are typed at their definition too, since the probe is the definition asking about itself and R-2's wall is for callers. Each def is typed on its own, so every one that does not type is reported, not the first. Out of reach and stated: supertrait/generic/associated-type traits, block-taking and unannotated defs, operator-named defs, defs of a mixin `module` (whose `self` is the includer's), `.cr` sources. *(Added with the agentic waves: a build, `check`, and the LSP may not disagree about what "clean" means. Mechanism: `semantic/definition_typing.cr`, probes from resolved signatures under `if false`, anchored at the def. First catch: this spec's own gate fixture — a signature edited to `Int64` over a body still returning `Int32`.)* |
| R-3 | Open classes are gone. `impl Trait for Type` must live in the module defining the trait or the type. |
| R-4 | Generic calls crossing a module boundary pass a dictionary keyed on GC shape. Within a module, monomorphisation. `@[Monomorphize]` forces specialisation across a boundary. |
| R-5 | Macros are derive-scoped: they see the declaration they are attached to, and nothing global. |

Union types, nil-safety flow typing, blocks, local inference and Ruby syntax are
kept unchanged from Crystal. They cost the compiler nothing.

---

## 0.1.0: what the first release has to prove

### What it shipped, in numbers that are current

**Everything else in this document is a record of how these were arrived at,
including tables that were true at the time and are not any more.** When a
figure here disagrees with one further down, this one is the release's.
Measured 2026-08-17 on one Linux box, release compiler, in a state the benches'
own reference accepts.

| | |
|---|---|
| edit one module, rebuild (30 modules, 7,207 lines) | **iyi 0.13 s**, Crystal 1.17 s, `go build` 0.16 s |
| the same edit with no artifacts | 0.23 s, which is what R-1 is worth here |
| warm full build, `hello` / 6,900-line pair | 0.07 s / 0.24 s, against `go build`'s 0.08 s / 0.09 s |
| front end, `hello.iyi` | **0.036 s** against the 0.050 s target: MET |
| starting the compiler and doing nothing | 0.018 s of that |
| iyi's own prelude | 17,511 lines, of which 3,509 are the library held to the 3,734 ceiling (5,031 with every platform's floor, which the ceiling stopped counting after Windows); the rest is the collector, the scheduler and the float printer, which 0.1.0's prelude got from libgc, pthreads and libc |
| compiler | 116,466 lines, none of it written in iyi |
| artifact format | `.iyimod` v54, checksum per section |
| samples | 27 programs, of which 12 rebuild from artifacts with their modules' source deleted |
| what runs in CI | iyi's specs, Crystal's 13,798 compiler examples, the standard library's, the CLI's, the samples, nine targets iyi's own prelude type-checks for, seven whose own-prelude emitted objects are audited for undefined symbols, the tarball |

`python3 bench/incremental.py` and `python3 bench/build_speed.py` print the
first four rows and refuse to time programs that do not agree on their output.

### Scope

Everything below this line is design. This section is scope, and it is here
because the rest of the document is easier to read once it is known which parts
of it the first release is allowed to need.

**0.1.0 is not a usable language.** It is the smallest artifact that lets
somebody who did not write it check the central claim and find it false. Nobody
will write production code with it, there will be no standard library worth the
name, and it will not be self-hosted. Go's first public release was the same
shape.

> **What changed after it shipped, and it changed this paragraph.** A prelude
> is a library and the rules are the language, so a program can keep one and
> change the other: `--crystal` builds against Crystal's standard library, and
> there `require` reaches the ecosystem while every rule stays where it was.
> "No standard library worth the name" is still true of iyi's own 17,511 lines
> and no longer true of what a program can have. Part V item 12a is the
> measurement, nine shards wide.

**The claim under test** is compile speed. The type system is the means, not the
product: open classes go so that a module can be compiled against its
dependencies' metadata instead of their bodies (R-1, R-3), and that is what
makes a build incremental. A release that ships the type system without the
speed has shipped the cost and none of the benefit.

### In scope

**1. `.iyimod`, end to end (IV.1). Built.** Not negotiable. R-1 is the rule the
rest of the document is built on, and without the artifact everything here is a
design document. The container, the `Header`, `Imports` and `Exports` sections,
`--emit-iyimod` and `mod dump` are built, and `--use-iyimod` compiles an
imported module from its artifact: all eight samples compile with the imported
module's source **deleted**.

`ObjectCode` carries a module's own machine code, and **a program built from a
module's artifact with the module's source deleted runs**. The thing here that
produces a program rather than a typecheck.

Of the five samples that import anything, **all five** do: `modules`,
`immutable` (a generic type, a 575-line trait with an associated type, a generic
impl), `collections` (the trait implemented by a type the artifact's module has
never heard of), `init_order` (III.5's ordering, line for line) and `webapp`,
the Kemal port, which took the whole of IV.1g to reach. Each builds, links,
runs, and prints what the build from source prints. IV.1g measures all of it,
and records what was in the way.

**2. The passes that still walk the prelude stop walking it (IV.1d). Measured
away, and what was actually in the way is fixed.** The claim this item was
written on was measured against Crystal's 107,719-line prelude: 0.47 s left
after the artifact, of which class-var initializers and `main` were 90%. Item 3
replaced that prelude with 1,053 lines of iyi, and the number this item exists
to remove does not exist any more. What the item became is the link, and the
link is now 0.026 s of a 0.09 s warm build of `hello.iyi`, against `go build`'s
0.12 s on the same machine. **That is a win at the size of `hello` and the
bench's second pair says so**: at 6,900 lines the same comparison is 0.23 s
against 0.09 s, because what was removed here was fixed cost. From
`bench/build_speed.py` on a release compiler, `hello.iyi`, seconds. The middle
column is where this morning started:

| | before | after |
|---|---|---|
| warm build | 0.26 | **0.09** |
| of what the compiler times in it, the **link** | 0.132 (85%) | **0.026 (45%)** |
| front end alone (`--no-codegen`) | 0.041 | 0.047, of which 0.023 is startup |
| the same front end, no LLVM linked into the binary | 0.02 | 0.03 |
| `go build`, warm | 0.10 | 0.12 |

Two things were in the way and neither was analysis: a search for a linker
nobody installed, and a driver working out the same link command on every
build. Both are below.

Inside that front end the top-level pass is 0.012 s and **the five passes this
item asked to fix cost 0.4 ms between them**: 2% of what is left, where the
item says 90%. That is the compiler's own `--stats`, per pass, on a warm build
of a program that is one `puts`, which is the measurement the item is about: it
asked those passes to stop walking *the prelude*. They cost more on a program
with something in it: `main` is 4.6 ms on `hello.iyi`, and that difference is
the user's own code being typed, which no cache of anything removes.

**What replaced it is the link, and a third of what looked like the link was
not the link.** Nearly everything a warm build spends is inside the linking
stage, on a program whose object files were every one of them reused and whose
own code is three lines. The first reading of that was wrong, and the way it was
wrong is worth the space: the stage measured 0.29 s by default and 0.18 s with
`--link-flags=-fuse-ld=gold`, which says the default linker is the slow one.
Running the compiler's own link command by hand takes **0.13 s with either
linker**. The flag was not choosing a faster linker. It was skipping a search.

Before linking, `use_modern_linker` looks for `mold`, then for `ld.lld`, and
prefers whichever it finds, and it returns without looking if the flags already
name a linker, which is what `-fuse-ld=gold` did. `Process.find_executable`
walks `PATH`, and a name that is *not* on `PATH` costs a stat in every entry of
it. That is a millisecond on an ordinary Linux box. Under WSL, where `PATH`
carries nineteen Windows directories on a filesystem that answers a stat in
about 6 ms, it is **0.062 s per search, twice per build**. A third of every
build was the compiler looking for two linkers that were not installed, and the
flag that appeared to fix it only skipped the looking.

**Fixed, and the fix is a cache rather than a policy.** The answer is written
next to the object cache and read back while the `PATH` it was found under is
unchanged; changing `PATH` asks again. The default build and the
`-fuse-ld=gold` build now measure the same, which is the result that says the
linker was never the difference. A warm build of `hello.iyi` went from 0.26 s to
**0.17 s** for twenty lines of caching, against Go's 0.10 s: the gap this
project exists to close is 1.7× where it was 2.9× this morning, and none of it
came from compiling anything faster.

What is left of the link is `ld` doing its job on eleven objects and libgc:
0.132 s, and still 85% of what the compiler times.

**And that part was not the linker at all.** Linking a one-object C program on
the same machine cost the same figure, so it was never about iyi's eleven
objects, but it was not about `ld` either. Measured on the same objects in the
same minute: `cc` takes **0.129 s**, and the command `cc` would run, with
`collect2` replaced by the linker itself, takes **0.014 s** with `ld.bfd`,
0.009 s with `ld.gold` and 0.023 s with `ld.lld`. Three linkers within 14 ms of
each other, and a driver worth 0.11 s on top of any of them.

`cc` does not link. It works out how to: the dynamic linker's path, `Scrt1.o`,
`crti.o`, `crtbeginS.o`, the `-L` directories, `-lgcc -lc`, and then it runs
`collect2`, which scans the objects for constructors before running `ld`. All of
that is the same for every build on a machine, and all of it was being redone
on every build.

**So the compiler asks once and links for itself.** `cc -###` prints the command
without running it, including for object files that do not exist, which is what
makes it a template: a placeholder marks where this build's objects go. The
template is cached against the flags it was computed for, the compiler runs `ld`
itself from then on, and a link that fails with it is retried through the driver
with the template marked unusable, so a machine this does not suit pays one
extra link once. `IYI_LINK_DRIVER=1` forces the old path. `clang` has done
this all along. It has no `collect2` and execs the linker itself, which is why
it measures 0.092 s where `cc` measures 0.129 s.

**What it is worth, on `hello.iyi`, warm:**

| | before | after |
|---|---|---|
| the linking stage | 0.143 | **0.019** |
| the whole build | 0.186 | **0.081** |

The bench's own run, with a debug compiler on a busy machine, puts the warm
build at 0.10 s against `go build`'s 0.13 s. **The gap this project exists to
close is closed on this bench**, and what closed it was not compiling anything
faster: it was not asking a compiler driver to work out the same link command
several times a second.

The front-end target this item was written to protect is met on the same run:
0.041 s against 0.050 s, of which 0.018 s is a process linking LLVM before doing
no codegen.

**And that 0.018 s is measured too, because it is the second-largest thing left
and it is not analysis.** An empty C program starts in 0.002 s. The same empty C
program, linked so that `libLLVM.so.19.1` is *loaded* and nothing in it is
called, starts in **0.025 s**. The compiler starts in 0.031 s and the front end
built without a code generator starts in 0.008 s. Those four figures are one
minute's, and it was a slower minute than the table above. The ratio between
them is the measurement, not the absolute. The dynamic loader is 1 ms of it: `LD_DEBUG=statistics` counts
331,639 relative relocations and 2.9M cycles, so what is left is libLLVM's own
static initialisers, running in every `crystal` process whether or not it will
generate code. `crystal-front` is the standing proof that a build that generates
none need not pay it (IV.1a), and making the ordinary compiler not pay it means
loading the code generator when codegen is asked for rather than when the
process starts.

**Two routes to not paying it were tried, and neither is cheap.**

*Load the library when codegen asks for it.* The bindings are a `lib LibLLVM`,
so the library is a `NEEDED` entry and the loader maps it before `main`: the
question is whether the entry can be dropped and the library `dlopen`ed at the
first call. It cannot, not this way: linking with
`--unresolved-symbols=ignore-all` and `-z lazy` produces a binary the loader
refuses to start at all: *unexpected PLT reloc type 0x00*, because what the
linker leaves behind for an undefined symbol is not something lazy binding can
finish. Deferring it properly means resolving every LLVM function through
`dlsym` into a table of pointers, which is a rewrite of upstream's `lib
LibLLVM` and a permanent divergence from it.

*Link LLVM statically, so that the linker keeps only what is reached.* This one
works, and it is worth less than it looks. `LLVM_LDFLAGS` with
`--link-static` builds a compiler once `-lPolly` (not installed here) is
dropped and `zstd` is named by its soname, and the result is a 129 MB binary
that starts in 0.020 s against the shared build's 0.022 s. The reason so
little moves is that the compiler *reaches* five targets: `to_target_machine`
names x86, aarch64, arm, avr and webassembly, so five targets' initialisers are
linked in and run. Measured on a C program that calls exactly those
initialisers: 0.013 s through the shared monolith, 0.006 s statically with the
five, 0.004 s statically with x86 alone.

So the 0.018 s breaks down as about 0.002 s of Crystal runtime, 0.006 s of
target initialisers the compiler genuinely reaches, and the rest the monolith's
every target LLVM ships, in a process that will use one. **Static linking
takes the last part and leaves the middle**, which is 2-5 ms measured, for 75 MB
of binary. It is not made the default on that trade, and the middle needs the
initialisers to run *later* rather than not at all, which is the `dlsym` table
above, and a larger piece of work than the number it wins.

**3. A deliberately tiny prelude, written in iyi. Done: 17,511 lines,
primitives included, of which the library is 3,509.** Not a standard library:
integers, booleans, a string, one sequence, one dictionary, one range, `puts`,
and an `enum`'s surface — the member's name, an order, the members, and the
bits of a `@[Flags]` one. **Its scope is set by what the
samples call and by nothing else**. A method enters the prelude because an
existing sample needs it, never because it belongs there.

**The rule held; the samples were the thing that was wrong.** Writing the six
programs a person writes before they write a module found `(1..10).each`
answering "wrong number of arguments for `Range(B, E).new`" — the compiler
expands a range literal to a constructor and the prelude had never defined the
type — along with no `first`, no `select`, no `includes?` on either a string or
an array, and no `sorted`. None of those is a library ambition; each is the
second or third line of somebody's first program. So the answer was a sample
rather than an exception to the rule: `samples/iyi/basics.iyi` is that half
hour, it is in the samples the prelude is measured against, and the prelude
grew 131 lines to run it. The ceiling is unmoved and the trigger is unchanged:
a program in this repository needs it.

**What the ceiling covers, once the runtime was written in iyi too.** The
3,734 lines were Crystal's *library*: its core files, plus 183 lines of
fibers over pthreads. Its allocator was Boehm's libgc, its float printing
was libc's `printf`, its scheduler leaned on libevent, and none of those
was in the count. iyi's prelude now carries all three itself - the
collector (GC_DESIGN.md, the block between two marks in `prelude.iyi`),
the scheduler and the kernel thread (III.4, `concurrency.iyi` and
`thread.iyi`), the shortest-round-trip float text (`float.iyi`) - and they
are most of its lines. So the figure held to the ceiling is the library:
**3,509 lines** of the 17,491, measured by `bench/doc_numbers.py` as
everything under `src/iyi/` except those three and except every platform's
floor of 1,522 lines — the arms behind `flag?(:win32)`, `flag?(:linux)`,
`flag?(:darwin)` and `flag?(:wasm32)`, which the paragraph on the breach
below settles and explains. Opening `src/iyi/` counts 5,031 with the floor
still in it, and the whole-prelude figure is stated beside both because a
reader sees the whole file, and a "tiny prelude" claim that hid 9,000 lines
of runtime would be a claim about the wrong number.

**And the prelude measures in two units, which is one sentence worth
writing down.** A *character* is what `size`, `each_char`, `chars`, `ljust`
and `rjust` count: UTF-8 code points, decoded. A *byte* is what `bytesize`,
`[]`, `[start, count]` and every search offset (`index`, `rindex`) speak in,
which is the convention `samples/iyi/calc` scans with and the one
`src/std/text.iyi` is written against. Three defects came from methods on
the wrong side of that line: `Char#to_s` wrote one byte of a code point,
`each_char` yielded one character per byte while `size` counted five for
`"héllo"`, and `ljust`/`rjust` padded to a width in bytes, so the one thing
padding is for — lining a column up — held for ASCII and nothing else. Each
was the prelude disagreeing with itself rather than with a standard, which
is why the sentence is here: the two units are a choice, and a method
belongs to one of them.

**And the integers say which arithmetic they are.** `//` truncates toward
zero and `%` takes the dividend's sign — C's pair, and Go's and Rust's, not
Crystal's floor-and-modulo: `-7 // 2` is -3 here and -4 there, and `-7 % 2`
is -1 here and 1 there. Self-consistent, measured across all four sign
combinations: `(a // b) * b + (a % b) == a`. It is written here because it
was not written anywhere, and it is the kind of difference a program carried
over from Crystal keeps silently; `src/std/time.iyi` was checked against
negative epochs and negative spans before this was recorded rather than
changed.

Two values at the edge are the prelude's own to report rather than the
processor's. `Int32::MIN` has no positive twin, so `String#to_i?` - which
built the positive magnitude and negated it - could not read what
`Int32::MIN.to_s` wrote, and because the arithmetic is checked that was a
panic where a `?` promises `nil`; every out-of-range string panicked the
same way. It accumulates a negative magnitude now, and the last digit is
checked before it is used. `MIN // -1` is the other one: the single division
whose result the type does not hold. Left to `unsafe_div` it trapped, and
the program died of "Process terminated because of a floating-point system
exception" for an integer divide - the same unactionable sentence the zero
divisor was checked to avoid, with the overflow beside it left unchecked.
Both are panics with names now, and `MIN % -1` answers the zero it
mathematically is. `bench/number_exercise.sh` holds all of it, with a proof
that asks for SIGFPE itself to show the guard is load-bearing.

**And a value type owes an `==` before it owes a `hash`.** The requirement
runs one way: equal values must hash equally, because a `Hash` finds a key
by its slot and only then compares. A *coarser* hash keeps that requirement,
which is what `Object#hash`'s type id is — every value of the type in one
slot, every lookup a walk, and the comparison still deciding — so the
default is correct and slow. Measured, keyed two ways with 40,000 lookups
each: 2,000 `Array(Int32)` keys, which have an `==` of their own and no
`hash`, answer in 28 ms against 3 ms for the same program keyed by tuples,
and at 4,000 keys it is 104 ms against 8. The broken direction is the other
one, a hash *finer* than `==`: two equal values land in different slots and
the comparison is never reached. Nothing in the prelude does that, and this
paragraph said the opposite for one commit — that a type-id hash "starts
being wrong" once a type defines equality — which the measurement above
replaced.

So what was wrong for `Tuple` was the `==`, not the hash: `Object`'s is
identity, on a value type, so `{1, 2} == {1, 2}` was false, `table[{1, 2}]?`
missed the entry `table[{1, 2}] =` had just made, and `includes?`, `index`,
`uniq` and a `case` arm over `zip`'s own result were all wrong with it.
`Range` had it too, the prelude's other value type: `(1..3) == (1..3)` was
false and a range could not be found in a `Hash` or an `Array`. Both write
both now, and `bench/value_exercise.sh` holds the pair for them the way
`bench/enum_exercise.sh` holds it for enums. `Set` and `Hash` are
references and still compare by identity, which is coherent and is *not*
the same defect — two sets with the same members are two objects — and it
is recorded here because `Array#==` is element-wise beside them, so the
prelude's collections do not answer that question the same way.

**And it sat on the ceiling exactly, on the figure of that day.** A night of probing added the
methods the defects needed - UTF-8 encode and decode, padding in characters,
`==` and `hash` for the two value types, a parser that reads its own
minimum, guards on the one division that overflows, and a character-wise
search - and paid for them by tightening the prose around them: 3,734 of
3,734, when the figure still counted every platform's floor. The rule it
demonstrates is the one that stands: the next method that enters the library
moves something out of it first, and `bench/doc_numbers.py` fails if one
does not.

**The ceiling was breached, and moving two files closed it.** The library
was under 3,734 until `io.iyi`, `socket.iyi` and `format.iyi` were written,
which took it to 4,689 — 955 lines over — and this section recorded the
breach rather than moving the number. Two of the three then answered the
question `src/std/` was created by: nothing in `src/iyi/` calls `sprintf`
and nothing in it opens a socket, so every program was carrying 1,358 lines
for the programs that do. They are `src/std/format.iyi` and
`src/std/socket.iyi` now, reached by `import std/format` and `import
std/socket`, and the library is **3,405 lines**, 353 under. `io.iyi` stays:
it is the write path behind `puts`, which every program has.

**And it was breached again by Windows' own floor — 4,803 of 3,734, 1,040
over — which is what settled the rule.** What entered is not API. It is the platform: the kernel32 names the
runtime calls, moved out of the collector's macro arm so a `-Dgc_none` or
`-Dgc_boehm` build on Windows can link at all; the environment read through
the accessor the C runtime exports, because the POSIX symbol `environ` is
not one of Windows'; `File.exists?` and `File.read` answering for a
directory, which `CreateFileW` refuses to open where POSIX opens and fails
at the read; a UTF-16 path layer, because Windows' narrow entry points read
a path in the process's code page and a name iyi was handed as UTF-8 is not
that; a console writer, because those same code pages are what turned a
Turkish or Japanese filename into mojibake on the way to the screen; a
fault handler that names a stack overflow and an access violation instead
of showing a dialog; a high-resolution timer for the poller's deadline,
because a millisecond timeout on a completion port is rounded up to the
system timer tick and a program that asked to sleep one millisecond slept
15.6; and the 128-bit divide LLVM emits a call to, which
every other platform gets from compiler-rt and Windows-MSVC has nowhere to
get. Each is a declaration or a branch, none of them a method a program
calls by a new name, and each carries the sentence that says why — which is
where most of the 1,040 lines are.

**And the whole breach was that floor, measured by the script rather than
by hand.** Counting the lines inside a macro conditional whose condition
names an OS, architecture or ABI flag — every arm of it, `else` included,
since an `else` under `flag?(:linux)` is what the other platforms take and
exists for the same reason — the platform floor measures **1,522 lines**
of the 4,803, and Windows is the largest arm of it by a wide margin, which
is what a platform whose every path, console byte and integer division
needs its own answer costs.

The first writing of this paragraph counted by hand and gave two figures
that did not agree: 624 lines for Windows' arms and a library of 3,618,
which is that one platform subtracted from a sentence about every
platform's. Both numbers are the script's now (`platform_floor`,
`library_with_floor`), so the rule below rests on arithmetic that checks.

**Decided: the ceiling stops counting every platform's floor, and the
comparison is fairer for it.** The two answers were a rule or a rewrite.
The rewrite means the library gives back 1,040 lines, which at this size
means giving back a method a program calls — and the lines it would give
back are not the ones that entered, because what entered cannot leave:
Windows cannot be spelled without `kernel32`, a path without UTF-16, a
128-bit divide without the four functions LLVM emits a call to. So the
rule: the figure excludes the arms behind `flag?(:win32)`,
`flag?(:linux)`, `flag?(:darwin)` and `flag?(:wasm32)`, symmetrically,
and the library is **3,509** of 3,734 with 225 to spare.

What makes it the honest reading rather than the convenient one is what
3,734 is measured against. Crystal 0.1.0's core did not carry its own
floor: its allocator was libgc, its float printing libc's `printf`, its
scheduler libevent, and its platform calls were libc's — none of it in the
8,161 lines, let alone the 3,734. iyi's prelude carries all of that, and
the three largest pieces were already excluded for exactly this reason
(the collector, the scheduler, the float printer). The platform floor is
the fourth piece of the same kind: not a method a program calls by a new
name, but the price of reaching a kernel without a C library in between.
Counting it was comparing a library that carries its floor against one
that did not.

What the rule does *not* forgive: a `pub def` a program calls is API and
counts wherever it is written, macro arm or not — the exclusion is for the
platform's own answer to a question the library already had, not for a
name that only exists on one platform. And the ceiling is a check now
rather than a habit: `bench/doc_numbers.py` fails when the library is over
it, which is what 508 lines walking past a paragraph made necessary.

The move a reader would still like — the Windows floor in one
`src/iyi/windows.iyi` rather than several macro arms of an 8,283-line
prelude — is worth making and moves this number by nothing, since the
exclusion is by condition rather than by file.

**Moving them broke Windows, and what broke was already broken.** With the
two files out of the prelude, `bench/tls_probe.iyi` exited `0xC0000005`
after printing `PASSED` where the same probe on the same runner had exited
0 — and the two cross-compiled objects differed by nothing but two absent
types and the addresses that shift with them. `@[ThreadLocal]` was the
reason: `declare_thread_local` forced LLVM's local-exec model on every
target, and COFF has no such model — a thread-local's address comes from
`_tls_index` and the TLS array the loader hangs off the TEB. LLVM put the
datum in `.tls$` and read it as an ordinary global, the same address in
every thread and an address the C runtime owns. The probe had been printing
`value wrong` for exactly that since the day it was written; the exit code
was luck, and a shifted layout spent it. Windows gets the general model
now, the probe prints `value ok`, and the move stands on a platform where
thread-locals work. A number that is "recorded rather than moved" is worth
recording for this reason: the attempt to close it is what found the defect.

The same attempt found that `format.iyi` had been *redefining* `Int64#to_s`
and `Int64#to_s(base)` over the prelude's own with the one shape that does
not overflow at `Int64::MIN`, and declaring `UInt64#//`, `UInt64#%`,
`UInt8#to_s`, `Tuple#size` and `Tuple#[]` that nothing else in the prelude
had. `std/time` divided two `UInt64`s and `std/indexable` walked a tuple
only because a formatter was in every program. Those are the number surface
and the tuple's own arithmetic: they are in `src/iyi/number.iyi` and
`src/iyi/object.iyi` now, one definition each, and `sprintf` asks its own
question — "too few arguments for format string" — where it used to borrow
a raise from an index.

**The standard library is deliberately outside that count, and this is the
answer this section left open.** `src/std/` is 6,057 lines across twelve
modules: `traits`, `cmp`, `enumerable`, `indexable`, `iterator`, `slice`,
`text`, `time`, `format`, `socket`, `list` and `derives`. It is opt-in via
`import std/...`, it lives outside `src/iyi/` where `bench/doc_numbers.py`
measures the ceiling, and a program that imports none of it pays for none of
it. So the prelude rule keeps its meaning, "a method enters because a
program in this repository needs it", and the number it is held to is the
one the rule named.

The ceiling was not a guess. Crystal's own 0.1.0 shipped 8,161 lines of
library. Its core is **3,551 lines** of that: `object`, `nil`, `bool`, `char`,
`int`, `float`, `number`, `string`, `array`, `hash`, `range`, `enumerable`,
`comparable`, `io`, `pointer`, `exception`, `raise`, `main`, `prelude`. The rest
is `json`, `yaml`, `http` and `option_parser`, which are libraries rather than a
prelude.

When the prelude took on concurrency (III.4), the same-purpose rule moved
the number the way it was always measured: 0.1.0 also shipped concurrency —
`thread.cr` at 70 lines and `fiber/` at 113 — and the core list above had
left it out, because on the day the list was written iyi's prelude had no
concurrency to compare it against. A prelude that carries a scheduler is
measured against a core that carries one: **3,551 + 183 = 3,734**, remeasured
from the 0.1.0 tree rather than reasoned about. The trigger is unchanged —
a line enters because a program in this repository needs it — and the gap
between 8,161 and the core is what it always was: `json`, `yaml`, `http`
and `option_parser` are libraries, and stay out.
3,551 lines was the number to stay under, measured in the same language family
and for the same purpose. `src/iyi/` came in at 833, and **all the samples
run on it with output identical to what they print under Crystal's prelude**,
which is the acceptance test: the samples are the documentation, so a prelude
that changed what they printed would have changed what the documentation says.
A `.iyi` entry file gets it by default; `--prelude` still wins, and a `.cr`
file is untouched.

| | measured |
|---|---|
| front end, `hello.iyi` | 1.41 s → **0.13 s** |
| whole build, `hello.iyi` | 2.10 s → **0.32 s** |
| whole build, `webapp.iyi` | 2.17 s → **0.36 s** |

**And then the same rule applied one level down.** With Crystal's prelude gone,
0.11 s of the remaining 0.17 s front end was `src/primitives.cr`, not its 581
lines but its shape: twelve numeric types crossed with each other is 2,580
`@[Primitive]` definitions macro-expanded on every build. Measured by deleting
the block and building again, which took the front end to 0.02 s.

So iyi has its own. **`src/iyi/primitives.iyi` crosses five types**: `Int32`,
`Int64`, `UInt8`, `UInt64` and `Float64`. The default integer, the one a byte
count grows into, the byte, the one an address and a size are, and a float.
That is 445 definitions, and it took the front end to 0.07 s. `Int8`, `Int16`,
`Int128` and the unsigned middle exist as types and have no arithmetic;
`1_i8 + 1_i8` is an undefined method. **This is a language-visible decision,
not a library one**. It is the same rule as the rest of the prelude (a thing
enters because a sample writes it) applied to the one file where the cost is
quadratic. What it does not decide is implicit promotion: the five types cross
each other exactly as Crystal's twelve do, so `1 + 1_i64` still works. Whether
iyi keeps that or takes Go's line and demands an explicit conversion is open,
and cheaper to answer now that the block is small enough to read.

Three decisions made it that small, and each is a thing 0.1.0 does not have
rather than a trick. **There is no `IO`**: `puts` writes to fd 1 and `to_s`
returns a `String`, which removes buffering, encodings and the class hierarchy
under them. The largest single saving against Crystal's core. **`raise` is a
panic** (III.1.4): it unwinds by registry rather than by frame — `defer`
registers its cleanup on the way in, the panic path walks the list — so
there is still no unwinder, no personality function and no exception
hierarchy, and the three `__crystal_*` symbols that a program with an
`ensure` in it must link remain stubs that say they cannot be
reached. **Strings are ASCII** wherever a method has to look inside one,
`upcase`, `starts_with?`, though `size` decodes UTF-8 properly, because a
sample counts the characters of a word with an accent in it.

What it is not (as of 0.1.0; `Float64#to_s` arrived in 0.11.0, `Range`
before it, `Hash#delete` and `Set` after it): no `Float64#to_s`, no `Range`, no `Set`, no formatting, no
`Comparable`, no deletion from a `Hash`, and `sort` is an insertion sort
because the samples sort five elements. Each of those is absent because no
sample asked, which is the rule doing its job rather than a list of regrets.

**4. IV.6 #6, module naming. Done.** A module is declared `app/greeter` and
reached `App::Greeter`. This appears in every line of user code and could not be
changed once there was user code, so it was settled first. The mismatch stays
and is made reversible instead: a path segment is `[a-z][a-z0-9]*` with single
`_` between groups, so path and type name determine each other. "Lowercase
snake_case" turned out not to be enough: `v_1` and `v1` both give `V1`.

**5. A benchmark that produces the claim, and a check that fails until it
holds. Built.** `bench/` already priced macros and `Share`; build speed was the
one number the project exists for and the one with no committed harness.
`bench/build_speed.py` is it, and its first run is below. Its corpus was one
program, because `hello` is the only pair where "the equivalent Go program" is
unambiguous and because iyi had no other program to offer, which made growing
that corpus a dependency of this item on item 3, not a nicety.

**Grown, and the ambiguity is gone rather than argued away.** The second pair is
generated: `bench/build_speed/generate_pair.py` emits the iyi and the Go halves
from one loop, and the bench runs both and refuses to time them unless they
print the same thing. At 300 types it is about 6,900 lines, which is the size at
which user code is the bill rather than the fixed costs, and the first
measurement of it takes back the warm win the previous run recorded. See "Done
is a number" below.

**Where the five stand.** One is built and the eight samples compile with the
imported module's source deleted. Two is answered: the passes it named cost
0.4 ms, and the two things that did cost. A `PATH` search per build and a
driver rebuilding the same link command: are fixed, which is what took
`hello.iyi`'s warm build to 0.09 s against Go's 0.12 s. Three and four are done;
five is done and its second pair is what says that win is a win at that size,
at 6,900 lines Go is ahead 0.09 s to 0.23 s, and iyi is what grows.

**That sentence is true and it is about the wrong program, which the edit-loop
bench says plainly once both benches can run.** `medium.iyi` is 6,900 lines in
**one file**: no module boundaries, so no artifacts, so nothing for R-1 to
exploit — every rebuild retypes and regenerates IR for all of it. Measured on
one release compiler on one machine, that is iyi 0.13 s against Go's 0.02 s,
and the gap is wider than this section records rather than narrower.

`bench/incremental.py` asks the same question of the shape the language is
designed around — 30 modules, 300 types, 7,207 lines — and the ordering
reverses: editing one module's body costs **iyi 0.07 s, Go 0.09 s**, Crystal
0.76 s. The row beneath is what does it: the same edit **without** artifacts is
0.18 s, so R-1 is worth 0.11 s of a 0.18 s build, and it is worth it by reading
twenty-nine modules as declarations instead of as source.

So iyi loses to Go on a monolith and beats it on a project, and the two numbers
are not in tension: one measures a compiler with nothing to cache and the other
measures the thing this design is. What the monolith figure locates is still
worth having — it is the same unstarted work IV names, and it is the ceiling on
how much the single-file case can improve.

**What remains for a release is not on this list**: III.4's concurrency is specified
and unbuilt, and III.5's "no import for side effects" is the one rule here with
a cost and no measurement. Everything else in this section is a number that has
been taken rather than a thing still to do.

### Out of scope, stated so it is not argued twice

III.4 in its entirety: structured concurrency is specified and it is not on
the critical path of the claim. III.5 rule 5's measurement. Cross-version
`.iyimod` compatibility (IV.5 already says this). A package manager. A standard
library. Self-hosting: the compiler is 87,421 lines and iyi's own library is
722, so this is not a near thing and pretending otherwise sets the wrong
priorities. Of the calls still open in Appendix B, only #1 is a taste decision
that would change what 0.1.0 looks like, and deferring it costs nothing.

### Done is a number

1. `bench/build_speed` prints one table, measured on one machine: iyi cold, iyi
   warm, and `go build` on the equivalent program. **The Go column is measured
   there, not quoted from anywhere**. This document has no Go timing in it and
   is not entitled to one until the bench runs.
2. The front end compiles `hello.iyi` in **0.05 s or less**. This is not an
   aspiration: IV.1a already ran a front end that never walks the prelude at
   0.049 s, and it emitted an object with an identical symbol table. 0.1.0's job
   is to make that configuration the ordinary one rather than an experiment.
   **Met: 0.039 s.** Not by the route IV.1a took. The prelude is small enough
   now that there is little left to cache, and two of the three things that
   closed the gap were the prelude and its primitives. The third was the
   instrument; see below.

   The figure was 0.039 s when this was written and it read **0.063 s, NOT
   MET** twice on one afternoon, on a binary that had changed only by
   deletions. Both readings were the same machine compiling something else at
   the time, and the bench has a guard for exactly that: it divides by what the
   compiler costs to start and does nothing when the machine is too slow to
   answer. The guard could not fire, because the reference it divides by was
   recorded when the compiler still carried the interpreter, the playground and
   the documentation generator. That binary started in 0.040 s and this one
   starts in 0.018 s, so every run looked 0.71x — comfortably faster than the
   machine the target was set on — and the bench went ahead and decided. **A
   stale baseline is worse than no baseline**: it does not report a wrong
   number, it turns off the check that would have refused to report one. It is
   re-recorded, and the comment beside it now says the binary counts as much as
   the machine.
3. The end-to-end `crystal build` time is published in the same table even
   though LLVM and the linker dominate it, so that the claim cannot quietly
   become a front-end-only claim.
4. The check for (2) is the bench's own exit status, not a spec. The release is
   a command that passes, not a judgement call. The same standard as the rest
   of this document. **Built:** `python3 bench/build_speed.py` exits non-zero
   while the target is unmet, and names which scope item closes the gap. It is
   deliberately not a `spec/compiler/…` example: one permanently red assertion
   in that suite would cost it the only thing it is good for, which is that a
   failure there means something broke.

**The first run, recorded because a bench with no baseline is a script.** On one
machine, best of three, seconds:

| program | stage | cold | warm |
|---|---|---|---|
| `hello.iyi` | front end (`--no-codegen`) | 1.32 | — |
| `hello.iyi` | end to end | 2.20 | 1.96 |
| `hello.go` | `go build` | 1.98 | 0.18 |
| `webapp.iyi` | front end, iyi only | 1.31 | — |

Three things fall out of it, and none were stated before it ran.

**The fight is the warm build, and it is 11× not 3×.** Cold, the two are level
2.20 against 1.98, because Go is compiling its own dependencies too. Warm,
Go drops to 0.18 and iyi to 1.96, because Crystal's cache only holds codegen
and the front end is redone in full every time. Warm rebuild is what a person
actually waits for, so **11× is the real gap**, and it is almost exactly the
front end: item 1 plus item 2 are worth 1.32 s of the 1.78 s difference.

**Being level when cold is not a consolation, it is a warning.** It means iyi's
cold build is already as expensive as compiling Go's stdlib from source, on a
program that prints one line.

**`webapp.iyi` costs the same as `hello.iyi`**, 1.31 against 1.32. IV.1d found
this on the previous instrument and it still holds on this one: user code is
nearly free and the fixed prelude cost is the whole bill. It is why the target
is set on a one-line program rather than a large one.

**The second run, after item 3.** Same machine, same command, with iyi's own
prelude (833 lines) in place of Crystal's 107,719:

| program | stage | cold | warm |
|---|---|---|---|
| `hello.iyi` | front end (`--no-codegen`) | **0.17** | — |
| `hello.iyi` | end to end | **0.38** | **0.37** |
| `hello.go` | `go build` | 2.54 | 0.16 |
| `webapp.iyi` | front end, iyi only | **0.18** | — |

**The 11× warm gap is 2.3×**, and it went there by deleting a dependency
rather than by making anything faster: nothing in the compiler changed for this
row. The front end is 7.8× off its own previous number and 3× over the target
rather than 26×.

**Cold, iyi is now 6.7× faster than Go**, 0.38 against 2.54, because Go cold
compiles its standard library and iyi cold compiles 833 lines. That reverses
the first run's warning and replaces it with a smaller one: the comparison is
only fair while iyi's library is this small, and it stops being flattering the
moment iyi has one worth the name.

**What is left is the same shape one order down.** 0.17 s of front end is 833
lines of prelude analysed from source on every build, and the reading here at
the time was that `.iyimod` removes exactly that. It does not: an artifact is
declarations in text, and a consumer parses them and runs the top-level pass
over them the same way. Measured in IV.1a once the artifact existed, on the
largest import graph here, and it is worth nothing at this size. What removes
the prelude's analysis is keeping it rather than serialising it. The daemon.

**The third run, and the target is met.** Two changes, one of them to the
instrument:

| program | stage | cold | warm |
|---|---|---|---|
| `hello.iyi` | front end (`--no-codegen`) | **0.04** | — |
| `hello.iyi` | end to end | **0.25** | **0.25** |
| `hello.go` | `go build` | 2.37 | 0.14 |
| `webapp.iyi` | front end, iyi only | **0.05** | — |

  measured 0.039 s against a 0.05 s target: **MET**.

The first change was iyi's own `primitives.iyi`, above: 0.17 s → 0.07 s. The
second was the instrument, and it has to be said plainly rather than banked.
**The bench used to time `bin/crystal`**, a POSIX-sh wrapper that resolves
symlinks with recursive shell functions, shells out to `uname` and `readlink`,
prints which compiler it found, and then `exec`s the binary. It costs **30 ms**.
`go build` is timed as a bare binary, so half of what was being compared was
this repository's development ergonomics. The bench now asks the wrapper once
for the two paths it knows and times the compiler: 0.07 s → 0.039 s.

**So the honest reading is that the target is met by the compiler and not yet
by `bin/crystal`**, which is still 0.066 s and is what a person in this
checkout actually types. Shipping a binary rather than a shell script is a
packaging job, not a compiler one, and it is not what this document is about,
but it is 45% of the number until it is done.

**Most of it turned out not to need the packaging job.** Alternating the old
script and a new one in the same directory, three rounds: **0.076 s against
0.044 s**. Four processes came out, none of which had to be there. The largest
started the *installed* compiler to read one string: `crystal env
IYI_LIBRARY_PATH`, 0.020 s, and that answer is now kept in `.build`, keyed
by the compiler that gave it. The others were `tput` deciding whether to colour
a message nobody may be reading, `uname` answering which binary to look for, and
`dirname`/`realpath` doing what `${path%/*}` and `pwd -P` do without forking.
What is left is about 0.018 s of shell over a 0.026 s binary, and *that* is the
packaging job.

**What is left of the front end.** Of 0.039 s: about 0.020 s is the top-level
pass over 1,053 lines of prelude and primitives, about 0.008 s is every other
semantic pass together, and the rest is process startup. Item 1's artifact
would carry the first term and item 2 addresses a term that is now 8 ms. The
gap that made this project has closed to the point where the remaining costs
are the ones every compiler has.

**The Go column, at last, and it is not the one this project was expecting.**
Item 1 of this section says the Go number is measured here or not had at all.
Until now it was not had: `go` was not installed on the machine, and every run
printed so. It is installed now: Go 1.25.2, and the table is complete:

| program | stage | cold | warm |
|---|---|---|---|
| `hello.iyi` | front end (`--no-codegen`) | 0.049 | — |
| `hello.iyi` | front end, no LLVM linked | **0.03** | — |
| `hello.iyi` | end to end | 0.21 | **0.19** |
| `hello.go` | `go build` | 4.62 | **0.08** |

**Warm, Go wins by 2.4×**, and warm is the number a person feels: 0.08 s against
0.19 s. Cold, iyi is fifteen to twenty times faster (0.21 s against 4.6 s) but
that column is Go compiling its standard library into an empty cache, which is
paid once per machine and is not a rebuild. Recording it flattering side up
would be the kind of thing this document exists not to do.

**And the front end is faster than Go's whole build.** 0.03 s of analysis
against 0.08 s for parse, typecheck, codegen and link. So the claim as this
project has been making it is true of *analysis* and false of *producing a
binary*: of iyi's 0.19 s, about 0.14 s is LLVM at `-O0` and `cc`. Item 3 of
this section put the end-to-end row in the table precisely so the claim could
not quietly become a front-end-only claim, and this is that guard firing.

**Which moves the next lever off the front end entirely.** Everything left in
Part IV buys milliseconds of analysis against a 140 ms tail that belongs to a
code generator and a linker. Go's answer to that tail is its own back end and
its own linker; iyi's options are narrower and none of them is `.iyimod`.

**The fourth run found nothing about the compiler and two things about the
gate.** Run on the same checkout minutes apart, `bench/build_speed.py` said both
MET and NOT MET.

**The first was how `.build/crystal` had been built.** The compiler is itself a
Crystal program, and a debug build of it is **1.5× slower**: 0.104 s against
0.068 s, measured by alternating the two binaries so that the machine's state
cancels, which is what the first attempt at this number did not do and why it
read 2.2×. The target is decided by a few percent, so the build mode decides
the gate. `make crystal release=1` does not settle it either: make takes an
existing binary for up to date whatever it was built with, and says nothing.
The bench now asks the compiler how it was built. The compiler already knows,
and `--version` says so: prints the answer above the table, and **refuses to
decide the target from a debug build** rather than reporting the compiler as
too slow.

**The second was the machine, and it is the larger term.** On one binary,
minutes apart, the front end measured **0.048 s, 0.109 s and 0.061 s**. Most of
that turned out to be three samples rather than three machines: fifteen runs put
the floor at 0.048, 0.042 and 0.045 s across three sessions whose medians ranged
0.048 to 0.070. Best-of-N assumes the samples reach the floor, and three did
not. The gated figure now takes fifteen after two discarded warm-up runs, and
prints the slowest beside the fastest.

**What is left of it is written down rather than averaged away.** The first
invocation after the machine has been idle reads about 40% high. Every sample
in it, not a few, and the ones a minute later do not. Two probes were tried
against that swing and neither isolates it: a fixed integer loop held to 4%
across the same period, and startup moves with it only partly. So a single run's
MET is worth more than its NOT MET, and a NOT MET from a machine that has been
asleep is worth running again.

**And measuring startup separately answered a question nobody had asked.**
Starting the compiler and doing nothing (`crystal --version`) costs **0.029 s
against a 0.042 s front end**. Two thirds of the number this target is set on is
a process starting rather than a line being analysed.

**It is not the binary, and it is not the loader. It is linking LLVM.** The
dynamic loader accounts for 3.2M cycles of it (about a millisecond) by its own
statistics. What the rest is took a control: a C program whose `main` returns
zero costs **0.001 s** built plainly and **0.026 s** built with a `NEEDED` entry
on `libLLVM.so` and no call to it. `clang --version` pays the same 0.023 s, and
a small Crystal program with no LLVM pays 0.004 s. So it is libLLVM's own
load-time initialisers, charged to every process that links the library whether
or not it generates code, and `crystal build --no-codegen` is exactly a process
that does not.

**That reorders what is left of this section.** Item 2 was written to remove
passes that re-walk the prelude; those are now about 8 ms together, against 26
ms spent bringing up a code generator the front end never calls.

**So the front end became a binary of its own, and it is built.**
`make crystal-front` produces `.build/crystal-front`: the same parser, the same
semantic passes, no LLVM linked. Measured against `crystal build --no-codegen`
on the same machine, fifteen runs each after two discarded:

| | full compiler | front end only |
|---|---|---|
| `hello.iyi` | 0.059 s | **0.028 s** |
| `webapp.iyi` | 0.045 s | **0.035 s** |
| starting up, doing nothing | 0.023 s | **0.0045 s** |

Startup falls by a factor of five and the gated figure by half. What is left of
`hello.iyi` is about 23 ms of analysis and 4.5 ms of a process starting, which
is the shape the target was written to reach.

**What it cost was smaller than the 64 references suggested.** Outside codegen
the compiler names `LLVM` in four places and three are strings settled when the
binary was built. The LLVM version, the host triple, and normalising a triple
a user typed, so `llvm_shim.cr` bakes them in. The fourth is a target machine,
wanted by one AVR flag. Two other things had to be absent rather than shimmed,
and both say so when reached: `sizeof` and its neighbours, which are answered
from LLVM's data layout, and `macro_run`, which compiles a program and runs it.
Nothing in iyi's prelude or samples writes either. Two plain types had to move
out of files that speak LLVM: `Compiler::OptimizationMode` into its own file,
and `Const#initializer` behind the same flag.

**And what it does not do is the rest of a build.** It parses, analyses,
reports and exits; there is no object file, no linker and no cache, because
those belong to the half that is missing. `crystal build` is unchanged.

Two things could take the remaining 26 ms off a full build as well, and neither
is this: **an LLVM built without its option registry**, which is not iyi's to
build, and **not paying it per build**, which is IV.1d's daemon. A process
that starts once amortises the fixed cost over every compile after the first.
The daemon was proposed to keep the prelude analysed; the larger thing it keeps
is the code generator loaded.

**The fifth run, and the warm column changed hands.** The 140 ms tail that the
Go comparison above assigned to "a code generator and a linker" was neither: it
was `cc` working out how to link, on every build. The compiler asks the driver
once now and runs `ld` itself (0.1.0 item 2), and the same bench on a release
compiler says:

| program | stage | cold | warm |
|---|---|---|---|
| `hello.iyi` | front end (`--no-codegen`) | 0.05 | — |
| `hello.iyi` | front end, no LLVM linked | 0.03 | — |
| `hello.iyi` | end to end | 0.24 | **0.09** |
| `hello.go` | `go build` | 4.15 | 0.12 |
| `webapp.iyi` | front end, iyi only | 0.06 | — |

  measured 0.047 s against a 0.05 s target: **MET**.

**Warm, iyi is now ahead**: 0.09 s against 0.12 s, where the run before this one
had it 0.19 s against 0.08 s. Nothing in the front end moved to do it. Of what
the compiler times in that warm build, the link is 0.026 s of 0.058 s: 45%,
where it was 93% this morning.

**And the gate is inside this machine's noise, which is worth saying rather than
picking the run that flatters.** Two release runs minutes apart measured 0.047 s
and 0.052 s against a 0.050 s target: MET and NOT MET on one binary. The
paragraph above about a machine that has been idle reading high is the same
observation, and the same conclusion follows. A NOT MET from a machine that
has just finished a compile is worth running again, and a target decided by 4%
is a target the next machine will decide differently.

**The sixth run had a second program in it, and it takes the previous
paragraph's headline back.** Item 5 said the corpus was one program because
`hello` is the only pair whose Go equivalent is unarguable, and that growing it
waited on item 3. `bench/build_speed/generate_pair.py` grows it without the
argument: both halves come out of one loop: 300 structs with two fields, an
arithmetic method, a method taking another of its kind, a name, and a main that
adds up what they answer, so they are the same shape by construction, and the
bench builds and runs both and drops the rows unless they print the same thing.
About 6,900 lines of iyi, 6,000 of Go. On a release compiler:

| program | stage | cold | warm |
|---|---|---|---|
| `hello.iyi` | end to end | 0.18 | **0.07** |
| `hello.go` | `go build` | 3.30 | 0.10 |
| `medium.iyi` (6,900 lines) | front end (`--no-codegen`) | 0.10 | — |
| `medium.iyi` | end to end | 0.58 | **0.23** |
| `medium.go` | `go build` | 3.66 | **0.09** |

**Go's warm build does not move and iyi's does.** Across a 6,900-line
difference Go went 0.10 s → 0.09 s; iyi went 0.07 s → 0.23 s, and at 13,800
lines it is 0.42 s against Go's 0.087 s. So the warm win recorded above is a
win at the size of `hello` and nothing more: it came from removing fixed costs,
and fixed costs are the whole bill only while the program is one line. Per
thousand lines of this program iyi costs about 25 ms and Go costs nothing
anyone here can measure.

Where those milliseconds go, at 300 types and warm: parse 55 ms, semantic 87 ms
across every pass, codegen 115 ms, link 55 ms. Nothing in that list is the
prelude, the artifact or the driver. It is the compiler compiling, which is the
first time in this document that has been the answer.

**And one of those terms is paid for work that is then thrown away.** After a
one-line edit at 300 types the compiler reports `305/306 .o files were reused`
the per-unit cache doing exactly what it is for, and still spends 87 ms in
`Codegen (crystal)`, which is building the LLVM IR for all 306 units. The IR is
what the hash is taken *from*, so every unit is generated in order to discover
that 305 of them did not need to be. What the cache saves is the back end after
that point: `bc+obj` falls to 42 ms, of which most is bookkeeping over 306
units, and the link is 60 ms for 306 objects.

The obvious alternative is one module, and it is not better: measured both ways,
unchanged source favours `--single-module` (0.257 s against 0.316 s, fewer files
to check and one object to link) and **a real one-line edit favours the unit per
type** (0.390 s against 0.505 s), which is the case that matters and the reason
the default is what it is. The first attempt at this comparison said the
opposite, because its "edit" for the first iteration rewrote the file with the
text it already had; the number that came out was a warm build with nothing to
do, and `min` picked it.

So the work worth removing is generating IR for a unit whose object is going to
be reused, and that needs a unit's *inputs* fingerprinted rather than its
output. A dependency-tracking problem, not an optimisation. It is written down
here rather than started.

**Asked again on a release compiler, on another machine, and the shape is the
same.** A one-line edit at 300 types rebuilds in 0.142 s; `306/307 .o files
were reused`, and `Codegen (crystal)` is 0.036 s with 0.023 s more in `bc+obj`
— so about 0.059 s of a 0.142 s rebuild, **42%**, is spent establishing that
306 units did not change. The absolute figures are smaller than the debug ones
above and the ratio is not: this is where the scale claim is decided, and it is
still the same unstarted piece of work.

**The front end was asked the same question and answered that there is nothing
wrong with it.** At 150, 300, 600 and 1,200 types (3,462 to 27,612 lines) parse
goes 0.026, 0.048, 0.092, 0.165 s and `main` goes 0.029, 0.056, 0.114, 0.236 s:
linear in both, with the top-level pass flat at 0.026–0.041 s because what it
walks is the prelude rather than the program. About 6 µs a line to parse and
8.5 µs a line to type, on a debug compiler. There is no quadratic hiding in
there and so nothing to remove; what is left is the cost of the implementation,
which is a project rather than a fix, and this document would rather say so than
imply a bug it has not found.

### What Crystal's own 0.1.0 looked like

The scope above was drawn before checking it against the one release most
comparable to it. The same language family, the same first-release question.
Checking it moved two things and left the shape alone.

| | Crystal 0.1.0 (2014-06-18) | iyi today |
|---|---|---|
| Compiler | 24,984 lines, **written in Crystal** | 116,466 lines, Crystal, forked |
| Library | 8,161 lines (3,551 of it core) | 17,511-line own prelude + 40,690 in std |
| Specs | 21,146 lines | 11,946 for iyi |
| Samples | 24 **programs** | 8 **explanations**, a first half hour, and `calc`, a language |
| History | 3,165 commits over 21 months | 266 |
| Own status line | *"pre-alpha: we are still designing the language"* | design largely settled, 0.2.0 released, a language written in it |

**It shipped admitting the language was undesigned.** No binaries, clone and
run `bin/crystal --setup`, OSX and 32/64-bit Linux. That is permission rather
than a rebuke: the scope above is *more* conservative than the release it is
being measured against, and iyi is further along in design at this point than
Crystal was at its first release. It is behind on building and ahead on
deciding.

**Its samples were programs.** mandelbrot, binary-trees, brainfuck,
`http_server`, sudoku, a red-black tree, n-bodies, SDL and Cocoa bindings. iyi's
samples are better in one respect. Every claim in them is compiled, which
Crystal's were not, and they have a gap Crystal's did not: **no iyi program
does any work.** A build-speed claim needs programs to build, and the benchmark
in item 5 therefore starts with almost nothing to measure. Growing that corpus
is a dependency of item 5, not a nicety, and it is bounded by item 3: a program
can only be written once the prelude carries it.

**The corpus grew, the benchmark ran, and it corrected the prediction it
was built to confirm.** `bench/rebuild_speed.py` rebuilds an app over
eight sample modules after an edit, arms alternating: from source, and
from artifacts with `--use-iyimod`. The naive reading of R-1 says the
artifact arm wins. It does not — ~1.0x on the sample corpus, ~0.85x on
a 400-type semantic-heavy fixture — because the front end types
lazily, so unused import surface is nearly free to compile, while the
artifact arm pays decode and re-declaration for all it reads. The
wall-time dividend R-1 delivers lives elsewhere, and each home already
has its own gate: the language server's per-module verdict (36 ms p50,
`bench/lsp_latency.py`), building with the library's *source deleted*
(`bench/samples_roundtrip.sh`), and the interface hash that rebuilds
nobody on a doc edit. What the benchmark now holds in CI is what the
loop still owes: an edit-rebuild stays under two seconds on either
arm, and the artifact read stays within 1.5x of the compile it
replaces, so decode cost cannot quietly grow. Recorded rather than
tuned until the fixture flattered.

**And self-hosting was already behind it.** Crystal's compiler was written in
Crystal before 0.1.0, at 24,984 lines against an 8,161-line library. That is
the cheapest such a move is ever going to be, and the cost only rises. See
Appendix B #10. The fork means iyi has already passed that point, and this
document has been silent about it.

### The item that decides the schedule

Item 3. "Tiny prelude" sounds small and is not: writing a string and a
dictionary under iyi's own rules (no open classes, `Share`, `sorted`) is the
first real library ever designed against them, and the whole of the evidence
that this is possible is one ported `Enumerable` and 722 lines of samples. The
bound is the rule stated above: the samples decide what goes in. If that bound
slips, 0.1.0 becomes a standard-library project and the claim goes unmeasured
for a year.

---

## Part II: Interactions

### II.1 Union types × traits: **SETTLED**

The question: can you write `impl Greet for String | Int32`?

**No. Union impls are not writable. A union implements a trait if and only if
every member implements it.**

```
impl Greet for String    # ok
impl Greet for Int32     # ok
# String | Int32 now implements Greet, automatically.

impl Greet for String | Int32   # ERROR: cannot impl a trait for a union
```

Why this and not explicit union impls:

- **No new coherence rule is needed.** If unions were implementable, you would
  have to decide what happens when both `String` and `String | Int32` have an
  impl, and every answer is a footgun.
- **Dispatch already exists.** A union value carries a type id; calling a trait
  method on it compiles to the switch Crystal already generates. No new
  machinery.
- **It composes.** `Array(String | Int32)` works with any trait both members
  implement, without anyone writing anything.

A consequence worth noticing, because it is a feature rather than an accident:
`T?` is `T | Nil`, so **`T?` implements a trait only if `Nil` does too.** In the
Kemal port `Nil` implements `IntoBody` (returning `""`), so `String?` is
returnable from a route. Where `Nil` does not implement a trait, the nilable
type is rejected at compile time: nil-handling is forced at exactly the point
it matters.

### II.2 Union types × dictionaries: **SETTLED**

The question: a union is already a boxed (type id, payload). Is that a
dictionary? Do the two dispatch mechanisms collide?

**They are orthogonal, and the rule is: a union is one type with one shape.**

|  | Union | Dictionary |
|---|---|---|
| What varies | the **value**'s runtime type | the **type parameter**, erased to a shape |
| What is fixed | the code | the value's layout |
| Dispatch | switch on type id carried by the value | indirect call through ops passed alongside |

So `T = String | Int32` receives **one** dictionary, not two. The union is a
single type whose shape is `UNION(PTR|SCALAR4)`. Inside the shared body, a trait
call on a `T` value still switches on the union's type id exactly as it would in
monomorphic code.

This is worth stating explicitly because the intuition "unions are already
dynamic, so they must be dictionaries" is wrong and would lead someone to build
two parallel dispatch systems.

### II.3 `using` × everything: **BUILT, one sub-question open**

The Kemal port proved `using` is required: without it, Kemal's DSL is
unwritable, because Crystal achieves it by injecting top-level methods into the
importing program's global namespace. But the port did not say what `using`
*is*. Proposed rules:

**1. `using` affects unqualified calls only. It never affects method resolution
on a receiver.**

```
using kemal::dsl

get "/" do |env| ... end     # unqualified -> resolved via `using`
user.greet                   # receiver call -> resolved via User's traits only
```

This single rule dissolves the `using` × traits question entirely: they operate
in disjoint namespaces and cannot interact. Trait method resolution is always
and only a function of the receiver's type and its impls.

**2. Local definitions beat imported ones. Always.**

Defining your own `get` shadows an imported `get`, with no ambiguity error. A
library can never break your code by adding an export that collides with
something you already had.

**3. Ambiguity is an error at the point of *use*, not the point of import.**

```
using a          # exports get, post
using b          # exports get, delete

post "/x" do ... end     # fine
get  "/x" do ... end     # ERROR: `get` is ambiguous (a::get, b::get): qualify it
```

Resolvable from export metadata alone, so it costs nothing. And it means adding
an export to a library only breaks consumers that actually call the colliding
name.

**A `using` imports what it names.** `import app/dep` followed by `using
app/dep` wrote one path twice, and the first line told the compiler nothing
the second did not: `using` reaches one module, and that module has to be
in the program. The parser makes the import for a top-level `using` whose
module the file does not import itself, after the file's own imports where
every import stands, so the edge is the file's and the import wall is where
it was - a qualified name the file never wrote a line for is still refused.
Writing both is not an error; the module loads once. The formatter and
`to_s` print what the source says, which is the `using`.

**4. File-scoped, declared at the top. No block-scoped `using`.**

Block-scoped imports are Ruby's `instance_eval` in a new hat: they make the
meaning of a bare name depend on where you are in a file. Not worth it.

**5. Selective form available and encouraged:**

```
using kemal::dsl                    # everything exported
using kemal::dsl::{get, post}       # just these
```

**Enforced.** `pub` is what a module's surface is, and both halves are closed:
`using` reaches only exported names. The selective form reports at the
directive which of the names it asked for the module does not export, and a
qualified `App::Greeter.helper` or `App::Greeter::Closed` is refused too.

The second half is not decoration. `.iyimod` carries a module's exports and
nothing else (IV.2), so if another module could reach an unmarked name, that
metadata would not be enough to compile against and R-1 would not hold.

Only a `module app/greeter` compilation unit has a surface, and only its own
body carries it: a `def` inside a `pub trait` or a `pub struct` belongs to the
trait or the struct. `Enumerable#to_a` writes no `pub` and stays callable on
every implementer. A Crystal module never wrote `pub` and is untouched.

**OPEN:** whether `using` may be re-exported (`pub using`), so a facade module
can pass a DSL through. Convenient for `import kemal` giving you the DSL without
a second line, and a way to reintroduce exactly the implicitness R-3 removed.
Recommend **no** for Draft 0.

### II.4 Derive macros × separate compilation: **SETTLED and BUILT**

This is the interaction that decides whether R-5 delivers the caching it
promises.

**A derive runs once, in the module that declares the type. Its output is part
of that module's export metadata. Consumers never re-run it.**

```
# module app/user : the derive expands HERE, once
pub struct User
  derive JSON
  getter name : String
end

# module app/api
import app/user
user.to_json      # reads export metadata; no macro expansion happens here
```

Coherence holds automatically: `derive JSON` generates `impl ToJSON for User`,
which lives in `User`'s own module: legal under R-3. And you cannot derive a
trait for a type you do not own, which is the orphan rule again, consistently.

**What a macro may read. The precise version of R-5:**

> A macro may read the declaration it is attached to, and the **export metadata**
> (never the bodies) of imported modules. It may not enumerate types it was
> not given.

This is more permissive than "module-local" and still separately compilable.
It matters for the realistic case:

```
pub struct Order
  getter customer : Customer     # imported from another module
  derive JSON
end
```

That order is not decoration. `getter` is a macro call, so the field it declares
exists only once it has run, and a derive reads the declarations above it. This
example was first written the other way round, which is what building it
corrected: see the ordering paragraph below.

Expanding `derive JSON` here needs to know only whether `Customer` implements
`ToJSON`. A fact in `Customer`'s export metadata. It never needs
`Customer`'s method bodies. Bounded, cacheable, correct.

What this forbids, and should: `all_subclasses`, program-wide `macro finished`,
and `macro_run`. The last of which costs a fixed **+7.4 s per distinct script**
on a cold build, remeasured in II.10.

**BUILT, and what it cost to get right.** `derive <macro>` in a class or struct
body resolves through the ordinary exported macro table, expands once while the
declaring type is being processed, and the methods it generates are that
module's own. `samples/iyi/derive.iyi` is built from its artifacts with
`std/derives` deleted by `bench/samples_roundtrip.sh`, which is this section's
claim taken literally.

**A derive is handed a description of its declaration, never the declaration.**
The first implementation passed the macro the attached `ClassDef`, first live
and then cloned. Every build that emitted or read an artifact failed to
terminate. Replacing the directive with a `Nop`, detaching the generated
expansion, and severing observer and dependency edges each removed one retained
path and none of them fixed it, because the argument itself was the cycle: the
declaration contains the `derive` node, and the walk that follows a macro's
inputs had no end. What is passed now is a `NamedTupleLiteral` built for the
purpose, carrying the declaration's name and, for each field written in its
body, that field's name and the type it was written as. It is finite, it holds
no reference back into the tree, and it is the same shape whether the module is
being compiled or read.

**The `Order` case is built.** A field's type arrives as a type, not a name, so
`field[:type] <= ToJSON` is the question above, asked and answered. The type,
the trait and the impl may all belong to another module and arrive from its
artifact: `spec/compiler/iyi_derive_spec.cr` deletes both producer sources and
builds the consumer from `.iyimod`s alone, and the field whose type does not
implement the trait is absent from what the derive generated, from source and
from artifact alike.

The type is read from the annotation, not from the instance variable, because an
instance variable's type is settled by `TypeDeclarationVisitor`, a later pass:
there is nothing to ask when a derive runs. R-2 is what makes that enough. What
a module exports carries written types, so the annotation is there to read.

**A derive reads the declarations above it.** `getter n : Int32` is a macro
call, and the field it declares exists only once it has run. Above the derive it
has run, so the field is read. Below, it has not, and a derive that answered
from the body anyway would generate a method over the fields it happened to
see — silently, and differently depending on where the `derive` line sits.
That is refused, naming the call and which way to move it.

Making the order not matter would mean expanding the calls below the derive
early, and that is a larger promise than it looks: it says macro expansion order
inside a type body is not observable. It is observable — a macro can read what
has been declared so far — and Crystal does not promise otherwise. So the rule
is the narrow one: a derive reads upwards, and says so when something it cannot
read is below it. The example at the top of this section was written the other
way round before this was built, and is now written the way the language works.

**The program-wide questions are refused for the length of the expansion.**
Handing over a type hands over everything a macro may ask a type, and
`all_subclasses`, `subclasses` and `includers` answer with the whole program
rather than with a declaration. A derive that read one would generate different
code depending on what else was compiled, which is the caching promise this
section rests on, so inside a derive they raise. Outside one they are untouched.

**Several names on one line.** `derive named, counted` runs each macro in turn,
left to right, each reading the same declaration. A name that is not an
available derive macro is reported at that name rather than at the line.

**Where R-5's parenthetical is stricter than the artifact format.** R-5 says a
macro may read imported modules' export metadata, *never the bodies*. A field's
type is a type, so a derive can reach `field[:type].methods` and read a method's
body — and measurement says it gets the same answer with the producer's source
deleted as with it present, because a `.iyimod`'s declaration section carries
those bodies. So the sentence describes an artifact narrower than the one iyi
emits. Nothing is unsound here: the answer is a function of the artifact, which
is what R-1 requires. What R-5 was protecting is the program-wide questions, and
those are refused. Recorded rather than fixed, because the fix belongs in what
a `.iyimod` carries, not in what a macro may ask.

### II.5 Dictionaries × the garbage collector: **SETTLED, and a dependency**

This one only became visible while writing the spec, and it removes a choice I
had previously presented as free.

Shape-based stenciling means one compiled body serves many types. That body must
still tell the collector which words in a value are pointers. **The pointer map
therefore has to travel with the shape**, which is exactly why Go calls it a
*GC shape* rather than a memory layout.

Consequences:

- **R-4 requires a precise collector.** Crystal's Boehm GC is conservative: it
  guesses at pointers by scanning. That works without shape information, but it
  cannot supply the per-shape pointer maps stenciling needs.
- So "replace Boehm with a precise GC" is **not** an independent runtime
  decision to be taken later. It is a prerequisite of R-4, and it constrains
  object layout from day one.
- Recommended: precise, generational, **non-moving** for Draft 0. Moving
  collection requires interior-pointer discipline throughout, and Crystal's
  `to_unsafe`/`Pointer` idioms are pervasive. Defer.

**Amended by III.9, and the amendment makes this cheaper than it reads.** "A
precise collector" is two requirements. R-4 needs to know which words *inside an
object of a given shape* are pointers, which is a table the compiler computes
anyway. It does not need to know which *stack slots* hold pointers, which is the
expensive half: stack maps, a frame walker, and correctness under every
optimisation the back end runs. `gcry` has measured that half and found it is
not even an RSS win. So the prerequisite stands and the bill is a table, not an
epic. See III.9.

**The table is now written.** `.iyimod` format v43 carries a `Layouts` section:
per type this module owns, its allocation size, its unrounded instance size, and
the byte offsets of its pointer fields, taken from the target's own data layout
rather than added up by hand. `Probe::Shapes::Pair`, three fields of `String`,
`String` and `Int32`, reads back as 24 bytes, scan cap 20, offsets `[0, 8]`, and
the padding in those numbers is the evidence they came from the back end.

Two things that table is not. It is per instantiation, not per GC shape: one
entry serving `Box(String)` and `Box(Pointer)` together is R-4's own keying and
nothing implements it, so a generic never instantiated in a module contributes
nothing there. And `noscan_offsets` is empty everywhere, because what "not
traced" means is Stage 6's to define and a guess now would risk a later stage
reading it as "do not retain" and collecting live buffers.

### II.6 Traits × the standard library: **SETTLED by porting `Enumerable`**

`Enumerable` is the load-bearing abstraction of Crystal's stdlib: 2,350 lines,
**130 methods built on a single `abstract def each`**, included by 17 types.
`Comparable` reaches 21 more. If traits cannot express that shape, the library
cannot be written in Crystal's idiom and the ergonomics half of the pitch fails.

It ports. But it required three things Draft 0 did not have, and exposed one
genuine conflict.

**It now ports in the compiler, not on paper.**
`src/std/enumerable.iyi` carries **all 71 of Crystal's distinct method
names** (72 defs against Crystal's 117, which counts overloads), all written
against one `abstract def each`. `samples/iyi/collections.iyi` implements it for
two types that answer `Elem` differently and calls every one of them. A default
method that is never called is never typed, so a trait that merely compiles
proves nothing. What is left out is listed at the foot of the port, and is
mostly the nilable-variant family (`minmax?`, `max_by?`) and methods that
destructure the element (`to_h`, `chunks`). It needed the
three things below and nothing else. Three findings came out of the port that
this section had wrong or had not reached:

- **The block must not be captured.** The sketch below writes
  `abstract def each(&block : Elem -> Nil)`. That form captures the block into
  a `Proc`, and a captured block cannot `return` from the enclosing method,
  which removes early exit from `find`, `any?`, `all?`, `none?`, `first`,
  `take`, `take_while`, `empty?`, `index` and `find_value`. It has to be typed
  without being captured, `& : Elem -> Nil`, and yielded. Corrected below.
- **Dropping `!` cost one thing, and it was `find`.** With `!` out of
  identifiers (III.1.7) the port first took `?` for the nilable one and the
  plain name for the one that raises — `find?`/`find`, `index?`/`index` —
  reading Crystal's `find!` and `index!` as breaking its own `max?`/`max`
  convention. That reading was wrong. Crystal's rule is that the plain name
  is the *common* case: `max` raises because an empty collection has no
  largest element, and `find` answers nil because not finding is the
  ordinary outcome of a search. Applying the max half to `find` made one
  name mean two things inside this library — `Enumerable#index` raised
  while `Indexable#index` and `Array#index` answered nil — which is what
  III.1.7a exists to keep out, and it put the recoverable answer out of
  reach: `|| raise` turns a nil into a panic in one expression, while a
  panic is caught at a task boundary and nowhere else (III.4.3). So `find`
  and `index` answer nil under their plain names, `find?` and `index?` are
  gone, and `max?`/`max`, `min?`/`min`, `first?`/`first` and
  `minmax?`/`minmax` keep their pairs, where the plain name raising is both
  the common case and Crystal's answer.
- **A trait needs to require class-level methods, and now can.** `sum` and
  `product` with no argument need an additive and a multiplicative identity,
  and an identity belongs to the type: an empty collection has no element to
  ask. So `Num` declares `abstract def self.zero : self`, an impl answers it
  with `def self.zero`, and `sum` reaches it as `Elem.zero` through the
  associated type. The requirement is checked at the impl like every other,
  and reported as `self.zero`. What has to be written to fix it. It stays
  refused outside a trait, where an abstract class method would oblige nobody:
  only a trait has implementers whose class methods anything checks.

  This is checked separately from the instance requirements, because `include`
  carries instance methods only. The trait's metaclass defs never reach the
  target's, so there is nothing for the impl to have inherited. It has to have
  written them.

Finding 6 below is realised too: `zip` is `forall O : Enumerable`, and `O::Elem`
names what the other collection yields without the caller stating it.

**Two more findings, from porting the rest of the library rather than just
`Enumerable`.** `src/std/` now carries `Indexable`, `Iterator`, `Slice`,
`Char`/`String` and `Time` alongside it, and two of them found limits this
section had not reached.

- **An associated type does not specialise through a type variable.** An
  adaptor parameterised on the upstream iterator alone, `MapIterator(I, U)`
  referring to `I::Elem`, does not compile: for a receiver of
  `ArrayIterator(Int32)` the compiler resolves `I::Elem` against the generic
  declaration, where `type Elem = T`, and asks for `Proc(T, Int32)` instead of
  `Proc(Int32, Int32)`. The projection is not specialised to the receiver's
  argument. The port works around it by passing the element type explicitly,
  `MapIterator(I, T, U)` built as `MapIterator(self, Elem, U)`, where `Elem` is
  already concrete at the call. Lazy pipelines do compose and do stay lazy, so
  the shape is expressible; it costs one type parameter per adaptor that this
  section's model says it should not. That is a compiler limitation rather than
  a design decision, and it is written down here because the next person to
  build a generic adaptor will hit it in the same place.
- **A trait cannot include a trait, so `Indexable` costs two impls.** A type
  that implements `size` and `unsafe_fetch` gets `Indexable`'s whole surface,
  and `Indexable` can define `each` from those two, but it cannot thereby be
  `Enumerable`: supertraits are requirements rather than inclusions, and the
  orphan rule (R-3) forbids `impl Enumerable for Array(T)` anywhere but the
  module defining one of them. So a type writes `impl Indexable` with its two
  methods and then an empty `impl Enumerable` answering only `type Elem`, and
  the second one exists purely to open the door. Nothing is unsound and nothing
  is unexpressible; it is one more line than the ergonomics claim implies, and
  the claim should say so rather than be quietly generous.

**1. Traits need associated types as well as parameters.**

```
pub trait Enumerable
  type Elem                                     # an output of the impl
  abstract def each(& : Elem -> Nil) : Nil      # required, and not captured
  def to_a : Array(Elem)                        # default, has a body
    # ...
  end
end
```

**`abstract def` marks a requirement, and this was corrected by writing the
parser.** The first draft used a bare `def each(...) : Nil` with no body. That is
ambiguous in a language with no statement terminator: after the signature, the
parser cannot tell a requirement from a default whose body starts on the next
line without unbounded lookahead. Rust avoids this with `;`. `abstract` is
already a Crystal keyword meaning exactly this, so it costs nothing and reads as
expected.

A collection iterates one way, so the element type is not something the caller
picks: making it a parameter would leave `arr.map` ambiguous about which impl
it means. But parameters are still needed where several impls are the whole
point (`Into(T)`, `From(T)`). **Both forms exist.** Draft 0 assumed only
parameters.

**Both are built.** An impl answers an associated type in its body, and names a
trait's parameters where it names the trait:

```
impl Container for Names          impl Into(String) for User
  type Elem = String                def into : String
  def first : String                  "u"
    "ada"                           end
  end                             end
end
```

Both are carried as type vars of the trait. What a trait's signatures and
default bodies need from them is identical, and an included generic module is
already how Crystal resolves such a name. They differ in exactly one checked
rule, which is the whole reason the distinction exists: **a trait that declares
associated types can be implemented only once for a given type.** A second impl
answering `Elem` differently would make a call on that type ambiguous, which is
the cost that ruled out making the element type a parameter. A trait with
parameters has no such rule, because several impls are the point of it.

One gap the implementation found, and it is on the parameter side: two impls of
the same parameterised trait for one type **collide when their methods take the
same arguments**. `impl Into(String) for U` and `impl Into(Int32) for U` both
define `into`, and the second silently wins. That is the shape parameters exist
for, so it needs an answer; Rust's is to select the impl from the type the call
site expects, which this design does not yet have anywhere else.

**2. Default methods need their own type parameters.**

```
def map(&block : Elem -> U) : Array(U) forall U
```

`U` belongs to the method, not the trait. Unavoidable: `map`, `flat_map`,
`group_by`, `min_by` and `to_a(&)` all need it.

**3. Default methods need conditional bounds.**

```
def max  : Elem            where Elem : Comparable
def sum  : Elem            where Elem : Numeric
def tally : Hash(Elem, Int32) where Elem : Hashable
```

About a quarter of `Enumerable` is only valid for some element types. Crystal
duck-types these and fails at instantiation with a confusing message; a closed
method set forces the bound to be written. More work for the library author, a
much better error for the caller.

**Built.** `where` bounds a name the method did not introduce, which is what
separates it from `forall`: `forall` introduces a name and may bound it, `where`
bounds an associated type the enclosing trait already introduced. The check runs
where the call is matched, because by then the associated type is a type, and it
reports `` Int32 does not implement Comparable, required by `where Elem :
Comparable` in `max` ``. The unbounded methods of the same trait stay available
whatever the element type is; only the bounded one is withheld.

**3a. A trait needs to require another trait.** `Comparable` reaching 21 more
methods is only sound if an implementer of the trait that uses them has them.

```
trait Ord : Comparable
  def beats(other : self) : Bool
    (self <=> other) > 0        # Ord never declared `<=>`
  end
end
```

**A requirement, not an inclusion.** Were `Ord` to include `Comparable`, every
implementer of `Ord` would satisfy `Comparable` with no `impl Comparable for` it anywhere,
the open-class hole R-3 exists to close. So `impl Ord for X` is refused unless
an `impl Comparable for X` already exists, and `Ord`'s default bodies still reach
`<=>` because a module's body resolves against the type it is included in.
Transitivity is free: if `Comparable` required `Show`, the `impl Comparable for X` this one
insists on was checked the same way.

The price is that impls have to be written in dependency order. The check needs
this impl and the trait's declaration and nothing else, which is what R-1 asks
of it, and nothing has run that would know about an impl written later.

**4. The conflict: where default bodies are compiled.**

R-1 says compiling a module reads only export metadata, never bodies. But a
default method's body must be compiled for each implementing type, and the
implementer is in another module. This is the Go/Rust fork a second time:

- **(a)** Stencil the body once per GC shape in the trait's module, reaching
  element operations through a dictionary. Pure R-1, cheap to compile, and it
  pays the cost measured at **4.3× on reference field access**, which is exactly
  the shape of `arr.map(&.name)`, the most idiomatic line in Crystal.
- **(b)** Ship default bodies in export metadata so the implementing module
  monomorphises them. Fast at runtime; precisely why Rust compiles slowly.

**Resolution: (a) by default, `@[Monomorphize]` opting a method into (b).** The
hot handful (`each`, `map`, `select`, `reduce`) are marked in the stdlib; the
other ~120 stay stencilled.

The price is real and belongs on the record: **the library author now makes a
per-method performance decision and has to get it right.** Crystal's author
never faced that choice, because everything monomorphises. This is the clearest
place where iyi asks the stdlib to absorb complexity so that user builds stay
fast.

**5. Dictionaries carry a type descriptor, not just a pointer map.**
`select(type : U.class)` filters by runtime type, so dictionaries need type
identity. II.5 had claimed only pointer maps; Go's dictionaries carry both.

**6. One simplification found.** Crystal's
`zip(*others : Indexable | Iterable | Iterator)` is duck typing left over from
having no traits. In iyi it is `forall O : Enumerable`. A union-of-traits bound
would mean "implements at least one of", which no body could rely on. It should
not exist in the language.

### II.7 Generic impls: **SETTLED**

`impl Enumerable for Array(T) forall T`. Four decisions, each taken from the
language that already paid for the mistake.

**1. The binder is required (Rust).** `impl Show for Box(T)` with no `forall T`
is refused. Without the binder, whether `T` is a new parameter or a type
already in scope depends on what happens to be imported, so a library could
change the meaning of a consumer's impl by adding an export. Rust requires
`impl<T>` for exactly this reason. The cost is four characters; the error names
them.

**2. Parameter names are the impl's own, bound positionally (Rust and Java,
not Crystal).** `impl Show for Pair(X, Y) forall X, Y` works on a `Pair(A, B)`.
Crystal requires a reopened generic to repeat the declared names, which leaks a
type's private naming into every impl of it. An impl states arity, not
vocabulary.

**3. A bound is a trait, and nothing else (Go).** `forall T : Show`. There is no
separate constraint language: what you can bound by is what you can implement.
This matters more here than in Go, because under R-4 a bound is not only a
check. It is what gets passed, as the dictionary.

**4. No specialisation and no blanket impls (Java's position; Rust's unfinished
business).**

- `impl Show for Box(Int32)` alongside `impl Show for Box(T) forall T` is
  refused. Overlapping impls need a rule for which one wins, and that rule has
  to stay sound when the two live in different modules compiled separately.
  Rust has wanted specialisation for a decade and it is still unstable. Java
  cannot express it at all. Refusing it is what keeps `Box(T)`'s method set
  knowable without knowing `T`. The same property R-3 exists to protect.
- `impl Show for T forall T : Debug`. A blanket impl: is refused for the same
  reason open classes are: it lets a distant module add methods to every type.

**What it costs.** Nothing extra at build time. Under R-4 an impl on a generic
type is compiled once per GC shape, not once per instantiation, so a generic
impl is one body and not N.

**A bound on a method and a bound on an impl are two different features.** The
draft treated `forall T : Show` as one thing. Implementing it showed the two
places it can be written have almost nothing in common:

| | What it means | Cost |
|---|---|---|
| `def add_route(&block : Ctx -> B) forall B : IntoBody` | The method exists either way. When `B` binds to a concrete type, check that the type implements the trait. | One check at the call site. **Built.** |
| `impl Show for Box(T) forall T : Show` | `Box(Int32)` implements `Show` only if `Int32` does. A **conditional** impl, checked where the type is instantiated rather than where the impl is written, and interacting with coherence. | A separate mechanism. **Not built.** |

The method form is the one the Kemal router depends on, in both `add_route`
and the macro loop that generates the HTTP verbs, so it was on the critical
path of the design's own acceptance test while being the cheaper of the two.
The error names the type, the variable and the method:

```
Error: Int32 does not implement App::Router::IntoBody, required by `B` in `add_route`
```

It is reported as an error rather than as a failed overload match. Under R-3 a
type's method set is closed, so "`Int32` does not implement `IntoBody`" is the
true reason a call is rejected, and Crystal's "no overload matches" would bury
it. This is also where II.6 finding 6 lands: `zip(*others : Indexable |
Iterable | Iterator)` becomes `forall O : Enumerable`.

**A generic impl of a trait with an associated type (II.7 × II.6) did not
work until something needed it.** `impl Enumerable for List(T) forall T` with
`type Elem = T` reported `undefined constant T`. Both halves were built and
specced; they had simply never been written together, because every impl in the
samples was either generic with a parameterless trait (`Show for Box(T)`) or
associated-typed on a concrete target (`Enumerable for Nums`).

The cause is worth recording, because the obvious fix is the wrong one. An
impl's answer to an associated type becomes an argument of the `include` the
compiler writes, and that argument may name a parameter of the *target*,
`List`'s `T`, which is not in scope where the impl was written. Pushing the
target's scope to find it loses the trait, whose name lives in the impl's own
module, and breaks every `impl Comparable for Int32` in `src/std/traits.iyi`.
The parameters have to be passed as **free variables** into a lookup that still
happens in the impl's scope, which is what resolving a superclass from inside a
generic already does. Both names then resolve, each from where it actually
lives.

That a generic collection implementing `Enumerable` is the first program to
need this says something about the order the samples were written in: the
canonical case arrived last.

### II.8 What a trait is, and is not: **SETTLED**

Draft 0 said `impl Trait for Type` and left "trait" undefined. The first
implementation desugared it to a module, which compiled but meant a trait and a
module were the same thing: `include Greet` worked, `using Greet` worked, and
`abstract def` was Crystal's abstract method rather than a requirement of
anything. Writing the checks settled what the word means.

**The distinction is at the declaration and use sites, not in the type
hierarchy.** This is the finding, and it went the opposite way from the
expectation. A trait has to *be* a type: `def render(x : Showable)` is
ordinary iyi, and it dispatches to the impl, and everything that makes that
work is what a module already does: it holds the required and default methods,
an impl registers the implementing type against it, and a call on a
trait-typed receiver resolves through the set of implementers. Rebuilding that
as a separate kind of type would mean reimplementing restriction matching,
union dispatch and codegen to arrive back where it started.

So `TraitType` is a *subclass* of the module type. What it adds is the ability
to refuse four things:

| Written | Refused because |
|---|---|
| `include Greet` / `extend Greet` | A type acquires a trait by having an impl, whose location R-3 can check. `include` has no such rule. It is the open-class hole under a different name. |
| `using Greet` | A trait exports no names to bring into scope. By II.3 rule 1 a trait method is resolved from the receiver, never from a `using`, so the two never meet. |
| `impl SomeModule for X` | A module has no requirements to satisfy and nothing for R-3 to check. Only a trait is implementable. |
| `impl Greet for SomeTrait` | A blanket impl in disguise, refused for the reason II.7 gives. |

The selective form of `using` may still *name* a trait,
`using app/show::{Showable}` uses the module and selects a type from it, which
is II.3 working as specified.

**`abstract def` is a requirement, checked where the impl is written.**
Crystal's abstract-method check reports at the point the type is first *used*,
names the type rather than the impl, and says nothing at all if the type is
never used. The trait reading is different in all three: an impl that does not
satisfy the trait is wrong when it is written, whether or not anything uses it.
The check is local. It needs the trait's declaration and this impl, never a
global pass, which is what R-1 requires of it.

A requirement is satisfied by the method existing on the target, not strictly
by the impl block defining it. A `def show` written on the struct itself lives
in the type's own module, which is exactly where R-3 would let an impl live, so
accepting it opens no coherence hole.

**Built since this was written, and the sentence outlived it:** associated
types (`type Elem` in a trait, `type Elem = T` in an impl, II.6) parse and
check — `src/std/enumerable.iyi` declares one and `std/list.iyi`
answers it — and a trait requires another with `trait Ord : Eq`
(`std/traits.iyi`'s `Num : Comparable`); `spec/compiler/semantic/iyi_spec.cr`'s
"supertraits" and "associated types" hold both. What II.7's table still
marks **not built** is the conditional impl, `impl Show for Box(T) forall T
: Show`, which the compiler refuses by name.

### II.9 The Kemal port, compiled: **SETTLED**

The design named Kemal's router as its acceptance test and reported that it
passed. That port was done **by hand, on paper**. It has now been fed to the
compiler: `samples/iyi/kemal/{router,dsl}.iyi` and `samples/iyi/webapp.iyi`
compile and run.

**Everything ported, and one thing had to be built first.** `record`, the macro
loop over a module-local constant that generates the HTTP verb surface,
`with sub_router yield`, blocks, procs, `alias`, `case` on symbols, nested
records, `Array(Tuple(String, String))`: none needed a language change. The
single feature the port required that did not exist is the method-level trait
bound of II.7, which is how `HTTP::Server::Context -> _` gets a name. That it
sat on the acceptance test's critical path is the argument for having built it
before anything else on the list.

**The runtime coercion is gone, as claimed.** `router.cr:301` runs
`result.is_a?(String) ? result : ""` on every request. In the port that is
`forall B : IntoBody`, checked once:

```
Error: Array(Int32) does not implement Kemal::Router::IntoBody, required by `B` in `get`
```

Kemal cannot say this. It accepts the block and returns an empty body forever.
And a user can now make their own type returnable by implementing the trait,
which Kemal has no way to offer.

**`using` did what II.3 said it would.** `dsl.cr` opens with "Kemal DSL is
defined here and it's baked into global scope." The port exports the same names
and the consumer writes `using kemal/dsl`; `before_all`, `get` and `mount` are
then unqualified in `webapp.iyi`. The Sinatra feel survives without the library
reaching into the program's namespace.

**The singletons went, and nothing forced it.** `Kemal::RouteHandler::INSTANCE`
and its three neighbours are replaced by one application value. Separate
compilation permits module-level state, so this is not a rule doing the work,
but `router.cr:270` carries "may have been cleared between tests" as a live
workaround, and a clean sheet is the moment such a line stops being necessary.

**What this does not establish.** `Context` is a stub, so no HTTP, no stdlib,
and WebSocket/SSE are omitted as they add no construct the routes do not
already exercise. Registration into handlers is replaced by returning the route
table. The earlier "+4% size" figure is therefore neither confirmed nor
refuted here: the ported scope differs, and comparing 142 lines against 173
would be comparing different programs.

### II.10 Macros × compile time: **SETTLED by measurement**

The last gap in the measurement record, and the one the rest of this document
had been quietly worrying about: this design picks a fight over compile speed
(Part IV), and it inherits Crystal's macros. If expansion is expensive, the
thesis is in trouble.

**It is not.** The measurement is `bench/macro_cost.py`, and it says "macro
cost" is three different numbers, only one of which matters.

**(a) A macro that emits a template costs what writing the code costs.** N
methods generated by a `for` loop, against N methods written out, with every one
of them called in both:

| N | via macro | hand-written | ratio |
|---|---|---|---|
| 0 | 0.143 s | 0.143 s | 1.00 |
| 500 | 0.155 s | 0.154 s | 1.00 |
| 1000 | 0.169 s | 0.168 s | 1.00 |
| 2000 | 0.187 s | 0.183 s | 1.02 |
| 4000 | 0.224 s | 0.215 s | 1.05 |

The per-method delta is not monotonic and sits inside the run-to-run spread, so
what this shows is an absence: **interpreting the macro body, emitting source
and re-parsing it does not cost measurably more than parsing the same source.**

**(b) A macro that computes per item costs about 9 µs per method it emits.**
Same comparison, but the macro builds each name with string operations and takes
a branch per item. The shape a real derive macro has:

| N | via macro | hand-written | ratio | per method |
|---|---|---|---|---|
| 250 | 0.155 s | 0.152 s | 1.02 | ~14 µs |
| 1000 | 0.171 s | 0.166 s | 1.03 | ~6 µs |
| 4000 | 0.253 s | 0.218 s | 1.16 | ~9 µs |

Real, and worth the context: the same table's slope says a *method* costs about
18 µs to define and type at all. **The macro that writes the code is cheaper
than the code it writes**, which is not the relationship anyone assumes.

**(c) `macro_run` is the whole problem, and it is worse than recorded.** On a
cold cache, against the same program with the generated code written out:

| | cold build |
|---|---|
| no `macro_run` | 1.44 s |
| one `run` script | 8.86 s |
| two `run` scripts | 15.76 s |
| the same script twice | 8.02 s |

One call site costs **+7.4 s**, which is not a percentage of anything. It is a
fixed nested compile, so expressing it as a share of the build (the appendix's
21%) says more about the build it was compared against than about `macro_run`.
It is memoised per *script*, not per call site: writing `run("x.cr")` twice
costs once. But a second script costs in full, so the price is linear in the
number of distinct generators a program and its dependencies contain, and a
library that uses one imposes it on every consumer's cold build, forever.

**What this settles.** R-5's derive scoping does not need a compile-time
justification, and should stop being offered one: it earns its place through
separate compilation (a macro that can see the whole program cannot be compiled
against export metadata alone), not through speed. The thing to police is
`macro_run`, which II.2's list already proposed cutting: now with a number that
does not depend on what it was measured against.

**Two notes on method**, both learned by getting it wrong first:

- **The generated methods must be called.** The earlier attempt at this
  measurement was invalid for exactly this reason: methods nobody calls are
  never typed, so it measured a macro producing dead code.
- **The prelude has to go, and the cache with it.** Against the real prelude the
  fixed ~1.4 s tax (IV.1a) is larger than the effect and the delta is pure
  noise. The first run of (a) reported the macro version as *faster*, twice.
  And Crystal caches the compiled `run` script, so without a fresh
  `IYI_CACHE_DIR` every build after the first reports `macro_run` as free.
  The 8 s cost was visible only as an outlier in the spread.

---

## Part III: Open questions, with recommendations

### III.1 Errors: **DECIDED (Appendix B #1: yes), built except III.1.4**

Errors are ordinary union members. No `Result` wrapper, no exception hierarchy,
no new type machinery: unions already exist and already carry a type id.

```
pub def read(path : String) : String | IOError
```

#### III.1.1 What makes a member an error: **BUILT**

A prelude marker trait:

```
pub trait Error
  def message : String
end
```

A union member is an *error member* if its type implements `Error`. This needs
no new syntax and composes with II.1: `IOError` is a normal type that happens to
implement a normal trait.

**Built.** `Error` is created by the compiler rather than declared in the
prelude, because the compiler has to recognise this exact trait: `!`, `.or` and
`.or_panic` all ask whether a member implements it, and a name the prelude
happened to define could be shadowed or replaced. Nothing else about it is
special: a module writes `impl Error for IOError` like any other impl, and the
`message` requirement is checked like any other.

The type side needed nothing else. Error unions are ordinary unions, and III.1.3
is already true: dropping a branch from a `case` over one is reported as `case is
not exhaustive`. `T?` is untouched, since `Nil` does not implement `Error`.

Two things the build found, both since closed:

- **`it` was not bound in a `case` branch: now it is.** The examples in this
  section write `in IOError then log(it)`, and `case` has learned to bind the
  value it is matching. The binding is an ordinary assignment the expander
  writes into each branch, so `it` picks up the narrowing that branch already
  did: in the `IOError` branch it *is* an `IOError`, not the whole union. Three
  consequences follow from it being an assignment rather than new machinery:
  `it` outlives the `case` exactly the way a variable assigned inside an `if`
  does; a nested `case` shadows the outer one's `it`; and `it` is a name an iyi
  program should not use for anything else. A `case` over a tuple subject binds
  nothing, since there is no single value to name, and a Crystal file is
  untouched.
- **The orphan rule was vacuous for a top-level trait: now it holds.** `Error`
  has no module, and coherence is satisfied by being inside the trait's module
  *or* the type's; where the trait's module was taken to be the top level,
  everyone was inside it, so `impl Error for String` was accepted from any
  module and two of them could both write it. The fix is that **the top level
  is not a module**: a side of the rule counts only when there is a real module
  on it to be inside of. So `impl Error for T` must live in `T`'s module, and
  `impl Error for String`, where neither side belongs to anyone: is an orphan
  from everywhere and is rejected outright.

  This is not special-casing `Error`. It is the same correction for a prelude
  type, which belongs to no module either, and it leaves both real sides of the
  rule open: `std/traits` still writes `impl Comparable for Int32`, because it owns
  `Comparable`. The one place the top level still answers is a program that never
  writes a module header. A single compilation unit, with no other module an
  impl could have gone in, and nothing for the rule to say.

Two degenerate cases are rejected at compile time rather than given surprising
meanings:

- `def f : IOError`, not a union, nothing to propagate. `f()!` is an error.
- `def f : IOError | ParseError`. Every member is an error, so `!` could never
  produce a value. Also an error. If a function genuinely never succeeds, its
  return type is `NoReturn`.

#### III.1.2 The propagation operator: **BUILT**

For `expr : T | E` where `E : Error`:

- if the value is a non-error member, `expr!` evaluates to it;
- if it is an error member, `expr!` returns it from the enclosing function.

The enclosing function's return type must already include `E`. There is no
implicit widening.

**Built, and it needed no type machinery.** `expr!` expands to

```
tmp = expr
return tmp if tmp.is_a?(::Error)
tmp
```

which is a purely syntactic rewrite. `Error` is an ordinary trait, so `is_a?`
narrows `tmp` in what follows to the union's non-error members. That *is* "if
the value is a non-error member, `expr!` evaluates to it". And the rule above,
that the enclosing function must already include `E`, is not enforced
separately: it is the ordinary return-type check on the `return` the expansion
wrote. `::Error` rather than `Error`, so a module with a type of that name
cannot change what the operator means.

The operator is attached-only: `f(x)!` propagates, `f !x` still means `f(!x)`.
`!` is left out of names by III.1.7, and the one place that still explains the
naming convention is a `def` name, where there is nothing to propagate.

III.1.1's two degenerate cases are rejected, along with a third the build found:
`!` on a type with **no** error member: `Int32?`, say, since `Nil` is not an
error. Without that check it compiles and silently does nothing, which is worse
than either case the section already named.

```
pub def load(path : String) : Config | IOError | ParseError
  text = read(path)!          # read  : String | IOError
  parse(text)!                # parse : Config | ParseError
end
```

**Narrowing.** `expr!` removes *all* error members, so the result type is the
union of what remains. This falls out of unions rather than being bolted on:

```
find(id)         # => User | Admin | NotFound | DBError
find(id)!        # => User | Admin
```

That is a real payoff of choosing unions over a two-parameter `Result`, which
would have forced the success side into a single type or a nested tuple.

**Error sets are just aliases**, so wide signatures stay readable:

```
pub alias LoadError = IOError | ParseError
pub def load(path : String) : Config | LoadError
```

**Inside blocks**, `!` returns from the enclosing *method*, matching Crystal's
existing `return`-in-block semantics. `items.map { |x| parse(x)! }` therefore
abandons the whole method on the first failure. Consistent, and worth stating
because the alternative reading is defensible.

#### III.1.3 Handling: **BUILT**

Nothing new is required. Exhaustive `case`/`in` over a union already exists and
already checks totality:

```
case load(path)
in Config     then serve(it)
in IOError    then log_missing(it)
in ParseError then log_invalid(it)
end
```

Adding a new error member to `load` turns every incomplete `case` on it into a
compile error. This is the main ergonomic argument for the whole approach and it
costs nothing to build.

Two conveniences for the cases where matching is overkill:

```
port = read_port().or(8080)     # value, or a default
port = read_port().or_panic     # value, or panic. The `unwrap` of this design
```

These are compiler-known on error unions rather than ordinary trait methods.
They have to be: by II.1 an ordinary method call on `Int32 | ConfigError` would
require *both* members to implement it, which is precisely the thing being
avoided here.

**Built, and like `!` they needed no type machinery.** Both expand to the same
`is_a?(::Error)` the operator uses:

```
tmp = read_port()               tmp = read_port()
if tmp.is_a?(::Error)           if tmp.is_a?(::Error)
  8080                            ::raise tmp.message
else                            else
  tmp                             tmp
end                             end
```

The result type falls out of that `if` rather than being computed. `.or` yields
the default unioned with the non-error members: `Int32` for the example above,
and honestly `Int32 | Char` if the default is a `Char`, since nothing here
narrows what the author wrote. `.or_panic` yields the non-error members alone,
because `raise` is `NoReturn`. And `tmp.message` is only reached where `tmp` has
been narrowed to the error members: they all implement `Error`, so by II.1 their
union does too, and the call resolves without this having to know which error it
holds.

The default is evaluated only when there is an error to recover from, matching
what a reader of `||` would expect.

Three things the build settled:

- **The two degenerate operands are rejected, as they are for `!`.** With no
  error member there is nothing to recover; with every member an error, `.or`
  can only ever return its default and `.or_panic` can only ever panic. Both
  are dead code wearing a fallback's clothes.
- **`or` and `or_panic` are reserved names in iyi.** That is what
  "compiler-known" costs: they are recognised at the call site by name, so an
  iyi program cannot define or call a method of either name. Only iyi: a
  Crystal file's `.or` is an ordinary call and is untouched.
- **`or_panic` panics.** III.1.4 is built: the `::raise` it lowers to *is*
  the panic — it dies at the task boundary carrying the error's
  `message`, and the line the previous revision promised would change
  changed by not needing to.

#### III.1.4 Panics, and cleanup: **BUILT — measured by `bench/panics.sh`**

Panics are for bugs, not control flow: index out of range, division by zero,
a violated invariant. They unwind and are catchable **only at task boundaries**,
so a panicking fiber cannot die silently.

**Built, and the unwind owns no unwinder.** The question Part V.5 held —
what exactly the task boundary does — is answered by the group the
language already had:

- **A panic prints once, at the site of the bug** - the message, then
  `  at file:line` for a `raise` in the program's own code (a panic the
  library raises — an index out of range in the prelude, a zero slice
  size in `std` — names no library line: that is not where the bug is)
  - **on the error stream, through a write that
  cannot fail**. Both halves are load-bearing. A panic is not the
  program's output, so `prog > data.json` finds no panic inside the
  JSON; and the print cannot be allowed to panic, because printing
  through the ordinary stream meant a refused write raised, and that
  raise printed, until the stack ended - a closed reader (`prog | head`)
  turned every panic into a segfault. The panic path holds no stream
  object either: it is reachable before the globals one would use are
  built. Then it unwinds by
  registry: `defer` pushes its cleanup on the way in (the normalizer
  emits `__iyi_defer_push(-> { x })` and pops on every ordinary exit),
  so the panic path walks the current task's list innermost-first
  instead of walking frames. No landing pads, no personality function,
  no libgcc — the dependency floor does not move, which is what III.10's
  "own the walk" row turns out to cost: nothing, because III.1 left
  only panics to unwind and a list is a walk you can own outright.
- **A panicking task dies alone.** Its defers run, its group is told on
  the child's own stack, the siblings are cancelled — the same policy a
  returned error triggers (III.4.3) — and the fiber is never scheduled
  again. `NoReturn` stays true, which `.or_panic`'s result type depends
  on (III.1.3).
- **Observed bugs are values; unobserved bugs are loud.** Reading a
  panicked task's handle *catches* the panic: `value` answers
  `Panicked` — an ordinary `Error` implementor carrying the message —
  so `case`, `!` and `.or` handle a caught panic with the machinery
  III.1.3 already built, and the typed `group do ... end!` propagates
  it like any other member of its error union. The read marks the
  panic delivered, and the join then owes nothing for it: the process
  outlives the bug, which is the sentence "catchable at task
  boundaries" was always owed. A panic *nobody* reads is re-raised by
  the join in the owner as `a task panicked: <message>`, exactly once
  — marked delivered before the raise, so the deferred second join
  finds nothing, and an owner already on its own panic path gets the
  mark without the noise. A nested unread failure climbs group by
  group, each boundary prefixing its report, until a boundary-less
  fiber — main — runs its own defers and exits 1.
- **Elsewhere there are no tasks**, so on targets without the
  concurrency runtime the registry is one global stack and a panic is a
  clean exit that ran the pending cleanups first — which is more than
  the previous revision offered anywhere, since a panic used to skip
  every `defer` on its way out.
- **The stack running out is a panic, and the one panic that does not
  unwind.** A fiber's stack has a guard page under it and the main
  thread's has the kernel's; running off either faulted, and the fault
  was the kernel's to report — `Segmentation fault`, exit 139. On the
  targets with a runtime the program says it itself: a handler on an
  alternate signal stack (per thread, since the stack that overflowed has
  no room to run anything) reads the faulting address and the interrupted
  stack pointer, and a fault at the stack's own edge is `iyi: panic: stack
  overflow`, on the error stream, exit 1. No defers run: they cannot, on a
  stack that is gone, which is the answer Go and Rust give the same
  fault. A fault anywhere else is handed back to the signal, so a
  `Pointer` at nothing still dies of what it did. Windows has no
  alternate signal stack, so the room is reserved in the stack instead:
  `SetThreadStackGuarantee` on a thread's own and, under a fiber's, a
  committed page carrying PAGE_GUARD with 16 KB of committed slack beneath
  it (`IyiFiber#map_stack`) — the handler runs on the stack that faulted
  and that slack is what it stands on, measured at 2,872 bytes used of the
  16,384. `bench/panics.sh` holds it on the main stack, a fiber's and a
  thread's, on every platform with a runtime, and holds the wild pointer
  apart.

The residue the first cut recorded — overflow trapping straight to a
process exit because a `fun` cannot reach scheduler state — closed the
cheap way: `__crystal_raise_overflow` steps into the ordinary panic
def, and an overflow in a task now dies at the task boundary like any
other bug. The gate's step overflows inside a `g.spawn` and reads the
boundary's report. And the registry's price is measured rather than
carried: `bench/defer_cost.sh` builds the same twenty-million-call
loop with and without a `defer` in the callee, release mode, and the
difference prices one defer at **~16 ns** on the machine that wrote
this — a node and a closure under iyi's own allocator, budgeted in CI
so it cannot quietly grow.

Because errors are values returned early, `begin`/`ensure` no longer covers
cleanup properly. Replace it with `defer`, which runs on normal return, on `!`
propagation, and on panic unwind. The compiler holds the line: a written
`rescue` or `ensure` in an iyi file is refused with the sentence above,
because a `rescue` here compiled and never ran, and an `ensure` ran on every
exit but the panic — the half of cleanup that matters. `.cr` sources keep
theirs.

```
pub def with_file(path : String) : String | IOError
  f = File.open(path)!
  defer f.close
  f.read_all()!
end
```

**Built, and panics gave it its final shape.** `defer x` expands to a
registered cleanup around the rest of its scope:

```
a                       a
defer x        ⟶        __iyi_defer_push(-> { x })
b                       begin
                          b
                        ensure
                          __iyi_defer_pop_run
                        end
```

The cleanup is written once, as a proc the runtime holds on the current
task. Every ordinary exit reaches the `ensure` — falling off the end, a
`return`, `!` expanding to a `return` (III.1.2) — which pops the proc
and runs it. A panic reaches none of them, and does not need to: the
panic path walks the same registry and runs whatever was never popped.
One list, two readers, and the promise holds on every exit including
the one that is a bug. What changed against `begin`/`ensure` is still
where the cleanup is *written*: at the acquisition, which is the entire
ergonomic point.

Two questions Part V.8 left open, both answered by Go's answers:

- **Ordering is LIFO**, and it is not a rule. A second `defer` expands
  inside the first one's body, so its push is later, its pop earlier,
  and the registry is a stack — the normal path and the panic path
  agree without coordinating. That is the only order that can be right
  when a later resource was built from an earlier one.
- **A `defer` may not propagate with `!`** (Appendix B #7), rejected in the
  parser with an error that says why.

One deliberate departure from Go:

- **The scope is the block, not the function.** A `defer` in a loop body runs at
  the end of each iteration rather than piling up until the function returns,
  which is Go's best-known wart with the feature: there, a loop that opens a
  file per iteration holds every one of them until the function is done. This is
  not an extra rule either; it is what the lowering does, and it is where Zig
  and Swift landed. The cost is that a `defer` cannot outlive the block it is
  written in, which is the same restriction stated from the other side.

`defer` is a reserved word in iyi and only in iyi: a Crystal file keeps it as an
ordinary identifier.

#### III.1.5 Nil is not an error: **SETTLED**

`T?` is `T | Nil`, and `Nil` does not implement `Error`. Absence and failure stay
distinct, as they are in Crystal today: `T?` for "not there", error unions for
"tried and failed". Existing flow typing (`if x = maybe_get`) handles nil, and
`!` does not touch it.

**No nil-propagating operator** (Appendix B #4). Not "not yet": a second
propagating operator would give absence and failure the same shape, and the
pressure would then be to unify them, which ends with `Nil` implementing `Error`
and this section deleted. Flow typing is the better tool anyway: it forces the
branch to be written where the absence means something.

#### III.1.6 Error conversion: **SETTLED: none**

Rust's `?` silently converts error types through `From`. That is convenient and
it is also the mechanism by which Rust error handling became something people
write blog posts to explain: the set of errors a function returns stops being
what its signature says and becomes what trait resolution computes.

There is no implicit conversion here, and this is not a Draft 0 restriction
waiting to be relaxed (Appendix B #3). The error type must already be a member
of the caller's return union. Two things make that livable rather than
punishing:

- **Widening is not conversion.** Error sets are aliases (III.1.2), so a caller
  that admits more errors than it raises just names a wider alias. Union
  subtyping makes this free, and it covers most of what conversion is asked to
  do.
- **Real conversion is rare and should look it.** Deliberately hiding an
  `IOError` behind a `ConfigError` is a decision about a module's public
  surface. It is an ordinary function call, written where the decision is made.

### III.1.7 The conflict this design creates: **SETTLED: A**

Working through the operator surfaced a problem the earlier draft only gestured
at. It is not cosmetic.

Crystal allows `!` as the final character of a method name: `sort!`, `map!`,
`not_nil!`, `strip!`. Postfix `!` for propagation makes `arr.sort!` **genuinely
ambiguous**: it is either a call to a method named `sort!`, or a call to `sort`
whose error is propagated.

A compiler can resolve it by preferring the method name when one exists. That is
worse than the ambiguity, because it means **adding a `sort!` method to a type
silently changes the meaning of existing `arr.sort!` call sites** from "propagate
the error" to "call the mutating method". Action at a distance, of the exact kind
R-3 was introduced to eliminate.

Three ways out:

**A. Drop `!` from identifiers. Keep `?`. Recommended.**
Adopt Swift's naming convention instead: the mutating form is the plain verb,
the non-mutating form is the participle.

```
arr.sort          # mutates in place
arr.sorted        # returns a new array
arr.reverse       # mutates
arr.reversed      # returns new
```

`?` stays legal in identifiers (`empty?`, `nil?`) and never collides, because
nilable types use `?` in *type* position, not after an expression. The loss is
one naming convention; the gain is an unambiguous operator and, arguably, a
better convention: `sorted` says what it returns, `sort!` only says it is
dangerous.

**B. Keep `!` identifiers, disambiguate by lookup.** Cheapest to adopt, and
carries the silent-meaning-change footgun described above. Not recommended.

**C. Prefix keyword: `try read(path)`.** No ambiguity, reads well in isolation,
composes badly. Compare chaining:

```
read(path)!.strip.parse!          # A
(try read(path)).strip |> try     # C, roughly: parens required at every step
```

Postfix wins wherever a fallible call is part of a larger expression, which is
most of the time.

**Decided: A.** It costs one Ruby convention and buys an operator with no
special cases.

The compiler enforces this today. `!` may not end a name in a `.iyi` file; `?`
still may. The mode comes from the file extension, so a `.cr` file is unaffected
and the prelude, which is full of `sort!` and `not_nil!`: keeps compiling.

The rejection applies at **call sites as well as definitions**. Banning only
`def sort!` would leave `arr.sort!` lexing as a single name, which is exactly the
room the operator needs. Since no iyi standard library exists yet, and no sample
used such a name, this cost nothing to adopt, which is why it was worth settling
before any stdlib code was written rather than after.

Two deliberate gaps:

- **Symbol literals are exempt.** `:sort!` is still legal in a `.iyi` file. A
  symbol is a literal, not an identifier, and since no iyi method can be *named*
  `sort!`, such a symbol can only ever refer to a Crystal method. The ambiguity
  being removed lives in call syntax, not in symbols.
- **Macro expansion is exempt.** Code expanded inside a `.iyi` file is parsed
  against a `VirtualFile`, so it lexes in Crystal mode and can still generate a
  name ending in `!`. The decision is about hand-written surface syntax, so this
  is defensible; closing it would mean making `VirtualFile` carry the mode of the
  file it expands into.

#### III.1.7a What the convention costs beside Crystal's library: **SETTLED: B**

III.1.7 settled the naming convention against a library iyi was going to write
itself. `--crystal` (Part V item 12a) put iyi's programs beside a library it did
not write, and the convention now has a cost it was not priced against.

**Measured, and it is one method.** Of everything iyi's library mutates —
`<<`, `[]=`, `concat`, `shift`, `sort` — only `sort` means something different
in the two libraries. Crystal writes `!` on the mutating member of a *pair* and
plainly for everything else, so `<<` and `shift` agree by accident of both
languages naming them the same way. The pairs are where it bites, and today
there is one:

| | iyi's library | Crystal's library |
|---|---|---|
| `a.sort` | sorts `a` | returns a sorted copy |
| `a.sorted` | returns a sorted copy | does not exist |

So `a.sort` compiles under both and means the opposite thing, silently. That is
the worst shape a difference can take, and it is worth deciding now rather than
after `reverse`, `map`, `select`, `uniq` and `shuffle` arrive with the same
shape.

**Three ways out, and none of them is free:**

**A. Agree with the library you sit beside.** `sort` copies, matching Crystal,
and `sorted` goes as a duplicate. Revokes III.1.7(A)'s participle rule for this
pair and leaves iyi with no in-place sort until something names one. Costs the
convention; buys a program that means one thing.

**B. Give the mutating one a name Crystal does not use.** `sorted` stays the
copy and the in-place form is spelled out — `sort_in_place`. The convention is
amended rather than revoked: the participle rule holds except where Crystal
spells the copy with the plain verb, and there the mutating form says so. Costs
a clumsy name; buys no collision and no silence.

**C. Keep the convention as it is.** Costs the silence, which is what this
section is about.

**Decided: B.** `sorted` is the copy and `sort_in_place` is the one that
changes the receiver. The plain verb is not in this library at all, so `a.sort`
is an error under iyi's library and Crystal's meaning under `--crystal` —
different answers, neither of them silent, which is the whole point.

A rule chosen for one library is not automatically right beside two, and the
amendment is narrow: the participle rule holds, except where Crystal spells the
copy with the plain verb. There the mutating form says what it does.

**The error teaches it**, because "undefined method 'sort'" is true and useless
and the suggestion machinery cannot reach `sorted` — two edits is past its
threshold. When a name is missing and its participle is there, the compiler
says so:

```
Error: undefined method 'sort' for Array(Int32)

'sorted' is what this library calls it: `!` cannot end a name here, so the copy
takes the participle and the one that changes the receiver says so
```

Asked of the type rather than of a list, so it answers for whatever the library
grows next — `reverse`, `map`, `uniq` — and stays quiet for a name nobody
spelled that way.

#### III.1.8 Worked comparison

Crystal today:

```crystal
def load_config(path : String) : Config
  text = File.read(path)          # raises IO::Error
  Config.from_yaml(text)          # raises YAML::ParseException
end

begin
  config = load_config("app.yml")
rescue ex : IO::Error
  STDERR.puts "missing: #{ex.message}"
  exit 1
rescue ex : YAML::ParseException
  STDERR.puts "invalid: #{ex.message}"
  exit 1
end
```

iyi:

```
pub def load_config(path : String) : Config | IOError | ParseError
  text = fs.read(path)!
  Config.from_yaml(text)!
end

case load_config("app.yml")
in Config     then run(it)
in IOError    then abort("missing: #{it.message}")
in ParseError then abort("invalid: #{it.message}")
end
```

The bodies are the same length. The signature now states what can go wrong, and
the `case` is checked for totality: adding a third failure mode to
`load_config` breaks this call site at compile time instead of at runtime.

**The honest cost.** Every fallible function's signature grows, and every caller
either handles or propagates. In a deep call chain that is real friction, and it
is the friction Go is criticised for. `!` and error aliases blunt it; they do not
remove it. This remains the largest departure from Ruby feel in the design.

### III.2 Garbage collector: **SETTLED by II.5**

No longer an open question. R-4 forces a precise collector; recommendation is
precise, generational, non-moving for Draft 0.

### III.3 `method_missing`: **CUT**

It requires an open method set, which R-3 closes by construction: a type's
methods are what its module declares plus its impls, all of it readable from
export metadata. A hook that answers calls nobody declared makes that set
unknowable, which is the one thing the compilation model needs it to be.

Grounded rather than asserted: in the Crystal standard library `method_missing`
appears **once**, as the hook definition in `object.cr`. **Kemal does not use it
at all.** Meanwhile `responds_to?`. The static alternative: appears across 34
files. The dynamic escape hatch is close to unused; the static one is what
people actually reach for.

**Cut.** `macro method_missing` is rejected in a `.iyi` file, with an error that
names R-3 and points at `responds_to?`. Only there. A Crystal file keeps the
hook, and the prelude's own definition of it is untouched. Compile-time
`responds_to?` works unchanged, which the error message is entitled to claim
because it is tested.

### III.4 Concurrency: **BUILT on Linux in III.4.8's order — scheduler, cancellable primitives, `group`, `Channel` (rendezvous), `select`, the typed group (III.4.9), `Atomic(T)` (III.4.10), a kernel thread the collector stops (III.4.11), `Share` gating its block (III.4.4)**

This is the section where the design either beats Go or does not, so it is worth
being blunt about where Go actually loses. Not goroutines: they are cheap, the
scheduler is good, and nothing here improves on them. Go loses in three places,
all of them the same shape: **the compiler is not told anything, so the failure
shows up at runtime or not at all**:

1. **`go f()` is fire-and-forget.** Nobody waits, nobody is told, and a leaked
   goroutine is invisible. There is no construct that makes "this finished"
   checkable.
2. **Data races compile.** Sharing a map across goroutines is legal Go. `-race`
   is a runtime detector that finds what a particular execution happened to do.
3. **`context.Context` is a parameter, not a property of the work.** It is
   viral, appears in nearly every signature, carries values in a
   `map[any]any`, and cancellation is cooperative. You must remember to select
   on `Done()` in every loop.

The recommendation below turns each of the three into something the compiler
knows. It is not built, and none of it is free.

#### III.4.1 Concurrency is introduced by a scope, never by a call

There is no bare spawn. A task is started inside a group, and the group's block
cannot be left until every task started in it has finished:

```
pub def fetch_both(a : String, b : String) : Tuple(String, String) | IOError
  group do |g|
    x = g.spawn { read(a) }
    y = g.spawn { read(b) }
  end!
end
```

**This is `defer` again, and that is the argument for it.** III.1.4 built a
cleanup that runs on a normal exit, on a `!` propagation, and on an unwind, by
lowering to an `ensure`. A group is that same guarantee applied to a set of
tasks: the join is deferred to the end of the scope, so there is no exit, not a
`return`, not an error, not a panic. That leaves a task running. Go's leak is
unrepresentable, and it costs no new mechanism.

The cost is real and should be stated: a task cannot outlive the scope that
started it. Work that genuinely must outlive its caller is started from a group
that lives as long as it should: usually one owned by the program's entry
point, and that group is written down rather than implied. Trio, Kotlin and
Swift all landed here; Go is the outlier.

#### III.4.2 Cancellation belongs to the group, not to a parameter

Because a group owns its children, cancellation is a property of the scope, not
an argument threaded through every signature. There is no `Context` parameter.
A group cancels its remaining children when the block leaves early, when a
child fails under the group's policy, or when an enclosing group is cancelled.

**This has a runtime dependency, and it is the same class of dependency as
II.5's precise collector: it constrains the runtime from day one rather than
being added later.** Cancellation is worthless unless it reaches a task that is
*blocked*, so every blocking primitive (channel receive, IO, sleep) has to be
cancellable. A cooperative check the author has to remember is Go's answer, and
it is the part of Go's answer people get wrong.

#### III.4.3 A task's failure is an error member

The group returns what its tasks return, and an error from a task is an ordinary
member of that union, so `!` propagates it (III.1.2) and `case` handles it
exhaustively (III.1.3). Nothing new is required, which is the whole point:
Go needed `errgroup`, a library, because `error` carries no type information a
signature could have stated.

Default policy: the first failing task cancels its siblings and the error leaves
the group. That is `errgroup`'s behaviour, typed and built in.

#### III.4.4 Data races are a compile error, and R-3 is why that is affordable: **BUILT, gating the block a thread runs**

A marker trait, `Share`, decided structurally: a type is shareable if every
field is shareable and none is mutable, or if it is a synchronised type that
owns its contents: `Mutex(T)` is shareable when `T` is. A value that is not
shareable cannot be captured by a spawned block or sent over a channel.

**Built, as written, with the obligations below met.** `Iyi::Share`
(`src/compiler/iyi/semantic/share.cr`) decides a type structurally: a
field is mutable if any method other than `initialize` assigns it, by any
spelling, or a setter `field=` is defined for it — III.4.7's mechanical
rule, on the compiler's own AST rather than the count's — and every
field's type must be shareable in turn: integers, floats, `Bool`, `Char`,
`Nil`, `Symbol` and enums are; `Pointer` is raw memory and is not;
`StaticArray` and a `Proc` are not; a tuple, named tuple or union is when
every member is; a class typed as its base is when every subclass is. The
trust half is `@[Share]` on a declaration, meaning shareable whenever the
type arguments are, whatever the fields do: `Atomic(T)` carries it, and
`src/std/list.iyi`'s `List(T)` carries it, the list this section
said should stay short. The marker travels: a producer writes `@[Share]`
into the artifact declaration of every type it found shareable, and a
consumer reads that and never recomputes — the bodies that said no field
is assigned are not in the artifact, so an imported type without the
marker is refused with the artifact as the reason. What it gates is the
block `IyiThread.start` runs on another thread (III.4.11): every variable
the block captures, and `self` when the block reaches an instance
variable, must be `Share`, and the error names the variable, its type and
the field that failed, one level at a time — ``captures `items :
Array(Int32)`, which is not Share: Array(Int32)'s field @size is assigned
in `unsafe_set_size` ``. The channel's `T : Share` (III.4.6) waits for the
channel that crosses threads. Held by `spec/compiler/semantic/iyi_spec.cr`
(eight shapes: immutable captures pass, a setter, an assignment outside
`initialize`, a field one and two levels down, `@[Share]` trusted, a
trusted generic refused by its argument, `self`), by
`spec/compiler/iyimod_spec.cr` (the marker written, read and refused
across an artifact) and by `bench/thread_exercise.sh`'s last step, a
program that must not compile.

This is Rust's `Send`/`Sync` **without** ownership or borrowing, and it is worth
being exact about what that buys and what it does not. It rules out data races,
because anything two tasks can both reach is either immutable or synchronised.
It does not rule out deadlock, and it does not rule out logical races. Aliasing
is untouched. The restriction is on the *type*, not on who points at what,
which is exactly why it needs no borrow checker.

**The interaction that makes it affordable is R-3.** A structural marker is only
computable if a type's field set is final, and open classes are what would
break that: any module could reopen a type and add a mutable field, and
shareability would no longer be a property the defining module could state.
With R-3 it is, so `Share` is computed once by the module that declares the type
and travels in its export metadata (IV.2) like any other exported fact. A
consumer checks a spawn against a marker it read from a `.iyimod`, with no
global pass. The same result IV.4 reaches for coherence, for the same reason.

**This is the decision most likely to be wrong, so here is the alternative and
why it lost.** The other sound answer without ownership is Erlang's: no sharing
at all, tasks communicate only by copying. It is simpler and it is proven. It
was rejected because copying cost is not something a systems language can hide,
and because `Mutex(T)` gives the escape hatch that Erlang has to route through a
process. The count in III.4.7 was to be the arbiter, and it came back for
`Share`: the class this section feared turned out to be empty, and clean-sheet
iyi code is 77% shareable as written.

**It came back with an obligation attached, though, and the obligation is
now met.** Every failure in that clean-sheet code was a type holding an
`Array`, which made a **shareable immutable collection** something the standard
library owed the language rather than a convenience: without it the `Mutex(T)`
escape becomes the normal case, and an escape hatch used routinely is the
definition of a failed rule. `src/std/list.iyi` is that collection, and
`samples/iyi/immutable.iyi` exercises it.

Two things building it settled that the count could not:

- **The collection cannot derive `Share`; it has to be trusted.** `List(T)`
  holds an `Array(T)`, so structurally it fails its own marker, and the
  counting tool duly reports it as failing, which is the demonstration rather
  than an embarrassment. What makes it safe is that it *owns* the array and
  never hands it out, and ownership is exactly what this design has no way to
  express, having refused a borrow checker. So `List` joins `Mutex` as a type
  the compiler trusts rather than checks. That list should stay short, but it
  cannot be empty. Rerunning the count with `List` present: 14 of 14 sample
  types pass once a shareable collection exists, against 10 of 14 without.
- **The constructor has to copy, for the same missing reason.** A caller that
  keeps the array it passed in could otherwise mutate the list from underneath
  a task holding it. Rust says "I own this now" and pays nothing; here it costs
  one copy at the boundary. `immutable.iyi` demonstrates the failure that copy
  prevents rather than asserting it.

#### III.4.5 What this settles about module-level state

II.9 recorded that the Kemal port replaced `Kemal::RouteHandler::INSTANCE` and
its neighbours with one application value, and noted that **nothing in the
design forced it**: separate compilation permits module-level state, so it was
taste and a suspicious comment in `router.cr:270` doing the work.

III.4.4 is the rule that was missing. Module-level mutable state is not
shareable, so it is not reachable from a task; it is either immutable or it is
behind a synchronised type. The Kemal port did by hand what this makes checked,
and Part V.5's question about the interaction between concurrency and
module-level mutable state is answered: there is no interaction, because the
combination does not compile.

#### III.4.6 What carries over from Crystal, and what does not

- **`Channel(T)` carries over**, with `T : Share`.
- **`select` carries over** unchanged.
- **`Fiber` does not carry over as a user-facing primitive.** It is how a task
  is implemented. Exposing a raw spawn puts III.4.1's leak straight back.
- **Parallelism is not free of the rest of the design.** IV.1d already measured
  that only the forking thread survives a `fork`, which is why the build daemon
  is single-threaded. A multi-threaded runtime and a fork-based daemon are in
  tension, and that is a measured fact rather than a prediction.

#### III.4.7 What `Share` costs: **COUNTED**

Every other rule in this document that costs users something was decided by
counting, and `Share` was not to be built before the same was done to it. The
count is `bench/share_count.cr`, which makes the marker mechanical: a field is
**mutable** if it is assigned anywhere other than the constructor, or if an
accessor macro generates a setter for it; a type fails if any field is mutable
or any field's type fails.

| | `samples/iyi` | the compiler's own source |
|---|---|---|
| types that can hold state | 13 | 483 |
| directly mutable | 0 (0%) | 118 (24.4%) |
| fail once field types propagate | 3 (23.1%) | 297 (61.5%) |
| …only because a collection is mutable | 3 (23.1%) | 2 (0.4%) |
| …only because of a generated setter | 0 | 42 (8.7%) |
| **pass `Share`** | **10 (76.9%)** | **186 (38.5%)** |
| pass given a shareable immutable collection | 13 (**100%**) | 188 (38.9%) |
| hold class variables (III.4.5) | 0 | 3 (0.6%) |

**The class this section told itself to fear is empty.** "Immutable in practice
but holds a mutable field for one initialisation" describes no type here,
because a construction-only write is not a mutation, and letting it pass is
sound rather than lenient: a value is not reachable from another task until it
exists, so there is no second party to observe the write. Zero of the sample
types are directly mutable at all. The escape hatch that would have signalled a
failed rule is not needed for this reason.

**Nor for the reason next most likely.** Only 8.7% of the compiler's types fail
solely because of a generated setter, so "move the field into the constructor"
is not a fix anyone would be applying constantly either.

**What the count actually found is that the two corpora disagree, and why.**
Clean-sheet iyi code is 77% shareable as written and **100% shareable given one
missing piece**: every failure in it is a type holding an `Array`. The compiler
is 38.5% shareable and stays there, because its failures are not collections but
its own mutable object graph: `MainVisitor` with 35 mutated fields, `Compiler`
with 34, `Formatter` with 32, `Parser` with 30.

So `Share` is not a rule that fails; it is a rule that **prices a style**. It
costs nothing for code written the way the ported samples are written, and it is
close to unpayable as a retrofit onto a program built as a mutable workspace.

**The compiler is the control case, and it agrees with something already
measured the hard way.** IV.1d records that the build server could not be made
concurrent by adding fibers. The obvious fiber-per-connection version deadlocked
and died, and the daemon had to fork instead. That took two attempts and a
debugging session to discover. `Share` says the same thing about the same code
statically, before anything runs. A marker whose verdict matches a fact that
previously cost a failed implementation to learn is measuring something real,
not merely being restrictive.

**Verdict: keep `Share` (Appendix B #9), with one dependency.** The stdlib owes
the language a **shareable immutable collection**, and it is not optional,
without it a quarter of clean-sheet iyi types fail the marker for a reason that
has nothing to do with how they were written, and the only workaround is
`Mutex(Array(T))` everywhere, which is exactly the routinely-used escape hatch
that would mean the rule had failed. Rust answers this with an immutable borrow,
which is not available here; Erlang answers it with immutable collections by
default, which is. This is the same shape of dependency as II.5's precise
collector: a language rule that constrains the library from day one.

**Limits.** The tool reads syntax, not types: field types are matched on the
last segment of their path, so a name used in two namespaces is conflated, and
`Mutex(T)` is counted as mutable rather than as the synchronised escape it is
meant to be, which makes these numbers a lower bound on what passes. It also
cannot answer the second half of the original question, "how many of those are
reached from something that would plausibly be spawned", for the compiler, which
spawns nothing. For the samples it can: the three failures are `Nums`, `Words`
and the Kemal router's route table, and the router is precisely the thing a
server would share across tasks.

#### III.4.8 What to build first, and what not to build: **SETTLED: nothing before a scheduler; BUILT in that order**

III.4 is specified and unbuilt, and the question this section had left open is
not whether to build it but which piece first. Asked properly, the answer is
that the obvious cheap slices are all dishonest, and it is worth writing down
why so nobody reaches for them again.

Iyi's own library had no concurrency surface of any kind when this was
written: no fiber, no thread, no scheduler, no channel, no mutex, no atomic
(the atomic is III.4.10 now, the rest is built below). A program built
`--crystal` has all of Crystal's (`src/fiber.cr`, `src/concurrent.cr`,
`src/channel.cr`, `src/atomic.cr`, `src/crystal/scheduler.cr`), which is
III.4.6's point: those are the thing III.4 was written to replace, not an
implementation of it.

Three slices were ranked:

1. **`Share` alone.** The cheapest. It is a static marker and the machinery it
   needs mostly exists: `collect_iyi_fields` in `src/compiler/iyi/compiler.cr`
   already walks a type's field set into the artifact's `TypeDecl`, and
   `bench/share_count.cr` already computes mutability, so the analysis has been
   written once. What it lacks is a caller. Nothing can spawn and nothing can
   send, so the marker would gate no operation, and a rule that refuses nothing
   cannot be tested for refusing the right things.
2. **`group` reusing `defer`'s lowering, running tasks sequentially.** III.4.1
   says a group is `defer` again, and it is right: `Defer` parses in
   `src/compiler/iyi/syntax/parser.cr` and lowers to an `ensure` in
   `normalizer.cr`, and a join-at-scope-exit is that same shape. The syntax
   would cost little. **Rejected.** A `group` whose tasks run one after another
   is not concurrency, and shipping the spelling of a feature without the
   feature is the worst outcome available here: it would typecheck, run, print
   the right answer, and teach everyone the wrong thing about what iyi does.
   III.1.7a settled that a name meaning two things is worse than a different
   name; a name meaning nothing is worse still.
3. **A scheduler, cancellable blocking primitives, then `group` and
   `Channel(T : Share)`.** The only slice that is usable and testable. It is
   also the expensive one, and III.4.2 already said so: cancellation is
   worthless unless it reaches a blocked task, so `__iyi_read` and its siblings
   in all four platform branches would have to stop being direct blocking
   syscalls and become non-blocking registrations against a poller the
   scheduler drives.

**Verdict: III.4 is built in the order 3, and not begun before that order can
be paid for.** `Share` is not built first despite being cheapest, because a
marker with no caller is a mechanism nobody can check, and this document has
refused that shape twice already.

The dependency floor (III.9) is the other cost to name in advance: a program's
Linux object has zero undefined symbols today because the prelude issues raw
syscalls. A poller is more syscalls, which is fine, but a scheduler that reached
for pthreads would put libc back on the link line and take III.9 with it.

**Built, in exactly that order, and measured where it can lie.** The runtime
is `src/iyi/concurrency.iyi`: a one-word context (the saved stack pointer,
everything else lives on the stack it names), a naked two-instruction-set
switch that `@[NoInline]` had to protect from the optimiser before the
release build stopped faulting, 256 KiB fiber stacks over the runtime's own
`mmap` with a guard page under each, a run queue, a deadline-sorted sleep
list, and an `epoll` the scheduler drains whenever nothing is runnable — raw
syscalls throughout on Linux, so the floor above holds: the gate counts the
exercise binary's undefined symbols and the runtime is allowed to add none
there, and the aarch64 object still has zero. What the same gate holds on
darwin is the paragraph after the next one, because darwin's floor was never
"zero symbols".

`bench/concurrency_exercise.sh` is the gate, and its first property is the
one slice 2 was rejected over: two tasks ping-pong through channels and the
letters must alternate, which a sequential `group` cannot produce; the gate
then proves that assert can fail by running a misordered copy and requiring
exit 1. The III.4.2 claim is asserted as time: a task blocked in a 10 s
sleep leaves in tens of milliseconds when a sibling fails, or the exercise
fails. Cancellation is delivered as a value — a woken primitive answers
`Cancelled`, an ordinary error member, so `!` drains a cancelled task
through its remaining waits, which is III.1.2 doing III.4.2's plumbing. The
join is `defer`'s lowering applied to a task set, as III.4.1 predicted: a
`return` out of the block still joins, and the gate holds a deadlocked
program to a diagnosis (`deadlock: every fiber is blocked`) rather than a
hang.

**darwin arm64 runs the same runtime, through libSystem — III.9's darwin
rule applied to the poller.** The port changes who is called and nothing
about what the calls mean: one kernel thread still runs every fiber, the
context is still one word, the aarch64 switch is the same twenty-slot frame
Linux swaps, cancellation is still a `Cancelled` value a woken primitive
answers, and the defer registry and the panic path are the
platform-independent code they always were — the port did not touch them,
it opened their guards. What is different is the doorway: Linux's raw
`mmap`/`mprotect`/`clock_gettime`/`epoll` syscalls are libSystem's `mmap`,
`mprotect`, `clock_gettime_nsec_np` and `kqueue`/`kevent` on darwin,
because Apple documents libSystem as the platform's only supported
interface and raw syscalls as explicitly not a stable ABI — the same rule
the prelude's `write` already follows there (III.9), and the same
conclusion Go reached. The poller is a kqueue: one `EV_ADD` per waited fd
where Linux does `EPOLL_CTL_ADD`, one `EV_DELETE` where it does
`EPOLL_CTL_DEL`, and one honest asymmetry recorded rather than smoothed —
each poller refuses a different kind of fd, epoll a regular file with
`-EPERM`, kqueue the null device with `EINVAL` (measured on `/dev/null`,
which took `samples/iyi/calc` down until it was), and both refusals get
the same answer: a fd the poller cannot watch is one whose read never
parks, so the wait returns "readable now" instead of dying. The floor
(III.9) does not move, because darwin's floor was never a
symbol count: it was libSystem and nothing else, and it still is — the
undefined-symbol list grows by `kqueue`, `kevent`, `clock_gettime_nsec_np`
and errno's `__error` in every program (the panic path runs through the
scheduler), and by `mmap`/`mprotect` in one that spawns a task, all of it
recorded in `bench/dependency_floor.sh` in the
same commit that caused them, which is that script's own rule for how a
dependency is taken on.

What is *not* built, said here rather than left to be found: `Share`
gated nothing when this was written — deliberately, because one thread
interleaves only at parks and cannot race; III.4.11 ended that, and
III.4.4 is built now, gating the block a thread runs (the shape this
document has refused three times is a mechanism with no caller, and it
got one first);
the rendezvous channel and `select` are both in — `Channel(T).new` parks a
sender carrying its value in its queue node's box, an emptied box is the
delivery receipt, a park is named by a nonce so a node a cancellation left
behind is skipped by arithmetic, and `select`'s expansion is served by one
variadic def whose macro walks the arm tuple's arity, over any mix of
receive and send arms, with `else` served by `non_blocking_select` (the
ceiling that stood in its way was remeasured instead of raised — the
paragraph under "The ceiling was not a guess" says how);
`group do ... end!` types its own return now (III.4.9, the section says
what the build corrected) — a *dynamic* group's union still
comes out through `task.value`; a fiber blocked *joining* is the one park
cancellation does not reach, which a failing group papers over by
cancelling every child; and the platforms that cannot carry the model get
nothing rather than an imitation: wasm32 cannot switch stacks (measured in
III.4.12). darwin arm64 and Windows x86_64 run the real runtime: darwin's kqueue
poller is the paragraph above, and Windows x86_64 uses handwritten asm with TEB
stack bounds management (gs:0x08 and gs:0x10), IOCP completion polling, and
CancelIoEx cancellation reaching blocked IO, holding the windows-runtime gate in CI.

#### III.4.9 The typed group, `group do ... end!`: **BUILT, with one correction the build forced**

III.4.1's example types its group — `Tuple(String, String) | IOError` — and
the runtime does not: today a task's union comes out through `task.value`,
one handle at a time, and the group expression is `Nil`. This section is the
design for closing that gap, written before the code because every piece of
III.4 that went well went in that order.

**The recommendation is an expansion, not type machinery — the same move
`select` was.** `select` compiles to calls the library already answers and a
`case` the language already checks; the typed group compiles to joins the
runtime already does and `is_a?` narrowing the language already has. From:

```
group do |g|
  x = g.spawn { read(a) }
  y = g.spawn { read(b) }
end!
```

to the same block with the extraction appended (hygienic names throughout):

```
group do |g|
  x = g.spawn { read(a) }
  y = g.spawn { read(b) }
  g.join
  %v1 = x.value
  if %v1.is_a?(::Error)
    %v1
  else
    %v2 = y.value
    if %v2.is_a?(::Error)
      %v2
    else
      {%v1, %v2}
    end
  end
end
```

**The correction: the block stays a block.** The first build inlined the
block's statements into the caller, and the gate's own `task.value`
property broke it: a name the block used collided with a name a *later*
closure captured, and a closured variable does not narrow, so an `is_a?`
that had always worked stopped. Appending to the block instead keeps every
name scoped where the author put it; what changed to allow it is one line
of the runtime — `group` answers what its block answers (`& : IyiGroup ->
U) : U forall U`), so the appended extraction *is* the group's value.

`!` then applies to that expression's type — `Tuple(String, String) |
IOError | Cancelled` — through the machinery III.1.2 already built. Nothing
new is typed: the tuple's elements are non-error by the same narrowing `!`
itself expands to, the error side is the union of what the branches answer,
and the first failing task has already cancelled its siblings by the time
`join` returns, so the extraction order cannot deadlock on a loser.

**What qualifies.** The expansion applies when the block's parameter is
used as the receiver of direct `spawn` statements — assigned or bare, not
inside an `if`, a `while` or a nested block — and nowhere else, because a
tuple has an arity and a loop does not. A group whose spawn count is
dynamic keeps the general shape: the group is its block's last expression,
handles answer through `task.value`, and that is not a diminished mode but
the general one. The marginal cases fall back to it quietly; a `!`
demanding the typed form of a group that cannot have one is refused by
`!`'s own degenerate-union check, which names the type it found.

**What it costs, named before it is paid.** A bare `g.spawn { }` whose value
nobody reads still contributes a tuple slot, because leaving it out would
make arity depend on use; `_ =` is the explicit discard. A nested group
types itself independently, inner first, which the expansion gets for free
by being bottom-up. And the `defer`red join stays: the expansion joins
early to read values, the deferred join then finds `@live` at zero and
costs one comparison — the leak guarantee is not traded for the type.

**Where the compiler hooks, decided by precedent.** `group` is a prelude
method today, and the expansion recognises it the way `.or` and
`.or_panic` are recognised (III.1.3): at the call site, by name, in an iyi
file only — which makes `group` a reserved name in iyi, the cost that
"compiler-known" always charges. The alternative was a keyword like
`defer`, and it buys nothing here: the dynamic case must keep lowering to
the method call anyway, so the name is load-bearing with or without a
parse node of its own.

Two facts the build wrote down. `end!` did not lex: the lexer's keyword
check counted an attached `!` as an identifier's tail, so `end` came back
an identifier and the block never closed — III.1.7's "`!` is not part of a
name" now applies to a keyword's name too. And the parser marks the call
(`Call#iyi_group?`, the `IsA#error_construct` precedent) for the
normalizer to expand, because a bare `group do` carries an empty argument
list some paths and no list on others, and the flag is the fact rather
than the shape. Gated in `bench/concurrency_exercise.sh`: the tuple, the
first-error union through `!`, and a loop-spawning group asserted to keep
the general form.

#### III.4.10 `Atomic(T)`: **BUILT — one ordering, six verbs, on the floor**

The first piece of III.4 that assumes a second thread, and it arrived the
way III.4.8 said every piece would: with a caller. `bench/thread_floor.iyi`
counted its threads in and out through three `fun`s of inline asm because
the prelude had nothing to count with, and the release build's `xchg`
clobbered a register the asm had declared an input (the Fixed entry in
CHANGELOG.md). The runtime's cutover to threads (GC_DESIGN.md) names what
the prelude's atomic must carry — the mark word's CAS, every shared
counter, the arena list — so the type was built for the probe and the
probe became its gate.

`Atomic(T)` is a struct holding one word, `T` one of the four integers
`primitives.iyi` gives arithmetic to (`Int32`, `Int64`, `UInt8`,
`UInt64`), and six verbs: `get`, `set`, `add`, `sub`, `swap`,
`compare_and_set`. The names and their answers are Crystal's, so a program
that reads the same under `--crystal` means the same: the three
read-modify-writes answer what the word held before, and
`compare_and_set` answers that value and whether the exchange happened,
which is what a retry loop needs without a second load. The instructions
are the compiler's — `atomicrmw`, `cmpxchg`, an ordered load and an
ordered store, four `@[Primitive]`s in `primitives.iyi` — not asm, so the
register allocation is LLVM's and the aarch64 arm is whatever the CPU
offers (`ldaxr`/`stlxr` loops; LSE's `ldaddal` where the target has it).

**One ordering, sequentially consistent, and no parameter to weaken it.
This is the decision.** It is Go's rule — its memory model makes every
`sync/atomic` operation sequentially consistent and the package has no
ordering argument — rather than C++'s or Rust's, and the reasons are the
ones this document has used before. An ordering parameter is the part of
an atomic API people get wrong, the compiler cannot check, and a program
cannot test for; the price of not having it is a fence on the
architectures that distinguish the orderings; and on x86_64, the machine
the floor was measured on, a sequentially consistent `add` and a relaxed
one are the same `lock xadd`, so the price is zero where it was measured
and not yet a number where it is not. On aarch64 the difference is
`ldaddal` against `ldadd`. The day a profile of the marker or the
scheduler names that difference, the measurement is what adds the weaker
spelling, and it is added as its own verb rather than a parameter, so a
call site says what it means. `fence` is not built: nothing calls one. A
pointer or a reference as `T` is refused by name rather than admitted
untested; the arena list that will want one brings it.

What it costs the floor is nothing, and that is asserted rather than
assumed: a 64-bit-or-narrower atomic is an instruction on every target
iyi links for, never a `__atomic_*` libcall, and `bench/thread_floor.sh`
reads the five C-template names off the binary that uses one, plain and
release, on both Linux arms and on darwin. Where a target has one thread
the instructions lower to plain loads and stores — wasm32 — so the type
costs nothing where nothing can race and needs no gate. The gate's own
failure proof is the contract: every thread adds to one shared word on
every turn of its loop beside a word of its own, the two totals must
agree, and with a load and a store in the atomic's place
(`-Dtf_plain_add`) they do not — 4 threads, 23,689 adds, 12,477 landed,
the program exits 1 naming the 11,212 it lost. The contended `add` is
also what the probe's threads now run on every turn, and the pauses
GC_DESIGN.md records held their shape with it in the loop.

Two things the build found. A `@[Primitive]` cannot live on a generic
instance's class: a call on one passes the class as a first argument
(`Pointer(T).malloc` reads its size from `call_args[1]`) and the atomic
instructions take their operands from the front, so the four primitives
sit on a holder of their own, `IyiAtomic`, the way Crystal's sit on
`Atomic::Ops`. And `UInt64` has no `to_s` in the prelude — a value prints
as its type's name — which the probe never noticed because it prints
through `to_i64`; noted here rather than fixed, by the prelude's own rule.

`Share` was not built when this was written, and the reason was
III.4.8's: one thread interleaves only at parks. III.4.11 removed the
reason, and III.4.4 has it built. What this section changed is the list
of types `Share` trusts rather than checks: `Atomic(T)` is the first
synchronised type in the prelude, shareable by construction, `@[Share]`
on its declaration, and it joins `List(T)` there before `Mutex(T)` exists.

#### III.4.11 A kernel thread: **BUILT — `IyiThread`, not a task, and the collector stops it**

The second thread exists. `IyiThread.start { }` is a kernel thread in
the runtime (`src/iyi/thread.iyi`): raw `clone` onto a mapping of its own
with a guard page and a TLS block laid out from the executable's PT_TLS
on Linux, `pthread_create` on darwin, `join` the futex on the tid word
the kernel clears or `pthread_join`. It costs the Linux floor no name and
the darwin floor exactly the thread floor's list, which
`bench/thread_exercise.sh` reads off the binary. A thread gets a
scheduler state and a heap cache on first touch — III.4's scheduler and
the collector's allocator were cut over to per-thread state in the two
entries before this one — so it spawns fibers of its own and allocates
without a lock.

**It is not a task, and saying so is the design.** No group owns it,
nothing cancels it, no channel crosses it: `Channel` is one thread's,
the scheduler's queues are one thread's, and a value handed from one
thread to another is a data race — which the type system now refuses at
the door it has: the block `IyiThread.start` runs may capture only
`Share` values (III.4.4, built below), so what crosses threads is
`Atomic(T)`, immutable values, and memory a program reaches through
`Pointer` and keeps straight itself, `Pointer` being what the marker
refuses by name. A thread is not offered as a spelling for
concurrency; `group` is. It is offered because the collector's parallel
stages (GC_DESIGN.md 7 and 8) and a scheduler with M threads need one,
and because a program that wants a core for itself has never had a way
to ask.

**The collector stops it, which is GC_DESIGN.md's Stage 4, built.** A
collection takes the runtime's one lock before anything else, signals
every other registered thread, and waits for each to count itself in;
the handler copies the interrupted registers from the ucontext onto the
thread's line, records sp and pc, parks, and the collector scans the
spill and the stack from that sp to the top of whichever mapping holds
it. A thread inside the allocator or spinning for the lock is not
parked where it stands but asked, and parks itself where it holds
nothing — the rule Go states as "no preemption inside mallocgc", reached
here from the deadlock it prevents. GC_DESIGN.md carries what the build
found: the trigger's count made atomic and decided twice, the centre's
free chunks handed out in the sweep's own per-arena batches so one
thread cannot hoard, and a budget floored at half of what the sweep
walked so eight threads do not turn a MiB budget into four thousand
stops a second. The gate holds eight threads with live lists in their
frames alone through collections triggered from any of them — by
checksum and by the sweep's own free flag, after an explicit collection
with every worker spinning and after twenty bursts of churn — fibers on
threads, 32 threads past the core count, the floor, and a failure proof
that removes the thread-root walk and sweeps a spinning thread's list by
name. The price, release, 20 cores: 76 ns an allocation with one thread,
162 with four, 268 with eight, every pause included — every thread
standing still for a sweep one thread runs, which is what Stages 7 and 8
were for. Since then (GC_DESIGN.md, the sections after Stage 4's): the
sweep left the pause and runs beside the program, in slices of an
arena taken by the mark's helpers after every collection and by an
allocating thread only for the slice it needs; the mark is parallel on
helper threads and runs beside the program on a write barrier the
compiler emits, a collection being two stops of tens of microseconds;
an object is its fields, a word ahead of it only for a class something
reads the type id off (the collector's bits and the other ids are
tables at the arena's head), the classes eight bytes apart, and the
sweep hands pages back to the kernel; a mutator outrunning the mark
allocates black and assists. The price today: 13 ns an allocation in a
release build (`bench/arena_exercise.sh` asserts a ceiling on it now),
29 ns with one thread under the thread exercise's collections, 104 with
four, 282 with eight, and `bench/gc_race.py`'s table beside Boehm and
Go — the wall time under Go's and Boehm's on all three programs, the
total paused a fortieth to a tenth of Boehm's, the longest pause under
Go's on churn and binary trees and level on the live items, and the
footprint Go's on churn and binary trees and a budget over it on the
live items.

**And a fiber gives its stack back, which a server is the only program
that notices.** A fiber's stack is 256 KiB of its own mapping with a
guard page under it, and it was mapped and never returned: "a done
fiber's stack is never reused" was true of the fiber and got read as
true of the mapping. Nothing in a script minds. A server is a fiber per
connection, and there the arithmetic is the request count: the address
space grew with it, every collection walked a registry holding every
request the process had ever served, and the mappings ran out first —
`/proc/self/maps` outgrew the buffer the root walk reads it with, and
the program exited saying so after twenty thousand fibers, half a
second, no sockets involved. The rule now: **a finished fiber hands its
stack to the fiber that runs next** — nothing can free the ground it
stands on, so the successor does it, on its own stack, as its first
instruction — and leaves the registry and its group's child list on the
way out (a panicked child stays, because the boundary still owes a
re-raise for one nobody read). Two hundred sequential connections run
on one stack. The pool is per scheduler, which is per thread, so it
needs no lock: a fiber never leaves the scheduler that spawned it.

**The other half of that lesson: an address is not a reference.** The
poller's event buffer was held as `Pointer(...).malloc(...).address` in
a `UInt64` field, and the collector is *precise* over a typed object's
fields — it traces the words the layout calls pointers. A number is not
one. The first collection freed the buffer under the poller, the kernel
kept writing epoll's answers into a chunk the allocator had handed to
somebody else, and a server died at its first collection with the free
list in pieces. The field is a `Pointer(UInt8)` now. The rule this
leaves: runtime state that points into the heap is spelled as a
pointer, or it is not there at all. `bench/server_load.sh` holds both —
a fiber per connection, both halves parked on the poller, a collection
in the middle — and proves both failures by patching them back in.

**The socket parks by itself now, and a server written in iyi serves
HTTP.** `server_load` had to name the poller — `wait_readable(fd)` before
every `read`, by hand — because `IyiSocket` blocked: a fiber in `recv`
held the thread, and every other fiber with it. On the targets that have
the runtime, every socket is non-blocking and `connect`, `accept`, `read`
and `write` park the calling fiber on the poller (`wait_writable` joined
`wait_readable` for the send side, EPOLLOUT and EVFILT_WRITE); a slow
peer costs one fiber. What that changes in the type is III.4.2's
contract applied where it was always meant to apply: those calls answer
`T | Cancelled`, `!` passes a cancelled task through its remaining IO
and `.or_panic` refuses it at the top level, and a socket closed by
another fiber under a parked call answers the same, because the kernel
drops a closed fd from the poller without a word and the closer has to
wake the waiter (`wake_closed`). `bench/socket_exercise.sh` holds it: a
task parked in `read` on a connection nobody writes to leaves with
`Cancelled` when a sibling fails, on one thread, which a blocking read
could not have done. `std/http` has `Server.serve(listener) { |request|
Response }` on that socket — a fiber per connection under a group,
keep-alive across requests, chunked request bodies, `HEAD`, a 400 for
what is not HTTP — and `bench/std_http_exercise.sh` runs the module's
own client against it, Python's `http.client` against it, and `wrk -c50`
against a release build: **76,226 requests/s, 236,296 requests, every
one answered**, against the 23,705/s the kemal port under Crystal's
library did in 0.12.0 on the same shape of program.

#### III.4.12 Concurrency on wasm32-wasi: **MEASURED and REFUSED: why this target has no runtime**

SPEC.md III.4 specifies structured concurrency (`group`/`spawn`, `Channel`,
`select`, cancellation as values) on Linux x86_64, Linux aarch64 and darwin
arm64. On wasm32-wasi a program naming `group` fails to compile with an
explicit refusal. III.4.8 rejected shipping the syntax as sequential
imitation, because a `group` whose tasks run sequentially is not concurrency
and would teach everyone the wrong thing about what iyi does.

This section records the investigation into whether wasm32-wasi could support
real coroutines, what each candidate mechanism costs, what specifically blocks
it on this toolchain, and what would have to change for the verdict to flip.
The probe is `bench/wasm_concurrency_probe.sh`.

**1. Native WebAssembly stack switching.** Core WebAssembly has an unaddressable
call stack and value stack. The stack-switching proposal adds instructions to
allocate, suspend, resume and switch stacks. In wasmtime 48.0.1 (7bac2c277
2026-08-24), `wasmtime -W help` lists `-W stack-switching[=y|n]`, but passing
the flag to run a module fails immediately:

```
Error: the wasm_stack_switching feature is not supported on this compiler configuration
```

Passing `-W all-proposals=y` fails with the same error. Cranelift and Wasmtime
disable stack switching at compile time in shipped binaries. Native stack
switching is unavailable on the host.

**2. WASI threads (wasi-threads Preview1).** wasi-sdk 24 ships
`wasm32-wasi-threads-clang`. Compiling a pthread program with `-pthread
-Wl,--shared-memory,--max-memory=67108864` produces a module importing
`wasi::thread-spawn`. Running under wasmtime 48.0.1 fails by default:

```
Error: unknown import: `wasi::thread-spawn` has not been defined
```

Attempting to enable threading via `wasmtime run -S threads=y` fails:

```
Error: the `-Sthreads` flag is no longer supported
```

Attempting `wasmtime run -S preview2=n -S threads=y` fails with `the
\`-Spreview2=n\` flag is no longer supported`. Wasmtime 48.0.1 removed the
legacy Preview1 wasi-threads implementation. Furthermore, SPEC.md III.9
forbids linking pthreads, which would reintroduce libc onto the link line and
destroy the dependency floor.

**3. Binaryen Asyncify (wasm-opt --asyncify).** Binaryen provides a post-link
whole-module transformation that rewrites function bodies to unwind the call
stack into a linear-memory buffer and rewind it upon re-entry. Tested on real
binaries under wasmtime 48.0.1, Asyncify is blocked by architecture and toolchain:

- **Asymmetric host requirement.** Asyncify unwinding unwinds the entire call
  stack out of `main` and `_start`. Standalone WASI CLI hosts (`wasmtime run`)
  do not provide an Asyncify host runner to intercept the unwind and re-invoke
  entry points. In-module attempts to unwind without a host trap or exit the
  process without resumption.
- **Code size penalty.** Whole-module instrumentation increases binary size
  substantially: 120,442 B to 182,811 B (+51.8%) on `samples/iyi/hello.iyi`, and
  80,227 B to 141,802 B (+76.7%) on `fib.iyi`.
- **Execution slowdown.** On recursive Fibonacci (32) under wasmtime 48.0.1,
  native execution averaged 18.2 ms (min 16.7 ms); asyncified execution
  averaged 37.7 ms (min 33.8 ms), a 106.9% slowdown (2.07x wall time).
- **Build toolchain boundary.** The iyi compiler compiles wasm by emitting an
  unlinked object file and printing the driver link command. `wasm-opt` is a
  separate post-link binary that neither iyi nor wasi-sdk 24 packages, which
  would violate III.9's toolchain floor.

**The refusal.** `group` remains a compile-time error on wasm32-wasi. The macro
in `src/iyi/prelude.iyi` names the reason:

```
group is not available on wasm32-wasi: WebAssembly cannot switch stacks, wasmtime 48 disables the stack-switching proposal, wasi-threads is unsupported, and asyncify cannot run without a host event loop (SPEC.md III.4)
```

**What would have to change for the answer to flip.** For wasm32-wasi to carry
iyi's structured concurrency, the host runtime and toolchain must provide
native stack switching out of the box: either the Wasm stack-switching proposal
stabilised and enabled by default in Cranelift/Wasmtime without extra flags, or
WASI 0.2/0.3 component-model async execution supporting stackful fibers directly.
Neither a sequential imitation nor a post-link bytecode transformation is
acceptable.

### III.5 Module initialisation: **PROPOSED; rules 1, 2 and 4 BUILT**

II.9 left this open with a concrete case: Kemal registers routes as a side
effect of top-level calls, which is legal, and the ordering guarantees across a
module DAG were never stated. Go's `init()` is the reference, and it is a
reference for what to avoid: importing a package runs code, order within a
package follows *file name*, an `init` that fails can only panic, and
`import _ "github.com/lib/pq"` exists as a language-level hack for a side effect
the compiler cannot see.

**III.4.5 already shrank the question.** Module-level mutable state is not
shareable, so it is either immutable or behind a synchronised type. What a
module initialiser mostly does, then, is compute constants, and the order in
which constants are computed is a much smaller question than the order in which
arbitrary side effects run.

**1. A module initialises after every module it imports.** R-1 makes `import` a
DAG, so this is a partial order with no cycles to resolve, and it needs no
analysis beyond the edges already in the artifact (IV.2).

R-1's DAG was a claim about the language and not about the compiler: a cycle
compiled. It was refused only where a module needed one of the other's names at
*declaration* time, because the second module of a pair is loaded from inside
the first's `import`, before the first's own body has been seen. Anything
resolving later got through. A cycle whose only crossing use sat inside a
`def` built and ran, and so did one that closed through the entry module, whose
initialiser is last by construction and so cannot precede a module that imports
it. A cycle is now an error naming the cycle, which is the same accident rule 1
stopped relying on above, and the one IV.4's coherence proof rests on.

**2. Between independent modules the order is *unobservable*, not merely
unspecified.** This is the rule worth having, and the compilation model already
pays for it: a module can only name what it imports (R-1), can only reach what
that module exports (R-2), and cannot reopen anything (R-3). So a module's
initialiser has nothing of an unrelated module to look at, and no program can
tell which of two independent modules went first. The tiebreak therefore does
not need specifying. There is no experiment that could detect it.

A rule nobody can observe is a rule that rots, so **debug builds shuffle the
order of independent modules. Built.** This is Go's own trick: map iteration was
randomised precisely to stop programs depending on an order the specification
never promised, and Go went further there than in its own `init`, which is
ordered by file name and therefore depends on one.

The compiler walks the DAG the way Kahn's algorithm does and picks at random
among the modules whose imports have all been placed, so no two debug builds of
a program need hand out the same order. Release builds keep the load order, so
what ships is reproducible; `IYI_INIT_SEED` pins a debug one, for a program
that fails under an order and has to be looked at twice.

**What it cost, measured.** Every sample was built under eight orders and all
eight produced identical output. The result is thinner than it sounds: of the
samples, only `modules.iyi` imports two modules that are independent of each
other, and their initialisers are declarations with nothing to observe. What it
does establish is that the reordering is safe. The tree the compiler hands the
rest of the pipeline is still one it types and generates code for, and that no
sample was quietly relying on load order. Evidence for what the rule *catches*
needs a program whose modules do work at initialisation, and there is not one
yet; III.4.5 is the reason to expect there never will be many, since
module-level mutable state is not shareable and an initialiser mostly computes
constants.

**Rule 1 was accidental, and now is not. Built.** `import` used to expand the
imported file *in place*, splicing its nodes where the directive stood, so a
module's top-level code ran at its import site and the order was textual. It
happened to agree with rule 1. An `import` usually precedes the body that
needs it, but only usually. An `import` written below other top-level code
disagreed, and the disagreement printed:

```
module probe/main
puts "before"     # ran first, before `probe/a` had initialised at all
import probe/a
puts "after"
```

`import` now leaves a `Nop` where it is written and hands the loaded file to
`Program#iyi_module_inits`; `top_level_semantic` splices that list into the
tree, after the prelude and ahead of the program's own code. Loading is
depth-first and a module is appended only once the modules it imports already
are, so the list is in topological order and rule 1 holds by construction. The
entry file is not in the list, which is rule 1 applied to it: it imports
everything, so it initialises last. `samples/iyi/init_order.iyi` is the case
above, printing in the order the DAG fixes.

This is the separation rule 2's shuffle was waiting for. The order is now a
list the compiler owns rather than a property of where the text sits, and it
is the same separation Part IV needs, since an artifact cannot store an
initialiser it never separated. What is still missing for Part IV is the step
after: the list holds a module's *nodes*, not a callable initialiser in the
module's own object code.

**3. There is no `init()`. A module's top-level expressions are its
initialiser, in source order.** Go needs two mechanisms: dependency-ordered
package variables *and* `init` functions, and orders the second by file name,
which means adding a file can change behaviour. That failure has nowhere to live
here: `import a/b` resolves to `a/b.iyi`, one source file per module, so source
order is already total.

**4. Initialisation may not fail. Built.** If it can fail it is not
initialisation, it is work, and work belongs in a function the program calls
when it is ready to handle the failure. This is checkable rather than
aspirational, because errors are types: a top-level expression may not
propagate.

It turned out to be enforced already, but by accident: `!` expands to a
`return` (III.1.2), so it hit Crystal's rule about returning from the top level
and reported `can't return from top level`, which describes the expansion rather
than the rule. The propagating `return` is now marked, and the message names
III.5. Reported where the check already was rather than in the parser, because
the parser cannot see through a macro to know whether the expansion will land
inside a `def`.

**5. No import for side effects.** `import` brings a module's declarations; it
is not a way to run its registrations. The driver-registration pattern Go writes
as `import _` becomes an ordinary call the program makes, where a reader can see
it. This is the rule that costs the most: it is more code, and it removes a
convenience real programs use. The Kemal port is the evidence that the trade is
survivable: II.9 records that its singletons were replaced by one application
value and its routes returned as a table rather than registered into a global,
and that **nothing in the design forced it at the time**. This is the rule that
would have.

**The alternative that lost: lazy initialisation.** Module-level values could be
computed on first use, which removes ordering as a question entirely: Swift's
answer. It was rejected because it moves cycles from a compile-time
impossibility to a runtime failure, and because a guard on every access to a
module-level constant is a cost paid by every program to solve a problem that
R-1's DAG already prevents.

**Status.** Rule 3 is a description of what the compilation model already
forces and needed writing down more than building. Rules 1, 2 and 4 are built,
and so is the cycle refusal R-1 asserted and the compiler did not perform.
Rule 5 is the one with a real cost and no measurement behind it yet, and it is
the one to be suspicious of.

### III.6 Crystal interoperation: **BUILT as an artifact — `iyi bind`; the `extern module` spelling below is not**

The question, asked as "how does iyi use a shard without rebuilding it every
build, the way Gleam uses an Elixir package?"

**What Gleam actually does, because the precedent is narrower than it sounds.**
A Gleam function may be declared with no body and an
`@external(erlang, "module", "function")` annotation. The developer writes the
Gleam type. The compiler does not check it against the Erlang function, and
cannot: Erlang has no types to check against. A wrong annotation is not a
compile error, it is a crash at the call. Gleam's guarantee stops at that edge
and Gleam says so. What Gleam gets for it is the whole BEAM ecosystem, and the
trade is judged worth it by everybody using it.

**iyi's version of the problem is harder in one way and much easier in
another.** Easier: there is no foreign function interface here at all. A shard
and an `.iyi` module are compiled by the same compiler, into the same object
format, with the same calling convention, against the same collector. A Crystal
method and an iyi method are the same machine code, and the only question is
what the type checker is told about it.

Harder: what it has to be told does not exist. Three of the four rules are
broken by ordinary shard code.

- **R-2 has nothing to read.** `def parse(str)` is idiomatic Crystal and carries
  no types. Crystal recovers them by inference over the whole program, which is
  exactly the thing R-1 refuses to do.
- **R-3 is broken on purpose.** The Appendix's own count: 77 of 484 types are
  reopened across module boundaries, `String` by five modules. A shard does not
  merely lack types at its edge, it *changes types iyi has closed*, and the
  coherence check in IV.4 has no way to see that it happened.
- **R-5 does not survive.** A shard's macros are written against a global view.

So the boundary cannot be a `require`. It has to be a place where the four rules
are restated by hand for exactly the surface being used.

**The proposal: an `extern module`, and the shard compiled once behind it.**

```crystal
extern module vendor/http from shard "http_client"

pub def get(url : String) : String          # R-2 written here, by the consumer
pub struct Response                          # named, not reopened
  pub def status : Int32
end
```

One build compiles the shard under Crystal's rules and writes a `.iyimod` whose
`Exports` are the binding's signatures and whose `ObjectCode` is the shard's.
From that point the artifact is an ordinary artifact: version-locked as IV.5
locks everything, hashed as IV.3 hashes everything, read by IV.1f like any
other. **The shard is compiled once per artifact, not once per build**, which is
the whole of what was asked.

**Four rules the boundary has to carry, and they are not negotiable.**

1. **The binding asserts and is not checked, and this is written down where a
   person will read it.** If the signature is wrong the failure is an undefined
   symbol, or worse, a call that returns something of another type. This is
   Gleam's trade taken deliberately rather than discovered. The alternative
   (check the binding against Crystal's inferred types) is available and is the
   better second version: the compiler *has* those types, because it inferred
   them to compile the shard.

   **The return type is now checked, and the sentence above was hiding a
   defect rather than a trade.** `crystal tool bind` always instantiated a
   method whose return nobody wrote; a method that wrote one was copied out
   verbatim, on the premise that Crystal's answer is what Crystal was told.
   It is not — Crystal narrows a restriction to what the body produced, so
   `def wider : String?` returning a `String` types its call `String`. A
   consumer told the union holds one where the object code answers a bare
   pointer, which is this rule's second failure reached with nobody having
   written a wrong signature.

   Held against the answer, Crystal's own library disagrees in five places
   and each is its own shape: `Int` where a caller gets `Int32`, an abstract
   base where a factory hands back the concrete class, a union carrying a
   member the method never produces. **URI: 40 agree, 0 disagree, 27 cannot
   be checked**; JSON 119/3/13; YAML 111/2/40. The third column is what is
   left of this rule — a splat, an unannotated block, a generic — and it is a
   number now rather than a sentence.

   **What travels is the answer, and the linker decided it rather than an
   argument.** This was left open for one commit on the grounds that changing
   what artifacts contain needed a consumer linking against the corrected
   declaration to prove it. `bench/bind_roundtrip.sh` is that consumer. Bound
   with the restriction repeated, a program calling `wider` fails with

   ```
   ld.lld: error: undefined symbol: *Shard::Part#wider:(String | Nil)
   ```

   because the symbol Crystal emitted is named `:String` — rule 1's first
   failure, at the end of a build that had no other complaint, reached with
   nobody having written a wrong signature. Bound with the answer, the same
   program links, runs, and prints what the source arm prints. The
   declarations now carry the instantiated answer wherever the two disagree,
   and the round trip is a gate so this cannot come back.

   **A virtual parameter, which is the same question asked of the other side
   of the arrow.** The round trip found it next: `def discards(io : IO)` is
   monomorphised on what it is *passed*, so the keep file emitted
   `discards<IO>` while a consumer handing it `STDOUT` asked for
   `discards<IO::FileDescriptor>`. The producer cannot know which concrete
   types a consumer will pass, and there is one symbol.

   The two answers that suggest themselves are both bad. The keep file could
   instantiate for every concrete subtype, which is the whole-program work an
   artifact exists to avoid. Or the boundary could refuse such methods, which
   costs real surface: **JSON 10 of 180 declarations take an `IO`, YAML 10 of
   193, URI 7 of 55**, and that counts only `IO`.

   Neither was needed, and one line of a consumer's source is what said so.
   `part.discards(STDOUT)` failed to link and `part.discards(STDOUT.as(IO))`
   linked, ran, and printed. The symbol the producer emitted was callable the
   whole time; what was wrong was that the *call* was keyed on what the call
   site passes. Everywhere else that is right, because the body is there to be
   compiled once per argument type. For a declaration read from an artifact
   there is no body and exactly one symbol, so the call is keyed on the
   parameter **as declared** and the argument is widened to it — the same
   conversion `.as(IO)` performs by hand. `Call#iyi_artifact_arg_types` decides
   it and codegen upcasts rather than downcasts, which is the direction the
   crash named when it was got backwards:
   `BUG: trying to downcast IO+ <- IO::FileDescriptor`.

   Nothing is refused and nothing is instantiated per subtype. The declaration
   is the contract, which is what R-2 says it is.

   **The check was built the wrong way round first, and the reason is worth
   the line.** It read the instantiated method's *body* rather than its call.
   `def discards(io : IO) : Nil` has a body producing an `IO` and a caller
   receiving `Nil`, because `: Nil` discards whatever the body answered — so
   the first run reported three defects in `URI` that were not there, all of
   them that shape. A boundary is about what a caller is handed. The spec
   pins the `: Nil` case so the wrong question cannot come back.
2. **The shard's opens stay inside the shard.** It may reopen `String` for its
   own use; those methods are not visible to iyi and must not be, because a
   consumer reading the artifact cannot see them and R-3's coherence answer
   depends on that being the whole story.
3. **No generic may cross unmonomorphised.** A binding names `Array(Int32)`, not
   `Array(T)`. A shard's generic body is not compilable under iyi's rules, so
   `MonoBodies` cannot carry it, and what travels has to be code the producing
   build already emitted.
4. **No macros cross.** R-5, unchanged.

**What was built, and where the proposal's spelling went.** No `extern
module` was ever parsed. The binding is the artifact itself: `tool bind
--crystal -e Root --emit-bind DIR` reads a shard under Crystal's rules,
instantiates every method whose return nobody wrote, checks the ones
somebody did, and writes `DIR/<shard>.iyimod` — `Exports` the signatures,
`crystal_library` set so an own-prelude program cannot import it — beside a
keep file; a second build of that file with `--iyi-keep Root --emit-bind .`
fills the object code in. `iyi bind` is the two steps for every shard under
`lib/`, in the order the shards' own `shard.yml` files give, each bound
against the artifacts before it, the root namespace read off each entry
file; Kemal is four shards and one command, 35 s on the machine that wrote
this, and the program that wrote `require "kemal"` writes `import kemal`
and builds with `--crystal --use-iyimod mods` (`samples/crystal/kemal/`,
gated by `bench/kemal_serves.sh`, whose two arms answer byte for byte).
What the consumer never writes is a signature: R-2 at the boundary is the
instantiated answer, which is what Appendix B #12's "checked for the second
version" turned out to mean once rule 1 above had been measured. What the
proposal's `pub struct Response` said by hand, the artifact's `TypeDecl`s
carry from the shard's own declarations, opens excluded (rule 2).

**What it is worth in build time, measured, and it is not speed.** The kemal
sample on the release compiler, min of three: `require "kemal"` builds in
2.03 s, `import kemal` from the artifacts in 1.88 s, and through the daemon
1.95 against 1.80. Eight per cent. A `--crystal` build's time is Crystal's
library analysed and the program's own code generated; the shard was a
small share of that bill and the artifact removes the small share. What the
boundary buys is R-1's claim, not a faster build: the shard compiled once,
its source not on the machine, the edge hashed and version-locked, and no
signature written by anybody. The build that would be faster is the one
where the library itself arrives analysed (IV.1d's open item), and that is
not this.

**And on a real application, the boundary's own limits, counted.** A 8,079-line
kemal application with 21 shards under `lib/`, 78,430 lines of them: `iyi
bind` binds 18 of the 19 its manifest depends on and writes 22 artifacts,
because a shard with more than one namespace is more than one boundary. The
one it does not bind is `prop`, whose whole surface is macros (rule 4), and
nothing waits on it: a macro-only shard has no declarations, no object code
and no artifact, so `validator`, written on its macros, binds beside it.

Written is not the same as usable, and the second number is the one that
counts: a program that does nothing but `import <name>` builds, links and
runs against **21 of the 22**. Getting there took sixteen defects, each
found by consuming an artifact rather than by writing one, and each is now
a shape in `bench/bind_roundtrip.sh`'s fixture: a class variable's
`@[ThreadLocal]` (a consumer that does not carry it writes to a different
global than the object code does), one the shard declared `uninitialized`,
a default that calls a private method, a private method named only after a
non-ASCII character in a travelling body, a shard's own top-level `fun`
(machine code in a main module, which never travels, so the source crosses
and the consumer compiles it), a macro call copied into the initialiser, a
type layout past 64 KiB, a match type named the way it prints rather than
the way its symbol is, and a bare name one boundary's declarations took
from another's.

**And then the application itself, against the boundaries rather than
against `lib/`.** The import probe above says a boundary can be read; this
says whether a program can be *written* on one. The same 8,079-line
application, with its 15 `require`s replaced by `pub import` of the
artifacts, compiles, links and boots: it connects to postgres, Kemal
installs its middleware and serves. Twelve more defects stood between the
two sentences, and every one was a thing a consumer does and the import
probe does not: call a macro the shard declares (`Kemal`'s `only`, and
`DB::Serializable`'s `macro included`, without which a query mapping rows
into structs types `Array(NoReturn)`), read the annotation that hook asks
for, name a class as an argument (`read(type : DB::Mappable.class)` is one
instantiation per class the caller names, so the body travels and nothing
is measured), include a module the boundary declares (`HandlerInterface`
carried no `include HTTP::Handler`, so a middleware was not a handler),
call a method whose overload is private and shares a public one's name,
pass an argument by name (keyed on the call site it asked `db` for a
symbol per exception class), and — the one that had nothing to do with
declarations — run a module *body*: `PG::Decoders` registers five decoders
in statements under the hash they fill, and an artifact that carried the
hash and not the statements answered every column with raw bytes.

What it costs is measured too, cold cache and the same compiler: **17.0 s
from source against 24.3 s from the boundaries**, and the whole difference
is the top-level pass — 2.3 s to 12.1 s — reading 267 MB of artifacts. The
application's own main pass falls, 7.9 s to 6.8 s, which is the boundary
doing what it promises; the read in front of it costs more than it saves.
The binary is **14.2 MB from source and 209 MB from the boundaries**,
`.text` 7.0 MB against 112 MB, because a source build's codegen is
demand-driven and a consumer links every unit every artifact carries.
Both numbers are about the artifact rather than about the rule: what it
carries, and when a consumer has to decode it.

**And what it did not survive: the first request.** The application booted
and faulted on the first HTTP request it was given, and the reason was a
rule this format did not keep. A *module used as a type* — kemal's
`@next : HTTP::Handler | Nil`, the handler chain — is dispatched as a test
per includer, and the includers are the ones the *producing* build had. A
consumer writes its own middleware, joins that set, and the artifact's
compiled `Kemal::InitHandler@HTTP::Handler#call_next` matches none of its
cases: it falls through to the union's `Proc` arm and calls through a
pointer that was never a function.

`bench/open_dispatch_fixture/` is that defect with no shard in it: a module
`Link`, two includers in the shard, one in the consumer, and a boundary
build that printed `first ` where the source build prints `first mine end`.

**The rule is the same sentence IV.1g already makes about blocks and
generics, said about *sets*, and it is BUILT: an instantiation whose machine
code enumerates the members of an open type is the whole program's answer,
not the module's, so its body travels and the consumer compiles it.** A
module is the open case — anybody may include one — and a class is the half
already written down. The closure reaches the bodies that *call* one, because
a caller the producer compiled binds to the producer's copy by name and
carries the stale answer one call deep. `Iyi::OpenTravel` marks the call
where the set is read (`Call#lookup_matches_in`), walks this build's
instantiated defs, and marks every caller; `bench/open_dispatch.sh` runs the
fixture both ways — `IYI_OPEN_TRAVEL=off` writes the boundary the way it was
written before the rule, and answers `first `.

**Every callee, because a copy is one too**, and which of the two bounds is
right had to be measured rather than reasoned. The obvious bound is the
module's own types: everything else is the consumer's to compile, so the
symbol a shard's object code calls is the consumer's own and its includers
are the consumer's. That bound is wrong for the reason IV.1g gives — while a
module's unit is emitted, a callee it does not own is *copied* into that unit
with internal linkage, so a library method with a dispatch in it is in the
artifact holding the producer's set, and only a caller that travels replaces
it. So the walk follows every call.

What that costs, measured: on kemal's four boundaries **nothing at all** —
the same 325, 36, 35 and 11 travelling bodies as the bounded walk, because
what reaches a dispatch there already travelled for another reason. On `db`
and `sqlite3` it is 45 bodies more out of 217, and neither gate's wall time
moves. The one place the wide walk looked expensive was a defect rather than
a cost, and it is the next paragraph.

And one defect the wide closure walked into on the way, which is about a
`fun` rather than about a set: **a `fun` that answers one of the shard's own
enums crosses as that enum.** It crossed as the enum's *base type*, which is
right for a parameter — what a C function takes is the integer, and Crystal
converts without being asked — and wrong for a return, because the shard's
own code reads what it declared. `sqlite3` writes `case
LibSQLite3.column_type(self, col) when Type::TEXT`; compiled on the far side
over an `Int32` it matched no member, took the `else` and raised `another row
available` on the first query. Named globally now (`::SQLite3::Type`): a
shard's `lib` is declared at the top level, where its name is what the
producer's symbols are made of, and a name looked up in there reaches
neither the module's scope nor its namespace. `bench/bind_roundtrip.sh`
carries the shape — a module's body casing on a `fun`'s enum — and with the
base type back its two arms disagree.

Two further shapes came with it, both the same kind of thing as the twelve
above. A private helper kept out of the declarations because its *default
value* names the module it lives in (`limit : Int32 =
Kemal.config.max_request_body_size`). And a declaration a travelling body
needs that never crossed: a private nested type named from a sibling scope
(`private constant Kemal::ParamParser::LimitedBodyIO referenced` — a
declaration's members are written *inside* it now, so the name is the one the
shard wrote), a method the shard alone cannot type (`exception_page` writes
`def self.new(context : HTTP::Server::Context, …)` and requires no `http`, so
its body travels and the consumer types it), a nested module that writes
`extend self` (`Backtracer::Backtrace::Parser.parse`, carried as the word
rather than as a second copy of every method — `.iyimod` v50), a method of a
private type (the keep file cannot name one, so the producer emits no symbol
for any of its methods and all of them travel), and an *empty* body, which
the format spelled exactly the way it spells a header (`def backtracer` with
nothing in it travels as `nil`). The application builds, boots and answers:
`bench/kemal_serves.sh` holds it.

Three rules came out of it. **A boundary is rooted at one namespace, and a
shard need not have one**: `pg` declares `PG` and `PQ`, its wire protocol,
so `iyi bind` binds each — `tool bind` reports the others it found — and
the parts a shard's entry never requires (`bindata/asn1.cr`) are boundaries
too, since a program that requires one needs its declarations from
somewhere. **What cannot compile cannot cross**: a method whose body does
not typecheck when it is instantiated goes in `<artifact>.drop`, both
builds run again without it, and the rest of the boundary is not hostage to
it (`ed25519` loses two methods calling an `assert_rst_point` that shard
never defined, and `jwt` binds behind it). And **a type id is a question
about the program**, not about the import that raised it: `PG` names
`PQ::Field` in its signatures while `PQ` numbers `PG::Error` in its object
code, so whichever of the two a consumer reads first refers to a type the
other has not declared yet — and no ordering of two boundaries fixes it,
because the dependency runs both ways while an import graph is a DAG (R-1).
The names an artifact's object code refers to are resolved once, after the
top-level pass has read every import, and `import p_g` — which pulls `p_q`
with it — builds. The one artifact of the 22 a program cannot import *alone*
is `p_q`, and the refusal is right: the wire protocol's object code numbers
`PG::Error`, so a program that wants it wants `PG` too, and IV.1g says so at
the import that named it.

**What a migration would need, measured on an application, before any
`iyi migrate` is written.** The question a Crystal user asks next is not
"can my shards cross" but "can my program become iyi modules", and the
answer was measured on the same 8,079-line, 99-file kemal application
before a converter existed, in the order this project measures things.
Two readings. `crystal tool bind -e AcikTurkiye` on the application's own
namespace, which is R-2 asked of the program rather than of a shard: 866
public methods, **496 written, 193 a machine can write, 177 a human has
to** — the last an upper bound, since only what a module exports needs a
signature and every one of those 177 carries an untyped parameter the
whole-program build does type at its calls; 68 more wait on `DB::ResultSet`
and `PG::Geo::Point`, which is `pg` crossing. `bench/migrate_count.py` on
the tree, for the shapes a file-per-module language has to do something
about: 99 files, 379 defs, 73 top-level route calls, 26 relative and 21
shard requires, 204 instance variables assigned without a declaration (the
compiler knows every type), 69 `not_nil!` sites (`!` is III.1.7a's, so each
becomes `x || raise`), 130 `rescue`/`raise` lines and 48 `include
JSON::Serializable`/`DB::Serializable` — and both of those compile as they
are under `--crystal`, tried on a probe. R-3, the rule that could not be
mechanical: **one file**, `logging.cr` reopening `Log::Metadata`; the
`AcikTurkiye::DB` namespace opened in 22 files is 22 modules, which is what
it already was.

Then one model converted by hand and consumed across an `import`, to see
what the counts miss. `models/tag.cr` became `acik_turkiye/d_b/tag.iyi`
with five edits, none to a method body: the header, spelled the way
`iyi_module_name` spells a namespace (`DB` is `d_b`); the `module
AcikTurkiye::DB … end` wrapper removed, because the path is the namespace;
`pub` on the struct; `require "pg"` kept and `import acik_turkiye/d_b` with
`using …::{SQL}` for the constant another file declares; and the consumer
writing `Tag` under `using acik_turkiye/d_b/tag::{Tag}` where it wrote
`AcikTurkiye::DB::Tag`. `iyi check --crystal` answers clean, `getter`,
`include ::DB::Serializable`, `as: Tag` and an untyped `def update(name,
description, sentiment)` untouched. The rule the exercise found, which no
count would have: **a Crystal namespace is an iyi path, and a type's
qualified name changes** — `A::B::C` in `c.cr` is module `a/b/c` exporting
`C`, and every `A::B::C` a consumer writes becomes `C` under a `using`
line. That rewrite is global and mechanical, and it is what a migrate verb
is: header from path, wrapper off, `pub` on what other files reach,
`import`/`using` from the references, signatures from the compiler where
the export lacks one. The residue a person writes is the reopened foreign
type and whatever the counts call R-3, which on this application is one
file.

**Built: `iyi migrate`.** The measurement above is what the verb was built
on, and every rule in it was found by migrating that application rather than
designed:

1. **A Crystal namespace is an iyi path.** `module A::B` wrapping a file, or
   `class A::B::C` at its top, places the file at `a/b/c` — segments spelled
   the way `Iyi.iyi_module_name` spells them — and the wrapper comes off,
   because the path *is* the namespace. Wrappers peel one at a time, so
   `module Shop` around `module Counter` is `shop/counter` and neither line
   stays in the file: a module left nested cannot be `pub`, and nothing
   outside could reach into it.
2. **A type's qualified name changes with it.** Every constant path the tree
   declares is resolved the way Crystal resolves one — innermost namespace
   outwards, through `include`, inside string interpolation as well as code —
   and rewritten to the bare name its module exports, under a `using` line.
   `Shop::Names.title(x)` keeps its qualified spelling, because a module
   function called from inside a type's body does not resolve as a bare name
   (R-2b names both spellings). Two modules offering one name: the second
   stays qualified and the note says which. A name that would be shadowed by
   an imported module's own namespace — `Report` inside `shop`, where
   `shop/report` is a module — is qualified for the same reason.
3. **What other files reach is `pub`**, and `def self.x` at a module's top
   level becomes `def x`: an iyi module extends itself, so that is where its
   module function lives. The `self.` spelling is reachable from source and
   *not* through an artifact, which is where the difference shows.
4. **`require "./x"` is `import`; `require "shard"` stays.** One module owns
   the tree's shard requires and every other imports it, because a shard's
   top-level code runs once and III.5 makes an import initialise before its
   importer.
5. **A cycle is one module.** R-1 refuses an import cycle and Crystal's
   global namespace never had one to refuse, so each strongly connected set
   is written as one module, members in require order, and named. The
   application's nine `DB` models are one module; splitting them is work a
   person does with the note in hand.
6. **A reopening of a type the tree does not own stays Crystal.** The
   compiler is asked once, by analysing a program that is nothing but the
   prelude, which names the library already owns — so `struct Int32` and
   `class Log::Metadata` are recognised whether they are written qualified or
   not, and travel to a `.cr` file beside their module, `require`d from it,
   where open classes are Crystal's rule.
7. **`!` is III.1.7a's.** `x.not_nil!` becomes `(x || raise …)` with the
   receiver's extent found by scanning left; any other `foo!` becomes `foo`,
   and each site is named, because the copy and the mutation are not the same
   program.
8. **What a macro splices travels too.** A tree's non-Crystal files are
   copied into the migrated tree, and an `.ecr` template — code, spliced by
   whichever module renders it — has its constant paths rewritten inside its
   `<% %>` regions, with the names it uses handed to every module that names a
   template.

`--check` compiles every module written and prints the first refusal of each,
then says *whose* each one is, because the three are worked on by different
people: a `require` this machine cannot resolve is the environment's - the
tree does not compile as Crystal here either, and `shards install` comes
before any rewrite, which is the whole of `kilt`'s 12 - R-2's question for a
signature is the author's, and what is left is this verb's own and asks to
be reported. That is the list a person works through, and on the
application it is empty.
**99 files became 91 modules and all 91 compile**, the program builds, and
run against the demo database beside the Crystal build it answers **byte
for byte on all nine routes tried** — `/api/v1/cities`, a city's districts,
`discover`, `tags`, a search, a city's submissions, a user, the API root
and one route the environment turns off — same bodies, same status codes.
`bench/migrate_gate.sh` holds the whole of it on a fixture that plants each
case above (in CI; hermetic, no shard).

Two defects of the compiler's own were found by doing this and fixed, both
about a `--crystal` program made of modules. A required file's top-level
code — `pg` registering its driver — was spliced *after* the imported
modules' initialisers whenever the entry required the same shard, because
"the program's own code" was read as "the first node that is not a
`Require`", which under an `.iyi` entry is the module header
(`semantic.cr`). And R-2's export check counted the bare `*` of `def
initialize(*, __pull_for_json_serializable pull : ...)` as an unannotated
parameter and asked the author to annotate a def a macro wrote — so a macro's
defs are exempt, which is R-5's own premise: the macro travels and the
consumer expands it again (`iyimod.cr`).

**A `.iyi` file may add to the other language's type and may not replace one
of its methods.** A reopen is how a module extends a type it does not own —
`class ::String; def blank?` gives the library's `String` something the
library does not have, and only what can reach the module's surface can call
it. Replacing is a different act: the definition that goes is one the
*library's own code* calls, so every program built with that module gets the
new one, and nothing at either site says so. Refused now, naming both
definitions. `src/std/text.iyi` is what found it — a `private def
byte_slice(start, count)` helper of its own, a name iyi's prelude does not
have and Crystal's `String` does, so `import std/text` under `--crystal`
replaced Crystal's public one with a private one and the first program to
touch `Path` (every program, through the backtrace) stopped on `private
method 'byte_slice' called for String`, at a line in the library that had
not changed. The rule asks where each definition was *written*, which is the
same question `iyi tool bind` asks of a shard's members.

**And the prelude's methods are the prelude's.** The sentence above stopped
at the other language's types, on the reasoning that under iyi's own prelude
the type is this language's and reopening it is how the prelude is extended.
That is true of the prelude extending itself — `number.iyi` writing a method
`primitives.iyi` declared is one library deciding its own surface — and false
of everybody else: a prelude method is the answer every program already has,
so a module that writes one again hands its own answer to every program that
imports it. A library written against this fork found it: a `std/enum`
reopening `::Enum` with a `to_s` of its own printed `All` for a two-member
flags set and answered `nil` for `Level.parse?("WARN")`, with one import line
as the whole diagnosis. Refused in the same sentence now, and told apart the
same way: a def written beside `prelude.iyi` may replace one, a def written
anywhere else may not.

**And a macro is the same act, one layer wider.** The question was asked of
`def` and not of `macro`, and a `macro` is where it costs more: `getter` is a
*declaration* macro, so a file that reopens `::Object` and writes its own
decides what every field declaration in the program means — the ones in files
that never heard of it, and the ones the prelude wrote. `class ::Object;
macro getter(*names)` in a program made `getter value` answer 99 for every
type in it, silently. It travels too (IV.1 carries `macro_bodies`), so a
consumer can inherit one from a module whose source it never reads. Asked at
the same place now, because `add_macro` answers what `add_def` answers: which
definition this one took the place of. A macro under a name the prelude does
not have is an addition, and a macro on a type the module declared is its
own — a program's `class Holder; macro getter` is untouched, because
`Holder`'s is not `Object`'s.

What that settles about `src/std/`: nine of its twelve modules are
library-agnostic and build under `--crystal`; `std/text` and `std/format` are
written against iyi's own prelude — byte-indexed `index`, `split` and `sub`,
a `%` that formats — and are refused there by the rule above rather than
silently replacing Crystal's, which is what they were doing.

**`--annotate`: the types R-2 wants, read off the program.** Crystal code
does not write them — `def call(env)` is idiomatic — but they are not
missing: the compiler bound them to compile the program. `iyi migrate
--annotate` compiles the tree as Crystal once per *entry* (every file
nothing requires: an app, a migration runner, a seeder) plus once for the
spec suite, which is where a *library* has its call sites - `radix` types
nothing without it and eleven declarations with it - and reads them
back, and which of two readings wins is the design (`tools/param_types.cr`):
a **parameter** from the instantiated def, where the compiler bound it to
compile the body — `initialize` is only reachable that way, since a call
names `new` — and the **answer** from the call, because a boundary is about
what a caller is handed, which is III.6 rule 1's own lesson one level out.
A parameter two instantiations bound differently is written as neither and
reported as both: a `pub def` cannot be two defs. On the application it
writes **226** types in 46 s, and the 53 it cannot are each named with
what is missing and why — nothing in any of the programs calls them, so there was
nothing to read.

Two rules came out of pushing it that far. **`pub` is what another module
names**: marking every top-level declaration made R-2 ask a signature of
every one, including helpers nobody outside calls, so a def or constant no
other module names stays the module's own — the rewrite knows exactly which
names cross, having written every `using` line. A *type* keeps its `pub`
regardless, because a macro in a shard names the class that includes it
(`Kemal::Handler`'s `only` expands `{{@type}}`) and that reference is
qualified. And **a `private def` is not R-2's business**: its signature
travels for a travelling body to typecheck against, and asking it for types
refused every tree with a `private def helper(x)` in an exported class
(`iyimod.cr`).

**`!` is III.1.7's, and which rewrite is right needs the compiler.** A name
cannot carry a `!` in a `.iyi` file, so every Crystal bang has to become
something, and there are four somethings. A `def sort!` loses the bang, and
so does every call to it - they agree because both drop it, and where the
file wrote *both* spellings the mutating one becomes `sort_in_place`
(III.1.7a's amendment) rather than silently replacing the other. `getter! x`
and `property! x` are `not_nil!` written by a macro: they become `getter? x`
and a reader that raises, which is the same three entry points with the
raise where a reader can see it. And `x.uniq!` alone on a line was there for
the mutation, with nothing reading the copy - so on an `@ivar`, the one
receiver whose assignment cannot mean something else, the copy goes back
where the mutation was. Whose method it is decides between the last two, and
only the compiler knows: `--annotate`'s reading records where each bang call
resolved, so a method the tree defines is told from Crystal's. Where nothing
in any program called it - a library with no program of its own - the line is
named with its file and line and the alternative spelled out, rather than
guessed at quietly.

**Seven shards, because a project is not one shape.** The rules above were
found on an application; running them over the shards it depends on found
three more, each a rule rather than a special case, and two bugs that were
not migration's at all. A **sidecar** - the `.cr` file a reopening of
somebody else's type stays in - names the tree's own types too, and has no
`using` line to reach them through, so every such path is written in full
and what it names counts as crossing: Kemal's `context_crystal.cr` asked
for `Kemal::Route` after `Route` had moved, and its `HeadRequestHandler`
lost the `pub` on a name only the sidecar beside it uses. And a def is
typed where it is written (III.1) by standing a probe up outside its type,
which cannot name a `private class`: every def of a private class nested
in an exported one was refused, pointing at the def
(`definition_typing.cr`'s `nameable?`).

Two more are line-local rewrites that could not see enough: a **file name
is not a module name** (`micrate-wrapper.cr` gave `module
micrate-wrapper`, which parses as a subtraction), and a **chain's
`.not_nil!` on a line of its own** has its receiver on the lines above, so
`( || raise …)` was written where nothing preceded it - the composing
spelling `.try { |value| value } || raise …` takes the whole chain, which
is what the bang meant where it sat. The fixture plants both.

A **bare** call to a bang method - `validate_typ!(payload)` inside the type that defines it -
has no receiver to key the rewrite on, and is rewritten where the name is
one this tree defines, which is what keeps `!=`, a prefix `!` and a
`"boom!"` out of it. The **manifest travels**: a shard's `version.cr` is
`{{ `shards version #{__DIR__}` }}`, and a tree written out without a
`shard.yml` beside it does not compile at all. And a **merge follows the
`require`, not the file**: `exception_page.cr` is a class body with
`require "./exception_page/*"` *under* it, so the files that reopen the
class are loaded after it — ordering them first made a reopening the first
definition and left `abstract class` as a second one the other language
ignores, which refused every `abstract def` in it. After all of them,
with `--annotate --check`: `validator` 11 of 11, `radix` 5 of 5,
`exception_page` 3 of 3, `dotenv` 1 of 1, `backtracer` 4 of 4, `kemal` 11
of 13, `jwt` 5 of 7, `micrate` 4 of 6, `faker` 2 of 3 — and every
remaining refusal is R-2 asking a type of a def nothing in the library's
own programs calls, which is a person's to write.

Three of those shards were refused by the *language* rather than by the
migration, and each is settled here. A **regex literal** is refused where
the program has no runtime `Regex` - iyi's own prelude - and that was
being read off the file's extension instead: under `--crystal` the library
is Crystal's, `Regex` is in it, and a `.iyi` file already writes
`Regex.new("a.c")` and `=~`, so refusing the sugar for that call was a rule
about a runtime that is present (`literal_expander.cr` asks the file *and*
the program now - either half alone is wrong, and asking only the program
refused snippets in Crystal's own compiler specs, which build a `Program`
without a driver). `backtracer` went from 2 of 5 to 4 of 4. It admits no semantics that
were not already reachable: the engine behind the literal is the one behind
`Regex.new` in the library the program compiles against, so under
`--crystal` it is that library's PCRE2 with that library's costs. iyi's own
library still has no runtime `Regex`, and III.10's linear-time guarantee is
about iyi's own engine — the sugar does not move either line. And `pub` did not admit an
**alias** or an **annotation**, which are both surface: a name for a type
is half of what `validator` exports, and an annotation is applied by a
*consumer* - `annotation Checker` in a shard means a class in somebody
else's module writes `@[Check::Checker]`. Both take `pub` now and both
travel in the artifact, the alias as what it resolved to and the
annotation as its name; `validator` went from 8 of 11 to 11 of 11.

One codegen bug came with the regex literals, and it was not theirs: code
emitted into `_main` - a constant's initialiser - kept whichever module's
closure host was open, so `~$Regex:<hash>:const_init` landed in `_main`
while `Regex.new` was copied into the module's unit with internal linkage,
and the link ended undefined. `in_main` clears it (IV.1g), and the gate
holds it: the fixture has a regex literal in a module, emits an artifact
per module and builds the program from those.

**Where the verb is pointed, and what it reaches.** Four things came from
one report: `iyi migrate <project> --out <dir>` on a shard checkout
"produced nonsense". It did. A **project root is not a source tree** - a
shards project keeps its library in `src` and its *programs* beside the
manifest, a spec suite and an `examples/` and a `bin/`, and reading all of
them together is what nobody means: on Kemal's root that was 79 files
instead of 34, with 24 of them merged into one module because the specs
and the examples require each other and the library. The library is
migrated and the narrowing is printed. A **merged module is named after
the project**: the manifest says `name: kemal` and one of the files is
`kemal.cr`, where joining twenty-four stems alphabetically had called it
`cli_and_others`. The **shards the tree requires are reached from the tree
that is written**: `require "exception_page"` resolves from `./lib`
relative to wherever the compiler runs, and the modules are somewhere
else, so every module refused with `can't find file 'exception_page'`
until a person exported `CRYSTAL_PATH` by hand - a `lib` symlink beside
the modules answers it, and the manifest travelling beside it means
`shards install` there replaces the link. And a **return type goes before
a `forall`**: `def f(x : Hash(String, V)) forall V` took one onto the end
and wrote `forall V : ::Hash(…)`, which reads as a bound on `V`. Kemal's
own checkout went from 0 of 12 modules compiling to 11, the twelfth being
R-2 asking for one signature.

**Twelve projects, and the five rules the last six found.** `crystal-db`,
`shards`, `halite`, `ameba`, `amber` and Kemal's own checkout were
migrated as they come from GitHub, and each found something. The
**library the tree is written against is the one it requires**, not a bare
prelude: `HTTP` is not declared until something requires `http/client`, so
`module HTTP; struct Headers` - halite reopening Crystal's headers - was
read as a module of the tree's own, compiled as a new type, and imported
in a cycle. The probe requires what the tree requires now. A **merge can
make a cycle**, so merging repeats until it cannot: `shards.cr` requires
`commands/*`, `commands/build` reaches `commands/command`, and `command`
is in a cycle with `shards` - the first merge left `M -> build -> M`, an
import cycle in a tree that had none, refused in fourteen modules. A
**`require` under a wrapper's `end`** does not stop the wrapper being
peeled (`require "./features/*"` after `module Halite`), while a macro
there does - `{% for cls in Exception.constants %}` re-exporting a peeled
module's classes found the *other* language's `Exception` and aliased its
constants over the module's own. A **class cannot inherit from itself**:
`class Error < Error` in `shards/script.cr` means the enclosing
namespace's `Error`, and written bare it read as iyi's own error trait. A
**bang accessor keeps its visibility** (`protected getter! segment`),
which the pattern had not allowed, leaving a `!` in a name.

And the one shape this verb does not rewrite is named rather than guessed
at: a Crystal module *mixed into a type* is a `trait` with an `impl` per
type here (II.6), and a mixin migrated as a module puts what `macro
included` writes at the module's own level - `can't declare instance
variables in DB::Disposable because DB::Disposable extends it`, which
points nowhere. Every site is named, and `--check` counts them as their
own kind. `crystal-db` is 4 of 6 with one mixin and one signature left,
`shards` 3 of 5 with two signatures, `halite` 5 of 7 with two,
`ameba` and `amber` need `shards install` before anything (their own
`require`s do not resolve here), and Kemal's checkout is 11 of 12.

**Where a template lands, and one file at a time.** A template's path is
written from the directory the *original* program was built from -
`ECR.embed("src/views/x.ecr")` resolves against the build's working
directory - so the copy has to sit at that same path under the migrated
tree. It was the migrating process's own cwd instead, so running the verb
from anywhere but the project root put every asset under a directory the
build does not look in: 91 modules compiled and the first template
refused with `No such file or directory`. The root is the tree's now, not
the caller's, and the gate migrates from `/` to hold it.

And the verb takes **one file** as well as a tree: `iyi migrate src/x.cr`
writes `src/x.iyi` beside it, under its own name, with the header path an
importer writes (`module kemal/base_log_handler`, which is where the file
already sits under the source root). It carries what the *tree* requires,
because a module is a compilation unit and what one file uses another
file required - `base_log_handler.cr` names `HTTP::Handler` and requires
nothing. Its own relative requires stay `require`s, pointing at the `.cr`
files, which are still the other language. Nothing else is touched: no
manifest copy, no assets, no `lib` link.

It only goes from the top, and says so. A `.iyi` module may require a
`.cr` file and not the other way round (R-2 and R-3 are what an artifact
is made of, and a `.cr` file provides neither), and a `require` that finds
a `.iyi` gets a compilation unit and none of its names - so a file *a
module already requires* is refused, with the whole-tree command as the
answer. Crystal files that require it are a note rather than a refusal:
they keep reading the `.cr`, which stays, and what they build and what a
module builds are two programs over one source until they are migrated
too. Measured on the application: `src/acikturkiye.cr` alone becomes a
module, `iyi build --crystal src/acikturkiye.iyi` builds the program with
the other 98 files still Crystal, and it answers the Crystal build byte
for byte on every route tried.

**What is not the tree's to migrate.** `shards install` writes every
dependency's source into a `lib/` beside the manifest, and `iyi migrate .`
read all of it: on the application that is 889 files, 756 of them somebody
else's, with 359 merged into one module because they import each other. A
`lib/` with a manifest beside it is skipped and counted, since the tree
reaches what is in there through its own `require "kemal"` - which is an
import of `crystal_shards`, not a copy. A `lib` a person wrote themselves,
with no manifest above it, is their code and is migrated. And pointing the
verb at a project root says so: the library is its `src`, and everything
else beside the manifest is a program of its own.

**What it does not do, said here rather than found later.** The list of
what R-2 still wants is a person's to write, and it says *when* each entry
is asked, because the two moments differ: a module's own `pub def` is
refused by the next compile, and a public method of an exported type is
refused when the module becomes an artifact - which is how the application
compiles 91 of 91 with 98 entries still on the list (228 types were
written for it and 98 remain). Until they are
written, its own modules do not become artifacts, which is where R-1's
edit loop lives. The fixture
does: `bench/migrate_gate.sh` annotates it, emits a `.iyimod` per module and
builds the program from those, byte for byte. Two things a migrated tree can
hit there are not migration's. An exported parameter whose declared type is
wider than the argument the producing build passed is compiled at the
argument's type, and the consumer asks the linker for the declared one
(`collect_iyi_object_code` names the eight lines that reproduce it). And a
sidecar's methods are its module's own: a reopening travels as source, so
`3.priced_like(item)` works anywhere in the module that requires it and
nowhere in a module that read that one as an artifact - the fixture calls
it from inside, which is what the rule already says about where a
reopening is closed.

**What it costs and what it buys, measured.** On the application, best of
three: the whole program's front end is **4.72 s** as Crystal and **4.99 s**
as modules — the module boundary is bookkeeping, and it is not free. What a
*change* costs is the number that moved: Crystal has no unit smaller than
the program, so every edit is the 4.72 s, and one module is **2.7–3.2 s**.
That is 1.5×, and the shape of what is left says why it is not more: a
module with *nothing of its own* costs **2.66 s** on this tree, of which
**1.48 s** is Crystal's library and the rest is 21 shards. The module's own
few hundred lines are half a second. Migration splits the program; it does
not move the floor, and moving the floor is what `iyi bind` is for.

On the fixture — seven modules, a few hundred lines — the same numbers say
the boundary is not free at any size: 1.80 s as Crystal, 1.85 s as modules
from source, **2.29 s** from artifacts, 1.40 s for one module. Reading seven
artifacts costs more than compiling the source they stand for. Artifacts pay
where a module's own code is large or its dependencies are behind a
boundary, and the honest place to read that is here rather than in a
headline.

**Why this is cheaper to build than it looks.** The mechanism that records an
inferred type as though it had been written already exists and is already load
bearing: `IyiMod.signature` renders a carried type's methods into the artifact,
and the check that they must carry their return types is what stops a consumer
asking the linker for a symbol nobody emitted. `iyi wrap <shard>` writing a
binding skeleton from the shard's inferred surface is the same operation aimed
at a different input.

**What it does not give, said here rather than found later.** No type checking of
the shard's interior. No `require` from an `.iyi` file, ever. No transitive
shards for free: a shard's own dependencies are compiled into it or the binding
does not link. And no answer at all for a shard whose interface *is* macros,
which is a large fraction of the ones worth wanting.

### III.7 Packages, and discoverability: **steps 1 and 2 BUILT — `iyi.mod`, MVS, a git fetcher, `iyi.sum`; the registry half still PROPOSED**

Shards is the part of Crystal a person meets second and it is the part that
decides whether they stay. This section is longer than it wants to be because
the interesting half is not resolution, it is **discovery**, and iyi holds one
asset for that which no other ecosystem does.

**The asset, stated first.** Every other package registry indexes either prose
or source. `pkg.go.dev` is the best of them and it does not build anything: it
parses with `go/ast` and `go/doc` and extracts what it can, degrading when the
code will not compile. iyi does not have to parse or build, because **R-2 means
every exported signature is already written down, and IV.2 already puts it in a
file**. `iyi mod dump` prints an exact API surface today, from an artifact,
without a compiler run and without the source existing. An index built from that
is not a best effort at the API, it *is* the API.

That is worth more now than it would have been five years ago. A model writing
iyi code needs exact signatures; given prose it invents them. An endpoint that
returns a module's `Exports` as data is a better answer to that than any amount
of documentation, it needs no new mechanism, and it falls out of a rule that is
already built for another reason.

**One gap, and it is small — closed since.** The artifact used to carry no
doc comments; now `Signature` and `TypeDecl` each carry a `doc` field
(format v41), `IyiMod.declarations` renders it as the comment it was, and
`mod dump --json` and `mod context` serve it as data. Two facts the build
wrote down: the comment rides the `pub` token, so `parse_pub` has to
capture it or it is gone by the time `parse_def` looks; and a doc is
surface for a reader, not the type checker, so the interface hash (IV.3)
is computed with docs blanked — the gate asserts that a doc-only edit
moves nothing and a signature edit still does. What remains of the old
gap is `iyi doc` itself (III.8), a renderer over data that now exists.

#### Identity, resolution, integrity

Three decisions, each taken from the language that already got it right.

**Identity is the import path, and the import path is a URL.** R-1 already says a
module's name is its file's path. Extend the same rule outward, as Go does:
`github.com/user/thing/http` is the repository, the module and the import, with
no central registry owning the namespace. This kills name squatting, needs no
registry to be up in order to build, and means a fork is a different module
rather than an argument. Major versions take a path suffix, `/v2`, so two major
versions of one library coexist in a program instead of being a resolution
failure. iyi gets this cheaper than Go did, because a module already *is* a path.

**Resolution is minimal version selection, not a solver.** For each module in the
graph, take the highest of the minimum versions anything asked for. That is the
whole algorithm. It is deterministic, it needs no SAT solver, it produces no
lockfile to conflict in a merge, and adding a dependency cannot silently upgrade
an unrelated one. Shards uses a solver and inherits every solver's failure mode:
two runs of the same manifest can disagree, and the diagnostic when it fails is
about the solver rather than about the program.

**Integrity is a second file, and it is not a lockfile.** `iyi.mod` is policy: the
minimums, written by a person. `iyi.sum` is fact: content hashes, written by the
tool, and its only job is to notice that what arrived is not what arrived last
time. Go's split, for Go's reason: merging two branches that each added a
dependency should be a merge of two manifests, not a fight over a resolved tree.

#### The part that is genuinely new: shipping the artifact

`install` in every ecosystem worth copying means *download source, then build*.
iyi could mean *download*, because IV.1g puts object code in the artifact. Before
claiming that, here is why nobody else does it.

| ecosystem | ships | keyed on | on a miss |
|---|---|---|---|
| Cargo | source only | n/a | n/a |
| Hex | source only, no `.beam` | n/a | n/a |
| Swift binary frameworks | `.xcframework` | compiler, platform, `BUILD_LIBRARY_FOR_DISTRIBUTION` | no standard fallback |
| Stack | cached objects | build-plan hash | rebuild |
| Nix substituters | any output | full input derivation hash, signed | rebuild from source |

Cargo's reasons are the honest ones and they are three: feature flags mean a
dependency has no single compiled form; platform fragmentation is worse than a
target triple (glibc against musl on the same triple); and source-first is what
lets a person read what they are about to run.

**iyi answers the first two already, and the answer is enforced rather than
promised.** An artifact records the compiler identity, target triple and flag
set, and refuses to be read under any other. A released compiler's identity is
its released version; a `-dev` identity also keeps the build commit because
`0.2.0-dev` alone does not name one compiler. Proven by trying it: a debug
artifact offered to a `--release` build is refused by name, with the reason,
because macros branch on flags. The cache key is the four-tuple the format
already carries:

> **`{format version, compiler identity, target triple, flag set}`**

Which makes the design Nix's rather than Swift's: key on the whole input, sign
it, publish as many as are worth publishing, and **fall back to source on a
miss**. A miss is then a build, which is what every other ecosystem does every
time. The registry serves one source tarball and N artifacts, N grows with how
many compilers and targets are worth precompiling for, and nothing breaks when
N is zero.

Cargo's third reason stands and is not answered by any of this: an artifact
cannot be read. So **source is the primary form and the artifact is a cache**,
never the only thing published, and a build must be able to reproduce the
artifact from the source it claims to be. That is what the hashes in IV.3 are
for, and it is the property that has to be checked rather than asserted.

**And it changes the security model, which IV.2a is explicit about not being
designed for.** The per-section checksum is 64 bits of MD5 and it is there to
catch a truncated file, which it does. A file that travels between machines is a
different threat: an artifact carries object code that goes to the linker and
macro source the compiler expands, so a hostile one is arbitrary code execution
at build time. Distribution therefore needs a whole-artifact signature and a
published key, in the same commit that first serves an artifact to anybody. Until
then artifacts are a local cache and the registry serves source.

#### What not to build

- **No install-time scripts.** They are the supply chain's largest hole and there
  is no reason to inherit it. A package is source and artifacts, and building it
  runs the compiler and nothing else.
- **No central name registry.** Identity is the path (above), so the registry is
  a cache and an index, and losing it loses discovery rather than the ability to
  build.
- **No version solver.** See above; MVS or nothing.
- **No transitive `using`.** R-2b says the consumer writes it. A dependency
  cannot bring names into scope, and a package manager is not a reason to
  reopen that.

#### The first version, in order

1. `iyi.mod`, MVS over path identity, source only, no registry: a fetcher and a
   resolver. This is enough to have dependencies at all.
2. `iyi.sum`, and reproducing an artifact from source to check it.
3. The `Docs` section, and `iyi doc` reading artifacts (III.8).
4. The index: `Exports` served as data, which is the discovery claim.
5. Signed artifact distribution, only with 4 in place, because an index that
   cannot say what a package's API is has nothing to serve.

Artifact distribution is deliberately last. It is the differentiator and it is
worth nothing until there is something to install.

**Step 1 is built, and three decisions came out of building it.** `iyi.mod`
beside the entry file is the opt-in: `module <path>` and `require <path>
v1.2.3`, nothing else. The resolver is MVS as written above, a worklist
whose per-path answer only climbs (`src/compiler/iyi/mod/`); the fetcher is
`git clone --depth 1 --branch v<version>` from `https://<path>.git`, into
the compiler's cache, immutable once its manifest is readable —
`IYI_MOD_MIRROR=<dir>` redirects every fetch to bare repositories under a
directory, which is how `bench/packages_resolve.sh` runs the whole story
offline: MVS observably raising a version, the second build reading the
cache with the mirror deleted, and two refusals by name.

The decisions:

1. **A package prefix never becomes a type name.** IV.6 #6's grammar exists
   so a path and a type determine each other, and `github.com` determines
   nothing — so the *import* grammar admits `.` and `-` inside a segment
   and the strict rule stands everywhere else. A requirement's prefix is
   identity for the resolver; the in-package path, under the old grammar,
   is what maps to `Liba::…`, and `using example.com/user/liba/colors`
   reaches `Colors` — the same name the package's own files use.
2. **A package's short imports resolve in its own checkout, or fail.** Not
   passed along to the program's roots: a dependency reaching the
   consumer's modules through a name collision is the accident isolation
   exists to prevent. The file registers under its canonical path — prefix
   plus in-package path — so it is one module however it was reached.
3. **A dotted import with no covering requirement is refused as what it
   is**, naming `iyi.mod` and the `require` line to write, because "can't
   find `github.com/user/lib.iyi`" would be technically true and useless.

**Step 2 followed, and taught one rule.** `iyi.sum` is the fact half of the
split above: one line per requirement the build used, a tree hash of its
checkout (`s1:` — SHA-1, spelled so nobody mistakes it for a signature,
which III.7 reserves for distribution). A matching entry is silence, a
mismatch is a refusal naming both hashes, a missing entry is appended —
the tool records facts, it does not ask a person to transcribe hashes. The
rule the build taught: **a checkout is read-only.** The first version let
a build whose entry sat inside the module cache write a sum *into the
checkout*, which changed the tree a user's sum pinned — the verifier
caught its own footprint within the hour, and the guard it forced is that
nothing under the cache's `mod/` is ever written to again.

**`iyi get` writes the line.** `iyi get PATH` requires the latest release
- the highest `vX.Y.Z` tag the repository has, a pre-release only when
there is no release - and `PATH@v1.2.0` that version, up or down; `-u`
brings every requirement to its latest. The tags are read with `git
ls-remote`, so a version that is not there is refused beside the ones
that are, before anything is cloned. The manifest is the person's: one
line is rewritten in place or appended after the last `require`, and it
is written only after the whole graph has resolved, every selection is
checked out and `iyi.sum` has agreed - a `get` that fails leaves `iyi.mod`
byte for byte. MVS can outbid what the line says, and `get` names the
module that builds at another version than the one its line names.
`--check` answers from the tags alone and writes nothing: `iyi get -u
--check` lists every requirement behind its latest release and exits 1
when one is. `bench/packages_get.sh` drives it against a mirror.

**A major version's suffix is read, not fetched.** `example.com/lib/v2` is
major version 2 of the repository `example.com/lib`, fetched from there at
a `v2.x.y` tag, and its root module is `lib.iyi`: the first fetcher took
the whole path as the repository, so every `/v2` pointed at a
`lib/v2.git` nobody publishes and "two major versions coexist" was a claim
nothing could reach. A `require` pairing a path with another major's
version is refused naming the path that version belongs to, and a plain
path's `latest` never crosses into the repository's v2 tags.

**A short name for a requirement.** `require
github.com/sdogruyol/iyi-web v0.1.0 as web` makes `web/dsl` the module
`github.com/sdogruyol/iyi-web/dsl` in this project's files: the path is
identity and is written once, in the manifest, and the files write the
name - `using web/dsl`, one line with the rule above. Go writes the full
path in every file's import and qualifies with the package's own name;
here the project chooses the name, so two packages' `json` are two names
and the import-alias question has its answer where the requirement is. The
name is rewritten to the path before anything resolves, so a module is one
module however a file spelled it. A package's own short names are its
files', from its manifest, never its consumer's. A short name that is also
the project's own directory is refused where it is written, since which of
the two `web/routes` meant would be a rule nobody could see from the line;
so are `std`, a name that is not one lower-case word, and a name given
twice. `iyi get PATH --as web` writes one, `get -u` keeps it and `tidy`
counts what it imports. It travels to every verb in the same prefix table,
as a row `@web` no import can begin with.

**`replace` builds a module from a directory.** `replace <path> =>
../dir` in the manifest beside the entry file makes every build - and
`get`, `check`, the language server, which all resolve through one
function - read that module from the directory instead of its tag: the
library written beside the app that uses it, or a fork checked out to
try. The directory has to hold the module, its own `iyi.mod` naming the
same path, and is spelled `./`, `../` or absolute so it is never read as
a module path. It is the program's decision alone: a `replace` in a
dependency's manifest is read and ignored, as Go does, or a library could
redirect its consumers' builds. And it is not a fact `iyi.sum` records:
a directory somebody is editing would be refused at the next keystroke.
iyi-web went into `lib/` as a copy because this was missing.

**`iyi mod tidy` makes the manifest say what the source imports.** Every
`.iyi` file under the manifest's directory is read for its imports - tests
included, hidden directories, `lib/` and any directory with its own
`iyi.mod` not. A package imported without a `require` gets one: at the
version the graph already builds when another requirement pulls it in, so
tidying never moves what builds, and otherwise at the latest release of
the longest prefix of the import that is a repository. A `require` nothing
imports is removed unless removing it changes what builds - the line
naming a module another requirement pulls in lower is the program raising
it, which Go spells `// indirect` and this decides by asking the resolver,
so there is no second kind of line to keep in step. `iyi.sum` keeps one
entry per module that builds. `--check` writes nothing and exits 1 when a
change is due.

What steps 1 and 2 do not do, said here: packages compile from
source every build (their `.iyimod` story is step 5's, with signatures),
and two packages whose in-package modules share a name collide in the type
namespace — the general import-alias question, which `using`'s selective
form already softens and a later section has to settle.

### III.8 Tooling: **BUILT — the formatter, the language server, `iyi doc`, `iyi vet`**

Go's developer experience is not one thing, it is a small set of verbs that
always work: build, test, fmt, vet, doc, get. The verbs are unremarkable
individually. What makes them the bar is that none of them has a bad day.

Measured against that, iyi has `build`, `run`, `mod`, `env`, `clear_cache` and
`tool`. What follows is what is missing, in the order the missing pieces should
be built, with the reason each is where it is.

#### 1. The formatter, which is first because it is nearly free: **BUILT since; measured now**

`iyi tool format` refuses an `.iyi` file and exits non-zero. That is honest and
it is also the sharpest thing on this list: `gofmt` is load bearing in Go's
culture rather than decorative, and it ended style as a category of argument. A
language competing on developer experience that cannot format its own source is
arguing for a position it has not taken.

**The work is bounded and countable.** The formatter is an AST visitor with 99
`visit` overloads and none for iyi's nodes. There are nine of those nodes:
`ModuleHeader`, `ImportDecl`, `UsingDecl`, `TraitDef`, `ImplDef`,
`AssocTypeDecl`, `Propagate`, `Defer`, `Recover`, and every one of them already
has `to_s`, `clone_without_location` and `accept_children`, because IV.6's parser
work needed them. So this is nine visit methods against an interface that
already exists, plus the idempotency tests the formatter has for everything else.

Two consequences worth naming. Formatting has to be **exit-code correct** for a
directory containing both `.cr` and `.iyi` files, because today's non-zero exit
means no repository can put `iyi tool format` in CI at all. And CI's existing
`tool format --check src spec` covers Crystal source only, so nothing formats
`src/iyi` or `samples/iyi`, which is where the language's own examples live.

**Since built, and the claim above no longer reproduces.** `iyi tool format
--check` on a file carrying every iyi node — a module header, `impl`,
`defer`, `!` — exits zero, formats idempotently, and CI's `Formatted` step
has covered `src spec samples` for as long as the concurrency work has been
landing: it is the step that caught this repository's own unformatted
syscall table. The nine visit methods exist; what this section asked for
is what the tree does.

Two things the surface needed afterwards, both found by asking which files
the tree-wide check never reaches. A **package** import — `example.test/user/lib`
— has a host segment that the parser reads dots off the characters for, and
that the lexer sees as three tokens; the formatter consumed one token per
segment, fell behind its own stream, and raised, which the command reported
as "there's a bug formatting '<file>', please report a bug" about valid
source. Every file importing a package was unformattable, and this
repository's own `.iyi` files import local modules, which is why all of them
format. And **stdin** is read as iyi: the language a file is in comes off its
extension everywhere in the compiler, `"STDIN"` ends in neither extension,
so `iyi tool format -` read iyi source by Crystal's rules and refused `!`.
`--stdin-filename PATH` says where piped bytes came from, which is what an
editor formatting a buffer knows, and its extension decides the language.

The same question has one more surface, and it is not the formatter's: a
**macro expansion** is named by a `VirtualFile`, which ends in no extension,
so every expansion was reparsed by the other language's rules. No macro
could generate `!` — `v = risky!` became a call to a method named `risky!`
and `v = risky(1)!` was "unexpected token" — and the rule that `!` is not a
name went unenforced in what a macro wrote, which is how the prelude came to
declare `to_i!` and its six siblings on five structs. An expansion is in the
language of the file it expands in; the unchecked conversions are spelled
`unsafe_to_i` now, which is a name iyi source can call.

#### 2. A language server, and why iyi can have a good one: **BUILT — `iyi lsp`, measured by `bench/lsp_session.py`**

This is the item where the compilation model pays a dividend nobody designed it
for.

**A language server for Crystal is hard for the same reason Crystal's rebuilds
are slow: there is no unit smaller than the program.** Answering "what is the
type here" means analysing everything, every time, because a class is open until
the last line of the last file. That is the rule iyi drops.

What R-1 leaves is exactly a language server's inner loop: **one module,
type-checked against declarations, with the rest of the program absent.** That
is not a thing to build, it is what `--use-iyimod` already does on every build,
and IV.1f is the specification of it.

What exists to build on, all of it reachable through `iyi tool` today:
`context` answers the type of an expression at a cursor, `implementations`
answers a call's definitions, `hierarchy` answers the type tree, `dependencies`
answers the import graph, `expand` answers a macro, `unreachable` answers dead
code. Those are hover, go-to-definition, symbol tree, and a diagnostics source,
in all but name and protocol. `iyi tool context` on a sample answers with the
right type today.

What they lack is a process. Each pays full startup and full prelude analysis to
answer one question, and an editor asks one on every keystroke.

**Which is the thing the fork already built and then withdrew.** IV.1d's daemon
holds a UNIX socket, speaks a framed protocol, keeps pre-analysed prelude state
keyed by flag set, and serves builds from it. Two of the three things a language
server needs are in there and working. The third, keeping a `Program`
between requests rather than forking per build, is the part IV.1d never needed
and an editor cannot do without. The daemon was measured, found not to pay for
*builds*, and stopped being offered. **It is the wrong conclusion for the wrong
consumer:** an editor session asks thousands of questions where a build asks one,
which is precisely the workload the pre-analysed state was for.

Two honest notes against it. It forks a child per build, so the reuse is the
transport and the prelude cache rather than the analysis. And when this was
written it was unreachable: `iyi` did not list `daemon`, so its lines and
its spec were maintained under a name a person could not type. That half
was fixed rather than argued: `iyi daemon` is listed, IV.1d says what it is
for (`--crystal`, the one prelude big enough to be worth holding), and the
release gate starts one out of the tarball and builds through it. The other
half — whether the server should live on it — is answered under "The
daemon's cache, asked about once more" below, and the answer is a number.

**Built, and the dividend was larger than the prediction.** The paragraphs
above assumed a server needs a resident `Program`; `iyi lsp` ships without
one, because the measurement said so: a full front-end compile of a
module-local unit answers in **50–70 ms on the gate's fixture, buffer to
verdict**, which is inside an editor's latency budget with no incremental
state, no invalidation story, and no answer a build would not give. The
daemon stays withdrawn. What the server actually needed was one compiler
hook, not a process: `iyi_file_overrides`, a hash of path → editor buffer
consulted in exactly two places (`resolve_import` counts an overridden
path as existing; `import_file` reads the buffer instead of the disk), so
an import sees what the person sees, saved or not, and a build pays one
hash lookup per import for the privilege.

What it speaks: LSP 3.17's earning subset — diagnostics on every change
(the message iyi would print, the SPEC section it cites riding in `code`
as data), hover from `ContextVisitor`, definition from
`ImplementationsVisitor`, the outline from the parser alone so it
survives a file that does not compile. And two methods no other language
can offer, because no other language wrote its interfaces down:
`iyi/contextPack` serves the grounding pack over the wire, and
`iyi/surface` serves a module's rendered surface, unsaved buffer
included. The gate is one scripted session, each step a claim this
section used to make in the future tense.

**The everyday half followed: completion, references, rename.** All
three are the same skeleton — compile, then visit the typed result — and
each taught something:

- **Completion** answers from the last result that held together,
  because the buffer stops compiling the moment the dot lands, which is
  exactly when completion fires. With a receiver it lists the type's
  methods, ancestors in resolution order, signatures as the author wrote
  them; bare, it offers the scope with its types. No index: the typed
  graph is rebuilt in the same 30–80 ms a keystroke already pays.
- **References** cannot come from one program, and that is R-1 speaking:
  a def's callers live in its *consumers'* compiles. The session answers
  instead — every open document compiles as its own entry and the
  answers merge. A reference is a call whose `target_defs` resolved to
  the def under the cursor, so an overload that shares the name but not
  the resolution stays out — the difference between a language server
  and a text search.
- **Rename** is references written back, and its gate found the rule
  worth recording: a `using` line that selects the renamed name is a
  reference too — miss it and the rename leaves a program that does not
  compile. `UsingDecl` now carries per-name locations from the parser,
  and the gate's step is literal: one request, three edits across two
  files (declaration, call, `using` selection), both buffers clean
  after.

**The rest of gopls' table followed, and the pattern held: compile,
then visit — or don't compile at all.** One editing session now speaks
the whole everyday protocol. Incremental sync applies range edits in
wire units, so a large buffer stops paying full-text tax per keystroke.
Signature help fires while the call is half-typed — the callee is found
by text, because there is no syntax yet, and its overloads come off the
typed graph, falling back to every def a call by that name already
resolved to, which is how a `using`-imported name answers. Hover grew
the def's signature as written and the `#` doc comment above it. Type
definition unwraps virtual, metaclass, generic-instance and union
shells to the declaration sites. Document highlight is references
scoped to one buffer; prepare-rename is the same question asked first,
so the refusal arrives before the input box opens. Folding takes
declarations from the outline and comment/import runs from the text,
so it survives a buffer that does not parse. Workspace symbols walk
every `.iyi` under the root with subsequence match, open buffers
winning over the disk — no index, because parsing a module costs
microseconds and an index is a cache with an invalidation story.
Formatting is `Iyi.format` in process, one whole-document edit. Inlay
hints are the facts the typed graph holds and the source omits: the
inferred type after a bare assignment, the parameter's name before a
positional literal. The compiler's own "Did you mean 'x'?" is re-served
as a quickfix whose edit was computed when the error was. And semantic
tokens come from the lexer alone — which, for a language no editor
ships a grammar for, means any LSP client colors `.iyi` correctly on
day one, no client-side configuration at all. One named piece of state
where this section promised none: the last compile is memoised by
(path, buffer, siblings) — the key is the whole input, so a hit cannot
differ from a recompile; it earns its line because one keystroke now
asks four questions of the same buffer. The gate grew a step per
claim, each of these sentences in the present tense.

**And the halves gopls keeps for last, plus the shape agents actually
consume.** Implementation jumps from a trait to its implementors — an
impl became an `include` in the semantic pass, so the answer is a walk
of the type tree, not a registry. Call hierarchy makes the written def
the node — a generic's instantiations collapse back to the line the
person wrote — with incoming edges merged across the session's open
documents (the references rule, one level up) and outgoing edges read
from the def's own compile, the item's `data` carrying the def's
source key so neither direction re-derives it from wire positions.
Selection range expands off the parse tree alone, so it works mid-edit.
And diagnostics grew their pull shape: `textDocument/diagnostic`
answers one buffer on request, `workspace/diagnostic` judges the whole
project in one — open buffers winning over the disk, a file nobody
opened still judged. That pair is the AI-first face of the server: an
editor holds a subscription, an agent asks a question, and R-1 is what
makes the whole-project question affordable — one cheap compile per
module, no shared state to invalidate, capped so a monorepo cannot
turn one request into a build farm. The gate holds 32 steps.
**Then the last gap the comparison with gopls still named was closed.**
References, rename, and incoming calls answered from the session's
*open* documents; a caller in a file nobody opened was invisible, and a
rename that missed it shipped a program that does not compile. They
answer from the workspace now: the same walk `workspace/diagnostic`
does — open buffers first so unsaved edits win, then every `.iyi`
under the root, the same cap — feeds the same per-entry compile-and-
visit, so "who calls this" is asked of the whole project without an
index appearing anywhere. The gate's steps are literal: a consumer
written to disk and never opened is found by references, edited by
rename, and named by incoming calls. The gate holds 35 steps.

**Completion grew the half gopls is famous for, and R-2 paid for it.**
Matching is fuzzy now — `ucs` finds `upcase` — but ranked honestly:
prefix matches from the scope first, keywords after, fuzzy last, the
tier leading `sortText` so a client that re-sorts still sees the same
order. And bare completion offers the *workspace's* exports: `pub` is
written at the declaration (R-2), so one parse of a module names its
whole callable surface — no compile, no artifact, which is why the
offer works in a buffer that has never compiled, the exact buffer a
person mid-thought is holding. Choosing an item inserts the name and
its `import`/`using` pair rides along as `additionalTextEdits`: a new
selective `using` when the module is unimported, the existing line
extended (`{token}` → `{token, glyph}`) when it is — the two lines a
person, and more often a model, forgets. The gate holds 38 steps.

**The last structural complaint was the pipe itself, and the queue
answered it.** The server is one thread on purpose — a compile is the
unit of work and it is never wrong — but reading requests on that same
thread meant a cancel could never overtake the work it cancelled and a
typing burst queued one compile per keystroke. The reader rides its
own fiber now, filling a queue while a compile runs, and the loop
sweeps that queue before working: a `$/cancelRequest` for queued work
answers `-32800` without compiling (in-flight work stays
uninterruptible — the honest limit of one thread, stated rather than
hidden), and every `didChange` for one document already queued applies
before the compile runs, so six keystrokes cost at most two compiles
and the verdict is the text the person actually sees. The gate holds
40 steps, the burst and the overtaking cancel both literal.

**Two conveniences rounded the table off.** Document links make the
import block clickable — `import calc/lexer` and the `using` line
under it both target the file, resolved against the root the header
names, by text, so a broken buffer still links. And type hierarchy
walks both ways off the compiled type tree: supertypes are the named
ancestors (an impl's trait included, because the impl became an
`include`), subtypes are the implementors walk generalised past
traits. The gate holds 43 steps.

**The three residues went last, and one of them earned its place.**
Semantic tokens answer deltas now — one appended line moves five
integers, not the file's stream, and an unknown previousResultId falls
back to a full answer, which is always correct. Completion items with
parameters land as snippets when the client said it renders them.
And the one with a point: a module whose body *does* something
carries a code lens on its first statement, and `workspace/
executeCommand` runs it — the released `iyi run`, against the buffer,
dirty state included, killed at 30 s so a program that never returns
cannot take the session with it. An editor shows the lens; an agent
calls the command and reads what the program printed, which closes
the loop `iyi/contextPack` opened: ground, edit, run, all without
leaving the protocol. The gate holds 46 steps.

**The first live session found the bug the gate could not.** Rebuild
`iyi` while an editor holds a session and, on Linux, the unlinked
binary makes `Process.executable_path` nil for the rest of the
process — so every later compile died with "Missing executable path
to expand $ORIGIN path", a failure a gate that starts a fresh server
per run can never see. Where the binary started is where its library
lives, and that answer cannot change mid-process: `$ORIGIN` is now
resolved once and pinned, the server captures its own path at startup
for the verbs it re-runs as itself, and the gate's step is literal —
the executable is deleted under the running session, a fresh compile
still answers, and the binary is put back. The gate holds 47 steps.

**Then the sentence about the next keystroke got its own gate, and
writing it hardened the transport.** `bench/lsp_soak.py` abuses the
wire — stray blank lines, headers that do not parse, bodies that are
not JSON or not UTF-8, requests missing their params, positions past
the file's end, edits to documents never opened, a 1,500-def module —
and demands the same hover after every blow. Two of those found real
deaths: a stray newline used to end the session (the reader took a
blank line with no header as EOF) and a non-JSON body killed the
reader fiber and hung the pipe. The transport forgives both now, and
only true EOF ends a session. Beside it, `source.organizeImports`
joined the code actions: the header block canonicalised — imports
sorted and deduped, one module's `using` selections merged and their
names sorted, a full `using` absorbing them — and an organizer that
meets anything it does not understand, a comment between imports
above all, offers nothing rather than eating it. The gate holds 48
steps, the soak ten more beside it in CI.

**Moving a file is renaming a module, and the server now says so.**
IV.6 read forward: a module's path is its file's path, so
`workspace/willRenameFiles` answers a file move with one WorkspaceEdit
— the header line in the moved file, and the exact `import`/`using`
spans in every consumer, open buffers and never-opened disk files
alike, applied by the client before the rename lands. A file whose
header and path already disagree has no module identity to move and
is left alone by name. The gate's step is the whole story: lexer.iyi
becomes scanner.iyi, nine edits land across five files, and the moved
module compiles clean. The gate holds 49 steps.

**And the whole-project question learned to get out of the way.** One
thread answers everything here, which is the honest limit; a *request*
is not the unit it has to be honest about. The walk was written inside
the response, so once it started nothing could stop it: 94 compiles on
this repository, and a hover sent 50 ms in was answered 10.9 seconds
later — the freeze a person reports as the server being broken. Between
files the walk now reads its inbox. A cancel for the pull is `-32800`;
anything else waiting stops the walk with `-32802` and
`retriggerRequest`, the code the diagnostic request carries for exactly
this, and the client asks again when the typing stops. Verdicts are
kept by `resultId`, so the pull that is asked again resumes rather than
starting over, and the same hover is answered in 0.23 s. The verbs the
server runs for the editor — `▶ run`, `iyi/contextPack` — ride their
own fibers for the same reason, and own their pipes: `iyi run` hands
them to the program it builds, so waiting for end-of-file on them is
waiting for a server to stop serving, which is how one click used to
end a session permanently. Both are steps in the gate now, and it
holds 55.

**And the speed is measured, not asserted.** `bench/lsp_latency.py`
opens the sample corpus — 32 modules: the calc language, the kemal
port, app, std and the first hour — in one session and times every
verb. On the machine that wrote this, with the release compiler and the
11,886-line prelude, a keystroke's verdict lands in **44 ms p50 / 76 ms
p95** (the gate's own fixture: 37 ms), hover in under 1 ms (the memo:
the keystroke already paid for the compile), completion in 3 ms p50,
and workspace-wide references in 70 ms p50 / 113 ms p95. References
read 1.7 s a commit earlier — 32 modules at one compile each, "the
architecture priced honestly rather than hidden in an index" — and the
price was R-1's to cut, not an index's: a module can refer to a def
only through the module that declares it, imported directly or through
another import, so the cursor's file compiles first and names the
declaring files, and only the entries whose import graph reaches one of
them compile at all. The header block is read as text for it (II.3
rule 4: line-shaped by design, so a buffer mid-edit still has one), an
entry with no header is asked anyway, and a target outside the
workspace — the prelude, a dependency — is reachable from anywhere and
asks everybody. `bench/lsp_session.py` step 34b holds the transitive
case: `use.iyi` imports only `shape/make`, whose `make` answers a
`Box`, and its `make.area` is found from `Box#area`'s declaration two
imports away. When this paragraph was first written the same verdict read
36 / 55 on 26 modules, and the prelude has grown several times over
since for a fifth more latency: the top-level pass is what grew, and
`--stats` on the release compiler reads it at 30 ms of a 48 ms front
end. The bench runs in CI beside the session gate with loose budgets, so
the claim cannot quietly rot. One number to not mistake for it: a
compiler from a plain `make iyi` is unoptimised, and its verdict reads
250 ms — that is the build, not the server, and `iyi version` says
which one you have.

**The daemon's cache, asked about once more and declined once more.**
IV.1d's `Preanalysed` — the prelude's top-level pass done, held in
memory — is exactly the 30 ms above, and Appendix B #15 asks whether
the server should live on it. Read for it (compiler.cr,
`compile_with_preanalysed_prelude`): adoption mutates the held
`Program` and reuses its `TypeDeclarationProcessor`, which is why the
daemon forks a child per build and why `IYI_WARM` adopts once and
returns. Reusing it across an editor's thousand requests means a clone
of a typed `Program` per request or an invalidation story for a shared
one, and what it buys is 44 ms to about 15 under a debounce every editor
already applies. Not built, on the number: the server stays a compile
per question, and the daemon stays withdrawn.

**But the daemon's *process shape* was right, and the server took it.**
Declining the daemon's cache left one thing unanswered, and it was the
one a person meets after an hour rather than after a keystroke: `iyi`
carries no collector by III.9, so a front end hands its memory back by
exiting, and a server does not exit. Measured, not feared: forty edits
and hovers on a 327-line module took one server from 87 MB to
**1,636 MB**, and a sweep of cursor questions over the library reached
**19 GB**, at which point the kernel killed it — mid-session, with the
person's answers inside it. Three ways out, and two of them cost more
than they fix. A collector on the compiler binary is the ancestor
library III.9 spent a release shedding, and it taxes every one-shot
build (the Makefile's own measure: 29% more peak memory). A second
binary with a collector keeps the floor but adds an exception to it.
What the daemon does needs neither: **analyse, work, exit, and let the
next process be the forgetting.** So `iyi lsp` is two processes — a
proxy that speaks the protocol and keeps the open buffers, and a worker
(`iyi lsp --worker`, today's server unchanged) that compiles and is
*retired*: when it has cost half a gigabyte, which it measures and says
(`iyi/footprint`), or when the wire has been quiet for two seconds, so
the replacement's first compile is paid out of the silence instead of
the next keystroke. A worker with a request in flight is never retired,
which is what keeps the code lens that runs the person's program from
being killed to save memory. The result is a session whose cost is what
is open rather than how long it has been open: the same forty edits
peak at 518 MB and rest at **95–112 MB**, measured by
`bench/lsp_memory.py`, whose `--direct` flag drives the single process
so the numbers it rules out stay reproducible rather than remembered.
Two properties fell out and are worth as much as the megabytes: a
front-end crash is now one bad answer — whoever was waiting is told
`-32603` and the next question is answered by a fresh worker, where
before the session died with the process — and the proxy is small
enough to be boring, because it parses four notifications and two
requests and relays everything else as bytes, malformed frames
included, so the protocol's refusals still come from the one place that
implements them.

#### 3. The rest of the verbs, and which are design consequences

| Go | iyi today | what it needs |
|---|---|---|
| `go build` | `iyi build` | nothing |
| `go run` | `iyi run` | nothing |
| `gofmt` | refuses `.iyi` | nine visit methods (above) |
| `go vet` | **`iyi vet`, built** | the verb the row asked for: `tool unreachable`'s analysis, go vet's contract — findings are the exit code |
| `go doc` | nothing; the generator was deleted (V.11's reasoning) | the `Docs` section from III.7, then a renderer over artifacts |
| `go test` | `spec` redirects to Crystal | a runner, and it is not small: it needs a stdlib with assertions and a process model |
| `go get`, `go mod` | nothing | III.7 |
| `go doc` offline | nothing | falls out of artifacts: declarations are already local |

`test` is the one that is a real project rather than a gap, and it is the one a
person notices second. Nothing here proposes an answer for it; it is named so the
list is honest.

One thing that is a bug rather than a design question: `iyi tool` prints
`Usage: crystal tool`, because the name fix reaches the top-level commands and
not the subcommand's own usage.

#### Order, and why this order

1. **Formatter.** Cheapest, most visible, unblocks a CI format gate.
2. **An in-process single-module analysis API.** The thing both the language
   server and `iyi doc` need, and the only item here that is architecture rather
   than plumbing.
3. **The language server** over that: hover, definition, diagnostics, symbols.
4. **`Docs` in the artifact, and `iyi doc`**, which is also III.7's index, so it
   is one piece of work serving two claims.

`test` and a package manager are both larger than any of these and neither is
blocked by them.

### III.9 The dependency floor: **MEASURED; the collector decided (B #20): iyi writes its own**

"Zero external dependencies" is two questions that have been asked as one. They
have different answers, and the one that was open is now decided (Appendix B
#20). This section and `bench/dependency_floor.sh` measure plain builds using
iyi's own prelude. They do not measure `--crystal`, which links Crystal's
standard library and may pull every library a required shard pulls.

#### What a plain own-prelude program depends on, counted

Every undefined symbol in a linked own-prelude program, plain `iyi build`, read
off the executable on darwin arm64:

```
write  exit                                                # libc staples
kqueue  kevent  clock_gettime_nsec_np  __error             # the poller (III.4.8)
mmap  munmap                                               # the collector's arena
pthread_self  pthread_get_stackaddr_np                     # root discovery
_dyld_get_image_header  _dyld_get_image_vmaddr_slide       # root discovery, dyld
```

The symbols are all libSystem — the prelude's staples, the concurrency
runtime's poller (III.4.8: the panic path runs through the scheduler, so
every program carries the poller and its clock), and the owned collector's
`mmap`/`munmap` plus root discovery's `pthread_get_stackaddr_np` and dyld
image calls (GC_DESIGN.md) — and the one shared library is the platform's
libc. The list this section was written on was seven, four of them the
allocator: `libgc.1.dylib` beside libc, carrying `GC_init`, `GC_malloc`,
`GC_malloc_atomic` and `GC_realloc`. That library left the default twice
over: first for the bump pointer, which held the floor by never freeing,
and then for the owned collector, which holds the same floor and frees —
the arena maps and unmaps through the platform's own VM interface, so
real collection now costs not one library. Crystal's own `hello`
additionally pulls `libiconv`, which iyi's `String` has no reason to
want, and the compiler dropped that one too (`-Dwithout_iconv`).

So **an own-prelude program's dependency is the platform libc and nothing
else**, and what that is worth depends on which artifact is being read, so this
section says which. The gate checks this mode at two layers.

**At the object layer**, which is the per-target cross-compile audit in CI, an
own-prelude program's object for `x86_64-linux-gnu` leaves nothing undefined:
the prelude issues the raw syscalls itself for `write`, `exit` and the
collector's `mmap`/`munmap`, and imports nothing. That is the strong form of
the claim and it is measured rather than projected. On darwin the same audit
defers to libSystem, because Apple supports it as the only interface and raw
syscalls are not a stable ABI there — the concurrency runtime and the
collector follow the same rule, so on darwin their calls are undefined
symbols in the object — counted by the exercise gates and by
`bench/dependency_floor.sh` — where the Linux object carries nothing.

**At the executable layer**, the linked program carries what its link template
adds. On Linux that is the C runtime's five undefined references,
`__libc_start_main`, `__gmon_start__`, `__cxa_finalize` and the two weak
`_ITM_` clone-table callbacks, left behind by `crt1.o`, `crti.o` and
`crtbegin.o`. On darwin it is libSystem's list above.
Either way an own-prelude program's dependency list is the platform libc and
nothing else.

The default under that floor has been three allocators, each a decision
this document records. Boehm shipped with 0.1.0 and was measured off as
the last library a plain build could not refuse. The bump pointer held
the floor next — allocate, never free, kept on purpose and documented
loudly (Appendix B #23) — until GC_DESIGN.md's collector was built,
gated, and measured against it (`bench/gc_default.py`). Now the owned
collector is the default: same floor, plus collection. `-Dgc_none`
selects the bump pointer for a program that wants the last nanosecond
and accepts unbounded memory; `-Dgc_boehm` restores libgc, the four
`GC_*` symbols and all, and is the third door, kept so nothing that
passes it breaks.

#### The collector is not hygiene, it is R-4

The reason to care is already in this document and it is not dependency count.
**II.5 ruled that R-4 requires a precise collector**: shape-based stencilling
needs a per-shape pointer map, Boehm is conservative and cannot supply one, and
so "replace Boehm" is a prerequisite of R-4 rather than a runtime decision to be
taken later. III.2 records the shape: precise, generational, non-moving.

R-4 is also the rule with nothing behind it. Nothing in the compiler mentions
`Monomorphize`, a dictionary or a GC shape, and the two defects fixed most
recently were both on the boundary R-4 governs: a generic type read from an
artifact had no object code to be compiled elsewhere into, and the synthesized
`new` fell through the gap. **The collector work and the cross-module generic
work are the same work**, and that is the argument for doing the collector. The
dependency count was never it, and the default build is the proof: libgc left
without one, by not collecting, and the collector is owed anyway.

**What stands in for R-4 today, measured.** Nothing passes a dictionary; a
generic's body travels in the artifact (`MonoBodies`, IV.2) and every
consumer compiles it again for the types it uses, so a module that is all
generics ships no object code at all. `bench/generic_boundary.py` reads the
sample corpus's eleven artifacts by section table: of the 35,340 bytes a
consumer's front end reads — exports, mono bodies, macro bodies; the object
code is the linker's — **37% is bodies it compiles again**, three modules
(`std/list`, `std/enumerable`, `std/traits`) ship no object code, and
`immutable.iyi`, a consumer of the all-generic `std/list`, builds its front
end from artifacts at 1.04x its time from source, the same ~1.0x
`bench/rebuild_speed.py` reads on the whole corpus. The gate pins the two
ends — a module with no generic ships object code and no body, one that is
all generics ships every body and none — and holds the share under 50%, a
tripwire rather than a target. That 37% and the 1.04x are the room the
dictionary has: what it would take out of a consumer's build, and what it
would cost the boundary in a shape key per call. Neither is a reason to
build it yet.

#### Two kinds of precision, and II.5 only needs the cheap one

II.5 says "R-4 requires a precise collector" and reads as one requirement. It is
two, they cost very different amounts, and the expensive one is not the one R-4
asks for.

- **Precise heap layout.** Which words *inside an object of a given shape* are
  pointers. This is what "the pointer map travels with the shape" means and it is
  the whole of R-4's requirement. A compiler knows it exactly, for every type,
  because it computed the layout.
- **Precise stack roots.** Which *stack slots* hold pointers. This needs stack
  maps from codegen, a frame walker at runtime, and correctness under every
  optimisation the back end performs. It is what people mean by "a precise GC"
  and R-4 does not need it.

Conflating them makes the collector look like the largest item in this document.
Separated, the part R-4 waits on is a table the compiler already has.

#### `gcry`, now prior art rather than a plan

[gcry](https://github.com/sdogruyol/gcry) is Crystal's collector written in
Crystal: conservative, non-moving mark and sweep, shipped as a shard, plugged in
with `-Dgc_none` and a reopened `module GC`. Measured against Boehm on Kemal:
**~87% throughput at ~0.80x post-GC RSS on Linux**, and it runs process GC on
Linux and macOS with no compiler fork.

This subsection used to recommend adopting it, and Appendix B #20 overruled
that. **The owner decided iyi writes its own collector**, and the decision is
theirs rather than a finding: they want concurrency, parallelism and a
performant language, owning the collector is the only path to the control that
takes, and gcry was pointed at as hints about what has already been tried to
pull Crystal off Boehm, never as a runtime to adopt. What changed was the
goal: control, rather than the shortest path off Boehm. The findings below
survive the overruling, because they are the best evidence available about the
work iyi's own collector now inherits.

What gcry built that would otherwise be written from nothing: an `mmap` heap
with size classes and large-object spans, chunk release, stop-the-world across
threads and fibers on two platforms, root discovery including static ranges
and the suspended-register cases that took it to v0.19 to close, finalizers,
fork reinitialisation, weak references, metrics, and a fuzz and soak apparatus.
That is the inventory of the road #20 chose to walk, and all of it is the part
that is easy to get subtly wrong.

What iyi has that gcry had to counterfeit: **`src/gcry/layout.cr` is a
`type_id` to pointer-offset table, and gcry has to reverse-engineer it from
outside the compiler.** It walks `Reference` subclasses with a macro, keeps a
blacklist of prefixes whose layout it cannot trust (`Crystal::`, `LibC::`),
hardcodes the field offsets of Crystal's `Hash` internals, and falls back to
conservative word-scanning whenever it is unsure. Every one of those is a
workaround for not being the compiler. iyi emits the same table exactly, for
every type, with no macro walk, no blacklist, no hardcoded stdlib offsets and
no fallback, because computing layouts is something it already did. That
asymmetry is the argument that writing the collector is affordable rather
than reckless.

Their `GCRY_PRECISE_STACK` work is correctness-stable and **not an RSS win**
(~2x); what actually closed the fat-app gap was finalizer correctness and a
retain policy, not precision. That result is inherited as prior art (#21 still
cites it as the best available evidence) rather than rediscovered.

Two facts about the seam, which iyi's own collector inherits as constraints:

1. **The seam is small.** gcry reopens Crystal's `module GC` and hooks its
   fibers. iyi's prelude has neither: it declares four functions and wires
   `__crystal_malloc64` and friends to them. A collector iyi owns is pointed
   at those four, and none of the `GC` facade is needed.
2. **A real collector raises the floor, and the gate will say so.** A process
   that gives memory back needs `munmap` beside `mmap`; on darwin the
   libSystem symbols become more and the Linux object stops being empty. That
   is not a regression, it is the trade: a default that does not collect
   becomes one that does, paying syscalls plus code iyi ships for it.
   `bench/dependency_floor.sh` will fail on the commit that does it, which is
   correct, and the commit adds the new symbols to the list with this section
   as the reason.

   **Resolved, and the trade came in under the prediction.** The flip's
   commit added darwin's `mmap`/`munmap` and root discovery's four to the
   list with this section as the reason, exactly as written — and the
   Linux object *stayed empty*, because the arena issues `mmap` and
   `munmap` as raw syscalls the way `write` and `exit` always were. On
   Linux a collected default costs the floor nothing at all.

One piece of luck this section named did not last, and what replaced it is
better: the own prelude grew III.4's scheduler before the collector's roots
were done, so the collector did not start "single-threaded with no fibers" —
it started with a fiber registry to walk, and `bench/root_exercise.sh` and
`bench/collect_trigger.sh` hold a parked fiber's stack as a root range. A
`--crystal` program has Crystal's fibers and is still not the configuration
this collector or floor measures.

#### Where the collector decision splits: the language, not the compiler

The decision in #20 is for the language, meaning the programs iyi builds, and
it does not reach the compiler, and the reason is threading rather than
anything about whose collector it is. The iyi compiler is not a parallelism-1
program: it runs parallel codegen over fibers. gcry, the nearest prior art,
ships proven and measured for `ExecutionContext` parallelism 1; its parallel
path is a supported opt-in measured at ~79% on one benchmark, with parallel
mark and TLAB-on both still marked experimental in its `DESIGN.md`. That
record is the honest estimate of the distance between a collector and a
collector that can host this compiler, and iyi's own starts at the same
distance.

Two ways through, unchanged by the decision. Keep bdw-gc on the compiler, or
build the compiler with sequential codegen so a single-threaded collector
applies. The second trades compile speed for a dependency, and compile speed
is the entire thesis of this project, so it is the wrong trade. **Decided
(#24, superseding this section's earlier form): the compiler keeps bdw-gc,
recorded as an exception carrying this reason, and the question is revisited
when iyi's own collector reaches the stage that serves parallel codegen, not
when any third party's does.** The asymmetry is real rather than convenient:
own-prelude programs are single-threaded because III.4 is unbuilt, and the
compiler itself is not. That is how one collector can be right for iyi's own
runtime and wrong for its compiler.

#### What the compiler depends on, which is a different list

```
libLLVM  libc++  libgc  libSystem
```

Four libraries, and **that list is read as the compiler's own link line:
direct dependencies, the same property `otool -L` reports on darwin and
`readelf -d` NEEDED entries report on Linux.** Both platforms measure the same
claim now, and `ALLOWED_LIBS_COMPILER` carries `libstdc++` beside `libc++`
because which of the two arrives is the distribution's choice of what its LLVM
was built against.

What libLLVM itself pulls in beyond that belongs to LLVM and to the
distribution that built it. On a typical Linux that is a dozen libraries, among
them libxml2, libz, libffi, libedit, icu, zstd and lzma; on darwin `otool -L`
on `libLLVM.dylib` prints libxml2, libffi, libedit, libz, libzstd and libz3,
so this is a property of LLVM rather than of one distribution's packaging.
None of it is part of iyi's floor: no iyi commit decided it and none can undo
it. What *is* part of the floor is any of those names turning up on iyi's own
link line, which is the case the denylist exists for, and reading direct
dependencies is what lets the gate see it (III.10 has the proof).

`iconv` left: the Makefile builds with `-Dwithout_iconv`, because iyi's
`String` has no encoding conversion and so the compiler had no reason to want
it either. `pcre2` left too, decided (#22) and carried out: macro-level regex
moved onto iyi's own engine, `src/compiler/iyi/rx.cr`, RE2 semantics,
differentially verified against pcre2, and then the four stdlib files this
compiler compiles into itself stopped using regex at all, which is what
actually took the library off the link line (III.10 has the files, the
verification and the two findings). Measured after a clean bootstrap: `otool
-L .build/iyi` prints exactly the four libraries above, and `nm -u
.build/iyi` leaves none of the thirteen `pcre2_*` symbols it used to. `libgc`
stays, and not for want of trying: `-Dgc_none` was built and is not viable
for the compiler itself (III.10 has the evidence), and iyi's own collector
does not yet reclaim what the compiler allocates. Not for the threading
reason above: `-Dgc_none` fails identically with parallel codegen switched
off, measured 5/5 either way, so the discriminator is freeing rather than
threads. So the
compiler keeps a collector and own-prelude programs do not. Its collector is a
recorded exception (Appendix B #24), not an unexamined habit. `libc++` arrives
with LLVM, and on two independent conditions rather than always. `llvm_ext.cc`
shims operand bundles and debug locations below LLVM 18; above it that object
is empty and goes unlinked. Separately, a statically linked `libLLVM` carries
its own C++ symbols at any version, where a shared one resolves them
internally. So the C++ runtime is owed when either holds, which is what the
Makefile gates `NEEDS_CXX_RUNTIME` on and what `ALLOWED_LIBS_COMPILER`
permits; with LLVM 18+ shared, measured on darwin arm64 at 22.1.8, it is off
the link line entirely. The first reading of this took a shared LLVM for the
whole story and called the library removable: CI links a static LLVM 20.1.2
and the floor caught the claim. **LLVM is the
list**, and Part V.9 already priced what owning the back end would cost while
declining to own the linker, for reasons that apply here with more force.

#### Self-hosting, which is settled, and the thing it is being confused with

B.2 settled it: iyi is not a self-hosting project. The argument is that Crystal
paid for self-hosting at 33k lines total and iyi would pay at 291k, against rules
that forbid the style most of those lines are written in. That argument is
unchanged and nothing in this section reopens it.

But "the only thing needed to build iyi is iyi" is a narrower claim than B.2
answers, and worth separating so the question stops being asked as one:

- **Porting this compiler to iyi.** What B.2 declined. 291k lines, and the
  Appendix's count of reopened types is the reason: the source is written in the
  style R-3 exists to forbid.
- **A bootstrap chain**: a released iyi built by the previous released iyi.
  This does not require porting anything. It requires *a* compiler for iyi
  written in iyi, which is a much smaller target than the fork, because it has
  to compile one language rather than two. Go's own path is the evidence and it
  is not the flattering version: `gc` stayed a C compiler until Go 1.5, and the
  transition was a mechanical translation rather than a rewrite.

The second is not scheduled. It needs IO, which iyi's own prelude does not
provide; `--crystal` provides Crystal's standard library and IO, but that is a
different library mode. **The own-prelude program floor above does not depend
on self-hosting**: it is measured, not projected, on a compiler that is still
a Crystal program. A compiler that needs LLVM to build itself emits
own-prelude binaries whose only host library is the platform libc, and whose
object for Linux asks that libc for nothing.

#### The toolchain-floor rule: zero library dependencies, permitted toolchain

The dependency rule is now decided as policy: **zero library dependencies in
what iyi ships or builds**, with LLVM and `cc` permitted as toolchain
requirements. This is the posture Go held while bootstrapping through C.

The rule states:

1. **A program iyi builds links the platform libc and nothing else.** On
   Darwin that is libSystem; on Linux an own-prelude object requests no
   symbols, and the linked executable carries only the link template's runtime
   start symbols. None of Crystal's thirteen ancestor libraries are reachable.
2. **The compiler may link LLVM and the platform libc.** LLVM and `cc` are
   permitted as **toolchain** requirements. A native backend (instruction
   selection and machine-code emission for arm64) and an own object-file
   linker were explicitly considered and not chosen. This is a deliberate
   decision rather than an omission.
3. **Every external tool is recorded with a reason.** The compiler and build
   system do not invoke unexamined host binaries. Tools required to build the
   compiler or link user programs are enumerated with reasons rather than
   admitted by habit.
4. **The two entries that have known exits are recorded as temporary with their
   exit conditions**, so nobody reads them as settled architecture:
   - `libgc` (bdw-gc): the Boehm collector used by the Crystal bootstrap
     compiler. Programs built by iyi use `IyiHeap` and link no collector
     library. `libgc` is present on the compiler only, and leaves when the
     compiler stops being a Crystal program.
   - `crystal`: the parent bootstrap compiler. It is a build-time tool only,
     and leaves at stage two when a released iyi compiler builds the next
     released iyi.

The gate in `bench/dependency_floor.sh` enforces this floor. An explicit
denylist names all thirteen of Crystal's ancestor libraries, so if any returns,
the failure message identifies it as an ancestor dependency rather than a
generic unexpected library.

#### Order

1. ~~Route the prelude's allocator through the flag, so `gc_none` means
   something.~~ Done, and then inverted: the libc allocator is the default and
   `-Dgc_boehm` is the opt-in.
2. A precise, non-moving collector, iyi's own (Appendix B #20), because II.5
   already requires one for R-4.
3. ~~Raw syscalls for `write` and `exit` on Linux, which the tree can already
   do.~~ Done, and further than written: the prelude issues the raw syscalls
   for `write`, `exit` and the allocator (`mmap`) on Linux.
4. ~~Nothing about LLVM, and nothing about self-hosting.~~ Decided: the
   toolchain-floor rule permits LLVM and `cc` as toolchain requirements, while
   library dependencies are zero and the two bootstrap dependencies carry
   explicit exit conditions.

### III.10 Every library Crystal needs, and iyi's answer for each: **PROPOSED**

III.9's five symbols are true and flattering because they are the floor of
iyi's own prelude, which carries whole-file `File` IO, stdin, and
`Program.args`/`.env` (restated from "no IO beyond `puts`", which the tarball
and agent work outgrew), and still no regex, no
TLS and no serialisation. `--crystal` is outside this floor and may link the
standard library's dependencies and anything a required shard pulls. **Every
dependency below arrives in the own mode attached to a feature**, and the
decision about it has to be taken when that feature is written, before a
library is reached from a hundred places and stops being a decision.

This section exists so the decision is taken once, in a list, from Crystal's own
published inventory rather than from whatever turns up.

**The principle, stated once so the table can be short: iyi owns everything
above libc, and libc is optional.** That is Go's position and Go's evidence is
the whole argument. `CGO_ENABLED=0` produces a static binary that depends on
nothing; `crypto/tls`, `encoding/xml`, `encoding/json`, `math/big`, `regexp` and
`compress/flate` are all written in Go; the runtime talks to the kernel
directly. None of that is purity. It buys cross-compilation that works from any
machine to any target, one artifact per target rather than a matrix against
system libraries, no build that fails because a header is missing, no version
skew between a package and a `.so`, and a container image with nothing in it.
All of those are developer experience, which is the thing being competed for.

#### The inventory

From Crystal's own *Required libraries* page, plus every `@[Link]` in this tree.
"Reachable" means reachable from an iyi program today.

| Library | What it is for | Reachable | iyi's answer |
|---|---|---|---|
| libc | everything | yes: `write`, `exit`, `memset` and the collector's `mmap`/`munmap` on darwin | keep. On Linux the prelude issues the raw syscalls instead, so the object asks libc for nothing and the executable carries only the link template's five |
| kernel32, advapi32 (Windows) | the platform itself | yes: `WriteFile`, `ExitProcess`, `VirtualAlloc`, `CreateThread`, the completion port — and `RtlGenRandom` for `std/random` | keep, and only these two. Windows has no libc of its own: the C runtime's POSIX shims are a person-installed choice of CRT and the Win32 API is the platform's contract, which is the same answer Go gives. `kernel32` is the floor; `advapi32` is one function, the OS entropy `Random.new` seeds from, and there is no kernel32 name for it. Both ship with every Windows, so an `.exe` iyi builds still needs nothing installed |
| ws2_32 (Windows) | sockets | yes: `socket`, `bind`, `listen`, `recv`, `send`, `recvfrom`, `sendto`, and the posted `AcceptEx`, `ConnectEx`, `WSASend` and `WSARecvFrom` the completion port answers — `std/socket` and `std/udp`, and nothing else | keep, and only for those two. Winsock *is* Windows' network interface: there is no socket call anywhere else, not in kernel32 and not in a CRT, which is the same position `kernel32` holds for processes and files. `ws2_32.dll` ships with every Windows, so an `.exe` iyi builds still needs nothing installed. `AcceptEx` and `ConnectEx` are mswsock's exports and are reached by asking a socket for the pointer (`WSAIoctl` with `SIO_GET_EXTENSION_FUNCTION_POINTER`) rather than by linking `mswsock`, so Windows' sockets are one row here and not two |
| Boehm GC | allocation | no: the default is the owned collector, arena over the platform's own `mmap`; `-Dgc_boehm` opts libgc back in, `-Dgc_none` opts out of collecting | **owned, shipped, default.** II.5 already required a precise collector for R-4; GC_DESIGN.md is the record and `bench/gc_default.py` the measurement that flipped the default. Present on the compiler only as a temporary bootstrap runtime dependency with an exit condition: leaves when the compiler stops being a Crystal program |
| compiler-rt builtins | 128-bit divide, float conversion, overflow-checked multiply | no | **already owned**: `src/crystal/compiler_rt/` ports them to Crystal. Keep porting |
| libunwind / libgcc | exception backtraces | no | own the walk. III.1 is what makes this cheap: errors are union members, so only a panic unwinds |
| libevent | event loop | no | **never adopt it.** Crystal already wrote native backends and libevent is its default only on OpenBSD, NetBSD, Dragonfly and Solaris |
| pthread | threads | no | kernel calls directly, as Go does. Arrives with III.4 |
| libdl | `dlopen` | no | do not offer dynamic loading |
| libm | `sqrt`, `pow` | no | LLVM intrinsics where they exist, iyi where they do not |
| libiconv | encoding conversion | no | never. UTF-8 only, which is Go's answer and already iyi's. The compiler dropped it too (`-Dwithout_iconv`) |
| PCRE2 | `Regex` | no | **decided (#17, #22) and done: RE2 semantics everywhere, on iyi's own engine** `src/compiler/iyi/rx.cr`, macro-level regex included, differentially verified against pcre2, and `libpcre2` measured off the compiler binary rather than only out of compiler source. The price: macros lose the constructs that are not regular, backreferences, recursion, subroutine calls and conditionals, plus atomic groups and possessive quantifiers, which are controls for a backtracker there is none of here; a macro using one fails with a named error. Lookaround was on this list and should never have been, corrected in III.10 and in #17. `Spec::CLI#pattern` changed type from `Regex?` to `String?` |
| OpenSSL (libssl, libcrypto) | TLS, digests | no | digests **already owned** (`src/crystal/digest/`). TLS: not in 0.x, own it eventually, a binding never in the prelude |
| zlib | `Compress` | no | **owned**: `src/std/compress.iyi` is DEFLATE, zlib and gzip in iyi — every block type read, one fixed-Huffman block over a 32 KiB LZ77 window written — and `bench/std_compress_exercise.sh` reads 72 of zlib's streams and has zlib read 18 of iyi's. DEFLATE was a known quantity and it arrived with HTTP, as this row said it would |
| libxml2 | `XML` | no | no XML in the prelude. A package, written in iyi |
| libyaml | `YAML` | no | same, and Go ships no YAML at all |
| GMP / MPIR | `BigInt`, `BigFloat` | no | own it or do without. Go's `math/big` is Go |
| libffi | the interpreter's FFI | no | gone with the interpreter (V.11) |
| LLVM, libstdc++ | the compiler's back end | no | compiler only. Permitted as a toolchain requirement (native backend and own linker considered and not chosen; III.9). Part V.9 and B.2 |

**Two of them are already answered by work in this tree and neither was on
anybody's list.** `compiler_rt` is ported to Crystal, so the routines LLVM emits
calls to are iyi's own code rather than a link against clang's runtime. And MD5
and SHA1 are Crystal implementations in `src/crystal/digest/`, which is why the
artifact's hashing needs no libcrypto. The pattern to notice is that both were
cheap and both removed a dependency permanently.

#### The four that needed a real decision

Everything else in the table is either already owned or a feature not to offer.
These four were where the work was. Two are now decided rather than
recommended: the collector (#20) and regex (#22).

**1. The event loop, and it is the cheapest big win because it is already
done.** `src/crystal/event_loop/` carries `epoll`, `kqueue`, `io_uring`, `iocp`,
`polling` and `wasi` backends beside the `libevent` one. Crystal moved off
libevent for mainstream platforms and iyi inherits that for free. What matters is
the timing: **III.4 is proposed and unbuilt**, so the choice of what structured
concurrency is written against is live right now, and the only wrong answer is
the one that reaches for libevent because it is the shortest path. Adopting it
would put a C library under every concurrent iyi program, permanently, to save
work that has already been done by somebody else.

**2. The collector.** III.9 and II.5, and the ground moved under it twice: the
default stopped linking libgc, so the floor stopped arguing for the collector
— and then the collector arrived and became the default without giving the
floor back (GC_DESIGN.md, `bench/gc_default.py`). The price this paragraph
recorded — a default that allocates and never frees — is paid no longer; it
is `-Dgc_none`'s price now, chosen rather than shipped. One shortcut was
recorded here as closed by measurement, and it is now open, because the
measurement was of a bug rather than of a limit.

**`-Dgc_none` was not viable for the compiler itself, and the reason was never
a collector. It was one byte, in the standard library.**
`String::Builder#increase_capacity_by` grew its buffer to
`real_bytesize + count`, while `to_s` writes the string's terminator at
`@buffer[real_bytesize]`. A string whose final size landed exactly on its
capacity therefore had its terminator written one byte outside its allocation,
and the reclaiming shrink in `to_s` was skipped, because the capacity was not
bigger than what was needed. bdw-gc rounds a block up and never reissues an
address something still points at, so under the collector every program was
correct; plain `malloc` returns exactly the size asked for, and the next
allocation overwrote the byte.

The symptom was a 116-byte mangled function name in a 128-byte block that
needed 129: clean at `target_def_fun`, corrupt at the same address by
`check_mod_fun`, LLVM's `strlen` reading into whatever was allocated next, and
`samples/iyi/collections.iyi` failing to link **10 runs out of 10** with
`Undefined symbols for architecture arm64` naming
`Nums@Std::Enumerable::Enumerable#zip<Words>`, sometimes with a
`Trace/BPT trap: 5` inside the compiler.

Fixed, and measured on the fix: that sample builds **0 failures in 10 runs**
with a fresh cache each, **every one of the 27 samples builds**, the iterator
exercise is green, and the collector-free compiler links **libLLVM and
libSystem only**. `bench/collector_free_floor.sh` is the gate, and removing
the reservation again fails it.

**Four mechanisms were recorded for this blocker before the right one, and all
four were wrong:** invalid IR, a dropped symbol, an empty link line, and
parallel codegen. Each was a plausible reading of an error message promoted to
a cause before it was isolated. What settled it was measuring the allocation
rather than reasoning about the compiler: the block was 128 bytes and the
string needed 129.

So the compiler keeps bdw-gc by default because it is a permitted toolchain
dependency and dropping it is a decision about peak memory, not about
correctness. What this section no longer claims is that a collector is
required for the compiler to work. It is not.

That finding now has a boundary drawn around it, and the collector inside it
has a decision. **The owner decided (Appendix B #20, overruling the adopt-gcry
recommendation this section carried): iyi writes its own collector, and gcry
stays as prior art whose measurements are inherited.** The decision is for the
language, the runtime iyi programs run on, and it does not reach the compiler
yet, though the reason it does not is now a choice rather than a wall.

Parallel codegen was blamed for this and cleared, which is worth keeping
because it is the second time. Measured against the Makefile's own
`sequential_codegen` switch, which removes the parallel half:

| build | `collections.iyi` |
|---|---|
| `-Dgc_none` | failed 5/5 |
| `-Dgc_none` + `sequential_codegen=1` | failed 5/5 |

Identical, so **threading was not the discriminator**. III.11's cache-cleaner
bug is the first instance, and the lesson is the same both times: a symptom
shared by the failing builds is not a cause. The right cause turned out to be
smaller than every mechanism proposed for it, and in the standard library
rather than the compiler.

**The exit condition recorded here was "a collector that frees", and that is
withdrawn.** A compiler built with no collector at all now compiles every
sample, the 7,207-line generated project, and the compiler's own source, so
freeing was never what stood in the way. What a collector buys the compiler is
peak memory, and that is now a number rather than a worry:

| build | 30-module project (7,207 lines) | the compiler's own source |
|---|---|---|
| with bdw-gc | 464 MB peak, 0.74s | 5,702 MB peak, 22.3s |
| collector-free | 598 MB peak, 0.78s | 7,430 MB peak, 20.3s |

**+29% peak, and wall time within noise**, both at zero failures in ten runs.
So bdw-gc stays on the compiler by decision rather than by necessity
(Appendix B #24, superseded and restated): it is a permitted toolchain
dependency, and 1.7 GB of extra peak on a self-host is a real cost to put on
every contributor's machine for a library the floor already permits.
`bench/collector_free_floor.sh` keeps the collector-free path working, gating
the samples, the project, and the terminator property directly, so the option
stays open rather than rotting. Flipping the default is a one-line change to
`COMPILER_FLAGS` whenever that memory trade is judged worth taking.

**3. Regex, and the semantics are the interesting part. Decided (#22), built,
and measured off the binary.** Owning PCRE2 removes a dependency from iyi
programs *and* from the compiler, which linked it. The program half was
writing the engine. The compiler half had two walls in it, and only the first
was visible from the source.

The first wall was macro-level regex, which is a language feature rather than
an internal convenience: `macros/methods.cr` implements `=~`, `gsub`, `match`,
`scan` and `split` over a `RegexLiteral`, and `semantic/literal_expander.cr`
expands a user's regex literal. Six internal regex uses had already been
rewritten to string operations and pcre2 still linked, which is what proved
the wall was there. It came down by moving macro-level regex onto iyi's own
engine, `src/compiler/iyi/rx.cr`, differentially verified against pcre2,
so pcre2 left compiler-owned source without cutting what a user's macro can
do.

**And pcre2 was still on the link line.** The second wall was in the stdlib,
and the reason this document recorded at the time was wrong: the leftover was
blamed on Crystal's prelude, on `require "regex"` emitting `@[Link("pcre2-8")]`
even when nothing calls it. An unused `@[Link]` does not put a library on the
link line, and the probe that proved that is in the gate paragraph below. The
cause was found by reading the binary rather than reasoning about the source:
`--emit llvm-ir` shows ten expanded regex constants, `$Regex:0` through
`$Regex:9`, and their patterns identify four stdlib files the compiler compiles
into itself. Every one of them is reachable from the compiler, which is the whole
point:

| File | The regex | Why the compiler reaches it | Verification |
|---|---|---|---|
| `src/option_parser.cr` | seven literals in `parse_flag_definition` | `compiler.cr`, `loader.cr` and most of `command/*` | 20,633-case differential against the original seven, 0 mismatches |
| `src/process/shell.cr` | one literal in `Process.quote_posix` | the compiler shells out to the linker | 194,690-input differential over every Unicode scalar to U+2FFFF, 0 mismatches, plus a live `/bin/sh` round trip of 18 hostile arguments |
| `src/semantic_version.cr` | `VERSION_PATTERN` | `macros/methods.cr`, for the `compare_versions` macro method | `valid?` and `parse?` now share one scanner so they cannot drift, and the pre-existing asymmetry is kept on purpose: `valid?("99999999999999999999999.1.1")` is true while `parse?` raises `ArgumentError` out of `to_i` |
| `src/spec/cli.cr` | `--location`, and `-e/--example` doing `Regex.new(Regex.escape(pattern))` | `command/spec.cr` requires `spec/cli` so `--help` can print the runner's options | two uses rather than one; `-e` was substring matching written the long way and is now `String#includes?`, and `--location` scans by hand |

All four parse by hand with no engine, and none of them calls `Iyi::Rx`.
The stdlib does not get to reach into compiler internals, so the conversion
had to be arithmetic over bytes rather than a different engine.

**And a price that reaches outside the compiler.** `-e/--example` changed a
stdlib public API type. `Spec::CLI#pattern` was `Regex?` and is now `String?`,
and `Spec::Item#matches_pattern?` and `filter_by_pattern` now take a `String`,
with `=~` replaced by `includes?`. The behaviour is identical, because
`Regex.escape` had already reduced every pattern to a literal substring, but the
type is a breaking change for anybody who called those directly.

**Two findings here are worth more than the dependency**, because either one
costs real time to rediscover. First, PCRE2 in this tree is compiled with
`UCP`, so its `\s` is Unicode while `Char#whitespace?` is `\p{Z}` plus the
ASCII controls. The two predicates agree on every character except U+0085 NEL,
which `option_parser.cr` now handles by name. That boundary was found rather
than assumed: an earlier differential run reported 1,114 mismatches and every
one of them contained U+0085. The same flag makes `\d` mean `\p{Nd}`, so
`--location` used to accept a non-ASCII digit as a line number and
deliberately no longer does. Second, a lazy `(.+?)` followed by an
end-anchored `(\d+)\Z` does not split at the first separator. `(\d+)\Z` has to
reach the end and `:` is not a digit, so the engine backtracks until the last
colon is the split, which makes `a:1:2` file `a:1` line 2. A `split(':')`, or
any leftmost scan, is wrong, and that is the only reason `parse_location`
scans backwards.

And the engine takes RE2's semantics rather than Perl's, which is a choice
about the language, not a port: PCRE backtracks and can be made to take
exponential time on ordinary-looking input, which is the standard
denial-of-service in every language that ships it. Go refused that trade and
iyi takes it too. In exchange, no pattern can take exponential time, in a
program or at compile time.

**What that trade costs was recorded wrongly here, and the correction matters
more than the capability it restores.** This section used to state the price
like this: "macro authors lose in-pattern backreferences and lookaround, and a
macro using one fails with a named error rather than quietly meaning something
else." Half of that sentence was false, and the premise under it was that
lookaround needs a backtracker. It does not. A lookaround over a regular inner
pattern is itself a regular property of a position, so it is answered by a
pre-pass costing one state set per character and nothing per position, and the
engine now runs exactly that: all four forms, `(?=)`, `(?!)`, `(?<=)` and
`(?<!)`, nested to any depth. RE2 omits lookaround because of its one-pass DFA
design, not because linear time forbids it, and reading RE2's omission as the
guarantee's price is what cost this tree a feature it could have had all along.
Decision #17 stands exactly as made; what was wrong was the scope of what it
costs, not the decision.

**What the guarantee actually costs is the constructs that are not regular:**
backreferences, recursion, subroutine calls and conditionals. No simulation
answers them, and matching backreferences is NP-hard, so no amount of care
makes them linear. Those stay refused, and a macro using one still fails with a
named error rather than quietly meaning something else.

**Two further refusals are kept separate, because the reason is a different
one.** Atomic groups and possessive quantifiers are controls for a
backtracker, and there is none here to control, so they are refused as
inapplicable rather than as expensive. And one refusal is new, arriving with
lookaround rather than surviving it: a capturing group inside an assertion. The
pre-pass answers whether an assertion holds at a position and never which text
its inner pattern consumed, so the group cannot be set, and reporting an empty
capture where pcre2 reports a real one is exactly the quiet difference this
engine exists to avoid.

**Lookbehind here is not length-limited, and pcre2's is**, so this is the one
place the owned engine is more capable than the library it replaced rather than
less: patterns pcre2 refuses for a variable-length lookbehind compile and run
here.

Alongside lookaround the engine took the rest of what a pattern in this tree
reaches for. Named groups in all three spellings, `(?<name>)`, `(?'name')` and
`(?P<name>)`, numbered alongside unnamed ones the way pcre2 numbers them, with
name lookup on the match. `\p{...}` and `\P{...}` for L, Lu, Ll, N and M,
braced or single-letter, inside a character class or out, with every other
category refused by name rather than approximated. `\v` as pcre2's vertical
whitespace class and `\V` as its complement. `\x{...}` at any digit count,
refusing at the offending position for no digits, a missing brace, a value
above U+10FFFF, or a surrogate, which pcre2 in UTF mode refuses too. And `(?i)`
folding past ASCII through `Char#downcase(Unicode::CaseOptions::Fold)`, simple
case folding, the same relation pcre2 uses. `spec/compiler/iyi/rx_spec.cr`
holds all of it against pcre2 over one corpus, 31 examples including exhaustive
codepoint sweeps for the character classes, and none of it cost a library:
`bench/dependency_floor.sh` still exits 0.

**Three readings are this engine's own rather than inherited from pcre2, and
all three are narrow.** They are divergences on purpose, each with a stated
reason, because a silent one is the failure this engine was written to prevent:

- `\d` is any Unicode number, Nd plus Nl plus No, where pcre2 under `UCP` means
  `\p{Nd}` exactly, so `½` and `Ⅴ` match here and do not there. No public
  stdlib predicate answers Nd on its own: `Char#number?` is the three-way
  union and everything finer is `:nodoc:`. Shipping a case table to close one
  class is worse than saying this, so `\p{Nd}` is refused rather than
  approximated into agreement.
- `ß` and `ẞ` do not match caselessly here and do in pcre2. `ẞ` full-folds to
  `"ss"`, so the stdlib's fold leaves it alone, while pcre2 pairs the two
  through simple case mapping. Chasing that one pair with an extra downcase
  comparison opens others, because simple lowercase is not symmetric. Exact for
  every other codepoint, verified by exhaustive sweep.
- Lookbehind follows the union law here and does not in pcre2. `(?<=A|B)` must
  hold exactly where `(?<=A)` or `(?<=B)` holds. Measured on subject `"a"` at
  byte 0, where neither branch holds: `(?<=(?:a|$))` searched from 0 reports a
  match at byte 0, the same pattern anchored at 0 reports nothing, and the
  ungrouped `(?<=a|$)` correctly reports nothing. So the trigger is the
  wrapping group, not the differing branch lengths, and pcre2 contradicts its
  own anchored evaluation. No mechanism is claimed beyond that: an earlier
  explanation blamed fixed-width stepping and the ungrouped row refutes it. The
  spec pins pcre2's per-branch answers and never its answer for the pair.

**4. TLS, which is the one to be honest about.** This is the largest library iyi
would ever write and the only one where being wrong is a vulnerability rather
than a bug. Three options, in order of how much they cost: no TLS in 0.x, which
is where the language is anyway; a binding to OpenSSL as a package under III.6,
which is available immediately and never belongs in the prelude; and a TLS 1.3
implementation in iyi, modern ciphers only, which is the eventual answer and
should not be attempted until there is something to protect and somebody to
audit it. What must not happen is OpenSSL becoming reachable from the prelude,
because that is the version nobody can back out of.

#### The rule, so this is not re-litigated per library

**No C library may be reachable from iyi's own prelude.** A binding to one is a
package (III.6, III.7), never a prelude feature. That keeps the floor a property
of the language rather than a habit of whoever wrote the last commit, and unlike
most rules in this document it is checkable by a machine.

**So it is checked.** `bench/dependency_floor.sh` builds every sample using
iyi's own prelude; it does not build `--crystal`. It reads undefined symbols
and linked libraries from each binary, does the same for the collector build
(`-Dgc_boehm`), and fails when either list grows past what this section records.
The allowed lists are per platform, because the platforms
are not the same claim: darwin's five libSystem symbols, or the five the Linux
link template leaves, and the platform libc alone either way. `libgc` and the
four `GC_*` entry points come back for the collector build. It reads the
compiler binary too, against `ALLOWED_LIBS_COMPILER`, now `libLLVM libc++ libgc
libSystem` plus the platform's own entries, and against a `FORBIDDEN` denylist
that own-prelude samples and the compiler must both clear. `libpcre` is on that
denylist, so the compiler is held to the same rule as own-prelude programs. It
runs in CI beside the roundtrip check.

**And `src/std/` is measured too, twice over.** The samples are what a person
writes; the library is what they import, and a module no sample reaches was
measured by nothing. Importing one is not enough to see it — codegen is
demand-driven, so `import std/socket` on its own asks the linker for no
socket symbol at all — so the gate builds each `bench/std_*_exercise.iyi`,
which is the program that calls its module's surface, and reads its symbols
and libraries into the same two sets. That leaves the case a measurement
cannot reach: a `@[Link]` sitting in the library against the day somebody
calls it, which is the shape a link line grows in. So the annotations are
also read as text, across `src/iyi` and `src/std`, and the list is the three
the library has reasons for — `kernel32` and the MSVC runtime on Windows,
and `bdw-gc` for the opt-in collector. A fourth fails the gate, whether or
not any program reaches it.

**The five on Linux are allowed by exact name.** `__libc_start_main`,
`__gmon_start__`, `__cxa_finalize` and the two weak `_ITM_` clone-table
callbacks, spelled in the script the way `nm -u` reports them with one leading
underscore stripped. They belong to the link template's `crt1.o`, `crti.o` and
`crtbegin.o` rather than to the prelude, and they are listed rather than excused
for that reason. A wildcard was the alternative and it was rejected: "whatever
the crt supplies" is not a measurable set, and a pattern loose enough to cover
it would also cover the one failure this check exists to catch, a prelude
falling back to libc. `malloc` and `mmap` are not on the list and still fail.

**And the libraries read are the binary's own.** `otool -L` reports a Mach-O
binary's `LC_LOAD_DYLIB` commands, `readelf -d` reports an ELF binary's
`NEEDED` entries, and those are the same property: what this binary asks the
loader for. `ldd` was on the Linux path and was wrong twice. It prints the whole
transitive closure, so libLLVM's own dependencies arrived as iyi's and the
compiler appeared to link libxml2, libz, libffi, libedit, icu, zstd, lzma,
libbsd, libmd and libtinfo, not one of which iyi names; darwin never showed any
of it, so the two platforms were measuring different claims. Worse than noisy,
it disarms the check: an allowlist holding libxml2 because libLLVM brings it can
never notice iyi reaching for libxml2 itself, which is the only case the
denylist exists for. `ldd` also printed `linux-vdso.so.1`, which no list here
tolerates and none needs to: it was never a `DT_NEEDED` entry at all. The kernel
maps it and `ldd` merely said so, and reading NEEDED entries makes it disappear
rather than excusing it.

**On Windows the same property has a third reader, and it is the
toolchain's own.** A PE binary's imports are its import table, which
`dumpbin -dependents` reports as DLLs and `dumpbin -imports` as the
symbols under each; that is the same question `otool -L` and `readelf -d`
answer, and it is asked per program rather than transitively, so LLVM's
own imports never arrive as iyi's. `dumpbin` is not on a shell's `PATH`,
so the gate locates it through `vswhere` the way `codegen/link.cr` locates
the linker. Two Windows-shaped details are written into the gate because
each cost a run: the flags are spelled `-imports` and `-dependents`,
because a POSIX shell rewrites `/imports` into a path before `dumpbin`
sees it, and every argument carries its `.exe`, because `dumpbin` reads an
extensionless file as an object.

Measured over 114 program binaries — every sample plain and `--release`,
every std exercise — the answer is four distinct import sets and nothing
outside the allowlist: 103 programs import `kernel32.dll`,
`vcruntime140.dll` and five UCRT façades (runtime, math, stdio, locale,
heap); five add `api-ms-win-crt-environment` (the `Program.env` readers);
four add `ws2_32.dll` (`std/socket`, `std/udp`); two add `advapi32.dll`
(`std/random`). The teeth were proven the way the POSIX ones were: with
`kernel32.dll` taken off the allowlist in a throwaway copy, the gate exits
1 naming the program and the DLL.

**And the branch that judged an unread floor is gone, on every platform.**
Before this, a box without `nm` read no symbols and the gate then printed
"The floor got lower and this script is out of date. No longer needed:"
followed by the entire allowlist and an invitation to delete it — advice
that would have disarmed the check, produced by a measurement that never
happened. It is guarded on having read something now, which is a Linux
defect as much as a Windows one; a missing reader prints one line naming
what went unmeasured, and the summary counts it rather than claiming the
floor held.

**The distinction is real, and it was proven in both directions.** Rebuilding
the compiler with an explicit `-lxml2` fails the gate by name; the same library
sitting inside libLLVM passes; and `otool -L` on `libLLVM.dylib` confirms it is
genuinely in there, beside libffi, libedit and libz. So the gate fires on a
library iyi took and stays quiet about one LLVM took, which is the line this
document draws. What it gives up is honest and small: a change in what an
already accepted library pulls in is not caught, and no iyi commit made that
change or can unmake it.

**What it does not cover, said here rather than found later.** The five crt
names were measured against the glibc in the container this repository pins for
CI. A different base contributes a different fixed set: musl's link template
leaves other names, an older glibc leaves fewer. That build fails loudly and by
name instead of passing quietly, which is the behaviour to want from a check
whose whole job is to notice this list changing, so it is the intended
behaviour rather than a gap. Widening the list to cover libcs nothing here
builds against would buy nothing and cost the teeth.

**And the two audits do not cover the same platforms**, which is worth naming
because musl is one of them. Nine targets are type-checked for the library, and
the seven the object-layer audit reads are not a subset of the same list:
`x86_64-linux-musl` and `arm-linux-gnueabihf` type-check and are never audited.
So the object claim above is measured on glibc and wasm and Windows, and on
musl it is type-checked only. `x86_64-w64-mingw32` and `x86_64-windows-gnu`
look like a second asymmetry and are not: LLVM normalises both to
`windows-gnu`, differing only in vendor, and Crystal's `Target` reads the
environment rather than the vendor. Closing the real gap is a change to the
workflow rather than to this section.

Proven to fail the only way that counts, and three times. The `-lxml2` rebuild
above is one. Adding a two-line `lib LibM` call to `hello.iyi` makes it exit
non-zero naming `sqrt`, and removing it makes it pass again. Injecting a
reachable regex literal back into `src/option_parser.cr` makes it fail at both
compiler layers, naming the gained library and naming the denylist hit. The
first attempt at that regex probe was invalid and was discarded rather than
written up as a weak gate: it added an unused constant, and Crystal never
instantiates an unreachable constant, so no library came back. That is also the
evidence that a `require` or an `@[Link]` was never what kept pcre2 on the
link line.

A new symbol is not automatically wrong, and the script says so. It is a
dependency being taken on, and the way to take one on is to add it to the list in
the same commit, which is a sentence somebody has to write and a reviewer gets to
read. What the check refuses is the other version, where a library arrives with a
feature and nobody finds out until a build fails on a machine that does not have
it.

#### Where zero is not reachable, said plainly

On Linux the object bottoms out at nothing, and it is no longer a projection:
the kernel is the interface, the prelude issues the raw syscalls itself for
`write`, `exit` and the allocator (`mmap`), and an iyi program's object for
`x86_64-linux-gnu` imports nothing. The linked executable is a step up from
that and only one step: the C runtime's five, named in III.9, and libc as the
one library, which is what a link template that starts a process costs. A
static binary with no libc at all is a normal thing to produce and is the next
step rather than a claim made here. **On macOS zero is not reachable at any
layer.** Apple's only supported interface is libSystem, raw syscalls are
explicitly not a stable ABI, and a binary that makes them is one OS release
from breaking. So the floor there is libSystem and that is Apple's rule rather
than a gap in this design; Go links libSystem on darwin for the same reason.
Windows is the same story with a different name.

The honest form of the own-prelude claim is therefore: **no dependency iyi
chose**, measured rather than promised and stated at the layer measured. At the
object layer, on Linux, there is no dependency at all. At the executable layer,
on Linux and macOS, the platform libc is the only library: five symbols on
macOS that the prelude asked for, five on Linux that the link template added.

### III.11 The interpreter, again: **DECIDED (Appendix B #25): yes, on the macro interpreter, no C interop**

This reopens a decision the document had settled, so it says what changed, and
what changed is not the evidence. V.11 removed Crystal's interpreter and
Appendix B #11 decided no, and the findings still stand: it was compiled out
already, no commit of this fork had touched it in 153, it could not run an iyi
program past the module header, and an interpreter is a second implementation
of the semantics, a price that keeps being paid while the language moves.
**What changed is that the owner asked for one, with Elixir's `iex` as the
reference.** A REPL is a developer-experience claim, which is the thing this
project competes on, so the question stops being whether to want it and
becomes what it costs and which base keeps the cost down.

**The conflict with the dependency objective is libffi, and libffi is C
interop.** libffi is on Crystal's own required-libraries list, "used for
implementing binary interfaces in the interpreter", so a naive revert of the
removed interpreter would put back exactly the kind of dependency III.9 and
III.10 exist to keep out. It is needed for one thing only: interpreted code
calling out to C. An interpreter that does not offer C calls needs no libffi,
which is Elixir's model, and a first iyi REPL has nothing to call out to
anyway, the only C in a program being the prelude's own primitives. So the
shape is fixed by the objective: **no C interop in a session, no libffi**, and
C calls, if they ever reach a REPL, arrive as a compiled escape hatch rather
than an interpreted one.

**The base is the macro interpreter, not the revert.** The removed runtime
interpreter is 11,377 lines and interprets Crystal, which is why it stops at
`BUG: missing interpret for Crystal::ModuleHeader` on line 12 of the simplest
sample. The macro interpreter that stayed,
`src/compiler/iyi/macros/interpreter.cr`, is 781 lines, is a complete AST
evaluator, and already resolves types, which is the hard half of the distance
between accepting a line and running it. Extending it for iyi's nine new AST
nodes and two `Def` clauses is a second implementation of the semantics either
way, which is what V.11 objected to, but it starts from 781 lines rather than
11,377, and from code that already runs iyi's macros rather than from code
that never ran an iyi program. V.11's parting line, that the removed
interpreter is in the history and "a better starting point when there is an
iyi to interpret", is overtaken by that: there is an iyi to interpret now, and
the smaller evaluator is in the tree.

**R-1 helps a REPL, and R-3 costs it one habit.** A module is the unit of
compilation and imports read declarations rather than bodies, so what a
session must recompile after an edit is bounded by the module graph, where
Crystal's whole-program model offers a REPL no boundary at all and
re-elaborates the world per line. The costs are stated beside it: every
session needs a module header, because that is where R-1 keeps declarations,
and open class extension, which is what a REPL user reaches for to patch a
running program, is forbidden by R-3. An `iex` for iyi answers with `impl`,
and is a smaller REPL than Ruby's on purpose.

**Appendix B #25 has decided: build it on the macro interpreter, without C
interop.** The no-libffi half of that is enforced rather than assumed:
`libffi` is on `bench/dependency_floor.sh`'s denylist, and the gate was proven
to fire by adding to a sample the exact `@[Link("ffi")]` shape a naive revert
would produce. It failed at three independent layers, reporting the gained
symbol `ffi_prep_cif`, the gained library `libffi.8.dylib`, and the denylist
hit, so an interpreter cannot quietly bring libffi with it.

### III.12 The sandbox: **BUILT, by subtraction; measured by `bench/sandbox_story.sh`**

Untrusted code needs a container, and generated code is the untrusted code
of this decade: a model writes a program, something has to run it, and the
something's blast radius is a design property of the language it runs.
iyi's answer costs nothing because it is made of two subtractions this
document already paid for elsewhere.

The first is the dependency floor (III.9): an iyi program's Linux object
has zero undefined symbols, so there is no libc surface for a payload to
lean on. The second is the wasm32-wasi target, where the answer is
stronger than a permission — it is an *absence*. The prelude's wasm32
branch never grew a `File` surface: `path_open` needs a preopened
directory fd, wasmtime preopens nothing by default, and rather than carry
a capability negotiation the prelude refuses by name. A program that
tries is a panic that says whose rule it hit:

    iyi: panic: File is not available on wasm32-wasi: path_open needs a
    preopened directory fd

`bench/sandbox_story.sh` is the measurement, three steps: an honest
program computes and prints through the boundary (`55`, exit 0); a theft
of `/etc/passwd` exits non-zero with not one byte of the file in its
output, under a default wasmtime; and the refusal is the prelude's own
sentence rather than a trap code, because a sandbox whose denials cannot
be read teaches nobody. Run in CI beside the wasi arm that already links
and runs `hello` there.

What this is not, said plainly: it is not an argument that native iyi
binaries are sandboxes — a native binary has the kernel — and it is not a
capability system. When the wasm32 arm grows real IO it will grow it
through WASI's preopens, and this section is where that negotiation gets
designed before it gets built.

---

## Part IV: `.iyimod`, the module artifact

Everything in R-1 rests on this file. If it is wrong, separate compilation does
not work and the 95% prelude tax stays.

**The contract:** to compile module B which imports A, the compiler reads A's
`.iyimod` and never opens A's source. The prelude stops being 200k lines to
re-analyse and becomes a file to read.

### IV.1 Shape

One file per module, sections in a single container. Single-file because
replacement must be atomic. A half-written artifact that a later build treats
as valid is the worst failure mode a build cache has.

| Section | Contents |
|---|---|
| Header | magic, format version, compiler version, target triple, build flags |
| Hashes | interface / implementation / private (see IV.3) |
| Imports | DAG edges, each with the interface hash it was compiled against |
| Requires | under `--crystal`, the library files the module required (Part V item 12d) |
| Exports | types, signatures, traits, impls, constants |
| Macro bodies | serialised AST for exported macros and derives |
| Mono bodies | the bodies a consumer has to compile: source text, not IR yet |
| Initialiser | the module's own top-level code, as source text (IV.1g) |
| Object code | machine code for this module's own definitions |

Binary, for read speed. A `iyi mod dump` producing text is required, not
optional. An opaque cache format is one nobody can debug.

**The container is built, `Exports` carries the declarations, and a build can
be compiled against them.** `src/compiler/iyi/iyimod.cr` writes and reads
magic, format version, a section table and the `Header`, `Imports` and
`Exports` sections; `crystal build --emit-iyimod DIR` writes one per imported
module, `crystal mod dump FILE` prints it, and `crystal build --use-iyimod DIR`
compiles an `import` from the artifact instead of the module's source: see
IV.1f. `Exports` carries `pub def` signatures, exported type declarations with
their parameters, associated types and methods, and impl records with what they
answer, **each type's own fields, in the order they were declared**, and **the
defs and types a module does not export**, which travel unreachable because a
body that travels calls them (IV.1g). Layout
templates and type descriptors are not in it. Those are what codegen needs
rather than what the front end needs. **`MonoBodies` carries the bodies a
consumer has to compile itself, `Initialiser` the module's own top-level code,
`TypeIds` the types its object code numbers, `Constants` the names that code
reads, and `MacroBodies` the macros a travelling body expands** (IV.1g). Every
section the `Section` enum names is written now.

`SymbolLiterals` belongs to that rule too: a symbol is its index in the
program's table, a build numbers its symbols in the order it meets them, and a
unit that baked the producer's numbers in compared `:before` against the
consumer's number for something else. A unit reads a symbol's value from a
global the linking program defines, as it reads a type id, and the section
carries the names so the consumer can number one only the unit spells.

`Requires` is the newest and belongs to the same rule as `TypeIds`: a module
built with `--crystal` refers to Crystal's types by name, and only a program
that required the same library has those names to define. The header also
records *which* library a module was built against, and importing across the two
is refused — Part V item 12d is why both are there.

`MacroBodies` was the last one, and what put it there was a body that travels:
the consumer compiles a block-taking `run`, `run` writes `twice(n)`, and `twice`
is a macro of the module `run` came from. A macro has no machine code to arrive
as and no `pub` to be exported with, so it travels as source text on the two
things that can declare one. The module and a type, and arrives ahead of the
bodies that call it, because a macro is read before it is called. All of them
rather than a chosen few: none is reachable from outside, so they are there for
the bodies to expand against, exactly as the unexported defs beside them are
there to typecheck against.

Fields were meant to be in that second list and are not, which is worth saying
plainly because the reason is a bug rather than a change of mind. A consumer
does not need a field to typecheck a call, and it does need one to
**allocate** the receiver. Without them `pub struct List(T)` read back as a
struct with no fields, and the consumer generated a `List(Int32)::new` that
allocated nothing while the module's own object code wrote to `@items`. That is
memory corruption, standing behind a link error that happened to fire first.
The line between "what the front end needs" and "what codegen needs" is not
the line between what travels and what does not.

**`ObjectCode` now carries a module's own machine code**: see IV.1g for what
that turned out to mean, and for everything that turned out to be standing
behind it.

`std/list` reads back as:

```
imports
  std/enumerable
usings
  std/enumerable::{Enumerable}
exports
  struct List(T)
    def appended(item : T) : List(T)
    def at(index : Int32) : T
    def concatenated(other : List(T)) : List(T)
    def empty? : Bool
    def initialize(items : Array(T))
    def size : Int32
  impl Std::Enumerable::Enumerable for Std::List::List(T) forall T
    type Elem = T
    def each(& : (T -> Nil)) : Nil
```

**A signature is stored as the annotation the author wrote**, not as a
rendering of the inferred `Crystal::Type`. R-2 is what makes that sound,
everything exported carries full parameter and return types, so there is
nothing to infer, and it avoids inventing a second grammar for this file when
the consumer already has a parser for the first one. Where no annotation was
written it is recorded as absent rather than filled in: a constructor's result
is its type and nobody writes it down, and `def initialize(items : Array(T))`
above is that case rather than a missing one.

**Impl records had to be collected as they are declared**, not recovered
afterwards. An impl leaves no record of its own. It works by making the target
type include the trait, and once analysis is over that is indistinguishable
from any other ancestor. R-3 is what makes the collected set complete: an impl
may only live in the trait's module or the type's, so `std/traits` carries
`impl Comparable for Int32` and no third module could have carried it instead.

Because the section is still partial, **`mod dump` says so on every dump**. A
reader cannot tell an absent field list from an empty one, and taking a partial
surface for a complete one is the mistake this file cannot afford.

Two properties were built in from the start rather than retrofitted, because
neither can be added later without a format break. **Replacement is atomic**: a
sibling temporary is renamed over the target, so a reader sees the old file or
the new one and never a half-written one. The worst failure a cache has is the
one that looks fine. **Unknown sections are skipped**, which is what the table
is for: a consumer wanting `Exports` must not have to page in `ObjectCode` to
reach it, and forward compatibility falls out of the same property. Both are
covered in `spec/compiler/iyimod_spec.cr` rather than asserted here.

**Target, and what became of it:** reading the prelude's `.iyimod` was to cost
single-digit milliseconds against the **~1.0 s** its top-level analysis cost
when that was written. Item 3 took the analysis to 0.010 s by deleting 107,719
lines of prelude, and IV.1a's re-measurement then took the target away: reading
an artifact is parsing text and running the top-level pass over it, which is
what reading the source was. The prelude is not made into an artifact, and the
reason is a measurement rather than a preference.

### IV.1f Reading the artifact instead of the source

`crystal build --use-iyimod DIR` resolves `import a/b` to `DIR/a/b.iyimod`
where it would have opened `a/b.iyi`, and **does not open the source**. Not
"prefers the artifact": the file need not exist. Seven of the eight samples
compile with the imported module's source deleted, `immutable.iyi` among them,
a generic type, a 575-line trait with an associated type, and a generic impl
that answers it.

**The artifact is rendered back to declarations and those are parsed.**
`crystal mod dump --declarations` prints exactly the text the compiler reads,
which for `std/list` is its `module`, its `import`, its `using`, `pub struct
List(T)` with six headers and no bodies, and the impl with its `type Elem = T`.
Text rather than a serialised AST because the signatures already are text: the
parser that read the module is the one that should read its declarations back,
and a second grammar for this file would be a second thing to keep correct. A
diagnostic that points into a `.iyimod` names a line of that output, which is
why it is printable.

**A call to a def from an artifact is typed from its return annotation.** There
is no body to visit and there is not meant to be one: R-2 guarantees the
annotation is written, and IV.2 keeps the body out. That is the whole of what
the front end gets, and it is also the boundary: a module read this way
contributes an **initialiser only because one now travels** in a section of its
own (IV.1g). Its top-level code is not a declaration, so `Exports` was never
going to hold it. What is still left behind is code inside a *type* body, and a
build that would generate code against a module with one is refused rather than
given a program that runs with the setup missing. IV.1a said the same thing
from the other direction,
codegen needs the prelude's tree for reasons caching analysis does not remove.

**Three things had to travel that the format did not carry**, each found by a
real module rather than by reading:

1. **The rest of the `def` line.** The block annotation, `forall`, `abstract`,
   the receiver, and a parameter kept whole so its default value survives.
   `Enumerable`'s `map(& : Elem -> U) : Array(U) forall U` needs three of the
   five in one signature.
2. **An impl's own methods.** They are the impl's, not the target's:
   `impl Comparable for Int32` puts `<=>` on a prelude type this module does not
   export, so recording it against the target loses it. This is also why
   `each` appears under the impl in the dump above and not under `List`.
3. **The module's `using` directives.** A signature is stored as the annotation
   the author wrote, and an annotation is written in a context: `pub def
   handle(ctx : Context)` resolves `Context` through a `using` further up the
   file. `std/list` never noticed, because its signatures name only its own
   types; the Kemal port's first exported signature does not. Carrying the
   annotation without what resolves it was carrying half of it.

**Measured**, best of 7 runs, `immutable.iyi`, top-level pass only:

| | top level |
|---|---|
| prelude alone (empty program) | 0.886 s |
| + `std` from source (722 lines) | 0.901 s |
| + `std` from its `.iyimod` | 0.884 s |

The 722 lines cost 15.5 ms from source and nothing measurable from their
artifacts, so on the modules it is applied to the mechanism delivers what it
promises. It is also invisible, because 0.886 s of prelude is next to it. That
is the 95% prelude tax stated as a measurement rather than as an argument, and
it is why item 3 of the 0.1.0 list. A prelude small enough to be one of these
modules: is what decides the schedule and not this section.

**And a module path can come to mean a different file.** A path is a file's
path (R-1) and it is resolved from the entry's own directory first and from
`IYI_PATH` after, so a program that writes `std/text.iyi` of its own has that
file while it exists and the library's `std/text` after it is deleted — the
same name, two files, and only one of them is the one an artifact was written
from. The artifact is refused, which is right: its surface is not the surface
at that path. What was wrong is what it said. The reader compared the two
source *hashes* and reported "`src/std/text.iyi` has changed since it was
written", naming a library file the author has never opened and sending them
to look for an edit nobody made. The artifact records the path it was written
from, so the two paths are compared first and the sentence is the fact:
`"std/text" is <the library's file> now, and this was written from <the
program's>`. The name a program gives a module is therefore worth choosing
against what `src/std/` already ships, and that is a naming consequence of
R-1 rather than a rule of its own: nothing is reserved, and whichever file
the search order reaches is what the name means.

**And where nobody says, the workspace's own `mods` is read after its
sources.** `--use-iyimod DIR` is how a *build* is told, and its contract is
the paragraph above: the artifact first, the source not opened. That leaves
every other way of asking with no way to reach one, and a library arrives as
`.iyimod` files with no source at all (III.7) — so the workspace R-1 exists
for was `can't find module 'app/base'` under `iyi build`, `iyi run`, `iyi
test`, `iyi check`, `iyi doc`, `iyi mod context` and the language server,
about a module `--use-iyimod` compiles fine against. A verb has no flag to be
told with, and a person typing `iyi test` is not saying how their dependency
arrived.

The rule is one name and one order:

* **`mods` beside the project root** — the root R-1's own reading names (a
  file whose path ends with its `module` header's path names the root above
  both), and the name every example in this file, the README and every bench
  already writes. Not a setting: the alternative to one name is a setting
  every editor has to be told and no agent knows.
* **After the sources.** A module with a file is compiled from it, and the
  artifact is reached for one whose file is not there. Two things follow, and
  both are why the order is this way round rather than the build flag's.
  A workspace with its sources present compiles exactly as it did before the
  rule existed — including the common case of a `mods` left over from an
  earlier `--emit-iyimod` run beside a source since edited, which artifact
  first would refuse as stale (IV.3) about a file the author is looking at.
  And an editor answers about code somebody is looking at, so
  go-to-definition lands in the file rather than in a rendered declaration.

`--use-iyimod` still says what it always said, and a build told it is
unchanged. `bench/mod_context.sh` gates the verbs and the left-over-artifact
case, `bench/lsp_artifacts.py` asks the server the same questions in both
workspaces, and `bench/daemon_agrees.py` compares a daemon-served build with
a plain one — the daemon forks a child per build, so a switch that reaches an
adopted program is a switch that can go missing from one.

### IV.1g `ObjectCode`. The module's own machine code

**The unit is the object file, because codegen already splits that way.** Every
method is emitted into the LLVM module of the type that owns it, one object
file per type, and the split is a **partition**: on the Kemal port, 23 units
and no symbol defined by two of them. So "this module's own definitions" is a
set of whole object files rather than a filter inside one, and carrying them is
copying bytes rather than teaching codegen a second way to lay out a program.

A module's units are the module type itself, where its own `pub def`s are
owned: plus every non-generic type declared under it, recursively.
`kemal/router` owns five (`Router`, its three nested records, `Context`) and
`kemal/dsl` one. `app/greeter`'s artifact comes out at 3,177 bytes, of which
2,736 are an ELF object defining `polite`.

**A generic type's instantiations are deliberately not among them**, and
carrying them was tried first because it looks obviously right. `--emit-iyimod`
runs inside an ordinary build, so the producer's instantiations *are* the
consumer's, and `List(Int32)`'s unit appeared to belong in `std/list`'s
artifact. It does not: `List(Int32)::new` is **synthesized** from `initialize`
rather than read from the artifact, so the consumer generates its own copy and
the link fails on a duplicate symbol. The deeper reason is that the appearance
depends on the two builds being one build, which is the arrangement this file
exists to end, which instantiations exist is decided by whoever writes
`List(Int32)`. They are `MonoBodies`' business (IV.2).

**Two properties had to hold for this to be possible at all, and both were
checked rather than assumed.**

*Symbol names carry nothing build-specific.* A method's symbol is its owner
type, its name, its argument types and its return type, escaped: no counter,
no path, no hash of the build. Two builds that agree on the types agree on the
name, which is what lets one build's object file be linked by another's.

*A type id is already an external reference.* Type ids are integers assigned by
a global pass, so a module compiled alone cannot know its own. The obvious
reading is that separate compilation is therefore impossible without a format
that carries them. It is wrong: the router's unit lists `Kemal::Router::Router:
type_id` among its **undefined** symbols. The number is resolved by the linker
from a definition in `_main`, not baked into the code. Whoever assigns the ids
defines the symbols, and everything else relocates against them.

**And a program built from an artifact runs.** `--use-iyimod` no longer implies
`--no-codegen`. A def read from a `.iyimod` is *declared* rather than defined,
the same shape a `lib` function takes, and for the same reason: the body is
somebody else's. The artifact's object files are unpacked into the build's
own output directory, and the linker joins the two.

```
crystal build --emit-iyimod mods -o from-source main.iyi   # 42
rm app/twice.iyi
crystal build --use-iyimod  mods -o from-artifact main.iyi # 42
```

That is the first thing in this document that produces a program rather than a
typecheck, and `spec/compiler/iyimod_spec.cr` runs both binaries and compares
what they print.

**Two bugs it found, both of the kind that would have linked and lied.**

*A def read from an artifact must not be inlined.* Its body is absent, which
reads to codegen as the simplest possible body: `Nop` is the first case
`try_inline_call` matches, so a call to the module's code was being replaced
by nothing at all. It did not link, because an absent body also has no type;
had it, the program would have run and computed the wrong answer.

*`type?` is not `@type`.* `ASTNode#type?` answers `@type || freeze_type`, so a
def whose return annotation has been resolved reads as typed while `@type` is
still nil, and `Def#mangled_name` reads `@type`. Setting the type only `unless
type?` therefore left the front end correct and handed codegen a symbol with no
return type on the end, which is not the symbol the artifact defines. The
linker caught it. Nothing else would have.

**Three more things had to travel, each found by the linker on `modules.iyi`**,
build it, delete `app/greeter.iyi` and `app/formal.iyi`, build again from the
artifacts. Four undefined symbols, then two, then none.

*A method inlined away has no symbol to carry.* `title` returns a string
literal, so every call site inlined it and the producing build emitted no
function, but the consumer has no body to inline and calls it by name. Two of
the four. A build writing an artifact therefore stops inlining the methods that
artifact describes: code somebody else will call by name has to be defined. The
check asks the *instance* type, because a module-level `def` is owned by the
module's metaclass, which is most of what a module exports.

*A module carries private copies of what it calls.* `String::interpolation
<String, String, String>` is in the prelude's `String` unit, and the consumer's
own `String` unit holds whatever *the consumer* instantiated, which need not
include it. Carrying the producer's whole `String` unit is not an option: it
would define symbols the consumer also defines, and the linker refuses that,
and sub-unit granularity cannot be had by copying bytes. So the callee is
copied into the module's own unit with **internal linkage**, transitively.

The alternative was `linkonce_odr` on Crystal's functions, so duplicates merge
at link. What C++ and Rust do with template instantiations, and sound here
because the header already asserts the same compiler, triple and flags. It was
rejected for reach: it changes codegen for **every** build in this fork to fix
a problem that belongs to artifacts. The price of the private copy is
duplication. Each module carries its own `String::interpolation`, and one
consequence worth knowing, that a proc taken to such a function has a different
address on each side of the boundary. A C function is never copied: it is a
declaration with no body whoever asks, and internal linkage on a declaration is
invalid IR, which `write` and `exit` reach from the prelude's own `puts`.

*And a program that links an artifact defines every type id.* The copy above
brought its own undefined symbol: `String:type_id`, which the same program
built from source resolves without trouble. Type-id globals are emitted on
demand, so they exist only where *this* program wanted one, and a build cannot
see from an object file which ones that object needs. It therefore defines them
all. An `i32` per type is not a cost worth a cleverer answer, and the artifact
must keep carrying a reference rather than a value: two programs number their
types differently.

*"All" is every type it has **numbered**, and that is not every type it has.*
Ids are handed out by walking `Object`'s subclasses, and the walk reaches a
class — not an enum and not a module. Both take an id from the first code that
asks for one, so a consumer whose own code never mentions
`Regex::MatchOptions` or `Backtracer::Backtrace::Parser` numbers them nowhere
and defines no global, while a unit it links refers to one. `TypeIds` carries
those beside the generic instances it already carried, and the two kinds are
missing for opposite reasons: an instantiation does not exist in the consumer
until it is named, an enum or a module exists and is unnumbered until it is
asked for.

**Some bodies have to travel, and `MonoBodies` is which ones.** A module's
machine code answers for a method the producer could compile. Two kinds it
cannot, and they are the two exceptions IV.2 already names:

- **A generic type's methods.** `List(Int32)#size` exists once per
  instantiation and the instantiations belong to whoever writes them. A
  consumer that writes `List(Float64)` needs a method the producer never made.
- **A trait's default methods.** `to_a` is stencilled onto the implementing
  type, and the implementing type may be the *consumer's*. There is no name
  `Samples::Collections::Nums@Std::Enumerable::Enumerable#to_a` could have been
  compiled under in the producing build, because `Nums` did not exist in it.

Both ship their bodies as **source text**, rendered back into the declarations
a consumer parses. IV.1's table asks for serialised typed IR, which is faster
and is a second grammar to keep correct; text is the choice `Exports` already
made, for the reason IV.1f gives, and IR can replace it without changing what
travels.

**A module is a mixin on the other side of a `--crystal` boundary.** iyi's
module header desugars to `extend self`, because in iyi a module is a
compilation unit and not a mixin: its functions belong to the module itself.
A boundary's declarations are read under that header, and a `--crystal`
boundary reopens a module of the *other* language — where a module is a mixin,
and says which is which in its own words: a module function is written `def
self.`, an instance method is not.

Extending it anyway put the module into its own metaclass. `module Random` has
`abstract def next_u` for its includers to answer, and its metaclass answers
nothing: `abstract def Random#next_u() must be implemented by Random:Module`,
on a program whose only line was `import random`. Plain Crystal refuses
`extend self` beside an `abstract def` for the same reason, so this was never
a question about boundaries — it was iyi's header meaning one thing and the
module meaning another.

So the header supplies it no longer and the artifact carries it, which is where
it belongs: whether a module extends itself is a fact about the module. Two
things had been leaning on the header without saying so. The constant accessors
`tool bind` synthesises are module functions and nothing else said which side
of the type they were on — written plain they became instance methods and the
link ended on `*Kemal::config_instance:Kemal::Config`; they are `def self.` now
on both sides. And the `extend self` line has to be written *after* the
requires, because the parser lifts a leading run of `import` and `require` out
of the module and stops at the first line that is neither — above them, every
require stayed inside the module, which is the fault `parse_module_header`'s
own comment describes.

**A module's own instance method travels as a body.** IV.1g lists a module's
methods among the ones with no single symbol to key on, because each is
compiled once per *including* type. The producer emits one only for the
including types its own code instantiated: `db` has
`*DB::Connection+@DB::Disposable#close` and two more because `db`'s code
closes all three of its `Disposable`s, and a module whose includers the shard
never uses has none. `module Gen` with a `def next_pair` and a `class Fixed`
that includes it linked on nothing —
`*Gen::Fixed@Gen#next_pair:Tuple(UInt32, UInt32)`, undefined.

The keep file is the other half of the same fact. These methods are declared
as the module's, and an iyi module header is `extend self`, so a consumer reads
them on the module *and* on whatever includes it. That is what an including
type needs and it is not a claim about the shard: `module Random` writes `def
new_seed` without `self.`, and `Random` answers to no such name. Called in the
keep file — which is compiled against the shard's own source — it stopped the
fill build on `undefined method 'new_seed' for Random:Module`. So the keep call
is skipped where the module does not extend itself, and nothing is lost by
skipping it, because there was no symbol to keep alive.

**A module used as a value has no name a declaration can write.**
`Random::Secure` is `module Secure; extend self; include Random; end` — a
module that is also a value — and `Random#split` answers `(Random::PCG32 |
Random::Secure:Module)`. The nameability scan reads a printed type as a list of
names, found `Secure` and `Module` and called both nameable, and wrote the
whole thing down; the consumer's parser stopped on `expecting token ')', not
'Module'`. The test is for one colon and not two, because `Foo::Module` is a
type somebody could declare.

**A constant has two spellings, and which one a build picks is a fact about
that build.** A constant read before it is initialised is reached through
`~NAME:const_read`, a function in the main module that runs the initialiser
once; one initialised before anything read it is a plain global.
`initialize_const` chooses on `const.read?` at the moment initialisation is
emitted, so the answer depends on the order that build happened to take.

Across a boundary the two builds do not agree. The producer's units read these
constants, so it emitted the function; the consumer initialises them from its
own program, in its own order, and emits the global. The artifact's object code
then calls a function nobody wrote — `undefined symbol:
~Iterator::Stop::INSTANCE:const_read`, referenced from `Path`'s `PartIterator`
unit, in a program whose own source names no iterator. `Time::Span::ZERO` is
the same thing one namespace over.

So the consumer defines the missing spelling for every name in `Constants`,
beside the type ids and the match funs it already defines for the same reason:
each is a name an artifact's object code calls that only the consumer can
build. The global is defined either way, so a unit referring to that instead
still links, and the function initialises only where this build's own answer
says to — one already initialised eagerly would otherwise re-run its
initialiser on every read.

Forcing the flag from the front end instead is wrong twice over, and both are
written down because both were measured. A `pointerof` is what
`needs_init_flag?` already answers to, but it initialises nothing — read that
way, `kemal/dsl`'s `APP` arrived with its routes unregistered. Kept beside a
real read, the changed initialisation order closed `STDERR` before
`bench/bind_chain.sh`'s program had written to it.

**A module's instance method is not a module function.** A module written
`extend self` puts its own methods on its metaclass as well, which is what
lets `Kemal.run` be a module function and what an iyi module header desugars
to. A module that does not write it does no such thing: `module Random` writes
`def new_seed` without `self.` — an instance method its includers get, and not
a name `Random` answers to. Collected as a module function it produced
`Random.new_seed` in the keep file, and the fill build stopped on `undefined
method 'new_seed' for Random:Module`. The question is asked of the metaclass,
which either has the module among its ancestors or does not; an instance
method that stays behind is not lost, because it travels as the module's
`TypeDecl`'s.

**A travelling body is compiled twice, and the two are not the same
function.** The producer compiles it too — its own code calls it — but the
producer compiles it against *declarations*, and where the body calls an
`abstract def` the producer's world may hold nothing that answers it. `db`
alone has no driver, so what `db`'s artifact carries for
`Connection#fetch_or_build_prepared_statement` is a function whose `else`
branch returns its own argument. The consumer compiles the same body against
`SQLite3::Connection` and gets the right one.

Both wore the same name. The consumer's copy is private to the unit that holds
it and the producer's is global, so every call the consumer wrote bound to the
producer's: `DB.open` handed back a statement whose `crystal_type_id` was 1,
and `.class` on it hit the trap at the end of a dispatch nothing matched. What
that reads like from the outside is `Invalid memory access` in
`SQLite3::Statement#perform_exec`, three frames past the cause.

The consumer's copy carries a suffix, so a name that means two different things
is two symbols. The producer's stays global rather than being hidden: `db`'s
own object code calls it by name, and so does `sqlite3`'s — `Statement#do_close`
calls `super` into `db`'s — and hiding it broke the link instead. Two copies of
a body is the price of a boundary that lets each side compile what it can see.

**An `abstract def` is a requirement, and a requirement is not a header.** Two
readings of the same shape went wrong in opposite directions, and both were
`db`.

Writing it out, `Def#body` for an abstract def is the empty string, which is
truthy: the generic collector read the requirement as a concrete method with an
empty body — one that answers `nil` — and wrote it down as an implementation.
`required` is the field that says otherwise and it was not being set there.

Reading it back, a declaration from an artifact has a `Nop` body and is typed
from its return annotation; that is what makes a boundary cheap, and an
`abstract def` looks exactly like one. It is the opposite: no code answers
*it*. Taking the header path typed the call and emitted none, and the caller
read whatever the stack held.

**A written return type is a restriction, and a travelling body keeps it.** A
body that travels is read for what it returns, so three places wrote the return
as empty wherever the body answers. That is true and it is not a reason to drop
what the shard wrote. Crystal narrows a written return to what the body
produced, exactly as it does for the shard, and dropping it made `sqlite3`
refuse its own override: *this method overrides ... which has an explicit
return type of Stmt*. A requirement's return type is inherited by whatever
answers it, for the same reason its parameter types are.

**An impl is the third case, and it is the one that fixes the rule.** An impl
defines methods *on its target*, so they are emitted into the target's unit,
and the artifact carries a unit only for a non-generic type the module
declares. `impl Comparable for Int32` in `std/traits` therefore puts `<=>` in the
*prelude's* `Int32` unit, which no artifact can carry without defining every
other `Int32` method the consumer also defines. So an impl's bodies travel
**unless** its target is a non-generic type this module declares, and the
"unless" is not caution. Shipping them always makes the consumer compile a
method the artifact's object code already defines, which is a duplicate symbol.

**Two duplicates found by that boundary, both about a method nobody wrote.**
`Greeter::new` is synthesized from `initialize` rather than read from an
artifact, so nothing marked it as coming from one: the producer emitted it into
`Greeter`'s unit and the consumer synthesized its own. The types an artifact
declares are now marked, and codegen declares their methods rather than
defining any. The artifact is authoritative for a type whose object code it
carries. The mark is on the declared type and not on its instantiations, which
is the distinction that makes it work: `List(T)` is the artifact's, and
`List(Int32)` is compiled here like any other type.

**And the artifact's declarations join the tree.** They were being parsed,
accepted and thrown away, which is enough for name lookup and no more: an
instance variable's type is settled by `TypeDeclarationVisitor`, a separate
pass over the tree. So `@items : Array(T)` read from an artifact was a
declaration the compiler had parsed, accepted, and could not see: "can't infer
the type of instance variable `@items`" on the line that assigns it. A file of
declarations still contributes no initialiser, because there is nothing in it
to run; that is a property of the content, not of how it is plumbed.

**And the module's initialiser travels too.** It is the one part of a module
that is neither a declaration nor the body of one, and III.5 is entirely about
it: it has to *run*, in DAG order, before anything that imports the module.
Nothing else can produce it. A consumer that never opens the source cannot
invent the module's constants, its proc literals, or the statements between
them. So it goes in a section of its own, as source text, rendered back inside
the module's own namespace; the consumer parses it and it takes its place in
the import order like any module read from source, because that order is over
modules and not over text. `init_order.iyi`, whose whole subject is that
ordering, and one of whose `import`s sits below a statement of its own: prints
the same five lines in the same order from its artifacts as from source.

The section is not in IV.1's table. The table had a row for declarations and a
row for bodies of declarations and no row for this, which is the gap rather
than an addition: a module is not only what it declares.

**What still does not travel is code inside a *type* body**. A class
variable's initialiser, which belongs to the type rather than to the module's
top level. `has_initialiser` now means exactly that, and a build that would
generate code against such a module is refused, naming the module and why. The
distinction is worth the precision: the flag used to mean "has anything to run"
and refused three modules that were fine.

**Two things the samples do not have, found by writing an example that did.**
A module exporting a type with a class method and a field is an ordinary shape
and no sample happens to be one, so both of these survived every sweep above.

*A class method lives on the metaclass.* `def self.zero` is stored there rather
than on the type, so walking a type's own defs dropped every class method a
module exported: `Counter.zero` was an undefined method on the far side of an
artifact that looked complete. Both sides now travel, told apart by the
signature's receiver, which is a thing the format already carried and nothing
had used. Two methods are kept out on the way: `new`, which is synthesized from
`initialize` and which the consumer therefore makes for itself, and anything
whose body is a `Primitive`: `allocate` is put on every metaclass by the
compiler, and describing it as part of a module's surface would be describing
this compiler instead.

*A field with a bodyless `initialize` reads as nilable.* The artifact's
`initialize` is a header, so nothing in it assigns `@n`, so the check that
looks for an `initialize` leaving an instance variable unassigned refused the
module outright. It is treated like a macro def now: assumed to assign
everything, because the build that wrote the artifact already checked that the
real one does.

**Where that leaves the eight samples.** Five import a module at all; the other
three (`hello`, `generics`, `errors`) are single files and exercise nothing
here.

| sample | from its artifacts, source deleted |
|---|---|
| `modules` | **builds, links, runs, identical output** |
| `immutable` | **the same**: a generic type, a 575-line trait, a generic impl |
| `collections` | **the same**: the consumer's own type implementing the trait |
| `init_order` | **the same**, including III.5's ordering, line for line |
| `webapp` | **the same**: the Kemal port, blocks and all |

**All five run.** `webapp`. The Kemal port: used to stop at `--emit-iyimod`, because
R-2 refuses an exported `def` that does not describe its block and
`Router#namespace` took `&` with `with sub_router yield` inside it. The port now
passes the sub-router as a block parameter: `& : Router -> Nil`, and its caller
writes `|admin|`. That is the rule costing something visible and being paid
rather than avoided. A `namespace` that keeps `with` would have to stay
unexported, which is a worse trade for a DSL than one extra parameter. Giving
`with … yield` a notation stays open (IV.2); this is what an exported
block-taking method looks like until it has one.

**And behind that one were two more, both the same shape as everything else
here: a module's object code referring to something the artifact does not
carry.** Neither is about blocks.

*A module's constants*: **fixed.** `kemal/dsl` writes `APP = Router.new`, and
its unit calls through `Kemal::Dsl::APP` from every exported `get`, `post` and
`mount`. The initialiser travels as source text and the consumer runs it, but
the *symbol* did not: a constant is typed and initialised where it is **read**,
the only reader on this side is machine code the consumer did not compile, and
nothing defined it. Six undefined references on a module of forty lines.

The names now travel in a `Constants` section and the consumer reads them on the
module's behalf. The paths are appended to the declarations before they are
analysed. Marking them used was tried first and is not enough: without a read
the constant's value has no type, and the next pass says it cannot infer one.
Reading costs one load in the consuming program and puts the constant back on
the ordinary path, where initialisation stays lazy and stays in III.5's order,
because reading a constant is what initialises it.

*A module's proc literals*: **fixed, and not by carrying a list.** `add_route`
builds `->(ctx : Context) { block.call(ctx).into_body }`, and the symbol for it
is named after the file and line it was written on,
`~procProc(Context, String)@kemal/router.iyi:211`. A proc literal is emitted
into `_main`, so the router's unit referred to a definition in a module the
artifact does not carry; and a name with a source location in it is one the
consumer could not have reproduced either, since its declarations arrive under
another filename. So the definition goes where the code that made it goes:
while a unit that will travel is being emitted, its proc literals are emitted
into that unit, private to it. Same answer, and the same reason, as the callees
the closure already copies.

**And behind that, the rule this section has been circling.** With the procs in
place the port fails twice more, and both are one thing: a method that takes a
block is instantiated *with the caller's block inlined into it*,
`Kemal::Dsl::before_all<&Proc(Context, Nil)>`. The producing build made those
instantiations because `webapp.iyi` called them, so they are in the unit the
artifact carries; the consuming build makes its own, because the block is its
own code. One is a duplicate symbol and the other: `Router#namespace` with a
block the producer never wrote: is an undefined one, and they are the same
mistake seen from either side.

So a block-taking method belongs with a generic type's methods and a trait's
defaults in IV.2's list: **its body has to travel and its machine code must
not**. `iyi_bodies_travel?` asked that question of a *type*, and this is the
case that makes it a question about a `def` as well: whatever the def is
written on, a module's own `pub def` and a method of an exported class alike.
**Built.** The producer emits each instantiation into the unit that called it,
private to that unit, so no symbol for one leaves the artifact; the body travels
in `MonoBodies`; and the consumer compiles its own from the block it wrote.

**Built on one side of the boundary and not the other, which a round trip
found.** The paragraph above says the question is about a `def` and not about a
type. `crystal tool bind` was answering it about a type: only a *generic*
type's methods carried their bodies, so an ordinary class's block-taking method
crossed as a declaration with nothing behind it. The machine code stayed
private to the producer, as designed, and the consumer asked for a symbol
nobody had emitted — `undefined symbol: *Shard::Part#each<&Proc(Int32, Nil)>`,
at the end of a build with no other complaint.

Nothing here was wrong except where it was applied. A block-taking method now
carries its body wherever it is written, the same way a generic's methods
already did, and both shapes round-trip: one that `yield`s and one that
captures its block as a `Proc`. The first guess at the cause was that `yield`
is inlined and a captured block is not, which would have made this a narrower
bug than it is; a captured block fails identically, so the rule is the block
and not the `yield`. Both are in
`bench/bind_roundtrip.sh`. The surface does not move: `JSON` 180 signatures,
`YAML` 193, `URI` 55, before and after.

**And the other half of a block, which is reading what such a method returns.**
`infer_return` instantiates a method on purpose and it did that with no block,
so a method that takes one was answered `wrong number of arguments` by its own
overload set — `JSON::Builder#string`, whose sibling takes a value. Its return
type was the last thing on this boundary standing on the shard's word, over a
block whose annotation described it in full.

The call carries a `Block` of the annotated shape now, which is the same block
the keep file has written as text since blocks first crossed, and a
`parent_visitor`, because a block's body is code and code is visited. With
both, **III.6 rule 1's residual over the crossing surface is zero**: `URI` 0 of
55, `JSON` 0 of 181, `YAML` 0 of 194. It moves the untyped half as well — 64
return types read in `JSON` that the tool had refused, and 81 in `YAML`.

One caution the same run produced, because it looked like a third defect and
was not. `YAML::Any#to_json_object_key` names `JSON::Error` in its body, and
the probe it was measured against required only `yaml`; the tool refused
correctly and the input was short. What a boundary is measured *with* is part
of the measurement — `YAML` reads 194 signatures with both libraries required
and 193 with one.

**And behind that one, three more**: each of them invisible until a consumer
started compiling a body against a type it had only ever imported.

*The aliases a declaration names*: **carried.** `Router` writes `alias Handler
= Context -> String`, and the private records that travel take a `handler :
Handler`. The text travels, so the name has to resolve on the far side, and it
did not: an alias has neither a layout nor an id, which is the reason it was
left out, and the reason it travels anyway is the other one a declaration does,
something else's text names it. It arrives as what it resolved to rather than as
what was written, on the same grounds as a field's type: the name resolved where
the module was read from source, and this file is read somewhere else.

*Whose machine code a def is*: **a question about the def, and not only about
the type.** Codegen asked whether `self_type` came from an artifact and, if it
did, emitted a signature with nothing under it. That is right for every method
that arrived as a header and wrong for the two things that did not: the def
whose body travelled, and a proc literal written inside that body. `add_route`
builds one, and its `self` is the artifact's type while its code has never been
anywhere but here.

*A field's offset is its position in the list*: **so the list travels in
declaration order.** The fields were sorted by name, for a good reason: a hash's
order is not a fact about a type, and an artifact that changed between two
identical builds would defeat IV.3. But the order *is* the layout, and sorting
it was wrong in a way nothing could see for as long as everything a consumer
compiled kept its hands off an imported type's fields. A travelled body is the
first thing that does not: the consumer's `add_route` wrote `@routes` at the
offset the module's own code reads `@filters` from. Every route went somewhere
nobody looked: `app.routes` came back empty, and then the program segfaulted.
Declaration order is no less deterministic than sorted order, because
`instance_vars` is insertion-ordered and the insertions are the declarations.

**And one the samples do not reach, found by asking what the rule leaves open:
the block-taking def a module does not export.** `pub def run` takes a block, so
the consumer compiles it, and `run` calls a `helper` the module kept to itself,
or a method on a type it never exported. Being unreachable changes nothing about
who the caller is, so those bodies have to travel too, and a header for one
would promise a symbol nobody emitted: the producer makes no machine code for a
block-taking def wherever it is written. They travel in a list of their own and
are rendered without `pub`, which is what keeps R-2b true. A consumer that
names one is refused with the message it gets from source, having had the
declaration all along. The same sentence covers both namespaces: the method on
a carried type, and the def at the module's own top level.

Both belong to IV.1g's rule rather than beside it: "a module's own code is the
object files named after the types it declares" is what makes them missing, and
what makes the type ids above missing was the same sentence.

**And one thing none of the five reaches, which was expected to be a missing
object file and turned out to be a missing number.** A module's body
instantiates prelude generics at its own types. The router's builds an
`Array(Kemal::Router::Router::RouteDefinition)`, and that unit is named after
`Array`, not after anything the module declares, so the ownership rule does not
catch it. It does not have to: the closure above already copies a callee the
emitting module does not own into the module's own unit, and a generic's
instantiated methods are callees like any other. What the copy leaves behind is
the **type id** it refers to. `Array(Item):type_id` is resolved from a
definition in the consuming program, a program defines an id for every type it
*has*, and `Array(Item)` is not among them: it exists in the producing build
because of a body that stays behind, and nothing in the declarations a consumer
reads would ever make it. Four undefined symbols on a module of nineteen lines,
in a program whose every method resolved.

So the artifact carries the **names** of the types its object code numbers, and
the consumer instantiates them on `import`. Names rather than numbers, for the
reason the section exists at all. Two programs number their types differently.
Only generic instances travel: everything else a module's code can name is
either declared by this artifact or imported by the consumer for itself, and an
instantiation is the one case with no declaration anywhere to arrive through.
The type has to be *numbered*, not used, so making it is enough.

**Which made a module's unexported types travel too**: the router's
`RouteDefinition` is a `private record`, so `Array(Router::RouteDefinition)`
named something the artifact did not have. A type nobody may call arrives as
its name, its kind, its fields and its nesting, and **no methods**: the
consumer cannot reach them and the module's object code already defines them,
and carrying them would put R-2's block rule. A rule about what another module
reads: in front of a private method's unannotated block. The visibility
travels as it was written, which is what keeps R-2b true on the far side: the
type is declared by the consumer and reachable from nowhere, exactly as it is
when the module is read from source, and a consumer that names it is refused
with the same message either way.

Nesting travels because iyi cannot reopen a class to add a type to it later,
and a type declared in a class belongs to the class rather than to the module's
surface: R-2 governs the unit's own body. Two things follow from a private
type being *written down*. The declarations name it: `@routes :
Array(Router::Route)`, and a path in that text may reach it where a path in
anybody's source may not, which is a mark on the path rather than a hole in the
rule. And it arrives with fields and no `initialize` to assign them in, so it
is assumed to assign everything, on the same grounds as a bodyless `initialize`
above: the build that wrote the artifact already checked the real one.

What is left is an instantiation at somebody *else's* unexported type, which
neither module can name. The consumer refuses the `import`, naming the module
and the type, rather than leaving it to a linker that would report a mangled
symbol and no module at all.

Underneath all of it stays the fact that **an artifact carries what the
consuming build reached**, rather than the module's surface. Codegen is
demand-driven and `--emit-iyimod` lives inside an ordinary build. A module
compiled on its own would instantiate every exported def at the signature R-2
makes it write down, and compiling a module on its own is the command that
cannot precede the artifact it produces.

**Deciding "does this module have an initialiser" was wrong three times**, and
each was the kind of mistake a spec cannot find by reasoning. The same class
IV.6 records. The test walks a module's top level and calls anything it does not
recognise as a declaration an initialiser, which is the safe direction: a
refusal explains itself and a missing setup does not. What it did not recognise:
the file is already wrapped in a `ModuleDef`, because `apply_module_header`
turns `module a/b` into one, so **every** module answered "no initialiser" and
the flag was written and always false. Then `pub struct List(T)` is a
`VisibilityModifier` around the declaration, not a declaration, which refused
three samples that were fine. Then `type Elem = T` is an `AssocTypeDecl`, which
refused the two that have associated types. Each looked like the last bug and
was a different one.

**And a fourth, which is where the safe direction stopped being safe.** A macro
call is not a declaration, so `getter name : String` in a type body read as code
that has to run and refused the module, and so did `private record Route, …`,
which is how the router writes its three. That is not a corner: `getter` is the
shape of every library anybody would write, so the conservative answer was wrong
on the ordinary case. A macro call is not code *until it is expanded*, and by
the time this test runs the top-level pass has expanded it, so the question can
be asked of the expansion instead of the call. A `getter` is a `def` and a
`record` is a struct, and both are declarations. The other direction is what
makes that safe rather than merely convenient: a macro that expands to `puts` in
a type body is still code in a type body, and the module is still refused. A
call with no expansion is what it looks like, and is refused too.

**A reader that does not want it does not pay for it.** `ObjectCode` is the
largest section in the file and is written last; `IyiMod.read` seeks past it
unless asked, so `import`. The front-end reader this whole file exists to make
fast: never allocates it. A `--no-codegen` build omits the section entirely
rather than writing it empty, and can still typecheck against a module whose
initialiser rules out generating code.

### IV.1a What the artifact actually buys: measured

The prelude fork probe (`IYI_FORK_PROBE=1`, temporary instrumentation) analyses
the prelude, forks, and compiles the user program in the child. Restoring the
prelude then costs a `fork`, which is the ceiling no serialised artifact can
beat. Front end only; 5 runs, median; single-threaded compiler build.

| Program | Front end today | Artifact (top level cached) | + prelude-aware passes |
|---|---|---|---|
| `hello.iyi` | 1.58 s | 0.47 s (3.4× | 0.049 s) 32×† |
| `webapp.iyi` (the Kemal port) | 1.54 s | 0.45 s (3.4× |) |
| 19.5k lines, 1500 types, 4500 methods | 2.39 s | 1.39 s (1.7× | 0.94 s) 2.6×† |
| prelude-free floor (`--prelude=empty`) | 0.09 s | (|) |

† Read IV.1e before quoting these. The third column measures a prelude analysed
all the way through `main`, which is more than Part IV's artifact carries and
which fails on any program that subclasses a prelude type. The number is a
ceiling on a configuration that does not work, not a target.

**The third column is reachable, and it was verified past the front end.** The
probe can go on to emit object code (`IYI_FORK_CODEGEN=1`). Under both models the
emitted object has a **byte-identical symbol table** to a normal build's: 3741
symbols, same size, differing only in 0.1% of bytes. So a front end that never
looks at the prelude produces the same program.

Getting there took one wrong turn worth recording, because it is the kind of
mistake this design invites. The first attempt handed codegen only the *user*
tree and failed with:

```
Missing __crystal_raise_overflow function
```

The tempting reading is that `main` is demand-driven and a prelude analysed
alone never instantiates what only user code reaches. That reading is wrong.
`__crystal_raise_overflow` is a `fun` in `src/raise.cr`, and **codegen emits
`fun`s and top-level code by walking the AST**, so the prelude's tree has to
reach codegen whatever the front end did with it. Once it does, the object is
equivalent.

Which is exactly what IV.1's object-code section is for: the prelude's machine
code comes from the artifact, not from re-analysing its source. The front end and
codegen need the prelude for *different reasons*, and only the front end's reason
is removed by caching analysis. Anyone building this will hit the same error and
should not conclude from it that the design is unsound.

**Measured again, now that it exists and the prelude is 1,053 lines: at this
scale the artifact buys no measurable time.** `bench/artifact_speed.py` builds
the Kemal port. The largest import graph here: from four modules' source and
then from four modules' artifacts with every one of those sources deleted. The
front end is the same figure either way, run after run, within a few percent.
The full builds move by more than that between two runs of the same column, so
this machine cannot separate them at all: what is being compared is smaller than
what the machine does to any measurement of it.

The reason it comes out this way is that **an artifact does not remove the pass
that costs**. What it removes is reading a module's source and typing its
bodies. What it does not remove is parsing. The declarations are text, and they
arrive as text, or the top-level pass, which runs over those declarations
exactly as it would have run over the source. At 107,719 lines the difference
between "the source" and "its declarations" was three orders of magnitude. At
400 it is nothing, and the parse of the declarations can cost more than the
parse of the module.

One thing the bench did find, and it was a defect rather than a difference: the
consumer wrote every object file it unpacks out of an artifact on **every**
build, to link bytes identical to the ones it linked last time. Six files on
this program. It writes them only when they are not already there now, which is
verified by the filesystem rather than by a stopwatch. A second build of an
unchanged program rewrites none of the six, where it used to rewrite all of
them.

**So it decides the prelude question, which was the next item on the list.**
Making the prelude an artifact would leave its 0.010 s top-level pass exactly
where it is, because that pass is over declarations either way, and would save
only the macro expansion: `primitives.iyi` writes 445 definitions from a loop
over five types, and an artifact would carry them already written out. What
removes the prelude's cost is not serialising the analysis but *keeping* it,
which is the daemon (IV.1d): analysed types in memory, no parse and no pass.

None of this is an argument against the artifact. It is the argument for what
the artifact is actually for: R-1, so that a module compiles against
declarations rather than source; IV.3, so that a build knows what to redo; and
`ObjectCode`, so that a consumer links a module it never compiled. Speed at this
size was never among them, and saying so is cheaper than measuring it twice.

### IV.1b End to end, with a real binary at the end

The probe can also link, so the claim can be checked the only way that really
counts: build `hello.iyi` inside the fork and run what comes out. Both models
produce a binary whose output is identical to a normal build's.

| | front end | whole build | vs Crystal today |
|---|---|---|---|
| today | 1.48 s | 2.19 s | 1.00× |
| artifact model | 0.47 s | 1.13 s | **1.9×** |
| + prelude-aware passes | 0.049 s | 0.74 s | **3.0×** |

Reaching this needed a runtime fix, worth recording because it is not
iyi-specific. **A forked child could not spawn a subprocess at all.**
`Signal.after_fork` recreates the signal pipe but never restarts the
`signal-loop` fiber that reads it (only the forking thread survives a fork) so
a `SIGCHLD` was written into a pipe nobody read and `Process#wait` blocked
forever. That silently broke the linker, `expand_lib_flags`, and `macro_run`
alike; restarting the reader fixes all three.

So a prelude daemon (analyse once, fork per build) is not blocked on `.iyimod`
at all.

### IV.1c Two bugs the split found, which `.iyimod` would have hit anyway

Making the artifact model compile the compiler itself took fixing two defects in
`TypeDeclarationProcessor`. Both are latent today and unreachable in a single
run, and both are certain to reappear the moment analysis is restored from an
artifact rather than recomputed. They are the first concrete evidence of what
Part IV costs beyond the file format.

1. **A module's guessed instance variables never reached types that included it
   later.** `process_owner_guessed_instance_var_declaration` returns early when
   the owner already has the variable, which doubles as "already processed",
   and that skipped the transfer to `raw_including_types`. When `IO::Buffered` is
   analysed in one run and `Socket` includes it in the next, `Socket` never gets
   `@in_buffer`, and it surfaces far away, as a nil assertion while attaching the
   initializer.

2. **Redeclaring a variable discarded its initializer.**
   `declare_meta_type_var` always builds a fresh `MetaTypeVar` and replaces the
   old one. In a single run that is safe, because declarations are processed
   before initializers are visited. Across a split it silently dropped every
   prelude class variable's initializer: caught here by the non-nilable check,
   but the same clobbering would have left them uninitialized at runtime.

3. **A per-pass flag stayed set across passes.** `top_level_semantic_complete`
   guards `TypeNode#instance_vars` and `#has_inner_pointers?` in macros, which
   must refuse to answer before instance variables are declared. A second
   top-level pass inherited the flag from the first, so the guard did not fire
   and the macro got an *empty* list instead of an error: then generated code
   against variables the type did not have yet. It is now cleared at the start
   of every top-level pass, which is a no-op in a single run.

The pattern in all three: **passes assume they see the whole program once.** Not
"they are slow", which is what IV.1a measured. They encode single-run
assumptions in ways that only fail when a program is analysed in two pieces.
That is the real content of "make the passes prelude-aware", and it is found by
running the split, not by reading the code.

### IV.1e What the fourth failure revealed about the experiment

The full model's remaining failure on the compiler was worth chasing to the
bottom, because the answer is about the experiment rather than about a bug.

Two plausible causes were wrong. It was not `finished_hooks` accumulating across
runs, and it was not the flag above. The actual chain, from the compiler's own
stack rather than from reading:

```
force_add_subclass → add_subclass → notify_subclass_added → Call#on_new_subclass
```

**A subclass observer is a `Call` registered during `main`, and notifying it
re-types that call.** In an ordinary compile this can never fire mid-declaration:
every type exists before `main` runs. Under the full model the parent had already
run `main`, so the child's top-level pass declaring `TypeException < CodeError`
re-typed a prelude call against a type whose instance variables were not declared
yet: hence a complaint about `@inner`, three layers away from the cause.

Holding those notifications until the end of the top-level pass fixes that layer
and exposes the next one: `instance variable '@dependencies' of Crystal::ASTNode
must be Crystal::SmallNodeList, not Nil`, i.e. nodes bound by the completed run
being re-bound by the new one.

That deferral is **not** in the tree. It passed the whole suite: 3350 semantic,
1811 codegen, 3962 parser, so removing it was a scope decision rather than a
correctness one: it changes a core mechanism to serve a configuration that still
does not work, and the knowledge it produced is this section. Whoever builds the
real prelude-aware passes will need it, and will find it here.

**The pattern is the finding.** The full model restores a prelude analysed
*through `main` and `cleanup`* and then declares new types against it. Part IV's
artifact deliberately carries types, signatures, impl records and layout
templates: **not typed method bodies**. So the full model was measuring a
configuration the design does not ask for, and its layered failures are what
"analysis complete, now declare more types into it" costs.

This corrects the third column of IV.1a: **32× is the value of a configuration
that does not work**, not a target. The genuine version of "prelude-aware passes"
parent stops at the end of the top-level phase exactly as the artifact model
does, and the child's *later* passes skip prelude subtrees: has not been built
or measured. It is the honest next experiment, and it is unaffected by everything
above, because it never runs `main` twice.

**Where it stands:** the artifact model now compiles all nine gate programs, a
targeted regression for each bug above, and the compiler itself. The full model
still fails on the compiler, for the fourth reason above, so its 3.0× remains a
result on small programs. The artifact model's 1.9× is the one that survives
contact with a real codebase.

The other honest limit: codegen's own prelude cost is untouched: 0.7 s of the
2.2 s build, now the dominant term, and reducing it is the object-code
section's job, which Crystal's existing `.o` reuse already does part of.

### IV.1d The daemon. The measurement, shipped, and then outlived

**Read this section knowing how it ends.** The daemon was built to hold
Crystal's 107,719-line prelude analysed between builds, and it did, and then
0.1.0 item 3 replaced that prelude with 1,053 lines of iyi and left it nothing
to hold. Measured again on the edit loop of IV.3a, 30 modules and 7,207 lines,
each build checked to produce a program that prints what the edit says it
should:

| | one module edited, rebuilt |
|---|---|
| `iyi build` | 0.18–0.28 s |
| the same through the daemon | 0.20–0.24 s |

**Nothing, within the noise, and a socket round trip to pay for it.** The term
it removes is prelude analysis, and iyi's prelude is small enough that
analysing it is no longer a term. So the daemon stays in the compiler, where it
is Crystal's to use on Crystal's prelude, and `iyi` does not offer it: a
command that costs a terminal and buys nothing is not a command.

> **And then `--crystal` gave it a prelude to hold again, so `iyi` offers it.**
> The paragraph above is right about iyi's prelude and wrong about the mode
> item 12d made central. `iyi daemon start` runs a single-threaded `iyi-daemon`
> built and shipped beside `iyi`, and holds Crystal's library analysed between
> builds.
>
> **The first numbers written here were wrong, and how they were wrong is worth
> more than they were.** They are below, after the right ones, because a
> measurement that flatters its own feature is a failure this document has now
> recorded more than once.
>
> Front end only, so that the term the daemon actually removes is not diluted by
> codegen. Release compiler, a daemon holding one prelude, and the two arms
> alternated rather than run in blocks — this machine's clock steps, and a block
> of one arm can land inside a step:
>
> | twelve-module app, `--no-codegen` | normal | through the daemon |
> |---|---|---|
> | twelve modules | 0.77–0.85 s | **0.44–0.49 s** |
> | twelve modules and Kemal | 1.15–1.36 s | 0.93–1.13 s |
> | the same, with Kemal named in a `--prelude` file | 1.15–1.36 s | **0.57–0.66 s** |
>
> **What it removes is about 0.3 s**, and a full build adds codegen and a link
> that it does not touch, so the share is smaller again. Full-build timings on
> this machine were too noisy to publish.
>
> > **They are publishable now, and the harness is committed** —
> > `bench/daemon_full_build.py`, which builds twelve modules under `--crystal`
> > with codegen and a link, eight alternating pairs, a module edited before
> > every build, and refuses to run unless both binaries are optimised. All
> > three of those are the corrections above, built in so they cannot be
> > forgotten again.
> >
> > | twelve modules, full build | min | median |
> > |---|---|---|
> > | normal | 0.63 s | 0.66 s |
> > | through the daemon | **0.46 s** | **0.49 s** |
> >
> > **0.17 s, or 26%**, and two runs agree to a hundredth. What was called noise
> > was mostly the measurement: `/usr/bin/time`, whose negative elapsed times
> > this section records, is not installed on this machine at all, and the wall
> > clock now runs a three-second window against the monotonic one with no
> > backward step.
> >
> > **This is not the row above measured further.** The app here is twelve
> > trivial modules and its front end alone is 0.35 s, against 0.81 s for the
> > app the table was made from — a lighter program, so a smaller saving. What
> > it establishes is that a whole build *can* be measured here, and what the
> > shape of the answer is: the daemon takes about half of the front end, and
> > the front end is about half of the build.
>
> **The last row is the finding.** It is the only large effect, it is more than
> twice the other two, and it does not come from holding the prelude — it comes
> from holding *Kemal*. The daemon's value is in the program's dependencies
> rather than in the library underneath them, which is the same sentence as
> "give the dependency an artifact", said by a resident process instead of by a
> file.
>
> **What it costs is memory.** About 200 MB resident per prelude held, and the
> default is three (`CRYSTAL_DAEMON_PRELUDES`), so a daemon that has seen a few
> flag sets is holding half a gigabyte.
>
> **The mechanism itself is sound, measured separately.** `IYI_WARM` analyses the
> prelude and adopts it in one process, without forking: adoption returns
> essentially the whole prelude analysis — 0.48 s of a 1.25 s front end — with no
> penalty for the Kemal case. The gap between that and what the daemon delivers
> is the fork, 0.2 to 0.3 s. It is not the GC: a daemon started with
> `GC_DONT_GC=1` measures the same.
>
> **The wrong numbers, and the three ways they were wrong.** What was published:
> 2.27 s to 1.24 s, 2.42 s to 1.30 s, 3.33 s to 2.52 s.
>
> - **A debug compiler.** `make iyi-tarball` did not force `release := 1`, so
>   the binaries measured were unoptimised. Prelude analysis is about 1.5 s
>   there and about 0.5 s in a release build, so every saving above is roughly
>   three times what somebody with the released tarball would see. The tarball
>   now refuses to be built from an unoptimised binary — `check_iyi_is_release`.
> - **Repeated identical builds.** Crystal caches generated objects per program,
>   so building the same unedited file five times skips codegen from the second
>   run on. That leaves the front end as most of what is measured, and the front
>   end is exactly what the daemon accelerates. Every measurement here now edits
>   a module first.
> - **A stepping clock.** This machine's clock jumps, and `/usr/bin/time`
>   reported *negative* elapsed times more than once. Six measurements of one arm
>   in a row can sit inside a step and come out uniformly wrong, which is how one
>   batch showed the daemon *slower* than a normal build for the Kemal case. It
>   is not. Alternating the arms is what makes a step hit both.
>
> The first two flattered the daemon and the third smeared it in both
> directions. None was a mistake about the compiler; all three were mistakes
> about the measurement, made by the person who wanted the number to be good.
>
> **It warms Crystal's prelude and not iyi's, and that is deliberate.**
> `--crystal` sets the prelude `Compiler.new` already has, so those builds hit
> the startup analysis on their first request. An ordinary `.iyi` build misses
> and warms `iyi/prelude` after its first build: 0.03 s, which is the reason
> the daemon is not for that mode.
>
> **Four bugs were in the way, all older than this work.** Three are one fact
> forgotten — the daemon runs in its own directory and the client does not.
>
> - A finished build's arguments are re-read in the daemon to decide which
>   prelude to warm next, and they were read in the *daemon's* directory. The
>   option parser exits the process on a file it cannot find, so the daemon
>   died after serving a build correctly — whenever the client had typed a
>   relative path, which is always.
> - A preanalysed prelude carries the compiler's search path, and `lib` is
>   resolved against the directory that path was built in. Every shard-using
>   project, built from anywhere but the daemon's own directory, answered
>   `require "kemal"` with "can't find file".
> - Fixing the second silently did nothing, because `CrystalPath` is a
>   **struct**: setting a field through a getter mutates the copy the getter
>   returned. Nothing failed; the daemon simply went on resolving `lib` beside
>   itself.
>
> Every spec in `crystal-daemon_spec.cr` passed through all three, because each
> one passes an absolute fixture path and starts the daemon where the runner is.
> That is the shape of the lesson rather than an aside: **a spec that never
> leaves the directory it was written in cannot see a directory bug.** Three new
> ones do.
>
> The fourth is not about directories and is the worst-behaved: **the path that
> adopts a preanalysed prelude never runs `new_program`**, so everything that
> method turns a switch into was decided by whoever analysed the prelude — a
> `Compiler.new` in a daemon, holding none of the build's switches. Most of it
> is safe because the flags, the target, the optimisation mode and the prelude
> are all in `prelude_cache_key`: an analysis that differs in any of them is a
> different analysis. `--use-iyimod` is not in that key. It was accepted,
> ignored, and the build compiled every module from source without a word,
> which is worse than the switch not existing — and it is only visible from
> outside by deleting the module's source, which is what its spec does.
>
> That one is worth generalising. **A cache key is a claim that everything not
> in it does not matter**, and this key was written when the only thing reading
> it was prelude analysis. Every switch added since has had to be checked
> against it by hand, silently, and nothing enforced the check.
>
> **It is enforced now.** Each of `Compiler`'s thirty-seven switches is written
> down as one of three things — in the key, re-applied when a build adopts a
> preanalysed prelude, or reaching neither — and `prelude_cache_key` refuses to
> compile while any is missing. Adding a property fails the build with the
> question rather than leaving it to be answered later by a build that quietly
> did the wrong thing.
>
> Writing the three lists out is itself worth something: two entries turned out
> to be judgements rather than facts. `mcpu`, `mattr` and `mcmodel` reach the
> target machine and the target machine reaches codegen, so a prelude analysed
> for one `-mcpu` is the same analysis as for another. And `progress_tracker`
> and `stderr` are where output goes — `new_program` sets the first, the adopt
> path sets neither, and that asymmetry was true before and invisible.
>
> **And artifacts and the daemon overlap.** Twelve modules as artifacts *plus*
> the daemon was 1.67 s against the daemon's 1.30 s — slower, because the daemon
> has already removed the term the artifacts were removing and reading twelve of
> them is not free. Under Crystal's library the daemon wins; under iyi's own the
> artifacts do, and neither is a general answer.

The measurement that follows is the one that built it, kept because it was true
and because the shape — *a thing measured, shipped, and then made pointless by
the next thing measured* — is the second time this document has had to record
it (0.1.0 item 2 is the first).

Measured on `hello.iyi`, five consecutive builds with the output deleted each
time:

| | |
|---|---|
| `crystal build` | 2.19 s |
| `crystal daemon build` | **1.12–1.31 s** |
| prelude analysed once, at startup | 1.07 s |

Diagnostics and exit status are identical to a normal build on all nine gate
programs, and the binaries it produces behave identically on all four samples.

Three things it has to get right, all of which are about being a *daemon* rather
than about compilation:

- **Staleness.** It holds an analysed prelude across edits to that prelude. The
  fingerprint is every file in `program.requires` with its modification time,
  checked per request; a changed prelude is re-analysed before the build. Tested
  by adding a method to `String`, watching a previously failing program compile,
  removing it, and watching the error come back.
- **Flags.** Macros branch on flags, so an analysis made under one set cannot
  serve a build under another. The daemon keeps one prelude *per flag set*,
  keyed on everything that changes what the prelude analyses to, and warms a new
  one from builds that already succeeded. The first `--release` build is cold,
  the rest are not. Measured: 0.46 s on a cached flag set, 1.48 s cold, and
  0.52 s once warmed.

  It warms only from arguments a build has already parsed successfully, and that
  is the whole safety argument: turning arguments into a compiler means running
  the option parser, and the option parser exits the process on bad input. Doing
  that on arguments a client made up would take the daemon down on a typo. It
  also warms only while nothing is in flight, since analysing costs about a
  second and this loop is what relays every build's output.

  Bounded by `IYI_DAEMON_PRELUDES`, default 3, because each analysed prelude
  is roughly 180 MB of live heap. Past the bound, extra flag sets stay cold
  rather than being evicted. A cold build is slow, and evicting the set someone
  is actively using would make every build slow in turn.
- **Its own socket.** `UNIXServer#close` unlinks the socket file, so the forked
  child closing its inherited copy took the daemon's address away from every
  later client while the daemon went on listening, looking healthy. `close(delete:
  false)` in the child.
- **Its own compiler.** A daemon holds an analysed prelude *and the compiler that
  analysed it*. Rebuild the compiler and it keeps serving builds from the old
  one, with output that looks entirely normal. The worst shape a stale cache
  can take. It now records its executable's size and modification time before
  opening the socket, checks per request, and refuses with an instruction to
  restart. Nanoseconds, not seconds: a rebuild landing in the same second as the
  daemon's start is exactly the case to catch.

**Using it should not require remembering it.** With `IYI_DAEMON_SOCKET` set,
an ordinary `crystal build` is served by that daemon: 1.00 s against 1.85 s on
the same warm cache, and falls back to a normal build, with a line saying so,
when nothing answers. Opting in to a daemon must never be able to *stop* a build;
the worst it may cost is the speedup.

**Builds run concurrently, and getting there took two attempts.** The obvious
fiber-per-connection version deadlocks and then dies: a forked child inherits the
parent's live fibers, and the scheduler runs them as soon as the child blocks on
IO, so another build's relay fiber writes to descriptors this child has closed.
**Fork-based build servers cannot be made concurrent by adding fibers**: that is
the transferable part.

What works is one fiber and one `poll(2)` over the listener plus every in-flight
build's two pipes. Crystal has no `IO.select`, so the binding is declared in the
daemon (at file scope: reopening `lib LibC` inside a class defines a *nested* lib
of the same name instead of extending the real one). A child also closes every
*other* in-flight build's connection and pipes, or an inherited copy outlives the
build that owns it.

Measured: four concurrent builds finish in 2.0 s against 1.16 s for one, and
eight (half of them deliberately failing) in 3.2 s with every exit status and
every diagnostic delivered to the client that asked for it.

Two limits worth naming: the request is read inline, so a client that connects
and then stalls holds up the loop; and writes to a client are blocking, so a
client that stops reading stalls the relaying of other builds. Both are fine for
a local build daemon and neither is fine for anything exposed.

**Packaging.** The server is a separate binary, `make crystal-daemon`, built with
`-Dwithout_mt`. This is not a workaround to be removed later: only the forking
thread survives a `fork`, so a multi-threaded runtime hands the child a broken
one, and Crystal refuses `fork` in such a build at compile time: correctly. The
client does not fork, so it stays in the normal compiler; `crystal daemon start`
execs the server binary (or `IYI_DAEMON`, if set) and says how to build it
when it is missing.

The cost of that split is that the daemon's builds code-generate sequentially.
Measured, it does not eat the win: on a 19.5k-line, 1500-type program the normal
multi-threaded build takes 3.40–4.25 s and the daemon 2.59–2.77 s, with identical
output. That is one program on one machine, not a general claim. A program whose
codegen both dominates and parallelises well could come out differently.

Against the same multi-threaded compiler as baseline: `hello.iyi` 2.21–2.26 s
normally, 1.16–1.24 s through the daemon.

**What it is not.** It cannot cross machines or sessions, it holds one prelude
and so serves one flag set quickly, and it builds one program at a time. It is
scaffolding that `.iyimod` will replace: worth having because it delivers the
win now and because every latent single-run assumption it trips over is one
`.iyimod` would have tripped over later.

It is covered by `spec/compiler-cli/crystal-daemon_spec.cr`, which starts a real
daemon on a private socket and checks the properties that would make it subtly
wrong rather than visibly broken: a served build's exit status and diagnostics
match a normal build's byte for byte, `stdout` and `stderr` stay separate, a
second build is still served after the first, and a build whose flags differ from
the daemon's prelude is still correct. `make cli_spec` builds the server binary
so the suite actually exercises it; if it is absent the examples report as
pending with the reason, rather than passing silently.

**The artifact alone is worth 3.4×, not 20×, and the gap is not the artifact's
fault.** Where the child's 0.45 s goes:

| Pass | Cost with prelude pre-analysed |
|---|---|
| top level | 0.004 s (was 0.99 s) |
| class-var initializers | **0.285 s** |
| main | **0.162 s** |
| everything else | ~0.04 s |

The top-level pass. The only one `.iyimod` removes: drops by 250×. What
remains is that **six of the eleven semantic passes re-walk the prelude AST and
three re-walk the whole type graph**, whatever put the prelude there. Class-var
initializers and `main` are 90% of the residual.

**So Part IV is necessary and not sufficient.** A serialised prelude that the
later passes still traverse converts a 1.5 s front end into a 0.45 s one; the
floor needs those passes to skip prelude nodes too, which the experiment above
shows is achievable and worth another 10×. That is a separate piece of work from
the file format, it is larger than the format, and it should be planned as such
rather than discovered afterwards.

Two secondary results from the same instrument:

- **Half the top-level cost is parsing.** 304 files, 107,719 lines: 0.57 s to
  parse, 0.54 s to visit. A cache removes both; a faster parser removes one.
- **User code stays nearly free until the program is large.** `webapp.iyi` costs
  the same as `puts "hi"`. At 19.5k lines user code finally dominates and the
  win falls to 1.7×. The prelude cache matters most to the small, frequent
  builds, which is where build-speed complaints come from.

**Everything above was measured against a 107,719-line prelude, and item 3
deleted it.** The table in this section is kept as what the instrument said at
the time, because the reasoning it supports is still the reasoning. A pass that
re-walks the prelude is a pass whose cost grows with the prelude. What changed is
the multiplier. Re-measured on the release compiler with iyi's own 1,053-line
prelude: the top-level pass is 0.012 s, and class-var initializers, `main`,
instance-var initializers, cleanup and the recursive-struct check are **0.4 ms
between them**. "Six of the eleven passes re-walk the prelude AST" is still true
and no longer worth anything: the residual it describes is 2% of a front end that
is itself 7% of a build. Scope item 2 records where the time went instead, which
is the linker.

### IV.2 What goes in Exports, and what is deliberately kept out

**In:**

- **Type declarations.** Name, kind, generic parameters, field names and types.
  **Built.** A field travels as its resolved type rather than as the annotation
  the author wrote, which is a departure from how signatures travel and is
  deliberate: a field is not part of the surface a consumer writes against, it
  is what the consumer has to allocate. For a generic type the resolution is in
  terms of its own parameters: `List(T)`'s `@items` is `Array(T)`, which is
  what lets one declaration stencil at every instantiation.
- **Class variables.** **Built, and it was a hole in R-1 rather than a gap in
  the format's coverage.** A class variable is a global. The methods that read
  it travel as machine code and refer to it by name — `@@seen` on
  `App::Counter::Tally` is the symbol `App::Counter::Tally::seen` — and the
  global itself is defined in the *main module*, which is the one part of a
  build that never travels. Nothing in the format mentioned class variables at
  all: not `TypeDecl`, not `Constants`, nowhere.

  So R-1's own claim was false for any module that had one, in iyi's own
  language and under iyi's own prelude. Build a module with a `@@seen : Int32
  = 0`, delete its source, build again from the artifact, and the link ended on
  `undefined symbol: App::Counter::Tally::seen`.
  `bench/samples_roundtrip.sh` is the gate for exactly that claim and passed,
  because none of the six samples has a class variable.

  **Two channels, and each closes half.** `TypeDecl` carries the declaration —
  name, resolved type and the initialiser as written — the way `fields`
  already do, one level up: the resolved type for the same reason a field's is
  resolved, the value because it has to run on the far side. That is what a
  module's **own** class variable needs, and it is all a bound shard's needs
  too.

  It is not enough on its own, and the case that says so is
  `@@cache : String? = nil`: a nil initialiser assigns nothing, so the compiler
  drops it before an artifact is written. The consumer read the declaration,
  made no initialiser out of it, and codegen — which emits what the consuming
  program *reaches* — emitted no global. So `ClassVars` carries the names a
  unit's object code refers to, and the consumer defines each. That second
  channel is also the whole of what a class variable of the **library** needs:
  the consumer already has the declaration, having compiled the same library,
  and only the global was missing. A bound shard reaching `String#upcase`
  refers to `Unicode::@@upcase_ranges`; one holding a regex it matches refers
  to `Regex::PCRE2::@@current_jit_stack`. One name answers both cases.

  **What a consumer owes is not only the global, and it cannot work out which.**
  A class variable with a live initialiser is read through `~Owner::name:read`,
  a main-module function that initialises on first use; one without is read
  straight off the global. Which of the two a unit emitted is decided where the
  producer emitted it, and the far side has no way to reach the same answer —
  so `ClassVars` carries a flag beside each name and the consumer builds
  exactly what was emitted.

  Both wrong guesses were made before that was clear, and each fails in a
  different world. Assume the direct form and a `--crystal` consumer leaves
  `~Exception::CallStack::skip:read` and
  `~Crystal::EventLoop::Polling::arena:read` undefined — both Crystal's own,
  both caught by `bench/bind_roundtrip.sh`. Assume the lazy form and an
  iyi-prelude program dies on `BUG: __crystal_once is not defined`, because
  iyi's prelude has no `__crystal_once` at all: **nothing under it ever takes
  that branch**, which is a real difference between the two libraries and not
  an accident of one program.

  Nothing in that step initialises. A variable whose declaration travelled has
  its initialiser in the consumer's own tree and runs on the ordinary path; one
  of the library's runs where that library says. What is missing is only ever
  the global, and the function that reaches it.

  **And a module has them too, which is a different place to put them.** A
  `TypeDecl` holds a type's; a module is not a `TypeDecl`, so `Exports` holds
  the module's own. `module Backtracer; class_getter(configuration)` is what
  said so — `Backtracer::configuration` was undefined at the end of a build
  that had every one of that shard's types *and* their class variables, because
  the one that mattered belonged to the root.

  **A thread-local one owes a third thing.** `@[ThreadLocal] @@current_jit_stack`
  is not read through its global but through a `noinline` function that hands
  back the address — LLVM would hoist the address out of the thread otherwise —
  and that function lives in the main module. So a consumer that had defined the
  global and copied the accessor around it still ended on
  `undefined symbol: *Regex::PCRE2::current_jit_stack`. It defines that function
  too, whichever way the variable is read.

  **And the value has to be caught before the compiler rewrites it.** The
  initialiser travels as source, and the node a class variable holds is not
  that source by the time an artifact is written: `CleanupTransformer` replaces
  it with what the literal expanded to. `@@nums = [1, 2, 3]` reached the format
  as five statements over three temporaries, and the consumer parsing them back
  said `read before assignment to local variable '__temp_2'`. It is recorded
  where the initialiser is first gathered instead, which is before any of that.
- **Layout templates.** Size, alignment, and pointer map: expressed as a
  *function of the type parameters' shapes*, not a fixed layout. `Array(T)` is
  three words regardless of `T`; `Tuple(Int32, String)` is not. R-4 needs the
  template to stencil at any shape.
- **Type descriptors.** A runtime type id per exported type. II.6 established
  that dictionaries carry type identity, not just pointer maps, because
  `select(type : U.class)` filters by runtime type.
- **Signatures** of `pub` functions and methods. Parameters, return type, the
  `where` bounds from II.6, and everything else on the `def` line: the block
  annotation, `forall`, `abstract`, the receiver.
- **Trait declarations.** Required methods, associated types, and the
  *signatures* of default methods.
- **Impl records.** Every `(Trait, Type)` pair this module provides, with what
  the impl answers. Its `forall` parameters, its trait arguments, its
  associated types, and the methods it defines. This is what lets a consumer
  answer "does `Customer` implement `ToJSON`?" without reading `Customer`,
  which II.4 depends on.
- **The module's `using` directives.** Not part of its surface: nothing here is
  reachable through them. Part of what its surface *means*. A signature is
  stored as the annotation the author wrote (IV.1), and `pub def handle(ctx :
  Context)` resolves `Context` through a `using` further up the file. The
  annotation travels, so what resolves it has to travel with it.
- **Exported constants.** **Built.** `pub LIMIT = 42` is reachable through the
  module's name and an unmarked constant is not, which is the same sentence an
  unmarked `def` gets. Nothing was added to the format: a module's own top
  level already travels as source text, so the mark travels by being written
  back out, exactly as `pub macro` does.

  Closing it found the hole under it, the third of its kind: a constant's
  visibility was never set from `pub`, so **every** constant a module declared
  was reachable through its name. A shard is where that shows: Kemal hands out
  every object it has through one, and the boundary in Part V item 12 could
  read 22 of its types and reach none of them.

  `pub enum` is built, and so is the surface an enum needs: `samples/iyi/enums.iyi`
  asked, and `src/iyi/enum.iyi` is the answer. The compiler gives an enum two
  methods — `value`, the integer the member was numbered with, and `new`,
  which wraps one — and everything a program does with one is the library's:
  equality (which is what `case` and every per-member question method are
  built on), an order, the member's name, the members as a list, a name read
  back, a value read back, and for a `@[Flags]` enum the membership its
  question methods ask and the two set operators. Before that surface existed
  the answers were `Object`'s: `Level::Warn == Level::Warn` was **false**,
  `to_s` printed the type's name, and a `case` over the members matched
  nothing. `bench/enum_exercise.sh` holds all of it and proves each check by
  breaking one method of a copied prelude.

  **And it crosses a boundary**, which is the half that had never been asked
  of it. An exported enum travels as its *members* and the numbers they were
  given — the module's object code was compiled against those, so a consumer
  that counted from zero again would agree with it only by luck — plus
  `@[Flags]` where the author wrote it, and without the `None` and `All` that
  annotation is given wherever it is declared. The surface is not carried and
  must not be: `value`, `new` and a question method per member are the
  consumer's own compiler's to write from the declaration, and the rest is
  its prelude's `Enum`. Three defects were in the way, each invisible until
  one was exported: R-2 refused the question methods the compiler writes,
  because they carried no return type; the writer asked an enum for its
  instance variables; and an enum's members read as code inside a type body,
  so the artifact could not be imported at all. `bench/enum_exercise.sh`
  builds a consumer against a module's source and against its `.iyimod` and
  requires the same answers.

**R-3 is refused where somebody reaches for it.** The way a Crystal programmer
adds a method to an imported type is a qualified declaration: `struct
App::A::Point` inside their own module. iyi has no open classes, so that path
does not resolve, and the compiler used to do the helpful thing and create
`Main::App`, `Main::App::A` and a second `Point` inside them. The program then
failed somewhere else with `wrong number of arguments for
'Main::App::A::Point.new'`, which names neither the rule nor the type the author
meant. It is refused at the declaration now, naming both, and pointing at the
`impl` that R-3 does allow. A file's own namespace is untouched, and so is
`module app/formal` beside `module app/greeter`, which share `App` because the
parser wrote both.

**R-2 is enforced where the artifact is written, and until recently only half
of it was.** The block rule below was checked and the rest was not: `pub def
greet(name)` compiled, the artifact recorded `def greet(name)`, and the cost
landed on somebody else. A consumer types a call from the return type alone,
since the body stays behind, so it inferred `Nil` and asked the linker for
`greet<String>:Nil` while this module had emitted `greet<String>:String`. The
module's own build was clean and the consumer's failed on a mangled symbol that
named no rule. Both halves are checked now, at the same place, and the message
names R-2 and the parameter.

Two things are exempt and both for the same reason: the type is already written
down somewhere a consumer reads. `initialize` answers the type it is defined on,
a setter answers what it was handed, and a method inside an `impl` is checked
against the trait's `abstract def`, which is where its types are.

**A block parameter is a parameter (R-2).** An exported `def` that takes a
block has to say what the block is: `pub def namespace(path : String, &)` says
a block arrives and nothing about it. Inside the module that is enough, because
the `yield` is right there. Through an artifact it is not. The body stays
behind, and what the block receives and returns is in it. Refused where the
module is compiled rather than where it is read, because that is where the
author can fix it.

The count that decided it: **one exported signature in the samples out of about
eighty**: Kemal's `Router#namespace`, which is also the case no annotation can
express, since `with sub_router yield` changes what `self` means inside the
block.

**And that one was paid rather than avoided.** The port now takes the
sub-router as a block parameter: `& : Router -> Nil`, called with `|admin|`,
which is a visible loss against Kemal's original and a smaller one than keeping
`namespace` unexported would have been. The alternative is a notation for the
block's `self`, something like `& : with Router -> Nil`, and it stays open: it
would have to say that `self` becomes the annotated type *with the caller's own
behind it*, which is what `with … yield` means. Nothing else in the samples
asks for it, and what unblocking `namespace` bought was two further findings in
IV.1g that no amount of reasoning about blocks would have produced.

**Out, deliberately:**

- Bodies of ordinary `pub` functions.
- Everything private: types, methods, fields not exposed.
- Anything that would let a consumer come to depend on an implementation detail.

**The two exceptions, both of which cost something:**

1. **Macro bodies.** `derive JSON` runs in the module declaring the type
   (II.4), so that module needs `std/json`'s macro body in order to run it.
   Macros are compile-time code; shipping them is loading a plugin, not reading
   an implementation.

   **Built, and the reason turned out to be nearer than `derive`.** A body that
   travels may call a macro of its own module, so the macros travel with it,
   all of them, on the module and on each type, as source text.

   **`pub macro` is the way to say which of them another module may run, and
   it is built.** A marked macro is reachable exactly as a `pub def` is:
   unqualified after `using`, or through the module's name. An unmarked one is
   the module's own and is refused by the same sentence an unmarked `def` gets.
   What it exports is a name and an arity rather than types, because a macro
   takes syntax and returns syntax and there is no type to write down — the one
   place R-2's "write the types" has nothing to ask for.

   Closing this found the hole under it: a macro's visibility was never set, so
   before `pub macro` existed **every** module's macros were already callable
   through its name. They travel so that a travelling body can call one, and
   that made them a surface nobody wrote and nobody could have refused.

   **Macros are not hygienic, and `pub macro` exports that too.** A macro is
   pasted text, so `pub macro shadow` writing `tmp = 99` assigns to the
   consumer's `tmp` if it has one, which was measured rather than assumed. This
   is Crystal's semantics kept whole, and it is a real hole in what R-2
   promises: an export whose surface is a name and an arity can still reach
   anything the caller can name. Hygiene is a rename of every name a macro
   introduces, it would part this fork from the macro semantics its own prelude
   is written in, and it is not built.
2. **`@[Monomorphize]` bodies.** The consumer specialises them, so it needs the
   body. This is the (b) path from II.6 and it is where incrementality is at
   risk: see IV.3.

   **Built, and wider than the annotation suggests.** The set is not the items
   somebody marked: it is every method a consumer has to compile, which the
   compiler can work out for itself. A generic type's methods, because
   instantiations belong to whoever writes them; a trait's defaults, because
   they are stencilled onto the implementing type; an impl's methods *unless*
   its target is a non-generic type this module declares, because otherwise
   they land in a unit the artifact cannot carry; and **any def that takes a
   block**, wherever it is written, because it is instantiated with the
   caller's block inside it and the caller is the consumer. `@[Monomorphize]`
   remains the annotation for choosing to specialise something that would
   otherwise be a dictionary call (II.6); it is not what decides whether a body
   travels. See IV.1g.

### IV.3a What the loop costs, against the language that does this well

The property above is a spec: a body edit does not move the interface hash, so
dependents are not rebuilt. What it was not, until now, is a number. Everything
timed in this document before this section was a *whole* build, and nobody uses
a language through whole builds.

`bench/incremental.py` builds a project rather than a file: 30 modules, 300
types, 7,207 lines, written by one generator in iyi, in Crystal and in Go, and
refused if the three binaries do not print the same number. Then it changes one
line and builds again. Best of 7, seconds, release compiler, idle machine:

| what changed | iyi | Crystal | `go build` |
|---|---|---|---|
| nothing cached anywhere | 0.61 | 1.97 | 3.09 |
| nothing at all | 0.12 | 1.14 | 0.08 |
| **one module's body** | **0.13** | **1.17** | **0.16** |
| the entry file only | 0.12 | 1.15 | 0.16 |
| the same edit, without artifacts | 0.23 | — | — |

**Four things fall out of it, and the last is the one to keep.**

**The Crystal column is the whole argument in one number, and it is this
compiler.** The same binary compiles that column; the difference is the
language it is compiling. A Crystal class is open until the last line of the
last file, so no build may trust anything it read last time, and every rebuild
of this program costs 1.17 s no matter what moved in it. The same edit under
R-1 and R-3 costs 0.13 s. **9x, on the language this is a fork of, measured
rather than argued** — and it is the number this document has been promising
since its first page.

**The loop is also where iyi holds against Go.** 0.13 s against 0.16 s for the
same edit to the same program, and 0.16 against 0.19 an hour earlier: Go's
column moves as much as iyi's, which is the answer to what a single run of
either would prove. Go is not slow at this; Go is the reason
this design exists. Being ahead by a fifth on a project this size is not the
headline: being in the same class is.

**The last row is R-1's argument with a price on it.** The same edit, built
without artifacts so that all 30 modules are read and analysed from source,
costs 0.23 s. With the artifacts it costs 0.13 s. **The rule pays 1.8x on the
loop it was written for**, and it pays it on a 7,207-line project — the figure
grows with the code that is *not* being edited, which is the whole of any real
program.

**The seconds are a machine, the columns are the language.** The table above
was measured in a state this machine's own reference accepts — starting the
compiler and doing nothing costs what it cost when 0.1.0's target was recorded.
Two sessions the reference accepts read 0.13 / 1.17 / 0.16 and 0.16 / 1.29 /
0.19 on the edited-module row, and a tired one reads 0.22 / 1.81 / 0.27:
everything moves together and the ratios stay.
`bench/incremental.py` prints that factor and says which of the two kinds of
run produced its table, because a comparison survives a slow machine and a
figure in seconds does not.

**What the rule is worth as the project grows, and where it is worth nothing.**
The table above is one project. Five, from the same generator, each timed the
same way: edit one module, rebuild with the artifacts, then rebuild the same
edit with every module read from source. A debug compiler, so read the ratios
rather than the seconds:

| project | with artifacts | from source | |
|---|---|---|---|
| 30 modules of 1 type, 997 lines | 0.13 | 0.14 | 1.1x |
| 300 modules of 1 type, 9,907 lines | 0.47 | 0.68 | 1.4x |
| 30 modules of 10 types, 7,207 lines | 0.27 | 0.48 | 1.8x |
| 60 modules of 10 types, 14,407 lines | 0.42 | 0.85 | 2.0x |
| 120 modules of 10 types, 28,807 lines | 0.77 | 1.61 | 2.1x |

**It is the lines, not the modules.** Three hundred modules of one type each buy
1.4x; thirty modules with ten types each buy 1.8x on a third of the files. And
below a certain size it is a loss: a project of 300 five-line modules rebuilt
in 0.30 s from source and 0.35 s from artifacts, because reading a `.iyimod`
costs more than parsing five lines. R-1 pays for the analysis it skips, so it
pays where there is analysis to skip, and a module small enough to read at a
glance is one the compiler can read at a glance too.

**What is left is not analysis, which is why this stops here.** Of the 0.13 s,
0.018 s is the compiler process starting and most of the remainder is the
link (0.1.0 item 2 measured the same shape on `hello`). Editing one module of
thirty costs about 0.02 s over editing nothing. There is no version of this
table where making the front end faster moves the number a person feels; the
next thing that would is not compiling at all on a rebuild, which is V.9 (d)
and is priced there at weeks.

### IV.2a The checksum, and what it is not for

**Format v19 records a 64-bit checksum per section in the table, and a section
that is read is checked.** Found by damaging artifacts on purpose: a single
flipped byte in a `.iyimod` written by this compiler used to build **seven
times out of ten**, with the program still printing the right answer because
the byte had landed somewhere that changed nothing. The other three reached the
linker, which failed with a message that never mentioned the artifact. Now all
twelve of twelve are refused, each naming the file and the section.

**Per section rather than per file**, because a front-end read seeks past the
object code and hashing the whole file would put the largest section back on
the path IV.1 exists to keep short. The consequence is stated rather than
hidden: a build with `--no-codegen` compiles happily against an artifact whose
`ObjectCode` is damaged, because it never reads it, and the build that links is
the one that refuses. A section nobody reads is a section nothing is compiled
against.

**This is not a signature.** MD5 folded to eight bytes catches a bit flip, a
truncated copy and a partial write; it catches nobody who wants to write a
`.iyimod` on purpose, and the format does not pretend otherwise. R-1 already
says a consumer trusts an artifact's declarations, so an artifact from an
untrusted source is a decision made before the reader ever sees it.

### IV.3 Hashing. The part that decides whether builds are actually incremental

**The property that matters: changing a function body must not change the
interface hash.** If it does, every dependent rebuilds and the entire benefit
evaporates.

**Written, and the property is a spec rather than a claim.** `Hashes` carries
three digests, taken over what the artifact itself carries rather than over the
file it came from, which is what makes the interface hash mean anything: it is
over the exports, so an edit that does not reach them cannot move it. Editing a
body leaves the interface and implementation hashes where they were and moves
only the source hash; adding a `pub def` moves the interface hash. Both are in
`spec/compiler/iyimod_spec.cr`.

Two things the implementation settles that the table below leaves open. The
digests are taken **from the front end alone**, before codegen: an artifact
written by `--no-codegen` and one written by a full build describe the same
module and have to hash the same, or a build that only typechecks would
invalidate what a build that generated code had just written. And the module's
**initialiser is implementation**, not interface. It is spliced into the
consuming program and runs there, so a consumer that has compiled it has to
compile it again when it changes.

Three hashes, not one:

| Hash | Covers | Changing it invalidates |
|---|---|---|
| **Interface** | exported signatures, layouts, type descriptors, trait declarations, impl records, exported constant types (when there are any: see IV.2) | every dependent must re-typecheck |
| **Implementation** | macro bodies, `@[Monomorphize]` bodies | only dependents that actually expand or specialise those items; no re-typechecking |
| **Private** | everything else: private types, all ordinary bodies | nothing outside this module; dependents relink but do not recompile |

Worked through:

- Edit a private helper → private hash only → this module rebuilds, nothing else.
- Edit a `pub def` body → private hash → this module rebuilds; dependents relink.
- Change a `pub def` signature → interface hash → dependents re-typecheck.
- Edit `@[Monomorphize] def map`'s body → implementation hash → callers of `map`
  re-codegen, but do not re-typecheck.

**This makes the real price of `@[Monomorphize]` visible.** It is not only "more
code generated": it puts the body in the metadata, so **editing a monomorphised
function rebuilds everything that uses it.** That is the mechanism behind Rust's
slow incremental builds, and iyi imports it deliberately, in exchange for speed
on the hot path. Without the interface/implementation split it would poison
incrementality outright.

**Cache key** for a module: its own source hash, plus the interface hashes of
all transitive imports, plus compiler version, target triple and build flags.

**Built, and it is what turned `--use-iyimod` from a claim into a cache.** An
artifact records, for every module it imports, what that module hashed to when
it was compiled against it, so a build can ask two questions without opening
anything it does not need: does this artifact still describe the source it was
written from, and is every module it was compiled against still the module it
was compiled against. Both are answered from the header, the hashes and the
edges. The section table earns its keep here, because a staleness check that
had to page in the exports and the object code to answer would cost more than
the analysis it saves.

**What a stale artifact means depends on what the build asked for.** A build
that only reads them is refused, and told which module moved and how: quietly
compiling the source instead would make a build that asked to be compiled
against artifacts slower than it looks and prove nothing, which is IV.5's rule
applied to a different kind of mismatch. A build that also writes them is the
incremental loop itself: there, the stale module is compiled from its source and
its artifact rewritten, and everything still true is read.

**The property, demonstrated rather than asserted.** Two programs over one
graph: `main → app/outer → app/inner` and `leaf → app/inner`, so that the
dependency can be rebuilt while the dependent is not touched. Edit
`app/inner`'s body, rebuild `leaf`: `app/outer`'s artifact is still read, and
the program links the new body through the linker. Add a `pub def` to
`app/inner` instead, and `app/outer` is refused by name. Both are in
`spec/compiler/iyimod_spec.cr`.

**A boundary answers the source question with its inputs.** A module
compiled from source is one file at its module path, and the source hash is
over that file. A shard `iyi bind` wrote has no such file - its source is a
checkout - so the artifact records every file the bind read, each with what
it hashed to (`Section::Inputs`), and a consumer digests each one that is
still on the machine before reading the artifact. That is a read of the
whole checkout per `import` of the boundary, per build: the price of a cache
that can go stale, paid where a module of one's own pays one file. A file
that is gone is not asked, because a boundary travels without its checkout;
a file *added* to a shard that requires by glob is not seen, because what is
recorded is what was read. `bench/bind_roundtrip.sh` holds both.

**One bug it found, in the build nothing had run before.** Reading one module
from its artifact while compiling another from source is what an incremental
build *is*, and it had never been done with codegen on. The closure copies a
callee the emitting module does not own into its own unit with internal
linkage, and a def read from a `.iyimod` has no body to copy, so the copy was
a declaration with internal linkage, which is invalid IR. It is the same case
the C functions already had, and the rule is now the one that covers both: a
copy is private only where there is a body to copy.

**Where it is pessimistic, and why that is the honest edge.** Within one
invocation the compiler cannot know what a module it is about to recompile will
hash to, so a dependent of a rebuilt module is recompiled too rather than
checked against a hash that does not exist yet. Across invocations the finer
answer is the one above, which is the arrangement a build driver has, and the
reason the edges carry the hashes rather than the compiler carrying the graph.

**Granularity: module-level, for Draft 0.** Adding an unused `pub def`
invalidates dependents that never call it. That is pessimistic, and acceptable,
because what re-typechecking costs is a metadata read, not body analysis: the
expensive thing is already avoided. Per-declaration hashing with used-symbol
tracking is the known refinement (this is what salsa does) and should wait until
measurement says module-level is the bottleneck.

### IV.4 A result: coherence needs no global check

R-3 says an `impl Trait for Type` must live in the module defining the trait or
the type. Separate compilation raises the obvious worry: if module T and module
Y each define `impl Show for Foo`, neither can see the other, and the clash is
only discovered at link time, or never.

**It cannot happen.** Suppose trait `Show` is in module T and type `Foo` in
module Y. The impl may live in T or in Y.

- For T to define it, T must name `Foo`, so T imports Y.
- For Y to define it, Y must name `Show`, so Y imports T.
- Both would mean T imports Y and Y imports T: a cycle, which R-1 forbids.

So at most one module can define any given impl, **by construction**. The
compiler now refuses the cycle rather than leaving that step of the argument to
the load order that happened to hide one module's names from the other (III.5
rule 1).

The argument needs both T and Y to exist, and the build found the case where
neither does: a trait the compiler owns, or a prelude type, belongs to no
module. Taking the top level to be a module in their place is what broke this,
every module counts as inside it, so nothing was ruled out and any number of
modules could write `impl Error for String`. The top level is therefore not a
module (III.1.1): where a side has no module, that side cannot be satisfied,
and an impl with no module on either side is rejected wherever it is written.
That restores the premise rather than adding a rule.

The DAG and the orphan rule together make duplicate impls unrepresentable, and
coherence is checkable locally from the impl records in IV.2. No global pass, no
link-time surprise, no cost at build time.

This is the payoff for accepting R-3's restriction, and it is worth stating
plainly because it is not obvious that the orphan rule buys anything beyond
knowing a type's method set.

### IV.6 Notes from implementing the parser

Three things only surfaced once the syntax was fed to a real lexer. Recorded
because they are the class of problem a spec cannot find by reasoning.

**1. `/` in module paths collides with regex literals.** After an identifier,
Crystal's lexer treats `/` as the start of a regex, so `module app/user` lexes as
`app` followed by `DELIMITER_START`. Module paths are the one place `/` separates
rather than divides, so the parser suppresses regex mode while reading a path.
Go sidesteps this by putting import paths in string literals; Rust by using
`::`. Keeping `/` is a deliberate choice. It mirrors the filesystem, and it
costs a two-line workaround.

**2. `abstract def` for trait requirements.** See II.6; a bare signature is not
distinguishable from a default method without unbounded lookahead.

**3. Module paths are absolute, resolved from the project root.** Not relative
to the importing file. This only surfaced when a module two levels deep
imported a sibling: a relative reading resolved `app/greeter` against
`app/`, looked for `app/app/greeter`, and failed. The deeper point is that a
relative reading makes a path's meaning depend on where it is written, so two
files can disagree about what `app/greeter` refers to, which defeats the
purpose of having module identity at all. Go takes the same position. Until iyi
has a manifest, the project root is the directory of the entry file.

**4. Namespacing makes `using` mandatory, not a convenience.** II.3 presented
`using` as the thing that keeps DSL-shaped libraries writable. Implementing
namespaces showed it is more basic than that: the moment `module app/greeter`
actually scoped its contents, every cross-module reference broke, and the
working test had to be rewritten to
`impl App::Greeter::Greet for User` / `App::Greeter.polite(name)`. Without
`using`, ordinary multi-module code is unbearable, not merely verbose.

**5. Module functions need `extend self`.** A `pub def` at module level is a
function of the module, not an instance method of a mixin: iyi modules are
compilation units, not mixins. The desugar inserts `extend self` so
`App::Greeter.polite` resolves.

**6. Declaring a module and naming one. SETTLED: the mismatch stays, and is
made reversible. Built.** A module is declared lowercase (`module app/greeter`)
but reached capitalised (`App::Greeter`), because Crystal type names must be
constants. Three answers were available: accept the mismatch, adopt Go's
convention where the last path segment is the name, or teach the type system
lowercase module names. The third is the better language and does not fit
0.1.0; the second replaces a cosmetic problem with a real one, since
`app/greeter` and `web/greeter` would then be one name.

So the mismatch stays, and stops being a wart by being made **reversible**: a
path segment is `[a-z][a-z0-9]*` with single `_` between groups, checked in
`Parser#parse_module_path`, which is the one gate `module`, `import` and
`using` all pass through. `camelcase` upper-cases the first character of each
underscore-separated group and drops the underscores, so a name splits back
into a path at every upper-case letter, and path and name determine each other.

**"Lowercase snake_case" was not the rule, and finding that out is why it was
checked rather than asserted.** `camelcase` drops an underscore that precedes a
digit, so `v_1` and `v1` both give `V1`. Two paths, one module, a collision
that survives any amount of care about naming style. Doubled, leading and
trailing underscores collide the same way (`my__greeter` with `my_greeter`,
`my_` with `my`). Requiring each group to begin with a letter removes all four
cases at once.

**7. New keywords are cheap, but not free.** `trait`, `impl`, `pub`, `import`
and `using` were added to the lexer with no regressions: `trailing`,
`implements`, `public`, `usingx` and `impl_` all still lex as identifiers. But
`impl` was in use as a local variable in two compiler tool files, which had to be
renamed. Every keyword iyi adds is a name taken away from every program; the
count should stay small.

### IV.5 Versioning

Format version in the header, and it is not migrated: a `.iyimod` whose format
number is not this compiler's is rejected and rebuilt. Cross-version metadata
compatibility is a large, permanent surface and there is no reason to take it
on before 1.0.

**What two compilers have to agree on is the release, the target and the
flags.** Every build of iyi 0.1.0 reads every other build's artifacts, on the
same target and under the same flags. That is what makes a module something to
hand to somebody: the artifact is the unit R-1 compiles against, and a unit
only its own build could open would be a cache with extra steps.

The three are one rule and not three. Macros branch on flags, so an artifact
built under one set answers questions differently from one built under
another; object code is a target's; and a release number is what names a
compiler in public.

**A development version keeps the build commit, and that is the same rule
rather than an exception to it.** `0.2.0-dev` is not a release: it names every
compiler between two of them, and two of those can disagree about anything at
all. So `0.1.0` is an identity and `0.2.0-dev+9bcbb359f` is one, while
`0.2.0-dev` on its own is not, and a build that carries it interoperates with
nothing but itself.

A build told no commit at all — compiled outside a checkout, or by something
that does not pass one — has nothing to add, so its `-dev` version stands
alone and is the weakest identity here: it will read another such build's
artifacts. That is the honest end of a best-effort answer rather than a hole
worth closing, because the case it covers is a compiler nobody released and
nobody can name.

The version is iyi's, read from `src/IYI_VERSION` at compile time rather than
from the environment, because two binaries in this repository write artifacts
and an equality test between them cannot depend on how each was invoked.

---

## Part V: Not yet specified

Named honestly, so nobody mistakes this draft for complete.

1. ~~Export metadata format.~~ **Specified in Part IV.** Remaining sub-question:
   the concrete binary encoding, which is engineering rather than design.
2. ~~Trait generics and associated types.~~ **Settled by II.6**: both forms
   exist; associated types for single-answer traits, parameters where multiple
   impls are the point.
3. ~~Trait default methods.~~ **Settled by II.6**: traits supply bodies, with
   their own type parameters and conditional `where` bounds.
4. ~~**Module initialisation order.**~~ **Specified in III.5**: DAG order, a
   relative order between independent modules that is unobservable rather than
   merely unspecified, no `init()`, no import for side effects, and
   initialisation that may not fail. All but "no import for side effects" are
   built, the shuffle that keeps the unobservable order unobservable included.
   That last one is the only rule here with a cost and no measurement.
5. ~~**Concurrency semantics.**~~ **Specified in III.4**: structured
   concurrency so a leak is unrepresentable, cancellation owned by the scope
   rather than threaded through signatures, task failure as an ordinary error
   member, and a `Share` marker that makes a data race a compile error. The
   module-level state question the Kemal port flagged is answered by III.4.5:
   the combination does not compile. Proposed, not built, and III.4.7 names the
   count that has to come first.
6. ~~**Macro cost.**~~ **Measured: see II.10.** Expansion is not a compile-time
   cost worth policing: a template macro is indistinguishable from writing the
   code, and a computing macro costs less per method than defining the method
   does. `macro_run` is the exception, at a fixed +7.4 s per distinct script on
   a cold build. The measurement record has no gaps left.
7. ~~Stdlib naming convention.~~ **Settled by III.1.7(A)**: `!` has left
   identifiers and the mutating/non-mutating pair is `sort` / `sorted`. Settled
   while no stdlib code existed yet, which was the whole point: it is a
   convention the entire library has to be designed around from the first
   commit, and it is now enforced by the compiler rather than left to style.
8. **`defer` semantics.** ~~Ordering of multiple `defer`s in a scope, and
   whether a `defer` may itself propagate with `!`.~~ **Both answered as Go
   answers them, LIFO and no**: LIFO because it is the reverse of acquisition
   order, and no because a `defer` runs while the function is already returning
   (Appendix B #7). Both are built (III.1.4), along with one departure from Go:
   the scope is the block, not the function.

9. **The link step, whose linker.** A warm build is 0.17 s and 0.13 s of it is
   `cc`, which is 76% of the wall clock and the largest single thing left
   (0.1.0 item 2). What it is *not* is iyi's own code. Linking a one-object C
   program on this machine costs the same figure, and of iyi's link, merging
   its eleven objects with `ld -r` costs **0.004 s**. Writing the 36 KB output
   is another 0.004 s. **The remaining 0.12 s is the system part**: `Scrt1.o`,
   `crti.o`, `crtbeginS.o`, `libgcc`, `libgc`, `libc.so.6`, a dynamic linker to
   name and a `.dynsym` to build.

   That decomposition is the whole design question, because an own linker
   inherits the 0.12 s rather than the 0.004 s. Four ways out were priced,
   and then the 0.12 s turned out not to be the link either.

   **Answered: it was the driver, and the compiler now builds the link
   itself.** `cc` takes 0.129 s where the command it would run takes 0.014 s
   with `ld.bfd`, 0.009 s with `ld.gold` and 0.023 s with `ld.lld`: three
   linkers within 14 ms of each other under a driver worth 0.11 s. The
   compiler asks `cc -###` once for the command, caches it as a template and
   runs `ld` from then on; the warm build goes 0.186 s → 0.081 s and the
   linking stage 0.143 s → 0.019 s (0.1.0 item 2). What follows is the
   costing as it stood before that, kept because the four routes are still the
   map, and because (b) and (d) are what is left if the remaining 0.019 s ever
   matters:

   **(a) A faster linker, which the compiler already prefers.**
   `use_modern_linker` looks for `mold`, then `ld.lld`, and passes
   `-fuse-ld=` for whichever it finds. Neither is installed here, so every
   figure above is `ld.bfd`. **Cost: nothing to build.** It is a packaging
   question, it is the first thing to try, and it is the only one of the four
   that needs no design. One wrinkle from this session: the probe's answer is
   cached against `PATH`, so a `mold` installed into a directory already on
   `PATH` is picked up when `PATH` next changes, or when the cache file is
   removed.

   **(b) lld inside the compiler's own process.** The compiler already links
   LLVM, and `lld` is the same project's linker with a library interface, so a
   build could link without spawning anything and without the driver, the
   `collect2` hop and the LTO plugin. **Cost: three to five days**: a C++ shim
   beside `llvm_ext.cc`, translation of the flags the compiler already computes,
   a fallback for platforms without it, and a build dependency on lld's
   libraries pinned to the LLVM version, which is a second version coupling to
   maintain. `liblldELF` is not installed here either, so this cannot be
   measured before it is chosen.

   **(c) iyi's own linker.** The 0.004 s says that merging what iyi emits is
   nearly free; the 0.12 s says everything else belongs to the system part, and
   an own linker has to do all of it: PIE start files, `libgcc`'s archives,
   `libc`'s symbol versions, TLS, `.eh_frame` and its index, RELRO,
   `--gc-sections`, and every dynamic table the loader reads. **Cost: months,
   and a correctness burden that never ends** (lld's ELF port is tens of
   thousands of lines; mold's is larger), for the same 0.12 s that (a) buys for
   the price of a package. Go did this, and Go could: it owns its object
   format, its runtime and its calling convention. iyi owns none of the three
   while it emits LLVM objects and links against libc.

   **(d) Not linking on a rebuild.** Patch the previous executable instead of
   producing a new one, which is where the edit-build loop actually lives.
   **Cost: weeks on top of (b) or (c)**, since it needs an in-process linker to
   patch from, and it is the hardest of the four to be sure of. A stale byte
   in a binary that runs is the worst failure mode in this document.

   **What would change this ranking is one measurement nobody here can take: a
   machine where `ld` is not this slow.** `go build` produces the equivalent
   program end to end in 0.09 s on this machine, so the link alone costs more
   than everything Go does; a native Linux box usually links this program in
   0.01–0.02 s, and at that figure the question is closed by (a) and the rest
   is not worth designing. **The recommendation is (a), then (b) if the number
   survives it, and (c) for no reason this section can find.**

10. **Two compilers at once.** Builds run while other builds were running
    failed at the link, asking for a `_main.o0.o` nobody had written, and once
    with "No such file or directory" out of the object emitter. Neither message
    named the cause, and an hour went into reading linker output for something
    the linker had not done. It was blamed on parallel codegen, because that is
    what the failing builds had in common.

    **Answered: the cache cleaner was deleting a running build's directory.**
    Crystal keeps the ten most recently modified directories in the cache and
    removes the rest, at the end of every compile. A build's directory stops
    looking recent while its units sit in an optimization pass writing nothing,
    so with ten other builds inside that window, one compiler process removes
    the directory another is writing its object files into. Reproduced
    deliberately by removing the directory mid-codegen: the same two failures,
    and the single-threaded path fails the same way, which is what cleared
    parallel codegen of the charge. It was never a race between threads; it was
    a race between processes.

    A build already declares the directory is its own. It holds `compiler.lock`
    there for the whole of codegen and linking, and the cleaner now reads it
    (`cache_dir.cr`, spec in `spec/compiler/compiler_spec.cr`). Checked against
    unpatched Crystal on the same setup: the held directory is deleted there and
    kept here, and an equally old directory nobody holds is still evicted, so
    the cache still shrinks.

    Two smaller things came out of the same hour. A codegen thread that raised
    used to print its exception and leave the build to fail later at the link,
    so the failure is now kept and raised as what it is. And it is worth saying
    what the bug was not: not the artifact's, not iyi's, and not the
    threads'. It is upstream, any Crystal user who builds two things at once can
    reach it, and that is where the fix belongs as well.

    **The same message, a second cause, and this one explains the reports that
    started it.** `Crystal.relative_filename` shortens a path by chopping the
    working directory off the front of it, and it chopped whenever the path
    merely *began with* the directory's name. Build in `/tmp/x/crystal` with a
    cache in `/tmp/x/crystal-cache` — a sibling, not a child — and every object
    file is written to `-cache/…`, which is nowhere. LLVM says "No such file or
    directory" and names nothing, so the build fails exactly as it does when
    somebody deletes the directory. Only a separator makes a prefix a
    directory; it says so now, with a spec in `spec/compiler/util_spec.cr`.

    The cleaner race above is real and reproducible by removing a directory by
    hand while a build writes into it. What it is not is the thing that caused
    the failures that started the hunt, which were runs whose cache directory
    sat beside the working directory under a name beginning the same way. Two
    confident wrong answers before the right one — parallel codegen, then the
    cleaner — and the reason both were possible is that the message named no
    file. `compile_to_object` names it now, and this is the third bug in this
    document found by making an error say what it was doing.

11. **The interpreter. Removed.** Crystal ships one, and the fork inherited it:
    11,377 lines under `src/compiler/iyi/interpreter`, 380 more of libffi
    bindings, 7,981 lines of specs, a CI workflow that builds it and runs the
    standard library's specs under it four ways, and a libffi build dependency
    on every platform.

    **What it was worth here, measured before deciding.** It was already
    compiled out: the Makefile passes `-Dwithout_interpreter` unless asked
    otherwise, so no shipped binary contained it. It cannot run iyi. Given the
    simplest program in `samples/`, it stops on line 12 with `BUG: missing
    interpret for Crystal::ModuleHeader`, which is R-1, the first rule this
    language has. And nobody had noticed: of the 153 commits between the fork
    and this one, **none** touched the interpreter, while the parser, the AST
    and the semantic passes took 7,840 lines of change. It interprets Crystal,
    and the fork stopped writing Crystal a long time ago.

    That is the argument, and it is not about the 11k lines. **An interpreter is
    a second implementation of the language's semantics.** Traits with defaults,
    `impl`, `using`, error unions, `defer`, and the module header all have to
    exist twice or the second copy quietly means something else. The fork is not
    finished changing the language, so the price is not paid once.

    The cost of losing it is one thing, named honestly: compile-time evaluation
    has to start somewhere, and `macro_run` still costs +7.4 s per script
    (II.10). But the half that would have been reused is the machine
    (instructions, primitives, memory, casts), and the half that decides what a
    program *means* is `interpreter/compiler.cr`, 3,550 lines that would have to
    be rewritten for iyi whatever happened. It is in the history, one
    `git revert` away, and it will be a better starting point when there is an
    iyi to interpret. There is one now, and #25 chose the smaller evaluator
    instead (III.11).

    What came out: the compiler is 99,253 → **87,421 lines** (11.9%), specs
    211,749 → 203,640, one CI workflow and four interpreter steps in others, the
    `reply` shard, and libffi. The shipped binary does not change size, because
    it never had it. What stays: the *macro* interpreter, which is a different
    thing that runs at compile time and is what makes `{% %}` work.

12e. **The library as an artifact. A measurement, not a plan.** IV.1d ends with
    a daemon that removes about 0.3 s of a `--crystal` build by holding the
    library analysed in a resident process. This document's own thesis says
    something else should be able to remove it: a library is a module, R-1
    compiles a module against declarations, and IV.1 already has a file for
    them. So the question was asked with a stopwatch rather than an argument.

    **The prize.** A generated module the shape of a library — 103,002 lines,
    5,000 exported methods across 1,000 types, bodies in the proportion
    Crystal's own library has them, which is *declarations at about 5% of the
    source*. Consumed from source and then from its `.iyimod`, front end only:

    | | from source | from its artifact |
    |---|---|---|
    | Semantic (top level) | 0.349 s | **0.077 s** |
    | Semantic (type declarations) | 0.043 s | **0.006 s** |
    | front end, all of it | 0.43 s | **0.11 s** |
    | peak memory | 163 MB | **25 MB** |

    Four times faster and six times smaller. Set that beside the daemon on the
    same term: 0.47 s to 0.33 s, one and a half times, *and* 200 MB resident per
    prelude held. The artifact wins on both axes, and it wins the second one in
    the other direction — it spends less memory where the daemon spends more.

    The ratio is not a property of the generator. It follows from declarations
    being 5% of a library's text, which is measured: Crystal's library is
    195,833 lines and about 11,886 of them are a `def` or a type header.

    **What it would take, also measured.** `crystal tool bind` already writes a
    `.iyimod` for a Crystal namespace compiled under Crystal's library (item
    12). Pointed at three of them, it reports how much of the public surface
    crosses with nobody's help:

    | | public methods | crossing unaided |
    |---|---|---|
    | `JSON` | 247 | **90.3%** |
    | `YAML` | 291 | **78.0%** |
    | `URI` | 105 | **58.1%** |

    What the remainder waits on is *named*: the tool prints which types are
    missing and what declaring each unlocks — `IO` +13, `Int` +12, `Tuple` +4,
    and so on. That is a work list rather than a research problem. Those are the
    corrected figures. The note below is what they were, and why.

    > **Asked again, and the work list was flattering the core.** The tool read
    > each restriction as the text somebody typed, and a method inside
    > `JSON::Token` writes `kind : Kind`. That is `JSON::Token::Kind` — the
    > shard's own, already travelling — and it was counted as a type nobody had
    > declared. `self` was counted the same way, and a method returning `self` in
    > `URI` returns `URI` and waits for nobody. Every such spelling pushed the
    > count in one direction: *towards the core*, which is the claim the count
    > was here to support. Published first: `IO` +11, `Int` +11, `Tuple` +4.
    >
    > Restrictions are resolved against the owner now, and the same three
    > namespaces answer differently — this is the boundary the tool can write
    > today, not the percentage above:
    >
    > | | crossing before | crossing now | still waiting |
    > |---|---|---|---|
    > | `JSON` | 142 | **152** | 57 → 47 |
    > | `YAML` | 142 | **158** | 60 → 44 |
    > | `URI` | 41 | **48** | 18 → 11 |
    >
    > The percentages do not move, and that is the check that this changed what
    > it claims to: they measure whether a *human* has to write a signature, and
    > resolving a name somebody already wrote does not change that. 33 more
    > signatures cross, and nothing stopped crossing except two `YAML` entries
    > returning a bare `Array` — which is a correction too, because a
    > declaration that says `Array` without saying of what is not one a consumer
    > can use.
    >
    > **And the work list, once it is true, says one word.** `IO` is first in all
    > three and by more than it was: +13 for `JSON`, +21 for `YAML`, +8 for
    > `URI`. That is 42 signatures against 21 for everything generic
    > (`Slice`, `Tuple`, `NamedTuple`, `Set`) and 20 for the whole numeric tower.
    > About four fifths of what these three ask of the top level is *not*
    > generic — `IO`, `Int`, `Time`, `Float32`, `Float` — which is to say the
    > declaration machinery this tool already has is the machinery that would
    > carry it. The generic remainder is IV.2's problem rather than this one's.

    **And the blocker that is not a percentage.** `tool bind` takes a root
    namespace, and the types every one of those signatures actually names —
    `String`, `Array`, `Int32`, `IO` — are not in a namespace. They are the
    top level. So the missing 10% of `JSON` and the missing 42% of `URI` are
    largely the *same* missing thing, and there is no root to point the tool at
    for it. Crossing a namespace is measured and mostly done; crossing the core
    is unstarted, and it is what everything else is waiting on.

    > **Most of that core was a list, and the list was wrong.** `nameable?` —
    > the question the whole count rests on — asked a literal kept beside the
    > tool: sixteen names said to be what an iyi program already has. It claimed
    > `Void`, `UInt32` and `Float64`, which iyi's prelude never declares, and it
    > left out `Slice`, `Int`, `Tuple` and `NamedTuple`, which `Program#initialize`
    > creates for *every* program before the first line of any prelude is read.
    > Those four were most of what the boundary appeared to be waiting on. The
    > list did not merely understate the answer; it invented the work it was
    > being read to size.
    >
    > It is asked of the program now — `builtin_type_names`, snapshotted where
    > those types are made, so a built-in added later is in it without anybody
    > remembering. What the same four namespaces answer:
    >
    > | | crossing | waiting on a type | taking one no variable can hold |
    > |---|---|---|---|
    > | `JSON` | 152 → **168** | 47 → **13** | 18 |
    > | `YAML` | 158 → **166** | 44 → **32** | 4 |
    > | `URI` | 48 → 48 | 11 → **9** | 2 |
    > | `IO` | 157 → **270** | 140 → **5** | 22 |
    >
    > The percentages do not move, again, and for the same reason. No signature
    > that crossed stopped crossing.
    >
    > **The third column is this correction catching itself.** Written first
    > without it, the table said 182, 168, 48 and 286 — because a name being
    > writable is not the same as a variable being able to hold it. `Int` is the
    > head of a family: a method taking one is compiled once per member, with a
    > symbol apiece and no single symbol to declare. The compiler already
    > answers this, `can_be_stored?`, and it is the same answer that decides
    > whether the keep file this tool generates compiles at all — which is how
    > it was found, by generating one and compiling it.
    >
    > **And pointing it at a class found three things a namespace never did.**
    > The tool assumed its root was a module, because a shard's root is one: it
    > reopened `IO` as `module IO`, and called `IO.write` — an instance method —
    > on the class. It declared `IO::Encoder`, which is private. And it counted
    > the signatures above. None of the three is visible from the counts; all
    > three are visible the moment the keep file it generates is compiled, which
    > is now how this is checked. `crystal tool bind -e IO` writes an artifact
    > and an object file end to end.
    >
    > It carries `IO` itself now, which took saying the difference out loud: a
    > module's own methods *are* module functions and a class's are its type's,
    > so a class root travels as one declaration holding everything under it —
    > `IO`, with `IO::Memory` and twelve more inside. 14 types, 148 methods, and
    > 311 symbols in the object file. What still stays behind is its constants,
    > which cross as functions whose symbol comes from `extend self`, and only a
    > module has that.
    >
    > Finding this also fixed something the shard path had all along: the keep
    > file never descended into nested types, so a nested declaration promised
    > symbols nothing emitted. `JSON`'s artifact holds 16 types and the file
    > reached 9 of them. It was a link error waiting rather than a compile one,
    > which is why no sample had found it.
    >
    > **`IO` is the whole of what is left, and `IO` is nearly done.** It is the
    > only name still blocking all three namespaces — 14, 22 and 9 — and pointed
    > at directly it is 442 public methods, 80.3% of them needing no human, with
    > five signatures waiting: `Time::Span` and `File::Info`, and nothing else.
    >
    > **And then the boundaries compose, which is the measurement closing.**
    > `tool bind` reads the artifacts already written — `--use-iyimod`, the same
    > switch a build uses — and a signature naming one of their types waits on
    > nobody. Each name is checked against the program rather than trusted,
    > because a class root's declarations are absolute and a module root's are
    > relative to a name the file does not record.
    >
    > | with `IO`, `Time` and `SemanticVersion` bound | crossing | waiting |
    > |---|---|---|
    > | `JSON` | 168 → **181** | 13 → **0** |
    > | `YAML` | 166 → **192** | 29 → **2** |
    > | `URI` | 48 → **55** | 7 → **0** |
    >
    > And the unlock report predicted it exactly. `JSON` reads `IO +13` and
    > gained 13; `URI` reads `IO +7` and gained 7; `YAML` reads `IO +20`,
    > `Time +5`, `SemanticVersion +1` and gained 26. The prediction is made by
    > counting what one declaration would free and the result by actually
    > freeing it, so the two agreeing is worth more than either — it is the
    > report and the composition checking each other.
    >
    > `Time` and `SemanticVersion` bind the same way — 446 public methods at
    > 86.1% and 22 at 95.5%. A `JSON` boundary written against `IO`'s is 16
    > types, 140 methods and 301 symbols, and its keep file compiles.
    >
    > **What is left, with all three bound and the count finally saying only
    > what it means.** A name that is not a type is not work, and counting `T`,
    > `self` and `_` beside `IO` said there was more waiting than there was —
    > the same inflation as the list, one layer further in. Split apart:
    >
    > | | crossing | waiting on a type | no variable can hold | not a type | block unannotated |
    > |---|---|---|---|---|---|
    > | `JSON` | **181** | **0** | 18 | 0 | 0 |
    > | `YAML` | **192** | **2** | 4 | 3 | 1 |
    > | `URI` | **55** | **0** | 2 | 1 | 1 |
    >
    > **And an artifact nothing had ever read back.** Every check this tool
    > carried was a number it printed, and a number cannot say whether anything
    > can consume the artifact printed beside it — so nothing did, and the first
    > spec written for it failed. Three things were wrong and all three are the
    > same sentence: *what an artifact declares belongs to the artifact.* A
    > module root kept the producer's prefix (`MyLib::Entry` with no `MyLib`,
    > because an iyi module path camelcases back to `Mylib` and `JSON` is not in
    > that mapping's image at all); a field crossed as `IO+`, which is dispatch
    > and not a name; and a reference to another boundary used the producer's
    > name where the consumer's was needed. A `JSON` boundary written against
    > `IO`'s is consumed by `import json` on its own now.
    >
    > **And then it linked, and the last step named its own limit.** A program
    > built from a bound shard runs: `MyGreeter.polite` called from iyi through
    > the four steps this tool prints, which had never been taken end to end
    > before and did not work when they first were. Two of the fixes were the
    > printed commands themselves — an unquoted `$(...)` that split every symbol
    > containing a space, and a module name made by `downcase` where the inverse
    > of `camelcase` was wanted.
    >
    > That second one is the whole constraint, once it is seen. Both sides mangle
    > alike — the premise the boundary rests on — so `Greeter.polite` is
    > `*Greeter@Greeter::polite<String>:String` from either language *only if the
    > consumer's module is `Greeter`*. A consumer builds that name by camelcasing
    > the path it imported, so the path has to be `camelcase` run backwards.
    >
    > **And what was written here first said an acronym could never be, which was
    > wrong.** The claim was that the mapping's image is names like `Greeter` and
    > `MyGreeter`, that `JSON`, `YAML`, `URI` and `HTTP` are outside it, and that
    > the library-as-artifact thesis waited on a question about iyi's module
    > paths. None of that is true, and the mistake was reaching for
    > `String#underscore` and then reasoning about *its* image instead of
    > `camelcase`'s. `underscore` answers `json` for `JSON`, and `json`
    > camelcases back to `Json` — but `camelcase` starts a group at every
    > upper-case letter, so the inverse of `JSON` is `j_s_o_n`, which is a legal
    > iyi path and comes back whole. So is `u_r_i`, and `h_t_t_p_server` for
    > `HTTPServer`, which `underscore` had flattened to `http_server` and lost.
    >
    > A shard named `ABC` links and runs. The wrong sentence stood for one commit
    > and named a language question that did not exist; what it was really
    > describing was a one-line inverse written with the wrong function.
    >
    > **And a second name mismatch under it, found the same way.** A module
    > written `extend self` puts its functions on the module and mangles
    > `*Widget@Widget::polite<String>:String`; one written `def self.polite`
    > puts them on the metaclass, and that has no `@`. The tool recorded both as
    > the first, so every `def self.` in a shard declared a function the consumer
    > called by a name nothing emitted. Crystal's library is written the second
    > way throughout, which is why nothing smaller than `JSON` had shown it.
    >
    > **What `JSON` still waits on is not a name but an instantiation.** With
    > both mismatches gone the two sides agree on `*JSON::parse<...>` — and
    > disagree inside the angle brackets: the producer's keep file passes the
    > declared parameter, a `(String | IO)` union, and gets
    > `<(IO+ | String)>`, while a consumer passing a string literal gets
    > `<String>`. A method's symbol carries the types at its *call site*, so a
    > union parameter has one symbol per way of calling it and a keep file forces
    > only the one it names.
    >
    > The file names all of them now — the product of the parameters' shapes,
    > which measures smaller than it sounds: a union parameter is about one in
    > twenty, 7 of `IO`'s 103 and 1 of `JSON`'s 53, so two in one signature is
    > rare and the product stays small. `JSON.parse("...")` called from iyi links
    > and the symbol is there.
    >
    > **And past the names, a hole that no name check would have found.** With
    > every symbol matching, `Store.plain(41)` answers 42 and
    > `Store.from_constant(1)` segfaults. Crystal initialises a constant from
    > `__crystal_main` and compiles the reads unguarded; the consumer has its own
    > `__crystal_main` and never calls the shard's, so the constant stays null.
    > `LIMIT = 10` survives because the compiler folds it; `TABLE = ["a", "b",
    > "c"]` has to be built at run time.
    >
    > **Written here first as a silent wrong answer, which it is not.** The exit
    > status being read was a `printf`'s rather than the program's — a mistake in
    > the measurement and not in the compiler, and the second one of that shape
    > this section has had to record. It crashes, loudly, on the first read.
    >
    > **And running the shard's initialisation does not fix it.** Renaming
    > `__crystal_main` out of the way with `objcopy --redefine-sym` and calling
    > it from the consumer segfaults *inside* the initialisation, before reaching
    > any constant: Crystal's top level expects Crystal's runtime — a thread, an
    > event loop, the exception machinery — and an iyi program, whose whole
    > prelude is 1,053 lines, is not one. So this was never about naming the
    > constants in the artifact, which is what it looked like from the outside.
    >
    > **And the other direction closes it.** A consumer built with `--crystal`
    > *is* a program with Crystal's runtime, which is what the shard's
    > initialisation was missing — so that ought to be the answer. It is not:
    > the link then fails on `Crystal::Hasher::seed`, `Thread::threads`,
    > `Fiber::fibers` and every other runtime global, defined once by the
    > consumer and once by the shard.
    >
    > So the two failures are one fact seen from either side. **The object this
    > pipeline makes is a whole program**, because a keep file is compiled like
    > one, and it carries the library with it. A program can have that library
    > once: without it the shard's state never starts, with it nothing links.
    > Neither the names nor the constants were ever the problem — the packaging
    > was.
    >
    > That is a sharper statement than "a boundary carries code that needs no
    > initialisation", and it names what would change it: the shard has to be
    > compiled the way `.iyimod` already compiles an iyi module — object code per
    > unit, against a library left external — rather than as a program somebody
    > then picks symbols out of with `nm`. `ObjectCode` is in the format for that
    > reason and `tool bind` does not write it.
    >
    > **And that was tried, one type of it, which is the cheapest question that
    > separates a wall from a work list.** An ordinary build of the keep file —
    > not `--emit obj`, which merges everything into one object — leaves 363
    > per-type units in the cache, one of them `Store`'s. Linked into an iyi
    > consumer on its own it gives a *clean* failure rather than a collision or a
    > crash, and the whole of what it asks for is twenty symbols:
    >
    > | | |
    > |---|---|
    > | type ids | 15 |
    > | constants | 4 |
    > | a main-module helper | 1 |
    >
    > Every one is a category the format already carries a section for —
    > `TypeIds`, `Constants`, and the helpers item 12d has the consumer emit with
    > its own numbering — and `tool bind` writes all three empty. The unit itself
    > carries no runtime, exports its method already global (so the `objcopy`
    > step is not needed at all in this shape), and leaves `Store::TABLE`
    > undefined for the consumer to define, which is exactly the arrangement that
    > makes an initialiser run in the right program.
    >
    > **The remaining catch is named rather than guessed at.** Four of those
    > constants are Crystal's own — `Int::DIGITS_BASE62` and its neighbours,
    > reached because `Array#[]` can raise and raising formats an integer. A
    > consumer can only define them if it has Crystal's `Int`, which is the
    > library-as-artifact question again. But it arrives here as twenty symbols
    > in three known categories rather than as a duplicate runtime, and that is a
    > different kind of problem to have.
    >
    > **And then the work list was worked, and it runs.** `--emit-bind` on the
    > keep file's build puts the per-type units into the artifact, with the type
    > ids and constants they refer to, using the collectors an iyi module's
    > artifact has always used. A consumer links what the artifact carries. So:
    >
    > ```
    > crystal tool bind -e ABCGreeter --emit-bind mods shard.cr
    > crystal build --iyi-keep ABCGreeter --emit-bind mods -o keepbin abc_greeter_keep.cr
    > iyi build --crystal --use-iyimod mods -o app app.iyi
    > ```
    >
    > That program prints what the shard returns. **Two commands, no `nm` and no
    > `objcopy`**, where the four printed steps had been and had never worked.
    > `spec/compiler-cli/bind-pipeline_spec.cr` runs it, and needs no binutils to.
    >
    > `--crystal` on the last line is the other half of what was learnt: the unit
    > numbers `Pointer(LibUnwind::Exception)` whatever the shard does, because a
    > `String#+` can raise. So the artifact is marked `crystal_library: true`,
    > which it always was — it was written `false` on the argument that a
    > boundary stands *between* Crystal's library and the consumer, and that
    > argument does not survive looking at what the unit refers to.
    >
    > **And the constants cross too, which was the last of it.** A constant
    > travels by *name* so its initialiser runs once, in the program that will
    > read it — and a name was only half, the half a bound shard was missing. Its
    > unit refers to `Store::TABLE` and defines nothing. So the assignment
    > travels as well, in the artifact's initialiser, which the reader renders
    > last and inside the module: `TABLE = [...]` under `module store` is
    > `Store::TABLE`, in the namespace the shard wrote it in and built by the
    > consumer's own program.
    >
    > `Store.word(1)` answers `one`. Two turns earlier the same call segfaulted
    > on the first read, and the turn after that it was refused by name. Its own
    > constants only: a unit refers to Crystal's as well — `Int::DIGITS_BASE62`,
    > reached because `Array#[]` can raise and raising formats an integer — and
    > those belong to the library the consumer already has.
    >
    > **And then it was given, because the premise was wrong.** iyi takes an
    > `enum` — the language has one, the compiler makes the type — and what it
    > did not take was `pub enum`, so a module could declare one and never hand
    > it out. The claim below that iyi has no enum came from grepping the prelude
    > and finding none, which is a fact about the prelude and not about the
    > language. `pub` takes one now, an artifact carries its members and the
    > integer they are numbered on, and an iyi program calls
    > `Store.bigger(Store::Kind::Large)` and is answered `true`.
    >
    > The numbers are read from what the compiler assigned rather than
    > renumbered: the object file the consumer links is what gave them their
    > numbers, and a boundary that renumbered would agree with it by luck.
    >
    > **A private type travels as private, which is a third thing from
    > travelling and from being dropped.** `JSON::PullParser` holds an
    > `Array(ObjectStackKind)`, so its object code numbers
    > `Pointer(ObjectStackKind)` — a consumer has to *number* a type it must
    > never *write*. Declared without `pub`, both are true at once. Dropping them
    > was the first answer, and the only thing that said otherwise was `ld`.
    >
    > **`JSON` binds whole now**: 21 units, 11.4 MB, 116 type ids, 28 constants,
    > with `JSON.parse` among its functions once `IO` is bound first. What it
    > does not yet do is *run*, and the reason has moved again — `--iyi-keep IO`
    > forces the whole of `IO`'s surface, and the keep binary that results does
    > not link, on `Crystal::EventLoop::Polling` internals a demand-driven build
    > would never have reached. The units are written after a successful link, so
    > `IO`'s artifact stays empty of object code. `--cross-compile` skips the
    > link and emits no per-type units either.
    >
    > That is the next thing, and it is about *when* the units are taken rather
    > than about names or types: a boundary needs the objects, not the program
    > they would have linked into.
    >
    > **So it does not link.** A build carrying both `--iyi-keep` and
    > `--emit-bind` exists to fill a boundary, and the keep file is not a program
    > anybody runs. `IO`'s artifact fills — 18 units, 14.8 MB, 92 type ids — and
    > every boundary build stops paying for a link nobody wanted.
    >
    > **And then the thing that had been measured turned out to be the wrong
    > thing.** `IO` and `JSON` are Crystal's library, and a consumer built with
    > `--crystal` *has* Crystal's library: `require "json"` and
    > `JSON.parse("[1,2,3]").as_a.size` answers 3 with no artifact anywhere near
    > it. Binding them measures how well a boundary can hand a program something
    > it already has.
    >
    > What a boundary is for is a **shard** — a library the consumer does not
    > have — which is what `tool bind -e Kemal` was written for and what the
    > fixtures in `bind-pipeline_spec.cr` are shaped like. Those cross whole:
    > functions both ways round, a union parameter, constants at the root and
    > inside a type, an enum, and a nested type with its own methods.
    >
    > For the library itself the artifact's value is *speed* rather than reach,
    > and that is 12e's question, measured at the top of this item — not
    > something the last few turns were testing.
    >
    > > **So it was asked of a shard, which is what a boundary is for.**
    > > `bench/bind_speed.py`, and the first thing it found was that `Kemal`
    > > cannot be bound at all: its object code numbers
    > > `Array(Radix::Node(Array(Kemal::FilterHandler::FilterBlock)))` — a
    > > generic instance from *another shard* — and a generic travels as bodies
    > > rather than as declarations. Binding `Radix` first does not help: it is
    > > generic throughout and its artifact carries no types. That is IV.2's
    > > problem arriving where a real library keeps it.
    > >
    > > What `tool bind` does say about `Kemal` is worth keeping: 254 public
    > > methods, **93.3% needing no human**, 26 types carrying 63 methods, and
    > > 31 units of object code.
    > >
    > > So the speed question went to a generated shard of stated size, and the
    > > answer depends on one thing:
    > >
    > > | shard | from source | from its boundary | |
    > > |---|---|---|---|
    > > | 2,167 lines | 1.11 s | 1.13 s | costs 2% |
    > > | 10,087 lines | 1.31 s | 1.20 s | saves 9% |
    > > | 29,767 lines | 1.94 s | 1.72 s | **saves 11%** |
    > >
    > > A boundary pays once compiling the shard is a real share of the build,
    > > which here is somewhere near ten thousand lines, and the share grows with
    > > size. Below that it costs a little: reading a megabyte of artifact and
    > > linking twenty objects is not free, and there was nothing to save.
    > >
    > > **And then the generics, which is what `Kemal` had stopped on.** IV.2
    > > already says what a generic does: its methods exist once per
    > > instantiation, the instantiations belong to whoever writes them, and the
    > > bodies travel as source in `MonoBodies`. `tool bind` was not using it —
    > > it skipped a generic type in three places — so `Radix` carried nothing
    > > and `Kemal` waited on a type nobody had declared.
    > >
    > > It carries them now, declaration and bodies both, and a generic crosses:
    > > `Bag.wrap(7).item` answers 7 from a consumer that compiled
    > > `Holder(Int32)#item` itself, out of source the producer sent. `new` stays
    > > behind because it is synthesized from `initialize` and a carried one
    > > would meet the consumer's own at the linker — which IV.2 had already
    > > written down.
    > >
    > > **A generic with no methods travels too**, and that was the second thing
    > > wrong: an empty one was dropped, when naming is itself what a consumer
    > > may need. `Kemal` refers to `Array(Radix::Node(...))` and calls no `Node`
    > > method. `Radix` carries three types now where it carried none.
    > >
    > > What a generic's methods must have is a **written return type**. The
    > > trick that rescues an ordinary method — instantiate it on purpose and
    > > read what comes back — has no single answer when the owner is generic, so
    > > 20 of `Radix`'s 33 methods stay behind. That is R-2 landing hardest
    > > exactly where inference cannot help.
    > >
    > > **The requires travel now**, Crystal's only: one that resolved into
    > > somebody else's `lib` is another shard, and replaying it would have the
    > > consumer compile from source the thing an artifact exists to spare it.
    > > Those arrive as import edges instead — and one of those edges was
    > > invisible. `Kemal` names no `Radix` type in any declaration and its
    > > object code refers to `Array(Radix::Node(...))`, so the dependency shows
    > > only in the type ids, which only the build that fills the object code
    > > knows. It reads the boundaries sitting beside it and adds the edge.
    > >
    > > **And `Kemal` still does not link, for a fifth reason, which is the one
    > > worth stopping on.** `Kemal::Route` does not travel, and the tool has
    > > been saying why all along: *left out, because their fields name what an
    > > iyi program cannot*. That sentence encodes an assumption this item has
    > > since disproved. `nameable?` asks what an **iyi-prelude** program could
    > > name — but the consumer of a bound shard has to be `--crystal`, because
    > > the units number `Pointer(LibUnwind::Exception)` whatever the shard does.
    > > Such a consumer has the whole of Crystal's library, and now the shard's
    > > requires as well.
    > >
    > > So the measurement of what crosses has been made against the wrong
    > > consumer since the tool was written, and it read low.
    > >
    > > **Asked of the right one, with nothing bound first:**
    > >
    > > | | crossing | waiting |
    > > |---|---|---|
    > > | `JSON` | 168 → **181** | 13 → **0** |
    > > | `YAML` | 166 → **194** | 32 → **0** |
    > > | `URI` | 48 → **55** | 9 → **0** |
    > >
    > > None of the three waits on anything anybody could declare. `Kemal` goes
    > > from 27 types carrying 65 methods to **34 carrying 148**, and what it
    > > waits on is down to three names, every one of them another shard's:
    > > `Radix::Tree`, `Radix::Result`, `ExceptionPage::Styles`.
    > >
    > > Two things had to follow it. A top-level name of Crystal's is written
    > > `::Log`, because these declarations are rendered inside their own module
    > > and `Kemal::Log` is a constant that shadows the class — the compiler said
    > > so in those words. And a generic carries the types nested inside it,
    > > which is how `Kemal::LRUCache::Node(K, V)` went missing while `LRUCache`
    > > travelled.
    > >
    > > **`Kemal` still does not link, and this one is not settled.** With its
    > > three shards bound the chain reaches an *import cycle*: every artifact's
    > > units number the others' instantiations — `Radix`'s number
    > > `Result(Kemal::Route)`, which is Kemal's instantiation and not Radix's —
    > > and read as dependencies both ways that is a cycle, where an import graph
    > > is a DAG. Binding each shard from its own entry rather than from the
    > > app's removes it, which says the rule is partly about *how* a boundary is
    > > made; but the state of the directory being bound into still changes the
    > > answer, and a rule that depends on that is not a rule yet. It is the next
    > > thing, and it is the first one in this item that is about the *graph*
    > > rather than about a name or a type.
    > >
    > > **The first version of this measured nothing, and why is the useful
    > > part.** Its consumer called one method. Codegen is demand-driven, so a
    > > consumer that reaches one method has the compiler emit one — and a
    > > 30,000-line shard cost the same as a 2,000-line one, because 28,000 lines
    > > of it were never compiled by either arm. What a boundary saves is
    > > compiling *the code somebody uses*, so a benchmark that uses none of it
    > > measures its own consumer. The consumer calls all of it now, and the
    > > source arm scales with the shard where before it was flat — which is how
    > > the mistake was visible at all.
    >
    > > **Asked of the real shard, with the network.** Everything above was
    > > measured against `Kemal` in a checkout; `bench/shard_serves.sh` now
    > > installs it — pinned at 1.12.0, with `radix`, `exception_page` and
    > > `backtracer` behind it — and the first thing that produced was the
    > > README's headline example running: `require "kemal"` in an `.iyi` file,
    > > built `--crystal`, answering two routes over HTTP. Nothing here had
    > > checked that. The tarball job builds a *synthetic* shard, which proves
    > > the library ships whole and cannot prove a real shard's macros parse.
    > >
    > > **What it waits on is zero now, and the fix was a name shape rather than
    > > a type.** `bound_names` asked whether the program had a type by each
    > > name an artifact declares, and asked it bare. That is right when the
    > > root is a *class* — `-e ExceptionPage` declares `ExceptionPage`, and the
    > > program has one. It is wrong when the root is a *module*: `-e Radix`
    > > declares `Node`, `Tree` and `Result` at the artifact's own top level,
    > > and the program has no top-level `Node`. It has `Radix::Node`. So
    > > `radix.iyimod` read as "6 types, **0** this program can name" while
    > > sitting in the same directory as a `Kemal` that names `Radix::Tree`
    > > eight times. Asked under the root as well, and recorded under it too
    > > because that is how the producer writes them: **`Kemal` 168 signatures
    > > and 12 waiting → 182 and 0**.
    > >
    > > **The import cycle is about order, which the run pins.** Binding
    > > `backtracer` last — after `kemal` was already in the directory — gives
    > > `Error: import cycle`, because the fill step reads the boundaries beside
    > > it and adds an edge in each direction. Binding in dependency order,
    > > `backtracer` → `radix` → `exception_page` → `kemal`, removes it. That
    > > is the same answer this item already guessed at; what the run adds is
    > > that the directory's *state at bind time* is the whole of it, and a
    > > boundary format that cannot say so is a rule waiting to be written.
    > >
    > > **And then a fifth thing, which is new, and the obvious fix for it is
    > > worse than the bug.** With the cycle gone the consumer fails on
    > > `undefined constant ::$Regex:0`.
    > >
    > > The chain is short and every link is somewhere in this tree. A regex
    > > literal becomes a program-level `Const` named `$Regex:N`, N assigned by
    > > the order the literals are met (`literal_expander.cr`). A unit that
    > > reads one records it, so `collect_iyi_constants` puts the name in
    > > `Constants`. The consumer emits a *read* of every name there, because
    > > that is how a constant crosses — the name travels and the consumer
    > > builds it — and `::$Regex:0` is not a name the consumer's program has.
    > >
    > > It cannot be carried as source either: `$` is not legal in a constant,
    > > and `Exports` is text the far side parses.
    > >
    > > **Dropping it from the list makes the build pass and must not be done.**
    > > Measured: with those names skipped the semantic error goes and the link
    > > gets two steps further. But the producer's object code still refers to
    > > the mangled name, and a `--crystal` consumer compiles Crystal's library,
    > > which has regex literals of its own numbered from zero in *its*
    > > encounter order. The reference would be satisfied by whichever constant
    > > mangles to the same name — a different pattern, silently. That is rule
    > > 1's "returns something of another type" one level down, and it is why
    > > the probe was reverted rather than kept.
    > >
    > > So the fix is an identity rather than a filter: a synthesised constant
    > > needs a name that means the same thing in a program that never compiled
    > > this source, and a channel that is not parsed source to carry its
    > > initialiser. **Both are built.**
    > >
    > > **The identity is the literal, not the module.** This paragraph said
    > > "unique to the module that made it" before it was tried, and that is
    > > the wrong half of the problem. The expander has no module: it runs over
    > > a whole program, and which of that program's types end up in which
    > > artifact is decided much later, by a flag. What it does have is the
    > > literal, so the name is `$Regex:` and a digest of the pattern and the
    > > flags. `$` still keeps it unwritable, which is the half the old name
    > > already had.
    > >
    > > Content addressing also turns the collision into the right answer
    > > instead of merely avoiding it. Two modules that both wrote `/\d+/`
    > > *should* share one constant, and under a module-qualified name they
    > > would define two. It costs nothing else: a digest is stable under build
    > > order, where a number is not — adding a file to a shard renumbered
    > > every literal after it and changed an artifact that had not changed.
    > >
    > > The initialiser travels in a `Regexes` section beside the names in
    > > `Constants`, as the pattern and the flags rather than as source, and the
    > > consumer builds the constant with the same `Regex.new` call the expander
    > > builds for a literal met in source. From there it is ordinary: typed
    > > when read, initialised where read.
    > >
    > > **Measured, because the name is the load-bearing half and the channel
    > > alone looks like it works.** With the channel in and encounter-order
    > > naming restored, two bound shards holding one literal each both wrote
    > > `$Regex:0`; the consumer can define one name once, so the second shard
    > > matched against the first one's pattern. Nothing raised, nothing failed
    > > to link, and the program exited 0:
    > >
    > > ```
    > > --- source ---        --- artifact ---
    > > alpha-[0-9]+          alpha-[0-9]+
    > > beta-[a-z]+           alpha-[0-9]+
    > > ```
    > >
    > > That is what the reverted probe would have shipped, now seen rather than
    > > predicted, and `bench/bind_regex_identity.sh` is the gate that holds it.
    > > It takes two boundaries: one can be wrong about the name and still right
    > > about the pattern, because there is nothing for it to collide with —
    > > which is why `bind_roundtrip.sh` could not have asked this.
    > >
    > > **And past it is not a name but a global.** With the constant built the
    > > consumer reaches the linker, and what it wants there is a *class
    > > variable*: `Regex::PCRE2::current_jit_stack` for a shard that matches,
    > > `Unicode::upcase_ranges` for one that calls `String#upcase`, and
    > > `Shard::Part::count` for one that keeps a counter of its own. That last
    > > one is the general case and it is not about binding at all — an iyi
    > > module with a class variable failed R-1's own round trip. **Built**, in
    > > IV.2, which is where a thing missing from `Exports` belongs;
    > > `Backtracer::configuration` below is the same finding reached from the
    > > other end.
    > >
    > > **And behind that one, two more — and reading them as a third kind was
    > > wrong.** With the class variables crossing, a shard that *matches* a
    > > regex still wanted `*Regex::PCRE2::current_jit_stack` and
    > > `Regex::MatchOptions:type_id`. Written up here first as the copy rule
    > > failing to bring a library method along, which it was not: the accessor
    > > *was* copied, and `nm` on the unit says so. What the copy calls is
    > > something else.
    > >
    > > `@@current_jit_stack` is `@[ThreadLocal]`, and a thread-local global is
    > > not read directly — it is read through a `noinline` function that hands
    > > back its address, because LLVM would otherwise hoist the address out of
    > > the thread. That function is the main module's, and a main module does
    > > not travel. It is the third thing a class variable owes, after the
    > > global and the read function, and it is in IV.2 with them.
    > >
    > > `Regex::MatchOptions` is an enum, and IV.1's "a program defines every
    > > type id" means every id it has *handed out*. Ids come from walking
    > > `Object`'s subclasses; that walk does not reach an enum, which takes its
    > > id from the first code to ask. A consumer that never mentions the enum
    > > never asks. Both are built, and `bench/bind_regex_identity.sh` matches
    > > with its patterns now rather than only naming them — which is the line
    > > that would catch either of them coming back.
    > >
    > > **The chain was run, and it binds.** All four shards installed from the
    > > network and bound in dependency order: `backtracer` **7 units**,
    > > `radix` **2**, `exception_page` **0**, `kemal` **36**. No cycle, no
    > > bind failure. `Backtracer::configuration` — named below as one of the
    > > two things left — was a *module's* class variable, and it crosses now.
    > >
    > > **What a consumer of that chain still waits on is four things, and none
    > > of them is a symbol nobody understands.** In the order they will have to
    > > be answered:
    > >
    > > 1. ~~**A module a unit numbers, whose declaration does not travel.**~~
    > >    and ~~**types with object code and no declaration**~~ — **both built,
    > >    and they were one thing.** `crystal tool bind` recorded a module as a
    > >    "nested namespace skipped" and carried nothing for it, so
    > >    `Backtracer::Backtrace::Parser` was a name the consumer could not
    > >    reach *and* `Kemal::Exceptions::CustomException` and three like it had
    > >    units in the artifact — 1.8 MB each — with no declaration anywhere.
    > >    The walk stopped at `Exceptions`, so both the namespace and everything
    > >    under it went missing at once.
    > >
    > >    A module travels as a declaration now, without `pub`: iyi's `pub`
    > >    takes a def, a class, a struct, a trait and an enum, and a namespace
    > >    owes only that the things *inside* it can be named, each carrying its
    > >    own visibility. **40 undefined symbols → 22.**
    > > 2. ~~**`~match<…>` for unions the consumer does not have.**~~ **Built.**
    > >    The same question as a type id, asked of a union — and unlike a
    > >    virtual type, which `iyi_define_all_match_funs` enumerates from the
    > >    program's own classes, a union cannot be enumerated: no walk over a
    > >    consumer arrives at `(Char | Iyi::Keyword | String | Nil)`, which is
    > >    a type kemal's code formed. `MatchTypes` carries the names and the
    > >    consumer builds each function with its own numbering, which is the
    > >    whole reason a name travels rather than a copy: a copy compiled by
    > >    the producer would compare the consumer's ids against the producer's
    > >    numbers and answer wrongly with no symptom. **22 → 11.**
    > > 3. ~~**A bound class's superclass does not travel.**~~ **Built, and it
    > >    was four things rather than one.** `TypeDecl` had no field for the
    > >    `<`, so a subclass arrived without its base and without the fields it
    > >    inherits — a class's own field list is only its own — and the
    > >    consumer said `undefined method 'tag' for Shard::Derived`.
    > >
    > >    The edge alone left three more, each a place that had only ever seen
    > >    a class with nothing under it. **A method is keyed on the type that
    > >    defines it**, because a boundary has one symbol per method and an
    > >    ordinary build makes one per receiver — the mirror of the parameter
    > >    rule already here. That symbol is keyed on the class's **virtual
    > >    form**, because a value of a class something inherits from is held as
    > >    one: the symbol is `*Shard::Base+@Shard::Base#tag`. And a class with
    > >    subclasses has a **second unit**, `Shard::Base+`, which is where the
    > >    methods reached through that form are emitted and which the artifact
    > >    was not carrying at all — so it also had to become an exported owner,
    > >    or its callees were never copied into it.
    > >
    > >    **The undefined symbol was the safe half.** A match against a virtual
    > >    type compares an id against the *range* its subclasses occupy, and
    > >    ids are assigned by walking that same tree — a consumer missing an
    > >    edge does not merely fail to define a function, it numbers the tree
    > >    differently. Defining the function anyway would answer `is_a?` wrongly
    > >    and link cleanly.
    > > 4. **`new` synthesised from `initialize`.** Already written down in
    > >    `collect_iyi_unit_names`, and it is what
    > >    `*Kemal::RouteHandler@Reference::new` was.
    > >
    > > **With those, two shapes were left that a boundary makes reachable and
    > > a whole-program build never does.** Both are the same widening seen from
    > > different places. A restriction that is virtual while the value is
    > > concrete — an `IO` parameter matched against `IO+` with an
    > > `IO::FileDescriptor` in hand — which `match_type_id` answers with the
    > > range rather than a single id. And the same widening asked of a *local*:
    > > inside a dispatch arm the slot holds the arm's concrete type while the
    > > read wants the declared one, and `visit(Var)` called `downcast` on it —
    > > `BUG: trying to downcast IO+ <- IO::Memory`.
    > >
    > > **Which of the two directions it is cannot be asked of `implements?`,**
    > > and asking it that way broke the compiler's own build: a virtual type
    > > implements its base, so `Iyi::Def+` in a slot read as `Iyi::Def` looked
    > > like a widening and is the opposite. What separates them is shape — a
    > > union or a virtual type is the wider thing — so widening is reading a
    > > *concrete* slot as one of those, and nothing else is.
    > >
    > > **A generic's declarations were kept out of the keep file with it.**
    > > `keep_type` skips a generic — rightly, since `uninitialized Holder(T)`
    > > is not a thing anybody can write — and skipped everything it *declares*
    > > along with it. Those have units in the artifact all the same:
    > > `Radix::Tree(T)` holds two error classes carrying 1.3 MB each, radix's
    > > keep file was **empty**, and the only `to_s` symbols it emitted were the
    > > ones radix's own code happened to reach — `to_s<IO::Memory>` and
    > > `to_s<IO::FileDescriptor>` — while the boundary declared `io : IO` and
    > > the consumer asked for the declared `to_s<IO+>`. A nested type is not
    > > parameterised by its container unless it says so, so the recursion is
    > > all it took. **Ten symbols to eight.**
    > >
    > > **And the type-id list is the import graph, which is why it cannot be
    > > filtered.** Two more went with one change. A module's id is its
    > > *metaclass's* — `Backtracer::Backtrace::Parser:Module` is how a module's
    > > metaclass prints — and carrying the instance and stopping there defined
    > > `…::Parser:type_id` for code that wanted `…::Parser:Module:type_id`; the
    > > walk that numbers metaclasses reaches only classes. And the list itself
    > > had been filtered to the kinds a consumer could not number for itself,
    > > leaving plain classes out on the reasoning that the consumer has them
    > > already. It has them only if it *imports the module that declares them*,
    > > and `add_bind_boundary_imports` derives that edge from this very list:
    > > `Kemal` numbers `ExceptionPage::Styles`, the name was filtered, no edge
    > > was added, and the consumer never read `exception_page` at all. The list
    > > is the dependency. Whole, it costs `Kemal` 303 names → 642, and a name
    > > is a string.
    > >
    > > **Asked of shards nobody here chose.** `jwt` and `bindata` bind clean —
    > > 14 units and 10 — and `habitat` binds at 3. Two limits showed up that
    > > kemal's four never touched, and both are about **force-instantiation**:
    > > the keep file exists to emit every method a consumer might call, and a
    > > shard can hold code its own compilation never types. `openssl_ext` has
    > > a `LibCrypto.x509_get0_signature` call whose argument is a pointer too
    > > deep, and Crystal's own `yaml` reaches `JSON::Error` from a method
    > > `require "yaml"` alone never instantiates. Both compile whole-program
    > > and neither survives being asked for everything. `tool bind` refuses the
    > > method — and **declared it anyway**, which is what put it in the keep
    > > file. What separates the two cases is who refused: this tool declining
    > > to ask (an unannotated block, a splat, a free variable) is not a defect
    > > in the method and those still travel, while the *compiler* refusing is.
    > > Dropped, `openssl_ext` goes from losing its whole artifact to **35
    > > units, 31 MB**, and the chain under `jwt` binds end to end.
    > >
    > > `yaml` is not that shape and still fails: its `@anchors` is typed by
    > > merging what *two* users of a shared module put in it, so no single
    > > method instantiation sees the error. That one is still open.
    > >
    > > It is no longer open, and it did not close the way this expected. `YAML`
    > > binds and fills; what was left was a link flag, and `Libs` is the
    > > section that carries it. `bench/yaml_reads.sh` holds it.
    > >
    > > **And a shard that reopens a library namespace carries only what it
    > > added.** `openssl_ext` is `OpenSSL`, and a `--crystal` consumer replays
    > > `require "openssl"` and gets Crystal's — so the declarations met the
    > > library's on `superclass mismatch for class OpenSSL::SSL::Error`, and
    > > then the constants met them on `already initialized constant
    > > OpenSSL::BIO::CRYSTAL_BIO`. What separates them is where a thing is
    > > *defined*: under the shard, or under the library. One the library wrote
    > > is neither declared nor assigned; one they both touch counts as the
    > > shard's, because what the shard added has to travel somehow.
    > >
    > > Behind that, a naming bug older than any of this and invisible until a
    > > superclass gave a nested type a name to resolve:
    > > `OpenSSL::PKey::PKeyError` stripped of the root is `PKey::PKeyError`,
    > > and that declaration is rendered *inside* `module PKey`, where it means
    > > `PKey::PKey::PKeyError`. The stripping goes a level deeper with each
    > > nesting now.
    > >
    > > What `jwt` waits on now is bigger than a `lib`, and worth naming
    > > exactly. `open_s_s_l` numbers `Pointer(LibCrypto::Bignum)`, and
    > > `LibCrypto` is a **top-level** `lib` of Crystal's that the shard *adds a
    > > struct to*. Carrying the addition is not carrying a type: an artifact's
    > > declarations are rendered inside its own module, so a `lib LibCrypto`
    > > written there is `OpenSSL::LibCrypto` and means something else.
    > >
    > > That is the general question this reaches, and it is not about C: **what
    > > a shard adds to a type it does not own.** Crystal shards do it — a
    > > method on `String`, a struct in somebody's `lib` — and every one of
    > > those additions belongs to a namespace the consumer already has from a
    > > different source. R-3 says iyi has no open classes, so there is no form
    > > for it to arrive in, and that is the wall `jwt` stands at.
    > >
    > > That wall has since been crossed — `Reopened` is the form, `jwt` signs
    > > and verifies a token through four boundaries, and `bench/jwt_signs.sh`
    > > holds it. The reading above is left as it was because the *shape* it
    > > names is the shape the answer took.
    > >
    > > **What it does not do any more is fail quietly.** The artifact left on
    > > disk has every declaration and no machine code, which read as a boundary
    > > promising a hundred methods and defining none — and it is
    > > indistinguishable from one that legitimately has none, since an abstract
    > > class with no subclass in its own shard is complete with zero units. The
    > > fill step records that it finished, and a consumer of an unfinished
    > > boundary is refused by name instead of being handed the linker's
    > > hundred.
    > >
    > > And a **stdlib-rooted** boundary is a third: `-e JSON` binds whole (24
    > > units, 14 MB) and a `--crystal` consumer of it replays `require "json"`
    > > from the artifact's own `Requires`, so the declarations reopen the real
    > > types — `can't reopen enum and add more constants to it`. The
    > > measurement those roots were bound for still holds; consuming one is
    > > `require "json"` with extra steps, and is not what a boundary is for.
    > >
    > > **The chain builds and runs.** Four boundaries — `backtracer`, `radix`,
    > > `exception_page`, `kemal` — installed from the network, bound in
    > > dependency order, and a program built against all four that prints what
    > > the same program prints built against their source.
    > > `bench/bind_chain.sh` is the gate, and nothing smaller finds what it
    > > finds: one boundary cannot collide with another's synthesised names,
    > > cannot have an import edge to get wrong, and cannot be a *class* root
    > > standing beside module roots.
    > >
    > > **The class root, which this item has carried as "the awkward one" the
    > > whole way, was one line and a wrong premise.** A module's declarations
    > > are wrapped in a `module <path>` header; for a class root that header
    > > camelcases to the class's own name, so the class arrived declared inside
    > > a module of the same name and every type under it gained a level.
    > > `Widget::Part` was `Widget::Widget::Part`. A class root needs no header
    > > at all — **the class is the namespace** — and iyi wraps a file in its
    > > module only when a header is there, so leaving it out puts the
    > > declarations where they belong. A `ClassType` is a `ModuleType`, so
    > > everything that looks a module unit up by name still finds it.
    > >
    > > Two things followed it, both from the same premise held elsewhere. The
    > > marker that says "this type came from an artifact" walked *into* the
    > > scope looking for the root's own name and found nothing, so a class root
    > > and everything under it went unmarked. And `bound_names` prefixed
    > > another boundary's types with its module path, which for a class root
    > > rewrote `Carrier` to `Carrier::Carrier` — with the prefix empty, the
    > > rewrite is a no-op, and the import edge that used to be recorded *when
    > > the text changed* is now recorded when the name is **met**.
    > >
    > > **And the last four symbols were four wrong answers to one question:
    > > what does an artifact actually define?** An artifact defines *more than
    > > it declares* — its own units call methods Crystal owns, so
    > > `RouteHandler`'s unit calls `FilterHandler#next=` and `next=` is
    > > `HTTP::Handler`'s — and *less than its types suggest*, because
    > > `Reference::new` is instantiated per receiver and exists only where
    > > something reached it. Assuming the first left
    > > `Kemal::FilterHandler@Reference::new` undefined; assuming the second made
    > > it a duplicate symbol; compiling a private copy in the consumer put the
    > > definition where `_main` could not see it. A `Symbols` section carries
    > > the mangled names each unit defines, and the consumer compiles
    > > everything else. **A list is not a rule and does not have a wrong side.**
    > >
    > > One more, and it is the reason a name travels rather than a number: a
    > > `~match` function is defined under the name that **travelled**, not
    > > under what the resolved type prints as here.
    > > `(Socket::IPAddress | Socket::UNIXAddress)` is a union in the producer
    > > and collapses to `Socket::Address+` in a consumer that knows those are
    > > all of `Socket::Address`'s subclasses — the same types, the same answer,
    > > a different symbol.
    > >
    > > **The counts on the way there**, since they are the only reason the
    > > order of the work was right: eleven undefined symbols after the
    > > superclass edge, ten after the keep file learned to reach past a
    > > generic, eight after a module's metaclass was numbered, then a refusal
    > > naming `ExceptionPage::Styles` once the import edge existed — and zero
    > > once the class root stopped nesting and the symbol list replaced the
    > > guessing. One note here said zero much earlier, and that was not a
    > > measurement: the build was dying before the linker ran, so nothing had
    > > been asked for.
    > >
    > > The refusal comes first and names its own cause: `"kemal" numbers
    > > `ExceptionPage::Styles`, and this build cannot name it`. With the edge
    > > added the consumer reads `exception_page`, and what it cannot do is
    > > *name* a type under a **class** root — the collision with its own module
    > > wrapper recorded below. That is where this goes next, and it is the same
    > > item as `exception_page` filling with 0 units.
    > >
    > > Behind it: four methods inherited from `Object` or `Reference` and
    > > synthesised rather than read (`new`, `to_s`), and one union `~match`
    > > whose members are both Crystal's own. The three virtual `~match`
    > > functions this item named before are gone, which is the superclass edge
    > > doing what it was built to do.
    > >
    > > **And the DSL is a separate question from all four.** `get "/" do …` is
    > > a top-level `def` of kemal's, outside `Kemal`, so a boundary rooted at
    > > `Kemal` cannot carry it: `import kemal` gives a consumer
    > > `undefined method 'get'`. That is about what a root *is*, not about what
    > > crosses one.
    > >
    > > **What the DSL is written on top of does cross now.**
    > > `Kemal::RouteHandler#add_route` takes `&handler : Context -> _`, and the
    > > scan that asks whether a signature's names can be written read `_` as a
    > > name — so every method whose block returns whatever the block returns
    > > was dropped. There is no single return type to infer for one either, and
    > > none is needed: a block-taking method's body travels and the consumer
    > > compiles it.
    > >
    > > Carrying that body found the older thing under it. `Def#body` stops
    > > being *source* as soon as anything instantiates it — `Route.new(…)`
    > > becomes `_.initialize(…)`, with a temporary for a receiver — so the body
    > > is recorded in the top-level pass, before any of that, and keyed on the
    > > name as well as the place: a synthesised `new` carries the location of
    > > the `initialize` it was made from. A block-taking `new` does not travel
    > > at all now, which is the same rule from the other side.
    > >
    > > `Route#initialize` followed it. Crystal reaches `initialize` through
    > > `new` and marks it not-public — fine while `new` travels, and it does
    > > not when it takes a block — so a block-taking `initialize` crosses now,
    > > and only that one: declaring it beside a `new` that also travels would
    > > be two ways to build the same type.
    > >
    > > **What a consumer driving the router waits on now is a *private*
    > > method, and it is three things rather than one.** `add_route`'s body
    > > calls `add_to_radix_tree`, which `RouteHandler` keeps to itself — and a
    > > body that travels calls the methods beside it. iyi's own side has
    > > carried those since the beginning (`carried_functions`, "a name nobody
    > > may reach is still a name the consumer has to typecheck a call
    > > against"); a boundary written by `tool bind` carries none.
    > >
    > > Tried, and each step named the next. A private method travels as
    > > `private def`, which is what it was — reachable from the body beside it
    > > and from nowhere else — and the keep file must not call one, because
    > > Crystal refuses that from outside the type. It needs **no verdict**: R-2
    > > asks its question of a surface a consumer writes against, and this is
    > > not one. Its parameters travel **as written**, restrictions and all,
    > > because `private def add_to_radix_tree(method, path, route)` has none
    > > and `?` is not a type. And its **body** must travel, since a declaration
    > > without one is a promise nothing keeps.
    > >
    > > That is where it stopped: the body reaches `@routes`, and
    > > `RouteHandler` crossed as a *handle* — a reference type carried without
    > > its fields, because one of them names a type the consumer could not
    > > write. A body that travels needs the fields the shard's own compiler
    > > had. So the three are one question: **what a travelling body is allowed
    > > to see.** It is the same question `carried_functions` answers on the iyi
    > > side, asked of a shard.
    > >
    > > **And the fields were a flag.** `tool bind` reads the boundaries beside
    > > it only when told where they are — `--use-iyimod mods` — and without it
    > > `Radix::Tree` is a name `Kemal` cannot write, so all three handlers
    > > crossed without their fields. With it, none of them does: **3 handle
    > > types → 0**, and `exception_page` gains its own. The report names the
    > > type and the field that did it now, because a count says three and a
    > > name says which three.
    > >
    > > **Carrying more of what a travelling body sees was tried and taken
    > > back.** With the fields in place the rest of it follows: a private
    > > method travels as `private def`, with no verdict — R-2 asks its question
    > > of a surface a consumer writes against and this is not one — with its
    > > parameters as the source wrote them and its own body, and a generic's
    > > methods travel the same way, since the consumer compiles them and reads
    > > their answer for itself. Each step worked and named the next: the
    > > private body, then `Radix::Tree#add` which had no declaration because a
    > > generic's methods were dropped for want of an inferred return, then
    > > `Node(T).new` which had none because a generic's `new` never travels and
    > > its `initialize` was not carried in its place.
    > >
    > > It stopped at `Node(T).new("", placeholder: true)`, and the whole of it
    > > was taken back rather than half-landed. Started again from there, the
    > > *generic* half of the question turned out to be separable and is built.
    > >
    > > **A generic can be built from its boundary now.** Its `new` is never
    > > carried — synthesised per instantiation, the consumer makes its own —
    > > and its `initialize` was not carried in `new`'s place. Three things were
    > > in the way and each is the same shape as something already here. A
    > > **default** did not travel, so a call that names one parameter and skips
    > > another met a declaration that had neither. A **type parameter** was
    > > recognised only as a whole restriction, so `T` passed and `(T | Nil)`
    > > did not and `Radix::Node(T)#initialize` never crossed. And a **private
    > > method a travelling body calls** had no declaration — `initialize` calls
    > > `compute_priority` — so a generic's private methods travel as
    > > `private def` with their bodies, which is what every one of a generic's
    > > methods already is.
    > >
    > > A *plain* type's private methods travel only where something that
    > > travels calls them, which is the rule that shape asks for — and the
    > > bodies are text, so the call graph is a word search. A private method
    > > travels if its name stands in a travelling body as a word, and then what
    > > *its* body calls travels too, to a fixed point. Reaching too far costs a
    > > declaration nobody uses; reaching too short is `undefined method`, so it
    > > errs long. `add_to_radix_tree` crosses now.
    > >
    > > **And the router works.** A consumer built against all four boundaries
    > > adds a route to kemal's, which is the DSL's own foundation. What it took
    > > was a chain: `add_route` takes a block, so its body is compiled here,
    > > and that body calls `add_to_radix_tree`, which kemal keeps private,
    > > which calls `Radix::Tree#add`, whose body calls a private overload of
    > > itself, which calls `Node#add` and a `protected sort!`.
    > >
    > > Three things were in the way and each was small. A body is found again
    > > by its **signature**, and a declaration's signatures are rewritten twice
    > > on the way out — so a key left behind was a body nobody found, and the
    > > link ended on `undefined symbol:
    > > *Radix::Tree(Kemal::Route)@Radix::Tree(T)#add<…>`. That was read here
    > > first as a symbol emitted with internal linkage being listed, which it
    > > was not. A **bare `*`** is a parameter with no name and written as
    > > nothing it is `, ,`. And **`protected`** is the same case as `private`:
    > > a name a travelling body may call and a consumer may not write.
    > >
    > > **An unannotated block travels too, where the body does.** R-2 refuses
    > > an exported signature without a block annotation because a consumer
    > > typechecking a call needs the shape; a method whose machine code is the
    > > caller's hands over the body instead, which is the shape. `Kemal.run` is
    > > `def self.run(…, &)` and the whole of running an app is behind it — it
    > > still does not cross, on a filter one further in, and that is where the
    > > *serving* example stands.
    > >
    > > `initialize` also travels where `new` could not be declared at all.
    > > `SharedKeyError#initialize(new_key, existing_key)` writes no
    > > restrictions, so its `new` is not a symbol anybody can name — and the
    > > rule was already here, in narrower words: a plain type's `initialize`
    > > travels where its `new` could not.
    > >
    > > Passing it opened one more, and it was a rewrite rather than a lookup.
    > > A boundary rewrites references to another boundary's types so the
    > > consumer reads them as it will see them, and the map is keyed on the
    > > *simple* name — so `radix` declaring a top-level `Node` made every bare
    > > `Node` in `Kemal` into `Radix::Node`, `Kemal::LRUCache::Node` included,
    > > and the consumer stopped on `wrong number of type vars for
    > > Radix::Node(T) (given 2, expected 1)`. A bare name in a shard's own
    > > source means its own, so the shard's names come out of the map. The gate
    > > binds the way a shard's author should now, and the counts beside it are
    > > **0 types without their fields** all the way down.
    > >
    > > **And `exception_page` filling with 0 units is not a bug.**
    > > `ExceptionPage` is an `abstract class` with no subclass in its own
    > > shard, so there is no machine code to carry: an abstract class's
    > > concrete methods are instantiated per *subclass*, and every subclass is
    > > somebody else's. That makes them the **third** thing whose body has to
    > > travel, beside a generic's and a block-taker's, and for the same reason
    > > each time. A consumer writing `class Report < Sheet` asked for
    > > `*Sheet+@Sheet#render` and nobody had made one.
    > >
    > > Two smaller things sat in front of it. The keep file *called* the
    > > abstract methods — `t0.title` on a class with no subclass has no type,
    > > and codegen said so as `BUG: … has no type` rather than as an error
    > > anybody could act on — and neither the method's nor the type's
    > > abstractness travelled, so a consumer read `def title` where the shard
    > > wrote `abstract def title`. Writing it properly needed one thing the
    > > language did not have: **`pub abstract class`**. Being abstract and
    > > being reachable are different questions, and a bound abstract class is a
    > > type a consumer subclasses and therefore has to be able to write.
    >
    > One thing binding the library did leave behind, and it is only reachable
    > from there: a *class*-rooted namespace collides with its own wrapper. The
    > artifact's declarations are wrapped in `module <path>`, and for `i_o` that
    > path camelcases to `IO` — which is a class, so reopening it as a module is
    > refused. A module root has no such problem, and a shard's root is one.
    >
    > **What `JSON` waited on, before that**, was written here as "iyi has no
    > `enum`" and that was wrong. With the units, the type ids and the constants
    > travelling, `JSON` bound to 19 units and stopped on `JSON::PullParser`'s
    > `ObjectStackKind` — and the reading of it was that the language had no such
    > type, so nothing on the far side could declare one. That came from grepping
    > the prelude and finding no enum in it, which is a fact about the prelude.
    > The language takes one, and a two-line program says so.
    >
    > What was actually missing was smaller and further in: `pub` did not take an
    > enum, so a module could declare one and never hand it out. Being wrong
    > about which of those it was cost a turn, and the shape of the mistake is
    > the one this document keeps recording — a claim about a language read off
    > the contents of a directory.
    >
    > One nested inside a type under the root crosses as well, written
    > `Inner::X = ...`. That was left out for a turn on the reasoning that a
    > qualified assignment reopens rather than defines — a guess, and wrong:
    > Crystal takes one wherever the namespace exists, and the declarations
    > rendered above this text are what make it exist. Two lines of experiment
    > would have said so, which is the whole argument for running them.
    >
    > A boundary carries code that needs no initialisation. That is the bound on
    > it today, and it is a larger claim than the earlier paragraphs implied.
    >
    > What still falls outside is a name the grammar cannot spell — `Foo_Bar`
    > needs two underscores running and `camelcase` reads two as one, so it comes
    > back `FooBar`. `tool bind` says so at bind time rather than leaving it to
    > `ld`, which is what the check was worth keeping for.
    >
    > `JSON` and `URI` wait on nothing anybody could declare. `YAML` waits on
    > `Set`, which is generic, and generics travel as bodies rather than as
    > declarations — IV.2's problem and not this one's. The middle column is
    > empty of work.
    >
    > The last column is the end-to-end check earning its place a second time. A
    > block-taking method is compiled per block *type*, so one whose block nobody
    > annotated has no single symbol; `infer_return` already refused those, but
    > only when it ran, and a method that writes its own return type never
    > reaches it. Nothing in the counts showed it. `Time`'s keep file did, by
    > refusing to compile: *`Time.measure` is expected to be invoked with a
    > block*.
    >
    > So the paragraph above is wrong in its last sentence and the correction is
    > worth more than it was. Crossing the core was not unstarted work that
    > everything was waiting on. It was a hand-written list claiming that
    > everything not in it was somebody's work to do — the same shape as the
    > prelude cache key in IV.1d, and found the same way, by asking what the
    > claim was resting on.

    **What this decides.** Not that the daemon should go — it works, it is
    tested, and it is what exists. It decides which of the two is the thing to
    build next, and the numbers are not close: on the term they both address the
    artifact is three times better and costs memory instead of spending it. The
    daemon is the answer a compiler reaches for when it has no file format. This
    one has a file format.

12d. **The ecosystem and R-1, together.** Item 12a ends by saying what stood
    between a program and having both. Three things did, and they turned out to
    be one thing asked three times: *a name in the module's object code that
    only the consuming program can define.*

    That is not a new question. `TypeIds` and `Constants` are already in the
    format because of it — a type id belongs to the program rather than to the
    module, so the module carries the *name* and the consumer supplies the
    number. Everything below is that rule, applied where it had not been.

    - **The main module's helpers.** `~match<IO+>` was the symbol. A unit that
      travels calls it and an artifact carries the unit, not main. Copying it
      would have been wrong for a reason worth stating: a match against a
      virtual type compiles to a comparison against a *range of type ids*, and
      those are the producer's numbers. A copy would have compared the
      consumer's ids against the producer's range and answered wrongly, with
      nothing to see. So the consumer emits them, with its own numbering,
      exactly as it emits every type-id global — all of them rather than the
      ones an object file asks for, because a build cannot see inside an object
      file, and each is two compares.

      This is what 12a's pure/stateful split got wrong. Purity was never the
      question; the question was whose numbering, and once it is asked that way
      the stateful helpers need no separate answer either — a constant's
      initialiser already runs once, in the consumer, because `Constants`
      already carries the name rather than the code.

    - **The module's requires.** A module that requires `uri` is compiled
      against `URI`, and its object code refers to `URI::Error.class:type_id`.
      A consumer that required only `json` has no such type to number, and the
      link fails on a name from a library nobody in the program ever asked for.
      So the requires travel — `Requires`, format v20 — and the consumer
      replays them, which makes its program a superset of the producer's. The
      numbering is still the consumer's, so this adds types and imports nobody
      else's ids.

    - **The `!dbg` location**, which 12a already fixed.

    **One thing had to be measured rather than argued.** A shared library is
    only shared if there is one copy of its state, and "it linked" would be
    just as true of a program with two copies of a lazily initialised constant
    — a program that is wrong and says nothing. It is one copy: `STDOUT` and
    `PROGRAM_NAME` are the same object on both sides of the boundary. The same
    compiler mangles the same names, the linker folds the definitions, and a
    lazily initialised constant goes through the global the consumer defines.
    Both identities are asserted in the specs, because that is the property,
    not a detail of it.

    **What is refused now is a different thing, and it is sharper.** An
    artifact records which library it was built against, and importing across
    is refused by name in both directions. This one is not a limitation to be
    lifted later: both worlds are compiled by the same compiler and mangle the
    same names, so a mixed program would link — on the names that happen to
    agree. `String` is a different type in each, and neither the linker nor
    anything after it would say so.

    **What it buys, measured rather than claimed.** A program can require Kemal
    *and* compile its own modules against their declarations, which is the
    combination the two features were each half of. The speed it buys is
    small, and saying so is the point of measuring: on a twelve-module app
    (656 lines, each module importing the last) with Crystal's library,

    | build | time |
    |---|---|
    | `require "json"` and nothing else | 3.12 s |
    | twelve modules from source | 3.28 s |
    | twelve modules from artifacts | 2.96 s |

    The modules cost 0.16 s from source and nothing from artifacts. Everything
    else is the library, read from source every build, and R-1 does not reach
    it. With Kemal in front the same twelve modules move a 4.4 s build to
    4.7 s — *slower*, because reading twelve artifacts and linking twelve
    object files is not free either, and there is only 0.5 s of module in front
    of 4 s of shard to pay for it.

    So: under iyi's own prelude the library costs 0.03 s and the artifact is
    the whole build; under Crystal's it costs 3 s and the artifact is a
    rounding error. The capability is what item 12d delivers. **The fixed cost
    of the other library is now the largest number in this document, and it is
    the next thing worth attacking** — not by making artifacts better, which is
    finished work, but by asking whether a library that every build reads from
    source has to be.

12c. **Portability, moved from compiled to run.** An iyi program produced code
    for nine targets and was tested on one, which is the weakest kind of
    portability claim: the code generator not objecting. Four of the nine now
    run in CI every build — x86-64 glibc natively, x86-64 musl in an Alpine
    container, aarch64 under emulation, and wasm32-wasi under wasmtime — and
    the check is that each prints what the same program printed on the machine
    that compiled it.

    What makes it cheap is the same thing that makes an artifact linkable: the
    object is produced here and linked there with the target's own `cc` and
    `libgc`, which is the command `--cross-compile` already prints. An iyi
    program needs no more of a target than a C toolchain and a collector.

    **Windows cost more than that, and what it cost is a lesson about the
    audit.** A Windows runner has the linker and the runtime this workflow was
    said to lack, so `x86_64-windows-msvc` was tried. It crashed, at
    `0xC0000005`, before writing anything — and it crashed for every program,
    including one whose entire source is `module w1`. That last measurement is
    what solved it: a program that declares nothing and runs nothing cannot be
    faulting in the allocator, the write path or `ExitProcess`, so the fault was
    not in the object at all.

    Two things were wrong, both outside the compiler's output. An LLVM-emitted
    object carries no `/DEFAULTLIB` directives, which an MSVC-compiled one
    would, so nothing pulls in `kernel32` or a C runtime and the `cl.exe obj
    /link` this fork prints for the target fails with seven unresolved
    externals. And with the libraries named, the choice of CRT decides it: the
    static `libcmt` links cleanly and faults before `main`, while the dynamic
    `msvcrt ucrt vcruntime` runs correctly. Same object, same linker, different
    library set, and one of them is a crash.

    So the audit's limit is now measured rather than asserted: reading what an
    object *asks for* tells you nothing about what happens when something
    answers.

    **And then Windows answered wrong, three different ways.** With the
    libraries named the linker is happy, and running the result is where it
    ends. The same binary, twenty runs, nothing changed between them: it has
    printed the right answer, printed `ache\w` — a fragment of a path from
    elsewhere in memory — where `HELLO, IYI!` belongs, printed `BEEP ` with the
    digits gone, and exited `0xC0000005`.

    The two wrong-output shapes are a case conversion and a number rendered
    into a string, which looked like a lead until a run access-violated: an
    intermittent AV on a program whose entire source is four lines is not a
    formatting bug, it is a wild write or a read through a pointer that came
    out of memory nobody set.

    The obvious theory is wrong and is recorded so it is not tried again: that
    `HeapAlloc` without `HEAP_ZERO_MEMORY` hands back dirty memory where
    Linux's bump allocator over fresh `mmap` pages hands back zeroed memory. It
    cannot be that on its own, because the POSIX path allocates atomically with
    plain `malloc`, which does not clear either, and macOS has never printed
    anything but the right answer.

    **The wild write has a name now, and it was found on Linux.** The
    prelude's own `memset` — the definition that intercepts the `memset`
    calls codegen's `llvm.memset` lowers to — advanced its `Pointer(UInt64)`
    by 8, eight *elements*, 64 bytes, while its counter recorded 8. Every
    runtime-sized clear wrote one word in eight far past its count and left
    seven of eight bytes dirty. That is both symptoms in one defect: an
    atomic allocation "cleared" at one-eighth coverage prints the memory it
    was never given, and the seven-out-of-eight overwrite past the count is
    a wild write into whatever neighbours the allocation — on Windows a
    packed `HeapAlloc` heap with metadata beside the chunks, which is
    `0xC0000005`. It also says why the platforms differ: darwin never
    defines its own `memset`, so libSystem's correct one answered there;
    Linux's bump allocator hid the overwrite in the untouched zero tail of
    its own mapping until the collector's arena gate burned a full region
    and found it; Windows had neighbours to trample from the first
    allocation. Fixed with the collector's merge, all three copies.

    The probe grew teeth with the fix: the twenty-run watch runs the two
    shapes 50,000 times, self-checked, so a packed-heap trample is probable
    rather than lucky, and it watched without failing until several builds
    in a row read twenty right and nothing else. Thirty-six in a row did —
    720 runs, 36 million self-checks, no wrong output, no crash — and the
    watch is a gate: a wrong output or a crash fails the build by its tally.
    The diagnosis is retired. What Windows is not is unchanged: not a test
    target, no collector (`HeapAlloc`, never freed), no threads.

    **wasm32-wasi had the same shape of defect and a smaller fix.** The module
    imports four `wasi_snapshot_preview1` functions and nothing else, and it
    linked — and trapped on `unreachable` before printing. wasi-libc's entry
    stub does not call `main`: clang renames a C `main` to `__main_argc_argv`,
    the stub calls that, and a module defining only `main` leaves the stub's
    weak reference unbound and traps the first time it is called through.
    Sixteen lines of prelude define the name the stub calls, and the program
    runs under wasmtime with the same output it has natively. And what this fork
    prints for the target is now `cc --target=wasm32-wasi` rather than
    `wasm-ld`, because only the driver can find the entry object its sysroot
    holds: printing a command that links a module no host can start is the same
    defect the Windows command had.

    Darwin was what remained unrun when this was written, the excuse being
    that macOS runners exist. They do, and it is run: `aarch64-darwin` has
    its own native job in the workflow (`darwin`, on `macos-14`), which
    builds the release compiler, holds the same gates a Linux push answers
    for, and ships the darwin tarball beside the Linux one.

12b. **What the library costs at run time, and the flattering answer that was
    wrong.** The tagline says Performance, and until now every number under it
    was about compiling. `bench/runtime.py` runs the same program under both
    libraries — same LLVM, same GC, same settings — and the first reading was
    that iyi's string building is **twenty times faster**. It is not. With
    `GC_DONT_GC=1` it is **1.64x slower**, and the whole of that twenty was the
    collector: a 17 KB binary has far fewer roots to scan than a 972 KB one, so
    a program that carries less collects faster. That is a real effect, it is
    the efficiency claim, and it is not a claim about `String`.

    What the honest column says on a later run of the same bench: arithmetic
    is within noise (0.96x), array work is ahead (0.78x), `String` is behind
    (3.62x), and `Hash` is ahead by 5x while doing less. The twenty-times
    as-it-runs reading did not reproduce; as they run, string building is
    now within noise (0.97x). The confound the first reading found is still
    the point: the collector is not the library.

    Kept here because the mistake is the point. A benchmark that measures a
    program and reports a library is the easiest way to publish a number that
    is true and means nothing, and the only defence is to take the thing being
    credited out and run it again.

12a. **The other answer, which is smaller.** A shard behind a generated
    boundary is one way to reach the ecosystem. The other is to give the
    program Crystal's standard library and compile the shard into it, and it
    turned out to be two small changes rather than a project.

    `require` was refused in a `.iyi` file, and the reason given was "there is
    no standard library to require: the prelude is what a program gets". That
    is true of iyi's prelude and of nothing else. `--crystal` builds a program
    against Crystal's, and there `require` means what it means in Crystal. A
    `require` also comes out of the module a header desugars to, the way
    `import` does: it is a directive about which files a build reads, and
    leaving it inside made json's `class String` mean `Site::String`.

    **The rules do not change with the library.** The module header, `pub`,
    `import`, `using`, traits, `impl`, R-2 on exports: all of them, on a
    program that requires Kemal. What changes is what a program *has*.

    **Swept across nine shards**, each built twice — as an iyi program and as a
    Crystal one, so that a difference is iyi's and a shared failure is
    the ecosystem's: `kemal`, `db`, `ameba`, `habitat`, `baked_file_system`,
    `radix`, `sqlite3`, the standard library's own `json`/`yaml`/`uri`/`http`,
    and a program that round-trips `JSON::Serializable`, parses YAML and writes
    a file. All nine behave identically in both languages. A Kemal server
    written in iyi serves HTTP.

    **One adaptation, and it is R-2 asking its question.** `habitat`'s macro
    resolves the type it was handed by name, and a class an iyi module left
    unmarked is private, so the macro could not find it. `pub class` fixes it —
    correctly, since a macro from another module reaching your type is exactly
    what `pub` governs.

    The message was `undefined macro method 'Path#constant'`, which names
    neither the type nor the rule. It is a fact about the compiler: an
    unresolved path stays a `Path`, and every method a macro would call on the
    type is undefined on that. **Fixed**: a macro method missing from a `Path`
    now asks whether the path names a type that exists and is unexported, and
    says so when it does. Only then — every other unresolved path keeps the
    message it had.

    **And then a real one was written**, because nine compiles are not nine
    programs: a small JSON API over Kemal, two iyi modules, storage in one and
    routes in the other. Creating, listing, fetching, and a miss answered
    `{"error":"no note 99"}` with a 404 — the miss travelling as `Note |
    NotFound` with an `impl Error for NotFound` on it, which is iyi's error
    union carrying a Kemal response. It found nothing of iyi's. The one thing
    it did find belongs to Crystal and reproduces there:
    `halt env, response: {error: found.message}.to_json` does not parse,
    because a `{` after a named argument in a call without parentheses is read
    as a block. A variable on the line before it is what a Crystal programmer
    writes too.

    **III.1.7(A) meets the standard library, and the bill is 49 names.** `!`
    left identifiers so that postfix `!` could mean propagation, and Crystal's
    library did not: `not_nil!`, `sort!`, `map!`, `select!`, `uniq!` and 44
    more cannot be called from a `.iyi` file. What comes back is not a mystery
    — `a.sort!` says "`!` has no error to propagate: no member of
    `Array(Int32)` implements `Error`" — and the replacements are what Crystal
    writes anyway: `a = a.sort`, `if home = maybe`, `maybe.as(String)`. Shard
    code is `.cr` and unaffected, so this is a rule about the lines somebody
    writes rather than the ones they depend on.

    Worth stating plainly because the convention was chosen (III.1.7) against a
    library iyi was going to write itself. It now also has to sit beside one it
    did not, and that is a cost the choice did not price.

    **And the prelude was not following its own rule.** `Array#sort` returned a
    copy and nothing mutated, which is Crystal's meaning under iyi's name. It
    sorts in place now and `sorted` is the copy, as III.1.7(A) says. The
    consequence is worth being blunt about: `a.sort` sorts here and copies
    under `--crystal`, silently, because Crystal calls the mutating one
    `sort!` and that name cannot be written here. It is the one call in this
    prelude that changes meaning with the library, it is noted in
    `src/iyi/array.iyi`, and `samples/iyi/basics.iyi` prints both halves.

    **What it costs.** R-1, for the required shard: it is read from source and
    the edit loop pays for it the way Crystal's does. The other cost — that a
    program could not have Crystal's library *and* its own modules as
    artifacts — was the sharpest limit here and is gone; item 12d is how.

    **Why, exactly — the first answer here was wrong.** It said the two builds
    would have "two of everything", which is not what happens. Taking the
    refusal out and looking:

    - The first failure was an LLVM module that would not verify: "inlinable
      function call in a function with debug info must have a !dbg location".
      The reads a consumer performs on an artifact's behalf (IV.1g) were
      synthesised without a location, and a call with no location inside a
      function that has debug info is invalid. Under iyi's own library the
      constants involved never landed in such a function; under Crystal's,
      `STDERR` and `String::CHAR_TO_DIGIT` did. **Fixed**: the reads carry the
      artifact's own path.
    - What is left is structural. A unit that travels can call helpers the
      compiler defines in the *main* module — `~match<IO+>` is the one that
      showed up — and an artifact carries the unit, not main. There are ten
      such helpers: type matching, constant reads and initialisers, class
      variable reads and initialisers, and a few more.

    **And the split proposed here was the wrong one.** It said the pure helpers
    could be copied into each unit and the stateful ones had to travel as
    names. Item 12d is what happened when that was tried: the axis is not
    purity, it is whose numbering — and the answer is the same for all of them.

12. ~~**Using Crystal code.**~~ **Specified in III.6; the direct source mode
    is measured in 12a.** An `extern module` restates R-2 by hand for the
    surface being used, the shard is compiled once behind it into an ordinary
    artifact, and the boundary is unchecked in the first version the way
    Gleam's is. Ordinary shard code breaks three of the four rules, which is
    why it cannot be a `require` in own-prelude artifact mode. `--crystal` is
    the separate source mode above.

    **The Crystal ecosystem, and what a shard would cost.** Ten thousand
    shards exist and none of them is written to iyi's rules, so "run them
    directly" is not a compatibility problem, it is the four rules: `require`
    against R-1, inference against R-2, monkey patching against R-3, and
    Crystal's 8,161-line standard library against iyi's own 17,511-line prelude.

    What is measurable is narrower and better than that framing suggests, and
    it was measured on **Kemal 1.12.0**, which compiles under this compiler
    unchanged, dependencies and all.

    **What the surface looks like.** `crystal tool bind -e Kemal` reads a
    shard and sorts its public methods three ways: written down already,
    writable by a machine, and needing a human. Kemal's 273 come out 74, 182
    and 17. The machine's share is not a guess — the tool instantiates each
    method whose parameters carry types and reads what it returns, which
    answered **125 return types nobody had written**. The 57 it refused are
    mostly honest: 40 take a block, and what a block-taking method returns
    depends on the block.

    **What blocks the rest.** 95 signatures can be written today; 104 wait on
    a type an iyi program cannot name, and the tool sorts those by what each
    one would unlock. `HTTP::Server::Context` is first and unlocks 16, then
    `IO` (9), `HTTP::Handler` (6), `Radix::Tree` (5). **Eight declarations
    unlock 49 of the 104.** That the head of that list is `Context` is the
    same answer the hand port reached in `samples/iyi/kemal/`: the framework's
    whole user-facing surface hangs on one type.

    **What crosses, measured.** The compiler is the same compiler, so a
    Crystal object links into an iyi program and the standard library works
    inside it: a `fun` calling `{"a" => 1}.to_json` answered correctly from an
    iyi `puts`. Objects cross too, because `String` is the *compiler's* type
    in both worlds — the prelude reopens what `Program#initialize` laid out.
    Two things do not cross by themselves, and both were found by trying:

    - **A separately compiled object brings its own runtime state.** Its
      `Crystal::Once`, `Thread` and `Fiber` are not the host's, its constants
      are filled by its own `__crystal_main`, and nothing runs it: reading one
      constant segfaults. The fix is mechanical and is the shim a generator
      writes — `fun shard_init(argc, argv)` calling `Crystal.init_runtime` and
      `Crystal.main_user_code`, with the object's own `main` localised so the
      host keeps the entry point. With it, a constant and a class variable both
      answer correctly.
    - **Layout is shared and invariants were not.** Crystal reads `@length == 0`
      on a non-empty string as "not counted yet" and scans; this prelude
      returned the field. So a string built by Crystal's `to_json` printed
      correctly through iyi's `puts` and answered `size` **0**. No error, a
      wrong number. **Fixed**: `String#size` counts when the field is unset,
      which is free for every string this prelude makes itself, because it
      fills the field. The same call now answers 7.

    **What crosses is more than a `fun`, and this is the finding the rest
    rests on.** The two sides mangle names identically, being one compiler:
    `Lib::Greeter.polite(String) : String` compiles to
    `*Lib::Greeter@Lib::Greeter::polite<String>:String` from Crystal source
    and from iyi source alike. So the boundary needs no C ABI at all. Measured
    end to end: a `.iyimod` written by `--no-codegen` (declarations, no object
    code), an object compiled from Crystal source with its symbol globalised,
    and an iyi program built with `--use-iyimod` against the first and linked
    against the second. It passes an iyi `String` in, gets one back, and
    prints it. `lib`'s C-types-only rule is not in the way because nothing
    goes through `lib`.

    **Where this is going.** `lib` carries C types only — Crystal's own rule,
    and it refuses `String` — so a real API cannot cross that way. It does not
    have to: an artifact already carries declarations *and* object code, and a
    shard compiled once with generated declarations is the same shape as a
    `.iyimod`. That is the boundary worth building, and R-1 is what makes it
    cheap: the shard is compiled once and the edit loop never reads it again.

    **Built far enough to run Kemal's own code.** `crystal tool bind
    --emit-iyimod` writes the artifact and the file that makes the machine code
    exist, and an iyi program built against the first and linked against the
    second called `Kemal::ExceptionPage.for_production_exception` and printed
    the page Kemal returns in production. Four things had to be true and each
    was found by trying:

    - **Codegen is demand-driven**, so a library nobody calls compiles to
      nothing. The generated keep file names every exported method and is never
      called.
    - **A getter whose body is one instance variable is inlined** and emits no
      symbol. `--emit-iyimod` already suppressed that for iyi modules;
      `--iyi-keep NAMESPACE` says the same about a bound shard.
    - **Symbols are local until an `objcopy`** globalises them.
    - **A reference type can cross without its fields.** A pointer is a
      pointer, so a consumer that never allocates one needs nothing of what is
      inside it — 16 of Kemal's 27 types travel that way, `new` withheld.
      A struct cannot: its size is its fields.

    **Kemal hands out everything through constants, and a constant is
    storage.** `Config::INSTANCE`, one `INSTANCE` per handler: a declaration
    can name a type but not a global somebody else's object file holds. So the
    generator writes a function per constant into the shim it already
    generates, and functions cross like any other:

        module Kemal
          extend self

          def config_instance : Kemal::Config
            Kemal::Config::INSTANCE
          end
        end

    `extend self` rather than `def self.`, because that is what an iyi module
    header desugars to and the two sides have to agree on one symbol:
    `Kemal@Kemal::config_instance` against `Kemal::config_instance`, which is
    the same distinction that makes a module function what it is.

    **A block crosses when its type is written, and that is not a detail.** A
    block-taking method is compiled per block *type*, and the type is in the
    symbol — `twice<Int32, &Proc(Int32, Int32)>` — so every consumer writing a
    block of the annotated type calls the one name the shard emitted. Measured:
    `twice(21) { |n| n }` runs across the boundary.

    A block written `-> _` has no such type. Each caller's block returns
    something else, each is a different symbol, and none of them is in the
    shard's object. **That is 32 of Kemal's 43 block-takers, and it is the
    whole DSL**: `get`, `post`, `error`, the filters. The hand port in
    `samples/iyi/kemal/` answers it with `forall B : IntoBody`, which is a
    person deciding what a route may return — R-2 asking its question, not a
    gap a generator can close.

    **Measured, on Kemal 1.12.0**: 15 module functions, 22 types carrying 50
    methods, and an iyi program that reads the framework's own configuration —
    `Kemal`, `3000`, `development`, `true`. What is left is two decisions per
    API rather than any missing machinery: what a `-> _` block returns, and
    what `HTTP::Server::Context` and a dozen more become on this side. 104
    signatures wait on the second.

    **What a travelling body costs, measured against `Kemal.run`.** A method
    that yields has no machine code of its own — the block is the caller's — so
    the consumer compiles the method from text, and everything that text names
    has to be there. Running a kemal app is behind one such method, and getting
    it across took nine fixes, each of which was invisible until the one before
    it landed. They fall into three groups, and the grouping is the finding:

    - **The tool did not know the body was travelling.** A block written `&`, or
      a bare `yield`, is the same fact as a block written `-> _`: nobody wrote
      the shape, so there is no single symbol. Two spellings counted and the
      third did not — and the third is how Crystal's own libraries are written.
      Worse, the question was never asked of `Kemal.run` at all: `args` has no
      type, so it was refused as a method a human must write before its block
      was looked at. That verdict is about *a declaration a consumer typechecks
      a call against*, which is exactly what a method whose body travels is not.

    - **Bodies were collected but not carried.** Module functions had a
      collector and no `MonoBodies` line. A module's own private functions had
      neither, though `Exports#carried_functions` was specified for that case.
      And a class's travelling `initialize` was collected after the search for
      what a travelling body calls, so nothing ever looked inside it.

    - **The two sides disagreed about what a declaration is.** R-2 refuses an
      exported signature with an untyped parameter because "the body is what
      stays behind" — which is the one thing that is not true of a `MonoBodies`
      entry. And the keep file tried to *call* these methods to force a symbol
      out of them, which cannot work twice over: it cannot synthesise an
      argument for a parameter with no type, and it cannot write a block for one
      whose arity nobody wrote. There is nothing to keep alive; that is what
      "the body travels" means.

    **Where it stops, and it is not machinery.** `Kemal.run` crosses with its
    body, and its body reaches `setup_404`, which calls `error` — a **top-level
    `def`** in kemal's `dsl.cr`, outside `Kemal`. `get` and `post` are there
    too, which is the whole DSL. A boundary rooted at `Kemal` cannot carry a
    method defined outside `Kemal`, and widening the root is a decision about
    what a boundary *is*, not a collector to write. The chain gate's consumer
    adds a route through the router's own API for this reason.

    Kemal's boundary carries 37 units where it carried 20.

    **A shard's top level is part of its boundary, and it needed a section of
    its own.** `get`, `post`, `error`, `ws` and `sse` are written outside every
    namespace — on `Object`, which is where Crystal puts a `def` nobody put
    anywhere — and a boundary rooted at `Kemal` cannot reach them. That is the
    whole DSL, and `Kemal.run`'s own body reaches one through `setup_404`.

    Where a declaration goes is not a property of the declaration, which is why
    this is a section (`TopLevel`, IV.1g) rather than a flag. The file of
    declarations opens with `module <name>` and never closes it: that is what
    puts everything below it *in* the module, and there is consequently nowhere
    in that file for something outside it. The reader parses a second text and
    accepts it where it stands.

    They travel **with their bodies, always**, and the reason is the same one
    that decides everything else here. Every other declaration names a symbol
    in the artifact's object code, and that code is per *type*: a shard's types
    each have a unit and the units travel. A `def` outside every namespace has
    no type, so it has no unit — it is compiled into the producing program's
    own main module, the one part of a build a boundary never carries.
    `render_404` crossed as a header and the link ended on `undefined symbol`.
    One with no body to carry cannot cross, and saying so is better than a link
    error.

    **A setter's answer is the value it was handed**, and R-2 has said so since
    it was written — it is why a setter is exempt from writing a return type.
    What was missing was a way to *carry* that answer. `property thing : Thing?`
    is `def thing=(@thing : Thing?)` whose body is `@thing = thing`, and an
    assignment's type is what was assigned; no single annotation says that, so
    `: (Thing | Nil)` is right for the declaration and wrong for every call.
    `config.server ||= HTTP::Server.new(…)` came out nilable. The body travels,
    which is what this whole part does whenever the answer depends on the
    caller.

    Two smaller rules came out of the same walk. **A body that travels needs
    what it calls, whatever the shard called it**: the search was written as
    "the private methods a travelling body calls" and visibility was never the
    question — `display_startup_message` is public, has untyped parameters, and
    so could not cross, which puts it exactly where a private one is. And **a
    superclass with the class's own name is written `::`**: nothing inherits
    from itself, so two identical names are two types, and
    `Kemal::ExceptionPage` extends the `exception_page` shard's own root.

    **Where it stood.** `Kemal.run` compiled, linked and ran across four
    boundaries, and stopped at run time in
    `HTTP::Server.new(config.handlers)`: the array reported `size 8` and
    `empty? false`, `first` and `last` answered the same object, and
    `handlers[0]` was out of bounds. That was read as virtual dispatch landing
    on the wrong method for `Array(HTTP::Handler)+`, a numbering question.

    **That reading was wrong, and the measurement that corrected it is the
    useful part.** Asked to hold one handler in a variable of the module's type,
    the consumer said `type must be HTTP::Handler, not Kemal::InitHandler`. The
    ids were fine; the *edge* was missing. `TypeDecl` carried `superclass` and
    nothing for `include`, so a class that mixed a module in stopped being the
    module's type on the way out — and where nothing asked directly, a virtual
    call went to whichever subtype the consumer did know. `class.to_s`
    answering `HTTP::CompressHandler` for seven handlers in a row is what
    dispatch against a tree missing its branches looks like.

    So an `include` travels, by `superclass`'s own argument one word further,
    and it brought the next rule with it: **an abstract `def` is a written
    signature, and the method answering it may lean on that.** `HTTP::Handler`
    writes `abstract def call(context : HTTP::Server::Context)`; kemal's
    handlers write `def call(context) : Nil`, which R-2 refuses for having no
    type to write down. R-2 says the answer already, for iyi's own impls: the
    trait wrote the types down, and a consumer types the call from the trait
    rather than from the implementation. A Crystal module's abstract method is
    the same sentence.

    **A header has no body, and two places forgot it.** `ParamParser`'s
    `new` takes `url : Hash(String, String) = {} of String => String`, and a
    call that omits it gets a wrapper: evaluate the default here, forward the
    whole list to the symbol. `expand_default_arguments` instead *retained the
    body* — which it does whenever an argument has both a default and a
    restriction — and a header's body is `Nop`, so the wrapper computed the
    default, returned it, and allocated nothing. The wrapper's body was then
    never typed either, because the fast path for an artifact def keys on the
    matched def, which is still the header. An untyped node becomes a `raise`
    in `CleanupTransformer`, so the program compiled, linked, and died on
    `can't execute` the first time a request reached it. A header's body is
    `Nop` and a wrapper's is not; that is the whole of the distinction.

    **Where it stands now.** `Kemal.run` runs across four boundaries, kemal
    binds its port and logs `Kemal is ready to lead`, and a request walks the
    entire handler chain in kemal's own order — `InitHandler`,
    `RequestLogHandler`, `HeadRequestHandler`, `ExceptionHandler`,
    `FilterHandler`, `WebSocketHandler`, `RouteHandler`.

    **A shard that adds to a type it does not own**, which is the last thing
    this item had left open. Kemal reopens `HTTP::Server::Context` and gives it
    `@params` and eighteen methods; a boundary carries none of the library's
    types on purpose, because the consumer replays the requires and has them,
    and declaring one twice is how a build stops on `superclass mismatch`. So
    the addition had nowhere to go: `undefined method 'params'` where the
    consumer's own code asked, and a field the consumer never allocated where
    the shard's compiled code did.

    The answer is the rule already used one level up, asked of a type's members
    instead of a namespace's types: **what the shard wrote travels, and what
    the library wrote stays**, decided by where each member is written.
    `Reopened` (IV.1g) carries it, rendered `class ::HTTP::Server::Context`,
    and with bodies — these methods are compiled into the *library's* unit,
    which a boundary does not carry, for the same reason a top-level `def`'s
    body travels.

    Three smaller rules came with it. **A member written by a macro belongs to
    the file that wrote the macro**: `macro finished` declares three of
    `Context`'s fields and their location is the expansion, so asked naively
    they were nobody's — and `Location#expanded_location` is that walk, which
    also brought `get` and `post` across. **A field travels with its default**,
    because the library's own `initialize` knows nothing about one the shard
    added. And **that default is written with its names resolved**, like every
    other text here, because it is read where the shard is not.

    **A delegating overload travels as its body.** `Kemal.run` is written four
    times; the two that take no block are `def self.run(args = ARGV,
    trap_signal : Bool = true)`, whose whole body fills in a default and calls
    the four-argument one. R-2 refuses them for `args`, and R-2's reason does
    not apply: a consumer typechecks a call *through* a travelling body, as the
    shard's own callers do. Narrow on purpose — the general form, "an untyped
    parameter is no reason to refuse a method whose body travels", would send a
    body for every method a shard left untyped, and that is a measurement
    nobody has made.

    **The measure, and it is a gate.** `bench/kemal_serves.sh` binds the four
    boundaries, writes the application the way kemal's README writes one —
    `get "/" do … end`, `Kemal.run` — and asks it for pages: a static route, one
    that reads a URL parameter, and one nobody wrote. Both arms answer `hello
    from a boundary`, `iyi`, `404`, and the gate compares them rather than
    trusting either.

    It asks for pages because every failure on the way here was a *quiet* one:
    a consumer that linked and then read a field nobody had allocated, a
    `class.to_s` that answered the wrong type for seven handlers in a row, a
    `new` that never ran an `initialize`. A gate that stopped at "it compiles"
    was green through all of them. The 404 is the deliberate half: it is
    kemal's own `setup_404`, which `Kemal.run` reaches through a private module
    function whose body travels.

    **What a shard adds to a `lib` travels**, which is this item's remaining
    open question answered rather than argued. `openssl_ext` reopens `lib
    LibCrypto` with a dozen C structs, two unions and a handful of `type`
    aliases, and a consumer stopped on `"open_s_s_l" numbers
    `Pointer(LibCrypto::Bignum)``.

    **Types only, and that is the finding.** A `fun` is a C symbol — `BN_new`
    is resolved by the system linker against `-lcrypto`, not by anything either
    side compiles — so a consumer that does not call one needs no declaration
    for it. What it needs is to *name* the types, because naming is what
    numbering is made of. A `lib` extension is then the same shape as
    `Reopened` rather than a new kind of thing.

    Two smaller rules came with it. A `lib`'s alias is `type Engine = Void*`
    where a class's is `alias`, and writing one without its right-hand side is
    `expecting token '=', not 'end'`. And **a class root keeps its class
    variables in its class** — they were written at the module level as well,
    which is right for a module root, that being no `TypeDecl` and having
    nowhere else to put them, and wrong for a class that is already carrying
    them.

    **`jwt` works, and `bench/jwt_signs.sh` holds it.** A program that imports
    `j_w_t` encodes a token, decodes it
    back and reads the header out of it, through four boundaries —
    `openssl_ext`, `bindata`, `bindata/asn1`, `jwt` — and answers what the same
    program answers from source. The gate builds both arms and compares them
    rather than trusting either, which matters more here than it does for
    kemal: a token is a signature over bytes, so a boundary that dropped a
    field or numbered a type differently does not crash, it signs something
    else. That is the second real shard to cross, and it
    is a different kind of shard from kemal: it is C-linked, it is written on
    macros that write classes, and it has an exception hierarchy. Eleven
    findings came out of it and each is measured below.

    **A body is what a method is, where the caller decides what the method is.**
    That was already the rule for a block whose type nobody wrote; the same
    question, asked of the arguments, is a parameter with no restriction, a
    splat, or a double splat. `JWT.encode(payload, key : String, algorithm :
    Algorithm, **header_keys) : String` is the whole of making a token, and R-2
    refused it and asked a human to annotate `payload` — but there is no
    annotation to write. The type is the caller's. Crystal compiles a member of
    that family per call site with the call site's types in the symbol, so
    there is no single symbol in the artifact to link against, and the body is
    the only honest declaration. The keep file learned the other half of the
    same rule: a signature with a splat, or a parameter whose type holds an
    `_`, is one there is no value to make and no symbol to keep alive.

    Two collectors had drifted apart, and the type side was the one behind. The
    module-function collector had read `storable` and "can this name be
    written" as questions about a method *called by symbol* since `Kemal.run`
    crossed; the type collector still read them as unconditional, so
    `OpenSSL::PKey::RSA.new(encoded : String, passphrase = nil)` was dropped
    over `passphrase` and a consumer got the one overload left: `expected
    argument #1 to 'OpenSSL::PKey::RSA.new' to be Int32, not String`. And a
    body-carrying `new` does not travel *because it is synthesised* — an empty
    receiver is what says so — where `openssl_ext` writes three of its own.

    **`initialize` travels where the `new` made from it did not, and "did not"
    is a question about a shape.** "Only where `new` is absent" held while the
    only `new` was the compiler's: one `initialize`, one `new`, and having
    either meant having both. `openssl_ext` writes two `def self.new` on
    `OpenSSL::PKey::PKey` and two `initialize` beside them, and the `new` made
    from `initialize(is_private : Bool)` is a fourth overload nobody wrote —
    refused, because an abstract class cannot be allocated. The name test saw
    two `new`s and called the type covered.

    **A constant's value is code, and code has a scope.** Two findings, one
    each side of it. The value travels as source, and the source it carries can
    call what R-2 held back: `openssl_ext` writes `GETS_BIO = begin … io_for(bio)
    … end` inside `class OpenSSL::GETS_BIO` and `io_for` is `private def self.`.
    The private-callee search already existed for travelling bodies — a
    constant's initialiser is one, and seeding it with them is the whole fix.
    And the value has to be the value as *written*: `CleanupTransformer`
    replaces an array literal with what it expands to, so `bindata`'s
    `KLASS_NAME = [ASN1::BER::ExtendedIdentifier]` reached the format as five
    statements over three temporaries and the consumer said `undefined local
    variable or method '__temp_829'`. That is the same correction a class
    variable's initialiser already carries, one field over.

    **What a shard adds to a `lib` is more than its types, and the correction
    is the earlier finding's own reason turned around.** A `fun` is a C symbol
    and the linker resolves it — true of the object code an artifact carries,
    false of the bodies it carries, because a body the consumer compiles makes
    the call itself. `openssl_ext`'s `PKey.read` travels and said `undefined
    fun 'pem_read_bio_rsa_private_key' for LibCrypto`. A `lib`'s `enum`s and
    constants came with the same measurement, each found by the next failure.
    And the names in `Reopened` are names the consumer can write: counted as
    unnameable, `OpenSSL::PKey::PKey` crossed as a *handle* — no fields, and no
    `new`, which is what keeps a handle honest — over an `@pkey` field naming
    the `LibCrypto::EvpPKey` the shard itself declares.

    **A class variable is identified by its owner and its name, and the
    bookkeeping was keyed on neither.** `MetaTypeVar` is a `Var`, and a `Var`'s
    equality is `def_equals_and_hash name` — its name, with nothing of its
    owner in it. A class variable declared on a superclass is copied onto every
    subclass that reads one, so `bindata`'s `@@bit_fields` is six variables and
    was one hash key: the unit `ASN1::BER` reads four of them and the last
    write took the entry. The consumer was told about one, made one read
    function, and the link ended on `~ASN1::BER::bit_fields:read`. That copy is
    also where the initialiser was being lost — `lookup_class_var?` carries the
    type, the thread-local flag and the initialiser node onto the copy, and iyi
    had added a field to the declaration that the copy did not carry.

    **And a gap that measurement closed rather than opened.** A third way of
    reading a class variable is visible in the code and has nothing behind it:
    where the owner is a virtual type the read goes through a main-module
    function that dispatches on the receiver's type id, `iyi_record_unit_class_var`
    is not on that path, and the main module never travels — so a consumer
    would owe a function it was never told about. That reading is what the
    symbol above looked like, and it was wrong; the cause was a hash keyed on a
    name. The machinery for it was written and then taken back out, because
    nothing has reached it and a rule with no measurement behind it is worse
    than a gap somebody wrote down. This is the gap, written down.

    **A class is held virtually, and the keep file was naming it.** `BinData::
    VerificationException.to_s(io)` emits `*BinData::VerificationException::
    to_s<IO+>`; a consumer that holds the class — `io << exception.class`,
    through `Exception+.class` — asks for `*BinData::VerificationException+@…`.
    The name is the concrete metaclass and a value of it is the virtual one, so
    the keep file calls the class side through `uninitialized T.class`. Not
    `new`: a virtual metaclass dispatches it to every subclass and a subclass
    builds itself its own way.

    **`yaml` crosses too, and what stood in its way was one link flag.** The
    reading recorded above — that its `@anchors` is typed by merging what two
    users of a shared module put in it, so no single method instantiation sees
    the error — was true of an older tree and is no longer what happens: `YAML`
    binds, fills into ten units, and a consumer parses a document with an
    anchor and a merge key in it. What was left was `undefined symbol:
    yaml_parser_parse`.

    **Which C libraries a boundary's object code needs is part of what has to
    travel, and it is not `Requires`.** `Requires` says what the consumer has
    to have *compiled*; this says what it has to have *linked against*, and the
    consumer cannot derive the second from the first. It replays `require
    "yaml"`, so it has `lib LibYAML` and the `@[Link("yaml")]` on it — and
    `link_annotations` collects a flag only from a `LibType` that is `used?`,
    which is a question about *this* build's own code. The call is in the
    artifact's `YAML::PullParser` unit, an object file the consumer reads
    rather than compiles, so nothing marked it and `-lyaml` never reached the
    link line.

    `Libs` (section 18) carries the names and nothing else. Everything a link
    line needs — `pkg_config`, `ldflags`, `framework`, static — is already on
    the consumer's own copy of the annotation, and carrying a second copy would
    be a second answer to a question that has one. What was missing is only
    that somebody used it. Recorded where a unit *declares* a `fun`, because
    that is exactly the condition: a unit that names a C symbol is a unit whose
    object file refers to it.

    `bench/yaml_reads.sh` holds it, and it holds the name rather than the
    count — the point of the section is *which* library, and a gate that
    counted would pass on the wrong one.

    **A boundary built from the library is a different question from a shard,
    and `Log` is where it stops being an easy one.** `JSON`, `URI`, `HTTP`,
    `Compress`, `Digest` and `OptionParser` all bind, fill and answer what
    their source answers; `bench/library_boundaries.sh` holds three of them and
    `bench/yaml_reads.sh` a fourth. `Log` is global state written by macros,
    and it found four things.

    **`tool bind` has to survive its own question.** It asks what a shard's own
    compilation never asks — what does this method answer, called on nothing in
    particular — and for `Log` the answer is that typing the call does not
    terminate: it recurses through `Call#recalculate` building a metaclass of a
    metaclass, twelve hundred deep, until the stack ends. A stack overflow is a
    signal rather than an exception, so the `rescue` this tool already had
    could not see one. `Program#iyi_instantiation_limit` is nil for every
    ordinary build and set by this tool, and past it the recursion becomes a
    refusal the tool already knows how to report. It went in at `instantiate`
    first, which was wrong for a measurable reason: the recursion passes
    through that five times and through `recalculate` twelve hundred, so a
    limit there is a limit on the wrong number.

    **And a parameter written `Class` is one there is no value to stand for.**
    `Class` is every metaclass there is and there is no end to them — `Foo.class`,
    `Foo.class.class`, and on. A real caller of `Log.for(type : Class)` names
    one; a call synthesised here hands the compiler the whole family. The limit
    above turns that into a diagnosis and this keeps it from being asked.

    **A class variable the library declares is not the artifact's to declare
    again.** A boundary rooted at the library's own namespace writes that
    namespace's type whole — `pub class Log`, with everything on it — and a
    consumer that replays `require "log"` has the real one, so the declaration
    reopens it and the variable arrives twice. One initialiser wins and it is
    not the artifact's, so `Log.setup` reached a `@@builder` nobody had built:
    `Invalid memory access` inside `Log::Builder#clear`. The same rule the
    constants beside them already took. The *name* still travels in
    `ClassVars`, which is what makes the global exist for the object code —
    that half was never the library's to provide.

    **And `MonoBodies` was keyed without the side of the type.** The key was
    documented as "the whole of what distinguishes one overload from another,
    which is the parameter list and the block", and it was missing the first
    thing that does. `Log` has a `{% for %}` loop writing `def info(*,
    exception : Exception)` on the instance and another writing `def self.info`
    with the same parameters on the class: same container, same name, same
    parameters, no block, one key. The class method's body took it, so the
    consumer read `Log#info` as `Top.info(exception: exception)` — which is
    `Log#info` calling itself — and said `recursive block expansion: blocks
    that yield are always inlined`.

    **`db` and `sqlite3` are the shard that asks for everything at once**, and
    they are not through yet. What they found is eleven more rules, each
    measured, and one named blocker left.

    **A record rebuilt field by field loses what was added to it later.**
    `map_names_declaration`, `strip_root_declaration` and `prune_declaration`
    each constructed a fresh `TypeDecl` by listing its fields, and each list
    was written before `funs` existed — so a reopened `lib` arrived with every
    type in it and not one `fun`. `copy_with` names only what changes, which is
    the shape a rewrite should have had all along. An alias had lost its
    right-hand side the same way once, and an enum its members.

    **A generic module's nested types are not parameterised by being nested.**
    `db` writes `module SessionMethods(Session, Stmt)` and puts `struct
    UnpreparedQuery(Session, Stmt)` inside it; the module was dropped whole and
    took the struct with it, and the object code numbers the struct. The same
    correction a generic *class* took when `Radix::Tree(T)`'s error classes went
    missing, one kind of type over. A generic's `superclass` and `includes`
    were missing too — `SessionMethods` includes `QueryMethods(Stmt)`, and
    `QueryMethods` is where `exec` lives.

    **A `lib` the shard owns outright belongs inside its module.** `Reopened`
    is for a `lib` the *library* also declares, written `lib ::LibCrypto` so it
    reopens the real one; `sqlite3` writes `lib LibSQLite3` beside `module
    SQLite3` and owns all of it. Outside the module its funs cannot name the
    shard's own types — `undefined constant SQLite3::Flag` — and inside them
    the root-stripping every other declaration takes rewrites them correctly.
    Its funs are text and take the same rewrites; a `lib` has nothing for the
    keep file to name.

    **An include is an ordering edge like a superclass, and so is every name
    in it.** `class Connection` including `module BeginTransaction` sorted
    before it; `include SessionMethods(Connection, Statement)` needs all three
    names placed first. And a generic's include may name the generic's own
    parameters — `QueryMethods(Stmt)` inside `SessionMethods(Session, Stmt)` —
    which is the same argument the methods beside it already took.

    **A generic module's instantiation is not a `ModuleType`.** It is a
    `GenericModuleInstanceType`, and the test that decides which parents are
    includes knew only the first name. `include SessionMethods(Database,
    PoolStatement)` was dropped and a consumer said `undefined method 'exec'
    for DB::Database` about a `Database` carrying every other method.

    **A block's annotation travelled as written while everything beside it
    travelled resolved.** `&factory : -> Connection` means `-> DB::Connection`,
    and unresolved it failed the nameability test that decides whether the
    method crosses — so `Database#initialize`, the one thing a consumer builds
    a `Database` with, was dropped. Resolved it has to stay an *arrow*: the
    resolved type prints `Proc(DB::Connection, Nil)`, the keep file reads the
    arrow to count block parameters, and handed the `Proc` form it counted the
    output as an input. The synthesised block's `uninitialized` needs resolving
    for the same reason from the other end — it is typed by a visitor scoped to
    the program, where `Connection` is nothing.

    **`uncompilable` is not a question to ask of a private callee**, and a bare
    generic is a name rather than a type. The first says this tool could not
    instantiate a method to read its answer, and these declarations exist for a
    travelling body to typecheck against — the keep file, where an
    uninstantiable method would do damage, skips a private one on purpose. The
    second is `private def perform_exec_and_release(args : Enumerable)`, whose
    resolved restriction prints `Enumerable(T)` with a `T` declared nowhere.

    **A body that travels is compiled per subclass, so the privates it calls
    travel per subclass too.** `db` writes `private abstract def
    build_statement` on `PoolStatement` and a concrete one on each subclass,
    and the body that calls it travels on the ancestor.

    **And `NoReturn` is an answer only where the body stays behind.**
    `NullIO#read` raises `NotImplementedError` and nothing overrides it, so
    `NoReturn` is true. `DB.build_driver` answers `NoReturn` because a build of
    `db` alone has no driver registered — and its body travels, so the answer
    is the consumer's to infer. Refusing it outright was the first attempt and
    it dropped `NullIO#read`, which an abstract `IO` requires.

    **`previous_def` travels, and the ordinal that carries it found a
    duplicate that had been there all along.** A redefinition does not sit
    beside the definition it replaces — `add_def` puts the old one on
    `previous` and the hash holds one — so the chain is walked and each link
    gets its own `MonoBodies` key, numbered in the order they were written.
    Both sides count the same way, which is what makes a position a name, and
    the sorts that order a type's methods had to become stable for the count to
    mean anything.

    What that exposed: `Kemal::CLI` had carried **two** `def initialize(args)`
    since `fallback_initialize` learned to match by shape, and nobody could
    tell, because both declarations read the same key and rendered the same
    body. Numbered, the second found nothing and rendered empty — and an empty
    `initialize` is the one Crystal keeps. `initialize` is *protected* in
    Crystal, so the visibility test in the private-callee search let it past
    whatever its name, and that search asked "has this crossed?" by name where
    it had to ask by signature. A redundancy for weeks, a fault the moment
    positions started mattering.

    **A method that answers an ancestor's `abstract def` travels whatever its
    visibility.** `db` writes `protected abstract def perform_exec(args :
    Enumerable) : ExecResult` and `Statement#exec`'s body — which travels —
    calls it, so every driver's implementation has to be there for that body to
    compile. The search that finds a travelling body's private callees cannot
    find this one: the body is in *db's* artifact and the implementation is in
    the driver's, two boundaries that never read each other's text. The
    requirement is the thing they share.

    **A parameter's external name is part of the method.** `def query_one(query,
    *args_, as type : Class)` is written `as: String` at the call site, and a
    declaration naming only the internal `type` is a different method: `no
    overload matches … with types String, Int32, as: String.class`, three
    overloads listed and every one of them naming it `type`.

    **And `forall` is another way of saying the caller decides.** `def
    read(type : T.class) : T forall T` is one method per `T`, compiled at the
    call site with the call site's type in the symbol — the same shape a splat
    has, and the same answer: the body is what travels. The `forall` clause was
    never carried at all, so the free variable also failed the test that asks
    whether every name in a signature is one the far side can write, and inside
    a generic the two kinds of bound name — the type's parameters and the
    method's free variables — had to be asked together.

    Two smaller ones came out of the same run. The private-callee search keyed
    its pool on parameter *names*: `sqlite3` writes ten `private def
    bind_arg(index, value : …)`, one per bindable type, and every one of them
    has the same two names — so nine were dropped. And a *synthesised* `new`
    must never travel from that search either, for the reason it never travels
    from the other: its body is `_ = allocate`, and `_` is not a name anybody
    reads back.

    **A list of what a module defines is only worth having if it is the list of
    what it has.** `collect_iyi_object_code` drops a unit name with no
    compilation unit behind it or no file on disk, and every other collector
    was still answering for the whole of `unit_names` — so an artifact could
    *claim* a symbol it did not carry, and a consumer reading that claim
    skipped compiling one of its own. `Symbols` is now collected from the units
    whose object code actually travelled, and `mod dump` names them rather than
    counting them: a count says a claim was made, and what is asked at the end
    of a failed link is *which*.

    **`sqlite3` typechecks whole and stops at the link, on forty symbols of
    three kinds**, and one of the three is a finding this file already has half
    of.

    **`Libs` carries names on an argument that holds for half the cases.** The
    argument is that everything a link line needs is already on the consumer's
    own copy of the `@[Link]` annotation — true of a `lib` the *library*
    declares, and false of one only the shard has, where there is no other
    copy. And a shard-owned lib is declared *inside* the artifact's module,
    which is what lets its funs name the shard's own types and also means the
    consumer's copy is the only copy. It arrived bare: nothing asked for
    `-lsqlite3`, and the link ended on `sqlite3_value_text`. So a `TypeDecl`
    carries its annotations as source now, and every C symbol resolves.

    **A keep file stops at the first method that only raises, and every call
    after it is discarded.** `CleanupTransformer` stops collecting an
    `Expressions` at a statement whose type is `NoReturn` — which is right for
    a program and ruinous for a file that is one long list of calls.
    `DB::Database#checkout` on an `uninitialized` receiver raises, and it is
    the *first* call in that type's block, so the seven after it never reached
    codegen and their symbols never existed. Every keep file this tool has ever
    written has been truncated this way at some line or other, and it went
    unseen because a shard usually reaches its own methods somewhere:
    `Kemal::Config#host_binding` has a symbol because kemal's startup message
    reads it, not because the keep file asked. What a keep file adds is
    precisely what a shard does *not* call itself, which is most of what a
    consumer calls.

    Each call goes in its own `begin`/`rescue` now. Not an ordering trick,
    because which methods raise is not knowable from a signature — and the file
    is never run, so what it rescues is nothing. `sqlite3`'s undefined symbols
    went from forty to five.

    **A `lib`'s name is the half that cannot move**, and moving a shard-owned
    one inside the artifact's module — done a few paragraphs above, for a good
    reason — moved it. The producer emits
    `*SQLite3::Connection#to_unsafe:LibSQLite3::SQLite3` and the consumer asked
    for `…:SQLite3::LibSQLite3::SQLite3`: the same method, two names, because
    the lib had gone into the shard's namespace and every symbol whose
    signature names one of its types mangles from that name. A lib needs both
    things — its funs must be able to name the shard's own types, and its own
    name must be the one the object code was compiled with — and only the
    second is a constraint.

    So it goes back beside a reopened one, at the top level, and the funs are
    what bend: a parameter written `SQLite3::Flag` is written as the enum's
    base type instead. That costs nothing, because what a C function takes is
    the integer and Crystal's own rule converts an enum at a `fun` call without
    being asked — a caller inside the module goes on writing
    `SQLite3::Flag::ReadWrite`. Three symbols left.

    **A boundary carries what the shard wrote, and it was carrying Crystal's
    library too.** `Class#name` is `{{ @type.name.stringify }}` in Crystal's
    own `class.cr`, one instantiation per type, and a shard's classes inherit
    it like everything else — so it crossed as a *header*, which is a promise
    of a symbol per subclass that only the types with units behind them could
    keep. A consumer forming `DB::PoolResourceLost(DB::Connection+)` got the
    header and nothing to link. It has its own `class.cr` and makes its own,
    which is what every other program does.

    The test is where a method is *not* written rather than where it is, and
    the difference is another boundary: a method inherited from Crystal stays
    behind, one inherited from another *shard* travels. And it has to be asked
    in both places a declaration can come from — asked only of the main walk,
    the method came back through the private-callee search and came back
    `private`.

    **A module's methods are the fourth thing whose body has to travel.** The
    sentence that covers a generic's and an abstract class's covers these too:
    they are instantiated per *including* type, and the includer may be in
    another boundary altogether. `db` writes `module Disposable` with a `close`
    in it and `sqlite3`'s `ResultSet` includes it, and neither artifact could
    define `*SQLite3::ResultSet@DB::Disposable#close` — db's build has no such
    type, sqlite3's has the method only as a header. The same argument fixes
    the consumer's side of it: `iyi_artifact_self_type` keys a method on its
    defining owner because a boundary has one symbol per method, and a module
    is the exception for the same reason a generic is.

    **And an empty body is a body.** `db` writes `protected def do_close; end`
    — a hook for subclasses, doing nothing itself — and the private-callee
    search read that as nothing to carry. `sqlite3`'s `do_close` calls
    `super()`, which then walked past every ancestor to `Object`.

    **A shard's top level is more than its constants.** `sqlite3` writes
    `DB.register_driver "sqlite3", SQLite3::Driver` at the top level of
    `driver.cr` — one statement, and the thing the whole shard exists to do.
    Only constants were crossing, so a consumer linked, ran, and said `no
    driver was registered for the schema "sqlite3", did you maybe forget to
    require the database driver?` — which is exactly what had happened, one
    boundary over. They are read back from the shard's own files in require
    order, because by the time a boundary is written they have been typed,
    expanded and folded into `_main`, and what has to cross is what the shard
    *wrote*. Not a macro, though: a macro at the top level writes declarations,
    the declarations have already travelled, and running it again on the far
    side reads names that are the shard's own and private.

    Two readings were measured and are wrong, and both are written down so
    nobody spends the afternoon on them again: instantiating a generic does not
    lose iyi's marks on a `Def` (`clone_without_location` carries both), and
    notifying a numbered type's ancestors a second time when it is created
    changes nothing.

    **A field's default travels, and it travels in the field's place.** `db`
    writes `@total = [] of T` on `DB::Pool(T)`; only the type was crossing, so
    a consumer allocated it null and the first `@total.each` read through it.
    `reopened_declaration` had carried defaults since kemal's `@store` needed
    one and the shard's *own* types never did.

    The first attempt put them where the class variables go — the same
    `name : type = value` line — and that was wrong for a reason worth keeping:
    **a field's position in the list is its position in the layout**, and the
    module's own object code was compiled against that layout. The defaulted
    fields all moved to the end, `@factory` changed offset, and db's own
    `Database#initialize` wrote a proc where the consumer read an array. So a
    field is a triple now — name, type, default — and the default is written
    where the field is.

    **And a default is the third thing to need the value as it was *written*.**
    A regex literal is replaced by the constant the compiler cached it in, so
    `backtracer`'s `@app_dirs_pattern : Regex = /…/` reached the format as
    `$Regex:99c9…` — a name iyi's parser refuses outright. Constants and class
    variables already recorded their written source; instance variables now do
    too. The same correction, three times, on the three kinds of value that
    have to run on the far side.

    A fourth thing cannot travel at all: a body that reads `$~`. It is the
    match the last regex in *that method* set — scoped, compiler-written, and
    not a name anybody declares. `backtracer` writes `def parse?(line : String,
    **options)` and reads `$~["method"]` in it, and the double splat is what
    makes the body the only honest declaration of the method — so the method
    does not cross, and the report says which one.

    **`sqlite3` compiles, links, runs, opens the database and builds its
    pool.** What it does not do yet is answer: `SQLite3::Statement#perform_exec`
    reads at offset `0x20` from a null receiver — a statement that was never
    built. That is a different kind of question from every one above it: not a
    name, not a symbol, not a layout, but an object that should have been
    constructed and was not.

    **A declaration cannot name a virtual type, and everything downstream was
    reading that as the exact one.** `DB::Database#checkout` answers
    `DB::Connection+`; the declaration writes `Connection`, because `Foo+` is
    how a virtual type prints and not a name anybody can write. Two things then
    went wrong, and the second is the one that mattered.

    The symbol is made of the type the method *actually* answers, so a consumer
    calling `db.checkout` directly asked for
    `*DB::Database#checkout:DB::Connection` and nobody had emitted one. That
    never showed through a travelling body, where the consumer compiles the
    call itself, and it did not show at all until a probe called `db.checkout`
    by hand.

    And a header's return type was read *literally*. An ordinary `def f :
    Connection` over an abstract class types its call `Connection+` — the body
    is what widens it — but a header has no body, so the call came out typed
    `DB::Connection` exactly. Every generic below it was then instantiated with
    the wrong argument, and a `SQLite3::Connection` stored in an
    `Array(DB::Connection)` read back as its own base: `.class` answered
    `DB::Connection` and `is_a?(SQLite3::Connection)` answered **false**. A
    program that linked and computed the wrong answer, which is the one failure
    this design is most afraid of. Both halves take the same correction, and
    `iyi_artifact_arg_types` had been making it for the *arguments* since kemal.

    **A shard's own `alias` does not travel, and a body names one.** `db`
    writes `alias Any = Union(…)` from a macro over the types a driver can
    bind, and `Statement#exec`'s body says `Slice(Any).empty`. An alias is a
    name for a type rather than a type, so it is not a `ModuleType` and the
    walk dropped it at the door. It travels with the type it resolved to, for
    the reason a field's type does: `Union({{*TYPES}})` is a macro nobody can
    run again.

    **And a body's text takes the same rewrite its signature does.** A body is
    the module's own code and names things the way the module wrote them —
    `SQLite3::TIME_ZONE`, absolute — while the declarations are read inside a
    module whose root has been stripped. That path is then the module's
    *public* name and R-2 answers for it: `SQLite3 does not export
    SQLite3::TIME_ZONE`. Stripped, it is what the shard's own file means.

    One exception, and it is the exception that proves the rule: a *top-level*
    `def` is rendered outside the module — that is what makes it top-level — so
    a name in its body has to stay the one the module is known by from out
    there. `Kemal::Utils` rather than `Utils`, which is nothing at that level.

    **Both of those now have a gate, and writing it took two tries apiece.**
    `bench/bind_roundtrip.sh` exists for exactly this — III.6 rule 1's "a call
    that returns something of another type" — and the shard it binds grew two
    shapes.

    The first version of the return check wrote `def factory(tag : String) :
    Base` and passed either way: Crystal resolves a *written* restriction on an
    abstract class to `Base+` on its own, so nothing was inferred and nothing
    was devirtualised. It takes a method with **no** return annotation whose
    body answers two subclasses — then the answer is `Base+`, the declaration
    can only say `Base`, and the header reads it as the exact class. Without
    the fix the gate now ends on `undefined symbol: *Shard::Base#describe`.

    The first version of the body check put the method on the *module* and
    passed either way, because a module function's body already took the
    rewrite; a type's did not. On a type, and taking a block so that the body
    travels at all, it ends on `Shard does not export Shard::TAG`.

    A gate that passes before the fix is a gate that proves nothing, and both
    of these did until they were checked against the broken compiler.

    **And a name resolves in its own scope first.** `openssl_ext` writes a
    constant `GETS_BIO` inside `class OpenSSL::GETS_BIO`, so the return type
    R-2 asks this file to write for its `new` — a type Crystal infers and the
    shard never spells — read as the constant. `self` is the spelling with no
    such problem, and on a metaclass it is exactly what `new` answers. There is
    no absolute spelling to reach for: `::` leaves the module wrapper entirely,
    which is what `lib ::LibCrypto` uses it for, and the wrapper's own name is
    not one a type path can start with.

    Two smaller facts came out of the same measurement, and both read as
    compiler bugs without being one. A shard is not always one boundary:
    `bindata` defines `BinData` *and* `ASN1`, the second in a file `jwt`
    requires separately, so `-e` names a root rather than a shard. And binding
    into a directory that already holds a *later* boundary gives the earlier one
    an import edge back to it — the dependency order in `bench/bind_chain.sh` is
    load-bearing, and a stale directory made three measurements here name the
    wrong type.

    **`sqlite3` runs a query, and `bench/sqlite3_queries.sh` holds it.** A
    program that imports `s_q_lite3` opens a database, creates a table, inserts
    two rows with bound parameters, reads a scalar back, iterates a result set
    with typed `read(String)` and `read(Int32)` and counts the rows — through
    two boundaries, and answers what the same program answers from source. The
    third real shard, and the first whose boundary is a *pair*: `db` declares
    what a driver must answer and never sees one, `sqlite3` answers it and
    never sees `db`'s source. Every `abstract def` between them is a place
    where the producer compiled a body against nothing at all.

    That is the finding, and IV.1g now carries it: **a travelling body is
    compiled twice and the two are not the same function.**
    `Connection#fetch_or_build_prepared_statement` calls an abstract
    `build_prepared_statement`, so `db`'s own copy — global, in its artifact —
    returns its own argument, and the consumer's correct copy is private to its
    unit. Every call the consumer wrote bound to the producer's, and `DB.open`
    handed back a statement whose `crystal_type_id` was 1. The consumer's copy
    now carries a suffix. Hiding the producer's instead was tried and broke the
    link: `sqlite3`'s `Statement#do_close` calls `super` into `db`'s.

    Three smaller rules came with it, all about the same shape read two ways.
    An `abstract def` is a *requirement*: `Def#body` is the empty string for
    one, which is truthy, so the generic collector wrote it down as a method
    that answers `nil`; and read back, a requirement's `Nop` body looks exactly
    like a header's, so the call was typed and never emitted. And **a written
    return type is a restriction a travelling body keeps** — dropping it
    wherever the body answers made `sqlite3` refuse its own override.

    **A name inside `responds_to?` is a call, and it is the one call the
    private-callee search cannot follow.** That search reads a travelling body
    and finds the private methods it names; `responds_to?(:name)` names one on
    a receiver that is whatever the caller passed. `db` writes
    `Pool(T)#checkout` — generic, so its body travels — ending
    `res.responds_to?(:before_checkout) && res.before_checkout`, and
    `Connection#before_checkout` is `protected`. `Pool` is not `Connection`'s
    ancestor and `T` binds to it nowhere a search can read, so the hook stayed
    behind: `responds_to?` answered false in the consumer, `auto_release` was
    never set, and no connection went back to the pool. Every statement got a
    fresh connection, which a file-backed database does not notice and
    `:memory:` does — it loses its table between statements. Every body that
    says `responds_to?` is now searched for every type, which errs long the way
    the rest of that search does: `calls?` matches a name that is actually
    there, and a body naming nothing of the type's costs a scan.

13. ~~**Dependencies and discovery.**~~ **Specified in III.7**: path identity,
    minimal version selection, a manifest and a sums file, source as the primary
    form and the artifact as a signed cache keyed on the four-tuple the format
    enforces. The discovery half is the part with an advantage: R-2 means an
    index built from declarations is exact rather than parsed.
14. ~~**Tooling.**~~ **Specified in III.8; the formatter is built.** It was the
    first item because it is nine visit methods against an interface that
    already exists. The remaining order is an in-process single-module analysis
    API, then a language server over it. R-1 is what makes that server cheap,
    and it is the one dividend of the compilation model nobody designed for.
15. ~~**The dependency floor.**~~ **Measured in III.9, and everything on the
    own-prelude floor is decided**: an own-prelude program on macOS asks
    libSystem for the staples, the concurrency runtime's four (III.4.8) and
    the owned collector's six (III.9, the flip); on Linux an object that
    leaves none at all — the arena is raw syscalls — against an executable
    carrying only the five its link template adds. libgc left the default
    first for the bump pointer, whose never-collecting price Appendix B #23
    kept on purpose, and then the owned collector (Appendix B #20, built)
    took the default with the floor intact, which is II.5's requirement
    for R-4 landing as the runtime rather than as hygiene. Self-hosting
    stays where B.2 put it.

    `bench/dependency_floor.sh` checks plain own-prelude builds and
    `-Dgc_boehm`; it does not check `--crystal`. That mode links Crystal's
    standard library and may pull every library a required shard pulls.
16. ~~**Every other C library.**~~ **Specified in III.10 for iyi's own
    prelude**: Crystal's published inventory, one line each, with the principle
    that iyi owns everything above libc and libc is optional. Two were already
    answered by work nobody had counted: `compiler_rt` is ported to Crystal and
    the digests are Crystal, so neither clang's runtime nor libcrypto is linked.
    The event loop is the cheapest of the remaining four because Crystal already
    wrote the native backends, and III.4 being unbuilt is why the choice is
    live. The rule is checked rather than asserted:
    `bench/dependency_floor.sh` fails in CI when an own-prelude program grows a
    symbol or linked library, on the default build and on `-Dgc_boehm`.

---

## Appendix: What measurement settled

For traceability, since several rules here rest on numbers rather than taste.

| Claim | Evidence |
|---|---|
| Separate compilation is the main prize | 1000 typed functions cost +0.08 s; ~95% of non-LLVM work is fixed prelude tax |
| A cached prelude is worth 3.4×, not 20× | fork probe: 1.58 s → 0.47 s front end; 0.09 s if the prelude did not exist (IV.1a) |
| The artifact is not the whole job | with the prelude pre-analysed, class-var initializers and `main` are 90% of what is left, because they still walk the prelude (IV.1a) |
| Prelude-aware passes are worth another 10× | a front end that never walks the prelude runs `hello.iyi` in 0.049 s vs 1.58 s, and emits an object with an identical symbol table (IV.1a) |
| The front end and codegen need the prelude for different reasons | codegen emits `fun`s by walking the AST, so the prelude's tree must reach it regardless; only the front end's need is removed by caching analysis (IV.1a) |
| Half the top-level pass is the parser | 304 prelude files, 107,719 lines: 0.57 s parse, 0.54 s visit |
| Open classes are the blocker | 77 of 484 types reopened across module boundaries; `String` by five modules |
| Traits are a viable replacement | Kemal router ports at +4% code size, structure intact |
| `using` is required, not optional | Kemal's DSL is unwritable without it |
| Dictionaries pay off at compile time | 46.6% of instantiations collapse (compiler), 47.7% (app-shaped code) |
| Dictionaries cost ~3–4 cycles per call | 17.5× on a vectorisable loop, 1.21× where neither side vectorises, 1.00× with real work per element |
| `macro_run` must go | +7.4 s per distinct script on a cold build, memoised per script but not amortised across scripts; two scripts cost twice (II.10) |
| Macro expansion is not a compile-time cost | a template macro runs at 1.00–1.05× hand-written code; a computing macro adds ~9 µs per method against the ~18 µs the method costs anyway (II.10) |
| `method_missing` is safe to cut | one occurrence in stdlib, zero in Kemal |
| Traits can carry the stdlib | `Enumerable` ported and running: all 71 of its method names on one `each`, implemented for two element types, every method called (`src/std/enumerable.iyi`) |
| `Share` prices a style rather than failing | clean-sheet iyi code is 77% shareable as written and 100% given an immutable collection; the compiler, built as a mutable workspace, is 38.5% and stays there (III.4.7) |
| Module-level mutable state is already rare | 3 of 483 compiler types hold a class variable, so III.4.5 costs almost nothing |
| Coherence costs nothing at build time | the import DAG plus the orphan rule make duplicate impls unrepresentable (IV.4) |
| The gap to Go is the warm build, and it is 11× | `hello`: cold 2.20 s vs Go's 1.98 s, warm 1.96 s vs Go's 0.18 s. Crystal's cache holds codegen only, so the 1.32 s front end is paid on every build (`bench/build_speed.py`) |
| A first release's prelude is ~3.5k lines | Crystal 0.1.0 shipped 8,161 lines of library, 3,551 of it the core that a prelude is; the rest is `json`/`yaml`/`http` |
| Self-hosting only gets more expensive | Crystal self-hosted at 24,984 lines of compiler and 8,161 of library, before its 0.1.0; iyi's fork starts at 95,010 and 196,217, and is 87,421 after the interpreter came out (Appendix B.2, V.11) |
| A second implementation of the language is what an interpreter costs | Crystal's interpreter stops on `samples/iyi/hello.iyi` line 12 at the module header, and 0 of the fork's 153 commits had touched it against 7,840 lines of parser and semantic change (V.11) |
| The daemon's win did not survive the prelude | it removed prelude analysis, and iyi's prelude is 1,053 lines: one module edited in a 7,207-line project costs 0.18–0.28 s built normally and 0.20–0.24 s through the daemon (IV.1d) |
| R-1 pays for lines, not for modules | 30 modules of 10 types buy 1.8x and 300 modules of one type buy 1.4x; a project of 300 five-line modules is a 0.86x *loss*, because reading an artifact costs more than parsing five lines (IV.3a) |
| One file is one module, and it had to be said | a second `module a/b` header in a file was accepted: the file emitted one artifact under the first name carrying both modules' exports, and the second module had none (IV.6) |
| A compiled artifact needs its own checksum | one flipped byte in a `.iyimod` built silently 7 times out of 10 and reached the linker the other 3; per-section checksums in format v19 refuse 12 of 12 and name the section (IV.2a) |
| A prefix is not a parent directory | working in `/tmp/x/crystal` with a cache at `/tmp/x/crystal-cache`, every object file was written to `-cache/…`; the same "No such file or directory" the cleaner race produces, from a different cause (V.10) |
| A build's cache directory can be deleted underneath it | the cleaner keeps the ten most recently modified directories and runs after every compile; removing one mid-codegen reproduces both failures, the single-threaded path included, and reading the `compiler.lock` the build already holds fixes it (V.10) |
| A module as the unit of compilation is worth 8x to 9x over Crystal | the same program, the same compiler binary, one module edited: 1.17 s as Crystal, 0.13 s as iyi, against `go build`'s 0.16 s, and 1.29 / 0.16 / 0.19 an hour earlier (IV.3a) |
| The edit loop is where R-1 pays, and it pays 1.8x | one module edited in a 30-module, 7,207-line project: 0.13 s with artifacts, 0.23 s without, against `go build`'s 0.16 s for the same edit (IV.3a) |
| The path/name mapping needed more than snake_case | `camelcase` drops an underscore before a digit, so `v_1` and `v1` both give `V1`; requiring each group to start with a letter removes that and three sibling collisions (IV.6 #6) |
| Ten reachable regex literals kept pcre2 on the compiler, not a `require` | `--emit llvm-ir` shows `$Regex:0` through `$Regex:9` expanded in the binary, from four stdlib files the compiler compiles into itself; converting all four leaves `otool -L .build/iyi` at libLLVM, libc++, libgc, libSystem and `nm -u .build/iyi` without any of the thirteen `pcre2_*` symbols it used to leave undefined. An unused constant does not bring it back, because Crystal never instantiates an unreachable one (III.10) |
| PCRE2's `\s` under `UCP` and `Char#whitespace?` differ at exactly one character | the 20,633-case differential over `parse_flag_definition` first reported 1,114 mismatches and every one of them contained U+0085 NEL; handling NEL by name takes it to 0 (III.10) |
| A claim measured on an object is not a claim about the executable | the per-target audit reads an own-prelude program's `.o` for `x86_64-linux-gnu` and finds nothing undefined, and this document turned that into "no undefined symbols at all". The linked own-prelude program has five, `__libc_start_main`, `__gmon_start__`, `__cxa_finalize` and the two weak `_ITM_` callbacks, contributed by the link template's crt objects and reported by CI on Linux. Both measurements are right and answer different questions, so the layer and library mode are now named wherever the number appears (III.9, III.10) |
| Direct dependencies and the transitive closure are different checks, and only one has teeth | `ldd` on the Linux compiler listed libxml2, libz, libffi, libedit, icu, zstd, lzma, libbsd, libmd and libtinfo, all of them libLLVM's; `readelf -d` NEEDED lists what iyi names, which is what `otool -L` already reported on darwin. Proven both ways: an explicit `-lxml2` fails the gate by name, the same library inside libLLVM passes, and `otool -L libLLVM.dylib` confirms libxml2, libffi, libedit and libz are in there. `linux-vdso.so.1` was never a `DT_NEEDED` entry and stopped appearing rather than being allowed (III.10) |
| A linear-time guarantee does not forbid lookaround, and this document said it did | the refusal was recorded as the price of RE2 semantics, on the premise that lookaround needs a backtracker. A lookaround over a regular inner pattern is a regular property of a position, answered by a pre-pass costing one state set per character and nothing per position, so all four forms landed with the guarantee intact and lookbehind unbounded where pcre2's is not. RE2's omission is its one-pass DFA design, not the guarantee. What the guarantee does cost is the constructs that are not regular, backreferences, recursion, subroutine calls and conditionals, and the correction is in III.10 and Appendix B #17 rather than the earlier reading being deleted (III.10) |
| pcre2 breaks the union law for a grouped lookbehind alternation, and the group is the trigger | on subject `"a"` at byte 0, where neither branch holds: `(?<=(?:a|$))` searched from 0 reports a match at byte 0, the same pattern anchored at 0 reports nothing, and the ungrouped `(?<=a|$)` correctly reports nothing. So pcre2 contradicts its own anchored evaluation, and an earlier explanation blaming fixed-width stepping is refuted by the ungrouped row. iyi's engine holds `(?<=A|B)` exactly where `(?<=A)` or `(?<=B)` holds, and the spec pins pcre2's per-branch answers rather than its answer for the pair (III.10) |

## Appendix B: Decisions awaiting your call

| # | Decision | Recommendation |
|---|---|---|
| 1 | Errors as unions at all (III.1) | yes: biggest departure from Ruby feel, so it is a taste call |
| 2 | ~~`!` in identifiers vs `!` as propagation (III.1.7)~~ | **Decided: A**: `!` dropped from identifiers, `sort`/`sorted` adopted, enforced by the compiler |
| 3 | ~~Implicit error conversion (III.1.6)~~ | **Decided: no, and not on a schedule**: the signature is the error set; a conversion the reader cannot see takes that away |
| 4 | ~~Nil-propagation operator (III.1.5)~~ | **Decided: no, and not on a schedule**: a second propagation channel ends by making `Nil` an error, which III.1.5 exists to prevent |
| 5 | `pub using` re-export (II.3) | no, for Draft 0 |
| 6 | `@[Monomorphize]` on stdlib trait defaults (II.6) | yes: mark `each`/`map`/`select`/`reduce`, stencil the rest. Accepts that the library author owns a per-method performance decision |
| 7 | ~~`!` inside a `defer` (III.1.4, V.8)~~ | **Decided: no**: a `defer` runs while the function is already returning, so propagating from one needs error-during-error semantics |
| 8 | Structured concurrency only, no bare spawn (III.4.1) | yes. It is `defer` applied to a task set, so it costs no new mechanism, and it makes Go's commonest bug unrepresentable. The price is that a task cannot outlive its scope, which is a taste call |
| 9 | ~~`Share` marker vs Erlang-style no sharing (III.4.4)~~ | **Decided: `Share`, on the count**: III.4.7 found the feared class empty and clean-sheet iyi code 77% shareable as written, 100% given a shareable immutable collection. That collection is now a stdlib obligation, not a nicety |
| 10 | ~~**Is iyi ever meant to be self-hosted?**~~ | **Decided: no.** iyi's compiler is and remains a Crystal program. The language's claim is what it compiles, not what compiles it. See B.2 |
| 11 | ~~**Keep Crystal's interpreter?**~~ | **Decided: no, and removed.** It was compiled out already, it cannot run an iyi program past the module header, and no commit of this fork had touched it in 153. An interpreter is a second implementation of the semantics, and the semantics are still moving. See V.11. **Reopened by III.11 and decided yes as #25: built on the macro interpreter, no C interop** |
| 12 | ~~**Is a Crystal binding checked or trusted? (III.6)**~~ | **Decided: checked, and nobody writes it.** The return type every binding carries is the instantiated answer, held against the written restriction where there is one (III.6 rule 1's count: URI 40 agree, 0 disagree, 27 unchecked); a person writes no signature at a boundary, `iyi bind` writes the artifact from the shard's own declarations. "Trusted for the first version" was the order of work, and the first version was measured out of it |
| 13 | **Does the registry serve prebuilt artifacts? (III.7)** | yes, but last, and never as the only form. Source is primary and the artifact is a cache keyed on the four-tuple the format already enforces. It also cannot ship before a whole-artifact signature exists, since an artifact reaching the linker is code execution |
| 14 | **A `Docs` section in the artifact? (III.7, III.8)** | yes. It is what makes `iyi doc` and the index possible without the deleted generator, and it is the one addition that serves two claims at once |
| 15 | ~~**Does the daemon become the language server's process? (III.8)**~~ | **Decided: no, on the number.** The server is a front-end compile per question, 44 ms p50 on the release compiler with today's prelude, and the daemon's `Preanalysed` is the 30 ms of that which is the prelude's top-level pass — held in a `Program` that adoption mutates, which is why the daemon forks per build. A clone per request or an invalidation story, for 44 ms to about 15 under an editor's debounce: III.8 declines it with the measurement beside it. The daemon is reachable (`iyi daemon`, listed, gated out of the tarball) and serves the workload it was kept for, `--crystal` builds |
| 16 | **Does III.4 use libevent or the native backends? (III.10)** | native, and it is not close. Crystal already wrote `epoll`, `kqueue`, `io_uring` and `iocp` backends and libevent is its default only on four platforms iyi does not target. Adopting it would put a C library under every concurrent iyi program to save work already done |
| 17 | **Regex: PCRE semantics or RE2's? (III.10)** | RE2's, and that answer stands. Linear time, no construct whose cost can grow with the subject. A language selling "the compiler will not surprise you" should not ship a library that takes exponential time on ordinary input, and Go already took this trade. **What this row said the answer costs was wrong, and it is restated rather than quietly widened.** It read "no backreferences, no lookbehind", and was taken to mean the guarantee forbids lookaround, on the premise that lookaround needs a backtracker. It does not: a lookaround over a regular inner pattern is itself a regular property of a position, answered by a pre-pass costing one state set per character and nothing per position. All four forms are supported, nested to any depth, and lookbehind here is not length-limited the way pcre2's is, so the engine accepts patterns pcre2 rejects. RE2 omits lookaround because of its one-pass DFA design, not because linear time forbids it, and this row inherited the omission as if it were the price. What the guarantee actually costs is the constructs that are not regular: backreferences, recursion, subroutine calls and conditionals, refused because no simulation answers them and matching backreferences is NP-hard. Atomic groups and possessive quantifiers are refused for a separate reason worth keeping separate: they are controls for a backtracker, and there is none here to control. A capturing group inside an assertion is refused too, because the pre-pass never performs the sub-match that would set it (III.10) |
| 18 | **TLS (III.10)** | none in 0.x; an OpenSSL binding as a package if something needs it sooner; own it eventually, TLS 1.3 only, and not before there is something to protect and somebody to audit it. What must not happen is OpenSSL becoming reachable from iyi's own prelude |
| 19 | **Is "no C library in the prelude" a rule or a habit? (III.10)** | a rule for iyi's own prelude, and it is checked: `bench/dependency_floor.sh` fails in CI when an own-prelude program grows a symbol or a linked library, on the default build and on `-Dgc_boehm`. `--crystal` is outside this gate and may link Crystal's standard library dependencies and anything a required shard pulls. Both host platforms measure the same property: direct dependencies, `otool -L` on macOS and `readelf -d` NEEDED on Linux, since `ldd`'s transitive closure put libLLVM's libraries on iyi's list and an allowlist holding libxml2 for that reason could never notice iyi reaching for libxml2 itself. Symbols are per platform: macOS's five libSystem calls, and on Linux the five the link template's crt objects leave, allowed by exact name rather than a wildcard, so `malloc` or `mmap` still fails. It holds the compiler binary to a list too, `libLLVM libc++ libgc libSystem`, and to a denylist that carries `libpcre`, so the rule is not weaker for the toolchain than for own-prelude programs. Proven to fail three times: adding a `lib LibM` call to a sample, injecting a reachable regex literal into `src/option_parser.cr`, and rebuilding the compiler with an explicit `-lxml2` |
| 20 | ~~**Write a collector, or adopt `gcry`? (III.9)**~~ | **Decided: iyi writes its own collector; gcry is not adopted, overruling this row's earlier recommendation.** What changed is the goal, and the change is the owner's, not a finding: they want concurrency, parallelism and a performant language, and owning the collector is the only path to the control that takes; gcry was pointed at as hints about what has already been tried to pull Crystal off Boehm, never as a runtime to adopt. The price is stated rather than softened: everything gcry already built, the heap, the STW, the roots, the finalizers, two platforms, is rebuilt in this tree, and only its measurements are inherited (#21). R-4 still requires the precise heap-layout table either way (II.5) |
| 21 | **Precise stack roots, now a design question inside the collector iyi writes (III.9)** | still open, and reframed by #20 rather than settled by it: it is a design decision in a collector iyi owns, no longer a finding inherited from gcry. R-4 needs heap-layout precision, which is a table. gcry's measurement is still the best available evidence on the expensive half: stack-map precision is correctness-stable and not an RSS win. Inherited as prior art rather than repeated, and answerable only when iyi's own collector exists to measure on |
| 22 | ~~**Keep macro-level regex, and pcre2 on the compiler with it? (III.9, III.10)**~~ | **Decided and done: macro-level regex is kept, on iyi's own engine, and pcre2 is off the compiler, measured.** RE2 semantics everywhere. This row recommended keeping both until the owned engine from #17 landed; it landed as `src/compiler/iyi/rx.cr`, differentially verified against pcre2, and it took pcre2 out of compiler-owned source. It did not take the library off the binary. Ten reachable regex literals in four stdlib files the compiler compiles into itself did that, found by reading `--emit llvm-ir` (`$Regex:0` through `$Regex:9`) rather than by inference: `option_parser.cr`, `process/shell.cr`, `semantic_version.cr` and `spec/cli.cr` now parse by hand, each differentially verified, and `otool -L .build/iyi` is down to libLLVM, libc++, libgc and libSystem. `bench/dependency_floor.sh` forbids `libpcre` for the compiler and own-prelude programs, proven to fail by injecting a reachable literal. The price: macro authors lose the constructs that are not regular, backreferences, recursion, subroutine calls and conditionals, plus atomic groups and possessive quantifiers, and a macro using one fails with a named error rather than quietly meaning something else; and `Spec::CLI#pattern` changed from `Regex?` to `String?`, a breaking change to a stdlib public API even though the behaviour is identical. **This row also listed lookaround as part of that price, inheriting the false premise corrected in #17; lookaround is supported, in all four forms, and lookbehind here is unbounded where pcre2's is not.** The gain: the compiler sheds a library on Crystal's required list, and no pattern can take exponential time |
| 23 | ~~**Is a default that does not collect acceptable until the collector lands? (III.9)**~~ | **Decided then, and now retired the way its last sentence promised.** A plain build using iyi's own prelude allocated and never collected, kept on purpose and documented loudly; the price stayed in the row: a long-running own-prelude program grew without bound, a default that shipped a known leak. "Until the collector lands" meant until iyi's own landed (#20) — and it landed: the owned collector is the default now (GC_DESIGN.md, `bench/gc_default.py` the measurement, III.9 the floor it kept). The never-collecting mode is `-Dgc_none`, chosen rather than shipped |
| 24 | ~~**Keep bdw-gc on the compiler? (III.9, III.10)**~~ | **Decided: yes; the exception holds in the present tense, and this row is superseded by #20 in its premise and restated.** The compiler keeps bdw-gc: `-Dgc_none` is proven not viable for it (III.10), and a collector that cannot carry parallel codegen cannot host a compiler that runs parallel codegen over fibers. What changed is the revisit condition: it is no longer gcry's parallel path leaving experimental, since gcry is not being adopted; it is iyi's own collector reaching the stage that serves parallel codegen. Until then the dependency stays a recorded exception carrying this reason rather than an unexamined habit |
| 25 | ~~**Build the interpreter on the macro interpreter, without C interop? (III.11)**~~ | **Decided: yes.** This reopens #11 on the owner's ask, with `iex` as the reference; the evidence that removed the old one still stands. The base is `src/compiler/iyi/macros/interpreter.cr`, 781 lines, a complete AST evaluator that already resolves types, extended for iyi's nine new AST nodes and two `Def` clauses, not the 11,377-line revert that cannot run iyi past the module header. No C interop, so no libffi, and that is enforced rather than assumed: `libffi` is on `bench/dependency_floor.sh`'s denylist, and the gate was proven to fire by adding to a sample the exact `@[Link("ffi")]` shape a naive revert would produce. It failed at three independent layers, reporting the gained symbol `ffi_prep_cif`, the gained library `libffi.8.dylib`, and the denylist hit, so an interpreter cannot quietly bring libffi with it. R-1 bounds what a session recompiles to the module graph; R-3 takes open-class patching away from the prompt |
| 26 | ~~**wasm32's allocator: wasi-libc as the platform runtime, a qualified platform, or `memory.grow` in the compiler? (III.9, III.10)**~~ | **Decided: bind `memory.grow` so an own-prelude iyi program on wasm32 needs nothing but its WASI imports.** A two-argument `fun` declaration of `llvm.wasm.memory.grow.i32` (memory index, then page delta) lowers to `memory.grow 0`. An earlier probe used the one-argument form, failed the module verifier, and was misread as "Crystal cannot bind this intrinsic". It was an arity error, not an impossibility, so this landed as an own-prelude binding rather than a compiler primitive. Measured after: `hello.wasm` and `webapp.wasm` leave `wasi_fd_write` and `wasi_proc_exit` undefined, and no longer leave `malloc` or `realloc`. Two alternatives were rejected: accepting wasi-libc as the platform's own runtime the way libSystem and kernel32 are accepted, and documenting wasm32 as a qualified target, both because either leaves an asterisk on a platform the owner named as a priority |

### B.2: The one decision the fork already made: **SETTLED: not a self-hosting project**

Crystal's compiler was written in Crystal before its 0.1.0, when the compiler
was 24,984 lines and the library 8,161. iyi begins from a fork: 95,010 lines of
compiler and 196,217 of library, none of it written in iyi, and none of it
compilable by iyi's own rules. The compiler is 87,421 lines since V.11 took the
interpreter out, which is the same decision read forward: a second
implementation of the language is a cost, and this fork does not pay it twice. The Appendix's own count says 77 of 484 types
are reopened across module boundaries, `String` by five modules.

The fork was the right call and it is why iyi has a working backend, a GC and a
measured thesis at 75 commits. It also bought that with something, and the
something is this: **self-hosting is the one cost that only rises.** Crystal
paid it at 33k lines total. iyi would pay it at 291k, against rules that forbid
the style most of those lines are written in.

So this is not a task that gets scheduled later; it is a door that is already
mostly shut, and the honest thing is to say so rather than leave it implied.
**Settled: iyi is not a self-hosting project.** Its compiler is and remains a
Crystal program, and the language's claim is what it compiles rather than what
compiles it. Go
is again the evidence for why that is survivable: `gc` stayed a C compiler
until Go 1.5 in 2015, nearly six years after the language was announced and
four point releases into Go 1, and nobody held it against the language.

The alternative (deciding that self-hosting matters) would have changed the
plan rather than added to it: it would make the compiler's own shape a design
input from here on, and III.4.7's measurement that the compiler is 38.5%
shareable *and stays there* is the first thing it would have collided with.
Deciding it now costs nothing; deciding it after the library exists would have
cost the library.

### B.1: Why #3, #4 and #7 are one decision

They are three requests for the same thing: **more reach for `!`**. Each is
individually reasonable and the three of them together are how this design
fails, so it is worth writing down once what they have in common rather than
answering each on its own merits.

`!` does exactly one thing: return early. It does not convert, does not widen,
does not reach into a second kind of absence, and does not run during unwind.
That is the whole of it, and the value of the design is in what the operator
**refuses** to do, not in what it does, because everything it refuses is a way
for a function's real error set to stop being the one written in its signature.

Go's own answer to this question is the evidence. The `try` proposal
(golang/go#32437, 2019) was not declined for being hard to implement. It was
declined because it hid control flow and made adding context to an error worse,
and Go took error *wrapping* instead. That is a language with the same taste as
this one deciding that the operator was the wrong place to spend the budget.

Taken one at a time:

- **#3, implicit conversion.** This is the decision that separates this design
  from Rust's. `?` plus `From` means the set of errors a function returns is
  computed by a trait resolution the reader cannot see, which is why that
  ecosystem grew libraries whose entire job is to make error types writable.
  Here the signature is the truth, and it stays the truth only if nothing
  silently rewrites an error on the way out. The replacement is not a
  conversion mechanism: error sets are aliases (III.1.2), so widening a return
  type covers most of what conversion is asked for, and it is free. Genuine
  conversion (deliberately *hiding* one error behind another) is rare, should
  look rare, and is an ordinary function call.
- **#4, nil propagation.** `T?` and error unions are different questions, and
  III.1.5 keeps them different. A `?`-propagating operator would put them in the
  same shape, and the pressure would then be to unify them: at which point
  `Nil` implements `Error` and the distinction is gone. Flow typing already
  handles absence, and it is the better tool: it forces the branch to be written
  where the absence means something, which is the whole reason absence is not an
  error.
- **#7, `!` in a `defer`.** A `defer` body runs while the function has already
  decided to return, and possibly while it is carrying an error of its own.
  Propagating a second error from there is the error-during-error problem, which
  is the ugliest corner of every language that has taken it on. A `defer` body
  handles its own failure, explicitly: `.or_panic` or ignore it.

None of the three is blocked on anything. They are not deferred to Draft 1; they
are answered.
