#!/usr/bin/env python3
"""
Compare two test outputs for semantic backtrace equivalence.

Usage:
    python3 bench/frames_equivalent.py [--across-optimisation] OUT_A OUT_B
    python3 bench/frames_equivalent.py --mutant KIND OUT

Exit codes:
    0: Equivalent
    1: Not equivalent (first violation printed)
    2: Usage error or unreadable input
"""

import os
import re
import sys

FRAME_RE = re.compile(rb'^(\d+) +(\S+) +0x[0-9a-fA-F]{16} (.*) \+ \d+$')


def canonical_function(sym: bytes) -> bytes:
    # 1. strip one trailing ~iyi
    if sym.endswith(b'~iyi'):
        sym = sym[:-4]
    # 2. for a symbol starting ~proc, drop the digits after ~proc
    if sym.startswith(b'~proc'):
        sym = re.sub(rb'^~proc\d*', b'~proc', sym)
    # 3. in the @FILE:LINE tail (split at the last @), rewrite …/src/std/X.iyi and mods/std/X.iyimod to std/X
    if b'@' in sym:
        head, sep, tail = sym.rpartition(b'@')
        tail = re.sub(rb'^(?:.*?[/\\])?src/std/(.+?)\.iyi(?=:\d+|$)', rb'std/\1', tail)
        tail = re.sub(rb'^(?:.*?[/\\])?mods/std/(.+?)\.iyimod(?=:\d+|$)', rb'std/\1', tail)
        sym = head + sep + tail
    return sym


def report_violation(line_no: int, rule: str, left: bytes, right: bytes):
    sys.stdout.write(f"line {line_no}: rule {rule}\n  left:  {repr(left)}\n  right: {repr(right)}\n")


def compare_same_opt(lines1: list[bytes], lines2: list[bytes]) -> int:
    # Equal line count
    if len(lines1) != len(lines2):
        min_len = min(len(lines1), len(lines2))
        line_no = min_len + 1
        left = lines1[min_len] if len(lines1) > min_len else b''
        right = lines2[min_len] if len(lines2) > min_len else b''
        report_violation(line_no, 'line_count', left, right)
        return 1

    for idx, (l1, l2) in enumerate(zip(lines1, lines2)):
        line_no = idx + 1
        m1 = FRAME_RE.match(l1.rstrip(b'\r\n'))
        m2 = FRAME_RE.match(l2.rstrip(b'\r\n'))

        # Frame lines at the same positions
        if bool(m1) != bool(m2):
            report_violation(line_no, 'position', l1, l2)
            return 1

        # Non-frame lines byte-equal
        if not m1:
            if l1 != l2:
                report_violation(line_no, 'text', l1, l2)
                return 1
        else:
            # Frames must have equal index, image (group 2) and canonical function
            idx1, img1, fn1 = m1.group(1), m1.group(2), canonical_function(m1.group(3))
            idx2, img2, fn2 = m2.group(1), m2.group(2), canonical_function(m2.group(3))

            if idx1 != idx2:
                report_violation(line_no, 'index', l1, l2)
                return 1
            if img1 != img2:
                report_violation(line_no, 'image', l1, l2)
                return 1
            if fn1 != fn2:
                report_violation(line_no, 'function', l1, l2)
                return 1

    return 0


def compare_across_opt(lines1: list[bytes], lines2: list[bytes]) -> int:
    def chunk_items(lines):
        items = []
        i = 0
        n = len(lines)
        while i < n:
            line_no = i + 1
            line = lines[i]
            m = FRAME_RE.match(line.rstrip(b'\r\n'))
            if m:
                frames = []
                while i < n and FRAME_RE.match(lines[i].rstrip(b'\r\n')):
                    frames.append(lines[i])
                    i += 1
                items.append(('frame', line_no, frames))
            else:
                items.append(('text', line_no, line))
                i += 1
        return items

    items1 = chunk_items(lines1)
    items2 = chunk_items(lines2)

    min_len = min(len(items1), len(items2))
    for i in range(min_len):
        k1, lno1, val1 = items1[i]
        k2, lno2, val2 = items2[i]

        if k1 != k2:
            left = val1 if k1 == 'text' else val1[0]
            right = val2 if k2 == 'text' else val2[0]
            report_violation(lno1, 'position', left, right)
            return 1

        if k1 == 'text':
            if val1 != val2:
                report_violation(lno1, 'text', val1, val2)
                return 1
        else:
            if len(val1) == 0 or len(val2) == 0:
                left = val1[0] if val1 else b''
                right = val2[0] if val2 else b''
                report_violation(lno1, 'empty_frames', left, right)
                return 1

    if len(items1) != len(items2):
        if len(items1) > len(items2):
            k, lno, val = items1[min_len]
            left = val if k == 'text' else val[0]
            right = b''
        else:
            k, lno, val = items2[min_len]
            left = b''
            right = val if k == 'text' else val[0]
        report_violation(lno, 'item_count', left, right)
        return 1

    return 0


def generate_mutant(kind: str, lines: list[bytes]) -> list[bytes]:
    mutated = list(lines)
    if kind == "text":
        for i, line in enumerate(mutated):
            if not FRAME_RE.match(line.rstrip(b'\r\n')):
                mutated[i] = b"MUTANT " + line
                return mutated
        raise ValueError("no text line to mutate")
    elif kind == "drop":
        for i, line in enumerate(mutated):
            if FRAME_RE.match(line.rstrip(b'\r\n')):
                del mutated[i]
                return mutated
        if mutated:
            del mutated[0]
            return mutated
        raise ValueError("no line to drop")
    elif kind == "swap":
        for i in range(len(mutated) - 1):
            if FRAME_RE.match(mutated[i].rstrip(b'\r\n')) and FRAME_RE.match(mutated[i + 1].rstrip(b'\r\n')):
                mutated[i], mutated[i + 1] = mutated[i + 1], mutated[i]
                return mutated
        if len(mutated) >= 2:
            mutated[0], mutated[1] = mutated[1], mutated[0]
            return mutated
        raise ValueError("not enough lines to swap")
    elif kind == "function":
        for i, line in enumerate(mutated):
            m = FRAME_RE.match(line.rstrip(b'\r\n'))
            if m:
                fn = m.group(3)
                new_fn = b"mutant_" + fn
                mutated[i] = line.replace(fn, new_fn, 1)
                return mutated
        raise ValueError("no frame line for function mutant")
    elif kind == "index":
        for i, line in enumerate(mutated):
            m = FRAME_RE.match(line.rstrip(b'\r\n'))
            if m:
                idx = m.group(1)
                new_idx = str(int(idx) + 99).encode()
                mutated[i] = re.sub(rb'^\d+', new_idx, line, count=1)
                return mutated
        raise ValueError("no frame line for index mutant")
    elif kind == "image":
        for i, line in enumerate(mutated):
            m = FRAME_RE.match(line.rstrip(b'\r\n'))
            if m:
                img = m.group(2)
                new_img = b"mutant_image"
                mutated[i] = line.replace(img, new_img, 1)
                return mutated
        raise ValueError("no frame line for image mutant")
    elif kind == "line":
        # change a proc's :LINE
        for i, line in enumerate(mutated):
            m = FRAME_RE.match(line.rstrip(b'\r\n'))
            if m:
                fn = m.group(3)
                sub_m = re.search(rb'(@.*?):(\d+)', fn)
                if sub_m:
                    old_num = sub_m.group(2)
                    new_num = str(int(old_num) + 12345).encode()
                    new_fn = fn[:sub_m.start(2)] + new_num + fn[sub_m.end(2):]
                    mutated[i] = line.replace(fn, new_fn, 1)
                    return mutated
        raise ValueError("no frame line with :LINE for line mutant")
    elif kind == "module":
        # change std/X to std/Y
        for i, line in enumerate(mutated):
            m = FRAME_RE.match(line.rstrip(b'\r\n'))
            if m:
                fn = m.group(3)
                if b'std/' in fn:
                    new_fn = re.sub(rb'std/([a-zA-Z0-9_]+)', rb'std/mutant_mod', fn, count=1)
                    if new_fn != fn:
                        mutated[i] = line.replace(fn, new_fn, 1)
                        return mutated
        raise ValueError("no frame line with std/ for module mutant")
    else:
        raise ValueError(f"unknown mutant kind: {kind}")


def main():
    args = sys.argv[1:]
    if not args:
        sys.stderr.write("Usage: frames_equivalent.py [--across-optimisation] OUT_A OUT_B\n       frames_equivalent.py --mutant KIND OUT\n")
        sys.exit(2)

    if args[0] == "--mutant":
        if len(args) != 3:
            sys.stderr.write("Error: --mutant requires KIND and OUT\n")
            sys.exit(2)
        kind = args[1]
        out_path = args[2]
        try:
            with open(out_path, 'rb') as f:
                lines = f.readlines()
        except Exception as e:
            sys.stderr.write(f"Error reading {out_path}: {e}\n")
            sys.exit(2)
        try:
            mutated = generate_mutant(kind, lines)
        except Exception as e:
            sys.stderr.write(f"Error generating mutant: {e}\n")
            sys.exit(2)
        sys.stdout.buffer.write(b''.join(mutated))
        sys.exit(0)

    across_opt = False
    files = []
    for arg in args:
        if arg in ("--across-optimisation", "--across-optimization"):
            across_opt = True
        elif arg.startswith("-"):
            sys.stderr.write(f"Unknown option: {arg}\n")
            sys.exit(2)
        else:
            files.append(arg)

    if len(files) != 2:
        sys.stderr.write("Error: exactly two files required\n")
        sys.exit(2)

    try:
        with open(files[0], 'rb') as f1, open(files[1], 'rb') as f2:
            lines1 = f1.readlines()
            lines2 = f2.readlines()
    except Exception as e:
        sys.stderr.write(f"Error reading inputs: {e}\n")
        sys.exit(2)

    if across_opt:
        ret = compare_across_opt(lines1, lines2)
    else:
        ret = compare_same_opt(lines1, lines2)

    sys.exit(ret)


if __name__ == "__main__":
    main()
