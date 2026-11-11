require "../spec_helper"
require "./spec_helper"
require "../../src/compiler/iyi/tools/bind"

# `tool bind` rewrites names in text it has printed. Only a path the parser reads is a name:
# what a string, a regex, a comment or a macro literal spells is left as written.
module Iyi
  describe "Literal preservation in bind text rewrites" do
    describe "strip_root" do
      it "leaves plain string literals as written" do
        strip_root(%("Root::X"), "Root", :expression).should eq(%("Root::X"))
        strip_root(%("before Root::X after"), "Root", :expression).should eq(%("before Root::X after"))
      end

      it "leaves percent string literals as written" do
        strip_root(%(%q(Root::X)), "Root", :expression).should eq(%(%q(Root::X)))
        strip_root(%(%Q(Root::X)), "Root", :expression).should eq(%(%Q(Root::X)))
        strip_root(%(%(Root::X)), "Root", :expression).should eq(%(%(Root::X)))
      end

      it "leaves array literals as written" do
        strip_root(%(%w(Root::X Other)), "Root", :expression).should eq(%(%w(Root::X Other)))
        strip_root(%(%i(Root::X Other)), "Root", :expression).should eq(%(%i(Root::X Other)))
      end

      it "leaves regex literals as written" do
        strip_root(%(/Root::X/), "Root", :expression).should eq(%(/Root::X/))
        strip_root(%(%r(Root::X)), "Root", :expression).should eq(%(%r(Root::X)))
      end

      it "reads a slash after an operator, an assignment or a comma as the regex the parser reads" do
        strip_root(%(s =~/Root::Thing/), "Root", :body).should eq(%(s =~/Root::Thing/))
        strip_root(%(x=/Root::Thing/), "Root", :body).should eq(%(x=/Root::Thing/))
        strip_root(%(f(1,/Root::Thing/)), "Root", :body).should eq(%(f(1,/Root::Thing/)))
        strip_root(%(a||/Root::X/), "Root", :body).should eq(%(a||/Root::X/))
      end

      it "reads a slash after a local variable as the division the parser reads" do
        source = %(total = 4; half = total /2; label = "a/b"; puts "Root::Thing"; Root::Thing.new)
        strip_root(source, "Root", :body).should eq(%(total = 4; half = total /2; label = "a/b"; puts "Root::Thing"; Thing.new))
      end

      it "leaves comments as written" do
        strip_root("# Root::X\nRoot::Y", "Root", :body).should eq("# Root::X\nY")
      end

      it "leaves heredoc bodies as written" do
        heredoc = "<<-EOF\nRoot::X\nEOF"
        strip_root(heredoc, "Root", :expression).should eq(heredoc)
      end

      it "rewrites code inside string interpolation while preserving the literal surrounding it" do
        source = %("before \#{Root::X} after Root::X")
        strip_root(source, "Root", :expression).should eq(%("before \#{X} after Root::X"))
      end

      it "handles escaped interpolation characters in literals" do
        source = %("before \\\#{Root::X} after")
        strip_root(source, "Root", :expression).should eq(source)
      end

      it "rewrites code in nested interpolation while preserving all literal segments" do
        source = %("outer \#{"inner \#{Root::X} more"} end")
        strip_root(source, "Root", :expression).should eq(%("outer \#{"inner \#{X} more"} end"))
      end

      it "reads a hash inside an interpolation to the brace that closes the interpolation" do
        source = %("before \#{ {x: Root::X, y: {Root::Y}} } after Root::X")
        strip_root(source, "Root", :expression).should eq(%("before \#{ {x: X, y: {Y}} } after Root::X"))
      end

      it "reads a block inside an interpolation to the brace that closes the interpolation" do
        source = %(puts "\#{names.map { |n| n }.join("Root::")} Root::X")
        strip_root(source, "Root", :body).should eq(source)
      end

      it "handles escaped quotes inside nested interpolation" do
        source = %("a \#{"b \\"nested\\" \#{Root::X}"} c")
        strip_root(source, "Root", :expression).should eq(%("a \#{"b \\"nested\\" \#{X}"} c"))
      end

      it "strips whole segments of a path and nothing shorter" do
        strip_root("Root::Decl::X.new", "Root::Decl", :body).should eq("X.new")
        strip_root("Root::Declared::X.new", "Root::Decl", :body).should eq("Root::Declared::X.new")
        strip_root("RootOther::X.new(Root::X)", "Root", :body).should eq("RootOther::X.new(X)")
      end

      it "leaves a global path, an interior root and the root itself as written" do
        strip_root("::Root::X.new(Root::Y)", "Root", :body).should eq("::Root::X.new(Y)")
        strip_root("Other::Root::X.new(Root::Y)", "Root", :body).should eq("Other::Root::X.new(Y)")
        strip_root("Root.call(Root::Y)", "Root", :body).should eq("Root.call(Y)")
      end

      it "leaves a named argument's label as written" do
        strip_root("call(Root: Root::X)", "Root", :body).should eq("call(Root: X)")
      end

      it "reads a type, a proc notation included" do
        strip_root("Root::A -> Root::B", "Root", :type).should eq("A -> B")
        strip_root("Array(Root::X) | Nil", "Root", :type).should eq("Array(X) | Nil")
        strip_root("Root::X?", "Root", :type).should eq("X?")
        strip_root("Root::X.class", "Root", :type).should eq("X.class")
      end

      it "reads a parameter with its default value, and a block parameter" do
        strip_root(%(tag : Root::Kind = Root::Kind.new("Root::none")), "Root", :parameter)
          .should eq(%(tag : Kind = Kind.new("Root::none")))
        strip_root("&block : Root::A -> Root::B", "Root", :parameter).should eq("&block : A -> B")
        strip_root("*rest : Root::A", "Root", :parameter).should eq("*rest : A")
      end

      it "reads a line of a lib" do
        strip_root("fun open = sqlite3_open(flags : Root::Flag) : Int32", "Root", :fun_line)
          .should eq("fun open = sqlite3_open(flags : Flag) : Int32")
      end

      it "reads text as what it is when the caller named another kind" do
        strip_root("Root::A -> Root::B", "Root", :body).should eq("A -> B")
        strip_root("&block : Root::A -> Root::B", "Root", :type).should eq("&block : A -> B")
      end

      it "reads a body where the parameters of its signature are variables" do
        strip_root("x = x.abs\nRoot::A.new(x)", "Root", :body, ["x : Int32"]).should eq("x = x.abs\nA.new(x)")
        strip_root("n -= 1\nRoot::A.new(n)", "Root", :body, ["n"]).should eq("n -= 1\nA.new(n)")
        strip_root("Root::A.each(&->obj.call)", "Root", :body, ["obj"]).should eq("A.each(&->obj.call)")
        strip_root("yield Root::A.new(x)", "Root", :body, ["x", "&block"]).should eq("yield A.new(x)")
      end

      it "reads a slash after a parameter as the division the parser reads" do
        strip_root(%(half = total /2; puts "Root::A"; Root::A.new), "Root", :body, ["total : Int32"])
          .should eq(%(half = total /2; puts "Root::A"; A.new))
      end

      it "reads a parameter among the parameters beside it" do
        parameters = ["obj : Root::H", "@[Root::Ann] *", "cb : Root::H = ->obj.call", "key : Root::K"]
        strip_root(parameters[1], "Root", :parameter, parameters, 1).should eq("@[Ann] *")
        strip_root(parameters[2], "Root", :parameter, parameters, 2).should eq("cb : H = ->obj.call")
        strip_root(parameters[0], "Root", :parameter, parameters, 0).should eq("obj : H")
        strip_root(parameters[3], "Root", :parameter, parameters, 3).should eq("key : K")
      end

      it "rewrites only the parameter it was given, not the ones beside it" do
        parameters = ["a : Root::A", "b : Root::B = Root::B.new(a)"]
        strip_root(parameters[1], "Root", :parameter, parameters, 1).should eq("b : B = B.new(a)")
      end

      it "leaves the text of a macro literal as written and rewrites a macro expression" do
        source = "{% if flag?(:linux) %}\n  Root::A.call(\"Root::B\")\n{% end %}\n{{ Root::C }}"
        strip_root(source, "Root", :body).should eq("{% if flag?(:linux) %}\n  Root::A.call(\"Root::B\")\n{% end %}\n{{ C }}")
      end

      it "refuses text the parser cannot read rather than rewriting part of it" do
        expect_raises(ArgumentError, "bound text cannot be read as source") do
          strip_root(%[Root::X.new("unterminated Root::Y], "Root", :body)
        end
      end

      it "does not parse text that does not spell the root" do
        strip_root(%("unterminated), "Root", :body).should eq(%("unterminated))
      end
    end

    describe "replace_word" do
      it "replaces a path in code while preserving occurrences in string literals" do
        source = %(Old.new("Old \#{Old} Old"))
        replace_word(source, "Old", "New", :expression).should eq(%(New.new("Old \#{New} Old")))
      end

      it "preserves percent literals, heredocs and regexes" do
        replace_word(%(%q(Old)), "Old", "New", :expression).should eq(%(%q(Old)))
        replace_word(%(/Old/), "Old", "New", :expression).should eq(%(/Old/))
        heredoc = "<<-EOF\nOld\nEOF"
        replace_word(heredoc, "Old", "New", :expression).should eq(heredoc)
      end

      it "replaces a path inside nested interpolations" do
        source = %("a \#{"b \#{Old} c"} d")
        replace_word(source, "Old", "New", :expression).should eq(%("a \#{"b \#{New} c"} d"))
      end

      it "leaves a longer path and a longer name as written" do
        replace_word("Old::X.new(Other::Old, MyOld, Old)", "Old", "New", :expression)
          .should eq("Old::X.new(Other::Old, MyOld, New)")
      end

      it "leaves a named argument's label as written" do
        replace_word("call(Old: Old)", "Old", "New", :expression).should eq("call(Old: New)")
      end
    end
  end
end
