#!/usr/bin/env bash
# Exercises `std/docs_pseudo_methods`.
#
#     bash bench/std_docs_pseudo_methods_exercise.sh
#
# Proves the documentation pseudo-methods module holds plain and --release,
# that its pseudo-types and Object pseudo-methods are declared and typed,
# and that a broken module is caught.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src:$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_docs_pseudo_methods_exercise.iyi" \
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

echo "== the std/docs_pseudo_methods exercise, plain build"
build_and_run "plain" docs_pseudo_methods-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/docs_pseudo_methods-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every docs_pseudo_methods section reported"
for phrase in "== documentation pseudo-types" "== Object pseudo-methods" "== compiler intrinsics documented by the pseudo-methods"; do
  if ! grep -q "$phrase" "$WORK/docs_pseudo_methods-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" docs_pseudo_methods-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/docs_pseudo_methods-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/docs_pseudo_methods.iyi").read_text()
old = 'def __crystal_pseudo_as(type : Class)'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/docs_pseudo_methods.iyi").write_text(src.replace(old, 'def __crystal_pseudo_mutated_as(type : Class)', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_docs_pseudo_methods_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken docs_pseudo_methods is caught"
fi

if [ "$status" -eq 0 ]; then
  echo
  echo "the std/docs_pseudo_methods exercise holds"
else
  echo
  echo "the std/docs_pseudo_methods exercise did not hold"
  exit 1
fi
