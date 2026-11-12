require "../../spec_helper"

# Settled layout folds at the semantic level.
#
# A fold records itself while typing. Settling writes the final value into the
# literal the program holds, in place, so the expression node keeps its
# identity. Two things are never written: a literal a type variable adopted
# (a type was built from its value), and every fold in the same layout
# component as a kept type argument (so a dependent expression keeps the value
# its type was built from). A native program refuses a stale type argument
# with an error instead.

private def layout_fold_program(code : String, iyi_prelude : Bool = true, cleanup : Bool = true) : Iyi::Program
  program = Iyi::Program.new
  program.color = false
  program.iyi_prelude = iyi_prelude
  program.filename = File.expand_path("x.iyi")
  parser = program.new_parser(code)
  parser.filename = program.filename
  node = program.normalize(parser.parse)
  program.semantic node, cleanup: cleanup
  program
end

# A generic whose type argument is a layout fold. Its type variable adopts the
# folded literal, which is what makes the fold a type argument.
private def layout_fold_buf : String
  <<-CODE
    struct Buf(N)
      def initialize
      end
    end

    CODE
end

private def layout_fold_header : String
  <<-CODE
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

# Grows `M` after the folds above, so their values go stale.
private def layout_fold_growth : String
  "b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)\n"
end

# The fold of `sizeof({Int32, M})`, as a type argument or as a plain expression.
private def layout_fold_tuple(program : Iyi::Program, type_argument : Bool) : Iyi::LayoutFold
  program.layout_folds.values.find! do |fold|
    fold.kind == Iyi::LayoutFoldKind::Size && fold.subject.to_s.includes?("M") && fold.type_argument == type_argument
  end
end

describe "Semantic: layout folds" do
  describe "recording" do
    it "marks a fold inside a type argument and leaves a plain fold unmarked" do
      program = layout_fold_program(layout_fold_buf + "x = sizeof(Int32)\nbuf = Buf(sizeof(Int32)).new\n")

      type_args = program.layout_folds.values.select(&.type_argument)
      type_args.size.should eq 1
      type_args.first.subject.to_s.should eq "Int32"

      plain = program.layout_folds.values.select { |fold| !fold.type_argument && fold.kind == Iyi::LayoutFoldKind::Size }
      plain.size.should eq 1
      plain.first.subject.to_s.should eq "Int32"
    end

    it "marks no fold as a type argument when no fold sits in one" do
      program = layout_fold_program("x = sizeof(Int32)\nx\n")
      program.layout_folds.values.none?(&.type_argument).should be_true
    end
  end

  describe "settling" do
    it "writes a stale expression's final value into the literal the program holds, in place" do
      program = layout_fold_program(layout_fold_header + "s1 = sizeof({Int32, M})\n" + layout_fold_growth, cleanup: false)
      fold = layout_fold_tuple(program, false)
      fold.value.should eq 8_u64

      node = fold.node.as(Iyi::ExpandableNode)
      literal = node.expanded.as(Iyi::NumberLiteral)
      literal.value.should eq "8"

      program.settle_layout_folds(patch: true)

      # Same node, same literal object, new value: the write is in place.
      node.expanded.should be(literal)
      literal.value.should eq "32"
    end

    it "writes the final value in place under --crystal as well" do
      program = layout_fold_program(layout_fold_header + "s1 = sizeof({Int32, M})\n" + layout_fold_growth, iyi_prelude: false)
      fold = layout_fold_tuple(program, false)
      fold.node.as(Iyi::ExpandableNode).expanded.as(Iyi::NumberLiteral).value.should eq "32"
    end

    it "leaves a stable fold's literal unchanged" do
      program = layout_fold_program("x = sizeof(Int32)\nx\n")
      fold = program.layout_folds.values.find! { |f| f.kind == Iyi::LayoutFoldKind::Size && f.subject.to_s == "Int32" }
      literal = fold.node.as(Iyi::ExpandableNode).expanded.as(Iyi::NumberLiteral)
      literal.value.should eq "4"

      program.settle_layout_folds(patch: true)

      fold.node.as(Iyi::ExpandableNode).expanded.should be(literal)
      literal.value.should eq "4"
    end

    it "keeps the literal a type variable adopted, which no settle writes (--crystal)" do
      program = layout_fold_program(layout_fold_buf + layout_fold_header + "buf = Buf(sizeof({Int32, M})).new\n" + layout_fold_growth, iyi_prelude: false)

      use = program.layout_fold_uses.find! { |u| u.kind == Iyi::LayoutFoldUseKind::TypeArgument }
      read = use.reads.find!(&.adopted)
      type_arg = layout_fold_tuple(program, true)
      adopted_literal = type_arg.node.as(Iyi::ExpandableNode).expanded.as(Iyi::NumberLiteral)

      # The type variable took this very literal, and it still holds the value
      # its type was built from, though the final layout is 32.
      read.literal.should be(adopted_literal)
      read.value.should eq "8"
      adopted_literal.value.should eq "8"
    end

    it "keeps the expression tied to a kept type argument (P6, --crystal)" do
      program = layout_fold_program(layout_fold_buf + layout_fold_header + "e = sizeof({Int32, M})\n" + layout_fold_growth + "buf = Buf(sizeof({Int32, M})).new\n", iyi_prelude: false)

      tied = layout_fold_tuple(program, false)
      tied.node.as(Iyi::ExpandableNode).expanded.as(Iyi::NumberLiteral).value.should eq "8"

      type_arg = layout_fold_tuple(program, true)
      type_arg.node.as(Iyi::ExpandableNode).expanded.as(Iyi::NumberLiteral).value.should eq "8"
    end

    it "refuses a stale type argument under the native gate" do
      expect_raises(Iyi::TypeException, /when it was used as a type argument, but/) do
        layout_fold_program(layout_fold_buf + layout_fold_header + "buf = Buf(sizeof({Int32, M})).new\n" + layout_fold_growth)
      end
    end
  end

  describe "constants" do
    it "writes a constant's stale value in place" do
      # A constant is cleaned only once the cleanup meets a reference to it, so the program reads it.
      program = layout_fold_program(layout_fold_header + "CONST = sizeof({Int32, M})\nc = CONST\n" + layout_fold_growth)
      const = program.types["CONST"].as(Iyi::Const)
      const.value.should be_a(Iyi::NumberLiteral)
      const.value.as(Iyi::NumberLiteral).value.should eq "32"
    end

    it "keeps a stable constant's value" do
      program = layout_fold_program("CONST = sizeof(Int32)\nCONST\n")
      program.types["CONST"].as(Iyi::Const).value.as(Iyi::NumberLiteral).value.should eq "4"
    end
  end
end
