require "../spec_helper"
require "./spec_helper"

# iyi: what `crystal tool bind` writes, read back by a build.
#
# The tool had no spec at all, and the shape of what that cost is the reason
# this one exists. Everything it checked was a number it printed — how much of a
# surface crosses, what the boundary waits on — and a number cannot say whether
# anything can *consume* the artifact printed beside it. So nothing ever did,
# and when somebody finally tried by hand, neither root shape worked: a module
# root declared `Any` while its own fields named `JSON::Any`, and a class root
# rendered a `def` where no type was open.
#
# The consumer runs with `no_codegen` on purpose. What broke was the
# declarations, and reading them back is the whole claim here. Linking is a
# separate one — it needs `nm` and `objcopy`, which is a pipeline rather than a
# spec, and a spec that shelled out to binutils would be testing this machine.

# The program `tool bind` reads: a Crystal source, analysed under Crystal's own
# library, which is what the tool needs and why it lives in the compiler.
private def bind_artifact(source_path : String, root : String, dir : String,
                          bound : String? = nil) : String
  compiler = create_spec_compiler
  compiler.no_codegen = true
  source = Iyi::Compiler::Source.new(File.expand_path(source_path), File.read(source_path))
  result = compiler.compile source, File.expand_path("bind-probe")

  report = IO::Memory.new
  Iyi.print_bind result.program, root, report, artifact_dir: dir, bound_dir: bound
  LAST_REPORT.clear
  LAST_REPORT << report.to_s
  File.join(dir, "#{iyi_module_name(root)}.iyimod")
end

# What the run above printed, for the one claim that is about the report rather
# than about the artifact.
LAST_REPORT = [] of String

# The same rule the tool uses, written out here rather than reached for, so a
# spec that agreed with the compiler by calling it could not agree wrongly.
private def iyi_module_name(root : String) : String
  root.split("::").map { |segment| segment.gsub(/([A-Z])/) { "_" + $1.downcase }.lchop('_') }.join("-")
end

# An iyi program that imports the boundary and nothing else. Importing is
# enough: it is the read-back, and every failure this file was written for
# happens there rather than at a call site.
private def consume(artifact_dir : String, module_name : String)
  File.write "main.iyi", <<-IYI
    module main

    import #{module_name}
    IYI

  # Crystal's library, not iyi's prelude. A bound shard's artifact says it was
  # compiled under Crystal's — which it was — and a program cannot hold one
  # module of each, because the two define types of the same names with
  # different layouts. The unit numbers `Pointer(LibUnwind::Exception)` whatever
  # the shard does, so the consumer that can read it is the one that has it.
  consumer = create_spec_compiler
  consumer.use_iyimod = artifact_dir
  consumer.no_codegen = true
  source = Iyi::Compiler::Source.new(File.expand_path("main.iyi"), File.read("main.iyi"))
  consumer.compile source, File.expand_path("consumer")
end

describe "tool bind" do
  # A module root, which is the shape a shard has: `Kemal`, `JSON`.
  #
  # `MyLib` rather than `Lib`, and the difference is the bug. The artifact's
  # module name is the root downcased, and the consumer builds a type back out
  # of it by capitalising — so `Lib` survives the trip and `MyLib` becomes
  # `Mylib`, while the declarations inside still say `MyLib::Entry`. Every real
  # namespace is the second kind: `JSON`, `YAML`, `URI`.
  #
  # The field is what fails rather than the method, and that is not incidental:
  # a consumer has to know a type's size to allocate one, so a field's type is
  # resolved on the way in while a return type can wait for a call site.
  it "writes a module's artifact that a build can read back" do
    with_tempdir("bind_module_root") do
      Dir.mkdir_p "mods"
      File.write "shard.cr", <<-CR
        module MyLib
          extend self

          class Entry
            @size : Int32

            def initialize(@size : Int32)
            end

            def size : Int32
              @size
            end
          end

          class Holder
            @entry : Entry

            def initialize(@entry : Entry)
            end

            def entry : Entry
              @entry
            end
          end

          def hold(entry : Entry) : Holder
            Holder.new(entry)
          end
        end
        CR

      File.exists?(bind_artifact("shard.cr", "MyLib", "mods")).should be_true
      consume "mods", "my_lib"
    end
  end

  # A carried body is read as source before a name in it is rewritten, and it is source only
  # where its parameters are variables: `x = x.abs`, `n -= 1` and `->obj.call` are not
  # otherwise.
  it "carries a body that assigns, steps and takes a method pointer of its parameters" do
    with_tempdir("bind_parameter_bodies") do
      Dir.mkdir_p "mods"
      File.write "shard.cr", <<-CR
        module MyLib
          extend self

          class Entry
            @size : Int32

            def initialize(@size : Int32)
            end

            def size : Int32
              @size
            end
          end

          def assigns(x : Int32, &block : MyLib::Entry -> Int32) : Int32
            x = x.abs
            yield MyLib::Entry.new(x)
          end

          def steps(n : Int32, &block : MyLib::Entry -> Int32) : Int32
            n -= 1
            yield MyLib::Entry.new(n)
          end

          def points(obj : MyLib::Entry, &block : MyLib::Entry -> Int32) : Int32
            size = ->obj.size
            yield MyLib::Entry.new(size.call)
          end
        end
        CR

      artifact = Iyi::IyiMod.read(bind_artifact("shard.cr", "MyLib", "mods"))
      body_of = ->(name : String) do
        method = artifact.exports.functions.find { |candidate| candidate.name == name }.not_nil!
        artifact.mono_bodies[Iyi::IyiMod.mono_body_key(artifact.module_name, method, 0)]
      end
      body_of.call("assigns").should eq("x = x.abs\nyield Entry.new(x)\n")
      # The body is printed after the compiler has read it, and that spells `n -= 1` out.
      body_of.call("steps").should eq("n = n - 1\nyield Entry.new(n)\n")
      body_of.call("points").should eq("size = ->obj.size\nyield Entry.new(size.call)\n")
      consume "mods", "my_lib"
    end
  end

  # A class root, which is the shape a core type has: `IO`, `Time`. Its own
  # methods are its type's rather than module functions, so the whole boundary
  # travels as one declaration holding the rest — a shape no shard produces and
  # nothing checked.
  #
  # It survives the trip the module root does not, and for a reason worth
  # keeping: a class root's own name *is* its declaration's name, so `MySink::Entry`
  # resolves against it wherever the module lands. A module root drops that name
  # and leaves the references pointing at nothing.
  it "writes a class's artifact that a build can read back" do
    with_tempdir("bind_class_root") do
      Dir.mkdir_p "mods"
      File.write "shard.cr", <<-CR
        class MySink
          @count : Int32

          def initialize
            @count = 0
          end

          def count : Int32
            @count
          end

          class Entry
            @size : Int32

            def initialize(@size : Int32)
            end

            def size : Int32
              @size
            end
          end
        end
        CR

      File.exists?(bind_artifact("shard.cr", "MySink", "mods")).should be_true
      consume "mods", "my_sink"
    end
  end

  # The one thing a boundary cannot survive, said where somebody can act on it.
  #
  # Almost every name survives it, `JSON` and `HTTPServer` included, because the
  # path is `camelcase` run backwards and `camelcase` reads every upper-case
  # letter as a group boundary. What does not survive is a name the grammar
  # cannot spell: `Foo_Bar` needs two underscores in a row and `camelcase` reads
  # two as one, so it comes back `FooBar`.
  #
  # Both sides mangle alike, which is the premise the whole boundary rests on —
  # so a root outside the image produces an object file whose symbols no
  # consumer will ever ask for. Nothing said so until the linker did, which is
  # the worst place for it: the artifact reads fine, the keep file compiles
  # fine, and the failure arrives four steps later.
  it "says when a root's name cannot survive the trip" do
    with_tempdir("bind_round_trip_name") do
      Dir.mkdir_p "mods"
      File.write "shard.cr", <<-CR
        module Foo_Bar
          extend self

          def polite(name : String) : String
            "hello, " + name
          end
        end
        CR
      bind_artifact "shard.cr", "Foo_Bar", "mods"
      LAST_REPORT.first.should contain "cannot be linked against"

      # And an acronym does survive it, which is the half that was got wrong
      # first: `JSON` is `j_s_o_n`, not `json`.
      File.write "ok.cr", <<-CR
        module ABC
          extend self

          def polite(name : String) : String
            "hello, " + name
          end
        end
        CR
      bind_artifact "ok.cr", "ABC", "mods"
      LAST_REPORT.first.should_not contain "cannot be linked against"
    end
  end

  # Two boundaries, where the second names a type from the first.
  #
  # This is what `IO` is for: `JSON`, `YAML` and `URI` all take one, so a `JSON`
  # boundary is only worth anything if it can say so. The producer calls the
  # type `Carrier`; the consumer, having imported it, calls it `Carrier::Carrier`
  # — so the name written into the second artifact has to be the consumer's, and
  # the dependency has to travel with it or a consumer would have to work out
  # the `import` for itself.
  it "writes a boundary that names another boundary's type" do
    with_tempdir("bind_composed") do
      Dir.mkdir_p "mods"
      File.write "carrier.cr", <<-CR
        class Carrier
          @size : Int32

          def initialize(@size : Int32)
          end

          def size : Int32
            @size
          end
        end
        CR
      File.write "shard.cr", <<-CR
        require "./carrier"

        module MyWire
          extend self

          class Packet
            @carrier : Carrier

            def initialize(@carrier : Carrier)
            end

            def carrier : Carrier
              @carrier
            end
          end
        end
        CR

      bind_artifact "carrier.cr", "Carrier", "mods"
      bind_artifact "shard.cr", "MyWire", "mods", bound: "mods"

      # `mywire` alone. The artifact records what it depends on, so the consumer
      # does not repeat it.
      consume "mods", "my_wire"
    end
  end

  # III.6 rule 1, measured instead of asserted.
  #
  # The tool instantiated a method whose return type nobody wrote and read the
  # answer, and copied a method whose return type somebody *did* write straight
  # out. So the written half was never held against anything, and a written
  # restriction is not what a caller is handed: Crystal narrows it to what the
  # body produced. `def narrow : String?` returning a `String` types its call
  # `String`, and a consumer told `String?` holds a union where the object code
  # answers a bare pointer.
  #
  # `: Nil` is the case that says the question has to be asked of the call and
  # not of the body. Its body produces an `IO` and its caller gets `Nil`, so a
  # check reading the body reports a defect that is not there. It was written
  # that way first and this is the spec that would have caught it.
  it "holds a written return type against what a caller is handed" do
    with_tempdir("bind_written_return") do
      Dir.mkdir_p "mods"
      File.write "shard.cr", <<-CR
        module Narrow
          extend self

          def wider : String?
            "s"
          end

          def exact : String
            "s"
          end

          def discards(io : IO) : Nil
            io << "x"
          end

          # Its return can only be read by calling it, and calling it needs a
          # block. The tool synthesises one of the annotated shape; without
          # that, overload resolution answered `wrong number of arguments`
          # and the return stood on the shard's word.
          def folded(& : Int32 -> Int32) : Int32
            yield 1
          end
        end
        CR

      bind_artifact "shard.cr", "Narrow", "mods"
      report = LAST_REPORT.first

      report.should contain "written returns, held against what a caller is handed"
      report.should contain "Narrow#wider"
      report.should contain "writes (String | Nil), answers String"

      # The two that agree stay out of it. `discards` is the one that would be
      # named by a check that read the body.
      report.should_not contain "Narrow#exact"
      report.should_not contain "Narrow#discards"

      # And a block-taking method is checked like any other, rather than
      # counted as a return nobody could read.
      report.should contain "crossing on a return nobody checked    0"

      # And the answer is what travels, because the symbol is named after it.
      # The draft the report prints is the same text the artifact carries.
      # `bench/bind_roundtrip.sh` is this claim with a linker behind it; this is
      # the cheap half, and says which of the two spellings was written.
      report.should contain "pub def wider : String\n"
      report.should_not contain "pub def wider : (String | Nil)"

      consume "mods", "narrow"
    end
  end
end
