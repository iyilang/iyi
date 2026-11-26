#!/usr/bin/env bash
# Compare both entry expressions and reachable specialized method bodies with
# the hosted semantic pass. The ordinary typed oracle walks uninstantiated Defs,
# so the body oracle follows Call#target_defs and the port walks typed_instances.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
. "$REPO/bench/lib/mutation.sh" || exit 1
cd "$REPO" || exit 1
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE="$(native_path "$REPO")"
WORK_NATIVE="$(native_path "$WORK")"
FLOOR="$REPO/bench/selfhost_typed_bodies.floor"
EXCEPTIONS="$REPO/bench/selfhost_typed_bodies_exceptions.tsv"
IYI="$REPO/bin/iyi"
HOSTED_COMPILER="$REPO/bin/crystal"
export IYI_PATH="$REPO_NATIVE/src"
export IYI_CACHE_DIR="$WORK_NATIVE/cache"
export LC_ALL=C
llvm_bridge_text=$(llvm_bridge_build_args) || exit 1
IYI_TYPED_ORACLE_FLAGS=$(printf '%s\n' "$llvm_bridge_text" | awk '/^-D/ {sub(/^-D/, ""); printf "%s ", $0}')
IYI_TYPED_DEFINES=$(printf '%s\n' "$llvm_bridge_text" | awk '/^-D/ {printf "%s ", $0}')
export IYI_TYPED_ORACLE_FLAGS

build_host() {
  local source="$1" output="$2"
  LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
    CRYSTAL_PATH="$REPO_NATIVE/src" IYI_CONFIG_PATH="$REPO_NATIVE/src" \
    "$HOSTED_COMPILER" build -Di_know_what_im_doing -o "$WORK_NATIVE/$output$EXE" \
    "$REPO_NATIVE/bench/$source" > "$WORK/$output.build" 2>&1 || {
      echo "FAIL: hosted $output did not build"
      awk 'NR <= 50 {print}' "$WORK/$output.build"
      return 1
    }
}
build_port() {
  local source="$1" output="$2"
  "$IYI" build -o "$WORK_NATIVE/$output$EXE" "$REPO_NATIVE/$source" > "$WORK/$output.build" 2>&1 || {
    echo "FAIL: port $output did not build"
    awk 'NR <= 50 {print}' "$WORK/$output.build"
    return 1
  }
}

echo '== 1. Building hosted and port entry, body and type-query drivers'
build_host selfhost_typed_oracle.cr entry-oracle || exit 1
build_host selfhost_typed_bodies_oracle.cr body-oracle || exit 1
build_host selfhost_semantic_types_oracle.cr types-oracle || exit 1
build_port src/compiler/tools/typed_dump.iyi entry-port || exit 1
build_port bench/fixtures/typed_bodies_dump.iyi body-port || exit 1
build_port bench/selfhost_semantic_types_exercise.iyi types-port || exit 1
echo '  built: three hosted oracles and three port drivers'

# The inventory must cover each fixture exactly once. Adding or removing a
# fixture, duplicating a row, or silently dropping a failing oracle is an error.
for fixture in "$REPO"/bench/fixtures/sem_bodies_*.iyi "$REPO"/bench/fixtures/sem_arms_*.iyi; do
  [ -f "$fixture" ] || { echo "FAIL: missing fixture family: $fixture"; exit 1; }
  basename "$fixture"
done | sort > "$WORK/inventory"
awk -F '\t' '!/^#/ && NF {
  if (NF != 6 || ($2 != "bare" && $2 != "prelude" && $2 != "cr") ||
      $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/) {
    print "invalid floor row: " $0 > "/dev/stderr"; bad=1
  }
  print $1
} END {exit bad}' "$FLOOR" > "$WORK/floor-names" || exit 1
awk -F '\t' '!/^#/ && NF {
  if (NF != 3 || $2 == "" || $3 == "") {
    print "invalid exception row: " $0 > "/dev/stderr"; bad=1
  }
  print $1
} END {exit bad}' "$EXCEPTIONS" > "$WORK/exception-names" || exit 1
sort "$WORK/floor-names" "$WORK/exception-names" > "$WORK/listed"
if ! diff -u "$WORK/inventory" "$WORK/listed"; then
  echo 'FAIL: each fixture needs exactly one floor or documented exception'
  exit 1
fi

echo
echo '== 2. Entry and instantiated-body typed-node parity'
status=0
bodies=0
arms=0
compared=0
excluded=0
entry_nodes=0
entry_matched=0
body_nodes=0
body_matched=0
no_body=0
zero_body_matches=0
while IFS= read -r name; do
  case "$name" in sem_bodies_*) bodies=$((bodies + 1)) ;; sem_arms_*) arms=$((arms + 1)) ;; esac
  fixture="$REPO/bench/fixtures/$name"
  row=$(awk -F '\t' -v n="$name" '$1 == n {print; exit}' "$FLOOR")
  if [ -z "$row" ]; then
    expected=$(awk -F '\t' -v n="$name" '$1 == n {print $2; exit}' "$EXCEPTIONS")
    reason=$(awk -F '\t' -v n="$name" '$1 == n {print $3; exit}' "$EXCEPTIONS")
    rc=0
    "$WORK/entry-oracle$EXE" "$(native_path "$fixture")" > "$WORK/skip.out" 2> "$WORK/skip.err" || rc=$?
    if [ "$rc" -ne 2 ] || ! awk -v expected="$expected" 'index($0, expected) {found=1} END {exit !found}' "$WORK/skip.err"; then
      echo "  FAIL: $name oracle exception changed (exit $rc); expected $expected"
      awk 'NR <= 2 {print}' "$WORK/skip.err"
      status=1
    else
      echo "  excluded $name: $reason"
      excluded=$((excluded + 1))
    fi
    continue
  fi
  IFS=$'\t' read -r _ mode root_floor root_match_floor body_floor body_match_floor <<< "$row"
  oracle_flag=""
  port_flag=""
  case "$mode" in
    bare) oracle_flag=--bare ;;
    prelude) port_flag=--with-prelude ;;
    cr)
      # The existing semantic gate uses a .cr copy for the written ensure,
      # which the hosted compiler intentionally rejects in .iyi sources.
      fixture="$WORK/${name%.iyi}.cr"
      cp "$REPO/bench/fixtures/$name" "$fixture" || exit 1
      oracle_flag=--bare ;;
  esac
  native_fixture="$(native_path "$fixture")"
  if ! "$WORK/entry-oracle$EXE" $oracle_flag "$native_fixture" > "$WORK/entry.host" 2> "$WORK/entry.host.err"; then
    echo "  FAIL: entry oracle $name: $(awk 'NR==1 {print}' "$WORK/entry.host.err")"
    status=1; continue
  fi
  if ! "$WORK/entry-port$EXE" $IYI_TYPED_DEFINES $port_flag "$native_fixture" "$REPO_NATIVE/src" > "$WORK/entry.port" 2> "$WORK/entry.port.err"; then
    echo "  FAIL: entry port $name: $(awk 'NR==1 {print}' "$WORK/entry.port.err")"
    status=1; continue
  fi
  if ! "$WORK/body-oracle$EXE" $oracle_flag "$native_fixture" > "$WORK/body.host" 2> "$WORK/body.host.err"; then
    echo "  FAIL: body oracle $name: $(awk 'NR==1 {print}' "$WORK/body.host.err")"
    status=1; continue
  fi
  if ! "$WORK/body-port$EXE" $IYI_TYPED_DEFINES $port_flag "$native_fixture" "$REPO_NATIVE/src" > "$WORK/body.port" 2> "$WORK/body.port.err"; then
    echo "  FAIL: body port $name: $(awk 'NR==1 {print}' "$WORK/body.port.err")"
    status=1; continue
  fi
  sort "$WORK/entry.host" > "$WORK/host.sorted"
  sort "$WORK/entry.port" > "$WORK/port.sorted"
  rn=$(wc -l < "$WORK/host.sorted" | tr -d ' ')
  rm=$(comm -12 "$WORK/host.sorted" "$WORK/port.sorted" | wc -l | tr -d ' ')
  sort "$WORK/body.host" > "$WORK/host.sorted"
  sort "$WORK/body.port" > "$WORK/port.sorted"
  bn=$(wc -l < "$WORK/host.sorted" | tr -d ' ')
  bm=$(comm -12 "$WORK/host.sorted" "$WORK/port.sorted" | wc -l | tr -d ' ')
  printf '  %-48s %-7s entry %s/%s (floor %s/%s) body %s/%s (floor %s/%s)\n' \
    "$name" "$mode" "$rm" "$rn" "$root_match_floor" "$root_floor" "$bm" "$bn" "$body_match_floor" "$body_floor"
  if [ "$rn" -lt "$root_floor" ] || [ "$rm" -lt "$root_match_floor" ] || \
     [ "$bn" -lt "$body_floor" ] || [ "$bm" -lt "$body_match_floor" ]; then
    echo "  BELOW FLOOR: $name"
    status=1
  fi
  compared=$((compared + 1))
  entry_nodes=$((entry_nodes + rn)); entry_matched=$((entry_matched + rm))
  body_nodes=$((body_nodes + bn)); body_matched=$((body_matched + bm))
  [ "$bn" -eq 0 ] && no_body=$((no_body + 1))
  [ "$bm" -eq 0 ] && zero_body_matches=$((zero_body_matches + 1))
done < "$WORK/inventory"
echo "  fixtures: $bodies sem_bodies, $arms sem_arms; $compared compared, $excluded documented oracle refusals"
echo "  entry nodes: $entry_matched matched of $entry_nodes hosted"
echo "  instantiated body nodes: $body_matched matched of $body_nodes hosted; $no_body fixtures have no hosted body nodes, $zero_body_matches have no body matches"
if [ "$compared" -eq 0 ] || [ "$body_nodes" -eq 0 ] || [ "$body_matched" -eq 0 ] || \
   [ $((compared + excluded)) -ne $((bodies + arms)) ]; then
  echo 'FAIL: the fixture inventory did not produce a complete comparison'
  status=1
fi

echo
echo '== 3. Exact regression fixtures'
FLOW="$REPO_NATIVE/bench/fixtures/typed_bodies_flow.iyi"
MERGE="$REPO_NATIVE/bench/fixtures/typed_bodies_merge.iyi"
"$WORK/entry-oracle$EXE" --bare "$FLOW" > "$WORK/flow-entry.host" 2> "$WORK/flow-entry.host.err" || exit 1
"$WORK/entry-port$EXE" $IYI_TYPED_DEFINES "$FLOW" "$REPO_NATIVE/src" > "$WORK/flow-entry.port" 2> "$WORK/flow-entry.port.err" || exit 1
"$WORK/body-oracle$EXE" --bare "$FLOW" > "$WORK/flow-body.host" 2> "$WORK/flow-body.host.err" || exit 1
"$WORK/body-port$EXE" $IYI_TYPED_DEFINES "$FLOW" "$REPO_NATIVE/src" > "$WORK/flow-body.port" 2> "$WORK/flow-body.port.err" || exit 1
sort "$WORK/flow-entry.host" > "$WORK/flow-entry.host.sorted"
sort "$WORK/flow-entry.port" > "$WORK/flow-entry.port.sorted"
sort "$WORK/flow-body.host" > "$WORK/flow-body.host.sorted"
sort "$WORK/flow-body.port" > "$WORK/flow-body.port.sorted"
if [ ! -s "$WORK/flow-body.host.sorted" ] || ! diff -u "$WORK/flow-entry.host.sorted" "$WORK/flow-entry.port.sorted" || \
   ! diff -u "$WORK/flow-body.host.sorted" "$WORK/flow-body.port.sorted"; then
  echo 'FAIL: flow fixture differs from hosted typed nodes'
  status=1
else
  echo "  flow fixture: $(wc -l < "$WORK/flow-entry.host.sorted" | tr -d ' ') entry and $(wc -l < "$WORK/flow-body.host.sorted" | tr -d ' ') body nodes identical"
fi
if ! awk 'index($0,"check_nested(") && / Or \(Bool \| Item\)$/ {n++} END {exit n != 2}' "$WORK/flow-body.host"; then
  echo 'FAIL: hosted nested condition did not type both Or nodes as (Bool | Item)'
  status=1
fi
"$WORK/types-oracle$EXE" "$MERGE" > "$WORK/merge.host" 2> "$WORK/merge.host.err" || exit 1
"$WORK/types-port$EXE" "$MERGE" > "$WORK/merge.port" 2> "$WORK/merge.port.err" || exit 1
if [ ! -s "$WORK/merge.host" ] || ! diff -u "$WORK/merge.host" "$WORK/merge.port"; then
  echo 'FAIL: union operations differ from hosted'
  status=1
else
  echo "  union fixture: $(wc -l < "$WORK/merge.host" | tr -d ' ') operations identical"
  awk '/^merge\(Union\(Int32, String\), Nil\)/ {print "  " $0}' "$WORK/merge.host"
fi

# A mutation is caught only by a successfully built and executed mutant which
# loses the specified hosted node, not by a compiler error or an unrelated diff.
check_body_mutation() {
  local owner="$1" expected="$2"
  if ! build_port bench/fixtures/typed_bodies_dump.iyi mutant-body; then
    echo 'INVALID MUTANT: body driver failed to build'
    return 2
  fi
  if ! "$WORK/mutant-body$EXE" $IYI_TYPED_DEFINES "$FLOW" "$REPO_NATIVE/src" > "$WORK/mutant.body" 2> "$WORK/mutant.body.err"; then
    echo 'INVALID MUTANT: body driver failed to run'
    return 2
  fi
  sort "$WORK/mutant.body" > "$WORK/mutant.body.sorted"
  comm -23 "$WORK/flow-body.host.sorted" "$WORK/mutant.body.sorted" > "$WORK/mutant.missing"
  if awk -v owner="$owner" -v expected="$expected" \
      'index($0, owner) && index($0, expected) {print "decisive: missing " $0; found=1; exit} END {exit !found}' "$WORK/mutant.missing"; then
    return 1
  fi
  echo "no targeted body mismatch for $owner $expected"
  return 0
}
check_type_mutation() {
  if ! build_port bench/selfhost_semantic_types_exercise.iyi mutant-types; then
    echo 'INVALID MUTANT: type query driver failed to build'
    return 2
  fi
  if ! "$WORK/mutant-types$EXE" "$MERGE" > "$WORK/mutant.types" 2> "$WORK/mutant.types.err"; then
    echo 'INVALID MUTANT: type query driver failed to run'
    return 2
  fi
  if awk -F ' => ' '$1 == "merge(Union(Int32, String), Nil)" && $2 != "(Int32 | String | Nil)" {print "decisive: " $0; found=1} END {exit !found}' "$WORK/mutant.types"; then
    return 1
  fi
  echo 'no targeted union-instantiation mismatch'
  return 0
}

echo
echo '== 4. Mutation proofs on every supported host'
mutations=0
caught=0
prove_mutation 'an OR condition incorrectly narrows its left operand' \
  "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '        @type_filters = TypeFilters.or_filters(cond_type_filters, else_type_filters)' \
  '        @type_filters = cond_type_filters' \
  -- check_body_mutation 'check_choice(' 'Var (Item | Nil)' && caught=$((caught + 1)) || status=1
mutations=$((mutations + 1))
prove_mutation 'a negated condition does not invert its filter' \
  "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      @type_filters = TypeFilters.invert(@type_filters)' \
  '      @type_filters = TypeFilters.invert(TypeFilters.invert(@type_filters))' \
  -- check_body_mutation 'check_negation(' 'Var Nil' && caught=$((caught + 1)) || status=1
mutations=$((mutations + 1))
prove_mutation 'merging a non-nil union with Nil drops Nil' \
  "$REPO/src/compiler/types/merge.iyi" \
  '    if second.nil_type? && first.is_a?(UnionType) && union_includes?(first.as(UnionType), second)' \
  '    if second.nil_type? && first.is_a?(UnionType)' \
  -- check_body_mutation 'check_merge(' 'If (Int32 | String | Nil)' && caught=$((caught + 1)) || status=1
mutations=$((mutations + 1))
prove_mutation 'revert lazy logical expansion and lose nested OR types' \
  "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '      if node.is_a?(Or)
        tree = @literal_expander.expand_or(node.as(Or))
      elsif node.is_a?(And)
        tree = @literal_expander.expand_and(node.as(And))
      else
        tree = node.transform(@literal_expander)
      end' \
  '      tree = node.transform(@literal_expander)' \
  -- check_body_mutation 'check_nested(' 'Or (Bool | Item)' && caught=$((caught + 1)) || status=1
mutations=$((mutations + 1))
prove_mutation 'revert Union generic instantiation to an ordinary class instance' \
  "$REPO/src/compiler/types/type_system.iyi" \
  '    if generic_type == @program.types["Union"]?' \
  '    if false && generic_type == @program.types["Union"]?' \
  -- check_type_mutation && caught=$((caught + 1)) || status=1
mutations=$((mutations + 1))
echo "  mutations: $caught/$mutations caught"
[ "$mutations" -eq 5 ] && [ "$caught" -eq 5 ] || status=1

echo
if [ "$status" -eq 0 ]; then
  echo '== ALL TYPED BODY CHECKS PASSED'
else
  echo '== SOME TYPED BODY CHECKS FAILED'
fi
exit "$status"
