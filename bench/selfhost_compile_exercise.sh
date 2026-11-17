#!/usr/bin/env bash
# Proves that the pure iyi self-host compiler tool (iyi-compile) compiles whole
# programs end-to-end using ONLY the ported compiler stages:
#   1. Parser (compiler/syntax/parser)
#   2. Semantic Analysis (compiler/semantic/top_level, compiler/semantic/main_visitor)
#   3. LLVM Code Generation (compiler/codegen/codegen, compiler/llvm)
#   4. Target & Linker (compiler/platform/target, compiler/platform/linker)
#
# Compares execution exit codes, output, and dependency floors against the
# shipped compiler across all compile fixtures.
#
#   bash bench/selfhost_compile_exercise.sh
#
set -u
status=0
diverged=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
COMPILE_TOOL_SRC="$REPO/src/compiler/tools/compile.iyi"
COMPILER_SRC="$REPO/src/compiler/compiler.iyi"
LLVM_BACKEND_SRC="$REPO/src/compiler/backend/llvm/llvm_backend.iyi"
LOADER_SRC="$REPO/src/compiler/loader.iyi"
CODEGEN_SRC="$REPO/src/compiler/codegen/codegen.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"

if command -v brew >/dev/null 2>&1; then
  LIBRARY_PATH="$(brew --prefix bdw-gc 2>/dev/null)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export LIBRARY_PATH
fi
export CRYSTAL_CACHE_DIR="${TMPDIR:-/tmp}/iyi-s2-cache"

echo "== 1. Building self-host compile tool"
cd "$REPO"
rm -f "$REPO/.build/iyi-compile"
make iyi-compile

if [ ! -x "$REPO/.build/iyi-compile" ]; then
  echo "  ERROR: .build/iyi-compile was not built"
  exit 1
fi
echo "  built .build/iyi-compile successfully"

echo
echo "== 2. Whole program execution parity: pure iyi compiler vs shipped compiler"
# compile_raise.iyi is not a parity fixture. It tests exception lowering (rescue,
# ensure, the raise runtime) under an empty prelude, a mode the port no longer has;
# exception lowering is retired in the port, which refuses rescue and ensure by name
# (section 7). Under the default prelude the oracle refuses it for another reason:
# it redefines Pointer(T)#[], a prelude method.
FIXTURES=(
  "bench/fixtures/compile_exit.iyi"
  "bench/fixtures/compile_arith.iyi"
  "bench/fixtures/compile_control.iyi"
  "bench/fixtures/compile_loop.iyi"
  "bench/fixtures/compile_struct.iyi"
  "bench/fixtures/compile_class.iyi"
  "bench/fixtures/compile_pointers.iyi"
  "bench/fixtures/compile_multi_import.iyi"
  "bench/fixtures/compile_diamond.iyi"
  "bench/fixtures/compile_order.iyi"
  "bench/fixtures/compile_top_level.iyi"
  "bench/fixtures/compile_no_top_level.iyi"
  "bench/fixtures/compile_cross_const.iyi"
  "bench/fixtures/compile_reopen_class.iyi"
  "bench/fixtures/compile_resolve_order.iyi"
  "bench/fixtures/compile_ivar_infer.iyi"
  "bench/fixtures/compile_stdout.iyi"
)

matched=0
total=${#FIXTURES[@]}

for fixture in "${FIXTURES[@]}"; do
  base="$(basename "$fixture" .iyi)"
  iyi_bin="$WORK/iyi_${base}"
  cr_bin="$WORK/cr_${base}"

  if ! "$REPO/.build/iyi-compile" -o "$iyi_bin" "$fixture" > "$WORK/compile_iyi_${base}.log" 2>&1; then
    echo "  FAIL: pure iyi compiler failed to compile $fixture"
    cat "$WORK/compile_iyi_${base}.log"
    status=1
    continue
  fi

  if ! "$IYI" build --prelude=empty -o "$cr_bin" "$fixture" > "$WORK/compile_cr_${base}.log" 2>&1; then
    echo "  FAIL: shipped compiler failed to compile $fixture"
    cat "$WORK/compile_cr_${base}.log"
    status=1
    continue
  fi

  set +e
  "$iyi_bin" > "$WORK/out_iyi_${base}.txt" 2> "$WORK/err_iyi_${base}.txt"
  iyi_rc=$?
  "$cr_bin" > "$WORK/out_cr_${base}.txt" 2> "$WORK/err_cr_${base}.txt"
  cr_rc=$?
  set -e

  if [ "$iyi_rc" -eq "$cr_rc" ] && cmp -s "$WORK/out_iyi_${base}.txt" "$WORK/out_cr_${base}.txt"; then
    echo "  $fixture: identical execution exit code (rc=$iyi_rc) and stdout"
    matched=$((matched + 1))
  else
    echo "  FAIL: $fixture execution diverged: iyi rc=$iyi_rc, crystal rc=$cr_rc"
    diff -u "$WORK/out_cr_${base}.txt" "$WORK/out_iyi_${base}.txt" || true
    status=1
  fi
done
# The shipped compiler's stdout for compile_stdout is the oracle for the stdout proof.
cp "$WORK/out_cr_compile_stdout.txt" "$WORK/oracle_stdout.txt" 2>/dev/null || touch "$WORK/oracle_stdout.txt"
echo "  Parity summary: $matched/$total compile fixtures match 100% across execution"

echo
echo "== 2b. Module search order: the first search root that holds a module wins"
# Two search roots both hold compile_shadow.iyi. The shipped compiler and the
# pure compiler must both take the first root's module (exit 11, not 22).
# src holds the oracle's empty prelude (src/empty.cr); IYI_PATH replaces its default path.
SEARCH_PATH="$REPO/bench/fixtures/compile_search_roots/a:$REPO/bench/fixtures/compile_search_roots/b:$REPO/src"
set +e
IYI_PATH="$SEARCH_PATH" "$IYI" build --prelude=empty -o "$WORK/shipped_search" "$REPO/bench/fixtures/compile_search.iyi" > "$WORK/shipped_search.log" 2>&1
shipped_search_build=$?
IYI_PATH="$SEARCH_PATH" "$REPO/.build/iyi-compile" -o "$WORK/selfhost_search" "$REPO/bench/fixtures/compile_search.iyi" > "$WORK/selfhost_search.log" 2>&1
selfhost_search_build=$?
"$WORK/shipped_search" > /dev/null 2>&1
shipped_search_rc=$?
"$WORK/selfhost_search" > /dev/null 2>&1
selfhost_search_rc=$?
set -e
if [ "$shipped_search_build" -eq 0 ] && [ "$selfhost_search_build" -eq 0 ] && \
   [ "$shipped_search_rc" -eq 11 ] && [ "$selfhost_search_rc" -eq 11 ]; then
  echo "  compile_search.iyi: both compilers take the first search root (rc=11)"
else
  echo "  FAIL: search order diverged: shipped build=$shipped_search_build rc=$shipped_search_rc, pure build=$selfhost_search_build rc=$selfhost_search_rc (expected 11)"
  status=1
fi

echo
echo "== 3. Dependency floor verification: pure iyi compiler produces dependency-floor binaries"
floor_matched=0
for fixture in "${FIXTURES[@]}"; do
  base="$(basename "$fixture" .iyi)"
  iyi_bin="$WORK/iyi_${base}"
  [ -x "$iyi_bin" ] || continue

  # Verify binary does not link libgc, and links the platform C library.
  case "$(uname -s)" in
    Darwin)
      if ! command -v otool >/dev/null 2>&1; then
        echo "  FAIL: otool not found; the dependency floor of $base cannot be measured"
        status=1
        continue
      fi
      libs="$(otool -L "$iyi_bin" | grep -v ":" | awk '{print $1}' | tr '\n' ' ')"
      if echo "$libs" | grep -qF "libgc"; then
        echo "  FAIL: $base links libgc: $libs"
        status=1
        continue
      fi
      if ! echo "$libs" | grep -qF "libSystem.B.dylib"; then
        echo "  FAIL: $base does not link libSystem: $libs"
        status=1
        continue
      fi
      ;;
    Linux)
      if ! command -v readelf >/dev/null 2>&1; then
        echo "  FAIL: readelf not found; the dependency floor of $base cannot be measured"
        status=1
        continue
      fi
      needed="$(readelf -d "$iyi_bin" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' | tr '\n' ' ')"
      if echo "$needed" | grep -qF "libgc"; then
        echo "  FAIL: $base links libgc: $needed"
        status=1
        continue
      fi
      if ! echo "$needed" | grep -qF "libc.so.6"; then
        echo "  FAIL: $base does not link libc.so.6: $needed"
        status=1
        continue
      fi
      ;;
    *)
      echo "  FAIL: the dependency floor is measured on Darwin and Linux only, not on $(uname -s)"
      status=1
      continue
      ;;
  esac
  floor_matched=$((floor_matched + 1))
done
echo "  Dependency floor summary: $floor_matched/$total binaries link only platform libc (no libgc)"

echo
echo "== 4. Object emission without linking (--emit-obj)"
"$REPO/.build/iyi-compile" --emit-obj "$WORK/test_emit.o" "$REPO/bench/fixtures/compile_exit.iyi" > "$WORK/emit_obj.log" 2>&1
if [ -f "$WORK/test_emit.o" ] && [ -s "$WORK/test_emit.o" ]; then
  echo "  --emit-obj successfully wrote object file: $WORK/test_emit.o"
else
  echo "  FAIL: --emit-obj did not produce object file"
  status=1
fi

echo
echo "== 5. Malformed input and error refusal checks"
refusals=0
# 1. Syntax error properly refused
set +e
"$REPO/.build/iyi-compile" -o "$WORK/bad1" <(echo "fun main : Int32; (1 + ; end") > "$WORK/err1.log" 2>&1
rc1=$?
set -e
if [ "$rc1" -ne 0 ]; then
  echo "  properly refused: malformed syntax rejected (rc=$rc1)"
  refusals=$((refusals + 1))
else
  echo "  FAIL: malformed syntax was not refused"
  status=1
fi

# 2. Missing input file properly refused
set +e
"$REPO/.build/iyi-compile" -o "$WORK/bad2" "non_existent_file_12345.iyi" > "$WORK/err2.log" 2>&1
rc2=$?
set -e
if [ "$rc2" -ne 0 ]; then
  echo "  properly refused: missing input file rejected (rc=$rc2)"
  refusals=$((refusals + 1))
else
  echo "  FAIL: missing file was not refused"
  status=1
fi

# 3. Missing import properly refused with identical message and exit code to shipped compiler
set +e
"$IYI" build --prelude=empty -o "$WORK/shipped_bad3" "$REPO/bench/fixtures/compile_missing_import.iyi" > "$WORK/shipped_missing.log" 2>&1
shipped_rc=$?
"$REPO/.build/iyi-compile" -o "$WORK/bad3" "$REPO/bench/fixtures/compile_missing_import.iyi" > "$WORK/selfhost_missing.log" 2>&1
selfhost_rc=$?
set -e
if [ "$selfhost_rc" -eq "$shipped_rc" ] && [ "$selfhost_rc" -ne 0 ] && \
   grep -q "can't find module 'nonexistent/missing_mod'" "$WORK/selfhost_missing.log" && \
   grep -q "can't find module 'nonexistent/missing_mod'" "$WORK/shipped_missing.log"; then
  echo "  properly refused: missing import rejected with identical exit code (rc=$selfhost_rc) and message"
  refusals=$((refusals + 1))
else
  echo "  FAIL: missing import was not properly refused"
  status=1
fi

# 4. Undefined type inside a generic class refused, as the shipped compiler does.
# A pass that skipped generic classes made this compile cleanly while the shipped
# compiler rejected it, so the refusal is compared rather than assumed.
set +e
"$IYI" build --no-codegen "$REPO/bench/fixtures/compile_undefined_type.iyi" > "$WORK/shipped_undef.log" 2>&1
shipped_undef_rc=$?
"$REPO/.build/iyi-compile" -o "$WORK/bad4" "$REPO/bench/fixtures/compile_undefined_type.iyi" > "$WORK/selfhost_undef.log" 2>&1
selfhost_undef_rc=$?
set -e
if [ "$selfhost_undef_rc" -ne 0 ] && [ "$shipped_undef_rc" -ne 0 ] && \
   grep -q "UndefinedTypeInGeneric" "$WORK/selfhost_undef.log"; then
  echo "  properly refused: undefined type in a generic class rejected (rc=$selfhost_undef_rc), as the shipped compiler does (rc=$shipped_undef_rc)"
  refusals=$((refusals + 1))
else
  echo "  FAIL: undefined type in a generic class was not refused (iyi rc=$selfhost_undef_rc, shipped rc=$shipped_undef_rc)"
  status=1
fi

# 5. An explicit raise with no rescue and no raise defined. The shipped compiler
# refuses it with the message compared here; the pure compiler must say the same
# and exit the same way.
set +e
"$IYI" build --prelude=empty -o "$WORK/shipped_raise" "$REPO/bench/fixtures/compile_raise_norescue.iyi" > "$WORK/shipped_raise.log" 2>&1
shipped_raise_rc=$?
"$REPO/.build/iyi-compile" -o "$WORK/bad5" "$REPO/bench/fixtures/compile_raise_norescue.iyi" > "$WORK/selfhost_raise.log" 2>&1
selfhost_raise_rc=$?
set -e
if [ "$selfhost_raise_rc" -eq "$shipped_raise_rc" ] && [ "$selfhost_raise_rc" -ne 0 ] && \
   grep -q "undefined method 'raise' for top-level" "$WORK/selfhost_raise.log" && \
   grep -q "undefined method 'raise' for top-level" "$WORK/shipped_raise.log"; then
  echo "  properly refused: explicit raise with no rescue, same message and exit (rc=$selfhost_raise_rc)"
  refusals=$((refusals + 1))
else
  echo "  FAIL: explicit raise with no rescue: pure iyi rc=$selfhost_raise_rc, shipped rc=$shipped_raise_rc"
  echo "    pure iyi: $(grep -m1 -v 'ld: warning' "$WORK/selfhost_raise.log" || true)"
  echo "    shipped:  $(grep -m1 'Error' "$WORK/shipped_raise.log" || true)"
  status=1
fi

# 6. An implicit raise: compile_implicit_raise calls __crystal_raise, which the
# pipeline no longer supplies. The shipped compiler refuses the undefined call;
# the pure compiler must refuse it with the same message and exit status.
set +e
"$IYI" build --prelude=empty -o "$WORK/shipped_implicit" "$REPO/bench/fixtures/compile_implicit_raise.iyi" > "$WORK/shipped_implicit.log" 2>&1
shipped_implicit_rc=$?
"$REPO/.build/iyi-compile" -o "$WORK/bad6" "$REPO/bench/fixtures/compile_implicit_raise.iyi" > "$WORK/selfhost_implicit.log" 2>&1
selfhost_implicit_rc=$?
set -e
if [ "$selfhost_implicit_rc" -eq "$shipped_implicit_rc" ] && [ "$selfhost_implicit_rc" -ne 0 ] && \
   grep -q "undefined method '__crystal_raise' for top-level" "$WORK/selfhost_implicit.log" && \
   grep -q "undefined method '__crystal_raise' for top-level" "$WORK/shipped_implicit.log"; then
  echo "  properly refused: implicit raise with no runtime, same message and exit (rc=$selfhost_implicit_rc)"
  refusals=$((refusals + 1))
else
  echo "  FAIL: implicit raise: pure iyi rc=$selfhost_implicit_rc, shipped rc=$shipped_implicit_rc"
  echo "    pure iyi: $(grep -m1 -v 'ld: warning' "$WORK/selfhost_implicit.log" || true)"
  echo "    shipped:  $(grep -m1 'Error' "$WORK/shipped_implicit.log" || true)"
  status=1
fi

# 7. A rescue under the default prelude, with no prelude method redefined. The
# shipped compiler refuses it; the pure compiler must refuse it with the same first
# error line and exit the same way.
set +e
"$IYI" build -o "$WORK/shipped_rescue" "$REPO/bench/fixtures/compile_rescue_refused.iyi" > "$WORK/shipped_rescue.log" 2>&1
shipped_rescue_rc=$?
"$REPO/.build/iyi-compile" -o "$WORK/bad7" "$REPO/bench/fixtures/compile_rescue_refused.iyi" > "$WORK/selfhost_rescue.log" 2>&1
selfhost_rescue_rc=$?
set -e
shipped_rescue_msg=$(grep -m1 '^Error: ' "$WORK/shipped_rescue.log" || true)
selfhost_rescue_msg=$(grep -m1 '^Error: ' "$WORK/selfhost_rescue.log" || true)
if [ "$selfhost_rescue_rc" -eq "$shipped_rescue_rc" ] && [ "$selfhost_rescue_rc" -ne 0 ] && \
   [ -n "$shipped_rescue_msg" ] && [ "$selfhost_rescue_msg" = "$shipped_rescue_msg" ]; then
  echo "  properly refused: rescue, same message and exit (rc=$selfhost_rescue_rc)"
  refusals=$((refusals + 1))
else
  echo "  FAIL: rescue: pure iyi rc=$selfhost_rescue_rc, shipped rc=$shipped_rescue_rc"
  echo "    pure iyi: $selfhost_rescue_msg"
  echo "    shipped:  $shipped_rescue_msg"
  status=1
fi

# 8. An instance variable that no declaration names and no typed assignment gives a
# type to. The oracle infers it from the call site, which the port does not do, so the
# port refuses the store by name rather than dropping it. Not compared with the shipped
# compiler (it accepts this program), and not counted in the refusal summary.
set +e
"$REPO/.build/iyi-compile" -o "$WORK/bad8" "$REPO/bench/fixtures/compile_ivar_untyped_refused.iyi" > "$WORK/selfhost_ivar.log" 2>&1
selfhost_ivar_rc=$?
set -e
if [ "$selfhost_ivar_rc" -ne 0 ] && grep -q "instance variable @v has no type the port can read" "$WORK/selfhost_ivar.log"; then
  echo "  properly refused: untyped instance variable store, by name (rc=$selfhost_ivar_rc)"
else
  echo "  FAIL: untyped instance variable store: pure iyi rc=$selfhost_ivar_rc"
  status=1
fi
  echo "  Refusal summary: $refusals/7 malformed scenarios refused properly"

echo
echo "== 6. Guarded mutation proofs"
echo "  Each mutation is caught only by a failing check. A check that fails because the"
echo "  mutated compiler does not build or refuses the fixture counts as caught only when"
echo "  the clean compiler builds and runs that fixture as expected; the verdict says which."

# A check writes its reason here; mutate_compiler_source prints it after the verdict.
set_why() { printf '%s\n' "$*" > "$WORK/why"; }

# Rebuilds the pure compiler from the sources as they are now.
rebuild_mutated_compile() {
  rm -f "$REPO/.build/iyi-compile"
  make -C "$REPO" iyi-compile >/dev/null 2>&1
}

# Rebuilds the pure compiler from the sources as they are now, then compiles the
# fixture and requires the program's exit code to equal the expected one.
check_compile_rc() {
  local fixture="$1" expected="$2" mut_rc=0
  rm -f "$WORK/mut_bin"
  if ! rebuild_mutated_compile; then
    set_why "the mutated compiler does not build (the clean compiler does)"
    return 1
  fi
  local build_rc=0
  "$REPO/.build/iyi-compile" -o "$WORK/mut_bin" "$fixture" > "$WORK/mut_compile.log" 2>&1 || build_rc=$?
  if [ "$build_rc" -ne 0 ]; then
    set_why "the mutated compiler exits $build_rc on $(basename "$fixture"); the clean compiler compiles it"
    return 1
  fi
  if [ ! -x "$WORK/mut_bin" ]; then
    set_why "the mutated compiler exits 0 but writes no binary for $(basename "$fixture")"
    return 1
  fi
  "$WORK/mut_bin" >/dev/null 2>&1 || mut_rc=$?
  if [ "$mut_rc" -eq "$expected" ]; then
    return 0
  fi
  set_why "the mutated program exits $mut_rc for $(basename "$fixture"), not $expected"
  return 1
}

# Compiles the (mutated) fixture with the already built compiler and requires the
# program's exit code to equal the expected one.
check_fixture_rc() {
  local fixture="$1" expected="$2" mut_rc=0
  rm -f "$WORK/mut_bin_fx"
  local build_rc=0
  "$REPO/.build/iyi-compile" -o "$WORK/mut_bin_fx" "$fixture" > "$WORK/mut_fx_compile.log" 2>&1 || build_rc=$?
  if [ "$build_rc" -ne 0 ]; then
    set_why "the compiler exits $build_rc on the mutated $(basename "$fixture"); the clean fixture compiles"
    return 1
  fi
  if [ ! -x "$WORK/mut_bin_fx" ]; then
    set_why "the compiler exits 0 but writes no binary for the mutated $(basename "$fixture")"
    return 1
  fi
  "$WORK/mut_bin_fx" >/dev/null 2>&1 || mut_rc=$?
  if [ "$mut_rc" -eq "$expected" ]; then
    return 0
  fi
  set_why "the mutated $(basename "$fixture") exits $mut_rc, not $expected"
  return 1
}

# Rebuilds the pure compiler from the mutated source, then compiles the fixture
# under the search roots and requires the program's exit code to equal 11.
check_search_rc() {
  local fixture="$1" expected="$2" mut_rc=0
  rm -f "$WORK/mut_bin_search"
  if ! rebuild_mutated_compile; then
    set_why "the mutated compiler does not build (the clean compiler does)"
    return 1
  fi
  local build_rc=0
  IYI_PATH="$SEARCH_PATH" "$REPO/.build/iyi-compile" -o "$WORK/mut_bin_search" "$fixture" > "$WORK/mut_search_compile.log" 2>&1 || build_rc=$?
  if [ "$build_rc" -ne 0 ]; then
    set_why "the mutated compiler exits $build_rc on $(basename "$fixture") under the search roots"
    return 1
  fi
  if [ ! -x "$WORK/mut_bin_search" ]; then
    set_why "the mutated compiler exits 0 but writes no binary under the search roots"
    return 1
  fi
  "$WORK/mut_bin_search" >/dev/null 2>&1 || mut_rc=$?
  if [ "$mut_rc" -eq "$expected" ]; then
    return 0
  fi
  set_why "the mutated program takes the other search root: exits $mut_rc, not $expected"
  return 1
}

# Rebuilds the pure compiler from the mutated source, compiles the fixture and
# requires its stdout to equal the oracle file.
check_compiler_stdout() {
  local fixture="$1" oracle="$2"
  rm -f "$WORK/mut_bin_cout"
  if ! rebuild_mutated_compile; then
    set_why "the mutated compiler does not build (the clean compiler does)"
    return 1
  fi
  local build_rc=0
  "$REPO/.build/iyi-compile" -o "$WORK/mut_bin_cout" "$fixture" > "$WORK/mut_cout_compile.log" 2>&1 || build_rc=$?
  if [ "$build_rc" -ne 0 ]; then
    set_why "the mutated compiler exits $build_rc on $(basename "$fixture"); the clean compiler compiles it"
    return 1
  fi
  if [ ! -x "$WORK/mut_bin_cout" ]; then
    set_why "the mutated compiler exits 0 but writes no binary for $(basename "$fixture")"
    return 1
  fi
  "$WORK/mut_bin_cout" > "$WORK/mut_cout.txt" 2>/dev/null || true
  if cmp -s "$WORK/mut_cout.txt" "$oracle"; then
    return 0
  fi
  set_why "the mutated program's stdout differs from the shipped compiler's for $(basename "$fixture")"
  return 1
}

# Compiles the (mutated) fixture and requires its stdout to equal the stdout the
# shipped compiler's binary printed for the unmutated fixture.
check_stdout_parity() {
  local fixture="$1" oracle="$2"
  rm -f "$WORK/mut_bin_out"
  local build_rc=0
  "$REPO/.build/iyi-compile" -o "$WORK/mut_bin_out" "$fixture" > "$WORK/mut_out_compile.log" 2>&1 || build_rc=$?
  if [ "$build_rc" -ne 0 ]; then
    set_why "the mutated compiler exits $build_rc on $(basename "$fixture"); the clean compiler compiles it"
    return 1
  fi
  "$WORK/mut_bin_out" > "$WORK/mut_stdout.txt" 2>/dev/null || true
  if cmp -s "$WORK/mut_stdout.txt" "$oracle"; then
    return 0
  fi
  set_why "the mutated $(basename "$fixture") prints a different stdout"
  return 1
}

# The fixture must be refused with the given message; the check passes (not caught)
# when the message is there.
check_refusal() {
  local fixture="$1" phrase="$2"
  if "$REPO/.build/iyi-compile" -o "$WORK/mut_refusal" "$fixture" > "$WORK/mut_refusal.log" 2>&1; then
    set_why "the compiler accepts the mutated $(basename "$fixture")"
    return 1
  fi
  if grep -q "$phrase" "$WORK/mut_refusal.log"; then
    return 0
  fi
  set_why "the mutated $(basename "$fixture") is refused with another message"
  return 1
}

# Rebuilds the pure compiler from the sources as they are now, then requires it to refuse
# the fixture with a message containing the phrase. A mutation of compiler source must be
# built before a refusal check, or the check runs the clean binary and proves nothing.
check_refusal_rebuilt() {
  local fixture="$1" phrase="$2"
  if ! rebuild_mutated_compile; then
    set_why "the mutated compiler does not build (the clean compiler does)"
    return 1
  fi
  check_refusal "$fixture" "$phrase"
}

# A mutation of a compiler source leaves .build/iyi-compile built from the mutated
# source, so rebuild it from the restored source before any later check uses it.
rebuild_clean_compile() {
  rm -f "$REPO/.build/iyi-compile"
  if ! make -C "$REPO" iyi-compile >/dev/null 2>&1; then
    echo "  ERROR: could not rebuild the clean compiler after a mutation"
    status=1
  fi
}

mutate_compiler_source() {
  rm -f "$WORK/why"
  prove_mutation "$@" || status=1
  if [ -s "$WORK/why" ]; then
    echo "      verdict: $(cat "$WORK/why")"
  fi
  rm -f "$WORK/why"
  rebuild_clean_compile
}

# The clean compiler must pass every check a mutation below relies on, or a
# failure under mutation would be caught for the wrong reason.
clean_must_pass() {
  local label="$1"
  shift
  rm -f "$WORK/why"
  if "$@"; then
    echo "  clean baseline ok: $label"
  else
    echo "  ERROR: clean baseline fails for $label ($(cat "$WORK/why" 2>/dev/null)); a mutation of it would not count"
    status=1
  fi
}

clean_must_pass "compile_arith expects 26" check_compile_rc "$REPO/bench/fixtures/compile_arith.iyi" 26
clean_must_pass "compile_top_level expects 42" check_compile_rc "$REPO/bench/fixtures/compile_top_level.iyi" 42
clean_must_pass "compile_no_top_level expects 0" check_compile_rc "$REPO/bench/fixtures/compile_no_top_level.iyi" 0
clean_must_pass "compile_search expects 11 under the search roots" check_search_rc "$REPO/bench/fixtures/compile_search.iyi" 11
clean_must_pass "compile_order prints the shipped order" check_compiler_stdout "$REPO/bench/fixtures/compile_order.iyi" "$WORK/out_cr_compile_order.txt"
clean_must_pass "compile_resolve_order expects 20 under the load order" check_compile_rc "$REPO/bench/fixtures/compile_resolve_order.iyi" 20
clean_must_pass "compile_ivar_infer expects 12" check_compile_rc "$REPO/bench/fixtures/compile_ivar_infer.iyi" 12

mutate_compiler_source "corrupt linker placeholder substitution" \
  "$LLVM_BACKEND_SRC" \
  '"\"${@}\""' \
  '"__WRONG_PLACEHOLDER__"' \
  -- check_compile_rc "$REPO/bench/fixtures/compile_arith.iyi" 26

mutate_compiler_source "corrupt object file output path" \
  "$COMPILER_SRC" \
  'obj_path = @config.obj_output_filename || (@config.output_filename + ".o")' \
  'obj_path = @config.obj_output_filename || "/nonexistent/dir/out.o"' \
  -- check_compile_rc "$REPO/bench/fixtures/compile_arith.iyi" 26

prove_mutation "corrupt arithmetic operation in test fixture" \
  "$REPO/bench/fixtures/compile_arith.iyi" \
  'v1 &- v2' \
  'v1 &+ v2' \
  -- check_fixture_rc "$REPO/bench/fixtures/compile_arith.iyi" 26 || status=1

# The search roots are read in order by IyiPath#find. Reading them backwards makes
# the second root's module win, which compile_search's exit code shows.
mutate_compiler_source "search roots read in reverse order" \
  "$LOADER_SRC" \
  '@entries.each do |entry|' \
  '@entries.reversed.each do |entry|' \
  -- check_search_rc "$REPO/bench/fixtures/compile_search.iyi" 11

# The initialiser order is a hash of the module path. Replacing the hash with a
# constant leaves the tie-break by path, which runs compile_order's modules the
# other way round from the shipped compiler.
mutate_compiler_source "initialiser order ignores the path hash" \
  "$LOADER_SRC" \
  '    hash ^ (hash >> 31)' \
  '    0_u64' \
  -- check_compiler_stdout "$REPO/bench/fixtures/compile_order.iyi" "$WORK/out_cr_compile_order.txt"


# The load order decides which of two reopened definitions of one method runs: the later
# import wins. Reversing the load order (@order) makes the earlier import win, so the
# program exits 10 instead of 20. This fixture is what sees the order: a loader that
# reverses the load order is caught here. Before the initialiser-order change, the
# mutation was caught by compile_diamond; no fixture there depends on declaration order.
mutate_compiler_source "wrong resolver resolution order" \
  "$LOADER_SRC" \
  '@order << clean_fn' \
  '@order = [clean_fn] + @order' \
  -- check_compile_rc "$REPO/bench/fixtures/compile_resolve_order.iyi" 20

mutate_compiler_source "missed import in resolver" \
  "$LOADER_SRC" \
  'resolve_file(clean_res, clean_fn)' \
  '# resolve_file(clean_res, clean_fn)' \
  -- check_compile_rc "$REPO/bench/fixtures/compile_diamond.iyi" 52

mutate_compiler_source "omitting entry point wrapper for top-level code" \
  "$CODEGEN_SRC" \
  '  return if top_level_stmts.empty?' \
  '  return if true' \
  -- check_compile_rc "$REPO/bench/fixtures/compile_top_level.iyi" 42

mutate_compiler_source "pipeline drops top-level statements" \
  "$COMPILER_SRC" \
  'append_entry_point(funs, top_level)' \
  '# append_entry_point(funs, top_level)' \
  -- check_compile_rc "$REPO/bench/fixtures/compile_top_level.iyi" 42

mutate_compiler_source "pipeline drops default entry point for declaration-only program" \
  "$COMPILER_SRC" \
  'top_level << Nop.new' \
  '# top_level << Nop.new' \
  -- check_compile_rc "$REPO/bench/fixtures/compile_no_top_level.iyi" 0

# compile_raise.iyi left the parity set (see the note at the fixture list), so its
# runtime mutations no longer have a run to be caught by. The rescue refusal is
# proven below in its place.
prove_mutation "rescue refusal names ensure instead" \
  "$REPO/bench/fixtures/compile_rescue_refused.iyi" \
  'rescue' \
  'ensure' \
  -- check_refusal "$REPO/bench/fixtures/compile_rescue_refused.iyi" "iyi has no exceptions to rescue" || status=1

# A store to an undeclared instance variable is refused by name. Replacing the refusal
# with nothing drops the store; the refusal check must notice the compiler now accepts
# the program.
mutate_compiler_source "undeclared instance variable store dropped" \
  "$CODEGEN_SRC" \
  '            refuse_undeclared_ivar(node.target.as(InstanceVar))' \
  '            nil' \
  -- check_refusal_rebuilt "$REPO/bench/fixtures/compile_ivar_untyped_refused.iyi" "instance variable @v has no type the port can read" || status=1

# Inference declares nothing: the typed fixture then has undeclared stores and is refused,
# so its exit code (12) is never reached.
mutate_compiler_source "ivar inference declares nothing" \
  "$CODEGEN_SRC" \
  '    info.add_field(name, guesses[name]) unless unresolved.includes?(name)' \
  '    nil' \
  -- check_compile_rc "$REPO/bench/fixtures/compile_ivar_infer.iyi" 12 || status=1

# The refusal of an explicit raise: renaming the raise makes the refused message
# change, so the refusal check must notice.
prove_mutation "explicit raise refusal names the wrong method" \
  "$REPO/bench/fixtures/compile_raise_norescue.iyi" \
  'raise E.new' \
  'raisx E.new' \
  -- check_refusal "$REPO/bench/fixtures/compile_raise_norescue.iyi" "undefined method 'raise' for top-level" || status=1

# A stdout difference must fail the stdout parity. The shipped compiler's stdout
# for the unmutated fixture is the oracle; the mutation prints a different letter.
prove_mutation "a stdout difference fails the stdout parity check" \
  "$REPO/bench/fixtures/compile_stdout.iyi" \
  'LibC.putchar(107)' \
  'LibC.putchar(108)' \
  -- check_stdout_parity "$REPO/bench/fixtures/compile_stdout.iyi" "$WORK/oracle_stdout.txt" || status=1
echo
if [ "$status" -eq 0 ]; then
  echo "ALL SELFHOST COMPILE CHECKS PASSED!"
else
  echo "SOME SELFHOST COMPILE CHECKS FAILED"
  exit 1
fi
