"""Evidence directory helpers for stale_equivalence gates (RG2, RG2a, RG2r).

Shared interface:
  IYI_PROOF_EVIDENCE_DIR: optional environment variable naming an absolute,
  existing, empty, caller-owned directory. When absent or empty, no evidence
  is persisted and gates run with standard default behavior.

Path layout:
  rg2/<selector>/
  rg2a/<selector>/
  rg2r/<probe>/

Files per leg:
  <leg>.stdout: raw unnormalized stdout bytes
  <leg>.stderr: raw unnormalized stderr bytes
  <leg>.exit: numeric exit code, or "TIMEOUT", or "-<sig>", or "LAUNCH_ERROR"
  <leg>.status: "EXIT:<rc>", "TIMEOUT:<timeout>", "SIGNAL:<sig>", "LAUNCH_ERROR:<err>"
  <leg>.timeout: explicit flag file present only when command timed out
  <leg>.signal: flag file present only when terminated by signal
  <leg>.error: error description file present only on launch error

Process-group and descendant management:
  Subprocesses are launched with start_new_session=True to establish a private
  process group. On timeout, SIGTERM is signaled to the entire process group,
  followed by SIGKILL after a grace period, and the process group leader is reaped.
  Descendants that decouple themselves by calling setsid() into a new session
  cannot be reached by process-group signaling and require container or PID-namespace
  containment by the hosted orchestrator.
"""

import os
import signal
import subprocess
import threading
import time

_mkdir_lock = threading.Lock()


def validate_evidence_root(env_var: str = "IYI_PROOF_EVIDENCE_DIR") -> str | None:
    """Validate and return absolute evidence root directory, or None if unset."""
    val = os.environ.get(env_var)
    if not val:
        return None
    if not os.path.isabs(val):
        raise ValueError(f"{env_var} must be an absolute path: {val!r}")
    if not os.path.exists(val):
        raise ValueError(f"{env_var} does not exist: {val!r}")
    if not os.path.isdir(val):
        raise ValueError(f"{env_var} is not a directory: {val!r}")
    if hasattr(os, "getuid"):
        st = os.stat(val)
        if st.st_uid != os.getuid():
            raise ValueError(
                f"{env_var} must be owned by current user ({os.getuid()}), found {st.st_uid}: {val!r}"
            )
    return os.path.abspath(val)


def safe_stage_dir(evidence_root: str | None, stage_name: str) -> str | None:
    """Create and return a stage directory (rg2, rg2a, rg2r) ensuring no traversal or overwrite."""
    if not evidence_root:
        return None
    stage_dir = os.path.abspath(os.path.join(evidence_root, stage_name))
    evidence_root_abs = os.path.abspath(evidence_root)
    if os.path.commonpath([evidence_root_abs, stage_dir]) != evidence_root_abs or stage_dir == evidence_root_abs:
        raise ValueError(f"Stage directory escapes evidence root: {stage_name!r}")
    if os.path.exists(stage_dir):
        raise FileExistsError(f"Stage directory already exists (overwrites forbidden): {stage_dir!r}")
    os.makedirs(stage_dir, exist_ok=False)
    return stage_dir


def safe_item_dir(stage_dir: str | None, item_name: str) -> str | None:
    """Create and return an item directory (selector or probe) ensuring no traversal or overwrite."""
    if not stage_dir:
        return None
    if not item_name or "\0" in item_name:
        raise ValueError(f"Invalid selector/probe name: {item_name!r}")
    norm = os.path.normpath(item_name)
    if os.path.isabs(norm) or norm.startswith("..") or norm == ".":
        raise ValueError(f"Path traversal detected in selector/probe: {item_name!r}")
    item_dir = os.path.abspath(os.path.join(stage_dir, norm))
    stage_dir_abs = os.path.abspath(stage_dir)
    if os.path.commonpath([stage_dir_abs, item_dir]) != stage_dir_abs or item_dir == stage_dir_abs:
        raise ValueError(f"Selector/probe escapes stage directory: {item_name!r}")
    with _mkdir_lock:
        if os.path.exists(item_dir):
            raise FileExistsError(f"Evidence directory already exists for {item_name!r}: {item_dir!r}")
        os.makedirs(item_dir, exist_ok=False)
    return item_dir


class ProcessOutput:
    def __init__(self, returncode: int, stdout: bytes, stderr: bytes):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def _kill_group(pgid: int) -> None:
    """Kill all owned descendants in the process group."""
    if hasattr(os, "killpg"):
        try:
            os.killpg(pgid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        time.sleep(0.1)
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    else:
        try:
            os.kill(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass


def execute_cmd(
    argv: list[str],
    *,
    env: dict[str, str] | None = None,
    cwd: str | None = None,
    timeout: float | None = None,
    item_dir: str | None = None,
    leg: str | None = None,
) -> ProcessOutput:
    """Run command, preserving raw streams and status in item_dir when provided."""
    if not item_dir or not leg:
        proc = subprocess.run(
            argv,
            env=env,
            cwd=cwd,
            capture_output=True,
            text=False,
            timeout=timeout,
        )
        return ProcessOutput(proc.returncode, proc.stdout, proc.stderr)

    stdout_path = os.path.join(item_dir, f"{leg}.stdout")
    stderr_path = os.path.join(item_dir, f"{leg}.stderr")
    exit_path = os.path.join(item_dir, f"{leg}.exit")
    status_path = os.path.join(item_dir, f"{leg}.status")
    timeout_path = os.path.join(item_dir, f"{leg}.timeout")
    signal_path = os.path.join(item_dir, f"{leg}.signal")
    error_path = os.path.join(item_dir, f"{leg}.error")

    # Overwrite protection
    for p in [stdout_path, stderr_path, exit_path, status_path]:
        if os.path.exists(p):
            raise FileExistsError(f"Evidence file already exists (overwrites forbidden): {p!r}")

    stdout_f = open(stdout_path, "xb")
    stderr_f = open(stderr_path, "xb")
    timed_out = False
    proc = None
    launch_err = None

    try:
        proc = subprocess.Popen(
            argv,
            env=env,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=stdout_f,
            stderr=stderr_f,
            start_new_session=True,
        )
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            timed_out = True
            _kill_group(proc.pid)
            proc.wait()
            raise exc
    except (OSError, ValueError) as err:
        if not timed_out:
            launch_err = err
        raise
    finally:
        stdout_f.flush()
        stderr_f.flush()
        stdout_f.close()
        stderr_f.close()

        # Distinguish launch error, signal, timeout, and actual numeric exit
        if timed_out:
            exit_str = "TIMEOUT"
            status_str = f"TIMEOUT:{timeout}"
            with open(timeout_path, "x", encoding="utf-8") as f:
                f.write(f"timeout after {timeout}s\n")
        elif launch_err is not None:
            exit_str = "LAUNCH_ERROR"
            status_str = f"LAUNCH_ERROR:{launch_err}"
            with open(error_path, "x", encoding="utf-8") as f:
                f.write(f"{launch_err}\n")
        elif proc is not None and proc.returncode is not None:
            if proc.returncode < 0:
                sig = -proc.returncode
                exit_str = str(proc.returncode)
                status_str = f"SIGNAL:{sig}"
                with open(signal_path, "x", encoding="utf-8") as f:
                    f.write(f"{sig}\n")
            else:
                exit_str = str(proc.returncode)
                status_str = f"EXIT:{proc.returncode}"
        else:
            exit_str = "1"
            status_str = "EXIT:1"

        with open(exit_path, "x", encoding="utf-8") as f:
            f.write(f"{exit_str}\n")
        with open(status_path, "x", encoding="utf-8") as f:
            f.write(f"{status_str}\n")

    with open(stdout_path, "rb") as f:
        out_bytes = f.read()
    with open(stderr_path, "rb") as f:
        err_bytes = f.read()

    rc = proc.returncode if (proc and proc.returncode is not None) else (124 if timed_out else 1)
    return ProcessOutput(rc, out_bytes, err_bytes)
