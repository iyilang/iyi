require "../spec_helper"
require "./spec_helper"

# iyi: an allocating iyi program, for the `-Dgc_none` examples below.
#
# It allocates through both entry points a program can reach: the array
# literal's buffer holds `String`s and so goes through `__crystal_malloc64`,
# the `<<` past its capacity allocates another, and `join` builds a string
# through `__crystal_malloc_atomic64`. A program that only printed a literal
# would link the collector and never call it, and would pass either way.
private IYI_ALLOCATING_PROGRAM = <<-IYI
  words = ["gc", "none"]
  words << "flag"
  puts words.join("-")
  puts words.size
  IYI

# The libraries the link would name, as the compiler sees them after semantic:
# `Program#link_annotations` reads the `@[Link]` of every `lib` a program
# actually used, which is the question "does this binary need libgc" asked
# without a platform's object format in the way.
private def linked_libraries(result : Iyi::Compiler::Result) : Array(String)
  result.program.link_annotations.compact_map(&.lib)
end

private def iyi_compiler
  compiler = create_spec_compiler
  # Chosen by the entry file's extension in `iyi build`, which is the command
  # layer rather than the compiler, so a spec driving the compiler asks for it.
  compiler.prelude = "iyi/prelude"
  compiler
end

# Undefined symbols, by name, with the leading underscore Mach-O puts on a C
# name and ELF does not, and without the `U` column ELF's `nm` prints.
private def undefined_symbols(path : String) : Array(String)
  Process.capture(["nm", "-u", path]).lines.compact_map do |line|
    line.split.last?.try(&.lchop('_'))
  end
end

private def nm_available?
  !!Process.find_executable("nm")
end

describe "Compiler" do
  it "has a valid version" do
    SemanticVersion.parse(Iyi::Config.version)
  end

  it "compiles a file" do
    with_temp_executable "compiler_spec_output" do |path|
      Iyi::Command.run ["build"].concat(program_flags_options).concat([compiler_datapath("compiler_sample"), "-o", path])

      File.exists?(path).should be_true

      Process.capture(path).should eq("Hello!")
    end
  end

  # iyi: the linker probe is asked once per `PATH`, not once per build.
  #
  # Before linking, the compiler searches `PATH` for `mold` and then for
  # `ld.lld`. A name that is not on `PATH` costs a stat in every entry of it —
  # a millisecond on an ordinary Linux box, and 0.062 s per search under WSL,
  # where `PATH` carries the Windows directories. Twice a build, that was a
  # third of a warm build spent looking for linkers nobody had installed
  # (SPEC.md 0.1.0 item 2). This is the file that keeps the answer.
  it "remembers which linker it found rather than searching PATH per build" do
    with_temp_executable "compiler_spec_output" do |path|
      Iyi::Command.run ["build"].concat(program_flags_options).concat([compiler_datapath("compiler_sample"), "-o", path])

      probe = Iyi::CacheDir.instance.join("linker-probe")
      File.exists?(probe).should be_true
      # The `PATH` it was found under, so that changing `PATH` asks again.
      File.read(probe).lines.first.size.should eq 32
    end
  end

  # iyi: the link is the compiler's, not the driver's.
  #
  # `cc` does not link — it computes a command and runs `collect2`, which runs
  # `ld`. Measured here: 0.129 s through the driver against 0.014 s running the
  # same command directly, which is most of what a warm build costs (SPEC.md
  # 0.1.0 item 2). The compiler asks the driver once, keeps the answer as a
  # template, and runs `ld` itself. This is the file that holds the template,
  # and the program above having run is what says the link it built works.
  it "builds the link itself rather than asking the driver every time" do
    with_temp_executable "compiler_spec_output" do |path|
      Iyi::Command.run ["build"].concat(program_flags_options).concat([compiler_datapath("compiler_sample"), "-o", path])
      Process.capture(path).should eq("Hello!")

      # One file per set of link flags. Absent on a platform where this is not
      # attempted, which is a fallback rather than a failure — but where it is
      # attempted it must be usable.
      templates = Dir.glob(File.join(Iyi::CacheDir.instance.dir, "link-template-*"))
      templates.each do |template|
        File.read(template).lines[1]?.should_not eq "unusable"
      end
    end
  end

  # iyi: the cache cleaner asks before it deletes.
  #
  # It keeps the ten most recently modified directories in the cache and
  # removes the rest, and it runs at the end of every compile. A build's
  # directory stops looking recent while its units sit in an optimization
  # pass, writing nothing — so with enough builds around, one compiler process
  # deleted the directory another was writing its object files into. That
  # arrived as "No such file or directory" from the object emitter, or as a
  # linker asking for a `_main.o0.o` nobody had written: a lost hour reading
  # linker output for something the linker had not done.
  #
  # A build already says it is using its directory. It holds `compiler.lock`
  # there for the whole of codegen and linking; the cleaner reads it now.
  it "keeps a cache directory another compile is working in" do
    with_tempfile("cache-in-use") do |root|
      Dir.mkdir_p(root)

      working, idle = File.join(root, "working"), File.join(root, "idle")
      [working, idle].each do |dir|
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "program.o"), "")
        File.write(File.join(dir, "compiler.lock"), "")
      end

      cache = Iyi::CacheDir.instance
      cache.directory_in_use?(working).should be_false # a lock nobody holds

      # Both are the oldest in a cache of twelve, so the rule above would have
      # both of them; one of them is being written to.
      12.times { |i| Dir.mkdir_p(File.join(root, "newer-#{i}")) }

      File.open(File.join(working, "compiler.lock"), "r") do |lock|
        lock.flock_exclusive(blocking: false)
        cache.directory_in_use?(working).should be_true

        cache.cleanup(root)

        File.exists?(File.join(working, "program.o")).should be_true
        Dir.exists?(idle).should be_false
      end

      cache.directory_in_use?(working).should be_false # released with the file
    end
  end

  it "runs subcommand in preference to a filename " do
    Dir.cd compiler_datapath do
      with_temp_executable "compiler_spec_output" do |path|
        Iyi::Command.run ["build"].concat(program_flags_options).concat(["compiler_sample", "-o", path])

        File.exists?(path).should be_true

        Process.capture(path).should eq("Hello!")
      end
    end
  end

  # iyi: the collector is opt-in, and `-Dgc_boehm` is the opt.
  #
  # The prelude bound `@[Link("gc")] lib LibGC` whatever the flags said and
  # wired the three allocation entry points straight to it, so `-Dgc_none` took
  # the flag, put `-lgc` in the link and called `GC_malloc` anyway. That is
  # fixed, and then the default was inverted on top of it: bdw-gc is on
  # Crystal's required-libraries list and an iyi program is not allowed to need
  # anything on that list, so a plain build allocates without it and
  # `-Dgc_boehm` is how a program that wants real collection asks.
  #
  # Asked of `link_annotations` rather than of the binary because that is the
  # compiler's own answer to "which libraries does this program need", and it is
  # the same answer on every platform. The output comparison is the other half:
  # a build that dropped the collector and no longer ran is not a fix.
  it "needs no collector by default, and links one for -Dgc_boehm" do
    with_tempdir("iyi-gc-default-link") do
      File.write "allocating.iyi", IYI_ALLOCATING_PROGRAM
      source = Iyi::Compiler::Source.new(
        File.expand_path("allocating.iyi"), File.read("allocating.iyi"))

      uncollected = iyi_compiler.compile(source, File.expand_path("uncollected"))
      linked_libraries(uncollected).should_not contain "gc"

      collected = iyi_compiler
      collected.flags << "gc_boehm"
      linked_libraries(collected.compile(source, File.expand_path("collected")))
        .should contain "gc"

      Process.capture(File.expand_path("uncollected"))
        .should eq Process.capture(File.expand_path("collected"))
    end
  end

  # `-Dgc_none` still means what it meant, so nothing that passes it breaks: it
  # selects the same allocator the default now uses.
  it "keeps -Dgc_none as an alias of the default" do
    with_tempdir("iyi-gc-none-alias") do
      File.write "allocating.iyi", IYI_ALLOCATING_PROGRAM
      source = Iyi::Compiler::Source.new(
        File.expand_path("allocating.iyi"), File.read("allocating.iyi"))

      aliased = iyi_compiler
      aliased.flags << "gc_none"
      linked_libraries(aliased.compile(source, File.expand_path("aliased")))
        .should_not contain "gc"

      # Against the default build rather than a literal, so the fixture can
      # change without this example quietly asserting the old one.
      iyi_compiler.compile(source, File.expand_path("plain"))
      Process.capture(File.expand_path("aliased"))
        .should eq Process.capture(File.expand_path("plain"))
    end
  end

  # The same claim at the layer a person checks it at: a plain build, no flags,
  # and no `GC_*` left to resolve. What replaces the collector is the
  # platform's own allocator, and the two platforms prove it in opposite
  # directions, which is why this splits on `flag?` rather than sharing one
  # universal assertion: a single line is true on one platform and quietly
  # false on the other, which is how this example read before CI ran on Linux.
  #
  # darwin binds libSystem (Apple documents it as the only supported interface
  # and raw syscalls as not a stable ABI), so the allocator's own syscalls must
  # be among the undefined: "fewer GC symbols" would also pass a prelude that
  # quietly stopped allocating, and `mmap` is what says it did not. `malloc`
  # and `realloc` are absent now and that is the point of the branch: the
  # collector is the default allocator on POSIX, it carves its arenas from
  # `mmap` itself, and a prelude that fell back to libc's heap would put those
  # two names right back on this list. This example asserted their PRESENCE
  # when the default was still the bump pointer over libSystem's heap, and the
  # assertion outlived that flip.
  #
  # Linux issues the syscalls itself, so the proof there reads the same way for
  # `malloc` and `realloc` and cannot ask about `mmap`: measured, the Linux
  # object a plain build hands the linker leaves nothing undefined at all
  # (`nm -u` on the cross-compiled fixture is empty), and what a linked Linux
  # binary leaves undefined belongs to the crt objects in the link template
  # rather than to the prelude. Holding the whole empty allowlist is the floor
  # gate's job (SPEC.md III.9); this example asserts the allocator family
  # because that is the trade this branch made.
  it "resolves no GC_ symbol in a plain build" do
    pending! "nm is not available" unless nm_available?

    with_tempdir("iyi-gc-default-symbols") do
      File.write "allocating.iyi", IYI_ALLOCATING_PROGRAM
      Iyi::Command.run ["build"].concat(program_flags_options)
        .concat(["allocating.iyi", "-o", File.expand_path("uncollected")])

      symbols = undefined_symbols(File.expand_path("uncollected"))
      symbols.select(&.starts_with?("GC_")).should be_empty

      {% if flag?(:darwin) %}
        # It still allocates, through its own arenas.
        symbols.should contain "mmap"
        symbols.should contain "munmap"
        # And not through libSystem's heap, which is what the collector replaced.
        symbols.should_not contain "malloc"
        symbols.should_not contain "realloc"
      {% else %}
        # Not `pending!`: absence is a real assertion, the same claim the
        # darwin branch makes, asked in the only direction Linux can answer.
        symbols.should_not contain "malloc"
        symbols.should_not contain "realloc"
        symbols.should_not contain "mmap"
      {% end %}
    end
  end

  # iyi: the same compiler ships under two names, and each has to answer as
  # the one a person typed. Both directions are asserted, because getting this
  # right in one direction by hardcoding is how it was wrong before.
  #
  # `Command.program_name` is set by the entrypoint, so a banner built in a
  # CONSTANT captures the default instead. That is exactly what `iyi tool`
  # did: it told everybody they were running `crystal tool`.
  describe "the name a person sees" do
    it "names iyi in a banner iyi reaches" do
      Iyi::Command.program_name = "iyi"
      Iyi::Command.commands_usage.should start_with "Usage: iyi tool"
    end

    it "names crystal in the same banner under crystal" do
      Iyi::Command.program_name = "crystal"
      Iyi::Command.commands_usage.should start_with "Usage: crystal tool"
    ensure
      Iyi::Command.program_name = "iyi"
    end

    it "interpolates rather than printing the interpolation" do
      # A quoted heredoc does not interpolate, and `clear_cache` shipped one,
      # so its banner printed the literal `#{...}` at a user.
      Iyi::Command.commands_usage.should_not contain "Command.program_name"
    end
  end

  # iyi: Crystal's own specs spawn this compiler with `CRYSTAL_PATH` set.
  # Reading only `IYI_PATH` made every one of those fail to find `prelude`.
  describe "the names Crystal's specs still set" do
    it "reads CRYSTAL_PATH when IYI_PATH is unset" do
      old_iyi = ENV["IYI_PATH"]?
      old_crystal = ENV["CRYSTAL_PATH"]?
      ENV.delete("IYI_PATH")
      ENV["CRYSTAL_PATH"] = "from-crystal"
      Iyi::IyiPath.default_paths.should eq(["from-crystal"])
    ensure
      old_iyi ? (ENV["IYI_PATH"] = old_iyi) : ENV.delete("IYI_PATH")
      old_crystal ? (ENV["CRYSTAL_PATH"] = old_crystal) : ENV.delete("CRYSTAL_PATH")
    end

    it "prefers IYI_PATH when both are set" do
      old_iyi = ENV["IYI_PATH"]?
      old_crystal = ENV["CRYSTAL_PATH"]?
      ENV["IYI_PATH"] = "from-iyi"
      ENV["CRYSTAL_PATH"] = "from-crystal"
      Iyi::IyiPath.default_paths.should eq(["from-iyi"])
    ensure
      old_iyi ? (ENV["IYI_PATH"] = old_iyi) : ENV.delete("IYI_PATH")
      old_crystal ? (ENV["CRYSTAL_PATH"] = old_crystal) : ENV.delete("CRYSTAL_PATH")
    end
  end

  # `Object#to_s` answers with the type's name, so a type that never defined
  # `to_s` printed its own name instead of its value and nothing said a method
  # was missing. `samples/iyi/calc` scans with `String#[]` and compares the
  # result, so the sample that added `String#[]` could not catch it: comparison
  # was defined and printing was not.
  #
  # Asserted against the character rather than "not the type name", because
  # `Char` is the only type this reaches and the value is the claim.
  describe "a Char prints its value" do
    it "prints, inspects and interpolates the character" do
      with_tempdir("iyi-char-to-s") do
        # Quoted, so the interpolation below reaches iyi instead of being
        # expanded by the spec's own compiler.
        File.write "char.iyi", <<-'IYI'
          s = "hello"
          puts s[1]
          puts s[1].inspect
          puts "x#{s[4]}y"
          IYI
        source = Iyi::Compiler::Source.new(
          File.expand_path("char.iyi"), File.read("char.iyi"))
        iyi_compiler.compile(source, File.expand_path("char"))

        Process.capture(File.expand_path("char")).should eq("e\n'e'\nxoy\n")
      end
    end
  end

  # iyi: negative indexing and the small formatting set.
  #
  # `a[-1]` used to raise, the way an index past the end does, and the README
  # listed that as a missing habit. It counts from the end now, on both Array
  # and String, and `[]=` / `[]?` wrap the same way. Formatting is
  # `to_s(base)`, `rjust` / `ljust` and `*`, not a format-string parser.
  describe "negative indexing and formatting" do
    it "indexes from the end, writes bases, and pads" do
      with_tempdir("iyi-index-format") do
        File.write "format.iyi", <<-'IYI'
          a = [10, 20, 30]
          puts a[-1]
          puts a[-a.size]
          a[-1] = 99
          puts a[-1]
          puts a[-1].inspect
          puts a[-4]?.inspect

          s = "hello"
          puts s[-1]
          puts s[-2, 2]

          puts 255.to_s(16)
          puts 5.to_s(2)
          puts "ab".rjust(5)
          puts "ab".ljust(5, '*')
          puts "ab" * 3
          IYI
        source = Iyi::Compiler::Source.new(
          File.expand_path("format.iyi"), File.read("format.iyi"))
        iyi_compiler.compile(source, File.expand_path("format"))

        Process.capture(File.expand_path("format")).should eq(
          "30\n10\n99\n99\nnil\no\nlo\nff\n101\n   ab\nab***\nababab\n")
      end
    end
  end

  # iyi: File.read / File.write / File.exists? / File.delete.
  #
  # A language that cannot read a file cannot be used. The surface is those
  # four, and a missing path panics with the path in the message.
  describe "File" do
    it "round-trips and deletes a file and answers exists?" do
      with_tempdir("iyi-file-io") do
        File.write "io.iyi", <<-'IYI'
          File.write("t.txt", "hello")
          puts File.read("t.txt")
          puts File.exists?("t.txt")
          puts File.exists?("missing.txt")
          File.delete("t.txt")
          puts File.exists?("t.txt")
          IYI
        source = Iyi::Compiler::Source.new(
          File.expand_path("io.iyi"), File.read("io.iyi"))
        iyi_compiler.compile(source, File.expand_path("io"))

        Process.capture(File.expand_path("io")).should eq("hello\ntrue\nfalse\nfalse\n")
      end
    end

    it "names the path when the file is missing" do
      with_tempdir("iyi-file-missing") do
        File.write "miss.iyi", <<-'IYI'
          File.read("no-such-iyi-file.txt")
          IYI
        source = Iyi::Compiler::Source.new(
          File.expand_path("miss.iyi"), File.read("miss.iyi"))
        iyi_compiler.compile(source, File.expand_path("miss"))

        exception = nil
        begin
          Process.capture(File.expand_path("miss"))
        rescue ex
          exception = ex
        end
        exception.should_not be_nil
      end
    end

    # `open` takes a directory and `read` refuses it, and the refusal read
    # as the end of an empty file: `File.read("adir")` was "", exit 0.
    it "refuses to read a directory rather than answering an empty file" do
      with_tempdir("iyi-file-directory") do
        Dir.mkdir("adir")
        File.write "dir.iyi", <<-'IYI'
          puts File.read("adir").size
          IYI
        source = Iyi::Compiler::Source.new(
          File.expand_path("dir.iyi"), File.read("dir.iyi"))
        iyi_compiler.compile(source, File.expand_path("dir"))

        error = IO::Memory.new
        status = Process.run(File.expand_path("dir"), error: error)
        status.success?.should be_false
        error.to_s.should contain "cannot read adir: it is a directory"
      end
    end
  end

  # iyi: the concurrency runtime — SPEC.md III.4, Linux only. The bench gate
  # (`bench/concurrency_exercise.sh`) is the full property list; what earns a
  # place *here* is what `make compiler_spec` should catch without bash: the
  # runtime compiles, interleaves, cancels, selects, and adds no undefined
  # symbol. Skipped where the runtime does not exist, by the same platform
  # test the prelude gates the `require` on.
  {% if flag?(:linux) && (flag?(:x86_64) || flag?(:aarch64)) %}
    describe "concurrency" do
      it "interleaves a group's tasks through a channel and joins" do
        with_tempdir("iyi-conc-pingpong") do
          File.write "ping.iyi", <<-'IYI'
            ping = Channel(Int32).new(1)
            pong = Channel(Int32).new(1)
            order = ""
            group do |g|
              g.spawn do
                round = 0
                while round < 2
                  ping.receive
                  order = order + "a"
                  pong.send(1)
                  round = round + 1
                end
                0
              end
              g.spawn do
                round = 0
                while round < 2
                  order = order + "b"
                  ping.send(1)
                  pong.receive
                  round = round + 1
                end
                0
              end
            end
            puts order
            IYI
          source = Iyi::Compiler::Source.new(
            File.expand_path("ping.iyi"), File.read("ping.iyi"))
          iyi_compiler.compile(source, File.expand_path("ping"))

          Process.capture(File.expand_path("ping")).should eq("baba\n")
        end
      end

      it "cancels a blocked sibling when a task fails, and select picks the ready arm" do
        with_tempdir("iyi-conc-cancel-select") do
          File.write "cs.iyi", <<-'IYI'
            pub struct Boom
              def initialize
              end
            end

            impl Error for Boom
              def message : String
                "boom"
              end
            end

            saw = ""
            group do |g|
              g.spawn do
                slept = sleep(10000)
                saw = slept.is_a?(Cancelled) ? "cancelled" : "slept"
                slept
              end
              g.spawn do
                sleep(10)
                Boom.new
              end
            end
            puts saw

            ready = Channel(Int32).new(1)
            ready.send(5)
            other = Channel(Int32).new(1)
            select
            when a = other.receive
              puts "wrong arm"
            when b = ready.receive
              puts b.is_a?(Int32) ? b * 2 : -1
            end
            IYI
          source = Iyi::Compiler::Source.new(
            File.expand_path("cs.iyi"), File.read("cs.iyi"))
          iyi_compiler.compile(source, File.expand_path("cs"))

          Process.capture(File.expand_path("cs")).should eq("cancelled\n10\n")
        end
      end

      it "adds no undefined symbol for the runtime" do
        pending! "nm is unavailable" unless nm_available?
        with_tempdir("iyi-conc-floor") do
          File.write "floor.iyi", <<-'IYI'
            done = Channel(Int32).new
            group do |g|
              g.spawn do
                done.send(1)
                0
              end
              g.spawn do
                value = done.receive
                0
              end
            end
            puts "ok"
            IYI
          Iyi::Command.run ["build"].concat(program_flags_options)
            .concat(["floor.iyi", "-o", File.expand_path("floor")])

          # The C runtime template's five, and nothing of the runtime's own:
          # the scheduler, the poller and the switch are raw syscalls and asm.
          symbols = undefined_symbols(File.expand_path("floor"))
          template = ["ITM_deregisterTMCloneTable", "ITM_registerTMCloneTable",
                      "_cxa_finalize", "_gmon_start__", "_libc_start_main"]
          (symbols - template).should be_empty
        end
      end
    end
  {% end %}
end
