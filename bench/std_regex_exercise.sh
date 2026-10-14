#!/usr/bin/env bash
# Exercises `std/regex`, with Python's `re` as the oracle for what a pattern
# finds: bytes and ASCII classes for the plain patterns, every group's span
# and the flags for the patterns with groups, and characters for the text
# past ASCII.
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

# Patterns with groups, with flags, and over text past ASCII: the span of
# every group of the first match, of every match `scan` finds, and `gsub`
# with a replacement naming each group as `\1` and `\k<name>`, in bytes.
# Python's `re` is a backtracker, but on these patterns its groups are the
# leftmost-first ones RE2 reports; `u` marks a case read without
# `re.ASCII`, whose patterns use no `\w \d \s \b`, which RE2 keeps ASCII.
# A group inside a loop whose body can match empty is not here: after the
# body has taken text, Python runs it once more on nothing, and `(a*)*` on
# `a` has group 1 empty, where Go's RE2-derived engine, which builds that
# loop as `(x+)?` as this one does, answers the `a`; the exercise holds
# that case to the machine's answer by hand.
"$PY" - "$WORK/groups.txt" <<'PY'
import re, sys
cases = [(p, "") for p in [
    "(a)(b)?", "(a|ab)(c|bcd)(d*)", "(a+)(b+)?", "(?:(a)|b)+", "(a)|(b)", "((a)|b)*",
    "(a|b)*c", r"(\w+)@(\w+)\.(\w+)", r"(?P<y>\d{4})-(?P<m>\d\d)", r"(?P<w>\w+) (?P<v>\w+)",
    "x(a?)y", "(a*?)(a*)", "(a+?)(a*)", "((a)(b))", "(.)(.)?", r"^(\s*)(\S+)", r"(\d+)(?:px|em)?",
    "(a)(?:b(c))?d", "(a|)(b|)", "([a-c]+)-([^a-c]+)", "(a|ab)(bc|c)?", r"\b(\w)(\w*)\b", "(x*)(y*)",
    "(a)(a)?(a)?", "((a)|(b))+", "(?i)ab", "a(?i:b)c", "(?i:a)b", "(?s:.)+", r"(?m)^(\w)",
    "(?x) a b", "(?i)a(?-i:b)", "(?i:A|b)+", r"(?s)a(.)b",
]] + [
    ("abc", "i"), ("(A)(b)", "i"), ("[a-c]+", "i"), ("(?P<n>[A-C])x", "i"), ("^(b.)", "m"),
    ("(a.)$", "m"), ("(.+)", "s"), ("^(.+)$", "ms"), ("(.)\n(.)", "m"), ("a b c # c\n", "x"),
    ("(a) (b)? # g\n", "x"), ("[ ]a", "x"), ("(?P<p> b | c )+", "ix"),
    (".", "u"), (".+", "u"), ("[^a]+", "u"), ("([α-ω]+)", "u"), ("(é+)(.)", "u"), ("[一-龥]+", "u"),
    ("a(.)c", "u"), ("σ+", "iu"), ("(straße)", "iu"), ("ß", "iu"), ("(привет) (мир)", "iu"),
    ("k", "iu"), ("[a-z]+", "iu"), ("(.)(.)", "su"), ("^(.)", "mu"), ("(?i)ΣΑΣ", "u"), ("[^α-ω]", "iu"),
]
subjects = {
    False: ["", "a", "ab", "abc", "ABC", "aBc", "abcd", "abbcd", "b", "aab", "user@host.com",
            "2024-06 x", "John Smith", "xy", "xay", "aaa", "a-xyz", "a\nb\nc", "ab\ncd", "  lead",
            "12px 3em 4", "abd acd", " a b", "ba", "xyyx", "AbAB", " b c B"],
    True: ["café", "naïve αβγ", "Ωμέγα", "中文字", "ΣΑΣ σας", "straße STRASSE STRAẞE", "Привет мир",
           "\u212a K k", "aéc", "日本", "a\nβ", "x\U0001F600y", "ſs"],
}

def expand(template, m):
    out, i = [], 0
    while i < len(template):
        if template[i] == "\\" and i + 1 < len(template):
            c = template[i + 1]
            if c == "\\":
                out.append("\\"); i += 2; continue
            if c in "0123456789":
                g = int(c)
                out.append((m.group(g) or "") if g <= m.re.groups else ""); i += 2; continue
            if c == "k" and template[i + 2:i + 3] == "<":
                close = template.index(">", i + 3)
                out.append(m.group(template[i + 3:close]) or ""); i = close + 1; continue
        out.append(template[i]); i += 1
    return "".join(out)

out = open(sys.argv[1], "wb")
for pat, flags in cases:
    wide = "u" in flags
    f = 0 if wide else re.ASCII
    for letter, bit in (("i", re.I), ("m", re.M), ("s", re.S), ("x", re.X)):
        if letter in flags:
            f |= bit
    rx = re.compile(pat, f)
    template = "<\\0" + "".join("|\\%d" % g for g in range(1, min(rx.groups, 9) + 1))
    template += "".join("|\\k<%s>" % name for name in rx.groupindex) + ">"
    for s in subjects[wide]:
        at = lambda i: -1 if i < 0 else len(s[:i].encode())
        m = rx.search(s)
        groups = ";".join("%d,%d" % (at(m.start(g)), at(m.end(g))) for g in range(rx.groups + 1)) if m else "<nil>"
        scan = ";".join("%d,%d" % (at(x.start()), at(x.end())) for x in rx.finditer(s)) or "<none>"
        replaced = rx.sub(lambda x: expand(template, x), s)
        row = "\x1e".join([pat, flags.replace("u", ""), s, groups, scan, template, replaced])
        out.write(row.replace("\n", "\x1d").encode() + b"\n")
PY
[ $? -eq 0 ] || { echo "  the groups oracle did not run"; status=1; }
echo "group cases: $(wc -l < "$WORK/groups.txt")"
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
  timeout 300 "$WORK/$name" "$WORK/cases.txt" "$WORK/groups.txt" >"$WORK/$name.out" 2>&1
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
for phrase in "== match" "== leftmost-first" "== an empty match costs no text" "== the syntax the header lists" "== linear time" "== against Python's re" "== groups and flags against Python's re" "== a regex literal" "== captures" "== flags" "== Unicode" "== escape and union" "== the text side with groups"; do
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
open(sys.argv[1], "w", encoding="utf-8").write('module main\n\nimport std/regex::{Regex}\n\nputs Regex.compile("%s").find("a").inspect\n' % pat)
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
refuses "an unknown inline flag" inline_flag "regex: unknown inline flag 'z'" '(?z)abc'
refuses "a flag group naming no flag" inline_empty "regex: an inline flag group names no flag" '(?)abc'
refuses "an atomic group" atomic "regex: atomic groups are refused" '(?>a)'
refuses "a Unicode class the UCD does not name" pclass "regex: unknown Unicode class 'Klingon'" '\p{Klingon}'
refuses "\\C, one byte" any_byte "regex: \\C is refused" 'a\Cb'
refuses "a group name used twice" name_twice "regex: duplicate group name 'a'" '(?<a>x)(?<a>y)'
refuses "a count out of order" count_order "regex: repeat range out of order" 'a{2,1}'
refuses "a count past 1000" count_big "regex: repeat count past 1000" 'a{1001}'
refuses "a range out of order" range_order "regex: range out of order" '[z-a]'
refuses "a range starting with a class" range_class "regex: a class cannot start a range" '[\d-z]'
refuses "an escaped character past ASCII" escape_utf8 "regex: unknown escape" '\é'
refuses "an unknown escape" escape_q "regex: unknown escape '\\q'" '\q'
refuses "a trailing backslash" trailing "regex: trailing '\\'" '\'
refuses "an unmatched (" open_paren "regex: unmatched '('" '('
refuses "an unmatched )" close_paren "regex: unmatched ')'" ')'
refuses "nothing to repeat" repeat_nothing "regex: nothing to repeat" '*a'
refuses "an unterminated class" class_open "regex: unterminated class" '[a'
refuses "\\x without its digits" hex_short "regex: \\x needs two hex digits" '\x4'
refuses "a count with nothing to repeat" count_nothing "regex: nothing to repeat" '{2}'
refuses "a count after a quantifier" count_twice "regex: nothing to repeat" 'a*{2}'
refuses "an empty group name" name_empty "regex: not a group name" '(?<>a)'
refuses "nested counts past 1000" count_nested "regex: repeat count past 1000" '(a{1000}){2}'

echo
echo "== what a regex literal refuses, at the literal"
literal_refused() { # literal_refused <label> <name> <phrase> <source>
  local label="$1" name="$2" phrase="$3"
  printf '%s\n' "$4" > "$WORK/$name.iyi"
  if "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: it built"
    status=1
  elif ! grep -qF "$phrase" "$WORK/$name.build"; then
    echo "  $label: refused, but not with '$phrase'"
    grep -m1 "Error" "$WORK/$name.build"
    status=1
  else
    echo "  $label: refused"
  fi
}
literal_refused "a literal with no std/regex" literal_unimported "nothing in this program imports it" 'puts /a/.match?("a")'

# A literal's flags are `Regex.compile`'s options, the constant named for the
# flags as well as the text: `/a/` and `/a/i` in one program are two
# constants, and the flagged one travels through an artifact with its flags.
echo
echo "== a regex literal with flags"
mkdir -p "$WORK/flags/app"
cat > "$WORK/flags/app/names.iyi" <<'IYI'
module app/names

import std/regex::{Regex}

pub def greek(text : String) : String?
  /\p{Greek}+|Σ+/i.find(text)
end
IYI
cat > "$WORK/flags/main.iyi" <<'IYI'
module main

import app/names
import std/regex::{Regex}

puts /a/.match?("A")
puts /a/i.match?("A")
puts /a.b/m.match?("a\nb")
puts /^b$/m.find("a\nb") || "nil"
puts /a b # c/x.match?("ab")
puts /k/ix.options
puts App::Names.greek("x σς y") || "nil"
IYI
want='false
true
true
b
true
IGNORE_CASE | EXTENDED
σς'
if (cd "$WORK/flags" && "$IYI" build -o from-source main.iyi) > "$WORK/flags/build.log" 2>&1 &&
   "$WORK/flags/from-source" > "$WORK/flags/source.out" 2>&1 &&
   [ "$(cat "$WORK/flags/source.out")" = "$want" ] &&
   (cd "$WORK/flags" && "$IYI" build --emit-iyimod mods -o emitted main.iyi) > "$WORK/flags/emit.log" 2>&1 &&
   (cd "$WORK/flags" && "$IYI" build --use-iyimod mods -o from-artifact main.iyi) > "$WORK/flags/use.log" 2>&1 &&
   "$WORK/flags/from-artifact" > "$WORK/flags/artifact.out" 2>&1 &&
   cmp -s "$WORK/flags/source.out" "$WORK/flags/artifact.out"; then
  echo "  i, m and x on a literal, two constants for /a/ and /a/i, and from an artifact alike: $(tr '\n' ' ' < "$WORK/flags/artifact.out")"
else
  echo "  FAIL: a literal's flags did not reach Regex.compile:"
  # The error line itself, which sits under the caret, then what ran.
  cat "$WORK/flags/build.log" "$WORK/flags/emit.log" "$WORK/flags/use.log" 2>/dev/null | grep -m3 -E "Error|undefined" | sed 's/^/    /'
  cat "$WORK/flags/source.out" "$WORK/flags/artifact.out" 2>/dev/null | head -8 | sed 's/^/    ran: /'
  status=1
fi

# A module's literal is a constant its artifact names and its consumer
# builds; built with the other library's `Regex.new`, it did not compile.
echo
echo "== a module's regex literal, from its artifact"
mkdir -p "$WORK/lit/app"
cat > "$WORK/lit/app/words.iyi" <<'IYI'
module app/words

import std/regex::{Regex}

pub def digits(text : String) : Array(String)
  /[0-9]+/.scan(text)
end

pub def word(text : String) : String?
  /w[a-z]*/.find(text)
end
IYI
cat > "$WORK/lit/main.iyi" <<'IYI'
module main

import app/words
import std/regex::{Regex}

puts App::Words.digits("a1 b22").inspect
puts App::Words.word("xx word") || "none"
puts /[0-9]+/.find("q9") || "none"
IYI
if (cd "$WORK/lit" && "$IYI" build --emit-iyimod mods -o from-source main.iyi) > "$WORK/lit/emit.log" 2>&1 &&
   (cd "$WORK/lit" && "$IYI" build --use-iyimod mods -o from-artifact main.iyi) > "$WORK/lit/use.log" 2>&1 &&
   "$WORK/lit/from-source" > "$WORK/lit/source.out" 2>&1 &&
   "$WORK/lit/from-artifact" > "$WORK/lit/artifact.out" 2>&1 &&
   cmp -s "$WORK/lit/source.out" "$WORK/lit/artifact.out" &&
   grep -qx "word" "$WORK/lit/artifact.out"; then
  echo "  from source and from its artifact alike: $(tr '\n' ' ' < "$WORK/lit/artifact.out")"
else
  echo "  FAIL: a module's literal did not come through its artifact:"
  cat "$WORK/lit/emit.log" "$WORK/lit/use.log" "$WORK/lit/artifact.out" 2>/dev/null | grep -m3 -E "Error|undefined|^" | sed 's/^/    /'
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
# With <phrase>, the broken exercise must fail there, at the check that
# proves the fix. With <pattern>, the fix is a refusal: the probe `refuses`
# builds, on the broken copy, must answer <pattern> instead.
mutate() { # mutate <label> <old> <new> [<phrase> [<pattern>]]
  local label="$1" old="$2" new="$3" phrase="${4:-}" pattern="${5:-}"
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
  elif [ -n "$pattern" ]; then
    if (export IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi"; refuses "$label" mutated_refusal "$phrase" "$pattern") >"$WORK/mut.out" 2>&1 &&
       grep -q "it answered instead of refusing" "$WORK/mut.out"; then
      echo "  $label: caught, /$pattern/ answered"
    else
      echo "  $label: the broken module still refused /$pattern/"
      sed 's/^/    /' "$WORK/mut.out"
      status=1
    fi
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" timeout 300 "$IYI" run "$REPO/bench/std_regex_exercise.iyi" -- "$WORK/cases.txt" "$WORK/groups.txt" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif [ -n "$phrase" ] && ! grep -qF -- "$phrase" "$WORK/mut.out"; then
    echo "  $label: caught, but not at '$phrase'"
    tail -3 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  else
    echo "  $label: caught"
  fi
}
mutate "a match state that never cuts" '            matched = true
            break' '            matched = true'
# The closure walks its own stack, out2 pushed under out1 so out1's states
# come first; pushed the other way, `a|ab` answers `ab`.
mutate "out2 preferred over out1" '        todo[top] = @nfa.out2[t]
        todo[top + 1] = @nfa.out1[t]' '        todo[top] = @nfa.out1[t]
        todo[top + 1] = @nfa.out2[t]'
mutate "an empty match that eats a byte" '        pos = a
        forbid = a' '        pos = a + 1
        forbid = -1'
mutate "a word boundary that is never one" 'before != after' 'false'
mutate "matches? that spans the whole text" '!pattern.find(self).nil?' 'pattern.match?(self)'
mutate "a block replacement that is ignored" 'io << yield text[a, b - a]' 'io << text[a, b - a]'
mutate "a run of classes that matches on its first byte alone" '      return false if table[src[i + j].to_i32] == 0_u8' '      return false if table[src[i].to_i32] == 0_u8'
mutate "a table's missing entry kept as the match" '    pattern.replace(self) { |match| table[match]? || "" }' '    pattern.replace(self) { |match| table[match]? || match }'
mutate "an automaton that keeps every bit" '      state = (state.unsafe_shl(1_u64) | heads) & masks[src[i].to_i32]' '      state = state.unsafe_shl(1_u64) | heads'
mutate "a literal looked for from one byte past where it may start" '    text.byte_index(literal, from)' '    text.byte_index(literal, from + 1)'
mutate "a pattern that forgets its source" 'runs, pattern, options' 'runs, "", options'
mutate "a fast-path range that reads an escaped end as \\" '              return nil if high == 92_u8 || high < c' '              return nil if high < c' "a range ending in an escape, on the fast path"
mutate "a star around an empty-matching body built as one loop" '    return optional(plus(atom, lazy), lazy) if nullable?(atom)' '' "a star whose body matched empty stops"
mutate "x{n,} as n copies and a star" '    copies = unbounded ? times : hi' '    copies = unbounded ? lo + 1 : hi' "x{1,} is x+"
mutate "\\0 without its octal digits" '      while k < 2 && @i < @n && peek >= 48_u8 && peek <= 55_u8' '      while false' "\\0 takes up to two more octal digits"
mutate "\\_ refused as a letter" '(RxCompiler.word?(b) && b != 95_u8)' '(RxCompiler.word?(b))' "unknown escape '\\_'"
mutate "a count read as text where nothing precedes it" '    elsif b == 123_u8 && count_ahead?' '    elsif false' "regex: nothing to repeat" 'a*{2}'
mutate "an empty group name taken" '        raise "regex: not a group name in /#{@shown}/" if @i < @n && peek == 62_u8 # (?<>' '' "regex: not a group name" '(?<>a)'
mutate "nested counts that do not multiply" 'if @copies * times > 1000' 'if false' "regex: repeat count past 1000" '(a{1000}){2}'
# Groups: a save records the position into the thread it follows, and puts
# the old one back for the branches after it; a count's copies are one
# group, not one each.
mutate "a save that records nothing" '          work[slot] = pos' '          work[slot] = -1'
mutate "a save the closure does not undo" '        work[-t - 2] = undo[top]' '        work[-t - 2] = work[-t - 2]'
mutate "a count whose copies are new groups" '      @groups = groups_at' '' "a counted group is one group"
mutate "a group name used twice taken" 'if name && @names.includes?(name)' 'if false' "regex: duplicate group name" '(?<a>x)(?<a>y)'
mutate "begin counted in bytes" '@string[0, byte_begin(n)].size' 'byte_begin(n)' "begin and end count characters"
mutate "\\1 in a replacement read as the whole match" 'self[(c - 48_u8).to_i32]?' 'self[0]?'
mutate "\\k<name> in a replacement left empty" 'io << (self[name]? || "")' 'io << ""'
# Flags: each one's effect, where it ends, and the order folding and
# negation take in a class.
mutate "a literal that ignores IGNORE_CASE" '    if @fold
      orbit' '    if false
      orbit'
mutate "a class that ignores IGNORE_CASE" '    set.fold if @fold
    set.negate if neg
    single' '    set.negate if neg
    single'
# Caught first by the oracle's `(?i)[^α-ω]`, which then takes `Α`.
mutate "a class negated before it is folded" '    set.fold if @fold
    set.negate if neg
    single' '    set.negate if neg
    set.fold if @fold
    single'
mutate "^ under m only at the start" 'pos == 0 || @src[pos - 1] == 10_u8' 'pos == 0'
mutate "a dot that ignores s" '@dotall ? RxNfa::ANY : RxNfa::ANY_BUT_NEWLINE' 'RxNfa::ANY_BUT_NEWLINE'
mutate "x that skips nothing" '    return unless @extended' '    return'
mutate "a scoped flag that outlives its group" '    @fold = fold
' ''
mutate "an empty negation taken" 'if !any || (negated && !after_minus)' 'if !any' "regex: an inline flag group names no flag" '(?i-)a'
# Characters: the width the machine steps, a class past ASCII, \p and its
# negations, \Q..\E, and the escaping `union` relies on.
mutate "a character stepped as one byte" '    @width = width
    point' '    point'
mutate "a class that holds nothing past ASCII" 'low < ranges.size // 2 && data[2 * low] <= cp' 'false'
mutate "a \\p range cut to its first character" 'set.add(ranges[k], ranges[k + 1])' 'set.add(ranges[k], ranges[k])'
mutate "\\p{^..} not negated" 'negated = property(set) != negated' 'property(set)' "\\p{^Greek}"
mutate "\\Q..\\E taken unescaped" '            io.write_byte(92_u8) if c < 128_u8 && !word?(c)' '' "\\Q..\\E is the text itself"
mutate "an escape that leaves spaces" 'special = " .' 'special = ".' "under EXTENDED too"
mutate "a union that drops a pattern's flags" '    pattern.to_s' '    pattern.source' "union of a pattern keeps its flags to itself"

# Linear time, held to a clock: the pathological pattern built from this
# module runs in a few milliseconds and must finish within 20 seconds. The
# proof that the bound can fail is the machine without its one-thread-a-
# state rule - a state is joined once per step - which is a backtracker's
# cost, 2^n, and does not finish.
echo
echo "== linear time, against a clock"
cat > "$WORK/linear.iyi" <<'IYI'
import std/regex::{Regex}

text = "a" * 30000
puts Regex.compile("(a|a)*b").match(text).nil?
puts Regex.compile("(?:a|a)*b").find(text).nil?
IYI
bounded() { # bounded <label> <search path>: 0 when the probe answers within 20 s
  local label="$1" path="$2"
  if ! IYI_PATH="$path" "$IYI" build -o "$WORK/linear" "$WORK/linear.iyi" > "$WORK/linear.build" 2>&1; then
    echo "  $label: the probe did not build"
    sed -n '1,8p' "$WORK/linear.build"
    return 2
  fi
  local start end
  start=$(date +%s%N)
  timeout 20 "$WORK/linear" > "$WORK/linear.out" 2>&1
  local code=$?
  end=$(date +%s%N)
  LINEAR_MS=$(( (end - start) / 1000000 ))
  [ "$code" -eq 0 ] && [ "$(tr '\n' ' ' < "$WORK/linear.out")" = "true true " ]
}
if bounded "(a|a)*b" "$REPO/src${PSEP}$REPO/samples/iyi"; then
  echo "  (a|a)*b over 30,000 a's, with its group and without: ${LINEAR_MS} ms"
else
  echo "  FAIL: (a|a)*b over 30,000 a's did not answer within 20 s ($(head -c 200 "$WORK/linear.out"))"
  status=1
fi
if [ -n "$PY" ]; then
  rm -rf "$WORK/patched" && mkdir -p "$WORK/patched/std"
  "$PY" - "$REPO/src/std/regex.iyi" "$WORK/patched/std/regex.iyi" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1]).read_text()
old = "      next if t < 0 || @seen[t] == @gen\n"
if old not in src:
    raise SystemExit("patch site missing: " + old)
Path(sys.argv[2]).write_text(src.replace(old, "      next if t < 0\n", 1))
PY
  if [ $? -ne 0 ]; then
    echo "  a state joined more than once a step: the patch did not apply"
    status=1
  elif bounded "a state joined more than once a step" "$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi"; then
    echo "  a state joined more than once a step: the probe still answered in ${LINEAR_MS} ms"
    status=1
  else
    echo "  a state joined more than once a step: caught, no answer within 20 s"
  fi
fi

# A script with no module header imports `Regex` the same way. The compiler
# declares an empty `Regex` of its own before any source is read - the
# other library's regex literals, which iyi refuses - and at a script's top
# level it answered for the imported one: `Regex.compile` was "undefined
# method 'compile' for Regex.class".
echo
echo "== a script without a module header imports Regex"
cat > "$WORK/script.iyi" <<'IYI'
import std/regex::{Regex}

puts Regex.compile("a+").find("xaay") || "none"
IYI
if "$IYI" run "$WORK/script.iyi" > "$WORK/script.out" 2>&1 && grep -qx "aa" "$WORK/script.out"; then
  echo "  the imported Regex answers: $(cat "$WORK/script.out")"
else
  echo "  FAIL: a headerless script's Regex is not the imported one:"
  sed 's/^/    /' "$WORK/script.out" | tail -3
  status=1
fi
# And only there. A headerless script's imports are the program's, and the
# first cut of the rule above handed them to the prelude too: a script that
# imported `std/gc::{GC}` and built a `List` was told `Std::Gc` "is not
# imported here", at a line of std/list.
cat > "$WORK/walled.iyi" <<'IYI'
import std/gc::{GC}
import std/list::{List}

puts List(Int64).new([4_i64, 5_i64]).appended(6_i64).size + GC.stats.collections.to_i32 * 0
IYI
if "$IYI" run "$WORK/walled.iyi" > "$WORK/walled.out" 2>&1 && grep -qx "3" "$WORK/walled.out"; then
  echo "  a script's import stays the script's: $(cat "$WORK/walled.out")"
else
  echo "  FAIL: a script's import reached the prelude:"
  sed 's/^/    /' "$WORK/walled.out" | tail -3
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/regex exercise holds"
else
  echo "the std/regex exercise did not hold"
fi
exit $status
