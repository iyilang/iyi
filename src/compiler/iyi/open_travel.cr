require "./program"

# iyi: which method bodies cannot cross a boundary as object code, because
# their machine code is the whole program's answer (SPEC.md III.6).
#
# IV.1g says this about blocks and generics: an instantiation the *consumer*
# makes is an instantiation no producer could have emitted, so the body travels
# and the consumer compiles it. This is the same sentence said about **sets**.
#
# A module used as a type is the open case. `@next : HTTP::Handler | Nil` is
# dispatched as one type-id test per including type, and the includers are
# whichever types the build that compiled the test happened to have. A consumer
# writes one middleware of its own, joins that set, and the producer's compiled
# dispatch matches none of its cases — `codegen_dispatch` ends in `unreachable`,
# so what a kemal application did with it was boot and fault on the first
# request. `bench/open_dispatch_fixture/` is the same defect in forty lines.
#
# Two kinds of def are marked here, and the second is why this is a walk rather
# than a predicate:
#
# 1. The one holding the dispatch. Its call is marked during semantic analysis,
#    where the open set is read (`Call#lookup_matches_in`).
# 2. Every def that **calls** one, transitively. A caller compiled by the
#    producer binds to the producer's copy of the callee by name, so its own
#    machine code carries the stale answer one call deep. The closure stops at
#    the boundary: the consumer's own code is compiled by the consumer already.
#
# What "marked" buys is what IV.1g's other cases already buy. The body goes in
# `MonoBodies`, the keep file leaves it alone, so the producer emits no symbol
# for it, and the consumer compiles it against the set *it* has.
#
# **Every callee, because a copy is one too.** The obvious bound is the
# module's own types: everything else is the consumer's to compile, so the
# symbol a shard's object code calls is the consumer's own, compiled against
# the consumer's includers. It is the wrong bound, and IV.1g says why. While a
# module's unit is being emitted, a callee the module does not own is *copied*
# into that unit with internal linkage (`iyi_closure_host`) — so a library
# method with a dispatch in it is in the artifact, holding the producer's set,
# and the only thing that replaces it is a caller that travels.
#
# So the walk follows every call. What that costs was measured rather than
# feared: on kemal's four boundaries, nothing at all — the same 325, 36, 35 and
# 11 bodies as the bounded walk, because what reaches a dispatch there already
# travelled for another reason. On `db` and `sqlite3` it is 45 bodies more out
# of 217, and the gate's wall time does not move. The one place the wide walk
# was expensive was a defect rather than a cost: it turned `ResultSet#read`
# into text, which read a `fun`'s enum as its base type and answered the
# `else` (`Iyi.fun_type`, fixed).
module Iyi::OpenTravel
  # Marks the written defs whose bodies have to travel.
  #
  # Run after semantic analysis and before an artifact is written, on the build
  # that has the typed bodies: the mark is read off a type's own `defs`, which
  # is what the artifact writers walk. A library def marked here is read by
  # nobody — an artifact writer asks only about the methods its own module
  # wrote — and its *callers* in the module are the answer this produces.
  #
  # `IYI_OPEN_TRAVEL=off` writes the boundary the way it was written before this
  # rule, and `=trace` prints the closure. The first is what
  # `bench/open_dispatch.sh` proves the defect with: a gate that cannot fail is
  # not a gate, and the failure here is a program that prints half a line.
  def self.mark(program : Program) : Nil
    return if ENV["IYI_OPEN_TRAVEL"]? == "off"

    Walk.new(program).run
  end

  # The call graph of this build's instantiated defs, in the one direction the
  # question needs: from a callee to the defs that call it.
  private class Walk
    # Instances by object id, so an instance reached twice is walked once.
    @seen = {} of UInt64 => Def
    # Callee instance id => the instances that call it.
    @callers = {} of UInt64 => Array(Def)
    # Instance ids whose machine code answers for an open set.
    @open = Set(UInt64).new

    def initialize(@program : Program)
    end

    def run : Nil
      collect_types @program
      @program.file_modules.each_value { |file_module| collect_types file_module }
      propagate
      record
    end

    # Every type this build made, and every def instance on it.
    #
    # The same walk `TypedDefProcessor` does for the tools, written out here
    # because this one has no target location to stop at: a module's method is
    # instantiated on the *including* type, so the instance that matters is
    # never on the type that declared it — `Kemal::InitHandler^HTTP::Handler#
    # call_next` is `Kemal::InitHandler`'s to carry and `HTTP::Handler`'s to
    # have written.
    private def collect_types(type : Type) : Nil
      if type.is_a?(NamedType) || type.is_a?(Program) || type.is_a?(FileModule)
        type.types?.try &.each_value { |inner| collect_types inner }
      end

      if type.is_a?(GenericType)
        type.each_instantiated_type { |instance| collect_types instance }
      end

      collect_types type.metaclass if type.metaclass != type

      return unless type.is_a?(DefInstanceContainer)
      type.def_instances.each_value { |instance| collect_instance instance }
    end

    # One instance's body, read once: whether it holds an open dispatch, and
    # which instances it calls.
    #
    # A callee is walked from here as well, because an instance is not always in
    # a type's `def_instances` — a block-taking one is instantiated per call site
    # and cached nowhere — and a closure that stopped at those would lose every
    # caller behind one.
    #
    # A worklist rather than recursion: the depth here is the depth of the
    # program's call graph, and a parser's descent is deeper than a stack this
    # runs on cares to be.
    private def collect_instance(root : Def) : Nil
      pending = [root]
      until pending.empty?
        instance = pending.pop
        next if @seen.has_key?(instance.object_id)
        @seen[instance.object_id] = instance

        calls = Calls.new
        instance.body.accept calls

        @open << instance.object_id if calls.open?

        calls.callees.each do |callee|
          # A def read from a `.iyimod` has no body here: its machine code is in
          # somebody else's object code, and its own artifact answered this
          # question when it was written.
          next if callee.iyi_from_artifact?
          # Every other callee is followed, the library's included: while a
          # module's unit is emitted, what it calls is copied into that unit
          # (IV.1g), so a dispatch inside a library method is a dispatch inside
          # the artifact.

          (@callers[callee.object_id] ||= [] of Def) << instance
          pending << callee
        end
      end
    end

    # A caller of an open instance is open: its object code calls the producer's
    # copy by name, and that copy holds the producer's set.
    private def propagate : Nil
      # `IYI_OPEN_TRAVEL=trace` prints the seeds — the instantiations that hold
      # a dispatch over an open set — and then what the closure reached. A
      # boundary that suddenly carries a body as source is read here first.
      trace = ENV["IYI_OPEN_TRAVEL"]? == "trace"
      if trace
        @open.each do |id|
          instance = @seen[id]?
          STDERR.puts "open-dispatch seed: #{describe(instance)}" if instance
        end
      end

      queue = @open.to_a
      until queue.empty?
        callee = queue.pop
        @callers[callee]?.try &.each do |caller|
          next if @open.includes?(caller.object_id)
          @open << caller.object_id
          queue << caller.object_id
          if trace
            STDERR.puts "open-dispatch caller: #{describe(caller)} -> #{describe(@seen[callee]?)}"
          end
        end
      end
    end

    private def describe(instance : Def?) : String
      return "?" unless instance
      "#{instance.owner}##{instance.name} (#{instance.location})"
    end

    # The mark goes on the def as it was *written*, which is the one an artifact
    # writer holds. An instance with no origin is this compiler's own — a
    # `Primitive`, a synthesized `new` — and has no written body to travel.
    private def record : Nil
      @open.each do |id|
        instance = @seen[id]?
        next unless instance

        origin = instance.iyi_origin || instance
        origin.iyi_open_travel = true
        # And by location, because `iyi tool bind` reads a shard through its own
        # record of each method (`BindMethod`) and holds no `Def` by the time it
        # decides what travels. A location names one def in one build.
        origin.location.try { |at| @program.iyi_open_travel_defs << at.to_s }
      end
    end
  end

  # The calls in one body: whether any answered out of an open set, and every
  # instance they reach.
  private class Calls < Visitor
    getter callees = [] of Def
    @open = false

    def open?
      @open
    end

    def visit(node : Call)
      @open = true if node.iyi_open_dispatch?
      node.target_defs.try &.each { |callee| @callees << callee }
      true
    end

    def visit(node)
      true
    end
  end
end
