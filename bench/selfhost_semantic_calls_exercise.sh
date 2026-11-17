#!/usr/bin/env bash
# Fails when the iyi call lookup stops agreeing with the hosted call pass.
#
# Each fixture (bench/fixtures/semcall_*.iyi) declares methods and lists call
# sites: `# call <expr>` lines are the hosted lookup's matches, and `# error <expr>`
# lines are the first line of the error the hosted compile raises for the call
# (or ok). The hosted oracle (bench/selfhost_semantic_calls_oracle.cr) and the
# port's driver (bench/selfhost_semantic_calls_exercise.iyi) each print one line
# per site, `<expr> => <result>`, and the two outputs must be byte-identical.
#
# Mutation proofs patch the ported code, rebuild the driver, and require the
# gate to fail. A patch that changes nothing is refused by prove_mutation.
#
#   bash bench/selfhost_semantic_calls_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")"
export IYI_PATH="$REPO_NATIVE/src"
METHOD_FILE="$REPO/src/compiler/semantic/method_lookup.iyi"
IYI="$REPO/bin/iyi"
HOSTED_COMPILER="$REPO/bin/crystal"
LOOKUP_FILE="$REPO/src/compiler/semantic/method_lookup.iyi"
MATCH_FILE="$REPO/src/compiler/semantic/match.iyi"
CALL_FILE="$REPO/src/compiler/semantic/call.iyi"
ERROR_FILE="$REPO/src/compiler/semantic/call_error.iyi"
DEFAULT_FILE="$REPO/src/compiler/semantic/default_arguments.iyi"
LIB_FILE="$REPO/src/compiler/semantic/lib_call.iyi"
RESTRICT_FILE="$REPO/src/compiler/semantic/restrictions.iyi"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")"
trap 'rm -rf "$WORK"' EXIT

. "$REPO/bench/lib/mutation.sh"

echo "== 1. Building the hosted oracle and the port driver"
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing \
    -o "$WORK_NATIVE/oracle$EXE" "$REPO_NATIVE/bench/selfhost_semantic_calls_oracle.cr" || { echo "oracle build failed"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/port$EXE" "$REPO_NATIVE/bench/selfhost_semantic_calls_exercise.iyi" || { echo "port driver build failed"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/tuple_cache$EXE" "$REPO_NATIVE/bench/selfhost_tuple_index_cache_exercise.iyi" || { echo "tuple cache driver build failed"; exit 1; }
"$WORK/tuple_cache$EXE" || { echo "tuple cache behavior failed"; exit 1; }

echo
echo "== 2. Each fixture's call sites, hosted oracle against the port"
fixture_count=0
total_calls=0
for fixture in "$REPO"/bench/fixtures/semcall_*.iyi; do
  fixture_name="bench/fixtures/$(basename "$fixture")"
  "$WORK/port$EXE" "$(native_path "$fixture")" > "$WORK/port.out" 2>"$WORK/port.err" || {
    echo "  $fixture_name: port driver failed: $(awk 'NR==1' "$WORK/port.err")"
    status=1
    continue
  }
  "$WORK/oracle$EXE" "$(native_path "$fixture")" > "$WORK/oracle.out" 2>"$WORK/oracle.err" || {
    echo "  $fixture_name: hosted oracle failed: $(awk 'NR==1' "$WORK/oracle.err")"
    status=1
    continue
  }
  if diff -u "$WORK/oracle.out" "$WORK/port.out" > "$WORK/diff.out"; then
    calls=$(awk 'END { print NR }' "$WORK/oracle.out")
    echo "  $fixture_name: identical ($calls call sites)"
    fixture_count=$((fixture_count + 1))
    total_calls=$((total_calls + calls))
  else
    echo "  $fixture_name: DIVERGED from the hosted oracle"
    cat "$WORK/diff.out"
    status=1
  fi
done
echo "  Parity summary: $fixture_count fixtures identical ($total_calls call sites compared)"
if [ "$fixture_count" -eq 0 ]; then
  echo "  no fixtures compared: this proves nothing"
  status=1
fi

echo
echo "== 3. Guarded mutation proofs (patch, rebuild, the gate must fail)"
MUTATIONS_RUN=0

# Rebuild the driver from the patched source and compare the fixtures. A build
# failure is not a behavioral catch.
check_calls_diverge() {
  if ! "$IYI" build -o "$WORK_NATIVE/port_m$EXE" "$REPO_NATIVE/bench/selfhost_semantic_calls_exercise.iyi" >"$WORK/mutation-build.log" 2>&1; then
    echo "INVALID MUTANT: call driver failed to build"
    cat "$WORK/mutation-build.log"
    return 0
  fi
  local fixture rc
  for fixture in "$REPO"/bench/fixtures/semcall_*.iyi; do
    if [ "$#" -gt 0 ] && [ "$fixture" != "$REPO/$1" ]; then
      continue
    fi
    "$WORK/port_m$EXE" "$(native_path "$fixture")" > "$WORK/pm.out" 2>"$WORK/pm.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "INVALID MUTANT: call driver died on $(basename "$fixture"): $(refusal_note "$rc" "$WORK/pm.err")"
      return 0
    fi
    "$WORK/oracle$EXE" "$(native_path "$fixture")" > "$WORK/om.out" 2>"$WORK/om.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "INVALID MUTANT: call oracle failed on $(basename "$fixture"): $(refusal_note "$rc" "$WORK/om.err")"
      return 0
    fi
    cmp -s "$WORK/pm.out" "$WORK/om.out"
    rc=$?
    case "$rc" in
      0) ;;
      1)
        echo "decisive: $(basename "$fixture"): the call sites differ from the oracle's"
        return 1
        ;;
      *)
        echo "INVALID MUTANT: call output comparison failed on $(basename "$fixture") (exit $rc)"
        return 0
        ;;
    esac
  done
  return 0
}

check_forward_lookup_diverge() {
  if ! "$IYI" build -o "$WORK_NATIVE/port_m$EXE" "$REPO_NATIVE/bench/selfhost_semantic_calls_exercise.iyi" >/dev/null 2>&1; then
    echo "INVALID MUTANT: call driver failed to build"
    return 0
  fi
  local fixture="$REPO/bench/fixtures/semcall_forward_order.iyi"
  "$WORK/oracle$EXE" "$(native_path "$fixture")" > "$WORK/forward_o.out" 2>/dev/null || return 0
  "$WORK/port$EXE" "$(native_path "$fixture")" > "$WORK/forward_p.out" 2>/dev/null || return 0
  cmp -s "$WORK/forward_o.out" "$WORK/forward_p.out" || return 0
  "$WORK/port_m$EXE" "$(native_path "$fixture")" > "$WORK/forward_m.out" 2>/dev/null || return 0
  grep -Fq 'lookup_choose(LookupValue) -> String' "$WORK/forward_o.out" || return 0
  grep -Fq 'lookup_choose(LookupSpecific) -> Int32' "$WORK/forward_m.out" || return 0
  cmp -s "$WORK/forward_o.out" "$WORK/forward_m.out"
}

# The ordinary lookup uses declaration-time ordering. Require both drivers to
# run and the baseline to agree before accepting this specific wrong target.
check_specificity_diverge() {
  local fixture="$REPO/bench/fixtures/semcall_overloads.iyi"
  if ! "$IYI" build -o "$WORK_NATIVE/port_m$EXE" "$REPO_NATIVE/bench/selfhost_semantic_calls_exercise.iyi" >"$WORK/specificity-build.log" 2>&1; then
    echo "INVALID MUTANT: call driver failed to build"
    cat "$WORK/specificity-build.log"
    return 0
  fi
  if ! "$WORK/oracle$EXE" "$(native_path "$fixture")" > "$WORK/specificity-oracle.out" 2>"$WORK/specificity-oracle.err" ||
     ! "$WORK/port$EXE" "$(native_path "$fixture")" > "$WORK/specificity-port.out" 2>"$WORK/specificity-port.err" ||
     ! "$WORK/port_m$EXE" "$(native_path "$fixture")" > "$WORK/specificity-mutant.out" 2>"$WORK/specificity-mutant.err"; then
    echo "specificity fixture did not run, not a behavioral catch"
    for log in "$WORK"/specificity-*.err; do [ ! -f "$log" ] || cat "$log"; done
    return 0
  fi
  if ! cmp -s "$WORK/specificity-oracle.out" "$WORK/specificity-port.out"; then
    echo "unmutated port did not match the hosted oracle"
    diff -u "$WORK/specificity-oracle.out" "$WORK/specificity-port.out"
    return 0
  fi
  if ! grep -F 'identify(instance(Dog)) =>' "$WORK/specificity-oracle.out" > "$WORK/specificity-expected" ||
     ! grep -Fq 'identify(Dog) -> String' "$WORK/specificity-expected" ||
     ! grep -F 'identify(instance(Dog)) =>' "$WORK/specificity-mutant.out" > "$WORK/specificity-actual" ||
     ! grep -Fq 'identify(Animal) -> String' "$WORK/specificity-actual"; then
    echo "mutation did not select the broad overload for the Dog call"
    cat "$WORK/specificity-oracle.out" "$WORK/specificity-mutant.out"
    return 0
  fi
  cmp -s "$WORK/specificity-oracle.out" "$WORK/specificity-mutant.out"
}
check_tuple_cache_mutation() {
  "$IYI" build -o "$WORK_NATIVE/tuple_cache_m$EXE" "$REPO_NATIVE/bench/selfhost_tuple_index_cache_exercise.iyi" >/dev/null 2>&1 || {
    echo "    INVALID MUTANT: call driver failed to build"
    return 0
  }
  if "$WORK/tuple_cache_m$EXE" >"$WORK/tuple-cache-mutant.log" 2>&1; then
    return 0
  fi
  if grep -Eq 'scalar and singleton range share a target|scalar marked as range|singleton range lost|empty range lost|scalar cache miss|range cache miss|dynamic index specialized|nilable out-of-bounds is not nil' "$WORK/tuple-cache-mutant.log"; then
    return 1
  fi
  echo "INVALID MUTANT: tuple cache driver failed without an expected assertion"
  cat "$WORK/tuple-cache-mutant.log"
  return 0
}

prove_mutation "singleton range shares the scalar cache entry" "$CALL_FILE" \
  '    cache_key = "#{meta}:#{first}:#{last}:#{is_range}"' \
  '    cache_key = "#{meta}:#{first}:#{last}"' \
  -- check_tuple_cache_mutation || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a range index loses its range discriminator" "$CALL_FILE" \
  '        is_range = true' \
  '        is_range = false' \
  -- check_tuple_cache_mutation || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))



prove_mutation "exact match does not end the lookup" "$LOOKUP_FILE" \
  "    return own if own.cover_all? || own.error" \
  "    return own if own.error" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a first exact call match does not stop lookup" "$METHOD_FILE" \
  '      if signature.autocast_nodes.nil? && match.as(Match).exact' \
  '      if false && signature.autocast_nodes.nil? && match.as(Match).exact' \
  -- check_forward_lookup_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "arguments beyond the def's parameters are accepted" "$MATCH_FILE" \
  "    return MatchAttempt.none if !splat && given > count" \
  "    return MatchAttempt.none if false" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "restrictions are not applied to arguments" "$MATCH_FILE" \
  "        restricted = ts.restrict(arg_type, allowed.as(Type))" \
  "        restricted = arg_type" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "missing arguments without a default are accepted" "$MATCH_FILE" \
  "      if !is_splat && !mandatory[k] && definition.args[k].default_value.nil?" \
  "      if false" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "parent types are not searched for methods" "$LOOKUP_FILE" \
  "      found = lookup_matches(parent.as(ModuleType), ts, signature, owner, parent.as(ModuleType), all)" \
  "      found = Matches.new(all, false)" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a type path as receiver resolves to its instance, not its metaclass" "$CALL_FILE" \
  "    scoped.as(ModuleType).metaclass" \
  "    scoped.as(ModuleType)" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "undefined method names a program's calls by the program, not top-level" "$ERROR_FILE" \
  "? \"top-level\" : owner.to_s" \
  "? \"program\" : owner.to_s" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "undefined method text loses its quotes" "$ERROR_FILE" \
  "\"undefined method '#{name}' for #{owner_name}\"" \
  "\"undefined method #{name} for #{owner_name}\"" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a consecutive range of expected sizes is printed as a list" "$ERROR_FILE" \
  "    if sizes.size > 1 && sizes[sizes.size - 1] - sizes[0] == sizes.size - 1" \
  "    if false" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a def that yields accepts a call without a block" "$MATCH_FILE" \
  "    if CallMatch.yields?(definition) != signature.block" \
  "    if false" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a named argument may repeat a positional one" "$MATCH_FILE" \
  "        return MatchAttempt.none if mandatory[index]" \
  "        return MatchAttempt.none if false" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "new does not match the initialize overloads of its class" "$LOOKUP_FILE" \
  "    return recorded.as(Array(Def)) if recorded" \
  "    return nil if recorded" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "an argument-type message is given even when the overloads disagree on the argument" "$ERROR_FILE" \
  "        chosen = candidate if every" \
  "        chosen = candidate if false" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "recalculate reports a unique target as an error" "$CALL_FILE" \
  "    if matches.matches.size == 1" \
  "    if matches.matches.size == 9" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a virtual receiver does not reach its subtypes" "$METHOD_FILE" \
  "    receiver.subtypes.each do |sub|" \
  "    ([] of Type).each do |sub|" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a subtype's matches do not go ahead of the base's" "$METHOD_FILE" \
  "        matches.each do |m|" \
  "        ([] of Match).each do |m|" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a union receiver drops the matches of its members" "$METHOD_FILE" \
  "        found.matches.each do |m|" \
  "        ([] of Match).each do |m|" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a virtual receiver answers covered when it has matches" "$METHOD_FILE" \
  "    Matches.new(matches, !matches.empty?)" \
  "    Matches.new(matches, false)" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a splat parameter takes none of the arguments past its prefix" "$MATCH_FILE" \
  "        matched << element" \
  "        matched << element if false" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a double splat does not take the names no parameter has" "$MATCH_FILE" \
  "          return MatchAttempt.none if !dsplat" \
  "          return MatchAttempt.none if true" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a def with a block argument does not yield" "$MATCH_FILE" \
  "    return true if definition.block_arg" \
  "    return false if definition.block_arg" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

if prove_mutation "the less specific of two overloads is chosen" "$REPO/src/compiler/semantic/top_level.iyi" \
  '            break if DeclarationOrder.before?(a_def, l[at], self, yields)' \
  '            break if false && DeclarationOrder.before?(a_def, l[at], self, yields)' \
  -- check_specificity_diverge; then
  printf '      hosted: '; cat "$WORK/specificity-expected"
  printf '      mutated: '; cat "$WORK/specificity-actual"
else
  status=1
fi
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a private method called with an explicit receiver is allowed" "$CALL_FILE" \
  "      if explicit && !synthetic && single.definition.visibility == Visibility::Private" \
  "      if false" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a trait receiver is looked up over the wrong implementers" "$LOOKUP_FILE" \
  "      targets << rec.target_type if rec.trait_type == trait_type" \
  "      targets << rec.target_type if rec.trait_type != trait_type" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "trait implementers are walked in declaration order, not by name" "$LOOKUP_FILE" \
  "    sorted = sorted_by_name(targets)" \
  "    sorted = targets" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a missing parameter takes the first argument, not its default" "$DEFAULT_FILE" \
  "out << default.clone" \
  "out << (args.empty? ? default.clone : args[0])" \
  -- check_calls_diverge bench/fixtures/semcall_default.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a named argument is ignored when a default is expanded" "$DEFAULT_FILE" \
  "named = DefaultArguments.named_value(named_args, rec_def.args[k].external_name)" \
  "named = rec_def.args[k].default_value ? nil : DefaultArguments.named_value(named_args, rec_def.args[k].external_name)" \
  -- check_calls_diverge bench/fixtures/semcall_default.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a given positional argument is replaced by its default" "$DEFAULT_FILE" \
  "out << args[k]" \
  "out << args[args.size - 1]" \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a lib fun's owner is written with a dot, not a hash" "$LIB_FILE" \
  '    target = LibCall.recalculate_fun(found.as(LibFun), "#{target_lib.full_name}##{name}", prog, ts, args)' \
  '    target = LibCall.recalculate_fun(found.as(LibFun), "#{target_lib.full_name}.#{name}", prog, ts, args)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a missing named argument of a lib call is not reported" "$LIB_FILE" \
  '      return LibCallTarget.failed("missing argument: #{missing[0]}") if missing.size == 1' \
  '      return LibCallTarget.failed("missing argument: #{missing[0]}") if missing.size == 7' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a fixed lib fun takes extra arguments as if it were variadic" "$LIB_FILE" \
  '    if count < lib_fun.args.size || (!lib_fun.varargs? && count > lib_fun.args.size)' \
  '    if count < lib_fun.args.size || (false && count > lib_fun.args.size)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a wrapper for a magic-constant default is built anyway" "$DEFAULT_FILE" \
  '      return nil if DefaultArguments.all_magic_from?(rec_def, given)' \
  '      return nil if false && DefaultArguments.all_magic_from?(rec_def, given)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a wrapper for a named argument drops the argument's name" "$DEFAULT_FILE" \
  '        new_name = "#{new_name}:#{named.name}"
        matching = rec_def.args[DefaultArguments.param_index(rec_def, named.name)]' \
  '        new_name = "#{new_name}"
        matching = rec_def.args[DefaultArguments.param_index(rec_def, named.name)]' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a wrapper forwards to its own name, not the def's" "$DEFAULT_FILE" \
  '      forwarding = Call.new(nil, rec_def.name, call_args)' \
  '      forwarding = Call.new(nil, new_name, call_args)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a yielding def forwards its defaults" "$DEFAULT_FILE" \
  '    retain = CallMatch.yields?(rec_def) || rec_def.macro_def' \
  '    retain = rec_def.macro_def' \
  -- check_calls_diverge bench/fixtures/semcall_default_wrapper.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a def with a restricted default is not kept whole" "$DEFAULT_FILE" \
  '      retain = true if arg.default_value && arg.restriction' \
  '      retain = true if false && arg.default_value && arg.restriction' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a call whose named arguments cover the defaults in order gets a wrapper" "$DEFAULT_FILE" \
  '      if given + named_args.size == count && DefaultArguments.named_in_order?(rec_def, given, named_args)' \
  '      if false && given + named_args.size == count && DefaultArguments.named_in_order?(rec_def, given, named_args)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a free variable is not bound from the argument that names it" "$RESTRICT_FILE" \
  '        bound[names[0]] = arg_type' \
  '        bound[names[0]] = arg_type if false' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a return type is resolved without the bound free variables" "$CALL_FILE" \
  'ret.as(ASTNode), rec_type, single.bound)' \
  'ret.as(ASTNode), rec_type, Hash(String, Type).new)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "an unbound free variable is not refused" "$MATCH_FILE" \
  '          return MatchAttempt.failed("undefined constant #{free_names[j]}") unless deferred' \
  '          return MatchAttempt.failed("undefined constant #{free_names[j]}") if false' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a generic restriction with bound arguments is a class instance, not instantiated through TypeLookup" "$RESTRICT_FILE" \
  '          return TypeLookup.new(ts.instances).instantiate(base_type, args)' \
  '          return ts.instantiate_generic(base_type.as(GenericClassType), args)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "restore the early return" "$LOOKUP_FILE" \
  '        first_error = err if first_error.nil?' \
  '        return Matches.new(matches_array, false, err)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a splat free variable is not bound to the splat tuple" "$RESTRICT_FILE" \
  '        return nil if !FreeBindings.bind(splat_restriction.as(Splat).exp, splat_tuple, free, bound)' \
  '        return nil if false' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a typed integer is not matched when its range fits a wider integer" "$MATCH_FILE" \
  '      return NumericAutocast.range_subset?(type, target)' \
  '      return false' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a number literal is not matched when its value fits" "$MATCH_FILE" \
  '      return NumericAutocast.value_fits?(node.as(NumberLiteral), target)' \
  '      return false' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "an inherited method's target forgets the type it was found on" "$CALL_FILE" \
  'return CallTarget.new(single.definition, rec_type, instantiated, false, nil, single.defining, single.arg_types, nil)' \
  'return CallTarget.new(single.definition, rec_type, instantiated, false, nil, nil, single.arg_types, nil)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "instantiated argument types are the written restrictions" "$CALL_FILE" \
  'return CallTarget.new(single.definition, rec_type, instantiated, false, nil, single.defining, single.arg_types, nil)' \
  'return CallTarget.new(single.definition, rec_type, instantiated, false, nil, single.defining, single.declared, nil)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "declared return is mistaken for the inferred body return" "$CALL_FILE" \
  'return CallTarget.new(single.definition, rec_type, instantiated, false, nil, single.defining, single.arg_types, nil)' \
  'return CallTarget.new(single.definition, rec_type, instantiated, false, nil, single.defining, single.arg_types, instantiated)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a named splat is counted as a required positional argument" "$ERROR_FILE" \
  '      minimum = splat if splat < minimum' \
  '      minimum = d.args.size' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a virtual dispatch target loses its defining owner" "$CALL_FILE" \
  'targets << CallTarget.new(match.definition, match.owner, found.as(Type), false, nil, match.defining, match.arg_types, nil)' \
  'targets << CallTarget.new(match.definition, match.owner, found.as(Type), false, nil, nil, match.arg_types, nil)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a tuple literal index uses the wrong member" "$CALL_FILE" \
  '    body : ASTNode = first == -1 ? NilLiteral.new : Primitive.tuple_indexer(first, last, is_range)' \
  '    body : ASTNode = first == -1 ? NilLiteral.new : Primitive.tuple_indexer(0, 0, is_range)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "default expansion returns the unexpanded definition" "$DEFAULT_FILE" \
  '    expansion.nil? ? rec_def : expansion.as(Def)' \
  '    rec_def' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# matching lane (match.iyi, restrictions.iyi)
prove_mutation "a generic restriction does not bind free vars from the instance type arguments" "$RESTRICT_FILE" \
  '    return RestrictResult.no_match if base_type.full_name != inst.generic_type.full_name' \
  '    return RestrictResult.no_match if true' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a generic owner's type parameter is not bound in a pointer restriction" "$RESTRICT_FILE" \
  '          bound = instance.type_vars[names[0]]?' \
  '          bound = nil' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a Proc does not bind its argument tuple as T" "$REPO/src/compiler/types/types.iyi" \
  '    vars["T"] = TupleInstanceType.new(program, @arg_types)' \
  '    vars["T"] = TupleInstanceType.new(program, [] of Type)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a generic owner's superclass restriction rejects subclasses" "$MATCH_FILE" \
  '        restricted = ts.restrict(arg_type, allowed.as(Type))' \
  '        restricted = arg_type == allowed.as(Type) ? arg_type : nil' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a typed integer expression is not eligible for autocast" "$MATCH_FILE" \
  '    bits = NumericAutocast.integer_bits(type)' \
  '    return false if node.is_a?(Call) && node.as(Call).obj'$'\n''    bits = NumericAutocast.integer_bits(type)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a union restriction drops its generic member" "$RESTRICT_FILE" \
  '      members << member.as(Type)' \
  '      members << member.as(Type) unless member.as(Type).is_a?(GenericInstanceType)' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a nilable restriction drops Nil" "$RESTRICT_FILE" \
  '      members << member.as(Type)' \
  '      members << member.as(Type) unless member.as(Type).full_name == "Nil"' \
  -- check_calls_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "an imported type is not found during restriction lookup" "$REPO/src/compiler/types/lookup.iyi" \
  '        curr = program.current_imports[name]?' \
  '        curr = nil' \
  -- check_calls_diverge bench/fixtures/semcall_match_import.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "SELFHOST SEMANTIC CALLS GATE PASSED"
else
  echo "SELFHOST SEMANTIC CALLS GATE FAILED"
fi
exit "$status"
