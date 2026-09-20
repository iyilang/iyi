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

Measured, not estimated: 15 of the 27 files in `samples/iyi` produce a
tree identical to the current parser's, and the mean file agrees for the
first 76% of its tree.

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

## The next slices, in the order the corpus asks for them

Run `where.sh` for the current list. As of this writing:

| what | files |
| --- | --- |
| `recover` and `!` propagation | socket, errors, workers |
| heredocs and multi-line strings | calc, config |
| non-ASCII string bodies | std_text |
| `yield` and the block a def declares | generics, std_iterator |
| the remaining call shapes | io, webapp, grid, sessions |

After the parser: the semantic pass, then codegen, then the bootstrap,
each differentially tested the same way. The bootstrap is the acceptance
test and it is available from the first day the port parses anything: the
Crystal-written compiler and the iyi-written one compile the same corpus
and must agree.
