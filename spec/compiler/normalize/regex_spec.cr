require "../../spec_helper"

private def assert_expand_regex_const(from : String, to, *, flags = nil, file = __FILE__, line = __LINE__)
  from_nodes = Parser.parse(from)
  assert_expand(from_nodes, flags: flags, file: file, line: line) do |to_nodes, program|
    const = program.types[to_nodes.to_s].should be_a(Iyi::Const), file: file, line: line
    const.value.to_s.should eq(to.strip), file: file, line: line
  end
end

describe "Normalize: regex literal" do
  describe "StringLiteral" do
    # iyi: the name is the literal's, not the order it was met in. It reaches a
    # linker — a unit reading this constant refers to `~<name>:const_read` —
    # and a boundary carrying `$Regex:0` was read by a consumer that had
    # numbered its own literals from zero too (SPEC.md IV.1g).
    it "expands to a const named after the literal" do
      assert_expand Parser.parse(%q(/foo/)) do |to_nodes, program|
        to_nodes.to_s.should eq Program.regex_const_name("foo", Iyi::RegexOptions::None)
      end
    end

    it "simple" do
      assert_expand_regex_const %q(/foo/), <<-'CODE'
      ::Regex.new("foo", ::Regex::Options.new(0))
      CODE
    end
  end

  describe "StringInterpolation" do
    it "simple" do
      assert_expand %q(/#{"foo".to_s}/), <<-'CODE'
        ::Regex.new("#{"foo".to_s}", ::Regex::Options.new(0))
        CODE
    end
  end

  describe "options" do
    it "empty" do
      assert_expand_regex_const %q(//), <<-'CODE'
      ::Regex.new("", ::Regex::Options.new(0))
      CODE
    end
    it "i" do
      assert_expand_regex_const %q(//i), <<-'CODE'
      ::Regex.new("", ::Regex::Options.new(1))
      CODE
    end
    it "x" do
      assert_expand_regex_const %q(//x), <<-'CODE'
      ::Regex.new("", ::Regex::Options.new(8))
      CODE
    end
    it "im" do
      assert_expand_regex_const %q(//im), <<-'CODE'
      ::Regex.new("", ::Regex::Options.new(7))
      CODE
    end
    it "imx" do
      assert_expand_regex_const %q(//imx), <<-'CODE'
      ::Regex.new("", ::Regex::Options.new(15))
      CODE
    end
  end

  # iyi: a `.iyi` program's literal is `std/regex`'s `Regex.compile`, and
  # iyi's prelude has no other runtime Regex: without the import the expander
  # says so at the literal rather than emitting `::Regex.new` into a program
  # whose Regex is the empty class the compiler pre-declares (SPEC.md III.10,
  # Appendix B #17).
  describe "in an .iyi file" do
    it "names the import it is missing" do
      expect_raises(Iyi::TypeException, "import std/regex::{Regex}") do
        LiteralExpander.new(Program.new).expand(parse(%q(/foo/), filename: "foo.iyi"))
      end
    end

    # iyi: `std/regex` takes `i`, `m` and `x` as `Regex::Options` of the
    # numbers the lexer writes, so a flagged literal is `Regex.compile` with
    # them rather than refused, and the flags are in the constant's name:
    # `/foo/` and `/foo/i` are two constants.
    it "carries a literal's flags to Regex.compile as Options" do
      program = iyi_regex_program
      expander = LiteralExpander.new(program)
      plain = expander.expand(parse(%q(/foo/), filename: "foo.iyi"))
      folded = expander.expand(parse(%q(/foo/i), filename: "foo.iyi"))
      all = expander.expand(parse(%q(/foo/imx), filename: "foo.iyi"))

      plain.to_s.should eq(Program.iyi_regex_const_name("foo"))
      folded.to_s.should eq(Program.iyi_regex_const_name("foo", Iyi::RegexOptions::IGNORE_CASE))
      folded.to_s.should_not eq(plain.to_s)
      all.to_s.should_not eq(folded.to_s)

      program.types[plain.to_s].as(Iyi::Const).value.to_s.should eq(%q(::Std::Regex::Regex.compile("foo")))
      program.types[folded.to_s].as(Iyi::Const).value.to_s.should eq(%q(::Std::Regex::Regex.compile("foo", ::Std::Regex::Regex::Options.new(1))))
      program.types[all.to_s].as(Iyi::Const).value.to_s.should eq(%q(::Std::Regex::Regex.compile("foo", ::Std::Regex::Regex::Options.new(15))))
      program.iyi_regex_constants[folded.to_s].should eq({"foo", Iyi::RegexOptions::IGNORE_CASE})
    end

    it "keeps the name a literal without flags always had" do
      key = "3:foo"
      Program.iyi_regex_const_name("foo").should eq("#{Program::IYI_REGEX_CONST_PREFIX}#{::Crystal::Digest::MD5.hexdigest(key)}")
      Program.iyi_regex_const_name("foo", Iyi::RegexOptions::None).should eq(Program.iyi_regex_const_name("foo"))
    end

    # `#{"f"}` would be folded into the text and cached like any literal, so
    # the interpolation names a call, which is only known when it runs.
    it "carries the flags of an interpolated literal, which is no constant" do
      node = LiteralExpander.new(iyi_regex_program).expand(parse(%q(/#{prefix}oo/m), filename: "foo.iyi"))
      node.to_s.should eq(%q(::Std::Regex::Regex.compile("#{prefix}oo", ::Std::Regex::Regex::Options.new(6))))
    end

    it "refuses a flag std/regex has no option for" do
      literal = Iyi::RegexLiteral.new(Iyi::StringLiteral.new("foo"), Iyi::RegexOptions::Reserved)
      literal.location = Iyi::Location.new("foo.iyi", 1, 1)
      expect_raises(Iyi::TypeException, "`std/regex` has no flag for Reserved") do
        LiteralExpander.new(iyi_regex_program).expand(literal)
      end
    end
  end
end

# A program with a `Std::Regex::Regex` in it, which is what tells the
# expander that `std/regex` was imported.
private def iyi_regex_program : Program
  semantic(<<-CODE).program
    module Std
      module Regex
        struct Regex
        end
      end
    end
    CODE
end
