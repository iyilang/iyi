#!/usr/bin/env bash
# Exercises `std/shlex`: shell words split, quoted and joined, against
# Python 3.14's `shlex` and against `/bin/sh` itself.
#
#     bash bench/std_shlex_exercise.sh
#
# Python writes a corpus of tricky texts - every byte with a meaning to
# the reader, blanks of all four kinds and two that are not, UTF-8, and
# texts built of quoted and escaped pieces - with what `shlex.split`
# answers for each, with and without comments; arguments with what
# `shlex.quote` writes; and argument lists with what `shlex.join` writes.
# The exercise must answer every line as Python did, refuse what Python
# refuses for the same reason, and split each of its joins back to the
# arguments. `/bin/sh` (and bash, if there is one) then reads each join
# the exercise wrote as `printf` arguments and must print the arguments.
# The panics are checked for their sentences, and broken copies of the
# module prove the checks can fail.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping: the
# paths it is given are mixed ones.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# Python resolved once and proven to run, with the module it answers for.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import shlex' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
# The module's own tree comes first, then whatever search path the caller
# gave: in the repository that is nothing more, and a tree holding only
# this module finds the prelude through the caller's path.
SEARCH="$REPO/src${PSEP}$REPO/samples/iyi${IYI_PATH:+${PSEP}$IYI_PATH}"
export IYI_PATH="$SEARCH"
export PYTHONIOENCODING=utf-8

if [ -z "$PY" ] || [ ! -x /bin/sh ]; then
  echo "the oracles are missing: python '$PY', /bin/sh"
  exit 1
fi
echo "== the oracles"
echo "  Python $("$PY" -c 'import sys; print(sys.version.split()[0])'); /bin/sh is $(readlink -f /bin/sh 2>/dev/null || echo /bin/sh)"

echo
echo "== the corpus, as Python's shlex answers it"
mkdir -p "$WORK/corpus"
if ! "$PY" - "$WORK/corpus" <<'PY'
import os, random, shlex, sys
out = sys.argv[1]
r = random.Random(20261018)
h = lambda s: s.encode().hex()

# Bytes with a meaning to the reader, blanks, near-blanks, letters, UTF-8.
alphabet = list("ab'\"\\#") + [" ", "\t", "\r", "\n", "\f", "\v", "\0"] + list("$`*~;|&(){}=%@:,./-+_!?[]<>^") + ["é", "中", "😀"]
pieces = ["word", "'single quoted'", "''", '""', '"dq \\" \\\\ \\$ \\n"', "\\ ", "\\'", '\\"', "\\\\",
          "\\\n", " ", "\t", "\n", "# comment", "#", "a#b", "'#'", '"#"', "é", "'it'\"'\"'s'", "$HOME", "\\#"]
texts = []
for _ in range(3000):
    texts.append("".join(r.choice(alphabet) for _ in range(r.randrange(16))))
for _ in range(2000):
    texts.append("".join(r.choice(pieces) for _ in range(r.randrange(8))))
texts += ["", " ", "''", '""', "\\", "'", '"', '"\\', "a\\", "#'", "\\\n", "'\\'", '"\\\\"']
lines = []
for t in texts:
    for comments in (False, True):
        try:
            words = shlex.split(t, comments=comments)
            answer = "\t".join("w" + h(w) for w in words)
        except ValueError as e:
            answer = {"No closing quotation": "!quote", "No escaped character": "!escape"}[str(e)]
        lines.append(("c" if comments else "p") + "\t" + h(t) + ("\t" + answer if answer else ""))
# LF on every platform: Python writes CRLF on Windows otherwise, and the
# exercise read "!quote\r" for "!quote".
with open(os.path.join(out, "split.txt"), "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(lines) + "\n")
refused = sum(1 for l in lines if "\t!" in l)

args = ["".join(r.choice(alphabet) for _ in range(r.randrange(10))) for _ in range(3000)]
args += [chr(c) for c in range(1, 128)] + ["", "-", "a:b", "x=y", "it's", "''"]
with open(os.path.join(out, "quote.txt"), "w", encoding="utf-8", newline="\n") as f:
    f.write("".join(h(a) + "\t" + h(shlex.quote(a)) + "\n" for a in args))

# No NUL in a list /bin/sh is to read: an argument cannot hold one.
shell = [c for c in alphabet if c != "\0"]
lists = []
for _ in range(800):
    lists.append(["".join(r.choice(shell) for _ in range(r.randrange(10))) for _ in range(1 + r.randrange(5))])
lists += [[""], ["", ""], ["a b", "c"], ["'"], ['"'], ["\\"], ["-n", "-e"], ["#", "x#"]]
with open(os.path.join(out, "join.txt"), "w", encoding="utf-8", newline="\n") as f:
    f.write("".join(h(shlex.join(a)) + "".join("\tw" + h(x) for x in a) + "\n" for a in lists))
print(f"  {len(lines)} splits ({refused} refused), {len(args)} quotes, {len(lists)} joins written")
PY
then
  echo "  the corpus could not be written"
  exit 1
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_shlex_exercise.iyi" \
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
echo "== the std/shlex exercise, plain build"
build_and_run "plain" shlex-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/shlex-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every shlex section reported"
for phrase in "== splitting" "== single quotes" "== double quotes" "== backslashes" "== comments" \
              "== refused as a value" "== quoting" "== join and back" "== against python's shlex"; do
  if ! grep -qF "$phrase" "$WORK/shlex-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== what /bin/sh makes of the exercise's joins"
# Each join the exercise wrote is handed to the shell as the arguments of
# `printf '%s\0'`; the shell must print each argument and a NUL after it.
if [ ! -f "$WORK/corpus/mine.txt" ]; then
  echo "  the exercise wrote no joins"
  status=1
elif ! "$PY" - "$WORK/corpus" <<'PY'
import os, shutil, subprocess, sys
out = sys.argv[1]
lists = [[bytes.fromhex(w[1:]) for w in l.rstrip("\n").split("\t")[1:]] for l in open(os.path.join(out, "join.txt"))]
mine = [bytes.fromhex(l.strip()) for l in open(os.path.join(out, "mine.txt"))]
assert len(lists) == len(mine), (len(lists), len(mine))
# Windows has no /bin/sh for Python to start, and its command line, which
# Git's sh would parse back into arguments, is quoting of its own: the
# shell's reading is asked on Linux and darwin.
if os.name == "nt":
    print("  not asked on Windows, which has no /bin/sh")
    sys.exit(0)
shells = ["/bin/sh"] + ([shutil.which("bash")] if shutil.which("bash") else [])
bad = 0
for sh in shells:
    for args, line in zip(lists, mine):
        got = subprocess.run([sh, "-c", b"printf '%s\\0' " + line], capture_output=True).stdout
        want = b"".join(a + b"\0" for a in args)
        if got != want:
            bad += 1
            if bad <= 3:
                print(f"  {sh} read {line!r} as {got.split(b'\0')[:-1]!r}, not {args!r}")
    print(f"  {sh}: {len(mine)} joins read back as their arguments" if not bad else f"  {sh}: disagrees")
sys.exit(1 if bad else 0)
PY
then
  status=1
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" shlex-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/shlex-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
elif ! cmp -s "$WORK/shlex-plain.out" "$WORK/shlex-release.out"; then
  echo "  release answers differently from plain"
  status=1
else
  echo "  the same lines as the plain build"
fi

echo
echo "== std/shlex reaches nothing"
# It imports nothing, and declares no C and calls no runtime hook: a
# program that only splits words reaches no file, process or clock.
if grep -nE '^import ' "$REPO/src/std/shlex.iyi" >/dev/null; then
  echo "  std/shlex imports: $(grep -E '^import ' "$REPO/src/std/shlex.iyi" | tr '\n' ' ')"
  status=1
elif grep -nE '^\s*(lib [A-Z]|fun [a-z_]|asm\(|@\[Link)|__iyi_' "$REPO/src/std/shlex.iyi" >/dev/null; then
  echo "  std/shlex binds the platform"
  status=1
else
  echo "  no imports, no bindings"
fi

echo
echo "== what the module refuses, by name"
refuses() { # refuses <label> <name> <phrase> <statements>
  local label="$1" name="$2" phrase="$3" statements="$4"
  printf 'module main\n\nimport std/shlex::{Shlex, ShlexError}\n\n%s\nputs "ANSWERED"\n' \
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
refuses "an unclosed single quote, or_panic" unclosed_single "shlex: no closing quotation: the ' at byte 4 is never closed" \
  'Shlex.split("cmd '"'"'arg").or_panic'
refuses "an unclosed double quote, or_panic" unclosed_double 'shlex: no closing quotation: the " at byte 2 is never closed' \
  'Shlex.split("a \"b c").or_panic'
refuses "a final backslash, or_panic" final_backslash "shlex: no escaped character: the backslash at byte 3 ends the text" \
  'Shlex.split("ab \\").or_panic'
refuses "a final backslash in double quotes, or_panic" final_backslash_dq "shlex: no escaped character: the backslash at byte 2 ends the text" \
  'Shlex.split("\"a\\", comments: true).or_panic'

echo
echo "== proving the checks can fail when the module is broken"
mutations=0
prove_broken() {
  mutations=$((mutations + 1))
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if ! OLD="$3" NEW="$4" "$PY" - "$REPO/src/std/shlex.iyi" "$WORK/patched/std/shlex.iyi" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing: " + os.environ["OLD"])
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif ! IYI_PATH="$WORK/patched${PSEP}$SEARCH" "$IYI" build -o "$WORK/mut-$mutations.bin" "$REPO/bench/std_shlex_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
prove_broken "a carriage return read as a letter" "space, tab, CR and LF are blanks" \
  ' || c == 13_u8' ''
prove_broken "a form feed read as a blank" "form feed and vertical tab are not blanks" \
  ' || c == 13_u8' ' || c == 13_u8 || c == 12_u8'
prove_broken "empty quoted words dropped" "two empty quotes are two empty words" \
  'words << word.to_s if quoted || !word.empty?' 'words << word.to_s unless word.empty?'
prove_broken "a backslash in double quotes taking any byte" 'inside double quotes a backslash takes only' \
  'word.write_byte(92_u8) unless after == 34_u8 || after == 92_u8' 'word.write_byte(92_u8) if false'
prove_broken "a backslash in double quotes taking \$ as POSIX does" 'inside double quotes a backslash takes only' \
  'unless after == 34_u8 || after == 92_u8' 'unless after == 34_u8 || after == 92_u8 || after == 36_u8'
prove_broken "a backslash outside quotes kept" "quotes and escapes join into one word" \
  '            word.write_byte(raw[i + 1])' '            word.write(raw + i, 2)'
prove_broken "a # inside a word left to it" "a # inside a word ends it with comments" \
  '          if comments && c == 35_u8' '          if false'
prove_broken "a comment run to the end of the text" "comments run to the line feed" \
  'while i < n && raw[i] != 10_u8' 'while i < n'
prove_broken "a final backslash in double quotes called unclosed" 'refused: the sentence for "x \"ab\\"' \
  'return dangling(text, i) if i + 1 >= n
                after' 'return unclosed(text, open) if i + 1 >= n
                after'
prove_broken "an offset past the quote" "refused: the offset for" \
  'is never closed", at)' 'is never closed", at + 1)'
prove_broken "an empty argument written as nothing" 'quote: ""' \
  "return \"''\" if arg.empty?" 'return arg if arg.empty?'
prove_broken "a colon quoted" 'quote: "a:b,c=d@e%f+g/h.i-j_k"' \
  'c <= 58_u8' 'c <= 57_u8'
prove_broken "a backquote left bare" 'quote: "`"' \
  'c == 95_u8' 'c == 95_u8 || c == 96_u8'
prove_broken "a single quote escaped with a backslash inside single quotes" "quote: \"it's\"" \
  "io << \"'\\\"'\\\"'\"" "io << \"\\\\'\""
echo "  $mutations broken copies tried"

echo
echo "== doc, format, other platforms and artifacts"
if "$IYI" doc "$REPO/src/std/shlex.iyi" >"$WORK/doc.txt" 2>&1; then
  echo "  iyi doc reads std/shlex ($(grep -c '^ *def ' "$WORK/doc.txt") methods)"
else
  echo "  iyi doc fails: $(grep -m1 -E 'Error|BUG' "$WORK/doc.txt")"
  status=1
fi
# `iyi fmt`, the formatter of the iyi the gate runs: `bin/crystal` is the
# bootstrap compiler on darwin's runner, which reads no iyi.
if "$IYI" fmt --check "$REPO/src/std/shlex.iyi" "$REPO/bench/std_shlex_exercise.iyi" >"$WORK/format.log" 2>&1; then
  echo "  the module and its exercise are formatted"
else
  echo "  not formatted: $(head -3 "$WORK/format.log")"
  status=1
fi
apart=""
for target in x86_64-linux-gnu aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  if ! "$IYI" build --no-codegen --target "$target" -o "$WORK/cross" "$REPO/bench/std_shlex_exercise.iyi" >"$WORK/cross.log" 2>&1; then
    echo "  $target: $(grep -m1 -E 'Error|BUG' "$WORK/cross.log")"
    apart="$apart $target"
  fi
done
if [ -n "$apart" ]; then
  echo "  FAIL: the exercise does not typecheck for:$apart"
  status=1
else
  echo "  the exercise typechecks for x86_64-linux-gnu, aarch64-darwin, x86_64-windows-msvc, aarch64-linux-gnu, x86_64-linux-musl"
fi
mkdir -p "$WORK/r1/mods"
if (cd "$WORK/r1" && "$IYI" build --emit-iyimod mods -o from-source "$REPO/bench/std_shlex_exercise.iyi" \
      && "$IYI" build --use-iyimod mods -o from-artifact "$REPO/bench/std_shlex_exercise.iyi") >"$WORK/r1/build.log" 2>&1; then
  "$WORK/r1/from-source" "$WORK/corpus" >"$WORK/r1/source.out" 2>&1
  "$WORK/r1/from-artifact" "$WORK/corpus" >"$WORK/r1/artifact.out" 2>&1
  if cmp -s "$WORK/r1/source.out" "$WORK/r1/artifact.out" && grep -q "ALL CHECKS PASSED" "$WORK/r1/artifact.out"; then
    echo "  built from its artifacts, the exercise prints what it prints from source"
  else
    echo "  from its artifacts the exercise prints otherwise:"
    diff "$WORK/r1/source.out" "$WORK/r1/artifact.out" | sed -n '1,6p' | sed 's/^/    /'
    status=1
  fi
else
  echo "  the artifacts did not build: $(grep -m1 -E 'Error|BUG' "$WORK/r1/build.log")"
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/shlex exercise holds"
else
  echo "the std/shlex exercise did not hold"
fi
exit $status
