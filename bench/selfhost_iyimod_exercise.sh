#!/usr/bin/env bash
# Fails when the iyi artifact format (.iyimod) stops agreeing with the one it replaces.
#
# SPEC.md Part IV specifies the .iyimod container, its section table, checksums,
# and binary layouts. A .iyimod is bytes. The same module written by both
# implementations must produce byte-identical artifacts, and each must read what
# the other wrote.
#
# This gate checks four load-bearing properties:
#   1. Writer parity: both implementations emit byte-identical artifacts for a
#      corpus of modules from `samples/iyi/` and `src/std/`.
#   2. Cross-reading: each reader accepts the other writer's artifacts and
#      produces identical text dumps.
#   3. The standalone iyi-mod driver matches the hosted reader's dump,
#      declarations and compact JSON for every corpus artifact.
#   4. Refusal: corrupted artifacts are refused by both with the same verdict.
#
# The mutation proofs follow the rule the other selfhost gates use: the patched
# file is compared against the original, and a patch that matched nothing is
# reported as proving nothing rather than passing quietly.
#
#   bash bench/selfhost_iyimod_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  echo "  FAILED: a functional Python interpreter is required" >&2
  exit 1
fi
if ! command -v perl >/dev/null 2>&1; then
  echo "  FAILED: perl is required for the mutation proofs" >&2
  exit 1
fi
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
IYIMOD="$REPO/src/compiler/artifact/iyimod.iyi"
. "$REPO/bench/lib/mutation.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE="$(native_path "$REPO")" || exit 1
WORK_NATIVE="$(native_path "$WORK")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
export TEST_SANDBOX="$WORK_NATIVE"
export TMPDIR="$WORK_NATIVE"

echo "== 1. Building and running the selfhost iyimod exercise (plain mode)"
if ! "$IYI" build -o "$WORK_NATIVE/exercise$EXE" "$REPO_NATIVE/bench/selfhost_iyimod_exercise.iyi"; then
  echo "  FAILED to build the plain exercise"
  exit 1
fi
if ! "$WORK/exercise$EXE" > "$WORK/plain.out" 2>&1; then
  echo "  PLAIN EXERCISE FAILED"
  cat "$WORK/plain.out"
  exit 1
fi
cat "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST IYIMOD CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "  EXERCISE DID NOT REPORT SUCCESS"
  status=1
fi

echo
echo "== 2. Building and running the selfhost iyimod exercise (--release mode)"
if ! "$IYI" build --release -o "$WORK_NATIVE/exercise-release$EXE" "$REPO_NATIVE/bench/selfhost_iyimod_exercise.iyi"; then
  echo "  FAILED to build the release exercise"
  exit 1
fi
if ! "$WORK/exercise-release$EXE" > "$WORK/release.out" 2>&1; then
  echo "  RELEASE EXERCISE FAILED"
  cat "$WORK/release.out"
  exit 1
fi
cat "$WORK/release.out"
if ! grep -qF "ALL SELFHOST IYIMOD CHECKS PASSED SUCCESSFULLY!" "$WORK/release.out"; then
  echo "  RELEASE EXERCISE DID NOT REPORT SUCCESS"
  status=1
fi

echo
echo "== 3. Building the hosted oracle for artifact comparison"
cat <<'HOSTED_ORACLE_SCRIPT' > "$WORK/oracle.cr"
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
when "write-pins"
  art = Iyi::IyiMod.read(ARGV[1], want_object_code: true)
  art.spawns = [Iyi::IyiMod::SpawnRecord.new("owner", "digest", 12, 7, true, true, "reason", true)]
  art.pins = [Iyi::IyiMod::PinRecord.new("Unit.new", 14, 9, "owning capture")]
  art.reaches = [Iyi::IyiMod::ReachRecord.new("owner", "state", "Box", "the constant", "read", ["call"], "", "example", "Box")]
  Iyi::IyiMod.write(art, ARGV[2])
end
HOSTED_ORACLE_SCRIPT
if ! LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO_NATIVE/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK_NATIVE/oracle$EXE" "$WORK_NATIVE/oracle.cr" > "$WORK/oracle_build.log" 2>&1; then
  echo "  FAILED to build the hosted oracle:"
  cat "$WORK/oracle_build.log"
  exit 1
fi
if [ ! -x "$WORK/oracle$EXE" ]; then
  echo "  THE ORACLE DID NOT BUILD: this gate cannot conclude anything"
  cat "$WORK/oracle_build.log"
  exit 1
fi

echo
echo "== 4. Emitting corpus artifacts from samples/iyi and src/std"
CORPUS_DIR="$WORK/corpus"
mkdir -p "$CORPUS_DIR" "$WORK/emit"
CORPUS_NATIVE="$(native_path "$CORPUS_DIR")" || exit 1
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
  sample_name="$(basename "$sample" .iyi)"
  sample_native="$(native_path "$sample")" || exit 1
  "$IYI" build --emit-iyimod "$CORPUS_NATIVE" --no-codegen "$sample_native" \
    > "$WORK/emit/$sample_name.log" 2>&1 || true
done
mkdir -p "$CORPUS_DIR/format"
if ! "$WORK/oracle$EXE" write-pins "$CORPUS_NATIVE/calc/lexer.iyimod" "$CORPUS_NATIVE/format/pins.iyimod"; then
  echo "  FAILED to generate v63 and v64 fixture"
  exit 1
fi

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
  "format/pins"
  "app/formal"
)

echo
echo "== 5. Writer parity: both implementations emit byte-identical artifacts"
mkdir -p "$WORK/iyi_written" "$WORK/hosted_written"
parity_count=0
total_bytes=0
missing_goldens=0

for mod in "${CORPUS_FILES[@]}"; do
  golden="$CORPUS_DIR/${mod}.iyimod"
  if [ ! -f "$golden" ]; then
    echo "  MISSING GOLDEN ARTIFACT: $golden"
    if [ "$missing_goldens" -eq 0 ]; then
      echo "  Corpus emission logs:"
      for log in "$WORK"/emit/*.log; do
        echo "  --- $(basename "$log") ---"
        cat "$log"
      done
    fi
    missing_goldens=$((missing_goldens + 1))
    status=1
    continue
  fi

  mod_bytes=$(wc -c < "$golden" | tr -d ' ')
  safe_name=$(echo "$mod" | tr '/' '_')
  iyi_out="$WORK/iyi_written/${safe_name}.iyimod"
  hosted_out="$WORK/hosted_written/${safe_name}.iyimod"
  golden_native="$CORPUS_NATIVE/${mod}.iyimod"
  iyi_native="$WORK_NATIVE/iyi_written/${safe_name}.iyimod"
  hosted_native="$WORK_NATIVE/hosted_written/${safe_name}.iyimod"

  if ! "$WORK/exercise$EXE" write "$golden_native" "$iyi_native" > "$WORK/iyi_write.log" 2>&1; then
    echo "  $mod: IYI WRITER FAILED"
    cat "$WORK/iyi_write.log"
    rm -f "$iyi_out"
    status=1
    continue
  fi
  if ! "$WORK/oracle$EXE" write "$golden_native" "$hosted_native" > "$WORK/hosted_write.log" 2>&1; then
    echo "  $mod: HOSTED WRITER FAILED"
    cat "$WORK/hosted_write.log"
    rm -f "$hosted_out"
    status=1
    continue
  fi

  if ! cmp -s "$golden" "$iyi_out"; then
    echo "  $mod: IYI WRITER DIVERGED FROM GOLDEN"
    status=1
  elif ! cmp -s "$hosted_out" "$iyi_out"; then
    echo "  $mod: IYI WRITER DIVERGED FROM HOSTED WRITER"
    status=1
  else
    echo "  $mod: identical ($mod_bytes bytes match hosted writer)"
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
  hosted_out="$WORK/hosted_written/${safe_name}.iyimod"
  iyi_native="$WORK_NATIVE/iyi_written/${safe_name}.iyimod"
  hosted_native="$WORK_NATIVE/hosted_written/${safe_name}.iyimod"

  if [ ! -f "$iyi_out" ] || [ ! -f "$hosted_out" ]; then
    echo "  $mod: CROSS-READ ARTIFACT MISSING"
    status=1
    continue
  fi
  if ! "$WORK/exercise$EXE" dump "$hosted_native" > "$WORK/iyi_reads_hosted.dump" 2>&1; then
    echo "  $mod: IYI READER FAILED"
    cat "$WORK/iyi_reads_hosted.dump"
    status=1
    continue
  fi
  if ! "$WORK/oracle$EXE" dump "$iyi_native" > "$WORK/hosted_reads_iyi.dump" 2>&1; then
    echo "  $mod: HOSTED READER FAILED"
    cat "$WORK/hosted_reads_iyi.dump"
    status=1
    continue
  fi
  if ! diff -u "$WORK/hosted_reads_iyi.dump" "$WORK/iyi_reads_hosted.dump" > "$WORK/dump.diff"; then
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
echo "== 7. Comparing the standalone iyi-mod driver with the hosted reader"
driver_count=0
driver_ready=1
if ! "$IYI" build -o "$WORK_NATIVE/iyi-mod$EXE" "$REPO_NATIVE/src/compiler/tools/mod.iyi" > "$WORK/driver_build.log" 2>&1; then
  echo "  FAILED to build iyi-mod:"
  cat "$WORK/driver_build.log"
  driver_ready=0
  status=1
elif [ ! -x "$WORK/iyi-mod$EXE" ]; then
  echo "  FAILED: iyi-mod executable is missing"
  cat "$WORK/driver_build.log"
  driver_ready=0
  status=1
fi

if [ "$driver_ready" -eq 1 ]; then
  for mod in "${CORPUS_FILES[@]}"; do
    golden="$CORPUS_DIR/${mod}.iyimod"
    if [ ! -f "$golden" ]; then
      echo "  $mod: IYI-MOD GOLDEN ARTIFACT MISSING"
      status=1
      continue
    fi
    golden_native="$CORPUS_NATIVE/${mod}.iyimod"
    module_ok=1
    for action in dump declarations json; do
      if ! "$WORK/iyi-mod$EXE" "$action" "$golden_native" > "$WORK/driver.out" 2> "$WORK/driver.err"; then
        echo "  $mod: IYI-MOD $action FAILED"
        cat "$WORK/driver.err"
        module_ok=0
        status=1
        continue
      fi
      if ! "$WORK/oracle$EXE" "$action" "$golden_native" > "$WORK/hosted.out" 2> "$WORK/hosted.err"; then
        echo "  $mod: HOSTED $action FAILED"
        cat "$WORK/hosted.err"
        module_ok=0
        status=1
        continue
      fi
      if ! cmp -s "$WORK/hosted.out" "$WORK/driver.out"; then
        echo "  $mod: IYI-MOD $action DIFFERENCE"
        diff -u "$WORK/hosted.out" "$WORK/driver.out" > "$WORK/driver.diff" || true
        head -20 "$WORK/driver.diff"
        module_ok=0
        status=1
      fi
    done
    if [ "$module_ok" -eq 1 ]; then
      driver_count=$((driver_count + 1))
    fi
  done
fi
echo "  iyi-mod: $driver_count/${#CORPUS_FILES[@]} modules identical to the hosted reader in dump, declarations and json"
if [ "$driver_count" -ne "${#CORPUS_FILES[@]}" ]; then
  status=1
fi

# The corpus has module macros; this artifact also exercises type-owned macros,
# omitted docs and a non-public module macro that must stay out of the API.
macro_ready=0
if [ "$driver_ready" -eq 1 ]; then
  if ! "$WORK/exercise$EXE" write-macros "$WORK_NATIVE/macros.iyimod" > "$WORK/macros-build.log" 2>&1; then
    echo "  FAILED to write the macro artifact"
    cat "$WORK/macros-build.log"
    status=1
  else
    macro_ready=1
    for action in dump declarations json; do
      if ! "$WORK/iyi-mod$EXE" "$action" "$WORK_NATIVE/macros.iyimod" > "$WORK/macros-driver-$action.out" 2> "$WORK/macros-driver.err"; then
        echo "  macro artifact: IYI-MOD $action FAILED"
        cat "$WORK/macros-driver.err"
        macro_ready=0
        status=1
        continue
      fi
      if ! "$WORK/oracle$EXE" "$action" "$WORK_NATIVE/macros.iyimod" > "$WORK/macros-hosted-$action.out" 2> "$WORK/macros-hosted.err"; then
        echo "  macro artifact: HOSTED $action FAILED"
        cat "$WORK/macros-hosted.err"
        macro_ready=0
        status=1
        continue
      fi
      if ! cmp -s "$WORK/macros-hosted-$action.out" "$WORK/macros-driver-$action.out"; then
        echo "  macro artifact: IYI-MOD $action DIFFERENCE"
        diff -u "$WORK/macros-hosted-$action.out" "$WORK/macros-driver-$action.out" || true
        macro_ready=0
        status=1
      fi
    done
    if [ "$macro_ready" -eq 1 ]; then
      echo "  iyi-mod: module and type macro artifact matches hosted dump, declarations and json"
    fi
  fi
fi

echo
echo "== 8. Refusal checks: damaged/corrupted artifacts refused with identical verdict"
REFUSAL_DIR="$WORK/refusal"
mkdir -p "$REFUSAL_DIR"
REFUSAL_NATIVE="$(native_path "$REFUSAL_DIR")" || exit 1

BASE_FILE="$CORPUS_DIR/calc/lexer.iyimod"
if [ ! -f "$BASE_FILE" ]; then
  echo "  REFUSAL FIXTURES CANNOT BE GENERATED: base artifact is missing"
  exit 1
fi
"$PY" - "$(native_path "$BASE_FILE")" "$REFUSAL_NATIVE" <<'PY'
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
header_at = 16 + 16 * int.from_bytes(base[12:16], "little") + 4
corrupt_payload[header_at] ^= 0xff
open(f"{out}/corrupt_payload.iyimod", "wb").write(corrupt_payload)

# 5. Truncated payload
open(f"{out}/truncated_payload.iyimod", "wb").write(base[:-5])

# Spec IV.2a: valid checksums do not make hostile counts trustworthy.
import hashlib, struct
u32 = lambda n: struct.pack("<I", n)
def artifact(sections):
    table = b"".join(struct.pack("<HHIQ", kind, 0, len(data),
        int.from_bytes(hashlib.md5(data).digest()[:8], "big")) for kind, data in sections)
    return base[:12] + u32(len(sections)) + table + b"".join(data for _, data in sections)
def header(flags=0):
    return b"".join(u32(len(s)) + s for s in (b"app/greeter", b"/src/app/greeter.iyi", b"1.0", b"triple")) + u32(flags) + bytes(6)
def nested(depth, closed, repeat):
    total = 4 + depth * 77 + (16 if closed else 0)
    result = bytearray(4)
    for _ in range(depth):
        left = total - len(result) - 4
        result += u32(left // 77 if repeat else 1) + bytes(73)
    if closed:
        result += bytes(16)
    return bytes(result)
def save(name, data):
    open(f"{out}/{name}.iyimod", "wb").write(data)
save("table_count", base[:12] + u32(0x7fffffff))
save("table_lengths", base[:12] + u32(2) + (struct.pack("<HHIQ", 1, 0, 0xfffffff0, 0) * 2) + b"four")
save("count_room", artifact([(1, header(0x7fffffff))]))
save("string_room", artifact([(1, u32(0xfffffff0) + b"x" * 26)]))
save("nested_claims", artifact([(1, header()), (4, nested(5000, False, True))]))
save("nested_depth", artifact([(1, header()), (4, nested(202, True, False))]))
PY
if [ "$?" -ne 0 ]; then
  echo "  FAILED to generate refusal fixtures"
  exit 1
fi

check_refusal() {
  local label="$1"
  local file="$2"
  local expected="$3"
  local iyi_out hosted_out
  local iyi_rc=0 hosted_rc=0

  iyi_out=$("$WORK/exercise$EXE" read "$file" 2>&1) || iyi_rc=$?
  hosted_out=$("$WORK/oracle$EXE" read "$file" 2>&1) || hosted_rc=$?

  if [ "$iyi_rc" -ne 0 ] && [ "$hosted_rc" -ne 0 ] &&
     printf '%s\n' "$iyi_out" | grep -qF "$expected" &&
     printf '%s\n' "$hosted_out" | grep -qF "$expected"; then
    echo "  properly refused by both: $label ($expected)"
  else
    echo "  REFUSAL MISMATCH for $label:"
    echo "    iyi output ($iyi_rc):    $iyi_out"
    echo "    hosted output ($hosted_rc): $hosted_out"
    status=1
  fi
}

check_refusal "truncated header" "$REFUSAL_NATIVE/short.iyimod" "too short to be a .iyimod"
check_refusal "invalid magic bytes" "$REFUSAL_NATIVE/bad_magic.iyimod" "is not a .iyimod"
check_refusal "mismatched format version" "$REFUSAL_NATIVE/bad_version.iyimod" "format v99, this compiler writes v64"
check_refusal "damaged section payload" "$REFUSAL_NATIVE/corrupt_payload.iyimod" "Header section is damaged, its checksum does not match"
check_refusal "truncated section payload" "$REFUSAL_NATIVE/truncated_payload.iyimod" "bytes follow the table"
check_refusal "table count" "$REFUSAL_NATIVE/table_count.iyimod" "its table names 2147483647 sections and 0 bytes follow it, which is room for 0"
check_refusal "section length sum" "$REFUSAL_NATIVE/table_lengths.iyimod" "its table says its sections are 8589934560 bytes together and 4 bytes follow the table"
check_refusal "count exceeds section" "$REFUSAL_NATIVE/count_room.iyimod" "$REFUSAL_NATIVE/count_room.iyimod is not a readable .iyimod: a section counts 2147483647 of something that takes 4 bytes or more each, and has 6 bytes left. It is damaged, or was written by something that is not this compiler; rebuild it with \`--emit-iyimod\`"
check_refusal "string exceeds section" "$REFUSAL_NATIVE/string_room.iyimod" "$REFUSAL_NATIVE/string_room.iyimod is not a readable .iyimod: a section counts 4294967280 of something that takes 1 byte or more each, and has 26 bytes left. It is damaged, or was written by something that is not this compiler; rebuild it with \`--emit-iyimod\`"
check_refusal "nested cumulative claims" "$REFUSAL_NATIVE/nested_claims.iyimod" "$REFUSAL_NATIVE/nested_claims.iyimod is not a readable .iyimod: a section's counts claim 769769 bytes between them, and it is 385004 bytes long. It is damaged, or was written by something that is not this compiler; rebuild it with \`--emit-iyimod\`"
check_refusal "type nesting" "$REFUSAL_NATIVE/nested_depth.iyimod" "$REFUSAL_NATIVE/nested_depth.iyimod is not a readable .iyimod: a section declares types more than 200 deep inside one another, which is deeper than a .iyimod holds. It is damaged, or was written by something that is not this compiler; rebuild it with \`--emit-iyimod\`"
deep_writer_rc=0
deep_writer_out=$("$WORK/exercise$EXE" write-deep "$WORK_NATIVE/too-deep.iyimod" 2>&1) || deep_writer_rc=$?
if [ "$deep_writer_rc" -eq 0 ] || ! printf '%s\n' "$deep_writer_out" | grep -qF "T202 is declared more than 200 types deep, which is deeper than a .iyimod holds"; then
  echo "  WRITER REFUSAL MISMATCH: $deep_writer_out"
  status=1
fi

echo
echo "== 9. Mutation proofs: each one must make the checks fail"

# A build failure or missing executable is an invalid mutant, not a caught defect.
build_mutant() {
  rm -f "$WORK/mut-exercise$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_iyimod_exercise.iyi" > "$WORK/mut-build.log" 2>&1; then
    echo "INVALID MUTANT: iyimod exercise failed to build" > "$WORK/invalid-mutant"
    return 1
  fi
  if [ ! -x "$WORK/mut-exercise$EXE" ]; then
    echo "INVALID MUTANT: iyimod exercise executable is missing" > "$WORK/invalid-mutant"
    return 1
  fi
  return 0
}

# Re-run writer parity on calc/lexer and the corrupt-payload refusal.
test_gate_mutation() {
  local runner="$1"
  local mut_out="$WORK/mut_out.iyimod"

  "$runner" write "$CORPUS_NATIVE/calc/lexer.iyimod" "$WORK_NATIVE/mut_out.iyimod" > "$WORK/mut-run.log" 2>&1 || return 1
  cmp -s "$BASE_FILE" "$mut_out" || return 1

  if "$runner" read "$REFUSAL_NATIVE/corrupt_payload.iyimod" > "$WORK/mut-run.log" 2>&1; then
    return 1
  fi
  grep -qF "Header section is damaged, its checksum does not match" "$WORK/mut-run.log"
}

check_iyimod_still_matches() {
  build_mutant || return 0
  test_gate_mutation "$WORK/mut-exercise$EXE"
}

# The shared helper prints only the tail of a failed check. Print the complete
# compiler log separately when the mutant itself could not be built.
run_mutation() {
  rm -f "$WORK/invalid-mutant"
  if ! prove_mutation "$@"; then
    if [ -f "$WORK/invalid-mutant" ]; then
      cat "$WORK/invalid-mutant" "$WORK/mut-build.log"
    fi
    status=1
  fi
}

MUTATIONS_RUN=0
run_proof() {
  run_mutation "$1" "$IYIMOD" "$2" "$3" -- check_iyimod_still_matches
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
}

# A refusal is a specific sentence, not merely a crash or a nonzero exit.
check_hardened_refusal() {
  local fixture="$1" expected="$2" verdict
  local rc=0
  build_mutant || return 0
  verdict=$("$WORK/mut-exercise$EXE" read "$REFUSAL_NATIVE/$fixture.iyimod" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] && printf '%s\n' "$verdict" | grep -qF "$expected"
}
run_mutation "table count bound" "$IYIMOD" \
  'if count * 16_u64 > room' 'if false' \
  -- check_hardened_refusal table_count "its table names 2147483647 sections"
run_mutation "table length sum bound" "$IYIMOD" \
  'if claimed > room' 'if false' \
  -- check_hardened_refusal table_lengths "its table says its sections are 8589934560 bytes together"
run_mutation "section count bound" "$IYIMOD" \
  'if claim > left' 'if false' \
  -- check_hardened_refusal count_room "a section counts 2147483647"
run_mutation "string length bound" "$IYIMOD" \
  'len = read_count(1)' 'len = read_count(2)' \
  -- check_hardened_refusal string_room "a section counts 4294967280 of something that takes 1 byte or more each, and has 26 bytes left"
run_mutation "cumulative claim bound" "$IYIMOD" \
  'if @claimed > @size.to_u64' 'if false' \
  -- check_hardened_refusal nested_claims "a section's counts claim 769769 bytes"
run_mutation "type nesting bound" "$IYIMOD" \
  'if depth > 200 && count > 0' 'if false' \
  -- check_hardened_refusal nested_depth "a section declares types more than 200 deep"
check_deep_writer_refusal() {
  local verdict
  local rc=0
  build_mutant || return 0
  verdict=$("$WORK/mut-exercise$EXE" write-deep "$WORK_NATIVE/too-deep-mut.iyimod" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] && printf '%s\n' "$verdict" | grep -qF "T202 is declared more than 200 types deep"
}
run_mutation "writer type nesting bound" "$IYIMOD" \
  'if depth > 200 && !types.empty?' 'if false' \
  -- check_deep_writer_refusal
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
MUTATIONS_RUN=$((MUTATIONS_RUN + 6))

run_proof "altering magic bytes breaks container verification" \
  'MAGIC               = "IYIMOD\0\0"' \
  'MAGIC               = "BADMOD\0\0"'

run_proof "altering format version allows or writes wrong version" \
  'FORMAT_VERSION      = 64_u32' \
  'FORMAT_VERSION      = 65_u32'

run_proof "bypassing section checksum verification accepts damaged payload" \
  'return if checksum(payload) == sum' \
  'return'

run_proof "corrupting checksum calculation algorithm" \
  'val = (val.unsafe_shl(8_u64)) | bytes[i].to_u64' \
  'val = (val.unsafe_shl(7_u64)) | bytes[i].to_u64'

run_proof "corrupting section table entry padding" \
  'w.write_u16_le(0_u16) # padding' \
  'w.write_u16_le(1_u16) # padding'

# A writer that stamps the wrong format version must be refused by the hosted
# reader, with the hosted reader's own message. Detected means the refusal is
# printed; a file the hosted reader accepts is not caught.
check_oracle_refuses_written_version() {
  local verdict
  local rc=0
  build_mutant || return 0
  "$WORK/mut-exercise$EXE" write "$CORPUS_NATIVE/calc/lexer.iyimod" "$WORK_NATIVE/mut_version.iyimod" > "$WORK/mut-run.log" 2>&1 || return 1
  verdict=$("$WORK/oracle$EXE" read "$WORK_NATIVE/mut_version.iyimod" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$verdict" | grep -qF "is .iyimod format v61, this compiler writes v64"; then
    return 1
  fi
  return 0
}

run_mutation "writing format v61 is refused by the hosted reader" "$IYIMOD" \
  'w.write_u32_le(FORMAT_VERSION)' \
  'w.write_u32_le(61_u32)' \
  -- check_oracle_refuses_written_version
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

check_pin_format() {
  build_mutant || return 0
  "$WORK/mut-exercise$EXE" write "$CORPUS_NATIVE/format/pins.iyimod" "$WORK_NATIVE/mut-pins.iyimod" > "$WORK/mut-run.log" 2>&1 || return 1
  cmp -s "$CORPUS_DIR/format/pins.iyimod" "$WORK/mut-pins.iyimod"
}
run_mutation "v63 pinned spawn bit" "$IYIMOD" \
  '(record.pinned ? 4_u8 : 0_u8)' '(record.pinned ? 0_u8 : 0_u8)' \
  -- check_pin_format
run_mutation "v64 reaches owning type" "$IYIMOD" \
  'w.write_string(record.owning)' 'w.write_string("")' \
  -- check_pin_format
MUTATIONS_RUN=$((MUTATIONS_RUN + 2))

check_macro_type_projection() {
  rm -f "$WORK/mut-iyi-mod$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut-iyi-mod$EXE" "$REPO_NATIVE/src/compiler/tools/mod.iyi" > "$WORK/mut-build.log" 2>&1; then
    echo "INVALID MUTANT: iyi-mod failed to build" > "$WORK/invalid-mutant"
    return 0
  fi
  if [ ! -x "$WORK/mut-iyi-mod$EXE" ]; then
    echo "INVALID MUTANT: iyi-mod executable is missing" > "$WORK/invalid-mutant"
    return 0
  fi
  "$WORK/mut-iyi-mod$EXE" json "$WORK_NATIVE/macros.iyimod" > "$WORK/macros-mutant.out" 2> "$WORK/macros-mutant.err" || return 1
  cmp -s "$WORK/macros-hosted-json.out" "$WORK/macros-mutant.out"
}
if [ "$macro_ready" -eq 1 ]; then
  run_mutation "type-owned macros are missing from JSON" "$IYIMOD" \
    'api_macros(decl.macros, json)' 'api_macros([] of String, json)' \
    -- check_macro_type_projection
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
else
  echo "  FAIL: macro projection baseline failed; its mutation proof cannot run"
  status=1
fi

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST IYIMOD CHECKS PASSED"
else
  echo "== SELFHOST IYIMOD CHECKS FAILED"
fi
exit "$status"
