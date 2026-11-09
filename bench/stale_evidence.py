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
  <leg>.stdout: raw unnormalized stdout bytes (streamed incrementally and flushed)
  <leg>.stderr: raw unnormalized stderr bytes (streamed incrementally and flushed)
  <leg>.exit: numeric exit code, or "TIMEOUT", or "-<sig>", or "LAUNCH_ERROR", or "IO_ERROR", or "UNRESOLVED_WRITERS", or "CANCELLED"
  <leg>.status: "EXIT:<rc>", "TIMEOUT:<timeout>", "SIGNAL:<sig>", "LAUNCH_ERROR:<err>", "IO_ERROR:<err>", "UNRESOLVED_WRITERS", "CANCELLED"
  <leg>.timeout: explicit flag file present only when command timed out
  <leg>.signal: flag file present only when terminated by signal
  <leg>.error: error description file present on launch error or pump write/fsync failure
  <leg>.cancelled: flag file present only when command was cancelled
  <leg>.unresolved: flag file present when unclosed descendant writers exceed deadline

Integration contract (Path B):
  - Helper runs commands as direct children without creating unanchored private sessions (start_new_session=False).
  - Helper never signals arbitrary or recycled numeric PGIDs; on timeout it signals only the direct unreaped child PID via proc.kill().
  - Pipe readers tee raw bytes incrementally to exclusive on-disk files while streaming to memory, flushing and fsyncing each chunk immediately so partial output survives runner death before cleanup.
  - Fail-closed guarantees:
      * Any pump I/O failure (write, flush, or fsync) forces non-zero returncode (1) and records IO_ERROR.
      * Any timeout forces non-zero returncode and records TIMEOUT with explicit .timeout flag file.
      * Any unclosed descendant writers past the command's allocated deadline force non-zero returncode (1) and record UNRESOLVED_WRITERS with explicit .unresolved flag file (marked on timeout and normal exit alike).
      * Normal writers are never truncated at arbitrary cutoffs; draining runs until stream EOF budgeted against the command's total allocated timeout.
  - Explicit unproven boundary: whole-stage process group ownership, guardian parent-death watchdog, and stage cancellation are owned by the outer hosted orchestrator and remain unproven locally until verified in that environment.
"""

import os
import subprocess
import threading
import time

_mkdir_lock = threading.Lock()


def validate_evidence_root(env_var: str = "IYI_PROOF_EVIDENCE_DIR") -> str | None:
    """Validate and return physical absolute evidence root directory, or None if unset."""
    val = os.environ.get(env_var)
    if not val:
        return None
    if not os.path.isabs(val):
        raise ValueError(f"{env_var} must be an absolute path: {val!r}")
    # Resolve physical path to eliminate symlink/.. lexical mismatches
    physical = os.path.realpath(val)
    if not os.path.exists(physical):
        raise ValueError(f"{env_var} does not exist: {val!r}")
    if not os.path.isdir(physical):
        raise ValueError(f"{env_var} is not a directory: {val!r}")
    if hasattr(os, "getuid"):
        st = os.stat(physical)
        if st.st_uid != os.getuid():
            raise ValueError(
                f"{env_var} must be owned by current user ({os.getuid()}), found {st.st_uid}: {val!r}"
            )
    return physical


def safe_stage_dir(evidence_root: str | None, stage_name: str) -> str | None:
    """Create and return a stage directory (rg2, rg2a, rg2r) ensuring no traversal or overwrite."""
    if not evidence_root:
        return None
    stage_dir = os.path.realpath(os.path.join(evidence_root, stage_name))
    evidence_root_real = os.path.realpath(evidence_root)
    if (
        os.path.commonpath([evidence_root_real, stage_dir]) != evidence_root_real
        or stage_dir == evidence_root_real
    ):
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
    stage_dir_real = os.path.realpath(stage_dir)
    # Check lexical containment
    if os.path.commonpath([stage_dir, item_dir]) != stage_dir or item_dir == stage_dir:
        raise ValueError(f"Selector/probe escapes stage directory: {item_name!r}")
    with _mkdir_lock:
        if os.path.exists(item_dir):
            raise FileExistsError(f"Evidence directory already exists for {item_name!r}: {item_dir!r}")
        os.makedirs(item_dir, exist_ok=False)
        # Check physical containment after directory creation
        item_dir_real = os.path.realpath(item_dir)
        if (
            os.path.commonpath([stage_dir_real, item_dir_real]) != stage_dir_real
            or item_dir_real == stage_dir_real
        ):
            os.rmdir(item_dir)
            raise ValueError(f"Selector/probe physically escapes stage directory: {item_name!r}")
    return item_dir


class ProcessOutput:
    def __init__(self, returncode: int, stdout: bytes, stderr: bytes):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def _pump_pipe(stream, file_handle, memory_buffer: bytearray, error_box: list[Exception]) -> None:
    """Stream chunks from pipe to file handle (immediately flushed/synced) and memory buffer."""
    fd = stream.fileno()
    try:
        while True:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            try:
                file_handle.write(chunk)
                file_handle.flush()
                try:
                    os.fsync(file_handle.fileno())
                except (OSError, ValueError) as sync_err:
                    error_box.append(sync_err)
                    break
            except (OSError, ValueError) as write_err:
                error_box.append(write_err)
                break
            memory_buffer.extend(chunk)
    except (OSError, ValueError) as read_err:
        if not stream.closed:
            error_box.append(read_err)


def execute_cmd(
    argv: list[str],
    *,
    env: dict[str, str] | None = None,
    cwd: str | None = None,
    timeout: float | None = None,
    item_dir: str | None = None,
    leg: str | None = None,
) -> ProcessOutput:
    """Run command, preserving raw streams and status in item_dir incrementally."""
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
    cancelled_path = os.path.join(item_dir, f"{leg}.cancelled")
    unresolved_path = os.path.join(item_dir, f"{leg}.unresolved")

    # Overwrite protection
    for p in [stdout_path, stderr_path, exit_path, status_path]:
        if os.path.exists(p):
            raise FileExistsError(f"Evidence file already exists (overwrites forbidden): {p!r}")

    # Open evidence files immediately so partial bytes are written incrementally
    stdout_f = open(stdout_path, "xb")
    stderr_f = open(stderr_path, "xb")

    raw_out = bytearray()
    raw_err = bytearray()
    error_box_out: list[Exception] = []
    error_box_err: list[Exception] = []
    timed_out = False
    cancelled = False
    unresolved = False
    proc = None
    launch_err = None
    deadline = (time.time() + timeout) if timeout else None

    try:
        # Path B: Direct child; stdin=None inherits stdin identically to standard subprocess.run
        proc = subprocess.Popen(
            argv,
            env=env,
            cwd=cwd,
            stdin=None,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        t_out = threading.Thread(
            target=_pump_pipe, args=(proc.stdout, stdout_f, raw_out, error_box_out), daemon=True
        )
        t_err = threading.Thread(
            target=_pump_pipe, args=(proc.stderr, stderr_f, raw_err, error_box_err), daemon=True
        )
        t_out.start()
        t_err.start()

        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            timed_out = True
            # Race-free: signals direct live unreaped child PID
            proc.kill()
            proc.wait()
            t_out.join(timeout=0.5)
            t_err.join(timeout=0.5)
            if t_out.is_alive() or t_err.is_alive():
                unresolved = True
            raise exc
        except (KeyboardInterrupt, SystemExit) as exc:
            cancelled = True
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            t_out.join(timeout=0.5)
            t_err.join(timeout=0.5)
            if t_out.is_alive() or t_err.is_alive():
                unresolved = True
            raise exc
        else:
            # Drain streams without arbitrary truncation, budgeted against total command deadline
            rem = max(0.0, deadline - time.time()) if deadline else 30.0
            t_out.join(timeout=rem)
            t_err.join(timeout=rem)
            if t_out.is_alive() or t_err.is_alive():
                unresolved = True
    except (OSError, ValueError) as err:
        if not timed_out and not cancelled:
            launch_err = err
        raise
    finally:
        stdout_f.close()
        stderr_f.close()

        pump_errors = error_box_out + error_box_err

        # Sidecar flag files:
        if timed_out:
            with open(timeout_path, "x", encoding="utf-8") as f:
                f.write(f"timeout after {timeout}s\n")
        if cancelled:
            with open(cancelled_path, "x", encoding="utf-8") as f:
                f.write("gate cancelled\n")
        if unresolved:
            with open(unresolved_path, "x", encoding="utf-8") as f:
                f.write("streams unclosed at deadline; unresolved ownership for hosted supervisor\n")

        # Determine exit_str, status_str, and rc (fail-closed priority)
        if pump_errors:
            io_err = pump_errors[0]
            exit_str = "IO_ERROR"
            status_str = f"IO_ERROR:{io_err}"
            with open(error_path, "x", encoding="utf-8") as f:
                f.write(f"IO_ERROR: {io_err}\n")
            rc = 1
        elif launch_err is not None:
            exit_str = "LAUNCH_ERROR"
            status_str = f"LAUNCH_ERROR:{launch_err}"
            with open(error_path, "x", encoding="utf-8") as f:
                f.write(f"{launch_err}\n")
            rc = 1
        elif unresolved and not timed_out and not cancelled:
            exit_str = "UNRESOLVED_WRITERS"
            status_str = "UNRESOLVED_WRITERS"
            rc = 1
        elif timed_out:
            exit_str = "TIMEOUT"
            status_str = (
                f"UNRESOLVED_WRITERS:TIMEOUT:{timeout}"
                if unresolved
                else f"TIMEOUT:{timeout}"
            )
            rc = 124
        elif cancelled:
            exit_str = "CANCELLED"
            status_str = (
                "UNRESOLVED_WRITERS:CANCELLED"
                if unresolved
                else "CANCELLED"
            )
            rc = 1
        elif proc is not None and proc.returncode is not None:
            if proc.returncode < 0:
                sig = -proc.returncode
                exit_str = str(proc.returncode)
                status_str = f"SIGNAL:{sig}"
                with open(signal_path, "x", encoding="utf-8") as f:
                    f.write(f"{sig}\n")
                rc = proc.returncode
            else:
                exit_str = str(proc.returncode)
                status_str = f"EXIT:{proc.returncode}"
                rc = proc.returncode
        else:
            exit_str = "1"
            status_str = "EXIT:1"
            rc = 1

        with open(exit_path, "x", encoding="utf-8") as f:
            f.write(f"{exit_str}\n")
        with open(status_path, "x", encoding="utf-8") as f:
            f.write(f"{status_str}\n")

    return ProcessOutput(rc, bytes(raw_out), bytes(raw_err))
