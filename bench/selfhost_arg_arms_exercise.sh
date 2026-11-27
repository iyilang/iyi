#!/usr/bin/env bash
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")" || exit 1
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"

# The probe is a host program. A crash or refusal is not an arm mismatch.
arm_probe() {
  local fixture="$1" rc=0
  shift
  "$WORK/probe$EXE" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" "$REPO_NATIVE/src" "$@" 2>"$WORK/probe.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "INVALID: arm probe exited $rc for $fixture" >&2
    cat "$WORK/probe.err" >&2
    return 2
  fi
}

# These hosted outcomes are independent baselines, not mutant behavior.
oracle_result() {
  local fixture="$1" output="$2" mode="$3" expected="$4" rc=0
  "$IYI" run "$REPO_NATIVE/bench/fixtures/$fixture.iyi" > "$output" 2>&1 || rc=$?
  if [ "$mode" = accept ]; then
    if [ "$rc" -eq 0 ] && grep -Fxq "$expected" "$output"; then return 0; fi
  else
    if [ "$rc" -eq 1 ] && grep -Fq "$expected" "$output"; then return 0; fi
  fi
  echo "INVALID: hosted oracle $fixture exited $rc without the expected $mode result" >&2
  cat "$output" >&2
  return 2
}

check_arms_impl() {
  if ! "$IYI" build -o "$WORK_NATIVE/probe$EXE" "$REPO_NATIVE/bench/selfhost_arg_arms_probe.iyi" > "$WORK/build.log" 2>&1; then
    echo "INVALID: arm probe failed to build" >&2
    cat "$WORK/build.log" >&2
    return 2
  fi
  arm_probe sem_arms_union_overload consume > "$WORK/union" || return $?
  printf '%s\n' 'arms=2 cover=true' 'main#consume:Int32' 'main#consume:String' > "$WORK/expected"
  cmp -s "$WORK/union" "$WORK/expected" || return 1
  arm_probe sem_arms_order show > "$WORK/order" || return $?
  printf '%s\n' 'arms=2 cover=true' 'main#show:A' 'main#show:Node+' > "$WORK/expected"
  cmp -s "$WORK/order" "$WORK/expected" || return 1
  arm_probe sem_arms_partial consume > "$WORK/partial" || return $?
  printf '%s\n' 'arms=1 cover=false' 'main#consume:Int32' > "$WORK/expected"
  cmp -s "$WORK/partial" "$WORK/expected" || return 1
  arm_probe sem_arms_uncovered consume > "$WORK/uncovered" || return $?
  printf '%s\n' 'arms=2 cover=false' 'main#consume:Int32,Bool' 'main#consume:String,String' > "$WORK/expected"
  cmp -s "$WORK/uncovered" "$WORK/expected" || return 1
  oracle_result sem_arms_uncovered "$WORK/oracle" refuse "expected argument #1 to 'consume'" || return $?
  arm_probe sem_arms_generic_new new > "$WORK/generic" || return $?
  printf '%s\n' 'arms=1 cover=true' 'Box(T).class#new:UInt64' 'owner=Box(UInt64).class' > "$WORK/expected"
  cmp -s "$WORK/generic" "$WORK/expected" || return 1
  arm_probe sem_arms_generic_new_mismatch new > "$WORK/mismatch" || return $?
  printf '%s\n' 'arms=0 cover=false' > "$WORK/expected"
  cmp -s "$WORK/mismatch" "$WORK/expected" || return 1
  arm_probe sem_arms_named_new new > "$WORK/named" || return $?
  printf '%s\n' 'arms=1 cover=true' 'Stream.class#new:Int64' 'owner=Stream.class' > "$WORK/expected"
  cmp -s "$WORK/named" "$WORK/expected" || return 1
  arm_probe sem_arms_named_new_mismatch new > "$WORK/named-mismatch" || return $?
  printf '%s\n' 'arms=0 cover=false' > "$WORK/expected"
  cmp -s "$WORK/named-mismatch" "$WORK/expected" || return 1
  for kind in module trait; do
    arm_probe "sem_arms_${kind}_arg" show > "$WORK/$kind" || return $?
    printf '%s\n' 'arms=2 cover=true' 'main#show:A' 'main#show:(A | B)' > "$WORK/expected"
    cmp -s "$WORK/$kind" "$WORK/expected" || return 1
  done
  arm_probe sem_arms_module_walk select modules > "$WORK/modules" || return $?
  printf '%s\n' 'arms=1 cover=false' 'Label#select:String' > "$WORK/expected"
  cmp -s "$WORK/modules" "$WORK/expected" || return 1
  arm_probe sem_arms_numeric widen > "$WORK/numeric" || return $?
  printf '%s\n' 'arms=1 cover=true' 'main#widen:Int64' > "$WORK/expected"
  cmp -s "$WORK/numeric" "$WORK/expected" || return 1
  arm_probe sem_arms_numeric_ambiguous widen > "$WORK/numeric-ambiguous" || return $?
  printf '%s\n' 'arms=0 cover=false' 'error=ambiguous call, implicit cast of 1 matches all of Int64, UInt64' > "$WORK/expected"
  cmp -s "$WORK/numeric-ambiguous" "$WORK/expected" || return 1
  oracle_result sem_arms_numeric_ambiguous "$WORK/ambiguous-oracle" refuse 'ambiguous call, implicit cast of 1 matches all of Int64, UInt64' || return $?
  arm_probe sem_arms_numeric_parent widen > "$WORK/numeric-parent" || return $?
  printf '%s\n' 'arms=1 cover=true' 'Child#widen:Int64' > "$WORK/expected"
  cmp -s "$WORK/numeric-parent" "$WORK/expected" || return 1
  oracle_result sem_arms_numeric_parent "$WORK/numeric-parent-oracle" accept 1 || return $?
  arm_probe sem_arms_unresolved consume > "$WORK/unresolved" || return $?
  printf '%s\n' 'arms=1 cover=true' 'main#consume:Int32' > "$WORK/expected"
  cmp -s "$WORK/unresolved" "$WORK/expected" || return 1
  arm_probe sem_arms_unresolved_partial consume > "$WORK/unresolved-partial" || return $?
  printf '%s\n' 'arms=1 cover=false' 'main#consume:Int32' > "$WORK/expected"
  cmp -s "$WORK/unresolved-partial" "$WORK/expected" || return 1
  arm_probe sem_arms_unresolved_only consume > "$WORK/unresolved-only" || return $?
  printf '%s\n' 'arms=0 cover=false' 'error=undefined constant MissingType' > "$WORK/expected"
  cmp -s "$WORK/unresolved-only" "$WORK/expected" || return 1
  arm_probe sem_arms_block_output produce > "$WORK/block" || return $?
  printf '%s\n' 'arms=1 cover=true' 'main#produce:' > "$WORK/expected"
  cmp -s "$WORK/block" "$WORK/expected" || return 1
  arm_probe sem_arms_capture_output capture > "$WORK/capture" || return $?
  printf '%s\n' 'arms=1 cover=true' 'main#capture:' > "$WORK/expected"
  cmp -s "$WORK/capture" "$WORK/expected" || return 1
  arm_probe sem_arms_block_unbound produce > "$WORK/block-unbound" || return $?
  printf '%s\n' 'arms=0 cover=false' 'error=undefined constant V' > "$WORK/expected"
  cmp -s "$WORK/block-unbound" "$WORK/expected" || return 1
  arm_probe sem_arms_bare_splat_named pick > "$WORK/bare" || return $?
  printf '%s\n' 'arms=1 cover=true' 'Bare.class#pick:Int32' > "$WORK/expected"
  cmp -s "$WORK/bare" "$WORK/expected" || return 1
  for kind in missing excess; do
    arm_probe "sem_arms_bare_splat_${kind}" pick > "$WORK/bare-$kind" || return $?
    printf '%s\n' 'arms=0 cover=false' > "$WORK/expected"
    cmp -s "$WORK/bare-$kind" "$WORK/expected" || return 1
  done
  arm_probe sem_arms_named_splat_tail pick > "$WORK/named-tail" || return $?
  printf '%s\n' 'arms=0 cover=false' 'error=parameters after a named splat are not ported' > "$WORK/expected"
  cmp -s "$WORK/named-tail" "$WORK/expected" || return 1
  arm_probe sem_arms_named_order pick parents signature > "$WORK/named-order" || return $?
  printf '%s\n' 'arms=2 cover=true' 'main#pick:' 'signature=pick(, value : String)' 'main#pick:' 'signature=pick(, value : Object)' > "$WORK/expected"
  cmp -s "$WORK/named-order" "$WORK/expected" || return 1
  oracle_result sem_arms_named_order "$WORK/named-order-oracle" accept string || return $?
  arm_probe sem_arms_named_forward named_choose parents signature > "$WORK/named-forward" || return $?
  printf '%s\n' 'arms=1 cover=true' 'main#named_choose:' 'signature=named_choose(, value : NamedValue)' > "$WORK/expected"
  cmp -s "$WORK/named-forward" "$WORK/expected" || return 1
  oracle_result sem_arms_named_forward "$WORK/named-forward-oracle" accept broad || return $?
  arm_probe sem_arms_named_free identity parents binding > "$WORK/named-free" || return $?
  printf '%s\n' 'arms=1 cover=true' 'main#identity:' 'binding=T:Int32' 'named=Int32' > "$WORK/expected"
  cmp -s "$WORK/named-free" "$WORK/expected" || return 1
  for kind in named mixed; do
    arm_probe "sem_arms_${kind}_free_conflict" pair > "$WORK/$kind-conflict" || return $?
    printf '%s\n' 'arms=0 cover=false' > "$WORK/expected"
    cmp -s "$WORK/$kind-conflict" "$WORK/expected" || return 1
  done
  arm_probe sem_arms_named_free_numeric pair parents binding > "$WORK/named-free-numeric" || return $?
  printf '%s\n' 'arms=1 cover=true' 'main#pair:' 'binding=T:Int64' 'named=Int64,Int64' > "$WORK/expected"
  cmp -s "$WORK/named-free-numeric" "$WORK/expected" || return 1
  arm_probe sem_arms_named_free_out_of_range pair > "$WORK/named-free-range" || return $?
  printf '%s\n' 'arms=0 cover=false' > "$WORK/expected"
  cmp -s "$WORK/named-free-range" "$WORK/expected" || return 1
  oracle_result sem_arms_named_free_out_of_range "$WORK/named-free-range-oracle" refuse "expected argument 'second' to 'pair' to be Int32, not Int64" || return $?
  arm_probe sem_arms_named_numeric_union pick parents binding > "$WORK/named-numeric-union" || return $?
  printf '%s\n' 'arms=2 cover=true' 'main#pick:' 'named=Int32,Int64' 'main#pick:' 'named=Bool,Int64' > "$WORK/expected"
  cmp -s "$WORK/named-numeric-union" "$WORK/expected" || return 1
  arm_probe sem_arms_numeric_union pick > "$WORK/numeric-union" || return $?
  printf '%s\n' 'arms=2 cover=true' 'main#pick:Int32,Int64' 'main#pick:Bool,Int64' > "$WORK/expected"
  cmp -s "$WORK/numeric-union" "$WORK/expected" || return 1
  arm_probe sem_arms_named_numeric_partial pick parents binding > "$WORK/named-numeric-partial" || return $?
  printf '%s\n' 'arms=1 cover=false' 'main#pick:' 'named=Int32,Int64' > "$WORK/expected"
  cmp -s "$WORK/named-numeric-partial" "$WORK/expected" || return 1
  oracle_result sem_arms_named_numeric_union "$WORK/named-numeric-union-oracle" accept 7 || return $?
  oracle_result sem_arms_named_numeric_partial "$WORK/named-numeric-partial-oracle" refuse "expected argument 'value' to 'pick' to be Int32" || return $?
  for kind in ambiguous later; do
    arm_probe "sem_arms_named_numeric_${kind}" widen > "$WORK/named-numeric-$kind" || return $?
    printf '%s\n' 'arms=0 cover=false' 'error=ambiguous call, implicit cast of 1 matches all of Int64, UInt64' > "$WORK/expected"
    cmp -s "$WORK/named-numeric-$kind" "$WORK/expected" || return 1
  done
}

if ! (set -x; check_arms_impl) 2>"$WORK/arms.trace"; then
  echo "FAIL: argument arms baseline"
  tail -20 "$WORK/arms.trace"
  for evidence in "$WORK"/*; do
    case "$evidence" in "$WORK/probe$EXE"|"$WORK/probe.dwarf"|"$WORK/arms.trace") continue ;; esac
    if [ -f "$evidence" ]; then
      echo "  --- $(basename "$evidence")"
      cat "$evidence"
    fi
  done
  exit 1
fi

# Mutation callbacks distinguish an observable mismatch from an invalid proof.
check_arms() {
  check_arms_impl
}

arm_probe sem_arms_proc_call call prelude > "$WORK/proc" || { echo "FAIL: proc call probe"; exit 1; }
printf '%s\n' 'arms=1 cover=true' 'Proc#call:' > "$WORK/expected"
cmp -s "$WORK/proc" "$WORK/expected" || { echo "FAIL: proc call arms"; diff -u "$WORK/expected" "$WORK/proc"; exit 1; }
arm_probe lowcall_capture_none call prelude-instances > "$WORK/captured-proc" || { echo "FAIL: captured proc probe"; exit 1; }
cmp -s "$WORK/captured-proc" "$WORK/expected" || { echo "FAIL: captured proc arms"; diff -u "$WORK/expected" "$WORK/captured-proc"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/compiler$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/compiler-build.log" 2>&1 || { echo "FAIL: typed compiler build"; cat "$WORK/compiler-build.log"; exit 1; }
if [ "$HOST_OS" = darwin ]; then
  codesign -v --strict "$WORK/compiler$EXE" || { echo "FAIL: typed compiler signature"; exit 1; }
else
  host_limited "argument arms: codesign verification requires Darwin"
fi
if ! IYI_ARGDISPATCH_TRACE=1 "$WORK/compiler$EXE" "$REPO_NATIVE/bench/fixtures/sem_arms_nil_eq.iyi" \
  -o "$WORK_NATIVE/nil.ir" --pipeline typed --prelude --probe-phase --emit ir > "$WORK/nil.log" 2>&1 ||
   [ ! -s "$WORK/nil.ir" ] || ! grep -Fxq '[phase] verify: pass' "$WORK/nil.log" ||
   ! grep -Fq 'targets=String#==(String);Reference#==(String);Object#==((String | Nil))' "$WORK/nil.log"; then
  echo "FAIL: nil dispatch did not produce verified IR with the expected targets"
  cat "$WORK/nil.log"
  exit 1
fi
if [ "$HOST_ID" = darwin-arm64 ]; then
  if ! "$WORK/compiler$EXE" "$REPO_NATIVE/bench/fixtures/sem_arms_nil_eq.iyi" \
    -o "$WORK_NATIVE/nil$EXE" --pipeline typed --prelude --probe-phase > "$WORK/nil-native.log" 2>&1 ||
     ! grep -Fxq '[phase] link: pass' "$WORK/nil-native.log" || ! codesign -v --strict "$WORK/nil$EXE" ||
     ! "$WORK/nil$EXE" > "$WORK/nil-run.log" 2>&1 || ! grep -Fxq true "$WORK/nil-run.log"; then
    echo "FAIL: native nil dispatch build or execution"
    cat "$WORK/nil-native.log"
    [ ! -f "$WORK/nil-run.log" ] || cat "$WORK/nil-run.log"
    exit 1
  fi
else
  host_limited "argument arms: native nil dispatch linking and execution require Darwin arm64"
fi
path_rc=0
IYI_ARGDISPATCH_TRACE=1 "$WORK/compiler$EXE" "$REPO_NATIVE/bench/fixtures/sem_arms_path_join.iyi" \
  -o "$WORK_NATIVE/path.ir" --pipeline typed --prelude --probe-phase --keep-going --emit ir > "$WORK/path.log" 2>&1 || path_rc=$?
if ! grep -Fxq '[phase] bodies: pass' "$WORK/path.log" ||
   ! grep -Fq 'targets=Std::Path::Path#join(String);Std::Path::Path#join(Std::Path::Path)' "$WORK/path.log"; then
  echo "FAIL: path dispatch did not reach the expected typed targets (status $path_rc)"
  cat "$WORK/path.log"
  exit 1
fi
if [ "$path_rc" -eq 0 ]; then
  if [ ! -s "$WORK/path.ir" ] || ! grep -Fxq '[phase] verify: pass' "$WORK/path.log"; then
    echo "FAIL: path dispatch produced no verified IR"
    cat "$WORK/path.log"
    exit 1
  fi
elif [ "$path_rc" -eq 1 ] &&
     grep -Fq 'lower: fail: lower: visit(a class method call on Std::Path::Path::Kind.class' "$WORK/path.log" &&
     grep -Fxq 'reached: bodies' "$WORK/path.log"; then
  echo "  path dispatch passed body typing; the compiler refused later lowering:"
  awk '/^lower: fail:/{show=1} show {print}' "$WORK/path.log"
else
  echo "FAIL: path dispatch compiler exited unexpectedly (status $path_rc)"
  cat "$WORK/path.log"
  exit 1
fi
status=0
prove_mutation 'cover requires a matching arm for each combination' "$REPO/src/compiler/semantic/cover.iyi" \
  '        return true if accepted' '        return false if accepted' -- check_arms || status=1
prove_mutation 'stricter overload is inserted before broader overload' "$REPO/src/compiler/semantic/top_level.iyi" \
  '            break if DeclarationOrder.before?(a_def, l[at], self, yields)' \
  '            break if false && DeclarationOrder.before?(a_def, l[at], self, yields)' -- check_arms || status=1
prove_mutation 'generic metaclass restrictions use the bound instance' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '          match_owner = instance if instance.is_a?(GenericInstanceType)' \
  '          match_owner = owner if instance.is_a?(GenericInstanceType)' -- check_arms || status=1
prove_mutation 'generic match retains its metaclass owner' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '            arm = Match.new(match.definition, match.arg_types, owner, match.defining, match.exact, match.named_arg_types, match.declared, match.bound)' \
  '            arm = match' -- check_arms || status=1
prove_mutation 'named argument types participate in matching' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      named_types = collected' \
  '      named_types = nil' -- check_arms || status=1
prove_mutation 'module-only walk does not search the superclass' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      return Matches.new(matches, CallCover.all?(signature, matches)) if walk == ArmWalk::Modules && matches.size > level_start' \
  '      return Matches.new(matches, CallCover.all?(signature, matches)) if false' -- check_arms || status=1
prove_mutation 'unmatched numeric calls receive an autocast pass' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '    unless NumericAutocast.any?(args, arg_types) || NumericAutocast.any?(named_nodes, named_arg_types)' \
  '    unless false' -- check_arms || status=1
prove_mutation 'unresolved restrictions are reported only when no arm matches' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '    return Matches.new(matches, false, first_error) if matches.empty? && first_error' \
  '    return Matches.new(matches, false, first_error) if first_error' -- check_arms || status=1
prove_mutation 'autocast compares every viable overload' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '          return Matches.new(matches, true) if arm.exact && signature.autocast_nodes.nil?' \
  '          return Matches.new(matches, true) if arm.exact' -- check_arms || status=1
prove_mutation 'multiple union arms with the same numeric cast are not ambiguous' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      if error = arm_autocast_ambiguity(widened.matches, args, named_nodes)' \
  '      if error = arm_autocast_ambiguity(widened.matches, args, named_nodes) || "ambiguity"' -- check_arms || status=1
prove_mutation 'widened calls preserve coverage of every union member' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      return Matches.new(widened.matches, cover)' \
  '      return Matches.new(widened.matches, true)' -- check_arms || status=1
prove_mutation 'positional widened types are used for coverage' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '        type = matches[0].arg_types[i]' \
  '        type = signature.arg_types[i]' -- check_arms || status=1
prove_mutation 'named widened types are used for coverage' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '          type = matches[0].named_arg_types[i].type' \
  '          type = named[i].type' -- check_arms || status=1
prove_mutation 'autocast stops after the first matching owner level' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      if signature.autocast_nodes && matches.size > level_start' \
  '      if false' -- check_arms || status=1
prove_mutation 'a supplied block can bind free names in its output' "$REPO/src/compiler/semantic/match.iyi" \
  '                    deferred = FreeBindings.mentions?(output, [free_names[j]])' \
  '                    deferred = false' -- check_arms || status=1
prove_mutation 'bare splats allow named-only trailing parameters' "$REPO/src/compiler/semantic/match.iyi" \
  '      if count > k + 1 && !definition.args[k].name.empty?' \
  '      if count > k + 1' -- check_arms || status=1
prove_mutation 'bare splats reject excess positional arguments' "$REPO/src/compiler/semantic/match.iyi" \
  '    if splat && definition.args[splat.as(Int32)].name.empty? && given > prefix' \
  '    if false' -- check_arms || status=1
prove_mutation 'named restrictions order overloads by specificity' "$REPO/src/compiler/semantic/top_level.iyi" \
  '          if br = b.restriction
            return false unless restriction_of?(ar, br, owner, first.free_vars, second.free_vars)
          end' \
  '          if br = b.restriction
            nil
          end' -- check_arms || status=1
prove_mutation 'named restrictions bind previously unbound type variables' "$REPO/src/compiler/semantic/match.iyi" \
  '              return MatchAttempt.none unless FreeBindings.bind(restriction, named_arg.type, unbound, bound)' \
  '              nil' -- check_arms || status=1
prove_mutation 'named numeric nodes participate in the autocast pass' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '    signature.named_autocast_nodes = named_nodes' \
  '    signature.named_autocast_nodes = nil' -- check_arms || status=1
prove_mutation 'named autocast selects the differing argument for ambiguity' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      if names.size > 1 && NumericAutocast.supports?(named_nodes[i], type_of(named_nodes[i]))' \
  '      if false' -- check_arms || status=1
exit "$status"
