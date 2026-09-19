# iyi: `iyi lsp` — serve the language over stdio (SPEC.md III.8 #2).
#
# Two processes, one verb. `iyi lsp` is the proxy the editor talks to: it
# speaks the protocol, keeps the open buffers, and runs `iyi lsp
# --worker` — this same binary, today's server — to do the compiling. The
# worker is replaced when the wire goes quiet, so the memory a
# collector-free front end never gives back goes back to the kernel the
# way `iyi build`'s does, by exiting (SPEC.md III.9, `lsp/proxy.cr`).
#
# No flags for the person: the protocol negotiates everything a flag
# would say, and a server that is configured outside the protocol is a
# server that lies to its client. `--worker` is the architecture, not an
# option — it is what the proxy runs, and what a gate measures the old
# single-process shape with.
require "../lsp/server"
require "../lsp/proxy"

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

        The session runs in two processes: this one holds the buffers and
        the protocol, and a child (`#{Command.program_name} lsp --worker`)
        does the compiling and is replaced while nobody is typing, so an
        hour of editing does not cost an hour of allocation.
        USAGE
      exit
    end

    # The worker: today's server, one process, no proxy. What the proxy
    # spawns, and what `bench/lsp_memory.py --direct` measures to show
    # what the split is worth.
    if options.first? == "--worker"
      server = Lsp::Server.new
      server.run
      exit server.exit_code
    end

    proxy = Lsp::Proxy.new
    proxy.run
    # 0 after a `shutdown`, 1 for an `exit` that skipped it, which is the
    # protocol's own rule and what a client that reads the code expects.
    exit proxy.exit_code
  end
end
