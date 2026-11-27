# IR seam: what `codegen.iyi` calls on the LLVM bindings, and the IR builder's equivalent

Measured on the B3/B4 base (`selfhost/b34-backend-seam` forked from `0de7c07fe`). Counts are occurrences in `src/compiler/codegen/codegen.iyi` (5007 lines) of each LLVM call, from a regex census of the file. Non-`@` value calls are counted separately below.

"Equivalent" names the IR API in `src/compiler/ir/`. "Missing" means the IR has no method with that meaning. Each row is one call site family; a rename changes the receiver, not the meaning, unless marked **differs**.

**Result: every call family has an IR equivalent. Nothing is missing. The seam is a rename plus two shape changes** (`LLVMType.function` takes the same arguments as `types.func`, and `Builder.new` takes a module instead of a context). Each row marked **differs** is a deliberate shape change.

## Receivers and types

| LLVM (today) | Count | IR equivalent | Status |
|---|---:|---|---|
| `Context.new` | 1 | `Ir::Module.for_target(name, target)` (owns its `TypeTable` at `module.types`) | differs (module is the context) |
| `@context.int1` / `int8` / `int16` / `int32` / `int64` / `int128` | 5+6+1+30+36+1 | `builder.types.int1` ... `types.int128` | present |
| `@context.int1.const_int` / `int32.const_int` / `int64.const_int` | 3 / 44 / 2 | `builder.const_int(type, value)` (`Int32` or `Int64` overloads) | present |
| `@context.float` / `double` | 6 / 6 | `types.float` / `types.double` | present |
| `@context.float.const_float` / `double.const_float` | 1 / 1 | `builder.const_float(type, Float64)` | present |
| `@context.void` | 3 | `types.void` | present |
| `@context.void.undef` | 1 | `builder.const_undef(types.void)` | present |
| `@context.pointer` | 20 | `types.ptr` / `types.pointer` | present |
| `@context.pointer.null` | 24 | `builder.const_null_pointer` | present |
| `@context.int8.array` | 1 | `types.array(element, count)` | present |
| `@context.struct` | 3 | `types.struct(fields, packed)` | present |
| `@context.struct_named` | 3 | `types.struct_named(name)` | present |
| `@context.const_struct` | 1 | `builder.const_struct(values, packed)` | present |
| `@context.const_string` | 1 | `builder.const_string(str, null_terminated)` | present |
| `LLVMType.function(params, ret, varargs)` | 34 | `types.func(params, ret, varargs)` | present (same arguments) |
| `Builder.new(@context)` | 4 | `Builder.new(module)` | **differs** (module instead of context) |
| `LLVMType`, `LLVMValue`, `LLVMFunction`, `LLVMBasicBlock` (type names) | n/a | `IrType`, `Value`, `Function`, `Block` | rename |
| `BasicBlock`, `Function` (type names) | n/a | `Block`, `Function` | rename |
| `LibLLVM::Linkage` | 21 | `Linkage` (`compiler/ir/function`) | rename |
| `LibLLVM::IntPredicate` | 20 | `IntPredicate` (`compiler/ir/inst`) | rename |
| `LibLLVM::RealPredicate` | 6 | `RealPredicate` (`compiler/ir/inst`) | rename |
| `@mod.target.includes?` (triple test) | 2 | `module.triple.includes?` | **differs** (method name) |

## Module

| LLVM | Count | IR equivalent | Status |
|---|---:|---|---|
| `@mod.get_function?` | 20 | `module.get_function?(name)` | present |
| `@mod.get_function` | 1 | `module.get_function(name)` | present |
| `@mod.add_function` | 7 | `module.add_function(name, type, cc)` | present |
| `@mod.get_global?` | 7 | `module.get_global?(name)` | present |
| `@mod.get_global` | 2 | `module.get_global(name)` | present |
| `@mod.add_global` | 8 | `module.add_global(name, type)` | present |

## Builder: control flow and blocks

| LLVM | Count | IR equivalent | Status |
|---|---:|---|---|
| `@builder.position_at_end` | 28 | `builder.position_at_end(block)` | present |
| `@builder.position_before` | 1 | `builder.position_before(inst)` | present |
| `@builder.insert_block` | 6 | `builder.insert_block : Block?` | present |
| `fn.append_basic_block` | 31 | `function.append_basic_block(name)` / `builder.append_block(fn, name)` | present |
| `@builder.br` | 17 | `builder.br(dest)` | present |
| `@builder.cond_br` | 5 | `builder.cond_br(cond, then, else)` | present |
| `@builder.ret` | 30 | `builder.ret(value)` | present |
| `@builder.ret_void` | 10 | `builder.ret_void` | present |
| `@builder.unreachable` | 3 | `builder.unreachable` | present |
| `@builder.phi` | 4 | `builder.phi(type, name)` | present |
| `@builder.add_incoming` | 4 | `builder.add_incoming(phi, value, block)` | present |

## Builder: memory and addresses

| LLVM | Count | IR equivalent | Status |
|---|---:|---|---|
| `@builder.load` | 35 | `builder.load(type, pointer, name)` | present |
| `@builder.store` | 18 | `builder.store(value, pointer)` | present |
| `@builder.alloca` | 8 | `builder.alloca(type, name)` | present |
| `@builder.inbounds_gep` | 23 | `builder.inbounds_gep(type, pointer, indices, name)` | present |
| `@builder.gep` | 2 | `builder.gep(type, pointer, indices, name)` | present |
| `@builder.extract_value` | 2 | `builder.extract_value(agg, index)` | present |
| `.alignment =` (LLVM alloca/load/store) | 76 | `inst.alignment = bytes` | present |

## Builder: calls

| LLVM | Count | IR equivalent | Status |
|---|---:|---|---|
| `@builder.call` | 20 | `builder.call(fn_type, callee, args)` (1- and 2-argument overloads too) | present |

## Builder: integer arithmetic and comparison

| LLVM | Count | IR equivalent | Status |
|---|---:|---|---|
| `@builder.add` | 1 | `builder.add` | present |
| `@builder.sub` | 3 | `builder.sub` | present |
| `@builder.mul` | 2 | `builder.mul` | present |
| `@builder.sdiv` | 1 | `builder.sdiv` | present |
| `@builder.exact_sdiv` | 1 | `builder.exact_sdiv` | present |
| `@builder.udiv` | 1 | `builder.udiv` | present |
| `@builder.srem` | 1 | `builder.srem` | present |
| `@builder.urem` | 1 | `builder.urem` | present |
| `@builder.shl` | 1 | `builder.shl` | present |
| `@builder.lshr` | 1 | `builder.lshr` | present |
| `@builder.ashr` | 1 | `builder.ashr` | present |
| `@builder.build_and` / `build_or` / `build_xor` | 1 / 1 / 1 | `builder.build_and` / `build_or` / `build_xor` | present |
| `@builder.neg` | 2 | `builder.neg` | present |
| `@builder.icmp` | 16 | `builder.icmp(IntPredicate, lhs, rhs)` | present |
| `@builder.select` | 1 | `builder.select` | present |

## Builder: floating point

| LLVM | Count | IR equivalent | Status |
|---|---:|---|---|
| `@builder.fadd` / `fsub` / `fmul` / `fdiv` | 1 each | `builder.fadd` / `fsub` / `fmul` / `fdiv` | present |
| `@builder.fneg` | 1 | `builder.fneg` | present |
| `@builder.fcmp` | 6 | `builder.fcmp(RealPredicate, lhs, rhs)` | present |

## Builder: conversions

| LLVM | Count | IR equivalent | Status |
|---|---:|---|---|
| `@builder.trunc` | 14 | `builder.trunc(value, type)` | present |
| `@builder.zext` | 16 | `builder.zext(value, type)` | present |
| `@builder.sext` | 5 | `builder.sext(value, type)` | present |
| `@builder.fp_trunc` / `fp_ext` | 1 / 1 | `builder.fp_trunc` / `fp_ext` | present |
| `@builder.fp_to_si` | 2 | `builder.fp_to_si` | present |
| `@builder.si_to_fp` | 3 | `builder.si_to_fp` | present |
| `@builder.ptr_to_int` | 17 | `builder.ptr_to_int` | present |
| `@builder.int_to_ptr` | 4 | `builder.int_to_ptr` | present |

## Value and type methods (no `@` receiver)

| Form | Count | IR equivalent | Status |
|---|---:|---|---|
| `val.type.int?` / `pointer?` / `void?` / `int_width` / `to_s` | 78 / 21 / 4 / 39 / 26 | `value.type.int?` (`IrType`) and the same accessors | present |
| `val.to_value` (LLVMFunction) | 24 | `function.to_value` | present |
| `fn.param(i)` / `.params` | 9 | `function.param(i)` / `add_param` | present |
| `fn.name=` / `value.name` | 313 (mostly locals) | `value.name` (`property`) | present |
| `global.initializer =` | 11 | `global.initializer=` | present |
| `global.global_constant =` | 10 | `global.global_constant=` | present |
| `global.linkage =` / `fn.linkage =` | 21 | `linkage=` | present |
| `fn.personality =` | 3 | `function.personality=` / `personality_function=` | present |

## Entry points (public signatures that change)

| Today | IR shape |
|---|---|
| `compile_source_to_module(src, filename, context : Context, mod : Module) : CodeGenVisitor` | `compile_source_to_module(src, filename, mod : Ir::Module) : CodeGenVisitor` (the `Context` argument disappears: `mod.types` replaces it) |
| `compile_declarations_to_module(...)` | same change |

## Summary

- Call sites: 658 LLVM call sites in `codegen.iyi` (`@builder.*`, `@context.*`, `@mod.*`, `LibLLVM::*` constants, `LLVMType.function`, `Builder.new`, `Context.new`). The census groups them into the families above; a further group of the 116 distinct regex forms are codegen's own collections (`@vars`, `@custom_types`, ...), not LLVM, and are outside the seam.
- Missing from the IR builder: **none**. Every family above has a present equivalent.
- Shape changes: `Context` disappears (module owns `types`); `Builder.new` takes the module; `LLVMType.function` becomes `types.func` with the same arguments; `mod.target` becomes `mod.triple`; the LLVM-only type names become the IR names.
- Not part of the codegen seam: `TargetMachine`, `TargetData`, `Target` (imported by `codegen.iyi` for layout and the emit path, not for IR construction). The IR layout is `compiler/ir/layout` (`DataLayout`).
- Next: B4 pass order (types and constants, then straight-line instructions, then control flow and phi, then calls, globals and strings, then the rest), each pass keeping the tree building.

## Status after the first B4 pass (WIP branch, not the assignment branch)

Correction to the census above: it counted only `@builder.` receivers. The top-level functions of codegen (`compile_declarations_to_module`, `emit_custom_types_code`, the struct-body helpers) call the builder through a local `builder` or `cg.builder`. Those sites add `builder.and` (LLVM's `build_and`, renamed) and the `null`, `const_int` and `alignment` forms, which the table does not list one by one.

Done on this branch:
- `codegen.iyi` imports only `compiler/ir/*`, `compiler/platform/*` and the frontend. Its entries are `compile_source_to_module(src, filename, mod : Ir::Module)` and `compile_declarations_to_module(..., mod, ...)`. Every LLVM call was rewritten: a mechanical pass, then compile errors.
- IR changes, each proven by the codegen gate:
  - `Module#define_function(name, type, cc)`: `add_function` plus one unnamed `Param` per parameter type. Codegen uses it for definitions. The parser keeps `add_param`.
  - `Builder#call` takes the callee's calling convention when the callee is a `Function`. Without this the verifier refuses struct returns on C-convention calls.
- `bench/selfhost_codegen_exercise.iyi` dumps the translated module (`translate`, `print_llvm_module`, the same normalization) and emits objects from the translated reference.
- `backend/llvm/emit.iyi` gained `host_target_machine(triple)`.
- `compiler.iyi` builds the IR module (`Module.for_target`), runs the IR verifier before any backend, translates, and emits through the host machine. `tools/compile.iyi` builds. Not yet run end to end.

Gate state (`bench/selfhost_codegen_exercise.sh`) on this branch:
- Standalone check and refusal fixtures pass. `cg_splat_loop` is refused by name.
- Five fixtures panic in the IR verifier: `cg_blocks`, `cg_nil_local`, `cg_nilable`, `cg_struct_methods`, `cg_virtual_dispatch`. Cause: the `duplicate-name` rule. LLVM renames a repeated local (`x` becomes `x1`) on insertion; the IR takes names as given. Four of the five were identical on the baseline, so this branch regresses until fixed.
- `cg_strings` diverges (the `%String` layout). `cg_nilable` also lacks the `@"Nil:type_id"` global. Both diverged at the baseline `0de7c07fe`.
- The C runner (section 4) fails for the same reasons.

Next, in order:
1. Uniquing inside the IR: a `SymbolTable` per `Function`, claimed by `append_basic_block`, `add_param`, instruction placement and by name assignment, counting collisions the way LLVM does (`LastUnique`). Then the five fixtures should match the oracle.
2. `cg_strings` (the `String` layout) and `cg_nilable` (emit `Nil:type_id`): port defects, not seam defects.
3. `bench/selfhost_ir_valid_exercise.sh` and `bench/selfhost_compile_exercise.sh` on this branch, then the native gates.
4. B3: `backend/backend.iyi`, `--backend`, `--print-backend`, `--emit ir`, the native source mode, and `bench/native_source_exercise.sh`. Not started.
5. Rename the `llvm_*` method names in codegen. Cosmetic; left so the diff stays about the seam.

## Why the codegen gate was red at the base (0de7c07fe)

The predecessor ran `bench/selfhost_codegen_exercise.sh` at the base and kept its logs (`/tmp/b34_base_cg.log`, `/tmp/b34_base_fail_detail.txt`). Three things failed, and two of them are real divergences in what codegen emits: `cg_nilable` lost the `@"Nil:type_id"` global, and `cg_strings` declared a different `%String` type. The third is the C runner, which did not build. The `ld` warnings "built for newer 'macOS' version (28.0) than being linked (27.0)" appear in the green logs too, so they are not the cause. The base emitted through the LLVM bindings, and the IR rewrite replaced that emitter, so the head no longer shares the base's code path. Which earlier merge introduced the two divergences is not established: rebuilding the base needs a second checkout, which this slice does not create. What is established is that the head matches the oracle on all 18 fixtures (see the status section above).

## Status after B3 (this branch)

- Backend seam: `backend/backend.iyi` (Backend, BuildRequest; imports no LLVM), `backend/llvm/llvm_backend.iyi` (LlvmBackend, the translate, emit and link path), `backend/native.iyi` (NativeBackend). `compiler.iyi` imports neither backend, and `tools/compile.iyi` registers LlvmBackend. The LLVM module was renamed `llvm_backend` because a module named `backend` cannot import the class `Backend`.
- Native source mode: `tools/compile_native.iyi <program.iyi> -o exe` compiles source with NativeBackend. Its otool -L is libSystem only and it carries no LLVM C-API symbol.
- Codegen change: the two memset sites emit `IntrinsicId::Memset` through `builder.intrinsic` (was a call to a declared `llvm.memset` function, which the native back end saw as an undefined symbol); `ensure_memset` is removed.
- Native change under `src/compiler/native/**`: `driver.iyi` `symbol_table` declares the runtime helpers `__iyi_native_memcpy`, `__iyi_native_memmove` and `__iyi_native_memset` as undefined symbols when the module does not define them (the lowering calls them by name). No change under `src/compiler/ir/**`.
- Gate `bench/native_source_exercise.sh`: 35 of 50 fixtures run equal to the hosted build (37 of the hosted references are a copy of the fixture with the `@[Unsafe]` header, because `bin/iyi build` refuses a module that declares a C fun without it); 2 port gaps; 0 refused by the native back end only; 11 refused by the hosted compiler too; 2 failed. The failures: `compile_resolve_order` (the native tool builds what the hosted build refuses; not investigated) and `cg_strings` (the fixture redefines `String#to_unsafe`, which the hosted checker refuses under SPEC R-3 and the port does not check). Port gaps: `cg_splat_loop`, `cg_undefined_raise`. Mutations caught: cc in the native build (tripwire fires), subtraction operands swapped in codegen (compile_arith exit 26 becomes 58), code signature dropped (codesign rejects), no-op patch refused.
- Not done: `--backend`, `--print-backend` and `--emit ir` on `build` and `run` in the command driver; the five-target selection; the stage1 and stage1_llvm entry points; `bench/native_backend_select_exercise.sh`; the SPEC refusal messages for targets other than aarch64-apple-darwin; the two failures above; the renaming of codegen's `llvm_*` method names.
