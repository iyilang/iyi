# The typed pipeline: status and refusal table

The typed pipeline takes one program from source to a native executable through the typed analysis
and the typed lowering, with no LLVM and no host tool. It is `compile_typed` in `compiler/compiler.iyi`
and the program assembly in `compiler/lower/program.iyi`, reached from `iyi-compile-native <program.iyi>
-o <exe> --pipeline typed [--prelude] [--probe-phase] [--keep-going] [--emit ir]`. The default pipeline is
still the codegen path; the integrator flips it.

Phases, in order: `parse`, `declarations`, `bodies`, `lower`, `verify`, `native`, `link`. With
`--probe-phase` each phase prints `[phase] X: start`, then `[phase] X: pass` when it passes. A refusal
prints `X: fail: <message>` and `reached: <last pass>` and writes no output.

`--keep-going` (probe only) switches the body typer to total mode before the bodies phase: a construct it
cannot type is recorded on its node with its reason, and typing goes on. After the bodies phase the tool prints
the refusal table below: the body refusals, then the lowering column, one `table:` line per row. Lowering of the
whole program still stops at its first refusal; the lowering column lowers each reached def alone.

The integration merge changes the hello root-driven floor from 810 reached, 737 typed clean, and 328 lowered clean
to 814, 742, and 243. The lowering count falls because a probe now counts as clean only when its own body finishes
and its function verifies. This one floor reduction is authorized for the integration merge. These are not census counts.

## Strict bootstrap checks

At `33f36d5da2` on macOS arm64, hosted `bin/iyi` builds the real
`src/compiler/stage1.iyi` command entry. Stage1 builds stage2 from that same
source, then stage2 builds stage3 with the same source and options. Stage2 and
stage3 are byte-identical, with SHA-256
`bd9afaae218eca641d78900411ef369864bb37e9d08289051babb2d60eefd7e5`.
Both self-built binaries have valid signatures and link only `libSystem.B.dylib`.

The self-built stage2 runs `samples/iyi/hello.iyi` with all six expected output
lines, empty stderr and exit 0. Stage1 builds the standalone parser, which
accepts hello and rejects incomplete syntax with exit 1. The hosted compiler
remains the default. A self-bootstrap on other hosts remains unproven.

At `16b2671a3`, LLVM-named C bindings lower through the typed intrinsic registry
rather than being imported as C symbols. Numeric, tuple-narrowing and intrinsic
fixtures compile through the stage1 command and match hosted output and exit
status. Unsupported intrinsic bindings fail during lowering and produce no
executable.

At `33f36d5da2`, the while-next fixture matches all five hosted functions and
the block-next/break fixture matches all six, including module-level IR.
Their native executables exit 30 and 57 with hosted-identical stdout and stderr.
Literal expansions retain their trees across flow retyping, keeping generated
temporaries stable; recursive retyping clears those trees' speculative bindings.

The pointer-forwarding and inline-annotation fixtures match hosted IR and return
42. The external-global access fixture matches hosted IR and returns 7. At
`1aabe425d`, all eight functions of the loop-carried-narrowing fixture and its
module-level IR match the hosted output.

At `7eb3c7c30`, both yielded-block generic fixtures compile with the real prelude
through linking and exit 0. Both failed on an unbound `U` in the preceding stage1.
At `d08d64739`, the generic-instance checks accept nullable unions and reject
incompatible members, and the IR builder passes 16 exact constant-fold checks
and 20 retained-instruction checks. The keyword-predicate fixture matches all
three hosted functions and its module-level IR.

At `c0f74685f`, the superclass fixture matches all 11 hosted functions and its
module-level IR, and its native executable exits 42 like hosted. Missing parent
methods and unsupported default forwarding remain named refusals. The exported
fun-definition fixture also matches all five functions and its module-level IR.
At `4e5e4b20a`, nil-left alternatives pass strict typing, match all five hosted
functions and exit 15. Parser compilation passes both the `super` call and
`string_pool || StringPool.new`, then stops with
`undefined method 'ident_start?' for Compiler::Syntax::Lexer.class`.

At the same revision, read-observed Nil storage fixes the three IR differences in
`lower_expansion_temps`, `lower_named_tuple` and `lower_tuple_literal`. The new
branch/loop/root and writer-block-read fixtures match hosted IR and exit 25 and 6.
Block-family pointer joins match all seven functions of `lower_union_consumers`
and all four of `lower_union_block_jumps`, including module-level IR. Their native
outputs are `ABCDEFG` and `HI`, both with status 0. All eight fixtures compile
through the source pipeline; real-prelude hello still runs equal to hosted and
the hosted-built stage1 links only libSystem.

At `de1d9ab55`, inherited methods resolve names in their defining scope, and
lowering reads each constant binding recorded by the analysis. The lexical-name
and shadowed-constant fixtures match all seven and nine hosted functions,
respectively, and both exit 7. The module-order fixture matches all five functions
and exits 6. All three also match module-level IR.

Top-level statements use their file's imports, and import-scope metadata emits
no instructions. The two-unit inherited-name program compiles through linking
and exits 7, equal to hosted. All 11 single-file regressions run equal to hosted;
real-prelude hello still exits 0 with identical output, and stage1 links only
libSystem. At that revision, the strict parser stopped in bodies at `expected type, got B`.
A real-prelude character-range probe reproduces that refusal at `72d1eac67`,
while the hosted build exits 7.

The omitted-fun-return, inline-macro-expansion and nested-body-scope regressions
compile, link and run natively. Their results match hosted execution: status 0,
`ABCDE\n` with status 0, and status 7 respectively. Each failed in the preceding
stage1. At `0e2157406`, stage1's only linked dylib is `libSystem.B.dylib`.

At `10df29874`, the union-consumer regression prints `ABCDEFG` with status 0,
and the program-allocator selection regression exits 3; both match hosted execution.
The declaration initializer is evaluated in value mode rather than storing an
undefined Nil value. At `04f93ac04`, all 14 normal-path defer fixtures match hosted
IR and execution, including a union result preserved across cleanup. The gate
rejects replacing the union's pointer phi with an aggregate phi.

At `90dc7e8cc`, an empty method evaluates both unused argument expressions in order
(`AB`, status 3). Class and struct constructors with empty two-argument initializers
each exit 7. All three results match hosted execution.

The census table below is an earlier diagnostic snapshot, separate from these
strict whole-program checks.


## What the table counts

- `defs-reached`: distinct instantiations the body typer started. The label is the receiver, the name and
  the argument types. A call clones the def, and the clone's node id is new every time; counting those ids
  counted one instantiation once per call site. The same instantiation reached again does not add a count.
- `defs-typed-clean`: those instantiations whose every clone has no refusal node under it.
- `root-refusals`: refusals on top-level code, outside any def.
- `refusal-sites`: distinct (node, reason) pairs. A node refused once per instantiation counts once.
- One row per refusal reason, largest count first: its count, the slice that owns it (`owner`, from
  `typed_owner` in `lower/program.iyi`), the reason's first line, and one example with its file and line
  and the def that holds it. `owner=unassigned` means no rule names the reason yet and the rule belongs in
  `typed_owner`.
 
Lowering per instantiation runs `lower_def_probe` (lower/lower.iyi) on each reached clone, alone, into one
 module. Its refusals are ranked as the body rows are, with the lowering's owner. An instantiation is lowered
 clean when every probe of that label succeeds. `defs-lowered-clean` counts those labels, not clones and not
 the lines of `.names`. A lowering refusal names its def, not a node, since the lowering carries no location
 yet. `.names` lists each clean function name once (`names.uniq` at the write). It used to repeat a name once
 per clean instance; the coverage comparison is on the set of names either way.

## Gate

`bench/selfhost_pipeline_exercise.sh` runs the tool with `--keep-going` on the three prelude roots and the
compiler's own tools, regenerates the block below (`SELFHOST_PIPELINE_RAISE=1`), fails when it is stale, and
holds `defs-reached`, `defs-typed-clean` and `defs-lowered-clean` per root against `bench/selfhost_pipeline_table.floor`.
All three may only rise, and the gate fails when one falls below its floor. The variation the earlier floors allowed for (identical builds gave reached 5218/5219/5218) came from the typer's node keys and is gone: `NodeMap` holds the nodes it is keyed by (integration `5e633ea4d`), and three runs of one build give byte-identical output. The phase floor is `bench/selfhost_pipeline.floor`.

The floor on 6fc731844 counts distinct instantiations, not clones. The rows it replaced (hello 601 375 194, parse 913 505 272, compile_native 2905 1839 1492) counted one instantiation once per call site. They are not a higher value of this measure. Of 62 labels a bodies merge no longer reaches under the lane's receiver, 50 moved off a bogus metaclass receiver (`Array(Some.class)#meth` and the same shape on `Pointer`). That move is a correction, not a loss, and it is not a reason to read the old number as ahead. 12 name and argument pairs are absent entirely; that remainder is a bodies regression (a splat restriction refused before the autocast retry), not a floor.

Merging inline macros a0a16fc2b drops 11 compile_native reached labels. They are not hosted functions (hosted-filtered reached stayed 348, 0 labels unmapped). The 11 are Array or Pointer of a metaclass (`Module.class`, `ObjectFile.class`) plus `Array(Int32)#count`. Hosted has 0 of those names and 12 methods on `Array(Compiler::Ir::Module::Module)`, the instance type. That drop is a correction. `Array(Compiler::Ir::Module::Module)#<<`, `#empty?`, and `#first` were already unreached before the merge.

## Headline: coverage against the hosted compiler

The number that says how far stage 1 is: which functions the hosted compiler emits for a root, and how many of them the
port lowers clean under the same name. The hosted list is the `define` names of `./bin/iyi build --no-debug --emit llvm-ir
-o <dir>/hosted <root>`. The port's list is `<output>.names`, written by the tool under `--keep-going` (one line per
distinct clean function name). `bench/pipeline_coverage.py <hosted.ll> <output>.names <root>` prints the line and the first missing names.

As measured on 2026-11-13 on `selfhost/s3-pipeline-wip` at 225a3f07d (the declarations trunk `d7ff41054` merged onto 61ffc5278; Class is a ClassType metaclass, builtin type ids in hosted order). The hosted IR is built by this checkout's `bin/iyi` from the same source. The port's names are as the call lowering names them: a class method by its class, `*Point::new`, as `call.iyi` passes `class_owner`. An instance-variable getter is not listed, since a call reads it in place (call.iyi 207).

- `hello`: hosted 698 functions; 73 match the port's clean list; 625 missing; 21 extra. (72 of 698 on 61ffc5278.)
- `compile_native` (as root): hosted 11,811 functions; 101 match; 11,710 missing; 43 extra. (100 of 11,772 on 61ffc5278. The hosted total moves with the compiler's own sources.)

The 625 missing names on hello, by the frontier: 378 not reached by the port; 58 `^Generic(T)` names (lowering core, `mangled_name`); 39 lowering-core refusals; 34 calls; 28 runtime shims; 24 bodies; 20 unassigned (no rule in `typed_owner`); 19 reached and lowered under another name; 13 declarations; 8 closures; 2 entry; 2 constant initialisers. On `compile_native`: 6,519 not reached; 4,869 `^Generic(T)`; 55 lowering core; 46 calls; 43 bodies; 38 closures; 36 shims; 35 unassigned; 32 lowered under another name; 20 constants; 15 declarations; 2 entry.

A class method the probe lowered can still be counted not-reached. `lower_def_probe` (lower.iyi) calls `target_def_fun` with the metaclass as `self_type` and no `class_owner`, so the function is emitted `*Owner.class#meth`. The table and the call lowering name it `*Owner::meth` (program.iyi, call.iyi `class_owner`). The lookup misses, and the clean function is left out of `.names`. The fix is in `lower_def_probe`, which lowering core owns.

The comparison is on exact `define` names. What is still counted as missing or extra and is not work:

- Generic instances. The hosted compiler names a method of a generic class with its owner's type parameters
  (`*Array(IyiSchedulerState)^Array(T)#grow:Nil`, 66 such defines in hello). The port's names carry no `^Generic(T)`
  segment at all (0 names with `^`). `mangled_name` (lower/fun.iyi, lowering core's) must add it. Until it does, every
  generic-class method is missing here.
- Extras that are over-reach, not naming. The body typer types and the lowering lowers defs the hosted compiler never
  reaches (`*Array(Int32)#each` is extra on hello; hosted hello has no `Array(Int32)`). Those are the typer's and are a
  real signal that the port lowers more than the program calls.
- Top-level prelude defs: the hosted compiler prefixes the file path (`*/abs/prelude.iyi::__iyi_say`); the script drops
  that file part on the hosted side so both sides compare on the def.

The gate does not check this line (the hosted build and the probe are too slow to run every gate); it is measured by hand
and recorded here.

The table below counts instances per call site (the typer had no instance cache on this head). Its reach counts are not
a measure of progress and are not a floor to chase; the coverage line above is.

## Owners and known exceptions

Program assembly (lower/program.iyi, this slice): the top-level code is named by the prelude (lower.iyi
`main_function_name`, as the hosted `abi_prefix` does): `__crystal_main` for a prelude-free program, `__iyi_main` with the
iyi prelude. The C `main` is emitted only when the root has no `fun main` of its own (fixture lower_fun_main). The
prelude-free name is checked by the gate. The prelude name is not: the prelude does not reach IR in the typed pipeline
yet (strict mode raises at main_visitor.iyi:214 on the prelude's macro control, concurrency.iyi:1557), so no fixture
can show it.

- Proc literals (`~procProc`, `~proc2Proc`, `~proc3Proc`): owner agent://S2a9Core (lowering core, closures).
- Runtime shims `__iyi_*`, `memcpy`, `memmove`, `memset`, `bzero`: owner agent://S2a9Core (landed on s2a-core as d6b6bdbb9).
- `~NAME:const_init` and the `STDOUT`/`STDERR` constants: owner agent://S2e6Globals. The port emits no `~STDOUT:const_init`
  or `~STDERR:const_init`, so a read of `STDOUT` refuses.
- Exception: a `@[ThreadLocal]` class variable (`IyiScheduler.class#state`) is lowered as a plain global, silently, on
  s2e-globals b2ef4c5b0. It is not counted as lowered clean until agent://S2e6Globals refuses or lowers it. Until then it
  is an exception here.
- Instance-variable getters (a def whose body is one instance variable) are read at the call (call.iyi 207, hosted
  call.cr 614) and are not listed as functions in the names. Their lowering still counts as clean.

## Table

<!-- table:begin: generated by bench/selfhost_pipeline_exercise.sh; do not edit by hand -->
```text
table: hello defs-reached=930 defs-typed-clean=930 root-refusals=0 refusal-sites=0
table: hello defs-lowered-clean=759 lowering-refusal-sites=0
table: parse defs-reached=4453 defs-typed-clean=4453 root-refusals=0 refusal-sites=0
table: parse defs-lowered-clean=3851 lowering-refusal-sites=0
table: compile_native defs-reached=34306 defs-typed-clean=34306 root-refusals=0 refusal-sites=0
table: compile_native defs-lowered-clean=30833 lowering-refusal-sites=39
table: compile_native lowering 18 owner=lowering core reason=lower: visit(loop back-edge preemption checks are not ported (hosted iyi_preempt_on?)) (hosted codegen.cr) is not ported yet example=IyiGroup#spawn_pooled
table: compile_native lowering 10 owner=lowering core reason=lower: visit(a call dispatched over (Array(Compiler::Semantic::TopLevel::Type) | Array(Compiler::Types::Types::GenericInstanceType)) with a block (hosted call.cr: codegen_dispatch)) (hosted codegen.cr) is not ported yet example=Compiler::Semantic::Restrictions::ArgRestriction.class#restrict_argument
table: compile_native lowering 4 owner=unassigned reason=BUG: ~procProc(Nil)^src/std/dir.iyi:198 already has a body (hosted External#dead) example=Std::Dir::Dir.class#children
table: compile_native lowering 3 owner=unassigned reason=BUG: ~procProc(Nil)^src/iyi/./concurrency.iyi:7304 already has a body (hosted External#dead) example=Compiler::Lower::Program#lowering_table
table: compile_native lowering 2 owner=bodies reason=BUG: pointerof argument x has no addressable slot example=Std::Digest::ValueBarrier.class#u64
table: compile_native lowering 2 owner=lowering core reason=lower: visit(yield with no block in scope (hosted codegen.cr: visit(Yield), a block of an enclosing block body)) (hosted codegen.cr) is not ported yet example=Std::Dir::Dir.class#glob
table: compile_native origin 3 owner=lowering core reason=*IyiGroup#pooled<IyiUnit, &Proc(Array(Compiler::Loader::ModuleInfo))>:IyiTask(Array(Compiler::Loader::ModuleInfo)) | lower: visit(loop back-edge preemption checks are not ported (hosted iyi_preempt_on?)) (hosted codegen.cr) is not ported yet example=IyiGroup#spawn_pooled
table: compile_native origin 3 owner=lowering core reason=*IyiGroup#pooled<IyiUnit, &Proc(Compiler::Lower::Program::TypedProgram)>:IyiTask(Compiler::Lower::Program::TypedProgram) | lower: visit(loop back-edge preemption checks are not ported (hosted iyi_preempt_on?)) (hosted codegen.cr) is not ported yet example=IyiGroup#spawn_pooled
table: compile_native origin 3 owner=lowering core reason=*IyiGroup#pooled<IyiUnit, &Proc(Nil)>:IyiTask(Nil) | lower: visit(loop back-edge preemption checks are not ported (hosted iyi_preempt_on?)) (hosted codegen.cr) is not ported yet example=IyiGroup#spawn_pooled
table: compile_native origin 3 owner=lowering core reason=*IyiGroup#pooled<IyiUnit, &Proc(Compiler::Ir::Module::Module)>:IyiTask(Compiler::Ir::Module::Module) | lower: visit(loop back-edge preemption checks are not ported (hosted iyi_preempt_on?)) (hosted codegen.cr) is not ported yet example=IyiGroup#spawn_pooled
table: compile_native origin 3 owner=lowering core reason=*IyiGroup#pooled<IyiUnit, &Proc(Compiler::Semantic::MainVisitor::MainVisitor)>:IyiTask(Compiler::Semantic::MainVisitor::MainVisitor) | lower: visit(loop back-edge preemption checks are not ported (hosted iyi_preempt_on?)) (hosted codegen.cr) is not ported yet example=IyiGroup#spawn_pooled
table: compile_native origin 3 owner=lowering core reason=*IyiGroup#pooled<IyiUnit, &Proc(Compiler::Codegen::Codegen::CodeGenVisitor)>:IyiTask(Compiler::Codegen::Codegen::CodeGenVisitor) | lower: visit(loop back-edge preemption checks are not ported (hosted iyi_preempt_on?)) (hosted codegen.cr) is not ported yet example=IyiGroup#spawn_pooled
table: compile_native origin 2 owner=lowering core reason=*Compiler::Semantic::Restrictions::ArgRestriction::restrict_union<Compiler::Types::TypeSystem::TypeSystem, Compiler::Semantic::TopLevel::ModuleType+, Compiler::Syntax::Ast::Union, Compiler::Types::Types::GenericInstanceType+, Compiler::Semantic::TopLevel::Type+, Array(String), Hash(String, Compiler::Semantic::TopLevel::Type+)>:Compiler::Semantic::Restrictions::RestrictResult | lower: visit(a call dispatched over (Array(Compiler::Semantic::TopLevel::Type) | Array(Compiler::Types::Types::GenericInstanceType)) with a block (hosted call.cr: codegen_dispatch)) (hosted codegen.cr) is not ported yet example=Compiler::Semantic::Restrictions::ArgRestriction.class#restrict_argument
table: compile_native origin 2 owner=lowering core reason=*Compiler::Semantic::Restrictions::ArgRestriction::restrict_union<Compiler::Types::TypeSystem::TypeSystem, Compiler::Semantic::TopLevel::ModuleType+, Compiler::Syntax::Ast::Union, Compiler::Types::Types::GenericInstanceType+, Compiler::Types::Types::VirtualType, Array(String), Hash(String, Compiler::Semantic::TopLevel::Type+)>:Compiler::Semantic::Restrictions::RestrictResult | lower: visit(a call dispatched over (Array(Compiler::Semantic::TopLevel::Type) | Array(Compiler::Types::Types::GenericInstanceType)) with a block (hosted call.cr: codegen_dispatch)) (hosted codegen.cr) is not ported yet example=Compiler::Semantic::Restrictions::ArgRestriction.class#restrict_argument
table: compile_native origin 2 owner=lowering core reason=*Compiler::Semantic::Restrictions::ArgRestriction::restrict_union<Compiler::Types::TypeSystem::TypeSystem, Compiler::Semantic::TopLevel::ModuleType+, Compiler::Syntax::Ast::Union, Compiler::Types::Types::GenericInstanceType+, Compiler::Types::Types::GenericClassInstanceMetaclassType, Array(String), Hash(String, Compiler::Semantic::TopLevel::Type+)>:Compiler::Semantic::Restrictions::RestrictResult | lower: visit(a call dispatched over (Array(Compiler::Semantic::TopLevel::Type) | Array(Compiler::Types::Types::GenericInstanceType)) with a block (hosted call.cr: codegen_dispatch)) (hosted codegen.cr) is not ported yet example=Compiler::Semantic::Restrictions::ArgRestriction.class#restrict_argument
table: compile_native origin 2 owner=lowering core reason=*Compiler::Semantic::Restrictions::ArgRestriction::restrict_union<Compiler::Types::TypeSystem::TypeSystem, Compiler::Semantic::TopLevel::ModuleType+, Compiler::Syntax::Ast::Union, Compiler::Types::Types::GenericInstanceType+, Compiler::Types::Types::GenericInstanceType+, Array(String), Hash(String, Compiler::Semantic::TopLevel::Type+)>:Compiler::Semantic::Restrictions::RestrictResult | lower: visit(a call dispatched over (Array(Compiler::Semantic::TopLevel::Type) | Array(Compiler::Types::Types::GenericInstanceType)) with a block (hosted call.cr: codegen_dispatch)) (hosted codegen.cr) is not ported yet example=Compiler::Semantic::Restrictions::ArgRestriction.class#restrict_argument
table: compile_native origin 2 owner=lowering core reason=*Compiler::Semantic::Restrictions::ArgRestriction::restrict_union<Compiler::Types::TypeSystem::TypeSystem, Compiler::Semantic::TopLevel::ModuleType+, Compiler::Syntax::Ast::Union, Compiler::Types::Types::GenericInstanceType+, Compiler::Semantic::TopLevel::ModuleType+, Array(String), Hash(String, Compiler::Semantic::TopLevel::Type+)>:Compiler::Semantic::Restrictions::RestrictResult | lower: visit(a call dispatched over (Array(Compiler::Semantic::TopLevel::Type) | Array(Compiler::Types::Types::GenericInstanceType)) with a block (hosted call.cr: codegen_dispatch)) (hosted codegen.cr) is not ported yet example=Compiler::Semantic::Restrictions::ArgRestriction.class#restrict_argument
table: compile_native origin 1 owner=bodies reason=*Std::Digest::ValueBarrier::u64<UInt64>:UInt64 | BUG: pointerof argument x has no addressable slot example=Std::Digest::ValueBarrier.class#u64
table: compile_native origin 1 owner=bodies reason=*Std::Digest::ValueBarrier::u8<UInt8>:UInt8 | BUG: pointerof argument x has no addressable slot example=Std::Digest::ValueBarrier.class#u8
table: compile_native origin 1 owner=unassigned reason=*Std::Dir::Dir::children<(Std::Path::Path | String)>:Array(String) | BUG: ~procProc(Nil)^src/std/dir.iyi:198 already has a body (hosted External#dead) example=Std::Dir::Dir.class#children
table: compile_native origin 1 owner=unassigned reason=*Std::Dir::Dir::empty?<(Std::Path::Path | String)>:Bool | BUG: ~procProc(Nil)^src/std/dir.iyi:198 already has a body (hosted External#dead) example=Std::Dir::Dir.class#empty?
table: compile_native origin 1 owner=lowering core reason=*Std::Dir::Dir::glob_single<String, &Proc(String, Nil)>:Nil | lower: visit(yield with no block in scope (hosted codegen.cr: visit(Yield), a block of an enclosing block body)) (hosted codegen.cr) is not ported yet example=Std::Dir::Dir.class#glob
table: compile_native origin 1 owner=unassigned reason=*Std::Dir::Dir::glob_step<(String | Nil), Array(String), Array(String), Int32, (String | Nil), Hash(String, Bool), &Proc(String, Nil)>:Nil | BUG: ~procProc(Nil)^src/std/dir.iyi:198 already has a body (hosted External#dead) example=Std::Dir::Dir.class#glob_step
table: compile_native origin 1 owner=unassigned reason=*Std::Dir::Dir::glob_step<String, Array(String), Array(String), Int32, (String | Nil), Hash(String, Bool), &Proc(String, Nil)>:Nil | BUG: ~procProc(Nil)^src/std/dir.iyi:198 already has a body (hosted External#dead) example=Std::Dir::Dir.class#glob_step
table: compile_native origin 1 owner=unassigned reason=*Compiler::Lower::Program#lowering_table<Compiler::Lower::Program::TypedProgram, String, String, Array(String), Array(String), Nil, Bool>:Array(String) | BUG: ~procProc(Nil)^src/iyi/./concurrency.iyi:7304 already has a body (hosted External#dead) example=Compiler::Lower::Program#lowering_table
table: compile_native origin 1 owner=unassigned reason=*Compiler::Lower::Program#lowering_table<Compiler::Lower::Program::TypedProgram, String, String, Array(String), Array(String), Hash(String, String)>:Array(String) | BUG: ~procProc(Nil)^src/iyi/./concurrency.iyi:7304 already has a body (hosted External#dead) example=Compiler::Lower::Program#lowering_table
table: compile_native origin 1 owner=unassigned reason=*Compiler::Lower::Program#lowering_table<Compiler::Lower::Program::TypedProgram, String, String, Array(String), Array(String), (Hash(String, String) | Nil), Bool>:Array(String) | BUG: ~procProc(Nil)^src/iyi/./concurrency.iyi:7304 already has a body (hosted External#dead) example=Compiler::Lower::Program#lowering_table
```
<!-- table:end -->
