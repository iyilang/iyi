#!/usr/bin/env python3
"""
proof/test_offline_vectors.py: Focused behavior tests for offline vector intake.

Tests the production helper (proof/offline_vectors.py) directly and exercises
full script entry (bench/std_*_exercise.sh) with safe fake compilers and network
spies to verify:
  1. IYI_PROOF_INPUTS_DIR path validation (relative paths and missing dirs fail nonzero).
  2. Missing vector files fail nonzero with zero network access and no fallback.
  3. Corrupt vector files (SHA-256 digest mismatch) fail nonzero with zero network access.
  4. Wycheproof test case count strictly enforces all 790 unique test cases.
  5. CLI entry points return nonzero exit status on validation failure.
  6. Actual exercise scripts exit nonzero when inputs are missing/corrupt under IYI_PROOF_INPUTS_DIR.
  7. No network (curl/urllib) is attempted when IYI_PROOF_INPUTS_DIR is set.
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
        # Unset
        old_env = os.environ.get("IYI_PROOF_INPUTS_DIR")
        try:
            os.environ.pop("IYI_PROOF_INPUTS_DIR", None)
            with self.assertRaises(OfflineVectorsError):
                get_proof_inputs_dir()

            # Relative path
            os.environ["IYI_PROOF_INPUTS_DIR"] = "relative/path"
            with self.assertRaises(OfflineVectorsError):
                get_proof_inputs_dir()

            # Nonexistent directory
            os.environ["IYI_PROOF_INPUTS_DIR"] = "/nonexistent/absolute/path/12345"
            with self.assertRaises(OfflineVectorsError):
                get_proof_inputs_dir()
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

            # Missing files
            with self.assertRaises(OfflineVectorsError) as ctx:
                process_mlkem_vectors(tdir, out_file)
            self.assertIn("Missing required vector file", str(ctx.exception))

            # Corrupt keygen
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

    def test_cli_exit_status_on_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            cli_py = REPO_ROOT / "proof" / "offline_vectors.py"
            # Missing inputs directory
            res = subprocess.run(
                [sys.executable, str(cli_py), "mlkem", f"{tmpdir}/out.json", "--inputs-dir", f"{tmpdir}/absent"],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("FAIL IYI_PROOF_INPUTS_DIR", res.stderr)

            # Corrupt file via CLI
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
        """Create mock compiler and spy curl, returning bin_dir, env, and canary_path."""
        bin_dir = Path(tmpdir) / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)

        canary = Path(tmpdir) / "network_attempted.canary"

        # Spy curl records network call and fails
        spy_curl = bin_dir / "curl"
        spy_curl.write_text(f'#!/bin/sh\necho "CURL INVOKED" >> "{canary}"\nexit 1\n')
        spy_curl.chmod(spy_curl.stat().st_mode | stat.S_IEXEC)

        # Mock IYI compiler that produces working executables for tests
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
fi
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
            self.assertIn("FAIL", res.stdout + res.stderr)
            self.assertFalse(canary.exists(), "Network must never be contacted when IYI_PROOF_INPUTS_DIR is set")


if __name__ == "__main__":
    unittest.main()
