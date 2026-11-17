# Typer parity: the lowering against the hosted typer

Measured by `bench/selfhost_lower_types_exercise.sh` on the head of `selfhost/s2b-typer`, for the host target `aarch64-apple-darwin`. A type is identical when the port's block equals the hosted oracle's block byte for byte. A block holds `llvm_type`, `llvm_type(wants_size)`, `llvm_struct_type`, `offsets`, `llvm_embedded_type`, `size`, `align`, `passed_by_value`, `ivars`, `layout` (the pointer map, without the type id), the C types, `passed_indirectly`, and the proc function types.

## Fixtures (bare, gate-compared)

| fixture | types | identical |
|---|---|---|
| `lowty_primitives` | 18 | 18 |
| `lowty_pointers` | 6 | 6 |
| `lowty_enums` | 4 | 4 |
| `lowty_composites` | 6 | 6 |
| `lowty_unions` | 7 | 7 |
| `lowty_refunions` (new) | 2 | 2 |
| `lowty_procs` | 4 | 4 |
| `lowty_class_explicit` (iyi object layout) | 1 | 1 |
| `lowty_class_layout` (Crystal object layout) | 1 | 1 |
| `lowty_class_pointers` | 2 | 2 |
| `lowty_class_assigned` (ivars typed by assignment) | 1 | 1 |
| **total (12 fixtures)** | **56** | **56** |

Type ids are gated by shape in `lowtyid_hierarchy` (the port's ids equal the hosted ids shifted by 30). Exact equality waits on NEEDS.md row 16.

## Own source: every type each file declares (the floor)

The whole-program mode (`--own <file> <triple>`) loads the file's import closure with the prelude, as a build does, declares the instance variables, and prints one block per type the file declares. Constants are not types: the hosted typer does not lower them, so both sides skip them (before this increment the hosted side printed them as failures, 255 of the 1001 blocks). The gate compares the blocks by type name and checks each file against `bench/selfhost_lower_types.floor`, which may only rise.

| | before (4370c655e) | after (this increment) |
|---|---|---|
| declared types, own source | 1001 (255 of them constants) | 746 |
| measured (the port lowers the file) | 688 | 688 |
| identical | 283 | **407** |
| differ | 405 | 281 |
| in a file the port cannot lower | 58 | 58 |

- 134 files under `src/compiler/**/*.iyi`; 118 measured, 16 port failures (the LibLLVM lib types, row 3 below).
- The hosted oracle fails no file.

### What changed in this increment

- **Namespaces and the file's own module (NEEDS row 19).** A namespace answers `i1`, the hosted `NonGenericModuleType` answer. The file's own module (`module a/b/c`, an iyi unit, `ModuleType#iyi_unit`) answers `i32`. Before, every namespace answered `i32`: 118 types differed for that reason alone.
- **Reference unions are one pointer (NEEDS row 20).** The typer decides from the members (`reference_union?`): when every member but Nil is reference-like, the union is `ptr`, passed as a word, and the layout walk scans it. The port's unification builds a `MixedUnionType` for some of them, so the typer cannot rely on the object's kind.
- **Driver prints ivar types as the hosted `to_s` does** (`TypeRenderer.render`), so `Array(String)` and `Foo+` print as the hosted does. Before, a generic instance printed its bare name.

### Ranked reasons (gate output, 281 types that differ)

The reason of a type is the root cause of its first difference, not the first printed field that differs: an instance variable recorded in another order moves every later offset, and that is one reason. `bench/lib/lower_types_compare.py` prints the same table on every run (`REASON` and `EXAMPLE` lines).

| # | types | reason | owner | NEEDS row |
|---|---|---|---|---|
| 1 | 115 | ivars recorded in a different order: an ivar whose type names a type declared later in the file is recorded after the ivars that resolve at once. Repro: `/tmp/s2b/t1.iyi` (`@n : Int32?` before `@v : Visibility?`). | declarations trunk (S1b6, `semantic/top_level.iyi`) | 12 |
| 2 | 101 | generic instance ivar types are the unbound generic (`@a : Array(String)` is `Array(T)`, lowered as i1). Repro: `/tmp/s2b/t4.iyi`. | declarations trunk (S1b6, `semantic/type_declaration_processor.cr`) | 22 |
| 3 | 51 | ivar typed by a class with subclasses prints `X` where hosted prints `X+` (the port does not build the virtual type). The ivar line differs, so the layout behind it is not measured yet. | declarations / type model (S1a) | 24 |
| 4 | 12 | `getter`/`property` declared ivars are not recorded (`ir/module.iyi`). | declarations trunk (S1b6) | 23 |
| 5 | 1 | `InstAux` size 48 where the port says 40 (open: a mixed union or a field alignment; next increment). | typer (S2b) | none |
| 6 | 1 | extern struct llvm name: hosted `struct.Name` for an `extern` struct, the port `Name` (no `extern?` on the port's class). | typer (S2b) after NEEDS row 4 | 4 |

Port failures (a file the port cannot lower counts zero; the 58 types are in these 16 files):

- `undefined constant LibLLVM::MemoryBufferRef` (10 files), `LibLLVM::TypeRef` (3), `LibLLVM::ModuleRef` (2): lib types not in the closure. Repro: `port --own src/compiler/backend/llvm/emit.iyi aarch64-apple-darwin`. Declarations trunk.
- `create_llvm_type for Compiler::Semantic::Typed::AnalysedProgram is not ported`: 1 file. Typer, to do.

Sum: 407 identical + 281 differ + 58 in failed files = 746.

## Hello and the prelude

`samples/iyi/hello.iyi` with the prelude: not measured in this increment. The own-source mode covers a file's own declared types; the program-wide count (every type the program instantiates) needs a driver mode that walks the whole analysed program. Next increment.

## Gate figures

- Fixtures: 12 identical (56 types), 0 diverged.
- Own source: 118 measured, 407 identical of 746 declared, floors in `bench/selfhost_lower_types.floor`, all at floor.
- Type ids: 1 fixture (`lowtyid_hierarchy`) agrees in shape.
- Mutations: 32 caught, including the new `reference union lowered as a mixed union` (caught by the own-source probe `syntax/ast.iyi`, since the bare fixtures already reach a `ReferenceUnionType` through the unification), `the file's own module answers i1` and `mixed unions not passed by value`.

## Next increments, in order

1. Re-measure after S1b6 lands the declaration-order and generic-argument fixes (rows 12, 22). Those two reasons are 216 of the 281.
2. `AnalysedProgram` and the `InstAux` size (reasons 5 and the typer item above).
3. Type ids: exact equality (row 16), metaclass ids (`assign_id_to_metaclass`), generic instantiated ids (row 17).
4. `gc_layouts.cr` remainder: virtual struct fields and `ReferenceStorageType` in the layout walk (row 18).
5. `samples/iyi/hello.iyi` with the prelude: the program-wide count.
