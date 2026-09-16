#!/usr/bin/env bash
# Exercises `std/nil`: singleton identity, hashing, conversions, IyiIO printing,
# try semantics, NilAssertionError, and nil-safety flow typing.
#
#     bash bench/std_nil_exercise.sh
#
# Proves:
#   * Nil singleton identity: object_id is 0, same? is true for nil and false
#     for references, clone and presence return nil.
#   * Equality and hashing: nil == nil, hash is 0 and stable.
#   * String conversions and IyiIO writing: to_s is empty, inspect is "nil",
#     to_s(io) writes nothing, and inspect(io) writes "nil".
#   * Control flow: try returns nil without yielding to the block.
#   * Nil-safety flow typing: truthiness narrowing, nil? predicate, and || defaulting.
#   * NilAssertionError and unwraps: default and custom error messages,
#     and not_nil panics on nil with the expected message.
#   * Broken implementations of hash, object_id, same?, inspect, and try are caught.
#
# Exits non-zero if any check fails.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_nil_exercise.iyi" \
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

echo "== the std/nil exercise, plain build"
build_and_run "plain" nil-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/nil-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every nil section reported"
for phrase in "== singleton and identity" "== equality and hashing" "== conversions and string forms" "== control flow and try" "== nil-safety flow typing" "== NilAssertionError"; do
  if ! grep -q "$phrase" "$WORK/nil-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" nil-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/nil-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
prove_fails() {
  local label="$1" name="$2" phrase="$3" replace="$4"
  mkdir -p "$WORK/$name/std"
  python3 -c "
import sys
src = open('$REPO/src/std/nil.iyi').read()
broken = $replace
if broken == src:
    sys.exit('patch did not apply')
open('$WORK/$name/std/nil.iyi', 'w').write(broken)
" || { echo "  $label: the patch did not apply"; status=1; return; }

  if IYI_PATH="$WORK/$name:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_nil_exercise.iyi" >"$WORK/$name.out" 2>&1; then
    echo "  $label: the exercise PASSED on broken module"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: failed, but not at '$phrase'"
    cat "$WORK/$name.out"
    status=1
    return
  fi
  echo "  $label: caught at '$phrase'"
}

prove_fails "hash returns non-zero" broken_hash "ASSERTION FAILED: hash is 0" \
  "src.replace('def hash : Int32\n    0\n  end', 'def hash : Int32\n    42\n  end')"

prove_fails "object_id returns non-zero" broken_obj_id "ASSERTION FAILED: object_id is 0" \
  "src.replace('0_u64', '99_u64')"

prove_fails "same? on nil returns false" broken_same "ASSERTION FAILED: same? with nil is true" \
  "src.replace('def same?(other : ::Nil) : ::Bool\n    true\n  end', 'def same?(other : ::Nil) : ::Bool\n    false\n  end')"

prove_fails "inspect(io) writes null" broken_inspect "ASSERTION FAILED: inspect(io) writes 'nil'" \
  "src.replace('io.print(\"nil\")', 'io.print(\"null\")')"

prove_fails "try yields to block" broken_try "ASSERTION FAILED: try does not yield to block" \
  "src.replace('def try(&)\n    self\n  end', 'def try(&)\n    yield self\n    self\n  end')"

echo
echo "== what not_nil refuses"
refuses() {
  local label="$1" name="$2" phrase="$3" code_body="$4"
  printf 'module main\n\nimport std/nil\n\n%s\n' "$code_body" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    cat "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    cat "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}

refuses "default nil unwrap" not_nil_default "Nil assertion failed" 'nil.not_nil'
refuses "custom nil unwrap message" not_nil_custom "value must not be nil" 'nil.not_nil("value must not be nil")'
refuses "explicit NilAssertionError raise" raise_err "explicit assertion failed" 'raise NilAssertionError.new("explicit assertion failed")'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/nil exercise holds"
else
  echo "the std/nil exercise did not hold"
fi
exit $status
