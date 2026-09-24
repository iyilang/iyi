require "./semantic_visitor"

# In this pass we traverse the AST nodes to declare and process:
# - class
# - struct
# - module
# - include
# - extend
# - enum (checking their value, since these need to be numbers or simple math operations)
# - macro
# - def (without going inside them)
# - alias (without resolution)
# - constants (without checking their value)
# - macro calls (only surface macros, because we don't go inside defs)
# - lib and everything inside them
# - fun with body (without going inside them)
#
# Macro calls are expanded, but only the first pass is done to them. This
# allows macros to define new classes and methods.
#
# We also process @[Link] annotations.
#
# After this pass we have completely defined the whole class hierarchy,
# including methods. After this point no new classes or methods can be introduced
# since in next passes we only go inside methods and top-level code, but we already
# analyzed top-level (surface) macros that could have expanded to class/method
# definitions.
#
# Now that we know the whole hierarchy, when someone types Foo, we know whether Foo has
# subclasses or not and we can tag it as "virtual" (having subclasses), but that concept
# might disappear in the future and we'll make consider everything as "maybe virtual".
class Iyi::TopLevelVisitor < Iyi::SemanticVisitor
  # These are `new` methods (values) that was created from `initialize` methods (keys)
  getter new_expansions : Hash(Def, Def) = ({} of Def => Def).compare_by_identity

  # All finished hooks and their scope
  record FinishedHook, scope : ModuleType, macro : Macro
  @finished_hooks = [] of FinishedHook

  @method_added_running = false

  # iyi: the class or struct declaration each `derive` sits inside (R-5).
  # `current_type` is the semantic type; a derive macro is handed syntax.
  @derive_owners = [] of ClassDef

  @last_doc : String?

  # special types recognized for `@[Primitive]`
  private enum PrimitiveType
    ReferenceStorageType
  end

  def visit(node : ClassDef)
    check_outside_exp node, "declare class"

    scope, name, type = lookup_type_def(node)

    annotations = read_annotations

    special_type = nil
    process_annotations(annotations) do |annotation_type, ann|
      case annotation_type
      when @program.primitive_annotation
        if ann.args.size != 1
          ann.raise "expected Primitive annotation to have one argument"
        end

        arg = ann.args.first
        unless arg.is_a?(SymbolLiteral)
          arg.raise "expected Primitive argument to be a symbol literal"
        end

        value = arg.value
        special_type = PrimitiveType.parse?(value)
        unless special_type
          arg.raise "BUG: Unknown primitive type #{value.inspect}"
        end
      end
    end

    created_new_type = false

    if type
      type = type.remove_alias

      unless type.is_a?(ClassType)
        node.raise "#{name} is not a #{node.struct? ? "struct" : "class"}, it's a #{type.type_desc}"
      end

      if node.struct? != type.struct?
        node.raise "#{name} is not a #{node.struct? ? "struct" : "class"}, it's a #{type.type_desc}"
      end

      if type_vars = node.type_vars
        if type.is_a?(GenericType)
          check_reopened_generic(type, node, type_vars)
        else
          node.raise "#{name} is not a generic #{type.type_desc}"
        end
      end
    else
      created_new_type = true
      case special_type
      in Nil
        if type_vars = node.type_vars
          type = GenericClassType.new @program, scope, name, nil, type_vars, false
          type.splat_index = node.splat_index
        else
          type = NonGenericClassType.new @program, scope, name, nil, false
        end
        type.abstract = node.abstract?
        type.struct = node.struct?
      in .reference_storage_type?
        type_vars = node.type_vars
        case
        when !node.struct?
          node.raise "BUG: Expected ReferenceStorageType to be a struct type"
        when node.abstract?
          node.raise "BUG: Expected ReferenceStorageType to be a non-abstract type"
        when !type_vars
          node.raise "BUG: Expected ReferenceStorageType to be a generic type"
        when type_vars.size != 1
          node.raise "BUG: Expected ReferenceStorageType to have a single generic type parameter"
        when node.splat_index
          node.raise "BUG: Expected ReferenceStorageType to have no splat parameter"
        end
        type = GenericReferenceStorageType.new @program, scope, name, @program.value, type_vars, false
        type.declare_instance_var("@type_id", @program.int32)
        type.can_be_stored = false
      end
    end

    type.private = true if node.visibility.private?

    node_superclass = node.superclass
    if node_superclass
      if type_vars = node.type_vars
        free_vars = {} of String => TypeVar
        type_vars.each do |type_var|
          free_vars[type_var] = type.as(GenericType).type_parameter(type_var)
        end
      else
        free_vars = nil
      end

      # find_root_generic_type_parameters is false because
      # we don't want to find T in this case:
      #
      # class A(T)
      #   class B < T
      #   end
      # end
      #
      # We search for a superclass starting from the current
      # type, A(T) in this case, but we don't want to find
      # type parameters because they will always be unbound.
      superclass = lookup_type(node_superclass,
        free_vars: free_vars,
        find_root_generic_type_parameters: false).devirtualize
      case superclass
      when GenericClassType
        node_superclass.raise "generic type arguments must be specified when inheriting #{superclass}"
      when NonGenericClassType, GenericClassInstanceType
        if superclass == @program.enum
          node_superclass.raise "can't inherit Enum. Use the enum keyword to define enums"
        end
      else
        node_superclass.raise "#{superclass} is not a class, it's a #{superclass.type_desc}"
      end
    else
      superclass = node.struct? ? program.struct : program.reference
    end

    if node.superclass && !created_new_type && type.superclass != superclass
      node.raise "superclass mismatch for class #{type} (#{superclass} for #{type.superclass})"
    end

    if created_new_type && superclass
      if node.struct? != superclass.struct?
        node.raise "can't make #{node.struct? ? "struct" : "class"} '#{node.name}' inherit #{superclass.type_desc} '#{superclass}'"
      end

      if superclass.struct? && !superclass.abstract?
        node.raise "can't extend non-abstract struct #{superclass}"
      end

      if type.is_a?(GenericReferenceStorageType) && superclass != @program.value
        node.raise "BUG: Expected reference_storage_type to inherit from Value"
      end
    end

    if created_new_type
      type.superclass = superclass

      # If it's SomeClass(T) < Foo(T), or SomeClass < Foo(Int32),
      # we want to add SomeClass as a subclass of Foo(T)
      if superclass.is_a?(GenericClassInstanceType)
        superclass.generic_type.add_subclass(type)
      end
      scope.types[name] = type
    end

    record_export scope, name, node.exported?
    type.private = true if unexported_in_unit?(scope, node.exported?)

    node.resolved_type = type

    process_annotations(annotations) do |annotation_type, ann|
      if annotation_type == @program.share_annotation
        # iyi: trust, not a check (SPEC.md III.4.4). Any struct or class,
        # generic or not; the generic's instances inherit the trust and are
        # then shareable when their arguments are.
        type.iyi_share_trusted = true
      end

      if node.struct? && type.is_a?(NonGenericClassType)
        case annotation_type
        when @program.extern_annotation
          unless type.is_a?(NonGenericClassType)
            node.raise "can only use Extern annotation with non-generic structs"
          end

          unless ann.args.empty?
            ann.raise "Extern annotation can't have positional arguments, only named arguments: 'union'"
          end

          ann.named_args.try &.each do |named_arg|
            case named_arg.name
            when "union"
              value = named_arg.value
              if value.is_a?(BoolLiteral)
                type.extern_union = value.value
              else
                value.raise "Extern 'union' annotation must be a boolean, not #{value.class_desc}"
              end
            else
              named_arg.raise "unknown Extern named argument, valid arguments are: 'union'"
            end
          end

          type.extern = true
        when @program.packed_annotation
          type.packed = true
        else
          # not a built-in annotation
        end
      end

      type.add_annotation(annotation_type, ann)
    end

    attach_doc type, node, annotations

    pushing_type(type) do
      run_hooks(hook_type(superclass), type, :inherited, node) if created_new_type
      @derive_owners.push node
      begin
        node.body.accept self
      ensure
        @derive_owners.pop
      end
    rescue ex : MacroRaiseException
      # Make the inner most exception to be the inherited node so that it's the last frame in the trace.
      # This will make the location show on that node instead of the `raise` call.
      ex.inner = Iyi::MacroRaiseException.for_node node, ex.message

      raise ex
    end

    if created_new_type
      type.force_add_subclass
    end

    false
  end

  # iyi: `using app/greeter`, `using app/greeter::{polite}` (SPEC.md II.3)
  #
  # Brings a module's exported names into unqualified scope — written by the
  # consumer, not performed by the library. This is only a record: the two
  # lookups that matter consult it directly, `Call#lookup_using_matches` for
  # methods and `Type#lookup_using_path_item` for type names. Nothing is added
  # to the ancestor chain, which is what keeps `using` from re-exporting.
  #
  # The record lands on `current_type`, so the directive reaches exactly the
  # scope it was written in and no further: both lookups walk outward from
  # where the name is used, so a `using` in a module covers the types nested
  # inside it, and stops at the module's edge.
  def visit(node : UsingDecl)
    check_outside_exp node, "use `using`"

    # A short name is spelled out first, as the import beside it was.
    written_short = node.path.join('/')
    expanded = iyi_expand_short_name(node, written_short)
    node.path = expanded.split('/') unless expanded == written_short

    # Global, because a module's path is its file's path (R-1) and a file path
    # does not mean something different depending on where it is written. A
    # lexical lookup made `using calc/lexer` inside a module called
    # `samples/calc` resolve `Calc` to the module doing the `using`, and then
    # say the module was not imported — a true-looking sentence about the wrong
    # thing. Found by `samples/iyi/calc`, which is called that.
    path = Path.new(iyi_using_segments(node.path), global: true).at(node)

    # iyi: `using` reaches a module this file has imported, and the error for
    # forgetting the import used to be "undefined constant App::Greeter" —
    # a name the author never wrote, about a rule they had not met. Two
    # different mistakes hide behind it, so they are told apart here.
    written = node.path.join('/')
    unless current_type.lookup_type?(path, allow_typeof: false)
      if resolve_import(written)
        node.raise "`#{written}` is not imported here. `using` brings in the " \
                   "names of a module this file has already imported, so this " \
                   "needs `import #{written}` above it (SPEC.md R-1, R-2b)"
      else
        node.raise "can't find module '#{written}'. A module's path is its " \
                   "file's path, so this one is `#{written}.iyi`"
      end
    end

    used_type = lookup_type(path)

    # `is_a?(ModuleType)` would not do: classes and structs are `ModuleType`s
    # too, and `using` a struct is meaningless. Nor would `module?` alone: a
    # trait is a module type, but it exports no names to bring into scope —
    # its methods are reached through the receiver's impl, which II.3 rule 1
    # keeps entirely out of `using`'s namespace.
    if used_type.trait?
      node.raise "can't `using` #{used_type}, it's a trait. Trait methods are resolved from the receiver's type, never from a `using` — see SPEC.md II.3"
    end

    unless used_type.is_a?(ModuleType) && used_type.module?
      node.raise "can't `using` #{used_type}, it's a #{used_type.type_desc}"
    end

    # iyi: the wall, made per-file. Until here the check was
    # type-existence, and type-existence is program-wide — anyone's
    # import made a module everyone's, which is the phantom-dependency
    # disease R-1 exists to refuse. A file reaches with `using` exactly
    # what it imported, plus what those imports re-export with
    # `pub import`, transitively: a facade may hand its dependencies
    # on, a private import may not.
    #
    # And only for modules somebody actually *imported*: a unit that
    # appears in no import edge exists because this very source declared
    # it — its own file, or a spec's inline fixture — and a file always
    # reaches what it wrote.
    if used_type.iyi_unit? &&
       (@program.iyi_module_paths.has_value?(written) || @program.iyi_artifact_modules.has_value?(written))
      from = @iyi_importing.last? || @program.filename.to_s
      unless iyi_using_reachable?(from, written)
        node.raise "`using #{written}` reaches a module this file did not " \
                   "import — it is in the program only because some other " \
                   "file imported it. Add `import #{written}` here, or have " \
                   "a module this file imports re-export it with " \
                   "`pub import #{written}` (SPEC.md R-1, R-2b)"
      end
    end

    # R-2b: `using` reaches a module's *exported* names. Reported here rather
    # than left to fail at the point of use, because the selective form names
    # what it wants and the author can be told which of those they cannot have.
    # Two mistakes hide behind "does not export": a name the module has and
    # did not mark `pub`, and a name the module does not have at all - a typo,
    # usually, and `using calc/add::{ad}` was told to add `pub` to a
    # declaration that does not exist. The typo gets the nearest exported name.
    if names = node.names
      unexported = names.reject { |name| used_type.exported_name?(name) }
      unless unexported.empty?
        declared, absent = unexported.partition { |name| used_type.defs.try(&.has_key?(name)) || used_type.types?.try(&.has_key?(name)) }
        if absent.empty?
          node.raise "#{used_type} does not export #{declared.map { |name| "`#{name}`" }.join(", ")}. `using` reaches only what a module marks `pub` — add `pub` to the declaration if it is meant to be part of the module's surface (SPEC.md R-2b)"
        else
          # iyi: the name the module declares at the *root*. `std/set` is
          # `module std/set` and `class ::Set(T)` inside it: the `::` puts
          # the class beside `Array` and `String` rather than in the
          # module, so `import std/set` alone is what brings it and a
          # `using` naming it asks the module for something it does not
          # have. Twenty-five modules under `src/std` are written this way,
          # and the sentence they drew — "nothing by that name is declared
          # in `std/set`, `pub` or not" — is true of the module and wrong
          # about the program, where `Set` is right there. `mod context`
          # already prints these as `class ::Set(T)` and offers no `using`
          # line; this is the same fact, said where the mistake is made.
          rooted = absent.select { |name| iyi_root_declared_by?(name, used_type) }
          unless rooted.empty?
            node.raise "#{rooted.map { |name| "`#{name}`" }.join(", ")} " \
                       "#{rooted.size == 1 ? "is" : "are"} declared at the root by " \
                       "`#{written}`, not as #{rooted.size == 1 ? "a name" : "names"} of it: " \
                       "`import #{written}` is enough to write #{rooted.map { |name| "`#{name}`" }.join(", ")}, " \
                       "and `using #{written}::{#{rooted.join(", ")}}` asks the module for " \
                       "#{rooted.size == 1 ? "a name it does not have" : "names it does not have"} (SPEC.md R-2b)"
          end

          hint = ""
          if (exported = used_type.exported_names) && (similar = Levenshtein.find(absent.first, exported.to_a))
            hint = "\nDid you mean `#{similar}`?"
          end
          node.raise "#{used_type} has no #{absent.map { |name| "`#{name}`" }.join(", ")}: nothing by that name is declared in `#{written}`, `pub` or not.#{hint}"
        end
      end
    end

    # iyi: a name the module's own name already takes.
    #
    # A module header makes a type — `module app/tally` is `App::Tally` — and
    # inside it that name means the module, whatever a `using` brought. So
    # `using x::{Tally}` in a module called `tally` asks for a name it cannot
    # have, and what the author sees otherwise is a mismatch between `Tally`
    # and `App::Count::Tally` at the first line that uses it, with nothing
    # pointing back here. Only for the selective form: it named what it wanted.
    if (selected = node.names) && (unit = current_type.as?(NamedType))
      own = unit.name
      if selected.includes?(own)
        node.raise "`#{own}` is this module's own name, so `using` cannot bring another one under it. Inside `#{unit}` the name `#{own}` means the module. Qualify the other one, or rename this module"
      end
    end

    # iyi: the directive as written, for the artifact (SPEC.md IV.2). Only the
    # module unit's own, because only its own reach the signatures the artifact
    # carries — one written inside a nested type resolves names there and
    # nowhere a consumer will look.
    if (file = @iyi_importing.last?) && current_type.iyi_unit?
      names = node.names
      selection = names ? "::{#{names.join(", ")}}" : ""
      (@program.iyi_usings[file] ||= [] of String) << "#{node.path.join('/')}#{selection}"
    end

    current_type.add_using_module(used_type, node.names)

    false
  end

  # iyi: the segments `using` turns into a type name. A package path names
  # its module by the *in-package* half (III.7): the requirement's prefix is
  # identity for the resolver and never a type, so it is stripped before the
  # camelcase mapping — `using example.com/user/liba/colors` reaches
  # `Colors`, the same name the package's own files reach it by.
  private def iyi_using_segments(segments : Array(String)) : Array(String)
    written = segments.join('/')
    @program.iyi_mod_table.each do |(prefix, _)|
      inner =
        if written == prefix
          # The package's own name, which a `/vN` suffix is not: the root
          # module of `example.com/lib/v2` is `lib.iyi`, as Go names it.
          Mod::ModFile.split_major(prefix)[0].rpartition('/')[2]
        elsif written.starts_with?("#{prefix}/")
          written[(prefix.size + 1)..]
        else
          next
        end
      return inner.split('/').map(&.camelcase)
    end
    segments.map(&.camelcase)
  end

  # Whether `written` is reachable from `from`'s own imports: every
  # direct import, then onward only through `pub import` edges. The
  # module path of an edge file is looked up both ways because a
  # dependency may have arrived as source or as an artifact.
  private def iyi_using_reachable?(from : String, written : String) : Bool
    seen = Set(String).new
    queue = (@program.iyi_module_imports[from]? || [] of String).dup
    while file = queue.pop?
      next unless seen.add?(file)
      name = @program.iyi_module_paths[file]? || @program.iyi_artifact_modules[file]?
      return true if name == written
      @program.iyi_exported_imports[file]?.try &.each { |handed| queue << handed }
    end
    false
  end

  # iyi: whether the program has *name* at its root and the file that
  # declares it is the one *used_type* is written in.
  #
  # `class ::Set(T)` inside `module std/set`: the `::` puts the class at
  # the root, and the only thing tying it to the module is that both are
  # declared in the same file. That is the same question
  # `Compiler#iyi_declared_here?` asks when it decides what an artifact
  # carries, asked here against the module's own locations rather than
  # against a filename — a module is one file (R-1, IV.6), and an inline
  # source that declares both is that file.
  #
  # `any?`, not `all?`: a root type this module declares picks up further
  # locations from anyone who reopens it or writes an `impl` for it —
  # `std/enumerable` writes `impl Enumerable for Set(T)`, so `::Set` is
  # located in two files and the module that declared it is only one of
  # them. The advice is the same for a type this module reopens rather
  # than declares: the name is at the root, `import` is what brings what
  # this module added to it, and a `using` naming it has nothing to bring.
  private def iyi_root_declared_by?(name : String, used_type : Type) : Bool
    return false unless type = @program.types[name]?
    return false unless locations = type.locations
    return false unless module_locations = used_type.locations
    files = module_locations.compact_map(&.original_filename).to_set
    return false if files.empty?
    locations.any? do |location|
      (filename = location.original_filename) && files.includes?(filename)
    end
  end

  # iyi: `trait Greet ... end`
  #
  # A trait is its own type — `TraitType` — but a *subclass* of the module
  # type, so that requirements, default methods, impl registration and
  # dispatch on a trait-typed value all keep running on machinery that is
  # already correct. See `Type#trait?` for why the distinction is drawn at
  # the declaration and use sites rather than in the type hierarchy.
  def visit(node : TraitDef)
    check_outside_exp node, "declare trait"

    annotations = read_annotations

    scope, name, type = lookup_type_def(node)

    if type
      type = type.remove_alias
      unless type.trait?
        node.raise "#{name} is not a trait, it's a #{type.type_desc}"
      end
      type = type.as(ModuleType)
    else
      type_vars = node.type_vars
      assoc_types = node.assoc_types

      if type_vars && assoc_types
        clashing = assoc_types & type_vars
        unless clashing.empty?
          node.raise "#{name} declares #{clashing.sort.join(", ")} both as a parameter and as an associated type"
        end
      end

      if type_vars || assoc_types
        generic = GenericTraitType.new @program, scope, name, (type_vars || [] of String) + (assoc_types || [] of String)
        generic.assoc_types = assoc_types || [] of String
        type = generic
      else
        type = TraitType.new @program, scope, name
      end
      scope.types[name] = type
    end

    type.private = true if node.visibility.private?

    record_export scope, name, node.exported?
    type.private = true if unexported_in_unit?(scope, node.exported?)

    resolve_supertraits node, type

    node.resolved_type = type

    attach_doc type, node, annotations

    process_annotations(annotations) do |annotation_type, ann|
      type.add_annotation(annotation_type, ann)
    end

    pushing_type(type) do
      node.body.accept self
    end

    false
  end

  # iyi: `pub` — record *name* on the enclosing module's public surface (R-2).
  #
  # Only an iyi compilation unit has one. What it marks is the whole of what
  # another module may reach, because `.iyimod` carries the exports and nothing
  # else: a name left unmarked has to be unreachable, or the metadata would not
  # be enough to compile against (SPEC.md IV.2).
  private def record_export(scope, name : String, exported : Bool)
    return unless exported

    mod = scope.as?(ModuleType)
    return unless mod && mod.iyi_unit?

    mod.add_exported_name(name)
  end

  # iyi: whether *scope* is a module unit that left this declaration unmarked,
  # so it is the module's own and no other module may reach it (R-2).
  #
  # Only the unit's own body is governed. A `def` inside a `pub trait` or a
  # `pub struct` declared in that body belongs to the trait or the struct, not
  # to the module's surface: `Enumerable`'s `to_a` carries no `pub` and has to
  # stay callable on every implementer.
  private def unexported_in_unit?(scope, exported : Bool) : Bool
    return false if exported

    mod = scope.as?(ModuleType)
    !!(mod && mod.iyi_unit?)
  end

  # iyi: `trait Ord : Eq` (SPEC.md II.6).
  private def resolve_supertraits(node : TraitDef, type)
    supertraits = node.supertraits
    return unless supertraits
    return unless type.is_a?(TraitSupertraits)

    resolved = [] of Type
    supertraits.each do |supertrait_node|
      supertrait = lookup_type(supertrait_node)

      unless supertrait.trait?
        supertrait_node.raise "can't require #{supertrait}, it's a #{supertrait.type_desc}. A trait can only require another trait"
      end

      if supertrait == type
        supertrait_node.raise "#{type} can't require itself"
      end

      if resolved.includes?(supertrait)
        supertrait_node.raise "#{type} already requires #{supertrait}"
      end

      resolved << supertrait
    end

    type.supertraits = resolved
  end

  # iyi: `impl Greet for User ... end`, `impl Greet for Box(T) forall T`
  #
  # Desugars to reopening the target type, defining the methods on it, and
  # including the trait.
  def visit(node : ImplDef)
    check_outside_exp node, "declare impl"

    annotations = read_annotations

    # What follows `impl` has to be a trait. A module is not implementable:
    # it has no requirements to satisfy, and R-3 has nothing to check for it.
    trait_type = lookup_type(node.trait)
    unless trait_type.trait?
      node.trait.raise "can't implement #{trait_type}, it's a #{trait_type.type_desc}. Only a trait can be implemented"
    end

    check_impl_trait_args node, trait_type

    target_type =
      if type_vars = node.type_vars
        resolve_generic_impl_target(node, type_vars)
      else
        check_generic_impl_without_forall(node)
        lookup_type(node.target)
      end

    # Checked before `is_a?(ModuleType)`, which a trait would satisfy.
    if target_type.trait?
      node.target.raise "can't implement #{trait_type} for #{target_type}, it's a trait. A trait is implemented for a type, and a trait is not one — to give every implementer of #{target_type} a default #{trait_type}, iyi has no blanket impls (SPEC.md II.7)"
    end

    unless target_type.is_a?(ModuleType)
      node.target.raise "can't implement a trait for #{target_type}, it's a #{target_type.type_desc}"
    end

    check_impl_coherence node, trait_type, target_type

    # iyi: one row of the artifact's impl records (SPEC.md IV.2). Recorded
    # against the file that declares it, which R-3 guarantees is the trait's
    # module or the type's — so a consumer holding both files holds every impl
    # that can exist for the pair.
    #
    # The trait and the target are recorded resolved, since that is the pair
    # coherence is about; everything else is recorded as written, because it is
    # what a consumer needs in order to state the impl again.
    # The methods are the impl's own, and are marked as such: once the body is
    # accepted below they are defs on the target like any other, and nothing
    # about them says where they came from. `impl Cmp for Int32` is why that
    # matters — the target is a prelude type this module does not export, so
    # recording them against it would lose them.
    # iyi: whether this impl's bodies travel (`MonoBodies`, SPEC.md IV.1g).
    #
    # An impl defines methods *on its target*, so they are emitted into the
    # target's unit — and the artifact carries a unit only for a non-generic
    # type this module declares. Everywhere else the machine code ends up
    # somewhere the artifact cannot reach, and the body has to travel instead:
    #
    # * a generic target, because a method exists once per instantiation and
    #   the instantiations belong to whoever writes them;
    # * a target this module does not declare, which is the case R-3 exists to
    #   allow — `impl Cmp for Int32` in `std/traits` puts `cmp` in the
    #   *prelude's* `Int32` unit, and carrying that whole unit would define
    #   every `Int32` method the consumer also defines.
    #
    # And it must be *unless*, not *always*: an impl for a non-generic type
    # this module declares already travels as machine code, and shipping the
    # body as well makes the consumer define a symbol the artifact defines too.
    file = @iyi_importing.last?
    target_declared_here =
      !!(file && target_type.locations.try &.any? { |location| location.filename == file })
    bodies_travel = target_type.is_a?(GenericType) || !target_declared_here
    container = IyiMod.mono_body_container(trait_type.to_s, target_type.to_s)

    impl_methods = [] of IyiMod::Signature
    iyi_impl_body_defs(node) do |a_def|
      a_def.iyi_from_impl = true
      signature = IyiMod.signature(a_def)
      impl_methods << signature

      # And one more way the machine code ends up somewhere the consumer
      # will not look for it: a signature written wider than what the body
      # answers. A consumer keys a call on the declaration, codegen keys
      # the symbol on the type the body inferred, and a union is where the
      # two part company — `impl Node for Number` answers `Int32` under a
      # `def evaluate(…) : Int32 | UnknownName | DividedByZero`, so the
      # producer emitted `…#evaluate<Hash(String, Int32)>:Int32` and the
      # `calc` sample's link ended on the union. The same question
      # `Iyi::Compiler#iyi_widened_parameters?` asks of an ordinary def,
      # asked here of what was written, because nothing is inferred yet.
      if iyi_impl_signature_widened?(a_def) && file
        bodies = @program.iyi_mono_bodies[file] ||= {} of String => String
        bodies[IyiMod.mono_body_key(container, signature)] = a_def.body.to_s
      elsif bodies_travel && file
        bodies = @program.iyi_mono_bodies[file] ||= {} of String => String
        bodies[IyiMod.mono_body_key(container, signature)] = a_def.body.to_s
      end
    end

    if file = @iyi_importing.last?
      (@program.iyi_impls[file] ||= [] of IyiMod::ImplRecord) << IyiMod::ImplRecord.new(
        trait_name: trait_type.to_s,
        type_name: target_type.to_s,
        trait_arguments: node.trait_args.try(&.map(&.to_s)) || [] of String,
        free_variables: node.type_vars || [] of String,
        free_variable_bounds: node.type_var_bounds.try(&.map { |name, bound| {name, bound.to_s} }) || [] of {String, String},
        assoc_types: node.assoc_types.try(&.map { |name, answer| {name, answer.to_s} }) || [] of {String, String},
        methods: impl_methods,
      )
    end

    node.resolved_type = target_type

    process_annotations(annotations) do |annotation_type, ann|
      target_type.add_annotation(annotation_type, ann)
    end

    # Define the methods on the target type.
    pushing_type(target_type) do
      node.body.accept self
    end

    # Record that the target implements the trait. Reuses `include`, which is
    # why `TraitType` is a module type — and `from_impl` is what keeps this
    # path open now that a written `include` of a trait is refused.
    assoc_args = check_impl_assoc_types node, trait_type, target_type
    check_single_impl node, trait_type, target_type
    check_impl_supertraits node, trait_type, target_type

    args = (node.trait_args || [] of ASTNode) + (assoc_args || [] of ASTNode)
    trait_name =
      if args.empty?
        node.trait
      else
        Generic.new(node.trait, args).at(node.trait)
      end
    include_node = Include.new(trait_name).at(node)
    # iyi: where II.6's associated types meet II.7's generic impls.
    #
    # `impl Enumerable for List(T) forall T` answers `type Elem = T`, and that
    # `T` becomes an argument of the `include` written here — but it names a
    # parameter of `List`, which is not in scope where the impl was written.
    # Pushing the target's scope would find it and lose the trait, whose name
    # lives in the impl's own module. So the parameters are passed as free
    # variables instead, which is what resolving a superclass inside a generic
    # already does.
    include_in target_type, include_node, :included,
      from_impl: true, free_vars: impl_target_free_vars(target_type)

    check_impl_requirements node, trait_type, target_type

    false
  end

  # iyi: the `def`s written directly in an impl's body.
  #
  # Directly: anything deeper belongs to a type declared in there and is not
  # the impl's answer to the trait.
  private def iyi_impl_body_defs(node : ImplDef, &)
    body = node.body
    expressions = body.is_a?(Expressions) ? body.expressions : [body]
    expressions.each do |expression|
      expression = expression.exp if expression.is_a?(VisibilityModifier)
      yield expression if expression.is_a?(Def)
    end
  end

  # iyi: `type Elem` outside a trait or an impl body. The parser marks the ones
  # that sit directly in such a body; anything else reaching here is nested
  # inside a type declared in that body, where it means nothing.
  def visit(node : AssocTypeDecl)
    unless node.in_type_body?
      node.raise "an associated type can only be declared directly in a trait or an impl body"
    end
    false
  end

  # iyi: `impl Into(String) for User` — the arguments a parameterised trait is
  # implemented at (SPEC.md II.6).
  #
  # Checked here rather than left to the include below, whose error says
  # "including" and names no impl. The arity check is worth doing eagerly for
  # the same reason `check_impl_requirements` is: the impl is where the author
  # can fix it, and it needs nothing but this node and the trait's declaration.
  private def check_impl_trait_args(node : ImplDef, trait_type)
    trait_args = node.trait_args

    unless trait_type.is_a?(GenericType)
      if trait_args
        node.trait.raise "can't implement #{trait_type} with type arguments, it's not a generic trait"
      end
      return
    end

    # An associated type is not a parameter: it is answered in the impl's body,
    # not written here. So the arity checked is the parameter count.
    params = trait_type.is_a?(GenericTraitType) ? trait_type.trait_params : trait_type.type_vars

    if params.empty?
      if trait_args
        node.trait.raise "can't implement #{trait_type} with type arguments, it has no parameters"
      end
      return
    end

    unless trait_args
      node.trait.raise "type arguments must be specified when implementing #{trait_type}, one for each of #{params.join(", ")}"
    end

    if trait_args.size != params.size
      node.trait.raise "wrong number of type arguments for #{trait_type} (given #{trait_args.size}, expected #{params.size})"
    end
  end

  # iyi: `type Elem = String` in an impl — the answer to an associated type the
  # trait declared (SPEC.md II.6). Returns the answers in declaration order,
  # which is the order they are appended to the trait's type vars.
  private def check_impl_assoc_types(node : ImplDef, trait_type, target_type) : Array(ASTNode)?
    declared = trait_type.is_a?(GenericTraitType) ? trait_type.assoc_types : [] of String
    given = node.assoc_types

    if declared.empty?
      if given
        node.raise "#{trait_type} declares no associated types, so this impl has nothing to answer with `type #{given.first_key}`"
      end
      return nil
    end

    given ||= {} of String => ASTNode

    unknown = given.keys.reject { |assoc_name| declared.includes?(assoc_name) }
    unless unknown.empty?
      node.raise "#{trait_type} declares no associated type named #{unknown.sort.join(", ")}. It declares: #{declared.join(", ")}"
    end

    missing = declared.reject { |assoc_name| given.has_key?(assoc_name) }
    unless missing.empty?
      node.raise "impl #{trait_type} for #{target_type} does not answer #{missing.size == 1 ? "an associated type" : "associated types"} the trait declares: #{missing.join(", ")}"
    end

    declared.map { |assoc_name| given[assoc_name] }
  end

  # iyi: `trait Ord : Eq` — an impl of `Ord` needs an impl of `Eq` for the same
  # type to exist already (SPEC.md II.6).
  #
  # Checked at the impl, like the required methods are, and for the same
  # reason: it needs this node and the trait's declaration, never a global
  # pass. The cost is that the impls have to be written in dependency order,
  # since nothing has run yet that would know about a later one.
  #
  # Transitivity comes for free. If `Eq` itself required `Show`, the
  # `impl Eq for N` this one insists on was checked the same way.
  private def check_impl_supertraits(node : ImplDef, trait_type, target_type)
    return unless trait_type.is_a?(TraitSupertraits)

    missing = trait_type.supertraits.reject { |supertrait| target_type.implements?(supertrait) }
    return if missing.empty?

    node.raise "impl #{trait_type} for #{target_type} needs #{missing.size == 1 ? "an impl" : "impls"} of #{missing.join(", ")} for #{target_type} first: #{trait_type} requires its implementers to implement #{missing.size == 1 ? "it" : "them"} — see SPEC.md II.6"
  end

  # iyi: a trait whose only type vars are associated ones can be implemented at
  # most once for a type (SPEC.md II.6).
  #
  # This is the whole difference between an associated type and a parameter. If
  # a second impl could answer `Elem` differently, `arr.map` would be ambiguous
  # about which impl it meant — which is exactly what making the element type a
  # parameter would have cost. Where the trait does have parameters, several
  # impls are the point, so they are left alone.
  private def check_single_impl(node : ImplDef, trait_type, target_type)
    return unless trait_type.is_a?(GenericTraitType)
    return if trait_type.assoc_types.empty?
    return unless trait_type.trait_params.empty?

    return unless target_type.ancestors.any? do |ancestor|
                    ancestor.is_a?(GenericModuleInstanceType) && ancestor.generic_type == trait_type
                  end

    node.raise "#{target_type} already implements #{trait_type}, and a trait with associated types can be implemented only once for a type: #{trait_type.assoc_types.join(", ")} #{trait_type.assoc_types.size == 1 ? "is an output" : "are outputs"} of the impl, so a second answer would make a call on #{target_type} ambiguous — see SPEC.md II.6"
  end

  # iyi: `impl Greet for Box(T)` and `impl Greet for Box(Int32)`, both without
  # `forall` (SPEC.md II.7). Neither is legal, and each is wrong in its own
  # way, so each gets its own error.
  private def check_generic_impl_without_forall(node : ImplDef)
    target = node.target
    return unless target.is_a?(Generic)

    # Left alone, the first fails with "undefined constant T" — which
    # describes the mechanism, not the mistake. Requiring the binder is a
    # deliberate decision, so it should be possible to learn it from the error.
    unbound = target.type_vars.compact_map do |arg|
      next unless arg.is_a?(Path) && !arg.global? && arg.names.size == 1
      name = arg.names.first
      name unless current_type.lookup_path(arg)
    end

    unless unbound.empty?
      node.target.raise "#{unbound.join(", ")} #{unbound.size == 1 ? "is" : "are"} not a type here. To implement #{node.trait} for every #{target.name}, introduce the parameters with `forall`: `impl #{node.trait} for #{target} forall #{unbound.join(", ")}`"
    end

    # Everything resolved, so this asks to implement the trait for one
    # instantiation only. See SPEC.md II.7 for why iyi has no specialisation.
    node.target.raise "can't implement #{node.trait} for #{target} alone: iyi has no specialised impls, so a trait is implemented for #{target.name} once, for every instantiation. Write `impl #{node.trait} for #{target.name}(T) forall T`"
  end

  # iyi: resolves the target of `impl Greet for Box(T) forall T` (SPEC.md II.7).
  #
  # `forall` is required, and this is the reason: without it, whether `T` in
  # `Box(T)` is a new parameter or a type already in scope would depend on
  # what happens to be imported, so a library could change the meaning of a
  # consumer's impl by adding an export. Rust takes the same position for the
  # same reason.
  #
  # The names are the impl's own, bound positionally to the target's
  # parameters, so an impl states arity and not vocabulary — what a type chose
  # to call its parameters is its own business. Reopening the type is how the
  # methods get defined, and Crystal resolves parameters inside a reopened
  # generic by name, so a differing name is renamed in the body here.
  private def resolve_generic_impl_target(node : ImplDef, type_vars : Array(String))
    target = node.target

    # A blanket impl — the target is the parameter itself. Checked before
    # anything else because refusing it is permanent, where the unimplemented
    # pieces below are not.
    if target.is_a?(Path) && !target.global? && target.names.size == 1 && type_vars.includes?(target.names.first)
      node.target.raise "can't implement #{node.trait} for every type. A blanket impl lets one module add methods to types it has never heard of, which is the open-class problem traits exist to remove — implement #{node.trait} for each type instead"
    end

    if bounds = node.type_var_bounds
      names = bounds.keys.join(", ")
      node.raise "trait bounds on impl type parameters (`forall #{names} : ...`) are not implemented yet"
    end

    unless target.is_a?(Generic)
      node.target.raise "#{node.target} takes no type parameters, so `forall #{type_vars.join(", ")}` has nothing to bind"
    end

    base = lookup_type(target.name)
    unless base.is_a?(GenericType)
      target.name.raise "#{base} is not a generic type"
    end

    declared = base.type_vars
    args = target.type_vars

    if args.size != declared.size
      node.target.raise "wrong number of type vars for #{base} (given #{args.size}, expected #{declared.size})"
    end

    # Every argument must be one of the `forall` names, each used once. A
    # concrete argument — `impl Show for Box(Int32)` — is refused rather than
    # treated as specialisation: see SPEC.md II.7.
    renames = {} of String => String
    args.each_with_index do |arg, index|
      unless arg.is_a?(Path) && !arg.global? && arg.names.size == 1 && type_vars.includes?(arg.names.first)
        arg.raise "expected one of the type parameters introduced by `forall` (#{type_vars.join(", ")}); iyi has no specialised impls, so a concrete type here is not a narrower impl but an error"
      end

      name = arg.names.first
      if renames.has_key?(name)
        arg.raise "type parameter #{name} is bound twice; each of #{base}'s parameters needs its own"
      end
      renames[name] = declared[index]
    end

    unused = type_vars.reject { |name| renames.has_key?(name) }
    unless unused.empty?
      node.raise "`forall` introduces #{unused.join(", ")}, which #{unused.size == 1 ? "is" : "are"} never used in #{node.target}"
    end

    unless renames.all? { |from, to| from == to }
      node.body = node.body.transform(TypeParamRenamer.new(renames))
    end

    base
  end

  # iyi: rewrites an impl's own type-parameter names to the ones the target
  # was declared with, so that `impl Greet for Box(U) forall U` works on a
  # `Box(T)` — the names an impl chooses are local to it.
  #
  # Renaming can capture: if the body already refers to something called `T`
  # meaning anything else, the rewrite would silently make it the type
  # parameter. That is refused rather than risked.
  private class TypeParamRenamer < Iyi::Transformer
    def initialize(@renames : Hash(String, String))
      @targets = @renames.values.to_set - @renames.keys.to_set
    end

    def transform(node : Iyi::Path)
      return node if node.global? || node.names.size != 1

      name = node.names.first
      if @targets.includes?(name)
        node.raise "#{name} is what this impl's target declared its type parameter as, so it can't also be used as a name here; rename the `forall` parameter to #{name}"
      end

      if (renamed = @renames[name]?)
        Iyi::Path.new([renamed]).at(node)
      else
        node
      end
    end

    # `Def#return_type` is not walked by the base transformer, and `def get : T`
    # is exactly where an impl's type parameter appears.
    def transform(node : Iyi::Def)
      if return_type = node.return_type
        node.return_type = return_type.transform(self)
      end
      super
    end
  end

  # iyi: R-3's orphan rule — an `impl` must live in the module that defines
  # the trait or the module that defines the type.
  #
  # SPEC.md IV.4 shows what the restriction buys: with it in force, no two
  # modules can define the same impl, because each would have to name a
  # declaration of the other and so import it, and R-1's import graph is a
  # DAG. That is what removes the need for a global coherence pass — and it is
  # the rule doing the work, not the DAG. The DAG alone forbids nothing here:
  # a third module that imports both is free to write the impl, and so is a
  # fourth, and the two would differ with no error and no link-time complaint.
  #
  # `namespace` is the defining module because that is what the `module`
  # header desugars to, so a declaration's module is simply the type enclosing
  # it.
  #
  # The top level is not a module, and treating it as one is what used to make
  # the rule vacuous: `Error` is the compiler's and belongs to no module,
  # `String` is the prelude's and belongs to none either, so
  # `impl Error for String` satisfied "inside the module that defines the
  # trait" from anywhere at all — and two modules could both write it, which is
  # the exact thing R-3 exists to prevent. So a side only counts when there is
  # a real module on it to be inside of.
  #
  # The one place the top level still answers is a program that never writes a
  # module header: it is a single compilation unit, there is no other module
  # for an impl to have gone in, and the rule has nothing to say.
  # Not asked of an impl that arrived from an artifact. R-3 is a rule about
  # *who may write* an impl, and the module that wrote this one was held to
  # it when it compiled; what arrives is the record of a check already
  # passed. Asking again reads the declaration in the wrong place: an impl
  # written inside the type it targets — `impl Comparable for Prerelease`
  # inside `struct SemanticVersion` — is rendered at the module's own level,
  # where the enclosing type is the module and not the struct, and
  # `std/semantic_version` could not be consumed as an artifact at all.
  private def check_impl_coherence(node, trait_type, target_type)
    return if node.trait.iyi_from_artifact?
    return if current_type.is_a?(Program)

    trait_module = trait_type.namespace
    target_module = target_type.namespace
    return if inside_module?(trait_module) || inside_module?(target_module)

    places = [] of String
    places << "the module that defines the trait (#{trait_module})" unless trait_module.is_a?(Program)
    places << "the module that defines the type (#{target_module})" unless target_module.is_a?(Program)

    if places.empty?
      node.raise "can't implement #{trait_type} for #{target_type} in #{current_type}: neither belongs to a module, so there is no module this impl could be at home in. Every module that can name both is free to write it, and they would disagree with no error and no complaint at link time. This is R-3, the orphan rule — see SPEC.md IV.4"
    end

    node.raise "can't implement #{trait_type} for #{target_type} in #{current_type}: an impl must live in #{places.join(" or ")}. This is R-3, the orphan rule, and it is what lets coherence be checked without a global pass — see SPEC.md IV.4"
  end

  # iyi: whether *mod* is a module the current type is inside of. The top level
  # is not one: nobody owns it, so being "in" it settles nothing.
  private def inside_module?(mod : Type) : Bool
    !mod.is_a?(Program) && within?(current_type, mod)
  end

  # iyi: `abstract def` in a trait is a requirement the impl has to satisfy
  # (SPEC.md II.6), and this is what makes it one.
  #
  # Crystal's own abstract-def check would eventually complain, but it reports
  # at the point the type is first *used* and names the type — saying nothing
  # about which impl was supposed to provide the method, and only if the type
  # is used at all. Checked here the error lands on the impl and names what is
  # missing. This is a local check: it needs the trait's declaration and this
  # impl, never a global pass, which is what R-1 requires of it.
  #
  # Satisfied by the method existing on the target, not strictly by this impl
  # block defining it: a `def show` written on the struct itself lives in the
  # type's own module, which is exactly where R-3 would let an impl live, so
  # there is no coherence hole in accepting it.
  private def check_impl_requirements(node : ImplDef, trait_type, target_type)
    missing = missing_requirements(trait_type, target_type)

    # iyi: `abstract def self.zero : self` — a class-level requirement.
    # Checked separately because `include` carries instance methods only, so
    # the trait's metaclass defs never reach the target's and there is nothing
    # here for the impl to have inherited: it has to have written them.
    missing.concat missing_requirements(trait_type.metaclass, target_type.metaclass).map { |name| "self.#{name}" }

    return if missing.empty?

    missing.sort!
    node.raise "impl #{trait_type} for #{target_type} is missing #{missing.size == 1 ? "a method" : "methods"} required by the trait: #{missing.join(", ")}"
  end

  private def missing_requirements(trait_type, target_type) : Array(String)
    defs = trait_type.defs
    return [] of String unless defs

    defs.compact_map do |name, list|
      next unless list.any? &.def.abstract?
      # Rejecting abstract defs skips the requirement itself, which the target
      # now inherits through the include this impl just performed.
      name if target_type.lookup_defs(name).none? { |a_def| !a_def.abstract? }
    end
  end

  # Whether *type* is *mod*, or is nested somewhere inside it.
  private def within?(type : Type, mod : Type) : Bool
    scope = type
    while scope
      return true if scope == mod
      break if scope == @program
      scope = scope.is_a?(NamedType) ? scope.namespace : nil
    end
    false
  end

  def visit(node : ModuleDef)
    check_outside_exp node, "declare module"

    annotations = read_annotations

    scope, name, type = lookup_type_def(node)

    if type
      type = type.remove_alias

      unless type.module?
        node.raise "#{name} is not a module, it's a #{type.type_desc}"
      end

      if type_vars = node.type_vars
        if type.is_a?(GenericType)
          check_reopened_generic(type, node, type_vars)
        else
          node.raise "#{name} is not a generic module"
        end
      end

      type = type.as(ModuleType)
    else
      if type_vars = node.type_vars
        type = GenericModuleType.new @program, scope, name, type_vars
        type.splat_index = node.splat_index
      else
        type = NonGenericModuleType.new @program, scope, name
      end
      scope.types[name] = type
    end

    type.private = true if node.visibility.private?
    type.iyi_unit = true if node.iyi_unit?

    node.resolved_type = type

    attach_doc type, node, annotations

    process_annotations(annotations) do |annotation_type, ann|
      type.add_annotation(annotation_type, ann)
    end

    pushing_type(type) do
      node.body.accept self
    end

    false
  end

  private def check_reopened_generic(generic, node, new_type_vars)
    generic_type_vars = generic.type_vars
    if new_type_vars != generic_type_vars || node.splat_index != generic.splat_index
      msg = String.build do |io|
        io << "type var"
        io << 's' if generic_type_vars.size > 1
        io << " must be "
        generic_type_vars.each_with_index do |var, i|
          io << ", " if i > 0
          io << '*' if i == generic.splat_index
          var.to_s(io)
        end
        io << ", not "
        new_type_vars.each_with_index do |var, i|
          io << ", " if i > 0
          io << '*' if i == node.splat_index
          var.to_s(io)
        end
      end
      node.raise msg
    end
  end

  def visit(node : AnnotationDef)
    check_outside_exp node, "declare annotation"

    annotations = read_annotations
    process_annotations(annotations) do |annotation_type, ann|
      node.add_annotation(annotation_type, ann)
    end

    scope, name, type = lookup_type_def(node)

    if type
      unless type.is_a?(AnnotationType)
        node.raise "#{type} is not an annotation, it's a #{type.type_desc}"
      end
    else
      type = AnnotationType.new(@program, scope, name)
      scope.types[name] = type
    end

    # iyi: `pub annotation` (R-2). An annotation a consumer applies is part
    # of the surface; one nothing outside writes is the module's own.
    record_export scope, name, node.exported?
    type.private = true if unexported_in_unit?(scope, node.exported?)

    node.resolved_type = type

    attach_doc type, node, annotations

    false
  end

  def visit(node : Alias)
    check_outside_exp node, "declare alias"

    annotations = read_annotations

    scope, name, existing_type = lookup_type_def(node)

    if existing_type
      if existing_type.is_a?(AliasType)
        node.raise "alias #{node.name} is already defined"
      else
        node.raise "can't alias #{node.name} because it's already defined as a #{existing_type.type_desc}"
      end
    end

    alias_type = AliasType.new(@program, scope, name, node.value)
    process_annotations(annotations) do |annotation_type, ann|
      alias_type.add_annotation(annotation_type, ann)
    end
    attach_doc alias_type, node, annotations
    scope.types[name] = alias_type

    alias_type.private = true if node.visibility.private?

    # iyi: `pub alias` (R-2). An unmarked one is the module's own, the same
    # as an unmarked class - and the artifact carries the marked ones.
    record_export scope, name, node.exported?
    alias_type.private = true if unexported_in_unit?(scope, node.exported?)

    node.resolved_type = alias_type

    false
  end

  def visit(node : Macro)
    check_outside_exp node, "declare macro"

    annotations = read_annotations
    process_annotations(annotations) do |annotation_type, ann|
      node.add_annotation(annotation_type, ann)
    end
    node.doc ||= annotations_doc(annotations)
    check_ditto node, node.location

    node.args.each &.accept self
    node.double_splat.try &.accept self
    node.block_arg.try &.accept self

    node.set_type @program.nil

    if node.name == "finished"
      unless node.args.empty?
        node.raise "wrong number of parameters for macro '#{node.name}' (given #{node.args.size}, expected 0)"
      end
      @finished_hooks << FinishedHook.new(current_type, node)
      return false
    end

    # iyi: an unmarked macro is the module's own, the same as an unmarked `def`
    # (R-2). Without this a module's macros were reachable through its name from
    # anywhere — they travel in the artifact so that a travelling body can call
    # one, and a consumer could call one too, which is a surface nobody wrote.
    node.visibility = :private if unexported_in_unit?(current_type, node.exported?)

    target = current_type.metaclass.as(ModuleType)
    begin
      replaced = target.add_macro node
    rescue ex : Iyi::CodeError
      node.raise ex.message
    end
    iyi_refuse_override node, replaced

    # iyi: `pub macro` — recorded on the module rather than on the metaclass the
    # macro itself lives on, because the export surface is the module's and
    # `using` asks the module what it exports (R-2b).
    record_export current_type, node.name, node.exported?

    false
  end

  def visit(node : Arg)
    if anns = node.parsed_annotations
      process_annotations anns do |annotation_type, ann|
        node.add_annotation annotation_type, ann
      end
    end

    false
  end

  def visit(node : Def)
    check_outside_exp node, "declare def"

    # iyi: the body as it was *written*, for the bodies a boundary carries
    # (SPEC.md IV.1g). Read here because this pass runs before anything expands
    # it: by the time `tool bind` walks the types, `Route.new(...)` has become
    # `_.initialize(...)` and an underscore is not a receiver anybody can write
    # — the consumer said `can't read from _` about a body it was handed.
    #
    # Keyed on the location, which is what a `Def` and its declaration share.
    # Recorded only while a boundary is being written.
    if @program.compiler.try(&.emit_bind)
      if location = node.location
        # Keyed on the name as well as the place. A synthesised `new` carries
        # the *location* of the `initialize` it was made from, so a key of one
        # handed `new` the other's body — and `@block = ...` in a metaclass is
        # `@instance_vars are not yet allowed in metaclasses`.
        @program.iyi_def_bodies[Program.iyi_def_body_key(location, node.name)] ||= node.body.to_s
      end
    end

    annotations = read_annotations

    process_def_annotations(node, annotations) do |annotation_type, ann|
      if annotation_type == @program.primitive_annotation
        process_def_primitive_annotation(node, ann)
      end

      node.add_annotation(annotation_type, ann)
    end

    node.doc ||= annotations_doc(annotations)
    check_ditto node, node.location

    node.args.each &.accept self
    node.double_splat.try &.accept self
    node.block_arg.try &.accept self

    is_instance_method = false

    target_type = case receiver = node.receiver
                  when Nil
                    is_instance_method = true
                    current_type
                  when Var
                    unless receiver.name == "self"
                      receiver.raise "def receiver can only be a Type or self"
                    end
                    current_type.metaclass
                  else
                    type = lookup_type(receiver)
                    metaclass = type.metaclass
                    case metaclass
                    when LibType
                      receiver.raise "can't define method in lib #{metaclass}"
                    when GenericClassInstanceMetaclassType
                      receiver.raise "can't define method in generic instance #{metaclass}"
                    when GenericModuleInstanceMetaclassType
                      receiver.raise "can't define method in generic instance #{metaclass}"
                    end
                    metaclass
                  end

    target_type = target_type.as(ModuleType)

    if node.abstract?
      if (target_type.class? || target_type.struct?) && !target_type.abstract?
        node.raise "can't define abstract def on non-abstract #{target_type.type_desc}"
      end
      if target_type.metaclass?
        # iyi: a trait may require a class-level method —
        # `abstract def self.zero : self` (SPEC.md II.6). Without it a trait
        # cannot express an identity, so `sum` and `product` have to be given
        # one by every caller. Everywhere else the rejection stands: an
        # abstract def on a metaclass has nobody it could oblige, because only
        # a trait has implementers whose class methods are checked.
        unless current_type.trait?
          node.raise "can't define abstract def on metaclass"
        end
      end
    end

    if target_type.struct? && !target_type.metaclass? && node.name == "finalize"
      node.raise "structs can't have finalizers because they are not tracked by the GC"
    end

    if target_type.is_a?(EnumType) && node.name == "initialize"
      node.raise "enums can't define an `initialize` method, try using `def self.new`"
    end

    # iyi: a module-level `def` left unmarked is the module's own (R-2).
    # Crystal's private visibility is exactly the rule R-2 needs — reachable
    # unqualified from inside the module, refused through the module's name
    # from outside — so it is set here rather than reimplemented.
    node.visibility = :private if is_instance_method && unexported_in_unit?(current_type, node.exported?)

    replaced = target_type.add_def node
    iyi_refuse_override node, replaced

    record_export current_type, node.name, node.exported?

    # iyi: R-2, at the line the author is looking at. `IyiMod` asks the same
    # question again when it writes the artifact, because an artifact can be
    # written by a build that never saw this file.
    if node.exported? && (mod = current_type.as?(ModuleType)) && mod.iyi_unit?
      IyiMod.check_types_written(node)
    end

    node.set_type @program.nil

    if is_instance_method
      # If it's an initialize method, we define a `self.new` for
      # the type, initially empty. We will fill it once we know if
      # a type defines a `finalize` method, but defining it now
      # allows `previous_def` for a next `def self.new` definition
      # to find this method.
      if node.name == "initialize"
        new_method = node.expand_new_signature_from_initialize(target_type)
        target_type.metaclass.as(ModuleType).add_def(new_method)

        # And we register it to later complete it
        new_expansions[node] = new_method
      end

      if !@method_added_running && has_hooks?(target_type.metaclass)
        @method_added_running = true
        run_hooks target_type.metaclass, target_type, :method_added, node, Call.new("method_added", node).at(node)
        @method_added_running = false
      end
    end

    false
  end

  # iyi: a `.iyi` file may *add* to a type of the other language and may not
  # *replace* one of its methods (SPEC.md R-3).
  #
  # Adding is what a reopen is for: `class ::String; def blank?` gives the
  # library's `String` a method the library does not have, and only code that
  # can reach the module's surface can call it. Replacing is a different act.
  # The definition that goes is one the *library's own code* calls, so the
  # whole program gets the new one — and nothing at the two sites says so.
  #
  # `src/std/text.iyi` is how this was found. It writes `private def
  # byte_slice(start, count)` as a helper of its own, which is a name iyi's
  # prelude does not have and Crystal's `String` does. Built `--crystal`,
  # `import std/text` replaced Crystal's public `byte_slice` with a private
  # one, and the first program that touched `Path` — which is every program,
  # through the exception handler's backtrace — stopped on `private method
  # 'byte_slice' called for String`, pointing at a line in Crystal's own
  # library that had not changed.
  #
  # The module's own language is not this rule's business: with iyi's prelude
  # the type is a type of this language, written in `.iyi`, and reopening it is
  # how the prelude is extended. What the test asks is where each definition
  # was *written* — the same question `iyi tool bind` asks of a shard's
  # members — because that is what says whose the type is.
  #
  # The prelude is the other half, and the half this fork's own library
  # reached first. `import std/enum` that reopens `::Enum` and writes `to_s`
  # again gets the prelude's every program: a two-member flags set printed
  # `All`, and `Level.parse?("WARN")` answered nil, with nothing said at
  # either definition. A prelude method is the answer every program already
  # has, so replacing one from outside the prelude is the same defect as
  # replacing the library's, and is refused in the same sentence.
  #
  # A macro is the same act and a wider one. `getter` is a declaration macro,
  # so a module that reopens `::Object` and writes its own decides what every
  # field declaration in the program means — including the ones in files that
  # never heard of it, and including the ones the prelude wrote. It travels in
  # an artifact too (IV.1, `macro_bodies`), so a consumer can inherit it from
  # a module whose source it never reads. Asked here because `add_macro`
  # answers the same question `add_def` does.
  private def iyi_refuse_override(node : Def | Macro, replaced : Def | Macro | Nil) : Nil
    return unless replaced
    return unless iyi_written_in?(node, ".iyi")

    kind = node.is_a?(Macro) ? "macro" : "method"
    if @program.iyi_prelude?
      # The prelude extends itself: `number.iyi` writing a method
      # `primitives.iyi` declared is one library deciding its own surface.
      return unless iyi_written_in_prelude?(replaced)
      return if iyi_written_in_prelude?(node)
      whose = "the prelude's"
      instead = "Give it a name the prelude does not use, or add the #{kind} " \
                "to the prelude itself, where one definition answers for " \
                "every program"
    else
      return unless iyi_written_in?(replaced, ".cr")
      whose = "the library's"
      instead = "Give it a name the library does not use, or build without " \
                "`--crystal`, where the type is the prelude's"
    end

    at = replaced.location.try(&.expanded_location)
    where = at ? " (#{at.filename}:#{at.line_number})" : ""
    # A macro lives on the metaclass, so `replaced.owner` spells it
    # `Object.class` — which is not what the author wrote above it.
    if node.is_a?(Macro)
      site = "#{replaced.owner.to_s.chomp(".class")}.#{node.name}"
      example = "a `macro` under a name the prelude does not have is an addition"
    else
      site = "#{replaced.owner}##{node.name}"
      example = "`def blank?` on `::String` is an addition"
    end
    node.raise "#{site} is #{whose} #{kind}, and this replaces it#{where}. " \
               "A `.iyi` file may add a #{kind} to a type it did not " \
               "declare — #{example} — and may not redefine one it has: the " \
               "definition that goes is one other code calls, so every " \
               "program built with it gets this one instead. #{instead} " \
               "(SPEC.md R-3)"
  end

  # Whether *node* was written in one of the prelude's own files.
  #
  # Both sides are read as posix paths, because on Windows they arrive in
  # different spellings and the prefix test then answered no for every
  # prelude file: `File::SEPARATOR` is `'/'` on every platform (`src/file.cr`),
  # while `iyi_prelude_dir` comes from `File.dirname` of a resolved require
  # and the location's filename from `File.expand_path`, both of which use
  # `\` there. So `C:\...\prelude/` was tested against
  # `C:\...\prelude\shout.iyi`, nothing was ever in the prelude, and R-3's
  # two refusals — a module replacing a prelude method, and one replacing a
  # prelude macro — said nothing at all. `to_posix` is the identity on a
  # posix path, so the rule fires for the same declarations it always did.
  private def iyi_written_in_prelude?(node : Def | Macro) : Bool
    return false unless dir = @program.iyi_prelude_dir
    prefix = "#{::Path[dir].to_posix}/"
    !!node.location.try(&.expanded_location).try do |at|
      at.filename.as?(String).try do |filename|
        ::Path[filename].to_posix.to_s.starts_with?(prefix)
      end
    end
  end

  # Where a definition was written, following a macro back to its source.
  private def iyi_written_in?(node : Def | Macro, extension : String) : Bool
    !!node.location.try(&.expanded_location).try do |at|
      at.filename.as?(String).try &.ends_with?(extension)
    end
  end

  private def process_def_primitive_annotation(node, ann)
    if ann.args.size != 1
      ann.raise "expected Primitive annotation to have one argument"
    end

    arg = ann.args.first
    unless arg.is_a?(SymbolLiteral)
      arg.raise "expected Primitive argument to be a symbol literal"
    end

    value = arg.value

    primitive = Primitive.new(value)
    primitive.location = node.location

    node.body = primitive
  end

  def visit(node : Include)
    check_outside_exp node, "include"
    include_in current_type, node, :included
    false
  end

  def visit(node : Extend)
    check_outside_exp node, "extend"
    include_in current_type.metaclass, node, :extended
    false
  end

  def visit(node : LibDef)
    check_outside_exp node, "declare lib"

    annotations = read_annotations

    scope, name, type = lookup_type_def(node)

    if type
      unless type.is_a?(LibType)
        node.raise "#{type} is not a lib, it's a #{type.type_desc}"
      end
    else
      type = LibType.new @program, scope, name
      scope.types[name] = type
    end

    attach_doc type, node, annotations

    node.resolved_type = type

    type.private = true if node.visibility.private?

    wasm_import_module = nil

    process_annotations(annotations) do |annotation_type, ann|
      case annotation_type
      when @program.link_annotation
        link_annotation = LinkAnnotation.from(ann)

        if link_annotation.static?
          @program.warnings.add_warning(ann, "specifying static linking for individual libraries is deprecated")
        end

        if ann.args.size > 1
          @program.warnings.add_warning(ann, "using non-named arguments for Link annotations is deprecated")
        end

        if wasm_import_module && link_annotation.wasm_import_module
          ann.raise "multiple wasm import modules specified for lib #{type}"
        end

        wasm_import_module = link_annotation.wasm_import_module

        type.add_link_annotation(link_annotation)
      when @program.call_convention_annotation
        type.call_convention = parse_call_convention(ann, type.call_convention)
      else
        # not a built-in annotation
      end
      type.add_annotation(annotation_type, ann)
    end

    pushing_type(type) do
      @in_lib = true
      node.body.accept self
      @in_lib = false
    end

    false
  end

  def visit(node : CStructOrUnionDef)
    annotations = read_annotations

    packed = false
    unless node.union?
      process_annotations(annotations) do |ann|
        packed = true if ann == @program.packed_annotation
      end
    end

    type = current_type.types[node.name]?
    if type
      unless type.is_a?(NonGenericClassType)
        node.raise "#{node.name} is already defined as #{type.type_desc}"
      end

      if !type.extern? || (type.extern_union? != node.union?)
        node.raise "#{node.name} is already defined as #{type.type_desc}"
      end

      node.raise "#{node.name} is already defined"
    else
      type = NonGenericClassType.new(@program, current_type, node.name, @program.struct)
      type.struct = true
      type.extern = true
      type.extern_union = node.union?

      attach_doc type, node, annotations

      current_type.types[node.name] = type
    end

    node.resolved_type = type

    type.packed = packed

    false
  end

  def visit(node : TypeDef)
    annotations = read_annotations
    type = current_type.types[node.name]?

    if type
      node.raise "#{node.name} is already defined"
    else
      typed_def_type = lookup_type(node.type_spec)
      typed_def_type = check_allowed_in_lib node.type_spec, typed_def_type
      type = TypeDefType.new @program, current_type, node.name, typed_def_type

      attach_doc type, node, annotations

      current_type.types[node.name] = type
    end

    false
  end

  def visit(node : EnumDef)
    check_outside_exp node, "declare enum"

    annotations = read_annotations

    scope, name, enum_type = lookup_type_def(node)

    if enum_type
      unless enum_type.is_a?(EnumType)
        node.raise "#{name} is not a enum, it's a #{enum_type.type_desc}"
      end
    end

    if base_type = node.base_type
      enum_base_type = lookup_type(base_type)
      unless enum_base_type.is_a?(IntegerType)
        base_type.raise "enum base type must be an integer type"
      end

      if enum_type && enum_base_type != enum_type.base_type
        base_type.raise "enum #{name}'s base type is #{enum_type.base_type}, not #{enum_base_type}"
      end
    end

    existed = !!enum_type
    enum_type ||= EnumType.new(@program, scope, name, enum_base_type || @program.int32)

    enum_type.private = true if node.visibility.private?

    process_annotations(annotations) do |annotation_type, ann|
      enum_type.flags = true if annotation_type == @program.flags_annotation
      enum_type.add_annotation(annotation_type, ann)
    end

    record_export scope, name, node.exported?
    enum_type.private = true if unexported_in_unit?(scope, node.exported?)

    node.resolved_type = enum_type
    attach_doc enum_type, node, annotations

    pushing_type(enum_type) do
      visit_enum_members(node, node.members, existed, enum_type)
    end

    unless existed
      num_members = enum_type.types.size
      if num_members > 0 && enum_type.flags?
        # skip None & All, they doesn't count as members for @[Flags] enums
        num_members = enum_type.types.count { |(name, _)| !name.in?("None", "All") }
      end

      if num_members == 0
        node.raise "enum #{node.name} must have at least one member"
      end

      if enum_type.flags?
        unless enum_type.types.has_key?("None")
          none_member = enum_type.add_constant("None", 0)

          if node_location = node.location
            none_member.add_location node_location
          end

          define_enum_none_question_method(enum_type, node)
        end

        unless enum_type.types.has_key?("All")
          all_value = enum_type.base_type.kind.cast(0).as(Int::Primitive)

          enum_type.types.each_value do |member|
            all_value |= interpret_enum_value(member.as(Const).value, enum_type.base_type)
          end

          all_member = enum_type.add_constant("All", all_value)

          if node_location = node.location
            all_member.add_location node_location
          end
        end
      end

      scope.types[name] = enum_type
    end

    false
  end

  def visit_enum_members(node, members, existed, enum_type, previous_counter = nil)
    members.reduce(previous_counter) do |counter, member|
      visit_enum_member(node, member, existed, enum_type, counter)
    end
  end

  def visit_enum_member(node, member, existed, enum_type, previous_counter = nil)
    case member
    when MacroIf
      expanded = expand_inline_macro(member, mode: Parser::ParseMode::Enum, accept: false)
      visit_enum_member(node, expanded, existed, enum_type, previous_counter)
    when MacroExpression
      expanded = expand_inline_macro(member, mode: Parser::ParseMode::Enum, accept: false)
      visit_enum_member(node, expanded, existed, enum_type, previous_counter)
    when MacroFor
      expanded = expand_inline_macro(member, mode: Parser::ParseMode::Enum, accept: false)
      visit_enum_member(node, expanded, existed, enum_type, previous_counter)
    when Expressions
      visit_enum_members(node, member.expressions, existed, enum_type, previous_counter)
    when Arg
      if existed
        node.raise "can't reopen enum and add more constants to it"
      end

      if enum_type.types.has_key?(member.name)
        member.raise "enum '#{enum_type}' already contains a member named '#{member.name}'"
      end

      if default_value = member.default_value
        counter = interpret_enum_value(default_value, enum_type.base_type)
      elsif previous_counter
        if enum_type.flags?
          if previous_counter == 0 # In case the member is set to 0
            counter = 1
          else
            counter = previous_counter &* 2
            unless (counter <=> previous_counter).sign == previous_counter.sign
              member.raise "value of enum member #{member} would overflow the base type #{enum_type.base_type}"
            end
          end
        else
          counter = previous_counter &+ 1
          unless counter > previous_counter
            member.raise "value of enum member #{member} would overflow the base type #{enum_type.base_type}"
          end
        end
      else
        counter = enum_type.base_type.kind.cast(enum_type.flags? ? 1 : 0).as(Int::Primitive)
      end

      if enum_type.flags? && !@in_lib
        if member.name == "None" && counter != 0
          member.raise "flags enum can't redefine None member to non-0"
        elsif member.name == "All"
          member.raise "flags enum can't redefine All member. None and All are autogenerated"
        end
      end

      if default_value.is_a?(Iyi::NumberLiteral)
        enum_base_kind = enum_type.base_type.kind
        if (enum_base_kind.i32?) && (enum_base_kind != default_value.kind)
          default_value.raise "enum value must be an Int32"
        end
      end

      define_enum_question_method(enum_type, member, enum_type.flags?)

      const_member = enum_type.add_constant(member.name, counter)
      member.default_value = const_member.value

      const_member.doc = member.doc
      check_ditto const_member, member.location

      if member_location = member.location
        const_member.add_location(member_location)
      end

      counter
    else
      member.accept self
      previous_counter
    end
  end

  # iyi: whether an impl method's declaration is written wider than the
  # symbol the producer will emit for it.
  #
  # Syntactic, and a union is the whole of it: this runs in the top-level
  # pass, where nothing has been inferred, and a union is the one written
  # form a body can answer narrower than. A virtual type is the other half
  # of the same question and belongs where the rest of it is asked, after
  # semantic — no impl in the tree needs it yet, and the module exercises
  # say so.
  private def iyi_impl_signature_widened?(a_def : Def) : Bool
    return true if a_def.return_type.is_a?(Union)
    a_def.args.any? { |argument| argument.restriction.is_a?(Union) }
  end

  def define_enum_question_method(enum_type, member, is_flags)
    method_name = is_flags ? "includes?" : "=="
    body = Call.new(Var.new("self").at(member), method_name, Path.new(member.name).at(member)).at(member)
    # iyi: written with its return type, because R-2 asks an exported
    # signature for one and this def is the *compiler's* (R-2's macro rule,
    # one kind of synthesis over). A `pub enum` in a module that writes its
    # `.iyimod` was refused on it — "`debug?` is exported and does not say
    # what it returns" — about a method nobody wrote and whose answer is
    # never anything but a `Bool`.
    a_def = Def.new("#{member.name.underscore}?", body: body,
      return_type: Path.global("Bool").at(member)).at(member)

    a_def.doc = if member.doc.try &.starts_with?(":nodoc:")
                  ":nodoc:"
                else
                  "Returns `true` if this enum value #{is_flags ? "contains" : "equals"} `#{member.name}`"
                end

    # Not the module's, so an artifact leaves it out: the consumer's own
    # compiler writes this one from the members it reads. See
    # `Def#iyi_compiler_made`.
    a_def.iyi_compiler_made = true
    enum_type.add_def a_def
  end

  def define_enum_none_question_method(enum_type, node)
    body = Call.new(Call.new(nil, "value").at(node), "==", NumberLiteral.new(0)).at(node)
    # Its return type for the reason the one above carries one.
    a_def = Def.new("none?", body: body, return_type: Path.global("Bool").at(node)).at(node)
    a_def.iyi_compiler_made = true
    enum_type.add_def a_def
  end

  def visit(node : Expressions)
    node.expressions.each_with_index do |child, i|
      child.accept self
    rescue ex : SkipMacroException
      @program.macro_expansion_error_hook.try &.call(ex.cause) if ex.is_a? SkipMacroCodeCoverageException
      node.expressions.delete_at(i..-1)
      break
    end
    false
  end

  def visit(node : Assign)
    type_assign(node.target, node.value, node)
    false
  end

  def type_assign(target : Var, value, node)
    @vars[target.name] = MetaVar.new(target.name)
    value.accept self
    false
  end

  def type_assign(target : Path, value, node, declared_type : ASTNode? = nil)
    node.raise "constant type declaration requires a value" unless value

    # We are inside the assign, so we go outside it to check if we are inside an outer expression
    @exp_nest -= 1
    check_outside_exp node, "declare constant"
    @exp_nest += 1

    annotations = read_annotations

    name = target.names.last
    scope = lookup_type_def_scope(target, target)
    type = scope.types[name]?
    if type
      target.raise "already initialized constant #{type}"
    end

    const = Const.new(@program, scope, name, value)
    # iyi: here, because here is the only place the value is still what the
    # shard wrote. See `Const#iyi_value_source`.
    const.iyi_value_source = value.to_s
    const.declared_type = declared_type
    const.private = true if target.visibility.private?

    # iyi: an unmarked constant is the module's own, the same as an unmarked
    # `def` (R-2). Without this every constant a module declared was reachable
    # through its name — `Kemal::Config::INSTANCE` and the rest — which is a
    # surface nobody wrote and nobody could refuse.
    const.private = true if unexported_in_unit?(scope, target.exported?)
    record_export scope, name, target.exported?

    process_annotations(annotations) do |annotation_type, ann|
      # annotations on constants are inaccessible in macros so we only add deprecations
      const.add_annotation(annotation_type, ann) if annotation_type == @program.deprecated_annotation
    end

    check_ditto node, node.location
    attach_doc const, node, annotations

    scope.types[name] = const

    target.target_const = const
  end

  def type_assign(target, value, node)
    value.accept self

    # Prevent to assign instance variables inside nested expressions.
    # `@exp_nest > 1` is to check nested expressions. We cannot use `inside_exp?` simply
    # because `@exp_nest` is increased when `node` is `Assign`.
    if @exp_nest > 1 && target.is_a?(InstanceVar)
      node.raise "can't use instance variables at the top level"
    end

    false
  end

  def visit(node : VisibilityModifier)
    node.exp.visibility = node.modifier
    node.exp.accept self

    # Can only apply visibility modifier to def, type, macro or a macro call
    case exp = node.exp
    when ClassDef, ModuleDef, EnumDef, Alias, LibDef
      if node.modifier.private?
        return false
      else
        node.raise "can only use 'private' for types"
      end
    when Assign
      if exp.target.is_a?(Path)
        if node.modifier.private?
          return false
        else
          node.raise "can only use 'private' for constants"
        end
      end
    when Def
      return false
    when Macro
      if node.modifier.private?
        return false
      else
        node.raise "can only use 'private' for macros"
      end
    when Call
      # Don't give an error yet: wait to see if the
      # call doesn't resolve to a method/macro
      return false
    end

    node.raise "can't apply visibility modifier"
  end

  def visit(node : ProcLiteral)
    old_vars_keys = @vars.keys

    node.def.args.each do |arg|
      @vars[arg.name] = MetaVar.new(arg.name)
    end

    node.def.body.accept self

    # Now remove these vars, but only if they weren't vars before
    node.def.args.each do |arg|
      @vars.delete(arg.name) unless old_vars_keys.includes?(arg.name)
    end

    false
  end

  def visit(node : FunDef)
    check_outside_exp node, "declare fun"

    if node.body && !current_type.is_a?(Program)
      node.raise "can only declare fun at lib or global scope"
    end

    annotations = read_annotations

    # We'll resolve the external args types later, in TypeDeclarationVisitor
    external_args = node.args.map do |arg|
      Arg.new(arg.name).at(arg.location)
    end

    external = External.new(node.name, external_args, node.body, node.real_name).at(node)
    external.name_location = node.name_location

    call_convention = nil
    process_def_annotations(external, annotations) do |annotation_type, ann|
      if annotation_type == @program.call_convention_annotation
        call_convention = parse_call_convention(ann, call_convention)
      elsif annotation_type == @program.primitive_annotation
        process_def_primitive_annotation(external, ann)
      else
        ann.raise "funs can only be annotated with: NoInline, AlwaysInline, Naked, ReturnsTwice, Raises, CallConvention"
      end
    end

    node.doc ||= annotations_doc(annotations)
    check_ditto node, node.location

    # Copy call convention from lib, if any
    scope = current_type
    if !call_convention && scope.is_a?(LibType)
      call_convention = scope.call_convention
    end

    if scope.is_a?(LibType)
      external.wasm_import_module = scope.wasm_import_module
    end

    # We fill the arguments and return type in TypeDeclarationVisitor
    external.doc = node.doc
    external.call_convention = call_convention
    external.varargs = node.varargs?
    external.fun_def = node
    external.return_type = node.return_type
    node.external = external

    current_type.add_def(external)

    false
  end

  def visit(node : TypeDeclaration)
    case var = node.var
    when Var
      @vars[var.name] = MetaVar.new(var.name)
    when Path
      type_assign(var, node.value, node, node.declared_type)
      return false
    end

    # Because the value could be using macro expansions
    node.value.try &.accept(self)

    false
  end

  def visit(node : UninitializedVar)
    if (var = node.var).is_a?(Var)
      @vars[var.name] = MetaVar.new(var.name)
    end
    false
  end

  def visit(node : MultiAssign)
    node.targets.each do |target|
      var = target.is_a?(Splat) ? target.exp : target
      if var.is_a?(Var)
        @vars[var.name] = MetaVar.new(var.name)
      end
      target.accept self
    end

    node.values.each &.accept self
    false
  end

  def visit(node : Rescue)
    if name = node.name
      @vars[name] = MetaVar.new(name)
    end

    node.body.accept self

    false
  end

  def visit(node : Call)
    # iyi: `derive equality` inside a type body (SPEC.md R-5, II.4). The macro
    # runs once here, in the module that declares the type, and what it
    # generates belongs to this module like any other declaration.
    if node.name == "derive" && node.obj.nil? && !@derive_owners.empty?
      expand_derive node
      return false
    end

    node.scope = node.global? ? @program : current_type.metaclass
    !expand_macro(node, raise_on_missing_const: false, first_pass: true)
  end

  private def expand_derive(node : Call)
    owner = @derive_owners.last

    if node.args.empty? || node.named_args || node.block
      node.raise "`derive` takes one or more exported macro names, for example `derive equality`"
    end

    generated = [] of ASTNode
    first_macro = nil

    # One expansion per name, left to right. Each reads the same declaration,
    # and each generates declarations of this module like any other.
    node.args.each do |argument|
      name = derive_macro_name(argument)

      # The macro is handed a description of the declaration, never the
      # declaration itself. R-5 promises it the attached declaration's shape; a
      # live or cloned `ClassDef` would also carry this `derive` node, and the
      # artifact walk that follows a macro's inputs would have a cycle to chase.
      call = Call.new(nil, name, [describe_derive_target(owner, node)] of ASTNode).at(node)
      call.scope = current_type.metaclass

      # Marked while the macro runs, so the program-wide type questions can be
      # refused for the length of the expansion (SPEC.md II.4).
      expanded =
        begin
          @program.expanding_derive = true
          expand_macro(call, raise_on_missing_const: false, first_pass: true)
        ensure
          @program.expanding_derive = false
        end

      unless expanded
        argument.raise "`#{name}` is not an available derive macro. Define it as " \
                       "`pub macro #{name}(declaration)` and import or `using` its module"
      end

      if call_expanded = call.expanded
        generated << call_expanded
      end
      first_macro ||= call.expanded_macro
    end

    # `expanded_macro` names one macro and this line may have run several. It
    # feeds error traces and `tool expand`, not the artifact, so it carries the
    # first and the expansions carry the rest.
    node.expanded = generated.size == 1 ? generated.first : Expressions.new(generated)
    node.expanded_macro = first_macro
  end

  # The bounded facts R-5 lets a derive read: the declaration's own name, and
  # the fields written in its body, each with the type it was written as.
  # Nothing else, and nothing that reaches back into the tree, so a derive sees
  # the same declaration whether its module is compiled from source or read
  # from an artifact.
  #
  # Handing over the `ClassDef` itself, live or cloned, is what this replaces.
  # That declaration contains the `derive` node, so the walk that follows a
  # macro's inputs had a cycle to chase and never finished (SPEC.md II.4).
  private def describe_derive_target(owner : ClassDef, derive : Call) : ASTNode
    fields = [] of ASTNode
    body = owner.body
    declarations = body.is_a?(Expressions) ? body.expressions : [body]

    seen_derive = false
    declarations.each do |declaration|
      if declaration.same?(derive)
        seen_derive = true
        next
      end

      # A macro call in the body may declare fields, and `getter n : Int32` is
      # the everyday one. Above the derive it has already expanded, so its
      # declarations are there to read. Below, it has not, and reading the body
      # would silently answer without them: a derive that generates a method
      # over no fields at all. That is refused rather than guessed at.
      if seen_derive && declaration.is_a?(Call) &&
         declaration.expanded.nil? && declaration.name != "derive"
        derive.raise "`#{derive_macro_name(derive.args.first)}` cannot read `#{declaration.name}` " \
                     "because it is written below the derive, and a macro's declarations only " \
                     "exist once it has run. Move `derive` below `#{declaration.name}`"
      end

      collect_derive_fields declaration, fields
    end

    NamedTupleLiteral.new([
      NamedTupleLiteral::Entry.new("name", StringLiteral.new(owner.name.names.last)),
      NamedTupleLiteral::Entry.new("fields", ArrayLiteral.new(fields)),
    ])
  end

  # Fields written directly, and fields a macro above the derive wrote for it.
  # Only the body's own level and macro expansions: a `Def` is left alone, so a
  # declaration inside a method body is not a field.
  private def collect_derive_fields(node : ASTNode, fields : Array(ASTNode)) : Nil
    case node
    when Expressions
      node.expressions.each { |expression| collect_derive_fields expression, fields }
    when Call
      expanded = node.expanded
      collect_derive_fields expanded, fields if expanded
    when TypeDeclaration
      var = node.var
      return unless var.is_a?(InstanceVar)

      fields << NamedTupleLiteral.new([
        NamedTupleLiteral::Entry.new("name", StringLiteral.new(var.name)),
        NamedTupleLiteral::Entry.new("type", derive_field_type(node.declared_type)),
      ])
    end
  end

  # The type a field was written as, resolved to the type it names. This is the
  # fact that lets a derive ask whether a field's type implements a trait, which
  # is the question a `JSON` derive has to answer about an imported `Customer`
  # (SPEC.md II.4).
  #
  # Read from the annotation rather than from the instance variable: an instance
  # variable's type is settled by `TypeDeclarationVisitor`, a later pass, and
  # there is nothing to ask yet when a derive runs. R-2 is what makes the
  # annotation enough — what a module exports carries written types.
  #
  # A name this module cannot see answers `nil` rather than raising, so a derive
  # can be written for a field whose type it does not need to know about.
  private def derive_field_type(node : ASTNode) : ASTNode
    type = current_type.lookup_type?(node, allow_typeof: false)
    type ? TypeNode.new(type) : NilLiteral.new
  rescue Iyi::TypeException
    NilLiteral.new
  end

  private def derive_macro_name(name : ASTNode) : String
    case name
    when Path
      names = name.names
      return names.first if names.size == 1
      name.raise "expected an exported macro name after `derive`, not a path"
    when Call
      return name.name if name.obj.nil? && name.args.empty? && !name.block
      name.raise "expected an exported macro name after `derive`, not a call"
    else
      name.raise "expected an exported macro name after `derive`, not an expression"
    end
  end

  def visit(node : ProcPointer)
    # A proc pointer at the top-level might refer to a macro, so we check
    # that here but we don't yet give an error: we let the real semantic visitor
    # (MainVisitor) do that job to avoid duplicating code.
    obj = node.obj

    call = Call.new(obj, node.name).at(obj)
    call.scope = current_type.metaclass
    node.call = call

    expand_macro(call, raise_on_missing_const: false, first_pass: true)

    false
  end

  def visit(node : Out)
    exp = node.exp
    if exp.is_a?(Var)
      @vars[exp.name] = MetaVar.new(exp.name)
    end
    true
  end

  def visit(node : Block)
    # Remember how many local vars we had before the block
    old_vars_size = @vars.size

    # When accepting a block, declare variables for block arguments.
    # These are needed for macro expansions to parser identifiers
    # as variables and not calls.
    node.args.each do |arg|
      @vars[arg.name] = MetaVar.new(arg.name)
    end

    node.body.accept self

    # After the block we should have the same number of local vars
    # (blocks can't declare inject local vars to the outer scope)
    while @vars.size > old_vars_size
      @vars.delete(@vars.last_key)
    end

    false
  end

  # iyi: *from_impl* is set by `visit(ImplDef)`, the one caller that may
  # legitimately include a trait. Everywhere else the caller is a written
  # `include` or `extend`, and including a trait is what R-3 removes: a type
  # acquires a trait by having an impl, which the orphan rule can check.
  # iyi: the target's own type parameters, so an impl's `include` can name them
  # (SPEC.md II.6 × II.7). Nil for a non-generic target, which is every impl
  # that has nothing to bind.
  private def impl_target_free_vars(target_type) : Hash(String, TypeVar)?
    return nil unless target_type.is_a?(GenericType)

    free_vars = {} of String => TypeVar
    target_type.type_vars.each do |type_var|
      free_vars[type_var] = target_type.type_parameter(type_var)
    end
    free_vars
  end

  def include_in(current_type, node, kind : HookKind, from_impl = false, free_vars = nil)
    node_name = node.name

    type = lookup_type(node_name, free_vars: free_vars)

    # Checked before the generic branch: a bare `include Into` on a generic
    # trait is a trait mistake, not a missing-type-arguments one.
    if type.trait? && !from_impl
      directive = kind.extended? ? "extend" : "include"
      node_name.raise "can't #{directive} #{type}, it's a trait. A type implements a trait by having an `impl #{type} for #{current_type.instance_type}`, which is what lets the orphan rule check it — see SPEC.md R-3"
    end

    case type
    when GenericModuleType
      node.raise "generic type arguments must be specified when including #{type}"
    when .module?
      # OK
    else
      node_name.raise "#{type} is not a module, it's a #{type.type_desc}"
    end

    if node_name.is_a?(Path)
      @program.check_deprecated_type(type, node_name)
    end

    begin
      current_type.as(ModuleType).include type
      run_hooks hook_type(type), current_type, kind, node
    rescue ex : MacroRaiseException
      # Make the inner most exception to be the include/extend node so that it's the last frame in the trace.
      # This will make the location show on that node instead of the `raise` call.
      ex.inner = Iyi::MacroRaiseException.for_node node, ex.message

      raise ex
    rescue ex : TypeException
      node.raise "at '#{kind}' hook", ex
    end
  end

  def has_hooks?(type_with_hooks)
    hooks = type_with_hooks.as?(ModuleType).try &.hooks
    !hooks.nil? && !hooks.empty?
  end

  def run_hooks(type_with_hooks, current_type, kind : HookKind, node, call = nil)
    type_with_hooks.as?(ModuleType).try &.hooks.try &.each do |hook|
      next if hook.kind != kind

      expansion = expand_macro(hook.macro, node, visibility: :public) do
        if call
          @program.expand_macro hook.macro, call, current_type.instance_type
        else
          @program.expand_macro hook.macro.body, current_type.instance_type
        end
      end

      node.add_hook_expansion(expansion)
    end

    if kind.inherited?
      # In the case of:
      #
      #    class A(X); end
      #    class B < A(Int32);end
      #
      # we need to go from A(Int32) to A(X) to go up the hierarchy.
      if type_with_hooks.is_a?(GenericClassInstanceMetaclassType)
        run_hooks(type_with_hooks.instance_type.generic_type.metaclass, current_type, kind, node)
      elsif (superclass = type_with_hooks.instance_type.superclass)
        run_hooks(superclass.metaclass, current_type, kind, node)
      end
    end
  end

  private def hook_type(type)
    type = type.generic_type if type.is_a?(GenericInstanceType)
    type.metaclass
  end

  def parse_call_convention(ann, call_convention)
    if call_convention
      ann.raise "call convention already specified"
    end

    if ann.args.size != 1
      ann.wrong_number_of_arguments "annotation CallConvention", ann.args.size, 1
    end

    call_convention_node = ann.args.first
    unless call_convention_node.is_a?(StringLiteral)
      call_convention_node.raise "argument to CallConvention must be a string"
    end

    value = call_convention_node.value
    call_convention = LLVM::CallConvention.parse?(value)
    unless call_convention
      call_convention_node.raise "invalid call convention. Valid values are #{LLVM::CallConvention.values.join ", "}"
    end
    call_convention
  end

  def attach_doc(type, node, annotations)
    if @program.wants_doc?
      type.doc ||= node.doc
      type.doc ||= annotations_doc(annotations) if annotations
    end

    if node_location = node.location
      type.add_location(node_location)
    end
  end

  def check_ditto(node : Def | Assign | FunDef | Const | Macro | TypeDeclaration, location : Location?) : Nil
    return if !@program.wants_doc?

    if stripped_doc = node.doc.try &.strip
      if stripped_doc == ":ditto:"
        node.doc = @last_doc
        return
      elsif appendix = stripped_doc.lchop?(":ditto:\n")
        node.doc = "#{@last_doc}\n\n#{appendix.lchop('\n')}"
        return
      end
    end

    @last_doc = node.doc
  end

  def annotations_doc(annotations)
    annotations.try(&.first?).try &.doc
  end

  def process_def_annotations(node, annotations, &)
    process_annotations(annotations) do |annotation_type, ann|
      case annotation_type
      when @program.no_inline_annotation
        node.no_inline = true
      when @program.always_inline_annotation
        node.always_inline = true
      when @program.naked_annotation
        node.naked = true
      when @program.returns_twice_annotation
        node.returns_twice = true
      when @program.raises_annotation
        node.raises = true
      when @program.target_feature_annotation
        ann.named_args.try &.each do |named_arg|
          case named_arg.name
          when "cpu"
            cpu_value = named_arg.value
            named_arg.raise "expected argument 'cpu' to be String" unless cpu_value.is_a?(StringLiteral)
            node.target_cpu = cpu_value.value
          else
            named_arg.raise "no argument named '#{named_arg.name}', expected 'cpu'"
          end
        end

        if ann.args.size > 0
          ann.raise "wrong number of arguments for TargetFeature (given #{ann.args.size}, expected 0..1)" if ann.args.size > 1
          features_value = ann.args[0]
          ann.raise "expected argument #1 to 'TargetFeature' to be String" unless features_value.is_a?(StringLiteral)
          node.target_features = features_value.value
        end
      else
        yield annotation_type, ann
      end
    end
  end

  def lookup_type_def(node : ASTNode)
    path = node.name
    scope = lookup_type_def_scope(node, path)
    name = path.names.last
    type = scope.types[name]?
    # iyi: the first doc comment a type was given stays its doc. Crystal
    # let every reopening with a comment replace it, so a type the
    # prelude opens in three files was described by the last file's note
    # (`Int32` by float.iyi's line on division), and `iyi doc` read that.
    if type && node.doc
      type.doc ||= node.doc
    end
    {scope, name, type}
  end

  def lookup_type_def_scope(node : ASTNode, path : Path)
    scope =
      if path.names.size == 1
        if path.global?
          if node.visibility.private?
            path.raise "can't declare private type in the global namespace; drop the `private` for the top-level namespace, or drop the leading `::` for the file-private namespace"
          end
          program
        else
          if current_type.is_a?(Program)
            file_module = program.check_private(node)
          end
          file_module || current_type
        end
      else
        prefix = path.clone
        prefix.names.pop
        iyi_check_not_reopening(node, path, prefix)
        lookup_type_def_name_creating_modules prefix
      end

    check_type_is_type_container(scope, path)
  end

  # iyi: R-3, at the declaration that tries to get around it.
  #
  # `struct App::A::Point` inside another module is what somebody writes when
  # they want to add a method to a type they imported. Crystal reads it as
  # reopening. iyi cannot, so the path does not resolve here and the next few
  # lines would helpfully create `Main::App`, `Main::App::A` and a second
  # `Point` in them. The program then fails somewhere else entirely, with
  # `wrong number of arguments for 'Main::App::A::Point.new'`, and the reader
  # has no way back to the rule they broke.
  #
  # So: if the path names a type that exists somewhere this file can see, the
  # declaration is refused here instead. Only for `.iyi` files, because a
  # qualified declaration is exactly how a `.cr` file reopens a type, which is
  # a thing Crystal has and iyi does not.
  private def iyi_check_not_reopening(node : ASTNode, path : Path, prefix : Path) : Nil
    filename = path.location.try(&.filename)
    return unless filename.is_a?(String) && filename.ends_with?(".iyi")

    # `module app/formal` is a qualified declaration the parser wrote, not one
    # the author did, and two modules under `app/` share the namespace by
    # design. The marker is the parser's own.
    return if node.responds_to?(:iyi_unit?) && node.iyi_unit?

    # The namespace being declared into, and then the type itself: `struct
    # App::A::Point` is refused because `App::A` is somebody else's, and
    # `struct App::A` because `App::A` is.
    existing = [prefix, path].compact_map do |candidate|
      current_type.lookup_path(candidate).as?(Type) || program.lookup_path(candidate).as?(Type)
    end.first?
    return unless existing

    # A namespace this file declared is its own to add to.
    locations = existing.locations
    return if locations.try &.any? { |location| location.filename == filename }

    declared_in = locations.try(&.first?).try(&.filename)
    where = declared_in.is_a?(String) ? " (declared in `#{declared_in}`)" : ""

    path.raise <<-MSG
      `#{path}` already exists#{where}, and this file cannot add to it

      R-3: iyi has no open classes. A type's methods are the ones its own module
      declares, which is what lets a consumer answer "does this type implement
      that trait?" by reading one `.iyimod` instead of the whole program.

      Add the method where the type is declared, or write `impl Trait for #{path}`
      here, which R-3 allows when the trait is this module's.
      MSG
  end

  def check_type_is_type_container(scope, path)
    if scope.is_a?(EnumType) || !scope.is_a?(ModuleType)
      path.raise "can't declare type inside #{scope.type_desc} #{scope}"
    end

    scope
  end

  def lookup_type_def_name_creating_modules(path : Path)
    base_type = path.global? ? program : current_type
    target_type = base_type.lookup_path(path, lookup_in_namespace: false).as?(Type).try &.remove_alias_if_simple

    unless target_type
      next_type = base_type
      path.names.each do |name|
        next_type = base_type.lookup_path_item(name, lookup_self: false, lookup_in_namespace: false, include_private: true, location: path.location)
        if next_type
          if next_type.is_a?(ASTNode)
            path.raise "expected #{name} to be a type"
          end
        else
          base_type = check_type_is_type_container(base_type, path)
          next_type = NonGenericModuleType.new(@program, base_type.as(ModuleType), name)
          if (location = path.location)
            next_type.add_location(location)
          end
          base_type.types[name] = next_type
        end
        base_type = next_type
      end
      target_type = next_type
    end

    unless target_type.is_a?(NamedType)
      path.raise "#{target_type} can't be used as a namespace"
    end

    target_type
  end

  # Turns all finished macros into expanded nodes, and
  # adds them to the program
  def process_finished_hooks
    @finished_hooks.each do |hook|
      self.current_type = hook.scope
      expansion = expand_macro(hook.macro, hook.macro, visibility: :public) do
        @program.expand_macro hook.macro.body, hook.scope
      end
      program.add_finished_hook(hook.scope, hook.macro, expansion)
    end
  end
end
