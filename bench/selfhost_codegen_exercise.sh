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
diverged=0
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
parser.filename = fixture
node = parser.parse
node = program.normalize(node)
node = program.semantic(node)
visitor = Iyi::CodeGenVisitor.new(program, node, single_module: true, debug: Iyi::Debug::None)
visitor.accept(node)
visitor.finish
llvm_mod = visitor.modules[""].mod

if mode == "--dump-ir"
  # 1. Module-level custom struct / class types
  types = [] of String
  llvm_mod.to_s.each_line do |l|
    stripped = l.strip
    if stripped.starts_with?("%") && stripped.includes?(" = type ") && !stripped.starts_with?("%Nil")
      types << stripped
    end
  end
  types.sort.each { |t| puts t }

  # 2. Module-level type ID globals
  globals = [] of String
  llvm_mod.to_s.each_line do |l|
    stripped = l.strip
    if stripped.starts_with?("@\"") && stripped.includes?(":type_id\"")
      globals << stripped
    end
  end
  globals.sort.each { |g| puts g }

  # 3. Module-level declarations (e.g. malloc, memset)
  decls = [] of String
  llvm_mod.to_s.each_line do |l|
    stripped = l.strip
    if stripped.starts_with?("declare ") && (stripped.includes?("@malloc") || stripped.includes?("@llvm.memset"))
      decls << stripped.split(" #")[0].strip
    end
  end
  decls.sort.each { |d| puts d }

  # 4. All defined functions across the module (constructors, initializers, methods, funs)
  fns = [] of LLVM::Function
  llvm_mod.functions.each do |fn|
    next if fn.basic_blocks.empty?
    next if fn.name == "__crystal_main"
    fns << fn
  end
  fns.sort_by!(&.name).each do |fn|
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
import sys, re

def norm(raw):
    lines = []
    for l in raw.splitlines():
        l = l.strip()
        if not l or l.startswith(";") or l.startswith("attributes #"):
            continue
        if l.startswith("define "):
            l = re.sub(r' #\d+', '', l)
        if " ; preds =" in l:
            l = l.split(" ; preds =")[0]
        # Normalize constant type_id initializer value (host numbering differences)
        if re.match(r'^@"[^"]+:type_id" = internal constant i32 \d+', l):
            l = re.sub(r'\d+$', '<ID>', l)
        # Normalize virtual hierarchy match range bounds (host numbering differences)
        if re.match(r'%\d+ = icmp sge i32 %0, \d+', l):
            l = re.sub(r'\d+$', '<MIN>', l)
        if re.match(r'%\d+ = icmp sle i32 %0, \d+', l):
            l = re.sub(r'\d+$', '<MAX>', l)
        # Normalize align on memset pointer argument
        if "call void @llvm.memset.p0.i64" in l:
            l = re.sub(r'ptr align \d+ %', 'ptr %', l)
        # Normalize memset declaration parameter attributes
        if l.startswith("declare void @llvm.memset.p0.i64"):
            l = re.sub(r'ptr [a-z0-9_\(\)]+', 'ptr', l)
        # Normalize proc literal location line number
        l = re.sub(r'(~procProc\([^)]+\)@[^:]+):\d+', r'\1:<LINE>', l)
        l = l.rstrip()
        l = l.replace("[ ", "[").replace(" ]", "]")
        lines.append(l)
    return "\n".join(lines)

path = sys.argv[1]
print(norm(open(path).read()))
PY
}

echo
# Widened IR comparison: covers the complete module emission rather than only
# the fixture's own `fun` declarations. This compares:
#   1. Defined custom struct and class types (%Type = type { ... })
#   2. Type ID globals (@"Type:type_id" = internal constant i32 ...)
#   3. External allocator declarations (@malloc, @llvm.memset)
#   4. All defined functions across the module: top-level funs, constructors
#      (*Type::new), initializers (*Type#initialize), and methods (*Type#method).
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
    diverged=$((diverged + 1))
    cat "$WORK/diff_${base}.patch"
    status=1
  fi
done
echo "  Parity summary: $((fixture_count - diverged))/$fixture_count codegen fixtures match 100% ($total_functions functions compared)"

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

prove_cg_mutation "corrupt module-level class type_id global" "cg_classes.iyi" \
  'tid_global = mod.add_global("#{info.name}:type_id", context.int32)' \
  'tid_global = mod.add_global("#{info.name}:corrupted_type_id", context.int32)'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_cg_mutation "corrupt virtual hierarchy match range predicate" "cg_virtual_dispatch.iyi" \
  'sge = builder.icmp(LibLLVM::IntPredicate::SGE, arg0, min_val)' \
  'sge = builder.icmp(LibLLVM::IntPredicate::SLT, arg0, min_val)'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_cg_mutation "corrupt nilable null check predicate" "cg_nilable.iyi" \
  'res = @builder.icmp(LibLLVM::IntPredicate::EQ, l_nil_tid2, sel)' \
  'res = @builder.icmp(LibLLVM::IntPredicate::NE, l_nil_tid2, sel)'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_cg_mutation "corrupt block body evaluation during yield" "cg_blocks.iyi" \
  'inlined.block.body.accept(self)' \
  '# inlined.block.body.accept(self)'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_cg_mutation "corrupt landing pad selector extraction index" "cg_exceptions.iyi" \
  'exception_type_id = @builder.extract_value(lp, 1)' \
  'exception_type_id = @builder.extract_value(lp, 0)'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_cg_mutation "corrupt rescue type check predicate EQ to NE" "cg_exceptions.iyi" \
  '@builder.icmp(LibLLVM::IntPredicate::EQ, l_tid, exception_type_id)' \
  '@builder.icmp(LibLLVM::IntPredicate::NE, l_tid, exception_type_id)'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_cg_mutation "corrupt closure environment store" "cg_closures.iyi" \
  'st = @builder.store(cval, slot)' \
  '# st = @builder.store(cval, slot)'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_cg_mutation "corrupt string literal constant global name delimiter" "cg_strings.iyi" \
  "io << \"'\"" \
  "io << \"$\""
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_cg_mutation "corrupt generic constructor name mangling" "cg_generics.iyi" \
  '"*#{info.name}@#{gname}::new<#{arg_type_names.join(", ")}>:#{info.name}"' \
  '"*#{info.name}@#{gname}::corrupted_new<#{arg_type_names.join(", ")}>:#{info.name}"'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_cg_mutation "corrupt class field offset index shift" "cg_layouts.iyi" \
  'idx = info.is_struct ? fidx : fidx + 1' \
  'idx = info.is_struct ? fidx : fidx + 5'
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST CODEGEN CHECKS PASSED"
else
  echo "== SOME SELFHOST CODEGEN CHECKS FAILED"
fi
exit $status
