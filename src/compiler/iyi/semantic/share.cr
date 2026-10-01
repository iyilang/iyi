# iyi: SPEC.md III.4.4's `Share` — the marker that says a value may be
# reached from two threads. Decided structurally, per type, the way
# `bench/share_count.cr` counted it before it was built: a type is
# shareable if none of its fields is mutable and every field's type is
# shareable, where a field is mutable if any method other than `initialize`
# assigns it or a setter `field=` is defined for it; or it is trusted
# (`@[Share]`), shareable whenever its type arguments are, for the short
# list that owns what it holds. Everything is a type-level fact: no
# ownership, no borrowing, no flow — R-3's closed types are what make it
# computable once per declaration.
#
# The mutation half reads bodies, so it can only be answered for a type
# declared in this compilation. A type read from an artifact carries the
# answer instead — its producer wrote `@[Share]` into the declaration it
# exported when it found the type shareable — and is never recomputed here:
# what a consumer sees of it is fields and method headers, and a header
# cannot say whether the body assigns.
#
# What it gates today: the block `IyiThread.start` captures (III.4.11), in
# `CleanupTransformer`. A channel's element type is next, with the channel
# that crosses threads.
module Iyi::Share
  # Shareable, or a sentence saying why not: the first field that fails and
  # the reason, one level at a time.
  def self.reason(type : Type) : String?
    reason(type, Set(Type).new)
  end

  def self.shareable?(type : Type) : Bool
    reason(type).nil?
  end

  private def self.reason(type : Type, visiting : Set(Type)) : String?
    # A recursive type reached again while its own check is open is not
    # the fault; whatever fails, fails elsewhere.
    return nil if visiting.includes?(type)
    visiting.add(type)
    begin
      check(type, visiting)
    ensure
      visiting.delete(type)
    end
  end

  private def self.check(type : Type, visiting : Set(Type)) : String?
    case type
    when NilType, BoolType, CharType, IntegerType, FloatType, SymbolType, VoidType, NoReturnType
      nil
    when EnumType
      nil
    when TypeParameter, TypeSplat
      # A generic's own parameter, as its producer sees the field: the
      # consumer's instantiation is where the argument is checked.
      nil
    when AliasType
      reason(type.aliased_type, visiting)
    when TypeDefType
      reason(type.typedef, visiting)
    when MetaclassType, GenericClassInstanceMetaclassType, VirtualMetaclassType
      nil
    when PointerInstanceType
      "#{type} is raw memory, which no marker can vouch for"
    when StaticArrayInstanceType
      "#{type} is a fixed buffer whose elements are written in place"
    when ProcInstanceType
      "#{type} is a closure, and what it captured is not written in its type"
    when TupleInstanceType
      type.tuple_types.each do |member|
        if why = reason(member, visiting)
          return "#{type} holds #{member}: #{why}"
        end
      end
      nil
    when NamedTupleInstanceType
      type.entries.each do |entry|
        if why = reason(entry.type, visiting)
          return "#{type} holds #{entry.name} : #{entry.type}: #{why}"
        end
      end
      nil
    when UnionType
      type.union_types.each do |member|
        if why = reason(member, visiting)
          return "#{type} may be #{member}: #{why}"
        end
      end
      nil
    when VirtualType
      # A value typed as the base may be any subclass; every one must hold.
      if why = reason(type.base_type, visiting)
        return why
      end
      type.base_type.all_subclasses.each do |subclass|
        if why = reason(subclass, visiting)
          return "#{type} may be #{subclass}: #{why}"
        end
      end
      nil
    when GenericClassInstanceType
      if trusted?(type)
        trusted_arguments(type, visiting)
      elsif type.generic_type.iyi_from_artifact?
        "#{type} came from an artifact whose producer did not find it shareable"
      else
        structural(type, visiting)
      end
    when GenericModuleInstanceType, NonGenericModuleType, GenericModuleType
      # A module as a value's type is its including types, which the virtual
      # form above enumerates; a bare module here is a type with no fields.
      nil
    when NonGenericClassType
      if type.iyi_share_trusted?
        nil
      elsif type.iyi_from_artifact?
        "#{type} came from an artifact whose producer did not find it shareable"
      else
        structural(type, visiting)
      end
    when GenericClassType
      # The uninstantiated generic, as a producer asks about it: shareable
      # when its own fields are, with its parameters standing for whatever
      # a consumer instantiates it with — the consumer checks those.
      if type.iyi_share_trusted?
        nil
      else
        structural(type, visiting)
      end
    else
      "#{type} (#{type.class}) has no shareability rule"
    end
  end

  private def self.trusted?(type : GenericClassInstanceType) : Bool
    type.generic_type.iyi_share_trusted?
  end

  # `@[Share]` on the generic: shareable whenever its arguments are.
  private def self.trusted_arguments(type : GenericClassInstanceType, visiting : Set(Type)) : String?
    type.type_vars.each do |name, var|
      next unless var.is_a?(Var)
      argument = var.type?
      next unless argument
      if why = reason(argument, visiting)
        return "#{type}'s #{name} is #{argument}: #{why}"
      end
    end
    nil
  end

  # The structural half: every field immutable after `initialize`, every
  # field's type shareable. An instance's defs are its generic's, read with
  # the instance's type arguments: a macro in one expands on the instance.
  private def self.structural(type : Type, visiting : Set(Type)) : String?
    mutated = mutated_fields(type)
    if type.responds_to?(:all_instance_vars)
      type.all_instance_vars.each do |name, var|
        if how = mutated[name]?
          return "#{type}'s field #{name} is #{how}"
        end
        var_type = var.type?
        next unless var_type
        if why = reason(var_type, visiting)
          return "#{type}'s field #{name} : #{var_type} is not shareable: #{why}"
        end
      end
    end
    nil
  end

  # Field name -> how it is mutable: "assigned in `clear`" or "given a setter
  # `count=`", for the structural half above. Read off the type's own defs
  # and its ancestors' — its superclasses and the modules it includes — once
  # per type.
  @@mutations = {} of Type => Hash(String, String)

  private def self.mutated_fields(type : Type) : Hash(String, String)
    @@mutations[type] ||= scan_mutations(type)
  end

  private def self.scan_mutations(type : Type) : Hash(String, String)
    found = {} of String => String
    each_type_and_ancestor(type) do |owner|
      next unless owner.responds_to?(:defs)
      defs = owner.defs
      next unless defs
      defs.each do |name, list|
        list.each do |entry|
          a_def = entry.def
          if name.ends_with?('=') && name != "==" && name != "!=" && name != "[]=" && name != "<=" && name != ">="
            field = "@#{name.rchop}"
            found[field] ||= "given a setter `#{name}`"
          end
          next if name == "initialize"
          scanner = MutationScanner.new(type, owner, a_def)
          a_def.body.accept(scanner)
          # A macro that needs more than the type to expand — one reading a
          # `forall` variable — is read in the instances the typer kept on
          # the type, where it has expanded. A block-taking instance is kept
          # by its call site rather than by the type, and is not read here.
          if scanner.unexpanded? && type.is_a?(DefInstanceContainer)
            type.def_instances.each_value do |instance|
              instance.body.accept(scanner) if instance.iyi_origin.same?(a_def)
            end
          end
          scanner.fields.each do |field|
            found[field] ||= "assigned in `#{name}`"
          end
        end
      end
    end
    found
  end

  # The class, then everything it inherits from: its superclasses and the
  # modules it and they include. The superclasses alone were walked, so a
  # field assigned only by a method of an included `module` read as
  # immutable: two threads bumping a counter through one compiled and
  # counted 2336841 of 4000000.
  private def self.each_type_and_ancestor(type : Type, &block : Type -> Nil) : Nil
    yield type
    type.ancestors.uniq!.each { |ancestor| yield ancestor }
  end

  # Every instance variable a body assigns, by any spelling, macro code
  # included. A macro is read as what it expands to on the type asked
  # about: walked as written it is the macro's text, and `@n += 1` inside
  # `{% if true %}`, or in a macro the method calls, was never seen — two
  # threads bumping a counter that way compiled and counted 2343960 of
  # 4000000.
  class MutationScanner < Visitor
    getter fields = Set(String).new
    # Some macro code here did not expand on the type alone.
    getter? unexpanded = false

    # A macro that keeps calling itself is the typer's to refuse, and a
    # method nothing calls is never typed; the scan stops instead.
    NESTING = 32

    def initialize(@scope : Type, @path_lookup : Type, @def : Def)
      @nesting = 0
    end

    def visit(node : Assign) : Bool
      note(node.target)
      true
    end

    def visit(node : OpAssign) : Bool
      note(node.target)
      true
    end

    def visit(node : MultiAssign) : Bool
      node.targets.each { |target| note(target) }
      true
    end

    def visit(node : MacroIf | MacroFor | MacroExpression) : Bool
      if expanded = node.expanded
        expanded.accept self
      else
        the_macro = Macro.new("macro_#{node.object_id}", [] of Arg, node).at(node)
        read_expansion(the_macro, node) { program.expand_macro(node, @scope, @path_lookup, nil, @def) }
      end
      false
    end

    def visit(node : Call) : Bool
      if expanded = node.expanded
        expanded.accept self
        return false
      end
      if the_macro = macro_called(node)
        read_expansion(the_macro, node) { program.expand_macro(the_macro, node, @scope, @scope, @def) }
        return false
      end
      true
    end

    def visit(node : ASTNode) : Bool
      true
    end

    private def program : Program
      @scope.program
    end

    # The macro a receiverless call names, found the way the typer finds it
    # from inside a method of the type.
    private def macro_called(node : Call) : Macro?
      return nil if node.obj || node.super? || node.previous_def?
      probe = Call.new(nil, node.name, node.args, named_args: node.named_args).at(node)
      probe.scope = @scope
      probe.lookup_macro
    rescue Iyi::CodeError
      nil
    end

    private def read_expansion(the_macro : Macro, node : ASTNode, &) : Nil
      if @nesting >= NESTING
        @unexpanded = true
        return
      end
      source, pragmas = yield
      locals = Set(String).new
      @def.args.each { |arg| locals << arg.name }
      expansion = program.parse_macro_source(source, pragmas, the_macro, node, locals, current_def: @def, inside_type: true)
      @nesting += 1
      begin
        expansion.accept self
      ensure
        @nesting -= 1
      end
    rescue Iyi::CodeError | Iyi::SkipMacroException
      @unexpanded = true
    end

    private def note(target : ASTNode) : Nil
      @fields << target.name if target.is_a?(InstanceVar)
    end
  end
end
