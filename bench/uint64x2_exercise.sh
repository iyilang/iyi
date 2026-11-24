#!/usr/bin/env bash
# Exercise UInt64x2 on native and wasm32-wasi, including a broken primitive.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WASI_SDK_PATH="${WASI_SDK_PATH:-/opt/wasi-sdk}"
WASMTIME="${WASMTIME:-$HOME/.wasmtime/bin/wasmtime}"
CLANG="$WASI_SDK_PATH/bin/clang"
OBJDUMP="${LLVM_OBJDUMP:-$(command -v llvm-objdump || printf '%s' "$WASI_SDK_PATH/bin/llvm-objdump")}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/iyi-uint64x2.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() {
  local message="$1" log
  shift
  echo "FAIL: $message" >&2
  for log in "$@"; do
    if [ -f "$log" ]; then
      echo "--- $log ---" >&2
      cat "$log" >&2
    fi
  done
  exit 1
}
for tool in "$IYI" "$CLANG" "$OBJDUMP" "$WASMTIME"; do
  if [ ! -x "$tool" ]; then echo "missing executable: $tool" >&2; exit 1; fi
done

build_wasm() {
  local output="$1" source="$2"; shift 2
  local command
  command="$("$IYI" build --cross-compile --target wasm32-wasi "$@" -o "$output" "$source")" ||
    fail "$output: wasm compilation failed${command:+: $command}"
  case "$command" in
    cc\ *) command="\"$CLANG\" ${command#cc }" ;;
    *) fail "$output: unexpected cross-link command: $command" ;;
  esac
  eval "$command -o \"$output.wasm\"" || fail "$output: wasm link failed"
}

for mode in native native-release; do
  args=()
  [ "$mode" != native-release ] || args+=(--release --emit=llvm-ir)
  "$IYI" build "${args[@]}" -o "$WORK/$mode" "$REPO/bench/uint64x2_exercise.iyi" 2>"$WORK/$mode.build.log" ||
    fail "$mode: build failed" "$WORK/$mode.build.log"
  "$WORK/$mode" >"$WORK/$mode.out" ||
    fail "$mode: program failed" "$WORK/$mode.out"
  grep -qx 'ALL UINT64X2 CHECKS PASSED' "$WORK/$mode.out" ||
    fail "$mode: success marker missing" "$WORK/$mode.out"
  echo "$mode: $(tail -1 "$WORK/$mode.out")"
done

# The union payload is an integer array after lowering, so its vector
# member must not be lost when heap loads, stores and indirect copies are
# assigned an alignment. Each extract is from the relevant function.
awk '/^define .*AlignedMaybeVector#value=<Nil>/ { inside=1 }
     inside { print }
     inside && /^}/ { exit }' "$WORK/native-release.ll" >"$WORK/union-nil.ir"
awk '/^define .*vector_union_closure<[(]UInt64x2 [|] Nil[)]>/ { inside=1 }
     inside { print }
     inside && /^}/ { exit }' "$WORK/native-release.ll" >"$WORK/union-closure.ir"
awk '/^define .*~procProc.*uint64x2_exercise/ { inside=1 }
     inside { print }
     inside && /^}/ { exit }' "$WORK/native-release.ll" >"$WORK/union-closure-body.ir"
awk '/^define .*AlignedLargeUnion#initialize/ { inside=1 }
     inside { print }
     inside && /^}/ { exit }' "$WORK/native-release.ll" >"$WORK/union-large.ir"
cat "$WORK/union-nil.ir" "$WORK/union-closure.ir" "$WORK/union-closure-body.ir" "$WORK/union-large.ir" >"$WORK/union.ir"
union_alignment_ok() {
  grep -Eq 'store i128 0, ptr .*align 8([,[:space:]]|$)|llvm.memset.*align (4|8) [^,]*%self' "$1" &&
    grep -Eq 'store %.*UInt64x2.*Nil.*align 8([,[:space:]]|$)' "$1" &&
    grep -Eq 'load %.*UInt64x2.*Nil.*align 8([,[:space:]]|$)' "$1" &&
    grep -Eq 'llvm.mem(move|cpy).*align 8.*%self,.*align 8.*%value' "$1" &&
    ! grep -Eq '(load|store) %.*UInt64x2.*Nil.*align (16|32|64)([,[:space:]]|$)' "$1" &&
    ! grep -Eq 'llvm.memset.*align (16|32|64) [^,]*%self' "$1"
}
if ! union_alignment_ok "$WORK/union.ir"; then
  echo 'union alignment: nil, closure or indirect union copy has the wrong alignment' >&2
  cat "$WORK/union.ir" >&2
  exit 1
fi
for pattern in 'llvm.memset.*%self' 'store %.*UInt64x2.*Nil' 'load %.*UInt64x2.*Nil' 'llvm.mem(move|cpy).*%self'; do
  awk -v pattern="$pattern" '$0 ~ pattern { sub(/align [48]/, "align 16") } { print }' "$WORK/union.ir" >"$WORK/union-broken.ir"
  if union_alignment_ok "$WORK/union-broken.ir"; then
    echo "union alignment: mutation escaped for $pattern" >&2; exit 1
  fi
done
echo 'union alignment: nil zeroing (align 8, or the memset LLVM forms at align 4), closure load/store and indirect copy use align 8 or less; each regression was caught'

cat >"$WORK/share-vector.iyi" <<'IYI'
@[Unsafe("Share is a trusted type annotation")]
struct VectorRecord
  def initialize(@value : UInt64x2)
  end
  getter value : UInt64x2
end
@[Share]
struct TrustedVector(T)
  def initialize(@value : T)
  end
  getter value : T
end
vector = UInt64x2.new(42_u64, 17_u64)
record = VectorRecord.new(vector)
trusted = TrustedVector(UInt64x2).new(vector)
thread = IyiThread.start do
  raise "thread vector changed" unless vector.low == 42_u64 && vector.high == 17_u64
  raise "thread record changed" unless record.value.low == 42_u64 && record.value.high == 17_u64
  raise "thread trusted vector changed" unless trusted.value.low == 42_u64 && trusted.value.high == 17_u64
  nil
end
thread.join
puts "thread vector and Share records passed"
IYI
"$IYI" build --release -o "$WORK/share-vector" "$WORK/share-vector.iyi" || fail "Share: build failed"
"$WORK/share-vector" >"$WORK/share-vector.out" || fail "Share: program failed" "$WORK/share-vector.out"
grep -qx 'thread vector and Share records passed' "$WORK/share-vector.out" ||
  fail "Share: success marker missing" "$WORK/share-vector.out"
awk '{ sub(/getter value : UInt64x2/, "property value : UInt64x2"); print }' "$WORK/share-vector.iyi" >"$WORK/not-share-vector.iyi"
if "$IYI" build --no-codegen "$WORK/not-share-vector.iyi" >"$WORK/not-share-vector.out" 2>&1; then
  fail "Share: a mutable vector record crossed a thread boundary" "$WORK/not-share-vector.out"
fi
grep -q 'not Share' "$WORK/not-share-vector.out" ||
  fail "Share: mutable vector was refused for the wrong reason" "$WORK/not-share-vector.out"
echo 'Share: vector, immutable record and trusted generic crossed a thread; mutable record was refused'

# The headed object has only eight-byte alignment. Check the exact store
# in the emitted constructor, not an unrelated vector in the runtime.
awk '/^define .*AlignedVector#initialize/ { inside=1 }
     inside { print }
     inside && /^}/ { exit }' "$WORK/native-release.ll" >"$WORK/field.ir"
field_alignment_ok() {
  grep -Eq 'store <2 x i64>.*align 8([,[:space:]]|$)' "$1" &&
    ! grep -Eq 'store <2 x i64>.*align (16|32|64)([,[:space:]]|$)' "$1"
}
if ! field_alignment_ok "$WORK/field.ir"; then
  echo 'field alignment: emitted constructor does not store the vector at align 8' >&2
  cat "$WORK/field.ir" >&2
  exit 1
fi
awk '{if (/store <2 x i64>/) sub(/align 8/, "align 16"); print}' "$WORK/field.ir" >"$WORK/field-broken.ir"
grep -q 'align 16' "$WORK/field-broken.ir" ||
  fail "field alignment: mutation did not change the IR" "$WORK/field-broken.ir"
if field_alignment_ok "$WORK/field-broken.ir"; then
  echo 'field alignment: align 16 mutation escaped the guard' >&2; exit 1
fi
echo 'field alignment: align 8 in LLVM IR; restoring align 16 is caught'
for mode in wasm-plain wasm-plain-simd wasm wasm-simd; do
  args=()
  case "$mode" in wasm|wasm-simd) args+=(--release) ;; esac
  case "$mode" in *-simd) args+=(--mattr +simd128) ;; esac
  build_wasm "$WORK/$mode" "$REPO/bench/uint64x2_exercise.iyi" "${args[@]}"
  "$WASMTIME" "$WORK/$mode.wasm" >"$WORK/$mode.out" ||
    fail "$mode: wasm program failed" "$WORK/$mode.out"
  grep -qx 'ALL UINT64X2 CHECKS PASSED' "$WORK/$mode.out" ||
    fail "$mode: success marker missing" "$WORK/$mode.out"
  echo "$mode: $(tail -1 "$WORK/$mode.out")"
done
for mode in native-release wasm-plain wasm-plain-simd wasm wasm-simd; do
  cmp "$WORK/native.out" "$WORK/$mode.out" ||
    fail "$mode: output differs from native" "$WORK/native.out" "$WORK/$mode.out"
done
cat "$WORK/native.out"

# LLVM 18's wasm disassembler can loop writing invalid_type indefinitely.
# A bounded pipe makes that failure visible instead of filling the disk.
disassemble() {
  if ! "$OBJDUMP" -d "$1" | head -c 4000000 >"$2"; then
    echo "disassembly failed or exceeded 4 MB: $1" >&2; return 1
  fi
}
disassemble "$WORK/wasm.wasm" "$WORK/scalar.dis"
disassemble "$WORK/wasm-simd.wasm" "$WORK/simd.dis"
if grep -Eq '(i64x2|v128)\.' "$WORK/scalar.dis"; then
  echo 'scalar module unexpectedly contains SIMD128 instructions' >&2; exit 1
fi
awk '/^[[:xdigit:]]+ <\*check_pair</ { inside=1; print; next }
     inside && /^[[:xdigit:]]+ </ { exit }
     inside && /(i64x2|v128)\./ { print }' "$WORK/simd.dis" >"$WORK/simd.instructions"
grep -q 'v128.xor' "$WORK/simd.instructions" ||
  fail "SIMD disassembly: v128.xor missing" "$WORK/simd.instructions"
grep -q 'i64x2.mul' "$WORK/simd.instructions" ||
  fail "SIMD disassembly: i64x2.mul missing" "$WORK/simd.instructions"
echo 'simd128 disassembly of check_pair (scalar module contains no v128/i64x2 instructions):'
grep -E 'v128\.(xor|and|or)|i64x2\.(add|sub|mul|shl|shr_u)' "$WORK/simd.instructions"

cat >"$WORK/flag.iyi" <<'EOF'
{% if flag?(:simd128) %}
  puts "simd128=true"
{% else %}
  puts "simd128=false"
{% end %}
EOF
"$IYI" build -o "$WORK/flag-native" "$WORK/flag.iyi" 2>"$WORK/flag-native.log" ||
  fail "native flag: build failed" "$WORK/flag-native.log"
actual="$("$WORK/flag-native")" || fail "native flag: program failed: $actual"
[ "$actual" = 'simd128=false' ] || fail "native flag: expected simd128=false, got: $actual"
"$IYI" build --mattr +simd128 -o "$WORK/flag-native-feature" "$WORK/flag.iyi" 2>"$WORK/flag-native-feature.log" ||
  fail "native feature flag: build failed" "$WORK/flag-native-feature.log"
actual="$("$WORK/flag-native-feature")" || fail "native feature flag: program failed: $actual"
[ "$actual" = 'simd128=false' ] || fail "native feature flag: expected simd128=false, got: $actual"
echo 'flag native with +simd128: simd128=false'
for flags in scalar enabled disabled reenabled; do
  args=()
  expected=false
  case "$flags" in
    enabled) args+=(--mattr +simd128); expected=true ;;
    disabled) args+=(--mattr +simd128,-simd128) ;;
    reenabled) args+=(--mattr=-simd128,+simd128); expected=true ;;
  esac
  build_wasm "$WORK/flag-$flags" "$WORK/flag.iyi" "${args[@]}"
  actual="$("$WASMTIME" "$WORK/flag-$flags.wasm")" || fail "flag $flags: wasm program failed: $actual"
  [ "$actual" = "simd128=$expected" ] || { echo "flag $flags: $actual" >&2; exit 1; }
  echo "flag wasm $flags: $actual"
done

cat >"$WORK/forbidden.iyi" <<'EOF'
@[Unsafe("tests the external ABI refusal")]
lib LibVectorProbe
  fun bad(value : UInt64x2) : UInt64x2
end
EOF
if "$IYI" build --no-codegen "$WORK/forbidden.iyi" >"$WORK/forbidden.log" 2>&1; then
  fail "external vector ABI unexpectedly accepted" "$WORK/forbidden.log"
fi
grep -q 'UInt64x2 has no C ABI' "$WORK/forbidden.log" ||
  fail "external vector ABI: refused for the wrong reason" "$WORK/forbidden.log"
echo "no-codegen FFI refusal: $(grep -m1 'UInt64x2 has no C ABI' "$WORK/forbidden.log")"

printf '%s\n' 'puts "compatibility prelude ok"' >"$WORK/compat.iyi"
"$IYI" build --crystal -o "$WORK/compat" "$WORK/compat.iyi" 2>"$WORK/compat.log" ||
  fail "compatibility prelude: build failed" "$WORK/compat.log"
actual="$("$WORK/compat")" || fail "compatibility prelude: program failed: $actual"
[ "$actual" = 'compatibility prelude ok' ] || fail "compatibility prelude: unexpected output: $actual"
printf '%s\n' 'x = uninitialized UInt64x2' >"$WORK/compat-vector.iyi"
if "$IYI" build --crystal --no-codegen "$WORK/compat-vector.iyi" >"$WORK/compat-vector.log" 2>&1; then
  fail "--crystal unexpectedly exposed the iyi-prelude vector" "$WORK/compat-vector.log"
fi
grep -q 'undefined constant UInt64x2' "$WORK/compat-vector.log" ||
  fail "--crystal: vector was refused for the wrong reason" "$WORK/compat-vector.log"
echo 'Compatibility prelude: ordinary program works, UInt64x2 is unavailable'

mkdir -p "$WORK/app" "$WORK/mods"
cat >"$WORK/app/vector.iyi" <<'EOF'
module app/vector
pub def mix(a : UInt64x2, b : UInt64x2) : UInt64x2
  (a ^ b) &+ UInt64x2.splat(1_u64)
end
EOF
cat >"$WORK/consumer.iyi" <<'EOF'
module consumer
import app/vector
value = App::Vector.mix(UInt64x2.new(9_u64, 20_u64), UInt64x2.new(3_u64, 6_u64))
puts value.low
puts value.high
EOF
IYI_PATH="$WORK:$REPO/src" "$IYI" build --emit-iyimod "$WORK/mods" -o "$WORK/source" "$WORK/consumer.iyi" ||
  fail "artifact: source build failed"
[ -f "$WORK/mods/app/vector.iyimod" ] || fail "vector artifact missing"
mv "$WORK/app/vector.iyi" "$WORK/vector-source.saved"
IYI_PATH="$WORK:$REPO/src" "$IYI" build --use-iyimod "$WORK/mods" -o "$WORK/artifact" "$WORK/consumer.iyi" ||
  fail "artifact: artifact-backed build failed"
"$WORK/source" >"$WORK/source.out" || fail "artifact: source program failed" "$WORK/source.out"
"$WORK/artifact" >"$WORK/artifact.out" || fail "artifact: artifact-backed program failed" "$WORK/artifact.out"
printf '11\n19\n' >"$WORK/expected.out"
cmp "$WORK/source.out" "$WORK/expected.out" ||
  fail "artifact: source output differs from expected" "$WORK/source.out"
cmp "$WORK/source.out" "$WORK/artifact.out" ||
  fail "artifact: source and artifact output differ" "$WORK/source.out" "$WORK/artifact.out"
echo 'artifact: vector signature and body agree with source (11, 19), source removed for import'

mkdir -p "$WORK/broken/iyi"
cp -R "$REPO/src/iyi/." "$WORK/broken/iyi/"
awk '{sub(/@\[Primitive\(:uint64x2_xor\)\]/, "@[Primitive(:uint64x2_or)]"); print}' \
  "$REPO/src/iyi/primitives.iyi" >"$WORK/broken/iyi/primitives.iyi"
grep -A1 'Primitive(:uint64x2_or)' "$WORK/broken/iyi/primitives.iyi" | grep -q 'def \^' ||
  fail "broken xor: mutation did not change the primitive"
IYI_PATH="$WORK/broken:$REPO/src" "$IYI" build -o "$WORK/broken/prog" "$REPO/bench/uint64x2_exercise.iyi" 2>"$WORK/broken/build.log" ||
  fail "broken xor: build failed" "$WORK/broken/build.log"
set +e
"$WORK/broken/prog" >"$WORK/broken/out" 2>&1
code=$?
set -e
if [ "$code" -eq 0 ] || grep -q 'ALL UINT64X2 CHECKS PASSED' "$WORK/broken/out"; then
  fail "broken xor primitive escaped the exercise" "$WORK/broken/out"
fi
grep -q 'xor: wrong' "$WORK/broken/out" ||
  fail "broken xor: program failed for the wrong reason" "$WORK/broken/out"
echo "broken xor: caught (exit $code, $(grep -m1 'xor: wrong' "$WORK/broken/out"))"
echo 'ALL UINT64X2 ACCEPTANCE CHECKS PASSED'
