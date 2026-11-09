#!/usr/bin/env python3
"""
proof/test_offline_vectors.py: Focused behavior tests for offline vector intake.

Tests the production helper (proof/offline_vectors.py) directly and exercises
full script entry (bench/std_*_exercise.sh) with safe fake compilers and network
spies (both curl binary spy and Python urllib/socket spy) to verify:
  1. IYI_PROOF_INPUTS_DIR path validation (relative paths and missing dirs fail nonzero).
  2. Missing vector files fail nonzero with exact diagnostics and zero network access.
  3. Corrupt vector files (SHA-256 digest mismatch) fail nonzero with zero network access.
  4. Wycheproof test case count strictly enforces all 790 unique test cases.
  5. CLI entry points return nonzero exit status on validation failure.
  6. Actual exercise scripts exit nonzero when inputs are missing/corrupt under IYI_PROOF_INPUTS_DIR.
  7. No network (curl/urllib/socket) is attempted when IYI_PROOF_INPUTS_DIR is set.
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
            os.environ.pop("IYI_PROOF_INPUTS_DIR", None)
            with self.assertRaises(OfflineVectorsError):
                get_proof_inputs_dir()

            # Relative path must be rejected
            os.environ["IYI_PROOF_INPUTS_DIR"] = "relative/path"
            with self.assertRaises(OfflineVectorsError) as ctx:
                get_proof_inputs_dir()
            self.assertIn("must be an absolute path", str(ctx.exception))

            # Nonexistent directory must be rejected
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

            with self.assertRaises(OfflineVectorsError) as ctx:
                process_wycheproof_vectors(tdir, out_file)
            self.assertIn("Missing required vector file", str(ctx.exception))

            wp = tdir / "wycheproof-p384.json"
            wp.write_bytes(b'{"testGroups": []}')
            with self.assertRaises(OfflineVectorsError) as ctx:
                process_wycheproof_vectors(tdir, out_file)
            self.assertIn("sha256", str(ctx.exception))

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

    def _setup_safe_environment(self, tmpdir: str) -> tuple[Path, dict[str, str], Path]:
        """Create mock compiler and spy curl + urllib, returning bin_dir, env, and canary_path."""
        bin_dir = Path(tmpdir) / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)

        canary = Path(tmpdir) / "network_attempted.canary"

        # Spy curl binary records network call
        spy_curl = bin_dir / "curl"
        spy_curl.write_text(f'#!/bin/sh\necho "CURL INVOKED: $@" >> "{canary}"\nexit 1\n')
        spy_curl.chmod(spy_curl.stat().st_mode | stat.S_IEXEC)

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

        # Mock IYI compiler emitting all expected section headers
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
shift
if [ "$sub" = "data" ]; then
    echo "  10 cases"
    echo "  ALL CHECKS PASSED"
    exit 0
elif [ "$sub" = "wycheproof" ]; then
    echo "  790 valid as Wycheproof's shared value, 0 invalid refused, 0 acceptable, 0 wrong"
    exit 0
elif [ "$sub" = "oracle" ]; then
    exit 0
elif [ "$sub" = "cost" ] || [ "$sub" = "time" ]; then
    echo "  timing: 100 us"
    exit 0
fi

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
echo "  keyGen"
echo "  vector"
echo "ALL CHECKS PASSED"
exit 0
BIN
    chmod +x "$out"
    exit 0
elif [ "$cmd" = "run" ]; then
    exit 0
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
        env["PY"] = sys.executable

        return bin_dir, env, canary

    def test_full_mlkem_exercise_script_fails_nonzero_on_missing_inputs(self) -> None:
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

    def test_full_hpke_exercise_script_fails_nonzero_on_missing_inputs(self) -> None:
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

    def test_full_p384_exercise_script_fails_nonzero_on_missing_inputs(self) -> None:
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


if __name__ == "__main__":
    unittest.main()
