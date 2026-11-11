require "../../spec_helper"

# A layout fold read before it settles is judged by what the read built.
#
# Native: a use that builds a type argument, an enum value, a macro's output or
# a typing decision from a stale value is refused. A use whose result still
# comes out the same under the final layout is not.
#
# `--crystal`: nothing is refused. A stale use keeps the value Crystal 1.21.0
# gives it, and the layouts it read are pinned so their neighbours agree.
#
# A constant is cleaned only once the cleanup visits a reference to it
# (cleanup_transformer.cr:465), and a macro or a type argument reads a constant's
# value only once it is cleaned (layout_folds.cr:340, type_lookup.cr:342). So a
# read of a constant in the main code of the program that declares it sees the
# raw `sizeof`. Every fixture here therefore runs in two passes, as a finished
# top-level pass does: the first declares and uses the constants, which settles
# and cleans them, and the second is the program under test.
#
# Folds are found by identity (the literal a fold expanded to) or by the value it
# recorded when typed, never by the printed name of its subject: a tuple that
# holds a module is a struct whose sizeof subject prints differently from
# `{Int32, M}` (types.cr:879-887).

private def fold_use_program(iyi_prelude : Bool) : Program
  program = Program.new
  program.color = false
  program.iyi_prelude = iyi_prelude
  program.define_crystal_constants
  program
end

private def fold_use_semantic(program : Program, code : String, cleanup : Bool = true) : ASTNode
  program.semantic(program.normalize(parse(code)), cleanup: cleanup)
end

# A header that defines `M` and one implementor, with no `raise` of its own.
private def fold_use_module : String
  <<-CODE
    require "primitives"

    module M
    end

    struct G(T)
      include M

      def initialize(@v : T)
      end
    end

    a = G(Int8).new(1_i8).as(M)

    CODE
end

# Adds an implementor of `M` that is larger than any so far, so every layout
# fold of `M` goes stale.
private def fold_use_growth : String
  "b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)\n"
end

# The second pass: the main code `body`, then the cleanup-typing code. The
# exhaustive `case` makes the cleanup write a `raise(String)` for its unreachable
# branch, and the cleanup types the body of that user `raise`, so `raise_body`
# is typed after the main code and after the constants of the first pass are cleaned.
private def fold_use_cleanup_source(body : String, raise_body : String) : String
  <<-CODE
    enum Color
      Red
      Green
    end

    struct Enum
      def ==(other : self)
        value == other.value
      end
    end

    def raise(message : String) : NoReturn
      #{raise_body}
      while true
      end
    end

    #{body}
    c = Color::Red
    case c
    in .red?
      1
    in .green?
      2
    end
    CODE
end

# One program in two passes. The first declares the module, `constants`, and
# anything the second pass reads, and settles and cleans it. The second runs
# `body` and `raise_body`. Returns the second pass's node.
private def fold_use_two_passes(program : Program, constants : String, body : String, raise_body : String) : ASTNode
  fold_use_semantic(program, fold_use_module + constants)
  fold_use_semantic(program, fold_use_cleanup_source(body, raise_body))
end

# Declares `X` in the first pass and uses it, so the first pass cleans it.
private def fold_use_x : String
  "X = sizeof({Int32, M})\nx = X\n"
end

# `X` folds to 8 and is 32 after growth. `Y` derives from it. Both are used, so
# both are cleaned in the first pass.
private def fold_use_derived : String
  fold_use_x + "Y = X &+ 1\ny = Y\n"
end

# A single-pass program, for fixtures that read no constant in main code.
private def fold_use_source(body : String, raise_body : String = "") : String
  fold_use_module + fold_use_cleanup_source(body, raise_body)
end

private def fold_use_const(program : Program, name : String) : Const
  program.types[name].as(Const)
end

private def fold_use_literal(program : Program, name : String) : NumberLiteral
  fold_use_const(program, name).value.as(NumberLiteral)
end

# The fold whose expansion is `literal`, by identity. Nil when no recorded fold
# expanded to that object, which is itself a finding.
private def fold_use_fold_of(program : Program, literal : NumberLiteral) : LayoutFold?
  program.layout_folds.values.find { |fold| fold.node.as(ExpandableNode).expanded.try(&.same?(literal)) }
end

# The `sizeof` folds that recorded `value` when typed, in the order typing recorded
# them. Matched by the value measured, since the printed subject is not stable.
private def fold_use_size_folds(program : Program, value : UInt64) : Array(LayoutFold)
  program.layout_folds.values.select { |fold| fold.kind == LayoutFoldKind::Size && fold.value == value }
end

private def fold_use_static_array(program : Program, size : Int32) : GenericInstanceType
  program.static_array_of(program.types["UInt8"], size).as(GenericInstanceType)
end

# Every number a generic instance holds as a type variable, found the way
# `Program` walks its own types.
private def fold_use_type_variables(type : Type, found : Array(NumberLiteral)) : Nil
  nested_types = type.types?
  return unless nested_types

  nested_types.each_value do |nested|
    if nested.is_a?(GenericType)
      nested.each_instantiated_type do |instance|
        next unless instance.is_a?(GenericInstanceType)
        instance.type_vars.each_value { |var| found << var if var.is_a?(NumberLiteral) }
      end
    end
    fold_use_type_variables(nested, found)
  end
end

# Control 13: a type variable that is a layout fold literal is always backed by an
# adopted read, so no literal can be held without a use that justified it.
private def fold_use_census(program : Program) : Nil
  found = [] of NumberLiteral
  fold_use_type_variables(program, found)
  program.file_modules.each_value { |file_module| fold_use_type_variables(file_module, found) }

  found.each do |literal|
    next unless program.layout_fold_of(literal)

    adopted = program.layout_fold_uses.any? do |use|
      use.reads.any? { |read| read.literal.same?(literal) && read.adopted }
    end
    adopted.should be_true
  end
end

describe "Semantic: layout fold uses" do
  describe "native" do
    it "refuses a derived type argument whose input moved (control 1)" do
      program = fold_use_program(true)
      expect_raises(Iyi::TypeException, /when it was used as a type argument, but/) do
        fold_use_two_passes(program, fold_use_derived, "", fold_use_growth + "buf = StaticArray(UInt8, Y).new\n")
      end
    end

    it "does not refuse a derived type argument whose result is still equal (control 4)" do
      program = fold_use_program(true)
      # `&*` by zero reads X and gives 0 whatever X is, so W is 4 both before and
      # after growth.
      fold_use_two_passes(program, fold_use_x + "W = X &* 0 &+ 4\nw = W\n", "", fold_use_growth + "buf = StaticArray(UInt8, W).new\n")

      fold_use_literal(program, "X").value.should eq "32"
      fold_use_const(program, "W").compile_time_value.should eq 4
      fold_use_census(program)
    end

    it "does not refuse a value that no type, enum, macro or typing decision takes (control 3)" do
      program = fold_use_program(true)
      fold_use_two_passes(program, fold_use_derived, "", fold_use_growth)

      fold_use_literal(program, "X").value.should eq "32"
      fold_use_const(program, "Y").compile_time_value.should eq 33
      fold_use_census(program)
    end

    it "refuses a type argument that is the fold's own copy (control 5)" do
      program = fold_use_program(true)
      expect_raises(Iyi::TypeException, /when it was used as a type argument, but/) do
        fold_use_two_passes(program, fold_use_x, "", fold_use_growth + "buf = StaticArray(UInt8, X).new\n")
      end
    end

    it "refuses a def return type built from a stale constant (control 6)" do
      program = fold_use_program(true)
      body = "def make : StaticArray(UInt8, Y)\n  StaticArray(UInt8, 9).new\nend\n"
      expect_raises(Iyi::TypeException, /when it was used as a type argument, but/) do
        fold_use_two_passes(program, fold_use_derived, body, fold_use_growth + "make\n")
      end
    end

    it "refuses a macro whose output a stale read of a cleaned constant gives (control 7)" do
      program = fold_use_program(true)
      # The macro is in the `raise` the cleanup types, after the growth. It reads
      # the cleaned X, so its output `8` differs from `32`.
      expect_raises(Iyi::TypeException, /a macro read/) do
        fold_use_two_passes(program, fold_use_x, "", fold_use_growth + "z = {{ X }}\n")
      end
    end

    it "does not refuse a macro whose output is the same under the final layout (control 7, same output)" do
      program = fold_use_program(true)
      # The macro's output is 0 whatever X is.
      fold_use_two_passes(program, fold_use_x, "", fold_use_growth + "z = {{ X * 0 }}\n")

      fold_use_literal(program, "X").value.should eq "32"
      fold_use_census(program)
    end

    it "does not refuse a macro that reads a changed value and never uses it (control 7, unused read)" do
      program = fold_use_program(true)
      # The macro reads X into a macro variable and never uses it, so its output
      # `1` is the same whatever X is. Only a read whose value is consumed can differ.
      fold_use_two_passes(program, fold_use_x, "", fold_use_growth + "{% unused = X %}\nz = {{ 1 }}\n")

      fold_use_literal(program, "X").value.should eq "32"
      fold_use_census(program)
    end

    it "does not refuse a macro with an external effect in an unchosen branch (effects in unchosen branch)" do
      program = fold_use_program(true)
      # The macro has an external command in the unchosen branch, but X * 0 == 0 is always true,
      # so the unchosen branch is never evaluated during settlement and output remains 42.
      macro_code = <<-CODE
        {% if X * 0 == 0 %}
          z = 42
        {% else %}
          z = {{ `echo should_never_run` }}
        {% end %}
        CODE
      fold_use_two_passes(program, fold_use_x, "", fold_use_growth + macro_code)

      fold_use_literal(program, "X").value.should eq "32"
      fold_use_census(program)
    end

    it "does not refuse a macro with nested pure calls producing the same output (nested calls)" do
      program = fold_use_program(true)
      # Nested arithmetic calls where output is always 0.
      fold_use_two_passes(program, fold_use_x, "", fold_use_growth + "z = {{ (X * 0) + (X - X) }}\n")

      fold_use_literal(program, "X").value.should eq "32"
      fold_use_census(program)
    end

    it "does not refuse a macro with a loop producing the same output (loops)" do
      program = fold_use_program(true)
      # Loop over a range whose output depends on X * 0 (always 0).
      macro_code = <<-CODE
        {% for i in 0...2 %}
          v_{{ i }} = {{ X * 0 }}
        {% end %}
        CODE
      fold_use_two_passes(program, fold_use_x, "", fold_use_growth + macro_code)

      fold_use_literal(program, "X").value.should eq "32"
      fold_use_census(program)
    end

    it "refuses, without running it, a command the final layout reaches (command not run during settlement)" do
      program = fold_use_program(true)
      sentinel = "/tmp/iyi_test_sentinel_#{Process.pid}_#{Time.utc.to_unix_ms}"
      begin
        # During typing X was 8, so X == 8 was true and output was 1.
        # Under final layout X is 32, so X == 8 is false and settlement enters the branch
        # with `touch sentinel`. The guard must report unknown and refuse before executing the command.
        macro_code = <<-CODE
          {% if X == 8 %}
            z = 1
          {% else %}
            z = {{ `touch #{sentinel}` }}
          {% end %}
          CODE
        expect_raises(Iyi::TypeException, /can't be known without running it again: it reaches/) do
          fold_use_two_passes(program, fold_use_x, "", fold_use_growth + macro_code)
        end
        File.exists?(sentinel).should be_false
      ensure
        File.delete(sentinel) if File.exists?(sentinel)
      end
    end

    it "does not falsely refuse safe macro logic producing the same output (no false positives)" do
      program = fold_use_program(true)
      # Safe conditional and arithmetic producing identical output under both layouts.
      macro_code = <<-CODE
        {% if X >= 8 %}
          val = {{ (X // X) * 10 }}
        {% else %}
          val = 0
        {% end %}
        CODE
      fold_use_two_passes(program, fold_use_x, "", fold_use_growth + macro_code)

      fold_use_literal(program, "X").value.should eq "32"
      fold_use_census(program)
    end

    # The replay controls below each fail if the replay keeps a stale value, asks the program a
    # question whose answer has moved since the expansion, or makes something.

    it "replays with the final value of a layout the expansion never read (accepts the same output)" do
      program = fold_use_program(true)
      # The expansion took the first branch and never read W. Under the final layout it takes the
      # second, where W is 32 and the output is still 4. With W left at 8 the replay would say 1.
      macro_code = <<-CODE
        {% if X == 8 %}
          z = 4
        {% else %}
          z = {{ W // 8 }}
        {% end %}
        CODE
      fold_use_two_passes(program, fold_use_x + "W = sizeof({Int32, M})\nw = W\n", "", fold_use_growth + macro_code)

      fold_use_literal(program, "X").value.should eq "32"
      # The expansion is the one macro use. The replay read X and W again and recorded neither.
      program.layout_fold_uses.count(&.kind.macro?).should eq 1
    end

    it "replays with the final value of a layout the expansion never read (refuses a changed output)" do
      program = fold_use_program(true)
      # Under the final layout the second branch runs and W is 32, so the output is 2, not 1.
      macro_code = <<-CODE
        {% if X == 8 %}
          z = 1
        {% else %}
          z = {{ W == 8 ? 1 : 2 }}
        {% end %}
        CODE
      expect_raises(Iyi::TypeException, /A macro's output can't be corrected/) do
        fold_use_two_passes(program, fold_use_x + "W = sizeof({Int32, M})\nw = W\n", "", fold_use_growth + macro_code)
      end
    end

    it "replays a constant whose value holds the layout under a node of any kind" do
      program = fold_use_program(true)
      # Y's value is a conditional over the fold. The macro prints it, so its output changes with X.
      expect_raises(Iyi::TypeException, /A macro's output can't be corrected/) do
        fold_use_two_passes(program, fold_use_x + "Y = sizeof({Int32, M}) == 8 ? 1 : 2\ny = Y\n", "", fold_use_growth + "z = {{ Y }}\n")
      end
    end

    it "refuses a macro that asks what a type holds, which has moved since it ran" do
      program = fold_use_program(true)
      # When `pick` ran, Foo had no `Later`, so X == 8 chose the branch. By settling Foo has one,
      # and a replay that asked would take the first branch for another reason and call it unchanged.
      body = <<-CODE
        macro pick
          {% if @type.has_constant?("Later") || X == 8 %}
            A = 1
          {% else %}
            A = 2
          {% end %}
        end

        class Foo
          pick
          Later = 0
        end
        CODE
      expect_raises(Iyi::TypeException, /could not show that the macro's output is unchanged: it calls `has_constant\?`/) do
        fold_use_two_passes(program, fold_use_x, body, fold_use_growth)
      end
    end

    it "refuses a macro whose replay would name a type, and makes none" do
      program = fold_use_program(true)
      macro_code = <<-CODE
        {% if X == 8 %}
          z = 1
        {% else %}
          z = {{ G({Int64, Int64, Int64}).struct? ? 1 : 2 }}
        {% end %}
        CODE
      expect_raises(Iyi::TypeException, /looking that up could create it/) do
        fold_use_two_passes(program, fold_use_x, "", fold_use_growth + macro_code)
      end
      generic = program.types["G"].as(Iyi::GenericType)
      generic.generic_types.values.map(&.to_s).should_not contain("G(Tuple(Int64, Int64, Int64))")
    end

    it "keeps the read of a macro that left by `skip_file`" do
      program = fold_use_program(true)
      # The macro runs at the top level, where X still reads 8, and skips the rest of the file. The
      # main code then grows M. The expansion gave no output to replay, and the skip stands, so the
      # stale read is refused.
      expect_raises(Iyi::TypeException, /a macro read/) do
        fold_use_two_passes(program, fold_use_x, fold_use_growth + "{% skip_file if X == 8 %}\nz = 1\n", "")
      end
    end

    it "refuses a tuple index that a stale constant selects (control 8)" do
      program = fold_use_program(true)
      expect_raises(Iyi::TypeException, /typing read/) do
        fold_use_two_passes(program, fold_use_x, "", fold_use_growth + "t = {1, 2, 3, 4, 5, 6, 7, 8, 9}\nt[X]\n")
      end
    end

    # The form the plan names, `Foo(sizeof({Int32, M}) &+ 1)`, is not reachable:
    # type arguments take no operators, and a sizeof inside `typeof(...)` in a
    # type argument is never recorded as a fold (main_visitor.cr:3223-3247). So the
    # computed size is held in a constant, and the type argument reads its type.
    it "does not refuse a type built from a computed fold's type, whose value no type takes (control 9)" do
      program = fold_use_program(true)
      fold_use_two_passes(program, "N = sizeof({Int32, M}) &+ 1\nn = N\n", "struct Foo(T)\nend\nf = Foo(typeof(N)).new\n", fold_use_growth)

      folds = fold_use_size_folds(program, 8_u64)
      folds.size.should eq 1
      folds.last.node.as(ExpandableNode).expanded.as(NumberLiteral).value.should eq "32"
      fold_use_census(program)
    end

    it "does not refuse a temporary copy used only as a value (temp)" do
      program = fold_use_program(true)
      fold_use_semantic(program, fold_use_source("X = sizeof({Int32, M})\nt = X &+ 1\nu = t\n", fold_use_growth))

      fold_use_literal(program, "X").value.should eq "32"
      fold_use_census(program)
    end

    it "refuses a nested derivation whose input moved (nested)" do
      program = fold_use_program(true)
      # Z derives from Y, which derives from X. Each step is a constant read by
      # name, so no parentheses are needed.
      constants = fold_use_derived + "Z = Y &* 2\nz = Z\n"
      expect_raises(Iyi::TypeException, /when it was used as a type argument, but/) do
        fold_use_two_passes(program, constants, "", fold_use_growth + "buf = StaticArray(UInt8, Z).new\n")
      end
    end

    it "writes nothing when it refuses, and names the measured value (error)" do
      program = fold_use_program(true)
      error = expect_raises(Iyi::TypeException, /when it was used as a type argument, but/) do
        fold_use_two_passes(program, fold_use_derived, "", fold_use_growth + "buf = StaticArray(UInt8, Y).new\n")
      end

      fold_use_literal(program, "X").value.should eq "8"
      error.inner.try(&.message).to_s.should contain "measured 8 here"
    end

    it "refuses an adopted literal that is still stale (control 10, adoption)" do
      program = fold_use_program(true)
      # X is cleaned in the first pass, so the second pass's type argument adopts
      # the very literal the constant holds. Growth in the second pass makes it stale.
      expect_raises(Iyi::TypeException, /when it was used as a type argument, but/) do
        fold_use_two_passes(program, fold_use_x, "", fold_use_growth + "buf = StaticArray(UInt8, X).new\n")
      end
    end

    it "accepts an adopted literal that was corrected before it was adopted (control 10, adoption after correction)" do
      program = fold_use_program(true)
      fold_use_semantic(program, fold_use_module + fold_use_x + fold_use_growth)

      literal = fold_use_literal(program, "X")
      literal.value.should eq "32"
      fold_use_fold_of(program, literal).should_not be_nil

      fold_use_semantic(program, fold_use_cleanup_source("", "buf = StaticArray(UInt8, X).new\n"))

      literal.value.should eq "32"
      fold_use_static_array(program, 32).type_vars["N"].should be(literal)
      fold_use_census(program)
    end

    it "accepts a fresh use of the corrected value made after the first settle (control 10, fresh use)" do
      program = fold_use_program(true)
      fold_use_semantic(program, fold_use_module + "x = sizeof({Int32, M})\n" + fold_use_growth, cleanup: false)
      program.settle_layout_folds(patch: true)

      # A sizeof in main code is typed, and so recorded, with the value it measured
      # before growth. A constant is typed only when a use reaches it, so an unused
      # `X = sizeof(...)` records no fold here, which is why this is a plain expression.
      literal = fold_use_size_folds(program, 8_u64).last.node.as(ExpandableNode).expanded.as(NumberLiteral)
      literal.value.should eq "32"

      fold_use_semantic(program, "buf = StaticArray(UInt8, sizeof({Int32, M})).new\n", cleanup: false)
      program.settle_layout_folds(patch: true)

      # The fresh use measured 32 when typed, after growth. It is recorded with 32, so
      # it is judged fresh: no refusal, and the first literal stays 32.
      fresh = fold_use_size_folds(program, 32_u64)
      fresh.empty?.should be_false
      fresh.last.node.as(ExpandableNode).expanded.as(NumberLiteral).value.should eq "32"
      literal.value.should eq "32"
      fold_use_census(program)
    end

    it "refuses an enum value computed from a stale constant (control 11)" do
      program = fold_use_program(true)
      first, first_processor = program.top_level_semantic(program.normalize(parse(fold_use_module + fold_use_x)))
      program.semantic_after_top_level(first, first_processor)

      second, second_processor = program.top_level_semantic(program.normalize(parse("enum E\n  A = X\nend\n" + fold_use_growth + "e = E::A\n")))
      expect_raises(Iyi::TypeException, /enum value/) do
        program.semantic_after_top_level(second, second_processor)
      end
    end
  end

  describe "--crystal" do
    it "keeps the value a derived type argument read and pins its input (control 2)" do
      program = fold_use_program(false)
      fold_use_two_passes(program, fold_use_derived, "", fold_use_growth + "buf = StaticArray(UInt8, Y).new\n")

      fold_use_literal(program, "X").value.should eq "8"
      fold_use_const(program, "Y").compile_time_value.should eq 9
      fold_use_static_array(program, 9).type_vars["N"].as(NumberLiteral).value.should eq "9"
      fold_use_census(program)
    end

    it "keeps a type argument's literal, and the copy of it, tied together (control 5)" do
      program = fold_use_program(false)
      fold_use_two_passes(program, fold_use_x, "", fold_use_growth + "buf = StaticArray(UInt8, X).new\n")

      literal = fold_use_literal(program, "X")
      literal.value.should eq "8"
      fold_use_static_array(program, 8).type_vars["N"].should be(literal)
      fold_use_census(program)
    end

    it "does not refuse a stale def return type, and keeps its input (control 6, crystal)" do
      program = fold_use_program(false)
      body = "def make : StaticArray(UInt8, Y)\n  StaticArray(UInt8, 9).new\nend\n"
      fold_use_two_passes(program, fold_use_derived, body, fold_use_growth + "make\n")

      fold_use_literal(program, "X").value.should eq "8"
    end

    it "does not refuse a stale macro after cleanup, and keeps its input (control 7, crystal)" do
      program = fold_use_program(false)
      fold_use_two_passes(program, fold_use_x, "", fold_use_growth + "z = {{ X }}\n")

      fold_use_literal(program, "X").value.should eq "8"
    end

    it "does not refuse a stale tuple index after cleanup, and keeps its input (control 8, crystal)" do
      program = fold_use_program(false)
      fold_use_two_passes(program, fold_use_x, "", fold_use_growth + "t = {1, 2, 3, 4, 5, 6, 7, 8, 9}\nt[X]\n")

      fold_use_literal(program, "X").value.should eq "8"
    end

    it "keeps an adopted stale literal and the type argument that holds it (control 10, crystal)" do
      program = fold_use_program(false)
      fold_use_two_passes(program, fold_use_x, "", fold_use_growth + "buf = StaticArray(UInt8, X).new\n")

      literal = fold_use_literal(program, "X")
      literal.value.should eq "8"
      fold_use_static_array(program, 8).type_vars["N"].should be(literal)
      fold_use_census(program)
    end

    it "keeps the enum value and the constant it was computed from (control 11, crystal)" do
      program = fold_use_program(false)
      first, first_processor = program.top_level_semantic(program.normalize(parse(fold_use_module + fold_use_x)))
      program.semantic_after_top_level(first, first_processor)

      second, second_processor = program.top_level_semantic(program.normalize(parse("enum E\n  A = X\nend\n" + fold_use_growth + "e = E::A\n")))
      program.semantic_after_top_level(second, second_processor)

      fold_use_literal(program, "X").value.should eq "8"
      program.types["E"].as(EnumType).types["A"].as(Const).compile_time_value.should eq 8
    end

    it "keeps a nested derivation's input and computes its value from it (nested, crystal)" do
      program = fold_use_program(false)
      constants = fold_use_derived + "Z = Y &* 2\nz = Z\n"
      fold_use_two_passes(program, constants, "", fold_use_growth + "buf = StaticArray(UInt8, Z).new\n")

      fold_use_literal(program, "X").value.should eq "8"
      fold_use_const(program, "Z").compile_time_value.should eq 18
      fold_use_census(program)
    end

    it "reports each stale use it keeps, and pins the expression fold that shares its layout (control 12)" do
      previous = ENV["IYI_LAYOUT_FOLD_REPORT"]?
      ENV["IYI_LAYOUT_FOLD_REPORT"] = "1"
      begin
        program = fold_use_program(false)
        # `s` is a second expression fold of the same layout as X. It is not a use,
        # so it is pinned only because it shares the component that the type
        # argument through Y pins.
        fold_use_two_passes(program, fold_use_derived, "s = sizeof({Int32, M})\n", fold_use_growth + "buf = StaticArray(UInt8, Y).new\n")

        program.layout_fold_lines.any?(&.includes?("layout fold use stale")).should be_true

        literal_x = fold_use_literal(program, "X")
        fold_x = fold_use_fold_of(program, literal_x)
        fold_x.should_not be_nil

        # Every fold measured 8 when typed: X's and `s`'s. `s` is the one that is not X's.
        folds = fold_use_size_folds(program, 8_u64)
        folds.size.should be >= 2
        shared = folds.reject { |fold| fold.node.same?(fold_x.not_nil!.node) }.last
        shared.node.as(ExpandableNode).expanded.as(NumberLiteral).value.should eq "8"
        literal_x.value.should eq "8"

        # One line per distinct judgement. X is read by the harmful type-argument use,
        # so its line names that use. `s` is read by no use: it is pinned only through
        # the component it shares with X, so its line is the tie. The harmful use has
        # its own line.
        lines = program.layout_fold_lines
        lines.count(&.includes?("in const: folded 8, final 32: kept (type argument)")).should eq 1
        lines.count(&.includes?("in main: folded 8, final 32: kept (tied to type argument at")).should eq 1
        lines.count(&.includes?("layout fold use stale:")).should eq 1
        lines.count { |line| line.includes?("layout fold use stale:") && line.includes?("type argument read") }.should eq 1
      ensure
        if previous
          ENV["IYI_LAYOUT_FOLD_REPORT"] = previous
        else
          ENV.delete("IYI_LAYOUT_FOLD_REPORT")
        end
      end
    end
  end
end
