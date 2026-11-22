#!/usr/bin/env bash
# Exercises std/secure_dns: a `Resolver` asking DNS over TLS and DNS over
# HTTPS upstreams instead of plaintext servers.
#
#     bash bench/std_secure_dns_exercise.sh
#
# The servers are bench/std_secure_dns_server.py, Python's ssl and
# http.server answering a fixed zone under a test root they make (and
# HTTP/2 through the `h2` package where it imports). The gate runs
# bench/std_secure_dns_exercise.iyi against them, plain and --release;
# asks dig the same questions over the same servers (`+tls`, `+https`,
# `+https-get`) - HTTPS records (RFC 9460) among them, which dig prints as
# `SvcbRecord#to_s` does - and holds the two to the same answers, which is what shows
# the scripted servers speak the protocols and not merely what the iyi
# client expects; holds the servers' padding rule, which every DoT and DoH
# query the iyi client sends must pass, to dig's `+padding`; and proves the
# checks can fail - each proof builds the exercise against a copy of the
# library with one rule taken out, and the exercise must stop at the check
# about that rule.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"

# Logs can contain partial output from a killed tool; retain only a bounded
# tail before the scratch directory is removed.
evidence() {
  local file="$1" size
  [ -f "$file" ] || return 0
  size="$(wc -c <"$file" 3<&- 4>&- | tr -d ' ' 3<&- 4>&-)"
  [ "$size" -gt 0 ] || return 0
  if [ "$size" -gt 16384 ]; then
    echo "-- $file: last 16384 of $size bytes"
  else
    echo "-- $file: last $size of $size bytes"
  fi
  tail -c 16384 "$file" 3<&- 4>&- | sed 's/^/  | /' 3<&- 4>&-
}

if [ "${1:-}" = "--dns-body" ]; then
  WORK="$2" SRV="$3" PY="$4" IYI="$5" REPO="$6" PSEP="$7"
  # The supervisor owns the server and every stage. FD 3 receives its go
  # line, FD 4 sends stage requests and the exit line, and ordinary gate
  # output remains visible.
  exec 3<&0 4>&1
  exec 0</dev/null 1>&2
  # After its exit line the body waits on FD 3, so the supervisor's group or
  # Job kill always meets a live leader.
  trap 'gate_exit=$?; printf "exit %s\n" "$gate_exit" >&4 || :; read -r _ <&3 || :' EXIT
  grant=""
  if ! IFS= read -r grant <&3 || [ "$grant" != go ]; then
    echo "the secure DNS supervisor did not grant the exercise"
    exit 76
  fi
else
  END_PROCESS_SH="$REPO/bench/end_process.sh"
  . "$END_PROCESS_SH"
  WORK="$(mktemp -d)"
  OWNED_PID=""
  OWNED_KIND=""
  CANCEL_STATUS=0
  # Completed jobs remain in jobs -p until wait collects them.
  owned_active() {
    local job
    for job in $(jobs -rp); do
      [ "$job" = "$OWNED_PID" ] && return 0
    done
    return 1
  }
  force_owned() {
    if [ "$END_PROCESS_WINDOWS" = yes ]; then
      # One native process, killed by taskkill on its own Windows pid from this
      # shell. timeout bounds only a taskkill that does not return.
      if { read -r native <"/proc/$OWNED_PID/winpid"; } 2>/dev/null; then
        MSYS2_ARG_CONV_EXCL="*" timeout --foreground -k 1 10 taskkill /F /PID "$native" >/dev/null 2>&1 || :
      fi
    else
      end_process "$OWNED_PID" KILL || :
    fi
  }
  reap_owned() {
    local end=$((SECONDS + 5))
    while owned_active && [ "$SECONDS" -lt "$end" ]; do sleep 0.1; done
    if owned_active; then
      jobs -l >&2
      echo "$OWNED_KIND cleanup is unconfirmed; retaining $WORK" >&2
      return 1
    fi
    wait "$OWNED_PID" 2>/dev/null || :
    OWNED_PID=""
    OWNED_KIND=""
  }
  # Only our deadline branch sets timeout: a child can itself exit 124/137.
  bounded() {
    local seconds="$1" log="$2" end code
    shift 2
    BOUNDED=""
    "$@" >"$log" 2>&1 &
    OWNED_PID=$!
    OWNED_KIND="preflight"
    end=$((SECONDS + seconds))
    while owned_active; do
      if [ "$CANCEL_STATUS" -ne 0 ]; then
        force_owned
        reap_owned || :
        return 1
      fi
      if [ "$SECONDS" -ge "$end" ]; then
        if owned_active; then
          BOUNDED=timeout
          force_owned
          if ! reap_owned; then
            BOUNDED=cleanup
          fi
          return 0
        fi
        break
      fi
      sleep 0.1
    done
    code=0
    wait "$OWNED_PID" 2>/dev/null || code=$?
    OWNED_PID=""
    OWNED_KIND=""
    BOUNDED="exit $code"
  }
  cancel() {
    CANCEL_STATUS="$1"
    : >"$WORK/cancel"
  }
  cleanup() {
    if [ -n "$OWNED_PID" ]; then
      if owned_active; then
        : >"$WORK/cancel"
        graceful_deadline=$((SECONDS + 2))
        while owned_active && [ "$SECONDS" -lt "$graceful_deadline" ]; do sleep 0.1; done
        if owned_active; then
          if [ "$OWNED_KIND" = supervisor ]; then
            echo "the secure DNS supervisor did not stop during cleanup" >&2
          fi
          force_owned
        fi
      fi
      reap_owned || return
    fi
    rm -rf "$WORK"
  }
  trap cleanup EXIT
  trap 'cancel 130' INT
  trap 'cancel 129' HUP
  trap 'cancel 143' TERM

  # Native Python and the compiler need native Windows paths.
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      REPO="$(cygpath -m "$REPO")"
      WORK="$(cygpath -m "$WORK")"
      BASH_NATIVE="$(cygpath -m "$BASH")"
      PSEP=';'
      ;;
    *) BASH_NATIVE="$BASH"; PSEP=':' ;;
  esac

  PY=""
  found_python=0
  PYTHON_PREFLIGHT_SECONDS=20
  for candidate in python3 python; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    found_python=1
    bounded "$PYTHON_PREFLIGHT_SECONDS" "$WORK/python-preflight.log" "$candidate" -c 'import sys' || exit "$CANCEL_STATUS"
    case "$BOUNDED" in
      "exit 0") PY="$candidate"; break ;;
      timeout)
        echo "Python interpreter startup watchdog expired"
        evidence "$WORK/python-preflight.log"
        exit 76
        ;;
      cleanup)
        echo "Python interpreter preflight cleanup failed"
        evidence "$WORK/python-preflight.log"
        exit 76
        ;;
    esac
  done
  if [ -z "$PY" ]; then
    if [ "$found_python" -eq 0 ]; then
      echo "skipped: no python3 here, so there is no scripted server to ask"
      exit 0
    fi
    echo "Python interpreter preflight failed"
    evidence "$WORK/python-preflight.log"
    exit 76
  fi
  bounded "$PYTHON_PREFLIGHT_SECONDS" "$WORK/crypto-preflight.log" "$PY" -c '
import importlib.util
import sys
try:
    import ssl
except ModuleNotFoundError as error:
    if error.name in ("ssl", "_ssl"):
        print(error, file=sys.stderr)
        sys.exit(42)
    raise
if importlib.util.find_spec("cryptography") is None:
    print("no cryptography package", file=sys.stderr)
    sys.exit(42)
from cryptography import x509
' || exit "$CANCEL_STATUS"
  case "$BOUNDED" in
    "exit 0") ;;
    "exit 42")
      echo "skipped: Python lacks ssl or cryptography, so there is no scripted server to ask"
      exit 0
      ;;
    timeout)
      echo "Python dependency preflight watchdog expired"
      evidence "$WORK/crypto-preflight.log"
      exit 76
      ;;
    cleanup)
      echo "Python dependency preflight cleanup failed"
      evidence "$WORK/crypto-preflight.log"
      exit 76
      ;;
    *)
      echo "Python dependency preflight failed"
      evidence "$WORK/crypto-preflight.log"
      exit 76
      ;;
  esac

  SRV="$WORK/servers"
  mkdir -p "$SRV"
  cat >"$WORK/supervisor.py" <<'PY'
import os
import pathlib
import queue
import re
import signal
import subprocess
import sys
import threading
import time
import traceback

PYTHON, SERVER, WORK, SRV, BASH, SCRIPT, REPO, IYI, PSEP = sys.argv[1:]
work = pathlib.Path(WORK)
srv = pathlib.Path(SRV)
SERVER_START_SECONDS = 20
DIAGNOSTIC_SECONDS = 5
CLEANUP_SECONDS = 5
STAGE_SECONDS = 60
FAILURE = 76


def cancelled():
    return (work / "cancel").exists()


def say(text):
    print(text, flush=True)


def show(path, head=False):
    try:
        with path.open("rb") as source:
            size = os.fstat(source.fileno()).st_size
            if not size:
                return
            count = min(size, 16384)
            if not head:
                source.seek(-count, os.SEEK_END)
            data = source.read(count)
        say("-- %s: %s %d of %d bytes" % (path, "first" if head else "last", len(data), size))
        sys.stdout.buffer.write(data)
        if data and not data.endswith(b"\n"):
            sys.stdout.buffer.write(b"\n")
        sys.stdout.buffer.flush()
    except FileNotFoundError:
        return
    except OSError as error:
        say("evidence unavailable: %s" % error)


def stop(child, deadline):
    if child is None or child.poll() is not None:
        return True
    try:
        child.terminate()
        try:
            child.wait(timeout=max(0.001, min(2, deadline - time.monotonic())))
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=max(0.001, deadline - time.monotonic()))
        return True
    except ProcessLookupError:
        try:
            child.wait(timeout=max(0.001, deadline - time.monotonic()))
            return True
        except (OSError, subprocess.TimeoutExpired) as error:
            say("cannot reap owned child: %s" % error)
            return False
    except (OSError, subprocess.TimeoutExpired) as error:
        say("cannot reap owned child: %s" % error)
        return False


def diagnostics(child):
    deadline = time.monotonic() + DIAGNOSTIC_SECONDS
    system = sys.platform
    commands = []
    if system == "darwin" or system.startswith("linux"):
        commands = [["uptime"], ["ps", "-A", "-o", "pid=,ppid=,stat=,pcpu=,etime=,comm="]]
        if system == "darwin":
            commands += [["vm_stat"], ["sample", str(child.pid), "3", "-file", str(work / "server.sample")]]
    for index, command in enumerate(commands):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            say("startup diagnostics watchdog expired")
            return
        path = work / ("diagnostic-%d" % index)
        say("== startup diagnostics: " + command[0])
        try:
            with path.open("wb") as output:
                subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=remaining, check=False)
        except subprocess.TimeoutExpired:
            show(path)
            if command[0] == "sample":
                show(work / "server.sample", head=True)
            say("startup diagnostics watchdog expired")
            return
        except OSError as error:
            say("startup diagnostics unavailable: %s" % error)
            continue
        show(path)
        if command[0] == "sample":
            show(work / "server.sample", head=True)


def stream_reader(pipe, events):
    try:
        while True:
            chunk = os.read(pipe.fileno(), 4096)
            if not chunk:
                events.put(("eof", b""))
                return
            events.put(("data", chunk))
    except OSError as error:
        events.put(("error", str(error)))


def startup(child, deadline):
    # The server writes WORKDIR/ready last, after every listener is bound.
    while True:
        if cancelled():
            return "cancel"
        code = child.poll()
        if (srv / "ready").is_file():
            if code is None:
                return "ready"
            say("the scripted servers exited before readiness was accepted (status %s)" % code)
            return "error"
        if code is not None:
            if (work / "server.log").stat().st_size:
                say("the scripted servers exited before readiness (status %s); server output follows" % code)
            else:
                say("the scripted servers exited silently before readiness (status %s)" % code)
            return "error"
        if time.monotonic() >= deadline:
            stage = (srv / "stage").read_text().strip() if (srv / "stage").exists() else "none"
            say("the scripted servers hung before signaling readiness, at stage: %s" % stage)
            diagnostics(child)
            return "error"
        time.sleep(min(0.1, max(0.001, deadline - time.monotonic())))


def start_body():
    command = [BASH, SCRIPT, "--dns-body", WORK, SRV, PYTHON, IYI, REPO, PSEP]
    options = dict(stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stdout, bufsize=0)
    if os.name != "nt":
        return subprocess.Popen(command, start_new_session=True, **options), None

    import ctypes
    from ctypes import wintypes

    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    ntdll = ctypes.WinDLL("ntdll")
    k32.CreateJobObjectW.argtypes = [wintypes.LPVOID, wintypes.LPCWSTR]
    k32.CreateJobObjectW.restype = wintypes.HANDLE
    k32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD]
    k32.SetInformationJobObject.restype = wintypes.BOOL
    k32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    k32.AssignProcessToJobObject.restype = wintypes.BOOL
    k32.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
    k32.TerminateJobObject.restype = wintypes.BOOL
    k32.QueryInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID,
                                               wintypes.DWORD, wintypes.LPVOID]
    k32.QueryInformationJobObject.restype = wintypes.BOOL
    k32.CloseHandle.argtypes = [wintypes.HANDLE]
    k32.CloseHandle.restype = wintypes.BOOL
    ntdll.NtResumeProcess.argtypes = [wintypes.HANDLE]
    ntdll.NtResumeProcess.restype = ctypes.c_long
    ntdll.RtlNtStatusToDosError.argtypes = [ctypes.c_long]
    ntdll.RtlNtStatusToDosError.restype = wintypes.ULONG

    class BASIC(ctypes.Structure):
        _fields_ = [("user", ctypes.c_int64), ("job_user", ctypes.c_int64), ("flags", wintypes.DWORD),
                    ("ws_min", ctypes.c_size_t), ("ws_max", ctypes.c_size_t), ("processes", wintypes.DWORD),
                    ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD), ("scheduling", wintypes.DWORD)]

    class EXTENDED(ctypes.Structure):
        _fields_ = [("basic", BASIC), ("io", ctypes.c_uint64 * 6), ("process_memory", ctypes.c_size_t),
                    ("job_memory", ctypes.c_size_t), ("peak_process", ctypes.c_size_t),
                    ("peak_job", ctypes.c_size_t)]

    class ACCOUNTING(ctypes.Structure):
        _fields_ = [("user", ctypes.c_int64), ("kernel", ctypes.c_int64),
                    ("period_user", ctypes.c_int64), ("period_kernel", ctypes.c_int64),
                    ("faults", wintypes.DWORD), ("total", wintypes.DWORD),
                    ("active", wintypes.DWORD), ("terminated", wintypes.DWORD)]

    job = None
    body = None
    assigned = False
    try:
        job = k32.CreateJobObjectW(None, None)
        if not job:
            raise ctypes.WinError(ctypes.get_last_error())
        info = EXTENDED()
        info.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not k32.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info)):
            raise ctypes.WinError(ctypes.get_last_error())
        body = subprocess.Popen(command, creationflags=0x4, **options)  # CREATE_SUSPENDED
        if not k32.AssignProcessToJobObject(job, int(body._handle)):
            raise ctypes.WinError(ctypes.get_last_error())
        assigned = True
        result = ntdll.NtResumeProcess(int(body._handle))
        if result != 0:
            raise ctypes.WinError(ntdll.RtlNtStatusToDosError(result))
        return body, (k32, ctypes, job, ACCOUNTING)
    except (OSError, ValueError) as error:
        if assigned:
            k32.TerminateJobObject(job, 1)
        if body is not None:
            try:
                body.kill()
            except OSError:
                pass
            try:
                body.wait(timeout=CLEANUP_SECONDS)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if job:
            k32.CloseHandle(job)
        say("the secure DNS exercise could not be placed in a job object: %s" % error)
        return None, None


def end_body(body, job):
    # The body waits on its control pipe after its exit line, so it is still
    # a live group leader here and the group can be signalled.
    deadline = time.monotonic() + CLEANUP_SECONDS
    ok = True
    if job is None:
        try:
            os.killpg(body.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as error:
            say("cannot signal secure DNS exercise group: %s" % error)
            ok = False
    else:
        k32, ctypes, handle, accounting = job
        if not k32.TerminateJobObject(handle, 1):
            say("cannot terminate secure DNS exercise job: %s" % ctypes.WinError(ctypes.get_last_error()))
            ok = False
    try:
        body.wait(timeout=max(0.001, deadline - time.monotonic()))
    except (OSError, subprocess.TimeoutExpired) as error:
        say("cannot reap secure DNS exercise body: %s" % error)
        ok = False
    if job is not None:
        while True:
            info = accounting()
            if not k32.QueryInformationJobObject(handle, 1, ctypes.byref(info), ctypes.sizeof(info), None):
                say("cannot inspect secure DNS exercise job: %s" % ctypes.WinError(ctypes.get_last_error()))
                ok = False
                break
            if not info.active:
                break
            if time.monotonic() >= deadline:
                say("secure DNS exercise job still has %s active processes" % info.active)
                ok = False
                break
            time.sleep(0.05)
        if not k32.CloseHandle(handle):
            say("cannot close secure DNS exercise job: %s" % ctypes.WinError(ctypes.get_last_error()))
            ok = False
    return ok


def run_body(server):
    body, job = start_body()
    if body is None:
        return FAILURE
    events = queue.Queue()
    threading.Thread(target=stream_reader, args=(body.stdout, events), daemon=True).start()

    def control():
        try:
            body.stdin.write(b"go\n")
            body.stdin.flush()
        except BrokenPipeError:
            pass
        pending = bytearray()
        done = False
        closed = False
        stage_seconds = STAGE_SECONDS
        stage_label = "the secure DNS exercise"
        stage_evidence = None
        stage_deadline = time.monotonic() + stage_seconds

        def failed(message, fallback=None):
            say(message)
            source = stage_evidence if stage_evidence is not None else fallback
            if source is not None and source.is_file():
                show(source)
            return FAILURE, False

        while True:
            if cancelled():
                return 143, False
            if server.poll() is not None:
                return failed("the scripted servers exited during the exercise (status %s)" % server.returncode, work / "server.log")
            if b"\n" not in pending:
                if len(pending) > 256:
                    return failed("the secure DNS exercise sent an oversized control request")
                if closed:
                    if pending:
                        return failed("the secure DNS exercise sent an invalid control request")
                    return FAILURE, stage_evidence if stage_evidence is not None else True
                remaining = stage_deadline - time.monotonic()
                try:
                    event, value = events.get_nowait() if remaining <= 0 else events.get(timeout=min(0.1, remaining))
                except queue.Empty:
                    if remaining <= 0:
                        return failed("%s watchdog expired (%s s)" % (stage_label, stage_seconds))
                    continue
                if event == "eof":
                    closed = True
                elif event == "data":
                    pending.extend(value)
                else:
                    return failed("the secure DNS exercise control stream closed unexpectedly")
                continue
            raw, _, rest = bytes(pending).partition(b"\n")
            pending = bytearray(rest)
            if len(raw) + 1 > 256:
                return failed("the secure DNS exercise sent an oversized control request")
            if raw.endswith(b"\r"):
                raw = raw[:-1]
            try:
                line = raw.decode("ascii")
            except UnicodeDecodeError:
                return failed("the secure DNS exercise sent an invalid control request")
            if line == "done" and not done:
                done = True
                continue
            match = re.fullmatch(r"exit ([0-9]{1,3})", line)
            if match and not pending:
                code = int(match.group(1))
                if code > 255 or (code == 0 and not done):
                    return failed("the secure DNS exercise exited without completing its control stream")
                return code, False
            match = re.fullmatch(r"stage ([0-9]{1,4}) (-|[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*) ([ -~]+)", line)
            if match and not done:
                seconds, relative, label = match.groups()
                if not 1 <= int(seconds) <= 3600 or ".." in relative:
                    return failed("the secure DNS exercise sent an invalid control request")
                stage_seconds = int(seconds)
                stage_label = label
                stage_evidence = None if relative == "-" else work / relative
                stage_deadline = time.monotonic() + stage_seconds
                continue
            return failed("the secure DNS exercise sent an invalid control request")

    try:
        verdict, missing = control()
    finally:
        ended = end_body(body, job)
    if not ended:
        say("the secure DNS exercise did not end")
        return FAILURE
    if missing:
        say("the secure DNS exercise ended without reporting its status (status %s)" % body.returncode)
        if missing is not True:
            show(missing)
        return FAILURE
    return verdict


def main():
    (work / "supervisor.armed").touch()
    server = None
    verdict = FAILURE
    try:
        with (work / "server.log").open("wb") as output:
            deadline = time.monotonic() + SERVER_START_SECONDS
            server = subprocess.Popen([PYTHON, SERVER, SRV], stdout=output, stderr=subprocess.STDOUT)
            outcome = startup(server, deadline)
            if outcome == "cancel":
                verdict = 143
            elif outcome == "ready":
                verdict = run_body(server)
            else:
                show(work / "server.log")
    finally:
        if not stop(server, time.monotonic() + CLEANUP_SECONDS):
            if verdict == 0:
                verdict = FAILURE
    if verdict == 0:
        say("the std/secure_dns exercise holds")
    return verdict


if __name__ == "__main__":
    try:
        verdict = main()
    except Exception:
        say("the secure DNS supervisor failed")
        traceback.print_exc()
        verdict = FAILURE
    sys.exit(verdict)
PY
  "$PY" -I -S "$WORK/supervisor.py" "$PY" "$REPO/bench/std_secure_dns_server.py" "$WORK" "$SRV" "$BASH_NATIVE" "$REPO/bench/std_secure_dns_exercise.sh" "$REPO" "$IYI" "$PSEP" &
  OWNED_PID=$!
  OWNED_KIND=supervisor
  bootstrap_deadline=$((SECONDS + PYTHON_PREFLIGHT_SECONDS))
  while :; do
    if [ "$CANCEL_STATUS" -ne 0 ]; then exit "$CANCEL_STATUS"; fi
    if ! owned_active; then
      supervisor_code=0
      wait "$OWNED_PID" 2>/dev/null || supervisor_code=$?
      OWNED_PID=""
      OWNED_KIND=""
      echo "Python supervisor exited before arming (status $supervisor_code)"
      exit 76
    fi
    if [ "$SECONDS" -ge "$bootstrap_deadline" ]; then
      echo "Python supervisor startup watchdog expired"
      exit 76
    fi
    [ -f "$WORK/supervisor.armed" ] && break
    sleep 0.1
  done
  supervisor_code=0
  while :; do
    supervisor_code=0
    wait "$OWNED_PID" || supervisor_code=$?
    if [ "$CANCEL_STATUS" -eq 0 ] || ! owned_active; then break; fi
  done
  OWNED_PID=""
  OWNED_KIND=""
  if [ "$CANCEL_STATUS" -ne 0 ]; then exit "$CANCEL_STATUS"; fi
  exit "$supervisor_code"
fi

status=0
export IYI_PATH="$REPO/src"

BUILD_SECONDS=300
CLIENT_SECONDS=180
BROKEN_SECONDS=120
DIG_SECONDS=30
STAGE_SECONDS=60

# Every stretch between stage requests has an owner-enforced deadline.
stage() {
  if ! printf 'stage %s %s %s\n' "$1" "$2" "$3" >&4; then
    echo "the secure DNS supervisor could not receive a stage"
    exit 76
  fi
}

if [ -f "$SRV/h2.missing" ]; then
  echo "== $(cat "$SRV/h2.missing" 3<&- 4>&-): DNS over HTTPS is asked over HTTP/1.1 alone"
fi

# build_and_run <label> <name> [build flags]: the exercise, built and run
# against the servers.
build_and_run() {
  local label="$1" name="$2"
  shift 2
  stage "$BUILD_SECONDS" "$name.build.log" "$label: build"
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_secure_dns_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1 </dev/null 3<&- 4>&-; then
    echo "$label: build failed"
    evidence "$WORK/$name.build.log"
    status=1
    return 1
  fi
  stage "$CLIENT_SECONDS" "$name.out" "$label: client"
  "$WORK/$name" "$SRV" >"$WORK/$name.out" 2>&1 </dev/null 3<&- 4>&-
  local exit_code=$?
  stage "$STAGE_SECONDS" "$name.out" "$label: the checks after its client"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    evidence "$WORK/$name.out"
    status=1
    return 1
  fi
  if grep -q "iyi: panic" "$WORK/$name.out" 3<&- 4>&-; then
    echo "$label: a panic the program outlived"
    evidence "$WORK/$name.out"
    status=1
    return 1
  fi
  grep -v '^answer ' "$WORK/$name.out" 3<&- 4>&- | sed 's/^/  /' 3<&- 4>&-
  return 0
}

SECTIONS="wire wire_padding dot_answers dot_reuse dot_pipelined dot_idle dot_wrong_name dot_id_mismatch dot_truncated dot_oversized dot_recovers dot_padding edns_answers doh_post doh_get doh_zero_id doh_reuse doh_status doh_content_type doh_oversized doh_truncated doh_wrong_name doh_padding plaintext_unpadded https_plaintext no_plaintext_fallback plaintext_fallback connect_by_name"
if [ -f "$SRV/h2.port" ]; then
  SECTIONS="$SECTIONS doh_h2"
fi

for mode in plain release; do
  if [ "$mode" = plain ]; then
    echo "== the std/secure_dns exercise, plain build"
    build_and_run "plain" dns-plain
  else
    echo
    echo "== the same program with optimisation on (--release)"
    build_and_run "release" dns-release --release
  fi
  if ! grep -q "^all checks passed" "$WORK/dns-$mode.out" 2>/dev/null 3<&- 4>&-; then
    echo "  $mode: the run did not reach the end"
    status=1
  fi
  missing=""
  for section in $SECTIONS; do
    grep -q "^$section: ok" "$WORK/dns-$mode.out" 2>/dev/null 3<&- 4>&- || missing="$missing $section"
  done
  if [ -n "$missing" ]; then
    echo "  $mode: nothing reported for:$missing"
    status=1
  else
    echo "  $mode: all $(echo $SECTIONS | wc -w 3<&- 4>&- | tr -d ' ' 3<&- 4>&-) sections reported ok"
  fi
done

echo
echo "== dig asks the same servers the same questions"
# dig's DNS over HTTPS is HTTP/2's alone: against the HTTP/1.1 server it
# answers "ALPN for HTTP/2 failed" (dig 9.20.24, measured), so the
# HTTP/1.1 answers are held to dig through the HTTP/2 server, which answers
# from the same zone by the same code.
HAS_TLS=no
HAS_HTTPS=no
DIG_VERSION_SET=no
dig_version() {
  if [ "$DIG_VERSION_SET" = no ]; then
    : >"$WORK/dig.version"
    stage "$DIG_SECONDS" dig.version "dig version"
    dig -v >"$WORK/dig.version" 2>&1 </dev/null 3<&- 4>&- || :
    DIG_VERSION=""
    IFS= read -r DIG_VERSION <"$WORK/dig.version" || :
    DIG_VERSION_SET=yes
  fi
}
ask() {
  local label="$1"
  shift
  : >"$WORK/dig.out"
  stage "$DIG_SECONDS" dig.out "$label"
  dig "$@" >"$WORK/dig.out" 2>&1 </dev/null 3<&- 4>&-
  DIG_STATUS=$?
  DIG_OUTPUT="$(cat "$WORK/dig.out" 3<&- 4>&-)"
}
if command -v dig >/dev/null 2>&1; then
  stage "$DIG_SECONDS" dig.help "dig help"
  dig -h >"$WORK/dig.help" 2>&1 </dev/null 3<&- 4>&-
  dig_status=$?
  if [ "$dig_status" -ne 0 ] || ! grep -Eq '^Usage:[[:space:]]+dig[[:space:]]' "$WORK/dig.help" 3<&- 4>&- ||
     ! grep -Fq '+[no]short' "$WORK/dig.help" 3<&- 4>&-; then
    echo "dig help failed"
    evidence "$WORK/dig.help"
    exit 76
  fi
  grep -q '+\[no\]tls ' "$WORK/dig.help" 3<&- 4>&- && HAS_TLS=yes
  grep -q '+\[no\]https\[=' "$WORK/dig.help" 3<&- 4>&- && HAS_HTTPS=yes
fi
if ! command -v dig >/dev/null 2>&1; then
  echo "  skipped: no dig here, so nothing but the iyi client asks the scripted servers"
elif [ "$HAS_TLS" = no ] && [ "$HAS_HTTPS" = no ]; then
  dig_version
  echo "  skipped: this dig has neither +tls nor +https ($DIG_VERSION)"
else
  DOT_PORT="$(cat "$SRV/dot.port" 3<&- 4>&-)"
  # dig checks the certificate when it can read the test root and has the
  # options for it. Ubuntu's AppArmor profile for dig lets it read files
  # under $HOME outside dot directories and nothing else, so a root in a
  # scratch directory answers "TLS context cannot be created" (measured,
  # dig 9.20.24), and an older dig may not know +tls-ca. Either way dig
  # then asks without checking, the sentence says why, and the name is
  # the iyi client's to check (dot_wrong_name, doh_wrong_name).
  VERIFY=(+tls-ca="$SRV/ca.pem" +tls-hostname=dns.test)
  probe=(+tls -p "$DOT_PORT")
  [ "$HAS_TLS" = no ] && probe=(+https -p "$(cat "$SRV/h2.port" 2>/dev/null 3<&- 4>&- || echo 1)")
  ask "dig certificate" "${probe[@]}" "${VERIFY[@]}" @127.0.0.1 a.zone.test A +short +tries=1 +timeout=5
  checked="$DIG_OUTPUT"
  if [ "$checked" != "192.0.2.1" ]; then
    echo "  dig asks without checking the certificate: with +tls-ca it said \"$(printf '%s\n' "$checked" | head -1 3<&- 4>&-)\""
    VERIFY=()
  else
    echo "  dig checks the certificate for dns.test against the test root"
    # The refusal the iyi client gives wrong.test, dig's too: the server's
    # certificate names dns.test and 127.0.0.1 and nothing else.
    ask "dig wrong certificate" "${probe[@]}" +tls-ca="$SRV/ca.pem" +tls-hostname=wrong.test @127.0.0.1 a.zone.test A +short +tries=1 +timeout=5
    if printf '%s\n' "$DIG_OUTPUT" | grep -q "192.0.2.1" 3<&- 4>&-; then
      echo "  dig took the certificate for wrong.test, which it does not name"
      status=1
    else
      echo "  dig refuses it for wrong.test, as the iyi client does"
    fi
  fi
  # A dig that predates the HTTPS type says ";; Warning, ignoring invalid
  # type HTTPS" to `-t HTTPS` (BIND's sentence for a type it does not
  # know, measured with an unknown type's name) and would read `HTTPS` as
  # a second name to ask about: its HTTPS rows are skipped, and said so.
  # Asked of the plaintext server, which every run has.
  HAS_HTTPS_TYPE=yes
  ask "dig HTTPS type" -t HTTPS +short +tries=1 +timeout=5 @127.0.0.1 -p "$(cat "$SRV/udp.port" 3<&- 4>&-)" svc.zone.test
  type_probe="$DIG_OUTPUT"
  if printf '%s' "$type_probe" | grep -qF 'ignoring invalid type HTTPS' 3<&- 4>&-; then
    HAS_HTTPS_TYPE=no
    dig_version
    echo "  HTTPS records skipped: this dig does not know the type ($DIG_VERSION): it said \"$(printf '%s' "$type_probe" | head -1 3<&- 4>&-)\""
  fi
  asked=0
  differs=0
  over=""
  while read -r _ via type name values; do
    [ "$type" = HTTPS ] && [ "$HAS_HTTPS_TYPE" = no ] && continue
    case "$via" in
      dot) [ "$HAS_TLS" = yes ] || continue; flags=(+tls) port="$DOT_PORT" ;;
      h2) [ "$HAS_HTTPS" = yes ] || continue; flags=(+https) port="$(cat "$SRV/h2.port" 3<&- 4>&-)" ;;
      h2-get) [ "$HAS_HTTPS" = yes ] || continue; flags=(+https-get) port="$(cat "$SRV/h2.port" 3<&- 4>&-)" ;;
      *) continue ;;
    esac
    case " $over " in *" ${flags[0]} "*) ;; *) over="$over ${flags[0]}" ;; esac
    ask "dig $via $type $name" "${flags[@]}" ${VERIFY[@]+"${VERIFY[@]}"} @127.0.0.1 -p "$port" "$name" -t "$type" +short +tries=1 +timeout=5
    got="$DIG_OUTPUT"
    # +short: an address a line, a CNAME's target ending in a dot, a TXT
    # record's strings each quoted, an HTTPS record's data in presentation
    # format, which the iyi line holds as `SvcbRecord#to_s` prints it. The
    # iyi line joins a record's strings and separates records with " | ".
    stage "$STAGE_SECONDS" dig.out "dig $via $type $name: parse"
    if [ "$type" = TXT ]; then
      said="$(printf '%s\n' "$got" | "$PY" -c 'import sys, shlex; print(" | ".join("".join(shlex.split(line)) for line in sys.stdin.read().splitlines() if line))' 3<&- 4>&-)"
    elif [ "$type" = HTTPS ]; then
      said="$(printf '%s\n' "$got" | "$PY" -c 'import sys; print(" | ".join(line for line in sys.stdin.read().splitlines() if line))' 3<&- 4>&-)"
    else
      said="$(printf '%s\n' "$got" | grep -v '\.$' 3<&- 4>&- | tr '\n' ' ' 3<&- 4>&- | sed 's/ *$//' 3<&- 4>&-)"
    fi
    asked=$((asked + 1))
    if [ "$said" != "$values" ]; then
      echo "  $via $type $name: iyi read \"$values\", dig \"$said\""
      differs=1
    fi
  done < <(grep '^answer ' "$WORK/dns-plain.out" 2>/dev/null 3<&- 4>&-)
  if [ "$asked" -eq 0 ] && { [ "$HAS_TLS" = yes ] || [ -f "$SRV/h2.port" ]; }; then
    echo "  nothing to ask: the exercise printed no answers dig can be asked for"
    status=1
  elif [ "$asked" -eq 0 ]; then
    :
  elif [ "$differs" -ne 0 ]; then
    status=1
  else
    echo "  dig and the iyi resolver agree on $asked answers, over$over"
  fi
  if [ "$HAS_TLS" = no ]; then
    dig_version
    echo "  +tls skipped: this dig has no DNS over TLS ($DIG_VERSION)"
  fi
  if [ "$HAS_HTTPS" = no ]; then
    dig_version
    echo "  +https skipped: this dig has no DNS over HTTPS ($DIG_VERSION)"
  elif [ ! -f "$SRV/h2.port" ]; then
    echo "  +https skipped: there is no HTTP/2 server without the h2 package, and dig speaks DNS over HTTPS over HTTP/2 alone"
  fi
  # The server's padding rule, which the iyi client is held to, held to
  # dig's own padding (+padding, BIND's RFC 7830): a query dig pads to 128
  # passes it, and one dig does not pad is counted unpadded. The first ask
  # starts the server's counts again.
  if [ "$HAS_TLS" = yes ]; then
    pad_ask() {
      ask "dig padding" +tls ${VERIFY[@]+"${VERIFY[@]}"} @127.0.0.1 -p "$DOT_PORT" padding.zone.test TXT +short +tries=1 +timeout=5 "$@"
    }
    pad_ask
    pad_ask +padding=128
    padded="$DIG_OUTPUT"
    pad_ask
    unpadded="$DIG_OUTPUT"
    if [ "$padded" != '"queries=1 edns=1 unpadded=0"' ]; then
      echo "  the server's padding rule refused dig's padded query: $padded"
      status=1
    elif [ "$unpadded" != '"queries=1 edns=1 unpadded=1 first=no Padding option"' ]; then
      echo "  the server's padding rule passed dig's unpadded query: $unpadded"
      status=1
    else
      echo "  the server's padding rule passes dig's +padding=128 query and refuses its unpadded one"
    fi
  fi
fi

echo
echo "== the checks fail when the module is broken"
# breaks <label> <dir> <phrase> <file> <old> <new> [<file> <old> <new>]:
# the exercise built against a copy of src/std with *old* in std/<file>
# replaced by *new* must fail, and say *phrase*.
breaks() {
  local label="$1" dir="$2" phrase="$3"
  stage "$BUILD_SECONDS" "$dir/patch.log" "$label: patch"
  mkdir -p "$WORK/$dir/std" 3<&- 4>&-
  : >"$WORK/$dir/patch.log"
  FILE1="$4" OLD1="$5" NEW1="$6" FILE2="${7:-}" OLD2="${8:-}" NEW2="${9:-}" "$PY" - >"$WORK/$dir/patch.log" 2>&1 3<&- 4>&- <<PY
import os
from pathlib import Path
for n in ("1", "2"):
    name = os.environ["FILE" + n]
    if not name:
        continue
    target = Path("$WORK/$dir/std") / name
    src = (target if target.exists() else Path("$REPO/src/std") / name).read_text()
    old, new = os.environ["OLD" + n], os.environ["NEW" + n]
    if old not in src:
        raise SystemExit("patch site missing in " + name)
    with open(target, "w", newline="\n") as handle:
        handle.write(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    evidence "$WORK/$dir/patch.log"
    status=1
    return
  fi
  stage "$BUILD_SECONDS" "$dir/build.log" "$label: build"
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -o "$WORK/$dir/program" \
       "$REPO/bench/std_secure_dns_exercise.iyi" >"$WORK/$dir/build.log" 2>&1 </dev/null 3<&- 4>&-; then
    echo "  $label: the broken copy did not build"
    evidence "$WORK/$dir/build.log"
    status=1
    return
  fi
  stage "$BROKEN_SECONDS" "$dir/out" "$label: broken copy"
  "$WORK/$dir/program" "$SRV" >"$WORK/$dir/out" 2>&1 </dev/null 3<&- 4>&-
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise PASSED on a broken module"
    evidence "$WORK/$dir/out"
    status=1
  elif ! grep -qF -- "$phrase" "$WORK/$dir/out" 3<&- 4>&-; then
    echo "  $label: failed, but not at '$phrase'"
    evidence "$WORK/$dir/out"
    status=1
  else
    echo "  $label: caught at \"$(grep -m1 -F -- "$phrase" "$WORK/$dir/out" 3<&- 4>&- | sed 's/^iyi: panic: //' 3<&- 4>&- | cut -c1-110 3<&- 4>&-)\""
  fi
}

breaks "the server's name not verified" noname "a server whose certificate does not name wrong.test" secure_dns.iyi \
  'tls = TlsClient.over(socket, @name, @config, timeout_ms, @session)' \
  'tls = TlsClient.over(socket, @address, @config, timeout_ms, @session)'
breaks "the length prefix dropped" noprefix "the encrypted resolver asks over TLS" secure_dns.iyi \
  '      framed << (query.size >> 8).to_u8
      framed << (query.size & 255).to_u8
' ''
breaks "the dns parameter sent with its padding" padded "the dns parameter is base64url without padding" secure_dns.iyi \
  '    while size > 0 && text.to_unsafe[size - 1] == 61_u8
      size = size - 1
    end
' ''
# Not the slot matching: the server answers a pipelined pair last first,
# so a client that took answers in arrival order is caught at the first
# lookup of both families. This takes out the refusal alone.
breaks "an answer's ID not checked over TLS" noid "an answer with an ID no query has is refused over TLS" secure_dns.iyi \
  '        return DnsError.new(DnsError::MALFORMED, "", label, "an answer with the ID #{id}, which no query waiting on the connection has")' \
  '        slot = 0'
breaks "the plaintext servers asked unasked" silentplain "a dead upstream, no fallback asked for" socket.iyi \
  'if @plaintext_fallback && !@servers.empty?' \
  'if !@servers.empty?'
# A TC answer's records are not read (std/dns), so taken over a stream it
# reads as a name without the address: refused, but not as truncated.
breaks "TC taken over a stream" tcstream "TC over a stream is refused" socket.iyi \
  'return DnsMessage.malformed("the answer is truncated (TC), which an answer over a stream never is").about(name, label) if message.truncated?' ''
breaks "bytes past the message taken" pastend "a frame longer than its message" socket.iyi \
  'return DnsMessage.malformed("oversized: #{bytes.size - ends} bytes past the end of the message").about(name, label) if ends < bytes.size' ''
breaks "a connection per exchange" noreuse "every query over one TLS connection" secure_dns.iyi \
  '    if kept = live
      got = over(kept, queries, timeout_ms, true)
    end
' '    close
'
breaks "an idle connection kept past its timeout" noidle "a connection idle past its timeout is closed" secure_dns.iyi \
  'if Resolver.now_ms - @used_ms > @idle_ms.to_i64' \
  'if false'
breaks "a DoH status not read" nostatus "a 500" secure_dns.iyi \
  'return DnsError.new(DnsError::REFUSED, "", label, "HTTP #{response.status} #{response.reason}") unless response.status == 200' ''
breaks "a DoH Content-Type not read" notype "an answer as text/plain" secure_dns.iyi \
  'return DnsError.new(DnsError::MALFORMED, "", label, "an answer of #{said.inspect}, not #{MEDIA}") unless media == MEDIA' ''
breaks "a DoH query with a random ID" doh_id "a POST's query has the ID 0" secure_dns.iyi \
  '  def zero_id? : Bool
    true' '  def zero_id? : Bool
    false'
breaks "an HTTPClient's own TLS configuration ignored" clienttls "over HTTPS from a server without h2" http.iyi \
  'under = keeping.tls || under' ''
breaks "an HTTPClient's own resolver ignored" clientresolver "a URL's host pinned to an address" http.iyi \
  'through = keeping.resolver' ''
breaks "queries sent unpadded" unpadded "every DoT query is padded" socket.iyi \
  'queries << DnsMessage.query(id, name, type, DnsMessage::PADDING_BLOCK)' \
  'queries << DnsMessage.query(id, name, type)'
breaks "the padding not brought to a block" unblocked "not a multiple of 128" dns.iyi \
  '      size = size + (block - size % block) % block
' ''
# HTTPS records over the upstreams: asked in the clear instead, of a
# resolver whose upstreams are its only servers; and their data not read
# as SVCB records when it came over an upstream.
breaks "HTTPS records asked in the clear despite upstreams" httpsclear "dot: a ServiceMode HTTPS record" socket.iyi \
  'return plaintext(name, type) if @upstreams.empty?' \
  'return plaintext(name, type) if @upstreams.empty? || type == DnsRecord::HTTPS'
breaks "HTTPS records not parsed when they came over an upstream" httpsparse "dot: a ServiceMode HTTPS record" socket.iyi \
  'record = SvcbRecord.parse(data, owner)' \
  'record = @upstreams.empty? ? SvcbRecord.parse(data, owner) : DnsMessage.malformed("an HTTPS record over an upstream, not read")'

echo
if [ "$status" -eq 0 ]; then
  if ! printf 'done\n' >&4; then
    echo "the secure DNS supervisor could not receive completion"
    exit 76
  fi
else
  echo "the std/secure_dns exercise did not hold"
fi
exit $status
