# iyi: the language server the editor talks to, which does not compile.
#
# `iyi` carries no collector (SPEC.md III.9): a compiler front end
# allocates for one program, answers, and lets the process exit hand the
# memory back. That is the right trade for a verb and the wrong one for a
# server, and the difference was measured, not guessed: forty edits and
# hovers on a ten-line file took one server from 87 MB to 1.6 GB, and a
# hundred and fifty `references` over `std/big` reached 19 GB, at which
# point the kernel killed it mid-session.
#
# So `iyi lsp` is two processes, and neither of them is asked to do
# something it is bad at:
#
#   the proxy (this file)  speaks the protocol, keeps the open buffers,
#                          and never builds a program — its memory is the
#                          text the person has open and nothing else
#   the worker (`Server`)  compiles, answers, and is replaced; every byte
#                          it allocated goes back to the kernel when it
#                          exits, which is the same bargain `iyi build`
#                          makes
#
# A worker is retired when the wire goes quiet (`RETIRE_IDLE`) or after
# `RETIRE_AFTER` requests, never while a request of its own is in flight
# — so the code lens that runs the person's program is not killed
# half-way, and the replacement is warmed while nobody is typing. Its
# successor is handed the buffers with `iyi/adopt` and asked for the
# focused file's verdict, which is the state the dead one had.
#
# This is the shape `iyi daemon` already uses for builds — analyse once,
# fork per build, let the child's exit do the freeing (IV.1d) — and the
# same reason: a process that must forget is easier to trust than a
# process that must remember to forget.
#
# Two properties fall out of the split, and both are worth as much as
# the memory:
#
#   * a front-end crash is one bad answer instead of a dead session. The
#     worker's death is reported to whoever was waiting, its successor
#     starts on the next request, and the person keeps typing.
#   * the server the worker runs is *exactly* today's server. The proxy
#     parses four notifications and two requests and relays everything
#     else as bytes — malformed frames included, so the protocol's
#     refusals still come from the one place that implements them.
require "json"
require "./text"

module Iyi::Lsp
  class Proxy
    # What a worker may cost before it is replaced, in resident
    # megabytes, as the worker itself reports it (`iyi/footprint`). The
    # number is measured, not chosen: one compile of a mid-sized module
    # costs a collector-free front end about 39 MB and never gives it
    # back, a fresh worker starts at about 90 MB, and replacing one
    # costs a fifth of a second — so half a gigabyte buys ten edits per
    # retirement, and the person's session holds at half a gigabyte
    # instead of reaching 1.6 GB in forty edits, which is what a single
    # process was measured doing.
    RETIRE_FOOTPRINT = 512

    # The bound where there is no `getrusage` to read (Windows): a count
    # of requests, assuming the worst of each. Cruder on purpose — a
    # bound that is always there beats a measure that sometimes is.
    RETIRE_AFTER = 24

    # Quiet on the wire before the successor is warmed. Long enough that
    # a typing burst is not interrupted, short enough that a coffee
    # leaves a fresh worker behind — and the replacement's first compile
    # is paid out of the silence rather than out of the next keystroke.
    RETIRE_IDLE = 2.seconds

    # The proxy's own requests ride ids no client would send, and their
    # answers are dropped rather than forwarded.
    PRIVATE_ID = "iyi/proxy:"

    # One worker: the process, what it owes, and what it has cost.
    private class Worker
      getter process : Process
      # The ids forwarded to it and not yet answered. A worker with
      # something in flight is never retired — the code lens that runs
      # the person's program is a request too, and killing it half-way
      # would be the proxy losing work to save memory.
      getter outstanding = Set(String).new
      property answered = 0
      # Resident megabytes, as it last said. Zero where the platform has
      # no cheap way to ask.
      property footprint = 0
      # Requests and buffer changes it has seen. A worker that has done
      # nothing is not worth replacing.
      property worked = 0

      def initialize(@process : Process)
      end

      def idle? : Bool
        @outstanding.empty?
      end

      # Has it cost enough to be worth the fifth of a second its
      # successor's first compile takes?
      def spent? : Bool
        @footprint >= RETIRE_FOOTPRINT || (@footprint.zero? && @answered >= RETIRE_AFTER)
      end
    end

    @worker : Worker?
    # uri => text, applied the same way the worker applies it.
    @documents = {} of String => String
    # The handshake, kept verbatim: a fresh worker is the same server
    # with the same client, so it is told what the client said.
    @initialize_frame : Bytes?
    @initialized_frame : Bytes?
    # The document the person is in, so a fresh worker is warmed on the
    # file the next question will be about.
    @focus : String?
    # A successor made on the memory bound whose warm-up waits for the
    # wire to go quiet (`retire`).
    @warm_pending = false

    # The version of each buffer as this proxy has applied it, and the
    # text of the last version a worker called clean.
    #
    # A successor inherits the buffers, and the buffers are not the
    # state its predecessor had: a cursor question in one that does not
    # compile is answered from the last program that did, and nothing
    # crossed the handover to build one from. The last *clean* text is
    # that thing, and the version is what makes it exact — a verdict can
    # arrive about a version the person has already typed past, and
    # pairing it with whatever the buffer holds now would hand over a
    # text that never compiled.
    @versions = {} of String => Int64
    @clean = {} of String => String
    @shut_down = false
    @running = true
    @private_id = 0
    getter exit_code = 0

    def initialize(@input : IO = STDIN, @output : IO = STDOUT)
      @self_exe = Process.executable_path || "iyi"
    end

    # Editor → here. A fiber reads frames so the loop can also watch the
    # worker and the clock.
    @frames = Channel(Bytes?).new(64)
    # Worker → here, tagged with the worker it came from: a retired
    # worker's last words are not the current one's.
    @answers = Channel({Worker, Bytes?}).new(64)
    # Here → editor. One fiber writes, so a header cannot land inside a
    # body.
    @outbox = Channel(Bytes).new(64)
    # Frames read off the wire while gathering a burst, waiting for
    # their turn, and whether the client's side has ended.
    @pending = Deque(Bytes).new
    @eof = false

    def run : Nil
      spawn do
        while body = @outbox.receive?
          @output << "Content-Length: " << body.bytesize << "\r\n\r\n"
          @output.write body
          @output.flush
        end
      end
      frames = @frames
      spawn do
        loop do
          body = read_frame(@input)
          frames.send body
          break unless body
        end
      end

      while @running
        # Frames the burst-gathering below took off the wire and did not
        # use come first; nothing may overtake them.
        if body = @pending.shift?
          dispatch(body)
          next
        end
        break if @eof
        select
        when body = frames.receive
          break unless body
          dispatch(body)
        when packet = @answers.receive
          worker, body = packet
          next unless worker.same?(@worker)
          if body
            answer(worker, body)
          else
            bury(worker)
          end
        when timeout(RETIRE_IDLE)
          # Nothing on either side for two seconds: the person is
          # reading. Spend it on a fresh worker rather than on their
          # next keystroke - or, when the last one was replaced on the
          # memory bound mid-traffic, on the warm-up that retirement
          # left for the quiet.
          if (worker = @worker) && worker.idle?
            if @warm_pending
              @warm_pending = false
              warm(worker)
            elsif worker.worked > 0
              retire
            end
          end
        end
      end
    ensure
      if worker = @worker
        stop(worker)
      end
      @outbox.close
    end

    # ── The editor's frames ──────────────────────────────────────────────

    private def dispatch(body : Bytes) : Nil
      message = parse(body)
      table = message.try(&.as_h?)
      method = table.try(&.["method"]?).try(&.as_s?)
      params = table.try(&.["params"]?)
      id = table.try(&.["id"]?)

      # The proxy reads what it has to keep and nothing else. Every
      # frame still reaches the worker below, so a method this case
      # does not name is not a method this proxy has to know.
      case method
      when "initialize", "initialized"
        # Kept for a successor to be handed, and kept *after* the frame
        # is forwarded (below): a worker spawned by this very frame must
        # not also be handed a replay of it.
      when "textDocument/didOpen"
        if params && (document = params["textDocument"]?)
          uri = document["uri"].as_s
          @documents[uri] = document["text"].as_s
          @versions[uri] = document["version"]?.try(&.as_i64?) || 0_i64
          @focus = uri
        end
      when "textDocument/didChange"
        if params && (uri = params.dig?("textDocument", "uri").try(&.as_s?))
          text = @documents[uri]? || ""
          changes = [] of JSON::Any
          params["contentChanges"].as_a.each do |change|
            text = Text.apply(text, change)
            changes << change
          end
          # A typing burst is one compile. The worker coalesces its own
          # queue, but it can only coalesce what it has been given, and
          # the proxy is what hands it over — so the burst is gathered
          # here, where the client's stream arrives, and leaves as one
          # frame carrying every change in order. Six keystrokes are six
          # ranges and one verdict, as they were before this proxy
          # existed.
          newest = params
          loop do
            absorb
            break unless queued = @pending.first?
            other = parse(queued).try(&.as_h?)
            break unless other && other["method"]?.try(&.as_s?) == "textDocument/didChange"
            other_params = other["params"]
            break unless other_params.dig?("textDocument", "uri").try(&.as_s?) == uri
            @pending.shift
            newest = other_params
            other_params["contentChanges"].as_a.each do |change|
              text = Text.apply(text, change)
              changes << change
            end
          end
          @documents[uri] = text
          @versions[uri] = newest.dig?("textDocument", "version").try(&.as_i64?) ||
                           (@versions[uri]? || 0_i64) + 1
          @focus = uri
          post(one_change(newest, changes), nil)
          return
        end
      when "textDocument/didSave"
        @focus = params.try(&.dig?("textDocument", "uri")).try(&.as_s?) || @focus
      when "textDocument/didClose"
        if uri = params.try(&.dig?("textDocument", "uri")).try(&.as_s?)
          @documents.delete(uri)
          @focus = nil if @focus == uri
        end
      when "shutdown"
        @shut_down = true
      when "exit"
        # The protocol's own rule: 0 after a `shutdown`, 1 for an `exit`
        # that skipped it. The worker is told too, so it exits for the
        # same reason rather than because a pipe closed.
        @exit_code = @shut_down ? 0 : 1
        post(body, id)
        @running = false
        return
      end

      # Anything that is not an answer may be owed one, and its id is
      # registered so the worker's reply is let through. A frame with an
      # id and no method is usually the client answering the *server* —
      # but it is also how a client asks something malformed, and that
      # gets the protocol's refusal rather than silence. `result` or
      # `error` is what tells the two apart.
      answering = table ? (table.has_key?("result") || table.has_key?("error")) : false
      post(body, id, request: !answering)

      case method
      when "initialize"  then @initialize_frame = body
      when "initialized" then @initialized_frame = body
      end
    end

    # Take whatever the client has already sent, so a burst can be seen
    # as a burst. The millisecond is the server's own trick and it is
    # here for the same reason: the reader rides a fiber, and a purely
    # non-blocking look at the channel finds it empty because that fiber
    # has not had a turn yet. At a thousandth of a compile it does not
    # show, and without it every keystroke is its own verdict.
    private def absorb : Nil
      return if @eof
      frames = @frames
      select
      when body = frames.receive
        if body
          @pending << body
        else
          @eof = true
        end
      when timeout(1.millisecond)
      end
      loop do
        select
        when body = frames.receive
          if body
            @pending << body
          else
            @eof = true
          end
        else
          break
        end
      end
    end

    # One `didChange` carrying a burst's changes in order, addressed to
    # the version the last of them named. The ranges stay ranges: the
    # worker applies them exactly as it would have applied the frames
    # they came in.
    private def one_change(params : JSON::Any, changes : Array(JSON::Any)) : Bytes
      JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "method", "textDocument/didChange"
          json.field "params" do
            json.object do
              json.field "textDocument" { params["textDocument"].to_json(json) }
              json.field "contentChanges" do
                json.array { changes.each(&.to_json(json)) }
              end
            end
          end
        end
      end.to_slice
    end

    # Hand a frame to the worker, spawning one if the last is gone. A
    # request's id is registered first: an answer nobody is waiting for
    # is dropped, which is what makes a replayed handshake invisible to
    # the client. Only the client's *requests* are registered — a frame
    # with an id and no method is the client answering the server, and
    # registering that id would leave the worker for ever busy and so
    # never retired.
    private def post(body : Bytes, id : JSON::Any?, request : Bool = true) : Nil
      worker = @worker
      unless worker
        unless worker = spawn_worker
          # There is no compiler to run any more — the binary this
          # server started from is gone. Saying so is the honest answer;
          # dying is not, because the client is holding open buffers.
          unstartable(id) if id && request
          return
        end
        @worker = worker
        # A worker the session did not start with inherits the session:
        # the handshake it never saw, the buffers, the focused file.
        hand_over(worker) if @initialize_frame
      end
      worker.outstanding << id.to_json if id && request
      worker.worked += 1
      return if write_frame(worker, body)
      # The pipe is gone: the worker died before it read this. Bury it,
      # and give the frame to its successor — the client asked once.
      bury(worker, retry: body, id: id)
    end

    # ── The worker's frames ──────────────────────────────────────────────

    private def answer(worker : Worker, body : Bytes) : Nil
      table = parse(body).try(&.as_h?)

      # The worker saying what it has cost. Not LSP and not the client's
      # business: it is the retirement signal, and it stops here.
      if table && table["method"]?.try(&.as_s?) == "iyi/footprint"
        worker.footprint = table["params"]["megabytes"].as_i
        retire(warm_now: false) if worker.idle? && worker.spent?
        return
      end

      unless table && (id = table["id"]?) && (table.has_key?("result") || table.has_key?("error"))
        # A notification — diagnostics, progress, a log line — or a
        # request the server is making of the client. Whoever the worker
        # is, the client hears it.
        #
        # A clean verdict is also the one thing that says a text
        # compiled, and the successor needs one to answer a cursor
        # question in a buffer that has stopped compiling. Taken only
        # where the version it names is the version this proxy holds:
        # a verdict about a version already typed past says nothing
        # about what the buffer is now. See `@clean`.
        if table && table["method"]?.try(&.as_s?) == "textDocument/publishDiagnostics" &&
           (params = table["params"]?) &&
           (uri = params["uri"]?.try(&.as_s?)) &&
           params["diagnostics"]?.try(&.as_a?).try(&.empty?) &&
           params["version"]?.try(&.as_i64?) == @versions[uri]? &&
           (held = @documents[uri]?)
          @clean[uri] = held
        end
        @outbox.send body
        return
      end

      # An answer carrying `id: null` is the protocol's shape for "the id
      # was inside the frame I could not parse" (-32700). Nobody can be
      # waiting on an id that was never read, and the client is waiting
      # all the same, so it goes through: the rule below is about ids,
      # and this is the absence of one.
      if id.raw.nil?
        @outbox.send body
        return
      end

      key = id.to_json
      waited = worker.outstanding.delete(key)
      # An answer to a question the client did not ask: the proxy's own
      # warm-up, or a replayed `initialize` whose answer the client
      # already has. Dropping it is the whole trick that lets a worker be
      # replaced mid-session — the client's stream is the stream it would
      # have had from one process that never died.
      if waited && !key.starts_with?(%("#{PRIVATE_ID}))
        worker.answered += 1
        @outbox.send body
      end
      retire(warm_now: false) if worker.idle? && worker.spent?
    end

    # A worker's stdout closed. Whoever was waiting is told by the code
    # the protocol has for "the server broke", because the alternative is
    # a client waiting forever for a process that no longer exists.
    private def bury(worker : Worker, retry : Bytes? = nil, id : JSON::Any? = nil) : Nil
      return unless worker.same?(@worker)
      status = worker.process.wait rescue nil
      @worker = nil
      worker.outstanding.each do |key|
        next if key.starts_with?(%("#{PRIVATE_ID}))
        next if retry && id && key == id.to_json
        refuse(key, status)
      end
      post(retry, id) if retry
    end

    # ── Retirement ───────────────────────────────────────────────────────

    # Replace the worker. Only ever called with nothing in flight, so
    # nothing is interrupted and nothing is lost: the successor is handed
    # the buffers and asked for the focused file's verdict, which is the
    # state its predecessor had.
    #
    # The successor is started *before* the predecessor is stopped, and
    # a failure to start is a retirement that does not happen rather than
    # a session that ends. That is not hypothetical: rebuilding `iyi`
    # unlinks the binary under the running server, which the session gate
    # does on purpose, and a retirement a second later would otherwise
    # have taken the editor down with an exception where before there was
    # one warm process that needed nothing from the disk.
    #
    # A retirement on the memory bound happens between two requests, with
    # the next one likely already on the wire: its successor is handed the
    # buffers now and warmed at the next quiet (`@warm_pending`), because
    # a warm-up sent first is a compile the next request waits behind -
    # 0.8 s for an unchanged workspace pull that compiles nothing.
    private def retire(warm_now : Bool = true) : Nil
      return unless old = @worker
      return unless successor = spawn_worker
      @worker = successor
      stop(old)
      hand_over(successor, warm_now)
    end

    # A worker, or nil if this binary can no longer be started.
    private def spawn_worker : Worker?
      process = Process.new(
        @self_exe,
        ["lsp", "--worker"],
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Inherit,
      )
      worker = Worker.new(process)
      answers = @answers
      output = process.output.not_nil!
      spawn do
        loop do
          body = read_frame(output)
          answers.send({worker, body})
          break unless body
        end
      end
      worker
    rescue File::Error | IO::Error | RuntimeError
      nil
    end

    # The handshake, then the buffers, then the file the person is in.
    # The replayed frames are answered to nobody: their ids are not
    # outstanding, so `answer` drops them.
    private def hand_over(worker : Worker, warm_now : Bool = true) : Nil
      if frame = @initialize_frame
        write_frame(worker, frame)
      end
      if frame = @initialized_frame
        write_frame(worker, frame)
      end
      adopt(worker)
      if warm_now
        warm(worker)
      else
        @warm_pending = true
      end
    end

    # Hand over the open buffers without asking for a verdict. A replayed
    # `didOpen` would publish diagnostics the client already has, once
    # per open file; `iyi/adopt` is the same state with no answers.
    private def adopt(worker : Worker) : Nil
      return if @documents.empty?
      frame = JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "method", "iyi/adopt"
          json.field "params" do
            json.object do
              json.field "documents" do
                json.array do
                  @documents.each do |uri, text|
                    json.object do
                      json.field "uri", uri
                      json.field "text", text
                      # The last text a verdict called clean, where the
                      # buffer has stopped compiling since. It is what a
                      # cursor question in one is answered from, and the
                      # successor has no other way to get it.
                      if (clean = @clean[uri]?) && clean != text
                        json.field "clean", clean
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
      write_frame(worker, frame.to_slice)
    end

    # The one compile retirement costs, paid while the wire is quiet
    # rather than on the next keystroke. Its answer is dropped.
    private def warm(worker : Worker) : Nil
      return unless uri = @focus
      key = private_id
      worker.outstanding << key.to_json
      frame = JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id", key
          json.field "method", "textDocument/diagnostic"
          json.field "params" do
            json.object do
              json.field "textDocument" do
                json.object { json.field "uri", uri }
              end
            end
          end
        end
      end
      write_frame(worker, frame.to_slice)
    end

    private def private_id : String
      @private_id += 1
      "#{PRIVATE_ID}#{@private_id}"
    end

    # ── Transport ────────────────────────────────────────────────────────

    # The body of one frame, or nil at end of stream. Headers beyond the
    # length are dropped: the frame this proxy writes carries the length
    # the body has, which is the only header the protocol reads.
    private def read_frame(io : IO) : Bytes?
      length = nil
      while line = io.gets(chomp: false)
        line = line.chomp
        break if line.empty? && length
        next if line.empty?
        if line.starts_with?("Content-Length:")
          length = line.split(':')[1]?.try(&.strip.to_i?)
        end
      end
      return nil unless length
      return nil if length < 0 || length > 64 * 1024 * 1024
      body = Bytes.new(length)
      io.read_fully(body)
      body
    rescue IO::Error
      nil
    end

    private def write_frame(worker : Worker, body : Bytes) : Bool
      io = worker.process.input.not_nil!
      io << "Content-Length: " << body.bytesize << "\r\n\r\n"
      io.write body
      io.flush
      true
    rescue IO::Error
      false
    end

    private def parse(body : Bytes) : JSON::Any?
      JSON.parse(String.new(body))
    rescue
      nil
    end

    # What a client waiting on a dead worker is told. The status is in
    # the message because "the server broke" without a signal number is
    # a bug report nobody can act on.
    private def refuse(key : String, status : Process::Status?) : Nil
      how =
        if status.nil?
          "it is gone"
        elsif status.normal_exit?
          "it exited with #{status.exit_code}"
        else
          "it was killed by signal #{status.exit_reason}"
        end
      frame = JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id" { json.raw key }
          json.field "error" do
            json.object do
              json.field "code", -32603
              json.field "message", "the compile this request ran in did not survive it: #{how}. " \
                                    "The session continues; ask again."
            end
          end
        end
      end
      @outbox.send frame.to_slice
    end

    # And what it is told when there is nothing left to start. Rebuilding
    # `iyi` unlinks the binary a running session started from; the warm
    # worker survives that, a successor cannot be born from it, and this
    # is the honest answer for the window in between. Restoring the
    # binary is all it takes: the next request spawns again.
    private def unstartable(id : JSON::Any) : Nil
      frame = JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id" { id.to_json(json) }
          json.field "error" do
            json.object do
              json.field "code", -32603
              json.field "message", "the compiler this server runs to answer is not there: " \
                                    "#{@self_exe} could not be started. The session is still " \
                                    "here; put the binary back and ask again."
            end
          end
        end
      end
      @outbox.send frame.to_slice
    end

    private def stop(worker : Worker) : Nil
      worker.process.input.try(&.close) rescue nil
      worker.process.terminate rescue nil
      worker.process.wait rescue nil
    end
  end
end
