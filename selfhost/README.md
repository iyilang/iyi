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

## Where it is

Measured, not estimated: **all 27** files in `samples/iyi` produce a tree
identical to the current parser's.

```
bash selfhost/parser/diff.sh samples/iyi/*.iyi
  agree 27, differ 0, no oracle 0
```

The lexer slice (`lexer/`) agrees with the current lexer token for token
on 7 of 7 non-interpolated samples.

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
single iyi file there is. What no corpus exercises is what remains:
heredocs, regex literals, `lib` and `fun` bodies, `with ... yield`, and
the macro language itself, which every corpus skips to its `{% end %}`
rather than parsing.

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
mind: 67 files, an order of magnitude more code than the prelude, and the
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
With those, the parser reproduces the tree of its own source: 3,597 lines
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

## The first inference slice

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
