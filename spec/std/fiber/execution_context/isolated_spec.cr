{% skip_file unless Fiber.has_constant?(:ExecutionContext) %}
require "spec"
require "socket"

describe Fiber::ExecutionContext::Isolated do
  # Upstream's spec for crystal-lang/crystal#17630. `Isolated#wait_for` set
  # `done = true` before it ran the event loop, so a run that returned
  # without the context's fiber - here a write readiness event nobody waits
  # for - resumed the fiber anyway: its read retried with its event still
  # among the fd's waiters, and the next wait crashed in `Waiters#add` (20
  # runs of 20 with the line put back, 0 of 20 without; Linux, 12 vCPU).
  it "waits to read after a write on the same socket" do
    server = TCPServer.new("127.0.0.1", 0)
    client = TCPSocket.new("127.0.0.1", server.local_address.port)
    peer = server.accept
    replies = 0

    ctx = Fiber::ExecutionContext::Isolated.new("request-reply") do
      buf = Bytes.new(4)
      20.times do
        client.write "ping".to_slice
        client.read_fully(buf)
        replies += 1 if buf == "pong".to_slice
      end
    end

    buf = Bytes.new(4)
    20.times do
      peer.read_fully(buf)
      sleep 1.millisecond # let the isolated fiber wait for the reply
      peer.write "pong".to_slice
    end

    ctx.wait
    replies.should eq(20)
  ensure
    peer.try &.close
    client.try &.close
    server.try &.close
  end
end
