# iyi: where the loop that reads the client's frames runs.
#
# On Windows the editor's end of stdin is an anonymous pipe, which cannot
# be read overlapped: the read is a plain `ReadFile` that holds its thread
# until bytes arrive. The reader handed each frame to the loop through a
# channel and went straight back into that `ReadFile` - and the loop's
# fiber, woken by the send, was queued on the thread the read now held.
# It ran when another scheduler came to take it, which the runtime's
# monitor does every hundred milliseconds: measured on a twelve-core
# Windows machine, a hover answered from cache took 0 to 96 ms with a
# median of 46, the same answer 1 ms on Linux, where stdin is read
# through the event loop and never holds a thread. On its own thread the
# read holds nothing but itself.
module Iyi::Lsp
  {% if flag?(:win32) && Fiber.has_constant?(:ExecutionContext) %}
    def self.read_loop(name : String, &block : ->) : Nil
      Fiber::ExecutionContext::Isolated.new(name, &block)
    end
  {% else %}
    def self.read_loop(name : String, &block : ->) : Nil
      spawn(&block)
    end
  {% end %}
end
