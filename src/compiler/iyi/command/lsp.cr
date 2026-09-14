# iyi: `iyi lsp` — serve the language over stdio (SPEC.md III.8 #2).
#
# No flags: the protocol negotiates everything a flag would say, and a
# server that is configured outside the protocol is a server that lies to
# its client. The process speaks JSON-RPC on stdin/stdout until the
# client says `exit`; anything a person would want printed goes to the
# client as a response, never to the transport.
require "../lsp/server"

class Iyi::Command
  private def lsp
    if options.first?.in?("--help", "-h")
      puts <<-USAGE
        Usage: #{Command.program_name} lsp

        Speak the Language Server Protocol over stdin/stdout. Point an editor
        at it; there is nothing to configure.

        Beyond LSP 3.17's earning subset — diagnostics pushed on every
        change and pulled on request (one file or the whole workspace),
        completion with auto-import and snippets, signature help, hover
        with docs, definition, type definition, implementation, call and
        type hierarchy, references, document highlight, rename with
        prepare, document and workspace symbols, selection ranges,
        folding, formatting, inlay hints, document links, "did you mean"
        quickfixes, a code lens that runs the module, and semantic
        tokens (with deltas) so any client highlights iyi with no
        grammar installed —
        two methods serve agents: `iyi/contextPack` returns the grounding
        pack for a file (`mod context --json` over the wire), and
        `iyi/surface` returns a module's rendered surface (`doc`), unsaved
        buffer included.
        USAGE
      exit
    end
    server = Lsp::Server.new
    server.run
    # 0 after a `shutdown`, 1 for an `exit` that skipped it, which is the
    # protocol's own rule and what a client that reads the code expects.
    exit server.exit_code
  end
end
