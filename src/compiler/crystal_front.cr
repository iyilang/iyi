# iyi: the front end as a program of its own — parse, analyse, report, exit.
#
#     crystal-front samples/iyi/hello.iyi
#
# **Why it exists is a measurement.** `crystal build --no-codegen` never calls
# LLVM and pays 0.026 s for linking it anyway: libLLVM's load-time initialisers
# are charged to any process with a `NEEDED` entry on the library, whether or
# not it generates code. That was two thirds of the figure 0.1.0's target is set
# on. This binary links none, so what it costs is what the analysis costs.
#
# It is deliberately not a second `Iyi::Command`: the driver is thirty
# lines because everything else in a build — object files, a linker, a cache —
# belongs to the half that is missing. See `crystal/llvm_shim.cr` and SPEC.md
# 0.1.0.

{% raise "crystal_front.cr is the front end without LLVM: build it with -Dwithout_llvm" unless flag?(:without_llvm) %}

# Named one by one rather than globbed, because the glob is what pulls in the
# half this binary is defined by not having: `compiler.cr` and `command.cr` are
# a code generator's driver and speak LLVM on every other line.
#
# The order is `requires.cr`'s — annotatable, then `Program`, then the rest —
# because `Program` is reopened by half the files here and whoever opens it
# first decides what it inherits from.
require "./iyi/annotatable"
require "./iyi/program"
require "./iyi/config"
require "./iyi/iyi_path"
require "./iyi/error"
require "./iyi/exception"
require "./iyi/formatter"
require "./iyi/iyimod"
require "./iyi/optimization_mode"
require "./iyi/syntax/transformer"
require "./iyi/progress_tracker"
require "./iyi/semantic"
require "./iyi/macros/*"
require "./iyi/syntax"
require "./iyi/types"
require "./iyi/util"
require "./iyi/build_inputs"
require "./iyi/warnings"

# Last, as the glob would have it: `@[Link]` is read by the front end, and the
# annotation lives under `codegen/` because only a linker acts on it. It names
# no LLVM.
require "./iyi/codegen/link"
require "./iyi/codegen/experimental"
require "./iyi/codegen/ast"
require "./iyi/codegen/types"
require "./iyi/codegen/cache_dir"

module Iyi::Front
  # The prelude a `.iyi` file gets, which is the same rule `crystal build`
  # applies: iyi's own, unless the file is Crystal's.
  private def self.prelude_for(filename : String) : String
    filename.ends_with?(".iyi") ? "iyi/prelude" : "prelude"
  end

  def self.run(argv : Array(String)) : Int32
    filename = argv.find { |argument| !argument.starts_with?("--") }
    unless filename
      STDERR.puts "usage: crystal-front FILE"
      return 1
    end

    unless File.file?(filename)
      STDERR.puts "crystal-front: no such file: #{filename}"
      return 1
    end

    filename = File.expand_path(filename)
    source = File.read(filename)

    program = Program.new
    program.filename = filename
    # Flags come from the target, computed on demand — the same set a build
    # for this machine would have.
    program.codegen_target = Config.host_target

    node = program.new_parser(source).tap(&.filename = filename).parse
    location = Location.new(filename, 1, 1)
    # Flagged as the prelude's own `require`, because a `.iyi` file is not
    # allowed one and the refusal does not know the compiler wrote this line.
    node = program.normalize(
      Expressions.new([Require.new(prelude_for(filename)).tap(&.iyi_prelude=(true)).at(location), node] of ASTNode))

    program.requires.add filename
    program.semantic node, cleanup: true

    0
  rescue ex : Iyi::CodeError
    # The same rendering the driver gives: a location, the line, and a caret.
    ex.color = true
    STDERR.puts ex
    1
  rescue ex : Iyi::Error
    # `require` wraps errors to trace the path it took to reach them, so the
    # message that matters is at the bottom of the chain.
    while cause = ex.cause
      STDERR.puts ex.message
      ex = cause
    end
    STDERR.puts ex.message
    1
  end
end

exit Iyi::Front.run(ARGV)
