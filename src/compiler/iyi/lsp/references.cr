# iyi: references, off the typed graph — the inverse of
# `ImplementationsVisitor`. A reference is not "the same spelling"; it is
# a call whose `target_defs` resolved to the def under the cursor. That
# is the difference between a language server and a text search, and the
# typed AST already knows it: overloads that share a name but not a
# resolution stay untouched, and callers in other modules are found
# because the front end bound them, not because a regex hoped.
#
# The def under the cursor is keyed by its *source location*: every typed
# instantiation of one written def carries the def's own location, so one
# key collects all of them and a generic's many instances count as one
# answer.
#
# Two passes over one typed result. The first finds what the cursor
# names — a call adopts its `target_defs`, a def adopts itself. The
# second collects every call that resolves into the adopted set, every
# declaration that carries an adopted key, and every name an `import` selects
# of an adopted name — the gate found that last one by renaming a def
# and watching the `import` line it left behind refuse to compile.
require "../syntax/ast"
require "../compiler"
require "../tools/typed_def_processor"

module Iyi::Lsp
  class ReferencesVisitor < Visitor
    include TypedDefProcessor

    # Call sites and declarations, each as {name location, name size}.
    getter references = [] of {Location, Int32}
    getter declarations = [] of {Location, Int32}

    # The adopted defs' keys, which are the seeds of every other entry's
    # visitor (see `initialize`).
    getter target_keys = Set({String, Int32, Int32, String}).new
    @target_names = Set(String).new
    # The files the adopted defs are declared in: under R-1 only a module
    # that imports one of them, directly or through another, can refer to
    # them, which is how the server picks which entries to compile.
    getter target_files = Set(String).new
    # The types the adopted defs belong to, for rename's question: is the
    # new name one of theirs already.
    @target_owners = [] of Type
    # iyi: why a rename of the adopted defs cannot be written, or nil. A
    # def a macro wrote (`getter x`) has no name of its own in the source,
    # and a `new` the compiler made from `initialize` has none at all: a
    # rename rewrote the call sites and left the declaration, or wrote the
    # new name over the `def` keyword.
    getter unrenameable : String? = nil
    @program : Program? = nil
    @collecting = false
    # The adopted defs themselves, for `link_trait_methods` to read their
    # owners and arity from, and for go-to-implementation to answer with.
    getter adopted = [] of Def

    # *seeds* are the keys another compile adopted (`target_keys`): a def
    # carrying one is adopted here too, wherever the cursor is. The cursor
    # names a place in its own file, and an importer's compile holds that
    # file only when it is the def's: asked from a call in `app.iyi`, a
    # sibling `other.iyi` matched nothing, and rename edited `app.iyi` and
    # the def and left `other.iyi` calling a name that was gone.
    def initialize(@target_location : Location, @seeds = Set({String, Int32, Int32, String}).new)
    end

    def process(result : Compiler::Result) : Bool
      @program = result.program
      process_result result
      result.node.accept self
      return false if @target_keys.empty?
      link_trait_methods(result.program)

      @collecting = true
      process_result result
      result.node.accept self

      @references.uniq!
      @declarations.uniq!
      true
    end

    def process_typed_def(typed_def : Def) : Nil
      consider typed_def
      typed_def.accept self
    end

    def visit(node : Call)
      # Definition-site probes are calls too, and they resolve to the
      # def under the cursor by construction. A person asking "who calls
      # this" is not asking about the compiler's own probe.
      return true if node.iyi_synthetic?
      if @collecting
        if (name_location = node.name_location) && node.target_defs.try &.any? { |d| key?(d) }
          @references << {name_location, node.name.size}
        end
      elsif node.location && @target_location.between?(node.name_location, node.name_end_location)
        node.target_defs.try &.each { |target| adopt target }
      end
      true
    end

    def visit(node : Def)
      consider node
      true
    end

    # An `import` line that selects a target's name references it — and has
    # to move with a rename, or the program the rename leaves behind does
    # not compile. Names are matched, then the path is checked against
    # the files the targets live in: `import greet::{shout}` counts only
    # if some target def's file is `<something>/greet.iyi`.
    def visit(node : UsingDecl)
      return true unless @collecting
      names = node.names
      name_locations = node.name_locations
      return true unless names && name_locations

      # Asked of the posix reading, the way `Compiler.header_root_of` asks
      # the same question: a module path is posix by grammar (R-1) and a
      # target's file is spelled the platform's way, so on Windows no file
      # ever ended with `/greet.iyi` and a rename left every `import` line
      # behind — step 13 of `bench/lsp_session.py`, the first time it ran
      # there.
      suffix = "/#{node.path.join('/')}.iyi"
      return true unless @target_files.any? { |file| ::Path[file].to_posix.to_s.ends_with?(suffix) }

      names.each_with_index do |name, index|
        if @target_names.includes?(name) && (name_location = name_locations[index]?)
          @references << {name_location, name.size}
        end
      end
      true
    end

    def visit(node)
      true
    end

    # Pass one: adopt a def whose name the cursor sits on, or one another
    # compile adopted (`@seeds`). Pass two: a def carrying an adopted key
    # is a declaration to report.
    private def consider(node : Def) : Nil
      location = node.location
      return unless location
      name_location = node.name_location || location
      name_size = node.name.size

      if @collecting
        @declarations << {name_location, name_size} if key?(node) && !node.new?
        return
      end

      if @seeds.includes?(key_of(node))
        adopt node
        return
      end

      name_end = Location.new(
        name_location.filename, name_location.line_number,
        name_location.column_number + name_size - 1)
      adopt node if @target_location.between?(name_location, name_end)
    end

    private def adopt(node : Def) : Nil
      location = node.location
      return unless location
      @adopted << node if @target_keys.add?(key_of(node))
      @target_names << node.name
      # The file the def is written in: for a macro's def, the file the
      # macro was expanded in, not the expansion's name, which is no file
      # and sent the server compiling every entry of the workspace.
      @target_files << (location.original_filename || location.filename.to_s)
      if node.new?
        @unrenameable ||= "#{node.name} is made from initialize and has no declaration of its own to rename"
      elsif location.filename.is_a?(VirtualFile)
        @unrenameable ||= "#{node.name} is written by a macro, and the rename would leave the macro's argument behind"
      end
      if owner = node.owner?
        @target_owners << owner unless @target_owners.any?(&.same?(owner))
      end
    end

    # iyi: a trait's requirement and every method that answers it are one
    # method to a caller - a call on a value typed by the trait reaches
    # whichever implementation the value has. So adopting any of them
    # adopts the rest: the trait's own def (abstract or default) and the
    # def of that name and arity on every type that implements the trait.
    # A rename of `Square#area` rewrote its def and every call and left
    # `abstract def area` in `Shape`, and the program it left said `impl
    # Shape for Square is missing a method required by the trait: area`;
    # references from the requirement answered the requirement alone.
    private def link_trait_methods(program : Program) : Nil
      linked = [] of {Type, String, Int32}
      @adopted.each do |a_def|
        owner = a_def.owner?
        next unless owner
        instance = owner.instance_type
        ([instance] + instance.ancestors).each do |ancestor|
          owner_trait = ancestor.is_a?(GenericInstanceType) ? ancestor.generic_type.as(Type) : ancestor
          next unless owner_trait.trait? && owner_trait.defs.try(&.has_key?(a_def.name))
          entry = {owner_trait, a_def.name, a_def.args.size}
          linked << entry unless linked.any? { |(seen, name, arity)| seen.same?(owner_trait) && name == entry[1] && arity == entry[2] }
        end
      end
      return if linked.empty?

      each_type(program) do |type|
        # Not the struct definition-site typing synthesizes to probe a
        # trait-typed parameter: its stub `def area` is stamped with the
        # trait's own location, and a rename wrote the new name over
        # `trait` in `pub trait Shape`.
        next if type.to_s.starts_with?(WITNESS_PREFIX)
        linked.each do |(wanted, name, arity)|
          answers = type.same?(wanted) || type.ancestors.any? do |ancestor|
            ancestor.same?(wanted) || (ancestor.is_a?(GenericInstanceType) && ancestor.generic_type.same?(wanted))
          end
          next unless answers
          type.defs.try &.[name]?.try &.each do |item|
            adopt item.def if item.def.args.size == arity
          end
        end
      end
    end

    # The name `DefinitionTyping` gives its witness structs.
    WITNESS_PREFIX = "IyiDefTypeWitness_"

    private def each_type(type : Type, &block : Type ->) : Nil
      type.types?.try &.each_value do |inner|
        block.call inner
        each_type(inner, &block)
      end
    end

    # Whether *name* is already a method where the adopted defs are: on
    # their type, on what it inherits, or at the top level, where a bare
    # call looks last. A rename onto it made two defs one name, and the
    # later of two with one signature replaces the earlier: renaming
    # `shout` to an existing `yell` turned `puts shout("a")`'s "A" into
    # "a!", with nothing refused.
    def taken?(name : String) : Bool
      return false if @target_names.includes?(name)
      return true if @target_owners.any? { |owner| !owner.lookup_defs(name).empty? }
      program = @program
      !!program && !program.lookup_defs(name).empty?
    end

    # The file of a module in this compile that brings an adopted def in
    # unqualified, by name or with `::*`, and already has *name* where the
    # renamed import would land: a def of its own, or another import's.
    # Its own beats the import (SPEC.md II.3 rule 2), so the rename would
    # rebind that module's calls to its own def with nothing to say so -
    # `puts shout("a")` printing "a!" where it printed "A" - and a second
    # import of *name* makes every call ambiguous. Nil when no module here
    # is taken; `taken?` answers for the defs' own scope.
    def importer_taking(name : String) : String?
      program = @program
      return nil unless program
      return nil if @target_names.includes?(name)
      units = @target_owners.map(&.instance_type)
      scopes = [program.as(Type)]
      while scope = scopes.pop?
        scope.types?.try &.each_value { |nested| scopes << nested }
        used = scope.using_modules?
        next unless used
        next unless used.any? { |imported| units.any?(&.same?(imported.type)) && @target_names.any? { |old| imported.exports?(old) } }
        if !scope.lookup_defs(name).empty? || used.any?(&.exports?(name))
          return scope.as?(ModuleType).try(&.iyi_unit_file) || scope.to_s
        end
      end
      nil
    end

    # The filename half of the key, in one spelling. An imported module's
    # file is `File.join(root, "calc/lexer.iyi")`, and `File.join` spells
    # the joint the platform's way and leaves the module path's own `/`
    # alone — so on Windows the importer's compile names the def's file
    # `...\gate\calc/lexer.iyi` while the cursor's names it
    # `...\gate\calc\lexer.iyi`, and a reference from a file nobody opened
    # never matched the def it calls (step 32 of `bench/lsp_session.py`,
    # the first time it ran there). Compared case-blind on Windows too,
    # which is what its filesystem does.
    # iyi: the def's name is part of the key: a `new` made from an
    # `initialize` carries the initialize's location, and keyed by place
    # alone the two were one def - a rename of `Point.new` wrote the new
    # name over `def initialize`, keyword and name both.
    private def key_of(node : Def) : {String, Int32, Int32, String}
      location = node.location.not_nil!
      {canonical(file_key(location.filename)), location.line_number, location.column_number, node.name}
    end

    # iyi: a macro's expansion is a VirtualFile whose name is the macro's
    # alone ("expanded macro: getter"), so every `getter x : T` in the
    # program put its def at one line and column of one "file", and
    # references to `p.x` listed every getter call in the program. The
    # site the macro was expanded at tells two expansions apart, and reads
    # the same in every compile of the same source.
    private def file_key(filename : String | VirtualFile | Nil) : String
      if filename.is_a?(VirtualFile) && (site = filename.expanded_location)
        "#{file_key(site.filename)}:#{site.line_number}:#{site.column_number}:#{filename.macro.name}"
      else
        filename.to_s
      end
    end

    private def canonical(filename : String) : String
      {% if flag?(:win32) %}
        filename.tr("/", "\\").downcase
      {% else %}
        filename
      {% end %}
    end

    private def key?(node : Def) : Bool
      node.location ? @target_keys.includes?(key_of(node)) : false
    end
  end
end
