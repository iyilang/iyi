require "./spec_helper"

# iyi: a Crystal namespace bound, built, and called from an iyi program.
#
# Two commands and no binutils, which is the whole of what changed. What this
# used to take was four steps — compile the keep file to one object, read its
# symbols with `nm`, make them global with `objcopy`, then hand the object to
# the consumer — and it did not work at the end of it. The object `--emit obj`
# makes is a whole program: it carries Crystal's library with it, and a program
# can have that library once. Linked into a consumer with none, the shard's
# constants never initialise and the first read segfaults. Linked into one that
# has it, every runtime global is defined twice and nothing links.
#
# An ordinary build leaves one object per type instead, and the ones a namespace
# owns carry no runtime at all. `--emit-bind` on that build puts them in the
# artifact, and the consumer links what the artifact carries — which is what it
# already does for an iyi module's object code.
#
# `--crystal` on the consumer is not decoration. The unit numbers
# `Pointer(LibUnwind::Exception)` whatever the shard does, because a `String#+`
# can raise, and an iyi program cannot name that type.
private ROOT = File.expand_path(File.join(__DIR__, "..", ".."))

# The list separator is the platform's: `;` on Windows, where a drive letter
# owns the colon.
private def crystal_env
  {"CRYSTAL_PATH" => "lib#{Process::PATH_DELIMITER}#{File.join(ROOT, "src")}"}
end

describe "`crystal tool bind`, end to end" do
  it "builds and runs a program that calls a bound shard" do
    pending!("requires #{CRYSTAL_BIN} (`make crystal`)") unless File::Info.executable?(CRYSTAL_BIN)
    pending!("requires #{IYI_BIN} (`make iyi`)") unless File::Info.executable?(IYI_BIN)

    # Both binaries, from one commit. An artifact is read only by the build that
    # wrote it (SPEC.md IV.5), and `make` bakes the commit in at link time — so a
    # tree where one of the two is a rebuild behind fails here for a reason that
    # has nothing to do with what this is checking.
    build_of = ->(binary : String) do
      Process.capture_result([binary, "--version"]).output.match(/\[([0-9a-f]+)\]/).try &.[1]
    end
    crystal_build = build_of.call(CRYSTAL_BIN)
    iyi_build = build_of.call(IYI_BIN)
    unless crystal_build && iyi_build && crystal_build == iyi_build
      pending!("needs `make crystal iyi` from one commit: crystal is #{crystal_build}, iyi is #{iyi_build}")
    end

    with_tempfile("bind-pipeline") do |dir|
      mods = File.join(dir, "mods")
      Dir.mkdir_p mods

      # `ABCGreeter` for both halves of what the name has to survive: an acronym,
      # which `underscore` flattened to `abcgreeter`, and an inner capital, which
      # a plain `downcase` flattened too.
      File.write File.join(dir, "shard.cr"), <<-CR
        module ABCGreeter
          extend self

          # Both ways a module can carry a function, because they mangle
          # differently. `extend self` puts `polite` on the module and `def
          # self.` puts `brisk` on the metaclass, which has no `@`. Crystal's
          # own library is written the second way throughout.
          def polite(name : String) : String
            "hello, " + name
          end

          def self.brisk(name : String) : String
            "hi " + name
          end

          # A union parameter is more than one symbol: a consumer passing a
          # string reaches `<String>` and one passing an `Int32` reaches
          # `<Int32>`. The keep file names all of them.
          def self.label(value : Int32 | String) : String
            value.to_s
          end

          # Both kinds of constant, because only one of them was ever the
          # problem. `LIMIT` is folded by the compiler and has always crossed;
          # `TABLE` has to be built when the program starts, and its initialiser
          # runs in whichever program *reads* it. The unit refers to it and
          # defines nothing, so the assignment travels in the artifact for the
          # consumer to make. Read the wrong way round, this is what used to
          # segfault on the first read.
          TABLE = ["zero", "one", "two"]
          LIMIT = 10

          def self.word(index : Int32) : String
            TABLE[index]
          end

          def self.limit : Int32
            LIMIT
          end

          # An enum, which is a kind of type and not a namespace. Its members
          # travel with it and are numbered as the shard numbered them: a
          # consumer that guessed would agree with the object file by luck.
          enum Size
            Small
            Large
          end

          def self.bigger(size : Size) : Bool
            size == Size::Large
          end

          # A generic, whose methods exist once per instantiation and whose
          # instantiations belong to whoever writes them. What crosses is the
          # declaration and the *source* of its methods (IV.2, `MonoBodies`);
          # the consumer compiles them for the arguments it picks. Its return
          # type has to be written, because the trick that rescues an ordinary
          # method — instantiate it and read the answer — has no single answer
          # for a generic owner.
          class Holder(T)
            @item : T

            def initialize(@item : T)
            end

            def item : T
              @item
            end
          end

          def self.hold(n : Int32) : Holder(Int32)
            Holder(Int32).new(n)
          end

          # And a type under the root, with a constant of its own. Its unit is
          # the root's second, and the assignment travels as `Inner::LABELS`,
          # which defines rather than reopens.
          class Inner
            LABELS = ["a", "b"]

            def self.label(index : Int32) : String
              LABELS[index]
            end
          end
        end
        CR

      File.write File.join(dir, "app.iyi"), <<-IYI
        module main

        import a_b_c_greeter

        puts ABCGreeter.polite("iyi")
        puts ABCGreeter.brisk("iyi")
        puts ABCGreeter.label(7)
        puts ABCGreeter.word(1)
        puts ABCGreeter.limit
        puts ABCGreeter::Inner.label(1)
        puts ABCGreeter.bigger(ABCGreeter::Size::Large)
        puts ABCGreeter.bigger(ABCGreeter::Size::Small)
        puts ABCGreeter.hold(42).item
        IYI

      # 1. The declarations, and the keep file that makes the code exist.
      Process.capture_result([CRYSTAL_BIN, "tool", "bind", "-e", "ABCGreeter",
                              "--emit-bind", "mods", "shard.cr"],
        chdir: dir, env: crystal_env).should be_success

      # The module's name is the root with `camelcase` undone, so this is the
      # file the tool wrote and not a guess about it.
      File.exists?(File.join(mods, "a_b_c_greeter.iyimod")).should be_true

      # 2. An ordinary build of that keep file, which is where the per-type units
      # exist. Not `--emit obj`: that merges them into one object and takes the
      # library with it.
      Process.capture_result([CRYSTAL_BIN, "build", "--iyi-keep", "ABCGreeter",
                              "--emit-bind", ".", "-o", "keepbin",
                              "a_b_c_greeter_keep.cr"],
        chdir: mods, env: crystal_env).should be_success

      # 3. The consumer, which links what the artifact carries. No `--link-flags`
      # and no binutils anywhere in this.
      Process.capture_result([IYI_BIN, "build", "--crystal", "--use-iyimod", "mods",
                              "-o", "app", "app.iyi"],
        chdir: dir, env: crystal_env).should be_success

      # The claim. Not that it compiled, not that it linked — that the program
      # ran and the answers came from the shard.
      Process.capture_result([File.join(dir, "app")], chdir: dir)
        .output.chomp.should eq "hello, iyi\nhi iyi\n7\none\n10\nb\ntrue\nfalse\n42"
    end
  end
end
