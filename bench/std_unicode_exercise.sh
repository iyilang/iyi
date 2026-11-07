#!/usr/bin/env bash
# Exercises `std/unicode`: Unicode general categories, case mapping and
# UTF-8 validity.
#
#     bash bench/std_unicode_exercise.sh
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

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_unicode_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/unicode exercise, plain build"
build_and_run "plain" unicode-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/unicode-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every unicode section reported"
for phrase in "== letter" "== valid" "== case" "== categories, scripts and case orbits" "== grapheme clusters"; do
  if ! grep -q "$phrase" "$WORK/unicode-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" unicode-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/unicode-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

# Every case of Unicode's own GraphemeBreakTest.txt, which the repository
# carries as the other library's generated spec (the GB9c cases it leaves
# pending included): each string is segmented by the plain and the
# optimised build, and every cluster compared with the file's.
echo
echo "== grapheme clusters against GraphemeBreakTest.txt"
if [ -z "$PY" ]; then
  echo "  no python on this machine, so the grapheme oracle is unmeasured"
else
  cat >"$WORK/graphemes.py" <<'PY'
import re, subprocess, sys

spec, programs = sys.argv[1], sys.argv[2:]


def decode(literal):
    """A literal's code points, from the escapes the spec writes."""
    points, i = [], 0
    while i < len(literal):
        c = literal[i]
        if c != "\\":
            points.append(ord(c))
            i += 1
            continue
        e = literal[i + 1]
        if e == "u" and literal[i + 2] == "{":
            end = literal.index("}", i)
            points.append(int(literal[i + 3:end], 16))
            i = end + 1
        elif e == "u":
            points.append(int(literal[i + 2:i + 6], 16))
            i += 6
        else:
            points.append({"r": 13, "n": 10, "0": 0, "t": 9, "\\": 92, '"': 34, "'": 39}[e])
            i += 2
    return points


cases = []
for line in open(spec, encoding="utf-8"):
    found = re.search(r'it_iterates_graphemes "((?:[^"\\]|\\.)*)", \[(.*?)\]\s*}?\s*#', line)
    if not found:
        continue
    clusters = [decode(t[1]) for t in re.findall(r"""(["'])((?:(?!\1)[^\\]|\\.)*)\1""", found.group(2))]
    text = decode(found.group(1))
    if sum(clusters, []) != text:
        sys.exit("a case whose clusters are not its text: " + line[:80])
    cases.append((text, clusters))
if len(cases) < 700:
    sys.exit(f"only {len(cases)} cases read from {spec}")
feed = "".join(" ".join(map(str, text)) + "\n" for text, _ in cases)
status = 0
for program in programs:
    out = subprocess.run([program, "graphemes"], input=feed, capture_output=True, text=True).stdout.splitlines()
    wrong = []
    for (text, clusters), said in zip(cases, out + [""] * len(cases)):
        want = "|".join(" ".join(map(str, c)) for c in clusters)
        if said != want:
            wrong.append(f"{' '.join('%04X' % p for p in text)}: wrote {said!r}, the file says {want!r}")
    if wrong:
        status = 1
        print(f"  {program.rsplit('/', 1)[-1]}: {len(wrong)} of {len(cases)} cases split otherwise:")
        for w in wrong[:6]:
            print("    " + w)
    else:
        print(f"  {program.rsplit('/', 1)[-1]}: all {len(cases)} cases split as the file splits them")
sys.exit(status)
PY
  "$PY" "$WORK/graphemes.py" "$REPO/spec/std/string/grapheme_break_spec.cr" "$WORK/unicode-plain" "$WORK/unicode-release" || status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
# mutate <label> <old> <new>: patches a copy of std/unicode.iyi and expects
# the exercise to fail against it.
mutate() {
  local label="$1" old="$2" new="$3"
  local dir="$WORK/patched-${label// /-}"
  if [ -z "$PY" ]; then
    echo "  $label: skipped, no working python3 to make the broken copy with"
    return 0
  fi
  mkdir -p "$dir/std"
  if ! OLD="$old" NEW="$new" DST="$dir/std/unicode.iyi" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/unicode.iyi").read_text()
old = os.environ["OLD"]
if old not in src:
    raise SystemExit("patch site missing: " + old)
Path(os.environ["DST"]).write_text(src.replace(old, os.environ["NEW"], 1))
PY
  then
    echo "  $label: the patch did not apply"
    status=1
  elif IYI_PATH="$dir${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_unicode_exercise.iyi" >"$dir/out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  else
    printf '  %s: caught at "%s"\n' "$label" \
      "$(grep -m1 'ASSERTION FAILED' "$dir/out" | sed 's/^.*ASSERTION FAILED: //')"
  fi
}

mutate "letter category" 'in_category?(letter_table, char.ord)' 'false'
# The ASCII fast path answering before the Turkic option is consulted
mutate "turkic ignored on ascii" \
  'return text.upcase if !options.turkic? && ascii_only?(text)' \
  'return text.upcase if ascii_only?(text)'
mutate "turkic downcase ignored on ascii" \
  'return text.downcase if !options.turkic? && ascii_only?(text)' \
  'return text.downcase if ascii_only?(text)'
# The titlecase digraphs with no uppercase again
mutate "digraph upcase missing" \
  'return cp - 1 if cp == 0x1C5 || cp == 0x1C8 || cp == 0x1CB || cp == 0x1F2' \
  ''
mutate "final sigma judged without the letters before it" \
  'if cp == 0x3A3 && !options.ascii? && !options.fold? && final_sigma?(source, index)' \
  'if cp == 0x3A3 && !options.ascii? && !options.fold? && final_sigma?(source, index) && index > from'
mutate "a category read from the wrong column" \
  'at < 0 ? "Cn" : category_names[table.to_unsafe[at + 2]]' \
  'at < 0 ? "Cn" : category_names[table.to_unsafe[at + 1] % 29]'
mutate "an orbit without CaseFolding's S rows" \
  '      join_orbit(map, data[row + 1], data[row])
      row = row + 2' \
  '      row = row + 2'
# The grapheme rules, each taken out of a copy that compiles.
mutate "a conjunct broken at its consonant (GB9c)" \
  '    return false if linked && after >> 5 == INCB_CONSONANT' ''
mutate "an emoji sequence broken at its ZWJ (GB11)" \
  '    return false if joined && after & PICTOGRAPHIC != 0' ''
mutate "regional indicators paired from the wrong one" \
  'indicators % 2 == 1' 'indicators % 2 == 0'
mutate "CR and LF apart" \
  '    return false if left == GCB_CR && right == GCB_LF' ''

echo
if [ "$status" -eq 0 ]; then
  echo "the std/unicode exercise holds"
else
  echo "the std/unicode exercise did not hold"
fi
exit $status
