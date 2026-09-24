# Editors

`iyi lsp` speaks the Language Server Protocol over stdio and there is
nothing to configure: point a client at the command and every capability
arrives through the protocol — diagnostics on each keystroke from a real
compile, completion that writes the `import X::{name}` line for you,
hover with docs, rename that follows the names on `import` lines, and highlighting as
semantic tokens, so no editor *needs* a grammar file for `.iyi`. The VS
Code extension still carries a deliberately minimal one: a TextMate
pass is synchronous with the first frame and a language server is not,
so the grammar paints instantly and the server's tokens — the truth —
override it the moment they arrive. It covers only what cannot drift:
comments, strings, numbers, keywords, capitalized types, def names.

The one prerequisite everywhere: `iyi` on your `PATH` (or spell the
absolute path where the config names the command).

## VS Code

The extension in [`vscode/`](vscode/) is the whole client — a manifest
and thirty lines that spawn `iyi lsp`. It is published as `iyilang.iyi`
to both registries a VS Code-shaped editor reads — the
[Marketplace](https://marketplace.visualstudio.com/items?itemName=iyilang.iyi)
for VS Code, [Open VSX](https://open-vsx.org/extension/iyilang/iyi) for
Cursor, Windsurf, VSCodium, Gitpod and Theia, which cannot use the
Marketplace because Microsoft's terms scope it to Microsoft's own
products. Installing from whichever one your editor searches is the usual
route; building it from this checkout is the other:

```console
$ cd editors/vscode
$ npm install
$ npx @vscode/vsce package        # produces iyi-<version>.vsix
$ code --install-extension iyi-0.1.2.vsix
```

Cursor takes the same file: **Extensions → … → Install from VSIX**, or
`cursor --install-extension iyi-0.1.2.vsix`.

For hacking on it, open `editors/vscode` in VS Code and press F5.

### Publishing it

A release is a tag, like every other release here: push `editor-v<version>`
and the `vscode` job in [`.github/workflows/iyi.yml`](../.github/workflows/iyi.yml)
packages the manifest it finds and sends that one `.vsix` to both
registries, with the `VSCE_PAT` and `OVSX_PAT` secrets. Either step is
skipped when its token is not set, so a tag publishes wherever it can. The
version in `package.json` must match the tag, and both registries refuse a
version they already have, so the bump and the tag are one commit.

By hand it is two commands per registry:

```console
$ npx @vscode/vsce login iyilang               # once, with a Marketplace PAT
$ npx @vscode/vsce publish
$ npx ovsx create-namespace iyilang -p <token> # once
$ npx ovsx publish iyi-<version>.vsix -p <token>
```

The Marketplace publisher (`iyilang`) and its token come from
<https://marketplace.visualstudio.com/manage>; that token is an Azure DevOps
PAT for **all accessible organizations** with the **Marketplace → Manage**
scope, and nothing less works. The Open VSX namespace and token come from
<https://open-vsx.org> — an Eclipse account, the publisher agreement signed
once, then **Settings → Access Tokens**. The namespace is unverified until
you [claim it](https://github.com/EclipseFdn/open-vsx.org/issues), which
only changes the badge on the listing, not the install.

## Neovim (0.11+)

```lua
vim.filetype.add { extension = { iyi = "iyi" } }
vim.lsp.config("iyi", { cmd = { "iyi", "lsp" }, filetypes = { "iyi" } })
vim.lsp.enable("iyi")
```

## Helix

`~/.config/helix/languages.toml`:

```toml
[language-server.iyi]
command = "iyi"
args = ["lsp"]

[[language]]
name = "iyi"
scope = "source.iyi"
file-types = ["iyi"]
comment-token = "#"
indent = { tab-width = 2, unit = "  " }
language-servers = ["iyi"]
```

## Sublime Text

With the [LSP](https://packagecontrol.io/packages/LSP) package,
`LSP.sublime-settings`:

```json
{
  "clients": {
    "iyi": {
      "enabled": true,
      "command": ["iyi", "lsp"],
      "selector": "source.iyi | text.plain",
      "auto_complete_selector": "source.iyi"
    }
  }
}
```

## Zed, and everything else

Zed registers new languages through its own extension system; the
server side is ready whenever someone writes that shim — command
`iyi lsp`, stdio. The same sentence is the whole integration guide for
any other client: Emacs (eglot), Kate, Acme bridges, and the agent
harnesses that speak LSP directly all need only the command and the
`.iyi` file association.
