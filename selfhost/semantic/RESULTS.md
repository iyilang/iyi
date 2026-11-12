# Declaration pass: measured results

Head measured: `8ff62d884` (formatting-only commit on top of `b74b451b8`).
Compiler: `bin/iyi` 0.21.0, built from `c77beab00`. The compiler sources are unchanged across the merge into this branch.
Machine: 18 cores, load between 13 and 158 during the run (shared with other sessions).

## Correction to `b74b451b8`

The message of `b74b451b8` says the mutation checks were run in a final pass. They were not. No mutant was built or run before this file. The mutation table below was measured on `8ff62d884` and is the first measurement of it.

## Gates on `8ff62d884`

| gate | command | exit | summary |
|---|---|---|---|
| declaration pass, samples (CI invocation) | `bash selfhost/semantic/diff.sh` | 0 | agree 27, differ 0, no oracle 1 |
| declaration pass, std | `bash selfhost/semantic/diff.sh src/std/*.iyi` | 1 | agree 117, differ 3, no oracle 0 |
| declaration pass, prelude | `bash selfhost/semantic/diff.sh src/iyi/*.iyi` | 1 | agree 16, differ 1, no oracle 3 |
| inference | `bash selfhost/semantic/infer_diff.sh` | 0 | 4 fixtures agree |
| identity floor | `python3 bench/identity_floor.py` | 0 | `iyi owns its name` |

CI runs only the samples invocation of `diff.sh`. The std and prelude rows use the same script on the same files, so their exit status 1 reports real differences, not a CI failure.

Corpus sizes are the gate's own glob (direct children of each directory): std 120, prelude 20, samples 28, 168 in total. An earlier note said 124, 17 and 27; those figures do not match this head. One std file, `src/std/eiy/`, is in a subdirectory the gate does not read and is not measured here.

The samples row is the CI run; the gate's own output says `agree 27, differ 0, no oracle 1`, and its no-oracle file is `std_text.iyi`.

## Differing and no-oracle files

- `std/format.iyi` (differ): the oracle reports `module IyiFloatText`, which `format.iyi` reopens with only `self.` methods. The port reports `module IyiFormat` and omits `IyiFloatText`. Reopened modules are not handled by `Declarations.at`.
- `std/json.iyi` (differ): the oracle reports `annotationtype Std::Json::JSON::Field`, which the port omits. The earlier analysis points at the parser: an `annotation` declaration produces an `AnnotationDefNode` with no name. Not re-verified on this head.
- `std/math.iyi` (differ): the port and the oracle list different sets of constants. The earlier analysis points at the parser, which drops `private NAME = ...` assignments. Its minimal snippet was verified earlier: `pub struct PV` containing `private SIN_T = 5`, where the oracle reports `const PV::SIN_T` and the port does not. Not re-verified on this head.
- `prelude/primitives.iyi` (differ): the first differing entries are in the `Reference` and `Pointer` region. The earlier analysis says the oracle gives `Pointer` a default `initialize` that the port no longer generates. Not re-verified on this head; the per-file first differing line is in `firstdiff.txt` below.
- `prelude/chaos.iyi`, `prelude/chaos_points.iyi`, `prelude/thread.iyi`, `samples/std_text.iyi` (no oracle): the oracle's own refusal is `compiler: the top-level pass declares no type in this file`. That is a refusal, not an answer. `chaos.iyi` and `thread.iyi` contain `class`, `struct` and `lib` declarations, and `chaos_points.iyi` contains `struct Atomic(T)`, so the file does declare types. The cause is not isolated: it is a gap in the driver's handling of these files, not a property of the file. `thread.iyi` and `chaos.iyi` use `{% if flag?(...) %}` blocks, and the oracle compile sets no flags, but `chaos.iyi` declares its classes outside any flag block, so flags do not explain all four.

## Mutation table

PENDING. Phase B2 is running on a 35-file subset, and this section will be completed when it finishes.
