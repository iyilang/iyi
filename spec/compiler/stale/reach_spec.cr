require "../../spec_helper"
require "../spec_helper"
require "compiler/iyi/compiler"
require "compiler/iyi/stale/reach"
require "compiler/iyi/stale/call_path"
require "compiler/iyi/stale/roots"
require "compiler/iyi/semantic/effects"
require "json"

private def compile_class_var_reach(source : Iyi::Compiler::Source, name : String, owners : Array(String)) : String
  with_tempfile("reach_class_var.key") do |key_path|
    with_tempfile("reach_class_var.bin") do |bin_path|
      compiler = create_spec_compiler
      compiler.prelude = "iyi/prelude"
      compiler.stale_key = key_path

      begin
        compiler.compile(source, bin_path)
      rescue ex : Iyi::Error
        details = String.build do |io|
          io << ex.class << ": " << ex.to_s << "\nClassVar diagnostics for " << name << '\n'
          if program = compiler.program?
            if reach = program.stale_reach
              io << "reach mismatch: " << reach.mismatch << '\n'
              io << "matching elements:\n"
              reach.elements.each do |element|
                next unless element.kind.class_var? && element.key.ends_with?("::#{name}")
                io << "  key=" << element.key << " initializer_class=" << element.node.try(&.class)
                io << " initializer_type=" << element.node.try(&.type?) << " variable_type=" << element.type << '\n'
              end
              io << "comparison set:\n"
              reach.class_vars.each do |cv|
                next unless cv.name == name
                init = cv.initializer.try(&.node)
                io << "  owner=" << cv.owner << " name=" << cv.name
                io << " initializer_class=" << init.try(&.class) << " initializer_type=" << init.try(&.type?)
                io << " variable_type=" << cv.type << '\n'
              end
            else
              io << "reach unavailable\n"
            end
            if recorder = program.stale_recorder
              io << "emitted set:\n"
              recorder.emitted_class_vars.each do |cv|
                next unless cv.name == name
                init = cv.initializer.try(&.node)
                io << "  owner=" << cv.owner << " name=" << cv.name
                io << " initializer_class=" << init.try(&.class) << " initializer_type=" << init.try(&.type?)
                io << " variable_type=" << cv.type << '\n'
              end
            else
              io << "recorder unavailable\n"
            end
          else
            io << "program unavailable\n"
          end
        end
        raise Iyi::Error.new(details, cause: ex)
      end

      reach = compiler.program.stale_reach.not_nil!
      recorder = compiler.program.stale_recorder.not_nil!
      owners.each do |owner|
        key = "#{owner}::#{name}"
        reach.elements.count { |element| element.kind.class_var? && element.key == key }.should eq(1)
        reach.class_vars.count { |cv| "#{cv.owner}::#{cv.name}" == key }.should eq(1)
        recorder.emitted_class_vars.count { |cv| "#{cv.owner}::#{cv.name}" == key }.should eq(1)
      end
      reach.mismatch.should be_empty
      File.exists?(key_path).should be_true
      key = JSON.parse(File.read(key_path))
      key["reach"]["checked"].as_bool.should be_true
      key["reach"]["mismatch"].as_a.should be_empty
      key["local"]["callpath"].as_s
    end
  end
end

private def atomic_class_var_source(seed : Int32, unused : Int32 = 1, opaque : Bool = false) : Iyi::Compiler::Source
  asm_text = opaque ? %(asm("nop"); ) : ""
  unsafe_mark = opaque ? %(@[Unsafe("the initializer-only leaf contains inline assembly for the closure safety test")]\n) : ""
  Iyi::Compiler::Source.new("reach_atomic.iyi", <<-IYI
    #{unsafe_mark}module spec/reach_atomic
    import std/atomic
    class SimpleHolder
      @@waiting = 0_i64
      def self.value
        @@waiting
      end
    end
    class FirstHolder
      def self.reach_leaf : UInt64
        #{asm_text}value = #{seed}_u64; value + 1_u64
      end
      def self.reach_seed : UInt64
        value = self.reach_leaf; value + 1_u64
      end
      @@waiting = Atomic(UInt64).new(self.reach_seed)
      def self.value
        @@waiting.get
      end
    end
    class SecondHolder
      def self.reach_leaf : UInt64
        value = 3_u64; value + 1_u64
      end
      def self.reach_seed : UInt64
        value = self.reach_leaf; value + 1_u64
      end
      @@waiting = Atomic(UInt64).new(self.reach_seed)
      def self.value
        @@waiting.get
      end
    end
    def unused_helper : UInt64
      value = #{unused}_u64; value + 1_u64
    end
    puts SimpleHolder.value
    puts FirstHolder.value
    puts SecondHolder.value
    IYI
  )
end

private def isolated_atomic_reach(seed : Int32 = 1, unused : Int32 = 1, opaque : Bool = false, reverse : Bool = false)
  source = atomic_class_var_source(seed, unused, opaque)
  with_tempfile("reach_atomic_isolated.bin") do |bin_path|
    compiler = create_spec_compiler
    compiler.prelude = "iyi/prelude"
    compiler.no_codegen = true
    program = compiler.compile(source, bin_path).program
    owners = ["Spec::ReachAtomic::SimpleHolder", "Spec::ReachAtomic::FirstHolder", "Spec::ReachAtomic::SecondHolder"]
    vars = owners.map do |owner|
      init = program.class_var_initializers.find { |candidate| candidate.owner.to_s == owner && candidate.name == "@@waiting" }.not_nil!
      init.owner.class_vars[init.name]
    end
    vars.reverse! if reverse
    walk = Iyi::Stale::ReachWalk.new(program)
    vars.each { |var| walk.reach_class_var(var) }
    vars.each { |var| walk.reach_class_var(var) }
    reach = Iyi::Stale::Reach.new(walk.elements, walk.def_names, walk.proc_literals, walk.consts, walk.class_vars)
    roots = Iyi::Stale::Roots.default(program, source.filename, source.code)
    fingerprint = Iyi::Stale::CallPath.compute(program, reach, roots)
    {program, reach, fingerprint, vars}
  end
end

private def initializer_def(reach : Iyi::Stale::Reach, owner : String, name : String) : Iyi::Stale::Element
  reach.elements.find do |element|
    element.kind.def? &&
      element.self_type.try { |type| type.instance_type.to_s } == owner &&
      element.node.as?(Iyi::Def).try(&.name) == name
  end.not_nil!
end

private def initializer_def_key(element : Iyi::Stale::Element) : String
  target = element.node.as(Iyi::Def)
  Iyi::Stale::CallPath.canonical_def_key(target, element.self_type || target.owner)
end

describe "Iyi::Stale S3e: Reach walk, cross-check, drop per EdgeKind (row 42)" do
  {% unless flag?(:win32) %}
    it "reaches Signal.wait class variable initializers without a mismatch" do
      source = Iyi::Compiler::Source.new("reach_signal.iyi", <<-IYI
        module spec/reach_signal
        import std/signal::{Signal}
        group do |g|
          g.spawn { Signal.wait(Signal::INT); 0 }
        end
        IYI
      )
      compile_class_var_reach(source, "@@waiting", ["Std::Signal::SignalWaiter"])
    end
  {% end %}

  it "reaches Atomic class variables with dependent initializers under distinct owners" do
    owners = ["Spec::ReachAtomic::FirstHolder", "Spec::ReachAtomic::SecondHolder"]
    first = compile_class_var_reach(atomic_class_var_source(1), "@@waiting", owners)
    changed = compile_class_var_reach(atomic_class_var_source(2), "@@waiting", owners)
    changed.should_not eq(first)
  end

  it "rejects a dropped Atomic class variable edge" do
    with_tempfile("reach_atomic_drop.key") do |key_path|
      with_tempfile("reach_atomic_drop.bin") do |bin_path|
        compiler = create_spec_compiler
        compiler.prelude = "iyi/prelude"
        compiler.stale_key = key_path
        compiler.stale_drop = Iyi::Stale::EdgeKind::ClassVar

        error = expect_raises(Iyi::Error, /reach mismatch/) do
          compiler.compile(atomic_class_var_source(1), bin_path)
        end
        error.message.to_s.should contain("Spec::ReachAtomic::FirstHolder::@@waiting")
        error.message.to_s.should contain("Spec::ReachAtomic::SecondHolder::@@waiting")
      end
    end
  end

  it "walks each same-named class variable and its own initializer without main" do
    [false, true].each do |reverse|
      _, reach, _, _ = isolated_atomic_reach(reverse: reverse)
      ["SimpleHolder", "FirstHolder", "SecondHolder"].each do |owner|
        key = "Spec::ReachAtomic::#{owner}::@@waiting"
        reach.elements.count { |element| element.kind.class_var? && element.key == key }.should eq(1)
      end
      ["FirstHolder", "SecondHolder"].each do |owner|
        qualified = "Spec::ReachAtomic::#{owner}"
        reach.class_vars.count { |cv| cv.owner.to_s == qualified && cv.name == "@@waiting" }.should eq(1)
        ["reach_seed", "reach_leaf"].each do |name|
          element = initializer_def(reach, qualified, name)
          reach.def_names.includes?(element.key).should be_true
        end
      end
    end
  end

  it "fingerprints an initializer-only leaf but not an unreached helper" do
    _, original, first, _ = isolated_atomic_reach
    _, changed_reach, changed, _ = isolated_atomic_reach(seed: 2)
    _, _, unrelated, _ = isolated_atomic_reach(unused: 2)
    _, _, reversed, _ = isolated_atomic_reach(reverse: true)
    owner = "Spec::ReachAtomic::FirstHolder"
    leaf = initializer_def(original, owner, "reach_leaf")
    changed_leaf = initializer_def(changed_reach, owner, "reach_leaf")
    first.element_digests[initializer_def_key(leaf)].should_not eq(changed.element_digests[initializer_def_key(changed_leaf)])
    first.hex_digest.should_not eq(changed.hex_digest)
    first.hex_digest.should eq(unrelated.hex_digest)
    first.hex_digest.should eq(reversed.hex_digest)
  end

  it "includes initializer-only opaque effects in closure safety" do
    pure_program, pure_reach, _, _ = isolated_atomic_reach
    program, reach, _, _ = isolated_atomic_reach(opaque: true)
    pure = Iyi::Effects.closure_check(pure_program, pure_reach)
    pure.not_reusable.any? { |reason| reason.category == "opaque program construct" && reason.reason == "asm" }.should be_false
    leaf = initializer_def(reach, "Spec::ReachAtomic::FirstHolder", "reach_leaf")
    line = leaf.location.not_nil!.line_number + 1
    closure = Iyi::Effects.closure_check(program, reach)
    closure.not_reusable.any? do |reason|
      reason.category == "opaque program construct" && reason.reason == "asm" &&
        reason.site.to_s.includes?("reach_atomic.iyi:#{line}")
    end.should be_true
  end

  it "retains same-named recorder entries and rejects either missing owner" do
    [false, true].each do |reverse|
      _, _, _, vars = isolated_atomic_reach(reverse: reverse)
      atomic = vars.reject { |cv| cv.owner.to_s == "Spec::ReachAtomic::SimpleHolder" }
      recorder = Iyi::Stale::Recorder.new
      atomic.each { |cv| recorder.record_class_var(cv) }
      emitted = recorder.emitted_class_vars.map { |cv| "#{cv.owner}::#{cv.name}" }.sort
      emitted.should eq(["Spec::ReachAtomic::FirstHolder::@@waiting", "Spec::ReachAtomic::SecondHolder::@@waiting"])
      partial = Iyi::Stale::Reach.new
      partial.class_vars << atomic.first
      partial.cross_check(recorder)
      partial.mismatch.should eq(["#{atomic.last.owner}::#{atomic.last.name}"])
      both = Iyi::Stale::Reach.new
      atomic.each { |cv| both.class_vars << cv }
      both.class_vars.size.should eq(2)
      both.cross_check(recorder)
      both.mismatch.should be_empty
    end
  end

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

  it "observed program with real prelude reaching raise and puts has empty mismatch and no __iyi_effect_ elements" do
    with_tempfile("reach_obs.key") do |key_path|
      with_tempfile("reach_obs.elements.jsonl") do |elements_path|
        with_tempfile("reach_obs.bin") do |bin_path|
          compiler = create_spec_compiler
          compiler.prelude = "iyi/prelude"
          compiler.flags << "iyi_observe"
          compiler.stale_key = key_path
          compiler.stale_dump_elements = elements_path

          source = Iyi::Compiler::Source.new("reach_obs.iyi", <<-IYI
            module spec/reach_obs
            def check_raise(x : Int32) : Int32
              raise "panicked" if x == 0
              x + 1
            end
            puts check_raise(1)
            IYI
          )

          compiler.compile(source, bin_path)
          File.exists?(key_path).should be_true
          key = File.read(key_path)
          key.should contain(%("mismatch": []))
          File.exists?(elements_path).should be_true
          elements = File.read(elements_path)
          elements.should_not contain("__iyi_effect_")
        end
      end
    end
  end
end
