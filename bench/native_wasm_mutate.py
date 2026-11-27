#!/usr/bin/env python3
"""Applies one mutation to a file, for bench/native_wasm_exercise.sh (slice D5).

    bench/native_wasm_mutate.py <file> <old> <new>

Exit 0: the mutation was applied. Exit 2: `old` is not in the file exactly once, so the mutation cannot be
applied as stated. Exit 3: `old` equals `new`, so the patch changes nothing and proves nothing; it is refused.
"""
import pathlib
import sys


def main() -> int:
    path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
    if old == new:
        print("refused: the patch changes nothing")
        return 3
    text = pathlib.Path(path).read_text()
    count = text.count(old)
    if count != 1:
        print(f"refused: the target text occurs {count} times, not once")
        return 2
    pathlib.Path(path).write_text(text.replace(old, new))
    return 0


if __name__ == "__main__":
    sys.exit(main())
