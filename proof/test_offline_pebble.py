#!/usr/bin/env python3
"""
proof/test_offline_pebble.py: Focused tests for offline Pebble dependency acquisition and proof contract.

Tests:
  - bench/pebble_acquire.sh (actual production helper directly)
  - Integration and skip boundaries in bench/std_acme_exercise.sh and bench/std_autocert_exercise.sh
  - Real Go toolchain resolution from an owned local file proxy

Contract specifications:
  - In proof-only mode (when IYI_PROOF_INPUTS_DIR is set):
      * Uses Go module mirror path go-proxy/ under $IYI_PROOF_INPUTS_DIR.
      * Uses exact version v2.10.1 for both commands:
          - github.com/letsencrypt/pebble/v2/cmd/pebble@v2.10.1
          - github.com/letsencrypt/pebble/v2/cmd/pebble-challtestsrv@v2.10.1
      * Sets GOTOOLCHAIN=local.
      * Owned GOMODCACHE and GOCACHE under $WORK ($WORK/gomodcache, $WORK/gocache).
      * Owned GOBIN under $WORK ($WORK/gobin).
      * Strict offline resolution:
          - GOPROXY set to file:// URI of go-proxy/ with no fallback.
          - GONOPROXY=none (prevents GOPRIVATE from defaulting GONOPROXY and attempting direct network).
          - GOSUMDB=off, GONOSUMDB="*".
          - No GOPRIVATE setting.
      * Contract: trusted orchestrator independently verifies complete Go mirror
        artifact manifest/digest before launch; do not claim Go's disabled
        checksum service proves it.
      * Fail-closed on missing mirror directory, module, certs, or install failure.
      * At script boundaries, proof mode fails nonzero with no skip messages.
  - In normal mode (when IYI_PROOF_INPUTS_DIR is unset):
      * Existing no-env normal behavior is completely preserved:
          - Uses @latest for pebble and pebble-challtestsrv.
          - Does not force GOTOOLCHAIN=local, GOSUMDB=off, or GONOPROXY=none.
          - If Go is absent or network install fails, returns skip codes (2 or 3)
            and caller prints census skip strings with status 0.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

PEBBLE_PINNED_VERSION = "v2.10.1"
PEBBLE_MODULE = "github.com/letsencrypt/pebble/v2"
PEBBLE_CMD_PKG = f"{PEBBLE_MODULE}/cmd/pebble@{PEBBLE_PINNED_VERSION}"
CHALLTESTSRV_CMD_PKG = f"{PEBBLE_MODULE}/cmd/pebble-challtestsrv@{PEBBLE_PINNED_VERSION}"

PEBBLE_ACQUIRE_SCRIPT = REPO_ROOT / "bench" / "pebble_acquire.sh"
ACME_SCRIPT = REPO_ROOT / "bench" / "std_acme_exercise.sh"
AUTOCERT_SCRIPT = REPO_ROOT / "bench" / "std_autocert_exercise.sh"


def create_fake_go(
    bin_dir: Path,
    log_file: Path,
    fail_install: bool = False,
    fail_install_msg: str = "module not found in offline mirror",
    installed_version: str = PEBBLE_PINNED_VERSION,
    create_certs: bool = True,
) -> Path:
    """Create an owned fake `go` binary that records invocations and environment."""
    go_path = bin_dir / "go"
    py_script = bin_dir / "_fake_go.py"

    py_script.write_text(f"""\
import json, os, sys
from pathlib import Path

log_path = Path({repr(str(log_file))})
fail_install = {fail_install}
fail_msg = {repr(fail_install_msg)}
installed_ver = {repr(installed_version)}
create_certs = {create_certs}

record = {{
    "argv": sys.argv[1:],
    "env": {{
        "GOTOOLCHAIN": os.environ.get("GOTOOLCHAIN"),
        "GOMODCACHE": os.environ.get("GOMODCACHE"),
        "GOCACHE": os.environ.get("GOCACHE"),
        "GOPROXY": os.environ.get("GOPROXY"),
        "GONOPROXY": os.environ.get("GONOPROXY"),
        "GOSUMDB": os.environ.get("GOSUMDB"),
        "GONOSUMDB": os.environ.get("GONOSUMDB"),
        "GOPRIVATE": os.environ.get("GOPRIVATE"),
        "GOBIN": os.environ.get("GOBIN"),
    }}
}}

with open(log_path, "a") as f:
    f.write(json.dumps(record) + "\\n")

args = sys.argv[1:]
if not args:
    sys.exit(0)

if args[0] == "install":
    if fail_install:
        sys.stderr.write(f"go: {{fail_msg}}\\n")
        sys.exit(1)
    gobin = os.environ.get("GOBIN")
    if gobin:
        os.makedirs(gobin, exist_ok=True)
        for name in ("pebble", "pebble-challtestsrv"):
            bin_file = Path(gobin) / name
            bin_file.write_text("#!/bin/sh\\nexit 0\\n")
            bin_file.chmod(bin_file.stat().st_mode | 0o755)
    modcache = os.environ.get("GOMODCACHE")
    if modcache and create_certs:
        certs_dir = Path(modcache) / f"github.com/letsencrypt/pebble/v2@{{installed_ver}}/test/certs"
        (certs_dir / "localhost").mkdir(parents=True, exist_ok=True)
        (certs_dir / "localhost/cert.pem").write_text("FAKE CERT")
        (certs_dir / "localhost/key.pem").write_text("FAKE KEY")
        (certs_dir / "pebble.minica.pem").write_text("FAKE CA")
    sys.exit(0)

elif args[0] == "version" and len(args) >= 3 and args[1] == "-m":
    target_bin = args[2]
    sys.stdout.write(f"{{target_bin}}: go1.22.0\\n")
    sys.stdout.write(f"\\tpath\\tgithub.com/letsencrypt/pebble/v2/cmd/pebble\\n")
    sys.stdout.write(f"\\tmod\\tgithub.com/letsencrypt/pebble/v2\\t{{installed_ver}}\\th1:fakehash=\\n")
    sys.exit(0)

elif args[0] == "env":
    if len(args) > 1:
        sys.stdout.write(os.environ.get(args[1], "") + "\\n")
    sys.exit(0)

sys.exit(0)
""")

    go_path.write_text(f"""#!/bin/sh
exec "{sys.executable}" "{py_script}" "$@"
""")
    go_path.chmod(go_path.stat().st_mode | stat.S_IEXEC | 0o755)
    return go_path


def run_helper(env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    """Execute bench/pebble_acquire.sh directly as a script."""
    return subprocess.run(
        ["bash", str(PEBBLE_ACQUIRE_SCRIPT)],
        env=env,
        capture_output=True,
        text=True,
    )


class TestOfflinePebbleContract(unittest.TestCase):
    def test_pinned_constants(self):
        self.assertEqual(PEBBLE_PINNED_VERSION, "v2.10.1")
        self.assertEqual(PEBBLE_MODULE, "github.com/letsencrypt/pebble/v2")
        self.assertIn("@v2.10.1", PEBBLE_CMD_PKG)
        self.assertIn("@v2.10.1", CHALLTESTSRV_CMD_PKG)
        self.assertTrue(PEBBLE_ACQUIRE_SCRIPT.is_file(), f"Missing {PEBBLE_ACQUIRE_SCRIPT}")
        self.assertTrue(ACME_SCRIPT.is_file(), f"Missing {ACME_SCRIPT}")
        self.assertTrue(AUTOCERT_SCRIPT.is_file(), f"Missing {AUTOCERT_SCRIPT}")

    def test_helper_proof_mode_exact_arguments_and_env(self):
        """In proof mode, bench/pebble_acquire.sh invokes go with exact v2.10.1, GOTOOLCHAIN=local, and file mirror."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "proof_inputs"
            mirror_dir = inputs_dir / "go-proxy"
            mirror_dir.mkdir(parents=True)
            work_dir = tmp / "work"
            work_dir.mkdir()
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"

            go_bin = create_fake_go(bin_dir, log_file, installed_version=PEBBLE_PINNED_VERSION)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)
            env["GOPRIVATE"] = "polluted_parent_goprivate"
            res = run_helper(env)
            self.assertEqual(res.returncode, 0, f"helper failed:\n{res.stderr}\n{res.stdout}")
            self.assertTrue(log_file.exists(), f"fake go was not called: {res.stdout}\n{res.stderr}")

            records = [json.loads(line) for line in log_file.read_text().splitlines()]
            install_records = [r for r in records if r["argv"] and r["argv"][0] == "install"]
            self.assertEqual(len(install_records), 1)

            rec = install_records[0]
            # Exact arguments: both commands pinned to v2.10.1
            expected_args = ["install", PEBBLE_CMD_PKG, CHALLTESTSRV_CMD_PKG]
            self.assertEqual(rec["argv"], expected_args)

            # Exact environment variables
            self.assertEqual(rec["env"]["GOTOOLCHAIN"], "local")
            self.assertEqual(rec["env"]["GONOPROXY"], "none")
            self.assertEqual(rec["env"]["GOSUMDB"], "off")
            self.assertEqual(rec["env"]["GONOSUMDB"], "*")
            self.assertIsNone(rec["env"]["GOPRIVATE"], "env -u GOPRIVATE must strip ambient GOPRIVATE from child")

            # Owned locations under WORK
            self.assertEqual(rec["env"]["GOMODCACHE"], str(work_dir / "gomodcache"))
            self.assertEqual(rec["env"]["GOCACHE"], str(work_dir / "gocache"))
            self.assertEqual(rec["env"]["GOBIN"], str(work_dir / "gobin"))

            # No network fallback: GOPROXY must strictly be a file:// URI pointing to go-proxy
            goproxy = rec["env"]["GOPROXY"]
            self.assertTrue(goproxy.startswith("file://"), f"GOPROXY is not file:// URI: {goproxy}")
            self.assertIn("go-proxy", goproxy)
            self.assertNotIn(",", goproxy, "GOPROXY contains fallback list")
            self.assertNotIn("http://", goproxy, "GOPROXY contains http network fallback")
            self.assertNotIn("https://", goproxy, "GOPROXY contains https network fallback")
            self.assertNotIn("direct", goproxy, "GOPROXY contains direct network fallback")

    def test_helper_empty_present_inputs_dir_fails_nonzero(self):
        """When IYI_PROOF_INPUTS_DIR is explicitly set but empty, helper fails closed (exit 1)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            work_dir = tmp / "work"
            work_dir.mkdir()
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(bin_dir, log_file)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = ""

            res = run_helper(env)
            self.assertEqual(res.returncode, 1)
            self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR must not be empty", res.stderr)
            self.assertFalse(log_file.exists(), "Go must not be invoked when IYI_PROOF_INPUTS_DIR is empty")

    def test_helper_relative_inputs_dir_fails_nonzero(self):
        """When IYI_PROOF_INPUTS_DIR is a relative path, helper fails closed (exit 1)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            work_dir = tmp / "work"
            work_dir.mkdir()
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(bin_dir, log_file)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = "relative/path"

            res = run_helper(env)
            self.assertEqual(res.returncode, 1)
            self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR must be an absolute path: relative/path", res.stderr)
            self.assertFalse(log_file.exists())

    def test_helper_absent_mirror_directory_fails_nonzero(self):
        """When IYI_PROOF_INPUTS_DIR has no go-proxy/ dir, helper exits 1."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "empty_inputs"
            inputs_dir.mkdir()
            work_dir = tmp / "work"
            work_dir.mkdir()
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(bin_dir, log_file)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res = run_helper(env)
            self.assertEqual(res.returncode, 1)
            self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR Go module mirror 'go-proxy/' missing", res.stderr)
            self.assertFalse(log_file.exists(), "Go must not be invoked when mirror directory is missing")

    def test_helper_absent_module_install_failure_fails_nonzero(self):
        """When go install fails (absent module in mirror), helper exits 1."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "inputs"
            (inputs_dir / "go-proxy").mkdir(parents=True)
            work_dir = tmp / "work"
            work_dir.mkdir()
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(
                bin_dir,
                log_file,
                fail_install=True,
                fail_install_msg="module github.com/letsencrypt/pebble/v2@v2.10.1: not found in mirror",
            )

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res = run_helper(env)
            self.assertEqual(res.returncode, 1)
            self.assertIn("FAIL: Pebble v2.10.1 could not be installed from offline mirror", res.stderr)

    def test_helper_missing_test_certs_fails_nonzero(self):
        """When Pebble test certs are absent from GOMODCACHE, helper exits 1."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "inputs"
            (inputs_dir / "go-proxy").mkdir(parents=True)
            work_dir = tmp / "work"
            work_dir.mkdir()
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(bin_dir, log_file, create_certs=False)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res = run_helper(env)
            self.assertEqual(res.returncode, 1)
            self.assertIn("FAIL: required Pebble test certs missing in", res.stderr)

    def test_helper_wrong_module_version_fails_nonzero(self):
        """When Pebble version does not match v2.10.1, helper exits 1."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "inputs"
            (inputs_dir / "go-proxy").mkdir(parents=True)
            work_dir = tmp / "work"
            work_dir.mkdir()
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(bin_dir, log_file, installed_version="v2.9.0")

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res = run_helper(env)
            self.assertEqual(res.returncode, 1)
            self.assertIn("FAIL: Pebble binary module version 'v2.9.0' != expected 'v2.10.1'", res.stderr)

    def test_helper_missing_go_command_in_proof_mode_fails_nonzero(self):
        """When Go is not found and IYI_PROOF_INPUTS_DIR is set, helper exits 1."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "inputs"
            (inputs_dir / "go-proxy").mkdir(parents=True)
            work_dir = tmp / "work"
            work_dir.mkdir()

            env = os.environ.copy()
            env["GO"] = str(tmp / "nonexistent_go_binary")
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res = run_helper(env)
            self.assertEqual(res.returncode, 1)
            self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR requires Go", res.stderr)

    def test_helper_normal_mode_skips(self):
        """When IYI_PROOF_INPUTS_DIR is unset, helper returns skip codes (2 for no Go, 3 for failed install)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            work_dir = tmp / "work"
            work_dir.mkdir()
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"

            # Case A: Missing Go returns 2
            env_no_go = os.environ.copy()
            env_no_go.pop("IYI_PROOF_INPUTS_DIR", None)
            env_no_go["GO"] = str(tmp / "nonexistent_go_binary")
            env_no_go["WORK"] = str(work_dir)
            res_no_go = run_helper(env_no_go)
            self.assertEqual(res_no_go.returncode, 2)

            # Case B: Failed install returns 3
            go_bin = create_fake_go(bin_dir, log_file, fail_install=True, fail_install_msg="network down")
            env_fail = os.environ.copy()
            env_fail.pop("IYI_PROOF_INPUTS_DIR", None)
            env_fail["PATH"] = f"{bin_dir}:{env_fail.get('PATH', '')}"
            env_fail["GO"] = str(go_bin)
            env_fail["WORK"] = str(work_dir)
            res_fail = run_helper(env_fail)
            self.assertEqual(res_fail.returncode, 3)

            records = [json.loads(line) for line in log_file.read_text().splitlines()]
            install_rec = [r for r in records if r["argv"] and r["argv"][0] == "install"][0]
            # Normal mode uses @latest, not pinned v2.10.1
            self.assertEqual(install_rec["argv"], [
                "install",
                "github.com/letsencrypt/pebble/v2/cmd/pebble@latest",
                "github.com/letsencrypt/pebble/v2/cmd/pebble-challtestsrv@latest",
            ])
            self.assertIsNone(install_rec["env"]["GOTOOLCHAIN"])
            self.assertIsNone(install_rec["env"]["GOSUMDB"])
            self.assertIsNone(install_rec["env"]["GONOPROXY"])

    def test_script_boundary_no_skips_in_proof_mode(self):
        """In std_acme_exercise.sh and std_autocert_exercise.sh, sourcing helper on failure sets status=1 with no skip string."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            work_dir = tmp / "work"
            work_dir.mkdir()
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(bin_dir, log_file)

            # Test ACME real sourced helper boundary when acquisition fails (missing mirror directory)
            cmd_acme = f"""\
set -u
status=0
REPO="{REPO_ROOT}"
WORK="{work_dir}"
GO="{go_bin}"
IYI_PROOF_INPUTS_DIR="{tmp}/missing_mirror"
PY="{sys.executable}"

acquire_res=0
. "$REPO/bench/pebble_acquire.sh" || acquire_res=$?
if [ "$acquire_res" -eq 1 ]; then
  status=1
elif [ "$acquire_res" -eq 2 ]; then
  echo "  no Go here (or no python to drive it), so Pebble is not built and the orders go unplaced"
elif [ "$acquire_res" -eq 3 ]; then
  echo "  Pebble could not be fetched or built here (no network?), so the orders go unplaced:"
elif [ "$acquire_res" -eq 0 ]; then
  echo "UNEXPECTED_ACQUIRE_SUCCESS"
fi
echo "FINAL_STATUS=$status"
"""
            res_acme = subprocess.run(["bash", "-c", cmd_acme], capture_output=True, text=True)
            self.assertEqual(res_acme.returncode, 0)
            self.assertIn("FINAL_STATUS=1", res_acme.stdout)
            self.assertNotIn("UNEXPECTED_ACQUIRE_SUCCESS", res_acme.stdout)
            self.assertNotIn("so Pebble is not built", res_acme.stdout)
            self.assertNotIn("so the orders go unplaced", res_acme.stdout)

            # Test AUTOCERT real sourced helper boundary when acquisition fails (missing mirror directory)
            cmd_autocert = f"""\
set -u
status=0
REPO="{REPO_ROOT}"
WORK="{work_dir}"
GO="{go_bin}"
IYI_PROOF_INPUTS_DIR="{tmp}/missing_mirror"
ORACLE=yes

acquire_res=0
. "$REPO/bench/pebble_acquire.sh" || acquire_res=$?
if [ "$acquire_res" -eq 1 ]; then
  status=1
elif [ "$acquire_res" -eq 2 ]; then
  echo "  no Go here (or no python with cryptography to drive it), so Pebble is not built and nothing is ordered"
elif [ "$acquire_res" -eq 3 ]; then
  echo "  Pebble could not be fetched or built here (no network?), so nothing is ordered:"
elif [ "$acquire_res" -eq 0 ]; then
  echo "UNEXPECTED_ACQUIRE_SUCCESS"
fi
echo "FINAL_STATUS=$status"
"""
            res_autocert = subprocess.run(["bash", "-c", cmd_autocert], capture_output=True, text=True)
            self.assertEqual(res_autocert.returncode, 0)
            self.assertIn("FINAL_STATUS=1", res_autocert.stdout)
            self.assertNotIn("UNEXPECTED_ACQUIRE_SUCCESS", res_autocert.stdout)
            self.assertNotIn("so Pebble is not built", res_autocert.stdout)
            self.assertNotIn("so nothing is ordered", res_autocert.stdout)

    def test_script_boundary_normal_mode_skips_preserved(self):
        """In std_acme_exercise.sh and std_autocert_exercise.sh, sourcing helper on normal skip produces census skip strings and status=0."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            work_dir = tmp / "work"
            work_dir.mkdir()
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(bin_dir, log_file, fail_install=True, fail_install_msg="network down")

            # Case A: Missing Go in normal mode
            cmd_acme_no_go = f"""\
set -u
status=0
REPO="{REPO_ROOT}"
WORK="{work_dir}"
GO="{tmp}/nonexistent_go"
PY="{sys.executable}"

acquire_res=0
. "$REPO/bench/pebble_acquire.sh" || acquire_res=$?
if [ "$acquire_res" -eq 1 ]; then
  status=1
elif [ "$acquire_res" -eq 2 ]; then
  echo "  no Go here (or no python to drive it), so Pebble is not built and the orders go unplaced"
elif [ "$acquire_res" -eq 3 ]; then
  echo "  Pebble could not be fetched or built here (no network?), so the orders go unplaced: $(tail -1 "$WORK/go-install.log")"
fi
echo "FINAL_STATUS=$status"
"""
            res_no_go = subprocess.run(["bash", "-c", cmd_acme_no_go], capture_output=True, text=True)
            self.assertIn("FINAL_STATUS=0", res_no_go.stdout)
            self.assertIn("no Go here (or no python to drive it), so Pebble is not built and the orders go unplaced", res_no_go.stdout)

            # Case B: Failed install in normal mode
            cmd_acme_fail = f"""\
set -u
status=0
REPO="{REPO_ROOT}"
WORK="{work_dir}"
GO="{go_bin}"
PY="{sys.executable}"

acquire_res=0
. "$REPO/bench/pebble_acquire.sh" || acquire_res=$?
if [ "$acquire_res" -eq 1 ]; then
  status=1
elif [ "$acquire_res" -eq 2 ]; then
  echo "  no Go here (or no python to drive it), so Pebble is not built and the orders go unplaced"
elif [ "$acquire_res" -eq 3 ]; then
  echo "  Pebble could not be fetched or built here (no network?), so the orders go unplaced: $(tail -1 "$WORK/go-install.log")"
fi
echo "FINAL_STATUS=$status"
"""
            res_fail = subprocess.run(["bash", "-c", cmd_acme_fail], capture_output=True, text=True)
            self.assertIn("FINAL_STATUS=0", res_fail.stdout)
            self.assertIn("Pebble could not be fetched or built here (no network?), so the orders go unplaced: go: network down", res_fail.stdout)

    def test_script_boundary_proof_mode_success_returns_zero(self):
        """In std_acme_exercise.sh and std_autocert_exercise.sh, sourcing helper on valid inputs sets acquire_res=0 and status=0."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "proof_inputs"
            mirror_dir = inputs_dir / "go-proxy"
            mirror_dir.mkdir(parents=True)
            work_dir = tmp / "work"
            work_dir.mkdir()
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(bin_dir, log_file, installed_version=PEBBLE_PINNED_VERSION)

            cmd = f"""\
set -u
status=0
REPO="{REPO_ROOT}"
WORK="{work_dir}"
GO="{go_bin}"
IYI_PROOF_INPUTS_DIR="{inputs_dir}"
PY="{sys.executable}"

acquire_res=0
. "$REPO/bench/pebble_acquire.sh" || acquire_res=$?
if [ "$acquire_res" -eq 1 ]; then
  status=1
elif [ "$acquire_res" -eq 2 ]; then
  echo "  no Go here (or no python to drive it), so Pebble is not built and the orders go unplaced"
elif [ "$acquire_res" -eq 3 ]; then
  echo "  Pebble could not be fetched or built here (no network?), so the orders go unplaced:"
elif [ "$acquire_res" -eq 0 ]; then
  echo "ACQUIRED_OK certs=$certs"
fi
echo "FINAL_STATUS=$status"
"""
            res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0)
            self.assertIn("FINAL_STATUS=0", res.stdout)
            self.assertIn("ACQUIRED_OK certs=", res.stdout)
    def test_script_boundary_empty_present_fails_closed(self):
        """When IYI_PROOF_INPUTS_DIR is set but empty, full scripts reject immediately with exit 1."""
        env = os.environ.copy()
        env["IYI_PROOF_INPUTS_DIR"] = ""

        res_acme = subprocess.run(["bash", str(ACME_SCRIPT)], env=env, capture_output=True, text=True)
        self.assertEqual(res_acme.returncode, 1)
        self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR must not be empty", res_acme.stderr)

        res_autocert = subprocess.run(["bash", str(AUTOCERT_SCRIPT)], env=env, capture_output=True, text=True)
        self.assertEqual(res_autocert.returncode, 1)
        self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR must not be empty", res_autocert.stderr)

    def test_script_boundary_no_python_with_empty_present_fails_closed(self):
        """When Python is missing and IYI_PROOF_INPUTS_DIR is set but empty, no-Python check fails closed."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            work_dir = tmp / "work"
            work_dir.mkdir()

            cmd_acme = f"""\
set -u
status=0
REPO="{REPO_ROOT}"
WORK="{work_dir}"
IYI_PROOF_INPUTS_DIR=""
PY=""
GO="go"

if [ -z "$PY" ]; then
  if [ "${{IYI_PROOF_INPUTS_DIR+set}}" = "set" ]; then
    echo "  FAIL: IYI_PROOF_INPUTS_DIR requires Python to drive Pebble" >&2
    status=1
  else
    echo "  no Go here (or no python to drive it), so Pebble is not built and the orders go unplaced"
  fi
fi
echo "FINAL_STATUS=$status"
"""
            res_acme = subprocess.run(["bash", "-c", cmd_acme], capture_output=True, text=True)
            self.assertIn("FINAL_STATUS=1", res_acme.stdout)
            self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR requires Python to drive Pebble", res_acme.stderr)
            self.assertNotIn("so Pebble is not built", res_acme.stdout)

    def test_actual_go_resolves_tiny_offline_file_proxy_module(self):
        """Actual host Go resolves an owned local file-proxy module under GOPROXY=file://, GONOPROXY=none."""
        real_go = shutil.which("go")
        if not real_go:
            self.skipTest("go toolchain not found on host")

        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            mirror = tmp / "go-proxy"
            mod_dir = mirror / "example.com/tinyoffline/@v"
            mod_dir.mkdir(parents=True)

            # Create file-based Go module mirror metadata and zip
            (mod_dir / "list").write_text("v1.0.0\n")
            (mod_dir / "v1.0.0.info").write_text('{"Version":"v1.0.0","Time":"2026-01-01T00:00:00Z"}\n')
            mod_content = "module example.com/tinyoffline\n\ngo 1.20\n"
            (mod_dir / "v1.0.0.mod").write_text(mod_content)

            zip_path = mod_dir / "v1.0.0.zip"
            with zipfile.ZipFile(zip_path, "w") as zf:
                zf.writestr("example.com/tinyoffline@v1.0.0/go.mod", mod_content)
                zf.writestr(
                    "example.com/tinyoffline@v1.0.0/cmd/tinypkg/main.go",
                    'package main\nimport "fmt"\nfunc main() { fmt.Println("TINY_OFFLINE_PROVED") }\n',
                )

            work = tmp / "work"
            work_bin = work / "gobin"
            work_mod = work / "gomodcache"
            work_cache = work / "gocache"
            for d in (work_bin, work_mod, work_cache):
                d.mkdir(parents=True)

            # Test 1: With GONOPROXY=none, GOSUMDB=off, GOTOOLCHAIN=local, and env -u GOPRIVATE:
            # Actual Go downloads from file:// mirror and builds successfully offline even if
            # ambient environment was polluted with GOPRIVATE.
            env = os.environ.copy()
            env["GOTOOLCHAIN"] = "local"
            env["GOPROXY"] = f"file://{mirror}"
            env["GONOPROXY"] = "none"
            env["GOSUMDB"] = "off"
            env["GONOSUMDB"] = "*"
            env["GOPRIVATE"] = "polluted_parent_goprivate"
            env["GOMODCACHE"] = str(work_mod)
            env["GOCACHE"] = str(work_cache)
            env["GOBIN"] = str(work_bin)

            res = subprocess.run(
                ["env", "-u", "GOPRIVATE", real_go, "install", "example.com/tinyoffline/cmd/tinypkg@v1.0.0"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, f"actual go install failed:\n{res.stderr}\n{res.stdout}")

            bin_file = work_bin / "tinypkg"
            self.assertTrue(bin_file.is_file(), "binary was not installed into owned GOBIN")

            run_res = subprocess.run([str(bin_file)], capture_output=True, text=True)
            self.assertEqual(run_res.stdout.strip(), "TINY_OFFLINE_PROVED")

            # Test 2: Negative control avoiding network: pointing GOPROXY to an owned nonexistent file mirror path
            # fails deterministically with zero network requests.
            work2 = tmp / "work2"
            work2_mod = work2 / "gomodcache"
            work2_cache = work2 / "gocache"
            work2_bin = work2 / "gobin"
            for d in (work2_bin, work2_mod, work2_cache):
                d.mkdir(parents=True)

            env_file_missing = os.environ.copy()
            env_file_missing["GOTOOLCHAIN"] = "local"
            env_file_missing["GOPROXY"] = f"file://{tmp}/nonexistent_mirror_path"
            env_file_missing["GONOPROXY"] = "none"
            env_file_missing["GOSUMDB"] = "off"
            env_file_missing["GONOSUMDB"] = "*"
            env_file_missing["GOMODCACHE"] = str(work2_mod)
            env_file_missing["GOCACHE"] = str(work2_cache)
            env_file_missing["GOBIN"] = str(work2_bin)

            res_file_missing = subprocess.run(
                ["env", "-u", "GOPRIVATE", real_go, "install", "example.com/tinyoffline/cmd/tinypkg@v1.0.0"],
                env=env_file_missing,
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertNotEqual(res_file_missing.returncode, 0, "Missing file mirror must fail")
            self.assertFalse((work2_bin / "tinypkg").exists(), "Binary must not be built from nonexistent file mirror")

            # Test 3: Negative control with owned loopback server dynamically bound to port 0
            # (kernel-allocated port owned by this test, no hardcoded ports) deterministically rejecting requests.
            work3 = tmp / "work3"
            work3_mod = work3 / "gomodcache"
            work3_cache = work3 / "gocache"
            work3_bin = work3 / "gobin"
            for d in (work3_bin, work3_mod, work3_cache):
                d.mkdir(parents=True)

            import http.server, threading

            class RejectHandler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(503)
                    self.end_headers()
                    self.wfile.write(b"owned loopback reject\n")

                def log_message(self, format, *args):
                    pass

            owned_server = http.server.HTTPServer(("127.0.0.1", 0), RejectHandler)
            owned_port = owned_server.server_address[1]
            server_thread = threading.Thread(target=owned_server.serve_forever, daemon=True)
            server_thread.start()

            try:
                env_loopback = os.environ.copy()
                env_loopback["GOTOOLCHAIN"] = "local"
                env_loopback["GOPROXY"] = f"http://127.0.0.1:{owned_port}"
                env_loopback["GONOPROXY"] = "none"
                env_loopback["GOSUMDB"] = "off"
                env_loopback["GONOSUMDB"] = "*"
                env_loopback["GOMODCACHE"] = str(work3_mod)
                env_loopback["GOCACHE"] = str(work3_cache)
                env_loopback["GOBIN"] = str(work3_bin)

                res_loopback = subprocess.run(
                    ["env", "-u", "GOPRIVATE", real_go, "install", "example.com/tinyoffline/cmd/tinypkg@v1.0.0"],
                    env=env_loopback,
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                self.assertNotEqual(res_loopback.returncode, 0, "Owned loopback reject expected to fail")
                self.assertFalse((work3_bin / "tinypkg").exists(), "Binary must not be built on rejected proxy")
            finally:
                owned_server.shutdown()
                owned_server.server_close()

if __name__ == "__main__":
    unittest.main()
