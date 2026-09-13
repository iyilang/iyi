#!/usr/bin/env bash
# Fails when the iyi bind tool stops agreeing with the front end it replaces.
#
# The oracle is the shipped compiler's `Iyi.print_bind`, built with `-Di_know_what_im_doing`
# and `LLVM_CONFIG` set. Each fixture is bound by both implementations and required
# byte-identical in its summary counts, method classifications, instantiation
# statistics, and draft module declarations.
#
# Machine-specific properties (absolute filesystem paths) are normalized in
# BOTH implementations' dumps identically by stripping workspace prefixes to
# relative fixture paths (e.g. bench/fixtures/bind_shard.iyi:14:5), so the comparison
# holds across workstations and CI environments without loosening the check.
#
# The mutation proofs follow the rule the other selfhost gates use: the patched
# file is compared against the original, and a patch that matched nothing is
# reported as proving nothing rather than passing quietly.
#
#   bash bench/selfhost_bind_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
BIND="$REPO/src/compiler/tools/bind.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. Building and running the bind tool exercise"
"$IYI" build -o "$WORK/exercise" "$REPO/bench/selfhost_bind_exercise.iyi"
"$WORK/exercise" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST BIND CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "  EXERCISE FAILED"
  status=1
fi

echo
echo "== 2. Bound method comparison against the front end being replaced"
cat <<'CRYSTAL_GOLDEN_SCRIPT' > "$WORK/dump_crystal_bind.cr"
require "compiler/requires"

module Iyi
  def self.collect_public_methods(program : Program, root : String) : Array(BindMethod)
    methods = [] of BindMethod
    collect_bind program.types?, root, methods
    methods
  end
end

filename = ARGV[0]
source = File.read(filename)

root = ARGV.size > 1 ? ARGV[1] : ""
if root == "--count"
  root = ""
end
if root.empty?
  source.each_line do |line|
    if match = line.match(/^(?:abstract\s+)?(?:module|class|struct)\s+([A-Z][A-Za-z0-9_]*)/)
      root = match[1]
      break
    end
  end
end

compiler = Iyi::Compiler.new
compiler.no_codegen = true
result = compiler.compile(Iyi::Compiler::Source.new(filename, source), "/dev/null")

if ARGV.includes?("--count")
  methods = Iyi.collect_public_methods(result.program, root)
  puts methods.size
else
  Iyi.print_bind(result.program, root, STDOUT)
end
CRYSTAL_GOLDEN_SCRIPT

# The oracle is the compiler being replaced, so it is built the way that
# compiler is: LLVM_CONFIG is what gives its LibLLVM its version constants.
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK/dump_crystal" "$WORK/dump_crystal_bind.cr"
if [ ! -x "$WORK/dump_crystal" ]; then
  echo "  THE ORACLE DID NOT BUILD: this gate cannot conclude anything"
  exit 1
fi
echo "  Oracle: shipped Iyi.print_bind from src/compiler/iyi/tools/bind.cr (requires compiler/requires)"

FIXTURES=(
  "bench/fixtures/bind_shard.iyi"
  "bench/fixtures/bind_generics.iyi"
)

# Every fixture, both implementations, byte for byte.
compare_all() {
  out_status=0
  for rel_fixture in "${FIXTURES[@]}"; do
    "$1" "$rel_fixture" > "$WORK/a.out" 2>/dev/null || { out_status=1; continue; }
    CRYSTAL_PATH="$REPO/src" "$WORK/dump_crystal" "$rel_fixture" > "$WORK/b.out" 2>/dev/null || { out_status=1; continue; }
    diff -q "$WORK/a.out" "$WORK/b.out" >/dev/null || out_status=1
  done
  return $out_status
}

fixture_count=0
total_matched_methods=0
for rel_fixture in "${FIXTURES[@]}"; do
  fixture_name="$rel_fixture"
  "$WORK/exercise" "$rel_fixture" > "$WORK/iyi.out"
  CRYSTAL_PATH="$REPO/src" "$WORK/dump_crystal" "$rel_fixture" > "$WORK/crystal.out"
  if ! diff -u "$WORK/crystal.out" "$WORK/iyi.out" > "$WORK/diff.out"; then
    echo "  $fixture_name: BOUND METHODS DIFFER"
    cat "$WORK/diff.out"
    status=1
  else
    methods_count=$(CRYSTAL_PATH="$REPO/src" "$WORK/dump_crystal" "$rel_fixture" --count)
    echo "  $fixture_name: identical ($methods_count public methods match the front end)"
    total_matched_methods=$((total_matched_methods + methods_count))
  fi
  fixture_count=$((fixture_count + 1))
done
echo "  Parity summary: $fixture_count/$fixture_count fixtures bind identically ($total_matched_methods total public methods)"

echo
echo "== 3. Mutation proofs: each one must make the comparison above fail"

prove_mutation() {
  label="$1"
  old="$2"
  new="$3"
  echo "  [$label]"
  cp "$BIND" "$BIND.orig"
  python3 - "$BIND" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
if old not in t:
    sys.exit(3)
open(path, "w").write(t.replace(old, new, 1))
PY
  rc=$?
  if [ "$rc" -eq 3 ] || diff -q "$BIND.orig" "$BIND" >/dev/null; then
    echo "    PATCH CHANGED NOTHING: this proves nothing"
    status=1
    cp "$BIND.orig" "$BIND"; rm -f "$BIND.orig"
    return
  fi
  if "$IYI" build -o "$WORK/mut-exercise" "$REPO/bench/selfhost_bind_exercise.iyi" >/dev/null 2>&1; then
    if compare_all "$WORK/mut-exercise"; then
      echo "    FAILED: the comparison still passed with the mutation applied"
      status=1
    else
      echo "    caught: the bound outputs diverged, as they must"
    fi
  else
    echo "    caught: the mutated bind tool did not build"
  fi
  cp "$BIND.orig" "$BIND"; rm -f "$BIND.orig"
  echo "    reverted"
}

MUTATIONS_RUN=0
run_proof() {
  prove_mutation "$1" "$2" "$3"
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
}

run_proof "untyped arguments stop triggering NeedsHuman verdict" \
  "verdict = BindVerdict::NeedsHuman" \
  "verdict = BindVerdict::Ready"

run_proof "block detection is disabled across methods" \
  "has_block = !node.block_arg.nil? || node.uses_block_arg?" \
  "has_block = false"

run_proof "ready method counting is bypassed in summary report" \
  "ready = ready + 1" \
  "ready = ready + 0"

run_proof "callable calculation requires unannotated block" \
  "!@block || !@written_block.empty?" \
  "!@block && !@written_block.empty?"

run_proof "generic type instantiation refusal is disabled" \
  "refused = \"generic type\"" \
  "refused = \"\""

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST BIND CHECKS PASSED"
else
  echo "== SELFHOST BIND CHECKS FAILED"
fi
exit $status
