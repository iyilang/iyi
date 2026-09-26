require "set"
require "./ast"
require "./lexer"

module Iyi
  class Parser < Lexer
    enum ParseMode
      Normal
      Lib
      LibStructOrUnion
      Enum
    end

    record Unclosed, name : String, location : Location

    property visibility : Visibility?

    # iyi: whether the source being parsed writes `extend self` for itself
    # where it wants one, so the module header must not supply it. Set when
    # parsing a `.iyimod`'s declarations, which carry the fact. See the header
    # handling below.
    property? iyi_module_extends_written = false
    property def_nest : Int32
    property fun_nest : Int32
    property type_nest : Int32
    getter? wants_doc : Bool
    @block_arg_name : String?

    def self.parse(str, string_pool : StringPool? = nil, var_scopes = [Set(String).new]) : ASTNode
      new(str, string_pool, var_scopes).parse
    end

    def initialize(str, string_pool : StringPool? = nil, @var_scopes = [Set(String).new], warnings : WarningCollection? = nil)
      super(str, string_pool, warnings)
      @unclosed_stack = [] of Unclosed
      @calls_super = false
      @calls_initialize = false
      @calls_previous_def = false
      @uses_block_arg = false
      @is_macro_def = false
      @assigns_special_var = false
      @def_nest = 0
      @fun_nest = 0
      @type_nest = 0
      @is_constant_assignment = false

      # Keeps track of current call args starting locations,
      # so if we parse a type declaration exactly at those points we
      # know we don't need to declare those as local variables in those scopes.
      @call_args_start_locations = [] of Location
      @temp_arg_count = 0
      @in_macro_expression = false
      @stop_on_yield = 0
      @inside_c_struct = false
      # iyi: true while parsing the immediate body of a trait or an impl, which
      # is the only place `type Elem` declares an associated type rather than
      # calling a method named `type`.
      @inside_trait_or_impl = false
      # iyi: depth of `defer` bodies being parsed, which is where `!` is
      # refused (SPEC.md III.1.4, Appendix B #7).
      @inside_defer = 0
      @wants_doc = false
      @doc_enabled = false
      @no_type_declaration = 0
      @consuming_heredocs = false
      @inside_interpolation = false

      # This flags tells the parser where it has to consider a "do"
      # as belonging to the current parsed call. For example when writing
      #
      # ```
      # foo bar do
      # end
      # ```
      #
      # this flag will be set to false for `foo`, and when parsing
      # `foo`'s arguments it will be set to true. When `bar` is parsed
      # the `do` won't be considered as part of `bar`, and eventually
      # be considered as part of `foo`.
      #
      # If `foo` is written with parentheses, for example:
      #
      # ```
      # foo(bar do
      # end)
      # ```
      #
      # then this flag is set to `true` when parsing `foo`'s arguments.
      @stop_on_do = false
      @assigned_vars = [] of String
    end

    def wants_doc=(@wants_doc : Bool)
      @doc_enabled = wants_doc
    end

    # iyi: the tree of what the source says and nothing it implies - the
    # formatter's, which walks the tokens beside the nodes and has no token
    # for the scope an `import x::{a}` makes beside it.
    property iyi_source_only = false

    # iyi: read `using`, the keyword `import x::{a}` replaced, as the node
    # it was, rather than refusing it: `iyi fix` rewrites a file written
    # before the change (`Iyi::UsingRewrite`), and has to read it to.
    property iyi_reads_using = false

    # iyi: the package this file is a module of, when it is one: its modules
    # live under the package's name (`Mod::ModFile.package_name`), so two
    # packages' `util`s are `Pa::Util` and `Pb::Util` and not one type. A
    # module whose path already begins with the name - `iyi_web/dsl` in
    # `iyi-web` - is where it was.
    property iyi_package_name : String? = nil

    # Where the import being read ends; see `parse_import_path_segment`.
    @iyi_import_end : Location? = nil

    def parse
      next_token_skip_statement_end

      nodes = parse_expressions.tap { iyi_check_eof }
      apply_module_header(nodes)
    end

    # iyi: what is left once every top-level expression is read is a
    # keyword nothing opened. "expecting token 'EOF', not 'end'" named the
    # token the parser wanted, not the one the person had one too many of.
    private def iyi_check_eof : Nil
      return if @token.type.eof?
      if @token.type.ident?
        case @token.value
        when Keyword::END
          if lookalike = @iyi_def_lookalike
            raise "unexpected 'end': nothing is open for it to close - `#{lookalike[0]}` at line #{lookalike[1].try(&.line_number)} is a call here, not a keyword, and a function is `def name(args) : Type`", @token
          end
          raise "unexpected 'end': nothing is open for it to close", @token
        when Keyword::ELSE, Keyword::ELSIF
          raise "unexpected '#{@token}': no `if` is open for it", @token
        when Keyword::WHEN, Keyword::IN
          # iyi: `in` with no `case` open is usually not a `case` at all.
          # `for i in 0..3` is the loop every other language writes, and
          # the answer it drew named a construct nobody had typed.
          if (lookalike = @iyi_for_lookalike) && @token.value == Keyword::IN
            raise "unexpected 'in': `for` at line #{lookalike[1].try(&.line_number)} is a call here, " \
                  "not a keyword - a range iterates with `(0..3).each do |i| ... end` and a " \
                  "collection with `xs.each do |x| ... end`", @token
          end
          raise "unexpected '#{@token}': no `case` is open for it", @token
        else
          # Not a keyword with a construct to belong to.
        end
      end
      check :EOF
    end

    # iyi: `module app/greeter` scopes everything after it in the file.
    #
    # Desugared here rather than in semantic analysis, because a header
    # applies to the rest of the file while `current_type` is managed with
    # nested blocks — the two do not line up. Rewriting
    #
    #     module app/greeter
    #     <rest>
    #
    # into `ModuleDef(App::Greeter, <rest>)` means the whole semantic phase
    # needs no changes at all.
    #
    # NOTE: path segments are capitalised to form the namespace, because
    # Crystal type names must be constants. `app/greeter` is reachable as
    # `App::Greeter`. That mismatch between how a module is declared and how
    # it is named is a wart the spec still has to settle.
    private def apply_module_header(nodes : ASTNode) : ASTNode
      expressions =
        case nodes
        when Expressions then nodes.expressions
        else                  [nodes]
        end

      # iyi: one file, one module (R-1, IV.6). A second header was accepted and
      # quietly wrong: the file emitted a single artifact under the first
      # module's name carrying *both* modules' exports, so the second module's
      # functions were exported by the first and the second had no artifact at
      # all. A module's path is its file's path, and a file has one path.
      expressions.each_with_index do |node, index|
        next if index == 0 || !node.is_a?(ModuleHeader)
        location = node.location
        raise "a file declares one module, and this one already declares " \
              "`#{expressions.first?.as?(ModuleHeader).try(&.path.join('/')) || "no module"}`. " \
              "A module is a compilation unit and its path is its file's path " \
              "(SPEC.md R-1, IV.6), so `#{node.path.join('/')}` belongs in " \
              "`#{node.path.join('/')}.iyi`",
          location.try(&.line_number) || 1, location.try(&.column_number) || 1
      end

      scoped = iyi_scope_imported_names(expressions)
      unless scoped.same?(expressions)
        expressions = scoped
        nodes = Expressions.from(expressions)
      end

      header = expressions.first?
      return nodes unless header.is_a?(ModuleHeader)

      rest = expressions[1..]

      # `import` stays at FILE level, outside the namespace. An imported file
      # carries its own `module` header, and processing it while scoped inside
      # this module would nest the two — `app/main` importing `app/greeter`
      # would create `App::Main::App::Greeter`.
      #
      # The scope an `import x::{a}` makes deliberately stays INSIDE, because
      # it affects name resolution within this module and should not leak to
      # whoever imports it: the import goes out, its `UsingDecl` goes to the
      # top of the module's body.
      # A `require` comes out with them, and for a plainer reason than
      # `import`'s: a require is file level in Crystal, and leaving it inside
      # the module this header desugars to loaded the required file *into* the
      # module. `require "json"` under `module web` made json's `class String`
      # mean `Web::String`, and the error was about a type nobody wrote.
      directives = [] of ASTNode
      scopes = [] of ASTNode
      while (first = rest.first?) && (first.is_a?(ImportDecl) || first.is_a?(Require) || first.is_a?(UsingDecl))
        node = rest.shift
        node.is_a?(UsingDecl) ? scopes << node : directives << node
      end

      segments = header.path
      if (package = @iyi_package_name) && segments.first? != package
        segments = [package] + segments
      end
      path = Path.new(segments.map(&.camelcase))
      path.at(header)

      # `extend self` so a module-level `pub def` is callable on the module
      # (`App::Greeter.polite`) rather than being an instance method of it.
      # In iyi a module is a compilation unit, not a mixin, so its functions
      # belong to the module itself.
      #
      # Except where the source writes its own, which a `.iyimod`'s declarations
      # do. Those may be of a module of the *other* language, where a module is
      # a mixin: `module Random` has `abstract def next_u` for its includers to
      # answer, and extending it anyway put it into its own metaclass, which
      # answers nothing — `abstract def Random#next_u() must be implemented by
      # Random:Module`, on a program whose only line was `import random`. Plain
      # Crystal refuses `extend self` beside an `abstract def` for the same
      # reason. A module of iyi's own carries the fact the same way and writes
      # the line; see `Artifact#module_extends_self`.
      body =
        if iyi_module_extends_written?
          scopes + rest
        else
          [Extend.new(Self.new).at(header)] of ASTNode + scopes + rest
        end

      module_def = ModuleDef.new(path, Expressions.from(body))
      module_def.iyi_unit = true
      module_def.at(header)
      module_def.end_location = header.end_location

      Expressions.from([header] of ASTNode + directives + [module_def] of ASTNode)
    end

    # iyi: `import x::{a, b}` and `import x::*` load the module and bring
    # names into scope; the second half is a `UsingDecl`, made here and put
    # beside the import, in the file's top level and in the bodies of the
    # types it declares - wherever an import can stand. The import is what
    # the source says; the scope is what it implies, so a tree for the
    # source alone (`iyi_source_only`) has none.
    private def iyi_scope_imported_names(expressions : Array(ASTNode)) : Array(ASTNode)
      return expressions if @iyi_source_only
      expressions.each do |node|
        node = node.exp if node.is_a?(VisibilityModifier)
        next unless node.is_a?(ClassDef) || node.is_a?(ModuleDef)
        body = node.body
        list = body.is_a?(Expressions) ? body.expressions : [body] of ASTNode
        scoped = iyi_scope_imported_names(list)
        node.body = Expressions.from(scoped) unless scoped.same?(list)
      end
      return expressions unless expressions.any? { |node| node.is_a?(ImportDecl) && node.scopes? }

      result = [] of ASTNode
      expressions.each do |node|
        result << node
        next unless node.is_a?(ImportDecl) && node.scopes?
        scope = UsingDecl.new(node.path.dup, node.glob? ? nil : node.names.dup, node.name_locations.dup)
        scope.at(node)
        scope.end_location = node.end_location
        result << scope
      end
      result
    end

    def parse(mode : ParseMode)
      case mode
      when .normal?
        parse
      when .lib?
        parse_lib_body
      when .lib_struct_or_union?
        parse_c_struct_or_union_body
      else
        parse_enum_body
      end
    end

    def parse_expressions
      preserve_stop_on_do { parse_expressions_internal }
    end

    def parse_expressions_internal
      if end_token?
        return Nop.new
      end

      exp = parse_multi_assign

      slash_is_regex!
      skip_statement_end

      if end_token?
        return exp
      end

      exps = [] of ASTNode
      exps.push exp

      loop do
        exps << parse_multi_assign
        skip_statement_end
        break if end_token?
      end

      Expressions.from(exps)
    end

    def parse_multi_assign
      location = @token.location

      if @token.type.op_star?
        lhs_splat = {index: 0, location: @token.location}
        next_token_skip_space
      end

      last = parse_expression
      skip_space

      last_is_target = multi_assign_target?(last) || multi_assign_middle?(last)

      case @token.type
      when .op_comma?
        unless last_is_target
          unexpected_token if lhs_splat
          raise "Multiple assignment is not allowed for constants" if last.is_a?(Path)
          unexpected_token
        end
      when .newline?, .op_semicolon?
        unexpected_token if lhs_splat && !multi_assign_middle?(last)
        return last unless lhs_splat
      else
        if end_token?
          unexpected_token if lhs_splat && !multi_assign_middle?(last)
          return last unless lhs_splat
        else
          unexpected_token
        end
      end

      exps = [] of ASTNode
      exps << last

      i = 0
      assign_index = -1

      while @token.type.op_comma?
        if assign_index == -1 && multi_assign_middle?(last)
          assign_index = i
        end

        i += 1

        next_token_skip_space_or_newline
        if @token.type.op_star?
          if assign_index == -1
            raise "splat assignment already specified" if lhs_splat
            lhs_splat = {index: i, location: @token.location}
          else
            unexpected_token
          end
          next_token_skip_space
        end

        last = parse_op_assign(allow_ops: false)
        if assign_index == -1 && !multi_assign_target?(last) && !multi_assign_middle?(last)
          unexpected_token
        end

        exps << last
        skip_space
      end

      if assign_index == -1 && multi_assign_middle?(last)
        assign_index = i
      end

      if assign_index == -1
        unexpected_token
      end

      targets = exps[0...assign_index].map { |exp| multi_assign_left_hand(exp) }

      assign = exps[assign_index]
      values = [] of ASTNode

      case assign
      when Assign
        targets << multi_assign_left_hand(assign.target)
        values << assign.value
      when Call
        assign.name = assign.name.byte_slice(0, assign.name.bytesize - 1)
        targets << assign
        values << assign.args.pop
      else
        raise "BUG: multi_assign index expression can only be Assign or Call"
      end

      if lhs_splat
        lhs_splat_location = lhs_splat[:location]
        lhs_splat_index = lhs_splat[:index]
        targets[lhs_splat_index] = Splat.new(targets[lhs_splat_index]).at(lhs_splat_location)
      end

      values.concat exps[assign_index + 1..-1]
      if values.size != 1
        if lhs_splat
          raise "Multiple assignment count mismatch", location if targets.size - 1 > values.size
        else
          raise "Multiple assignment count mismatch", location if targets.size != values.size
        end
      end

      multi = MultiAssign.new(targets, values).at(location)
      parse_expression_suffix multi, location
    end

    def multi_assign_target?(exp)
      case exp
      when Underscore, Var, InstanceVar, ClassVar, Global
        true
      when Call
        !exp.has_parentheses? && !exp.block && (!exp.has_any_args? || exp.name == "[]")
      else
        false
      end
    end

    def multi_assign_middle?(exp)
      case exp
      when Assign
        true
      when Call
        Lexer.setter?(exp.name) || exp.name == "[]="
      else
        false
      end
    end

    def multi_assign_left_hand(exp)
      if exp.is_a?(Path)
        raise "can't assign to constant in multiple assignment", exp.location.not_nil!
      end

      if exp.is_a?(Call)
        case obj = exp.obj
        when Nil
          if exp.args.empty?
            exp = Var.new(exp.name).at(exp)
          end
        when Global
          if obj.name == "$~" && exp.name == "[]"
            raise "global match data cannot be assigned to", obj.location.not_nil!
          end
        end
      end

      if exp.is_a?(Var)
        if exp.name == "self"
          raise "can't change the value of self", exp.location.not_nil!
        end
        push_var exp
      end
      exp
    end

    def parse_expression
      location = @token.location
      atomic = parse_op_assign
      parse_expression_suffix atomic, location
    end

    def parse_expression_suffix(atomic, location)
      while true
        case @token.type
        when .space?
          next_token
        when .ident?
          case @token.value
          when Keyword::IF
            atomic = parse_expression_suffix(location) { |exp| If.new(exp, atomic) }
          when Keyword::UNLESS
            atomic = parse_expression_suffix(location) { |exp| Unless.new(exp, atomic) }
          when Keyword::WHILE
            raise "trailing `while` is not supported", @token
          when Keyword::UNTIL
            raise "trailing `until` is not supported", @token
          when Keyword::RESCUE
            rescue_location = @token.location
            next_token_skip_space
            rescue_body = parse_op_assign
            rescues = [Rescue.new(rescue_body).at(rescue_location).at_end(rescue_body)] of Rescue
            if atomic.is_a?(Assign)
              atomic.value = ex = ExceptionHandler.new(atomic.value, rescues)
            else
              atomic = ex = ExceptionHandler.new(atomic, rescues)
            end
            ex.at(location).at_end(rescue_body)
            ex.suffix = true
          when Keyword::ENSURE
            ensure_location = @token.location
            next_token_skip_space
            ensure_body = parse_op_assign
            if atomic.is_a?(Assign)
              atomic.value = ex = ExceptionHandler.new(atomic.value, ensure: ensure_body)
            else
              atomic = ex = ExceptionHandler.new(atomic, ensure: ensure_body)
            end
            ex.at(location).at_end(ensure_body)
            ex.ensure_location = ensure_location
            ex.suffix = true
          else
            break
          end
        when .op_rparen?, .op_comma?, .op_semicolon?, .op_percent_rcurly?, .newline?, .eof?
          break
        else
          if end_token?
            break
          else
            unexpected_token
          end
        end
      end
      atomic
    end

    def parse_expression_suffix(location, &)
      slash_is_regex!
      next_token_skip_statement_end
      exp = parse_op_assign_no_control
      (yield exp).at(location).at_end(exp)
    end

    def parse_op_assign_no_control(allow_ops = true, allow_suffix = true)
      check_void_expression_keyword
      parse_op_assign(allow_ops, allow_suffix)
    end

    def parse_op_assign(allow_ops = true, allow_suffix = true)
      doc = @token.doc
      location = @token.location
      start_token = @token

      atomic = parse_question_colon

      while true
        name_location = @token.location

        case @token.type
        when .space?
          next_token
          next
        when .ident?
          unexpected_token unless allow_suffix
          break
        when .op_eq?
          slash_is_regex!
          break unless can_be_assigned?(atomic)

          if atomic.is_a?(Call) && atomic.name == "[]"
            next_token_skip_space_or_newline

            atomic.name = "[]="
            atomic.name_size = 0
            arg = parse_op_assign_no_control
            atomic.args << arg
            atomic.end_location = arg.end_location
          else
            if atomic.is_a?(Path) && (inside_def? || inside_fun? || @is_constant_assignment)
              raise "dynamic constant assignment. Constants can only be declared at the top level or inside other types."
            end

            @is_constant_assignment = true if atomic.is_a?(Path)

            if atomic.is_a?(Var) && atomic.name == "self"
              raise "can't change the value of self", location
            end

            if atomic.is_a?(Call) && (atomic.name.ends_with?('?') || atomic.name.ends_with?('!'))
              unexpected_token token: start_token
            end

            atomic = Var.new(atomic.name).at(atomic) if atomic.is_a?(Call)

            next_token_skip_space_or_newline

            # Constants need a new scope for their value
            case atomic
            when Path
              needs_new_scope = true
            when InstanceVar
              needs_new_scope = @def_nest == 0
            when ClassVar
              needs_new_scope = @def_nest == 0
            when Var
              @assigns_special_var = true if atomic.special_var?
            else
              needs_new_scope = false
            end

            atomic_value = with_isolated_var_scope(needs_new_scope) do
              if @token.keyword?(:uninitialized) && (
                   atomic.is_a?(Var) || atomic.is_a?(InstanceVar) ||
                   atomic.is_a?(ClassVar) || atomic.is_a?(Global)
                 )
                push_var atomic
                next_token_skip_space
                type = parse_bare_proc_type
                atomic = UninitializedVar.new(atomic, type).at(location).at_end(type)
                return atomic
              else
                if atomic.is_a?(Var) && !var?(atomic.name)
                  @assigned_vars.push atomic.name
                  value = parse_op_assign_no_control
                  @assigned_vars.pop
                  value
                else
                  parse_op_assign_no_control
                end
              end
            end

            @is_constant_assignment = false if atomic.is_a?(Path)

            push_var atomic

            atomic = Assign.new(atomic, atomic_value).at(location)
            atomic.doc = doc
            atomic
          end
        when .assignment_operator?
          unexpected_token unless allow_ops

          break unless can_be_assigned?(atomic)

          if atomic.is_a?(Path)
            raise "can't reassign to constant"
          end

          if atomic.is_a?(Var) && atomic.name == "self"
            raise "can't change the value of self", location
          end

          if atomic.is_a?(Call) && atomic.name != "[]" && !var_in_scope?(atomic.name)
            raise "'#{@token.type}' before definition of '#{atomic.name}'"
          end

          push_var atomic
          method = @token.type.to_s.byte_slice(0, @token.to_s.bytesize - 1)
          next_token_skip_space_or_newline
          value = parse_op_assign_no_control
          atomic = OpAssign.new(atomic, method, value).at(location)
          atomic.name_location = name_location
        else
          break
        end
        allow_ops = true
      end

      atomic
    end

    def parse_question_colon
      cond = parse_range

      while @token.type.op_question?
        location = @token.location

        check_void_value cond, location

        next_token_skip_space_or_newline

        @no_type_declaration += 1
        true_val = parse_question_colon

        skip_space_or_newline
        check :OP_COLON
        next_token_skip_space_or_newline

        false_val = parse_question_colon
        @no_type_declaration -= 1

        cond = If.new(cond, true_val, false_val, ternary: true).at(cond).at_end(false_val)
      end

      cond
    end

    def parse_range
      location = @token.location

      if @token.type.op_period_period? || @token.type.op_period_period_period?
        exp = Nop.new
      else
        exp = parse_or
      end

      while true
        case @token.type
        when .op_period_period?
          exp = new_range(exp, location, false)
        when .op_period_period_period?
          exp = new_range(exp, location, true)
        else
          return exp
        end
      end
    end

    def new_range(exp, location, exclusive)
      end_location = token_end_location
      check_void_value exp, location
      next_token_skip_space
      check_void_expression_keyword
      if end_token? ||
         @token.type.op_rparen? ||
         @token.type.op_comma? ||
         @token.type.op_semicolon? ||
         @token.type.op_eq_gt? ||
         @token.type.newline?
        right = Nop.new
      else
        right = parse_or
        end_location = right.end_location
      end
      RangeLiteral.new(exp, right, exclusive).at(location).at_end(end_location)
    end

    macro parse_operator(name, next_operator, node, *operators, right_associative = false)
      def parse_{{name.id}}
        location = @token.location

        left = parse_{{next_operator.id}}
        while true
          case @token.type
          when .space?
            next_token
          when {{operators.map { |op| ".#{op.id}".id }.splat}}
            check_void_value left, location

            method = @token.type.to_s
            name_location = @token.location

            slash_is_regex!
            next_token_skip_space_or_newline
            right = parse_{{(right_associative ? name : next_operator).id}}
            left = ({{node.id}}).at(location).at_end(right)
            left.name_location = name_location if left.is_a?(Call)
          else
            return left
          end
        end
      end
    end

    parse_operator :or, :and, "Or.new left, right", :op_bar_bar?
    parse_operator :and, :equality, "And.new left, right", :op_amp_amp?
    parse_operator :equality, :cmp, "Call.new left, method, right", :op_lt?, :op_lt_eq?, :op_gt?, :op_gt_eq?, :op_lt_eq_gt?
    parse_operator :cmp, :logical_or, "Call.new left, method, right", :op_eq_eq?, :op_bang_eq?, :op_eq_tilde?, :op_bang_tilde?, :op_eq_eq_eq?
    parse_operator :logical_or, :logical_and, "Call.new left, method, right", :op_bar?, :op_caret?
    parse_operator :logical_and, :shift, "Call.new left, method, right", :op_amp?
    parse_operator :shift, :add_or_sub, "Call.new left, method, right", :op_lt_lt?, :op_gt_gt?

    def parse_add_or_sub
      location = @token.location

      left = parse_mul_or_div
      while true
        case @token.type
        when .space?
          next_token
        when .op_plus?, .op_minus?, .op_amp_plus?, .op_amp_minus?
          check_void_value left, location

          method = @token.type.to_s
          name_location = @token.location
          next_token_skip_space_or_newline
          right = parse_mul_or_div
          left = Call.new(left, method, right).at(location).at_end(right)
          left.name_location = name_location
        when .number?
          case char = @token.value.to_s[0]
          when '+', '-'
            method = char.to_s
            name_location = @token.location

            # Go back to the +/-, advance one char and continue from there
            self.current_pos = @token.start + 1
            next_token

            right = parse_mul_or_div
            left = Call.new(left, method, right).at(location).at_end(right)
            left.name_location = name_location
          else
            return left
          end
        else
          return left
        end
      end
    end

    parse_operator :mul_or_div, :pow, "Call.new left, method, right", :op_star?, :op_slash?, :op_slash_slash?, :op_percent?, :op_amp_star?
    parse_operator :pow, :prefix, "Call.new left, method, right", :op_star_star?, :op_amp_star_star?, right_associative: true

    def parse_prefix
      name_location = @token.location
      case token_type = @token.type
      when .unary_operator?
        location = @token.location
        next_token_skip_space_or_newline
        check_void_expression_keyword
        arg = parse_prefix
        # iyi: a unary operator reaches across a newline for its operand, so
        # a stray `!` on the line before `module x` read the header as
        # `!(module x ...)` - out of the top level, past the one-module rule,
        # never typed, and codegen died on "`module x` has no type". A
        # declaration is not a value, and the sentence says so at the line.
        if iyi? && (what = iyi_declaration_word(arg))
          raise "unexpected '#{token_type}': a #{what} is a declaration, not a value to negate", location
        end
        if token_type.op_bang?
          Not.new(arg).at(location).at_end(arg)
        else
          call = Call.new(arg, token_type.to_s).at(location).at_end(arg)
          call.name_location = name_location
          call
        end
      else
        parse_atomic_with_method
      end
    end

    # iyi: what a declaration node is called in a sentence, or nil for a value.
    private def iyi_declaration_word(node : ASTNode) : String?
      case node
      when ModuleHeader then "module header"
      when ModuleDef    then "module"
      when ClassDef     then node.struct? ? "struct" : "class"
      when Def          then "def"
      when Macro        then "macro"
      when EnumDef      then "enum"
      when Alias        then "alias"
      when TraitDef     then "trait"
      when ImplDef      then "impl"
      when LibDef       then "lib"
      else                   nil
      end
    end

    # IDENT CONST + - * / // % | & ^ ~ ! ** << < <= == != =~ !~ >> > >= <=> === [] []= []? [ &+ &- &* &**
    AtomicWithMethodCheck = [
      :IDENT, :CONST, :OP_PLUS, :OP_MINUS, :OP_STAR, :OP_SLASH, :OP_SLASH_SLASH, :OP_PERCENT,
      :OP_BAR, :OP_AMP, :OP_CARET, :OP_TILDE, :OP_BANG, :OP_STAR_STAR, :OP_LT_LT, :OP_LT, :OP_LT_EQ,
      :OP_EQ_EQ, :OP_BANG_EQ, :OP_EQ_TILDE, :OP_BANG_TILDE, :OP_GT_GT, :OP_GT, :OP_GT_EQ,
      :OP_LT_EQ_GT, :OP_EQ_EQ_EQ, :OP_LSQUARE_RSQUARE, :OP_LSQUARE_RSQUARE_EQ, :OP_LSQUARE_RSQUARE_QUESTION,
      :OP_LSQUARE, :OP_AMP_PLUS, :OP_AMP_MINUS, :OP_AMP_STAR, :OP_AMP_STAR_STAR,
    ] of Token::Kind

    def parse_atomic_with_method
      location = @token.location
      atomic = parse_atomic
      parse_atomic_method_suffix atomic, location
    end

    def parse_atomic_method_suffix(atomic, location)
      # iyi: whether a `!` here is attached to what precedes it. A space before
      # it makes it the unary operator it has always been, so `f !x` keeps
      # meaning `f(!x)` and only `f(x)!` propagates.
      attached = true

      while true
        case @token.type
        when .op_bang?
          break unless attached && iyi?
          if @inside_defer > 0
            raise <<-MSG, @token
              `!` can't propagate out of a `defer`

              A `defer` runs while the scope is already being left, and may be
              carrying an error of its own. Handle the failure here — `.or_panic`
              or ignore it — see SPEC.md III.1.4.
              MSG
          end
          check_void_value atomic, location
          atomic = Propagate.new(atomic).at(location)
          next_token
          if @token.type.space?
            attached = false
            next_token
          end
          check_iyi_bang_call atomic
        when .space?
          attached = false
          next_token
        when .newline?
          # In these cases we don't want to chain a call
          case atomic
          when ClassDef, ModuleDef, EnumDef, FunDef, Def
            break
          else
            # continue chaining
          end

          # Allow '.' after newline for chaining calls
          unless lookahead(preserve_token_on_fail: true) { next_token_skip_space_or_newline; @token.type.op_period? }
            break
          end
        when .op_period?
          check_void_value atomic, location

          @wants_regex = false

          wants_def_or_macro_name do
            next_token_skip_space_or_newline
          end

          if @token.type.instance_var?
            atomic = parse_read_instance_var(atomic).at(location)
            next
          end

          iyi_check_name(AtomicWithMethodCheck, "a method name after '.'")

          if @token.value == Keyword::IS_A_QUESTION
            atomic = parse_is_a(atomic).at(location)
          elsif @token.value == Keyword::AS
            atomic = parse_as(atomic).at(location)
          elsif @token.value == Keyword::AS_QUESTION
            atomic = parse_as?(atomic).at(location)
          elsif @token.value == Keyword::RESPONDS_TO_QUESTION
            atomic = parse_responds_to(atomic).at(location)
          elsif !@in_macro_expression && @token.value == Keyword::NIL_QUESTION
            atomic = parse_nil?(atomic).at(location)
          elsif @token.type.op_bang?
            atomic = parse_negation_suffix(atomic).at(location)
            atomic = parse_atomic_method_suffix_special(atomic, location)
          elsif @token.type.op_lsquare?
            return parse_atomic_method_suffix(atomic, location)
          elsif iyi? && @token.type.ident? && @token.value.to_s.in?("or", "or_panic")
            atomic = parse_iyi_recover(atomic).at(location)
          else
            name = case @token.type
                   when .ident?, .const?
                     @token.value.to_s
                   else
                     @token.type.to_s
                   end
            name_location = @token.location
            end_location = token_end_location

            @wants_regex = false
            next_token

            space_consumed = false
            if @token.type.space?
              @wants_regex = true
              next_token
              space_consumed = true
            end

            case @token.type
            when .op_eq?
              atomic = Call.new(atomic, name)
              unexpected_token unless can_be_assigned?(atomic)

              # Rewrite 'f.x = arg' as f.x=(arg)
              next_token

              if @token.type.op_lparen?
                # If we have `f.x=(exp1).a.b.c`, consider it the same as `f.x = (exp1).a.b.c`
                # and not as `(f.x = exp1).a.b.c` because a difference in space
                # should not make a difference in semantic (#4399)
                # The only exception is doing a splat, in which case this can only
                # be expanded arguments for the call.
                if current_char == '*'
                  next_token_skip_space
                  arg = parse_single_arg
                  check :OP_RPAREN
                  end_location = token_end_location
                  next_token
                else
                  arg = parse_op_assign_no_control
                  end_location = arg.end_location
                end
              else
                skip_space_or_newline
                arg = parse_single_arg
                end_location = arg.end_location
              end

              atomic.at(location).at_end(end_location)
              atomic.name = "#{name}="
              atomic.args = [arg] of ASTNode
              atomic.name_location = name_location
              next
            when .assignment_operator?
              call = Call.new(atomic, name)
              unexpected_token unless can_be_assigned?(call)

              op_name_location = @token.location
              method = @token.type.to_s.byte_slice(0, @token.type.to_s.size - 1)
              next_token_skip_space_or_newline
              value = parse_op_assign
              call.at(location)
              call.name_location = name_location
              atomic = OpAssign.new(call, method, value).at(location)
              atomic.name_location = op_name_location
              next
            else
              call_args = preserve_stop_on_do { space_consumed ? parse_call_args_space_consumed : parse_call_args }
              if call_args
                args = call_args.args
                block = call_args.block
                block_arg = call_args.block_arg
                named_args = call_args.named_args
                has_parentheses = call_args.has_parentheses
              else
                args = block = block_arg = named_args = nil
                has_parentheses = false
              end
            end

            block = parse_block(block, stop_on_do: @stop_on_do)
            atomic = Call.new atomic, name, (args || [] of ASTNode), block, block_arg, named_args
            atomic.has_parentheses = has_parentheses
            atomic.name_location = name_location
            atomic.end_location = block.try(&.end_location) || call_args.try(&.end_location) || end_location
            atomic.at(location)
            atomic
          end
        when .op_lsquare_rsquare?
          check_void_value atomic, location

          name_location = @token.location
          end_location = token_end_location
          @wants_regex = false
          next_token_skip_space
          atomic = Call.new(atomic, "[]").at(location)
          atomic.name_location = name_location
          atomic.end_location = end_location
          atomic.name_size = 0 if atomic.is_a?(Call)
          atomic
        when .op_lsquare?
          check_void_value atomic, location

          name_location = @token.location
          next_token_skip_space_or_newline

          call_args = preserve_stop_on_do do
            parse_call_args_space_consumed(
              check_plus_and_minus: false,
              allow_curly: true,
              end_token: :OP_RSQUARE,
              allow_beginless_range: true,
              control: true,
            )
          end

          skip_space_or_newline
          check :OP_RSQUARE
          end_location = token_end_location
          @wants_regex = false
          next_token

          if call_args
            args = call_args.args
            block = call_args.block
            block_arg = call_args.block_arg
            named_args = call_args.named_args
          end

          if @token.type.op_question?
            method_name = "[]?"
            end_location = token_end_location
            next_token_skip_space
          else
            method_name = "[]"
            skip_space
          end

          atomic = Call.new(atomic, method_name, (args || [] of ASTNode), block, block_arg, named_args).at(location)
          atomic.name_location = name_location
          atomic.end_location = end_location
          atomic.name_size = 0
          atomic.args_in_brackets = true
          atomic
        else
          break
        end
      end

      atomic
    end

    def parse_atomic_method_suffix_special(call, location)
      case @token.type
      when .op_period?, .op_lsquare?, .op_lsquare_rsquare?
        parse_atomic_method_suffix(call, location)
      else
        call
      end
    end

    def parse_single_arg
      if @token.type.op_star?
        location = @token.location
        next_token_skip_space
        arg = parse_op_assign_no_control
        Splat.new(arg).at(location).at_end(arg)
      else
        parse_op_assign_no_control
      end
    end

    def parse_is_a(atomic)
      next_token_skip_space

      if @token.type.op_lparen?
        next_token_skip_space_or_newline
        type = parse_bare_proc_type
        skip_space_or_newline
        check :OP_RPAREN
        end_location = token_end_location
        next_token_skip_space
      else
        type = parse_union_type
        end_location = type.end_location
      end

      IsA.new(atomic, type).at_end(end_location)
    end

    # iyi: `defer f.close` (SPEC.md III.1.4).
    #
    # Recognised by name, so `defer` is a reserved word in an iyi program and
    # only there — a Crystal file keeps it as an ordinary identifier.
    #
    # The body may not propagate. A `defer` runs while the scope is already
    # being left, possibly carrying an error of its own, so a second error
    # leaving from here is the error-during-error problem — the ugliest corner
    # of every language that has taken it on (Appendix B #7).
    def parse_defer
      location = @token.location
      next_token_skip_space

      @inside_defer += 1
      begin
        exp = parse_op_assign
      ensure
        @inside_defer -= 1
      end

      Defer.new(exp).at(location).at_end(exp)
    end

    # iyi: `.or(default)` and `.or_panic` (SPEC.md III.1.3).
    #
    # Recognised by name here, which is what "compiler-known" costs: `or` and
    # `or_panic` are reserved in an iyi program. Gated on `iyi?`, so a Crystal
    # file that calls a method of either name is untouched.
    def parse_iyi_recover(atomic)
      panic = @token.value.to_s == "or_panic"
      end_location = token_end_location
      next_token

      if panic
        # `.or_panic()` is allowed but pointless; there is nothing to pass.
        if @token.type.op_lparen?
          next_token_skip_space_or_newline
          check :OP_RPAREN
          end_location = token_end_location
          next_token
        end

        return Recover.new(atomic).at_end(end_location)
      end

      skip_space
      unless @token.type.op_lparen?
        unexpected_token "expected '(': `.or` takes the default to use when the value is an error"
      end

      next_token_skip_space_or_newline
      default = parse_op_assign
      skip_space_or_newline
      check :OP_RPAREN
      end_location = token_end_location
      next_token

      Recover.new(atomic, default).at_end(end_location)
    end

    def parse_as(atomic, klass = Cast)
      next_token_skip_space

      if @token.type.op_lparen?
        next_token_skip_space_or_newline
        type = parse_bare_proc_type
        skip_space_or_newline
        check :OP_RPAREN
        end_location = token_end_location
        next_token_skip_space
      else
        type = parse_union_type
        end_location = token_end_location
      end

      klass.new(atomic, type).at_end(end_location)
    end

    def parse_as?(atomic)
      parse_as atomic, klass: NilableCast
    end

    def parse_responds_to(atomic)
      next_token

      if @token.type.op_lparen?
        next_token_skip_space_or_newline
        name = parse_responds_to_name
        next_token_skip_space_or_newline
        check :OP_RPAREN
        end_location = token_end_location
        next_token_skip_space
      elsif @token.type.space?
        next_token
        name = parse_responds_to_name
        end_location = token_end_location
        next_token_skip_space
      else
        unexpected_token "expected space or '('"
      end

      RespondsTo.new(atomic, name).at_end(end_location)
    end

    def parse_responds_to_name
      unless @token.type.symbol?
        unexpected_token "expected symbol"
      end

      @token.value.to_s
    end

    def parse_nil?(atomic)
      end_location = token_end_location
      next_token

      if @token.type.op_lparen?
        next_token_skip_space_or_newline
        check :OP_RPAREN
        end_location = token_end_location
        next_token_skip_space
      end

      IsA.new(atomic, Path.global("Nil"), nil_check: true).at_end(end_location)
    end

    def parse_negation_suffix(atomic)
      end_location = token_end_location
      next_token

      if @token.type.op_lparen?
        next_token_skip_space_or_newline
        check :OP_RPAREN
        end_location = token_end_location
        next_token_skip_space
      end

      Not.new(atomic).at_end(end_location)
    end

    def parse_read_instance_var(atomic)
      ivar_name = @token.value.to_s
      end_location = token_end_location
      next_token_skip_space

      call = ReadInstanceVar.new(atomic, ivar_name)
      call.end_location = end_location

      call
    end

    def parse_atomic
      location = @token.location
      atomic = parse_atomic_without_location
      atomic.location ||= location
      atomic
    end

    def parse_atomic_without_location
      case @token.type
      when .op_lparen?
        parse_parenthesized_expression
      when .op_lsquare_rsquare?
        parse_empty_array_literal
      when .op_lsquare?
        parse_array_literal
      when .op_lcurly?
        parse_hash_or_tuple_literal
      when .op_lcurly_lcurly?
        parse_percent_macro_expression
      when .op_lcurly_percent?
        parse_percent_macro_control
      when .op_colon_colon?
        parse_generic_or_global_call
      when .op_minus_gt?
        parse_fun_literal
      when .op_at_lsquare?
        parse_annotation
      when .number?
        @wants_regex = false
        node_and_next_token NumberLiteral.new(@token.value.to_s, @token.number_kind)
      when .char?
        node_and_next_token CharLiteral.new(@token.value.as(Char))
      when .string?, .delimiter_start?
        parse_delimiter
      when .string_array_start?
        parse_string_array
      when .symbol_array_start?
        parse_symbol_array
      when .symbol?
        node_and_next_token SymbolLiteral.new(@token.value.to_s)
      when .global?
        raise "$global_variables are not supported, use @@class_variables instead"
      when .op_dollar_tilde?, .op_dollar_question?
        location = @token.location
        var = Var.new(@token.to_s).at(location)

        if peek_ahead { next_token_skip_space; @token.type.op_eq? }
          push_var var
          node_and_next_token var
        else
          node_and_next_token Global.new(var.name).at(location)
        end
      when .global_match_data_index?
        if peek_ahead { next_token_skip_space; @token.type.op_eq? }
          raise "global match data cannot be assigned to"
        end

        value = @token.value.to_s
        if value_prefix = value.rchop? '?'
          method = "[]?"
          value = value_prefix
        else
          method = "[]"
        end
        location = @token.location
        index = value.to_i?
        raise "Index $#{value} doesn't fit in an Int32" unless index
        node_and_next_token Call.new(Global.new("$~").at(location), method, NumberLiteral.new(index))
      when .magic_line?
        node_and_next_token MagicConstant.expand_line_node(@token.location)
      when .magic_end_line?
        raise "__END_LINE__ can only be used in default parameter value", @token
      when .magic_file?
        node_and_next_token MagicConstant.expand_file_node(@token.location)
      when .magic_dir?
        node_and_next_token MagicConstant.expand_dir_node(@token.location)
      when .ident?
        # NOTE: Update `Parser#invalid_internal_name?` keyword list
        # when adding or removing keyword to handle here.
        if keyword = @token.value.as?(Keyword)
          case keyword
          when .begin?
            check_type_declaration { parse_begin }
          when Keyword::NIL
            check_type_declaration do
              @wants_regex = false
              slash_is_not_regex!
              node_and_next_token NilLiteral.new
            end
          when .true?
            check_type_declaration do
              @wants_regex = false
              slash_is_not_regex!
              node_and_next_token BoolLiteral.new(true)
            end
          when .false?
            check_type_declaration do
              @wants_regex = false
              slash_is_not_regex!
              node_and_next_token BoolLiteral.new(false)
            end
          when .yield?
            check_type_declaration { parse_yield }
          when .with?
            check_type_declaration { parse_yield_with_scope }
          when .abstract?
            check_type_declaration do
              check_not_inside_def("can't use abstract") do
                doc = @token.doc

                next_token_skip_space_or_newline
                case @token.value
                when Keyword::DEF
                  parse_def is_abstract: true, doc: doc
                when Keyword::CLASS
                  parse_class_def is_abstract: true, doc: doc
                when Keyword::STRUCT
                  parse_class_def is_abstract: true, is_struct: true, doc: doc
                else
                  unexpected_token
                end
              end
            end
          when .def?
            check_type_declaration do
              check_iyi_bodiless_trait_def
              check_not_inside_def("can't define def") do
                parse_def
              end
            end
          when .macro?
            check_type_declaration do
              check_not_inside_def("can't define macro") do
                parse_macro
              end
            end
          when .require?
            check_type_declaration do
              check_not_inside_def("can't require") do
                parse_require
              end
            end
          when .case?
            check_type_declaration { parse_case }
          when .select?
            check_type_declaration { parse_select }
          when .if?
            check_type_declaration { parse_if }
          when .unless?
            check_type_declaration { parse_unless }
          when .include?
            check_type_declaration do
              check_not_inside_def("can't include") do
                parse_include
              end
            end
          when .extend?
            check_type_declaration do
              check_not_inside_def("can't extend") do
                parse_extend
              end
            end
          when .class?
            check_type_declaration do
              check_not_inside_def("can't define class") do
                parse_class_def
              end
            end
          when .struct?
            check_type_declaration do
              check_not_inside_def("can't define struct") do
                parse_class_def is_struct: true
              end
            end
          when .module?
            check_type_declaration do
              check_not_inside_def("can't define module") do
                # `parse_module_def` returns a ModuleHeader instead when the
                # name is a lowercase path (iyi) rather than a CONST (Crystal).
                parse_module_def
              end
            end
          when .trait?
            check_type_declaration do
              check_not_inside_def("can't define trait") do
                parse_trait_def
              end
            end
          when .impl?
            check_type_declaration do
              check_not_inside_def("can't define impl") do
                parse_impl_def
              end
            end
          when .import?
            check_type_declaration do
              check_not_inside_def("can't import") { parse_import }
            end
          when .using?
            check_type_declaration do
              check_not_inside_def("can't import") { parse_using }
            end
          when .pub?
            check_type_declaration do
              check_not_inside_def("can't export") { parse_pub }
            end
          when .type?
            # Outside a trait or an impl this stays what it has always been: a
            # call to a method named `type`. Crystal's own `type X = Y` has its
            # own parse loop inside `lib`, and never reaches here.
            if @inside_trait_or_impl
              check_type_declaration do
                check_not_inside_def("can't declare an associated type") do
                  parse_assoc_type
                end
              end
            else
              set_visibility parse_var_or_call
            end
          when .enum?
            check_type_declaration do
              check_not_inside_def("can't define enum") do
                parse_enum_def
              end
            end
          when .while?
            check_type_declaration { parse_while }
          when .until?
            check_type_declaration { parse_until }
          when .return?
            check_type_declaration { parse_return }
          when .next?
            check_type_declaration { parse_next }
          when .break?
            check_type_declaration { parse_break }
          when .lib?
            check_type_declaration do
              check_not_inside_def("can't define lib") do
                parse_lib
              end
            end
          when .fun?
            check_type_declaration do
              check_not_inside_def("can't define fun") do
                parse_fun_def top_level: true, require_body: true
              end
            end
          when .alias?
            check_type_declaration do
              check_not_inside_def("can't define alias") do
                parse_alias
              end
            end
          when .pointerof?
            check_type_declaration { parse_pointerof }
          when .sizeof?
            check_type_declaration { parse_sizeof }
          when .instance_sizeof?
            check_type_declaration { parse_instance_sizeof }
          when .alignof?
            check_type_declaration { parse_alignof }
          when .instance_alignof?
            check_type_declaration { parse_instance_alignof }
          when .offsetof?
            check_type_declaration { parse_offsetof }
          when .typeof?
            check_type_declaration { parse_typeof }
          when .private?
            check_type_declaration { parse_visibility_modifier Visibility::Private }
          when .protected?
            check_type_declaration { parse_visibility_modifier Visibility::Protected }
          when .asm?
            check_type_declaration { parse_asm }
          when .annotation?
            check_type_declaration do
              check_not_inside_def("can't define annotation") do
                parse_annotation_def
              end
            end
          else
            set_visibility parse_var_or_call
          end
        elsif iyi? && @token.value == "defer"
          parse_defer
        else
          set_visibility parse_var_or_call
        end
      when .const?
        parse_const
      when .instance_var?
        if @in_macro_expression && @token.value == "@type"
          @is_macro_def = true
        end
        new_node_check_type_declaration InstanceVar
      when .class_var?
        new_node_check_type_declaration ClassVar
      when .underscore?
        node_and_next_token Underscore.new
      else
        unexpected_token_in_atomic
      end
    end

    def check_type_declaration(&)
      if next_comes_colon_space?
        name = @token.value.to_s
        var = Var.new(name).at(@token.location).at_end(token_end_location)
        next_token
        unless @token.type.space?
          warnings.add_warning_at(@token.location, "space required before colon in type declaration (run `crystal tool format` to fix this)")
        end
        skip_space
        check :OP_COLON
        type_declaration = parse_type_declaration(var)
        set_visibility type_declaration
      else
        yield
      end
    end

    def parse_type_declaration(var, is_const = false)
      next_token_skip_space_or_newline
      var_type = parse_bare_proc_type
      skip_space
      if @token.type.op_eq?
        next_token_skip_space_or_newline
        value = parse_op_assign_no_control
      elsif is_const
        raise "expected '=' for constant type declaration"
      end
      TypeDeclaration.new(var, var_type, value).at(var).at_end(value || var_type)
    end

    def next_comes_colon_space?
      return false unless @no_type_declaration == 0

      pos = current_pos
      while current_char.ascii_whitespace?
        next_char_no_column_increment
      end
      comes_colon_space = current_char == ':'
      if comes_colon_space
        next_char_no_column_increment
        comes_colon_space = current_char.ascii_whitespace?
      end
      self.current_pos = pos
      comes_colon_space
    end

    def new_node_check_type_declaration(klass)
      name = @token.value.to_s
      var = klass.new(name).at(@token.location)
      var.end_location = token_end_location
      @wants_regex = false
      next_token
      space_after_name = @token.type.space?
      skip_space

      if @no_type_declaration == 0 && @token.type.op_colon?
        unless space_after_name
          warnings.add_warning_at(@token.location, "space required before colon in type declaration (run `crystal tool format` to fix this)")
        end
        parse_type_declaration(var)
      else
        var
      end
    end

    def parse_const(global = false, location = @token.location)
      type = parse_generic global, location, expression: true
      space_after_name = @token.type.space?
      skip_space

      if @no_type_declaration == 0 && @token.type.op_colon? && type.is_a?(Path)
        unless space_after_name
          warnings.add_warning_at(@token.location, "space required before colon in type declaration (run `crystal tool format` to fix this)")
        end
        parse_type_declaration(type, is_const: true)
      else
        parse_custom_literal type
      end
    end

    def parse_custom_literal(type)
      if @token.type.op_lcurly?
        tuple_or_hash = parse_hash_or_tuple_literal allow_of: false

        skip_space

        if @token.keyword?(:of)
          unexpected_token
        end

        case tuple_or_hash
        when TupleLiteral
          ary = ArrayLiteral.new(tuple_or_hash.elements, name: type).at(tuple_or_hash)
          return ary
        when HashLiteral
          tuple_or_hash.name = type
          return tuple_or_hash
        else
          raise "BUG: tuple_or_hash should be tuple or hash, not #{tuple_or_hash}"
        end
      end

      type
    end

    def check_not_inside_def(message, &)
      if @def_nest == 0 && @fun_nest == 0
        yield
      else
        suffix = @def_nest > 0 ? " inside def" : " inside fun"
        raise message + suffix, @token.line_number, @token.column_number
      end
    end

    def inside_def?
      @def_nest > 0
    end

    def inside_fun?
      @fun_nest > 0
    end

    def parse_annotation
      doc = @token.doc
      location = @token.location

      next_token_skip_space
      name = parse_path
      skip_space

      args = [] of ASTNode
      named_args = nil

      if @token.type.op_lparen?
        open("annotation") do
          next_token_skip_space_or_newline
          while !@token.type.op_rparen?
            if @token.type.ident? && current_char == ':'
              named_args = parse_named_args(@token.location, first_name: nil, allow_newline: true)
              check :OP_RPAREN
              break
            else
              args << parse_call_arg
            end

            skip_space_or_newline
            if @token.type.op_comma?
              next_token_skip_space_or_newline
            end
          end
          next_token_skip_space
        end
      end
      check :OP_RSQUARE
      end_location = token_end_location
      @wants_regex = false
      next_token_skip_space

      ann = Annotation.new(name, args, named_args).at(location).at_end(end_location)
      ann.doc = doc
      ann
    end

    def parse_begin
      begin_location = @token.location
      slash_is_regex!
      next_token_skip_statement_end
      iyi_opened "begin", begin_location
      exps = parse_expressions
      node, end_location, found_handler = parse_exception_handler exps, begin_location: begin_location
      iyi_closed
      if !found_handler && (!node.is_a?(Expressions) || !node.keyword.none?)
        node = Expressions.new([node])
      end
      node.at(begin_location).at_end(end_location)
      node.keyword = :begin if node.is_a?(Expressions)
      node
    end

    def parse_exception_handler(exp, implicit = false, begin_location = nil)
      rescues = nil
      a_else = nil
      a_ensure = nil
      begin_location ||= exp.location

      if @token.keyword?(:rescue)
        rescues = [] of Rescue
        found_catch_all = false
        while true
          begin_location ||= @token.location
          location = @token.location
          a_rescue = parse_rescue
          if a_rescue.types
            if found_catch_all
              raise "specific rescue must come before catch-all rescue", location
            end
          else
            if found_catch_all
              raise "catch-all rescue can only be specified once", location
            end
            found_catch_all = true
          end
          rescues << a_rescue
          break unless @token.keyword?(:rescue)
        end
      end

      if @token.keyword?(:else)
        unless rescues
          raise "'else' is useless without 'rescue'", @token, 4
        end

        else_location = @token.location
        begin_location ||= @token.location
        next_token_skip_statement_end
        a_else = parse_expressions
        skip_statement_end
      end

      if @token.keyword?(:ensure)
        ensure_location = @token.location
        begin_location ||= @token.location
        next_token_skip_statement_end
        a_ensure = parse_expressions
        skip_statement_end
      end

      end_location = token_end_location

      check_ident :end
      slash_is_not_regex!
      @wants_regex = false
      next_token_skip_space

      if rescues || a_ensure
        ex = ExceptionHandler.new(exp, rescues, a_else, a_ensure)
        ex.at(begin_location).at_end(end_location)
        ex.implicit = true if implicit
        ex.else_location = else_location
        ex.ensure_location = ensure_location
        {ex, end_location, true}
      else
        {exp, end_location, false}
      end
    end

    SemicolonOrNewLine = [:OP_SEMICOLON, :NEWLINE] of Token::Kind
    ConstOrDoubleColon = [:CONST, :OP_COLON_COLON] of Token::Kind

    def parse_rescue
      location = @token.location
      end_location = token_end_location
      next_token_skip_space

      case @token.type
      when .ident?
        name = @token.value.to_s
        push_var_name name
        end_location = token_end_location
        next_token_skip_space

        if @token.type.op_colon?
          next_token_skip_space_or_newline
          check ConstOrDoubleColon
          types = parse_rescue_types
          end_location = types.last.end_location
        end
      when .const?, .op_colon_colon?
        types = parse_rescue_types
        end_location = types.last.end_location
      else
        # keep going
      end

      check SemicolonOrNewLine

      next_token_skip_space_or_newline

      if @token.keyword?(:end)
        body = nil
      else
        body = parse_expressions
        end_location = body.end_location
        skip_statement_end
      end

      Rescue.new(body, types, name).at(location).at_end(end_location)
    end

    def parse_rescue_types
      types = [] of ASTNode
      while true
        types << parse_generic
        skip_space
        if @token.type.op_bar?
          next_token_skip_space
        else
          skip_space
          break
        end
      end
      types
    end

    def parse_while
      parse_while_or_until While
    end

    def parse_until
      parse_while_or_until Until
    end

    def parse_while_or_until(klass)
      location = @token.location
      slash_is_regex!
      next_token_skip_space_or_newline

      cond = parse_op_assign_no_control allow_suffix: false

      slash_is_regex!
      skip_statement_end

      iyi_opened(klass == While ? "while" : "until", location)
      body = parse_expressions
      skip_statement_end

      end_location = token_end_location
      check_ident :end
      iyi_closed
      next_token_skip_space

      klass.new(cond, body).at_end(end_location)
    end

    def call_block_arg_follows?
      @token.type.op_amp? && !current_char.ascii_whitespace?
    end

    def parse_call_block_arg(args, check_paren, named_args = nil)
      location = @token.location

      next_token_skip_space

      if @token.type.op_period?
        block_arg_name = temp_arg_name
        obj = Var.new(block_arg_name)

        @wants_regex = false
        if current_char == '%'
          next_char
          @token.type = :OP_PERCENT
          @token.column_number += 1
          skip_space
        else
          next_token_skip_space
        end

        call = parse_call_block_arg_after_dot(obj)

        block = Block.new([Var.new(block_arg_name)], call).at(location)
        end_location = call.end_location
      else
        block_arg = parse_op_assign
        end_location = block_arg.end_location
      end

      if check_paren
        skip_space_or_newline
        check :OP_RPAREN
        end_location = token_end_location
        @wants_regex = false
        next_token_skip_space
      else
        skip_space
      end

      CallArgs.new args, block, block_arg, named_args, false, end_location, has_parentheses: check_paren
    end

    def parse_call_block_arg_after_dot(obj)
      location = @token.location

      if @token.type.instance_var?
        call = parse_read_instance_var(obj).at(location)
        call = parse_atomic_method_suffix_special(call, location)
        return call
      end

      iyi_check_name(AtomicWithMethodCheck, "a method name after '.'")

      if @token.value == Keyword::IS_A_QUESTION
        call = parse_is_a(obj).at(location)
        call = parse_atomic_method_suffix_special(call, location)
      elsif @token.value == Keyword::AS
        call = parse_as(obj).at(location)
        call = parse_atomic_method_suffix_special(call, location)
      elsif @token.value == Keyword::AS_QUESTION
        call = parse_as?(obj).at(location)
        call = parse_atomic_method_suffix_special(call, location)
      elsif @token.value == Keyword::RESPONDS_TO_QUESTION
        call = parse_responds_to(obj).at(location)
        call = parse_atomic_method_suffix_special(call, location)
      elsif !@in_macro_expression && @token.value == Keyword::NIL_QUESTION
        call = parse_nil?(obj).at(location)
        call = parse_atomic_method_suffix_special(call, location)
      elsif @token.type.op_bang?
        call = parse_negation_suffix(obj).at(location)
        call = parse_atomic_method_suffix_special(call, location)
      elsif @token.type.op_lsquare?
        call = parse_atomic_method_suffix obj, location

        if @token.type.op_eq? && call.is_a?(Call) && can_be_assigned?(call)
          next_token_skip_space
          exp = parse_op_assign
          call.name = "#{call.name}="
          call.args << exp
          call.at_end(exp)
        end
      else
        # At this point we want to attach the "do" to the next call
        old_stop_on_do = @stop_on_do
        @stop_on_do = false
        call = parse_var_or_call(force_call: true).at(location)

        if call.is_a?(Call)
          call.obj = obj
        else
          raise "BUG: #{call} should be a call"
        end

        call = call.as(Call)

        if @token.type.op_eq?
          unexpected_token unless can_be_assigned?(call)

          next_token

          if @token.type.op_lparen?
            skip_space
            next_token_skip_space
            exp = parse_op_assign
            check :OP_RPAREN
            next_token_skip_space
            call.name = "#{call.name}="
            call.args = [exp] of ASTNode
            call = parse_atomic_method_suffix call, location
          else
            skip_space
            exp = parse_op_assign
            call.name = "#{call.name}="
            call.args = [exp] of ASTNode
          end

          call.at_end(exp)
        else
          call = parse_atomic_method_suffix call, location

          if @token.type.op_eq? && call.is_a?(Call) && can_be_assigned?(call)
            next_token_skip_space
            exp = parse_op_assign
            call.name = "#{call.name}="
            call.args << exp
            call.at_end(exp)
          end
        end

        @stop_on_do = old_stop_on_do
      end

      call
    end

    StatementEnd = [:OP_SEMICOLON, :NEWLINE, :SPACE] of Token::Kind

    def parse_class_def(is_abstract = false, is_struct = false, doc = nil)
      @type_nest += 1

      doc ||= @token.doc

      next_token_skip_space_or_newline
      name_location = @token.location

      name = parse_path
      found_space = @token.type.space?
      skip_space

      type_vars, splat_index = parse_type_vars

      if type_vars
        found_space = @token.type.space?
        skip_space
      end

      superclass = nil

      if @token.type.op_lt?
        next_token_skip_space_or_newline
        if @token.keyword?(:self)
          superclass = Self.new.at(@token.location)
          next_token
        else
          superclass = parse_generic
        end
      end

      check(StatementEnd) if superclass || !found_space
      skip_statement_end

      iyi_opened(is_struct ? "struct" : "class", name_location)
      body = push_visibility { parse_expressions }

      end_location = token_end_location
      check_ident :end
      iyi_closed
      next_token_skip_space

      @type_nest -= 1

      class_def = ClassDef.new name, body, superclass, type_vars, is_abstract, is_struct, splat_index
      class_def.doc = doc
      class_def.name_location = name_location
      class_def.end_location = end_location
      set_visibility class_def
      class_def
    end

    def parse_type_vars
      type_vars = nil
      splat_index = nil
      if @token.type.op_lparen?
        type_vars = [] of String

        next_token_skip_space_or_newline

        index = 0
        while !@token.type.op_rparen?
          if @token.type.op_star?
            raise "splat type parameter already specified", @token if splat_index
            splat_index = index
            next_token
          end
          type_var_name = check_const

          if type_vars.includes? type_var_name
            raise "duplicated type parameter name: #{type_var_name}", @token
          end

          type_vars.push type_var_name

          next_token_skip_space
          if @token.type.op_comma?
            next_token_skip_space_or_newline
          else
            skip_space_or_newline
            check :OP_RPAREN
          end

          index += 1
        end

        if type_vars.empty?
          raise "must specify at least one type var"
        end

        next_token
      end
      {type_vars, splat_index}
    end

    # iyi: a slash-separated lowercase path, e.g. `app/user`, `std/json`.
    # Distinguishable from Crystal's `module Foo` because that takes a CONST.
    def parse_module_path : Array(String)
      segments = [] of String
      check Token::Kind::IDENT
      segments << check_module_path_segment(@token.value.to_s)

      # After an identifier the lexer would treat `/` as the start of a regex
      # literal, so `app/user` lexes as `app` followed by DELIMITER_START.
      # Module paths are the one place `/` is a separator, so suppress regex
      # mode for the duration.
      #
      # `@wants_regex` alone was not enough, and the way it failed is worth
      # keeping. A token whose text *begins* with a keyword — `libs`, `defs`,
      # `endpoint`, `class1` — leaves the lexer through an early `return` that
      # skips the reset of `@slash_is_regex`, and that flag is the one the
      # slash is judged by. So `module endpoint/handler` lexed its `/` as the
      # start of a regex and did not parse, while `module app/user` did.
      # Ordinary names, and the failure was a syntax error pointing at the
      # slash.
      suppress_regex
      next_token

      while @token.type.op_slash?
        suppress_regex
        next_token
        check Token::Kind::IDENT
        segments << check_module_path_segment(@token.value.to_s)
        suppress_regex
        next_token
      end

      @wants_regex = true
      skip_space
      segments
    end

    # iyi: both flags, because the lexer reads one of them and the parser sets
    # the other, and a keyword-prefixed identifier skips the reset that would
    # have kept them in step.
    private def suppress_regex : Nil
      @wants_regex = false
      slash_is_not_regex!
    end

    # iyi: a module path segment is `[a-z][a-z0-9]*` with single `_` between
    # groups (SPEC.md IV.6 #6).
    #
    # A module is declared `app/greeter` and reached `App::Greeter`, and the
    # two notations are kept in step by making the mapping between them
    # reversible rather than by unifying them. `camelcase` upper-cases the
    # first character of each underscore-separated group and drops the
    # underscores, so a name is split back into a path at every upper-case
    # letter — but only if every group starts with a letter, which is what
    # this enforces.
    #
    # Plain `snake_case` is not enough, which is the reason this is checked
    # rather than assumed: `camelcase` drops an underscore that precedes a
    # digit, so `v_1` and `v1` both give `V1`. Doubled, leading and trailing
    # underscores collide the same way.
    private def check_module_path_segment(segment : String) : String
      start_of_group = true
      valid = segment.each_char do |char|
        if start_of_group
          break false unless char.ascii_lowercase?
          start_of_group = false
        elsif char == '_'
          start_of_group = true
        elsif !(char.ascii_lowercase? || char.ascii_number?)
          break false
        end
      end

      # `start_of_group` is still set for an empty segment or a trailing `_`.
      if valid == false || start_of_group
        raise <<-MSG, @token.line_number, @token.column_number
          module path segment '#{segment}' is not lower-case snake_case

          A module declared `app/greeter` is reached as `App::Greeter`, so the \
          path and the type name have to determine each other: every segment \
          is a lower-case letter followed by letters and digits, with single \
          `_` between groups. Otherwise two paths can name one module — `v_1` \
          and `v1` would both be `V1`. See SPEC.md IV.6 #6.
          MSG
      end

      segment
    end

    # iyi: `module app/user` — compilation-unit header (R-1).
    # Crystal's `module Foo ... end` still parses; the two are told apart by
    # whether the name is a CONST or a lowercase IDENT.
    def parse_module_header
      location = @token.location
      next_token_skip_space
      path = parse_module_path
      header = ModuleHeader.new(path)
      header.at(location)
      header.end_location = token_end_location
      header
    end

    # iyi: `import std/json`, and `import github.com/user/lib/http` (SPEC.md
    # III.7): a package path's host-shaped segments carry `.` and `-`, which
    # IV.6 #6's grammar refuses because those segments never become a type
    # name — the in-package path does that, and it is checked where the
    # package's own files load. The relaxed spelling is import-only; a
    # module header stays under the strict grammar.
    #
    # `::{a, b}` after the path brings those names into scope as well, and
    # `::*` every name the module exports: one keyword for a module and its
    # names, where there were two (SPEC.md R-2b). The names are taken as
    # written and matched as written, so the list may hold both method
    # names and type names - to the consumer they are just names.
    def parse_import
      location = @token.location
      next_token_skip_space
      path = parse_import_path
      names = nil
      name_locations = nil
      glob = false
      if @token.type.op_colon_colon?
        next_token
        if @token.type.op_star?
          glob = true
          @iyi_import_end = token_end_location
          next_token_skip_space
        elsif @token.type.op_lcurly?
          names, name_locations = parse_import_names
        else
          raise "after `::` an import lists the names it brings into scope, " \
                "`import #{path.join('/')}::{name}`, or takes every one, `import #{path.join('/')}::*`", @token
        end
      end
      node = ImportDecl.new(path, names, name_locations, glob)
      node.at(location)
      node.end_location = @iyi_import_end
      node
    end

    # Like `parse_module_path`, with dotted and hyphened segments admitted.
    # A `.` or `-` extends the current segment only when it is attached on
    # both sides — `github.com`, `crystal-lang` — so `a . b` stays the
    # method call it reads as. The strict segment check is applied to any
    # segment that stayed plain, so `import App/Thing` is refused exactly
    # as before.
    private def parse_import_path : Array(String)
      segments = [] of String
      segments << parse_import_path_segment

      while @token.type.op_slash?
        suppress_regex
        next_token
        segments << parse_import_path_segment
      end

      @wants_regex = true
      skip_space
      segments
    end

    private def parse_import_path_segment : String
      check Token::Kind::IDENT
      segment = String.build do |io|
        io << @token.value
        while (current_char == '.' || current_char == '-') &&
              peek_next_char.ascii_lowercase?
          io << current_char
          next_char
          next_token
          check Token::Kind::IDENT
          io << @token.value
        end
      end
      check_module_path_segment(segment) unless segment.includes?('.') || segment.includes?('-')
      suppress_regex
      # Where an import's text ends, taken before the lexer moves past the
      # line: `token_end_location` after it is the end of whatever comes
      # next - the spaces, a comment - and `iyi fix` rewrites by this span.
      @iyi_import_end = token_end_location
      next_token
      segment
    end

    # iyi: `using app/greeter` and `using app/greeter::{polite}` are what
    # `import app/greeter::*` and `import app/greeter::{polite}` were
    # spelled before one keyword did both. Refused with the line that
    # replaces it, read whole so the sentence can say it exactly - unless
    # `iyi fix` is reading the file to rewrite it (`iyi_reads_using`).
    def parse_using
      location = @token.location
      next_token_skip_space
      path = parse_import_path
      if @token.type.op_colon_colon?
        next_token
        names, name_locations = parse_import_names
      end

      unless @iyi_reads_using
        written = path.join('/')
        now = names ? "import #{written}::{#{names.join(", ")}}" : "import #{written}::*"
        message = "`using` is gone: one keyword loads a module and names what it brings into scope, " \
                  "so this line is `#{now}` (SPEC.md R-2b). `iyi fix .` rewrites every `using` in a project, " \
                  "folding an `import` of the same module into it"
        # The edit, where the directive is one line: its span, replaced by the
        # line that replaces it - what `check -f json` and a quick fix apply.
        last = @iyi_import_end
        one_line = last && last.line_number == location.line_number
        size = one_line && last ? last.column_number - location.column_number + 1 : nil
        refusal = SyntaxException.new(message, location.line_number, location.column_number, @filename, size)
        refusal.suggestion = now if size
        ::raise refusal
      end

      node = UsingDecl.new(path, names, name_locations)
      node.at(location)
      node.end_location = @iyi_import_end
      node
    end

    # `{a, b}`, from the `{`.
    private def parse_import_names : {Array(String), Array(Location)}
      check Token::Kind::OP_LCURLY

      names = [] of String
      name_locations = [] of Location
      next_token_skip_space_or_newline
      loop do
        unless @token.type.ident? || @token.type.const?
          raise "expected a name to bring into scope", @token.line_number, @token.column_number
        end
        names << @token.value.to_s
        name_locations << @token.location
        next_token_skip_space_or_newline
        break unless @token.type.op_comma?
        next_token_skip_space_or_newline
      end
      check Token::Kind::OP_RCURLY
      @iyi_import_end = token_end_location

      next_token_skip_space
      {names, name_locations}
    end

    # iyi: `pub` marks a declaration as exported (R-2). Exported declarations
    # appear in the module's `.iyimod` and must carry full type signatures.
    def parse_pub
      pub_location = @token.location
      # The doc comment rides the `pub` token; captured here or it is gone
      # by the time `parse_def` looks — the artifact's `Docs` (III.7) is
      # exactly the exported surface, so `pub` is the one reader that must
      # not drop it.
      doc = @token.doc
      next_token_skip_space

      # iyi: `pub LIMIT = 42`. A constant is a CONST token rather than an
      # identifier, and it is the one exported thing whose name is its
      # declaration — there is no keyword in front of it.
      if @token.type.const?
        assign = parse_expression
        unless assign.is_a?(Assign) && assign.target.is_a?(Path)
          raise "`pub` takes a constant assignment here", @token.line_number, @token.column_number
        end
        assign.exported = true
        return assign.at(pub_location)
      end

      unless @token.type.ident?
        raise "expected a declaration after `pub`", @token.line_number, @token.column_number
      end

      node =
        case @token.value
        when Keyword::TRAIT
          parse_trait_def(exported: true)
        when Keyword::IMPORT
          # iyi: `pub import x` — the facade form. The import is
          # re-exported: whoever imports this module reaches `x` too.
          decl = parse_import
          if decl.scopes?
            written = decl.path.join('/')
            raise "`pub import` re-exports #{written} whole, and names brought into scope are this " \
                  "module's own - they never pass to its importers (SPEC.md R-1, R-2b). Write " \
                  "`pub import #{written}` to hand the module on, and `import #{written}::" \
                  "#{decl.glob? ? "*" : "{#{decl.names.try(&.join(", "))}}"}` beside it for the names this module uses",
              pub_location.line_number, pub_location.column_number
          end
          decl.exported = true
          decl
        when Keyword::DEF
          a_def = parse_def
          a_def.exported = true
          a_def
        when Keyword::CLASS
          cls = parse_class_def
          cls.exported = true if cls.is_a?(ClassDef)
          cls
        when Keyword::STRUCT
          cls = parse_class_def is_struct: true
          cls.exported = true if cls.is_a?(ClassDef)
          cls
        when Keyword::MACRO
          a_macro = parse_macro
          a_macro.exported = true if a_macro.is_a?(Macro)
          a_macro
        when Keyword::ENUM
          # A type like any other here. It was left out of this list while
          # nothing declared one, and what wanted it was a boundary: a bound
          # Crystal namespace hands out enum values, and an artifact can only
          # declare what `pub` admits.
          enum_def = parse_enum_def
          enum_def.exported = true if enum_def.is_a?(EnumDef)
          enum_def
        when Keyword::ALIAS
          # A name for a type is a name another module writes: `alias Errors
          # = Hash(Symbol | String, Array(String))` is half of what the
          # `validator` shard's surface says, and it travels in the artifact
          # as what it resolved to (`TypeDecl#value`).
          node_alias = parse_alias
          node_alias.exported = true if node_alias.is_a?(Alias)
          node_alias
        when Keyword::ANNOTATION
          # An annotation is applied by *consumers*: a shard declaring
          # `annotation Checker` means a class in somebody else's module to
          # write `@[Check::Checker]`, which is exactly a surface.
          annotation_def = parse_annotation_def
          annotation_def.exported = true if annotation_def.is_a?(AnnotationDef)
          annotation_def
        when Keyword::ABSTRACT
          # `pub abstract class`. Being abstract and being reachable are
          # different questions — one says the type cannot be instantiated, the
          # other says who may name it — and a boundary needs both at once: a
          # bound `abstract class ExceptionPage` is a type a consumer subclasses
          # and therefore has to be able to write. Without this the declaration
          # came back as a plain `pub class`, and the requirement inside it was
          # refused with `can't define abstract def on non-abstract class`.
          next_token_skip_space_or_newline
          case @token.value
          when Keyword::CLASS
            cls = parse_class_def is_abstract: true
            cls.exported = true if cls.is_a?(ClassDef)
            cls
          when Keyword::STRUCT
            cls = parse_class_def is_abstract: true, is_struct: true
            cls.exported = true if cls.is_a?(ClassDef)
            cls
          when Keyword::DEF
            a_def = parse_def is_abstract: true
            a_def.exported = true
            a_def
          else
            raise "`pub abstract` takes a class, a struct or a def", @token.line_number, @token.column_number
          end
        else
          # iyi: the word, when the word is one somebody brought with them.
          # `pub const LIMIT = 10` answered "can't apply `pub` to const",
          # which reads as if `const` were a construct here that `pub`
          # happens not to take. It is not a construct at all, and the
          # sentence a bare `const LIMIT = 10` gets is the one to give.
          if @token.type.ident? && @token.value.to_s.in?("const", "val", "final", "let", "var")
            raise "there is no `#{@token}`: a constant is `LIMIT = ...`, " \
                  "uppercase is what makes it one, and `pub LIMIT = ...` " \
                  "is how a module exports it (SPEC.md R-2)",
              @token.line_number, @token.column_number
          end
          # And the word Rust writes here, which is the language this fork
          # is closest to in spelling: `pub fn greet() -> String` answered
          # "can't apply `pub` to fn", where a bare `fn` has been met with
          # the sentence below since the verbs gate was written.
          if @token.type.ident? && @token.value.to_s.in?("fn", "func", "function")
            raise "there is no `#{@token}`: a function is " \
                  "`pub def name(args) : Type`, and the return type follows " \
                  "a colon rather than an arrow",
              @token.line_number, @token.column_number
          end
          raise "can't apply `pub` to #{@token}", @token.line_number, @token.column_number
        end

      node.at(pub_location)
      node.doc ||= doc
      node
    end

    # iyi: `type Elem` in a trait, `type Elem = String` in an impl (SPEC.md II.6).
    def parse_assoc_type
      doc = @token.doc
      next_token_skip_space_or_newline

      name_location = @token.location
      name = check_const
      next_token_skip_space

      value = nil
      if @token.type.op_eq?
        next_token_skip_space_or_newline
        value = parse_bare_proc_type
        skip_space
      end

      decl = AssocTypeDecl.new(name, value)
      decl.name_location = name_location
      decl.doc = doc
      decl
    end

    # The body of a trait or an impl, parsed with `type` meaning an associated
    # type declaration.
    private def parse_trait_or_impl_body
      old = @inside_trait_or_impl
      @inside_trait_or_impl = true
      body = parse_expressions
      @inside_trait_or_impl = old
      body
    end

    # iyi: the associated types a trait declares (SPEC.md II.6).
    #
    # Collected here rather than found while visiting, because the trait's type
    # is created before its body is visited and these are part of what it is.
    private def collect_trait_assoc_types(body) : Array(String)?
      names = nil
      each_assoc_type_decl(body) do |decl, location|
        if decl.value
          raise "a trait declares an associated type, it does not answer it: write `type #{decl.name}`, and let each impl say what it is", location
        end
        names ||= [] of String
        if names.includes?(decl.name)
          raise "duplicate associated type #{decl.name}", location
        end
        names << decl.name
      end
      names
    end

    # iyi: the answers an impl gives (SPEC.md II.6).
    private def collect_impl_assoc_types(body) : Hash(String, ASTNode)?
      types = nil
      each_assoc_type_decl(body) do |decl, location|
        value = decl.value
        unless value
          raise "an impl has to answer the associated type #{decl.name}: write `type #{decl.name} = ...`", location
        end
        types ||= {} of String => ASTNode
        if types.has_key?(decl.name)
          raise "duplicate associated type #{decl.name}", location
        end
        types[decl.name] = value
      end
      types
    end

    # Only the declarations sitting directly in the body count. One nested
    # inside a type declared in that body is marked by nobody, and the semantic
    # phase rejects it there.
    private def each_assoc_type_decl(body, & : AssocTypeDecl, Location ->)
      case body
      when AssocTypeDecl
        body.in_type_body = true
        yield body, assoc_type_location(body)
      when Expressions
        body.expressions.each do |exp|
          next unless exp.is_a?(AssocTypeDecl)
          exp.in_type_body = true
          yield exp, assoc_type_location(exp)
        end
      end
    end

    private def assoc_type_location(decl : AssocTypeDecl) : Location
      decl.name_location || decl.location || @token.location
    end

    # iyi: `trait Greet ... end` (SPEC.md R-3, II.6)
    def parse_trait_def(exported = false)
      @type_nest += 1

      location = @token.location
      doc = @token.doc

      next_token_skip_space_or_newline

      name_location = @token.location
      name = parse_path
      found_space = @token.type.space?
      skip_space

      type_vars, _ = parse_type_vars
      skip_space

      # iyi: `trait Ord : Eq, Show` — the traits an implementer must already
      # implement (SPEC.md II.6). `:` reads as "bounded by" here exactly as it
      # does in `forall T : Show` and `where Elem : Cmp`.
      supertraits = nil
      if @token.type.op_colon?
        next_token_skip_space_or_newline
        supertraits = [] of ASTNode
        loop do
          supertraits << parse_path
          skip_space
          break unless @token.type.op_comma?
          next_token_skip_space_or_newline
        end
      end

      check(StatementEnd) if type_vars || supertraits || !found_space
      skip_statement_end

      body = push_visibility { parse_trait_or_impl_body }

      end_location = token_end_location
      check_ident :end
      next_token_skip_space

      @type_nest -= 1

      assoc_types = collect_trait_assoc_types(body)

      trait_def = TraitDef.new name, body, type_vars, exported, assoc_types, supertraits
      trait_def.doc = doc
      trait_def.name_location = name_location
      trait_def.end_location = end_location
      trait_def.at(location)
      trait_def
    end

    # iyi: `impl Greet for User ... end`, `impl Greet for Box(T) forall T`,
    # `impl Show for Box(T) forall T : Show` (SPEC.md II.7),
    # `impl Into(String) for User` (SPEC.md II.6)
    def parse_impl_def
      @type_nest += 1

      location = @token.location
      doc = @token.doc

      next_token_skip_space_or_newline

      name_location = @token.location

      # Parsed as a type rather than a path, so that a parameterised trait
      # reuses the same argument grammar every other type position uses —
      # `impl Into(Array(String)) for User` needs no rule of its own. It stops
      # before `for` for the same reason the target below stops before
      # `forall`: neither is a type token.
      trait_node = parse_bare_proc_type
      trait_path, trait_args =
        case trait_node
        when Path
          {trait_node, nil}
        when Generic
          name = trait_node.name
          unless name.is_a?(Path)
            raise "expected a trait name after `impl`", name_location
          end
          {name, trait_node.type_vars}
        else
          raise "expected a trait name after `impl`", name_location
        end
      skip_space

      check_ident :for
      next_token_skip_space_or_newline

      target = parse_bare_proc_type
      skip_space

      type_vars = nil
      type_var_bounds = nil
      if @token.type.ident? && @token.value == "forall"
        next_token_skip_space
        type_vars = [] of String
        loop do
          check Token::Kind::CONST
          name = @token.value.to_s
          type_vars << name
          next_token_skip_space

          # `forall T : Show` — the bound is a trait, and nothing else. There
          # is no separate constraint language to learn: what you can bound by
          # is what you can implement.
          if @token.type.op_colon?
            next_token_skip_space_or_newline
            type_var_bounds ||= {} of String => ASTNode
            type_var_bounds[name] = parse_path
            skip_space
          end

          break unless @token.type.op_comma?
          next_token_skip_space_or_newline
        end
      end

      skip_statement_end

      body = push_visibility { parse_trait_or_impl_body }

      end_location = token_end_location
      check_ident :end
      next_token_skip_space

      @type_nest -= 1

      assoc_types = collect_impl_assoc_types(body)

      impl_def = ImplDef.new trait_path, target, body, type_vars, type_var_bounds, trait_args, assoc_types
      impl_def.doc = doc
      impl_def.name_location = name_location
      impl_def.end_location = end_location
      impl_def.at(location)
      impl_def
    end

    def parse_module_def
      location = @token.location
      doc = @token.doc

      next_token_skip_space_or_newline

      # iyi: `module app/user` — compilation-unit header, lowercase path and no
      # body. Crystal's `module Foo ... end` takes a CONST, so the token type
      # after `module` is enough to tell them apart without lookahead.
      if @token.type.ident?
        path = parse_module_path
        header = ModuleHeader.new(path)
        header.at(location)
        header.end_location = token_end_location
        return header
      end

      @type_nest += 1

      name_location = @token.location
      name = parse_path
      found_space = @token.type.space?
      skip_space

      type_vars, splat_index = parse_type_vars

      check(StatementEnd) if type_vars || !found_space
      skip_statement_end

      iyi_opened "module", name_location
      body = push_visibility { parse_expressions }

      end_location = token_end_location
      check_ident :end
      iyi_closed
      next_token_skip_space

      @type_nest -= 1

      module_def = ModuleDef.new name, body, type_vars, splat_index
      module_def.doc = doc
      module_def.name_location = name_location
      module_def.end_location = end_location
      set_visibility module_def
      module_def
    end

    def parse_annotation_def
      location = @token.location
      doc = @token.doc

      next_token_skip_space_or_newline

      name_location = @token.location
      name = parse_path
      check StatementEnd
      skip_statement_end

      end_location = token_end_location
      check_ident :end
      next_token_skip_space

      annotation_def = AnnotationDef.new name
      annotation_def.doc = doc
      annotation_def.name_location = name_location
      annotation_def.end_location = end_location
      annotation_def
    end

    def parse_parenthesized_expression
      location = @token.location
      slash_is_regex!
      next_token_skip_space_or_newline

      if @token.type.op_rparen?
        end_location = token_end_location
        node = Expressions.new([Nop.new] of ASTNode).at(location).at_end(end_location)
        node.keyword = :paren
        return node_and_next_token node
      end

      exps = [] of ASTNode

      # do...end in parenthesis should not stop because there's no call further
      # left to bind to:
      #
      # ```
      # (foo do
      # end)
      # ```
      @stop_on_do = false

      # iyi: on the unclosed stack, so the file ending inside it says
      # "unterminated parenthesized expression" at the `(` rather than
      # "unexpected token: EOF" at the last line. Only the end of the
      # file is read that way; `unexpected_token_in_atomic` says so.
      open("parenthesized expression", location) do
        while true
          exps << parse_expression
          case @token.type
          when .op_rparen?
            @wants_regex = false
            end_location = token_end_location
            next_token_skip_space
            break
          when .newline?, .op_semicolon?
            next_token_skip_statement_end
            if @token.type.op_rparen?
              @wants_regex = false
              end_location = token_end_location
              next_token_skip_space
              break
            end
          else
            raise "unterminated parenthesized expression", location
          end
        end
      end

      unexpected_token if @token.type.op_lparen?

      node = Expressions.new(exps).at(location).at_end(end_location)
      node.keyword = :paren
      node
    end

    def parse_fun_literal
      location = @token.location

      next_token_skip_space_or_newline

      case @token.type
      when .symbol?
        # -> :T { }
        raise "a space is mandatory between ':' and return type", @token
      when .op_lparen?, .op_lcurly?, .op_colon?
        # do nothing
      else
        return parse_fun_pointer unless @token.keyword?(:do)
      end

      params = [] of Arg
      if @token.type.op_lparen?
        next_token_skip_space_or_newline
        while !@token.type.op_rparen?
          param = parse_fun_literal_param
          if params.any? &.name.==(param.name)
            raise "duplicated proc literal parameter name: #{param.name}", param.location.not_nil!
          end

          params << param
        end
        next_token_skip_space_or_newline
      end

      case @token.type
      when .symbol?
        # ->() :T { }
        raise "a space is mandatory between ':' and return type", @token
      when .op_colon?
        next_token_skip_space_or_newline
        return_type = parse_bare_proc_type
        skip_space_or_newline
      end

      with_lexical_var_scope do
        push_vars params

        end_location = nil

        if @token.keyword?(:do)
          next_token_skip_statement_end
          check_not_pipe_before_proc_literal_body
          body = parse_expressions
          body, end_location, _ = parse_exception_handler body, implicit: true
        elsif @token.type.op_lcurly?
          next_token_skip_statement_end
          check_not_pipe_before_proc_literal_body
          body = preserve_stop_on_do { parse_expressions }
          end_location = token_end_location
          check :OP_RCURLY
          next_token_skip_space
        else
          unexpected_token
        end

        a_def = Def.new("->", params, body, return_type: return_type).at(location).at_end(end_location)
        ProcLiteral.new(a_def).at(location).at_end(end_location)
      end
    end

    def check_not_pipe_before_proc_literal_body
      if @token.type.op_bar?
        location = @token.location
        next_token_skip_space

        msg = String.build do |msg|
          msg << %[unexpected token: "|", proc literals specify their parameters like this: ->(]
          if @token.type.ident?
            msg << @token.value.to_s << " : Type"
            next_token_skip_space_or_newline
            msg << ", ..." if @token.type.op_comma?
          else
            msg << "param : Type"
          end
          msg << ") { ... }"
        end

        raise msg, location
      end
    end

    def parse_fun_literal_param
      name = check_ident
      location = @token.location
      end_location = token_end_location
      next_token_skip_space_or_newline

      if @token.type.op_colon?
        next_token_skip_space_or_newline

        type = parse_bare_proc_type
        end_location = type.end_location
      end

      if @token.type.op_comma?
        next_token_skip_space_or_newline
      else
        skip_space_or_newline
        check :OP_RPAREN
      end

      Arg.new(name, restriction: type).at(location).at_end(end_location)
    end

    def parse_fun_pointer
      location = @token.location

      global = false
      if @token.type.op_colon_colon?
        next_token_skip_space_or_newline
        global = true
      end

      case @token.type
      when .ident?
        name = @token.value.to_s
        var_location = @token.location
        var_end_location = token_end_location
        global_call = global
        equals_sign, end_location = consume_def_equals_sign_skip_space
        if equals_sign
          name = "#{name}="
        elsif @token.type.op_period?
          raise "ProcPointer of local variable cannot be global", location if global
          if name != "self" && !var_in_scope?(name)
            raise "undefined variable '#{name}'", location
          end
          obj = Var.new(name).at(var_location).at_end(var_end_location)

          name = consume_def_or_macro_name
          equals_sign, end_location = consume_def_equals_sign_skip_space
          name = "#{name}=" if equals_sign
        end
      when .const?
        obj = parse_generic global: global, location: location, expression: false
        skip_space
        check :OP_PERIOD
        name = consume_def_or_macro_name
        equals_sign, end_location = consume_def_equals_sign_skip_space
        name = "#{name}=" if equals_sign
      when .instance_var?
        raise "ProcPointer of instance variable cannot be global", location if global
        obj = InstanceVar.new(@token.value.to_s).at(location).at_end(token_end_location)
        next_token_skip_space
        check :OP_PERIOD
        name = consume_def_or_macro_name
        equals_sign, end_location = consume_def_equals_sign_skip_space
        name = "#{name}=" if equals_sign
      when .class_var?
        raise "ProcPointer of class variable cannot be global", location if global
        obj = ClassVar.new(@token.value.to_s).at(location).at_end(token_end_location)
        next_token_skip_space
        check :OP_PERIOD
        name = consume_def_or_macro_name
        equals_sign, end_location = consume_def_equals_sign_skip_space
        name = "#{name}=" if equals_sign
      else
        unexpected_token
      end

      if @token.type.op_period?
        unexpected_token
      end

      if @token.type.op_lparen?
        next_token_skip_space
        types = parse_union_types(:OP_RPAREN)
        check :OP_RPAREN
        end_location = token_end_location
        next_token_skip_space
      else
        types = [] of ASTNode
      end

      ProcPointer.new(obj, name, types, !!global_call).at_end(end_location)
    end

    record Piece,
      value : String | ASTNode,
      line_number : Int32

    def parse_delimiter(want_skip_space = true)
      if @token.type.string?
        return node_and_next_token StringLiteral.new(@token.value.to_s).at(@token.location)
      end

      location = @token.location
      delimiter_state = @token.delimiter_state

      check :DELIMITER_START

      if delimiter_state.kind.heredoc?
        if @inside_interpolation
          raise "heredoc cannot be used inside interpolation", location
        end
        node = StringInterpolation.new([] of ASTNode).at(location)
        @heredocs << {delimiter_state, node}
        next_token
        return node
      end

      next_string_token(delimiter_state)
      delimiter_state = @token.delimiter_state

      pieces = [] of Piece

      delimiter_state, options, end_location = consume_delimiter pieces, delimiter_state

      if want_skip_space && delimiter_state.kind.string?
        while true
          passed_backslash_newline = @token.passed_backslash_newline
          skip_space

          if passed_backslash_newline && @token.type.delimiter_start? && @token.delimiter_state.kind.string?
            next_string_token(delimiter_state)
            delimiter_state = @token.delimiter_state
            delimiter_state, options, end_location = consume_delimiter pieces, delimiter_state
          else
            break
          end
        end
      end

      result = combine_pieces(pieces, delimiter_state).at(location).at_end(end_location)

      case delimiter_state.kind
      when .command?
        result = Call.new("`", result).at(result)
      when .regex?
        # iyi: no compile-time pattern check. It was `Regex.error?`, which is
        # pcre2, and pcre2 is off the compiler (SPEC.md III.10, Appendix B
        # #22), so the compiler can no longer promise pcre2's semantics and
        # stops pretending to check them. A macro pattern is compiled by
        # Iyi::Rx when the macro runs and refused there by name; a `.cr`
        # program's pattern is compiled by the Regex that program links, when
        # its `$Regex` constant initialises at startup; a `.iyi` program's
        # literal is refused by the literal expander, which has no runtime
        # Regex to offer.
        result = RegexLiteral.new(result, options).at(result)
      else
        # no special treatment
      end

      result
    end

    private def combine_pieces(pieces, delimiter_state)
      if pieces.any?(&.value.is_a?(ASTNode))
        pieces = combine_interpolation_pieces(pieces, delimiter_state)
        StringInterpolation.new(pieces)
      else
        string = combine_stringliteral_pieces(pieces, delimiter_state)
        StringLiteral.new(string)
      end
    end

    private def combine_interpolation_pieces(pieces, delimiter_state)
      if needs_heredoc_indent_removed?(delimiter_state)
        remove_heredoc_indent(pieces, delimiter_state.heredoc_indent)
      else
        pieces.map do |piece|
          value = piece.value
          value.is_a?(String) ? StringLiteral.new(value) : value
        end
      end
    end

    private def combine_stringliteral_pieces(pieces, delimiter_state)
      if needs_heredoc_indent_removed?(delimiter_state)
        pieces = remove_heredoc_indent(pieces, delimiter_state.heredoc_indent)
        pieces.join { |piece| piece.as(StringLiteral).value }
      else
        pieces.map(&.value).join
      end
    end

    def consume_delimiter(pieces, delimiter_state)
      options = RegexOptions::None
      end_location = nil
      while true
        case @token.type
        when .string?
          pieces << Piece.new(@token.value.to_s, @token.line_number)

          next_string_token(delimiter_state)
          delimiter_state = @token.delimiter_state
        when .delimiter_end?
          if delimiter_state.kind.regex?
            options = consume_regex_options
          end
          end_location = token_end_location
          next_token
          break
        when .eof?
          case delimiter_state.kind
          when .command?
            raise "Unterminated command"
          when .regex?
            raise "Unterminated regular expression"
          when .heredoc?
            raise "Unterminated heredoc"
          else
            raise "Unterminated string literal"
          end
        else
          next_token_skip_space_or_newline

          line_number = @token.line_number
          exp = consume_interpolation(delimiter_state)
          next_string_token delimiter_state
          pieces << Piece.new(exp, line_number)
          delimiter_state = @token.delimiter_state
        end
      end

      {delimiter_state, options, end_location}
    end

    def consume_interpolation(delimiter_state)
      old_inside_interpolation = @inside_interpolation
      @inside_interpolation = true

      exp = preserve_stop_on_do { parse_expression }

      skip_space_or_newline
      if !@token.type.op_rcurly?
        raise "Unterminated string interpolation"
      end

      @token.delimiter_state = delimiter_state
      @inside_interpolation = old_inside_interpolation

      # We cannot reduce `StringLiteral` of interpolation inside heredoc into `String`
      # because heredoc try to remove its indentation.
      if exp.is_a?(StringLiteral) && !delimiter_state.kind.heredoc?
        exp = exp.value
      end

      exp
    end

    def consume_regex_options
      options = RegexOptions::None
      while true
        case current_char
        when 'i'
          options |= RegexOptions::IGNORE_CASE
          next_char
        when 'm'
          options |= RegexOptions::MULTILINE
          next_char
        when 'x'
          options |= RegexOptions::EXTENDED
          next_char
        else
          if 'a' <= current_char.downcase <= 'z'
            raise "unknown regex option: #{current_char}"
          end
          break
        end
      end
      options
    end

    def consume_heredocs
      @consuming_heredocs = true
      @heredocs.reverse!
      while heredoc = @heredocs.pop?
        consume_heredoc(heredoc[0], heredoc[1].as(StringInterpolation))
      end
      @consuming_heredocs = false
    end

    def consume_heredoc(delimiter_state, node)
      next_string_token(delimiter_state)
      delimiter_state = @token.delimiter_state

      pieces = [] of Piece

      delimiter_state, _options, end_location = consume_delimiter pieces, delimiter_state

      result = combine_pieces(pieces, delimiter_state)
      if result.is_a?(StringInterpolation)
        node.expressions.concat(result.expressions)
      else
        node.expressions.push(result.at(node).at_end(end_location))
      end

      node.heredoc_indent = delimiter_state.heredoc_indent

      node.end_location = end_location
    end

    def needs_heredoc_indent_removed?(delimiter_state)
      delimiter_state.kind.heredoc? && delimiter_state.heredoc_indent >= 0
    end

    def remove_heredoc_indent(pieces : Array, indent)
      current_line = IO::Memory.new
      remove_indent = true
      new_pieces = [] of ASTNode | String
      previous_line_number = 0
      pieces.each_with_index do |piece, i|
        value = piece.value
        line_number = piece.line_number

        this_piece_is_in_new_line = line_number != previous_line_number
        next_piece_is_in_new_line = i == pieces.size - 1 || pieces[i + 1].line_number != line_number
        if value.is_a?(String)
          if value.in?("\n", "\r\n")
            current_line << value
            if this_piece_is_in_new_line || next_piece_is_in_new_line
              line = current_line.to_s
              line = remove_heredoc_from_line(line, indent, line_number - 1) if remove_indent
              add_heredoc_piece new_pieces, line
              current_line.clear
              remove_indent = true
            end
          elsif (slash_n = value.starts_with?('\n')) || value.starts_with?("\r\n")
            current_line << (slash_n ? '\n' : "\r\n")
            line = current_line.to_s
            line = remove_heredoc_from_line(line, indent, line_number - 1) if remove_indent
            add_heredoc_piece new_pieces, line
            current_line.clear
            remove_indent = true
            current_line << value.byte_slice(slash_n ? 1 : 2)
          else
            current_line << value
          end
        else
          if remove_indent
            line = current_line.to_s
            if (line.size < indent) || !line.each_char.first(indent).all?(&.ascii_whitespace?)
              raise "heredoc line must have an indent greater than or equal to #{indent}", line_number, 1
            else
              line = line[indent..-1]
            end
            add_heredoc_piece new_pieces, line unless line.empty?
            add_heredoc_piece new_pieces, value
            remove_indent = false
            current_line.clear
          else
            unless current_line.empty?
              line = current_line.to_s
              add_heredoc_piece new_pieces, line
              current_line.clear
            end

            add_heredoc_piece new_pieces, value
          end
        end
        previous_line_number = line_number
      end
      unless current_line.empty?
        line = current_line.to_s
        line = remove_heredoc_from_line(line, indent, pieces.last.line_number) if remove_indent
        add_heredoc_piece new_pieces, line
      end
      new_pieces.map do |piece|
        if piece.is_a?(String)
          StringLiteral.new(piece)
        else
          piece
        end
      end
    end

    private def add_heredoc_piece(pieces, piece : String)
      last = pieces.last?
      if last.is_a?(String)
        last += piece
        pieces[-1] = last
      else
        pieces << piece
      end
    end

    private def add_heredoc_piece(pieces, piece : ASTNode)
      pieces << piece
    end

    def remove_heredoc_from_line(line, indent, line_number)
      if line.each_char.first(indent).all? &.ascii_whitespace?
        if line.size - 1 < indent
          "\n"
        else
          line[indent..-1]
        end
      else
        raise "heredoc line must have an indent greater than or equal to #{indent}", line_number, 1
      end
    end

    def parse_string_without_interpolation(context, want_skip_space = true)
      parse_string_literal_without_interpolation(context, want_skip_space).value
    end

    def parse_string_literal_without_interpolation(context, want_skip_space = true)
      location = @token.location

      unless string_literal_start?
        raise "expected string literal for #{context}, not #{@token}"
      end

      string = parse_delimiter(want_skip_space)
      if string.is_a?(StringLiteral)
        string
      else
        raise "interpolation not allowed in #{context}", location
      end
    end

    def parse_string_array
      strings, end_location = parse_string_or_symbol_array_strings do |pieces|
        combine_pieces(pieces, @token.delimiter_state)
      end

      ArrayLiteral.new(strings, Path.global("String")).at_end(end_location)
    end

    def parse_symbol_array
      strings, end_location = parse_string_or_symbol_array_strings do |pieces|
        string = combine_stringliteral_pieces(pieces, @token.delimiter_state)
        SymbolLiteral.new(string)
      end

      ArrayLiteral.new(strings, Path.global("Symbol")).at_end(end_location)
    end

    def parse_string_or_symbol_array_strings(&)
      strings = [] of ASTNode

      while !@token.type.string_array_end?
        if element = parse_percent_array_element { |pieces| yield pieces }
          strings << element
        end
      end

      check :STRING_ARRAY_END

      end_location = @token.location

      next_token

      {strings, end_location}
    end

    def parse_percent_array_element(&)
      pieces = [] of Piece
      start_location = nil
      end_location = nil
      delimiter_state = @token.delimiter_state

      while true
        end_location = token_end_location
        next_string_token(delimiter_state)
        start_location ||= @token.location
        delimiter_state = @token.delimiter_state
        case @token.type
        when .string?
          pieces << Piece.new(@token.value.to_s, @token.line_number)
        when .interpolation_start?
          line_number = @token.line_number
          # parse interpolation expression
          next_token_skip_space_or_newline
          if @token.type.op_star?
            unless pieces.empty?
              raise "splat interpolation must be the only piece in a string array element", @token
            end

            splat_location = @token.location
            next_token_skip_space_or_newline

            exp = consume_interpolation(delimiter_state)

            next_string_token(delimiter_state)
            unless @token.type.space? || @token.type.string_array_end?
              raise "splat interpolation must be the only piece in a string array element", @token
            end

            if exp.is_a?(String)
              exp = StringLiteral.new(exp)
            end

            return Splat.new(exp).at(splat_location)
          else
            pieces << Piece.new(consume_interpolation(delimiter_state), line_number)
          end
        else
          break
        end
      end

      return if pieces.empty?

      (yield pieces).at(start_location).at_end(end_location)
    end

    def parse_empty_array_literal
      line = @line_number
      column = @token.column_number

      next_token_skip_space
      if @token.keyword?(:of)
        next_token_skip_space_or_newline
        of = parse_bare_proc_type
        ArrayLiteral.new(of: of).at_end(of)
      else
        raise "for empty arrays use '[] of ElementType'", line, column
      end
    end

    def parse_array_literal
      line = @line_number
      column = @token.column_number

      slash_is_regex!

      exps = [] of ASTNode
      end_location = nil

      open("array literal") do
        next_token_skip_space_or_newline
        while !@token.type.op_rsquare?
          exp_location = @token.location

          if @token.type.op_star?
            next_token_skip_space_or_newline
            exp = Splat.new(parse_op_assign_no_control).at(exp_location)
          else
            exp = parse_op_assign_no_control
          end

          exps << exp
          skip_space

          if @token.type.op_comma?
            slash_is_regex!
            next_token_skip_space_or_newline
          else
            skip_space_or_newline
            check :OP_RSQUARE
            break
          end
        end
        @wants_regex = false
        end_location = token_end_location
        next_token_skip_space
      end

      of = nil
      if @token.keyword?(:of)
        next_token_skip_space_or_newline
        of = parse_bare_proc_type
        end_location = of.end_location
      elsif exps.size == 0
        raise "for empty arrays use '[] of ElementType'", line, column
      end

      ArrayLiteral.new(exps, of).at_end(end_location)
    end

    def parse_hash_or_tuple_literal(allow_of = true)
      location = @token.location
      line = @line_number
      column = @token.column_number

      slash_is_regex!
      next_token_skip_space_or_newline

      if @token.type.op_rcurly?
        end_location = token_end_location
        next_token_skip_space
        new_hash_literal([] of HashLiteral::Entry, line, column, end_location)
      else
        if named_tuple_start?
          unless allow_of
            raise "can't use named tuple syntax for Hash-like literal, use '=>'", @token
          end
          return parse_named_tuple(location)
        else
          if @token.type.op_star?
            first_is_splat = true
            first_splat_location = @token.location
            next_token_skip_space_or_newline
          end

          key_location = @token.location
          first_key = parse_op_assign_no_control
          first_key = Splat.new(first_key).at(first_splat_location) if first_is_splat
          case @token.type
          when .op_colon?
            unexpected_token if first_is_splat

            # Check that there's no space before the ':'
            if @token.column_number != first_key.end_location.not_nil!.column_number + 1
              raise "space not allowed between named argument name and ':'"
            end

            if first_key.is_a?(StringLiteral)
              # It's a named tuple
              unless allow_of
                raise "can't use named tuple syntax for Hash-like literal, use '=>'", @token
              end
              if first_key.value.empty?
                raise "named tuple name cannot be empty", key_location
              end
              return parse_named_tuple(location, first_key.value)
            else
              check :OP_EQ_GT
            end
          when .op_comma?
            slash_is_regex!
            next_token_skip_space_or_newline
            return parse_tuple first_key, location
          when .op_rcurly?
            return parse_tuple first_key, location
          when .newline?
            next_token_skip_space
            check :OP_RCURLY
            return parse_tuple first_key, location
          else
            unexpected_token if first_is_splat
            check :OP_EQ_GT
          end
        end
        slash_is_regex!
        next_token_skip_space_or_newline
        parse_hash_literal first_key, location, allow_of
      end
    end

    def parse_hash_literal(first_key, location, allow_of)
      line = @line_number
      column = @token.column_number
      end_location = nil

      entries = [] of HashLiteral::Entry
      entries << HashLiteral::Entry.new(first_key, parse_op_assign)

      if @token.type.newline?
        # iyi: inside the open, so a `{"a" => 1` with the next line under
        # it names the literal and its line, as the multi-entry path does.
        open("hash literal", location) do
          next_token_skip_space_or_newline
          check :OP_RCURLY
        end
        next_token_skip_space
      else
        open("hash literal", location) do
          skip_space_or_newline
          if @token.type.op_comma?
            slash_is_regex!
            next_token_skip_space_or_newline
          else
            skip_space_or_newline
            check :OP_RCURLY
          end

          while !@token.type.op_rcurly?
            key_loc = @token.location
            key = parse_op_assign_no_control
            skip_space_or_newline
            if @token.type.op_colon? && key.is_a?(StringLiteral)
              raise "can't use 'key: value' syntax in a hash literal", key_loc
            else
              check :OP_EQ_GT
            end
            slash_is_regex!
            next_token_skip_space_or_newline
            entries << HashLiteral::Entry.new(key, parse_op_assign)
            skip_space
            if @token.type.op_comma?
              slash_is_regex!
              next_token_skip_space_or_newline
            else
              skip_space_or_newline
              check :OP_RCURLY
              break
            end
          end
          end_location = token_end_location
          next_token_skip_space
        end
      end

      new_hash_literal entries, line, column, end_location, allow_of: allow_of
    end

    def named_tuple_start?
      (@token.type.ident? || @token.type.const?) && current_char == ':' && peek_next_char != ':'
    end

    def string_literal_start?
      @token.type.delimiter_start? && @token.delimiter_state.kind.string?
    end

    def parse_tuple(first_exp, location)
      exps = [] of ASTNode
      end_location = nil

      open("tuple literal", location) do
        exps << first_exp
        while !@token.type.op_rcurly?
          exp_location = @token.location

          if @token.type.op_star?
            next_token_skip_space_or_newline
            exp = Splat.new(parse_op_assign_no_control).at(exp_location)
          else
            exp = parse_op_assign_no_control
          end

          exps << exp
          skip_space

          if @token.type.op_comma?
            next_token_skip_space_or_newline
          else
            skip_space_or_newline
            check :OP_RCURLY
            break
          end
        end
        end_location = token_end_location
        next_token_skip_space
      end

      TupleLiteral.new(exps).at_end(end_location)
    end

    def new_hash_literal(entries, line, column, end_location, allow_of = true)
      of = nil

      if allow_of
        if @token.keyword?(:of)
          next_token_skip_space_or_newline
          of_key = parse_bare_proc_type
          check :OP_EQ_GT
          next_token_skip_space_or_newline
          of_value = parse_bare_proc_type
          of = HashLiteral::Entry.new(of_key, of_value)
          end_location = of_value.end_location
        end

        if entries.empty? && !of
          raise "for empty hashes use '{} of KeyType => ValueType'", line, column
        end
      end

      HashLiteral.new(entries, of).at_end(end_location)
    end

    def parse_named_tuple(location)
      parse_named_tuple(location, @token.value.to_s)
    end

    def parse_named_tuple(location, first_key)
      next_token_never_a_symbol

      slash_is_regex!
      next_token_skip_space

      first_value = parse_op_assign
      skip_space_or_newline

      entries = [] of NamedTupleLiteral::Entry
      entries << NamedTupleLiteral::Entry.new(first_key, first_value)

      if @token.type.op_comma?
        next_token_skip_space_or_newline

        while !@token.type.op_rcurly?
          key_location = @token.location
          key = @token.value.to_s
          if named_tuple_start?
            next_token_never_a_symbol
          elsif string_literal_start?
            key = parse_string_without_interpolation("named tuple name", want_skip_space: false)
          else
            raise "expected '}' or named tuple name, not #{@token}", @token
          end

          if key.empty?
            raise "named tuple name cannot be empty", key_location
          end

          if @token.type.space?
            raise "space not allowed between named argument name and ':'"
          end

          check :OP_COLON

          if entries.any? { |entry| entry.key == key }
            raise "duplicated key: #{key}", @token
          end

          slash_is_regex!
          next_token_skip_space

          value = parse_op_assign_no_control
          skip_space

          entries << NamedTupleLiteral::Entry.new(key, value)
          if @token.type.op_comma?
            next_token_skip_space_or_newline
          else
            break
          end
        end
      end

      skip_space_or_newline
      check :OP_RCURLY

      end_location = token_end_location
      next_token_skip_space

      NamedTupleLiteral.new(entries).at(location).at_end(end_location)
    end

    def parse_require
      raise "can't require inside type declarations", @token if @type_nest > 0

      next_token_skip_space
      string_literal = parse_string_literal_without_interpolation("require")

      skip_space

      Require.new(string_literal.value).at_end(string_literal)
    end

    def parse_case
      slash_is_regex!
      next_token_skip_space_or_newline
      while @token.type.op_semicolon?
        next_token_skip_space
      end

      unless @token.value.in?(Keyword::WHEN, Keyword::ELSE, Keyword::END)
        cond = parse_op_assign_no_control
        skip_statement_end
      end

      # iyi: `it` names the value being matched inside every branch
      # (SPEC.md III.1.1). It has to be declared before the bodies are parsed,
      # because that is where an identifier is decided to be a variable rather
      # than a call. A tuple subject has no single value to name, so it is left
      # out rather than given one of its elements.
      binds_it = iyi? && !cond.nil? && !cond.is_a?(TupleLiteral)
      push_var_name "it" if binds_it

      whens = [] of When
      a_else = nil
      exhaustive = nil

      # All when expressions, so we can detect duplicates
      when_exps = Set(ASTNode).new

      while true
        case @token.value
        when Keyword::WHEN, Keyword::IN
          if exhaustive.nil?
            exhaustive = @token.value == Keyword::IN
            if exhaustive && !cond
              raise "exhaustive case (case ... in) requires a case expression (case exp; in ..)"
            end
          elsif exhaustive && @token.value == Keyword::WHEN
            raise "expected 'in', not 'when'"
          elsif !exhaustive && @token.value == Keyword::IN
            raise "expected 'when', not 'in'"
          end

          location = @token.location
          {% if compare_versions(Crystal::VERSION, "1.1.0") < 0 %}
            # FIXME: Workaround for compiler bug in Crystal 1.0 and earlier (https://github.com/crystal-lang/crystal/pull/15452#issuecomment-2653266710)
            end_location = token_end_location
          {% end %}
          slash_is_regex!
          next_token_skip_space_or_newline
          when_conds = [] of ASTNode

          if cond.is_a?(TupleLiteral)
            raise "splat is not allowed inside case expression" if cond.elements.any?(Splat)

            while true
              if @token.type.op_lcurly?
                curly_location = @token.location

                next_token_skip_space_or_newline

                tuple_elements = [] of ASTNode

                while true
                  exp = parse_when_expression(cond, single: false, exhaustive: exhaustive)
                  check_valid_exhaustive_expression(exp) if exhaustive

                  tuple_elements << exp

                  skip_space
                  if @token.type.op_comma?
                    next_token_skip_space_or_newline
                  else
                    break
                  end
                end

                if tuple_elements.size != cond.elements.size
                  raise "wrong number of tuple elements (given #{tuple_elements.size}, expected #{cond.elements.size})", curly_location
                end

                tuple = TupleLiteral.new(tuple_elements).at(curly_location)
                when_conds << tuple
                add_when_exp(when_exps, tuple)

                check :OP_RCURLY
                next_token_skip_space
              else
                exp = parse_when_expression(cond, single: true, exhaustive: exhaustive)
                when_conds << exp
                add_when_exp(when_exps, exp)
                skip_space
              end

              break if when_expression_end
            end
          else
            while true
              exp = parse_when_expression(cond, single: true, exhaustive: exhaustive)
              check_valid_exhaustive_expression(exp) if exhaustive

              when_conds << exp
              add_when_exp(when_exps, exp)
              skip_space
              break if when_expression_end
            end
          end

          when_body = parse_expressions
          skip_space_or_newline
          whens << When.new(when_conds, when_body)
            .at(location)
            .at_end(when_conds.last.end_location)
        when Keyword::ELSE
          if exhaustive
            raise "exhaustive case (case ... in) doesn't allow an 'else'"
          end

          next_token_skip_statement_end
          a_else = parse_expressions
          skip_statement_end
          check_ident :end
          end_location = token_end_location
          next_token
          break
        when Keyword::END
          end_location = token_end_location
          next_token
          break
        else
          unexpected_token "expecting when, else or end"
        end
      end

      node = Case.new(cond, whens, a_else, exhaustive.nil? ? false : exhaustive).at_end(end_location)
      node.binds_it = binds_it
      node
    end

    def check_valid_exhaustive_expression(exp)
      case exp
      when NilLiteral, BoolLiteral, Path, Generic, Underscore
        return
      when Call
        if exp.obj.is_a?(ImplicitObj) && exp.name.ends_with?('?') &&
           exp.args.empty? && !exp.named_args &&
           !exp.block
          return
        end

        if (exp.obj.is_a?(Path) || exp.obj.is_a?(Generic)) && exp.name == "class" &&
           exp.args.empty? && !exp.named_args &&
           !exp.block
          return
        end
      end

      raise "expression of exhaustive case (case ... in) must be a constant (like `IO::Memory`), a generic (like `Array(Int32)`), a bool literal (true or false), a nil literal (nil) or a question method (like `.red?`)", exp.location.not_nil!
    end

    # Adds an expression to all when expressions and error on duplicates
    def add_when_exp(when_exps, exp)
      return unless when_exp_constant?(exp)

      if when_exps.includes?(exp)
        raise "duplicate when #{exp} in case", exp.location.not_nil!
      end

      when_exps << exp
    end

    # Only error on constant values, because calls might have side-effects:
    # a first call might return one value and not match the case
    # value, but the second same call returns something different
    # and matches it.
    def when_exp_constant?(exp)
      case exp
      when NilLiteral, BoolLiteral, CharLiteral, NumberLiteral,
           StringLiteral, SymbolLiteral, Path
        true
      when ArrayLiteral
        exp.elements.all? { |e| when_exp_constant?(e) }
      when TupleLiteral
        exp.elements.all? { |e| when_exp_constant?(e) }
      when RegexLiteral
        when_exp_constant?(exp.value)
      when RangeLiteral
        when_exp_constant?(exp.from) &&
          when_exp_constant?(exp.to)
      else
        false
      end
    end

    def when_expression_end
      slash_is_regex!
      if @token.keyword?(:then)
        next_token_skip_space_or_newline
        return true
      else
        case @token.type
        when .op_comma?
          next_token_skip_space_or_newline
        when .newline?
          skip_space_or_newline
          return true
        when .op_semicolon?
          skip_statement_end
          return true
        else
          unexpected_token "expecting ',', ';' or '\\n'"
        end
      end
      false
    end

    def parse_when_expression(cond, single, exhaustive)
      if cond && @token.type.op_period?
        location = @token.location
        next_token
        call = parse_var_or_call(force_call: true).at(location)
        case call
        when Call        then call.obj = ImplicitObj.new
        when RespondsTo  then call.obj = ImplicitObj.new
        when IsA         then call.obj = ImplicitObj.new
        when Cast        then call.obj = ImplicitObj.new
        when NilableCast then call.obj = ImplicitObj.new
        when Not         then call.exp = ImplicitObj.new
        else
          raise "BUG: expected Call, RespondsTo, IsA, Cast or NilableCast"
        end
        call
      elsif single && @token.type.underscore?
        if exhaustive
          raise "'when _' is not supported"
        else
          raise "'when _' is not supported, use 'else' block instead"
        end
      else
        parse_op_assign_no_control
      end
    end

    def parse_select
      slash_is_regex!
      next_token_skip_space
      skip_statement_end

      {% if compare_versions(Crystal::VERSION, "1.1.0") < 0 %}
        # FIXME: Workaround for compiler bug in Crystal 1.0 and earlier (https://github.com/crystal-lang/crystal/pull/15452#issuecomment-2653266710)
        end_location = token_end_location
      {% end %}
      whens = [] of When

      while true
        case @token.value
        when Keyword::WHEN
          slash_is_regex!
          next_token_skip_space_or_newline

          location = @token.location
          condition = parse_op_assign_no_control
          unless valid_select_when?(condition)
            raise "invalid select when expression: must be an assignment or call", location
          end

          skip_space
          unless when_expression_end
            unexpected_token "expecting then, ';' or newline"
          end
          skip_statement_end

          body = parse_expressions
          skip_space_or_newline

          whens << When.new(condition, body)
            .at(location)
            .at_end(condition.end_location)
        when Keyword::ELSE
          if whens.size == 0
            unexpected_token "expecting when"
          end
          slash_is_regex!
          next_token_skip_statement_end
          a_else = parse_expressions
          skip_statement_end
          check_ident :end
          end_location = token_end_location
          next_token
          break
        when Keyword::END
          if whens.empty?
            unexpected_token "expecting when, else or end"
          end
          end_location = token_end_location
          next_token
          break
        else
          unexpected_token "expecting when, else or end"
        end
      end

      Select.new(whens, a_else).at_end(end_location)
    end

    def valid_select_when?(node)
      case node
      when Assign
        node.value.is_a?(Call)
      when Call
        true
      else
        false
      end
    end

    def parse_include
      parse_include_or_extend Include
    end

    def parse_extend
      parse_include_or_extend Extend
    end

    def parse_include_or_extend(klass)
      location = @token.location

      next_token_skip_space_or_newline

      if @token.keyword?(:self)
        name = Self.new.at(@token.location)
        name.end_location = token_end_location
        next_token_skip_space
      else
        name = parse_generic
        skip_space
      end

      klass.new name
    end

    def parse_to_def(a_def)
      prepare_parse_def
      @def_nest += 1

      result = parse

      a_def.calls_super = @calls_super
      a_def.calls_initialize = @calls_initialize
      a_def.calls_previous_def = @calls_previous_def
      a_def.uses_block_arg = @uses_block_arg
      a_def.assigns_special_var = @assigns_special_var

      result
    end

    def parse_def(is_abstract = false, is_macro_def = false, doc = nil)
      doc ||= @token.doc

      prepare_parse_def
      a_def = with_isolated_var_scope do
        parse_def_helper is_abstract: is_abstract
      end

      a_def.calls_super = @calls_super
      a_def.calls_initialize = @calls_initialize
      a_def.calls_previous_def = @calls_previous_def
      a_def.uses_block_arg = @uses_block_arg
      a_def.assigns_special_var = @assigns_special_var
      a_def.doc = doc
      @calls_super = false
      @calls_initialize = false
      @calls_previous_def = false
      @uses_block_arg = false
      @assigns_special_var = false
      @block_arg_name = nil
      @is_macro_def = false
      a_def
    end

    def prepare_parse_def
      @calls_super = false
      @calls_initialize = false
      @calls_previous_def = false
      @uses_block_arg = false
      @block_arg_name = nil
      @assigns_special_var = false
      @is_macro_def = false
    end

    def parse_macro
      doc = @token.doc

      # Force lexer return if possible a def or macro name
      # cases like: def `, def /, def //
      # that in regular statements states for delimiters
      # here must be treated as method names.
      name = consume_def_or_macro_name("macro")
      check_iyi_method_missing name

      with_isolated_var_scope do
        name_location = @token.location

        case @token.type
        when .const?
          raise "macro can't have a receiver"
        when .ident?
          check_valid_def_name
          equals_sign, _ = consume_def_equals_sign_skip_space
          name = "#{name}=" if equals_sign
        else
          check_valid_def_op_name
          next_token_skip_space
        end

        params = [] of Arg

        found_default_value = false
        found_splat = false
        found_double_splat = nil

        splat_index = nil
        double_splat = nil
        index = 0

        case @token.type
        when .op_lparen?
          next_token_skip_space_or_newline
          while !@token.type.op_rparen?
            extras = parse_param(params,
              extra_assigns: nil,
              parentheses: true,
              found_default_value: found_default_value,
              found_splat: found_splat,
              found_double_splat: found_double_splat,
              allow_restrictions: false)
            if !found_default_value && extras.default_value
              found_default_value = true
            end
            if !splat_index && extras.splat
              splat_index = index
              found_splat = true
            end
            if extras.double_splat
              double_splat = params.pop
              found_double_splat = double_splat
            end
            if block_param = extras.block_arg
              check :OP_RPAREN
              break
            elsif @token.type.op_comma?
              next_token_skip_space_or_newline
            else
              skip_space_or_newline
              check :OP_RPAREN
            end
            index += 1
          end

          if splat_index == params.size - 1 && params.last.name.empty?
            raise "named parameters must follow bare *", params.last.location.not_nil!
          end

          next_token
        when .ident?, .op_star?
          if @token.keyword?(:end)
            unexpected_token "expected ';' or newline"
          else
            unexpected_token "parentheses are mandatory for macro parameters"
          end
        when .op_semicolon?, .newline?
          # Skip
        when .op_period?
          raise "macro can't have a receiver"
        else
          unexpected_token
        end

        end_location = nil

        if @token.keyword?(:end)
          end_location = token_end_location
          body = Expressions.new
          next_token_skip_space
        else
          body, end_location = parse_macro_body(name_location)
        end

        node = Macro.new name, params, body, block_param, splat_index, double_splat: double_splat
        node.name_location = name_location
        node.doc = doc
        node.end_location = end_location
        set_visibility node
        node
      end
    end

    def parse_macro_body(start_location, macro_state = Token::MacroState.default)
      skip_whitespace = check_macro_skip_whitespace
      slash_is_regex!

      pieces = [] of ASTNode

      while true
        next_macro_token macro_state, skip_whitespace
        macro_state = @token.macro_state
        if macro_state.yields
          @block_arity ||= 0
        end

        skip_whitespace = false

        case @token.type
        when .macro_literal?
          pieces << MacroLiteral.new(@token.value.to_s).at(@token.location).at_end(token_end_location)
        when .macro_expression_start?
          location = @token.location
          exp = MacroExpression.new(parse_macro_expression).at(location)
          check_macro_expression_end
          skip_whitespace = check_macro_skip_whitespace
          pieces << exp.at_end(token_end_location)
        when .macro_control_start?
          macro_control = parse_macro_control(start_location, macro_state)
          if macro_control
            skip_space_or_newline
            check :OP_PERCENT_RCURLY
            pieces << macro_control
            skip_whitespace = check_macro_skip_whitespace
          else
            return new_macro_expressions(pieces), nil
          end
        when .macro_var?
          macro_var_name = @token.value.to_s
          location = @token.location
          if macro_var_name[0].uppercase? || macro_var_name[0].titlecase?
            warnings.add_warning_at @token.location, "macro fresh variables with constant names are deprecated"
          end

          if lookahead { next_token.type.op_lcurly? }
            if macro_var_name.size == 1
              warnings.add_warning_at @token.location, "single-letter macro fresh variables with indices are deprecated"
            end
            macro_var_exps = parse_macro_var_exps
          else
            macro_var_exps = nil
          end
          pieces << MacroVar.new(macro_var_name, macro_var_exps).at(location).at_end(token_end_location)
        when .macro_end?
          break
        when .eof?
          raise "unterminated macro", start_location
        else
          unexpected_token
        end
      end

      end_location = token_end_location

      next_token

      {new_macro_expressions(pieces), end_location}
    end

    private def new_macro_expressions(pieces)
      if pieces.empty?
        Expressions.new
      else
        Expressions.from(pieces)
      end
    end

    def parse_macro_var_exps
      next_token

      exps = [] of ASTNode
      while !@token.type.op_rcurly?
        exps << parse_expression_inside_macro
        skip_space
        case @token.type
        when .op_comma?
          next_token_skip_space
        when .op_rcurly?
          break
        else
          unexpected_token %(expecting "," or "}")
        end
      end
      exps
    end

    def check_macro_skip_whitespace
      if current_char == '\\' && peek_next_char.ascii_whitespace?
        next_char
        true
      else
        false
      end
    end

    def parse_percent_macro_expression
      raise "can't nest macro expressions", @token if @in_macro_expression

      slash_is_regex!
      location = @token.location
      macro_exp = parse_macro_expression
      check_macro_expression_end
      end_location = token_end_location
      next_token
      MacroExpression.new(macro_exp).at(location).at_end(end_location)
    end

    def parse_macro_expression
      next_token_skip_space_or_newline
      parse_expression_inside_macro
    end

    def check_macro_expression_end
      if @token.type.op_comma?
        raise <<-MSG
          expecting token ',', not '}'

          If you are nesting tuples or hashes you must write them like this:

              { {x, y}, {z, w} } # Note the space after the first curly brace

          because {{...}} is parsed as a macro expression.
          MSG
      end

      check :OP_RCURLY

      next_token
      check :OP_RCURLY
    end

    def parse_percent_macro_control
      raise "can't nest macro expressions", @token if @in_macro_expression

      macro_control = parse_macro_control(@token.location)
      if macro_control
        skip_space_or_newline
        check :OP_PERCENT_RCURLY
        next_token_skip_space
        macro_control
      else
        unexpected_token_in_atomic
      end
    end

    def parse_macro_control(start_location, macro_state = Token::MacroState.default)
      location = @token.location
      next_token_skip_space_or_newline

      case @token.value
      when Keyword::FOR
        next_token_skip_space

        vars = [] of Var

        while true
          var = case @token.type
                when .underscore?
                  "_"
                when .ident?
                  @token.value.to_s
                else
                  unexpected_token "expecting ident or underscore"
                end
          vars << Var.new(var).at(@token.location).at_end(token_end_location)

          next_token_skip_space
          if @token.type.op_comma?
            next_token_skip_space
          else
            break
          end
        end

        check_ident :in
        next_token_skip_space

        exp = parse_expression_inside_macro

        check :OP_PERCENT_RCURLY

        macro_state.control_nest += 1
        body, end_location = parse_macro_body(start_location, macro_state)
        macro_state.control_nest -= 1

        check_ident :end
        next_token_skip_space
        check :OP_PERCENT_RCURLY

        return MacroFor.new(vars, exp, body).at_end(token_end_location)
      when Keyword::IF
        return parse_macro_if(start_location, macro_state).at(location)
      when Keyword::UNLESS
        return parse_macro_if(start_location, macro_state, is_unless: true).at(location)
      when Keyword::BEGIN
        next_token_skip_space
        check :OP_PERCENT_RCURLY

        macro_state.control_nest += 1
        body, end_location = parse_macro_body(start_location, macro_state)
        macro_state.control_nest -= 1

        check_ident :end
        next_token_skip_space
        check :OP_PERCENT_RCURLY

        return MacroIf.new(BoolLiteral.new(true), body).at(location).at_end(token_end_location)
      when Keyword::ELSE, Keyword::ELSIF, Keyword::END
        return nil
      when Keyword::VERBATIM
        next_token_skip_space
        unless @token.keyword?(:do)
          unexpected_token(msg: "expecting 'do'")
        end
        next_token_skip_space
        check :OP_PERCENT_RCURLY

        macro_state.control_nest += 1
        body, end_location = parse_macro_body(start_location, macro_state)
        macro_state.control_nest -= 1

        check_ident :end
        next_token_skip_space
        check :OP_PERCENT_RCURLY

        return MacroVerbatim.new(body).at_end(token_end_location)
      else
        # will be parsed as a normal expression
      end

      @in_macro_expression = true
      exps = parse_expressions
      @in_macro_expression = false

      MacroExpression.new(exps, output: false).at(location).at_end(token_end_location)
    end

    def parse_macro_if(start_location, macro_state, check_end = true, is_unless = false)
      location = @token.location

      next_token_skip_space

      @in_macro_expression = true
      cond = parse_op_assign
      @in_macro_expression = false

      if !@token.type.op_percent_rcurly? && check_end
        @in_macro_expression = true
        if is_unless
          node = parse_unless_after_condition cond, location
        else
          node = parse_if_after_condition cond, location, true
        end
        skip_statement_end
        exps = parse_expressions
        @in_macro_expression = false
        check :OP_PERCENT_RCURLY

        exps = Expressions.concat!(node, exps)
        return MacroExpression.new(exps, output: false).at_end(token_end_location)
      end

      check :OP_PERCENT_RCURLY

      macro_state.control_nest += 1
      a_then, end_location = parse_macro_body(start_location, macro_state)
      macro_state.control_nest -= 1

      case @token.value
      when Keyword::ELSE
        next_token_skip_space
        check :OP_PERCENT_RCURLY

        macro_state.control_nest += 1
        a_else, end_location = parse_macro_body(start_location, macro_state)
        macro_state.control_nest -= 1

        if check_end
          check_ident :end
          next_token_skip_space
          check :OP_PERCENT_RCURLY
        end
      when Keyword::ELSIF
        unexpected_token if is_unless
        start_loc = @token.location
        a_else = parse_macro_if(start_location, macro_state, false).at(start_loc)

        if check_end
          check_ident :end
          next_token_skip_space
          check :OP_PERCENT_RCURLY
        end
      when Keyword::END
        if check_end
          next_token_skip_space
          check :OP_PERCENT_RCURLY
        end
      else
        unexpected_token
      end

      a_then, a_else = a_else, a_then if is_unless
      MacroIf.new(cond, a_then, a_else, is_unless: is_unless).at_end(token_end_location)
    end

    def parse_expression_inside_macro
      @in_macro_expression = true

      case @token.type
      when .op_star?
        next_token_skip_space
        exp = parse_expression
        exp = Splat.new(exp).at(exp)
      when .op_star_star?
        next_token_skip_space
        exp = parse_expression
        exp = DoubleSplat.new(exp).at(exp)
      else
        exp = parse_expression
      end

      skip_space_or_newline

      @in_macro_expression = false
      exp
    end

    # << < <= == === != =~ !~ >> > >= + - * / // ! ~ % & | ^ ** [] []? []= <=> &+ &- &* &**
    DefOrMacroCheck2 = [
      :OP_LT_LT, :OP_LT, :OP_LT_EQ, :OP_EQ_EQ, :OP_EQ_EQ_EQ, :OP_BANG_EQ, :OP_EQ_TILDE,
      :OP_BANG_TILDE, :OP_GT_GT, :OP_GT, :OP_GT_EQ, :OP_PLUS, :OP_MINUS, :OP_STAR, :OP_SLASH,
      :OP_SLASH_SLASH, :OP_BANG, :OP_TILDE, :OP_PERCENT, :OP_AMP, :OP_BAR, :OP_CARET, :OP_STAR_STAR,
      :OP_LSQUARE_RSQUARE, :OP_LSQUARE_RSQUARE_EQ, :OP_LSQUARE_RSQUARE_QUESTION, :OP_LT_EQ_GT,
      :OP_AMP_PLUS, :OP_AMP_MINUS, :OP_AMP_STAR, :OP_AMP_STAR_STAR,
    ] of Token::Kind

    def parse_def_helper(is_abstract = false)
      def_location = @token.location
      @doc_enabled = false
      @def_nest += 1

      # At this point we want to attach the "do" to calls inside the def,
      # not to calls that might have this def as a macro argument.
      @stop_on_do = false

      next_token

      consume_def_or_macro_name

      receiver = nil
      @block_arity = nil
      name_location = @token.location
      receiver_location = @token.location
      end_location = token_end_location

      if @token.type.const?
        receiver = parse_path
        skip_space
        last_was_space = false
      elsif @token.type.ident?
        check_valid_def_name
        name = @token.value.to_s

        equals_sign, _ = consume_def_equals_sign
        check_iyi_def_bang
        name = "#{name}=" if equals_sign
        last_was_space = @token.type.space?
        skip_space
      else
        check_valid_def_op_name
        name = @token.type.to_s

        next_token
        last_was_space = @token.type.space?
        skip_space
      end

      params = [] of Arg
      extra_assigns = [] of ASTNode

      if @token.type.op_period?
        unless receiver
          if name
            receiver = Var.new(name).at(receiver_location).at_end(end_location)
          else
            raise "shouldn't reach this line"
          end
        end

        consume_def_or_macro_name

        if @token.type.ident?
          check_valid_def_name
          name = @token.value.to_s

          name_location = @token.location
          equals_sign, _ = consume_def_equals_sign
          check_iyi_def_bang
          name = "#{name}=" if equals_sign
          last_was_space = @token.type.space?
          skip_space
        else
          check DefOrMacroCheck2
          check_valid_def_op_name
          name = @token.type.to_s

          name_location = @token.location
          next_token
          last_was_space = @token.type.space?
          skip_space
        end
      else
        if receiver
          unexpected_token
        else
          raise "shouldn't reach this line" unless name
        end
        name = name.not_nil!
      end

      found_default_value = false
      found_splat = false
      found_double_splat = nil
      found_block = false

      index = 0
      splat_index = nil
      double_splat = nil

      case @token.type
      when .op_lparen?
        next_token_skip_space_or_newline
        while !@token.type.op_rparen?
          extras = parse_param(params,
            extra_assigns: extra_assigns,
            parentheses: true,
            found_default_value: found_default_value,
            found_splat: found_splat,
            found_double_splat: found_double_splat,
            allow_restrictions: true,
          )
          if !found_default_value && extras.default_value
            found_default_value = true
          end
          if !splat_index && extras.splat
            splat_index = index
            found_splat = true
          end
          if extras.double_splat
            double_splat = params.pop
            found_double_splat = double_splat
          end
          if block_param = extras.block_arg
            compute_block_arg_yields block_param
            check :OP_RPAREN
            found_block = true
            break
          elsif @token.type.op_comma?
            next_token_skip_space_or_newline
          else
            skip_space_or_newline
            check :OP_RPAREN
          end
          index += 1
        end

        end_location = token_end_location

        if Lexer.setter?(name)
          if params.size > 1 || found_splat || found_double_splat
            raise "setter method '#{name}' cannot have more than one parameter"
          elsif found_block
            raise "setter method '#{name}' cannot have a block"
          end
        end

        if splat_index == params.size - 1 && params.last.name.empty?
          raise "named parameters must follow bare *", params.last.location.not_nil!
        end

        next_token
        last_was_space = @token.type.space?
        skip_space
        if @token.type.symbol?
          raise "a space is mandatory between ':' and return type", @token
        end
      when .ident?, .instance_var?, .class_var?, .op_star?, .op_star_star?
        if @token.keyword?(:end)
          unexpected_token %(expected ";" or newline)
        else
          unexpected_token "parentheses are mandatory for def parameters"
        end
      when .op_semicolon?, .newline?
        # Skip
      when .op_colon?
        # Skip
      when .op_amp?
        unexpected_token "parentheses are mandatory for def parameters"
      when .symbol?
        raise "a space is mandatory between ':' and return type", @token
      when .op_minus_gt?
        iyi_return_arrow
      else
        if is_abstract && @token.type.eof?
          # OK
        else
          unexpected_token
        end
      end

      # With parameters the arrow arrives after the `)`, past the case.
      iyi_return_arrow if iyi? && @token.type.op_minus_gt?

      if @token.type.op_colon?
        unless last_was_space
          warnings.add_warning_at @token.location, "space required before colon in return type restriction (run `crystal tool format` to fix this)"
        end
        next_token_skip_space
        return_type = parse_bare_proc_type
        end_location = return_type.end_location
      end

      skip_space
      free_var_bounds = nil
      if @token.type.ident? && @token.value == "forall"
        next_token_skip_space
        free_vars, free_var_bounds = parse_def_free_vars
      end

      skip_space
      where_bounds = nil
      if @token.type.ident? && @token.value == "where"
        next_token_skip_space
        where_bounds = parse_where_bounds
      end

      if is_abstract
        body = Nop.new
      else
        slash_is_regex!
        skip_statement_end

        end_location = token_end_location

        if @token.keyword?(:end)
          body = Expressions.from(extra_assigns).at(@token.location)
          next_token_skip_space
        else
          iyi_opened "def", def_location
          body = parse_expressions
          if extra_assigns.size > 0
            exps = [] of ASTNode
            exps.concat extra_assigns
            if body.is_a?(Expressions)
              exps.concat body.expressions
            else
              exps.push body
            end
            body = Expressions.from(exps).at(body)
          end
          body, end_location, _ = parse_exception_handler body, implicit: true
          iyi_closed
        end
      end

      @def_nest -= 1
      @doc_enabled = @wants_doc

      node = Def.new name, params, body, receiver, block_param, return_type, @is_macro_def, @block_arity, is_abstract, splat_index, double_splat: double_splat, free_vars: free_vars
      node.free_var_bounds = free_var_bounds
      node.where_bounds = where_bounds
      node.name_location = name_location
      set_visibility node
      node.end_location = end_location
      node
    end

    # iyi: `def f(a : Int32) -> Int32` is another language's return arrow.
    # It parsed as a proc literal opening the body, and the report was
    # "expecting token '.', not 'NEWLINE'" - true of the parse and nothing
    # to do with the mistake. A `.cr` keeps the parse it always had.
    private def iyi_return_arrow
      unexpected_token unless iyi?
      raise "unexpected token: \"->\": a return type is `: Type` here, not `-> Type` - `def name(args) : Type`", @token
    end

    # iyi: `def max : Elem where Elem : Comparable` (SPEC.md II.6).
    #
    # `forall` introduces a name and may bound it; `where` bounds a name that
    # is already in scope — an associated type of the enclosing trait. Keeping
    # the two separate keeps `forall`'s rule intact: a name it did not
    # introduce is not its business.
    private def parse_where_bounds : Hash(String, ASTNode)
      bounds = {} of String => ASTNode
      loop do
        check Token::Kind::CONST
        name = @token.value.to_s
        if bounds.has_key?(name)
          raise "duplicate `where` bound for #{name}", @token
        end
        next_token_skip_space

        check :OP_COLON
        next_token_skip_space_or_newline

        bounds[name] = parse_path
        skip_space

        break unless @token.type.op_comma?
        next_token_skip_space_or_newline
      end
      bounds
    end

    # iyi: `def area : Float64` with no body, inside a trait, and the next
    # `def` under it.
    #
    # A requirement in a trait is spelled `abstract def` (SPEC.md II.6); a
    # plain `def` opens a body, so the second `def` is read as nested and
    # the report is "can't define def inside def", which is true of the
    # parse and false of the mistake. Somebody arriving from a language
    # whose interfaces list bare signatures writes this first.
    private def check_iyi_bodiless_trait_def
      return unless iyi? && @inside_trait_or_impl && @def_nest > 0

      raise <<-MSG, @token
        can't define def inside def: the `def` above it has no `end`

        A method a trait requires of its implementers has no body and says
        so - `abstract def name : Type` (SPEC.md II.6). A `def` with a body
        ends with `end`.
        MSG
    end

    # iyi: `def sort!` (SPEC.md III.1.7, decision A).
    #
    # `!` is no longer part of a name, so by here it has been left as its own
    # token. After a `def` name there is nothing to propagate, and the author
    # almost certainly meant a Crystal-style mutating name — so this is the one
    # place that still explains the convention rather than reporting a stray
    # token.
    private def check_iyi_def_bang
      return unless iyi? && @token.type.op_bang?

      raise <<-MSG, @token
        `!` can't be part of a name in iyi

        Name the form that changes its receiver so it says so and the copy
        after the participle — `sort_in_place` mutates, `sorted` returns a new
        value. Postfix `!` propagates an error, and a name has none.
        MSG
    end

    # iyi: `items.sort_by! { |x| ... }` — the same mistake at a call site.
    #
    # By here the `!` has been read as a propagation, and what follows it is
    # a block or an argument list, which a propagation cannot take: the
    # author wrote a Crystal bang method. Said here, because the token that
    # would otherwise be reported is the `{`, and "unexpected token" beside
    # a call that reads correctly in the other language teaches nothing.
    private def check_iyi_bang_call(atomic)
      return unless atomic.is_a?(Propagate) && (call = atomic.exp).is_a?(Call)
      return unless @token.type.op_lcurly? || @token.type.op_lparen? || @token.keyword?(:do)

      raise <<-MSG, @token
        `#{call.name}!` is not a method here: `!` propagates an error, and takes no block

        `!` can't be part of a name in iyi (SPEC.md III.1.7a), so the pair
        Crystal spells `#{call.name}` and `#{call.name}!` is spelled after the
        participle for the copy and with `_in_place` for the one that changes
        its receiver — `sorted`, `sort_in_place`, `sorted_by`, `sort_in_place_by`.
        MSG
    end

    # iyi: `macro method_missing` (SPEC.md III.3).
    #
    # It requires an open method set, and R-3 closes that by construction: a
    # type's methods are its own module's declarations plus its impls, all
    # known from export metadata. A hook that answers calls nobody declared
    # would make that set unknowable, which is the one thing the compilation
    # model needs it to be.
    #
    # Cheap to give up, and counted rather than assumed: one occurrence in the
    # whole Crystal standard library — the hook definition itself — none in
    # Kemal, against `responds_to?` across 34 files.
    private def check_iyi_method_missing(name)
      return unless iyi? && name == "method_missing"

      raise <<-MSG, @token
        `method_missing` doesn't exist in iyi

        It needs a method set that is open to names nobody declared, and R-3
        closes that: a type's methods are what its module declares plus its
        impls. Use compile-time `responds_to?`, which is what Crystal code
        reaches for anyway — see SPEC.md III.3.
        MSG
    end

    def check_valid_def_name
      if @token.value.in?(Keyword::IS_A_QUESTION, Keyword::AS, Keyword::AS_QUESTION, Keyword::RESPONDS_TO_QUESTION, Keyword::NIL_QUESTION)
        raise "'#{@token.value}' is a pseudo-method and can't be redefined", @token
      end
    end

    def check_valid_def_op_name
      if @token.type.op_bang?
        raise "'!' is a pseudo-method and can't be redefined", @token
      end
    end

    # Returns the free variable names and, for iyi, the trait each one is
    # bounded by — `forall B : IntoBody` (SPEC.md II.7 rule 3). A bound is a
    # trait path and nothing else: there is no separate constraint language,
    # so what you can bound by is what you can implement.
    def parse_def_free_vars : {Array(String), Hash(String, ASTNode)?}
      free_vars = [] of String
      bounds = nil
      while true
        check :CONST
        free_var = @token.value.to_s
        raise "duplicated free variable name: #{free_var}", @token if free_vars.includes?(free_var)
        free_vars << free_var

        next_token_skip_space

        if @token.type.op_colon?
          next_token_skip_space_or_newline
          bounds ||= {} of String => ASTNode
          bounds[free_var] = parse_path
          skip_space
        end

        if @token.type.op_comma?
          next_token_skip_space
          check :CONST
        else
          break
        end
      end
      {free_vars, bounds}
    end

    def compute_block_arg_yields(block_arg)
      block_arg_restriction = block_arg.restriction

      # Unwrap parens unions
      while block_arg_restriction.is_a?(Union) && block_arg_restriction.singleton?
        block_arg_restriction = block_arg_restriction.types.first
      end

      if block_arg_restriction.is_a?(ProcNotation)
        @block_arity = block_arg_restriction.inputs.try(&.size) || 0
      else
        @block_arity = 0
      end
    end

    record ArgExtras,
      block_arg : Arg?,
      default_value : Bool,
      splat : Bool,
      double_splat : Bool

    def parse_param(params, extra_assigns, parentheses, found_default_value, found_splat, found_double_splat, allow_restrictions)
      annotations = nil

      # Parse annotations first since they would be before any actual param tokens.
      # Do this in a loop to account for multiple annotations.
      while @token.type.op_at_lsquare?
        (annotations ||= Array(Annotation).new) << parse_annotation
        skip_space_or_newline
      end

      if @token.type.op_amp?
        next_token
        space_after_amp = @token.type.space?
        skip_space_or_newline

        if @token.type.op_colon? && !space_after_amp # anonymous block arg without space
          warnings.add_warning_at @token.location, "space required before colon in type restriction (run `crystal tool format` to fix this)"
        end

        block_param = parse_def_block_param(extra_assigns, annotations)
        skip_space_or_newline
        # When block_param.name is empty, this is an anonymous parameter.
        # An anonymous parameter should not conflict other parameters names.
        # (In fact `params` may contain anonymous splat parameter. See #9108).
        # So check is skipped.
        unless block_param.name.empty?
          conflict_param = params.any?(&.name.==(block_param.name))
          conflict_double_splat = found_double_splat && found_double_splat.name == block_param.name
          if conflict_param || conflict_double_splat
            raise "duplicated def parameter name: #{block_param.name}", block_param.location.not_nil!
          end
        end
        return ArgExtras.new(block_param, false, false, false)
      end

      if found_double_splat
        raise "only block parameter is allowed after double splat"
      end

      splat = false
      double_splat = false
      param_location = @token.location
      allow_external_name = true

      case @token.type
      when .op_star?
        if found_splat
          unexpected_token
        end

        splat = true
        allow_external_name = false
        next_token_skip_space
      when .op_star_star?
        double_splat = true
        allow_external_name = false
        next_token_skip_space
      else
        # not a splat
      end

      found_space = false

      if splat && (@token.type.op_comma? || @token.type.op_rparen?)
        param_name = ""
        allow_restrictions = false
      else
        param_location = @token.location
        param_name, external_name, found_space, _uses_param = parse_param_name(param_location, extra_assigns, allow_external_name: allow_external_name)

        params.each do |param|
          if param.name == param_name
            raise "duplicated def parameter name: #{param_name}", param_location
          end

          if param.external_name == external_name
            raise "duplicated def parameter external name: #{external_name}", param_location
          end
        end

        if @token.type.symbol?
          raise "space required after colon in type restriction", @token
        end
      end

      default_value = nil
      restriction = nil

      found_colon = false

      if allow_restrictions && @token.type.op_colon?
        if !default_value && !found_space
          raise "space required before colon in type restriction", @token
        end

        next_token_skip_space_or_newline

        location = @token.location
        splat_restriction = false
        if (splat && @token.type.op_star?) || (double_splat && @token.type.op_star_star?)
          splat_restriction = true
          next_token
        end

        restriction = parse_bare_proc_type

        if splat_restriction
          restriction = splat ? Splat.new(restriction) : DoubleSplat.new(restriction)
          restriction.at(location)
        end
        found_colon = true
      end

      if @token.type.op_eq?
        raise "splat parameter can't have default value", @token if splat
        raise "double splat parameter can't have default value", @token if double_splat

        slash_is_regex!
        next_token_skip_space_or_newline

        case @token.type
        when .magic?
          default_value = MagicConstant.new(@token.type).at(@token.location)
          next_token
        else
          @no_type_declaration += 1
          default_value = parse_op_assign
          @no_type_declaration -= 1
        end

        skip_space
      else
        if found_default_value && !found_splat && !splat && !double_splat
          raise "parameter must have a default value", param_location
        end
      end

      unless found_colon
        if @token.type.symbol?
          raise "the syntax for a parameter with a default value V and type T is `param : T = V`", @token
        end

        if allow_restrictions && @token.type.op_colon?
          raise "the syntax for a parameter with a default value V and type T is `param : T = V`", @token
        end
      end

      raise "BUG: param_name is nil" unless param_name

      param = Arg.new(param_name, default_value, restriction, external_name: external_name, parsed_annotations: annotations).at(param_location)
      params << param
      push_var param

      ArgExtras.new(nil, !!default_value, splat, !!double_splat)
    end

    def parse_def_block_param(extra_assigns, annotations : Array(Annotation)?)
      name_location = @token.location

      if @token.type.op_rparen? || @token.type.newline? || @token.type.op_colon?
        param_name = ""
      else
        param_name, _external_name, found_space, uses_param = parse_param_name(name_location, extra_assigns, allow_external_name: false)
        @uses_block_arg = true if uses_param
      end

      if @token.type.op_colon?
        unless param_name.empty? || found_space
          warnings.add_warning_at @token.location, "space required before colon in type restriction (run `crystal tool format` to fix this)"
        end
        next_token_skip_space_or_newline

        location = @token.location

        type_spec = parse_bare_proc_type
      end

      block_param = Arg.new(param_name, restriction: type_spec, parsed_annotations: annotations).at(name_location)

      push_var block_param

      @block_arg_name = block_param.name

      block_param
    end

    def parse_param_name(location, extra_assigns, allow_external_name)
      do_next_token = true
      found_string_literal = false
      invalid_internal_name = nil
      external_name_token = nil

      if allow_external_name && (@token.type.ident? || string_literal_start?)
        name_location = @token.location
        external_name_token = @token.dup
        if @token.type.ident?
          if @token.keyword? && invalid_internal_name?(@token.value)
            invalid_internal_name = @token.dup
          end
          external_name = @token.value.to_s
          next_token
        else
          external_name = parse_string_without_interpolation("external name")
          found_string_literal = true
        end

        if external_name.empty?
          raise "external parameter name cannot be empty", name_location
        end

        found_space = @token.type.space? || @token.type.newline?
        skip_space
        do_next_token = false
      end

      case @token.type
      when .ident?
        if @token.keyword? && invalid_internal_name?(@token.value)
          raise "cannot use '#{@token}' as a parameter name", @token
        end

        param_name = @token.value.to_s
        if param_name == external_name
          raise "when specified, external name must be different than internal name", @token
        end

        check_valid_param_name

        uses_param = false
        do_next_token = true
      when .instance_var?
        # Transform `def foo(@x); end` to `def foo(x); @x = x; end`
        param_name = @token.value.to_s[1..-1]
        if param_name == external_name
          raise "when specified, external name must be different than internal name", @token
        end

        # If it's something like @select, we can't transform it to:
        #
        #     @select = select
        #
        # because if someone uses `to_s` later it will produce invalid code.
        # So we do something like:
        #
        # def method(select __arg0)
        #   @select = __arg0
        # end
        #
        # The external name defaults to the internal one unless otherwise
        # specified (i.e. `def method(foo @select)`).
        if invalid_internal_name?(param_name)
          external_name ||= param_name
          param_name = temp_arg_name
        end

        ivar = InstanceVar.new(@token.value.to_s).at(location)
        var = Var.new(param_name).at(location)
        assign = Assign.new(ivar, var).at(location)
        if extra_assigns
          extra_assigns.push assign
        else
          raise "can't use @instance_variable here"
        end
        uses_param = true
        do_next_token = true
      when .class_var?
        param_name = @token.value.to_s[2..-1]
        if param_name == external_name
          raise "when specified, external name must be different than internal name", @token
        end

        # Same case as :INSTANCE_VAR for things like @select
        if invalid_internal_name?(param_name)
          external_name ||= param_name
          param_name = temp_arg_name
        end

        cvar = ClassVar.new(@token.value.to_s).at(location)
        var = Var.new(param_name).at(location)
        assign = Assign.new(cvar, var).at(location)
        if extra_assigns
          extra_assigns.push assign
        else
          raise "can't use @@class_var here"
        end
        uses_param = true
        do_next_token = true
      else
        if external_name
          if found_string_literal
            unexpected_token "expected parameter internal name"
          end
          if invalid_internal_name
            raise "cannot use '#{invalid_internal_name}' as a parameter name", invalid_internal_name
          end
          param_name = external_name
          if external_name_token.nil?
            raise "missing external name token"
          end
          check_valid_param_name(external_name_token)
        else
          unexpected_token
        end
      end

      if do_next_token
        next_token
        found_space = @token.type.space? || @token.type.newline?
      end

      skip_space

      {param_name, external_name, found_space, uses_param}
    end

    def invalid_internal_name?(keyword)
      case keyword
      when Keyword
        case keyword
        # These names are handled as keyword by `Parser#parse_atomic_without_location`.
        # We cannot assign value into them and never reference them,
        # so they are invalid internal name.
        when .begin?, Keyword::NIL, .true?, .false?, .yield?, .with?, .abstract?,
             .def?, .macro?, .require?, .case?, .select?, .if?, .unless?, .include?,
             .extend?, .class?, .struct?, .module?, .enum?, .while?, .until?, .return?,
             .next?, .break?, .lib?, .fun?, .alias?, .pointerof?, .sizeof?, .offsetof?,
             .instance_sizeof?, .typeof?, .private?, .protected?, .asm?, .out?,
             .self?, Keyword::IN, .end?, .alignof?, .instance_alignof?
          true
        else
          false
        end
      when String
        case keyword
        when "begin", "nil", "true", "false", "yield", "with", "abstract",
             "def", "macro", "require", "case", "select", "if", "unless", "include",
             "extend", "class", "struct", "module", "enum", "while", "until", "return",
             "next", "break", "lib", "fun", "alias", "pointerof", "sizeof", "offsetof",
             "instance_sizeof", "typeof", "private", "protected", "asm", "out",
             "self", "in", "end", "alignof", "instance_alignof"
          true
        else
          false
        end
      else
        false
      end
    end

    def check_valid_param_name(token : Token = @token)
      param_name = token.value.to_s
      if param_name[-1]?.in?('?', '!')
        warnings.add_warning_at(token.location, "invalid parameter name: #{param_name}")
      end
    end

    def parse_if(check_end = true)
      location = @token.location

      slash_is_regex!
      next_token_skip_space_or_newline

      cond = parse_op_assign_no_control allow_suffix: false
      parse_if_after_condition cond, location, check_end
    end

    def parse_if_after_condition(cond, location, check_end)
      iyi_opened "if", location if check_end
      slash_is_regex!
      skip_statement_end

      a_then = parse_expressions
      skip_statement_end

      else_location = nil
      a_else = nil
      if @token.type.ident?
        case @token.value
        when Keyword::ELSE
          else_location = @token.location
          next_token_skip_space
          if iyi? && @token.keyword?(:if) && @token.line_number == else_location.try(&.line_number)
            @iyi_else_if = @token.location
          end
          skip_statement_end
          a_else = parse_expressions
        when Keyword::ELSIF
          else_location = @token.location
          a_else = parse_if check_end: false
        end
      end

      end_location = token_end_location
      if check_end
        check_ident :end
        iyi_closed
        next_token_skip_space
      end

      node = If.new(cond, a_then, a_else).at(location).at_end(end_location)
      node.else_location = else_location
      node
    end

    def parse_unless
      location = @token.location

      slash_is_regex!
      next_token_skip_space_or_newline

      cond = parse_op_assign_no_control allow_suffix: false
      parse_unless_after_condition(cond, location)
    end

    def parse_unless_after_condition(cond, location)
      iyi_opened "unless", location
      slash_is_regex!
      skip_statement_end

      a_then = parse_expressions
      skip_statement_end

      a_else = nil
      if @token.keyword?(:else)
        else_location = @token.location
        next_token_skip_statement_end
        a_else = parse_expressions
      end

      check_ident :end
      iyi_closed
      end_location = token_end_location
      next_token_skip_space

      node = Unless.new(cond, a_then, a_else).at(location).at_end(end_location)
      node.else_location = else_location
      node
    end

    def set_visibility(node)
      if visibility = @visibility
        node.visibility = visibility
      end
      node
    end

    def parse_var_or_call(global = false, force_call = false, location = @token.location)
      end_location = token_end_location
      doc = @token.doc

      check AtomicWithMethodCheck

      if @token.type.op_bang?
        # only trigger from `parse_when_expression`
        obj = Var.new("self").at(location)
        return parse_negation_suffix(obj)
      end

      case @token.value
      when Keyword::IS_A_QUESTION
        obj = Var.new("self").at(location)
        return parse_is_a(obj)
      when Keyword::AS
        obj = Var.new("self").at(location)
        return parse_as(obj)
      when Keyword::AS_QUESTION
        obj = Var.new("self").at(location)
        return parse_as?(obj)
      when Keyword::RESPONDS_TO_QUESTION
        obj = Var.new("self").at(location)
        return parse_responds_to(obj)
      when Keyword::NIL_QUESTION
        unless @in_macro_expression
          obj = Var.new("self").at(location)
          return parse_nil?(obj)
        end
      else
        # Not a special call, go on
      end

      name = @token.value.to_s
      name_location = @token.location

      if force_call && !@token.value
        name = @token.type.to_s
      end

      is_var = var?(name)

      # If the name is a var and '+' or '-' follow, never treat the name as a call
      if is_var && next_comes_plus_or_minus?
        var = Var.new(name)
        var.doc = doc
        var.location = name_location
        var.end_location = end_location
        next_token
        return var
      end

      @wants_regex = false
      # Some keyword tokens (e.g. `self`, `super`) early-return from the
      # lexer without resetting `@slash_is_regex`, so it can persist from
      # an earlier `slash_is_regex!` and make `self/2` or `super/2` lex
      # as a regex. The atomic we've just parsed is a value, so the next
      # `/` is always division.
      slash_is_not_regex!
      next_token

      name_followed_by_space = @token.type.space?
      if name_followed_by_space
        # We don't want the next token to be a regex literal if the call's name is
        # a variable in the current scope (it's unlikely that there will be a method
        # with that name that accepts a regex as a first argument).
        # This allows us to write: a = 1; b = 2; a /b
        @wants_regex = !is_var
      end

      case name
      when "super"
        @calls_super = true
      when "initialize"
        @calls_initialize = true
      when "previous_def"
        @calls_previous_def = true
      else
        # Not a special call
      end

      call_args = preserve_stop_on_do(@stop_on_do) { parse_call_args stop_on_do_after_space: @stop_on_do }

      if call_args
        args = call_args.args
        block = call_args.block
        block_arg = call_args.block_arg
        named_args = call_args.named_args
        has_parentheses = call_args.has_parentheses
        force_call ||= has_parentheses || (args.try(&.empty?) == false) || (named_args.try(&.empty?) == false)
        # iyi: `fn f(x : Int32)` is a call to `fn` with a call for its
        # argument, and parses; what fails is the `: Int32` after it or
        # the `end` under it, and the sentence for either names this.
        if !is_var && !has_parentheses && name.in?("fn", "func", "function") && args.try(&.first?).is_a?(Call) && @iyi_def_lookalike.nil?
          @iyi_def_lookalike = {name, name_location}
        end

        # iyi: `for i in 0..3` is a call to `for` with a variable for its
        # argument, and the `in` after it is a keyword `case` owns.
        if !is_var && !has_parentheses && name == "for" && args.try(&.first?).is_a?(Var | Call) &&
           @iyi_for_lookalike.nil?
          @iyi_for_lookalike = {name, name_location}
        end

        # iyi: `const LIMIT = 10` is a call to `const` whose argument is an
        # assignment to a constant, so it parses, and the answer it drew
        # was the semantic's `can't declare constant dynamically` — true of
        # the shape and silent about the word. `pub const LIMIT = 10` drew
        # "can't apply `pub` to const", which reads as if `const` were a
        # thing here. Every other arrival from another language is met with
        # this one's spelling (`IYI_ARRIVAL_CALL_HINTS`), and these five
        # words are what introduces a constant in the languages people come
        # from. The shape is checked too, so a call to something actually
        # named `const` is still a call.
        if !is_var && !has_parentheses && name.in?("const", "val", "final", "let", "var") &&
           (assignment = args.try(&.first?)).is_a?(Assign) && (constant = assignment.target).is_a?(Path)
          raise "there is no `#{name}`: a constant is `#{constant} = ...`, " \
                "uppercase is what makes it one, and `pub #{constant} = ...` " \
                "is how a module exports it (SPEC.md R-2)", name_location
        end
      else
        has_parentheses = false
      end

      if call_args && call_args.stopped_on_do_after_space
        # This is the case when we have:
        #
        #     x = 1
        #     foo x do
        #         ^~~~
        #     end
        #
        # In this case, since x is a variable and the previous call (foo)
        # doesn't have parentheses, we don't parse "x do end" as an invocation
        # to a method x with a block. Instead, we just stop on x and we don't
        # consume the block, leaving the block for 'foo' to consume.
        block = parse_curly_block(block)
      elsif @stop_on_do && call_args && call_args.has_parentheses
        # This is the case when we have:
        #
        #    foo x(y) do
        #        ^~~~~~~
        #    end
        #
        # We don't want to attach the block to `x`, but to `foo`.
        block = parse_curly_block(block)
      else
        block = parse_block(block)
      end

      if block && block_arg
        raise "can't use captured and non-captured blocks together", location
      end

      node =
        if block || block_arg || global
          call = Call.new(name, (args || [] of ASTNode), block, block_arg, named_args, global)
          call.name_location = name_location
          call.has_parentheses = has_parentheses
          # iyi: `group do ... end` is compiler-known (SPEC.md III.4.9) —
          # the typed expansion needs to know this is *the* group, not a
          # method sharing the name; recognising it here is what makes
          # `group` a reserved name in an iyi file, and only there.
          call.iyi_group = true if iyi? && name == "group" && block && !global && (args.nil? || args.empty?)
          call
        else
          if args
            maybe_var = !force_call && is_var
            if maybe_var
              Var.new(name)
            else
              call = Call.new(name, args, nil, nil, named_args, global)
              call.name_location = name_location
              call.has_parentheses = has_parentheses
              call
            end
          else
            if @no_type_declaration == 0 && @token.type.op_colon?
              unless name_followed_by_space
                warnings.add_warning_at(@token.location, "space required before colon in type declaration (run `crystal tool format` to fix this)")
              end
              declare_var = parse_type_declaration(Var.new(name).at(location).at_end(end_location))
              end_location = declare_var.end_location

              # Don't declare a local variable if it happens directly as an argument
              # of a call, like `property foo : Int32` (we don't want `foo` to be a
              # local variable afterwards.)
              push_var declare_var unless @call_args_start_locations.includes?(location)
              declare_var
            elsif (!force_call && is_var)
              if @block_arg_name && !@uses_block_arg && name == @block_arg_name
                @uses_block_arg = true
              end
              Var.new(name)
            else
              if !force_call && !named_args && !global && @assigned_vars.includes?(name)
                raise "can't use variable name '#{name}' inside assignment to variable '#{name}'", location
              end

              call = Call.new(name, [] of ASTNode, nil, nil, named_args, global)
              call.name_location = name_location
              call.has_parentheses = has_parentheses
              call
            end
          end
        end
      node.doc = doc
      node.location = location
      node.end_location = block.try(&.end_location) || call_args.try(&.end_location) || end_location
      node
    end

    def next_comes_plus_or_minus?
      pos = current_pos
      while current_char.ascii_whitespace?
        next_char_no_column_increment
      end
      comes_plus_or_minus = current_char.in?('+', '-')
      self.current_pos = pos
      comes_plus_or_minus
    end

    def preserve_stop_on_do(new_value = false, &)
      old_stop_on_do = @stop_on_do
      @stop_on_do = new_value
      value = yield
      @stop_on_do = old_stop_on_do
      value
    end

    def parse_block(block, stop_on_do = false)
      if @token.keyword?(:do)
        return block if stop_on_do

        raise "block already specified with &" if block
        parse_block2 do |body|
          body, end_location, _ = parse_exception_handler body, implicit: true
          {body, end_location}
        end
      else
        parse_curly_block(block)
      end
    end

    def parse_curly_block(block)
      if @token.type.op_lcurly?
        raise "block already specified with &" if block
        parse_block2 do |body|
          check :OP_RCURLY
          end_location = token_end_location
          slash_is_not_regex!
          @wants_regex = false
          next_token_skip_space
          {body, end_location}
        end
      else
        block
      end
    end

    def parse_block2(&)
      location = @token.location
      block_params, splat_index, unpacks = parse_block_params(location)

      with_lexical_var_scope do
        push_vars block_params

        unpacks.try &.each do |index, expressions|
          push_block_vars(expressions)
        end

        block_body = parse_expressions
        block_body, end_location = yield block_body

        Block.new(block_params, block_body, splat_index, unpacks).at(location).at_end(end_location)
      end
    end

    def parse_block_params(location)
      block_params = [] of Var
      all_names = [] of String
      param_index = 0
      splat_index = nil
      unpacks = nil

      slash_is_regex!
      next_token_skip_space
      if @token.type.op_bar?
        next_token_skip_space_or_newline
        while true
          var, found_splat, unpack_expressions = parse_block_param(
            found_splat: !!splat_index,
            all_names: all_names,
          )
          splat_index ||= param_index if found_splat
          block_params << var

          if unpack_expressions
            unpacks ||= {} of Int32 => Expressions
            unpacks[param_index] = Expressions.new(unpack_expressions)
          end

          next_token_skip_space_or_newline

          case @token.type
          when .op_comma?
            next_token_skip_space_or_newline
            break if @token.type.op_bar?
          when .op_bar?
            break
          else
            raise "expecting ',' or '|', not #{@token}", @token
          end

          param_index += 1
        end
        next_token_skip_statement_end
      else
        skip_statement_end
      end

      {block_params, splat_index, unpacks}
    end

    def parse_block_param(found_splat, all_names : Array(String))
      if @token.type.op_star?
        if found_splat
          raise "splat block parameter already specified", @token
        end
        found_splat = true
        next_token
      end

      location = @token.location

      case @token.type
      when .ident?
        if @token.keyword? && invalid_internal_name?(@token.value)
          raise "cannot use '#{@token}' as a block parameter name", @token
        end

        param_name = @token.value.to_s
        check_valid_param_name

        if all_names.includes?(param_name)
          raise "duplicated block parameter name: #{param_name}", @token
        end
        all_names << param_name
      when .underscore?
        param_name = "_"
      when .op_lparen?
        next_token_skip_space_or_newline

        unpack_expressions = [] of ASTNode
        found_splat_in_nested_expression = false

        while true
          sub_location = @token.location
          sub_var, new_found_splat_in_nested_expression, sub_unpack_expressions = parse_block_param(
            found_splat: found_splat_in_nested_expression,
            all_names: all_names,
          )

          unpack_expression =
            if sub_unpack_expressions
              Expressions.new(sub_unpack_expressions).at(sub_location)
            elsif sub_var.name == "_"
              Underscore.new.at(sub_location)
            else
              sub_var
            end

          if new_found_splat_in_nested_expression && !found_splat_in_nested_expression
            unpack_expression = Splat.new(unpack_expression).at(sub_location)
          end
          found_splat_in_nested_expression = new_found_splat_in_nested_expression

          unpack_expressions << unpack_expression

          next_token_skip_space_or_newline
          case @token.type
          when .op_comma?
            next_token_skip_space_or_newline
            break if @token.type.op_rparen?
          when .op_rparen?
            break
          else
            raise "expecting ',' or ')', not #{@token}", @token
          end
        end

        param_name = ""
      else
        raise "expecting block parameter name, not #{@token.type}", @token
      end

      var = Var.new(param_name).at(location)
      {var, found_splat, unpack_expressions}
    end

    def push_block_vars(node)
      case node
      when Expressions
        node.expressions.each do |expression|
          push_block_vars(expression)
        end
      when Var
        push_var node
      when Underscore
        # Nothing to do
      when Splat
        push_block_vars(node.exp)
      else
        raise "BUG: unexpected block var: #{node} (#{node.class})"
      end
    end

    record CallArgs,
      args : Array(ASTNode)?,
      block : Block?,
      block_arg : ASTNode?,
      named_args : Array(NamedArgument)?,
      stopped_on_do_after_space : Bool,
      end_location : Location?,
      has_parentheses : Bool

    def parse_call_args(stop_on_do_after_space = false, allow_curly = false, control = false)
      case @token.type
      when .op_lcurly?
        nil
      when .op_lparen?
        slash_is_regex!

        args = [] of ASTNode
        end_location = nil

        open("call") do
          # We found a parentheses, so calls inside it will get the `do`
          # attached to them
          @stop_on_do = false
          found_double_splat = false

          next_token_skip_space_or_newline
          while !@token.type.op_rparen?
            if call_block_arg_follows?
              return parse_call_block_arg(args, true)
            end

            if named_tuple_start?
              return parse_call_args_named_args(@token.location, args, first_name: nil, allow_newline: true)
            else
              arg = parse_call_arg(found_double_splat)
              if @token.type.op_colon? && arg.is_a?(StringLiteral)
                return parse_call_args_named_args(arg.location.not_nil!, args, first_name: arg.value, allow_newline: true)
              else
                args << arg
                found_double_splat = arg.is_a?(DoubleSplat)
              end
            end

            skip_space
            if @token.type.op_comma?
              slash_is_regex!
              next_token_skip_space_or_newline
            else
              skip_space_or_newline
              check :OP_RPAREN
              break
            end
          end
          end_location = token_end_location
          @wants_regex = false
          next_token_skip_space
        end

        CallArgs.new args, nil, nil, nil, false, end_location, has_parentheses: true
      when .space?
        slash_is_not_regex!
        end_location = token_end_location
        next_token

        if stop_on_do_after_space && @token.keyword?(:do)
          return CallArgs.new nil, nil, nil, nil, true, end_location, has_parentheses: false
        end

        if control && @token.keyword?(:do)
          unexpected_token
        end

        parse_call_args_space_consumed check_plus_and_minus: true, allow_curly: allow_curly, control: control
      else
        nil
      end
    end

    def parse_call_args_space_consumed(check_plus_and_minus = true, allow_curly = false, control = false, end_token : Token::Kind = :OP_RPAREN,
                                       allow_beginless_range = false)
      if @token.keyword?(:end) && !next_comes_colon_space?
        return nil
      end

      case @token.type
      when .op_amp?
        return nil if current_char.ascii_whitespace?
      when .op_plus?, .op_minus?
        if check_plus_and_minus
          return nil if current_char.ascii_whitespace?
        end
      when .op_lcurly?
        return nil unless allow_curly
      when .char?, .string?, .delimiter_start?, .string_array_start?, .symbol_array_start?,
           .number?, .ident?, .symbol?, .instance_var?, .class_var?, .const?, .global?,
           .op_dollar_tilde?, .op_dollar_question?, .global_match_data_index?, .op_lparen?,
           .op_bang?, .op_lsquare?, .op_lsquare_rsquare?, .op_tilde?, .op_minus_gt?,
           .op_lcurly_lcurly?, .magic?, .underscore?
        # Nothing
      when .op_star?, .op_star_star?
        if current_char.ascii_whitespace?
          return nil
        end
      when .op_colon_colon?
        if current_char.ascii_whitespace?
          return nil
        end
      when .op_period_period?, .op_period_period_period?
        return nil unless allow_beginless_range
      else
        return nil
      end

      case @token.value
      when Keyword::IF, Keyword::UNLESS, Keyword::WHILE, Keyword::UNTIL, Keyword::RESCUE, Keyword::ENSURE
        return nil unless next_comes_colon_space?
      when Keyword::YIELD
        return nil if @stop_on_yield > 0 && !next_comes_colon_space?
      else
        # keep going
      end

      args = [] of ASTNode
      end_location = nil

      # On calls without parentheses we want to stop on `do`.
      # The exception is when parsing `return`, `break`, `yield`
      # and `next` arguments (marked with the `control` flag),
      # because this:
      #
      # ```
      # return foo do
      # end
      # ```
      #
      # must always be parsed as the block belonging to `foo`,
      # never to `return`.
      @stop_on_do = true unless control

      found_double_splat = false

      while !@token.type.newline? && !@token.type.op_semicolon? && !@token.type.eof? && @token.type != end_token && !@token.type.op_colon? && !end_token?
        if call_block_arg_follows?
          return parse_call_block_arg(args, false)
        end

        if @token.type.ident? && current_char == ':'
          return parse_call_args_named_args(@token.location, args, first_name: nil, allow_newline: false)
        else
          arg = parse_call_arg(found_double_splat)
          if @token.type.op_colon? && arg.is_a?(StringLiteral)
            return parse_call_args_named_args(arg.location.not_nil!, args, first_name: arg.value, allow_newline: false)
          else
            args << arg
            found_double_splat = arg.is_a?(DoubleSplat)
          end
          end_location = arg.end_location
        end

        skip_space

        if @token.type.op_comma?
          location = @token.location
          slash_is_regex!
          next_token_skip_space_or_newline
          raise "invalid trailing comma in call", location if (@token.keyword?(:end) && !next_comes_colon_space?) || @token.type.eof?
        else
          break
        end
      end

      CallArgs.new args, nil, nil, nil, false, end_location, has_parentheses: false
    end

    def parse_call_args_named_args(location, args, first_name, allow_newline)
      named_args = parse_named_args(location, first_name: first_name, allow_newline: allow_newline)

      if call_block_arg_follows?
        return parse_call_block_arg(args, check_paren: allow_newline, named_args: named_args)
      end

      check :OP_RPAREN if allow_newline

      # Prefer the end location of the last named argument when available.
      # Using `token_end_location` would produce an off-by-one column
      # in some cases (see issue #16092).
      end_location = named_args.last?.try(&.end_location) unless allow_newline
      end_location ||= token_end_location

      if allow_newline
        next_token_skip_space
      else
        skip_space
      end
      CallArgs.new args, nil, nil, named_args, false, end_location, has_parentheses: allow_newline
    end

    def parse_named_args(location, first_name = nil, allow_newline = false)
      named_args = [] of NamedArgument
      while true
        if first_name
          name = first_name
          first_name = nil
        else
          if named_tuple_start?
            name = @token.value.to_s
            next_token_never_a_symbol
          elsif string_literal_start?
            name = parse_string_without_interpolation("named argument")
          else
            raise "expected named argument, not #{@token}", location
          end
        end

        if name.empty?
          raise "named argument cannot have an empty name", location
        end

        if named_args.any? { |arg| arg.name == name }
          raise "duplicated named argument: #{name}", location
        end

        check :OP_COLON
        slash_is_regex!
        next_token_skip_space_or_newline

        if @token.keyword?(:out)
          value = parse_out
        else
          @call_args_start_locations << @token.location
          value =
            begin
              parse_op_assign
            ensure
              @call_args_start_locations.pop
            end
        end

        named_args << NamedArgument.new(name, value).at(location)
        skip_space
        if @token.type.op_comma?
          next_token_skip_space_or_newline
          if @token.type.op_rparen? || @token.type.op_amp? || @token.type.op_rsquare?
            break
          end
        elsif @token.type.newline? && allow_newline
          skip_space_or_newline
          break
        else
          break
        end

        location = @token.location
      end
      named_args
    end

    def parse_call_arg(found_double_splat = false)
      @call_args_start_locations.push @token.location

      if @token.keyword?(:out)
        if found_double_splat
          raise "out argument not allowed after double splat"
        end

        parse_out
      else
        location = @token.location
        splat = nil
        case @token.type
        when .op_star?
          unless current_char.ascii_whitespace?
            if found_double_splat
              raise "splat not allowed after double splat"
            end

            splat = :single
            next_token
          end
        when .op_star_star?
          unless current_char.ascii_whitespace?
            splat = :double
            next_token
          end
        else
          # not a splat
        end

        arg = parse_op_assign_no_control

        if found_double_splat && splat != :double
          raise "argument not allowed after double splat", arg.location.not_nil!
        end

        case splat
        when :single
          arg = Splat.new(arg).at(location).at_end(arg)
        when :double
          arg = DoubleSplat.new(arg).at(location).at_end(arg)
        else
          # no splat
        end

        arg
      end
    ensure
      @call_args_start_locations.pop
    end

    def parse_out
      location = @token.location
      next_token_skip_space_or_newline
      name = @token.value.to_s

      case @token.type
      when .ident?
        var = Var.new(name)
        push_var var
      when .instance_var?
        var = InstanceVar.new(name)
      when .underscore?
        var = Underscore.new
      else
        raise "expecting variable or instance variable after out"
      end
      var.at(@token.location).at_end(token_end_location)
      next_token
      Out.new(var).at(location).at_end(var)
    end

    def parse_generic_or_global_call
      location = @token.location
      next_token_skip_space_or_newline

      case @token.type
      when .ident?
        set_visibility parse_var_or_call global: true, location: location
      when .const?
        parse_const global: true, location: location
      else
        unexpected_token
      end
    end

    # Parse a **bare** proc type like `A, B, C -> D`.
    # Generally it is entry point of type parsing and
    # it is used on the context expected type (e.g. type restrictions, rhs of `alias` and more)
    def parse_bare_proc_type
      type = parse_type_splat { parse_union_type }

      # To determine to consume comma, looking-ahead is needed.
      # Consider `[ [] of Int32, Foo.new ]`, we want to parse it as `[ ([] of Int32), Foo.new ]` of course.
      # If the parser consumes comma after Int32 quickly, it may cause parsing error.
      unless @token.type.op_minus_gt? || (@token.type.op_comma? && type_start?(consume_newlines: true))
        if type.is_a?(Splat)
          raise "invalid type splat", type.location.not_nil!
        end
        return type
      end

      input_types = [type]
      if !@token.type.op_minus_gt?
        loop do
          next_token_skip_space_or_newline
          input_types << parse_type_splat { parse_union_type }
          break unless @token.type.op_comma? && type_start?(consume_newlines: true)
        end
      end

      parse_proc_type_output(input_types, input_types.first.location)
    end

    def parse_union_type
      type = parse_atomic_type_with_suffix
      return type unless @token.type.op_bar?

      types = [type]
      while @token.type.op_bar?
        next_token_skip_space_or_newline
        types << parse_atomic_type_with_suffix
      end

      Union.new(types).at(type).at_end(types.last)
    end

    def parse_atomic_type_with_suffix
      type = parse_atomic_type
      parse_type_suffix type
    end

    def parse_atomic_type
      location = @token.location

      case @token.type
      when .ident?
        case @token.value
        when Keyword::SELF
          next_token_skip_space
          Self.new.at(location)
        when "self?"
          next_token_skip_space
          make_nilable_type Self.new.at(location)
        when Keyword::TYPEOF
          parse_typeof
        else
          # iyi: `int32`, `string`, `bool` where a type goes are another
          # language's spelling of a name this one capitalises.
          if iyi? && (proper = IYI_TYPE_SPELLINGS[@token.value.to_s]?)
            raise "unexpected token: #{@token.to_s.inspect}: a type name is capitalised here - `#{proper}`", @token
          end
          unexpected_token
        end
      when .underscore?
        next_token_skip_space
        Underscore.new.at(location)
      when .const?, .op_colon_colon?
        type = parse_generic
        skip_space
        type
      when .op_lcurly?
        next_token_skip_space_or_newline
        if named_tuple_start? || @token.type.delimiter_start?
          type = make_named_tuple_type parse_named_type_args(:OP_RCURLY)
        else
          type = make_tuple_type parse_union_types(:OP_RCURLY, allow_splats: true)
        end
        check :OP_RCURLY
        end_location = token_end_location
        next_token_skip_space
        type.at(location).at_end(end_location)
      when .op_minus_gt?
        parse_proc_type_output(nil, location)
      when .op_lparen?
        next_token_skip_space_or_newline
        if @token.type.op_rparen?
          # ProcNotation without argument types: `() ->`
          next_token_skip_space
          check :OP_MINUS_GT
          return parse_proc_type_output([] of ASTNode, location)
        end

        type = parse_type_splat { parse_union_type }
        if @token.type.op_rparen?
          end_location = @token.location
          next_token_skip_space
          if @token.type.op_minus_gt? # `(A) -> B` case
            type = parse_proc_type_output([type] of ASTNode, location)
          elsif type.is_a?(Splat)
            raise "invalid type splat", type.location.not_nil!
          else
            type = Union.parens(type).at(location).at_end(end_location)
          end
        else
          input_types = [type]
          while @token.type.op_comma?
            next_token_skip_space_or_newline
            break if @token.type.op_rparen? # allow trailing comma
            input_types << parse_type_splat { parse_union_type }
          end
          if @token.type.op_minus_gt? # `(A, B, C -> D)` case
            type = parse_proc_type_output(input_types, input_types.first.location)
            check :OP_RPAREN
            next_token_skip_space
            unless @token.type.op_minus_gt?
              # Usually the parenthesis is encoded in a Union instance.
              # But not when nesting proc notations like `(->) ->`.
              type = Union.parens(type).at(type)
            end
          else # `(A, B, C) -> D` case
            check :OP_RPAREN
            next_token_skip_space
            type = parse_proc_type_output(input_types, location)
          end
        end
        type
      else
        unexpected_token
      end
    end

    def parse_union_types(end_token : Token::Kind, *, allow_splats = false)
      type = allow_splats ? parse_type_splat { parse_union_type } : parse_union_type
      types = [type]

      while @token.type.op_comma?
        next_token_skip_space_or_newline
        break if @token.type == end_token # allow trailing comma
        type = allow_splats ? parse_type_splat { parse_union_type } : parse_union_type
        types << type
      end

      types
    end

    # Parse generic type path like `A::B(C, D)?`.
    # This method is used to parse not only a type, but also an expression represents type.
    # And it also consumes prefix `::` to specify global path.
    def parse_generic(expression = false)
      location = @token.location

      global = false
      if @token.type.op_colon_colon?
        next_token_skip_space_or_newline
        global = true
      end

      parse_generic global, location, expression
    end

    def parse_generic(global, location, expression)
      path = parse_path(global, location)
      type = parse_type_args(path)

      # Nilable suffixes without any spaces are consumed here
      # for expression represents nilable type. Typically such an expression
      # is appeared in macro expression. (e.g. `{% if T <= Int32? %} ... {% end %}`)
      # Note that the parser cannot consume any spaces because it conflicts ternary operator.
      while expression && @token.type.op_question?
        end_location = token_end_location
        next_token
        type = make_nilable_expression(type).at_end(end_location)
      end

      type
    end

    # Parse type path.
    # It also consumes prefix `::` to specify global path.
    def parse_path
      location = @token.location

      global = false
      if @token.type.op_colon_colon?
        next_token_skip_space_or_newline
        global = true
      end

      parse_path(global, location)
    end

    def parse_path(global, location)
      names = [check_const]
      end_location = token_end_location

      @wants_regex = false
      next_token
      while @token.type.op_colon_colon?
        next_token_skip_space_or_newline
        names << check_const
        end_location = token_end_location

        @wants_regex = false
        next_token
      end

      Path.new(names, global).at(location).at_end(end_location)
    end

    def parse_type_args(name)
      return name unless @token.type.op_lparen?

      next_token_skip_space_or_newline
      args = [] of ASTNode
      if named_tuple_start? || string_literal_start?
        named_args = parse_named_type_args(:OP_RPAREN)
      elsif !@token.type.op_rparen?
        args << parse_type_splat { parse_type_arg }
        while @token.type.op_comma?
          next_token_skip_space_or_newline
          break if @token.type.op_rparen? # allow trailing comma
          args << parse_type_splat { parse_type_arg }
        end

        has_int = args.any? do |arg|
          arg.is_a?(NumberLiteral) || arg.is_a?(SizeOf) || arg.is_a?(InstanceSizeOf) ||
            arg.is_a?(AlignOf) || arg.is_a?(InstanceAlignOf) || arg.is_a?(OffsetOf)
        end

        if @token.type.op_minus_gt? && !has_int
          args = [parse_proc_type_output(args, args.first.location)] of ASTNode
        end
      end

      skip_space_or_newline
      check :OP_RPAREN
      end_location = token_end_location
      next_token

      Generic.new(name, args, named_args).at(name).at_end(end_location)
    end

    def parse_named_type_args(end_token : Token::Kind)
      named_args = [] of NamedArgument

      while @token.type != end_token
        name_location = @token.location
        if named_tuple_start?
          name = @token.value.to_s
          next_token
        elsif string_literal_start?
          name = parse_string_without_interpolation("named argument")
        else
          raise "expected '#{end_token}' or named argument, not #{@token}", @token
        end

        if name.empty?
          raise "named argument cannot have an empty name", name_location
        end

        if named_args.any? { |arg| arg.name == name }
          raise "duplicated key: #{name}", @token
        end

        check :OP_COLON
        next_token_skip_space_or_newline

        type = parse_bare_proc_type
        skip_space

        named_args << NamedArgument.new(name, type).at(name_location)

        if @token.type.op_comma?
          next_token_skip_space_or_newline
        else
          skip_space_or_newline
          check end_token
          break
        end
      end

      named_args
    end

    def parse_type_splat(&)
      location = @token.location

      splat = false
      if @token.type.op_star?
        next_token_skip_space_or_newline
        splat = true
      end

      type = yield
      type = Splat.new(type).at(location) if splat
      type
    end

    def parse_type_arg
      if @token.type.number?
        num = NumberLiteral.new(@token.value.to_s, @token.number_kind).at(@token.location)
        next_token_skip_space
        return num
      end

      case @token
      when .keyword?(:sizeof)
        parse_sizeof
      when .keyword?(:instance_sizeof)
        parse_instance_sizeof
      when .keyword?(:alignof)
        parse_alignof
      when .keyword?(:instance_alignof)
        parse_instance_alignof
      when .keyword?(:offsetof)
        parse_offsetof
      else
        parse_union_type
      end
    end

    def parse_type_suffix(type)
      loop do
        end_location = token_end_location
        case @token.type
        when .op_period?
          next_token_skip_space_or_newline
          check_ident :class
          end_location = token_end_location
          next_token_skip_space
          type = Metaclass.new(type).at(type).at_end(end_location)
        when .op_question?
          next_token_skip_space
          type = make_nilable_type(type).at_end(end_location)
        when .op_star?
          next_token_skip_space
          type = make_pointer_type(type).at_end(end_location)
        when .op_star_star?
          next_token_skip_space
          type = make_pointer_type(make_pointer_type(type)).at_end(end_location)
        when .op_lsquare?
          next_token_skip_space_or_newline
          size = parse_type_arg
          skip_space_or_newline
          check :OP_RSQUARE
          end_location = token_end_location
          next_token_skip_space
          type = make_static_array_type(type, size).at_end(end_location)
        else
          return type
        end
      end
    end

    def parse_proc_type_output(input_types, location)
      has_output_type = type_start?(consume_newlines: false)

      check :OP_MINUS_GT
      end_location = token_end_location
      next_token_skip_space

      if has_output_type
        skip_space_or_newline
        output_type = parse_union_type
        end_location = output_type.end_location
      end

      ProcNotation.new(input_types, output_type).at(location).at_end(end_location)
    end

    def make_nilable_type(type)
      Union.new([type, Path.global("Nil").at(type)]).at(type)
    end

    def make_nilable_expression(type)
      type = Generic.new(Path.global("Union").at(type), [type, Path.global("Nil").at(type)]).at(type)
      type.suffix = :question
      type
    end

    def make_pointer_type(type)
      type = Generic.new(Path.global("Pointer").at(type), [type] of ASTNode).at(type)
      type.suffix = :asterisk
      type
    end

    def make_static_array_type(type, size)
      type = Generic.new(Path.global("StaticArray").at(type), [type, size] of ASTNode).at(type)
      type.suffix = :bracket
      type
    end

    def make_tuple_type(types)
      Generic.new(Path.global("Tuple"), types)
    end

    def make_named_tuple_type(named_args)
      Generic.new(Path.global("NamedTuple"), [] of ASTNode, named_args: named_args)
    end

    # Looks ahead next tokens to check whether they indicate type.
    def type_start?(*, consume_newlines)
      peek_ahead do
        if consume_newlines
          next_token_skip_space_or_newline
        else
          next_token_skip_space
        end

        type_start?
      rescue
        false
      end
    end

    def type_start?
      while @token.type.op_lparen? || @token.type.op_lcurly?
        next_token_skip_space_or_newline
      end

      # TODO: the below conditions are not complete, and there are many false-positive or true-negative examples.

      case @token.type
      when .ident?
        return false if named_tuple_start?
        case @token.value
        when Keyword::TYPEOF
          true
        when Keyword::SELF, "self?"
          next_token_skip_space
          delimiter_or_type_suffix?
        else
          false
        end
      when .const?
        return false if named_tuple_start?
        type_path_start?
      when .op_colon_colon?
        next_token
        type_path_start?
      when .underscore?, .op_minus_gt?
        true
      when .op_star?
        next_token_skip_space_or_newline
        type_start?
      else
        false
      end
    end

    def type_path_start?
      while @token.type.const?
        next_token
        break unless @token.type.op_colon_colon?
        next_token_skip_space_or_newline
      end

      skip_space
      delimiter_or_type_suffix?
    end

    def delimiter_or_type_suffix?
      case @token.type
      when .op_period?
        next_token_skip_space_or_newline
        @token.keyword?(:class)
      when .op_question?, .op_star?, .op_star_star?
        # They are conflicted with operators, so more look-ahead is needed.
        next_token_skip_space
        delimiter_or_type_suffix?
      when .op_minus_gt?, .op_bar?, .op_comma?, .op_eq_gt?, .newline?, .eof?,
           .op_eq?, .op_semicolon?, .op_lparen?, .op_rparen?, .op_lsquare?, .op_rsquare?
        # -> | , => \n EOF = ; ( ) [ ]
        true
      else
        false
      end
    end

    def parse_typeof
      location = @token.location

      next_token_skip_space
      check :OP_LPAREN
      next_token_skip_space_or_newline
      if @token.type.op_rparen?
        raise "missing typeof argument"
      end

      with_lexical_var_scope do
        exps = [] of ASTNode
        while !@token.type.op_rparen?
          exps << parse_op_assign
          if @token.type.op_comma?
            next_token_skip_space_or_newline
          else
            skip_space_or_newline
            check :OP_RPAREN
          end
        end

        end_location = token_end_location
        next_token_skip_space

        TypeOf.new(exps).at(location).at_end(end_location)
      end
    end

    def parse_visibility_modifier(modifier)
      doc = @token.doc
      location = @token.location

      next_token_skip_space
      exp = parse_op_assign

      modifier = VisibilityModifier.new(modifier, exp).at(location)
      modifier.doc = doc
      exp.doc = doc
      modifier
    end

    def parse_asm
      next_token_skip_space
      check :OP_LPAREN
      next_token_skip_space_or_newline
      text = parse_string_without_interpolation("asm")
      skip_space_or_newline

      volatile = false
      alignstack = false
      intel = false
      can_throw = false

      part_index = 0
      until @token.type.op_rparen?
        if @token.type.op_colon_colon?
          next_token_skip_space_or_newline
          part_index += 2
        elsif @token.type.op_colon?
          next_token_skip_space_or_newline
          part_index += 1
        else
          unexpected_token
        end

        case part_index
        when 1
          if @token.type.delimiter_start?
            outputs = parse_asm_operands
          end
        when 2
          if @token.type.delimiter_start?
            inputs = parse_asm_operands
          end
        when 3
          if @token.type.delimiter_start?
            clobbers = parse_asm_clobbers
          end
        when 4
          if @token.type.delimiter_start?
            volatile, alignstack, intel, can_throw = parse_asm_options
          end
        else break
        end
      end

      check :OP_RPAREN

      end_location = token_end_location

      next_token_skip_space

      Asm.new(text, outputs, inputs, clobbers, volatile, alignstack, intel, can_throw).at_end(end_location)
    end

    def parse_asm_operands
      operands = [] of AsmOperand
      while true
        operands << parse_asm_operand
        if @token.type.op_comma?
          next_token_skip_space_or_newline
        end
        break unless @token.type.delimiter_start?
      end
      operands
    end

    def parse_asm_operand
      text = parse_string_without_interpolation("constraint")
      check :OP_LPAREN
      next_token_skip_space_or_newline
      exp = parse_expression
      check :OP_RPAREN
      next_token_skip_space_or_newline
      AsmOperand.new(text, exp)
    end

    def parse_asm_clobbers
      clobbers = [] of String
      while true
        clobbers << parse_string_without_interpolation("asm clobber")
        skip_space_or_newline
        if @token.type.op_comma?
          next_token_skip_space_or_newline
        end
        break unless @token.type.delimiter_start?
      end
      clobbers
    end

    def parse_asm_options
      volatile = false
      alignstack = false
      intel = false
      can_throw = false
      while true
        location = @token.location
        option = parse_string_without_interpolation("asm option")
        skip_space_or_newline
        case option
        when "volatile"
          volatile = true
        when "alignstack"
          alignstack = true
        when "intel"
          intel = true
        when "unwind"
          can_throw = true
        else
          raise "unknown asm option: #{option}", location
        end

        if @token.type.op_comma?
          next_token_skip_space_or_newline
        end
        break unless @token.type.delimiter_start?
      end
      {volatile, alignstack, intel, can_throw}
    end

    def parse_yield_with_scope
      location = @token.location
      next_token_skip_space
      @stop_on_yield += 1
      @block_arity ||= 1
      scope = parse_op_assign
      @stop_on_yield -= 1
      skip_space
      check_ident :yield
      parse_yield scope, location
    end

    def parse_yield(scope = nil, location = @token.location)
      end_location = token_end_location
      next_token

      call_args = preserve_stop_on_do { parse_call_args control: true }

      if call_args
        args = call_args.args
        end_location = nil
      end

      block_arity = (@block_arity ||= 0)
      if args && args.size > block_arity
        @block_arity = args.size
      end

      Yield.new(args || [] of ASTNode, scope, !!call_args.try(&.has_parentheses)).at(location).at_end(end_location)
    end

    def parse_break
      parse_control_expression Break
    end

    def parse_return
      parse_control_expression Return
    end

    def parse_next
      parse_control_expression Next
    end

    def parse_control_expression(klass)
      end_location = token_end_location
      next_token

      call_args = preserve_stop_on_do { parse_call_args allow_curly: true, control: true }
      args = call_args.args if call_args

      if args && !args.empty?
        if args.size == 1 && !args.first.is_a?(Splat)
          node = klass.new(args.first)
        else
          tuple = TupleLiteral.new(args).at(args.first).at_end(args.last)
          node = klass.new(tuple)
        end
      else
        node = klass.new.at_end(end_location)
      end

      node
    end

    def parse_lib
      doc = @token.doc
      location = @token.location
      next_token_skip_space_or_newline

      name_location = @token.location
      name = parse_path
      check StatementEnd
      skip_statement_end

      body = push_visibility { parse_lib_body_expressions }

      check_ident :end
      end_location = token_end_location
      next_token_skip_space

      lib_def = LibDef.new(name, body).at(location).at_end(end_location)
      lib_def.name_location = name_location
      lib_def.doc = doc
      lib_def
    end

    def parse_lib_body
      next_token_skip_statement_end
      Expressions.from(parse_lib_body_expressions)
    end

    private def parse_lib_body_expressions
      expressions = [] of ASTNode
      while true
        skip_statement_end
        break if end_token?
        expressions << parse_lib_body_exp
      end
      expressions
    end

    def parse_lib_body_exp
      location = @token.location
      parse_lib_body_exp_without_location.at(location)
    end

    def parse_lib_body_exp_without_location
      case @token.type
      when .op_at_lsquare?
        parse_annotation
      when .ident?
        case @token.value
        when Keyword::ALIAS
          parse_alias
        when Keyword::FUN
          parse_fun_def(top_level: false)
        when Keyword::TYPE
          parse_type_def
        when Keyword::STRUCT
          @inside_c_struct = true
          node = parse_c_struct_or_union union: false
          @inside_c_struct = false
          node
        when Keyword::UNION
          parse_c_struct_or_union union: true
        when Keyword::ENUM
          parse_enum_def
        else
          unexpected_token
        end
      when .const?
        ident = parse_path(global: false, location: @token.location)
        skip_space
        check :OP_EQ
        next_token_skip_space_or_newline
        value = parse_expression
        skip_statement_end
        Assign.new(ident, value)
      when .global?
        doc = @token.doc
        location = @token.location
        name = @token.value.to_s[1..-1]
        next_token_skip_space_or_newline
        if @token.type.op_eq?
          next_token_skip_space
          check IdentOrConst
          real_name = @token.value.to_s
          next_token_skip_space
        end
        check :OP_COLON
        next_token_skip_space_or_newline
        type = parse_bare_proc_type

        if name[0].ascii_uppercase?
          raise "external variables must start with lowercase, use for example `$#{name.underscore} = #{name} : #{type}`", location
        end

        skip_statement_end
        ExternalVar.new(name, type, real_name)
          .at(location).tap(&.doc=(doc))
      when .op_lcurly_lcurly?
        parse_percent_macro_expression
      when .op_lcurly_percent?
        parse_percent_macro_control
      else
        unexpected_token
      end
    end

    IdentOrConst = [:IDENT, :CONST] of Token::Kind

    def parse_fun_def(top_level, require_body = false)
      location = @token.location
      doc = @token.doc

      with_isolated_var_scope(require_body) do
        next_token_skip_space_or_newline

        name_location = @token.location
        name = if top_level
                 check_ident
               else
                 check IdentOrConst
                 @token.value.to_s
               end

        next_token_skip_space_or_newline

        if @token.type.op_eq?
          next_token_skip_space_or_newline
          case @token.type
          when .ident?, .const?
            real_name = @token.value.to_s
            next_token_skip_space_or_newline
          when .delimiter_start?
            real_name = parse_string_without_interpolation("fun name")
            skip_space
          else
            unexpected_token
          end
        else
          real_name = name
        end

        params = [] of Arg
        varargs = false

        if @token.type.op_lparen?
          next_token_skip_space_or_newline
          while !@token.type.op_rparen?
            if @token.type.op_period_period_period?
              varargs = true
              next_token_skip_space_or_newline
              check :OP_RPAREN
              break
            end

            if @token.type.ident?
              param_name = @token.value.to_s
              param_location = @token.location

              next_token_skip_space_or_newline
              check :OP_COLON
              next_token_skip_space_or_newline
              param_type = parse_bare_proc_type
              skip_space_or_newline

              params.each do |param|
                if param.name == param_name
                  raise "duplicated fun parameter name: #{param_name}", param_location
                end
              end

              params << Arg.new(param_name, nil, param_type).at(param_location)

              push_var_name param_name if require_body
            else
              if top_level
                raise "top-level fun parameter must have a name", @token
              end
              param_type = parse_union_type
              params << Arg.new("", nil, param_type).at(param_type)
            end

            if @token.type.op_comma?
              next_token_skip_space_or_newline
            else
              skip_space_or_newline
              check :OP_RPAREN
              break
            end
          end
          end_location = token_end_location
          next_token_skip_statement_end
        end

        if @token.type.op_colon?
          next_token_skip_space_or_newline
          end_location = token_end_location
          return_type = parse_bare_proc_type
        end

        skip_statement_end

        if require_body
          @fun_nest += 1

          if @token.keyword?(:end)
            body = Nop.new
            end_location = token_end_location
            next_token
          else
            body = parse_expressions
            body, end_location, _ = parse_exception_handler body, implicit: true
          end

          @fun_nest -= 1
        else
          body = nil
        end

        fun_def = FunDef.new name, params, return_type, varargs, body, real_name
        fun_def.name_location = name_location
        fun_def.doc = doc
        fun_def.at(location).at_end(end_location)
      end
    end

    def parse_alias
      doc = @token.doc

      next_token_skip_space_or_newline

      name = parse_path

      skip_space
      check :OP_EQ
      next_token_skip_space_or_newline

      value = parse_bare_proc_type
      end_location = value.end_location
      skip_space

      alias_node = Alias.new(name, value).at_end(end_location)
      alias_node.doc = doc
      alias_node
    end

    def parse_pointerof
      next_token_skip_space

      check :OP_LPAREN
      next_token_skip_space_or_newline

      if @token.keyword?(:self)
        raise "can't take address of self", @token.line_number, @token.column_number
      end

      exp = parse_op_assign
      skip_space_or_newline

      end_location = token_end_location
      check :OP_RPAREN
      next_token_skip_space

      PointerOf.new(exp).at_end(end_location)
    end

    def parse_sizeof
      parse_sizeof SizeOf
    end

    def parse_instance_sizeof
      parse_sizeof InstanceSizeOf
    end

    def parse_alignof
      parse_sizeof AlignOf
    end

    def parse_instance_alignof
      parse_sizeof InstanceAlignOf
    end

    def parse_sizeof(klass)
      sizeof_location = @token.location
      next_token_skip_space

      check :OP_LPAREN
      next_token_skip_space_or_newline

      location = @token.location
      exp = parse_bare_proc_type.at(location)

      skip_space_or_newline

      end_location = token_end_location
      check :OP_RPAREN
      next_token_skip_space

      klass.new(exp).at(sizeof_location).at_end(end_location)
    end

    def parse_offsetof
      offsetof_location = @token.location
      next_token_skip_space
      check :OP_LPAREN

      next_token_skip_space_or_newline
      type_location = @token.location
      type = parse_bare_proc_type.at(type_location)

      skip_space
      check :OP_COMMA

      next_token_skip_space_or_newline
      offset = case @token.type
               when .instance_var?
                 InstanceVar.new(@token.value.to_s)
               when .number?
                 raise "expecting an integer offset, not '#{@token}'", @token if !@token.number_kind.i32?
                 NumberLiteral.new(@token.value.to_s, @token.number_kind)
               else
                 raise "expecting an instance variable or a integer offset, not '#{@token}'", @token
               end
      offset.at(@token.location)

      next_token_skip_space_or_newline

      end_location = token_end_location
      check :OP_RPAREN
      next_token_skip_space

      OffsetOf.new(type, offset).at(offsetof_location).at_end(end_location)
    end

    def parse_type_def
      doc = @token.doc
      next_token_skip_space_or_newline
      name = check_const
      name_location = @token.location
      next_token_skip_space_or_newline
      check :OP_EQ
      next_token_skip_space_or_newline

      type = parse_bare_proc_type
      skip_space

      typedef = TypeDef.new name, type
      typedef.name_location = name_location
      typedef.doc = doc

      typedef
    end

    def parse_c_struct_or_union(union : Bool)
      doc = @token.doc
      location = @token.location
      next_token_skip_space_or_newline
      name = check_const
      next_token
      check StatementEnd
      skip_statement_end
      body = parse_c_struct_or_union_body_expressions
      check_ident :end
      end_location = token_end_location
      next_token_skip_space

      CStructOrUnionDef.new(name, Expressions.from(body), union: union)
        .at(location).at_end(end_location)
        .tap(&.doc=(doc))
    end

    def parse_c_struct_or_union_body
      next_token_skip_statement_end
      Expressions.from(parse_c_struct_or_union_body_expressions)
    end

    private def parse_c_struct_or_union_body_expressions
      exps = [] of ASTNode

      while true
        case @token.type
        when .ident?
          case @token.value
          when Keyword::INCLUDE
            if @inside_c_struct
              location = @token.location
              exps << parse_include.at(location)
            else
              parse_c_struct_or_union_fields exps
            end
          when Keyword::END
            break
          else
            parse_c_struct_or_union_fields exps
          end
        when .op_lcurly_lcurly?
          exps << parse_percent_macro_expression
        when .op_lcurly_percent?
          exps << parse_percent_macro_control
        when .newline?, .op_semicolon?
          skip_statement_end
        else
          break
        end
      end

      exps
    end

    def parse_c_struct_or_union_fields(exps)
      doc = @token.doc
      vars = [Var.new(@token.value.to_s).at(@token.location).at_end(token_end_location)]

      next_token_skip_space_or_newline

      while @token.type.op_comma?
        next_token_skip_space_or_newline
        vars << Var.new(check_ident).at(@token.location).at_end(token_end_location)
        next_token_skip_space_or_newline
      end

      check :OP_COLON
      next_token_skip_space_or_newline

      type = parse_bare_proc_type

      skip_statement_end

      vars.each do |var|
        var.doc = doc
        exps << TypeDeclaration.new(var, type).at(var).at_end(type)
      end
    end

    def parse_enum_def
      location = @token.location
      doc = @token.doc

      next_token_skip_space_or_newline

      name = parse_path
      skip_space

      if @token.type.op_colon?
        next_token_skip_space_or_newline
        base_type = parse_path
        skip_space
      end

      check SemicolonOrNewLine
      skip_statement_end

      members = parse_enum_body_expressions

      check_ident :end
      end_location = token_end_location
      next_token_skip_space

      enum_def = EnumDef.new name, members, base_type
      enum_def.doc = doc
      enum_def.at(location).at_end(end_location)
    end

    def parse_enum_body
      next_token_skip_statement_end
      Expressions.from(parse_enum_body_expressions)
    end

    private def parse_enum_body_expressions
      members = [] of ASTNode
      until end_token?
        location = @token.location
        case @token.type
        when .const?
          constant_name = @token.value.to_s
          member_doc = @token.doc

          next_token_skip_space
          if @token.type.op_eq?
            next_token_skip_space_or_newline
            constant_value = parse_logical_or
          else
            constant_value = nil
          end

          skip_space

          case @token.type
          when .newline?, .op_semicolon?, .eof?
            next_token_skip_statement_end
          else
            unless @token.keyword?(:end)
              raise "expecting ';', 'end' or newline after enum member", location
            end
          end

          arg = Arg.new(constant_name, constant_value).at(location).at_end(constant_value || location)
          arg.doc = member_doc

          members << arg
        when .ident?
          visibility = nil

          case @token.value
          when Keyword::PRIVATE
            visibility = Visibility::Private
            next_token_skip_space
          when Keyword::PROTECTED
            visibility = Visibility::Protected
            next_token_skip_space
          else
            # not a visibility modifier
          end

          def_location = @token.location

          case @token.value
          when Keyword::DEF
            member = parse_def.at(def_location)
            member = VisibilityModifier.new(visibility, member).at(location) if visibility
            members << member
          when Keyword::MACRO
            member = parse_macro.at(def_location)
            member = VisibilityModifier.new(visibility, member).at(location) if visibility
            members << member
          else
            unexpected_token
          end
        when .class_var?
          class_var = ClassVar.new(@token.value.to_s).at(location)

          next_token_skip_space
          check :OP_EQ
          next_token_skip_space_or_newline
          value = parse_op_assign

          members << Assign.new(class_var, value).at(class_var)
        when .op_lcurly_lcurly?
          members << parse_percent_macro_expression
        when .op_lcurly_percent?
          members << parse_percent_macro_control.at(location)
        when .op_at_lsquare?
          members << parse_annotation
        when .newline?, .op_semicolon?
          skip_statement_end
        else
          unexpected_token
        end
      end
      members
    end

    def node_and_next_token(node)
      node.end_location = token_end_location
      next_token
      node
    end

    def end_token?
      case @token.type
      when .op_rcurly?, .op_rsquare?, .op_percent_rcurly?, .eof?
        return true
      end

      if keyword = @token.value.as?(Keyword)
        case keyword
        when .do?, .end?, .else?, .elsif?, .when?, Keyword::IN, .rescue?, .ensure?, .then?
          !next_comes_colon_space?
        else
          false
        end
      else
        false
      end
    end

    def can_be_assigned?(node)
      case node
      when Var, InstanceVar, ClassVar, Path, Global, Underscore
        true
      when Call
        return false if node.has_parentheses?
        no_args = node.args.empty? && node.named_args.nil? && node.block.nil? && node.block_arg.nil?
        return true if Lexer.ident?(node.name) && no_args
        node.name == "[]" && (node.args_in_brackets? || no_args)
      else
        false
      end
    end

    # IDENT CONST ` << < <= == === != =~ !~ >> > >= + - * / // ! ~ % & | ^ ** [] []? []= <=> &+ &- &* &**
    DefOrMacroCheck1 = [
      :IDENT, :CONST, :OP_GRAVE,
      :OP_LT_LT, :OP_LT, :OP_LT_EQ, :OP_EQ_EQ, :OP_EQ_EQ_EQ, :OP_BANG_EQ, :OP_EQ_TILDE,
      :OP_BANG_TILDE, :OP_GT_GT, :OP_GT, :OP_GT_EQ, :OP_PLUS, :OP_MINUS, :OP_STAR, :OP_SLASH,
      :OP_SLASH_SLASH, :OP_BANG, :OP_TILDE, :OP_PERCENT, :OP_AMP, :OP_BAR, :OP_CARET, :OP_STAR_STAR,
      :OP_LSQUARE_RSQUARE, :OP_LSQUARE_RSQUARE_EQ, :OP_LSQUARE_RSQUARE_QUESTION, :OP_LT_EQ_GT,
      :OP_AMP_PLUS, :OP_AMP_MINUS, :OP_AMP_STAR, :OP_AMP_STAR_STAR,
    ] of Token::Kind

    def consume_def_or_macro_name(what : String = "def")
      # Force lexer return if possible a def or macro name
      # cases like: def `, def /, def //
      # that in regular statements states for delimiters
      # here must be treated as method names.
      wants_def_or_macro_name do
        next_token_skip_space_or_newline
        iyi_check_name(DefOrMacroCheck1, "a name after '#{what}'")
      end
      @token.to_s
    end

    # iyi: a place that takes a name or an operator, answered as one
    # sentence rather than the thirty-three tokens it takes: "expecting
    # any of these tokens: IDENT, CONST, `, <<, <, <=, ==, ..." was the
    # answer to `def 1` and to `x.` at the end of a line.
    private def iyi_check_name(token_types : Array(Token::Kind), what : String) : Nil
      return if token_types.any? { |type| @token.type == type }
      not_what = @token.type.eof? ? "the end of the file" : "'#{@token}'"
      raise "expecting #{what}, not #{not_what}", @token
    end

    def consume_def_equals_sign_skip_space
      result = consume_def_equals_sign
      skip_space
      result
    end

    def consume_def_equals_sign
      end_location = token_end_location
      next_token
      if @token.type.op_eq?
        end_location = token_end_location
        next_token
        {true, end_location}
      else
        {false, end_location}
      end
    end

    # If *create_scope* is true, creates an isolated variable scope and returns
    # the yield result, resetting the scope afterwards. Otherwise simply returns
    # the yield result without touching the scopes.
    def with_isolated_var_scope(create_scope = true, &)
      return yield unless create_scope

      begin
        @var_scopes.push(Set(String).new)
        yield
      ensure
        @var_scopes.pop
      end
    end

    # Creates a new variable scope with the same variables as the current scope,
    # and then returns the yield result, resetting the scope afterwards.
    def with_lexical_var_scope(&)
      current_scope = @var_scopes.last.dup
      @var_scopes.push current_scope
      yield
    ensure
      @var_scopes.pop
    end

    def push_vars(vars)
      vars.each do |var|
        push_var var
      end
    end

    def push_var(var : Var | Arg)
      push_var_name var.name.to_s
    end

    def push_var(var : TypeDeclaration)
      var_var = var.var
      case var_var
      when Var
        push_var_name var_var.name
      when InstanceVar
        push_var_name var_var.name
      else
        raise "can't happen"
      end
    end

    def push_var_name(name)
      @var_scopes.last.add name
    end

    def push_var(node)
      # Nothing
    end

    def var_in_scope?(name)
      @var_scopes.last.includes? name
    end

    def open(symbol, location = @token.location, &)
      @unclosed_stack.push Unclosed.new(symbol, location)
      begin
        value = yield
      ensure
        @unclosed_stack.pop
      end
      value
    end

    def check_void_value(exp, location)
      if exp.is_a?(ControlExpression)
        raise "void value expression", location
      end
    end

    def check_void_expression_keyword
      case @token.value
      when Keyword::BREAK, Keyword::NEXT, Keyword::RETURN
        unless next_comes_colon_space?
          raise "void value expression", @token, @token.value.to_s.size
        end
      end
    end

    def check(token_types : Array(Token::Kind))
      raise "expecting any of these tokens: #{token_types.join ", "} (not '#{@token}')", @token unless token_types.any? { |type| @token.type == type }
    end

    def check(token_type : Token::Kind)
      return if token_type == @token.type
      # iyi: a closer that is missing names what it would close and where
      # that began, as a missing `end` does: "expecting token ']', not
      # 'puts'" pointed at the next line's first word and said nothing
      # about the `[` two lines up. The upstream sentence stays as its
      # head, because the parser's specs and every reader know it.
      if (unclosed = @unclosed_stack.last?) && iyi_closes?(token_type, unclosed.name)
        raise "expecting token '#{token_type}', not '#{@token}'; the #{unclosed.name} that began at line #{unclosed.location.line_number} is still open", @token
      end
      raise "expecting token '#{token_type}', not '#{@token}'", @token
    end

    private def iyi_closes?(token_type : Token::Kind, name : String) : Bool
      case token_type
      when .op_rsquare? then name == "array literal"
      when .op_rcurly?  then name.in?("hash literal", "tuple literal", "named tuple literal")
      when .op_rparen?  then name.in?("call", "parenthesized expression")
      else                   false
      end
    end

    def check_ident(value : Keyword)
      return if @token.keyword?(value)
      # iyi: an `end` missing at the end of the file names what it was
      # to close - the innermost construct still open - and where that
      # began: "expecting identifier 'end', not 'EOF'" at the last line
      # sent a reader back through the whole file to find the one
      # unclosed `if`.
      if value == Keyword::END && @token.type.eof? && (open = @iyi_open.last?)
        message = "expecting 'end' to close the #{open[0]} that began at line #{open[1].try(&.line_number)}, not the end of the file"
        # `else if` is legal and opens a second `if` that wants its own
        # `end`; the inner one takes the only `end` written, and the outer
        # is what is left open - the one the writer thought `elsif` had
        # folded away.
        if (else_if = @iyi_else_if) && open[0] == "if" && (began = open[1].try(&.line_number)) && began < else_if.line_number
          message += " - `else if` at line #{else_if.line_number} opens a second `if` that needs its own `end`; `elsif` is the spelling here"
        end
        raise message, @token
      end
      raise "expecting identifier '#{value}', not '#{@token}'", @token
    end

    # iyi: the constructs still open, innermost last, for `check_ident`'s
    # message on a missing `end`: pushed where a construct's body begins,
    # popped once its `end` was seen. A failed parse abandons the stack
    # with the parser.
    @iyi_open = [] of {String, Location?}

    # iyi: where an `else` was followed by `if` on its own line, for the
    # missing-`end` sentence above.
    @iyi_else_if : Location?

    def iyi_opened(what : String, location : Location?) : Nil
      @iyi_open << {what, location}
    end

    def iyi_closed : Nil
      @iyi_open.pop?
    end

    def check_ident
      check :IDENT
      @token.value.to_s
    end

    def check_const
      check :CONST
      @token.value.to_s
    end

    def unexpected_token(msg : String? = nil, token : Token = @token)
      token_str = token.type.eof? ? "EOF" : token.to_s.inspect
      if msg
        raise "unexpected token: #{token_str} (#{msg})", @token
      end
      # iyi: the token is not always a slip. `and` and `or` are another
      # language's spelling, and a `:` after `fn f(x : Int32)` is a
      # definition written with another language's keyword, which parsed
      # as a call and then met its return type; both are answered.
      if token.type.ident? && (spelling = IYI_SPELLINGS[token.value.to_s]?)
        raise "unexpected token: #{token_str}: #{spelling}", @token
      end
      if (lookalike = @iyi_def_lookalike) && lookalike[1].try(&.line_number) == token.line_number
        raise "unexpected token: #{token_str}: `#{lookalike[0]}` is a call here, not a keyword - a function is `def name(args) : Type`", @token
      end
      raise "unexpected token: #{token_str}", @token
    end

    # iyi: spellings from other languages the parser meets as a bare
    # identifier where no expression may go, and what they are here.
    IYI_SPELLINGS = {
      "and" => "`&&` is the spelling here",
      "or"  => "`||` is the spelling here",
    }

    # iyi: lowercase spellings of the prelude's scalar names, met where a
    # type is expected, and the name each one is here.
    IYI_TYPE_SPELLINGS = {
      "int"     => "Int32",
      "int8"    => "Int8",
      "int16"   => "Int16",
      "int32"   => "Int32",
      "int64"   => "Int64",
      "int128"  => "Int128",
      "uint8"   => "UInt8",
      "uint16"  => "UInt16",
      "uint32"  => "UInt32",
      "uint64"  => "UInt64",
      "float"   => "Float64",
      "float32" => "Float32",
      "float64" => "Float64",
      "double"  => "Float64",
      "string"  => "String",
      "str"     => "String",
      "bool"    => "Bool",
      "boolean" => "Bool",
      "char"    => "Char",
      "nil"     => "Nil",
      "void"    => "Nil",
    }

    # iyi: the first `fn`, `func` or `function` parsed as a command call
    # with a call for its argument - `fn f(x : Int32)` - and where. It
    # is what a stray `end` or a `: Type` after the parenthesis is about.
    @iyi_def_lookalike : {String, Location?}?

    # iyi: the first `for` parsed as a command call — `for i in 0..3` — and
    # where. `in` is a keyword `case` uses, so what the parser met was a
    # keyword with no construct open and it said so: "unexpected 'in': no
    # `case` is open for it", about a line with no `case` anywhere near it.
    @iyi_for_lookalike : {String, Location?}?

    def unexpected_token_in_atomic
      # iyi: the file ending inside a literal or a call is what
      # "unterminated" means. A stray `)` inside an array literal was
      # read the same way and reported at the `[`, three lines from the
      # token that is wrong; it is the token now.
      if @token.type.eof? && (unclosed = @unclosed_stack.last?)
        raise "unterminated #{unclosed.name}", unclosed.location
      end

      unexpected_token
    end

    def var?(name)
      return true if @in_macro_expression

      name = name.to_s
      name == "self" || var_in_scope?(name)
    end

    def push_visibility(&)
      old_visibility = @visibility
      @visibility = nil
      value = yield
      @visibility = old_visibility
      value
    end

    def next_token
      token = super

      if token.type.newline? && !@consuming_heredocs && !@heredocs.empty?
        consume_heredocs
      end

      token
    end

    def temp_arg_name
      arg_name = "__arg#{@temp_arg_count}"
      @temp_arg_count += 1
      arg_name
    end
  end

  class StringInterpolation
    include Lexer::HeredocItem
  end
end
