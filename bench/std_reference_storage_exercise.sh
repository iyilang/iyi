#!/usr/bin/env bash
# Exercises `std/reference_storage`: manual memory storage for reference types.
#
#     bash bench/std_reference_storage_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_reference_storage_exercise.iyi" \
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

echo "== the std/reference_storage exercise, plain build"
build_and_run "plain" reference_storage-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/reference_storage-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every reference_storage section reported"
for phrase in \
  "== size and alignment" \
  "== stack allocation and unsafe_construct" \
  "== manual pre_initialize and initialize" \
  "== heap allocation and custom storage" \
  "== equality and hash" \
  "== uninitialized storage with a reference field" \
  "== string representation"; do
  if ! grep -q "$phrase" "$WORK/reference_storage-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" reference_storage-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/reference_storage-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/reference_storage.iyi").read_text()
old = 'obj.initialize(*args, **opts)'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/reference_storage.iyi").write_text(src.replace(old, '# skipped init', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_reference_storage_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken reference_storage is caught"
fi

echo
echo "== proving wrapping hash is required"
mkdir -p "$WORK/patched_hash/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/reference_storage.iyi").read_text()
old = "h = (h &* 31) ^ ptr[i].to_i32"
if old not in src:
    raise SystemExit("hash patch site missing")
Path("$WORK/patched_hash/std/reference_storage.iyi").write_text(src.replace(old, "h = (h * 31) ^ ptr[i].to_i32", 1))
PY
if [ $? -ne 0 ]; then
  echo "  the hash patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched_hash:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_reference_storage_exercise.iyi" >"$WORK/mut_hash.out" 2>&1; then
  echo "  the exercise PASSED on overflow-checked hash"
  status=1
else
  echo "  overflow-checked hash is caught"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/reference_storage exercise holds"
else
  echo "the std/reference_storage exercise did not hold"
fi
exit $status
