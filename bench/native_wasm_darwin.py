#!/usr/bin/env python3
"""Makes the darwin oracle of a wasm32-wasi fixture (slice D5).

A fixture prints through `declare external void @__iyi_print_i64(i64)`, which the wasm runtime defines with
fd_write. The oracle is the same program compiled for aarch64-apple-darwin by the native backend, with that
function defined through libc's printf instead, so its stdout is the reference for the wasm module's stdout.

    bench/native_wasm_darwin.py <fixture.ir> <oracle.ir>
"""
import pathlib
import sys

DARWIN_TRIPLE = "aarch64-apple-darwin"
DARWIN_LAYOUT = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
WASM_TRIPLE = 'target triple = "wasm32-wasi"'
WASM_LAYOUT_PREFIX = "target datalayout = "
PRINT_DECL = "declare external void @__iyi_print_i64(i64)"
PRINT_DEF = """@fmt_pi = private constant [6 x i8] c"%ld\\0A\\00"
declare external i32 @printf(ptr, ...)

define internal void @__iyi_print_i64(i64 %v) {
entry:
  %r = call i32 (ptr, ...) @printf(ptr @fmt_pi, i64 %v)
  ret void
}
"""


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    lines = pathlib.Path(src).read_text().splitlines()
    out = []
    replaced_triple = replaced_layout = replaced_print = False
    for line in lines:
        if line == WASM_TRIPLE:
            out.append(f'target triple = "{DARWIN_TRIPLE}"')
            replaced_triple = True
        elif line.startswith(WASM_LAYOUT_PREFIX):
            out.append(f'target datalayout = "{DARWIN_LAYOUT}"')
            replaced_layout = True
        elif line == PRINT_DECL:
            out.extend(PRINT_DEF.splitlines())
            replaced_print = True
        else:
            out.append(line)
    if not (replaced_triple and replaced_layout and replaced_print):
        print(f"FAIL: {src} is not a wasm32-wasi fixture with the print declaration")
        return 1
    pathlib.Path(dst).write_text("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
