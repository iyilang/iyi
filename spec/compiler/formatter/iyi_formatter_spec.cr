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
# assert is that the formatter leaves correct code alone. The two that change
# something are the ones that show it is running at all.
private def assert_iyi_format(input, output = input, file = __FILE__, line = __LINE__)
  it "formats #{input.inspect}", file, line do
    result = Iyi.format("#{input}\n", filename: "spec.iyi")
    result.should eq("#{output}\n"), file: file, line: line
  end
end

describe "Formatter on iyi" do
  # R-1's header, which desugars to two nodes the formatter has to see as one
  # line: the header itself and a module wrapping everything under it.
  assert_iyi_format "module app/greeter"
  assert_iyi_format "module app/nested/deeper"
  assert_iyi_format "module m\n\nimport app/greeter"
  assert_iyi_format "module m\n\nimport app/greeter\nusing app/greeter"
  assert_iyi_format "module m\n\nimport std/list\nusing std/list::{List}"
  assert_iyi_format "module m\n\nimport std/list\nusing std/list::{List, Cons}"

  # A keyword-prefixed segment: `end` and `def` start these names, and the
  # slash after one is what the parser had to take out of the lexer's hands.
  assert_iyi_format "module endpoint/handler"
  assert_iyi_format "module m\n\nimport defs/shared"

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

  # Errors: propagation, recovery, and the panic that takes no default.
  assert_iyi_format "module m\n\nvalue = read(path)!"
  assert_iyi_format "module m\n\nvalue = read(path).or(0)"
  assert_iyi_format "module m\n\nvalue = read(path).or_panic"
  assert_iyi_format "module m\n\ndef f : Nil\n  defer close(handle)\nend"

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
end
