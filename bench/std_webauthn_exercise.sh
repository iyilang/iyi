#!/usr/bin/env bash
# Exercise WebAuthn registration/assertion against independent authenticators.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import cryptography' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
if [ -z "$PY" ]; then
  echo 'FAIL: Python cryptography is required for the WebAuthn software authenticator'
  exit 1
fi
BASE="${TMPDIR:-${TEMP:-}}"
if [ -z "$BASE" ]; then
  echo 'FAIL: TMPDIR or TEMP is required for WebAuthn scratch files'
  exit 1
fi
WORK="$(mktemp -d "${BASE%/}/iyi-webauthn.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
W3C="$REPO/bench/std_webauthn_fixture/w3c.json"
CHROME="$REPO/bench/std_webauthn_fixture/chrome.json"

printf '%s\n' '== software authenticator: 100 registrations per format and algorithm'
if ! "$PY" "$REPO/bench/std_webauthn_authenticator.py" 100 > "$WORK/cases.jsonl"; then
  echo 'FAIL: software-authenticator corpus generation'; exit 1
fi
if ! "$PY" "$REPO/bench/std_webauthn_authenticator.py" 1 > "$WORK/small.jsonl"; then
  echo 'FAIL: software-authenticator negative corpus generation'; exit 1
fi
"$PY" - "$WORK/cases.jsonl" <<'PY' || exit 1
import collections, json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    cases = [json.loads(line) for line in f]
counts = collections.Counter('/'.join(x['name'].split('/')[1:]) for x in cases if x['name'].split('/')[0].isdigit())
for alg in ('-7', '-257', '-8'):
    for fmt in ('none', 'packed', 'packed-x5c'):
        assert counts[f'{alg}/{fmt}'] == 100, (alg, fmt, counts)
print('  900 registrations, 900 assertions, plus named negative cases')
PY

for mode in plain release; do
  opt=()
  [ "$mode" = release ] && opt=(--release)
  echo "== $mode build"
  if ! "$IYI" build "${opt[@]}" -o "$WORK/exercise-$mode" "$REPO/bench/std_webauthn_exercise.iyi" >"$WORK/build-$mode.log" 2>&1; then
    echo "FAIL: $mode build"; tail -30 "$WORK/build-$mode.log"; exit 1
  fi
  if ! "$WORK/exercise-$mode" "$WORK/cases.jsonl" "$W3C" "$CHROME" >"$WORK/$mode.out" 2>&1; then
    echo "FAIL: $mode exercise"; tail -35 "$WORK/$mode.out"; exit 1
  fi
  if ! grep -qx 'ALL CHECKS PASSED' "$WORK/$mode.out"; then
    echo "FAIL: $mode missing success sentinel"; exit 1
  fi
  cat "$WORK/$mode.out"
done

echo '== standard-module dependency closure'
"$PY" - "$REPO" <<'PY' || exit 1
import pathlib, re, sys
root = pathlib.Path(sys.argv[1]) / 'src'
seen, pending = set(), ['std/webauthn']
while pending:
    module = pending.pop()
    if module in seen:
        continue
    seen.add(module)
    for target in re.findall(r'^\s*import\s+([A-Za-z0-9_./-]+)', (root / (module + '.iyi')).read_text(), re.M):
        if not target.startswith('std/'):
            raise SystemExit('FAIL: non-std import ' + target + ' in ' + module)
        if target not in seen:
            pending.append(target)
print('  %d transitive modules, all under std/' % len(seen))
PY

echo '== proving the checks fail on broken implementations'
for mutation in rp_id uv counter signed_data origin; do
  mkdir -p "$WORK/$mutation/std"
  "$PY" - "$REPO/src/std/webauthn.iyi" "$WORK/$mutation/std/webauthn.iyi" "$mutation" <<'PY' || exit 1
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
patches = {
 'rp_id': ('return verification("rp_id") unless diff == 0', 'return verification("rp_id") unless true'),
 'uv': ('return verification("user_verified") if uv && flags & 4 == 0', 'return verification("user_verified") if false'),
 'counter': ('count <= expected.sign_count', 'count < expected.sign_count'),
 'signed_data': ('signed = authenticator_data + SHA256.hash_bytes(client_data_json)', 'signed = SHA256.hash_bytes(client_data_json) + authenticator_data'),
 'origin': ('return verification("origin") unless origins.includes?(origin)', 'return verification("origin") unless true'),
}
old, new = patches[sys.argv[3]]
if source.count(old) != 1:
    raise SystemExit('FAIL: mutation site missing or ambiguous: ' + sys.argv[3])
Path(sys.argv[2]).write_text(source.replace(old, new, 1))
PY
  if ! IYI_PATH="$WORK/$mutation${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/broken-$mutation" "$REPO/bench/std_webauthn_exercise.iyi" >"$WORK/$mutation.build" 2>&1; then
    echo "FAIL: $mutation mutation did not compile"; tail -20 "$WORK/$mutation.build"; exit 1
  fi
  if "$WORK/broken-$mutation" "$WORK/small.jsonl" "$W3C" "$CHROME" >"$WORK/$mutation.out" 2>&1; then
    echo "FAIL: $mutation mutation passed"; exit 1
  fi
  if grep -qx 'ALL CHECKS PASSED' "$WORK/$mutation.out" || ! grep -q 'ASSERTION FAILED:' "$WORK/$mutation.out"; then
    echo "FAIL: $mutation did not fail an exercise assertion"; tail -20 "$WORK/$mutation.out"; exit 1
  fi
  case "$mutation" in
    rp_id) expected='rpId hash' ;;
    uv) expected='user verified' ;;
    counter) expected='assertion counter' ;;
    signed_data) expected='0/-7/none' ;;
    origin) expected='client origin' ;;
  esac
  if ! grep -Fq "ASSERTION FAILED: $expected:" "$WORK/$mutation.out"; then
    echo "FAIL: $mutation failed at the wrong assertion"; tail -20 "$WORK/$mutation.out"; exit 1
  fi
  echo "  caught $mutation at $expected"
done

echo 'ALL WEBAUTHN CHECKS PASSED'
