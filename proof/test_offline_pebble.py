#!/usr/bin/env python3
"""
proof/test_offline_pebble.py: Focused tests for offline proof-only Pebble ACME test server inputs.

Tests the offline Go module mirror contract across:
  - bench/std_acme_exercise.sh (real script execution)
  - bench/std_autocert_exercise.sh (real script execution)
  - Real Go toolchain offline module resolution proof

Contract specifications:
  - In proof-only mode (when IYI_PROOF_INPUTS_DIR is set):
      * Uses Go module mirror path go-proxy/ under $IYI_PROOF_INPUTS_DIR.
      * Uses exact version v2.10.1 for both commands:
          - github.com/letsencrypt/pebble/v2/cmd/pebble@v2.10.1
          - github.com/letsencrypt/pebble/v2/cmd/pebble-challtestsrv@v2.10.1
      * Sets GOTOOLCHAIN=local.
      * Owned GOMODCACHE and GOCACHE under $WORK (e.g. $WORK/gomodcache, $WORK/gocache).
      * Owned GOBIN under $WORK ($WORK/gobin).
      * Never network or fallback:
          - GOPROXY set to file:// URI of go-proxy/ with no fallback (,direct or remote).
          - GONOPROXY=none (crucial: prevents GOPRIVATE from bypassing file mirror to direct network).
          - GOSUMDB=off, GONOSUMDB="*".
      * Contract: trusted orchestrator independently verifies complete Go mirror
        artifact manifest/digest before launch; do not claim Go's disabled
        checksum service proves it.
      * Fail nonzero on missing module, certs, or install:
          - Missing go-proxy/ directory fails nonzero.
          - Missing Go in proof mode fails nonzero.
          - go install failure fails nonzero.
          - Missing or wrong module version (!= v2.10.1) fails nonzero.
          - Missing test certs fails nonzero.
  - In normal mode (when IYI_PROOF_INPUTS_DIR is unset):
      * Existing no-env normal behavior is completely preserved:
          - Uses @latest for pebble and pebble-challtestsrv.
          - Does not force GOTOOLCHAIN=local or GOSUMDB=off or GONOPROXY=none.
          - If Go is absent or network install fails, outputs census skip strings
            and does not fail the exercise (status remains 0).
  - Real path verification:
      * Tests execute the actual bash script files on disk, never sliced strings.
      * Proves actual Go binary resolves from an owned local file-proxy module with
        network disabled.
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

ACME_SCRIPT = REPO_ROOT / "bench" / "std_acme_exercise.sh"
AUTOCERT_SCRIPT = REPO_ROOT / "bench" / "std_autocert_exercise.sh"


def create_fake_go(
    bin_dir: Path,
    log_file: Path,
    fail_install: bool = False,
    fail_install_msg: str = "module not found in offline mirror",
    installed_version: str = PEBBLE_PINNED_VERSION,
    create_certs: bool = True,
    stop_after_install: bool = False,
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
stop_after_install = {stop_after_install}

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
    if stop_after_install:
        # Stop cleanly so subsequent server launches are skipped in tests inspecting flags
        sys.stderr.write("install recorded\\n")
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


def run_real_script(
    script_path: Path,
    env: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    """Execute the real script directly without slicing source strings."""
    # Ensure PEBBLE_ONLY=1 is set so Pebble lifecycle and flags are tested
    # on the real script path without requiring full compiler compilation.
    run_env = env.copy()
    run_env["PEBBLE_ONLY"] = "1"
    return subprocess.run(
        ["bash", str(script_path)],
        env=run_env,
        capture_output=True,
        text=True,
    )


class TestOfflinePebbleContract(unittest.TestCase):
    def test_pinned_constants(self):
        self.assertEqual(PEBBLE_PINNED_VERSION, "v2.10.1")
        self.assertEqual(PEBBLE_MODULE, "github.com/letsencrypt/pebble/v2")
        self.assertIn("@v2.10.1", PEBBLE_CMD_PKG)
        self.assertIn("@v2.10.1", CHALLTESTSRV_CMD_PKG)
        self.assertTrue(ACME_SCRIPT.is_file(), f"Missing {ACME_SCRIPT}")
        self.assertTrue(AUTOCERT_SCRIPT.is_file(), f"Missing {AUTOCERT_SCRIPT}")

    def test_acme_proof_mode_exact_arguments_and_env(self):
        """In proof mode, real std_acme_exercise.sh invokes go with exact v2.10.1, GOTOOLCHAIN=local, and file mirror."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "proof_inputs"
            mirror_dir = inputs_dir / "go-proxy"
            mirror_dir.mkdir(parents=True)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"

            go_bin = create_fake_go(bin_dir, log_file, installed_version=PEBBLE_PINNED_VERSION, stop_after_install=True)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["PY"] = sys.executable
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res = run_real_script(ACME_SCRIPT, env)
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
            self.assertIsNone(rec["env"]["GOPRIVATE"], "GOPRIVATE must not be set")

            # Owned locations under WORK
            self.assertTrue(rec["env"]["GOMODCACHE"].endswith("/gomodcache"))
            self.assertTrue(rec["env"]["GOCACHE"].endswith("/gocache"))
            self.assertTrue(rec["env"]["GOBIN"].endswith("/gobin"))

            # No network fallback: GOPROXY must strictly be a file:// URI pointing to go-proxy
            goproxy = rec["env"]["GOPROXY"]
            self.assertTrue(goproxy.startswith("file://"), f"GOPROXY is not file:// URI: {goproxy}")
            self.assertIn("go-proxy", goproxy)
            self.assertNotIn(",", goproxy, "GOPROXY contains fallback list")
            self.assertNotIn("http://", goproxy, "GOPROXY contains http network fallback")
            self.assertNotIn("https://", goproxy, "GOPROXY contains https network fallback")
            self.assertNotIn("direct", goproxy, "GOPROXY contains direct network fallback")

    def test_autocert_proof_mode_exact_arguments_and_env(self):
        """In proof mode, real std_autocert_exercise.sh invokes go with exact v2.10.1, GOTOOLCHAIN=local, and file mirror."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "proof_inputs"
            mirror_dir = inputs_dir / "go-proxy"
            mirror_dir.mkdir(parents=True)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"

            go_bin = create_fake_go(bin_dir, log_file, installed_version=PEBBLE_PINNED_VERSION, stop_after_install=True)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["PY"] = sys.executable
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res = run_real_script(AUTOCERT_SCRIPT, env)
            self.assertTrue(log_file.exists(), f"fake go was not called: {res.stdout}\n{res.stderr}")

            records = [json.loads(line) for line in log_file.read_text().splitlines()]
            install_records = [r for r in records if r["argv"] and r["argv"][0] == "install"]
            self.assertEqual(len(install_records), 1)

            rec = install_records[0]
            expected_args = ["install", PEBBLE_CMD_PKG, CHALLTESTSRV_CMD_PKG]
            self.assertEqual(rec["argv"], expected_args)

            self.assertEqual(rec["env"]["GOTOOLCHAIN"], "local")
            self.assertEqual(rec["env"]["GONOPROXY"], "none")
            self.assertEqual(rec["env"]["GOSUMDB"], "off")
            self.assertEqual(rec["env"]["GONOSUMDB"], "*")
            self.assertIsNone(rec["env"]["GOPRIVATE"])
            self.assertTrue(rec["env"]["GOMODCACHE"].endswith("/gomodcache"))
            self.assertTrue(rec["env"]["GOCACHE"].endswith("/gocache"))
            self.assertTrue(rec["env"]["GOBIN"].endswith("/gobin"))

            goproxy = rec["env"]["GOPROXY"]
            self.assertTrue(goproxy.startswith("file://"))
            self.assertIn("go-proxy", goproxy)
            self.assertNotIn(",", goproxy)
            self.assertNotIn("http://", goproxy)
            self.assertNotIn("https://", goproxy)
            self.assertNotIn("direct", goproxy)

    def test_absent_mirror_directory_fails_nonzero(self):
        """When IYI_PROOF_INPUTS_DIR has no go-proxy/ dir, real scripts fail nonzero."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "empty_inputs"
            inputs_dir.mkdir()
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(bin_dir, log_file)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["PY"] = sys.executable
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res_acme = run_real_script(ACME_SCRIPT, env)
            self.assertEqual(res_acme.returncode, 1)
            self.assertIn("the std/acme exercise did not hold", res_acme.stdout)
            self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR Go module mirror 'go-proxy/' missing", res_acme.stderr)
            self.assertFalse(log_file.exists(), "Go must not be invoked when mirror directory is missing")

            res_autocert = run_real_script(AUTOCERT_SCRIPT, env)
            self.assertEqual(res_autocert.returncode, 1)
            self.assertIn("the std/autocert exercise did not hold", res_autocert.stdout)
            self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR Go module mirror 'go-proxy/' missing", res_autocert.stderr)

    def test_absent_module_install_failure_fails_nonzero(self):
        """When go install fails (absent module in mirror), real scripts fail nonzero."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "inputs"
            (inputs_dir / "go-proxy").mkdir(parents=True)
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
            env["PY"] = sys.executable
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res_acme = run_real_script(ACME_SCRIPT, env)
            self.assertEqual(res_acme.returncode, 1)
            self.assertIn("the std/acme exercise did not hold", res_acme.stdout)
            self.assertIn("FAIL: Pebble v2.10.1 could not be installed from offline mirror", res_acme.stderr)

            res_autocert = run_real_script(AUTOCERT_SCRIPT, env)
            self.assertEqual(res_autocert.returncode, 1)
            self.assertIn("the std/autocert exercise did not hold", res_autocert.stdout)
            self.assertIn("FAIL: Pebble v2.10.1 could not be installed from offline mirror", res_autocert.stderr)

    def test_missing_test_certs_fails_nonzero(self):
        """When Pebble test certs are absent from GOMODCACHE, real scripts fail nonzero."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "inputs"
            (inputs_dir / "go-proxy").mkdir(parents=True)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(bin_dir, log_file, create_certs=False)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["PY"] = sys.executable
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res_acme = run_real_script(ACME_SCRIPT, env)
            self.assertEqual(res_acme.returncode, 1)
            self.assertIn("the std/acme exercise did not hold", res_acme.stdout)
            self.assertIn("FAIL: required Pebble test certs missing in", res_acme.stderr)

            res_autocert = run_real_script(AUTOCERT_SCRIPT, env)
            self.assertEqual(res_autocert.returncode, 1)
            self.assertIn("the std/autocert exercise did not hold", res_autocert.stdout)
            self.assertIn("FAIL: required Pebble test certs missing in", res_autocert.stderr)

    def test_wrong_module_version_fails_nonzero(self):
        """When Pebble version does not match v2.10.1, real scripts fail nonzero."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "inputs"
            (inputs_dir / "go-proxy").mkdir(parents=True)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(bin_dir, log_file, installed_version="v2.9.0")

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["PY"] = sys.executable
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res_acme = run_real_script(ACME_SCRIPT, env)
            self.assertEqual(res_acme.returncode, 1)
            self.assertIn("the std/acme exercise did not hold", res_acme.stdout)
            self.assertIn("FAIL: Pebble binary module version 'v2.9.0' != expected 'v2.10.1'", res_acme.stderr)

            res_autocert = run_real_script(AUTOCERT_SCRIPT, env)
            self.assertEqual(res_autocert.returncode, 1)
            self.assertIn("the std/autocert exercise did not hold", res_autocert.stdout)
            self.assertIn("FAIL: Pebble binary module version 'v2.9.0' != expected 'v2.10.1'", res_autocert.stderr)

    def test_missing_go_command_in_proof_mode_fails_nonzero(self):
        """When Go is not found and IYI_PROOF_INPUTS_DIR is set, real scripts fail nonzero (not skip)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "inputs"
            (inputs_dir / "go-proxy").mkdir(parents=True)

            env = os.environ.copy()
            env["GO"] = str(tmp / "nonexistent_go_binary")
            env["PY"] = sys.executable
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res_acme = run_real_script(ACME_SCRIPT, env)
            self.assertEqual(res_acme.returncode, 1)
            self.assertIn("the std/acme exercise did not hold", res_acme.stdout)
            self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR requires Go", res_acme.stderr)

            res_autocert = run_real_script(AUTOCERT_SCRIPT, env)
            self.assertEqual(res_autocert.returncode, 1)
            self.assertIn("the std/autocert exercise did not hold", res_autocert.stdout)
            self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR requires Go", res_autocert.stderr)

    def test_normal_mode_unchanged_on_missing_go(self):
        """When IYI_PROOF_INPUTS_DIR is unset, missing Go preserves normal census skip string and status=0."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)

            env = os.environ.copy()
            env.pop("IYI_PROOF_INPUTS_DIR", None)
            env["GO"] = str(tmp / "nonexistent_go_binary")
            env["PY"] = sys.executable

            res_acme = run_real_script(ACME_SCRIPT, env)
            self.assertEqual(res_acme.returncode, 0)
            self.assertIn("the std/acme pebble exercise holds", res_acme.stdout)
            self.assertIn("no Go here (or no python to drive it), so Pebble is not built and the orders go unplaced", res_acme.stdout)

            res_autocert = run_real_script(AUTOCERT_SCRIPT, env)
            self.assertEqual(res_autocert.returncode, 0)
            self.assertIn("the std/autocert pebble exercise holds", res_autocert.stdout)
            self.assertIn("no Go here (or no python with cryptography to drive it), so Pebble is not built and nothing is ordered", res_autocert.stdout)

    def test_normal_mode_unchanged_on_failed_install(self):
        """When IYI_PROOF_INPUTS_DIR is unset, failed go install preserves normal skip and status=0."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(bin_dir, log_file, fail_install=True, fail_install_msg="network down")

            env = os.environ.copy()
            env.pop("IYI_PROOF_INPUTS_DIR", None)
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["PY"] = sys.executable

            res_acme = run_real_script(ACME_SCRIPT, env)
            self.assertEqual(res_acme.returncode, 0)
            self.assertIn("the std/acme pebble exercise holds", res_acme.stdout)
            self.assertIn("Pebble could not be fetched or built here (no network?), so the orders go unplaced: go: network down", res_acme.stdout)

            records = [json.loads(line) for line in log_file.read_text().splitlines()]
            install_rec = [r for r in records if r["argv"] and r["argv"][0] == "install"][0]
            # Normal mode uses @latest, not pinned v2.10.1
            self.assertEqual(install_rec["argv"], [
                "install",
                "github.com/letsencrypt/pebble/v2/cmd/pebble@latest",
                "github.com/letsencrypt/pebble/v2/cmd/pebble-challtestsrv@latest",
            ])
            # Normal mode does not force GOTOOLCHAIN=local, GOSUMDB=off, or GONOPROXY=none
            self.assertIsNone(install_rec["env"]["GOTOOLCHAIN"])
            self.assertIsNone(install_rec["env"]["GOSUMDB"])
            self.assertIsNone(install_rec["env"]["GONOPROXY"])

            log_file.unlink()
            res_autocert = run_real_script(AUTOCERT_SCRIPT, env)
            self.assertEqual(res_autocert.returncode, 0)
            self.assertIn("the std/autocert pebble exercise holds", res_autocert.stdout)
            self.assertIn("Pebble could not be fetched or built here (no network?), so nothing is ordered: go: network down", res_autocert.stdout)

    def test_actual_go_resolves_tiny_offline_file_proxy_module(self):
        """Proof using actual Go command: resolves an owned local file-proxy module with network disabled."""
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

            # Test 1: With GONOPROXY=none, GOSUMDB=off, GOTOOLCHAIN=local, no GOPRIVATE:
            # Actual Go downloads from file:// mirror and builds successfully offline.
            env = os.environ.copy()
            env["GOTOOLCHAIN"] = "local"
            env["GOPROXY"] = f"file://{mirror}"
            env["GONOPROXY"] = "none"
            env["GOSUMDB"] = "off"
            env["GONOSUMDB"] = "*"
            env.pop("GOPRIVATE", None)
            env["GOMODCACHE"] = str(work_mod)
            env["GOCACHE"] = str(work_cache)
            env["GOBIN"] = str(work_bin)

            res = subprocess.run(
                [real_go, "install", "example.com/tinyoffline/cmd/tinypkg@v1.0.0"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, f"actual go install failed:\n{res.stderr}\n{res.stdout}")

            bin_file = work_bin / "tinypkg"
            self.assertTrue(bin_file.is_file(), "binary was not installed into owned GOBIN")

            run_res = subprocess.run([str(bin_file)], capture_output=True, text=True)
            self.assertEqual(run_res.stdout.strip(), "TINY_OFFLINE_PROVED")

            # Test 2: Prove that setting GOPRIVATE=* without GONOPROXY=none WOULD attempt network:
            # GONOPROXY defaults to GOPRIVATE, bypassing GOPROXY and failing with direct network lookup.
            env_bad = env.copy()
            env_bad["GOPRIVATE"] = "*"
            env_bad.pop("GONOPROXY", None)

            res_bad = subprocess.run(
                [real_go, "install", "example.com/tinyoffline/cmd/tinypkg@v1.0.0"],
                env=env_bad,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res_bad.returncode, 0, "GOPRIVATE=* without GONOPROXY=none unexpectedly succeeded")
            self.assertTrue(
                "unrecognized import path" in res_bad.stderr or "reading https://" in res_bad.stderr,
                f"Expected network lookup failure with GOPRIVATE=*, got: {res_bad.stderr}",
            )


if __name__ == "__main__":
    unittest.main()
