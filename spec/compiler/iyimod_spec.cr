require "../spec_helper"
require "./spec_helper"

# iyi: the `.iyimod` container — SPEC.md IV.1.
#
# The contract these guard is that an artifact is either understood exactly or
# refused. A build cache whose worst case is "read something plausible and
# carried on" is the failure IV.1 is written to avoid, so the rejections below
# matter at least as much as the round trip.

private def sample_artifact(imports = [] of String,
                            exports = [] of Iyi::IyiMod::Signature,
                            types = [] of Iyi::IyiMod::TypeDecl,
                            impls = [] of Iyi::IyiMod::ImplRecord,
                            object_code = [] of Iyi::IyiMod::ObjectUnit,
                            layouts = [] of {String, Iyi::IyiMod::TypeLayout})
  Iyi::IyiMod::Artifact.new(
    module_name: "app/greeter",
    source_path: "/src/app/greeter.iyi",
    compiler_version: "1.22.0-dev+abc1234",
    target_triple: "x86_64-pc-linux-gnu",
    flags: ["bits64", "linux"],
    imports: imports.map { |name| Iyi::IyiMod::ImportEdge.new(name) },
    exports: Iyi::IyiMod::Exports.new(exports, types, impls),
    object_code: object_code,
    layouts: layouts,
  )
end

# Not text. An object file holds zero bytes, high bytes and byte sequences that
# are not valid UTF-8, and a container that round-tripped it through a `String`
# would corrupt every one of them — which is why this is the payload the round
# trip below is checked with.
private def sample_object_unit(name : String = "App::Greeter")
  Iyi::IyiMod::ObjectUnit.new(name, Bytes[0x7F, 0x45, 0x4C, 0x46, 0x00, 0xFF, 0x80, 0x00])
end

private def signature(name : String,
                      parameters = [] of String,
                      return_type = "",
                      block_parameter = "",
                      free_variables = [] of String,
                      receiver = "",
                      required = false)
  Iyi::IyiMod::Signature.new(name, receiver, parameters, block_parameter,
    return_type, free_variables, required)
end

private def type_declaration(name : String,
                             kind : String,
                             type_parameters = [] of String,
                             assoc_types = [] of String,
                             supertraits = [] of String,
                             fields = [] of {String, String, String},
                             methods = [] of Iyi::IyiMod::Signature)
  Iyi::IyiMod::TypeDecl.new(name, kind, type_parameters, assoc_types,
    supertraits, fields, methods)
end

private def impl_record(trait_name : String,
                        type_name : String,
                        trait_arguments = [] of String,
                        free_variables = [] of String,
                        free_variable_bounds = [] of {String, String},
                        assoc_types = [] of {String, String},
                        methods = [] of Iyi::IyiMod::Signature)
  Iyi::IyiMod::ImplRecord.new(trait_name, type_name, trait_arguments,
    free_variables, free_variable_bounds, assoc_types, methods)
end

private def with_temporary_file(&)
  path = File.tempname("iyimod", ".iyimod")
  begin
    yield path
  ensure
    File.delete?(path)
  end
end

describe Iyi::IyiMod do
  # iyi: a `.iyimod` is the one input the compiler reads that nobody typed.
  # Truncated ones used to leave `IO::EOFError` and a stack trace, which names
  # no file and reads as a compiler bug rather than as a damaged file.
  describe "a damaged file" do
    it "is refused rather than crashed on, at every length" do
      with_temporary_file do |path|
        Iyi::IyiMod.write sample_artifact, path
        whole = File.read(path).to_slice

        [1, 8, 64, whole.size // 2, whole.size - 1].each do |cut|
          File.write(path, whole[0, cut])
          expect_raises(Iyi::IyiMod::Error, /#{Regex.escape(path)}/) do
            Iyi::IyiMod.read(path)
          end
          expect_raises(Iyi::IyiMod::Error, /#{Regex.escape(path)}/) do
            Iyi::IyiMod.read_summary(path)
          end
        end
      end
    end

    it "says where it ran out when it ends inside the file" do
      with_temporary_file do |path|
        Iyi::IyiMod.write sample_artifact, path
        whole = File.read(path).to_slice
        File.write(path, whole[0, whole.size - 4])

        # Two wordings, both true: the reader knows it ran out inside a
        # section when the table said how long the section was, and knows only
        # that it ran out when the table itself is short.
        expect_raises(Iyi::IyiMod::Error, /truncated|ends inside/) do
          Iyi::IyiMod.read(path)
        end
      end
    end

    it "refuses a section whose bytes changed under it" do
      # A compiled artifact travels: into a CI cache, over a network, out of a
      # backup. One flipped byte used to build seven times out of ten and reach
      # the linker the other three, which failed without mentioning the file.
      with_temporary_file do |path|
        Iyi::IyiMod.write sample_artifact, path
        bytes = File.read(path).to_slice.dup
        bytes[bytes.size - 3] ^= 0xFF_u8
        File.write(path, bytes)

        expect_raises(Iyi::IyiMod::Error, /damaged|checksum/) do
          Iyi::IyiMod.read(path)
        end
      end
    end

    it "refuses something that was never a .iyimod" do
      with_temporary_file do |path|
        File.write(path, "this is not an artifact\n")
        expect_raises(Iyi::IyiMod::Error, /not a .iyimod|too short/) do
          Iyi::IyiMod.read(path)
        end
      end
    end
  end

  it "round-trips an artifact" do
    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact, path
      read = Iyi::IyiMod.read(path)

      read.module_name.should eq "app/greeter"
      read.source_path.should eq "/src/app/greeter.iyi"
      read.compiler_version.should eq "1.22.0-dev+abc1234"
      read.target_triple.should eq "x86_64-pc-linux-gnu"
      read.flags.should eq ["bits64", "linux"]
      read.imports.should be_empty
    end
  end

  it "round-trips import edges in order" do
    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact(["std/list", "std/enumerable"]), path
      Iyi::IyiMod.read(path).import_names.should eq ["std/list", "std/enumerable"]
    end
  end

  # Atomic replacement is the property IV.1 picks a single-file container for:
  # a half-written artifact that a later build reads as valid is the worst
  # failure a cache has, because it is wrong and nothing about it looks broken.
  it "leaves no temporary file behind" do
    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact, path
      Dir[File.join(File.dirname(path), "#{File.basename(path)}.*.tmp")].should be_empty
    end
  end

  it "refuses a file that is not a .iyimod" do
    with_temporary_file do |path|
      File.write path, "this is not an artifact"
      expect_raises(Iyi::IyiMod::Error, /is not a \.iyimod/) do
        Iyi::IyiMod.read(path)
      end
    end
  end

  it "refuses a file too short to hold the magic" do
    with_temporary_file do |path|
      File.write path, "IYI"
      expect_raises(Iyi::IyiMod::Error, /too short/) do
        Iyi::IyiMod.read(path)
      end
    end
  end

  # IV.5: rejected and rebuilt, never migrated.
  it "refuses another format version" do
    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact, path
      bytes = File.read(path).to_slice.dup
      # The version is the u32 right after the 8-byte magic.
      Iyi::IyiMod::FORMAT.encode(99_u32, bytes[8, 4])
      File.write path, bytes

      expect_raises(Iyi::IyiMod::Error, /format v99/) do
        Iyi::IyiMod.read(path)
      end
    end
  end
  # The one a v42 artifact in a cache actually hits: the `Layouts` section
  # bumped the format to v43, and the rule above applies to the version this
  # tree wrote yesterday exactly as to one it never wrote.
  it "refuses a v42 artifact" do
    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact, path
      bytes = File.read(path).to_slice.dup
      # The version is the u32 right after the 8-byte magic.
      Iyi::IyiMod::FORMAT.encode(42_u32, bytes[8, 4])
      File.write path, bytes

      expect_raises(Iyi::IyiMod::Error, /format v42/) do
        Iyi::IyiMod.read(path)
      end
    end
  end

  # The section table exists so a reader can take what it needs and seek past
  # the rest — that is what will let a consumer read `Exports` without paging in
  # `ObjectCode`. Forward compatibility falls out of the same property, so it is
  # checked here rather than assumed when the later sections arrive.
  it "skips a section it does not know" do
    with_temporary_file do |path|
      io = IO::Memory.new
      format = Iyi::IyiMod::FORMAT
      header = IO::Memory.new
      {"app/greeter", "/src/app/greeter.iyi", "1.0", "triple"}.each do |value|
        header.write_bytes value.bytesize.to_u32, format
        header.write value.to_slice
      end
      header.write_bytes 0_u32, format # no flags
      header.write_byte 0_u8           # no initialiser
      payload = header.to_slice

      unknown = "xyz".to_slice

      io.write Iyi::IyiMod::MAGIC
      io.write_bytes Iyi::IyiMod::FORMAT_VERSION, format
      io.write_bytes 2_u32, format
      io.write_bytes Iyi::IyiMod::Section::Header.value, format
      io.write_bytes 0_u16, format
      io.write_bytes payload.size.to_u32, format
      io.write_bytes Iyi::IyiMod.checksum(payload), format
      io.write_bytes 4242_u16, format # a kind no compiler has ever defined
      io.write_bytes 0_u16, format
      io.write_bytes unknown.size.to_u32, format
      io.write_bytes Iyi::IyiMod.checksum(unknown), format
      io.write payload
      io.write unknown

      File.write path, io.to_slice
      Iyi::IyiMod.read(path).module_name.should eq "app/greeter"
    end
  end

  it "refuses an artifact with no header" do
    with_temporary_file do |path|
      io = IO::Memory.new
      io.write Iyi::IyiMod::MAGIC
      io.write_bytes Iyi::IyiMod::FORMAT_VERSION, Iyi::IyiMod::FORMAT
      io.write_bytes 0_u32, Iyi::IyiMod::FORMAT
      File.write path, io.to_slice

      expect_raises(Iyi::IyiMod::Error, /no header/) do
        Iyi::IyiMod.read(path)
      end
    end
  end

  it "dumps as text" do
    io = IO::Memory.new
    Iyi::IyiMod.dump sample_artifact(["std/list"]), io
    text = io.to_s

    text.should contain "module        app/greeter"
    text.should contain "  std/list"
  end

  # R-2: everything exported carries full parameter and return types, which is
  # why the signature can be the annotation as written rather than a rendering
  # of an inferred type.
  it "round-trips exported signatures" do
    signatures = [
      signature("polite", ["name : String"], "String"),
      signature("title", return_type: "String"),
      signature("pair", ["a : Int32", "b : Array(String)"], "Tuple(Int32, String)"),
    ]

    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact(exports: signatures), path
      read = Iyi::IyiMod.read(path).exports.functions

      read.size.should eq 3
      read[0].name.should eq "polite"
      read[0].parameters.should eq ["name : String"]
      read[0].return_type.should eq "String"
      read[1].parameters.should be_empty
      read[2].parameters.should eq ["a : Int32", "b : Array(String)"]
      read[2].return_type.should eq "Tuple(Int32, String)"
    end
  end

  # Everything a consumer needs and the source's `def` line carries. Each of
  # these was absent from the format until a consumer that reads the artifact
  # instead of the source went looking for it: without the block annotation
  # there is no `yield` left to infer a block from, without the `forall` the
  # return type does not resolve, and an `abstract def` read as a definition is
  # a requirement nobody is told they missed.
  it "round-trips the rest of a def's header" do
    signatures = [
      signature("map", ["a : Int32"], "Array(U)",
        block_parameter: "& : (Elem -> U)", free_variables: ["U"]),
      signature("each", return_type: "Nil",
        block_parameter: "& : (Elem -> Nil)", required: true),
      signature("zero", return_type: "self", receiver: "self"),
      signature("push", ["*values : T", "**options"]),
    ]

    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact(exports: signatures), path
      read = Iyi::IyiMod.read(path).exports.functions

      read[0].block_parameter.should eq "& : (Elem -> U)"
      read[0].free_variables.should eq ["U"]
      read[0].required.should be_false
      read[1].required.should be_true
      read[2].receiver.should eq "self"
      read[3].parameters.should eq ["*values : T", "**options"]
    end
  end

  it "dumps a def's header the way it was written" do
    io = IO::Memory.new
    Iyi::IyiMod.dump sample_artifact(exports: [
      signature("map", ["a : Int32"], "Array(U)",
        block_parameter: "& : (Elem -> U)", free_variables: ["U"]),
      signature("each", return_type: "Nil",
        block_parameter: "& : (Elem -> Nil)", required: true),
      signature("zero", return_type: "self", receiver: "self"),
    ]), io
    text = io.to_s

    text.should contain "  def map(a : Int32, & : (Elem -> U)) : Array(U) forall U"
    # A block parameter alone still gets the parentheses it needs.
    text.should contain "  abstract def each(& : (Elem -> Nil)) : Nil"
    text.should contain "  def self.zero : self"
  end

  it "dumps a signature the way it was written" do
    io = IO::Memory.new
    Iyi::IyiMod.dump sample_artifact(exports: [
      signature("polite", ["name : String"], "String"),
      signature("title", return_type: "String"),
    ]), io
    text = io.to_s

    text.should contain "  def polite(name : String) : String"
    # No empty parens for a function that takes nothing.
    text.should contain "  def title : String"
  end

  # The format still stops short of what codegen needs, and a reader has no way
  # to tell an absent field list from an empty one, so the dump says so.
  # For a long time this note said what the format was still missing, because a
  # reader has no way to tell an absent field list from an empty one. Every
  # section the enum names is written now, so it says what is in the file.
  it "says what the format carries" do
    io = IO::Memory.new
    Iyi::IyiMod.dump sample_artifact, io
    text = io.to_s
    text.should contain "carries declarations"
    text.should contain "the macros"
    text.should contain "bodies a consumer has to compile for itself"
  end

  it "round-trips object code byte for byte" do
    unit = sample_object_unit
    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact(object_code: [unit]), path
      read = Iyi::IyiMod.read(path, want_object_code: true).object_code

      read.size.should eq 1
      read.first.name.should eq "App::Greeter"
      read.first.code.should eq unit.code
    end
  end

  it "round-trips one unit per type, in order" do
    units = [sample_object_unit("App::Greeter"), sample_object_unit("App::Greeter::Formal")]
    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact(object_code: units), path
      read = Iyi::IyiMod.read(path, want_object_code: true).object_code
      read.map(&.name).should eq ["App::Greeter", "App::Greeter::Formal"]
    end
  end

  # The reader that matters most is `import`, and it is a front-end reader: it
  # wants the declarations and has no use for the machine code. Reading the
  # largest section in the file anyway would put it on the path of the pass the
  # artifact exists to make fast, so it is seeked past unless asked for.
  it "does not read object code unless asked" do
    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact(object_code: [sample_object_unit]), path

      Iyi::IyiMod.read(path).object_code.should be_empty
      Iyi::IyiMod.read(path, want_object_code: true).object_code.size.should eq 1
    end
  end

  # Seeking past a section only works if what follows it is still found, so the
  # skip is checked by reading something written *after* the object code — the
  # exports, which the writer puts before it, and the header, which it puts
  # first. A skip of the wrong length would lose both.
  it "reads the rest of the file with the object code skipped" do
    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact(imports: ["std/list"],
        exports: [signature("polite", ["name : String"], "String")],
        object_code: [sample_object_unit]), path

      read = Iyi::IyiMod.read(path)
      read.module_name.should eq "app/greeter"
      read.import_names.should eq ["std/list"]
      read.exports.functions.map(&.name).should eq ["polite"]
    end
  end

  # A `--no-codegen` build writes an artifact with nothing to link. The section
  # is left out rather than written empty, so that such a file is the same size
  # it was before this section existed.
  it "omits the object code section when there is none" do
    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact, path
      # Section count is the u32 after the 8-byte magic and the version.
      count = Iyi::IyiMod::FORMAT.decode(UInt32, File.read(path).to_slice[12, 4])
      count.should eq 3
    end
  end

  it "dumps the units it carries, and says when it carries none" do
    io = IO::Memory.new
    Iyi::IyiMod.dump sample_artifact(object_code: [sample_object_unit]), io
    io.to_s.should contain "App::Greeter — 8 bytes"

    io = IO::Memory.new
    Iyi::IyiMod.dump sample_artifact, io
    io.to_s.should contain "object code   (none)"
  end

  # The only example here that compiles a real program, and the one thing the
  # container specs above cannot check: that the name a unit is filed under is
  # the name codegen gave it. Codegen emits one object file per owner type and
  # names it after that type; an artifact that agreed on the bytes and not on
  # the name would carry machine code nobody could match to a declaration.
  it "carries the object code of a module's own type" do
    with_tempdir("iyimod_object_code") do
      Dir.mkdir_p "app"
      File.write "app/greeter.iyi", <<-IYI
        module app/greeter

        pub def polite(name : String) : String
          "Hello, " + name
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/greeter

        puts App::Greeter.polite("world")
        IYI

      compiler = create_spec_compiler
      # Chosen by the entry file's extension in `crystal build`, which is the
      # command layer rather than the compiler, so a spec driving the compiler
      # directly asks for it.
      compiler.prelude = "iyi/prelude"
      compiler.emit_iyimod = "mods"

      with_temp_executable("iyimod-object-code") do |executable|
        source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
        compiler.compile source, executable
      end

      artifact = Iyi::IyiMod.read(File.join("mods", "app", "greeter.iyimod"),
        want_object_code: true)
      unit = artifact.object_code.find { |candidate| candidate.name == "App::Greeter" }
      unit.should_not be_nil
      unit.not_nil!.code.should_not be_empty
    end
  end

  # The claim Part IV exists for, end to end: a program built from a module's
  # artifact, with the module's source **deleted**, that runs and prints what
  # the same program printed when it was built from source.
  #
  # The module is arithmetic on purpose: everything it calls is a primitive, so
  # this example is about the mechanism and nothing else. The example after it
  # is the one that needs the closure.
  it "builds and runs a program from a module's artifact, source deleted" do
    with_tempdir("iyimod_end_to_end") do
      Dir.mkdir_p "app"
      File.write "app/twice.iyi", <<-IYI
        module app/twice

        pub def twice(n : Int32) : Int32
          n + n
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/twice

        puts App::Twice.twice(21)
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "42"

      File.delete "app/twice.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "42"
    end
  end

  # An exported `enum`, which travels as its members and the numbers they were
  # given. Three things were in the way, each invisible until one was exported:
  # the question methods the compiler writes carried no return type, so R-2
  # refused the module ("`debug?` is exported and does not say what it
  # returns"); the writer asked the enum for its instance variables (`BUG:
  # Level::Level doesn't implement instance_vars`); and its members read as
  # code inside a type body, so the artifact could not be imported at all.
  #
  # The surface is not carried and must not be: `value`, `new` and a question
  # method per member are the consumer's compiler's to write from this
  # declaration, and `==`, `to_s` and the rest are the prelude's `Enum`.
  it "builds and runs a program from a module's exported enum" do
    with_tempdir("iyimod_enum") do
      Dir.mkdir_p "app"
      File.write "app/levels.iyi", <<-IYI
        module app/levels

        pub enum Level : Int32
          Debug = 0
          Warn  = 2
        end

        @[Flags]
        pub enum Mode
          Read
          Write
        end

        pub def loudest : Level
          Level::Warn
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/levels
        using app/levels::{Level, Mode, loudest}

        puts "\#{loudest} \#{loudest == Level::Warn} \#{loudest.warn?} \#{Level.values.size} \#{(Mode::Read | Mode::Write)}"
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "Warn true true 2 Read | Write"

      # The declaration carries the members and their numbers, and not the
      # `None` and `All` a `@[Flags]` enum is given wherever it is declared —
      # carried, they arrive as a redefinition of the consumer's own.
      artifact = Iyi::IyiMod.read(File.join("mods", "app", "levels.iyimod"))
      level = artifact.exports.types.find { |declaration| declaration.name == "Level" }
      level.should_not be_nil
      level.not_nil!.kind.should eq "enum"
      level.not_nil!.value.should eq "Int32"
      level.not_nil!.members.should eq [{"Debug", "0"}, {"Warn", "2"}]
      mode = artifact.exports.types.find { |declaration| declaration.name == "Mode" }
      mode.not_nil!.annotations.should eq ["@[Flags]"]
      mode.not_nil!.members.map(&.[0]).should eq ["Read", "Write"]

      File.delete "app/levels.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "Warn true true 2 Read | Write"
    end
  end

  # A generic the consumer instantiates, which is the one type an artifact
  # carries no object code for.
  #
  # `collect_iyi_unit_names` gives a module's object code a unit per non-generic
  # type it declares and none for a generic one, because a generic has machine
  # code only once somebody picks its arguments. The consumer is who picks them
  # here, so `Box(Int32)`'s methods are the consumer's to compile — and the
  # marking that says "this type's code is in the artifact" was reading the
  # generic itself, which made the consumer declare a `new` nobody defined.
  #
  # Written twice on purpose. `Box(Int32).new` is owned by the instance, which
  # was never marked and always worked; `Box.new(42)` infers the argument, and
  # inference makes `new` a method on `Box(T)` — the artifact's own type. Only
  # the second one linked undefined, so only the second one is the regression.
  it "builds a generic from an artifact whether or not its argument is written" do
    with_tempdir("iyimod_generic_instance") do
      Dir.mkdir_p "app"
      File.write "app/boxes.iyi", <<-IYI
        module app/boxes

        pub struct Box(T)
          getter value : T

          def initialize(@value : T)
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/boxes

        written = App::Boxes::Box(Int32).new(21)
        inferred = App::Boxes::Box.new(21)
        puts written.value + inferred.value
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "42"

      File.delete "app/boxes.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "42"
    end
  end

  # The closure (IV.1g): the module's body calls `String#+`, which lives in the
  # prelude's `String` unit — a unit the artifact does not carry and one whose
  # contents on the consumer's side are whatever *the consumer* instantiated.
  # The consumer here never writes a `+`, so nothing would define it, and this
  # is the build that failed to link before the module started carrying private
  # copies of what it calls.
  it "carries what a module's body calls but its consumer does not" do
    with_tempdir("iyimod_closure") do
      Dir.mkdir_p "app"
      File.write "app/greeter.iyi", <<-IYI
        module app/greeter

        pub def polite(name : String) : String
          "Hello, " + name
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/greeter

        puts App::Greeter.polite("world")
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "Hello, world"

      File.delete "app/greeter.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "Hello, world"
    end
  end

  # A type id is an external reference, which is what lets one build's object
  # file be linked by another's — and the definition comes from the consuming
  # program, which defines an id for every type it *has*. `Array(Item)` is not
  # one of them: it exists in the producing build because of a body that stays
  # behind, and nothing in the declarations the consumer reads would ever make
  # it. So `Array(App::Box::Item):type_id` was undefined at link, in a program
  # whose every method resolved.
  it "numbers the types a module's own code instantiates" do
    with_tempdir("iyimod_type_ids") do
      Dir.mkdir_p "app"
      File.write "app/box.iyi", <<-IYI
        module app/box

        pub struct Item
          @name : String

          def initialize(@name : String)
          end

          def name : String
            @name
          end
        end

        pub def labels : String
          items = Array(Item).new
          items << Item.new("a")
          items << Item.new("b")
          items.map { |item| item.name }.join(", ")
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/box

        puts App::Box.labels
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "a, b"

      # The instantiation the consumer cannot reach any other way, named in the
      # artifact so that it can make it.
      artifact = Iyi::IyiMod.read(File.join("mods", "app", "box.iyimod"))
      artifact.type_ids.should contain "Array(App::Box::Item)"

      File.delete "app/box.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "a, b"
    end
  end

  # A type the module keeps to itself still has to arrive, because its object
  # code refers to it: `Array(Secret):type_id` is resolved from a definition in
  # this program and a program can only number a type it has. So it travels as
  # a declaration without `pub` — reachable from nowhere, which is exactly what
  # it is when the module is read from source.
  it "carries a type its module does not export" do
    with_tempdir("iyimod_type_ids_private") do
      Dir.mkdir_p "app"
      File.write "app/box.iyi", <<-IYI
        module app/box

        struct Secret
          @n : Int32

          def initialize(@n : Int32)
          end

          def n : Int32
            @n
          end
        end

        pub def total : Int32
          items = Array(Secret).new
          items << Secret.new(2)
          items << Secret.new(3)
          items[0].n + items[1].n
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/box

        puts App::Box.total
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "5"

      artifact = Iyi::IyiMod.read(File.join("mods", "app", "box.iyimod"))
      secret = artifact.exports.types.find! { |declaration| declaration.name == "Secret" }
      secret.visibility.should eq "private"
      secret.fields.should eq [{"@n", "Int32", ""}]
      # Headers, and only headers. The consumer cannot reach them and the
      # module's own object code already defines them — but a body that
      # travels calls them, and a call it cannot typecheck is refused before
      # anything gets as far as being unreachable.
      secret.methods.map(&.name).sort!.should eq ["initialize", "n"]
      secret.methods.each { |signature| signature.required.should be_false }

      File.delete "app/box.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "5"

      # And carrying it does not make it reachable, which is the half R-2b is
      # about: the consumer has the type and may not name it.
      File.write "reach.iyi", <<-IYI
        module main

        import app/box

        puts App::Box::Secret.new(1).n
        IYI
      reaching = Iyi::Compiler::Source.new(File.expand_path("reach.iyi"), File.read("reach.iyi"))

      refuser = create_spec_compiler
      refuser.prelude = "iyi/prelude"
      refuser.use_iyimod = "mods"
      refuser.no_codegen = true
      expect_raises(Iyi::TypeException, /does not export App::Box::Secret/) do
        refuser.compile reaching, "unused"
      end
    end
  end

  # R-3 says there are no open classes, and the way somebody reaches for one is
  # a qualified declaration: `struct App::A::Point` inside their own module.
  # Crystal reads that as reopening. iyi cannot, so it used to create a second
  # `Point` under `Main::App::A` and fail later with `wrong number of arguments
  # for 'Main::App::A::Point.new'`, which names neither the rule nor the type
  # the author meant.
  it "refuses a declaration that adds to another module's namespace" do
    with_tempdir("iyi_r3_reopen") do
      Dir.mkdir_p "app"
      File.write "app/a.iyi", <<-IYI
        module app/a

        pub struct Point
          getter x : Int32

          def initialize(@x : Int32)
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/a

        struct App::A::Point
          def doubled : Int32
            x * 2
          end
        end

        puts App::A::Point.new(2).doubled
        IYI
      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      compiler = create_spec_compiler
      compiler.prelude = "iyi/prelude"
      compiler.no_codegen = true
      expect_raises(Iyi::TypeException, /`App::A::Point` already exists.*cannot add to it/m) do
        compiler.compile source, "unused"
      end

      # A file's own namespace is its own to declare into, and two modules
      # under `app/` share `App` by design: neither is reopening.
      File.write "main.iyi", <<-IYI
        module main

        import app/a

        module Helpers
        end

        struct Helpers::Thing
          def n : Int32
            7
          end
        end

        puts Helpers::Thing.new.n + App::A::Point.new(2).x
        IYI
      allowed = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
      ok = create_spec_compiler
      ok.prelude = "iyi/prelude"
      ok.compile allowed, File.expand_path("allowed")
      `./allowed`.chomp.should eq "9"
    end
  end

  # R-2 was a rule the format assumed and nothing checked, and the cost of that
  # landed on the consumer: `pub def greet(name)` compiled, the artifact
  # recorded `def greet(name)`, and a build reading it typed the call from a
  # return type that was not there. The producer emitted `greet<String>:String`
  # and the consumer asked the linker for `greet<String>:Nil`.
  it "refuses an exported def that does not write its types down" do
    with_tempdir("iyimod_r2") do
      Dir.mkdir_p "app"
      File.write "main.iyi", <<-IYI
        module main

        import app/a

        puts App::A.greet("x")
        IYI
      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      write = ->(body : String) do
        File.write "app/a.iyi", "module app/a\n\n#{body}\n"
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.emit_iyimod = "mods"
        compiler.no_codegen = true
        compiler
      end

      expect_raises(Iyi::TypeException, /`greet` is exported and does not say what `name` is/) do
        write.call("pub def greet(name)\n  \"hi \#{name}\"\nend").compile source, "unused"
      end

      expect_raises(Iyi::TypeException, /`greet` is exported and does not say what it returns/) do
        write.call("pub def greet(name : String)\n  \"hi \#{name}\"\nend").compile source, "unused"
      end

      # Written down, and the same program builds from the artifact and prints
      # what the build from source prints.
      compiler = write.call("pub def greet(name : String) : String\n  \"hi \#{name}\"\nend")
      compiler.no_codegen = false
      compiler.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "hi x"

      File.delete "app/a.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "hi x"
    end
  end

  # A method that takes a block is instantiated with the caller's block inlined
  # into it, so its machine code belongs to whoever wrote the block. The
  # producer emits none — it would be a duplicate for a block it happened to
  # write and missing for every block it did not — and the body travels instead,
  # for the reason a generic's method and a trait's default do (SPEC.md IV.1g).
  it "carries the body of a method that takes a block" do
    with_tempdir("iyimod_block_bodies") do
      Dir.mkdir_p "app"
      File.write "app/box.iyi", <<-IYI
        module app/box

        pub class Box
          alias Step = Int32 -> Int32

          private record Entry,
            step : Step

          getter label : String
          @entries : Array(Entry)

          def initialize(@label : String)
            @entries = [] of Entry
          end

          def add(&block : Int32 -> Int32) : Nil
            @entries << Entry.new(step: block)
          end

          def run(start : Int32) : Int32
            total = start
            @entries.each { |entry| total = entry.step.call(total) }
            total
          end
        end

        pub def boxed(label : String, &block : Int32 -> Int32) : Box
          box = Box.new(label)
          box.add(&block)
          box
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/box

        box = App::Box.boxed("doubling") { |n| n * 2 }
        box.add { |n| n + 1 }
        puts box.label
        puts box.run(5)
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "doubling\n11"

      artifact = Iyi::IyiMod.read(File.join("mods", "app", "box.iyimod"))

      # Whatever the def is written on: a module's own `pub def` and a method
      # of an exported class are the same case.
      artifact.mono_bodies.keys.should contain "app/box#boxed(label : String)&block : (Int32 -> Int32)"
      artifact.mono_bodies.keys.should contain "Box#add()&block : (Int32 -> Int32)"

      box = artifact.exports.types.find! { |declaration| declaration.name == "Box" }

      # Declaration order, because it is the layout the consumer's copy of
      # `add` writes `@entries` at and the module's own `run` reads it from.
      box.fields.map { |(name, _, _)| name }.should eq ["@label", "@entries"]

      # The alias travels because a declaration that travels names it: the
      # carried record's `step : Step` is the text this module was written
      # with, and a consumer without the alias reads an undefined constant.
      #
      # As written, not as resolved — `it "carries an alias as the module
      # wrote it"` is why, and `Proc(Int32, Int32)` is what this used to say.
      step = box.types.find! { |nested| nested.name == "Step" }
      step.kind.should eq "alias"
      step.value.should eq "(Int32 -> Int32)"

      File.delete "app/box.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "doubling\n11"
    end
  end

  # A body that travels calls what the module keeps to itself, and being
  # unreachable does not change who compiles a block-taking def. Both shapes
  # are here because they are one hole seen in two namespaces: a method on a
  # type the module does not export, and a def at the module's own top level.
  it "carries the unexported defs a travelling body calls" do
    with_tempdir("iyimod_carried_defs") do
      Dir.mkdir_p "app"
      File.write "app/box.iyi", <<-IYI
        module app/box

        class Hidden
          @n : Int32

          def initialize(@n : Int32)
          end

          def tweak(&block : Int32 -> Int32) : Int32
            block.call(@n)
          end
        end

        def helper(start : Int32, &block : Int32 -> Int32) : Int32
          Hidden.new(start).tweak(&block)
        end

        pub def run(start : Int32, &block : Int32 -> Int32) : Int32
          helper(start, &block)
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/box

        puts App::Box.run(5) { |n| n * 3 }
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "15"

      artifact = Iyi::IyiMod.read(File.join("mods", "app", "box.iyimod"))

      # Kept out of `functions`, which is the module's surface and stays what a
      # consumer may call.
      artifact.exports.functions.map(&.name).should eq ["run"]
      artifact.exports.carried_functions.map(&.name).should eq ["helper"]

      # With their bodies, because a header would promise a symbol the producer
      # never emitted: it makes no machine code for a block-taking def either.
      artifact.mono_bodies.keys.should contain "app/box#helper(start : Int32)&block : (Int32 -> Int32)"
      artifact.mono_bodies.keys.should contain "Hidden#tweak()&block : (Int32 -> Int32)"

      File.delete "app/box.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "15"

      # And carrying them leaves R-2b where it was: the consumer has them and
      # may not name them, with the message it gets from source.
      File.write "reach.iyi", <<-IYI
        module main

        import app/box

        puts App::Box.helper(5) { |n| n * 3 }
        IYI
      reaching = Iyi::Compiler::Source.new(File.expand_path("reach.iyi"), File.read("reach.iyi"))

      refuser = create_spec_compiler
      refuser.prelude = "iyi/prelude"
      refuser.use_iyimod = "mods"
      refuser.no_codegen = true
      expect_raises(Iyi::TypeException, /does not export 'helper'/) do
        refuser.compile reaching, "unused"
      end
    end
  end

  # A macro has no machine code to arrive as and no `pub` to be exported with,
  # and a body that travels calls one: the consumer compiles `run`, `run`
  # writes `twice(n)`, and `twice` is a macro of the module `run` came from.
  # Both places one can be written are here, because they are one rule.
  it "carries the macros a travelling body expands" do
    with_tempdir("iyimod_macro_bodies") do
      Dir.mkdir_p "app"
      File.write "app/box.iyi", <<-IYI
        module app/box

        macro twice(x)
          ({{x}} + {{x}})
        end

        pub class Box
          macro double(x)
            ({{x}} * 2)
          end

          @n : Int32

          def initialize(@n : Int32)
          end

          def run(&block : Int32 -> Int32) : Int32
            block.call(double(@n))
          end
        end

        pub def run_module(n : Int32, &block : Int32 -> Int32) : Int32
          block.call(twice(n))
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/box

        puts App::Box::Box.new(5).run { |n| n + 1 }
        puts App::Box.run_module(5) { |n| n + 1 }
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "11\n11"

      artifact = Iyi::IyiMod.read(File.join("mods", "app", "box.iyimod"))
      artifact.macro_bodies.size.should eq 1
      artifact.macro_bodies.first.should start_with "macro twice"

      # On the type it was declared on, because that is where it is looked up.
      box = artifact.exports.types.find! { |declaration| declaration.name == "Box" }
      box.macros.size.should eq 1
      box.macros.first.should start_with "macro double"

      File.delete "app/box.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "11\n11"
    end
  end

  # An error in the declarations has a location in them, and the file that
  # location names is binary — so the line it showed was the bytes of the
  # container the declarations travelled in. The text is what the build read
  # and the text is what it shows.
  it "shows the declaration an error is in, not the bytes of the artifact" do
    with_tempdir("iyimod_error_source") do
      Dir.mkdir_p "app"
      # A generic's body travels and the consumer instantiates it, so a type
      # the producer never tried is where this lands: the error is in a line of
      # the module's, reported to somebody who does not have the module.
      File.write "app/box.iyi", <<-IYI
        module app/box

        pub struct Box(T)
          @item : T

          def initialize(@item : T)
          end

          def doubled : T
            @item + @item
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/box

        puts App::Box::Box(Int32).new(21).doubled
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "42"

      File.delete "app/box.iyi"

      File.write "bad.iyi", <<-IYI
        module main

        import app/box

        puts App::Box::Box(Bool).new(true).doubled
        IYI
      bad = Iyi::Compiler::Source.new(File.expand_path("bad.iyi"), File.read("bad.iyi"))

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.no_codegen = true

      error = expect_raises(Iyi::TypeException, /undefined method '\+' for Bool/) do
        consumer.compile bad, File.expand_path("unused")
      end

      rendered = error.to_s
      rendered.should contain "@item + @item"
      rendered.should contain "box.iyimod"
      # The bytes the artifact starts with, which is what used to be shown.
      rendered.should_not contain "IYIMOD"
    end
  end

  # A class variable is a global, and its global is defined in the main module
  # — the one part of a build that never travels. The methods that read one
  # travel as this module's machine code referring to it by symbol, so a module
  # with a `@@seen` failed R-1's own round trip on
  # `undefined symbol: App::Counter::Tally::seen`, and this file's own gate for
  # that claim passed because no sample had a class variable.
  #
  # Two of them, and the nilable one is not decoration. `@@cache : String? = nil`
  # has its initialiser dropped before an artifact is written — assigning nil
  # assigns nothing — so the declaration travelling is not enough on its own:
  # the consumer read it, made no initialiser from it, and codegen emitted no
  # global. The name travelling in `ClassVars` is what closes that half.
  it "carries a module's class variables, declaration and global" do
    with_tempdir("iyimod_class_vars") do
      Dir.mkdir_p "app"
      File.write "app/counter.iyi", <<-IYI
        module app/counter

        pub struct Tally
          @@cache : String? = nil
          @@seen : Int32 = 0

          def initialize
          end

          pub def remember(s : String) : String
            @@cache = s
            @@seen = @@seen + 1
            (@@cache || "none") + ":" + @@seen.to_s
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/counter

        t = App::Counter::Tally.new
        puts t.remember("hello")
        puts t.remember("again")
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "hello:1\nagain:2"

      artifact = Iyi::IyiMod.read(File.join("mods", "app", "counter.iyimod"))
      # The module's own two, plus the scheduler's: `raise` reaches the
      # panic path now (III.1.4), so every unit's object code refers to
      # the runtime's globals — the same rule that carries
      # `Unicode::@@upcase_ranges` for a shard that calls `upcase`, and
      # the consumer emits them once either way.
      artifact.class_vars.map(&.name).select(&.starts_with?("App::")).should eq [
        "App::Counter::Tally::@@cache",
        "App::Counter::Tally::@@seen",
      ]
      artifact.class_vars.map(&.name).any?(&.starts_with?("IyiScheduler::")).should be_true

      # None of them lazy, and that is a fact about the prelude rather than
      # about these two: iyi's has no `__crystal_once`, so a unit under it
      # never reads a class variable through an init flag.
      artifact.class_vars.map(&.lazy).uniq.should eq [false]

      tally = artifact.exports.types.find { |type| type.name == "Tally" }.should_not be_nil
      tally.class_vars.map { |class_var| {class_var.name, class_var.type, class_var.value} }
        .should eq [{"@@cache", "(String | Nil)", ""}, {"@@seen", "Int32", "0"}]
      tally.class_vars.map(&.annotations).should eq [[] of String, [] of String]

      File.delete "app/counter.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "hello:1\nagain:2"
    end
  end

  # A constant is typed and initialised where it is *read*, and on the far side
  # of an artifact the only reader is machine code the consumer did not compile.
  # So `kemal/dsl`'s `APP` was declared, assigned by the initialiser that
  # travelled, and never given a symbol — every exported method in the unit
  # called through a global nothing defined.
  it "carries the constants a module's own code reads" do
    with_tempdir("iyimod_constants") do
      Dir.mkdir_p "app"
      File.write "app/counter.iyi", <<-IYI
        module app/counter

        pub struct Tally
          @n : Int32

          def initialize(@n : Int32)
          end

          def n : Int32
            @n
          end
        end

        START = Tally.new(40)

        pub def total : Int32
          START.n + 2
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/counter

        puts App::Counter.total
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "42"

      artifact = Iyi::IyiMod.read(File.join("mods", "app", "counter.iyimod"))
      artifact.constants.should eq ["App::Counter::START"]

      File.delete "app/counter.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "42"
    end
  end

  # The router's shape: a `private record` inside an exported class. It belongs
  # to the class rather than to the module's surface — R-2 governs the unit's
  # own body — so it travels inside its container, and the field that names it
  # travels with the name it was written with.
  it "carries a type declared inside a carried type" do
    with_tempdir("iyimod_nested_types") do
      Dir.mkdir_p "app"
      File.write "app/router.iyi", <<-IYI
        module app/router

        pub class Router
          private struct Route
            @method : String
            @path : String

            def initialize(@method : String, @path : String)
            end
          end

          @routes : Array(Route)

          def initialize
            @routes = Array(Route).new
          end

          pub def add(method : String, path : String) : Nil
            @routes << Route.new(method, path)
          end

          pub def count : Int32
            @routes.size
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/router

        router = App::Router::Router.new
        router.add("GET", "/")
        router.add("POST", "/x")
        puts router.count
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "2"

      artifact = Iyi::IyiMod.read(File.join("mods", "app", "router.iyimod"))
      router = artifact.exports.types.find! { |declaration| declaration.name == "Router" }
      route = router.types.find! { |declaration| declaration.name == "Route" }
      route.visibility.should eq "private"

      # Rendered where it was written, because iyi cannot reopen `Router` to
      # add it afterwards.
      io = IO::Memory.new
      Iyi::IyiMod.declarations artifact, io
      io.to_s.should contain "  private struct Route"

      File.delete "app/router.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "2"
    end
  end

  # A class method lives on the type's *metaclass*, so walking a type's own
  # defs dropped every one a module exported — `Counter.zero` was an undefined
  # method on the far side of an artifact that looked complete. And a field
  # with a bodyless `initialize` is the shape no sample has: the artifact's
  # `initialize` has no body to assign `@n` in, which read as leaving it
  # nilable and refused the module outright.
  it "carries a type's class methods, and its bodyless initialize" do
    with_tempdir("iyimod_class_methods") do
      Dir.mkdir_p "std"
      File.write "std/counter.iyi", <<-IYI
        module std/counter

        pub struct Counter
          @n : Int32

          def initialize(@n : Int32)
          end

          def self.zero : Counter
            Counter.new(0)
          end

          def n : Int32
            @n
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import std/counter

        puts Std::Counter::Counter.zero.n
        puts Std::Counter::Counter.new(5).n
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "0\n5"

      declaration = Iyi::IyiMod.read(File.join("mods", "std", "counter.iyimod"))
        .exports.types.find! { |candidate| candidate.name == "Counter" }

      declaration.methods.find { |m| m.name == "zero" }.try(&.receiver).should eq "self"

      # `allocate` is put on every metaclass by the compiler and `new` is
      # synthesized from `initialize`; describing either as part of the
      # module's surface would be describing this compiler instead.
      declaration.methods.map(&.name).should eq ["initialize", "n", "zero"]

      File.delete "std/counter.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "0\n5"
    end
  end

  # `MonoBodies`. A generic type's method exists once per instantiation, and
  # the instantiations belong to whoever writes them — so no machine code the
  # producer emits can serve a consumer, and the body is the only thing that
  # can travel. The consumer here instantiates at a type the producer never
  # did, which is the case that makes carrying the producer's object code no
  # answer at all. The fixture is `pack/box`, not `std/box`: that module
  # ships, and deleting the fixture would find the library's (the case the
  # "names a module whose path reaches another file now" example holds).
  it "ships a generic type's bodies, and the consumer specialises them" do
    with_tempdir("iyimod_mono_generic") do
      Dir.mkdir_p "pack"
      File.write "pack/box.iyi", <<-IYI
        module pack/box

        pub struct Box(T)
          @item : T

          def initialize(@item : T)
          end

          def item : T
            @item
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import pack/box

        puts Pack::Box::Box(Int32).new(7).item
        puts Pack::Box::Box(String).new("seven").item
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "7\nseven"

      artifact = Iyi::IyiMod.read(File.join("mods", "pack", "box.iyimod"))
      artifact.mono_bodies.keys.should contain "Box#item()"

      File.delete "pack/box.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "7\nseven"
    end
  end

  # The rest of what crosses the boundary once a consumer picks the arguments.
  #
  # The spec above and the one at the top of this file both write `Box(Int32)`,
  # which is the form that was never in doubt: an instance is a type the
  # consumer made and nothing marked it as the artifact's. These are the three
  # shapes where the generic itself is the owner, so each one asks the same
  # question the linker asked, on a different path. A method with its own
  # `forall`, whose specialisation is picked twice over; an `impl` written on
  # the generic, whose method is reached through the trait; and an instance of
  # an instance, which numbers a type nothing declared.
  it "specialises an imported generic however the consumer reaches it" do
    with_tempdir("iyimod_generic_reach") do
      Dir.mkdir_p "pack"
      File.write "pack/box.iyi", <<-IYI
        module pack/box

        pub trait Show
          abstract def show : String
        end

        pub struct Box(T)
          getter value : T

          def initialize(@value : T)
          end

          def map(& : T -> U) : Box(U) forall U
            Box(U).new(yield value)
          end
        end

        impl Show for Box(T) forall T
          def show : String
            "shown"
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import pack/box

        puts Pack::Box::Box.new(21).map { |v| v + v }.value
        puts Pack::Box::Box.new(1).show
        puts Pack::Box::Box.new(Pack::Box::Box.new(5)).value.value
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "42\nshown\n5"

      File.delete "pack/box.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "42\nshown\n5"
    end
  end

  # The other half of `MonoBodies`, and the half no producer could ever emit
  # code for: a trait default is stencilled onto the implementing type, and the
  # implementing type here is declared by the *consumer*. There is no name the
  # producing build could have compiled it under.
  it "ships a trait's default bodies, and the consumer stencils them" do
    with_tempdir("iyimod_mono_trait") do
      Dir.mkdir_p "std"
      File.write "std/countable.iyi", <<-IYI
        module std/countable

        pub trait Countable
          abstract def count : Int32

          def doubled : Int32
            count + count
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import std/countable

        using std/countable::{Countable}

        pub struct Three
        end

        impl Countable for Three
          def count : Int32
            3
          end
        end

        puts Three.new.doubled
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "6"

      artifact = Iyi::IyiMod.read(File.join("mods", "std", "countable.iyimod"))
      artifact.mono_bodies.keys.should contain "Countable#doubled()"

      File.delete "std/countable.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "6"
    end
  end

  # And the boundary, which is what keeps the two mechanisms from colliding. An
  # ordinary method of an ordinary type travels as machine code, so its body
  # must **not** also travel: a consumer given both would compile a definition
  # the artifact already carries, and the link would fail on a duplicate
  # symbol. Kept as an example because nothing else says it out loud.
  it "does not ship the body of a method that travels as machine code" do
    with_tempdir("iyimod_mono_boundary") do
      Dir.mkdir_p "app"
      File.write "app/greeter.iyi", <<-IYI
        module app/greeter

        pub struct Greeter
          def hello : String
            "hello"
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/greeter

        puts App::Greeter::Greeter.new.hello
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")

      artifact = Iyi::IyiMod.read(File.join("mods", "app", "greeter.iyimod"),
        want_object_code: true)
      artifact.mono_bodies.should be_empty
      artifact.object_code.map(&.name).should contain "App::Greeter::Greeter"

      File.delete "app/greeter.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "hello"
    end
  end

  it "round-trips mono bodies" do
    with_temporary_file do |path|
      artifact = sample_artifact
      artifact.mono_bodies["Box#item()"] = "@item\n"
      Iyi::IyiMod.write artifact, path

      Iyi::IyiMod.read(path).mono_bodies.should eq({"Box#item()" => "@item\n"})
    end
  end

  it "renders a mono body under the declaration it belongs to" do
    declaration = type_declaration("Box", "generic struct",
      type_parameters: ["T"],
      methods: [signature("item", return_type: "T")])

    artifact = sample_artifact(types: [declaration])
    artifact.mono_bodies["Box#item()"] = "@item"

    io = IO::Memory.new
    Iyi::IyiMod.declarations artifact, io

    io.to_s.should contain "  def item : T\n    @item\n  end\n"
  end

  # III.5's initialiser is the one part of a module that is neither a
  # declaration nor the body of one, and it has to run — in DAG order, before
  # anything that imports the module. It travels as source text and is compiled
  # by the consumer, which is also what produces the module's constants and its
  # proc literals: nothing else could have.
  #
  # Two modules, because one would not show the ordering. `boot/config` is
  # imported by `boot/registry`, so it initialises first however the imports
  # are written — and `boot/registry`'s own `import` sits *below* a statement
  # of its own, which is the case III.5 rule 1 exists for.
  it "carries a module's initialiser, in import order" do
    with_tempdir("iyimod_initialiser") do
      Dir.mkdir_p "boot"
      File.write "boot/config.iyi", <<-IYI
        module boot/config

        puts "1. config"

        pub def name : String
          "iyi"
        end
        IYI
      File.write "boot/registry.iyi", <<-IYI
        module boot/registry

        puts "2. registry, above its own import"

        import boot/config

        puts "3. registry, below it"

        pub def greeting : String
          Boot::Config.name
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import boot/registry

        puts "4. main"
        puts Boot::Registry.greeting
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
      expected = "1. config\n2. registry, above its own import\n3. registry, below it\n4. main\niyi"

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq expected

      artifact = Iyi::IyiMod.read(File.join("mods", "boot", "registry.iyimod"))
      artifact.has_initialiser.should be_false
      artifact.initialiser.lines.size.should eq 2

      File.delete "boot/config.iyi"
      File.delete "boot/registry.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq expected
    end
  end

  # What the initialiser does *not* reach: a statement in a type body. It is
  # not a declaration, so nothing in `Exports` carries it, and it is not the
  # module's own top level, so the initialiser does not either. Refused rather
  # than linked, because the alternative is a program that runs with that part
  # silently missing.
  #
  # A class variable was what this was written with, and that was wrong: its
  # value travels in `TypeDecl#class_vars` and the consumer initialises it —
  # `it "carries a class variable's value"` below is the proof. A bare `puts`
  # is the shape that has nowhere to go.
  it "refuses to generate code against a module whose type body has to run" do
    with_tempdir("iyimod_type_body") do
      Dir.mkdir_p "boot"
      File.write "boot/counter.iyi", <<-IYI
        module boot/counter

        pub struct Counter
          puts "the type body ran"

          def count : Int32
            7
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import boot/counter

        puts Boot::Counter::Counter.new.count
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.no_codegen = true
      producer.compile source, File.expand_path("unused")

      Iyi::IyiMod.read(File.join("mods", "boot", "counter.iyimod"))
        .has_initialiser.should be_true

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      expect_raises(Iyi::TypeException, /has code inside a type body/) do
        consumer.compile source, File.expand_path("from-artifact")
      end

      # Front end only, which is what the artifact does carry: still fine.
      checker = create_spec_compiler
      checker.prelude = "iyi/prelude"
      checker.use_iyimod = "mods"
      checker.no_codegen = true
      checker.compile source, File.expand_path("unused-too")
    end
  end

  # And what it does reach, which is the other half of the same rule. A
  # constant in a type body is not runnable code the artifact drops: it is a
  # declaration with a value, and it travels qualified — `Point::MAX = 10` —
  # the way `iyi tool bind` has always carried a bound Crystal namespace's.
  #
  # Without that it was in the artifact nowhere at all: not in `Exports`,
  # which carries types and signatures, and not in the initialiser, which
  # stopped at the type's body. So the module read as one whose type body has
  # to run and every consumer of it was refused — thirteen of `src/std`'s own
  # modules, `std/math` over `PI`.
  #
  # The sources are deleted before the consuming build, so nothing here can
  # pass by reading them, and the program is *run*: a constant that arrives
  # declared and never initialised answers zero, which a compile would not
  # catch.
  #
  # All three spellings, because they reach the consumer by different paths:
  # `pub` is read by the consumer's own source, the private one only by a body
  # this module compiled into the artifact's object code, and the nested one
  # has a name that is two namespaces deep.
  it "carries the constants a type body declares" do
    with_tempdir("iyimod_type_constants") do
      Dir.mkdir_p "boot"
      File.write "boot/limits.iyi", <<-IYI
        module boot/limits

        pub struct Limits
          pub MAX = 10
          private SCALE = 3

          pub struct Inner
            pub DEPTH = 2
          end

          pub def self.scaled : Int32
            MAX * SCALE
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import boot/limits

        puts Boot::Limits::Limits::MAX
        puts Boot::Limits::Limits.scaled
        puts Boot::Limits::Limits::Inner::DEPTH
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
      expected = "10\n30\n2"

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq expected

      artifact = Iyi::IyiMod.read(File.join("mods", "boot", "limits.iyimod"))
      artifact.has_initialiser.should be_false
      artifact.initialiser.lines.should eq [
        "pub Limits::MAX = 10",
        "Limits::SCALE = 3",
        "pub Limits::Inner::DEPTH = 2",
      ]

      File.delete "boot/limits.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq expected
    end
  end

  # Two more things the check read as code, both of them declarations.
  #
  # A `lib` body is the first: a `fun` is a C prototype, a `type` names a
  # pointer, a `struct` is a layout. Nothing in one runs, so nothing in one
  # can be the piece of setup III.5 is about — and every module with a `lib`
  # in it was refused. `std/math` binds two LLVM intrinsics and its consumers
  # were told it "has code inside a type body that has to run".
  #
  # A macro is the second, and it is where the constants of the modules that
  # bind a platform live: `std/file` writes `AT_FDCWD` inside a `{% if
  # flag?(:linux) %}`. A `{% for %}` here rather than a `flag?`, so the
  # expansion is the same on every machine this spec runs on; the node is the
  # same `ExpandableNode` either way.
  #
  # Run, with the source deleted, because the point is not that the build is
  # allowed: it is that `LOW` is 1 on the far side and the `fun` still reaches
  # the intrinsic.
  it "carries a lib's declarations and the constants a macro writes" do
    with_tempdir("iyimod_lib_and_macro") do
      Dir.mkdir_p "boot"
      File.write "boot/plat.iyi", <<-IYI
        module boot/plat

        lib LibPlat
          type Handle = Void*

          struct Pair
            a : Int32
            b : Int32
          end

          fun plat_abs = "llvm.fabs.f64"(x : Float64) : Float64
        end

        pub struct Plat
          {% for name, value in {"LOW" => 1, "HIGH" => 2} %}
            pub {{name.id}} = {{value}}
          {% end %}

          pub def self.magnitude(x : Float64) : Float64
            LibPlat.plat_abs(x)
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import boot/plat

        puts Boot::Plat::Plat::LOW
        puts Boot::Plat::Plat::HIGH
        puts Boot::Plat::Plat.magnitude(-2.5)
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
      expected = "1\n2\n2.5"

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq expected

      artifact = Iyi::IyiMod.read(File.join("mods", "boot", "plat.iyimod"))
      artifact.has_initialiser.should be_false
      artifact.initialiser.lines.should eq ["pub Plat::LOW = 1", "pub Plat::HIGH = 2"]

      File.delete "boot/plat.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq expected
    end
  end

  # A class variable's value travels, so a module with one is consumable.
  #
  # This was the case the type-body rule was written for, on the reading that
  # a class variable's initialiser belongs to the type and nothing carries it.
  # Half of that is true — it is not in the module's initialiser — and the
  # other half stopped being true when `TypeDecl#class_vars` started carrying
  # the value as written, so the consumer declares `@@names : Array(String) =
  # ["a", "b"]` and initialises it like any other.
  #
  # Three shapes, because "the value travels" has to mean more than a number:
  # a literal, a collection literal (whose node `CleanupTransformer` rewrites
  # into temporaries, which is why the *source* is what travels), and one
  # whose value calls a private def of the module — a body the consumer never
  # sees, reached in the artifact's own object code.
  it "carries a class variable's value" do
    with_tempdir("iyimod_class_var_value") do
      Dir.mkdir_p "boot"
      File.write "boot/reg.iyi", <<-IYI
        module boot/reg

        private def seed : Int32
          41
        end

        pub struct Reg
          @@count = 7
          @@names = ["a", "b"]
          @@base : Int32 = seed + 1

          pub def self.report : String
            @@count.to_s + ":" + @@names.join(",") + ":" + @@base.to_s
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import boot/reg

        puts Boot::Reg::Reg.report
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
      expected = "7:a,b:42"

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq expected

      Iyi::IyiMod.read(File.join("mods", "boot", "reg.iyimod"))
        .has_initialiser.should be_false

      File.delete "boot/reg.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq expected
    end
  end

  # An enum the module keeps to itself travels as its members, which is what
  # an enum is.
  #
  # The exported side has always written them down. The carried side — a type
  # a consumer cannot name but the module's own object code does — fell
  # through to the branch built for a class, and wrote the *question methods*
  # the consumer's own compiler generates from the members while writing no
  # members at all. The consumer read `private enum Kind` with a `Large?` in
  # it and nothing to number, and said `enum Kind must have at least one
  # member` about a type nobody outside the module can write.
  #
  # The numbers are asserted, not just the names: the module's object code was
  # compiled against these, and a consumer that renumbered from zero would
  # agree with it only by luck. `@[Flags]` is here for the pair the compiler
  # adds wherever a flags enum is declared — writing `None` and `All` down
  # hands the consumer its own two back.
  it "carries the members of an enum it does not export" do
    with_tempdir("iyimod_carried_enum") do
      Dir.mkdir_p "boot"
      File.write "boot/kinds.iyi", <<-IYI
        module boot/kinds

        enum Kind
          Small  = 3
          Large  = 9
        end

        @[Flags]
        enum Mode
          Read
          Write
        end

        pub struct Holder
          pub def self.describe : String
            Kind::Large.to_s + ":" + Kind::Large.value.to_s + ":" + (Mode::Read | Mode::Write).to_s
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import boot/kinds

        puts Boot::Kinds::Holder.describe
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
      expected = "Large:9:Read | Write"

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq expected

      declarations = String.build do |io|
        Iyi::IyiMod.declarations(Iyi::IyiMod.read(File.join("mods", "boot", "kinds.iyimod")), io)
      end
      declarations.should contain "private enum Kind : Int32\n  Small = 3\n  Large = 9\nend"
      declarations.should contain "@[Flags]\nprivate enum Mode : Int32\n  Read = 1\n  Write = 2\nend"

      File.delete "boot/kinds.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq expected
    end
  end

  # A header with a splat in it: keyword-only parameters, called by name.
  #
  # This crashed the compiler rather than refusing anything. A def read from
  # an artifact is a header, and headers take the forwarding path through
  # `expand_default_arguments` — evaluate the defaults here, call the symbol
  # there — which is written for a plain parameter list and passes the whole
  # of it by position. A bare `*` is a nameless `Arg` in that list: the build
  # died on `Nil assertion failed` reading its missing default, or on `Index
  # out of bounds` where the call named fewer parameters than the def has.
  #
  # A def with a splat keeps its body instead, which is what upstream does
  # with one and what links: the producer emits a symbol per named-argument
  # combination — `Span::new:days<Int64>` — and the expansion built here
  # carries the same name, built from the same named arguments. The body it
  # keeps is the header's `Nop`, so the expansion has to be marked a header
  # too, or codegen inlines the nothing it sees and the call vanishes.
  #
  # `self.new` because that is the shape the library writes — `Time::Span`
  # has one, and `std/time`, `std/json` and `std/kernel` were all refused
  # over it — and one more named `make`, because `new` has an expansion path
  # of its own and the defect is in the other one.
  it "carries a header whose parameters are keyword-only" do
    with_tempdir("iyimod_splat_header") do
      Dir.mkdir_p "boot"
      File.write "boot/span.iyi", <<-IYI
        module boot/span

        pub struct Span
          @ticks : Int64

          def initialize(@ticks : Int64)
          end

          pub def self.new(*, days : Int64 = 0_i64, hours : Int64 = 0_i64) : Span
            Span.new(days * 24_i64 + hours)
          end

          pub def self.make(*, hours : Int64) : Span
            Span.new(hours)
          end

          pub def ticks : Int64
            @ticks
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import boot/span

        puts Boot::Span::Span.new(days: 2_i64).ticks
        puts Boot::Span::Span.new(hours: 5_i64).ticks
        puts Boot::Span::Span.new(days: 1_i64, hours: 3_i64).ticks
        puts Boot::Span::Span.make(hours: 9_i64).ticks
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
      expected = "48\n5\n27\n9"

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq expected

      File.delete "boot/span.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq expected
    end
  end

  # An alias travels as the type expression the module wrote.
  #
  # It used to travel as what the name resolved to, and a resolved type is
  # not always something that can be written down again. Two shapes here,
  # both taken from `src/std`:
  #
  # * `pub alias Ary = ::Array` is an uninstantiated generic, and one prints
  #   with its type variables — the consumer read `alias Ary = Array(T)` and
  #   said `undefined constant T` about a letter nobody wrote.
  # * `pub alias Array = ::Array` hands a prelude type out under its own
  #   name, and a resolved name has no `::` on it: inside `module Boot::Ring`
  #   the consumer read `alias Array = Array`, which is the alias itself —
  #   `infinite recursive definition of alias`. `std/annotations`,
  #   `std/bit_array` and `std/static_array` each do exactly this.
  #
  # The written form resolves on the far side because the declarations text
  # replays the module's imports, requires and `using` directives and
  # declares its own nested types, which is the whole of what the module
  # itself could name.
  it "carries an alias as the module wrote it" do
    with_tempdir("iyimod_alias_value") do
      Dir.mkdir_p "boot"
      File.write "boot/ring.iyi", <<-IYI
        module boot/ring

        pub alias Array = ::Array
        pub alias Ary = ::Array

        pub def first(items : Array(Int32)) : Int32
          items[0]
        end

        pub def last(items : Ary(Int32)) : Int32
          items[items.size - 1]
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import boot/ring

        puts Boot::Ring.first([7, 8])
        puts Boot::Ring.last([7, 8])
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
      expected = "7\n8"

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq expected

      declarations = String.build do |io|
        Iyi::IyiMod.declarations(Iyi::IyiMod.read(File.join("mods", "boot", "ring.iyimod")), io)
      end
      declarations.should contain "pub alias Array = ::Array"
      declarations.should contain "pub alias Ary = ::Array"

      File.delete "boot/ring.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq expected
    end
  end

  it "round-trips a module's initialiser" do
    with_temporary_file do |path|
      artifact = Iyi::IyiMod::Artifact.new(
        module_name: "boot/config",
        source_path: "/src/boot/config.iyi",
        compiler_version: "1.22.0-dev+abc1234",
        target_triple: "x86_64-pc-linux-gnu",
        flags: ["bits64"],
        imports: [] of Iyi::IyiMod::ImportEdge,
        initialiser: %(puts("one")\nputs("two")),
      )
      Iyi::IyiMod.write artifact, path

      Iyi::IyiMod.read(path).initialiser.should eq %(puts("one")\nputs("two"))
    end
  end

  it "round-trips the hashes" do
    with_temporary_file do |path|
      artifact = Iyi::IyiMod::Artifact.new(
        module_name: "app/box",
        source_path: "/src/app/box.iyi",
        compiler_version: "1.22.0-dev+abc1234",
        target_triple: "x86_64-pc-linux-gnu",
        flags: ["bits64"],
        imports: [] of Iyi::IyiMod::ImportEdge,
        hashes: Iyi::IyiMod::Hashes.new("iface", "impl", "src"),
      )
      Iyi::IyiMod.write artifact, path

      read = Iyi::IyiMod.read(path).hashes
      read.interface.should eq "iface"
      read.implementation.should eq "impl"
      read.source.should eq "src"
    end
  end

  # The property IV.3 exists for, and the one that decides whether the artifact
  # buys anything: **a body edit must not move the interface hash.** If it does,
  # every dependent re-typechecks for every edit and an incremental build is a
  # slower first build.
  it "moves the interface hash for a signature and not for a body" do
    with_tempdir("iyimod_hashes") do
      Dir.mkdir_p "app"
      File.write "main.iyi", <<-IYI
        module main

        import app/box

        puts App::Box.twice(21)
        IYI
      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      write_box = ->(body : String, extra : String) do
        File.write "app/box.iyi", <<-IYI
          module app/box

          pub def twice(n : Int32) : Int32
            #{body}
          end
          #{extra}
          IYI
      end

      emit = -> do
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.emit_iyimod = "mods"
        compiler.no_codegen = true
        compiler.compile source, "unused"
        Iyi::IyiMod.read(File.join("mods", "app", "box.iyimod")).hashes
      end

      write_box.call("n + n", "")
      before = emit.call

      # The same module, one body written differently.
      write_box.call("n * 2", "")
      after_body = emit.call

      after_body.interface.should eq before.interface
      after_body.implementation.should eq before.implementation
      after_body.source.should_not eq before.source

      # And a name added to the surface, which every dependent does have to
      # hear about.
      write_box.call("n * 2", <<-IYI)

        pub def thrice(n : Int32) : Int32
          n * 3
        end
        IYI
      after_signature = emit.call

      after_signature.interface.should_not eq after_body.interface
    end
  end

  # An artifact is a cache, so it is read only while it still describes its
  # module. Before the hashes it was read whichever way the source had moved,
  # and a build could compile against a surface nobody had and link code
  # nobody wrote — silently, with an exit status of nought.
  it "reads an artifact only while it still describes its module" do
    with_tempdir("iyimod_stale") do
      Dir.mkdir_p "app"
      File.write "main.iyi", <<-IYI
        module main

        import app/box

        puts App::Box.twice(21)
        IYI
      File.write "app/box.iyi", <<-IYI
        module app/box

        pub def twice(n : Int32) : Int32
          n + n
        end
        IYI
      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "42"

      File.write "app/box.iyi", <<-IYI
        module app/box

        pub def twice(n : Int32) : Int32
          n * 3
        end
        IYI

      # A build that only reads artifacts is refused, and told what moved.
      reader = create_spec_compiler
      reader.prelude = "iyi/prelude"
      reader.use_iyimod = "mods"
      expect_raises(Iyi::TypeException, /has changed since it was written/) do
        reader.compile source, File.expand_path("stale")
      end

      # A build that also writes them is the incremental loop: the module is
      # compiled from its source and its artifact rewritten.
      rewriter = create_spec_compiler
      rewriter.prelude = "iyi/prelude"
      rewriter.use_iyimod = "mods"
      rewriter.emit_iyimod = "mods"
      rewriter.compile source, File.expand_path("rebuilt")
      `./rebuilt`.chomp.should eq "63"

      # And what it wrote is read again without a word.
      again = create_spec_compiler
      again.prelude = "iyi/prelude"
      again.use_iyimod = "mods"
      again.compile source, File.expand_path("cached")
      `./cached`.chomp.should eq "63"
    end
  end

  # A module path is a file path (R-1), so the same name can come to mean a
  # different file: `src/std/` ships a `std/text`, and a program with one of
  # its own that deletes it finds the library's at that path. The artifact is
  # then not stale — it is about a file nobody asked for — and saying
  # "src/std/text.iyi has changed since it was written" named a library file
  # the author has never opened.
  it "names a module whose path reaches another file now" do
    with_tempdir("iyimod_moved_name") do
      Dir.mkdir_p "std"
      File.write "std/text.iyi", <<-IYI
        module std/text

        pub def mine : Int32
          7
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import std/text
        using std/text::{mine}

        puts mine
        IYI
      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "7"

      File.delete "std/text.iyi"

      reader = create_spec_compiler
      reader.prelude = "iyi/prelude"
      reader.use_iyimod = "mods"
      # The module path is posix by grammar (R-1); the *file* it named is
      # printed the way this platform writes a path, so the expectation asks
      # for the file by its own separator rather than by a literal slash.
      moved = Regex.escape(File.join("std", "text.iyi"))
      expect_raises(Iyi::TypeException, /"std\/text" is .+ now, and this was written from .+#{moved}/) do
        reader.compile source, File.expand_path("moved")
      end
    end
  end

  # An artifact records the module it was written for, and nothing compared that
  # to the module being imported. A `.iyimod` copied onto another module's path
  # was adopted: its declarations were spliced in under its own name, and the
  # module actually asked for stayed undefined. The failure surfaced at the
  # first `using` as "can't find module 'm1/a'", which sends the reader off to
  # write `m1/a.iyi` when the file was there, valid, and already read.
  it "refuses an artifact that declares a different module" do
    with_tempdir("iyimod_module_name") do
      Dir.mkdir_p "m1"
      File.write "m1/a.iyi", <<-IYI
        module m1/a

        pub def v : Int32
          1
        end
        IYI
      File.write "m1/b.iyi", <<-IYI
        module m1/b

        pub def v : Int32
          2
        end
        IYI
      File.write "usea.iyi", <<-IYI
        module usea

        import m1/a
        using m1/a

        puts v
        IYI
      File.write "useb.iyi", <<-IYI
        module useb

        import m1/b
        using m1/b

        puts v
        IYI
      source = Iyi::Compiler::Source.new(File.expand_path("usea.iyi"), File.read("usea.iyi"))

      # Both artifacts, each written for the module it names.
      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-a")
      `./from-a`.chomp.should eq "1"

      other = Iyi::Compiler::Source.new(File.expand_path("useb.iyi"), File.read("useb.iyi"))
      producer_b = create_spec_compiler
      producer_b.prelude = "iyi/prelude"
      producer_b.emit_iyimod = "mods"
      producer_b.compile other, File.expand_path("from-b")
      `./from-b`.chomp.should eq "2"

      # The sources go away, so the artifacts are all there is. That is what
      # puts the mismatch beyond reach of every other check: with `m1/a.iyi`
      # present, the source hash catches the wrong file and blames the source
      # for having changed, which is a misdiagnosis of its own.
      Dir.mkdir_p "away"
      File.rename "m1", File.join("away", "m1")

      # `m1/b`'s artifact under `m1/a`'s name. Every checksum in it is intact and
      # the only thing wrong with it is which module it is.
      File.copy File.join("mods", "m1", "b.iyimod"), File.join("mods", "m1", "a.iyimod")

      reader = create_spec_compiler
      reader.prelude = "iyi/prelude"
      reader.use_iyimod = "mods"
      ex = expect_raises(Iyi::TypeException, /declares module "m1\/b", not "m1\/a"/) do
        reader.compile source, File.expand_path("mismatched")
      end

      # The file, so the reader knows which one to go and look at.
      ex.message.to_s.should contain File.join("mods", "m1", "a.iyimod")

      # At the `import`, which is where the artifact is read, and not at the
      # `using` on the next line where the old misdiagnosis landed.
      ex.line_number.should eq 3
      ex.message.to_s.should_not match(/can't find module/)

      # A build that also writes artifacts repairs it once the source is back:
      # the module is compiled from it and the wrong file written over.
      File.rename File.join("away", "m1"), "m1"
      rewriter = create_spec_compiler
      rewriter.prelude = "iyi/prelude"
      rewriter.use_iyimod = "mods"
      rewriter.emit_iyimod = "mods"
      rewriter.compile source, File.expand_path("repaired")
      `./repaired`.chomp.should eq "1"
      Iyi::IyiMod.read_summary(File.join("mods", "m1", "a.iyimod"))
        .module_name.should eq "m1/a"

      # And what it wrote is read again without a word.
      again = create_spec_compiler
      again.prelude = "iyi/prelude"
      again.use_iyimod = "mods"
      again.compile source, File.expand_path("cached")
      `./cached`.chomp.should eq "1"
    end
  end

  # IV.3's whole point, in the shape that shows it: two programs over one graph,
  # so that a dependency can be rebuilt while a dependent is not touched. A body
  # edit under `app/outer` must leave its artifact valid; a surface edit must
  # not.
  it "keeps a dependent whose dependency changed only a body" do
    with_tempdir("iyimod_interface_hash") do
      Dir.mkdir_p "app"
      File.write "main.iyi", <<-IYI
        module main

        import app/outer

        puts App::Outer.outer
        IYI
      File.write "leaf.iyi", <<-IYI
        module leaf

        import app/inner

        puts App::Inner.inner
        IYI
      File.write "app/outer.iyi", <<-IYI
        module app/outer

        import app/inner

        pub def outer : Int32
          App::Inner.inner + 41
        end
        IYI
      write_inner = ->(body : String, extra : String) do
        File.write "app/inner.iyi", <<-IYI
          module app/inner

          pub def inner : Int32
            #{body}
          end
          #{extra}
          IYI
      end

      main = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
      leaf = Iyi::Compiler::Source.new(File.expand_path("leaf.iyi"), File.read("leaf.iyi"))

      build = ->(program : Iyi::Compiler::Source, output : String, emit : Bool) do
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.use_iyimod = "mods"
        compiler.emit_iyimod = "mods" if emit
        compiler.compile program, File.expand_path(output)
      end

      write_inner.call("1", "")
      build.call(main, "first", true)
      `./first`.chomp.should eq "42"

      # The other program rewrites `app/inner`'s artifact and leaves
      # `app/outer`'s where it was.
      write_inner.call("2", "")
      build.call(leaf, "leaf-build", true)

      # So `app/outer` is read from its artifact: the module it was compiled
      # against hashes the same on its surface, and its new body arrives as
      # machine code through the linker.
      build.call(main, "kept", false)
      `./kept`.chomp.should eq "43"

      # A name added to that surface is a different matter.
      write_inner.call("2", <<-IYI)

        pub def other : Int32
          3
        end
        IYI
      build.call(leaf, "leaf-again", true)

      expect_raises(Iyi::TypeException, /the surface of "app\/inner"/) do
        build.call(main, "invalidated", false)
      end
    end
  end

  it "round-trips the types a module numbers" do
    with_temporary_file do |path|
      artifact = Iyi::IyiMod::Artifact.new(
        module_name: "app/box",
        source_path: "/src/app/box.iyi",
        compiler_version: "1.22.0-dev+abc1234",
        target_triple: "x86_64-pc-linux-gnu",
        flags: ["bits64"],
        imports: [] of Iyi::IyiMod::ImportEdge,
        type_ids: ["Array(App::Box::Item)", "Pointer(App::Box::Item)"],
      )
      Iyi::IyiMod.write artifact, path

      Iyi::IyiMod.read(path).type_ids.should eq ["Array(App::Box::Item)", "Pointer(App::Box::Item)"]
    end
  end
  # GC_DESIGN.md Stage 1: the pointer maps. The container examples check the
  # encoding and the refusals; the compiling example is the one that proves
  # the pass, because it asserts the offsets against the layout the compiler
  # itself computed rather than against numbers typed from memory.
  describe "layouts" do
    it "round-trips them" do
      layouts = [
        {"App::Shapes::Point", Iyi::IyiMod::TypeLayout.new(41, 8_u32, 8_u32, [] of UInt32, [] of UInt32)},
        {"App::Shapes::Labelled", Iyi::IyiMod::TypeLayout.new(8, 40_u32, 36_u32, [8_u32, 24_u32], [] of UInt32)},
      ]
      with_temporary_file do |path|
        Iyi::IyiMod.write sample_artifact(layouts: layouts), path
        Iyi::IyiMod.read(path).layouts.should eq layouts
      end
    end

    it "is refused when its bytes changed under it, like every other section" do
      with_temporary_file do |path|
        # With no object code after it, the layouts payload is the last bytes
        # of the file, so the last byte is this section's own.
        Iyi::IyiMod.write sample_artifact(layouts: [
          {"App::Shapes::Labelled", Iyi::IyiMod::TypeLayout.new(8, 40_u32, 36_u32, [8_u32, 24_u32], [] of UInt32)},
        ]), path
        bytes = File.read(path).to_slice.dup
        bytes[bytes.size - 1] ^= 0xFF_u8
        File.write(path, bytes)

        expect_raises(Iyi::IyiMod::Error, /the Layouts section is damaged/) do
          Iyi::IyiMod.read(path)
        end
      end
    end

    it "shows them in mod dump, in a form to check against the struct as written" do
      io = IO::Memory.new
      Iyi::IyiMod.dump sample_artifact(layouts: [
        {"App::Shapes::Labelled", Iyi::IyiMod::TypeLayout.new(8, 40_u32, 36_u32, [8_u32, 24_u32], [] of UInt32)},
      ]), io
      text = io.to_s

      text.should contain "layouts"
      text.should contain "App::Shapes::Labelled: type id 8, 40 bytes (scan cap 36), scan [8, 24], noscan []"
    end

    it "computes the offsets from the emitted struct, not from field sizes added up" do
      with_tempdir("iyimod_layouts") do
        Dir.mkdir_p "app"
        File.write "app/shapes.iyi", <<-IYI
          module app/shapes

          pub struct Point
            @x : Int32
            @y : Int32

            def initialize(@x : Int32, @y : Int32)
            end
          end

          pub struct Inner
            @ref : String
            @n : Int32

            def initialize(@ref : String, @n : Int32)
            end
          end

          pub struct Outer
            @inner : Inner
            @flag : Bool

            def initialize(@inner : Inner, @flag : Bool)
            end
          end

          pub class Labelled
            @name : String
            @point : Point
            @tags : Array(String)
            @count : Int32

            def initialize(@name : String, @point : Point, @tags : Array(String), @count : Int32)
            end
          end

          pub class Base
            @id : Int64
            @owner : String

            def initialize(@id : Int64, @owner : String)
            end
          end

          pub class Derived < Base
            @extra : String

            def initialize(id : Int64, owner : String, @extra : String)
              super(id, owner)
            end
          end

          pub struct Box(T)
            @value : T

            def initialize(@value : T)
            end
          end

          pub struct Unused(T)
            @value : T

            def initialize(@value : T)
            end
          end

          pub def make(name : String) : Labelled
            Box(String).new("packed")
            Labelled.new(name, Point.new(1, 2), ["t"], 3)
          end
          IYI
        File.write "main.iyi", <<-IYI
          module main

          import app/shapes

          App::Shapes.make("hi")
          puts "ok"
          IYI

        captured = nil
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.emit_iyimod = "mods"
        source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
        compiler.compile_configure_program(source, File.expand_path("from-source")) do |program|
          captured = program
        end
        `./from-source`.chomp.should eq "ok"

        program = captured.not_nil!
        artifact = Iyi::IyiMod.read(File.join("mods", "app", "shapes.iyimod"))
        shapes = program.types["App"].types["Shapes"]

        # The layout the compiler computed, asked the way `offsetof` asks it.
        # An assertion against numbers typed from memory would prove nothing:
        # the padding in these types is the target's decision.
        offset_of = ->(type : Iyi::Type, name : String) do
          index = type.index_of_instance_var(name).not_nil!
          if type.struct?
            program.offset_of(type, index)
          else
            program.instance_offset_of(type, index)
          end
        end
        layout_of = ->(name : String) do
          entry = artifact.layouts.find { |(candidate, _)| candidate == name }
          entry.should_not be_nil
          entry.not_nil![1]
        end

        # A type with no pointer fields is present with an empty map, not
        # absent: absent means "no layout, scan conservatively" to a
        # collector, and this type has a layout with nothing to scan.
        point = shapes.types["Point"]
        point_layout = layout_of.call("App::Shapes::Point")
        point_layout.scan_offsets.should eq [] of UInt32
        point_layout.alloc_size.should eq program.instance_size_of(point).to_u32

        inner = shapes.types["Inner"]
        inner_layout = layout_of.call("App::Shapes::Inner")
        inner_layout.scan_offsets.should eq [offset_of.call(inner, "@ref").to_u32]
        inner_layout.alloc_size.should eq program.instance_size_of(inner).to_u32
        # The scan cap is the end of the last field, before tail padding.
        expected_cap = offset_of.call(inner, "@n") + program.size_of(program.int32)
        inner_layout.scan_cap.should eq expected_cap.to_u32

        # A struct field is stored inline, so its pointer words flatten into
        # the containing map: Outer's is where `@inner` sits plus where
        # `@ref` sits inside an Inner.
        outer = shapes.types["Outer"]
        outer_layout = layout_of.call("App::Shapes::Outer")
        outer_layout.scan_offsets.should eq [
          (offset_of.call(outer, "@inner") + offset_of.call(inner, "@ref")).to_u16,
        ]

        # A class carries its type id under the object, not in it, so its
        # first field is at 0; `@point` has no inner pointers and `@count`
        # is a scalar, so neither is here.
        labelled = shapes.types["Labelled"]
        labelled_layout = layout_of.call("App::Shapes::Labelled")
        labelled_layout.scan_offsets.should eq [
          offset_of.call(labelled, "@name").to_u16,
          offset_of.call(labelled, "@tags").to_u16,
        ]
        labelled_layout.alloc_size.should eq program.instance_size_of(labelled).to_u32

        # An inherited pointer field is in the subclass's own map, at the
        # offset the subclass's struct gives it.
        derived = shapes.types["Derived"]
        derived_layout = layout_of.call("App::Shapes::Derived")
        derived_layout.scan_offsets.should eq [
          offset_of.call(derived, "@owner").to_u16,
          offset_of.call(derived, "@extra").to_u16,
        ]

        # A generic the module owns contributes each instantiation this build
        # has, under the instantiation's own name; one it never instantiated
        # contributes nothing, because R-4's per-GC-shape keying does not
        # exist yet to give `Unused(T)` a shape of its own.
        box = shapes.types["Box"].as(Iyi::GenericType).instantiated_types
          .find { |instance| instance.to_s == "App::Shapes::Box(String)" }.not_nil!
        box_layout = layout_of.call("App::Shapes::Box(String)")
        box_layout.scan_offsets.should eq [offset_of.call(box, "@value").to_u32]
        artifact.layouts.find { |(name, _)| name.includes?("Unused") }.should be_nil

        # Empty everywhere, on purpose: what noscan means is Stage 6's to say.
        artifact.layouts.each do |(_, layout)|
          layout.noscan_offsets.should be_empty
          layout.type_id.should be > 0
        end
      end
    end
  end

  # An artifact with every declaration and no machine code is not the same
  # thing as one that legitimately has none: an `abstract class` with no
  # subclass in its own shard carries no object code and is complete, while a
  # boundary whose fill build died carries none and promises everything. Read as
  # it stands the second is a hundred undefined symbols with the cause named
  # nowhere.
  it "refuses a boundary whose object-code step never finished" do
    with_tempdir("iyimod_unfilled") do
      Dir.mkdir_p "app"
      File.write "app/counter.iyi", <<-IYI
        module app/counter

        pub def total : Int32
          42
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/counter

        puts App::Counter.total
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")

      # Written back as the fill step would have left it had the build died:
      # everything it declares, and no record of having finished.
      path = File.join("mods", "app", "counter.iyimod")
      artifact = Iyi::IyiMod.read(path, want_object_code: true)
      artifact.filled.should be_true
      artifact.filled = false
      Iyi::IyiMod.write artifact, path

      File.delete "app/counter.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      expect_raises(Iyi::TypeException, /was never filled/) do
        consumer.compile source, File.expand_path("from-artifact")
      end
    end
  end

  # The flag beside the name, because the consumer cannot work it out. A unit
  # that reads a class variable with a live initialiser calls
  # `~Owner::name:read`; one reading a variable without an initialiser reads the
  # global. Assume the first and an iyi-prelude program dies on
  # `BUG: __crystal_once is not defined`; assume the second and a `--crystal`
  # build leaves `~Exception::CallStack::skip:read` undefined.
  # Two of them share a *name* and differ only in their owner, and that is the
  # case this list was once unable to hold: the bookkeeping behind it was keyed
  # on the variable, `MetaTypeVar` is a `Var`, and a `Var`'s equality is its
  # name. A class variable declared on a superclass is copied onto every
  # subclass that reads one, so `bindata`'s `@@bit_fields` is six variables and
  # was one key — the last write took the entry and the link ended on
  # `~ASN1::BER::bit_fields:read`.
  #
  # `Requires` says what a consumer has to have compiled and this says what it
  # has to have linked against, and the consumer cannot derive one from the
  # other: it replays `require "yaml"`, so it *has* `lib LibYAML` and its
  # `@[Link("yaml")]`, and drops the flag anyway — a flag is collected from the
  # libs that build marked `used?`, and the call to `yaml_parser_parse` is in
  # an object file it reads rather than compiles.
  # A redefinition and the definition it replaced are two bodies under one
  # signature, and `previous_def` is how the second reaches the first. `db`
  # writes a macro that redefines `around_query_or_exec` that way, and keyed on
  # the signature alone the second body took the first's place.
  it "tells a redefinition's body from the one it replaced" do
    signature = Iyi::IyiMod::Signature.new(
      name: "around_query_or_exec", receiver: "", parameters: ["args : Enumerable"],
      block_parameter: "&", return_type: "",
      free_variables: [] of String, required: false,
    )

    first = Iyi::IyiMod.mono_body_key("DB::Statement", signature, 0)
    second = Iyi::IyiMod.mono_body_key("DB::Statement", signature, 1)
    first.should_not eq second

    # And both sides count the same way, which is what makes a position a name.
    Iyi::IyiMod.mono_body_ordinals([signature, signature]).should eq [0, 1]
  end

  # An instance method and a class method of the same name and parameters are
  # two methods, and the key that finds a body again was missing the only thing
  # that tells them apart. `Log` has a `{% for %}` loop writing `def info(*,
  # exception : Exception)` on the instance and another writing `def self.info`
  # with the same parameters on the class; the second took the first's key, and
  # a consumer read `Log#info` as `Log#info` calling itself.
  it "tells a class method's body from an instance method's" do
    instance = Iyi::IyiMod::Signature.new(
      name: "info", receiver: "", parameters: ["exception : Exception"],
      block_parameter: "", return_type: "Nil",
      free_variables: [] of String, required: false,
    )
    on_class = instance.copy_with(receiver: "self")

    Iyi::IyiMod.mono_body_key("Log", instance)
      .should_not eq Iyi::IyiMod.mono_body_key("Log", on_class)
  end

  it "round-trips the libs a module's object code calls into" do
    with_temporary_file do |path|
      artifact = Iyi::IyiMod::Artifact.new(
        module_name: "y_a_m_l",
        source_path: "/src/probe.cr",
        compiler_version: "1.22.0-dev+abc1234",
        target_triple: "x86_64-pc-linux-gnu",
        flags: ["bits64"],
        imports: [] of Iyi::IyiMod::ImportEdge,
      )
      artifact.libs = ["LibC", "LibYAML"]
      Iyi::IyiMod.write artifact, path

      Iyi::IyiMod.read(path).libs.should eq ["LibC", "LibYAML"]
    end
  end

  it "round-trips how a unit refers to a class variable" do
    with_temporary_file do |path|
      artifact = Iyi::IyiMod::Artifact.new(
        module_name: "app/box",
        source_path: "/src/app/box.iyi",
        compiler_version: "1.22.0-dev+abc1234",
        target_triple: "x86_64-pc-linux-gnu",
        flags: ["bits64"],
        imports: [] of Iyi::IyiMod::ImportEdge,
        class_vars: [
          Iyi::IyiMod::ClassVarRef.new("App::Box::Store::@@cache", false),
          Iyi::IyiMod::ClassVarRef.new("App::Box::Crate::@@cache", false),
          Iyi::IyiMod::ClassVarRef.new("Exception::CallStack::@@skip", true),
        ],
      )
      Iyi::IyiMod.write artifact, path

      read = Iyi::IyiMod.read(path).class_vars
      read.map(&.name).should eq ["App::Box::Store::@@cache",
                                  "App::Box::Crate::@@cache",
                                  "Exception::CallStack::@@skip"]
      read.map(&.lazy).should eq [false, false, true]
    end
  end

  # The pattern and not just the name, because the name is a digest of the
  # pattern and a digest does not read backwards. `Constants` carries a name
  # because for every other constant a name is enough — the consumer's own
  # library has it, or the module's initialiser assigns it. Nobody wrote this
  # one and `$` keeps it out of the source channel, so what a consumer needs to
  # build it travels here or nowhere.
  it "round-trips what a synthesised regex constant was made from" do
    with_temporary_file do |path|
      artifact = Iyi::IyiMod::Artifact.new(
        module_name: "app/box",
        source_path: "/src/app/box.cr",
        compiler_version: "1.22.0-dev+abc1234",
        target_triple: "x86_64-pc-linux-gnu",
        flags: ["bits64"],
        imports: [] of Iyi::IyiMod::ImportEdge,
        constants: ["$Regex:0efd0f2ede78a843db3048bc8d79fcff"],
        regexes: [Iyi::IyiMod::RegexConst.new("$Regex:0efd0f2ede78a843db3048bc8d79fcff",
          "alpha-[0-9]+", 1_u32)],
      )
      Iyi::IyiMod.write artifact, path

      read = Iyi::IyiMod.read(path).regexes
      read.size.should eq 1
      read[0].name.should eq "$Regex:0efd0f2ede78a843db3048bc8d79fcff"
      read[0].pattern.should eq "alpha-[0-9]+"
      read[0].options.should eq 1_u32
    end
  end

  # Same pattern, same name, in a program that never met the other one — which
  # is the whole of what the digest is for. Two boundaries numbering their own
  # literals from zero both said `$Regex:0`, and a consumer holding both can
  # only define one: the second module's machine code read the first module's
  # pattern, with nothing raised and nothing linked wrong.
  it "names a regex constant after the literal rather than the order it was met in" do
    alpha = Iyi::Program.regex_const_name("alpha-[0-9]+", Iyi::RegexOptions::None)
    beta = Iyi::Program.regex_const_name("beta-[a-z]+", Iyi::RegexOptions::None)

    alpha.should_not eq beta
    alpha.should eq Iyi::Program.regex_const_name("alpha-[0-9]+", Iyi::RegexOptions::None)

    # The flags are part of what the literal means, so they are part of its
    # name: `/a/i` and `/a/` are two patterns and must not share one constant.
    Iyi::Program.regex_const_name("a", Iyi::RegexOptions::IGNORE_CASE)
      .should_not eq Iyi::Program.regex_const_name("a", Iyi::RegexOptions::None)

    # Unwritable, which the old name already was and this one has to keep: the
    # consumer defines it, and a name a consumer could also *write* would be a
    # constant two things own.
    alpha.should start_with "$Regex:"
  end

  it "renders the initialiser inside the module it belongs to" do
    artifact = Iyi::IyiMod::Artifact.new(
      module_name: "boot/config",
      source_path: "/src/boot/config.iyi",
      compiler_version: "1.22.0-dev+abc1234",
      target_triple: "x86_64-pc-linux-gnu",
      flags: [] of String,
      imports: [] of Iyi::IyiMod::ImportEdge,
      initialiser: %(puts("hello")),
    )

    io = IO::Memory.new
    Iyi::IyiMod.declarations artifact, io
    text = io.to_s

    text.should start_with "module boot/config\n"
    text.should contain %(puts("hello"))
  end

  # A consumer allocates the type, and allocating needs its size. Without the
  # fields it read `pub struct Box` as a struct with none, and generated a
  # `Box::new` that allocated nothing while the module's own code wrote to
  # `@n` — memory corruption waiting for the rest of `ObjectCode` to stop
  # failing at link, rather than a missing feature.
  it "carries a type's fields" do
    with_tempdir("iyimod_fields") do
      Dir.mkdir_p "std"
      File.write "std/box.iyi", <<-IYI
        module std/box

        pub struct Box(T)
          @item : T
          @count : Int32

          def initialize(@item : T)
            @count = 1
          end

          def item : T
            @item
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import std/box

        puts Std::Box::Box(Int32).new(7).item
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.no_codegen = true
      producer.compile source, File.expand_path("unused")

      declaration = Iyi::IyiMod.read(File.join("mods", "std", "box.iyimod"))
        .exports.types.find! { |candidate| candidate.name == "Box" }

      # In the order they were declared, because that order is the layout: a
      # field's offset is its position in this list, and a consumer compiling a
      # body of this module's has to reach the same field the module's own
      # object code does.
      declaration.fields.should eq [{"@item", "T", ""}, {"@count", "Int32", ""}]
    end
  end

  # SPEC.md III.4.4: the `Share` marker travels with the declaration. A
  # producer writes `@[Share]` above every type it found shareable, and a
  # consumer reads that — never recomputing, because the bodies that said
  # no method assigns a field are not in the artifact — and gates the block
  # `IyiThread.start` runs on another thread by it (III.4.11).
  it "carries a type's Share marker, and a consumer's thread reads it" do
    with_tempdir("iyimod_share") do
      Dir.mkdir_p "std"
      File.write "std/pair.iyi", <<-IYI
        module std/pair

        pub struct Pair
          @left : Int32
          @right : Int32

          def initialize(@left : Int32, @right : Int32)
          end

          def left : Int32
            @left
          end
        end

        pub class Counter
          @count : Int32

          def initialize
            @count = 0
          end

          def bump : Nil
            @count = 1
          end

          def count : Int32
            @count
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import std/pair

        pair = Std::Pair::Pair.new(1, 2)
        t = IyiThread.start do
          pair.left
          nil
        end
        t.join
        puts pair.left
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.no_codegen = true
      producer.compile source, File.expand_path("unused")

      types = Iyi::IyiMod.read(File.join("mods", "std", "pair.iyimod")).exports.types
      types.find! { |candidate| candidate.name == "Pair" }.annotations.should eq ["@[Share]"]
      types.find! { |candidate| candidate.name == "Counter" }.annotations.should eq [] of String

      File.delete "std/pair.iyi"

      # The shareable one crosses a thread from the artifact alone.
      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.no_codegen = true
      consumer.compile source, File.expand_path("unused")

      # The other is refused with the artifact as the reason: the consumer
      # cannot see `bump`, and does not pretend to.
      File.write "main.iyi", <<-IYI
        module main

        import std/pair

        counter = Std::Pair::Counter.new
        t = IyiThread.start do
          counter.count
          nil
        end
        t.join
        IYI
      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
      refusing = create_spec_compiler
      refusing.prelude = "iyi/prelude"
      refusing.use_iyimod = "mods"
      refusing.no_codegen = true
      expect_raises(Iyi::TypeException, /captures `counter : Std::Pair::Counter`, which is not Share: Std::Pair::Counter came from an artifact whose producer did not find it shareable/) do
        refusing.compile source, File.expand_path("unused")
      end
    end
  end

  it "renders a type's fields into the declarations a consumer reads" do
    declaration = type_declaration("List", "generic struct",
      type_parameters: ["T"],
      fields: [{"@items", "Array(T)", ""}],
      methods: [signature("size", return_type: "Int32")])

    io = IO::Memory.new
    Iyi::IyiMod.declarations sample_artifact(types: [declaration]), io

    io.to_s.should contain "pub struct List(T)\n  @items : Array(T)\n"
  end

  # The other half of the rule above, and the half that went wrong three times.
  # A module whose top level is only declarations has no initialiser — and the
  # declarations do not look like declarations from the outside: the file is
  # wrapped in a `ModuleDef`, `pub struct` is a `VisibilityModifier` around one,
  # and `type Elem = T` is an `AssocTypeDecl`. Each of those, taken for
  # something that runs, refused a module that was fine.
  it "does not mistake declarations for an initialiser" do
    with_tempdir("iyimod_no_initialiser") do
      Dir.mkdir_p "std"
      File.write "std/hold.iyi", <<-IYI
        module std/hold

        pub trait Hold
          type Item

          abstract def item : Item
        end

        pub struct Box
          @n : Int32

          def initialize(@n : Int32)
          end
        end

        impl Hold for Box
          type Item = Int32

          def item : Int32
            @n
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import std/hold

        using std/hold::{Hold}

        puts Std::Hold::Box.new(7).item
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")

      Iyi::IyiMod.read(File.join("mods", "std", "hold.iyimod")).has_initialiser.should be_false
    end
  end

  # A macro call is not code until it is expanded, and what a module's macros
  # expand to is mostly declarations. Reading the call itself made every module
  # that writes a `getter` read as having code in a type body and refused it,
  # which is the ordinary shape of a library rather than a corner of one.
  it "does not mistake a macro call in a type body for an initialiser" do
    with_tempdir("iyimod_macro_declarations") do
      Dir.mkdir_p "app"
      File.write "app/store.iyi", <<-IYI
        module app/store

        pub struct Item
          getter name : String
          getter price : Int32

          def initialize(@name : String, @price : Int32)
          end
        end

        pub class Store
          private record Entry,
            item : Item,
            count : Int32

          @entries : Array(Entry)

          def initialize
            @entries = Array(Entry).new
          end

          pub def add(name : String, price : Int32, count : Int32) : Nil
            @entries << Entry.new(Item.new(name, price), count)
          end

          pub def total : Int32
            sum = 0
            @entries.each { |entry| sum = sum + entry.item.price * entry.count }
            sum
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/store

        store = App::Store::Store.new
        store.add("a", 3, 2)
        store.add("b", 5, 1)
        puts store.total
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq "11"

      Iyi::IyiMod.read(File.join("mods", "app", "store.iyimod")).has_initialiser.should be_false

      File.delete "app/store.iyi"

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "11"
    end
  end

  # And the other direction, which is what makes following the expansion safe:
  # a macro that expands to something that has to *run* is still code in a type
  # body, and a build that would generate against it is still refused.
  it "sees the code a macro expands to in a type body" do
    with_tempdir("iyimod_macro_code") do
      Dir.mkdir_p "app"
      File.write "app/thing.iyi", <<-IYI
        module app/thing

        pub class Thing
          {% for word in ["one"] %}
            puts {{ word }}
          {% end %}

          pub def n : Int32
            1
          end
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/thing

        puts App::Thing::Thing.new.n
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")

      Iyi::IyiMod.read(File.join("mods", "app", "thing.iyimod")).has_initialiser.should be_true

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      expect_raises(Iyi::TypeException, /has code inside a type body/) do
        consumer.compile source, File.expand_path("from-artifact")
      end
    end
  end

  # A build that generates no code has none to carry. Checked because the two
  # cases are told apart by the flag the build was given and by nothing in the
  # file, so an empty section here is the honest answer rather than a failure
  # to collect.
  it "carries no object code from a --no-codegen build" do
    with_tempdir("iyimod_no_codegen") do
      Dir.mkdir_p "app"
      File.write "app/greeter.iyi", <<-IYI
        module app/greeter

        pub def polite(name : String) : String
          "Hello, " + name
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/greeter

        puts App::Greeter.polite("world")
        IYI

      compiler = create_spec_compiler
      compiler.prelude = "iyi/prelude"
      compiler.emit_iyimod = "mods"
      compiler.no_codegen = true

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
      compiler.compile source, "unused"

      artifact = Iyi::IyiMod.read(File.join("mods", "app", "greeter.iyimod"),
        want_object_code: true)
      artifact.object_code.should be_empty
      artifact.exports.functions.map(&.name).should eq ["polite"]
    end
  end

  # An edge names a module, and it has to name one whichever way the module on
  # the far end arrived. The edges are kept by filename because load-once is,
  # so writing one out means looking the filename back up — and the lookup used
  # to ask only the modules read from source, which left an import resolved
  # from a `.iyimod` recorded as that file's path. `mods/app/inner.iyimod` is
  # this build's directory layout, not a module anybody else can resolve.
  it "records an import read from an artifact as the module it is" do
    with_tempdir("iyimod_artifact_edge") do
      Dir.mkdir_p "app"
      File.write "app/inner.iyi", <<-IYI
        module app/inner

        pub def inner : Int32
          1
        end
        IYI
      File.write "app/outer.iyi", <<-IYI
        module app/outer

        import app/inner

        pub def outer : Int32
          App::Inner.inner
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/outer

        puts App::Outer.outer
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.no_codegen = true
      producer.compile source, "unused"

      # Only the leaf keeps its artifact, so the second build reads `app/inner`
      # from a `.iyimod` and `app/outer` from source — which is the shape an
      # incremental build has, and the only one where the edge is written by a
      # module whose dependency did not come from source.
      File.delete File.join("mods", "app", "outer.iyimod")

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"
      consumer.emit_iyimod = "out"
      consumer.no_codegen = true
      consumer.compile source, "unused"

      artifact = Iyi::IyiMod.read(File.join("out", "app", "outer.iyimod"))
      artifact.import_names.should eq ["app/inner"]
    end
  end

  it "round-trips exported types with their parameters and methods" do
    declaration = type_declaration("List", "generic struct",
      type_parameters: ["T"],
      methods: [signature("at", ["index : Int32"], "T")])

    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact(types: [declaration]), path
      read = Iyi::IyiMod.read(path).exports.types

      read.size.should eq 1
      read[0].name.should eq "List"
      read[0].kind.should eq "generic struct"
      read[0].type_parameters.should eq ["T"]
      read[0].methods.map(&.name).should eq ["at"]
    end
  end

  # II.4 depends on this record: it is what lets a consumer answer "does
  # `Customer` implement `ToJSON`?" without reading `Customer`.
  it "round-trips impl records" do
    impls = [
      impl_record("Std::Traits::Cmp", "Int32"),
      impl_record("Std::Enumerable::Enumerable", "Std::List::List(T)",
        free_variables: ["T"], assoc_types: [{"Elem", "T"}]),
    ]

    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact(impls: impls), path
      read = Iyi::IyiMod.read(path).exports.impls

      read.map(&.trait_name).should eq ["Std::Traits::Cmp", "Std::Enumerable::Enumerable"]
      read.map(&.type_name).should eq ["Int32", "Std::List::List(T)"]
      read[1].free_variables.should eq ["T"]
      read[1].assoc_types.should eq [{"Elem", "T"}]
    end
  end

  # A constructor's result is its type and nobody writes it down, so an absent
  # return type is recorded as absent rather than filled in with a guess.
  it "renders a signature with no return annotation without one" do
    io = IO::Memory.new
    Iyi::IyiMod.dump sample_artifact(exports: [
      signature("initialize", ["items : Array(T)"]),
    ]), io

    io.to_s.should contain "  def initialize(items : Array(T))\n"
  end

  it "dumps a type declaration and an impl" do
    io = IO::Memory.new
    Iyi::IyiMod.dump sample_artifact(
      types: [type_declaration("Greet", "trait",
        methods: [signature("greet", return_type: "String")])],
      impls: [impl_record("Greet", "User")],
    ), io
    text = io.to_s

    # With its visibility, because "carried and unreachable" is a thing a
    # reader of this file has to be able to tell from "carried and exported".
    text.should contain "  pub trait Greet"
    text.should contain "    def greet : String"
    text.should contain "  impl Greet for User"
  end

  # II.6 keeps a trait's parameters and its associated types apart — the first
  # is supplied at the `impl` line and the second is answered in its body — so
  # an artifact that merged them would ask for `Elem` in the one place II.6
  # says it does not go.
  it "round-trips a trait's parameters, associated types and supertraits" do
    declaration = type_declaration("Enumerable", "generic trait",
      type_parameters: ["K"],
      assoc_types: ["Elem"],
      supertraits: ["Std::Traits::Cmp"],
      methods: [signature("each", return_type: "Nil",
        block_parameter: "& : (Elem -> Nil)", required: true)])

    with_temporary_file do |path|
      Iyi::IyiMod.write sample_artifact(types: [declaration]), path
      read = Iyi::IyiMod.read(path).exports.types[0]

      read.type_parameters.should eq ["K"]
      read.assoc_types.should eq ["Elem"]
      read.supertraits.should eq ["Std::Traits::Cmp"]
    end
  end

  it "dumps a trait and an impl as they were declared" do
    io = IO::Memory.new
    Iyi::IyiMod.dump sample_artifact(
      types: [type_declaration("Enumerable", "generic trait",
        assoc_types: ["Elem"],
        supertraits: ["Cmp"],
        methods: [signature("each", return_type: "Nil", required: true)])],
      impls: [impl_record("Std::Enumerable::Enumerable", "Std::List::List(T)",
        free_variables: ["T"],
        free_variable_bounds: [{"T", "Cmp"}],
        assoc_types: [{"Elem", "T"}])],
    ), io
    text = io.to_s

    # `generic` is how a type describes itself, not how anyone declares one.
    text.should contain "  pub trait Enumerable : Cmp"
    text.should contain "    type Elem"
    text.should contain "  impl Std::Enumerable::Enumerable for Std::List::List(T) forall T : Cmp"
    text.should contain "    type Elem = T"
  end

  # What `import` compiles against instead of the module's source (R-1). It is
  # iyi rather than a second grammar, so the parser that read the module reads
  # its declarations back.
  it "renders the declarations a consumer compiles against" do
    io = IO::Memory.new
    Iyi::IyiMod.declarations sample_artifact(
      exports: [signature("polite", ["name : String"], "String")],
      types: [type_declaration("Greet", "trait",
        methods: [signature("greet", return_type: "String", required: true)])],
      impls: [impl_record("Greet", "User")],
    ), io
    text = io.to_s

    text.should contain "module app/greeter"
    # A body is absent, not empty: a call is typed from the return annotation,
    # which is what makes this enough for the front end and nothing else.
    text.should contain "pub def polite(name : String) : String\nend\n"
    text.should contain "pub trait Greet\n  abstract def greet : String\nend\n"
    # An `abstract def` ends at its signature and takes no `end` of its own.
    text.should_not contain "abstract def greet : String\n  end"
    text.should contain "impl Greet for User\nend\n"
    # The impl comes after the type it targets, because the requirement check
    # reads the methods off the target rather than out of the impl's body.
    text.index("pub trait Greet").not_nil!.should be < text.index("impl Greet for User").not_nil!
  end

  it "renders a generic type and the impl that answers its associated type" do
    io = IO::Memory.new
    Iyi::IyiMod.declarations sample_artifact(
      types: [type_declaration("List", "generic struct", type_parameters: ["T"],
        methods: [signature("each", return_type: "Nil", block_parameter: "& : (T -> Nil)")])],
      impls: [impl_record("Std::Enumerable::Enumerable", "Std::List::List(T)",
        free_variables: ["T"], assoc_types: [{"Elem", "T"}])],
    ), io
    text = io.to_s

    text.should contain "pub struct List(T)"
    text.should contain "  def each(& : (T -> Nil)) : Nil\n  end\n"
    text.should contain "impl Std::Enumerable::Enumerable for Std::List::List(T) forall T\n  type Elem = T\nend\n"
  end
end

# iyi: the ecosystem and R-1, together (SPEC.md Part V item 12d).
#
# `--crystal` gives a program Crystal's library; a `.iyimod` gives a consumer a
# module it does not compile. Each was useful alone and refused together, and
# what the refusal protected against turned out to be three concrete things
# rather than one general one: the main module's helpers do not travel, the
# consumer's numbering is its own, and a module's requires are not the
# consumer's. All three have answers, so the combination is now supported and
# these are what keeps it working.
describe "a module compiled against Crystal's library" do
  it "travels through a .iyimod and links, replaying its requires" do
    with_tempdir("iyimod_crystal_library") do
      Dir.mkdir_p "app"
      # `uri` and not only `json`, because the requires are the point: the
      # consumer requires neither, and `URI::Error.class:type_id` was the
      # symbol that went undefined when they did not travel.
      File.write "app/store.iyi", <<-IYI
        module app/store

        require "json"
        require "uri"

        pub def encode(name : String) : String
          {"name" => name}.to_json
        end

        pub def slug(name : String) : String
          URI.encode_path_segment(name)
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/store
        using app/store

        puts encode("iyi")
        puts slug("a b")
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")
      `./from-source`.chomp.should eq %({"name":"iyi"}\na%20b)

      artifact = Iyi::IyiMod.read(File.join("mods", "app", "store.iyimod"))
      artifact.crystal_library.should be_true
      artifact.requires.should eq ["json", "uri"]

      File.delete "app/store.iyi"

      consumer = create_spec_compiler
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq %({"name":"iyi"}\na%20b)
    end
  end

  # The thing a shared library has to be shared: one copy of its state. Both
  # sides were compiled by the same compiler and mangle the same names, so the
  # linker folds them — but "the link succeeded" would also be true of a
  # program with two copies of a lazily initialised constant, and that program
  # is wrong in a way nothing reports.
  it "shares the library's state with the program that consumes it" do
    with_tempdir("iyimod_crystal_state") do
      Dir.mkdir_p "app"
      File.write "app/ids.iyi", <<-IYI
        module app/ids

        require "json"

        pub def stdout_id : UInt64
          STDOUT.object_id
        end

        pub def program_name_id : UInt64
          PROGRAM_NAME.object_id
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/ids
        using app/ids

        puts stdout_id == STDOUT.object_id
        puts program_name_id == PROGRAM_NAME.object_id
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("from-source")

      File.delete "app/ids.iyi"

      consumer = create_spec_compiler
      consumer.use_iyimod = "mods"
      consumer.compile source, File.expand_path("from-artifact")
      `./from-artifact`.chomp.should eq "true\ntrue"
    end
  end

  it "refuses to be imported by a program built against iyi's prelude" do
    with_tempdir("iyimod_crystal_into_iyi") do
      Dir.mkdir_p "app"
      File.write "app/store.iyi", <<-IYI
        module app/store

        require "json"

        pub def encode(name : String) : String
          {"name" => name}.to_json
        end
        IYI
      File.write "producer.iyi", <<-IYI
        module main

        import app/store
        using app/store

        puts encode("iyi")
        IYI

      producer = create_spec_compiler
      producer.emit_iyimod = "mods"
      producer.compile Iyi::Compiler::Source.new(
        File.expand_path("producer.iyi"), File.read("producer.iyi")),
        File.expand_path("producer")

      File.write "consumer.iyi", <<-IYI
        module main

        import app/store
        using app/store

        puts 1
        IYI

      consumer = create_spec_compiler
      consumer.prelude = "iyi/prelude"
      consumer.use_iyimod = "mods"

      expect_raises Iyi::CodeError, /built against Crystal's standard library/ do
        consumer.compile Iyi::Compiler::Source.new(
          File.expand_path("consumer.iyi"), File.read("consumer.iyi")),
          File.expand_path("consumer")
      end
    end
  end

  it "refuses to import a module built against iyi's prelude" do
    with_tempdir("iyimod_iyi_into_crystal") do
      Dir.mkdir_p "app"
      File.write "app/greet.iyi", <<-IYI
        module app/greet

        pub def hello(name : String) : String
          "merhaba " + name
        end
        IYI
      File.write "main.iyi", <<-IYI
        module main

        import app/greet
        using app/greet

        puts hello("iyi")
        IYI

      source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))

      producer = create_spec_compiler
      producer.prelude = "iyi/prelude"
      producer.emit_iyimod = "mods"
      producer.compile source, File.expand_path("producer")

      consumer = create_spec_compiler
      consumer.use_iyimod = "mods"

      expect_raises Iyi::CodeError, /built against iyi's prelude/ do
        consumer.compile source, File.expand_path("consumer")
      end
    end
  end
end
