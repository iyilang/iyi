#!/usr/bin/env bash
# Google V4 vectors and GCS operations against a loopback-only fake.
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
# Refuse non-loopback before DNS or sockets, for each exchange including a
# redirect. The exercise first verifies this refusal against example.com.
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
  if ! "$IYI" build "$@" -o "$W/gcs-$label" "$ROOT/bench/std_gcs_exercise.iyi" >"$WORK/build-$label.log" 2>&1; then
    echo "FAIL: $label build"; tail -25 "$WORK/build-$label.log"; return 1
  fi
  if ! "$WORK/gcs-$label" "$W" "$ROOT/bench/std_gcs_fixture" >"$WORK/out-$label" 2>&1; then
    echo "FAIL: $label run"; cat "$WORK/out-$label"; cat "$WORK/server.log"; return 1
  fi
  cat "$WORK/out-$label"
  grep -q 'ALL CHECKS PASSED' "$WORK/out-$label"
}
echo '== std/gcs plain'
run_exercise plain || exit 1
echo '== std/gcs release'
run_exercise release --release || exit 1
prove_broken() {
  label="$1" expected="$2" old="$3" new="$4"
  if ! OLD="$old" NEW="$new" "$PY" - "$ROOT/src/std/gcs.iyi" "$W/mut/std/gcs.iyi" <<'PY'
import os, pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
old, new = os.environ['OLD'], os.environ['NEW']
if source.count(old) != 1: raise SystemExit('mutation site missing or ambiguous')
changed = source.replace(old, new, 1)
if changed == source: raise SystemExit('mutation made no change')
pathlib.Path(sys.argv[2]).write_text(changed)
PY
  then echo "FAIL: $label mutation setup"; return 1; fi
  if ! IYI_PATH="$W/mut${PSEP}$W/guard${PSEP}$ROOT/src${PSEP}$ROOT/samples/iyi" "$IYI" build -o "$W/gcs-mut" "$ROOT/bench/std_gcs_exercise.iyi" >"$WORK/mut-build.log" 2>&1; then
    echo "FAIL: $label mutation did not compile"; tail -20 "$WORK/mut-build.log"; return 1
  fi
  if "$WORK/gcs-mut" "$W" "$ROOT/bench/std_gcs_fixture" >"$WORK/mut-out" 2>&1; then
    echo "FAIL: $label mutation passed"; return 1
  fi
  if ! grep -qF "$expected" "$WORK/mut-out"; then
    echo "FAIL: $label failed at the wrong assertion"; cat "$WORK/mut-out"; return 1
  fi
  echo "  caught $label: $expected"
}
echo '== mutation proofs'
prove_broken 'query sort' 'canonical vector: Query Parameter Encoding' 'parameters.keys.sorted.map' 'parameters.keys.map' || exit 1
prove_broken 'RFC3986 encoding' 'canonical vector: Simple GET' 'URI.encode_path_segment(value)' 'URI.encode(value)' || exit 1
prove_broken 'scope date' 'canonical vector: Simple GET' 'scope = day + "/auto/storage/goog4_request"' 'scope = "20000101/auto/storage/goog4_request"' || exit 1
prove_broken 'generation precondition name' 'create-only precondition 412' 'fields["ifGenerationMatch"] = generation if generation' 'fields["ifGenerationWrong"] = generation if generation' || exit 1
prove_broken 'metageneration precondition name' 'stale metageneration 412' 'fields["ifMetagenerationMatch"] = metageneration if metageneration' 'fields["ifMetagenerationWrong"] = metageneration if metageneration' || exit 1
prove_broken 'custom endpoint authentication' 'custom endpoint omits bearer' '@authenticate = (endpoint.nil? && emulator.nil?) || authenticate_custom_endpoint' '@authenticate = true' || exit 1
prove_broken 'empty object capability' 'empty object signed GET' 'return GcsError.new("object name is empty") if object && object.empty?' 'return GcsError.new("object name is empty") if false' || exit 1
echo 'std/gcs exercise holds'
