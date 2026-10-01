require "./semantic_visitor"

# Interprets math expressions like 1 + 2 for enum values and
# constant values that are being used for the N of a StaticArray.
struct Iyi::MathInterpreter
  def initialize(@path_lookup : Type, @visitor : SemanticVisitor? = nil, @target_type : IntegerType? = nil)
  end

  def interpret(node : NumberLiteral)
    case node.kind
    when .signed_int?, .unsigned_int?
      target_kind = @target_type.try(&.kind) || node.kind
      case target_kind
      when .i8?   then node.value.to_i8? || node.raise "invalid Int8: #{node.value}"
      when .u8?   then node.value.to_u8? || node.raise "invalid UInt8: #{node.value}"
      when .i16?  then node.value.to_i16? || node.raise "invalid Int16: #{node.value}"
      when .u16?  then node.value.to_u16? || node.raise "invalid UInt16: #{node.value}"
      when .i32?  then node.value.to_i32? || node.raise "invalid Int32: #{node.value}"
      when .u32?  then node.value.to_u32? || node.raise "invalid UInt32: #{node.value}"
      when .i64?  then node.value.to_i64? || node.raise "invalid Int64: #{node.value}"
      when .u64?  then node.value.to_u64? || node.raise "invalid UInt64: #{node.value}"
      when .i128? then node.value.to_i128? || node.raise "invalid Int128: #{node.value}"
      when .u128? then node.value.to_u128? || node.raise "invalid UInt128: #{node.value}"
      else
        node.raise "enum type must be an integer, not #{target_kind}"
      end
    else
      node.raise "constant value must be an integer, not #{node.kind}"
    end
  end

  def interpret(node : Call)
    obj = node.obj
    if obj
      if obj.is_a?(Path)
        value = interpret_call_macro?(node)
        return value if value
      end

      case node.args.size
      when 0
        left = interpret(obj)

        case node.name
        when "+" then +left
        when "-"
          case left
          when Int8   then -left
          when Int16  then -left
          when Int32  then -left
          when Int64  then -left
          when Int128 then -left
          else
            interpret_call_macro(node)
          end
        when "~" then ~left
        else
          interpret_call_macro(node)
        end
      when 1
        left = interpret(obj)
        right = interpret(node.args.first)
        iyi = MathInterpreter.iyi_rules?(@path_lookup.program, node.location)

        case node.name
        when "+"  then left + right
        when "-"  then left - right
        when "*"  then left * right
        when "&+" then left &+ right
        when "&-" then left &- right
        when "&*" then left &* right
          # MathInterpreter only works with Integer and left / right : Float
          # when "/"  then left / right
        when "//" then iyi ? left.tdiv(right) : left // right
        when "&"  then left & right
        when "|"  then left | right
        when "^"  then left ^ right
        when "<<" then iyi ? MathInterpreter.iyi_shl(left, right) : left << right
        when ">>" then iyi ? MathInterpreter.iyi_shr(left, right) : left >> right
        when "%"  then iyi ? left.remainder(right) : left % right
        else
          interpret_call_macro(node)
        end
      else
        node.raise "invalid constant value"
      end
    else
      interpret_call_macro(node)
    end
  rescue ex : OverflowError | DivisionByZeroError
    node.raise ex.message
  end

  def interpret_call_macro(node : Call)
    interpret_call_macro?(node) ||
      node.raise("invalid constant value")
  end

  # iyi: an operator folded at compile time answers what it answers at run
  # time, so a constant, an enum value, a StaticArray size and a macro say
  # the same as the line that computes it. The folding used the host's
  # operators, which are the other library's: `X = -7 // 2` was -4,
  # `-7 % 2` was 1 and `8 << -1` was 4, where iyi's integers (number.iyi,
  # std/int.iyi) truncate, take the dividend's sign and answer 0 for a
  # negative count: -3, -1 and 0. That held for every constant, because
  # codegen folds any integer constant it can. A source of the other
  # language, or one built against the other library (`--crystal`), runs
  # that library's operators and keeps its rules.
  def self.iyi_rules?(program : Program, location : Location?) : Bool
    program.iyi_prelude? && Lexer.iyi_source?(location.try(&.filename))
  end

  # A count below zero or past the width shifts every bit out.
  def self.iyi_shl(value : Int, count : Int)
    count < 0 || count >= sizeof(typeof(value)) * 8 ? value.class.zero : value.unsafe_shl(count)
  end

  # The same, and a negative value keeps its sign bit: -1.
  def self.iyi_shr(value : Int, count : Int)
    if count < 0 || count >= sizeof(typeof(value)) * 8
      value < 0 ? ~value.class.zero : value.class.zero
    else
      value.unsafe_shr(count)
    end
  end

  def interpret_call_macro?(node : Call)
    visitor = @visitor
    return unless visitor

    if node.global?
      node.scope = visitor.program
    else
      node.scope = visitor.scope? || visitor.current_type.metaclass
    end

    if visitor.expand_macro(node, raise_on_missing_const: false, first_pass: true)
      return interpret(node.expanded.not_nil!)
    end

    nil
  end

  def interpret(node : Path)
    type = @path_lookup.lookup_type_var(node)
    case type
    when Const
      interpret(type.value)
    else
      node.raise "invalid constant value"
    end
  end

  def interpret(node : Expressions)
    if node.expressions.size == 1
      interpret(node.expressions.first)
    else
      node.raise "invalid constant value"
    end
  end

  def interpret(node : ASTNode)
    node.raise "invalid constant value"
  end
end
