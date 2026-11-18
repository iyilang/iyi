require "../../spec_helper"

describe "Code gen: sizeof" do
  it "gets sizeof int" do
    run("sizeof(Int32)").to_i.should eq(4)
  end

  it "gets sizeof struct" do
    run(<<-CODE).to_i.should eq(12)
      struct Foo
        def initialize(@x : Int32, @y : Int32, @z : Int32)
        end
      end

      Foo.new(1, 2, 3)

      sizeof(Foo)
      CODE
  end

  it "gets sizeof class" do
    # A class is represented as a pointer to its data
    run(<<-CODE).to_i.should eq(sizeof(Void*))
      class Foo
        def initialize(@x : Int32, @y : Int32, @z : Int32)
        end
      end

      Foo.new(1, 2, 3)

      sizeof(Foo)
      CODE
  end

  it "gets sizeof union" do
    size = run(<<-CODE).to_i
      sizeof(Int32 | Float64)
      CODE

    # This union is represented as:
    #
    #   struct {
    #      4 bytes, # for the type id
    #      8 bytes, # for the largest size between Int32 and Float64
    #   }
    #
    # But in 64 bits structs are aligned to 8 bytes, so it'll actually
    # be struct { 8 bytes, 8 bytes }.
    #
    # In 32 bits structs are aligned to 4 bytes, so it remains the same.
    {% if flag?(:bits64) %}
      size.should eq(16)
    {% else %}
      size.should eq(12)
    {% end %}
  end

  it "gets instance_sizeof class" do
    run(<<-CODE).to_i.should eq(16)
      class Foo
        def initialize(@x : Int32, @y : Int32, @z : Int32)
        end
      end

      Foo.new(1, 2, 3)

      instance_sizeof(Foo)
      CODE
  end

  it "gets instance_sizeof a generic type with type vars" do
    run(<<-CODE).to_i.should eq(8)
      class Foo(T)
        def initialize(@x : T)
        end
      end

      instance_sizeof(Foo(Int32))
      CODE
  end

  it "gets sizeof Void" do
    # Same as the size of a byte, because doing
    # `Pointer(Void).malloc` must work like `Pointer(UInt8).malloc`
    run("sizeof(Void)").to_i.should eq(1)
  end

  it "gets sizeof NoReturn" do
    # NoReturn can't hold anything
    run("sizeof(NoReturn)").to_i.should eq(0)
  end

  it "gets sizeof Nil (#7644)" do
    # Nil can't hold anything
    run("sizeof(Nil)").to_i.should eq(0)
  end

  it "gets sizeof Bool (#8272)" do
    run("sizeof(Bool)").to_i.should eq(1)
  end

  it "can use sizeof in type argument (1)" do
    run(<<-CODE).to_i.should eq(4)
      struct StaticArray
        def size
          N
        end
      end

      x = uninitialized UInt8[sizeof(Int32)]
      x.size
      CODE
  end

  it "can use sizeof in type argument (2)" do
    run(<<-CODE).to_i.should eq(8)
      struct StaticArray
        def size
          N
        end
      end

      x = uninitialized UInt8[sizeof(Float64)]
      x.size
      CODE
  end

  it "can use sizeof of virtual type" do
    size = run(<<-CODE).to_i
      class Foo
        @x = 1
      end

      class Bar < Foo
        @y = 2
      end

      foo = Bar.new.as(Foo)
      sizeof(typeof(foo))
      CODE

    {% if flag?(:bits64) %}
      size.should eq(8)
    {% else %}
      size.should eq(4)
    {% end %}
  end

  it "can use instance_sizeof of virtual type" do
    run(<<-CODE).to_i.should eq(12)
      class Foo
        @x = 1
      end

      class Bar < Foo
        @y = 2
      end

      class Baz < Bar
        @z = 2
      end

      bar = Baz.new.as(Bar)
      instance_sizeof(typeof(bar))
      CODE
  end

  it "can use instance_sizeof in type argument" do
    run(<<-CODE).to_i.should eq(12)
      struct StaticArray
        def size
          N
        end
      end

      class Foo
        def initialize
          @x = 1
          @y = 1
        end
      end

      x = uninitialized UInt8[instance_sizeof(Foo)]
      x.size
      CODE
  end

  it "returns correct sizeof for abstract struct (#4319)" do
    size = run(<<-CODE).to_i
        abstract struct Entry
        end

        struct FooEntry < Entry
          def initialize
            @uid = ""
          end
        end

        struct BarEntry < Entry
          def initialize
            @uid = ""
          end
        end

        sizeof(Entry)
        CODE

    size.should eq(16)
  end

  it "doesn't precompute sizeof of abstract struct (#7741)" do
    run(<<-CODE).to_i.should eq(16)
      abstract struct Base
      end

      struct Foo(T) < Base
        def initialize(@x : T)
        end
      end

      z = sizeof(Base)

      Foo({Int32, Int32, Int32, Int32})

      z
      CODE
  end

  it "doesn't precompute sizeof of module (#7741)" do
    run(<<-CODE).to_i.should eq(16)
      module Base
      end

      struct Foo(T)
        include Base

        def initialize(@x : T)
        end
      end

      z = sizeof(Base)

      Foo({Int32, Int32, Int32, Int32})

      z
      CODE
  end

  describe "alignof" do
    it "gets alignof primitive types" do
      run("alignof(Int32)").to_i.should eq(4)
      run("alignof(Void)").to_i.should eq(1)
      run("alignof(NoReturn)").to_i.should eq(1)
      run("alignof(Nil)").to_i.should eq(1)
      run("alignof(Bool)").to_i.should eq(1)
    end

    it "gets alignof struct" do
      run(<<-CODE).to_i.should eq(4)
        struct Foo
          def initialize(@x : Int8, @y : Int32, @z : Int16)
          end
        end

        Foo.new(1, 2, 3)

        alignof(Foo)
        CODE
    end

    it "gets alignof class" do
      # pointer size and alignment should be identical
      run(<<-CODE).to_i.should eq(sizeof(Void*))
        class Foo
          def initialize(@x : Int8, @y : Int32, @z : Int16)
          end
        end

        Foo.new(1, 2, 3)

        alignof(Foo)
        CODE
    end

    it "gets alignof union" do
      run("alignof(Int32 | Int8)").to_i.should eq(8)
      run("alignof(Int32 | Int64)").to_i.should eq(8)
    end

    it "alignof mixed union is not less than alignof its variant types" do
      # NOTE: `alignof(Int128) == 16` is not guaranteed
      run("alignof(Int32 | Int128) >= alignof(Int128)").to_b.should be_true
    end
  end

  describe "instance_alignof" do
    it "gets instance_alignof class" do
      run(<<-CODE).to_i.should eq(4)
        class Foo
          def initialize(@x : Int8, @y : Int32, @z : Int16)
          end
        end

        Foo.new(1, 2, 3)

        instance_alignof(Foo)
        CODE

      run(<<-CODE).to_i.should eq(8)
        class Foo
          def initialize(@x : Int8, @y : Int64, @z : Int16)
          end
        end

        Foo.new(1, 2, 3)

        instance_alignof(Foo)
        CODE

      run(<<-CODE).to_i.should eq(4)
        class Foo
        end

        Foo.new

        instance_alignof(Foo)
        CODE
    end

    it "gets instance_alignof a generic type with type vars" do
      run(<<-CODE).to_i.should eq(4)
        class Foo(T)
          def initialize(@x : T)
          end
        end

        instance_alignof(Foo(Int32))
        CODE

      run(<<-CODE).to_i.should eq(8)
        class Foo(T)
          def initialize(@x : T)
          end
        end

        instance_alignof(Foo(Int64))
        CODE

      run(<<-CODE).to_i.should eq(4)
        class Foo(T)
          def initialize(@x : T)
          end
        end

        instance_alignof(Foo(Int8))
        CODE
    end
  end
end

describe "Code gen: sizeof settled folds" do
  # Each program grows `M` after a fold, which makes the fold stale. A stale
  # expression is settled to the built layout (Q1 b). A stale type argument
  # cannot be corrected without changing its type, so it is refused (Q2 b).
  it "corrects a folded sizeof of a tuple whose module grew after the fold" do
    run(settled_fold_program(<<-CODE)).to_i.should eq(32)
      a = G(Int8).new(1_i8).as(M)
      s1 = sizeof({Int32, M})
      b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)
      s1
      CODE
  end

  it "gives the corrected sizeof the codegen stride of the grown tuple" do
    run(settled_fold_program(<<-CODE)).to_b.should be_true
      a = G(Int8).new(1_i8).as(M)
      s1 = sizeof({Int32, M})
      b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)
      (Pointer({Int32, M}).new(0_u64) + 1).address == s1
      CODE
  end

  it "keeps a folded sizeof when the module never grows" do
    run(settled_fold_program(<<-CODE)).to_i.should eq(8)
      a = G(Int8).new(1_i8).as(M)
      s1 = sizeof({Int32, M})
      s1
      CODE
  end

  it "refuses a type argument built from a layout that grows later" do
    expect_raises(Iyi::TypeException, /when it was used as a type argument, but/) do
      run(settled_fold_program(<<-CODE))
        a = G(Int8).new(1_i8).as(M)
        buf = StaticArray(UInt8, sizeof({Int32, M})).new
        b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)
        buf.size
        CODE
    end
  end

  it "keeps the value of a type argument when the module never grows" do
    run(settled_fold_program(<<-CODE)).to_i.should eq(8)
      a = G(Int8).new(1_i8).as(M)
      buf = StaticArray(UInt8, sizeof({Int32, M})).new
      buf.size
      CODE
  end

  it "gives a type argument sized after the final growth its final value" do
    run(settled_fold_program(<<-CODE)).to_i.should eq(32)
      a = G(Int8).new(1_i8).as(M)
      b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)
      buf = StaticArray(UInt8, sizeof({Int32, M})).new
      buf.size
      CODE
  end

  it "refuses a type argument built from a recursive generic that grows" do
    expect_raises(Iyi::TypeException, /when it was used as a type argument, but/) do
      run(<<-CODE)
        module M
        end

        struct G(N)
          include M

          def initialize
            @buf = StaticArray(UInt8, N).new
          end

          def n
            N
          end
        end

        x = G(1).new.as(M)
        y = G(2).new.as(M)
        z = G(sizeof({M})).new
        z.n
        CODE
    end
  end

  it "corrects an offsetof that precedes a grown module field" do
    run(settled_fold_p4("off\n")).to_i.should eq(24)
  end

  it "reads the field back at the corrected offset" do
    run(settled_fold_p4("(pointerof(s).as(UInt8*) + sizeof(typeof(s.@a))).as(Int32*).value\n")).to_i.should eq(7)
  end

  it "agrees the corrected offsetof with the size of the module field" do
    run(settled_fold_p4("off == sizeof(typeof(s.@a))\n")).to_b.should be_true
  end

  it "corrects a macro-expanded sizeof of a class" do
    run(<<-CODE).to_i.should eq(8)
      class C
        def initialize(@a : Int64, @b : Int64)
        end
      end

      {% begin %}
        X = {{ sizeof(C) }}
      {% end %}
      c = C.new(1, 2)
      X
      CODE
  end

  it "keeps the corrected instance_sizeof of the same class" do
    run(<<-CODE).to_i.should eq(24)
      class C
        def initialize(@a : Int64, @b : Int64)
        end
      end

      {% begin %}
        X = {{ sizeof(C) }}
      {% end %}
      c = C.new(1, 2)
      instance_sizeof(C)
      CODE
  end

  it "corrects a constant sizeof of a class" do
    run(<<-CODE).to_i.should eq(8)
      class C
        def initialize(@a : Int64, @b : Int64)
        end
      end

      X = {{ sizeof(C) }}
      c = C.new(1, 2)
      X
      CODE
  end
end

private def settled_fold_program(body : String) : String
  <<-CODE
    module M
    end

    struct StaticArray(T, N)
      def size
        N
      end
    end

    struct G(T)
      include M

      def initialize(@v : T)
      end
    end

    #{body}
    CODE
end

private def settled_fold_p4(last : String) : String
  body = <<-CODE
    struct S
      def initialize(@a : M, @b : Int32)
      end
    end

    x = G(Int8).new(1_i8).as(M)
    off = offsetof(S, @b)
    s = S.new(G({Int64, Int64}).new({1_i64, 2_i64}), 7)
    CODE
  settled_fold_program(body + "\n" + last)
end
