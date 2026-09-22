# Changelog

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
