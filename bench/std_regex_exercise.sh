#!/usr/bin/env bash
# Exercises `std/regex`, with Python's `re` (bytes, ASCII classes) as the
# oracle for what a pattern finds.
#
#     bash bench/std_regex_exercise.sh
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

# The negative proofs are patched by python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

if [ -z "$PY" ]; then
  echo "std/regex: SKIPPED, not a pass: every check compares against oracle cases drawn by python3, none runs here, so no case was measured"
  exit 0
fi

# Every pattern against every subject, the four answers written down for
# the exercise to compare. Python's `$` also matches before a final
# newline, so no subject ends in one; `\z` is spelled `\Z` there.
"$PY" - "$WORK/cases.txt" <<'PY'
import re, sys
patterns = [
    "a", "a+", "a*", "a?", "ab|cd", "a|ab", "ab|a", "(a|b)*c", "x*", "b*", "^", "$", "^$",
    "^a", "a$", r"\bfoo\b", r"\Bo", r"\d+", r"\D+", r"\w+", r"\W+", r"\s+", r"\S+",
    "[a-c]+", "[^a-c]+", r"[\w.]+", r"[\d-]+", r"[^\s]+", "a{2}", "a{2,}", "a{1,3}",
    "a{0,2}b", "(ab){2}", "a*?", "a+?", "a??b", "a{2,3}?", ".", ".+", ".*", "a.c",
    "(?:ab)+", "(a)(b)", "a|b|c", "(a|b)+", r"\.", r"\x41+", r"\n", r"[\n]", "colou?r",
    "[0-9]{3}-[0-9]{4}", r"\w+@\w+\.\w+", r"\bthe\b", r"^\s*$", "(a*)*", "(a|aa)+",
    "a{0}", "", "()", "a|", "[-a]", "[a-]", "[]a]", "[^]a]", r"\\", r"\t",
    r"a\z", r"\Aa", "(a|ab)(c|bcd)", "(a+)(b+)?", "o+?", "(?P<pair>ab)+", "b+$", "^b+",
    "[a-cx-z]+", "(a|b)c|d", "x{2,4}", ".*b", ".*?b", "a\\.b", "[.]", "a[^\n]*",
]
subjects = [
    "", "a", "aa", "ab", "abc", "the dog", "foo bar", "bfoob", "a\nb", "colour color",
    "123-4567 x", "user@host.com", "  ", "aXbXc", "ababab", "A\tB", "a.c abc", "bcd",
    "...", "xxxxxx", "aabbb", "ooo", "ba", "ab\nab", "abcd", "b", "\\",
]
out = open(sys.argv[1], "wb")
for pat in patterns:
    rx = re.compile(pat.replace(r"\z", r"\Z").encode(), re.ASCII)
    for sub in subjects:
        s = sub.encode()
        m = rx.search(s)
        found = m.group(0) if m else b"<nil>"
        scan = [m.group(0) for m in rx.finditer(s)]
        pieces, last = [], 0
        for m in rx.finditer(s):
            pieces.append(s[last:m.start()]); last = m.end()
        pieces.append(s[last:])
        replaced = rx.sub(lambda m: b"<>", s)
        assert rx.groups or re.split(rx, s) == pieces, (pat, sub)
        row = b"\x1e".join([pat.encode(), s, found, b"\x1f".join(scan) if scan else b"<none>",
                            b"\x1f".join(pieces), replaced])
        out.write(row.replace(b"\n", b"\x1d") + b"\n")
PY
[ $? -eq 0 ] || { echo "  the oracle did not run"; status=1; }
echo "cases: $(wc -l < "$WORK/cases.txt")"
build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_regex_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  timeout 300 "$WORK/$name" "$WORK/cases.txt" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/regex exercise, plain build"
build_and_run "plain" regex-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/regex-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every regex section reported"
for phrase in "== match" "== leftmost-first" "== an empty match costs no text" "== the syntax the header lists" "== linear time" "== against Python's re"; do
  if ! grep -q "$phrase" "$WORK/regex-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" regex-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/regex-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what a pattern refuses, by name"
refuses() { # refuses <label> <name> <phrase> <pattern>
  local label="$1" name="$2" phrase="$3" pattern="$4"
  if [ -z "$PY" ]; then
    echo "  $label: skipped, no working python3 to write the probe program with"
    return 0
  fi
  PATTERN="$pattern" "$PY" - "$WORK/$name.iyi" <<'PY'
import os, sys
pat = os.environ["PATTERN"].replace("\\", "\\\\").replace('"', '\\"')
# UTF-8 by name: Windows' default is the ANSI code page, which wrote `[é]`
# as the single byte 0xE9 and made a source file the compiler refuses.
open(sys.argv[1], "w", encoding="utf-8").write('module main\n\nimport std/regex\nusing std/regex::{Regex}\n\nputs Regex.compile("%s").find("a").inspect\n' % pat)
PY
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,8p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing"
    status=1
    return
  fi
  if ! grep -qF "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(grep -m1 -oF "$phrase" "$WORK/$name.out")"
}
refuses "lookahead" look_ahead "regex: lookaround is refused" '(?=a)'
refuses "lookbehind" look_behind "regex: lookaround is refused" '(?<=a)b'
refuses "a backreference" backref "regex: backreferences are refused" '(a)\1'
refuses "a possessive quantifier" possessive "regex: possessive quantifiers are refused" 'a*+'
refuses "an inline flag" inline_flag "regex: inline flags are refused" '(?i)abc'
refuses "an atomic group" atomic "regex: atomic groups are refused" '(?>a)'
refuses "a unicode class" pclass "regex: \\p classes are refused" '\p{L}'
refuses "a count out of order" count_order "regex: repeat range out of order" 'a{2,1}'
refuses "a count past 1000" count_big "regex: repeat count past 1000" 'a{1001}'
refuses "a range out of order" range_order "regex: range out of order" '[z-a]'
refuses "a range starting with a class" range_class "regex: a class cannot start a range" '[\d-z]'
refuses "a class past ASCII" class_utf8 "regex: a class holding a byte past ASCII is refused" '[é]'
refuses "an unknown escape" escape_q "regex: unknown escape '\\q'" '\q'
refuses "a trailing backslash" trailing "regex: trailing '\\'" '\'
refuses "an unmatched (" open_paren "regex: unmatched '('" '('
refuses "an unmatched )" close_paren "regex: unmatched ')'" ')'
refuses "nothing to repeat" repeat_nothing "regex: nothing to repeat" '*a'
refuses "an unterminated class" class_open "regex: unterminated class" '[a'
refuses "\\x without its digits" hex_short "regex: \\x needs two hex digits" '\x4'

echo
echo "== proving the checks can fail when the module is broken"
mutate() { # mutate <label> <old> <new>
  local label="$1" old="$2" new="$3"
  if [ -z "$PY" ]; then
    echo "  $label: skipped, no working python3 to make the broken copy with"
    return 0
  fi
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  OLD="$old" NEW="$new" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/regex.iyi").read_text()
old = os.environ["OLD"]
if old not in src:
    raise SystemExit("patch site missing: " + old)
Path("$WORK/patched/std/regex.iyi").write_text(src.replace(old, os.environ["NEW"], 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" timeout 300 "$IYI" run "$REPO/bench/std_regex_exercise.iyi" "$WORK/cases.txt" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  else
    echo "  $label: caught"
  fi
}
mutate "a match state that never cuts" 'match_end = pos
            break' 'match_end = pos'
mutate "out2 preferred over out1" '      add(nxt, @nfa.out1[s], start, pos)
      add(nxt, @nfa.out2[s], start, pos)' '      add(nxt, @nfa.out2[s], start, pos)
      add(nxt, @nfa.out1[s], start, pos)'
mutate "an empty match that eats a byte" '        pos = a
        forbid = a' '        pos = a + 1
        forbid = -1'
mutate "a word boundary that is never one" 'before != after' 'false'
mutate "matches? that spans the whole text" '!pattern.find(self).nil?' 'pattern.match?(self)'
mutate "a block replacement that is ignored" 'io << yield text[a, b - a]' 'io << text[a, b - a]'
mutate "a run of classes that matches on its first byte alone" '      return false if table[src[i + j].to_i32] == 0_u8' '      return false if table[src[i].to_i32] == 0_u8'
mutate "a table's missing entry kept as the match" '    pattern.replace(self) { |match| table[match]? || "" }' '    pattern.replace(self) { |match| table[match]? || match }'
mutate "an automaton that keeps every bit" '      state = (state.unsafe_shl(1_u64) | heads) & masks[src[i].to_i32]' '      state = state.unsafe_shl(1_u64) | heads'
mutate "a literal compared from its second byte on" '        j = 1
        while j < m && source[i + j] == wanted[j]' '        j = 2
        while j < m && source[i + j] == wanted[j]'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/regex exercise holds"
else
  echo "the std/regex exercise did not hold"
fi
exit $status
