#!/usr/bin/env bash
# Exercises `std/lazy`: a value built at its first `get`, kept and counted
# once, each Lazy its own, and one value kept when parallel units race to
# build it. bench/std_lazy_tables_exercise.sh is the other half: std's
# tables built at their first call, never before main.
#
#     bash bench/std_lazy_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The broken copies are made by python, and windows answers `python3` with
# a store stub that prints and exits rather than running it, so the
# interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping, so the
# patched copy's directory is named as Windows names it.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_lazy_exercise.iyi" \
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

echo "== the std/lazy exercise, plain build"
build_and_run "plain" lazy-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/lazy-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every lazy section reported"
for phrase in "== lazy" "== lazy, from parallel units"; do
  if ! grep -qx -- "$phrase" "$WORK/lazy-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" lazy-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/lazy-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
# breaks <label> <name> <old> <new> <check>: src/std/lazy.iyi with <old>,
# which must be there once, made <new>; the exercise must stop at the
# assertion that names <check>.
breaks() {
  local label="$1" name="$2" old="$3" new="$4" check="$5"
  mkdir -p "$WORK/$name/std"
  if ! SRC="$REPO/src/std/lazy.iyi" DST="$WORK/$name/std/lazy.iyi" OLD="$old" NEW="$new" "$PY" - <<'PY'
import os
from pathlib import Path
src = Path(os.environ["SRC"]).read_text(encoding="utf-8")
old = os.environ["OLD"]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique")
Path(os.environ["DST"]).write_text(src.replace(old, os.environ["NEW"], 1), encoding="utf-8")
PY
  then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$name${PSEP}$IYI_PATH" "$IYI" build -o "$WORK/$name.bin" "$REPO/bench/std_lazy_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "  $label: the broken copy did not build"
    tail -5 "$WORK/$name.build.log" | sed 's/^/    /'
    status=1
    return
  fi
  "$WORK/$name.bin" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  if grep -q "ALL CHECKS PASSED" "$WORK/$name.out"; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF -- "ASSERTION FAILED: $check" "$WORK/$name.out"; then
    echo "  $label: exited $exit_code, not at \"$check\":"
    tail -3 "$WORK/$name.out" | sed 's/^/    /'
    status=1
  else
    echo "  $label: caught at \"$check\""
  fi
}

if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proofs are unmeasured"
else
  breaks "a build stored and never marked kept" unmarked \
    '      IyiAtomic.store(pointerof(@mark), 2, :release, false)
' '' \
    'a second get builds nothing'
  breaks "a build not counted" uncounted \
    '    Builds.add
' '' \
    'LazyBuilds.count counts the build'
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/lazy exercise holds"
else
  echo "the std/lazy exercise did not hold"
fi
exit $status
