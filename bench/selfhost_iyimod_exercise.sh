#!/usr/bin/env bash
# Fails when the iyi artifact format (.iyimod) stops agreeing with the one it replaces.
#
# SPEC.md Part IV specifies the .iyimod container, its section table, checksums,
# and binary layouts. A .iyimod is bytes. The same module written by both
# implementations must produce byte-identical artifacts, and each must read what
# the other wrote.
#
# This gate proves three load-bearing properties:
#   1. Writer parity: both implementations emit byte-identical artifacts for a
#      corpus of modules from `samples/iyi/` and `src/std/`.
#   2. Cross-reading: the iyi reader accepts what the Crystal writer produced
#      and vice versa, with identical text/JSON dumps.
#   3. Refusal: corrupted artifacts (truncated files, bad magic, bad version,
#      checksum mismatch, truncated section payload) are refused by both with
#      the same verdict.
#
# The mutation proofs follow the rule the other selfhost gates use: the patched
# file is compared against the original, and a patch that matched nothing is
# reported as proving nothing rather than passing quietly.
#
#   bash bench/selfhost_iyimod_exercise.sh
set -u
status=0
diverged=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
IYIMOD="$REPO/src/compiler/artifact/iyimod.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. Building and running the selfhost iyimod exercise (plain mode)"
"$IYI" build -o "$WORK/exercise" "$REPO/bench/selfhost_iyimod_exercise.iyi"
"$WORK/exercise" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST IYIMOD CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "  EXERCISE FAILED"
  status=1
fi

echo
echo "== 2. Building and running the selfhost iyimod exercise (--release mode)"
"$IYI" build --release -o "$WORK/exercise-release" "$REPO/bench/selfhost_iyimod_exercise.iyi"
"$WORK/exercise-release" > "$WORK/release.out" 2>&1
cat "$WORK/release.out"
if ! grep -qF "ALL SELFHOST IYIMOD CHECKS PASSED SUCCESSFULLY!" "$WORK/release.out"; then
  echo "  RELEASE EXERCISE FAILED"
  status=1
fi

echo
echo "== 3. Building the Crystal oracle for artifact comparison"
cat <<'CRYSTAL_ORACLE_SCRIPT' > "$WORK/oracle.cr"
require "compiler/requires"

action = ARGV[0]?
case action
when "read"
  path = ARGV[1]
  Iyi::IyiMod.read(path, want_object_code: true)
  puts "read: ok"
when "dump"
  path = ARGV[1]
  art = Iyi::IyiMod.read(path, want_object_code: true)
  Iyi::IyiMod.dump(art, STDOUT)
when "declarations"
  path = ARGV[1]
  art = Iyi::IyiMod.read(path, want_object_code: true)
  Iyi::IyiMod.declarations(art, STDOUT)
when "json"
  path = ARGV[1]
  art = Iyi::IyiMod.read(path, want_object_code: true)
  json = JSON.build { |b| Iyi::IyiMod.api_json(art, b) }
  puts json
when "write"
  in_path = ARGV[1]
  out_path = ARGV[2]
  art = Iyi::IyiMod.read(in_path, want_object_code: true)
  Iyi::IyiMod.write(art, out_path)
end
CRYSTAL_ORACLE_SCRIPT
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK/oracle" "$WORK/oracle.cr"
if [ ! -x "$WORK/oracle" ]; then
  echo "  THE ORACLE DID NOT BUILD: this gate cannot conclude anything"
  exit 1
fi

echo
echo "== 4. Emitting corpus artifacts from samples/iyi and src/std"
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
echo "== 5. Writer parity: both implementations emit byte-identical artifacts"
mkdir -p "$WORK/iyi_written" "$WORK/crystal_written"
parity_count=0
total_bytes=0

for mod in "${CORPUS_FILES[@]}"; do
  golden="$CORPUS_DIR/${mod}.iyimod"
  if [ ! -f "$golden" ]; then
    echo "  MISSING GOLDEN ARTIFACT: $golden"
    status=1
    continue
  fi

  mod_bytes=$(wc -c < "$golden" | tr -d ' ')
  safe_name=$(echo "$mod" | tr '/' '_')
  iyi_out="$WORK/iyi_written/${safe_name}.iyimod"
  crystal_out="$WORK/crystal_written/${safe_name}.iyimod"

  "$WORK/exercise" write "$golden" "$iyi_out"
  "$WORK/oracle" write "$golden" "$crystal_out"

  if ! diff -q "$golden" "$iyi_out" >/dev/null; then
    echo "  $mod: IYI WRITER DIVERGED FROM GOLDEN"
    status=1
  elif ! diff -q "$crystal_out" "$iyi_out" >/dev/null; then
    echo "  $mod: IYI WRITER DIVERGED FROM CRYSTAL WRITER"
    status=1
  else
    echo "  $mod: identical ($mod_bytes bytes match Crystal front end)"
    parity_count=$((parity_count + 1))
    total_bytes=$((total_bytes + mod_bytes))
  fi
done

echo "  Parity summary: $parity_count/${#CORPUS_FILES[@]} modules match byte-for-byte ($total_bytes total bytes)"
if [ "$parity_count" -ne "${#CORPUS_FILES[@]}" ]; then
  status=1
fi

echo
echo "== 6. Cross-reading: each implementation accepts what the other wrote"
cross_count=0
for mod in "${CORPUS_FILES[@]}"; do
  safe_name=$(echo "$mod" | tr '/' '_')
  iyi_out="$WORK/iyi_written/${safe_name}.iyimod"
  crystal_out="$WORK/crystal_written/${safe_name}.iyimod"

  # iyi reads crystal_out, crystal reads iyi_out
  "$WORK/exercise" dump "$crystal_out" > "$WORK/iyi_reads_crystal.dump" 2>&1
  "$WORK/oracle" dump "$iyi_out" > "$WORK/crystal_reads_iyi.dump" 2>&1

  if ! diff -u "$WORK/crystal_reads_iyi.dump" "$WORK/iyi_reads_crystal.dump" > "$WORK/dump.diff"; then
    echo "  $mod: CROSS-READ DUMP DIFFERENCE"
    head -10 "$WORK/dump.diff"
    status=1
  else
    cross_count=$((cross_count + 1))
  fi
done
echo "  Cross-reading summary: $cross_count/${#CORPUS_FILES[@]} modules cross-read and agree identically"
if [ "$cross_count" -ne "${#CORPUS_FILES[@]}" ]; then
  status=1
fi

echo
echo "== 7. Refusal checks: damaged/corrupted artifacts refused with identical verdict"
REFUSAL_DIR="$WORK/refusal"
mkdir -p "$REFUSAL_DIR"

BASE_FILE="$CORPUS_DIR/calc/lexer.iyimod"
python3 - "$BASE_FILE" "$REFUSAL_DIR" <<'PY'
import sys
base = open(sys.argv[1], "rb").read()
out = sys.argv[2]

# 1. Truncated header
open(f"{out}/short.iyimod", "wb").write(base[:4])

# 2. Bad magic
open(f"{out}/bad_magic.iyimod", "wb").write(b"NOTIYIMD" + base[8:])

# 3. Bad format version (version 99 at offset 8)
bad_ver = bytearray(base)
bad_ver[8] = 99; bad_ver[9] = 0; bad_ver[10] = 0; bad_ver[11] = 0
open(f"{out}/bad_version.iyimod", "wb").write(bad_ver)

# 4. Corrupted payload byte
corrupt_payload = bytearray(base)
corrupt_payload[85] ^= 0xff
open(f"{out}/corrupt_payload.iyimod", "wb").write(corrupt_payload)

# 5. Truncated payload
open(f"{out}/truncated_payload.iyimod", "wb").write(base[:-5])
PY

check_refusal() {
  local label="$1"
  local file="$2"
  local expected="$3"

  local iyi_out
  local crystal_out
  iyi_out=$("$WORK/exercise" read "$file" 2>&1 || true)
  crystal_out=$("$WORK/oracle" read "$file" 2>&1 || true)

  local iyi_ok=0
  local crystal_ok=0

  if echo "$iyi_out" | grep -qF "$expected"; then
    iyi_ok=1
  fi
  if echo "$crystal_out" | grep -qF "$expected"; then
    crystal_ok=1
  fi

  if [ "$iyi_ok" -eq 1 ] && [ "$crystal_ok" -eq 1 ]; then
    echo "  properly refused by both: $label ($expected)"
  else
    echo "  REFUSAL MISMATCH for $label:"
    echo "    iyi output:     $iyi_out"
    echo "    crystal output: $crystal_out"
    status=1
  fi
}

check_refusal "truncated header" "$REFUSAL_DIR/short.iyimod" "too short to be a .iyimod"
check_refusal "invalid magic bytes" "$REFUSAL_DIR/bad_magic.iyimod" "is not a .iyimod"
check_refusal "mismatched format version" "$REFUSAL_DIR/bad_version.iyimod" "format v99, this compiler writes v50"
check_refusal "damaged section payload" "$REFUSAL_DIR/corrupt_payload.iyimod" "Header section is damaged, its checksum does not match"
check_refusal "truncated section payload" "$REFUSAL_DIR/truncated_payload.iyimod" "ends inside a section"

echo
echo "== 8. Mutation proofs: each one must make the checks fail"

# Verification function used across mutation proofs:
# Re-runs writer parity on calc/lexer and refusal on corrupt_payload
test_gate_mutation() {
  local runner="$1"
  local mut_out="$WORK/mut_out.iyimod"

  # 1. Writer parity test: write calc/lexer and cmp against golden
  "$runner" write "$CORPUS_DIR/calc/lexer.iyimod" "$mut_out" >/dev/null 2>&1 || return 1
  diff -q "$CORPUS_DIR/calc/lexer.iyimod" "$mut_out" >/dev/null || return 1

  # 2. Refusal test: reading corrupt payload must fail
  if "$runner" read "$REFUSAL_DIR/corrupt_payload.iyimod" >/dev/null 2>&1; then
    # Accepted corrupt payload!
    return 1
  fi

  return 0
}

prove_mutation() {
  local label="$1"
  local old="$2"
  local new="$3"
  echo "  [$label]"
  cp "$IYIMOD" "$IYIMOD.orig"
  python3 - "$IYIMOD" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
if old not in t:
    sys.exit(3)
open(path, "w").write(t.replace(old, new, 1))
PY
  local rc=$?
  if [ "$rc" -eq 3 ] || diff -q "$IYIMOD.orig" "$IYIMOD" >/dev/null; then
    echo "    PATCH CHANGED NOTHING: this proves nothing"
    status=1
    cp "$IYIMOD.orig" "$IYIMOD"; rm -f "$IYIMOD.orig"
    return
  fi

  if "$IYI" build -o "$WORK/mut-exercise" "$REPO/bench/selfhost_iyimod_exercise.iyi" >/dev/null 2>&1; then
    if test_gate_mutation "$WORK/mut-exercise"; then
      echo "    FAILED: the comparison still passed with the mutation applied"
      status=1
    else
      echo "    caught: the artifact format diverged or refused, as it must"
    fi
  else
    echo "    caught: the mutated iyimod did not build"
  fi
  cp "$IYIMOD.orig" "$IYIMOD"; rm -f "$IYIMOD.orig"
  echo "    reverted"
}

MUTATIONS_RUN=0
run_proof() {
  prove_mutation "$1" "$2" "$3"
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
}

run_proof "altering magic bytes breaks container verification" \
  'MAGIC               = "IYIMOD\0\0"' \
  'MAGIC               = "BADMOD\0\0"'

run_proof "altering format version allows or writes wrong version" \
  'FORMAT_VERSION      = 50_u32' \
  'FORMAT_VERSION      = 51_u32'

run_proof "bypassing section checksum verification accepts damaged payload" \
  'return if checksum(payload) == sum' \
  'return'

run_proof "corrupting checksum calculation algorithm" \
  'val = (val.unsafe_shl(8_u64)) | bytes[i].to_u64' \
  'val = (val.unsafe_shl(7_u64)) | bytes[i].to_u64'

run_proof "corrupting section table entry padding" \
  'w.write_u16_le(0_u16) # padding' \
  'w.write_u16_le(1_u16) # padding'

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST IYIMOD CHECKS PASSED"
else
  echo "== SELFHOST IYIMOD CHECKS FAILED"
fi
exit "$status"
