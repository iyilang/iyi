#!/usr/bin/env python3
"""Every parse says which language it is reading.

    python3 bench/language_is_named.py

Which language a source is written in is the one thing the lexer cannot
read out of its text: `!` is not part of a name in a `.iyi` file (SPEC.md
III.1.7) and is part of one in a `.cr` file, so the answer comes off the
name. A `Parser` or `Lexer` built without one reads by the other
language's rules, and that has been a defect four separate times:

  * `iyi tool format -` read iyi source as Crystal, because stdin was
    named `STDIN`, which ends in neither extension;
  * the LSP's semantic-token scanner coloured every buffer by Crystal's
    rules, so `risky!` was one name and `end!` was not a keyword;
  * a macro expansion is named by a `VirtualFile`, which ends in nothing,
    so no macro could generate `!` and the rule that `!` is not a name
    went unenforced in what a macro wrote — which is how the prelude came
    to declare `to_i!` on five structs;
  * a macro body's formatter was handed the text with no name, so a body
    using `!` did not parse and was written back exactly as typed.

So this is that seam, checked: a construction whose following lines do
not mention `filename` has to be on the list below with what it reads
instead. Exits non-zero for anything else.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(os.path.dirname(__file__)))
SOURCE = os.path.join(ROOT, "src", "compiler", "iyi")
BUILD = re.compile(r"\b(?:Iyi::)?(Parser|Lexer)\.new\(")
WINDOW = 10

# Each key is the line as written; each value is why that construction has
# no file to name. A line that changes stops matching, which is the point:
# the reason is about the code as it stands.
EXEMPT = {
    # `Rx::Parser` is the regex engine's, not the language's: its source is
    # a pattern and it has no dialect to pick.
    "parser = Parser.new(source, ignore_case)":
        "the regex engine's parser, whose source is a pattern",
    # The factory. Every caller sets the name on what it hands back, which
    # is why the parameter is not here.
    "Parser.new(source, string_pool, var_scopes, warnings)":
        "the factory `new_parser`, named by each caller",
    # The formatter's own lexer, named through `Formatter#filename=` when
    # the caller says which file this is.
    "@lexer = Lexer.new(source)":
        "the formatter's lexer, named by `filename=`",
    # Scans for one keyword — whether a `method_missing` body starts with
    # `def` — and `def` is `def` in both languages.
    "lexer = Iyi::Lexer.new(source)":
        "a keyword scan, which both languages spell the same",
}


def sites():
    for directory, _, files in os.walk(SOURCE):
        for name in sorted(files):
            if not name.endswith(".cr"):
                continue
            path = os.path.join(directory, name)
            with open(path, errors="ignore") as handle:
                lines = handle.read().split("\n")
            for index, line in enumerate(lines):
                if not BUILD.search(line):
                    continue
                window = "\n".join(lines[index:index + WINDOW])
                yield path, index + 1, line.strip(), "filename" in window


def main():
    named = 0
    exempt = []
    nameless = []
    for path, line, text, has_name in sites():
        if has_name:
            named += 1
        elif text in EXEMPT:
            exempt.append((path, line, text))
        else:
            nameless.append((path, line, text))

    print(f"{named} parse(s) name their file, {len(exempt)} exempt by reason")
    for path, line, text in exempt:
        print(f"  {os.path.relpath(path, ROOT)}:{line}  {EXEMPT[text]}")

    unused = sorted(set(EXEMPT) - {text for _, _, text in exempt})
    if unused:
        print()
        print("A reason on the list matches no construction:")
        for text in unused:
            print(f"    {text}")
        print("Delete it in the same commit as the code it was about.")
        return 1

    if nameless:
        print()
        print("A parse that does not name its file reads by the other language's rules:")
        for path, line, text in nameless:
            print(f"    {os.path.relpath(path, ROOT)}:{line}  {text}")
        print()
        print("Set `filename` on it — the path the text came from, which is what")
        print("`!` is judged by — or add the line to EXEMPT in this script with")
        print("what it reads instead, in the same commit.")
        return 1

    print()
    print("every parse in the compiler names the language it is reading.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
