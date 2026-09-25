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
- **Completion** that writes the `import X::{name}` line for you.
- **Hover** with documentation, **signature help**, **inlay hints**.
- **Go to definition**, type definition, implementation, references, document
  and workspace symbols, call and type hierarchy.
- **Rename** that follows the names on `import` lines, with prepare-rename.
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

**`spawn iyi ENOENT`**, nothing highlights, nothing completes: the editor
could not find the binary. The extension looks on the `PATH` it was given
and then where the installers put it — `%LOCALAPPDATA%\Programs\iyi\bin` on
Windows, `~/.local/bin`, `/usr/local/bin`, `/usr/bin`, and `$IYI_PREFIX/bin`
elsewhere — so this means iyi is not installed, or it is somewhere else.

If you installed it while this window was open, reopen the window: a running
editor keeps the environment it started with, on Windows and macOS both.
Installed somewhere of your own choosing: put the absolute path in
`iyi.serverPath` (on Windows, name `iyi.exe`) and reload the window.

Anything else the server says goes to **Output → iyi language server**.

## Links

- [Repository](https://github.com/iyilang/iyi)
- [Issues](https://github.com/iyilang/iyi/issues)
- [Other editors](https://github.com/iyilang/iyi/blob/master/editors/README.md)
  — Neovim, Helix, Sublime Text, and anything else that speaks LSP; the whole
  integration is the command `iyi lsp` over stdio.

Licensed Apache-2.0 with the Runtime Library Exception.
