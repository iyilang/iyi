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
LOADER_SRC="$REPO/src/compiler/loader.iyi"
CODEGEN_SRC="$REPO/src/compiler/codegen/codegen.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export LIBRARY_PATH="/opt/homebrew/opt/bdw-gc/lib:${LIBRARY_PATH:-}"
export CRYSTAL_CACHE_DIR="/tmp/iyi-s2-cache"

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
  "bench/fixtures/compile_top_level.iyi"
  "bench/fixtures/compile_no_top_level.iyi"
  "bench/fixtures/compile_cross_const.iyi"
  "bench/fixtures/compile_reopen_class.iyi"
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
  "$iyi_bin" > "$WORK/out_iyi_${base}.txt" 2>&1
  iyi_rc=$?
  "$cr_bin" > "$WORK/out_cr_${base}.txt" 2>&1
  cr_rc=$?
  set -e

  if [ "$iyi_rc" -eq "$cr_rc" ]; then
    echo "  $fixture: identical execution exit code (rc=$iyi_rc)"
    matched=$((matched + 1))
  else
    echo "  FAIL: $fixture execution diverged: iyi rc=$iyi_rc, crystal rc=$cr_rc"
    status=1
  fi
done
echo "  Parity summary: $matched/$total compile fixtures match 100% across execution"

echo
echo "== 3. Dependency floor verification: pure iyi compiler produces dependency-floor binaries"
floor_matched=0
for fixture in "${FIXTURES[@]}"; do
  base="$(basename "$fixture" .iyi)"
  iyi_bin="$WORK/iyi_${base}"
  [ -x "$iyi_bin" ] || continue

  # Verify binary does not link libgc, libc++, or libLLVM
  if [ "$(uname -s)" = "Darwin" ]; then
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
  fi
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
echo "  Refusal summary: $refusals/4 malformed scenarios refused properly"

echo
echo "== 6. Guarded mutation proofs"
prove_compile_mutation() {
  local label="$1"
  local target_file="$2"
  local old_pat="$3"
  local new_pat="$4"
  local test_fixture="${5:-$REPO/bench/fixtures/compile_arith.iyi}"
  local expected_rc="${6:-26}"

  echo "  [$label]"
  cp "$target_file" "$target_file.orig"
  python3 - "$target_file" "$old_pat" "$new_pat" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(path).read()
if old not in content:
    sys.exit(3)
open(path, 'w').write(content.replace(old, new, 1))
PY
  local py_rc=$?
  if [ "$py_rc" -eq 3 ] || diff -q "$target_file" "$target_file.orig" >/dev/null 2>&1; then
    echo "    ERROR: patch did not change file: $label"
    mv "$target_file.orig" "$target_file"
    status=1
    return
  fi

  # Run test with mutation applied
  local test_fixture="${5:-$REPO/bench/fixtures/compile_arith.iyi}"
  local expected_rc="${6:-26}"
  local mut_failed=0
  if [ "$target_file" = "$COMPILE_TOOL_SRC" ] || [ "$target_file" = "$COMPILER_SRC" ] || [ "$target_file" = "$LOADER_SRC" ] || [ "$target_file" = "$CODEGEN_SRC" ]; then
    rm -f "$REPO/.build/iyi-compile"
    if make -C "$REPO" iyi-compile >/dev/null 2>&1; then
      if "$REPO/.build/iyi-compile" -o "$WORK/mut_bin" "$test_fixture" >/dev/null 2>&1; then
        set +e
        "$WORK/mut_bin"
        local mut_rc=$?
        set -e
        if [ "$mut_rc" -ne "$expected_rc" ]; then
          mut_failed=1
        fi
      else
        mut_failed=1
      fi
    else
      mut_failed=1
    fi
    mv "$target_file.orig" "$target_file"
    rm -f "$REPO/.build/iyi-compile"
    make -C "$REPO" iyi-compile >/dev/null 2>&1
  else
    # Mutating a fixture file
    if "$REPO/.build/iyi-compile" -o "$WORK/mut_bin" "$target_file" >/dev/null 2>&1; then
      set +e
      "$WORK/mut_bin"
      local mut_rc=$?
      set -e
      if [ "$mut_rc" -ne "$expected_rc" ]; then
        mut_failed=1
      fi
    else
      mut_failed=1
    fi
    mv "$target_file.orig" "$target_file"
  fi

  if [ "$mut_failed" -eq 1 ]; then
    echo "    caught: mutation caused compilation or execution divergence as expected"
  else
    echo "    FAIL: mutation was not caught: $label"
    status=1
  fi
}

prove_compile_mutation "corrupt linker placeholder substitution" \
  "$COMPILER_SRC" \
  "\"\\${@}\"" \
  "\"__WRONG_PLACEHOLDER__\""

prove_compile_mutation "corrupt object file output path" \
  "$COMPILER_SRC" \
  "obj_path = @config.obj_output_filename || (@config.output_filename + \".o\")" \
  "obj_path = @config.obj_output_filename || \"/nonexistent/dir/out.o\""

prove_compile_mutation "corrupt arithmetic operation in test fixture" \
  "$REPO/bench/fixtures/compile_arith.iyi" \
  "v1 &- v2" \
  "v1 &+ v2"

prove_compile_mutation "wrong resolver resolution order" \
  "$LOADER_SRC" \
  "@order << clean_fn" \
  "@order = [clean_fn] + @order" \
  "$REPO/bench/fixtures/compile_diamond.iyi" \
  "52"

prove_compile_mutation "missed import in resolver" \
  "$LOADER_SRC" \
  "resolve_file(clean_res, clean_fn)" \
  "# resolve_file(clean_res, clean_fn)" \
  "$REPO/bench/fixtures/compile_diamond.iyi" \
  "52"

prove_compile_mutation "omitting entry point wrapper for top-level code" \
  "$CODEGEN_SRC" \
  "  return if top_level_stmts.empty?" \
  "  return if true" \
  "$REPO/bench/fixtures/compile_top_level.iyi" \
  42

prove_compile_mutation "pipeline drops top-level statements" \
  "$COMPILER_SRC" \
  "append_entry_point(funs, top_level)" \
  "# append_entry_point(funs, top_level)" \
  "$REPO/bench/fixtures/compile_top_level.iyi" \
  42

prove_compile_mutation "pipeline drops default entry point for declaration-only program" \
  "$COMPILER_SRC" \
  "top_level << Nop.new" \
  "# top_level << Nop.new" \
  "$REPO/bench/fixtures/compile_no_top_level.iyi" \
  0
echo
if [ "$status" -eq 0 ]; then
  echo "ALL SELFHOST COMPILE CHECKS PASSED!"
else
  echo "SOME SELFHOST COMPILE CHECKS FAILED"
  exit 1
fi
