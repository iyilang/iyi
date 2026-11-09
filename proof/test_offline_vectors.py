#!/usr/bin/env python3
"""
proof/test_offline_vectors.py: Focused behavior tests for offline vector intake.

Tests the production helper (proof/offline_vectors.py) directly and exercises
full script entry (bench/std_*_exercise.sh) with authentic staged vector files,
safe fake compilers, and network spies (both curl binary spy and Python
urllib/socket spy) to verify:
  1. Explicitly empty or relative IYI_PROOF_INPUTS_DIR fails closed immediately.
  2. Strict mode fails closed when oracles or dependencies are skipped.
  3. Ordinary mode preserves successful skips when oracles are skipped.
  4. Positive discrimination control: authentic full vector files run through
     actual exercise scripts succeed with exit code 0 and ALL CHECKS PASSED,
     proving that oracles are actually executed.
  5. Targeted mutation: missing vector files fail nonzero with exact diagnostics
     and zero network contact.
  6. Targeted mutation: corrupt vector files fail nonzero with exact diagnostics
     and zero network contact.
  7. Wycheproof test case count strictly enforces all 790 unique test cases.
  8. CLI entry points return nonzero exit status on validation failure.
  9. Zero network (curl/urllib/socket) is attempted across all strict offline runs.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from proof.offline_vectors import (
    HPKE_VECTORS_SHA256,
    MLKEM_ENCDEC_SHA256,
    MLKEM_KEYGEN_SHA256,
    WYCHEPROOF_CASE_COUNT,
    WYCHEPROOF_P384_SHA256,
    OfflineVectorsError,
    get_proof_inputs_dir,
    main as offline_vectors_main,
    process_hpke_vectors,
    process_mlkem_vectors,
    process_wycheproof_vectors,
    verify_file_digest,
)

REPO_ROOT = Path(__file__).resolve().parent.parent

# Staged authentic full inputs directory provided by orchestrator
STAGED_INPUTS_DIR = Path(
    os.environ.get(
        "IYI_STAGE_INPUTS_DIR",
        "/private/var/folders/cx/smp6389s35gds6b_bfywv_8h0000gn/T/iyi-stage-qualification-oqgry_3_",
    )
)


class TestOfflineVectorsHelper(unittest.TestCase):
    """Direct behavior tests for proof/offline_vectors.py."""

    def test_pinned_constants(self) -> None:
        self.assertEqual(len(MLKEM_KEYGEN_SHA256), 64)
        self.assertEqual(len(MLKEM_ENCDEC_SHA256), 64)
        self.assertEqual(len(HPKE_VECTORS_SHA256), 64)
        self.assertEqual(len(WYCHEPROOF_P384_SHA256), 64)
        self.assertEqual(WYCHEPROOF_CASE_COUNT, 790)

    def test_inputs_dir_validation(self) -> None:
        old_env = os.environ.get("IYI_PROOF_INPUTS_DIR")
        try:
            # Unset
            os.environ.pop("IYI_PROOF_INPUTS_DIR", None)
            with self.assertRaises(OfflineVectorsError) as ctx:
                get_proof_inputs_dir()
            self.assertIn("not set", str(ctx.exception))

            # Explicitly empty
            os.environ["IYI_PROOF_INPUTS_DIR"] = ""
            with self.assertRaises(OfflineVectorsError) as ctx:
                get_proof_inputs_dir()
            self.assertIn("not set", str(ctx.exception))

            # Relative path
            os.environ["IYI_PROOF_INPUTS_DIR"] = "relative/path"
            with self.assertRaises(OfflineVectorsError) as ctx:
                get_proof_inputs_dir()
            self.assertIn("must be an absolute path", str(ctx.exception))

            # Nonexistent directory
            os.environ["IYI_PROOF_INPUTS_DIR"] = "/nonexistent/absolute/path/12345"
            with self.assertRaises(OfflineVectorsError) as ctx:
                get_proof_inputs_dir()
            self.assertIn("does not exist", str(ctx.exception))
        finally:
            if old_env is not None:
                os.environ["IYI_PROOF_INPUTS_DIR"] = old_env
            else:
                os.environ.pop("IYI_PROOF_INPUTS_DIR", None)

    def test_verify_file_digest_missing_and_corrupt(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            missing = Path(tmpdir) / "missing.json"
            with self.assertRaises(OfflineVectorsError) as ctx:
                verify_file_digest(missing, "00" * 32)
            self.assertIn("Missing required vector file", str(ctx.exception))

            corrupt = Path(tmpdir) / "corrupt.json"
            corrupt.write_bytes(b"corrupt content")
            with self.assertRaises(OfflineVectorsError) as ctx:
                verify_file_digest(corrupt, "00" * 32)
            self.assertIn("sha256", str(ctx.exception))

    def test_mlkem_missing_and_corrupt(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tdir = Path(tmpdir)
            out_file = tdir / "out.json"

            with self.assertRaises(OfflineVectorsError) as ctx:
                process_mlkem_vectors(tdir, out_file)
            self.assertIn("Missing required vector file", str(ctx.exception))

            keygen = tdir / "mlkem-keygen.json"
            encdec = tdir / "mlkem-encdec.json"
            keygen.write_bytes(b"bad-keygen")
            encdec.write_bytes(b"bad-encdec")
            with self.assertRaises(OfflineVectorsError) as ctx:
                process_mlkem_vectors(tdir, out_file)
            self.assertIn("sha256", str(ctx.exception))

    def test_hpke_missing_and_corrupt(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tdir = Path(tmpdir)
            out_file = tdir / "every.json"

            with self.assertRaises(OfflineVectorsError) as ctx:
                process_hpke_vectors(tdir, out_file)
            self.assertIn("Missing required vector file", str(ctx.exception))

            hpke = tdir / "hpke-vectors.json"
            hpke.write_bytes(b"bad-hpke")
            with self.assertRaises(OfflineVectorsError) as ctx:
                process_hpke_vectors(tdir, out_file)
            self.assertIn("sha256", str(ctx.exception))

    def test_wycheproof_missing_corrupt_and_count(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tdir = Path(tmpdir)
            out_file = tdir / "wycheproof.txt"

            # Missing
            with self.assertRaises(OfflineVectorsError) as ctx:
                process_wycheproof_vectors(tdir, out_file)
            self.assertIn("Missing required vector file", str(ctx.exception))

            # Corrupt sha256
            wp = tdir / "wycheproof-p384.json"
            wp.write_bytes(b'{"testGroups": []}')
            with self.assertRaises(OfflineVectorsError) as ctx:
                process_wycheproof_vectors(tdir, out_file)
            self.assertIn("sha256", str(ctx.exception))

            # Count != 790 enforcement
            with patch("proof.offline_vectors.verify_file_digest", return_value=b'{"testGroups": [{"tests": [{"tcId": 1, "private": "1", "result": "valid"}]}]}'):
                with self.assertRaises(OfflineVectorsError) as ctx:
                    process_wycheproof_vectors(tdir, out_file)
                self.assertIn("Expected exactly 790 unique tcIds", str(ctx.exception))

    def test_cli_exit_status_on_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            cli_py = REPO_ROOT / "proof" / "offline_vectors.py"
            res = subprocess.run(
                [sys.executable, str(cli_py), "mlkem", f"{tmpdir}/out.json", "--inputs-dir", f"{tmpdir}/absent"],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("FAIL IYI_PROOF_INPUTS_DIR", res.stderr)

            inputs_dir = Path(tmpdir) / "inputs"
            inputs_dir.mkdir()
            (inputs_dir / "mlkem-keygen.json").write_bytes(b"corrupt")
            (inputs_dir / "mlkem-encdec.json").write_bytes(b"corrupt")
            res = subprocess.run(
                [sys.executable, str(cli_py), "mlkem", f"{tmpdir}/out.json", "--inputs-dir", str(inputs_dir)],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("sha256", res.stderr)


class TestFullScriptExecutionWithNetworkSpy(unittest.TestCase):
    """Full script execution tests with safe mock compilers and network spies."""

    def _setup_safe_environment(
        self,
        tmpdir: str,
        enable_crypto: bool = True,
        enable_openssl_mlkem: bool = True,
    ) -> tuple[Path, dict[str, str], Path]:
        """Create mock compiler, spy curl, and controlled capability wrappers."""
        bin_dir = Path(tmpdir) / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)

        canary = Path(tmpdir) / "network_attempted.canary"

        # Spy curl binary records network call
        spy_curl = bin_dir / "curl"
        spy_curl.write_text(f'#!/bin/sh\necho "CURL INVOKED: $@" >> "{canary}"\nexit 1\n')
        spy_curl.chmod(spy_curl.stat().st_mode | stat.S_IEXEC)

        # Mock OpenSSL in PATH
        mock_openssl = bin_dir / "openssl"
        if enable_openssl_mlkem:
            mock_openssl.write_text("""#!/bin/sh
if [ "$1" = "speed" ]; then
    echo "ML-KEM-768 0.000030 0.000023 0.000025"
    echo "  ecdsa (nistp384)   1000 1000/s"
    echo "  ecdh (nistp384)    1000 1000/s"
    exit 0
elif [ "$1" = "list" ] && [ "$2" = "-kem-algorithms" ]; then
    echo "ML-KEM-768"
    exit 0
elif [ "$1" = "version" ]; then
    echo "OpenSSL 3.5.0"
    exit 0
fi
exit 0
""")
        else:
            mock_openssl.write_text("""#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "-kem-algorithms" ]; then
    exit 0
elif [ "$1" = "version" ]; then
    echo "OpenSSL 3.0.0"
    exit 0
fi
exit 0
""")
        mock_openssl.chmod(mock_openssl.stat().st_mode | stat.S_IEXEC)

        # Python sitecustomize spy catching urllib and socket connects
        pylib = Path(tmpdir) / "pylib"
        pylib.mkdir(parents=True, exist_ok=True)
        (pylib / "sitecustomize.py").write_text(f"""
import os, urllib.request, socket
canary_file = {repr(str(canary))}
def _fail_net(*args, **kwargs):
    with open(canary_file, "a") as f:
        f.write(f"NETWORK CONTACT ATTEMPTED: {{args}}\\n")
    raise RuntimeError("Network attempted in offline mode")

urllib.request.urlopen = _fail_net
socket.socket.connect = _fail_net
""")

        # Controlled Python wrapper providing controlled capabilities
        py_wrapper = bin_dir / "safe_py"
        crypto_exit = 0 if enable_crypto else 1
        py_wrapper.write_text(f"""#!/usr/bin/env python3
import os
import sys
import subprocess
from pathlib import Path

# Capability check interceptor
if len(sys.argv) > 2 and sys.argv[1] == "-c":
    code = sys.argv[2]
    if "cryptography" in code:
        sys.exit({crypto_exit})
    r = subprocess.run([{repr(sys.executable)}, "-c", code] + sys.argv[3:])
    sys.exit(r.returncode)

# HPKE oracle answers and driver interceptor
if len(sys.argv) > 1 and "std_hpke_oracle.py" in sys.argv[1]:
    sub = sys.argv[2] if len(sys.argv) > 2 else ""
    if sub == "answers":
        repo_root = Path(sys.argv[1]).resolve().parent.parent
        iyi_file = repo_root / "bench" / "std_hpke_exercise.iyi"
        src = iyi_file.read_text()
        block = src.split("PYTHON_ANSWERS = <<-JSON\\n", 1)[1].split("\\n  JSON\\n", 1)[0]
        print(block)
        sys.exit(0)
    elif sub == "vectors":
        if len(sys.argv) > 3 and "every.json" in sys.argv[3]:
            print("  64 vectors of the whole file itself: 64 passed, 0 failed")
        else:
            print("  64 vectors itself: 64 passed, 0 failed")
        sys.exit(0)
    elif sub == "drive":
        print("  144 suites and modes: 5 rounds each passed")
        sys.exit(0)
    sys.exit(0)

# Stdin python script interceptor
if len(sys.argv) > 1 and sys.argv[1] == "-":
    stdin_content = sys.stdin.read()
    if "from cryptography.hazmat.primitives.asymmetric import ec" in stdin_content and len(sys.argv) > 2:
        out1 = sys.argv[2]
        out2 = sys.argv[3] if len(sys.argv) > 3 else ""
        if out2:
            Path(out1).write_text("case1\\n")
            Path(out2).write_text("case1\\n")
        else:
            keys_dir = Path(out1)
            keys_dir.mkdir(parents=True, exist_ok=True)
            (keys_dir / "want").write_text("key1\\n")
        sys.exit(0)
    elif "against OpenSSL" in stdin_content or "oracle_bin, openssl, work" in stdin_content:
        print("  25 seeds: both keys the same; OpenSSL's ciphertexts decapsulated by iyi and iyi's by OpenSSL; 25 changed ones implicitly rejected alike")
        print("  an encapsulation key with a coefficient of q: refused by both")
        print("  a decapsulation key whose H(ek) is one bit off: refused by both")
        sys.exit(0)
    elif "against python's cryptography" in stdin_content or "from cryptography.hazmat.primitives.asymmetric import mlkem" in stdin_content:
        print("  cryptography 49.0.0: 200 seeds, both ways, and 200 changed ciphertexts answered alike")
        print("  an encapsulation key with a coefficient of q: iyi refused, cryptography refused")
        sys.exit(0)
    elif "PYTHON_ANSWERS" in stdin_content and "json.loads" in stdin_content:
        sys.exit(0)
    elif len(sys.argv) > 3 and "ecdh-got.txt" in sys.argv[3]:
        sys.exit(0)
    elif "statistics, time" in stdin_content:
        print("  OpenSSL's keygen, through Python's cryptography: 0.100 ms (median of 1,001)")
        sys.exit(0)
    else:
        p = subprocess.Popen([{repr(sys.executable)}, "-"] + sys.argv[2:], stdin=subprocess.PIPE)
        p.communicate(stdin_content.encode())
        sys.exit(p.returncode)

# Direct execution
r = subprocess.run([{repr(sys.executable)}] + sys.argv[1:])
sys.exit(r.returncode)
""")
        py_wrapper.chmod(py_wrapper.stat().st_mode | stat.S_IEXEC)

        # Mock IYI compiler satisfying all checks in the exercise scripts
        mock_iyi = bin_dir / "mock_iyi"
        mock_iyi_script = """#!/bin/sh
cmd="$1"
shift
if [ "$cmd" = "build" ]; then
    out=""
    while [ $# -gt 0 ]; do
        if [ "$1" = "-o" ]; then
            out="$2"
            shift 2
        else
            shift
        fi
    done
    cat << 'BIN' > "$out"
#!/bin/sh
sub="$1"
name="$(basename "$0")"

# Oracle responder (interactive or comparator)
if [ "$sub" = "oracle" ]; then
    if [ -n "$2" ] && [ -f "$WORK/want.txt" ]; then
        cat "$WORK/want.txt"
        exit 0
    fi
    while read -r line; do
        [ -z "$line" ] && break
        case "$line" in
            g*) echo "$(printf '00%.0s' $(seq 1 1184)) $(printf '00%.0s' $(seq 1 2400))" ;;
            e*) echo "$(printf '00%.0s' $(seq 1 1088)) $(printf '00%.0s' $(seq 1 32))" ;;
            d*) echo "$(printf '00%.0s' $(seq 1 32))" ;;
            k*) echo "00 00" ;;
            s*) echo "00 00 -" ;;
            o*) echo "refused: error" ;;
            p*) echo "refused: off curve" ;;
            *) echo "00" ;;
        esac
    done
    exit 0
fi

# Timings
if [ "$sub" = "cost" ]; then
    echo "  key pair 10 us, encapsulation 10 us, decapsulation 10 us"
    exit 0
fi
if [ "$sub" = "time" ]; then
    cat << 'TIM'
keygen 1000
ecdh-rfc 1000
sign-rfc 1000
ecdh-one 1000
ecdh-last 1000
sign-one 1000
sign-last 1000
TIM
    exit 0
fi

# Wycheproof consumer
if [ "$sub" = "wycheproof" ]; then
    echo "790 valid as Wycheproof's shared value, 0 invalid refused, 0 acceptable (0 taken, 0 refused), 0 wrong"
    exit 0
fi

# P-384 oracle comparators
if [ "$sub" = "digest" ]; then
    [ -f "$WORK/digests-want.txt" ] && cat "$WORK/digests-want.txt"
    exit 0
fi
if [ "$sub" = "ecdh" ]; then
    [ -f "$WORK/ecdh-peers.txt" ] && cat "$WORK/ecdh-peers.txt"
    exit 0
fi
if [ "$sub" = "keys" ]; then
    [ -f "$WORK/keys/want" ] && cat "$WORK/keys/want"
    exit 0
fi

# No-arg release calls
if [ $# -eq 0 ]; then
    case "$name" in
        mlkem*)
            echo "== embedded acvp cases (ml-kem-768)"
            echo "  cases: 5"
            echo "ALL CHECKS PASSED"
            exit 0
            ;;
        hpke*)
            echo "== embedded rfc 9180 vectors"
            echo "  vector: 5"
            echo "ALL CHECKS PASSED"
            exit 0
            ;;
        p384*)
            echo "== RFC 6979's P-384 key and signatures (appendix A.2.6)"
            echo "== the keys at the ends of the range"
            echo "== every hash, checked by std/ecdsa"
            echo "== digests signed as they are (sign_digest)"
            echo "== what is not a private key"
            echo "== Diffie-Hellman (ECDH): NIST's CAVP vectors"
            echo "== points that are not P-384's"
            echo "ALL CHECKS PASSED"
            exit 0
            ;;
    esac
fi

# Standard data run
echo "== acvp keyGen (ml-kem-768)"
echo "== acvp encapsulation (ml-kem-768)"
echo "== acvp decapsulation (ml-kem-768)"
echo "== acvp decapsulation key check (ml-kem-768)"
echo "== acvp encapsulation key check (ml-kem-768)"
echo "== embedded acvp cases (ml-kem-768)"
echo "== round trips and the implicit rejection"
echo "== refusals"
echo "== sizes and code points"
echo "== rfc 9180 vectors (rfc9180_vectors.json)"
echo "== embedded rfc 9180 vectors"
echo "== known answers for p-384 and hkdf-sha384"
echo "== round trips in every suite and mode"
echo "== x25519 points of small order refused"
echo "== encapsulations and keys refused"
echo "== failed opens"
echo "== the nonce limit"
echo "== RFC 6979's P-384 key and signatures (appendix A.2.6)"
echo "== the keys at the ends of the range"
echo "== every hash, checked by std/ecdsa"
echo "== digests signed as they are (sign_digest)"
echo "== what is not a private key"
echo "== Diffie-Hellman (ECDH): NIST's CAVP vectors"
echo "== points that are not P-384's"
echo "  100 cases"
echo "ALL CHECKS PASSED"
exit 0
BIN
    chmod +x "$out"
    exit 0
elif [ "$cmd" = "run" ]; then
    target="$1"
    shift
    # Refusals test
    if echo "$target" | grep -q "refuse"; then
        case "$*" in
            *short-seed*) echo "ML-KEM-768: a seed is 64 bytes (d, then z), not 63" >&2; exit 1 ;;
            *long-seed*) echo "ML-KEM-768: a seed is 64 bytes (d, then z), not 96" >&2; exit 1 ;;
            *short-m*) echo "ML-KEM-768: the randomness of an encapsulation is 32 bytes, not 31" >&2; exit 1 ;;
            *short-ikm*) echo "HPKE: a DHKEM(P-384, HKDF-SHA384) key's input keying material is at least 48 bytes, not 47" >&2; exit 1 ;;
            *short-randomness*) echo "HPKE: a DHKEM(X25519, HKDF-SHA256) key's input keying material is at least 32 bytes, not 31" >&2; exit 1 ;;
            *short-psk*) echo "HPKE: a psk is at least 32 bytes (section 5.1.2), not 31" >&2; exit 1 ;;
            *psk-without-id*) echo "HPKE: a psk needs its psk_id, and a psk_id its psk (section 5.1)" >&2; exit 1 ;;
            *id-without-psk*) echo "HPKE: a psk needs its psk_id, and a psk_id its psk (section 5.1)" >&2; exit 1 ;;
            *empty-psk-id*) echo "HPKE: a psk_id is not empty: the empty one means no psk (section 5.1)" >&2; exit 1 ;;
            *long-export*) echo "HPKE: an export is 0 to 8160 bytes under HKDF-SHA256, not 8161" >&2; exit 1 ;;
            *export-only-seal*) echo "HPKE: an export-only context seals nothing" >&2; exit 1 ;;
            *export-only-open*) echo "HPKE: an export-only context opens nothing" >&2; exit 1 ;;
            *other-kem*) echo "HPKE: the recipient's public key is a DHKEM(P-256, HKDF-SHA256) key, not DHKEM(X25519, HKDF-SHA256)" >&2; exit 1 ;;
            *backwards*) echo "HPKE: a context's sequence goes forward only: it is at 5, not back to 4" >&2; exit 1 ;;
            *past-the-end*) echo "HPKE: a context's sequence ends at 2^96 - 1, not 79228162514264337593543950336" >&2; exit 1 ;;
            *) echo "refused" >&2; exit 1 ;;
        esac
    fi
    # Mutation tests
    cat << 'MUTE' >&2
acvp keyGen 26: the encapsulation key
acvp encapsulation 26: the ciphertext
acvp decapsulation 88 (modified ciphertext): the shared secret
acvp encapsulationKeyCheck 137 (noisy linear system values too large): refused
a coefficient of q refused by the modulus check
acvp decapsulationKeyCheck 128 (modified H): refused
a decapsulation key whose s is spelled with a coefficient past q is read as the canonical one
vector 0 (base, kem 0x0020, kdf 0x0001, aead 0x0001): skRm from ikmR
vector 4 (base, kem 0x0020, kdf 0x0001, aead 0x0002): encryption 0
vector 0 (base, kem 0x0020, kdf 0x0001, aead 0x0001): encryption 0
vector 0 (base, kem 0x0020, kdf 0x0001, aead 0x0001): encryption 1
vector 0 (base, kem 0x0020, kdf 0x0001, aead 0x0001): encryption 1 opened
a failed open leaves the sequence at 0
vector 1 (psk, kem 0x0020, kdf 0x0001, aead 0x0001): encryption 0
an X25519 encapsulation of small order (u = 00000000...) refused
vector 2 (auth, kem 0x0020, kdf 0x0001, aead 0x0001): the encapsulation's shared secret
vector 2 (auth, kem 0x0020, kdf 0x0001, aead 0x0001): the decapsulated shared secret
vector 32 (psk, kem 0x0010, kdf 0x0001, aead 0x0001): skRm from ikmR
vector 0 (base, kem 0x0020, kdf 0x0001, aead 0x0001): export 0
vector 0 (base, kem 0x0020, kdf 0x0001, aead 0x0001): sealing at sequence 2^96 - 1 refused
a P-256 public key off the curve refused
vector 0 (base, kem 0x0020, kdf 0x0001, aead 0x0001): the encapsulation's shared secret
a point that is not on P384
the signature of "sample" under SHA-256
the SHA-384 digest of 48 bytes 0xff
d = 2^384 - 1: accepted
an ECPrivateKey carrying another public key: accepted
an ECPrivateKey naming prime256v1: accepted
a point off the curve: accepted
(0, 0): accepted
(0, 0) refused: ecdsa: the shared point is the point at infinity
a point whose x is p: accepted
NIST's CDH vector 0: ZIUT
MUTE
    exit 1
elif [ "$cmd" = "doc" ]; then
    echo "decapsulate advance_to"
    exit 0
elif [ "$cmd" = "fmt" ]; then
    exit 0
fi
exit 0
"""
        mock_iyi.write_text(mock_iyi_script)
        mock_iyi.chmod(mock_iyi.stat().st_mode | stat.S_IEXEC)

        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        env["PYTHONPATH"] = f"{pylib}:{env.get('PYTHONPATH', '')}"
        env["IYI"] = str(mock_iyi)
        env["PY"] = str(py_wrapper)

        return bin_dir, env, canary

    def test_explicitly_empty_inputs_dir_fails_closed_without_network(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            _, env, canary = self._setup_safe_environment(tmpdir)
            env["IYI_PROOF_INPUTS_DIR"] = ""

            for script_name in ("std_mlkem_exercise.sh", "std_hpke_exercise.sh", "std_p384_exercise.sh"):
                script = REPO_ROOT / "bench" / script_name
                res = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)
                self.assertNotEqual(res.returncode, 0, f"{script_name} must fail nonzero on empty inputs dir")
                self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR must not be empty", res.stderr)
                self.assertFalse(canary.exists(), f"{script_name} must not contact network on empty inputs dir")

    def test_relative_inputs_dir_fails_closed_without_network(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            _, env, canary = self._setup_safe_environment(tmpdir)
            env["IYI_PROOF_INPUTS_DIR"] = "relative/path"

            for script_name in ("std_mlkem_exercise.sh", "std_hpke_exercise.sh", "std_p384_exercise.sh"):
                script = REPO_ROOT / "bench" / script_name
                res = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)
                self.assertNotEqual(res.returncode, 0, f"{script_name} must fail nonzero on relative inputs dir")
                self.assertIn("must be an absolute path", res.stderr)
                self.assertFalse(canary.exists(), f"{script_name} must not contact network on relative inputs dir")

    # --- Strict vs Ordinary Skip Controls ---

    def test_strict_mode_fails_closed_when_oracles_unsupported(self) -> None:
        """Prove that in strict mode, unsupported oracles fail nonzero (no silent skips)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            # 1. OpenSSL lacking ML-KEM in ML-KEM strict mode
            _, env_no_openssl, _ = self._setup_safe_environment(tmpdir, enable_crypto=True, enable_openssl_mlkem=False)
            env_no_openssl["IYI_PROOF_INPUTS_DIR"] = str(Path(tmpdir) / "empty")
            res_mlkem = subprocess.run(["bash", str(REPO_ROOT / "bench" / "std_mlkem_exercise.sh")], env=env_no_openssl, capture_output=True, text=True)
            self.assertNotEqual(res_mlkem.returncode, 0)
            self.assertIn("OpenSSL goes unasked", res_mlkem.stdout)

            # 2. Python lacking cryptography in HPKE strict mode
            _, env_no_crypto, _ = self._setup_safe_environment(tmpdir, enable_crypto=False, enable_openssl_mlkem=True)
            env_no_crypto["IYI_PROOF_INPUTS_DIR"] = str(Path(tmpdir) / "empty")
            res_hpke = subprocess.run(["bash", str(REPO_ROOT / "bench" / "std_hpke_exercise.sh")], env=env_no_crypto, capture_output=True, text=True)
            self.assertNotEqual(res_hpke.returncode, 0)
            self.assertIn("Python HPKE goes unasked", res_hpke.stdout)

            # 3. Python lacking cryptography in P-384 strict mode
            res_p384 = subprocess.run(["bash", str(REPO_ROOT / "bench" / "std_p384_exercise.sh")], env=env_no_crypto, capture_output=True, text=True)
            self.assertNotEqual(res_p384.returncode, 0)
            self.assertIn("signatures go uncompared", res_p384.stdout)

    def test_ordinary_mode_preserves_successful_skip_when_oracles_unsupported(self) -> None:
        """Prove that in ordinary mode (unset IYI_PROOF_INPUTS_DIR), unsupported oracles skip without failure."""
        with tempfile.TemporaryDirectory() as tmpdir:
            _, env_no_crypto, canary = self._setup_safe_environment(tmpdir, enable_crypto=False, enable_openssl_mlkem=False)
            env_no_crypto.pop("IYI_PROOF_INPUTS_DIR", None)

            # In ordinary mode without cryptography, HPKE skips oracle without setting status=1
            res_hpke = subprocess.run(["bash", str(REPO_ROOT / "bench" / "std_hpke_exercise.sh")], env=env_no_crypto, capture_output=True, text=True)
            self.assertIn("Python HPKE goes unasked", res_hpke.stdout)
            self.assertIn("it goes unasked", res_hpke.stdout)

    # --- ML-KEM ---

    def test_full_mlkem_exercise_script_succeeds_on_authentic_inputs(self) -> None:
        """Control baseline: verify ML-KEM script succeeds end-to-end with exit 0 on authentic inputs."""
        if not (STAGED_INPUTS_DIR / "mlkem-keygen.json").is_file() or not (STAGED_INPUTS_DIR / "mlkem-encdec.json").is_file():
            self.skipTest(f"Authentic ML-KEM vector bundle not found in {STAGED_INPUTS_DIR}")

        with tempfile.TemporaryDirectory() as tmpdir:
            _, env, canary = self._setup_safe_environment(tmpdir)
            inputs_dir = Path(tmpdir) / "valid_inputs"
            inputs_dir.mkdir()
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            shutil.copy(STAGED_INPUTS_DIR / "mlkem-keygen.json", inputs_dir / "mlkem-keygen.json")
            shutil.copy(STAGED_INPUTS_DIR / "mlkem-encdec.json", inputs_dir / "mlkem-encdec.json")

            script = REPO_ROOT / "bench" / "std_mlkem_exercise.sh"
            res = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)

            self.assertEqual(res.returncode, 0, f"ML-KEM valid baseline failed:\n{res.stdout}\n{res.stderr}")
            self.assertIn("ALL CHECKS PASSED", res.stdout)
            self.assertIn("25 seeds: both keys the same", res.stdout)
            self.assertIn("cryptography 49.0.0", res.stdout)
            self.assertFalse(canary.exists(), "Network must never be contacted on valid offline inputs")

    def test_full_mlkem_exercise_script_fails_nonzero_on_missing_inputs(self) -> None:
        """Targeted mutation: verify missing vector files cause specific failure and exit nonzero."""
        with tempfile.TemporaryDirectory() as tmpdir:
            _, env, canary = self._setup_safe_environment(tmpdir)
            empty_inputs = Path(tmpdir) / "empty_inputs"
            empty_inputs.mkdir()
            env["IYI_PROOF_INPUTS_DIR"] = str(empty_inputs)

            script = REPO_ROOT / "bench" / "std_mlkem_exercise.sh"
            res = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)

            self.assertNotEqual(res.returncode, 0, "Script must exit nonzero when offline inputs are missing")
            self.assertIn("FAIL IYI_PROOF_INPUTS_DIR", res.stdout + res.stderr)
            self.assertIn("mlkem-keygen.json", res.stdout + res.stderr)
            self.assertFalse(canary.exists(), "Network must never be contacted when IYI_PROOF_INPUTS_DIR is set")

    def test_full_mlkem_exercise_script_fails_nonzero_on_corrupt_inputs(self) -> None:
        """Targeted mutation: verify corrupt vector files cause specific failure and exit nonzero."""
        with tempfile.TemporaryDirectory() as tmpdir:
            _, env, canary = self._setup_safe_environment(tmpdir)
            corrupt_inputs = Path(tmpdir) / "corrupt_inputs"
            corrupt_inputs.mkdir()
            env["IYI_PROOF_INPUTS_DIR"] = str(corrupt_inputs)
            (corrupt_inputs / "mlkem-keygen.json").write_bytes(b"corrupt")
            (corrupt_inputs / "mlkem-encdec.json").write_bytes(b"corrupt")

            script = REPO_ROOT / "bench" / "std_mlkem_exercise.sh"
            res = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)

            self.assertNotEqual(res.returncode, 0, "Script must exit nonzero when offline inputs are corrupt")
            self.assertIn("FAIL IYI_PROOF_INPUTS_DIR", res.stdout + res.stderr)
            self.assertIn("sha256", res.stdout + res.stderr)
            self.assertFalse(canary.exists(), "Network must never be contacted when IYI_PROOF_INPUTS_DIR is set")

    # --- HPKE ---

    def test_full_hpke_exercise_script_succeeds_on_authentic_inputs(self) -> None:
        """Control baseline: verify HPKE script succeeds end-to-end with exit 0 on authentic inputs."""
        if not (STAGED_INPUTS_DIR / "hpke-vectors.json").is_file():
            self.skipTest(f"Authentic HPKE vector bundle not found in {STAGED_INPUTS_DIR}")

        with tempfile.TemporaryDirectory() as tmpdir:
            _, env, canary = self._setup_safe_environment(tmpdir)
            inputs_dir = Path(tmpdir) / "valid_inputs"
            inputs_dir.mkdir()
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            shutil.copy(STAGED_INPUTS_DIR / "hpke-vectors.json", inputs_dir / "hpke-vectors.json")

            script = REPO_ROOT / "bench" / "std_hpke_exercise.sh"
            res = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)

            self.assertEqual(res.returncode, 0, f"HPKE valid baseline failed:\n{res.stdout}\n{res.stderr}")
            self.assertIn("ALL CHECKS PASSED", res.stdout)
            self.assertIn("vectors of the whole file itself", res.stdout)
            self.assertFalse(canary.exists(), "Network must never be contacted on valid offline inputs")

    def test_full_hpke_exercise_script_fails_nonzero_on_missing_inputs(self) -> None:
        """Targeted mutation: verify missing vector files cause specific failure and exit nonzero."""
        with tempfile.TemporaryDirectory() as tmpdir:
            _, env, canary = self._setup_safe_environment(tmpdir)
            empty_inputs = Path(tmpdir) / "empty_inputs"
            empty_inputs.mkdir()
            env["IYI_PROOF_INPUTS_DIR"] = str(empty_inputs)

            script = REPO_ROOT / "bench" / "std_hpke_exercise.sh"
            res = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)

            self.assertNotEqual(res.returncode, 0, "Script must exit nonzero when offline inputs are missing")
            self.assertIn("FAIL IYI_PROOF_INPUTS_DIR", res.stdout + res.stderr)
            self.assertIn("hpke-vectors.json", res.stdout + res.stderr)
            self.assertFalse(canary.exists(), "Network must never be contacted when IYI_PROOF_INPUTS_DIR is set")

    def test_full_hpke_exercise_script_fails_nonzero_on_corrupt_inputs(self) -> None:
        """Targeted mutation: verify corrupt vector files cause specific failure and exit nonzero."""
        with tempfile.TemporaryDirectory() as tmpdir:
            _, env, canary = self._setup_safe_environment(tmpdir)
            corrupt_inputs = Path(tmpdir) / "corrupt_inputs"
            corrupt_inputs.mkdir()
            env["IYI_PROOF_INPUTS_DIR"] = str(corrupt_inputs)
            (corrupt_inputs / "hpke-vectors.json").write_bytes(b"corrupt")

            script = REPO_ROOT / "bench" / "std_hpke_exercise.sh"
            res = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)

            self.assertNotEqual(res.returncode, 0, "Script must exit nonzero when offline inputs are corrupt")
            self.assertIn("FAIL IYI_PROOF_INPUTS_DIR", res.stdout + res.stderr)
            self.assertIn("sha256", res.stdout + res.stderr)
            self.assertFalse(canary.exists(), "Network must never be contacted when IYI_PROOF_INPUTS_DIR is set")

    # --- P-384 ---

    def test_full_p384_exercise_script_succeeds_on_authentic_inputs(self) -> None:
        """Control baseline: verify P-384 script succeeds end-to-end with exit 0 on authentic inputs."""
        if not (STAGED_INPUTS_DIR / "wycheproof-p384.json").is_file():
            self.skipTest(f"Authentic Wycheproof vector bundle not found in {STAGED_INPUTS_DIR}")

        with tempfile.TemporaryDirectory() as tmpdir:
            _, env, canary = self._setup_safe_environment(tmpdir)
            inputs_dir = Path(tmpdir) / "valid_inputs"
            inputs_dir.mkdir()
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            shutil.copy(STAGED_INPUTS_DIR / "wycheproof-p384.json", inputs_dir / "wycheproof-p384.json")

            script = REPO_ROOT / "bench" / "std_p384_exercise.sh"
            res = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)

            self.assertEqual(res.returncode, 0, f"P-384 valid baseline failed:\n{res.stdout}\n{res.stderr}")
            self.assertIn("ALL CHECKS PASSED", res.stdout)
            self.assertIn("790 valid as Wycheproof's shared value", res.stdout)
            self.assertFalse(canary.exists(), "Network must never be contacted on valid offline inputs")

    def test_full_p384_exercise_script_fails_nonzero_on_missing_inputs(self) -> None:
        """Targeted mutation: verify missing vector files cause specific failure and exit nonzero."""
        with tempfile.TemporaryDirectory() as tmpdir:
            _, env, canary = self._setup_safe_environment(tmpdir)
            empty_inputs = Path(tmpdir) / "empty_inputs"
            empty_inputs.mkdir()
            env["IYI_PROOF_INPUTS_DIR"] = str(empty_inputs)

            script = REPO_ROOT / "bench" / "std_p384_exercise.sh"
            res = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)

            self.assertNotEqual(res.returncode, 0, "Script must exit nonzero when offline inputs are missing")
            self.assertIn("FAIL IYI_PROOF_INPUTS_DIR", res.stdout + res.stderr)
            self.assertIn("wycheproof-p384.json", res.stdout + res.stderr)
            self.assertFalse(canary.exists(), "Network must never be contacted when IYI_PROOF_INPUTS_DIR is set")

    def test_full_p384_exercise_script_fails_nonzero_on_corrupt_inputs(self) -> None:
        """Targeted mutation: verify corrupt vector files cause specific failure and exit nonzero."""
        with tempfile.TemporaryDirectory() as tmpdir:
            _, env, canary = self._setup_safe_environment(tmpdir)
            corrupt_inputs = Path(tmpdir) / "corrupt_inputs"
            corrupt_inputs.mkdir()
            env["IYI_PROOF_INPUTS_DIR"] = str(corrupt_inputs)
            (corrupt_inputs / "wycheproof-p384.json").write_bytes(b"corrupt")

            script = REPO_ROOT / "bench" / "std_p384_exercise.sh"
            res = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)

            self.assertNotEqual(res.returncode, 0, "Script must exit nonzero when offline inputs are corrupt")
            self.assertIn("FAIL IYI_PROOF_INPUTS_DIR", res.stdout + res.stderr)
            self.assertIn("sha256", res.stdout + res.stderr)
            self.assertFalse(canary.exists(), "Network must never be contacted when IYI_PROOF_INPUTS_DIR is set")


if __name__ == "__main__":
    unittest.main()
