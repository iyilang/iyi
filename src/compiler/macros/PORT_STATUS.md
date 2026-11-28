# Macro port status (slice S1g)

Hosted macro methods (`src/compiler/iyi/macros/methods.cr`, one `when` dispatch per
AST type) against the port (`src/compiler/macros/*.iyi`).

- **hosted on**: the hosted types whose `interpret` dispatch answers the name.
- **port**: `named` when a `when "name"` in the port's macro dispatch answers it,
  `not yet` otherwise. This is name-level. The per-type record is in "Checked per
  type" below, and only that section says a name works for a type.
- **uses**: occurrences of `.name` inside `{% %}` and `{{ }}` across the prelude
  (`src/iyi`), std (`src/std`) and the port's source. These counts describe the
  integration source tree and have not been measured for this component's base.

## Interpreter forms (increment 3)

Each form has a fixture, and the gate compares its per-site dump with the hosted
compiler's: `if`/`unless`/`elsif`/`else`, `for` over arrays, tuples, hashes, named
tuples and ranges (with index variables), `begin` blocks, `verbatim` blocks, macro
variables and their scope, `@type`, `@top_level`, `@def`, `env`, `flag?`,
`host_flag?` (always the host's set), `raise` (message and location), undefined
macro variables and methods, `skip_file`, `puts`, `print`, and `debug(format: false)`.
`yield` is written as `begin ... end`, as the hosted compiler writes it. Refused:
`system` and the backtick with hosted's sentence, and `run` by name.

## File methods and the package

`read_file`, `read_file?` and `file_exists?` resolve their path and check it as
hosted `iyi_macro_checked_path` does (`src/compiler/iyi/macros/methods.cr` 40-243).
The macro's package is the longest of the compiling package and the standard
library roots that holds the file the macro was written in (its definition's
file), else the nearest ancestor with an `iyi.mod`, else the file's own directory.
A path resolves through links, the missing tail is appended, and a `..` in the
tail is applied after the links before it. A dangling link is refused. The
standard library roots come from `IYI_PATH` and apply to `read_file`,
`read_file?` and `file_exists?` only, as hosted's `library: true` does. `env` is
allowed only where the macro's package is the compiling package.

The embedding program supplies the context (`MacroConfinement`: the compiling
package, the library roots, and the directory relative paths resolve against).
The engine passes it to each interpreter. The port has no module table, so
hosted's dependency roots from it have no counterpart: a dependency is its nearest
`iyi.mod` ancestor, or its own directory. With no context, these methods and
`env` are refused with `cannot determine the package of this compile-time macro`;
they never fall back to reading. The gate's section 2c compares each case with the
hosted oracle.

Read from code only, not run on Linux or Windows: path separators, drive letters,
junctions and case-insensitive volumes. On Windows the port resolves a path with
the standard library's `File.real_path` (`GetFinalPathNameByHandleW`), as hosted
does, and refuses a `\\?\` verbatim path, since it does not strip the prefix the
way hosted's `Iyi.unverbatim` does.

## Methods

| uses | method | hosted on | port |
|---:|---|---|---|
| 297 | `id` | ASTNode | named |
| 66 | `size` | HashLiteral, NamedTupleLiteral, StringLiteral, TypeNode | named |
| 39 | `stringify` | ASTNode, MacroId, SymbolLiteral | named |
| 27 | `keys` | HashLiteral, NamedTupleLiteral, TypeNode | named |
| 23 | `symbolize` | ASTNode, MacroId, SymbolLiteral | named |
| 20 | `includes?` | StringLiteral | named |
| 13 | `nilable?` | TypeNode | not yet |
| 11 | `name` | Alias, Annotation, AnnotationDef, Arg, CStructOrUnionDef, Call, ClassDef, ClassVar, Def, EnumDef, Extend, ExternalVar, FunDef, Generic, Global, Include, InstanceVar, LibDef, Macro, MacroVar, MetaMacroVar, ModuleDef, NamedArgument, Primitive, ProcPointer, ReadInstanceVar, Rescue, RespondsTo, TypeDef, TypeNode | named |
| 10 | `constant` | TypeNode | not yet |
| 9 | `empty?` | HashLiteral, NamedTupleLiteral, StringLiteral | named |
| 8 | `annotation` | Arg, Def, MetaMacroVar, TypeNode | not yet |
| 8 | `strip` | StringLiteral | named |
| 7 | `constants` | TypeNode | not yet |
| 7 | `has_constant?` | TypeNode | not yet |
| 7 | `instance_vars` | TypeNode | not yet |
| 6 | `starts_with?` | StringLiteral | named |
| 6 | `type` | Alias, ArrayLiteral, ExternalVar, HashLiteral, MetaMacroVar, OffsetOf, TypeDeclaration, TypeDef, UninitializedVar | named |
| 6 | `var` | TypeDeclaration, UninitializedVar | named |
| 3 | `gsub` | StringLiteral | not yet |
| 3 | `has_default_value?` | MetaMacroVar | not yet |
| 2 | `/` | NumberLiteral | named |
| 2 | `args` | Annotation, Block, Call, Def, FunDef, Macro, ProcLiteral, ProcPointer, TypeOf | named |
| 2 | `chomp` | StringLiteral | not yet |
| 2 | `class?` | TypeNode | not yet |
| 2 | `downcase` | StringLiteral | named |
| 2 | `exp` | AsmOperand, ControlExpression, MacroExpression, MacroFor, UnaryExpression, VisibilityModifier | not yet |
| 2 | `map` | HashLiteral, NamedTupleLiteral, RangeLiteral | not yet |
| 2 | `named_args` | Annotation, Call, Generic | not yet |
| 2 | `reject` | HashLiteral, NamedTupleLiteral | not yet |
| 2 | `select` | HashLiteral, NamedTupleLiteral | not yet |
| 2 | `split` | StringLiteral | not yet |
| 2 | `target` | Assign | not yet |
| 2 | `union?` | CStructOrUnionDef, TypeNode | not yet |
| 1 | `*` | NumberLiteral, StringLiteral | named |
| 1 | `ancestors` | TypeNode | not yet |
| 1 | `bytesize` | StringLiteral | named |
| 1 | `filename` | ASTNode | not yet |
| 1 | `methods` | TypeNode | not yet |
| 1 | `of` | ArrayLiteral | not yet |
| 1 | `tr` | StringLiteral | not yet |
| 1 | `union_types` | TypeNode | not yet |
| 1 | `value` | Assign, MacroLiteral, NamedArgument, TypeDeclaration | named |
| 0 | `!` | ASTNode | named |
| 0 | `!=` | ASTNode, MacroId, StringLiteral, SymbolLiteral, TypeNode | named |
| 0 | `%` | NumberLiteral | named |
| 0 | `&` | NumberLiteral | not yet |
| 0 | `**` | NumberLiteral | not yet |
| 0 | `+` | NumberLiteral, StringLiteral | named |
| 0 | `-` | NumberLiteral | named |
| 0 | `//` | NumberLiteral | not yet |
| 0 | `<` | NumberLiteral, StringLiteral, TypeNode | named |
| 0 | `<<` | NumberLiteral | not yet |
| 0 | `<=` | NumberLiteral, TypeNode | named |
| 0 | `<=>` | NumberLiteral | not yet |
| 0 | `==` | ASTNode, MacroId, StringLiteral, SymbolLiteral, TypeNode | named |
| 0 | `=~` | StringLiteral | not yet |
| 0 | `>` | NumberLiteral, StringLiteral, TypeNode | named |
| 0 | `>=` | NumberLiteral, TypeNode | named |
| 0 | `>>` | NumberLiteral | not yet |
| 0 | `[]` | Annotation, HashLiteral, NamedTupleLiteral, StringLiteral, TypeNode | named |
| 0 | `[]=` | HashLiteral, NamedTupleLiteral | not yet |
| 0 | `^` | NumberLiteral | not yet |
| 0 | `abstract?` | ClassDef, Def, TypeNode | not yet |
| 0 | `accepts_block?` | Def | not yet |
| 0 | `alignstack?` | Asm | not yet |
| 0 | `all_methods` | TypeNode | not yet |
| 0 | `all_subclasses` | TypeNode | not yet |
| 0 | `annotations` | Arg, Def, MetaMacroVar, TypeNode | not yet |
| 0 | `arg` | IsA | not yet |
| 0 | `base_type` | EnumDef | not yet |
| 0 | `begin` | RangeLiteral | named |
| 0 | `block` | Call | named |
| 0 | `block_arg` | Call, Def, Macro | not yet |
| 0 | `body` | AnnotationDef, Block, CStructOrUnionDef, ClassDef, Def, EnumDef, ExceptionHandler, FunDef, LibDef, Macro, MacroFor, ModuleDef, ProcLiteral, Rescue, When, While | named |
| 0 | `camelcase` | StringLiteral | named |
| 0 | `can_throw?` | Asm | not yet |
| 0 | `capitalize` | StringLiteral | named |
| 0 | `chars` | StringLiteral | not yet |
| 0 | `chr` | NumberLiteral | not yet |
| 0 | `class` | TypeNode | not yet |
| 0 | `class_name` | ASTNode, MacroId, SymbolLiteral | named |
| 0 | `class_vars` | TypeNode | not yet |
| 0 | `clear` | ArrayLiteral, HashLiteral | not yet |
| 0 | `clobbers` | Asm | not yet |
| 0 | `column_number` | ASTNode | not yet |
| 0 | `compare_versions` | MacroInterpreter | not yet |
| 0 | `cond` | Case, If, MacroIf, While | not yet |
| 0 | `conds` | When | not yet |
| 0 | `constraint` | AsmOperand | not yet |
| 0 | `count` | StringLiteral | not yet |
| 0 | `debug` | MacroInterpreter | named |
| 0 | `default_value` | Arg, MetaMacroVar | named |
| 0 | `doc` | ASTNode | not yet |
| 0 | `doc_comment` | ASTNode | not yet |
| 0 | `double_splat` | Def, HashLiteral, Macro, NamedTupleLiteral | not yet |
| 0 | `each` | HashLiteral, NamedTupleLiteral, RangeLiteral | not yet |
| 0 | `else` | Case, ExceptionHandler, If, MacroIf, Select | not yet |
| 0 | `end` | RangeLiteral | named |
| 0 | `end_column_number` | ASTNode | not yet |
| 0 | `end_line_number` | ASTNode | not yet |
| 0 | `ends_with?` | StringLiteral | named |
| 0 | `ensure` | ExceptionHandler | not yet |
| 0 | `env` | MacroInterpreter | named |
| 0 | `excludes_end?` | RangeLiteral | named |
| 0 | `exhaustive?` | Case, When | not yet |
| 0 | `expressions` | Expressions, MacroVar, StringInterpolation, Yield | not yet |
| 0 | `file_exists?` | MacroInterpreter | named |
| 0 | `flag?` | MacroInterpreter | named |
| 0 | `free_vars` | Def | not yet |
| 0 | `global` | Path | not yet |
| 0 | `global?` | Call, Path, ProcPointer | not yet |
| 0 | `has_body?` | FunDef | not yet |
| 0 | `has_inner_pointers?` | TypeNode | not yet |
| 0 | `has_key?` | HashLiteral, NamedTupleLiteral | named |
| 0 | `has_method?` | TypeNode | not yet |
| 0 | `host_flag?` | MacroInterpreter | named |
| 0 | `identify` | StringLiteral | not yet |
| 0 | `includers` | TypeNode | not yet |
| 0 | `inputs` | Asm, ProcNotation | not yet |
| 0 | `instance` | Metaclass, TypeNode | not yet |
| 0 | `intel?` | Asm | not yet |
| 0 | `internal_name` | Arg | not yet |
| 0 | `is_unless?` | MacroIf | not yet |
| 0 | `kind` | AnnotationDef, CStructOrUnionDef, ClassDef, EnumDef, LibDef, ModuleDef, NumberLiteral | not yet |
| 0 | `left` | BinaryOp | not yet |
| 0 | `line_number` | ASTNode | not yet |
| 0 | `lines` | StringLiteral | not yet |
| 0 | `match` | StringLiteral | not yet |
| 0 | `module?` | TypeNode | not yet |
| 0 | `names` | Path | not yet |
| 0 | `nil?` | ASTNode | named |
| 0 | `obj` | Cast, NilableCast, ProcPointer, ReadInstanceVar | named |
| 0 | `of_key` | HashLiteral | not yet |
| 0 | `of_value` | HashLiteral | not yet |
| 0 | `offset` | OffsetOf | not yet |
| 0 | `options` | RegexLiteral | not yet |
| 0 | `ord` | CharLiteral | not yet |
| 0 | `output` | ProcNotation | not yet |
| 0 | `output?` | MacroExpression | not yet |
| 0 | `outputs` | Asm | not yet |
| 0 | `overrides?` | TypeNode | not yet |
| 0 | `p` | MacroInterpreter | named |
| 0 | `p!` | MacroInterpreter | not yet |
| 0 | `parse_type` | MacroInterpreter | not yet |
| 0 | `path` | Require | not yet |
| 0 | `pp` | MacroInterpreter | named |
| 0 | `pp!` | MacroInterpreter | not yet |
| 0 | `print` | MacroInterpreter | named |
| 0 | `private?` | TypeNode | not yet |
| 0 | `public?` | TypeNode | not yet |
| 0 | `puts` | MacroInterpreter | named |
| 0 | `raise` | ASTNode, MacroInterpreter | named |
| 0 | `read_file` | MacroInterpreter | named |
| 0 | `read_file?` | MacroInterpreter | named |
| 0 | `real_name` | ExternalVar, FunDef | not yet |
| 0 | `receiver` | Call, Def, IsA, RespondsTo | named |
| 0 | `rescues` | ExceptionHandler | not yet |
| 0 | `resolve` | Generic, Metaclass, Path, ProcNotation, TypeNode, Union | not yet |
| 0 | `resolve?` | Generic, Metaclass, Path, ProcNotation, TypeNode, Union | not yet |
| 0 | `restriction` | Arg | not yet |
| 0 | `return_type` | Def, FunDef, ProcLiteral | named |
| 0 | `right` | BinaryOp | not yet |
| 0 | `run` | MacroInterpreter | refused |
| 0 | `scan` | StringLiteral | not yet |
| 0 | `scope` | Yield | not yet |
| 0 | `skip_file` | MacroInterpreter | named |
| 0 | `source` | RegexLiteral | not yet |
| 0 | `splat_index` | Block, ClassDef, Def, Macro, ModuleDef | not yet |
| 0 | `struct?` | ClassDef, TypeNode | not yet |
| 0 | `subclasses` | TypeNode | not yet |
| 0 | `superclass` | ClassDef, TypeNode | not yet |
| 0 | `system` | MacroInterpreter | refused |
| 0 | `targets` | MultiAssign | not yet |
| 0 | `text` | Asm | not yet |
| 0 | `then` | If, MacroIf | not yet |
| 0 | `titleize` | StringLiteral | not yet |
| 0 | `to` | Cast, NilableCast | not yet |
| 0 | `to_a` | HashLiteral, NamedTupleLiteral, RangeLiteral | not yet |
| 0 | `to_f` | StringLiteral | not yet |
| 0 | `to_i` | StringLiteral | named |
| 0 | `to_number` | NumberLiteral | not yet |
| 0 | `to_utf16` | StringLiteral | not yet |
| 0 | `type_vars` | ClassDef, Generic, ModuleDef, TypeNode | not yet |
| 0 | `types` | Generic, Path, Rescue, Union | not yet |
| 0 | `underscore` | StringLiteral | named |
| 0 | `upcase` | StringLiteral | named |
| 0 | `values` | HashLiteral, MultiAssign, NamedTupleLiteral | named |
| 0 | `variadic?` | FunDef | not yet |
| 0 | `vars` | MacroFor | not yet |
| 0 | `visibility` | Def, Macro, TypeNode, VisibilityModifier | not yet |
| 0 | `volatile?` | Asm | not yet |
| 0 | `warning` | ASTNode, MacroInterpreter | not yet |
| 0 | `whens` | Case, Select | not yet |
| 0 | `zero?` | NumberLiteral | not yet |
| 0 | `\|` | NumberLiteral | not yet |
| 0 | `~` | NumberLiteral | not yet |

## Checked per type

Every entry is an exact match with the hosted compiler, on the fixture named.

- `id`, `stringify`, `symbolize`: ASTNode types Var, StringLiteral, SymbolLiteral,
  NumberLiteral, NilLiteral, BoolLiteral, CharLiteral, ArrayLiteral, HashLiteral and
  Call (`macro_method_id_stringify.iyi`); MacroId through `key.id` on named tuple
  keys (`macro_for_named_tuple.iyi`); StringLiteral for `symbolize`
  (`macro_method_string_search.iyi`).
- `size`: StringLiteral, HashLiteral, NamedTupleLiteral, ArrayLiteral
  (`macro_method_size_keys.iyi`, `macro_method_string_search.iyi`).
- `keys`: HashLiteral, NamedTupleLiteral (`macro_method_size_keys.iyi`).
- `empty?`: StringLiteral, HashLiteral, NamedTupleLiteral (`macro_method_size_keys.iyi`).
- `includes?`, `starts_with?`, `ends_with?`, `upcase`, `downcase`, `capitalize`:
  StringLiteral (`macro_method_string_search.iyi`).
- `nil?`: NilLiteral and a node that is not nil (`macro_env_lookup.iyi`).
- `strip`: StringLiteral, and its refusals of an argument and a block
  (`macro_method_strip.iyi`, `macro_method_strip_argument.iyi`,
  `macro_method_strip_block.iyi`).

Not checked by any fixture, so not claimed: every TypeNode method, the Def, Arg,
Annotation and Macro accessors (`args`, `name`, `type`, `var`, `exp`,
`named_args`), and the rest of the StringLiteral methods (`chomp`, `split`,
`gsub`, `tr`).

## Divergences the port keeps

- A method the port does not define returns its receiver without an error. The
  hosted compiler raises `undefined macro method 'Class#name'`. No fixture reaches
  this path.
- `verbatim` keeps the body's raw text. The hosted compiler re-prints the body from
  its parse, so `{{i}}` comes out as `{{ i }}`. Fixtures use the spelling that
  re-prints unchanged.
- `debug` with formatting (the default) is refused: the hosted compiler formats the
  expansion with its formatter, which the port does not have.
- `p`, `pp`, `p!`, `pp!`, `parse_type`, `compare_versions`, `warning` and `@caller`
  are not ported. Each falls under the first divergence above. The hosted compiler
  on this base does not answer `ecr_process` or `ecr_process_string`.
- With no confinement context, `read_file`, `read_file?`, `file_exists?` and `env`
  are refused. Hosted resolves the package from the macro's own file when there is
  no program context, so this is the one divergence in the file methods, and the
  gate keeps it by design.
- `system` and the backtick are refused with hosted's sentence. `run` is refused by
  name (`is refused`).
- The host triple is the hosted `Config.host_target` at run time: LLVM's default,
  with the macOS version from `MACOSX_DEPLOYMENT_TARGET`. Not ported: the Linux C
  library the hosted compiler detects with `ldd`, and `IYI_CONFIG_TARGET`, which the
  hosted compiler reads when it is built. The gate checks the host triple with
  `--host-target`.
- A macro's strings and symbols are quoted by the macro engine itself
  (`MacroMethods.string_text`, `symbol_text`), as the hosted compiler quotes them.
  The shared printer in `src/compiler/syntax/ast.iyi` is outside this slice and still
  prints symbols bare elsewhere.
- Not started: the TypeNode model (increment 5) and the macro hooks `inherited`,
  `included`, `extended`, `finished` and `method_missing` (increment 6).
