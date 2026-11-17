#!/usr/bin/env bash
# Gate for S1: verifies std/digest SHA256.hexdigest against Python hashlib over lengths 0..130 and 1 MiB.
#
#     bash bench/stale_sha256.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ]; then
  echo "python3 required for gate check" >&2
  exit 1
fi

IYI="${IYI:-$REPO/bin/iyi}"
if [ ! -x "$IYI" ]; then
  echo "iyi compiler not found at $IYI. Build it with make iyi first." >&2
  exit 1
fi

WORK="$(mktemp -d)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

cat > "$WORK/test_sha256.iyi" <<'IYI'
module stale_sha256_test

import std/digest::{SHA256}

len = 0
while len <= 130
  s = "a" * len
  puts "#{len} #{SHA256.hexdigest(s)}"
  len = len + 1
end

puts "1048576 #{SHA256.hexdigest("a" * 1048576)}"
IYI

echo "== building stale_sha256_test with $IYI"
"$IYI" build -o "$WORK/test_sha256" "$WORK/test_sha256.iyi"

"$WORK/test_sha256" > "$WORK/iyi_output.txt"

echo "== verifying against python hashlib"
"$PY" -c '
import sys, hashlib

with open(sys.argv[1], "r") as f:
    lines = [line.strip().split() for line in f if line.strip()]

mismatches = 0
total = 0

for parts in lines:
    if len(parts) != 2:
        continue
    length = int(parts[0])
    got_hex = parts[1].lower()
    total += 1

    expected_hex = hashlib.sha256(b"a" * length).hexdigest()
    if got_hex != expected_hex:
        print(f"MISMATCH at length {length}: expected {expected_hex}, got {got_hex}", file=sys.stderr)
        mismatches += 1

if mismatches > 0:
    print(f"FAILED: {mismatches} mismatches out of {total}", file=sys.stderr)
    sys.exit(1)

print(f"ALL {total} SHA-256 test cases matched Python hashlib byte for byte")
' "$WORK/iyi_output.txt"
