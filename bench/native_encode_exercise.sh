#!/usr/bin/env bash
# The aarch64 encoder gate (SPEC 2.2 step 6, SPEC 3.8). Every MIR form the selector can produce is encoded by
# src/compiler/native/aarch64/encode.iyi and compared with the bytes and relocation kinds the Crystal-hosted
# compiler's LLVM assembler gives the same instruction text, read back through C1's Mach-O reader.
#
#   bench/native_encode_exercise.sh
#
# The oracle is one naked function holding every form in table order, bracketed by a marker that no
# compiled code emits (brk #0x7e7e). The hosted compiler gives naked functions no symbol names this slice can
# rely on, so the gate finds the marker in the text section and walks the forms from there: each form's
# bytes must appear at the cursor, and its relocations must match by offset and kind. The `ret` form is
# checked against the return word directly, since a naked body cannot end before its last form.
#
# Built with `./bin/iyi build --cross-compile --target aarch64-apple-darwin`. Encoding is architecture-only, so
# the same bytes are expected on any host; the native-linux job runs this gate.
set -u
cd "$(dirname "$0")/.." || exit 1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-encode.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

failed=0
fail() { echo "FAIL: $*"; failed=1; }

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"
export LIBRARY_PATH=${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}

echo "== 1. build the driver with the hosted compiler"
if ! ./bin/iyi build -o "$WORK/native_cg" src/compiler/tools/native_cg.iyi >"$WORK/build.log" 2>&1; then
  grep -v 'ld: warning' "$WORK/build.log" | tail -20
  fail "the driver does not build"
  exit 1
fi

echo "== 2. the encoder's table of forms"
"$WORK/native_cg" forms >"$WORK/forms.tsv" || fail "native_cg forms failed"
echo "forms: $(wc -l <"$WORK/forms.tsv" | tr -d ' ')"

echo "== 3. the oracle: every form in one naked function, built by the hosted compiler"
python3 - "$WORK" <<'PY'
import sys
work = sys.argv[1]
with open(f"{work}/forms.tsv") as f:
    rows = [line.rstrip("\n").split("\t") for line in f if line.strip()]
body = ["brk #0x7e7e"]
for row in rows:
    if row[0] == "ret":
        continue
    body += [part.strip() for part in row[0].split(" ; ")]
body.append("ret")
lines = ['@[Unsafe("the oracle: one naked function holds every encoded form, for the encoder gate")]',
         "module encode_oracle", "", "@[Naked]", "def oracle_forms : Nil",
         "  asm(\"" + "\n       ".join(body) + "\" :::: \"volatile\")", "end", "",
         "oracle_forms"]
open(f"{work}/oracle.iyi", "w").write("\n".join(lines) + "\n")
PY
if ! ./bin/iyi build --cross-compile --target aarch64-apple-darwin -o "$WORK/oracle.o" "$WORK/oracle.iyi" >"$WORK/oracle.log" 2>&1; then
  grep -v 'ld: warning' "$WORK/oracle.log" | tail -20
  fail "the oracle does not build"
  exit 1
fi

echo "== 4. read the oracle's bytes and relocations back, then compare"
"$WORK/native_cg" bytes "$WORK/oracle.o" >"$WORK/oracle.tsv" || fail "native_cg bytes failed"
python3 - "$WORK" <<'PY' || failed=1
import sys
work = sys.argv[1]
MARKER = "c0cf2fd4"   # brk #0x7e7e
RET = "c0035fd6"      # 0xd65f03c0, the return word

text = None
relocs = []
with open(f"{work}/oracle.tsv") as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if parts[0] == "section" and text is None and MARKER in parts[2]:
            text = parts[2]
            section = int(parts[1])
        elif parts[0] == "reloc" and text is not None:
            relocs.append((int(parts[1]), int(parts[2]), parts[3]))
if text is None:
    print("the oracle's marker is not in the text section")
    sys.exit(1)
relocs = [(off, kind) for (sec, off, kind) in relocs if sec == section]

pos = text.find(MARKER)
if text.find(MARKER, pos + 8) != -1:
    print("the marker occurs more than once; the gate cannot place the forms")
    sys.exit(1)
cursor = pos + len(MARKER)          # hex digits
with open(f"{work}/forms.tsv") as f:
    rows = [line.rstrip("\n").split("\t") for line in f if line.strip()]

compared = 0
bad = 0
for row in rows:
    asm, ours_hex = row[0], row[1]
    ours_relocs = sorted(r for r in (row[2] if len(row) > 2 else "").split(",") if r)
    if asm == "ret":
        if ours_hex == RET:
            compared += 1
        else:
            bad += 1
            print(f"MISMATCH ret: encoder {ours_hex}")
        continue
    if text[cursor:cursor + len(ours_hex)] != ours_hex:
        bad += 1
        print(f"MISMATCH {asm}")
        print(f"  encoder: {ours_hex}")
        print(f"  oracle:  {text[cursor:cursor + len(ours_hex)]}")
        break    # the walk has lost its place; later forms cannot be trusted
    start = cursor // 2
    end = start + len(ours_hex) // 2
    oracle_relocs = sorted(f"{off - start}:{kind}" for (off, kind) in relocs if start <= off < end)
    if sorted(ours_relocs) != oracle_relocs:
        bad += 1
        print(f"MISMATCH relocations {asm}: encoder {ours_relocs} oracle {oracle_relocs}")
        break
    cursor += len(ours_hex)
    compared += 1

print(f"compared {compared} of {len(rows)} forms against the oracle")
if bad:
    sys.exit(1)
PY

echo
if [ "$failed" -eq 0 ]; then
  echo "== THE ENCODER MATCHES THE ORACLE"
  exit 0
fi
echo "== THE ENCODER GATE FAILED"
exit 1
