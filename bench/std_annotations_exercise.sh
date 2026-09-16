#!/usr/bin/env bash
# Exercises `std/annotations`.
#
#     bash bench/std_annotations_exercise.sh
#
# Proves the exercise holds plain and --release, that an unexported annotation
# is caught by using, and what the annotations refuse: non-string messages for
# Deprecated and Experimental, and unrecognized named arguments for TargetFeature.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_annotations_exercise.iyi" \
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

echo "== the std/annotations exercise, plain build"
build_and_run "plain" annotations-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/annotations-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every annotations section reported"
for phrase in "== flags" "== deprecated" "== experimental" "== target_feature" "== link"; do
  if ! grep -q "$phrase" "$WORK/annotations-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" annotations-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/annotations-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/annotations.iyi").read_text()
old = 'pub annotation Flags'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/annotations.iyi").write_text(src.replace(old, 'annotation Flags', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_annotations_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  an unexported annotation is caught"
fi

echo
echo "== what annotations refuse"
refuses() { # refuses <label> <name> <phrase> <code_snippet>
  local label="$1" name="$2" phrase="$3" snippet="$4"
  printf 'import std/annotations\nusing std/annotations::{Deprecated, Experimental, TargetFeature}\n%s\n' "$snippet" > "$WORK/$name.iyi"
  if "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build.log" 2>&1; then
    echo "  $label: unexpectedly succeeded"
    status=1
    return 1
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.build.log"; then
    echo "  $label: failed without expected error ($phrase)"
    sed -n '1,6p' "$WORK/$name.build.log" | sed 's/^/    /'
    status=1
    return 1
  fi
  printf '  %s: refused with "%s"\n' "$label" "$phrase"
}

refuses "non-string Deprecated message" bad_dep "first argument must be a String" \
  $'@[Deprecated(123)]\ndef bad_dep\nend'
refuses "non-string Experimental message" bad_exp "first argument must be a String" \
  $'@[Experimental(456)]\ndef bad_exp\nend'
refuses "invalid TargetFeature named argument" bad_tf "no argument named 'invalid', expected 'cpu'" \
  $'class Simd\n  @[TargetFeature(invalid: "cpu")]\n  def bad_tf\n  end\nend'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/annotations exercise holds"
else
  echo "the std/annotations exercise did not hold"
fi
exit $status
