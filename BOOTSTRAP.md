# The bootstrap contract

What it would take for iyi to compile itself, what each stage has to prove
before the next one starts, and what is still linked when it is done.

Every number here is measured from this tree by `python3 bench/doc_numbers.py`
and `bash bench/dependency_floor.sh`, not estimated.

## Where this actually stands

`src/compiler` is **110,105 lines of Crystal and 35,814 lines of iyi**. The
iyi side is the lexer, the token, the AST, the visitor and transformer, the
parser's expressions and declarations, the normalizer, the top-level declaration
and expression and method body typing passes of semantic analysis, the type
system (unification, generics, virtual types, nilable handling, restrictions,
narrowing, and rendering), the artifact format, the bind tool, the command
driver and build daemon, the formatter, the macro engine, platform support
(targets, flags, and linker commands), the four foundation files, the LLVM
bindings, and the first slice of code generation:

| in iyi | lines | proved by |
|---|---|---|
| `syntax/lexer.iyi`, `syntax/token.iyi` | 3,103 | `bench/selfhost_lexer_exercise.sh`: 42 fixtures, 21,034 tokens identical to the Crystal front end |
| `syntax/ast.iyi`, `visitor.iyi`, `transformer.iyi` | 7,202 | `bench/selfhost_ast_exercise.sh`, five guarded mutation proofs |
| `syntax/parser.iyi` (no macros) | 4,072 | `bench/selfhost_parser_exercise.sh`: 24 fixtures, 1,609 normalised nodes identical to the Crystal front end, nine guarded mutation proofs |
| `semantic/normalizer.iyi` | 705 | `bench/selfhost_normalizer_exercise.sh`: 11 fixtures, 577 normalised nodes identical to the Crystal front end, five guarded mutation proofs |
| `semantic/top_level.iyi`, `semantic/main_visitor.iyi`, `semantic/recursive_struct_checker.iyi` | 2,996 | `bench/selfhost_semantic_exercise.sh`: 42 fixtures (9 declaration fixtures, 39 declarations; 10 typed expression fixtures, 312 typed nodes; 23 error fixtures rejected with identical errors), sixteen guarded mutation proofs. Top-level declarations, method bodies, instance variable type inference across a type, class variable initializers, recursive struct check, overload resolution by argument types with specificity ranking and autocast ambiguity detection, multiple dispatch over union receivers, and block and closure type inference |
| `types/*.iyi`, `types.iyi` | 2,123 | `bench/selfhost_types_exercise.sh`: 13 fixtures (7 type declaration fixtures, 66 types identical to the Crystal front end; 6 error fixtures rejected with identical errors), six guarded mutation proofs. Type hierarchy extensions, virtual types and virtual metaclasses, generic class/module/trait instances, tuples, named tuples, procs, pointers, static arrays, union classification and unification, type filtering and is_a? narrowing, type restrictions, and type rendering with full options |
| `tools/bind.iyi` | 727 | `bench/selfhost_bind_exercise.sh`: 11 fixtures, 80 public methods, four guarded mutation proofs. Read the note below before trusting this row |
| `tools/formatter.iyi` | 2,436 | `bench/selfhost_formatter_exercise.sh`: 35 files, 106,026 bytes identical to the shipped formatter, idempotency on each file, eight guarded mutation proofs. Still not in the port: alignment (when/hash/assign/comments), doc comment code block formatting, heredoc fixes, and macros |
| `artifact/iyimod.iyi` | 2,681 | `bench/selfhost_iyimod_exercise.sh`: 16 modules, 80,414 bytes identical to the Crystal front end, cross-reading, refusal, five guarded mutation proofs |
| `tools/mod.iyi` | 59 | `bench/selfhost_mod_wiring_exercise.sh`: 16 modules, 100% byte-for-byte dump and declarations parity, refusal parity on corrupted artifacts, four guarded mutation proofs. Shipped compiler calls it behind `iyi mod dump --selfhost` |
| `tools/format.iyi` | 36 | `bench/selfhost_format_wiring_exercise.sh`: 35 files, 100% byte-for-byte formatting parity across stdin, in-place, and prefix flags, check mode and refusal parity, five guarded mutation proofs. Shipped compiler calls it behind `iyi tool format --selfhost` |
| `command/driver.iyi` | 1,963 | `bench/selfhost_command_exercise.sh`: 115 argument vectors dispatched identically to the Crystal driver, six guarded mutation proofs. Dispatch only: vectors that would compile or run a program are out of scope, and the driver does no compiling |
| `command/daemon.iyi` | 717 | `bench/selfhost_daemon_exercise.sh`: 30 scenarios across socket path selection, kernel limit refusal, candidate search order, identity calculation, and error text identical to the shipped daemon, six guarded mutation proofs |
| `llvm/*.iyi` | 2,285 | `bench/selfhost_llvm_exercise.sh`: a real object file emitted from iyi code, linked against a C driver, run |
| `foundation/*.iyi` | 122 | compiled by the above |
| `macros/*.iyi` | 1,583 | `bench/selfhost_macros_exercise.sh`: 12 fixtures, 71 expanded nodes identical to the Crystal front end, five guarded mutation proofs. Macro expansion interpreter, argument binding (positional, defaults, splats, double splats, named arguments, blocks), control flow ({% if %}, {% for %}), stringification and macro methods on AST nodes. Still not in the port: TypeNode semantic table inspection, external macro run, and semantic hook callbacks |
| `platform/*.iyi` | 698 | `bench/selfhost_platform_exercise.sh`: 24 target triples across darwin, linux (gnu/musl), windows (msvc/gnu), wasm32-wasi, freebsd, and openbsd identical to the Crystal front end, malformed triple rejection, six guarded mutation proofs |
| `codegen/codegen.iyi` | 2,572 | `bench/selfhost_codegen_exercise.sh`: 13 fixtures, 85 functions, 9 struct and class types, 8 type ID globals, and allocator declarations with 100% identical LLVM IR and identical native object execution linked with C driver, twelve guarded mutation proofs. Emits LLVM IR for `fun` declarations with integer and float arithmetic, comparisons, local variable allocation and assignments, `if`/`else` (with phi value merges), `while` loops, and inter-function calls; structs (stack allocation, zero-initialization via memset, field accessors, pass-by-value arguments, methods, initializers, and constructors); pointer operations (pointerof, value, value=, ptr + offset, ptr - ptr, address); classes (heap allocation via malloc, zero-initialization via memset, type_id header initialization and hierarchical type_id global constants, instance variable accessors, single-inheritance field layout, methods, initializers, and constructors); virtual hierarchy dynamic dispatch tables and match functions (`~match<Base+>`); nilable values (nil as null pointer, `nil?` predicate, pointer truthiness checks); inline block expansion with yield, block arguments, outer variable capture, and loop yields; and exception handling (begin/rescue/else/ensure, LLVM landing-pad and personality function bindings, exception type matching via type ID and virtual match functions, re-raising, and caught exception access). Excluded: full proc closures with escaping variable capture (require unported closure capture analysis and lambda lifting in semantic analysis), generics, and GC interface |

The bind row is weaker than the rows above it, and the difference matters.
Every other gate here compares against the code being replaced. The bind gate
does not: its oracle is a second implementation written inside the gate
script, so what it proves is that two implementations of the same description
agree, which a shared misreading would satisfy. The shipped tool also works
from a semantically analysed program while this port works from a parsed
tree, so they are not the same tool on the same input. Treat `tools/bind.iyi`
as unproven against `src/compiler/iyi/tools/bind.cr` until semantic analysis
is ported and the gate can drive the real one.

What is **not** in iyi: semantic analysis beyond the top-level declaration,
expression and method body typing passes, instance and class variable type
inference, recursive struct check, overload resolution, multiple dispatch,
and block and closure type inference (first-class captured proc values and
exception handling typing),
TypeNode inspection in macros, and codegen beyond the fun, struct, class,
virtual dispatch, nilable, block inlining, and exception slices (full proc closures,
generics, and the GC interface). That is the
109,871. The formatter, macro engine and codegen are partly ported, and their
rows above say which parts are not.
Before this change, nothing in the build called any of the ports above: each
was checked against the code it would replace, not used in its place. Two
wiring steps are now active: `iyi mod dump --selfhost` routes artifact inspection
through the pure iyi port (`src/compiler/tools/mod.iyi` and
`src/compiler/artifact/iyimod.iyi`), proved byte-identical across the entire
module corpus by `bench/selfhost_mod_wiring_exercise.sh`; and
`iyi tool format --selfhost` routes source code formatting through the pure iyi
port (`src/compiler/tools/format.iyi` and `src/compiler/tools/formatter.iyi`),
proved byte-identical across all 35 corpus files by
`bench/selfhost_format_wiring_exercise.sh`.

The artifact row proves binary parity: 16 modules across `samples/iyi` and
`src/std` (80,414 bytes) produce byte-identical `.iyimod` files between Crystal
and iyi, each implementation cross-reads what the other wrote with identical
dumps, and damaged or corrupted artifacts are refused by both with identical
verdicts. What this gate does not prove on its own is standalone artifact
emission from un-analyzed user source code: extracting exported signatures,
type definitions, and layout pointer maps requires semantic analysis and the
type checker, which remain in Crystal. Once semantic analysis lands in iyi,
the artifact writer can be plugged directly into the front-end AST walk.

The parser is the one thing in between. Expressions and declarations are
ported, 3,868 lines of iyi against the 7,600 of
`src/compiler/iyi/syntax/parser.cr`, and `bench/selfhost_parser_exercise.sh`
requires every one of twenty-four syntax fixtures to produce a normalised tree
identical to the frontend's, 1,609 nodes in all. Declarations here means `def`
in its argument and return-type forms, `class`, `struct`, `module`, `enum`,
`trait`, `impl` with `forall`, `annotation`, `lib` and `fun`, type and
variable declarations, `alias`, inclusion and visibility.

What is still not parsed is the macro grammar, which is a separate lexer mode
rather than more of the same grammar and belongs with the macro engine. Nothing
in the build calls the iyi parser yet: it is checked against the Crystal one,
not used in place of it. Porting the rest is what closes stage one.

## The stages

Stage zero is the contract, not a build. It is the set of statements a later
stage is measured against, so that "it bootstrapped" is a checkable claim
rather than a feeling.

**Stage 0, the contract.** No compiler is built. What has to be true:

1. Every iyi file under `src/compiler` compiles with the current compiler and
   is exercised by a gate that carries a failure proof. True today for all five
   groups above.
2. A stage-one compiler is built *by Crystal* from iyi sources. Its output is
   the thing under test, never its own source.
3. A stage-two compiler is built *by stage one* from the same sources.
4. Stage two is byte-identical to a stage-three built by stage two. That is the
   fixed point, and it is the only evidence that accepts the compiler as
   self-describing. Stage one and stage two are NOT expected to be identical:
   they were produced by different compilers.
5. The reproduction is measured with `SOURCE_DATE_EPOCH` pinned and the
   artifact paths normalised, because otherwise the comparison proves the
   filesystem rather than the compiler.

**Stage 1.** Crystal compiles iyi sources into a compiler. Blocked on the ten
components listed above being written in iyi. This is the long pole and it is
not close: 109,871 lines of it.

**Stage 2.** Stage one compiles the same sources. The first moment iyi is
written in iyi.

**Stage 3.** Stage two compiles the same sources. `cmp` stage two against
stage three. Equal is the pass.

## What is still linked when this is done

This is the part worth being plain about, because "self-hosted" is often heard
as "dependency free" and it is not the same claim.

A self-hosted iyi compiler still links:

- **libLLVM**, and **libstdc++** with it. `src/compiler/llvm/lib_llvm.iyi:11`
  carries `@[Link("stdc++")]` and the LLVM ldflags. The bindings being written
  in iyi changes who calls LLVM, not whether LLVM is there.
- **the platform libc**, which is the floor for any program on a supported
  target and is Apple's only supported interface on darwin.

What it stops linking is **libgc**: the collector is iyi's own, and a program
iyi builds already links no collector unless `-Dgc_boehm` asks for one. The
compiler links libgc today only because it is a Crystal program and Crystal's
runtime is built on Boehm.

So the honest end state of this work is: **a compiler that needs LLVM and a
libc.** Removing LLVM is a separate decision about a native back end, and
nothing here assumes it.

## What would make this contract false

Each of these is a way the claim could read as satisfied while being wrong, so
each one is a gate or it is not being checked:

- A stage-two build that reuses stage one's artifacts rather than recompiling.
  The reproduction must start from a clean artifact directory.
- Comparing stage one against stage two and calling it a fixed point. It is
  not; they had different producers.
- A byte comparison that passes because both binaries embed the same timestamp
  path rather than the same code.
- `src/compiler/*.iyi` growing a file no gate exercises. The five groups above
  each have one; a sixth needs one in the same commit.
