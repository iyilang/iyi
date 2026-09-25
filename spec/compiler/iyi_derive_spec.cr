require "../spec_helper"
require "./spec_helper"

private def with_iyi_modules(files : Hash(String, String), &)
  with_tempdir("iyi_derive") do
    files.each do |path, source|
      directory = File.dirname(path)
      Dir.mkdir_p(directory) unless directory == "."
      File.write path, source
    end
    yield Dir.current
  end
end

private def semantic_iyi(entry : String)
  program = Iyi::Program.new
  program.color = false
  program.filename = File.expand_path(entry)

  parser = program.new_parser(File.read(entry))
  parser.filename = program.filename
  program.semantic program.normalize(parser.parse)
  program
end

# iyi: `derive` (SPEC.md R-5, II.4). A derive runs once, in the module that
# declares the type. What it generates belongs to that module and travels in its
# `.iyimod` like any other declaration, so a consumer calls the derived method
# without running the macro and without the producer's source.
describe "Semantic: iyi derive" do
  it "runs the macro in the declaring module and carries what it generated" do
    with_tempdir("iyi_derive_artifact") do
      Dir.mkdir_p "app"
      # The derive reads the facts R-5 promises it: the declaration's name and
      # its fields. It never enumerates a type it was not given.
      File.write "app/derives.iyi", <<-IYI
        module app/derives

        pub macro described(declaration)
          def described : String
            result = {{declaration[:name]}} + "("
            {% for field in declaration[:fields] %}
              result = result + {{field[:name]}} + "=" + {{field[:name].id}}.to_s + ";"
            {% end %}
            result + ")"
          end
        end
        IYI
      File.write "app/point.iyi", <<-IYI
        module app/point

        import app/derives::*

        pub struct Point
          @x : Int32
          @y : Int32

          def initialize(@x : Int32, @y : Int32)
          end

          derive described
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/point

        puts App::Point::Point.new(3, 4).described
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "Point(@x=3;@y=4;)"

      # R-1, taken literally: the consumer compiles against declarations, so
      # both the declaring module's source and the macro's own source go away.
      File.delete "app/point.iyi"
      File.delete "app/derives.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "Point(@x=3;@y=4;)"
    end
  end

  # II.4's own case: a derive that has to know whether a field's type
  # implements a trait, where the type, the trait and the impl all belong to
  # another module and arrive from its artifact.
  it "reads whether an imported field's type implements a trait" do
    with_tempdir("iyi_derive_trait") do
      Dir.mkdir_p "app"
      File.write "app/kinds.iyi", <<-IYI
        module app/kinds

        pub trait ToJSON
          abstract def to_json : String
        end

        pub struct Customer
          @name : String

          def initialize(@name : String)
          end
        end

        impl ToJSON for Customer
          def to_json : String
            "\\"" + @name + "\\""
          end
        end

        pub macro json(declaration)
          def to_json : String
            result = "{"
            {% for field in declaration[:fields] %}
              {% if field[:type] && field[:type] <= ToJSON %}
                result = result + {{field[:name]}} + ":" + {{field[:name].id}}.to_json + ","
              {% end %}
            {% end %}
            result + "}"
          end
        end
        IYI
      File.write "app/order.iyi", <<-IYI
        module app/order

        import app/kinds::*

        pub struct Order
          @customer : Customer
          @count : Int32

          def initialize(@customer : Customer, @count : Int32)
          end

          derive json
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/order
        import app/kinds

        puts App::Order::Order.new(App::Kinds::Customer.new("ada"), 2).to_json
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      # `@count` is absent because `Int32` does not implement the trait, which
      # is the derive reading an answer it could only get from the type.
      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq %({@customer:"ada",})

      File.delete "app/kinds.iyi"
      File.delete "app/order.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq %({@customer:"ada",})
    end
  end

  # `getter n : Int32` is how a field is usually written, and it is a macro
  # call: the field only exists once it has run.
  it "reads the fields a macro above the derive declared" do
    with_tempdir("iyi_derive_getter") do
      Dir.mkdir_p "app"
      File.write "app/derives.iyi", <<-IYI
        module app/derives

        pub macro shapes(declaration)
          def shapes : String
            {% names = [] of ::String %}
            {% for field in declaration[:fields] %}
              {% names << field[:name] + ":" + field[:type].stringify %}
            {% end %}
            {{names.join(",")}}
          end
        end
        IYI
      File.write "app/boxed.iyi", <<-IYI
        module app/boxed

        import app/derives::*

        pub struct Boxed
          getter n : Int32
          @tail : Array(Int32)

          def initialize(@n : Int32, @tail : Array(Int32))
          end

          derive shapes
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/boxed

        puts App::Boxed::Boxed.new(1, Array(Int32).new).shapes
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "@n:Int32,@tail:Array(Int32)"

      File.delete "app/derives.iyi"
      File.delete "app/boxed.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "@n:Int32,@tail:Array(Int32)"
    end
  end

  it "refuses to read a declaration written below the derive" do
    with_iyi_modules({
      "app/derives.iyi" => <<-IYI,
        module app/derives

        pub macro shapes(declaration)
          def shapes : Int32
            {{declaration[:fields].size}}
          end
        end
        IYI
      "main.iyi" => <<-IYI,
        module app/main

        import app/derives::*

        pub struct Boxed
          derive shapes

          getter n : Int32

          def initialize(@n : Int32)
          end
        end
        IYI
    }) do
      expect_raises(Iyi::TypeException, /cannot read `getter`.*Move `derive` below `getter`/) do
        semantic_iyi("main.iyi")
      end
    end
  end

  # A field's type arrives as a type so the derive can ask what it implements.
  # The questions that answer with the whole program are not declaration facts,
  # and an artifact cannot carry them, so a derive may not ask them.
  it "refuses the program-wide type questions inside a derive" do
    with_iyi_modules({
      "app/derives.iyi" => <<-IYI,
        module app/derives

        pub macro spread(declaration)
          def spread : Int32
            {{declaration[:fields][0][:type].all_subclasses.size}}
          end
        end
        IYI
      "main.iyi" => <<-IYI,
        module app/main

        import app/derives::*

        pub struct Boxed
          @n : Int32

          def initialize(@n : Int32)
          end

          derive spread
        end
        IYI
    }) do
      expect_raises(Iyi::TypeException, /`all_subclasses` is not available to a derive/) do
        semantic_iyi("main.iyi")
      end
    end
  end

  it "leaves the program-wide type questions to an ordinary macro" do
    with_iyi_modules({
      "main.iyi" => <<-IYI,
        module app/main

        macro count_subs(t)
          {{t.resolve.all_subclasses.size}}
        end

        class Base
        end

        class Leaf < Base
        end

        count_subs(Base)
        IYI
    }) do
      semantic_iyi("main.iyi")
    end
  end

  it "runs each macro named on one derive line" do
    with_tempdir("iyi_derive_many") do
      Dir.mkdir_p "app"
      File.write "app/derives.iyi", <<-IYI
        module app/derives

        pub macro named(declaration)
          def named : String
            {{declaration[:name]}}
          end
        end

        pub macro counted(declaration)
          def counted : Int32
            {{declaration[:fields].size}}
          end
        end
        IYI
      File.write "app/pair.iyi", <<-IYI
        module app/pair

        import app/derives::*

        pub struct Pair
          @a : Int32
          @b : Int32

          def initialize(@a : Int32, @b : Int32)
          end

          derive named, counted
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/pair

        pair = App::Pair::Pair.new(1, 2)
        puts pair.named + ":" + pair.counted.to_s
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "Pair:2"

      File.delete "app/derives.iyi"
      File.delete "app/pair.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "Pair:2"
    end
  end

  it "names the macro it could not find in a list" do
    with_iyi_modules({
      "app/derives.iyi" => <<-IYI,
        module app/derives

        pub macro named(declaration)
          def named : String
            {{declaration[:name]}}
          end
        end
        IYI
      "main.iyi" => <<-IYI,
        module app/main

        import app/derives::*

        pub struct Boxed
          derive named, absent
        end
        IYI
    }) do
      expect_raises(Iyi::TypeException, /`absent` is not an available derive macro/) do
        semantic_iyi("main.iyi")
      end
    end
  end

  it "teaches that a derive names an exported macro" do
    with_iyi_modules({
      "main.iyi" => <<-IYI,
        module app/main

        pub struct Number
          derive missing
        end
        IYI
    }) do
      expect_raises(Iyi::TypeException, /not an available derive macro.*pub macro missing/) do
        semantic_iyi("main.iyi")
      end
    end
  end
end
