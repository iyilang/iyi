require "../../spec_helper"

private def assert_commutes(str, *, file = __FILE__, line = __LINE__, &)
  result = semantic(str)
  program = result.program
  type1, type2, expected = with program yield program
  union1 = program.type_merge([type1, type2])
  union2 = program.type_merge([type2, type1])
  union1.should eq(expected), file: file, line: line
  union2.should eq(expected), file: file, line: line
end

describe "Semantic: union" do
  context "commutativity" do
    it "module v.s. including module" do
      assert_commutes(<<-CODE) { [types["A"], types["B"], types["A"]] }
        module A
        end

        module B
          include A
        end
        CODE
    end

    it "module v.s. including generic module instance" do
      assert_commutes(<<-CODE) { [types["A"], generic_module("B", types["Cxx"]), types["A"]] }
        class Cxx
        end

        module A
        end

        module B(T)
          include A
        end
        CODE
    end

    it "generic module instance v.s. including module" do
      assert_commutes(<<-CODE) { [generic_module("A", types["Cxx"]), types["B"], generic_module("A", types["Cxx"])] }
        class Cxx
        end

        module A(T)
        end

        module B
          include A(Cxx)
        end
        CODE
    end

    it "generic module instance v.s. including generic module instance" do
      assert_commutes(<<-CODE) { [generic_module("A", types["Cxx"]), generic_module("B", types["Cxx"]), generic_module("A", types["Cxx"])] }
        class Cxx
        end

        module A(T)
        end

        module B(T)
          include A(T)
        end
        CODE
    end

    it "module v.s. extending generic module instance metaclass" do
      assert_commutes(<<-CODE) { [types["A"], generic_module("B", types["Cxx"]).metaclass, types["A"]] }
        class Cxx
        end

        module A
        end

        module B(T)
          extend A
        end
        CODE
    end

    it "generic module instance v.s. extending generic module instance metaclass" do
      assert_commutes(<<-CODE) { [generic_module("A", types["Cxx"]), generic_module("B", types["Cxx"]).metaclass, generic_module("A", types["Cxx"])] }
        class Cxx
        end

        module A(T)
        end

        module B(T)
          extend A(T)
        end
        CODE
    end

    it "virtual metaclass v.s. generic subclass instance metaclass" do
      assert_commutes(<<-CODE) { [types["A"].virtual_type!.metaclass, generic_class("B", types["Cxx"]).metaclass, types["A"].virtual_type!.metaclass] }
        class Cxx
        end

        class A
        end

        class B(T) < A
        end
        CODE
    end

    it "superclass v.s. uninstantiated generic subclass" do
      assert_commutes(<<-CODE) { [types["A"], types["B"], types["A"].virtual_type!] }
        class A
        end

        class B(T) < A
        end
        CODE
    end

    it "uninstantiated generic super-metaclass v.s. uninstantiated generic sub-metaclass" do
      assert_commutes(<<-CODE) { [types["A"].metaclass, types["B"].metaclass, types["A"].metaclass.virtual_type!] }
        class A(T)
        end

        class B(T) < A(T)
        end
        CODE
    end
  end

  it "types union when obj is union" do
    assert_type("struct Char; def +(other); self; end; end; a = 1 || 'a'; a + 1", inject_primitives: true) { union_of(int32, char) }
  end

  it "types union when arg is union" do
    assert_type("struct Int; def +(x : Char); x; end; end; a = 1 || 'a'; 1 + a", inject_primitives: true) { union_of(int32, char) }
  end

  it "types union when both obj and arg are union" do
    assert_type("struct Char; def +(other); self; end; end; struct Int; def +(x : Char); x; end; end; a = 1 || 'a'; a + a", inject_primitives: true) { union_of(int32, char) }
  end

  it "types union of classes" do
    assert_type("class Foo; end; class Bar; end; a = Foo.new || Bar.new; a") { union_of(types["Foo"], types["Bar"]) }
  end

  it "assigns to union and keeps new union type in call" do
    assert_type(<<-CODE) { union_of(int32, bool, char) }
      def foo(x)
        while false
          x = 'a'
        end
        x
      end

      foo(1 || false)
      CODE
  end

  it "looks up type in union type with free var" do
    assert_type(<<-CODE) { generic_class "Bar", union_of(int32, char) }
      class Bar(T)
      end

      def foo(x : T) forall T
        Bar(T).new
      end

      foo(1 || 'a')
      CODE
  end

  it "supports macro if inside union" do
    assert_type(<<-CODE, flags: "some_flag") { int32 }
      lib LibC
        union Foo
          {% if flag?(:some_flag) %}
            a : Int32
          {% else %}
            a : Float64
          {% end %}
        end
      end

      LibC::Foo.new.a
      CODE
  end

  it "types union" do
    assert_type(<<-CODE) { union_of(int32, string).metaclass }
      Union(Int32, String)
      CODE
  end

  it "types union of same type" do
    assert_type(<<-CODE) { int32.metaclass }
      Union(Int32, Int32, Int32)
      CODE
  end

  it "can reopen Union" do
    assert_type(<<-CODE) { int32 }
      struct Union
        def self.foo
          1
        end
      end
      Union(Int32, String).foo
      CODE
  end

  it "can reopen Union and access T" do
    assert_type(<<-CODE) { tuple_of([int32, string]).metaclass }
      struct Union
        def self.types
          T
        end
      end
      Union(Int32, String).types
      CODE
  end

  it "can iterate T" do
    assert_type(<<-CODE) { tuple_of([int32.metaclass, string.metaclass]) }
      struct Union
        def self.types
          {% begin %}
            {
              {% for type in T %}
                {{type}},
              {% end %}
            }
          {% end %}
        end
      end
      Union(Int32, String).types
      CODE
  end

  it "errors if instantiates union" do
    assert_error <<-CODE, "can't create instance of a union type"
      Union(Int32, String).new
      CODE
  end

  it "finds method in Object" do
    assert_type(<<-CODE) { int32 }
      class Object
        def self.foo
          1
        end
      end

      Union(Int32, String).foo
      CODE
  end

  it "finds method in Value" do
    assert_type(<<-CODE) { int32 }
      struct Value
        def self.foo
          1
        end
      end

      Union(Int32, String).foo
      CODE
  end

  it "merges types in the same hierarchy with Union" do
    assert_type(<<-CODE) { types["Foo"].virtual_type!.metaclass }
      class Foo; end
      class Bar < Foo; end

      Union(Foo, Bar)
      CODE
  end

  it "treats void as nil in union" do
    assert_type(<<-CODE) { nil_type }
      nil.as(Void?)
      CODE
  end

  it "can use Union in type restriction (#2988)" do
    assert_type(<<-CODE) { tuple_of([int32, string]) }
      def foo(x : Union(Int32, String))
        x
      end

      {foo(1), foo("hi")}
      CODE
  end

  it "doesn't crash with union of no-types (#5805)" do
    assert_type(<<-CODE) { union_of char, generic_class("Gen", int32).metaclass }
      class Gen(T)
      end

      foo = 42
      if foo.is_a?(String)
        Gen(typeof(foo) | Int32)
      else
        'a'
      end
      CODE
  end

  it "doesn't virtualize union elements (#7814)" do
    assert_type(<<-CODE) { types["Foo"].metaclass }
      class Foo; end
      class Bar < Foo; end

      Union(Foo)
      CODE
  end

  it "doesn't run virtual lookup on unbound unions (#9173)" do
    assert_type(<<-CODE) { int32 }
      class Object
        def foo
          self
        end
      end

      abstract class Parent
      end

      class Child(T) < Parent
        @buffer = uninitialized T

        def bar
          @buffer.foo
        end
      end

      class Foo(U)
        @x = Child(U | Char).new
      end

      Child(Int32).new.as(Parent).bar
      CODE
  end

  describe "canonical union order" do
    it "union_of([b, a]) and union_of([a, b]) are the same object, with Nil first" do
      program = Program.new
      a = program.nil
      b = program.string
      u1 = program.union_of([b, a]).not_nil!
      u2 = program.union_of([a, b]).not_nil!
      u1.same?(u2).should be_true
      u1.as(UnionType).union_types.first.should eq(a)

      # Also with value type
      c = program.int32
      u3 = program.union_of([c, a]).not_nil!
      u4 = program.union_of([a, c]).not_nil!
      u3.same?(u4).should be_true
      u3.as(UnionType).union_types.first.should eq(a)

      # Non-nil types sorted by canonical name
      u5 = program.union_of([b, c]).not_nil!
      u6 = program.union_of([c, b]).not_nil!
      u5.same?(u6).should be_true
      u5.as(UnionType).union_types.first.should eq(c)
      u5.as(UnionType).union_types.last.should eq(b)

      # Multiple members with Nil first
      u7 = program.union_of([b, c, a]).not_nil!
      u8 = program.union_of([a, b, c]).not_nil!
      u7.same?(u8).should be_true
      u7.as(UnionType).union_types.map(&.to_s).should eq(["Nil", "Int32", "String"])
    end

    it "two programs that create String | Int32 and Int32 | String in opposite orders print the same typeof" do
      res1 = semantic("a = 1 ? \"hello\" : 1; a")
      res2 = semantic("a = 1 ? 1 : \"hello\"; a")
      res1.node.type.to_s.should eq("(Int32 | String)")
      res2.node.type.to_s.should eq("(Int32 | String)")
      res1.node.type.to_s.should eq(res2.node.type.to_s)
    end
  end
end
