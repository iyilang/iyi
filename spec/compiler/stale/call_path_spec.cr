require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/call_path"
require "compiler/iyi/stale/roots"

private def compute_fp(code : String, filename : String = "test.iyi", flags : Array(String)? = nil) : {String, Iyi::Stale::CallPathResult}
  with_tempfile("callpath.key") do |key_path|
    with_tempfile("callpath.bin") do |bin_path|
      compiler = create_spec_compiler
      compiler.prelude = "iyi/prelude"
      compiler.no_codegen = true
      compiler.stale_key = key_path
      compiler.flags = flags if flags
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

private def flatten_top_level(node : Iyi::ASTNode, into : Array(String)) : Nil
  if node.is_a?(Iyi::Expressions)
    node.expressions.each { |e| flatten_top_level(e, into) }
  elsif node.is_a?(Iyi::FileNode)
    into << "FileNode #{::Path[node.filename].parent.basename}/#{::Path[node.filename].basename}"
  else
    loc = node.location
    into << "#{node.class.name.split("::").last} #{loc ? "#{File.basename(loc.filename.to_s)}:#{loc.line_number}" : "-"}"
  end
end

private def compute_fp_and_top(code : String, filename : String, flags : Array(String)? = nil) : {String, Iyi::Stale::CallPathResult, Array(String)}
  with_tempfile("callpath.key") do |key_path|
    with_tempfile("callpath.bin") do |bin_path|
      compiler = create_spec_compiler
      compiler.prelude = "iyi/prelude"
      compiler.no_codegen = true
      compiler.stale_key = key_path
      compiler.flags = flags if flags
      program = compiler.compile(Iyi::Compiler::Source.new(filename, code), bin_path).program
      reach = program.stale_reach.not_nil!
      res = Iyi::Stale::CallPath.compute(program, reach, Iyi::Stale::Roots.default(program, filename, code))
      top = [] of String
      flatten_top_level(reach.elements.find { |e| e.kind == Iyi::Stale::ElementKind::Main }.not_nil!.node.not_nil!, top)
      {res.hex_digest, res, top}
    end
  end
end

private def top_level_divergence(normal : Array(String), warm : Array(String)) : String?
  return nil if normal == warm
  at = (0...Math.min(normal.size, warm.size)).find { |i| normal[i] != warm[i] } || Math.min(normal.size, warm.size)
  from = Math.max(at - 2, 0)
  fn, fw = normal.select(&.starts_with?("FileNode ")), warm.select(&.starts_with?("FileNode "))
  "top-level main differs at #{at}: normal=#{normal[from, 8]} warm=#{warm[from, 8]}; " +
    (fn == fw ? "same initialiser order" : "initialiser order differs: normal=#{fn} warm=#{fw}")
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

  it "observed real hello normal-vs-preanalysed gives identical call path fingerprint" do
    hello_path = File.expand_path("../../../samples/iyi/hello.iyi", __DIR__)
    hello_code = File.read(hello_path)
    obs_flags = ["iyi_observe"]

    fp1, res1, top1 = compute_fp_and_top(hello_code, hello_path, flags: obs_flags)

    ENV["IYI_WARM"] = "1"
    begin
      Iyi::Compiler.preanalysed.clear
      fp2, res2, top2 = compute_fp_and_top(hello_code, hello_path, flags: obs_flags)

      top_level_divergence(top1, top2).should be_nil

      rows1 = res1.dump_rows.to_h { |r| { {r.kind, r.key}, r.digest } }
      rows2 = res2.dump_rows.to_h { |r| { {r.kind, r.key}, r.digest } }

      all_keys = (rows1.keys + rows2.keys).uniq
      all_keys.each do |key|
        d1 = rows1[key]?
        d2 = rows2[key]?
        d1.should eq(d2), "Element #{key} digest mismatch: normal=#{d1} warm=#{d2}"
      end

      fp2.should eq(fp1)
    ensure
      Iyi::Compiler.preanalysed.clear
      ENV.delete("IYI_WARM")
    end
  end

  it "observed real modules normal-vs-preanalysed gives identical call path fingerprint" do
    modules_path = File.expand_path("../../../samples/iyi/modules.iyi", __DIR__)
    modules_code = File.read(modules_path)
    obs_flags = ["iyi_observe"]

    fp1, res1, top1 = compute_fp_and_top(modules_code, modules_path, flags: obs_flags)

    ENV["IYI_WARM"] = "1"
    begin
      Iyi::Compiler.preanalysed.clear
      fp2, res2, top2 = compute_fp_and_top(modules_code, modules_path, flags: obs_flags)

      top_level_divergence(top1, top2).should be_nil

      rows1 = res1.dump_rows.to_h { |r| { {r.kind, r.key}, r.digest } }
      rows2 = res2.dump_rows.to_h { |r| { {r.kind, r.key}, r.digest } }

      all_keys = (rows1.keys + rows2.keys).uniq
      all_keys.each do |key|
        d1 = rows1[key]?
        d2 = rows2[key]?
        d1.should eq(d2), "Element #{key} digest mismatch: normal=#{d1} warm=#{d2}"
      end

      fp2.should eq(fp1)
    ensure
      Iyi::Compiler.preanalysed.clear
      ENV.delete("IYI_WARM")
    end
  end

  it "observed initialiser order is part of CallPathFp" do
    modules_path = File.expand_path("../../../samples/iyi/modules.iyi", __DIR__)
    modules_code = File.read(modules_path)
    obs_flags = ["iyi_observe"]

    old_seed = ENV["IYI_INIT_SEED"]?
    begin
      ENV.delete("IYI_INIT_SEED")
      fp0, _, top0 = compute_fp_and_top(modules_code, modules_path, flags: obs_flags)

      ENV["IYI_INIT_SEED"] = "1"
      fp1, _, top1 = compute_fp_and_top(modules_code, modules_path, flags: obs_flags)

      top1.should_not eq(top0)
      fp1.should_not eq(fp0)
    ensure
      if old_seed
        ENV["IYI_INIT_SEED"] = old_seed
      else
        ENV.delete("IYI_INIT_SEED")
      end
    end
  end

  it "editing non-trivial body of inlined @[Effect] def in std changes observed CallPathFp" do
    runtime_file = File.join(Dir.current, "src", "std", "spec_effect_callpath_test.iyi")
    obs_flags = ["iyi_observe"]

    code1 = <<-IYI
      class File
        @[Effect(:file_read)]
        def self.custom_read(path : String) : String
          buf = path + "_v1"
          buf
        end
      end
      puts File.custom_read("test")
      IYI

    code2 = <<-IYI
      class File
        @[Effect(:file_read)]
        def self.custom_read(path : String) : String
          buf = path + "_v2"
          buf
        end
      end
      puts File.custom_read("test")
      IYI

    fp1, _ = compute_fp(code1, runtime_file, flags: obs_flags)
    fp2, _ = compute_fp(code2, runtime_file, flags: obs_flags)

    fp1.should_not eq(fp2)
  end
end
