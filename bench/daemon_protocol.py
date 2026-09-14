#!/usr/bin/env python3
"""What the build daemon does when a client is not a client.

    make iyi iyi-daemon
    python3 bench/daemon_protocol.py

A daemon is a process other processes depend on, and the whole reason to run
one is that it holds an analysed prelude nobody else has to pay for
(SPEC.md IV.1d). Killing it is therefore not a small failure: it is everyone's
failure, and the next build after it pays the second back.

Every case below used to kill it. `daemon_accept` read the request frame with
no rescue at all, so anything that could go wrong on a socket the daemon does
not own the far end of went wrong all the way out of the accept loop:

  * a client that connects and closes - `iyi daemon build` under Ctrl-C, a
    health check, anything that probes the socket - was `End of file reached`,
    exit 1;
  * a length header with no body behind it, likewise;
  * a body that is not JSON was a `JSON::ParseException` with a stack trace;
  * a 4 GB length header was `Bytes.new(4294967295)`, an `OverflowError`
    through the allocator;
  * a request missing `cwd` was `Missing hash key: "cwd"`, a `KeyError`;
  * and a refusal written to a client that had already hung up was EPIPE,
    which `Command#run` turns into `::exit 0` because that is the right
    answer for `mod dump | head` and the wrong one for a server. The daemon
    exited *successfully*, mid-sentence, and the next client got
    "no daemon listening".

The ninth case is the other direction: a second `iyi daemon start` on a live
socket used to `File.delete?` the incumbent's address and listen on a new
socket with the same name. The first daemon kept running - a compiler and a
warm prelude behind a socket with no name, unreachable and unreapable.

The rule this gate holds the daemon to: one client's mistake is one client's
mistake. The daemon may refuse, log, and close that connection, and must be
serving the next one.
"""

import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IYI = os.path.join(REPO, "bin", "iyi")
WORK = tempfile.mkdtemp(prefix="iyi-daemon-protocol")
SOURCE = os.path.join(WORK, "ok.iyi")
FAILURES = []


def step(name, ok, note=""):
    print("daemon %-4s %s %s" % ("ok" if ok else "FAIL", name, note))
    if not ok:
        FAILURES.append(name)


def start(sock):
    """A daemon listening on *sock*, banner already printed.

    The socket file appears about a second before the banner does - the
    prelude is analysed between them - so a gate that only waits for the
    file can terminate the daemon with its first two lines still in the
    buffer, and then read an empty log. Waiting for the second banner
    line leaves the log holding exactly what the cases below put in it.
    """
    proc = subprocess.Popen([IYI, "daemon", "start", "--socket", sock],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True)
    for _ in range(600):
        if os.path.exists(sock):
            break
        if proc.poll() is not None:
            sys.exit("the daemon would not start: " + proc.stderr.read())
        time.sleep(0.1)
    else:
        proc.kill()
        sys.exit("the daemon never listened on " + sock)

    for _ in range(4):
        line = proc.stderr.readline()
        if not line:
            sys.exit("the daemon closed its log before it was ready")
        if "prelude analysed" in line:
            return proc
    proc.kill()
    sys.exit("the daemon never said it was ready")


def stop(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()


def builds(sock, tag):
    """True when the daemon on *sock* still compiles a program."""
    try:
        done = subprocess.run(
            [IYI, "daemon", "build", "--socket", sock,
             "-o", os.path.join(WORK, "out-%s" % tag), SOURCE],
            capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return False, "the daemon stopped answering"
    if done.returncode != 0:
        return False, (done.stdout + done.stderr).strip().splitlines()[:1]
    return True, ""


def speak(sock, payload):
    """Send raw bytes and hang up, the way a broken client does."""
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(10)
    client.connect(sock)
    if payload:
        client.sendall(payload)
    client.close()


def main():
    with open(SOURCE, "w") as handle:
        handle.write('module main\n\nputs "compiled by a daemon"\n')

    request = json.dumps({"cwd": "/tmp", "args": ["build"]}).encode()
    shapeless = json.dumps({"hello": "world"}).encode()
    mismatch = json.dumps({"cwd": WORK, "args": ["build", "-o",
                                                 os.path.join(WORK, "m"), SOURCE],
                           "version": "iyi 0.0.0-from-another-build"}).encode()
    junk = b"this is not json {{{"

    cases = [
        ("a client that connects and says nothing", b""),
        ("a length header with no body", struct.pack("<I", 64)),
        ("half a length header", b"\x40\x00"),
        ("a body shorter than its header", struct.pack("<I", len(request) + 500) + request),
        ("a body that is not JSON", struct.pack("<I", len(junk)) + junk),
        ("a 4 GB length header", struct.pack("<I", 0xFFFFFFFF)),
        ("a request with no cwd", struct.pack("<I", len(shapeless)) + shapeless),
        ("a client from another build", struct.pack("<I", len(mismatch)) + mismatch),
    ]

    # One daemon for all of them, in order: a gate that restarts between
    # cases cannot see the damage one case does to the next, and "the
    # daemon is still the same daemon" is most of the claim.
    sock = os.path.join(WORK, "d.sock")
    daemon = start(sock)
    ok, note = builds(sock, "first")
    step("a daemon that serves before any of this", ok, note)

    for index, (name, payload) in enumerate(cases):
        try:
            speak(sock, payload)
        except OSError as exc:
            step(name, False, "the socket was already gone: %s" % exc)
            continue
        time.sleep(0.2)
        ok, note = builds(sock, str(index))
        alive = daemon.poll() is None
        step(name, ok and alive,
             "" if ok and alive else "daemon exit=%s %s" % (daemon.poll(), note))
        if not alive:
            break

    if daemon.poll() is None:
        # A second daemon must not take the socket out from under the first.
        second = subprocess.run([IYI, "daemon", "start", "--socket", sock],
                                capture_output=True, text=True, timeout=120)
        said = (second.stdout + second.stderr).strip()
        step("a second daemon on a live socket",
             second.returncode == 1 and "already listening" in said,
             repr(said[:120]))
        ok, note = builds(sock, "after-second")
        step("the first daemon still has its socket", ok, note)

    stop(daemon)
    log = (daemon.stderr.read() or "")
    # A client that starts a frame and abandons it is worth one line: the
    # daemon kept serving, and the next person to read the log should be
    # able to see that something out there is speaking badly.
    step("an abandoned frame is logged",
         log.count("a client sent no usable request") >= 4,
         repr(log[-160:]))

    # And the other side of that: `daemon start` asks "is anyone home?" by
    # connecting, and a client killed before its first byte looks exactly
    # the same. Neither is a fault, so neither may fill the log of a daemon
    # that runs for days. Its own daemon, because the frames above log the
    # very line this one must not find.
    quiet_sock = os.path.join(WORK, "quiet.sock")
    quiet = start(quiet_sock)
    speak(quiet_sock, b"")
    time.sleep(0.3)
    ok, note = builds(quiet_sock, "quiet")
    step("a silent connection leaves the daemon serving", ok, note)
    stop(quiet)
    quiet_log = (quiet.stderr.read() or "")
    step("a connection that says nothing is not logged as a fault",
         "no usable request" not in quiet_log, repr(quiet_log[-160:]))

    # A socket file with nothing behind it is the ordinary aftermath of a
    # killed daemon, and starting must take it over rather than refuse.
    stale = os.path.join(WORK, "stale.sock")
    holder = socket.socket(socket.AF_UNIX)
    holder.bind(stale)
    holder.close()
    revived = start(stale)
    ok, note = builds(stale, "stale")
    step("a stale socket file is taken over, not refused", ok, note)
    stop(revived)

    if FAILURES:
        sys.exit("daemon protocol: %s" % FAILURES)
    print("daemon protocol gate: one client's mistake is one client's mistake")


if __name__ == "__main__":
    main()
