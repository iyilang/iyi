#!/usr/bin/env bash
# Proves that the pure iyi self-host compiler tool (iyi-compile) compiles
# the prelude as a whole unit, following all require and import directives,
# measures the compilation phase reached (parse, semantic, codegen, object, link),
# enforces a committed floor against regression, and proves the gate can fail
# under guarded mutation.
#
# The unit is src/iyi/prelude.iyi as the root: `iyi-compile --probe-phase
# prelude.iyi`, which resolves every require. selfhost_prelude_exercise.sh
# probes prelude.iyi with the same invocation as its own prelude.iyi row, and
# the two share the floor below.
#
# The Oracle line is the shipped compiler's verdict on the same root
# (--prelude=empty): link, semantic, or refused, with its first error.
#
#   bash bench/selfhost_prelude_whole_exercise.sh
#
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
TOOL="$REPO/.build/iyi-compile$EXE"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK_NATIVE="$(native_path "$WORK")" || exit 1

. "$REPO/bench/lib/mutation.sh"

if command -v brew >/dev/null 2>&1; then
  LIBRARY_PATH="$(brew --prefix bdw-gc)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export LIBRARY_PATH
fi
export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-$(native_path "${TMPDIR:-/tmp}/iyi-pwl-cache")}"

echo "== 1. Building self-host compile tool"
cd "$REPO" || exit 1
rm -f "$TOOL"
if [ "$HOST_OS" = windows ]; then
  make -f Makefile.win iyi-compile || exit 1
else
  make iyi-compile || exit 1
fi
if [ ! -x "$TOOL" ]; then
  echo "  ERROR: .build/iyi-compile$EXE was not built" >&2
  exit 1
fi
echo "  built .build/iyi-compile$EXE successfully"

echo
echo "== 2. Measuring whole-prelude compilation phase against committed floor"

# Committed floor for compiling the prelude as a single integrated unit:
# parse -> semantic -> codegen -> object -> link. The same value as the
# prelude.iyi row of selfhost_prelude_exercise.sh.
#
# Lowered from codegen to semantic with evidence. The floor was set at 837aa85dc,
# before bcbf7818d (refuse unresolved operands by name), and at that commit an
# unresolved function call emitted nothing (codegen.iyi: `if fn_val = fn` with no
# else). The probe now stops at semantic: object.iyi's `{{ @type.name.stringify }}`
# in Object#to_s needs @type, which the macro engine does not bind.
WHOLE_FLOOR="semantic"

phase_rank() {
  case "$1" in
    none)     echo 0 ;;
    parse)    echo 1 ;;
    semantic) echo 2 ;;
    codegen)  echo 3 ;;
    object)   echo 4 ;;
    link)     echo 5 ;;
    *)        echo -1 ;;
  esac
}

probe_whole_prelude() {
  local rc=0
  local log="$WORK/probe_whole_prelude.log"
  (cd "$WORK" && "$TOOL" --probe-phase -o "$WORK_NATIVE/whole_prelude$EXE" "$REPO_NATIVE/src/iyi/prelude.iyi" > "$log" 2> "$log.err") || rc=$?
  printf '%s\n' "$rc" > "$log.status"
  if [ "$rc" -ne 0 ] && ! port_refusal "$rc" "$log.err"; then
    echo "  INVALID: whole-prelude probe failed unexpectedly (exit $rc)" >&2
    cat "$log" "$log.err" >&2
    return 2
  fi
  if grep -qF "[phase] link: pass" "$log"; then
    echo "link"
  elif grep -qF "[phase] object: pass" "$log"; then
    echo "object"
  elif grep -qF "[phase] codegen: pass" "$log"; then
    echo "codegen"
  elif grep -qF "[phase] semantic: pass" "$log"; then
    echo "semantic"
  elif grep -qF "[phase] parse: pass" "$log"; then
    echo "parse"
  else
    echo "none"
  fi
}

oracle_whole_prelude() {
  local target="$REPO_NATIVE/src/iyi/prelude.iyi" no_codegen=0 full=0
  "$IYI" build --prelude=empty --no-codegen -o "$WORK_NATIVE/oracle_whole_ns$EXE" "$target" > "$WORK/oracle_whole_ns.log" 2>&1 || no_codegen=$?
  "$IYI" build --prelude=empty -o "$WORK_NATIVE/oracle_whole_full$EXE" "$target" > "$WORK/oracle_whole_full.log" 2>&1 || full=$?
  if [ "$no_codegen" -ge 126 ] || [ "$full" -ge 126 ]; then
    echo "  INVALID: hosted compiler crashed or could not be started for the whole prelude" >&2
    cat "$WORK/oracle_whole_ns.log" "$WORK/oracle_whole_full.log" >&2
    return 2
  fi
  if [ "$full" -eq 0 ]; then
    echo "link"
  elif [ "$no_codegen" -eq 0 ]; then
    echo "semantic"
  else
    echo "refused"
  fi
}

printf "  %-22s %-10s %-10s %-9s %s\n" "Unit" "Floor" "Measured" "Oracle" "Status"
printf "  %-22s %-10s %-10s %-9s %s\n" "----------------------" "----------" "----------" "---------" "------"

measured_phase="$(probe_whole_prelude)" || { measured_phase=none; status=1; }
oracle_phase="$(oracle_whole_prelude)" || { oracle_phase=invalid; status=1; }
measured_rank="$(phase_rank "$measured_phase")"
floor_rank="$(phase_rank "$WHOLE_FLOOR")"

matched=0
total=1
regressions=0

if [ "$measured_rank" -ge "$floor_rank" ]; then
  printf "  %-22s %-10s %-10s %-9s %s\n" "prelude (whole)" "$WHOLE_FLOOR" "$measured_phase" "$oracle_phase" "matched"
  matched=$((matched + 1))
else
  printf "  %-22s %-10s %-10s %-9s %s\n" "prelude (whole)" "$WHOLE_FLOOR" "$measured_phase" "$oracle_phase" "REGRESSION"
  regressions=$((regressions + 1))
  status=1
  fail_line="$(grep -m1 -E '(parse|semantic|codegen|object|link): fail:' "$WORK/probe_whole_prelude.log" || true)"
  echo "  Cause, first failure in the probe's log: ${fail_line:-none printed}"
  case "$fail_line" in
    parse:*)    echo "  Owner: lexer or parser (smallest input needed)" ;;
    semantic:*) echo "  Owner: semantic, top_level or main_visitor" ;;
    codegen:*|object:*) echo "  Owner: emitter, codegen.iyi" ;;
    link:*)     echo "  Owner: codegen.iyi, whose raise lowering references the runtime that pipeline no longer supplies" ;;
    *)          echo "  Owner: see the probe log" ;;
  esac
fi

echo "  Phase summary: $matched/$total whole-prelude compilation targets match or exceed committed floor ($regressions regressions)"

echo
echo "== 3. Guarded mutation proofs: verifying the gate goes red when whole prelude regresses"

mutations_caught=0
mutations_run=0

# A lower phase counts only for the exact injected error, never a crash.
check_whole_at_or_above_floor() {
  local floor="$1" target="$2" replacement="$3" measured rc expected
  local log="$WORK/probe_whole_prelude.log"
  measured="$(probe_whole_prelude)" || return 2
  [ "$(phase_rank "$measured")" -lt "$(phase_rank "$floor")" ] || return 0
  rc="$(cat "$log.status")"
  case "$replacement" in
    *UndefinedType9876*)
      if ! expected_refusal "$rc" "$log.err" refuse_port '^undefined constant UndefinedType9876$'; then
        echo "  INVALID: expected injected type refusal in $target" >&2
        cat "$log" "$log.err" >&2
        return 2
      fi
      ;;
    *)
      if [ "$replacement" = 'require %%%' ]; then
        expected="expecting token 'DELIMITER_START', not '%'"
      else
        expected="expecting token 'CONST', not '%'"
      fi
      # The phase probe catches SyntaxException and returns 0.
      if [ "$rc" -ne 0 ] ||
         ! sed 's#/\./#/#g' "$log" | grep -F "parse: fail: Syntax error in $(native_path "$target"):" | grep -Fq "$expected"; then
        echo "  INVALID: expected injected syntax refusal in $target" >&2
        cat "$log" "$log.err" >&2
        return 2
      fi
      ;;
  esac
  echo "decisive: whole prelude reached $measured, below $floor, at the injected error"
  return 1
}

# $1 label, $2 prelude file, $3 literal text to patch, $4 its replacement, $5 committed floor.
run_proof() {
  local target="$REPO/src/iyi/$2" baseline
  mutations_run=$((mutations_run + 1))
  baseline="$(probe_whole_prelude)" || { status=1; return; }
  if [ "$(phase_rank "$baseline")" -lt "$(phase_rank "$5")" ]; then
    echo "  INVALID: whole-prelude baseline reached $baseline, below $5" >&2
    status=1
    return
  fi
  if prove_mutation "$1" "$target" "$3" "$4" -- check_whole_at_or_above_floor "$5" "$target" "$4"; then
    mutations_caught=$((mutations_caught + 1))
  else
    status=1
  fi
}

run_proof "syntax corruption in prelude regresses below semantic floor" "prelude.iyi" 'require "./primitives"' 'require %%%' "semantic"

run_proof "semantic corruption in prelude regresses below semantic floor" "prelude.iyi" '@proc : Proc(Nil)' '@proc : UndefinedType9876' "semantic"

run_proof "syntax corruption in concurrency regresses whole prelude below semantic floor" "concurrency.iyi" 'class IyiFiber' 'class %%%' "semantic"

run_proof "syntax corruption in primitives regresses whole prelude below semantic floor" "primitives.iyi" 'struct Symbol' 'struct %%%' "semantic"
echo "  Mutation summary: $mutations_caught/$mutations_run regressions caught"

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SELFHOST PRELUDE WHOLE CHECKS PASSED!"
else
  echo "SOME SELFHOST PRELUDE WHOLE CHECKS FAILED"
  exit 1
fi
