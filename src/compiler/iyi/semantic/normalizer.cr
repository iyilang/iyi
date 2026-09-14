require "../program"
require "../syntax/transformer"

module Iyi
  class Program
    def normalize(node, inside_exp = false, current_def = nil)
      normalizer = Normalizer.new(self)
      normalizer.current_def = current_def
      node.transform(normalizer)
    end
  end

  class Normalizer < Transformer
    getter program : Program

    # The current method where we are normalizing.
    # This is used to expand argless `super` and `previous_def`
    # to their version with arguments copied from the current method.
    property current_def : Def?

    @dead_code = false

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
      exps = apply_defers(exps)
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
    #
    # To:
    #
    #     a
    #     __iyi_defer_push(-> { x })
    #     begin
    #       b
    #     ensure
    #       __iyi_defer_pop_run
    #     end
    #
    # The cleanup is written once, as a proc the runtime holds. Every
    # ordinary exit — falling off the end, a `return`, `!` expanding to
    # a `return` (III.1.2) — reaches the `ensure`, which pops the proc
    # and runs it. A panic reaches none of them: `raise` never unwinds
    # (there is no unwinder to link, by design), so the panic path in
    # the prelude walks the same registry and runs what was never
    # popped. One list, two readers, and `defer`'s promise holds on
    # every exit including the one that is a bug.
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
    private def apply_defers(exps : Array(ASTNode)) : Array(ASTNode)
      index = exps.index { |exp| exp.is_a?(Defer) }
      return exps unless index

      deferred = exps[index].as(Defer)
      rest = apply_defers(exps[(index + 1)..])
      head = exps[0...index]

      if program.iyi_prelude?
        # The trailing `nil` pins the proc to `-> Nil`: a proc literal
        # does not coerce its return the way a block restriction does,
        # and a cleanup's value is nobody's.
        cleanup_body = Expressions.new([deferred.exp, NilLiteral.new.at(deferred)] of ASTNode).at(deferred)
        proc_literal = ProcLiteral.new(Def.new("->", [] of Arg, cleanup_body)).at(deferred)
        push = Call.global("__iyi_defer_push", proc_literal).at(deferred)
        pop = Call.new(nil, "__iyi_defer_pop_run", global: true).at(deferred)
        head << push
        head << ExceptionHandler.new(rest, ensure: pop).at(deferred).tap(&.iyi_defer=(true))
      else
        # Crystal's prelude has a real unwinder, so the classic shape —
        # the cleanup inline in the `ensure` — already runs on a panic.
        head << ExceptionHandler.new(rest, ensure: deferred.exp).at(deferred).tap(&.iyi_defer=(true))
      end
      head
    end

    # A `defer` that is not one of several expressions — the whole of a body,
    # say — has nothing after it to defer past, so all that is left of it is
    # the cleanup itself, still guarded so that it runs on an unwind.
    def transform(node : Defer)
      ExceptionHandler.new(Nop.new, ensure: node.exp.transform(self)).at(node).tap(&.iyi_defer=(true))
    end

    # iyi: the typed group — SPEC.md III.4.9.
    #
    # From:
    #
    #     group do |g|
    #       x = g.spawn { read(a) }
    #       y = g.spawn { read(b) }
    #     end
    #
    # To:
    #
    #     group do |g|
    #       x = g.spawn { read(a) }
    #       y = g.spawn { read(b) }
    #       g.join
    #       %v1 = x.value
    #       if %v1.is_a?(::Error)
    #         %v1
    #       else
    #         %v2 = y.value
    #         if %v2.is_a?(::Error)
    #           %v2
    #         else
    #           {%v1, %v2}
    #         end
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
    # — a `return` between two spawns still joins — and finds nothing live
    # after the appended one, which costs a comparison.
    #
    # What qualifies is what the section says: the block's parameter is used
    # as the receiver of direct `spawn` statements and *nowhere else*. A
    # spawn in a loop, an `if`, or a `g` that escapes falls back quietly to
    # the general form, whose group is its block's last expression and whose
    # handles answer through `task.value`; a `!` demanding the typed form of
    # a group that cannot have one is refused by `!`'s own degenerate-union
    # check, which names the type it found.
    private def expand_iyi_group(node : Call) : ASTNode?
      block = node.block
      return nil unless block
      group_param = block.args.first?
      return nil unless group_param

      body = block.body
      statements = body.is_a?(Expressions) ? body.expressions.dup : [body] of ASTNode

      handles = [] of ASTNode
      rewritten = [] of ASTNode

      statements.each do |statement|
        spawn_call = iyi_direct_spawn(statement, group_param.name)
        if spawn_call.is_a?(Call)
          if statement.is_a?(Assign) && !statement.target.is_a?(Underscore)
            handles << statement.target
            rewritten << statement
          else
            handle = Var.new(program.new_temp_var_name).at(statement)
            handles << handle
            rewritten << Assign.new(handle.clone, spawn_call).at(statement)
          end
        else
          # Any other use of the group parameter anywhere in the statement
          # disqualifies: the tuple's arity has to be a fact of the text.
          return nil if iyi_uses_var?(statement, group_param.name)
          rewritten << statement
        end
      end
      return nil if handles.empty?

      rewritten << Call.new(Var.new(group_param.name).at(node), "join").at(node)

      values = [] of ASTNode
      handles.each do |handle|
        value = Var.new(program.new_temp_var_name).at(node)
        values << value
        rewritten << Assign.new(value.clone, Call.new(handle.clone, "value").at(node)).at(node)
      end

      extraction = TupleLiteral.new(values.map(&.clone)).at(node).as(ASTNode)
      values.reverse_each do |value|
        is_error = IsA.new(value.clone, Path.global("Error").at(node)).at(node)
        extraction = If.new(is_error, value.clone, extraction).at(node)
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

      def visit(node : ASTNode)
        true
      end
    end

    def transform(node : Call)
      # iyi: the typed group (III.4.9). The parser marked the call; whether
      # the *typed* form applies is this file's question, and a `nil` answer
      # is the method call standing as written.
      if node.iyi_group?
        expanded = expand_iyi_group(node)
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
      exp = node.exp.transform(self)
      temp_var = program.new_temp_var

      assign = Assign.new(temp_var.clone, exp).at(node)
      check = IsA.new(temp_var.clone, Path.global(["Error"]).at(node)).at(node)
      check.error_construct = "!"
      returned = Return.new(temp_var.clone).at(node)
      returned.from_propagate = true
      propagate = If.new(check, returned).at(node)

      Expressions.new([assign, propagate, temp_var.clone] of ASTNode).at(node)
    end

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
