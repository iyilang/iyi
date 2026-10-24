require "./program"
require "./syntax/ast"
require "./syntax/visitor"
require "./semantic/*"

# The overall algorithm for semantic analysis of a program is:
# - top level: declare classes, modules, macros, defs and other top-level stuff
# - new methods: create `new` methods for every `initialize` method
# - type declarations: process type declarations like `@x : Int32`
# - check abstract defs: check that abstract defs are implemented
# - class_vars_initializers (ClassVarsInitializerVisitor): process initializers like `@@x = 1`
# - instance_vars_initializers (InstanceVarsInitializerVisitor): process initializers like `@x = 1`
# - main: process "main" code, calls and method bodies (the whole program).
# - cleanup: remove dead code and other simplifications
# - check recursive structs (RecursiveStructChecker): check that structs are not recursive (impossible to codegen)

class Iyi::Program
  # Runs semantic analysis on the given node, returning a node
  # that's typed. In the process types and methods are defined in
  # this program.
  def semantic(node : ASTNode, cleanup = true, main_visitor : MainVisitor = MainVisitor.new(self)) : ASTNode
    node, processor = top_level_semantic(node, main_visitor)
    # iyi: definition-site typing (semantic/definition_typing.cr). After
    # the top-level pass every name is a type, so the probes are built
    # from *resolved* signatures and only the main pass ever sees them.
    DefinitionTyping.append_probes(self, node)
    semantic_after_top_level(node, processor, cleanup: cleanup, main_visitor: main_visitor)
  end

  # The passes that follow the top-level ones, split out so that the prelude
  # fork probe can run the top-level pass over the prelude and over the user
  # file separately and then finish over the combined tree. Calling
  # `top_level_semantic` and then this is exactly `semantic`.
  #
  # *also_check* is for the fork probe, whose prelude was processed by a
  # different `TypeDeclarationProcessor` in the parent. Its class-var check has
  # to happen here rather than earlier, because it can only run once the
  # initializers have been visited below.
  def semantic_after_top_level(node : ASTNode, processor : TypeDeclarationProcessor,
                               cleanup = true,
                               main_visitor : MainVisitor = MainVisitor.new(self),
                               also_check : TypeDeclarationProcessor? = nil) : ASTNode
    @progress_tracker.stage("Semantic (ivars initializers)") do
      visitor = InstanceVarsInitializerVisitor.new(self)
      Prof.span("  ivars: node.accept") { node.accept visitor }
      Prof.span("  ivars: finished hooks") { process_finished_hooks visitor }
      Prof.span("  ivars: visitor.finish") { visitor.finish }
    end

    @progress_tracker.stage("Semantic (cvars initializers)") do
      Prof.span("cvars: node.accept") { visit_class_vars_initializers(node) }
    end

    # Check that class vars without an initializer are nilable,
    # give an error otherwise
    processor.check_non_nilable_class_vars_without_initializers
    also_check.try &.check_non_nilable_class_vars_without_initializers

    result = @progress_tracker.stage("Semantic (main)") do
      Prof.span("main: visit_main") do
        visit_main(node, process_finished_hooks: true, cleanup: cleanup, visitor: main_visitor)
      end
    end

    @progress_tracker.stage("Semantic (cleanup)") do
      Prof.span("cleanup: types + files") do
        cleanup_types
        cleanup_files
      end
    end

    @progress_tracker.stage("Semantic (recursive struct check)") do
      Prof.span("recursive struct check") { RecursiveStructChecker.new(self).run }
    end

    result
  end

  # Processes type declarations and instance/class/global vars
  # types are guessed or followed according to type annotations.
  #
  # This alone is useful for some tools like doc or hierarchy
  # where a full semantic of the program is not needed.
  # *processor* lets a caller continue with an existing
  # `TypeDeclarationProcessor` instead of a fresh one. The processor accumulates
  # which type owns which instance variable, and `process_instance_vars_declarations`
  # only walks the owners *it* recorded — so a run that analyses a module and a
  # later run that analyses a type including that module have to share one, or
  # the second never learns to give the including type the module's variables.
  # Only the fork probe needs this today; a `.iyimod` would restore these tables
  # rather than recompute them.
  def top_level_semantic(node, main_visitor : MainVisitor = MainVisitor.new(self),
                         processor : TypeDeclarationProcessor? = nil)
    # A top-level pass is running, whatever an earlier one concluded. The flag
    # guards `TypeNode#instance_vars` and `#has_inner_pointers?` in macros, which
    # must refuse to answer until instance variables are declared. Leaving it set
    # from a previous pass — which only a split analysis can do — turns that
    # refusal into an empty answer, and the macro then generates code against
    # variables the type does not have yet.
    self.top_level_semantic_complete = false

    new_expansions = @progress_tracker.stage("Semantic (top level)") do
      visitor = TopLevelVisitor.new(self)

      # This is mainly for the interpreter so that vars are populated
      # for macro calls.
      # For compiled Crystal this should have no effect because we always
      # use a new MainVisitor which will have no vars.
      visitor.vars = main_visitor.vars.dup unless main_visitor.vars.empty?

      Prof.span("top level: node.accept") { node.accept visitor }
      Prof.span("top level: finished hooks") { visitor.process_finished_hooks }
      visitor.new_expansions
    end

    # Before anything else walks the tree: the imports collected above are not
    # in it yet, and every pass from here on has to see them.
    node = splice_iyi_module_initialisers(node)

    # And now that every import has been read, what their object code refers to
    # by name. Asked per import it was a stricter order than the question: `pg`
    # declares `PG` and `PQ`, each names the other, and no order of two
    # boundaries answers both. See `Program::IyiArtifactRef`.
    Prof.span("artifact references") { resolve_iyi_artifact_refs }

    @progress_tracker.stage("Semantic (new)") do
      Prof.span("new methods") { define_new_methods(new_expansions) }
    end
    node, processor = @progress_tracker.stage("Semantic (type declarations)") do
      Prof.span("type declarations") do
        (processor || TypeDeclarationProcessor.new(self)).process(node)
      end
    end

    @progress_tracker.stage("Semantic (abstract def check)") do
      Prof.span("abstract def check") { AbstractDefChecker.new(self).run }
    end

    unless @program.has_flag?("no_restrictions_augmenter")
      @progress_tracker.stage("Semantic (restrictions augmenter)") do
        Prof.span("restrictions augmenter") do
          node.accept RestrictionsAugmenter.new(self, new_expansions)
        end
      end
    end

    self.top_level_semantic_complete = true

    {node, processor}
  end

  # iyi: puts the imported modules' initialisers into the tree (SPEC.md III.5).
  #
  # `import` collects them instead of expanding them where it was written, so
  # this is where the compiler chooses when they run. The list is already in
  # the order the import DAG forces, and they go in as one block: after the
  # prelude, because an initialiser calls `puts` and allocates and so cannot
  # run before the runtime is up, and before the program's own code, because
  # that code is what would observe them.
  #
  # The entry file is not in the list — it is the program's own code, and being
  # last is exactly rule 1 applied to it.
  private def splice_iyi_module_initialisers(node : ASTNode) : ASTNode
    inits = @iyi_module_inits
    return node if inits.empty?
    @iyi_module_inits = [] of ASTNode

    inits = shuffle_iyi_module_initialisers(inits) unless has_flag?("release")

    expressions = node.is_a?(Expressions) ? node.expressions : [node] of ASTNode

    # The program's own code starts after the entry's *header block*: the
    # prelude require the compiler prepended, the `module` line, the
    # `require`s and the `import` lines (II.3 rule 4 makes that
    # block line-shaped). It used to be "the first node that is not a
    # `Require`", which under an `.iyi` entry is the module header —
    # so an entry's own `require "pg"` was spliced *after* the imported
    # modules' initialisers, and a shard whose top-level code registers
    # something ran after the module that used it. Crystal's semantics
    # are that a `require` runs where it is written, and an entry writes
    # its requires above everything.
    index = expressions.index do |exp|
      !(exp.is_a?(Require) || exp.is_a?(ModuleHeader) || exp.is_a?(ImportDecl) ||
        exp.is_a?(UsingDecl) || exp.is_a?(Nop))
    end || expressions.size
    expressions.insert(index, Expressions.from(inits))

    node.is_a?(Expressions) ? node : Expressions.new(expressions)
  end

  # iyi: reorders independent modules (SPEC.md III.5 rule 2).
  #
  # Rule 2 says the relative order of two modules that do not import each other
  # is *unobservable*, not merely unspecified — a module can only name what it
  # imports (R-1), reach what that module exports (R-2), and reopen nothing
  # (R-3), so an initialiser has nothing of an unrelated module to look at. A
  # rule nobody can observe is a rule that rots, so debug builds do not hand
  # out the same order twice: this walks the DAG the way Kahn's algorithm does
  # and picks at random among the modules whose imports have all been placed,
  # which produces a different valid topological order each build.
  #
  # Release builds keep the load order, so what ships is reproducible.
  # `IYI_INIT_SEED` pins the order, for a program that fails under one.
  private def shuffle_iyi_module_initialisers(inits : Array(ASTNode)) : Array(ASTNode)
    seed = ENV["IYI_INIT_SEED"]?.try &.to_u64?
    random = seed ? Random.new(seed) : Random.new

    by_file = {} of String => ASTNode
    pending = inits.map do |init|
      filename = init.as(FileNode).filename
      by_file[filename] = init
      filename
    end

    placed = Set(String).new
    ordered = Array(ASTNode).new(inits.size)

    until pending.empty?
      ready = pending.select do |filename|
        imports = @iyi_module_imports[filename]?
        # An import that is not in `by_file` was loaded by someone else and is
        # already placed; there is only ever one initialiser per module.
        imports.nil? || imports.all? { |dep| placed.includes?(dep) || !by_file.has_key?(dep) }
      end
      # Cannot be empty: `import` is refused a cycle, so some module's imports
      # are all placed. Falling back rather than dividing by zero if it is.
      ready = pending if ready.empty?

      chosen = ready[random.rand(ready.size)]
      pending.delete chosen
      placed << chosen
      ordered << by_file[chosen]
    end

    ordered
  end

  # This property indicates that the compiler has finished the top-level semantic
  # stage.
  # At this point, instance variables are declared and macros `#instance_vars`
  # and `#has_internal_pointers?` provide meaningful information.
  #
  # FIXME: Introduce a more generic method to track progress of compiler stages
  # (potential synergy with `ProcessTracker`?).
  property? top_level_semantic_complete = false
end
