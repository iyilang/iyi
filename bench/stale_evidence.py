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
  <leg>.exit: numeric exit code, or "TIMEOUT", or "-<sig>", or "LAUNCH_ERROR", or "CANCELLED"
  <leg>.status: "EXIT:<rc>", "TIMEOUT:<timeout>", "SIGNAL:<sig>", "LAUNCH_ERROR:<err>", "CANCELLED"
  <leg>.timeout: explicit flag file present only when command timed out
  <leg>.signal: flag file present only when terminated by signal
  <leg>.error: error description file present only on launch error
  <leg>.cancelled: flag file present only when gate or command was cancelled
  <leg>.unresolved: flag file present only when detached descendants hold pipes after timeout

Process-group, descendant management, and streaming:
  Subprocesses are launched with start_new_session=True to establish a private
  process group. Stdin is inherited by default matching standard subprocess.run.
  Pipe readers tee raw bytes incrementally to exclusive on-disk files while streaming
  to memory, flushing and syncing each chunk immediately so partial output survives
  runner SIGKILL or controller crashes before cleanup.
  Streams are drained to EOF across descendants with bounded timeouts (avoiding
  unbounded hangs when detached descendants hold pipes).
  On timeout or gate cancellation (SIGINT/SIGTERM), SIGTERM is signaled to the
  entire owned process group via os.killpg, followed by SIGKILL after a grace period,
  and the process group leader is reaped.
  Explicit host boundary limitation: process-group signaling reaches only descendants
  within the child session. Descendants that decouple themselves by calling setsid()
  or double-forking into a new session cannot be contained by process-group signaling
  and require container, cgroup, or PID-namespace containment by the hosted orchestrator.
  When detached descendants hold open pipes beyond bounded drain timeouts, an explicit
  <leg>.unresolved flag is published for hosted supervisor tracking.
"""

import os
import signal
import subprocess
import threading
import time

_mkdir_lock = threading.Lock()
_active_processes_lock = threading.Lock()
_active_processes: set[subprocess.Popen] = set()


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


def _cleanup_all_active_processes() -> None:
    """Clean up all currently active process groups on gate cancellation."""
    with _active_processes_lock:
        procs = list(_active_processes)
    for proc in procs:
        try:
            _kill_group(proc.pid)
            proc.wait(timeout=0.2)
        except Exception:
            pass


def _install_cancellation_handlers() -> None:
    def _handle_cancel(sig, frame):
        _cleanup_all_active_processes()
        signal.signal(sig, signal.SIG_DFL)
        os.kill(os.getpid(), sig)

    try:
        if threading.current_thread() is threading.main_thread():
            signal.signal(signal.SIGINT, _handle_cancel)
            signal.signal(signal.SIGTERM, _handle_cancel)
    except (ValueError, AttributeError):
        pass


_install_cancellation_handlers()


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


def _pump_pipe(stream, file_handle, memory_buffer: bytearray) -> None:
    """Stream chunks from pipe to file handle (immediately flushed/synced) and memory buffer."""
    fd = stream.fileno()
    try:
        while True:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            file_handle.write(chunk)
            file_handle.flush()
            try:
                os.fsync(file_handle.fileno())
            except (OSError, ValueError):
                pass
            memory_buffer.extend(chunk)
    except (OSError, ValueError):
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
    timed_out = False
    cancelled = False
    unresolved = False
    proc = None
    launch_err = None

    try:
        # Note: stdin=None inherits stdin identically to default subprocess.run
        proc = subprocess.Popen(
            argv,
            env=env,
            cwd=cwd,
            stdin=None,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        with _active_processes_lock:
            _active_processes.add(proc)

        t_out = threading.Thread(
            target=_pump_pipe, args=(proc.stdout, stdout_f, raw_out), daemon=True
        )
        t_err = threading.Thread(
            target=_pump_pipe, args=(proc.stderr, stderr_f, raw_err), daemon=True
        )
        t_out.start()
        t_err.start()

        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            timed_out = True
            _kill_group(proc.pid)
            proc.wait()
            t_out.join(timeout=0.5)
            t_err.join(timeout=0.5)
            raise exc
        except (KeyboardInterrupt, SystemExit) as exc:
            cancelled = True
            _kill_group(proc.pid)
            proc.wait()
            t_out.join(timeout=0.5)
            t_err.join(timeout=0.5)
            raise exc
        else:
            # Drain streams from descendants up to bounded DRAIN_TIMEOUT (2.0s)
            t_out.join(timeout=2.0)
            t_err.join(timeout=2.0)
            if t_out.is_alive() or t_err.is_alive():
                unresolved = True
                _kill_group(proc.pid)
                t_out.join(timeout=0.5)
                t_err.join(timeout=0.5)
    except (OSError, ValueError) as err:
        if not timed_out and not cancelled:
            launch_err = err
        raise
    finally:
        if proc is not None:
            with _active_processes_lock:
                _active_processes.discard(proc)

        stdout_f.close()
        stderr_f.close()

        # Distinguish launch error, signal, timeout, cancellation, and actual numeric exit
        if timed_out:
            exit_str = "TIMEOUT"
            status_str = f"TIMEOUT:{timeout}"
            with open(timeout_path, "x", encoding="utf-8") as f:
                f.write(f"timeout after {timeout}s\n")
        elif cancelled:
            exit_str = "CANCELLED"
            status_str = "CANCELLED"
            with open(cancelled_path, "x", encoding="utf-8") as f:
                f.write("gate cancelled\n")
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

        if unresolved:
            status_str = f"UNRESOLVED_WRITERS:{status_str}"
            with open(unresolved_path, "x", encoding="utf-8") as f:
                f.write("detached descendant holds pipe; unresolved ownership for hosted supervisor\n")

        with open(exit_path, "x", encoding="utf-8") as f:
            f.write(f"{exit_str}\n")
        with open(status_path, "x", encoding="utf-8") as f:
            f.write(f"{status_str}\n")

    rc = proc.returncode if (proc and proc.returncode is not None) else (124 if timed_out else 1)
    return ProcessOutput(rc, bytes(raw_out), bytes(raw_err))
