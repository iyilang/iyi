#!/usr/bin/env bash
# Exercises `std/eiy`: templates compiled into the program.
#
#     bash bench/std_eiy_exercise.sh
#
# Proves:
#   * `Eiy.render`, `Eiy.embed` and `Eiy.def_to_s` of bench/std_eiy_exercise.eiy
#     (output tags, `if`, a block, `<%-`/`-%>` trimming, a comment, an escaped
#     tag, quotes, backslashes, `#{` and UTF-8 text) print the expected text
#     byte for byte, plain and with --release.
#   * `Eiy::Lexer` token types, values, flags and positions; the generated
#     source of `process_string`, exactly; `process_file`, `locate`, and the
#     nil-answering pair.
#   * Negative proofs: a copy of the module with `-%>` trimming broken, with
#     columns counted in bytes, and with `#` left unescaped in template text is
#     caught, each at its named check.
#   * Refusals: a template with an open tag and a template that is not there
#     are refused at build time with their sentences; the runtime API panics
#     with the same sentences.
#   * Dependency floor: the exercise binary adds no symbol and no library.
#
# Needs `make` for bin/iyi, plus `nm`, and `otool` on Darwin or `readelf` on Linux.
# Exits non-zero if any check fails.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/floor_base.sh"

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

# Ensure IYI_PATH can find std modules in src/ and samples/iyi/
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

symbols() {
  nm -u "$1" 2>/dev/null |
    sed -e 's/^ *//' -e 's/^U  *//' -e 's/@.*$//' |
    awk '{ print $NF }' |
    sed -e 's/^_//' |
    grep -v '^$' |
    sort -u
}

libraries() {
  if command -v otool >/dev/null 2>&1; then
    otool -L "$1" 2>/dev/null | sed -n '2,$p' | awk '{ print $1 }' | sed 's|.*/||' | sort -u
  else
    readelf -d "$1" 2>/dev/null |
      sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' |
      sed 's|.*/||' | sort -u
  fi
}

unexpected() {
  local allowed="$1" found="$2" item keep ok
  for item in $found; do
    keep=no
    for ok in $allowed; do
      case "$item" in "$ok"*) keep=yes ;; esac
    done
    [ "$keep" = no ] && printf '%s\n' "$item"
  done
  return 0
}

build_and_run() {
  local label="$1" name="$2" source="$3"
  shift 3
  if ! "$IYI" build "$@" -o "$WORK/$name" "$source" >"$WORK/$name.build.log" 2>&1; then
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

echo "== the std/eiy exercise"
build_and_run "std_eiy" exercise-eiy "$REPO/bench/std_eiy_exercise.iyi"

echo
echo "== every eiy check reported"
for check in "render:" "embed: into a Buffer" "embed: into stdout" "def_to_s:" "lexer:" "generated source exact" "ALL CHECKS PASSED"; do
  if ! grep -qF -- "$check" "$WORK/exercise-eiy.out" 2>/dev/null; then
    echo "  missing: $check"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  render, embed, def_to_s, the lexer and the generated source all reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "std_eiy --release" exercise-eiy-release "$REPO/bench/std_eiy_exercise.iyi" --release >"$WORK/release.log"
if grep -qF "ALL CHECKS PASSED" "$WORK/exercise-eiy-release.out" 2>/dev/null; then
  echo "  the release build reports the same"
else
  echo "  the release build did not report ALL CHECKS PASSED"
  sed -n '1,12p' "$WORK/release.log"
  status=1
fi

# ---------------------------------------------------------------------------
# Negative failure proofs
# ---------------------------------------------------------------------------

# A patched copy of the module ahead of src on IYI_PATH; `eiy/process`, the
# program the macros run, goes with it, so the patched lexer is the one that
# compiles the template.
patched_std() { # patched_std <dir> <python replace expression>
  local dir="$1" replace="$2"
  mkdir -p "$WORK/$dir/std/eiy"
  cp "$REPO/src/std/eiy.iyi" "$WORK/$dir/std/eiy.iyi"
  cp "$REPO/src/std/eiy/process.iyi" "$WORK/$dir/std/eiy/process.iyi"
  "$PY" -c "
import sys
path = '$WORK/$dir/std/eiy.iyi'
with open(path) as f:
    content = f.read()
broken = $replace
if broken == content:
    sys.exit('the patch changed nothing')
with open(path, 'w') as f:
    f.write(broken)
" || { echo "  could not patch the module"; status=1; }
}

prove_fails() { # prove_fails <label> <dir> <named check> <python replace expression>
  local label="$1" dir="$2" check="$3" replace="$4"
  echo
  echo "== negative proof: $label is caught"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so this proof is unmeasured"
    return
  fi
  patched_std "$dir" "$replace"
  if (IYI_PATH="$WORK/$dir${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_eiy_exercise.iyi" >"$WORK/$dir.out" 2>&1); then
    echo "  the exercise PASSED with $label (it should have failed):"
    head -15 "$WORK/$dir.out" | sed 's/^/    /'
    status=1
  elif grep -qF -- "$check" "$WORK/$dir.out"; then
    echo "  $label was caught at '$check'"
  else
    echo "  $label failed, but not at '$check':"
    head -15 "$WORK/$dir.out" | sed 's/^/    /'
    status=1
  fi
}

prove_fails "-%> trimming that trims nothing" patched_trim "render of the template" \
  "content.replace('if suppress_trailing && token.string?', 'if false && token.string?')"
prove_fails "a column counted in bytes" patched_column "token 2 at 2:7" \
  "content.replace('@column_number += 1 unless (b & 0xC0_u8) == 0x80_u8', '@column_number += 1')"
# With `#` left unescaped the template's `#{raw}` becomes interpolation in the
# generated program, and the build refuses the name the template never meant.
prove_fails "template text spliced in unescaped" patched_quote "undefined local variable or method 'raw'" \
  "content.replace(\"elsif b == 35 # '#'\", \"elsif b == 36 # '#'\")"

# ---------------------------------------------------------------------------
# What the template compiler refuses
# ---------------------------------------------------------------------------

echo
echo "== what the macros refuse at build time"
eiy_build_refuses() { # eiy_build_refuses <label> <name> <phrase>
  local label="$1" name="$2" phrase="$3"
  printf 'module main\n\nimport std/eiy::{Eiy}\n\nputs Eiy.render("%s.eiy")\n' "$name" > "$WORK/$name.iyi"
  if "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: it built instead of refusing"
    status=1
    return
  fi
  # A path inside an iyi message is rendered the platform's own way, so the
  # output's separators are normalised before the sentence is looked for.
  # Pinning either spelling fails on the other platform, and what this arm
  # is about is the refusal, not the slash. Same shape as `bench/panics.sh`.
  if ! tr '\\' '/' < "$WORK/$name.build" | grep -qF -- "$phrase"; then
    echo "  $label: refused, but not with '$phrase'"
    sed -n '1,12p' "$WORK/$name.build"
    status=1
    return
  fi
  printf '  %s: the build stops at "%s"\n' "$label" "$phrase"
}
printf 'ok\n  x <%%= 1 +\n' > "$WORK/open_tag.eiy"
eiy_build_refuses "a tag that is never closed" open_tag "unterminated <%= tag at line 2, column 5"
eiy_build_refuses "a template that is not there" no_such_template "cannot read $WORK/no_such_template.eiy"
# And an error inside a template's own code is reported at the template's
# line and column, not in the generated source.
printf 'ok\n  x <%%= nonexistent_thing %%>\n' > "$WORK/bad_name.eiy"
eiy_build_refuses "a name the template does not have" bad_name "bad_name.eiy:2:9"

echo
echo "== what the runtime API refuses"
eiy_panics_with() { # eiy_panics_with <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/eiy::{Eiy}\n\nputs (%s).to_s\n' "$expression" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of panicking: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: panicked, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits 1 at "%s"\n' "$label" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}
eiy_panics_with "an open control tag, processed with a filename" open_control "t.eiy: unterminated <% tag at line 1, column 4" \
  'Eiy.process_string("ab <% x", "t.eiy")'
eiy_panics_with "an open output tag, lexed" open_lexed "unterminated <%= tag at line 2, column 1" \
  '(l = Eiy::Lexer.new("a\n<%= b"); l.next_token; l.next_token).value'
eiy_panics_with "a template file that is not there, processed" open_file "cannot read /nowhere/t.eiy" \
  'Eiy.process_file("/nowhere/t.eiy")'

# ---------------------------------------------------------------------------
# Dependency floor audit
# ---------------------------------------------------------------------------

echo
echo "== the dependency floor, measured against the std_eiy exercise binary"
case "$(uname -s)" in
  Linux)
    allowed_symbols="$FLOOR_BASE_LINUX"
    if ! command -v readelf >/dev/null 2>&1; then
      echo "  readelf is required on Linux to read NEEDED entries" >&2
      exit 2
    fi
    ;;
  *)
    # The base is every darwin program's (bench/floor_base.sh); the socket
    # and file names beside it are what this exercise's binary asks for on
    # top, each libSystem's, which the `allowed_libs` check below proves
    # independently: this binary still links libSystem and nothing else.
    allowed_symbols="$FLOOR_BASE_DARWIN accept bind chmod close connect getsockname listen open recv send setsockopt socket unlink"
    ;;
esac
allowed_libs="$FLOOR_LIBS_PROGRAM"

if [ -x "$WORK/exercise-eiy" ]; then
  eiy_syms="$(symbols "$WORK/exercise-eiy")"
  eiy_libs="$(libraries "$WORK/exercise-eiy")"
  printf '  symbols   %s\n' "$(echo $eiy_syms)"
  printf '  libraries %s\n' "$(echo $eiy_libs)"

  extra_syms="$(unexpected "$allowed_symbols" "$(echo $eiy_syms)")"
  if [ -n "$extra_syms" ]; then
    echo "  std/eiy asks the machine for something new:"
    echo "$extra_syms" | sed 's/^/    /'
    echo "  Each is a dependency being taken on. If that is the decision, record it"
    echo "  here and in the commit (SPEC.md III.9)."
    status=1
  fi

  extra_libs="$(unexpected "$allowed_libs" "$(echo $eiy_libs)")"
  if [ -n "$extra_libs" ]; then
    echo "  std/eiy links something new:"
    echo "$extra_libs" | sed 's/^/    /'
    status=1
  fi
  [ -z "$extra_syms$extra_libs" ] && echo "  nothing new: std/eiy costs zero new symbols and zero new libraries"
else
  echo "  no exercise binary to audit"
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/eiy exercise holds"
else
  echo "the std/eiy exercise did not hold"
fi
exit $status
