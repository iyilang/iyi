#!/usr/bin/env bash
# Exercises `std/colorize`: ANSI SGR wrapping, gated by Colorize.enabled.
#
#     bash bench/std_colorize_exercise.sh
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

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_colorize_exercise.iyi" \
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

echo "== the std/colorize exercise, plain build"
build_and_run "plain" colorize-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/colorize-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every colorize section reported"
for phrase in "== disabled" "== enabled" "== inspect and names"; do
  if ! grep -q "$phrase" "$WORK/colorize-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" colorize-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/colorize-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== a name that is no colour or mode is refused"
# `fore(:purple)` raises in the other library, and a program cannot catch a
# panic, so the refusal is proven here: the program must stop, and with the
# sentence that names the typo. Answering `Default` painted it in no colour.
mkdir -p "$WORK/names"
refused() {
  local path="$1" name="$2" call="$3" message="$4"
  printf 'import std/colorize::{Colorize}\nColorize.enabled = true\nputs "x".colorize%s.to_s\n' "$call" >"$WORK/names/$name.iyi"
  if IYI_PATH="$path" "$IYI" run "$WORK/names/$name.iyi" >"$WORK/names/$name.out" 2>&1; then
    return 1
  fi
  grep -q "$message" "$WORK/names/$name.out"
}
if refused "$IYI_PATH" color '(:purple)' "Unknown color: purple"; then
  echo "  fore(:purple) is refused"
else
  echo "  fore(:purple) was not refused with \"Unknown color: purple\""
  status=1
fi
if refused "$IYI_PATH" mode '.bold.mode(:italic)' "Unknown mode: italic"; then
  echo "  mode(:italic) is refused"
else
  echo "  mode(:italic) was not refused with \"Unknown mode: italic\""
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/colorize.iyi").read_text()
old = 'Red          = 31'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/colorize.iyi").write_text(src.replace(old, 'Red          = 32', 1))
PY
then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_colorize_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken colorize is caught"
fi

# A copy of the module with each replacement made, or the reason it could
# not be: `broken_copy DIR OLD NEW [OLD NEW]...`.
broken_copy() {
  local dir="$1"
  shift
  mkdir -p "$WORK/$dir/std"
  "$PY" - "$WORK/$dir/std/colorize.iyi" "$@" <<PY
import sys
from pathlib import Path
src = Path("$REPO/src/std/colorize.iyi").read_text()
args = sys.argv[2:]
for old, new in zip(args[0::2], args[1::2]):
    if old not in src:
        raise SystemExit("patch site missing: " + old)
    src = src.replace(old, new, 1)
Path(sys.argv[1]).write_text(src)
PY
}

# The exercise, run on a broken copy, must stop at the check named.
caught_at() {
  local dir="$1" label="$2" message="$3"
  if IYI_PATH="$WORK/$dir${PSEP}$IYI_PATH" "$IYI" run "$REPO/bench/std_colorize_exercise.iyi" >"$WORK/$dir.out" 2>&1; then
    echo "  the exercise PASSED with $label"
    status=1
  elif grep -q "ASSERTION FAILED: $message" "$WORK/$dir.out"; then
    echo "  $label is caught"
  else
    echo "  $label failed, but not at \"$message\""
    tail -3 "$WORK/$dir.out" | sed 's/^/    /'
    status=1
  fi
}

if [ -n "$PY" ]; then
  if broken_copy inspect 'wrap(@target.inspect)' 'wrap(@target.to_s)'; then
    caught_at inspect "inspect written as to_s" "inspect wraps the target's inspect"
  else
    echo "  the inspect patch did not apply"
    status=1
  fi
  if broken_copy bright 'when :bold, :bright then Mode::Bold' 'when :bold          then Mode::Bold' \
       'else                     raise "Unknown mode: #{sym}"' 'else                     Mode::Default'; then
    caught_at bright ":bright read as no mode" "mode(:bright) is bold"
  else
    echo "  the bright patch did not apply"
    status=1
  fi
  if ! broken_copy nocolor 'else                     raise "Unknown color: #{symbol}"' 'else                     ColorANSI::Default'; then
    echo "  the unknown-colour patch did not apply"
    status=1
  elif refused "$WORK/nocolor${PSEP}$IYI_PATH" nocolor '(:purple)' "Unknown color: purple"; then
    echo "  an unknown colour answered Default was not caught"
    status=1
  elif grep -q "^x$" "$WORK/names/nocolor.out"; then
    echo "  an unknown colour answered Default is caught"
  else
    echo "  the unknown-colour copy failed without printing: it did not build"
    tail -3 "$WORK/names/nocolor.out" | sed 's/^/    /'
    status=1
  fi
  if ! broken_copy nomode 'else                     raise "Unknown mode: #{sym}"' 'else                     Mode::Default'; then
    echo "  the unknown-mode patch did not apply"
    status=1
  elif refused "$WORK/nomode${PSEP}$IYI_PATH" nomode '.bold.mode(:italic)' "Unknown mode: italic"; then
    echo "  an unknown mode answered Default was not caught"
    status=1
  elif grep -q "^x$" "$WORK/names/nomode.out"; then
    echo "  an unknown mode answered Default is caught"
  else
    echo "  the unknown-mode copy failed without printing: it did not build"
    tail -3 "$WORK/names/nomode.out" | sed 's/^/    /'
    status=1
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/colorize exercise holds"
else
  echo "the std/colorize exercise did not hold"
fi
exit $status
