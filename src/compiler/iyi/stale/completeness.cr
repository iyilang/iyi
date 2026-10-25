module Iyi::Stale
  ALLOWED_LOCATION_READ_METHODS = %w(
    alloca_non_closured_vars
    codegen_fun
    codegen_primitive_pointer_malloc
    codegen_raise_cast_failed
    create_initialize_class_var_function
    create_initialize_const_function
    create_local_copy_of_arg
    create_read_class_var_function
    create_read_const_function
    declare_class_var_debug_info
    declare_const_debug_info
    declare_thread_local_fun
    declare_var
    emit_def_debug_metadata
    emit_vars_debug_info
    fun_literal_name
    initialize_const
    initialize_no_init_flag_const
    initialize_simple_const
    iyi_define_all_artifact_const_reads
    iyi_refuse_unreached
    prepare_call_args_non_external
    set_current_debug_location
    setup_closure_vars
    type_cast_exception_call
    visit
  )

  ALLOWED_VISIT_MAIN_NORMALIZE_METHODS = %w(
    type_cast_exception_call
    cant_pass_closure_to_c_exception_call
  )

  ENCODED_NODES = %w(
    Alias
    AlignOf
    And
    Annotation
    Arg
    ArrayLiteral
    Asm
    AsmOperand
    Assign
    AssignWithRestriction
    Block
    BoolLiteral
    Break
    Call
    Cast
    CharLiteral
    ClassDef
    ClassVar
    Def
    EnumDef
    ExceptionHandler
    Expressions
    External
    ExternalVar
    FileNode
    FunDef
    Generic
    Global
    HashLiteral
    If
    InstanceAlignOf
    InstanceSizeOf
    InstanceVar
    IsA
    LibDef
    Macro
    Metaclass
    MetaTypeVar
    MetaVar
    ModuleDef
    NamedArgument
    NamedTupleLiteral
    Next
    NilLiteral
    Nop
    NumberLiteral
    OffsetOf
    Out
    Path
    PointerOf
    Primitive
    ProcLiteral
    ProcPointer
    RangeLiteral
    ReadInstanceVar
    RegexLiteral
    Rescue
    RespondsTo
    Return
    Self
    SizeOf
    StringInterpolation
    StringLiteral
    SymbolLiteral
    TupleLiteral
    TypeNode
    TypeOf
    Unreachable
    Var
    While
    Yield
  )

  NEVER_TYPED = %w(
    AnnotationDef
    AssocTypeDecl
    BinaryOp
    CStructOrUnionDef
    Case
    ControlExpression
    Defer
    DoubleSplat
    Extend
    ImplicitObj
    ImplDef
    ImportDecl
    Include
    MacroExpression
    MacroFor
    MacroId
    MacroIf
    MacroLiteral
    MacroVar
    MacroVerbatim
    MagicConstant
    MetaMacroVar
    ModuleHeader
    MultiAssign
    NilableCast
    Not
    OpAssign
    Or
    ProcNotation
    Propagate
    Recover
    Require
    Select
    Splat
    TraitDef
    TupleIndexer
    TypeDeclaration
    TypeDef
    TypeFilteredNode
    UnaryExpression
    Underscore
    UninitializedVar
    Union
    Unless
    Until
    UsingDecl
    VisibilityModifier
    When
    YieldBlockBinder
  )

  ENCODED_TYPES = %w(
    AliasType
    AnnotationType
    AutocastType
    BoolType
    CharType
    ClassType
    Const
    EnumType
    FileModule
    FloatType
    GenericClassInstanceMetaclassType
    GenericClassInstanceType
    GenericClassType
    GenericInstanceType
    GenericModuleInstanceMetaclassType
    GenericModuleInstanceType
    GenericModuleType
    GenericReferenceStorageType
    GenericTraitType
    GenericUnionType
    IntegerType
    LibType
    MetaclassType
    MixedUnionType
    ModuleType
    NamedTupleInstanceType
    NamedTupleType
    NamedType
    NilType
    NilableProcType
    NilableReferenceUnionType
    NilableType
    NoReturnType
    NonGenericClassType
    NonGenericModuleType
    NumberAutocastType
    PointerInstanceType
    PointerType
    PrimitiveType
    ProcInstanceType
    ProcType
    Program
    ReferenceStorageType
    ReferenceUnionType
    StaticArrayInstanceType
    StaticArrayType
    SymbolAutocastType
    SymbolType
    TraitType
    TupleInstanceType
    TupleType
    TypeDefType
    TypeParameter
    TypeSplat
    UnionType
    VirtualMetaclassType
    VirtualType
    VoidType
  )

  macro check_completeness!
    {% begin %}
      # 1. Parity of visit restrictions between CodeGenVisitor and ReachWalk
      {% cg_restrictions = [] of String %}
      {% for m in Iyi::CodeGenVisitor.methods %}
        {% if m.name == "visit" %}
          {% cg_restrictions << m.args[0].restriction.stringify %}
        {% end %}
      {% end %}

      {% rw_restrictions = [] of String %}
      {% for m in Iyi::Stale::ReachWalk.methods %}
        {% if m.name == "visit" %}
          {% rw_restrictions << m.args[0].restriction.stringify %}
        {% end %}
      {% end %}

      {% for r in cg_restrictions %}
        {% unless rw_restrictions.includes?(r) %}
          {% raise "ReachWalk is missing visit restriction present in CodeGenVisitor: " + r %}
        {% end %}
      {% end %}

      {% for r in rw_restrictions %}
        {% unless cg_restrictions.includes?(r) %}
          {% raise "ReachWalk has extra visit restriction not present in CodeGenVisitor: " + r %}
        {% end %}
      {% end %}

      # 2. Location / end_location reads in CodeGenVisitor
      {% actual_location_methods = [] of String %}
      {% for m in Iyi::CodeGenVisitor.methods %}
        {% str = m.body.stringify %}
        {% if str.includes?(".location") || str.includes?(".end_location") %}
          {% unless actual_location_methods.includes?(m.name.stringify) %}
            {% actual_location_methods << m.name.stringify %}
          {% end %}
          {% unless ALLOWED_LOCATION_READ_METHODS.includes?(m.name.stringify) %}
            {% raise "Unallowed location/end_location read in CodeGenVisitor#" + m.name.stringify %}
          {% end %}
        {% end %}
      {% end %}

      {% for allowed in ALLOWED_LOCATION_READ_METHODS %}
        {% unless actual_location_methods.includes?(allowed) %}
          {% raise "Stale entry in ALLOWED_LOCATION_READ_METHODS: " + allowed %}
        {% end %}
      {% end %}

      # 3. visit_main / normalize in CodeGenVisitor
      {% actual_visit_main_methods = [] of String %}
      {% for m in Iyi::CodeGenVisitor.methods %}
        {% str = m.body.stringify %}
        {% if str.includes?("visit_main") || str.includes?("normalize") %}
          {% unless actual_visit_main_methods.includes?(m.name.stringify) %}
            {% actual_visit_main_methods << m.name.stringify %}
          {% end %}
          {% unless ALLOWED_VISIT_MAIN_NORMALIZE_METHODS.includes?(m.name.stringify) %}
            {% raise "Unallowed visit_main/normalize call in CodeGenVisitor#" + m.name.stringify %}
          {% end %}
        {% end %}
      {% end %}

      {% for allowed in ALLOWED_VISIT_MAIN_NORMALIZE_METHODS %}
        {% unless actual_visit_main_methods.includes?(allowed) %}
          {% raise "Stale entry in ALLOWED_VISIT_MAIN_NORMALIZE_METHODS: " + allowed %}
        {% end %}
      {% end %}
      # 4. ASTNode subclasses completeness
      {% for sub in Iyi::ASTNode.all_subclasses %}
        {% name = sub.name.stringify.split("::").last %}
        {% unless ENCODED_NODES.includes?(name) || NEVER_TYPED.includes?(name) %}
          {% raise "ASTNode subclass " + name + " is neither in ENCODED_NODES nor NEVER_TYPED" %}
        {% end %}
      {% end %}

      # 5. Type subclasses completeness
      {% for sub in Iyi::Type.all_subclasses %}
        {% name = sub.name.stringify.split("::").last %}
        {% unless ENCODED_TYPES.includes?(name) %}
          {% raise "Type subclass " + name + " is not in ENCODED_TYPES" %}
        {% end %}
      {% end %}
    {% end %}
  end
end

macro finished
  Iyi::Stale.check_completeness!
end
