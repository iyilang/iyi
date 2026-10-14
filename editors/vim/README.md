# iyi for Vim and Neovim

This runtime plugin detects `*.iyi` files and highlights comments, strings
and nested interpolation, characters, decimal/binary/octal/hex numbers,
keywords, types, method definitions (including receivers, setters, and
operators), symbols, and instance variables. It also handles percent literals,
command strings, heredocs, macro delimiters, and source-location constants.
It sets `#` comments and two-space indentation. The syntax rules follow
the compiler's lexer rather than relying on language server tokens.

No compiler, language server, or other Vim plugin is required.

## Install

From the iyi repository root, copy the plugin into a Vim package directory:

```sh
mkdir -p ~/.vim/pack/iyi/start
cp -R editors/vim ~/.vim/pack/iyi/start/vim-iyi
```

For Neovim, use its data directory instead (normally
`~/.local/share/nvim`):

```sh
mkdir -p ~/.local/share/nvim/site/pack/iyi/start
cp -R editors/vim ~/.local/share/nvim/site/pack/iyi/start/vim-iyi
```

Restart the editor after installation. Enable syntax and filetype plugins
in your `.vimrc` or `init.vim` if they are not already enabled:

```vim
filetype plugin on
syntax enable
```

For a Lua Neovim configuration, the equivalent is:

```lua
vim.cmd("filetype plugin on")
vim.cmd("syntax enable")
```

Open an `.iyi` file and check `:set filetype?`; it should report `iyi`.
To update the plugin, copy these files again from a newer checkout.

## Language server

This plugin supplies filetype detection, syntax highlighting, and buffer
settings. For completion, diagnostics, and other language server features,
configure your LSP client to run `iyi lsp` for filetype `iyi`. The
[editor guide](../README.md#neovim-011) includes a Neovim example.

Highlighting is lexical: it does not resolve names or validate a program.
Slash-delimited regex literals are not recognized because `/` also means
division; use `%r{...}` for syntax highlighting without an LSP client.
Multiple heredocs introduced on the same line are not supported by these rules.

## Check the syntax rules

From the repository root:

```sh
vim -Nu NONE -i NONE -n -es -S editors/vim/test/syntax.vim
```

The checks inspect Vim's actual syntax groups, including nested literals and
the return to code highlighting after closing delimiters.
