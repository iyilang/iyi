require "./process_cost"

module Iyi
  # Fine-grained profiling, gated behind IYI_PROF=1.
  # Temporary instrumentation for the compile-speed investigation.
  module Prof
    @@enabled = !ENV["IYI_PROF"]?.nil?
    @@spans = {} of String => Time::Span
    @@order = [] of String

    def self.enabled?
      @@enabled
    end

    # Times a block and accumulates it under `name`.
    def self.span(name : String, &)
      return yield unless @@enabled
      start = Time.instant
      retval = yield
      taken = start.elapsed
      if existing = @@spans[name]?
        @@spans[name] = existing + taken
      else
        @@spans[name] = taken
        @@order << name
      end
      retval
    end

    @@counts = {} of String => Int64
    @@samples = {} of String => Array({String, Time::Span})

    # Method-instantiation census, for sizing what GC-shape stenciling
    # (dictionary-passing generics) would collapse.
    #
    # Totals MUST come from these global sets. Bucketing by anything that
    # already encodes the concrete receiver type (e.g. `Array(Model1)#push`)
    # would partition the data by exact type and hide the very collapsing
    # being measured.
    @@inst_exact = Set(String).new
    @@inst_shape = Set(String).new

    # Breakdown keyed on Def identity, so all instantiations of one generic
    # body land in the same bucket regardless of receiver type.
    # def_object_id => {display name, exact keys, shape keys}
    @@inst_by_def = {} of UInt64 => {String, Set(String), Set(String)}

    def self.instantiation(owner, key, a_def) : Nil
      return unless @@enabled
      o = owner.as(Type)

      exact = String.build do |s|
        s << o << '#' << key.def_object_id << '('
        key.arg_types.each_with_index do |t, i|
          s << ',' if i > 0
          s << t
        end
        s << ")["
        s << (key.block_type.try(&.to_s) || "-")
        s << ']'
      end

      shape = String.build do |s|
        s << o.inst_shape << '#' << key.def_object_id << '('
        key.arg_types.each_with_index do |t, i|
          s << ',' if i > 0
          s << t.inst_shape
        end
        s << ")["
        s << (key.block_type.try(&.inst_shape) || "-")
        s << ']'
      end

      @@inst_exact << exact
      @@inst_shape << shape

      # Display name uses the def's *generic* owner where available, so the
      # label does not vary per instantiation.
      owner = a_def.owner
      display = "#{owner.is_a?(GenericInstanceType) ? owner.generic_type : owner}##{a_def.name}"
      bucket = (@@inst_by_def[key.def_object_id] ||= {display, Set(String).new, Set(String).new})
      bucket[1] << exact
      bucket[2] << shape
    end

    private def self.report_instantiations(io)
      return if @@inst_exact.empty?

      total_exact = @@inst_exact.size
      total_shape = @@inst_shape.size
      ratio = total_shape.zero? ? 0.0 : total_exact / total_shape.to_f

      io.puts
      io.puts "=== INSTANTIATION CENSUS ==="
      io.puts "distinct method instantiations (exact)   : #{total_exact}"
      io.puts "collapsed by GC shape                    : #{total_shape}"
      io.puts "collapse ratio                           : %.2fx" % ratio
      io.puts "eliminated by stenciling                 : #{total_exact - total_shape} (%.1f%%)" % (
        total_exact.zero? ? 0.0 : (total_exact - total_shape) / total_exact.to_f * 100
      )
      io.puts
      io.puts "top 20 generic bodies by instantiation count:"
      io.puts "  %-52s %7s %7s %7s" % {"method", "exact", "shape", "saved"}
      @@inst_by_def.to_a.sort_by! { |_, v| -v[1].size }.first(20).each do |_, v|
        e = v[1].size
        s = v[2].size
        io.puts "  %-52s %7d %7d %6.1f%%" % {v[0][0, 52], e, s, e.zero? ? 0.0 : (e - s) / e.to_f * 100}
      end
    end

    # Times a block and records it as an individual labelled sample under
    # `group`, so the slowest items can be reported.
    def self.sample(group : String, label : String, &)
      return yield unless @@enabled
      start = Time.instant
      retval = yield
      (@@samples[group] ||= [] of {String, Time::Span}) << {label, start.elapsed}
      retval
    end

    def self.count(name : String, by : Int32 = 1)
      return unless @@enabled
      @@counts[name] = (@@counts[name]? || 0_i64) + by
    end

    def self.report(io = STDERR)
      return unless @@enabled
      return if @@order.empty? && @@counts.empty? && @@inst_exact.empty?
      io.puts
      io.puts "=== IYI_PROF ==="
      @@order.each do |name|
        io.puts "#{name.ljust(38)} #{@@spans[name]}"
      end
      @@counts.each do |name, n|
        io.puts "#{name.ljust(38)} #{n}"
      end
      @@samples.each do |group, list|
        total = list.sum(&.[1])
        sorted = list.sort_by { |(_, span)| -span.total_nanoseconds }
        io.puts
        io.puts "--- #{group}: #{list.size} samples, total #{total} ---"
        sorted.first(15).each_with_index do |(label, span), i|
          pct = total.total_nanoseconds.zero? ? 0.0 : span.total_nanoseconds / total.total_nanoseconds * 100
          io.puts "  %2d. %-52s %s (%5.1f%%)" % {i + 1, label[0, 52], span, pct}
        end
        top15 = sorted.first(15).sum(&.[1])
        io.puts "  top 15 = #{top15} of #{total}"
      end
      report_instantiations(io)
      io.flush
    end
  end

  class ProgressTracker
    # FIXME: This assumption is not always true
    STAGES        = 14
    STAGE_PADDING = 34

    property? stats = false
    property? progress = false

    getter current_stage = 1
    getter current_stage_name : String?
    getter stage_progress = 0
    getter stage_progress_total : Int32?

    def stage(name, &)
      @current_stage_name = name

      print_stats
      print_progress

      before = cost if @stats
      time_start = Time.instant
      retval = yield
      time_taken = time_start.elapsed

      print_stats(time_taken, before)
      print_progress

      @current_stage += 1
      @stage_progress = 0
      @stage_progress_total = nil

      retval
    end

    def clear
      return unless @progress
      print " " * (STAGE_PADDING + 5)
      print "\r"
    end

    # What `-s` prints beside a phase's time: the process's resident set when
    # the phase ended, and the processor seconds and page faults the phase
    # itself spent (`ProcessCost`, `Process.times`).
    #
    # It printed `GC.stats.heap_size` until #144, which is zero in a compiler
    # built `-Dgc_none` and so said `( 0.00MB)` after every phase. The heap is
    # not what it reads now, so the column says which number it is, and a
    # figure the platform cannot give is left out rather than printed as zero.
    #
    # Processor time is user plus system across every thread, so a phase that
    # codegens on several threads can spend more of it than its wall time, and
    # one that waits on a child (a macro run, the linker) less. A phase whose
    # processor time is close to a fast run's and whose wall time is not was
    # kept off the processor or waiting on a child; one whose faults went up
    # paid for memory. That is the question #143 left open.
    private record Cost, cpu_seconds : Float64?, faults : Int64?

    private def cost : Cost
      {% if flag?(:wasm32) %}
        Cost.new(nil, ProcessCost.page_faults)
      {% else %}
        times = Process.times
        Cost.new(times.utime + times.stime, ProcessCost.page_faults)
      {% end %}
    end

    def print_stats(time_taken = nil, before : Cost? = nil)
      return unless @stats

      justified_name = "#{current_stage_name}:".ljust(STAGE_PADDING)
      if time_taken
        puts "#{justified_name} #{time_taken}#{cost_column(before)}"
      else
        print "#{justified_name}\r" unless @progress
      end
    end

    private def cost_column(before : Cost?) : String
      after = cost
      parts = [] of String
      if resident = ProcessCost.resident_bytes
        parts << "%8.2fMB rss" % {resident / 1024.0 / 1024.0}
      end
      if (cpu_now = after.cpu_seconds) && (cpu_was = before.try(&.cpu_seconds))
        parts << "%6.2fs cpu" % {cpu_now - cpu_was}
      end
      if (faults_now = after.faults) && (faults_was = before.try(&.faults))
        parts << "%8d page faults" % {faults_now - faults_was}
      end
      parts.empty? ? "" : " (#{parts.join(", ")})"
    end

    def print_progress
      return unless @progress

      if stage_progress_total = @stage_progress_total
        progress = " [#{@stage_progress}/#{stage_progress_total}]"
      end

      stage_name = @current_stage_name.try(&.ljust(STAGE_PADDING))
      print "[#{@current_stage}/#{STAGES}]#{progress} #{stage_name}\r"
    end

    def stage_progress=(@stage_progress)
      print_progress
    end

    def stage_progress_total=(@stage_progress_total)
      print_progress
    end
  end
end
