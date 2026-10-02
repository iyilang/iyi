require "../../spec_helper"

# iyi: what a `when` asks of a value it does not name as a type. A `when`
# holding a range, a tuple of types or a union of types lowers to
# `cond === value`, and `Object#===` is `==`: a range is never equal to an
# integer, nor a class to an instance, so those arms never matched and the
# `case` fell through to `else` without a word. Built with the real prelude,
# since that is where `===` lives.
private def iyi_compiler
  compiler = create_spec_compiler
  compiler.prelude = "iyi/prelude"
  compiler
end

private def run_iyi(name : String, code : String) : String
  File.write "#{name}.iyi", code
  source = Iyi::Compiler::Source.new(File.expand_path("#{name}.iyi"), code)
  iyi_compiler.compile(source, File.expand_path(name))
  Process.capture(File.expand_path(name))
end

describe "Codegen: iyi case equality" do
  it "matches a range arm by inclusion" do
    with_tempdir("iyi-case-range") do
      run_iyi("range", <<-'IYI').should eq("true\nfalse\nhigh\nlow\n")
        puts((1..3) === 3)
        puts((1...3) === 3)
        [5, 1].each do |x|
          case x
          when 0...1 then puts "zero"
          when 1..4 then puts "low"
          when 5..9 then puts "high"
          else puts "none"
          end
        end
        IYI
    end
  end

  it "matches a class against an instance" do
    with_tempdir("iyi-case-class") do
      run_iyi("klass", <<-'IYI').should eq("true\nfalse\ntrue\ntrue\n")
        y = 1 > 0 ? "s" : 1
        puts Int32 === 1
        puts Int32 === y
        puts String === y
        puts Nil === nil
        IYI
    end
  end

  it "matches a tuple of types member by member" do
    with_tempdir("iyi-case-tuple") do
      run_iyi("tuple", <<-'IYI').should eq("nil-bool\nint-str\nequal\n")
        a = 1 > 0 ? nil : 1
        t = {a, false}
        case t
        when {Int32, Bool} then puts "int-bool"
        when {Nil, Bool} then puts "nil-bool"
        else puts "neither"
        end
        u = {1, "s"}
        case u
        when {Int32, String} then puts "int-str"
        else puts "other"
        end
        case u
        when {1, "s"} then puts "equal"
        else puts "unequal"
        end
        IYI
    end
  end

  it "matches a union of types" do
    with_tempdir("iyi-case-union") do
      run_iyi("union", <<-'IYI').should eq("str-or-char\n")
        y = 1 > 0 ? "s" : 1
        case y
        when Int32 | Nil then puts "int-or-nil"
        when String | Char then puts "str-or-char"
        end
        IYI
    end
  end
end
