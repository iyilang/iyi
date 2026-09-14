# The Stage Two Contract

What stage two actually requires, the dependency order of the components,
the architectural holes that separate today's tree from a self-hosted compiler,
the first end-to-end compilation proof, and the observable that ends the objective.

Every number and claim in this document cites a measured file or command
output from this repository, verified by `python3 bench/doc_numbers.py`,
`bash bench/dependency_floor.sh`, and the selfhost exercise suite.

## 1. What Stage Two Is and the Objective Observable

`BOOTSTRAP.md` defines four bootstrapping stages:

* **Stage 0 (the contract):** No self-hosted compiler is built. The compiler
  is written in Crystal and compiled with Crystal (`bin/crystal`). The ported
  components are checked against the Crystal code they replace.
* **Stage 1 (the first compiler):** Crystal compiles the ported iyi compiler
  sources into an executable compiler binary.
* **Stage 2 (self-compilation):** Stage one compiles the same iyi sources.
  This is the first moment iyi is compiled by an iyi binary.
* **Stage 3 (fixed-point verification):** Stage two compiles the same sources,
  producing a stage three binary that is byte-for-byte identical (`cmp` pass).

### The Standing Objective

The standing objective of self-hosting is eliminating `libgc`. Running
`bash bench/dependency_floor.sh` confirms that user programs built by iyi link
only `libSystem.B.dylib` on macOS (the platform libc). However, `bin/iyi`
itself still links:

```
libc++.1.dylib libgc.1.dylib libLLVM.dylib libSystem.B.dylib
```

The compiler links `libgc` only because it is a Crystal program and Crystal's
runtime requires the Boehm garbage collector (`bdw-gc`). A self-hosted compiler
written in iyi uses iyi's own allocator and runtime (`src/iyi/prelude.iyi`),
which links no collector unless `-Dgc_boehm` asks for one.

The definitive observable that marks the close of this objective:

```
otool -L bin/iyi (on macOS) or readelf -d bin/iyi (on Linux)
```

shows only `libLLVM`, `libc++`, and the platform libc (`libSystem.B.dylib` on
macOS, `libc.so` on Linux), with `libgc` completely absent from the link line.

### The Heap Boundary Problem

`STAGE_ONE.md` recorded the primary architectural blocker as the heap boundary.
Crystal's compiler allocates all AST nodes, symbols, and types on the Boehm GC
heap. The ported iyi front end produces `ast.iyi` nodes on the iyi runtime heap.
Replacing a compiler pass in-process (for example, passing AST nodes from a pure
iyi parser directly into Crystal's semantic analyzer within the same process)
would require both the Boehm collector and the iyi allocator to coexist in one
process, managing intertwined data structures across foreign object headers.

Every component wired so far has respected this boundary by running as an
isolated companion process:

* `iyi mod dump --selfhost`: invokes `.build/iyi-mod` via process execution.
* `iyi tool format --selfhost`: invokes `.build/iyi-format` via process execution.
* `iyi check --parse-only --selfhost`: invokes `.build/iyi-parse` via process execution.
* `iyi-compile`: invokes `.build/iyi-compile` via standalone execution.

Stage Two moves past isolated companion tools to a whole-compiler replacement.
Because hybrid in-process execution is prohibited by the heap boundary, the
cutover must occur at the whole-compiler binary boundary: an executable binary
compiled from `src/compiler/**/*.iyi` that replaces `bin/iyi` entirely.

## 2. Measuring What Is Actually Left

As measured by `python3 bench/doc_numbers.py` and `git ls-files`, the compiler
source tree consists of:

* **110,105 lines of Crystal** across 114 files in `src/compiler/**/*.cr` and `src/compiler/*.cr`
* **37,069 lines of pure iyi** across 49 files in `src/compiler/**/*.iyi` and `src/compiler/*.iyi`

Below is the complete status of all eleven compiler stages, their exact line
counts, what each produces and consumes, and the gate output proving parity:

### Layer 0: Foundation
* **Files:** `src/compiler/foundation/location.iyi` (44 lines), `errors.iyi` (18 lines),
  `enums.iyi` (16 lines), `string_pool.iyi` (44 lines). Total: 122 lines.
* **Crystal equivalent:** `src/compiler/iyi/syntax/location.cr`, `error.cr`.
* **Produces:** `Location` (file, line, column), basic compiler error models, string pool.
* **Consumed by:** Lexer, AST, Parser, Semantic, and Codegen.
* **Completeness:** Complete for all compiler layers.

### Layer 1: Lexer and Token
* **Files:** `src/compiler/syntax/lexer.iyi` (2,752 lines), `src/compiler/syntax/token.iyi` (351 lines).
  Total: 3,103 lines.
* **Crystal equivalent:** `src/compiler/iyi/syntax/lexer.cr` (1,939 lines), `token.cr` (179 lines).
* **Produces:** Token stream with locations, keywords, operators, literals, and delimiters.
* **Consumed by:** `Parser.new(source, filename).parse`.
* **Gate proof:** `bench/selfhost_lexer_exercise.sh` proves 42/42 syntax fixtures match
  Crystal token streams byte-for-byte (21,034 tokens).
* **Completeness:** Complete for language syntax. Does not parse macro delimiter mode.

### Layer 2: AST, Visitors, and Transformers
* **Files:** `src/compiler/syntax/ast.iyi` (2,374 lines), `visitor.iyi` (233 lines),
  `transformer.iyi` (496 lines). Total: 3,103 lines.
* **Crystal equivalent:** `src/compiler/iyi/syntax/ast.cr` (3,800+ lines).
* **Produces:** 104 concrete AST node types with equality, hashing, cloning, doc preservation,
  `to_s`, and out-of-band `NodeMap` storage.
* **Consumed by:** Parser (creation), Normalizer (rewriting), Semantic (typing), Codegen (emission).
* **Gate proof:** `bench/selfhost_ast_exercise.sh` proves all 104 concrete AST node kinds
  construct, clone, compare, format, and traverse cleanly.
* **Completeness:** Complete.

### Layer 3: Parser
* **Files:** `src/compiler/syntax/parser.iyi` (4,126 lines).
* **Crystal equivalent:** `src/compiler/iyi/syntax/parser.cr` (7,600 lines).
* **Produces:** `ASTNode` hierarchy (expressions, declarations, control structures).
* **Consumed by:** Normalizer and Semantic Analysis.
* **Gate proof:** `bench/selfhost_parser_exercise.sh` proves 24/24 syntax fixtures produce
  normalized ASTs identical to the Crystal frontend (1,609 nodes).
* **Wired proof:** `bench/selfhost_parser_wiring_exercise.sh` proves 68/68 files match
  byte-for-byte behind `iyi check --parse-only --selfhost`.
* **Completeness:** Parses all standard declarations and expressions. Does not parse inline macro grammar.

### Layer 4: Normalizer
* **Files:** `src/compiler/semantic/normalizer.iyi` (626 lines).
* **Crystal equivalent:** `src/compiler/iyi/semantic/normalizer.cr` (1,234 lines).
* **Produces:** Desugared AST (`unless` to `if`, `until` to `while`, op-assign to call,
  string interpolation to `String.interpolation`, chained comparisons to `&&`).
* **Consumed by:** Semantic Analysis (`TopLevelVisitor` and `MainVisitor`).
* **Gate proof:** `bench/selfhost_normalizer_exercise.sh` proves 11/11 fixtures normalize
  identically to the front end (577 nodes).
* **Completeness:** Complete for all language desugaring rules.

### Layer 5: Semantic Analysis and Type System
* **Files:**
  * Semantic: `top_level.iyi` (1,610 lines), `main_visitor.iyi` (1,847 lines),
    `recursive_struct_checker.iyi` (104 lines).
  * Types: `types.iyi` (440 lines), `type_system.iyi` (280 lines), `unification.iyi` (427 lines),
    `restrictions.iyi` (310 lines), `filtering.iyi` (285 lines), `rendering.iyi` (381 lines),
    `root: types.iyi` (6 lines).
  * Subtotal: 5,816 lines across 10 files.
* **Crystal equivalent:** `src/compiler/iyi/semantic/*.cr` (18,000+ lines), `types.cr` (3,800+ lines).
* **Produces:** `SemanticProgram` type hierarchy (classes, structs, modules, traits, enums,
  aliases, constants) and `MainVisitor` typed nodes (`node_types : NodeMap(Type)`),
  overload resolution tables, union multiple dispatch resolution, and variable scopes.
* **Consumed by:** `CodeGenVisitor` (`src/compiler/codegen/codegen.iyi`).
* **Gate proofs:**
  * `bench/selfhost_semantic_exercise.sh` proves 9/9 declaration fixtures (39 declarations),
    10/10 typed expression fixtures (312 typed nodes), and 23/23 error fixtures match Crystal identically.
  * `bench/selfhost_types_exercise.sh` proves 7/7 type fixtures (66 types), 6/6 error fixtures,
    and 6 mutation proofs match Crystal identically.
* **Completeness:** Complete for single-unit typed programs. Does not load multi-file imports from disk.

### Layer 6: Macro Engine
* **Files:** `src/compiler/macros/ast.iyi` (256 lines), `engine.iyi` (320 lines),
  `interpreter.iyi` (450 lines), `macro_parser.iyi` (477 lines), `methods.iyi` (380 lines).
  Total: 1,883 lines.
* **Crystal equivalent:** `src/compiler/iyi/macros/*.cr` (4,396 lines).
* **Produces:** Expanded AST nodes from macro definitions and invocations.
* **Gate proof:** `bench/selfhost_macros_exercise.sh` proves 12/12 fixtures expand
  identically to the front end (71 nodes).
* **Completeness:** Standalone expansion is complete. Macro expansion hook is not yet wired
  into `MainVisitor` expression traversal.

### Layer 7: LLVM C-API and Code Generation
* **Files:**
  * Codegen: `src/compiler/codegen/codegen.iyi` (2,572 lines).
  * LLVM: `builder.iyi` (420 lines), `context.iyi` (110 lines), `lib_llvm.iyi` (240 lines),
    `llvm.iyi` (30 lines), `memory_buffer.iyi` (60 lines), `module.iyi` (214 lines),
    `pass_manager.iyi` (80 lines), `target.iyi` (220 lines), `values.iyi` (390 lines),
    `root: llvm.iyi` (13 lines).
  * Subtotal: 4,349 lines across 11 files.
* **Crystal equivalent:** `src/compiler/iyi/codegen/*.cr` (15,000+ lines).
* **Produces:** Native object files (`.o`) containing machine code and LLVM IR modules.
* **Consumed by:** Linker.
* **Gate proof:** `bench/selfhost_codegen_exercise.sh` proves 17/17 fixtures match 100%
  (105 functions) in LLVM IR against Crystal, and emitted object files pass C driver execution 100%.
* **Completeness:** Emits functions, structs, struct methods, classes, constructors, instance
  variables, virtual hierarchy dispatch, pointers, exception landing pads, string literals
  with constant pool reuse, user-defined generic class and struct instantiations, and heap layout
  maps. Does not emit top-level statements outside functions or runtime garbage collection interface.

### Layer 8: Platform Support and Linker
* **Files:** `src/compiler/platform/target.iyi` (260 lines), `flags.iyi` (184 lines),
  `linker.iyi` (254 lines). Total: 698 lines.
* **Crystal equivalent:** `src/compiler/iyi/codegen/target.cr`, `link.cr`.
* **Produces:** Normalized target triples, platform flags, and exact linker command strings.
* **Consumed by:** Driver and build tool for executable generation.
* **Gate proof:** `bench/selfhost_platform_exercise.sh` proves 24/24 target triples match 100%
  across targets, flags, extensions, and link commands.
* **Completeness:** Complete across macOS, Linux, Windows, WASM, and BSD targets.

### Layer 9: Artifact Serializer
* **Files:** `src/compiler/artifact/iyimod.iyi` (2,681 lines).
* **Crystal equivalent:** `src/compiler/iyi/iyimod.cr` (1,348 lines).
* **Produces:** `.iyimod` binary module artifacts across all 20 section types.
* **Consumed by:** Module consumer and `iyi mod dump`.
* **Gate proof:** `bench/selfhost_iyimod_exercise.sh` proves 16/16 modules match byte-for-byte
  (80,398 bytes) against Crystal backend.
* **Wired proof:** `bench/selfhost_mod_wiring_exercise.sh` proves 16/16 modules match behind
  `iyi mod dump --selfhost`.
* **Completeness:** Complete for serialization and inspection.

### Layer 10: Command Driver and Daemon
* **Files:** `src/compiler/command/driver.iyi` (1,970 lines), `daemon.iyi` (620 lines).
  Total: 2,590 lines.
* **Crystal equivalent:** `src/compiler/iyi/command.cr` (1,104 lines), `command/*.cr`.
* **Produces:** CLI option parsing (`CompilerOptions`) and build daemon socket protocol.
* **Gate proofs:** `bench/selfhost_command_exercise.sh` (115/115 vectors match),
  `bench/selfhost_daemon_exercise.sh` (30/30 scenarios match).
* **Completeness:** Option parsing and dispatch match Crystal. `build` action does not yet
  invoke an in-process compiler class.

### Layer 11: Standalone and Companion Tools
* **Files:** `src/compiler/tools/formatter.iyi` (2,436 lines), `format.iyi` (34 lines),
  `mod.iyi` (40 lines), `parse.iyi` (42 lines), `bind.iyi` (1,213 lines),
  `compile.iyi` (245 lines). Total: 4,010 lines across 6 files.
* **Status:** Four companion tools wired into CLI (`mod`, `format`, `parse`, `compile`).

## 3. Can a Whole Compiler Be Assembled from the iyi Ports Alone Today?

Establishing with evidence: **No, a whole compiler cannot be assembled from the iyi ports alone today.**

The investigation identified six specific architectural holes that currently prevent
assembling a self-hosted compiler binary from `src/compiler/**/*.iyi` alone:

### Hole 1: Top-Level Compiler Pipeline Orchestrator
* **Status:** Absent.
* **Evidence:** In Crystal, `src/compiler/iyi/compiler.cr` (3,186 lines) orchestrates the entire
  compilation pipeline: `Compiler#compile` coordinates `new_program`, `parse`, `normalize`,
  `top_level_semantic`, `main_visitor`, `prepare_iyimods`, `codegen`, and `link`.
  In pure iyi, `src/compiler/command/driver.iyi` line 790 parses options into `CompilerOptions`,
  but no `src/compiler/iyi.iyi` or `src/compiler/compiler.iyi` class exists to instantiate the
  pipeline.

### Hole 2: Multi-File Dependency Graph and Module Resolver
* **Status:** Absent.
* **Evidence:** In Crystal, `src/compiler/iyi/loader.cr` and `src/compiler/iyi/iyi_path.cr`
  manage the recursive import graph, resolving `import std/json` to filesystem paths,
  preventing circular loading, and tracking required files.
  In pure iyi, `syntax/parser.iyi`, `semantic/top_level.iyi`, and `codegen/codegen.iyi` only
  accept an in-memory string or a single file path. There is no loader to traverse imports
  across multiple files on disk.

### Hole 3: Prelude Self-Compilation Barrier
* **Status:** Codegen primitives ported for string literals, user-defined generics, and heap layouts; blocked by macro delimiter mode.
* **Evidence:** `src/compiler/codegen/codegen.iyi` now emits string literals with private constant pools
  and Crystal's string struct layout, user-defined generic instantiations with monomorphized constructors
  and methods, and heap layout maps for instance variable offsets across structs and classes, proven by
  `bench/selfhost_codegen_exercise.sh` (17 fixtures, 105 functions, 16 mutation proofs). Attempting to compile
  `src/iyi/prelude.iyi` (7,471 lines) now advances past lexical analysis to line 48:1, where it encounters
  macro delimiter grammar (`{%`), and `src/iyi/array.iyi` (507 lines) compiles through semantic analysis into codegen.
### Hole 4: Macro Expansion Hook in Semantic Traversal
* **Status:** Unwired.
* **Evidence:** While `src/compiler/macros/` expands macros standalone in `selfhost_macros_exercise.sh`,
  `src/compiler/semantic/main_visitor.iyi` contains no call to `MacroEngine#expand`.
  When an AST contains a macro call, `main_visitor.iyi` treats it as an unresolved method call
  rather than expanding it into replacement AST nodes.

### Hole 5: Top-Level Statement Wrapper in Codegen
* **Status:** Absent.
* **Evidence:** `src/compiler/codegen/codegen.iyi` lines 2411 to 2432 iterates over top-level
  AST nodes and only collects `ClassDef`, `FunDef`, `Def`, and `LibDef`. Any top-level
  imperative code (e.g. `puts "hello"` or top-level assignments) is ignored during emission.
  In Crystal, `codegen.cr` synthesizes `__crystal_main` to evaluate top-level statements.
  In iyi, a program must explicitly declare `fun main(argc : Int32, argv : Pointer(Pointer(UInt8))) : Int32`
  to produce an executable entry point.

### Hole 6: The Bootstrap Chicken-and-Egg
* **Status:** Structural bootstrap requirement.
* **Evidence:** The 37,069 lines of iyi compiler source use classes, instance variables,
  hash tables, arrays, strings, and recursion. To build a standalone compiler binary that
  does not link `libgc`, the compiler source must be compiled by an existing compiler.
  Crystal currently builds `bin/iyi`, which links `libgc`. The first compiler binary that does
  not link `libgc` can only be generated once Stage One compiles `src/compiler/iyi.iyi` into
  an executable binary.

## 4. The First Genuinely Possible Step: End-to-End Program Compiler

To bridge the gap between isolated pass verification and whole-compiler assembly, this change
implements Candidate 1: compiling complete programs end-to-end using only the ported compiler
stages through a dedicated helper binary, and proving execution parity against the shipped compiler.

### Implementation: `src/compiler/tools/compile.iyi`

`src/compiler/tools/compile.iyi` (245 lines) glues together five ported stages in pure iyi:
1. `compiler/syntax/parser`: parses source code into an AST.
2. `compiler/semantic/top_level`: declares types, methods, structs, and classes.
3. `compiler/semantic/main_visitor`: types expressions, local variables, and calls.
4. `compiler/codegen/codegen` and `compiler/llvm`: generates LLVM IR and emits a machine object file (`.o`).
5. `compiler/platform/target` and `compiler/platform/linker`: constructs the platform linker command
   and invokes the system linker (`cc`).

The tool is built via the Makefile target:

```makefile
make iyi-compile
```

producing `.build/iyi-compile`.

### Measured Execution Parity and Dependency Floor

The differential gate `bench/selfhost_compile_exercise.sh` executes 7 distinct program fixtures
across both `.build/iyi-compile` and the shipped compiler `.build/iyi build --prelude=empty`:

1. `compile_exit.iyi`: trivial program returning exit code 42 directly from `fun main`.
2. `compile_arith.iyi`: multi-function integer arithmetic, wrapping operators (`&+`, `&-`, `&*`),
   bitwise logic, and shifts.
3. `compile_control.iyi`: conditional branches (`if`/`else`), absolute value calculations, and phi merges.
4. `compile_loop.iyi`: while loops with variable mutation, accumulation (sum 1..10 = 55), and Euclidean gcd.
5. `compile_struct.iyi`: struct definition, constructor initialization, property getters/setters,
   and struct method calculation.
6. `compile_class.iyi`: heap-allocated class, instance variable mutation, and class method dispatch.
7. `compile_pointers.iyi`: pointerof, pointer dereference, and in-place variable mutation via pointer.

Running `bash bench/selfhost_compile_exercise.sh` produces:

```
== 1. Building self-host compile tool
.build/iyi build -o .build/iyi-compile src/compiler/tools/compile.iyi
built .build/iyi-compile
  built .build/iyi-compile successfully

== 2. Whole program execution parity: pure iyi compiler vs shipped compiler
  bench/fixtures/compile_exit.iyi: identical execution exit code (rc=42)
  bench/fixtures/compile_arith.iyi: identical execution exit code (rc=26)
  bench/fixtures/compile_control.iyi: identical execution exit code (rc=42)
  bench/fixtures/compile_loop.iyi: identical execution exit code (rc=49)
  bench/fixtures/compile_struct.iyi: identical execution exit code (rc=42)
  bench/fixtures/compile_class.iyi: identical execution exit code (rc=42)
  bench/fixtures/compile_pointers.iyi: identical execution exit code (rc=42)
  Parity summary: 7/7 compile fixtures match 100% across execution

== 3. Dependency floor verification: pure iyi compiler produces dependency-floor binaries
  Dependency floor summary: 7/7 binaries link only platform libc (no libgc)

== 4. Object emission without linking (--emit-obj)
  --emit-obj successfully wrote object file: /tmp/test_emit.o

== 5. Malformed input and error refusal checks
  properly refused: malformed syntax rejected (rc=1)
  properly refused: missing input file rejected (rc=1)
  Refusal summary: 2/2 malformed scenarios refused properly

== 6. Guarded mutation proofs
  [corrupt linker placeholder substitution]
    caught: mutation caused compilation or execution divergence as expected
  [corrupt object file output path]
    caught: mutation caused compilation or execution divergence as expected
  [corrupt arithmetic operation in test fixture]
    caught: mutation caused compilation or execution divergence as expected

ALL SELFHOST COMPILE CHECKS PASSED!
```

Running `otool -L` on every binary produced by `.build/iyi-compile` confirms:

```
/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
```

Both the pure iyi compiler and the shipped compiler produce binaries that link exclusively
to the platform libc. No `libgc`, no `libc++`, and no `libLLVM` are linked into the generated
binaries.

## 5. The Stage Two Order of Operations

To assemble a complete self-hosted compiler that builds without `libgc`, work must proceed
in the following strict topological order:

```
Step 1: End-to-End Program Compiler (PROVED)
  │     Pure iyi pipeline parses, types, emits, and links whole programs.
  │     Tool: .build/iyi-compile. Gate: bench/selfhost_compile_exercise.sh.
  ▼
Step 2: Semantic Analysis Companion Tool Wiring
  │     Extend `iyi check --selfhost` past parsing into semantic analysis.
  │     Tool: .build/iyi-check. Proves type-checking user code via pure iyi.
  ▼
Step 3: Multi-File Loader and Dependency Graph
  │     Port `loader.cr` and `iyi_path.cr` to pure iyi (`compiler/loader.iyi`).
  │     Resolves `import` statements across directories and prevents cycles.
  ▼
Step 4: Codegen Primitives (Generics, String Literals, Heap Layouts)
  │     Extend `codegen.iyi` to support string constant emission, heap object
  │     allocation headers, and generic class/struct method monomorphization.
  ▼
Step 5: Minimal Compiler Prelude Definition
  │     Define a self-contained runtime subset (`src/compiler/prelude.iyi`)
  │     providing only what the compiler itself requires (strings, arrays, hashes,
  │     files, and memory allocation), avoiding full standard library dependencies.
  ▼
Step 6: Top-Level Compiler Assembly (`src/compiler/iyi.iyi`)
  │     Write the main compiler class in pure iyi, integrating Driver, Loader,
  │     Parser, Normalizer, Semantic, Macros, Codegen, Artifact, and Linker.
  ▼
Step 7: Stage One Cutover and `libgc` Elimination
        Build `src/compiler/iyi.iyi` with `bin/iyi` to produce `.build/iyi-stage1`.
        Verify `otool -L .build/iyi-stage1` contains no `libgc`.
        Replace `bin/iyi` with `.build/iyi-stage1`.
```

## 6. What Stage Two Must Compile to Prove Completion

Stage Two will be demonstrably complete when:

1. **Compiler Builds from Pure iyi Sources:**
   `bin/iyi build -o .build/iyi-stage2 src/compiler/iyi.iyi` exits 0 without errors.
2. **Compiler Binary Dependency Floor:**
   `bash bench/dependency_floor.sh` reports that `.build/iyi-stage2` links only:
   `libLLVM`, `libc++`, and the platform libc (`libSystem.B.dylib` on macOS, `libc.so` on Linux).
   `libgc` is completely absent from the link line.
3. **Self-Compilation Fixed Point:**
   `.build/iyi-stage2 build -o .build/iyi-stage3 src/compiler/iyi.iyi` exits 0.
   `cmp .build/iyi-stage2 .build/iyi-stage3` exits 0 (identical binaries).
4. **Full Test Suite and Gate Execution:**
   All 18 selfhost exercise scripts pass when invoked with `IYI=.build/iyi-stage2`.
5. **Standard Library and Sample Compilation:**
   `.build/iyi-stage2` compiles all 102 modules under `src/std/` and all 34 samples
   under `samples/iyi/`, with every produced binary continuing to link only the platform libc.
