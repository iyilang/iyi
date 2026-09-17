#!/usr/bin/env bash
# Exercises `std/path`: POSIX and Windows names, expand, relative_to.
#
#     bash bench/std_path_exercise.sh
#
# The expand checks read HOME and PWD from the environment; this script
# pins both so the answers are the same on every machine.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src:$REPO/samples/iyi"
export HOME=/home/gate
export PWD=/pwd/gate

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_path_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  grep -v '^oracle ' "$WORK/$name.out" | sed 's/^/  /'
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/path exercise, plain build"
build_and_run "plain" path-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/path-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every path section reported"
for phrase in "== normalize corpus" "== join" "== relative_to" "== expand" "== windows kind" "== path comparison"; do
  if ! grep -q "$phrase" "$WORK/path-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  normalize, join, relative_to, expand, windows and Comparable all reported"

echo
echo "== normalize and relpath against python3 posixpath"
python3 - "$WORK/path-plain.out" <<'PY'
import posixpath, sys
status = 0
for line in open(sys.argv[1]):
    if not line.startswith("oracle "):
        continue
    kind, *rest = line.rstrip("\n").split("\t")
    kind = kind.split()[1]
    if kind == "normpath":
        name, got = rest
        expect = posixpath.normpath(name)
        if got != expect:
            print(f"  FAIL normpath {name!r}: iyi {got!r} python {expect!r}")
            status = 1
    elif kind == "relpath":
        name, base, got = rest
        expect = posixpath.relpath(name, base)
        if got != expect:
            print(f"  FAIL relpath {name!r} {base!r}: iyi {got!r} python {expect!r}")
            status = 1
sys.exit(status)
PY
if [ $? -ne 0 ]; then
  status=1
else
  echo "  every oracle line agrees with posixpath"
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" path-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/path-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when .. is not folded"
mkdir -p "$WORK/patched_dot/std"
python3 - <<PY
src = open("$REPO/src/std/path.iyi").read()
old = 'elsif seg == ".."'
# break only the first when ".." in normalize if present
if old not in src:
    raise SystemExit("patch site missing")
open("$WORK/patched_dot/std/path.iyi", "w").write(src.replace(old, 'elsif seg == "..x"', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched_dot:$REPO/src:$REPO/samples/iyi" HOME=/home/gate PWD=/pwd/gate "$IYI" run "$REPO/bench/std_path_exercise.iyi" >"$WORK/dot.out" 2>&1; then
  echo "  the exercise PASSED with .. not folded"
  status=1
else
  echo "  a normalize that leaves .. is caught"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/path exercise holds"
else
  echo "the std/path exercise did not hold"
fi
exit $status
