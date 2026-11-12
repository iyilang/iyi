#!/usr/bin/env python3
"""
Compare two test outputs for semantic backtrace equivalence.

Usage:
    python3 bench/frames_equivalent.py [--across-optimisation] [--require-frames] OUT_A OUT_B
    python3 bench/frames_equivalent.py --mutant KIND OUT

Tested by:
    python3 bench/test_frames_equivalent.py

Exit codes:
    0: Equivalent
    1: Not equivalent (first violation printed)
    2: Usage error or unreadable input
"""

import os
import re
import sys

FRAME_RE = re.compile(rb'^(\d+) +(\S+) +0x[0-9a-fA-F]{16} (.*) \+ \d+$')
DARWIN_FRAME_RE = FRAME_RE
LINUX_FRAME_RE = re.compile(rb'^(\d+) +(\S+) at (.+):(\d+):(\d+)$')

def proc_location(sym: bytes):
    """Return the path and line spans of a current proc linkage name."""
    start = re.match(rb'^~proc\d*Proc\(', sym)
    if not start:
        return None
    depth = 1
    quote = None
    escaped = False
    for i in range(start.end(), len(sym)):
        c = sym[i]
        if c == ord('^'):
            return None
        if quote is not None:
            if escaped:
                escaped = False
            elif c == ord('\\'):
                escaped = True
            elif c == quote:
                quote = None
        elif c in (ord('"'), ord("'")):
            quote = c
        elif c == ord('('):
            depth += 1
        elif c == ord(')'):
            depth -= 1
            if depth == 0:
                if sym[i + 1:i + 2] != b'^':
                    return None
                location = re.fullmatch(rb'([^^]+):(\d+)', sym[i + 2:])
                if not location:
                    return None
                path_start = i + 2
                return (path_start, path_start + len(location.group(1)),
                        path_start + location.start(2), path_start + location.end(2))
    return None


# What a carried closure's linkage name ends with: the unit that hosts it, as the
# lowercase hex of the unit's name (SPEC.md IV, "The unit is the object file").
UNIT_SUFFIX_RE = re.compile(rb'\^unit:[0-9a-f]+\Z')
PROC_ORDINAL_RE = re.compile(rb'\A~proc\d*')


def canonical_function(sym: bytes) -> bytes:
    """The function a frame names, without what only one build's linkage adds.

    Two builds of one program name the same function differently in three ways,
    and none of them says anything about the source:

    * a body compiled from an artifact's carried source is linked beside the
      artifact's own object for it, under the same name with one `~iyi` after it;
    * a closure a carried unit hosts ends in `^unit:` and the unit's name in hex,
      and the closure a consumer compiles from the same source does not;
    * a closure is numbered in the order its build reached it (`~proc3`), and a
      build from artifacts reaches them in another order.

    So a function is its name without one trailing `~iyi`, and a closure is its
    Proc type and the file and line it was written at. Two closures of one type
    written on one line are not told apart: the frame a person reads does not
    tell them apart either. A proc name that carries no location keeps its
    number, and so does anything this does not recognise.
    """
    if sym.endswith(b'~iyi'):
        sym = sym[:-4]
    if sym.startswith(b'~proc'):
        unit = UNIT_SUFFIX_RE.search(sym)
        if unit:
            sym = sym[:unit.start()]
    location = proc_location(sym)
    if location:
        start, end, _, _ = location
        head = PROC_ORDINAL_RE.sub(b'~proc', sym[:start], count=1)
        path = sym[start:end]
        canonical = canonical_file(path)
        if canonical != path:
            # NUL cannot occur in a linkage name and prevents a literal path
            # already named std/X from colliding with this equivalence class.
            return head + b'\0' + canonical + sym[end:]
        return head + sym[start:]
    # Older proc symbols use @ as their location separator.
    legacy = re.fullmatch(rb'~proc\d*@([^@:]+):(\d+)', sym)
    if legacy:
        path = legacy.group(1)
        canonical = canonical_file(path)
        if canonical != path:
            return b'~proc@\0' + canonical + b':' + legacy.group(2)
        return b'~proc@' + path + b':' + legacy.group(2)
    return sym

def canonical_file(path: bytes) -> bytes:
    # Only paths beneath the std tree correspond; reject traversal and empty
    # components rather than equating a different file with a std module.
    match = re.fullmatch(rb'(?:.*?[/\\])?(?:src/std/(.+)\.iyi|mods/std/(.+)\.iyimod)', path)
    if match:
        module = match.group(1) or match.group(2)
        if all(part not in (b'', b'.', b'..') for part in re.split(rb'[/\\]', module)):
            return b'std/' + module
    return path


def parse_frame(line: bytes):
    s = line.rstrip(b'\r\n')
    m_darwin = FRAME_RE.match(s)
    if m_darwin:
        return (
            'darwin',
            m_darwin.group(1),
            m_darwin.group(2),
            canonical_function(m_darwin.group(3)),
        )
    m_linux = LINUX_FRAME_RE.match(s)
    if m_linux:
        return (
            'linux',
            m_linux.group(1),
            canonical_function(m_linux.group(2)),
            canonical_file(m_linux.group(3)),
            m_linux.group(4),
            m_linux.group(5),
        )
    return None


def is_frame(line: bytes) -> bool:
    return parse_frame(line) is not None

def is_named_function(fn: bytes) -> bool:
    if fn.startswith(b'[0x') and fn.endswith(b']'):
        return False
    if fn == b'0x0' or (fn.startswith(b'0x') and all(c in b'0123456789abcdefABCDEFx' for c in fn)):
        return False
    return True


def report_violation(line_no: int, rule: str, left: bytes, right: bytes):
    sys.stdout.write(f"line {line_no}: rule {rule}\n  left:  {repr(left)}\n  right: {repr(right)}\n")


def compare_same_opt(lines1: list[bytes], lines2: list[bytes], require_frames: bool = False) -> int:
    # Equal line count
    if len(lines1) != len(lines2):
        min_len = min(len(lines1), len(lines2))
        line_no = min_len + 1
        left = lines1[min_len] if len(lines1) > min_len else b''
        right = lines2[min_len] if len(lines2) > min_len else b''
        report_violation(line_no, 'line_count', left, right)
        return 1

    named_frames_found_1 = 0
    named_frames_found_2 = 0
    for idx, (l1, l2) in enumerate(zip(lines1, lines2)):
        line_no = idx + 1
        f1 = parse_frame(l1)
        f2 = parse_frame(l2)

        # Frame lines at the same positions
        if bool(f1) != bool(f2):
            report_violation(line_no, 'position', l1, l2)
            return 1

        # Non-frame lines byte-equal
        if not f1:
            if l1 != l2:
                report_violation(line_no, 'text', l1, l2)
                return 1
        else:
            kind1, kind2 = f1[0], f2[0]
            if kind1 != kind2:
                report_violation(line_no, 'position', l1, l2)
                return 1

            if kind1 == 'darwin':
                _, idx1, img1, fn1 = f1
                _, idx2, img2, fn2 = f2

                if idx1 != idx2:
                    report_violation(line_no, 'index', l1, l2)
                    return 1
                if img1 != img2:
                    report_violation(line_no, 'image', l1, l2)
                    return 1
                if fn1 != fn2:
                    report_violation(line_no, 'function', l1, l2)
                    return 1
                if is_named_function(fn1):
                    named_frames_found_1 += 1
                if is_named_function(fn2):
                    named_frames_found_2 += 1
            elif kind1 == 'linux':
                _, idx1, fn1, file1, line1, col1 = f1
                _, idx2, fn2, file2, line2, col2 = f2

                if idx1 != idx2:
                    report_violation(line_no, 'index', l1, l2)
                    return 1
                if fn1 != fn2:
                    report_violation(line_no, 'function', l1, l2)
                    return 1
                if (file1, line1, col1) != (file2, line2, col2):
                    report_violation(line_no, 'location', l1, l2)
                    return 1
                if is_named_function(fn1):
                    named_frames_found_1 += 1
                if is_named_function(fn2):
                    named_frames_found_2 += 1

    if require_frames and (named_frames_found_1 == 0 or named_frames_found_2 == 0):
        report_violation(1, 'zero_frames', lines1[0] if lines1 else b'', lines2[0] if lines2 else b'')
        return 1

    return 0


def compare_across_opt(lines1: list[bytes], lines2: list[bytes], require_frames: bool = False) -> int:
    def chunk_items(lines):
        items = []
        i = 0
        n = len(lines)
        while i < n:
            line_no = i + 1
            line = lines[i]
            f = parse_frame(line)
            if f:
                kind = f[0]
                frames = []
                while i < n:
                    cur_f = parse_frame(lines[i])
                    if cur_f and cur_f[0] == kind:
                        frames.append((lines[i], cur_f))
                        i += 1
                    else:
                        break
                items.append((kind, line_no, frames))
            else:
                items.append(('text', line_no, line))
                i += 1
        return items

    items1 = chunk_items(lines1)
    items2 = chunk_items(lines2)

    min_len = min(len(items1), len(items2))
    named_frames_found_1 = 0
    named_frames_found_2 = 0
    for i in range(min_len):
        k1, lno1, val1 = items1[i]
        k2, lno2, val2 = items2[i]

        if k1 != k2:
            left = val1 if k1 == 'text' else val1[0][0]
            right = val2 if k2 == 'text' else val2[0][0]
            report_violation(lno1, 'position', left, right)
            return 1

        if k1 == 'text':
            if val1 != val2:
                report_violation(lno1, 'text', val1, val2)
                return 1
        elif k1 == 'darwin':
            # Darwin legacy across-optimization semantics:
            # inlining changes frame counts and offsets; verify non-empty chunk
            if len(val1) == 0 or len(val2) == 0:
                left = val1[0][0] if val1 else b''
                right = val2[0][0] if val2 else b''
                report_violation(lno1, 'empty_frames', left, right)
                return 1
            for _, f in val1:
                if is_named_function(f[3]):
                    named_frames_found_1 += 1
            for _, f in val2:
                if is_named_function(f[3]):
                    named_frames_found_2 += 1
        elif k1 == 'linux':
            # Strict Linux across-optimization semantics:
            # preserve count, index, function, file, line, column, order
            if len(val1) != len(val2):
                min_flen = min(len(val1), len(val2))
                err_lno = lno1 + min_flen
                left = val1[min_flen][0] if len(val1) > min_flen else b''
                right = val2[min_flen][0] if len(val2) > min_flen else b''
                report_violation(err_lno, 'line_count', left, right)
                return 1

            for f_idx, ((raw1, f1), (raw2, f2)) in enumerate(zip(val1, val2)):
                frame_lno = lno1 + f_idx
                _, idx1, fn1, file1, line1, col1 = f1
                _, idx2, fn2, file2, line2, col2 = f2

                if idx1 != idx2:
                    report_violation(frame_lno, 'index', raw1, raw2)
                    return 1
                if fn1 != fn2:
                    report_violation(frame_lno, 'function', raw1, raw2)
                    return 1
                if (file1, line1, col1) != (file2, line2, col2):
                    report_violation(frame_lno, 'location', raw1, raw2)
                    return 1
                if is_named_function(fn1):
                    named_frames_found_1 += 1
                if is_named_function(fn2):
                    named_frames_found_2 += 1

    if len(items1) != len(items2):
        if len(items1) > len(items2):
            k, lno, val = items1[min_len]
            left = val if k == 'text' else val[0][0]
            right = b''
        else:
            k, lno, val = items2[min_len]
            left = b''
            right = val if k == 'text' else val[0][0]
        report_violation(lno, 'item_count', left, right)
        return 1

    if require_frames and (named_frames_found_1 == 0 or named_frames_found_2 == 0):
        report_violation(1, 'zero_frames', lines1[0] if lines1 else b'', lines2[0] if lines2 else b'')
        return 1

    return 0


def generate_mutant(kind: str, lines: list[bytes]) -> list[bytes]:
    mutated = list(lines)
    if kind == "text":
        for i, line in enumerate(mutated):
            if not is_frame(line):
                mutated[i] = b"MUTANT " + line
                return mutated
        raise ValueError("no text line to mutate")
    elif kind in ("drop", "count"):
        for i, line in enumerate(mutated):
            if is_frame(line):
                del mutated[i]
                return mutated
        if mutated:
            del mutated[0]
            return mutated
        raise ValueError("no line to drop")
    elif kind == "swap":
        for i in range(len(mutated) - 1):
            if is_frame(mutated[i]) and is_frame(mutated[i + 1]):
                mutated[i], mutated[i + 1] = mutated[i + 1], mutated[i]
                return mutated
        if len(mutated) >= 2:
            mutated[0], mutated[1] = mutated[1], mutated[0]
            return mutated
        raise ValueError("not enough lines to swap")
    elif kind == "position":
        for i in range(len(mutated) - 1):
            f1 = is_frame(mutated[i])
            f2 = is_frame(mutated[i + 1])
            if f1 != f2:
                mutated[i], mutated[i + 1] = mutated[i + 1], mutated[i]
                return mutated
        if mutated:
            if is_frame(mutated[0]):
                mutated.insert(0, b"nonframe text line\n")
            else:
                mutated.insert(0, b"0   frame_fn at /path/probe.iyi:1:1\n")
            return mutated
        raise ValueError("no line to mutate for position")
    elif kind == "function":
        for i, line in enumerate(mutated):
            s = line.rstrip(b'\r\n')
            m_d = FRAME_RE.match(s)
            m_l = LINUX_FRAME_RE.match(s)
            if m_d:
                fn = m_d.group(3)
                new_fn = b"mutant_" + fn
                mutated[i] = line.replace(fn, new_fn, 1)
                return mutated
            elif m_l:
                fn = m_l.group(2)
                new_fn = b"mutant_" + fn
                mutated[i] = line.replace(fn, new_fn, 1)
                return mutated
        raise ValueError("no frame line for function mutant")
    elif kind == "index":
        for i, line in enumerate(mutated):
            s = line.rstrip(b'\r\n')
            m_d = FRAME_RE.match(s)
            m_l = LINUX_FRAME_RE.match(s)
            if m_d or m_l:
                idx = (m_d or m_l).group(1)
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
    elif kind in ("location", "line"):
        for i, line in enumerate(mutated):
            s = line.rstrip(b'\r\n')
            m_l = LINUX_FRAME_RE.match(s)
            if m_l:
                old_line = m_l.group(4)
                new_line = str(int(old_line) + 12345).encode()
                old_loc = m_l.group(3) + b':' + old_line + b':' + m_l.group(5)
                new_loc = m_l.group(3) + b':' + new_line + b':' + m_l.group(5)
                mutated[i] = line.replace(old_loc, new_loc, 1)
                return mutated
            m_d = FRAME_RE.match(s)
            if m_d:
                fn = m_d.group(3)
                loc = proc_location(fn)
                sub_m = re.fullmatch(rb'~proc\d*@[^@:]+:(\d+)', fn) if not loc else None
                if loc or sub_m:
                    start, end = (loc[2], loc[3]) if loc else sub_m.span(1)
                    old_num = fn[start:end]
                    new_num = str(int(old_num) + 12345).encode()
                    new_fn = fn[:start] + new_num + fn[end:]
                    mutated[i] = line.replace(fn, new_fn, 1)
                    return mutated
        raise ValueError("no frame line with location/line for mutant")
    elif kind == "column":
        for i, line in enumerate(mutated):
            s = line.rstrip(b'\r\n')
            m_l = LINUX_FRAME_RE.match(s)
            if m_l:
                old_col = m_l.group(5)
                new_col = str(int(old_col) + 54321).encode()
                old_loc = m_l.group(3) + b':' + m_l.group(4) + b':' + old_col
                new_loc = m_l.group(3) + b':' + m_l.group(4) + b':' + new_col
                mutated[i] = line.replace(old_loc, new_loc, 1)
                return mutated
        raise ValueError("no frame line with column for mutant")
    elif kind == "file":
        for i, line in enumerate(mutated):
            s = line.rstrip(b'\r\n')
            m_l = LINUX_FRAME_RE.match(s)
            if m_l:
                old_file = m_l.group(3)
                new_file = old_file + b'_mutant'
                old_loc = old_file + b':' + m_l.group(4) + b':' + m_l.group(5)
                new_loc = new_file + b':' + m_l.group(4) + b':' + m_l.group(5)
                mutated[i] = line.replace(old_loc, new_loc, 1)
                return mutated
        raise ValueError("no frame line with file for mutant")
    elif kind == "module":
        # change std/X to std/Y in a recognized frame
        for i, line in enumerate(mutated):
            s = line.rstrip(b'\r\n')
            m_d = FRAME_RE.match(s)
            if m_d:
                fn = m_d.group(3)
                if b'std/' in fn:
                    new_fn = re.sub(rb'std/([a-zA-Z0-9_]+)', rb'std/mutant_mod', fn, count=1)
                    if new_fn != fn:
                        mutated[i] = line.replace(fn, new_fn, 1)
                        return mutated
            m_l = LINUX_FRAME_RE.match(s)
            if m_l:
                file_part = m_l.group(3)
                if b'std/' in file_part:
                    new_file = re.sub(rb'std/([a-zA-Z0-9_]+)', rb'std/mutant_mod', file_part, count=1)
                    if new_file != file_part:
                        mutated[i] = line.replace(file_part, new_file, 1)
                        return mutated
                fn_part = m_l.group(2)
                if b'std/' in fn_part:
                    new_fn = re.sub(rb'std/([a-zA-Z0-9_]+)', rb'std/mutant_mod', fn_part, count=1)
                    if new_fn != fn_part:
                        mutated[i] = line.replace(fn_part, new_fn, 1)
                        return mutated
        raise ValueError("no frame line with std/ for module mutant")
    else:
        raise ValueError(f"unknown mutant kind: {kind}")


def main():
    args = sys.argv[1:]
    if not args:
        sys.stderr.write("Usage: frames_equivalent.py [--across-optimisation] [--require-frames] OUT_A OUT_B\n       frames_equivalent.py --mutant KIND OUT\n")
        sys.exit(2)

    if args[0] in ("--test", "--selftest"):
        from test_frames_equivalent import run_all_tests
        sys.exit(run_all_tests())

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
    require_frames = False
    files = []
    for arg in args:
        if arg in ("--across-optimisation", "--across-optimization"):
            across_opt = True
        elif arg in ("--require-frames", "--require-named-frames", "--named-frame-proof"):
            require_frames = True
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
        ret = compare_across_opt(lines1, lines2, require_frames=require_frames)
    else:
        ret = compare_same_opt(lines1, lines2, require_frames=require_frames)

    sys.exit(ret)

if __name__ == "__main__":
    main()
