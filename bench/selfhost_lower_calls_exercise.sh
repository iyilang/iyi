#!/usr/bin/env bash
# Fails when the typed lowering of calls and functions (src/compiler/lower/{fun,call}.iyi)
# stops agreeing with the hosted code generator's module for the same fixture.
#
# For each fixture (bench/fixtures/lowcall_*.iyi) the hosted compiler builds the program
# against --prelude empty, with --emit llvm-ir and --no-debug. Its module is read through
# the port's IR text parser and printed by the port's printer. The port analyses the
# fixture, lowers it, and prints the module. The two normalised texts are compared
# function by function (bench/lib/lower_gate.iyi, shared with the lowering-core gate).
#
# The oracle's direct calls get their function type and lose their call-site attribute
# group from bench/lib/lower_oracle.sh (CALL_TYPES), the same as the core gate.
#
# Each fixture the port lowers identically is then built to a native executable by the
# native tool and run: its exit status and stdout must equal the hosted executable's. The
# fixtures return computed values through `LibC.exit`, so the status is observable.
#
# The analysis types each lib and the calls on it (the semantic pass, semantic/lib_call.iyi).
#
# Mutation proofs patch the ported code, rebuild the driver, and require the check to
# fail. A patch that changes nothing is refused by prove_mutation.
#
#   bash bench/selfhost_lower_calls_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
if [ "$HOST_OS" = windows ]; then PROBE_IYI_PATH="$REPO_NATIVE;$REPO_NATIVE/src"; else PROBE_IYI_PATH="$REPO_NATIVE:$REPO_NATIVE/src"; fi
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/lower_oracle.sh"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")" || exit 1

run_fixture_status() {
  [ -n "$PY" ] || { echo 'INVALID: Python is required to distinguish exits from signals'; return 2; }
  "$PY" - "$(native_path "$1")" "$(native_path "$2")" "$(native_path "$3")" <<'PY'
import subprocess
import sys
try:
    with open(sys.argv[2], "wb") as output:
        result = subprocess.run([sys.argv[1]], stdout=output, stderr=subprocess.STDOUT, timeout=30)
except (OSError, subprocess.TimeoutExpired) as error:
    print("INVALID: fixture did not complete:", error)
    sys.exit(2)
if result.returncode < 0 or result.returncode > 255:
    print("INVALID: fixture terminated abnormally:", result.returncode)
    sys.exit(2)
with open(sys.argv[3], "w") as status:
    status.write(str(result.returncode))
PY
}

summary_check() {
  local rc=0
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then
    echo "INVALID: missing or unreadable comparison: $1"
    return 2
  fi
  awk '/^SUMMARY identical=[0-9]+ total=[0-9]+ module=[01]$/ {
    split($2,a,"="); split($3,b,"="); split($4,c,"=")
    if (b[2] == 0) invalid=1
    if (a[2] != b[2] || c[2] != 1) bad=1
    n++
  } END { if (n != 1 || invalid) exit 43; if (bad) exit 42 }' "$1" || rc=$?
  case "$rc" in
    0) return 0 ;;
    42) echo "decisive: comparison differs in $1"; return 1 ;;
    *) echo "INVALID: comparison summary unavailable (awk exit $rc): $1"; return 2 ;;
  esac
}

calls_run_lower() {
  local driver="$1" fixture="$2" out="$3" err="$4" site="${5:-}" message="${6:-}" result=0
  "$driver" lower "$REPO_NATIVE/bench/fixtures/$fixture.iyi" "$WORK_NATIVE/$fixture.oracle.ll" > "$out" 2>"$err" || result=$?
  if [ "$result" -eq 0 ]; then return 0; fi
  if [ -n "$message" ] && summary_check "$WORK/$fixture.port.out" >/dev/null &&
     expected_refusal "$result" "$err" "$site" "$message"; then
    echo "decisive: $fixture: $(refusal_note "$result" "$err")"
    return 1
  fi
  echo "INVALID: $fixture failed outside its expected refusal"
  cat "$out" "$err"
  return 2
}

normalize_switches() {
  awk '
    in_switch {
      if ($0 ~ /^[[:space:]]*][[:space:]]*$/) { print line " ]"; in_switch=0; next }
      if ($0 !~ /^[[:space:]]*i[0-9]+ -?[0-9]+, label %[^[:space:]]+[[:space:]]*$/) { bad=1; exit 1 }
      sub(/^[[:space:]]*/, "")
      line=line (count++ ? ", " : " ") $0
      next
    }
    /switch .*\[$/ { line=$0; in_switch=1; count=0; next }
    { print }
    END { if (in_switch || bad) exit 1 }
  '
}

# Hosted in? splat formals use file-hashed temporary names; the port names
# them $splat_N. Rename only those formal SSA names and their uses, separately
# for each in? function, before comparing every instruction.
normalize_splat_formals() {
  awk '
    function replace_name(line, from, to,   result, tail, at, following) {
      result = ""; tail = line
      while ((at = index(tail, from)) > 0) {
        following = substr(tail, at + length(from), 1)
        if (following != "" && following ~ /[[:alnum:]$_.-]/) {
          result = result substr(tail, 1, at + length(from) - 1)
        } else {
          result = result substr(tail, 1, at - 1) to
        }
        tail = substr(tail, at + length(from))
      }
      return result tail
    }
    /^define / {
      for (key in names) delete names[key]
      count = 0; rest = $0
      if (index($0, "#in?<") > 0) {
        while (match(rest, /%__temp_[0-9a-f]+_[0-9]+/)) {
          name = substr(rest, RSTART, RLENGTH)
          following = substr(rest, RSTART + RLENGTH, 1)
          if ((following == "" || following !~ /[[:alnum:]$_.-]/) && !(name in names))
            names[name] = "%$splat_" ++count
          rest = substr(rest, RSTART + RLENGTH)
        }
      }
    }
    {
      for (key in names) $0 = replace_name($0, key, names[key])
      print
    }
    /^}$/ { for (key in names) delete names[key] }
  '
}
switch_result="$(printf '  switch i32 %%x, label %%else [\n    i32 1, label %%a\n    i32 2, label %%b\n  ]\n' | normalize_switches)"
if [ "$switch_result" != '  switch i32 %x, label %else [ i32 1, label %a, i32 2, label %b ]' ] ||
   printf 'switch i32 %%x, label %%else [\n i32 1, label %%a\n' | normalize_switches >/dev/null ||
   printf 'switch i32 %%x, label %%else [\n nonsense\n]\n' | normalize_switches >/dev/null; then
  echo "switch normalization regression"
  exit 1
fi

# Fixtures with a named, intentionally unsupported refusal belong here until
# their hosted and port modules agree.
WAITING_FIXTURES=""
waiting_reason() {
  case "$1" in
    *) printf "%s" "" ;;
  esac
}

trap 'rm -rf "$WORK"' EXIT

echo "== 1. Building the port driver"
if ! "$IYI" build -o "$WORK_NATIVE/port$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/port.build.log" 2>&1; then
  echo "the port driver failed to build:"
  awk '!/^ld: warning/ && NR<=20' "$WORK/port.build.log"
  exit 1
fi
echo "  driver built"
if ! "$WORK/port$EXE" triple; then
  echo "  FAIL: target triple frame-pointer classification"
  status=1
fi

echo
echo "== 2. Each fixture: the hosted module against the port's lowering"
passed=0
waiting=0
e2e=""
diverged=0
for fixture in "$REPO"/bench/fixtures/lowcall_*.iyi "$REPO"/bench/fixtures/lowdecl_*.iyi; do
  name="$(basename "$fixture" .iyi)"
  oracle_target=()
  oracle_output="$WORK_NATIVE/$name$EXE"
  if [ "$HOST_ID" != darwin-arm64 ]; then
    oracle_target=(--cross-compile --target aarch64-apple-darwin)
    oracle_output="$WORK_NATIVE/$name.o"
  fi
  if ! "$IYI" build ${oracle_target[@]+"${oracle_target[@]}"} --prelude empty --emit llvm-ir --no-debug -o "$oracle_output" "$(native_path "$fixture")" > "$WORK/$name.oracle.log" 2>&1 || [ ! -s "$WORK/$name.ll" ]; then
    echo "  $name: the hosted compiler did not emit its module (see $WORK/$name.oracle.log)"
    diverged=$((diverged + 1))
    continue
  fi
  if ! awk "$CALL_TYPES" "$WORK/$name.ll" | normalize_switches > "$WORK/$name.oracle.pre-splat.ll" ||
     ! normalize_splat_formals < "$WORK/$name.oracle.pre-splat.ll" > "$WORK/$name.oracle.ll"; then
    echo "  $name: malformed hosted module normalization"
    diverged=$((diverged + 1))
    continue
  fi

  if ! "$WORK/port$EXE" lower "$(native_path "$fixture")" "$WORK_NATIVE/$name.oracle.ll" > "$WORK/$name.port.out" 2> "$WORK/$name.port.err"; then
    reason="$(awk 'NR==1' "$WORK/$name.port.err")"
    expected="$(waiting_reason "$name")"
    if [ -n "$expected" ]; then
      case "$reason" in
        *"$expected"*)
          echo "  $name: WAITING, $expected (S1wDefaults3 expansion, S2d13Primitives Proc primitive): $reason"
          waiting=$((waiting + 1))
          ;;
        *)
          echo "  $name: unexpected refusal: $reason"
          diverged=$((diverged + 1))
          ;;
      esac
    else
      echo "  $name: REFUSED: $reason"
      diverged=$((diverged + 1))
    fi
    continue
  fi
  echo "  $name:"
  awk '!/^SUMMARY/ { print "    " $0 }' "$WORK/$name.port.out"
  summary="$(awk '/^SUMMARY/ { print }' "$WORK/$name.port.out")"
  identical="$(echo "$summary" | awk '{ split($2, a, "="); print a[2] }')"
  total="$(echo "$summary" | awk '{ split($3, a, "="); print a[2] }')"
  module="$(echo "$summary" | awk '{ split($4, a, "="); print a[2] }')"
  if [ -n "$total" ] && [ "$total" -gt 0 ] && [ "$identical" = "$total" ] && [ "$module" = 1 ]; then
    if [ -n "$(waiting_reason "$name")" ]; then
      echo "    $name: now identical to the hosted module: remove it from WAITING_FIXTURES"
      diverged=$((diverged + 1))
    fi
    echo "    $name: PASSED, $identical of $total functions identical"
    passed=$((passed + 1))
    e2e="$e2e $name"
  else
    echo "    $name: DIVERGED, $identical of $total functions identical"
    diverged=$((diverged + 1))
  fi
done
echo "  fixtures: $passed passed, $waiting waiting (named), $diverged diverged or refused"
if [ "$diverged" -gt 0 ] || [ "$passed" -eq 0 ]; then
  status=1
fi

printf '%s\n' 'import no_such_cycle_unit::{Missing}' > "$WORK/missing_import.iyi"
if "$WORK/port$EXE" lower "$WORK_NATIVE/missing_import.iyi" "$WORK_NATIVE/lowcall_empty_body.oracle.ll" > "$WORK/missing_import.out" 2> "$WORK/missing_import.err" ||
   ! grep -Fq "can't find module 'no_such_cycle_unit'" "$WORK/missing_import.err"; then
  echo "  FAIL: missing fixture import was not rejected by name"
  status=1
fi

super_refusal_checks() {
  local driver="$1" fixture line rc
  fixture="$REPO/bench/fixtures/lowcallwait_super_missing.iyi"
  if "$IYI" build --prelude empty --emit llvm-ir --no-debug -o "$WORK_NATIVE/super_missing$EXE" "$(native_path "$fixture")" > "$WORK/super_missing.log" 2>&1; then
    echo "  super missing: hosted unexpectedly accepted"
    return 1
  fi
  line="$(awk '/Error: / { sub(/^.*Error: /, ""); print; exit }' "$WORK/super_missing.log")"
  case "$line" in
    *"undefined method 'greet'"*) ;;
    *) echo "  super missing: unexpected hosted error: $line"; return 1 ;;
  esac
  if "$driver" emit "$(native_path "$fixture")" "$WORK_NATIVE/lowcall_super.oracle.ll" > "$WORK/super_missing.out" 2> "$WORK/super_missing.err"; then
    echo "  super missing: port unexpectedly accepted"
    return 1
  fi
  grep -Fq -- "$line" "$WORK/super_missing.err" || return 1

  fixture="$REPO/bench/fixtures/lowcallwait_super_forwarded_default.iyi"
  "$IYI" build --prelude empty --emit llvm-ir --no-debug -o "$WORK_NATIVE/super_default$EXE" "$(native_path "$fixture")" > "$WORK/super_default.log" 2>&1 || return 1
  "$WORK/super_default$EXE" > "$WORK/super_default.run" 2>&1
  rc=$?
  [ "$rc" -eq 3 ] || return 1
  if [ "$HOST_ID" != darwin-arm64 ]; then
    "$IYI" build --cross-compile --target aarch64-apple-darwin --prelude empty --emit llvm-ir --no-debug \
      -o "$WORK_NATIVE/super_default.o" "$(native_path "$fixture")" > "$WORK/super_default.cross.log" 2>&1 || { cat "$WORK/super_default.cross.log"; return 2; }
  fi
  awk "$CALL_TYPES" "$WORK/super_default.ll" | normalize_switches > "$WORK/super_default.oracle.ll" || return 1
  "$driver" lower "$(native_path "$fixture")" "$WORK_NATIVE/super_default.oracle.ll" > "$WORK/super_default.out" 2> "$WORK/super_default.err" || return 1
  summary_check "$WORK/super_default.out" || return $?

  fixture="$REPO/bench/fixtures/lowcallwait_previous_def_refused.iyi"
  if "$driver" emit "$(native_path "$fixture")" "$WORK_NATIVE/lowcall_super.oracle.ll" > "$WORK/previous_def.out" 2> "$WORK/previous_def.err"; then
    echo "  previous_def: port unexpectedly accepted"
    return 1
  fi
  grep -Fq "previous_def" "$WORK/previous_def.err" || return 1

  fixture="$REPO/bench/fixtures/lowcallwait_super_argument_dispatch.iyi"
  if "$driver" emit "$(native_path "$fixture")" "$WORK_NATIVE/lowcall_super.oracle.ll" > "$WORK/super_args.out" 2> "$WORK/super_args.err"; then
    echo "  super argument dispatch: port unexpectedly accepted"
    return 1
  fi
  grep -Fq 'not ported: super with an argument dispatch (hosted codegen/call.cr:473-475)' "$WORK/super_args.err" || return 1
}
if ! super_refusal_checks "$WORK/port$EXE"; then
  echo "  super refusal checks failed"
  status=1
fi

# LLVM bindings must lower to instructions, with malformed bindings refused before linking.
intrinsic_refusal_checks() {
  local driver="$1" pair name expected
  for pair in \
    "unknown|the lib fun vzeroall binds llvm.x86.avx.vzeroall, which is not an intrinsic the IR accepts" \
    "varargs|the lib fun ceil binds the LLVM intrinsic llvm.ceil.f64 with variadic arguments" \
    "argument|the lib fun ceil declares the LLVM intrinsic llvm.ceil.f64 as double (float), and the intrinsic is double (double)" \
    "result|the lib fun ceil declares the LLVM intrinsic llvm.ceil.f64 as float (double), and the intrinsic is double (double)" \
    "aggregate|the lib fun sadd binds the LLVM intrinsic llvm.sadd.with.overflow.i32 with the aggregate result"; do
    name="lowcallwait_intrinsic_${pair%%|*}"
    expected="${pair#*|}"
    if "$driver" emit "$REPO_NATIVE/bench/fixtures/$name.iyi" "$WORK_NATIVE/lowcall_clib_intrinsics.oracle.ll" > "$WORK/$name.out" 2> "$WORK/$name.err"; then
      echo "  $name: port unexpectedly accepted"
      return 1
    fi
    if ! grep -Fq -- "$expected" "$WORK/$name.err"; then
      echo "  $name: expected refusal missing: $(awk 'NR==1' "$WORK/$name.err")"
      return 1
    fi
  done
}
if intrinsic_refusal_checks "$WORK/port$EXE"; then
  echo "  LLVM intrinsic bindings: five malformed or unsupported bindings refused by name"
else
  echo "  FAIL: LLVM intrinsic binding refusals"
  status=1
fi


# An uninstantiated generic receiver is a typing gap, not an owner that lowering
# may guess. The hosted compiler still accepts the source and emits its module.
generic_fixture="$REPO/bench/fixtures/lowcallwait_uninstantiated_generic.iyi"
if "$IYI" build --prelude empty --emit llvm-ir --no-debug -o "$WORK_NATIVE/uninstantiated$EXE" "$(native_path "$generic_fixture")" > "$WORK/uninstantiated.oracle.log" 2>&1; then
  awk "$CALL_TYPES" "$WORK/uninstantiated.ll" > "$WORK/uninstantiated.oracle.ll"
  if "$WORK/port$EXE" lower "$(native_path "$generic_fixture")" "$WORK_NATIVE/uninstantiated.oracle.ll" > "$WORK/uninstantiated.out" 2> "$WORK/uninstantiated.err"; then
    echo "  uninstantiated generic: unexpectedly lowered"
    status=1
  elif awk 'index($0, "the receiver of probe is the uninstantiated generic Range(B, E).class: typing has not instantiated the owner") { found = 1 } END { exit !found }' "$WORK/uninstantiated.err"; then
    echo "  uninstantiated generic: typing gap identified"
  else
    echo "  uninstantiated generic: unexpected refusal: $(awk 'NR==1' "$WORK/uninstantiated.err")"
    status=1
  fi
else
  echo "  uninstantiated generic: hosted compiler refused the fixture"
  status=1
fi

uncovered_check() {
  local driver="$1" fixture="$REPO/bench/fixtures/lowcallwait_dispatch_uncovered.iyi"
  "$driver" emit "$(native_path "$fixture")" "$WORK_NATIVE/lowcall_super.oracle.ll" > "$WORK/uncovered.out" 2> "$WORK/uncovered.err"
  local result=$?
  if [ "$result" -eq 0 ]; then
    echo "  uncovered union: port unexpectedly accepted"
    return 1
  fi
  if port_refusal "$result" "$WORK/uncovered.err" && grep -Fq "expected argument #1 to 'consume'" "$WORK/uncovered.err"; then return 0; fi
  echo 'INVALID: uncovered union did not reach its named semantic refusal'
  cat "$WORK/uncovered.err"
  return 2
}
if "$IYI" build --prelude empty -o "$WORK_NATIVE/uncovered.hosted$EXE" "$REPO_NATIVE/bench/fixtures/lowcallwait_dispatch_uncovered.iyi" > "$WORK/uncovered.hosted.log" 2>&1; then
  echo "  uncovered union: hosted compiler unexpectedly accepted"
  status=1
elif ! grep -Fq "expected argument #1 to 'consume'" "$WORK/uncovered.hosted.log" || ! uncovered_check "$WORK/port$EXE"; then
  echo "  uncovered union: expected argument diagnostic missing"
  status=1
fi
free_dispatch="$REPO/bench/fixtures/lowcallwait_dispatch_free_vars_block.iyi"
if ! "$IYI" build --prelude empty -o "$WORK_NATIVE/free_dispatch.hosted$EXE" "$(native_path "$free_dispatch")" > "$WORK/free_dispatch.hosted.log" 2>&1; then
  echo "  block-bound free-variable dispatch: hosted compiler unexpectedly refused"
  status=1
elif "$WORK/port$EXE" emit "$(native_path "$free_dispatch")" "$WORK_NATIVE/lowcall_super.oracle.ll" > "$WORK/free_dispatch.out" 2> "$WORK/free_dispatch.err"; then
  echo "  block-bound free-variable dispatch: port unexpectedly accepted"
  status=1
elif ! grep -Fq 'not ported: a dispatch whose arms bind free variables from the block they share (hosted semantic/call.cr match_block_arg binds them per match from the merged block)' "$WORK/free_dispatch.err"; then
  echo "  block-bound free-variable dispatch: expected port limitation missing"
  status=1
else
  echo "  block-bound free-variable dispatch: hosted accepted; port explicitly refused"
fi


echo
echo "== 3. End to end: each fixture the port lowers identically, built natively and run"
e2e_pass=0
e2e_fail=0
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "lower calls: AArch64 Mach-O signature and execution require macOS arm64; $HOST_ID compares and emits Darwin-target IR"
fi
if "$IYI" build -o "$WORK_NATIVE/compile_native$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/tool.build.log" 2>&1; then
  for name in $e2e; do
    fixture="$REPO_NATIVE/bench/fixtures/$name.iyi"
    if ! "$WORK/port$EXE" emit "$fixture" "$WORK_NATIVE/$name.oracle.ll" > "$WORK/$name.port.ir" 2> "$WORK/$name.emit.err"; then
      echo "  $name: the port writes no module: $(awk 'NR==1' "$WORK/$name.emit.err")"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    if ! "$WORK/compile_native$EXE" "$WORK_NATIVE/$name.port.ir" -o "$WORK_NATIVE/$name.native" > "$WORK/$name.native.log" 2>&1; then
      echo "  $name: the native tool refuses the port's module: $(awk 'NR==1' "$WORK/$name.native.log")"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    if [ "$HOST_ID" != darwin-arm64 ]; then
      echo "  $name: AArch64 Mach-O emitted; native execution is host-limited"
      continue
    fi
    if [ "$(uname -s)" = Darwin ] && ! codesign -v --strict "$WORK/$name.native"; then
      echo "  $name: native signature verification failed"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    timeout 30 "$WORK/$name.native" > "$WORK/$name.native.out" 2>&1; ns=$?
    timeout 30 "$WORK/$name$EXE" > "$WORK/$name.hosted.out" 2>&1; hs=$?
    if [ "$name" = lowcall_super ] && [ "$hs" -ne 42 ]; then
      echo "  $name: hosted status $hs, expected 42"
      e2e_fail=$((e2e_fail + 1))
      continue
    fi
    if [ "$ns" = "$hs" ] && cmp -s "$WORK/$name.native.out" "$WORK/$name.hosted.out"; then
      echo "  $name: native executable runs to the hosted result (status $hs, stdout identical)"
      e2e_pass=$((e2e_pass + 1))
    else
      echo "  $name: native status $ns, hosted $hs; stdout differs or status differs"
      e2e_fail=$((e2e_fail + 1))
    fi
  done
else
  echo "  the native tool does not build"
  cat "$WORK/tool.build.log"
  e2e_fail=1
fi
echo "  end to end: $e2e_pass fixture(s) run to the hosted result, $e2e_fail failed"
if [ "$e2e_fail" -gt 0 ] || { [ "$HOST_ID" = darwin-arm64 ] && [ "$e2e_pass" -eq 0 ]; }; then
  status=1
fi
# Array#map and its block-output type variable require the real prelude. This
# fixture must not run through the empty-prelude IR comparison above.
real_fixture_check() {
  local name="$1" fixture="$2" expected="$3" hs ns
  if ! "$IYI" build --no-debug -o "$WORK_NATIVE/$name.hosted$EXE" "$fixture" > "$WORK/$name.hosted.log" 2>&1; then
    echo "  $name: hosted build failed"
    cat "$WORK/$name.hosted.log"
    return 1
  fi
  if ! "$WORK/compile_native$EXE" "$fixture" -o "$WORK_NATIVE/$name.ir" --pipeline typed --prelude --emit ir > "$WORK/$name.native.log" 2>&1; then
    echo "  $name: typed IR emission failed"
    cat "$WORK/$name.native.log"
    return 1
  fi
  timeout 30 "$WORK/$name.hosted$EXE" > "$WORK/$name.hosted.out" 2>&1; hs=$?
  if [ "$hs" -ne 0 ] || { [ -n "$expected" ] && [ "$(< "$WORK/$name.hosted.out")" != "$expected" ]; }; then
    echo "  $name: hosted status or output differs"
    cat "$WORK/$name.hosted.out"
    return 1
  fi
  if ! "$WORK/compile_native$EXE" "$fixture" -o "$WORK_NATIVE/$name.native" --pipeline typed --prelude >> "$WORK/$name.native.log" 2>&1; then
    echo "  $name: Mach-O emission failed"
    cat "$WORK/$name.native.log"
    return 1
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then
    host_limited "$name: AArch64 Mach-O signature and execution require macOS arm64; hosted output, typed IR and Mach-O emission checked"
    return 0
  fi
  if ! codesign -v --strict "$WORK/$name.hosted$EXE" ||
     ! codesign -v --strict "$WORK/$name.native"; then
    echo "  $name: native build or signature verification failed"
    cat "$WORK/$name.native.log"
    return 1
  fi
  timeout 30 "$WORK/$name.native" > "$WORK/$name.native.out" 2>&1; ns=$?
  if [ "$ns" -ne "$hs" ] || ! cmp -s "$WORK/$name.hosted.out" "$WORK/$name.native.out"; then
    echo "  $name: hosted status $hs, native status $ns, or output differs"
    return 1
  fi
  echo "  $name: hosted and signed native output agree"
}
map_fixture="$REPO_NATIVE/bench/fixtures/lowcallrun_block_map_u.iyi"
cached_flow_fixture="$REPO_NATIVE/bench/fixtures/lowcallrun_block_cached_flow.iyi"
meta_name_fixture="$REPO_NATIVE/bench/fixtures/runtime_metaclass_name.iyi"
real_fixture_check block_map "$map_fixture" 'a-b' || status=1
real_fixture_check cached_flow "$cached_flow_fixture" "$(printf '7\n4')" || status=1
real_fixture_check meta_name "$meta_name_fixture" '' || status=1
# Compare the named macro-bearing method. The two IR printers differ only in
# signature attributes, label comments, and phi label spelling here.
meta_name_body() {
  awk '
    /^define .*IRLabel::name_text<Bool>:String/ { active=1; found=1; next }
    active && /^}/ { exit }
    active { sub(/[[:space:]]*;.*/, ""); gsub(/, label %/, ", %"); if ($0 != "") print }
    END { if (!found) exit 1 }
  ' "$1"
}
meta_target=()
meta_output="$WORK_NATIVE/meta_name_ir$EXE"
if [ "$HOST_ID" != darwin-arm64 ]; then
  meta_target=(--cross-compile --target aarch64-apple-darwin)
  meta_output="$WORK_NATIVE/meta_name_ir.o"
fi
if ! "$IYI" build ${meta_target[@]+"${meta_target[@]}"} --single-module --emit llvm-ir --no-debug -o "$meta_output" "$meta_name_fixture" > "$WORK/meta_name.ir-hosted.log" 2>&1 ||
   ! "$WORK/compile_native$EXE" "$meta_name_fixture" -o "$WORK_NATIVE/meta_name.ir-port" --pipeline typed --prelude --emit ir > "$WORK/meta_name.ir-port.log" 2>&1 ||
   ! meta_name_body "$WORK/meta_name_ir.ll" > "$WORK/meta_name.hosted.body" ||
   ! meta_name_body "$WORK/meta_name.ir-port" > "$WORK/meta_name.port.body" ||
   ! diff -u "$WORK/meta_name.hosted.body" "$WORK/meta_name.port.body"; then
  echo "  metaclass name: method IR differs from hosted"
  status=1
else
  echo "  metaclass name: macro-bearing method IR matches hosted"
fi
meta_name_mutation_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/meta_name.mutant$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/meta_name.mutant.build.log" 2>&1; then
    echo "  INVALID MUTANT: compiler did not build" >&2
    cat "$WORK/meta_name.mutant.build.log" >&2
    return 2
  fi
  if ! "$WORK/meta_name.mutant$EXE" "$meta_name_fixture" -o "$WORK_NATIVE/meta_name.mutant.ir" --pipeline typed --prelude --emit ir > "$WORK/meta_name.mutant.log" 2>&1; then
    echo '  INVALID MUTANT: typed IR emission failed'
    cat "$WORK/meta_name.mutant.log"
    return 2
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then
    meta_name_body "$WORK/meta_name.mutant.ir" > "$WORK/meta_name.mutant.body" || return 2
    cmp -s "$WORK/meta_name.port.body" "$WORK/meta_name.mutant.body"
    return $?
  fi
  if ! codesign -v --strict "$WORK/meta_name.mutant$EXE" ||
     ! "$WORK/meta_name.mutant$EXE" "$meta_name_fixture" -o "$WORK_NATIVE/meta_name.mutant.native" --pipeline typed --prelude > "$WORK/meta_name.mutant.log" 2>&1 ||
     ! codesign -v --strict "$WORK/meta_name.mutant.native"; then
    echo '  INVALID MUTANT: native build or signature failed'
    cat "$WORK/meta_name.mutant.log"
    return 2
  fi
  "$WORK/meta_name.mutant.native" > "$WORK/meta_name.mutant.out" 2>&1
  local result=$?
  if [ "$result" -eq 0 ]; then return 0; fi
  if [ "$result" -eq 1 ] && [ ! -s "$WORK/meta_name.mutant.out" ]; then return 1; fi
  echo 'INVALID: metaclass mutant did not reach the fixture assertion'
  cat "$WORK/meta_name.mutant.out"
  return 2
}
prove_mutation "metaclass macro scope uses its instance type" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  "      return TypeQueries.instance_type(scope).devirtualize.full_name" \
  "      return scope.full_name" -- meta_name_mutation_check || status=1


echo
echo "== 3a. Generic constructor inference and refusal boundaries"
for name in lowcallinfer_generic_new lowcallinfer_explicit_struct lowcallwait_generic_handwritten_new; do
  fixture="$REPO_NATIVE/bench/fixtures/$name.iyi"
  if ! "$IYI" build --prelude empty --no-debug -o "$WORK_NATIVE/$name.hosted$EXE" "$fixture" > "$WORK/$name.hosted.log" 2>&1 ||
     ! "$WORK/compile_native$EXE" "$fixture" -o "$WORK_NATIVE/$name.baseline.ir" --pipeline typed --emit ir > "$WORK/$name.native.log" 2>&1; then
    echo "  $name: hosted build or typed IR emission failed"
    cat "$WORK/$name.hosted.log" "$WORK/$name.native.log"
    status=1
    continue
  fi
  timeout 30 "$WORK/$name.hosted$EXE" > "$WORK/$name.hosted.out" 2>&1; hs=$?
  if [ "$hs" -ne 7 ]; then echo "  $name: hosted status $hs, expected 7"; status=1; continue; fi
  if ! "$WORK/compile_native$EXE" "$fixture" -o "$WORK_NATIVE/$name.native" --pipeline typed > "$WORK/$name.native.log" 2>&1; then
    echo "  $name: Mach-O emission failed"
    cat "$WORK/$name.native.log"
    status=1
    continue
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then
    host_limited "$name: AArch64 Mach-O signature and execution require macOS arm64"
    continue
  fi
  if ! codesign -v --strict "$WORK/$name.native"; then
    echo "  $name: native compilation or signature verification failed"
    cat "$WORK/$name.native.log"
    status=1
    continue
  fi
  timeout 30 "$WORK/$name.native" > "$WORK/$name.native.out" 2>&1; ns=$?
  if [ "$ns" -ne "$hs" ] || ! cmp -s "$WORK/$name.hosted.out" "$WORK/$name.native.out"; then
    echo "  $name: hosted status $hs, native status $ns, or output differs"
    status=1
  else
    echo "  $name: native and hosted status 7, stdout identical"
  fi
done
generic_wait_reason() {
  case "$1" in
    lowcallwait_generic_handwritten_make) printf "%s" "expected argument #1 to 'Maker.make' to be T, not Int32" ;;
    lowcallwait_generic_default_new) printf "%s" "expected argument #1 to 'Opt.new' to be T, not Int32" ;;
  esac
}
for name in lowcallwait_uninferred_generic_new lowcallwait_generic_handwritten_make lowcallwait_generic_default_new; do
  fixture="$REPO_NATIVE/bench/fixtures/$name.iyi"
  rm -f "$WORK/$name.native"
  if "$WORK/compile_native$EXE" "$fixture" -o "$WORK_NATIVE/$name.native" --pipeline typed --emit ir > "$WORK/$name.native.log" 2>&1 || [ -e "$WORK/$name.native" ]; then
    echo "  $name: expected refusal without an executable"
    status=1
  elif [ "$name" = lowcallwait_uninferred_generic_new ]; then
    if grep -Fq 'the receiver of new is the uninstantiated generic Hold(T).class: typing has not instantiated the owner' "$WORK/$name.native.log"; then
      echo "  $name: uninstantiated generic refused without an executable"
    else
      echo "  $name: unexpected refusal"
      status=1
    fi
  elif ! "$IYI" build --prelude empty --no-codegen "$fixture" > "$WORK/$name.hosted.log" 2>&1; then
    echo "  $name: hosted compiler unexpectedly refused"
    status=1
  elif ! grep -Fq "$(generic_wait_reason "$name")" "$WORK/$name.native.log"; then
    echo "  $name: unexpected port refusal"
    status=1
  else
    echo "  $name: hosted accepted; port refuses unbound generic T"
  fi
done
if "$IYI" build --prelude empty -o "$WORK_NATIVE/uninferred.hosted$EXE" "$REPO_NATIVE/bench/fixtures/lowcallwait_uninferred_generic_new.iyi" > "$WORK/uninferred.hosted.log" 2>&1; then
  echo "  uninferred generic: hosted compiler unexpectedly accepted"
  status=1
elif ! grep -Fq 'can'"'"'t infer `T`' "$WORK/uninferred.hosted.log" && ! grep -Fq "can't infer the type parameter T" "$WORK/uninferred.hosted.log"; then
  echo "  uninferred generic: hosted compiler refused for another reason"
  status=1
else
  echo "  uninferred generic: hosted compiler could not infer T"
fi

# Named constructor parameters use different temporary names; compare their runs.
for name in lowcallrun_named_new lowcallrun_new_default_shapes lowcallrun_new_overload_dispatch; do
  case "$name" in
    lowcallrun_named_new) want_status=35; want_output=213 ;;
    lowcallrun_new_default_shapes) want_status=63; want_output=21A3AB4CD567EF ;;
    lowcallrun_new_overload_dispatch) want_status=3; want_output="" ;;
  esac
  fixture="$REPO_NATIVE/bench/fixtures/$name.iyi"
  if ! "$IYI" build --prelude empty --no-debug -o "$WORK_NATIVE/$name.hosted$EXE" "$fixture" > "$WORK/$name.hosted.log" 2>&1 ||
     ! "$WORK/compile_native$EXE" "$fixture" -o "$WORK_NATIVE/$name.ir" --pipeline typed --emit ir > "$WORK/$name.native.log" 2>&1; then
    echo "  $name: hosted build or typed IR emission failed"
    cat "$WORK/$name.hosted.log" "$WORK/$name.native.log"
    status=1
    continue
  fi
  timeout 30 "$WORK/$name.hosted$EXE" > "$WORK/$name.hosted.out" 2>&1; hs=$?
  if [ $((hs & 255)) -ne "$want_status" ] || [ "$(< "$WORK/$name.hosted.out")" != "$want_output" ]; then
    echo "  $name: hosted status or output differs"
    status=1
    continue
  fi
  if ! "$WORK/compile_native$EXE" "$fixture" -o "$WORK_NATIVE/$name.native" --pipeline typed > "$WORK/$name.native.log" 2>&1; then
    echo "  $name: Mach-O emission failed"
    cat "$WORK/$name.native.log"
    status=1
    continue
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then
    : > "$WORK/$name.validated"
    host_limited "$name: AArch64 Mach-O signature and execution require macOS arm64"
    continue
  fi
  if ! codesign -v --strict "$WORK/$name.native"; then
    echo "  $name: native compilation or signature verification failed"
    cat "$WORK/$name.native.log"
    status=1
    continue
  fi
  timeout 30 "$WORK/$name.native" > "$WORK/$name.native.out" 2>&1; ns=$?
  if [ "$ns" -ne "$hs" ] || ! cmp -s "$WORK/$name.hosted.out" "$WORK/$name.native.out"; then
    echo "  $name: hosted/native status or output differs"
    status=1
  else
    echo "  $name: hosted and native output '$want_output', status $want_status"
    : > "$WORK/$name.validated"
  fi
done

fixture="$REPO_NATIVE/bench/fixtures/lowcallwait_super_forwarded_default.iyi"
if ! "$WORK/compile_native$EXE" "$fixture" -o "$WORK_NATIVE/super_default.ir" --pipeline typed --emit ir > "$WORK/super_default.native.log" 2>&1; then
  echo "  super forwarded default: typed IR emission failed"
  cat "$WORK/super_default.native.log"
  status=1
elif ! "$WORK/compile_native$EXE" "$fixture" -o "$WORK_NATIVE/super_default.native" --pipeline typed > "$WORK/super_default.native.log" 2>&1; then
  echo "  super forwarded default: native compilation failed"
  status=1
elif [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited 'super forwarded default: AArch64 Mach-O signature and execution require macOS arm64'
elif ! codesign -v --strict "$WORK/super_default.native"; then
  echo "  super forwarded default: native signature verification failed"
  status=1
else
  timeout 30 "$WORK/super_default.native" > "$WORK/super_default.native.out" 2>&1; ns=$?
  if [ "$ns" -ne 3 ] || ! cmp -s "$WORK/super_default.run" "$WORK/super_default.native.out"; then
    echo "  super forwarded default: native status $ns or output differs"
    status=1
  else
    echo "  super forwarded default: native matches hosted status 3"
  fi
fi

constructor_allocation_ir_check() {
  [ -n "$PY" ] || { echo 'INVALID: Python is required for the allocation IR check'; return 2; }
  "$PY" - "$(native_path "$1")" "$(native_path "$2")" <<'PY'
import re
import sys

ssa = r'%[-A-Za-z0-9$._]+'
alloc_re = re.compile(r'^\s*(' + ssa + r')\s*=\s*call\b.*\bptr\b.*@malloc\(')
load_re = re.compile(r'^\s*(' + ssa + r')\s*=\s*load\s+ptr\s*,\s*ptr\s+(' + ssa + r')(?:,|\s*$)')
store_re = re.compile(r'^\s*store\s+ptr\s+(' + ssa + r')\s*,\s*ptr\s+' + ssa + r'(?:,|\s*$)')

def allocation_flow(path):
    with open(path, encoding="utf-8") as source:
        lines = source.read().splitlines()
    flows = []
    active = False
    allocations = set()
    loads = {}
    stores = set()
    for line in lines:
        if line.startswith("define "):
            active = "Box(" in line and "::new" in line
            allocations, loads, stores = set(), {}, set()
        elif active and line == "}":
            for allocated in allocations:
                indirect = any(origin == allocated and loaded in stores for loaded, origin in loads.items())
                flows.append((allocated in stores, indirect))
            active = False
        elif active:
            alloc = alloc_re.match(line)
            if alloc and "Box(" in line:
                allocations.add(alloc.group(1))
            load = load_re.match(line)
            if load:
                loads[load.group(1)] = load.group(2)
            store = store_re.match(line)
            if store:
                stores.add(store.group(1))
    return flows

try:
    baseline = allocation_flow(sys.argv[1])
    mutant = allocation_flow(sys.argv[2])
except (OSError, UnicodeError) as error:
    print("INVALID: cannot inspect allocation IR:", error)
    sys.exit(2)
if not baseline or not all(direct and not indirect for direct, indirect in baseline):
    print("INVALID: baseline Box constructor does not store its allocated pointer directly")
    sys.exit(2)
if any(indirect and not direct for direct, indirect in mutant):
    print("decisive: Box constructor loads from its allocation before storing the result")
    sys.exit(1)
if mutant and all(direct and not indirect for direct, indirect in mutant):
    sys.exit(0)
print("INVALID: mutant Box constructor has no expected allocation flow")
sys.exit(2)
PY
}

# A mutant that cannot build is invalid, not a caught regression. The marker
# crosses the mutation helper's subprocess boundary and makes that case red.
generic_constructor_check() {
  local name fixture result
  if ! "$IYI" build -o "$WORK_NATIVE/constructor.check.tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/constructor.check.build.log" 2>&1; then
    echo "INVALID MUTANT: constructor compiler did not build"
    cat "$WORK/constructor.check.build.log"
    return 2
  fi
  for name in lowcallinfer_generic_new lowcallinfer_explicit_struct lowcallwait_generic_handwritten_new; do
    fixture="$REPO_NATIVE/bench/fixtures/$name.iyi"
    result=0
    "$WORK/constructor.check.tool$EXE" "$fixture" -o "$WORK_NATIVE/constructor.check.ir" --pipeline typed --emit ir > "$WORK/constructor.check.log" 2>"$WORK/constructor.check.err" || result=$?
    if [ "$result" -ne 0 ]; then
      if [ "${CONSTRUCTOR_REFUSAL:-}" = inferred ] && [ "$name" = lowcallinfer_generic_new ] &&
         [ -f "$WORK/constructor.baseline" ] &&
         expected_refusal "$result" "$WORK/constructor.check.err" src/compiler/lower/pending.iyi '^lower: visit\(the receiver of new is the uninstantiated generic Cell\(T\)\.class: typing has not instantiated the owner\) \(hosted codegen\.cr\) is not ported yet$'; then
        echo "decisive: $name: $(refusal_note "$result" "$WORK/constructor.check.err")"
        return 1
      fi
      echo "INVALID MUTANT: constructor $name did not emit IR"
      cat "$WORK/constructor.check.log" "$WORK/constructor.check.err"
      return 2
    fi
    if [ "${CONSTRUCTOR_REFUSAL:-}" = class-load ] && [ "$name" = lowcallinfer_generic_new ]; then
      if [ ! -f "$WORK/constructor.baseline" ]; then
        echo 'INVALID: class-allocation mutation has no passing baseline'
        return 2
      fi
      constructor_allocation_ir_check "$WORK/$name.baseline.ir" "$WORK/constructor.check.ir"
      result=$?
      if [ "$result" -ne 0 ]; then return "$result"; fi
    fi
    if ! "$WORK/constructor.check.tool$EXE" "$fixture" -o "$WORK_NATIVE/constructor.check.exe" --pipeline typed > "$WORK/constructor.check.log" 2>&1; then
      echo "INVALID MUTANT: constructor $name did not emit Mach-O"
      cat "$WORK/constructor.check.log"
      return 2
    fi
    if [ "$HOST_ID" != darwin-arm64 ]; then
      cmp -s "$WORK/$name.baseline.ir" "$WORK/constructor.check.ir" || return 1
      continue
    fi
    if ! codesign -v --strict "$WORK/constructor.check.exe"; then
      echo "INVALID MUTANT: constructor $name did not link or sign"
      cat "$WORK/constructor.check.log"
      return 2
    fi
    run_fixture_status "$WORK/constructor.check.exe" "$WORK/constructor.check.out" "$WORK/constructor.check.status" || return 2
    result="$(< "$WORK/constructor.check.status")"
    [ "$result" -eq 7 ] && cmp -s "$WORK/constructor.check.out" "$WORK/$name.hosted.out" || return 1
  done
  for name in lowcallwait_generic_handwritten_make lowcallwait_generic_default_new; do
    fixture="$REPO_NATIVE/bench/fixtures/$name.iyi"
    rm -f "$WORK/constructor.check.ir"
    "$WORK/constructor.check.tool$EXE" "$fixture" -o "$WORK_NATIVE/constructor.check.ir" --pipeline typed --emit ir > "$WORK/constructor.check.log" 2>&1
    result=$?
    if [ "$result" -eq 0 ] && [ -s "$WORK/constructor.check.ir" ]; then return 1; fi
    if [ "$result" -ne 1 ] || [ -e "$WORK/constructor.check.ir" ] || ! grep -Fq "$(generic_wait_reason "$name")" "$WORK/constructor.check.log"; then
      echo "INVALID MUTANT: $name did not reach its named refusal"
      cat "$WORK/constructor.check.log"
      return 2
    fi
  done
}

constructor_prove() {
  rm -f "$WORK/constructor.invalid"
  prove_mutation "$@" -- generic_constructor_check
  local result=$?
  if [ -e "$WORK/constructor.invalid" ]; then
    echo "  INVALID MUTANT: compiler did not build (see $WORK/constructor.check.build.log)"
    return 1
  fi
  return "$result"
}

rm -f "$WORK/constructor.invalid"
if generic_constructor_check && [ ! -e "$WORK/constructor.invalid" ]; then
  echo "  constructor mutation baseline passed"
  : > "$WORK/constructor.baseline"
  constructor_prove "non-constructor methods infer class variables" "$REPO/src/compiler/semantic/match.iyi" \
    '    return nil unless definition.name == "new"' '    nil' || status=1
  constructor_prove "omitted arguments infer class variables" "$REPO/src/compiler/semantic/match.iyi" \
    '    return nil unless given == definition.args.size' '    nil' || status=1
  CONSTRUCTOR_REFUSAL=inferred constructor_prove "lowering ignores the inferred receiver" "$REPO/src/compiler/lower/call.iyi" \
    '  if recorded = low.analysed.call_receiver?(node)' \
    '  if recorded = (node.obj.nil? ? low.analysed.call_receiver?(node) : nil)' || status=1
  # Leaving a struct address is indistinguishable in the exercised callers:
  # their stores and returns load it. Force the opposite classification instead.
  CONSTRUCTOR_REFUSAL=class-load constructor_prove "class allocation is loaded as a struct" "$REPO/src/compiler/lower/call.iyi" \
    '      if passed_by_value?(allocated_type)' '      if true' || status=1
else
  echo "  constructor mutation baseline failed or did not build"
  status=1
fi

echo
echo "== 3b. A recursive call targets the instance still being typed"
if [ -x "$WORK/compile_native$EXE" ]; then
  for fixture in "$REPO"/bench/fixtures/sem_bodies_recursion_mutual.iyi "$REPO"/bench/fixtures/sem_bodies_recursion_state.iyi "$REPO"/bench/fixtures/sem_bodies_recursive_helper.iyi; do
    name="$(basename "$fixture" .iyi)"
    "$WORK/compile_native$EXE" "$(native_path "$fixture")" -o "$WORK_NATIVE/$name.probe.exe$EXE" --pipeline typed --probe-phase --keep-going > "$WORK/$name.probe" 2>&1
    probe_status=$?
    if [ "$probe_status" -gt 1 ]; then
      echo "  $name: invalid probe exit $probe_status"
      cat "$WORK/$name.probe"
      status=1
      continue
    fi
    if grep -E 'untyped instantiated parameter|no type for the call' "$WORK/$name.probe"; then
      echo "  $name: a cycle call targets an untyped clone"
      status=1
    elif ! awk '/^table: .* defs-lowered-clean=/ { found = 1 } END { exit !found }' "$WORK/$name.probe"; then
      echo "  $name: probe produced no lowering table"
      status=1
    else
      echo "  $name: every probe root lowered without a missing call target"
    fi
  done
else
  echo "  recursion probe skipped: the native tool did not build"
  status=1
fi

echo
echo "== 3c. Top-level imports and inherited names across units"
unit_fixture="$REPO_NATIVE/bench/fixtures/inherited_unit_name/main.iyi"
if [ -x "$WORK/compile_native$EXE" ] &&
   "$IYI" build --prelude empty --no-debug -o "$WORK_NATIVE/unit_name.hosted$EXE" "$unit_fixture" > "$WORK/unit_name.hosted.log" 2>&1 &&
   "$WORK/compile_native$EXE" "$unit_fixture" -o "$WORK_NATIVE/unit_name.ir" --pipeline typed --emit ir > "$WORK/unit_name.native.log" 2>&1 &&
   "$WORK/compile_native$EXE" "$unit_fixture" -o "$WORK_NATIVE/unit_name.native" --pipeline typed >> "$WORK/unit_name.native.log" 2>&1; then
  timeout 30 "$WORK/unit_name.hosted$EXE" > "$WORK/unit_name.hosted.out" 2>&1; hs=$?
  if [ "$hs" -ne 7 ]; then
    echo "  FAIL: inherited unit name hosted status $hs, expected 7"
    status=1
  elif [ "$HOST_ID" != darwin-arm64 ]; then
    host_limited 'inherited unit name: AArch64 Mach-O signature and execution require macOS arm64'
  elif ! codesign -v --strict "$WORK/unit_name.native"; then
    echo "  FAIL: inherited unit name native build or signature verification failed"
    cat "$WORK/unit_name.native.log"
    status=1
  else
    timeout 30 "$WORK/unit_name.native" > "$WORK/unit_name.native.out" 2>&1; ns=$?
    if [ "$ns" -eq "$hs" ] && cmp -s "$WORK/unit_name.hosted.out" "$WORK/unit_name.native.out"; then
      echo "  inherited unit name: native executable runs to the hosted result (status 7, stdout identical)"
    else
      echo "  FAIL: inherited unit name: native status $ns, hosted $hs"
      status=1
    fi
  fi
else
  echo "  FAIL: inherited unit name: hosted build or typed IR emission failed"
  for log in "$WORK/unit_name.hosted.log" "$WORK/unit_name.native.log"; do
    if [ -f "$log" ]; then cat "$log"; fi
  done
  status=1
fi

echo
echo "== 4. Mutation proofs: the gate must catch each patch to the ported code"
# The check rebuilds the driver from the patched source and requires every call fixture
# to match the hosted module exactly. It returns 0 only on the unmutated behaviour.
# Keep diagnostics past WORK cleanup. An invalid mutant must fail the proof,
# while a failed baseline must still return nonzero to its caller.
invalid_mutation() {
  { echo "INVALID MUTANT: $1"; cat "$1"; } | tee -a "$WORK/general-mutation.invalid" >&2
  return 2
}
driver_assertion_result() {
  local file="$1" result="$2" message="$3" line="$4"
  if [ "$result" -eq 0 ]; then return 0; fi
  if [ "$result" -eq 1 ] &&
     grep -Fxq "iyi: panic: $message" "$file" &&
     tr '\\' '/' < "$file" | grep -Fq "bench/selfhost_lower_calls_exercise.iyi:$line"; then
    return 1
  fi
  echo "INVALID: driver did not reach its expected assertion"
  cat "$file"
  return 2
}

lower_calls_check() {
  local expected_mutant_refusal="${1:-}" expected_fixture="${2:-}" expected_site="${3:-src/compiler/lower/pending.iyi}" expected_source_line="${4:-}" expected_stack="${5:-}" result
  if ! "$IYI" build -o "$WORK_NATIVE/mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/mut.build.log" 2>&1; then
    invalid_mutation "$WORK/mut.build.log"
    return $?
  fi
  for fixture in "$REPO"/bench/fixtures/lowcall_*.iyi; do
    name="$(basename "$fixture" .iyi)"
    if [ -n "$(waiting_reason "$name")" ]; then
      "$WORK/mut$EXE" lower "$(native_path "$fixture")" "$WORK_NATIVE/$name.oracle.ll" > "$WORK/mut.out" 2> "$WORK/mut.err" && return 1
      expected="$(waiting_reason "$name")"
      awk -v expected="$expected" 'index($0, expected) { found = 1 } END { exit !found }' "$WORK/mut.err" || return 1
      continue
    fi
    "$WORK/mut$EXE" lower "$(native_path "$fixture")" "$WORK_NATIVE/$name.oracle.ll" > "$WORK/mut.out" 2>"$WORK/mut.err"
    result=$?
    if [ "$result" -ne 0 ]; then
      if [ -n "$expected_mutant_refusal" ] &&
         { [ -z "$expected_fixture" ] || [ "$name" = "$expected_fixture" ]; } &&
         summary_check "$WORK/$name.port.out" >/dev/null &&
         expected_refusal "$result" "$WORK/mut.err" "$expected_site" "$expected_mutant_refusal"; then
        if [ "$expected_site" = refuse_port ]; then
          if [ -z "$expected_source_line" ] ||
             ! awk -v prefix="  source: $(native_path "$fixture"):$expected_source_line:" 'index($0, prefix) == 1 && substr($0, length(prefix) + 1) ~ /^[0-9]+$/ { found=1 } END { exit !found }' "$WORK/mut.err"; then
            echo "INVALID: $name lacks the required localized source diagnostic"
            cat "$WORK/mut.err"
            return 2
          fi
        fi
        if [ -n "$expected_stack" ]; then
          # A host listed for this frame prints a panic with no stack frames at all, so the frame cannot be named
          # there (bench/selfhost_lower_calls_provenance.known, an exact list: the frame appearing, or any frame,
          # fails until the row is removed).
          stack_known="$(awk -v host="$HOST_ID" -v frame="$expected_stack" '$1 == host && $2 == frame { print; exit }' "$REPO/bench/selfhost_lower_calls_provenance.known")"
          if [ -n "$stack_known" ]; then
            if grep -Eq '0x[0-9a-fA-F]{6,}' "$WORK/mut.err" || grep -Fq "$expected_stack" "$WORK/mut.err"; then
              echo "INVALID: $name now prints stack frames on $HOST_ID: remove its row from bench/selfhost_lower_calls_provenance.known"
              cat "$WORK/mut.err"
              return 2
            fi
            host_limited "lower_calls: the panic on $HOST_ID prints no stack frames, so $expected_stack is not checked as its provenance"
          elif ! grep -Fq "$expected_stack" "$WORK/mut.err"; then
            echo "INVALID: $name lacks the expected diagnostic provenance"
            cat "$WORK/mut.err"
            return 2
          fi
        fi
        echo "decisive: $name: $(refusal_note "$result" "$WORK/mut.err")"
        return 1
      fi
      echo "INVALID: calls mutant failed outside its expected comparison ($name)"
      cat "$WORK/mut.err"
      return 2
    fi
    summary_check "$WORK/mut.out" || return $?
  done
  return 0
}

prove_mutation "a generated new evaluates defaults before allocating" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '    if @program.generated_new?(definition) && definition.double_splat.nil? && (named || definition.splat_index || node.args.size != definition.args.size)' \
  '    if false' -- lower_calls_check || status=1
prove_mutation "a forwarded initialize loses its definition location" "$REPO/src/compiler/semantic/new.iyi" \
  '    init.at(anchor)' '    anchor' -- lower_calls_check || status=1

overload_dispatch_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/overload.check.tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/overload.check.build.log" 2>&1; then
    invalid_mutation "$WORK/overload.check.build.log"
    return 2
  fi
  local result=0
  [ -f "$WORK/lowcallrun_new_overload_dispatch.validated" ] || { echo 'INVALID: overload fixture has no passing baseline'; return 2; }
  "$WORK/overload.check.tool$EXE" "$REPO_NATIVE/bench/fixtures/lowcallrun_new_overload_dispatch.iyi" -o "$WORK_NATIVE/overload.check.ir" --pipeline typed --emit ir > "$WORK/overload.check.log" 2>"$WORK/overload.check.err" || result=$?
  if [ "$result" -ne 0 ]; then
    if expected_refusal "$result" "$WORK/overload.check.err" src/compiler/lower/pending.iyi '^lower: visit\(downcast String to Int32 \(hosted cast\.cr downcast_distinct, not ported\)\) \(hosted codegen\.cr\) is not ported yet$'; then
      echo "decisive: overload dispatch: $(refusal_note "$result" "$WORK/overload.check.err")"
      return 1
    fi
    echo 'INVALID MUTANT: overload fixture did not emit IR'
    cat "$WORK/overload.check.log" "$WORK/overload.check.err"
    return 2
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then
    cmp -s "$WORK/lowcallrun_new_overload_dispatch.ir" "$WORK/overload.check.ir"
    return $?
  fi
  if ! "$WORK/overload.check.tool$EXE" "$REPO_NATIVE/bench/fixtures/lowcallrun_new_overload_dispatch.iyi" -o "$WORK_NATIVE/overload.check.exe" --pipeline typed > "$WORK/overload.check.log" 2>&1 ||
     ! codesign -v --strict "$WORK/overload.check.exe" > "$WORK/overload.signature.log" 2>&1; then
    echo 'INVALID MUTANT: overload fixture did not link or sign'
    cat "$WORK/overload.check.log" "$WORK/overload.signature.log"
    return 2
  fi
  local result
  run_fixture_status "$WORK/overload.check.exe" "$WORK/overload.check.out" "$WORK/overload.check.status" || return 2
  result="$(< "$WORK/overload.check.status")"
  [ "$result" -eq 3 ] && [ ! -s "$WORK/overload.check.out" ]
}
prove_mutation "constructor overload wrappers share a typing frame" "$REPO/src/compiler/semantic/new.iyi" \
  '    return restriction.clone' '    return nil' -- overload_dispatch_check || status=1
cleanup_probe_ok() {
  if ! "$IYI" build -o "$WORK_NATIVE/cleanup_probe$EXE" "$REPO_NATIVE/bench/selfhost_probe_cleanup.iyi" > "$WORK/cleanup_probe.build.log" 2>&1; then
    echo "INVALID MUTANT: cleanup probe failed to build" >&2
    cat "$WORK/cleanup_probe.build.log" >&2
    return 2
  fi
  if [ "$HOST_OS" = darwin ] && ! codesign -v --strict "$WORK/cleanup_probe$EXE"; then return 2; fi
  "$WORK/cleanup_probe$EXE" > "$WORK/cleanup_probe.out" 2>&1
  local result=$?
  if [ "$result" -eq 0 ]; then return 0; fi
  if [ "$result" -eq 1 ] &&
     grep -Fxq 'iyi: panic: wrong survivors' "$WORK/cleanup_probe.out" &&
     tr '\\' '/' < "$WORK/cleanup_probe.out" | grep -Fq 'bench/selfhost_probe_cleanup.iyi:17'; then return 1; fi
  echo 'INVALID: cleanup probe failed outside its expected assertion'
  cat "$WORK/cleanup_probe.out"
  return 2
}
if cleanup_probe_ok; then
  prove_mutation "failed probe cleanup removes prior functions" "$REPO/src/compiler/lower/fun.iyi" \
    '    added << fn unless prior.includes?(fn.name)' '    added << fn' -- cleanup_probe_ok || status=1
else
  echo "  FAIL: cleanup probe baseline failed"
  status=1
fi

cat > "$WORK/recursive-inferred-probe.iyi" <<'IYI'
import bench/lib/lower_gate::{analyse}
import compiler/syntax/ast::{Call}
import compiler/syntax/visitor::{Visitor}

class InferredCallWalk < Visitor
  getter calls : Array(Call)
  def initialize
    @calls = [] of Call
  end
  def visit(node : Call) : Bool
    @calls << node
    true
  end
end

fixture = Program.args[0]
analysis = analyse(File.read(fixture), fixture, true)
walk = InferredCallWalk.new
analysis.visitor.typed_instances.each do |instance|
  instance.definition.accept(walk) if instance.definition.name == "recursive_inferred_count"
end
walk.calls.each do |call|
  next unless call.name == "&+"
  if loc = call.location
    next unless loc.line_number == 10
    if type = analysis.visitor.type_of?(call)
      puts "INFERRED-ADD type=#{type.full_name}"
    else
      puts "INFERRED-ADD type=missing"
    end
  end
end
IYI
recursive_inferred_check() {
  if ! IYI_PATH="$PROBE_IYI_PATH" "$IYI" build -o "$WORK_NATIVE/recursive-mut$EXE" "$WORK_NATIVE/recursive-inferred-probe.iyi" > "$WORK/recursive-mut.build.log" 2>&1; then
    invalid_mutation "$WORK/recursive-mut.build.log"
    return 2
  fi
  if ! "$WORK/recursive-mut$EXE" "$REPO_NATIVE/bench/fixtures/lowcall_recursive_inferred.iyi" > "$WORK/recursive-mut.out" 2>"$WORK/recursive-mut.err"; then
    echo 'INVALID: recursive-inference semantic probe failed'
    cat "$WORK/recursive-mut.out" "$WORK/recursive-mut.err"
    return 2
  fi
  if grep -Fxq 'INFERRED-ADD type=Int32' "$WORK/recursive-mut.out" &&
     ! grep -Fxq 'INFERRED-ADD type=missing' "$WORK/recursive-mut.out"; then return 0; fi
  if [ -f "$WORK/recursive-inferred.baseline" ] && grep -Fxq 'INFERRED-ADD type=missing' "$WORK/recursive-mut.out"; then
    echo 'decisive: recursive_inferred_count line 10 has no inferred addition type'
    return 1
  fi
  echo 'INVALID: recursive-inference probe did not identify the expected addition'
  cat "$WORK/recursive-mut.out"
  return 2
}
if recursive_inferred_check; then
  : > "$WORK/recursive-inferred.baseline"
  prove_mutation "an inferred recursive body is not retyped" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '    if recursive_frame.cyclic' '    if false && recursive_frame.cyclic' -- recursive_inferred_check || status=1
else
  echo 'FAIL: recursive-inference semantic baseline did not type the addition'
  status=1
fi

underscore_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/underscore-mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/underscore-mut.build.log" 2>&1; then
    invalid_mutation "$WORK/underscore-mut.build.log"
    return $?
  fi
  local result=0
  "$WORK/underscore-mut$EXE" lower "$REPO_NATIVE/bench/fixtures/lowdecl_multi_assign_underscore.iyi" "$WORK_NATIVE/lowdecl_multi_assign_underscore.oracle.ll" > "$WORK/underscore-mut.out" 2>"$WORK/underscore-mut.err" || result=$?
  if [ "$result" -ne 0 ]; then
    if [ -f "$WORK/underscore.baseline" ] && expected_refusal "$result" "$WORK/underscore-mut.err" src/compiler/lower/pending.iyi '^lower: visit\(Assign to a target that is not a variable\) \(hosted codegen\.cr\) is not ported yet$'; then
      echo "decisive: $(refusal_note "$result" "$WORK/underscore-mut.err")"
      return 1
    fi
    echo 'INVALID: underscore fixture failed outside the expected refusal'
    cat "$WORK/underscore-mut.out" "$WORK/underscore-mut.err"
    return 2
  fi
  summary_check "$WORK/underscore-mut.out"
}
if underscore_check; then
  : > "$WORK/underscore.baseline"
  prove_mutation "underscore assignment is refused" "$REPO/src/compiler/lower/lower.iyi" \
    '  if node.target.is_a?(Underscore)' '  if false && node.target.is_a?(Underscore)' -- underscore_check || status=1
else
  echo 'FAIL: underscore assignment baseline differs'
  status=1
fi

block_decl_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/block-decl-mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/block-decl-mut.build.log" 2>&1; then
    invalid_mutation "$WORK/block-decl-mut.build.log"
    return $?
  fi
  for name in lowdecl_typedecl_block lowdecl_typedecl_block_widen lowdecl_typedecl_block_nested lowdecl_typedecl_block_later_nil lowdecl_typedecl_reference; do
    calls_run_lower "$WORK/block-decl-mut$EXE" "$name" "$WORK/block-decl-mut.out" "$WORK/block-decl-mut.err" src/compiler/semantic/main_visitor.iyi "^argument 'status' of 'LibC#exit' must be Int32, not \\(Int32 \\| Nil\\)$" || return $?
    summary_check "$WORK/block-decl-mut.out" || return $?
  done
}
prove_mutation "a typed local keeps its initializer's storage type" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '        stored = proc_compatible ? decl_type : val_type' \
  '        stored = decl_type' -- block_decl_check || status=1

block_storage_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/block-storage-mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/block-storage-mut.build.log" 2>&1; then
    invalid_mutation "$WORK/block-storage-mut.build.log"
    return $?
  fi
  calls_run_lower "$WORK/block-storage-mut$EXE" lowdecl_block_branch_storage "$WORK/block-storage-mut.out" "$WORK/block-storage-mut.err" src/compiler/lower/pending.iyi '^lower: visit\(assign First to Int32 \(hosted assign_distinct, not ported\)\) \(hosted codegen\.cr\) is not ported yet$' || return $?
  summary_check "$WORK/block-storage-mut.out"
}
prove_mutation "block locals retain only the first assignment type" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      unions[name] = @program.type_merge(previous, type)' \
  '      unions[name] = previous' -- block_storage_check || status=1

block_loop_rw_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/block-loop-rw-mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/block-loop-rw-mut.build.log" 2>&1; then
    invalid_mutation "$WORK/block-loop-rw-mut.build.log"
    return $?
  fi
  "$WORK/block-loop-rw-mut$EXE" lower "$REPO_NATIVE/bench/fixtures/lowcall_block_nilable_rw.iyi" "$WORK_NATIVE/lowcall_block_nilable_rw.oracle.ll" > "$WORK/block-loop-rw-mut.out" 2>"$WORK/block-loop-rw-mut.err" || { cat "$WORK/block-loop-rw-mut.err"; return 2; }
  summary_check "$WORK/block-loop-rw-mut.out"
}
prove_mutation "a loop yield sees only the first block invocation" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      if @block_may_repeat' '      if false && @block_may_repeat' -- block_loop_rw_check || status=1

block_branch_rw_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/block-branch-rw-mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/block-branch-rw-mut.build.log" 2>&1; then
    invalid_mutation "$WORK/block-branch-rw-mut.build.log"
    return $?
  fi
  "$WORK/block-branch-rw-mut$EXE" lower "$REPO_NATIVE/bench/fixtures/lowcall_block_branch_nilable_rw.iyi" "$WORK_NATIVE/lowcall_block_branch_nilable_rw.oracle.ll" > "$WORK/block-branch-rw-mut.out" 2>"$WORK/block-branch-rw-mut.err" || { cat "$WORK/block-branch-rw-mut.err"; return 2; }
  summary_check "$WORK/block-branch-rw-mut.out"
}
prove_mutation "one yield overwrites another yield's entry flow" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '            ctx[k] = @program.type_merge(ctx[k], new_v)' '            ctx[k] = new_v' -- block_branch_rw_check || status=1

block_lexical_locals_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/block-lexical-mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/block-lexical-mut.build.log" 2>&1; then
    invalid_mutation "$WORK/block-lexical-mut.build.log"
    return $?
  fi
  calls_run_lower "$WORK/block-lexical-mut$EXE" lowcall_block_lexical_locals "$WORK/block-lexical-mut.out" "$WORK/block-lexical-mut.err" src/compiler/lower/pending.iyi "${1:-}" || return $?
  summary_check "$WORK/block-lexical-mut.out"
}
prove_mutation "a block inherits later caller locals" "$REPO/src/compiler/lower/call.iyi" \
  '      block_vars[name] = var if name == "self" || writer_vars.has_key?(name)' \
  '      block_vars[name] = var' -- block_lexical_locals_check '^lower: visit\(assign Int32 to Bool \(hosted assign_distinct, not ported\)\) \(hosted codegen\.cr\) is not ported yet$' || status=1
cat > "$WORK/writer-owner-probe.iyi" <<'IYI'
import bench/lib/lower_gate::{analyse}
import compiler/syntax/ast::{Block}
import compiler/syntax/visitor::{Visitor}

class WriterBlockWalk < Visitor
  getter blocks : Array(Block)
  def initialize
    @blocks = [] of Block
  end
  def visit(node : Block) : Bool
    @blocks << node
    true
  end
end

fixture = Program.args[0]
analysis = analyse(File.read(fixture), fixture, true)
walk = WriterBlockWalk.new
analysis.root.accept(walk)
walk.blocks.each do |block|
  if loc = block.location
    if loc.line_number == 86
      puts "WRITER-OWNER=#{analysis.visitor.block_owners[block]?.nil? ? "missing" : "present"}"
    end
  end
end
IYI
writer_owner_check() {
  if ! IYI_PATH="$PROBE_IYI_PATH" "$IYI" build -o "$WORK_NATIVE/writer-owner$EXE" "$WORK_NATIVE/writer-owner-probe.iyi" > "$WORK/writer-owner.build.log" 2>&1; then
    echo 'INVALID: writer-owner semantic probe did not build'
    cat "$WORK/writer-owner.build.log"
    return 2
  fi
  if ! "$WORK/writer-owner$EXE" "$REPO_NATIVE/bench/fixtures/lowcall_block_lexical_locals.iyi" > "$WORK/writer-owner.out" 2>"$WORK/writer-owner.err"; then
    echo 'INVALID: writer-owner semantic probe failed'
    cat "$WORK/writer-owner.out" "$WORK/writer-owner.err"
    return 2
  fi
  if grep -Fxq 'WRITER-OWNER=present' "$WORK/writer-owner.out" &&
     ! grep -Fxq 'WRITER-OWNER=missing' "$WORK/writer-owner.out"; then return 0; fi
  if [ -f "$WORK/writer-owner.baseline" ] && grep -Fxq 'WRITER-OWNER=missing' "$WORK/writer-owner.out"; then
    echo 'decisive: via_fun block at line 86 lost its writer ownership'
    return 1
  fi
  echo 'INVALID: writer-owner probe did not find the expected block'
  cat "$WORK/writer-owner.out"
  return 2
}
if writer_owner_check; then
  : > "$WORK/writer-owner.baseline"
  prove_mutation "a fun visitor loses block writer ownership" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '    inner.block_owners = @block_owners' \
    '    inner.block_owners = NodeMap(BlockOwner).new' -- writer_owner_check || status=1
else
  echo 'FAIL: via_fun block writer ownership baseline was not recorded'
  status=1
fi

block_nested_storage_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/block-nested-mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/block-nested-mut.build.log" 2>&1; then
    invalid_mutation "$WORK/block-nested-mut.build.log"
    return $?
  fi
  calls_run_lower "$WORK/block-nested-mut$EXE" lowcall_block_nested_local_writes "$WORK/block-nested-mut.out" "$WORK/block-nested-mut.err" src/compiler/lower/pending.iyi '^lower: visit\(assign \(Answer\+ \| Nil\) to Nil \(union into a non-mixed target, hosted assign_distinct\)\) \(hosted codegen\.cr\) is not ported yet$' || return $?
  summary_check "$WORK/block-nested-mut.out"
}
prove_mutation "a block local misses its nested blocks' writes" "$REPO/src/compiler/lower/call.iyi" \
  '        storage = low.analysed.program.type_merge(storage, written)' \
  '        storage = t.nil? ? low.analysed.program.nil_type : t.as(Type)' -- block_nested_storage_check || status=1
prove_mutation "a nested block writes into its yielding def's storage" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '        @var_unions = owner.local_storage.unions' \
  '        @var_unions = callee_var_unions' -- block_nested_storage_check || status=1

block_cache_check() {
  local name="$1"
  if ! "$IYI" build -o "$WORK_NATIVE/block-cache-mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/block-cache-mut.build.log" 2>&1; then
    invalid_mutation "$WORK/block-cache-mut.build.log"
    return $?
  fi
  calls_run_lower "$WORK/block-cache-mut$EXE" "$name" "$WORK/block-cache-mut.out" "$WORK/block-cache-mut.err" src/compiler/lower/pending.iyi "${2:-}" || return $?
  summary_check "$WORK/block-cache-mut.out"
}
prove_mutation "a reused block instance drops its writes" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '          replay_block_flow(flow)' '          flow' -- block_cache_check lowcall_block_cached_writes || status=1
prove_mutation "a reused block instance ignores its entry flow" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '    block_entry_holds?(flow)' '    true' -- block_cache_check lowcall_block_cached_entry || status=1
prove_mutation "a reused block instance ignores its writer storage" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '    return false unless flow.storage.object_id == @var_unions.object_id' \
  '    return false unless true' -- block_cache_check lowcall_block_cached_entry '^lower: visit\(assign Int32 to Nil \(hosted assign_distinct, not ported\)\) \(hosted codegen\.cr\) is not ported yet$' || status=1
prove_mutation "a while next carries no flow to its loop head" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      @while_next_vars.last << @vars.dup unless @while_next_vars.empty?' '      nil' -- block_cache_check lowcall_while_next_flow || status=1
prove_mutation "a revisited literal is expanded again" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '    tree = @expansions[node]?' '    tree = nil' -- block_cache_check lowcall_while_next_flow || status=1
prove_mutation "a block next carries no flow" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '        merge_block_exit(ctx, @vars, block)' '        ctx' -- block_cache_check lowcall_block_exit_flow || status=1
prove_mutation "a block break carries no flow" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '          exit_owner.exits.each { |state| merge_block_exit(ctx_vars, state, blk) }' '          exit_owner.exits' -- block_cache_check lowcall_block_exit_flow || status=1

uncovered_mutation_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/uncovered-mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/uncovered-mut.build.log" 2>&1; then
    cat "$WORK/uncovered-mut.build.log"
    touch "$WORK/uncovered.invalid"
    return 2
  fi
  uncovered_check "$WORK/uncovered-mut$EXE"
}
if uncovered_check "$WORK/port$EXE"; then
  prove_mutation "uncovered argument combinations are accepted" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '    found = lookup_call_arms(receiver, receiver, node.name, node.args, node, ArmWalk::Parents, infer_class_vars)
    trace_arg_dispatch(receiver, node.name, node.args, node, found, nil)
    unless found.cover_all?' \
    '    found = lookup_call_arms(receiver, receiver, node.name, node.args, node, ArmWalk::Parents, infer_class_vars)
    trace_arg_dispatch(receiver, node.name, node.args, node, found, nil)
    unless true' -- uncovered_mutation_check || status=1
else
  echo "  FAIL: uncovered union baseline did not refuse"
  status=1
fi
if [ -e "$WORK/uncovered.invalid" ]; then
  echo "  FAIL: uncovered union mutation failed to compile"
  status=1
fi

triple_check() {
  "$IYI" build -o "$WORK_NATIVE/triple-mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/triple-mut.build.log" 2>&1 || { invalid_mutation "$WORK/triple-mut.build.log"; return 2; }
  "$WORK/triple-mut$EXE" triple > "$WORK/triple-mut.out" 2>&1
  driver_assertion_result "$WORK/triple-mut.out" "$?" 'macOS target lacks frame pointers' 35
}

free_dispatch_check() {
  local label="${1:-baseline}"
  if ! "$IYI" build -o "$WORK_NATIVE/free-mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/free-mut-$label.build.log" 2>&1; then
    cat "$WORK/free-mut-$label.build.log" | tee "$WORK/free-dispatch.invalid"
    return 2
  fi
  if [ "$label" = binding ]; then
    calls_run_lower "$WORK/free-mut$EXE" lowcall_dispatch_free_vars "$WORK/free-mut-$label.out" "$WORK/free-mut-$label.err" src/compiler/semantic/main_visitor.iyi "^undefined method 'value' for Int32$" || return $?
  else
    calls_run_lower "$WORK/free-mut$EXE" lowcall_dispatch_free_vars "$WORK/free-mut-$label.out" "$WORK/free-mut-$label.err" || return $?
  fi
  summary_check "$WORK/free-mut-$label.out"
}
if free_dispatch_check; then
  prove_mutation "dispatch arms share a cached definition" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '      dkey = def_instance_key(target_def, union_instance_owner, node)' \
    '      dkey = def_instance_key(arms[0].definition, arms[0].owner, node)' -- free_dispatch_check identity || status=1
  prove_mutation "dispatch arms share the first arm's argument bindings" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '      bound_types = match_bound_types(arm)' \
    '      bound_types = match_bound_types(arms[0])' -- free_dispatch_check binding || status=1
else
  echo "  FAIL: free-variable dispatch baseline differs from the hosted module"
  status=1
fi
if [ -e "$WORK/free-dispatch.invalid" ]; then
  echo "  FAIL: a free-variable dispatch mutation did not compile; behavioral detection is unproven"
  cat "$WORK/free-dispatch.invalid"
  status=1
fi

super_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/super_mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/super_mut.build.log" 2>&1; then
    cat "$WORK/super_mut.build.log" | tee "$WORK/super.invalid"
    return 2
  fi
  calls_run_lower "$WORK/super_mut$EXE" lowcall_super "$WORK/super_mut.out" "$WORK/super_mut.err" "${1:-}" "${2:-}" || return $?
  summary_check "$WORK/super_mut.out" || return $?
  super_refusal_checks "$WORK/super_mut$EXE"
}
if ! super_check; then
  echo "  super baseline failed; mutations cannot prove coverage"
  status=1
else
  prove_mutation "virtual receivers skip subtype groups" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '    if receiver.is_a?(VirtualType)' '    if false' -- lower_calls_check "^no overload matches 'Answer\\+#code' with type $" lowcall_block_cached_writes src/compiler/semantic/main_visitor.iyi || status=1
  prove_mutation "super uses dynamic scope instead of lexical owner" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '    super_ancestors(owner_module, parents)' '    super_ancestors(self_base.as(ModuleType), parents)' -- super_check || status=1
  prove_mutation "super recursion key loses defining owner" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '      key = key + "^#{owner.full_name}"' '      key = "#{rec_type.full_name}##{target_def.name}(#{parts.join(",")})"' -- super_check || status=1
  prove_mutation "super symbol loses recorded owner" "$REPO/src/compiler/lower/fun.iyi" \
    '    found = recorded if start.as(Type).object_id == recorded.object_id || walk_reaches?(start.as(Type), recorded, [] of UInt64)' '    found = start if start.as(Type).object_id == recorded.object_id || walk_reaches?(start.as(Type), recorded, [] of UInt64)' -- super_check || status=1
  prove_mutation "bare super stops forwarding arguments" "$REPO/src/compiler/semantic/normalizer.iyi" \
    '                node.args << Var.new(arg.name)' '                node.args.size' -- super_check src/compiler/semantic/main_visitor.iyi "^wrong number of arguments for 'Child#pick' \\(given 0, expected 1\\)$" || status=1
  prove_mutation "missing super loses its method diagnostic" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '      unless pinned.nil?' '      unless true' -- super_check || status=1
  prove_mutation "super types its body with static self" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '    instantiate_call_target(node, scope, scope, target_def, false)' '    instantiate_call_target(node, @program.def_owner(target_def).as(Type), @program.def_owner(target_def).as(Type), target_def, false)' -- super_check || status=1
  prove_mutation "super permits argument dispatch" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '      if arms.matches.size > 1' '      if false' -- super_check || status=1
  prove_mutation "an expansion call dispatches on self" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '    if node.expansion && node.obj.nil?' '    if false' -- super_check || status=1
  prove_mutation "lowering refuses super as previous_def" "$REPO/src/compiler/lower/call.iyi" \
    '  if node.previous_def?' '  if node.previous_def? || node.super?' -- super_check src/compiler/lower/pending.iyi '^lower: visit\(previous_def \(hosted call\.cr: lookup_previous_def_matches\)\) \(hosted codegen\.cr\) is not ported yet$' || status=1
fi
if [ -e "$WORK/super.invalid" ]; then
  echo "  FAIL: a super mutation did not compile; no behavioral detection was proved"
  cat "$WORK/super.invalid"
  status=1
fi

block_nil_if_read_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/block-nil$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/block-nil.build.log" 2>&1; then
    cat "$WORK/block-nil.build.log" | tee "$WORK/block-nil.invalid"
    return 2
  fi
  calls_run_lower "$WORK/block-nil$EXE" lowcall_block_nil_if_read "$WORK/block-nil.out" "$WORK/block-nil.err" src/compiler/lower/pending.iyi '^lower: visit\(downcast Int32 to \(Int32 \| Nil\) \(hosted cast\.cr downcast_distinct, not ported\)\) \(hosted codegen\.cr\) is not ported yet$' || return $?
  summary_check "$WORK/block-nil.out"
}
if block_nil_if_read_check; then
  prove_mutation "a block read loses its writer's nil storage" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '    @var_owners[name]?' '    nil' -- block_nil_if_read_check || status=1
else
  echo "  FAIL: a block's read-observed nil storage differs from the hosted module"
  status=1
fi
if [ -e "$WORK/block-nil.invalid" ]; then
  echo "  FAIL: the block nil-storage mutation did not compile"
  cat "$WORK/block-nil.invalid"
  status=1
fi


lexical_owner_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/lexical-mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/lexical-mut.build.log" 2>&1; then
    cat "$WORK/lexical-mut.build.log" | tee "$WORK/lexical.invalid"
    return 2
  fi
  calls_run_lower "$WORK/lexical-mut$EXE" lowcall_inherited_lexical_owner "$WORK/lexical-mut.out" "$WORK/lexical-mut.err" src/compiler/semantic/main_visitor.iyi "^undefined method 'code' for Scanner\\.class$" || return $?
  summary_check "$WORK/lexical-mut.out"
}
if lexical_owner_check; then
  prove_mutation "an inherited body resolves names from its receiver instead of its owner" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '        lookup_owner = body_lookup_owner(owner, rec_type)' \
    '        lookup_owner = rec_type' -- lexical_owner_check || status=1
else
  echo "  FAIL: inherited lexical lookup differs from the hosted module"
  status=1
fi

shadowed_const_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/shadow-mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/shadow-mut.build.log" 2>&1; then
    cat "$WORK/shadow-mut.build.log" | tee "$WORK/shadow.invalid"
    return 2
  fi
  "$WORK/shadow-mut$EXE" lower "$REPO_NATIVE/bench/fixtures/lowcall_inherited_shadowed_const.iyi" "$WORK_NATIVE/lowcall_inherited_shadowed_const.oracle.ll" > "$WORK/shadow-mut.out" 2> "$WORK/shadow-mut.err" || { cat "$WORK/shadow-mut.err"; return 2; }
  summary_check "$WORK/shadow-mut.out"
}
if shadowed_const_check; then
  prove_mutation "a constant read ignores the constant the analysis resolved" "$REPO/src/compiler/lower/const.iyi" \
    '  low.analysed.target_const?(node)' '  nil' -- shadowed_const_check || status=1
else
  echo "  FAIL: inherited constant binding differs from the hosted module"
  status=1
fi
for invalid in "$WORK/lexical.invalid" "$WORK/shadow.invalid"; do
  if [ -e "$invalid" ]; then
    echo "  FAIL: a block-jump or lexical-binding mutation did not compile"
    cat "$invalid"
    status=1
  fi
done
# A mutation is caught only when the unmutated port matches the hosted module: a check that fails on the
# unmutated tree would "catch" every patch, so the baseline must pass first.
if ! lower_calls_check; then
  echo "  baseline: the unmutated port does not match the hosted module, so no mutation below is counted"
  exit 1
fi
generic_gap_check() {
  "$IYI" build -o "$WORK_NATIVE/mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/mut.build.log" 2>&1 || { invalid_mutation "$WORK/mut.build.log"; return 2; }
  "$WORK/mut$EXE" lower "$(native_path "$generic_fixture")" "$WORK_NATIVE/uninstantiated.oracle.ll" > "$WORK/generic.mut.out" 2> "$WORK/generic.mut.err"
  local result=$?
  if [ "$result" -eq 0 ]; then
    if [ -f "$WORK/generic.baseline" ] && grep -Eq '^SUMMARY identical=[0-9]+ total=[0-9]+ module=[01]$' "$WORK/generic.mut.out"; then
      echo 'decisive: uninstantiated generic was lowered'
      return 1
    fi
    echo 'INVALID: uninstantiated generic was accepted without a baseline or comparison'
    return 2
  fi
  if expected_refusal "$result" "$WORK/generic.mut.err" src/compiler/lower/pending.iyi '^lower: visit\(the receiver of probe is the uninstantiated generic Range\(B, E\)\.class: typing has not instantiated the owner\) \(hosted codegen\.cr\) is not ported yet$'; then return 0; fi
  if [ -f "$WORK/generic.baseline" ] &&
     expected_refusal "$result" "$WORK/generic.mut.err" src/compiler/lower/pending.iyi '^lower: visit\(a class method call on Range\(B, E\)\.class \(hosted call\.cr: prepare_call_args, a generic or builtin metaclass\)\) \(hosted codegen\.cr\) is not ported yet$' &&
     ! grep -Fq 'typing has not instantiated the owner' "$WORK/generic.mut.err"; then
    echo "decisive: the typing-gap diagnostic was replaced: $(refusal_note "$result" "$WORK/generic.mut.err")"
    return 1
  fi
  echo 'INVALID: uninstantiated generic did not reach its named refusal'
  cat "$WORK/generic.mut.err"
  return 2
}
if ! generic_gap_check; then
  echo "  baseline: uninstantiated generic diagnostic did not match"
  exit 1
fi
: > "$WORK/generic.baseline"
prove_mutation "an uninstantiated generic loses its typing-gap diagnostic" "$REPO/src/compiler/lower/call.iyi" \
  '    if inst.is_a?(GenericClassType)' '    if false' -- generic_gap_check || status=1
# The import of a lib fun (contract 6b): the port's own text declares SecRandomCopyBytes with its framework. The
# comparison above drops the `import` text on both sides (lower_gate.iyi strip_import), so this check is the one
# that proves it. It rebuilds the driver from the current source, so a mutation of the import is what it tests.
link_import_check() {
  "$IYI" build -o "$WORK_NATIVE/mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/mut.build.log" 2>&1 || { invalid_mutation "$WORK/mut.build.log"; return 2; }
  "$WORK/mut$EXE" emit "$REPO_NATIVE/bench/fixtures/lowcall_link_framework.iyi" "$WORK_NATIVE/lowcall_link_framework.oracle.ll" > "$WORK/mut.import.ir" 2>"$WORK/mut.import.err" || { cat "$WORK/mut.import.err"; return 2; }
  awk '/^declare / && /@SecRandomCopyBytes\(/ && / import "Security"/ { ok = 1 } END { exit !ok }' "$WORK/mut.import.ir"
}
echo "  the lib fun is imported from its framework (contract 6b):"
if link_import_check; then
  echo "    yes: SecRandomCopyBytes is declared import \"Security\""
else
  echo "    no: the port's module does not declare SecRandomCopyBytes import \"Security\""
  status=1
fi
prove_mutation "a lib fun is imported from no library" "$REPO/src/compiler/lower/call.iyi" \
  "    made.import_library = import_from" "    made.import_library = nil" -- link_import_check || status=1
prove_mutation "a function's linkage is external" "$REPO/src/compiler/lower/fun.iyi" \
  "fn.linkage = Linkage::Internal" "fn.linkage = Linkage::External" -- lower_calls_check || status=1
prove_mutation "a mangled argument list has no separator" "$REPO/src/compiler/lower/fun.iyi" \
  'text = text + "<" + names.join(", ") + ">"' 'text = text + "<" + names.join(",") + ">"' -- lower_calls_check || status=1
prove_mutation "a call's result is discarded for nil" "$REPO/src/compiler/lower/call.iyi" \
  "    low.last = inst" "    low.last = llvm_nil(low)" -- lower_calls_check '^lower: visit\(binary &\+ with operand IR types %Nil and %Nil inconsistent with Int32 and Int32 \(hosted codegen_binary_op\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_bare_splat_new || status=1
prove_mutation "a lib call omits the unreachable after NoReturn" "$REPO/src/compiler/lower/call.iyi" \
  "    low.builder.unreachable" "    low.last = llvm_nil(low)" -- lower_calls_check || status=1
prove_mutation "the return after a terminated block is not skipped" "$REPO/src/compiler/lower/fun.iyi" \
  "  return if block_ended?(low)" "  low.last = low.last" -- lower_calls_check || status=1
prove_mutation "a def's unwind table is async on aarch64" "$REPO/src/compiler/lower/fun.iyi" \
  'return "sync"' 'return "async"' -- lower_calls_check || status=1
prove_mutation "a def loses its darwin frame pointers" "$REPO/src/compiler/lower/fun.iyi" \
  "  if darwin_triple?(triple)" "  if false" -- lower_calls_check || status=1
prove_mutation "a macOS triple loses its frame pointers" "$REPO/src/compiler/lower/fun.iyi" \
  '  triple.includes?("darwin") || triple.includes?("macosx")' '  triple.includes?("darwin")' -- triple_check || status=1
prove_mutation "the printer writes uwtable as an attribute, not uwtable(sync)" "$REPO/src/compiler/ir/printer.iyi" \
  'return "uwtable(" + s + ")" if a.name == "uwtable"' 'return "uwtable=" + ir_quote(s) if a.name == "uwtable"' -- lower_calls_check || status=1
prove_mutation "a NoReturn def carries no noreturn attribute" "$REPO/src/compiler/lower/fun.iyi" \
  'Attribute.new("noreturn", 0_u64, nil, nil)' 'Attribute.new("nounwind", 0_u64, nil, nil)' -- lower_calls_check || status=1
prove_mutation "a call to a def passes no arguments" "$REPO/src/compiler/lower/call.iyi" \
  'inst = low.builder.call(func.fn_type, func, call_arguments(self_value, values), "")' 'inst = low.builder.call(func.fn_type, func, [] of Value, "")' -- lower_calls_check || status=1
prove_mutation "a NoReturn def call is not followed by unreachable" "$REPO/src/compiler/lower/call.iyi" \
  "  if ret.is_a?(NoReturnType)
    low.builder.unreachable" "  if ret.is_a?(NilType)
    low.builder.unreachable" -- lower_calls_check || status=1
prove_mutation "a block argument is never stored at a yield" "$REPO/src/compiler/lower/block.iyi" \
  "        store_local(low, var.as(LowerVar), exp_types[i], exp_values[i])" "        low.last = low.last" -- lower_calls_check || status=1
prove_mutation "a block call's value is merged as a non-final branch" "$REPO/src/compiler/lower/call.iyi" \
  "  phi.add(low, low.last, true)" "  phi.add(low, low.last, false)" -- lower_calls_check || status=1
prove_mutation "a block call allocates an extra variable" "$REPO/src/compiler/lower/call.iyi" \
  '  allocate_block_vars(low, block, block_ctx.vars, captured)' '  allocate_block_vars(low, block, block_ctx.vars, captured)
  alloca_local(low, block_ctx.vars, "__extra_mutant", low.analysed.program.int32_type)' -- lower_calls_check || status=1
prove_mutation "an inlined def's argument is allocated with the nil type" "$REPO/src/compiler/lower/call.iyi" \
  "      alloca_local(low, vars, arg.name, storage)" "      alloca_local(low, vars, arg.name, low.analysed.program.nil_type)" -- lower_calls_check '^lower: visit\(assign Int32 to Nil \(hosted assign_distinct, not ported\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_block_args || status=1
prove_mutation "a block branch's value is merged as the last branch" "$REPO/src/compiler/lower/block.iyi" \
  "  phi.add_branch(low, value, false)" "  phi.add_branch(low, value, true)" -- lower_calls_check || status=1
prove_mutation "a block branch's value is dropped" "$REPO/src/compiler/lower/block.iyi" \
  "      value = v.as(Value)" "      value = nil" -- lower_calls_check || status=1
prove_mutation "a block break skips its by-value join conversion" "$REPO/src/compiler/lower/block.iyi" \
  '        value = join_pointer(low, branch, got, join_t)' '        value = branch' -- lower_calls_check || status=1
prove_mutation "a break from a block drops its value" "$REPO/src/compiler/lower/lower.iyi" \
  "    branch_to_phi(low, block_phi.as(BranchPhi), node.exp, jump_target(node, low.current_context.break_target))" "    branch_to_phi(low, block_phi.as(BranchPhi), nil, jump_target(node, low.current_context.break_target))" -- lower_calls_check '^lower: visit\(upcast Nil to Int32 \(hosted cast\.cr: upcast_distinct\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_block_break || status=1
prove_mutation "a return from an inlined def drops its value" "$REPO/src/compiler/lower/lower.iyi" \
  "    branch_to_phi(low, rp.as(BranchPhi), node.exp, jump_target(node, low.current_context.return_target))" "    branch_to_phi(low, rp.as(BranchPhi), nil, jump_target(node, low.current_context.return_target))" -- lower_calls_check '^lower: visit\(upcast Nil to Int32 \(hosted cast\.cr: upcast_distinct\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_block_return_def || status=1
prove_mutation "a method's receiver is not passed to the call" "$REPO/src/compiler/lower/call.iyi" \
  "    out << sv.as(Value)" "    out.size" -- lower_calls_check || status=1
prove_mutation "a method's mangled name has no owner" "$REPO/src/compiler/lower/fun.iyi" \
  'text = text + owner_segment(st, name, false, defining) + "#"' 'text = text + "#"' -- lower_calls_check || status=1
prove_mutation "a block call does not bind self in the inlined def" "$REPO/src/compiler/lower/call.iyi" \
  '      frame.vars["self"] = LowerVar.new(sv.as(Value), st, !self_by_pointer?(st))' '      frame.vars.size' -- lower_calls_check || status=1
prove_mutation "a method's self is not the first parameter" "$REPO/src/compiler/lower/fun.iyi" \
  '    first = 1' '    first = 0' -- lower_calls_check || status=1
prove_mutation "a lib call passes no arguments" "$REPO/src/compiler/lower/call.iyi" \
  'inst = low.builder.call(fn_type, func.as(Function), values, "")' 'inst = low.builder.call(fn_type, func.as(Function), [] of Value, "")' -- lower_calls_check || status=1
prove_mutation "a lib fun is declared with the iyi calling convention" "$REPO/src/compiler/lower/call.iyi" \
  'made = low.module.add_function(real, fn_type, CallConv::C)' 'made = low.module.add_function(real, fn_type, CallConv::Iyi)' -- lower_calls_check || status=1
prove_mutation "a lib call's function type returns nil" "$REPO/src/compiler/lower/call.iyi" \
  'fn_type = low.module.types.func(params, low.typer.llvm_return_type(ret), lib_fun.varargs?)' 'fn_type = low.module.types.func(params, low.typer.llvm_return_type(low.analysed.program.nil_type), lib_fun.varargs?)' -- lower_calls_check '^lower: visit\(binary &\+ with operand IR types i32 and void inconsistent with Int32 and Int32 \(hosted codegen_binary_op\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_block_lexical_locals || status=1
prove_mutation "a lib call's result is declared as an integer (a pointer result is caught)" "$REPO/src/compiler/lower/call.iyi" \
  'fn_type = low.module.types.func(params, low.typer.llvm_return_type(ret), lib_fun.varargs?)' 'fn_type = low.module.types.func(params, low.module.types.int32, lib_fun.varargs?)' -- lower_calls_check || status=1

intrinsic_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/intrinsic_mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/intrinsic_mut.build.log" 2>&1; then
    cat "$WORK/intrinsic_mut.build.log" | tee "$WORK/intrinsic.invalid"
    return 2
  fi
  local result=0
  "$WORK/intrinsic_mut$EXE" lower "$REPO_NATIVE/bench/fixtures/lowcall_clib_intrinsics.iyi" "$WORK_NATIVE/lowcall_clib_intrinsics.oracle.ll" > "$WORK/intrinsic_mut.out" 2> "$WORK/intrinsic_mut.err" || result=$?
  if [ "$result" -ne 0 ]; then
    if [ "${1:-}" = ordinary ] && [ -f "$WORK/intrinsic.baseline" ] &&
       expected_refusal "$result" "$WORK/intrinsic_mut.err" src/compiler/lower/pending.iyi '^lower: the lib fun exit binds exit, which is not an intrinsic the IR accepts \(ir/intrinsics\.iyi intrinsic_match; hosted codegen/ast\.cr llvm_intrinsic\?\)$'; then
      echo "decisive: $(refusal_note "$result" "$WORK/intrinsic_mut.err")"
      return 1
    fi
    echo 'INVALID: intrinsic fixture failed outside its expected refusal'
    cat "$WORK/intrinsic_mut.out" "$WORK/intrinsic_mut.err"
    return 2
  fi
  summary_check "$WORK/intrinsic_mut.out" || return $?
  intrinsic_refusal_checks "$WORK/intrinsic_mut$EXE" > /dev/null
}
if ! intrinsic_check; then
  echo "  LLVM intrinsic baseline failed; mutations cannot prove coverage"
  status=1
else
  : > "$WORK/intrinsic.baseline"
  prove_mutation "an LLVM-named lib fun is called as a C function" "$REPO/src/compiler/lower/call.iyi" \
    '  if real.starts_with?("llvm.")' '  if false' -- intrinsic_check || status=1
  prove_mutation "an ordinary C fun is taken for an LLVM intrinsic" "$REPO/src/compiler/lower/call.iyi" \
    '  if real.starts_with?("llvm.")' '  if true' -- intrinsic_check ordinary || status=1
  prove_mutation "an LLVM binding's declared signature is not checked" "$REPO/src/compiler/lower/call.iyi" \
    '  unless params == signature[1] && result == signature[0]' '  unless true' -- intrinsic_check || status=1
  prove_mutation "a variadic LLVM binding is accepted" "$REPO/src/compiler/lower/call.iyi" \
    '  if lib_fun.varargs?' '  if false' -- intrinsic_check || status=1
fi
if [ -e "$WORK/intrinsic.invalid" ]; then
  echo "  FAIL: an LLVM intrinsic mutation did not compile; no behavioral detection was proved"
  cat "$WORK/intrinsic.invalid"
  status=1
fi

prove_mutation "a class method is named with the instance separator (# not ::)" "$REPO/src/compiler/lower/fun.iyi" \
  'text = text + owner_segment(co, name, true, defining) + "::"' 'text = text + owner_segment(co, name, true, defining) + "#"' -- lower_calls_check || status=1
prove_mutation "a stored struct receiver is passed by value instead of address" "$REPO/src/compiler/lower/instance_var.iyi" \
  '  passed_by_value?(s)' '  false' -- lower_calls_check || status=1
prove_mutation "an empty (Nop) body is not inlined" "$REPO/src/compiler/lower/call.iyi" \
  'body.is_a?(Nop) || body.is_a?(NilLiteral)' 'body.is_a?(NilLiteral)' -- lower_calls_check || status=1
prove_mutation "a def is emitted with the C calling convention (a struct result is then refused)" "$REPO/src/compiler/lower/fun.iyi" \
  'return CallConv::Iyi if name.starts_with?("*")' 'return CallConv::C if name.starts_with?("*")' -- lower_calls_check || status=1
prove_mutation "a struct call result is returned as the aggregate, not its spill address (hosted call.cr:707-713)" "$REPO/src/compiler/lower/call.iyi" \
  '        low.last = temp' '        low.last = inst' -- lower_calls_check || status=1
cat > "$WORK/build-filter-probe.iyi" <<'IYI'
import bench/lib/lower_gate::{build_names, normalised_lines}
build = %(@"Crystal::BUILD_COMMIT" = internal global ptr null)
program = %(@"User::VALUE" = internal global ptr null)
text = %(  store ptr @"'compiler'", ptr @"Crystal::BUILD_COMMIT", align 8\n) + build + "\n" + program + "\n"
lines = normalised_lines(text, build_names(text, "::"))
puts "BUILD-GLOBAL=#{lines.includes?(build) ? "present" : "filtered"}"
puts "PROGRAM-GLOBAL=#{lines.includes?(program) ? "kept" : "missing"}"
IYI
build_filter_check() {
  if ! IYI_PATH="$PROBE_IYI_PATH" "$IYI" build -o "$WORK_NATIVE/build-filter-probe$EXE" "$WORK_NATIVE/build-filter-probe.iyi" > "$WORK/build-filter.build.log" 2>&1; then
    echo 'INVALID: build-constant filter probe did not build'
    cat "$WORK/build-filter.build.log"
    return 2
  fi
  if ! "$WORK/build-filter-probe$EXE" > "$WORK/build-filter.out" 2>"$WORK/build-filter.err"; then
    echo 'INVALID: build-constant filter probe failed'
    cat "$WORK/build-filter.out" "$WORK/build-filter.err"
    return 2
  fi
  if ! grep -Fxq 'PROGRAM-GLOBAL=kept' "$WORK/build-filter.out"; then
    echo 'INVALID: ordinary program global was not preserved'
    cat "$WORK/build-filter.out"
    return 2
  fi
  if grep -Fxq 'BUILD-GLOBAL=filtered' "$WORK/build-filter.out"; then return 0; fi
  if [ -f "$WORK/build-filter.baseline" ] && grep -Fxq 'BUILD-GLOBAL=present' "$WORK/build-filter.out"; then
    echo 'decisive: hosted BUILD_COMMIT global was retained by the module filter'
    return 1
  fi
  echo 'INVALID: build-constant filter probe returned an unexpected result'
  cat "$WORK/build-filter.out"
  return 2
}
if build_filter_check; then
  : > "$WORK/build-filter.baseline"
  prove_mutation "a build identity global is kept by the module filter" "$REPO/bench/lib/lower_gate.iyi" \
    'next if stripped.starts_with?("@") && build_constant?(stripped, builds) || stripped.starts_with?("%Nil = type")' 'next if stripped.starts_with?("%Nil = type")' -- build_filter_check || status=1
else
  echo 'FAIL: build-constant filter baseline did not pass'
  status=1
fi
noreturn_phi_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/noreturn_phi$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/noreturn_phi.build.log" 2>&1; then
    invalid_mutation "$WORK/noreturn_phi.build.log"
    return $?
  fi
  if [ "$HOST_OS" = darwin ] && ! codesign -v --strict "$WORK/noreturn_phi$EXE" > "$WORK/noreturn_phi.signature.log" 2>&1; then
    invalid_mutation "$WORK/noreturn_phi.signature.log"
    return $?
  fi
  "$WORK/noreturn_phi$EXE" noreturn-phi > "$WORK/noreturn_phi.out" 2>&1
  driver_assertion_result "$WORK/noreturn_phi.out" "$?" 'NoReturn body left an open block' 64
}
if noreturn_phi_check; then
  prove_mutation "a NoReturn body leaves an open block" "$REPO/src/compiler/lower/call.iyi" \
    '  if ret.is_a?(NoReturnType) || body_t.is_a?(NoReturnType)' '  if ret.is_a?(NoReturnType)' -- noreturn_phi_check || status=1
else
  echo "  FAIL: NoReturn phi baseline did not pass"
  status=1
fi
prove_mutation "a top-level fun with a body is emitted with the iyi calling convention" "$REPO/src/compiler/lower/fun.iyi" \
  "  CallConv::C
end" "  CallConv::Iyi
end" -- lower_calls_check || status=1
prove_mutation "an instantiated generic parameter is resolved in program scope" "$REPO/src/compiler/lower/call.iyi" \
  '    param_type = low.analysed.type_of?(def_node.args[i])' '    param_type = def_node.args[i].restriction ? low.analysed.program.lookup_type_node(def_node.args[i].restriction.as(ASTNode), low.analysed.program) : low.analysed.type_of?(def_node.args[i])' -- lower_calls_check || status=1
prove_mutation "generic allocation skips preparing its metaclass receiver" "$REPO/src/compiler/lower/call.iyi" \
  '      type_id_value(low, inst) if inst.is_a?(GenericClassInstanceMetaclassType)' '      type_id_value(low, inst) if false' -- lower_calls_check || status=1
prove_mutation "a computed metaclass receiver is not evaluated" "$REPO/src/compiler/lower/call.iyi" \
  '      unless node.obj.as(ASTNode).is_a?(Path)' '      if false' -- lower_calls_check || status=1
prove_mutation "an inherited call loses its defining owner" "$REPO/src/compiler/lower/call.iyi" \
  '    if defining = low.analysed.program.def_owner(target)' '    if defining = nil' -- lower_calls_check '^lower: visit\(a call to identity inherited from a superclass of Child \(hosted call\.cr: target_def\.owner is the defining type\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_inherited_owner || status=1
prove_mutation "an inherited dispatch arm loses its defining owner" "$REPO/src/compiler/lower/call.iyi" \
  '        return owner if low.analysed.program.def_owner(target)' '        return owner if false' -- lower_calls_check '^lower: visit\(a call to in\? inherited from a superclass of String \(hosted call\.cr: target_def\.owner is the defining type\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_dispatch_free_vars || status=1
prove_mutation "a recursive named call targets an untyped clone" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '@call_target_defs[call] = frame.definition' '@call_target_defs[call] = target_def' -- lower_calls_check '^lower: visit\(an untyped instantiated parameter 0 of recursive_named_mixed \(hosted call\.cr: prepare_call_args\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_recursive_named_mixed || status=1
prove_mutation "a named argument key drops its name" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '        entries << "#{arg_name.bytesize}:#{arg_name}=#{text.bytesize}:#{text}"' \
  '        entries << "#{text.bytesize}:#{text}"' -- lower_calls_check || status=1
prove_mutation "a yielded block loses its writer's narrowed-out locals" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '@untyped_locals = writer_untyped.dup' '@untyped_locals = Hash(String, String).new' -- lower_calls_check "^undefined local variable or method 'other' for main$" lowcall_narrowed_block_capture src/compiler/semantic/main_visitor.iyi || status=1
prove_mutation "a repeated block loses its narrowed-out entry locals" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '@untyped_locals = entry_untyped_locals.dup' '@untyped_locals = Hash(String, String).new' -- lower_calls_check "^undefined local variable or method 'other' for main$" lowcall_narrowed_block_capture src/compiler/semantic/main_visitor.iyi || status=1
prove_mutation "a nil receiver is not accepted" "$REPO/src/compiler/lower/call.iyi" \
  '  return owner if owner.is_a?(NilType)' '  pending_visit_node("nil receiver") if owner.is_a?(NilType)' -- lower_calls_check '^lower: visit\(nil receiver\) \(hosted codegen\.cr\) is not ported yet$' || status=1
prove_mutation "an aggregate dispatch argument remains a pointer" "$REPO/src/compiler/lower/call.iyi" \
  '      passed = to_rhs(low, passed, params[i]) if passed_by_value?(params[i]) && passed.type.pointer?' '      passed = values[i]' -- lower_calls_check || status=1
nil_phi_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/nil_phi$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/nil_phi.build.log" 2>&1; then
    invalid_mutation "$WORK/nil_phi.build.log"
    return $?
  fi
  if [ "$HOST_OS" = darwin ] && ! codesign -v --strict "$WORK/nil_phi$EXE" > "$WORK/nil_phi.signature.log" 2>&1; then
    invalid_mutation "$WORK/nil_phi.signature.log"
    return $?
  fi
  "$WORK/nil_phi$EXE" nil-phi > "$WORK/nil_phi.out" 2>&1
  driver_assertion_result "$WORK/nil_phi.out" "$?" 'nil phi collected a value' 47
}
if nil_phi_check; then
  prove_mutation "a nil block call collects its body value" "$REPO/src/compiler/lower/phi.iyi" \
    '    if @needs_value && !@node_type.is_a?(NilType) && !@node_type.is_a?(VoidType)' '    if @needs_value' -- nil_phi_check || status=1
else
  echo "  FAIL: nil phi baseline did not pass"
  status=1
fi
prove_mutation "an aggregate dispatch result uses a value phi" "$REPO/src/compiler/lower/call.iyi" \
  '  phi_type = passed_by_value?(ret) ? low.module.types.ptr(0) : low.typer.llvm_type(ret) if phi_wants' '  phi_type = low.typer.llvm_type(ret) if phi_wants' -- lower_calls_check || status=1
prove_mutation "a typed block declaration is refused" "$REPO/src/compiler/lower/call.iyi" \
  '  block.body.accept(collector)' '  block.body.accept(collector)
  if collector.declared
    pending_visit_node("typed block declaration")
  end' -- lower_calls_check '^lower: visit\(typed block declaration\) \(hosted codegen\.cr\) is not ported yet$' || status=1
prove_mutation "primitive dispatch loses its receiver" "$REPO/src/compiler/lower/call.iyi" \
  '      prim_values = [self_value.as(Value)] of Value' '      prim_values = [] of Value' -- lower_calls_check '^lower: visit\(binary primitive with 0 arguments \(hosted codegen_primitive_binary\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_dispatch_primitive || status=1
prove_mutation "enum dispatch receivers are refused" "$REPO/src/compiler/lower/call.iyi" \
  '  if owner.is_a?(MetaclassType) || (owner.is_a?(ModuleType) && !owner.is_a?(ClassType) && !owner.is_a?(EnumType))' \
  '  if owner.is_a?(MetaclassType) || (owner.is_a?(ModuleType) && !owner.is_a?(ClassType))' -- lower_calls_check '^lower: visit\(a dispatched call on unsupported receiver Kind\) \(hosted codegen\.cr\) is not ported yet$' lowcall_dispatch_enum || status=1
prove_mutation "global dispatch arms are repeated for virtual subtypes" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      return base_matches.matches if global_only' '      return base_matches.matches if false' -- lower_calls_check || status=1
prove_mutation "global dispatch arms are treated as runtime receivers" "$REPO/src/compiler/lower/call.iyi" \
  '    checked_dispatch_receiver(low, node, arm.receiver, arm.definition) if receiver_dynamic && !arm.receiver.is_a?(VirtualType) && !global_arm' \
  '    checked_dispatch_receiver(low, node, arm.receiver, arm.definition) if receiver_dynamic && !arm.receiver.is_a?(VirtualType)' -- lower_calls_check '^lower: visit\(a dispatched call on unsupported receiver main\) \(hosted codegen\.cr\) is not ported yet$' lowcall_dispatch_virtual_global || status=1
prove_mutation "dispatch drops the argument type test" "$REPO/src/compiler/lower/call.iyi" \
  '        matches = low.builder.bitwise_and(matches, match_type_id(low, arg_types[i], params[i], arg_tids[i]))' \
  '        matches = int1(low, 1_i64)' -- lower_calls_check || status=1
prove_mutation "dispatch drops the argument downcast" "$REPO/src/compiler/lower/call.iyi" \
  '          passed = downcast(low, passed, params[i], arg_types[i], true)' \
  '          passed = values[i]' -- lower_calls_check || status=1
prove_mutation "dispatch evaluates an argument in every arm" "$REPO/src/compiler/lower/call.iyi" \
  '      passed = values[i]' '      visit_node(low, arguments[i])
      passed = values[i]' -- lower_calls_check || status=1
prove_mutation "named arguments lose written order" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      named.each { |arg| arguments << arg.value }' '      named.reverse_each { |arg| arguments << arg.value }' -- lower_calls_check '^lower: visit\(downcast Int32 to Bool \(hosted cast\.cr downcast_distinct, not ported\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_dispatch_named_arg || status=1
prove_mutation "generic bindings ignore matched argument types" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '          call_arg_type = matched[index] if index < matched.size' '          call_arg_type = matched[index] if false' -- lower_calls_check '^undefined constant T$' lowcall_named_generic_widen refuse_port 5 || status=1
prove_mutation "numeric arguments ignore their matched type" "$REPO/src/compiler/lower/call.iyi" \
  '      converted = lib_number_value(low, arg_node.as(NumberLiteral), target_type)' \
  '      converted = downcast(low, passed, target_type, at, true)' -- lower_calls_check || status=1
prove_mutation "dispatched numeric arguments ignore their matched type" "$REPO/src/compiler/lower/call.iyi" \
  '          passed = lib_number_value(low, arguments[i].as(NumberLiteral), params[i])' \
  '          passed = downcast(low, passed, params[i], arg_types[i], true)' -- lower_calls_check || status=1
prove_mutation "typing mutates the written argument list" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '    CallExpansion.new(target, arguments)' '    node.args = arguments
    CallExpansion.new(target, arguments)' -- lower_calls_check '^not ported: splat or unmatched default arguments$' lowcall_dispatch_named_arg src/compiler/semantic/main_visitor.iyi '' 'MainVisitor#call_expansion' || status=1
prove_mutation "named argument match types are dropped" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      result << arg.type' '      result << arg.type if false' -- lower_calls_check || status=1
prove_mutation "magic arguments precede named arguments" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      arguments << materialized_magic(node, value.as(MagicConstant))' \
  '      arguments.unshift(materialized_magic(node, value.as(MagicConstant)))' -- lower_calls_check || status=1
prove_mutation "lowering ignores recorded argument order" "$REPO/src/compiler/lower/call.iyi" \
  '  low.analysed.call_arguments[node]? || node.args' '  node.args' -- lower_calls_check '^lower: visit\(a call with default arguments or a splat \(hosted call\.cr\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_bare_splat_new || status=1
prove_mutation "recursion keys omit the written overload signature" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '    key = key + "|signature(" + restrictions.join(",") + ")"' '    key = key + ""' -- lower_calls_check '^lower: visit\(downcast B to A \(hosted cast\.cr downcast_distinct, not ported\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_dispatch_nested_overload || status=1
prove_mutation "virtual field reads lose their base scope" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '    target_type = target_type.as(VirtualType).base_type if target_type.is_a?(VirtualType)' \
  '    target_type = target_type.as(VirtualType).base_type if false' -- lower_calls_check "^can't infer the type of instance variable '@value' of Base\\+$" lowcall_dispatch_virtual_self_fields src/compiler/semantic/main_visitor.iyi || status=1
prove_mutation "virtual field writes lose their base scope" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      target_type = target_type.as(VirtualType).base_type if target_type.is_a?(VirtualType)' \
  '      target_type = target_type.as(VirtualType).base_type if false' -- lower_calls_check "^can't use instance variables in Base\\+$" lowcall_dispatch_virtual_self_fields src/compiler/semantic/main_visitor.iyi || status=1
prove_mutation "virtual class primitive loses its metaclass" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '        if sc.is_a?(VirtualType)' '        if false' -- lower_calls_check '^primitive class without a declared return type$' lowcall_dispatch_virtual_class src/compiler/semantic/main_visitor.iyi || status=1
prove_mutation "virtual methods lose priority over global functions" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '    if rec_type.is_a?(VirtualType)
      collect_candidate_defs(rec_type.as(VirtualType).base_type, name, result, visited)' \
  '    if false
      collect_candidate_defs(rec_type.as(VirtualType).base_type, name, result, visited)' -- lower_calls_check || status=1
prove_mutation "subtype groups use the base match" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      groups[i].each { |match| result << match }' \
  '      base_matches.matches.each { |match| result << match }' -- lower_calls_check "^no overload matches 'Answer\\+#code' with type $" lowcall_block_cached_writes src/compiler/semantic/main_visitor.iyi || status=1
prove_mutation "a nil argument is passed as the visit left it, not as the nil value (hosted zeroinitializer)" "$REPO/src/compiler/lower/call.iyi" \
  'passed = at.is_a?(NilType) ? low.builder.const_zero(low.typer.nil_type).as(Value) : value.as(Value)' 'passed = value.as(Value)' -- lower_calls_check || status=1
prove_mutation "an unqualified class-method call loses its class owner" "$REPO/src/compiler/lower/call.iyi" \
  '          class_owner = ct' '          class_owner = nil' -- lower_calls_check '^lower: visit\(a class method native inherited from a superclass of Choice::Kind \(hosted call\.cr: target_def\.owner is the defining type\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_enum_class_methods || status=1
prove_mutation "a generic metaclass call passes no self type id" "$REPO/src/compiler/lower/call.iyi" \
  '      self_value = type_id_value(low, recv_type)' '      self_value = nil' -- lower_calls_check || status=1
prove_mutation "a builtin metaclass receiver is refused" "$REPO/src/compiler/lower/call.iyi" \
  '    unless (inst.is_a?(NonGenericClassType) || inst.is_a?(NonGenericModuleType) || inst.is_a?(EnumType)) && !inst.is_a?(NilType)' '    unless (inst.is_a?(NonGenericClassType) || inst.is_a?(NonGenericModuleType) || inst.is_a?(EnumType)) && !inst.is_a?(NilType) && primitive_kind(inst) == ""' -- lower_calls_check '^lower: visit\(a class method call on Int32\.class \(hosted call\.cr: prepare_call_args, a generic or builtin metaclass\)\) \(hosted codegen\.cr\) is not ported yet$' || status=1
prove_mutation "an implicit builtin class call is refused" "$REPO/src/compiler/lower/call.iyi" \
  '      if (ct.is_a?(NonGenericClassType) || ct.is_a?(NonGenericModuleType) || ct.is_a?(EnumType)) && !ct.is_a?(NilType)' '      if (ct.is_a?(NonGenericClassType) || ct.is_a?(NonGenericModuleType) || ct.is_a?(EnumType)) && !ct.is_a?(NilType) && primitive_kind(ct) == ""' -- lower_calls_check '^lower: visit\(a call to identity with no receiver inside a generic or builtin class method \(hosted call\.cr: prepare_call_args, the metaclass owner\)\) \(hosted codegen\.cr\) is not ported yet$' lowcall_meta_builtin_implicit || status=1
prove_mutation "a computed metaclass receiver is not evaluated" "$REPO/src/compiler/lower/call.iyi" \
  '      unless node.obj.as(ASTNode).is_a?(Path)' '      if false' -- lower_calls_check || status=1
prove_mutation "a captured block precedes self in the call" "$REPO/src/compiler/lower/call.iyi" \
  '      emit_def_call(low, node, func, self_value, values, ret)' '      emit_def_call(low, node, func, nil, call_arguments(self_value, values).reversed, ret)' -- lower_calls_check || status=1
recursion_owner_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/recursion_mut$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/recursion_mut.build.log" 2>&1; then
    echo "INVALID MUTANT: recursion driver failed to build" >&2
    cat "$WORK/recursion_mut.build.log" >&2
    return 2
  fi
  local fixture name result
  for fixture in "$REPO"/bench/fixtures/lowcall_recursion_*.iyi; do
    name="$(basename "$fixture" .iyi)"
    result=0
    "$WORK/recursion_mut$EXE" lower "$(native_path "$fixture")" "$WORK_NATIVE/$name.oracle.ll" > "$WORK/recursion_mut.out" 2> "$WORK/recursion_mut.err" || result=$?
    if [ "$result" -ne 0 ]; then
      if [ -f "$WORK/recursion.baseline" ] && [ "$name" = lowcall_recursion_mutual ] &&
         expected_refusal "$result" "$WORK/recursion_mut.err" src/compiler/lower/pending.iyi '^lower: visit\(an untyped instantiated parameter 0 of a \(hosted call\.cr: prepare_call_args\)\) \(hosted codegen\.cr\) is not ported yet$'; then
        echo "decisive: $name: $(refusal_note "$result" "$WORK/recursion_mut.err")"
        return 1
      fi
      echo "INVALID: recursive fixture $name failed outside the expected refusal"
      cat "$WORK/recursion_mut.out" "$WORK/recursion_mut.err"
      return 2
    fi
    summary_check "$WORK/recursion_mut.out" || return $?
  done
  if ! "$IYI" build -o "$WORK_NATIVE/recursion_target_mut$EXE" "$REPO_NATIVE/bench/selfhost_recursion_target_probe.iyi" > "$WORK/recursion_target_mut.build.log" 2>&1; then
    echo "INVALID MUTANT: recursion target probe failed to build" >&2
    cat "$WORK/recursion_target_mut.build.log" >&2
    return 2
  fi
  if ! "$WORK/recursion_target_mut$EXE" "$REPO_NATIVE/bench/fixtures/lowcall_recursion_top.iyi" "$REPO_NATIVE/src" > "$WORK/recursion_target_mut.out" 2>"$WORK/recursion_target_mut.err"; then
    echo "INVALID MUTANT: recursion target probe failed to run" >&2
    cat "$WORK/recursion_target_mut.err" >&2
    return 2
  fi
  if grep -q '^cycle_a target=.* untyped-params' "$WORK/recursion_target_mut.out"; then return 1; fi
  return 0
}
# The clean comparison must succeed before its failure can count as a catch.
if recursion_owner_check; then
  : > "$WORK/recursion.baseline"
  prove_mutation "a recursive call targets a fresh clone" "$REPO/src/compiler/semantic/main_visitor.iyi" \
    '      instantiated_def = hit.definition
      @call_target_defs[node] = instantiated_def' \
    '      instantiated_def = target_def.clone
      @call_target_defs[node] = instantiated_def' -- recursion_owner_check || status=1
else
  echo 'FAIL: recursion owner baseline did not pass'
  status=1
fi

generic_frame_owner_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/frame_owner$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/frame_owner.build.log" 2>&1; then
    invalid_mutation "$WORK/frame_owner.build.log"
    return $?
  fi
  if [ "$HOST_OS" = darwin ] && ! codesign -v --strict "$WORK/frame_owner$EXE" > "$WORK/frame_owner.signature.log" 2>&1; then
    invalid_mutation "$WORK/frame_owner.signature.log"
    return $?
  fi
  "$WORK/frame_owner$EXE" generic-frame "$REPO_NATIVE/bench/fixtures/lowcall_generic_self_new.iyi" > "$WORK/frame_owner.out" 2>&1
  driver_assertion_result "$WORK/frame_owner.out" "$?" 'generic owner lost its metaclass context' 89
}
if ! generic_frame_owner_check; then
  echo "  baseline: generic owner lost its metaclass context"
  status=1
else
  prove_mutation "a generic class method drops its metaclass context" "$REPO/src/compiler/lower/fun.iyi" \
    '      return owner.as(GenericClassInstanceType).metaclass' \
    '      return owner' -- generic_frame_owner_check || status=1
fi

# A generic class method compiled without a runtime self (the typed probe drops
# it) must still lower a receiverless new. Hosted fun.cr:289 keeps the metaclass
# as context; call.cr:95 passes that type id as self.
generic_frame_check() {
  if ! "$IYI" build -o "$WORK_NATIVE/frame_lower$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/frame_lower.build.log" 2>&1; then
    invalid_mutation "$WORK/frame_lower.build.log"
    return $?
  fi
  if [ "$HOST_OS" = darwin ] && ! codesign -v --strict "$WORK/frame_lower$EXE" > "$WORK/frame_lower.signature.log" 2>&1; then
    invalid_mutation "$WORK/frame_lower.signature.log"
    return $?
  fi
  local result=0
  "$WORK/frame_lower$EXE" generic-frame-lower "$REPO_NATIVE/bench/fixtures/lowcall_generic_self_new.iyi" > "$WORK/frame_lower.out" 2>"$WORK/frame_lower.err" || result=$?
  if [ "$result" -ne 0 ]; then
    if [ -f "$WORK/frame.baseline" ] &&
       expected_refusal "$result" "$WORK/frame_lower.err" src/compiler/lower/pending.iyi '^lower: visit\(a call to new with no receiver inside a generic or builtin class method \(hosted call\.cr: prepare_call_args, the metaclass owner\)\) \(hosted codegen\.cr\) is not ported yet$'; then
      echo "decisive: generic self new: $(refusal_note "$result" "$WORK/frame_lower.err")"
      return 1
    fi
    echo 'INVALID: generic frame failed outside its expected refusal'
    cat "$WORK/frame_lower.out" "$WORK/frame_lower.err"
    return 2
  fi
  if ! "$IYI" build -o "$WORK_NATIVE/frame_native$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/frame_native.build.log" 2>&1; then
    invalid_mutation "$WORK/frame_native.build.log"
    return $?
  fi
  "$WORK/frame_native$EXE" "$REPO_NATIVE/bench/fixtures/lowcall_generic_self_new.iyi" -o "$WORK_NATIVE/frame.probe.exe$EXE" --pipeline typed --probe-phase --keep-going > "$WORK/frame.probe" 2>&1
  result=$?
  if [ "$result" -gt 1 ]; then echo "INVALID: generic frame probe exited $result"; cat "$WORK/frame.probe"; return 2; fi
  if grep -E 'no receiver inside a generic or builtin class method|no receiver inside a class method' "$WORK/frame.probe"; then
    echo 'INVALID: generic frame probe reported an unpinned refusal'
    cat "$WORK/frame.probe"
    return 2
  fi
  if ! awk '/^table: .* defs-lowered-clean=/ { found = 1 } END { exit !found }' "$WORK/frame.probe"; then
    echo 'INVALID: generic frame probe did not produce a lowering table'
    cat "$WORK/frame.probe"
    return 2
  fi
  return 0
}
if ! generic_frame_check; then
  echo "  baseline: generic class-method context did not lower a receiverless new"
  exit 1
fi
: > "$WORK/frame.baseline"
echo "  generic class-method context lowers a receiverless new"
prove_mutation "a receiverless call in a generic class method is treated as builtin" "$REPO/src/compiler/lower/call.iyi" \
  '      elsif class_meta = receiverless_class_metaclass(ct)' \
  '      elsif class_meta = nil' -- generic_frame_check || status=1


if [ -e "$WORK/general-mutation.invalid" ]; then
  echo "  FAIL: a mutation driver could not be built or verified; behavioral detection is unproven"
  cat "$WORK/general-mutation.invalid"
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "lowering of calls and functions: all checks hold"
else
  echo "lowering of calls and functions: FAILED (see above)"
fi
exit "$status"
