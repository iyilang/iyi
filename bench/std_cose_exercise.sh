#!/usr/bin/env bash
# COSE key validation and signature checks against Python cryptography.
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
status=0
oracle=""
echo '== independent cryptography oracle'
if [ -n "$PY" ] && "$PY" -c 'import cryptography' >/dev/null 2>&1; then
  if "$PY" "$REPO/bench/std_cose_oracle.py" "$WORK/oracle.txt"; then
    oracle="$WORK/oracle.txt"
  else
    echo '  FAIL: cryptography oracle could not generate vectors'; status=1
  fi
else
  echo '  SKIP: Python cryptography unavailable; the fixed RFC 8032 vector still runs'
fi
run_program() {
  if [ -n "$oracle" ]; then "$1" "$oracle"; else "$1"; fi
}
build_run() {
  local name="$1"; shift
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_cose_exercise.iyi" >"$WORK/$name.build" 2>&1; then
    echo "$name: build failed"; tail -30 "$WORK/$name.build"; status=1; return 1
  fi
  if ! run_program "$WORK/$name" >"$WORK/$name.out" 2>&1; then
    echo "$name: exercise failed"; tail -20 "$WORK/$name.out"; status=1; return 1
  fi
  cat "$WORK/$name.out"
  if ! grep -qF 'ALL CHECKS PASSED' "$WORK/$name.out"; then status=1; return 1; fi
}
echo '== plain'
build_run plain
echo '== release'
build_run release --release

echo '== broken-copy proofs'
prove_broken() {
  local label="$1" old="$2" new="$3" needs_oracle="$4"
  if [ -z "$PY" ] || { [ "$needs_oracle" = yes ] && [ -z "$oracle" ]; }; then
    echo "  SKIP $label: Python or cryptography unavailable"; return
  fi
  mkdir -p "$WORK/patched/std"
  if ! OLD="$old" NEW="$new" SRC="$REPO/src/std/cose.iyi" DST="$WORK/patched/std/cose.iyi" "$PY" - <<'PY'
import os
from pathlib import Path
source = Path(os.environ['SRC']).read_text()
old, new = os.environ['OLD'], os.environ['NEW']
if source.count(old) != 1: raise SystemExit('mutation site is missing or ambiguous')
Path(os.environ['DST']).write_text(source.replace(old, new, 1))
PY
  then echo "  FAIL $label: patch failed"; status=1; return; fi
  if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src" "$IYI" build -o "$WORK/mut" "$REPO/bench/std_cose_exercise.iyi" >"$WORK/mut.build" 2>&1; then
    echo "  FAIL $label: patched module did not compile"; tail -10 "$WORK/mut.build"; status=1; return
  fi
  if run_program "$WORK/mut" >"$WORK/mut.out" 2>&1 && grep -qF 'ALL CHECKS PASSED' "$WORK/mut.out"; then
    echo "  FAIL $label: mutation survived"; status=1
  else
    echo "  caught $label"
  fi
}
prove_broken 'EdDSA verification bypass' 'return key.verify(message, signature) if @alg == CoseAlg::EdDSA' 'return true if @alg == CoseAlg::EdDSA' no
prove_broken 'duplicate label accepted' 'if seen[label]?' 'if false' no
prove_broken 'small-order Ed25519 key accepted' 'if CoseEd.small_order?(x)' 'if false' no
prove_broken 'ECDSA COSE signature width' 'width = @alg == CoseAlg::ES256 ? 32 : 48' 'width = @alg == CoseAlg::ES256 ? 31 : 48' yes
prove_broken 'RSA-PSS verified as PKCS1 v1.5' 'return key.verify_pss(RsaHash::SHA256, message, signature) if @alg == CoseAlg::PS256' 'return key.verify_pkcs1v15(RsaHash::SHA256, message, signature) if @alg == CoseAlg::PS256' yes
[ "$status" -eq 0 ] && echo 'the std/cose exercise holds' || echo 'the std/cose exercise failed'
exit "$status"
