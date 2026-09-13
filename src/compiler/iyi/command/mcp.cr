# iyi: `iyi mcp` — the compiler as a toolbox on the Model Context
# Protocol.
#
# The LSP is the editor's protocol; MCP is the agent harness's. Every
# verb this server exposes already exists and already speaks JSON —
# `check -f json`, `fix --json`, `mod context --json`, `test --json` —
# so the server is deliberately a shell: each tool call runs this same
# binary with those arguments and hands the output back untouched. No
# second implementation, no drift: what an agent gets over MCP is
# byte-for-byte what a shell would have gotten, minus the shell.
#
# Transport is MCP's stdio shape: one JSON-RPC message per line, both
# directions. The subset served is the whole of what a tool server
# needs — `initialize`, `tools/list`, `tools/call`, `ping` — and
# nothing speculative.
require "json"

class Iyi::Command
  private def mcp
    # iyi: this used to look at `options.first?` alone and serve whatever
    # it did not recognise, so `iyi mcp --nonesuch` reached the read loop
    # and the agent harness on the other end got a server it never
    # configured. `--help` and `-h` are the whole of this command line.
    if unknown = options.find { |option| !option.in?("--help", "-h") }
      abort! "mcp takes no arguments but --help, and '#{unknown}' is one", :USAGE_ERROR
    end

    unless options.empty?
      puts <<-USAGE
        Usage: #{Command.program_name} mcp

        Serve the compiler's verbs as Model Context Protocol tools over
        stdin/stdout, one JSON-RPC message per line. Point an agent
        harness at it; there is nothing to configure.

        Tools: check (front-end verdict with suggested edits), fix
        (apply them), context (a file's grounding pack), test (run
        tests, optionally only those an edit can reach).
        USAGE
      exit
    end

    while line = STDIN.gets
      next if line.blank?
      message =
        begin
          JSON.parse(line)
        rescue JSON::ParseException
          STDOUT.puts %({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "parse error"}})
          STDOUT.flush
          next
        end

      id = message["id"]?
      case message["method"]?.try(&.as_s?)
      when "initialize"
        respond_mcp(id) do |json|
          json.field "protocolVersion", message.dig?("params", "protocolVersion").try(&.as_s?) || "2025-06-18"
          json.field "capabilities" do
            json.object do
              json.field "tools" do
                json.object { json.field "listChanged", false }
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
      when "notifications/initialized", "notifications/cancelled"
        # Notifications carry no id and want no answer.
      when "ping"
        respond_mcp(id) { }
      when "tools/list"
        respond_mcp(id) do |json|
          json.field "tools" do
            # The catalogue is written pretty for the reader below; the
            # wire is one message per line, so it travels compact.
            json.raw JSON.parse(MCP_TOOLS).to_json
          end
        end
      when "tools/call"
        name = message.dig?("params", "name").try(&.as_s?) || ""
        arguments = message.dig?("params", "arguments")
        mcp_call(id, name, arguments)
      when "exit", "shutdown"
        break
      else
        # A notification we do not serve is silence; a request is told so.
        if id
          STDOUT.puts %({"jsonrpc": "2.0", "id": #{id.to_json}, "error": {"code": -32601, "message": "method not found"}})
          STDOUT.flush
        end
      end
    end
  end

  # The catalogue, verbatim JSON: five tools, each one existing verb.
  # Schemas are the arguments those verbs already take — nothing here
  # exists only over the wire.
  MCP_TOOLS = <<-JSON
    [
      {
        "name": "check",
        "description": "Type-check an iyi file without producing anything. Returns [] when clean, else the compiler's errors as data: file, line, column, size, message, the SPEC sections cited, and suggested_edit (exact replacement span) when the compiler knows the fix.",
        "inputSchema": {
          "type": "object",
          "properties": {"file": {"type": "string", "description": "path to the .iyi file"}},
          "required": ["file"]
        }
      },
      {
        "name": "fix",
        "description": "Apply the compiler's own did-you-mean edits to a file, recompiling after each, until clean or an error carries no edit. Returns the edits applied and whether the file ended clean.",
        "inputSchema": {
          "type": "object",
          "properties": {"file": {"type": "string", "description": "path to the .iyi file"}},
          "required": ["file"]
        }
      },
      {
        "name": "context",
        "description": "The grounding pack for an iyi file: every import's exported surface as data (signatures, docs, interface_hash), read from source without compiling the file itself. What an agent should read before editing.",
        "inputSchema": {
          "type": "object",
          "properties": {"file": {"type": "string", "description": "path to the .iyi file"}},
          "required": ["file"]
        }
      },
      {
        "name": "test",
        "description": "Run *_test.iyi programs: exit 0 is a pass. Optionally pass affected=[changed files] to run only the tests whose transitive import closure reaches a change - the selection is exact, computed by parsing.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "path": {"type": "string", "description": "directory or test file (default: .)"},
            "affected": {"type": "array", "items": {"type": "string"}, "description": "files that changed; only tests that can reach them run"}
          }
        }
      },
      {
        "name": "doc",
        "description": "What can be called: a module's exported surface (functions, types, methods, impls, with their doc comments, no bodies) from a .iyi file or a .iyimod artifact, or a type of the prelude by name - `String`, `Array`, `Hash`, `Float64`, `Program` - the same way. Text.",
        "inputSchema": {
          "type": "object",
          "properties": {"target": {"type": "string", "description": "path to a .iyi module or .iyimod artifact, a prelude type's name, or `prelude` for the list of them"}},
          "required": ["target"]
        }
      }
    ]
    JSON

  private def mcp_call(id, name : String, arguments : JSON::Any?) : Nil
    file = arguments.try(&.dig?("file")).try(&.as_s?)

    args =
      case name
      when "check"
        return mcp_tool_error(id, "check needs a file") unless file
        ["check", "-f", "json", file]
      when "fix"
        return mcp_tool_error(id, "fix needs a file") unless file
        ["fix", "--json", file]
      when "context"
        return mcp_tool_error(id, "context needs a file") unless file
        ["mod", "context", "--json", file]
      when "test"
        built = ["test", "--json"]
        arguments.try(&.dig?("affected")).try(&.as_a?).try &.each do |changed|
          if path = changed.as_s?
            built << "--affected" << path
          end
        end
        if path = arguments.try(&.dig?("path")).try(&.as_s?)
          built << path
        end
        built
      when "doc"
        target = arguments.try(&.dig?("target")).try(&.as_s?)
        return mcp_tool_error(id, "doc needs a target: a .iyi module, a .iyimod artifact, or a prelude type's name") unless target
        ["doc", target]
      else
        return mcp_tool_error(id, "unknown tool: #{name}")
      end

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(Process.executable_path.not_nil!, args, output: stdout, error: stderr)

    # `check` answers on stderr (errors are errors) and says nothing when
    # clean; every other verb answers on stdout. An empty clean check
    # becomes `[]` so the caller always receives JSON.
    text = stdout.to_s
    text = stderr.to_s if text.blank?
    text = "[]" if text.blank? && name == "check"
    text = "(exit #{status.exit_code}, no output)" if text.blank?

    # iyi: `isError` was the constant `false`, so a tool that could not
    # answer said it had. A missing file, a directory, bytes that are not
    # text and an unknown prelude type all came back as success envelopes
    # whose text began with "Error:" — and an agent branches on this flag;
    # that is what it is for.
    #
    # The exit code cannot decide it alone: `check` exits 1 when the file
    # has diagnostics and `test` exits 1 when a test fails, and both of
    # those are *answers*. So the question asked here is whether the tool
    # produced the shape it promises. The four JSON tools have answered
    # when their output parses as JSON — diagnostics, a fix record, a
    # context pack, a test report — and have refused when it is a sentence.
    # `doc` promises text, so for it the exit code is the answer.
    answered =
      if name == "doc"
        status.success?
      else
        begin
          JSON.parse(text)
          true
        rescue JSON::ParseException
          false
        end
      end

    respond_mcp(id) do |json|
      json.field "content" do
        json.array do
          json.object do
            json.field "type", "text"
            json.field "text", text
          end
        end
      end
      json.field "isError", !answered
    end
  end

  private def mcp_tool_error(id, message : String) : Nil
    respond_mcp(id) do |json|
      json.field "content" do
        json.array do
          json.object do
            json.field "type", "text"
            json.field "text", message
          end
        end
      end
      json.field "isError", true
    end
  end

  private def respond_mcp(id, &) : Nil
    return unless id
    STDOUT.puts(JSON.build do |json|
      json.object do
        json.field "jsonrpc", "2.0"
        json.field "id" { id.to_json(json) }
        json.field "result" do
          json.object do
            yield json
          end
        end
      end
    end)
    STDOUT.flush
  end
end
