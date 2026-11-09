#!/usr/bin/env python3
"""Focused behavioral tests for bench/frames_equivalent.py.

Verifies:
1. Exact semantic equivalence on real captured Linux named frames from
   run 42573044166 (normal.stderr vs artifact.stderr).
2. Discriminating mutations for index, function, location, position, count, text.
3. Explicit named-frame proof that rejects zero-frame false positives while
   allowing zero-frame corpus outputs under default comparison.
4. Approved std source (src/std/X.iyi) vs modular artifact (mods/std/X.iyimod)
   canonicalization, without masking actual line, column, function, or module changes.
5. Unknown addresses and unrecognized lines preserved exact without normalization.
6. Preservation of existing Darwin comparator behavior and rules.
7. Across-optimization chunking across frame and text boundaries.
"""

import io
import os
import sys

# Ensure bench/ is on sys.path
BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
if BENCH_DIR not in sys.path:
    sys.path.insert(0, BENCH_DIR)

from frames_equivalent import (
    FRAME_RE,
    DARWIN_FRAME_RE,
    LINUX_FRAME_RE,
    canonical_file,
    canonical_function,
    compare_across_opt,
    compare_same_opt,
    generate_mutant,
    is_frame,
    parse_frame,
)

# Real captured outputs from run 42573044166
CAPTURED_NORMAL = b"""iyi: panic: frame qualification
  at /__w/_temp/frame-probe/probe.iyi:5
0   frame_inner at /__w/_temp/frame-probe/probe.iyi:5:3
1   frame_inner at /__w/_temp/frame-probe/probe.iyi:6:3
2   frame_inner at /__w/_temp/frame-probe/probe.iyi:6:3
3   frame_inner at /__w/_temp/frame-probe/probe.iyi:6:3
4   __iyi_main at /__w/_temp/frame-probe/probe.iyi:8:1
5   __iyi_program at /__w/iyi/iyi/src/iyi/prelude.iyi:10096:3
6   __iyi_enter at /__w/iyi/iyi/src/iyi/prelude.iyi:10086:3
7   main at /__w/iyi/iyi/src/iyi/prelude.iyi:11042:3
"""

CAPTURED_ARTIFACT = b"""iyi: panic: frame qualification
  at /__w/_temp/frame-probe/probe.iyi:5
0   frame_inner at /__w/_temp/frame-probe/probe.iyi:5:3
1   frame_inner at /__w/_temp/frame-probe/probe.iyi:6:3
2   frame_inner at /__w/_temp/frame-probe/probe.iyi:6:3
3   frame_inner at /__w/_temp/frame-probe/probe.iyi:6:3
4   __iyi_main at /__w/_temp/frame-probe/probe.iyi:8:1
5   __iyi_program at /__w/iyi/iyi/src/iyi/prelude.iyi:10096:3
6   __iyi_enter at /__w/iyi/iyi/src/iyi/prelude.iyi:10086:3
7   main at /__w/iyi/iyi/src/iyi/prelude.iyi:11042:3
"""

# Real Darwin frames
DARWIN_SAMPLE_1 = b"""0   a.out                               0x0000000100003f50 ~proc3@samples/iyi/hello.iyi:1 + 16
1   a.out                               0x0000000100004120 main + 32
"""

DARWIN_SAMPLE_2 = b"""0   a.out                               0x0000000100099999 ~proc3@samples/iyi/hello.iyi:1 + 48
1   a.out                               0x0000000100088888 main + 64
"""


def capture_violation(fn, *args, **kwargs):
    """Run fn and capture reported violation rule and output."""
    old_stdout = sys.stdout
    sys.stdout = io.StringIO()
    try:
        ret = fn(*args, **kwargs)
        out = sys.stdout.getvalue()
        rule = None
        for line in out.splitlines():
            if "rule " in line:
                rule = line.split("rule ")[1].strip()
                break
        return ret, rule, out
    finally:
        sys.stdout = old_stdout


def test_captured_linux_equivalence():
    lines_n = CAPTURED_NORMAL.splitlines(keepends=True)
    lines_a = CAPTURED_ARTIFACT.splitlines(keepends=True)

    # Both same_opt and across_opt must evaluate as equivalent (0)
    ret, rule, _ = capture_violation(compare_same_opt, lines_n, lines_a)
    assert ret == 0, f"normal vs artifact same_opt returned {ret}"

    ret, rule, _ = capture_violation(compare_across_opt, lines_n, lines_a)
    assert ret == 0, f"normal vs artifact across_opt returned {ret}"

    # Also equivalent with require_frames=True
    ret, rule, _ = capture_violation(compare_same_opt, lines_n, lines_a, require_frames=True)
    assert ret == 0, f"normal vs artifact with require_frames=True returned {ret}"

    ret, rule, _ = capture_violation(compare_across_opt, lines_n, lines_a, require_frames=True)
    assert ret == 0, f"normal vs artifact across_opt with require_frames=True returned {ret}"


def test_discriminating_mutations_linux():
    lines = CAPTURED_NORMAL.splitlines(keepends=True)

    # 1. index mutant
    mut = generate_mutant("index", lines)
    ret, rule, _ = capture_violation(compare_same_opt, lines, mut)
    assert ret == 1, "index mutant did not fail"
    assert rule == "index", f"index mutant reported rule {rule!r}, expected 'index'"

    # 2. function mutant
    mut = generate_mutant("function", lines)
    ret, rule, _ = capture_violation(compare_same_opt, lines, mut)
    assert ret == 1, "function mutant did not fail"
    assert rule == "function", f"function mutant reported rule {rule!r}, expected 'function'"

    # 3. location mutant (line change)
    mut = generate_mutant("location", lines)
    ret, rule, _ = capture_violation(compare_same_opt, lines, mut)
    assert ret == 1, "location mutant did not fail"
    assert rule == "location", f"location mutant reported rule {rule!r}, expected 'location'"

    # 4. location mutant via column change
    mut = generate_mutant("column", lines)
    ret, rule, _ = capture_violation(compare_same_opt, lines, mut)
    assert ret == 1, "column mutant did not fail"
    assert rule == "location", f"column mutant reported rule {rule!r}, expected 'location'"

    # 5. location mutant via file change
    mut = generate_mutant("file", lines)
    ret, rule, _ = capture_violation(compare_same_opt, lines, mut)
    assert ret == 1, "file mutant did not fail"
    assert rule == "location", f"file mutant reported rule {rule!r}, expected 'location'"

    # 6. position mutant (frame line swapped with nonframe line)
    mut = generate_mutant("position", lines)
    ret, rule, _ = capture_violation(compare_same_opt, lines, mut)
    assert ret == 1, "position mutant did not fail"
    assert rule == "position", f"position mutant reported rule {rule!r}, expected 'position'"

    # 7. count / drop mutant (frame line dropped)
    mut = generate_mutant("count", lines)
    ret, rule, _ = capture_violation(compare_same_opt, lines, mut)
    assert ret == 1, "count mutant did not fail"
    assert rule == "line_count", f"count mutant reported rule {rule!r}, expected 'line_count'"

    # 8. text mutant (nonframe line mutated)
    mut = generate_mutant("text", lines)
    ret, rule, _ = capture_violation(compare_same_opt, lines, mut)
    assert ret == 1, "text mutant did not fail"
    assert rule == "text", f"text mutant reported rule {rule!r}, expected 'text'"


def test_explicit_named_frame_proof_rejects_zero_frames():
    # Normal corpus output without any panic / frames
    corpus_no_frames = [
        b"compilation successful\n",
        b"running test suite\n",
        b"42 tests passed\n",
    ]

    # Without require_frames: passes (no requirement every corpus output has frames)
    ret, rule, _ = capture_violation(compare_same_opt, corpus_no_frames, corpus_no_frames, require_frames=False)
    assert ret == 0, f"corpus without frames failed under default require_frames=False: {rule}"

    # With require_frames: must be REJECTED as zero-frame false positive
    ret, rule, _ = capture_violation(compare_same_opt, corpus_no_frames, corpus_no_frames, require_frames=True)
    assert ret == 1, "zero-frame output unexpectedly passed under require_frames=True"
    assert rule == "zero_frames", f"expected rule 'zero_frames', got {rule!r}"

    # In across_opt as well
    ret, rule, _ = capture_violation(compare_across_opt, corpus_no_frames, corpus_no_frames, require_frames=True)
    assert ret == 1, "zero-frame output unexpectedly passed in across_opt under require_frames=True"
    assert rule == "zero_frames", f"expected rule 'zero_frames', got {rule!r}"

    # Empty files under require_frames=True must also be rejected
    ret, rule, _ = capture_violation(compare_same_opt, [], [], require_frames=True)
    assert ret == 1, "empty output unexpectedly passed under require_frames=True"
    assert rule == "zero_frames", f"expected rule 'zero_frames', got {rule!r}"

    # Address-only frame [0x...] without a named function
    addr_only_frames = [
        b"iyi: panic: test\n",
        b"0   [0x7f0001] at /path/test.iyi:1:2\n",
    ]
    ret, rule, _ = capture_violation(compare_same_opt, addr_only_frames, addr_only_frames, require_frames=False)
    assert ret == 0, f"identical address-only frames failed under require_frames=False: {rule}"

    # Under require_frames=True, address-only frames MUST be rejected as zero named frames
    ret, rule, _ = capture_violation(compare_same_opt, addr_only_frames, addr_only_frames, require_frames=True)
    assert ret == 1, "address-only frame unexpectedly passed under require_frames=True"
    assert rule == "zero_frames", f"expected rule 'zero_frames', got {rule!r}"

    # Across-opt with address-only frames under require_frames=True MUST also be rejected
    ret, rule, _ = capture_violation(compare_across_opt, addr_only_frames, addr_only_frames, require_frames=True)
    assert ret == 1, "address-only frame unexpectedly passed across-opt under require_frames=True"
    assert rule == "zero_frames", f"expected rule 'zero_frames', got {rule!r}"

def test_approved_std_canonicalization():
    # Source vs modular artifact in std/
    source_line = b"0   proc_work at /home/runner/work/iyi/iyi/src/std/debug.iyi:100:15\n"
    artifact_line = b"0   proc_work at /tmp/scratch/mods/std/debug.iyimod:100:15\n"
    ret, rule, _ = capture_violation(compare_same_opt, [source_line], [artifact_line])
    assert ret == 0, f"std source vs artifact unexpectedly differed: {rule}"

    # Submodule in std/
    source_sub = b"0   fn at /home/runner/src/std/crypto/sha256.iyi:42:1\n"
    artifact_sub = b"0   fn at /home/runner/mods/std/crypto/sha256.iyimod:42:1\n"
    ret, rule, _ = capture_violation(compare_same_opt, [source_sub], [artifact_sub])
    assert ret == 0, f"std submodule source vs artifact unexpectedly differed: {rule}"

    # MUST NOT mask line difference
    line_diff = b"0   proc_work at /tmp/scratch/mods/std/debug.iyimod:101:15\n"
    ret, rule, _ = capture_violation(compare_same_opt, [source_line], [line_diff])
    assert ret == 1, "actual line change was masked"
    assert rule == "location", f"expected 'location', got {rule!r}"

    # MUST NOT mask column difference
    col_diff = b"0   proc_work at /tmp/scratch/mods/std/debug.iyimod:100:16\n"
    ret, rule, _ = capture_violation(compare_same_opt, [source_line], [col_diff])
    assert ret == 1, "actual column change was masked"
    assert rule == "location", f"expected 'location', got {rule!r}"

    # MUST NOT mask function change
    fn_diff = b"0   proc_other at /tmp/scratch/mods/std/debug.iyimod:100:15\n"
    ret, rule, _ = capture_violation(compare_same_opt, [source_line], [fn_diff])
    assert ret == 1, "actual function change was masked"
    assert rule == "function", f"expected 'function', got {rule!r}"

    # MUST NOT mask module change (std/debug vs std/digest)
    mod_diff = b"0   proc_work at /tmp/scratch/mods/std/digest.iyimod:100:15\n"
    ret, rule, _ = capture_violation(compare_same_opt, [source_line], [mod_diff])
    assert ret == 1, "module change was masked"
    assert rule == "location", f"expected 'location', got {rule!r}"

    # Non-std paths MUST NOT be canonicalized
    non_std_src = b"0   fn at /home/runner/work/src/other/test.iyi:10:5\n"
    non_std_art = b"0   fn at /home/runner/work/mods/other/test.iyimod:10:5\n"
    ret, rule, _ = capture_violation(compare_same_opt, [non_std_src], [non_std_art])
    assert ret == 1, "non-std path difference was unexpectedly canonicalized"
    assert rule == "location", f"expected 'location', got {rule!r}"


def test_unknown_addresses_not_normalized():
    # Unknown addresses in nonframe lines must compare byte-for-byte exact
    line1 = b"0   [0x00007fff12345678]\n"
    line2 = b"0   [0x00007fff87654321]\n"
    ret, rule, _ = capture_violation(compare_same_opt, [line1], [line2])
    assert ret == 1, "differing unknown address lines were normalized away"
    assert rule == "text", f"expected 'text', got {rule!r}"

    # Unknown address in function name must compare byte-for-byte exact
    fn_addr1 = b"0   [0x7f0001] at /path/test.iyi:1:2\n"
    fn_addr2 = b"0   [0x7f0002] at /path/test.iyi:1:2\n"
    ret, rule, _ = capture_violation(compare_same_opt, [fn_addr1], [fn_addr2])
    assert ret == 1, "unknown address in function name was normalized away"
    assert rule == "function", f"expected 'function', got {rule!r}"


def test_darwin_backward_compatibility():
    d1 = DARWIN_SAMPLE_1.splitlines(keepends=True)
    d2 = DARWIN_SAMPLE_2.splitlines(keepends=True)

    # Equivalent despite differing 16-hex addresses and instruction offsets
    ret, rule, _ = capture_violation(compare_same_opt, d1, d2)
    assert ret == 0, f"Darwin equivalence failed: {rule}"

    # Legacy paths may correspond, but distinct ordinals do not.
    sym_a = b"0   a.out                               0x0000000100003f50 ~proc123@src/std/big.iyi:10 + 16\n"
    sym_b = b"0   a.out                               0x0000000100009999 ~proc123@mods/std/big.iyimod:10 + 32\n"
    ret, rule, _ = capture_violation(compare_same_opt, [sym_a], [sym_b])
    assert ret == 0, f"Darwin proc/std canonicalization failed: {rule}"
    ret, rule, _ = capture_violation(compare_same_opt, [sym_a], [sym_b.replace(b'proc123', b'proc456')])
    assert ret == 1 and rule == "function", "legacy proc ordinal was discarded"

    sym_c = b"0   a.out                               0x0000000100003f50 run_loop~iyi + 16\n"
    sym_d = b"0   a.out                               0x0000000100009999 run_loop + 32\n"
    ret, rule, _ = capture_violation(compare_same_opt, [sym_c], [sym_d])
    assert ret == 1 and rule == "function", "function suffix was discarded"
    # Darwin mutations fail with their expected rules
    mut_idx = generate_mutant("index", d1)
    ret, rule, _ = capture_violation(compare_same_opt, d1, mut_idx)
    assert ret == 1 and rule == "index", f"Darwin index mutant: {rule}"

    mut_img = generate_mutant("image", d1)
    ret, rule, _ = capture_violation(compare_same_opt, d1, mut_img)
    assert ret == 1 and rule == "image", f"Darwin image mutant: {rule}"

    mut_fn = generate_mutant("function", d1)
    ret, rule, _ = capture_violation(compare_same_opt, d1, mut_fn)
    assert ret == 1 and rule == "function", f"Darwin function mutant: {rule}"

    # Darwin across-opt named vs address-only 0x0 (real prelude.iyi:10397 shape)
    darwin_named = [b"0   a.out                               0x0000000100003f50 main + 16\n"]
    darwin_addr_only = [b"0   ???                                 0x0000000100009999 0x0 + 32\n"]

    # Default relaxed across-opt preserves Darwin equivalence across inlined/unnamed frames
    ret, rule, _ = capture_violation(compare_across_opt, darwin_named, darwin_addr_only, require_frames=False)
    assert ret == 0, f"Darwin across-opt default relaxed mode failed on named vs 0x0: {rule}"
    ret, rule, _ = capture_violation(compare_across_opt, darwin_addr_only, darwin_named, require_frames=False)
    assert ret == 0, f"Darwin across-opt default relaxed mode failed on reversed 0x0 vs named: {rule}"

    # Under require_frames=True, both same-order and reversed MUST reject with zero_frames
    ret, rule, _ = capture_violation(compare_across_opt, darwin_named, darwin_addr_only, require_frames=True)
    assert ret == 1, "Darwin across-opt named vs 0x0 unexpectedly passed with require_frames=True"
    assert rule == "zero_frames", f"expected 'zero_frames', got {rule!r}"

    ret, rule, _ = capture_violation(compare_across_opt, darwin_addr_only, darwin_named, require_frames=True)
    assert ret == 1, "Darwin across-opt reversed 0x0 vs named unexpectedly passed with require_frames=True"
    assert rule == "zero_frames", f"expected 'zero_frames', got {rule!r}"

    ret, rule, _ = capture_violation(compare_across_opt, darwin_addr_only, darwin_addr_only, require_frames=True)
    assert ret == 1, "Darwin across-opt both 0x0 unexpectedly passed with require_frames=True"
    assert rule == "zero_frames", f"expected 'zero_frames', got {rule!r}"

def test_cross_format_mismatch():
    darwin_line = b"0   a.out                               0x0000000100003f50 main + 16\n"
    linux_line = b"0   main at /path/test.iyi:1:2\n"
    ret, rule, _ = capture_violation(compare_same_opt, [darwin_line], [linux_line])
    assert ret == 1, "Darwin frame vs Linux frame unexpectedly matched"
    assert rule == "position", f"expected 'position', got {rule!r}"


def test_strict_linux_across_opt():
    lines_n = CAPTURED_NORMAL.splitlines(keepends=True)

    # 1. Synthetic replacement with wrong frame count / contents
    synthetic_wrong = [
        b"iyi: panic: frame qualification\n",
        b"  at /__w/_temp/frame-probe/probe.iyi:5\n",
        b"99   wrong at /wrong.iyi:99:99\n",
    ]
    ret, rule, _ = capture_violation(compare_across_opt, lines_n, synthetic_wrong)
    assert ret == 1, "across_opt accepted wrong Linux frame chunk length/contents"
    assert rule == "line_count", f"expected 'line_count', got {rule!r}"

    # 2. Mutating index in real captured Linux frames must fail across_opt
    mut_idx = generate_mutant("index", lines_n)
    ret, rule, _ = capture_violation(compare_across_opt, lines_n, mut_idx)
    assert ret == 1, "across_opt accepted index mutation"
    assert rule == "index", f"expected 'index', got {rule!r}"

    # 3. Mutating function in real captured Linux frames must fail across_opt
    mut_fn = generate_mutant("function", lines_n)
    ret, rule, _ = capture_violation(compare_across_opt, lines_n, mut_fn)
    assert ret == 1, "across_opt accepted function mutation"
    assert rule == "function", f"expected 'function', got {rule!r}"

    # 4. Mutating location in real captured Linux frames must fail across_opt
    mut_loc = generate_mutant("location", lines_n)
    ret, rule, _ = capture_violation(compare_across_opt, lines_n, mut_loc)
    assert ret == 1, "across_opt accepted location mutation"
    assert rule == "location", f"expected 'location', got {rule!r}"


def test_module_mutant_restricts_to_recognized_frame():
    # Preceding nonframe diagnostic holding std/ path
    lines_with_diag = [
        b"compiling src/std/debug.iyi\n",
        b"0   proc_work at /home/runner/work/iyi/iyi/src/std/debug.iyi:100:15\n",
    ]
    mut = generate_mutant("module", lines_with_diag)
    # The nonframe diagnostic must remain completely untouched
    assert mut[0] == lines_with_diag[0], f"nonframe line was incorrectly mutated: {mut[0]!r}"
    # The frame line must be mutated
    assert mut[1] != lines_with_diag[1], "frame line was not mutated"
    assert b"std/mutant_mod" in mut[1], f"expected std/mutant_mod in frame line: {mut[1]!r}"
    # Comparison must fail via location rule on the frame, NOT text on nonframe line
    ret, rule, _ = capture_violation(compare_same_opt, lines_with_diag, mut)
    assert ret == 1, "module mutant comparison did not fail"
    assert rule == "location", f"expected 'location', got {rule!r}"

    # Darwin module mutant also leaves preceding nonframe text untouched
    darwin_with_diag = [
        b"loading src/std/big.iyi\n",
        b"0   a.out                               0x0000000100003f50 ~proc@src/std/big.iyi:10 + 16\n",
    ]
    darwin_mut = generate_mutant("module", darwin_with_diag)
    assert darwin_mut[0] == darwin_with_diag[0], f"Darwin nonframe line was mutated: {darwin_mut[0]!r}"
    assert darwin_mut[1] != darwin_with_diag[1], "Darwin frame line was not mutated"
    ret, rule, _ = capture_violation(compare_same_opt, darwin_with_diag, darwin_mut)
    assert ret == 1, "Darwin module mutant did not fail"
    assert rule == "function", f"expected 'function', got {rule!r}"

def test_captured_darwin_proc_and_collisions():
    source = b'4   std_http_exercise                   0x0000000105d32a54 ~procProc(Int32)^/Users/runner/work/iyi/iyi/.build/../src/std/http.iyi:1832 + 80\n'
    artifact = b'4   std_http_exercise                   0x00000001047074a4 ~procProc(Int32)^mods/std/http.iyimod:1832 + 80\n'
    ret, rule, _ = capture_violation(compare_same_opt, [source], [artifact], require_frames=True)
    assert ret == 0, f"captured HTTP frames differed: {rule}"

    colon_source = source.replace(b'/Users/runner/work/iyi/iyi/.build/..', b'/tmp/build:debug')
    ret, rule, _ = capture_violation(compare_same_opt, [colon_source], [artifact])
    assert ret == 0, f"colon in source path prevented equivalence: {rule}"
    for old, new in [(b'http.iyimod', b'debug.iyimod'),
                     (b':1832', b':1833'),
                     (b'Proc(Int32)', b'Proc(Int64)')]:
        ret, _, _ = capture_violation(compare_same_opt, [colon_source], [artifact.replace(old, new, 1)])
        assert ret == 1, f"colon path masked {old!r} mismatch"
    colon_mutant = generate_mutant("location", [colon_source])
    assert b'/tmp/build:debug/' in colon_mutant[0] and b':14177 +' in colon_mutant[0]
    ret, _, _ = capture_violation(compare_same_opt, [colon_source], colon_mutant)
    assert ret == 1, "colon path location mutant survived"

    colon_escaped = colon_source.replace(b'http.iyi', b'http%5E.iyi')
    artifact_escaped = artifact.replace(b'http.iyimod', b'http%5E.iyimod')
    ret, _, _ = capture_violation(compare_same_opt, [colon_escaped], [artifact_escaped])
    assert ret == 0, "escaped caret with colon path did not survive aliasing"
    ret, _, _ = capture_violation(compare_same_opt, [colon_escaped], [artifact_escaped.replace(b'%5E', b'^')])
    assert ret == 1, "escaped caret collided with a literal caret"

    for old, new in [
        (b'http.iyimod', b'debug.iyimod'),
        (b':1832', b':1833'),
        (b'Proc(Int32)', b'Proc(Int64)'),
        (b'~procProc', b'~proc2Proc'),
        (b'~procProc', b'~funProc'),
        (b'std_http_exercise', b'other_image'),
        (b'4   ', b'5   '),
        (b'mods/std/http.iyimod', b'std/http'),
        (b'mods/std/http.iyimod', b'mods/std/../std/http.iyimod'),
    ]:
        changed = artifact.replace(old, new, 1)
        assert changed != artifact
        ret, _, _ = capture_violation(compare_same_opt, [source], [changed])
        assert ret == 1, f"masked difference {old!r} -> {new!r}"

    parallel_source = b'2   std_parallel_exercise               0x00000001030158e0 ~proc3Proc(Array(Tuple(Int64, Array(Int32))))^/Users/runner/work/iyi/iyi/.build/../src/std/parallel.iyi:215 + 396\n'
    parallel_artifact = b'2   std_parallel_exercise               0x0000000102f63c64 ~proc2Proc(Array(Tuple(Int64, Array(Int32))))^mods/std/parallel.iyimod:215 + 444\n'
    ret, rule, _ = capture_violation(compare_same_opt, [parallel_source], [parallel_artifact])
    assert ret == 1 and rule == "function", "unverified parallel ordinal alias accepted"
    ret, _, _ = capture_violation(compare_same_opt, [parallel_source], [parallel_artifact.replace(b'~proc2', b'~proc3')])
    assert ret == 0, "nested type path alias failed"

    escaped_source = source.replace(b'Proc(Int32)', b'Proc(NamedTuple("a%5Eb%40c%25": Array(Int32)))').replace(b'http.iyi', b'http%5E%40%25.iyi')
    escaped_artifact = artifact.replace(b'Proc(Int32)', b'Proc(NamedTuple("a%5Eb%40c%25": Array(Int32)))').replace(b'http.iyimod', b'http%5E%40%25.iyimod')
    ret, _, _ = capture_violation(compare_same_opt, [escaped_source], [escaped_artifact])
    assert ret == 0, "escaped type or module did not survive aliasing"
    for old, new in [(b'%5E', b'^'), (b'%40', b'@'), (b'%25', b'%2525')]:
        ret, _, _ = capture_violation(compare_same_opt, [escaped_source], [escaped_artifact.replace(old, new, 1)])
        assert ret == 1, f"escaped bytes {old!r} were collapsed"

    for bad in [
        artifact.replace(b'Proc(Int32)', b'Proc(Int32'),
        artifact.replace(b'Proc(Int32)^', b'Proc(Int32)junk^'),
        artifact.replace(b'Proc(Int32)^', b'Proc(Int32)^extra^'),
        artifact.replace(b':1832', b':1832extra'),
    ]:
        ret, _, _ = capture_violation(compare_same_opt, [source], [bad])
        assert ret == 1, "malformed proc grammar accepted"

    other = b'5   std_http_exercise                   0x0000000105d32a54 another + 80\n'
    original = [b'panic\n', source, other]
    for changed in ([b'changed\n', artifact, other], [b'panic\n', other, artifact],
                    [b'panic\n', artifact], [b'panic\n', artifact, other, other]):
        ret, _, _ = capture_violation(compare_same_opt, original, changed)
        assert ret == 1, "text, order, or count difference was masked"
    for kind in ("location", "line", "module", "function", "index", "image"):
        mutant = generate_mutant(kind, original)
        assert mutant[0] == original[0], f"{kind} mutant touched nonframe text"
        ret, _, _ = capture_violation(compare_same_opt, original, mutant)
        assert ret == 1, f"{kind} mutant survived"


def run_all_tests() -> int:
    tests = [
        ("test_captured_linux_equivalence", test_captured_linux_equivalence),
        ("test_discriminating_mutations_linux", test_discriminating_mutations_linux),
        ("test_explicit_named_frame_proof_rejects_zero_frames", test_explicit_named_frame_proof_rejects_zero_frames),
        ("test_strict_linux_across_opt", test_strict_linux_across_opt),
        ("test_module_mutant_restricts_to_recognized_frame", test_module_mutant_restricts_to_recognized_frame),
        ("test_approved_std_canonicalization", test_approved_std_canonicalization),
        ("test_unknown_addresses_not_normalized", test_unknown_addresses_not_normalized),
        ("test_darwin_backward_compatibility", test_darwin_backward_compatibility),
        ("test_captured_darwin_proc_and_collisions", test_captured_darwin_proc_and_collisions),
        ("test_cross_format_mismatch", test_cross_format_mismatch),
    ]
    failed = 0
    for name, test in tests:
        try:
            test()
            print(f"PASS: {name}")
        except Exception as e:
            print(f"FAIL: {name}: {e}")
            failed += 1

    if failed == 0:
        print(f"\nAll {len(tests)} test suites PASSED")
        return 0
    else:
        print(f"\n{failed}/{len(tests)} test suites FAILED")
        return 1


if __name__ == "__main__":
    sys.exit(run_all_tests())
