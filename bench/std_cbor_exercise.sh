#!/usr/bin/env bash
# RFC 8949 vectors, semantic oracle, malformed inputs and mutation proofs.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';'; REPO="$(cygpath -m "$REPO")"; WORK="$(cygpath -m "$WORK")" ;;
  *) PSEP=':' ;;
esac
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then PY="$candidate"; break; fi
done
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
FIXTURE="$REPO/bench/std_cbor_fixture/appendix_a.txt"
status=0
build_run() {
  local name="$1"; shift
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_cbor_exercise.iyi" >"$WORK/$name.build" 2>&1; then
    echo "$name: build failed"; tail -30 "$WORK/$name.build"; status=1; return 1
  fi
  if ! (cd "$WORK" && "$WORK/$name") >"$WORK/$name.offline" 2>&1 ||
     ! grep -qx 'CBOR OFFLINE CHECKS PASSED' "$WORK/$name.offline"; then
    echo "$name: no-argument exercise failed"; tail -20 "$WORK/$name.offline"; status=1; return 1
  fi
  echo "  $name: no-argument offline checks passed"
  if ! "$WORK/$name" "$FIXTURE" >"$WORK/$name.out" 2>&1; then
    echo "$name: exercise failed"; tail -20 "$WORK/$name.out"; status=1; return 1
  fi
  cat "$WORK/$name.out"
  if ! grep -qF 'ALL CHECKS PASSED' "$WORK/$name.out"; then status=1; return 1; fi
}
echo '== plain'
build_run plain
echo '== release'
build_run release --release

echo '== Appendix A semantic comparison against Python struct'
if [ -z "$PY" ] || [ ! -f "$WORK/plain.out" ]; then
  echo '  SKIP: Python or the built exercise is unavailable'; status=1
else
  "$WORK/plain" "$FIXTURE" shapes >"$WORK/shapes" || status=1
  if ! "$PY" - "$FIXTURE" "$WORK/shapes" <<'PY'
import math, struct, sys

def read(data, offset=0):
    initial = data[offset]; offset += 1
    major, extra = divmod(initial, 32)
    if extra < 24:
        arg = extra
    elif extra < 28:
        n = 1 << (extra - 24)
        arg = int.from_bytes(data[offset:offset+n], 'big'); offset += n
    elif extra == 31:
        arg = None
    else:
        raise ValueError('reserved')
    if major == 0: return f'u:{arg}', offset
    if major == 1: return f'n:{arg}', offset
    if major in (2, 3):
        if arg is None:
            body = b''
            while data[offset] != 255:
                chunk_major = data[offset] >> 5
                assert chunk_major == major
                before = offset
                chunk, offset = read(data, offset)
                body += bytes.fromhex(chunk[2:])
            offset += 1
        else:
            body = data[offset:offset+arg]; offset += arg
        return ('b:' if major == 2 else 't:') + body.hex(), offset
    if major in (4, 5):
        items = []
        count = 0
        while (arg is None and data[offset] != 255) or (arg is not None and count < arg):
            item, offset = read(data, offset)
            if major == 5:
                val, offset = read(data, offset); item += '=' + val
            items.append(item); count += 1
        if arg is None: offset += 1
        brackets = ('[', ']') if major == 4 else ('{', '}')
        return brackets[0] + ','.join(items) + brackets[1], offset
    if major == 6:
        child, offset = read(data, offset)
        return f'tag:{arg}({child})', offset
    if extra < 20 or extra == 24: return f's:{arg}', offset
    if extra in (20, 21, 22, 23): return ['false', 'true', 'null', 'undefined'][extra-20], offset
    f = struct.unpack({25:'>e', 26:'>f', 27:'>d'}[extra], arg.to_bytes({25:2, 26:4, 27:8}[extra], 'big'))[0]
    return ('f:nan' if math.isnan(f) else f'f:{struct.unpack(">Q", struct.pack(">d", f))[0]:x}'), offset

expected = []
for line in open(sys.argv[1], encoding='utf-8'):
    if not line.strip() or line.startswith('#'): continue
    source = line.strip().split('|')[0]
    value, used = read(bytes.fromhex(source))
    assert used == len(bytes.fromhex(source)), source
    expected.append(source + '|' + value)
actual = open(sys.argv[2], encoding='utf-8').read().splitlines()
if expected != actual:
    for a, b in zip(expected, actual):
        if a != b: print('  expected', a, '\n  got     ', b)
    raise SystemExit(f'{len(expected)} expected, {len(actual)} actual')
print(f'  {len(expected)} decoded values match the independent semantic reader')
PY
  then status=1; fi
fi

echo '== broken-copy proofs'
prove_broken() {
  local label="$1" old="$2" new="$3"
  if [ -z "$PY" ]; then echo "  SKIP $label: no Python"; status=1; return; fi
  mkdir -p "$WORK/patched/std"
  if ! OLD="$old" NEW="$new" SRC="$REPO/src/std/cbor.iyi" DST="$WORK/patched/std/cbor.iyi" "$PY" - <<'PY'
import os
from pathlib import Path
source = Path(os.environ['SRC']).read_text()
old, new = os.environ['OLD'], os.environ['NEW']
if source.count(old) != 1: raise SystemExit('mutation site is missing or ambiguous')
Path(os.environ['DST']).write_text(source.replace(old, new, 1))
PY
  then echo "  FAIL $label: patch failed"; status=1; return; fi
  if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src" "$IYI" build -o "$WORK/mut" "$REPO/bench/std_cbor_exercise.iyi" >"$WORK/mut.build" 2>&1; then
    echo "  FAIL $label: patched module did not compile"; tail -10 "$WORK/mut.build"; status=1; return
  fi
  if "$WORK/mut" "$FIXTURE" >"$WORK/mut.out" 2>&1 && grep -qF 'ALL CHECKS PASSED' "$WORK/mut.out"; then
    echo "  FAIL $label: mutation survived"; status=1
  else
    echo "  caught $label"
  fi
}
prove_broken 'length decoding' 'value = value.unsafe_shl(8_u64) | @bytes[@offset].to_u64' 'value = value.unsafe_shl(7_u64) | @bytes[@offset].to_u64'
prove_broken 'negative mapping' 'when 1 then CborValue.negative(argument)' 'when 1 then CborValue.negative(argument + 1_u64)'
prove_broken 'map key sorting' 'return -1 if a[i] < b[i]' 'return 1 if a[i] < b[i]'
prove_broken 'indefinite string assembly' 'value = major == 2 ? CborValue.bytes(data) : CborValue.text(String.new(data, 0, data.size))' 'value = major == 2 ? CborValue.bytes([] of UInt8) : CborValue.text(String.new(data, 0, data.size))'
prove_broken 'depth limit' 'if depth > @limits.max_depth' 'if false'
[ "$status" -eq 0 ] && echo 'the std/cbor exercise holds' || echo 'the std/cbor exercise failed'
exit "$status"
