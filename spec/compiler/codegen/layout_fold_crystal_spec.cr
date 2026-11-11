require "../../spec_helper"

# Crystal mode (`require "prelude"`, iyi prelude off).
#
# Upstream Crystal 1.21.0 folds some sizes before a module grows and then
# builds a layout that disagrees with the fold. Under --crystal, an expression
# fold of that kind takes the size of the layout actually built. A fold inside
# a type argument, and every expression tied to one, keeps the value 1.21.0
# prints, because changing a type argument would change a type.

private def growing_module_program(body : String) : String
  <<-CODE
    require "prelude"

    module M
    end

    struct G(T)
      include M

      def initialize(@v : T)
      end
    end

    #{body}
    CODE
end

describe "Code gen: layout folds under --crystal" do
  describe "expression folds take the built layout" do
    it "corrects a sizeof of a tuple whose module grew after the fold (P1)" do
      run(growing_module_program(<<-CODE)).to_string.should eq("{32, 32, 32}")
        a = G(Int8).new(1_i8).as(M)
        s1 = sizeof({Int32, M})
        b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)
        {s1, sizeof(typeof({1, b})), sizeof({Int32, M})}
        CODE
    end

    it "gives the corrected sizeof the codegen stride of the grown tuple (P1)" do
      run(growing_module_program(<<-CODE)).to_string.should eq("{32, 32}")
        a = G(Int8).new(1_i8).as(M)
        s1 = sizeof({Int32, M})
        b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)
        {s1, (Pointer({Int32, M}).null + 1).address}
        CODE
    end

    it "corrects an offsetof that precedes a grown module field and reads the field back (P4)" do
      run(growing_module_program(<<-CODE)).to_string.should eq("{24, true, 7}")
        struct S
          def initialize(@a : M, @b : Int32)
          end
        end

        x = G(Int8).new(1_i8).as(M)
        off = offsetof(S, @b)
        s = S.new(G({Int64, Int64}).new({1_i64, 2_i64}), 7)
        {off, off == sizeof(typeof(s.@a)), (pointerof(s).as(UInt8*) + sizeof(typeof(s.@a))).as(Int32*).value}
        CODE
    end

    it "corrects a macro-expanded sizeof of a class (P7)" do
      run(<<-CODE).to_string.should eq("{8, 24, 24, 24}")
        require "prelude"

        class C
          def initialize(@a : Int64, @b : Int64)
          end
        end

        {% begin %}
          X = {{ sizeof(C) }}
        {% end %}
        c = C.new(1, 2)
        {X, instance_sizeof(C), instance_sizeof(typeof(c)), sizeof(ReferenceStorage(C))}
        CODE
    end

    it "corrects a constant sizeof of a class (P7')" do
      run(<<-CODE).to_string.should eq("{8, 24, 24, 24}")
        require "prelude"

        class C
          def initialize(@a : Int64, @b : Int64)
          end
        end

        X = {{ sizeof(C) }}
        c = C.new(1, 2)
        {X, instance_sizeof(C), instance_sizeof(typeof(c)), sizeof(ReferenceStorage(C))}
        CODE
    end
  end

  describe "type arguments keep the value 1.21.0 prints" do
    it "keeps a stale type argument and the array size it fixes (P2)" do
      run(growing_module_program(<<-CODE)).to_string.should eq("{8, 32}")
        a = G(Int8).new(1_i8).as(M)
        buf = StaticArray(UInt8, sizeof({Int32, M})).new(0_u8)
        b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)
        {buf.size, sizeof(typeof({1, b}))}
        CODE
    end

    it "keeps the value of a type argument built from a recursive generic (P3)" do
      run(<<-CODE).to_string.should eq("{16, 24}")
        require "prelude"

        module M
        end

        struct G(N)
          include M

          def initialize
            @buf = StaticArray(UInt8, N).new(0_u8)
          end

          def n
            N
          end
        end

        x = G(1).new.as(M)
        y = G(2).new.as(M)
        z = G(sizeof({M})).new
        {z.n, sizeof(typeof({x}))}
        CODE
    end

    it "keeps the expression tied to a stale type argument (P6)" do
      run(growing_module_program(<<-CODE)).to_string.should eq("{8, 8}")
        a = G(Int8).new(1_i8).as(M)
        e = sizeof({Int32, M})
        b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)
        buf = StaticArray(UInt8, sizeof({Int32, M})).new(0_u8)
        {e, buf.size}
        CODE
    end

    it "gives a type argument sized after the growth the final layout (P6')" do
      run(growing_module_program(<<-CODE)).to_string.should eq("32")
        a = G(Int8).new(1_i8).as(M)
        b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)
        buf = StaticArray(UInt8, sizeof({Int32, M})).new(0_u8)
        buf.size
        CODE
    end

    it "keeps the value of a sizeof in a type argument of a struct without a grown field (Q-b)" do
      run(growing_module_program(<<-CODE)).to_string.should eq("1")
        struct S
          def initialize(@a : M)
          end
        end

        a = G(Int8).new(1_i8).as(M)
        StaticArray(UInt8, sizeof(S)).new(0_u8).size
        CODE
    end

    it "prints the type argument unchanged (Q-a)" do
      run(<<-CODE).to_string.should eq("Foo(Int32)")
        require "prelude"

        struct Foo(T)
        end

        x = 1
        Foo(sizeof(typeof(x)))
        CODE
    end
  end

  describe "stable layouts are unchanged" do
    it "keeps a sizeof of a module that never grows" do
      run(growing_module_program(<<-CODE)).to_string.should eq("8")
        a = G(Int8).new(1_i8).as(M)
        sizeof({Int32, M})
        CODE
    end
  end

  describe "bootstrap regression" do
    it "dups a dup of an array holding a grown module element to completion (P5)" do
      run(growing_module_program(<<-CODE)).to_string.should eq("{2, 1, 2, true}")
        arr = [{1, G(Int8).new(1_i8).as(M)}]
        d1 = arr.dup
        arr << {2, G({Int64, Int64}).new({3_i64, 4_i64}).as(M)}
        d2 = arr.dup
        d3 = d2.dup
        {d3.size, d3[0][0], d3[1][0], d3 == arr}
        CODE
    end
  end
end
