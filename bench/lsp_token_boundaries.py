#!/usr/bin/env python3
"""Sweeps every sample module's semantic tokens and refuses a token
that colors part of a word, or a name with a `!` inside it. The first
bug this gate exists for was literal: the lexer reuses one Token and
leaves `raw` dirty between kinds, so an ident could inherit the
previous number's *length* — and every editor showed `t`otal, the
first letter colored, the rest plain. The second was the language: the
scanner built its lexer without the file's name, which is the only
thing about a buffer the lexer cannot read out of the source, so every
`.iyi` file was colored by the other language's rules. There `foo!` is
one name, so the propagation operator was swallowed into the name
before it, and `end!` was a name too — which cost a block's `end` its
keyword color. In iyi `!` is never part of a name (SPEC.md III.1.7),
so a wordy token carrying one is that mistake. A wordy token must
start and end on word boundaries; 8,000+ tokens across the samples say
so on every push, so the world's best highlighting cannot quietly
become the world's strangest.
"""

import glob
import os
import sys

from lsp_session import Client, file_uri

TYPES = ["keyword", "string", "number", "comment", "type", "function",
         "variable", "property", "operator", "regexp", "macro",
         "enumMember", "parameter"]
WORDY = {"keyword", "type", "function", "variable", "parameter", "number"}


def name_char(ch):
    return ch.isalnum() or ch == "_"


def main():
    root = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "samples", "iyi"))
    files = sorted(glob.glob(root + "/**/*.iyi", recursive=True))
    if not files:
        sys.exit(f"no corpus under {root}")

    c = Client()
    c.send("initialize", {"rootUri": file_uri(root), "capabilities": {}})
    c.send("initialized", {}, wait=False)

    total = 0
    bangs = 0
    bad = []
    for path in files:
        with open(path) as f:
            text = f.read()
        lines = text.split("\n")
        uri = file_uri(path)
        c.send("textDocument/didOpen",
               {"textDocument": {"uri": uri, "languageId": "iyi",
                                 "version": 1, "text": text}}, wait=False)
        reply = c.send("textDocument/semanticTokens/full",
                       {"textDocument": {"uri": uri}})
        data = reply["result"]["data"]
        line = start = 0
        for i in range(0, len(data), 5):
            dl, ds, ln, tt, _ = data[i:i + 5]
            line += dl
            start = (start + ds) if dl == 0 else ds
            total += 1
            kind = TYPES[tt]
            if kind not in WORDY:
                continue
            src = lines[line] if line < len(lines) else ""
            word = src[start:start + ln]
            before = src[start - 1] if start > 0 else " "
            last = src[start + ln - 1] if start + ln - 1 < len(src) else " "
            after = src[start + ln] if start + ln < len(src) else " "
            starts_mid = name_char(before) and kind != "number"
            ends_mid = name_char(after) and name_char(last)
            # `!` is not part of a name in iyi, so a name carrying one is
            # the buffer read by the other language's rules: there `foo!`
            # is a single ident, which eats the propagation operator and,
            # after `end`, a keyword.
            if "!" in word:
                bangs += 1
            if starts_mid or ends_mid or "!" in word:
                bad.append(f"{os.path.relpath(path, root)}:{line + 1}:{start}"
                           f" {kind} {word!r}"
                           f" in {src.strip()!r}")
    c.send("shutdown", {})
    c.send("exit", {}, wait=False)

    if bad:
        print(f"{len(bad)} of {total} tokens are not a whole word "
              f"({bangs} of them a name with `!` in it):")
        for entry in bad[:20]:
            print(f"  {entry}")
        sys.exit(1)
    print(f"token boundaries: {total} tokens across "
          f"{len(files)} modules, every word whole and no `!` inside one")


if __name__ == "__main__":
    main()
