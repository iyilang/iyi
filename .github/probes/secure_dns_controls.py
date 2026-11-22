import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(sys.argv[1]).resolve()
SHELL = sys.argv[2]
GATE = (ROOT / "bench/std_secure_dns_exercise.sh").read_text()
SERVER = (ROOT / "bench/std_secure_dns_server.py").read_text()
HELPER = (ROOT / "bench/end_process.sh").read_text()


def once(text, old, new):
    n = text.count(old)
    if n != 1:
        raise RuntimeError("expected one mutation anchor, found %d: %r" % (n, old))
    return text.replace(old, new, 1)


def test(mode):
    with tempfile.TemporaryDirectory(prefix="sdns-review-control-") as temp:
        root = pathlib.Path(temp)
        bench = root / "bench"
        bench.mkdir()
        shell, server = GATE, SERVER
        (bench / "end_process.sh").write_text(HELPER, newline="\n")
        env = os.environ.copy()
        marker = 'if [ -f "$SRV/h2.missing" ]; then\n'
        ready = '    os.write(1, b"ready\\n")\n'
        handoff = '            events = queue.Queue()\n'
        idle = '            kind, value = "idle", b""\n'
        success = {"crlf", "split"}
        if mode in success:
            shell = once(shell, marker, 'echo "fixture body reached"\nprintf "done\\n" >&4\nexit 0\n' + marker)
            shell = once(shell, '        say("the std/secure_dns exercise holds")\n', '        say("fixture supervisor completed")\n')
        if mode == "body-early":
            shell = once(shell, marker, 'echo "fixture body exited early"\nexit 0\n' + marker)
            expected = "the secure DNS exercise exited without completing its control stream"
        elif mode == "silent":
            server = once(server, "\nimport os\n", "\nimport os; os._exit(23)\n")
            expected = "the scripted servers exited silently before readiness (status 23)"
        elif mode == "crash":
            server = once(server, "def main():\n", 'def main():\n    raise RuntimeError("controlled startup crash")\n')
            expected = "the scripted servers exited before readiness (status 1); server output follows"
        elif mode == "hang":
            anchor = '    write(work, "stage", "pki\\n")\n'
            server = once(server, anchor, anchor + '    threading.Event().wait()\n')
            expected = "the scripted servers hung before signaling readiness, at stage: pki"
        elif mode == "import-hang":
            server = once(server, "\nimport base64\n", '\n__import__("threading").Event().wait()\nimport base64\n')
            expected = "the scripted servers hung before signaling readiness, at stage: none"
        elif mode in ("invalid-dead", "invalid-deadline"):
            server = once(server, ready, '    os.write(1, b"wrong\\n"); os._exit(23)\n')
            shell = once(shell, handoff, '            server.wait(timeout=5)\n' + handoff)
            if mode == "invalid-deadline":
                anchor = '            threading.Thread(target=stream_reader, args=(server.stdout, events), daemon=True).start()\n'
                replacement = '            reader = threading.Thread(target=stream_reader, args=(server.stdout, events), daemon=True)\n            reader.start()\n            reader.join(timeout=5)\n            if reader.is_alive(): raise RuntimeError("fixture reader did not finish")\n            deadline = time.monotonic() - 1\n'
                shell = once(shell, anchor, replacement)
            expected = "the scripted servers sent an invalid readiness signal: wrong"
        elif mode == "truncated":
            server = once(server, ready, '    os.write(1, b"rea"); os._exit(23)\n')
            shell = once(shell, handoff, '            server.wait(timeout=5)\n' + handoff)
            expected = "the scripted servers sent a truncated readiness signal: rea"
        elif mode == "ready-dead":
            server = once(server, ready, ready + '    os._exit(23)\n')
            shell = once(shell, handoff, '            server.wait(timeout=5)\n' + handoff)
            expected = "the scripted servers exited before readiness handoff (status 23)"
        elif mode == "late-ready":
            anchor = '            threading.Thread(target=stream_reader, args=(server.stdout, events), daemon=True).start()\n'
            replacement = anchor + '            event = events.get(timeout=5)\n            events.put(event)\n            deadline = time.monotonic() - 1\n'
            shell = once(shell, anchor, replacement)
            expected = "the scripted servers' readiness was not accepted before the startup deadline"
        elif mode == "closed":
            server = once(server, ready, '    os.close(1); threading.Event().wait()\n')
            expected = "the scripted servers hung before signaling readiness, at stage: udp (stdout closed)"
        elif mode == "crlf":
            server = once(server, ready, '    if os.name == "nt": __import__("msvcrt").setmode(1, os.O_BINARY)\n    os.write(1, b"ready\\r\\n")\n')
            expected = "fixture body reached"
        elif mode == "split":
            server = once(server, ready, '    os.write(1, b"rea")\n    while not os.path.exists(os.path.join(work, "split.release")):\n        __import__("time").sleep(0.01)\n    os.write(1, b"dy\\n")\n')
            shell = once(shell, idle, idle + '            if buffer == b"rea":\n                (srv / "split.release").touch()\n')
            expected = "fixture body reached"
        elif mode == "diagnostic":
            anchor = "    commands = []\n"
            shell = once(shell, anchor, '    commands = [[sys.executable, "-c", "import threading; print(\\"partial-diagnostic\\", flush=True); threading.Event().wait()"]]\n')
            shell = once(shell, '    if system == "darwin" or system.startswith("linux"):\n', '    if False:\n')
            anchor = '    write(work, "stage", "pki\\n")\n'
            server = once(server, anchor, anchor + '    threading.Event().wait()\n')
            expected = "startup diagnostics watchdog expired"
        elif mode in ("broken-h2", "broken-h2-self"):
            package = root / "h2"
            package.mkdir()
            (package / "__init__.py").write_text("")
            if mode == "broken-h2":
                (package / "connection.py").write_text('raise ImportError("controlled broken h2")\n')
            else:
                (package / "connection.py").write_text('raise ModuleNotFoundError("controlled broken h2", name="h2")\n')
            env["PYTHONPATH"] = str(root)
            expected = "the scripted servers exited before readiness (status 1); server output follows"
        elif mode == "dependency-self":
            package = root / "cryptography"
            package.mkdir()
            (package / "__init__.py").write_text('raise ModuleNotFoundError("controlled broken cryptography", name="cryptography")\n')
            env["PYTHONPATH"] = str(root)
            expected = "Python dependency preflight failed"
        elif mode == "bootstrap-hang":
            anchor = '    (work / "supervisor.armed").touch()\n'
            shell = once(shell, anchor,
                         '    pathlib.Path(os.environ["SDNS_TEST_SUPERVISOR_PID"]).write_text(str(os.getpid()))\n'
                         '    threading.Event().wait()\n' + anchor)
            env["SDNS_TEST_SUPERVISOR_PID"] = str(root / "supervisor-pid")
            expected = "Python supervisor startup watchdog expired"
        elif mode in ("interpreter-hang", "dependency-hang", "dependency-broken"):
            if mode == "interpreter-hang":
                anchor = '"$candidate" -c \'import sys\''
                shell = once(shell, anchor, '"$candidate" -c \'import threading; threading.Event().wait()\'')
                expected = "Python interpreter startup watchdog expired"
            else:
                start = '  timeout -k 5 "$PYTHON_PREFLIGHT_SECONDS" "$PY" -c \'\n'
                end = '\' >"$WORK/crypto-preflight.log" 2>&1\n'
                if shell.count(start) != 1 or shell.count(end) != 1:
                    raise RuntimeError("dependency preflight anchors moved")
                first = shell.index(start) + len(start)
                last = shell.index(end, first)
                program = 'raise ImportError("controlled broken dependency")' if mode == "dependency-broken" else "import threading; threading.Event().wait()"
                shell = shell[:first] + program + "\n" + shell[last:]
                expected = "Python dependency preflight failed" if mode == "dependency-broken" else "Python dependency preflight watchdog expired"
        elif mode in ("dig-broken", "dig-junk"):
            shell = once(shell, 'for mode in plain release; do\n', 'for mode in ; do\n')
            shell = once(shell, 'HAS_TLS=no\n', 'dig() { :; }\nHAS_TLS=no\n')
            anchor = '  timeout -k 5 20 dig -h >"$WORK/dig.help" 2>&1\n'
            program = 'import sys; print("controlled broken dig"); sys.exit(%s)' % ("1" if mode == "dig-broken" else "0")
            shell = once(shell, anchor, '  timeout -k 5 20 "$PY" -c ' + repr(program) + ' >"$WORK/dig.help" 2>&1\n')
            expected = "dig help failed"
        elif mode in ("plain-timeout", "release-timeout", "exit-124", "exit-137"):
            env["IYI"] = "true"
            selected = "release" if mode.startswith("release") else "plain"
            name = "dns-release" if selected == "release" else "dns-plain"
            anchor = '    if kind == "' + selected + '" and name == "' + name + '":\n        return [str(work / name), SRV], work / (name + ".out"), 180\n'
            if mode.endswith("timeout"):
                program = 'import threading; threading.Event().wait()'
                bound = "0.5"
                expected = ("release" if mode.startswith("release") else "plain") + ": client watchdog expired (180 s)"
            else:
                number = mode.split("-")[-1]
                program = "import sys; sys.exit(%s)" % number
                bound = "5"
                expected = "plain: exited " + number
            replacement = '    if kind == "' + selected + '" and name == "' + name + '":\n        return [PYTHON, "-c", ' + repr(program) + '], work / (name + ".out"), ' + bound + '\n'
            shell = once(shell, anchor, replacement)
            if mode == "release-timeout":
                shell = once(shell, 'for mode in plain release; do\n', 'for mode in release; do\n')
            if mode.startswith("exit-"):
                anchor = '    build_and_run "plain" dns-plain\n'
                shell = once(shell, anchor, anchor + '    exit $?\n')
        elif mode == "mutation-timeout":
            env["IYI"] = "true"
            (root / "src/std").mkdir(parents=True)
            shutil.copy2(ROOT / "src/std/secure_dns.iyi", root / "src/std/secure_dns.iyi")
            start = 'SECTIONS="wire wire_padding '
            end = 'breaks() {\n'
            if shell.count(start) != 1 or shell.count(end) != 1:
                raise RuntimeError("mutation-control region anchors moved")
            shell = shell[:shell.index(start)] + shell[shell.index(end):]
            anchor = '        return [str(work / name / "program"), SRV], work / name / "out", 120\n'
            program = 'import threading; print("a server whose certificate does not name wrong.test", flush=True); threading.Event().wait()'
            shell = once(shell, anchor, '        return [PYTHON, "-c", ' + repr(program) + '], work / name / "out", 0.5\n')
            expected = "the server's name not verified: broken-copy watchdog expired (120 s)"
        else:
            raise RuntimeError("unknown mode " + mode)
        server_live_modes = {"body-early", "late-ready", "hang", "import-hang", "closed", "diagnostic", "crlf", "split", "dig-broken", "dig-junk", "plain-timeout", "release-timeout", "mutation-timeout", "exit-124", "exit-137"}
        client_timeout_modes = {"plain-timeout", "release-timeout", "mutation-timeout"}
        if mode in server_live_modes:
            env["SDNS_TEST_SERVER_REAPED"] = str(root / "server-reaped")
            env["SDNS_TEST_CLIENT_REAPED"] = str(root / "client-reaped")
            anchor = '        return True\n    except ProcessLookupError:\n'
            replacement = '        if len(child.args) > 1 and child.args[1] == SERVER:\n            pathlib.Path(os.environ["SDNS_TEST_SERVER_REAPED"]).write_text("reaped")\n        elif len(child.args) > 1 and child.args[1] == "-c":\n            pathlib.Path(os.environ["SDNS_TEST_CLIENT_REAPED"]).write_text("reaped")\n' + anchor
            shell = once(shell, anchor, replacement)
        (bench / "std_secure_dns_exercise.sh").write_text(shell, newline="\n")
        (bench / "std_secure_dns_server.py").write_text(server, newline="\n")
        output = root / "fixture-output.log"
        pid = None
        handle = None
        try:
            with output.open("wb") as log:
                process = subprocess.Popen([SHELL, (bench / "std_secure_dns_exercise.sh").as_posix()], env=env,
                                           stdout=log, stderr=subprocess.STDOUT)
                if mode == "bootstrap-hang":
                    deadline = time.monotonic() + 40
                    marker = root / "supervisor-pid"
                    while time.monotonic() < deadline and process.poll() is None:
                        text = marker.read_text().strip() if marker.exists() else ""
                        if text.isdigit():
                            pid = int(text)
                            break
                        time.sleep(0.05)
                    if pid is None:
                        raise RuntimeError("bootstrap supervisor did not publish its PID")
                    if os.name == "nt":
                        import ctypes
                        from ctypes import wintypes
                        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
                        kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
                        kernel.OpenProcess.restype = wintypes.HANDLE
                        kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
                        kernel.WaitForSingleObject.restype = wintypes.DWORD
                        kernel.TerminateProcess.argtypes = (wintypes.HANDLE, wintypes.UINT)
                        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
                        handle = kernel.OpenProcess(0x100001, False, pid)
                        if not handle:
                            raise ctypes.WinError(ctypes.get_last_error())
                returncode = process.wait(timeout=80)
                if pid is not None:
                    if os.name == "nt":
                        if kernel.WaitForSingleObject(handle, 0) != 0:
                            raise RuntimeError("bootstrap supervisor PID %s survived cleanup" % pid)
                    else:
                        try:
                            os.kill(pid, 0)
                        except ProcessLookupError:
                            pass
                        else:
                            raise RuntimeError("bootstrap supervisor PID %s survived cleanup" % pid)
                    print("bootstrap supervisor PID %s is gone" % pid, flush=True)
        except subprocess.TimeoutExpired as error:
            print(output.read_text(errors="replace"), flush=True)
            raise RuntimeError("%s: fixture watchdog expired" % mode) from error
        finally:
            # Retain the native handle while checking and, on a failed
            # control, terminate only the supervisor whose PID we captured.
            if handle:
                if kernel.WaitForSingleObject(handle, 0) != 0:
                    kernel.TerminateProcess(handle, 1)
                    kernel.WaitForSingleObject(handle, 5000)
                kernel.CloseHandle(handle)
            if "process" in locals() and process.poll() is None:
                if pid is not None and os.name != "nt":
                    try:
                        os.kill(pid, 9)
                    except ProcessLookupError:
                        pass
                process.kill()
                process.wait(timeout=5)
        captured = output.read_text(errors="replace")
        lines = captured.splitlines()
        status = 0 if mode in success else (1 if mode.startswith("exit-") else 76)
        print("=== %s status=%s ===" % (mode, returncode), flush=True)
        print(captured, flush=True)
        if returncode != status or lines.count(expected) != 1:
            raise RuntimeError("%s: expected status %s and exactly one %r" % (mode, status, expected))
        if "supervisor cleanup is unconfirmed" in captured:
            raise RuntimeError("supervisor cleanup was not confirmed")
        if mode in server_live_modes and (root / "server-reaped").read_text() != "reaped":
            raise RuntimeError("server was not reaped by its supervisor")
        if mode in client_timeout_modes and (root / "client-reaped").read_text() != "reaped":
            raise RuntimeError("timed-out client was not reaped by its supervisor")
        if mode in success and lines.count("fixture supervisor completed") != 1:
            raise RuntimeError("fixture did not complete its supervisor handoff")
        if mode == "crash" and "RuntimeError: controlled startup crash" not in captured:
            raise RuntimeError("crash traceback missing")
        if mode in ("broken-h2", "broken-h2-self") and "controlled broken h2" not in captured:
            raise RuntimeError("broken h2 traceback missing")
        if mode in ("hang", "import-hang", "closed", "diagnostic") and "Timeout (0:00:15)!" not in captured:
            raise RuntimeError("server traceback timer did not report")
        if mode in ("hang", "import-hang", "closed"):
            if sys.platform == "darwin" and "Call graph:" not in captured:
                raise RuntimeError("native Darwin sample call graph missing")
            if (sys.platform == "darwin" or sys.platform.startswith("linux")) and "== startup diagnostics: ps" not in lines:
                raise RuntimeError("startup process diagnostics missing")
        if mode == "diagnostic" and (lines.count("partial-diagnostic") != 1 or lines.count("the scripted servers hung before signaling readiness, at stage: pki") != 1):
            raise RuntimeError("partial diagnostic output or stage verdict missing")
        if mode not in success and "fixture body reached" in lines:
            raise RuntimeError("body ran after failed startup")
        if "the std/secure_dns exercise holds" in lines:
            raise RuntimeError("a fixture was mistaken for a full gate pass")
        if mode == "mutation-timeout" and "caught at" in captured:
            raise RuntimeError("timeout was counted as a catch")
        if mode.startswith("exit-") and "watchdog expired" in captured:
            raise RuntimeError("natural exit was mistaken for a timeout")


if __name__ == "__main__":
    modes = sys.argv[3:] or ["body-early", "silent", "crash", "hang", "import-hang", "invalid-dead", "invalid-deadline", "truncated", "ready-dead", "late-ready", "closed", "crlf", "split", "diagnostic", "broken-h2", "broken-h2-self", "bootstrap-hang", "interpreter-hang", "dependency-hang", "dependency-broken", "dependency-self", "dig-broken", "dig-junk", "plain-timeout", "release-timeout", "mutation-timeout", "exit-124", "exit-137"]
    for mode in modes:
        test(mode)
