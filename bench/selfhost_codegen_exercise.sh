#!/usr/bin/env bash
# Fails when the pure-iyi code generation pass stops agreeing with the
# hosted front end backend it replaces.
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
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  echo "FAILED: a functional Python interpreter is required" >&2
  exit 1
fi
. "$REPO/bench/lib/mutation.sh"
# The LLVM bridge reads its version, targets and link flags from build arguments this host supplies: read them once.
LLVM_BRIDGE_ARGS=()
llvm_bridge_text=$(llvm_bridge_build_args) || { echo "FAILED: no LLVM build arguments for this host, see the sentence above"; exit 1; }
while IFS= read -r llvm_arg; do LLVM_BRIDGE_ARGS+=("$llvm_arg"); done <<< "$llvm_bridge_text"
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
CRYSTAL="${CRYSTAL:-crystal}"
CG_SRC="$REPO/src/compiler/codegen/codegen.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE="$(native_path "$REPO")" || exit 1
WORK_NATIVE="$(native_path "$WORK")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
exec 9>&1

# Preserve normal fixture exits 0..255 while distinguishing signals and timeouts.
run_fixture() {
  "$PY" - "$(native_path "$1")" "$(native_path "$2")" "$(native_path "$3")" <<'PY'
import os, signal, subprocess, sys
exe, out, err = sys.argv[1:]
try:
    with open(out, "wb") as stdout, open(err, "wb") as stderr:
        proc = subprocess.Popen([exe], stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                start_new_session=(os.name != "nt"))
        try:
            rc = proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                proc.kill()
            else:
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            print("timeout")
        else:
            print(rc if 0 <= rc <= 255 else "signal:%s" % (-rc) if rc < 0 else "invalid-exit:%s" % rc)
except OSError as exc:
    print("launch-error:%s" % exc)
PY
}

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
export CRYSTAL_CACHE_DIR="$WORK_NATIVE/cache"
export CRYSTAL_PATH="$REPO_NATIVE/src"

echo "== 1. Building and running pure iyi codegen standalone check"
if ! "$IYI" build "${LLVM_BRIDGE_ARGS[@]}" -o "$WORK_NATIVE/exercise$EXE" "$REPO_NATIVE/bench/selfhost_codegen_exercise.iyi" > "$WORK/exercise.build.log" 2>&1; then
  cat "$WORK/exercise.build.log"
  exit 1
fi
if ! "$WORK/exercise$EXE" > "$WORK/plain.out" 2>&1; then
  cat "$WORK/plain.out"
  exit 1
fi
cat "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST CODEGEN CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "FAIL: standalone codegen verification failed"
  exit 1
fi

echo
echo "== 2. Building hosted oracle for differential codegen verification"
cat <<'HOSTED_ORACLE_SCRIPT' > "$WORK/dump_crystal_cg.cr"
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
HOSTED_ORACLE_SCRIPT

if ! LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO_NATIVE/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK_NATIVE/dump_crystal_cg$EXE" "$WORK_NATIVE/dump_crystal_cg.cr" > "$WORK/oracle.build.log" 2>&1; then
  cat "$WORK/oracle.build.log"
  exit 1
fi

normalize_ir() {
  "$PY" - "$(native_path "$1")" <<'PY'
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
echo "== 3. Textual LLVM IR comparison against the hosted backend being replaced"
fixture_count=0
total_functions=0

for fixture in "$REPO"/bench/fixtures/cg_*.iyi; do
  [ -f "$fixture" ] || continue
  base="$(basename "$fixture")"
  is_refusal "$base" && continue
  fixture_count=$((fixture_count + 1))

  fixture_native="$(native_path "$fixture")" || exit 1
  if ! "$WORK/exercise$EXE" --dump-ir "$fixture_native" > "$WORK/iyi_${base}.raw" 2>"$WORK/iyi_${base}.err" ||
     ! "$WORK/dump_crystal_cg$EXE" --dump-ir "$fixture_native" > "$WORK/cr_${base}.raw" 2>"$WORK/cr_${base}.err" ||
     ! normalize_ir "$WORK/iyi_${base}.raw" > "$WORK/iyi_${base}.norm" ||
     ! normalize_ir "$WORK/cr_${base}.raw" > "$WORK/cr_${base}.norm"; then
    echo "  FAIL: could not generate or normalize IR for $fixture"
    cat "$WORK/iyi_${base}.err" "$WORK/cr_${base}.err" 2>/dev/null
    diverged=$((diverged + 1))
    status=1
    continue
  fi

  fn_count=$(grep -c "^define " "$WORK/iyi_${base}.norm" || true)
  total_functions=$((total_functions + fn_count))

  if diff -u "$WORK/cr_${base}.norm" "$WORK/iyi_${base}.norm" > "$WORK/diff_${base}.patch"; then
    touch "$WORK/ir_baseline_$base"
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
  local name="$1" flags="$2" oracle_status port_status
  local fixture="bench/fixtures/$name"
  (cd "$REPO" && "$IYI" build $flags -o "$WORK_NATIVE/oracle_refusal_$name$EXE" "$fixture") >"$WORK/oracle_refusal_$name.out" 2>"$WORK/oracle_refusal_$name.err"
  oracle_status=$?
  cat "$WORK/oracle_refusal_$name.out" "$WORK/oracle_refusal_$name.err" >"$WORK/oracle_refusal_$name.txt"
  printf '%s\n' "$oracle_status" > "$WORK/oracle_refusal_$name.status"
  (cd "$REPO" && "$WORK/exercise$EXE" --dump-ir "$fixture") >"$WORK/port_refusal_$name.out" 2>"$WORK/port_refusal_$name.err"
  port_status=$?
  if [ "$oracle_status" -eq 1 ] && [ "$port_status" -eq 1 ] &&
     cmp -s "$WORK/oracle_refusal_$name.out" "$WORK/port_refusal_$name.out" &&
     cmp -s "$WORK/oracle_refusal_$name.err" "$WORK/port_refusal_$name.err" &&
     grep -Fq "In $fixture:" "$WORK/oracle_refusal_$name.err" &&
     grep -q '^Error: ' "$WORK/oracle_refusal_$name.err"; then
    touch "$WORK/refusal_baseline_$name"
    echo "  $name: refused with the oracle's text and exit $port_status"
    return 0
  fi
  echo "  FAIL: $name: oracle exit $oracle_status, port exit $port_status"
  echo "    oracle:"; cat "$WORK/oracle_refusal_$name.out" "$WORK/oracle_refusal_$name.err"
  echo "    port:"; cat "$WORK/port_refusal_$name.out" "$WORK/port_refusal_$name.err"
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
  port_out="$(cd "$REPO" && "$WORK/exercise$EXE" --dump-ir "$REPO_NATIVE/bench/fixtures/$name" 2>&1)"
  port_status=$?
  printf '%s\n' "$port_out" > "$WORK/limit_baseline_$name.log"
  if expected_refusal "$port_status" "$WORK/limit_baseline_$name.log" refuse_port "^port limitation: the port cannot resolve the call '.*' in '.*', so it refuses instead of leaving the call out of the IR \\(no IR is written\\)$"; then
    touch "$WORK/limit_baseline_$name"
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
if (cd "$REPO" && "$WORK/exercise$EXE" --dump-ir "$REPO_NATIVE/bench/fixtures/fwd_struct_probe.iyi" >"$WORK/forward.baseline" 2>"$WORK/forward.err") &&
   grep -q 'Holder' "$WORK/forward.baseline" && grep -q 'Inner' "$WORK/forward.baseline"; then
  touch "$WORK/forward.baseline.ok"
  echo "  fwd_struct_probe.iyi: compiles, the field's struct type is laid out before its use"
else
  echo "  FAIL: fwd_struct_probe.iyi did not compile"
  status=1
fi

echo
echo "== 3e. Program fixtures: whole programs compared by exit status"
echo "    No IR or C-runner comparison: the oracle refuses their @[Unsafe] header, and each defines fun main."
port_built=1
if ! "$IYI" build "${LLVM_BRIDGE_ARGS[@]}" -o "$WORK_NATIVE/port$EXE" "$REPO_NATIVE/src/compiler/tools/compile.iyi" > "$WORK/port.build.log" 2>&1; then
  echo "  FAIL: the port did not build"
  cat "$WORK/port.build.log"
  status=1
  port_built=0
fi
for base in $PROGRAM_FIXTURES; do
  fixture="$REPO/bench/fixtures/$base"
  stem="${base%.iyi}"
  hosted_rc="missing"
  port_rc="missing"
  if "$IYI" build -o "$WORK_NATIVE/prog_hosted_$stem$EXE" "$(native_path "$fixture")" > "$WORK/prog_hosted_$stem.log" 2>&1; then
    hosted_rc="$(run_fixture "$WORK/prog_hosted_$stem$EXE" "$WORK/prog_hosted_$stem.out" "$WORK/prog_hosted_$stem.err")"
  fi
  if [ "$port_built" = 1 ] && "$WORK/port$EXE" "$(native_path "$fixture")" -o "$WORK_NATIVE/prog_port_$stem$EXE" > "$WORK/prog_port_$stem.log" 2>&1; then
    port_rc="$(run_fixture "$WORK/prog_port_$stem$EXE" "$WORK/prog_port_$stem.out" "$WORK/prog_port_$stem.err")"
  fi
  if [[ "$hosted_rc" =~ ^[0-9]+$ ]] && [ "$port_rc" = "$hosted_rc" ]; then
    echo "  $base: the port's exit $port_rc equals the hosted build's exit $hosted_rc"
    if [ "$base" = cg_call_on_call.iyi ] && [ "$hosted_rc" -eq 10 ]; then
      touch "$WORK/call_result.baseline.ok"
    fi
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
  if ! "$WORK/exercise$EXE" --emit-obj "$(native_path "$fixture")" "$WORK_NATIVE/iyi_${base}.o" > "$WORK/iyi_obj.log" 2>&1 ||
     ! "$WORK/dump_crystal_cg$EXE" --emit-obj "$(native_path "$fixture")" "$WORK_NATIVE/cr_${base}.o" > "$WORK/cr_obj.log" 2>&1; then
    echo "  FAIL: object emission for $fixture"
    cat "$WORK/iyi_obj.log" "$WORK/cr_obj.log" 2>/dev/null
    status=1
  fi
done

CC="${CC:-$(command -v clang || command -v cc || command -v gcc || true)}"
if [ -z "$CC" ]; then
  echo "  FAIL: no host C compiler available"
  status=1
else
  iyi_objects=()
  cr_objects=()
  for object in "$WORK"/iyi_*.o; do [ -f "$object" ] && iyi_objects+=("$(native_path "$object")"); done
  for object in "$WORK"/cr_*.o; do [ -f "$object" ] && cr_objects+=("$(native_path "$object")"); done
  if ! "$CC" "$REPO_NATIVE/bench/fixtures/cg_runner.c" "${iyi_objects[@]}" -o "$WORK_NATIVE/iyi_runner$EXE" > "$WORK/iyi_runner.build.log" 2>&1; then
    echo "  FAIL: failed to build pure iyi C runner:"
    cat "$WORK/iyi_runner.build.log"
    status=1
  fi
  if ! "$CC" "$REPO_NATIVE/bench/fixtures/cg_runner.c" "${cr_objects[@]}" -o "$WORK_NATIVE/cr_runner$EXE" > "$WORK/cr_runner.build.log" 2>&1; then
    echo "  FAIL: failed to build hosted oracle C runner:"
    cat "$WORK/cr_runner.build.log"
    status=1
  fi
fi
"$WORK/iyi_runner$EXE" > "$WORK/iyi_runner.out" 2>&1 || status=1
"$WORK/cr_runner$EXE" > "$WORK/cr_runner.out" 2>&1 || status=1

if diff -u "$WORK/cr_runner.out" "$WORK/iyi_runner.out" > "$WORK/runner.diff"; then
  echo "  C driver output identical between hosted and pure iyi backends:"
  sed 's/^/    /' "$WORK/iyi_runner.out"
  echo "  Parity summary: C driver execution matches 100% (exit code 0, identical output)"
else
  echo "  FAIL: C driver execution diverged:"
  cat "$WORK/runner.diff"
  status=1
fi

echo
echo "== 5. Guarded mutation proofs"

build_codegen_mutant() {
  if ! "$IYI" build "${LLVM_BRIDGE_ARGS[@]}" -o "$WORK_NATIVE/mut_exercise$EXE" "$REPO_NATIVE/bench/selfhost_codegen_exercise.iyi" > "$WORK/mut_build.log" 2>&1; then
    echo "INVALID MUTANT: codegen driver did not build" >&2
    cat "$WORK/mut_build.log" >&9
    return 2
  fi
}

check_cg_mutant() {
  local fixture="$1" refusal="${2:-}"
  [ -f "$WORK/ir_baseline_$fixture" ] || { echo "INVALID PROOF: IR baseline did not agree" >&2; return 2; }
  build_codegen_mutant || return 2
  local rc=0
  "$WORK/mut_exercise$EXE" --dump-ir "$REPO_NATIVE/bench/fixtures/$fixture" > "$WORK/mut_iyi.raw" 2>"$WORK/mut_iyi.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$fixture" = cg_nil_local.iyi ] && [ "$refusal" = first-assignment ] &&
       expected_refusal "$rc" "$WORK/mut_iyi.err" refuse_port "^port limitation: the port cannot resolve the call 'found\\.val' in 'test_nil_first_local', so it refuses instead of leaving the call out of the IR \\(no IR is written\\)$"; then
      echo "decisive: first-assignment-wins refuses found.val in test_nil_first_local"
      return 1
    fi
    echo "INVALID MUTANT: IR generation failed (exit $rc)" >&2
    cat "$WORK/mut_iyi.raw" "$WORK/mut_iyi.err" >&2
    return 2
  fi
  normalize_ir "$WORK/mut_iyi.raw" > "$WORK/mut_iyi.norm" || return 2
  [ -s "$WORK/cr_${fixture}.norm" ] && [ -s "$WORK/mut_iyi.norm" ] || return 2
  diff -q "$WORK/cr_${fixture}.norm" "$WORK/mut_iyi.norm" >/dev/null
}

# A changed refusal is evidence only if it is the particular diagnostic under
# test, or the original diagnostic with the deliberately changed exit status.
check_refusal_mutant() {
  local name="$1" got_status=0 changed baseline_error
  [ -f "$WORK/refusal_baseline_$name" ] || { echo "INVALID PROOF: refusal baseline did not agree" >&2; return 2; }
  build_codegen_mutant || return 2
  (cd "$REPO" && "$WORK/mut_exercise$EXE" --dump-ir "bench/fixtures/$name") >"$WORK/mut_refusal.out" 2>"$WORK/mut_refusal.err" || got_status=$?
  cat "$WORK/mut_refusal.out" "$WORK/mut_refusal.err" >"$WORK/mut_refusal.log"
  if [ "$got_status" = "$(cat "$WORK/oracle_refusal_$name.status")" ] &&
     cmp -s "$WORK/mut_refusal.log" "$WORK/oracle_refusal_$name.txt"; then
    return 0
  fi
  case "$got_status" in
    0|1) ;;
    *) echo "INVALID MUTANT: compiler exited $got_status" >&2; cat "$WORK/mut_refusal.log" >&2; return 2 ;;
  esac
  baseline_error="$(grep '^Error: ' "$WORK/oracle_refusal_$name.txt" | tail -n 1)"
  case "$name" in
    cg_exceptions.iyi) changed="${baseline_error/exceptions to rescue/exceptions to catch}" ;;
    cg_raise.iyi) changed="${baseline_error/iyi has no \`ensure\`/iyi has no ensure}" ;;
    cg_undefined_raise.iyi) changed="${baseline_error/for top-level/for toplevel}" ;;
    *) return 2 ;;
  esac
  [ "$changed" != "$baseline_error" ] || return 2
  printf '%s\n' "$changed" > "$WORK/mut_refusal.expected"
  grep '^Error: ' "$WORK/mut_refusal.log" | tail -n 1 > "$WORK/mut_refusal.message"
  if grep -Fq "$name:" "$WORK/mut_refusal.log" &&
     cmp -s "$WORK/mut_refusal.expected" "$WORK/mut_refusal.message" &&
     expected_refusal "$got_status" "$WORK/mut_refusal.message" refuse_port '^'; then return 1; fi
  if [ "$got_status" -eq 0 ] && cmp -s "$WORK/mut_refusal.log" "$WORK/oracle_refusal_$name.txt"; then return 1; fi
  echo "INVALID MUTANT: unexpected refusal output" >&2
  cat "$WORK/mut_refusal.log" >&2
  return 2
}

check_probe_mutant() {
  local name="$1"
  [ -f "$WORK/forward.baseline.ok" ] || { echo "INVALID PROOF: forward baseline is unavailable" >&2; return 2; }
  build_codegen_mutant || return 2
  if ! "$WORK/mut_exercise$EXE" --dump-ir "$REPO_NATIVE/bench/fixtures/$name" > "$WORK/mut_probe.log" 2>&1; then
    echo "INVALID MUTANT: forward-reference probe failed" >&2
    cat "$WORK/mut_probe.log" >&2
    return 2
  fi
  diff -q "$WORK/forward.baseline" "$WORK/mut_probe.log" >/dev/null
}

check_standalone_mutant() {
  local rc=0
  build_codegen_mutant || return 2
  "$WORK/mut_exercise$EXE" > "$WORK/mut_standalone.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    grep -qF "ALL SELFHOST CODEGEN CHECKS PASSED SUCCESSFULLY!" "$WORK/mut_standalone.log" && return 0
  elif [ "$rc" -eq 1 ] && grep -q '^iyi: panic: unique names: ' "$WORK/mut_standalone.log" &&
       grep -Eq 'bench/selfhost_codegen_exercise\.iyi:(172|213)' "$WORK/mut_standalone.log"; then
    return 1
  fi
  echo "INVALID MUTANT: standalone probe failed unexpectedly" >&2
  cat "$WORK/mut_standalone.log" >&2
  return 2
}

# Rebuilds the port with the unresolved-call refusal silenced too, and asks it to
# write IR for a port-limit fixture. cg_splat_loop.iyi is refused by an unresolved
# call before its binary operand, so the port refuses it by name only while both
# refusals stand. prove_mutation has already silenced the binary operand; this
# silences the call. It passes, meaning not caught, only while the fixture is
# still refused by name, and the caller's copy of the source is restored.
check_port_limit_mutant() {
  local name="$1" keep="$WORK/cg_first_mutant.iyi" built got_status=0
  [ -f "$WORK/limit_baseline_$name" ] || { echo "INVALID PROOF: limitation baseline did not agree" >&2; return 2; }
  cp "$CG_SRC" "$keep" || return 2
  "$PY" - "$(native_path "$CG_SRC")" <<'PY' || { cp "$keep" "$CG_SRC"; return 2; }
import sys
p = sys.argv[1]
s = open(p).read()
call = "refuse_undefined_call(node)"
if s.count(call) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(call, "nil", 1))
PY
  "$IYI" build "${LLVM_BRIDGE_ARGS[@]}" -o "$WORK_NATIVE/mut_limit$EXE" "$REPO_NATIVE/bench/selfhost_codegen_exercise.iyi" > "$WORK/mut_limit.build.log" 2>&1
  built=$?
  cp "$keep" "$CG_SRC" || return 2
  if [ "$built" -ne 0 ]; then
    echo "INVALID MUTANT: codegen driver did not build" >&2
    cat "$WORK/mut_limit.build.log" >&9
    return 2
  fi
  "$WORK/mut_limit$EXE" --dump-ir "$REPO_NATIVE/bench/fixtures/$name" > "$WORK/mut_limit.log" 2>&1 || got_status=$?
  if cmp -s "$WORK/limit_baseline_$name.log" "$WORK/mut_limit.log" &&
     expected_refusal "$got_status" "$WORK/mut_limit.log" refuse_port '^port limitation: the port cannot '; then return 0; fi
  if [ "$got_status" -eq 0 ] && grep -q '^define ' "$WORK/mut_limit.log"; then return 1; fi
  echo "INVALID MUTANT: unexpected port-limit result" >&2
  cat "$WORK/mut_limit.log" >&2
  return 2
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

prove_mutation "corrupt the block argument evaluated by yield" "$CG_SRC" \
  's_inst = @builder.store(val, ptr)' \
  's_inst = @builder.store(@builder.const_int(val.type, 0), ptr)' \
  -- check_cg_mutant cg_blocks.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "corrupt closure environment store" "$CG_SRC" \
  'st = @builder.store(cval, slot)' \
  'st = @builder.store(@builder.const_int(@types.int32, 0), slot)' \
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
  'idx = info.is_struct ? fidx : fidx' \
  -- check_cg_mutant cg_layouts.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "restore first-assignment-wins for local slot types" "$CG_SRC" \
  '      if t == "Nil"' \
  '      if t == "Nil!"' \
  -- check_cg_mutant cg_nil_local.iyi first-assignment || status=1
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
  local name="$1" got_status=0
  [ -f "$WORK/limit_baseline_$name" ] || { echo "INVALID PROOF: limitation baseline did not agree" >&2; return 2; }
  build_codegen_mutant || return 2
  "$WORK/mut_exercise$EXE" --dump-ir "$REPO_NATIVE/bench/fixtures/$name" > "$WORK/mut_limit_status.log" 2>&1 || got_status=$?
  if cmp -s "$WORK/limit_baseline_$name.log" "$WORK/mut_limit_status.log"; then
    if expected_refusal "$got_status" "$WORK/mut_limit_status.log" refuse_port '^port limitation: the port cannot '; then return 0; fi
    if [ "$got_status" -eq 0 ]; then return 1; fi
  fi
  echo "INVALID MUTANT: unexpected port-limit result" >&2
  cat "$WORK/mut_limit_status.log" >&2
  return 2
}
prove_mutation_all "corrupt refuse_port's exit status" "$REPO/src/compiler/foundation/errors.iyi" \
  '  exit(1)' \
  '  exit(0)' \
  -- check_port_limit_status cg_splat_loop.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "route a no-else false edge through the then block" "$CG_SRC" \
  '      if eb = exit_bb
        @builder.br(eb)
        @builder.position_at_end(eb)' \
  '      if eb = exit_bb
        @builder.br(then_bb)
        @builder.position_at_end(eb)' \
  -- check_cg_mutant cg_nil_local.iyi || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a forward-referenced type is emitted under the wrong LLVM name" "$CG_SRC" \
  '    st = @types.struct_named(name)' \
  '    st = @types.struct_named(name + "_wrong")' \
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
  local rc=0
  [ -f "$WORK/call_result.baseline.ok" ] || { echo "INVALID PROOF: call-result baseline did not exit 10" >&2; return 2; }
  if ! "$IYI" build "${LLVM_BRIDGE_ARGS[@]}" -o "$WORK_NATIVE/mut_port$EXE" "$REPO_NATIVE/src/compiler/tools/compile.iyi" > "$WORK/mut_port.log" 2>&1; then
    echo "INVALID MUTANT: compiler did not build" >&2
    cat "$WORK/mut_port.log" >&9
    return 2
  fi
  if ! "$WORK/mut_port$EXE" "$REPO_NATIVE/bench/fixtures/cg_call_on_call.iyi" -o "$WORK_NATIVE/mut_exe$EXE" > "$WORK/mut_exe.log" 2>&1; then
    echo "INVALID MUTANT: fixture did not build" >&2
    cat "$WORK/mut_exe.log" >&2
    return 2
  fi
  rc="$(run_fixture "$WORK/mut_exe$EXE" "$WORK/mut_exe.out" "$WORK/mut_exe.err")"
  case "$rc" in
    ''|*[!0-9]*) echo "INVALID: call-result fixture terminated with $rc"; cat "$WORK/mut_exe.err" >&2; return 2 ;;
  esac
  if [ -s "$WORK/mut_exe.err" ]; then cat "$WORK/mut_exe.err" >&2; return 2; fi
  [ "$rc" -eq 10 ]
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
