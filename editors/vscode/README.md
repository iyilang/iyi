# iyi for VS Code

Language support for [iyi](https://iyi-lang.com) — a language built for
Developer & Agentic Experience, Portability, Performance, and Efficiency.
(*iyi* is Turkish for "good".)

The extension is the whole client: a manifest and thirty lines that spawn
`iyi lsp` and hand it your `.iyi` files. Everything you see comes over the
protocol from the compiler itself, so the editor is never looking at a second,
approximate model of your code.

## Prerequisite

`iyi` on your `PATH`:

```sh
curl -fsSL https://raw.githubusercontent.com/iyilang/iyi/master/install.sh | sh
```

On Windows, PowerShell installs the same release:

```powershell
irm https://raw.githubusercontent.com/iyilang/iyi/master/install.ps1 | iex
```

If the binary lives somewhere the shell does not look, name it in
`iyi.serverPath` — that is the extension's only setting.

## What arrives over the protocol

- **Diagnostics** on each keystroke, from a real compile — not a heuristic pass.
- **Completion** that writes the `import`/`using` pair for you.
- **Hover** with documentation, **signature help**, **inlay hints**.
- **Go to definition**, type definition, implementation, references, document
  and workspace symbols, call and type hierarchy.
- **Rename** that follows `using` lines, with prepare-rename.
- **Code actions and quick fixes**, **code lenses**, **formatting**, folding
  ranges, document links, selection ranges.
- **Semantic highlighting**. A deliberately minimal TextMate grammar paints the
  first frame, because a grammar pass is synchronous and a language server is
  not; the server's semantic tokens are the truth and override it the moment
  they arrive. The grammar covers only what cannot drift: comments, strings,
  numbers, keywords, capitalized types, `def` names.

## Settings

| setting | default | meaning |
|---|---|---|
| `iyi.serverPath` | `iyi` | Path to the `iyi` binary. The server is `iyi lsp`; there is nothing else to configure. |

## Trouble

Nothing highlights, nothing completes: the server did not start. Open
**Output → iyi language server** — the client writes the spawn failure there.
Almost always it is `iyi` not being on the `PATH` VS Code inherited (a GUI
launch does not read your shell's profile); spell the absolute path in
`iyi.serverPath` and reload the window.

## Links

- [Repository](https://github.com/iyilang/iyi)
- [Issues](https://github.com/iyilang/iyi/issues)
- [Other editors](https://github.com/iyilang/iyi/blob/master/editors/README.md)
  — Neovim, Helix, Sublime Text, and anything else that speaks LSP; the whole
  integration is the command `iyi lsp` over stdio.

Licensed Apache-2.0 with the Runtime Library Exception.
