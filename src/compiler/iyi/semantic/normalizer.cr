require "../program"
require "../syntax/transformer"

module Iyi
  class Program
    def normalize(node, inside_exp = false, current_def = nil)
      normalizer = Normalizer.new(self)
      normalizer.current_def = current_def
      normalizer.macro_expansion = node if Normalizer.macro_expansion?(node)
      node.transform(normalizer)
    end
  end

  class Normalizer < Transformer
    getter program : Program

    # The current method where we are normalizing.
    # This is used to expand argless `super` and `previous_def`
    # to their version with arguments copied from the current method.
    property current_def : Def?

    # iyi: the top of a macro's expansion, when that is what is being
    # normalized. Its statements are the enclosing scope's, not a scope of
    # their own, so a `defer` among them is left standing for the main
    # visitor to lower over the rest of that scope
    # (`MainVisitor#iyi_splice_macro_defers`). Lowered here, it covered
    # nothing: `{% if true %} defer puts "a" {% end %}` printed "a" before
    # the body after it.
    property macro_expansion : ASTNode?

    @dead_code = false

    # A macro's expansion is parsed from a `VirtualFile`, and it is the
    # only source that is.
    def self.macro_expansion?(node : ASTNode) : Bool
      location = node.location
      location ||= node.expressions.first?.try(&.location) if node.is_a?(Expressions)
      location.try(&.filename).is_a?(VirtualFile)
    end

    def initialize(@program)
    end

    def before_transform(node)
      @dead_code = false
    end

    def after_transform(node)
      case node
      when Return, Break, Next
        @dead_code = true
      when If, Unless, Expressions, Block, Assign
        # Skip
      else
        @dead_code = false
      end
    end

    def transform(node : Expressions)
      exps = [] of ASTNode
      node.expressions.each do |exp|
        # iyi: a `defer` is left standing here on purpose. What it defers past
        # is everything after it in *this* list, which is only known once the
        # list is complete — see `apply_defers` below.
        if exp.is_a?(Defer)
          exp.exp = exp.exp.transform(self)
          exps << exp
          next
        end

        new_exp = exp.transform(self)
        if new_exp
          if new_exp.is_a?(Expressions)
            exps.concat new_exp.expressions
          else
            exps << new_exp
          end
        end
        break if @dead_code
      end
      exps = apply_defers(exps) unless node.same?(@macro_expansion)
      case exps.size
      when 0
        Nop.new
      else
        node.expressions = exps
        node
      end
    end

    # iyi: `defer` — cleanup that runs however the scope is left
    # (SPEC.md III.1.4).
    #
    # From:
    #
    #     a
    #     defer x
    #     b
    #     defer y
    #     c
    #
    # To:
    #
    #     a
    #     %live = true
    #     __iyi_defer_push(-> { x if %live; nil })
    #     begin
    #       b
    #       __iyi_defer_push(-> { y if %live; nil })
    #       begin
    #         c
    #       ensure
    #         %live = false
    #         __iyi_defer_pop_run
    #         %live = true
    #         y
    #       end
    #     ensure
    #       %live = false
    #       __iyi_defer_pop_run
    #       x
    #     end
    #
    # Every ordinary exit — falling off the end, a `return`, `!` expanding
    # to a `return` (III.1.2) — reaches the `ensure`, which runs the
    # cleanup there, inline, as the scope's own code. A panic reaches none
    # of them: `raise` never unwinds (there is no unwinder to link, by
    # design), so the cleanup is also registered, as a proc the runtime
    # holds, and the panic path walks the registry and runs what was never
    # popped. The ordinary exit disarms its proc before popping it, so the
    # registry stays balanced and the cleanup runs once.
    #
    # One `%live` serves every `defer` of the list: the pop runs only the
    # proc on top, which is the one being disarmed, and the flag is armed
    # again after it for the procs of the same list still registered. A
    # flag for each `defer` was a variable for each, and every handler
    # nested inside copies every variable in scope: N `defer`s in one
    # scope were N^2 copies.
    #
    # The proc used to be the only copy, run by the pop too, and a proc is
    # a closure: in a struct method it read a copy of `self` made at entry
    # (`defer puts @n` printed 0 after `@n = 2`) and wrote into that copy,
    # and every variable it named stopped narrowing. Inline, the cleanup is
    # typed and run as an `ensure` is; the proc runs only when the frame
    # never resumes, which is what lets the semantic pass keep a captured
    # variable's narrowing (`Def#iyi_defer?`).
    #
    # **LIFO falls out of the nesting** twice over: a second `defer`
    # expands inside the first one's body, so its push is later and its
    # pop earlier — and the registry is a stack, so the panic path
    # agrees.
    #
    # **The scope is the block, not the function.** This is a deliberate
    # departure from Go, and it is the shape of the lowering rather than an
    # extra rule: a `defer` in a loop body runs at the end of each iteration
    # instead of piling up until the function returns, which is Go's
    # best-known wart with the feature.
    def apply_defers(exps : Array(ASTNode), live : Var? = nil) : Array(ASTNode)
      index = exps.index { |exp| exp.is_a?(Defer) }
      return exps unless index

      deferred = exps[index].as(Defer)
      head = exps[0...index]

      if program.iyi_prelude?
        # An earlier `defer` of this list made the flag, and its proc is
        # still registered when this one is popped.
        outer = live
        live ||= Var.new(program.new_temp_var_name).at(deferred)
        rest = apply_defers(exps[(index + 1)..], live)
        # The trailing `nil` pins the proc to `-> Nil`: a proc literal
        # does not coerce its return the way a block restriction does,
        # and a cleanup's value is nobody's.
        armed = If.new(live.clone, deferred.exp.clone).at(deferred)
        cleanup_body = Expressions.new([armed, NilLiteral.new.at(deferred)] of ASTNode).at(deferred)
        cleanup = Def.new("->", [] of Arg, cleanup_body).at(deferred)
        cleanup.iyi_defer = true
        push = Call.global("__iyi_defer_push", ProcLiteral.new(cleanup).at(deferred)).at(deferred)
        pop = Call.new(nil, "__iyi_defer_pop_run", global: true).at(deferred)
        disarm = Assign.new(live.clone, BoolLiteral.new(false).at(deferred)).at(deferred)
        ordinary_exit = [disarm, pop] of ASTNode
        ordinary_exit << Assign.new(live.clone, BoolLiteral.new(true).at(deferred)).at(deferred) if outer
        ordinary_exit << deferred.exp
        head << Assign.new(live.clone, BoolLiteral.new(true).at(deferred)).at(deferred) unless outer
        head << push
        head << ExceptionHandler.new(rest, ensure: Expressions.new(ordinary_exit).at(deferred)).at(deferred).tap(&.iyi_defer=(true))
      else
        # Crystal's prelude has a real unwinder, so the classic shape —
        # the cleanup inline in the `ensure` — already runs on a panic.
        rest = apply_defers(exps[(index + 1)..])
        head << ExceptionHandler.new(rest, ensure: deferred.exp).at(deferred).tap(&.iyi_defer=(true))
      end
      head
    end

    # A `defer` that is not one of several expressions — the whole of a body,
    # say — has nothing after it to defer past, so all that is left of it is
    # the cleanup itself, still guarded so that it runs on an unwind.
    def transform(node : Defer)
      if node.same?(@macro_expansion)
        # A macro's whole expansion: left standing, as in a list of them.
        node.exp = node.exp.transform(self)
        return Expressions.new([node] of ASTNode).at(node)
      end
      ExceptionHandler.new(Nop.new, ensure: node.exp.transform(self)).at(node).tap(&.iyi_defer=(true))
    end

    # iyi: the typed group — SPEC.md III.4.9.
    #
    # From:
    #
    #     group do |g|
    #       x = g.spawn { read(a) }
    #       y = g.spawn { read(b) }
    #     end!
    #
    # To (inside the `!`'s own expansion):
    #
    #     group do |g|
    #       %h1 = g.spawn { read(a) }
    #       x = %h1
    #       %h2 = g.spawn { read(b) }
    #       y = %h2
    #       %v1 = %h1.value
    #       %v2 = %h2.value
    #       %first = g.first_failure
    #       if %v1.is_a?(::Error) && %h1.fiber.object_id == %first
    #         %v1
    #       elsif %v2.is_a?(::Error) && %h2.fiber.object_id == %first
    #         %v2
    #       elsif %v1.is_a?(::Error)
    #         %v1
    #       elsif %v2.is_a?(::Error)
    #         %v2
    #       else
    #         {%v1, %v2}
    #       end
    #     end
    #
    # The block stays a block, which is the hygiene: a name a task's body
    # uses stays scoped to it, instead of being inlined into the caller
    # where a later closure over the same name would freeze its type. The
    # group method answers what its block answers, so the appended
    # extraction *is* the group's value, and `!` applies through III.1.2's
    # ordinary machinery: the tuple's elements are non-error by the same
    # `is_a?(::Error)` narrowing `!` expands to, and the error side is the
    # union of what the branches answer. The method's deferred join stays
    # — a `return` between two spawns still joins.
    #
    # Under `end!` the values are read before any join: a read waits for
    # its task, and reading a panicked task's value is what catches the
    # panic as `Panicked` (III.1.4), so the deferred join finds nothing
    # owed. With a `g.join` first, the join re-raised the panic nobody had
    # read yet and the program died where the group was to answer
    # `Panicked`. A group without `!` joins first, as before: nothing
    # reads its answer for it, and a panic it swallowed into a discarded
    # tuple would be a bug nobody heard of.
    #
    # The error that leaves is the one that stopped the group: the first
    # failure cancels its siblings, and a sibling cancelled earlier in the
    # text answers `Cancelled`, which the slots in text order answered in
    # its place. The runtime keeps the failing task's object_id
    # (`IyiGroup#first_failure`), and its slot is asked first.
    #
    # Each slot reads a handle of its own (`%h1`, `%h2`), never the author's
    # variable: one name reused for two spawns (`t = g.spawn {..}` twice)
    # read the last task twice, answering {2, 2} for {1, 2} and losing the
    # first task's error.
    #
    # What qualifies is what the section says: the block's parameter is used
    # as the receiver of direct `spawn` statements and *nowhere else*, and
    # the block ends in one. A spawn in a loop, an `if`, a `g` that escapes,
    # or macro code anywhere in the block (whose expansion may spawn) falls
    # back quietly to the general form, whose group is its block's last
    # expression and whose handles answer through `task.value`; a `!`
    # demanding the typed form of a group that cannot have one is refused
    # by `!`'s own degenerate-union check, which names the type it found.
    # A block whose last expression is its own — `"sum is #{a.value}"`
    # after two spawns — answers that: the expansion threw it away and
    # answered the tuple.
    private def expand_iyi_group(node : Call, propagated : Bool) : ASTNode?
      block = node.block
      return nil unless block
      group_param = block.args.first?
      return nil unless group_param

      body = block.body
      statements = body.is_a?(Expressions) ? body.expressions.dup : [body] of ASTNode
      last = statements.last?
      return nil unless last && iyi_direct_spawn(last, group_param.name)

      handles = [] of ASTNode
      # Which handles are tuple slots. `_ = g.spawn {..}` is III.4.9's
      # explicit discard, and it took a slot all the same: `{30, 40}` for
      # `{40}`. Its value is still read below, so a failure that stopped
      # the group still leaves it and a panic still arrives as `Panicked`.
      slots = [] of Bool
      rewritten = [] of ASTNode

      statements.each do |statement|
        spawn_call = iyi_direct_spawn(statement, group_param.name)
        if spawn_call.is_a?(Call)
          # `%h1 = g.spawn {..}`, and the author's `x = %h1` after it.
          handle = Var.new(program.new_temp_var_name).at(statement)
          handles << handle
          discarded = statement.is_a?(Assign) && statement.target.is_a?(Underscore)
          slots << !discarded
          rewritten << Assign.new(handle.clone, spawn_call).at(statement)
          if statement.is_a?(Assign) && !discarded
            rewritten << Assign.new(statement.target, handle.clone).at(statement)
          end
        else
          # Any other use of the group parameter anywhere in the statement
          # disqualifies: the tuple's arity has to be a fact of the text.
          return nil if iyi_uses_var?(statement, group_param.name)
          rewritten << statement
        end
      end

      group_var = Var.new(group_param.name).at(node)
      rewritten << Call.new(group_var.clone, "join").at(node) unless propagated

      values = [] of ASTNode
      tuple = [] of ASTNode
      handles.each_with_index do |handle, index|
        value = Var.new(program.new_temp_var_name).at(node)
        values << value
        tuple << value.clone if slots[index]
        rewritten << Assign.new(value.clone, Call.new(handle.clone, "value").at(node)).at(node)
      end

      extraction = TupleLiteral.new(tuple).at(node).as(ASTNode)
      values.reverse_each do |value|
        is_error = IsA.new(value.clone, Path.global("Error").at(node)).at(node)
        extraction = If.new(is_error, value.clone, extraction).at(node)
      end

      if handles.size > 1
        first = Var.new(program.new_temp_var_name).at(node)
        rewritten << Assign.new(first.clone, Call.new(group_var.clone, "first_failure").at(node)).at(node)
        handles.zip(values).reverse_each do |handle, value|
          is_error = IsA.new(value.clone, Path.global("Error").at(node)).at(node)
          fiber_id = Call.new(Call.new(handle.clone, "fiber").at(node), "object_id").at(node)
          stopped_the_group = Call.new(fiber_id, "==", first.clone).at(node)
          extraction = If.new(And.new(is_error, stopped_the_group).at(node), value.clone, extraction).at(node)
        end
      end
      rewritten << extraction

      block.body = Expressions.new(rewritten).at(node)
      # The same call node, rewritten; the flag comes off so the transform
      # this returns into normalizes the new body instead of reasking.
      node.iyi_group = false
      node
    end

    # The statement's own spawn, when the statement is exactly a direct one:
    # `g.spawn { }` bare, or assigned to a variable or an underscore.
    private def iyi_direct_spawn(statement : ASTNode, group_name : String) : Call?
      target = statement.is_a?(Assign) ? statement.value : statement
      return nil unless target.is_a?(Call)
      return nil unless target.name == "spawn" && target.block
      receiver = target.obj
      return nil unless receiver.is_a?(Var) && receiver.name == group_name
      # The spawn's own block must not smuggle the group out either.
      spawn_block = target.block
      return nil if spawn_block && iyi_uses_var?(spawn_block, group_name)
      target
    end

    # Whether *node* uses the variable *name*, or holds macro code: what a
    # `{% for %}` writes is text until the main visitor expands it, so
    # `y{{i}} = g.spawn {..}` in one was invisible here, and the tuple came
    # out one slot short with those tasks' errors dropped.
    private def iyi_uses_var?(node : ASTNode, name : String) : Bool
      scan = IyiVarScan.new(name)
      node.accept(scan)
      scan.found?
    end

    # :nodoc:
    class IyiVarScan < Visitor
      getter? found = false

      def initialize(@name : String)
      end

      def visit(node : Var)
        @found = true if node.name == @name
        true
      end

      def visit(node : MacroIf | MacroFor | MacroExpression | MacroVerbatim | MacroLiteral)
        @found = true
        false
      end

      def visit(node : ASTNode)
        true
      end
    end

    def transform(node : Call)
      # iyi: the typed group (III.4.9). The parser marked the call; whether
      # the *typed* form applies is this file's question, and a `nil` answer
      # is the method call standing as written.
      if node.iyi_group?
        expanded = expand_iyi_group(node, node.same?(@propagated_group))
        return expanded.transform(self) if expanded
      end

      # Copy enclosing def's parameters to super/previous_def without parenthesis
      case node
      when .super?, .previous_def?
        named_args = node.named_args
        if node.args.empty? && (!named_args || named_args.empty?) && !node.has_parentheses?
          if current_def = @current_def
            splat_index = current_def.splat_index
            current_def.args.each_with_index do |arg, i|
              if splat_index && i > splat_index
                # Past the splat index we must pass arguments as named arguments
                named_args = node.named_args ||= Array(NamedArgument).new
                named_args.push NamedArgument.new(arg.external_name, Var.new(arg.name))
              elsif i == splat_index
                # At the splat index we must use a splat, except the bare splat
                # parameter will be skipped
                unless arg.external_name.empty?
                  node.args.push Splat.new(Var.new(arg.name))
                end
              else
                # Otherwise it's just a regular argument
                node.args.push Var.new(arg.name)
              end
            end

            # Copy also the double splat
            if arg = current_def.double_splat
              node.args.push DoubleSplat.new(Var.new(arg.name))
            end
          end
          node.has_parentheses = true
        end
      else
        # not a special call
      end

      # Convert 'a <= b <= c' to 'a <= b && b <= c'
      if comparison?(node.name) && (obj = node.obj) && obj.is_a?(Call) && comparison?(obj.name)
        case middle = obj.args.first
        when NumberLiteral, Var, InstanceVar
          transform_many node.args
          left = obj
          right = Call.new(middle.clone, node.name, node.args).at(middle)
        else
          temp_var = program.new_temp_var
          temp_assign = Assign.new(temp_var.clone, middle).at(middle)
          left = Call.new(obj.obj, obj.name, temp_assign).at(obj.obj)
          right = Call.new(temp_var.clone, node.name, node.args).at(node)
        end
        node = And.new(left, right).at(left)
        node = node.transform self
      else
        node = super
      end

      node
    end

    def comparison?(name)
      case name
      when "<=", "<", "!=", "==", "===", ">", ">="
        true
      else
        false
      end
    end

    def transform(node : Def)
      @current_def = node
      node = super
      @current_def = nil

      # If the def has a block argument without a specification
      # and it doesn't use it, we remove it because it's useless
      # and the semantic code won't have to bother checking it
      block_arg = node.block_arg
      if !node.uses_block_arg? && block_arg
        block_arg_restriction = block_arg.restriction
        if block_arg_restriction.is_a?(ProcNotation) && !block_arg_restriction.inputs && !block_arg_restriction.output
          node.block_arg = nil
        elsif !block_arg_restriction
          node.block_arg = nil
        end
      end

      node
    end

    def transform(node : Macro)
      node
    end

    def transform(node : If)
      node.cond = node.cond.transform(self)

      node.then = node.then.transform(self)
      then_dead_code = @dead_code

      node.else = node.else.transform(self)
      else_dead_code = @dead_code

      @dead_code = then_dead_code && else_dead_code
      node
    end

    # Convert unless to if:
    #
    # From:
    #
    #     unless foo
    #       bar
    #     else
    #       baz
    #     end
    #
    # To:
    #
    #     if foo
    #       baz
    #     else
    #       bar
    #     end
    # iyi: `read(path)!` — propagate an error member (SPEC.md III.1.2).
    #
    # From:
    #
    #     read(path)!
    #
    # To:
    #
    #     tmp = read(path)
    #     return tmp if tmp.is_a?(::Error)
    #     tmp
    #
    # No type information is needed here, and that is the point. `Error` is an
    # ordinary trait, so `is_a?` narrows the value in what follows to the
    # union's non-error members — which is exactly "if the value is a non-error
    # member, `expr!` evaluates to it". And "the enclosing function's return
    # type must already include E" is not a rule this has to enforce: it is the
    # ordinary return-type check on the `return` it just wrote.
    #
    # `::Error` rather than `Error`, so that a module of its own with that name
    # cannot change what the operator means.
    def transform(node : Propagate)
      if (group = node.exp).is_a?(Call) && group.iyi_group?
        @propagated_group = group
      end
      exp = node.exp.transform(self)
      temp_var = program.new_temp_var

      assign = Assign.new(temp_var.clone, exp).at(node)
      check = IsA.new(temp_var.clone, Path.global(["Error"]).at(node)).at(node)
      # A `group do ... end!` that kept the general form answers its block's
      # last expression, and the refusal of a `!` with nothing to propagate
      # says so (`MainVisitor#check_error_union_operand`).
      check.error_construct = exp.is_a?(Call) && exp.iyi_group? ? "end!" : "!"
      returned = Return.new(temp_var.clone).at(node)
      returned.from_propagate = true
      propagate = If.new(check, returned).at(node)

      Expressions.new([assign, propagate, temp_var.clone] of ASTNode).at(node)
    end

    # iyi: the `group do ... end!` whose `!` is being expanded: the typed
    # group reads its values before the join when its answer is propagated.
    @propagated_group : Call?

    # iyi: `read_port().or(8080)` and `read_port().or_panic` (SPEC.md III.1.3).
    #
    # From:
    #
    #     read_port().or(8080)          read_port().or_panic
    #
    # To:
    #
    #     tmp = read_port()             tmp = read_port()
    #     if tmp.is_a?(::Error)         if tmp.is_a?(::Error)
    #       8080                          ::raise tmp.message
    #     else                          else
    #       tmp                           tmp
    #     end                           end
    #
    # Same trick as `Propagate` above, and for the same reason: `is_a?` already
    # narrows both ways, so the result type falls out instead of being computed.
    # `.or` yields the default unioned with the non-error members; `.or_panic`
    # yields the non-error members alone, because `raise` is `NoReturn`.
    #
    # `tmp.message` is only reached where `tmp` has been narrowed to the error
    # members, and every one of those implements `Error` — so by II.1 the union
    # implements it too and `message` dispatches without either branch of this
    # having to know which error it holds.
    #
    # The default is evaluated only when there is an error to recover from,
    # which is what a reader of `||` would expect.
    #
    # `::raise` *is* the panic: III.1.4 is built, so the unwrap of this
    # design dies at the task boundary carrying the error's `message`.
    # The line the earlier revision promised would change changed by
    # not needing to.
    def transform(node : Recover)
      exp = node.exp.transform(self)
      temp_var = program.new_temp_var

      assign = Assign.new(temp_var.clone, exp).at(node)
      check = IsA.new(temp_var.clone, Path.global(["Error"]).at(node)).at(node)
      check.error_construct = node.panic? ? ".or_panic" : ".or"

      recovery =
        if default = node.default
          default.transform(self)
        else
          Call.global("raise", Call.new(temp_var.clone, "message").at(node)).at(node)
        end

      value = If.new(check, recovery, temp_var.clone).at(node)

      Expressions.new([assign, value] of ASTNode).at(node)
    end

    def transform(node : Unless)
      If.new(node.cond, node.else, node.then).transform(self).at(node)
    end

    # Convert until to while:
    #
    # From:
    #
    #    until foo
    #      bar
    #    end
    #
    # To:
    #
    #    while !foo
    #      bar
    #    end
    def transform(node : Until)
      node = super
      not_exp = Not.new(node.cond).at(node.cond)
      While.new(not_exp, node.body).at(node)
    end

    # Checks if the right hand side is dead code
    def transform(node : Assign)
      super

      if @dead_code
        node.value
      else
        node
      end
    end

    # Convert `a += b` to `a = a + b`
    def transform(node : OpAssign)
      super

      target = node.target
      if target.is_a?(Call)
        if target.name == "[]"
          transform_op_assign_index(node, target)
        else
          transform_op_assign_call(node, target)
        end
      else
        transform_op_assign_simple(node, target)
      end
    end

    def transform_op_assign_call(node, target)
      obj = target.obj.not_nil!

      # Convert
      #
      #     a.exp += b
      #
      # To
      #
      #     tmp = a
      #     tmp.exp=(tmp.exp + b)
      case obj
      when Var, InstanceVar, ClassVar, .simple_literal?
        tmp = obj
      else
        tmp = program.new_temp_var

        # (1) = tmp = a
        assign = Assign.new(tmp, obj).at(node)
      end

      # (2) = tmp.exp
      call = Call.new(tmp.clone, target.name).at(node)
      call.name_location = node.name_location

      case node.op
      when "||"
        # Special: tmp.exp || tmp.exp=(b)
        #
        # (3) = tmp.exp=(b)
        right = Call.new(tmp.clone, "#{target.name}=", node.value).at(node)
        right.name_location = node.name_location

        # (4) = (2) || (3)
        call = Or.new(call, right).at(node)
      when "&&"
        # Special: tmp.exp && tmp.exp=(b)
        #
        # (3) = tmp.exp=(b)
        right = Call.new(tmp.clone, "#{target.name}=", node.value).at(node)
        right.name_location = node.name_location

        # (4) = (2) && (3)
        call = And.new(call, right).at(node)
      else
        # (3) = (2) + b
        call = Call.new(call, node.op, node.value).at(node)
        call.name_location = node.name_location

        # (4) = tmp.exp=((3))
        call = Call.new(tmp.clone, "#{target.name}=", call).at(node)
        call.name_location = node.name_location
      end

      # (1); (4)
      if assign
        Expressions.new([assign, call] of ASTNode).at(node)
      else
        call
      end
    end

    def transform_op_assign_index(node, target)
      obj = target.obj.not_nil!

      # Convert
      #
      #     a[exp1, exp2, ...] += b
      #
      # To
      #
      #     tmp = a
      #     tmp1 = exp1
      #     tmp2 = exp2
      #     ...
      #     tmp.[]=(tmp1, tmp2, ..., tmp[tmp1, tmp2, ...] + b)
      tmp_args = target.args.map { program.new_temp_var(node).as(ASTNode) }
      tmp = program.new_temp_var(node)

      # (1) = tmp1 = exp1; tmp2 = exp2; ...; tmp = a
      tmp_assigns = Array(ASTNode).new(tmp_args.size + 1)
      tmp_args.each_with_index do |var, i|
        # For simple literals we don't need a temp variable
        arg = target.args[i]
        if arg.simple_literal?
          tmp_args[i] = arg
        else
          tmp_assigns << Assign.new(var.clone, arg).at(node)
        end
      end

      case obj
      when Var, InstanceVar, ClassVar, .simple_literal?
        # Nothing
        tmp = obj
      else
        tmp_assigns << Assign.new(tmp, obj).at(node)
      end

      case node.op
      when "||"
        # Special: tmp[tmp1, tmp2, ...]? || (tmp[tmp1, tmp2, ...] = b)
        #
        # (2) = tmp[tmp1, tmp2, ...]?
        call = Call.new(tmp.clone, "[]?", tmp_args).at(node)
        call.name_location = node.name_location

        # (3) = tmp[tmp1, tmp2, ...] = b
        args = Array(ASTNode).new(tmp_args.size + 1)
        tmp_args.each { |arg| args << arg.clone }
        args << node.value
        right = Call.new(tmp.clone, "[]=", args).at(node)
        right.name_location = node.name_location

        # (3) = (2) || (4)
        call = Or.new(call, right).at(node)
      when "&&"
        # Special: tmp[tmp1, tmp2, ...]? && (tmp[tmp1, tmp2, ...] = b)
        #
        # (2) = tmp[tmp1, tmp2, ...]?
        call = Call.new(tmp.clone, "[]?", tmp_args).at(node)
        call.name_location = node.name_location

        # (3) = tmp[tmp1, tmp2, ...] = b
        args = Array(ASTNode).new(tmp_args.size + 1)
        tmp_args.each { |arg| args << arg.clone }
        args << node.value
        right = Call.new(tmp.clone, "[]=", args).at(node)
        right.name_location = node.name_location

        # (3) = (2) && (4)
        call = And.new(call, right).at(node)
      else
        # (2) = tmp[tmp1, tmp2, ...]
        call = Call.new(tmp.clone, "[]", tmp_args).at(node)
        call.name_location = node.name_location

        # (3) = (2) + b
        call = Call.new(call, node.op, node.value).at(node)
        call.name_location = node.name_location

        # (4) tmp.[]=(tmp1, tmp2, ..., (3))
        args = Array(ASTNode).new(tmp_args.size + 1)
        tmp_args.each { |arg| args << arg.clone }
        args << call
        call = Call.new(tmp.clone, "[]=", args).at(node)
        call.name_location = node.name_location
      end

      # (1); (4)
      if tmp_assigns.empty?
        call
      else
        exps = Array(ASTNode).new(tmp_assigns.size + 2)
        exps.concat(tmp_assigns)
        exps << call

        Expressions.new(exps).at(node)
      end
    end

    def transform_op_assign_simple(node, target)
      case node.op
      when "&&"
        # (1) a = b
        assign = Assign.new(target, node.value).at(node)

        # a && (1)
        And.new(target.clone, assign).at(node)
      when "||"
        # (1) a = b
        assign = Assign.new(target, node.value).at(node)

        # a || (1)
        Or.new(target.clone, assign).at(node)
      else
        # (1) = a + b
        call = Call.new(target, node.op, node.value).at(node)
        call.name_location = node.name_location

        # a = (1)
        Assign.new(target.clone, call).at(node)
      end
    end

    def transform(node : StringInterpolation)
      # If the interpolation has just one string literal inside it,
      # return that instead of an interpolation
      if node.expressions.size == 1
        first = node.expressions.first
        return first if first.is_a?(StringLiteral)
      end

      super
    end

    # Turn block argument unpacking to multi assigns at the beginning
    # of a block.
    #
    # So this:
    #
    #    foo do |(x, y), z|
    #      x + y + z
    #    end
    #
    # is transformed to:
    #
    #    foo do |__temp_1, z|
    #      x, y = __temp_1
    #      x + y + z
    #    end
    def transform(node : Block)
      node = super

      unpacks = node.unpacks
      return node unless unpacks

      # as `node` is mutated in-place, ensure it can only be mutated once
      # we consider a block to be mutated if any unpack already has a
      # corresponding block parameter with a name (as the fictitious packed
      # parameters have empty names)
      return node if unpacks.any? { |index, _| !node.args[index].name.empty? }

      extra_expressions = [] of ASTNode
      next_unpacks = [] of {String, Expressions}

      unpacks.each do |index, expressions|
        temp_name = program.new_temp_var_name
        node.args[index] = Var.new(temp_name).at(node.args[index])

        extra_expressions << block_unpack_multiassign(temp_name, expressions, next_unpacks)
      end

      if next_unpacks
        while next_unpack = next_unpacks.shift?
          var_name, expressions = next_unpack

          extra_expressions << block_unpack_multiassign(var_name, expressions, next_unpacks)
        end
      end

      body = node.body
      case body
      when Nop
        node.body = Expressions.new(extra_expressions).at(node.body)
      when Expressions
        body.expressions = extra_expressions + body.expressions
      else
        extra_expressions << node.body
        node.body = Expressions.new(extra_expressions).at(node.body)
      end

      node
    end

    private def block_unpack_multiassign(var_name, expressions, next_unpacks)
      targets = expressions.expressions.map do |exp|
        case exp
        when Var
          exp
        when Underscore
          exp
        when Splat
          exp
        when Expressions
          next_temp_name = program.new_temp_var_name

          next_unpacks << {next_temp_name, exp}

          Var.new(next_temp_name).at(exp)
        else
          raise "BUG: unexpected block var #{exp} (#{exp.class})"
        end
      end
      values = [Var.new(var_name).at(expressions)] of ASTNode
      MultiAssign.new(targets, values).at(expressions)
    end

    def transform(node : Union)
      if node.singleton?
        # If the union has just one type, return that instead of a union
        node.types.first
      else
        super
      end
    end
  end
end
