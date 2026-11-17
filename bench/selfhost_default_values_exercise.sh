#!/usr/bin/env bash
# Verify call-site magic defaults in emitted IR and in hosted/native executables.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export IYI_PATH="$REPO/src"
IYI="$REPO/bin/iyi"
"$IYI" build -o "$WORK/native" "$REPO/src/compiler/tools/compile_native.iyi"

fixture="$REPO/bench/fixtures/bodies_magic_payload.iyi"
"$WORK/native" "$fixture" -o "$WORK/magic.ir" --pipeline typed --emit ir
grep -F 'call iyicc i32 (i32) @"*magic_line<Int32>:Int32"(i32 17)' "$WORK/magic.ir"
grep -F 'call iyicc i32 (i32) @"*magic_end<Int32>:Int32"(i32 20)' "$WORK/magic.ir"
grep -F "$fixture" "$WORK/magic.ir"
grep -F "$REPO/bench/fixtures\\00" "$WORK/magic.ir"
grep -F 'call iyicc ptr (ptr) @"*magic_file<String>:String"' "$WORK/magic.ir"
grep -F 'call iyicc ptr (ptr) @"*magic_dir<String>:String"' "$WORK/magic.ir"

fixture="$REPO/bench/fixtures/bodies_magic_output.iyi"
"$IYI" build --prelude empty -o "$WORK/hosted" "$fixture"
"$WORK/native" "$fixture" -o "$WORK/native-out" --pipeline typed
"$WORK/hosted" > "$WORK/hosted.out"
"$WORK/native-out" > "$WORK/native.out"
printf '\016\021' > "$WORK/expected.out"
cmp "$WORK/expected.out" "$WORK/hosted.out"
cmp "$WORK/hosted.out" "$WORK/native.out"
echo 'magic call-site literals and executable output match'

caller="$REPO/bench/fixtures/bodies_magic_cross.iyi"
helper="$REPO/bench/fixtures/magic_site/helper.iyi"
expect_line() {
  got="$(sed -n "${2}p" "$1")"
  if [ "$got" != "$3" ]; then
    echo "fixture line $2 of $1 is '$got', expected '$3'"
    exit 1
  fi
}
expect_line "$caller" 19 'LibC.putchar(caller_line)'
expect_line "$caller" 20 'LibC.putchar(caller_line)'
expect_line "$caller" 21 'LibC.putchar(caller_line(40))'
expect_line "$caller" 24 'LibC.putchar(caller_end('
expect_line "$caller" 25 '))'
expect_line "$caller" 26 'outer'
expect_line "$caller" 27 'wrapped'
expect_line "$caller" 28 'named_magic(a: 11)'
expect_line "$caller" 29 'named_magic(c: 33, a: 12)'
expect_line "$caller" 30 'named_magic(b: "kept")'
expect_line "$helper" 12 '  nested('
expect_line "$helper" 13 '  )'
caller_dir="$(dirname "$caller")"
helper_dir="$(dirname "$helper")"
printf '\x13\x14\x28\x19\x0c\x0d\x07\x1b\x0b\x1c\x0c\x21\x1e\x1e' > "$WORK/cross.expected"
"$IYI" build --prelude empty -o "$WORK/cross.hosted" "$caller"
"$WORK/native" "$caller" -o "$WORK/cross.ir" --pipeline typed --emit ir
grep -F "$caller" "$WORK/cross.ir"
grep -F "$caller_dir\\00" "$WORK/cross.ir"
helper_file="$caller_dir/./magic_site/helper.iyi"
helper_dir_magic="$caller_dir/./magic_site"
grep -F "$helper_file" "$WORK/cross.ir"
grep -F "$helper_dir_magic\\00" "$WORK/cross.ir"
grep -F 'kept' "$WORK/cross.ir"
"$WORK/native" "$caller" -o "$WORK/cross.native" --pipeline typed
fixture="$REPO/bench/fixtures/bodies_magic_splat.iyi"
"$WORK/native" "$fixture" -o "$WORK/splat" --pipeline typed > "$WORK/splat.log" 2>&1 || true
if grep -F 'a call with default arguments or a splat' "$WORK/splat.log"; then
  echo 'primitive splat still reached lowering as a splat:'
  cat "$WORK/splat.log"
  exit 1
fi
if ! grep -F 'a primitive call has no receiver' "$WORK/splat.log"; then
  echo 'primitive splat did not reach the receiver check:'
  cat "$WORK/splat.log"
  exit 1
fi
echo 'primitive splat is arity-specific; the next refusal is the missing receiver'

"$WORK/cross.hosted" > "$WORK/cross.hosted.out"
"$WORK/cross.native" > "$WORK/cross.native.out"
if ! cmp "$WORK/cross.expected" "$WORK/cross.hosted.out"; then
  echo 'hosted cross-file magic output differs from the call-site coordinates'
  echo 'expected:'
  od -An -tx1 "$WORK/cross.expected"
  echo 'hosted:'
  od -An -tx1 "$WORK/cross.hosted.out"
  exit 1
fi
if ! cmp "$WORK/cross.hosted.out" "$WORK/cross.native.out"; then
  echo 'native cross-file magic output differs from hosted'
  echo 'native:'
  od -An -tx1 "$WORK/cross.native.out"
  exit 1
fi
echo 'cross-file magic coordinates, wrappers, and named omission match'

fixture="$REPO/bench/fixtures/bodies_union_magic_mismatch.iyi"
"$IYI" build -o "$WORK/typed" "$REPO/src/compiler/tools/typed_dump.iyi"
"$WORK/typed" "$fixture" "$REPO/src" > "$WORK/union-typed.log" 2>&1 || true
if ! grep -F 'untyped: not ported: differing union call-site defaults' "$WORK/union-typed.log"; then
  echo "union magic defaults changed reason or started typing:"
  cat "$WORK/union-typed.log"
  exit 1
fi
echo 'differing union call-site defaults stay refused'
