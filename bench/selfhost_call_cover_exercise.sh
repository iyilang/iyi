#!/usr/bin/env bash
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
cd "$REPO" || exit 1
REPO_NATIVE="$(native_path "$REPO")"
export IYI_PATH="$REPO_NATIVE/src"
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK_NATIVE="$(native_path "$WORK")"
. "$REPO/bench/lib/mutation.sh"
invalid_mutant() {
  echo "INVALID MUTANT: $*"
  [ "${_PM_ARMED:-0}" = 1 ]
}
check_cover() {
  rm -f "$WORK/probe$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/probe$EXE" "$REPO_NATIVE/bench/selfhost_call_cover_probe.iyi" > "$WORK/build.log" 2>&1 ||
     [ ! -x "$WORK/probe$EXE" ]; then
    cat "$WORK/build.log"
    invalid_mutant "cover probe failed to build"
    return $?
  fi
  if ! "$WORK/probe$EXE" > "$WORK/actual"; then
    invalid_mutant "cover probe failed to run"
    return $?
  fi
  printf '%s\n' 'module=A,B' 'trait=A,B' 'virtual=A,B' 'alias-union=A,B' > "$WORK/expected"
  cmp -s "$WORK/actual" "$WORK/expected"
}
check_cover || exit 1
status=0
COVER="$REPO/src/compiler/semantic/cover.iyi"
prove_mutation 'alias cover follows the aliased type' "$COVER" \
  '      append(type.as(AliasType).process_value, result)' '      result << type' -- check_cover || status=1
prove_mutation 'union cover includes each member' "$COVER" \
  '      type.as(UnionType).union_types.each { |member| append(member, result) }' '      result << type' -- check_cover || status=1
prove_mutation 'abstract virtual cover descends into subclasses' "$COVER" \
  '      if base.abstract?' '      if false' -- check_cover || status=1
prove_mutation 'module cover expands its includers' "$COVER" \
  '      type.as(NonGenericModuleType).including_types.each { |member| append(member, result) }' '      result << type' -- check_cover || status=1
prove_mutation 'trait cover expands its implementers' "$COVER" \
  '      type.as(TraitType).including_types.each { |member| append(member, result) }' '      result << type' -- check_cover || status=1
exit "$status"
