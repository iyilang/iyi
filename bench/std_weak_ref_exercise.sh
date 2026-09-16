#!/usr/bin/env bash
# Exercises `std/weak_ref`: inspect a referenced object without preventing collection.
#
#     bash bench/std_weak_ref_exercise.sh
#
# Proves:
#   * A reference whose target is strongly held reads back as present.
#   * Construction and the accessor preserve object attributes and identity.
#   * Multiple weak references to the same target agree.
#   * A non-heap object (static literal) yields nil.
#   * A freed target returns nil and zeroes the stored target.
#   * Both plain and --release builds pass.
#   * A broken module is caught when the stored address is discarded.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_weak_ref_exercise.iyi" \
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

echo "== the std/weak_ref exercise, plain build"
build_and_run "plain" weak_ref-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/weak_ref-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every weak_ref section reported"
for phrase in "== strongly held target" "== non-heap target" "== cleared reference"; do
  if ! grep -q "$phrase" "$WORK/weak_ref-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" weak_ref-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/weak_ref-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/weak_ref.iyi").read_text()
old = '@target = ptr.address'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/weak_ref.iyi").write_text(src.replace(old, '@target = 0_u64', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_weak_ref_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken weak_ref is caught"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/weak_ref exercise holds"
else
  echo "the std/weak_ref exercise did not hold"
fi
exit $status
