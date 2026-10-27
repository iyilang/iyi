require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/call_path"
require "compiler/iyi/stale/roots"

private def compute_fp(code : String, filename : String = "test.iyi") : {String, Iyi::Stale::CallPathResult}
  with_tempfile("callpath.key") do |key_path|
    with_tempfile("callpath.bin") do |bin_path|
      compiler = create_spec_compiler
      compiler.prelude = "iyi/prelude"
      compiler.no_codegen = true
      compiler.stale_key = key_path
      source = Iyi::Compiler::Source.new(filename, code)
      result = compiler.compile(source, bin_path)
      program = result.program
      reach = program.stale_reach.not_nil!
      roots = Iyi::Stale::Roots.default(program, filename, code)
      cp_res = Iyi::Stale::CallPath.compute(program, reach, roots)
      {cp_res.hex_digest, cp_res}
    end
  end
end

describe "Iyi::Stale S3f: CallPathFp, typed encoder, roots, explain" do
  it "unreached def edit keeps call path fingerprint" do
    c1 = <<-IYI
    module spec/test
    def unreached
      100
    end
    def reached
      42
    end
    puts reached
    IYI

    c2 = <<-IYI
    module spec/test
    def unreached
      200
    end
    def reached
      42
    end
    puts reached
    IYI

    fp1, _ = compute_fp(c1)
    fp2, _ = compute_fp(c2)
    fp1.should eq(fp2)
  end

  it "reached def edit changes call path fingerprint" do
    c1 = <<-IYI
    module spec/test
    def reached(x : Int32) : Int32
      a = 1
      a + x + 40
    end
    puts reached(1)
    IYI

    c2 = <<-IYI
    module spec/test
    def reached(x : Int32) : Int32
      a = 2
      a + x + 40
    end
    puts reached(1)
    IYI

    fp1, _ = compute_fp(c1)
    fp2, _ = compute_fp(c2)
    fp1.should_not eq(fp2)
  end

  describe "position and location handling (D18, rows 33, 38, 45, 46)" do
    it "moved defs keep fingerprint when no location literals or magic defaults move (row 33)" do
      c1 = <<-IYI
      module spec/test
      def helper
        10
      end
      def reached
        helper + 32
      end
      puts reached
      IYI

      c2 = <<-IYI
      module spec/test



      def helper
        10
      end


      def reached
        helper + 32
      end

      puts reached
      IYI

      fp1, _ = compute_fp(c1)
      fp2, _ = compute_fp(c2)
      fp1.should eq(fp2)
    end

    it "moving call to def with magic-constant default (__LINE__) changes fingerprint (row 45)" do
      c1 = <<-IYI
      module spec/test
      def here(line = __LINE__)
        line
      end
      puts here()
      IYI

      c2 = <<-IYI
      module spec/test
      def here(line = __LINE__)
        line
      end

      puts here()
      IYI

      fp1, _ = compute_fp(c1)
      fp2, _ = compute_fp(c2)
      fp1.should_not eq(fp2)
    end

    it "comment added above call leaving magic default changes fingerprint; comment below keeps it (row 38)" do
      c_base = <<-IYI
      module spec/test
      def here(line = __LINE__)
        line
      end
      puts here()
      IYI

      c_above = <<-IYI
      module spec/test
      def here(line = __LINE__)
        line
      end
      # Added comment above call site
      puts here()
      IYI

      c_below = <<-IYI
      module spec/test
      def here(line = __LINE__)
        line
      end
      puts here()
      # Added comment below call site
      IYI

      fp_base, _ = compute_fp(c_base)
      fp_above, _ = compute_fp(c_above)
      fp_below, _ = compute_fp(c_below)

      fp_base.should_not eq(fp_above)
      fp_base.should eq(fp_below)
    end

    it "failable downcast moving line changes fingerprint (row 46)" do
      c1 = <<-IYI
      module spec/test
      class Base; end
      class Derived < Base; end
      def choose(b : Bool) : Base
        b ? Base.new : Derived.new
      end
      val = choose(true)
      puts val.as(Derived)
      IYI

      c2 = <<-IYI
      module spec/test
      class Base; end
      class Derived < Base; end
      def choose(b : Bool) : Base
        b ? Base.new : Derived.new
      end
      val = choose(true)

      puts val.as(Derived)
      IYI

      fp1, _ = compute_fp(c1)
      fp2, _ = compute_fp(c2)
      fp1.should_not eq(fp2)
    end
  end

  it "new overload capturing a reached call changes fingerprint (row 34)" do
    c_base = <<-IYI
    module spec/test
    def compute(x : Number)
      1
    end
    puts compute(42)
    IYI

    c_overload = <<-IYI
    module spec/test
    def compute(x : Number)
      1
    end
    def compute(x : Int32)
      2
    end
    puts compute(42)
    IYI

    fp1, _ = compute_fp(c_base)
    fp2, _ = compute_fp(c_overload)
    fp1.should_not eq(fp2)
  end

  describe "ivar add, type change, initializer change on reached type (row 36)" do
    it "added ivar changes fingerprint" do
      c1 = <<-IYI
      module spec/test
      class Person
        @age : Int32 = 20
        def age; @age; end
      end
      puts Person.new.age
      IYI

      c2 = <<-IYI
      module spec/test
      class Person
        @age : Int32 = 20
        @name : String = "Alice"
        def age; @age; end
      end
      puts Person.new.age
      IYI

      fp1, _ = compute_fp(c1)
      fp2, _ = compute_fp(c2)
      fp1.should_not eq(fp2)
    end

    it "changed ivar type changes fingerprint" do
      c1 = <<-IYI
      module spec/test
      class Person
        @age : Int32 = 20
        def age; @age; end
      end
      puts Person.new.age
      IYI

      c2 = <<-IYI
      module spec/test
      class Person
        @age : Int64 = 20_i64
        def age; @age; end
      end
      puts Person.new.age
      IYI

      fp1, _ = compute_fp(c1)
      fp2, _ = compute_fp(c2)
      fp1.should_not eq(fp2)
    end

    it "edited ivar initializer changes fingerprint" do
      c1 = <<-IYI
      module spec/test
      class Person
        @age : Int32 = 20
        def age; @age; end
      end
      puts Person.new.age
      IYI

      c2 = <<-IYI
      module spec/test
      class Person
        @age : Int32 = 99
        def age; @age; end
      end
      puts Person.new.age
      IYI

      fp1, _ = compute_fp(c1)
      fp2, _ = compute_fp(c2)
      fp1.should_not eq(fp2)
    end
  end

  describe "type set closure and virtual types (row 37)" do
    it "unrelated new type in a loaded file keeps fingerprint" do
      c_base = <<-IYI
      module spec/test
      abstract class Animal
        abstract def speak : String
      end
      class Dog < Animal
        def speak : String; "woof"; end
      end
      def sound(a : Animal)
        a.speak
      end
      puts sound(Dog.new)
      IYI

      c_unrelated = <<-IYI
      module spec/test
      abstract class Animal
        abstract def speak : String
      end
      class Dog < Animal
        def speak : String; "woof"; end
      end
      class UnrelatedWidget
        def unused; 999; end
      end
      def sound(a : Animal)
        a.speak
      end
      puts sound(Dog.new)
      IYI

      fp1, _ = compute_fp(c_base)
      fp2, _ = compute_fp(c_unrelated)
      fp1.should eq(fp2)
    end

    it "new subclass of a reached virtual type changes fingerprint" do
      c_base = <<-IYI
      module spec/test
      abstract class Animal
        abstract def speak : String
      end
      class Dog < Animal
        def speak : String; "woof"; end
      end
      def sound(a : Animal)
        a.speak
      end
      puts sound(Dog.new)
      IYI

      c_subclass = <<-IYI
      module spec/test
      abstract class Animal
        abstract def speak : String
      end
      class Dog < Animal
        def speak : String; "woof"; end
      end
      class Cat < Animal
        def speak : String; "meow"; end
      end
      def sound(a : Animal)
        a.speak
      end
      puts sound(Dog.new)
      IYI

      fp1, _ = compute_fp(c_base)
      fp2, _ = compute_fp(c_subclass)
      fp1.should_not eq(fp2)
    end
  end

  it "Int32 | String arg gives one fingerprint in either declaration order (row 47)" do
    cA = <<-IYI
    module spec/test
    def format_val(x : Int32 | String)
      x.to_s
    end
    puts format_val(1)
    IYI

    cB = <<-IYI
    module spec/test
    def format_val(x : String | Int32)
      x.to_s
    end
    puts format_val(1)
    IYI

    fpA, resA = compute_fp(cA)
    fpB, resB = compute_fp(cB)
    fpA.should eq(fpB)
  end

  it "two private same-name types with different bodies give ambiguous key" do
    with_tempfile("callpath.key") do |key_path|
      with_tempfile("callpath.bin") do |bin_path|
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.no_codegen = true
        compiler.stale_key = key_path

        program = compiler.compile(Iyi::Compiler::Source.new("test.iyi", "module spec/test\nputs 1\n"), bin_path).program
        reach = program.stale_reach.not_nil!
        roots = Iyi::Stale::Roots.default(program, "test.iyi", "module spec/test\nputs 1\n")

        elem1 = Iyi::Stale::Element.new(Iyi::Stale::ElementKind::Type, "Helper", Iyi::NumberLiteral.new(1), nil, nil, nil)
        elem2 = Iyi::Stale::Element.new(Iyi::Stale::ElementKind::Type, "Helper", Iyi::NumberLiteral.new(2), nil, nil, nil)
        reach.elements << elem1
        reach.elements << elem2

        res = Iyi::Stale::CallPath.compute(program, reach, roots)
        res.ambiguous?.should be_true
        res.ambiguous_keys.should contain("Helper")
      end
    end
  end

  it "one corpus file checked in two compiler processes gives one fingerprint (row 43)" do
    code = <<-IYI
    module spec/test
    def fib(n : Int32) : Int32
      n <= 1 ? n : fib(n - 1) + fib(n - 2)
    end
    puts fib(10)
    IYI

    fp1, _ = compute_fp(code)
    fp2, _ = compute_fp(code)
    fp1.should eq(fp2)

    ENV["IYI_WARM"] = "1"
    begin
      Iyi::Compiler.preanalysed.clear
      fp3, _ = compute_fp(code)
      fp3.should eq(fp1)
    ensure
      Iyi::Compiler.preanalysed.clear
      ENV.delete("IYI_WARM")
    end
  end
  it "warm build with definition typing witness gives identical call path fingerprint" do
    code = <<-IYI
    module spec/test
    trait Greetable
      abstract def greet : String
    end
    def say_hi(g : Greetable) : String
      g.greet
    end
    puts 42
    IYI

    fp1, _ = compute_fp(code)
    ENV["IYI_WARM"] = "1"
    begin
      Iyi::Compiler.preanalysed.clear
      fp2, _ = compute_fp(code)
      fp2.should eq(fp1)
    ensure
      Iyi::Compiler.preanalysed.clear
      ENV.delete("IYI_WARM")
    end
  end

  it "warm build compiles NamedTuple.new without generic allocation error" do
    code = <<-IYI
    module spec/test
    struct ::NamedTuple
      def self.new(**opts : **T)
        opts
      end
    end
    empty = NamedTuple.new
    puts 42
    IYI

    ENV["IYI_WARM"] = "1"
    begin
      Iyi::Compiler.preanalysed.clear
      fp, _ = compute_fp(code)
      fp.should_not be_empty
    ensure
      Iyi::Compiler.preanalysed.clear
      ENV.delete("IYI_WARM")
    end
  end

  it "produces expected dump rows and explain keys" do
    code = <<-IYI
    module spec/test
    def multiply(a : Int32, b : Int32) : Int32
      a * b
    end
    puts multiply(6, 7)
    IYI

    _, res = compute_fp(code)
    res.dump_rows.should_not be_empty
    res.explain.should_not be_empty
    res.explain.keys.should contain("src:test.iyi")

    sample_row = res.dump_rows.find { |r| r.key.includes?("multiply") }
    sample_row.should_not be_nil
    sample_row.not_nil!.kind.should eq("def")
    sample_row.not_nil!.digest.size.should eq(64)
  end
end
