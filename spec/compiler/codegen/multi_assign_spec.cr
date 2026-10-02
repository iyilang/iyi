require "../../spec_helper"

describe "Code gen: multi assign" do
  it "supports n to n assignment" do
    run(<<-CODE).to_i.should eq(123)
      a, b, c = 1, 2, 3
      a &* 100 &+ b &* 10 &+ c
      CODE
  end

  context "without strict_multi_assign" do
    it "supports 1 to n assignment" do
      run(<<-CODE).to_i.should eq(123)
        class Foo
          def [](index)
            index &+ 1
          end
        end

        a, b, c = Foo.new
        a &* 100 &+ b &* 10 &+ c
        CODE
    end

    it "doesn't raise if value size in 1 to n assignment doesn't match target count" do
      run(<<-CODE).to_i.should eq(4)
        require "prelude"

        begin
          a, b = [1, 2, 3]
          4
        rescue ex : Exception
          raise ex unless ex.message == "Multiple assignment count mismatch"
          5
        end
        CODE
    end
  end

  context "strict_multi_assign" do
    it "supports 1 to n assignment" do
      run(<<-CODE, flags: %w(strict_multi_assign)).to_i.should eq(123)
        require "prelude"

        class Foo
          include Indexable(Int32)

          def unsafe_fetch(index)
            index &+ 1
          end

          def size
            3
          end
        end

        a, b, c = Foo.new
        a &* 100 &+ b &* 10 &+ c
        CODE
    end

    it "raises if value size in 1 to n assignment doesn't match target count" do
      run(<<-CODE, flags: %w(strict_multi_assign)).to_i.should eq(5)
        require "prelude"

        begin
          a, b = [1, 2, 3]
          4
        rescue ex : Exception
          raise ex unless ex.message == "Multiple assignment count mismatch"
          5
        end
        CODE
    end
  end

  it "supports m to n assignment, with splat on left-hand side (1)" do
    run(<<-CODE).to_i.should eq(12345)
      #{tuple_new}

      a, *b, c = 1, 2, 3, 4, 5
      a &* 10000 &+ b[0] &* 1000 &+ b[1] &* 100 &+ b[2] &* 10 &+ c
      CODE
  end

  it "supports m to n assignment, with splat on left-hand side (2)" do
    run(<<-CODE).to_i.should eq(12345)
      #{tuple_new}

      *a, b, c = 1, 2, 3, 4, 5
      a[0] &* 10000 &+ a[1] &* 1000 &+ a[2] &* 100 &+ b &* 10 &+ c
      CODE
  end

  it "supports m to n assignment, with splat on left-hand side (3)" do
    run(<<-CODE).to_i.should eq(12345)
      #{tuple_new}

      a, b, *c = 1, 2, 3, 4, 5
      a &* 10000 &+ b &* 1000 &+ c[0] &* 100 &+ c[1] &* 10 &+ c[2]
      CODE
  end

  it "supports m to n assignment, splat is empty tuple (1)" do
    run(<<-CODE).to_b.should be_true
      #{tuple_new}

      _, *x, _ = 1, 2
      x.is_a?(Tuple())
      CODE
  end

  it "supports m to n assignment, splat is empty tuple (2)" do
    run(<<-CODE).to_b.should be_true
      #{tuple_new}

      *x, _, _ = 1, 2
      x.is_a?(Tuple())
      CODE
  end

  it "supports m to n assignment, splat is empty tuple (3)" do
    run(<<-CODE).to_b.should be_true
      #{tuple_new}

      _, _, *x = 1, 2
      x.is_a?(Tuple())
      CODE
  end

  # iyi: the splat's tuple is a literal, so it needs no `Tuple.new`, which
  # iyi's prelude does not have.
  it "supports m to n assignment with a splat where nothing defines Tuple.new" do
    run(<<-CODE).to_b.should be_true
      a, *b, c = 1, 2, 3, 4
      b.is_a?(Tuple(Int32, Int32))
      CODE
  end

  it "supports 1 to n assignment, with splat on left-hand side (1)" do
    run(<<-CODE).to_i.should eq(12345)
      require "prelude"

      a, *b, c = {1, 2, 3, 4, 5}
      a &* 10000 &+ b[0] &* 1000 &+ b[1] &* 100 &+ b[2] &* 10 &+ c
      CODE
  end

  it "supports 1 to n assignment, with splat on left-hand side (2)" do
    run(<<-CODE).to_i.should eq(12345)
      #{range_new}
      #{include_indexable}

      *a, b, c = {1, 2, 3, 4, 5}
      a[0] &* 10000 &+ a[1] &* 1000 &+ a[2] &* 100 &+ b &* 10 &+ c
      CODE
  end

  it "supports 1 to n assignment, with splat on left-hand side (3)" do
    run(<<-CODE).to_i.should eq(12345)
      #{range_new}
      #{include_indexable}

      a, b, *c = {1, 2, 3, 4, 5}
      a &* 10000 &+ b &* 1000 &+ c[0] &* 100 &+ c[1] &* 10 &+ c[2]
      CODE
  end

  it "supports 1 to n assignment, splat is empty (1)" do
    run(<<-CODE).to_b.should be_true
      require "prelude"

      _, *x, _ = {1, 2}
      x.is_a?(Tuple())
      CODE
  end

  it "supports 1 to n assignment, splat is empty (2)" do
    run(<<-CODE).to_b.should be_true
      #{tuple_new}
      #{range_new}
      #{include_indexable}

      *x, _, _ = {1, 2}
      x.is_a?(Tuple())
      CODE
  end

  it "supports 1 to n assignment, splat is empty (3)" do
    run(<<-CODE).to_b.should be_true
      #{tuple_new}
      #{range_new}
      #{include_indexable}

      _, _, *x = {1, 2}
      x.is_a?(Tuple())
      CODE
  end

  it "supports 1 to n assignment, raises if too short" do
    run(<<-CODE).to_b.should be_true
      require "prelude"

      begin
        a, *b, c = [1]
        false
      rescue ex : IndexError
        ex.message == "Multiple assignment count mismatch"
      end
      CODE
  end

  it "supports 1 to n assignment, raises if out of bounds (1)" do
    run(<<-CODE).to_b.should be_true
      require "prelude"

      begin
        *a, b, c = [1]
        false
      rescue ex : IndexError
        true
      end
      CODE
  end

  it "supports 1 to n assignment, raises if out of bounds (2)" do
    run(<<-CODE).to_b.should be_true
      require "prelude"

      begin
        a, b, *c = [1]
        false
      rescue ex : IndexError
        true
      end
      CODE
  end
end

private def tuple_new
  <<-CODE
    struct Tuple
      def self.new(*args)
        args
      end
    end
    CODE
end

private def range_new
  <<-CODE
    struct Range(B, E)
      def initialize(@begin : B, @end : E, @exclusive : Bool = false)
      end
    end
    CODE
end

private def include_indexable
  <<-CODE
    struct Tuple(*T)
      include Indexable(Union(*T))
    end
    CODE
end
