#!/usr/bin/env bash
# Compare normal-path handler lowering with the hosted module after its unwind
# edges have been removed, then compare the executable's output and status.
# Hosted unwind-only blocks consume names from the same local counter as the
# normal path. In handler bodies, canonicalize nonnumeric local names by base
# and first occurrence so their suffixes do not hide instruction differences.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
# The LLVM bridge takes its version, targets and link flags as build arguments (src/compiler/llvm/lib_llvm.iyi): read
# them for this host once, and pass them to every build of a program that imports the bridge.
LLVM_BRIDGE_ARGS=()
llvm_bridge_text=$(llvm_bridge_build_args) || { echo "FAILED: no LLVM build arguments for this host, see the sentence above"; exit 1; }
while IFS= read -r llvm_arg; do LLVM_BRIDGE_ARGS+=("$llvm_arg"); done <<< "$llvm_bridge_text"
if [ -z "$PY" ]; then
  echo 'FAIL: a functional Python interpreter is required' >&2
  exit 1
fi
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")" || exit 1
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/lower_oracle.sh"
status=0

# The empty-prelude ABI supplies a private main entry. The generated wrapper
# uses that ABI, while the checked-in prelude declares only the runtime stubs.
mkdir -p "$WORK/prelude"
awk '{print} END {
  print "lib LibEntry"
  print "  fun entry = __cry" "stal_main(argc : Int32, argv : UInt8**) : Void*"
  print "end"
  print "fun main(argc : Int32, argv : UInt8**) : Int32"
  print "  LibEntry.entry(argc, argv)"
  print "  0"
  print "end"
}' "$REPO/bench/fixtures/lowens_prelude/prelude.iyi" > "$WORK/prelude/prelude.iyi"

build_port() {
  "$IYI" build -o "$WORK_NATIVE/port$EXE" "$REPO_NATIVE/bench/selfhost_lower_calls_exercise.iyi" > "$WORK/port.log" 2>&1
}

# Fixture functions reference no globals. As in the core headed fixture, compare
# the complete function body without the prelude-dependent signature attributes.
extract_work() {
  awk '/^define / && index($0, "*work") { active = 1; next } active { print } active && /^}$/ { found = 1; exit } END { if (!found) exit 1 }' "$1" |
    "$PY" -c '
import re, sys
names = {}
counts = {}
token = re.compile(r"(?P<value>%[A-Za-z$._][A-Za-z0-9$._-]*|^[A-Za-z$._][A-Za-z0-9$._-]*(?=:))", re.M)
def replace(match):
    raw = match.group("value")
    prefix = "%" if raw.startswith("%") else ""
    name = raw[len(prefix):]
    if name not in names:
        base = re.sub(r"[0-9]+$", "", name)
        index = counts.get(base, 0)
        counts[base] = index + 1
        names[name] = f"{base}#{index}"
    return prefix + names[name]
sys.stdout.write(token.sub(replace, sys.stdin.read()))
' > "$2"
}

# The comparison must still reject a branch redirected to a different block.
normalization_negative() {
  awk 'BEGIN { print "define void @\"*work\"() {"; print "entry:"; print "  br label %body1"; print "body1:"; print "  br label %exit2"; print "exit2:"; print "  ret void"; print "}" }' > "$WORK/names.good"
  awk 'BEGIN { print "define void @\"*work\"() {"; print "entry:"; print "  br label %exit2"; print "body1:"; print "  br label %exit2"; print "exit2:"; print "  ret void"; print "}" }' > "$WORK/names.wrong"
  extract_work "$WORK/names.good" "$WORK/names.good.norm" &&
    extract_work "$WORK/names.wrong" "$WORK/names.wrong.norm" &&
    ! cmp -s "$WORK/names.good.norm" "$WORK/names.wrong.norm"
}

check_fixture() {
  local name="$1" expected_code actual_code
  if ! "$WORK/port$EXE" emit "$REPO_NATIVE/bench/fixtures/lowens_${name}.iyi" "$WORK_NATIVE/${name}.ll" > "$WORK/${name}.port.ir" 2> "$WORK/${name}.port.err"; then
    echo "INVALID: $name did not emit IR"
    cat "$WORK/${name}.port.err"
    return 2
  fi
  awk '/^define / && index($0, "*work") { found = 1; if (index($0, "personality")) exit 1 } END { if (!found) exit 1 }' "$WORK/${name}.port.ir" || return 1
  extract_work "$WORK/${name}.host.ir" "$WORK/${name}.host.work" || return 1
  extract_work "$WORK/${name}.port.ir" "$WORK/${name}.port.work" || return 1
  if ! cmp -s "$WORK/${name}.host.work" "$WORK/${name}.port.work"; then
    diff -u "$WORK/${name}.host.work" "$WORK/${name}.port.work" || true
    return 1
  fi
  if ! "$WORK/native$EXE" "$WORK_NATIVE/${name}.port.ir" -o "$WORK_NATIVE/${name}.native" > "$WORK/${name}.native.log" 2>&1; then
    echo "INVALID: $name native executable did not build"
    cat "$WORK/${name}.native.log"
    return 2
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then
    return 0
  fi
  timeout 30 "$WORK/${name}$EXE" > "$WORK/${name}.host.out" 2>&1
  expected_code=$?
  timeout 30 "$WORK/${name}.native" > "$WORK/${name}.native.out" 2>&1
  actual_code=$?
  [ "$expected_code" -ne 124 ] && [ "$actual_code" -ne 124 ] && [ "$expected_code" -eq "$actual_code" ] && cmp -s "$WORK/${name}.host.out" "$WORK/${name}.native.out"
}

mutation_check() {
  if ! build_port; then
    echo 'INVALID: mutated comparison driver did not build'
    cat "$WORK/port.log"
    return 2
  fi
  check_fixture "$1"
}

echo '== 1. Building comparison and native tools'
if ! build_port || ! "$IYI" build "${LLVM_BRIDGE_ARGS[@]}" -o "$WORK_NATIVE/bridge$EXE" "$REPO_NATIVE/src/compiler/tools/ir.iyi" > "$WORK/bridge.log" 2>&1 || ! "$IYI" build -o "$WORK_NATIVE/native$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/native.log" 2>&1; then
  echo '  FAIL: tool build failed'
  for log in "$WORK/port.log" "$WORK/bridge.log" "$WORK/native.log"; do
    [ ! -f "$log" ] || awk 'NR <= 12 { print }' "$log"
  done
  exit 1
fi
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "lower ensure: running AArch64 Mach-O fixtures requires macOS arm64 ($HOST_ID compares IR and emits Mach-O)"
fi

echo '== 2. Hosted and port function bodies and native executions'
passed=0
failed_names=""
for name in fallthrough value return break next block_break block_next boundary nested_loops around_yield nested nested_return invoke union block_union; do
  if ! IYI_PATH="$WORK_NATIVE/prelude" "$IYI" build --prelude prelude --emit llvm-ir --no-debug -o "$WORK_NATIVE/${name}$EXE" "$REPO_NATIVE/bench/fixtures/lowens_${name}.iyi" > "$WORK/${name}.host.log" 2>&1; then
    echo "  FAIL: $name hosted compilation"
    awk 'NR <= 8 { print }' "$WORK/${name}.host.log"
    failed_names="$failed_names $name"
    status=1
    continue
  fi
  if [ "$HOST_ID" != darwin-arm64 ] &&
     ! IYI_PATH="$WORK_NATIVE/prelude" "$IYI" build --cross-compile --target aarch64-apple-darwin --prelude prelude --emit llvm-ir --no-debug -o "$WORK_NATIVE/${name}.o" "$REPO_NATIVE/bench/fixtures/lowens_${name}.iyi" > "$WORK/${name}.cross.log" 2>&1; then
    echo "  FAIL: $name Darwin-target hosted IR"
    cat "$WORK/${name}.cross.log"
    failed_names="$failed_names $name"
    status=1
    continue
  fi
  if ! "$WORK/bridge$EXE" drop-unwind "$WORK_NATIVE/${name}.ll" > "$WORK/${name}.host.ir" 2> "$WORK/${name}.bridge.log"; then
    echo "  FAIL: $name unwind legalization"
    awk 'NR <= 8 { print }' "$WORK/${name}.bridge.log"
    failed_names="$failed_names $name"
    status=1
    continue
  fi
  if check_fixture "$name"; then
    if [ "$HOST_ID" = darwin-arm64 ]; then
      echo "  $name: identical and native output/status match"
    else
      echo "  $name: identical IR"
    fi
    passed=$((passed + 1))
  else
    echo "  FAIL: $name differs or cannot run"
    for log in "$WORK/${name}.port.err" "$WORK/${name}.native.log"; do
      [ ! -f "$log" ] || awk 'NR <= 5 { print }' "$log"
    done
    failed_names="$failed_names $name"
    status=1
  fi
done

echo '== 3. Name normalization negative control'
if normalization_negative; then
  echo '  caught: branch to wrong block'
else
  echo '  FAIL: name normalization hid a wrong branch'
  status=1
fi

echo '== 4. Mutation proofs'
if [ "$passed" -eq 15 ] || { [ "$passed" -eq 14 ] && [ "$failed_names" = " invoke" ]; }; then
  file="$REPO/src/compiler/lower/ensure.iyi"
  prove_mutation 'fallthrough cleanup' "$file" 'visit_node(low, cleanup.as(ASTNode))' 'low.last = value' -- mutation_check fallthrough || status=1
  prove_mutation 'fallthrough cleanup runs twice' "$file" '    visit_node(low, cleanup.as(ASTNode))' '    visit_node(low, cleanup.as(ASTNode)); visit_node(low, cleanup.as(ASTNode))' -- mutation_check fallthrough || status=1
  prove_mutation 'exit phi preserves body value' "$file" '  phi.add(low, low.last, false)' '  phi.add(low, llvm_nil(low), false)' -- mutation_check value || status=1
  prove_mutation 'by-value ensure joins use pointer phis' "$file" \
    'merge = by_value ? low.module.types.ptr : low.typer.llvm_type(t.as(Type))' \
    'merge = low.typer.llvm_type(t.as(Type))' -- mutation_check union || status=1
  prove_mutation 'ensure aggregate copy clears holes' "$file" '  clear_value_holes(low, copy, t)' '  nil' -- mutation_check union || status=1
  prove_mutation 'body value survives cleanup' "$file" '    low.last = value' '    low.last = low.last' -- mutation_check value || status=1
  prove_mutation 'return cleanup' "$file" 'while low.ensure_nodes.size > stop' 'while low.ensure_nodes.size > low.ensure_nodes.size' -- mutation_check return || status=1
  prove_mutation 'break cleanup' "$file" 'while low.ensure_nodes.size > stop' 'while low.ensure_nodes.size > low.ensure_nodes.size' -- mutation_check break || status=1
  prove_mutation 'next cleanup' "$file" 'while low.ensure_nodes.size > stop' 'while low.ensure_nodes.size > low.ensure_nodes.size' -- mutation_check next || status=1
  prove_mutation 'block break cleanup' "$file" 'while low.ensure_nodes.size > stop' 'while low.ensure_nodes.size > low.ensure_nodes.size' -- mutation_check block_break || status=1
  prove_mutation 'block next cleanup' "$file" 'while low.ensure_nodes.size > stop' 'while low.ensure_nodes.size > low.ensure_nodes.size' -- mutation_check block_next || status=1
  prove_mutation 'loop boundary preserves outer cleanup' "$file" 'stop = low.ensure_boundaries[target.object_id]? || 0' 'stop = 0' -- mutation_check boundary || status=1
  prove_mutation 'nested loop boundary preserves outer cleanup' "$file" 'stop = low.ensure_boundaries[target.object_id]? || 0' 'stop = 0' -- mutation_check nested_loops || status=1
  prove_mutation 'yield boundary preserves outer cleanup' "$file" 'stop = low.ensure_boundaries[target.object_id]? || 0' 'stop = 0' -- mutation_check around_yield || status=1
  prove_mutation 'nested return cleanup' "$file" 'while low.ensure_nodes.size > stop' 'while low.ensure_nodes.size > low.ensure_nodes.size' -- mutation_check nested_return || status=1
  prove_mutation 'nested cleanup order' "$file" 'visit_node(low, node.body)' 'visit_node(low, cleanup.as(ASTNode)); visit_node(low, node.body)' -- mutation_check nested || status=1
else
  echo '  NOT RUN: baseline fixtures did not all pass'
  status=1
fi
if [ "$status" -eq 0 ]; then
  echo '== ALL LOWER ENSURE CHECKS PASSED'
else
  echo '== SOME LOWER ENSURE CHECKS FAILED'
fi
exit "$status"
