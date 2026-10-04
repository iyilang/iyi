# A VirtualFile is used as a Location's filename when
# expanding a macro. It contains the macro expanded source
# code so the user can debug it as if there was a file in the
# filesystem with those contents.
class Iyi::VirtualFile
  # The macro that produced this VirtualFile
  getter macro : Macro

  # The expanded source code of the macro
  getter source : String

  # The location where the macro was expanded (where the macro was invoked).
  getter expanded_location : Location?

  # iyi: for an inline macro, the line of the file each line of the
  # expansion was written on, where it was text rather than an expression's
  # output. `__LINE__` - and `raise`'s default argument, which is one - read
  # it: without it a panic inside `{% if flag?(:win32) %}` named the
  # `{% if` line, which is where the expansion was put rather than where the
  # `raise` is.
  property line_origins : Hash(Int32, Int32)? = nil

  # iyi: how many expansions this one sits inside, itself included: 1 for a
  # macro called from a file. A macro that expands to a call of itself, or
  # of one that calls it back, never stops expanding, and nothing counted:
  # `macro m(x)` holding `m({{ x }})` ran the compiler into a stack overflow
  # after 5 to 17 seconds, in `Lexer.iyi_source?`, which walks this chain.
  # `Program#parse_macro_source` refuses an expansion deeper than
  # `DEPTH_LIMIT`.
  getter depth : Int32

  # Far past any expansion that ends, and short of the stack: a self-call
  # ran out near 4,900 levels, and an `inherited` hook whose class sets it
  # off again, which nests a namespace and a superclass each time, near 125.
  DEPTH_LIMIT = 64

  def initialize(@macro : Macro, @source : String, @expanded_location : Location?)
    outer = @expanded_location.try(&.filename)
    @depth = outer.is_a?(VirtualFile) ? outer.depth + 1 : 1
  end

  def to_s(io : IO) : Nil
    io << "expanded macro: " << @macro.name
  end

  def inspect(io : IO) : Nil
    to_s(io)
  end

  def pretty_print(pp)
    pp.text inspect
  end
end
