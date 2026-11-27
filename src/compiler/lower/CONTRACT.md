# Analysed-program contract: what the Crystal code generator reads

This table lists the members that `src/compiler/semantic/typed.iyi` (trait `AnalysedProgram`) declares. They are the members the Crystal code generator reads from the analysed program, and the port has to provide them before a lowering can consume the analysed program in place of `src/compiler/iyi/codegen/*.cr`. This is specification section 3.6, slice S0. The trait and this table are generated from the same rows, and the gate fails when they disagree.

## How the list was extracted

Extracted at line B commit `9a2a08173`.

1. **Readings.** Every `receiver.member` access in `src/compiler/iyi/codegen/*.cr`, `src/compiler/iyi/preempt_checks.cr` and `src/compiler/iyi/wasm_roots.cr`. Lines containing `LLVM::` are skipped, and so are receivers that name LLVM or builder objects (`llvm`, `builder`, `di_`, `target_machine`, `data_layout`, `context`, `mod`, and similar). The first reading of each member is recorded, with the number of readings.
2. **Definitions.** A member is kept when the Crystal analysed-program sources define it as a `def`, `property`, `getter` or `setter`. Those sources are `src/compiler/iyi/{program,types,semantic,macros,preempt_checks,wasm_roots,object_header,annotatable,exception}.cr`, `src/compiler/iyi/semantic/*.cr` and `src/compiler/iyi/syntax/*.cr`. The defining file and line are recorded.
3. **Standard-library names removed.** A denylist drops names the codegen reads from Crystal's standard library rather than from the analysed program, such as `each`, `join`, `puts`, `raise`, `size` and `to_s`. The denylist is part of the extraction: a changed list means a changed table.
4. **Explicit rows.** The annotations and constants the specification names (`@[Primitive]`, `@[Naked]`, `@[NoInline]`, `@[AlwaysInline]`, `@[NoPreempt]`, `@[ThreadLocal]`, `@[Link]`, `ARGC_UNSAFE`, `ARGV_UNSAFE`) are added with their reading site. `@[Raises]` has no reading in the codegen, so its row says `(no reading site)`.

Matching is by name, not by receiver type. Each row therefore needs one look at its first reading before anyone relies on it for a particular purpose. The `reads` column shows how many readings a name has.

## Port status

`yes`: line B's semantic port defines the member and assigns it in `src/compiler/semantic/*.iyi`, `src/compiler/types/*.iyi` or `src/compiler/syntax/ast.iyi`. `partly`: defined there but never assigned, so the port declares the member without filling it. `no`: not defined there. For an annotation row, `partly` means the annotation's name appears in those sources and `no` means it does not.

## Counts

- Members: **193**
- Provided by the port today: **yes 53**, **partly 34**, **no 106**

## Members

| # | member | group | trait name | first read (file:line) | reads | defined at | port today |
|---|---|---|---|---|---|---|---|
| 1 | `accept` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:40` | 7 | `src/compiler/iyi/syntax/visitor.cr:19` | partly (`src/compiler/syntax/ast.iyi`) |
| 2 | `all_instance_vars` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:2765` | 8 | `src/compiler/iyi/types.cr:722` | partly (`src/compiler/semantic/top_level.iyi`) |
| 3 | `all_subclasses` | Program and Type |  | `src/compiler/iyi/codegen/class_var.cr:394` | 3 | `src/compiler/iyi/types.cr:273` | yes (`src/compiler/types/types.iyi`) |
| 4 | `base_type` | Program and Type |  | `src/compiler/iyi/codegen/class_var.cr:220` | 18 | `src/compiler/iyi/types.cr:3229` | yes (`src/compiler/syntax/ast.iyi`) |
| 5 | `belongs_to?` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:2578` | 2 | `src/compiler/iyi/semantic/ast.cr:514` | no |
| 6 | `bytes` | Program and Type |  | `src/compiler/iyi/codegen/llvm_typer.cr:136` | 32 | `src/compiler/iyi/types.cr:1612` | partly (`src/compiler/types/types.iyi`) |
| 7 | `can_throw?` | Program and Type |  | `src/compiler/iyi/codegen/asm.cr:56` | 1 | `src/compiler/iyi/macros.cr:2663` | no |
| 8 | `const` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:2130` | 1 | `src/compiler/iyi/syntax/ast.cr:1956` | yes (`src/compiler/syntax/ast.iyi`) |
| 9 | `context` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:92` | 8 | `src/compiler/iyi/semantic/ast.cr:453` | no |
| 10 | `def` | Program and Type | `def_member` | `src/compiler/iyi/codegen/codegen.cr:1044` | 4 | `src/compiler/iyi/semantic/match.cr:108` | yes (`src/compiler/syntax/ast.iyi`) |
| 11 | `each_concrete_type` | Program and Type |  | `src/compiler/iyi/codegen/match.cr:175` | 1 | `src/compiler/iyi/types.cr:3565` | no |
| 12 | `each_instantiated_type` | Program and Type |  | `src/compiler/iyi/codegen/llvm_id.cr:153` | 1 | `src/compiler/iyi/types.cr:1891` | no |
| 13 | `entries` | Program and Type |  | `src/compiler/iyi/codegen/cast.cr:269` | 9 | `src/compiler/iyi/types.cr:2951` | yes (`src/compiler/syntax/ast.iyi`) |
| 14 | `expanded_location` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:1997` | 2 | `src/compiler/iyi/syntax/location.cr:74` | no |
| 15 | `expressions` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:1160` | 2 | `src/compiler/iyi/macros.cr:706` | yes (`src/compiler/syntax/ast.iyi`) |
| 16 | `filename` | Program and Type |  | `src/compiler/iyi/codegen/class_var.cr:448` | 13 | `src/compiler/iyi/program.cr:1333` | no |
| 17 | `filter_by` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:2021` | 1 | `src/compiler/iyi/types.cr:439` | partly (`src/compiler/types/type_system.iyi`) |
| 18 | `get_exception_name` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:708` | 1 | `src/compiler/iyi/program.cr:552` | no |
| 19 | `has_key?` | Program and Type |  | `src/compiler/iyi/codegen/fun.cr:879` | 2 | `src/compiler/iyi/macros.cr:927` | no |
| 20 | `hook_expansions` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:1214` | 4 | `src/compiler/iyi/semantic/hooks.cr:50` | no |
| 21 | `implements?` | Program and Type |  | `src/compiler/iyi/codegen/cast.cr:143` | 8 | `src/compiler/iyi/types.cr:421` | no |
| 22 | `includes_type?` | Program and Type |  | `src/compiler/iyi/codegen/class_var.cr:44` | 1 | `src/compiler/iyi/types.cr:380` | no |
| 23 | `index_of_instance_var` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:3433` | 4 | `src/compiler/iyi/types.cr:739` | no |
| 24 | `instance` | Program and Type |  | `src/compiler/iyi/codegen/cache_dir.cr:14` | 2 | `src/compiler/iyi/macros.cr:2435` | no |
| 25 | `instance_vars` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:3430` | 4 | `src/compiler/iyi/types.cr:714` | yes (`src/compiler/semantic/top_level.iyi`) |
| 26 | `instance_vars_initializers` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:2835` | 1 | `src/compiler/iyi/types.cr:1336` | no |
| 27 | `instantiated_types` | Program and Type |  | `src/compiler/iyi/codegen/llvm_id.cr:92` | 1 | `src/compiler/iyi/types.cr:1887` | no |
| 28 | `iyi` | Program and Type |  | `src/compiler/iyi/codegen/cache_dir.cr:58` | 6 | `src/compiler/iyi/syntax/lexer.cr:24` | no |
| 29 | `lookup_instance_var` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:1916` | 3 | `src/compiler/iyi/types.cr:757` | partly (`src/compiler/semantic/top_level.iyi`) |
| 30 | `malloc_atomic_name` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:707` | 1 | `src/compiler/iyi/program.cr:544` | no |
| 31 | `malloc_name` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:707` | 1 | `src/compiler/iyi/program.cr:540` | no |
| 32 | `members` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:1258` | 1 | `src/compiler/iyi/semantic/exhaustiveness_checker.cr:441` | yes (`src/compiler/syntax/ast.iyi`) |
| 33 | `name_type` | Program and Type |  | `src/compiler/iyi/codegen/cast.cr:273` | 2 | `src/compiler/iyi/types.cr:2965` | partly (`src/compiler/types/types.iyi`) |
| 34 | `namespace` | Program and Type |  | `src/compiler/iyi/codegen/const.cr:130` | 2 | `src/compiler/iyi/types.cr:99` | partly (`src/compiler/semantic/top_level.iyi`) |
| 35 | `new_temp_var_name` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:2088` | 1 | `src/compiler/iyi/program.cr:1979` | partly (`src/compiler/semantic/normalizer.iyi`) |
| 36 | `nil_type` | Program and Type |  | `src/compiler/iyi/codegen/class_var.cr:44` | 2 | `src/compiler/iyi/program.cr:1886` | partly (`src/compiler/semantic/top_level.iyi`) |
| 37 | `nil_type?` | Program and Type |  | `src/compiler/iyi/codegen/ast.cr:170` | 9 | `src/compiler/iyi/types.cr:326` | yes (`src/compiler/semantic/top_level.iyi`) |
| 38 | `node` | Program and Type |  | `src/compiler/iyi/codegen/class_var.cr:124` | 8 | `src/compiler/iyi/semantic/ast.cr:829` | no |
| 39 | `normalize` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:2002` | 1 | `src/compiler/iyi/semantic/normalizer.cr:6` | partly (`src/compiler/semantic/normalizer.iyi`) |
| 40 | `not_nil_type` | Program and Type |  | `src/compiler/iyi/codegen/debug.cr:253` | 3 | `src/compiler/iyi/types.cr:3663` | partly (`src/compiler/types/types.iyi`) |
| 41 | `optimization_mode` | Program and Type |  | `src/compiler/iyi/codegen/fun.cr:847` | 1 | `src/compiler/iyi/program.cr:1354` | no |
| 42 | `packed?` | Program and Type |  | `src/compiler/iyi/codegen/llvm_typer.cr:314` | 1 | `src/compiler/iyi/types.cr:153` | yes (`src/compiler/types/types.iyi`) |
| 43 | `params` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:321` | 4 | `src/compiler/iyi/semantic/reach_proof.cr:164` | no |
| 44 | `parent` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:2744` | 1 | `src/compiler/iyi/semantic/main_visitor.cr:54` | no |
| 45 | `pointer?` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:1953` | 6 | `src/compiler/iyi/types.cr:322` | yes (`src/compiler/types/types.iyi`) |
| 46 | `pointer_of` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:2648` | 2 | `src/compiler/iyi/program.cr:1831` | partly (`src/compiler/types/type_system.iyi`) |
| 47 | `proc?` | Program and Type |  | `src/compiler/iyi/codegen/fun.cr:584` | 4 | `src/compiler/iyi/types.cr:350` | yes (`src/compiler/types/types.iyi`) |
| 48 | `proc_type` | Program and Type |  | `src/compiler/iyi/codegen/debug.cr:368` | 3 | `src/compiler/iyi/types.cr:3685` | partly (`src/compiler/types/types.iyi`) |
| 49 | `raise_cast_failed_name` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:709` | 1 | `src/compiler/iyi/program.cr:536` | no |
| 50 | `raise_name` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:707` | 1 | `src/compiler/iyi/program.cr:528` | no |
| 51 | `raise_overflow_name` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:708` | 1 | `src/compiler/iyi/program.cr:532` | no |
| 52 | `realloc_name` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:707` | 1 | `src/compiler/iyi/program.cr:548` | no |
| 53 | `reference_like?` | Program and Type |  | `src/compiler/iyi/codegen/type_layouts.cr:113` | 1 | `src/compiler/iyi/types.cr:215` | yes (`src/compiler/types/types.iyi`) |
| 54 | `reference_type` | Program and Type |  | `src/compiler/iyi/codegen/llvm_typer.cr:270` | 2 | `src/compiler/iyi/types.cr:3065` | yes (`src/compiler/semantic/top_level.iyi`) |
| 55 | `remove_indirection` | Program and Type |  | `src/compiler/iyi/codegen/call.cr:465` | 20 | `src/compiler/iyi/types.cr:838` | yes (`src/compiler/types/indirection.iyi`) |
| 56 | `special_var?` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:1612` | 6 | `src/compiler/iyi/syntax/ast.cr:845` | no |
| 57 | `struct?` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:2503` | 19 | `src/compiler/iyi/types.cr:137` | yes (`src/compiler/types/types.iyi`) |
| 58 | `subclasses` | Program and Type |  | `src/compiler/iyi/codegen/llvm_id.cr:104` | 5 | `src/compiler/iyi/types.cr:267` | yes (`src/compiler/types/types.iyi`) |
| 59 | `super?` | Program and Type |  | `src/compiler/iyi/codegen/call.cr:30` | 2 | `src/compiler/iyi/semantic/call.cr:1808` | no |
| 60 | `superclass` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:2823` | 2 | `src/compiler/iyi/types.cr:543` | yes (`src/compiler/syntax/ast.iyi`) |
| 61 | `syntax_replacement` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:2203` | 1 | `src/compiler/iyi/semantic/ast.cr:652` | no |
| 62 | `target` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:1179` | 4 | `src/compiler/iyi/macros.cr:1369` | yes (`src/compiler/syntax/ast.iyi`) |
| 63 | `target_cpu` | Program and Type |  | `src/compiler/iyi/codegen/fun.cr:832` | 1 | `src/compiler/iyi/semantic/ast.cr:166` | no |
| 64 | `target_features` | Program and Type |  | `src/compiler/iyi/codegen/fun.cr:831` | 1 | `src/compiler/iyi/semantic/ast.cr:163` | no |
| 65 | `to` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:1951` | 2 | `src/compiler/iyi/macros.cr:2456` | partly (`src/compiler/syntax/ast.iyi`) |
| 66 | `tuple_types` | Program and Type |  | `src/compiler/iyi/codegen/cast.cr:255` | 16 | `src/compiler/iyi/types.cr:2831` | partly (`src/compiler/types/types.iyi`) |
| 67 | `type_from_literal_kind` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:657` | 1 | `src/compiler/iyi/program.cr:1895` | partly (`src/compiler/semantic/main_visitor.iyi`) |
| 68 | `type_merge` | Program and Type |  | `src/compiler/iyi/codegen/call.cr:515` | 1 | `src/compiler/iyi/semantic/type_merge.cr:5` | partly (`src/compiler/types/unification.iyi`) |
| 69 | `types` | Program and Type |  | `src/compiler/iyi/codegen/cast.cr:525` | 5 | `src/compiler/iyi/types.cr:513` | yes (`src/compiler/syntax/ast.iyi`) |
| 70 | `types?` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:598` | 2 | `src/compiler/iyi/types.cr:517` | no |
| 71 | `unbound?` | Program and Type |  | `src/compiler/iyi/codegen/llvm_id.cr:154` | 1 | `src/compiler/iyi/types.cr:862` | yes (`src/compiler/types/types.iyi`) |
| 72 | `union_types` | Program and Type |  | `src/compiler/iyi/codegen/cast.cr:128` | 21 | `src/compiler/iyi/types.cr:3487` | partly (`src/compiler/semantic/top_level.iyi`) |
| 73 | `unions` | Program and Type |  | `src/compiler/iyi/codegen/gc_layouts.cr:213` | 1 | `src/compiler/iyi/program.cr:1268` | no |
| 74 | `upcast` | Program and Type |  | `src/compiler/iyi/codegen/phi.cr:64` | 1 | `src/compiler/iyi/semantic/bindings.cr:479` | no |
| 75 | `var` | Program and Type |  | `src/compiler/iyi/codegen/class_var.cr:101` | 9 | `src/compiler/iyi/types.cr:2658` | yes (`src/compiler/syntax/ast.iyi`) |
| 76 | `visit_main` | Program and Type |  | `src/compiler/iyi/codegen/codegen.cr:2007` | 2 | `src/compiler/iyi/semantic/main_visitor.cr:5` | no |
| 77 | `void?` | Program and Type |  | `src/compiler/iyi/codegen/ast.cr:170` | 14 | `src/compiler/iyi/types.cr:354` | yes (`src/compiler/types/types.iyi`) |
| 78 | `arg_types` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:298` | 10 | `src/compiler/iyi/types.cr:2755` | partly (`src/compiler/types/types.iyi`) |
| 79 | `args` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:105` | 50 | `src/compiler/iyi/macros.cr:1265` | yes (`src/compiler/syntax/ast.iyi`) |
| 80 | `block` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:38` | 3 | `src/compiler/iyi/macros.cr:1329` | yes (`src/compiler/syntax/ast.iyi`) |
| 81 | `body` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:62` | 21 | `src/compiler/iyi/macros.cr:1283` | yes (`src/compiler/syntax/ast.iyi`) |
| 82 | `closure_in?` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/codegen.cr:2576` | 2 | `src/compiler/iyi/semantic/ast.cr:509` | no |
| 83 | `cond` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/codegen.cr:1331` | 6 | `src/compiler/iyi/macros.cr:1351` | yes (`src/compiler/syntax/ast.iyi`) |
| 84 | `def_full_name` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/fun.cr:205` | 1 | `src/compiler/iyi/semantic/call_error.cr:1906` | no |
| 85 | `default_value` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:193` | 1 | `src/compiler/iyi/macros.cr:1223` | partly (`src/compiler/syntax/ast.iyi`) |
| 86 | `else` | Def, ASTNode and Call | `else_member` | `src/compiler/iyi/codegen/codegen.cr:1341` | 4 | `src/compiler/iyi/macros.cr:1359` | yes (`src/compiler/syntax/ast.iyi`) |
| 87 | `end_location` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:195` | 1 | `src/compiler/iyi/syntax/ast.cr:46` | yes (`src/compiler/syntax/ast.iyi`) |
| 88 | `exp` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/asm.cr:34` | 11 | `src/compiler/iyi/macros.cr:1621` | yes (`src/compiler/syntax/ast.iyi`) |
| 89 | `expanded` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:5` | 2 | `src/compiler/iyi/semantic/ast.cr:706` | yes (`src/compiler/syntax/ast.iyi`) |
| 90 | `fun_literal` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:40` | 1 | `src/compiler/iyi/semantic/ast.cr:674` | no |
| 91 | `has_inner_pointers?` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/codegen.cr:2765` | 9 | `src/compiler/iyi/macros.cr:3043` | no |
| 92 | `instance_type` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/ast.cr:19` | 14 | `src/compiler/iyi/types.cr:372` | yes (`src/compiler/types/types.iyi`) |
| 93 | `location` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:6` | 25 | `src/compiler/iyi/semantic/type_declaration_processor.cr:60` | yes (`src/compiler/syntax/ast.iyi`) |
| 94 | `mangled_name` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/fun.cr:22` | 1 | `src/compiler/iyi/semantic/ast.cr:776` | no |
| 95 | `meta_vars` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/class_var.cr:163` | 2 | `src/compiler/iyi/types.cr:1316` | no |
| 96 | `metaclass` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/class_var.cr:397` | 12 | `src/compiler/iyi/program.cr:2015` | yes (`src/compiler/types/types.iyi`) |
| 97 | `metaclass?` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/ast.cr:18` | 6 | `src/compiler/iyi/types.cr:311` | yes (`src/compiler/types/types.iyi`) |
| 98 | `name` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/ast.cr:35` | 97 | `src/compiler/iyi/types.cr:935` | yes (`src/compiler/syntax/ast.iyi`) |
| 99 | `name_location` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:459` | 2 | `src/compiler/iyi/syntax/ast.cr:99` | yes (`src/compiler/syntax/ast.iyi`) |
| 100 | `no_return?` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:678` | 4 | `src/compiler/iyi/types.cr:338` | yes (`src/compiler/types/types.iyi`) |
| 101 | `obj` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:67` | 14 | `src/compiler/iyi/macros.cr:1398` | yes (`src/compiler/syntax/ast.iyi`) |
| 102 | `owner` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:90` | 18 | `src/compiler/iyi/types.cr:2096` | partly (`src/compiler/semantic/top_level.iyi`) |
| 103 | `return_type` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:244` | 15 | `src/compiler/iyi/types.cr:2756` | partly (`src/compiler/syntax/ast.iyi`) |
| 104 | `scope` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:30` | 5 | `src/compiler/iyi/macros.cr:2385` | yes (`src/compiler/syntax/ast.iyi`) |
| 105 | `set_type` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:512` | 3 | `src/compiler/iyi/semantic/bindings.cr:111` | partly (`src/compiler/semantic/main_visitor.iyi`) |
| 106 | `special_vars` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:186` | 2 | `src/compiler/iyi/semantic/ast.cr:145` | no |
| 107 | `splat_index` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/codegen.cr:2233` | 1 | `src/compiler/iyi/types.cr:854` | yes (`src/compiler/types/types.iyi`) |
| 108 | `supports_autocast?` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:490` | 1 | `src/compiler/iyi/semantic/ast.cr:20` | no |
| 109 | `target_const` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:75` | 5 | `src/compiler/iyi/semantic/ast.cr:650` | yes (`src/compiler/semantic/main_visitor.iyi`) |
| 110 | `target_def` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:25` | 7 | `src/compiler/iyi/semantic/call.cr:24` | yes (`src/compiler/semantic/main_visitor.iyi`) |
| 111 | `target_defs` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:9` | 2 | `src/compiler/iyi/semantic/call.cr:9` | no |
| 112 | `then` | Def, ASTNode and Call | `then_member` | `src/compiler/iyi/codegen/codegen.cr:1332` | 3 | `src/compiler/iyi/macros.cr:1355` | yes (`src/compiler/syntax/ast.iyi`) |
| 113 | `type` | Def, ASTNode and Call | `type_member` | `src/compiler/iyi/codegen/asm.cr:15` | 248 | `src/compiler/iyi/macros.cr:864` | yes (`src/compiler/types/types.iyi`) |
| 114 | `type?` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/ast.cr:166` | 19 | `src/compiler/iyi/semantic/bindings.cr:85` | no |
| 115 | `uses_with_scope` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:458` | 1 | `src/compiler/iyi/semantic/call.cr:12` | no |
| 116 | `value` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:161` | 64 | `src/compiler/iyi/types.cr:1315` | yes (`src/compiler/syntax/ast.iyi`) |
| 117 | `vars` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:371` | 12 | `src/compiler/iyi/program.cr:70` | yes (`src/compiler/syntax/ast.iyi`) |
| 118 | `with_scope` | Def, ASTNode and Call |  | `src/compiler/iyi/codegen/call.cr:93` | 3 | `src/compiler/iyi/semantic/call.cr:7` | no |
| 119 | `type_id` | type ids |  | `src/compiler/iyi/codegen/gc_layouts.cr:98` | 3 | `src/compiler/iyi/object_header.cr:115` | no |
| 120 | `virtual_type` | type ids |  | `src/compiler/iyi/codegen/ast.cr:110` | 5 | `src/compiler/iyi/types.cr:358` | yes (`src/compiler/types/types.iyi`) |
| 121 | `virtual_type!` | type ids | `virtual_type_bang` | `src/compiler/iyi/codegen/codegen.cr:517` | 1 | `src/compiler/iyi/types.cr:368` | no |
| 122 | `virtual_type_made?` | type ids |  | `src/compiler/iyi/codegen/gc_layouts.cr:207` | 1 | `src/compiler/iyi/types.cr:364` | no |
| 123 | `size_bit_width` | layouts and sizes |  | `src/compiler/iyi/codegen/codegen.cr:3282` | 10 | `src/compiler/iyi/semantic/flags.cr:63` | no |
| 124 | `sizeof_type` | layouts and sizes |  | `src/compiler/iyi/codegen/codegen.cr:1292` | 4 | `src/compiler/iyi/types.cr:879` | partly (`src/compiler/types/types.iyi`, refused by name) |
| 125 | `alignstack?` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/asm.cr:56` | 1 | `src/compiler/iyi/macros.cr:2654` | no |
| 126 | `allowed_in_lib?` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/ast.cr:170` | 2 | `src/compiler/iyi/semantic/lib.cr:281` | no |
| 127 | `annotation` | lib funs, asm and linking | `annotation_member` | `src/compiler/iyi/codegen/call.cr:385` | 2 | `src/compiler/iyi/macros.cr:1233` | no |
| 128 | `call_convention` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/call.cr:661` | 3 | `src/compiler/iyi/types.cr:3079` | no |
| 129 | `clobbers` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/asm.cr:42` | 1 | `src/compiler/iyi/macros.cr:2645` | partly (`src/compiler/syntax/ast.iyi`) |
| 130 | `constraint` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/asm.cr:13` | 2 | `src/compiler/iyi/macros.cr:2676` | partly (`src/compiler/syntax/ast.iyi`) |
| 131 | `element_type` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/abi.cr:74` | 23 | `src/compiler/iyi/types.cr:2662` | partly (`src/compiler/types/types.iyi`) |
| 132 | `extern?` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/ast.cr:168` | 9 | `src/compiler/iyi/types.cr:142` | yes (`src/compiler/types/types.iyi`) |
| 133 | `extern_union?` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/codegen.cr:206` | 9 | `src/compiler/iyi/types.cr:147` | yes (`src/compiler/types/types.iyi`) |
| 134 | `file_module` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/codegen.cr:874` | 1 | `src/compiler/iyi/program.cr:2047` | no |
| 135 | `file_modules` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/codegen.cr:486` | 1 | `src/compiler/iyi/program.cr:59` | no |
| 136 | `inputs` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/asm.cr:30` | 1 | `src/compiler/iyi/macros.cr:1480` | partly (`src/compiler/syntax/ast.iyi`) |
| 137 | `link_annotations` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/link.cr:366` | 1 | `src/compiler/iyi/types.cr:3077` | no |
| 138 | `main_name` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/codegen.cr:47` | 2 | `src/compiler/iyi/program.cr:524` | no |
| 139 | `output_ptrofs` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/asm.cr:8` | 2 | `src/compiler/iyi/semantic/ast.cr:824` | no |
| 140 | `outputs` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/asm.cr:7` | 1 | `src/compiler/iyi/macros.cr:2637` | partly (`src/compiler/syntax/ast.iyi`) |
| 141 | `real_name` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/ast.cr:135` | 8 | `src/compiler/iyi/macros.cr:2092` | partly (`src/compiler/syntax/ast.iyi`) |
| 142 | `remove_alias` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/ast.cr:167` | 3 | `src/compiler/iyi/types.cr:830` | yes (`src/compiler/types/merge.iyi`) |
| 143 | `remove_typedef` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/codegen.cr:1931` | 6 | `src/compiler/iyi/types.cr:384` | yes (`src/compiler/semantic/top_level.iyi`) |
| 144 | `typedef` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/cast.cr:247` | 10 | `src/compiler/iyi/types.cr:3113` | no |
| 145 | `volatile?` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/asm.cr:56` | 1 | `src/compiler/iyi/macros.cr:2650` | no |
| 146 | `wasm_import_module` | lib funs, asm and linking |  | `src/compiler/iyi/codegen/fun.cr:565` | 1 | `src/compiler/iyi/types.cr:3104` | no |
| 147 | `class_vars` | Program: class variables |  | `src/compiler/iyi/codegen/codegen.cr:3031` | 2 | `src/compiler/iyi/types.cr:718` | yes (`src/compiler/semantic/top_level.iyi`) |
| 148 | `class_vars?` | Program: class variables |  | `src/compiler/iyi/codegen/codegen.cr:501` | 1 | `src/compiler/iyi/types.cr:1246` | no |
| 149 | `global` | Program: class variables |  | `src/compiler/iyi/codegen/codegen.cr:2000` | 3 | `src/compiler/iyi/macros.cr:1816` | partly (`src/compiler/syntax/ast.iyi`) |
| 150 | `initializer` | Program: class variables |  | `src/compiler/iyi/codegen/class_var.cr:44` | 42 | `src/compiler/iyi/semantic/ast.cr:563` | partly (`src/compiler/semantic/top_level.iyi`) |
| 151 | `lookup_class_var` | Program: class variables |  | `src/compiler/iyi/codegen/class_var.cr:356` | 2 | `src/compiler/iyi/types.cr:770` | partly (`src/compiler/semantic/top_level.iyi`) |
| 152 | `lookup_class_var?` | Program: class variables |  | `src/compiler/iyi/codegen/codegen.cr:523` | 2 | `src/compiler/iyi/types.cr:766` | no |
| 153 | `once_init_name` | Program: class variables |  | `src/compiler/iyi/codegen/codegen.cr:709` | 1 | `src/compiler/iyi/program.cr:556` | no |
| 154 | `once_name` | Program: class variables |  | `src/compiler/iyi/codegen/codegen.cr:709` | 1 | `src/compiler/iyi/program.cr:560` | no |
| 155 | `simple_initializer` | Program: class variables |  | `src/compiler/iyi/codegen/class_var.cr:186` | 1 | `src/compiler/iyi/semantic/ast.cr:592` | no |
| 156 | `simple_literal?` | Program: class variables |  | `src/compiler/iyi/codegen/class_var.cr:174` | 1 | `src/compiler/iyi/semantic/ast.cr:9` | no |
| 157 | `thread_local` | Program: class variables |  | `src/compiler/iyi/codegen/codegen.cr:2181` | 1 | `src/compiler/iyi/semantic/ast.cr:596` | no |
| 158 | `ARGC_UNSAFE` | Program: constants | `argc_unsafe` | `src/compiler/iyi/codegen/const.cr:34` | 1 | (constant) | no |
| 159 | `ARGV_UNSAFE` | Program: constants | `argv_unsafe` | `src/compiler/iyi/codegen/const.cr:34` | 1 | (constant) | no |
| 160 | `const_initializers` | Program: constants |  | `src/compiler/iyi/codegen/codegen.cr:435` | 1 | `src/compiler/iyi/program.cr:1311` | no |
| 161 | `const_slices` | Program: constants |  | `src/compiler/iyi/codegen/codegen.cr:360` | 1 | `src/compiler/iyi/program.cr:1306` | no |
| 162 | `predefined_constants` | Program: constants |  | `src/compiler/iyi/codegen/const.cr:38` | 1 | `src/compiler/iyi/program.cr:1340` | no |
| 163 | `has_flag?` | Program: flags |  | `src/compiler/iyi/codegen/call.cr:490` | 32 | `src/compiler/iyi/semantic/flags.cr:20` | no |
| 164 | `no_init_flag` | Program: flags |  | `src/compiler/iyi/codegen/class_var.cr:119` | 2 | `src/compiler/iyi/semantic/ast.cr:613` | no |
| 165 | `iyi_artifact_class_vars` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/codegen.cr:463` | 2 | `src/compiler/iyi/program.cr:887` | no |
| 166 | `iyi_artifact_constant_reads` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/const.cr:304` | 1 | `src/compiler/iyi/program.cr:877` | no |
| 167 | `iyi_artifact_match_types` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/match.cr:114` | 1 | `src/compiler/iyi/program.cr:872` | no |
| 168 | `iyi_artifact_modules` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/fun.cr:203` | 1 | `src/compiler/iyi/program.cr:241` | no |
| 169 | `iyi_artifact_numbered_types` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/type_id.cr:97` | 1 | `src/compiler/iyi/program.cr:714` | no |
| 170 | `iyi_artifact_objects` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/codegen.cr:626` | 2 | `src/compiler/iyi/program.cr:465` | no |
| 171 | `iyi_artifact_phantom_types` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/type_id.cr:127` | 1 | `src/compiler/iyi/program.cr:725` | no |
| 172 | `iyi_artifact_symbols` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/fun.cr:337` | 1 | `src/compiler/iyi/program.cr:858` | no |
| 173 | `iyi_exported_owners` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/call.cr:590` | 17 | `src/compiler/iyi/program.cr:475` | no |
| 174 | `iyi_origin` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/fun.cr:190` | 1 | `src/compiler/iyi/syntax/ast.cr:1642` | no |
| 175 | `iyi_preempt_flag` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/codegen.cr:3150` | 2 | `src/compiler/iyi/program.cr:637` | no |
| 176 | `iyi_preempt_funs` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/fun.cr:456` | 1 | `src/compiler/iyi/program.cr:642` | no |
| 177 | `iyi_prelude_dir` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/codegen.cr:3063` | 1 | `src/compiler/iyi/program.cr:576` | no |
| 178 | `iyi_runs_c?` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/primitives.cr:84` | 1 | `src/compiler/iyi/program.cr:601` | no |
| 179 | `iyi_unit_class_vars` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/class_var.cr:269` | 2 | `src/compiler/iyi/program.cr:703` | no |
| 180 | `iyi_unit_constants` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/const.cr:261` | 1 | `src/compiler/iyi/program.cr:668` | no |
| 181 | `iyi_unit_libs` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/fun.cr:108` | 2 | `src/compiler/iyi/program.cr:833` | no |
| 182 | `iyi_unit_match_types` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/match.cr:67` | 1 | `src/compiler/iyi/program.cr:760` | no |
| 183 | `iyi_unit_symbol_literals` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/symbol.cr:42` | 1 | `src/compiler/iyi/program.cr:767` | no |
| 184 | `iyi_unit_symbols` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/fun.cr:376` | 1 | `src/compiler/iyi/program.cr:820` | no |
| 185 | `iyi_unit_type_ids` | Program: iyi-specific state |  | `src/compiler/iyi/codegen/type_id.cr:192` | 1 | `src/compiler/iyi/program.cr:655` | no |
| 186 | `@[AlwaysInline]` | annotations | `annotation_always_inline` | `src/compiler/iyi/codegen/fun.cr:842` | 1 | (annotation) | no |
| 187 | `@[Link]` | annotations | `annotation_link` | `src/compiler/iyi/codegen/class_var.cr:42` | 1 | (annotation) | no |
| 188 | `@[Naked]` | annotations | `annotation_naked` | `src/compiler/iyi/codegen/codegen.cr:2157` | 1 | (annotation) | no |
| 189 | `@[NoInline]` | annotations | `annotation_no_inline` | `src/compiler/iyi/codegen/call.cr:738` | 1 | (annotation) | no |
| 190 | `@[NoPreempt]` | annotations | `annotation_no_preempt` | `src/compiler/iyi/codegen/call.cr:383` | 1 | (annotation) | no |
| 191 | `@[Primitive]` | annotations | `annotation_primitive` | `src/compiler/iyi/codegen/call.cr:62` | 1 | (annotation) | partly |
| 192 | `@[Raises]` | annotations | `annotation_raises` | (no reading site) | 0 | (annotation) | no |
| 193 | `@[ThreadLocal]` | annotations | `annotation_thread_local` | `src/compiler/iyi/codegen/class_var.cr:9` | 1 | (annotation) | no |

## Limits of this table

- Name matching over-approximates. A codegen call site may read a name from some object other than the analysed program (for example, an asm node's fields), so such rows are listed. Each row keeps its first reading so a reviewer can check it.
- A member generated through a macro in the Crystal sources (for example `{% for %}` property generation) is not seen. A missing row is therefore not proof that the codegen does not read that member.
- `yes` means the port assigns the member on some path. It does not mean the value agrees with the Crystal value. The typed parity gate measures agreement, node by node.
