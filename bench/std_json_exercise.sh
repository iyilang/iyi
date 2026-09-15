#!/usr/bin/env bash
# Exercises `std/json`: parse, Any, PullParser, Builder, to_json / from_json.
#
#     bash bench/std_json_exercise.sh
#
# Proves the exercise holds plain and --release, the compact corpus round-trips
# through python3's json, what the reader refuses is refused in the program,
# and a copy that stops treating a repeated object key as a mistake is caught.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_json_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  grep -v '^[{["0-9tfn-]' "$WORK/$name.out" | grep -v '^  ' | sed 's/^/  /' || true
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    tail -8 "$WORK/$name.out"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/json exercise, plain build"
build_and_run "plain" json-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/json-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every json section reported"
for phrase in "== parse corpus" "== to_json and to_pretty_json" "== pull parser walk" "== builder" "== equality and hash" "== to_json and from_json" "== what the reader refuses" "== differential corpus"; do
  if ! grep -q "$phrase" "$WORK/json-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  parse, print, pull, builder, hash, from_json, refusals and the corpus all reported"

echo
echo "== compact corpus against python3 json"
grep '^oracle json' "$WORK/json-plain.out" | cut -f2- > "$WORK/compact.iyi.txt"
if [ "$(wc -l < "$WORK/compact.iyi.txt")" -lt 20 ]; then
  echo "  the corpus shrank ($(wc -l < "$WORK/compact.iyi.txt") compact lines)"
  status=1
else
  python3 - "$WORK/compact.iyi.txt" <<'PY'
import json, sys
n = 0
for i, line in enumerate(open(sys.argv[1]), 1):
    line = line.rstrip("\n")
    if not line:
        continue
    try:
        json.loads(line)
    except Exception as e:
        print(f"  line {i} is not JSON python3 accepts: {e}")
        print(f"    {line[:120]}")
        sys.exit(1)
    n += 1
print(f"  {n} compact documents are JSON python3 accepts")
PY
  if [ $? -ne 0 ]; then
    status=1
  fi
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" json-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/json-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when a repeated key is accepted"
mkdir -p "$WORK/patched_dup/std"
python3 - <<PY
src = open("$REPO/src/std/json.iyi").read()
old = 'return fail("duplicate key \\'#{key}\\'")'
new = 'return fail("duplicate key \\'#{key}\\'") if false'
if old not in src:
    raise SystemExit("patch site missing")
open("$WORK/patched_dup/std/json.iyi", "w").write(src.replace(old, new, 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched_dup:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_json_exercise.iyi" >"$WORK/dup.out" 2>&1; then
  echo "  the exercise PASSED with duplicate keys accepted"
  status=1
elif ! grep -q "duplicate key" "$WORK/dup.out"; then
  echo "  failed, but not at the duplicate-key check:"
  grep -m1 panic "$WORK/dup.out" || sed -n '1,8p' "$WORK/dup.out"
  status=1
else
  echo "  a repeated object key is caught"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/json exercise holds"
else
  echo "the std/json exercise did not hold"
fi
exit $status
