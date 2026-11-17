#!/usr/bin/env bash
# Diagnostic stubs never change strict compilation and stop when actually called.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
FIXTURE="$REPO/bench/fixtures/stub_refused.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo 'SKIP: the native executable is a Darwin arm64 Mach-O'
  exit 0
fi

check_stub() {
  "$IYI" build -o "$WORK/stage1" "$REPO/src/compiler/tools/compile_native.iyi" >"$WORK/build.log" 2>&1 || return 1
  codesign -v --strict "$WORK/stage1" || return 1
  "$WORK/stage1" "$FIXTURE" -o "$WORK/strict" --pipeline typed >"$WORK/strict.log" 2>&1 && return 1
  grep -q 'proc literal calls twice' "$WORK/strict.log" || return 1
  [ ! -e "$WORK/strict" ] || return 1
  "$WORK/stage1" "$FIXTURE" -o "$WORK/model" --pipeline typed --stub-refused >"$WORK/stub.log" 2>&1 || return 1
  grep -q 'DIAGNOSTIC BUILD' "$WORK/stub.log" || return 1
  grep -q 'StubExercise#refused' "$WORK/model.stubs" || return 1
  codesign -v --strict "$WORK/model" || return 1
  "$WORK/model" >"$WORK/normal.out" 2>"$WORK/normal.err"; local normal=$?
  "$WORK/hosted" >"$WORK/hosted.out" 2>"$WORK/hosted.err"; local hosted=$?
  [ "$normal" -eq "$hosted" ] && cmp -s "$WORK/normal.out" "$WORK/hosted.out" && cmp -s "$WORK/normal.err" "$WORK/hosted.err" || return 1
  "$WORK/model" hit >"$WORK/hit.out" 2>"$WORK/hit.err"; local hit=$?
  [ "$hit" -eq 70 ] && grep -q 'iyi: refused def hit at runtime: .*StubExercise#refused.*proc literal calls twice' "$WORK/hit.err"
}

"$IYI" build --prelude empty -o "$WORK/hosted" "$FIXTURE" >"$WORK/hosted.build.log" 2>&1 || { cat "$WORK/hosted.build.log"; exit 1; }
if ! check_stub; then
  echo 'FAIL: diagnostic stub behavior'
  for log in build strict stub hit; do [ ! -f "$WORK/$log.log" ] || cat "$WORK/$log.log"; done
  exit 1
fi
echo 'PASS: strict refusal, diagnostic build, unmodified path and fatal stub'
prove_mutation 'stub exits with status 70' "$REPO/src/compiler/lower/fun.iyi" 'b.const_int(m.types.int32, 70)' 'b.const_int(m.types.int32, 71)' -- check_stub || exit 1
