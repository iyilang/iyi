#!/usr/bin/env bash
# Exercises `std/comparable`.
#
#     bash bench/std_comparable_exercise.sh
#
# Proves the exercise holds plain and --release, that every comparison operator
# derived from <=> holds for less, equal, and greater values, that transitivity
# holds, that incomparable values evaluate to false, that clamp and between?
# work as specified, that a broken operator or helper is caught via IYI_PATH,
# and that clamping an exclusive range panics with a descriptive sentence.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_comparable_exercise.iyi" \
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

echo "== the std/comparable exercise, plain build"
build_and_run "plain" comp-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/comp-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every comparable section reported"
for phrase in "== operators" "== transitivity" "== incomparable" "== clamp" "== between"; do
  if ! grep -q "$phrase" "$WORK/comp-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" comp-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/comp-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"

prove_fails() {
  local label="$1" name="$2" pattern="$3" replacement="$4"
  python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/comparable.iyi").read_text()
old = """$pattern"""
if old not in src:
    raise SystemExit("patch site missing: " + repr(old))
Path("$WORK/patched/std/comparable.iyi").write_text(src.replace(old, """$replacement""", 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply for $label"
    status=1
  elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_comparable_exercise.iyi" >"$WORK/$name.out" 2>&1; then
    echo "  the exercise PASSED on a broken $label"
    status=1
  else
    echo "  a broken $label is caught"
  fi
}

prove_fails "less-than operator" broken_lt \
  'cmp ? cmp < 0 : false' \
  'cmp ? cmp <= 0 : false'

prove_fails "greater-than operator" broken_gt \
  'cmp ? cmp > 0 : false' \
  'cmp ? cmp >= 0 : false'

prove_fails "clamp max logic" broken_clamp \
  'return max_val if !max_val.nil? && self > max_val' \
  '# clamp max removed'

prove_fails "between? helper" broken_between \
  'self >= min_val && self <= max_val' \
  'self > min_val && self < max_val'

echo
echo "== what clamp refuses"
refuses() {
  local label="$1" name="$2" phrase="$3"
  cat >"$WORK/$name.iyi" <<'EOF'
import std/comparable
using std/comparable::{Comparable}

struct Score
  getter val : Int32
  def initialize(@val : Int32)
  end
end

impl Comparable(Score) for Score
  def <=>(other : Score) : Int32?
    if @val < other.val
      -1
    elsif @val > other.val
      1
    else
      0
    end
  end
end

Score.new(20).clamp(Score.new(10)...Score.new(30))
EOF
  if "$IYI" run "$WORK/$name.iyi" >"$WORK/$name.out" 2>&1; then
    echo "  FAIL ($label): did not panic"
    status=1
  elif ! grep -q "$phrase" "$WORK/$name.out"; then
    echo "  FAIL ($label): missing phrase: $phrase"
    cat "$WORK/$name.out"
    status=1
  else
    echo "  $label refuses with: $phrase"
  fi
}

refuses "clamping an exclusive range" clamp_exc "Can't clamp an exclusive range"

echo
if [ "$status" -eq 0 ]; then
  echo "the std/comparable exercise holds"
else
  echo "the std/comparable exercise did not hold"
fi
exit $status
