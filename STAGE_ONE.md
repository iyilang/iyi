# The Stage One Contract

What stage one actually requires, the dependency order of the components,
the blockers for each component today, and the observable proof of stage one.

Every number and claim in this document cites a measured file or command
output from this repository, verified by `python3 bench/doc_numbers.py`
and the selfhost exercise suite.

## 1. What Stage One Is

`BOOTSTRAP.md` defines four bootstrapping stages:

* **Stage 0 (the contract):** No self-hosted compiler is built. The compiler
  is built by Crystal from Crystal sources in `src/compiler/iyi/*.cr`. Ported
  components in `src/compiler/**/*.iyi` are exercised against the Crystal
  frontend via differential gates.
* **Stage 1 (the bootstrap cutover):** A compiler binary built by Crystal from
  pure iyi sources in `src/compiler/**/*.iyi`. This binary is compiled by the
  Crystal-hosted compiler (`bin/iyi`), but its entire source code is written in
  iyi. Its output is the thing under test, never its own source.
* **Stage 2 (first self-compilation):** The stage-one compiler compiles the same
  iyi sources (`src/compiler/**/*.iyi`) to produce stage two. This is the first
  moment iyi is compiled by an iyi binary.
* **Stage 3 (fixed point):** The stage-two compiler compiles the same sources to
  produce stage three. `cmp -s .build/iyi-stage2 .build/iyi-stage3` must be
  byte-identical.

The standing objective of self-hosting is eliminating `libgc`. Running
`bash bench/dependency_floor.sh` confirms that user programs built by iyi link
only `libSystem.B.dylib` on macOS (the platform libc). However, `bin/iyi`
itself still links:

```
libc++.1.dylib libgc.1.dylib libLLVM.dylib libSystem.B.dylib
```

The compiler links `libgc` only because it is a Crystal program and Crystal's
runtime requires Boehm GC. A self-hosted compiler written in iyi uses iyi's own
allocator and runtime (`src/iyi/prelude.iyi`), eliminating `libgc` completely.

## 2. Measuring the Real Gap Today

As measured by `python3 bench/doc_numbers.py`, the compiler source consists of:

* **110,081 lines of Crystal** across 114 files in `src/compiler/iyi/**/*.cr`
  and top-level wrappers (`crystal.cr`, `iyi.cr`, `crystal_front.cr`).
* **34,377 lines of pure iyi** across 45 files in `src/compiler/**/*.iyi`.

### Verification of the `BOOTSTRAP.md` Claim

`BOOTSTRAP.md` stated:

> Nothing in the build calls any of the ports above yet: each is checked against
> the code it would replace, not used in its place.

Verification of `Makefile`:
* `$(O)/iyi$(EXE)` compiles `src/compiler/iyi.cr` via `./bin/crystal build`.
* `$(O)/crystal$(EXE)` compiles `src/compiler/crystal.cr` via `./bin/crystal build`.
* `$(O)/crystal-front$(EXE)` compiles `src/compiler/crystal_front.cr`.
* `src/compiler/requires.cr` requires only `./iyi/*`, `./iyi/semantic/*`,
  `./iyi/macros/*`, and `./iyi/codegen/*` (all `.cr` files).

Prior to this work, no build rule, no compiler pipeline pass, and no CLI command
called any `.iyi` file under `src/compiler/`. Each port was only compiled during
isolated gate runs in `bench/selfhost_*_exercise.sh` where a standalone test
harness imported a single ported module and compared its output against a Crystal
oracle script.

The first wiring steps have now been implemented: `bin/iyi mod dump --selfhost`
wires `src/compiler/artifact/iyimod.iyi` into the shipped compiler CLI,
`bin/iyi tool format --selfhost` wires `src/compiler/tools/formatter.iyi` into
the shipped compiler CLI, and `bin/iyi check --parse-only --selfhost` wires
the ported front end (`src/compiler/syntax/parser.iyi` and `lexer.iyi`) into
the shipped compiler CLI.
## 3. Component Inventory and Blockers

Below is the complete status of all twenty ported and unported compiler
subsystems, their line counts, and what blocks each from being wired into
the compiler pipeline today:

### Layer 0: Foundation
* **`foundation/*.iyi` (122 lines) vs `src/compiler/iyi/` foundation types**
  * Ported: `location.iyi`, `errors.iyi`, `enums.iyi`, `string_pool.iyi`.
  * Status: Tested by `bench/selfhost_lexer_exercise.sh` and downstream gates.
  * Blockers: Foundation types are ready. Blocked only on downstream consumers.

### Layer 1: Lexer and AST
* **`syntax/lexer.iyi`, `syntax/token.iyi` (3,103 lines) vs `src/compiler/iyi/syntax/lexer.cr` (1,939 lines)**
  * Status: 42 fixtures, 21,034 tokens identical to Crystal frontend. Wired
    into shipped compiler CLI behind `iyi check --parse-only --selfhost`.
  * Blockers: In-process runtime boundary for compilation passes (semantic analysis
    and codegen). Full in-process replacement requires wiring together with `Parser.iyi`
    in pure iyi.
* **`syntax/ast.iyi`, `visitor.iyi`, `transformer.iyi` (7,202 lines) vs `src/compiler/iyi/syntax/ast.cr` (4,482 lines)**
  * Status: 104 concrete AST node kinds verified by `bench/selfhost_ast_exercise.sh`.
  * Blockers: Central in-memory data structures. Consumed by semantic analysis
    and codegen. Cannot replace Crystal's AST nodes until semantic analysis and
    codegen are ported.

### Layer 2: Parser and Normalizer
* **`syntax/parser.iyi` (4,152 lines) vs `src/compiler/iyi/syntax/parser.cr` (7,600 lines)**
  * Status: 24 fixtures, 1,609 normalized nodes identical to Crystal frontend. Wired
    into shipped compiler CLI behind `iyi check --parse-only --selfhost`.
  * Blockers:
    1. Macro grammar parsing: `{% if %}`, `{% for %}`, macro expressions are
       handled by `src/compiler/macros/macro_parser.iyi` rather than the main
       grammar.
    2. Downstream in-process consumer: semantic analysis and codegen must be assembled
       in pure iyi to consume `ast.iyi` nodes without serialization overhead.
* **`semantic/normalizer.iyi` (705 lines) vs `src/compiler/iyi/semantic/normalizer.cr` (1,236 lines)**
  * Status: 11 fixtures, 577 normalized nodes identical to Crystal frontend.
  * Blockers: Transforms `ast.iyi` nodes. Blocked on `ast.iyi` and `parser.iyi`.

### Layer 3: Macro Expansion
* **`macros/*.iyi` (1,583 lines) vs `src/compiler/iyi/macros/*.cr` (4,396 lines)**
  * Status: 12 fixtures, 71 expanded nodes verified by `bench/selfhost_macros_exercise.sh`.
  * Blockers:
    1. `TypeNode` semantic inspection: accessing type tables from macros.
    2. External macro execution (`macro run`).
    3. Semantic hook callbacks (`inherited`, `included`, `extended`).

### Layer 4: Type System and Semantic Analysis
* **`types/*.iyi` (2,123 lines) vs `src/compiler/iyi/types.cr` (3,800+ lines)**
  * Status: 13 fixtures, 66 types verified by `bench/selfhost_types_exercise.sh`.
  * Blockers: Type system operates on iyi types. Blocked on semantic analysis.
* **`semantic/top_level.iyi`, `semantic/main_visitor.iyi` (2,129 lines) vs `src/compiler/iyi/semantic/*.cr` (25,000+ lines)**
  * Status: 28 fixtures, 39 declarations, 100 typed nodes, 14 errors.
  * Blockers: The largest gap in the compiler. Unported components in Crystal:
    1. Instance variable type inference beyond local scope (`type_inference.cr`).
    2. Class variable initializers (`class_var_initializer_visitor.cr`).
    3. Recursive struct check (`recursive_struct_checker.cr`).
    4. Overload resolution and multiple dispatch (`call.cr`, `overload_resolution.cr`).
    5. Block and closure type inference.
    6. Exception handling typing (`exception_handler.cr`).

### Layer 5: Platform and LLVM C-API
* **`platform/*.iyi` (698 lines) vs `src/compiler/iyi/codegen/target.cr` and `compiler.cr`**
  * Status: 24 target triples verified by `bench/selfhost_platform_exercise.sh`.
  * Blockers: Consumed by compiler driver and linker invocation.
* **`llvm/*.iyi` (2,285 lines) vs Crystal LLVM bindings**
  * Status: Emits native object file linked with C driver in `bench/selfhost_llvm_exercise.sh`.
  * Blockers: Consumed by codegen.

### Layer 6: Code Generation
* **`codegen/codegen.iyi` (548 lines) vs `src/compiler/iyi/codegen/*.cr` (15,000+ lines)**
  * Status: 5 fixtures, 21 functions with identical LLVM IR and execution.
  * Blockers:
    1. Class layout and heap object allocation.
    2. Virtual and dynamic method dispatch.
    3. Closures and proc pointers.
    4. Exceptions (`raise`, `rescue`, `ensure`, landing pads).
    5. Generics monomorphization.
    6. GC interface and runtime integration.

### Layer 7: Artifact Serializer
* **`artifact/iyimod.iyi` (2,681 lines) vs `src/compiler/iyi/iyimod.cr` (1,348 lines)**
  * Status: 16 modules, 80,414 bytes, 100% byte-for-byte parity, cross-reading,
    refusal verified by `bench/selfhost_iyimod_exercise.sh`.
  * Blockers: NONE for standalone inspection and dumping. Fully wired into
    `bin/iyi mod dump --selfhost` as the first working stage one port.

### Layer 8: Command Driver and Tooling
* **`command/driver.iyi` (1,963 lines) vs `src/compiler/iyi/command.cr` (1,104 lines)**
  * Status: 115 argument vectors verified by `bench/selfhost_command_exercise.sh`.
  * Blockers: Option parsing and dispatch only. Cannot compile programs until
    the full compiler pipeline is wired.
* **`command/daemon.iyi` (717 lines) vs `src/compiler/iyi/command/daemon.cr` (537 lines)**
  * Status: 30 scenarios verified by `bench/selfhost_daemon_exercise.sh`.
  * Blockers: Socket paths and identity only. Does not implement worker fork loop.
* **`tools/formatter.iyi` (2,090 lines) vs `src/compiler/iyi/tools/formatter.cr` (5,457 lines)**
  * Status: 35 files verified in `bench/selfhost_formatter_exercise.sh`.
    Wired into `bin/iyi tool format --selfhost` with 100% byte-for-byte parity across
    all 35 corpus files verified by `bench/selfhost_format_wiring_exercise.sh`.
  * Blockers: Incomplete formatting coverage on complex constructs. Still missing alignment (when,
    hash, assign, comments), doc comment formatting, heredoc fixes, and macros.
    Unblocked for all 35 verified constructs and clean formatting runs.
* **`tools/bind.iyi` (727 lines) vs `src/compiler/iyi/tools/bind.cr`**
  * Status: 11 fixtures in `bench/selfhost_bind_exercise.sh`.
  * Blockers: Works from parsed AST rather than semantically analyzed types.
    Unproven against real frontend until semantic analysis lands.

## 4. The Stage One Wiring Sequence

To achieve Stage One, components must be wired in strict topological dependency
order:

```
[Layer 0: Foundation]
       |
       v
[Layer 1: Lexer + Token + AST + Visitor]
       |
       v
[Layer 2: Parser + Normalizer] <-----+
       |                             |
       v                             |
[Layer 3: Macro Parser + Engine] ----+
       |
       v
[Layer 4: Types + Semantic Analysis (TopLevel, Visitors, Inference, Overloads)]
       |
       v
[Layer 5: Platform Support + LLVM C-API Bindings]
       |
       v
[Layer 6: Code Generation (Fun, Classes, Closures, Exceptions, GC)]
       |
       v
[Layer 7: Artifact Serializer (IyiMod)]
       |
       v
[Layer 8: Command Driver + Main Entrypoint]
```

Wiring across the Crystal/iyi language boundary can only happen where a clean
process or file boundary exists. An in-memory boundary (e.g. passing AST nodes
from pure iyi Lexer/Parser into Crystal's Semantic Analyzer) requires either
full serialization or an FFI bridge that is more complex than completing the
port. Therefore, the compilation pipeline must be assembled entirely within iyi,
while standalone tools (`mod`, `format`, `bind`) can be wired immediately via
CLI companion dispatch.

## 5. The First Wired Component: `iyi mod dump --selfhost`

`artifact/iyimod.iyi` was selected as the first component to wire into the
shipped compiler because:

1. **Complete specification coverage:** All twenty section types in SPEC.md
   Part IV are fully implemented.
2. **Proven 100% binary parity:** All 16 modules in the corpus (80,398 bytes)
   produce byte-identical `.iyimod` files and byte-identical dumps.
3. **Clean boundary:** The tool operates on files on disk and emits formatted
   text or JSON to standard output. There is no in-memory runtime or GC
   impedance mismatch between Crystal and iyi.
4. **Direct user-facing command:** SPEC.md IV.1 specifies `iyi mod dump FILE`
   as the user-facing inspection tool.

### Implementation

1. **Companion tool (`src/compiler/tools/mod.iyi`):**
   Pure iyi tool that imports `compiler/artifact/iyimod` and implements `dump`,
   `declarations`, and `json` commands.
2. **Compiler CLI wiring (`src/compiler/iyi/command/mod.cr`):**
   `Iyi::Command#mod` and `mod_dump` accept `--selfhost` (either before or after
   the subcommand). When present, `run_selfhost_mod_dump` locates `iyi-mod`
   beside the compiler binary, in `.build/iyi-mod`, or via `IYI_MOD_BIN`, and
   delegates execution.
3. **Build system (`Makefile`):**
   Added `.PHONY: iyi-mod` target compiling `$(O)/iyi-mod$(EXE)` using
   `$(O)/iyi build src/compiler/tools/mod.iyi`.
4. **Differential wiring gate (`bench/selfhost_mod_wiring_exercise.sh`):**
   Verifies that:
   * `iyi mod dump "$file"` equals `iyi mod dump --selfhost "$file"`.
   * `iyi mod dump --declarations "$file"` equals `iyi mod dump --declarations --selfhost "$file"`.
   * Prefix flag syntax `iyi mod --selfhost dump "$file"` works identically.
   * Corrupted artifacts are refused by both with identical verdicts.
   * Four guarded mutation proofs verify that defects in the tool, the
     formatter, the CLI routing, and the format validator are caught.

### Measured Parity Summary

Running `bash bench/selfhost_mod_wiring_exercise.sh` confirms:

```
Dump parity summary: 16/16 modules match byte-for-byte
Declarations parity summary: 16/16 modules match byte-for-byte
Prefix flag summary: 16/16 modules match
Refusal parity: 5/5 corrupted artifact scenarios properly refused by both
Mutation proofs: 4/4 guarded mutations caught and reverted
Parity summary: 16/16 modules match byte-for-byte across dump and declarations (100% parity)
ALL SELFHOST MOD WIRING CHECKS PASSED SUCCESSFULLY!
```

## 6. The Second Wired Component: `iyi tool format --selfhost`

`tools/formatter.iyi` was selected as the second component to wire into the
shipped compiler because:

1. **Clean process boundary:** The formatter is a pure text-to-text transform
   taking source code in and emitting formatted code out. Like the artifact
   inspector, it avoids any in-memory object passing or GC runtime conflict
   between Crystal and iyi.
2. **Proven 100% byte-for-byte parity:** All 35 files in the formatter corpus
   (106,026 bytes) produce byte-identical formatted code between the Crystal
   frontend and the pure iyi implementation.
3. **Direct user-facing command:** `iyi tool format [options] [files]` is an
   active user-facing CLI command. Wiring the self-hosted formatter allows users
   and CI to exercise the pure iyi formatter directly on real codebases today.
4. **Preserved default behavior:** Default invocation (`iyi tool format`) is
   completely untouched, while `--selfhost` (or prefix `tool --selfhost format`)
   routes execution to the companion tool.

### Implementation

1. **Companion tool (`src/compiler/tools/format.iyi`):**
   Pure iyi tool that imports `compiler/tools/formatter` and formats source
   from file paths or standard input.
2. **Compiler CLI wiring (`src/compiler/iyi/command/format.cr` and `command.cr`):**
   `Iyi::Command#format` and `FormatCommand` accept `--selfhost` (either before or
   after the `format` subcommand). When present, `run_selfhost_format` locates
   `iyi-format` beside the compiler binary, in `.build/iyi-format`, or via
   `IYI_FORMAT_BIN`, and delegates execution.
3. **Build system (`Makefile`):**
   Added `.PHONY: iyi-format` target compiling `$(O)/iyi-format$(EXE)` using
   `$(O)/iyi build src/compiler/tools/format.iyi`.
4. **Differential wiring gate (`bench/selfhost_format_wiring_exercise.sh`):**
   Verifies that:
   * `iyi tool format - < file` equals `iyi tool format --selfhost - < file`.
   * `iyi tool format file` in-place equals `iyi tool format --selfhost file`.
   * Prefix flag syntax `iyi tool --selfhost format` works identically.
   * Check mode (`--check`) parity on both clean files (exit 0) and unformatted files (exit 1).
   * Syntax error refusal parity on malformed source files (exit 1).
   * Five guarded mutation proofs verify that defects in the companion tool,
     the STDIN handler, the delegation output capture, the prefix flag routing,
     and the check mode status code are caught.

### Measured Parity Summary

Running `bash bench/selfhost_format_wiring_exercise.sh` confirms:

```
STDIN parity summary: 35/35 files match byte-for-byte
In-place parity summary: 35/35 files match byte-for-byte
Prefix flag summary: 35/35 files match
clean check parity: 35/35 files pass on both paths
unformatted check refusal: both paths detect changes (rc=1)
syntax error properly refused by both (rc=1)
Mutation proofs: 5/5 guarded mutations caught and reverted
Parity summary: 35/35 files match byte-for-byte across stdin, in-place, and prefix flags (100% parity)
ALL SELFHOST FORMAT WIRING CHECKS PASSED SUCCESSFULLY!
```

## 7. The Third Wired Component: `iyi check --parse-only --selfhost`

`syntax/parser.iyi` and `syntax/lexer.iyi` were selected as the third component to wire into the
shipped compiler because:

1. **Clean process boundary:** Front-end syntax checking is a file-in or text-in, verdict-out
   transform that validates syntax without mutating disk state or executing codegen. It avoids
   any in-memory runtime or Boehm GC conflict between Crystal and pure iyi.
2. **Proven 100% parity on real corpus:** All 68 files in the test corpus (the 24 parser syntax
   fixtures and the 44 sample programs in the samples tree) produce identical verdicts and
   clean exits (exit code 0, empty output) across files, STDIN, and flag ordering.
3. **Identical error text on malformed input:** Syntax errors on malformed input exit with
   status 1 and output byte-identical error messages between the Crystal and self-hosted paths.
4. **Direct user-facing command:** `iyi check --parse-only [--selfhost] [files...]` extends the
   shipped `check` command so users and CI can exercise the pure iyi front end on real codebases.
5. **Preserved default behavior:** Default invocation (`iyi check`) and standard syntax checking
   (`iyi check --parse-only`) are completely untouched, while `--selfhost` routes execution to
   the companion tool `iyi-parse`.

### Implementation

1. **Companion tool (`src/compiler/tools/parse.iyi`):**
   Pure iyi tool that imports `compiler/syntax/parser` and parses source files or standard input.
2. **Compiler CLI wiring (`src/compiler/iyi/command/check.cr`):**
   `Iyi::Command#check` accepts `--parse-only` and `--selfhost`. When `--selfhost` is combined
   with `--parse-only`, `run_selfhost_parse` locates `iyi-parse` beside the compiler binary,
   in `.build/iyi-parse`, or via `IYI_PARSE_BIN`, and delegates execution.
3. **Build system (`Makefile`):**
   Added `.PHONY: iyi-parse` target compiling `$(O)/iyi-parse$(EXE)` using
   `$(O)/iyi build -o $@ src/compiler/tools/parse.iyi`.
4. **Differential wiring gate (`bench/selfhost_parser_wiring_exercise.sh`):**
   Verifies that:
   * `iyi check --parse-only file` equals `iyi check --parse-only --selfhost file` across all 68 files.
   * `iyi check --parse-only - < file` equals `iyi check --parse-only --selfhost - < file`.
   * Flag ordering `iyi check --selfhost --parse-only` works identically.
   * Syntax error refusal parity on malformed source files with identical exit code (rc=1) and error text.
   * Five guarded mutation proofs verify that defects in the companion tool, STDIN parsing,
     tool discovery, flag routing, and status code propagation are caught.

### Measured Parity Summary

Running `bash bench/selfhost_parser_wiring_exercise.sh` confirms:

```
Parity summary: 68/68 files match byte-for-byte across files, stdin, and flag ordering (100% parity)
Refusal summary: 5/5 malformed scenarios refused with identical error text and status (rc=1)
Mutation summary: 5/5 guarded wiring mutations caught and reverted
ALL SELFHOST PARSER WIRING CHECKS PASSED SUCCESSFULLY!
```

## 8. Observable Proof of Stage One

Stage One will be demonstrably complete when:

1. **Self-hosted entrypoint exists:**
   `src/compiler/iyi.iyi` imports all layers (0 through 8) and implements the
   full compiler pipeline in pure iyi.
2. **Crystal builds Stage One:**
   Running `bin/iyi build -o .build/iyi-stage1 src/compiler/iyi.iyi` exits 0
   and produces an executable compiler binary.
3. **Executable validation:**
   `.build/iyi-stage1 --version` executes, prints the compiler version, and
   does not segfault or panic.
4. **Compilation proof:**
   `.build/iyi-stage1 build -o .build/calc-stage1 samples/iyi/calc.iyi`
   successfully compiles a non-trivial program containing lexing, parsing,
   custom structs, methods, traits, and standard library imports.
5. **Runtime verification:**
   The compiled binary `.build/calc-stage1` runs, passes its tests, and matches
   the behavior of the binary compiled by `bin/iyi`.
6. **Selfhost gate pass:**
   All seventeen selfhost exercise scripts pass when invoked with `IYI=.build/iyi-stage1`.
7. **Dependency floor holds:**
   `bash bench/dependency_floor.sh` confirms that binaries produced by Stage One
   continue to link only the platform libc (`libSystem.B.dylib` on darwin).
