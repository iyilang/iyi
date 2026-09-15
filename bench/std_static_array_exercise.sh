#!/usr/bin/env bash
# Exercises `std/static_array`: fixed-size stack array new, size, index.
#
#     bash bench/std_static_array_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_static_array_exercise.iyi" \
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

echo "== the std/static_array exercise, plain build"
build_and_run "plain" static_array-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/static_array-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every static_array section reported"
for phrase in "== new" "== index"; do
  if ! grep -q "$phrase" "$WORK/static_array-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" static_array-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/static_array-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/static_array.iyi").read_text()
old = '  def size : Int32\n    N\n  end'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/static_array.iyi").write_text(src.replace(old, '  def size : Int32\n    0\n  end', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_static_array_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken static_array is caught"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/static_array exercise holds"
else
  echo "the std/static_array exercise did not hold"
fi
exit $status
