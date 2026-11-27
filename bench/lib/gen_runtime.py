#!/usr/bin/env python3
"""Regenerates src/compiler/native/rt/builtins_text.iyi from src/compiler/native/rt/builtins.ir.

The compiler carries the native runtime as a string in that module, so iyi-compile-native needs no file at run time.
`--check` exits 1 when the committed module differs from what the IR would generate (the gate runs it that way).
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
IR = ROOT / "src/compiler/native/rt/builtins.ir"
OUT = ROOT / "src/compiler/native/rt/builtins_text.iyi"


def generate() -> str:
    lines = IR.read_text(encoding="utf-8").splitlines()
    out = [
        "module compiler/native/rt/builtins_text",
        "",
        "# GENERATED from builtins.ir by bench/lib/gen_runtime.py: do not edit by hand.",
        "# The native runtime's IR text, one array element per line, so the compiler needs no file at run time.",
        "",
        "pub def builtins_ir : String",
        "  lines = [] of String",
    ]
    for line in lines:
        out.append("  lines << " + json.dumps(line))
    out += ['  lines.join("\\n") + "\\n"', "end", ""]
    return "\n".join(out)


def main(argv: list[str]) -> int:
    text = generate()
    if argv == ["--check"]:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != text:
            print("builtins_text.iyi is stale: run python3 bench/lib/gen_runtime.py", file=sys.stderr)
            return 1
        return 0
    if argv:
        print("usage: gen_runtime.py [--check]", file=sys.stderr)
        return 2
    OUT.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
