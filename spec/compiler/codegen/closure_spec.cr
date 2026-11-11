require "../../spec_helper"

describe "Code gen: closure" do
  it "namespaces only closures hosted in selected carried units" do
    program = Iyi::Program.new
    program.flags.delete("msvc")
    names = ["Boot::Half", "Boot::Half+", "Boot::Half::Nested", "A%@^", "雪"]
    program.register_iyi_carried_closure_units(names)
    requested = "~procProc(Int32)^source.iyi:12"
    names.each do |name|
      suffix = "^unit:#{name.to_slice.hexstring}"
      program.iyi_carried_closure_suffixes[name].should eq(suffix)
      program.iyi_closure_linkage_name(requested, name, false).should eq(requested + suffix)
    end
    program.iyi_carried_closure_suffixes.values.uniq.size.should eq(names.size)
    program.iyi_closure_linkage_name(requested, nil, false).should eq(requested)
    program.iyi_closure_linkage_name(requested, "Caller::Other", false).should eq(requested)
    program.iyi_closure_linkage_name(requested, "Boot::Half", true).should eq(requested)
    program.register_iyi_carried_closure_units(names)
    program.iyi_closure_linkage_name(requested, "Boot::Half", false)
      .should eq("#{requested}^unit:426f6f743a3a48616c66")
  end

  it "mangles only the carried unit suffix on MSVC" do
    program = Iyi::Program.new
    program.flags << "msvc"
    program.register_iyi_carried_closure_units(["Boot::Half", "雪"])
    requested = ".7E.proc.28.Int32.29."
    program.iyi_closure_linkage_name(requested, "Boot::Half", false)
      .should eq("#{requested}.5E.unit.3A.426f6f743a3a48616c66")
    program.iyi_closure_linkage_name(requested, "雪", false)
      .should eq("#{requested}.5E.unit.3A.e99baa")
  end

  it "codegens simple closure at global scope" do
    run(<<-CODE).to_i.should eq(1)
      a = 1
      foo = ->{ a }
      foo.call
      CODE
  end

  it "codegens simple closure in function" do
    run(<<-CODE).to_i.should eq(1)
      def foo
        a = 1
        ->{ a }
      end

      foo.call
      CODE
  end

  it "codegens simple closure in function with argument" do
    run(<<-CODE).to_i.should eq(1)
      def foo(a)
        ->{ a }
      end

      foo(1).call
      CODE
  end

  it "codegens simple closure in block" do
    run(<<-CODE).to_i.should eq(1)
      def foo
        yield
      end

      f = foo do
        x = 1
        -> { x }
      end

      f.call
      CODE
  end

  it "codegens closured nested in block" do
    run(<<-CODE).to_i.should eq(3)
      def foo
        yield
      end

      a = 1
      f = foo do
        b = 2
        -> { a &+ b }
      end
      f.call
      CODE
  end

  it "codegens closured nested in block with a call with a closure with same names" do
    run(<<-CODE).to_i.should eq(4)
      def foo
        a = 3
        f = -> { a }
        yield f.call
      end

      a = 1
      f = foo do |x|
        -> { a &+ x }
      end
      f.call
      CODE
  end

  it "codegens closure with block that declares same var" do
    run(<<-CODE).to_i.should eq(3)
      def foo
        a = 1
        yield a
      end

      f = foo do |x|
        a = 2
        -> { a &+ x }
      end
      f.call
      CODE
  end

  it "codegens closure with def that has an if" do
    run(<<-CODE).to_i.should eq(2)
      def foo
        yield 1 if 1
        yield 2
      end

      f = foo do |x|
        -> { x }
      end
      f.call
      CODE
  end

  it "codegens multiple nested blocks" do
    run(<<-CODE).to_i.should eq(9)
      def foo
        yield 1
        yield 2
        yield 3
      end

      a = 1
      f = foo do |x|
        b = 1
        foo do |y|
          c = 1
          -> { a &+ b &+ c &+ x &+ y }
        end
      end
      f.call
      CODE
  end

  it "codegens closure with nested context without new closured vars" do
    run(<<-CODE).to_i.should eq(1)
      def foo
        yield
      end

      a = 1
      f = foo do
        -> { a }
      end
      f.call
      CODE
  end

  it "codegens closure with nested context without new closured vars" do
    run(<<-CODE).to_i.should eq(2)
      def foo
        yield
      end

      def bar
        yield
      end

      a = 1
      f = foo do
        b = 1
        bar do
          -> { a &+ b }
        end
      end
      f.call
      CODE
  end

  it "codegens closure with nested context without new closured vars but with block arg" do
    run(<<-CODE).to_i.should eq(2)
      def foo
        yield
      end

      def bar
        yield 3
      end

      a = 1
      f = foo do
        b = 1
        bar do |x|
          x
          -> { a &+ b }
        end
      end
      f.call
      CODE
  end

  it "unifies types of closured var" do
    run(<<-CODE).to_i.should eq(2)
      a = 1
      f = -> { a }
      a = 2.5
      f.call.to_i!
      CODE
  end

  it "codegens closure with block" do
    run(<<-CODE).to_i.should eq(1)
      def foo
        yield
      end

      a = 1
      ->{ foo { a } }.call
      CODE
  end

  it "codegens closure with self and var" do
    run(<<-CODE).to_i.should eq(3)
      class Foo
        def initialize(@x : Int32)
        end

        def foo
          a = 2
          ->{ self.x &+ a }
        end

        def x
          @x
        end
      end

      Foo.new(1).foo.call
      CODE
  end

  it "codegens closure with implicit self and var" do
    run(<<-CODE).to_i.should eq(3)
      class Foo
        def initialize(@x : Int32)
        end

        def foo
          a = 2
          ->{ x &+ a }
        end

        def x
          @x
        end
      end

      Foo.new(1).foo.call
      CODE
  end

  it "codegens closure with instance var and var" do
    run(<<-CODE).to_i.should eq(3)
      class Foo
        def initialize(@x : Int32)
        end

        def foo
          a = 2
          ->{ @x &+ a }
        end
      end

      Foo.new(1).foo.call
      CODE
  end

  it "codegens closure with instance var" do
    run(<<-CODE).to_i.should eq(1)
      class Foo
        def initialize(@x : Int32)
        end

        def foo
          ->{ @x }
        end
      end

      Foo.new(1).foo.call
      CODE
  end

  it "codegens closure with instance var and block" do
    run(<<-CODE).to_i.should eq(3)
      def bar
        yield
      end

      class Foo
        def initialize(@x : Int32)
        end

        def foo
          bar do
            a = 2
            ->{ @x &+ a }
          end
        end
      end

      Foo.new(1).foo.call
      CODE
  end

  it "codegen closure in instance method without self closured" do
    run(<<-CODE).to_i.should eq(1)
      class Foo
        def foo
          ->(a : Int32) { a }
        end
      end

      Foo.new.foo.call(1)
      CODE
  end

  it "codegens closure inside initialize inside block with self" do
    run(<<-CODE)
      def foo
        yield
      end

      class Foo
        def initialize
          -> { self }
        end
      end

      foo do
        Foo.new
      end
      CODE
  end

  it "doesn't free closure memory (bug)" do
    run(<<-CODE).to_i.should eq(1249975000_i64)
      require "prelude"

      def foo
        i = 0
        while i < 50_000
          yield i
          i += 1
        end
      end

      funcs = [] of -> Int32

      foo do |x|
        funcs.push(->{ x })
      end

      a = 0_i64
      funcs.each do |func|
        a += func.call
      end
      a
      CODE
  end

  it "codegens nested closure" do
    run(<<-CODE).to_i.should eq(1)
      a = 1
      ->{ ->{ a } }.call.call
      CODE
  end

  it "codegens super nested closure" do
    run(<<-CODE).to_i.should eq(1)
      a = 1
      ->{ ->{ -> { -> { a } } } }.call.call.call.call
      CODE
  end

  it "codegens nested closure with block (1)" do
    run(<<-CODE).to_i.should eq(1)
      def foo
        yield
      end

      a = 1
      ->{ foo { ->{ a } } }.call.call
      CODE
  end

  it "codegens nested closure with block (2)" do
    run(<<-CODE).to_i.should eq(1)
      def foo
        yield
      end

      a = 1
      ->{ ->{ foo { a } } }.call.call
      CODE
  end

  it "codegens nested closure with nested closured variable" do
    run(<<-CODE).to_i.should eq(3)
      a = 1
      ->{
        b = 2
        ->{ a &+ b }
      }.call.call
      CODE
  end

  it "codegens super nested closure with nested closured variable" do
    run(<<-CODE).to_i.should eq(10)
      def foo
        yield 4
      end

      a = 1
      ->{
        b = 2
        ->{
          -> {
            -> {
              c = 3
              foo do |d|
                -> {
                  a &+ b &+ c &+ d
                }
              end
            }
          }
        }
      }.call.call.call.call.call
      CODE
  end

  it "codegens proc literal with struct" do
    run(<<-CODE).to_i.should eq(2)
      struct Foo
        def initialize(@x : Int32)
        end

        def x
          @x
        end
      end

      f = ->(foo : Foo) { foo.x }

      obj = Foo.new(2)
      f.call(obj)
      CODE
  end

  it "codegens closure with struct" do
    run(<<-CODE).to_i.should eq(3)
      struct Foo
        def initialize(@x : Int32)
        end

        def x
          @x
        end
      end

      a = 1
      f = ->(foo : Foo) {
        foo.x &+ a
      }

      obj = Foo.new(2)
      f.call(obj)
      CODE
  end

  it "codegens closure with self and arguments" do
    run(<<-CODE).to_i.should eq(3)
      class Foo
        def initialize(@x : Int32)
        end

        def foo(x)
          @x &+ x
        end

        def bar
          ->foo(Int32)
        end
      end

      f = Foo.new(1).bar
      f.call(2)
      CODE
  end

  it "codegens nested closure that mentions var in both contexts" do
    run(<<-CODE).to_i.should eq(1)
      a = 1
      f = ->{
        a
        -> { a }
      }
      f.call.call
      CODE
  end

  it "transforms block to proc literal" do
    run(<<-CODE).to_i.should eq(2)
      def foo(&block : Int32 -> Int32)
        block.call(1)
      end

      a = 1
      foo do |x|
        x &+ a
      end
      CODE
  end

  it "transforms block to proc literal with free var" do
    run(<<-CODE).to_i.should eq(10)
      def foo(&block : Int32 -> U) forall U
        block
      end

      a = 1
      g = foo { |x| x &+ a }
      h = foo { |x| x.to_f + a }
      (g.call(3) + h.call(5)).to_i!
      CODE
  end

  it "allows passing block as proc literal to new and to initialize" do
    run(<<-CODE).to_i.should eq(2)
      class Foo
        def initialize(&block : Int32 -> Float64)
          @block = block
        end

        def block
          @block
        end
      end

      a = 1
      foo = Foo.new { |x| x.to_f! + a }
      foo.block.call(1).to_i!
      CODE
  end

  it "allows giving less block args when transforming block to proc literal" do
    run(<<-CODE).to_i.should eq(2)
      def foo(&block : Int32 -> U) forall U
        block.call(1)
      end

      a = 1
      v = foo do
        1.5 + a
      end
      v.to_i!
      CODE
  end

  it "allows passing proc literal to def that captures block with &" do
    run(<<-CODE).to_i.should eq(2)
      def foo(&block : Int32 -> Int32)
        block.call(1)
      end

      a = 1
      f = ->(x : Int32) { x &+ a }
      foo &f
      CODE
  end

  it "allows mixing yield and block.call" do
    run(<<-CODE).to_i.should eq(3)
      def foo(&block : Int32 ->)
        yield 1
        block.call 2
      end

      a = 0
      foo { |x| a &+= x }
      a
      CODE
  end

  it "closures struct self" do
    run(<<-CODE).to_i.should eq(1)
      struct Foo
        def initialize(@x : Int32)
        end

        def foo
          ->{ @x }
        end
      end

      Foo.new(1).foo.call
      CODE
  end

  it "doesn't form a closure if invoking class method" do
    run(<<-CODE).to_b.should be_false
      require "prelude"

      class Foo
        def self.foo
          ->{ bar }.closure?
        end

        def self.bar
        end
      end

      Foo.foo
      CODE
  end

  it "doesn't form a closure if invoking class method with self" do
    run(<<-CODE).to_b.should be_false
      require "prelude"

      class Foo
        def self.foo
          ->{ self.bar }.closure?
        end

        def self.bar
        end
      end

      Foo.foo
      CODE
  end

  it "captures block and accesses local variable (#2050)" do
    run(<<-CODE).to_i.should eq(1)
      require "prelude"

      def capture(&block)
        block
      end

      coco = 1
      capture do
        coco
      end
      coco
      CODE
  end

  it "codegens closured self in block (#3388)" do
    run(<<-CODE).to_i.should eq(42)
      class Foo
        def initialize(@x : Int32)
        end

        def x
          @x
        end

        def foo
          yield
          ->{ self }
        end
      end

      foo = Foo.new(42)
      foo2 = foo.foo { }
      foo2.call.x
      CODE
  end

  it "doesn't incorrectly consider local as closured (#4948)" do
    codegen(<<-CODE)
      arg = 1

      f1 = ->{
        # Here 'local' isn't to be confused with
        # the outer closured 'local'
        local = 1
        local &+ arg
      }

      arg = 2

      local = 4_i64
      f2 = ->{ local.to_i! }

      f1.call &+ f2.call
      CODE
  end

  it "ensures it can raise from the closure check" do
    expect_raises(Exception, "::raise must be of NoReturn return type!") do
      codegen(<<-CODE)
        def raise(m : String)
        end

        fun a(a : -> Int32)
        end

        value = 1
        p = ->{ value }
        a(p)
        CODE
    end
  end

  it "allows passing an external function along" do
    codegen(<<-CODE)
      require "prelude"


      lib LibA
        fun a(a : Void* -> Void*)
      end

      fun b(a : Void* -> Void*)
        LibA.a(a)
      end
      CODE
  end

  it "allows passing an external function along (2)" do
    codegen(<<-CODE)
      lib LibFoo
        struct S
          callback : ->
        end
      end

      s = LibFoo::S.new
      s.callback = nil
      CODE
  end

  it "uses atomic allocation for closure data if closured variables have no inner pointers" do
    run(<<-CODE, Nil)
      fun __crystal_malloc64(size : UInt64) : Void*
        Pointer(Void).new(0_u64)
      end

      struct Foo
        @a = 1.2
        @b = true
      end

      x = 0
      y = Foo.new
      -> { {x, y} }
      nil
      CODE
  end

  it "uses non-atomic allocation for closure data if closured variables contain inner pointers" do
    run(<<-CODE, Nil)
      fun __crystal_malloc_atomic64(size : UInt64) : Void*
        Pointer(Void).new(0_u64)
      end

      class Foo
        @x : Foo?

        def foo
          -> { @x }
        end
      end

      x = Foo.new
      -> { x }

      y = Pointer(Void).new(0_u64)
      -> { y }

      x.foo
      nil
      CODE
  end

  it "uses non-atomic allocation for nested closure data" do
    # nested closures always contain a pointer to their parent closures
    run(<<-CODE, Bool).should be_false
      module Closure
        @@atomic = uninitialized Int32

        def self.atomic
          pointerof(@@atomic).as(Void*)
        end
      end

      fun __crystal_malloc_atomic64(size : UInt64) : Void*
        Closure.atomic
      end

      struct Proc
        def closure_data
          func = self
          ptr = pointerof(func).as({Void*, Void*}*)
          ptr.value[1]
        end
      end

      x = 0
      fn = -> do
        y = 0
        -> { x &+ y }
      end

      fn.call.closure_data.address == Closure.atomic.address
      CODE
  end
end
