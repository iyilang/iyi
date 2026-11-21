require "../../spec_helper"

# iyi: a program built against iyi's prelude, from a `.iyi` file on disk,
# so its `import std/regex` resolves to the real module.
private def run_iyi(name : String, code : String) : String
  compiler = create_spec_compiler
  compiler.prelude = "iyi/prelude"
  File.write "#{name}.iyi", code
  source = Iyi::Compiler::Source.new(File.expand_path("#{name}.iyi"), code)
  compiler.compile(source, File.expand_path(name))
  Process.capture(File.expand_path(name))
end

describe "Code gen: regex literal spec" do
  it "works in a class variable (#10951)" do
    run(<<-CODE).to_b.should be_true
      require "prelude"
      class Foo
        @@regex = /whatever/

        def self.check_regex
          @@regex == /whatever/
        end
      end
      Foo.check_regex
      CODE
  end

  # #215: a literal a macro wrote is in the file that expanded it, whose
  # `import std/regex` it sees: inside `{% if %}`, `{% for %}`, a `macro`
  # def's body and a class body's `{% begin %}` (an instance variable's
  # initializer, whose type is guessed from the literal) it was the other
  # library's `::Regex.new(..., ::Regex::Options.new(0))` and refused as
  # `undefined constant ::Regex::Options`, while the same literal outside
  # the macro compiled.
  it "is std/regex's inside a macro expansion in an iyi program (#215)" do
    with_tempdir("iyi-regex-macro") do
      run_iyi("macro", <<-'IYI').should eq("x\nx\ncpu,-\nyz\n2\n")
        import std/regex::{Regex}

        def outside(text : String) : String
          text.sub(/^model name\s*:\s*/, "")
        end

        def inside(text : String) : String
          {% if flag?(:win32) %}
            text
          {% else %}
            text.sub(/^model name\s*:\s*/, "")
          {% end %}
        end

        def words(text : String) : String
          found = [] of String
          {% for w in ["cpu", "mhz"] %}
            found << (text =~ /{{ w.id }}/i ? {{ w }} : "-")
          {% end %}
          found.join(",")
        end

        macro strip_xs(text)
          {{ text }}.sub(/^x+/, "")
        end

        class Probe
          {% begin %}
            @pattern = /b+/
          {% end %}

          def find(text : String) : Int32?
            text =~ @pattern
          end
        end

        puts outside("model name : x")
        puts inside("model name : x")
        puts words("CPU 4")
        puts strip_xs("xxyz")
        puts Probe.new.find("aabb")
        IYI
    end
  end
end
