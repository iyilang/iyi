#!/usr/bin/env bash
# Exercises `std/diff`: edit scripts, unified diffs and patches, against
# GNU diff, GNU patch and Python's difflib.
#
#     bash bench/std_diff_exercise.sh
#
# Python writes a corpus of text pairs and has GNU diff (`-u`, and
# `--minimal` for the count of changed lines), difflib and GNU patch
# (`-F0`, on the old text moved down and on it spoilt) answer for each;
# the exercise must change as few lines as `diff --minimal`, write GNU's
# diff byte for byte where the pair has one shortest script, apply GNU's
# and difflib's diffs, and apply a moved or spoilt text as GNU patch did
# or refuse it as GNU patch did. GNU patch then applies every diff the
# exercise wrote. Large inputs are timed beside GNU diff, the panics are
# checked for their sentences, and broken copies of the module prove the
# checks can fail.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The corpus and the broken copies are written by python, and a machine
# can answer `python3` with a store stub that prints a refusal instead of
# running, so the interpreter is resolved once and proven to run.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

# GNU's diff and patch, by what they say they are: BSD diff, busybox and
# the Rust rewrites write other hunks and apply by other rules, and are
# not what this checks against.
GNUDIFF=""
if diff --version 2>/dev/null | grep -q "GNU diffutils"; then GNUDIFF=diff; fi
GNUPATCH=""
if patch --version 2>/dev/null | grep -q "GNU patch"; then GNUPATCH=patch; fi

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

# Without the interpreter and GNU's tools there is no oracle, and every
# comparison below would be against an empty directory: that is the
# gate's failure, said here, not the module's.
if [ -z "$PY" ] || [ -z "$GNUDIFF" ] || [ -z "$GNUPATCH" ]; then
  echo "the oracles are missing: python '$PY', GNU diff '$GNUDIFF', GNU patch '$GNUPATCH'"
  exit 1
fi
echo "== the oracles"
echo "  $($GNUDIFF --version | head -1); $($GNUPATCH --version | head -1); Python $("$PY" -c 'import sys; print(sys.version.split()[0])')"

echo
echo "== the corpus, as GNU diff, GNU patch and difflib answer it"
# Four kinds of pair. Unique lines edited - deleted, inserted and replaced
# with lines new to both - have one longest common subsequence, so one
# shortest script and one right diff: GNU's, byte for byte. Code-shaped
# lines from a small vocabulary edited, and lines of a few letters drawn
# apart, have many, and only the count of changed lines is GNU's. Then
# the edges: empty texts, equal texts, a last line without its newline,
# CRLF against LF. A pair's context is 3 mostly, else 0, 1, 2 or 5; a
# fifth of the texts lose their last newline and a tenth are CRLF.
mkdir -p "$WORK/corpus"
if ! "$PY" - "$WORK/corpus" "$GNUDIFF" "$GNUPATCH" <<'PY'
import difflib, os, random, subprocess, sys
out, gnudiff, gnupatch = sys.argv[1], sys.argv[2], sys.argv[3]
r = random.Random(20261017)

def split(s):
    parts = s.split("\n")
    lines = [p + "\n" for p in parts[:-1]]
    if parts[-1]:
        lines.append(parts[-1])
    return lines

def edit(lines, fresh, ops):
    lines = list(lines)
    for k in range(ops):
        at = r.randrange(len(lines) + 1)
        n = 1 + r.randrange(5)
        op = r.randrange(3)
        if op == 0:
            del lines[at:at + n]
        elif op == 1:
            lines[at:at] = [fresh(k, j) for j in range(n)]
        else:
            lines[at:at + n] = [fresh(k, j) for j in range(n)]
    return lines

def finish(lines, crlf, cut):
    s = "".join(l[:-1] + "\r\n" if crlf and l.endswith("\n") else l for l in lines)
    if cut and s.endswith("\n"):
        s = s[:-2] if s.endswith("\r\n") else s[:-1]
    return s

pairs = []
for i in range(70):
    base = [f"line {i}.{j} {r.randrange(10**6)}\n" for j in range(r.randrange(400))]
    other = edit(base, lambda k, j: f"new {i}.{k}.{j}\n", 1 + r.randrange(12))
    crlf = r.random() < 0.1
    pairs.append((f"unique{i:02}", finish(base, crlf, r.random() < 0.2), finish(other, crlf, r.random() < 0.2), True))
vocab = ["{\n", "}\n", "\n", "  return x;\n", "  x += 1;\n", "int f(int x)\n", "// note\n", "end\n", "  if (x) {\n", "  }\n"]
for i in range(45):
    base = [r.choice(vocab) for _ in range(r.randrange(300))]
    other = edit(base, lambda k, j: r.choice(vocab), 1 + r.randrange(15))
    pairs.append((f"code{i:02}", finish(base, False, r.random() < 0.2), finish(other, False, r.random() < 0.2), False))
for i in range(25):
    letters = "abcd"[:2 + r.randrange(3)]
    a = [r.choice(letters) + "\n" for _ in range(r.randrange(200))]
    b = [r.choice(letters) + "\n" for _ in range(r.randrange(200))]
    pairs.append((f"letters{i:02}", "".join(a), "".join(b), False))
edges = [("", ""), ("", "a\n"), ("a\n", ""), ("a", "a\n"), ("a\n", "a"), ("a\nb\n", "a\nb\n"),
         ("a\r\nb\r\n", "a\nb\n"), ("x\ny", "x\nz"), ("p\nq", "p\nq\nr"), ("\n\n\n", "\n\n"),
         ("only\n", "other\n"), ("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\n2\n3\n4\n5\n6\n7\n8\n9")]
for i, (a, b) in enumerate(edges):
    pairs.append((f"edge{i:02}", a, b, True))

index = []
for name, a, b, unique in pairs:
    p = os.path.join(out, name)
    context = r.choice([3, 3, 3, 3, 0, 1, 2, 5])
    for ext, text in (("a", a), ("b", b)):
        with open(p + "." + ext, "w", newline="") as f:
            f.write(text)
    g = subprocess.run([gnudiff, f"-U{context}", "--label", "a", "--label", "b", p + ".a", p + ".b"], capture_output=True)
    assert g.returncode in (0, 1), g.stderr
    with open(p + ".gnu", "wb") as f:
        f.write(g.stdout)
    m = subprocess.run([gnudiff, "--minimal", p + ".a", p + ".b"], capture_output=True)
    changed = sum(1 for l in m.stdout.split(b"\n") if l.startswith(b"< ") or l.startswith(b"> "))
    with open(p + ".minimal", "w") as f:
        f.write(f"{changed}\n")
    # difflib leaves a line with no newline as it is, and the next line
    # runs on from it; the marker after it is what GNU diff writes there.
    d = difflib.unified_diff(split(a), split(b), "a", "b", n=context)
    with open(p + ".py", "w", newline="") as f:
        f.write("".join(l if l.endswith("\n") else l + "\n\\ No newline at end of file\n" for l in d))
    # The old text with lines on top, and with a line spoilt, as GNU patch
    # with no fuzz takes GNU's diff to them: `.out` if it applied.
    old = split(a)
    if old and a != b:
        variants = {"shift": [f"on top {k}\n" for k in range(1 + r.randrange(4))] + old}
        spoilt = list(old)
        spoilt[r.randrange(len(spoilt))] = "spoilt\n"
        variants["spoil"] = spoilt
        for kind, lines in variants.items():
            q = p + "." + kind
            with open(q, "w", newline="") as f:
                f.write("".join(lines))
            done = subprocess.run([gnupatch, "-F0", "-f", "-s", "--no-backup-if-mismatch", "-r", q + ".rej", "-o", q + ".out", q],
                                  stdin=open(p + ".gnu", "rb"), capture_output=True)
            if done.returncode != 0 and os.path.exists(q + ".out"):
                os.remove(q + ".out")
            if os.path.exists(q + ".rej"):
                os.remove(q + ".rej")
    index.append(f"{name} {context} {'unique' if unique else 'many'}")
with open(os.path.join(out, "index.txt"), "w") as f:
    f.write("\n".join(index) + "\n")
applied = sum(1 for n in os.listdir(out) if n.endswith(".out"))
tried = sum(1 for n in os.listdir(out) if n.endswith(".shift") or n.endswith(".spoil"))
print(f"  {len(pairs)} pairs written; GNU patch -F0 applied {applied} of {tried} moved or spoilt texts")
PY
then
  echo "  the corpus could not be written"
  exit 1
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_diff_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" "$WORK/corpus" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo
echo "== the std/diff exercise, plain build"
build_and_run "plain" diff-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/diff-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every diff section reported"
for phrase in "== edit scripts" "== shortest, against the longest common subsequence" \
              "== the bound on the search" "== lines" "== unified, as GNU diff writes it" \
              "== Python's difflib" "== a patch read" "== applying at an offset" \
              "== no newline at end of file" "== CRLF" "== round trips" "== refused as a value" \
              "== against GNU diff and GNU patch"; do
  if ! grep -qF "$phrase" "$WORK/diff-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== what the exercise wrote, applied by GNU patch"
# Every unified diff the exercise wrote for the corpus, given to GNU patch
# with no fuzz: the old text must come out as the new one, byte for byte.
applied=0
for a in "$WORK"/corpus/*.a; do
  base="${a%.a}"
  name="$(basename "$base")"
  if [ ! -f "$base.iyi" ]; then
    echo "  $name: the exercise wrote no diff"
    status=1
    continue
  fi
  if [ ! -s "$base.iyi" ]; then
    cmp -s "$base.a" "$base.b" || { echo "  $name: an empty diff for texts that differ"; status=1; }
    continue
  fi
  if ! "$GNUPATCH" -F0 -f -s --no-backup-if-mismatch -r "$WORK/rej" -o "$WORK/patched.txt" "$base.a" < "$base.iyi" > "$WORK/patch.log" 2>&1; then
    echo "  $name: GNU patch refused the exercise's diff: $(head -1 "$WORK/patch.log")"
    status=1
  elif ! cmp -s "$WORK/patched.txt" "$base.b"; then
    echo "  $name: GNU patch made something else of the exercise's diff"
    status=1
  else
    applied=$((applied + 1))
  fi
  rm -f "$WORK/rej" "$WORK/patched.txt"
done
echo "  GNU patch -F0 applied $applied of the exercise's diffs, each to the new text exactly"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" diff-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/diff-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
elif ! cmp -s "$WORK/diff-plain.out" "$WORK/diff-release.out"; then
  echo "  release answers differently from plain"
  status=1
else
  echo "  the same lines as the plain build"
fi

echo
echo "== large inputs, timed beside GNU diff"
# 100,000 lines against 100,000 others, the same with a thousand edits,
# and three letters at random (about 57,000 changes, past the search's
# bound); and 200,000 integers against 200,000 others through the generic
# `Diff.edits`, which sets nothing aside and leans on the bound alone.
# Each `--release`, its time and the bytes it allocated (the collector off
# for the count) printed; the diffs must apply with GNU patch, and the
# bounds asserted are loose against a loaded machine - what they catch is
# the quadratic search, which takes minutes here.
mkdir -p "$WORK/large"
"$PY" - "$WORK/large" <<'PY'
import random, sys
d, r = sys.argv[1], random.Random(7)
N = 100000
def put(name, lines):
    with open(f"{d}/{name}", "w") as f:
        f.write("".join(lines))
put("apart.a", [f"a line {i}\n" for i in range(N)])
put("apart.b", [f"b line {i}\n" for i in range(N)])
base = [f"line {i} {r.random()}\n" for i in range(N)]
b = list(base)
for k in range(1000):
    i = r.randrange(len(b))
    op = r.randrange(3)
    if op == 0:
        del b[i]
    elif op == 1:
        b.insert(i, f"new {k}\n")
    else:
        b[i] = f"changed {k}\n"
put("sparse.a", base)
put("sparse.b", b)
put("letters.a", [r.choice("xyz") + "\n" for _ in range(N)])
put("letters.b", [r.choice("xyz") + "\n" for _ in range(N)])
put("letters20k.a", [r.choice("xyz") + "\n" for _ in range(20000)])
put("letters20k.b", [r.choice("xyz") + "\n" for _ in range(20000)])
PY
cat > "$WORK/large/timed.iyi" <<'IYI'
module main

import std/diff::{Diff, Edit}
import std/file::{File}
import std/gc::{GC}

def changed(edits : Array(Edit)) : Int32
  n = 0
  edits.each { |e| n = n + e.count unless e.keep? }
  n
end

if Program.args[0] == "generic"
  n = 200000
  a = Array(Int32).new(n) { |i| i }
  b = Array(Int32).new(n) { |i| n + i }
  GC.collect
  GC.disable
  before = GC.stats.bytes_since_collection
  t0 = __iyi_monotonic_ns
  e = Diff.edits(a, b)
  ms = (__iyi_monotonic_ns - t0) // 1000000
  alloc = GC.stats.bytes_since_collection - before
  GC.enable
  puts "#{changed(e)} #{ms} #{alloc // 1024}"
else
  a = File.read(Program.args[0])
  b = File.read(Program.args[1])
  minimal = Program.args.size > 3
  GC.collect
  GC.disable
  before = GC.stats.bytes_since_collection
  t0 = __iyi_monotonic_ns
  e = Diff.lines(a, b, minimal)
  ms = (__iyi_monotonic_ns - t0) // 1000000
  alloc = GC.stats.bytes_since_collection - before
  GC.enable
  File.write(Program.args[2], Diff.unified(a, b, "a", "b", 3, minimal))
  puts "#{changed(e)} #{ms} #{alloc // 1024}"
end
IYI
gnu_ms() { # gnu_ms <args...>: GNU diff's wall time in milliseconds
  "$PY" -c 'import subprocess, sys, time
t = time.perf_counter(); subprocess.run(sys.argv[1:], stdout=subprocess.DEVNULL); print(int((time.perf_counter() - t) * 1000))' "$@"
}
timed() { # timed <label> <case> <bound ms> [minimal]
  local label="$1" case="$2" bound="$3" minimal="${4:-}"
  local line
  if [ "$case" = generic ]; then
    line="$(timeout 120 "$WORK/timed" generic)"
  else
    line="$(timeout 120 "$WORK/timed" "$WORK/large/$case.a" "$WORK/large/$case.b" "$WORK/large/$case.iyi" $minimal)"
  fi
  if [ -z "$line" ]; then
    echo "  $label: did not finish within 120 s"
    status=1
    return 1
  fi
  set -- $line
  local changed="$1" ms="$2" kib="$3"
  local said="  $label: $changed changed in $ms ms, $((kib / 1024)) MiB allocated"
  if [ "$case" != generic ]; then
    local gflag="" gms gchanged
    [ -n "$minimal" ] && gflag="--minimal"
    gms="$(gnu_ms "$GNUDIFF" $gflag "$WORK/large/$case.a" "$WORK/large/$case.b")"
    gchanged="$("$GNUDIFF" $gflag "$WORK/large/$case.a" "$WORK/large/$case.b" | grep -c '^[<>] ')"
    said="$said; GNU diff${gflag:+ $gflag}: $gchanged changed in $gms ms"
    if [ -n "$minimal" ] && [ "$changed" -ne "$gchanged" ]; then
      echo "$said"; echo "  $label: not as short as diff --minimal"; status=1; return 1
    fi
    if ! "$GNUPATCH" -F0 -f -s --no-backup-if-mismatch -r "$WORK/rej" -o "$WORK/large/out" "$WORK/large/$case.a" < "$WORK/large/$case.iyi" > /dev/null 2>&1 ||
       ! cmp -s "$WORK/large/out" "$WORK/large/$case.b"; then
      echo "$said"; echo "  $label: GNU patch did not make the new text of the diff"; status=1; return 1
    fi
    rm -f "$WORK/rej" "$WORK/large/out"
  fi
  echo "$said"
  if [ "$ms" -gt "$bound" ]; then
    echo "  $label: past its bound of $bound ms"
    status=1
    return 1
  fi
  if [ "$kib" -gt 65536 ]; then
    echo "  $label: allocated past 64 MiB"
    status=1
    return 1
  fi
  return 0
}
if ! "$IYI" build --release -o "$WORK/timed" "$WORK/large/timed.iyi" > "$WORK/timed.log" 2>&1; then
  echo "  the timing program did not build"; sed -n '1,8p' "$WORK/timed.log"; status=1
else
  timed "100,000 lines against 100,000 others" apart 3000
  timed "100,000 lines, a thousand edits" sparse 3000
  timed "100,000 lines of three letters" letters 30000
  timed "20,000 lines of three letters, minimal" letters20k 30000 minimal
  timed "200,000 integers against 200,000 others, Diff.edits" generic 15000
fi

echo
echo "== what the module refuses, by name"
# A malformed patch, or one that does not match, is a PatchError value,
# checked by the exercise; what panics is the caller's own mistake, and an
# error the caller chose to panic on (`or_panic`) panics with its sentence.
refuses() { # refuses <label> <name> <phrase> <statements>
  local label="$1" name="$2" phrase="$3" statements="$4"
  printf 'module main\n\nimport std/diff::{Diff, Patch, PatchError}\n\n%s\nputs "ANSWERED"\n' \
    "$statements" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,8p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ] || grep -q ANSWERED "$WORK/$name.out"; then
    echo "  $label: it answered instead of refusing"
    status=1
    return
  fi
  if ! grep -qxF "iyi: panic: $phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase' (exit $code)"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$phrase"
}
refuses "a negative context" negative_context "Diff.unified: context is -1; it is 0 or more" \
  'Diff.unified("a\n", "b\n", "a", "b", -1)'
refuses "a negative context to format_unified" negative_format "Diff.format_unified: context is -2; it is 0 or more" \
  'Diff.format_unified(["a\n"], ["b\n"], Diff.lines("a\n", "b\n"), "a", "b", -2)'
refuses "a name with a line end" newline_name 'Diff.unified: the name "x\ny" holds a line end, which would end the header line' \
  'Diff.unified("a\n", "b\n", "x\ny", "b")'
refuses "not a patch, or_panic" not_patch 'patch: no unified diff in the text: no "--- " line followed by a "+++ " line' \
  'Patch.parse("hello\n").or_panic'
refuses "a hunk that does not match, or_panic" no_match "patch: hunk #1 (@@ -1 +1 @@) does not match the text at line 1 or at any offset from it" \
  'Patch.parse("--- a\n+++ b\n@@ -1 +1 @@\n-a\n+b\n").or_panic.apply("c\n").or_panic'

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new>: the exercise must fail on a
# copy of the module with <old> replaced, at the check that names <phrase>.
mutations=0
prove_broken() {
  mutations=$((mutations + 1))
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/diff.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing: " + os.environ["OLD"])
Path("$WORK/patched/std/diff.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  # Build first, then run: a patch that does not compile would also "fail",
  # and that proves nothing about whether the exercise catches the break.
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mut-$mutations.bin" "$REPO/bench/std_diff_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the $1 copy did not compile"
    sed -n '1,6p' "$WORK/mut.out"
    status=1
  elif "$WORK/mut-$mutations.bin" "$WORK/corpus" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $1"
    status=1
  elif grep -qF "$2" "$WORK/mut.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not where it should have:"
    { grep -m2 -E 'panic|ASSERTION' "$WORK/mut.out" || tail -2 "$WORK/mut.out"; } | sed 's/^/    /'
    status=1
  fi
  rm -f "$WORK/mut-$mutations.bin"
}
prove_broken "a line with one partner set aside" "Diff.line_edits is shortest" \
  'if in_b[a_ids[i]] == 0' 'if in_b[a_ids[i]] <= 1'
prove_broken "the search's bound reached at once" "Diff.edits is shortest" \
  'if !minimal && c >= @too_expensive' 'if !minimal && c >= 2'
prove_broken "insertions written before deletions" "a change and an append" \
  '      if i < n && a_gone[i]
' '      if i < n && a_gone[i] && !(j < m && b_gone[j])
'
prove_broken "a count of 1 written out" "unified: byte for byte as GNU diff wrote" \
  '    return "#{lo + 1}" if count == 1
' ''
prove_broken "an empty range named by the line after it" "unified: byte for byte as GNU diff wrote an insertion with no context" \
  'return "#{lo},0" if count == 0' 'return "#{lo + 1},0" if count == 0'
prove_broken "no marker after a line without its newline" "unified: byte for byte as GNU diff wrote no newline at the end of the old text" \
  'io << "\n\\ No newline at end of file\n" unless' 'io << "\n" unless'
prove_broken "changes 2 * context apart given two hunks" "unified: byte for byte as GNU diff wrote changes six lines apart share a hunk" \
  '.a_end <= 2 * context' '.a_end < 2 * context'
prove_broken "the marker not read on the old side" "Patch applies GNU diff's no newline at the end of the old text" \
  'old_lines[old_lines.size - 1] = chomp_nl(old_lines.last)' 'old_lines[old_lines.size - 1] = old_lines.last'
prove_broken "no search past the hunk's own line" "a hunk found two lines down" \
  'while guess + offset <= max_where || guess - offset >= floor' 'while offset == 0'
prove_broken "the start of the file not held" "a hunk held at the start of the file is refused a line down" \
  'if h.leading < h.trailing && h.old_index == 0
      return' 'if false
      return'
prove_broken "the end of the file not held" "a hunk held at the end of the file is refused a line up" \
  'if h.trailing < h.leading
      return' 'if false
      return'
prove_broken "a hunk's first line alone compared" "a hunk held at the end of the file is refused a line up" \
  'return false unless lines[at + i] == pat[i]' 'return false unless lines[at + i] == pat[i] || i > 0'
prove_broken "a hunk looked for inside the one before" "a hunk is not looked for inside the hunk before it" \
  'where = Patch.locate(lines, h, guess, at)' 'where = Patch.locate(lines, h, guess, 0)'
prove_broken "more lines than the header counts" "refused: more lines than counted" \
  'if (side_old && old_lines.size == old_count) || (side_new && new_lines.size == new_count)' 'if false'

# The bound on the search is a matter of time, which the exercise does not
# measure: the timing program is built on a copy without it, and the
# 200,000 integers must miss their 15 s (they take minutes).
mutations=$((mutations + 1))
rm -rf "$WORK/patched"
mkdir -p "$WORK/patched/std"
"$PY" - "$REPO/src/std/diff.iyi" "$WORK/patched/std/diff.iyi" <<'PY'
import sys
src = open(sys.argv[1]).read()
old = "if !minimal && c >= @too_expensive"
if old not in src:
    raise SystemExit("patch site missing: " + old)
open(sys.argv[2], "w").write(src.replace(old, "if false && c >= @too_expensive", 1))
PY
if IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build --release -o "$WORK/timed-unbound" "$WORK/large/timed.iyi" > "$WORK/mut.out" 2>&1; then
  started=$(date +%s)
  if timeout 15 "$WORK/timed-unbound" generic > "$WORK/mut.out" 2>&1; then
    echo "  the search without its bound finished the 200,000 integers in time: $(cat "$WORK/mut.out")"
    status=1
  else
    echo "  the search without its bound is caught: 200,000 integers not done in $(( $(date +%s) - started )) s"
  fi
else
  echo "  the unbounded copy did not compile"; sed -n '1,6p' "$WORK/mut.out"; status=1
fi
echo "  $mutations broken copies tried"

echo
if [ "$status" -eq 0 ]; then
  echo "std/diff: all checks passed"
else
  echo "std/diff: exercise failed"
fi
exit $status
