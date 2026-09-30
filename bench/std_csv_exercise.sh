#!/usr/bin/env bash
# Exercises `std/csv`.
#
#     bash bench/std_csv_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_csv_exercise.iyi" \
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

echo "== the std/csv exercise, plain build"
build_and_run "plain" csv-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/csv-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every csv section reported"
for phrase in "== parse" "== line ends and empty fields"; do
  if ! grep -q "$phrase" "$WORK/csv-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" csv-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/csv-release.out" 2>/dev/null; then
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
src = Path("$REPO/src/std/csv.iyi").read_text()
old = 'row << take(field, flen)'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/csv.iyi").write_text(src.replace(old, 'row << ""', 1))
PY
then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_csv_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken csv is caught"
fi

# Each fix undone in a copy: the exercise must fail at the check written
# for it - not at an earlier one, and not by failing to compile.
broken() { # broken <label> <old> <new> <phrase>
  local label="$1" phrase="$4"
  if [ -z "$PY" ]; then
    echo "  $label: no python3 on this machine, so the broken-module proof is unmeasured"
    return
  fi
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if ! OLD="$2" NEW="$3" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/csv.iyi").read_text()
old = os.environ["OLD"]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique")
Path("$WORK/patched/std/csv.iyi").write_text(src.replace(old, os.environ["NEW"], 1))
PY
  then
    echo "  $label: the patch did not apply"
    status=1
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mut.bin" "$REPO/bench/std_csv_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the broken copy did not compile"
    sed -n '1,6p' "$WORK/mut.out"
    status=1
  elif "$WORK/mut.bin" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF -- "$phrase" "$WORK/mut.out"; then
    echo "  $label: failed, but not at '$phrase'"
    sed -n '1,4p' "$WORK/mut.out"
    status=1
  else
    echo "  $label: caught"
  fi
}
broken "a lone CR dropped again" 'elsif b == 10_u8 || b == 13_u8' 'elsif b == 10_u8' "ASSERTION FAILED: a lone CR ends the line"
broken "a blank line read as one empty field" 'row << take(field, flen) if row.size > 0 || flen > 0 || opened' 'row << take(field, flen)' "ASSERTION FAILED: a blank line is a row of no fields"
broken "a last quoted empty field dropped" 'if flen > 0 || row.size > 0 || opened' 'if flen > 0 || row.size > 0' "ASSERTION FAILED: a last line of one quoted empty field"
broken "a lone empty field written bare" 'io << "\"\"" if fields.size == 1 && fields[0].empty?' '' "ASSERTION FAILED: a row of one empty field is written quoted"

echo
if [ "$status" -eq 0 ]; then
  echo "the std/csv exercise holds"
else
  echo "the std/csv exercise did not hold"
fi
exit $status
