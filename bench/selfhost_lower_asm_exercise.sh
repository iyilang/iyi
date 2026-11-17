#!/usr/bin/env bash
# Fails when the typed lowering of inline asm (src/compiler/lower/asm.iyi, and
# visit(Asm) in src/compiler/semantic/main_visitor.iyi) stops agreeing with the
# hosted compiler's module for the same fixture.
#
# For each fixture (bench/fixtures/lowasm_*.iyi) the hosted compiler builds the
# program with --prelude empty, --emit llvm-ir and --no-debug. The oracle module
# is rewritten so an asm call carries the function type the IR parser requires
# (`call T asm` becomes `call T (params) asm`), then read through the port's IR
# text parser and printed by the port's printer. The port analyses the fixture,
# lowers it, and prints the module. The two normalised texts are compared
# function by function (bench/lib/lower_gate.iyi).
#
# A fixture the port lowers identically is built by the native tool and run,
# except where the assembler refuses the template (IR-only: the refusal is
# quoted) or the template is `svc #0` (IR-only: a supervisor call, not executed).
# The other fixtures' exit status and stdout must equal the hosted executable's.
#
# Mutation proofs patch the ported code, rebuild the driver, and require the
# named fixture's check to fail.
#
#   bash bench/selfhost_lower_asm_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/lower_oracle.sh"
WORK="$(mktemp -d)"

trap 'rm -rf "$WORK"' EXIT

# LLVM prints `call T asm ... "constraints"(ARGS)` and leaves the function type's
# parameter list out. The IR parser requires `call T (P, P) asm ...`.
ASM_TYPES='
function arg_type(a,   n, w) {
  n = split(a, w, " ")
  return w[1]
}
function split_top(s, out,   i, c, depth, cur, n, quoted) {
  n = 0; depth = 0; cur = ""; quoted = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\"") quoted = !quoted
    else if (!quoted && c == "(") depth++
    else if (!quoted && c == ")") depth--
    if (c == "," && depth == 0 && !quoted) {
      out[++n] = cur
      cur = ""
      if (substr(s, i + 1, 1) == " ") i++
      continue
    }
    cur = cur c
  }
  if (cur != "" || n == 0) out[++n] = cur
  return n
}
function asm_args(after,   i, c, quotes, inq, start, end, args, n, parts, types, k, depth) {
  quotes = 0; inq = 0; start = 0
  for (i = 1; i <= length(after); i++) {
    c = substr(after, i, 1)
    if (c == "\"") {
      inq = !inq
      if (!inq) quotes++
    } else if (!inq && quotes >= 2 && c == "(" && start == 0) {
      start = i
      break
    }
  }
  if (start == 0) return ""
  depth = 1; end = 0
  for (i = start + 1; i <= length(after); i++) {
    c = substr(after, i, 1)
    if (c == "(") depth++
    else if (c == ")") { depth--; if (depth == 0) { end = i; break } }
  }
  if (end == 0) return ""
  args = substr(after, start + 1, end - start - 1)
  if (args == "") return ""
  n = split_top(args, parts)
  types = ""
  for (k = 1; k <= n; k++) types = types (k > 1 ? ", " : "") arg_type(parts[k])
  return types
}
function rewrite_asm(line,   p, types) {
  p = index(line, " asm ")
  if (p == 0) return line
  if (index(line, " call ") == 0) return line
  types = asm_args(substr(line, p + 1))
  return substr(line, 1, p - 1) " (" types ") " substr(line, p + 1)
}
{ print rewrite_asm($0) }
'

echo "== 1. Building the port driver"
if ! "$IYI" build -o "$WORK/port" "$REPO/bench/selfhost_lower_asm_exercise.iyi" > "$WORK/port.build.log" 2>&1; then
  echo "  the port driver did not build (see $WORK/port.build.log)"
  exit 1
fi
echo "  driver built"

echo
echo "== 2. Each fixture: the hosted module against the port lowering"
passed=0
e2e=""
diverged=0
for fixture in "$REPO"/bench/fixtures/lowasm_*.iyi; do
  name="$(basename "$fixture" .iyi)"
  if ! "$IYI" build --prelude empty --emit llvm-ir --no-debug -o "$WORK/$name" "$fixture" > "$WORK/$name.oracle.log" 2>&1 || [ ! -s "$WORK/$name.ll" ]; then
    echo "  $name: the hosted compiler did not emit its module (see $WORK/$name.oracle.log)"
    diverged=$((diverged + 1))
    continue
  fi
  awk "$ASM_TYPES" "$WORK/$name.ll" | awk "$CALL_TYPES" > "$WORK/$name.oracle.ll"

  if ! "$WORK/port" lower "$fixture" "$WORK/$name.oracle.ll" > "$WORK/$name.port.out" 2> "$WORK/$name.port.err"; then
    echo "  $name: REFUSED: $(awk 'NR==1' "$WORK/$name.port.err")"
    diverged=$((diverged + 1))
    continue
  fi
  echo "  $name:"
  awk '!/^SUMMARY/ { print "    " $0 }' "$WORK/$name.port.out"
  summary="$(awk '/^SUMMARY/ { print }' "$WORK/$name.port.out")"
  identical="$(echo "$summary" | awk '{ split($2, a, "="); print a[2] }')"
  total="$(echo "$summary" | awk '{ split($3, a, "="); print a[2] }')"
  module="$(echo "$summary" | awk '{ split($4, a, "="); print a[2] }')"
  if [ -n "$total" ] && [ "$total" -gt 0 ] && [ "$identical" = "$total" ] && [ "$module" = 1 ]; then
    echo "    $name: PASSED, $identical of $total functions identical"
    passed=$((passed + 1))
    e2e="$e2e $name"
  else
    echo "    $name: DIVERGED, $identical of $total functions identical"
    diverged=$((diverged + 1))
  fi
done
echo "  fixtures: $passed passed, $diverged diverged or refused"
if [ "$diverged" -gt 0 ] || [ "$passed" -eq 0 ]; then
  status=1
fi

echo
echo "== 3. End to end: each identical fixture, built natively and run"
echo "  IR-only: lowasm_svc (the template is svc #0, a supervisor call; not executed)"
e2e_pass=0
e2e_fail=0
ir_only=0
if "$IYI" build -o "$WORK/compile_native" "$REPO/src/compiler/tools/compile_native.iyi" > "$WORK/tool.build.log" 2>&1; then
  for name in $e2e; do
    fixture="$REPO/bench/fixtures/$name.iyi"
    if ! "$WORK/port" emit "$fixture" "$WORK/$name.oracle.ll" > "$WORK/$name.port.ir" 2> "$WORK/$name.emit.err"; then
      echo "  $name: the port writes no module: $(awk 'NR==1' "$WORK/$name.emit.err")"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    if ! "$WORK/compile_native" "$WORK/$name.port.ir" -o "$WORK/$name.native" > "$WORK/$name.native.log" 2>&1; then
      reason="$(awk 'NR==1' "$WORK/$name.native.log")"
      echo "  $name: IR-only. The native tool refuses the template: $reason"
      ir_only=$((ir_only + 1))
      continue
    fi
    if [ "$name" = "lowasm_svc" ]; then
      echo "  $name: IR-only. The assembler accepted svc #0. Not run: it is a supervisor call, and the registers this fixture sets are not a Darwin syscall number."
      ir_only=$((ir_only + 1))
      continue
    fi
    timeout 30 "$WORK/$name.native" > "$WORK/$name.native.out" 2>&1; ns=$?
    timeout 30 "$WORK/$name" > "$WORK/$name.hosted.out" 2>&1; hs=$?
    if [ "$ns" = "$hs" ] && cmp -s "$WORK/$name.native.out" "$WORK/$name.hosted.out"; then
      echo "  $name: native executable runs to the hosted result (status $hs, stdout identical)"
      e2e_pass=$((e2e_pass + 1))
    else
      echo "  $name: native status $ns, hosted $hs; stdout differs or status differs"
      e2e_fail=$((e2e_fail + 1))
    fi
  done
else
  echo "  the native tool does not build (see $WORK/tool.build.log)"
  e2e_fail=1
fi
echo "  end to end: $e2e_pass fixture(s) run to the hosted result, $e2e_fail failed, $ir_only IR-only"
if [ "$e2e_fail" -gt 0 ] || [ "$e2e_pass" -eq 0 ]; then
  status=1
fi

echo
echo "== 4. Mutation proofs: the gate must catch each patch to the ported code"
asm_one() {
  name="$1"
  "$IYI" build -o "$WORK/mut" "$REPO/bench/selfhost_lower_asm_exercise.iyi" > "$WORK/mut.build.log" 2>&1 || return 1
  "$WORK/mut" lower "$REPO/bench/fixtures/$name.iyi" "$WORK/$name.oracle.ll" > "$WORK/mut.out" 2>/dev/null || return 1
  awk '/^SUMMARY identical=[0-9]+ total=[0-9]+ module=[01]$/ { split($2, a, "="); split($3, b, "="); split($4, c, "="); if (a[2] != b[2] || b[2] == 0 || c[2] != 1) bad = 1; n++ } END { exit (bad || n == 0) }' "$WORK/mut.out"
}
if ! asm_one lowasm_yield || ! asm_one lowasm_reg_out || ! asm_one lowasm_fixed || ! asm_one lowasm_reg_io; then
  echo "  baseline: the unmutated port does not match the hosted module, so no mutation below is counted"
  exit 1
fi
echo "  lowasm_reg_io catches a swapped constraint order:"
prove_mutation "outputs are written after inputs (constraint order)" "$REPO/src/compiler/lower/asm.iyi" \
  "    append_outputs(io, node)
    append_inputs(io, node)" \
  "    append_inputs(io, node)
    append_outputs(io, node)" -- asm_one lowasm_reg_io || status=1
echo "  lowasm_reg_out catches an output that is not stored:"
prove_mutation "an asm output is not stored" "$REPO/src/compiler/lower/asm.iyi" \
  "  store_aligned(low, value, pointer.as(Value))" \
  "  low.last = value" -- asm_one lowasm_reg_out || status=1
echo "  lowasm_yield catches a dropped volatile:"
prove_mutation "volatile is dropped from the asm call" "$REPO/src/compiler/lower/asm.iyi" \
  "node.volatile, node.alignstack, dialect, node.can_throw" \
  "false, node.alignstack, dialect, node.can_throw" -- asm_one lowasm_yield || status=1
echo "  lowasm_fixed catches a dropped clobber:"
prove_mutation "a clobber is dropped from the constraint string" "$REPO/src/compiler/lower/asm.iyi" \
  "    append_clobbers(io, node)" \
  "    io << io" -- asm_one lowasm_fixed || status=1

echo
if [ "$status" -eq 0 ]; then
  echo "OK: inline asm lowers to the hosted module, and each mutation is caught"
else
  echo "FAIL: inline asm lowering disagrees with the hosted module, or a mutation was not caught"
fi
exit "$status"
