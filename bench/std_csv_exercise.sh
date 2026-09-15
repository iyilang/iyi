#!/usr/bin/env bash
# Exercises `std/csv`.
#
#     bash bench/std_csv_exercise.sh
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
for phrase in "== parse"; do
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
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/csv.iyi").read_text()
old = 'row << take(field, flen)'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/csv.iyi").write_text(src.replace(old, 'row << ""', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_csv_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken csv is caught"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/csv exercise holds"
else
  echo "the std/csv exercise did not hold"
fi
exit $status
