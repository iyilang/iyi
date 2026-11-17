#!/usr/bin/env bash
# Google credentials against a loopback metadata/OAuth/IAM fake.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import cryptography' >/dev/null 2>&1; then PY="$candidate"; break; fi
done
if [ -z "$PY" ]; then echo 'FAIL: Python cryptography is required for the GCS fake'; exit 1; fi
WORK="$(mktemp -d)"
PID=""
cleanup() { if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi; rm -rf "$WORK"; }
trap cleanup EXIT
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) PSEP=';'; ROOT="$(cygpath -m "$REPO")"; W="$(cygpath -m "$WORK")" ;;
  *) PSEP=':'; ROOT="$REPO"; W="$WORK" ;;
esac
mkdir -p "$WORK/guard/std" "$WORK/mut/std"
# A test-only guard at the common HTTP exchange refuses every host except the
# literal loopback address before DNS or socket creation, even on a redirect.
"$PY" - "$ROOT/src/std/http.iyi" "$W/guard/std/http.iyi" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
old = '    return HTTPError.new("missing host") unless host\n'
new = old + '    return HTTPError.new("loopback proof refuses host") unless host == "127.0.0.1"\n'
if source.count(old) != 1: raise SystemExit('HTTP loopback guard did not match once')
pathlib.Path(sys.argv[2]).write_text(source.replace(old, new, 1))
PY
if [ $? -ne 0 ]; then echo 'FAIL: loopback guard setup'; exit 1; fi
"$PY" "$ROOT/bench/std_gcs_server.py" "$W" >"$WORK/server.log" 2>&1 &
PID=$!
for _ in $(seq 1 150); do
  [ -f "$WORK/ready" ] && break
  if ! kill -0 "$PID" 2>/dev/null; then cat "$WORK/server.log"; exit 1; fi
  sleep 0.2
done
if [ ! -f "$WORK/ready" ]; then echo 'FAIL: local fake did not start'; cat "$WORK/server.log"; exit 1; fi
export IYI_PATH="$W/guard${PSEP}$ROOT/src${PSEP}$ROOT/samples/iyi"
run_exercise() {
  label="$1"; shift
  if ! "$IYI" build "$@" -o "$W/auth-$label" "$ROOT/bench/std_google_auth_exercise.iyi" >"$WORK/build-$label.log" 2>&1; then
    echo "FAIL: $label build"; tail -25 "$WORK/build-$label.log"; return 1
  fi
  if ! "$WORK/auth-$label" >"$WORK/offline-$label" 2>&1 || ! grep -qF "offline Google Auth checks passed" "$WORK/offline-$label"; then
    echo "FAIL: $label no-argument run"; cat "$WORK/offline-$label"; return 1
  fi
  cat "$WORK/offline-$label"
  if ! "$WORK/auth-$label" "$W" >"$WORK/out-$label" 2>&1; then
    echo "FAIL: $label run"; cat "$WORK/out-$label"; cat "$WORK/server.log"; return 1
  fi
  cat "$WORK/out-$label"
  grep -q 'ALL CHECKS PASSED' "$WORK/out-$label"
}
echo '== std/google_auth plain'
run_exercise plain || exit 1
echo '== std/google_auth release'
run_exercise release --release || exit 1
prove_broken() {
  label="$1" expected="$2" old="$3" new="$4"
  # MSYS2 can rewrite path-shaped environment values before native Python
  # sees them. Hex keeps mutation needles identical on every platform.
  old_hex="$(printf '%s' "$old" | od -An -v -tx1 | tr -d ' \n')"
  new_hex="$(printf '%s' "$new" | od -An -v -tx1 | tr -d ' \n')"
  if ! OLD_HEX="$old_hex" NEW_HEX="$new_hex" "$PY" - "$ROOT/src/std/google_auth.iyi" "$W/mut/std/google_auth.iyi" <<'PY'
import os, pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
old = bytes.fromhex(os.environ['OLD_HEX']).decode('utf-8')
new = bytes.fromhex(os.environ['NEW_HEX']).decode('utf-8')
if source.count(old) != 1: raise SystemExit('mutation site missing or ambiguous')
changed = source.replace(old, new, 1)
if changed == source: raise SystemExit('mutation made no change')
pathlib.Path(sys.argv[2]).write_text(changed, encoding="utf-8")
PY
  then echo "FAIL: $label mutation setup"; return 1; fi
  if ! IYI_PATH="$W/mut${PSEP}$W/guard${PSEP}$ROOT/src${PSEP}$ROOT/samples/iyi" "$IYI" build -o "$W/auth-mut" "$ROOT/bench/std_google_auth_exercise.iyi" >"$WORK/mut-build.log" 2>&1; then
    echo "FAIL: $label mutation did not compile"; tail -20 "$WORK/mut-build.log"; return 1
  fi
  if "$WORK/auth-mut" "$W" >"$WORK/mut-out" 2>&1; then
    echo "FAIL: $label mutation passed"; return 1
  fi
  if ! grep -qF "$expected" "$WORK/mut-out"; then
    echo "FAIL: $label failed at the wrong assertion"; cat "$WORK/mut-out"; return 1
  fi
  echo "  caught $label: $expected"
}
echo '== mutation proofs'
prove_broken 'JWT exp' 'JWT grant' 'json.field("exp", now + 3600_i64)' 'json.field("exp", now + 3599_i64)' || exit 1
prove_broken 'cache headroom' 'cache headroom request count' 'now < @cached_until' 'now <= @cached_until' || exit 1
prove_broken 'IAM resource path' 'IAM signBlob signature' 'serviceAccounts' 'serviceAccount' || exit 1
echo 'std/google_auth exercise holds'
