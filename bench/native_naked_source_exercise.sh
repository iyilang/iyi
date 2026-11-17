#!/usr/bin/env bash
# A source-level @[Naked] must survive lowering and reach the native backend.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"
fixture="$REPO/bench/fixtures/lownaked_return.iyi"

"$IYI" build --prelude empty --no-debug -o "$WORK/hosted" "$fixture" > "$WORK/hosted.log" 2>&1 || { cat "$WORK/hosted.log"; exit 1; }
"$WORK/hosted"; hosted=$?
[ "$hosted" = 42 ] || { echo "hosted fixture returned $hosted, expected 42"; exit 1; }

naked_source_check() {
  "$IYI" build -o "$WORK/stage1" "$REPO/src/compiler/tools/compile_native.iyi" > "$WORK/stage1.log" 2>&1 || return 1
  codesign -v --strict "$WORK/stage1" || return 1
  "$WORK/stage1" "$fixture" -o "$WORK/naked.ir" --pipeline typed --emit ir > "$WORK/emit.log" 2>&1 || return 1
  grep -E '^define .*@naked_value\(\).*naked' "$WORK/naked.ir" >/dev/null || return 1
  "$WORK/stage1" "$fixture" -o "$WORK/native" --pipeline typed > "$WORK/native.log" 2>&1 || return 1
  codesign -v --strict "$WORK/native" || return 1
  "$WORK/native"; native=$?
  [ "$native" = "$hosted" ]
}

naked_source_check || { echo "naked-source baseline failed"; exit 1; }
prove_mutation "Naked annotation is dropped before native selection" "$REPO/src/compiler/lower/lower.iyi" \
  '  fn.attrs << Attribute.new("naked", 0_u64, nil, nil) if rec.naked' '  nil' -- naked_source_check || exit 1
printf 'naked-source: hosted and native exit %s, annotation mutation caught\n' "$hosted"
