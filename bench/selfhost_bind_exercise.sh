#!/usr/bin/env bash
# Fails when the iyi bind tool stops agreeing with the front end it replaces.
#
# The oracle is the hosted compiler's `Iyi.print_bind` (`src/compiler/iyi/tools/bind.cr`),
# built with `-Di_know_what_im_doing` and `LLVM_CONFIG` set, driven over the full
# eleven-fixture corpus. Each fixture is bound by both implementations and required
# byte-identical in its summary counts, method classifications, instantiation
# statistics, and draft module declarations.
#
# The hosted tool consumes a semantically analysed program, so a fixture the
# hosted front end rejects is reported as UNANALYSABLE: the oracle prints the
# front end's error and the gate fails rather than comparing empty output.
# The five original parser fixtures are syntax exercises rather than valid
# programs, and the hosted compiler rejects each semantically with:
#   decl_classes_and_structs:   Error: there's no self in this scope
#   decl_lib_and_fun:           Error: fun redefinition with different signature
#   decl_modules_and_inclusion: Error: Service is not a module, it's a class
#   decl_traits_and_impls:      Error: undefined constant Comparable
#   decl_types_and_vars:        Error: can only declare instance variables of a non-generic class
# Rather than leaving unanalysable parser fixtures in the corpus or trimming it,
# five companion fixtures (`bind_classes_and_structs`, `bind_lib_and_fun`,
# `bind_modules_and_inclusion`, `bind_traits_and_impls`, `bind_types_and_vars`)
# cover the same declaration surface as programs the hosted compiler accepts.
# The parity gate compares both tools over that corpus.
# Both implementations receive repo-relative fixture paths, so their dumps
# contain the same paths across hosts.
#
# The mutation proofs follow the rule the other selfhost gates use: the patched
# file is compared against the original, and a patch that matched nothing is
# reported as proving nothing rather than passing quietly.
#
#   bash bench/selfhost_bind_exercise.sh
set -u
status=0
diverged=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if ! command -v perl >/dev/null 2>&1; then
  echo "  FAILED: perl is required for the mutation proofs" >&2
  exit 1
fi
. "$REPO/bench/lib/mutation.sh" || exit 1
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
BIND="$REPO/src/compiler/tools/bind.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE="$(native_path "$REPO")" || exit 1
WORK_NATIVE="$(native_path "$WORK")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
cd "$REPO" || exit 1
# The mutation helper retains only a log tail; preserve full invalid-build logs.
exec 3>&1

echo "== 1. Building and running the bind tool exercise"
if ! "$IYI" build -o "$WORK_NATIVE/exercise$EXE" "$REPO_NATIVE/bench/selfhost_bind_exercise.iyi"; then
  echo "  FAILED to build bench/selfhost_bind_exercise.iyi"
  exit 1
fi
if ! "$WORK/exercise$EXE" > "$WORK/plain.out" 2>&1; then
  echo "  EXERCISE FAILED"
  cat "$WORK/plain.out"
  exit 1
fi
cat "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST BIND CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "  EXERCISE FAILED"
  status=1
fi

echo
echo "== 2. Bound method comparison against the front end being replaced"
cat <<'HOSTED_ORACLE_SCRIPT' > "$WORK/dump_hosted_bind.cr"
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
HOSTED_ORACLE_SCRIPT

# The oracle is the compiler being replaced, so it is built the way that
# compiler is: LLVM_CONFIG is what gives its LibLLVM its version constants.
if ! LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
     CRYSTAL_PATH="$REPO_NATIVE/src" "$CRYSTAL" build -Di_know_what_im_doing \
     -o "$WORK_NATIVE/dump_hosted$EXE" "$WORK_NATIVE/dump_hosted_bind.cr" > "$WORK/oracle_build.log" 2>&1; then
  echo "  FAILED to build the hosted oracle:"
  cat "$WORK/oracle_build.log"
  exit 1
fi
if [ ! -x "$WORK/dump_hosted$EXE" ]; then
  echo "  THE ORACLE DID NOT BUILD: executable is missing"
  cat "$WORK/oracle_build.log"
  exit 1
fi
echo "  Oracle: hosted Iyi.print_bind from src/compiler/iyi/tools/bind.cr (requires compiler/requires)"

FIXTURES=(
  "bench/fixtures/bind_classes_and_structs.iyi"
  "bench/fixtures/decl_def.iyi"
  "bench/fixtures/decl_enums.iyi"
  "bench/fixtures/bind_lib_and_fun.iyi"
  "bench/fixtures/bind_modules_and_inclusion.iyi"
  "bench/fixtures/decl_operators.iyi"
  "bench/fixtures/bind_traits_and_impls.iyi"
  "bench/fixtures/bind_types_and_vars.iyi"
  "bench/fixtures/decl_visibility_and_annotations.iyi"
  "bench/fixtures/bind_shard.iyi"
  "bench/fixtures/bind_generics.iyi"
)

# Every fixture, both implementations, byte for byte.
compare_all() {
  local out_status=0 rel_fixture
  for rel_fixture in "${FIXTURES[@]}"; do
    if ! CRYSTAL_PATH="$REPO_NATIVE/src" "$WORK/dump_hosted$EXE" "$rel_fixture" > "$WORK/hosted.out" 2>"$WORK/hosted.err"; then
      echo "INVALID MUTANT: hosted oracle failed on $rel_fixture"
      cat "$WORK/hosted.err"
      return 0
    fi
    if [ ! -s "$WORK/hosted.out" ]; then
      echo "INVALID MUTANT: hosted oracle returned no output on $rel_fixture"
      cat "$WORK/hosted.err"
      return 0
    fi
    "$1" "$rel_fixture" > "$WORK/mutant.out" 2>"$WORK/mutant.err" || { out_status=1; continue; }
    cmp -s "$WORK/mutant.out" "$WORK/hosted.out"
    cmp_rc=$?
    if [ "$cmp_rc" -eq 1 ]; then
      out_status=1
    elif [ "$cmp_rc" -ne 0 ]; then
      echo "INVALID MUTANT: cannot compare output for $rel_fixture"
      return 0
    fi
  done
  return "$out_status"
}

diverged=0
unanalisable=0
fixture_count=0
total_matched_methods=0
for rel_fixture in "${FIXTURES[@]}"; do
  fixture_name="$rel_fixture"
  if ! "$WORK/exercise$EXE" "$rel_fixture" > "$WORK/iyi.out" 2>"$WORK/iyi.err"; then
    echo "  $fixture_name: BIND EXERCISE FAILED"
    cat "$WORK/iyi.err"
    diverged=$((diverged + 1))
    status=1
    fixture_count=$((fixture_count + 1))
    continue
  fi
  CRYSTAL_PATH="$REPO_NATIVE/src" "$WORK/dump_hosted$EXE" "$rel_fixture" > "$WORK/hosted.out" 2>"$WORK/hosted.err"
  hosted_rc=$?
  if [ "$hosted_rc" -ne 0 ] || [ ! -s "$WORK/hosted.out" ]; then
    first_err=$(grep "^Error:" "$WORK/hosted.err" | head -n 1 | sed "s/^Error: //")
    [ -z "$first_err" ] && first_err=$(head -n 1 "$WORK/hosted.err")
    echo "  $fixture_name: UNANALYSABLE BY THE HOSTED FRONT END"
    echo "    hosted oracle error: $first_err"
    unanalisable=$((unanalisable + 1))
    status=1
    fixture_count=$((fixture_count + 1))
    continue
  fi
  if ! diff -u "$WORK/hosted.out" "$WORK/iyi.out" > "$WORK/diff.out"; then
    echo "  $fixture_name: BOUND METHODS DIFFER"
    diverged=$((diverged + 1))
    cat "$WORK/diff.out"
    status=1
  elif ! methods_count=$(CRYSTAL_PATH="$REPO_NATIVE/src" "$WORK/dump_hosted$EXE" "$rel_fixture" --count 2>"$WORK/hosted.err"); then
    echo "  $fixture_name: HOSTED METHOD COUNT FAILED"
    cat "$WORK/hosted.err"
    diverged=$((diverged + 1))
    status=1
  else
    case "$methods_count" in
      ''|*[!0-9]*)
        echo "  $fixture_name: INVALID HOSTED METHOD COUNT: $methods_count"
        diverged=$((diverged + 1))
        status=1
        ;;
      *)
        echo "  $fixture_name: identical ($methods_count public methods match the front end)"
        total_matched_methods=$((total_matched_methods + methods_count))
        ;;
    esac
  fi
  fixture_count=$((fixture_count + 1))
done
matched=$((fixture_count - diverged - unanalisable))
echo "  Parity summary: $matched/$fixture_count fixtures bind identically ($total_matched_methods total public methods)"
if [ "$unanalisable" -gt 0 ]; then
  echo "  $unanalisable fixture(s) the hosted front end cannot analyse; see the UNANALYSABLE lines above"
fi

echo
echo "== 3. Mutation proofs: each one must make the comparison above fail"

check_bind_mutant() {
  rm -f "$WORK/mut-exercise$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_bind_exercise.iyi" > "$WORK/mut-build.log" 2>&1; then
    echo "INVALID MUTANT: bind exercise failed to build" >&3
    cat "$WORK/mut-build.log" >&3
    echo "INVALID MUTANT: bind exercise failed to build"
    return 0
  fi
  if [ ! -x "$WORK/mut-exercise$EXE" ]; then
    echo "INVALID MUTANT: bind exercise executable is missing" >&3
    cat "$WORK/mut-build.log" >&3
    echo "INVALID MUTANT: bind exercise executable is missing"
    return 0
  fi
  compare_all "$WORK/mut-exercise$EXE"
}

MUTATIONS_RUN=0

prove_mutation "untyped arguments stop triggering NeedsHuman verdict" "$BIND" \
  "verdict = BindVerdict::NeedsHuman" \
  "verdict = BindVerdict::Ready" \
  -- check_bind_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "block detection is disabled across methods" "$BIND" \
  "has_block = !node.block_arg.nil? || node.uses_block_arg?" \
  "has_block = false" \
  -- check_bind_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "ready method counting is bypassed in summary report" "$BIND" \
  "ready = ready + 1" \
  "ready = ready + 0" \
  -- check_bind_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "callable calculation requires unannotated block" "$BIND" \
  "!@block || !@written_block.empty?" \
  "!@block && !@written_block.empty?" \
  -- check_bind_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "generic type instantiation refusal is disabled" "$BIND" \
  "refused = \"generic type\"" \
  "refused = \"\"" \
  -- check_bind_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "also declares output header is omitted" "$BIND" \
  "sb << \"also declares: \"" \
  "sb << \"declares also: \"" \
  -- check_bind_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "empty methods early return in summary report is bypassed" "$BIND" \
  "if methods.empty?" \
  "if false && methods.empty?" \
  -- check_bind_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "empty root matching bypasses namespace scoping" "$BIND" \
  "!@root.empty? && (owner == @root || owner.starts_with?(\"#{@root}::\") || owner.starts_with?(\"#{@root}:\"))" \
  "true || (owner == @root || owner.starts_with?(\"#{@root}::\") || owner.starts_with?(\"#{@root}:\"))" \
  -- check_bind_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST BIND CHECKS PASSED"
else
  echo "== SELFHOST BIND CHECKS FAILED"
fi
exit $status
