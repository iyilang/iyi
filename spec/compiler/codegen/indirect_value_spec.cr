require "../../spec_helper"

# iyi: a value larger than `LLVMTyper::INDIRECT_ABOVE` bytes travels between
# functions through memory and is copied with `llvm.memcpy`/`llvm.memmove`
# rather than as one first-class aggregate, which LLVM lowers an element at a
# time when it does not optimise.
BIG_VALUE_PRELUDE = <<-CODE
  struct Big
    @pad : StaticArray(Int64, 20)

    def initialize(@x : Int32, @y : Int32)
      @pad = uninitialized StaticArray(Int64, 20)
    end

    def x
      @x
    end

    def y
      @y
    end

    def bump : Int32
      @x = @x &+ 100
      1
    end
  end
  CODE

describe "Code gen: values passed indirectly" do
  it "returns and passes a large value through memory, with no aggregate load or store" do
    ir = codegen(<<-CODE).to_s
      def make : StaticArray(UInt8, 1000)
        x = uninitialized StaticArray(UInt8, 1000)
        x
      end

      def take(x : StaticArray(UInt8, 1000)) : StaticArray(UInt8, 1000)
        y = x
        y
      end

      take(make)
      1
      CODE

    ir.should_not contain("load [1000 x i8]")
    ir.should_not contain("store [1000 x i8]")
    ir.should_not contain("ret [1000 x i8]")
    ir.should contain("@llvm.memcpy")
    ir.should match(/define [^\n]*void @"\*make[^"]*"\(ptr noalias %return\)/)
    ir.should match(/define [^\n]*void @"\*take[^"]*"\(ptr %x, ptr noalias %return\)/)
  end

  it "keeps a small value first-class" do
    ir = codegen(<<-CODE).to_s
      def pair(a : Int64) : {Int64, Int64}
        {a, a}
      end

      pair(1_i64)
      1
      CODE

    ir.should match(/define [^\n]*%"Tuple\(Int64, Int64\)" @"\*pair/)
  end

  it "copies an argument before a later argument writes where it points" do
    run(<<-CODE).to_i.should eq(10 * 1000 + 1 * 100 + 110)
      #{BIG_VALUE_PRELUDE}

      def three(a : Big, n : Int32, b : Big) : Int32
        a.x &* 1000 &+ n &* 100 &+ b.x
      end

      v = Big.new(10, 0)
      three(v, v.bump, v)
      CODE
  end

  it "gives the callee its own copy" do
    run(<<-CODE).to_i.should eq(7)
      #{BIG_VALUE_PRELUDE}

      def change(a : Big) : Int32
        a.bump
        a.x
      end

      v = Big.new(7, 0)
      change(v)
      v.x
      CODE
  end

  it "returns a large value from a nested call" do
    run(<<-CODE).to_i.should eq(43)
      #{BIG_VALUE_PRELUDE}

      def make(x : Int32) : Big
        Big.new(x, x &+ 1)
      end

      def pass(b : Big) : Big
        c = b
        c
      end

      pass(pass(make(42))).y
      CODE
  end

  it "copies between overlapping places as a whole value" do
    run(<<-CODE).to_i.should eq(2 * 10 + 3)
      #{BIG_VALUE_PRELUDE}

      p = Pointer(Big).malloc(3_u64)
      p.value = Big.new(1, 0)
      (p + 1).value = Big.new(2, 0)
      (p + 2).value = Big.new(3, 0)
      p.value = (p + 1).value
      (p + 1).value = (p + 2).value
      p.value.x &* 10 &+ (p + 1).value.x
      CODE
  end

  it "stores a large value in a union and reads it back" do
    run(<<-CODE).to_i.should eq(5 &+ 6)
      #{BIG_VALUE_PRELUDE}

      def maybe(n : Int32) : Big | Int32
        return n if n == 0
        Big.new(n, n &+ 1)
      end

      u = maybe(5)
      if u.is_a?(Big)
        u.x &+ u.y
      else
        0
      end
      CODE
  end

  it "passes and returns a large value through a proc and a closure" do
    run(<<-CODE).to_i.should eq(12 &+ 30)
      #{BIG_VALUE_PRELUDE}

      f = ->(b : Big) { Big.new(b.x &+ 2, 0) }
      base = Big.new(30, 0)
      g = ->(b : Big) { b.x &+ base.x }
      f.call(Big.new(10, 0)).x &+ g.call(Big.new(0, 0))
      CODE
  end

  it "passes a large value through a proc pointer to a method" do
    run(<<-CODE).to_i.should eq(9)
      #{BIG_VALUE_PRELUDE}

      def ident(b : Big) : Big
        b
      end

      f = ->ident(Big)
      f.call(Big.new(9, 0)).x
      CODE
  end

  it "passes a large value to a block" do
    run(<<-CODE).to_i.should eq(11)
      #{BIG_VALUE_PRELUDE}

      def with_big(b : Big, &)
        yield b
      end

      with_big(Big.new(11, 0)) { |b| b.x }
      CODE
  end
end
