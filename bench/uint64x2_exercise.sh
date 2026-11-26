#!/usr/bin/env bash
# Exercise UInt64x2 on wasm32-wasi, including a broken primitive.
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
  command="$("$IYI" build --cross-compile --target wasm32-wasi "$@" -o "$output.raw" "$source")" ||
    fail "$output: wasm compilation failed${command:+: $command}"
  if [ -f "$output.raw.ll" ]; then mv "$output.raw.ll" "$output.ll"; fi
  case "$command" in
    cc\ *) command="\"$CLANG\" ${command#cc }" ;;
    *) fail "$output: unexpected cross-link command: $command" ;;
  esac
  eval "$command -o \"$output.wasm\"" || fail "$output: wasm link failed"
}

for mode in wasm-plain wasm-plain-simd wasm wasm-simd; do
  args=()
  case "$mode" in wasm|wasm-simd) args+=(--release --emit=llvm-ir) ;; esac
  case "$mode" in *-simd) args+=(--mattr +simd128) ;; esac
  build_wasm "$WORK/$mode" "$REPO/bench/uint64x2_exercise.iyi" "${args[@]}"
  "$WASMTIME" "$WORK/$mode.wasm" >"$WORK/$mode.out" ||
    fail "$mode: wasm program failed" "$WORK/$mode.out"
  grep -qx 'ALL UINT64X2 CHECKS PASSED' "$WORK/$mode.out" ||
    fail "$mode: success marker missing" "$WORK/$mode.out"
  echo "$mode: $(tail -1 "$WORK/$mode.out")"
done
for mode in wasm-plain-simd wasm wasm-simd; do
  cmp "$WORK/wasm-plain.out" "$WORK/$mode.out" ||
    fail "$mode: output differs from scalar wasm" "$WORK/wasm-plain.out" "$WORK/$mode.out"
done
cat "$WORK/wasm-plain.out"

# The union payload is an integer array after lowering, so its vector
# member must not be lost when heap loads, stores and indirect copies are
# assigned an alignment. Each extract is from the relevant function.
awk '/^define .*AlignedMaybeVector#value=<Nil>/ { inside=1 }
     inside { print }
     inside && /^}/ { exit }' "$WORK/wasm-simd.ll" >"$WORK/union-nil.ir"
awk '/^define .*vector_union_closure<[(]UInt64x2 [|] Nil[)]>/ { inside=1 }
     inside { print }
     inside && /^}/ { exit }' "$WORK/wasm-simd.ll" >"$WORK/union-closure.ir"
awk '/^define .*~procProc.*uint64x2_exercise/ { inside=1 }
     inside { print }
     inside && /^}/ { exit }' "$WORK/wasm-simd.ll" >"$WORK/union-closure-body.ir"
awk '/^define .*AlignedLargeUnion#initialize/ { inside=1 }
     inside { print }
     inside && /^}/ { exit }' "$WORK/wasm-simd.ll" >"$WORK/union-large.ir"
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

# wasm32 has no runtime threads. This declaration exercises the compiler's
# IyiThread.start capture boundary at type-check time, not a real thread.
class IyiThread
  def self.start(&block : -> Nil)
    block.call
    IyiThread.new
  end

  def join : Nil
  end
end

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
"$IYI" build --cross-compile --target wasm32-wasi -o "$WORK/share-vector" "$WORK/share-vector.iyi" ||
  fail "Share: wasm compilation failed"
awk '{ sub(/getter value : UInt64x2/, "property value : UInt64x2"); print }' "$WORK/share-vector.iyi" >"$WORK/not-share-vector.iyi"
if "$IYI" build --cross-compile --target wasm32-wasi -o "$WORK/not-share-vector" "$WORK/not-share-vector.iyi" >"$WORK/not-share-vector.out" 2>&1; then
  fail "Share: a mutable vector record crossed a thread boundary" "$WORK/not-share-vector.out"
fi
grep -q 'not Share' "$WORK/not-share-vector.out" ||
  fail "Share: mutable vector was refused for the wrong reason" "$WORK/not-share-vector.out"
echo 'Share: wasm accepts vector, immutable record and trusted generic; mutable record was refused'

# The headed object has only eight-byte alignment. Check the exact store
# in the emitted constructor, not an unrelated vector in the runtime.
awk '/^define .*AlignedVector#initialize/ { inside=1 }
     inside { print }
     inside && /^}/ { exit }' "$WORK/wasm-simd.ll" >"$WORK/field.ir"
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
if "$IYI" build --target wasm32-wasi --no-codegen "$WORK/forbidden.iyi" >"$WORK/forbidden.log" 2>&1; then
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

# Wide integers share the heap alignment rule with vectors on native targets.
cat >"$WORK/int128.iyi" <<'IYI'
import std/int
class Int128Field
  def initialize(@value : Int128)
  end
  @[NoInline]
  def value : Int128
    @value
  end
end
class Int128Union
  def initialize(@value : Int128 | Nil)
  end
  @[NoInline]
  def value : Int128 | Nil
    @value
  end
end
@[NoInline]
def captured(value : Int128)
  -> { value }
end
v = 123_i128
puts Int128Field.new(v).value.to_i64
x = Int128Union.new(v).value
puts x.as(Int128).to_i64
puts captured(v).call.to_i64
IYI
"$IYI" build --release --emit=llvm-ir -o "$WORK/int128" "$WORK/int128.iyi" ||
  fail "Int128: native build failed"
for function in 'Int128Field::new<Int128>' 'Int128Union::new<Int128>' 'captured<Int128>'; do
  awk -v name="$function" '/^define / && index($0, name) { inside=1 }
       inside { print }
       inside && /^}/ { exit }' "$WORK/int128.ll" >"$WORK/int128-function.ir"
  grep -Eq 'store i128 .*align 8([,[:space:]]|$)' "$WORK/int128-function.ir" ||
    fail "Int128: $function did not use eight-byte heap alignment" "$WORK/int128-function.ir"
done
echo 'native Int128: field, union and closure stores use align 8'

mkdir -p "$WORK/app" "$WORK/vector-artifacts"
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
# Reading an artifact written by a wasm32 cross build with machine code was
# refused in CI (`its object code has no symbol for it`: the build that wrote
# it never reached `mix`), so the artifact is checked in the front end, as
# bench/std_platforms.sh does for other targets. The source build runs and
# gives (11, 19); the artifact must be written, resolve the import with the
# module's source gone, and the same build without it must fail, so that the
# artifact is what answered. The artifacts go in a directory not named `mods`,
# because a `mods` beside the project root is read without being named and
# would answer the build that must fail.
IYI_PATH="$WORK:$REPO/src" build_wasm "$WORK/source" "$WORK/consumer.iyi"
"$WASMTIME" "$WORK/source.wasm" >"$WORK/source.out" || fail "artifact: source program failed" "$WORK/source.out"
printf '11\n19\n' >"$WORK/expected.out"
cmp "$WORK/source.out" "$WORK/expected.out" ||
  fail "artifact: source output differs from expected" "$WORK/source.out"
(cd "$WORK" && IYI_PATH="$WORK:$REPO/src" "$IYI" build --no-codegen --target wasm32-wasi \
  --emit-iyimod "$WORK/vector-artifacts" -o "$WORK/emit-out" "$WORK/consumer.iyi") >"$WORK/emit.log" 2>&1 ||
  fail "artifact: writing the vector artifact failed" "$WORK/emit.log"
[ -f "$WORK/vector-artifacts/app/vector.iyimod" ] || fail "vector artifact missing"
mv "$WORK/app/vector.iyi" "$WORK/vector-source.saved"
(cd "$WORK" && IYI_PATH="$WORK:$REPO/src" "$IYI" build --no-codegen --target wasm32-wasi \
  --use-iyimod "$WORK/vector-artifacts" -o "$WORK/use-out" "$WORK/consumer.iyi") >"$WORK/use.log" 2>&1 ||
  fail "artifact: the front end could not read the vector artifact" "$WORK/use.log"
if (cd "$WORK" && IYI_PATH="$WORK:$REPO/src" "$IYI" build --no-codegen --target wasm32-wasi \
  -o "$WORK/nouse-out" "$WORK/consumer.iyi") >"$WORK/nouse.log" 2>&1; then
  fail "artifact: the import resolved with neither source nor artifact" "$WORK/nouse.log"
fi
echo 'artifact: UInt64x2 signature round-trips through the vector artifact on wasm32 (front end), source removed for import'

mkdir -p "$WORK/broken/iyi"
cp -R "$REPO/src/iyi/." "$WORK/broken/iyi/"
awk '{sub(/@\[Primitive\(:uint64x2_xor\)\]/, "@[Primitive(:uint64x2_or)]"); print}' \
  "$REPO/src/iyi/primitives.iyi" >"$WORK/broken/iyi/primitives.iyi"
grep -A1 'Primitive(:uint64x2_or)' "$WORK/broken/iyi/primitives.iyi" | grep -q 'def \^' ||
  fail "broken xor: mutation did not change the primitive"
IYI_PATH="$WORK/broken:$REPO/src" build_wasm "$WORK/broken/prog" "$REPO/bench/uint64x2_exercise.iyi"
set +e
"$WASMTIME" "$WORK/broken/prog.wasm" >"$WORK/broken/out" 2>&1
code=$?
set -e
if [ "$code" -eq 0 ] || grep -q 'ALL UINT64X2 CHECKS PASSED' "$WORK/broken/out"; then
  fail "broken xor primitive escaped the exercise" "$WORK/broken/out"
fi
grep -q 'xor: wrong' "$WORK/broken/out" ||
  fail "broken xor: program failed for the wrong reason" "$WORK/broken/out"
echo "broken xor: caught (exit $code, $(grep -m1 'xor: wrong' "$WORK/broken/out"))"
echo 'ALL UINT64X2 ACCEPTANCE CHECKS PASSED'
