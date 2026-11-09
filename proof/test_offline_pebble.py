#!/usr/bin/env python3
"""
proof/test_offline_pebble.py: Focused tests for offline proof-only Pebble ACME test server inputs.

Tests the offline Go module mirror contract across:
  - bench/std_acme_exercise.sh
  - bench/std_autocert_exercise.sh

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
          - GOSUMDB=off, GONOSUMDB="*", GOPRIVATE="*".
      * Contract: trusted orchestrator independently verifies complete Go mirror
        artifact manifest/digest before launch; do not claim Go's disabled
        checksum service proves it.
      * Fail nonzero on missing module, certs, or install:
          - Missing go-proxy/ directory fails nonzero.
          - Missing Go or Python in proof mode fails nonzero.
          - go install failure fails nonzero.
          - Missing or wrong module version (!= v2.10.1) fails nonzero.
          - Missing test certs fails nonzero.
          - Absent Pebble in proof mode fails mutations nonzero without skip strings.
  - In normal mode (when IYI_PROOF_INPUTS_DIR is unset):
      * Existing no-env normal behavior is completely preserved:
          - Uses @latest for pebble and pebble-challtestsrv.
          - Does not force GOTOOLCHAIN=local or GOSUMDB=off.
          - If Go is absent or network install fails, outputs census skip strings
            and does not fail the exercise (status remains 0).
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
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

PEBBLE_PINNED_VERSION = "v2.10.1"
PEBBLE_MODULE = "github.com/letsencrypt/pebble/v2"
PEBBLE_CMD_PKG = f"{PEBBLE_MODULE}/cmd/pebble@{PEBBLE_PINNED_VERSION}"
CHALLTESTSRV_CMD_PKG = f"{PEBBLE_MODULE}/cmd/pebble-challtestsrv@{PEBBLE_PINNED_VERSION}"


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
        certs_dir = Path(modcache) / f"github.com/letsencrypt/pebble/v2@{installed_ver}/test/certs"
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


def run_acme_pebble_block(
    env: dict[str, str],
    script_path: Path = REPO_ROOT / "bench" / "std_acme_exercise.sh",
) -> subprocess.CompletedProcess[str]:
    """Run the Pebble installation and configuration section of std_acme_exercise.sh."""
    # Extract lines between the Pebble section header and the next section (doc/format)
    # and execute them in a standalone subshell with provided environment.
    bash_cmd = f"""\
set -u
status=0
REPO="{REPO_ROOT}"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac
source <(sed -n "/== whole orders against Let's Encrypt's Pebble/,/== doc, format/p" "{script_path}" | sed '1d;$d')
echo "FINAL_STATUS=$status"
"""
    return subprocess.run(
        ["bash", "-c", bash_cmd],
        env=env,
        capture_output=True,
        text=True,
    )


def run_autocert_pebble_block(
    env: dict[str, str],
    script_path: Path = REPO_ROOT / "bench" / "std_autocert_exercise.sh",
) -> subprocess.CompletedProcess[str]:
    """Run the Pebble installation and configuration section of std_autocert_exercise.sh."""
    bash_cmd = f"""\
set -u
status=0
REPO="{REPO_ROOT}"
ORACLE=yes
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac
source <(sed -n "/== certificates from Let's Encrypt's Pebble/,/== doc, format/p" "{script_path}" | sed '1d;$d')
echo "FINAL_STATUS=$status"
echo "FINAL_PEBBLE=$PEBBLE"
"""
    return subprocess.run(
        ["bash", "-c", bash_cmd],
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

    def test_acme_proof_mode_exact_arguments_and_env(self):
        """In proof mode, std_acme_exercise.sh invokes go with exact v2.10.1, GOTOOLCHAIN=local, and file mirror."""
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
            env["PY"] = sys.executable
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res = run_acme_pebble_block(env)
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
            self.assertEqual(rec["env"]["GOSUMDB"], "off")
            self.assertEqual(rec["env"]["GONOSUMDB"], "*")
            self.assertEqual(rec["env"]["GOPRIVATE"], "*")

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

    def test_autocert_proof_mode_exact_arguments_and_env(self):
        """In proof mode, std_autocert_exercise.sh invokes go with exact v2.10.1, GOTOOLCHAIN=local, and file mirror."""
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
            env["PY"] = sys.executable
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res = run_autocert_pebble_block(env)
            self.assertTrue(log_file.exists(), f"fake go was not called: {res.stdout}\n{res.stderr}")

            records = [json.loads(line) for line in log_file.read_text().splitlines()]
            install_records = [r for r in records if r["argv"] and r["argv"][0] == "install"]
            self.assertEqual(len(install_records), 1)

            rec = install_records[0]
            expected_args = ["install", PEBBLE_CMD_PKG, CHALLTESTSRV_CMD_PKG]
            self.assertEqual(rec["argv"], expected_args)

            self.assertEqual(rec["env"]["GOTOOLCHAIN"], "local")
            self.assertEqual(rec["env"]["GOSUMDB"], "off")
            self.assertEqual(rec["env"]["GONOSUMDB"], "*")
            self.assertEqual(rec["env"]["GOPRIVATE"], "*")
            self.assertEqual(rec["env"]["GOMODCACHE"], str(work_dir / "gomodcache"))
            self.assertEqual(rec["env"]["GOCACHE"], str(work_dir / "gocache"))
            self.assertEqual(rec["env"]["GOBIN"], str(work_dir / "gobin"))

            goproxy = rec["env"]["GOPROXY"]
            self.assertTrue(goproxy.startswith("file://"))
            self.assertIn("go-proxy", goproxy)
            self.assertNotIn(",", goproxy)
            self.assertNotIn("http://", goproxy)
            self.assertNotIn("https://", goproxy)
            self.assertNotIn("direct", goproxy)

    def test_absent_mirror_directory_fails_nonzero(self):
        """When IYI_PROOF_INPUTS_DIR has no go-proxy/ dir, both scripts fail nonzero."""
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
            env["PY"] = sys.executable
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res_acme = run_acme_pebble_block(env)
            self.assertIn("FINAL_STATUS=1", res_acme.stdout)
            self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR Go module mirror 'go-proxy/' missing", res_acme.stderr)
            self.assertFalse(log_file.exists(), "Go must not be invoked when mirror directory is missing")

            res_autocert = run_autocert_pebble_block(env)
            self.assertIn("FINAL_STATUS=1", res_autocert.stdout)
            self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR Go module mirror 'go-proxy/' missing", res_autocert.stderr)

    def test_absent_module_install_failure_fails_nonzero(self):
        """When go install fails (absent module in mirror), both scripts fail nonzero."""
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
            env["PY"] = sys.executable
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res_acme = run_acme_pebble_block(env)
            self.assertIn("FINAL_STATUS=1", res_acme.stdout)
            self.assertIn("FAIL: Pebble v2.10.1 could not be installed from offline mirror", res_acme.stderr)

            res_autocert = run_autocert_pebble_block(env)
            self.assertIn("FINAL_STATUS=1", res_autocert.stdout)
            self.assertIn("FAIL: Pebble v2.10.1 could not be installed from offline mirror", res_autocert.stderr)

    def test_missing_test_certs_fails_nonzero(self):
        """When Pebble test certs are absent from GOMODCACHE, both scripts fail nonzero."""
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
            env["PY"] = sys.executable
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res_acme = run_acme_pebble_block(env)
            self.assertIn("FINAL_STATUS=1", res_acme.stdout)
            self.assertIn("FAIL: required Pebble test certs missing in", res_acme.stderr)

            res_autocert = run_autocert_pebble_block(env)
            self.assertIn("FINAL_STATUS=1", res_autocert.stdout)
            self.assertIn("FAIL: required Pebble test certs missing in", res_autocert.stderr)

    def test_wrong_module_version_fails_nonzero(self):
        """When Pebble version does not match v2.10.1, both scripts fail nonzero."""
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
            env["PY"] = sys.executable
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res_acme = run_acme_pebble_block(env)
            self.assertIn("FINAL_STATUS=1", res_acme.stdout)
            self.assertIn("FAIL: Pebble binary module version 'v2.9.0' != expected 'v2.10.1'", res_acme.stderr)

            res_autocert = run_autocert_pebble_block(env)
            self.assertIn("FINAL_STATUS=1", res_autocert.stdout)
            self.assertIn("FAIL: Pebble binary module version 'v2.9.0' != expected 'v2.10.1'", res_autocert.stderr)

    def test_missing_go_command_in_proof_mode_fails_nonzero(self):
        """When Go is not found and IYI_PROOF_INPUTS_DIR is set, scripts fail nonzero (not skip)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            inputs_dir = tmp / "inputs"
            (inputs_dir / "go-proxy").mkdir(parents=True)
            work_dir = tmp / "work"
            work_dir.mkdir()

            env = os.environ.copy()
            env["GO"] = str(tmp / "nonexistent_go_binary")
            env["PY"] = sys.executable
            env["WORK"] = str(work_dir)
            env["IYI_PROOF_INPUTS_DIR"] = str(inputs_dir)

            res_acme = run_acme_pebble_block(env)
            self.assertIn("FINAL_STATUS=1", res_acme.stdout)
            self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR requires Go", res_acme.stderr)

            res_autocert = run_autocert_pebble_block(env)
            self.assertIn("FINAL_STATUS=1", res_autocert.stdout)
            self.assertIn("FAIL: IYI_PROOF_INPUTS_DIR requires Go", res_autocert.stderr)

    def test_normal_mode_unchanged_on_missing_go(self):
        """When IYI_PROOF_INPUTS_DIR is unset, missing Go preserves normal census skip string and status=0."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            work_dir = tmp / "work"
            work_dir.mkdir()

            env = os.environ.copy()
            env.pop("IYI_PROOF_INPUTS_DIR", None)
            env["GO"] = str(tmp / "nonexistent_go_binary")
            env["PY"] = sys.executable
            env["WORK"] = str(work_dir)

            res_acme = run_acme_pebble_block(env)
            self.assertIn("FINAL_STATUS=0", res_acme.stdout)
            self.assertIn("no Go here (or no python to drive it), so Pebble is not built and the orders go unplaced", res_acme.stdout)

            res_autocert = run_autocert_pebble_block(env)
            self.assertIn("FINAL_STATUS=0", res_autocert.stdout)
            self.assertIn("no Go here (or no python with cryptography to drive it), so Pebble is not built and nothing is ordered", res_autocert.stdout)

    def test_normal_mode_unchanged_on_failed_install(self):
        """When IYI_PROOF_INPUTS_DIR is unset, failed go install preserves normal skip and status=0."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            work_dir = tmp / "work"
            work_dir.mkdir()
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log_file = tmp / "go.log"
            go_bin = create_fake_go(bin_dir, log_file, fail_install=True, fail_install_msg="network down")

            env = os.environ.copy()
            env.pop("IYI_PROOF_INPUTS_DIR", None)
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["GO"] = str(go_bin)
            env["PY"] = sys.executable
            env["WORK"] = str(work_dir)

            res_acme = run_acme_pebble_block(env)
            self.assertIn("FINAL_STATUS=0", res_acme.stdout)
            self.assertIn("Pebble could not be fetched or built here (no network?), so the orders go unplaced: go: network down", res_acme.stdout)

            records = [json.loads(line) for line in log_file.read_text().splitlines()]
            install_rec = [r for r in records if r["argv"] and r["argv"][0] == "install"][0]
            # Normal mode uses @latest, not pinned v2.10.1
            self.assertEqual(install_rec["argv"], [
                "install",
                "github.com/letsencrypt/pebble/v2/cmd/pebble@latest",
                "github.com/letsencrypt/pebble/v2/cmd/pebble-challtestsrv@latest",
            ])
            # Normal mode does not force GOTOOLCHAIN=local or GOSUMDB=off
            self.assertIsNone(install_rec["env"]["GOTOOLCHAIN"])
            self.assertIsNone(install_rec["env"]["GOSUMDB"])

            log_file.unlink()
            res_autocert = run_autocert_pebble_block(env)
            self.assertIn("FINAL_STATUS=0", res_autocert.stdout)
            self.assertIn("Pebble could not be fetched or built here (no network?), so nothing is ordered: go: network down", res_autocert.stdout)


if __name__ == "__main__":
    unittest.main()
