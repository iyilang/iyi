#!/usr/bin/env bash
# The IR core gate (SPEC 3.2, slice B1). The iyi IR's text form round-trips, the verifier refuses each
# malformed fixture under its named rule, and five target layouts agree with LLVM. Windows computes
# every layout locally, using the same-head Linux LLVM reference for WASI.
#
#   bench/native_ir_exercise.sh
#   IR_ORACLE_EXPORT_DIR=/path/to/bundle bench/native_ir_exercise.sh  # Linux
#   IR_ORACLE_DIR=/path/to/bundle bench/native_ir_exercise.sh         # Windows
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd -P)
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
[ -n "$PY" ] || { echo "FAIL: a working Python interpreter is required" >&2; exit 1; }
export IYI_PATH="$(native_path "$REPO/src")"

if [ -n "${IR_ORACLE_EXPORT_DIR:-}" ] && [ "$HOST_OS" != linux ]; then
  echo "FAIL: IR_ORACLE_EXPORT_DIR requires Linux" >&2
  exit 1
fi
if [ "$HOST_OS" = windows ] && [ -z "${IR_ORACLE_DIR:-}" ]; then
  echo "FAIL: IR_ORACLE_DIR must name the same-head Linux oracle bundle" >&2
  exit 1
fi
if [ -n "${IR_ORACLE_DIR:-}" ] && [ "$HOST_OS" != windows ]; then
  echo "FAIL: IR_ORACLE_DIR is used only on Windows" >&2
  exit 1
fi
if [ -n "${IR_ORACLE_DIR:-}${IR_ORACLE_EXPORT_DIR:-}" ]; then
  HEAD_SHA=$(git rev-parse --verify 'HEAD^{commit}') || exit 1
  if ! git diff --quiet HEAD -- src bench/fixtures/ir samples/iyi/hello.iyi bench/native_ir_exercise.sh; then
    echo "FAIL: oracle inputs differ from git HEAD $HEAD_SHA" >&2
    exit 1
  fi
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-ir.XXXXXX")
RESTORE=()
restore_all() {
  local pair file backup restore_failed=0
  for pair in ${RESTORE[@]+"${RESTORE[@]}"}; do
    file=${pair%%|*}
    backup=${pair#*|}
    if ! cat "$backup" >"$file" || ! cmp -s "$backup" "$file"; then
      echo "FAIL: $file WAS NOT RESTORED: its backup is $backup" >&2
      restore_failed=1
    fi
  done
  [ "$restore_failed" -eq 0 ] || return 1
  rm -rf "$WORK"
}
trap 'restore_all || exit 2' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failed=0
fail() {
  echo "FAIL: $*"
  failed=1
}

DRV="$WORK/ir_core$EXE"
MUTANT="$WORK/mutant$EXE"
LLVM_DRV="$WORK/llvm_layout$EXE"

# The five targets, as "oracle-triple our-triple": the spelling used by the oracle hosted in Crystal, then the spelling
# the IR's DataLayout is keyed by.
TARGETS=(
  "aarch64-apple-darwin aarch64-apple-darwin"
  "aarch64-linux-gnu aarch64-unknown-linux-gnu"
  "x86_64-linux-gnu x86_64-unknown-linux-gnu"
  "x86_64-pc-windows-msvc x86_64-pc-windows-msvc"
  "wasm32-wasi wasm32-unknown-wasi"
)

build_driver() {
  ./bin/iyi build -o "$(native_path "$1")" src/compiler/tools/ir_core.iyi >"$WORK/build.log" 2>&1
}

# Export all five Linux reference sets, or validate the complete bundle and copy only WASI on Windows.
oracle_bundle() {
  local mode="$1" dir="$2"
  "$PY" - "$mode" "$(native_path "$dir")" "$(native_path "$WORK")" "$HEAD_SHA" "$HOST_ID" \
    "$(native_path "$REPO/bench/fixtures/ir/layout/shapes.iyi")" \
    "$(native_path "$REPO/.build/iyi$EXE")" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

mode, directory, workdir, head, host, shapes, compiler = sys.argv[1:]
directory, workdir = pathlib.Path(directory), pathlib.Path(workdir)
targets = {
    "aarch64-apple-darwin": "aarch64-apple-darwin",
    "aarch64-linux-gnu": "aarch64-unknown-linux-gnu",
    "x86_64-linux-gnu": "x86_64-unknown-linux-gnu",
    "x86_64-pc-windows-msvc": "x86_64-pc-windows-msvc",
    "wasm32-wasi": "wasm32-unknown-wasi",
}
names = {f"{kind}-{triple}.txt" for triple in targets
         for kind in ("layout", "oracle", "wide-oracle")}

def reject(message):
    raise ValueError(message)

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            reject(f"duplicate manifest key: {key}")
        result[key] = value
    return result

def digest(data):
    return hashlib.sha256(data).hexdigest()

def validate_data(files):
    source = pathlib.Path(shapes).read_bytes()
    keys = re.findall(rb"^def probe_([A-Za-z0-9_]+) : Int64\r?$", source, re.M)
    if len(keys) != 19 or len(set(keys)) != 19:
        reject("the shapes fixture does not declare 19 distinct probes")
    for triple in targets:
        layout = files[f"layout-{triple}.txt"]
        if not re.fullmatch(rb'target datalayout = "[^"\r\n]+"\n', layout):
            reject(f"malformed datalayout for {triple}")
        probes = files[f"oracle-{triple}.txt"]
        rows = probes.splitlines(keepends=True)
        matches = [re.fullmatch(rb"([A-Za-z0-9_]+) (-?[0-9]+)\n", row) for row in rows]
        if len(rows) != 19 or any(match is None for match in matches):
            reject(f"malformed probe rows for {triple}")
        if {match.group(1) for match in matches} != set(keys):
            reject(f"missing or duplicate probe names for {triple}")
        wide = files[f"wide-oracle-{triple}.txt"].splitlines(keepends=True)
        if len(wide) != 8:
            reject(f"expected eight wide-layout rows for {triple}")
        for index, row in enumerate(wide):
            if index in (0, 4):
                name = b"Wide" if index == 0 else b"Mid"
                valid = re.fullmatch(rb"struct " + name + rb" size=[0-9]+ align=[0-9]+\n", row)
            else:
                field = (index - 1) % 4
                valid = re.fullmatch(rb"field " + str(field).encode() +
                                     rb" offset=[0-9]+ size=[0-9]+\n", row)
            if not valid:
                reject(f"malformed wide-layout row {index + 1} for {triple}")

try:
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", head):
        reject("invalid git HEAD")
    if mode == "export":
        if not host.startswith("linux-"):
            reject("oracle producer is not Linux")
        files = {name: (workdir / name).read_bytes() for name in names}
        validate_data(files)
        identity = (workdir / "llvm-identity.txt").read_text(encoding="utf-8").splitlines()
        if len(identity) != 3 or not all(identity):
            reject("missing LLVM identity")
        llvm_targets = identity[2].split(",")
        if not {"aarch64", "x86", "webassembly"}.issubset(llvm_targets):
            reject("Linux LLVM identity lacks a required backend")
        producer = {
            "host": host,
            "llvm_runtime": identity[0],
            "llvm_compiled": identity[1],
            "llvm_targets": llvm_targets,
            "iyi_version": (workdir / "iyi-version.txt").read_text(encoding="utf-8").strip(),
            "crystal_version": (workdir / "crystal-version.txt").read_text(encoding="utf-8").strip(),
            "iyi_sha256": digest(pathlib.Path(compiler).read_bytes()),
        }
        if not producer["iyi_version"] or not producer["crystal_version"]:
            reject("missing compiler identity")
        manifest = {"format": 1, "git_head": head, "producer": producer,
                    "targets": targets, "sha256": {name: digest(files[name]) for name in sorted(names)}}
        directory.mkdir(parents=True, exist_ok=True)
        if any(directory.iterdir()):
            reject("oracle export directory is not empty")
        for name, data in files.items():
            (directory / name).write_bytes(data)
        (directory / "manifest.json").write_bytes((json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8"))
        print(f"exported five Linux LLVM reference sets at {head} to {directory}")
    elif mode == "load":
        manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"),
                              object_pairs_hook=unique_object)
        if set(manifest) != {"format", "git_head", "producer", "targets", "sha256"}:
            reject("unexpected manifest fields")
        if type(manifest["format"]) is not int or manifest["format"] != 1 or manifest["git_head"] != head or manifest["targets"] != targets:
            reject("oracle manifest format, git HEAD, or target list differs")
        producer = manifest["producer"]
        fields = {"host", "llvm_runtime", "llvm_compiled", "llvm_targets",
                  "iyi_version", "crystal_version", "iyi_sha256"}
        if not isinstance(producer, dict) or set(producer) != fields:
            reject("malformed producer identity")
        if producer["host"] not in ("linux-x86_64", "linux-arm64"):
            reject("oracle producer is not a supported Linux host")
        if any(not isinstance(producer[k], str) or not producer[k].strip()
               for k in ("llvm_runtime", "llvm_compiled", "iyi_version", "crystal_version")):
            reject("incomplete compiler or LLVM identity")
        if not isinstance(producer["llvm_targets"], list) or not all(
                isinstance(target, str) for target in producer["llvm_targets"]) or not {
                    "aarch64", "x86", "webassembly"}.issubset(producer["llvm_targets"]):
            reject("incomplete LLVM backend identity")
        if not isinstance(producer["iyi_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", producer["iyi_sha256"]):
            reject("invalid compiler checksum")
        hashes = manifest["sha256"]
        if not isinstance(hashes, dict) or set(hashes) != names:
            reject("oracle checksum list is incomplete")
        files = {name: (directory / name).read_bytes() for name in names}
        if any(not isinstance(hashes[name], str) or hashes[name] != digest(files[name]) for name in names):
            reject("oracle checksum mismatch")
        validate_data(files)
        for kind in ("layout", "oracle", "wide-oracle"):
            name = f"{kind}-wasm32-wasi.txt"
            (workdir / name).write_bytes(files[name])
        print("Windows component execution; Linux LLVM reference: "
              f"{producer['host']}, runtime LLVM {producer['llvm_runtime']}, "
              f"compiled LLVM {producer['llvm_compiled']}, git {head}")
    else:
        reject("unknown oracle bundle operation")
except (OSError, ValueError, TypeError, KeyError, UnicodeError) as error:
    print(f"FAIL: oracle bundle: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

# Native Windows LLVM lacks WebAssembly symbols. Only the temporary probe's initializers change;
# the four supported targets still run the same LLVM layout code locally.
prepare_llvm_probe() {
  "$PY" - "$(native_path "$REPO/bench/fixtures/ir/layout/llvm_layout.cr")" \
    "$(native_path "$WORK/llvm_layout.cr")" "$HOST_OS" <<'PY'
import pathlib
import sys

source, output, host = sys.argv[1:]
data = pathlib.Path(source).read_bytes()
anchor = b"triple = ARGV[0]\n"
if data.count(anchor) != 1:
    raise SystemExit("LLVM layout probe identity anchor changed")
identity = b'''if ARGV[0] == "--identity"
  puts LLVM.version
  puts LibLLVM::VERSION
  puts LibLLVM::BUILT_TARGETS.join(",")
  exit
end

'''
data = data.replace(anchor, identity + anchor, 1)
if host == "windows":
    all_targets = b"%w(aarch64 x86 webassembly)"
    if data.count(all_targets) != 1:
        raise SystemExit("LLVM layout probe target initializer changed")
    data = data.replace(all_targets, b"%w(aarch64 x86)", 1)
pathlib.Path(output).write_bytes(data)
PY
}

# Normalize external LLVM/Crystal transport only; never rewrite the tested driver's output.
normalize_oracle() {
  "$PY" - "$(native_path "$1")" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes().replace(b"\r\n", b"\n")
if b"\r" in data:
    raise SystemExit(f"invalid carriage return in oracle output: {path}")
path.write_bytes(data)
PY
}

extract_datalayout() {
  "$PY" - "$(native_path "$1")" "$(native_path "$2")" <<'PY'
import pathlib
import re
import sys

data = pathlib.Path(sys.argv[1]).read_bytes().replace(b"\r\n", b"\n")
lines = [line for line in data.split(b"\n") if line.startswith(b"target datalayout = ")]
if len(lines) != 1 or not re.fullmatch(rb'target datalayout = "[^"\r\n]+"', lines[0]):
    raise SystemExit("missing or malformed LLVM target datalayout")
pathlib.Path(sys.argv[2]).write_bytes(lines[0] + b"\n")
PY
}

# The oracle's folded probe constants for one target, as sorted "NAME VALUE" lines.
oracle_values() {
  local oracle_t="$1" out="$2"
  ./bin/iyi build --cross-compile --target "$oracle_t" --emit llvm-ir -o "$(native_path "$WORK/shapes-$oracle_t")" bench/fixtures/ir/layout/shapes.iyi >"$WORK/shapes.log" 2>&1 || return 1
  awk '
    /^define/ && /probe_/ {
      n = $0
      sub(/.*probe_/, "", n)
      sub(/(:Int64|\.3A\.Int64).*/, "", n)
      pending = n
      next
    }
    pending != "" && /ret i64/ {
      v = $0
      sub(/.*ret i64 /, "", v)
      sub(/[^-0-9].*/, "", v)
      print pending, v
      pending = ""
    }' "$WORK/shapes-$oracle_t.ll" | sort >"$out" || return 1
  [ -s "$out" ]
}

# The shapes fixture declared for one of our triples, with its DataLayout from the driver.
make_shapes_ir() {
  local our_t="$1" dl
  dl=$("$DRV" layout "$our_t" | sed 's/^target datalayout = "//; s/"$//') || return 1
  sed "s|@TRIPLE@|$our_t|; s|@DATALAYOUT@|$dl|" bench/fixtures/ir/layout/shapes.ir.in >"$WORK/shapes-$our_t.ir"
}

# Our struct layouts for one of our triples, as sorted "NAME VALUE" lines in the oracle's key format.
ours_values() {
  local bin="$1" our_t="$2" out="$3"
  "$bin" structs "$(native_path "$WORK/shapes-$our_t.ir")" | awk '
    /^struct/ { name = $2; v = $3; sub(/size=/, "", v); print "size_" name, v }
    /^field/  { v = $3; sub(/offset=/, "", v); print "offset_" name "_" $2, v }' | sort >"$out" || return 1
  [ -s "$out" ]
}

# Compares our struct layouts with the oracle on every target. Non-zero when any value differs.
struct_check() {
  local bin="$1" pair oracle_t our_t status=0
  for pair in "${TARGETS[@]}"; do
    oracle_t=${pair%% *}
    our_t=${pair#* }
    ours_values "$bin" "$our_t" "$WORK/ours-$our_t.txt" || return 1
    diff -q "$WORK/oracle-$oracle_t.txt" "$WORK/ours-$our_t.txt" >/dev/null || status=1
  done
  return $status
}

# The wide-integer struct fixture for one of our triples, as `ir_core structs` prints it. Non-zero when it cannot be made.
wide_ours() {
  local bin="$1" our_t="$2" dl
  dl=$("$DRV" layout "$our_t" | sed 's/^target datalayout = "//; s/"$//') || return 1
  sed "s|@TRIPLE@|$our_t|; s|@DATALAYOUT@|$dl|" bench/fixtures/ir/layout/wide_structs.ir.in >"$WORK/wide-$our_t.ir" || return 1
  "$bin" structs "$(native_path "$WORK/wide-$our_t.ir")"
}

# Compares the wide-integer struct layouts with LLVM's DataLayout on every target. Non-zero when any line differs.
wide_check() {
  local bin="$1" pair oracle_t our_t status=0
  for pair in "${TARGETS[@]}"; do
    oracle_t=${pair%% *}
    our_t=${pair#* }
    wide_ours "$bin" "$our_t" >"$WORK/wide-ours-$our_t.txt" || return 1
    diff -q "$WORK/wide-oracle-$oracle_t.txt" "$WORK/wide-ours-$our_t.txt" >/dev/null || status=1
  done
  return $status
}

# Every valid fixture must round-trip. Non-zero when any does not.
roundtrip_check() {
  local bin="$1" f out
  for f in bench/fixtures/ir/valid/*.ir; do
    out=$("$bin" roundtrip "$f" 2>&1) || return 1
    [ "$out" = "identical" ] || return 1
  done
  return 0
}
# LLVM writes a type before a function personality; our printer emits its
# canonical untyped spelling after parsing it.
personality_check() {
  local bin="$1" out
  out=$("$bin" print bench/fixtures/ir/accept/personality_typed.ir 2>&1) || return 1
  echo "$out" | grep -qF 'personality @personality'
}


# Decimal floating-point constants must be read as the bit patterns they name. Non-zero when any is not.
decimal_check() {
  local bin="$1" out want
  out=$("$bin" print bench/fixtures/ir/accept/decimal_float.ir 2>&1) || return 1
  for want in \
    '@half = internal global double 0x3fe0000000000000' \
    '@single = internal global float 0x3fc00000' \
    '@plain = internal global double 0x4002000000000000' \
    '@negative = internal global double 0xbff8000000000000' \
    '  ret double 0x3ff8000000000000'; do
    echo "$out" | grep -qxF -- "$want" || return 1
  done
  return 0
}

# LLVM's form of a float constant, the double of the same value, must be read as the float's own bits, and a
# double must keep its sixteen digits. Non-zero when any is not.
llvm_float_check() {
  local bin="$1" out want
  out=$("$bin" print bench/fixtures/ir/accept/llvm_float.ir 2>&1) || return 1
  for want in \
    '@lowest = internal global float 0xff7fffff' \
    '@one_and_a_half = internal global float 0x3fc00000' \
    '@infinite = internal global float 0x7f800000' \
    '@not_a_number = internal global float 0x7fc00000' \
    '@smallest = internal global float 0x00000001' \
    '@own_form = internal global float 0x3fc00000' \
    '@double_kept = internal global double 0xc7efffffe0000000' \
    '  %sum = fadd float 0x3fc00000, 0x40200000'; do
    echo "$out" | grep -qxF -- "$want" || return 1
  done
  return 0
}

# A named type is written only when the module mentions it: in a global's type or initializer, in an attribute
# of a signature, in an alloca or as a getelementptr's source type, directly or inside another type. Non-zero
# when a type nothing mentions is written, or a mentioned one is not.
named_types_check() {
  local bin="$1" out want
  out=$("$bin" print bench/fixtures/ir/accept/named_types.ir 2>&1) || return 1
  if echo "$out" | grep -q '^%Unused'; then return 1; fi
  for want in \
    '%Nested = type { i64 }' \
    '%ByGlobal = type { i32, %Nested }' \
    '%ByInitializer = type { i32 }' \
    '%ByAttribute = type { i64, i64, i64 }' \
    '%ByParameter = type { i64, i64, i64 }' \
    '%ByGep = type { i8, i64 }' \
    '%ByAlloca = type { i16 }'; do
    echo "$out" | grep -qxF -- "$want" || return 1
  done
  return 0
}

# Named types must be written in LLVM TypeFinder discovery order, not type-table creation order.
named_type_order_check() {
  local bin="$1" out expected
  out=$("$bin" print bench/fixtures/ir/accept/named_types.ir 2>&1 | grep ' = type ') || return 1
  expected='%ByGlobal = type { i32, %Nested }
%Nested = type { i64 }
%ByInitializer = type { i32 }
%ByAttribute = type { i64, i64, i64 }
%ByParameter = type { i64, i64, i64 }
%ByAlloca = type { i16 }
%ByGep = type { i8, i64 }'
  [ "$out" = "$expected" ]
}

# The tls-fresh fixture must be refused under its rule. Non-zero when it is accepted or refused another way.
tls_check() {
  local bin="$1" out
  out=$("$bin" verify bench/fixtures/ir/bad/tls_fresh_call.ir 2>&1) && return 1
  echo "$out" | grep -q 'error\[tls-fresh\]'
}
ptrtoint_check() {
  local bin="$1" out
  out=$("$bin" verify bench/fixtures/ir/bad/ptrtoint_aggregate.ir 2>&1) && return 1
  echo "$out" | grep -q 'error\[types\].*ptrtoint needs a pointer operand and integer result'
}
# The same-width trunc fixture must be refused under types. Non-zero when it is accepted or refused another way.
trunc_same_width_check() {
  local bin="$1" out
  out=$("$bin" verify bench/fixtures/ir/bad/review_trunc_same_width.ir 2>&1) && return 1
  echo "$out" | grep -q 'error\[types\].*trunc must narrow an integer'
}


# The named-struct C-convention fixture must be refused under cc-lowered. Non-zero when it is accepted or refused another way.
cc_named_check() {
  local bin="$1" out
  out=$("$bin" verify bench/fixtures/ir/bad/cc_named_param.ir 2>&1) && return 1
  echo "$out" | grep -q 'error\[cc-lowered\]'
}

# The unwinding inline asm in a nounwind function must be refused under asm-unwind. Non-zero when it is accepted or
# refused another way.
asm_unwind_check() {
  local bin="$1" out
  out=$("$bin" verify bench/fixtures/ir/bad/asm_unwind_nounwind.ir 2>&1) && return 1
  echo "$out" | grep -q 'error\[asm-unwind\]'
}

# The unwind fixture with its unwind edges dropped must be its expected text, byte for byte, and a pad that a normal
# edge reaches must be refused by name. Non-zero when either is not so.
unwind_check() {
  local bin="$1" out
  "$bin" drop-unwind bench/fixtures/ir/unwind/ensure.ir >"$WORK/unwind.out" 2>&1 || return 1
  cmp -s "$WORK/unwind.out" bench/fixtures/ir/unwind/ensure.expected || return 1
  out=$("$bin" drop-unwind bench/fixtures/ir/unwind/pad_reachable.ir 2>&1) && return 1
  [ "$out" = "refused: function f: block pad still holds a landingpad after its unwind edges were dropped" ]
}

# Applies one mutation, compiles it, runs its check, and restores the original bytes.
# A compiler failure cannot count as detecting the mutation.
prove_mutation() {
  local label="$1" file="$2" old="$3" new="$4" check="$5" backup count caught
  if [ "$old" = "$new" ]; then
    fail "PATCH CHANGED NOTHING: $label: this proves nothing"
    return
  fi
  if ! count=$("$PY" -c 'import pathlib, sys
sys.stdout.write(str(pathlib.Path(sys.argv[1]).read_bytes().count(sys.argv[2].encode("utf-8"))))' "$(native_path "$file")" "$old"); then
    fail "$label: could not count mutation occurrences"
    return
  fi
  if [ "$count" != "1" ]; then
    fail "PATCH CHANGED NOTHING: $label: the text occurs $count times, not once"
    return
  fi
  if ! "$check" "$DRV" >"$WORK/baseline-check.log" 2>&1; then
    fail "BASELINE FAILED: $label: the unmodified driver does not pass $check"
    cat "$WORK/baseline-check.log"
    return
  fi
  backup="$WORK/$(basename "$file").orig"
  # Copy contents without depending on filesystem extended attributes.
  cat "$file" > "$backup"
  cmp -s "$file" "$backup" || { fail "$label: the backup of $file is not the file; nothing was patched"; return; }
  RESTORE+=("$file|$backup")
  if ! "$PY" -c 'import pathlib, sys
path = pathlib.Path(sys.argv[1])
old, new = (arg.encode("utf-8") for arg in sys.argv[2:])
data = path.read_bytes()
if data.count(old) != 1:
    raise SystemExit("mutation source changed while patching")
path.write_bytes(data.replace(old, new, 1))' "$(native_path "$file")" "$old" "$new"; then
    cat "$backup" > "$file"
    cmp -s "$backup" "$file" || { echo "FAIL: $file WAS NOT RESTORED: what it held is in $backup"; trap - EXIT INT TERM; exit 2; }
    RESTORE=()
    fail "$label: could not write the mutation"
    return
  fi
  rm -f "$MUTANT"
  if ! build_driver "$MUTANT"; then
    caught=3
  elif "$check" "$MUTANT" >"$WORK/mutant-check.log" 2>&1; then
    caught=0
  else
    caught=1
  fi
  cat "$backup" > "$file"
  cmp -s "$backup" "$file" || { echo "FAIL: $file WAS NOT RESTORED: what it held is in $backup"; trap - EXIT INT TERM; exit 2; }
  RESTORE=()
  if [ "$caught" -eq 0 ]; then
    fail "NOT CAUGHT: $label: the check still passes"
  elif [ "$caught" -eq 3 ]; then
    fail "BUILD FAILED: $label: no behavioral detection was proved"
    cat "$WORK/build.log"
  else
    echo "caught: $label"
  fi
}

# ---- 1. the driver -----------------------------------------------------------------------------
echo "== 1. build the IR driver with the compiler hosted in Crystal"
if build_driver "$DRV"; then
  echo "built $DRV"
else
  grep -v 'ld: warning' "$WORK/build.log" | tail -n 20
  echo "== SOME NATIVE IR CHECKS FAILED"
  exit 1
fi

if [ "$HOST_OS" = windows ]; then
  oracle_bundle load "$IR_ORACLE_DIR" || exit 1
fi

# ---- 2. the linkage floor ----------------------------------------------------------------------
if [ "$HOST_OS" = darwin ]; then
  echo "== 2. linkage floor: $DRV on $HOST_ID links only libSystem"
  if libs=$(otool -L "$DRV" | tail -n +2 | awk '{print $1}'); then
    for lib in $libs; do
      [ "$lib" = "/usr/lib/libSystem.B.dylib" ] || fail "the driver links $lib"
    done
    [ -n "$libs" ] || fail "otool reported no libraries for $DRV"
    echo "links: $libs"
  else
    fail "otool could not inspect $DRV on $HOST_ID"
  fi
else
  host_limited "linkage floor for $DRV on $HOST_ID: otool is darwin-only"
fi

# ---- 3. valid fixtures -------------------------------------------------------------------------
echo "== 3. every valid fixture prints back byte for byte and verifies"
count=0
for f in bench/fixtures/ir/valid/*.ir; do
  count=$((count + 1))
  out=$("$DRV" roundtrip "$f" 2>&1) || { fail "$f: $out"; continue; }
  [ "$out" = "identical" ] || fail "$f does not round-trip: $out"
  "$DRV" verify "$f" >"$WORK/verify.out" 2>&1 || fail "$f does not verify: $(cat "$WORK/verify.out")"
done
[ "$count" -gt 0 ] || fail "no valid fixtures found"
echo "checked $count valid fixtures"

# ---- 4. builder-constructed modules ------------------------------------------------------------
echo "== 4. modules built with the Builder print identically after a parse"
for name in arith memory control calls runtime intrinsics; do
  "$DRV" emit "$name" >"$WORK/$name.ir" || { fail "emit $name"; continue; }
  out=$("$DRV" roundtrip "$(native_path "$WORK/$name.ir")" 2>&1) || { fail "$name: $out"; continue; }
  [ "$out" = "identical" ] || fail "built module $name does not round-trip: $out"
  "$DRV" verify "$(native_path "$WORK/$name.ir")" >"$WORK/verify.out" 2>&1 || fail "built module $name does not verify: $(cat "$WORK/verify.out")"
done

echo "== 4b. integer arithmetic folds at its IR width and retains poison-sensitive operations"
if ./bin/iyi run bench/selfhost_ir_fold_exercise.iyi >"$WORK/folds.out" 2>&1; then
  cat "$WORK/folds.out"
else
  cat "$WORK/folds.out"
  fail "integer constant folding"
fi

# ---- 5. malformed fixtures ---------------------------------------------------------------------
echo "== 5. each malformed fixture is refused under its named rule"
count=0
for f in bench/fixtures/ir/bad/*.ir; do
  count=$((count + 1))
  want=$(sed -n 's/^; expect: //p' "$f" | head -n 1)
  [ -n "$want" ] || { fail "$f names no expected rule"; continue; }
  out=$("$DRV" verify "$f" 2>&1) && { fail "$f was accepted"; continue; }
  echo "$out" | grep -q "error\[$want\]" || fail "$f was not refused as $want: $out"
done
[ "$count" -gt 0 ] || fail "no malformed fixtures found"
echo "refused $count malformed fixtures under their rules"

# ---- 5b. the parser's acceptances and refusals -------------------------------------------------
echo "== 5b. the ModuleID header is ignored and the module is named by source_filename; the rejected literals and intrinsics are refused"
out=$("$DRV" print bench/fixtures/ir/accept/moduleid.ir 2>&1) || fail "moduleid.ir: $out"
echo "$out" | grep -q '^source_filename = "moduleid.iyi"$' || fail "moduleid.ir does not keep source_filename as its module identifier: $out"
personality_check "$DRV" || fail "personality_typed.ir: LLVM's typed personality was not preserved"
decimal_check "$DRV" || fail "decimal_float.ir: a decimal floating-point constant is not read as its bit pattern: $("$DRV" print bench/fixtures/ir/accept/decimal_float.ir 2>&1)"
llvm_float_check "$DRV" || fail "llvm_float.ir: a float constant in LLVM's double form is not read as the float's bits: $("$DRV" print bench/fixtures/ir/accept/llvm_float.ir 2>&1)"
named_types_check "$DRV" || fail "named_types.ir: a named type nothing mentions is written, or a mentioned one is not: $("$DRV" print bench/fixtures/ir/accept/named_types.ir 2>&1 | grep ' = type ')"
named_type_order_check "$DRV" || fail "named_types.ir: named types are not written in TypeFinder discovery order: $("$DRV" print bench/fixtures/ir/accept/named_types.ir 2>&1 | grep ' = type ')"
count=0
for f in bench/fixtures/ir/reject/*.ir; do
  count=$((count + 1))
  want=$(sed -n 's/^; reject: //p' "$f" | head -n 1)
  [ -n "$want" ] || { fail "$f names no expected refusal"; continue; }
  out=$("$DRV" print "$f" 2>&1) && { fail "$f was accepted"; continue; }
  echo "$out" | grep -Fq -- "$want" || fail "$f was refused for another reason, not '$want': $out"
done
[ "$count" -gt 0 ] || fail "no rejected fixtures found"
echo "refused $count literal and intrinsic fixtures under their reasons"

# ---- 5c. every intrinsic the IR accepts, at every width its family accepts ----------------------
echo "== 5c. the accepted intrinsic names match the checked-in list"
"$DRV" intrinsics >"$WORK/intrinsic-names.txt" || fail "the driver lists no intrinsics"
if diff bench/fixtures/ir/intrinsic-names.txt "$WORK/intrinsic-names.txt" >"$WORK/diff.txt"; then
  echo "accepts $(wc -l <"$WORK/intrinsic-names.txt" | tr -d ' ') intrinsic names"
else
  fail "the accepted intrinsic names changed: $(cat "$WORK/diff.txt")"
fi

# ---- 5d. unwind edges --------------------------------------------------------------------------
echo "== 5d. a module with its unwind edges dropped is its normal path, a call where each invoke stood"
out=$("$DRV" roundtrip bench/fixtures/ir/unwind/ensure.ir 2>&1) || fail "unwind/ensure.ir does not round-trip: $out"
if unwind_check "$DRV"; then
  echo "unwind edges dropped: an invoke is the call it makes and the block opened after it is the rest of its own, the pads and what only they named are gone, a phi keeps its live pairs"
else
  fail "unwind/ensure.ir without its unwind edges is not unwind/ensure.expected, or a reachable pad was accepted: $("$DRV" drop-unwind bench/fixtures/ir/unwind/ensure.ir 2>&1 | diff - bench/fixtures/ir/unwind/ensure.expected | head -n 12)"
fi

# ---- 5e. dominance across a 20,000-block function -----------------------------------------------
echo "== 5e. a generated function of 20,000 blocks (6,666 chained diamonds) verifies"
chain_file="$WORK/chain20000.ir"
"$PY" - "$(native_path "$chain_file")" <<'PY' || fail "could not generate the 20,000-block chain of diamonds"
import pathlib
import sys

# Diamonds chained through their joins. Head h(k) branches to arms a(k) and b(k), both of which branch to h(k+1);
# that head's phi joins the arms, and its value uses the previous head's value, so the dominator tree is 6,666 deep.
D = 6666
lines = [
    "; iyi-ir 1",
    'source_filename = "chain20000"',
    'target triple = "x86_64-unknown-linux-gnu"',
    'target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"',
    "define internal iyicc i32 @f(i1 %c, i32 %p) {",
    "entry:",
    "  %v0 = add i32 %p, 1",
    "  br i1 %c, label %a0, label %b0",
]
for k in range(D):
    join = f"h{k + 1}" if k + 1 < D else f"h{D}"
    lines += [f"a{k}:", f"  %x{k} = add i32 %v{k}, 3", f"  br label %{join}"]
    lines += [f"b{k}:", f"  %y{k} = add i32 %v{k}, 4", f"  br label %{join}"]
    if k + 1 < D:
        lines += [
            f"h{k + 1}:",
            f"  %p{k + 1} = phi i32 [ %x{k}, label %a{k} ], [ %y{k}, label %b{k} ]",
            f"  %v{k + 1} = add i32 %p{k + 1}, %v{k}",
            f"  br i1 %c, label %a{k + 1}, label %b{k + 1}",
        ]
    else:
        lines += [
            f"h{D}:",
            f"  %p{D} = phi i32 [ %x{k}, label %a{k} ], [ %y{k}, label %b{k} ]",
            "  br label %end",
        ]
lines += ["end:", f"  ret i32 %p{D}", "}", ""]
blocks = sum(1 for line in lines if line.endswith(":") and not line.startswith((" ", ";")))
if blocks != 20000:
    sys.exit(f"the chain has {blocks} blocks, not 20000")
pathlib.Path(sys.argv[1]).write_text("\n".join(lines))
PY
if [ -s "$chain_file" ] && "$DRV" verify "$(native_path "$chain_file")" >"$WORK/chain.out" 2>&1 && [ "$(cat "$WORK/chain.out")" = verified ]; then
  echo "a function of 20,000 blocks verifies"
else
  fail "the 20,000-block chain of diamonds does not verify: $(cat "$WORK/chain.out" 2>/dev/null)"
fi

# ---- 6. DataLayout against the oracle ----------------------------------------------------------
echo "== 6. DataLayout#llvm_string equals the oracle's target datalayout on all five targets"
for pair in "${TARGETS[@]}"; do
  oracle_t=${pair%% *}
  our_t=${pair#* }
  reference=""
  if [ "$HOST_OS" = windows ] && [ "$oracle_t" = wasm32-wasi ]; then
    reference=" (Windows component execution; Linux LLVM reference)"
  else
    if ! ./bin/iyi build --cross-compile --target "$oracle_t" --emit llvm-ir -o "$(native_path "$WORK/hello-$oracle_t")" samples/iyi/hello.iyi >"$WORK/hello.log" 2>&1; then
      fail "the oracle cannot emit $oracle_t: $(tail -n 3 "$WORK/hello.log")"
      continue
    fi
    if ! extract_datalayout "$WORK/hello-$oracle_t.ll" "$WORK/layout-$oracle_t.txt"; then
      fail "the oracle reports no valid DataLayout for $oracle_t"
      continue
    fi
  fi
  if ! "$DRV" layout "$our_t" >"$WORK/layout-ours-$our_t.txt"; then
    fail "no DataLayout for $our_t"
    continue
  fi
  if cmp -s "$WORK/layout-$oracle_t.txt" "$WORK/layout-ours-$our_t.txt"; then
    echo "datalayout ok: $our_t$reference"
  else
    fail "DataLayout for $our_t: ours [$(cat "$WORK/layout-ours-$our_t.txt")] oracle [$(cat "$WORK/layout-$oracle_t.txt")]"
  fi
done

# ---- 7. struct layouts against the oracle ------------------------------------------------------
echo "== 7. offset_of and size_of agree with the oracle hosted in Crystal on all five targets"
for pair in "${TARGETS[@]}"; do
  oracle_t=${pair%% *}
  our_t=${pair#* }
  reference=""
  if [ "$HOST_OS" = windows ] && [ "$oracle_t" = wasm32-wasi ]; then
    reference=" (Windows component execution; Linux LLVM reference)"
  elif ! oracle_values "$oracle_t" "$WORK/oracle-$oracle_t.txt"; then
    fail "the oracle reports no probe values for $oracle_t"
    continue
  fi
  if [ "$(wc -l <"$WORK/oracle-$oracle_t.txt" | tr -d ' ')" -ne 19 ]; then
    fail "expected 19 probe values for $oracle_t, got $(wc -l <"$WORK/oracle-$oracle_t.txt")"
  fi
  make_shapes_ir "$our_t" || { fail "no DataLayout for $our_t"; continue; }
  ours_values "$DRV" "$our_t" "$WORK/ours-$our_t.txt" || { fail "no struct output for $our_t"; continue; }
  if diff "$WORK/oracle-$oracle_t.txt" "$WORK/ours-$our_t.txt" >"$WORK/diff.txt"; then
    echo "struct layouts ok: $our_t$reference"
  else
    fail "struct layout differs for $our_t: $(cat "$WORK/diff.txt")"
  fi
done

# ---- 7b. wide integers against LLVM's own DataLayout -------------------------------------------
echo "== 7b. struct layouts with i192, i65 and i33 agree with LLVM's DataLayout on all five targets"
if ! prepare_llvm_probe; then
  fail "the LLVM layout probe could not be prepared"
elif ! CRYSTAL_PATH="$(native_path "$REPO/src")" ./bin/crystal build -o "$(native_path "$LLVM_DRV")" "$(native_path "$WORK/llvm_layout.cr")" >"$WORK/llvm_layout.log" 2>&1; then
  fail "the LLVM layout probe does not build: $(tail -n 3 "$WORK/llvm_layout.log")"
else
  if "$LLVM_DRV" --identity >"$WORK/llvm-identity.txt" && normalize_oracle "$WORK/llvm-identity.txt"; then
    echo "LLVM layout probe identity (runtime version, compiled version, built targets):"
    cat "$WORK/llvm-identity.txt"
  else
    fail "the LLVM layout probe cannot report its identity"
  fi
  if ! ./bin/iyi --version >"$WORK/iyi-version.txt" 2>"$WORK/version.log" || ! normalize_oracle "$WORK/iyi-version.txt"; then
    fail "the iyi oracle cannot report its version"
  fi
  if ! ./bin/crystal --version >"$WORK/crystal-version.txt" 2>"$WORK/version.log" || ! normalize_oracle "$WORK/crystal-version.txt"; then
    fail "the Crystal oracle cannot report its version"
  fi
  for pair in "${TARGETS[@]}"; do
    oracle_t=${pair%% *}
    our_t=${pair#* }
    if [ "$HOST_OS" = windows ] && [ "$oracle_t" = wasm32-wasi ]; then
      echo "wide reference for $our_t: Windows component execution; Linux LLVM reference"
    elif ! "$LLVM_DRV" "$our_t" >"$WORK/wide-oracle-$oracle_t.txt" || ! normalize_oracle "$WORK/wide-oracle-$oracle_t.txt"; then
      fail "the LLVM layout probe fails for $our_t"
    fi
  done
  if wide_check "$DRV"; then
    echo "wide struct layouts ok on all five targets"
  else
    fail "a wide struct layout differs from LLVM's DataLayout"
  fi
fi

# ---- 8. mutation proofs ------------------------------------------------------------------------
echo "== 8. mutations are each caught"
prove_mutation "layout: offset_of drops its alignment rounding" \
  src/compiler/ir/layout.iyi \
  'off = ((off + a - 1) // a) * a' \
  'off = off + 0' \
  struct_check
prove_mutation "layout: an integer wider than 64 bits is 8-byte aligned, not 16" \
  src/compiler/ir/layout.iyi \
  $'    return 8 if bits <= 64\n    16' \
  $'    return 8 if bits <= 64\n    8' \
  wide_check
prove_mutation "printer: the Add and Sub mnemonics swap" \
  src/compiler/ir/printer.iyi \
  '    when Op::Add  then "add"' \
  '    when Op::Add  then "sub"' \
  roundtrip_check
prove_mutation "printer: hidden visibility is written as nothing" \
  src/compiler/ir/printer.iyi \
  '      "hidden"' \
  '      ""' \
  roundtrip_check
prove_mutation "printer: an intrinsic operand drops its align attribute" \
  src/compiler/ir/printer.iyi \
  'attrs = k < aux.param_attrs.size ? attrs_inline(aux.param_attrs[k]) : ""' \
  'attrs = k < aux.param_attrs.size ? attrs_inline(aux.param_attrs[k].select { |a| a.name != "align" }) : ""' \
  roundtrip_check
prove_mutation "printer: a wide integer constant is written as its low word alone" \
  src/compiler/ir/printer.iyi \
  'return int_words_text(i.int_words(i.type.bits), i.type.bits) if i.type.bits > 64' \
  'return i.aux_int.to_s if i.type.bits > 64' \
  roundtrip_check
prove_mutation "printer: every named type in the table is written, mentioned or not" \
  src/compiler/ir/printer.iyi \
  '      named_types_in_order.each do |t|' \
  '      @module.types.named.each do |t|' \
  named_types_check
prove_mutation "printer: a type an attribute names is not followed" \
  src/compiler/ir/printer.iyi \
  $'      if t = a.type_value\n        incorporate_type(t, found, visited, worklist)' \
  $'      if t = a.type_value\n        nil' \
  named_types_check
prove_mutation "printer: mentioned named types are written in table creation order instead of discovery order" \
  src/compiler/ir/printer.iyi \
  $'    found\n  end' \
  $'    @module.types.named.select { |t| visited.includes?(t.key) }\n  end' \
  named_type_order_check
prove_mutation "verifier: ptrtoint accepts an aggregate operand" \
  src/compiler/ir/verifier.iyi \
  'unless operand_type(i.args[0]).pointer? && i.type.int?' \
  'unless true' \
  ptrtoint_check
prove_mutation "verifier: a trunc to the width it has is accepted" \
  src/compiler/ir/verifier.iyi \
  'i.type.bits < operand_type(i.args[0]).bits' \
  'i.type.bits <= operand_type(i.args[0]).bits' \
  trunc_same_width_check
prove_mutation "verifier: a call no longer kills thread-local values" \
  src/compiler/ir/verifier.iyi \
  '    if i.op == Op::Call || i.op == Op::Invoke' \
  '    if i.op == Op::Call && i.op == Op::Invoke' \
  tls_check
prove_mutation "verifier: a named struct passes the C-convention rule" \
  src/compiler/ir/verifier.iyi \
  'return false if t.packed_struct? || !t.struct_name.nil?' \
  'return false if t.packed_struct?' \
  cc_named_check
prove_mutation "verifier: an unwinding asm is accepted in a nounwind function" \
  src/compiler/ir/verifier.iyi \
  'if inline_asm.unwind && f.attrs.any? { |a| a.name == "nounwind" }' \
  'if inline_asm.unwind && f.attrs.any? { |a| a.name == "nounwind_never" }' \
  asm_unwind_check

# The dominance rule: each check states the driver's answer on one fixture, so a mutant that gets it wrong is caught.
dominance_check() {
  local bin="$1" out
  out=$("$bin" verify bench/fixtures/ir/bad/dominance_diamond.ir 2>&1) && return 1
  echo "$out" | grep -q 'error\[dominance\]'
}
unreachable_check() {
  "$1" verify bench/fixtures/ir/valid/unreachable_use.ir >/dev/null 2>&1
}
phi_dominance_check() {
  local bin="$1" out
  out=$("$bin" verify bench/fixtures/ir/bad/phi_not_dominated.ir 2>&1) && return 1
  echo "$out" | grep -q 'error\[dominance\]'
}
prove_mutation "verifier: every block dominates every other, so a use that no definition dominates is accepted" \
  src/compiler/ir/verifier.iyi \
  '    @pre[a] <= @pre[b] && @post[b] <= @post[a]' \
  '    true' \
  dominance_check
prove_mutation "verifier: an unreachable block is dominated by nothing, so a phi incoming from one is refused" \
  src/compiler/ir/verifier.iyi \
  '    return true unless reachable?(b)' \
  '    return false unless reachable?(b)' \
  unreachable_check
prove_mutation "verifier: a phi incoming is not checked against the dominance of its value" \
  src/compiler/ir/verifier.iyi \
  '      if db != source && !dom.dominates?(db, source)' \
  '      if db != source && false' \
  phi_dominance_check
prove_mutation "printer: the unwind word of inline asm is not written" \
  src/compiler/ir/printer.iyi \
  '    text += " unwind" if inline_asm.unwind' \
  '    text += " unwind_" if inline_asm.unwind' \
  roundtrip_check
prove_mutation "parser: a typed personality is not consumed" \
  src/compiler/ir/parser.iyi \
  '        if c.ident?("ptr")
          parse_type(c, mod.types)
        end' \
  '        if false && c.ident?("ptr")
          parse_type(c, mod.types)
        end' \
  personality_check
prove_mutation "parser: a decimal constant of type float keeps the double's bit pattern" \
  src/compiler/ir/parser.iyi \
  'type.float32? ? single_bits(value) : double_bits(value)' \
  'type.float32? ? double_bits(value) : double_bits(value)' \
  decimal_check
prove_mutation "parser: a float constant in LLVM's double form keeps the double's low bits" \
  src/compiler/ir/parser.iyi \
  'if type.float32? && t.text.bytesize > 8' \
  'if type.float32? && t.text.bytesize > 16' \
  llvm_float_check
prove_mutation "values: the float read from a double loses its sign" \
  src/compiler/ir/values.iyi \
  'return (sign << 31) | ((power + 127_i64) << 23) | top' \
  'return ((power + 127_i64) << 23) | top' \
  llvm_float_check
prove_mutation "unwind: an invoke is left an invoke" \
  src/compiler/ir/inst.iyi \
  '    @op = Op::Call' \
  '    @op = Op::Invoke' \
  unwind_check
prove_mutation "unwind: the call continues into the unwind successor" \
  src/compiler/ir/function.iyi \
  '        normal = t.targets[0]' \
  '        normal = t.targets[1]' \
  unwind_check
prove_mutation "unwind: the block opened after an invoke stays a block" \
  src/compiler/ir/function.iyi \
  'normal.preds.size == 1 && normal.terminated?' \
  'normal.preds.size == 0 && normal.terminated?' \
  unwind_check
prove_mutation "unwind: a successor another block reaches is merged" \
  src/compiler/ir/function.iyi \
  'normal.preds.size == 1 && normal.terminated?' \
  'normal.preds.size >= 1 && normal.terminated?' \
  unwind_check
prove_mutation "unwind: a successor that starts with a phi is merged" \
  src/compiler/ir/function.iyi \
  'normal.insts[0].op != Op::Phi' \
  'normal.insts[0].op != Op::LandingPad' \
  unwind_check
prove_mutation "unwind: a phi still names the merged block" \
  src/compiler/ir/function.iyi \
  'inst.move_incoming(normal, b) if inst.op == Op::Phi' \
  'inst.move_incoming(normal, normal) if inst.op == Op::Phi' \
  unwind_check
prove_mutation "unwind: a block only an unwind edge reached is kept" \
  src/compiler/ir/function.iyi \
  '      kept << @blocks[k] if seen[k]' \
  '      kept << @blocks[k]' \
  unwind_check
prove_mutation "unwind: a phi keeps the pair of a removed block" \
  src/compiler/ir/function.iyi \
  'inst.keep_incoming(block.preds) if inst.op == Op::Phi' \
  'inst.keep_incoming(block.preds) if inst.op == Op::Phi && false' \
  unwind_check
prove_mutation "unwind: the personality stays on the function" \
  src/compiler/ir/function.iyi \
  $'    relink\n    @personality = nil' \
  $'    relink\n    relink' \
  unwind_check
prove_mutation "unwind: a declaration only the unwind path named stays" \
  src/compiler/ir/module.iyi \
  'next if f.declaration? && before.has_key?(f) && !after.has_key?(f)' \
  'next if f.declaration? && before.has_key?(f) && after.has_key?(f)' \
  unwind_check
prove_mutation "unwind: an unwinding instruction that is still reachable is accepted" \
  src/compiler/ir/function.iyi \
  'if word = unwind_only_op(inst.op)' \
  'if word = unwind_only_op(Op::Br)' \
  unwind_check

if [ "$failed" -eq 0 ] && [ -n "${IR_ORACLE_EXPORT_DIR:-}" ]; then
  if ! git diff --quiet HEAD -- src bench/fixtures/ir samples/iyi/hello.iyi bench/native_ir_exercise.sh; then
    fail "oracle inputs changed after the baseline at git HEAD $HEAD_SHA"
  elif ! oracle_bundle export "$IR_ORACLE_EXPORT_DIR"; then
    fail "could not export the Linux LLVM reference bundle"
  fi
fi

echo
if [ "$failed" -eq 0 ]; then
  echo "== ALL NATIVE IR CHECKS PASSED"
  exit 0
fi
echo "== SOME NATIVE IR CHECKS FAILED"
exit 1
