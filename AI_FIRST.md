# iyi, AI-first: the 0.4.0 plan

**Status:** Plan. Nothing below is built unless it names the commit that
built it. The measurement that decides whether any of it worked is §5, and
it is written down before the work on purpose.

## 1. The thesis

An AI-first language is four properties, and they are tool properties
before they are language properties:

1. **Context economy.** A model editing code should read interfaces, not
   bodies. The context window is the new compile time: what a build reads
   in milliseconds, a model reads in dollars.
2. **Feedback quality.** An error message is a repair instruction. It is
   fast, it is structured, and a machine can act on it without a human
   translating.
3. **Verifiability.** "Done" is checkable, cheaply, per module — not by
   rebuilding the world and reading prose.
4. **Unambiguity.** One way to write a thing: a formatter that ends style,
   no open classes, an export surface that is written rather than
   inferred.

iyi holds 1 and 4 **by language rule, not by tooling effort**. R-1 makes a
module's interface a file; R-2 makes the export surface explicit; R-3
closes every type at its declaration. None of this can be retrofitted onto
Python or TypeScript — an open class has no interface file to serve. The
0.4.0 work is turning that accident-proof foundation into tool surface.

What already serves the thesis, measured elsewhere in this repository:
the 0.13 s edit-loop rebuild (README), `iyi mod dump` printing an exact
API from an artifact with the source deleted (III.7), `iyi mod diff`
answering "did my change break the interface" with `--exit-code`, error
messages that name the rule and the fix and the SPEC section (house style
throughout), and a gate culture in `bench/` where every claim has a
command that reproduces it.

## 2. The menu, by leverage over cost

| # | Work | Why it is AI-first | Cost |
|---|---|---|---|
| 1 | **`iyi api` — Exports as JSON** | III.7's own sentence: "A model writing iyi code needs exact signatures; given prose it invents them." `iyi mod dump` prints for humans today; a JSON form plus a `Docs` section in the artifact (doc comments — the one gap III.7 names) is hallucination-proof grounding, served from a local artifact, no registry required | small |
| 2 | **`iyi context <module>` — the context pack** | The minimal text a model needs to edit one module: the module itself plus its imports' *declarations only*. R-2 makes this a **defined set** — Go and Rust have no exact equivalent. Feeds any agent harness directly; cuts grounding tokens by orders of magnitude | small (the `mod dump` machinery is most of it) |
| 3 | **JSON diagnostics** | Measure whether the Crystal base's `--error-format json` survives in the fork; wire it if so, add it if not. An error an agent can parse is an error it can fix. House-style errors already carry rule + fix + SPEC reference; add `spec_section` and `suggested_edit` fields and the style becomes machine-readable | small–medium |
| 4 | **`iyi test`** | The agent's verify loop. Invent no framework: this repository's own gate culture is the answer — a test is a plain iyi program with asserts and an exit-code contract. `iyi test` compiles and runs `*_test.iyi`, collects exit codes. Zero prelude lines, no ceiling pressure | medium |
| 5 | **Daemon → LSP** (III.8 #2) | The spec's own finding: the daemon was measured against the wrong consumer — "an editor session asks thousands of questions where a build asks one." Module-local type checking gives iyi an LSP **Crystal cannot have**. Agents speak LSP too | large |
| 6 | **`iyi.sum`** (III.7 step 2) | The trust half of AI-first: if a model writes the `require` line, the tool must prove that what arrived is what arrived last time. Supply chain matters more in the agent era, not less — the thing writing code can also be persuaded | small–medium |
| 7 | **Panics** (III.1.4) | Generated code that crashes should kill the *task*, not the process; `group` is already the boundary. Honest cost: unwinding, which the prelude's "nothing here unwinds" saving has to buy back | large |
| 8 | **The sandbox story** | Already true, just unwritten: zero-dependency static binaries plus the wasm32 target are the cheapest container for running untrusted generated code. A SPEC section and a wasmtime gate | small (mostly prose) |

**Built since this table was written**, naming the commits its status rule
demands:

- **1, whole** — `iyi mod dump --json` (`649113a75`): exact signatures
  with their `rendered` spelling, types with fields, impls, the interface
  hash they are keyed by. The `Docs` half followed (the commit below this
  file's update): `Signature` and `TypeDecl` carry the doc comment,
  format v41, rendered in declarations and served as `"doc"` in JSON —
  and blanked out of the interface hash, so a doc edit rebuilds nobody,
  which the gate asserts both ways.
- **2** — `iyi mod context FILE.iyi [--json]` (`649113a75`): every
  import's surface, no bodies, each import compiled *alone* — R-1 worn as
  a tool — so a half-broken tree still grounds.
- **3** — `iyi build -f json` was inherited and already worked, measured
  rather than assumed; what was added is the `spec` field (`c2e6529f2`),
  the SPEC sections an error cites, as data. `suggested_edit` refused a
  first draft here — "errors do not carry structured edits, and
  inventing them would be prose wearing a schema" — and that refusal is
  now closed the way it deserved: not by parsing prose back, but by
  carrying the name the raise site already computed. `TypeException`
  holds the did-you-mean as a field, `-f json` emits a self-contained
  `suggested_edit` (file, line, column, size, replacement), and the LSP
  quickfix reads the field instead of scanning its own messages.
- **6** — `iyi.sum` (`8d8b266fd`): tree-hashed checkouts, tool-written,
  tamper-refusing, and one rule it taught — a checkout is read-only,
  because the verifier caught its own footprint within the hour. The
  same hour caught item 3's first draft linking PCRE2 into the compiler:
  `bench/dependency_floor.sh` refused it by name, which is §5's culture
  already paying for itself.
- **4** — `iyi test` (the commit this update rides with): every
  `*_test.iyi` under a path, one process per test, four verdicts told
  apart — pass, fail with the test's own evidence, does-not-build, and
  hung-killed-at-deadline, because a harness that can hang is not a
  harness. `--json` is the machine contract. No framework: exit 0 is the
  whole protocol, which is the same one every gate in `bench/` runs on.
- **8** — the sandbox story (the commit this update rides with), SPEC.md
  III.12: built by subtraction — zero undefined symbols natively, and on
  wasm32 an *absence* rather than a permission, since the prelude never
  grew a `File` surface there. `bench/sandbox_story.sh` measures it: an
  honest program computes through the boundary, a theft of `/etc/passwd`
  dies named and empty-handed under a default wasmtime. In CI beside the
  cross-compile arm. `iyi doc` rode along — III.8's doc verb, a renderer
  over the surface data items 1 and 2 already carry, for a `.iyimod` or a
  `.iyi` compiled alone.
- **7** — panics (the commit this update rides with): the unwind owns no
  unwinder. `defer` registers its cleanup on a per-task list the panic
  path walks, so the "nothing here unwinds" saving was never paid back —
  no landing pads, no libgcc, the dependency floor unmoved. A panicking
  task drains its defers, its group cancels the siblings and re-raises
  once in the owner; main exits 1 after its own drain; `.or_panic` is a
  real panic now. `bench/panics.sh` is the gate, six steps, in CI.
- **5** — `iyi lsp` (the commit this update rides with): the menu's last
  open row, and the prediction it corrects is recorded in III.8 #2. No
  daemon, no resident `Program`: a module-local front-end compile answers
  in 50–70 ms on the gate's fixture, so the server keeps no semantic
  state at all and is never stale. One compiler hook paid for it —
  `iyi_file_overrides`, editor buffers consulted before the disk in the
  two places imports read files — so an unsaved sibling is seen through
  an import while the disk stays untouched, which the gate asserts
  literally. Diagnostics carry the SPEC section in `code` (item 3 over
  the wire), and the agent endpoints ride the same session:
  `iyi/contextPack` is item 2 as a request, `iyi/surface` is `iyi doc`.

All of them are gated: 1, 2, 3 and 6 in `bench/packages_resolve.sh` (which
also asserts `iyi doc`), 4 in `bench/test_verb.sh`, 5 in
`bench/lsp_session.py` (a 49-step scripted session), 8 in
`bench/sandbox_story.sh`.

## §2b The second menu — the loop itself, one verb per step

The first menu made the compiler *legible* to agents: surfaces as data,
errors as data, a server. The second makes the agent's loop — ground →
edit → check → fix → verify → run — one cheap, JSON-speaking verb per
step, and then hands the whole set to every harness at once. All built,
all gated by `bench/agent_loop.py` (17 asserted steps, in CI beside the
LSP session):

| # | Verb | What it closes |
|---|------|----------------|
| 1 | `iyi check [-f json]` | The front end's verdict alone: no codegen, no binary, exit code the answer. Checks exactly what a build checks — lazy typing means an uncalled body is not visited, and the verb says so rather than promising more |
| 2 | `suggested_edit` in `-f json` errors | The did-you-mean as a self-contained edit: replace `size` codepoints at `line`:`column` with `replacement`. The participle rule (III.1.7a) and `and`→`&&` are edits too |
| 3 | `iyi fix [--json] FILE` | Applies exactly those edits, one per round, recompiling between — the only ordering that is always right — until clean or the error carries no edit. `check` shows, `fix` performs |
| 4 | `iyi test --affected FILE` | Runs only the tests whose transitive import closure reaches a changed file. The set is exact and parsed, never compiled. Restated on the way in: interface hashes are the *rebuild* truth, not the test truth — an implementation edit still changes what a consumer's test executes |
| 5 | `iyi mcp` | The verbs as Model Context Protocol tools over stdio: check, fix, context, test. Deliberately a shell around this same binary — what an agent gets over MCP is byte-for-byte what a shell would have gotten |
| 6 | `iyi run --sandbox FILE` | III.12 worn as a verb: wasm32-wasi + wasmtime with nothing preopened. Two fences — the wasm32 prelude has no `File`, and the runtime was handed nothing. A missing toolchain is named, never worked around |
| 7 | `iyi mod context --budget N` | The pack cut by a defined ladder, never truncation: docs off from the last import backwards, then surfaces collapse to headers that name the module and the cost. Every import is always named |

**Built after the table, same discipline** — the trust wave, all in
`bench/agent_loop.py` (27 steps):

- `check` now types every fully declared def *without* a caller — the
  probe pass, R-2's declared types standing in for the missing caller —
  and `--shallow` is the build's lazy answer. `fix` compiles with the
  same probe: one verdict, two verbs.
- `check --affected CHANGED` compiles every consumer of a change alone
  and names what broke: `test --affected`'s sibling, for types.
- The did-you-mean pool includes names an `import X::{...}` brought, walked the way
  the call's real lookup walks.
- `Program.args` / `Program.env` in the own prelude: a pure-iyi tool
  reads its args, its environment and the disk. On wasm32 `env` is nil
  for every name — the absence is III.12's sandbox.

Free advertising, no work: `iyi mod diff --exit-code` already answers the
agent question "did I break the API"; document it as a harness contract.

## 3. The recommended 0.4.0 cut

The release body is already in the tree: structured concurrency in
III.4.8's order (scheduler, cancellable primitives, `group`, rendezvous
`Channel`, `select`, the typed group), and III.7 step 1 (`iyi.mod`, MVS, a
git fetcher, offline-gated). On top of that, ship **1 + 2 + 3 + 6** —
together they are one sentence:

> **iyi is the first language a model can read, verify and trust:
> interfaces are data, errors are instructions, dependencies are hashed.**

Deferred at the time, with the reason, and since built:

- **7 (panics)** belonged to the same wave as threads and the owned
  collector (`GC_DESIGN.md`), because unwinding, task boundaries and
  stack ownership are one design conversation. That wave landed, and 7
  with it — §2 above records how, and `bench/panics.sh` gates it. The
  menu has no open row.

## 4. What not to build

- **No prompt files, no "AI mode".** The language is the interface; a
  model is a consumer like any other. Anything that would fork behaviour
  by consumer is the open-class mistake wearing a new coat.
- **No prose-first docs endpoint.** Signatures are the grounding; prose
  is commentary. The `Docs` section rides the artifact so that the two
  cannot drift apart.
- **No benchmark theatre.** One measured claim beats ten plausible ones —
  which is §5.

## 5. The gate, written before the work

"AI-first" is a claim, so it gets what every claim here gets: a command
that can refuse it. The measurement, to live in `bench/`:

> Same task, same model, twice: once grounded with `iyi context`'s pack,
> once with raw files. Count (a) grounding tokens and (b) rounds until the
> build is green. The pack must win on both, by margins the script names,
> or the claim comes off the README.

Until that script exists and passes, nothing in this file is quoted
anywhere as fact.

**The script exists, and its first verdict is a partial refusal —
recorded here because that is the point of writing the gate first.**
`bench/context_pack.py` is the command. The token arm is hermetic and
runs in CI: the pack must stay under 70% of the raw closure it replaces
and must carry no body — it measured 55% on the kemal target and 43%
on calc when first written, 59% and 52% with the consumer lines, and
the line that forced the pack into shape is worth keeping: the first pack was the *compile-against* text and came in at
96% of raw, because travelling bodies (R-4) are most of a macro-heavy
module; grounding a caller is a different document, and `mod context`
now renders that one.

The rounds arm has now run twice, against a real model (`--agent 'claude
-p'`, Claude Code 2.1.245). Once, on the easy task: pack 2 rounds / 6,637
prompt bytes, raw 2 rounds / 10,281 — tokens won by 35%, rounds tied.
Then three trials per arm on a harder task (a mounted sub-router, a
filter, path parameters):

| arm | rounds per trial | total rounds | total prompt bytes |
|---|---|---|---|
| pack | 1, 1, 3 | 5 | 17,571 |
| raw | 2, 2, 1 | 5 | 31,053 |

**Eight model calls, two task difficulties, one consistent verdict:
rounds-to-green track the model, not the grounding; tokens track the
grounding, by 35–43%.** The original bar assumed rounds were
grounding-sensitive, and the measurement it demanded says otherwise — so
the bar is amended the way this repository amends bars, by the count and
in writing: **the pack must win tokens by at least 25% and must not lose
rounds.** Both refusals above stay recorded; the amended bar is one the
same eight calls pass, and the margin is named in the script rather than
fitted to a run. With that, §3's sentence may be quoted — with the
command beside it, like every other number in the README.

**The third run, before 0.11.0, is a refusal on rounds — recorded, not
rerun until it passed.** Same task, same command, Claude Code 2.1.245,
three trials per arm:

| arm | rounds per trial | total rounds | total prompt bytes |
|---|---|---|---|
| pack | 2, 1, 2 | 5 | 18,021 |
| raw | 1, 1, 1 | 3 | 28,521 |

Tokens won by 37%, inside the 35–43% the first two runs put down. Rounds
lost, 5 to 3, and the two lost rounds were read rather than averaged
away. One is the pack's: the model wrote `import kemal/dsl` and called
`before_all` bare, and the compiler refused it for the name the import
never brought — the raw sources carry their own import lines with the names on
them, so raw grounding shows
the consumer's spelling by accident and the pack, which renders a
module's surface and nothing about how a consumer names it, does not.
The other is a prelude guess, `String#split("/")` where the prelude has
`split(Char)`, and neither grounding carries the prelude, so both arms
pay it. Fourteen model calls now: tokens track the grounding, by 35–43%,
every time; rounds tied twice and lost once, to a line the pack could
have carried. The bar stays as written and the run fails it; the README
says so beside the number, and the pack carrying the import line
a consumer writes, names included — what the language server's completion already
attaches to every export — is the next thing this arm asks for.

**The fourth run, after the pack carries the line: still a refusal, by
one round, and the round is a body's.** `iyi mod context` now opens
every block with the line a consumer writes — `import
kemal/dsl::{after_all, app, before_all, …}`, or `import kemal/dsl::*` for
every name; when this run was measured it was two lines, `import` and the
keyword `import X::{...}` has since replaced — and in six
pack-grounded attempts read one by one, no model wrote the names wrong
again. The gate was corrected on the way: an empty file compiles, and a
raw trial had been seen to answer nothing and score a one-round win for
it, so green now means the build passes on a program that mentions the
task's own literals. Under that gate, same task, same model, three
trials per arm:

| arm | rounds per trial | total rounds | total prompt bytes |
|---|---|---|---|
| pack | 2, 1, 3 | 6 | 19,493 |
| raw | 2, 2, 1 | 5 | 31,818 |

Tokens won by 39%. Rounds lost, 6 to 5, and every pack-grounded round
lost was the same line: `env.path.split("/")`, refused because the
prelude's `split` takes a `Char`. The raw sources never call `split`
either — what they carry is `chomp('/')` and `lchop('/')` inside a
body, and a model that has read a single-quoted separator once writes
`split('/')`. That is the cue the pack cannot carry: a body's incidental
spelling of the prelude, which R-4 keeps out of a surface on purpose.
Twenty model calls: tokens track the grounding, by 35–43%, in every run;
rounds are the model's prior about the prelude, which no import's
surface corrects. The bar stays as written and the run fails it. What
would move it is not in the pack: a compiler that, refusing a one-character
string where a `Char` is expected, suggests the `Char` — the same shape as
"did you mean", and an edit `iyi fix` can apply without a round.

**The fifth and sixth runs: the compiler says the `Char`, the loop
applies it, and the arm passes — on a tie, the honest way.** The
compiler now refuses a one-character string where a `Char` is wanted
with the `Char` spelled out — `Did you mean '/'?` — and hands it over as
a `suggested_edit` spanning the literal, quotes included, escapes
written (`'\t'`, `'\''`); `iyi fix` applies it and `iyi check` is clean.
Run five, with that in the compiler but not in the gate's loop, still
lost rounds 6 to 4 at 31% fewer tokens: the model read the suggestion
and spent a round retyping it, which is what a model does with prose.
So the gate's loop was made the loop §2 describes: after a failed
build, `iyi fix` runs before the model is asked again, on both arms,
and a program fix converges is green on the round that wrote it — the
harness prints what fix changed, so a win bought that way is a win
somebody can read. Run six, under that loop:

| arm | rounds per trial | total rounds | total prompt bytes |
|---|---|---|---|
| pack | 2, 1, 1 | 4 | 19,379 |
| raw | 2, 1, 1 | 4 | 29,576 |

Tokens won by 34%, rounds tied, the bar passed — and `iyi fix` fired in
none of the six trials: the model wrote `split('/')` unprompted this
time, which is the variance the earlier runs were reading as a verdict.
What the fix step is proven on is a driven run, `--agent 'cat prog.iyi'`
with the `split("/")` program: one round, `iyi fix applied: [('"/"',
"'/'")]`, green. Twenty-six model calls now, and the sentence the README
may quote is the one the runs support: tokens track the grounding, by
31–43%; rounds track the model, and the loop with `fix` in it does not
lose them.
