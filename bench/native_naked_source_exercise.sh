#!/usr/bin/env bash
# A source-level @[Naked] must survive lowering and reach the native backend.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
WORK="$(mktemp -d)" || exit 1
WORK_NATIVE="$(native_path "$WORK")" || exit 1
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/native_signature.sh"
fixture="$REPO_NATIVE/bench/fixtures/lownaked_return.iyi"

"$IYI" build --prelude empty --no-debug -o "$WORK_NATIVE/hosted$EXE" "$fixture" > "$WORK/hosted.log" 2>&1 || { cat "$WORK/hosted.log"; exit 1; }
"$WORK/hosted$EXE"; hosted=$?
[ "$hosted" = 42 ] || { echo "hosted fixture returned $hosted, expected 42"; exit 1; }

naked_source_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/stage1$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/stage1.log" 2>&1; then
    cat "$WORK/stage1.log"
    return 2
  fi
  if [ "$HOST_ID" = darwin-arm64 ] && ! native_signature_ok "$WORK/stage1$EXE"; then return 2; fi
  if ! "$WORK/stage1$EXE" "$fixture" -o "$WORK_NATIVE/naked.ir" --pipeline typed --emit ir > "$WORK/emit.log" 2>&1; then
    cat "$WORK/emit.log"
    return 2
  fi
  if ! grep -E '^define .*@naked_value\(\).*naked' "$WORK/naked.ir" >/dev/null; then
    echo "decisive: naked_value lost its naked attribute"
    return 1
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then return 0; fi
  if ! "$WORK/stage1$EXE" "$fixture" -o "$WORK_NATIVE/native" --pipeline typed > "$WORK/native.log" 2>&1; then
    cat "$WORK/native.log"
    return 2
  fi
  native_signature_ok "$WORK/native" || return 2
  "$WORK/native"; native=$?
  [ "$native" -lt 128 ] || return 2
  [ "$native" = "$hosted" ]
}

naked_source_check || { echo "naked-source baseline failed"; exit 1; }
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "naked source: native Mach-O signature verification and execution require macOS arm64"
fi
prove_mutation "Naked annotation is dropped before native selection" "$REPO/src/compiler/lower/lower.iyi" \
  '  fn.attrs << Attribute.new("naked", 0_u64, nil, nil) if rec.naked' '  nil' -- naked_source_check || exit 1
printf 'naked-source: hosted exit %s, IR annotation mutation caught (1/1 attempted, 0 host-limited)\n' "$hosted"
