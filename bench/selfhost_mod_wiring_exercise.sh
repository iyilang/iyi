#!/usr/bin/env bash
# Proves that the shipped compiler wires in the pure iyi artifact reader
# behind --selfhost, producing output identical to the Crystal frontend across
# the entire corpus of module artifacts.
#
#   bash bench/selfhost_mod_wiring_exercise.sh
#
# Verifies:
# 1. Building the companion self-host artifact tool (iyi-mod) from pure iyi source.
# 2. Emitting all 16 corpus module artifacts from samples/iyi and src/std.
# 3. dump parity: `iyi mod dump <file>` vs `iyi mod dump --selfhost <file>`.
# 4. declarations parity: `iyi mod dump --declarations <file>` vs `iyi mod dump --declarations --selfhost <file>`.
# 5. prefix compatibility: `iyi mod --selfhost dump <file>` works identically.
# 6. refusal parity: corrupted artifacts refused by both with identical verdicts.
# 7. Guarded mutation proofs verifying that checks catch injected defects.
#
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
MOD_TOOL_SRC="$REPO/src/compiler/tools/mod.iyi"
MOD_CR_SRC="$REPO/src/compiler/iyi/command/mod.cr"
IYIMOD_SRC="$REPO/src/compiler/artifact/iyimod.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. Building compiler and self-host artifact inspection tool"
cd "$REPO"
make -B iyi
make iyi-mod

if [ ! -x "$REPO/.build/iyi-mod" ]; then
  echo "  ERROR: .build/iyi-mod was not built"
  exit 1
fi

echo
echo "== 2. Emitting corpus artifacts from samples/iyi and src/std"
CORPUS_DIR="$WORK/corpus"
mkdir -p "$CORPUS_DIR"
for sample in \
  "$REPO/samples/iyi/calc.iyi" \
  "$REPO/samples/iyi/shapes.iyi" \
  "$REPO/samples/iyi/generics.iyi" \
  "$REPO/samples/iyi/immutable.iyi" \
  "$REPO/samples/iyi/inventory.iyi" \
  "$REPO/samples/iyi/sessions.iyi" \
  "$REPO/samples/iyi/io.iyi" \
  "$REPO/samples/iyi/config.iyi" \
  "$REPO/samples/iyi/errors.iyi" \
  "$REPO/samples/iyi/basics.iyi" \
  "$REPO/samples/iyi/derive.iyi" \
  "$REPO/samples/iyi/format.iyi" \
  "$REPO/samples/iyi/std_iterator.iyi" \
  "$REPO/samples/iyi/std_time.iyi" \
  "$REPO/samples/iyi/modules.iyi" \
  "$REPO/samples/iyi/init_order.iyi" \
  "$REPO/samples/iyi/visited.iyi" \
  "$REPO/samples/iyi/webapp.iyi" \
  "$REPO/samples/iyi/workers.iyi"; do
  "$IYI" build --emit-iyimod "$CORPUS_DIR" --no-codegen "$sample" 2>/dev/null || true
done

CORPUS_FILES=(
  "calc/ast"
  "calc/lexer"
  "calc/parser"
  "std/traits"
  "std/enumerable"
  "std/list"
  "std/iterator"
  "std/time"
  "std/format"
  "std/derives"
  "kemal/dsl"
  "kemal/router"
  "boot/config"
  "boot/registry"
  "app/greeter"
  "app/formal"
)

echo
echo "== 3. Dump parity: compiler default vs --selfhost"
dump_parity_count=0
for mod in "${CORPUS_FILES[@]}"; do
  file="$CORPUS_DIR/${mod}.iyimod"
  if [ ! -f "$file" ]; then
    echo "  MISSING CORPUS FILE: $file"
    status=1
    continue
  fi

  "$IYI" mod dump "$file" > "$WORK/c.dump"
  "$IYI" mod dump --selfhost "$file" > "$WORK/s.dump"

  if ! diff -u "$WORK/c.dump" "$WORK/s.dump" > "$WORK/diff"; then
    echo "  DIVERGENCE in dump for $mod:"
    cat "$WORK/diff"
    status=1
  else
    dump_parity_count=$((dump_parity_count + 1))
  fi
done

echo "  Dump parity summary: $dump_parity_count/${#CORPUS_FILES[@]} modules match byte-for-byte"
if [ "$dump_parity_count" -ne "${#CORPUS_FILES[@]}" ]; then
  status=1
fi

echo
echo "== 4. Declarations parity: compiler default vs --selfhost"
decls_parity_count=0
for mod in "${CORPUS_FILES[@]}"; do
  file="$CORPUS_DIR/${mod}.iyimod"
  if [ ! -f "$file" ]; then
    continue
  fi

  "$IYI" mod dump --declarations "$file" > "$WORK/c.decls"
  "$IYI" mod dump --declarations --selfhost "$file" > "$WORK/s.decls"

  if ! diff -u "$WORK/c.decls" "$WORK/s.decls" > "$WORK/diff"; then
    echo "  DIVERGENCE in declarations for $mod:"
    cat "$WORK/diff"
    status=1
  else
    decls_parity_count=$((decls_parity_count + 1))
  fi
done

echo "  Declarations parity summary: $decls_parity_count/${#CORPUS_FILES[@]} modules match byte-for-byte"
if [ "$decls_parity_count" -ne "${#CORPUS_FILES[@]}" ]; then
  status=1
fi

echo
echo "== 5. Prefix flag compatibility: mod --selfhost dump"
prefix_count=0
for mod in "${CORPUS_FILES[@]}"; do
  file="$CORPUS_DIR/${mod}.iyimod"
  if [ ! -f "$file" ]; then
    continue
  fi

  "$IYI" mod dump "$file" > "$WORK/c.dump"
  "$IYI" mod --selfhost dump "$file" > "$WORK/p.dump"

  if ! diff -u "$WORK/c.dump" "$WORK/p.dump" > "$WORK/diff"; then
    echo "  DIVERGENCE in prefix flag for $mod"
    status=1
  else
    prefix_count=$((prefix_count + 1))
  fi
done
echo "  Prefix flag summary: $prefix_count/${#CORPUS_FILES[@]} modules match"

echo
echo "== 6. Refusal parity: damaged/corrupted artifacts refused with identical verdicts"
REFUSAL_DIR="$WORK/refusal"
mkdir -p "$REFUSAL_DIR"

BASE_FILE="$CORPUS_DIR/calc/lexer.iyimod"
python3 - "$BASE_FILE" "$REFUSAL_DIR" <<'PY'
import sys
base = open(sys.argv[1], "rb").read()
out = sys.argv[2]

open(f"{out}/short.iyimod", "wb").write(base[:4])
open(f"{out}/bad_magic.iyimod", "wb").write(b"NOTIYIMD" + base[8:])
bad_ver = bytearray(base)
bad_ver[8] = 99; bad_ver[9] = 0; bad_ver[10] = 0; bad_ver[11] = 0
open(f"{out}/bad_version.iyimod", "wb").write(bad_ver)
corrupt_payload = bytearray(base)
corrupt_payload[85] ^= 0xff
open(f"{out}/corrupt_payload.iyimod", "wb").write(corrupt_payload)
open(f"{out}/truncated_payload.iyimod", "wb").write(base[:-5])
PY

check_refusal() {
  local label="$1"
  local file="$2"
  local expected="$3"

  local c_out
  local s_out
  c_out=$("$IYI" mod dump "$file" 2>&1 || true)
  s_out=$("$IYI" mod dump --selfhost "$file" 2>&1 || true)

  local c_ok=0
  local s_ok=0

  if echo "$c_out" | grep -qF "$expected"; then
    c_ok=1
  fi
  if echo "$s_out" | grep -qF "$expected"; then
    s_ok=1
  fi

  if [ "$c_ok" -eq 1 ] && [ "$s_ok" -eq 1 ]; then
    echo "  properly refused by both: $label ($expected)"
  else
    echo "  REFUSAL MISMATCH for $label:"
    echo "    crystal output:  $c_out"
    echo "    selfhost output: $s_out"
    status=1
  fi
}

check_refusal "truncated header" "$REFUSAL_DIR/short.iyimod" "too short to be a .iyimod"
check_refusal "invalid magic bytes" "$REFUSAL_DIR/bad_magic.iyimod" "is not a .iyimod"
check_refusal "mismatched format version" "$REFUSAL_DIR/bad_version.iyimod" "format v99, this compiler writes v50"
check_refusal "damaged section payload" "$REFUSAL_DIR/corrupt_payload.iyimod" "Header section is damaged, its checksum does not match"
check_refusal "truncated section payload" "$REFUSAL_DIR/truncated_payload.iyimod" "ends inside a section"

echo
echo "== 7. Mutation proofs: each one must make the checks fail"

test_wiring_parity() {
  local f="$CORPUS_DIR/calc/lexer.iyimod"
  "$IYI" mod dump "$f" > "$WORK/test_c.dump"
  "$IYI" mod dump --selfhost "$f" > "$WORK/test_s.dump"
  diff -q "$WORK/test_c.dump" "$WORK/test_s.dump" >/dev/null || return 1
  return 0
}

test_declarations_parity() {
  local f="$CORPUS_DIR/calc/lexer.iyimod"
  "$IYI" mod dump --declarations "$f" > "$WORK/test_c.decls"
  "$IYI" mod dump --declarations --selfhost "$f" > "$WORK/test_s.decls"
  diff -q "$WORK/test_c.decls" "$WORK/test_s.decls" >/dev/null || return 1
  return 0
}

test_refusal_parity() {
  local f="$REFUSAL_DIR/bad_version.iyimod"
  local out
  out=$("$IYI" mod dump --selfhost "$f" 2>&1 || true)
  echo "$out" | grep -qF "format v99, this compiler writes v50" || return 1
  return 0
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

  # If target is iyi-mod source, recompile it
  if [ "$target_file" = "$MOD_TOOL_SRC" ] || [ "$target_file" = "$IYIMOD_SRC" ]; then
    "$IYI" build -o "$REPO/.build/iyi-mod" "$MOD_TOOL_SRC" >/dev/null 2>&1 || true
  elif [ "$target_file" = "$MOD_CR_SRC" ]; then
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
  if [ "$target_file" = "$MOD_TOOL_SRC" ] || [ "$target_file" = "$IYIMOD_SRC" ]; then
    "$IYI" build -o "$REPO/.build/iyi-mod" "$MOD_TOOL_SRC" >/dev/null 2>&1
  elif [ "$target_file" = "$MOD_CR_SRC" ]; then
    make -B iyi >/dev/null 2>&1
  fi
}

prove_wiring_mutation "corrupt self-host dump output format" \
  "$MOD_TOOL_SRC" \
  'print IyiMod.dump_to_s(art)' \
  'puts "CORRUPTED DUMP"; print IyiMod.dump_to_s(art)' \
  'test_wiring_parity'

prove_wiring_mutation "corrupt self-host declarations output format" \
  "$MOD_TOOL_SRC" \
  'print IyiMod.declarations_to_s(art)' \
  'puts "CORRUPTED DECLS"; print IyiMod.declarations_to_s(art)' \
  'test_declarations_parity'

prove_wiring_mutation "corrupt subcommand dispatched in mod command" \
  "$MOD_CR_SRC" \
  'sub = declarations ? "declarations" : "dump"' \
  'sub = "corrupted_sub"' \
  'test_wiring_parity'

prove_wiring_mutation "bypass format version validation in iyimod reader" \
  "$IYIMOD_SRC" \
  'unless format_version == FORMAT_VERSION' \
  'if false' \
  'test_refusal_parity'

echo
echo "== Verification clean state confirmed"
"$IYI" build -o "$REPO/.build/iyi-mod" "$MOD_TOOL_SRC" >/dev/null
make -B iyi >/dev/null

if [ $status -eq 0 ]; then
  echo "Parity summary: 16/16 modules match byte-for-byte across dump and declarations (100% parity)"
  echo "ALL SELFHOST MOD WIRING CHECKS PASSED SUCCESSFULLY!"
else
  echo "CHECKS FAILED"
fi

exit $status
