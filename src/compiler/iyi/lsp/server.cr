# iyi: `iyi lsp` — the language server SPEC.md III.8 #2 said R-1 makes
# nearly free, built as exactly that.
#
# A language server for an open-class language keeps an incremental model
# of the whole program and prays its invalidation story is right. iyi's
# unit is the module, compiled alone against its imports' *declarations*,
# so this server keeps **no semantic state at all**: every request runs
# the real front end on the module under the cursor — the same code, the
# same errors, the same answers a build would give — and is fast because
# the language made the unit small, not because a cache is guessing.
#
# What it speaks (LSP 3.17, the subset that earns its keep):
#
#   textDocument/didOpen · didChange · didSave · didClose — incremental
#     sync; every change publishes diagnostics from a real compile of the
#     buffer, unsaved and half-broken included
#   textDocument/hover          — the name's type, the def's signature
#     and doc comment
#   textDocument/definition     — where the call or type is defined
#   textDocument/typeDefinition — where the name's *type* is declared
#   textDocument/documentSymbol — the file's outline, from the parser
#   textDocument/documentHighlight · foldingRange · workspace/symbol
#   textDocument/completion     — the scope fuzzy-ranked, plus the
#     workspace's exports, their `import`/`using` pair riding as edits
#   textDocument/references · rename (with prepare) — workspace-wide
#   textDocument/signatureHelp  — overloads while the call is half-typed
#   textDocument/formatting     — the formatter, in process
#   textDocument/inlayHint      — inferred types and parameter names
#   textDocument/codeAction     — the compiler's own "did you mean",
#     made clickable
#   textDocument/semanticTokens — highlighting from the lexer, so any
#     client colors iyi with no grammar installed
#   textDocument/implementation — from a trait to its implementors
#   textDocument/prepareCallHierarchy · incomingCalls · outgoingCalls
#   textDocument/selectionRange — expand-selection off the parse tree
#   textDocument/diagnostic · workspace/diagnostic — the pull shape:
#     one buffer, or the whole project's verdict, on request
#
# And two methods no other server has, because no other language wrote
# its interfaces down (AI_FIRST.md §2):
#
#   iyi/contextPack — the grounding pack for a file: every import's exact
#     exported surface, no bodies; what a model reads before editing
#   iyi/surface     — one module's rendered surface, doc comments included
#
# Diagnostics carry the house style as data: when the message cites a
# SPEC section, the section rides in `code` and `codeDescription` links
# to the spec itself. An error that names its rule is an error an editor
# can teach with.
#
# Unsaved sibling buffers reach the compiler as `iyi_file_overrides`:
# one hash of path → buffer the resolver and `import_file` consult
# before the disk, so an import finds what the person sees, saved or
# not. No shadow tree, no virtual file system — the same resolution a
# build does, reading a buffer where it would have read the file.
require "json"
require "uri"
require "./analysis"
require "./outline"
require "./tokens"
require "./exports"
require "../tools/formatter"
require "./text"
require "./footprint"

module Iyi::Lsp
  class Server
    @documents = {} of String => String # uri => current text
    # The last published diagnostics, kept for codeAction to read back:
    # {line0, start_ch, end_ch, message, suggestion} per document.
    @published = {} of String => Array({Int32, Int32, Int32, String, String?})
    @root : String?
    @running = true
    # Set by `shutdown`. After it, the protocol says every request but
    # `exit` is answered -32600: a client that keeps asking is asking a
    # server that has agreed to stop, and an empty answer would read as
    # "nothing there" instead.
    @shut_down = false
    # Set by `initialize`. Before it, the protocol says a request is
    # answered -32002 and a notification is dropped, `exit` aside.
    @initialized = false
    # What the process exits with: the protocol says 0 after a `shutdown`
    # and 1 for an `exit` that skipped it, and a client that reads the
    # code is told which conversation it had.
    getter exit_code = 0
    @analysis = Analysis.new
    # Messages the reader fiber has queued while a compile ran, and the
    # ids the client cancelled. One thread does the work; the queue is
    # what lets a cancel overtake the work it cancels.
    @inbox = Deque(JSON::Any).new
    @cancelled = Set(String).new
    @eof = false
    # Whether the client renders snippets, said at initialize.
    @snippets = false
    # The last semantic-token stream per document, for delta answers.
    @token_result = 0
    @token_data = {} of String => {String, Array(Int32)}

    # Captured at startup, before a rebuild can unlink the binary out
    # from under a running session: `$ORIGIN` is pinned for the
    # compiler's own library path, and the executable's path is kept
    # for the verbs the server re-runs as itself.
    @self_exe : String?

    def initialize(@input : IO = STDIN, @output : IO = STDOUT)
      IyiPath.origin
      @self_exe = Process.executable_path
    end

    # The reader rides its own fiber, so the queue fills while a compile
    # runs. That buys the two behaviours a synchronous server cannot
    # otherwise have: a `$/cancelRequest` for *queued* work is seen
    # before the work starts (in-flight work stays uninterruptible —
    # the honest limit of one thread), and a typing burst coalesces
    # into one compile instead of queueing one per keystroke.
    def run : Nil
      messages = Channel(JSON::Any?).new(64)
      @messages = messages
      spawn do
        loop do
          message = read_message
          messages.send message
          break unless message
        end
      end

      while @running
        drain(messages)
        sweep_cancels
        unless message = @inbox.shift?
          break if @eof
          next
        end
        if (id = message["id"]?) && @cancelled.delete(id.to_json)
          respond_cancelled(id)
          next
        end
        handle(message)
        report_footprint
      end
    end

    # What this process has cost, last time it said so, and the step
    # that is worth saying. `Lsp::Proxy` listens for this and replaces a
    # worker that has grown enough: a front end with no collector cannot
    # give the memory back, so the only way to bound a session is for
    # the process to end, and the only one who knows when that is due is
    # the process. Thirty-two megabytes keeps the wire quiet — a session
    # of pure hovers on unchanged text never says anything at all.
    FOOTPRINT_STEP = 32
    @footprint_said = 0

    private def report_footprint : Nil
      now = Lsp.footprint
      return if now < @footprint_said + FOOTPRINT_STEP
      @footprint_said = now
      notify("iyi/footprint") do |json|
        json.object { json.field "megabytes", now }
      end
    end

    # The reader's channel, kept so work that runs long can look up from
    # it: `workspace/diagnostic` walks the project a file at a time and
    # reads the inbox between them.
    @messages : Channel(JSON::Any?)?

    # A verb the editor asked to run, finished. `iyi.run` launches the
    # person's own program, which may serve forever; its fiber watches
    # it and hands the answer back here, so the reply is still written
    # by the loop and one frame cannot land inside another.
    record Finished, id : JSON::Any, ok : Bool, output : String, error : String
    @finished_verbs = Channel(Finished).new(RUNS_IN_FLIGHT)
    @running_verbs = 0

    # Take whatever has arrived, and register the cancels among it. Safe
    # to call from inside a handler: it only moves messages from the
    # channel into the queue the loop reads.
    #
    # The millisecond is not politeness, it is the whole mechanism. The
    # reader rides a fiber parked on stdin, and a compile yields to
    # nothing, so a purely non-blocking peek at the channel finds it
    # empty however long the walk runs — measured: the pull noticed a
    # waiting hover eight seconds after it arrived. Waiting on the
    # channel with a deadline is the trip through the event loop that
    # wakes the reader; at a tenth of a file's compile it does not show.
    private def absorb_pending : Nil
      return unless messages = @messages
      return if @eof
      select
      when message = messages.receive
        if message
          @inbox << message
        else
          @eof = true
        end
      when finished = @finished_verbs.receive
        answer_verb(finished)
      when timeout(1.millisecond)
      end
      loop do
        select
        when message = messages.receive
          if message
            @inbox << message
          else
            @eof = true
          end
        when finished = @finished_verbs.receive
          answer_verb(finished)
        else
          break
        end
      end
      sweep_cancels
    end

    # Block for the first message only; take the rest without waiting.
    private def drain(messages : Channel(JSON::Any?)) : Nil
      if @inbox.empty? && !@eof
        select
        when message = messages.receive
          if message
            @inbox << message
          else
            @eof = true
          end
        when finished = @finished_verbs.receive
          answer_verb(finished)
        end
      end
      loop do
        select
        when message = messages.receive
          if message
            @inbox << message
          else
            @eof = true
          end
        when finished = @finished_verbs.receive
          answer_verb(finished)
        else
          break
        end
      end
    end

    # A cancel's position in the queue is irrelevant — it names its
    # target by id — so register them all before touching real work.
    # The set is bounded: a cancel that arrived too late names an id
    # that was already answered, and its key would otherwise live
    # forever.
    private def sweep_cancels : Nil
      @inbox.reject! do |queued|
        next false unless queued["method"]?.try(&.as_s?) == "$/cancelRequest"
        if cancel_id = queued["params"]?.try(&.["id"]?)
          @cancelled << cancel_id.to_json
        end
        true
      end
      @cancelled.clear if @cancelled.size > 256
    end

    private def respond_cancelled(id : JSON::Any) : Nil
      send(JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id" { id.to_json(json) }
          json.field "error" do
            json.object do
              json.field "code", -32800
              json.field "message", "the client cancelled the request"
            end
          end
        end
      end)
    end

    # ── Transport: Content-Length framed JSON-RPC over stdio ────────────

    # The server's whole value is being there on the next keystroke, so
    # the transport forgives what it can: a stray blank line is not a
    # frame, a header that does not parse is skipped, a body that is
    # not JSON is dropped and the stream continues. Only true EOF — or
    # a length too absurd to read — ends the session.
    private def read_message : JSON::Any?
      loop do
        length = nil
        while line = @input.gets(chomp: false)
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
        @input.read_fully(body)
        parsed =
          begin
            JSON.parse(String.new(body))
          rescue
            nil
          end
        # JSON, but not a message: `[]` parsed, and `message["method"]?`
        # on an array raised outside every rescue - one frame took the
        # server down with a backtrace. The loop reads a message as an
        # object; anything else is told so with the protocol's code.
        return parsed if parsed && parsed.as_h?
        return JSON.parse(%({"method": "$/invalidRequest"})) if parsed
        # Not JSON: the frame is dropped, the session is not — and the
        # client is told, because the request it is waiting on is inside
        # that frame and it would wait forever otherwise. `iyi mcp` has
        # answered -32700 all along; this side said nothing at all.
        #
        # Handed back as a message rather than written from here: this
        # runs on the reader fiber, and every byte on the wire is written
        # by the loop that handles messages. Two writers would interleave
        # a header with a body.
        return JSON.parse(%({"method": "$/parseError"}))
      end
    rescue IO::EOFError
      nil
    end

    private def send(payload : String) : Nil
      @output << "Content-Length: " << payload.bytesize << "\r\n\r\n" << payload
      @output.flush
    end

    private def respond(id : JSON::Any, & : JSON::Builder -> _) : Nil
      send(JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id" { id.to_json(json) }
          json.field "result" { yield json }
        end
      end)
    end

    private def respond_null(id : JSON::Any) : Nil
      respond(id, &.null)
    end

    private def notify(method : String, & : JSON::Builder -> _) : Nil
      send(JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "method", method
          json.field "params" { yield json }
        end
      end)
    end

    # ── Dispatch ─────────────────────────────────────────────────────────

    private def handle(message : JSON::Any) : Nil
      method = message["method"]?.try(&.as_s?)
      id = message["id"]?
      params = message["params"]?

      # After `shutdown` the session is over but the process is not: the
      # client owes an `exit` and nothing else, and anything it does send
      # is answered by the code the protocol has for it rather than with
      # an empty result that reads as an answer.
      if @shut_down && id && method != "exit"
        respond_error(id, -32600, "the server has shut down; only `exit` is left")
        return
      end

      # A request with no `method` is not a method that is missing, it is
      # not a request; it used to get nothing, and the client waited.
      if method.nil? && id
        respond_error(id, -32600, "invalid request: no method")
        return
      end

      # Before `initialize`, the protocol's word for a request is -32002,
      # and a notification is dropped; `exit` is the one thing allowed.
      # A definition asked before the handshake used to be answered as if
      # the root were the working directory, which it may not be.
      unless @initialized || method.in?("initialize", "exit", "$/parseError", "$/invalidRequest")
        respond_error(id, -32002, "the server is not initialized: `initialize` comes first") if id
        return
      end

      case method
      when "$/parseError"
        # The reader could not parse a frame. The id was inside it, so
        # JSON-RPC's answer carries `null` for one.
        respond_error(nil, -32700, "parse error: the frame's body is not JSON")
      when "$/invalidRequest"
        respond_error(nil, -32600, "invalid request: the frame's body is JSON but not an object")
      when "initialize"
        @initialized = true
        @root = root_of(params)
        @snippets = params.try(&.dig?("capabilities", "textDocument", "completion", "completionItem", "snippetSupport")).try(&.as_bool?) == true
        respond(id.not_nil!) { |json| capabilities(json) }
      when "initialized"
        # A notification; nothing to say back.
      when "shutdown"
        @shut_down = true
        respond_null(id.not_nil!)
      when "exit"
        @exit_code = @shut_down ? 0 : 1
        @running = false
      when "iyi/adopt"
        # Not a client's method: `Proxy` hands a fresh worker the buffers
        # its predecessor held, and this is the handover. A replayed
        # `didOpen` would publish a verdict per open file that the client
        # already has on screen; adopting is the same state with nothing
        # said back.
        adopted = [] of String
        params.not_nil!["documents"].as_a.each do |document|
          uri = document["uri"].as_s
          @documents[uri] = document["text"].as_s
          @analysis.open(path_of(uri))
          adopted << uri
        end

        # And one compile each, because the buffers are not the state the
        # predecessor had. A cursor question in a buffer that does not
        # compile — which is what mid-edit means, and mid-edit is where a
        # person asks — is answered from the last program that did, and a
        # successor that only records the text has none. `Proxy` warms it
        # on the *focused* file, so every other open buffer answered the
        # first completion with nothing: `s.up` offered `upcase` before
        # the replacement and an empty list after it.
        #
        # Paid in the silence the replacement is scheduled in, and
        # bounded by what `Analysis` keeps anyway — warming more than
        # that would evict the ones warmed first. Nothing is published:
        # the client already has these verdicts.
        adopted.last(Analysis::KEEP).each do |uri|
          path = path_of(uri)
          @analysis.check(path, @documents[uri], overrides_for(path))
        end
      when "textDocument/didOpen"
        uri = params.not_nil!["textDocument"]["uri"].as_s
        @documents[uri] = params.not_nil!["textDocument"]["text"].as_s
        @analysis.open(path_of(uri))
        publish_diagnostics(uri)
      when "textDocument/didChange"
        uri = params.not_nil!["textDocument"]["uri"].as_s
        # Incremental sync: each change names a range in wire units, or
        # carries the whole text; both apply in order.
        text = @documents[uri]? || ""
        params.not_nil!["contentChanges"].as_a.each do |change|
          text = Text.apply(text, change)
        end
        # A typing burst is one verdict: every didChange for this
        # document already queued applies now, and the compile runs
        # once, on what the person actually sees.
        while (queued = @inbox.first?) &&
              queued["method"]?.try(&.as_s?) == "textDocument/didChange" &&
              queued["params"]["textDocument"]["uri"].as_s == uri
          @inbox.shift
          queued["params"]["contentChanges"].as_a.each do |change|
            text = Text.apply(text, change)
          end
        end
        @documents[uri] = text
        publish_diagnostics(uri)
      when "textDocument/didSave"
        publish_diagnostics(params.not_nil!["textDocument"]["uri"].as_s)
      when "textDocument/didClose"
        uri = params.not_nil!["textDocument"]["uri"].as_s
        @documents.delete(uri)
        @published.delete(uri)
        @analysis.close(path_of(uri))
      when "textDocument/hover"
        on_hover(id.not_nil!, params.not_nil!)
      when "textDocument/definition"
        on_definition(id.not_nil!, params.not_nil!)
      when "textDocument/documentSymbol"
        on_document_symbol(id.not_nil!, params.not_nil!)
      when "textDocument/completion"
        on_completion(id.not_nil!, params.not_nil!)
      when "textDocument/references"
        on_references(id.not_nil!, params.not_nil!)
      when "textDocument/rename"
        on_rename(id.not_nil!, params.not_nil!)
      when "textDocument/prepareRename"
        on_prepare_rename(id.not_nil!, params.not_nil!)
      when "textDocument/typeDefinition"
        on_type_definition(id.not_nil!, params.not_nil!)
      when "textDocument/documentHighlight"
        on_document_highlight(id.not_nil!, params.not_nil!)
      when "textDocument/signatureHelp"
        on_signature_help(id.not_nil!, params.not_nil!)
      when "textDocument/formatting"
        on_formatting(id.not_nil!, params.not_nil!)
      when "textDocument/foldingRange"
        on_folding_range(id.not_nil!, params.not_nil!)
      when "workspace/willRenameFiles"
        on_will_rename_files(id.not_nil!, params.not_nil!)
      when "workspace/symbol"
        on_workspace_symbol(id.not_nil!, params.not_nil!)
      when "textDocument/semanticTokens/full"
        on_semantic_tokens(id.not_nil!, params.not_nil!)
      when "textDocument/semanticTokens/full/delta"
        on_semantic_tokens_delta(id.not_nil!, params.not_nil!)
      when "textDocument/codeLens"
        on_code_lens(id.not_nil!, params.not_nil!)
      when "workspace/executeCommand"
        on_execute_command(id.not_nil!, params.not_nil!)
      when "textDocument/inlayHint"
        on_inlay_hint(id.not_nil!, params.not_nil!)
      when "textDocument/codeAction"
        on_code_action(id.not_nil!, params.not_nil!)
      when "textDocument/implementation"
        on_implementation(id.not_nil!, params.not_nil!)
      when "textDocument/prepareCallHierarchy"
        on_prepare_call_hierarchy(id.not_nil!, params.not_nil!)
      when "callHierarchy/incomingCalls"
        on_incoming_calls(id.not_nil!, params.not_nil!)
      when "callHierarchy/outgoingCalls"
        on_outgoing_calls(id.not_nil!, params.not_nil!)
      when "textDocument/selectionRange"
        on_selection_range(id.not_nil!, params.not_nil!)
      when "textDocument/diagnostic"
        on_pull_diagnostics(id.not_nil!, params.not_nil!)
      when "workspace/diagnostic"
        on_workspace_diagnostics(id.not_nil!, params)
      when "textDocument/documentLink"
        on_document_link(id.not_nil!, params.not_nil!)
      when "textDocument/prepareTypeHierarchy"
        on_prepare_type_hierarchy(id.not_nil!, params.not_nil!)
      when "typeHierarchy/supertypes"
        on_supertypes(id.not_nil!, params.not_nil!)
      when "typeHierarchy/subtypes"
        on_subtypes(id.not_nil!, params.not_nil!)
      when "iyi/contextPack"
        on_delegated(id.not_nil!, params.not_nil!, "mod", "context", "--json")
      when "iyi/surface"
        on_delegated(id.not_nil!, params.not_nil!, "doc")
      else
        # A notification nobody here speaks is silence, which is what the
        # protocol asks for. A *request* is not: it used to get an empty
        # answer, and an empty answer is indistinguishable from "there is
        # nothing at that position" — the one thing a client must be able
        # to tell apart, because -32601 is how it learns to stop asking.
        if id
          respond_error(id, -32601, "method not found: #{method}")
        end
      end
    rescue ex
      # A single bad request must not take the session down: the server's
      # whole value is being there on the next keystroke. What it is told
      # depends on whose mistake it was — -32603 says *this server* is
      # broken, and it said that for a file the client named that is not
      # there, in the runtime's own words ("Error opening file with mode
      # 'r'"), which is neither true nor actionable.
      if id
        case ex
        when File::Error
          reason = ex.os_error.try(&.message) || "it could not be read"
          respond_error(id, -32602, "#{ex.file}: #{reason}")
        when IO::Error
          respond_error(id, -32602, ex.os_error.try(&.message) || ex.message.to_s)
        when KeyError
          # `params["textDocument"]` on a request that carried none. The
          # JSON library's wording is `Missing hash key: "textDocument"`.
          respond_error(id, -32602, "the request is missing #{ex.message.to_s.sub("Missing hash key: ", "")}")
        when NilAssertionError
          # `params.not_nil!` on a request with no `params` at all: it was
          # answered -32603 "Nil assertion failed", the server's own words
          # for the client's omission.
          respond_error(id, -32602, "the request carries no params, and #{method} takes some")
        else
          # The JSON library's "Expected Hash for #[](key : String), not
          # String" is a request whose params are the wrong shape, which is
          # the client's -32602 and not this server's -32603.
          if ex.message.to_s.starts_with?("Expected ")
            respond_error(id, -32602, "the request's params are not the shape #{method} takes: #{ex.message}")
          else
            respond_error(id, -32603, ex.message.to_s)
          end
        end
      end
    end

    # One place the protocol's error shape is written, because there were
    # three and one of them was a constant -32603.
    private def respond_error(id : JSON::Any?, code : Int32, message : String) : Nil
      send(JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id" do
            if id
              id.to_json(json)
            else
              json.scalar(nil)
            end
          end
          json.field "error" do
            json.object do
              json.field "code", code
              json.field "message", message
            end
          end
        end
      end)
    end

    private def capabilities(json : JSON::Builder) : Nil
      json.object do
        json.field "capabilities" do
          json.object do
            json.field "textDocumentSync" do
              json.object do
                json.field "openClose", true
                json.field "change", 2 # incremental
                json.field "save", true
              end
            end
            json.field "hoverProvider", true
            json.field "definitionProvider", true
            json.field "typeDefinitionProvider", true
            json.field "typeHierarchyProvider", true
            json.field "documentLinkProvider" do
              json.object { json.field "resolveProvider", false }
            end
            json.field "documentSymbolProvider", true
            json.field "documentHighlightProvider", true
            json.field "referencesProvider", true
            json.field "documentFormattingProvider", true
            json.field "foldingRangeProvider", true
            json.field "workspaceSymbolProvider", true
            json.field "inlayHintProvider", true
            json.field "implementationProvider", true
            json.field "callHierarchyProvider", true
            json.field "selectionRangeProvider", true
            json.field "diagnosticProvider" do
              json.object do
                json.field "interFileDependencies", true
                json.field "workspaceDiagnostics", true
              end
            end
            json.field "renameProvider" do
              json.object { json.field "prepareProvider", true }
            end
            json.field "codeActionProvider" do
              json.object do
                json.field "codeActionKinds" do
                  json.array do
                    json.string "quickfix"
                    json.string "source.organizeImports"
                  end
                end
              end
            end
            json.field "workspace" do
              json.object do
                json.field "fileOperations" do
                  json.object do
                    json.field "willRename" do
                      json.object do
                        json.field "filters" do
                          json.array do
                            json.object do
                              json.field "pattern" do
                                json.object { json.field "glob", "**/*.iyi" }
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
            json.field "completionProvider" do
              json.object do
                json.field "triggerCharacters" { json.array { json.string "." } }
              end
            end
            json.field "signatureHelpProvider" do
              json.object do
                json.field "triggerCharacters" do
                  json.array do
                    json.string "("
                    json.string ","
                  end
                end
              end
            end
            json.field "semanticTokensProvider" do
              json.object do
                json.field "legend" do
                  json.object do
                    json.field "tokenTypes" do
                      json.array { Tokens::TYPES.each { |name| json.string name } }
                    end
                    json.field "tokenModifiers" { json.array { } }
                  end
                end
                json.field "full" do
                  json.object { json.field "delta", true }
                end
              end
            end
            json.field "codeLensProvider" do
              json.object { json.field "resolveProvider", false }
            end
            json.field "executeCommandProvider" do
              json.object do
                json.field "commands" { json.array { json.string "iyi.run" } }
              end
            end
          end
        end
        json.field "serverInfo" do
          json.object do
            json.field "name", "iyi"
            json.field "version", Iyi::Config.iyi_version
          end
        end
      end
    end

    # ── Diagnostics ──────────────────────────────────────────────────────

    # One document's verdict as rows: {line0, start_ch, end_ch, diag}.
    # Push and pull share this — and codeAction reads the stored copy
    # back, because a quickfix is a diagnostic whose message already
    # names the fix.
    private def diagnostic_rows(uri : String) : Array({Int32, Int32, Int32, Diag})
      path = path_of(uri)
      text = text_of(uri)
      lines = text.lines
      _, diags = @analysis.check(path, text, overrides_for(path))

      rows = diags.map do |diag|
        line_text = lines[diag.line - 1]? || ""
        start_ch = Lsp.character_of(line_text, diag.column)
        end_ch = diag.size > 0 ? Lsp.character_of(line_text, diag.column + diag.size) : start_ch
        {diag.line - 1, start_ch, end_ch, diag}
      end

      @published[uri] = rows.map { |(line0, start_ch, end_ch, diag)| {line0, start_ch, end_ch, diag.message, diag.suggestion} }
      rows
    end

    private def write_diagnostic(json : JSON::Builder, line0 : Int32, start_ch : Int32, end_ch : Int32, diag : Diag) : Nil
      json.object do
        json.field "range" { range(json, line0, start_ch, line0, end_ch) }
        json.field "severity", 1
        json.field "source", "iyi"
        json.field "message", diag.message
        if refs = diag.spec
          json.field "code", "SPEC #{refs.first}"
          json.field "codeDescription" do
            json.object do
              json.field "href", "https://github.com/iyilang/iyi/blob/master/SPEC.md"
            end
          end
        end
        unless diag.related.empty?
          json.field "relatedInformation" do
            json.array do
              diag.related.each do |(file, line, col, msg)|
                json.object do
                  json.field "location" do
                    json.object do
                      json.field "uri", uri_of(file)
                      json.field "range" { range(json, line - 1, col > 0 ? col - 1 : 0, line - 1, col > 0 ? col - 1 : 0) }
                    end
                  end
                  json.field "message", msg
                end
              end
            end
          end
        end
      end
    end

    private def publish_diagnostics(uri : String) : Nil
      rows = diagnostic_rows(uri)
      notify("textDocument/publishDiagnostics") do |json|
        json.object do
          json.field "uri", uri
          json.field "diagnostics" do
            json.array do
              rows.each do |(line0, start_ch, end_ch, diag)|
                write_diagnostic(json, line0, start_ch, end_ch, diag)
              end
            end
          end
        end
      end
    end

    # ── Pull diagnostics: the agent's shape of the same verdict ─────────
    #
    # A pull carries a `resultId`, and the next pull hands it back: the
    # same id means "nothing you judged this by has moved", and the
    # answer is `unchanged` — no compile. What a file's verdict is
    # judged by is R-1's list: the file, and the modules its imports
    # reach, directly or through another import. So the id is per file,
    # folded over exactly that set (`result_ids`), and a keystroke in
    # one module makes the next pull full for that module and its
    # importers and `unchanged` for everything else — on a corpus of
    # thirty modules, a compile or three where it was thirty.
    #
    # Free is the whole point. VS Code's client pulls
    # `workspace/diagnostic` two seconds after every answer, forever,
    # for as long as the window is open; without an `unchanged` the
    # server was compiling every file under the root — up to two
    # hundred — every two seconds of an idle editor, and keeping every
    # program it built. Two Cursor windows on a laptop: a gigabyte of
    # resident memory and a fan, doing nothing. And with one id for
    # the whole workspace, an editor being typed in was the same build
    # farm every two seconds; the per-file id is what ends that.

    # `textDocument/diagnostic` — one buffer, on request. Agents poll;
    # they do not sit on a subscription. Same compile, same rows.
    private def on_pull_diagnostics(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      result_id = result_ids[path_of(uri)]? || "0"
      respond(id) do |json|
        json.object do
          json.field "resultId", result_id
          if params["previousResultId"]?.try(&.as_s?) == result_id
            json.field "kind", "unchanged"
          else
            rows = diagnostic_rows(uri)
            json.field "kind", "full"
            json.field "items" do
              json.array do
                rows.each do |(line0, start_ch, end_ch, diag)|
                  write_diagnostic(json, line0, start_ch, end_ch, diag)
                end
              end
            end
          end
        end
      end
    end

    # `workspace/diagnostic` — the whole project's verdict in one
    # request, open buffers winning over the disk. R-1 is why this is
    # affordable: each file is its own compile, tens of milliseconds,
    # no shared state to invalidate. Capped so a monorepo cannot turn
    # one request into a build farm.
    private def on_workspace_diagnostics(id : JSON::Any, params : JSON::Any?) : Nil
      ids = result_ids
      previous = {} of String => String
      params.try(&.["previousResultIds"]?).try(&.as_a?).try &.each do |entry|
        uri = entry["uri"]?.try(&.as_s?)
        value = entry["value"]?.try(&.as_s?)
        previous[uri] = value if uri && value
      end

      uris = @documents.keys.dup
      if root = @root
        Dir.glob(::Path[root].to_posix.join("**", "*.iyi")) do |file|
          # Read as posix before the skip tests: a glob yields the platform's
          # own separators, so a backslashed path went past `/.` and `/lib/`
          # and the `.git` and `lib` trees were indexed anyway.
          #
          # And the posix reading is what the URI is built from — a `file://`
          # URI has one separator, and this side's spelling has to be the one
          # `path_of` hands back for a buffer the client named.
          posix = ::Path[file].to_posix.to_s
          next if posix.includes?("/.") || posix.includes?("/lib/")
          uri = uri_of(posix)
          uris << uri unless uris.includes?(uri)
          break if uris.size >= 200
        end
      end

      # The verdicts first, and *interruptibly*, because this is the one
      # request that compiles a hundred files.
      #
      # It was built inside the response, so the walk could not be stopped
      # once it started: a cold pull of this repository is 94 compiles and
      # eleven seconds, and every keystroke behind it waited the whole
      # eleven — measured, hover answered at 10.91 s. One thread is the
      # honest limit, but a *request* is not the unit it has to be honest
      # about: between files the inbox is drained, and if the client
      # cancelled this pull, or anything else is waiting to be answered,
      # the walk stops and says so. A cancelled pull is `-32800`; one the
      # server gave up on is `-32802` with `retriggerRequest`, which the
      # protocol has for exactly this and which the editor answers by
      # asking again when the typing stops.
      answers = [] of {String, String, Array({Int32, Int32, Int32, Diag})?}
      uris.each do |uri|
        next unless @documents.has_key?(uri) || File.file?(path_of(uri))
        result_id = ids[path_of(uri)]? || "0"
        if previous[uri]? == result_id
          answers << {uri, result_id, nil}
          next
        end

        if kept = kept_rows(uri, result_id)
          answers << {uri, result_id, kept}
          next
        end

        # Only a file that has to be compiled is worth looking up from:
        # everything above is a hash lookup, and a warm pull should not
        # pay the event loop ninety-four times for nothing.
        absorb_pending
        return respond_cancelled(id) if @cancelled.delete(id.to_json)
        return respond_retrigger(id) if waiting_request?(id)

        answers << {uri, result_id, compile_rows(uri, result_id)}
      end

      respond(id) do |json|
        json.object do
          json.field "items" do
            json.array do
              answers.each do |(uri, result_id, rows)|
                json.object do
                  json.field "uri", uri
                  json.field "version", nil
                  json.field "resultId", result_id
                  if rows.nil?
                    json.field "kind", "unchanged"
                    next
                  end
                  json.field "kind", "full"
                  json.field "items" do
                    json.array do
                      rows.each do |(line0, start_ch, end_ch, diag)|
                        write_diagnostic(json, line0, start_ch, end_ch, diag)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # One file's verdict, kept by the id that describes it.
    #
    # A pull the server gave up on is asked again, and without this the
    # second pull recompiles every file the first one had already answered
    # — which, with a client polling every two seconds while somebody
    # types, is a server that never finishes anything. The key is the
    # `resultId`, so a file that moved is compiled again by construction.
    # Bounded to the cap the walk already has.
    @workspace_rows = {} of String => {String, Array({Int32, Int32, Int32, Diag})}

    private def kept_rows(uri : String, result_id : String) : Array({Int32, Int32, Int32, Diag})?
      kept = @workspace_rows[uri]?
      return nil unless kept && kept[0] == result_id
      kept[1]
    end

    private def compile_rows(uri : String, result_id : String) : Array({Int32, Int32, Int32, Diag})
      rows = diagnostic_rows(uri)
      @workspace_rows.clear if @workspace_rows.size > 256
      @workspace_rows[uri] = {result_id, rows}
      rows
    end

    # Whether anything but this request is waiting to be answered.
    #
    # A cancel is not work — `sweep_cancels` has already taken those out —
    # and neither is another pull for the same thing: answering "ask me
    # again" to a queue that holds nothing but pulls is a loop.
    private def waiting_request?(id : JSON::Any) : Bool
      @inbox.any? do |message|
        next false if message["id"]?.try(&.to_json) == id.to_json
        method = message["method"]?.try(&.as_s?)
        next false unless method
        next false if method == "$/cancelRequest"
        next false if method == "workspace/diagnostic"
        true
      end
    end

    # `ServerCancelled`, with the flag the diagnostic request has for it:
    # the client retriggers rather than treating the verdict as missing.
    private def respond_retrigger(id : JSON::Any) : Nil
      send(JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id" { id.to_json(json) }
          json.field "error" do
            json.object do
              json.field "code", -32802
              json.field "message", "the server stopped the workspace pull to answer what was waiting"
              json.field "data" do
                json.object { json.field "retriggerRequest", true }
              end
            end
          end
        end
      end)
    end

    # One workspace file as the pull sees it: what it is (an open
    # buffer's text hash, or a disk file's size and mtime), what module
    # it declares, and what it imports. The header block is read as
    # text (II.3 rule 4) and cached by size and mtime for disk files, so
    # a pull every two seconds is a stat per file and a read of the
    # ones that moved.
    record Node, stamp : UInt64, header : String?, imports : Array(String)
    @header_cache = {} of String => {Int64, Time, String?, Array(String)}

    # A resultId per file: a fold over the file's own stamp and the
    # stamps of every module its imports reach, plus one stamp shared
    # by all for what is outside the graph — `lib/`, `iyi.mod`,
    # `iyi.sum` — since a dependency's declarations are part of every
    # verdict and the graph does not resolve into them. The hash is per
    # process, which is exactly the life of a resultId.
    private def result_ids : Hash(String, String)
      prime = 1099511628211_u64
      nodes = {} of String => Node
      @documents.each do |uri, text|
        nodes[path_of(uri)] = Node.new(text.hash, Exports.header_of(text), imports_of(text))
      end

      outside = 0_u64
      if root = @root
        Dir.glob(::Path[root].to_posix.join("**", "*.iyi")) do |file|
          posix = ::Path[file].to_posix.to_s
          next if posix.includes?("/.")
          info = File.info?(file)
          next unless info
          if posix.includes?("/lib/")
            outside = outside &* prime &+ file.hash &+ info.size.hash &+ info.modification_time.hash
            next
          end
          next if nodes.has_key?(posix)
          header, imports = header_and_imports(file, info)
          nodes[posix] = Node.new(info.size.hash &* prime &+ info.modification_time.hash, header, imports)
        end
        Dir.glob(::Path[root].to_posix.join("**", "iyi.mod"), ::Path[root].to_posix.join("**", "iyi.sum")) do |file|
          info = File.info?(file)
          next unless info
          outside = outside &* prime &+ file.hash &+ info.size.hash &+ info.modification_time.hash
        end
      end

      by_header = {} of String => String
      nodes.each do |path, node|
        if header = node.header
          by_header[header] ||= path
        end
      end

      ids = {} of String => String
      seen = Set(String).new
      stack = [] of String
      nodes.each_key do |path|
        seen.clear
        seen << path
        stack.clear
        stack << path
        fold = outside
        while current = stack.pop?
          node = nodes[current]
          fold = fold &* prime &+ current.hash &* prime &+ node.stamp
          node.imports.each do |imported|
            if (target = by_header[imported]?) && seen.add?(target)
              stack << target
            end
          end
        end
        ids[path] = fold.to_s(36)
      end
      ids
    end

    private def header_and_imports(file : String, info : File::Info) : {String?, Array(String)}
      if (cached = @header_cache[file]?) && cached[0] == info.size && cached[1] == info.modification_time
        return {cached[2], cached[3]}
      end
      text = File.read(file)
      header = Exports.header_of(text)
      imports = imports_of(text)
      @header_cache[file] = {info.size, info.modification_time, header, imports}
      {header, imports}
    end

    # ── Hover ────────────────────────────────────────────────────────────

    private def on_hover(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)
      line0 = params["position"]["line"].as_i
      char = params["position"]["character"].as_i
      line_text = text.lines[line0]? || ""
      column = Lsp.column_of(line_text, char)

      word = word_at(line_text, column)
      parts = [] of String

      result = @analysis.context_at(path, text, overrides_for(path), line0 + 1, column)
      if (contexts = result.try(&.contexts)) && !contexts.empty?
        # The name under the cursor first; a call expression the visitor
        # keyed by its own text second. Never the whole scope: hover is a
        # question about one thing.
        entry = nil
        contexts.each do |ctx|
          if word && (type = ctx[word]?)
            entry = {word, type}
            break
          end
        end
        unless entry
          contexts.each do |ctx|
            ctx.each do |key, type|
              if word && (key == word || key.ends_with?(".#{word}") || key.starts_with?("#{word}("))
                entry = {key, type}
                break
              end
            end
            break if entry
          end
        end
        if entry
          name, type = entry
          parts << "```iyi\n#{name} : #{PrettyTypeNameJsonConverter.pretty_type_name(type)}\n```"
        end
      end

      # A call's definition rides along: its signature as the author
      # wrote it, the doc comment above it. The compile is the memoised
      # one the type answer already paid for.
      impls = @analysis.implementations_at(path, text, overrides_for(path), line0 + 1, column)
      if trace = impls.try(&.implementations).try(&.find { |t| t.filename != "<unknown>" && t.line > 0 })
        signature = read_line(trace.filename, trace.line).strip
        unless signature.empty?
          parts << "```iyi\n#{signature}\n```"
          doc = doc_above(trace.filename, trace.line)
          parts << doc unless doc.empty?
        end
      end

      return respond_null(id) if parts.empty?

      respond(id) do |json|
        json.object do
          json.field "contents" do
            json.object do
              json.field "kind", "markdown"
              json.field "value", parts.uniq.join("\n\n---\n\n")
            end
          end
        end
      end
    end

    # The `#` lines immediately above a definition — the doc comment,
    # rendered as the markdown it already is.
    private def doc_above(filename : String, line : Int32) : String
      text = @documents[uri_of(filename)]? || (File.file?(filename) ? File.read(filename) : "")
      lines = text.lines
      docs = [] of String
      index = line - 2
      while index >= 0
        stripped = lines[index]?.try(&.strip)
        break unless stripped && stripped.starts_with?('#')
        docs << stripped.lchop('#').lchop(' ')
        index -= 1
      end
      docs.reverse!.join('\n')
    end

    # The identifier under the cursor: iyi's name characters, plus the
    # `@`/`@@` sigils and the `?`/`!` suffixes. The range is inclusive
    # codepoint indexes into the line, 0-based.
    private def word_range(line_text : String, column : Int32) : {Int32, Int32}?
      chars = line_text.chars
      index = column - 1
      index = chars.size - 1 if index >= chars.size
      return nil if index < 0

      name_char = ->(ch : Char) { ch.alphanumeric? || ch == '_' }
      return nil unless name_char.call(chars[index]) || chars[index].in?('?', '!', '@')

      from = index
      while from > 0 && name_char.call(chars[from - 1])
        from -= 1
      end
      while from > 0 && chars[from - 1] == '@'
        from -= 1
      end
      to = index
      while to < chars.size - 1 && name_char.call(chars[to + 1])
        to += 1
      end
      to += 1 if to < chars.size - 1 && chars[to + 1].in?('?', '!')
      {from, to}
    end

    private def word_at(line_text : String, column : Int32) : String?
      word_range(line_text, column).try { |(from, to)| line_text[from..to] }
    end

    # ── Definition ───────────────────────────────────────────────────────

    private def on_definition(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)
      line0 = params["position"]["line"].as_i
      char = params["position"]["character"].as_i
      line_text = text.lines[line0]? || ""
      column = Lsp.column_of(line_text, char)

      result = @analysis.implementations_at(path, text, overrides_for(path), line0 + 1, column)
      traces = result.try(&.implementations)
      unless traces && !traces.empty?
        return respond_null(id)
      end

      respond(id) do |json|
        json.array do
          traces.each do |trace|
            next if trace.filename == "<unknown>" || trace.line <= 0
            target_line = read_line(trace.filename, trace.line)
            ch = Lsp.character_of(target_line, trace.column)
            json.object do
              json.field "uri", uri_of(trace.filename)
              json.field "range" { range(json, trace.line - 1, ch, trace.line - 1, ch) }
            end
          end
        end
      end
    end

    private def read_line(filename : String, line : Int32) : String
      text = @documents[uri_of(filename)]? || (File.file?(filename) ? File.read(filename) : "")
      text.lines[line - 1]? || ""
    end

    # ── Completion ───────────────────────────────────────────────────────

    KEYWORDS = %w(def end if elsif else unless while case when import using
      pub module trait impl struct class enum return begin rescue ensure
      true false nil self group spawn defer select)

    private def on_completion(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)
      line0 = params["position"]["line"].as_i
      char = params["position"]["character"].as_i
      line_text = text.lines[line0]? || ""

      # Everything below is in codepoints; the wire's UTF-16 enters and
      # leaves through the two converters only.
      cursor = Lsp.column_of(line_text, char) - 1
      chars = line_text.chars

      prefix_start = cursor
      while prefix_start > 0 && name_char?(chars[prefix_start - 1]?)
        prefix_start -= 1
      end
      prefix = chars[prefix_start...cursor].join

      receiver = nil
      anchor = prefix_start
      if prefix_start > 0 && chars[prefix_start - 1]? == '.'
        receiver_start = prefix_start - 1
        while receiver_start > 0 && (name_char?(chars[receiver_start - 1]?) || chars[receiver_start - 1]? == '@')
          receiver_start -= 1
        end
        receiver = chars[receiver_start...(prefix_start - 1)].join
        anchor = receiver_start
        return respond_null(id) if receiver.empty?
      end

      scope_items = @analysis.completion_at(
        path, text, overrides_for(path), line0 + 1, anchor + 1, receiver)

      # {label, detail, kind, tier, from module, additional edits}.
      # The tier leads sortText: prefix matches before fuzzy ones,
      # the scope before the workspace, keywords in between.
      rows = [] of {String, String, Int32, Char, String?, Array({Int32, Int32, Int32, String})?}
      scope_items.each do |(label, detail, kind)|
        if prefix.empty? || label.starts_with?(prefix)
          rows << {label, detail, kind, kind == 6 ? '0' : '1', nil, nil}
        elsif fuzzy_match?(prefix, label)
          rows << {label, detail, kind, '4', nil, nil}
        end
      end

      if receiver.nil?
        KEYWORDS.each do |keyword|
          rows << {keyword, "keyword", 14, '2', nil, nil} if prefix.empty? || keyword.starts_with?(prefix)
        end

        # The workspace's exported defs, auto-import riding along: the
        # item inserts the name, and the `import`/`using` pair a person
        # (or a model) forgets arrives as additionalTextEdits. Parse
        # only — R-2 wrote `pub` at the declaration, so the offer works
        # in a buffer that has never compiled.
        unless prefix.empty?
          own = Exports.header_of(text)
          seen = rows.map { |(label, _, _, _, _, _)| label }.to_set
          count = 0
          workspace_entries.each do |(entry_path, entry_text)|
            break if count >= 100
            next if entry_path == path
            Exports.of(entry_text, entry_path).each do |item|
              next if item.module_path == own
              next if seen.includes?(item.name)
              tier =
                if item.name.starts_with?(prefix)
                  '3'
                elsif fuzzy_match?(prefix, item.name)
                  '5'
                end
              next unless tier
              rows << {item.name, item.detail, 3, tier, item.module_path,
                       import_edits(text, item.module_path, item.name)}
              seen << item.name
              count += 1
            end
          end
        end
      end

      respond(id) do |json|
        json.object do
          json.field "isIncomplete", false
          json.field "items" do
            json.array do
              rows.each do |(label, detail, kind, tier, from_module, edits)|
                json.object do
                  json.field "label", label
                  json.field "kind", kind
                  json.field "detail", detail
                  json.field "sortText", "#{tier}#{label}"
                  # A callable with parameters lands as a snippet when
                  # the client said it renders them: the cursor stops
                  # inside the parentheses it was going to type anyway.
                  if @snippets && kind.in?(2, 3) && detail.includes?('(')
                    json.field "insertText", "#{label}($1)"
                    json.field "insertTextFormat", 2
                  end
                  if from_module
                    json.field "labelDetails" do
                      json.object { json.field "description", from_module }
                    end
                    json.field "documentation", "from #{from_module}"
                  end
                  if edits && !edits.empty?
                    json.field "additionalTextEdits" do
                      json.array do
                        edits.each do |(edit_line, edit_start, edit_end, new_text)|
                          json.object do
                            json.field "range" { range(json, edit_line, edit_start, edit_line, edit_end) }
                            json.field "newText", new_text
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # The edits that make `name` from `module_path` bare-callable in
    # this buffer: extend the module's selective `using`, or write the
    # `import`/`using` pair after the last import (or the header). Nil
    # when the name is already reachable — no edit is the right edit.
    private def import_edits(text : String, module_path : String, name : String) : Array({Int32, Int32, Int32, String})?
      lines = text.lines
      header_index : Int32? = nil
      last_import : Int32? = nil
      has_import = false
      selective : {Int32, Array(String)}? = nil

      lines.each_with_index do |line, index|
        stripped = line.strip
        if header_index.nil? && stripped.starts_with?("module ")
          header_index = index
        elsif stripped == "import #{module_path}"
          has_import = true
          last_import = index
        elsif stripped.starts_with?("import ") || stripped.starts_with?("using ")
          last_import = index
          if stripped == "using #{module_path}"
            return nil # everything exported is already in scope
          elsif stripped.starts_with?("using #{module_path}::{") && stripped.ends_with?('}')
            names = stripped.lchop("using #{module_path}::{").rchop.split(',').map(&.strip)
            return nil if names.includes?(name)
            selective = {index, names}
          end
        end
      end

      if pick = selective
        index, names = pick
        line = lines[index]
        end_ch = Lsp.character_of(line, line.chars.size + 1)
        return [{index, 0, end_ch, "using #{module_path}::{#{names.join(", ")}, #{name}}"}]
      end

      anchor = (last_import || header_index || -1) + 1
      block = String.build do |io|
        io << "import " << module_path << '\n' unless has_import
        io << "using " << module_path << "::{" << name << "}\n"
      end
      [{anchor, 0, 0, block}]
    end

    private def name_char?(ch : Char?) : Bool
      return false unless ch
      ch.alphanumeric? || ch == '_'
    end

    # ── References and rename ────────────────────────────────────────────

    private def on_references(id : JSON::Any, params : JSON::Any) : Nil
      references, declarations = reference_sites(params)
      if references.empty? && declarations.empty?
        return respond_null(id)
      end

      include_declaration = params["context"]?.try(&.["includeDeclaration"]?).try(&.as_bool?) || false
      sites = references.dup
      sites.concat declarations if include_declaration

      respond(id) do |json|
        json.array do
          sites.each do |(location, size)|
            filename = location.filename
            next unless filename.is_a?(String)
            target_line = read_line(filename, location.line_number)
            start_ch = Lsp.character_of(target_line, location.column_number)
            end_ch = Lsp.character_of(target_line, location.column_number + size)
            json.object do
              json.field "uri", uri_of(filename)
              json.field "range" { range(json, location.line_number - 1, start_ch, location.line_number - 1, end_ch) }
            end
          end
        end
      end
    end

    # Rename rides the same typed graph as references: only the edges the
    # front end bound move, so an overload that shares the name but not
    # the resolution keeps it. What the graph does not know it refuses to
    # touch — by name, not silently.
    private def on_rename(id : JSON::Any, params : JSON::Any) : Nil
      new_name = params["newName"].as_s
      unless valid_name?(new_name)
        raise "'#{new_name}' is not an iyi method name"
      end

      references, declarations = reference_sites(params)
      if references.empty? && declarations.empty?
        raise "nothing renameable under the cursor: rename serves defs and their calls, off the typed graph"
      end

      by_file = {} of String => Array({Int32, Int32, Int32})
      (declarations + references).each do |(location, size)|
        filename = location.filename
        next unless filename.is_a?(String)
        target_line = read_line(filename, location.line_number)
        start_ch = Lsp.character_of(target_line, location.column_number)
        end_ch = Lsp.character_of(target_line, location.column_number + size)
        (by_file[filename] ||= [] of {Int32, Int32, Int32}) << {location.line_number - 1, start_ch, end_ch}
      end
      by_file.each_value(&.uniq!)

      respond(id) do |json|
        json.object do
          json.field "changes" do
            json.object do
              by_file.each do |filename, edits|
                json.field uri_of(filename) do
                  json.array do
                    edits.each do |(line0, start_ch, end_ch)|
                      json.object do
                        json.field "range" { range(json, line0, start_ch, line0, end_ch) }
                        json.field "newText", new_name
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # Under R-1 a def's callers live in its *consumers'* compiles, so one
    # program cannot answer "who calls this" — the workspace can: every
    # open document and every `.iyi` under the root compiles as its own
    # entry and the answers merge. A caller in a file nobody opened is
    # still a caller, and a rename that missed it would leave a program
    # that does not compile. Open buffers ride first, so unsaved edits
    # win; the walk shares workspace/diagnostic's cap for the same
    # reason — a question must not become a build farm.
    #
    # And R-1 says which entries can answer at all: a module refers to a
    # def only through the module that declares it, imported directly or
    # through another import. So the cursor's own file compiles first and
    # names the declaring files, and then only the entries whose import
    # graph reaches one of them compile — the rest could not hold a
    # reference, and are not asked. On a 32-module corpus that is the
    # difference between 1.7 s and the importers' share of it.
    private def reference_sites(params : JSON::Any) : {Array({Location, Int32}), Array({Location, Int32})}
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)
      line0 = params["position"]["line"].as_i
      char = params["position"]["character"].as_i
      line_text = text.lines[line0]? || ""
      target = Location.new(path, line0 + 1, Lsp.column_of(line_text, char))

      references = [] of {Location, Int32}
      declarations = [] of {Location, Int32}

      first = @analysis.references_at(path, text, overrides_for(path), target)
      return {references, declarations} unless first
      references.concat first.references
      declarations.concat first.declarations

      entries = workspace_entries
      entries_reaching(entries, first.target_files).each do |(entry_path, entry_text)|
        next if entry_path == path
        visitor = @analysis.references_at(entry_path, entry_text, overrides_for(entry_path), target)
        next unless visitor
        references.concat visitor.references
        declarations.concat visitor.declarations
      end

      {dedupe(references), dedupe(declarations)}
    end

    # The entry set a session-wide question compiles: open buffers
    # first (they see unsaved edits), then the workspace's own `.iyi`
    # files, capped like workspace/diagnostic. R-1 prices each entry at
    # one small front-end compile, which is what makes "ask the whole
    # workspace" an ordinary request rather than an index.
    private def workspace_entries : Array({String, String})
      entries = @documents.map { |doc_uri, doc_text| {path_of(doc_uri), doc_text} }
      if root = @root
        Dir.glob(::Path[root].to_posix.join("**", "*.iyi")) do |file|
          posix = ::Path[file].to_posix.to_s
          next if posix.includes?("/.") || posix.includes?("/lib/")
          next if @documents.has_key?(uri_of(posix))
          entries << {posix, File.read(file)}
          break if entries.size >= 200
        end
      end
      entries
    end

    # The entries whose import graph reaches any of `files`: those files'
    # own modules, everything that imports one of them, everything that
    # imports one of those, to a fixpoint. Read from the header block as
    # text, the way document links are, because the block is line-shaped
    # by design (II.3 rule 4) and a buffer mid-edit still has one. An
    # entry with no header is kept — it cannot be placed, so it is asked.
    # A target outside the entries (the prelude, a dependency under
    # `lib/`) is reachable from anywhere, and then every entry is asked.
    private def entries_reaching(entries : Array({String, String}), files : Enumerable(String)) : Array({String, String})
      headers = entries.map { |(_, entry_text)| Exports.header_of(entry_text) }
      by_path = {} of String => Int32
      entries.each_with_index { |(entry_path, _), index| by_path[entry_path] = index }

      reached = Set(String).new
      files.each do |file|
        index = by_path[file]?
        return entries unless index && (header = headers[index])
        reached << header
      end

      imports = entries.map { |(_, entry_text)| imports_of(entry_text) }
      loop do
        grew = false
        entries.each_index do |index|
          header = headers[index]
          next if header.nil? || reached.includes?(header)
          if imports[index].any? { |imported| reached.includes?(imported) }
            reached << header
            grew = true
          end
        end
        break unless grew
      end

      selected = [] of {String, String}
      entries.each_with_index do |entry, index|
        header = headers[index]
        selected << entry if header.nil? || reached.includes?(header)
      end
      selected
    end

    private def imports_of(text : String) : Array(String)
      imports = [] of String
      text.each_line do |line|
        stripped = line.lstrip
        next unless stripped.starts_with?("import ")
        mod = stripped.lchop("import ").each_char
          .take_while { |ch| ch.alphanumeric? || ch == '_' || ch == '/' }
          .join
        imports << mod unless mod.empty?
      end
      imports
    end

    private def dedupe(sites : Array({Location, Int32})) : Array({Location, Int32})
      seen = Set({String, Int32, Int32}).new
      sites.select do |(location, _)|
        seen.add?({location.filename.to_s, location.line_number, location.column_number})
      end
    end

    private def valid_name?(name : String) : Bool
      return false if name.empty?
      return false unless name[0].ascii_letter? || name[0] == '_'
      body = name.ends_with?('?') || name.ends_with?('!') ? name.rchop : name
      return false if body.empty?
      body.each_char.all? { |ch| ch.alphanumeric? || ch == '_' }
    end

    # ── Document symbols ─────────────────────────────────────────────────

    private def on_document_symbol(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      text = text_of(uri)
      symbols = Outline.build(text, path_of(uri))
      lines = text.lines
      respond(id) do |json|
        json.array do
          symbols.each { |sym| document_symbol(json, sym, lines) }
        end
      end
    end

    private def document_symbol(json : JSON::Builder, sym : Outline::Sym, lines : Array(String)) : Nil
      name_line = lines[sym.name_line - 1]? || ""
      sel_start = Lsp.character_of(name_line, sym.name_column)
      sel_end = Lsp.character_of(name_line, sym.name_column + sym.name.size)
      json.object do
        json.field "name", sym.name
        json.field "kind", sym.kind
        json.field "range" { range(json, sym.line - 1, 0, sym.end_line - 1, (lines[sym.end_line - 1]? || "").size) }
        json.field "selectionRange" { range(json, sym.name_line - 1, sel_start, sym.name_line - 1, sel_end) }
        unless sym.children.empty?
          json.field "children" do
            json.array do
              sym.children.each { |child| document_symbol(json, child, lines) }
            end
          end
        end
      end
    end

    # ── Prepare rename ───────────────────────────────────────────────────

    # Rename begins with the question references answer — is the cursor
    # on the typed graph at all — asked of this buffer alone, so the
    # refusal is instant and named before the client opens an input box.
    private def on_prepare_rename(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)
      line0 = params["position"]["line"].as_i
      char = params["position"]["character"].as_i
      line_text = text.lines[line0]? || ""
      column = Lsp.column_of(line_text, char)

      target = Location.new(path, line0 + 1, column)
      visitor = @analysis.references_at(path, text, overrides_for(path), target)
      span = word_range(line_text, column)
      return respond_null(id) unless visitor && span

      from, to = span
      start_ch = Lsp.character_of(line_text, from + 1)
      end_ch = Lsp.character_of(line_text, to + 2)
      respond(id) do |json|
        json.object do
          json.field "range" { range(json, line0, start_ch, line0, end_ch) }
          json.field "placeholder", line_text[from..to]
        end
      end
    end

    # ── Type definition ──────────────────────────────────────────────────

    private def on_type_definition(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)
      line0 = params["position"]["line"].as_i
      char = params["position"]["character"].as_i
      line_text = text.lines[line0]? || ""
      column = Lsp.column_of(line_text, char)

      locations = @analysis.type_locations_at(
        path, text, overrides_for(path), line0 + 1, column, word_at(line_text, column))
      return respond_null(id) if locations.empty?

      respond(id) do |json|
        json.array do
          locations.each do |location|
            filename = location.filename
            next unless filename.is_a?(String)
            target_line = read_line(filename, location.line_number)
            ch = Lsp.character_of(target_line, location.column_number)
            json.object do
              json.field "uri", uri_of(filename)
              json.field "range" { range(json, location.line_number - 1, ch, location.line_number - 1, ch) }
            end
          end
        end
      end
    end

    # ── Document highlight ───────────────────────────────────────────────

    # References, scoped to the buffer under the cursor: one compile,
    # the sites in this file only, the declaration marked as the write.
    private def on_document_highlight(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)
      line0 = params["position"]["line"].as_i
      char = params["position"]["character"].as_i
      line_text = text.lines[line0]? || ""
      target = Location.new(path, line0 + 1, Lsp.column_of(line_text, char))

      visitor = @analysis.references_at(path, text, overrides_for(path), target)
      return respond_null(id) unless visitor

      respond(id) do |json|
        json.array do
          {visitor.declarations, visitor.references}.each_with_index do |sites, group|
            sites.each do |(location, size)|
              next unless location.filename == path
              target_line = read_line(path, location.line_number)
              start_ch = Lsp.character_of(target_line, location.column_number)
              end_ch = Lsp.character_of(target_line, location.column_number + size)
              json.object do
                json.field "range" { range(json, location.line_number - 1, start_ch, location.line_number - 1, end_ch) }
                json.field "kind", group.zero? ? 3 : 2 # Write the def, Read the calls
              end
            end
          end
        end
      end
    end

    # ── Signature help ───────────────────────────────────────────────────

    # The half-typed call is found by text — the buffer stopped parsing
    # the moment the `(` landed — and its overloads by the typed graph:
    # the callee resolves in the scope the cursor sits in, off the last
    # compile that held together.
    private def on_signature_help(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)
      line0 = params["position"]["line"].as_i
      char = params["position"]["character"].as_i
      lines = text.lines
      line_text = lines[line0]? || ""
      cursor = Lsp.column_of(line_text, char) - 1

      call = enclosing_call(lines, line0, cursor)
      return respond_null(id) unless call
      receiver, name, commas = call

      signatures = @analysis.signatures_at(
        path, text, overrides_for(path), line0 + 1,
        Lsp.column_of(line_text, char), receiver, name)
      return respond_null(id) if signatures.empty?

      active = signatures.index { |sig| sig.params.size > commas } || 0
      respond(id) do |json|
        json.object do
          json.field "activeSignature", active
          json.field "activeParameter", commas
          json.field "signatures" do
            json.array do
              signatures.each do |sig|
                json.object do
                  json.field "label", sig.label
                  if doc = sig.doc
                    json.field "documentation", doc
                  end
                  json.field "parameters" do
                    json.array do
                      sig.params.each do |param|
                        json.object { json.field "label", param }
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # Walk backwards from the cursor to the unclosed `(`, counting the
    # commas at its depth; what precedes it is the callee, maybe with a
    # `receiver.` in front. Text, not syntax — the buffer mid-call has
    # no syntax yet — and bounded, so a pathological file cannot stall
    # a keystroke. Returns {receiver, name, commas-before-cursor}.
    private def enclosing_call(lines : Array(String), line0 : Int32, cursor : Int32) : {String?, String, Int32}?
      chars = [] of Char
      ({line0 - 40, 0}.max...line0).each do |index|
        chars.concat (lines[index]? || "").chars
        chars << '\n'
      end
      line_chars = (lines[line0]? || "").chars
      chars.concat line_chars[0, {cursor, line_chars.size}.min]

      depth = 0
      commas = 0
      found = -1
      index = chars.size - 1
      while index >= 0
        case chars[index]
        when ')', ']', '}'
          depth += 1
        when '[', '{'
          depth -= 1 if depth > 0
        when '('
          if depth.zero?
            found = index
            break
          end
          depth -= 1
        when ','
          commas += 1 if depth.zero?
        end
        index -= 1
      end
      return nil if found <= 0

      name_end = found - 1
      from = chars[name_end].in?('?', '!') ? name_end - 1 : name_end
      while from >= 0 && name_char?(chars[from])
        from -= 1
      end
      name = chars[(from + 1)..name_end].join
      return nil if name.empty?
      return nil unless name[0].ascii_letter? || name[0] == '_'
      return nil if name[0].ascii_uppercase? # `Foo(` instantiates a generic

      receiver = nil
      if from >= 0 && chars[from] == '.'
        rec_end = from - 1
        rec_from = rec_end
        while rec_from >= 0 && (name_char?(chars[rec_from]) || chars[rec_from] == '@')
          rec_from -= 1
        end
        if rec_end >= 0 && rec_end > rec_from
          receiver = chars[(rec_from + 1)..rec_end].join
        end
      end

      {receiver, name, commas}
    end

    # ── Formatting ───────────────────────────────────────────────────────

    # The formatter, in process: the same `Iyi.format` the CLI verb
    # runs, answered as one whole-document edit. A buffer that does not
    # parse keeps its bytes — the diagnostics channel already says why.
    private def on_formatting(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      text = text_of(uri)
      formatted =
        begin
          Iyi.format(text, filename: path_of(uri))
        rescue CodeError
          return respond_null(id)
        end
      return respond(id) { |json| json.array { } } if formatted == text

      lines = text.split('\n')
      end_line0 = lines.size - 1
      end_ch = Lsp.character_of(lines[end_line0], lines[end_line0].size + 1)
      respond(id) do |json|
        json.array do
          json.object do
            json.field "range" { range(json, 0, 0, end_line0, end_ch) }
            json.field "newText", formatted
          end
        end
      end
    end

    # ── Folding ranges ───────────────────────────────────────────────────

    # Declarations fold off the outline; comment blocks and the import
    # header fold off the text — all of it survives a buffer that does
    # not compile.
    private def on_folding_range(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      text = text_of(uri)
      folds = [] of {Int32, Int32, String?}
      collect_symbol_folds(Outline.build(text, path_of(uri)), folds)

      lines = text.lines
      run_start = nil
      run_kind = nil
      lines.each_with_index do |line, index|
        stripped = line.strip
        kind =
          if stripped.starts_with?('#')
            "comment"
          elsif stripped.starts_with?("import ") || stripped.starts_with?("using ")
            "imports"
          end
        next if kind == run_kind
        if (start = run_start) && (ended = run_kind) && index - 1 > start
          folds << {start, index - 1, ended}
        end
        run_start = kind ? index : nil
        run_kind = kind
      end
      if (start = run_start) && (ended = run_kind) && lines.size - 1 > start
        folds << {start, lines.size - 1, ended}
      end

      respond(id) do |json|
        json.array do
          folds.each do |(start_line, end_line, kind)|
            json.object do
              json.field "startLine", start_line
              json.field "endLine", end_line
              json.field "kind", kind if kind
            end
          end
        end
      end
    end

    private def collect_symbol_folds(symbols : Array(Outline::Sym), into : Array({Int32, Int32, String?})) : Nil
      symbols.each do |sym|
        into << {sym.line - 1, sym.end_line - 1, nil} if sym.end_line > sym.line
        collect_symbol_folds(sym.children, into)
      end
    end

    # ── Workspace symbols ────────────────────────────────────────────────

    # Every `.iyi` file the workspace holds, open buffers winning over
    # the disk, outlined by the parser and filtered by subsequence — the
    # match every editor's muscle memory expects. No index: parsing a
    # module costs microseconds, and an index is a cache with an
    # invalidation story.
    private def on_workspace_symbol(id : JSON::Any, params : JSON::Any) : Nil
      query = params["query"]?.try(&.as_s?) || ""

      paths = @documents.keys.map { |doc_uri| path_of(doc_uri) }
      if root = @root
        Dir.glob(::Path[root].to_posix.join("**", "*.iyi")) do |file|
          posix = ::Path[file].to_posix.to_s
          next if posix.includes?("/.") || posix.includes?("/lib/")
          paths << posix unless paths.includes?(posix)
          break if paths.size >= 2000
        end
      end

      results = [] of {String, Int32, String, Int32, Int32, Int32, String?}
      paths.each do |file|
        text = @documents[uri_of(file)]? || (File.file?(file) ? File.read(file) : nil)
        next unless text
        collect_workspace_symbols(Outline.build(text, file), file, text.lines, query, nil, results)
        break if results.size >= 400
      end

      respond(id) do |json|
        json.array do
          results.each do |(name, kind, file, line0, start_ch, end_ch, container)|
            json.object do
              json.field "name", name
              json.field "kind", kind
              json.field "location" do
                json.object do
                  json.field "uri", uri_of(file)
                  json.field "range" { range(json, line0, start_ch, line0, end_ch) }
                end
              end
              json.field "containerName", container if container
            end
          end
        end
      end
    end

    private def collect_workspace_symbols(symbols : Array(Outline::Sym), file : String, lines : Array(String), query : String, container : String?, into : Array({String, Int32, String, Int32, Int32, Int32, String?})) : Nil
      symbols.each do |sym|
        if fuzzy_match?(query, sym.name)
          name_line = lines[sym.name_line - 1]? || ""
          start_ch = Lsp.character_of(name_line, sym.name_column)
          end_ch = Lsp.character_of(name_line, sym.name_column + sym.name.size)
          into << {sym.name, sym.kind, file, sym.name_line - 1, start_ch, end_ch, container}
        end
        collect_workspace_symbols(sym.children, file, lines, query, sym.name, into)
      end
    end

    # Subsequence, case-insensitive: `psr` finds `ParseResult`.
    private def fuzzy_match?(query : String, name : String) : Bool
      return true if query.empty?
      qchars = query.downcase.chars
      qi = 0
      name.downcase.each_char do |ch|
        qi += 1 if qi < qchars.size && ch == qchars[qi]
      end
      qi == qchars.size
    end

    # ── Semantic tokens ──────────────────────────────────────────────────

    private def on_semantic_tokens(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      data = semantic_token_data(text_of(uri))
      result_id = remember_tokens(uri, data)
      respond(id) do |json|
        json.object do
          json.field "resultId", result_id
          json.field "data" { json.array { data.each { |n| json.number n } } }
        end
      end
    end

    # Delta: the splice between the last answer and this one — a
    # one-line edit moves five integers, not the whole file's stream.
    # An unknown previousResultId falls back to a full answer, which is
    # always correct.
    private def on_semantic_tokens_delta(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      previous_id = params["previousResultId"]?.try(&.as_s?)
      data = semantic_token_data(text_of(uri))

      previous = @token_data[uri]?
      unless previous && previous[0] == previous_id
        result_id = remember_tokens(uri, data)
        return respond(id) do |json|
          json.object do
            json.field "resultId", result_id
            json.field "data" { json.array { data.each { |n| json.number n } } }
          end
        end
      end

      old = previous[1]
      prefix = 0
      while prefix < old.size && prefix < data.size && old[prefix] == data[prefix]
        prefix += 1
      end
      suffix = 0
      while suffix < old.size - prefix && suffix < data.size - prefix &&
            old[old.size - 1 - suffix] == data[data.size - 1 - suffix]
        suffix += 1
      end

      result_id = remember_tokens(uri, data)
      respond(id) do |json|
        json.object do
          json.field "resultId", result_id
          json.field "edits" do
            json.array do
              unless old.size == data.size && prefix == old.size
                json.object do
                  json.field "start", prefix
                  json.field "deleteCount", old.size - prefix - suffix
                  json.field "data" do
                    json.array do
                      (prefix...(data.size - suffix)).each { |index| json.number data[index] }
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    private def remember_tokens(uri : String, data : Array(Int32)) : String
      @token_result += 1
      result_id = @token_result.to_s
      @token_data[uri] = {result_id, data}
      result_id
    end

    private def semantic_token_data(text : String) : Array(Int32)
      lines = text.lines
      toks = Tokens.scan(text)
      toks.sort_by! { |tok| {tok.line, tok.column} }

      data = [] of Int32
      prev_line = 0
      prev_start = 0
      emitted = false
      toks.each do |tok|
        line0 = tok.line - 1
        next if line0 < 0
        line_text = lines[line0]? || ""
        start_ch = Lsp.character_of(line_text, tok.column)
        length = Lsp.character_of(line_text, tok.column + tok.size) - start_ch
        next if length <= 0
        next if emitted && (line0 < prev_line || (line0 == prev_line && start_ch <= prev_start))
        delta_line = line0 - prev_line
        data << delta_line
        data << (delta_line.zero? && emitted ? start_ch - prev_start : start_ch)
        data << length
        data << tok.type
        data << 0
        prev_line = line0
        prev_start = start_ch
        emitted = true
      end
      data
    end

    # ── Inlay hints ──────────────────────────────────────────────────────

    private def on_inlay_hint(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)
      from_line = params["range"]["start"]["line"].as_i + 1
      to_line = params["range"]["end"]["line"].as_i + 1

      hints = @analysis.inlay_hints_at(path, text, overrides_for(path), from_line, to_line)
      return respond_null(id) if hints.empty?

      lines = text.lines
      respond(id) do |json|
        json.array do
          hints.each do |hint|
            line_text = lines[hint.line - 1]? || ""
            json.object do
              json.field "position" do
                json.object do
                  json.field "line", hint.line - 1
                  json.field "character", Lsp.character_of(line_text, hint.column)
                end
              end
              json.field "label", hint.label
              json.field "kind", hint.kind
              json.field "paddingRight", true if hint.kind == InlayVisitor::KIND_PARAMETER
              # `total : Int32`, the way the formatter writes it — not
              # `total: Int32`, which reads as different syntax.
              json.field "paddingLeft", true if hint.kind == InlayVisitor::KIND_TYPE
            end
          end
        end
      end
    end

    # ── Code actions ─────────────────────────────────────────────────────

    # The compiler's own suggestion, made clickable: a diagnostic that
    # carries `Diag#suggestion` — set at the raise site, next to the
    # prose — becomes a quickfix performing the change. No new analysis,
    # and no scanning our own message strings: the name travels as data
    # from the exception to the edit.

    private def on_code_action(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      from = params["range"]["start"]["line"].as_i
      to = params["range"]["end"]["line"].as_i
      only = params["context"]?.try(&.["only"]?).try(&.as_a?.try(&.compact_map(&.as_s?)))

      actions = (@published[uri]? || [] of {Int32, Int32, Int32, String, String?}).compact_map do |(line0, start_ch, end_ch, message, suggestion)|
        next unless action_wanted?(only, "quickfix")
        next unless line0 >= from && line0 <= to && end_ch > start_ch
        next unless suggestion
        {line0, start_ch, end_ch, message, suggestion}
      end

      organize =
        if action_wanted?(only, "source.organizeImports")
          organize_imports(text_of(uri))
        end
      respond(id) do |json|
        json.array do
          actions.each do |(line0, start_ch, end_ch, message, suggestion)|
            json.object do
              json.field "title", "Change to '#{suggestion}'"
              json.field "kind", "quickfix"
              json.field "diagnostics" do
                json.array do
                  json.object do
                    json.field "range" { range(json, line0, start_ch, line0, end_ch) }
                    json.field "severity", 1
                    json.field "source", "iyi"
                    json.field "message", message
                  end
                end
              end
              json.field "edit" do
                json.object do
                  json.field "changes" do
                    json.object do
                      json.field uri do
                        json.array do
                          json.object do
                            json.field "range" { range(json, line0, start_ch, line0, end_ch) }
                            json.field "newText", suggestion
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
          if organize
            block_start, block_end, new_text = organize
            end_line_text = text_of(uri).lines[block_end]? || ""
            json.object do
              json.field "title", "Organize imports"
              json.field "kind", "source.organizeImports"
              json.field "edit" do
                json.object do
                  json.field "changes" do
                    json.object do
                      json.field uri do
                        json.array do
                          json.object do
                            json.field "range" do
                              range(json, block_start, 0, block_end,
                                Lsp.character_of(end_line_text, end_line_text.size + 1))
                            end
                            json.field "newText", new_text
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # `only` honored the way the spec asks: a requested kind matches
    # itself and anything beneath it.
    private def action_wanted?(only : Array(String)?, kind : String) : Bool
      return true unless only && !only.empty?
      only.any? { |wanted| kind == wanted || kind.starts_with?("#{wanted}.") }
    end

    # The header block, canonicalised: imports sorted and deduped, then
    # a blank line, then `using` lines sorted — selective selections of
    # one module merged and their names sorted, a full `using` absorbing
    # them. Anything in the block this function does not understand — a
    # comment between imports, a trailing remark — makes it offer
    # nothing: an organizer that might eat a comment is not an organizer.
    private def organize_imports(text : String) : {Int32, Int32, String}?
      lines = text.lines
      first : Int32? = nil
      last : Int32? = nil

      imports = [] of String
      full_usings = [] of String
      selective = {} of String => Array(String)

      lines.each_with_index do |line, index|
        stripped = line.strip
        if stripped.starts_with?("import ") || stripped.starts_with?("using ")
          first ||= index
          break if last && lines[(last + 1)...index].any? { |between| !between.strip.empty? }
          last = index
          if mod = stripped.lchop?("import ")
            return nil unless clean_module?(mod)
            imports << mod
          elsif rest = stripped.lchop?("using ")
            if brace = rest.index("::{")
              mod = rest[0, brace]
              names = rest[(brace + 3)..]
              return nil unless names.ends_with?('}') && clean_module?(mod)
              (selective[mod] ||= [] of String).concat names.rchop.split(',').map(&.strip)
            else
              return nil unless clean_module?(rest)
              full_usings << rest
            end
          end
        elsif first && !stripped.empty?
          break
        end
      end
      return nil unless first && last

      organized = String.build do |io|
        imports.uniq!.sort!
        imports.each_with_index do |mod, index|
          io << '\n' unless index.zero?
          io << "import " << mod
        end
        modules = (full_usings + selective.keys).uniq!.sort!
        io << '\n' << '\n' if !imports.empty? && !modules.empty?
        modules.each_with_index do |mod, index|
          io << '\n' unless index.zero?
          if full_usings.includes?(mod)
            io << "using " << mod
          else
            names = selective[mod].uniq!.sort!
            io << "using " << mod << "::{" << names.join(", ") << '}'
          end
        end
      end

      current = lines[first..last].join('\n')
      return nil if current == organized
      {first, last, organized}
    end

    # A module path and nothing else on the line: letters, digits,
    # underscores, slashes. A trailing comment fails the test on purpose.
    private def clean_module?(mod : String) : Bool
      !mod.empty? && mod.each_char.all? { |ch| ch.alphanumeric? || ch == '_' || ch == '/' }
    end

    # ── File renames ─────────────────────────────────────────────────────

    # IV.6 read forward: a module's path is its file's path, so moving
    # the file *is* renaming the module — the header line and every
    # consumer's `import`/`using` move with it, in one WorkspaceEdit
    # the client applies before the rename lands on disk. A file whose
    # header and path disagree has no module identity to move, and is
    # left alone by name.
    private def on_will_rename_files(id : JSON::Any, params : JSON::Any) : Nil
      edits = {} of String => Array({Int32, Int32, Int32, String})

      params["files"].as_a.each do |file|
        old_path = path_of(file["oldUri"].as_s)
        new_path = path_of(file["newUri"].as_s)
        next unless old_path.ends_with?(".iyi") && new_path.ends_with?(".iyi")

        text = @documents[uri_of(old_path)]? || (File.file?(old_path) ? File.read(old_path) : nil)
        next unless text
        old_mod = Exports.header_of(text)
        next unless old_mod
        # Read as posix, the way `Compiler.header_root_of` reads the same
        # question: a module path is posix by grammar (R-1) and these two are
        # filesystem paths. A `file://` URI spells `/` on Windows as well, so
        # this is the one of the three that was not already answering for the
        # wrong files, and now it does not depend on where its paths came
        # from either.
        old_posix = ::Path[old_path].to_posix.to_s
        new_posix = ::Path[new_path].to_posix.to_s
        suffix = "/#{old_mod}.iyi"
        next unless old_posix.ends_with?(suffix)

        root = old_posix[0, old_posix.size - suffix.size]
        prefix = root.empty? ? "/" : root + "/"
        next unless new_posix.starts_with?(prefix)
        new_mod = new_posix[prefix.size..].rchop(".iyi")
        next if new_mod.empty? || new_mod == old_mod || !clean_module?(new_mod)

        (edits[uri_of(old_path)] ||= [] of {Int32, Int32, Int32, String})
          .concat module_mention_edits(text, old_mod, new_mod)
        workspace_entries.each do |(entry_path, entry_text)|
          next if entry_path == old_path
          mentions = module_mention_edits(entry_text, old_mod, new_mod)
          next if mentions.empty?
          (edits[uri_of(entry_path)] ||= [] of {Int32, Int32, Int32, String})
            .concat mentions
        end
      end

      return respond_null(id) if edits.empty?

      respond(id) do |json|
        json.object do
          json.field "changes" do
            json.object do
              edits.each do |edit_uri, rows|
                json.field edit_uri do
                  json.array do
                    rows.each do |(line0, start_ch, end_ch, new_text)|
                      json.object do
                        json.field "range" { range(json, line0, start_ch, line0, end_ch) }
                        json.field "newText", new_text
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # Every line that names `old_mod` as a module — the `module` header,
    # an `import`, a `using` (selective or full) — with the exact span
    # of the path, so the rename touches nothing else on the line.
    private def module_mention_edits(text : String, old_mod : String, new_mod : String) : Array({Int32, Int32, Int32, String})
      edits = [] of {Int32, Int32, Int32, String}
      text.lines.each_with_index do |line, index|
        stripped = line.lstrip
        keyword =
          if stripped.starts_with?("module ")
            "module "
          elsif stripped.starts_with?("import ")
            "import "
          elsif stripped.starts_with?("using ")
            "using "
          end
        next unless keyword
        rest = stripped.lchop(keyword)
        next unless rest == old_mod || rest.starts_with?("#{old_mod}::")
        start_col = line.size - stripped.size + keyword.size
        start_ch = Lsp.character_of(line, start_col + 1)
        end_ch = Lsp.character_of(line, start_col + old_mod.size + 1)
        edits << {index, start_ch, end_ch, new_mod}
      end
      edits
    end

    # ── Implementation ───────────────────────────────────────────────────

    # The trait under the cursor answers with the types that implement
    # it. An impl became an `include` in the semantic pass, so the walk
    # asks the type tree, not a registry.
    private def on_implementation(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)
      line0 = params["position"]["line"].as_i
      char = params["position"]["character"].as_i
      line_text = text.lines[line0]? || ""
      column = Lsp.column_of(line_text, char)

      locations = @analysis.implementors_at(
        path, text, overrides_for(path), word_at(line_text, column))
      return respond_null(id) if locations.empty?

      respond(id) do |json|
        json.array do
          locations.each do |location|
            filename = location.filename
            next unless filename.is_a?(String)
            target_line = read_line(filename, location.line_number)
            ch = Lsp.character_of(target_line, location.column_number)
            json.object do
              json.field "uri", uri_of(filename)
              json.field "range" { range(json, location.line_number - 1, ch, location.line_number - 1, ch) }
            end
          end
        end
      end
    end

    # ── Call hierarchy ───────────────────────────────────────────────────

    # The item's `data` carries the def's source key {file, line,
    # column} — the location every compile of the same source
    # reproduces — so incoming and outgoing never re-derive the target
    # from wire positions.
    private def on_prepare_call_hierarchy(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)
      line0 = params["position"]["line"].as_i
      char = params["position"]["character"].as_i
      line_text = text.lines[line0]? || ""
      column = Lsp.column_of(line_text, char)

      sites = @analysis.hierarchy_targets_at(path, text, overrides_for(path), line0 + 1, column)
      return respond_null(id) if sites.empty?

      respond(id) do |json|
        json.array do
          sites.each { |site| hierarchy_item(json, site) }
        end
      end
    end

    private def hierarchy_item(json : JSON::Builder, site : HierarchySite) : Nil
      name_line = read_line(site.filename, site.name_line)
      sel_start = Lsp.character_of(name_line, site.name_column)
      sel_end = Lsp.character_of(name_line, site.name_column + site.name_size)
      end_line = read_line(site.filename, site.end_line)
      json.object do
        json.field "name", site.name
        json.field "kind", 6 # Method
        json.field "uri", uri_of(site.filename)
        json.field "range" { range(json, site.line - 1, 0, site.end_line - 1, Lsp.character_of(end_line, end_line.size + 1)) }
        json.field "selectionRange" { range(json, site.name_line - 1, sel_start, site.name_line - 1, sel_end) }
        json.field "data" do
          json.object do
            json.field "file", site.filename
            json.field "line", site.line
            json.field "column", site.column
          end
        end
      end
    end

    private def hierarchy_key(params : JSON::Any) : {String, Int32, Int32}?
      data = params["item"]?.try(&.["data"]?)
      return nil unless data
      file = data["file"]?.try(&.as_s?)
      line = data["line"]?.try(&.as_i?)
      column = data["column"]?.try(&.as_i?)
      return nil unless file && line && column
      {file, line, column}
    end

    # Incoming: under R-1 a def's callers live in its consumers'
    # compiles, so every entry whose imports reach the def's module
    # answers and the edges merge — the references rule, one level up.
    private def on_incoming_calls(id : JSON::Any, params : JSON::Any) : Nil
      key = hierarchy_key(params)
      return respond_null(id) unless key

      entries = workspace_entries
      unless entries.any? { |(entry_path, _)| entry_path == key[0] }
        entries << {key[0], File.read(key[0])} if File.file?(key[0])
      end

      merged = {} of {String, Int32, Int32} => {HierarchySite?, Array(CallSite)}
      entries_reaching(entries, {key[0]}).each do |(entry_path, entry_text)|
        visitor = @analysis.incoming_calls_at(entry_path, entry_text, overrides_for(entry_path), key)
        next unless visitor
        visitor.calls.each do |group, (site, calls)|
          entry = merged[group] ||= {site, [] of CallSite}
          entry[1].concat calls
        end
      end
      return respond_null(id) if merged.empty?

      respond(id) do |json|
        json.array do
          merged.each do |_, (site, calls)|
            calls.uniq!
            json.object do
              json.field "from" do
                if site
                  hierarchy_item(json, site)
                else
                  # The file's main expressions call too; the file is
                  # the caller.
                  file = calls.first[0]
                  json.object do
                    json.field "name", File.basename(file)
                    json.field "kind", 2 # Module
                    json.field "uri", uri_of(file)
                    json.field "range" { range(json, calls.first[1] - 1, 0, calls.first[1] - 1, 0) }
                    json.field "selectionRange" { range(json, calls.first[1] - 1, 0, calls.first[1] - 1, 0) }
                  end
                end
              end
              json.field "fromRanges" { call_ranges(json, calls) }
            end
          end
        end
      end
    end

    # Outgoing: the body lives in the def's own file, so one compile is
    # the whole answer.
    private def on_outgoing_calls(id : JSON::Any, params : JSON::Any) : Nil
      key = hierarchy_key(params)
      return respond_null(id) unless key

      file = key[0]
      text = @documents[uri_of(file)]? || (File.file?(file) ? File.read(file) : nil)
      return respond_null(id) unless text

      visitor = @analysis.outgoing_calls_at(file, text, overrides_for(file), key)
      return respond_null(id) unless visitor && !visitor.calls.empty?

      respond(id) do |json|
        json.array do
          visitor.calls.each do |_, (site, calls)|
            calls.uniq!
            json.object do
              json.field "to" { hierarchy_item(json, site) }
              json.field "fromRanges" { call_ranges(json, calls) }
            end
          end
        end
      end
    end

    private def call_ranges(json : JSON::Builder, calls : Array(CallSite)) : Nil
      json.array do
        calls.each do |(file, line, column, size)|
          target_line = read_line(file, line)
          start_ch = Lsp.character_of(target_line, column)
          end_ch = Lsp.character_of(target_line, column + size)
          range(json, line - 1, start_ch, line - 1, end_ch)
        end
      end
    end

    # ── Selection range ──────────────────────────────────────────────────

    # Expand-selection off the parse tree alone: every node whose span
    # holds the position, innermost out. Syntax, not semantics — the
    # buffer mid-edit still answers.
    private def on_selection_range(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)
      lines = text.lines

      parsed =
        begin
          parser = Parser.new(text)
          parser.filename = path
          parser.parse
        rescue CodeError
          return respond_null(id)
        end

      respond(id) do |json|
        json.array do
          params["positions"].as_a.each do |position|
            line0 = position["line"].as_i
            char = position["character"].as_i
            line_text = lines[line0]? || ""
            column = Lsp.column_of(line_text, char)

            collector = SpanCollector.new(Location.new(path, line0 + 1, column))
            parsed.accept collector
            chain = nest_spans(collector.spans)

            if chain.empty?
              json.object do
                json.field "range" { range(json, line0, char, line0, char) }
              end
            else
              write_selection(json, chain, chain.size - 1, lines)
            end
          end
        end
      end
    end

    # Outermost-first spans → the strictly nested chain the protocol
    # wants. Sorting by (start asc, end desc) puts a container before
    # its contents; anything that breaks nesting is dropped.
    private def nest_spans(spans : Array({Location, Location})) : Array({Location, Location})
      spans.sort! do |a, b|
        cmp = (a[0] <=> b[0]) || 0
        cmp.zero? ? ((b[1] <=> a[1]) || 0) : cmp
      end
      chain = [] of {Location, Location}
      spans.each do |span|
        if last = chain.last?
          next if span[0] == last[0] && span[1] == last[1]
          next unless last[0] <= span[0] && span[1] <= last[1]
        end
        chain << span
      end
      chain
    end

    # chain[index] innermost-out via recursion: the object is the
    # innermost range, its `parent` the next span outward.
    private def write_selection(json : JSON::Builder, chain : Array({Location, Location}), index : Int32, lines : Array(String)) : Nil
      start_loc, end_loc = chain[index]
      start_line = lines[start_loc.line_number - 1]? || ""
      end_line = lines[end_loc.line_number - 1]? || ""
      json.object do
        json.field "range" do
          range(json,
            start_loc.line_number - 1, Lsp.character_of(start_line, start_loc.column_number),
            end_loc.line_number - 1, Lsp.character_of(end_line, end_loc.column_number + 1))
        end
        if index > 0
          json.field "parent" { write_selection(json, chain, index - 1, lines) }
        end
      end
    end

    # ── Document links ───────────────────────────────────────────────────

    # `import calc/lexer` names a file; the link makes it clickable.
    # Text, not syntax — the header block is line-shaped by design
    # (II.3 rule 4), so a broken buffer still links its imports.
    private def on_document_link(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)

      roots = [] of String
      if (header = Exports.header_of(text)) && path.ends_with?("/#{header}.iyi")
        derived = path[0, path.size - header.size - 5]
        roots << (derived.empty? ? "/" : derived)
      end
      if root = @root
        roots << root unless roots.includes?(root)
      end
      roots << File.dirname(path)

      respond(id) do |json|
        json.array do
          text.lines.each_with_index do |line, index|
            stripped = line.lstrip
            keyword =
              if stripped.starts_with?("import ")
                "import "
              elsif stripped.starts_with?("using ")
                "using "
              end
            next unless keyword
            mod = stripped.lchop(keyword).each_char
              .take_while { |ch| ch.alphanumeric? || ch == '_' || ch == '/' }
              .join
            next if mod.empty?
            target = roots.each do |candidate_root|
              candidate = File.join(candidate_root, mod + ".iyi")
              break candidate if File.file?(candidate) || @documents.has_key?(uri_of(candidate))
            end
            next unless target
            start_col = line.size - stripped.size + keyword.size
            start_ch = Lsp.character_of(line, start_col + 1)
            end_ch = Lsp.character_of(line, start_col + mod.size + 1)
            json.object do
              json.field "range" { range(json, index, start_ch, index, end_ch) }
              json.field "target", uri_of(target)
            end
          end
        end
      end
    end

    # ── Type hierarchy ───────────────────────────────────────────────────

    # The item's `data` carries the type's short name and the document
    # whose compile knows it, so supertypes and subtypes re-ask the same
    # program the prepare answered from.
    private def on_prepare_type_hierarchy(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      path = path_of(uri)
      text = text_of(uri)
      line0 = params["position"]["line"].as_i
      char = params["position"]["character"].as_i
      line_text = text.lines[line0]? || ""
      column = Lsp.column_of(line_text, char)

      sites = @analysis.hierarchy_types_named(
        path, text, overrides_for(path), word_at(line_text, column))
      return respond_null(id) if sites.empty?

      respond(id) do |json|
        json.array do
          sites.each { |site| type_hierarchy_item(json, site, path) }
        end
      end
    end

    private def type_hierarchy_item(json : JSON::Builder, site : Analysis::TypeSite, context : String) : Nil
      filename = site.location.filename.to_s
      target_line = read_line(filename, site.location.line_number)
      ch = Lsp.character_of(target_line, site.location.column_number)
      json.object do
        json.field "name", site.name
        json.field "kind", site.kind
        json.field "uri", uri_of(filename)
        json.field "range" { range(json, site.location.line_number - 1, ch, site.location.line_number - 1, ch) }
        json.field "selectionRange" { range(json, site.location.line_number - 1, ch, site.location.line_number - 1, ch) }
        json.field "data" do
          json.object do
            json.field "name", site.name
            json.field "context", context
          end
        end
      end
    end

    private def on_supertypes(id : JSON::Any, params : JSON::Any) : Nil
      hierarchy_related(id, params) do |context, text, name|
        @analysis.supertypes_of(context, text, overrides_for(context), name)
      end
    end

    private def on_subtypes(id : JSON::Any, params : JSON::Any) : Nil
      hierarchy_related(id, params) do |context, text, name|
        @analysis.subtypes_of(context, text, overrides_for(context), name)
      end
    end

    private def hierarchy_related(id : JSON::Any, params : JSON::Any, & : String, String, String -> Array(Analysis::TypeSite)) : Nil
      data = params["item"]?.try(&.["data"]?)
      name = data.try(&.["name"]?).try(&.as_s?)
      context = data.try(&.["context"]?).try(&.as_s?)
      return respond_null(id) unless name && context

      text = @documents[uri_of(context)]? || (File.file?(context) ? File.read(context) : nil)
      return respond_null(id) unless text

      sites = yield context, text, name
      respond(id) do |json|
        json.array do
          sites.each { |site| type_hierarchy_item(json, site, context) }
        end
      end
    end

    # ── Incremental sync ─────────────────────────────────────────────────
    #
    # The arithmetic is `Text`'s: the proxy in front of this server keeps
    # the same buffers and has to apply the same changes.

    # The workspace root the client named at initialize, for
    # workspace/symbol to glob under.
    private def root_of(params : JSON::Any?) : String?
      return nil unless params
      if folders = params["workspaceFolders"]?.try(&.as_a?)
        if first = folders.first?
          if folder_uri = first["uri"]?.try(&.as_s?)
            return path_of(folder_uri)
          end
        end
      end
      if root_uri = params["rootUri"]?.try(&.as_s?)
        return path_of(root_uri)
      end
      params["rootPath"]?.try(&.as_s?)
    end

    # ── Code lens and its command ────────────────────────────────────────

    # One lens, on the file's first top-level statement: a module whose
    # body *does* something is runnable, and the lens says so. The
    # command runs the released verb — `iyi run` — against the buffer,
    # dirty state included, and returns what it printed.
    private def on_code_lens(id : JSON::Any, params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      text = text_of(uri)
      line = runnable_line(text, path_of(uri))
      return respond(id) { |json| json.array { } } unless line

      respond(id) do |json|
        json.array do
          json.object do
            json.field "range" { range(json, line - 1, 0, line - 1, 0) }
            json.field "command" do
              json.object do
                json.field "title", "▶ run"
                json.field "command", "iyi.run"
                json.field "arguments" do
                  json.array { json.string uri }
                end
              end
            end
          end
        end
      end
    end

    # The 1-based line of the first top-level statement that is not a
    # declaration — the line a person means by "the program".
    private def runnable_line(text : String, path : String) : Int32?
      parser = Parser.new(text)
      parser.filename = path
      first_statement(parser.parse)
    rescue CodeError
      nil
    end

    private def first_statement(node : ASTNode) : Int32?
      case node
      when Expressions
        node.expressions.each do |child|
          if found = first_statement(child)
            return found
          end
        end
        nil
      when ModuleDef
        first_statement(node.body)
      when ClassDef, TraitDef, EnumDef, LibDef, ImplDef, Def, Macro,
           UsingDecl, ImportDecl, Require, VisibilityModifier, Nop,
           Extend, Include, Alias, AnnotationDef, ModuleHeader
        nil
      when Assign
        node.target.is_a?(Path) ? nil : node.location.try(&.line_number)
      else
        node.location.try(&.line_number)
      end
    end

    private def on_execute_command(id : JSON::Any, params : JSON::Any) : Nil
      command = params["command"].as_s
      case command
      when "iyi.run"
        uri = params["arguments"]?.try(&.[0]?).try(&.as_s?)
        raise "iyi.run takes the document uri" unless uri
        run_verb(id, uri, "run")
      else
        raise "unknown command '#{command}'"
      end
    end

    # ── The agent endpoints: the CLI's own verbs over the wire ───────────

    # `iyi/contextPack` and `iyi/surface` run the released verbs against
    # the document — the same output `iyi mod context --json` and
    # `iyi doc` print, framed as a response. A dirty buffer is
    # materialised beside the file first, so the pack grounds what the
    # editor sees, not what the disk last saw.
    private def on_delegated(id : JSON::Any, params : JSON::Any, *verb : String) : Nil
      run_verb(id, params["textDocument"]["uri"].as_s, *verb)
    end

    # One released verb against one document, bounded: `iyi.run`
    # executes the person's own program, and a program that never
    # returns must not take the session with it.
    RUN_LIMIT = 30.seconds

    # How many verbs may be out at once. A person clicks `▶ run` twice;
    # a client with a stuck retry clicks it a thousand times.
    RUNS_IN_FLIGHT = 4

    private def run_verb(id : JSON::Any, uri : String, *verb : String) : Nil
      if @running_verbs >= RUNS_IN_FLIGHT
        return respond(id) do |json|
          json.object do
            json.field "ok", false
            json.field "output", ""
            json.field "error", "#{RUNS_IN_FLIGHT} verbs are already running for this session"
          end
        end
      end

      path = path_of(uri)

      scratch = nil
      if (text = @documents[uri]?) && (!File.file?(path) || File.read(path) != text)
        scratch = File.join(File.dirname(path), ".#{File.basename(path, ".iyi")}.iyi-lsp.iyi")
        File.write(scratch, text)
        path = scratch
      end

      # The pipes are ours, not `Process`'s. Handing it an `IO` makes
      # `wait` wait for end-of-file on that pipe as well as for the
      # child, and `iyi run` hands the pipe down to the program it built:
      # a program that serves never closes it, so `wait` never returns
      # and neither did this method. That is the session freezing on `▶
      # run` over a web server — the whole of iyi-web is web servers.
      process = Process.new(
        @self_exe || raise("the server's own binary is gone — rebuilt under a running session? restart the client"),
        verb.to_a + [path],
        input: Process::Redirect::Close,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe)

      @running_verbs += 1
      spawn { supervise_verb(id, process, scratch) }
    end

    # The verb, watched from its own fiber: the loop is free the whole
    # time, and the answer joins the queue when the program is done.
    private def supervise_verb(id : JSON::Any, process : Process, scratch : String?) : Nil
      output = IO::Memory.new
      error = IO::Memory.new
      spawn { capture(process.output, output) }
      spawn { capture(process.error, error) }

      exited = Channel(Process::Status).new(1)
      spawn do
        status = process.wait rescue nil
        exited.send(status) if status
      end

      status = nil
      note = nil
      select
      when finished = exited.receive
        status = finished
      when timeout(RUN_LIMIT)
        # Termination travels: `iyi run` forwards it to the program it
        # built, so a server started here does not outlive the click.
        process.terminate rescue nil
        note = "killed after #{RUN_LIMIT.total_seconds.to_i}s: the verb did not return"
        select
        when finished = exited.receive
          status = finished
        when timeout(2.seconds)
          note = "#{note}, and did not die either; it is on its own now"
        end
      end

      # Whatever arrived is the answer. What holds the other end open is
      # not this session's business any more.
      process.output.close rescue nil
      process.error.close rescue nil

      # The note goes last, under the program's own last word, so the two
      # are not read as one sentence.
      said = error.to_s
      said += "\n" unless said.empty? || said.ends_with?("\n")
      said += "#{note}\n" if note
      if output.size >= RUN_OUTPUT_LIMIT || error.size >= RUN_OUTPUT_LIMIT
        said += "the program passed #{RUN_OUTPUT_LIMIT // 1024} KiB and the rest was not read\n"
      end

      @finished_verbs.send Finished.new(id, status.try(&.success?) == true,
        output.to_s, said)
    ensure
      @running_verbs -= 1
      File.delete(scratch) if scratch && File.file?(scratch)
    end

    # What one run may say into a session that outlives it. A program
    # printing in a loop is a program, not a bug, and a megabyte of it
    # is already more than an editor will show; the rest is a leak with
    # a nicer name.
    RUN_OUTPUT_LIMIT = 1024 * 1024

    private def capture(from : IO, into : IO::Memory) : Nil
      buffer = Bytes.new(16384)
      while (read = from.read(buffer)) > 0
        room = RUN_OUTPUT_LIMIT - into.size
        if room <= 0
          # Stop listening *and* say so by hanging up: a program writing
          # into a pipe nobody reads would otherwise sit in `write` until
          # the deadline killed it, and the person would wait thirty
          # seconds for an answer that was already full.
          from.close
          return
        end
        into.write(buffer[0, Math.min(read, room)])
      end
    rescue
      # The pipe was closed under us, which is how a run that overstayed
      # ends. What arrived before that is still the answer.
    end

    private def answer_verb(finished : Finished) : Nil
      respond(finished.id) do |json|
        json.object do
          json.field "ok", finished.ok
          json.field "output", finished.output
          json.field "error", finished.error unless finished.ok
        end
      end
    end

    # ── Paths and the shadow root ────────────────────────────────────────

    private def path_of(uri : String) : String
      URI.decode(uri.lchop("file://"))
    end

    private def uri_of(path : String) : String
      "file://" + path
    end

    private def text_of(uri : String) : String
      @documents[uri]? || File.read(path_of(uri))
    end

    private def range(json : JSON::Builder, l0 : Int32, c0 : Int32, l1 : Int32, c1 : Int32) : Nil
      json.object do
        json.field "start" do
          json.object do
            json.field "line", l0
            json.field "character", c0
          end
        end
        json.field "end" do
          json.object do
            json.field "line", l1
            json.field "character", c1
          end
        end
      end
    end

    # Every open buffer except the one being compiled, keyed by the path
    # its file would have — the compiler reads these before the disk, so
    # cross-module answers see unsaved edits.
    private def overrides_for(path : String) : Hash(String, String)
      overrides = {} of String => String
      @documents.each do |uri, text|
        doc_path = path_of(uri)
        overrides[doc_path] = text unless doc_path == path
      end
      overrides
    end
  end
end
