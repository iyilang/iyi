#!/usr/bin/env bash
# Proves that the shipped compiler wires in the pure iyi formatter
# behind --selfhost, producing output identical to the Crystal frontend across
# the entire corpus of formatted files.
#
#   bash bench/selfhost_format_wiring_exercise.sh
#
# Verifies:
# 1. Building the companion self-host formatter tool (iyi-format) from pure iyi source.
# 2. STDIN formatting parity: `iyi tool format - < file` vs `iyi tool format --selfhost - < file`.
# 3. In-place file formatting parity: `iyi tool format file` vs `iyi tool format --selfhost file`.
# 4. Prefix flag compatibility: `iyi tool --selfhost format` works identically.
# 5. Check mode parity: `--check` exits 0 on clean files and 1 on unformatted files.
# 6. Refusal parity: syntax errors refused by both with identical status.
# 7. Guarded mutation proofs verifying that defects in the wiring are caught.
#
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
FORMAT_TOOL_SRC="$REPO/src/compiler/tools/format.iyi"
FORMAT_CR_SRC="$REPO/src/compiler/iyi/command/format.cr"
COMMAND_CR_SRC="$REPO/src/compiler/iyi/command.cr"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. Building compiler and self-host formatter tool"
cd "$REPO"
make -B iyi
make iyi-format

if [ ! -x "$REPO/.build/iyi-format" ]; then
  echo "  ERROR: .build/iyi-format was not built"
  exit 1
fi

CORPUS=(
  "samples/iyi/calc.iyi"
  "samples/iyi/collections.iyi"
  "samples/iyi/derive.iyi"
  "samples/iyi/files.iyi"
  "samples/iyi/format.iyi"
  "samples/iyi/formatting.iyi"
  "samples/iyi/generics.iyi"
  "samples/iyi/hello.iyi"
  "samples/iyi/immutable.iyi"
  "samples/iyi/init_order.iyi"
  "samples/iyi/io.iyi"
  "samples/iyi/modules.iyi"
  "samples/iyi/sessions.iyi"
  "samples/iyi/socket.iyi"
  "samples/iyi/std_collections.iyi"
  "samples/iyi/std_compress.iyi"
  "samples/iyi/std_iterator.iyi"
  "samples/iyi/std_json.iyi"
  "samples/iyi/std_regex.iyi"
  "samples/iyi/std_text.iyi"
  "samples/iyi/std_time.iyi"
  "samples/iyi/std_util.iyi"
  "samples/iyi/std_yaml.iyi"
  "samples/iyi/webapp.iyi"
  "src/std/bool.iyi"
  "src/std/cmp.iyi"
  "src/std/comparable.iyi"
  "src/std/deque.iyi"
  "src/std/iterable.iyi"
  "src/std/list.iyi"
  "src/std/nil.iyi"
  "src/std/pretty_print.iyi"
  "src/std/steppable.iyi"
  "src/std/string_scanner.iyi"
  "src/std/traits.iyi"
)

echo
echo "== 2. STDIN formatting parity: compiler default vs --selfhost"
stdin_parity_count=0
for rel in "${CORPUS[@]}"; do
  src="$REPO/$rel"
  if [ ! -f "$src" ]; then
    echo "  MISSING CORPUS FILE: $rel"
    status=1
    continue
  fi

  "$IYI" tool format - < "$src" > "$WORK/c.out" 2>/dev/null
  c_rc=$?
  "$IYI" tool format --selfhost - < "$src" > "$WORK/s.out" 2>/dev/null
  s_rc=$?

  if [ "$c_rc" -ne 0 ] || [ "$s_rc" -ne 0 ]; then
    echo "  EXECUTION FAILURE for $rel: crystal rc=$c_rc, selfhost rc=$s_rc"
    status=1
    continue
  fi

  if ! diff -u "$WORK/c.out" "$WORK/s.out" > "$WORK/diff"; then
    echo "  DIVERGENCE in stdin format for $rel:"
    cat "$WORK/diff"
    status=1
  else
    stdin_parity_count=$((stdin_parity_count + 1))
  fi
done

echo "  STDIN parity summary: $stdin_parity_count/${#CORPUS[@]} files match byte-for-byte"
if [ "$stdin_parity_count" -ne "${#CORPUS[@]}" ]; then
  status=1
fi

echo
echo "== 3. In-place file formatting parity: compiler default vs --selfhost"
file_parity_count=0
for rel in "${CORPUS[@]}"; do
  src="$REPO/$rel"
  if [ ! -f "$src" ]; then
    continue
  fi

  cp "$src" "$WORK/c_target.iyi"
  cp "$src" "$WORK/s_target.iyi"

  "$IYI" tool format "$WORK/c_target.iyi" >/dev/null 2>&1
  c_rc=$?
  "$IYI" tool format --selfhost "$WORK/s_target.iyi" >/dev/null 2>&1
  s_rc=$?

  if [ "$c_rc" -ne 0 ] || [ "$s_rc" -ne 0 ]; then
    echo "  IN-PLACE FAILURE for $rel: crystal rc=$c_rc, selfhost rc=$s_rc"
    status=1
    continue
  fi

  if ! diff -u "$WORK/c_target.iyi" "$WORK/s_target.iyi" > "$WORK/diff"; then
    echo "  DIVERGENCE in file format for $rel:"
    cat "$WORK/diff"
    status=1
  else
    file_parity_count=$((file_parity_count + 1))
  fi
done

echo "  In-place parity summary: $file_parity_count/${#CORPUS[@]} files match byte-for-byte"
if [ "$file_parity_count" -ne "${#CORPUS[@]}" ]; then
  status=1
fi

echo
echo "== 4. Prefix flag compatibility: tool --selfhost format"
prefix_count=0
for rel in "${CORPUS[@]}"; do
  src="$REPO/$rel"
  if [ ! -f "$src" ]; then
    continue
  fi

  "$IYI" tool format - < "$src" > "$WORK/c.out" 2>/dev/null
  "$IYI" tool --selfhost format - < "$src" > "$WORK/p.out" 2>/dev/null

  if ! diff -u "$WORK/c.out" "$WORK/p.out" > "$WORK/diff"; then
    echo "  DIVERGENCE in prefix flag for $rel"
    status=1
  else
    prefix_count=$((prefix_count + 1))
  fi
done

echo "  Prefix flag summary: $prefix_count/${#CORPUS[@]} files match"
if [ "$prefix_count" -ne "${#CORPUS[@]}" ]; then
  status=1
fi

echo
echo "== 5. Check mode parity: --check exits 0 on clean files and 1 on unformatted files"
clean_check_ok=1
for rel in "${CORPUS[@]}"; do
  src="$REPO/$rel"
  if [ ! -f "$src" ]; then
    continue
  fi

  if ! "$IYI" tool format --check "$src" >/dev/null 2>&1; then
    echo "  DEFAULT CHECK FAILED on clean file: $rel"
    clean_check_ok=0
    status=1
  fi
  if ! "$IYI" tool format --check --selfhost "$src" >/dev/null 2>&1; then
    echo "  SELFHOST CHECK FAILED on clean file: $rel"
    clean_check_ok=0
    status=1
  fi
done

if [ "$clean_check_ok" -eq 1 ]; then
  echo "  clean check parity: ${#CORPUS[@]}/${#CORPUS[@]} files pass on both paths"
fi

# Verify unformatted content detection
echo "x  =  1  +  2" > "$WORK/unformatted.iyi"
"$IYI" tool format --check "$WORK/unformatted.iyi" >/dev/null 2>&1
c_unfmt_rc=$?
"$IYI" tool format --check --selfhost "$WORK/unformatted.iyi" >/dev/null 2>&1
s_unfmt_rc=$?

if [ "$c_unfmt_rc" -eq 1 ] && [ "$s_unfmt_rc" -eq 1 ]; then
  echo "  unformatted check refusal: both paths detect changes (rc=1)"
else
  echo "  UNFORMATTED CHECK MISMATCH: crystal rc=$c_unfmt_rc, selfhost rc=$s_unfmt_rc"
  status=1
fi

echo
echo "== 6. Refusal parity: syntax errors refused with identical error status"
echo "def bad_syntax(" > "$WORK/syntax_error.iyi"
"$IYI" tool format "$WORK/syntax_error.iyi" > "$WORK/c_err.out" 2>&1
c_err_rc=$?
"$IYI" tool format --selfhost "$WORK/syntax_error.iyi" > "$WORK/s_err.out" 2>&1
s_err_rc=$?

if [ "$c_err_rc" -ne 0 ] && [ "$s_err_rc" -ne 0 ]; then
  echo "  syntax error properly refused by both (rc=1)"
else
  echo "  SYNTAX ERROR MISMATCH: crystal rc=$c_err_rc, selfhost rc=$s_err_rc"
  status=1
fi

echo
echo "== 7. Mutation proofs: each one must make the checks fail"

test_wiring_stdin_parity() {
  local f="$REPO/samples/iyi/calc.iyi"
  "$IYI" tool format - < "$f" > "$WORK/test_c.out" 2>/dev/null || return 1
  "$IYI" tool format --selfhost - < "$f" > "$WORK/test_s.out" 2>/dev/null || return 1
  diff -q "$WORK/test_c.out" "$WORK/test_s.out" >/dev/null || return 1
  return 0
}

test_wiring_file_parity() {
  local f="$REPO/samples/iyi/calc.iyi"
  cp "$f" "$WORK/t_c.iyi"
  cp "$f" "$WORK/t_s.iyi"
  "$IYI" tool format "$WORK/t_c.iyi" >/dev/null 2>&1 || return 1
  "$IYI" tool format --selfhost "$WORK/t_s.iyi" >/dev/null 2>&1 || return 1
  diff -q "$WORK/t_c.iyi" "$WORK/t_s.iyi" >/dev/null || return 1
  return 0
}

test_prefix_flag_parity() {
  local f="$REPO/samples/iyi/calc.iyi"
  "$IYI" tool format - < "$f" > "$WORK/test_c.out" 2>/dev/null || return 1
  "$IYI" tool --selfhost format - < "$f" > "$WORK/test_p.out" 2>/dev/null || return 1
  diff -q "$WORK/test_c.out" "$WORK/test_p.out" >/dev/null || return 1
  return 0
}

test_check_refusal() {
  local unformatted="$WORK/unformatted_mut.iyi"
  echo "x  =  1  +  2" > "$unformatted"
  "$IYI" tool format --check --selfhost "$unformatted" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq 1 ]; then
    return 0
  else
    return 1
  fi
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

  # If target is iyi-format source, recompile it
  if [ "$target_file" = "$FORMAT_TOOL_SRC" ]; then
    "$IYI" build -o "$REPO/.build/iyi-format" "$FORMAT_TOOL_SRC" >/dev/null 2>&1 || true
  elif [ "$target_file" = "$FORMAT_CR_SRC" ] || [ "$target_file" = "$COMMAND_CR_SRC" ]; then
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
  if [ "$target_file" = "$FORMAT_TOOL_SRC" ]; then
    "$IYI" build -o "$REPO/.build/iyi-format" "$FORMAT_TOOL_SRC" >/dev/null 2>&1
  elif [ "$target_file" = "$FORMAT_CR_SRC" ] || [ "$target_file" = "$COMMAND_CR_SRC" ]; then
    make -B iyi >/dev/null 2>&1
  fi
}

prove_wiring_mutation "corrupt self-host format tool file output" \
  "$FORMAT_TOOL_SRC" \
  'print Formatter.format(source, path)' \
  'puts "# mutated"; print Formatter.format(source, path)' \
  'test_wiring_file_parity'

prove_wiring_mutation "corrupt self-host format tool STDIN output" \
  "$FORMAT_TOOL_SRC" \
  'print Formatter.format(source, "STDIN")' \
  'puts "# stdin mutated"; print Formatter.format(source, "STDIN")' \
  'test_wiring_stdin_parity'

prove_wiring_mutation "corrupt captured output in format command delegation" \
  "$FORMAT_CR_SRC" \
  'out_io.to_s' \
  'out_io.to_s + "\n# corrupted output capture\n"' \
  'test_wiring_stdin_parity'

prove_wiring_mutation "corrupt prefix flag propagation in command router" \
  "$COMMAND_CR_SRC" \
  'options.unshift("--selfhost") if selfhost' \
  'options.unshift("--corrupted-flag") if selfhost' \
  'test_prefix_flag_parity'

prove_wiring_mutation "bypass status code in check mode" \
  "$FORMAT_CR_SRC" \
  '@status_code = 1' \
  '@status_code = 0' \
  'test_check_refusal'

echo
echo "== Verification clean state confirmed"
"$IYI" build -o "$REPO/.build/iyi-format" "$FORMAT_TOOL_SRC" >/dev/null
make -B iyi >/dev/null

if [ $status -eq 0 ]; then
  echo "Parity summary: 35/35 files match byte-for-byte across stdin, in-place, and prefix flags (100% parity)"
  echo "ALL SELFHOST FORMAT WIRING CHECKS PASSED SUCCESSFULLY!"
else
  echo "CHECKS FAILED"
fi

exit $status
