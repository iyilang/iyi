module Iyi::Stale
  enum ElementKind
    Def
    Fun
    LibFun
    Const
    ClassVar
    IvarInit
    Main
    Type
    ObjectUnit
  end

  record Element,
    kind : ElementKind,
    key : String,
    node : ASTNode?,
    type : Type?,
    self_type : Type?,
    location : Location?

  enum EdgeKind
    Call
    BlockInline
    ProcLiteral
    Const
    ClassVar
    IvarInit
  end

  class Reach
    getter elements : Array(Element)
    getter def_names : Set(String)
    getter proc_literals : Set(UInt64)
    getter consts : Set(Const)
    getter class_vars : Set(MetaTypeVar)
    getter mismatch : Array(String)

    def initialize(@elements : Array(Element) = [] of Element,
                   @def_names : Set(String) = Set(String).new,
                   @proc_literals : Set(UInt64) = Set(UInt64).new,
                   @consts : Set(Const) = Set(Const).new,
                   @class_vars : Set(MetaTypeVar) = Set(MetaTypeVar).new)
      @mismatch = [] of String
    end

    def cross_check(recorder : Recorder) : Nil
      recorder.emitted_defs.each do |def_name|
        unless @def_names.includes?(def_name)
          @mismatch << def_name unless @mismatch.includes?(def_name)
        end
      end

      recorder.emitted_proc_literals.each do |lit, name|
        unless @proc_literals.includes?(lit.object_id)
          @mismatch << name unless @mismatch.includes?(name)
        end
      end

      recorder.emitted_consts.each do |const|
        unless @consts.includes?(const)
          key = const.to_s
          @mismatch << key unless @mismatch.includes?(key)
        end
      end

      recorder.emitted_class_vars.each do |cv|
        cv_key = "#{cv.owner}::#{cv.name}"
        unless @class_vars.any? { |c| c.same?(cv) || "#{c.owner}::#{c.name}" == cv_key }
          @mismatch << cv_key unless @mismatch.includes?(cv_key)
        end
      end
    end
  end

  class Recorder
    getter emitted_defs : Set(String)
    getter emitted_proc_literals : Array({ProcLiteral, String})
    getter emitted_consts : Set(Const)
    getter emitted_class_vars : Set(MetaTypeVar)

    def initialize
      @emitted_defs = Set(String).new
      @emitted_proc_literals = [] of {ProcLiteral, String}
      @emitted_consts = Set(Const).new
      @emitted_class_vars = Set(MetaTypeVar).new
    end

    def record_def(mangled_name : String) : Nil
      @emitted_defs << mangled_name
    end

    def record_proc_literal(node : ProcLiteral, name : String) : Nil
      @emitted_proc_literals << {node, name}
    end

    def record_const(const : Const) : Nil
      @emitted_consts << const
    end

    def record_class_var(class_var : MetaTypeVar) : Nil
      @emitted_class_vars << class_var
    end
  end

  class ReachWalk < Visitor
    getter program : Program
    getter drop : EdgeKind?
    getter elements : Array(Element)
    getter def_names : Set(String)
    getter proc_literals : Set(UInt64)
    getter consts : Set(Const)
    getter class_vars : Set(MetaTypeVar)

    @visited_defs : Set(String)
    @visited_consts : Set(Const)
    @visited_class_vars : Set(MetaTypeVar)
    @allocated_types : Set(Type)
    @visited_fun_defs : Set(External)

    class BlockContext
      getter block : Block
      getter type : Type?
      getter parent : BlockContext?

      def initialize(@block : Block, @type : Type?, @parent : BlockContext?)
      end
    end

    @current_type : Type?
    @current_block_context : BlockContext?
    @in_lib : Bool

    def self.walk(program : Program, node : ASTNode, drop : EdgeKind? = nil) : Reach
      walker = new(program, drop)
      walker.reach(node)
      Reach.new(
        walker.elements,
        walker.def_names,
        walker.proc_literals,
        walker.consts,
        walker.class_vars
      )
    end

    def initialize(@program : Program, @drop : EdgeKind? = nil)
      @elements = [] of Element
      @def_names = Set(String).new
      @proc_literals = Set(UInt64).new
      @consts = Set(Const).new
      @class_vars = Set(MetaTypeVar).new

      @visited_defs = Set(String).new
      @visited_consts = Set(Const).new
      @visited_class_vars = Set(MetaTypeVar).new
      @allocated_types = Set(Type).new
      @visited_fun_defs = Set(External).new
      @current_type = @program
      @current_block_context = nil
      @in_lib = false
      @inlined_defs_stack = Set(Tuple(UInt64, String, UInt64)).new
    end

    def reach(node : ASTNode) : Nil
      # 1. Main element
      record_element(ElementKind::Main, "main", node, node.type?, @program, node.location)

      # 2. Well-known functions (codegen.cr:373, 679-713)
      reach_well_known_functions(node)

      # 3. Predefined constants (codegen.cr:375, const.cr:37-41)
      @program.predefined_constants.each do |const|
        reach_const(const)
      end

      # 4. Simple constants (codegen.cr:382, 422-430). An unreferenced
      # constant cannot cause emitted code merely by being declared.
      @program.const_initializers.each do |const|
        reach_const(const) if const.used? && const.simple? && !const.compile_time_value
      end

      # 5. Artifact class variables (codegen.cr:383)
      @program.iyi_artifact_class_vars.each_key do |qualified|
        owner_name, separator, name = qualified.partition("::@@")
        next if separator.empty?
        owner_name = owner_name.rchop("+.class").rchop("+")
        if (owner = @program.types[owner_name]?) && owner.is_a?(ClassVarContainer)
          if cv = owner.lookup_class_var?("@@#{name}")
            reach_class_var(cv)
          end
        end
      end
      # 6. Main node (codegen.cr:157)
      accept node

      # 7. Finish-time artifact objects and constants (codegen.cr:739-745, const.cr:303-325)
      unless @program.iyi_artifact_objects.empty?
        @program.iyi_artifact_constant_reads.each do |n|
          if const = n.target_const
            reach_const(const)
          end
        end

        @program.iyi_artifact_objects.each do |mod_name, units|
          units.each do |unit|
            record_element(ElementKind::ObjectUnit, "#{mod_name}/#{unit}", nil, nil, nil, nil)
          end
        end
      end
    end

    def accept(node : ASTNode?) : Nil
      node.try &.accept(self)
    end

    def record_element(kind : ElementKind, key : String, node : ASTNode? = nil,
                       type : Type? = nil, self_type : Type? = nil, location : Location? = nil) : Nil
      @elements << Element.new(kind, key, node, type, self_type, location)
    end

    private def reach_well_known_functions(node : ASTNode) : Nil
      visitor = WellKnownVisitor.new(self)
      node.accept visitor
    end

    protected def reach_fun_def(node : FunDef) : Nil
      return if @in_lib
      unless node.external.dead? || @visited_fun_defs.includes?(node.external)
        @visited_fun_defs << node.external
        @def_names << node.real_name
        record_element(ElementKind::Fun, node.real_name, node, nil, @program, node.location)
        accept node.body
        accept node.external.body
      end
    end

    def reach_const(const : Const) : Nil
      return if @drop == EdgeKind::Const
      return if @visited_consts.includes?(const)
      @visited_consts << const

      @consts << const
      record_element(
        ElementKind::Const,
        const.to_s,
        const.value,
        const.value.type?,
        const.namespace,
        const.locations.try &.first?
      )

      old_type = @current_type
      @current_type = const.namespace
      accept const.value
      @current_type = old_type
    end

    def reach_class_var(class_var : MetaTypeVar) : Nil
      return if @drop == EdgeKind::ClassVar
      owner = class_var.owner
      if owner.is_a?(VirtualType) || owner.is_a?(VirtualMetaclassType)
        base = owner.base_type
        if base.is_a?(ClassVarContainer) && (cv = base.lookup_class_var?(class_var.name))
          reach_concrete_class_var(cv)
        end
        base.all_subclasses.each do |subclass|
          if subclass.is_a?(ClassVarContainer) && (cv = subclass.lookup_class_var?(class_var.name))
            reach_concrete_class_var(cv)
          end
        end
      else
        reach_concrete_class_var(class_var)
      end
    end

    private def reach_concrete_class_var(class_var : MetaTypeVar) : Nil
      return if @visited_class_vars.includes?(class_var)
      @visited_class_vars << class_var
      init_node = class_var.initializer.try(&.node)
      unless simple_class_var_init?(init_node, class_var.type)
        @class_vars << class_var
      end
      record_element(
        ElementKind::ClassVar,
        "#{class_var.owner}::#{class_var.name}",
        init_node,
        class_var.type,
        class_var.owner,
        init_node.try(&.location)
      )

      if initializer = class_var.initializer
        old_type = @current_type
        @current_type = class_var.owner
        accept initializer.node
        @current_type = old_type
      end
    end

    private def simple_class_var_init?(node : ASTNode?, type : Type) : Bool
      return true if node.nil?
      return true if node.type?.try(&.nil_type?) && !type.nil_type?
      if type.is_a?(PrimitiveType) || type.is_a?(EnumType)
        return true if node.simple_literal?
        case node
        when NilLiteral, BoolLiteral, CharLiteral, NumberLiteral, SymbolLiteral
          return true
        end
      end
      false
    end

    def reach_allocate(type : Type) : Nil
      base_type = type.is_a?(VirtualType) ? type.base_type : type
      return if @allocated_types.includes?(base_type)
      @allocated_types << base_type

      record_element(ElementKind::Type, base_type.to_s, nil, base_type, nil, nil)

      if @drop != EdgeKind::IvarInit
        reach_instance_vars_initializers(base_type, base_type)
      end
    end

    private def reach_instance_vars_initializers(real_type : Type, current_type : Type) : Nil
      if current_type.is_a?(ClassType) || current_type.is_a?(GenericClassInstanceType)
        if superclass = current_type.superclass
          reach_instance_vars_initializers(real_type, superclass)
        end
      end

      if current_type.is_a?(ClassType) || current_type.is_a?(GenericClassInstanceType)
        if initializers = current_type.instance_vars_initializers
          record_element(ElementKind::IvarInit, current_type.to_s, nil, nil, current_type, nil)
          initializers.each do |init|
            old_type = @current_type
            @current_type = real_type.metaclass
            accept init.value
            @current_type = old_type
          end
        end
      end
    end

    def reach_call_target(node : Call, target_def : Def, owner : Type) : Nil
      owner = iyi_artifact_self_type(target_def, owner)

      if block = node.block
        if @drop == EdgeKind::BlockInline
          return
        end

        if (fun_literal = block.fun_literal) && target_def.uses_block_arg?
          accept fun_literal
        else
          bc = BlockContext.new(block, @current_type, @current_block_context)
          reach_inlined_def(target_def, owner, bc)
          return
        end
      end

      if target_def.body.is_a?(Primitive)
        reach_primitive(node, target_def.body.as(Primitive), target_def, owner)
        return
      end

      if try_inline_call?(target_def, owner)
        return
      end

      mangled_name = target_def.mangled_name(@program, owner)
      return if @visited_defs.includes?(mangled_name)
      @visited_defs << mangled_name
      @def_names << mangled_name
      record_element(
        target_def.is_a?(External) ? ElementKind::LibFun : ElementKind::Def,
        mangled_name,
        target_def,
        target_def.type?,
        owner,
        target_def.location
      )

      old_type = @current_type
      old_block_context = @current_block_context
      old_inlined_stack = @inlined_defs_stack
      @current_type = owner
      @current_block_context = nil
      @inlined_defs_stack = Set(Tuple(UInt64, String, UInt64)).new
      accept target_def.body
      @inlined_defs_stack = old_inlined_stack
      @current_block_context = old_block_context
      @current_type = old_type
    end

    def personality_name : String
      @program.has_flag?("msvc") ? "__CxxFrameHandler3" : @program.abi_name("personality")
    end

    private def iyi_artifact_self_type(target_def : Def, self_type : Type) : Type
      return self_type unless target_def.iyi_from_artifact?
      return self_type if target_def.iyi_body_travelled?

      defining = target_def.original_owner?
      return self_type unless defining
      return self_type if defining == self_type

      return self_type unless defining.instance_type.iyi_from_artifact?
      return self_type if defining.is_a?(GenericType) || defining.is_a?(GenericInstanceType)
      return self_type if defining.instance_type.module?
      return self_type unless self_type.metaclass? == defining.metaclass?

      defining.responds_to?(:virtual_type) ? defining.virtual_type : defining
    end

    private def reach_inlined_def(target_def : Def, owner : Type, block_context : BlockContext) : Nil
      key = {target_def.object_id, owner.to_s, block_context.block.object_id}
      return if @inlined_defs_stack.includes?(key)
      @inlined_defs_stack << key
      old_block_context = @current_block_context
      old_type = @current_type
      @current_block_context = block_context
      @current_type = owner
      accept target_def.body
      @current_type = old_type
      @current_block_context = old_block_context
      @inlined_defs_stack.delete(key)
    end

    private def reach_primitive(node : Call?, primitive : Primitive, target_def : Def, self_type : Type) : Nil
      case primitive.name
      when "allocate"
        type = node ? node.type : self_type.instance_type
        reach_allocate(type)
      when "pre_initialize"
        type = self_type.instance_type
        reach_allocate(type)
      end
    end

    def try_inline_call?(target_def : Def, owner : Type) : Bool
      return false if target_def.is_a?(External)
      return false if target_def.iyi_from_artifact?

      unless @program.iyi_exported_owners.empty?
        if (def_owner = target_def.owner) && @program.iyi_exported_owners.includes?(def_owner.instance_type)
          return false unless target_def.body.is_a?(InstanceVar) || (target_def.body.is_a?(Var) && target_def.body.as(Var).name == "self")
          return false
        end
      end

      case target_def.body
      when Nop, NilLiteral, BoolLiteral, CharLiteral, StringLiteral, NumberLiteral, SymbolLiteral
        true
      when Var
        target_def.body.as(Var).name == "self"
      when InstanceVar
        true
      else
        false
      end
    end

    def fun_literal_name(node : ProcLiteral) : String
      location = node.location.try &.expanded_location
      if location && (type = node.type?)
        filename = location.filename.as(String)
        Iyi.safe_mangling(@program, "~proc#{type}@#{Iyi.relative_filename(filename)}:#{location.line_number}")
      else
        "~fun_literal"
      end
    end

    # All 62 visit overloads mirroring CodeGenVisitor#visit exactly

    def visit(node : ASTNode)
      true
    end

    def visit(node : Alias)
      false
    end

    def visit(node : AlignOf)
      accept node.exp if node.exp.is_a?(ASTNode)
      false
    end

    def visit(node : Annotation)
      false
    end

    def visit(node : Asm)
      node.inputs.try &.each { |input| accept input.exp }
      node.outputs.try &.each { |output| accept output.exp if output.exp }
      false
    end

    def visit(node : Assign)
      target = node.target
      case target
      when Path
        if const = target.target_const
          reach_const(const)
        end
      when ClassVar
        reach_class_var(target.var)
        accept node.value
      when InstanceVar
        accept node.value
      else
        accept target
        accept node.value
      end
      false
    end

    def visit(node : AssocTypeDecl)
      false
    end

    def visit(node : BoolLiteral)
      false
    end

    def visit(node : Break)
      accept node.exp if node.exp
      false
    end

    def visit(node : CStructOrUnionDef)
      false
    end

    def visit(node : Call)
      accept node.obj if node.obj
      node.args.each { |arg| accept arg }
      node.named_args.try &.each { |na| accept na.value }

      return false if @drop == EdgeKind::Call

      if target_defs = node.target_defs
        target_defs.each do |target_def|
          owner = node.super? ? node.scope : target_def.owner
          reach_call_target(node, target_def, owner)
        end
      end
      false
    end

    def visit(node : Cast)
      accept node.obj
      false
    end

    def visit(node : CharLiteral)
      false
    end

    def visit(node : ClassDef)
      accept node.body
      false
    end

    def visit(node : ClassVar)
      reach_class_var(node.var)
      false
    end

    def visit(node : Def)
      node.hook_expansions.try &.each do |hook|
        accept hook
      end
      false
    end

    def visit(node : EnumDef)
      false
    end

    def visit(node : ExceptionHandler)
      accept node.body
      node.rescues.try &.each { |r| accept r.body }
      accept node.else if node.else
      accept node.ensure if node.ensure
      false
    end

    def visit(node : ExpandableNode)
      node.expanded.try &.accept(self)
      false
    end

    def visit(node : Expressions)
      node.expressions.each do |exp|
        accept exp
      end
      false
    end

    def visit(node : Extend)
      false
    end

    def visit(node : ExternalVar)
      false
    end

    def visit(node : FileNode)
      accept node.node
      false
    end

    def visit(node : FunDef)
      reach_fun_def(node)
      false
    end

    def visit(node : Generic)
      false
    end

    def visit(node : Global)
      false
    end

    def visit(node : If)
      if node.truthy?
        accept node.cond
        accept node.then
        return false
      end

      if node.falsey?
        accept node.cond
        accept node.else
        return false
      end

      accept node.cond
      accept node.then
      accept node.else
      false
    end

    def visit(node : ImplDef | TraitDef)
      accept node.body
      false
    end

    def visit(node : Include)
      false
    end

    def visit(node : InstanceAlignOf)
      accept node.exp if node.exp.is_a?(ASTNode)
      false
    end

    def visit(node : InstanceSizeOf)
      accept node.exp if node.exp.is_a?(ASTNode)
      false
    end

    def visit(node : InstanceVar)
      false
    end

    def visit(node : IsA)
      accept node.obj
      false
    end

    def visit(node : LibDef)
      old_in_lib = @in_lib
      @in_lib = true
      accept node.body
      @in_lib = old_in_lib
      false
    end

    def visit(node : Macro)
      false
    end

    def visit(node : ModuleDef)
      accept node.body
      false
    end

    def visit(node : NamedTupleLiteral)
      node.entries.each do |entry|
        accept entry.value
      end
      false
    end

    def visit(node : Next)
      accept node.exp if node.exp
      false
    end

    def visit(node : NilLiteral)
      false
    end

    def visit(node : NilableCast)
      accept node.obj
      false
    end

    def visit(node : Nop)
      false
    end

    def visit(node : Not)
      accept node.exp
      false
    end

    def visit(node : NumberLiteral)
      false
    end

    def visit(node : Path)
      if const = node.target_const
        reach_const(const)
      end
      false
    end

    def visit(node : PointerOf)
      accept node.exp
      false
    end

    def visit(node : Primitive)
      case node.name
      when "allocate", "pre_initialize"
        type = node.type
        reach_allocate(type)
      end
      false
    end

    def visit(node : ProcLiteral)
      return false if @drop == EdgeKind::ProcLiteral

      @proc_literals << node.object_id
      fun_name = fun_literal_name(node)
      record_element(ElementKind::Def, fun_name, node, node.type?, @current_type, node.location)
      accept node.def.body
      false
    end

    def visit(node : ProcPointer)
      accept node.obj if node.obj
      return false if @drop == EdgeKind::Call

      target_def = node.call.target_def
      owner = node.call.target_def.owner
      reach_call_target(node.call, target_def, owner)
      false
    end

    def visit(node : RespondsTo)
      accept node.obj
      false
    end

    def visit(node : Return)
      accept node.exp if node.exp
      false
    end

    def visit(node : SizeOf)
      accept node.exp if node.exp.is_a?(ASTNode)
      false
    end

    def visit(node : StringLiteral)
      false
    end

    def visit(node : SymbolLiteral)
      false
    end

    def visit(node : TupleLiteral)
      node.elements.each do |el|
        accept el
      end
      false
    end

    def visit(node : TypeDeclaration)
      var = node.var
      case var
      when Var
        accept node.value if node.value
      when ClassVar
        reach_class_var(var.var)
        accept node.value if node.value
      end
      false
    end

    def visit(node : TypeDef)
      false
    end

    def visit(node : TypeOf)
      false
    end

    def visit(node : UninitializedVar)
      false
    end

    def visit(node : Unreachable)
      false
    end

    def visit(node : Var)
      false
    end

    def visit(node : While)
      accept node.cond
      accept node.body
      false
    end

    def visit(node : Yield)
      if scope = node.scope
        accept scope
      end
      node.exps.each do |exp|
        accept exp
      end
      if bc = @current_block_context
        old_bc = @current_block_context
        old_type = @current_type
        @current_block_context = bc.parent
        @current_type = bc.type
        accept bc.block.body
        @current_type = old_type
        @current_block_context = old_bc
      end
      false
    end

    private class WellKnownVisitor < Visitor
      @reach_walk : ReachWalk

      def initialize(@reach_walk : ReachWalk)
      end

      def visit(node : FileNode)
        true
      end

      def visit(node : Expressions)
        true
      end

      def visit(node : FunDef)
        case node.name
        when @reach_walk.program.malloc_name, @reach_walk.program.malloc_atomic_name,
             @reach_walk.program.realloc_name, @reach_walk.program.raise_name,
             @reach_walk.personality_name, @reach_walk.program.get_exception_name,
             @reach_walk.program.raise_overflow_name, @reach_walk.program.raise_cast_failed_name,
             @reach_walk.program.raise_closure_to_c_name, @reach_walk.program.once_init_name,
             @reach_walk.program.once_name,
             Iyi::WRITE_BARRIER_BEGIN_NAME, Iyi::WRITE_BARRIER_NAME
          @reach_walk.reach_fun_def(node)
        end
        false
      end

      def visit(node : ASTNode)
        false
      end
    end
  end
end
