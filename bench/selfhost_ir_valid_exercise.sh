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
. "$REPO/bench/lib/mutation.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if command -v brew >/dev/null 2>&1; then
  LIBRARY_PATH="$(brew --prefix bdw-gc)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"; export LIBRARY_PATH
fi
export CRYSTAL_CACHE_DIR="${TMPDIR:-/tmp}/iyi-irvalid-cache"

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
    # A prelude file the port refuses by name is its own verdict, "refused", with
    # the port's message. It is not a pass, and the gate fails if the port starts
    # emitting IR for it that does not verify. Raise the floor when the port types
    # the construct that refuses it.
    # These verified before only because the port dropped the calls it could not
    # resolve (`raise` and the prelude's own methods, which a single-file probe
    # does not define) and emitted the rest. The port now refuses each such call
    # by name, so the verdict is "refused" until the port resolves them. The
    # floor moves, and nothing is counted as a pass that the port never checked.
    "hash.iyi"|"chaos.iyi"|"array.iyi"|"enum.iyi"|"file.iyi"|"float.iyi") echo "refused" ;;
    "io.iyi"|"number.iyi"|"object.iyi"|"primitives.iyi"|"set.iyi"|"string.iyi"|"testing.iyi") echo "refused" ;;
    *)                 echo "pass" ;;
  esac
}

echo "== 1. Building self-host compile tool"
if ! "$IYI" build -o "$REPO/.build/iyi-compile" "$COMPILE_TOOL_SRC" >/dev/null 2>&1; then
  echo "  FAILED: could not build the compile tool"
  exit 1
fi
echo "  built .build/iyi-compile successfully"

# Reports "pass", "refused: <port message>", "fail: <verifier message>", or
# "absent" when codegen never ran.
verify_one() {
  local src="$1"
  local out
  out="$("$REPO/.build/iyi-compile" --probe-verify -o "$WORK/out" "$src" 2>&1 | tr -d '\0' || true)"
  if printf '%s' "$out" | grep -q '\[verify\] pass'; then
    echo "pass"
  elif printf '%s' "$out" | grep -q '\[verify\] fail'; then
    printf 'fail: %s\n' "$(printf '%s' "$out" | sed -n 's/.*\[verify\] fail: //p' | head -1)"
  elif printf '%s' "$out" | grep -q '^Error: port limitation'; then
    printf 'refused: %s\n' "$(printf '%s' "$out" | grep '^Error: ' | head -1 | sed 's/^Error: //')"
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
  case "$floor" in
    pass)
      if [ "$got" = "pass" ]; then
        held=$((held + 1))
      else
        note="REGRESSION"
        status=1
      fi
      ;;
    refused)
      # Held at the port's named refusal. A pass here is an improvement to record,
      # and any other verdict (including a verifier failure) is a regression.
      case "$got" in
        refused:*) held=$((held + 1)) ;;
        pass) held=$((held + 1)); note="IMPROVED: the port types it now, raise this floor" ;;
        *) note="REGRESSION"; status=1 ;;
      esac
      ;;
    *)
      # known-fail: passing is an improvement worth surfacing, never a failure.
      held=$((held + 1))
      case "$got" in
        pass) note="IMPROVED: raise this floor" ;;
      esac
      ;;
  esac
  printf '  %-20s %-10s %s %s\n' "$name" "$floor" "$got" "$note"
done
echo "  Validity summary: $held/$checked prelude modules meet the committed IR floor"

echo
echo "== 3. Codegen fixtures must emit valid IR too"
fx_total=0
fx_valid=0
for src in "$REPO"/bench/fixtures/cg_*.iyi; do
  name="$(basename "$src")"
  # A refusal or port-limitation fixture has no IR to verify: the port refuses it by
  # name, and selfhost_codegen_exercise.sh checks that refusal against the oracle.
  case "$name" in
    cg_exceptions.iyi|cg_raise.iyi|cg_undefined_raise.iyi|cg_undefined_runtime_raise.iyi|cg_splat_loop.iyi) continue ;;
  esac
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
echo "== 3b. Forward-reference probes: a field may name a type defined later, and the IR must verify"
echo "   (probes, not parity fixtures: they check the layout order, not the oracle's output)"
probe_total=0
probe_valid=0
for src in "$REPO"/bench/fixtures/fwd_*_probe.iyi; do
  name="$(basename "$src")"
  probe_total=$((probe_total + 1))
  got="$(verify_one "$src")"
  if [ "$got" = "pass" ]; then
    probe_valid=$((probe_valid + 1))
  else
    echo "  FAIL: $name did not verify ($got)"
    status=1
  fi
done
echo "  Probe summary: $probe_valid/$probe_total forward-reference probes emit verifying IR"

echo
echo "== 4. Guarded mutation proofs: the gate must go red on invalid IR"
mut_run=0
mut_caught=0

# Checks the mutated backend. Returns zero only while the probe still verifies (not caught);
# a mutant that stops the backend building, or emits IR that fails verification, returns
# non-zero (caught). MUT_PROBE names the probe file for this mutation.
check_ir_still_verifies() {
  "$IYI" build -o "$WORK/mut-compile" "$COMPILE_TOOL_SRC" >/dev/null 2>&1 || return 1
  local out
  out="$("$WORK/mut-compile" --probe-verify -o "$WORK/mut_out" "$MUT_PROBE" 2>&1 | tr -d '\0' || true)"
  printf '%s' "$out" | grep -q '\[verify\] pass'
}

prove_invalid() {
  local label="$1" target="$2" old="$3" new="$4" probe="$5"
  mut_run=$((mut_run + 1))
  MUT_PROBE="$probe"
  if prove_mutation "$label" "$target" "$old" "$new" -- check_ir_still_verifies; then
    mut_caught=$((mut_caught + 1))
  else
    status=1
  fi
}

prove_invalid "return a value from a void function" \
  "$CODEGEN_SRC" \
  "@builder.ret_void" \
  "@builder.ret(@context.int32.const_int(0))" \
  "$REPO/bench/fixtures/cg_int_arith.iyi"

# Each mutation below was confirmed to be detected by the probe named with it.
# Several plausible-looking alternatives (phi widening, pointer offset
# extension, return width conversion) are NOT here: no file that verifies
# today reaches them, so a proof anchored there would patch real code and
# still detect nothing. The return type of an ordinary method call is one of
# them: the port converts a pointer result to the declared width before every
# consumer the verifier checks, so that mutation still verifies. The dispatch
# merge below is a consumer the verifier does check: its phi takes the
# declared return type.
prove_invalid "declare a dispatched call with the wrong return type" \
  "$CODEGEN_SRC" \
  "m_fn_ty = @types.func(m_param_tys, ret_llvm_type, false)" \
  "m_fn_ty = @types.func(m_param_tys, @types.pointer, false)" \
  "$REPO/bench/fixtures/cg_virtual_dispatch.iyi"

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
