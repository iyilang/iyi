require "spec"
require "../../../src/compiler/iyi/formatter"

# iyi: the formatter on iyi's own syntax.
#
# The file name is what the difference hangs on. `Iyi.format` hands it to
# the parser, which reads `!` as propagation in a `.iyi` file and as a method
# suffix in a `.cr` one, so a spec that left the name off would be formatting
# a different language from the one it is about.
#
# Every case here is written the way this repository writes it, so what these
# assert is that the formatter leaves correct code alone, and that a second
# pass over what it wrote changes nothing. The cases that change something
# show it is running at all, or that a comment or a trailing space no longer
# decides the layout.
private def assert_iyi_format(input, output = input, file = __FILE__, line = __LINE__)
  it "formats #{input.inspect}", file, line do
    result = Iyi.format("#{input}\n", filename: "spec.iyi")
    result.should eq("#{output}\n"), file: file, line: line
    Iyi.format(result, filename: "spec.iyi").should eq(result), file: file, line: line
  end
end

describe "Formatter on iyi" do
  # R-1's header, which desugars to two nodes the formatter has to see as one
  # line: the header itself and a module wrapping everything under it.
  assert_iyi_format "module app/greeter"
  assert_iyi_format "module app/nested/deeper"
  assert_iyi_format "module m\n\nimport app/greeter"
  assert_iyi_format "module m\n\nimport app/greeter::*"
  assert_iyi_format "module m\n\nimport std/list::{List}"
  assert_iyi_format "module m\n\nimport std/list::{List, Cons}"
  assert_iyi_format "module m\n\nimport std/list ::{List}", "module m\n\nimport std/list::{List}"
  assert_iyi_format "module m\n\nimport app/greeter ::*", "module m\n\nimport app/greeter::*"
  # An `import X::*` alone loads the module and names what it brings; the
  # parser makes the scope half beside it, and the formatter writes what the
  # source says, so the file keeps the one line.
  assert_iyi_format "module m\n\nimport app/greeter::*"
  assert_iyi_format "module m\n\nimport web/dsl::{get, run}\n\nget \"/\" do |env|\n  \"hi\"\nend"
  assert_iyi_format "import app/greeter::*\n\nputs 1"

  # A keyword-prefixed segment: `end` and `def` start these names, and the
  # slash after one is what the parser had to take out of the lexer's hands.
  assert_iyi_format "module endpoint/handler"
  assert_iyi_format "module m\n\nimport defs/shared"

  # A comment or a trailing space after a call's or a def's `(` sits before
  # the line break that puts the arguments on their own lines. A comment
  # there put the first argument at column 0 (a def also lined its later
  # parameters up under the `(`), and `f( ` became `f(1,`.
  assert_iyi_format "x = Planet.new( # c\n  1.5,\n  2.5)"
  assert_iyi_format "def f\n  x = foo( # c\n    1,\n    2)\nend"
  assert_iyi_format "x = foo( # c\n  # first\n  1,\n)"
  assert_iyi_format "foo( # c\n  a: 1,\n  b: 2)"
  assert_iyi_format "def initialize( # c\n  scheme : String? = nil,\n  host : String? = nil,\n)\nend"
  assert_iyi_format "f( \n  1,\n  2)", "f(\n  1,\n  2)"

  # R-2: what a module exports says so.
  assert_iyi_format "module m\n\npub def polite(name : String) : String\n  name\nend"
  assert_iyi_format "module m\n\npub struct Box(T)\n  getter value : T\nend"
  assert_iyi_format "module m\n\npub class Holder\n  @x = 1\nend"
  # Every declaration `pub` takes, one case each, because the formatter needs
  # its own line per declaration and nothing but writing the syntax catches
  # the omission. `pub macro`, `pub CONST` and `pub alias` were each found by
  # a file the formatter refused - the third one under a comment already
  # saying that the second had happened - so the list is checked against the
  # parser's below rather than kept by hand.
  assert_iyi_format "module m\n\npub macro described(declaration)\n  def described : String\n    \"x\"\n  end\nend"
  assert_iyi_format "module m\n\npub LIMIT = 42"
  assert_iyi_format "module m\n\npub import app/greeter"
  assert_iyi_format "module m\n\npub enum Colour\n  Red\n  Green\nend"
  assert_iyi_format "module m\n\npub alias Bytes = Slice(UInt8)"
  assert_iyi_format "module m\n\npub annotation Checker\nend"
  assert_iyi_format "module m\n\npub abstract class Sheet\n  abstract def title : String\nend"
  assert_iyi_format "module m\n\npub abstract struct Shape\n  abstract def area : Int32\nend"
  assert_iyi_format "module m\n\npub abstract def title : String"

  # A comment after `nil?` is the line's, as after `is_a?(T)`: the comment
  # line under `if x.nil? # c` went to column 3, and the one under `raise
  # "x" if pwd.nil? # c` to the column of `pwd`.
  assert_iyi_format "if x.nil? # c\n  # body\n  x = 1\nend"
  assert_iyi_format "while x.nil? # c\n  # body\n  x = 1\nend"
  assert_iyi_format "raise \"x\" if pwd.nil? # c\n# next\nputs 1"

  # A suffix `if`/`unless` on an `if`/`unless` block. The keyword in front
  # was taken for the prefix form: fmt wrote the inner block, asked for
  # `if` at the line break after its condition, and died.
  assert_iyi_format "if true\n  puts 1\nend if false"
  assert_iyi_format "unless false\n  puts 1\nend unless true"
  assert_iyi_format "if a\n  1\nelse\n  2\nend if b"

  # Traits, their supertraits, and the associated types they declare.
  assert_iyi_format "module m\n\npub trait Show\n  abstract def show : String\nend"
  assert_iyi_format "module m\n\npub trait Ord : Cmp\n  abstract def cmp(other : self) : Int32\nend"
  assert_iyi_format "module m\n\npub trait Each\n  type Elem\n\n  abstract def each(& : (Elem -> Nil)) : Nil\nend"

  # R-3: an impl, its target, and the binder that introduces the target's
  # parameters.
  assert_iyi_format "module m\n\nimpl Show for Int32\n  def show : String\n    \"i\"\n  end\nend"
  assert_iyi_format "module m\n\nimpl Show for Box(T) forall T\n  def show : String\n    \"b\"\n  end\nend"
  assert_iyi_format "module m\n\nimpl Show for Box(T) forall T : Show\n  def show : String\n    \"b\"\n  end\nend"
  assert_iyi_format "module m\n\nimpl Each for Nums\n  type Elem = Int32\n\n  def each(& : Int32 -> Nil) : Nil\n  end\nend"

  # A bound on a name the signature mentions rather than introduces (II.6),
  # and one on a name it introduces (II.7).
  assert_iyi_format "module m\n\ndef includes?(value : Elem) : Bool where Elem : Cmp\n  true\nend"
  assert_iyi_format "module m\n\npub def announce(item : T) : String forall T : Greet\n  item.greet\nend"

  # A comment ending a header: the comment lines under it are the body's,
  # where they went to the header's own column after type parameters, a
  # union return type, `forall`, `where`, a supertrait or a `[`/`{`.
  assert_iyi_format "class Box(T) # c\n  # doc\n  def f\n  end\nend"
  assert_iyi_format "pub struct Box(T) # c\n  # doc\n  getter value : T\nend"
  assert_iyi_format "module Foo(T) # c\n  # doc\n  def f\n  end\nend"
  assert_iyi_format "def g : Int32 | Nil # c\n  # body\n  nil\nend"
  assert_iyi_format "class A\n  def self.decode(x) : String | Err # c\n    # body\n    nil\n  end\nend"
  assert_iyi_format "def f(x : T) : Nil where T : Foo # c\n  # body\n  nil\nend"
  assert_iyi_format "impl Show for Box(T) forall T # c\n  # doc\n  def show : String\n    \"x\"\n  end\nend"
  assert_iyi_format "impl Show for Box(T) forall T : Show # c\n  # doc\n  def show : String\n    \"x\"\n  end\nend"
  assert_iyi_format "pub trait Num : Comparable # c\n  # doc\n  abstract def x : Int32\nend"
  assert_iyi_format "x = [ # c\n  # first\n  1,\n]"
  assert_iyi_format "h = { # c\n  # first\n  1 => 2,\n}"

  # A `{` block's or a proc's body that starts on the opener's line and
  # runs over several: a comment ending its last line took the `}` into it,
  # so the block closed nothing, or closed the lines after it.
  assert_iyi_format "[1].each { |i| puts i\nputs 2 # c\n}"
  assert_iyi_format "def f\n  [1].each { |i| puts i\n  puts 2 # c\n  }\nend"
  assert_iyi_format "x = -> { puts 1\nputs 2 # c\n}\nx.call"
  assert_iyi_format "x = -> do puts 1\nputs 2 # c\nend\nx.call"

  # Errors: propagation, recovery, and the panic that takes no default.
  assert_iyi_format "module m\n\nvalue = read(path)!"
  # A short block's call can propagate: `&.close!`, `&.size!.succ`.
  assert_iyi_format "module m\n\nxs.each(&.close!)"
  assert_iyi_format "module m\n\nxs.map(&.size!.succ)"
  assert_iyi_format "module m\n\nvalue = read(path).or(0)"
  assert_iyi_format "module m\n\nvalue = read(path).or_panic"
  assert_iyi_format "module m\n\ndef f : Nil\n  defer close(handle)\nend"
  # Recovery on the line under its call, as a call chain is broken.
  assert_iyi_format "module m\n\nvalue = read(path)\n  .or(0)"
  assert_iyi_format "module m\n\nvalue = read(path)\n  .or_panic"

  # asm: a comment after an operand section keeps the next section under
  # the first colon, where it went to column 1; a comment line between two
  # sections stays on its line there, where it went up to the line before
  # with a blank line after it, and a second pass moved the section again.
  assert_iyi_format "def f\n  asm(\"cpuid\" : \"={rax}\"(leaf) # c\n              : \"{rax}\"(1_u64))\nend"
  assert_iyi_format "def f\n  asm(\"cpuid\" : \"={rax}\"(leaf)\n              : \"{rax}\"(1_u64)\n# c\n              : \"rbx\")\nend",
    "def f\n  asm(\"cpuid\" : \"={rax}\"(leaf)\n              : \"{rax}\"(1_u64)\n              # c\n              : \"rbx\")\nend"

  # And the list itself, held against the parser's, because a case per
  # declaration only helps while the cases are all of them. `parse_pub` is
  # the one place that decides what `pub` takes; a keyword added there
  # without a formatter case fails here instead of in somebody's file.
  it "covers every declaration `pub` takes" do
    source = File.read(File.expand_path("../../../src/compiler/iyi/syntax/parser.cr", __DIR__))
    body = source[source.index!("def parse_pub")..]
    body = body[..body.index!("\n    def ", 1)]
    taken = body.scan(/Keyword::([A-Z]+)/).map(&.[1].downcase).to_set

    # `const` has no keyword in front of it - `pub LIMIT = 42` is the name
    # itself - so it is not in the parser's `case` and is covered by the line
    # above all the same.
    covered = Set{"trait", "import", "def", "class", "struct", "macro",
                  "enum", "alias", "annotation", "abstract"}

    (taken - covered).should be_empty
    (covered - taken).should be_empty
  end

  # Aligned comments move the comments, not the code: the `)` after a
  # comment on an earlier argument's line was written `bbbbbbbb  )`.
  assert_iyi_format "begin\n  f(a,        # c\n    bbbbbbbb) # d\nend           # e"

  # The samples, twice: a formatter that is not a fixed point rewrites a
  # file on every save, and the samples are the tree's own code, so the
  # second pass has to be a no-op over every one. Then the same files with
  # their indentation destroyed: what comes out is the file in the tree,
  # which is what "canonical" means. Lines inside a multi-line string are
  # left as they are, because they are the string.
  it "is a fixed point over the samples, and canonical from ruined indentation" do
    Dir.glob(File.expand_path("../../../samples/iyi/*.iyi", __DIR__)).sort.each do |path|
      source = File.read(path)
      once = Iyi.format(source, filename: path)
      once.should eq(source), "#{path} is not formatted as the tree keeps it"
      Iyi.format(once, filename: path).should eq(once), "#{path} is not a fixed point"

      ruined = String.build do |io|
        in_string = false
        n = 0
        source.each_line(chomp: false) do |line|
          n += 1
          if in_string
            io << line
          else
            io << " " * (n % 7) << line.lstrip(" \t")
          end
          quotes = line.gsub("\\\"", "").count('"')
          in_string = !in_string if quotes.odd?
        end
      end
      Iyi.format(ruined, filename: path).should eq(source), "#{path} did not come back from ruined indentation"
    end
  end

  # Comments line up where a terminal draws them, a wide character taking
  # two cells: counted one each, the first `#` here sat two cells right.
  assert_iyi_format "x = \"日本\" # c\nyy = \"ab\"  # d"

  # Running at all: these two are wrong on the way in and right on the way out.
  assert_iyi_format "module m\n\npub    def   polite(name : String) : String\n  name\nend",
    "module m\n\npub def polite(name : String) : String\n  name\nend"
  assert_iyi_format "module m\n\nimpl Show    for    Int32\n  def show : String\n    \"i\"\n  end\nend",
    "module m\n\nimpl Show for Int32\n  def show : String\n    \"i\"\n  end\nend"

  # A macro body is formatted by a second formatter over its text, and the
  # text used to be handed over with no name — so `!` was read by the other
  # language's rules, the body did not parse, and the rescue put it back
  # exactly as it was typed. A macro whose body used iyi's own operator was
  # the one macro the formatter left alone.
  assert_iyi_format "module m\n\nmacro twice\n v = read()!\n   puts v\n  end",
    "module m\n\nmacro twice\n  v = read()!\n  puts v\nend"
  assert_iyi_format "module m\n\nmacro plain\n v = 1\n   puts v\n  end",
    "module m\n\nmacro plain\n  v = 1\n  puts v\nend"

  # A macro body that starts with a blank line and then a line at column 0
  # was "there's a bug formatting": the parser's line break took the blank
  # line, and the formatter's handed it back as text the parser has no node
  # for.
  assert_iyi_format "macro m\n\n{{ 1 }}\nend"
  assert_iyi_format "macro m\n\n{% if true %}puts \"yes\"{% end %}\nend"
  assert_iyi_format "macro twice(x)\n\n# c\n  {{x}}\nend"
end
