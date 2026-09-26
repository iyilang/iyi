# iyi: a package's reach - what its own source touches outside the
# language: the standard-library modules that call C which it reaches,
# `File` from the prelude, and the C it declares itself, `@[Link]`
# libraries and `lib` functions (SPEC.md III.7).
#
# A std module counts when it, or a std module it imports, declares a C
# function or calls one of the runtime's `__iyi_` hooks - `std/env` reads
# the environment through `__iyi_environ` - and `std/socket` does, so a
# package importing `std/http` reaches `std/socket`; `std/json` calls
# nothing and is not listed. The allocator's hooks are the language's own
# and are not reach. The rule is
# read off std's own source rather than kept as a list, so a module that
# gains a `lib` is counted the day it does. An LLVM intrinsic spelled as a
# `fun` - `std/math`'s `llvm.sqrt.f64` - is the compiler's, not C.
#
# It is read from the source, not from a build: the import lines, and the
# declarations a C call needs before it can be written. A package cannot
# open a socket without importing `std/socket`, and cannot call C without
# a `lib` declaring the function, so the list is what the package can do,
# not a sample of what one run did. It is a report and not a sandbox: a
# `lib` spelled inside macro text the parser cannot read alone is not
# counted, and says so by not being there.
#
# Tests are left out - a consumer builds the package, never its tests -
# and so are hidden directories, `lib/` and any directory with an
# `iyi.mod` of its own, which is another package.
require "../syntax/parser"
require "../syntax/visitor"
require "../iyi_path"

module Iyi::Mod
  record Reach, std : Array(String), prelude : Array(String), links : Array(String), c : Array(String) do
    def self.none : Reach
      new([] of String, [] of String, [] of String, [] of String)
    end

    def empty? : Bool
      std.empty? && prelude.empty? && links.empty? && c.empty?
    end

    # What *self* reaches that *other* does not.
    def -(other : Reach) : Reach
      Reach.new(std - other.std, prelude - other.prelude, links - other.links, c - other.c)
    end

    # What *self* reaches that *allowed* - a `reaches` clause's items - does
    # not let it: the std modules and `File` by name, and `C` for any C the
    # package declares itself, links or functions.
    def beyond(allowed : Array(String)) : Array(String)
      over = std.reject { |name| allowed.includes?(name) }
      over += prelude.reject { |name| allowed.includes?(name) }
      over << "C" if !(links.empty? && c.empty?) && !allowed.includes?("C")
      over
    end

    # `std/file, std/socket; File; links z; C LibZ.zlibVersion`
    def to_s(io : IO) : Nil
      parts = [] of String
      parts << std.join(", ") unless std.empty?
      parts << prelude.join(", ") unless prelude.empty?
      parts << "links #{links.join(", ")}" unless links.empty?
      parts << "C #{c.join(", ")}" unless c.empty?
      parts.empty? ? (io << "nothing outside the language") : parts.join(io, "; ")
    end

    # The package source at *dir*, read.
    def self.of(dir : String) : Reach
      visitor = ReachVisitor.new
      sources(dir).each do |file|
        visitor.read(File.read(file), file)
      end
      own = visitor.reach
      std = Set(String).new
      own.std.each { |imported| std.concat(std_calls_c(imported)) }
      Reach.new(std.to_a.sort!, own.prelude, own.links, own.c)
    end

    @@std_calls_c = {} of String => Set(String)

    # The std modules, *name* among them, that *name* reaches and that
    # declare C functions.
    private def self.std_calls_c(name : String, seen = Set(String).new) : Set(String)
      if known = @@std_calls_c[name]?
        return known
      end
      return Set(String).new unless seen.add?(name)
      found = Set(String).new
      if file = std_file(name)
        visitor = ReachVisitor.new
        visitor.read(File.read(file), file)
        read = visitor.reach
        found << name unless read.c.empty?
        read.std.each { |imported| found.concat(std_calls_c(imported, seen)) }
      end
      @@std_calls_c[name] = found
    end

    # Where `std/x/y` is, on the search path a build resolves it on.
    private def self.std_file(name : String) : String?
      IyiPath.default_paths.each do |entry|
        file = File.join(File.expand_path(entry), "#{name}.iyi")
        return file if File.file?(file)
      end
      nil
    end

    # The `.iyi` files a consumer builds of the package at *dir*.
    def self.sources(dir : String) : Array(String)
      found = [] of String
      Dir.each_child(dir) do |entry|
        full = File.join(dir, entry)
        if File.directory?(full)
          next if entry.starts_with?('.') || entry == "lib"
          next if File.file?(File.join(full, "iyi.mod"))
          found.concat(sources(full))
        elsif entry.ends_with?(".iyi") && !entry.ends_with?("_test.iyi")
          found << full
        end
      end
      found.sort!
    end
  end

  # The prelude's types that reach past the program: `File` reads and
  # writes the file system with no import to show for it.
  PRELUDE_REACH = {"File"}

  # The runtime hooks that are memory, which every program uses.
  ALLOCATOR_HOOKS = {"__iyi_malloc", "__iyi_realloc", "__iyi_free"}

  private class ReachVisitor < Visitor
    @std = Set(String).new
    @prelude = Set(String).new
    @links = Set(String).new
    @c = Set(String).new
    @lib : String? = nil

    def read(text : String, filename : String) : Nil
      parser = Parser.new(text)
      parser.filename = filename
      parser.parse.accept(self)
    rescue CodeError
      # A file that does not parse does not build either, and says why
      # where it is built; its reach is not a question yet.
    end

    def reach : Reach
      Reach.new(@std.to_a.sort!, @prelude.to_a.sort!, @links.to_a.sort!, @c.to_a.sort!)
    end

    def visit(node : ImportDecl) : Bool
      @std << node.path.join('/') if node.path.first? == "std" && node.path.size > 1
      false
    end

    def visit(node : Annotation) : Bool
      if node.path.names.last? == "Link"
        if (first = node.args.first?).is_a?(StringLiteral)
          @links << first.value
        end
        node.named_args.try &.each do |named|
          @links << named.value.as(StringLiteral).value if named.name == "lib" && named.value.is_a?(StringLiteral)
        end
      end
      false
    end

    def visit(node : LibDef) : Bool
      @lib = node.name.names.join("::")
      true
    end

    def end_visit(node : LibDef) : Nil
      @lib = nil
    end

    def visit(node : FunDef) : Bool
      @c << "#{@lib}.#{node.name}" if @lib && !node.real_name.starts_with?("llvm.")
      false
    end

    def visit(node : Call) : Bool
      name = node.name
      if name.starts_with?("__iyi_") && !ALLOCATOR_HOOKS.any? { |hook| name.starts_with?(hook) }
        @c << name
      end
      true
    end

    def visit(node : Path) : Bool
      name = node.names.first?
      @prelude << name if name && node.names.size == 1 && PRELUDE_REACH.includes?(name)
      false
    end

    # Macro text is parsed where the branch is plain code - the
    # `{% if flag?(:win32) %}` around a `lib` - so a platform's C is
    # counted on every platform.
    def visit(node : MacroIf) : Bool
      {node.then, node.else}.each { |branch| read_macro_text(branch) }
      false
    end

    def visit(node : MacroFor) : Bool
      read_macro_text(node.body)
      false
    end

    def visit(node : ASTNode) : Bool
      true
    end

    private def read_macro_text(branch : ASTNode) : Nil
      text =
        case branch
        when MacroLiteral then branch.value
        when Expressions
          String.build do |io|
            branch.expressions.each do |piece|
              case piece
              when MacroLiteral then io << piece.value
              when MacroIf, MacroFor
                piece.accept(self)
              else
                # An interpolation: its text is not known until expansion.
              end
            end
          end
        else
          branch.accept(self)
          return
        end
      read(text, "") unless text.blank?
    end
  end
end
