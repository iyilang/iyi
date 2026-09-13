#!/usr/bin/env bash
# Proves that the shipped compiler wires in the pure iyi front end (parser and lexer)
# behind --selfhost, producing output identical to the Crystal frontend across
# the 24 parser syntax fixtures and the samples tree.
#
#   bash bench/selfhost_parser_wiring_exercise.sh
#
# Verifies:
# 1. Building the companion self-host parse tool (iyi-parse) from pure iyi source.
# 2. File parsing parity: `iyi check --parse-only file` vs `iyi check --parse-only --selfhost file`.
# 3. STDIN parsing parity: `iyi check --parse-only - < file` vs `iyi check --parse-only --selfhost - < file`.
# 4. Flag ordering compatibility: `iyi check --selfhost --parse-only` vs `iyi check --parse-only --selfhost`.
# 5. Refusal parity: syntax errors refused with identical error text and status (rc=1).
# 6. Guarded mutation proofs verifying that defects in the wiring are caught.
#
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
PARSE_TOOL_SRC="$REPO/src/compiler/tools/parse.iyi"
CHECK_CR_SRC="$REPO/src/compiler/iyi/command/check.cr"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. Building compiler and self-host parse tool"
cd "$REPO"
make -B iyi
make iyi-parse

if [ ! -x "$REPO/.build/iyi-parse" ]; then
  echo "  ERROR: .build/iyi-parse was not built"
  exit 1
fi

CORPUS=(
  "bench/fixtures/expr_literals.iyi"
  "bench/fixtures/expr_variables_and_paths.iyi"
  "bench/fixtures/expr_operators.iyi"
  "bench/fixtures/expr_calls_and_blocks.iyi"
  "bench/fixtures/expr_control.iyi"
  "bench/fixtures/expr_modifiers.iyi"
  "bench/fixtures/expr_collections.iyi"
  "bench/fixtures/expr_precedence.iyi"
  "bench/fixtures/expr_associativity.iyi"
  "bench/fixtures/expr_combined.iyi"
  "bench/fixtures/expr_ranges_and_tuples.iyi"
  "bench/fixtures/expr_hashes_and_arrays.iyi"
  "bench/fixtures/expr_blocks.iyi"
  "bench/fixtures/expr_multi_assign.iyi"
  "bench/fixtures/expr_case_when.iyi"
  "bench/fixtures/decl_classes_and_structs.iyi"
  "bench/fixtures/decl_def.iyi"
  "bench/fixtures/decl_enums.iyi"
  "bench/fixtures/decl_lib_and_fun.iyi"
  "bench/fixtures/decl_modules_and_inclusion.iyi"
  "bench/fixtures/decl_operators.iyi"
  "bench/fixtures/decl_traits_and_impls.iyi"
  "bench/fixtures/decl_types_and_vars.iyi"
  "bench/fixtures/decl_visibility_and_annotations.iyi"
  "samples/crystal/notes.iyi"
  "samples/crystal/stdlib.iyi"
  "samples/crystal/notes/store.iyi"
  "samples/iyi/app/formal.iyi"
  "samples/iyi/app/greeter.iyi"
  "samples/iyi/basics.iyi"
  "samples/iyi/boot/config.iyi"
  "samples/iyi/boot/registry.iyi"
  "samples/iyi/calc/ast.iyi"
  "samples/iyi/calc/lexer.iyi"
  "samples/iyi/calc/parser.iyi"
  "samples/iyi/calc.iyi"
  "samples/iyi/collections.iyi"
  "samples/iyi/config.iyi"
  "samples/iyi/derive.iyi"
  "samples/iyi/enums.iyi"
  "samples/iyi/errors.iyi"
  "samples/iyi/files.iyi"
  "samples/iyi/format.iyi"
  "samples/iyi/formatting.iyi"
  "samples/iyi/generics.iyi"
  "samples/iyi/grid.iyi"
  "samples/iyi/hello.iyi"
  "samples/iyi/immutable.iyi"
  "samples/iyi/init_order.iyi"
  "samples/iyi/inventory.iyi"
  "samples/iyi/io.iyi"
  "samples/iyi/modules.iyi"
  "samples/iyi/sessions.iyi"
  "samples/iyi/shapes.iyi"
  "samples/iyi/socket.iyi"
  "samples/iyi/std_collections.iyi"
  "samples/iyi/std_compress.iyi"
  "samples/iyi/std_http.iyi"
  "samples/iyi/std_iterator.iyi"
  "samples/iyi/std_json.iyi"
  "samples/iyi/std_regex.iyi"
  "samples/iyi/std_text.iyi"
  "samples/iyi/std_time.iyi"
  "samples/iyi/std_util.iyi"
  "samples/iyi/std_yaml.iyi"
  "samples/iyi/visited.iyi"
  "samples/iyi/webapp.iyi"
  "samples/iyi/workers.iyi"
)

echo
echo "== 2. File syntax check parity: compiler default vs --selfhost"
file_parity_count=0
for rel in "${CORPUS[@]}"; do
  src="$REPO/$rel"
  if [ ! -f "$src" ]; then
    echo "  MISSING CORPUS FILE: $rel"
    status=1
    continue
  fi

  c_out=$("$IYI" check --parse-only "$src" 2>&1)
  c_rc=$?
  s_out=$("$IYI" check --parse-only --selfhost "$src" 2>&1)
  s_rc=$?

  if [ "$c_rc" -ne 0 ] || [ "$s_rc" -ne 0 ]; then
    echo "  EXECUTION FAILURE for $rel: crystal rc=$c_rc, selfhost rc=$s_rc"
    status=1
    continue
  fi

  if [ "$c_out" != "$s_out" ]; then
    echo "  DIVERGENCE in file syntax check for $rel:"
    echo "    crystal:  $c_out"
    echo "    selfhost: $s_out"
    status=1
  else
    file_parity_count=$((file_parity_count + 1))
  fi
done

echo "  File parity summary: $file_parity_count/${#CORPUS[@]} files match byte-for-byte (rc=0, clean output)"
if [ "$file_parity_count" -ne "${#CORPUS[@]}" ]; then
  status=1
fi

echo
echo "== 3. STDIN syntax check parity: compiler default vs --selfhost"
stdin_parity_count=0
for rel in "${CORPUS[@]}"; do
  src="$REPO/$rel"
  if [ ! -f "$src" ]; then
    continue
  fi

  c_out=$("$IYI" check --parse-only - < "$src" 2>&1)
  c_rc=$?
  s_out=$("$IYI" check --parse-only --selfhost - < "$src" 2>&1)
  s_rc=$?

  if [ "$c_rc" -ne 0 ] || [ "$s_rc" -ne 0 ]; then
    echo "  STDIN EXECUTION FAILURE for $rel: crystal rc=$c_rc, selfhost rc=$s_rc"
    status=1
    continue
  fi

  if [ "$c_out" != "$s_out" ]; then
    echo "  STDIN DIVERGENCE for $rel:"
    echo "    crystal:  $c_out"
    echo "    selfhost: $s_out"
    status=1
  else
    stdin_parity_count=$((stdin_parity_count + 1))
  fi
done

echo "  STDIN parity summary: $stdin_parity_count/${#CORPUS[@]} files match byte-for-byte (rc=0, clean output)"
if [ "$stdin_parity_count" -ne "${#CORPUS[@]}" ]; then
  status=1
fi

echo
echo "== 4. Flag ordering compatibility: --parse-only --selfhost vs --selfhost --parse-only"
order_parity_count=0
for rel in "${CORPUS[@]}"; do
  src="$REPO/$rel"
  if [ ! -f "$src" ]; then
    continue
  fi

  s1_out=$("$IYI" check --parse-only --selfhost "$src" 2>&1)
  s1_rc=$?
  s2_out=$("$IYI" check --selfhost --parse-only "$src" 2>&1)
  s2_rc=$?

  if [ "$s1_rc" -ne "$s2_rc" ] || [ "$s1_out" != "$s2_out" ]; then
    echo "  ORDER MISMATCH for $rel: $s1_rc vs $s2_rc"
    status=1
  else
    order_parity_count=$((order_parity_count + 1))
  fi
done

echo "  Flag ordering summary: $order_parity_count/${#CORPUS[@]} files match identically"
if [ "$order_parity_count" -ne "${#CORPUS[@]}" ]; then
  status=1
fi

echo
echo "== 5. Refusal parity: syntax errors refused with identical error text and status (rc=1)"
REFUSALS=(
  "x = 1 while true"
  "x = 1 until true"
  "(1 + 2"
  "[1, 2"
  "{1 => 2"
)

refusal_parity_count=0
for bad in "${REFUSALS[@]}"; do
  bad_file="$WORK/refusal_$refusal_parity_count.iyi"
  echo "$bad" > "$bad_file"

  c_err=$("$IYI" check --parse-only "$bad_file" 2>&1)
  c_rc=$?
  s_err=$("$IYI" check --parse-only --selfhost "$bad_file" 2>&1)
  s_rc=$?

  if [ "$c_rc" -ne 1 ] || [ "$s_rc" -ne 1 ]; then
    echo "  REFUSAL STATUS MISMATCH for '$bad': crystal rc=$c_rc, selfhost rc=$s_rc"
    status=1
  elif [ "$c_err" != "$s_err" ]; then
    echo "  REFUSAL TEXT MISMATCH for '$bad':"
    echo "    crystal:  $c_err"
    echo "    selfhost: $s_err"
    status=1
  else
    echo "  properly refused by both (rc=1): '$bad' => $s_err"
    refusal_parity_count=$((refusal_parity_count + 1))
  fi
done

echo "  Refusal parity summary: $refusal_parity_count/${#REFUSALS[@]} malformed scenarios match identically"
if [ "$refusal_parity_count" -ne "${#REFUSALS[@]}" ]; then
  status=1
fi

# STDIN refusal check
stdin_bad="$WORK/stdin_bad.iyi"
echo "(1 + 2" > "$stdin_bad"
c_stdin_err=$("$IYI" check --parse-only - < "$stdin_bad" 2>&1)
c_stdin_rc=$?
s_stdin_err=$("$IYI" check --parse-only --selfhost - < "$stdin_bad" 2>&1)
s_stdin_rc=$?

if [ "$c_stdin_rc" -ne 1 ] || [ "$s_stdin_rc" -ne 1 ] || [ "$c_stdin_err" != "$s_stdin_err" ]; then
  echo "  STDIN REFUSAL MISMATCH: crystal rc=$c_stdin_rc, selfhost rc=$s_stdin_rc"
  echo "    crystal:  $c_stdin_err"
  echo "    selfhost: $s_stdin_err"
  status=1
else
  echo "  properly refused on STDIN by both (rc=1): $s_stdin_err"
fi

echo
echo "== 6. Mutation proofs: each one must make the checks fail"

test_wiring_file_parity() {
  local f="$REPO/samples/iyi/calc.iyi"
  local out
  out=$("$IYI" check --parse-only --selfhost "$f" 2>&1)
  local rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ]
}

test_wiring_stdin_parity() {
  local f="$REPO/samples/iyi/calc.iyi"
  local out
  out=$("$IYI" check --parse-only --selfhost - < "$f" 2>&1)
  local rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ]
}

test_parse_only_routing() {
  # bench/fixtures/expr_blocks.iyi is a syntax snippet that compiles clean under
  # --parse-only, but fails full type check under `iyi check` because variables are unbound.
  # If --parse-only routing is broken, this command falls through to full check and exits 1.
  local f="$REPO/bench/fixtures/expr_blocks.iyi"
  "$IYI" check --parse-only "$f" >/dev/null 2>&1
}

test_refusal_exit_code() {
  local bad_file="$WORK/mut_bad.iyi"
  echo "(1 + 2" > "$bad_file"
  "$IYI" check --parse-only --selfhost "$bad_file" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 1 ]
}

prove_wiring_mutation() {
  local label="$1"
  local target_file="$2"
  local old_text="$3"
  local new_text="$4"
  local test_cmd="$5"

  echo "  [mutation: $label]"
  cp "$target_file" "$target_file.orig"

  python3 - "$target_file" "$old_text" "$new_text" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(path).read()
if old not in content:
    sys.exit(2)
content = content.replace(old, new, 1)
open(path, "w").write(content)
PY
  local py_code=$?
  if [ $py_code -ne 0 ]; then
    echo "    ERROR: patch matched nothing in $target_file"
    rm -f "$target_file.orig"
    status=1
    return
  fi

  if cmp -s "$target_file" "$target_file.orig"; then
    echo "    ERROR: patch did not change file: $label"
    mv "$target_file.orig" "$target_file"
    status=1
    return
  fi

  # If target is iyi-parse source, recompile it
  if [ "$target_file" = "$PARSE_TOOL_SRC" ]; then
    "$IYI" build -o "$REPO/.build/iyi-parse" "$PARSE_TOOL_SRC" >/dev/null 2>&1 || true
  elif [ "$target_file" = "$CHECK_CR_SRC" ]; then
    make -B iyi >/dev/null 2>&1 || true
  fi

  if eval "$test_cmd"; then
    echo "    FAILED: mutation was not caught ($label)"
    status=1
  else
    echo "    caught: failure observed as expected"
  fi

  mv "$target_file.orig" "$target_file"

  # Restore compiled binary
  if [ "$target_file" = "$PARSE_TOOL_SRC" ]; then
    "$IYI" build -o "$REPO/.build/iyi-parse" "$PARSE_TOOL_SRC" >/dev/null 2>&1
  elif [ "$target_file" = "$CHECK_CR_SRC" ]; then
    make -B iyi >/dev/null 2>&1
  fi
}

prove_wiring_mutation "corrupt self-host parse tool file parsing" \
  "$PARSE_TOOL_SRC" \
  'parse_source(source, path)' \
  'raise "injected parse tool failure"; parse_source(source, path)' \
  'test_wiring_file_parity'

prove_wiring_mutation "corrupt self-host parse tool STDIN parsing" \
  "$PARSE_TOOL_SRC" \
  'parse_source(source, "STDIN.iyi")' \
  'raise "injected stdin failure"; parse_source(source, "STDIN.iyi")' \
  'test_wiring_stdin_parity'

prove_wiring_mutation "corrupt companion tool discovery in check command" \
  "$CHECK_CR_SRC" \
  'tool_name = "iyi-parse"' \
  'tool_name = "iyi-corrupted-tool-name"' \
  'test_wiring_file_parity'

prove_wiring_mutation "corrupt parse-only flag routing in check command" \
  "$CHECK_CR_SRC" \
  'parse_only = options.delete("--parse-only") != nil' \
  'parse_only = options.delete("--corrupted-flag") != nil' \
  'test_parse_only_routing'

prove_wiring_mutation "bypass status code on syntax error in check command" \
  "$CHECK_CR_SRC" \
  'exit status_code' \
  'exit 0' \
  'test_refusal_exit_code'

echo
echo "== Verification clean state confirmed"
"$IYI" build -o "$REPO/.build/iyi-parse" "$PARSE_TOOL_SRC" >/dev/null
make -B iyi >/dev/null

if [ $status -eq 0 ]; then
  echo "Parity summary: 68/68 files match byte-for-byte across files, stdin, and flag ordering (100% parity)"
  echo "Refusal summary: 5/5 malformed scenarios refused with identical error text and status (rc=1)"
  echo "Mutation summary: 5/5 guarded wiring mutations caught and reverted"
  echo "ALL SELFHOST PARSER WIRING CHECKS PASSED SUCCESSFULLY!"
else
  echo "CHECKS FAILED"
fi

exit $status
