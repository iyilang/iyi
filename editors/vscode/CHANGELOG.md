# Changelog

## 0.1.3

- Find `iyi` when the PATH does not have it. An editor started before the
  installer ran keeps the environment it was given — Windows broadcasts the
  change and a running process does not re-read it — so `spawn iyi ENOENT`
  was the first thing a fresh Windows install said. The client now also
  looks where the installers put it: `%LOCALAPPDATA%\Programs\iyi\bin`,
  `~/.local/bin`, `/usr/local/bin`, `/usr/bin`, and `$IYI_PREFIX/bin`.
- On Windows, resolve `iyi.exe` through PATHEXT with `.exe` preferred, and
  spawn a `.bat` or `.cmd` through a shell, which node otherwise refuses.
- The message for a missing binary says what to do: install it, then reopen
  the window, or name the path in `iyi.serverPath`.

## 0.1.2

- Require VS Code 1.82, which is what `vscode-languageclient` 9 requires. The
  manifest used to claim 1.75, so an older editor could install a client its
  own dependency refuses to run.
- Report a failed spawn as a notification naming the command that failed,
  instead of leaving the window silently without a language server.
- Marketplace metadata: icon, categories, keywords, repository and issue links.
- Declare the extension unsupported in untrusted and virtual workspaces: it
  runs a compiler from a settable path, against files on a real filesystem.
- `iyi.serverPath` is `machine-overridable`, so a cloned repository cannot
  point the editor at an executable of its choosing.

## 0.1.1

- A minimal TextMate grammar paints the first frame under the server's
  semantic tokens.

## 0.1.0

- First release: spawn `iyi lsp`, hand it `.iyi` documents.
