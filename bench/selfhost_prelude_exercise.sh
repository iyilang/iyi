#!/usr/bin/env bash
# Proves that the pure iyi self-host compiler tool (iyi-compile) compiles
# the real prelude files (src/iyi/*.iyi), measures the compilation phase
# reached by each file (parse, semantic, codegen, object, link), enforces
# a committed floor per file to prevent regressions, and proves the gate can
# fail under guarded mutation.
#
# Each file is probed as the root of its own require closure, as the shipped
# compiler compiles it: `iyi-compile --probe-phase <file>`, with no
# --single-file. prelude.iyi's row is therefore the whole prelude, the same
# probe selfhost_prelude_whole_exercise.sh measures, and shares its floor. A
# file that needs a type another prelude file provides cannot be probed alone;
# its floor is for the alone probe and its reason is printed.
#
# The Oracle column is the shipped compiler's verdict on the same file as root
# (--prelude=empty): link (full build passes), semantic (--no-codegen passes),
# or refused. Below each row that misses its floor, the gate prints the first
# failure in the probe's own log and the component that owns it.
#
#   bash bench/selfhost_prelude_exercise.sh
#
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

. "$REPO/bench/lib/mutation.sh"

if command -v brew >/dev/null 2>&1; then
  LIBRARY_PATH="$(brew --prefix bdw-gc)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export LIBRARY_PATH
fi
export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-${TMPDIR:-/tmp}/iyi-pdr-cache}"

echo "== 1. Building self-host compile tool"
cd "$REPO"
rm -f "$REPO/.build/iyi-compile"
make iyi-compile

if [ ! -x "$REPO/.build/iyi-compile" ]; then
  echo "  ERROR: .build/iyi-compile was not built"
  exit 1
fi
echo "  built .build/iyi-compile successfully"

echo
echo "== 2. Measuring prelude compilation phases against committed floor"

# Committed floor per prelude file, for the alone probe: each file is the root of
# its own require closure. 0 = none, 1 = parse, 2 = semantic, 3 = codegen, 4 = object, 5 = link
#
# A floor is lowered only when the port's old figure came from silently skipping
# an unresolved call. Before commit bcbf7818d (refuse unresolved operands by name),
# an unresolved function call emitted nothing: codegen.iyi's function-call path
# was `if fn_val = fn` with no else, so the call was dropped and @last kept a
# stale value. Every row lowered here failed at the first such call (see the
# reason printed under the row, and the commit message for the evidence).
# Rows at their floor keep it: atomic, chaos_points, concurrency, macros, range, thread.
file_floor() {
  case "$1" in
    "array.iyi")        echo "semantic" ;;
    "atomic.iyi")       echo "link" ;;
    "chaos.iyi")        echo "semantic" ;;
    "chaos_points.iyi") echo "link" ;;
    "concurrency.iyi")  echo "parse" ;;
    "enum.iyi")         echo "semantic" ;;
    "file.iyi")         echo "semantic" ;;
    "float.iyi")        echo "semantic" ;;
    "hash.iyi")         echo "semantic" ;;
    "io.iyi")           echo "semantic" ;;
    "macros.iyi")       echo "link" ;;
    "number.iyi")       echo "semantic" ;;
    "object.iyi")       echo "semantic" ;;
    "prelude.iyi")      echo "semantic" ;;
    "primitives.iyi")   echo "semantic" ;;
    "range.iyi")        echo "link" ;;
    "set.iyi")          echo "semantic" ;;
    "string.iyi")       echo "semantic" ;;
    "testing.iyi")      echo "semantic" ;;
    "thread.iyi")       echo "link" ;;
    *)                  echo "none" ;;
  esac
}

# Why a floor is for the alone probe, printed beside the row.
file_reason() {
  case "$1" in
    "concurrency.iyi") echo "needs Atomic, which atomic.iyi provides and prelude.iyi requires before this file; the shipped compiler refuses it alone too. Its phase in place is measured by selfhost_prelude_whole_exercise.sh" ;;
    "array.iyi")       echo "raise is defined in prelude.iyi, which this alone probe does not load; the port refuses the call by name" ;;
    "file.iyi")        echo "raise is defined in prelude.iyi, which this alone probe does not load; the port refuses the call by name" ;;
    "io.iyi")          echo "raise is defined in prelude.iyi, which this alone probe does not load; the port refuses the call by name" ;;
    "number.iyi")      echo "raise is defined in prelude.iyi, which this alone probe does not load; the port refuses the call by name" ;;
    "chaos.iyi")       echo "String is defined in string.iyi, which this alone probe does not load" ;;
    "set.iyi")         echo "Hash is defined in hash.iyi, which this alone probe does not load" ;;
    "string.iyi")      echo "Array is defined in array.iyi, which this alone probe does not load" ;;
    "testing.iyi")     echo "__iyi_env_forget is defined in prelude.iyi only, which this alone probe does not load" ;;
    "enum.iyi")        echo "value is supplied by the compiler's predefined enum type, which this file does not define" ;;
    "float.iyi")       echo "the tuple from IyiFloatText.product is destructured into a local the port does not type" ;;
    "hash.iyi")        echo "Hash#initialize has a block overload; the method table holds one definition per name, so the no-argument call finds the wrong overload" ;;
    "object.iyi")      echo "{{ @type.name.stringify }} needs @type, which the macro engine does not bind; the port cannot expand it" ;;
    "prelude.iyi")     echo "the whole prelude: the same probe as selfhost_prelude_whole_exercise.sh, with the same floor. It stops at object.iyi's {{ @type.name.stringify }}, which the macro engine does not bind" ;;
    "primitives.iyi")  echo "Class has no superclass in the port, so the receiverless crystal_type_id defined on Object is not found" ;;
    *)                 echo "" ;;
  esac
}

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

probe_one_file() {
  local target="$1"
  local base
  base="$(basename "$target")"
  local log="$WORK/probe_${base}.log"
  set +e
  (cd "$WORK" && "$REPO/.build/iyi-compile" --probe-phase "$target" > "$log" 2>&1)
  set -e
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

# The shipped compiler's verdict on the same file as root.
oracle_phase() {
  local target="$1" base
  base="$(basename "$target" .iyi)"
  set +e
  "$IYI" build --prelude=empty --no-codegen -o "$WORK/oracle_ns_$base" "$target" > "$WORK/oracle_ns_$base.log" 2>&1
  local no_codegen=$?
  "$IYI" build --prelude=empty -o "$WORK/oracle_full_$base" "$target" > "$WORK/oracle_full_$base.log" 2>&1
  local full=$?
  set -e
  if [ "$full" -eq 0 ]; then
    echo "link"
  elif [ "$no_codegen" -eq 0 ]; then
    echo "semantic"
  else
    echo "refused"
  fi
}

# The first failure in a probe's log, and the component that owns that phase.
probe_cause() {
  local log="$1" target="$2" line verdict
  line="$(grep -m1 -E '(parse|semantic|codegen|object|link): fail:' "$log" || true)"
  if [ -z "$line" ]; then
    # Object emission ended without a phase line. The LLVM verifier says why.
    verdict="$("$REPO/.build/iyi-compile" --probe-phase --probe-verify "$target" 2>&1 | grep -m1 '\[verify\] fail' || true)"
    echo "object emission ends without a phase line; ${verdict:-the verifier passes}"
    return
  fi
  case "$line" in
    parse:*)    echo "$line (owner: lexer or parser; smallest input needed)" ;;
    semantic:*) echo "$line (owner: semantic, top_level or main_visitor)" ;;
    codegen:*)  echo "$line (owner: emitter, codegen.iyi)" ;;
    object:*)   echo "$line (owner: emitter, codegen.iyi)" ;;
    link:*)
      if grep -q '___crystal_' "$log"; then
        echo "$line (owner: codegen.iyi, whose raise lowering references the runtime that pipeline no longer supplies; retiring that lowering is A3's)"
      else
        echo "$line (owner: the platform linker step; see the probe log)"
      fi
      ;;
    *)          echo "$line (owner: see the probe log)" ;;
  esac
}

printf "  %-18s %-6s %-10s %-10s %-9s %s\n" "File" "Lines" "Floor" "Measured" "Oracle" "Status"
printf "  %-18s %-6s %-10s %-10s %-9s %s\n" "----------------" "-----" "----------" "----------" "---------" "------"

matched=0
total=0
regressions=0
causes=""

for file_path in "$REPO"/src/iyi/*.iyi; do
  [ -f "$file_path" ] || continue
  total=$((total + 1))
  base="$(basename "$file_path")"
  lines="$(wc -l < "$file_path" | tr -d ' ')"
  floor="$(file_floor "$base")"
  floor_rank="$(phase_rank "$floor")"
  measured="$(probe_one_file "$file_path")"
  measured_rank="$(phase_rank "$measured")"
  oracle="$(oracle_phase "$file_path")"

  if [ "$measured_rank" -lt "$floor_rank" ]; then
    printf "  %-18s %-6s %-10s %-10s %-9s %s\n" "$base" "$lines" "$floor" "$measured" "$oracle" "REGRESSION"
    regressions=$((regressions + 1))
    status=1
    causes="${causes}  $base: $(probe_cause "$WORK/probe_${base}.log" "$file_path")
"
  elif [ "$measured_rank" -gt "$floor_rank" ]; then
    printf "  %-18s %-6s %-10s %-10s %-9s %s\n" "$base" "$lines" "$floor" "$measured" "$oracle" "IMPROVED"
    matched=$((matched + 1))
  else
    printf "  %-18s %-6s %-10s %-10s %-9s %s\n" "$base" "$lines" "$floor" "$measured" "$oracle" "matched"
    matched=$((matched + 1))
  fi
  reason="$(file_reason "$base")"
  if [ -n "$reason" ]; then
    echo "    note $base: $reason"
  fi
done

if [ -n "$causes" ]; then
  echo "  Rows below their floor, with the first failure in the probe's log:"
  printf "%s" "$causes"
fi
echo "  Phase summary: $matched/$total prelude files match or exceed committed floor ($regressions regressions)"

echo
echo "== 3. Guarded mutation proofs: verifying the gate goes red when a file regresses"

mutations_caught=0
mutations_run=0

# Non-zero (caught) when the mutated prelude file measures below its committed floor.
check_at_or_above_floor() {
  local target="$1" floor="$2" measured
  measured="$(probe_one_file "$target")"
  [ "$(phase_rank "$measured")" -ge "$(phase_rank "$floor")" ]
}

# $1 label, $2 prelude file, $3 literal text to patch, $4 its replacement, $5 committed floor.
run_proof() {
  mutations_run=$((mutations_run + 1))
  if prove_mutation "$1" "$REPO/src/iyi/$2" "$3" "$4" -- check_at_or_above_floor "$REPO/src/iyi/$2" "$5"; then
    mutations_caught=$((mutations_caught + 1))
  else
    status=1
  fi
}

run_proof "syntax corruption in set regresses below semantic floor" "set.iyi" 'class Set' 'class %%%' "semantic"

run_proof "semantic corruption in set regresses below semantic floor" "set.iyi" '@entries : Hash(T, Bool)' '@entries : UndefinedType12345' "semantic"

run_proof "syntax corruption in hash regresses below semantic floor" "hash.iyi" 'class Hash' 'class %%%' "semantic"

run_proof "syntax corruption in range regresses below link floor" "range.iyi" 'struct Range' 'struct %%%' "link"

run_proof "syntax corruption in enum regresses below semantic floor" "enum.iyi" 'struct Enum' 'struct %%%' "semantic"

run_proof "syntax corruption in primitives regresses below semantic floor" "primitives.iyi" 'struct Symbol' 'struct %%%' "semantic"

run_proof "syntax corruption in atomic regresses below link floor" "atomic.iyi" 'struct Atomic' 'struct %%%' "link"

run_proof "syntax corruption in prelude regresses below semantic floor" "prelude.iyi" 'require "./primitives"' 'require %%%' "semantic"

run_proof "semantic corruption in prelude regresses below semantic floor" "prelude.iyi" '@proc : Proc(Nil)' '@proc : UndefinedType9876' "semantic"

run_proof "syntax corruption in concurrency regresses below parse floor" "concurrency.iyi" 'class IyiFiber' 'class %%%' "parse"

run_proof "syntax corruption in float regresses below semantic floor" "float.iyi" 'struct Float64' 'struct %%%' "semantic"

run_proof "syntax corruption in array regresses below semantic floor" "array.iyi" 'class Array' 'class %%%' "semantic"

run_proof "syntax corruption in file regresses below semantic floor" "file.iyi" 'class File' 'class %%%' "semantic"

run_proof "syntax corruption in string regresses below semantic floor" "string.iyi" 'class String' 'class %%%' "semantic"

run_proof "syntax corruption in number regresses below semantic floor" "number.iyi" 'struct Int32' 'struct %%%' "semantic"

run_proof "syntax corruption in object regresses below semantic floor" "object.iyi" 'class Object' 'class %%%' "semantic"

run_proof "syntax corruption in io regresses below semantic floor" "io.iyi" 'class IyiIO' 'class %%%' "semantic"
echo "  Mutation summary: $mutations_caught/$mutations_run regressions caught"

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SELFHOST PRELUDE CHECKS PASSED!"
else
  echo "SOME SELFHOST PRELUDE CHECKS FAILED"
  exit 1
fi
