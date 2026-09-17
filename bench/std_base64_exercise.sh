#!/usr/bin/env bash
# Exercises `std/base64`.
#
#     bash bench/std_base64_exercise.sh
#
# Proves the exercise holds plain and --release, that a broken encoder is
# caught, and what `decode` refuses: a byte outside the alphabet, data after
# the padding, data inside it, more `=` than the group needs, `=` with no
# group to close, and a final group of one character - each a panic with a
# sentence, where before the data was silently dropped.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_base64_exercise.iyi" \
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

echo "== the std/base64 exercise, plain build"
build_and_run "plain" base64-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/base64-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every base64 section reported"
for phrase in "== encode" "== decode"; do
  if ! grep -q "$phrase" "$WORK/base64-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" base64-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/base64-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/base64.iyi").read_text()
old = 'dst[o] = table[(triple >> 18) & 63]'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/base64.iyi").write_text(src.replace(old, 'dst[o] = 65_u8', 1))
PY
then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_base64_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken base64 is caught"
fi

echo
echo "== what decode refuses"
refuses() { # refuses <label> <name> <phrase> <text>
  local label="$1" name="$2" phrase="$3" text="$4"
  printf 'module main\n\nimport std/base64\nusing std/base64::{Base64}\n\nputs Base64.decode(%s).inspect\n' "$text" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}
refuses "a byte outside the alphabet" bad_byte "base64: invalid byte 42" '"QU*JD"'
refuses "data after the padding" after_pad "base64: data after padding" '"QQ==QQ=="'
refuses "data inside the padding" inside_pad "base64: discontinuous padding" '"QU=JD"'
refuses "more padding than the group needs" excess_pad "base64: excess padding" '"QQ==="'
refuses "padding after a full group" full_pad "base64: padding with no group to close" '"QUJD="'
refuses "a lone character" lone_char "base64: 1 data characters, 1 more than a multiple of 4" '"Q"'
refuses "a final group of one character" dangling "base64: 5 data characters, 1 more than a multiple of 4" '"QUJDR"'
refuses "a padded lone character" padded_lone "base64: 1 data characters, 1 more than a multiple of 4" '"Q="'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/base64 exercise holds"
else
  echo "the std/base64 exercise did not hold"
fi
exit $status
