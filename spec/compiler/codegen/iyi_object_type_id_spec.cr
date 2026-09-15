require "../../spec_helper"

# iyi: dispatch by the object's own type id, under iyi's object layout.
#
# A class carries its id in the word under the object only when something
# reads it there (`gc_layouts.cr`, `iyi_headed?`): a reference union it is a
# member of, or a virtual type over it. The census that decides this walked
# `ClassType`s, and an instantiated generic is not one — so `Array(Any)` in
# `Array(Any) | Hash(Any, Any)` and `Foo(Int32)` under `Foo(Int32)+` were
# laid out headless, and every `is_a?` / `case` / method call that read the
# word read whatever the arena left there. Built with the real prelude, since
# a spec-JIT snippet never has the layout (`iyi_object_layout?`).
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

describe "Codegen: iyi object type id" do
  it "dispatches a case over a recursive union once the value arms narrow it to generic instances" do
    with_tempdir("iyi-union-dispatch") do
      # After `Nil`, `Bool`, `Int64`, `Float64` and `String` are ruled out the
      # value is `Array(Any) | Hash(Any, Any)`, a thin pointer answered by the
      # word under the object.
      run_iyi("dispatch", <<-'IYI').should eq("array\nhash\nnil\n")
        class Any
          getter raw : Nil | Bool | Int64 | Float64 | String | Array(Any) | Hash(Any, Any)

          def initialize(@raw : Nil | Bool | Int64 | Float64 | String | Array(Any) | Hash(Any, Any))
          end
        end

        [Any.new([Any.new(1_i64)] of Any), Any.new({} of Any => Any), Any.new(nil)].each do |any|
          case any.raw
          when Nil then puts "nil"
          when Bool then puts "bool"
          when Int64 then puts "int"
          when Float64 then puts "float"
          when String then puts "string"
          when Array(Any) then puts "array"
          when Hash(Any, Any) then puts "hash"
          end
        end
        IYI
    end
  end

  it "dispatches a virtual call over an instantiated generic's subclass" do
    with_tempdir("iyi-generic-virtual") do
      run_iyi("virtual", <<-'IYI').should eq("bar\nfoo\ntrue\nfalse\n")
        class Foo(T)
          def initialize(@v : T)
          end

          def name
            "foo"
          end
        end

        class Bar(T) < Foo(T)
          def name
            "bar"
          end
        end

        xs = [Bar(Int32).new(1), Foo(Int32).new(2)] of Foo(Int32)
        xs.each { |x| puts x.name }
        xs.each { |x| puts x.is_a?(Bar(Int32)) }
        IYI
    end
  end
end
