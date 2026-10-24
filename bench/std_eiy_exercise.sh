#!/usr/bin/env bash
# Exercises `std/eiy`: templates compiled into the program.
#
#     bash bench/std_eiy_exercise.sh
#
# Proves:
#   * `Eiy.render`, `Eiy.embed` and `Eiy.def_to_s` of bench/std_eiy_exercise.eiy
#     (output tags, `if`, a block, `<%-`/`-%>` trimming, a two-line comment,
#     an escaped tag, quotes, backslashes, `#{`, UTF-8 text, and
#     bench/std_eiy_exercise_part.eiy rendered from inside it) print the
#     expected text byte for byte, plain and with --release.
#   * Two builds of it at once, the template helper the macros run made
#     stale before each of four rounds, all build.
#   * One helper run per template per compile: two renders of a template
#     from one file, and of a template that renders a partial, run the
#     helper once each and print each to its own buffer; a template edited
#     between two builds prints its new text; one with the placeholder name
#     in its text is run under the real name; the second build reuses the
#     helper rather than relinking it; and a copy of the compiler's
#     substitution (`src/compiler/iyi/macros/eiy_io.cr`) that leaves the
#     placeholder in place is caught.
#   * `Eiy::Lexer` token types, values, flags and positions; the generated
#     source of `process_string`, exactly; `process_file`, `locate`, and the
#     nil-answering pair.
#   * Negative proofs: a copy of the module with `-%>` trimming broken, with
#     columns counted in bytes, with `#` left unescaped in template text, with
#     bytes that are not UTF-8 left unescaped, with a comment tag spliced in
#     as code, with `render`'s buffer under a fixed name, with `def_to_s`'s
#     parameter named `io`, and with a Buffer that needs `write` of its target
#     is caught, each at its named check.
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
for check in "render:" "embed: into a Buffer" "embed: a Buffer printed into another Buffer" "embed: into stdout" "def_to_s:" "a template's own" "lexer:" "generated source exact" "ALL CHECKS PASSED"; do
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

echo
echo "== two builds of it at once, the template helper stale before each"
# Every compiler on the machine links the helper the macros `run`
# (std/eiy/process) into one cache directory, and it was linked straight to
# its final name: Windows will not write over a program that is running, so
# two builds of this exercise at once, the helper stale, failed one of the
# two in each of 4 rounds with "LNK1104: cannot open file ...\macro_run".
# The module is copied so that its helper can be made stale here.
mkdir -p "$WORK/twice/std/eiy"
cp "$REPO/src/std/eiy.iyi" "$WORK/twice/std/eiy.iyi"
cp "$REPO/src/std/eiy/process.iyi" "$WORK/twice/std/eiy/process.iyi"
twice_failed=0
for round in 1 2 3 4; do
  # A modification time the helper was not built from.
  touch -t "2020010100${round}0" "$WORK/twice/std/eiy/process.iyi"
  pids=""
  for side in a b; do
    IYI_PATH="$WORK/twice${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/twice/$side" \
      "$REPO/bench/std_eiy_exercise.iyi" >"$WORK/twice/$round$side.log" 2>&1 &
    pids="$pids $!"
  done
  for pid in $pids; do
    wait "$pid" || twice_failed=$((twice_failed + 1))
  done
done
if [ "$twice_failed" -eq 0 ]; then
  echo "  8 builds, two at a time, all built"
else
  echo "  $twice_failed of 8 builds, two at a time, failed:"
  grep -h -m1 "rror" "$WORK"/twice/*.log | head -3 | sed 's/^/    /'
  status=1
fi

echo
echo "== one helper run per template per compile"
# `Eiy.render` names its buffer afresh (`%buf`), so every render passed the
# helper different arguments and was a process of its own: 240 of them on
# the generated app #143 was measured on, for 40 templates. The compiler
# runs the helper under a placeholder name and gives each render the output
# with its own buffer's name put back (#143), so this program costs three
# runs and three reuses: `card.eiy` twice, `outer.eiy` twice, and the
# `part.eiy` inside it once per `outer.eiy`, all from one caller each.
#
# The second build has to reuse the helper the first one linked. A search
# path with `..` in it made every build relink it inside `Semantic (main)`
# (`can_reuse_previous_compilation?`): measured with the compiler before
# #143 and this path, a fresh cache linked it in 1.53 s and the next build
# linked it again in 0.24 s. So the path is spelled through `bin/..`, and
# the cache is this gate's own, where nothing else has linked the helper
# first.
R="$WORK/reuse"
mkdir -p "$R"
printf 'module main\n\nimport std/eiy::{Eiy}\n\nn = 1\na = Eiy.render("card.eiy")\nn = 2\nb = Eiy.render("card.eiy")\nn = 3\nc = Eiy.render("outer.eiy")\nn = 4\nd = Eiy.render("outer.eiy")\nputs a\nputs b\nputs c\nputs d\n' > "$R/main.iyi"
printf 'card <%%= n %%>' > "$R/card.eiy"
printf '[<%%= n %%> <%%= Eiy.render("part.eiy") %%> <%%= n %%>]' > "$R/outer.eiy"
printf 'part <%%= n * 10 %%>' > "$R/part.eiy"
reuse_path="$REPO/bin/../src${PSEP}$REPO/samples/iyi"
reuse_build() { # reuse_build <name> <source> <expected output> <expected run line> <label>
  local name="$1" source="$2" expected="$3" runs="$4" label="$5"
  if ! IYI_PATH="$reuse_path" IYI_CACHE_DIR="$R/cache" "$IYI" build -s -o "$R/$name" "$R/$source" >"$R/$name.log" 2>&1; then
    echo "  $label: build failed"
    tail -12 "$R/$name.log" | sed 's/^/    /'
    status=1
    return 1
  fi
  local actual
  actual="$("$R/$name" | tr -d '\r')"
  if [ "$actual" != "$expected" ]; then
    echo "  $label: printed"
    printf '%s\n' "$actual" | sed 's/^/    /'
    echo "  instead of"
    printf '%s\n' "$expected" | sed 's/^/    /'
    status=1
    return 1
  fi
  if ! tr -d '\r' < "$R/$name.log" | grep -qE -- "process\.iyi: .*$runs"; then
    echo "  $label: the macro runs were not '$runs':"
    grep -A2 "^Macro runs" "$R/$name.log" | sed 's/^/    /'
    status=1
    return 1
  fi
  echo "  $label: right text, $(tr -d '\r' < "$R/$name.log" | grep -oE -- "process\.iyi: .*" | sed 's/process\.iyi: //')"
}
reuse_build first main.iyi "$(printf 'card 1\ncard 2\n[3 part 30 3]\n[4 part 40 4]')" \
  "3 runs in [0-9:.]+, 3 reused$" "two renders each of a template and of one with a partial"
printf 'CARD <%%= n %%>!' > "$R/card.eiy"
reuse_build second main.iyi "$(printf 'CARD 1!\nCARD 2!\n[3 part 30 3]\n[4 part 40 4]')" \
  "reused previous compilation .*, 3 runs in [0-9:.]+, 3 reused$" "the template edited, built again"
# The placeholder written in a template could not be told from the buffer
# in the helper's output, so the first render pays for the refused run and
# its real one, and the second only for its real one.
printf 'module main\n\nimport std/eiy::{Eiy}\n\nn = 1\nputs Eiy.render("literal.eiy")\nn = 2\nputs Eiy.render("literal.eiy")\n' > "$R/literal.iyi"
printf '__iyi_eiy_io_7f3a__ <%%= n %%>' > "$R/literal.eiy"
reuse_build literal literal.iyi "$(printf '__iyi_eiy_io_7f3a__ 1\n__iyi_eiy_io_7f3a__ 2')" \
  "3 runs in [0-9:.]+$" "a template with the placeholder in its text"

# The substitution on its own, built from the compiler's source, and a copy
# that hands the output back with the placeholder still in it.
eiy_io_check() { # eiy_io_check <dir>; the driver's output is in <dir>/out
  local dir="$1"
  cat > "$dir/drive.cr" <<'CRYSTAL'
require "./eiy_io"

failed = false
check = ->(label : String, ok : Bool) do
  puts "#{ok ? "ok" : "FAILED"}: #{label}"
  failed = true unless ok
end
placeholder = Iyi::EiyIO::PLACEHOLDER
output = "#{placeholder}.print(\"a\")\n#<loc:push>#{placeholder}.print((x\n))#<loc:pop>\n"
check.call "the buffer's name stands where the placeholder stood",
  Iyi::EiyIO.substitute(output, "__temp_7") == "__temp_7.print(\"a\")\n#<loc:push>__temp_7.print((x\n))#<loc:pop>\n"
check.call "a placeholder inside a longer word is refused",
  Iyi::EiyIO.substitute("x#{placeholder}.print(1)\n#{placeholder}_2", "b").nil?
check.call "the placeholder is found in a template's text",
  Iyi::EiyIO.in?("a #{placeholder} b") && !Iyi::EiyIO.in?("a b")
exit(failed ? 1 : 0)
CRYSTAL
  "$IYI" build --crystal -o "$dir/drive" "$dir/drive.cr" >"$dir/out" 2>&1 && "$dir/drive" >"$dir/out" 2>&1
}
mkdir -p "$WORK/eiy_io"
cp "$REPO/src/compiler/iyi/macros/eiy_io.cr" "$WORK/eiy_io/eiy_io.cr"
if eiy_io_check "$WORK/eiy_io"; then
  echo "  the compiler's substitution: $(grep -c '^ok' "$WORK/eiy_io/out") checks held"
else
  echo "  the compiler's substitution failed:"
  sed 's/^/    /' "$WORK/eiy_io/out"
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
# The compiler reads a string literal as UTF-8 and stops with an internal
# error at a byte that is not, so such a byte in template text has to be
# written out.
prove_fails "text that is not UTF-8 spliced in as itself" patched_utf8 "text that is not UTF-8 is written as \\x escapes" \
  "content.replace('elsif b < 32 || b >= 127', 'elsif b < 32 || b == 127')"
# Spliced in as code, the comment's second line runs and drops an item.
prove_fails "a comment tag spliced in as code" patched_comment "render of the template" \
  "content.replace(\"unless str_val.starts_with?('#')\", \"unless false && str_val.starts_with?('#')\")"
# Under a fixed name the template's inner `render` replaces the outer buffer,
# and what the outer printed before it is lost.
prove_fails "render's buffer under a fixed name" patched_nested "render of the template" \
  "content.replace('%buf', '__buf__')"
# Named `io`, the parameter is what the part template's own `|io|` hides, and
# the template prints to its string.
prove_fails "def_to_s's parameter named io" patched_io "undefined method 'print' for String" \
  "content.replace('def to_s(__io__) : Nil\n      ::Std::Eiy::Eiy.embed({{filename}}, __io__)', 'def to_s(io) : Nil\n      ::Std::Eiy::Eiy.embed({{filename}}, io)')"
prove_fails "a Buffer that writes to its target" patched_buffer "undefined method 'write' for Std::Eiy::Eiy::Buffer" \
  "content.replace('io.print(to_s)', 'io.write(to_s)')"

# The compiler's half: a substitution that gives the helper's output back
# as it came, placeholder and all, which every render would then print to a
# buffer of that name that no render has.
echo
echo "== negative proof: a substitution that leaves the placeholder is caught"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so this proof is unmeasured"
else
  mkdir -p "$WORK/eiy_io_broken"
  "$PY" -c "
import sys
with open('$REPO/src/compiler/iyi/macros/eiy_io.cr') as f:
    content = f.read()
broken = content.replace('        io << io_name\n', '        io << PLACEHOLDER\n')
if broken == content:
    sys.exit('the patch changed nothing')
with open('$WORK/eiy_io_broken/eiy_io.cr', 'w') as f:
    f.write(broken)
" || { echo "  could not patch the substitution"; status=1; }
  check="FAILED: the buffer's name stands where the placeholder stood"
  if eiy_io_check "$WORK/eiy_io_broken"; then
    echo "  the checks PASSED with the placeholder left in (they should have failed)"
    status=1
  elif grep -qF -- "$check" "$WORK/eiy_io_broken/out"; then
    echo "  the placeholder left in was caught at '$check'"
  else
    echo "  the placeholder left in failed, but not at '$check':"
    sed 's/^/    /' "$WORK/eiy_io_broken/out" | head -15
    status=1
  fi
fi

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
# A control tag's code that opens straight after `<%` too: it was reported
# a column right, at 2:6.
printf 'ok\n  <%%nonexistent_thing%%>\n' > "$WORK/bad_control.eiy"
eiy_build_refuses "a name in a control tag with no space before it" bad_control "bad_control.eiy:2:5"

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
    # `fstat64` is the runtime's read asking whether standard input is a
    # regular file, which a socket's read shares the code of.
    allowed_symbols="$FLOOR_BASE_DARWIN accept bind chmod close connect fstat64 getsockname listen open recv send setsockopt socket unlink"
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
