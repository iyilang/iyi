#!/usr/bin/env bash
# Exercises `std/string_scanner`.
#
#     bash bench/std_string_scanner_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# the patches and oracles below are written in python, and windows answers
# `python3` with a store stub that prints and exits rather than running it, so
# the interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from `pwd` is `/c/...` and finds no prelude at all, and a
# scratch directory named `/tmp/tmp.X` is silently ignored on that path, so
# the patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
EXERCISE="$REPO/bench/std_string_scanner_exercise.iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$EXERCISE" >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  # The refusals the exercise provokes on purpose are printed by the
  # tasks that panic; only what the exercise itself says is shown.
  "$WORK/$name" >"$WORK/$name.out" 2>"$WORK/$name.err"
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    tail -4 "$WORK/$name.err" | sed 's/^/  /'
    status=1
    return 1
  fi
  return 0
}

echo "== the std/string_scanner exercise, plain build"
build_and_run "plain" scanner-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/scanner-plain.out" 2>/dev/null; then
  echo "plain: ALL CHECKS PASSED missing"
  status=1
fi

echo
echo "== every string_scanner section reported"
for phrase in "== the other library's scan, scan_until, skip and skip_until" "== check, check_until, matches? and matched?" \
  "== groups of the last match" "== offset, rest, peek, reset, terminate" "== bytes and characters" "== inspect" "== a tokenizer"; do
  if ! grep -qF "$phrase" "$WORK/scanner-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" scanner-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/scanner-release.out" 2>/dev/null; then
  echo "release: ALL CHECKS PASSED missing"
  status=1
else
  echo "  ALL CHECKS PASSED"
fi

echo
echo "== what the scanner refuses, by its sentence"
# Each is a program's mistake, not its input's, and ends the program with
# the sentence that says which; `[]?` is the form that answers nil.
# refuses <label> <statement> <sentence>
refuses() {
  cat >"$WORK/refuse.iyi" <<IYI
module refuse

import std/regex::{Regex}
import std/string_scanner::{StringScanner}

s = StringScanner.new("Fri Dec 12")
s.scan(/(?<wday>\\w+) (\\w+)/)
$2
puts "accepted"
IYI
  if "$IYI" run "$WORK/refuse.iyi" >"$WORK/refuse.out" 2>&1; then
    echo "  $1 was accepted"
    status=1
  elif ! grep -qxF "iyi: panic: $3" "$WORK/refuse.out"; then
    echo "  $1 was refused without the sentence: $(tr -d '\r' <"$WORK/refuse.out" | head -1)"
    status=1
  else
    echo "  $1: $3"
  fi
}
refuses "an offset past the end" 's.offset = 11' "string_scanner: offset 11 is past the end of a string of 10 bytes"
refuses "a negative offset" 's.offset = -1' "string_scanner: offset -1 is negative"
refuses "an offset inside a character" 'StringScanner.new("中").offset = 2' "string_scanner: offset 2 is inside a character"
refuses "a group that is not there" 'puts s[3]' "string_scanner: the last match has no group 3 (it has 2)"
refuses "a name that is not there" 'puts s["day"]' "string_scanner: the last match has no group named 'day'"
refuses "a group of no match" 's.scan("x")
puts s[0]' "string_scanner: the last scan matched nothing, so it has no group 0"
refuses "a negative count" 's.peek(-3)' "string_scanner: negative lookahead count: -3"
if grep -nE '^\s*(lib|fun) |File\.|Dir\.|ENV' "$REPO/src/std/string_scanner.iyi"; then
  echo "  the module reaches outside itself"
  status=1
else
  echo "  no file, environment or C binding in the module"
fi

echo
echo "== anchored matching against Python's re"
# Python's `pattern.match(text, pos)` is the same question `match_at`
# answers: a match beginning at pos, the text before it still the text, so
# `^` is its start and `\b` sees the character before pos. Every pattern
# below at every character of 400 texts drawn from a small alphabet, the
# positions converted to bytes; `re.ASCII` because RE2's `\w`, `\s` and `\b`
# are ASCII.
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the comparison is unmeasured"
elif ! "$PY" - "$WORK/cases.txt" "$WORK/expected.txt" <<'PY'
import random, re, sys
rng = random.Random(20261014)
patterns = ["a+", "a*b", "(a|ab)(c|bcd)?", "[^ ]+", r"\bab", r"\Bb", "a??b", "(?:é|a)+",
            "^a", "b$", "a{2,3}", ".", "", "é.", "(?i)A+", "x*", "[a-c]+?b", "ab|a",
            r"\w+", r"\s*", "中+|[ab]", "(?:a|b)*c", "[^a]"]
alphabet = "ab é-c中 "
cases, expected = [], []
for _ in range(400):
    text = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 8)))
    for pattern in patterns:
        compiled = re.compile(pattern, re.ASCII)
        for pos in range(len(text) + 1):
            byte = len(text[:pos].encode())
            cases.append(f"{pattern}\x1f{text}\x1f{byte}")
            m = compiled.match(text, pos)
            expected.append(f"{len(text[:m.start()].encode())} {len(text[:m.end()].encode())}" if m else "-")
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(cases) + "\n")
open(sys.argv[2], "w").write("\n".join(expected) + "\n")
PY
then
  echo "  the cases were not written"
  status=1
elif ! "$WORK/scanner-plain" match_at "$WORK/cases.txt" >"$WORK/got.txt" 2>&1; then
  echo "  the exercise did not answer the cases"
  tail -3 "$WORK/got.txt" | sed 's/^/    /'
  status=1
elif ! "$PY" - "$WORK/cases.txt" "$WORK/expected.txt" "$WORK/got.txt" <<'PY'
import sys
cases = open(sys.argv[1], encoding="utf-8").read().splitlines()
want = open(sys.argv[2]).read().splitlines()
got = open(sys.argv[3]).read().splitlines()
bad = [i for i in range(len(want)) if i >= len(got) or got[i] != want[i]]
for i in bad[:5]:
    print("  " + repr(cases[i].split("\x1f")) + f": ours {got[i] if i < len(got) else None}, python {want[i]}")
print(f"  {len(want)} pattern, text and offset triples, {len(bad)} differences")
sys.exit(1 if bad or len(got) != len(want) else 0)
PY
then
  status=1
fi

echo
echo "== the tokenizer against one written with Python's re"
# The same patterns, read from the exercise, tried in the same order with
# `match(text, pos)`, over 300 programs generated from the language's
# tokens, junk characters and unterminated strings included.
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the comparison is unmeasured"
elif ! "$WORK/scanner-plain" patterns >"$WORK/patterns.txt" 2>&1; then
  echo "  the patterns did not print"
  status=1
elif ! "$PY" - "$WORK/patterns.txt" "$WORK/programs.txt" "$WORK/tokens.expected" <<'PY'
import random, re, sys
rng = random.Random(7)
table = [line.split("\t", 1) for line in open(sys.argv[1], encoding="utf-8").read().splitlines()]
table = [(kind, re.compile(source, re.ASCII)) for kind, source in table]
keywords = {"let", "fn", "if", "else", "print"}
pieces = ["let", "fn", "if", "else", "print", "x", "größe", "名前", "_a1", "foo_bar", "0", "42", "3.25", "1e9",
          "6.02E+23", "7.", '"hi"', '"a \\"q\\" b\\n"', '""', "==", "!=", "<=", ">=", "->", "+", "-", "*", "/",
          "=", "<", ">", "(", ")", "{", "}", ",", ";", " ", "  ", "\t", "\n", "# note\n", "#", "é"]
junk = ["@", "$", "~", '"open', "?", "\\"]
programs = []
for _ in range(300):
    parts = [rng.choice(pieces) for _ in range(rng.randint(0, 30))]
    if rng.random() < 0.2:
        parts.insert(rng.randint(0, len(parts)), rng.choice(junk))
    programs.append("".join(parts))
def tokenize(src):
    out, pos = [], 0
    while pos < len(src):
        kind = None
        for name, pattern in table:
            m = pattern.match(src, pos)
            if m:
                kind = name
                break
        at = len(src[:pos].encode())
        if kind is None:
            # An error is the tokenizer's whole answer, as `tokenize`'s
            # `Array(Token) | LexError` is one or the other.
            return [f"error {'unterminated' if src[pos] == chr(34) else 'unexpected'} {at}"]
        text = m.group(0)
        pos = m.end()
        if kind == "space":
            continue
        if kind == "ident" and text in keywords:
            kind = "keyword"
        out.append(f"{kind} {at} {text.encode().hex()}")
    return out
lines = []
for k, program in enumerate(programs):
    lines.append(f"== program {k}")
    lines.extend(tokenize(program))
# newline="": Windows' text mode wrote each \n of a program as \r\n, and
# the scanner read the bytes it was given, a byte later than Python.
open(sys.argv[2], "w", encoding="utf-8", newline="").write("\x1e".join(programs))
open(sys.argv[3], "w", newline="").write("\n".join(lines) + "\n")
PY
then
  echo "  the programs were not written"
  status=1
elif ! "$WORK/scanner-plain" tokens "$WORK/programs.txt" >"$WORK/tokens.got" 2>&1; then
  echo "  the exercise did not tokenize the programs"
  tail -3 "$WORK/tokens.got" | sed 's/^/    /'
  status=1
elif ! "$PY" - "$WORK/tokens.expected" "$WORK/tokens.got" <<'PY'
import sys
want = open(sys.argv[1]).read().splitlines()
got = open(sys.argv[2]).read().splitlines()
programs = sum(1 for line in want if line.startswith("== program"))
tokens = sum(1 for line in want if not line.startswith("==") and not line.startswith("error"))
errors = sum(1 for line in want if line.startswith("error"))
if want != got:
    for i, (a, b) in enumerate(zip(want, got)):
        if a != b:
            print(f"  line {i}: ours {b!r}, python {a!r}")
            break
    print(f"  {len(got)} lines against {len(want)}")
    sys.exit(1)
print(f"  {programs} programs, {tokens} tokens and {errors} errors, the same as Python's")
PY
then
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new>: the exercise must fail on a
# copy of the module with <old> replaced, at the check that names <phrase>.
prove_broken() {
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/string_scanner.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/string_scanner.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$EXERCISE" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $1"
    status=1
  elif grep -qF -- "$2" "$WORK/mut.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not where it should have:"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
# Matching at the offset is the whole point: a scan that searches ahead
# reads `string` out of `test string` from offset 4.
prove_broken "a scan that searches ahead" "scan does not search ahead" \
  '    data = pattern.match_at(@string, @offset)' '    data = pattern.match(@string, @offset)'
# A string compared by its length alone.
prove_broken "a string pattern that is not compared" "nor for a char" \
  '      return forget if src[i] != want[i]
' ''
# `scan_until` takes everything up to the match's end, not the match.
prove_broken "scan_until answering the match alone" "scan_until a regex" \
  '    return nil unless ahead(pattern)
    @offset = @last_end
    @string[start, @last_end - start]' '    return nil unless ahead(pattern)
    @offset = @last_end
    @string[@last_start, @last_end - @last_start]'
# A count read as bytes: two characters of 文字列 are six bytes.
prove_broken "a count of bytes" "a count is characters" \
  '    return 1 if lead < 0xC2 || lead > 0xF4
    width =' '    return 1
    width ='
# A miss must be the last match: `[]?` after one is nil, not the old match.
prove_broken "a miss that leaves no mark" "and the failure is the last match" \
  '  def []?(n : Int32) : String?
    return nil unless matched?
' '  def []?(n : Int32) : String?
'
prove_broken "an offset past the end accepted" "an offset past the end panics" \
  '    raise "string_scanner: offset #{position} is past the end of a string of #{@string.bytesize} bytes" if position > @string.bytesize
' ''
prove_broken "an offset inside a character accepted" "an offset inside a character panics" \
  '    return true if at <= 0 || at >= @string.bytesize' '    return true'
prove_broken "a group past the last answered as one that took no part" "[] of a group it does not have panics" \
  '      raise "string_scanner: the last match has no group #{n} (it has #{data.size - 1})" if n < -data.size || n >= data.size
' ''
# inspect shows the last five characters at the end, not two and nothing.
prove_broken "inspect's window not held to the string" "inspect at the end" \
  '    first = total - 5 if first > total - 5
' ''

echo
if [ "$status" -eq 0 ]; then
  echo "the std/string_scanner exercise holds"
else
  echo "the std/string_scanner exercise did not hold"
fi
exit $status
