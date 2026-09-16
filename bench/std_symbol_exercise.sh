#!/usr/bin/env bash
# Exercises `std/symbol`.
#
#     bash bench/std_symbol_exercise.sh
#
# Proves the exercise holds plain and --release, that symbol identity,
# interning, string conversion, ordering (<=>, <, <=, >, >=), inspect
# quoting, and named argument quoting hold, and that broken ordering,
# dropped inspect quotes, or raw named arguments fail with a clear assertion.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_symbol_exercise.iyi" \
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

echo "== the std/symbol exercise, plain build"
build_and_run "plain" symbol-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/symbol-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every symbol section reported"
for phrase in "== identity and equality" "== string conversion" "== ordering" "== inspect" "== quote helpers"; do
  if ! grep -q "$phrase" "$WORK/symbol-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" symbol-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/symbol-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
prove_fails() { # prove_fails <label> <dir> <phrase> <old> <new>
  local label="$1" dir="$2" phrase="$3" old="$4" new="$5"
  mkdir -p "$WORK/$dir/std"
  python3 - "$old" "$new" "$WORK/$dir/std/symbol.iyi" <<'PY'
import sys
from pathlib import Path
old = sys.argv[1]
new = sys.argv[2]
out_path = Path(sys.argv[3])
src = Path("src/std/symbol.iyi").read_text()
if old not in src:
    raise SystemExit(f"patch site missing: {old!r}")
out_path.write_text(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src:$REPO/samples/iyi" "$IYI" build -o "$WORK/$dir/program" "$REPO/bench/std_symbol_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched module did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at the expected check ('$phrase')"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

prove_fails "inverted <=> ordering" inv_order \
  "ASSERTION FAILED: <=> less" \
  's1 < s2 ? -1 : 1' \
  's1 < s2 ? 1 : -1'

prove_fails "inspect omits required quotes" dropped_quotes \
  "ASSERTION FAILED: inspect with space" \
  ':\"" + val + "\""' \
  ':" + val'

prove_fails "quote_for_named_argument leaves special names raw" raw_named \
  "ASSERTION FAILED: quote_for_named_argument _" \
  '"\"" + string + "\""' \
  'string'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/symbol exercise holds"
else
  echo "the std/symbol exercise did not hold"
fi
exit $status
