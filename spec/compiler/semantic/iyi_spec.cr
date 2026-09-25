require "../../spec_helper"

# Semantics of the iyi declarations: `module` headers, an import's names, and `impl`.
#
# `import` is not covered here — it resolves against files on disk, so it is
# exercised by `samples/iyi/modules.iyi` rather than by this file. Everything
# else needs only that the used module exist, so these specs declare it
# directly instead of importing it.
describe "Semantic: iyi" do
  describe "import names" do
    it "resolves a function of a used module from module top level" do
      assert_type(<<-CODE) { int32 }
        module App
          module Greeter
            extend self

            def polite
              1
            end
          end
        end

        module Consumer
          import app/greeter::*

          def self.go
            polite
          end
        end

        Consumer.go
        CODE
    end

    it "resolves a function of a used module from a nested type" do
      # The case `include` cannot cover: the directive is on `Consumer`, and
      # `Consumer::User` is not on `Consumer`'s ancestor chain.
      assert_type(<<-CODE) { int32 }
        module App
          module Greeter
            extend self

            def polite
              1
            end
          end
        end

        module Consumer
          import app/greeter::*

          struct User
            def greet
              polite
            end
          end
        end

        Consumer::User.new.greet
        CODE
    end

    it "resolves a type of a used module" do
      assert_type(<<-CODE) { types["Consumer"].types["User"] }
        module App
          module Greeter
            module Greet
            end
          end
        end

        module Consumer
          import app/greeter::*

          struct User
            include Greet
          end
        end

        Consumer::User.new
        CODE
    end

    it "does not re-export what it brought in" do
      # An import's names are the consumer's, so importing the consumer must not
      # be a way to reach what the consumer used.
      assert_error <<-CODE, "undefined method 'polite'"
        module App
          module Greeter
            extend self

            def polite
              1
            end
          end
        end

        module Consumer
          import app/greeter::*
        end

        Consumer.polite
        CODE
    end

    it "does not reach a name the selective form left out" do
      assert_error <<-CODE, "undefined local variable or method 'polite'"
        module App
          module Greeter
            extend self

            def polite
              1
            end

            def title
              2
            end
          end
        end

        module Consumer
          import app/greeter::{title}

          polite
        end
        CODE
    end

    it "reaches a name the selective form listed" do
      assert_type(<<-CODE) { int32 }
        module App
          module Greeter
            extend self

            def polite
              1
            end

            def title
              2
            end
          end
        end

        module Consumer
          import app/greeter::{polite}

          def self.go
            polite
          end
        end

        Consumer.go
        CODE
    end

    it "takes type names in the selective form too" do
      assert_type(<<-CODE) { types["Consumer"].types["User"] }
        module App
          module Greeter
            module Greet
            end

            module Loud
            end
          end
        end

        module Consumer
          import app/greeter::{Greet}

          struct User
            include Greet
          end
        end

        Consumer::User.new
        CODE
    end

    it "does not reach a type the selective form left out" do
      assert_error <<-CODE, "undefined constant Loud"
        module App
          module Greeter
            module Greet
            end

            module Loud
            end
          end
        end

        module Consumer
          import app/greeter::{Greet}

          struct User
            include Loud
          end
        end
        CODE
    end
  end

  describe "a nilable receiver" do
    it "says the two idioms for a local" do
      assert_error <<-CODE, "x can be nil here: narrow it first (`if x`) or give the nil an answer (`x || default`)"
        class B
          def size
            1
          end
        end

        def make(b : B) : B?
          if b
            nil
          else
            b
          end
        end

        x = make(B.new)
        x.size
        CODE
    end

    it "says the narrowing form for an instance variable" do
      assert_error <<-CODE, "@v can be nil here: narrow it first (`if value = @v`)"
        class B
          def size
            1
          end
        end

        class A
          @v : B?

          def initialize
            @v = nil
          end

          def g
            @v.size
          end
        end

        A.new.g
        CODE
    end
  end

  describe "Crystal's spelling" do
    it "names Program.args for ARGV" do
      assert_error "ARGV", "The arguments are `Program.args`"
    end

    it "names Program.env for ENV, and the module that has the map" do
      assert_error "ENV", "`Program.env(\"NAME\")`"
      assert_error "ENV", "comes with `import std/env::{ENV}`"
    end

    it "names the module that has rand" do
      assert_error "rand(10)", "comes with `import std/random::{Random}`"
    end

    it "names the std module that declares an unimported type" do
      assert_error "x = Deque(Int32).new", "`Deque` comes with `import std/deque::{Deque}`"
      assert_error "x = JSON.parse(\"1\")", "comes with `import std/json::{JSON}`"
      assert_error "x = Nosuch.new", "undefined constant Nosuch"
    end

    it "names Base64's plain spellings for the other library's" do
      assert_error "struct B64\n  def self.encode(s : String) : String\n    s\n  end\nend\nB64.strict_encode(\"x\")", "it is the other library's `strict_encode`"
      assert_error "struct B64\n  def self.decode(s : String) : String\n    s\n  end\nend\nB64.decode_string(\"x\")", "the other library's `decode_string`"
    end

    it "names std/int for a method the integer tower has there" do
      assert_error "x = 5_u32\nx + 1_u32", "`+` on UInt32 is in `std/int`"
      assert_error "x = 5_u64\nx << 3", "`<<` on UInt64 is in `std/int`"
      assert_error "x = 5_u64\nx.to_u32", "`to_u32` on UInt64 is in `std/int`"
    end

    it "names puts value.inspect for p" do
      assert_error "p 1", "`puts value.inspect` is the spelling here; `p` comes with `import std/kernel::{p}`"
    end

    it "names elsif for elif, and a plain assignment for let" do
      assert_error "x = true\nif x\n  1\nelif x\n  2\nend", "`elsif` is the spelling here."
      assert_error "let x = 1", "There is no `let`: a variable is `x = 1`"
    end

    it "names size, to_s and nil for len, str and null" do
      assert_error "len(1)", "`.size` is the spelling here"
      assert_error "str(1)", "`.to_s` is the spelling here"
      assert_error "x = null", "`nil` is the spelling here"
    end

    # The names Python, JavaScript, Rust and Java write for values,
    # containers and methods this language has under other names. Each of
    # these arrived as `undefined constant X` or `undefined method X`,
    # which is true and says nothing about what to write instead — and for
    # a method on a prelude type, as the library's size rule, which is a
    # sentence about policy where the reader needed a spelling.
    it "names the spelling for a value, a container, a method and `new`" do
      assert_error "x = None", "`nil` is the spelling here"
      assert_error "x = True", "`true` is lowercase here"
      assert_error "xs : List(Int32) = [1]", "`Array(T)` is the name here"
      assert_error "puts \"abc\".length", "`size` is the spelling here"
      assert_error "puts \"abc\".filter", "`select` is the spelling here"
      assert_error "throw \"bad\"", "`raise \"why\"` is the spelling here"
    end

    it "says the prelude's size rule for a method a prelude type lacks" do
      assert_error <<-CODE, "iyi's prelude has no `split` on String: it is small by rule"
        "a,b".split(",")
        CODE
    end

    it "names the std module that implements the trait the method is on" do
      # "undefined method 'clamp' for String" is true and useless when
      # `import std/traits` is the whole answer: std implements the
      # trait for the prelude's types, so the method is one line away
      # rather than absent.
      assert_error <<-CODE, "`std/traits` implements `Comparable` for String"
        "b".clamp("a", "c")
        CODE
    end

    it "still says the size rule when no std module has the method" do
      assert_error <<-CODE, "iyi's prelude has no `frobnicate` on String"
        "a".frobnicate
        CODE
    end

    it "names the `_by` sibling when a block is given to the plain name" do
      # This library pairs a method with `_by` where Crystal passes a
      # block to the same name, and the pair is looked up on the
      # receiver rather than listed, so it cannot go stale.
      assert_error <<-CODE, "`total_by` is the block form"
        class Ledger
          def total : Int32
            0
          end

          def total_by(& : Int32 -> Int32) : Int32
            yield 1
          end
        end

        Ledger.new.total { |x| x }
        CODE
    end

    it "says nothing about the rule for a class the program declares" do
      exception = expect_raises(Iyi::TypeException) do
        semantic <<-CODE
          class Foo
          end

          Foo.new.bar
          CODE
      end
      exception.to_s.should_not contain("small by rule")
    end

    it "says sleep's unit when it is given seconds" do
      assert_error <<-CODE, "`sleep` takes milliseconds, an `Int32`: `sleep 100` is a tenth of a second."
        def sleep(ms : Int32)
        end

        sleep 0.1
        CODE
    end

    it "names std/time for Time" do
      assert_error "Time.now", "`Time` lives in `std/time`: write `import std/time::{Time}`"
    end

    it "names the literal edges for Int32::MAX" do
      assert_error "Int32::MAX", "There is no `Int32::MAX`: the edges are the literals, 2147483647 and -2147483648"
    end

    it "says a program has no exit, and what a failure is" do
      assert_error "exit 1", "There is no `exit`: a program ends when its last line runs, and a failure is a panic"
    end

    it "names stdin.gets for gets" do
      assert_error "line = gets", "`stdin.gets` reads a line"
    end

    it "names std/format for printf and for String#%" do
      assert_error %(printf("%d", 1)), "come with `import std/format::{printf}`"
      assert_error %("%d" % 1), "`%` on a String is a format string, and it comes with `import std/format`"
    end

    it "keeps the format hint off a remainder" do
      exception = expect_raises(Iyi::TypeException) do
        semantic <<-CODE
          class Foo
          end

          Foo.new % 2
          CODE
      end
      exception.to_s.should_not contain("format string")
    end

    it "says there is no try, and what narrows a nil" do
      assert_error "x = 1 || nil\nx.try { |v| v }", "There is no `try`: narrow the nil first"
    end
  end

  # iyi: `rescue` compiled and never ran - a panic unwinds by registry to a
  # task boundary, through no handler on the way - and `ensure` ran on the
  # ordinary exit only. Both are refused in an iyi file; a `.cr` file keeps
  # them, and so does the handler `defer` lowers to (bench/panics.sh runs it).
  describe "rescue and ensure" do
    it "refuses a rescue in an iyi file" do
      assert_error <<-CODE, "iyi has no exceptions to rescue", filename: "prog.iyi"
        begin
          1
        rescue
          2
        end
        CODE
    end

    it "refuses an ensure in an iyi file, naming defer" do
      assert_error <<-CODE, "iyi has no `ensure`", filename: "prog.iyi"
        begin
          1
        ensure
          2
        end
        CODE
    end

    it "keeps a Crystal file's rescue" do
      assert_type("begin; 1; rescue; 2; end", filename: "prog.cr") { int32 }
    end
  end

  describe "import name conflicts (SPEC.md II.3)" do
    it "reports an ambiguous function at the point of use" do
      assert_error <<-CODE, "'title' is ambiguous here"
        module App
          module Greeter
            extend self

            def title
              1
            end
          end

          module Formal
            extend self

            def title
              2
            end
          end
        end

        module Consumer
          import app/greeter::*
          import app/formal::*

          def self.go
            title
          end
        end

        Consumer.go
        CODE
    end

    it "reports an ambiguous type at the point of use" do
      assert_error <<-CODE, "'Greet' is ambiguous here"
        module App
          module Greeter
            module Greet
            end
          end

          module Formal
            module Greet
            end
          end
        end

        module Consumer
          import app/greeter::*
          import app/formal::*

          struct User
            include Greet
          end
        end
        CODE
    end

    it "does not report two used modules that merely could clash" do
      # Two modules exporting one name is not by itself a mistake. Nothing is
      # wrong until a name is written that could mean either.
      assert_type(<<-CODE) { int32 }
        module App
          module Greeter
            extend self

            def title
              1
            end

            def polite
              1
            end
          end

          module Formal
            extend self

            def title
              2
            end
          end
        end

        module Consumer
          import app/greeter::*
          import app/formal::*

          def self.go
            polite
          end
        end

        Consumer.go
        CODE
    end

    it "resolves an otherwise ambiguous name once one directive is narrowed" do
      assert_type(<<-CODE) { int32 }
        module App
          module Greeter
            extend self

            def title
              1
            end
          end

          module Formal
            extend self

            def title
              true
            end

            def address
              2
            end
          end
        end

        module Consumer
          import app/greeter::*
          import app/formal::{address}

          def self.go
            title
          end
        end

        Consumer.go
        CODE
    end

    # II.3's other rule, and the one that keeps a library from breaking its
    # consumers by adding an export. Checked from inside a nested type,
    # because that is where getting the search order wrong shows up.
    #
    # It needs a module header, so nothing in the source is at top level and
    # there is no last expression to assert a type on. The `: Bool` return
    # restriction is the assertion instead: only one of the two candidates
    # satisfies it, so which one was chosen decides whether this compiles.
    # The pair of specs is what pins it down — the second shows the used
    # function really is found when there is no local one to beat it.

    it "raises on importing names from something that is not a module" do
      assert_error <<-CODE, %(can't import names from App::Greeter, it's a struct)
        module App
          struct Greeter
          end
        end

        module Consumer
          import app/greeter::*
        end
        CODE
    end
  end

  describe "module header" do
    it "puts a module's own functions in scope for the types declared in it" do
      # An iyi module is a compilation unit, so its `def`s are functions in
      # lexical scope. Crystal modules do not work this way, which is what the
      # next spec pins down.
      assert_no_errors <<-CODE
        module app/thing

        def helper
          1
        end

        struct T
          def go : Int32
            helper
          end
        end

        T.new.go
        CODE
    end

    it "leaves a Crystal module scoping exactly as it was" do
      assert_error <<-CODE, "undefined local variable or method 'helper'"
        module Thing
          extend self

          def helper
            1
          end

          struct T
            def go
              helper
            end
          end
        end

        Thing::T.new.go
        CODE
    end
  end

  describe "traits are their own type (SPEC.md R-3)" do
    it "refuses to reopen a struct as a trait" do
      assert_error <<-CODE, "Foo is not a trait, it's a struct"
        module App
          struct Foo
          end

          trait Foo
            abstract def show
          end
        end
        CODE
    end

    it "refuses to reopen a module as a trait" do
      assert_error <<-CODE, "Greet is not a trait, it's a module"
        module App
          module Greet
          end

          trait Greet
            abstract def greet
          end
        end
        CODE
    end

    it "refuses to `include` a trait" do
      # The whole point of R-3: a type acquires a trait through an impl, whose
      # location the orphan rule can check. `include` has no such rule.
      assert_error <<-CODE, "can't include App::Show::Showable, it's a trait"
        module App
          module Show
            trait Showable
              abstract def show
            end

            struct Foo
              include Showable

              def show
                1
              end
            end
          end
        end
        CODE
    end

    it "refuses to `extend` a trait" do
      assert_error <<-CODE, "can't extend App::Show::Showable, it's a trait"
        module App
          module Show
            trait Showable
              abstract def show
            end

            struct Foo
              extend Showable
            end
          end
        end
        CODE
    end

    it "still lets an impl register the trait" do
      # `impl` reaches the same machinery `include` does, so refusing the
      # written directive must not close the path the impl needs.
      assert_type(<<-CODE) { bool }
        module App
          module Show
            trait Showable
              abstract def show : Int32
            end

            struct Foo
            end

            impl Showable for Foo
              def show : Int32
                1
              end
            end
          end
        end

        App::Show::Foo.new.is_a?(App::Show::Showable)
        CODE
    end

    it "refuses to import names from a trait" do
      assert_error <<-CODE, "can't import names from App::Show::Showable, it's a trait"
        module App
          module Show
            trait Showable
              abstract def show
            end
          end
        end

        module Consumer
          import app/show/showable::*
        end
        CODE
    end

    it "still lets the selective form name a trait" do
      # `import app/show::{Showable}` loads the *module* and selects a type name
      # from it, which is II.3 working as specified — only naming the trait as
      # the used module itself is refused.
      assert_type(<<-CODE) { types["App"].types["Show"].types["Foo"] }
        module App
          module Show
            trait Showable
              abstract def show : Int32
            end

            struct Foo
            end

            impl Showable for Foo
              def show : Int32
                1
              end
            end
          end
        end

        module Consumer
          import app/show::{Showable, Foo}

          def self.build : Showable
            Foo.new
          end
        end

        Consumer.build
        CODE
    end

    it "refuses to implement a module" do
      assert_error <<-CODE, "can't implement App::Greeter, it's a module. Only a trait can be implemented"
        module App
          module Greeter
          end

          struct Foo
          end

          impl Greeter for Foo
            def greet
              1
            end
          end
        end
        CODE
    end

    it "refuses to implement a trait for a trait" do
      # A blanket impl in disguise: it would give every implementer of one
      # trait a second one, from a module that has heard of neither.
      assert_error <<-CODE, "it's a trait"
        module App
          module Show
            trait Showable
              abstract def show
            end

            trait Loud
              abstract def shout
            end

            impl Showable for Loud
              def show
                1
              end
            end
          end
        end
        CODE
    end

    it "reports a requirement the impl does not satisfy, at the impl" do
      # Crystal's abstract-def check reports at the point the type is first
      # used and names the type. This names the impl and the method.
      assert_error <<-CODE, "impl App::Show::Showable for App::Show::Foo is missing a method required by the trait: show"
        module App
          module Show
            trait Showable
              abstract def show : Int32
            end

            struct Foo
            end

            impl Showable for Foo
            end
          end
        end
        CODE
    end

    it "reports every missing requirement at once" do
      assert_error <<-CODE, "is missing methods required by the trait: shout, show"
        module App
          module Show
            trait Showable
              abstract def show : Int32
              abstract def shout : Int32

              def loud : Int32
                shout
              end
            end

            struct Foo
            end

            impl Showable for Foo
            end
          end
        end
        CODE
    end

    it "does not report a requirement an unused type leaves unimplemented" do
      # The point of checking at the impl: today this compiles clean, because
      # Crystal only reports an unimplemented abstract where the type is used.
      assert_error <<-CODE, "is missing a method required by the trait: show"
        module App
          module Show
            trait Showable
              abstract def show : Int32
            end

            struct Unused
            end

            impl Showable for Unused
            end
          end
        end

        1
        CODE
    end

    it "accepts a requirement satisfied by a default method" do
      # A trait method with a body is not a requirement, so an impl that
      # defines only the abstract one is complete.
      assert_type(<<-CODE) { int32 }
        module App
          module Show
            trait Showable
              abstract def show : Int32

              def shown : Int32
                show
              end
            end

            struct Foo
            end

            impl Showable for Foo
              def show : Int32
                21
              end
            end
          end
        end

        App::Show::Foo.new.shown
        CODE
    end

    it "keeps a trait usable as a type restriction" do
      # The reason `TraitType` subclasses the module type rather than replacing
      # it: a value typed by the trait still dispatches to the impl.
      assert_type(<<-CODE) { int32 }
        module App
          module Show
            trait Showable
              abstract def show : Int32
            end

            struct Foo
            end

            impl Showable for Foo
              def show : Int32
                1
              end
            end

            def self.render(x : Showable) : Int32
              x.show
            end
          end
        end

        App::Show.render(App::Show::Foo.new)
        CODE
    end
  end

  describe "impl coherence (R-3)" do
    it "allows an impl in the module that defines the trait" do
      assert_type(<<-CODE) { types["App"].types["Data"].types["Foo"] }
        module App
          module Data
            struct Foo
            end
          end

          module Show
            trait Showable
              abstract def show
            end

            impl Showable for App::Data::Foo
              def show
                1
              end
            end
          end
        end

        App::Data::Foo.new
        CODE
    end

    it "allows an impl in the module that defines the type" do
      assert_type(<<-CODE) { types["App"].types["Data"].types["Foo"] }
        module App
          module Show
            trait Showable
              abstract def show
            end
          end

          module Data
            struct Foo
            end

            impl App::Show::Showable for Foo
              def show
                1
              end
            end
          end
        end

        App::Data::Foo.new
        CODE
    end

    it "refuses an impl in a module that defines neither" do
      # The case the import DAG does not rule out on its own: a third module
      # that can name both is free to write the impl, and so is a fourth.
      assert_error <<-CODE, "an impl must live in the module that defines the trait"
        module App
          module Show
            trait Showable
              abstract def show
            end
          end

          module Data
            struct Foo
            end
          end

          module Orphan
            impl App::Show::Showable for App::Data::Foo
              def show
                1
              end
            end
          end
        end
        CODE
    end

    it "refuses an impl where neither declaration belongs to a module" do
      # The top level is not a module. Treating it as one is what used to make
      # the rule vacuous for `Error`, which the compiler owns, and for a
      # prelude type: every module was trivially "inside" it.
      assert_error <<-CODE, "neither belongs to a module, so there is no module this impl could be at home in", filename: "x.iyi"
        module App
          module Orphan
            impl Error for String
              def message : String
                self
              end
            end
          end
        end
        CODE
    end

    it "refuses an impl of a module-less trait outside the type's module" do
      # With no module on the trait's side, only the type's side is left to
      # satisfy — and this impl is in neither.
      assert_error <<-CODE, "an impl must live in the module that defines the type (App::Data)", filename: "x.iyi"
        module App
          module Data
            struct Foo
            end
          end

          module Orphan
            impl Error for App::Data::Foo
              def message : String
                "x"
              end
            end
          end
        end
        CODE
    end

    it "allows an impl of a module-less trait in the type's own module" do
      assert_type(<<-CODE, filename: "x.iyi") { types["App"].types["Data"].types["Foo"] }
        module App
          module Data
            struct Foo
            end

            impl Error for Foo
              def message : String
                "x"
              end
            end
          end
        end

        App::Data::Foo.new
        CODE
    end

    it "allows an impl for a module-less type from the trait's own module" do
      # Implementing a trait you own for a type you do not is the other side of
      # the rule, and it stays open — this is how `std/traits` reaches `Int32`.
      assert_type(<<-CODE, filename: "x.iyi") { int32 }
        module App
          module Show
            trait Showable
              abstract def show : Int32
            end

            impl Showable for Int32
              def show : Int32
                1
              end
            end
          end
        end

        1
        CODE
    end

    it "is vacuous when neither declaration is in a module" do
      # A program that never writes a module header is one compilation unit,
      # so there is no other module for an impl to have gone in.
      assert_type(<<-CODE) { types["Foo"] }
        trait Showable
          abstract def show
        end

        struct Foo
        end

        impl Showable for Foo
          def show
            1
          end
        end

        Foo.new
        CODE
    end
  end

  describe "generic impls (SPEC.md II.7)" do
    it "implements a trait for every instantiation of a generic type" do
      assert_type(<<-CODE) { int32 }
        trait Showable
          abstract def show
        end

        struct Box(T)
          def initialize(@value : T)
          end

          def value
            @value
          end
        end

        impl Showable for Box(T) forall T
          def show
            value
          end
        end

        Box.new(1).show
        CODE
    end

    it "binds the impl's own parameter names positionally" do
      # `Pair` declared `A, B`; the impl calls them `X, Y`. An impl states
      # arity, not vocabulary — Crystal requires a reopened generic to repeat
      # the declared names, which leaks a type's private naming.
      assert_type(<<-CODE) { bool }
        trait Showable
          abstract def show
        end

        struct Pair(A, B)
          def initialize(@first : A, @second : B)
          end

          def second
            @second
          end
        end

        impl Showable for Pair(X, Y) forall X, Y
          def show : Y
            second
          end
        end

        Pair.new(1, true).show
        CODE
    end

    it "requires the binder" do
      assert_error <<-CODE, "introduce the parameters with `forall`"
        trait Showable
          abstract def show
        end

        struct Box(T)
        end

        impl Showable for Box(T)
          def show
            1
          end
        end
        CODE
    end

    it "refuses a specialised impl" do
      assert_error <<-CODE, "iyi has no specialised impls"
        trait Showable
          abstract def show
        end

        struct Box(T)
        end

        impl Showable for Box(Int32)
          def show
            1
          end
        end
        CODE
    end

    it "refuses a concrete argument alongside a binder" do
      assert_error <<-CODE, "iyi has no specialised impls"
        trait Showable
          abstract def show
        end

        struct Pair(A, B)
        end

        impl Showable for Pair(T, Int32) forall T
          def show
            1
          end
        end
        CODE
    end

    it "refuses a blanket impl" do
      assert_error <<-CODE, "can't implement Showable for every type"
        trait Showable
          abstract def show
        end

        impl Showable for T forall T
          def show
            1
          end
        end
        CODE
    end

    it "refuses a blanket impl before complaining about its bound" do
      # Refusing the blanket form is permanent; the bound being unimplemented
      # is not. The permanent answer is the more useful one.
      assert_error <<-CODE, "can't implement Showable for every type"
        trait Showable
          abstract def show
        end

        impl Showable for T forall T : Showable
          def show
            1
          end
        end
        CODE
    end

    it "rejects bounds as unimplemented" do
      assert_error <<-CODE, "trait bounds on impl type parameters"
        trait Showable
          abstract def show
        end

        struct Box(T)
        end

        impl Showable for Box(T) forall T : Showable
          def show
            1
          end
        end
        CODE
    end

    it "checks arity" do
      assert_error <<-CODE, "wrong number of type vars"
        trait Showable
          abstract def show
        end

        struct Box(T)
        end

        impl Showable for Box(T, U) forall T, U
          def show
            1
          end
        end
        CODE
    end

    it "refuses binding one parameter twice" do
      assert_error <<-CODE, "is bound twice"
        trait Showable
          abstract def show
        end

        struct Pair(A, B)
        end

        impl Showable for Pair(T, T) forall T
          def show
            1
          end
        end
        CODE
    end

    it "refuses an unused binder name" do
      assert_error <<-CODE, "which is never used"
        trait Showable
          abstract def show
        end

        struct Box(T)
        end

        impl Showable for Box(T) forall T, U
          def show
            1
          end
        end
        CODE
    end

    it "refuses a rename that would capture" do
      # `Pair` declared `A`; renaming the impl's `X` to `A` would silently turn
      # a body reference to `A` into the type parameter.
      assert_error <<-CODE, "can't also be used as a name here"
        trait Showable
          abstract def show
        end

        struct A
        end

        struct Pair(A, B)
        end

        impl Showable for Pair(X, Y) forall X, Y
          def show
            A.new
          end
        end
        CODE
    end

    it "refuses `forall` on a target that takes no parameters" do
      assert_error <<-CODE, "has nothing to bind"
        trait Showable
          abstract def show
        end

        struct Foo
        end

        impl Showable for Foo forall T
          def show
            1
          end
        end
        CODE
    end
  end

  # A bound on a *method*'s free variable, which is a different mechanism from
  # a bound on an impl's parameter: the method exists either way, so there is
  # one check where the variable binds and nothing to defer. The impl form
  # stays unimplemented — see the `describe` above.
  describe "trait bounds on a method (SPEC.md II.7)" do
    it "accepts a call whose bound type implements the trait" do
      assert_type(<<-CODE) { int32 }
        module App
          module Show
            trait Showable
              abstract def show : Int32
            end

            struct Foo
            end

            impl Showable for Foo
              def show : Int32
                1
              end
            end

            def self.render(x : T) : Int32 forall T : Showable
              x.show
            end
          end
        end

        App::Show.render(App::Show::Foo.new)
        CODE
    end

    it "refuses a call whose bound type does not implement the trait" do
      assert_error <<-CODE, "Char does not implement App::Show::Showable, required by `T` in `render`"
        module App
          module Show
            trait Showable
              abstract def show : Int32
            end

            def self.render(x : T) : Int32 forall T : Showable
              1
            end
          end
        end

        App::Show.render('a')
        CODE
    end

    it "binds through a block's return type" do
      # The shape the Kemal router needs: nothing in the parameter list
      # mentions the bounded variable.
      assert_type(<<-CODE) { int32 }
        module App
          module Router
            trait IntoBody
              abstract def into_body : Int32
            end

            impl IntoBody for Char
              def into_body : Int32
                1
              end
            end

            # The body does not call the block: the spec harness runs a
            # minimal prelude with no `Proc#call`, and what is under test is
            # where `B` binds, not what the body does with it.
            def self.add_route(&block : Int32 -> B) : Int32 forall B : IntoBody
              1
            end
          end
        end

        App::Router.add_route { |x| 'a' }
        CODE
    end

    it "refuses a block whose return type does not implement the trait" do
      assert_error <<-CODE, "Bool does not implement App::Router::IntoBody, required by `B` in `add_route`"
        module App
          module Router
            trait IntoBody
              abstract def into_body : Int32
            end

            def self.add_route(&block : Int32 -> B) : Int32 forall B : IntoBody
              1
            end
          end
        end

        App::Router.add_route { |x| true }
        CODE
    end

    it "checks only the names that carry a bound" do
      assert_error <<-CODE, "does not implement App::Show::Showable, required by `A` in `pair`"
        module App
          module Show
            trait Showable
              abstract def show : Int32
            end

            impl Showable for Char
              def show : Int32
                1
              end
            end

            def self.pair(a : A, b : B) : Int32 forall A : Showable, B
              a.show
            end
          end
        end

        App::Show.pair('a', true)
        App::Show.pair(true, 'a')
        CODE
    end

    it "refuses a bound that is not a trait" do
      assert_error <<-CODE, "can't bound T by App::Helpers, it's a module. A bound is a trait, and nothing else"
        module App
          module Helpers
          end

          def self.f(x : T) : Int32 forall T : Helpers
            1
          end
        end

        App.f(1)
        CODE
    end
  end

  # iyi: `trait Ord : Eq` — a trait requiring another trait (SPEC.md II.6).
  # A requirement, not an inclusion, so a type still acquires `Eq` only by
  # having an `impl Eq for` it — which is what keeps R-3 the only route in.
  describe "supertraits" do
    it "lets a default method call a method the required trait provides" do
      # `Ord` never declares `eq`. It is the requirement that guarantees the
      # implementer has one.
      assert_type(<<-CODE) { bool }
        module App
          module Cmp
            trait Eq
              abstract def eq : Bool
            end

            trait Ord : Eq
              abstract def key : Int32

              def same : Bool
                eq
              end
            end

            struct N
              def initialize
              end
            end

            impl Eq for N
              def eq : Bool
                true
              end
            end

            impl Ord for N
              def key : Int32
                1
              end
            end
          end
        end

        App::Cmp::N.new.same
        CODE
    end

    it "reports a required trait the type does not implement" do
      assert_error <<-CODE, "needs an impl of App::Cmp::Eq for App::Cmp::N first"
        module App
          module Cmp
            trait Eq
              abstract def eq : Bool
            end

            trait Ord : Eq
              abstract def key : Int32
            end

            struct N
            end

            impl Ord for N
              def key : Int32
                1
              end
            end
          end
        end
        CODE
    end

    it "does not let implementing the requiring trait confer the required one" do
      # The reason this is a requirement rather than an `include`: if `Ord`
      # included `Eq`, every implementer of `Ord` would satisfy `Eq` with no
      # impl anywhere, which is the open-class hole R-3 closes.
      assert_error <<-CODE, "needs an impl of App::Cmp::Eq for App::Cmp::M first"
        module App
          module Cmp
            trait Eq
              abstract def eq : Bool
            end

            trait Ord : Eq
              abstract def key : Int32
            end

            struct N
              def initialize
              end
            end

            impl Eq for N
              def eq : Bool
                true
              end
            end

            impl Ord for N
              def key : Int32
                1
              end
            end

            struct M
            end

            impl Ord for M
              def key : Int32
                2
              end
            end
          end
        end
        CODE
    end

    it "reports every required trait that is missing at once" do
      assert_error <<-CODE, "needs impls of App::Cmp::Eq, App::Cmp::Show for App::Cmp::N first"
        module App
          module Cmp
            trait Eq
              abstract def eq : Bool
            end

            trait Show
              abstract def show : String
            end

            trait Ord : Eq, Show
              abstract def key : Int32
            end

            struct N
            end

            impl Ord for N
              def key : Int32
                1
              end
            end
          end
        end
        CODE
    end

    it "refuses a requirement that is not a trait" do
      assert_error <<-CODE, "can't require App::Cmp::Helpers, it's a module. A trait can only require another trait"
        module App
          module Cmp
            module Helpers
            end

            trait Ord : Helpers
              abstract def key : Int32
            end
          end
        end
        CODE
    end

    it "refuses a trait that requires itself" do
      assert_error <<-CODE, "App::Cmp::Ord can't require itself"
        module App
          module Cmp
            trait Ord : Ord
              abstract def key : Int32
            end
          end
        end
        CODE
    end

    it "refuses the same requirement twice" do
      assert_error <<-CODE, "App::Cmp::Ord already requires App::Cmp::Eq"
        module App
          module Cmp
            trait Eq
              abstract def eq : Bool
            end

            trait Ord : Eq, Eq
              abstract def key : Int32
            end
          end
        end
        CODE
    end
  end

  # iyi: `type Elem` — an associated type (SPEC.md II.6). It is an output of the
  # impl, not an input the caller picks, which is why a trait that declares one
  # can be implemented only once for a type.
  describe "associated types" do
    it "resolves the trait's own signatures through the impl's answer" do
      assert_type(<<-CODE) { string }
        module App
          module Coll
            trait Container
              type Elem

              abstract def first : Elem

              def describe : Elem
                first
              end
            end

            struct Names
              def initialize
              end
            end

            impl Container for Names
              type Elem = String

              def first : String
                "ada"
              end
            end
          end
        end

        App::Coll::Names.new.describe
        CODE
    end

    it "lets two types answer it differently" do
      assert_type(<<-CODE) { int32 }
        module App
          module Coll
            trait Container
              type Elem

              abstract def first : Elem
            end

            struct Names
              def initialize
              end
            end

            impl Container for Names
              type Elem = String

              def first : String
                "ada"
              end
            end

            struct Counts
              def initialize
              end
            end

            impl Container for Counts
              type Elem = Int32

              def first : Int32
                42
              end
            end
          end
        end

        App::Coll::Counts.new.first
        CODE
    end

    it "checks the impl's signature against its own answer" do
      assert_error <<-CODE, "must return String"
        module App
          module Coll
            trait Container
              type Elem

              abstract def first : Elem
            end

            struct Names
              def initialize
              end
            end

            impl Container for Names
              type Elem = String

              def first : Int32
                1
              end
            end
          end
        end

        App::Coll::Names.new.first
        CODE
    end

    it "reports an associated type the impl does not answer" do
      assert_error <<-CODE, "impl App::Coll::Container for App::Coll::Names does not answer an associated type the trait declares: Elem"
        module App
          module Coll
            trait Container
              type Elem

              abstract def first : Elem
            end

            struct Names
            end

            impl Container for Names
              def first : String
                "ada"
              end
            end
          end
        end
        CODE
    end

    it "reports an answer the trait never asked for" do
      assert_error <<-CODE, "App::Coll::Container declares no associated type named Key. It declares: Elem"
        module App
          module Coll
            trait Container
              type Elem

              abstract def first : Elem
            end

            struct Names
            end

            impl Container for Names
              type Elem = String
              type Key = Int32

              def first : String
                "ada"
              end
            end
          end
        end
        CODE
    end

    it "refuses a second impl of the same trait for one type" do
      # The whole difference from a parameter: a second answer would make a
      # call on the type ambiguous about which impl it meant.
      assert_error <<-CODE, "already implements App::Coll::Container, and a trait with associated types can be implemented only once for a type"
        module App
          module Coll
            trait Container
              type Elem

              abstract def first : Elem
            end

            struct Names
              def initialize
              end
            end

            impl Container for Names
              type Elem = String

              def first : String
                "ada"
              end
            end

            impl Container for Names
              type Elem = Int32

              def first : Int32
                1
              end
            end
          end
        end
        CODE
    end

    it "refuses one declared anywhere but a trait or an impl body" do
      assert_error <<-CODE, "an associated type can only be declared directly in a trait or an impl body"
        module App
          module Coll
            trait Container
              type Elem

              abstract def first : Elem
            end

            struct Names
            end

            impl Container for Names
              type Elem = String

              struct Inner
                type Nested = Int32
              end

              def first : String
                "ada"
              end
            end
          end
        end
        CODE
    end

    it "allows a default method bounded on the associated type" do
      assert_type(<<-CODE) { int32 }
        module App
          module Coll
            trait Cmp
              abstract def cmp : Int32
            end

            trait Container
              type Elem

              abstract def first : Elem

              def biggest : Elem where Elem : Cmp
                first
              end
            end

            struct Score
              def initialize
              end
            end

            impl Cmp for Score
              def cmp : Int32
                1
              end
            end

            struct Scores
              def initialize
              end
            end

            impl Container for Scores
              type Elem = Score

              def first : Score
                Score.new
              end
            end
          end
        end

        App::Coll::Scores.new.biggest.cmp
        CODE
    end

    it "reports an element type that does not meet the bound" do
      # The point of the bound: Crystal duck-types these and fails at
      # instantiation, naming neither the bound nor the element type.
      assert_error <<-CODE, "Int32 does not implement App::Coll::Cmp, required by `where Elem : App::Coll::Cmp` in `biggest`"
        module App
          module Coll
            trait Cmp
              abstract def cmp : Int32
            end

            trait Container
              type Elem

              abstract def first : Elem

              def biggest : Elem where Elem : Cmp
                first
              end
            end

            struct Raw
              def initialize
              end
            end

            impl Container for Raw
              type Elem = Int32

              def first : Int32
                1
              end
            end
          end
        end

        App::Coll::Raw.new.biggest
        CODE
    end

    it "leaves an unbounded method alone on the same trait" do
      # Only the bounded method is restricted; the rest of the trait stays
      # available whatever the element type is.
      assert_type(<<-CODE) { int32 }
        module App
          module Coll
            trait Cmp
              abstract def cmp : Int32
            end

            trait Container
              type Elem

              abstract def first : Elem

              def biggest : Elem where Elem : Cmp
                first
              end

              def any : Elem
                first
              end
            end

            struct Raw
              def initialize
              end
            end

            impl Container for Raw
              type Elem = Int32

              def first : Int32
                1
              end
            end
          end
        end

        App::Coll::Raw.new.any
        CODE
    end

    it "refuses a where bound that is not a trait" do
      assert_error <<-CODE, "can't bound Elem by App::Coll::Helpers, it's a module. A bound is a trait, and nothing else"
        module App
          module Coll
            module Helpers
            end

            trait Container
              type Elem

              abstract def first : Elem

              def go : Elem where Elem : Helpers
                first
              end
            end

            struct Raw
              def initialize
              end
            end

            impl Container for Raw
              type Elem = Int32

              def first : Int32
                1
              end
            end
          end
        end

        App::Coll::Raw.new.go
        CODE
    end

    it "refuses a name that is both a parameter and an associated type" do
      assert_error <<-CODE, "declares T both as a parameter and as an associated type"
        module App
          module Coll
            trait Both(T)
              type T

              abstract def go : T
            end
          end
        end
        CODE
    end
  end

  # iyi: errors are ordinary union members (SPEC.md III.1). `Error` is the
  # compiler's own marker trait: what makes a member an error member is that
  # its type implements it, which needs no new syntax and no new type machinery.
  describe "errors" do
    it "lets a module implement the compiler's Error trait" do
      assert_type(<<-CODE) { types["App"].types["Fails"].types["IOError"] }
        module App
          module Fails
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end
          end
        end

        App::Fails::IOError.new
        CODE
    end

    it "checks Error's own requirement" do
      assert_error <<-CODE, "impl Error for App::Fails::Bad is missing a method required by the trait: message"
        module App
          module Fails
            struct Bad
            end

            impl Error for Bad
            end
          end
        end
        CODE
    end

    it "reports an error member left unhandled" do
      # III.1.3, and the main ergonomic argument for the whole approach:
      # adding an error member turns every incomplete `case` into an error.
      assert_error <<-CODE, "case is not exhaustive"
        module App
          module Fails
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end

            def self.read : String | IOError
              IOError.new
            end

            def self.go : Int32
              result = read
              case result
              in String then 1
              end
            end
          end
        end

        App::Fails.go
        CODE
    end

    it "propagates an error member out of the enclosing method" do
      # III.1.2. `read` can fail; `load` says so in its own return type, and
      # `!` is what carries the failure across without a `case`. The filename
      # matters: `!` is the operator only in a `.iyi` file.
      assert_type(<<-CODE, filename: "x.iyi") { union_of(int32, types["App"].types["Fails"].types["IOError"]) }
        module App
          module Fails
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end

            def self.read(missing : Bool) : String | IOError
              return IOError.new if missing
              "contents"
            end

            # `length` takes a `String`, so this only matches if `!` narrowed
            # `text` to the union's non-error member. Without the narrowing it
            # would still be `String | IOError` and no overload would match.
            def self.length(s : String) : Int32
              1
            end

            def self.load(missing : Bool) : Int32 | IOError
              text = read(missing)!
              length(text)
            end
          end
        end

        App::Fails.load(false)
        CODE
    end

    it "refuses to propagate where there is no error member" do
      # III.1.1's degenerate cases are rejected rather than given a surprising
      # meaning: without this, `!` here compiles and silently does nothing.
      assert_error <<-CODE, "`!` has no error to propagate: no member of (Int32 | Nil) implements `Error`", filename: "x.iyi"
        module App
          module Fails
            def self.maybe(missing : Bool) : Int32?
              return nil if missing
              1
            end

            def self.go : Int32?
              maybe(false)!
            end
          end
        end

        App::Fails.go
        CODE
    end

    it "refuses to propagate where every member is an error" do
      assert_error <<-CODE, "`!` can never produce a value: every member of App::Fails::IOError implements `Error`", filename: "x.iyi"
        module App
          module Fails
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end

            def self.always : IOError
              IOError.new
            end

            def self.go : IOError
              always!
            end
          end
        end

        App::Fails.go
        CODE
    end

    it "reports an enclosing return type that does not admit the error" do
      # It used to be the ordinary return-type check on the `return` the
      # expansion wrote: "must return String but it is returning IOError",
      # which is true and mentions neither the operator that put it there nor
      # the two ways out. The operator asks the enclosing signature itself now.
      assert_error <<-CODE, "`!` propagates App::Fails::IOError out of `go`", filename: "x.iyi"
        module App
          module Fails
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end

            def self.read(missing : Bool) : String | IOError
              return IOError.new if missing
              "contents"
            end

            def self.go : String
              read(false)!
            end
          end
        end

        App::Fails.go
        CODE
    end

    it "does not make Nil an error" do
      # III.1.5: absence and failure stay distinct, so `T?` is not an error
      # union and nothing here touches it.
      assert_type(<<-CODE) { nilable int32 }
        module App
          module Fails
            def self.maybe(missing : Bool) : Int32?
              return nil if missing
              1
            end
          end
        end

        App::Fails.maybe(false)
        CODE
    end

    # iyi: a module's initialisation may not fail (SPEC.md III.5). Already
    # rejected before this, but through Crystal's rule about `return` — which
    # is what the expansion happens to be made of, and explains nothing.
    it "refuses to propagate out of a module's initialisation" do
      assert_error <<-CODE, "`!` can't propagate out of a module's initialisation", filename: "x.iyi"
        module App
          module Fails
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end

            def self.read(missing : Bool) : Int32 | IOError
              return IOError.new if missing
              1
            end
          end
        end

        App::Fails.read(false)!
        CODE
    end

    it "still reports a plain top-level `return` as itself" do
      assert_error "return", "can't return from top level", filename: "x.iyi"
    end

    # iyi: `defer` (SPEC.md III.1.4). The shape of the expansion is specced in
    # `spec/compiler/normalize/defer_spec.cr`; what matters here is that it
    # leaves the scope's type alone — the cleanup is a registered proc plus
    # an `ensure`, and neither contributes to a value. The harness has no
    # prelude, so each fixture carries the runtime pair as typed no-ops.
    it "leaves the value of the scope alone" do
      assert_type(<<-CODE, filename: "x.iyi") { int32 }
        def __iyi_defer_push(cleanup : -> Nil) : Nil
        end

        def __iyi_defer_pop_run : Nil
        end

        module App
          module Res
            def self.close : Char
              'x'
            end

            def self.go : Int32
              defer close
              1
            end
          end
        end

        App::Res.go
        CODE
    end

    it "keeps a defer in a method that propagates" do
      assert_type(<<-CODE, filename: "x.iyi") { union_of(int32, types["App"].types["Res"].types["IOError"]) }
        def __iyi_defer_push(cleanup : -> Nil) : Nil
        end

        def __iyi_defer_pop_run : Nil
        end

        module App
          module Res
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end

            def self.close : Char
              'x'
            end

            def self.open(missing : Bool) : Int32 | IOError
              return IOError.new if missing
              1
            end

            def self.go(missing : Bool) : Int32 | IOError
              defer close
              open(missing)!
            end
          end
        end

        App::Res.go(false)
        CODE
    end

    # iyi: `it` in a `case` branch (SPEC.md III.1.1). An assignment, not new
    # machinery, so it picks up the narrowing the branch already did.
    it "binds `it` to the value a case is matching, narrowed per branch" do
      # `length` takes a `String`, so this only compiles if `it` is the narrowed
      # value and not the whole union.
      assert_type(<<-CODE, filename: "x.iyi") { int32 }
        module App
          module Fails
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end

            def self.read(missing : Bool) : String | IOError
              return IOError.new if missing
              "contents"
            end

            def self.length(s : String) : Int32
              1
            end

            def self.go(missing : Bool) : Int32
              case read(missing)
              in String  then length(it)
              in IOError then length(it.message)
              end
            end
          end
        end

        App::Fails.go(false)
        CODE
    end

    it "binds `it` in a `when` branch and in the else" do
      assert_type(<<-CODE, filename: "x.iyi") { int32 }
        module App
          module Fails
            def self.go(n : Int32) : Int32
              case n
              when Int32 then it
              else            it
              end
            end
          end
        end

        App::Fails.go(1)
        CODE
    end

    it "leaves `it` undefined where a case has a tuple subject" do
      # There is no single value to name, so `it` is left a call rather than
      # bound to one of the elements.
      assert_error <<-CODE, "undefined local variable or method 'it'", filename: "x.iyi"
        module App
          module Fails
            def self.go(a : Int32, b : Int32) : Int32
              case {a, b}
              in {Int32, Int32} then it
              end
            end
          end
        end

        App::Fails.go(1, 2)
        CODE
    end

    it "leaves `it` undefined in a Crystal file" do
      assert_error <<-CODE, "undefined local variable or method 'it'"
        module App
          module Fails
            def self.go(n : Int32) : Int32
              case n
              when Int32 then it
              else            n
              end
            end
          end
        end

        App::Fails.go(1)
        CODE
    end

    # iyi: `.or(default)` and `.or_panic` — III.1.3's two conveniences, for
    # where a `case` is overkill. Compiler-known rather than trait methods:
    # by II.1 an ordinary call on `Int32 | IOError` would need *both* members
    # to implement it, which is the thing this design avoids.
    it "recovers from an error with a default" do
      assert_type(<<-CODE, filename: "x.iyi") { int32 }
        module App
          module Fails
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end

            def self.read_port(missing : Bool) : Int32 | IOError
              return IOError.new if missing
              1234
            end

            def self.port(missing : Bool) : Int32
              read_port(missing).or(8080)
            end
          end
        end

        App::Fails.port(true)
        CODE
    end

    it "widens the result when the default is of another type" do
      # Nothing computes this: the expansion is an `if`, so the result is the
      # union of the default and what `is_a?(::Error)` left on the other side.
      assert_type(<<-CODE, filename: "x.iyi") { union_of(int32, char) }
        module App
          module Fails
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end

            def self.read_port(missing : Bool) : Int32 | IOError
              return IOError.new if missing
              1234
            end

            def self.port(missing : Bool) : Int32 | Char
              read_port(missing).or('x')
            end
          end
        end

        App::Fails.port(true)
        CODE
    end

    it "recovers by panicking, leaving only the non-error members" do
      # `raise` is `NoReturn`, so the error branch contributes nothing to the
      # type. Defined here because the semantic harness runs without a prelude.
      assert_type(<<-CODE, filename: "x.iyi") { int32 }
        def raise(message : String) : NoReturn
          while true
          end
        end

        module App
          module Fails
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end

            def self.read_port(missing : Bool) : Int32 | IOError
              return IOError.new if missing
              1234
            end

            def self.port(missing : Bool) : Int32
              read_port(missing).or_panic
            end
          end
        end

        App::Fails.port(false)
        CODE
    end

    it "reaches `message` across a union of several error types" do
      # `.or_panic` calls `message` on the narrowed value, which here holds two
      # unrelated error types. That resolves by II.1: both implement `Error`,
      # so their union does, and the marker trait carries the call.
      assert_type(<<-CODE, filename: "x.iyi") { int32 }
        def raise(message : String) : NoReturn
          while true
          end
        end

        module App
          module Fails
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end

            struct ParseError
              def initialize
              end
            end

            impl Error for ParseError
              def message : String
                "bad"
              end
            end

            def self.read(missing : Bool, bad : Bool) : Int32 | IOError | ParseError
              return IOError.new if missing
              return ParseError.new if bad
              1234
            end

            def self.port(missing : Bool, bad : Bool) : Int32
              read(missing, bad).or_panic
            end
          end
        end

        App::Fails.port(false, false)
        CODE
    end

    it "refuses to recover where there is no error member" do
      assert_error <<-CODE, "`.or` has no error to recover: no member of (Int32 | Nil) implements `Error`", filename: "x.iyi"
        module App
          module Fails
            def self.maybe(missing : Bool) : Int32?
              return nil if missing
              1
            end

            def self.go : Int32?
              maybe(false).or(0)
            end
          end
        end

        App::Fails.go
        CODE
    end

    it "refuses to recover where every member is an error" do
      # The default would be the only outcome, which is dead code dressed up as
      # a fallback — rejected for the same reason `!` rejects this operand.
      assert_error <<-CODE, "`.or` can only ever return its default: every member of App::Fails::IOError implements `Error`", filename: "x.iyi"
        module App
          module Fails
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end

            def self.always : IOError
              IOError.new
            end

            def self.go : Int32
              always.or(0)
            end
          end
        end

        App::Fails.go
        CODE
    end

    it "refuses to panic-recover where every member is an error" do
      assert_error <<-CODE, "`.or_panic` can never produce a value: every member of App::Fails::IOError implements `Error`", filename: "x.iyi"
        def raise(message : String) : NoReturn
          while true
          end
        end

        module App
          module Fails
            struct IOError
              def initialize
              end
            end

            impl Error for IOError
              def message : String
                "boom"
              end
            end

            def self.always : IOError
              IOError.new
            end

            def self.go : Int32
              always.or_panic
            end
          end
        end

        App::Fails.go
        CODE
    end
  end

  # iyi: `pub` — what a module exports (R-2), and what an import's names may reach
  # (R-2b). Only a `module app/greeter` compilation unit has a surface; a
  # Crystal module never wrote `pub`, so the import-name specs above are unaffected.
  describe "what a trait mismatch says" do
    # A trait is not a class, so "not Dog" is only half an answer: it says the
    # argument is wrong and not what would make it right. R-3 says exactly
    # where the `impl` may go, and the message names both places.
    it "names the impl to write, and the two modules it may live in" do
      assert_error <<-CODE, "Write `impl"
        module app/thing

        trait Speaker
          abstract def speak : String
        end

        pub struct Dog
        end

        def hear(s : Speaker) : String
          s.speak
        end

        hear(Dog.new)
        CODE
    end
  end

  describe "a return type that does not admit what is returned" do
    # The type reported is the one bound when the check fired, which can be
    # a partial union, so the members outside the declared type are named
    # on their own.
    it "names the members outside the declared type" do
      assert_error <<-CODE, "Nil is not in the declared type", filename: "x.iyi"
        def f(x : Bool) : Int32 | String
          x ? 1 : (x ? "a" : nil)
        end

        f(true)
        CODE
    end
  end

  describe "the naming rule beside Crystal's library" do
    # III.1.7a: `!` cannot end a name, so the pair Crystal spells `sort` and
    # `sort!` is spelled `sorted` and `sort_in_place`. Somebody arriving from
    # Crystal writes the plain verb, and "undefined method" is true and teaches
    # nothing — the suggestion machinery cannot reach it either, `sort` to
    # `sorted` being two edits.
    it "names the participle when the plain verb is missing" do
      assert_error <<-CRYSTAL, "'sorted' is what this library calls it"
        module app/thing

        struct Numbers
          def sorted : Int32
            1
          end
        end

        Numbers.new.sort
        CRYSTAL
    end

    # The participle is on the verb, which is the first word: `sort_by` is
    # `sorted_by`, `map_by` would be `mapped_by`. (`sort_by` itself is one
    # Levenshtein reaches; the doubled consonant here is what it does not.)
    it "inflects the first word of a compound name" do
      assert_error <<-CRYSTAL, "'mapped_by' is what this library calls it"
        module app/thing

        struct Numbers
          def mapped_by : Int32
            1
          end
        end

        Numbers.new.map_by
        CRYSTAL
    end

    it "stays quiet for a name nobody spelled that way" do
      assert_error <<-CRYSTAL, "undefined method 'frist'"
        module app/thing

        struct Numbers
          def first : Int32
            1
          end
        end

        Numbers.new.frist
        CRYSTAL
    end
  end

  describe "pub" do
    # R-2 is a rule of the language, so it is asked at the `pub def`. It used
    # to be asked only where the artifact is written, which meant
    # `pub def twice(x)` compiled all day and failed the first time somebody
    # packaged the module: a rule of the language reported as a packaging
    # error, at a build that need not be the author's.
    it "asks an exported def for its types where it is written" do
      assert_error <<-CODE, "`twice` is exported and does not say what `x` is"
        module app/thing

        pub def twice(x)
          x + x
        end
        CODE
    end

    it "asks an exported def what it returns" do
      assert_error <<-CODE, "`twice` is exported and does not say what it returns"
        module app/thing

        pub def twice(x : Int32)
          x + x
        end
        CODE
    end

    it "leaves an unexported def to infer, which is the point of the mark" do
      assert_no_errors <<-CODE
        module app/thing

        def twice(x)
          x + x
        end

        pub def four : Int32
          twice(2)
        end
        CODE
    end

    # `pub` is what another module may name, and two kinds of declaration
    # were missing from it. An `alias` is a name for a type - half of what
    # the `validator` shard's surface is - and an `annotation` is applied
    # by *consumers*: `annotation Checker` in a shard means a class in
    # somebody else's module writes `@[Check::Checker]`. Both were refused
    # by the parser ("can't apply `pub` to ..."), which left a migrated
    # tree unable to export either.
    it "exports an alias" do
      assert_no_errors <<-CODE
        module app/thing

        pub alias Money = Int32

        pub def owed : Money
          1
        end
        CODE
    end

    it "leaves an unexported alias to the module's own body" do
      assert_error <<-CODE, "does not export `Money`"
        module app/thing

        alias Money = Int32

        module Consumer
          import app/thing::{Money}
        end
        CODE
    end

    it "exports an annotation, which is what a consumer applies" do
      assert_no_errors <<-CODE
        module app/thing

        pub annotation Priced; end

        module Consumer
          import app/thing::{Priced}

          @[Priced]
          class Item
            def priced? : Bool
              {{ @type.annotation(Priced) ? true : false }}
            end
          end
        end
        CODE
    end

    it "leaves an unexported annotation to the module's own body" do
      assert_error <<-CODE, "does not export `Priced`"
        module app/thing

        annotation Priced; end

        module Consumer
          import app/thing::{Priced}
        end
        CODE
    end

    it "refuses an import of a name the module does not export" do
      assert_error <<-CODE, "App::Greeter does not export `internal`"
        module app/greeter

        pub def polite : Int32
          1
        end

        def internal : Int32
          2
        end

        module Consumer
          import app/greeter::{internal}
        end
        CODE
    end

    it "names every unexported name the directive asked for" do
      assert_error <<-CODE, "does not export `internal`, `Hidden`"
        module app/greeter

        def internal : Int32
          2
        end

        trait Hidden
          abstract def go : Int32
        end

        module Consumer
          import app/greeter::{internal, Hidden}
        end
        CODE
    end

    # The other mistake behind "does not export": a name the module does not
    # have at all. `import calc/add::{ad}` was told to add `pub` to a
    # declaration that does not exist; the typo gets the nearest exported name.
    it "tells a name the module lacks from one it did not mark pub" do
      error = assert_error <<-CODE, "App::Greeter has no `polit`: nothing by that name is declared in `app/greeter`, `pub` or not."
        module app/greeter

        pub def polite : Int32
          1
        end

        module Consumer
          import app/greeter::{polit}
        end
        CODE
      error.message.should_not(be_nil).should contain "Did you mean `polite`?"
    end

    # The third mistake behind "has no `X`": a name the module declares at
    # the *root*. `module std/set` with `class ::Set(T)` inside it is how
    # twenty-five modules under `src/std` are written, and `import` alone
    # brings the class — so the answer "nothing by that name is declared
    # in `std/set`, `pub` or not" was true of the module and wrong about
    # the program, where `Set` is right there beside `Array`.
    it "tells a name declared at the root from a name the module lacks" do
      error = assert_error <<-CODE, "`Bag` is declared at the root by `app/bags`, not as a name of it"
        module app/bags

        class ::Bag
          def size : Int32
            0
          end
        end

        module Consumer
          import app/bags::{Bag}
        end
        CODE
      error.message.should_not(be_nil).should contain "`import app/bags` is enough to write `Bag`"
    end

    it "allows an import naming exported names" do
      # `semantic` rather than `assert_type`: a `module app/greeter` header
      # scopes the whole rest of the source into the module, so the last
      # expression is inside it and the program's type is the module's, not the
      # call's. What is being asserted here is that nothing raises.
      semantic(<<-CODE)
        module app/greeter

        pub def polite : Int32
          1
        end

        pub trait Greet
          abstract def greet : Int32
        end

        module Consumer
          import app/greeter::{polite, Greet}

          def self.go : Int32
            polite
          end
        end

        Consumer.go
        CODE
    end

    # An `import app/greeter::*` reaching only the exported names cannot be
    # written here for the same reason: the header scopes the rest of the
    # source into the module, so any consumer declared after it is *inside*
    # the module and sees its names lexically — which is right, R-2 is about
    # what another module reaches. `samples/iyi/modules.iyi` is a separate
    # file and is where that half is exercised.

    it "refuses a qualified call to a name the module does not export" do
      assert_error <<-CODE, "App::Greeter does not export 'helper'. Only what a module marks `pub` is reachable from outside it"
        module app/greeter

        pub def polite : Int32
          helper
        end

        def helper : Int32
          1
        end

        module Consumer
          def self.go : Int32
            App::Greeter.helper
          end
        end

        Consumer.go
        CODE
    end

    it "refuses a qualified reference to a type the module does not export" do
      assert_error <<-CODE, "does not export App::Greeter::Closed"
        module app/greeter

        struct Closed
          def initialize
          end
        end

        module Consumer
          def self.go : App::Greeter::Closed
            App::Greeter::Closed.new
          end
        end

        Consumer.go
        CODE
    end

    it "leaves the methods of an exported type alone" do
      # The carve-out that matters: only the unit's own body carries `pub`. A
      # `def` inside a `pub trait` belongs to the trait — `Enumerable#to_a`
      # writes no `pub` and has to stay callable on every implementer.
      semantic(<<-CODE)
        module std/enumerable

        pub trait Container
          type Elem

          abstract def first : Elem

          def again : Elem
            first
          end
        end

        pub struct Nums
          def initialize
          end
        end

        impl Container for Nums
          type Elem = Int32

          def first : Int32
            1
          end
        end

        Nums.new.again
        CODE
    end

    it "leaves a Crystal module's names alone" do
      # A Crystal module has no `pub` and so no surface to enforce. Were the
      # rule applied to it, every import of its names would reach nothing.
      assert_type(<<-CODE) { int32 }
        module App
          module Plain
            extend self

            def helper : Int32
              1
            end
          end

          module Consumer
            import app/plain::{helper}

            def self.go : Int32
              helper
            end
          end
        end

        App::Consumer.go
        CODE
    end
  end

  # iyi: `abstract def self.zero : self` — a trait requiring a class-level
  # method (SPEC.md II.6). Needed for an identity: `Enumerable#sum` has no
  # element to ask when the collection is empty.
  describe "class-level requirements" do
    it "lets a default method reach the requirement through an associated type" do
      assert_type(<<-CODE) { int32 }
        module App
          module Coll
            trait Num
              abstract def self.zero : self
              abstract def add(other : self) : self
            end

            impl Num for Int32
              def self.zero : self
                0
              end

              def add(other : self) : self
                self + other
              end
            end

            trait Container
              type Elem

              abstract def first : Elem

              def start : Elem where Elem : Num
                Elem.zero
              end
            end

            struct Nums
              def initialize
              end
            end

            impl Container for Nums
              type Elem = Int32

              def first : Int32
                1
              end
            end
          end
        end

        App::Coll::Nums.new.start
        CODE
    end

    it "reports a class-level requirement the impl does not satisfy" do
      # Named `self.zero`, because that is what has to be written to fix it.
      assert_error <<-CODE, "is missing a method required by the trait: self.zero"
        module App
          module Coll
            trait Num
              abstract def self.zero : self
              abstract def add(other : self) : self
            end

            struct Money
              def initialize
              end
            end

            impl Num for Money
              def add(other : self) : self
                Money.new
              end
            end
          end
        end
        CODE
    end

    it "reports instance and class requirements together" do
      assert_error <<-CODE, "is missing methods required by the trait: add, self.zero"
        module App
          module Coll
            trait Num
              abstract def self.zero : self
              abstract def add(other : self) : self
            end

            struct Money
            end

            impl Num for Money
            end
          end
        end
        CODE
    end

    it "still refuses an abstract class method outside a trait" do
      # A trait is the only type whose implementers have their class methods
      # checked; anywhere else the requirement would oblige nobody.
      assert_error <<-CODE, "can't define abstract def on metaclass"
        abstract class Base
          abstract def self.make : self
        end
        CODE
    end
  end

  # iyi: `impl Into(String) for User` — a trait with parameters (SPEC.md II.6).
  # Parameters are the form to reach for where several impls for one type are
  # the point; associated types are the form for a single answer per type.
  describe "parameterised traits" do
    it "implements a trait at a type argument" do
      assert_type(<<-CODE) { string }
        module App
          module Conv
            trait Into(T)
              abstract def into : T
            end

            struct User
              def initialize
              end
            end

            impl Into(String) for User
              def into : String
                "u"
              end
            end
          end
        end

        App::Conv::User.new.into
        CODE
    end

    it "checks the impl's signature against the type argument" do
      # The argument is not decoration: `Into(String)` instantiates the trait,
      # so the requirement being satisfied is `into : String`.
      assert_error <<-CODE, "must return String"
        module App
          module Conv
            trait Into(T)
              abstract def into : T
            end

            struct User
              def initialize
              end
            end

            impl Into(String) for User
              def into : Int32
                1
              end
            end
          end
        end

        App::Conv::User.new.into
        CODE
    end

    it "reports a missing type argument at the impl" do
      assert_error <<-CODE, "type arguments must be specified when implementing App::Conv::Into(T), one for each of T"
        module App
          module Conv
            trait Into(T)
              abstract def into : T
            end

            struct User
            end

            impl Into for User
              def into : String
                "u"
              end
            end
          end
        end
        CODE
    end

    # iyi: II.7 × II.6. A generic impl answering an associated type with its own
    # parameter. Both halves were built long before they were ever written
    # together, and the meeting failed on `undefined constant T`.
    it "answers an associated type with the impl's own type parameter" do
      assert_type(<<-CODE, filename: "x.iyi") { int32 }
        module App
          module Coll
            trait Holder
              type Elem
              abstract def get : Elem
            end

            struct Box(T)
              @value : T

              def initialize(@value : T)
              end
            end

            impl Holder for Box(T) forall T
              type Elem = T

              def get : T
                @value
              end
            end

            def self.go : Int32
              Box(Int32).new(1).get
            end
          end
        end

        App::Coll.go
        CODE
    end

    it "keeps the trait's own name resolvable from the impl's module" do
      # The fix must not reach for the target's scope: `Cmp` lives where the
      # impl was written, and `Int32` has never heard of it.
      assert_type(<<-CODE, filename: "x.iyi") { int32 }
        module App
          module Traits
            trait Sized
              abstract def measure : Int32
            end

            impl Sized for Int32
              def measure : Int32
                1
              end
            end

            def self.go : Int32
              1.measure
            end
          end
        end

        App::Traits.go
        CODE
    end

    it "reports type arguments given to a trait that has no parameters" do
      assert_error <<-CODE, "can't implement App::Conv::Plain with type arguments, it's not a generic trait"
        module App
          module Conv
            trait Plain
              abstract def go : Int32
            end

            struct User
            end

            impl Plain(String) for User
              def go : Int32
                1
              end
            end
          end
        end
        CODE
    end

    it "reports the wrong number of type arguments" do
      assert_error <<-CODE, "wrong number of type arguments for App::Conv::Into(T) (given 2, expected 1)"
        module App
          module Conv
            trait Into(T)
              abstract def into : T
            end

            struct User
            end

            impl Into(String, Int32) for User
              def into : String
                "u"
              end
            end
          end
        end
        CODE
    end
  end

  # SPEC.md III.4.4: `Share`, gating the block `IyiThread.start` runs on
  # another thread (III.4.11). The stub stands in for the prelude's thread:
  # the compiler knows the call by its owner's name and the block's shape.
  describe "Share" do
    stub = <<-STUB
      class IyiThread
        def self.start(&block : -> Nil) : Nil
          keep = block
          nil
        end
      end

      STUB

    it "lets a block capture integers, strings and immutable structs" do
      assert_type(stub + <<-CODE, filename: "x.iyi") { nil_type }
        struct Point
          def initialize(@x : Int32, @y : Int32)
          end

          def x : Int32
            @x
          end
        end

        n = 3
        name = "seven"
        point = Point.new(1, 2)
        IyiThread.start do
          n
          point.x
          name
          nil
        end
        CODE
    end

    it "refuses a captured value whose type has a setter" do
      assert_error(stub + <<-CODE, "the block IyiThread.start runs on another thread captures `counter : Counter`, which is not Share: Counter's field @count is given a setter `count=` (SPEC.md III.4.4)", filename: "x.iyi")
        class Counter
          def initialize
            @count = 0
          end

          def count=(value : Int32)
            @count = value
          end
        end

        counter = Counter.new
        IyiThread.start do
          counter.count = 1
          nil
        end
        CODE
    end

    it "refuses a captured value whose type assigns a field outside initialize" do
      assert_error(stub + <<-CODE, "which is not Share: Tally's field @total is assigned in `bump` (SPEC.md III.4.4)", filename: "x.iyi")
        class Tally
          def initialize
            @total = 0
          end

          def bump : Nil
            @total = 1
          end

          def total : Int32
            @total
          end
        end

        tally = Tally.new
        IyiThread.start do
          tally.total
          nil
        end
        CODE
    end

    it "refuses a captured value through a field that is not shareable" do
      assert_error(stub + <<-CODE, "captures `bag : Bag`, which is not Share: Bag's field @items : Pointer(Int32) is not shareable: Pointer(Int32) is raw memory", filename: "x.iyi")
        class Bag
          def initialize(@items : Pointer(Int32))
          end

          def items : Pointer(Int32)
            @items
          end
        end

        memory = uninitialized Pointer(Int32)
        bag = Bag.new(memory)
        IyiThread.start do
          bag.items
          nil
        end
        CODE
    end

    it "refuses a captured value through a field two levels down" do
      assert_error(stub + <<-CODE, "captures `shelf : Shelf`, which is not Share: Shelf's field @bag : Bag is not shareable: Bag's field @items : Pointer(Int32) is not shareable", filename: "x.iyi")
        class Bag
          def initialize(@items : Pointer(Int32))
          end
        end

        class Shelf
          def initialize(@bag : Bag)
          end

          def bag : Bag
            @bag
          end
        end

        memory = uninitialized Pointer(Int32)
        shelf = Shelf.new(Bag.new(memory))
        IyiThread.start do
          shelf.bag
          nil
        end
        CODE
    end

    it "trusts a type marked @[Share] whatever its fields do" do
      assert_type(stub + <<-CODE, filename: "x.iyi") { nil_type }
        @[Share]
        class Box
          def initialize
            @value = 0
          end

          def value=(value : Int32)
            @value = value
          end
        end

        box = Box.new
        IyiThread.start do
          box.value = 1
          nil
        end
        CODE
    end

    it "trusts a generic marked @[Share] only when its arguments are" do
      assert_error(stub + <<-CODE, "captures `cell : Cell(Pointer(Int32))`, which is not Share: Cell(Pointer(Int32))'s T is Pointer(Int32): Pointer(Int32) is raw memory", filename: "x.iyi")
        @[Share]
        class Cell(T)
          def initialize(@value : T)
          end

          def value : T
            @value
          end

          def value=(value : T)
            @value = value
          end
        end

        memory = uninitialized Pointer(Int32)
        cell = Cell.new(memory)
        IyiThread.start do
          cell.value
          nil
        end
        CODE
    end

    it "refuses a captured self whose type is not shareable" do
      assert_error(stub + <<-CODE, "captures `self : Worker`, which is not Share: Worker's field @done is assigned in `finish` (SPEC.md III.4.4)", filename: "x.iyi")
        class Worker
          def initialize
            @done = false
          end

          def finish : Nil
            @done = true
          end

          def go : Nil
            IyiThread.start do
              @done
              nil
            end
          end
        end

        Worker.new.go
        CODE
    end
  end
end
