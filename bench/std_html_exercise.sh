#!/usr/bin/env bash
# Exercises `std/html`: escape and unescape.
#
#     bash bench/std_html_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_html_exercise.iyi" \
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

echo "== the std/html exercise, plain build"
build_and_run "plain" html-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/html-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every html section reported"
for phrase in "== escape" "== unescape"; do
  if ! grep -q "$phrase" "$WORK/html-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  escape and unescape reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" html-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/html-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when & is not escaped"
mkdir -p "$WORK/patched_amp/std"
python3 - <<PY
src = open("$REPO/src/std/html.iyi").read()
old = 'bytes << 38_u8; bytes << 97_u8; bytes << 109_u8; bytes << 112_u8; bytes << 59_u8'
if old not in src:
    raise SystemExit("patch site missing")
open("$WORK/patched_amp/std/html.iyi", "w").write(src.replace(old, 'bytes << 38_u8', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched_amp:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_html_exercise.iyi" >"$WORK/amp.out" 2>&1; then
  echo "  the exercise PASSED with & left raw"
  status=1
else
  echo "  an escape that leaves & raw is caught"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/html exercise holds"
else
  echo "the std/html exercise did not hold"
fi
exit $status
