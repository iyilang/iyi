require "../syntax/ast"
require "../syntax/visitor"
require "../types"

module Iyi
  class Program
    getter(iyi_share_reach : ShareReach) { ShareReach.new }
  end

  # iyi: the module state a block that crosses threads reaches through the
  # defs it calls (SPEC.md III.4.4). `CleanupTransformer#check_share_boundary`
  # refuses what the block names in its own text; a constant read one call
  # away was not seen, and that is where a program keeps its database pool:
  # a parallel block calling `ask`, which ran `DATABASE.query_one`, compiled
  # silently and at 12 workers answered other requests' rows (#148). This
  # walks the typed call graph from the block and lists every constant and
  # class variable met on the way, each with the shortest path of defs that
  # reaches it; the boundary check warns for those whose type is not Share.
  #
  # The walk covers the program's own modules and the packages it depends
  # on, and never std or the prelude, nor a constant std declares: a
  # dependency keeps module state the program cannot see as surely as the
  # program's own files do, and std's is its own to keep safe, which its
  # boundaries check where it is written. It stops where the capture check
  # does: a constant typed `Mutex`, `Atomic`, `List` or another trusted
  # `@[Share]` type is Share, and is not warned about, and their methods
  # are std's. A block given to a lock (`MUTEX.lock { ask }`) is walked like
  # any other: the lock guards what it holds, not the constants the block
  # reaches, which other code reaches without it - the reason a block
  # behind a lock may not name one either. Every target of a call is
  # walked, so a virtual call reaches each override, and a def met twice,
  # by recursion or by two paths, is walked once.
  #
  # What each def names and calls is read once per compilation and kept, so
  # a hundred routes reaching the same model functions read them once.
  class ShareReach
    # A constant or class variable a body names: *state* is the constant or
    # the class variable's cell, *label* how the source spells it, *use* the
    # expression it is used in (`DATABASE.query_one`).
    record Named, state : Const | MetaTypeVar, label : String, type : Type, use : String do
      def key : UInt64
        state.object_id
      end
    end

    # What one body names and the defs it calls, in the order written.
    record Facts, named : Array(Named), calls : Array(Def)

    # A named thing the walk found, and the defs that lead to it from the
    # block: the first is one the block calls, the last the one naming it.
    record Found, named : Named, path : Array(Def)

    def initialize
      @facts = {} of Def => Facts
      @facts.compare_by_identity
      @std_files = {} of String => Bool
      @std_dirs = {} of String => Bool
    end

    # Everything the block whose body is *block_def*'s reaches through the
    # defs it calls, each once, by the shortest path (fewest defs; the
    # first written among equals). What the block names in its own text is
    # left out: the boundary check asks about that, and refuses it.
    def reach(block_def : Def) : Array(Found)
      start = scan(block_def.body)
      seen = Set(UInt64).new
      start.named.each { |named| seen << named.key }
      visited = Set(Def).new.compare_by_identity
      queue = Deque({Def, Array(Def)}).new
      start.calls.each { |target| queue << {target, [target]} if visited.add?(target) }
      found = [] of Found
      while entry = queue.shift?
        a_def, path = entry
        facts = facts_of(a_def)
        facts.named.each do |named|
          found << Found.new(named, path) if seen.add?(named.key)
        end
        facts.calls.each do |target|
          queue << {target, path + [target]} if visited.add?(target)
        end
      end
      found
    end

    private def facts_of(a_def : Def) : Facts
      @facts[a_def] ||= scan(a_def.body)
    end

    private def scan(body : ASTNode) : Facts
      scanner = Scanner.new(self)
      body.accept scanner
      Facts.new(scanner.named, scanner.calls)
    end

    # The reason `@[SafeReach("...")]` on a constant or a class variable
    # gives: one string with something in it, since the reason is the
    # claim, and a bare mark would document nothing.
    def self.claim(ann : Annotation, what : String) : String
      reason = ann.args.first?
      unless ann.args.size == 1 && ann.named_args.nil? && reason.is_a?(StringLiteral) && !reason.value.blank?
        ann.raise "SafeReach takes one string, the reason every thread may reach #{what} through a call: `@[SafeReach(\"set once at startup, then only read\")]`"
      end
      reason.value
    end

    # The def as a path names it: `ask`, `Model.find`, `Pool#checkout`. A
    # function of an iyi module (`module main`) by its bare name, which is
    # how its own module and an import write it.
    def self.called(a_def : Def) : String
      owner = a_def.owner
      name = a_def.name.split(':').first
      type = owner.metaclass? ? owner.instance_type : owner
      return name if type.is_a?(Program) || type.is_a?(FileModule) || (owner.metaclass? && type.iyi_unit?)
      short = type.to_s.split('(').first.split("::").last
      owner.metaclass? ? "#{short}.#{name}" : "#{short}##{name}"
    end

    # Whether the walk goes into *a_def*: one written in the program or a
    # package.
    def walks?(a_def : Def) : Bool
      !std?(a_def)
    end

    # Whether *node* was written in std or the prelude: in a directory, or
    # under one, that holds `iyi/prelude.iyi`, which is where every module
    # of iyi's own library sits beside the prelude (`src/std/http.iyi`,
    # `src/iyi/prelude.iyi`). Read off the file rather than off the
    # directory the prelude was required from (`Program#iyi_prelude_dir`):
    # under `bin/iyi` that prefix matched none of std's files as the defs'
    # locations spell them, and the walk entered std's own `Server.serve`.
    def std?(node : ASTNode) : Bool
      file = node.location.try(&.original_filename)
      return false unless file
      @std_files.fetch(file) do
        @std_files[file] = std_dir?(File.dirname(File.expand_path(file)))
      end
    end

    private def std_dir?(dir : String) : Bool
      @std_dirs.fetch(dir) do
        parent = File.dirname(dir)
        @std_dirs[dir] = File.file?(File.join(dir, "iyi", "prelude.iyi")) || (parent != dir && std_dir?(parent))
      end
    end

    # One body's facts: every constant and class variable it names, once
    # each, and every def it calls that the walk enters. Macro code and the
    # nodes the typer expanded are read as their expansions, the blocks
    # given to calls as part of the body, and a proc's body too, since the
    # block may call it.
    class Scanner < Visitor
      getter named = [] of Named
      getter calls = [] of Def

      def initialize(@reach : ShareReach)
        @keys = Set(UInt64).new
        @defs = Set(Def).new.compare_by_identity
      end

      def visit(node : Call) : Bool
        if expanded = node.expanded
          expanded.accept self
          return false
        end
        node.target_defs.try &.each do |target|
          @calls << target if @reach.walks?(target) && @defs.add?(target)
        end
        case obj = node.obj
        when Path
          if (const = obj.target_const) && (type = obj.type?)
            note(const, obj.to_s, type, "#{obj}.#{node.name}")
          end
        when ClassVar
          if (var = obj.var?) && !var.thread_local? && (type = var.type?)
            note(var, obj.name, type, "#{obj.name}.#{node.name}")
          end
        end
        true
      end

      def visit(node : Path) : Bool
        if (const = node.target_const) && (type = node.type?)
          note(const, node.to_s, type, node.to_s)
        end
        false
      end

      def visit(node : ClassVar) : Bool
        if (var = node.var?) && !var.thread_local? && (type = var.type?)
          note(var, node.name, type, node.name)
        end
        false
      end

      def visit(node : ProcLiteral) : Bool
        node.def.body.accept self
        false
      end

      def visit(node : ProcPointer) : Bool
        node.expanded.try &.accept self
        false
      end

      def visit(node : ExpandableNode) : Bool
        if expanded = node.expanded
          expanded.accept self
          return false
        end
        true
      end

      # Not run: what `typeof` asks about is a type, and a nested
      # definition is not this body's code.
      def visit(node : TypeOf | Def | Macro | LibDef | AnnotationDef) : Bool
        false
      end

      def visit(node : ASTNode) : Bool
        true
      end

      # A constant std declares is std's to keep safe, as its defs are:
      # `STDOUT.puts` in a function a parallel block called warned that
      # `STDOUT : IyiIO` is not Share while `puts`, which writes the same
      # stream from inside std, said nothing.
      private def note(state : Const | MetaTypeVar, label : String, type : Type, use : String) : Nil
        return if state.is_a?(Const) && @reach.std?(state.value)
        @named << Named.new(state, label, type, use) if @keys.add?(state.object_id)
      end
    end
  end
end
