#!/usr/bin/env bash
# Exercises `std/levenshtein`.
#
#     bash bench/std_levenshtein_exercise.sh
#
# Proves the exercise holds plain and --release, that all sections report,
# and that a broken distance calculation is caught.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_levenshtein_exercise.iyi" \
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

echo "== the std/levenshtein exercise, plain build"
build_and_run "plain" levenshtein-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/levenshtein-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every levenshtein section reported"
for phrase in \
  "== identical strings" \
  "== empty against non-empty" \
  "== single edit kinds" \
  "== multiple edits and classical distances" \
  "== transposition" \
  "== multibyte and unicode" \
  "== symmetry" \
  "== finder and candidate search" \
  "== finder transposition (OSA)"; do
  if ! grep -q "$phrase" "$WORK/levenshtein-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" levenshtein-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/levenshtein-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"

# Mutation 1: Broken identity short-circuit
mkdir -p "$WORK/patched1/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/levenshtein.iyi").read_text()
old = 'return 0 if string1 == string2'
if old not in src:
    raise SystemExit("patch site missing: return 0")
Path("$WORK/patched1/std/levenshtein.iyi").write_text(src.replace(old, 'return 1 if string1 == string2', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the identity patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched1:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_levenshtein_exercise.iyi" >"$WORK/mut1.out" 2>&1; then
  echo "  the exercise PASSED on broken identity"
  status=1
else
  echo "  a broken identity check is caught"
fi

# Mutation 2: Zero substitution cost
mkdir -p "$WORK/patched2/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/levenshtein.iyi").read_text()
old = 'sub_cost = s[i] == t[j] ? 0 : 1'
if old not in src:
    raise SystemExit("patch site missing: sub_cost")
Path("$WORK/patched2/std/levenshtein.iyi").write_text(src.replace(old, 'sub_cost = 0', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the sub_cost patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched2:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_levenshtein_exercise.iyi" >"$WORK/mut2.out" 2>&1; then
  echo "  the exercise PASSED on zero substitution cost"
  status=1
else
  echo "  a broken substitution cost is caught"
fi

# Mutation 3: Finder scores with classic distance (transposition costs 2)
mkdir -p "$WORK/patched3/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/levenshtein.iyi").read_text()
old = 'dist = Levenshtein.osa_distance(@target, name)'
if old not in src:
    raise SystemExit("patch site missing: osa_distance in Finder")
Path("$WORK/patched3/std/levenshtein.iyi").write_text(src.replace(old, 'dist = Levenshtein.distance(@target, name)', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the finder-distance patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched3:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_levenshtein_exercise.iyi" >"$WORK/mut3.out" 2>&1; then
  echo "  the exercise PASSED on finder using classic distance"
  status=1
else
  echo "  a finder that ignores transposition is caught"
fi

# Mutation 4: a method the prelude does not have, instead of bytesize == size
mkdir -p "$WORK/patched4/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/levenshtein.iyi").read_text()
old = 'if string1.bytesize == string1.size && string2.bytesize == string2.size'
if old not in src:
    raise SystemExit("patch site missing: bytesize == size")
Path("$WORK/patched4/std/levenshtein.iyi").write_text(src.replace(old, 'if string1.single_byte_optimizable? && string2.single_byte_optimizable?', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the single-byte-optimizable patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched4:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_levenshtein_exercise.iyi" >"$WORK/mut4.out" 2>&1; then
  echo "  the exercise PASSED with single_byte_optimizable?"
  status=1
else
  echo "  a method the prelude does not have is caught"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "std/levenshtein: all checks passed"
else
  echo "std/levenshtein: exercise failed"
fi
exit $status
