require "../../spec_helper"

# iyi mode (iyi prelude, iyi object layout).
#
# A fold typed before a module grows is settled to the layout actually built,
# so the program sees the final size. A type argument built from a layout that
# grows later cannot be corrected without changing its type, so it is refused
# with a compile error at the expression that holds it.

private def iyi_compiler
  compiler = create_spec_compiler
  compiler.prelude = "iyi/prelude"
  compiler
end

private def run_iyi(name : String, code : String) : String
  File.write "#{name}.iyi", code
  source = Iyi::Compiler::Source.new(File.expand_path("#{name}.iyi"), code)
  iyi_compiler.compile(source, File.expand_path(name))
  Process.capture(File.expand_path(name))
end

private def growing_module_program(body : String) : String
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

      def v : T
        @v
      end
    end

    #{body}
    CODE
end

describe "Codegen: iyi layout folds" do
  it "settles a sizeof of a tuple whose module grew after the fold (P1)" do
    with_tempdir("layout-fold-iyi-p1") do
      run_iyi("layout_fold_p1", growing_module_program(<<-CODE)).should eq("32\n32\n32\n")
        a = G(Int8).new(1_i8).as(M)
        s1 = sizeof({Int32, M})
        b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)
        puts s1
        puts sizeof(typeof({1, b}))
        puts sizeof({Int32, M})
        CODE
    end
  end

  it "keeps a sizeof of a module that never grows (P1 control)" do
    with_tempdir("layout-fold-iyi-p1-stable") do
      run_iyi("layout_fold_p1_stable", growing_module_program(<<-CODE)).should eq("8\n")
        a = G(Int8).new(1_i8).as(M)
        puts sizeof({Int32, M})
        CODE
    end
  end

  it "settles an offsetof that precedes a grown module field and reads the field back (P4)" do
    with_tempdir("layout-fold-iyi-p4") do
      run_iyi("layout_fold_p4", %(@[Unsafe("reads the field at its computed byte offset")]\n) + growing_module_program(<<-CODE)).should eq("24\ntrue\n7\n")
        struct S
          def initialize(@a : M, @b : Int32)
          end
        end

        x = G(Int8).new(1_i8).as(M)
        off = offsetof(S, @b)
        s = S.new(G({Int64, Int64}).new({1_i64, 2_i64}), 7)
        puts off
        puts off == sizeof(typeof(s.@a))
        puts (pointerof(s).as(UInt8*) + sizeof(typeof(s.@a))).as(Int32*).value
        CODE
    end
  end

  it "settles a macro-expanded sizeof of a class (P7)" do
    with_tempdir("layout-fold-iyi-p7") do
      run_iyi("layout_fold_p7", <<-CODE).should eq("8\ntrue\ntrue\n")
        class C
          def initialize(@a : Int64, @b : Int64)
          end
        end

        {% begin %}
          X = {{ sizeof(C) }}
        {% end %}
        c = C.new(1, 2)
        puts X
        puts instance_sizeof(C) == 2 * sizeof(Int64)
        puts instance_sizeof(typeof(c)) == 2 * sizeof(Int64)
        CODE
    end
  end

  it "refuses a stale type argument (P2)" do
    with_tempdir("layout-fold-iyi-p2") do
      expect_raises(Iyi::TypeException, /when it was used as a type argument, but/) do
        run_iyi("layout_fold_p2", growing_module_program(<<-CODE))
          a = G(Int8).new(1_i8).as(M)
          buf = StaticArray(UInt8, sizeof({Int32, M})).new
          b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)
          puts buf.size
          CODE
      end
    end
  end

  it "refuses a stale type argument built from a recursive generic (P3)" do
    with_tempdir("layout-fold-iyi-p3") do
      expect_raises(Iyi::TypeException, /when it was used as a type argument, but/) do
        run_iyi("layout_fold_p3", <<-CODE)
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
          puts z.n
          puts sizeof(typeof({x}))
          CODE
      end
    end
  end

  it "refuses the type argument of P6, which is stale once the module grows" do
    with_tempdir("layout-fold-iyi-p6") do
      expect_raises(Iyi::TypeException, /when it was used as a type argument, but/) do
        run_iyi("layout_fold_p6", growing_module_program(<<-CODE))
          a = G(Int8).new(1_i8).as(M)
          e = sizeof({Int32, M})
          b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)
          buf = StaticArray(UInt8, sizeof({Int32, M})).new
          puts e
          puts buf.size
          CODE
      end
    end
  end

  it "gives a type argument sized after the final growth its final value (P6')" do
    with_tempdir("layout-fold-iyi-p6-prime") do
      run_iyi("layout_fold_p6_prime", growing_module_program(<<-CODE)).should eq("32\n")
        a = G(Int8).new(1_i8).as(M)
        b = G({Int64, Int64}).new({1_i64, 2_i64}).as(M)
        buf = StaticArray(UInt8, sizeof({Int32, M})).new
        puts buf.size
        CODE
    end
  end

  it "keeps a type argument's value when the module never grows (control)" do
    with_tempdir("layout-fold-iyi-type-arg-stable") do
      run_iyi("layout_fold_type_arg_stable", growing_module_program(<<-CODE)).should eq("8\n")
        a = G(Int8).new(1_i8).as(M)
        buf = StaticArray(UInt8, sizeof({Int32, M})).new
        puts buf.size
        CODE
    end
  end

  it "runs the array dup that aborts under upstream Crystal to completion (P5)" do
    with_tempdir("layout-fold-iyi-p5") do
      output = run_iyi("layout_fold_p5", growing_module_program(<<-CODE)).lines
        arr = [{1, G(UInt8).new(1_u8).as(M)}]
        d1 = arr.dup
        arr << {2, G({Int64, Int64}).new({3_i64, 4_i64}).as(M)}
        d2 = arr.dup
        puts d2.size
        puts d2[0][0]
        puts d2[1][0]
        puts d2[0][1].is_a?(G(UInt8))
        puts d2[1][1].is_a?(G({Int64, Int64}))
        puts d2[0][1].as(G(UInt8)).v
        puts d2[1][1].as(G({Int64, Int64})).v[0]
        puts d2[1][1].as(G({Int64, Int64})).v[1]
        puts arr[0][1].as(G(UInt8)).v
        puts arr[1][1].as(G({Int64, Int64})).v[0]
        puts arr[1][1].as(G({Int64, Int64})).v[1]
        puts arr == arr
        puts d2 == arr
        puts arr[0] == arr[0]
        puts d2[0] == arr[0]
        puts arr[1] == arr[1]
        puts d2[1] == arr[1]
        CODE
      output.size.should eq 17
      # Fields and type values of the copy and of the original, read independently of `==`. The
      # one-byte implementor is a `UInt8` because the prelude gives `Int8` neither `to_s` nor `==`
      # (those are `std/int`), so an `Int8` field could not be checked here.
      output[0, 11].should eq %w(2 1 2 true true 1 3 4 1 3 4)
      # Equality contract: a copy compares as its original does with itself. The
      # baseline is what this build gives, so nothing here assumes `true`.
      output[12].should eq output[11]
      output[14].should eq output[13]
      output[16].should eq output[15]
    end
  end
end
