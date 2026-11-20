# Self-hosting: where the port is

An iyi program that compiles iyi. This directory is the front end being
written in the language it compiles, one slice at a time, with each slice
diffed against the compiler that exists.

## How it is checked

Not by reading it. `parser/oracle.cr` prints the tree the current parser
builds as a canonical S-expression; `parser/parser.iyi` prints the same
shape from its own tree; `parser/diff.sh` compares them.

```
bash selfhost/parser/diff.sh                      # the fixtures
bash selfhost/parser/diff.sh samples/iyi/*.iyi    # the real corpus
bash selfhost/parser/where.sh samples/iyi/*.iyi   # how far each one agrees
```

`diff.sh` is the gate: it exits non-zero when anything differs. `where.sh`
is the worklist: whole-file agreement moves one file at a time and hides a
slice that fixed nine tenths of twenty files, so it reports the column
where each file first disagrees and what the oracle had there.

Three things about the harness are load-bearing, because each one was
wrong first and made the port look better or worse than it was:

- The oracle sets the **filename**, because `Lexer#filename=` is what turns
  iyi mode on. Without it an `.iyi` file is parsed as Crystal, and
  `errors.iyi` died on the `!` that propagates.
- An oracle that prints **nothing** is its own row. Counting it as a
  difference made the current parser refusing a file look like the port
  disagreeing about it.
- The oracle prints **branches and members**, not just node names. `(if)`
  on its own lets a port that mis-read a condition agree with it.
- The corpus is listed with `find`, not with `selfhost/**/*.iyi`. That
  glob is `selfhost/*/*.iyi` unless `globstar` is on, which is 10 files
  where the port has 40. It matches, it passes, and it says nothing
  about the thirty it never read. Every count below that says "the
  port's own source" is 40 files: the parser agrees on all 40, and the
  lexer on 55 of those plus the prelude.

## Where CI runs them

Nowhere, until now. Every gate here was a script a person ran by hand,
so each number in this file held on one laptop and a regression would
have landed green. `.github/workflows/iyi.yml` now runs the string
invariants, the lexer, the parser, the declaration pass and inference
in a job of their own, and the codegen slice in the `darwin` job,
which is the one with a `clang` to assemble what the port emits.

A job of their own for two reasons, both learned by doing it the other
way first. Bolted onto `samples` they took that job past its 45 minute
timeout and cancelled twenty steps that had nothing to do with them.
And a gate that fails should name itself rather than arriving as
"samples failed".

Two things had to change for that to be honest. The gate scripts
replaced `PATH` outright with a Homebrew-first list, which is this
laptop's layout and nobody else's; they now prepend it when it exists
and leave the runner's own toolchain alone otherwise. And the
`windows-probe` job answered a failed link with `exit 0`, which
skipped the twenty runs underneath it and left the job green on a
build that never linked. Its three sibling steps already exited with
the linker's status.

## Where it is

Measured, not estimated: **all 27** files in `samples/iyi` produce a tree
identical to the current parser's.

```
bash selfhost/parser/diff.sh samples/iyi/*.iyi
  agree 27, differ 0, no oracle 0
```

The lexer slice (`lexer/`) agrees with the current lexer token for token
on **116 files**: every sample, every standard library file, the
prelude, and the port's own source.

## What the port carries

Module headers and the `Samples::InitOrder` camelisation; files with no
header at all; `import` hoisted when it leads and left in place when it
does not; `using`. `def` with typed arguments, return types, `forall`,
`abstract`, and the `@x` argument that is also an assignment. `trait`,
`struct`, `class` and `impl`, with type parameters on all of them.
Instance variables and field declarations. Types as a thing distinct from
expressions: generics, unions. `if`, `unless` as its own node, `elsif`,
`while`, `until`, the trailing forms, `return`, `&&` and `||` as the
short-circuit nodes they are. Calls with and without parentheses, chains,
`a[i]`, `a[i]?`, `a[i] = v`, blocks in both spellings. Literals: integer,
string, interpolated string, char, array, hash, tuple, range, `true`,
`false`, `nil`, and the empty forms that say what they are in an `of`
clause rather than in their braces.

## The next slices

Three corpora are closed: the samples, the prelude, and the standard
library. The parser also reproduces its own source, which is the largest
file under `selfhost/`. What no corpus exercises is what remains:
heredocs, regex literals, `lib` and `fun` bodies, `with ... yield`, and
the macro language itself, which every corpus skips to its `{% end %}`
rather than parsing.

One rule came out of the port reading its own source rather than a
sample: `"\#{"` is a `#` and a `{` with no interpolation, and `inspect`
writes the backslash back when it prints the value, because without it
a re-read would open one. The printer holds a `#` for one character to
see whether a `{` follows it.

## The semantic pass

`semantic/oracle.cr` is the first slice's oracle, and the slice is what a
file *declares*: for each type, its kind, its path, its parameters and its
methods. It already says something the parser cannot, which is the point
of the stage: a `struct Box` with `impl Show for Box` beside it answers
`show`, because the impl attached it.

```
bin/crystal run selfhost/semantic/oracle.cr -- samples/iyi/hello.iyi
```

It runs the pass on one file with no imports resolved, so **23 of 27**
samples answer and four do not. Those four are the measure of what
resolving imports would add, and they are reported rather than skipped.
The port is `semantic/declare.iyi`; its measured state is below.

After the parser: the semantic pass, then codegen, then the bootstrap,
each differentially tested the same way. The bootstrap is the acceptance
test and it is available from the first day the port parses anything: the
Crystal-written compiler and the iyi-written one compile the same corpus
and must agree.

## The prelude

`samples/iyi` was written for this language, so it says only what the
language was built to say. `src/iyi` was not: it is the prelude, written
before the port existed, and it is the second corpus.

    bash selfhost/parser/where.sh src/iyi/*.iyi

Measured: **17 of 17 files agree**. The second corpus closed the shapes the
samples never needed: compiler questions (`pointerof`, `sizeof`,
`instance_sizeof`), casts, `yield`, splats, symbols, macro loops,
keyword-named parameters, defaults, pointer types, uninitialized variables,
forwarded blocks, wrapping arithmetic, base-prefixed numbers, visibility
modifiers, and string escapes as values rather than spelling.

Two defects were in the harness rather than the language. A private method
whose body took a `do` block let the block's `end` stand in for the
method's, and `getter end : E` was mistaken for a block boundary. The full
corpus, rather than a hand-picked fixture, is what exposed both.

## The standard library

`src/std` is the third corpus and the one nobody wrote with a port in
mind: 67 files and 39,015 lines against the prelude's 17 and 15,907, and the
only corpus large enough that a first-divergence column was the only
usable worklist.

    bash selfhost/parser/where.sh src/std/*.iyi

Measured: **all 67 files agree**, from 16 when the corpus was first run.
One parser rule moved more than a dozen files at a time, which is why the
work was ordered by shared class rather than by file: absolute paths
(`::Atomic`), imports hoisted out of a file with no module header,
visibility on a declaration that is not a `def`, multiple assignment,
proc notation in a restriction, enum bodies that carry methods, the
semicolon as a statement separator, compound assignment, splat and
double-splat parameters and types, typed empty arrays, and multiline
argument lists.

Three of the last six were defects in the port's own reading rather than
missing grammar, and each one printed a plausible tree rather than an
error:

- A `do` block counted `end` without knowing that `{% end %}` closes a
  macro conditional, so a block containing one finished an `end` early.
  The block then swallowed the method's `end`, the method closed, its
  locals went out of scope, and a variable two lines later printed as a
  call. The fix was to read a `do` block with the same reader every other
  body already used.
- `yield (a | b).unsafe_chr` is a yield of one argument and
  `yield(a, b) > 0` is a comparison of what the block answered. The
  difference is the space, so the parentheses are the argument list only
  when they are adjacent to the word.
- A name declared with a type is a local inside a method and a field
  outside one. Registering both made every later read of a field print as
  a variable, in five files that had agreed before.

The corpus also closed `%w(...)` as one literal, `private record Name,`
continuing onto the next line, and a union alias wrapping after a `|`.
With those, the parser reproduces the tree of its own source: 3,777 lines
of iyi, printed identically by the compiler that exists and by the port.

`where.sh` is the worklist and `diff.sh` is the gate, and the gate takes
the same corpus:

    bash selfhost/parser/diff.sh src/std/*.iyi

It is load-bearing on this corpus too. Dropping the adjacency test that
separates `yield (a).b` from `yield(a).b` turns `agree 1` into
`differ 1` on `src/iyi/string.iyi`, and restoring the file byte-for-byte
turns it back.

## The declaration pass

`selfhost/semantic/declare.iyi` is the first semantic slice written in
iyi: what a file declares. It imports the parser, walks its tree, and
prints the same shape `selfhost/semantic/oracle.cr` reads off the real
top-level pass.

    bash selfhost/semantic/diff.sh

Measured: **23 agree, 0 differ, 4 with no oracle**. The four are
`collections`, `immutable`, `std_text` and `webapp`, where the pass
itself refuses the file because it resolves no imports; they are
reported rather than skipped so the number says what it covers.

Three rules in the port are the compiler's rather than the language's,
and each was read off the oracle rather than guessed:

* a trait that declares an associated type is a generic module, and
  prints as one;
* a generic class prints its parameters twice, in its name and again as
  its parameter list, and a generic module only once;
* an `impl`'s methods belong to the type it is for. `impl Show for
  Box(T)` puts `show` on `Box`.

Getting here split `selfhost/parser/parser.iyi` into a library and the
command that was at the bottom of it, `selfhost/parser/main.iyi`, since
a program cannot be imported and the semantic pass reads the same tree.

The gate is load-bearing: changing one method name the pass reports
turns `agree 1` into `differ 1`, and restoring the file byte-for-byte
turns it back.

### The prelude, declared

The samples corpus was written for this language and the prelude was
not, so the declaration pass gets the same second corpus the parser did:

    bash selfhost/semantic/diff.sh src/iyi/*.iyi

Measured: **13 agree, 2 differ, 2 with no oracle**, from 4 agreeing when
the corpus was first run. What it closed is what a declaration is, as
opposed to what a file says:

* A private method is a method the type has. The parser used to count
  `private def` to its `end` and throw the declaration away, so the
  modifier now carries it and the shape still prints the modifier alone.
* `def self.x` belongs to the type and `def x` to its instances. They
  print the same and land on different types, so the node carries the
  receiver the shape does not.
* An `alias` brings a type into being, and the pass reports it as one.
* `struct Int32` in the prelude does not build a struct: the compiler
  already holds that type and reports it by its own kind. The same is
  true of `Bool`, `Nil`, `Char`, `Symbol` and `Class`, and of `Tuple`
  and `Proc`, which the compiler holds with parameters the prelude does
  not write down.
* A struct answers `new`, so the compiler writes the `initialize` that
  `new` calls when the struct declares none. `Reference` is the root the
  compiler builds the same way.

Parsing a private declaration instead of counting over it found a
grammar gap the corpus had been hiding: `escape =` with its value on the
next line was read as an assignment of nothing followed by a statement,
in `src/std/eiy.iyi`, inside a private method nothing had parsed before.

The two that differ are both macro expansion, and neither is this
slice's: `primitives.iyi` writes six of `Char`'s methods with a
`{% for %}` loop, and `prelude.iyi` uses `property`, whose definition
arrives through a `require` this pass does not resolve. The macro
language is the next slice and these two are its measure.

### The standard library, declared

    bash selfhost/semantic/diff.sh src/std/*.iyi

Measured: **29 agree, 6 differ, 32 with no oracle**, from 13 agreeing
when the corpus was first run. Thirty-two files answer nothing because
the pass raises on a name an import would have brought, and they are
reported rather than skipped so the number says what it covers.

Two rules came out of this corpus, and both are about which type a
declaration names rather than what is in it:

* `struct ::Bool` is the root's type and `struct Bool` inside a module
  is that module's. Eleven files write the first and the port read them
  all as the second, so `Bool` was reported as `Std::Bool::Bool` and the
  prelude's type was never touched. The parser reads the marker and
  dropped it, because the canonical shape prints the path without it;
  now the node carries it.
* A file that opens `Std::File` and imports `std/path` did not bring
  `Std` into being, and the pass reports only what this file declared:
  such a file's own module is invisible to it and so is everything
  inside it, leaving `class ::File` and nothing else. A file that shares
  no root with what it imports, `samples/hello` importing `app/greeter`,
  declares its modules and their contents as usual. Getting this wrong
  in the other direction cost the samples corpus five files before the
  rule was measured rather than guessed.

`EOF` is one word: an underscore rule that broke before every capital
spelled the enum member `e_o_f?` where the compiler spells it `eof?`.
An enum body holds methods as well as members, and `NamedTuple` is
another type the compiler holds with parameters the source does not
write down.

What the six that differ measure is two things this pass did not do at
the time: five of them expand macros, and the section below closes
three of those. The sixth, `big.iyi`, writes no macro at all. It
reopens `Int32`, and the compiler reports every method that type has,
including the tower `std/int` writes, so reporting them means loading
what the file imports.

### Macros

A macro body is not iyi until it has run. `def add_{{suffix}}` is not a
method declaration and `{% if flag?(:darwin) %}` is not a statement, so
nothing downstream can read either until expansion. Crystal expands a
macro into source and parses the result, and `selfhost/macro/expand.iyi`
does the same for the shapes the corpora write:

    bin/iyi build -o macro selfhost/macro/main.iyi && ./macro src/std/errno.iyi

It carries `{% if %}`, `{% elsif %}`, `{% else %}`, `{% unless %}`,
`{% begin %}`, `{% for %}` over a literal list or map or over a name
bound above it, `{% name = ... %}`, and `{{ name }}` substitution. What
it cannot evaluate it drops, which is what the reader before it did with
every macro: a region that cannot be evaluated has no declarations
rather than wrong ones. Its flags come from its own `flag?`, because the
pass is built by the compiler it is measured against.

The declaration pass reads the file twice, and the second reading is
where the rule lives. A macro's *methods* land on a type the file
declared and are reported; the *type* a macro writes is not reported at
all, because its home is the expansion rather than the file. So
`errno.iyi` gains the members its platform branch lists and does not
gain a constant for each of them, and `primitives.iyi` gains the six
operators a loop writes onto `Char` without the file appearing to
declare `Int32`.

This closed `atomic.iyi`, `errno.iyi` and `primitives.iyi`: the prelude
corpus went to **14 agree, 1 differ** and the standard library to
**31 agree, 4 differ**. The expansion is load-bearing: making the map
loop run no times turns `atomic.iyi` from `agree 1` into `differ 1`, and
restoring the file byte-for-byte turns it back.

One more rule, and the corpus that found it was the port's own source.
A macro delimiter written inside a comment or a string is text about
macros rather than a macro, and the expander was reading the raw bytes:
`selfhost/parser/parser.iyi` explains `{%` in a comment and spells both
delimiters as string literals a few lines below, so the expander read
the first as an opener, the second as its close, and deleted the 967
lines between them. The class the deletion ran through lost its `end`,
and `dump_all` was reported as the module's method as well as the
class's. The search now walks code only, skipping comments, string
literals and character literals, which took a second bug with it: an
escape is two bytes, and stepping three over `"\\"` put the scanner
inside every string from there on.

Load-bearing: searching the raw bytes again turns `parser.iyi` from
`agree 1` into `differ 1`, and restoring the file byte-for-byte turns
it back. The port's own source is now the fourth declarations corpus:
**5 agree, 0 differ, 5 with no oracle**.

Walking code rather than bytes made the expander slower, and it was
slower in a way worth measuring rather than tolerating. Two changes,
both checked rather than assumed. A file with no `{%` and no `{{` in
it expands to itself, so the walk that proves that is skipped. And
the scan starts where the caller asked rather than at the top of the
file: every caller passes a position an earlier scan already left
outside a comment and outside a literal, so the state it needs is the
state it has. Expanding all 84 files of the prelude and the standard
library gives output identical byte for byte either way, in two
thirds of the time.

What was left after that was one file. `src/iyi/prelude.iyi` took 31
seconds where the other sixteen prelude files took 0.3 between them,
and every guess about why was wrong. Not the code-aware scan:
pointing the delimiter searches back at the raw bytes changed 29.4
seconds into 29.9. Not the multibyte characters in its comments:
rewriting every one of them as ASCII changed 32.8 into 33.3. Not the
slicing, which copies 3MB across 24,716 calls, and not the
concatenation, which builds 400KB in 0.4 seconds on its own.

A profile answered it in one run where six ablations had not. Almost
all of the time was inside `String#+`, in two places: `character_count`,
which walks every byte of the result to count its characters, and
`Pointer#copy_from`, which copies one byte at a time.

The first of those is now fixed, in the prelude rather than in this
pass. The characters of `a + b` are the characters of `a` and then
those of `b`, because a byte that starts a character in either one
still starts one after the join, so the count is the sum and the scan
is redundant. Doing it on every `+` made building any string in a loop
quadratic in its own length. `String.new` gained an overload that is
told the count instead of finding it, and `+` uses it: the prelude
expands in 22.3 seconds rather than 29.4, to the same 5,586 lines, and
a benchmark that concatenates 400KB drops from 0.41 to 0.30.

That change needed a gate that did not exist. A wrong character count
is not a crash: it is a number that comes out quietly wrong somewhere
far away, and nothing in this repository would have caught one. The
specs are the compiler's rather than the prelude's,
`bench/samples_roundtrip.sh` compares a program against itself, and
the samples have no expected output pinned. So `+` reporting four
characters where it holds five would have passed every check there
is, including all six corpora above.

`bench/string_invariants.sh` runs one iyi program and diffs nineteen
answers against the ones written down beside it: ASCII, one multibyte
operand, two multibyte operands, the empty-operand short path that
returns the other string whole, and a hundred concatenations in a
loop. Load-bearing, both ways it can be got wrong: telling the join
one side's count instead of the sum, or telling it the byte count
instead of the character count, each turns it red, and restoring the
file byte for byte turns it green.

The second half of that profile is `Pointer#copy_from`, which copies
one byte at a time, and the obvious answer is closed. `memcpy` would
mean calling libc, and on Linux this prelude calls libc for nothing:
it issues its own syscalls for `write`, `exit` and the allocator, and
`nm -u` on the emitted object prints nothing at all. That is a stated
property of the fork, not an accident, and the `lib LibC` blocks in
`prelude.iyi` bear it out: there are seven, under `darwin` and
`win32`, and none under `linux`.

What is left is a word at a time rather than a byte, written in iyi,
and it is done. `String.copy_bytes` moves eight bytes at a time when
both ends are eight-byte aligned and one at a time when they are not.
Only when both are aligned: an unaligned 64-bit access is fine on two
of the nine targets this compiles for and a question on the rest, so
it is not attempted. That still catches the copy that matters, because
a string's bytes begin one header along from an allocation and the
allocator returns aligned memory, so building a string in a loop
copies the accumulator by word every time.

Together with the count, expanding `src/iyi/prelude.iyi` went from
31 seconds to 3.5, to the same 5,586 lines, and the 400KB
concatenation benchmark from 0.41 to 0.12.

Gating it meant admitting the first gate could not see it. Counting
alone passed three mutations of the word loop, because the fixture's
longest string was built two bytes at a time and only its length was
compared. It compares bytes now, through a position-weighted checksum,
across a string joined at a multiple of eight and one joined a byte
off it. Shifting the word read by one, or copying every other word,
each turns it red; removing the word path entirely leaves it green,
which is right, because that is slower and not wrong.

Reading the prelude without expanding it is still what the codegen
slice does, and what that costs was re-measured once expansion got
cheap. Wiring it into the emitter takes the thirteen fixtures from
11.6 seconds to 31.6, and all thirteen still agree: 2.7x rather than
the 25x it was, and a price a slice could now pay. It is still not
wired, because it buys nothing yet. The conversions `wide.iyi` writes
are answered by a table of names in the emitter rather than by reading
what `primitives.iyi` declares, so no fixture reaches a macro-written
declaration. The slice that replaces that table with a read is the
slice that pays for it.

The four that remain need what a macro cannot give them. `named_tuple`
is missing exactly the methods `tuple.iyi` declares, `traits` and
`float` are missing the integer tower that `std/int` writes, and
`big.iyi` imports `std/traits`, which imports both. They are one
capability away, and it is the same one the bootstrap needs: loading
what a file imports.

### What a file imports, and what it requires

Both corpora are closed now, and they were closed by two different
edges. An `import` is a module edge: what it brings is another module's,
and `std/traits` reopening `Int64` expects to find the tower `std/int`
wrote. A `require` names a file rather than a module, relative to the
file that wrote it, and what it brings is read as if it had been written
there: `src/iyi/prelude.iyi` is seventeen files and one program on this platform.

The distinction is load-bearing beyond resolution. A struct is given the
`initialize` that `new` calls when it declares none, and the compiler
writes that once, where the struct was declared. For an import that is
the other module: `src/std/named_tuple.iyi` reopens a `NamedTuple` that
`src/std/tuple.iyi` owns, and only `tuple.iyi` reports the `initialize`.
For a require it is this program's own text, so `prelude.iyi` reopening
the `Pointer` that `primitives.iyi` declared reports it. All three were
measured before the rule was written.

A macro runs where its declaration reaches the file, which is the same
edge again. `getter` and `property` are declared in `src/iyi/macros.iyi`,
so a module file writing `getter a : Int32` declares no reader at all,
and the compiler agrees: it reports the type with `initialize` and
nothing else. `prelude.iyi` requires that file, so its `property
next_node : IyiDeferNode?` writes the reader, the writer and the field.
The expander answers what such an argument is, with
`name.is_a?(TypeDeclaration)`, and the two halves of it, with `name.var`
and `name.type`.

A `lib` is a type the compiler prints as `libtype` and the functions it
declares are its methods. There is no body to walk, so the parser keeps
the names while it skips to the end.

Measured after all of it: the standard library **35 agree, 0 differ**,
the prelude **15 agree, 0 differ**, the samples **23 agree, 0 differ**.
Every file with an oracle agrees with it. The expansion is load-bearing:
making `expand_calls` return its source unchanged turns `prelude.iyi`
from `agree` into a file missing exactly `next_node` and `next_node=`,
and restoring it byte-for-byte turns it back.

## The inference slice

`semantic/infer.iyi` infers the return type of every called internal method
in `semantic/fixtures/infer.iyi`. The oracle runs `Program#semantic` and
reads the typed `DefInstance` objects the current compiler created:

    bash selfhost/semantic/infer_diff.sh
    agree: <Program>#integer=Int32 <Program>#maybe=(Int32 | Nil) <Program>#text=String <Program>#truth=Bool

This slice is call-driven rather than another declaration walk. The fixture
contains an uncalled method and neither side reports it. The iyi pass carries
literal types, typed parameters, local assignment and lookup, expression-list
results, and branch unions. Its gate is load-bearing: changing the inferred
integer type to `Int64` changes two answers and exits non-zero; restoring the
source byte-for-byte returns the exact four rows above.

The second fixture, `fixtures/infer_calls.iyi`, carries what a body does
rather than what it holds, and `infer_diff.sh` now runs every fixture,
because a slice that grew a second one and kept checking the first proves
only the first:

    infer.iyi agrees: <Program>#integer=Int32 <Program>#maybe=(Int32 | Nil) <Program>#text=String <Program>#truth=Bool
    infer_calls.iyi agrees: <Program>#character=Char <Program>#early=(Int32 | String) <Program>#fraction=Float64 <Program>#leaf=Int32 <Program>#loops=Nil <Program>#reaches_leaf=Int32 <Program>#recursive=Int32

Five things the first fixture did not say:

* A call to a method in the same file is typed by that method, which is
  the first answer reading one method cannot give.
* A method that reaches itself is typed by the way out that does not.
  The recursive call answers nothing, and nothing is what a union with it
  drops.
* A body has more than one way out. `early` returns a `String` and ends
  on an `Int32`, and the answer is both. A body that ends in a `return`
  is worth nothing on its own, which is how `recursive` answers `Int32`
  rather than `(Nil | Int32)`.
* A loop is not a value.
* `1.5` is a `Float64` and `'c'` is a `Char`. A literal's suffix is not
  here: the lexer drops it, so `1_i64` arrives as `1`, and neither
  fixture writes one.

The second gate is load-bearing too: dropping the collection of `return`
types changes two rows and exits non-zero, and restoring the file
byte-for-byte returns the rows above.

### A method on a value

The third fixture, `fixtures/infer_types.iyi`, is the first one with a
type in it, and it is where inference stops being a walk over one file's
top level:

    infer_types.iyi agrees: <Program>#make_label=Label <Program>#make_point=Point <Program>#reach_field=Int32 <Program>#reach_self=Int32 Label#initialize=String Label.class#new=Label Point#first=Int32 Point#initialize=Int32 Point#x=Int32 Point#y=Int32 Point.class#new=Point

Eleven rows, and each one is a different question:

* A constructor is worth the type it builds, and it reaches the
  `initialize` that the `new` the compiler writes calls. That `new`
  lives on the metaclass, which is why it prints as `Point.class#new`.
* `initialize` needs no special case. The parser writes
  `def initialize(@x : Int32, @y : Int32)` as two arguments and two
  assignments, so it is typed by its body like anything else, and the
  body ends on `@y = y`: `Point#initialize` is an `Int32` and `Label`'s
  is a `String`.
* A field's type is read off that same constructor. Reading it means
  inferring a body, and that is not a call, so it is done with recording
  turned off: a field read must not make `initialize` look reached.
* A call on a local is looked up on the local's type. `point` carries
  what `make_point` answered.
* A call written with no receiver inside a method is a call on that
  method's own type before it is one on the program. `Point#first` calls
  `x`, and `x` is `Point`'s.
* Nothing calls `Point#unused` or `Label#text`, and neither side reports
  them. `Point#x` is reported because `first` reaches it, not because it
  is declared.

No fixture calls a method the prelude owns. The pass runs on one file
with no prelude, so `i < 3` is an undefined method rather than a
comparison, and the first attempt at the second fixture died on exactly
that. Typing `1 + 1` means loading the prelude, which is the work the
bootstrap needs.

This gate is load-bearing as well: making the receiver lookup refuse the
types it knows turns `reach_field` and `reach_self` into `Unknown` and
exits non-zero, while the two fixtures with no receiver in them keep
agreeing. Restoring the file byte-for-byte returns the rows above.

### A method the prelude owns

The wall the first three fixtures named was `1 + 1`. They ran on one
file with nothing under it, so there was no `+` to reach, and the
fixture that tried died on exactly that. `fixtures/infer_prelude.iyi`
requires the prelude, which is what the bootstrap does:

    infer_prelude.iyi agrees: <Program>#fraction=Float64 <Program>#length=Int32 <Program>#sum=Int32 <Program>#through_local=Int32 <Program>#wider=Int64

R-2 is what makes this tractable rather than a second compiler. An
exported method carries its return type, so a required method is typed
by reading its declaration rather than by inferring its body:
`def to_i64 : Int64` answers an `Int64`, and `def +(other : Int32) :
self` answers whatever the receiver is. Nothing in the prelude is
inferred and nothing in it is reported: a row is this file's method or
it is nothing.

Two things had to be true for `1 + 1` to answer `Int32`.

The prelude writes its integer tower with a macro. `to_i64` and `+` are
not written anywhere in `src/iyi`: they are a `{% for %}` over a map and
a cross of operators in `src/iyi/primitives.iyi`, so the pass expands
each required file before reading it. Reading the source instead finds
no method of that name at all, which is what the mutation proof shows.

And `self` in a type position is its own node rather than a path.
Reading the return type as a path answered nothing, so every operator
the prelude declares that way came out `Unknown` while `to_i64` was
already right. A call with an argument also has to choose among
overloads, and it chooses by the type of the first argument: `1 + 1` and
`1 + 1.5` are one name and two answers.

Writing this slice found a defect in the expander rather than in the
prelude. `macro_params` asked a string for its last bracket with
`rindex`, which is a method `std/text` adds, and `selfhost/macro/expand`
imports nothing. It compiled anyway, because the declaration pass that
uses it does import `std/text`, and the macro driver on its own stopped
building. A module that leans on what another file imported is not a
module.

This gate is load-bearing: reading the required files without expanding
them turns `sum`, `fraction` and `wider` into `Unknown` and exits
non-zero, while the three fixtures with no prelude under them keep
agreeing.

## The lexer, on everything

    bash selfhost/lexer/diff.sh              # 27 samples
    bash selfhost/lexer/diff.sh src/std/*.iyi  # 67 of the standard library
    bash selfhost/lexer/where.sh <file>      # the first token that differs

Measured: **116 files agree, 0 differ**, from 6 when the corpus skipped
every file with a `#{` in it. Four files have no oracle at all, which is
reported rather than skipped.

The skip was the point. Twenty-one files were out of scope for
interpolation, and eleven of them turned out to differ for reasons that
had nothing to do with it: `**`, `//`, `@[`, `{%`, `{{`, `%w(`, symbols,
a line continuation, a byte-order mark. Nothing was wrong with the
measurement while those files sat outside it, and nothing was right
either.

What interpolation needed is a lexer that holds what it is in the middle
of. A string body is not code and an interpolation inside one is, so the
two alternate and they nest: `"to_a #{n.to_a.join(",")}"` is a string
holding code holding a string. The port keeps a stack of modes and the
oracle keeps the same stack, because the current lexer only reads a body
when a parser tells it to.

Three of the differences were in the instrument:

- After `INTERPOLATION_START` the driver kept asking for string tokens,
  so `#{name}!` read as the string `name}!`. An interpolation is code.
- A string written inside an interpolation ends back into that
  interpolation, not into the string around it. Popping the wrong
  context made the quote after it open a second string that ran to the
  end of the file.
- A stream that stops where the lexer raised is not an oracle. The
  prelude reaches a `{%` the lexer wants a parser's macro state for, and
  the tokens before it looked like agreement followed by a difference
  that was ours. The oracle now prints nothing unless it reaches the
  end, and `diff.sh` reports the file as having none.

Two rules were measured rather than assumed. A number is reported as
what it means: `0x80` is `128`, `0xFFFFFFFFFFFFFFFF_u64` is
`18446744073709551615`, and `1_000` is `1000`, while `1e3` stays as it
was written. And `empty?`, `nil?` and `in?` are one word where `to_u64!`
and `end!` are two, so a question mark is part of a name here and a bang
is not.

The gate is load-bearing: making the interpolation branch match a
character that never appears turns the sample corpus from 27 agreeing
into 6, and restoring the file byte-for-byte turns it back.

## The codegen slice

    bash selfhost/codegen/diff.sh
      across.iyi agrees: exit 37
      arith.iyi agrees: exit 11
      branch.iyi agrees: exit 16
      control.iyi agrees: exit 16
      dispatch.iyi agrees: exit 31
      generic.iyi agrees: exit 48
      loop.iyi agrees: exit 32
      nested.iyi agrees: exit 14
      print.iyi agrees: exit 3, 60 bytes out
      reference.iyi agrees: exit 8
      struct.iyi agrees: exit 10
      text.iyi agrees: exit 87, 6 bytes out
      wide.iyi agrees: exit 88
      agree 13, differ 0

Every other slice diffs an artifact: a token stream, a tree, a
declaration, a type. Two independent backends do not write the same LLVM
IR, and diffing the text would measure spelling rather than meaning. So
this slice compares what the programs *do*. Each fixture ends in
`__iyi_exit`, which is the prelude's own exit, so it is an ordinary iyi
program the current compiler builds and runs. The port emits LLVM IR,
`clang` assembles it, and the gate compares the status the two processes
exit with.

A fixture that exits 0 and prints nothing would pass for free either
way, so the gate refuses one and says why rather than counting it.

Scope, and it is narrow on purpose: integer literals, `+`, `-` and `*`,
comparisons, `if`, `while`, local assignment and lookup, arguments, a
call to a method in the same file, `print` of a literal, and a struct
with fields and methods, a class, which is a reference, a generic type
with its instantiations, a string as a value, the integer tower with
its conversions, a program spread over more than one file, and the
rest of the control flow: `return`,
`unless`, `&&`, `||`, `!`, `next`, `break`, `case` and a typed local.
Not here: anything that would need the prelude compiled first, which
is measured at the end of this section.
The sections
below are the fixtures in the order they were written, and each names
what it added and how the gate was made to fail without it.

One thing the slice is allowed to assume, and it is the prelude's
doing: the operators are primitives, so `@[Primitive(:binary)] def
+(other : Int32) : self` is an instruction and `add` can be emitted
without reading a body.

A local lives in a slot rather than a register, so an assignment can
rewrite it without asking which branch wrote it, which is what the
branch fixture below leans on.

The second fixture is there because the first is one operation per line,
which an emitter reading left to right would also get right.
`triple(a) + b * 2 - 1` is three operators of two precedences with a
call in front of them, and what decides the answer is the shape the
parser built.

Writing this cost an hour to a keyword. `out = body.register` is not an
assignment, because `out` is a keyword, and the block it was written in
never closed: the error the compiler printed was `can't export inside
def` at the next method, thirty lines below. The port's own parser reads
`out` as a keyword too, so it agrees with the compiler about the file
and neither says why.

The gate is load-bearing: emitting `add` where the instruction is `mul`
turns 11 into 10 and 14 into 8 and exits non-zero, and restoring the
file byte-for-byte turns it back.

### A branch

`fixtures/branch.iyi` is the first shape this slice cannot emit by
appending. An `if` is two blocks and a value that depends on which one
ran, so the emitter tracks which block it is writing into and ends each
arm with a `phi` naming what the arm answered and where it answered
from. That block is the one the arm *ended* in rather than the one it
started in: an `if` inside an arm leaves the cursor somewhere else.

An arm with nothing in it answers zero, which is what an `if` with no
`else` is worth on the side that did not run. `clamp` writes its answer
into a local instead, and the `phi` it leaves behind is dead.

The comparison in front of a branch is a primitive as well, and it is
the first value in this slice that is not an `i32`:
`def <(other : Int32) : Bool` is an `icmp` answering an `i1`. A
condition is the only place one appears, because nothing here stores a
`Bool`, returns one, or prints one.

Two mutations, and the difference between them is worth keeping.
Swapping the `phi`'s arms is caught, but by LLVM's own verifier
(`Instruction does not dominate all uses`), which is the gate refusing
to assemble rather than measuring an answer. Emitting `sgt` where the
comparison is `slt` is the pointed one: `branch.iyi` exits 12 where the
current compiler exits 16, while the two fixtures with no comparison in
them keep agreeing.

### A loop

`fixtures/loop.iyi` is a branch that goes backwards. The condition gets
a block of its own, because it is asked again on every turn, and the
body ends by branching to it. What makes it cheap is the slot decision
above: the counter is loaded where it is read and stored where it is
written, so nothing has to be threaded around the back edge.

A loop is not a value, which the inference slice already said. It
answers zero and the method answers what follows it.

The second method in that fixture has a branch inside the loop, so one
method holds the condition block, both arms, the join, the body and the
exit: six blocks, and the `phi` in the middle of them has to name the
arm it came from rather than the loop it is in.

Load-bearing, and without hanging the gate: sending the body's back edge
to the exit instead of the condition runs each loop once, so `loop.iyi`
exits 1 where the current compiler exits 32.

### What it prints

`fixtures/print.iyi` moves the observable from a number to bytes, which
is what a compiler is eventually judged by. The gate compares stdout as
well as the status, and a fixture that exits 0 *and* prints nothing is
refused rather than counted.

A literal becomes a module constant, and every byte that is not plain
printable ASCII is written as two hex digits, because a newline inside a
constant would end the line it is written on. `print` is an intrinsic
the same way `+` is: the prelude declares both and the backend knows
what they do. That was the whole of what this slice knew by name; the
string and integer slices below add `bytesize`, `size` and the
conversions, and each one says what it is borrowing.

This slice does not build an iyi `String` - a bytesize, a length and
the bytes - because nothing in the fixture asks a string for anything.
It writes the bytes the literal holds, which is all `print` of a
literal does. The slice that does build one is further down.

One thing is borrowed from outside the program being compiled: the write
itself. The current compiler emits the syscall; the port calls the C
library's, and what the gate compares is the bytes that reach stdout
either way. A port that emitted the syscall directly would be measured
by the same diff, which is why this is a scope note rather than a
dependency.

Load-bearing: passing `bytesize - 1` to the write drops a byte from each
line, the statuses still match, and the gate fails on the output.

### A type with fields

`fixtures/struct.iyi` is the first value with a shape. Everything before
it was an `i32` in a register or a slot, so the emitter could assume one
type and never ask. A struct makes it carry what each value is, and that
is what this fixture paid for: every expression now answers its text
*and* its kind, and a store, a load and an argument are written from the
kind rather than assumed.

`Point` is two `i32`s side by side. The fields are read off the
constructor, which the parser already writes as an argument and an
assignment, so their order is the order the assignments are made.

A struct is passed by value, which is what makes this a first slice with
a type in it: nothing is allocated and nothing is collected. `self`
arrives as the first argument and is put in a slot, so a field read is
the same shape as a local read - an offset and a load - and a method
that names no receiver finds the struct it is already inside.

The `new` the compiler writes is emitted as a function that runs the
constructor's body against a value of its own and answers it, so an
`initialize` doing more than assigning its arguments still works: the
body is emitted rather than pattern-matched.

Load-bearing: fixing every field offset at zero makes both readers
answer `@x`, and `struct.iyi` exits 8 where the current compiler exits
10.

Writing this found a parser gap, and the port's own source is what found
it. An `if` used as an operand inside a `do` block, `text = text + if
cond ... end`, had its `end` counted as the block's, so the block closed
early and the method's last expression became a statement of its own.
The rule said an `if` opens a block after a newline or an `=`, and `=`
is only the most common operator rather than a case of its own.

Read the other way round the rule is wrong twice. The first attempt
asked whether the token before the word could end an expression, which
makes `next if done` and `return 0 if n < 0` into blocks: both follow a
keyword and both are modifiers. Four files caught it, and the rule that
holds names the openers rather than guessing at the closers.

### A class, which is a reference

`fixtures/reference.iyi` is the same fields as the struct and a
different thing to pass around. The fixture is built so that getting it
wrong changes the answer rather than the shape of the IR: `bump` is
called twice on one counter, and a port that copied the object by value
answers 7 - or 6, which is what it actually answers, because the writes
land on copies that are then thrown away.

A reference prints as `ptr` and every reference prints the same, so a
value has to carry which type it is as well as how it prints. That is
the second thing the emitter learned to track, after the struct made it
track kinds at all: `Val` holds a text, a kind and a shape, and dispatch
reads the shape while a store reads the kind.

A field is then an offset into what the pointer points at rather than
into the slot: the slot holds the pointer, so it is loaded first and the
offset is taken from that. The constructor is the same function it was
for a struct except that it begins by asking `malloc` for the bytes -
four a field, because every field here is an `Int32` - and stores what
it answered into `self`.

What this borrows is a heap. The current compiler brings its own; this
calls the C library's `malloc` the same way it calls `write`, and
nothing frees anything. A collector is not a codegen slice.

Load-bearing: emitting a `class` as a value turns `reference.iyi` from 8
into 6 while the struct fixture keeps agreeing, which is the difference
between the two fixtures and nothing else.

### The rest of the control flow

This fixture was measured rather than chosen. Counting the shapes the
port's own source writes against the ones the emitter carried, the
cheapest remaining class was control flow: `and` 381 and `or` 461,
`return` 440, `not` 116, `bool` 113, `unless` 80, `next` 30 and `break`
10. None of them needs anything from the prelude, which is what makes
them a fixture rather than a plan.

`&&` and `||` are blocks rather than instructions, because they answer
without asking the other side when the first one settles it. A `return`
ends its block, so what follows one is written into a block of its own
that nothing branches to. `next` and `break` are branches to labels the
loop holds, and it holds a stack of them so an inner `break` leaves the
inner loop.

The first version of this fixture was wrong, and the mutation proof is
what said so. Every `&&` and `||` in it settled on the second side, so
swapping what a short circuit answers when it stops early changed
nothing: the fixture exercised the blocks and never the short cut. It
now calls `both(0, 1)` and `either(1, 0)`, which are the two cases where
the first side decides.

Load-bearing both ways round. Emitting the branch as an unconditional
jump is caught by LLVM's verifier, because the `phi` then has a
predecessor it does not name. Swapping what the short circuit answers is
the pointed one: `control.iyi` exits 17 where the current compiler exits
16.

### A case, and a local that says its type

The two shapes left that need no prelude: `case` 27 with `when` 86, and
`typedecl` 192.

A `case` over values is a chain of comparisons, which is what it
becomes once the subject is an integer. The subject is emitted once
into a slot, because a `case` over a call must not call it again per
arm, and each `when` gets a block that answers and a block that asks
the next one. The `else` is whatever the last `when` fell into, and the
`phi` names every arm that answered.

A typed local cost a change to the parser rather than the emitter.
`total : Int32 = 6` prints as a declaration and the value is not in the
shape, so the tree the port builds could not carry it, the way
`RequireNode` could not carry its path. The node carries it now and
prints the same.

That is also the second fixture this session that was wrong until a
mutation proof said so. It declared `total : Int32 = 0`, so ignoring
the value entirely still answered 25: the fixture exercised the
declaration and never the value. It declares 6 now, and ignoring the
value answers 25 where the current compiler answers 31.

Load-bearing: inverting the `when` comparison makes every arm answer
the wrong one, and `dispatch.iyi` exits 15 where the current compiler
exits 31.

### A generic type, one copy per type argument

`generic` is the most common shape the port's own source writes that
the emitter did not carry, at 241, and it is the first thing the
prelude needs: `Pointer(T)`, `Array(T)` and every container under them
are generic. It is also the first shape where one written type becomes
more than one emitted type.

`generic.iyi` writes `Box(T)` and `Pair(A, B)` and then asks for
`Box(Int32)`, `Box(Bool)`, `Pair(Int32, Int32)` and
`Pair(Bool, Int32)`. The emitter keeps the written type as a template
and never emits it. Naming an instantiation copies the template, binds
the parameters to the arguments, and adds the copy to the same list of
shapes under a name that carries the arguments:

```
%Box.Int32 = type { i32 }
%Box.Bool = type { i1 }
%Pair.Bool.Int32 = type { i1, i32 }
```

A field's type comes from the constructor argument it was assigned, so
`@value = value` with `value : T` records `T` and the instance answers
what `T` was bound to. The list of shapes is walked by index rather
than with `each`, and the program is emitted before it, because naming
`Box(Int32)` is what brings that shape into being: the list grows while
it is read.

Load-bearing, and the failure has a different shape from every slice
before it. Taking the substitution away - a parameter answers as
itself - makes every field an `i32` while the calls still pass an `i1`,
and the module stops assembling: `generic.iyi` fails where the other
twelve keep agreeing. LLVM IR is typed, so a wrong substitution cannot be
a quiet wrong answer here; it is a module that does not exist.

### A string as a value

Every slice before this one was chosen so that it needed nothing of
the prelude compiled. This one needs one thing, and it turns out to be
a shape rather than a body: `String` is laid out by the compiler
itself, in `Program#initialize`, as `@bytesize`, `@length` and the
bytes, with the type id in the word underneath the pointer. The
prelude reopens that type and says what can be done with it; it does
not decide what it is.

So the emitter borrows the layout the way it already borrows `write`
and `malloc`. A literal becomes a constant with that shape, a local
holding one is a pointer into it, and the two methods that read the
header answer out of the header:

```
@text0 = private unnamed_addr constant { i32, i32, i32, [5 x i8] }
           { i32 0, i32 5, i32 5, [5 x i8] c"hello" }
```

`text.iyi` passes strings to a method, prints one, and adds up what
`bytesize` and `size` answer. One of them is `"héllo"`, six bytes and
five characters, because a fixture where the two counts are the same
number cannot tell them apart - the first version of this one summed
them and passed with the header reversed.

Load-bearing twice over, and both failures are wrong answers rather
than broken modules. Swapping the two counts in the constant makes
`text.iyi` exit 78 where the current compiler exits 87. Taking the
header as four bytes rather than eight leaves the status alone and
writes the wrong bytes, which the gate catches because this fixture
prints.

What it still cannot do is make a string: that needs the allocator and
the collector, which is the bootstrap.

### The integer tower

This one was found rather than chosen. Every integer in the slices
above was emitted as an `i32`, `Int64` included, because nothing had
asked for a second width yet: `kind_of` answered `i32` for `Int64` and
`UInt64` both, and the gate had no fixture that could tell. A program
that doubles two billion can, and the port answered 0 where the
current compiler answered 40.

The whole tower is primitives, so none of it needs a body compiled. A
conversion is a `sext`, a `zext` or a `trunc`, decided by the two
widths, and an instruction reads two operands of one width, so the
narrower side is widened first. `//` and `%` arrived with it, since a
bare `/` on two integers is a `Float64` this slice does not carry.

Signedness is the other half, and it is not a width. `//`, `%` and
every ordering comparison have two spellings, and the sign of a
widening comes from the value being widened rather than from what it
is being widened to. `200.to_u8.to_i32` is 200 because the byte is
unsigned, whatever the `Int32` on the other side of it says.

`wide.iyi` exercises five rules and each one is load-bearing on its
own: one width for every integer (the port exits 39), division always
signed (79), comparison always signed (83), every widening signed
(52), and a literal always an `i32` (147), against 88.

One of those took two attempts to make fail. A signed byte and an
unsigned one differ by exactly 256, and an exit status keeps only what
is under that, so the fixture divides the byte rather than adding it.
A fixture that cannot see the defect is not a gate, and multiplying it
by three does not help: that difference is 768.

### More than one file

Every fixture until here was one file, which let the emitter read the
tree it was handed and emit what was in it. The bootstrap cannot be
one file: `src/iyi/prelude.iyi` is seventeen of them and one program,
and reaching a method the prelude writes means reading the file that
wrote it first.

A require names a file, relative to the file that wrote it, and what
it brings is read as if it had been written there. The emitter reads
the required file before the requiring one and puts its items in
front, and reads a file once however many paths reach it:
`across.iyi` requires two files and the second requires the first.

The prelude is read like any other require now, and it was not while
emission followed the file: reading it then meant emitting all of it,
and following it for the first time stopped ten fixtures assembling
at once. Once emission followed the calls instead, the seventeen files
under `src/iyi` became declarations in scope and nothing else. What
the port still borrows out of the prelude rather than compiling is
`write`, `malloc` and the string layout.

That move needed one rule. A type reopened in another file is the
same declaration continued, which is what a require means:
`counter.iyi` reopens the `Tally` that `helpers.iyi` declared and
adds a method to it. Declaring it twice instead puts two `%Tally` in
one module and `across.iyi` stops assembling.

Load-bearing both ways. Following no require at all leaves `tripled`
undefined and `across.iyi` exits 0 where the current compiler exits
37; reading a file once per path that reaches it emits `tripled`
twice, and a module with two of a function in it is not a module.

### Reaching, not reading

Reading more than one file makes the other half of the bootstrap
visible immediately. A file is not a list of things to emit: the
prelude declares thousands of methods and a program calls a handful,
and emitting a declaration nobody reaches means compiling shapes the
program never asked for.

So emission follows the calls. The program is emitted first, a call
puts the name it reached on a list, and the list is drained rather
than walked, because emitting one body reaches more. Functions and
methods share the list, under the name each is mangled to, because
emitting either can reach either: a method calls a function, a
function makes an instance, and naming `Box(Int32)` brings a shape
into being that was not on the list when it started.

`shared/helpers.iyi` carries two things the emitter cannot compile, a
function and a method on a type the program does use, both answering
a `Float64` this slice does not have. `across.iyi` is unaffected by
either. Reading the file instead - walking every declaration and
every method of every type, which is what this did before - writes
`ret i32 2.5` and the module stops assembling. That is the shape of
every file the bootstrap will read.

### What the bootstrap still needs

The same count says what is left. In the port's own source: `cast`
137, `stringinterpolation` 167, `arrayliteral` 127, and a scattering
of `procliteral`, `hashliteral` and `yield`. The `cast` count is
smaller than it was: a conversion between two integers is one of
those, and the tower slice carries it. The string slice above
shows what separates them from the shapes already carried, and it is
not the type: a literal `String` needed a layout the compiler decides,
and every one of these needs a *body* the prelude writes. An
interpolation calls `to_s` and concatenates; an array literal
allocates and grows; a proc is a closure the runtime carries.

The wall has moved. It used to be that the prelude could not be read
at all; it is read now, and no body of it is emitted because no
fixture reaches one. The next slice is the first program that does,
and what it will need is the part of `src/iyi` that has no iyi under
it: the collector, the syscalls, and the three borrowings this slice
still makes - `write`, `malloc` and the string layout - which are
exactly what compiling the prelude would replace.

### A zero that was an answer

Reaching for the next slice found a defect in this one. `Int32#abs` is
declared in `number.iyi` as `self < 0 ? -self : self`, a body written in
iyi rather than a primitive, and the emitter has no way to compile it
yet. What it did was return a literal zero. So a program writing
`(0 - 9).abs` emitted `add i32 %t, 0`, the module assembled, the program
ran, and it exited 0 where the compiler exits 39.

Every fixture passed throughout, because none of them reaches one. That
is the shape of the problem: this gate compares exit status, and a
wrong status is still a status. A silent zero is worse than a refusal
precisely because it is plausible.

Three places did it, and the third was the largest. Two were calls, one
with a receiver and one without. The third was the `else` arm of the
switch in `emit`: any node shape this slice does not carry came back as
zero, so an interpolation, an array literal or a proc silently became
`0` and whatever was built on it was wrong rather than refused. All
three now name what they could not do and exit non-zero.

`NopNode` is the one place zero is right, and it is now written down
rather than caught by a fallback. It is an `if` with an empty `else`
and a `while` with an empty body, which three fixtures write.

The gate has a second half for it: `selfhost/codegen/refuses/` holds
programs the slice is *required* to refuse, and `diff.sh` reports
`refused` beside `agree` and `differ`.

    prelude_body.iyi refused: exit 2, abs: this slice has no way to
    emit that call on a i32
    unheld_shape.iyi refused: exit 2, Parser::Parser::InterpNode: this
    slice has no way to emit that

Writing the second of those found a gate that could not fail. It was an
array literal, `xs = [3, 5, 9]` and then `xs.size`, and it stayed green
with the shape refusal removed: the zero the array became was asked a
question, so the *call* refusal caught it either way. The fixture was
measuring the wrong one of the two. What replaced it builds an
interpolation and never reads it, so nothing downstream can catch it,
and removing the shape refusal turns it red. The five mutations that
hold this up are in the session notes: each of the three zeros put
back, each refusal made silent, and `NopNode` treated as a gap, which
has to stay green.

That first line is also the measure of the next slice. When it stops
being a refusal and becomes an `agrees`, the prelude is being compiled.

### What compiling `abs` actually needs

Refusing it made the next slice's shape legible, so here is what was
measured rather than guessed.

The declaration is already there. `collect` registers `struct Int32`
from `number.iyi` as a shape and `collect_shape` puts `abs`, `even?`,
`odd?` and the rest on it, because the prelude is read like any other
require. Nothing needs to be found.

What is missing is one link. A `Val` carries a `kind` and a `shape`,
and `int_val` sets the kind to `i32` and leaves the shape empty, so
`(0 - 9)` arrives at the call with nothing to look a method up by. That
is why the refusal says `on a i32`: `i32` is the kind, printed because
there is no name to print.

Reading the name back out of the kind does not work, and it is worth
saying why rather than finding out later. `kind_of` sends `Int32`,
`UInt32`, `Int` and `UInt` all to `i32`, and `Int64` and `UInt64` both
to `i64`. The mapping is many-to-one and the methods differ across it:
`Int32#abs` is `self < 0 ? -self : self` and `UInt32#abs` is the value
itself. Guessing the name from the kind would compile the wrong body
for half the tower, silently, which is the defect this section is about.

So the slice is: carry the type name on an integer `Val` and keep it
through arithmetic, then emit a method on a primitive type, where
`self` is the value rather than a struct arrived at by pointer.

It is done, and `prelude_body.iyi` moved out of `refuses/` and into
`fixtures/` to say so. The fourteenth fixture agrees with the compiler
at exit 39.

The first half was small and stood on its own: a literal carries
`Int32` or `Int64`, and arithmetic already passed the name along from
the wider operand.

The second half had a wall in front of it, found by trying. A fixture
that reaches `number.iyi` does make `Int32` a known shape, and the very
next thing that happened was `-: this slice has no way to emit that
call on a %Int32`: subtraction, which was an instruction a moment ago.
`Shape` in this emitter meant a struct with a layout, and `%Int32` is
the layout name it invents. The body of `Int32#abs` stored `self` as a
`%Int32`, and `-self` on a value of that kind is not arithmetic.

Four things closed it, and each is held up by a mutation.

`register_kind` is the types whose values live in a register, asked as
a question rather than repeated as a table. `Shape#kind` answers it
before reaching for `%Name`, which is what makes `self` an `i32` inside
a prelude method body. Taking that away turns the fixture red.

Unary minus. `-x` is one operand and the instruction path wants a
receiver and an argument, so it fell through to the refusal. A written
`-1` never arrives there, because the lexer hands the sign to the
literal; this is the negation of something computed, which is a
subtraction from zero at the operand's own width. Removing it turns the
fixture red, and an `add` where the `sub` belongs answers 21 instead of
39, which is the kind of wrong number the refusal above exists to stop
being silent.

Quoted symbols. `even?` and `odd?` are ordinary iyi method names and
`?` is not a character a bare LLVM symbol can hold, so `@iyi_Int32_even?`
does not assemble. Every symbol is quoted now rather than the awkward
ones: `@"iyi_answer"` and `@iyi_answer` name the same thing, and a rule
with no exceptions needs nothing that decides which side of it a name
falls on. Leaving them bare turns the fixture red at the assembler.

The prelude, read without being asked for. An iyi program is compiled
against it without writing a `require`, and a fixture that required its
own copy would be a program the *compiler* refuses, because a file may
not redefine a method the prelude has. So the emitter finds it on
`IYI_PATH`, the same list the compiler searches. Emptying that in
`diff.sh` turns all fourteen red rather than quietly reading as
programs that need no prelude, which is why it is exported once at the
top rather than put in front of each run.

What it costs: the gate went from 16.6 seconds to 22.3 for fourteen
fixtures, because the prelude is parsed for every one of them. Not
expanded. Expanding is still the 2.7x above, and still unpaid for.

One thing that is not load-bearing, said out loud because the mutation
that was supposed to prove it came back green. `Shape#primitive?` keeps
a dead `%Int32 = type { }` out of the module, and LLVM accepts that
declaration perfectly well. It is tidiness. The mutation now aims at
`Shape#kind`, which is the line that actually decides anything.

### A gate that could not say why

The slice above went green locally and red in CI, on a step it had not
touched: the declaration pass, on one sample, `std_iterator.iyi`. The
whole of what CI could tell me was this.

    DIFFERS std_iterator.iyi
      oracle: (class Samples::StdIterator::NaturalNumbers
      port:

The port answered nothing, and nothing is what a crash, a file the port
refused, and a genuinely empty answer all look like. The sentence that
would have separated them existed: the port writes it to stderr. The
harness was throwing it away, along with the exit status, on the line
that ran it.

    "$WORK/declare" "$f" > "$WORK/b.txt" 2>/dev/null

That is the same defect as the silent zero further up, in a different
organ. A measurement that cannot distinguish two causes reports the one
the reader guesses.

It was a class, not a line. Four gates did it: the lexer, the parser,
the declaration pass and inference. All four keep the status and the
message now, and print them when they differ:

    DIFFERS std_iterator.iyi
      the port exited 3 saying: planted: this port was made to fail

Proven on each by planting an `abort` at the top of the port's own main
and checking the line appears, then restoring the file byte for byte.
The `2>/dev/null` on the *oracle* side stays: each gate already has an
explicit "no oracle" path that says what that means.

This does not yet explain `std_iterator.iyi`. It is what makes the next
occurrence explain itself, which is the only honest thing to do with a
failure whose cause was discarded before it was read.

### Bounds that sat on the edge of what they catch

CI went red on darwin, and not on anything above: `bench/parallel_mark.sh`
proves that a pool which never recycles a batch is refused, and the
proof did not fire. The three-core runner mapped exactly 4,194,304
bytes with `free_batch` removed, and the check was `pool > 4194304_u64`,
which is false at 4,194,304. The bound was sitting on the bottom edge of
the population it exists to catch.

Sampled across CI runs on both runners, healthy and with `free_batch`
removed:

    recycling     65,536   262,144   393,216   589,824   1,507,328
    removed    4,194,304 4,521,984 4,587,520 4,653,056 5,111,808

The gap is 1.5 MB to 4.19 MB, so the bound moved to 2.5 MB: 1.74x above
the largest healthy reading and 1.6x below the smallest broken one,
which is its middle measured the way these numbers vary. The high-water
depends on core count, because the wide mark's spills outrun the helpers
for a moment and more helpers drain them sooner, so margin on both sides
is what makes the check travel between machines.

What this machine can prove is that the check is live: lowering the
bound under a healthy reading makes it fire. What it cannot prove is the
three-core reading itself, because with eighteen cores the broken value
is 20 MB, far above either bound. The separation at 4,194,304 is
arithmetic over the sampled data rather than a local reproduction, and
the comment in the file says so.

The complaint names a class, so the others were looked for rather than
waited for. `bench/arena_exercise.iyi` had the same shape: twelve
one-object arenas must not be backed by huge pages, and the bound was
`grew > 2048_u64` where 2,048 KB is exactly one huge page. A single huge
page lands on `>` and does not fire. Sampled healthy across three runs:
324 KB, every time. That bound moved to 1 MB, 3.2x above the reading and
half a huge page.

One more was checked and left alone. `bench/collect_trigger.iyi` refuses
fewer than four arenas for 64 MiB live, and the sampled reading is 21.
That is not an edge.
