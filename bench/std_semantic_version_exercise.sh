#!/usr/bin/env bash
# Exercises `std/semantic_version`: SemVer 2.0 parse and refuse.
#
#     bash bench/std_semantic_version_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_semantic_version_exercise.iyi" \
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

echo "== the std/semantic_version exercise, plain build"
build_and_run "plain" semantic_version-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/semantic_version-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every semantic_version section reported"
for phrase in "== parse" "== refuse" "== order" "== prerelease identifiers"; do
  if ! grep -q "$phrase" "$WORK/semantic_version-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" semantic_version-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/semantic_version-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/semantic_version.iyi").read_text()
old = 'return nil unless parts'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/semantic_version.iyi").write_text(src.replace(old, '# return nil unless parts', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_semantic_version_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on a broken module"
    status=1
  else
    echo "  a broken semantic_version is caught"
  fi
fi

# Each fix, broken back, must be caught at the check written for it: the
# module is patched the way the proof above patches it, and the run's
# output must carry *expect*.
caught_at() {
  local label="$1" old="$2" new="$3" expect="$4"
  rm -rf "$WORK/patched" && mkdir -p "$WORK/patched/std"
  OLD="$old" NEW="$new" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/semantic_version.iyi").read_text()
old, new = os.environ["OLD"], os.environ["NEW"]
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/semantic_version.iyi").write_text(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_semantic_version_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF "$expect" "$WORK/mut.out"; then
    echo "  $label: failed, but not at \"$expect\":"
    tail -3 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  else
    echo "  $label: caught"
  fi
}

if [ -n "$PY" ]; then
  caught_at "<=> spelled (other : self), replaced by the impl's own" \
    'def <=>(other : SemanticVersion) : Int32' 'def <=>(other : self) : Int32' \
    'stack overflow'
  caught_at "a signed identifier read as a number" \
    'if n && part.to_unsafe[0] >= 48_u8 && part.to_unsafe[0] <= 57_u8' 'if n' \
    'a signed identifier is alphanumeric'
  caught_at "numbers past Int32 compared as bytes" \
    'elsif digits?(x) || digits?(y)' 'elsif false' \
    'numbers past Int32 order by value'
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/semantic_version exercise holds"
else
  echo "the std/semantic_version exercise did not hold"
fi
exit $status
