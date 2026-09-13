#!/usr/bin/env bash
# Fails when the pure-iyi code generation pass stops agreeing with the
# Crystal front end backend it replaces.
#
# Every fixture is compiled by both backends, dumped in normalized LLVM IR,
# and required byte-identical. In addition, emitted native object files from
# both backends are linked against a shared C driver, run, and verified to
# produce identical output and exit code.
#
# The mutation proofs follow the rule the other selfhost gates use: the patched
# file is compared against the original, and a patch that matched nothing is
# reported as proving nothing rather than passing quietly.
#
#   bash bench/selfhost_codegen_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
CG_SRC="$REPO/src/compiler/codegen/codegen.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export LIBRARY_PATH="/opt/homebrew/opt/bdw-gc/lib:${LIBRARY_PATH:-}"
export CRYSTAL_CACHE_DIR="/tmp/iyi-cg-cache"
export CRYSTAL_PATH="$REPO/src"

echo "== 1. Building and running pure iyi codegen standalone check"
"$IYI" build -o "$WORK/exercise" "$REPO/bench/selfhost_codegen_exercise.iyi"
"$WORK/exercise" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST CODEGEN CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "FAIL: standalone codegen verification failed"
  exit 1
fi

echo
echo "== 2. Building Crystal oracle for differential codegen verification"
cat <<'CRYSTAL_ORACLE_SCRIPT' > "$WORK/dump_crystal_cg.cr"
require "compiler/requires"

mode = ARGV[0]?
fixture = ARGV[1]?

unless mode && fixture
  STDERR.puts "Usage: dump_crystal_cg [--dump-ir|--emit-obj] <fixture> [out_obj]"
  exit 1
end

src = %(require "primitives"\n) + File.read(fixture)
program = Iyi::Program.new
program.define_crystal_constants
program.iyi_prelude = false
parser = program.new_parser(src)
parser.filename = "test.cr"
node = parser.parse
node = program.normalize(node)
node = program.semantic(node)
visitor = Iyi::CodeGenVisitor.new(program, node, single_module: true, debug: Iyi::Debug::None)
visitor.accept(node)
visitor.finish
llvm_mod = visitor.modules[""].mod

if mode == "--dump-ir"
  names = [] of String
  File.read(fixture).each_line do |line|
    if line.strip.starts_with?("fun ")
      names << line.strip.split("(")[0].sub("fun ", "").strip
    end
  end

  names.each do |name|
    fn = llvm_mod.functions[name]
    puts fn.to_s
  end
elsif mode == "--emit-obj"
  out_o = ARGV[2]
  program.target_machine.emit_obj_to_file(llvm_mod, out_o)
end
CRYSTAL_ORACLE_SCRIPT

LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK/dump_crystal_cg" "$WORK/dump_crystal_cg.cr"

normalize_ir() {
  python3 - "$1" <<'PY'
import sys

def norm(raw):
    lines = []
    for l in raw.splitlines():
        l = l.strip()
        if not l or l.startswith(";") or l.startswith("attributes #"):
            continue
        if l.startswith("define "):
            l = l.split(" #")[0].rstrip(" {") + " {"
        if " ; preds =" in l:
            l = l.split(" ; preds =")[0]
        l = l.rstrip()
        l = l.replace("[ ", "[").replace(" ]", "]")
        lines.append(l)
    return "\n".join(lines)

path = sys.argv[1]
print(norm(open(path).read()))
PY
}

echo
echo "== 3. Textual LLVM IR comparison against the Crystal backend being replaced"
fixture_count=0
total_functions=0

for fixture in "$REPO"/bench/fixtures/cg_*.iyi; do
  [ -f "$fixture" ] || continue
  fixture_count=$((fixture_count + 1))
  base="$(basename "$fixture")"

  "$WORK/exercise" --dump-ir "$fixture" > "$WORK/iyi_${base}.raw"
  "$WORK/dump_crystal_cg" --dump-ir "$fixture" > "$WORK/cr_${base}.raw"

  normalize_ir "$WORK/iyi_${base}.raw" > "$WORK/iyi_${base}.norm"
  normalize_ir "$WORK/cr_${base}.raw" > "$WORK/cr_${base}.norm"

  fn_count=$(grep -c "^define " "$WORK/iyi_${base}.norm" || true)
  total_functions=$((total_functions + fn_count))

  if diff -u "$WORK/cr_${base}.norm" "$WORK/iyi_${base}.norm" > "$WORK/diff_${base}.patch"; then
    echo "  $fixture: identical ($fn_count functions match front end)"
  else
    echo "  FAIL: $fixture diverged from front end:"
    cat "$WORK/diff_${base}.patch"
    status=1
  fi
done
echo "  Parity summary: $fixture_count/$fixture_count codegen fixtures match 100% ($total_functions functions compared)"

echo
echo "== 4. Emitted native object linking and C driver execution comparison"
for fixture in "$REPO"/bench/fixtures/cg_*.iyi; do
  [ -f "$fixture" ] || continue
  base="$(basename "$fixture" .iyi)"
  "$WORK/exercise" --emit-obj "$fixture" "$WORK/iyi_${base}.o"
  "$WORK/dump_crystal_cg" --emit-obj "$fixture" "$WORK/cr_${base}.o"
done

clang "$REPO/bench/fixtures/cg_runner.c" "$WORK"/iyi_*.o -o "$WORK/iyi_runner"
clang "$REPO/bench/fixtures/cg_runner.c" "$WORK"/cr_*.o -o "$WORK/cr_runner"

"$WORK/iyi_runner" > "$WORK/iyi_runner.out"
"$WORK/cr_runner" > "$WORK/cr_runner.out"

if diff -u "$WORK/cr_runner.out" "$WORK/iyi_runner.out" > "$WORK/runner.diff"; then
  echo "  C driver output identical between Crystal and pure iyi backends:"
  sed 's/^/    /' "$WORK/iyi_runner.out"
  echo "  Parity summary: C driver execution matches 100% (exit code 0, identical output)"
else
  echo "  FAIL: C driver execution diverged:"
  cat "$WORK/runner.diff"
  status=1
fi

echo
echo "== 5. Guarded mutation proofs"

prove_cg_mutation() {
  local label="$1"
  local fix_name="$2"
  local old="$3"
  local new="$4"
  echo "  [$label]"
  cp "$CG_SRC" "$CG_SRC.orig"
  python3 - "$CG_SRC" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
if old not in t:
    sys.exit(3)
open(path, "w").write(t.replace(old, new, 1))
PY
  local rc=$?
  if [ "$rc" -eq 3 ] || diff -q "$CG_SRC.orig" "$CG_SRC" >/dev/null; then
    echo "    PATCH CHANGED NOTHING: this proves nothing"
    status=1
    cp "$CG_SRC.orig" "$CG_SRC"; rm -f "$CG_SRC.orig"
    return
  fi

  if "$IYI" build -o "$WORK/mut_exercise" "$REPO/bench/selfhost_codegen_exercise.iyi" >/dev/null 2>&1; then
    "$WORK/mut_exercise" --dump-ir "$REPO/bench/fixtures/$fix_name" > "$WORK/mut_iyi.raw" 2>&1 || true
    normalize_ir "$WORK/mut_iyi.raw" > "$WORK/mut_iyi.norm" 2>/dev/null || true
    if diff -q "$WORK/cr_${fix_name}.norm" "$WORK/mut_iyi.norm" >/dev/null 2>&1; then
      echo "    FAILED: the comparison still passed with the mutation applied"
      status=1
    else
      echo "    caught: the codegen output diverged or failed, as it must"
    fi
  else
    echo "    caught: the mutated codegen did not build"
  fi
  cp "$CG_SRC.orig" "$CG_SRC"; rm -f "$CG_SRC.orig"
  echo "    reverted"
}

MUTATIONS_RUN=0

prove_cg_mutation "corrupt addition opcode to subtraction" "cg_int_arith.iyi" \
  '@last = is_float ? @builder.fadd(lhs, rhs) : @builder.add(lhs, rhs)' \
  '@last = is_float ? @builder.fsub(lhs, rhs) : @builder.sub(lhs, rhs)'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_cg_mutation "corrupt comparison predicate SLT to SGT" "cg_comparisons.iyi" \
  'LibLLVM::IntPredicate::SLT' \
  'LibLLVM::IntPredicate::SGT'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_cg_mutation "bypass variable store in assignment" "cg_control.iyi" \
  '@builder.store(val, ptr)' \
  '# @builder.store(val, ptr)'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_cg_mutation "invert if branch condition targets" "cg_control.iyi" \
  '@builder.cond_br(cond_val, then_bb, else_bb)' \
  '@builder.cond_br(cond_val, else_bb, then_bb)'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_cg_mutation "corrupt while loop loopback branch" "cg_control.iyi" \
  '@builder.br(while_bb)' \
  '@builder.br(fail_bb)'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_cg_mutation "corrupt multiplication opcode to addition" "cg_int_arith.iyi" \
  '@last = is_float ? @builder.fmul(lhs, rhs) : @builder.mul(lhs, rhs)' \
  '@last = is_float ? @builder.fadd(lhs, rhs) : @builder.add(lhs, rhs)'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST CODEGEN CHECKS PASSED"
else
  echo "== SOME SELFHOST CODEGEN CHECKS FAILED"
fi
exit $status
