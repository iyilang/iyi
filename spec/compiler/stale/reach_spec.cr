require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/reach"

describe "Iyi::Stale S3e: Reach walk, cross-check, drop per EdgeKind (row 42)" do
  it "compiles without error when no edge is dropped" do
    with_tempfile("reach_ok.key") do |key_path|
      with_tempfile("reach_ok.bin") do |bin_path|
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.stale_key = key_path

        source = Iyi::Compiler::Source.new("reach_ok.iyi", <<-IYI
          module spec/reach_ok
          def add(a : Int32, b : Int32) : Int32
            a + b
          end
          puts add(1, 2)
          IYI
        )

        compiler.compile(source, bin_path)
        File.exists?(key_path).should be_true
        key = File.read(key_path)
        key.should contain(%("mismatch": []))
      end
    end
  end

  it "refuses with reach mismatch when Call edge is dropped" do
    with_tempfile("reach_call.key") do |key_path|
      with_tempfile("reach_call.bin") do |bin_path|
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.stale_key = key_path
        compiler.stale_drop = Iyi::Stale::EdgeKind::Call

        source = Iyi::Compiler::Source.new("reach_call.iyi", <<-IYI
          module spec/reach_call
          def unique_callee_func : Int32
            42
          end
          puts unique_callee_func
          IYI
        )

        expect_raises(Iyi::Error, /reach mismatch/) do
          compiler.compile(source, bin_path)
        end
      end
    end
  end

  it "refuses with reach mismatch when BlockInline edge is dropped" do
    with_tempfile("reach_block.key") do |key_path|
      with_tempfile("reach_block.bin") do |bin_path|
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.stale_key = key_path
        compiler.stale_drop = Iyi::Stale::EdgeKind::BlockInline

        source = Iyi::Compiler::Source.new("reach_block.iyi", <<-IYI
          module spec/reach_block
          def my_inlined(&block : Int32 -> Int32) : Int32
            yield 42
          end
          puts my_inlined { |x| x + 100 }
          IYI
        )

        expect_raises(Iyi::Error, /reach mismatch/) do
          compiler.compile(source, bin_path)
        end
      end
    end
  end

  it "refuses with reach mismatch when ProcLiteral edge is dropped" do
    with_tempfile("reach_proc.key") do |key_path|
      with_tempfile("reach_proc.bin") do |bin_path|
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.stale_key = key_path
        compiler.stale_drop = Iyi::Stale::EdgeKind::ProcLiteral

        source = Iyi::Compiler::Source.new("reach_proc.iyi", <<-IYI
          module spec/reach_proc
          fn = -> { 42 }
          puts fn.call
          IYI
        )

        expect_raises(Iyi::Error, /reach mismatch/) do
          compiler.compile(source, bin_path)
        end
      end
    end
  end

  it "refuses with reach mismatch when Const edge is dropped" do
    with_tempfile("reach_const.key") do |key_path|
      with_tempfile("reach_const.bin") do |bin_path|
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.stale_key = key_path
        compiler.stale_drop = Iyi::Stale::EdgeKind::Const

        source = Iyi::Compiler::Source.new("reach_const.iyi", <<-IYI
          module spec/reach_const
          COMPLEX_CONST = [10, 20, 30]
          puts COMPLEX_CONST.size
          IYI
        )

        expect_raises(Iyi::Error, /reach mismatch/) do
          compiler.compile(source, bin_path)
        end
      end
    end
  end

  it "refuses with reach mismatch when ClassVar edge is dropped" do
    with_tempfile("reach_cvar.key") do |key_path|
      with_tempfile("reach_cvar.bin") do |bin_path|
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.stale_key = key_path
        compiler.stale_drop = Iyi::Stale::EdgeKind::ClassVar

        source = Iyi::Compiler::Source.new("reach_cvar.iyi", <<-IYI
          module spec/reach_cvar
          class CVarHolder
            @@list = [100, 200]
            def self.list
              @@list
            end
          end
          puts CVarHolder.list.size
          IYI
        )

        expect_raises(Iyi::Error, /reach mismatch/) do
          compiler.compile(source, bin_path)
        end
      end
    end
  end

  it "refuses with reach mismatch when IvarInit edge is dropped" do
    with_tempfile("reach_ivar.key") do |key_path|
      with_tempfile("reach_ivar.bin") do |bin_path|
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.stale_key = key_path
        compiler.stale_drop = Iyi::Stale::EdgeKind::IvarInit

        source = Iyi::Compiler::Source.new("reach_ivar.iyi", <<-IYI
          module spec/reach_ivar
          class Box
            @items = [1, 2, 3, 4]
            def items
              @items
            end
          end
          puts Box.new.items.size
          IYI
        )

        expect_raises(Iyi::Error, /reach mismatch/) do
          compiler.compile(source, bin_path)
        end
      end
    end
  end
end
