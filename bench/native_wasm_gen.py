#!/usr/bin/env python3
"""Generates src/compiler/native/rt/start_wasm32_text.iyi from start_wasm32.ir (slice D5).

The compiler embeds the runtime's IR text so it needs no file at run time. `--check` exits 1 when the
checked-in module is out of date; the wasm gate runs it so the two cannot drift.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src/compiler/native/rt/start_wasm32.ir"
OUT = ROOT / "src/compiler/native/rt/start_wasm32_text.iyi"


def render() -> str:
    lines = SRC.read_text().splitlines()
    out = [
        "module compiler/native/rt/start_wasm32_text",
        "",
        "# GENERATED from start_wasm32.ir by bench/native_wasm_gen.py: do not edit by hand.",
        "# The wasm32-wasi runtime's IR text, one array element per line, so the compiler needs no file at run time.",
        "",
        "pub def start_wasm32_ir : String",
        "  lines = [] of String",
    ]
    for line in lines:
        esc = line.replace("\\", "\\\\").replace('"', '\\"')
        out.append(f'  lines << "{esc}"')
    out.append('  lines.join("\\n") + "\\n"')
    out.append("end")
    return "\n".join(out) + "\n"


def main() -> int:
    text = render()
    if "--check" in sys.argv:
        current = OUT.read_text() if OUT.exists() else ""
        if current != text:
            print(f"FAIL: {OUT.relative_to(ROOT)} is out of date; run bench/native_wasm_gen.py")
            return 1
        print("start_wasm32_text.iyi is in sync")
        return 0
    OUT.write_text(text)
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
