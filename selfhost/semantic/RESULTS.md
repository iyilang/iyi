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

Measured on `8ff62d884` (the gate code is identical at `a51a81501`). Each row is one variant run over a **35-file subset** of the 168-file corpus, not the full corpus: the 10 std files that the head differs on or whose rules the mutants touch (`format json math bzip2 static_array random reference_storage hpke float file`), all 20 prelude files, and 5 samples (`derive hello modules calc std_text`). The verdict per file is `diff.sh`'s rule: empty oracle answer is NO ORACLE, otherwise port stdout must equal oracle stdout byte for byte.

```
BASELINE (head oracle vs head port, mutation harness)
  std      n= 10 agree 7, differ 3, no oracle 0
  prelude  n= 20 agree 16, differ 1, no oracle 3
  samples  n=  5 agree 4, differ 0, no oracle 1
  total    n= 35 agree 27, differ 4, no oracle 4

MUTATIONS (verdict changed against the head baseline)
m1 (port): agree 26, differ 5, no oracle 4; 1 file(s) changed verdict
    std/random.iyi: AGREE -> DIFFER
m2 (port): agree 27, differ 4, no oracle 4; 0 file(s) changed verdict
m3 (port): agree 26, differ 5, no oracle 4; 1 file(s) changed verdict
    samples/derive.iyi: AGREE -> DIFFER
m4 (port): agree 26, differ 5, no oracle 4; 1 file(s) changed verdict
    std/reference_storage.iyi: AGREE -> DIFFER
m5 (port): agree 26, differ 5, no oracle 4; 1 file(s) changed verdict
    prelude/float.iyi: AGREE -> DIFFER
m6 (port): agree 26, differ 5, no oracle 4; 1 file(s) changed verdict
    std/hpke.iyi: AGREE -> DIFFER
m7 (port): agree 21, differ 10, no oracle 4; 6 file(s) changed verdict
    std/bzip2.iyi: AGREE -> DIFFER
    std/static_array.iyi: AGREE -> DIFFER
    std/random.iyi: AGREE -> DIFFER
    std/hpke.iyi: AGREE -> DIFFER
    std/float.iyi: AGREE -> DIFFER
    std/file.iyi: AGREE -> DIFFER
o8 (oracle): agree 21, differ 7, no oracle 7; 7 file(s) changed verdict
    std/math.iyi: DIFFER -> NO ORACLE
    std/bzip2.iyi: AGREE -> NO ORACLE
    std/static_array.iyi: AGREE -> DIFFER
    std/random.iyi: AGREE -> DIFFER
    std/hpke.iyi: AGREE -> NO ORACLE
    std/float.iyi: AGREE -> DIFFER
    std/file.iyi: AGREE -> DIFFER
o9 (oracle): agree 23, differ 4, no oracle 8; 4 file(s) changed verdict
    samples/derive.iyi: AGREE -> NO ORACLE
    samples/hello.iyi: AGREE -> NO ORACLE
    samples/modules.iyi: AGREE -> NO ORACLE
    samples/calc.iyi: AGREE -> NO ORACLE
```

A row lists each file whose verdict changed against the head baseline. The `m2` mutant changed no verdict on this subset, so this subset does not catch it: it was built and run, and that is recorded, not omitted.

Mutants: `m1`..`m7` are port mutations of `declare.iyi` (`m7` restores the header-import rule, `first_segment` and `opens_own_module?` from `0f01c3bed^`, with the module body guarded by it); `o8` makes the oracle walk only types located in the file, `o9` makes any directory named `iyi` the prelude. Their sources are not committed: they were scratch copies, now outside the checkout.

### First differing line per DIFFER or NO ORACLE file (head)

```
DIFFER src/std/format.iyi: first differing line 1 of oracle output:
    oracle: (class IyiBig (defs div_small to_decimal)) (class String (defs %)) (const IyiFloatText::MAX_PLACES (defs )) (module IyiFloatText (defs )) (module IyiFormat (defs )) (modu
    port:   (class IyiBig (defs div_small to_decimal)) (class String (defs %)) (const IyiFloatText::MAX_PLACES (defs )) (module IyiFormat (defs )) (module Std (defs )) (module Std::F
DIFFER src/std/json.iyi: first differing line 1 of oracle output:
    oracle: (aliastype Std::Json::Any::Type (defs )) (annotationtype Std::Json::JSON::Field (defs )) (class Object (defs __json_write)) (class Std::Json::Builder (defs array before_v
    port:   (aliastype Std::Json::Any::Type (defs )) (class Object (defs __json_write)) (class Std::Json::Builder (defs array before_value bool empty? end_array end_object field inde
DIFFER src/std/math.iyi: first differing line 1 of oracle output:
    oracle: (const Std::Math::Math::ACOSH_CL2 (defs )) (const Std::Math::Math::ACOSH_CL3 (defs )) (const Std::Math::Math::ACOSH_CL4 (defs )) (const Std::Math::Math::ACOSH_CL9 (defs )
    port:   (const Std::Math::Math::E (defs )) (const Std::Math::Math::LOG10 (defs )) (const Std::Math::Math::LOG2 (defs )) (const Std::Math::Math::PI (defs )) (const Std::Math::Math
NO ORACLE src/iyi/chaos_points.iyi: oracle says: compiler: the top-level pass declares no type in this file
NO ORACLE src/iyi/chaos.iyi: oracle says: compiler: the top-level pass declares no type in this file
DIFFER src/iyi/primitives.iyi: first differing line 1 of oracle output:
    oracle: (booltype Bool (defs )) (chartype Char (defs + hash ord)) (class Object (defs class crystal_type_id)) (class Reference (defs == hash initialize object_id)) (metaclasstype
    port:   (booltype Bool (defs )) (chartype Char (defs + hash ord)) (class Object (defs class crystal_type_id)) (class Reference (defs == hash initialize object_id)) (metaclasstype
NO ORACLE src/iyi/thread.iyi: oracle says: compiler: the top-level pass declares no type in this file
NO ORACLE samples/iyi/std_text.iyi: oracle says: compiler: the top-level pass declares no type in this file
```
