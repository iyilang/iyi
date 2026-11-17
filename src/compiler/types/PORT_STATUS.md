# Port status of `src/compiler/iyi/types.cr`

Slice S1a. Every class, module, `def` and accessor declared in the hosted `types.cr` (4,014 lines), checked against the port: `src/compiler/types/*.iyi` and the base classes in `src/compiler/semantic/top_level.iyi`.

Generated mechanically by name and owner class (indentation-tracked, so a method is matched only to a class of the same name in the port). The status column is a name match: `ported` means the port declares the same member on a class of the same name at the given location, and it does not prove the values agree (the gate proves that). `other owner` means the port has a function of that name on a different owner, usually a module function taking the receiver as its first argument (the hosted code reopens classes, which iyi cannot do). `out of scope` marks Crystal-only printing and inspection, which the iyi port does not carry.

The `codegen reads` column comes from `src/compiler/lower/CONTRACT.md`: the number of readings by the Crystal code generator and the first reading. Those rows are the ones increment (2) must provide.

Totals: 568 rows. Increment (1) baseline: 141 ported, 107 other owner, 298 missing, 22 out of scope. Increment (2) provides the base `Type` members named in the `TypeQueries` rows below (`ported as TypeQueries.<name>`); the subclass overrides of the same names are not yet covered. 

Increment (9), regenerated from the status column: 186 ported, 98 other owner, 262 missing, 22 out of scope, 0 other. The rows changed in increment 9 are the members the type-model gate compares (semty_*.iyi, 260 operations); their status names the defining file.
Increment (3), `merge.iyi`, and increment (4), `filters.iyi` and `intersect.iyi`, are gated in `semty_merge.iyi`, `semty_filter.iyi` and `semty_intersect.iyi`. This session closed the divergences those fixtures used to list as "not gated": including_types (`ModuleType#including_types`, read by `TypeIntersect.including_descendent`), aliases (removed before intersecting, and union alias values merge through the hook), generic instances (`semty_generics.iyi`: an instance registers with its generic type, and a generic type stands for itself as a virtual type; `class IntBox < Box(Int32)` takes the instance as its superclass), procs (`TypeIntersect.compatible_proc?`, as the hosted `compatible_with?`, with `Void` returns converted to `Nil` by `TypeSystem.proc_of`), and union members printed devirtualized, as the hosted printer does. `SemanticProgram` resolves written types and merges through the `TypeHook` that `TypeSystem` installs. Typedefs (`remove_typedef`, lib declarations) are not declared by the port: the `# waiting typedef:` lines in `semty_alias.iyi` are reported by the gate under their own heading and are not compared. Increment (7): `restrictions.iyi` and `type_system.iyi` call `TypeIntersect.common_descendent`, and `filtering.iyi`'s copy is retired. Increment (5) is done in `lookup.iyi` (see below). Increments (6), (7), (8) and (9) are not started. Row counts above are the baseline; the status column was not regenerated.
Increment (5), the lookup port: `lookup.iyi` (`TypeLookup`), with `instances.iyi` (`TypeInstances`), the instance cache the lookup and the TypeSystem now share, since lookup.iyi cannot import type_system.iyi. The lookup covers `Path` (global, nested, the parent and namespace walk for the first item), `Union`, `Metaclass`, `Generic` (arity messages, splats of tuples and type parameters, `NamedTuple`, `Tuple`, `Union`, `Proc`, `Pointer`, `StaticArray` with a number size), `ProcNotation`, `Self`, and the nilable `?` (the parser writes it as `Union(T, Nil)`). Refused by name or not ported: `typeof`, `_`, a constant size, the import wall, `using`, private types, a type parameter solved through an inherited generic, and the parents of a generic instance. `TypeSystem.lookup_type_node` and `lookup_path` are deleted; `TypeSystem#resolve_node` is the one entry and the types driver's caller migrated to it. `SemanticProgram.lookup_type_node` keeps the simplified lookup: the real pipeline installs no TypeSystem, and routing that lookup through the hook broke the typing of its union branch, so only the superclass path uses the hook. `TypeRenderer` prints a union member devirtualized outside codegen, as the hosted printer does. The gate `semty_lookup.iyi`: 23 operations identical, the `typeof` operation is waiting, and three mutations are proved, among them the arity check and the unbound-generic check.
Increments (6), (7) and (8), the later status. This supersedes the typedef and "not started" sentences above. Restrictions: `to_restriction.iyi` (`TypeToRestriction`) ports `type_to_restriction.cr`, including the common-namespace rule for private types. `conversions.cr` needs typed calls and waits. Gate `semty_restrict.iyi`. Typedefs: `TypeDefType` and `LibType` in `top_level.iyi`, `Type#remove_typedef`, and the `LibDef` and `TypeDef` visits; lib functions, structs and external variables keep the default visit. Not ported: the lib's link annotations and call convention, `check_allowed_in_lib` (a typedef of a disallowed type is accepted), and the TypeDefType delegations (`pointer?`, `reference_like?`, `parents`, `defs`, `macros`, `lookup_instance_var`). `intersect.iyi`: `typedef_descendent`, with typedef operands on the right and a typedef's parent walk not ported. Includers: a generic instance records the modules its generic class includes (`GenericClassInstanceType#included_modules`, read by `subtype_of?` and `TypeIntersect.parents_of`, and registered with each `NonGenericModuleType#add_including_type`). Not ported: `GenericClassType#including_types`, which the hosted generic type answers with its instances (waiting in `semty_includers.iyi`). `AliasType#simple?` is always true, since every alias the port models names a type. Lookup: a private type reached at a later path item is refused as `private constant X referenced`. Gates `semty_restrict.iyi`, `semty_alias.iyi` and `semty_includers.iyi` are in `selfhost_semantic_types`, which now compares 12 fixtures over 241 operations.
| hosted line | kind | owner | member | port status | codegen reads | class |
|---:|---|---|---|---|---|---|
| 3 | class | Iyi | `Iyi` | missing class |  | missing |
| 5 | class | Type | `Type` | ported class (src/compiler/semantic/top_level.iyi:19) |  | ported |
| 9 | attr | Type | `program` | ported (src/compiler/semantic/top_level.iyi:20) |  | ported |
| 43 | def | Type | `initialize` | ported (src/compiler/semantic/top_level.iyi:27) |  | ported |
| 47 | def | Type | `doc` | missing |  | missing |
| 52 | def | Type | `locations` | missing |  | missing |
| 61 | def | Type | `using_modules?` | missing |  | missing |
| 70 | def | Type | `iyi_unit?` | missing |  | missing |
| 79 | def | Type | `error?` | missing |  | missing |
| 87 | def | Type | `exported_name?` | missing |  | missing |
| 93 | def | Type | `opaque_id` | missing |  | missing |
| 99 | def | Type | `namespace` | ported (src/compiler/semantic/top_level.iyi:21) | 2 reads, first src/compiler/iyi/codegen/const.cr:130 | ported |
| 104 | def | Type | `each_namespace` | missing |  | missing |
| 113 | def | Type | `abstract?` | ported (src/compiler/semantic/top_level.iyi:57) |  | ported |
| 120 | def | Type | `abstract_leaf?` | missing |  | missing |
| 137 | def | Type | `struct?` | ported (src/compiler/semantic/top_level.iyi:61) | 19 reads, first src/compiler/iyi/codegen/codegen.cr:2503 | ported |
| 142 | def | Type | `extern?` | missing | 9 reads, first src/compiler/iyi/codegen/ast.cr:168 | ported as TypeQueries.extern? (src/compiler/types/types.iyi) |
| 147 | def | Type | `extern_union?` | missing | 9 reads, first src/compiler/iyi/codegen/codegen.cr:206 | ported as TypeQueries.extern_union? (src/compiler/types/types.iyi) |
| 153 | def | Type | `packed?` | missing | 1 reads, first src/compiler/iyi/codegen/llvm_typer.cr:314 | ported as TypeQueries.packed? (src/compiler/types/types.iyi) |
| 169 | def | Type | `gc_shape` | missing |  | missing |
| 193 | def | Type | `inst_shape` | missing |  | missing |
| 215 | def | Type | `reference_like?` | ported as `TypeQueries.reference_like?` (types/types.iyi) | 1 reads, first src/compiler/iyi/codegen/type_layouts.cr:113 | ported |
| 234 | def | Type | `defs` | other owner ModuleType (src/compiler/semantic/top_level.iyi:195) |  | other-owner |
| 240 | def | Type | `macros` | other owner ModuleType (src/compiler/semantic/top_level.iyi:199) |  | other-owner |
| 245 | attr | Type | `metaclass` | other owner VirtualType (src/compiler/types/types.iyi:45) | 12 reads, first src/compiler/iyi/codegen/class_var.cr:397 | other-owner |
| 253 | def | Type | `initialize_metaclass` | missing |  | missing |
| 262 | def | Type | `can_be_stored?` | missing |  | missing |
| 267 | def | Type | `subclasses` | ported as `TypeQueries.subclasses` (types/types.iyi) | 5 reads, first src/compiler/iyi/codegen/llvm_id.cr:104 | ported |
| 273 | def | Type | `all_subclasses` | ported as `TypeQueries.all_subclasses` (types/types.iyi) | 3 reads, first src/compiler/iyi/codegen/class_var.cr:394 | ported |
| 279 | def | Type | `append_subclasses` | missing |  | missing |
| 287 | def | Type | `leaf?` | ported as `TypeQueries.leaf?` (types/types.iyi) |  | ported |
| 291 | def | Type | `class?` | ported (src/compiler/semantic/top_level.iyi:65) |  | ported |
| 295 | def | Type | `module?` | ported (src/compiler/semantic/top_level.iyi:69) |  | ported |
| 307 | def | Type | `trait?` | ported (src/compiler/semantic/top_level.iyi:73) |  | ported |
| 311 | def | Type | `metaclass?` | ported as `TypeQueries.metaclass?` (types/types.iyi) | 6 reads, first src/compiler/iyi/codegen/ast.cr:18 | ported |
| 322 | def | Type | `pointer?` | ported as `TypeQueries.pointer?` (types/types.iyi) | 6 reads, first src/compiler/iyi/codegen/codegen.cr:1953 | ported |
| 326 | def | Type | `nil_type?` | ported (src/compiler/semantic/top_level.iyi:93) | 9 reads, first src/compiler/iyi/codegen/ast.cr:170 | ported |
| 330 | def | Type | `nilable?` | ported (src/compiler/semantic/top_level.iyi:97) |  | ported |
| 334 | def | Type | `bool_type?` | missing |  | missing |
| 338 | def | Type | `no_return?` | ported as `TypeQueries.no_return?` (types/types.iyi) | 4 reads, first src/compiler/iyi/codegen/call.cr:678 | ported |
| 342 | def | Type | `virtual?` | ported as `TypeQueries.virtual?` (types/types.iyi) |  | ported |
| 346 | def | Type | `virtual_metaclass?` | ported as `TypeQueries.virtual_metaclass?` (types/types.iyi) |  | ported |
| 350 | def | Type | `proc?` | ported as `TypeQueries.proc?` (types/types.iyi) | 4 reads, first src/compiler/iyi/codegen/fun.cr:584 | ported |
| 354 | def | Type | `void?` | ported as `TypeQueries.void?` (types/types.iyi) | 14 reads, first src/compiler/iyi/codegen/ast.cr:170 | ported |
| 358 | def | Type | `virtual_type` | ported as `TypeQueries.virtual_type` (types/types.iyi) | 5 reads, first src/compiler/iyi/codegen/ast.cr:110 | ported |
| 364 | def | Type | `virtual_type_made?` | missing | 1 reads, first src/compiler/iyi/codegen/gc_layouts.cr:207 | missing |
| 368 | def | Type | `virtual_type!` | ported as `TypeQueries.virtual_type_bang` (types/types.iyi) | 1 reads, first src/compiler/iyi/codegen/codegen.cr:517 | ported |
| 372 | def | Type | `instance_type` | ported as `TypeQueries.instance_type` (types/types.iyi) | 14 reads, first src/compiler/iyi/codegen/ast.cr:19 | ported |
| 376 | def | Type | `generic_type` | other owner GenericInstanceType (src/compiler/types/types.iyi:110) |  | other-owner |
| 380 | def | Type | `includes_type?` | missing | 1 reads, first src/compiler/iyi/codegen/class_var.cr:44 | missing |
| 384 | def | Type | `remove_typedef` | missing | 6 reads, first src/compiler/iyi/codegen/codegen.cr:1931 | ported (src/compiler/semantic/top_level.iyi) |
| 392 | def | Type | `class_var_owner` | missing |  | missing |
| 396 | def | Type | `has_in_type_vars?` | missing |  | missing |
| 404 | def | Type | `lookup_new_in_ancestors?` | missing |  | missing |
| 410 | def | Type | `devirtualize` | missing |  | missing |
| 421 | def | Type | `implements?` | ported (src/compiler/semantic/top_level.iyi:150) | 8 reads, first src/compiler/iyi/codegen/cast.cr:143 | ported |
| 439 | def | Type | `filter_by` | other owner TypeFiltering (src/compiler/types/filtering.iyi:11) | 1 reads, first src/compiler/iyi/codegen/codegen.cr:2021 | other-owner |
| 443 | def | Type | `filter_by_responds_to` | other owner TypeFiltering (src/compiler/types/filtering.iyi:127) |  | other-owner |
| 447 | def | Type | `add_instance_var_initializer` | missing |  | missing |
| 451 | def | Type | `declare_instance_var` | missing |  | missing |
| 465 | def | Type | `has_protected_access_to?` | missing |  | missing |
| 480 | def | Type | `same_namespace?` | missing |  | missing |
| 485 | def | Type | `top_namespace` | missing |  | missing |
| 513 | def | Type | `types` | other owner NamedType (src/compiler/semantic/top_level.iyi:156) | 5 reads, first src/compiler/iyi/codegen/cast.cr:525 | other-owner |
| 517 | def | Type | `types?` | missing | 2 reads, first src/compiler/iyi/codegen/codegen.cr:598 | missing |
| 521 | def | Type | `lookup_name` | missing |  | missing |
| 525 | def | Type | `parents` | other owner ModuleType (src/compiler/semantic/top_level.iyi:196) |  | other-owner |
| 529 | def | Type | `ancestors` | missing |  | missing |
| 535 | def | Type | `collect_ancestors` | missing |  | missing |
| 543 | def | Type | `superclass` | other owner GenericClassInstanceType (src/compiler/types/types.iyi:137) | 2 reads, first src/compiler/iyi/codegen/codegen.cr:2823 | other-owner |
| 547 | def | Type | `lookup_defs` | missing |  | missing |
| 553 | def | Type | `lookup_defs` | missing |  | missing |
| 581 | def | Type | `lookup_defs_without_parents` | missing |  | missing |
| 587 | def | Type | `lookup_defs_without_parents` | missing |  | missing |
| 593 | def | Type | `lookup_defs_with_modules` | missing |  | missing |
| 608 | def | Type | `lookup_first_def` | missing |  | missing |
| 613 | def | Type | `has_def?` | missing |  | missing |
| 617 | def | Type | `has_def_without_parents?` | missing |  | missing |
| 632 | def | Type | `lookup_macro` | missing |  | missing |
| 664 | def | Type | `lookup_macros` | missing |  | missing |
| 688 | def | Type | `add_including_type` | missing |  | missing |
| 692 | def | Type | `including_types` | missing |  | ported as TypeIntersect.including_union (src/compiler/types/intersect.iyi) |
| 699 | def | Type | `allows_instance_vars?` | missing |  | missing |
| 714 | def | Type | `instance_vars` | other owner ModuleType (src/compiler/semantic/top_level.iyi:197) | 4 reads, first src/compiler/iyi/codegen/codegen.cr:3430 | other-owner |
| 718 | def | Type | `class_vars` | other owner ModuleType (src/compiler/semantic/top_level.iyi:198) | 2 reads, first src/compiler/iyi/codegen/codegen.cr:3031 | other-owner |
| 722 | def | Type | `all_instance_vars` | other owner ModuleType (src/compiler/semantic/top_level.iyi:264) | 8 reads, first src/compiler/iyi/codegen/codegen.cr:2765 | other-owner |
| 730 | def | Type | `all_class_vars` | other owner ModuleType (src/compiler/semantic/top_level.iyi:288) |  | other-owner |
| 739 | def | Type | `index_of_instance_var` | missing | 4 reads, first src/compiler/iyi/codegen/codegen.cr:3433 | missing |
| 757 | def | Type | `lookup_instance_var` | missing | 3 reads, first src/compiler/iyi/codegen/codegen.cr:1916 | missing |
| 761 | def | Type | `lookup_instance_var?` | other owner ModuleType (src/compiler/semantic/top_level.iyi:211) |  | other-owner |
| 766 | def | Type | `lookup_class_var?` | other owner ModuleType (src/compiler/semantic/top_level.iyi:234) | 2 reads, first src/compiler/iyi/codegen/codegen.cr:523 | other-owner |
| 770 | def | Type | `lookup_class_var` | missing | 2 reads, first src/compiler/iyi/codegen/class_var.cr:356 | missing |
| 774 | def | Type | `has_instance_var_initializer?` | missing |  | missing |
| 778 | def | Type | `all_instance_vars_count` | missing |  | missing |
| 782 | def | Type | `lookup_similar_instance_var_name` | missing |  | missing |
| 795 | def | Type | `lookup_instance_var` | missing | 3 reads, first src/compiler/iyi/codegen/codegen.cr:1916 | missing |
| 812 | def | Type | `add_subclass` | missing |  | missing |
| 818 | def | Type | `replace_type_parameters` | missing |  | missing |
| 822 | def | Type | `depth` | missing |  | missing |
| 826 | def | Type | `type_desc` | ported (src/compiler/semantic/top_level.iyi:53) |  | ported |
| 830 | def | Type | `remove_alias` | missing | 3 reads, first src/compiler/iyi/codegen/ast.cr:167 | ported as TypeMerge.remove_alias (src/compiler/types/merge.iyi) |
| 834 | def | Type | `remove_alias_if_simple` | missing |  | missing |
| 838 | def | Type | `remove_indirection` | missing | 20 reads, first src/compiler/iyi/codegen/call.cr:465 | ported as TypeIndirection.remove_indirection (src/compiler/types/indirection.iyi) |
| 842 | def | Type | `remove_literal` | missing |  | missing |
| 846 | def | Type | `generic_nest` | missing |  | missing |
| 850 | def | Type | `double_variadic?` | missing |  | missing |
| 854 | def | Type | `splat_index` | ported as `TypeQueries.splat_index` (types/types.iyi) | 1 reads, first src/compiler/iyi/codegen/codegen.cr:2233 | ported |
| 858 | def | Type | `type_vars` | other owner GenericInstanceType (src/compiler/types/types.iyi:111) |  | other-owner |
| 862 | def | Type | `unbound?` | missing | 1 reads, first src/compiler/iyi/codegen/llvm_id.cr:154 | ported as TypeQueries.unbound? (src/compiler/types/types.iyi) |
| 866 | def | Type | `private?` | ported (src/compiler/semantic/top_level.iyi:107) |  | ported |
| 870 | def | Type | `private=` | missing |  | missing |
| 874 | def | Type | `type_var?` | missing |  | missing |
| 879 | def | Type | `sizeof_type` | missing | 4 reads, first src/compiler/iyi/codegen/codegen.cr:1292 | missing |
| 889 | def | Type | `get_instance_var_initializer` | missing |  | missing |
| 896 | def | Type | `check_restriction_exception` | missing |  | missing |
| 903 | def | Type | `all?` | missing |  | missing |
| 907 | def | Type | `to_s` | ported (src/compiler/semantic/top_level.iyi:45) |  | ported |
| 913 | def | Type | `inspect` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 917 | def | Type | `to_s` | ported (src/compiler/semantic/top_level.iyi:45) |  | ported |
| 921 | def | Type | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 923 | def | Type | `pretty_print` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 933 | class | NamedType | `NamedType` | ported class (src/compiler/semantic/top_level.iyi:155) |  | ported |
| 934 | attr | NamedType | `namespace` | other owner Type (src/compiler/semantic/top_level.iyi:21) | 2 reads, first src/compiler/iyi/codegen/const.cr:130 | other-owner |
| 935 | attr | NamedType | `name` | other owner NamedArgumentType (src/compiler/types/types.iyi:339) | 97 reads, first src/compiler/iyi/codegen/ast.cr:35 | other-owner |
| 936 | attr | NamedType | `locations` | missing |  | missing |
| 937 | attr | NamedType | `doc` | missing |  | missing |
| 940 | def | NamedType | `initialize` | ported (src/compiler/semantic/top_level.iyi:158) |  | ported |
| 945 | def | NamedType | `add_location` | missing |  | missing |
| 952 | def | NamedType | `types?` | missing | 2 reads, first src/compiler/iyi/codegen/codegen.cr:598 | missing |
| 956 | def | NamedType | `append_full_name` | missing |  | missing |
| 974 | def | NamedType | `full_name` | other owner VirtualType (src/compiler/types/types.iyi:21) |  | other-owner |
| 978 | def | NamedType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 993 | def | Iyi | `new` | missing |  | missing |
| 1000 | class | HookKind | `HookKind` | missing class |  | missing |
| 1037 | class | DefInstanceContainer | `DefInstanceContainer` | missing class |  | missing |
| 1040 | def | DefInstanceContainer | `add_def_instance` | missing |  | missing |
| 1045 | def | DefInstanceContainer | `lookup_def_instance` | missing |  | missing |
| 1055 | def | Iyi | `exports?` | missing |  | missing |
| 1068 | class | ModuleType | `ModuleType` | ported class (src/compiler/semantic/top_level.iyi:194) |  | ported |
| 1069 | attr | ModuleType | `defs` | ported (src/compiler/semantic/top_level.iyi:195) |  | ported |
| 1070 | attr | ModuleType | `macros` | ported (src/compiler/semantic/top_level.iyi:199) |  | ported |
| 1071 | attr | ModuleType | `hooks` | missing |  | missing |
| 1089 | def | ModuleType | `add_using_module` | missing |  | missing |
| 1099 | def | ModuleType | `using_modules?` | missing |  | missing |
| 1110 | attr | ModuleType | `iyi_unit_file` | missing |  | missing |
| 1114 | attr | ModuleType | `exported_names` | missing |  | missing |
| 1116 | def | ModuleType | `add_exported_name` | missing |  | missing |
| 1122 | def | ModuleType | `exported_name?` | missing |  | missing |
| 1129 | def | ModuleType | `add_def` | ported (src/compiler/semantic/top_level.iyi:320) |  | ported |
| 1163 | def | ModuleType | `add_macro` | ported (src/compiler/semantic/top_level.iyi:331) |  | ported |
| 1201 | def | ModuleType | `add_hook` | missing |  | missing |
| 1207 | def | ModuleType | `check_macro_param_count` | missing |  | missing |
| 1214 | def | ModuleType | `filter_by_responds_to` | other owner TypeFiltering (src/compiler/types/filtering.iyi:127) |  | other-owner |
| 1218 | def | ModuleType | `include` | ported (src/compiler/semantic/top_level.iyi:370) |  | ported |
| 1237 | def | ModuleType | `type_desc` | ported (src/compiler/semantic/top_level.iyi:316) |  | ported |
| 1243 | class | ClassVarContainer | `ClassVarContainer` | missing class |  | missing |
| 1246 | def | ClassVarContainer | `class_vars?` | missing | 1 reads, first src/compiler/iyi/codegen/codegen.cr:501 | missing |
| 1250 | def | ClassVarContainer | `lookup_class_var` | missing | 2 reads, first src/compiler/iyi/codegen/class_var.cr:356 | missing |
| 1254 | def | ClassVarContainer | `lookup_class_var?` | other owner ModuleType (src/compiler/semantic/top_level.iyi:234) | 2 reads, first src/compiler/iyi/codegen/codegen.cr:523 | other-owner |
| 1292 | class | SubclassObservable | `SubclassObservable` | missing class |  | missing |
| 1293 | def | SubclassObservable | `add_subclass_observer` | missing |  | missing |
| 1298 | def | SubclassObservable | `remove_subclass_observer` | missing |  | missing |
| 1302 | def | SubclassObservable | `notify_subclass_added` | missing |  | missing |
| 1312 | class | InstanceVarInitializerContainer | `InstanceVarInitializerContainer` | missing class |  | missing |
| 1313 | class | InstanceVarInitializer | `InstanceVarInitializer` | missing class |  | missing |
| 1314 | attr | InstanceVarInitializer | `name` | other owner NamedArgumentType (src/compiler/types/types.iyi:339) | 97 reads, first src/compiler/iyi/codegen/ast.cr:35 | other-owner |
| 1315 | attr | InstanceVarInitializer | `value` | other owner Const (src/compiler/semantic/top_level.iyi:521) | 64 reads, first src/compiler/iyi/codegen/call.cr:161 | other-owner |
| 1316 | attr | InstanceVarInitializer | `meta_vars` | missing | 2 reads, first src/compiler/iyi/codegen/class_var.cr:163 | missing |
| 1329 | attr | InstanceVarInitializer | `written` | missing |  | missing |
| 1331 | def | InstanceVarInitializer | `initialize` | other owner TypeSystem (src/compiler/types/type_system.iyi:17) |  | other-owner |
| 1336 | attr | InstanceVarInitializerContainer | `instance_vars_initializers` | missing | 1 reads, first src/compiler/iyi/codegen/codegen.cr:2835 | missing |
| 1338 | def | InstanceVarInitializerContainer | `add_instance_var_initializer` | missing |  | missing |
| 1367 | def | InstanceVarInitializerContainer | `has_instance_var_initializer?` | missing |  | missing |
| 1372 | def | InstanceVarInitializerContainer | `get_instance_var_initializer` | missing |  | missing |
| 1388 | class | InstanceVarContainer | `InstanceVarContainer` | missing class |  | missing |
| 1393 | class | NonGenericModuleType | `NonGenericModuleType` | ported class (src/compiler/semantic/top_level.iyi:474) |  | ported |
| 1398 | def | NonGenericModuleType | `add_including_type` | missing |  | missing |
| 1407 | def | NonGenericModuleType | `including_types` | missing |  | ported as TypeIntersect.including_union (src/compiler/types/intersect.iyi) |
| 1417 | def | NonGenericModuleType | `add_to_including_types` | missing |  | missing |
| 1425 | def | NonGenericModuleType | `raw_including_types` | missing |  | missing |
| 1429 | def | NonGenericModuleType | `remove_indirection` | missing | 20 reads, first src/compiler/iyi/codegen/call.cr:465 | ported as TypeIndirection.remove_indirection (src/compiler/types/indirection.iyi) |
| 1437 | def | NonGenericModuleType | `filter_by_responds_to` | other owner TypeFiltering (src/compiler/types/filtering.iyi:127) |  | other-owner |
| 1441 | def | NonGenericModuleType | `module?` | other owner GenericModuleInstanceType (src/compiler/types/types.iyi:212) |  | other-owner |
| 1445 | def | NonGenericModuleType | `add_instance_var_initializer` | missing |  | missing |
| 1466 | class | TraitSupertraits | `TraitSupertraits` | missing class |  | missing |
| 1467 | attr | TraitSupertraits | `supertraits` | other owner TraitType (src/compiler/semantic/top_level.iyi:494) |  | other-owner |
| 1470 | class | TraitType | `TraitType` | ported class (src/compiler/semantic/top_level.iyi:493) |  | ported |
| 1473 | def | TraitType | `trait?` | ported (src/compiler/semantic/top_level.iyi:503) |  | ported |
| 1477 | def | TraitType | `type_desc` | ported (src/compiler/semantic/top_level.iyi:507) |  | ported |
| 1483 | class | FileModule | `FileModule` | missing class |  | missing |
| 1488 | def | FileModule | `vars?` | missing |  | missing |
| 1492 | def | FileModule | `metaclass?` | other owner ModuleType (src/compiler/semantic/top_level.iyi:384) | 6 reads, first src/compiler/iyi/codegen/ast.cr:18 | other-owner |
| 1496 | def | FileModule | `metaclass` | other owner VirtualType (src/compiler/types/types.iyi:45) | 12 reads, first src/compiler/iyi/codegen/class_var.cr:397 | other-owner |
| 1503 | def | FileModule | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 1514 | class | ClassType | `ClassType` | ported class (src/compiler/semantic/top_level.iyi:409) |  | ported |
| 1519 | attr | ClassType | `metaclass` | other owner VirtualType (src/compiler/types/types.iyi:45) | 12 reads, first src/compiler/iyi/codegen/class_var.cr:397 | other-owner |
| 1520 | attr | ClassType | `superclass` | ported (src/compiler/semantic/top_level.iyi:410) | 2 reads, first src/compiler/iyi/codegen/codegen.cr:2823 | ported |
| 1521 | attr | ClassType | `subclasses` | ported (src/compiler/semantic/top_level.iyi:412) | 5 reads, first src/compiler/iyi/codegen/llvm_id.cr:104 | ported |
| 1522 | attr | ClassType | `depth` | missing |  | missing |
| 1532 | def | ClassType | `initialize` | ported (src/compiler/semantic/top_level.iyi:414) |  | ported |
| 1539 | def | ClassType | `superclass=` | missing |  | missing |
| 1544 | def | ClassType | `add_subclass` | missing |  | missing |
| 1557 | def | ClassType | `force_add_subclass` | missing |  | missing |
| 1561 | def | ClassType | `type_desc` | ported (src/compiler/semantic/top_level.iyi:433) |  | ported |
| 1574 | class | NonGenericClassType | `NonGenericClassType` | ported class (src/compiler/semantic/top_level.iyi:449) |  | ported |
| 1578 | def | NonGenericClassType | `initialize_metaclass` | missing |  | missing |
| 1582 | def | NonGenericClassType | `virtual_type` | missing | 5 reads, first src/compiler/iyi/codegen/ast.cr:110 | ported as TypeQueries.virtual_type (src/compiler/types/types.iyi) |
| 1594 | def | NonGenericClassType | `virtual_type!` | missing | 1 reads, first src/compiler/iyi/codegen/codegen.cr:517 | missing |
| 1598 | def | NonGenericClassType | `virtual_type_made?` | missing | 1 reads, first src/compiler/iyi/codegen/gc_layouts.cr:207 | missing |
| 1602 | def | NonGenericClassType | `class?` | other owner GenericClassInstanceType (src/compiler/types/types.iyi:154) |  | other-owner |
| 1608 | class | PrimitiveType | `PrimitiveType` | ported class (src/compiler/types/types.iyi:563) |  | ported |
| 1612 | attr | PrimitiveType | `bytes` | ported (src/compiler/types/types.iyi:564) | 32 reads, first src/compiler/iyi/codegen/llvm_typer.cr:136 | ported |
| 1614 | def | PrimitiveType | `initialize` | ported (src/compiler/types/types.iyi:566) |  | ported |
| 1619 | def | PrimitiveType | `abstract?` | other owner VirtualType (src/compiler/types/types.iyi:37) |  | other-owner |
| 1624 | class | BoolType | `BoolType` | ported class (src/compiler/types/types.iyi:604) |  | ported |
| 1627 | class | CharType | `CharType` | ported class (src/compiler/types/types.iyi:598) |  | ported |
| 1630 | class | IntegerType | `IntegerType` | ported class (src/compiler/types/types.iyi:580) |  | ported |
| 1631 | attr | IntegerType | `rank` | ported (src/compiler/types/types.iyi:581) |  | ported |
| 1632 | attr | IntegerType | `kind` | ported (src/compiler/types/types.iyi:582) |  | ported |
| 1634 | def | IntegerType | `initialize` | ported (src/compiler/types/types.iyi:585) |  | ported |
| 1638 | def | IntegerType | `signed?` | missing |  | missing |
| 1642 | def | IntegerType | `unsigned?` | missing |  | missing |
| 1646 | def | IntegerType | `bits` | missing |  | missing |
| 1650 | def | IntegerType | `normal_rank` | missing |  | missing |
| 1654 | def | IntegerType | `range` | missing |  | missing |
| 1684 | def | IntegerType | `subset_of?` | missing |  | missing |
| 1691 | def | IntegerType | `subset_of?` | missing |  | missing |
| 1707 | class | FloatType | `FloatType` | ported class (src/compiler/types/types.iyi:590) |  | ported |
| 1708 | attr | FloatType | `rank` | ported (src/compiler/types/types.iyi:591) |  | ported |
| 1710 | def | FloatType | `initialize` | ported (src/compiler/types/types.iyi:593) |  | ported |
| 1714 | def | FloatType | `kind` | other owner IntegerType (src/compiler/types/types.iyi:582) |  | other-owner |
| 1718 | def | FloatType | `range` | missing |  | missing |
| 1732 | def | FloatType | `subset_of?` | missing |  | missing |
| 1737 | def | FloatType | `subset_of?` | missing |  | missing |
| 1742 | class | SymbolType | `SymbolType` | ported class (src/compiler/types/types.iyi:610) |  | ported |
| 1745 | class | NilType | `NilType` | ported class (src/compiler/types/types.iyi:616) |  | ported |
| 1748 | class | NoReturnType | `NoReturnType` | ported class (src/compiler/types/types.iyi:622) |  | ported |
| 1750 | def | NoReturnType | `implements?` | other owner VirtualType (src/compiler/types/types.iyi:80) | 8 reads, first src/compiler/iyi/codegen/cast.cr:143 | other-owner |
| 1755 | class | VoidType | `VoidType` | ported class (src/compiler/types/types.iyi:636) |  | ported |
| 1758 | class | AutocastType | `AutocastType` | missing class |  | missing |
| 1760 | attr | AutocastType | `match` | missing |  | missing |
| 1770 | def | AutocastType | `save_matches` | missing |  | missing |
| 1775 | def | AutocastType | `restore_matches` | missing |  | missing |
| 1780 | def | AutocastType | `set_exact_match` | missing |  | missing |
| 1785 | def | AutocastType | `add_match` | missing |  | missing |
| 1798 | def | AutocastType | `exact_match?` | missing |  | missing |
| 1802 | def | AutocastType | `remove_literal` | missing |  | missing |
| 1806 | def | AutocastType | `check_restriction_exception` | missing |  | missing |
| 1823 | class | NumberAutocastType | `NumberAutocastType` | missing class |  | missing |
| 1825 | attr | NumberAutocastType | `literal` | missing |  | missing |
| 1827 | def | NumberAutocastType | `initialize` | other owner TypeSystem (src/compiler/types/type_system.iyi:17) |  | other-owner |
| 1831 | def | NumberAutocastType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 1838 | class | SymbolAutocastType | `SymbolAutocastType` | missing class |  | missing |
| 1840 | attr | SymbolAutocastType | `literal` | missing |  | missing |
| 1842 | def | SymbolAutocastType | `initialize` | other owner TypeSystem (src/compiler/types/type_system.iyi:17) |  | other-owner |
| 1846 | def | SymbolAutocastType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 1868 | class | GenericType | `GenericType` | missing class |  | missing |
| 1872 | attr | GenericType | `type_vars` | other owner GenericInstanceType (src/compiler/types/types.iyi:111) |  | other-owner |
| 1875 | attr | GenericType | `splat_index` | other owner GenericClassType (src/compiler/semantic/top_level.iyi:460) | 1 reads, first src/compiler/iyi/codegen/codegen.cr:2233 | other-owner |
| 1887 | def | GenericType | `instantiated_types` | missing | 1 reads, first src/compiler/iyi/codegen/llvm_id.cr:92 | missing |
| 1891 | def | GenericType | `each_instantiated_type` | missing | 1 reads, first src/compiler/iyi/codegen/llvm_id.cr:153 | missing |
| 1898 | def | GenericType | `type_parameter` | missing |  | missing |
| 1903 | def | GenericType | `instantiate` | missing |  | missing |
| 1984 | def | GenericType | `notify_parents_subclass_added` | missing |  | missing |
| 1991 | attr | GenericType | `inherited` | missing |  | missing |
| 1993 | def | GenericType | `add_inherited` | missing |  | missing |
| 1998 | def | GenericType | `add_instance_var_initializer` | missing |  | missing |
| 2016 | def | GenericType | `run_instance_vars_initializers` | missing |  | missing |
| 2026 | def | GenericType | `run_instance_vars_initializers` | missing |  | missing |
| 2030 | def | GenericType | `run_instance_var_initializer` | missing |  | missing |
| 2051 | def | GenericType | `run_instance_var_initializer` | missing |  | missing |
| 2055 | def | GenericType | `instantiated_generic_superclass` | missing |  | missing |
| 2063 | def | GenericType | `type_var?` | missing |  | missing |
| 2094 | class | TypeParameter | `TypeParameter` | ported class (src/compiler/types/types.iyi:646) |  | ported |
| 2096 | attr | TypeParameter | `owner` | other owner PendingIvar (src/compiler/semantic/top_level.iyi:1121) | 18 reads, first src/compiler/iyi/codegen/call.cr:90 | other-owner |
| 2099 | attr | TypeParameter | `name` | other owner NamedArgumentType (src/compiler/types/types.iyi:339) | 97 reads, first src/compiler/iyi/codegen/ast.cr:35 | other-owner |
| 2101 | def | TypeParameter | `initialize` | ported (src/compiler/types/types.iyi:649) |  | ported |
| 2105 | def | TypeParameter | `replace_type_parameters` | missing |  | missing |
| 2114 | def | TypeParameter | `solve` | missing |  | missing |
| 2118 | def | TypeParameter | `solve?` | missing |  | missing |
| 2128 | def | TypeParameter | `unbound?` | missing | 1 reads, first src/compiler/iyi/codegen/llvm_id.cr:154 | ported as TypeQueries.unbound? (src/compiler/types/types.iyi) |
| 2132 | def | TypeParameter | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 2154 | class | TypeSplat | `TypeSplat` | ported class (src/compiler/types/types.iyi:658) |  | ported |
| 2155 | attr | TypeSplat | `splatted_type` | ported (src/compiler/types/types.iyi:659) |  | ported |
| 2157 | def | TypeSplat | `initialize` | ported (src/compiler/types/types.iyi:661) |  | ported |
| 2161 | def | TypeSplat | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 2167 | class | GenericModuleType | `GenericModuleType` | ported class (src/compiler/semantic/top_level.iyi:477) |  | ported |
| 2171 | def | GenericModuleType | `initialize` | ported (src/compiler/semantic/top_level.iyi:481) |  | ported |
| 2175 | def | GenericModuleType | `module?` | other owner GenericModuleInstanceType (src/compiler/types/types.iyi:212) |  | other-owner |
| 2179 | def | GenericModuleType | `can_be_stored?` | missing |  | missing |
| 2183 | def | GenericModuleType | `type_desc` | other owner VirtualType (src/compiler/types/types.iyi:29) |  | other-owner |
| 2187 | def | GenericModuleType | `add_including_type` | missing |  | missing |
| 2192 | def | GenericModuleType | `raw_including_types` | missing |  | missing |
| 2196 | def | GenericModuleType | `new_generic_instance` | missing |  | missing |
| 2200 | def | GenericModuleType | `add_instance_var_initializer` | missing |  | missing |
| 2204 | def | GenericModuleType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 2228 | class | GenericTraitType | `GenericTraitType` | ported class (src/compiler/semantic/top_level.iyi:512) |  | ported |
| 2232 | attr | GenericTraitType | `assoc_types` | other owner TraitType (src/compiler/semantic/top_level.iyi:495) |  | other-owner |
| 2235 | def | GenericTraitType | `trait_params` | missing |  | missing |
| 2242 | def | GenericTraitType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 2258 | def | GenericTraitType | `trait?` | other owner GenericTraitInstanceType (src/compiler/types/types.iyi:236) |  | other-owner |
| 2262 | def | GenericTraitType | `type_desc` | other owner VirtualType (src/compiler/types/types.iyi:29) |  | other-owner |
| 2268 | class | GenericClassType | `GenericClassType` | ported class (src/compiler/semantic/top_level.iyi:458) |  | ported |
| 2272 | def | GenericClassType | `initialize` | ported (src/compiler/semantic/top_level.iyi:462) |  | ported |
| 2276 | def | GenericClassType | `class?` | other owner GenericClassInstanceType (src/compiler/types/types.iyi:154) |  | other-owner |
| 2280 | def | GenericClassType | `can_be_stored?` | missing |  | missing |
| 2284 | def | GenericClassType | `new_generic_instance` | missing |  | missing |
| 2288 | def | GenericClassType | `initialize_metaclass` | missing |  | missing |
| 2292 | def | GenericClassType | `type_desc` | other owner VirtualType (src/compiler/types/types.iyi:29) |  | other-owner |
| 2296 | def | GenericClassType | `including_types` | missing |  | ported as TypeIntersect.including_union (src/compiler/types/intersect.iyi) |
| 2309 | def | GenericClassType | `remove_indirection` | missing | 20 reads, first src/compiler/iyi/codegen/call.cr:465 | ported as TypeIndirection.remove_indirection (src/compiler/types/indirection.iyi) |
| 2317 | def | GenericClassType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 2355 | class | GenericInstanceType | `GenericInstanceType` | ported class (src/compiler/types/types.iyi:109) |  | ported |
| 2356 | attr | GenericInstanceType | `generic_type` | ported (src/compiler/types/types.iyi:110) |  | ported |
| 2357 | attr | GenericInstanceType | `type_vars` | ported (src/compiler/types/types.iyi:111) |  | ported |
| 2361 | def | GenericInstanceType | `initialize` | ported (src/compiler/types/types.iyi:114) |  | ported |
| 2365 | def | GenericInstanceType | `class_var_owner` | missing |  | missing |
| 2369 | def | GenericInstanceType | `parents` | other owner ModuleType (src/compiler/semantic/top_level.iyi:196) |  | other-owner |
| 2375 | def | GenericInstanceType | `replace_type_parameters` | missing |  | missing |
| 2419 | def | GenericInstanceType | `implements?` | other owner VirtualType (src/compiler/types/types.iyi:80) | 8 reads, first src/compiler/iyi/codegen/cast.cr:143 | other-owner |
| 2436 | def | GenericInstanceType | `implements?` | other owner VirtualType (src/compiler/types/types.iyi:80) | 8 reads, first src/compiler/iyi/codegen/cast.cr:143 | other-owner |
| 2441 | def | GenericInstanceType | `has_in_type_vars?` | missing |  | missing |
| 2450 | def | GenericInstanceType | `unbound?` | missing | 1 reads, first src/compiler/iyi/codegen/llvm_id.cr:154 | ported as TypeQueries.unbound? (src/compiler/types/types.iyi) |
| 2459 | def | GenericInstanceType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 2495 | class | GenericClassInstanceType | `GenericClassInstanceType` | ported class (src/compiler/types/types.iyi:136) |  | ported |
| 2501 | attr | GenericClassInstanceType | `superclass` | ported (src/compiler/types/types.iyi:137) | 2 reads, first src/compiler/iyi/codegen/codegen.cr:2823 | ported |
| 2502 | attr | GenericClassInstanceType | `subclasses` | ported (src/compiler/types/types.iyi:138) | 5 reads, first src/compiler/iyi/codegen/llvm_id.cr:104 | ported |
| 2503 | attr | GenericClassInstanceType | `generic_nest` | missing |  | missing |
| 2505 | def | GenericClassInstanceType | `initialize` | ported (src/compiler/types/types.iyi:141) |  | ported |
| 2510 | def | GenericClassInstanceType | `after_initialize` | missing |  | missing |
| 2517 | def | GenericClassInstanceType | `add_subclass` | missing |  | missing |
| 2530 | def | GenericClassInstanceType | `virtual_type` | missing | 5 reads, first src/compiler/iyi/codegen/ast.cr:110 | ported as TypeQueries.virtual_type (src/compiler/types/types.iyi) |
| 2542 | def | GenericClassInstanceType | `virtual_type!` | missing | 1 reads, first src/compiler/iyi/codegen/codegen.cr:517 | missing |
| 2546 | def | GenericClassInstanceType | `virtual_type_made?` | missing | 1 reads, first src/compiler/iyi/codegen/gc_layouts.cr:207 | missing |
| 2554 | def | GenericClassInstanceType | `filter_by_responds_to` | other owner TypeFiltering (src/compiler/types/filtering.iyi:127) |  | other-owner |
| 2558 | def | GenericClassInstanceType | `class?` | ported (src/compiler/types/types.iyi:154) |  | ported |
| 2566 | class | GenericModuleInstanceType | `GenericModuleInstanceType` | ported class (src/compiler/types/types.iyi:204) |  | ported |
| 2572 | attr | GenericModuleInstanceType | `generic_nest` | missing |  | missing |
| 2574 | def | GenericModuleInstanceType | `initialize` | ported (src/compiler/types/types.iyi:207) |  | ported |
| 2579 | def | GenericModuleInstanceType | `after_initialize` | missing |  | missing |
| 2585 | def | GenericModuleInstanceType | `virtual_type` | missing | 5 reads, first src/compiler/iyi/codegen/ast.cr:110 | ported as TypeQueries.virtual_type (src/compiler/types/types.iyi) |
| 2593 | def | GenericModuleInstanceType | `add_including_type` | missing |  | missing |
| 2604 | def | GenericModuleInstanceType | `including_types` | missing |  | ported as TypeIntersect.including_union (src/compiler/types/intersect.iyi) |
| 2614 | def | GenericModuleInstanceType | `add_to_including_types` | missing |  | missing |
| 2622 | def | GenericModuleInstanceType | `raw_including_types` | missing |  | missing |
| 2626 | def | GenericModuleInstanceType | `remove_indirection` | missing | 20 reads, first src/compiler/iyi/codegen/call.cr:465 | ported as TypeIndirection.remove_indirection (src/compiler/types/indirection.iyi) |
| 2634 | def | GenericModuleInstanceType | `filter_by_responds_to` | other owner TypeFiltering (src/compiler/types/filtering.iyi:127) |  | other-owner |
| 2638 | def | GenericModuleInstanceType | `module?` | ported (src/compiler/types/types.iyi:212) |  | ported |
| 2646 | class | PointerType | `PointerType` | missing class |  | missing |
| 2647 | def | PointerType | `new_generic_instance` | missing |  | missing |
| 2651 | def | PointerType | `type_desc` | other owner VirtualType (src/compiler/types/types.iyi:29) |  | other-owner |
| 2657 | class | PointerInstanceType | `PointerInstanceType` | ported class (src/compiler/types/types.iyi:465) |  | ported |
| 2658 | def | PointerInstanceType | `var` | missing | 9 reads, first src/compiler/iyi/codegen/class_var.cr:101 | missing |
| 2662 | def | PointerInstanceType | `element_type` | ported (src/compiler/types/types.iyi:466) | 23 reads, first src/compiler/iyi/codegen/abi.cr:74 | ported |
| 2666 | def | PointerInstanceType | `type_desc` | ported (src/compiler/types/types.iyi:481) |  | ported |
| 2672 | class | StaticArrayType | `StaticArrayType` | missing class |  | missing |
| 2673 | def | StaticArrayType | `new_generic_instance` | missing |  | missing |
| 2696 | class | StaticArrayInstanceType | `StaticArrayInstanceType` | ported class (src/compiler/types/types.iyi:490) |  | ported |
| 2697 | def | StaticArrayInstanceType | `var` | missing | 9 reads, first src/compiler/iyi/codegen/class_var.cr:101 | missing |
| 2701 | def | StaticArrayInstanceType | `size` | other owner TupleInstanceType (src/compiler/types/types.iyi:318) |  | other-owner |
| 2705 | def | StaticArrayInstanceType | `element_type` | ported (src/compiler/types/types.iyi:491) | 23 reads, first src/compiler/iyi/codegen/abi.cr:74 | ported |
| 2711 | class | ProcType | `ProcType` | missing class |  | missing |
| 2715 | def | ProcType | `instantiate` | missing |  | missing |
| 2740 | def | ProcType | `can_be_stored?` | missing |  | missing |
| 2744 | def | ProcType | `new_generic_instance` | missing |  | missing |
| 2748 | def | ProcType | `type_desc` | other owner VirtualType (src/compiler/types/types.iyi:29) |  | other-owner |
| 2754 | class | ProcInstanceType | `ProcInstanceType` | ported class (src/compiler/types/types.iyi:414) |  | ported |
| 2755 | attr | ProcInstanceType | `arg_types` | ported (src/compiler/types/types.iyi:415) | 10 reads, first src/compiler/iyi/codegen/call.cr:298 | ported |
| 2756 | attr | ProcInstanceType | `return_type` | ported (src/compiler/types/types.iyi:416) | 15 reads, first src/compiler/iyi/codegen/call.cr:244 | ported |
| 2758 | def | ProcInstanceType | `initialize` | ported (src/compiler/types/types.iyi:418) |  | ported |
| 2768 | def | ProcInstanceType | `struct?` | ported (src/compiler/types/types.iyi:441) | 19 reads, first src/compiler/iyi/codegen/codegen.cr:2503 | ported |
| 2772 | def | ProcInstanceType | `implements?` | other owner VirtualType (src/compiler/types/types.iyi:80) | 8 reads, first src/compiler/iyi/codegen/cast.cr:143 | other-owner |
| 2782 | def | ProcInstanceType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 2797 | class | TupleType | `TupleType` | missing class |  | missing |
| 2801 | def | TupleType | `instantiate` | missing |  | missing |
| 2818 | def | TupleType | `new_generic_instance` | missing |  | missing |
| 2822 | def | TupleType | `type_desc` | other owner VirtualType (src/compiler/types/types.iyi:29) |  | other-owner |
| 2828 | class | TupleInstanceType | `TupleInstanceType` | ported class (src/compiler/types/types.iyi:289) |  | ported |
| 2831 | attr | TupleInstanceType | `tuple_types` | ported (src/compiler/types/types.iyi:290) | 16 reads, first src/compiler/iyi/codegen/cast.cr:255 | ported |
| 2833 | def | TupleInstanceType | `initialize` | ported (src/compiler/types/types.iyi:292) |  | ported |
| 2841 | def | TupleInstanceType | `tuple_indexer` | missing |  | missing |
| 2846 | def | TupleInstanceType | `tuple_metaclass_indexer` | missing |  | missing |
| 2851 | def | TupleInstanceType | `size` | ported (src/compiler/types/types.iyi:318) |  | ported |
| 2855 | def | TupleInstanceType | `tuple_indexer` | missing |  | missing |
| 2864 | def | TupleInstanceType | `implements?` | other owner VirtualType (src/compiler/types/types.iyi:80) | 8 reads, first src/compiler/iyi/codegen/cast.cr:143 | other-owner |
| 2875 | def | TupleInstanceType | `var` | missing | 9 reads, first src/compiler/iyi/codegen/class_var.cr:101 | missing |
| 2879 | def | TupleInstanceType | `has_in_type_vars?` | missing |  | missing |
| 2883 | def | TupleInstanceType | `replace_type_parameters` | missing |  | missing |
| 2900 | def | TupleInstanceType | `unbound?` | missing | 1 reads, first src/compiler/iyi/codegen/llvm_id.cr:154 | ported as TypeQueries.unbound? (src/compiler/types/types.iyi) |
| 2904 | def | TupleInstanceType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 2913 | def | TupleInstanceType | `type_desc` | ported (src/compiler/types/types.iyi:306) |  | ported |
| 2919 | class | NamedTupleType | `NamedTupleType` | missing class |  | missing |
| 2924 | def | NamedTupleType | `instantiated_types` | missing | 1 reads, first src/compiler/iyi/codegen/llvm_id.cr:92 | missing |
| 2928 | def | NamedTupleType | `each_instantiated_type` | missing | 1 reads, first src/compiler/iyi/codegen/llvm_id.cr:153 | missing |
| 2932 | def | NamedTupleType | `instantiate` | missing |  | missing |
| 2936 | def | NamedTupleType | `instantiate_named_args` | missing |  | missing |
| 2940 | def | NamedTupleType | `new_generic_instance` | missing |  | missing |
| 2944 | def | NamedTupleType | `type_desc` | other owner VirtualType (src/compiler/types/types.iyi:29) |  | other-owner |
| 2950 | class | NamedTupleInstanceType | `NamedTupleInstanceType` | ported class (src/compiler/types/types.iyi:350) |  | ported |
| 2951 | attr | NamedTupleInstanceType | `entries` | ported (src/compiler/types/types.iyi:351) | 9 reads, first src/compiler/iyi/codegen/cast.cr:269 | ported |
| 2953 | def | NamedTupleInstanceType | `initialize` | ported (src/compiler/types/types.iyi:353) |  | ported |
| 2961 | def | NamedTupleInstanceType | `name_index` | missing |  | missing |
| 2965 | def | NamedTupleInstanceType | `name_type` | ported (src/compiler/types/types.iyi:384) | 2 reads, first src/compiler/iyi/codegen/cast.cr:273 | ported |
| 2969 | def | NamedTupleInstanceType | `tuple_indexer` | missing |  | missing |
| 2974 | def | NamedTupleInstanceType | `tuple_metaclass_indexer` | missing |  | missing |
| 2979 | def | NamedTupleInstanceType | `tuple_indexer` | missing |  | missing |
| 2988 | def | NamedTupleInstanceType | `implements?` | other owner VirtualType (src/compiler/types/types.iyi:80) | 8 reads, first src/compiler/iyi/codegen/cast.cr:143 | other-owner |
| 3003 | def | NamedTupleInstanceType | `size` | ported (src/compiler/types/types.iyi:380) |  | ported |
| 3007 | def | NamedTupleInstanceType | `var` | missing | 9 reads, first src/compiler/iyi/codegen/class_var.cr:101 | missing |
| 3011 | def | NamedTupleInstanceType | `replace_type_parameters` | missing |  | missing |
| 3018 | def | NamedTupleInstanceType | `unbound?` | missing | 1 reads, first src/compiler/iyi/codegen/llvm_id.cr:154 | ported as TypeQueries.unbound? (src/compiler/types/types.iyi) |
| 3022 | def | NamedTupleInstanceType | `has_in_type_vars?` | missing |  | missing |
| 3026 | def | NamedTupleInstanceType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 3043 | def | NamedTupleInstanceType | `type_desc` | ported (src/compiler/types/types.iyi:368) |  | ported |
| 3049 | class | GenericReferenceStorageType | `GenericReferenceStorageType` | missing class |  | missing |
| 3052 | def | GenericReferenceStorageType | `new_generic_instance` | missing |  | missing |
| 3064 | class | ReferenceStorageType | `ReferenceStorageType` | missing class |  | missing |
| 3065 | attr | ReferenceStorageType | `reference_type` | other owner SemanticProgram (src/compiler/semantic/top_level.iyi:674) | 2 reads, first src/compiler/iyi/codegen/llvm_typer.cr:270 | other-owner |
| 3067 | def | ReferenceStorageType | `initialize` | other owner TypeSystem (src/compiler/types/type_system.iyi:17) |  | other-owner |
| 3076 | class | LibType | `LibType` | missing class |  | missing |
| 3077 | attr | LibType | `link_annotations` | missing | 1 reads, first src/compiler/iyi/codegen/link.cr:366 | missing |
| 3079 | attr | LibType | `call_convention` | missing | 3 reads, first src/compiler/iyi/codegen/call.cr:661 | missing |
| 3081 | def | LibType | `add_link_annotation` | missing |  | missing |
| 3086 | def | LibType | `metaclass` | other owner VirtualType (src/compiler/types/types.iyi:45) | 12 reads, first src/compiler/iyi/codegen/class_var.cr:397 | other-owner |
| 3090 | def | LibType | `lookup_var` | missing |  | missing |
| 3100 | def | LibType | `type_desc` | other owner VirtualType (src/compiler/types/types.iyi:29) |  | other-owner |
| 3104 | def | LibType | `wasm_import_module` | missing | 1 reads, first src/compiler/iyi/codegen/fun.cr:565 | missing |
| 3110 | class | TypeDefType | `TypeDefType` | missing class |  | missing |
| 3113 | attr | TypeDefType | `typedef` | missing | 10 reads, first src/compiler/iyi/codegen/cast.cr:247 | missing |
| 3115 | def | TypeDefType | `initialize` | other owner TypeSystem (src/compiler/types/type_system.iyi:17) |  | other-owner |
| 3122 | def | TypeDefType | `remove_indirection` | missing | 20 reads, first src/compiler/iyi/codegen/call.cr:465 | ported as TypeIndirection.remove_indirection (src/compiler/types/indirection.iyi) |
| 3126 | def | TypeDefType | `type_def_type?` | missing |  | missing |
| 3130 | def | TypeDefType | `type_desc` | other owner VirtualType (src/compiler/types/types.iyi:29) |  | other-owner |
| 3136 | class | AliasType | `AliasType` | ported class (src/compiler/semantic/top_level.iyi:564) |  | ported |
| 3141 | def | AliasType | `initialize` | ported (src/compiler/semantic/top_level.iyi:569) |  | ported |
| 3149 | def | AliasType | `lookup_name` | missing |  | missing |
| 3154 | def | AliasType | `remove_alias` | missing | 3 reads, first src/compiler/iyi/codegen/ast.cr:167 | ported as TypeMerge.remove_alias (src/compiler/types/merge.iyi) |
| 3164 | def | AliasType | `remove_alias_if_simple` | missing |  | missing |
| 3169 | def | AliasType | `remove_indirection` | missing | 20 reads, first src/compiler/iyi/codegen/call.cr:465 | ported as TypeIndirection.remove_indirection (src/compiler/types/indirection.iyi) |
| 3179 | def | AliasType | `can_be_stored?` | missing |  | missing |
| 3188 | def | AliasType | `process_value` | ported (src/compiler/semantic/top_level.iyi:581) |  | ported |
| 3196 | def | AliasType | `includes_type?` | missing | 1 reads, first src/compiler/iyi/codegen/class_var.cr:44 | missing |
| 3200 | def | AliasType | `type_desc` | ported (src/compiler/semantic/top_level.iyi:577) |  | ported |
| 3225 | class | EnumType | `EnumType` | ported class (src/compiler/semantic/top_level.iyi:538) |  | ported |
| 3229 | attr | EnumType | `base_type` | ported (src/compiler/semantic/top_level.iyi:539) | 18 reads, first src/compiler/iyi/codegen/class_var.cr:220 | ported |
| 3232 | def | EnumType | `initialize` | ported (src/compiler/semantic/top_level.iyi:542) |  | ported |
| 3239 | def | EnumType | `parents` | other owner ModuleType (src/compiler/semantic/top_level.iyi:196) |  | other-owner |
| 3243 | def | EnumType | `add_constant` | missing |  | missing |
| 3251 | def | EnumType | `lookup_new_in_ancestors?` | missing |  | missing |
| 3255 | def | EnumType | `find_member` | missing |  | missing |
| 3265 | def | EnumType | `type_desc` | ported (src/compiler/semantic/top_level.iyi:552) |  | ported |
| 3270 | class | AnnotationType | `AnnotationType` | missing class |  | missing |
| 3271 | def | AnnotationType | `type_desc` | other owner VirtualType (src/compiler/types/types.iyi:29) |  | other-owner |
| 3283 | class | MetaclassType | `MetaclassType` | ported class (src/compiler/semantic/top_level.iyi:389) |  | ported |
| 3286 | attr | MetaclassType | `instance_type` | ported (src/compiler/semantic/top_level.iyi:390) | 14 reads, first src/compiler/iyi/codegen/ast.cr:19 | ported |
| 3288 | def | MetaclassType | `initialize` | ported (src/compiler/semantic/top_level.iyi:392) |  | ported |
| 3306 | def | MetaclassType | `metaclass` | other owner VirtualType (src/compiler/types/types.iyi:45) | 12 reads, first src/compiler/iyi/codegen/class_var.cr:397 | other-owner |
| 3313 | def | MetaclassType | `class_var_owner` | missing |  | missing |
| 3317 | def | MetaclassType | `virtual_type` | missing | 5 reads, first src/compiler/iyi/codegen/ast.cr:110 | ported as TypeQueries.virtual_type (src/compiler/types/types.iyi) |
| 3321 | def | MetaclassType | `virtual_type!` | missing | 1 reads, first src/compiler/iyi/codegen/codegen.cr:517 | missing |
| 3325 | def | MetaclassType | `remove_typedef` | missing | 6 reads, first src/compiler/iyi/codegen/codegen.cr:1931 | ported (src/compiler/semantic/top_level.iyi) |
| 3332 | def | MetaclassType | `replace_type_parameters` | missing |  | missing |
| 3336 | def | MetaclassType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 3346 | def | MetaclassType | `type_desc` | ported (src/compiler/semantic/top_level.iyi:404) |  | ported |
| 3352 | class | GenericClassInstanceMetaclassType | `GenericClassInstanceMetaclassType` | ported class (src/compiler/types/types.iyi:245) |  | ported |
| 3355 | attr | GenericClassInstanceMetaclassType | `instance_type` | other owner VirtualMetaclassType (src/compiler/types/types.iyi:86) | 14 reads, first src/compiler/iyi/codegen/ast.cr:19 | other-owner |
| 3357 | def | GenericClassInstanceMetaclassType | `initialize` | ported (src/compiler/types/types.iyi:246) |  | ported |
| 3361 | def | GenericClassInstanceMetaclassType | `metaclass` | other owner VirtualType (src/compiler/types/types.iyi:45) | 12 reads, first src/compiler/iyi/codegen/class_var.cr:397 | other-owner |
| 3365 | def | GenericClassInstanceMetaclassType | `add_subclass` | missing |  | missing |
| 3369 | def | GenericClassInstanceMetaclassType | `superclass` | other owner GenericClassInstanceType (src/compiler/types/types.iyi:137) | 2 reads, first src/compiler/iyi/codegen/codegen.cr:2823 | other-owner |
| 3373 | def | GenericClassInstanceMetaclassType | `parents` | other owner ModuleType (src/compiler/semantic/top_level.iyi:196) |  | other-owner |
| 3379 | def | GenericClassInstanceMetaclassType | `generic_type` | other owner GenericInstanceType (src/compiler/types/types.iyi:110) |  | other-owner |
| 3383 | def | GenericClassInstanceMetaclassType | `implements?` | other owner VirtualType (src/compiler/types/types.iyi:80) | 8 reads, first src/compiler/iyi/codegen/cast.cr:143 | other-owner |
| 3388 | def | GenericClassInstanceMetaclassType | `replace_type_parameters` | missing |  | missing |
| 3392 | def | GenericClassInstanceMetaclassType | `virtual_type` | missing | 5 reads, first src/compiler/iyi/codegen/ast.cr:110 | ported as TypeQueries.virtual_type (src/compiler/types/types.iyi) |
| 3396 | def | GenericClassInstanceMetaclassType | `virtual_type!` | missing | 1 reads, first src/compiler/iyi/codegen/codegen.cr:517 | missing |
| 3403 | def | GenericClassInstanceMetaclassType | `class_var_owner` | missing |  | missing |
| 3407 | def | GenericClassInstanceMetaclassType | `filter_by_responds_to` | other owner TypeFiltering (src/compiler/types/filtering.iyi:127) |  | other-owner |
| 3415 | def | GenericClassInstanceMetaclassType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 3420 | def | GenericClassInstanceMetaclassType | `type_desc` | ported (src/compiler/types/types.iyi:262) |  | ported |
| 3426 | class | GenericModuleInstanceMetaclassType | `GenericModuleInstanceMetaclassType` | ported class (src/compiler/types/types.iyi:267) |  | ported |
| 3429 | attr | GenericModuleInstanceMetaclassType | `instance_type` | other owner VirtualMetaclassType (src/compiler/types/types.iyi:86) | 14 reads, first src/compiler/iyi/codegen/ast.cr:19 | other-owner |
| 3431 | def | GenericModuleInstanceMetaclassType | `initialize` | ported (src/compiler/types/types.iyi:268) |  | ported |
| 3435 | def | GenericModuleInstanceMetaclassType | `metaclass` | other owner VirtualType (src/compiler/types/types.iyi:45) | 12 reads, first src/compiler/iyi/codegen/class_var.cr:397 | other-owner |
| 3439 | def | GenericModuleInstanceMetaclassType | `add_subclass` | missing |  | missing |
| 3443 | def | GenericModuleInstanceMetaclassType | `parents` | other owner ModuleType (src/compiler/semantic/top_level.iyi:196) |  | other-owner |
| 3449 | def | GenericModuleInstanceMetaclassType | `generic_type` | other owner GenericInstanceType (src/compiler/types/types.iyi:110) |  | other-owner |
| 3453 | def | GenericModuleInstanceMetaclassType | `implements?` | other owner VirtualType (src/compiler/types/types.iyi:80) | 8 reads, first src/compiler/iyi/codegen/cast.cr:143 | other-owner |
| 3458 | def | GenericModuleInstanceMetaclassType | `replace_type_parameters` | missing |  | missing |
| 3465 | def | GenericModuleInstanceMetaclassType | `class_var_owner` | missing |  | missing |
| 3469 | def | GenericModuleInstanceMetaclassType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 3474 | def | GenericModuleInstanceMetaclassType | `type_desc` | ported (src/compiler/types/types.iyi:284) |  | ported |
| 3480 | class | MultiType | `MultiType` | missing class |  | missing |
| 3481 | def | MultiType | `concrete_types` | missing |  | missing |
| 3487 | def | MultiType | `union_types` | other owner UnionType (src/compiler/semantic/top_level.iyi:604) | 21 reads, first src/compiler/iyi/codegen/cast.cr:128 | other-owner |
| 3494 | class | GenericUnionType | `GenericUnionType` | missing class |  | missing |
| 3498 | def | GenericUnionType | `instantiate` | missing |  | missing |
| 3517 | def | GenericUnionType | `new_generic_instance` | missing |  | missing |
| 3521 | def | GenericUnionType | `type_desc` | other owner VirtualType (src/compiler/types/types.iyi:29) |  | other-owner |
| 3527 | class | UnionType | `UnionType` | ported class (src/compiler/semantic/top_level.iyi:603) |  | ported |
| 3530 | attr | UnionType | `union_types` | ported (src/compiler/semantic/top_level.iyi:604) | 21 reads, first src/compiler/iyi/codegen/cast.cr:128 | ported |
| 3532 | def | UnionType | `initialize` | ported (src/compiler/semantic/top_level.iyi:606) |  | ported |
| 3536 | def | UnionType | `parents` | other owner ModuleType (src/compiler/semantic/top_level.iyi:196) |  | other-owner |
| 3540 | def | UnionType | `superclass` | other owner GenericClassInstanceType (src/compiler/types/types.iyi:137) | 2 reads, first src/compiler/iyi/codegen/codegen.cr:2823 | other-owner |
| 3544 | def | UnionType | `generic_type` | other owner GenericInstanceType (src/compiler/types/types.iyi:110) |  | other-owner |
| 3548 | def | UnionType | `metaclass` | other owner VirtualType (src/compiler/types/types.iyi:45) | 12 reads, first src/compiler/iyi/codegen/class_var.cr:397 | other-owner |
| 3552 | def | UnionType | `generic_nest` | missing |  | missing |
| 3556 | def | UnionType | `includes_type?` | missing | 1 reads, first src/compiler/iyi/codegen/class_var.cr:44 | missing |
| 3560 | def | UnionType | `filter_by_responds_to` | other owner TypeFiltering (src/compiler/types/filtering.iyi:127) |  | other-owner |
| 3565 | def | UnionType | `each_concrete_type` | missing | 1 reads, first src/compiler/iyi/codegen/match.cr:175 | missing |
| 3589 | def | UnionType | `virtual_type` | missing | 5 reads, first src/compiler/iyi/codegen/ast.cr:110 | ported as TypeQueries.virtual_type (src/compiler/types/types.iyi) |
| 3597 | def | UnionType | `implements?` | other owner VirtualType (src/compiler/types/types.iyi:80) | 8 reads, first src/compiler/iyi/codegen/cast.cr:143 | other-owner |
| 3602 | def | UnionType | `replace_type_parameters` | missing |  | missing |
| 3627 | def | UnionType | `unbound?` | missing | 1 reads, first src/compiler/iyi/codegen/llvm_id.cr:154 | ported as TypeQueries.unbound? (src/compiler/types/types.iyi) |
| 3631 | def | UnionType | `all?` | missing |  | missing |
| 3635 | def | UnionType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 3650 | def | UnionType | `type_desc` | other owner VirtualType (src/compiler/types/types.iyi:29) |  | other-owner |
| 3658 | class | NilableType | `NilableType` | ported class (src/compiler/types/types.iyi:516) |  | ported |
| 3659 | def | NilableType | `initialize` | ported (src/compiler/types/types.iyi:519) |  | ported |
| 3663 | def | NilableType | `not_nil_type` | ported (src/compiler/types/types.iyi:517) | 3 reads, first src/compiler/iyi/codegen/debug.cr:253 | ported |
| 3671 | class | NilableReferenceUnionType | `NilableReferenceUnionType` | ported class (src/compiler/types/types.iyi:536) |  | ported |
| 3676 | class | ReferenceUnionType | `ReferenceUnionType` | ported class (src/compiler/types/types.iyi:542) |  | ported |
| 3680 | class | NilableProcType | `NilableProcType` | ported class (src/compiler/types/types.iyi:548) |  | ported |
| 3681 | def | NilableProcType | `initialize` | ported (src/compiler/types/types.iyi:551) |  | ported |
| 3685 | def | NilableProcType | `proc_type` | ported (src/compiler/types/types.iyi:549) | 3 reads, first src/compiler/iyi/codegen/debug.cr:368 | ported |
| 3694 | class | MixedUnionType | `MixedUnionType` | ported class (src/compiler/types/types.iyi:560) |  | ported |
| 3710 | class | Const | `Const` | ported class (src/compiler/semantic/top_level.iyi:520) |  | ported |
| 3711 | attr | Const | `value` | ported (src/compiler/semantic/top_level.iyi:521) | 64 reads, first src/compiler/iyi/codegen/call.cr:161 | ported |
| 3716 | attr | Const | `declared_type` | ported (src/compiler/semantic/top_level.iyi:522) |  | ported |
| 3718 | attr | Const | `fake_def` | missing |  | missing |
| 3736 | attr | Const | `iyi_value_source` | missing |  | missing |
| 3741 | attr | Const | `iyi_safe_reach` | missing |  | missing |
| 3746 | attr | Const | `visitor` | missing |  | missing |
| 3748 | def | Const | `initialize` | ported (src/compiler/semantic/top_level.iyi:525) |  | ported |
| 3752 | def | Const | `type_desc` | ported (src/compiler/semantic/top_level.iyi:533) |  | ported |
| 3757 | class | VirtualTypeLookup | `VirtualTypeLookup` | missing class |  | missing |
| 3758 | def | VirtualTypeLookup | `filter_by_responds_to` | other owner TypeFiltering (src/compiler/types/filtering.iyi:127) |  | other-owner |
| 3767 | def | VirtualTypeLookup | `collect_filtered_by_responds_to` | missing |  | missing |
| 3803 | class | VirtualType | `VirtualType` | ported class (src/compiler/types/types.iyi:8) |  | ported |
| 3811 | attr | VirtualType | `base_type` | ported (src/compiler/types/types.iyi:9) | 18 reads, first src/compiler/iyi/codegen/class_var.cr:220 | ported |
| 3813 | def | VirtualType | `initialize` | ported (src/compiler/types/types.iyi:12) |  | ported |
| 3823 | def | VirtualType | `remove_indirection` | missing | 20 reads, first src/compiler/iyi/codegen/call.cr:465 | ported as TypeIndirection.remove_indirection (src/compiler/types/indirection.iyi) |
| 3831 | def | VirtualType | `metaclass` | ported (src/compiler/types/types.iyi:45) | 12 reads, first src/compiler/iyi/codegen/class_var.cr:397 | ported |
| 3835 | def | VirtualType | `each_concrete_type` | missing | 1 reads, first src/compiler/iyi/codegen/match.cr:175 | missing |
| 3841 | def | VirtualType | `subtypes` | ported (src/compiler/types/types.iyi:55) |  | ported |
| 3847 | def | VirtualType | `subtypes` | ported (src/compiler/types/types.iyi:55) |  | ported |
| 3855 | def | VirtualType | `collect_subtypes` | ported (src/compiler/types/types.iyi:61) |  | ported |
| 3862 | def | VirtualType | `lookup_class_var?` | other owner ModuleType (src/compiler/semantic/top_level.iyi:234) | 2 reads, first src/compiler/iyi/codegen/codegen.cr:523 | other-owner |
| 3880 | def | VirtualType | `all_class_vars` | other owner ModuleType (src/compiler/semantic/top_level.iyi:288) |  | other-owner |
| 3887 | def | VirtualType | `replace_type_parameters` | missing |  | missing |
| 3891 | def | VirtualType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 3896 | def | VirtualType | `name` | other owner NamedArgumentType (src/compiler/types/types.iyi:339) | 97 reads, first src/compiler/iyi/codegen/ast.cr:35 | other-owner |
| 3901 | class | VirtualMetaclassType | `VirtualMetaclassType` | ported class (src/compiler/types/types.iyi:85) |  | ported |
| 3907 | attr | VirtualMetaclassType | `instance_type` | ported (src/compiler/types/types.iyi:86) | 14 reads, first src/compiler/iyi/codegen/ast.cr:19 | ported |
| 3909 | def | VirtualMetaclassType | `initialize` | ported (src/compiler/types/types.iyi:88) |  | ported |
| 3913 | def | VirtualMetaclassType | `metaclass` | ported (src/compiler/types/types.iyi:104) | 12 reads, first src/compiler/iyi/codegen/class_var.cr:397 | ported |
| 3917 | def | VirtualMetaclassType | `parents` | other owner ModuleType (src/compiler/semantic/top_level.iyi:196) |  | other-owner |
| 3921 | def | VirtualMetaclassType | `leaf?` | other owner VirtualType (src/compiler/types/types.iyi:41) |  | other-owner |
| 3930 | def | VirtualMetaclassType | `replace_type_parameters` | missing |  | missing |
| 3934 | def | VirtualMetaclassType | `each_concrete_type` | missing | 1 reads, first src/compiler/iyi/codegen/match.cr:175 | missing |
| 3940 | def | VirtualMetaclassType | `lookup_class_var?` | other owner ModuleType (src/compiler/semantic/top_level.iyi:234) | 2 reads, first src/compiler/iyi/codegen/codegen.cr:523 | other-owner |
| 3958 | def | VirtualMetaclassType | `implements?` | other owner VirtualType (src/compiler/types/types.iyi:80) | 8 reads, first src/compiler/iyi/codegen/cast.cr:143 | other-owner |
| 3962 | def | VirtualMetaclassType | `to_s_with_options` | out of scope: Crystal-only inspection/printing |  | out-of-scope |
| 3967 | def | VirtualMetaclassType | `type_desc` | ported (src/compiler/types/types.iyi:100) |  | ported |
| 3973 | def | (top) | `add_to_including_types` | missing |  | missing |
| 3988 | def | (top) | `add_to_including_types` | missing |  | missing |
| 3992 | def | (top) | `add_to_including_types` | missing |  | missing |
| 3997 | def | (top) | `add_instance_var_initializer` | missing |  | missing |
