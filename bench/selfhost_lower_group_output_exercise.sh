#!/usr/bin/env bash
# A reused captured ProcLiteral must bind the callee's free output on every call.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
export IYI_PATH="$REPO/src"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"
fixture="$REPO/bench/fixtures/lowpool_generic_group_forward.iyi"
"$IYI" build -o "$WORK/hosted" "$fixture" > "$WORK/hosted.build.log" 2>&1 || { cat "$WORK/hosted.build.log"; exit 1; }
"$WORK/hosted" > "$WORK/hosted.out" 2>&1
hosted=$?

check_group_output() {
  if ! "$IYI" build -o "$WORK/stage" "$REPO/src/compiler/tools/compile_native.iyi" > "$WORK/build.log" 2>&1; then
    echo "INVALID: stage build failed" >&2
    [ "${_PM_ARMED:-0}" = 1 ] && return 0
    return 1
  fi
  codesign -v --strict "$WORK/stage" || return 1
  "$WORK/stage" "$fixture" -o "$WORK/native" --pipeline typed --prelude --probe-phase > "$WORK/stage.log" 2>&1 || return 1
  codesign -v --strict "$WORK/native" || return 1
  "$WORK/native" > "$WORK/native.out" 2>&1
  local actual=$?
  [ "$actual" = "$hosted" ] && cmp -s "$WORK/hosted.out" "$WORK/native.out"
}
check_group_output || { echo 'FAIL: nested group generic output does not match hosted'; exit 1; }
prove_mutation 'a reused captured block does not bind the free output' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '                if captured_block_type.is_a?(ProcInstanceType)' \
  '                if false && captured_block_type.is_a?(ProcInstanceType)' -- check_group_output || exit 1
echo 'nested group generic output: hosted/native match; mutation caught'
