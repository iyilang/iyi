# iyi Stale Test Design

Status: Approved for implementation by Jason Waldrip; implementation in progress on this branch. Grounded at iyilang/iyi `9045a508` (master, 2026-10-24); every `path:line` is at that commit.

## 1. Review

`iyi test --cached` reports a test as passing without generating code for it or running it, when the code the compiler would emit is the code a passing receipt was built from and everything its run was observed reading still gives the same answer. Every check parses and type-checks the test. The compiler then hashes the typed call path: every function, initializer and type layout codegen reaches from the program's entry, after macros have expanded, with program-wide numbering left out. An observation build watches the run. Master CI publishes receipts that other runs import.

### Requirements set by Jason Waldrip before planning

* A test identity for reuse is a SHA signature over the contents of everything it transitively depends on. A portable index records what has actually passed.
* The compiler and runtime discover dependencies automatically. Nobody declares file or environment lists.
* Inputs include the environment (12-factor), effective compiler flags and defaults, toolchain and target, and process behavior.
* Local and CI runs use the same validity rules.
* Crystal mode keeps working.
* Nothing is implemented before this plan is approved.

### Requirements set by Jason Waldrip in review

* The source-side identity is the SHA of a distinct call path: the function bodies and code actually used, not files.
* It is derived from what the compiler already instantiates and emits, not from a separate dependency analysis.
* The call-path signature is the only source-side key. Every check type-checks first.

### Decisions this plan makes

* **D1:** The unit of reuse is one `*_test.iyi` program: one build, one process (§2, §3).
* **D2:** A receipt is valid when its build key equals the current one and every recorded run observation answers the same now. The source side of the build key is the call-path signature. Never file contents, `.iyimod` module hashes, interface hashes or run-time coverage (§3, §4, §6).
* **D3:** The compiler computes the build key itself, after semantic analysis and before codegen. Every `--cached` check type-checks; a hit stops there, before codegen, LLVM, linking and running. Compiler file reads are not recorded, replayed or keyed, and stale builds do not use `UpToDate` (§4).
* **D4:** The run side is an observation build with compiler-injected observers and a static closure check over the reached set of §4. Anything outside the closure is opaque (§5).
* **D5:** Clock, entropy, timers, network, subprocesses, signal handlers, runtime timing values and writes outside the run scratch directory make a run not reusable. The test still runs and reports (§5).
* **D6:** Values the runtime makes up for uniqueness or layout, and the numbering the compiler assigns, are unspecified, not inputs. Accessors that hand machine or timing values to programs are annotated not reusable (§3, §5).
* **D7:** Only passes become receipts. A non-pass under a state that validates a receipt revokes it in the local store; cross-machine revocation occurs through the master audit (§6, §8).
* **D8:** Local state lives in `<cache root>/tests-v1/`, written atomically. Digests that can carry environment values are stored keyed (§6, §7).
* **D9:** There are two namespaces. `master` holds receipts from iyilang/iyi master pushes, fetched through the Actions API. `run:<id>` holds receipts within a single workflow run. Pull requests never write a namespace another ref reads (§8).
* **D10:** No secret or token reaches the export step environment; portable records hold plain digests of environment values. A gate checks this (§8).
* **D11:** Every CI run produces receipts, then a fresh runner hits and re-executes them. Hits across runs and commits wait on RG1 (§8, §10).
* **D12:** `--cached` is opt-in. Default `iyi test` behavior and output do not change. Changing the default is a separate proposal backed by §13 (§9).
* **D13:** `--affected` keeps its selection; reuse applies inside it (§9).
* **D14:** Crystal mode (reached via `IYI_OPTS`) always runs and states why. The Crystal spec aggregate is the unit if it is ever covered (§9).
* **D15:** A claim that rests on an unproven property is blocked by a named proof gate. There is no declaration mode as a fallback (§10).
* **D16:** The reached set is what codegen would emit: a walk starts where `CodeGenVisitor` starts, follows what it follows and skips what it skips. A recording build also generates code and refuses its receipt if codegen emitted a function the walk did not reach. RG8 proves coverage (§4, §10).
* **D17:** Program-wide numbering is never hashed. Elements are named canonically, sets are sorted by name, compiler-made names are numbered by first occurrence inside their element, and literals are hashed by value. A key shared by two elements with different content abstains (§4, §6).
* **D18:** Source positions enter the signature through three sources: literals from location macros, expanded call-site location arguments codegen emits for magic-constant defaults (`src/compiler/iyi/codegen/call.cr:173-191`), and failable cast locations (`src/compiler/iyi/codegen/codegen.cr:1954-1980`). Debug line information is left out; a runtime def that returns code locations or debug information to program code is `code_location`, not reusable (§4, §5).
* **D19:** What reaches the executable from outside the typed program is keyed beside the signature: object units linked from `.iyimod` artifacts by content, the linker flags the compiler would pass with `CHILD_ENV`, and the compiler's own environment reads (§4).

### Approval gate

Implementation starts only after Jason Waldrip approves this pull request. Approval covers D1 through D19 and the phase order in §11. A decision that changes during implementation changes this file in the same PR as the code. No phase is ticketed until this document merges.

## 2. What exists at 9045a508

* **`iyi test`:** One build and one process per file (`src/compiler/iyi/command/test.cr:176`, `317-375`). The header rejects interface hashes for re-running (`test.cr:18-30`). Options are `--json`, `--timeout` and `--affected`; unknown flags are refused (`test.cr:46-85`). Files are discovered and deduplicated by `Iyi.file_key` (`test.cr:87-118`). `--affected` parses the import closure and falls back to a full run when a manifest changed (`test.cr:129-131`), when a changed file cannot be in any closure, meaning it has an extension other than `.iyi` or is a prelude file (`test.cr:138-140`, `243-257`), or when a named file is missing (`test.cr:153`). A test whose own source does not parse is selected on its own (`test.cr:158`, `261-262`), and an import that does not parse stays in the closure by path (`test.cr:263-266`). Syntax changes in existing imported files do not cause a full run. JSON output (`test.cr:179-217`). Stdin is `/dev/null` via `Redirect::Close` opening `File::NULL` (`test.cr:336`; `src/process.cr:550-551`, `607-612`). No result is persisted.
* Named cases and the exit-status verdict: `src/iyi/testing.iyi:151-205`. `assert` and `raise` default `file = __FILE__` (`src/iyi/prelude.iyi:9545`, `9619`).
* The Crystal spec runner builds one generated program requiring every selected spec, then runs it once (`src/compiler/iyi/command/spec.cr:55-115`, `98-115`).
* **Compiler pipeline:** Semantic passes run, then codegen, in both compile paths (`src/compiler/iyi/semantic.cr:6-15`, `39-77`; `src/compiler/iyi/compiler.cr:437-449`, `623-632`). A def is typed when a call instantiates it and is cached per owner by `DefInstanceKey`, whose first field is the def's object id (`src/compiler/iyi/semantic/call.cr:573-630`; `src/compiler/iyi/types.cr:1028-1047`). Definition-site probes type every fully declared user def under `if false` (`src/compiler/iyi/semantic/definition_typing.cr:1-29`). Codegen emits on demand from the main node, one function per mangled name per module (`src/compiler/iyi/codegen/codegen.cr:153-162`; `src/compiler/iyi/codegen/fun.cr:20-84`). `tool unreachable` walks `target_defs` and skips probes, but does not follow constants or class variables (`src/compiler/iyi/tools/unreachable.cr:163-247`).
* **Numbering:** Type ids, the symbol table and proc literal names are assigned at codegen (`codegen/llvm_id.cr:4-37`; `codegen.cr:339-352`, `1071-1098`). Union members are ordered by object id (`src/compiler/iyi/program.cr:1601-1604`). Temporary names and constant slices are program-wide counters (`program.cr:1190-1204`). Programs see type ids through the primitive (`src/iyi/primitives.iyi:39-44`) and the default `hash` (`src/iyi/primitives.iyi:67-74`; `src/iyi/object.iyi:20-22`).
* **`.iyimod` artifacts:** A consumer never opens the module's source (`src/compiler/iyi/iyimod.cr:4-9`). A def read from an artifact has a `Nop` body (`semantic/call.cr:636-695`). Its code comes as object units (`iyimod.cr:91`, `1061-1063`) held in `program.iyi_artifact_objects` and linked whole (`program.cr:414-424`; `compiler.cr:3870-3880`). Module hashes are MD5 cache keys at module granularity (`iyimod.cr:401-406`, `487-500`, `533-538`). `iyi test` reads an artifact only for a module whose source is absent (`src/compiler/iyi/command.cr:1253-1275`) or under `--use-iyimod` (`compiler.cr:169-178`).
* **Build recorder:** `BuildInputs` watches `File`, `Dir` and `ENV` while a build holds it (`src/compiler/iyi/build_inputs.cr:4-23`, `519-591`). The `ENV` hooks cover only `fetch` and `has_key?` (`build_inputs.cr:579-591`). `CHILD_ENV` names what the linker, its driver and `pkg-config` read (`build_inputs.cr:41-47`). `paused` runs a block unrecorded (`build_inputs.cr:61-63`). `UpToDate` keys one record per output path (`up_to_date.cr:40`), with compiler identity from version, path, size and mtime (`up_to_date.cr:47-55`), arguments minus `DISPLAY_ONLY` (`up_to_date.cr:26`, `37`), and environment values in clear (`up_to_date.cr:156-159`). Link flags come from `Program#lib_flags`, which asks `pkg-config` (`src/compiler/iyi/codegen/link.cr:123-181`, `325-343`).
* **Effective options:** `IYI_OPTS` is parsed before explicit arguments (`src/compiler/iyi/command.cr:1553`, `1565`). The prelude key classifies compiler properties with a compile-time completeness check (`src/compiler/iyi/compiler.cr:523-560`); the behavior key copies that model.
* **Environment access:** On POSIX, `Program.env` scans `__iyi_environ` (`src/iyi/prelude.iyi:9844`, `9990`), and `std/env` reads, writes and enumerates the same table (`src/std/env.iyi:61`, `121`, `206`, `283`). On Windows, `Program.env` reads the process block via `__iyi_win_env_get` (`src/iyi/prelude.iyi:9993-9997`), and `std/env` Windows branches do the same (`src/std/env.iyi:59`). Child processes inherit the environment table (`src/std/process.iyi:799`, `1696`).
* **Time, randomness and temp names:** `src/std/time.iyi:1252-1349`, `src/std/random.iyi:440-475`, temp names from getrandom, arc4random or clock (`src/std/file.iyi:1963-1985`), `TMPDIR` read by `Dir.tempdir` (`src/std/dir.iyi:425-431`) and `File.tempfile` (`src/std/file.iyi:1921-1931`), GC pause clock and accessor (`src/iyi/prelude.iyi:4781`, `7529`).
* SHA-256 exists in iyi (`src/std/digest.iyi:429`). The host side has only `src/crystal/digest/md5.cr` and `sha1.cr`.
* The cache cleaner keeps ten most recently used directories (`src/compiler/iyi/codegen/cache_dir.cr:109-117`, `212-233`). The MCP `test` tool is at `src/compiler/iyi/command/mcp.cr:179`, `221`.
* **Corpus and CI:** No committed `*_test.iyi`. The test verb is exercised by generated fixtures: `bench/test_verb.sh` and `bench/agent_loop.py:72-76`, `674-695`, at `.github/workflows/iyi.yml:604`, `644`, `1519`, `1531`, `2106`, `2134`. The std exercises run as four weighted shards per platform (`.github/workflows/iyi.yml:934-985`, `1663`, `2450`). `on: [push, pull_request]` (`iyi.yml:41`), `permissions: {}` (`iyi.yml:65`). The only `secrets.` references are in the VS Code job (`iyi.yml:3174-3175`). `github.token` is exported in step environments (`iyi.yml:2708`, `2795`, `3139`), and PR jobs use `actions/cache` (`iyi.yml:1362`, `1647`, `2700`, `2787`, `2880`). Linux executables dynamically link libc (`SPEC.md:6425-6432`).

## 3. The claim and what it assumes

**Claim:** Under `--cached`, a test reported as passing from a receipt would, if rebuilt and rerun now, read the same bytes, names and values at every point it reads anything, and so reach the same verdict.

* **A1 (Determinism):** Given an equal build key, the compiler emits the same reached code, and given identical answers to observed reads, the program reaches the same verdict. Guards: RG1, RG2, RG7, RG8 and RG9 for the compiler; contradiction detection and the shadow audit for tests.
* **A2 (Unspecified values):** Memory addresses, temp names, scheduling order, descriptor numbers, uninitialized memory, and the numbering the compiler assigns (type ids, symbol indices) are not inputs. A verdict depending on them is a flaky test. Reuse can hide a flake that a rerun might expose, identical to the exposure of a plain rerun. Numbering is stable across reruns of one build and can move with an unrelated edit, so a verdict depending on it is exposed by a `--fresh` run or the audit, not by reuse. Process limits not captured in the profile are unspecified values. Guards: a contradiction revokes in the local store, and any shadow-audit disagreement fails CI.
* **A3 (Inputs hold still during a run):** Guard: compare the stat taken when the test opened a file with a stat after exit. A file whose mtime falls within the recorder resolution of the open (SPEC.md V.9 (e)) taints the run.
* **A4 (Cooperative tests):** Accidental bypass is detected and marks the run not reusable: program `asm`, `lib` bindings, integer-to-pointer conversions, or a closed trace channel. Only trusted refs produce cross-run receipts.

## 4. The build: the call-path signature

The compiler computes the build key once `semantic_after_top_level` returns, in both compile paths (`src/compiler/iyi/compiler.cr:437-444`, `623-627`), before `prepare_iyimods` (`compiler.cr:446`, `629`). The program is typed and cleaned (`src/compiler/iyi/semantic.cr:59-74`) and nothing is numbered yet (`src/compiler/iyi/codegen/codegen.cr:164-166`, `339-352`, `1071-1098`). Hashing after codegen would put IR construction on every hit and would have to undo numbering rather than skip it; codegen output is RG8's oracle instead. Every check type-checks, so a macro `read_file`, `env`, `run` and `system` reach the signature through their expansion, and no compile-time read is replayed.

**Reach.** A walk visits the cleaned typed program the way `CodeGenVisitor` does:
* Roots: well-known funs, predefined constants and artifact class variables (`codegen.cr:373-383`, `679-713`), the main node (`codegen.cr:157`), every `fun` in it (`codegen.cr:735-737`, `823-847`), the bodies and hook expansions of every type and def declared in it (`codegen.cr:1181-1203`, `2074-2081`), and when artifacts are linked, the finish-time program-wide definitions and artifact-read constants (`codegen.cr:739-745`; `codegen/const.cr:303-325`).
* Edges: a call's `target_defs`, through a dispatch when there are several and inline where a block is inlined (`src/compiler/iyi/codegen/call.cr:4-39`); proc literal bodies; a used constant where assigned and any constant where read (`codegen.cr:1484-1488`; `codegen/const.cr:229-256`); a class variable initializer where declared and where read (`codegen.cr:1498-1502`, `1688-1705`; `codegen/class_var.cr:210-244`); instance variable initializers of a type and its superclasses where it is allocated (`codegen.cr:2640-2720`).
* Branches: only those `truthy?` and `falsey?` leave to codegen (`codegen.cr:1297-1314`), so definition-site probes (`src/compiler/iyi/semantic/definition_typing.cr:21-29`) are never reached and `def_instances` (`src/compiler/iyi/types.cr:1028-1047`) cannot stand in for the reached set.
* Failable casts and closure-to-C attempts call `__iyi_raise_cast_failed` and `__iyi_raise_closure_to_c` in `src/iyi/prelude.iyi`, planned for S3 (`src/compiler/iyi/program.cr:495-497`; `src/compiler/iyi/codegen/codegen.cr:1856-1866`, `1945-1952`, `1954-1980`), avoiding codegen-time typing and normalization. Both prelude functions print their fallback messages byte for byte (`codegen.cr:1877-1897`, `1945-1952`), preserving default output per D12. The walk encodes each failable cast's expanded location.
* A macro refuses to compile the compiler while a `CodeGenVisitor#visit` overload, an `ASTNode` subclass, or a `Type` subclass (with layout attributes codegen reads: enum base type, tuple and named-tuple fields, static array sizes, typedef targets) lacks a counterpart in the walk or encoder (`compiler.cr:544-556`). The completeness macro also flags any codegen read of `location`/`end_location` outside allowed debug-metadata sites (`src/compiler/iyi/codegen/debug.cr:407`, `527`, `562`; `codegen/fun.cr:196`, `934`; `codegen/codegen.cr:1072`, `2467-2469`), and flags any `visit_main`/`normalize` calls inside codegen. Where codegen stops after a `NoReturn` (`codegen/call.cr:23-25`) the walk does not; that costs reruns, never a hit.

**Elements.** The walk yields elements, each a kind, a key and a digest of its typed content (§6):
* `def`, one per function codegen would emit, keyed by its canonical name with union members sorted by canonical name recursively (`src/compiler/iyi/codegen/ast.cr:46-48`; mangled names map codegen functions for the cross-check): owner and self type, arguments with types and defaults, block argument, return type, free variable bindings, variables with types and closure flags, `raises?`, every annotation, origin flags, body, and for each call leaving magic-constant defaults to codegen, the expanded values codegen emits (`src/compiler/iyi/codegen/call.cr:173-191`).
* `fun` and `lib_fun` by symbol, a `lib_fun` with its C signature and its `lib` annotations; `const` by path, with value, `simple?`, `compile_time_value` and whether it is initialized where assigned; `class_var` as `Owner::@@name`, with initializer, `simple_initializer?` and thread-local flag; `ivar_init` by type; `main`; `object_unit` (below).
* `type` by canonical name (sorting union members by canonical name recursively, `codegen/types.cr:107-108`, `types.cr:3619-3632`): kind, every annotation, superclass and included modules, instance variables in layout order, enum members and generic arguments; the type set is closed over these references. Planned for S3, member order is made canonical where unions are created (`src/compiler/iyi/program.cr:1601-1604`), sorting members by canonical name rather than object id. This canonicalizes keys, macro literals (`macros/methods.cr:499-500`, `types.cr:3619-3632`), and runtime names together. A virtual type lists every concrete subtype, since codegen range checks and dispatch cover the whole hierarchy (`src/compiler/iyi/codegen/llvm_id.cr:4-27`, `116-135`). Probe witness types (`definition_typing.cr:31-38`) are keyed by the trait they witness.

**Numbering (D17).** No element encodes an object id, type id, symbol index, proc counter, temporary name or slice name (`src/compiler/iyi/program.cr:1190-1192`, `1202-1204`). Keys are canonical names (line 87); mangled names only map codegen functions for the cross-check. Compiler-made variable names and probe serials are numbered by first occurrence inside their element. Two elements with one key and different digests abstain with `ambiguous key`. Numbering that reaches program values (`src/iyi/primitives.iyi:39-44`, `67-74`) is unspecified under A2.

**Positions (D18).** Source positions enter the signature through three sources: literals from location macros, the expanded call-site arguments codegen emits when a call leaves magic-constant defaults to its target def (`src/compiler/iyi/codegen/call.cr:173-191`), and each failable cast's expanded location (`src/compiler/iyi/codegen/codegen.cr:1954-1980`). Nothing else about where code was written is hashed. Backtraces reach only the error stream (`prelude.iyi:9547-9588`), and `std/debug` resolves frames without exporting anything (`src/std/debug.iyi:1-16`).

**Artifacts.** A def read from a `.iyimod` has a `Nop` body (`src/compiler/iyi/semantic/call.cr:636-695`); its code is one of the object units the build links whole (`program.cr:414-424`; `compiler.cr:3802-3803`, `3870-3880`). Each linked unit is an `object_unit` element keyed by module and unit and digested by its bytes. Travelling bodies are typed by the consumer and reached like source. Module hashes (`src/compiler/iyi/iyimod.cr:401-406`, `487-500`, `533-538`) are not used.

**Link and environment.** `LinkFp` covers the flags `Program#lib_flags` returns, `pkg-config` answers included (`src/compiler/iyi/codegen/link.cr:123-181`, `325-343`), `link_flags` (`compiler.cr:3517-3526`, `3709-3765`), the static flag and the `CHILD_ENV` values (`src/compiler/iyi/build_inputs.cr:41-47`). Stale builds always link through the compiler's linker driver (`@iyi_link_driver_only = true`), avoiding direct-`ld` templates (`compiler.cr:3563-3583`). Stale reuse links without a shell (passing an argument vector directly to the linker driver rather than invoking `sh -c`, `src/compiler/iyi/compiler.cr:3533`, `4115`), preventing glob, tilde, and subcommand expansion. Stale reuse is refused when any ldflags or link flag contains a backtick, `$`, `*`, `?`, `[` or `~` (`compiler.cr:3775-3799`). The compiler evaluates `lib_flags` and `link_flags` once during the check and passes that exact vector to the linker. `CompilerEnvFp` covers the compiler's own environment reads during the check, recorded by the `ENV` hooks (`build_inputs.cr:579-591`). Reads inside macro methods run under `BuildInputs.paused` (`build_inputs.cr:61-63`), because their values reach the signature as expanded code. Reads are classified `value`, `locator` (left out: what it located is in the signature) or `display` (left out); unlisted variables are `value`. Stale builds take no file or directory stamps and neither read nor write `UpToDate` records.

**Cross-check (D16).** A recording build continues to codegen and checks that every def, proc literal, constant and class variable that `codegen_fun` (`fun.cr:265`) and the initializer functions receive was reached. One that was not refuses the receipt with `reach mismatch`.

**No build-side race.** The signature and codegen read one parsed tree, and `lib_flags` is evaluated once, so edits or environment changes after check start cannot reach the executable; the receipt is keyed by what was compiled.

Toolchain identity embeds a build-input digest covering compiler sources, LLVM version, bootstrap compiler version and build flags, plus compiler executable SHA-256 until RG1 is green, LLVM shared library digest, and linker driver path, version and digest.
The behavior key classifies compiler properties after defaults apply (`IN_BEHAVIOR_KEY`, `LOCATION_ONLY` or `DISPLAY_ONLY`), using the check model in `src/compiler/iyi/compiler.cr:523-560`. Stale builds refuse `--no-cleanup`, `--emit`, `--emit-iyimod`, `--emit-bind`, `--iyi-keep`, `--cross-compile` and `IYI_FORK_PROBE` with a not-reusable reason. `--stale-key`, `--stale-accept`, `--stale-block` and `--stale-dump-elements` (which carries RG8's element spans) are all `DISPLAY_ONLY`, keeping per-run file paths out of the behavior key. Stale builds never go through a build daemon: the runner unsets `IYI_DAEMON_SOCKET` for its build children (`src/compiler/iyi/command.cr:137-141`).

### Gap table

| Gap | Change | Slice |
|---|---|---|
| G1: nothing records what codegen will emit | Reach walk mirroring `CodeGenVisitor` | S3 |
| G2: typed defs include probes never emitted (`definition_typing.cr:256-261`) | Walk keeps only branches codegen keeps | S3 |
| G3: identities are addresses or counters (`types.cr:1028-1032`, `program.cr:1601-1604`) | Canonical keys, sorted sets, first-occurrence ordinals; duplicate key abstains | S1/S3 |
| G4: a def read from a `.iyimod` has no body | Linked object units keyed by content | S3 |
| G5: link inputs live outside the typed program | `LinkFp` | S3 |
| G6: `ENV` hooks cover only `fetch` and `has_key?` | Hook enumeration: record whole table, or abstain; macro methods paused | S3 |
| G7: environment values in clear | Keyed digests locally; plain digests only for CI producer jobs | S3/S8 |
| G8: compiler identity is path, size, mtime | Toolchain identity digest, linker driver identity included | S2 |
| G9: raw argument list | Resolved behavior key; refused stale modes | S2 |
| G10: nothing observes program at run time | Observation build | S4/S5 |
| G11: one record per output, deleted before build | Per-signature receipts with verdict history | S6 |
| G12: nothing checks the walk against codegen | Recording-build cross-check; RG8 | S3 |

## 5. The run: the observation build

The runner builds each test with `-Diyi_observe`, which belongs to the behavior key. Observer runtime is the std module `std/observe` at `src/std/observe.iyi`. SPEC.md I.4 holds `src/iyi/` to 4,650 lines; `prelude_library_lines()` is budgeted at most 4,644 at PR close. The prelude gains only the two raise funs and, under `{% if flag?(:iyi_observe) %}`, the load of `std/observe` plus start and END hooks. `std/observe` has `bench/std_observe_exercise.{iyi,sh}` (`bench/std_exercise.sh:419-440`, `bench/tarball_std.sh:109`).
`@[Effect(kind)]` is permitted only on defs in `src/iyi` and `src/std`; anywhere else is a compile error.

| Class | Kinds | Effect on the run |
|---|---|---|
| observed | `file_read`, `file_stat`, `file_exists`, `dir_list`, `env_get`, `env_all`, `cwd`, `host` | Recorded in trace |
| output | `stdio`, `exit`, `file_write` (create, delete, rename, mkdir, link, symlink, touch, chmod) | Nothing; write outside scratch taints `shared-write` |
| not reusable | `clock`, `entropy`, `timer` (sleep, timeout, deadline), `network`, `process`, `signal`, `runtime_timing`, `code_location`, `dir_stream` (40, reason: directory read as a stream) | Taints run, naming def |
| internal | `memory`, `collector`, `threads`, `scheduler`, `self_image`, `console`, `panic_backtrace`, `temp_name`, `observation_channel` | Nothing; internal to runtime |

Examples: `src/std/file.iyi:1963` (`temp_name`, internal) vs `src/std/random.iyi:440-475` (`entropy`); `src/iyi/prelude.iyi:4781` (internal clock) vs `7529` (`runtime_timing`). `self_image` and `panic_backtrace` are internal because their results reach only the error stream; a runtime def returning code locations or debug information to program code is `code_location` (D18).

* **Injection:** Observer wrappers and `__iyi_observe_<kind>` calls are generated during semantic analysis, before the §4 hook, so they are typed, reached and encoded. The compiler renames each annotated def and generates a wrapper calling the renamed def followed by `__iyi_observe_<kind>` from `src/std/observe.iyi`. Wrappers forward positional and named arguments with their defaults. A def that yields or takes splats cannot carry an observed, output or not-reusable kind; that is a compile error naming the def; annotate the non-yielding helper it calls instead. The wrapper for kind `exit` calls its observer before the renamed def, since exit does not return. Every other kind observes after it. Panics keep calling `__iyi_exit` directly (`src/iyi/prelude.iyi:9608-9613`) and write no END. Outermost frame records: an observation (or taint) fires only at the outermost annotated def on the current task's call stack. Every annotated def opens a frame, including internal-kind defs (`memory`, `collector`, `threads`, `scheduler`, `self_image`, `console`, `panic_backtrace`, `temp_name`, `observation_channel`) and `stdio`, which get a frame-only wrapper that records nothing. Nested annotated calls inside an open frame record nothing. The depth counter is per task (fiber), not per thread, so a task switch inside a frame does not leak suppression to another task, kept in `std/observe` with zero cost in non-observe builds. Soundness: the outermost observed def's observation fully describes what flows out of it to program code (its arguments and result), so nested effects inside it are covered; internal frames return nothing program-visible beyond what A2 already treats as unspecified.
* **Closure:** Checked statically on the reached set of §4. Reachable `asm`, `lib` `fun` calls, and `lib` globals must sit inside an `@[Effect]` def in runtime library files. `llvm.*` intrinsics are compiler operations and not lib calls. Internal defs are defs in runtime library files (`src/iyi` or `src/std`) annotated with an `internal`-class kind (`memory`, `collector`, `threads`, `scheduler`, `self_image`, `console`, `panic_backtrace`, `temp_name`, `observation_channel`). In program files, `asm`, `lib` calls and globals, integer-to-pointer conversions, and calls to internal defs that return a value mark the run opaque with `FILE:LINE`. A call to an internal def that returns Nil or never returns (`raise`, the collector's `enable`, `disable` and `collect`) hands the program nothing a verdict can read beyond the values A2 already calls unspecified, so it is not opaque; the census showed that treating `raise` as opaque made nearly every standard library exercise unreusable. Unclassified reachable runtime sites mark the run opaque and trigger gate RG3. Runtime accessors that hand machine or timing values to programs are annotated `not reusable` (for example, `IyiWorkers.resolved` in `src/iyi/concurrency.iyi:3116-3134` returning `IyiThread.core_count` in `src/iyi/thread.iyi:954`, or collector and scheduler statistics). Uniqueness and layout values (such as `Reference#object_id` in `src/iyi/primitives.iyi:59-60` or temp names in `src/std/file.iyi:1911-1957`) remain unspecified values under A2. Classification rests on review, checked by RG6.
* **Channel:** `IYI_OBSERVE=<path>` names a runner-owned file outside scratch and outside roots. At startup the runtime opens it and unsets the variable before program code runs. It appends length-prefixed records and writes `END(status)` after `IyiTestCases.verdict` or program completion. Top-level assertion failures and panics call `__iyi_exit(1)` (`src/iyi/prelude.iyi:9608-9613`, `src/iyi/concurrency.iyi:2966-2971`, `3007-3010`), and signal deaths or timeout kills terminate the process without writing END. Missing or malformed END, trailing records, or reserved exit codes mark `trace incomplete`.

Run observations, test ids and `explain` entries map paths to logical roots:
* `src`: `Compiler.entry_root_of` (`src/compiler/iyi/compiler.cr:352`).
* `toolchain`: library entry holding `iyi/prelude.iyi` (`src/compiler/iyi/command/test.cr:251-255`).
* `pkg`: cache `mod/` (`src/compiler/iyi/build_inputs.cr:100`).
* `scratch`: runner per-test directory.
* `abs`: machine-bound files.

* **Trace content:**
  * File operations and links: Every observed kind (existence, size, `dir_list`, content) and every write is classified by the real path after resolving symlinks (`src/std/file.iyi:1288`). Creating a hard link (`src/std/file.iyi:1269`) or a symlink whose target is outside scratch taints `shared-write`. File operations record path as given, open flags, open-time stat, and absolute real path as resolved at open (`Dir.cd` changes process directory, `src/std/dir.iyi:387-395`). `Dir.cd` is recorded as an observed `cwd` event in the trace. Absolute paths map to roots using cwd active at open. Content is hashed after exit. Each trace record is tagged with its task id to preserve observation order per task.
  * Directory listings record names in the order returned.
  * Environment reads record name and whether program wrote it first (`env_get`: unwritten reads observe initial environment; reads after writes are internal). `env_all` digests every initial value in the whole initial environment table (except `IYI_OBSERVE`), recording `TMPDIR`, `TEMP` and `TMP` as the `scratch` locator.
  * Scratch, timestamps and writes: `TMPDIR`, `TEMP` and `TMP` map to the `scratch` locator, set on every platform (`src/std/dir.iyi:425-431`, `src/std/file.iyi:1921-1931`). Scratch directory starts empty for each run and is removed afterward. Existence, size, `dir_list` and content under scratch stay internal, as do reads of paths the run already wrote (not hashed after exit, not validated at lookup). Returning a timestamp of a scratch or self-written file taints the run with `clock`. Descriptors inherited from the runner (stdin, stdout, stderr) count as `stdio` by provenance rather than descriptor number, and the trace channel descriptor counts as `observation_channel`. Writes outside scratch or through descriptors outside runner-inherited `stdio` or a recorded open taint `shared-write`.
* **Process profile:** Empty argv, stdin as `/dev/null` via `Redirect::Close` opening `File::NULL` (`src/process.cr:550-551`, `607-612`), piped stdout/stderr, inherited cwd as (root, path), isolated `TMPDIR`/`TEMP`/`TMP` scratch directory created empty, timeout, umask, all `getrlimit` values (stack, open files, address space, data, CPU time, file size) and cgroup memory limit, cleared loader variables (`LD_PRELOAD`, `LD_LIBRARY_PATH`, `GLIBC_TUNABLES` on Linux per `SPEC.md:6425-6432`; `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH` on Darwin acting on libSystem, `src/iyi/prelude.iyi:303-308`), target triple, OS and kernel release.

## 6. Signatures, lookup and revocation

Encoding uses canonical, type-tagged, length-prefixed binary (FIPS 180-4, RFC 2104):

```
D(tag, x)     = SHA-256("iyi.stale.v1." || tag || 0x00 || enc(x))
K(x)          = HMAC-SHA256(machine key, x) in local records, x in portable records
TestId        = (root "src", path)
Element       = (kind, key, D(kind, typed content))
CallPathFp    = D("callpath", elements sorted by (kind, key))
LinkFp        = D("link", lib_flags, link_flags, static, CHILD_ENV values)
CompilerEnvFp = D("cenv", sort((name, value | absent) of value-class reads))
Build         = D("build", toolchain, behavior, K(CallPathFp), K(LinkFp), K(CompilerEnvFp))
ProfileFp     = D("profile", argv, stdin, stdio, cwd, timeout, umask, rlimits, cgroup_mem, loader_vars, target, os, kernel)
TraceFp       = h_n,  h_0 = D("trace0", ""),  h_i = D("trace", h_(i-1), obs_i)
Signature     = D("record", TestId, Build, ProfileFp, TraceFp)
Receipt       = {version, test, build, explain, profile, trace, signature,
                 mode: local|portable, newest: pass|fail|hung|build-failed, seq, contradicted}
```

Typed content is encoded node by node: class tag, fields in order, and the type of a typed node. A call encodes its arguments, block, `target_defs` as element keys, and expanded magic-constant default arguments, or a block-inlined target's body in place; a path its constant or type key; a variable its name and type; a literal its kind and bytes; an `If` its `truthy?` and `falsey?` flags and the branches codegen keeps. A declaration codegen emits nothing for contributes nothing to the `main` element (not even a tag or position): a `Def` encodes its hook expansions, a `Macro` nothing, a type body its initializers. Unused constant assignments contribute nothing to `main`. `explain` holds, per file under `src`, `toolchain` or `pkg`, K of a digest over the sorted digests of the elements written there, and one entry for all others; it names files in `--explain` and is never compared for validity.

Local mode keys the build components, `explain`, environment observations and `abs`-root observations with HMAC-SHA256 under the machine key. Portable mode uses plain `D`. A version change is always a miss.

TestId is (root `src`, path from `Compiler.entry_root_of`, `src/compiler/iyi/compiler.cr:352`). Every test whose TestId is shared within the selection runs fresh, with reason `ambiguous test id`, and records nothing.

Lookup and execution:

```
for test in selected tests, in fresh run order:
  accept = {}
  block  = {}
  unless --fresh:
    valid  = builds of local passes, then imported passes (unmasked, same target),
             not contradicted, whose profile equals the current profile and whose
             trace observations, replayed in order, answer the same now
    block  = builds of contradicted receipts and masks of test passing the same checks
    accept = valid minus block
  run(test, accept, block)

run(test, accept, block):
  build with -Diyi_observe --stale-key OUT --stale-accept accept --stale-block block:
    parse and type-check
    semantic error: report build failure; write nothing, revoke nothing
    compute Build in both modes (machine key read under BuildInputs.paused)
    refuse accept if Build in either mode matches a block entry in that entry's mode
    Build matches an accept entry in that entry's mode: stop; report pass (cached, source); next test
    generate code and link; reach mismatch taints
  build failure after Build: revoke every receipt of test that validates now
  execute under profile; collect trace
  interrupted sent to iyi test itself: write nothing, revoke nothing
  non-pass exit (fail, signal, timeout kill, reserved status):
    revoke every receipt of test that validates now (whatever trace state)
  pass with trace incomplete: write nothing
  pass, complete, untainted, run inputs unchanged during run: write receipt
```

Why sound: An equal build key means the compiler emits the same reached code (A1, RG8), so a rebuild runs the code the receipt ran. A deterministic program whose recorded answers all still hold makes the same reads and reaches the same verdict. Replay in order stops at the first mismatch (`run: fixtures/a.txt changed`). A changed condition reruns the test and records a second receipt, while the first stays valid for its own inputs. Validating tests in execution order preserves sequential equivalence.
Revocation: Local receipts mark `contradicted` (sticky). Imported receipts receive a local mask storing the masked receipt's build components, profile and trace. Before serving any receipt, the runner checks whether any contradicted receipt or mask of that test validates under current state (matching by state, not signature, because build components and environment observations use HMAC locally and plain SHA-256 in portable records). A new pass matching a contradicted signature keeps the contradicted flag (read-modify-write under the lock). Under the lock, a corrupt or unreadable record is replaced with a persistent contradiction marker for its test; a later `--fresh` executed pass with a complete trace clears it. Local masks and contradictions persist in the local store; cross-machine revocation occurs through the master shadow audit.

## 7. Local state

```
<cache root>/tests-v1/
  key                                machine key, created once, mode 0600
  seq                                attempt counter, advanced under lock
  lock                               held while writing receipts, masks, snapshots
  toolchain/<digest>.json            compiler and linker driver metadata memo
  records/<ab>/<signature>.json
  masks/<signature>                  local revocations storing build, profile, trace
  imported/<namespace digest>.json   one snapshot per namespace
```

Masks store the masked receipt's build components, profile and trace (`masks/<signature>`). `toolchain/` caches a digest memo of the compiler executable, LLVM shared library and linker driver, keyed by (path, device, inode, size, mtime, ctime); ctime cannot be set by `cp -p`, `touch` or `rsync -t`. Atomic writes write to a temp file, fsync, then rename (`MoveFileEx` with write-through on Windows). Readers take no lock. Masks are never deleted as corrupt; readers never delete masks. Under the lock, a corrupt or unreadable record file is replaced with a persistent contradiction marker for its test; a later `--fresh` executed pass with a complete trace clears it. S2 adds `tests-v1` to `NOT_BUILDS` (`src/compiler/iyi/codegen/cache_dir.cr:261`) because its toolchain memo is the first write under the cache root, preventing `cleanup_dirs` (`cache_dir.cr:212-219`) from rotating the machine key away. Outdated toolchain receipts are pruned during recording runs. Interrupts sent to `iyi test` leave existing receipts intact.

## 8. Portable index, trust and secrets

Snapshot format:

```json
{"format": "iyi-test-index", "version": 1, "namespace": "master",
 "repository": "github.com/iyilang/iyi", "workflow": ".github/workflows/iyi.yml",
 "ref": "refs/heads/master", "target": "x86_64-linux-gnu",
 "producer": {"run_id": 0, "run_attempt": 1, "sha": "...", "job": "iyi", "shard": "1/1"},
 "records": []}
```

* **Export:** Allowed only with `--fresh` within the CI producer context, guarded by an environment flag (such as `IYI_CI_PRODUCER=1`) set by the workflow and checked by the CI gate to prevent accidental export from developer workstations. Contains reusable passes and drops receipts with `abs` or `host` observations.
* **Import checks:** Validates format, version, matching namespace, matching target, sorted unique tests, and roots of trace observations and `explain` entries restricted to `src`, `toolchain` and `pkg`. Snapshots are uploaded uncompressed with `archive: false` so the API artifact digest directly covers the JSON file. That input needs `actions/upload-artifact` v7; the workflow pins v5 today (`.github/workflows/iyi.yml:93`), so S9 moves the stale jobs' upload steps to v7. `bench/stale_ci.sh fetch-master` is the only step holding `github.token` (the compiler links no TLS; `bench/dependency_floor.sh` forbids openssl). It downloads through the Actions API, checks the file SHA-256 against the API artifact digest, and writes `FILE.provenance.json`. `--import-index master=FILE` refuses a file if it lacks a sidecar, if its SHA-256 differs from the recorded digest, or if its snapshot producer differs from the recorded run. A forged sidecar counts as adversarial (§3 A4). Newer snapshots replace older ones wholesale.
* **Precedence:** Local masks and contradictions, then local passes, then imported passes. At most one receipt per test per snapshot.
* **Namespace `master`:** Produced on iyilang/iyi workflow runs on master pushes (`--export-index master=...`). Consumers trust only artifacts from `push` runs on `refs/heads/master` of that repository. Consumers fetch the newest completed master `push` run and import nothing for `master` if that run has no snapshot for the target (e.g. build failed before export, artifact expired). A run whose shadow audit disagreed publishes an empty snapshot (disabling consumption per RG6).
* **Namespace `run:<id>`:** Consumed only within the same workflow run. Snapshot union across shards is allowed only for shards from the same producer run; a snapshot union containing duplicate tests across shards is refused.
* **Trust and secrets:** No cross-run cache persistence in stale jobs (`actions/cache`). No secret or token reaches the export step environment; the token goes only to the artifact download step. The export gate verifies that the export step environment contains neither `secrets.` nor `github.token` (`.github/workflows/iyi.yml:2708`, `2795`, `3139`). Portable receipts use plain digests of public variables; local receipts use the machine key. Pull requests cannot write a namespace another ref reads.
* **CI flow (Linux first, others as RG3 turns green):**
  * Job `iyi` runs `bench/stale_tests.sh`. Under workflow `permissions: {}` (`iyi.yml:65`), the job grants `actions: read`, and only the download step receives `github.token` to download the master snapshot for audit. Runs `iyi test --fresh --export-index run:<id>=...` (and on master pushes, `--export-index master=...`) over `samples/iyi/*.iyi`, auditing against master, and uploads snapshots with `archive: false`.
  * Job `stale-fresh` on a fresh runner receives job `iyi`'s compiler binary as an artifact (matching compiler bytes so toolchain executable SHA-256 matches), imports the run snapshot, runs `--cached` and asserts every receipt hits (only platform identity mismatches allowed).
  * Re-executes with `--fresh` for shadow audit: tests that would have hit must pass with matching verdict, build key and observation sets (preserving observation order per task). The planted hidden-read test (row 24) runs on a fixture outside the published corpus. On disagreement, `stale-fresh` overwrites the master artifact with an empty snapshot under `if: always()` (or a final publish job waits on both audits).
  * Imports `master` and runs `--cached` with a git-diff self-check of run observations against `git diff --name-only <producer sha> HEAD`: hits whose trace observed a changed path fail the step; misses with an equal build key whose trace observed only unchanged checkout paths fail. Build keys are not checked against the diff, since a changed file that leaves reached code alone is expected to hit; RG8 and RG9 cover the build side. Miss check is limited to `File` observations of tracked checkout files mapped from roots (`src` mapped via `Compiler.entry_root_of`, `src/compiler/iyi/compiler.cr:352`; `toolchain` mapped to checkout `src/`).

## 9. `iyi test` behavior

```
iyi test [--json] [--timeout S] [--affected FILE]... [--cached | --fresh] [--explain]
         [--shard K/N] [--import-index NS=FILE]... [--export-index NS=FILE]... [paths]
```

* **Default mode:** Unchanged. Normal builds, no recording, no new JSON fields.
* **JSON fields under `--cached`/`--fresh`:** Per-test `cached` (bool), `source` (`local` or namespace), `reuse` (`hit`, `miss`, `not reusable`), `reason` (mismatch or taint with `FILE:LINE`). Top-level `cached` count and `audit` list.
* **Text summary:** `7 passed (5 from receipts), 0 failed`. Exit status unchanged.
* **`--explain`:** Prints one decision line per test. A miss names the first component that differs from the test's newest receipt, in the order toolchain, behavior, compiler environment, link, call path (with the files whose `explain` entries differ), profile, run.
* **`--affected`:** Selects candidates as today (`src/compiler/iyi/command/test.cr:120-163`): falls back to a full run when a manifest changed (`test.cr:129-131`), when a changed file cannot be in any closure (`test.cr:138-140`, `243-257`), or when a named file is missing (`test.cr:153`). A test whose own source does not parse is selected on its own (`test.cr:158`, `261-262`), and an import that does not parse stays in the closure by path (`test.cr:263-266`). Reuse evaluates inside selection. Unselected tests are never reported as passed and never touched in store.
* **Failures/timeouts/signals:** Every non-pass exit (fail, signal death, timeout kill, reserved status) revokes every receipt of that test that validates now, regardless of trace state. A build that fails before its signature exists revokes nothing: no receipt validates without one.
* **Interrupt:** Sent to `iyi test` itself: child tree killed (via a new process group on POSIX, job object on Windows, `src/compiler/iyi/command/test.cr:377-380`, `416`), no receipt written for active test, existing receipts left intact, nothing revoked, exits 130.
* **`--shard K/N`:** Deals tests round-robin; snapshots unioned only across shards of the same producer run; duplicate test across shards refused.
* **`--export-index NS=FILE`:** May be specified multiple times to export to multiple namespaces in a single run.
* **MCP:** `test` tool gains optional `cached` parameter (`src/compiler/iyi/command/mcp.cr:179`, `221`).
* **Crystal mode:** `iyi test` rejects `--crystal` as a direct CLI option (`src/compiler/iyi/command/test.cr:76-80`), so Crystal mode reaches `iyi test` only through `IYI_OPTS="--crystal"` (`src/compiler/iyi/command.cr:992`, `1565`). Tests always run fresh with reason `Crystal library effects are not classified` (SPEC.md V.9 (e)).
* **Crystal spec aggregate:** `./bin/crystal spec` is unchanged. If ever covered, unit is whole generated program (`src/compiler/iyi/command/spec.cr:98-115`).

## 10. Proof gates

| Gate | Proves | Blocks | Until green |
|---|---|---|---|
| RG1 | Compilers with equal build-input digests produce byte-identical test executables for corpus | Hits across commits | Executable SHA-256 stays in identity |
| RG2 | Normal and `-Diyi_observe` builds give equal exit status, stdout and stderr | Shipping `--cached` | Shipping waits |
| RG3 | Zero unclassified runtime sites reachable from corpus on target; report lists candidate runtime defs flagged by the §4 walk, with completeness resting on review and RG6 as the check | Enabling platform CI | Platform runs fresh |
| RG4 | Links byte-identical under randomized variables outside `CHILD_ENV` | Treating `CHILD_ENV` as whole link environment | Full link environment digested |
| RG5 | Runtime patched via `IYI_PATH` dropping each observer allows changed input to pass; gate catches it | Claiming kind is covered | Kind is not claimed |
| RG6 | Standing shadow audit catches unannotated leaks or disagreements | Keeping consumption enabled after disagreement | Consumption disabled until fix (publishes empty snapshot) |
| RG7 | Different `--threads` produce identical executables | Leaving `n_threads` out of behavior key | `n_threads` stays in key |
| RG8 | Over C2, C3 and single-site mutations generated from the walk's own elements (body, callee, overload capture, instance variable and its initializer, constant, class variable initializer, annotation, macro input, position change above a reached call or failable cast): every mutation changing normalized reached IR changes `CallPathFp`; link annotation mutations change the link command line and `LinkFp`; artifact object unit mutations change linked bytes and `Build`; mutations outside the reached set (unreached def body, unrelated type, unused constant, comment above code holding no location literal) change neither; codegen emits no function the walk did not reach | Shipping `--cached` | Shipping waits |
| RG9 | Every C2 and C3 program checked in two processes with address randomization, with and without a preanalysed prelude (`compiler.cr:605-617`), and on the `stale-fresh` runner gets one `CallPathFp` | Shipping `--cached` | Shipping waits |

Normalized reached IR is the unoptimized IR printed under `DUMP=1` (`codegen.cr:755-779`), with debug metadata stripped, type-id constants replaced by the names they denote and range checks by the sorted names in range, symbol indices by symbol strings, proc and temporary names by first-occurrence ordinals, union cases sorted by type name, and module-level tables (simple constants, type-id globals, GC layouts, symbol table) restricted to entries the emitted functions reference.

## 11. Phases and slices

| Slice | Files | Change | Out of scope | Done when |
|---|---|---|---|---|
| S1 (P1) | `src/crystal/digest/sha256.cr`, `src/compiler/iyi/stale/encoding.cr`, specs | FIPS 180-4 SHA-256, canonical encoding | Replacing MD5 in `UpToDate`, OpenSSL | Matches FIPS vectors, agrees with `std/digest` across blocks |
| S2 (P1) | `Makefile`, `Makefile.win`, `src/compiler/iyi/config.cr`, `compiler.cr`, `stale/toolchain.cr`, `bench/stale_reproducible.sh` | S2 adds `tests-v1` to `NOT_BUILDS` (`cache_dir.cr:261`); toolchain digest memo; behavior key with refused stale modes, toolchain digest with linker driver identity, RG1 and RG7 gates | Changing `UpToDate.compiler_identity` | RG1 and RG7 pass |
| S3 (P1) | `src/compiler/iyi/stale/call_path.cr`, `compiler.cr`, `command.cr`, `codegen/fun.cr`, `codegen/const.cr`, `codegen/class_var.cr`, `build_inputs.cr`, `macros/methods.cr`, `src/iyi/prelude.iyi`, `bench/stale_callpath.sh` | Reach walk and typed encoder with completeness macros; `__iyi_raise_cast_failed` and `__iyi_raise_closure_to_c` in prelude; canonical union creation (`program.cr:1601-1604`); `CallPathFp`, `LinkFp`, `CompilerEnvFp`; `--stale-key`, `--stale-accept`, `--stale-block`, `--stale-dump-elements` (all `DISPLAY_ONLY`); emitted-function cross-check; environment-only recorder with macro methods paused and enumeration hooked; direct linker invocation without shell; RG4 (in link section of bench/stale_callpath.sh), RG8 and RG9 gates | Reuse across tests, skipping the type check, changing `UpToDate` | G1 through G6 and G12 are closed, and RG4, RG8 and RG9 pass |
| S4 (P2) | `src/compiler/iyi/semantic/effects.cr`, annotations in `src/iyi` and `src/std`, `bench/stale_effects.sh` | `@[Effect]` typing, static closure check over the S3 reached set, RG3 gate | Program-level effect inference | RG3 clean on target |
| S5 (P2) | `src/std/observe.iyi`, `src/compiler/iyi/stale/trace.cr`, `bench/std_observe_exercise.iyi`, `bench/std_observe_exercise.sh`, `bench/stale_equivalence.sh` | `std/observe` module, observer injection during semantic, runtime trace channel, logical roots, RG2 gate | User-space tracing | RG2 passes and RG5 trace half passes (a dropped observer leaves the changed input out of the trace) |
| S6 (P3) | `command/test.cr`, `stale/store.cr`, `cache_dir.cr`, `mcp.cr`, `bench/stale_tests.sh`, workflows | Receipt storage keyed by build, atomic files, accept and block lists, lookup, revocation, `explain`, CLI flags | Remote cache | §12 local rows green and RG5 end-to-end half passes (a cached hit despite the change is caught by a fresh audit) |
| S8 (P3) | `src/compiler/iyi/stale/snapshot.cr` | Portable snapshot export and import, repeatable export flags, CI attestation check | Cross-repo sharing | Snapshot validation passes |
| S9 (P4) | `.github/workflows/iyi.yml`, `bench/stale_ci.sh`, `bench/stale_census.sh` | Master index publishing, `stale-fresh` job, shadow audit, git-diff self-check of run observations | Third-party CI | CI steps green |
| S10 (P5) | `SPEC.md`, `CHANGELOG.md`, `README.md` | SPEC test row, census and overhead documentation | Unmeasured claims | `bench/doc_numbers.py` passes |

S7 is removed: a macro `run` program output reaches the signature as expanded code.

Out of scope overall: per-case (`test "name"`) reuse, classifying Crystal library, caching failures, non-host targets, remote cache service, migrating bench drivers to `iyi test`, changing up-to-date check behavior, default-on reuse, adversarial tests, LSP, skipping the type check on a hit, reuse of one test's receipts by another, hashing libraries the linker finds by search path.

## 12. Acceptance and falsification

Automated in `bench/stale_tests.sh` unless marked CI:
1. Nothing changed, fresh state, snapshot imported: every receipt hits; each test is parsed and type-checked and nothing past semantic analysis runs: no codegen, object file, link or test process.
2. Body edit in a reached def of an imported module reruns the tests that reach it, with `--explain` naming its file; tests that do not reach it hit.
3. New file at an import candidate path that the compiler now loads instead: reruns when reached code differs, with the explanation naming the new file.
4. New file matched by a `require` glob reruns only when it changes reached code; otherwise hits. New entry in a run-listed directory reruns; unrelated directory hits. Run-time listings preserve returned order.
5. Env branch: `MODE=a` reads `a.txt`. Changing `b.txt` hits; changing `a.txt` reruns; setting `MODE=b` reruns and records second receipt; restoring `MODE=a` hits from first receipt.
6. Unset variable set to `""` reruns. Changing outer variable written by test before read hits. Enumeration (`env_all`) plus added variable reruns. Enumeration plus changed variable value reruns.
7. `IYI_OPTS=--release` reruns; adding `--json` or `--explain` hits.
8. Edit to a reached prelude or std def reruns every test reaching it; an edit to an unreached def in the same file hits.
9. Compiler rebuilt from changed sources misses everywhere. Compiler rebuilt from identical sources hits once RG1 is green.
10. Clock, entropy, sleep, socket, subprocess, signal handler and GC pause accessor each cause test to run, naming def. Accessor returning core count (`IyiWorkers.resolved`) runs with `not reusable`.
11. Temp file under scratch directory (`TMPDIR`/`TEMP`/`TMP`) stays reusable; existence, size, `dir_list` and content under scratch stay internal. Reads of self-written files stay internal. Writes outside scratch, or through descriptors outside runner-inherited `stdio` or a recorded open, run with `shared-write`.
12. Program `asm`, `lib` binding, integer-to-pointer conversion, or internal def call runs with `FILE:LINE`.
13. Failing test never served from receipt. Fixed test reruns, passes and records.
14. Revocation: `--fresh` run forced to fail through input hidden by patched runtime contradicts receipt; next `--cached` run reruns (matching by state). Local contradiction blocks a same-state pass imported later.
15. Non-pass exit (failure, signal, timeout kill, build failure after the signature exists) writes no receipt and revokes every receipt of that test that validates now, regardless of trace state. A type error writes nothing and revokes nothing.
16. Interrupt sent to `iyi test` itself: finished tests keep receipts; nothing revoked; active test writes nothing.
17. Closed trace channel or missing END: trace incomplete, no receipt written.
18. Filtered runs and `--affected` touch only selected tests; excluded tests reported skipped, never passed.
19. Union of `--shard k/3` snapshots from same producer run equals unsharded snapshot. Mixing shards across producer runs or duplicate tests across shards is rejected.
20. Snapshot with wrong namespace, target, version, duplicate test, or path outside roots is refused. Accidental export outside CI producer attestation flag is refused.
21. Corrupt or unreadable receipt becomes a miss and is replaced under lock with a persistent contradiction marker for its test; a later `--fresh` executed pass with complete trace clears it. Masks store observations and are never deleted as corrupt. Concurrent runs leave no torn receipts.
22. Crystal mode via `IYI_OPTS="--crystal"` always runs with reason. `./bin/crystal spec` output unchanged.
23. Workflow check: pull request stale jobs upload nothing across runs and persist no state; export step environment contains no secrets or `github.token`.
24. (CI) `stale-fresh` reports all hits on push with matching compiler bytes. Shadow audit checks verdict, build key and observation sets. Git-diff self-check catches validation bugs on tracked files read at run time. Planted hidden read outside published corpus with changed file between producer and audit fails shadow audit.
25. `Dir.cd` into subdirectory followed by relative file read resolves and records absolute path at open; modifying target file reruns test.
26. A source edited while its test builds: the receipt carries the signature of what the compiler parsed; the next check hits only if the current content gives that signature.
27. Newest master push run without target snapshot imports nothing; disagreeing audit run publishes empty snapshot turning consumption off.
28. Runner clears dynamic loader variables (`LD_PRELOAD`, `DYLD_INSERT_LIBRARIES`), so changed launcher loader variable hits; changed `getrlimit` value or cgroup memory limit misses.
29. Reading, checking existence or size, or writing through a symlink in scratch pointing outside scratch resolves to target file outside scratch (reads and stat checks observed, writes taint `shared-write`). Creating a symlink in scratch targeting outside scratch taints `shared-write`.
30. Creating a hard link to a file outside scratch taints the run with `shared-write`.
31. Returning a timestamp of a scratch or self-written file taints the run with `clock`.
32. Local `master=` file lacking a valid `.provenance.json` sidecar, with a mismatched SHA-256, or with forged run metadata is refused.
33. Edit to an unreached def of an imported module hits, including one that moves reached defs below it to other lines.
34. New overload in any loaded file that captures a reached call reruns.
35. Macro `read_file` or `env` input change reruns when the expansion is reached and hits when unreached. A macro `run` printing the clock misses on every check.
36. Added instance variable, changed instance variable type, or edited instance variable initializer of a reached type reruns.
37. Unrelated new type in a loaded file hits. New subclass of a reached virtual type reruns.
38. Comment added above a call leaving magic-constant defaults (`__LINE__`) to codegen reruns (call-site location argument changed); comment below file's last location-dependent construct hits.
39. Type error in an unreached def fails the check as `does not build` and is never served from a receipt.
40. Rebuilt `.iyimod` whose object code changed reruns tests linking it; one rebuilt to identical bytes hits.
41. Changed `pkg-config` answer or `CHILD_ENV` value reruns; `ldflags` containing a backtick or `$` is refused; changed `locator` or `display` compiler variable hits.
42. A walk constructed with one edge kind disabled (internal constructor argument; no CLI or environment surface) makes the recording build refuse with `reach mismatch` for a program using that edge; one in-process spec per edge kind.
43. Two checks of one tree in separate processes, and on the `stale-fresh` runner, give one signature.
44. A stale build under a refused mode (`IYI_OPTS="--emit llvm-ir"`) runs with a not-reusable reason. `--no-cleanup` is refused too, but only tooling verbs accept it, since an uncleaned program cannot be generated; its refusal is proven in-process.
45. Def returning `__LINE__` default (`def here(line = __LINE__) = line`): moving a call to `here()` to another line reruns.
46. Failable downcast: moving the cast to another line reruns; `__iyi_raise_cast_failed` in prelude prevents codegen-time typing.
47. Two processes checking a def taking `Int32 | String` compute identical signatures under canonical union sorting.
48. Linked library or link flag using a backtick, `$`, `*`, `?`, `[` or `~` is refused with a not-reusable reason; link command uses exact flags vector computed during check.

## 13. Measurements and completion

Census (`bench/stale_census.sh`) per platform over C2 (`samples/iyi/*.iyi`) and C3 (`bench/std_*_exercise.iyi` standalone):
* Records verdict, reusable or not, reason category and site.
* Categories: requested effect, opaque program construct, refused build mode, runner (trace incomplete, racy run input), internal (unclassified runtime site, internal effect reported as reason, `ambiguous key`, `ambiguous test id`, `reach mismatch`, signature unstable between two checks).

Overhead reported as measured with no thresholds and no promised speedup:
* Wall time of `--fresh` against default mode.
* Per-hit validation time.
* Trace and receipt bytes per program.
* Per-hit check time against a default-mode build and run of the same test, split as the progress tracker reports it: parse, top level, main semantic (macro `run` programs included), walk and hashing. Measured with and without a preanalysed prelude (`compiler.cr:605-617`; `iyimod.cr:7-9` reports the top-level pass at 0.99 s cold and 0.004 s preanalysed).
* Reached elements and encoded bytes per program, and the reruns RG8 attributes to over-approximation.

Completion requires all of:
1. Every §12 row automated and green on every enabled platform.
2. RG1 through RG9 each green, or claim withdrawn in SPEC.md.
3. Census with zero runner or internal reasons, and reusable programs on every enabled platform.
4. Consumption and audit run on master with zero disagreements since enablement.
5. SPEC.md recording census and overhead as measured.

If the census shows almost all real tests always running, work is not marked complete even if condition 3 holds. The distribution goes to Jason Waldrip and the default stays off. Check cost goes to Jason Waldrip beside the census; a hit is not described as cheaper than a build until §13 measures it.

## 14. Limits

* Flaky tests: bounded by contradiction detection and shadow audit.
* Deliberately adversarial test code.
* Every hit type-checks: parse, semantic analysis and macro execution, `run` programs included, happen on every check.
* A verdict that depends on compiler numbering can change after an unrelated edit and stays hidden until a `--fresh` run or the audit (A2).
* Modules read from `.iyimod` artifacts are keyed per linked object unit, not per function.
* Libraries the linker finds by search path are identified by flags, `CHILD_ENV` and the toolchain, not by content.
* Where codegen stops after a `NoReturn`, edits behind it rerun.
* File writers that preserve size and mtime (`cp -p`, `tar`, `rsync -t`): A3's stat comparison cannot observe content modifications when size and mtime are preserved.
* Process limits or loader settings outside recorded profile properties.
* Per-case reuse within a test file.
* Non-host targets.
* Cached failures.
* Snapshot export is limited to CI producer context via workflow attestation flag to prevent accidental export.
* Cross-machine hits also need identical checkout and toolchain paths, since reached code holds absolute location literals (every `assert`).
* Cross-machine hits are expected only between runners configured alike (matching kernel release, rlimits, cgroup memory limit, and loader variables).
* Hits across commits wait on RG1.
* Environment mutations (`ENV.[]=`, `ENV.delete`, `__iyi_set_environ`) over-approximate by recording `env_all` because `std/observe` provides no dedicated write hook.
* No speedup is promised.
