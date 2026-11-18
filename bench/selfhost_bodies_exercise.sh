#!/usr/bin/env bash
# Body-typing fixtures (bench/fixtures/sem_bodies_*.iyi), S1d: each fixture is analysed
# by the hosted compiler's oracle (bench/selfhost_typed_oracle.cr, built here) and by the
# port's typed dump (src/compiler/tools/typed_dump.iyi, built here). A fixture's matched
# count is the number of oracle lines the port prints identically. Its floor
# (bench/selfhost_bodies.floor) may only rise.
#
#   bash bench/selfhost_bodies_exercise.sh
#
# Environment:
#   BODIES_RAISE=1   write each floor up to the measured count (never lower)
#
# Exit status 0 when every fixture reaches its floor, 1 otherwise.
set -u
set -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")" || exit 1
cd "$REPO" || exit 1
# The hosted compiler that builds the port's tools: this checkout's, or the one IYI_COMPILER names.
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
export IYI_PATH="$REPO_NATIVE/src"
CRYSTAL="${CRYSTAL:-crystal}"
FLOOR_FILE="$REPO/bench/selfhost_bodies.floor"
RAISE="${BODIES_RAISE:-0}"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")" || exit 1
LC_ALL=C
export LC_ALL
export IYI_CACHE_DIR="$WORK_NATIVE/cache"
trap 'rm -rf "$WORK"' EXIT INT TERM
ORACLE="$WORK/oracle$EXE"
TYPED="$WORK/typed_dump$EXE"
RESULTS="$WORK/results.tsv"
status=0
: > "$RESULTS"

echo "== 1. Building the hosted compiler's oracle and the port's typed dump"
CRYSTAL_PATH="$REPO_NATIVE/src" IYI_CONFIG_PATH="$REPO_NATIVE/src" "$CRYSTAL" build -Di_know_what_im_doing \
  -o "$(native_path "$ORACLE")" "$REPO_NATIVE/bench/selfhost_typed_oracle.cr" > "$WORK/oracle_build.log" 2>&1 \
  || { cat "$WORK/oracle_build.log"; echo "FAILED to build the oracle"; exit 1; }
"$IYI" build -o "$(native_path "$TYPED")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/typed_build.log" 2>&1 \
  || { cat "$WORK/typed_build.log"; echo "FAILED to build src/compiler/tools/typed_dump.iyi"; exit 1; }
echo "  built"

echo
echo "== 2. Each body fixture: the port's typed nodes against the oracle's"
for fixture in "$REPO"/bench/fixtures/sem_bodies_*.iyi; do
  rel="bench/fixtures/$(basename "$fixture")"
  # pointer_set defines Pointer#value= in the file. The prelude already has that
  # method, so this fixture is analysed alone.
  if [ "$(basename "$fixture")" = "sem_bodies_ensure.iyi" ]; then
    cp "$fixture" "$WORK/ensure.cr"
    "$ORACLE" --bare "$WORK_NATIVE/ensure.cr" > "$WORK/o.txt" 2> "$WORK/o.err"
  elif [ "$(basename "$fixture")" = "sem_bodies_pointer_set.iyi" ]; then
    "$ORACLE" --bare "$(native_path "$fixture")" > "$WORK/o.txt" 2> "$WORK/o.err"
  else
    "$ORACLE" "$(native_path "$fixture")" > "$WORK/o.txt" 2> "$WORK/o.err"
  fi
  if [ $? -ne 0 ]; then
    printf '%s\t%s\t%s\n' "$rel" 0 "ORACLE: $(head -n 1 "$WORK/o.err")" >> "$RESULTS"
    continue
  fi
  sort "$WORK/o.txt" > "$WORK/o.sorted"
  nodes=$(wc -l < "$WORK/o.sorted" | tr -d ' ')
  port_args=()
  if [ "$(basename "$fixture")" = "sem_bodies_defer.iyi" ]; then
    port_args=(--iyi-defer)
  fi
  if "$TYPED" "${port_args[@]}" "$(native_path "$fixture")" "$REPO_NATIVE/src" > "$WORK/p.txt" 2> "$WORK/p.err"; then
    sort "$WORK/p.txt" > "$WORK/p.sorted"
    matched=$(comm -12 "$WORK/o.sorted" "$WORK/p.sorted" | wc -l | tr -d ' ')
  else
    matched=0
  fi
  printf '%s\t%s\t%s\n' "$rel" "$matched" "of $nodes oracle nodes" >> "$RESULTS"
done
awk -F'\t' '{ printf "  %-42s matched %4s  %s\n", $1, $2, $3 }' "$RESULTS"

echo
echo "== 3. Checking each fixture against its floor"
: > "$WORK/floor.new"
while IFS=$'\t' read -r rel matched note; do
  floor=$(awk -v r="$rel" '$1 == r { print $2 }' "$FLOOR_FILE" 2>/dev/null)
  floor=${floor:-0}
  if [ "$matched" -lt "$floor" ]; then
    echo "  BELOW FLOOR: $rel matched $matched, floor $floor. A regression: restore the typing or lower nothing."
    status=1
    keep=$floor
  elif [ "$matched" -gt "$floor" ]; then
    if [ "$RAISE" = 1 ]; then
      echo "  raised: $rel $floor to $matched"
      keep=$matched
    else
      echo "  RAISE THE FLOOR: $rel matched $matched, floor $floor (BODIES_RAISE=1)."
      status=1
      keep=$floor
    fi
  else
    keep=$floor
  fi
  case "$note" in ORACLE*)
    echo "  ORACLE: $rel: $note"
    status=1
    ;;
  esac
  printf '%s %s\n' "$rel" "$keep" >> "$WORK/floor.new"
done < "$RESULTS"

if [ "$RAISE" = 1 ]; then
  {
    echo "# body-typing fixture floors: <repo-relative fixture> <matched oracle nodes>."
    echo "# A count may only rise. Raise with: BODIES_RAISE=1 bash bench/selfhost_bodies_exercise.sh"
    sort "$WORK/floor.new"
  } > "$FLOOR_FILE"
fi

echo
echo "== 2b. The def-instance cache: one def at five call sites is three typed instances"
cache_fx="$REPO/bench/fixtures/sem_bodies_instance_cache.iyi"
cache_count=$("$TYPED" --instances "$(native_path "$cache_fx")" "$REPO_NATIVE/src" 2>/dev/null | awk '/^typed instances:/ { print $3 }')
echo "  sem_bodies_instance_cache.iyi typed instances: ${cache_count:-none} (expected 3)"
if [ "${cache_count:-}" != 3 ]; then
  echo "  CACHE: expected 3 typed instances, got ${cache_count:-none}"
  status=1
fi
refused_cache_count=$("$TYPED" --instances "$REPO_NATIVE/bench/fixtures/bodies_refused_cache.iyi" "$REPO_NATIVE/src" 2>/dev/null | awk '/^typed instances:/ { print $3 }')
echo "  bodies_refused_cache.iyi typed instances: ${refused_cache_count:-none} (expected 1)"
if [ "${refused_cache_count:-}" != 1 ]; then
  echo "  CACHE: refused declared-return body was instantiated more than once"
  status=1
fi
named_cache_count=$("$TYPED" --instances "$REPO_NATIVE/bench/fixtures/sem_bodies_named_instance_cache.iyi" "$REPO_NATIVE/src" 2>/dev/null | awk '/^typed instances:/ { print $3 }')
echo "  named instance cache: ${named_cache_count:-none} (expected 8)"
if [ "${named_cache_count:-}" != 8 ]; then status=1; fi
fanout_count=$("$TYPED" --instances "$REPO_NATIVE/bench/fixtures/sem_bodies_named_recursion_fanout.iyi" "$REPO_NATIVE/src" 2>/dev/null | awk '/^typed instances:/ { print $3 }')
echo "  named recursion fanout: ${fanout_count:-none} (expected 5)"
if [ "${fanout_count:-}" != 5 ]; then status=1; fi
forward_recursion_count=$("$TYPED" --instances "$REPO_NATIVE/bench/fixtures/sem_bodies_forward_recursion.iyi" "$REPO_NATIVE/src" 2>/dev/null | awk '/^typed instances:/ { print $3 }')
echo "  forwarded recursion: ${forward_recursion_count:-none} (expected 4)"
if [ "${forward_recursion_count:-}" != 4 ]; then status=1; fi
forward_controls_count=$("$TYPED" --instances "$REPO_NATIVE/bench/fixtures/sem_bodies_forward_controls.iyi" "$REPO_NATIVE/src" 2>/dev/null | awk '/^typed instances:/ { print $3 }')
echo "  forwarded block controls: ${forward_controls_count:-none} (expected 7)"
if [ "${forward_controls_count:-}" != 7 ]; then status=1; fi

echo
echo "== 2d. Program defs share instances across callers without shadowing methods"
owner_fixture="$REPO/bench/fixtures/bodies_program_owner.iyi"
owner_probe="$WORK/program_owner_probe$EXE"
owner_expected="$WORK/program_owner.expected"
printf '%s\n' '*owner_probe<Int32>:Int32' '*owner_probe<String>:String' '*OwnerShadow#owner_probe<Int32>:Bool' | sort > "$owner_expected"
"$IYI" build -o "$(native_path "$owner_probe")" "$REPO_NATIVE/bench/selfhost_program_owner_probe.iyi" > "$WORK/owner_build.log" 2>&1 || {
  cat "$WORK/owner_build.log"
  echo "  OWNER: failed to build probe"
  exit 1
}
if ! "$owner_probe" "$(native_path "$owner_fixture")" "$REPO_NATIVE/src" > "$WORK/owner.unsorted" ||
   ! sort "$WORK/owner.unsorted" > "$WORK/owner.actual" ||
   ! diff -u "$owner_expected" "$WORK/owner.actual"; then
  echo "  OWNER: incorrect instance names or cache sharing"
  status=1
fi
if ! "$ORACLE" "$(native_path "$owner_fixture")" > "$WORK/owner.oracle" 2> "$WORK/owner.oracle.err" ||
   ! "$TYPED" "$(native_path "$owner_fixture")" "$REPO_NATIVE/src" > "$WORK/owner.typed" 2> "$WORK/owner.typed.err"; then
  echo "  OWNER: typing comparison could not run"
  status=1
else
  for line in 28 29 30; do
    grep "^${line}:.* Call " "$WORK/owner.oracle" | sort > "$WORK/owner.oracle.calls"
    grep "^${line}:.* Call " "$WORK/owner.typed" | sort > "$WORK/owner.typed.calls"
    if [ ! -s "$WORK/owner.oracle.calls" ] || ! diff -u "$WORK/owner.oracle.calls" "$WORK/owner.typed.calls"; then
      echo "  OWNER: call typing differs at line $line"
      status=1
    fi
  done
fi

echo
echo "== 2d. Abstract requirements supply a return type without a typed body"
abstract_fixture="$REPO/bench/fixtures/bodies_abstract_requirement.iyi"
abstract_probe="$WORK/abstract_requirement_probe$EXE"
abstract_expected="$WORK/abstract_requirement.expected"
printf '%s\n' 'refusals: 0' 'item.greet: String' 'abstract instances: 0' > "$abstract_expected"
"$IYI" build -o "$(native_path "$abstract_probe")" "$REPO_NATIVE/bench/selfhost_abstract_requirement_probe.iyi" > "$WORK/abstract_build.log" 2>&1 || {
  cat "$WORK/abstract_build.log"
  echo "  ABSTRACT: failed to build probe"
  exit 1
}
if ! "$abstract_probe" "$(native_path "$abstract_fixture")" "$REPO_NATIVE/src" > "$WORK/abstract.actual" 2> "$WORK/abstract_run.log" ||
   ! diff -u "$abstract_expected" "$WORK/abstract.actual"; then
  cat "$WORK/abstract_run.log"
  echo "  ABSTRACT: incorrect requirement typing"
  status=1
fi

echo
echo "== 2c. A call in a fun body's macro branch is typed after expansion"
splice_count=$("$TYPED" --instances "$REPO_NATIVE/bench/fixtures/sem_bodies_fun_splice.iyi" "$REPO_NATIVE/src" 2>/dev/null | awk '/^typed instances:/ { print $3 }')
echo "  sem_bodies_fun_splice.iyi typed instances: ${splice_count:-none} (expected 1)"
if [ "${splice_count:-}" != 1 ]; then
  echo "  FUN SPLICE: expected 1 typed instance, got ${splice_count:-none}"
  status=1
fi
proc_scope_count=$("$TYPED" --instances "$REPO_NATIVE/bench/fixtures/sem_bodies_proc_scope.iyi" "$REPO_NATIVE/src" 2>/dev/null | awk '/^typed instances:/ { print $3 }')
echo "  sem_bodies_proc_scope.iyi typed instances: ${proc_scope_count:-none} (expected 7)"
if [ "${proc_scope_count:-}" != 7 ]; then
  echo "  PROC SCOPE: expected both helper calls to be typed"
  status=1
fi
if ! "$IYI" build -o "$WORK_NATIVE/proc_scope_probe$EXE" "$REPO_NATIVE/bench/selfhost_proc_scope_probe.iyi" > "$WORK/proc_scope_probe.build.log" 2>&1 ||
   ! "$WORK/proc_scope_probe$EXE" "$REPO_NATIVE/bench/fixtures/sem_bodies_proc_scope.iyi" "$REPO_NATIVE/src"; then
  echo "  PROC SCOPE: the class and instance helper definitions must both be instantiated"
  status=1
fi

echo
echo "== 2d. A nilable property setter is the type of the value it is given"
setter_fx="$REPO/bench/fixtures/sem_bodies_setter_value.iyi"
"$ORACLE" "$(native_path "$setter_fx")" > "$WORK/setter.hosted" 2> "$WORK/setter.hosted.err" || {
  echo "  ORACLE setter: $(head -n 1 "$WORK/setter.hosted.err")"
  status=1
}
if ! "$TYPED" "$(native_path "$setter_fx")" "$REPO_NATIVE/src" > "$WORK/setter.port" 2> "$WORK/setter.port.err"; then
  echo "  PORT setter failed"
  status=1
elif ! diff -q "$WORK/setter.hosted" "$WORK/setter.port" >/dev/null; then
  echo "  setter value dump differs from hosted"
  diff -u "$WORK/setter.hosted" "$WORK/setter.port" | head -n 40
  status=1
else
  echo "  sem_bodies_setter_value.iyi matches hosted node by node"
fi
 
 echo
 echo "== 2e. A one-arg new with a block is the yielding overload, not initialize"
 array_fx="$REPO/bench/fixtures/sem_bodies_array_new.iyi"
 "$ORACLE" "$(native_path "$array_fx")" > "$WORK/array.hosted" 2> "$WORK/array.hosted.err" || {
   echo "  ORACLE array new: $(head -n 1 "$WORK/array.hosted.err")"
   status=1
 }
 if ! "$TYPED" "$(native_path "$array_fx")" "$REPO_NATIVE/src" > "$WORK/array.port" 2> "$WORK/array.port.err"; then
   echo "  PORT array new failed"
   status=1
 elif ! diff -q "$WORK/array.hosted" "$WORK/array.port" >/dev/null; then
   echo "  array new dump differs from hosted"
   diff -u "$WORK/array.hosted" "$WORK/array.port" | head -n 40
   status=1
 else
   echo "  sem_bodies_array_new.iyi matches hosted node by node"
 fi

echo
echo "== 4. Mutation proofs: a patch to the port's body typing must drop a fixture below its floor"
. "$REPO/bench/lib/mutation.sh"
MUT_TD="$WORK/mut_typed_dump$EXE"
# The mutation runner displays only the tail; fd 9 preserves full build logs.
exec 9>&1
body_build_failed() {
  echo "INVALID MUTANT: hosted compiler build failed" >&9
  cat "$1" >&9
  return 2
}

# Mutation callbacks are only evidence after their clean assertion passes.
body_prove() {
  local prover="$1"
  shift
  local original=("$@")
  if [ "${MUTATION_SKIP:-0}" = 1 ]; then
    "$prover" "${original[@]}"
    return $?
  fi
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
  [ "$#" -gt 1 ] || { echo "INVALID PROOF: missing callback" >&9; return 1; }
  shift
  if ! ( "$@" ) > "$WORK/body_baseline.log" 2>&1; then
    echo "INVALID PROOF: clean baseline failed for ${original[0]}" >&9
    cat "$WORK/body_baseline.log" >&9
    return 1
  fi
  "$prover" "${original[@]}"
}

# Probe assertions are caught only for their own named assertion and source
# site. A signal or another panic is an invalid proof.
body_assertion_probe() {
  local site="$1" message="$2" rc=0
  shift 2
  "$@" > "$WORK/body_assertion.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 1 ] &&
     grep -Eq "^iyi: panic: ($message)$" "$WORK/body_assertion.log" &&
     grep -Eq "$site" "$WORK/body_assertion.log"; then
    return 1
  fi
  echo "INVALID MUTANT: probe failed outside its assertion" >&9
  cat "$WORK/body_assertion.log" >&9
  return 2
}
# Rebuilds the typed dump from the patched source and checks the lib-call and jump fixtures
# still reach their floors. Returns non-zero when a fixture falls below its floor.
bodies_at_floor() {
  if ! "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1; then
    body_build_failed "$WORK/mut_build.log"
    return $?
  fi
  for name in sem_bodies_jumps sem_bodies_libcall sem_bodies_self_return sem_bodies_instance_cache sem_bodies_generic_ivar sem_bodies_import_scope sem_bodies_import_later sem_bodies_block_context sem_bodies_block_output sem_bodies_global_fun sem_bodies_magic_constant sem_bodies_fun_splice sem_bodies_block_nil_value sem_bodies_trait_def sem_bodies_trait_requirement sem_bodies_proc_literal sem_bodies_proc_scope sem_bodies_class_method_constant sem_bodies_flow_truthy sem_bodies_flow_nil sem_bodies_flow_is_a sem_bodies_flow_early_exit sem_bodies_splat_restriction sem_bodies_generic_pointer_restriction sem_bodies_interpolation sem_bodies_union_restriction sem_bodies_pointer_set sem_bodies_nil_return sem_bodies_noreturn_declared sem_bodies_owner_typeof sem_bodies_enum_member sem_bodies_union_generic sem_bodies_virtual_lookup sem_bodies_receiver_order sem_bodies_unit_scope sem_bodies_unit_scope_inferred sem_bodies_proc_splat sem_bodies_pack_splat sem_bodies_imported_restriction sem_bodies_setter_value sem_bodies_return_contract; do
    fixture="$REPO/bench/fixtures/$name.iyi"
    rel="bench/fixtures/$name.iyi"
    if [ "$name" = "sem_bodies_pointer_set" ]; then
      "$ORACLE" --bare "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
    else
      "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
    fi
    "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mp.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
    matched=$(comm -12 "$WORK/mo.txt" "$WORK/mp.txt" | wc -l | tr -d ' ')
    floor=$(awk -v r="$rel" '$1 == r { print $2 }' "$FLOOR_FILE" 2>/dev/null)
    [ "$matched" -ge "${floor:-0}" ] || return 1
  done
  fixture="$REPO/bench/fixtures/sem_bodies_class_var_initializer.iyi"
  rel="bench/fixtures/sem_bodies_class_var_initializer.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mp.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  matched=$(comm -12 "$WORK/mo.txt" "$WORK/mp.txt" | wc -l | tr -d ' ')
  floor=$(awk -v r="$rel" '$1 == r { print $2 }' "$FLOOR_FILE" 2>/dev/null)
  [ "$matched" -ge "${floor:-0}" ] || return 1
  count=$("$MUT_TD" --instances "$REPO_NATIVE/bench/fixtures/sem_bodies_instance_cache.iyi" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | awk '/^typed instances:/ { print $3 }') || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  [ "${count:-}" = 3 ] || return 1
  fsc=$("$MUT_TD" --instances "$REPO_NATIVE/bench/fixtures/sem_bodies_fun_splice.iyi" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | awk '/^typed instances:/ { print $3 }') || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  [ "${fsc:-}" = 1 ] || return 1
  proc_count=$("$MUT_TD" --instances "$REPO_NATIVE/bench/fixtures/sem_bodies_proc_scope.iyi" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | awk '/^typed instances:/ { print $3 }') || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  [ "${proc_count:-}" = 7 ] || return 1
  refused_count=$("$MUT_TD" --instances "$REPO_NATIVE/bench/fixtures/bodies_refused_cache.iyi" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | awk '/^typed instances:/ { print $3 }') || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  [ "${refused_count:-}" = 1 ] || return 1
  return 0
}
# A nilable property setter is typed as the assigned value (hosted type_assign
# binds the Assign to the value, main_visitor.cr 1037-1038). Returns 0 only
# when that fixture's typed dump is identical to the hosted oracle.
setter_typed_as_value() {
  if ! "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/setter_mut_build.log" 2>&1; then
    body_build_failed "$WORK/setter_mut_build.log"
    return $?
  fi
  fx="$REPO/bench/fixtures/sem_bodies_setter_value.iyi"
  "$ORACLE" "$(native_path "$fx")" > "$WORK/setter_mut.hosted" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fx")" "$REPO_NATIVE/src" > "$WORK/setter_mut.port" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  diff -q "$WORK/setter_mut.hosted" "$WORK/setter_mut.port" >/dev/null
}
abstract_probe_at_expected() {
  if ! "$IYI" build -o "$WORK_NATIVE/abstract_mutant$EXE" "$REPO_NATIVE/bench/selfhost_abstract_requirement_probe.iyi" > "$WORK/abstract_mutant_build.log" 2>&1; then
    body_build_failed "$WORK/abstract_mutant_build.log"
    return $?
  fi
  if ! "$WORK/abstract_mutant$EXE" "$(native_path "$abstract_fixture")" "$REPO_NATIVE/src" > "$WORK/abstract_mutant.actual" 2> "$WORK/abstract_mutant_run.log"; then
    echo "INVALID MUTANT: abstract requirement probe failed to run" >&2
    cat "$WORK/abstract_mutant_run.log" >&2
    return 2
  fi
  diff -u "$abstract_expected" "$WORK/abstract_mutant.actual"
}
MAIN_VISITOR="$REPO/src/compiler/semantic/main_visitor.iyi"
block_parameter_shadow_at_expected() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/shadow.build.log" 2>&1 || {
    body_build_failed "$WORK/shadow.build.log"
    return $?
  }
  local fixture="$REPO/bench/fixtures/sem_bodies_block_parameter_shadow.iyi"
  "$ORACLE" "$(native_path "$fixture")" > "$WORK/shadow.oracle" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" > "$WORK/shadow.port" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  grep -qx '10:1 Var Bool' "$WORK/shadow.port" || return 1
  diff -q "$WORK/shadow.oracle" "$WORK/shadow.port" >/dev/null
}
block_parameter_shadow_at_expected || status=1
body_prove prove_mutation "block parameter overwrites the caller's flow type" "$MAIN_VISITOR" \
  '          next if shadowed' '          nil' -- block_parameter_shadow_at_expected || status=1
block_generic_inference_matches() {
  if ! "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/block_generic_mut_build.log" 2>&1; then
    body_build_failed "$WORK/block_generic_mut_build.log"
    return $?
  fi
  local fx="$REPO/bench/fixtures/sem_bodies_block_generic_inference.iyi"
  "$ORACLE" "$(native_path "$fx")" > "$WORK/block_generic.hosted" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fx")" "$REPO_NATIVE/src" > "$WORK/block_generic.port" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  diff -q "$WORK/block_generic.hosted" "$WORK/block_generic.port" >/dev/null
}
body_prove prove_mutation "generic constructor inference uses the block result" "$MAIN_VISITOR" \
  'if FreeBindings.unbound?(output, names, bound.as(Hash(String, Type)))' \
  'if false && FreeBindings.unbound?(output, names, bound.as(Hash(String, Type)))' -- block_generic_inference_matches || status=1
alias_members_at_expected() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/alias_mut_build.log" 2>&1 || {
    body_build_failed "$WORK/alias_mut_build.log"
    return $?
  }
  local fixture="$REPO/bench/fixtures/sem_bodies_alias_members.iyi"
  "$ORACLE" "$(native_path "$fixture")" > "$WORK/alias.oracle" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" > "$WORK/alias.port" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  diff -q "$WORK/alias.oracle" "$WORK/alias.port" >/dev/null
}
alias_members_at_expected || status=1
body_prove prove_mutation "qualified alias members resolve through their target" "$REPO/src/compiler/semantic/top_level.iyi" \
  "        c = remove_alias(c)" "        nil" -- alias_members_at_expected || status=1
body_prove prove_mutation "an alias expression has its target's metaclass" "$MAIN_VISITOR" \
  "    t = @program.remove_alias(t) if t.is_a?(AliasType)" \
  "    nil" -- alias_members_at_expected || status=1
const_owner_at_expected() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/const_owner_mut_build.log" 2>&1 || {
    body_build_failed "$WORK/const_owner_mut_build.log"
    return $?
  }
  local fixture="$REPO/bench/fixtures/sem_bodies_const_owner.iyi"
  "$ORACLE" "$(native_path "$fixture")" > "$WORK/const_owner.oracle" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" > "$WORK/const_owner.port" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  diff -q "$WORK/const_owner.oracle" "$WORK/const_owner.port" >/dev/null
}
const_owner_at_expected || status=1
body_prove prove_mutation "a constant initializer uses its declaring scope" "$MAIN_VISITOR" \
  "        inner.current_type = c.namespace || @program" \
  "        inner.current_type = @current_type" -- const_owner_at_expected || status=1
body_prove prove_mutation "a constant assignment has type Nil" "$MAIN_VISITOR" \
  "      # Hosted main_visitor.cr:1084-1087: the assignment itself is Nil.
      set_type(node, @program.nil_type)" \
  "      # Hosted main_visitor.cr:1084-1087: the assignment itself is Nil.
      set_type(node, val_type)" -- const_owner_at_expected || status=1
# Check one fixture's typed records rather than letting an unrelated prelude
# body make a semantic mutation panic before the fixture is observed.
typed_fixture_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return $?; }
  local fixture="$1" rel floor matched
  rel="bench/fixtures/$(basename "$fixture")"
  "$ORACLE" "$(native_path "$fixture")" >"$WORK/typed_fixture.hosted" 2>"$WORK/typed_fixture.hosted.err" || { cat "$WORK/typed_fixture.hosted.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" >"$WORK/typed_fixture.port" 2>"$WORK/typed_fixture.port.err" || { cat "$WORK/typed_fixture.port.err" >&9; return 2; }
  sort "$WORK/typed_fixture.hosted" >"$WORK/typed_fixture.hosted.sorted"
  sort "$WORK/typed_fixture.port" >"$WORK/typed_fixture.port.sorted"
  matched=$(comm -12 "$WORK/typed_fixture.hosted.sorted" "$WORK/typed_fixture.port.sorted" | wc -l | tr -d ' ')
  floor=$(awk -v r="$rel" '$1 == r { print $2 }' "$FLOOR_FILE")
  if [ -z "$floor" ]; then echo "INVALID PROOF: missing fixture floor for $rel" >&9; return 2; fi
  if [ "$matched" -lt "$floor" ]; then
    echo "decisive: $rel matched $matched records, below $floor"
    return 1
  fi
  return 0
}

strict_typing_at_expected() {
  "$IYI" build -o "$WORK_NATIVE/strict_mutant$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/strict_mut_build.log" 2>&1 || {
    body_build_failed "$WORK/strict_mut_build.log"
    return $?
  }
  if [ "$HOST_OS" = darwin ] && ! codesign -v --strict "$WORK/strict_mutant$EXE"; then
    echo "  INVALID MUTANT: compiler signature failed" >&9
    return 2
  fi
  local rc=0 expected_message="${1:-}" expected_site="${2:-}"
  rm -f "$WORK/strict_native.ll"
  "$WORK/strict_mutant$EXE" "$(native_path "$strict_fixture")" -o "$WORK_NATIVE/strict_native.ll" --pipeline typed --prelude --probe-phase --emit ir > "$WORK/strict_mut.log" 2>"$WORK/strict_mut.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "${_PM_ARMED:-0}" = 1 ] && [ ! -e "$WORK/strict_native.ll" ] &&
       grep -Eq "$expected_site" "$WORK/strict_mut.log" &&
       expected_refusal "$rc" "$WORK/strict_mut.err" src/compiler/semantic/main_visitor.iyi "$expected_message"; then
      echo "decisive: strict typing refused the expected fixture call"
      return 1
    fi
    echo "INVALID MUTANT: strict typing did not complete" >&9
    cat "$WORK/strict_mut.log" "$WORK/strict_mut.err" >&9
    return 2
  fi
  grep -Fq '[phase] bodies: pass' "$WORK/strict_mut.log"
}
strict_fixture="$REPO/bench/fixtures/sem_bodies_virtual_metaclass.iyi"
body_prove prove_mutation "virtual metaclass calls dispatch to concrete metaclasses" "$MAIN_VISITOR" \
  "    if receiver.is_a?(VirtualMetaclassType)" \
  "    if false" -- strict_typing_at_expected "^undefined method 'new' for VirtualCopy\+\.class$" \
  '^bodies: refused at .*sem_bodies_virtual_metaclass\.iyi:3:5 in VirtualCopy\+#dup$' || status=1
strict_fixture="$REPO/bench/fixtures/sem_bodies_dead_return_tail.iyi"
body_prove prove_mutation "an untyped unreachable tail does not erase returns" "$MAIN_VISITOR" \
  "      last_type = @program.no_return_type if dead_here && last_type.nil?" \
  "      nil" -- typed_fixture_at_floor "$strict_fixture" || status=1
strict_fixture="$REPO/bench/fixtures/sem_bodies_digest_reach.iyi"
body_prove prove_mutation "an unnameable virtual Self probe stays caller-typed" "$REPO/src/compiler/semantic/definition_typing.iyi" \
  "    written.is_a?(Self) && TypeQueries.virtual_type(scope).is_a?(VirtualType)" \
  "    false" -- strict_typing_at_expected "^undefined method 'new' for BodiesDigestReachHelper::DigestBase\+\.class$" \
  '^bodies: refused at .*bodies_digest_reach_helper\.iyi:8:12 in BodiesDigestReachHelper::DigestBase\+#dup$' || status=1
# A leaf Self remains nameable, so its incorrect return must still be checked.
leaf_bad="$REPO/bench/fixtures/bodies_digest_leaf_bad.iyi"
if "$IYI" build --no-codegen "$(native_path "$leaf_bad")" > "$WORK/leaf_bad.hosted.log" 2>&1 ||
   ! grep -Fq 'must return LeafItem' "$WORK/leaf_bad.hosted.log"; then
  echo "  FAIL: hosted leaf Self control did not reject"
  status=1
fi
if ! "$IYI" build -o "$WORK_NATIVE/leaf_bad.compiler$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/leaf_bad.build.log" 2>&1 ||
   { [ "$(uname -s)" = Darwin ] && ! codesign -v --strict "$WORK/leaf_bad.compiler$EXE"; }; then
  echo "  FAIL: leaf Self control compiler did not build"
  status=1
elif "$WORK/leaf_bad.compiler$EXE" "$(native_path "$leaf_bad")" -o "$WORK_NATIVE/leaf_bad.native" --pipeline typed --prelude --probe-phase > "$WORK/leaf_bad.port.log" 2>&1 ||
     ! grep -Fq 'expected LeafItem, got String' "$WORK/leaf_bad.port.log"; then
  echo "  FAIL: port leaf Self control did not reject"
  status=1
fi
class_self_return_at_expected() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return $?; }
  fixture="$REPO/bench/fixtures/sem_bodies_class_self_return.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mp.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  diff -q "$WORK/mo.txt" "$WORK/mp.txt" >/dev/null
}
class_self_return_at_expected || status=1
body_prove prove_mutation "class method Self resolves to its instance type" "$MAIN_VISITOR" \
  "return o.as(MetaclassType).instance_type if o.is_a?(MetaclassType)" \
  "return o.as(Type) if o.is_a?(MetaclassType)" -- class_self_return_at_expected || status=1
forward_block_at_expected() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return $?; }
  fixture="$REPO/bench/fixtures/sem_bodies_forward_block.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mp.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  diff -q "$WORK/mo.txt" "$WORK/mp.txt" >/dev/null
}
forward_block_at_expected || status=1
body_prove prove_mutation "forwarded proc is presented as a call block" "$MAIN_VISITOR" \
  "      node.block = forwarded" \
  "      nil" -- forward_block_at_expected || status=1
array_restriction_matches() {
  if ! "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/array_restriction_mut_build.log" 2>&1; then
    body_build_failed "$WORK/array_restriction_mut_build.log"
    return $?
  fi
  local fx="$REPO/bench/fixtures/sem_bodies_array_literal_restriction.iyi"
  "$ORACLE" "$(native_path "$fx")" > "$WORK/array_restriction.hosted" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fx")" "$REPO_NATIVE/src" > "$WORK/array_restriction.port" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  diff -q "$WORK/array_restriction.hosted" "$WORK/array_restriction.port" >/dev/null
}
body_prove prove_mutation "generic argument restrictions accept covariant element types" "$REPO/src/compiler/semantic/match.iyi" \
  'if restricted.nil? && written.is_a?(Generic) && arg_type.is_a?(GenericInstanceType)' \
  'if false && restricted.nil? && written.is_a?(Generic) && arg_type.is_a?(GenericInstanceType)' -- array_restriction_matches || status=1
body_prove prove_mutation "an abstract requirement is typed as an empty implementation" "$MAIN_VISITOR" \
  '    if target_def.abstract' '    if false && target_def.abstract' -- abstract_probe_at_expected || status=1
owner_mutant_at_expected() {
  if ! "$IYI" build -o "$WORK_NATIVE/owner_mutant$EXE" "$REPO_NATIVE/bench/selfhost_program_owner_probe.iyi" > "$WORK/owner_mutant_build.log" 2>&1; then
    body_build_failed "$WORK/owner_mutant_build.log"
    return $?
  fi
  if ! "$WORK/owner_mutant$EXE" "$(native_path "$owner_fixture")" "$REPO_NATIVE/src" > "$WORK/owner_mutant.unsorted" 2> "$WORK/owner_mutant_run.log"; then
    echo "INVALID MUTANT: owner probe failed to run" >&2
    cat "$WORK/owner_mutant_run.log" >&2
    return 2
  fi
  sort "$WORK/owner_mutant.unsorted" > "$WORK/owner_mutant.actual" || return 2
  diff -u "$owner_expected" "$WORK/owner_mutant.actual"
}
echo
echo "== 2e. A recursive call targets the instance still being typed"
recursion_probe="$WORK/recursion_target_probe$EXE"
"$IYI" build -o "$(native_path "$recursion_probe")" "$REPO_NATIVE/bench/selfhost_recursion_target_probe.iyi" > "$WORK/recursion_probe_build.log" 2>&1 || {
  cat "$WORK/recursion_probe_build.log"
  echo "  RECURSION: failed to build the target probe"
  exit 1
}
recursion_targets_ok() {
  "$recursion_probe" "$REPO_NATIVE/bench/fixtures/lowcall_recursion_top.iyi" "$REPO_NATIVE/src" > "$WORK/recursion_top.txt" 2>"$WORK/recursion_top.err" || return 1
  grep -q '^cycle_a target=.* typed-params Bool$' "$WORK/recursion_top.txt" || return 1
  "$recursion_probe" "$REPO_NATIVE/bench/fixtures/sem_bodies_recursion_state.iyi" "$REPO_NATIVE/src" > "$WORK/recursion_state.txt" 2>"$WORK/recursion_state.err" || return 1
  awk '/^lock target=/ { id = $2; sub("target=", "", id); if (!(id in seen)) { seen[id] = 1; kinds++ } n++ } END { exit !(n == 2 && kinds == 1) }' "$WORK/recursion_state.txt" || return 1
  "$recursion_probe" "$REPO_NATIVE/bench/fixtures/lowcall_recursive_named_mixed.iyi" "$REPO_NATIVE/src" > "$WORK/recursion_mixed.txt" 2>"$WORK/recursion_mixed.err" || return 1
  awk '/^recursive_named_mixed target=.* typed-params Bool,Bool$/ { id = $2; if (!(id in seen)) { seen[id] = 1; kinds++ } n++ } END { exit !(n == 1 && kinds == 1) }' "$WORK/recursion_mixed.txt"
}
forward_recursion_targets_ok() {
  "$recursion_probe" "$REPO_NATIVE/bench/fixtures/sem_bodies_forward_recursion.iyi" "$REPO_NATIVE/src" > "$WORK/forward_recursion_targets.txt" 2>"$WORK/forward_recursion_targets.err" || return 1
  awk '/^forward_walk target=.* typed-params (Int32|String),Bool$/ { id = $2; if (!(id in seen)) { seen[id] = 1; kinds++ } n++ } END { exit !(n == 4 && kinds == 2) }' "$WORK/forward_recursion_targets.txt" || return 1
  awk '/^forward_depth target=.* typed-params Bool$/ { id = $2; if (!(id in seen)) { seen[id] = 1; kinds++ } n++ } END { exit !(n == 2 && kinds == 1) }' "$WORK/forward_recursion_targets.txt" || return 1
  "$recursion_probe" "$REPO_NATIVE/bench/fixtures/sem_bodies_forward_controls.iyi" "$REPO_NATIVE/src" > "$WORK/forward_control_targets.txt" 2>"$WORK/forward_control_targets.err" || return 1
  awk '/^control_mixed target=.* typed-params Bool,Bool$/ { id = $2; if (!(id in seen)) { seen[id] = 1; kinds++ } n++ } END { exit !(n == 2 && kinds == 1) }' "$WORK/forward_control_targets.txt"
}
if forward_recursion_targets_ok; then
  echo "  forwarded recursive calls share the matching in-progress instance"
else
  echo "  RECURSION: forwarded calls have incorrect target identity"
  cat "$WORK/forward_recursion_targets.txt" "$WORK/forward_control_targets.txt" 2>/dev/null
  status=1
fi
if recursion_targets_ok; then
  echo "  recursive calls share the in-progress typed instance"
else
  echo "  RECURSION: a cycle call does not target the in-progress instance"
  status=1
fi
recursion_fresh_clone() {
  if ! "$IYI" build -o "$WORK_NATIVE/recursion_mutant$EXE" "$REPO_NATIVE/bench/selfhost_recursion_target_probe.iyi" > "$WORK/recursion_mutant_build.log" 2>&1; then
    body_build_failed "$WORK/recursion_mutant_build.log"
    return $?
  fi
  if ! "$WORK/recursion_mutant$EXE" "$REPO_NATIVE/bench/fixtures/lowcall_recursive_named_mixed.iyi" "$REPO_NATIVE/src" > "$WORK/recursion_mutant.txt" 2>"$WORK/recursion_mutant.err"; then
    echo "INVALID MUTANT: recursion probe failed to run" >&2
    cat "$WORK/recursion_mutant.err" >&2
    return 2
  fi
  awk '/^recursive_named_mixed target=.* typed-params Bool,Bool$/ { id = $2; if (!(id in seen)) { seen[id] = 1; kinds++ } n++ } END { exit !(n == 1 && kinds == 1) }' "$WORK/recursion_mutant.txt"
}
unit_cycle_targets_ok() {
  if ! "$IYI" build -o "$WORK_NATIVE/unit_cycle_probe$EXE" "$REPO_NATIVE/bench/selfhost_recursion_target_probe.iyi" > "$WORK/unit_cycle_build.log" 2>&1; then
    echo "INVALID MUTANT: unit cycle probe failed to build" >&2
    cat "$WORK/unit_cycle_build.log" >&9
    return 2
  fi
  "$WORK/unit_cycle_probe$EXE" "$REPO_NATIVE/bench/fixtures/lowcall_cycle_untyped_clone.iyi" "$REPO_NATIVE/src" unit-keys "$REPO_NATIVE/bench/fixtures" > "$WORK/unit_cycle.log" 2>&1 || { cat "$WORK/unit_cycle.log" >&9; return 2; }
  grep -Fxq 'unit-key-equal=true' "$WORK/unit_cycle.log"
}
unit_cycle_targets_ok || status=1
body_prove prove_mutation "unit helper cycle uses its defining owner" "$MAIN_VISITOR" \
  "      key_owner = owner if owner.iyi_unit" \
  "      key_owner = rec_type if owner.iyi_unit" -- unit_cycle_targets_ok || status=1
body_prove prove_mutation "a recursive call targets a fresh clone" "$MAIN_VISITOR" \
  "@call_target_defs[call] = frame.definition" \
  "@call_target_defs.delete(call)" -- recursion_fresh_clone || status=1
named_keys_at_expected() {
  if ! "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/named_keys_build.log" 2>&1; then
    body_build_failed "$WORK/named_keys_build.log"
    return $?
  fi
  count=$("$MUT_TD" --instances "$REPO_NATIVE/bench/fixtures/sem_bodies_named_instance_cache.iyi" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | awk '/^typed instances:/ { print $3 }') || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  [ "${count:-}" = 8 ] || return 1
  count=$("$MUT_TD" --instances "$REPO_NATIVE/bench/fixtures/sem_bodies_named_recursion_fanout.iyi" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | awk '/^typed instances:/ { print $3 }') || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  [ "${count:-}" = 5 ]
}
forward_keys_at_expected() {
  if ! "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/forward_keys_build.log" 2>&1; then
    body_build_failed "$WORK/forward_keys_build.log"
    return $?
  fi
  for name in sem_bodies_forward_recursion sem_bodies_forward_controls; do
    fixture="$REPO/bench/fixtures/$name.iyi"
    case "$name" in
      sem_bodies_forward_recursion) expected=4 ;;
      sem_bodies_forward_controls) expected=7 ;;
    esac
    if ! "$MUT_TD" --instances "$(native_path "$fixture")" "$REPO_NATIVE/src" > "$WORK/forward_instances.txt" 2>"$WORK/forward_instances.err"; then
      echo "INVALID MUTANT: typed dump failed to run for $name" >&2
      cat "$WORK/forward_instances.err" >&2
      return 2
    fi
    count=$(awk '/^typed instances:/ { print $3 }' "$WORK/forward_instances.txt")
    [ "${count:-}" = "$expected" ] || return 1
    "$ORACLE" "$(native_path "$fixture")" > "$WORK/forward_hosted.txt" 2>"$WORK/forward_hosted.err" || { cat "$WORK/forward_hosted.err" >&9; return 2; }
    if ! "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" > "$WORK/forward_port.txt" 2>"$WORK/forward_port.err"; then
      echo "INVALID MUTANT: typed dump failed to run for $name" >&2
      cat "$WORK/forward_port.err" >&2
      return 2
    fi
    sort "$WORK/forward_hosted.txt" > "$WORK/forward_hosted.sorted"
    sort "$WORK/forward_port.txt" > "$WORK/forward_port.sorted"
    diff -u "$WORK/forward_hosted.sorted" "$WORK/forward_port.sorted" || return 1
  done
}
forward_keys_at_expected || status=1
body_prove prove_mutation "forwarded block uses fresh node identity" "$MAIN_VISITOR" \
  '    if callee.uses_block_arg?' '    if false && callee.uses_block_arg?' -- forward_keys_at_expected || status=1
body_prove prove_mutation "forwarded stack key uses node identity" "$MAIN_VISITOR" \
  '      key = key + block_key(target_def, blk, call_node)' '      key = key + "&#{blk.node_id}"' -- forward_keys_at_expected || status=1
body_prove prove_mutation "forwarded cache key uses node identity" "$MAIN_VISITOR" \
  '      key = key + block_key(origin, blk, call_node)' '      key = key + "&#{blk.node_id}"' -- forward_keys_at_expected || status=1
body_prove prove_mutation "yielding callees share forwarded block identity" "$MAIN_VISITOR" \
  '    if callee.uses_block_arg?' '    if true' -- forward_keys_at_expected || status=1
body_prove prove_mutation "written captured blocks share identity" "$MAIN_VISITOR" \
  '    "&#{block.node_id}"' '    callee.uses_block_arg? ? "&written" : "&#{block.node_id}"' -- forward_keys_at_expected || status=1
forward_components_at_expected() {
  if ! "$IYI" build -o "$WORK_NATIVE/forward_components$EXE" "$REPO_NATIVE/bench/fixtures/bodies_forward_block_key_probe.iyi" > "$WORK/forward_components_build.log" 2>&1; then
    body_build_failed "$WORK/forward_components_build.log"
    return $?
  fi
  local rc=0
  body_assertion_probe 'bodies_forward_block_key_probe\.iyi:(45|46|47|48|49|53|55|68|70)' \
    'argument type was omitted from a key|return type was omitted from a key|virtual argument type was erased|virtual return type was erased|same forwarded proc type did not share both keys|written blocks were merged|yielding blocks were merged|same-entry proc-only cache missed|proc-only cache accepted changed entry flow' \
    "$WORK/forward_components$EXE" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  grep -Fxq 'forwarded block key components and identity controls: passed' "$WORK/body_assertion.log" || return 2
}
forward_components_at_expected || status=1
body_prove prove_mutation "a cached block omits its proc-only captures" "$MAIN_VISITOR" \
  '      node.as(ProcLiteral).def.body.accept(self)' '      nil' -- forward_components_at_expected || status=1
body_prove prove_mutation "forwarded proc argument type is omitted" "$MAIN_VISITOR" \
  '                    parts << "#{text.bytesize}:#{text}"' '                    nil' -- forward_components_at_expected || status=1
body_prove prove_mutation "forwarded proc return type is omitted" "$MAIN_VISITOR" \
  '                  text = proc_type.as(ProcInstanceType).return_type.full_name
                  parts << "#{text.bytesize}:#{text}"' \
  '                  text = proc_type.as(ProcInstanceType).return_type.full_name
                  nil' -- forward_components_at_expected || status=1
body_prove prove_mutation "forwarded proc argument type is devirtualized" "$MAIN_VISITOR" \
  '                    text = arg_type.full_name' '                    text = arg_type.devirtualize.full_name' -- forward_components_at_expected || status=1
body_prove prove_mutation "forwarded proc return type is devirtualized" "$MAIN_VISITOR" \
  '                  text = proc_type.as(ProcInstanceType).return_type.full_name' '                  text = proc_type.as(ProcInstanceType).return_type.devirtualize.full_name' -- forward_components_at_expected || status=1
body_prove prove_mutation "a call with named arguments is not cached" "$MAIN_VISITOR" \
  '      key = key + "|named(" + entries.join(",") + ")"' \
  '      return nil' -- named_keys_at_expected || status=1
body_prove prove_mutation "a named argument key drops its name" "$MAIN_VISITOR" \
  '        entries << "#{arg_name.bytesize}:#{arg_name}=#{text.bytesize}:#{text}"' \
  '        entries << "#{text.bytesize}:#{text}"' -- named_keys_at_expected || status=1
body_prove prove_mutation "program defs use their declared owner" "$MAIN_VISITOR" \
  "        instance_owner = declared_owner if declared_owner.is_a?(SemanticProgram)" \
  "        instance_owner = rec_type if declared_owner.is_a?(SemanticProgram)" -- owner_mutant_at_expected || status=1
body_prove prove_mutation "class variable initializer uses its owner's metaclass" "$MAIN_VISITOR" \
  "      @scope = @current_type.metaclass" \
  "      @scope = @current_type" -- bodies_at_floor || status=1
body_prove prove_mutation "class variable literal is guessed before body typing" "$REPO/src/compiler/semantic/instance_vars.iyi" \
  "      assign_class_var(target.as(ClassVar), node.value)" \
  "      nil" -- bodies_at_floor || status=1
body_prove prove_mutation "lib call result type" "$MAIN_VISITOR" \
  "set_type(node, target.result_type.as(Type))" \
  "set_type(node, @program.nil_type)" -- bodies_at_floor || status=1
body_prove prove_mutation "next value joins the block type" "$MAIN_VISITOR" \
  "blk_type = merge_jump_values(child_type(blk.body), @next_types)" \
  "blk_type = child_type(blk.body)" -- bodies_at_floor || status=1
body_prove prove_mutation "return value joins the def type" "$MAIN_VISITOR" \
  "body_type = merge_jump_values(child_type(body.as(ASTNode)), @return_types)" \
  "body_type = child_type(body.as(ASTNode))" -- bodies_at_floor || status=1
body_prove prove_mutation "self in a declared type names the receiver" "$MAIN_VISITOR" \
  "return o.as(Type) unless o.is_a?(SemanticProgram)" \
  "return @program unless o.is_a?(SemanticProgram)" -- bodies_at_floor || status=1
body_prove prove_mutation "a call hits the def-instance cache" "$MAIN_VISITOR" \
  "        return instance" \
  "        return nil" -- bodies_at_floor || status=1
body_prove prove_mutation "a generic instance copies its declared instance variable with the argument" "$REPO/src/compiler/types/types.iyi" \
  "TypeQueries.replace_type_parameters(source_type, @type_vars)" \
  "source_type" -- bodies_at_floor || status=1
body_prove prove_mutation "an imported name is not in scope in its def's body" "$MAIN_VISITOR" \
  "enter_file_scope(target_def)" \
  "nil" -- bodies_at_floor || status=1
body_prove prove_mutation "a block body is typed in the scope of the call that owns it" "$MAIN_VISITOR" \
  "@scope = writer_scope" \
  "@scope = @program" -- bodies_at_floor || status=1
body_prove prove_mutation "a call to a top-level fun with a body is refused" "$MAIN_VISITOR" \
  "return visit_global_fun_call(node, global_fun) if own.empty?" \
  "return false if own.empty?" -- bodies_at_floor || status=1
body_prove prove_mutation "a trait definition is typed in its own type" "$MAIN_VISITOR" \
  "def visit(node : TraitDef) : Bool" \
  "def visit_trait_def_off(node : TraitDef) : Bool" -- bodies_at_floor || status=1
trait_dispatch_at_expected() {
  if ! "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1; then
    body_build_failed "$WORK/mut_build.log"
    return $?
  fi
  "$ORACLE" "$REPO_NATIVE/bench/fixtures/sem_bodies_trait_dispatch.iyi" 2>"$WORK/body_mut_run.err" | sort > "$WORK/trait.oracle" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$REPO_NATIVE/bench/fixtures/sem_bodies_trait_dispatch.iyi" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/trait.port" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  grep -Fxq '32:10 Call String' "$WORK/trait.oracle" &&
    grep -Fxq '32:10 Call String' "$WORK/trait.port"
}
trait_dispatch_at_expected || status=1
body_prove prove_mutation "trait implementers dispatch without argument dispatch" "$MAIN_VISITOR" \
  "          if seen_owners.includes?(owner_name)" \
  "          if true" -- trait_dispatch_at_expected || status=1
body_prove prove_mutation "a proc literal is typed as a Proc" "$MAIN_VISITOR" \
  "def visit(node : ProcLiteral) : Bool" \
  "def visit_proc_literal_off(node : ProcLiteral) : Bool" -- bodies_at_floor || status=1
body_prove prove_mutation "a call body is not typed in the scope of its owner" "$MAIN_VISITOR" \
  "    enter_owner_scope(lookup_owner)" \
  "    nil" -- bodies_at_floor || status=1
body_prove prove_mutation "a block whose declared output is _ is checked against a type" "$MAIN_VISITOR" \
  "unless out_node.is_a?(Underscore)" \
  $'if out_node.is_a?(Underscore)\n                    set_type(node, @program.nil_type)\n                  else' -- typed_fixture_at_floor \
  "$REPO/bench/fixtures/sem_bodies_block_output.iyi" || status=1
body_prove prove_mutation "a call-site __LINE__ expands as a string" "$MAIN_VISITOR" \
  'literal = magic.expand_node(node.location, node.end_location).at(node)' \
  'literal = StringLiteral.new("?").at(node)' -- bodies_at_floor || status=1
body_prove prove_mutation "if x narrows a truthy variable in its then branch" "$MAIN_VISITOR" \
  "    filter_vars(cond_type_filters)
    then_dead = @narrowed_out" \
  "    nil
    then_dead = @narrowed_out" -- bodies_at_floor || status=1
body_prove prove_mutation "if x.nil?, unless x and !x narrow the else branch" "$MAIN_VISITOR" \
  "    filter_vars(TypeFilters.invert(cond_type_filters))
    else_dead = @narrowed_out" \
  "    nil
    else_dead = @narrowed_out" -- bodies_at_floor || status=1
body_prove prove_mutation "while cond narrows its variable in the loop body" "$MAIN_VISITOR" \
  "      filter_vars(cond_type_filters)" \
  "      nil" -- bodies_at_floor || status=1
body_prove prove_mutation "early exit in then branch narrows the rest of the body" "$MAIN_VISITOR" \
  "        elsif then_unreachable
          merged_vars[name] = else_var" \
  "        elsif false
          merged_vars[name] = else_var" -- bodies_at_floor || status=1
body_prove prove_mutation_all "a refused body with declared return is cached" "$MAIN_VISITOR" \
  "remember_def_instance(cache_key, target_def," \
  "nil # " -- bodies_at_floor || status=1
body_prove prove_mutation "a generic pointer restriction is not bound from the receiver" "$REPO/src/compiler/semantic/restrictions.iyi" \
  "            arg = ArgRestriction.lookup_bound(ts, scope, arg_node, owner)" \
  "            arg = ArgRestriction.lookup_bound(ts, scope, arg_node, owner)
            arg = LookupError.new(\"unbound\") if arg.is_a?(Type)" -- bodies_at_floor || status=1
body_prove prove_mutation "a splat call is not resolved by the calls lookup" "$REPO/src/compiler/semantic/match.iyi" \
  "    splat = definition.splat_index" \
  "    splat = definition.splat_index
    return MatchAttempt.none unless splat.nil?" -- bodies_at_floor || status=1
body_prove prove_mutation "a union restriction is not instantiated from its members" "$REPO/src/compiler/semantic/restrictions.iyi" \
  "      return ArgRestriction.lookup_union(ts, scope, node.as(Union), owner)" \
  "      return LookupError.new(\"unbound union\")" -- bodies_at_floor || status=1
body_prove prove_mutation "pointer_set types the assigned value" "$MAIN_VISITOR" \
  "set_type(node, pst)" \
  "set_type(node, @program.nil_type)" -- bodies_at_floor || status=1
body_prove prove_mutation "a Nil return annotation discards the body value" "$MAIN_VISITOR" \
  "    contract.nil_type? || resolved.subtype_of?(contract) || proc_contract?(resolved, contract)" \
  "    resolved.subtype_of?(contract) || proc_contract?(resolved, contract)" -- bodies_at_floor || status=1
body_prove prove_mutation "a non-returning body gives a Nil-declared def NoReturn" "$MAIN_VISITOR" \
  "if bt.is_a?(NoReturnType) && !error_contract?(declared_ret)" \
  "if false" -- bodies_at_floor || status=1
body_prove prove_mutation "an error contract survives a non-returning body" "$MAIN_VISITOR" \
  "if bt.is_a?(NoReturnType) && !error_contract?(declared_ret)" \
  "if bt.is_a?(NoReturnType)" -- bodies_at_floor || status=1

body_prove prove_mutation "metaclass owner binds its instance parameters" "$MAIN_VISITOR" \
  "    if instance = receiver_instance(owner)
      found = ArgRestriction.lookup_bound(type_node_system(@program), @current_type, node, instance)" \
  "    if instance = receiver_instance(owner)
      found = ArgRestriction.lookup_bound(type_node_system(@program), @current_type, node, owner)" -- bodies_at_floor || status=1
body_prove prove_mutation "typeof inside type arguments yields the instance type" "$REPO/src/compiler/semantic/type_nodes.iyi" \
  "  if depth > 0" \
  "  if false" -- bodies_at_floor || status=1
body_prove prove_mutation "enum members have the enum type" "$MAIN_VISITOR" \
  "        set_type(node, enum_type)" \
  "        set_type(node, @program.int32_type)" -- bodies_at_floor || status=1
generic_union_matches_hosted() {
  if ! "$IYI" build -o "$WORK_NATIVE/union_calls$EXE" "$REPO_NATIVE/bench/selfhost_semantic_calls_exercise.iyi" > "$WORK/union_calls_build.log" 2>&1; then
    body_build_failed "$WORK/union_calls_build.log"
    return $?
  fi
  "$WORK/union_calls$EXE" "$REPO_NATIVE/bench/fixtures/semcall_match_union_generic.iyi" > "$WORK/union_calls.port" 2>&1 || { cat "$WORK/union_calls.port" >&9; return 2; }
  diff -q "$WORK/union_calls.hosted" "$WORK/union_calls.port" >/dev/null
}
CRYSTAL_PATH="$REPO_NATIVE/src" "$CRYSTAL" build -Di_know_what_im_doing -o "$WORK_NATIVE/union_calls_oracle$EXE" "$REPO_NATIVE/bench/selfhost_semantic_calls_oracle.cr" > "$WORK/union_calls_oracle_build.log" 2>&1 || { cat "$WORK/union_calls_oracle_build.log"; exit 1; }
"$WORK/union_calls_oracle$EXE" "$REPO_NATIVE/bench/fixtures/semcall_match_union_generic.iyi" > "$WORK/union_calls.hosted" || exit 1
generic_union_matches_hosted || status=1
body_prove prove_mutation "a generic union member retains its arguments" "$REPO/src/compiler/semantic/restrictions.iyi" \
  "      member = ArgRestriction.lookup_bound(ts, scope, node.types[i], owner)" \
  "      member_node = node.types[i]
      member_node = member_node.as(Generic).name if member_node.is_a?(Generic)
      member = ArgRestriction.lookup_bound(ts, scope, member_node, owner)" -- generic_union_matches_hosted || status=1
type_lookup_at_expected() {
  if ! "$IYI" build -o "$WORK_NATIVE/type_lookup_probe$EXE" "$REPO_NATIVE/bench/selfhost_type_lookup_probe.iyi" > "$WORK/type_lookup_probe.build.log" 2>&1; then
    body_build_failed "$WORK/type_lookup_probe.build.log"
    return $?
  fi
  body_assertion_probe 'selfhost_type_lookup_probe\.iyi:(17|20)' \
    'written class must be virtual|static array lookup lost element or size' "$WORK/type_lookup_probe$EXE"
}
type_lookup_at_expected || status=1
body_prove prove_mutation "written class types are virtualized" "$MAIN_VISITOR" \
  "      return TypeQueries.virtual_type(quiet)" \
  "      return quiet" -- type_lookup_at_expected || status=1
body_prove prove_mutation "a call types its receiver before its arguments" "$MAIN_VISITOR" \
  "    rec_type : Type
    if obj = node.obj
      obj.accept(self)
      if ot = child_type(obj)
        rec_type = ot
      else
        # Total analysis still records independent argument nodes when the
        # receiver cannot be typed. The call itself remains unresolved.
        if @total || @speculation.depth > 0
          node.args.each do |arg|
            arg.accept(self)
          end
          if named = node.named_args
            named.each do |arg|
              arg.value.accept(self)
            end
          end
        end
        @needs_type_filters = saved_call_ntf
        @type_filters = nil
        return false
      end
    else
      rec_type = @scope || @current_type
    end
    node.args.each do |arg|
      arg.accept(self)
    end" \
  "    node.args.each do |arg|
      arg.accept(self)
    end
    rec_type : Type
    if obj = node.obj
      obj.accept(self)
      if ot = child_type(obj)
        rec_type = ot
      else
        # Total analysis still records independent argument nodes when the
        # receiver cannot be typed. The call itself remains unresolved.
        if @total || @speculation.depth > 0
          node.args.each do |arg|
            arg.accept(self)
          end
          if named = node.named_args
            named.each do |arg|
              arg.value.accept(self)
            end
          end
        end
        @needs_type_filters = saved_call_ntf
        @type_filters = nil
        return false
      end
    else
      rec_type = @scope || @current_type
    end" -- bodies_at_floor || status=1
body_prove prove_mutation "a proc literal inherits its enclosing scope" "$MAIN_VISITOR" \
  "    inner.scope = @scope" \
  "    inner.scope = @program" -- bodies_at_floor || status=1
body_prove prove_mutation "unit definitions resolve in their lexical scope" "$MAIN_VISITOR" \
  "      if mod.iyi_unit" \
  "      if false" -- bodies_at_floor || status=1
body_prove prove_mutation "splat arguments bind a tuple" "$REPO/src/compiler/semantic/default_arguments.iyi" \
  "body << Assign.new(Var.new(splat.name), TupleLiteral.new(elements))" \
  "body << Assign.new(Var.new(splat.name), TupleLiteral.new([] of ASTNode))" -- bodies_at_floor || status=1
body_prove prove_mutation "Assign typed as its target" "$MAIN_VISITOR" \
  "        set_type(node, val_type)
      elsif target_type.is_a?(GenericClassInstanceType)" \
  "        set_type(node, ivar.type)
      elsif target_type.is_a?(GenericClassInstanceType)" -- setter_typed_as_value || status=1

# Assignment conditions carry the value's filters onto the assigned local.
flow_assign_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return 2; }
  local fixture="$REPO/bench/fixtures/sem_bodies_flow_assign.iyi"
  "$ORACLE" "$(native_path "$fixture")" > "$WORK/flow_o.txt" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" > "$WORK/flow_p.txt" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  sort "$WORK/flow_o.txt" > "$WORK/flow_o.sorted"
  sort "$WORK/flow_p.txt" > "$WORK/flow_p.sorted"
  local matched floor
  matched=$(comm -12 "$WORK/flow_o.sorted" "$WORK/flow_p.sorted" | wc -l | tr -d ' ')
  floor=$(awk '$1 == "bench/fixtures/sem_bodies_flow_assign.iyi" { print $2 }' "$FLOOR_FILE")
  [ "$matched" -ge "${floor:-0}" ]
}
body_prove prove_mutation "assignment condition narrows its target" "$MAIN_VISITOR" \
  "@type_filters = TypeFilters.assign_var(value_type_filters, v.name)" \
  "@type_filters = value_type_filters" -- flow_assign_at_floor || status=1

# A written ensure is refused with the iyi prelude; the handler mechanism is
# compared against the hosted compiler without that prelude.
ensure_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return 2; }
  local fixture="$REPO/bench/fixtures/sem_bodies_ensure.iyi"
  cp "$fixture" "$WORK/ensure.cr"
  "$ORACLE" --bare "$WORK_NATIVE/ensure.cr" > "$WORK/ensure_o.txt" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" > "$WORK/ensure_p.txt" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  sort "$WORK/ensure_o.txt" > "$WORK/ensure_o.sorted"
  sort "$WORK/ensure_p.txt" > "$WORK/ensure_p.sorted"
  local matched floor
  matched=$(comm -12 "$WORK/ensure_o.sorted" "$WORK/ensure_p.sorted" | wc -l | tr -d ' ')
  floor=$(awk '$1 == "bench/fixtures/sem_bodies_ensure.iyi" { print $2 }' "$FLOOR_FILE")
  [ "$matched" -ge "${floor:-0}" ]
}
body_prove prove_mutation "ensure assignments reach following code" "$MAIN_VISITOR" \
  "          @vars[name] = type" \
  "          nil" -- ensure_at_floor || status=1

# The oracle and port both normalize this fixture with the iyi prelude mode.
defer_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return 2; }
  local fixture="$REPO/bench/fixtures/sem_bodies_defer.iyi"
  "$ORACLE" "$(native_path "$fixture")" > "$WORK/defer_o.txt" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" --iyi-defer "$(native_path "$fixture")" "$REPO_NATIVE/src" > "$WORK/defer_p.txt" 2>"$WORK/body_mut_run.err" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  sort "$WORK/defer_o.txt" > "$WORK/defer_o.sorted"
  sort "$WORK/defer_p.txt" > "$WORK/defer_p.sorted"
  local matched floor
  matched=$(comm -12 "$WORK/defer_o.sorted" "$WORK/defer_p.sorted" | wc -l | tr -d ' ')
  floor=$(awk '$1 == "bench/fixtures/sem_bodies_defer.iyi" { print $2 }' "$FLOOR_FILE")
  [ "$matched" -ge "${floor:-0}" ]
}
body_prove prove_mutation "defer cleanup is typed" "$MAIN_VISITOR" \
  "      cleanup.accept(self)" \
  "      nil" -- defer_at_floor || status=1

ensure_refusal_check() {
  "$IYI" build -o "$WORK_NATIVE/ensure_refusal$EXE" "$REPO_NATIVE/bench/selfhost_ensure_refusal.iyi" > "$WORK/ensure_refusal_build.log" 2>&1 || { body_build_failed "$WORK/ensure_refusal_build.log"; return 2; }
  body_assertion_probe 'selfhost_ensure_refusal\.iyi:21' 'missing refusal: iyi has no `ensure`' "$WORK/ensure_refusal$EXE"
}
echo "== 4c. Written ensure refusal and nested-loop exits"
ensure_refusal_check || status=1
body_prove prove_mutation "written ensure is refused under the prelude" "$MAIN_VISITOR" \
  "if @program.iyi_prelude? && !node.iyi_defer?" \
  "if false" -- ensure_refusal_check || status=1

# The return targets its instantiated def (hosted main_visitor.cr 2096).
ensure_targets_check() {
  "$IYI" build -o "$WORK_NATIVE/ensure_targets$EXE" "$REPO_NATIVE/bench/selfhost_ensure_targets.iyi" > "$WORK/ensure_targets_build.log" 2>&1 || { body_build_failed "$WORK/ensure_targets_build.log"; return 2; }
  body_assertion_probe 'selfhost_ensure_targets\.iyi:(17|99|114|130|131)' \
    'return targets a different def|return targets: .*|jump targets: .*|captured block target: .*|captured next targets another def' "$WORK/ensure_targets$EXE"
}
echo "== 4d. Return target identity"
ensure_targets_check || status=1
body_prove prove_mutation "return identifies its typed def" "$MAIN_VISITOR" \
  "    node.target = @current_def" \
  "    node.target = nil" -- ensure_targets_check || status=1
body_prove prove_mutation "break identifies its block call" "$MAIN_VISITOR" \
  "      node.target = @jump_block_calls[block]?" \
  "      node.target = nil" -- ensure_targets_check || status=1
body_prove prove_mutation "next identifies its block" "$MAIN_VISITOR" \
  "      node.target = block" \
  "      node.target = nil" -- ensure_targets_check || status=1
body_prove prove_mutation "captured next identifies its proc def" "$MAIN_VISITOR" \
  "                @jump_proc = literal_def" \
  "                @jump_proc = nil" -- ensure_targets_check || status=1

echo
echo "== 4b. A name no module defines is never typed in another module's def body (port only)"
leak_typed=$("$TYPED" "$REPO_NATIVE/bench/fixtures/bodies_scope_leak_b.iyi" "$REPO_NATIVE/src" 2>/dev/null | awk '$1 ~ /^5:/' | wc -l | tr -d ' ')
if [ "${leak_typed:-1}" -eq 0 ]; then
  echo "  refused: bodies_scope_leak_b.iyi line 5 (scope_value_nowhere) is untyped"
else
  echo "  NOT REFUSED: bodies_scope_leak_b.iyi line 5 has $leak_typed typed node(s)"
  status=1
fi

echo
echo "== 4c. A macro site in a def body sees the receiver's type parameters and the def's free variables"
# Rebuilds the typed dump from the patched source and checks the macro-bindings fixture alone.
macro_bindings_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return $?; }
  fixture="$REPO/bench/fixtures/sem_bodies_macro_bindings.iyi"
  rel="bench/fixtures/sem_bodies_macro_bindings.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mp.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  matched=$(comm -12 "$WORK/mo.txt" "$WORK/mp.txt" | wc -l | tr -d ' ')
  floor=$(awk -v r="$rel" '$1 == r { print $2 }' "$FLOOR_FILE" 2>/dev/null)
  [ -n "${floor:-}" ] || return 1
  [ "$matched" -ge "$floor" ]
}
body_prove prove_mutation "a macro site in a def body does not see the receiver's type parameters" "$MAIN_VISITOR" \
  "    MacroBindings.of(@scope, free)" \
  "    MacroBindings.of(nil, free)" -- macro_bindings_at_floor || status=1
body_prove prove_mutation_all "a macro site in a def body does not see the def's free variables" "$MAIN_VISITOR" \
  "@def_free_types[target_def] = free_types unless free_types.empty?" \
  "        nil" -- macro_bindings_at_floor || status=1
echo
echo "== 4d. A macro site in an enum method sees its constants"
macro_enum_facts_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return 2; }
  fixture="$REPO/bench/fixtures/sem_bodies_macro_enum_facts.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/eo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/ep.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  matched=$(comm -12 "$WORK/eo.txt" "$WORK/ep.txt" | wc -l | tr -d ' ')
  [ "$matched" -ge 6 ]
}
body_prove prove_mutation_all "enum macro facts are not passed to the body splice" "$MAIN_VISITOR" \
  "MacroBindings.facts(@scope)" \
  "nil" -- macro_enum_facts_at_floor || status=1
macro_ivars_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return 2; }
  fixture="$REPO/bench/fixtures/sem_bodies_macro_ivars.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/eo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/ep.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  matched=$(comm -12 "$WORK/eo.txt" "$WORK/ep.txt" | wc -l | tr -d ' ')
  [ "$matched" -ge 10 ]
}
body_prove prove_mutation "instance variable facts are not passed to the body splice" "$REPO/src/compiler/semantic/macro_bindings.iyi" \
  "      facts.instance_vars_known = true
      owner.as(ModuleType).all_instance_vars.each" \
  "      facts.instance_vars_known = false
      owner.as(ModuleType).all_instance_vars.each" -- macro_ivars_at_floor || status=1
macro_annotations_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return 2; }
  fixture="$REPO/bench/fixtures/sem_bodies_macro_annotations.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/eo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/ep.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  matched=$(comm -12 "$WORK/eo.txt" "$WORK/ep.txt" | wc -l | tr -d ' ')
  [ "$matched" -ge 12 ]
}
body_prove prove_mutation "enum annotations are not supplied to macro sites" "$REPO/src/compiler/semantic/macro_bindings.iyi" \
  "facts.annotations_known = true" \
  "facts.annotations_known = false" -- macro_annotations_at_floor || status=1
macro_value_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return 2; }
  fixture="$REPO/bench/fixtures/sem_bodies_macro_value.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/eo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/ep.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  matched=$(comm -12 "$WORK/eo.txt" "$WORK/ep.txt" | wc -l | tr -d ' ')
  [ "$matched" -ge 9 ]
}
body_prove prove_mutation "a value-position macro expansion is not typed" "$MAIN_VISITOR" \
  "    expanded.accept(self)
    if et = child_type(expanded)
      set_type(node, et)
    end
    false
  end

  def visit(node : MacroFor)" \
  "    nil
    if et = child_type(expanded)
      set_type(node, et)
    end
    false
  end

  def visit(node : MacroFor)" -- macro_value_at_floor || status=1
macro_empty_at_floor() {
  if ! "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1; then
    body_build_failed "$WORK/mut_build.log"
    return $?
  fi
  fixture="$REPO/bench/fixtures/sem_bodies_macro_empty.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/eo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/ep.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  matched=$(comm -12 "$WORK/eo.txt" "$WORK/ep.txt" | wc -l | tr -d ' ')
  [ "$matched" -ge 18 ]
}
body_prove prove_mutation "an empty def-body macro is dropped, so the preceding expression types the def" "$REPO/src/compiler/semantic/inline_macros.iyi" \
  "        out << n if keep_empty" \
  "        nil" -- macro_empty_at_floor || status=1
macro_uninitialized_at_floor() {
  "$IYI" build -o "$WORK_NATIVE/macro_uninitialized$EXE" "$REPO_NATIVE/bench/selfhost_macro_uninitialized_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return 2; }
  local rc=0
  "$WORK/macro_uninitialized$EXE" "$REPO_NATIVE/bench/fixtures/sem_bodies_macro_uninitialized.iyi" >"$WORK/macro_uninitialized.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 1 ] && grep -Fxq 'later expansion did not parse the uninitialized local as a variable' "$WORK/macro_uninitialized.log"; then return 1; fi
  cat "$WORK/macro_uninitialized.log" >&9
  return 2
}
macro_uninitialized_at_floor || status=1
body_prove prove_mutation "uninitialized locals are unavailable to later macro sites" "$REPO/src/compiler/semantic/inline_macros.iyi" \
  "  def visit(node : UninitializedVar) : Bool
    add_name(node.var)" \
  "  def visit(node : UninitializedVar) : Bool
    nil" -- macro_uninitialized_at_floor || status=1
free_types_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return $?; }
  fixture="$REPO/bench/fixtures/sem_bodies_free_types.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mp.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  matched=$(comm -12 "$WORK/mo.txt" "$WORK/mp.txt" | wc -l | tr -d ' ')
  floor=$(awk '$1 == "bench/fixtures/sem_bodies_free_types.iyi" { print $2 }' "$FLOOR_FILE")
  [ -n "$floor" ] && [ "$matched" -ge "$floor" ]
}
body_prove prove_mutation "a callee's free types are unavailable to body and return lookup" "$MAIN_VISITOR" \
  "      if bound = @def_free_types[cd]?
        found = ArgRestriction.lookup_free(type_node_system(@program), @current_type, node, owner, bound)" \
  "      if bound = @def_free_types[cd]?
        found = LookupError.new(\"unbound\")" -- free_types_at_floor || status=1
block_free_output_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return $?; }
  for name in sem_bodies_block_free_output sem_bodies_block_free_body; do
    fixture="$REPO/bench/fixtures/$name.iyi"
    "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
    "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mp.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
    matched=$(comm -12 "$WORK/mo.txt" "$WORK/mp.txt" | wc -l | tr -d ' ')
    floor=$(awk -v r="bench/fixtures/$name.iyi" '$1 == r { print $2 }' "$FLOOR_FILE")
    { [ -n "$floor" ] && [ "$matched" -ge "$floor" ]; } || return 1
  done
}
body_prove prove_mutation "a yielded block's output binds its callee's free variable before the body" "$MAIN_VISITOR" \
  "@def_free_types[target_def] = output_bound unless output_bound.empty?" \
  "nil" -- block_free_output_at_floor || status=1
captured_free_output_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return $?; }
  fixture="$REPO/bench/fixtures/sem_bodies_capture_free_output.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mp.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  matched=$(comm -12 "$WORK/mo.txt" "$WORK/mp.txt" | wc -l | tr -d ' ')
  floor=$(awk '$1 == "bench/fixtures/sem_bodies_capture_free_output.iyi" { print $2 }' "$FLOOR_FILE")
  [ -n "$floor" ] && [ "$matched" -ge "$floor" ]
}
body_prove prove_mutation "captured block output binds its callee's free variable" "$MAIN_VISITOR" \
  "                      if FreeBindings.bind(output, bt, free_names, bound)
                        @def_free_types[target_def] = bound unless bound.empty?" \
  "                      if FreeBindings.bind(output, bt, free_names, bound)
                        nil" -- captured_free_output_at_floor || status=1
captured_wildcard_at_expected() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return $?; }
  fixture="$REPO/bench/fixtures/bodies_capture_wildcard.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mp.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  diff -q "$WORK/mo.txt" "$WORK/mp.txt" >/dev/null
}
captured_wildcard_at_expected || status=1
body_prove prove_mutation "captured wildcard block has its hosted NoReturn type" "$MAIN_VISITOR" \
  "                    # Block NoReturn, while the Proc keeps its body's type.
                    set_type(blk, @program.no_return_type)" \
  "                    # Block NoReturn, while the Proc keeps its body's type.
                    nil" -- captured_wildcard_at_expected || status=1
generic_rebuild_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return $?; }
  [ "${_PM_ARMED:-0}" != 1 ] || touch "$WORK/imported_generic_mutant_built"
  fixture="$REPO/bench/fixtures/sem_bodies_owner_typeof.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mp.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  matched=$(comm -12 "$WORK/mo.txt" "$WORK/mp.txt" | wc -l | tr -d ' ')
  floor=$(awk '$1 == "bench/fixtures/sem_bodies_owner_typeof.iyi" { print $2 }' "$FLOOR_FILE")
  if [ "${_PM_ARMED:-0}" = 1 ]; then printf '%s of floor %s\n' "$matched" "$floor" > "$WORK/imported_generic_mutant_count"; fi
  [ -n "$floor" ] && [ "$matched" -ge "$floor" ]
}
rm -f "$WORK/imported_generic_mutant_built" "$WORK/imported_generic_mutant_count"
body_prove prove_mutation "a generic with typed arguments is rebuilt" "$REPO/src/compiler/semantic/type_nodes.iyi" \
  "  resolved = generic_of_typed_args(visitor, node)" \
  "  resolved = nil" -- generic_rebuild_at_floor || status=1
if [ "${MUTATION_SKIP:-0}" != 1 ] && [ ! -f "$WORK/imported_generic_mutant_built" ]; then
  echo "  FAIL: generic rebuild mutation did not build"
  status=1
fi
if [ -f "$WORK/imported_generic_mutant_count" ]; then
  echo "  generic rebuild mutant matched $(<"$WORK/imported_generic_mutant_count")"
fi
writer_type_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return $?; }
  fixture="$REPO/bench/fixtures/sem_bodies_block_writer_type.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mp.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  matched=$(comm -12 "$WORK/mo.txt" "$WORK/mp.txt" | wc -l | tr -d ' ')
  floor=$(awk '$1 == "bench/fixtures/sem_bodies_block_writer_type.iyi" { print $2 }' "$FLOOR_FILE")
  [ -n "$floor" ] && [ "$matched" -ge "$floor" ]
}
body_prove prove_mutation "block body uses the writer's current type" "$MAIN_VISITOR" \
  "        if writer_type = owner.writer_type
          @current_type = writer_type" \
  "        if writer_type = owner.writer_type
          nil" -- writer_type_at_floor || status=1
captured_input_at_floor() {
  "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return $?; }
  fixture="$REPO/bench/fixtures/sem_bodies_capture_none.iyi"
  "$ORACLE" "$(native_path "$fixture")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mo.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fixture")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/mp.txt" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  matched=$(comm -12 "$WORK/mo.txt" "$WORK/mp.txt" | wc -l | tr -d ' ')
  floor=$(awk '$1 == "bench/fixtures/sem_bodies_capture_none.iyi" { print $2 }' "$FLOOR_FILE")
  [ -n "$floor" ] && [ "$matched" -ge "$floor" ]
}
body_prove prove_mutation "captured block parameters use restriction inputs" "$MAIN_VISITOR" \
  "                    @vars[arg.name] = input_types[index]" \
  "                    @vars[arg.name] = @program.nil_type" -- captured_input_at_floor || status=1
# A total-mode probe with refused bodies must write its table and exit 1,
# rather than reaching whole-program lowering with incomplete types.
body_table_probe() {
  local tool="$1" input="$2" stem="$3" rc=0
  rm -f "$WORK/$stem" "$WORK/$stem.refusals" "$WORK/$stem.names"
  "$tool" "$input" -o "$WORK_NATIVE/$stem" --pipeline typed --prelude --probe-phase --keep-going >"$WORK/$stem.log" 2>"$WORK/$stem.err" || rc=$?
  if grep -Eq 'BUG:|iyi: panic:' "$WORK/$stem.log" "$WORK/$stem.err"; then
    echo "INVALID PROOF: $stem panicked" >&9
    cat "$WORK/$stem.log" "$WORK/$stem.err" >&9
    return 2
  fi
  if [ "$rc" -eq 1 ] && [ ! -e "$WORK/$stem" ] &&
     grep -Eq '^iyi-compile-native: lower: body typing recorded [1-9][0-9]* refusal\(s\); whole-program lowering is unavailable$' "$WORK/$stem.err"; then
    return 0
  fi
  if [ "$rc" -eq 0 ] && [ -f "$WORK/$stem" ]; then return 0; fi
  echo "INVALID PROOF: $stem did not produce a valid output or the expected body refusal (exit $rc)" >&9
  cat "$WORK/$stem.log" "$WORK/$stem.err" >&9
  return 2
}

atomic_free_at_floor() {
  "$IYI" build -o "$WORK_NATIVE/atomic_tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/mut_build.log" 2>&1 || { body_build_failed "$WORK/mut_build.log"; return $?; }
  body_table_probe "$WORK/atomic_tool$EXE" "$REPO_NATIVE/bench/fixtures/sem_bodies_match_atomics.iyi" atomic || return 2
  [ -f "$WORK/atomic.refusals" ] || { echo "INVALID MUTANT: no refusal table" >&9; return 2; }
  awk -F '\t' '
    $1 == "body" && $2 ~ /^MatchAtomic\((UInt64|Int64)\)#(get|set|add|compare_and_set)$/ { bad = 1 }
    $1 == "reached" && $2 ~ /^MatchAtomic\((UInt64|Int64)\)#(get|set|add|compare_and_set)$/ { seen[$2] = 1 }
    END { for (name in seen) count++; exit bad || count != 8 }
  ' "$WORK/atomic.refusals"
}
 # A block call must not match the generated initialize new. Returns non-zero
 # when that filter is gone and the fixture no longer matches the hosted dump.
 array_new_yields() {
   if ! "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/array_mut_build.log" 2>&1; then
     body_build_failed "$WORK/array_mut_build.log"
     return $?
   fi
   fx="$REPO/bench/fixtures/sem_bodies_array_new.iyi"
   "$ORACLE" "$(native_path "$fx")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/array_mut.hosted" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
   "$MUT_TD" "$(native_path "$fx")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/array_mut.port" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
   if diff -q "$WORK/array_mut.hosted" "$WORK/array_mut.port" >/dev/null; then
     return 0
   fi
   return 1
 }
body_prove prove_mutation "a block call matches only a yielding new" "$MAIN_VISITOR" \
  "        next unless CallMatch.yields?(definition) == !call_node.block.nil?" \
  "        next if CallMatch.yields?(definition) == !call_node.block.nil?" -- array_new_yields || status=1
if ! atomic_free_at_floor; then
  echo "  ATOMIC: one of the instantiated atomic bodies was refused or not reached"
  status=1
fi
untyped_call_arguments_safe() {
  if ! "$IYI" build -o "$WORK_NATIVE/untyped_call_tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/untyped_call_build.log" 2>&1; then
    body_build_failed "$WORK/untyped_call_build.log"
    return $?
  fi
  if [ "$HOST_OS" = darwin ] && ! codesign -v --strict "$WORK/untyped_call_tool$EXE"; then return 2; fi
  body_table_probe "$WORK/untyped_call_tool$EXE" "$REPO_NATIVE/bench/fixtures/sem_bodies_untyped_call_argument.iyi" untyped_call || return 2
  if [ -e "$WORK/untyped_call" ] || ! grep -Eq '^iyi-compile-native: lower: body typing recorded [1-9][0-9]* refusal\(s\); whole-program lowering is unavailable$' "$WORK/untyped_call.err"; then
    echo "INVALID PROOF: untyped-call probe did not refuse whole-program lowering" >&9
    cat "$WORK/untyped_call.log" "$WORK/untyped_call.err" >&9
    return 2
  fi
  if grep -Eq 'BUG:|iyi: panic:' "$WORK/untyped_call.log" "$WORK/untyped_call.err"; then
    echo "INVALID PROOF: untyped-call probe panicked" >&9
    return 2
  fi
  [ -f "$WORK/untyped_call.refusals" ] || { echo "INVALID PROOF: no untyped-call refusal table" >&9; return 2; }
  grep -Fq '[phase] bodies: pass' "$WORK/untyped_call.log" || return 1
  grep -Eq '^table: sem_bodies_untyped_call_argument refusal 4 owner=.* reason=an argument was not typed: fresh ' "$WORK/untyped_call.log" || return 1
  awk -F '\t' '
    $1 == "lowering" && $2 == "CensusDerived+#compute" && $4 ~ /^(body typing|depends on )/ { derived = 1 }
    $1 == "lowering" && $2 == "CensusLeaf#compute" && $4 ~ /^(body typing|depends on )/ { leaf = 1 }
    END { exit !(derived && leaf) }
  ' "$WORK/untyped_call.refusals"
}
if ! untyped_call_arguments_safe; then
  echo "  UNTYPED CALL: positional and named arguments must be refused without a bodies panic"
  status=1
fi
body_prove prove_mutation "an untyped positional argument stops before call matching" "$MAIN_VISITOR" \
  'return untyped(node, "an argument was not typed: #{arg}") if child_type(arg).nil?' \
  'set_type(arg, @program.nil_type) if child_type(arg).nil?' -- untyped_call_arguments_safe || status=1
body_prove prove_mutation "an untyped named argument stops before call matching" "$MAIN_VISITOR" \
  'return untyped(node, "an argument was not typed: #{arg.value}") if child_type(arg.value).nil?' \
  'set_type(arg.value, @program.nil_type) if child_type(arg.value).nil?' -- untyped_call_arguments_safe || status=1
generic_alias_restriction_safe() {
  if ! "$IYI" build -o "$WORK_NATIVE/alias_tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/alias_build.log" 2>&1; then
    body_build_failed "$WORK/alias_build.log"
    return $?
  fi
  if [ "$HOST_OS" = darwin ] && ! codesign -v --strict "$WORK/alias_tool$EXE"; then return 2; fi
  if ! "$WORK/alias_tool$EXE" "$REPO_NATIVE/bench/fixtures/sem_bodies_generic_alias_restriction.iyi" \
    -o "$WORK_NATIVE/alias_probe.ll" --pipeline typed --prelude --probe-phase --emit ir > "$WORK/alias_probe.log" 2>&1; then
    cat "$WORK/alias_probe.log" >&9
    return 2
  fi
  [ -s "$WORK/alias_probe.ll" ] && grep -Fq '[phase] verify: pass' "$WORK/alias_probe.log"
}
generic_alias_restriction_safe || status=1
CRYSTAL_PATH="$REPO_NATIVE/src" "$CRYSTAL" build -Di_know_what_im_doing -o "$WORK_NATIVE/alias_types_oracle$EXE" "$REPO_NATIVE/bench/selfhost_semantic_types_oracle.cr" > "$WORK/alias_types_oracle_build.log" 2>&1 || { cat "$WORK/alias_types_oracle_build.log"; exit 1; }
"$WORK/alias_types_oracle$EXE" "$REPO_NATIVE/bench/fixtures/semty_nested_alias_lookup.iyi" > "$WORK/alias_types.hosted" || exit 1
generic_alias_lookup_matches() {
  if ! "$IYI" build -o "$WORK_NATIVE/alias_types$EXE" "$REPO_NATIVE/bench/selfhost_semantic_types_exercise.iyi" > "$WORK/alias_types_build.log" 2>&1; then
    body_build_failed "$WORK/alias_types_build.log"
    return $?
  fi
  "$WORK/alias_types$EXE" "$REPO_NATIVE/bench/fixtures/semty_nested_alias_lookup.iyi" > "$WORK/alias_types.port" 2>"$WORK/alias_types.err" || { cat "$WORK/alias_types.err" >&9; return 2; }
  diff -q "$WORK/alias_types.hosted" "$WORK/alias_types.port" >/dev/null
}
generic_alias_lookup_matches || status=1
body_prove prove_mutation "generic arguments resolve their aliases before instantiation" "$REPO/src/compiler/types/lookup.iyi" \
  "      return expand(target.as(Type))" \
  "      return type" -- generic_alias_lookup_matches || status=1
body_prove prove_mutation "a resolved pointer restriction binds its free variable" "$MAIN_VISITOR" \
  "      if free_types = FreeBindings.of_def(target_def, call_arg_types, type_node_system(@program))
        @def_free_types[target_def] = free_types unless free_types.empty?" \
  "      if free_types = FreeBindings.of_def(target_def, call_arg_types, type_node_system(@program))
        nil" -- atomic_free_at_floor || status=1
# Concrete static array annotations retain their element type and size.
static_array_return_at_floor() {
  if ! "$IYI" build -o "$(native_path "$MUT_TD")" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/static_array_mut_build.log" 2>&1; then
    body_build_failed "$WORK/static_array_mut_build.log"
    return $?
  fi
  fx="$REPO/bench/fixtures/sem_bodies_static_array_return.iyi"
  rel="bench/fixtures/sem_bodies_static_array_return.iyi"
  "$ORACLE" "$(native_path "$fx")" 2>"$WORK/body_mut_run.err" | sort > "$WORK/static_array_mut.hosted" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  "$MUT_TD" "$(native_path "$fx")" "$REPO_NATIVE/src" 2>"$WORK/body_mut_run.err" | sort > "$WORK/static_array_mut.port" || { cat "$WORK/body_mut_run.err" >&9; return 2; }
  matched=$(comm -12 "$WORK/static_array_mut.hosted" "$WORK/static_array_mut.port" | wc -l | tr -d ' ')
  floor=$(awk -v r="$rel" '$1 == r { print $2 }' "$FLOOR_FILE" 2>/dev/null)
  # Without a floor the mutation must not be credited as caught.
  [ "$matched" -ge "${floor:-0}" ]
}
body_prove prove_mutation "a static array return annotation is typed as the bare StaticArray(T, N)" "$REPO/src/compiler/semantic/top_level.iyi" \
  "hook.resolve_node?(node, current_type)" \
  "hook.resolve_node?(g.name, current_type)" -- type_lookup_at_expected || status=1
body_prove prove_mutation "a static array prints its element's virtual type" "$REPO/src/compiler/types/types.iyi" \
  '"StaticArray(#{@element_type.devirtualize.arg_full_name}, #{@size_int})"' \
  '"StaticArray(#{@element_type.full_name}, #{@size_int})"' -- static_array_return_at_floor || status=1
bare_splat_bounds() {
  if ! "$IYI" build -o "$WORK_NATIVE/bare_splat_bounds$EXE" "$REPO_NATIVE/bench/selfhost_bare_splat_arity_probe.iyi" > "$WORK/bare_splat_build.log" 2>&1; then
    body_build_failed "$WORK/bare_splat_build.log"
    return $?
  fi
  body_assertion_probe 'selfhost_bare_splat_arity_probe\.iyi:(12|13|34|35|38|39|40|41|42|43|44|45|46|54|58)' \
    'wrong argument bounds|wrong minimum|omitted expansion failed|omitted expansion arity|named expansion failed|named expansion arity|named expansion label|named argument overwritten by default|missing default assignment|extra positional accepted|unknown named argument accepted|duplicate named argument accepted|duplicate positional argument accepted|splat named restriction lost|wrapper named restriction lost' \
    "$WORK/bare_splat_bounds$EXE"
}
bare_splat_bounds || status=1
body_prove prove_mutation "the first default sets the minimum" "$MAIN_VISITOR" \
  "        default_index = i" "        default_index = -1" -- bare_splat_bounds || status=1
body_prove prove_mutation "a bare splat limits positional arguments" "$MAIN_VISITOR" \
  "        max_size = splat_index" "        max_size = d.args.size" -- bare_splat_bounds || status=1
body_prove prove_mutation "a default before a splat lowers the minimum" "$MAIN_VISITOR" \
  "        min_size = default_index" "        min_size = splat_index" -- bare_splat_bounds || status=1
body_prove prove_mutation "a restricted named splat needs an argument" "$MAIN_VISITOR" \
  "            min_size = min_size + 1" "            min_size = splat_index" -- bare_splat_bounds || status=1
body_prove prove_mutation "a named splat has an unbounded maximum" "$MAIN_VISITOR" \
  "        max_size = 2147483647" "        max_size = d.args.size" -- bare_splat_bounds || status=1
body_prove prove_mutation "a tuple restriction permits an empty splat" "$MAIN_VISITOR" \
  "if !restriction.is_a?(Splat) && !(default_index >= 0 && default_index < splat_index)" \
  "if !(default_index >= 0 && default_index < splat_index)" -- bare_splat_bounds || status=1
body_prove prove_mutation "a named argument survives splat expansion" "$REPO/src/compiler/semantic/default_arguments.iyi" \
  "        matching = rec_def.args[param_index(rec_def, named.name)]
        new_args << Arg.new(matching.name, nil, copy_node(matching.restriction), named.name)" \
  "        matching = rec_def.args[param_index(rec_def, named.name)]
        nil" -- bare_splat_bounds || status=1
body_prove prove_mutation "a splat expansion retains its call-site name" "$REPO/src/compiler/semantic/default_arguments.iyi" \
  '        new_name = "#{new_name}:#{named.name}"
        matching = rec_def.args[param_index(rec_def, named.name)]' \
  '        new_name = rec_def.name
        matching = rec_def.args[param_index(rec_def, named.name)]' -- bare_splat_bounds || status=1
body_prove prove_mutation "a bare splat rejects excess positionals" "$REPO/src/compiler/semantic/default_arguments.iyi" \
  "    if rec_def.args[index].name.empty? && given > index" \
  "    if false" -- bare_splat_bounds || status=1
body_prove prove_mutation "invalid or duplicate names are rejected" "$REPO/src/compiler/semantic/default_arguments.iyi" \
  "        if named_index < before || named_index == index || seen.includes?(named.name)" \
  "        if false" -- bare_splat_bounds || status=1
body_prove prove_mutation "a supplied named parameter is not defaulted" "$REPO/src/compiler/semantic/default_arguments.iyi" \
  "      if k != index && !named_given?(named_args, rec_def.args[k].external_name)" \
  "      if k != index" -- bare_splat_bounds || status=1
restriction_scope_at_floor() {
  if ! "$IYI" build -o "$WORK_NATIVE/scope_tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/scope_tool_build.log" 2>&1; then
    body_build_failed "$WORK/scope_tool_build.log"
    return $?
  fi
  local rc=0
  if [ "$HOST_ID" = darwin-arm64 ]; then
    "$WORK/scope_tool$EXE" "$REPO_NATIVE/bench/fixtures/sem_bodies_restriction_scope.iyi" \
      -o "$WORK_NATIVE/scope_native$EXE" --pipeline typed --prelude --probe-phase > "$WORK/scope_phase.log" 2> "$WORK/scope_build.log" || rc=$?
  else
    host_limited "restriction-scope Mach-O execution requires the Darwin arm64 kernel; inspecting its IR instead"
    "$WORK/scope_tool$EXE" "$REPO_NATIVE/bench/fixtures/sem_bodies_restriction_scope.iyi" \
      -o "$WORK_NATIVE/scope_native.ll" --pipeline typed --prelude --probe-phase --emit ir > "$WORK/scope_phase.log" 2> "$WORK/scope_build.log" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    if [ "${_PM_ARMED:-0}" = 1 ] &&
       grep -Eq 'bodies: refused at .*t6_scope[/\\]call\.iyi:7:' "$WORK/scope_phase.log" &&
       expected_refusal "$rc" "$WORK/scope_build.log" src/compiler/semantic/main_visitor.iyi "^no overload matches 'T6Scope::Visitor::Visitor#check' with type T6Scope::Types::Call$"; then
      return 1
    fi
    echo "INVALID MUTANT: scope fixture failed for an unexpected reason" >&9
    cat "$WORK/scope_phase.log" "$WORK/scope_build.log" >&9
    return 2
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then
    [ -s "$WORK/scope_native.ll" ] && grep -Fq '[phase] verify: pass' "$WORK/scope_phase.log"
    return $?
  fi
  if ! codesign -v --strict "$WORK/scope_native$EXE" > "$WORK/scope_sign.log" 2>&1; then
    echo "INVALID PROOF: scope fixture did not pass strict codesign" >&9
    cat "$WORK/scope_sign.log" >&9
    return 2
  fi
  local output
  output="$("$WORK/scope_native$EXE" 2>"$WORK/scope_run.err")" || { cat "$WORK/scope_run.err" >&9; return 2; }
  [ "$output" = 42 ]
}
restriction_scope_at_floor || status=1
body_prove prove_mutation "a restriction resolves in its definition owner scope" "$MAIN_VISITOR" \
  "        enter_file_scope(definition)" \
  "        nil" -- restriction_scope_at_floor || status=1
if [ "$status" -eq 0 ]; then
  echo
  echo "== ALL BODY FIXTURES AT THEIR FLOORS"
else
  echo
  echo "== SOME BODY FIXTURE CHECKS FAILED"
fi
exit "$status"
