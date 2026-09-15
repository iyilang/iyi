#!/usr/bin/env bash
# Exercises `std/yaml`: YAML 1.2 core schema, dump, anchors, merge, refusals.
#
#     bash bench/std_yaml_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_yaml_exercise.iyi" \
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

echo "== the std/yaml exercise, plain build"
build_and_run "plain" yaml-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/yaml-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every yaml section reported"
for phrase in "== scalars and collections" "== dump round trip" "== anchors, aliases, merge" "== streams and typed keys" "== what the reader refuses"; do
  if ! grep -q "$phrase" "$WORK/yaml-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  scalars, dump, anchors, streams and refusals all reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" yaml-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/yaml-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when a repeated key is accepted"
mkdir -p "$WORK/patched_dup/std"
SRC="$REPO/src/std/yaml.iyi" DST="$WORK/patched_dup/std/yaml.iyi" python3 - <<'PY'
import os
from pathlib import Path
src = Path(os.environ["SRC"]).read_text()
old = "if !merge && spelled.has_key?(key)"
new = "if !merge && spelled.has_key?(key) && false"
if old not in src:
    raise SystemExit("patch site missing")
Path(os.environ["DST"]).parent.mkdir(parents=True, exist_ok=True)
Path(os.environ["DST"]).write_text(src.replace(old, new, 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched_dup:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_yaml_exercise.iyi" >"$WORK/dup.out" 2>&1; then
  echo "  the exercise PASSED with duplicate keys accepted"
  status=1
else
  echo "  a repeated mapping key is caught"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/yaml exercise holds"
else
  echo "the std/yaml exercise did not hold"
fi
exit $status
