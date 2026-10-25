# iyi Stale Test Design

Status: Proposal for review. Nothing in it is built. Grounded at iyilang/iyi `9045a508` (master, 2026-10-24); every `path:line` is at that commit.

## 1. Review

`iyi test --cached` reports a test as passing without building or running it, when everything its build and its run were observed reading still gives the same answer. The compiler up-to-date recorder watches the build. An observation build watches the run. Master CI publishes receipts that other runs import.

### Requirements set by Jason Waldrip before planning

* A test identity for reuse is a SHA signature over the contents of everything it transitively depends on. A portable index records what has actually passed.
* The compiler and runtime discover dependencies automatically. Nobody declares file or environment lists.
* Inputs include the environment (12-factor), effective compiler flags and defaults, toolchain and target, and process behavior.
* Local and CI runs use the same validity rules.
* Crystal mode keeps working.
* Nothing is implemented before this plan is approved.

### Decisions this plan makes

* **D1:** The unit of reuse is one `*_test.iyi` program: one build, one process (§2, §3).
* **D2:** A receipt is valid when every recorded observation answers the same now. Contents are compared by SHA-256, never by interface hashes or call coverage (§3, §6).
* **D3:** The build side extends `BuildInputs`/`UpToDate`. No second recorder (§4).
* **D4:** The run side is an observation build with compiler-injected observers and a static closure check. Anything outside the closure is opaque (§5).
* **D5:** Clock, entropy, timers, network, subprocesses, signal handlers, runtime timing values and writes outside the run scratch directory make a run not reusable. The test still runs and reports (§5).
* **D6:** Values the runtime makes up for uniqueness or layout are unspecified, not inputs. Accessors that hand internal values to programs are annotated not reusable (§3, §5).
* **D7:** Only passes become receipts. A non-pass under a state that validates a receipt revokes it in the local store; cross-machine revocation occurs through the master audit (§6, §8).
* **D8:** Local state lives in `<cache root>/tests-v1/`, written atomically. Environment values are stored as keyed digests (§6, §7).
* **D9:** There are two namespaces. `master` holds receipts from iyilang/iyi master pushes, fetched through the Actions API. `run:<id>` holds receipts within a single workflow run. Pull requests never write a namespace another ref reads (§8).
* **D10:** Producer jobs carry no secrets, so portable records may hold plain digests of environment values. A gate checks the export step environment for secrets and tokens (§8).
* **D11:** Every CI run produces receipts, then a fresh runner hits and re-executes them. Hits across runs and commits wait on RG1 (§8, §10).
* **D12:** `--cached` is opt-in. Default `iyi test` behavior and output do not change. Changing the default is a separate proposal backed by §13 (§9).
* **D13:** `--affected` keeps its selection; reuse applies inside it (§9).
* **D14:** Crystal mode (reached via `IYI_OPTS`) always runs and states why. The Crystal spec aggregate is the unit if it is ever covered (§9).
* **D15:** A claim that rests on an unproven property is blocked by a named proof gate. There is no declaration mode as a fallback (§10).

### Approval gate

Implementation starts only after Jason Waldrip approves this pull request. Approval covers D1 through D15 and the phase order in §11. A decision that changes during implementation changes this file in the same PR as the code. No phase is ticketed until this document merges.

## 2. What exists at 9045a508

* **`iyi test`:**
  * One build and one process per file (`src/compiler/iyi/command/test.cr:176`, `317-375`). The header rejects interface hashes for re-running (`test.cr:18-30`).
  * Options are `--json`, `--timeout` and `--affected`; unknown flags are refused (`test.cr:46-85`). Files are discovered and deduplicated by `Iyi.file_key` (`test.cr:87-118`).
  * `--affected` parses the import closure and falls back to a full run when a manifest changed (`test.cr:129-131`), when a changed file cannot be in any closure, meaning it has an extension other than `.iyi` or is a prelude file (`test.cr:138-140`, `243-257`), or when a named file is missing (`test.cr:153`). A test whose own source does not parse is selected on its own (`test.cr:158`, `261-262`), and an import that does not parse stays in the closure by path (`test.cr:263-266`). Syntax changes in existing imported files do not cause a full run.
  * JSON output (`test.cr:179-217`). Stdin is closed (`test.cr:336`; `src/process.cr:550-551`). No result is persisted.
* Named cases and the exit-status verdict: `src/iyi/testing.iyi:151-205`. `assert` and `raise` default `file = __FILE__` (`src/iyi/prelude.iyi:9545`, `9619`).
* The Crystal spec runner builds one generated program requiring every selected spec, then runs it once (`src/compiler/iyi/command/spec.cr:55-115`, `98-115`).
* **The up-to-date check:**
  * Recorder design: `src/compiler/iyi/build_inputs.cr:4-23`. Stamps (`build_inputs.cr:25-39`), `CHILD_ENV` (`build_inputs.cr:41-47`), cache root excluded (`build_inputs.cr:97-109`), `cannot` (`build_inputs.cr:272`), hooks (`build_inputs.cr:519-591`).
  * One JSON record per output path (`src/compiler/iyi/up_to_date.cr:40`). Compiler identity is version, description, executable path, size and mtime (`up_to_date.cr:47-55`). Arguments exclude `DISPLAY_ONLY` (`up_to_date.cr:26`, `37`), and environment values stay in clear (`up_to_date.cr:156-159`).
  * Macro abstain cases (`src/compiler/iyi/macros/methods.cr:109-111`), `IYI_RUN_INPUTS` (`src/compiler/iyi/macros/macros.cr:254`), SPEC.md V.9 (e), and the gate `bench/up_to_date.sh` at `.github/workflows/iyi.yml:366`, `1543`, `2114`.
* **Effective options:** `IYI_OPTS` is parsed before explicit arguments (`src/compiler/iyi/command.cr:1553`, `1565`). The prelude key classifies compiler properties with a compile-time completeness check (`src/compiler/iyi/compiler.cr:523-560`); the behavior key copies that model.
* **Environment access:** On POSIX, `Program.env` scans `__iyi_environ` (`src/iyi/prelude.iyi:9844`, `9990`), and `std/env` reads, writes and enumerates the same table (`src/std/env.iyi:61`, `121`, `206`, `283`). On Windows, `Program.env` reads the process block via `__iyi_win_env_get` (`src/iyi/prelude.iyi:9993-9997`), and `std/env` Windows branches do the same (`src/std/env.iyi:59`). Child processes inherit the environment table (`src/std/process.iyi:799`, `1696`).
* **Time, randomness and temp names:** `src/std/time.iyi:1252-1349`, `src/std/random.iyi:440-475`, temp names from getrandom, arc4random or clock (`src/std/file.iyi:1963-1985`), `TMPDIR` read by `Dir.tempdir` (`src/std/dir.iyi:425-431`) and `File.tempfile` (`src/std/file.iyi:1921-1931`), GC pause clock and accessor (`src/iyi/prelude.iyi:4781`, `7529`).
* SHA-256 exists in iyi (`src/std/digest.iyi:429`). The host side has only `src/crystal/digest/md5.cr` and `sha1.cr`.
* The cache cleaner keeps ten most recently used directories (`src/compiler/iyi/codegen/cache_dir.cr:109-117`, `212-233`). The MCP `test` tool is at `src/compiler/iyi/command/mcp.cr:179`, `221`.
* **Corpus and CI:**
  * No committed `*_test.iyi`. The test verb is exercised by generated fixtures: `bench/test_verb.sh` and `bench/agent_loop.py:72-76`, `674-695`, at `.github/workflows/iyi.yml:604`, `644`, `1519`, `1531`, `2106`, `2134`.
  * The std exercises run as four weighted shards per platform (`.github/workflows/iyi.yml:934-985`, `1663`, `2450`).
  * `on: [push, pull_request]` (`iyi.yml:41`), `permissions: {}` (`iyi.yml:65`). The only `secrets.` references are in the VS Code job (`iyi.yml:3174-3175`). `github.token` is exported in step environments (`iyi.yml:2708`, `2795`, `3139`), and PR jobs use `actions/cache` (`iyi.yml:1362`, `1647`, `2700`, `2787`, `2880`).

## 3. The claim and what it assumes

**Claim:** Under `--cached`, a test reported as passing from a receipt would, if rebuilt and rerun now, read the same bytes, names and values at every point it reads anything, and so reach the same verdict.

* **A1 (Determinism):** Given identical answers to observed reads, the compiler builds the same program and the program reaches the same verdict. Guards: RG1, RG2 and RG7 for the compiler; contradiction detection and the shadow audit for tests.
* **A2 (Unspecified values):** Memory addresses, temp names, scheduling order, descriptor numbers and uninitialized memory are not inputs. A verdict depending on them is a flaky test. Reuse can hide a flake that a rerun might expose, identical to the exposure of a plain rerun. Process limits not captured in the profile are unspecified values. Guards: a contradiction revokes in the local store, and any shadow-audit disagreement fails CI.
* **A3 (Inputs hold still during a run):** Guard: compare the stat taken when the test opened a file with a stat after exit. A file whose mtime falls within the recorder resolution of the open (SPEC.md V.9 (e)) taints the run.
* **A4 (Cooperative tests):** Accidental bypass is detected and marks the run not reusable: program `asm`, `lib` bindings, integer-to-pointer conversions, or a closed trace channel. Only trusted refs produce cross-run receipts.

## 4. The build: extending the up-to-date recorder

Carries over unchanged from `BuildInputs` and `UpToDate`:
* The watch-not-declare recorder and hooks (`src/compiler/iyi/build_inputs.cr:519-591`).
* The `cannot` abstain path (`build_inputs.cr:272`).
* Excluding cache root and build outputs (`src/compiler/iyi/build_inputs.cr:111-116`, `156-180`; `BuildInputs#ignore` and `#excluded?`). Receipts drop post-build output stamps (`src/compiler/iyi/up_to_date.cr:146-148`, `167-168`), because the test runner binary receives a fresh temp name each run and is removed afterward (`src/compiler/iyi/command/test.cr:325`, `366`).
* Fingerprinting files whose stamps fall within clock resolution (`build_inputs.cr:184-212`).
* The gate pattern of `bench/up_to_date.sh` (`.github/workflows/iyi.yml:366`).

### Gap table

| Gap | Change | Slice |
|---|---|---|
| G1: stamps are size and mtime | SHA-256 of file input when first seen; receipt refused if stamp at hashing differs from first-look stamp (`build_inputs.cr:184-212`) | S1/S3 |
| G2: absolute keys, cwd verbatim | Logical roots (`src`, `toolchain`, `pkg`, `scratch`, `abs`) | S3 |
| G3: compiler identity is path, size, mtime | Toolchain identity digest | S2 |
| G4: raw argument list | Resolved behavior key | S2 |
| G5: environment values in clear | Keyed digests locally; plain digests only for CI producer jobs | S3/S8 |
| G6: `ENV` hooks cover only `fetch` and `has_key?` | Hook enumeration: record whole table, or abstain | S3 |
| G7: macro `run` reads are self-reported | Blind for receipts until run programs build in observation mode | S7 |
| G8: `cannot` mixes blind inputs with output warnings | Receipts abstain only on blind reasons | S3 |
| G9: linker driver identity not recorded | Driver path, `--version` output and digest | S3 |
| G10: nothing observes program at run time | Observation build | S4/S5 |
| G11: one record per output, deleted before build | Per-signature receipts with verdict history | S6 |

Compile observations form a sorted set: `File(root, path, sha256)`, `Absent(root, path)`, `Dir(root, path)`, `Listing(root, path, sha256(sorted names))`, `Env(name, class, digest|absent)`, `PkgConfig(module, static, digest)`, and `Embedded(root, absolute path)` when a location macro expanded to an absolute path (`assert` does this).

Logical roots:
* `src`: `Compiler.entry_root_of` (`src/compiler/iyi/compiler.cr:352`).
* `toolchain`: library entry holding `iyi/prelude.iyi` (`src/compiler/iyi/command/test.cr:251-255`).
* `pkg`: cache `mod/` (`src/compiler/iyi/build_inputs.cr:100`).
* `scratch`: runner per-test directory.
* `abs`: machine-bound files.

Environment reads by the compiler are classified `value`, `locator` or `display`, with a compile-time check. Macro `env` reads and unlisted variables are classified `value`.
Toolchain identity embeds a build-input digest covering compiler sources, LLVM version, bootstrap compiler version and build flags, plus compiler executable SHA-256 until RG1 is green, LLVM shared library digest, and linker driver path, version and digest.
The behavior key classifies compiler properties after defaults apply (`IN_BEHAVIOR_KEY`, `LOCATION_ONLY` or `DISPLAY_ONLY`), using the check model in `src/compiler/iyi/compiler.cr:523-560`.

## 5. The run: the observation build

The runner builds each test with `-Diyi_observe`, which belongs to the behavior key.
`@[Effect(kind)]` is permitted only on defs in `src/iyi` and `src/std`; anywhere else is a compile error.

| Class | Kinds | Effect on the run |
|---|---|---|
| observed | `file_read`, `file_stat`, `file_exists`, `dir_list`, `env_get`, `env_all`, `cwd`, `host` | Recorded in trace |
| output | `stdio`, `exit`, `file_write` (create, delete, rename, mkdir) | Nothing; write outside scratch taints `shared-write` |
| not reusable | `clock`, `entropy`, `timer` (sleep, timeout, deadline), `network`, `process`, `signal`, `runtime_timing` | Taints run, naming def |
| internal | `memory`, `collector`, `threads`, `scheduler`, `self_image`, `console`, `panic_backtrace`, `temp_name`, `observation_channel` | Nothing; internal to runtime |

Examples: `src/std/file.iyi:1963` (`temp_name`, internal) vs `src/std/random.iyi:440-475` (`entropy`); `src/iyi/prelude.iyi:4781` (internal clock) vs `7529` (`runtime_timing`).

* **Injection:** In observation builds the compiler renames each annotated def and generates a wrapper calling the renamed def followed by `__iyi_observe_<kind>` from `src/iyi/observe.iyi`. A kind without an observer or a def with a mismatched signature is a compile error.
* **Closure:** Checked statically on the typed program. Reachable `asm`, `lib` `fun` calls, and `lib` globals must sit inside an `@[Effect]` def in runtime library files. In program files, any of these, integer-to-pointer conversions, or calls to internal defs mark the run opaque with `FILE:LINE`. Unclassified reachable runtime sites mark the run opaque and trigger gate RG3. Runtime accessors that hand an internal value to programs are annotated `not reusable` (for example, `IyiWorkers.resolved` in `src/iyi/concurrency.iyi:3116-3134` returning `IyiThread.core_count` in `src/iyi/thread.iyi:954`). RG3 reports every runtime def returning values derived from internal defs, checked by RG6.
* **Channel:** `IYI_OBSERVE=<path>` names a runner-owned file outside scratch and outside roots. At startup the runtime opens it and unsets the variable before program code runs. It appends length-prefixed records and writes `END(status)` after `IyiTestCases.verdict` or program completion. Top-level assertion failures and panics call `__iyi_exit(1)` (`src/iyi/prelude.iyi:9608-9613`, `src/iyi/concurrency.iyi:2966-2971`, `3007-3010`), and signal deaths or timeout kills terminate the process without writing END. Missing or malformed END, trailing records, or reserved exit codes mark `interrupted: trace incomplete`.
* **Trace content:**
  * File reads record path as given, open flags, open-time stat, and absolute path as resolved at open (`Dir.cd` changes process directory, `src/std/dir.iyi:387-395`). `Dir.cd` is recorded as an observed `cwd` event in the trace. Absolute paths map to roots using cwd active at open. Content is hashed after exit.
  * Directory listings record names in the order returned.
  * Environment reads record name and whether program wrote it first (`env_get`: unwritten reads observe initial environment; reads after writes are internal). `env_all` digests every initial value in the whole initial environment table (except `IYI_OBSERVE`).
  * Scratch and writes: `TMPDIR`, `TEMP` and `TMP` map to the `scratch` locator, set on every platform (`src/std/dir.iyi:425-431`, `src/std/file.iyi:1921-1931`). Scratch directory starts empty for each run and is removed afterward. Reads under scratch, and reads of paths the run already wrote, stay internal (not hashed after exit, not validated at lookup). Writes are classified by path: a write outside scratch, or through a descriptor the runtime never observed being opened, taints `shared-write`.
* **Process profile:** Empty argv, closed stdin (`src/process.cr:550-551`), piped stdout/stderr, inherited cwd as (root, path), isolated `TMPDIR`/`TEMP`/`TMP` scratch directory created empty, timeout, umask, all `getrlimit` values (stack, open files, address space, data, CPU time, file size) and cgroup memory limit, cleared or recorded loader variables (`DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH` on Darwin acting on libSystem, `src/iyi/prelude.iyi:303-308`), target triple, OS and kernel release.

## 6. Signatures, lookup and revocation

Encoding uses canonical, type-tagged, length-prefixed binary (FIPS 180-4, RFC 2104):

```
D(tag, x)  = SHA-256("iyi.stale.v1." || tag || 0x00 || enc(x))
TestId     = (root "src", path)
CompileFp  = D("compile", toolchain, behavior, sort(compile observations))
ProfileFp  = D("profile", argv, stdin, stdio, cwd, timeout, umask, rlimits, cgroup_mem, loader_vars, target, os, kernel)
TraceFp    = h_n,  h_0 = D("trace0", ""),  h_i = D("trace", h_(i-1), obs_i)
Signature  = D("record", TestId, CompileFp, ProfileFp, TraceFp)
Receipt    = {version, test, compile observations, profile, trace, signature,
              mode: local|portable, newest: pass|fail|hung|build-failed, seq, contradicted}
```

Local mode digests environment values and `abs`-root observations with HMAC-SHA256 under the machine key. Portable mode uses plain `D`. A version change is always a miss.

Lookup and execution:

```
for test in selected tests, in fresh run order:
  if --fresh: run(test); next
  for receipt in local passes, then imported passes (unmasked, same target):
    skip if contradicted or masked
    skip if any contradicted receipt or mask of test validates now (match by state)
    skip unless toolchain and behavior key equal current ones
    skip unless every compile observation answers the same now
    skip unless profile equals current profile
    skip unless every trace observation, replayed in order, answers the same now
    report pass (cached, source); next test
  run(test)

run(test):
  build with -Diyi_observe and recorder; blind reason taints
  refuse receipt if any file stamp at hashing time differs from first-look stamp
  execute under profile; collect trace
  interrupted sent to iyi test itself: write nothing, revoke nothing
  non-pass exit (fail, signal, timeout kill, reserved status, build failure):
    revoke every receipt of test that validates now (whatever trace state)
  pass with incomplete trace: write nothing
  pass, complete, untainted, inputs unchanged during run: write receipt
```

Why sound: A deterministic program whose recorded answers all still hold makes the same reads and reaches the same verdict. Replay in order stops at the first mismatch (`run: fixtures/a.txt changed`). A changed condition reruns the test and records a second receipt, while the first stays valid for its own inputs. Validating tests in execution order preserves sequential equivalence.
Revocation: Local receipts mark `contradicted` (sticky). Imported receipts receive a local mask. Before serving any receipt, the runner checks whether any contradicted receipt or mask of that test validates under current state (matching by state, not signature, because CompileFp carries `CHILD_ENV` digests, `src/compiler/iyi/build_inputs.cr:46-47`, `93`, which use HMAC locally and plain SHA-256 in portable records). Local masks and contradictions persist in the local store; cross-machine revocation occurs through the master shadow audit.

## 7. Local state

```
<cache root>/tests-v1/
  key                                machine key, created once, mode 0600
  seq                                attempt counter, advanced under lock
  lock                               held while writing receipts, masks, snapshots
  records/<ab>/<signature>.json
  masks/<signature>                  local revocations of imported receipts
  imported/<namespace digest>.json   one snapshot per namespace
```

Atomic writes write to a temp file, fsync, then rename (`MoveFileEx` with write-through on Windows). Readers take no lock. Masks are never deleted as corrupt; readers never delete masks. Corrupt record files are removed as misses. S6 adds `tests-v1` to `NOT_BUILDS` (`src/compiler/iyi/codegen/cache_dir.cr:261`) so cache rotation spares it (`cache_dir.cr:109-117`, `212-233`). Outdated toolchain receipts are pruned during recording runs. Interrupts sent to `iyi test` leave existing receipts intact.

## 8. Portable index, trust and secrets

Snapshot format:

```json
{"format": "iyi-test-index", "version": 1, "namespace": "master",
 "repository": "github.com/iyilang/iyi", "workflow": ".github/workflows/iyi.yml",
 "ref": "refs/heads/master", "target": "x86_64-linux-gnu",
 "producer": {"run_id": 0, "run_attempt": 1, "sha": "...", "job": "iyi", "shard": "1/1"},
 "records": []}
```

* **Export:** Allowed only with `--fresh` within the CI producer context (an attestation the workflow sets and the CI gate checks; refused on developer workstations to prevent leaking digests of low-entropy secrets or local `.env` files). Contains reusable passes and drops receipts with `abs` or `host` observations.
* **Import checks:** Validates format, version, matching namespace, matching target, sorted unique tests, and roots restricted to `src`, `toolchain` and `pkg`. Only the GitHub Actions API filter establishes `master` provenance (verifying `producer.run_id` against trusted push runs on `refs/heads/master`). Local files imported under `master=` without API verification are rejected. Newer snapshots replace older ones wholesale.
* **Precedence:** Local masks and contradictions, then local passes, then imported passes. At most one receipt per test per snapshot.
* **Namespace `master`:** Produced on iyilang/iyi workflow runs on master pushes (`--export-index master=...`). Consumers trust only artifacts from `push` runs on `refs/heads/master` of that repository. Consumers fetch the newest completed master `push` run and import nothing for `master` if that run has no snapshot for the target (e.g. build failed before export, artifact expired). A run whose shadow audit disagreed publishes an empty snapshot (disabling consumption per RG6).
* **Namespace `run:<id>`:** Consumed only within the same workflow run. Snapshot union across shards is allowed only for shards from the same producer run; a snapshot union containing duplicate tests across shards is refused.
* **Trust and secrets:** No cross-run cache persistence in stale jobs (`actions/cache`). Producer jobs reference no secrets (`.github/workflows/iyi.yml:3174-3175`). The export gate verifies that the export step environment contains neither `secrets.` nor `github.token` (`iyi.yml:2708`, `2795`, `3139`). Portable receipts use plain digests of public variables; local receipts use the machine key. Pull requests cannot write a namespace another ref reads.
* **CI flow (Linux first, others as RG3 turns green):**
  * Job `iyi` runs `bench/stale_tests.sh`. Under workflow `permissions: {}` (`iyi.yml:65`), the job configures `actions: read` and uses `github.token` to download the master snapshot for audit. Runs `iyi test --fresh --export-index run:<id>=...` (and on master pushes, `--export-index master=...`) over `samples/iyi/*.iyi`, auditing against master, and uploads snapshots.
  * Job `stale-fresh` on a fresh runner receives job `iyi`'s compiler binary as an artifact (matching compiler bytes so toolchain executable SHA-256 matches), imports the run snapshot, runs `--cached` and asserts every receipt hits (only platform identity mismatches allowed).
  * Re-executes with `--fresh` for shadow audit: tests that would have hit must pass with matching verdict and observation sets (preserving observation order per task). Disagreements publish an empty master snapshot.
  * Imports `master` and runs `--cached` with git-diff self-check against `git diff --name-only <producer sha> HEAD`. Git-diff self-check fetches producer SHA and checks only validation bugs: hits observing changed paths fail the step; misses on unchanged checkout paths fail only for `File` observations of tracked checkout files mapped from roots (`src` mapped via `Compiler.entry_root_of`, `src/compiler/iyi/compiler.cr:352`; `toolchain` mapped to checkout `src/`). Planted hidden read test modifies a hidden file between producer and audit where compiler bytes match; caught by the shadow audit.

## 9. `iyi test` behavior

```
iyi test [--json] [--timeout S] [--affected FILE]... [--cached | --fresh] [--explain]
         [--shard K/N] [--import-index NS=FILE]... [--export-index NS=FILE] [paths]
```

* **Default mode:** Unchanged. Normal builds, no recording, no new JSON fields.
* **JSON fields under `--cached`/`--fresh`:** Per-test `cached` (bool), `source` (`local` or namespace), `reuse` (`hit`, `miss`, `not reusable`), `reason` (mismatch or taint with `FILE:LINE`). Top-level `cached` count and `audit` list.
* **Text summary:** `7 passed (5 from receipts), 0 failed`. Exit status unchanged.
* **`--explain`:** Prints one decision line per test.
* **`--affected`:** Selects candidates as today (`src/compiler/iyi/command/test.cr:120-163`): falls back to a full run when a manifest changed (`test.cr:129-131`), when a changed file cannot be in any closure (`test.cr:138-140`, `243-257`), or when a named file is missing (`test.cr:153`). A test whose own source does not parse is selected on its own (`test.cr:158`, `261-262`), and an import that does not parse stays in the closure by path (`test.cr:263-266`). Reuse evaluates inside selection. Unselected tests are never reported as passed and never touched in store.
* **Failures/timeouts/signals:** Every non-pass exit (fail, signal death, timeout kill, reserved status, build failure) revokes every receipt of that test that validates now, regardless of trace state.
* **Interrupt:** Sent to `iyi test` itself: child tree killed (via process group on POSIX, job object on Windows, `src/compiler/iyi/command/test.cr:377-380`, `416`), no receipt written for active test, existing receipts left intact, nothing revoked, exits 130.
* **`--shard K/N`:** Deals tests round-robin; snapshots unioned only across shards of the same producer run; duplicate test across shards refused.
* **MCP:** `test` tool gains optional `cached` parameter (`src/compiler/iyi/command/mcp.cr:179`, `221`).
* **Crystal mode:** `iyi test` rejects `--crystal` as a direct CLI option (`src/compiler/iyi/command/test.cr:76-80`), so Crystal mode reaches `iyi test` only through `IYI_OPTS="--crystal"` (`src/compiler/iyi/command.cr:992`, `1565`). Tests always run fresh with reason `Crystal library effects are not classified` (SPEC.md V.9 (e)).
* **Crystal spec aggregate:** `./bin/crystal spec` is unchanged. If ever covered, unit is whole generated program (`src/compiler/iyi/command/spec.cr:98-115`).

## 10. Proof gates

| Gate | Proves | Blocks | Until green |
|---|---|---|---|
| RG1 | Compilers with equal build-input digests produce byte-identical test executables for corpus | Hits across commits | Executable SHA-256 stays in identity |
| RG2 | Normal and `-Diyi_observe` builds give equal exit status, stdout and stderr | Shipping `--cached` | Shipping waits |
| RG3 | Zero unclassified runtime sites reachable from corpus on target; report lists every runtime def returning values derived from internal defs | Enabling platform CI | Platform runs fresh |
| RG4 | Links byte-identical under randomized variables outside `CHILD_ENV` | Treating `CHILD_ENV` as whole link environment | Full link environment digested |
| RG5 | Runtime patched via `IYI_PATH` dropping each observer allows changed input to pass; gate catches it | Claiming kind is covered | Kind is not claimed |
| RG6 | Standing shadow audit catches unannotated leaks or disagreements | Keeping consumption enabled after disagreement | Consumption disabled until fix (publishes empty snapshot) |
| RG7 | Different `--threads` produce identical executables | Leaving `n_threads` out of behavior key | `n_threads` stays in key |

## 11. Phases and slices

| Slice | Files | Change | Out of scope | Done when |
|---|---|---|---|---|
| S1 (P1) | `src/crystal/digest/sha256.cr`, `src/compiler/iyi/stale/encoding.cr`, specs | FIPS 180-4 SHA-256, canonical encoding | Replacing MD5 in `UpToDate`, OpenSSL | Matches FIPS vectors, agrees with `std/digest` across blocks |
| S2 (P1) | `Makefile`, `Makefile.win`, `src/compiler/iyi/config.cr`, `compiler.cr`, `stale/toolchain.cr`, `bench/stale_reproducible.sh` | Behavior key, toolchain digest, RG1 and RG7 gates | Changing `UpToDate.compiler_identity` | RG1 and RG7 pass |
| S4 (P1) | `src/compiler/iyi/semantic/effects.cr`, annotations in `src/iyi` and `src/std`, `bench/stale_effects.sh` | `@[Effect]` typing, static closure check, RG3 gate | Program-level effect inference | RG3 clean on target |
| S3 (P2) | `build_inputs.cr`, `stale/compile_record.cr`, `command.cr` | BuildInputs SHA-256, env enumeration, roots, location macro | Runtime observation | G1 through G9 closed |
| S5 (P2) | `src/iyi/observe.iyi`, wrapper generation, `stale/trace.cr`, `bench/stale_equivalence.sh` | Observer injection, runtime trace channel, RG2 and RG5 gates | User-space tracing | RG2 and RG5 pass |
| S6 (P3) | `command/test.cr`, `stale/store.cr`, `cache_dir.cr`, `mcp.cr`, `bench/stale_tests.sh`, workflows | Receipt storage, atomic files, lookup, revocation, CLI flags; S6 adds `tests-v1` to `NOT_BUILDS` (`cache_dir.cr:261`) | Remote cache | §12 local rows green |
| S7 (P3) | `src/compiler/iyi/macros/macros.cr`, `methods.cr` | Macro run programs built with `-Diyi_observe` | External build tools | Macro runs recorded |
| S8 (P3) | `src/compiler/iyi/stale/snapshot.cr` | Portable snapshot export and import, CI attestation check | Cross-repo sharing | Snapshot validation passes |
| S9 (P4) | `.github/workflows/iyi.yml`, `bench/stale_ci.sh`, `bench/stale_census.sh` | Master index publishing, `stale-fresh` job, shadow audit | Third-party CI | CI steps green |
| S10 (P5) | `SPEC.md`, `CHANGELOG.md`, `README.md` | SPEC test row, census and overhead documentation | Unmeasured claims | `bench/doc_numbers.py` passes |

Out of scope overall: per-case (`test "name"`) reuse, classifying Crystal library, caching failures, non-host targets, remote cache service, migrating bench drivers to `iyi test`, changing up-to-date check behavior, default-on reuse, adversarial tests, LSP.

## 12. Acceptance and falsification

Automated in `bench/stale_tests.sh` unless marked CI:
1. Nothing changed, fresh state, snapshot imported: every receipt hits and nothing is built.
2. Body edit in imported module leaving interface alone reruns tests reading it; other tests hit.
3. New file at import candidate recorded absent: test reruns with explanation naming file.
4. New entry in compile-listed or run-listed directory reruns test; unrelated directory hits. Directory listings preserve returned order.
5. Env branch: `MODE=a` reads `a.txt`. Changing `b.txt` hits; changing `a.txt` reruns; setting `MODE=b` reruns and records second receipt; restoring `MODE=a` hits from first receipt.
6. Unset variable set to `""` reruns. Changing outer variable written by test before read hits. Enumeration (`env_all`) plus added variable reruns. Enumeration plus changed variable value reruns.
7. `IYI_OPTS=--release` reruns; adding `--json` or `--explain` hits.
8. Edited prelude or std module reruns every test compiling it.
9. Compiler rebuilt from changed sources misses everywhere. Compiler rebuilt from identical sources hits once RG1 is green.
10. Clock, entropy, sleep, socket, subprocess, signal handler and GC pause accessor each cause test to run, naming def. Accessor returning core count (`IyiWorkers.resolved`) runs with `not reusable`.
11. Temp file under scratch directory (`TMPDIR`/`TEMP`/`TMP`) stays reusable; reads under scratch or of self-written files stay internal. Write outside scratch, or through descriptor not observed opened, runs with `shared-write`.
12. Program `asm`, `lib` binding, integer-to-pointer conversion, or internal def call runs with `FILE:LINE`.
13. Failing test never served from receipt. Fixed test reruns, passes and records.
14. Revocation: `--fresh` run forced to fail through input hidden by patched runtime contradicts receipt; next `--cached` run reruns (matching by state).
15. Non-pass exit (failure, signal, timeout kill, build failure) writes no receipt and revokes every receipt of that test that validates now, regardless of trace state.
16. Interrupt sent to `iyi test` itself: finished tests keep receipts; nothing revoked; active test writes nothing.
17. Closed trace channel or missing END: interrupted, no receipt.
18. Filtered runs and `--affected` touch only selected tests; excluded tests reported skipped, never passed.
19. Union of `--shard k/3` snapshots from same producer run equals unsharded snapshot. Mixing shards across producer runs or duplicate tests across shards is rejected.
20. Snapshot with wrong namespace, target, version, duplicate test, or path outside roots is refused. Export outside CI producer attestation is refused.
21. Corrupt receipt becomes miss and is rewritten. Masks are never deleted as corrupt. Concurrent runs leave no torn receipts.
22. Crystal mode via `IYI_OPTS="--crystal"` always runs with reason. `./bin/crystal spec` output unchanged.
23. Workflow check: pull request stale jobs upload nothing across runs and persist no state; producer job has no secrets and export step environment contains no secrets or `github.token`.
24. (CI) `stale-fresh` reports all hits on push with matching compiler bytes. Shadow audit checks verdict and observation sets. Git-diff self-check catches validation bugs on tracked files. Planted hidden read with changed file between producer and audit fails shadow audit.
25. `Dir.cd` into subdirectory followed by relative file read resolves and records absolute path at open; modifying target file reruns test.
26. Mid-build file modification where file stamp at hashing time differs from first-look stamp refuses receipt and rebuilds on next run.

## 13. Measurements and completion

Census (`bench/stale_census.sh`) per platform over C2 (`samples/iyi/*.iyi`) and C3 (`bench/std_*_exercise.iyi` standalone):
* Records verdict, reusable or not, reason category and site.
* Categories: requested effect, opaque program construct, blind build, runner (trace incomplete, racy input), internal (unclassified runtime site, or internal effect reported as reason).

Overhead reported as measured with no thresholds and no promised speedup:
* Wall time of `--fresh` against default mode.
* Per-hit validation time.
* Trace and receipt bytes per program.

Completion requires all of:
1. Every §12 row automated and green on every enabled platform.
2. RG1 through RG7 each green, or claim withdrawn in SPEC.md.
3. Census with zero runner or internal reasons, and reusable programs on every enabled platform.
4. Consumption and audit run on master with zero disagreements since enablement.
5. SPEC.md recording census and overhead as measured.

If the census shows almost all real tests always running, work is not marked complete even if condition 3 holds. The distribution goes to Jason Waldrip and the default stays off.

## 14. Limits

* Flaky tests: bounded by contradiction detection and shadow audit.
* Deliberately adversarial test code.
* File writers that preserve size and mtime (`cp -p`, `tar`, `rsync -t`): A3's stat comparison cannot observe content modifications when size and mtime are preserved.
* Process limits or loader settings outside recorded profile properties.
* Per-case reuse within a test file.
* Non-host targets.
* Cached failures.
* Snapshot export is limited to CI producer context with valid workflow attestation.
* Local hits on CI receipts require identical checkout paths when location macros embed paths.
* Hits across commits wait on RG1.
* No speedup is promised.
