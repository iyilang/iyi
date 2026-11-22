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

if [ "${1:-}" = "--dns-body" ]; then
  WORK="$2" SRV="$3" PY="$4" IYI="$5" REPO="$6" PSEP="$7"
  # The supervisor owns the server and watched clients. FD 3 receives its
  # replies, FD 4 sends requests, and ordinary gate output remains visible.
  exec 3<&0 4>&1
  exec 0</dev/null 1>&2
  grant=""
  if ! IFS= read -r grant <&3 || [ "$grant" != go ]; then
    echo "the secure DNS supervisor did not grant the exercise"
    exit 76
  fi
else
  . "$REPO/bench/end_process.sh"
  WORK="$(mktemp -d)"
  SUPERVISOR_PID=""
  CANCEL_STATUS=0
  supervisor_active() {
    local job
    for job in $(jobs -p); do
      [ "$job" = "$SUPERVISOR_PID" ] && return 0
    done
    return 1
  }
  cancel() {
    CANCEL_STATUS="$1"
    : >"$WORK/cancel"
  }
  cleanup() {
    if [ -n "$SUPERVISOR_PID" ] && supervisor_active; then
      : >"$WORK/cancel"
      cleanup_deadline=$((SECONDS + 5))
      graceful_deadline=$((SECONDS + 2))
      while supervisor_active && [ "$SECONDS" -lt "$graceful_deadline" ]; do sleep 0.1; done
      if supervisor_active; then
        echo "the secure DNS supervisor did not stop during cleanup" >&2
        if [ "$END_PROCESS_WINDOWS" = yes ]; then
          # MSYS2_ARG_CONV_EXCL may already be '*': doubled slashes then
          # reach taskkill literally and are rejected. Pass native switches.
          timeout -k 1 3 "$BASH" -c '
            { read -r native <"/proc/$1/winpid"; } 2>/dev/null || exit 1
            MSYS2_ARG_CONV_EXCL="*" taskkill /F /PID "$native" >/dev/null 2>&1
          ' _ "$SUPERVISOR_PID" || :
        else
          timeout -k 1 3 "$BASH" -c '. "$1"; end_process "$2"' _ "$REPO/bench/end_process.sh" "$SUPERVISOR_PID" || :
        fi
        while supervisor_active && [ "$SECONDS" -lt "$cleanup_deadline" ]; do sleep 0.1; done
        if supervisor_active; then
          echo "supervisor cleanup is unconfirmed; retaining $WORK" >&2
          return
        fi
      fi
      wait "$SUPERVISOR_PID" 2>/dev/null || :
      SUPERVISOR_PID=""
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
    timeout -k 5 "$PYTHON_PREFLIGHT_SECONDS" "$candidate" -c 'import sys' >"$WORK/python-preflight.log" 2>&1
    probe_code=$?
    if [ "$probe_code" -eq 0 ]; then
      PY="$candidate"
      break
    elif [ "$probe_code" -eq 124 ] || [ "$probe_code" -eq 137 ]; then
      echo "Python interpreter startup watchdog expired"
      cat "$WORK/python-preflight.log"
      exit 76
    fi
  done
  if [ -z "$PY" ]; then
    if [ "$found_python" -eq 0 ]; then
      echo "skipped: no python3 here, so there is no scripted server to ask"
      exit 0
    fi
    echo "Python interpreter preflight failed"
    cat "$WORK/python-preflight.log"
    exit 76
  fi
  timeout -k 5 "$PYTHON_PREFLIGHT_SECONDS" "$PY" -c '
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
' >"$WORK/crypto-preflight.log" 2>&1
  probe_code=$?
  case "$probe_code" in
    0) ;;
    42)
      echo "skipped: Python lacks ssl or cryptography, so there is no scripted server to ask"
      exit 0
      ;;
    124 | 137)
      echo "Python dependency preflight watchdog expired"
      cat "$WORK/crypto-preflight.log"
      exit 76
      ;;
    *)
      echo "Python dependency preflight failed"
      cat "$WORK/crypto-preflight.log"
      exit 76
      ;;
  esac

  SRV="$WORK/servers"
  mkdir -p "$SRV"
  cat >"$WORK/supervisor.py" <<'PY'
import os
import pathlib
import queue
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
BODY_DRAIN_SECONDS = 5
FAILURE = 76


def cancelled():
    return (work / "cancel").exists()


def say(text):
    print(text, flush=True)


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
            if path.exists():
                sys.stdout.buffer.write(path.read_bytes())
            sample = work / "server.sample"
            if command[0] == "sample" and sample.exists():
                sys.stdout.buffer.write(sample.read_bytes())
            sys.stdout.buffer.flush()
            say("startup diagnostics watchdog expired")
            return
        except OSError as error:
            say("startup diagnostics unavailable: %s" % error)
            continue
        data = path.read_bytes()
        if command[0] == "ps":
            lines = data.decode(errors="replace").splitlines()
            def cpu(line):
                try:
                    return float(line.split(None, 5)[3])
                except (ValueError, IndexError):
                    return 0.0
            data = ("\n".join(sorted(lines, key=cpu, reverse=True)[:5]) + "\n").encode()
        sys.stdout.buffer.write(data)
        if command[0] == "sample" and (work / "server.sample").exists():
            sys.stdout.buffer.write((work / "server.sample").read_bytes())
        sys.stdout.buffer.flush()


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


def startup(child, events, deadline):
    buffer = bytearray()
    frame = None
    eof = False
    while True:
        if cancelled():
            return "cancel"
        remaining = deadline - time.monotonic()
        expired = remaining <= 0
        try:
            if eof:
                raise queue.Empty
            kind, value = events.get_nowait() if expired else events.get(timeout=min(0.1, remaining))
        except queue.Empty:
            if expired:
                if child.poll() is not None and not eof:
                    say("the scripted server readiness pipe did not drain by the startup deadline (child status %s)" % child.returncode)
                    return "error"
                stage = (srv / "stage").read_text().strip() if (srv / "stage").exists() else "none"
                suffix = " (stdout closed)" if eof else ""
                say("the scripted servers hung before signaling readiness, at stage: %s%s" % (stage, suffix))
                log = work / "server.log"
                if log.exists():
                    sys.stdout.buffer.write(log.read_bytes())
                    sys.stdout.buffer.flush()
                diagnostics(child)
                return "error"
            kind, value = "idle", b""
        if kind == "error":
            say("the scripted servers' readiness pipe failed: %s" % value)
            return "error"
        if kind == "data":
            buffer.extend(value)
            if len(buffer) > 64:
                say("the scripted servers sent an oversized readiness signal")
                return "error"
            if b"\n" in buffer:
                raw, _, rest = bytes(buffer).partition(b"\n")
                frame = raw[:-1] if raw.endswith(b"\r") else raw
                buffer = bytearray(rest)
                if frame != b"ready":
                    say("the scripted servers sent an invalid readiness signal: %s" % frame.decode("utf-8", "backslashreplace"))
                    return "error"
                if buffer:
                    say("the scripted servers sent extra bytes after readiness")
                    return "error"
        if kind == "eof":
            eof = True
            if buffer:
                say("the scripted servers sent a truncated readiness signal: %s" % bytes(buffer).decode("utf-8", "backslashreplace"))
                return "error"
        code = child.poll()
        if frame is not None:
            if not (srv / "ready").is_file():
                say("the scripted servers signaled readiness without a ready file")
                return "error"
            if code is not None:
                if eof:
                    say("the scripted servers exited before readiness handoff (status %s)" % code)
                    return "error"
            elif expired:
                say("the scripted servers' readiness was not accepted before the startup deadline")
                return "error"
            else:
                return "ready"
        if eof and code is not None:
            log = work / "server.log"
            if log.stat().st_size:
                say("the scripted servers exited before readiness (status %s); server output follows" % code)
                sys.stdout.buffer.write(log.read_bytes())
                sys.stdout.buffer.flush()
            else:
                say("the scripted servers exited silently before readiness (status %s)" % code)
            return "error"
        if eof and not expired:
            time.sleep(min(0.1, remaining))


def client_command(kind, name):
    if kind == "plain" and name == "dns-plain":
        return [str(work / name), SRV], work / (name + ".out"), 180
    if kind == "release" and name == "dns-release":
        return [str(work / name), SRV], work / (name + ".out"), 180
    if kind == "mutation" and name and all(c.isalnum() or c in "_-" for c in name):
        return [str(work / name / "program"), SRV], work / name / "out", 120
    raise ValueError("invalid client request")


def watch_client(command, output_path, bound, body, server):
    deadline = time.monotonic() + bound
    with output_path.open("wb") as output:
        client = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
        try:
            while client.poll() is None:
                if cancelled() or body.poll() is not None or server.poll() is not None:
                    return "cancel"
                if time.monotonic() >= deadline:
                    return "timeout"
                time.sleep(min(0.1, max(0.001, deadline - time.monotonic())))
            return "exit %s" % client.returncode
        finally:
            if not stop(client, time.monotonic() + CLEANUP_SECONDS):
                raise RuntimeError("client cleanup failed")


def run_body(server, deadline):
    if time.monotonic() >= deadline:
        say("the scripted servers' readiness was not accepted before the startup deadline")
        return FAILURE
    if server.poll() is not None:
        say("the scripted servers exited before readiness handoff (status %s)" % server.returncode)
        return FAILURE
    body = subprocess.Popen([BASH, SCRIPT, "--dns-body", WORK, SRV, PYTHON, IYI, REPO, PSEP],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stdout, bufsize=0)
    try:
        events = queue.Queue()
        threading.Thread(target=stream_reader, args=(body.stdout, events), daemon=True).start()
        if time.monotonic() >= deadline:
            say("the scripted servers' readiness was not accepted before the startup deadline")
            return FAILURE
        if server.poll() is not None:
            say("the scripted servers exited before readiness handoff (status %s)" % server.returncode)
            return FAILURE
        body.stdin.write(b"go\n")
        body.stdin.flush()
        pending = bytearray()
        done = False
        closed = False
        drain_deadline = None
        while True:
            if cancelled():
                return 143
            if server.poll() is not None:
                say("the scripted servers exited during the exercise (status %s)" % server.returncode)
                return FAILURE
            code = body.poll()
            if code is not None and code != 0:
                return code
            if code == 0 and closed:
                if done and not pending:
                    return 0
                say("the secure DNS exercise exited without completing its control stream")
                return FAILURE
            if (code is not None or closed) and drain_deadline is None:
                drain_deadline = time.monotonic() + BODY_DRAIN_SECONDS
            if drain_deadline is not None and time.monotonic() >= drain_deadline:
                say("the secure DNS exercise control stream did not drain")
                return FAILURE
            try:
                event, value = events.get(timeout=0.1)
            except queue.Empty:
                continue
            if event == "eof":
                closed = True
                continue
            if event != "data" or closed:
                say("the secure DNS exercise control stream closed unexpectedly")
                return FAILURE
            pending.extend(value)
            if len(pending) > 256:
                say("the secure DNS exercise sent an oversized control request")
                return FAILURE
            if b"\n" not in pending:
                continue
            raw, _, rest = bytes(pending).partition(b"\n")
            if raw.endswith(b"\r"):
                raw = raw[:-1]
            pending = bytearray(rest)
            if raw == b"done" and not pending and not done:
                done = True
                continue
            fields = raw.decode("ascii").split(" ")
            if done or len(fields) != 3 or fields[0] != "run" or pending:
                say("the secure DNS exercise sent an invalid control request")
                return FAILURE
            command, output_path, bound = client_command(fields[1], fields[2])
            reply = watch_client(command, output_path, bound, body, server)
            if reply == "cancel":
                if server.poll() is not None:
                    say("the scripted servers exited during the exercise (status %s)" % server.returncode)
                    return FAILURE
                return 143 if cancelled() else FAILURE
            body.stdin.write((reply + "\n").encode("ascii"))
            body.stdin.flush()
    finally:
        if not stop(body, time.monotonic() + CLEANUP_SECONDS):
            raise RuntimeError("exercise cleanup failed")


def main():
    (work / "supervisor.armed").touch()
    bootstrap = time.monotonic() + SERVER_START_SECONDS
    while not (work / "supervisor.grant").exists():
        if cancelled():
            return 143
        if time.monotonic() >= bootstrap:
            say("Python supervisor grant watchdog expired")
            return FAILURE
        time.sleep(0.05)
    server = None
    verdict = FAILURE
    try:
        with (work / "server.log").open("wb") as output:
            deadline = time.monotonic() + SERVER_START_SECONDS
            server = subprocess.Popen([PYTHON, SERVER, SRV], stdout=subprocess.PIPE, stderr=output, bufsize=0)
            events = queue.Queue()
            threading.Thread(target=stream_reader, args=(server.stdout, events), daemon=True).start()
            outcome = startup(server, events, deadline)
            if outcome == "cancel":
                verdict = 143
            elif outcome == "ready":
                verdict = run_body(server, deadline)
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
  SUPERVISOR_PID=$!
  bootstrap_deadline=$((SECONDS + PYTHON_PREFLIGHT_SECONDS))
  while :; do
    if [ "$CANCEL_STATUS" -ne 0 ]; then exit "$CANCEL_STATUS"; fi
    if ! supervisor_active; then
      supervisor_code=0
      wait "$SUPERVISOR_PID" 2>/dev/null || supervisor_code=$?
      SUPERVISOR_PID=""
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
  : >"$WORK/supervisor.grant"
  supervisor_code=0
  while :; do
    supervisor_code=0
    wait "$SUPERVISOR_PID" || supervisor_code=$?
    if [ "$CANCEL_STATUS" -eq 0 ] || ! supervisor_active; then break; fi
  done
  SUPERVISOR_PID=""
  if [ "$CANCEL_STATUS" -ne 0 ]; then exit "$CANCEL_STATUS"; fi
  exit "$supervisor_code"
fi

status=0
export IYI_PATH="$REPO/src"

# The supervisor owns each client and distinguishes its exit status from
# a watchdog expiry, including a real exit 124 or 137.
run_watched() {
  if ! printf 'run %s %s\n' "$1" "$2" >&4; then
    echo "the secure DNS supervisor could not receive a client request"
    exit 76
  fi
  WATCHED_KIND="" WATCHED_CODE=""
  if ! IFS=' ' read -r WATCHED_KIND WATCHED_CODE <&3; then
    echo "the secure DNS client watchdog gave no verdict"
    exit 76
  fi
  case "$WATCHED_KIND" in
    exit | timeout) ;;
    *) echo "the secure DNS client watchdog gave an invalid verdict"; exit 76 ;;
  esac
}
if [ -f "$SRV/h2.missing" ]; then
  echo "== $(cat "$SRV/h2.missing"): DNS over HTTPS is asked over HTTP/1.1 alone"
fi

# build_and_run <label> <name> [build flags]: the exercise, built and run
# against the servers.
build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_secure_dns_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  run_watched "$label" "$name"
  if [ "$WATCHED_KIND" = timeout ]; then
    echo "$label: client watchdog expired (180 s)"
    exit 76
  fi
  local exit_code="$WATCHED_CODE"
  grep -v '^answer ' "$WORK/$name.out" | sed 's/^/  /'
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  if grep -q "iyi: panic" "$WORK/$name.out"; then
    echo "$label: a panic the program outlived"
    status=1
    return 1
  fi
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
  if ! grep -q "^all checks passed" "$WORK/dns-$mode.out" 2>/dev/null; then
    echo "  $mode: the run did not reach the end"
    status=1
  fi
  missing=""
  for section in $SECTIONS; do
    grep -q "^$section: ok" "$WORK/dns-$mode.out" 2>/dev/null || missing="$missing $section"
  done
  if [ -n "$missing" ]; then
    echo "  $mode: nothing reported for:$missing"
    status=1
  else
    echo "  $mode: all $(echo $SECTIONS | wc -w | tr -d ' ') sections reported ok"
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
if command -v dig >/dev/null 2>&1; then
  timeout -k 5 20 dig -h >"$WORK/dig.help" 2>&1
  dig_status=$?
  if [ "$dig_status" -eq 124 ] || [ "$dig_status" -eq 137 ]; then
    echo "dig help watchdog expired"
    exit 76
  elif [ "$dig_status" -ne 0 ] || ! grep -Eq '^Usage:[[:space:]]+dig[[:space:]]' "$WORK/dig.help"; then
    echo "dig help failed"
    cat "$WORK/dig.help"
    exit 76
  fi
  grep -q '+\[no\]tls ' "$WORK/dig.help" && HAS_TLS=yes
  grep -q '+\[no\]https\[=' "$WORK/dig.help" && HAS_HTTPS=yes
fi
if ! command -v dig >/dev/null 2>&1; then
  echo "  skipped: no dig here, so nothing but the iyi client asks the scripted servers"
elif [ "$HAS_TLS" = no ] && [ "$HAS_HTTPS" = no ]; then
  echo "  skipped: this dig has neither +tls nor +https ($(dig -v 2>&1 | head -1))"
else
  DOT_PORT="$(cat "$SRV/dot.port")"
  # dig checks the certificate when it can read the test root and has the
  # options for it. Ubuntu's AppArmor profile for dig lets it read files
  # under $HOME outside dot directories and nothing else, so a root in a
  # scratch directory answers "TLS context cannot be created" (measured,
  # dig 9.20.24), and an older dig may not know +tls-ca. Either way dig
  # then asks without checking, the sentence says why, and the name is
  # the iyi client's to check (dot_wrong_name, doh_wrong_name).
  VERIFY=(+tls-ca="$SRV/ca.pem" +tls-hostname=dns.test)
  probe=(+tls -p "$DOT_PORT")
  [ "$HAS_TLS" = no ] && probe=(+https -p "$(cat "$SRV/h2.port" 2>/dev/null || echo 1)")
  checked="$(dig "${probe[@]}" "${VERIFY[@]}" @127.0.0.1 a.zone.test A +short +tries=1 +timeout=5 2>&1)"
  if [ "$checked" != "192.0.2.1" ]; then
    echo "  dig asks without checking the certificate: with +tls-ca it said \"$(printf '%s\n' "$checked" | head -1)\""
    VERIFY=()
  else
    echo "  dig checks the certificate for dns.test against the test root"
    # The refusal the iyi client gives wrong.test, dig's too: the server's
    # certificate names dns.test and 127.0.0.1 and nothing else.
    if dig "${probe[@]}" +tls-ca="$SRV/ca.pem" +tls-hostname=wrong.test @127.0.0.1 a.zone.test A +short +tries=1 +timeout=5 2>&1 | grep -q "192.0.2.1"; then
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
  type_probe="$(dig -t HTTPS +short +tries=1 +timeout=5 @127.0.0.1 -p "$(cat "$SRV/udp.port")" svc.zone.test 2>&1)"
  if printf '%s' "$type_probe" | grep -qF 'ignoring invalid type HTTPS'; then
    HAS_HTTPS_TYPE=no
    echo "  HTTPS records skipped: this dig does not know the type ($(dig -v 2>&1 | head -1)): it said \"$(printf '%s' "$type_probe" | head -1)\""
  fi
  asked=0
  differs=0
  over=""
  while read -r _ via type name values; do
    [ "$type" = HTTPS ] && [ "$HAS_HTTPS_TYPE" = no ] && continue
    case "$via" in
      dot) [ "$HAS_TLS" = yes ] || continue; flags=(+tls) port="$DOT_PORT" ;;
      h2) [ "$HAS_HTTPS" = yes ] || continue; flags=(+https) port="$(cat "$SRV/h2.port")" ;;
      h2-get) [ "$HAS_HTTPS" = yes ] || continue; flags=(+https-get) port="$(cat "$SRV/h2.port")" ;;
      *) continue ;;
    esac
    case " $over " in *" ${flags[0]} "*) ;; *) over="$over ${flags[0]}" ;; esac
    got="$(dig "${flags[@]}" ${VERIFY[@]+"${VERIFY[@]}"} @127.0.0.1 -p "$port" "$name" -t "$type" +short +tries=1 +timeout=5 2>&1)"
    # +short: an address a line, a CNAME's target ending in a dot, a TXT
    # record's strings each quoted, an HTTPS record's data in presentation
    # format, which the iyi line holds as `SvcbRecord#to_s` prints it. The
    # iyi line joins a record's strings and separates records with " | ".
    if [ "$type" = TXT ]; then
      said="$(printf '%s\n' "$got" | "$PY" -c 'import sys, shlex; print(" | ".join("".join(shlex.split(line)) for line in sys.stdin.read().splitlines() if line))')"
    elif [ "$type" = HTTPS ]; then
      said="$(printf '%s\n' "$got" | "$PY" -c 'import sys; print(" | ".join(line for line in sys.stdin.read().splitlines() if line))')"
    else
      said="$(printf '%s\n' "$got" | grep -v '\.$' | tr '\n' ' ' | sed 's/ *$//')"
    fi
    asked=$((asked + 1))
    if [ "$said" != "$values" ]; then
      echo "  $via $type $name: iyi read \"$values\", dig \"$said\""
      differs=1
    fi
  done < <(grep '^answer ' "$WORK/dns-plain.out" 2>/dev/null)
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
  [ "$HAS_TLS" = yes ] || echo "  +tls skipped: this dig has no DNS over TLS ($(dig -v 2>&1 | head -1))"
  if [ "$HAS_HTTPS" = no ]; then
    echo "  +https skipped: this dig has no DNS over HTTPS ($(dig -v 2>&1 | head -1))"
  elif [ ! -f "$SRV/h2.port" ]; then
    echo "  +https skipped: there is no HTTP/2 server without the h2 package, and dig speaks DNS over HTTPS over HTTP/2 alone"
  fi
  # The server's padding rule, which the iyi client is held to, held to
  # dig's own padding (+padding, BIND's RFC 7830): a query dig pads to 128
  # passes it, and one dig does not pad is counted unpadded. The first ask
  # starts the server's counts again.
  if [ "$HAS_TLS" = yes ]; then
    pad_ask() {
      dig +tls ${VERIFY[@]+"${VERIFY[@]}"} @127.0.0.1 -p "$DOT_PORT" padding.zone.test TXT +short +tries=1 +timeout=5 "$@" 2>&1
    }
    pad_ask >/dev/null
    padded="$(pad_ask +padding=128)"
    unpadded="$(pad_ask)"
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
  mkdir -p "$WORK/$dir/std"
  FILE1="$4" OLD1="$5" NEW1="$6" FILE2="${7:-}" OLD2="${8:-}" NEW2="${9:-}" "$PY" - <<PY
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
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -o "$WORK/$dir/program" \
       "$REPO/bench/std_secure_dns_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the broken copy did not build"
    sed -n '1,8p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  run_watched mutation "$dir"
  if [ "$WATCHED_KIND" = timeout ]; then
    echo "$label: broken-copy watchdog expired (120 s)"
    exit 76
  fi
  local code="$WATCHED_CODE"
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF -- "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at '$phrase'"
    sed -n '$p' "$WORK/$dir/out"
    status=1
  else
    echo "  $label: caught at \"$(grep -m1 -F -- "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //' | cut -c1-110)\""
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
