#!/usr/bin/env bash
# Exercises `std/xml`: parser, tree, serializer, references, refusals.
#
#     bash bench/std_xml_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_xml_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  grep -E '^== |^  |ALL CHECKS' "$WORK/$name.out" | sed 's/^/  /' || true
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    tail -8 "$WORK/$name.out"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/xml exercise, plain build"
build_and_run "plain" xml-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/xml-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every xml section reported"
for phrase in "== round trip" "== escaping" "== refusals" "== limits"; do
  if ! grep -q "$phrase" "$WORK/xml-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  round trip, escaping, refusals and limits all reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" xml-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/xml-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when a duplicate attribute is accepted"
mkdir -p "$WORK/patched_dup/std"
python3 - <<PY
src = open("$REPO/src/std/xml.iyi").read()
old = '''        fail_at(attr_line, attr_col, "attribute '#{attr_name}' given twice on <#{name}>")'''
new = '''        # duplicate attributes accepted'''
if old not in src:
    raise SystemExit("patch site missing")
open("$WORK/patched_dup/std/xml.iyi", "w").write(src.replace(old, new, 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched_dup:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_xml_exercise.iyi" >"$WORK/dup.out" 2>&1; then
  echo "  the exercise PASSED with duplicate attributes accepted"
  status=1
elif ! grep -q "given twice" "$WORK/dup.out"; then
  echo "  failed, but not at the duplicate-attribute check:"
  grep -m1 panic "$WORK/dup.out" || sed -n '1,8p' "$WORK/dup.out"
  status=1
else
  echo "  a repeated attribute is caught"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/xml exercise holds"
else
  echo "the std/xml exercise did not hold"
fi
exit $status
