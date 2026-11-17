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
. "$REPO/bench/lib/mutation.sh"
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
CG_SRC="$REPO/src/compiler/codegen/codegen.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Refusal fixtures: iyi refuses these programs, so they have no IR to compare.
# Each list names the oracle it is compared with, in sections 3b, 3b2 and 3c.
#   REFUSAL_FIXTURES: the oracle under its default prelude. It refuses `rescue`
#     and `ensure` in an iyi file, and the port must match its whole text.
#   EMPTY_REFUSAL_FIXTURES: the oracle under --prelude=empty, the prelude the
#     parity lists use. There is no definition of `raise` or `__crystal_raise`,
#     so the oracle refuses the call, and the port must match its whole text.
#   PORT_LIMIT_FIXTURES: the oracle is not asked for a verdict. The port cannot
#     type a construct in these, so it must refuse by name and write no IR.
REFUSAL_FIXTURES="cg_exceptions.iyi cg_raise.iyi"
EMPTY_REFUSAL_FIXTURES="cg_undefined_raise.iyi cg_undefined_runtime_raise.iyi"
PORT_LIMIT_FIXTURES="cg_splat_loop.iyi"
# Whole programs, each with its own `fun main`: a C runner cannot link them with the other fixtures, and the Crystal oracle
# refuses their @[Unsafe] header. They are compared by the exit status of their hosted and port builds (section 3e).
PROGRAM_FIXTURES="cg_macro_site.iyi cg_macro_target.iyi cg_call_on_call.iyi"
is_refusal() {
  case " $REFUSAL_FIXTURES $EMPTY_REFUSAL_FIXTURES $PORT_LIMIT_FIXTURES $PROGRAM_FIXTURES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

if command -v brew >/dev/null 2>&1; then
  LIBRARY_PATH="$(brew --prefix bdw-gc)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export LIBRARY_PATH
fi
export CRYSTAL_CACHE_DIR="${TMPDIR:-/tmp}/iyi-cg-cache"
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

# The require shares the fixture's first line: a line of its own shifted every
# location the oracle reports by one, which the port's own numbers then missed.
src = %(require "primitives"; ) + File.read(fixture)
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
  base="$(basename "$fixture")"
  is_refusal "$base" && continue
  fixture_count=$((fixture_count + 1))

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

# Runs the oracle and the port on one refusal fixture from the repo root, on the
# same relative path, so both print the same location lines. It passes only when
# the whole stderr text and the exit status are identical. $1 is the fixture and
# $2 the oracle's extra flags. The oracle's text is kept for check_refusal_mutant.
refusal_check() {
  local name="$1" flags="$2" oracle_out oracle_status port_out port_status
  local rel="bench/fixtures/$name"
  oracle_out="$(cd "$REPO" && "$IYI" build $flags -o "$WORK/oracle_refusal_$name" "$rel" 2>&1)"
  oracle_status=$?
  printf '%s\n' "$oracle_out" > "$WORK/oracle_refusal_$name.txt"
  printf '%s\n' "$oracle_status" > "$WORK/oracle_refusal_$name.status"
  port_out="$(cd "$REPO" && "$WORK/exercise" --dump-ir "$rel" 2>&1)"
  port_status=$?
  if [ "$oracle_status" -ne 0 ] && [ "$oracle_status" -eq "$port_status" ] && [ "$oracle_out" = "$port_out" ]; then
    echo "  $name: refused with the oracle's text and exit $port_status"
    return 0
  fi
  echo "  FAIL: $name: oracle exit $oracle_status, port exit $port_status"
  echo "    oracle: $oracle_out"
  echo "    port:   $port_out"
  return 1
}

echo "== 3b. Refusal fixtures: the port must refuse each with the oracle's whole text and exit status"
echo "   (oracle: its default prelude, which refuses rescue and ensure)"
refusal_count=0
refusal_diverged=0
for name in $REFUSAL_FIXTURES; do
  refusal_count=$((refusal_count + 1))
  refusal_check "$name" "" || refusal_diverged=$((refusal_diverged + 1))
done
echo "  Refusal summary: $((refusal_count - refusal_diverged))/$refusal_count refusal fixtures match the oracle's message and exit status"
[ "$refusal_diverged" -eq 0 ] || status=1

echo "== 3b2. Refusal fixtures against the oracle under --prelude=empty"
echo "   (the prelude the parity lists use, which has no raise or __crystal_raise)"
empty_count=0
empty_diverged=0
for name in $EMPTY_REFUSAL_FIXTURES; do
  empty_count=$((empty_count + 1))
  refusal_check "$name" "--prelude=empty" || empty_diverged=$((empty_diverged + 1))
done
echo "  Empty-prelude refusal summary: $((empty_count - empty_diverged))/$empty_count refusal fixtures match the oracle's message and exit status"
[ "$empty_diverged" -eq 0 ] || status=1

echo "== 3c. Port limitations: the port must refuse each by name and write no IR"
echo "   (the oracle accepts or refuses these with its own wording, so no oracle text is compared)"
limit_count=0
limit_diverged=0
for name in $PORT_LIMIT_FIXTURES; do
  limit_count=$((limit_count + 1))
  port_out="$(cd "$REPO" && "$WORK/exercise" --dump-ir "bench/fixtures/$name" 2>&1)"
  port_status=$?
  if [ "$port_status" -ne 0 ] && printf '%s\n' "$port_out" | grep -q '^Error: port limitation: the port cannot '; then
    echo "  $name: port limitation, refused by name (exit $port_status): $(printf '%s\n' "$port_out" | grep '^Error: ' | head -1)"
  else
    echo "  FAIL: $name: the port did not refuse by name (exit $port_status): $port_out"
    limit_diverged=$((limit_diverged + 1))
  fi
done
echo "  Port-limitation summary: $((limit_count - limit_diverged))/$limit_count port limitations refused by name"
[ "$limit_diverged" -eq 0 ] || status=1

echo "== 3d. Forward references: a struct field may name a type defined later, with no panic"
echo "   (a probe, not a parity fixture: the port emits every method of a type, while the oracle emits the reachable ones)"
probe_status=0
if (cd "$REPO" && "$WORK/exercise" --dump-ir "bench/fixtures/fwd_struct_probe.iyi" >/dev/null 2>&1); then
  echo "  fwd_struct_probe.iyi: compiles, the field's struct type is laid out before its use"
else
  echo "  FAIL: fwd_struct_probe.iyi did not compile"
  status=1
fi

echo
echo "== 3e. Program fixtures: whole programs compared by exit status"
echo "    No IR or C-runner comparison: the oracle refuses their @[Unsafe] header, and each defines fun main."
port_built=1
if ! "$IYI" build -o "$WORK/port" "$REPO/src/compiler/tools/compile.iyi" > "$WORK/port.build.log" 2>&1; then
  echo "  FAIL: the port did not build"
  status=1
  port_built=0
fi
for base in $PROGRAM_FIXTURES; do
  fixture="$REPO/bench/fixtures/$base"
  stem="${base%.iyi}"
  hosted_rc="missing"
  port_rc="missing"
  if "$IYI" build -o "$WORK/prog_hosted_$stem" "$fixture" > "$WORK/prog_hosted_$stem.log" 2>&1; then
    "$WORK/prog_hosted_$stem" > /dev/null 2>&1
    hosted_rc=$?
  fi
  if [ "$port_built" = 1 ] && "$WORK/port" "$fixture" -o "$WORK/prog_port_$stem" > "$WORK/prog_port_$stem.log" 2>&1; then
    "$WORK/prog_port_$stem" > /dev/null 2>&1
    port_rc=$?
  fi
  if [ "$hosted_rc" != "missing" ] && [ "$port_rc" = "$hosted_rc" ]; then
    echo "  $base: the port's exit $port_rc equals the hosted build's exit $hosted_rc"
  else
    echo "  FAIL: $base: hosted exit $hosted_rc, port exit $port_rc"
    status=1
  fi
done
echo
echo "== 4. Emitted native object linking and C driver execution comparison"
for fixture in "$REPO"/bench/fixtures/cg_*.iyi; do
  [ -f "$fixture" ] || continue
  is_refusal "$(basename "$fixture")" && continue
  base="$(basename "$fixture" .iyi)"
  "$WORK/exercise" --emit-obj "$fixture" "$WORK/iyi_${base}.o"
  "$WORK/dump_crystal_cg" --emit-obj "$fixture" "$WORK/cr_${base}.o"
done

CC="${CC:-$(command -v clang || command -v cc || command -v gcc)}"
if ! $CC "$REPO/bench/fixtures/cg_runner.c" "$WORK"/iyi_*.o -o "$WORK/iyi_runner" > "$WORK/iyi_runner.build.log" 2>&1 || [ ! -x "$WORK/iyi_runner" ]; then
  echo "  FAIL: failed to build pure iyi C runner:"
  cat "$WORK/iyi_runner.build.log"
  status=1
fi
if ! $CC "$REPO/bench/fixtures/cg_runner.c" "$WORK"/cr_*.o -o "$WORK/cr_runner" > "$WORK/cr_runner.build.log" 2>&1 || [ ! -x "$WORK/cr_runner" ]; then
  echo "  FAIL: failed to build Crystal oracle C runner:"
  cat "$WORK/cr_runner.build.log"
  status=1
fi

"$WORK/iyi_runner" > "$WORK/iyi_runner.out" 2>&1 || status=1
"$WORK/cr_runner" > "$WORK/cr_runner.out" 2>&1 || status=1

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

check_cg_mutant() {
  local fixture="$1"
  "$IYI" build -o "$WORK/mut_exercise" "$REPO/bench/selfhost_codegen_exercise.iyi" >/dev/null 2>&1 || return 1
  "$WORK/mut_exercise" --dump-ir "$REPO/bench/fixtures/$fixture" > "$WORK/mut_iyi.raw" 2>&1 || true
  normalize_ir "$WORK/mut_iyi.raw" > "$WORK/mut_iyi.norm" 2>/dev/null || true
  diff -q "$WORK/cr_${fixture}.norm" "$WORK/mut_iyi.norm" >/dev/null 2>&1
}

# Rebuilds the port with a mutated backend and asks it to refuse the fixture. The
# check passes, meaning not caught, only while the refusal still matches the
# oracle's whole text and exit status recorded in section 3b or 3b2.
check_refusal_mutant() {
  local name="$1" got got_status
  "$IYI" build -o "$WORK/mut_exercise" "$REPO/bench/selfhost_codegen_exercise.iyi" >/dev/null 2>&1 || return 1
  got="$(cd "$REPO" && "$WORK/mut_exercise" --dump-ir "bench/fixtures/$name" 2>&1)"
  got_status=$?
  [ "$got_status" = "$(cat "$WORK/oracle_refusal_$name.status")" ] && [ "$got" = "$(cat "$WORK/oracle_refusal_$name.txt")" ]
}
# Rebuilds the port with a mutated backend and runs it on a forward-reference probe.
# The probe compiles only while the port lays out the struct before its use, so a
# panic or a refusal is detected. Returns zero (not caught) while it compiles.
check_probe_mutant() {
  local name="$1"
  "$IYI" build -o "$WORK/mut_exercise" "$REPO/bench/selfhost_codegen_exercise.iyi" >/dev/null 2>&1 || return 1
  (cd "$REPO" && "$WORK/mut_exercise" --dump-ir "bench/fixtures/$name" >/dev/null 2>&1)
}

# Rebuilds the port with a mutated IR and runs the standalone check, which proves the builder's name claims.
# Returns zero (not caught) only while the check still prints its passing line.
check_standalone_mutant() {
  "$IYI" build -o "$WORK/mut_exercise" "$REPO/bench/selfhost_codegen_exercise.iyi" >/dev/null 2>&1 || return 1
  "$WORK/mut_exercise" 2>&1 | grep -qF "ALL SELFHOST CODEGEN CHECKS PASSED SUCCESSFULLY!"
}

# Rebuilds the port with the unresolved-call refusal silenced too, and asks it to
# write IR for a port-limit fixture. cg_splat_loop.iyi is refused by an unresolved
# call before its binary operand, so the port refuses it by name only while both
# refusals stand. prove_mutation has already silenced the binary operand; this
# silences the call. It passes, meaning not caught, only while the fixture is
# still refused by name, and the caller's copy of the source is restored.
check_port_limit_mutant() {
  local name="$1" keep="$WORK/cg_first_mutant.iyi" built out got_status
  cp "$CG_SRC" "$keep" || return 1
  python3 - "$CG_SRC" <<'PY' || { cp "$keep" "$CG_SRC"; return 1; }
import sys
p = sys.argv[1]
s = open(p).read()
call = "refuse_undefined_call(node)"
if s.count(call) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(call, "nil", 1))
PY
  "$IYI" build -o "$WORK/mut_limit" "$REPO/bench/selfhost_codegen_exercise.iyi" >/dev/null 2>&1
  built=$?
  cp "$keep" "$CG_SRC"
  [ "$built" -eq 0 ] || return 1
  out="$(cd "$REPO" && "$WORK/mut_limit" --dump-ir "bench/fixtures/$name" 2>&1)"
  got_status=$?
  [ "$got_status" -ne 0 ] && printf '%s\n' "$out" | grep -q '^Error: port limitation: the port cannot '
}

MUTATIONS_RUN=0

prove_mutation "corrupt addition opcode to subtraction" "$CG_SRC" \
  '@last = is_float ? @builder.fadd(lhs, rhs) : @builder.add(lhs, rhs)' \
  '@last = is_float ? @builder.fsub(lhs, rhs) : @builder.sub(lhs, rhs)' \
  -- check_cg_mutant cg_int_arith.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt comparison predicate SLT to SGT" "$CG_SRC" \
  'IntPredicate::SLT' \
  'IntPredicate::SGT' \
  -- check_cg_mutant cg_comparisons.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "bypass variable store in assignment" "$CG_SRC" \
  's_inst = @builder.store(val_to_store, ptr)' \
  's_inst = @builder.load(val_to_store.type, ptr)' \
  -- check_cg_mutant cg_control.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "invert if branch condition targets" "$CG_SRC" \
  '@builder.cond_br(cond_val, then_bb, else_bb)' \
  '@builder.cond_br(cond_val, else_bb, then_bb)' \
  -- check_cg_mutant cg_control.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt while loop loopback branch" "$CG_SRC" \
  '@builder.br(while_bb)' \
  '@builder.br(fail_bb)' \
  -- check_cg_mutant cg_control.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt multiplication opcode to addition" "$CG_SRC" \
  '@last = is_float ? @builder.fmul(lhs, rhs) : @builder.mul(lhs, rhs)' \
  '@last = is_float ? @builder.fadd(lhs, rhs) : @builder.add(lhs, rhs)' \
  -- check_cg_mutant cg_int_arith.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# The IR normaliser rewrites every type_id value to <ID>, so no mutation of
# the value can ever be observed here, and renaming the global is masked by
# lazy sites that create a correctly named one on demand. This anchors on the
# global's constness, which the comparison does see: `internal constant`
# becomes `internal global`.
prove_mutation "corrupt module-level class type_id global" "$CG_SRC" \
  'tid_global.global_constant = true' \
  'tid_global.global_constant = false' \
  -- check_cg_mutant cg_classes.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "corrupt virtual hierarchy match range predicate" "$CG_SRC" \
  'sge = builder.icmp(IntPredicate::SGE, arg0, min_val)' \
  'sge = builder.icmp(IntPredicate::SLT, arg0, min_val)' \
  -- check_cg_mutant cg_virtual_dispatch.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt nilable null check predicate" "$CG_SRC" \
  'res = @builder.icmp(IntPredicate::EQ, l_nil_tid2, sel)' \
  'res = @builder.icmp(IntPredicate::NE, l_nil_tid2, sel)' \
  -- check_cg_mutant cg_nilable.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt block body evaluation during yield" "$CG_SRC" \
  'inlined.block_body.accept(self)' \
  '# inlined.block_body.accept(self)' \
  -- check_cg_mutant cg_blocks.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt closure environment store" "$CG_SRC" \
  'st = @builder.store(cval, slot)' \
  '# st = @builder.store(cval, slot)' \
  -- check_cg_mutant cg_closures.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt string literal constant global name delimiter" "$CG_SRC" \
  "io << \"'\"" \
  "io << \"$\"" \
  -- check_cg_mutant cg_strings.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt generic constructor name mangling" "$CG_SRC" \
  '"*#{info.name}^#{gname}::new<#{arg_type_names.join(", ")}>:#{info.name}"' \
  '"*#{info.name}^#{gname}::corrupted_new<#{arg_type_names.join(", ")}>:#{info.name}"' \
  -- check_cg_mutant cg_generics.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt class field offset index shift" "$CG_SRC" \
  'idx = info.is_struct ? fidx : fidx + 1' \
  'idx = info.is_struct ? fidx : fidx + 5' \
  -- check_cg_mutant cg_layouts.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "restore first-assignment-wins for local slot types" "$CG_SRC" \
  '      if t == "Nil"' \
  '      if t == "Nil!"' \
  -- check_cg_mutant cg_nil_local.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "unless lowering swaps its branches" "$CG_SRC" \
  'lowered = If.new(node.cond, node.else, node.then)' \
  'lowered = If.new(node.cond, node.then, node.else)' \
  -- check_cg_mutant cg_unless.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt proc literal symbol joiner back to at-sign" "$CG_SRC" \
  '^#{symbol_text(rel_file)}' \
  '@#{symbol_text(rel_file)}' \
  -- check_cg_mutant cg_closures.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt the rescue refusal message" "$CG_SRC" \
  '"iyi has no exceptions to rescue: an error' \
  '"iyi has no exceptions to catch: an error' \
  -- check_refusal_mutant cg_exceptions.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt the ensure refusal message" "$CG_SRC" \
  '"iyi has no `ensure`: a panic' \
  '"iyi has no ensure: a panic' \
  -- check_refusal_mutant cg_raise.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# The rescue refusal is a located one: it prints the source line and exits in
# codegen.iyi's own refusal, not through foundation/errors.iyi's refuse_port.
prove_mutation_all "corrupt the located refusal's exit status" "$CG_SRC" \
  '  exit(1)' \
  '  exit(0)' \
  -- check_refusal_mutant cg_exceptions.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# The by-name refusals (a call or an operand the port cannot resolve) exit
# through refuse_port. The port-limit fixture is the one that reaches it: the
# check holds only while the port still refuses it by name with a status that
# is not zero, which is what section 3c requires.
check_port_limit_status() {
  local name="$1" got got_status
  "$IYI" build -o "$WORK/mut_exercise" "$REPO/bench/selfhost_codegen_exercise.iyi" >/dev/null 2>&1 || return 1
  got="$(cd "$REPO" && "$WORK/mut_exercise" --dump-ir "bench/fixtures/$name" 2>&1)"
  got_status=$?
  [ "$got_status" -ne 0 ] && printf '%s\n' "$got" | grep -q '^Error: port limitation: the port cannot '
}
prove_mutation_all "corrupt refuse_port's exit status" "$REPO/src/compiler/foundation/errors.iyi" \
  '  exit(1)' \
  '  exit(0)' \
  -- check_port_limit_status cg_splat_loop.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "drop the exit block of a statement if with no else" "$CG_SRC" \
  '        exit_bb = fn.append_basic_block("exit")
        @builder.br(exit_bb)
      end

      # The false edge' \
  '        exit_bb = nil
      end

      # The false edge' \
  -- check_cg_mutant cg_nil_local.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "read a named struct type before it is created" "$CG_SRC" \
  '    st = @types.struct_named(name)' \
  '    st = @llvm_struct_types[name]' \
  -- check_probe_mutant fwd_struct_probe.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt the undefined-method refusal wording" "$CG_SRC" \
  "    message = \"undefined method '#{node.name}' for top-level\"" \
  "    message = \"undefined method '#{node.name}' for toplevel\"" \
  -- check_refusal_mutant cg_undefined_raise.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# cg_splat_loop.iyi is refused by name at its binary operand once the call is
# silenced, and by the unresolved call while it stands. Both refusals must be
# silent before the port writes IR for it, so the proof silences both.
prove_mutation "return a constant for an unresolved binary operand" "$CG_SRC" \
  "refuse_port(\"port limitation: the port cannot type the #{side} operand '#{operand_text(operand)}' of '#{op_node.name}' in #{scope_name}, so it refuses instead of leaving the block unterminated (no IR is written)\")" \
  "return @builder.const_int(@types.int32, 0)" \
  -- check_port_limit_mutant cg_splat_loop.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a block name is not claimed in its function" "$REPO/src/compiler/ir/function.iyi" \
  '    block = Block.new(@symbols.claim(name))' \
  '    block = Block.new(name)' \
  -- check_standalone_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a parameter name is not claimed in its function" "$REPO/src/compiler/ir/function.iyi" \
  '    param.name = @symbols.claim(name)' \
  '    param.name = name' \
  -- check_standalone_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a placed instruction's name is not claimed" "$REPO/src/compiler/ir/builder.iyi" \
  '      inst.name = symbols.claim(inst.name)' \
  '      inst.name = inst.name' \
  -- check_standalone_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
# cg_call_on_call.iyi reads its String result's bytesize from the field's slot. Read the type id slot instead and the exit moves.
check_call_result_mutant() {
  "$IYI" build -o "$WORK/mut_port" "$REPO/src/compiler/tools/compile.iyi" > "$WORK/mut_port.log" 2>&1 || return 1
  "$WORK/mut_port" "$REPO/bench/fixtures/cg_call_on_call.iyi" -o "$WORK/mut_exe" > "$WORK/mut_exe.log" 2>&1 || return 1
  "$WORK/mut_exe" > /dev/null 2>&1
  [ "$?" -eq 10 ]
}
prove_mutation "a field of a call result is read from the type id slot" "$CG_SRC" \
  'r_info.fields[node.name] + 1)])' \
  'r_info.fields[node.name] + 0)])' \
  -- check_call_result_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST CODEGEN CHECKS PASSED"
else
  echo "== SOME SELFHOST CODEGEN CHECKS FAILED"
fi
exit $status
