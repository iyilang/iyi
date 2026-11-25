#!/usr/bin/env bash
# The x86_64 encoder and ABI gate. Sections, each checked here:
#
#   1. encoder: the forms listed by compiler/tools/native_amd64 are encoded by
#      compiler/native/amd64/encode and compared with LLVM's assembler for the
#      same text: bytes exactly, and each relocation's kind, offset and addend.
#      The oracle is llvm-mc on macOS and Linux, and clang's integrated assembler
#      on Windows. llvm-objdump reads its object back at test time only.
#   2. ABI: the System V and Win64 register tables, the eightbyte classifier, the register-availability rule and
#      the Win64 slots, against expected rows written from the psABI and the Microsoft x64 convention.
#   6. mutations: each patch to the encoder or the ABI must make the check that covers it fail. A patch whose
#      text is absent, or that leaves the text unchanged, changes nothing and is refused.
#
# Instruction selection and executable linking are separate components. This gate
# checks encodings, relocations and ABI tables; it does not execute x86_64 output.
#
# Runs on macOS, Linux and Windows: encoding and ABI tables are host-independent.
# Exit 0 with "== ALL X86_64 CHECKS PASSED", or 1 with "== SOME X86_64 CHECKS FAILED".

set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd -P)
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"
source "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  echo "a working python3 or python is required" >&2
  exit 1
fi

# Honor explicit tool paths, then PATH, then the standard Windows LLVM install.
resolve_llvm_tool() {
  local requested=$1 default_name=$2 found="" candidate root
  if [ "$HOST_OS" = windows ]; then
    case "$requested" in
      [A-Za-z]:[\\/]*) requested=$(cygpath -u "$requested") || return 1 ;;
    esac
  fi
  found=$(command -v "$requested" 2>/dev/null || true)
  if [ -z "$found" ] && [ "$HOST_OS" = windows ] && [ "$requested" = "$default_name" ]; then
    for root in "${LLVM_PATH:-}" "${ProgramFiles:+$ProgramFiles/LLVM}" "/c/Program Files/LLVM"; do
      [ -n "$root" ] || continue
      case "$root" in
        [A-Za-z]:[\\/]*) root=$(cygpath -u "$root") || continue ;;
      esac
      candidate="$root/bin/$default_name.exe"
      if [ -x "$candidate" ]; then
        found=$candidate
        break
      fi
    done
  fi
  if [ -z "$found" ]; then
    echo "required LLVM tool not found: $requested" >&2
    return 1
  fi
  if [ "$HOST_OS" = windows ] && [ -f "$found.exe" ]; then
    found="$found.exe"
  fi
  case "$found" in
    /*) ;;
    *) found="$(cd "$(dirname "$found")" && pwd -P)/$(basename "$found")" ;;
  esac
  printf '%s\n' "$found"
}

LLVM_OBJDUMP=$(resolve_llvm_tool "${LLVM_OBJDUMP:-llvm-objdump}" llvm-objdump) || exit 1
if [ "$HOST_OS" = windows ]; then
  LLVM_CLANG=$(resolve_llvm_tool "${LLVM_CLANG:-clang}" clang) || exit 1
  printf 'LLVM assembler frontend: clang integrated assembler (%s)\n' "$(native_path "$LLVM_CLANG")"
  "$LLVM_CLANG" --version || exit 1
else
  LLVM_MC=$(resolve_llvm_tool "${LLVM_MC:-llvm-mc}" llvm-mc) || exit 1
  printf 'LLVM assembler frontend: llvm-mc (%s)\n' "$(native_path "$LLVM_MC")"
  "$LLVM_MC" --version || exit 1
fi
printf 'LLVM objdump: %s\n' "$(native_path "$LLVM_OBJDUMP")"
"$LLVM_OBJDUMP" --version || exit 1
printf 'Python: %s\n' "$(command -v "$PY")"
"$PY" --version || exit 1

work=$(mktemp -d "${TMPDIR:-/tmp}/native-x86_64.XXXXXX") || exit 1
restore=""
backup=""
cleanup() {
  if [ -n "$restore" ] && [ -f "$backup" ]; then
    if ! cp "$backup" "$restore"; then
      echo "could not restore $restore; backup kept at $backup" >&2
      return 1
    fi
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failed=0
fail() {
  echo "FAIL: $*"
  failed=1
}

# The encoder check (section 1). prepare writes forms.s from the table; compare reads the oracle's listing back.
cat >"$work/check_forms.py" <<'PY'
import re
import sys

work = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else "compare"
# Our relocation kinds, and the ELF relocation LLVM emits for the same operand. A movq from the GOT is the
# relaxable GOTPCRELX form, the one the object model's X86GotPcRel stands for.
ELF_NAME = {
    "PcRel32": "R_X86_64_PC32",
    "X86Branch32": "R_X86_64_PLT32",
    "X86GotPcRel": "R_X86_64_REX_GOTPCRELX",
    "X86TpOff32": "R_X86_64_TPOFF32",
    "Abs64": "R_X86_64_64",
}

rows = []
for line in open(f"{work}/forms.tsv", encoding="utf-8", newline=""):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 2:
        continue
    text, hexbytes = parts[0], parts[1]
    relocs = []
    if len(parts) > 2 and parts[2]:
        for item in parts[2].split(","):
            off, kind, addend = item.split(":")
            relocs.append((int(off), ELF_NAME[kind], int(addend)))
    rows.append((text, hexbytes, relocs))

with open(f"{work}/forms.s", "w", encoding="utf-8", newline="\n") as f:
    f.write("\t.text\n")
    for text, _, _ in rows:
        f.write(text + "\n")

if len(rows) != 113 or sum(len(relocs) for _, _, relocs in rows) != 11:
    print(f"expected 113 forms with 11 relocations, got {len(rows)} forms with "
          f"{sum(len(relocs) for _, _, relocs in rows)} relocations")
    sys.exit(1)

if mode == "prepare":
    sys.exit(0)

instr = []   # (offset, hex bytes)
relocs = []  # (offset, elf name, addend, symbol expression)
pending = None
ins_re = re.compile(r"^\s+([0-9a-f]+):\s+((?:[0-9a-f]{2} )*[0-9a-f]{2})\s*\t")
rel_re = re.compile(r"^\s*([0-9a-f]+):\s+(R_X86_64_\w+)\s+(\S+)\s*$")
for line in open(f"{work}/dis.txt", encoding="utf-8"):
    m = ins_re.match(line)
    if m:
        off = int(m.group(1), 16)
        bts = m.group(2).replace(" ", "")
        if pending is not None:
            # objdump prints a lock prefix as its own instruction: it belongs to the one after it.
            off, bts = pending[0], pending[1] + bts
            pending = None
        if line[m.end():].split() == ["lock"]:
            pending = (off, bts)
            continue
        instr.append((off, bts))
        continue
    m = rel_re.match(line)
    if m:
        expr = m.group(3)
        em = re.fullmatch(r"sym([+-]0x[0-9a-f]+)?", expr)
        if not em:
            print(f"unexpected relocation expression: {expr}")
            sys.exit(1)
        addend = int(em.group(1), 16) if em.group(1) else 0
        relocs.append((int(m.group(1), 16), m.group(2), addend, expr))

if len(instr) != len(rows):
    print(f"the oracle assembled {len(instr)} instructions for {len(rows)} forms: the forms are not one instruction each")
    sys.exit(1)

bad = 0
bytes_ok = 0
relocs_ok = 0
reloc_count = 0
for k, (text, hexbytes, ours) in enumerate(rows):
    start = instr[k][0]
    end = instr[k + 1][0] if k + 1 < len(instr) else None
    oracle_bytes = instr[k][1]
    if hexbytes == oracle_bytes:
        bytes_ok += 1
    else:
        bad += 1
        print(f"MISMATCH bytes {text}: encoder {hexbytes} oracle {oracle_bytes}")
        continue
    mine_rel = [r for r in relocs if r[0] >= start and (end is None or r[0] < end)]
    theirs = sorted((off - start, name, addend) for off, name, addend, _ in mine_rel)
    mine = sorted(ours)
    reloc_count += len(mine)
    if mine == theirs:
        relocs_ok += 1
    else:
        bad += 1
        print(f"MISMATCH relocations {text}: encoder {mine} oracle {theirs}")

print(f"compared {len(rows)} forms against the LLVM assembler: {bytes_ok} byte-identical, "
      f"{relocs_ok} with identical relocations ({reloc_count} relocations)")
sys.exit(10 if bad else 0)
PY

# The ABI expectations (section 2): written from the psABI and the Microsoft x64 convention, not from the tables.
cat >"$work/abi_expected.py" <<'PY'
import sys

rows = [
    # psABI 3.2.3: the class of each eightbyte of an aggregate of 16 bytes or fewer, and its return registers
    ("class", "i64_i64", "INTEGER,INTEGER"),
    ("ret", "i64_i64", "0,2"),           # rax, rdx
    ("class", "f64_f64", "SSE,SSE"),
    ("ret", "f64_f64", "32,33"),         # xmm0, xmm1
    ("class", "i64_f64", "INTEGER,SSE"),
    ("ret", "i64_f64", "0,32"),          # rax, xmm0
    ("class", "f64_i64", "SSE,INTEGER"),
    ("ret", "f64_i64", "32,0"),          # xmm0, rax
    ("class", "f32_f32", "SSE"),         # two floats share one eightbyte
    ("ret", "f32_f32", "32"),
    ("class", "i32x3", "INTEGER,INTEGER"),
    ("ret", "i32x3", "0,2"),
    ("class", "i64x3", "MEMORY"),        # over 16 bytes: on the stack, and returned through sret
    ("ret", "i64x3", ""),
    ("class", "f32_i32", "INTEGER"),     # an integer leaf makes the eightbyte INTEGER
    ("ret", "f32_i32", "0"),
    ("class", "i8_f64", "INTEGER,SSE"),
    ("ret", "i8_f64", "0,32"),
    # psABI 3.2.3: an aggregate is passed in registers only when every eightbyte of it fits the free registers
    ("fits", "i64_i64", "6", "8", "yes"),
    ("fits", "i64_i64", "1", "8", "no"),
    ("fits", "f64_f64", "6", "1", "no"),
    ("fits", "f64_f64", "6", "2", "yes"),
    ("fits", "i64x3", "6", "8", "no"),
    ("fits", "i64_f64", "6", "0", "no"),
    # the register lists, in argument order: psABI 3.2.3 (System V) and the Microsoft x64 argument passing rules
    ("table", "sysv_integer", "7,6,2,1,8,9"),          # rdi rsi rdx rcx r8 r9
    ("table", "sysv_sse", "32,33,34,35,36,37,38,39"),  # xmm0..xmm7
    ("table", "win64_integer", "1,2,8,9"),             # rcx rdx r8 r9
    ("table", "win64_sse", "32,33,34,35"),             # xmm0..xmm3
    ("table", "sysv_callee_saved", "3,5,12,13,14,15"), # rbx rbp r12..r15
    ("table", "win64_callee_saved", "3,5,7,6,12,13,14,15,38,39,40,41,42,43,44,45,46,47"),
    # the Win64 by-value rule: 1, 2, 4 or 8 bytes by value, any other size by reference
    ("win64_value", "1", "yes"),
    ("win64_value", "2", "yes"),
    ("win64_value", "3", "no"),
    ("win64_value", "4", "yes"),
    ("win64_value", "8", "yes"),
    ("win64_value", "12", "no"),
    ("win64_value", "16", "no"),
    # the positional slots: argument i is rcx, rdx, r8, r9 or xmm0..xmm3 by its class
    ("win64_slot", "0", "1", "32"),
    ("win64_slot", "1", "2", "33"),
    ("win64_slot", "2", "8", "34"),
    ("win64_slot", "3", "9", "35"),
    ("target", "x86_64-linux-gnu", "indirect=7", "frame=5", "stack_align=16", "pointer_bits=64"),
    ("target", "x86_64-windows-msvc", "indirect=1", "frame=5", "stack_align=16", "pointer_bits=64"),
]
sys.stdout.buffer.write("".join("\t".join(row) + "\n" for row in rows).encode("utf-8"))
PY

build_table_tool() {
  ./bin/iyi build -o "$(native_path "$1")" "$(native_path "$REPO/src/compiler/tools/native_amd64.iyi")"
}

echo "== 0. build the x86_64 table tool"
if ! build_table_tool "$work/native_amd64$EXE" >"$work/build.log" 2>&1; then
  cat "$work/build.log"
  fail "the table tool does not build"
  echo "== SOME X86_64 CHECKS FAILED"
  exit 1
fi

# Return 0 for a match, 1 for a completed comparison that found a mismatch,
# and 2 when the driver, oracle, parser or comparison could not run.
check_encoder() {
  local result
  : >"$work/check.log"
  : >"$work/forms.err"
  : >"$work/mc.log"
  : >"$work/dis.err"
  "$work/native_amd64$EXE" forms >"$work/forms.tsv" 2>"$work/forms.err" || return 2
  "$PY" "$(native_path "$work/check_forms.py")" "$(native_path "$work")" prepare >"$work/check.log" 2>&1 || return 2
  if [ "$HOST_OS" = windows ]; then
    "$LLVM_CLANG" --target=x86_64-unknown-linux-gnu -integrated-as -x assembler -c \
      "$(native_path "$work/forms.s")" -o "$(native_path "$work/oracle.o")" >"$work/mc.log" 2>&1 || return 2
  else
    "$LLVM_MC" -triple=x86_64-linux-gnu -filetype=obj -o "$(native_path "$work/oracle.o")" \
      "$(native_path "$work/forms.s")" >"$work/mc.log" 2>&1 || return 2
  fi
  "$LLVM_OBJDUMP" -dr "$(native_path "$work/oracle.o")" >"$work/dis.txt" 2>"$work/dis.err" || return 2
  "$PY" "$(native_path "$work/check_forms.py")" "$(native_path "$work")" >"$work/check.log" 2>&1
  result=$?
  case "$result" in
    0) return 0 ;;
    10) return 1 ;;
    *) return 2 ;;
  esac
}

check_abi() {
  local result
  : >"$work/abi.diff"
  : >"$work/abi.err"
  : >"$work/abi.expected.err"
  "$work/native_amd64$EXE" abi >"$work/abi.tsv" 2>"$work/abi.err" || return 2
  "$PY" "$(native_path "$work/abi_expected.py")" >"$work/abi.expected" 2>"$work/abi.expected.err" || return 2
  # The rows are keyed facts, not a sequence: both sides are compared sorted, so a row in another place is not a difference.
  sort "$work/abi.expected" >"$work/abi.expected.sorted" || return 2
  sort "$work/abi.tsv" >"$work/abi.tsv.sorted" || return 2
  diff -u "$work/abi.expected.sorted" "$work/abi.tsv.sorted" >"$work/abi.diff"
  result=$?
  case "$result" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

show_check_failure() {
  if [ "$1" = check_encoder ]; then
    cat "$work/check.log" "$work/forms.err" "$work/mc.log" "$work/dis.err"
  else
    cat "$work/abi.diff" "$work/abi.err" "$work/abi.expected.err"
  fi
}

echo "== 1. encoder: every form against the LLVM assembler"
if check_encoder; then
  cat "$work/check.log"
else
  result=$?
  show_check_failure check_encoder
  if [ "$result" -eq 1 ]; then
    fail "the encoder differs from the LLVM assembler"
  else
    fail "the encoder or LLVM oracle could not complete the comparison"
  fi
fi

echo "== 2. ABI: the register tables, the eightbyte classes and the Win64 slots against the psABI"
if check_abi; then
  echo "   $(wc -l <"$work/abi.expected" | tr -d ' ') rows match the psABI's stated classes, registers and rules"
else
  result=$?
  show_check_failure check_abi
  if [ "$result" -eq 1 ]; then
    fail "the ABI tables or classes differ from the psABI"
  else
    fail "the ABI comparison could not complete"
  fi
fi

if [ "$failed" -ne 0 ]; then
  echo "mutations require passing encoder and ABI baselines"
  echo "== SOME X86_64 CHECKS FAILED"
  exit 1
fi

# prove_mutation LABEL FILE OLD NEW CHECK: replaces the first OLD in FILE with NEW, rebuilds the table tool from
# the patched source, runs CHECK, and requires it to fail. A patch whose OLD is absent, or whose NEW leaves the
# text unchanged, changes nothing and is refused. The backup is taken before the patch, in the gate's work directory
# (never beside the source, where an interrupted run left `.bak` files in the tree), and the file is restored on every
# exit path.
restore_source() {
  if ! cp "$backup" "$restore"; then
    fail "could not restore $restore; backup kept at $backup"
    exit 1
  fi
  restore=""
}

prove_mutation() {
  local label=$1 file=$2 old=$3 new=$4 check=$5 patched result
  backup="$work/mutation-$RANDOM.bak"
  if ! cp "$file" "$backup"; then
    fail "could not back up $file for '$label'"
    return 1
  fi
  restore="$file"
  "$PY" - "$(native_path "$REPO/$file")" "$old" "$new" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
old, new = (s.encode("utf-8") for s in sys.argv[2:4])
data = path.read_bytes()
if old not in data or old == new:
    sys.exit(3)
path.write_bytes(data.replace(old, new, 1))
PY
  patched=$?
  if [ "$patched" -ne 0 ]; then
    restore_source
    if [ "$patched" -eq 3 ]; then
      fail "PATCH CHANGED NOTHING: '$label' found no text to change"
    else
      fail "could not apply '$label'"
    fi
    return 1
  fi
  if build_table_tool "$work/mutant_amd64$EXE" >"$work/mutant.log" 2>&1; then
    if ! cp "$work/mutant_amd64$EXE" "$work/native_amd64$EXE"; then
      fail "could not install the compiled mutant: $label"
    elif "$check"; then
      fail "NOT caught: $label"
    else
      result=$?
      if [ "$result" -eq 1 ]; then
        echo "   caught: $label"
      else
        show_check_failure "$check"
        fail "the mutant comparison could not complete: $label"
      fi
    fi
  else
    cat "$work/mutant.log"
    fail "the mutant does not build, so it proves nothing: $label"
  fi
  restore_source
  if ! build_table_tool "$work/native_amd64$EXE" >"$work/build.log" 2>&1; then
    cat "$work/build.log"
    fail "the original tool does not rebuild after '$label'"
    exit 1
  fi
  return 0
}

echo "== 6. mutations are each caught"
prove_mutation "cvtt: cvttsd2si given the cvtsd2si opcode (2D, not 2C)" src/compiler/native/amd64/encode.iyi \
  "sse(double ? 0xF2 : 0xF3, 0x2C, size == 64, reg, rm)" \
  "sse(double ? 0xF2 : 0xF3, 0x2D, size == 64, reg, rm)" check_encoder
prove_mutation "rex.b: the base register's extension bit is dropped from memory operands" src/compiler/native/amd64/encode.iyi \
  "rex_b = !m.rip && m.base >= 0 && hw(m.base) >= 8" \
  "rex_b = false" check_encoder
prove_mutation "rip-relative addend: the four-byte pc correction is dropped" src/compiler/native/amd64/encode.iyi \
  "w.reloc(kind, sym, value - 4_i64 - after)" \
  "w.reloc(kind, sym, value - after)" check_encoder
prove_mutation "abi: an integer leaf no longer dominates an SSE leaf in its eightbyte" src/compiler/native/amd64/abi.iyi \
  "(classes[idx] == class_sse && wanted == class_integer)" \
  "(classes[idx] == class_sse && wanted == class_sse)" check_abi
prove_mutation "win64: a floating-point argument takes the integer slot" src/compiler/native/amd64/abi.iyi \
  "  if is_float
    return win64_sse_args[index]" \
  "  if is_float
    return win64_integer_args[index]" check_abi

if [ "$failed" -eq 0 ]; then
  echo "== ALL X86_64 CHECKS PASSED"
  exit 0
fi
echo "== SOME X86_64 CHECKS FAILED"
exit 1
