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

    @target_keys = Set({String, Int32, Int32}).new
    @target_names = Set(String).new
    # The files the adopted defs are declared in: under R-1 only a module
    # that imports one of them, directly or through another, can refer to
    # them, which is how the server picks which entries to compile.
    getter target_files = Set(String).new
    # The types the adopted defs belong to, for rename's question: is the
    # new name one of theirs already.
    @target_owners = [] of Type
    @program : Program? = nil
    @collecting = false

    def initialize(@target_location : Location)
    end

    def process(result : Compiler::Result) : Bool
      @program = result.program
      process_result result
      result.node.accept self
      return false if @target_keys.empty?

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
        if (name_location = node.name_location) && node.target_defs.try &.any? { |d| key?(d.location) }
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

    # Pass one: adopt a def whose name the cursor sits on. Pass two: a def
    # carrying an adopted key is a declaration to report.
    private def consider(node : Def) : Nil
      location = node.location
      return unless location
      name_location = node.name_location || location
      name_size = node.name.size

      if @collecting
        @declarations << {name_location, name_size} if key?(location)
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
      @target_keys << key_of(location)
      @target_names << node.name
      @target_files << location.filename.to_s
      if owner = node.owner?
        @target_owners << owner unless @target_owners.any?(&.same?(owner))
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

    # The filename half of the key, in one spelling. An imported module's
    # file is `File.join(root, "calc/lexer.iyi")`, and `File.join` spells
    # the joint the platform's way and leaves the module path's own `/`
    # alone — so on Windows the importer's compile names the def's file
    # `...\gate\calc/lexer.iyi` while the cursor's names it
    # `...\gate\calc\lexer.iyi`, and a reference from a file nobody opened
    # never matched the def it calls (step 32 of `bench/lsp_session.py`,
    # the first time it ran there). Compared case-blind on Windows too,
    # which is what its filesystem does.
    private def key_of(location : Location) : {String, Int32, Int32}
      {canonical(location.filename.to_s), location.line_number, location.column_number}
    end

    private def canonical(filename : String) : String
      {% if flag?(:win32) %}
        filename.tr("/", "\\").downcase
      {% else %}
        filename
      {% end %}
    end

    private def key?(location : Location?) : Bool
      location ? @target_keys.includes?(key_of(location)) : false
    end
  end
end
