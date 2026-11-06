# Does an exception come out of an `ensure` that parked its fiber while the
# exception was passing through, as the same object with the same callstack?
#
#   ensure_park <shape> <fibers> <rounds> [threads]
#
# On x86_64-windows-msvc an `ensure` used to run inside the C++ catch
# funclet and re-raise with `_CxxThrowException(NULL, NULL)`, which rethrows
# the C++ runtime's per-thread "current exception". A fiber that parks in
# there hands the thread, and that per-thread state, to the next fiber that
# runs on it. The compiler now leaves the funclet first
# (src/compiler/iyi/codegen/exception.cr).
#
# Run by bench/ensure_park.sh, which also builds this file with the old
# funclet codegen and requires that copy to abort. Exits non-zero, naming
# the fiber, if any exception arrives as another object, with a callstack
# captured again, or not at all.
#
# Shapes, each a way an `ensure` is reached while an exception propagates:
#   yield    `Fiber.yield` in the ensure
#   sleep    `sleep` in the ensure (the event loop's timer)
#   channel  the ensure sends to and receives from another fiber
#   mutex    the ensure takes a mutex the other fibers hold, and yields
#            holding it
#   rescued  a `rescue` that matched raises a second exception, and the
#            ensure parks while that one passes (the rescue_ensure path)
#   missed   a `rescue` that did not match, then the ensure parks
#   nested   an ensure inside an ensure, both parking
#   none     the control: the ensure does not park
class ParkError < Exception
end

class OtherError < Exception
end

# What the ensure saw: the array of return addresses the propagating
# exception had captured, compared by identity afterwards - a callstack
# captured again at the re-raise would be a new array.
class Seen
  property addresses : Array(Void*)? = nil

  def record(ex : Exception) : Nil
    @addresses = ex.callstack.try { |stack| stack.@callstack }
  end
end

SHAPE   = ARGV[0]? || "yield"
FIBERS  = (ARGV[1]? || "8").to_i
ROUNDS  = (ARGV[2]? || "200").to_i
THREADS = (ARGV[3]? || "1").to_i

MUTEX = Mutex.new
PING  = Channel(Int32).new
PONG  = Channel(Int32).new

def park(shape : String) : Nil
  case shape
  when "none"
  when "sleep"
    sleep 50.microseconds
  when "channel"
    PING.send 1
    PONG.receive
  when "mutex"
    MUTEX.synchronize { Fiber.yield }
  else
    Fiber.yield
  end
end

# Raises *ex* (or, for `rescued`, *second*) through an ensure that parks.
def through(shape : String, ex : Exception, second : Exception, seen : Seen) : Nil
  case shape
  when "rescued"
    begin
      raise ex
    rescue ParkError
      raise second
    ensure
      seen.record(second)
      park(shape)
    end
  when "missed"
    begin
      raise ex
    rescue OtherError
      seen.addresses = nil
    ensure
      seen.record(ex)
      park(shape)
    end
  when "nested"
    begin
      begin
        raise ex
      ensure
        park(shape)
      end
    ensure
      seen.record(ex)
      park(shape)
    end
  else
    begin
      raise ex
    ensure
      seen.record(ex)
      park(shape)
    end
  end
end

# The far side of the channel shape: answers every ping.
if SHAPE == "channel"
  spawn(name: "pong") do
    loop do
      PING.receive
      PONG.send 1
    end
  end
end

# The broken copy, built by the Crystal bootstrap, may have no execution
# contexts; it runs on one thread, which needs none.
{% if Fiber.has_constant?(:ExecutionContext) %}
  CONTEXT = THREADS > 1 ? Fiber::ExecutionContext::Parallel.new("ensure_park", THREADS) : nil
{% else %}
  abort "ensure_park: this Crystal has no execution contexts, so no #{THREADS} threads" if THREADS > 1
  CONTEXT = nil
{% end %}
done = Channel(Int32).new(FIBERS)

FIBERS.times do |i|
  body = -> do
    wrong = 0
    ROUNDS.times do |round|
      ex = ParkError.new("boom #{i}.#{round}")
      second = OtherError.new("second #{i}.#{round}")
      expected = SHAPE == "rescued" ? second : ex
      seen = Seen.new
      caught = nil
      begin
        through(SHAPE, ex, second, seen)
      rescue caught_ex
        caught = caught_ex
      end
      addresses = caught.try(&.callstack).try { |stack| stack.@callstack }
      unless caught && caught.same?(expected) && addresses && addresses.same?(seen.addresses)
        wrong += 1
        STDERR.puts "fiber #{i} round #{round}: wanted #{expected.message.inspect}, got #{caught.try(&.message).inspect}" if wrong <= 3
      end
    end
    done.send wrong
  end
  if context = CONTEXT
    context.spawn(name: "park #{i}", &body)
  else
    spawn(name: "park #{i}", &body)
  end
end

bad = 0
FIBERS.times { bad += done.receive }
puts "ensure_park shape=#{SHAPE} fibers=#{FIBERS} rounds=#{ROUNDS} threads=#{THREADS} wrong=#{bad}"
exit(bad == 0 ? 0 : 1)
