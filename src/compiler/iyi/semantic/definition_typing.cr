# iyi: definition-site typing — R-2c, the language rule the `check`
# probe grew up into.
#
# Lazy typing (inherited from Crystal) types a def when somebody calls
# it, so a build said "clean" about a body it never visited. R-2c closes
# that: every fully declared def in user code is typed at its
# definition, in the same compile as everything else — build, `check`,
# artifact emit and every LSP keystroke agree about what "clean" means.
#
# The probes are synthesized *after* the top-level pass, from resolved
# types, and that placement is load-bearing — a parse-time draft failed
# twice in ways worth keeping on record:
#
# - `def describe(e : Enumerable)` is fully written and still generic:
#   a trait_type restriction types per call (Crystal's own semantics), and
#   no parser can know which names are traits. Resolution first.
# - Probes visible to the top-level visitor met the macro expander
#   without a scope and crashed on the kemal port. Appended here, only
#   the main pass ever sees them.
#
# Mechanism: for each eligible def, a snippet at *global* scope — the
# resolved type names are absolute, so it types anywhere — calling it
# once with `uninitialized` values of the declared types, under
# `if false` so nothing can ever run. Instance methods get an
# `uninitialized Owner` receiver; module functions are called on the
# module itself. Every node is stamped with the def's own location, so
# a probe-found error anchors at the def it belongs to, and every
# synthesized call is marked so reference answers never count it.
#
# **Trait-restricted parameters get a witness.** `def total(s : Sized)`
# is generic, but the bound is written, and a bound is enough: the rule
# synthesizes one `struct IyiDefTypeWitnessN` per trait_type, implements the
# trait_type's abstract requirements with stub bodies, and probes the def
# with the witness — so a generic body calling anything *outside* its
# bound, or lying about its return, is caught at the definition. This
# is the half duck-typed generics never check and Rust checks
# always; here it costs one synthetic type per trait_type per compile.
#
# The probe is written at the top level and stamped with the def's own
# location, and `Call#check_visibility` lets a synthetic call through R-2's
# wall: it is the definition asking about itself, so a module's unmarked
# function and a type's `private def` are typed like an exported one.
# The fences that remain were each earned by a failure, kept on record:
# a non-`pub` *type* is not nameable from the top level and stays
# caller-typed (a spec's private `struct User`), impl-carried defs stay inside their
# trait_type context (R-3, the collections sample's `<=>`), `Program` is its
# own namespace so the nameable climb must stop there or hang, and
# witnesses are only built for simple traits — supertraits, generic and
# associated-type traits keep caller-typed bodies, stated rather than
# guessed at.
require "../syntax/ast"

module Iyi::DefinitionTyping
  def self.append_probes(program : Program, node : ASTNode) : Nil
    return unless node.is_a?(Expressions)
    runner = Runner.new(program)
    runner.collect
    runner.flush_into(node)
  end

  # One compile's worth of probes: the serial counter, the witness cache
  # and the synthesized nodes live for exactly one `semantic` run.
  private class Runner
    @serial = 0
    @probes = [] of ASTNode
    @witness_nodes = [] of ASTNode
    @witnesses = {} of Type => String?

    def initialize(@program : Program)
    end

    def collect : Nil
      files = user_files
      return if files.empty?

      each_owner do |owner|
        defs = owner.defs
        next unless defs
        defs.each_value do |overloads|
          overloads.each do |with_metadata|
            a_def = with_metadata.def
            filename = a_def.location.try(&.filename).as?(String)
            next unless filename && filename.ends_with?(".iyi") && files.includes?(filename)
            synthesize(owner, a_def)
          end
        end
      end
    end

    def flush_into(node : Expressions) : Nil
      return if @probes.empty?
      was_empty = node.expressions.empty?
      unless @witness_nodes.empty?
        # Witnesses are declarations, and declarations are the top-level
        # pass's business — which already ran. One more visitor over just
        # the witness nodes declares the structs and lands the impls; the
        # main pass then types their stub bodies like anything else.
        visitor = TopLevelVisitor.new(@program)
        wrapper = Expressions.new(@witness_nodes.dup)
        wrapper.accept(visitor)
        visitor.process_finished_hooks
      end
      # Prepend witness declarations and probes before user code so that
      # definition typing probes under `if false` do not overwrite the
      # program's return type. If the program had no expressions, keep Nil.
      node.expressions = @witness_nodes + @probes + node.expressions
      node.expressions << Nop.new if was_empty
    end

    # The entry file plus everything it imported: exactly the code this
    # build is responsible for. The prelude and `--crystal` sources never
    # appear here.
    private def user_files : Set(String)
      files = Set(String).new
      if entry = @program.filename
        files << entry
      end
      @program.iyi_module_imports.each do |file, imports|
        files << file
        imports.each { |imported| files << imported }
      end
      files
    end

    # Every type that can own a probeable def: the program itself (a
    # script's top-level defs), non-generic modules that are not traits,
    # and concrete classes and structs.
    private def each_owner(& : Type ->) : Nil
      yield @program
      queue = [] of Type
      if types = @program.types?
        types.each_value { |type| queue << type }
      end
      while type = queue.pop?
        case type
        when TraitType
          # Requirements and default methods stay caller-typed; a trait_type
          # body only means something against an implementer.
        when NonGenericModuleType
          yield type
        when NonGenericClassType
          yield type unless type.abstract?
        else
          # Not an owner the probe can stand a receiver up for.
        end
        if types = type.types?
          types.each_value { |inner| queue << inner }
        end
      end
    end

    private def synthesize(owner : Type, a_def : Def) : Nil
      return unless probable?(a_def)
      location = a_def.location
      return unless location

      # R-3 keeps impl-carried defs inside their trait_type context. R-2's
      # wall does not stop the probe: it is the def's own site asking, and
      # `Call#check_visibility` lets a synthetic call through - so a module's
      # unmarked function and a type's `private def` are typed at their
      # definition like anything else. Before that, `def f : Int32` with a
      # body answering `"s"` passed `check` and `build` whenever nothing
      # called it, and `pub` was what decided whether the rule applied.
      # The owner still has to be nameable from the top level: a spec's
      # `private struct User` is not, and stays caller-typed.
      return if a_def.iyi_from_impl?
      return unless nameable?(owner)
      # A plain `module` that is not a unit is a mixin: its instance defs
      # mean something on the type that includes it (`self` in
      # `Colorize::ObjectExtensions#colorize : Object(self)` is the includer),
      # and calling one on the module itself typed `self` as the module.
      return if owner.is_a?(NonGenericModuleType) && !owner.iyi_unit?

      argument_texts = [] of String
      a_def.args.each do |arg|
        restriction = arg.restriction
        return unless restriction
        resolved = resolve(owner, restriction)
        return unless resolved
        if resolved.is_a?(TraitType)
          # The bound is written, and a bound is enough: probe with a
          # witness that implements exactly the trait_type and nothing more.
          witness = witness_for(resolved)
          return unless witness
          argument_texts << witness
        else
          return unless instantiable?(resolved) && nameable?(resolved)
          argument_texts << resolved.to_s
        end
      end

      serial = (@serial += 1)
      lines = [] of String
      names = argument_texts.map_with_index do |text, index|
        name = "__iyi_dt_#{serial}_#{index}"
        lines << "#{name} = uninitialized #{text}"
        name
      end

      call =
        case owner
        when Program
          "#{a_def.name}(#{names.join(", ")})"
        when NonGenericModuleType
          "#{owner}.#{a_def.name}(#{names.join(", ")})"
        else
          receiver = "__iyi_dt_#{serial}_r"
          lines << "#{receiver} = uninitialized #{owner}"
          "#{receiver}.#{a_def.name}(#{names.join(", ")})"
        end

      # The return is verified when the declared type can be a variable;
      # a def honestly declared to return a trait_type still gets its body
      # typed, just not the assignment check.
      returned = a_def.return_type.try { |written| resolve(owner, written) }
      if returned && instantiable?(returned) && nameable?(returned) && !returned.nil_type?
        lines << "__iyi_dt_#{serial}_v : #{returned} = #{call}"
      else
        lines << call
      end

      parser = Parser.new("if false\n#{lines.join('\n')}\nend\n")
      parser.filename = location.filename
      parsed = parser.parse
      parsed.accept(Stamper.new(location))
      @probes << parsed
    rescue Iyi::CodeError
      # A type whose printed name does not re-parse (rare, and its own
      # bug elsewhere): the def stays caller-typed rather than the build
      # failing over a probe.
    end

    # The witness type's name for a trait_type, synthesizing it on first use —
    # or nil when the trait_type is not witnessable: supertraits, generic and
    # associated-type traits (those are `GenericTraitType` and never reach
    # here), and requirements the stub cannot write.
    private def witness_for(trait_type : TraitType) : String?
      if @witnesses.has_key?(trait_type)
        return @witnesses[trait_type]
      end
      @witnesses[trait_type] = build_witness(trait_type)
    end

    private def build_witness(trait_type : TraitType) : String?
      return nil unless trait_type.supertraits.empty?
      return nil unless nameable?(trait_type)

      # The name leaks into error messages ("undefined method 'length'
      # for ..."), so it carries the trait's own name: a reader meets
      # the witness *for Sized*, not an anonymous serial.
      witness = "IyiDefTypeWitness_#{trait_type.to_s.gsub("::", "_")}"
      stubs = [] of String

      if defs = trait_type.defs
        defs.each_value do |overloads|
          overloads.each do |with_metadata|
            requirement = with_metadata.def
            next unless requirement.abstract?
            stub = stub_for(trait_type, requirement, witness)
            return nil unless stub
            stubs << stub
          end
        end
      end

      text = String.build do |io|
        io << "struct " << witness << "\nend\n"
        io << "impl " << trait_type << " for " << witness << '\n'
        stubs.each { |stub| io << stub }
        io << "end\n"
      end

      parser = Parser.new(text)
      parser.filename = trait_type.locations.try(&.first?).try(&.filename) || "definition-typing-witness"
      parsed = parser.parse
      if location = trait_type.locations.try(&.first?)
        parsed.accept(Stamper.new(location))
      end
      @witness_nodes << parsed
      witness
    rescue Iyi::CodeError
      nil
    end

    # One requirement's stub: the signature re-spelled with absolute
    # names (`self` becomes the witness), the body an `uninitialized`
    # value of the return type. Operator names are requirements too and
    # travel verbatim.
    private def stub_for(trait_type : TraitType, requirement : Def, witness : String) : String?
      return nil if requirement.block_arity || requirement.block_arg
      return nil if requirement.splat_index || requirement.double_splat
      return nil if (free_vars = requirement.free_vars) && !free_vars.empty?

      params = requirement.args.map do |arg|
        restriction = arg.restriction
        return nil unless restriction
        text = requirement_type_text(trait_type, restriction, witness)
        return nil unless text
        "#{arg.name} : #{text}"
      end

      returns = requirement.return_type
      return nil unless returns
      return_text = requirement_type_text(trait_type, returns, witness)
      return nil unless return_text

      body =
        if return_text == "Nil"
          "    nil\n"
        else
          "    __iyi_dt_w = uninitialized #{return_text}\n    __iyi_dt_w\n"
        end

      "  def #{requirement.name}(#{params.join(", ")}) : #{return_text}\n#{body}  end\n"
    end

    private def requirement_type_text(trait_type : TraitType, written : ASTNode, witness : String) : String?
      return witness if written.is_a?(Self)
      resolved = resolve(trait_type, written)
      return nil unless resolved && instantiable?(resolved) && nameable?(resolved)
      resolved.to_s
    end

    private def resolve(owner : Type, written : ASTNode) : Type?
      owner.lookup_type?(written)
    rescue Iyi::CodeError
      nil
    end

    # A type an `uninitialized` variable can hold: concrete, this-world,
    # every union member included. Virtual types devirtualize first so an
    # abstract root answers as itself.
    private def instantiable?(type : Type) : Bool
      type = type.devirtualize
      if type.is_a?(UnionType)
        return type.union_types.all? { |member| instantiable?(member) }
      end
      return false if type.is_a?(GenericType)
      return false if type.module?
      return false if type.abstract?
      return false if type.is_a?(NoReturnType) || type.is_a?(VoidType)
      return false if type.metaclass?
      true
    end

    # Whether the type's printed name resolves from the program's top
    # level. The climb mirrors the R-2 check itself: crossing into an iyi
    # unit requires the unit to export the name.
    private def nameable?(type : Type) : Bool
      type = type.devirtualize
      if type.is_a?(UnionType)
        return type.union_types.all? { |member| nameable?(member) }
      end
      if type.is_a?(GenericClassInstanceType)
        return false unless nameable?(type.generic_type)
        return type.type_vars.each_value.all? do |var|
          !var.is_a?(Type) || nameable?(var)
        end
      end
      current = type
      while current.is_a?(NamedType)
        # A `private class` is file-private in the other language, and a
        # probe stands outside: it cannot write the name at all. R-2's
        # wall below stops it at an unexported one for the same reason —
        # and this one was missing, so a private class nested in an
        # exported one had its own defs probed by a name nobody can use
        # ("private constant referenced", pointing at the def).
        return false if current.private?
        namespace = current.namespace
        # `Program` is its own namespace (constructed `super(self, self,
        # "main")`); walking past it loops forever — call.cr's using walk
        # carries the same warning.
        break if namespace == current
        if namespace.iyi_unit? && !namespace.exported_name?(current.name)
          return false
        end
        break unless namespace.is_a?(NamedType)
        current = namespace
      end
      true
    end

    # A def the probe can honestly call: every parameter carries a
    # written type, the return is written, and there is no shape the
    # probe cannot synthesise — no block, no splats, no free vars, no
    # defaults, no receiver, a plainly callable name.
    private def probable?(a_def : Def) : Bool
      return false if a_def.block_arity || a_def.block_arg
      return false if a_def.splat_index || a_def.double_splat
      return false if (free_vars = a_def.free_vars) && !free_vars.empty?
      return false unless a_def.return_type
      return false if a_def.abstract?
      return false if a_def.receiver
      return false if a_def.name == "initialize"
      return false unless a_def.name.each_char.all? { |ch| ch.alphanumeric? || ch == '_' || ch.in?('?', '!') }
      return false unless a_def.name[0].lowercase? || a_def.name[0] == '_'
      a_def.args.all? do |arg|
        arg.restriction && !arg.default_value && arg.external_name == arg.name
      end
    end
  end

  # Sets every node's location to the def the probe belongs to, so the
  # error a probe finds points at the definition rather than at a
  # synthetic line no file contains — and marks every call as the
  # compiler's own, so reference answers never count it.
  private class Stamper < Visitor
    def initialize(@location : Location)
    end

    def visit(node : ASTNode) : Bool
      node.at(@location)
      node.iyi_synthetic = true if node.is_a?(Call)
      true
    end
  end
end
