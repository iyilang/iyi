# Call lookup parity (slice S1c)

Status of the call lookup port (`method_lookup.iyi`, `match.iyi`, `restrictions.iyi`,
`call.iyi`, `call_error.iyi`, `default_arguments.iyi`) against the hosted call pass.
Measured on the pushed head by `bench/selfhost_semantic_calls_exercise.sh` and
`bench/selfhost_semantic_calls_census.sh`.

## Fixture parity (measured)

16 fixtures, 161 call sites: every `# call` line (the hosted lookup result), every
`# error` line (the first line of the hosted error, or `ok`) and every `# expand` line
(the argument list after default arguments are expanded) is byte-identical to the
hosted oracle. 28 guarded mutation proofs, each caught.

`# expand` lines: `DefaultArguments.expand` (positional and named arguments; a
parameter no argument reaches takes a copy of its default). The hosted oracle reads
the values from the hosted `expand_default_arguments` assignments. This fixture gate
still does not cover a magic-constant default or a splat: `supported?` answers false
for a splat or double splat, and `expand` refuses those calls. Positional splat
expansion and call-site magic defaults are proved by
`bench/selfhost_default_values_exercise.sh`, not by this oracle.

## Census over whole programs (measured)

`bench/selfhost_semantic_calls_census.sh` over the 45 whole-program entries
(`samples/iyi/*.iyi` and `src/compiler/tools/*.iyi`), run as
`CALLS_CENSUS_FILES=<list>`. Without the list the script walks every `src/compiler`
file, which is a survey, not the gate.

| Head | Entries loaded in the port | Sites reached | Typed by hosted | Identical |
|---|---|---|---|---|
| `494a4d338` (before the declarations trunk merge) | 17 | 729 | 567 | 331 |
| `2d522629b` (trunk `c3a301dae` merged) | 38 | 7,533 | 1,107 | 668 |

The floor was raised with `CALLS_CENSUS_RAISE=1` for every loaded entry. `basics.iyi`
rose from 79 to 80. `samples/iyi/generics.iyi` is at 19 against a floor of 20: a regression
from the hosted pass's generic implementers, which the port does not instantiate yet
(see the ranked gaps below). The floor is not lowered.

Still not loading: 29 entries (`src/compiler/tools/*` and some samples). The port
refuses or panics on them in the declarations pass (`can't implement Std::Enumerable,
it's a module`, `Compiler::Syntax::Lexer is not a class`, `undefined constant
valid_int_bits?`, `undefined constant ir_quote`, `undefined constant parse_operand`,
`can't find module 'compiler/syntax/ast'` on the typed-parity path). These belong to the
declarations slice.

## Typed parity on this slice's files (measured)

`bench/selfhost_typed_parity_exercise.sh` with `TYPED_PARITY_FILES` set to a list file
holding `method_lookup`, `restrictions`, `call`, `call_error`, `match` and
`default_arguments`: every file has 0 typed nodes matched. Their nodes are typed by the
bodies slice, which uses this lookup; the lookup is measured by the calls gate instead.

## Ranked gaps

1. **Generic implementers.** `impl Show for Box(T)`: the hosted trait dispatch lists
   `Box(Int32)`, `Box(String)`, and so on. The port refuses a generic implementer
   (`not ported: generic implementer`), which is the `generics.iyi` regression above.
2. **`==` and index calls** (`Object#==`, `[]`, `[]?`, `[]=`), the most frequent shapes
   in the port's source. Several prelude overloads are declared inside macro loops, which
   the declarations slice expands (`S1bInlineMacros`); until it lands these are not
   reachable.
3. **`super`** is ported for non-generic class owners and dynamic selves. Named refusals cover
   blocks, captured blocks, proc literals, calls with blocks, missing recorded owners, non-class
   or generic owners and selves, generic ancestors, and omitted defaults that forward.
   **`previous_def`** remains pending.
4. **`call_error.cr`**: protected calls, named-argument errors, and the suggestions in
   `suggestions.cr`. `restrictions_augmenter.cr` and the rest of `call.cr` follow.
5. **A restricted splat parameter** (`Array#push(*values : T)` with a restriction): the
   port refuses it; the hosted pass answers `none` for `# call`.
6. **Free variables** (`forall T`): the port refuses them; the hosted pass says
   `undefined constant T`.
7. **Known text differences:** the hosted pass prints a file's module as `Name:Module`
   and the port prints `Name` (a renderer gap in `ModuleType#to_s`, owned by the types
   slice).
8. **Default arguments:** this calls fixture gate still does not cover magic-constant
   defaults or splats. The default-values gate proves call-site `__LINE__`,
   `__END_LINE__`, `__FILE__` and `__DIR__` for positional omission, two calls of the
   same signature, a wrapper forced by a normal default, named in-order omission,
   supported out-of-order omission, explicit overrides, and a nested call whose
   coordinates stay in its own file. File and directory values are the emitted string
   constants; line and end-line values are the executable bytes. `pointerof(@c)` plus
   `puts` is not that proof: the native string object has a type-id header, so that
   pointer lands on the length field. Macro-generated calls are not original-source
   parity: `Location` is a flat filename and line, with no VirtualFile line-origin
   map, and this pass does not invent one. `Proc#call(*args : *T)` is still refused
   at lookup (`expected type, got *T`) before this expansion, so `lowglob_cvar_lazy`
   is not a consumer this base can prove. A primitive splat with no `*T` restriction
   does become an arity-specific target; lowering then refuses the missing receiver,
   not the splat.


## Entry points

- `CallRecalculation.recalculate` takes argument nodes and types literal arguments
  (the fixture seed).
- `CallRecalculation.recalculate_signature(rec_type, ts, signature, explicit)` takes a
  `CallSignature` of already-typed arguments and returns the same `CallTarget`. The
  bodies slice calls this one.
- `DefaultArguments.supported?(rec_def, args, named_args)` then
  `DefaultArguments.expand(rec_def, args, named_args) : Array(ASTNode)`: the argument
  list the expanded def is called with. The bodies slice calls these from `visit(Call)`.
