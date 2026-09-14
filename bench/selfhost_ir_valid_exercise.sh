#!/usr/bin/env bash
# The IR the ported backend emits must be VALID, not merely acceptable to
# emit_obj_to_file. Five prelude files used to emit object code from modules
# that LLVMVerifyModule rejects, which was found only because a stray
# mod.verify was left in the emit path and demoted them.
#
# The shipped compiler does not verify in its emit path and neither does this
# one: matching its behaviour matters. The check belongs here instead, with a
# committed floor per file so a file that verifies today cannot quietly stop.
#
# A file listed as "pass" MUST verify. A file listed as "known-fail" is
# recorded with its verifier message in STAGE_TWO.md and is allowed to fail;
# if it starts passing, this gate says so and the floor should be raised.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
COMPILE_TOOL_SRC="$REPO/src/compiler/tools/compile.iyi"
CODEGEN_SRC="$REPO/src/compiler/codegen/codegen.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export LIBRARY_PATH="/opt/homebrew/opt/bdw-gc/lib:${LIBRARY_PATH:-}"
export CRYSTAL_CACHE_DIR="/tmp/iyi-irvalid-cache"

status=0

# Committed floor: measured, not assumed.
expected_verify() {
  case "$1" in
    "concurrency.iyi") echo "known-fail" ;;
    # prelude.iyi requires concurrency, and this gate compiles with requires
    # resolved rather than single-file, so it inherits the same defect rather
    # than carrying one of its own. Fixing concurrency should clear both, and
    # the gate will say so.
    "prelude.iyi")     echo "known-fail" ;;
    *)                 echo "pass" ;;
  esac
}

echo "== 1. Building self-host compile tool"
if ! "$IYI" build -o "$REPO/.build/iyi-compile" "$COMPILE_TOOL_SRC" >/dev/null 2>&1; then
  echo "  FAILED: could not build the compile tool"
  exit 1
fi
echo "  built .build/iyi-compile successfully"

# Reports "pass", "fail: <message>", or "absent" when codegen never ran.
verify_one() {
  local src="$1"
  local out
  out="$("$REPO/.build/iyi-compile" --probe-verify -o "$WORK/out" "$src" 2>&1 | tr -d '\0' || true)"
  if printf '%s' "$out" | grep -q '\[verify\] pass'; then
    echo "pass"
  elif printf '%s' "$out" | grep -q '\[verify\] fail'; then
    printf 'fail: %s\n' "$(printf '%s' "$out" | sed -n 's/.*\[verify\] fail: //p' | head -1)"
  else
    echo "absent"
  fi
}

echo
echo "== 2. LLVM module validity across the prelude, against the committed floor"
printf '  %-20s %-10s %s\n' "File" "Floor" "Measured"
printf '  %-20s %-10s %s\n' "-----------------" "---------" "--------"
checked=0
held=0
for src in "$REPO"/src/iyi/*.iyi; do
  name="$(basename "$src")"
  floor="$(expected_verify "$name")"
  got="$(verify_one "$src")"
  checked=$((checked + 1))
  note=""
  if [ "$floor" = "pass" ]; then
    if [ "$got" = "pass" ]; then
      held=$((held + 1))
    else
      note="REGRESSION"
      status=1
    fi
  else
    # known-fail: passing is an improvement worth surfacing, never a failure.
    held=$((held + 1))
    case "$got" in
      pass) note="IMPROVED: raise this floor" ;;
    esac
  fi
  printf '  %-20s %-10s %s %s\n' "$name" "$floor" "$got" "$note"
done
echo "  Validity summary: $held/$checked prelude modules meet the committed IR floor"

echo
echo "== 3. Codegen fixtures must emit valid IR too"
fx_total=0
fx_valid=0
for src in "$REPO"/bench/fixtures/cg_*.iyi; do
  name="$(basename "$src")"
  fx_total=$((fx_total + 1))
  got="$(verify_one "$src")"
  if [ "$got" = "pass" ]; then
    fx_valid=$((fx_valid + 1))
  else
    echo "  FAIL: $name emitted IR that does not verify ($got)"
    status=1
  fi
done
echo "  Fixture summary: $fx_valid/$fx_total codegen fixtures emit verifying IR"

echo
echo "== 4. Guarded mutation proofs: the gate must go red on invalid IR"
mut_run=0
mut_caught=0

prove_invalid() {
  local label="$1"
  local target="$2"
  local script="$3"
  local probe="$4"

  mut_run=$((mut_run + 1))
  echo "  [$label]"
  cp "$target" "$target.orig"
  sed -e "$script" "$target.orig" > "$target"
  if cmp -s "$target.orig" "$target"; then
    echo "    FAIL: mutation matched nothing, so it proves nothing"
    mv "$target.orig" "$target"
    status=1
    return
  fi

  local caught=0
  if "$IYI" build -o "$WORK/mut-compile" "$COMPILE_TOOL_SRC" >/dev/null 2>&1; then
    local out
    out="$("$WORK/mut-compile" --probe-verify -o "$WORK/mut_out" "$probe" 2>&1 | tr -d '\0' || true)"
    if ! printf '%s' "$out" | grep -q '\[verify\] pass'; then
      caught=1
    fi
  else
    # A mutation that stops the backend building also stops it emitting
    # invalid IR unnoticed, which is a catch rather than a miss.
    caught=1
  fi

  mv "$target.orig" "$target"
  if [ "$caught" -eq 1 ]; then
    echo "    caught: the mutated backend no longer emits verifying IR, as it must"
    mut_caught=$((mut_caught + 1))
  else
    echo "    FAIL: mutation left the IR verifying"
    status=1
  fi
}

prove_invalid "return a value from a void function" \
  "$CODEGEN_SRC" \
  's/@builder\.ret_void/@builder.ret(@context.int32.const_int(0))/' \
  "$REPO/bench/fixtures/cg_int_arith.iyi"

# Each mutation below was confirmed to be detected by the probe named with it.
# Several plausible-looking alternatives (phi widening, pointer offset
# extension, return width conversion) are NOT here: no file that verifies
# today reaches them, so a proof anchored there would patch real code and
# still detect nothing.
prove_invalid "declare a call with the wrong return type" \
  "$CODEGEN_SRC" \
  's/method_fn_ty = LLVMType\.function(m_param_tys, call_ret_ty, false)/method_fn_ty = LLVMType.function(m_param_tys, @context.pointer, false)/' \
  "$REPO/src/iyi/float.iyi"

echo "  Mutation summary: $mut_caught/$mut_run invalid-IR mutations caught"

# Rebuild the tool from clean source so a later gate does not inherit a mutant.
"$IYI" build -o "$REPO/.build/iyi-compile" "$COMPILE_TOOL_SRC" >/dev/null 2>&1 || true

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SELFHOST IR VALIDITY CHECKS PASSED!"
else
  echo "SOME SELFHOST IR VALIDITY CHECKS FAILED"
  exit 1
fi
