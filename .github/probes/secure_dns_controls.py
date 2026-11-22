"""Startup, stage and cleanup controls for bench/std_secure_dns_exercise.sh.

A manual probe, not run by CI. Each control copies the gate and the scripted
server into a scratch tree, breaks one mechanism through an exact-once anchor,
runs the gate, and asserts the exact sentence and status that mechanism must
produce. Run it from the repository root, once for each Bash that runs the gate:

    python3 .github/probes/secure_dns_controls.py "$PWD" "$(command -v bash)"

Mode names after the Bash run a subset. It stays out of the workflows because a
full run takes minutes on each runner: the earlier 48-control set took 101 s on
Linux, 228 s on macOS per Bash and 123 s on Windows.
"""
import os
import pathlib
import shutil
import shlex
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


def between(text, start, end, replacement):
    if text.count(start) != 1 or text.count(end) != 1:
        raise RuntimeError("expected one of each region anchor: %r, %r" % (start, end))
    first = text.index(start) + len(start)
    last = text.index(end, first)
    return once(text, text[first:last], replacement)


def without_comparisons(shell):
    start, end = 'SECTIONS="wire wire_padding ', 'breaks() {\n'
    if shell.count(start) != 1 or shell.count(end) != 1:
        raise RuntimeError("mutation-control region anchors moved")
    return once(shell, shell[shell.index(start):shell.index(end)], "")


def tool_program(evidence):
    # The marker is created only after the evidence has reached the log.
    return (
        'import os, pathlib, sys, threading\n'
        'if os.name != "nt":\n'
        '    closed = []\n'
        '    for fd in (3, 4):\n'
        '        try: os.fstat(fd)\n'
        '        except OSError: closed.append(fd)\n'
        '    fd_state = "control fds closed" if closed == [3, 4] else "control fds open"\n'
        'else:\n'
        '    fd_state = "native Windows tool"\n'
        'print("discarded-evidence-prefix", flush=True)\n'
        'print("X" * 20000, flush=True)\n'
        'print(fd_state, flush=True)\n'
        'print(%r, flush=True)\n' % evidence +
        'stop = pathlib.Path(os.environ["SDNS_TEST_FIXTURE_STOP"])\n'
        'if stop.exists(): sys.exit(0)\n'
        'pathlib.Path(os.environ["SDNS_TEST_TOOL_FDS"]).write_text(fd_state)\n'
        'pid_path = pathlib.Path(os.environ["SDNS_TEST_TOOL_PID"])\n'
        'pid_path.with_suffix(".tmp").write_text(str(os.getpid()))\n'
        'pid_path.with_suffix(".tmp").replace(pid_path)\n'
        'opened = pathlib.Path(os.environ["SDNS_TEST_TOOL_OPENED"])\n'
        'while not opened.exists() and not stop.exists():\n'
        '    threading.Event().wait(0.01)\n'
        'while not stop.exists():\n'
        '    threading.Event().wait(0.01)\n'
    )


def open_handle(pid):
    if os.name != "nt":
        return None
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
    return kernel, handle


def gone(pid, native):
    if native is not None:
        kernel, handle = native
        return kernel.WaitForSingleObject(handle, 0) == 0
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    if sys.platform.startswith("linux"):
        try:
            stat = pathlib.Path("/proc/%s/stat" % pid).read_text()
        except FileNotFoundError:
            return True
        # The command in parentheses can contain spaces.
        return stat[stat.rfind(")") + 2:].split()[0] in ("Z", "X")
    return False


def hold_bash_deadlines(shell):
    # A bash-side watchdog starts only after the fixture has opened, so a
    # preflight or the bootstrap wait cannot expire before the fixture runs.
    shell = once(shell, "PYTHON_PREFLIGHT_SECONDS=20\n", "PYTHON_PREFLIGHT_SECONDS=1\n")
    shell = once(shell, '      if [ "$SECONDS" -ge "$end" ]; then\n',
                 '      if [ ! -e "$SDNS_TEST_TOOL_OPENED" ]; then end=$((SECONDS + seconds)); fi\n'
                 '      if [ "$SECONDS" -ge "$end" ]; then\n')
    return once(shell, '    if [ "$SECONDS" -ge "$bootstrap_deadline" ]; then\n',
                '    if [ ! -e "$SDNS_TEST_TOOL_OPENED" ]; then bootstrap_deadline=$((SECONDS + PYTHON_PREFLIGHT_SECONDS)); fi\n'
                '    if [ "$SECONDS" -ge "$bootstrap_deadline" ]; then\n')


VERDICT_PREFIXES = ("the scripted servers", "the secure DNS", "Python ", "the std/secure_dns", "cannot ")


def verdict_alternatives(mode, expected):
    # The verdict-level lines a control may print, in order. Any other line
    # that starts like a verdict is a stray sentence and fails the control.
    if mode == "bootstrap-hang":
        return [["Python supervisor startup watchdog expired",
                 "the secure DNS supervisor did not stop during cleanup"]]
    if mode == "diagnostic":
        return [["the scripted servers hung before signaling readiness, at stage: pki"]]
    texts = (expected,) if isinstance(expected, str) else expected
    return [[text] for text in texts]


def test(mode):
    with tempfile.TemporaryDirectory(prefix="sdns-review-control-") as temp:
        root = pathlib.Path(temp)
        bench = root / "bench"
        bench.mkdir()
        shell, server = GATE, SERVER
        (bench / "end_process.sh").write_text(HELPER, newline="\n")
        env = os.environ.copy()
        marker = 'if [ -f "$SRV/h2.missing" ]; then\n'
        ready = '    write(work, "ready", "ready\\n")\n'
        success = {"queued-frames"}
        if mode == "queued-frames":
            body = ('echo "fixture body reached"\n'
                    'printf "stage 1 - queued fixture\\ndone\\n" >&4\n'
                    'exit 0\n')
            anchor = '    threading.Thread(target=stream_reader, args=(body.stdout, events), daemon=True).start()\n'
            grouped = ('    def grouped_fixture_reader():\n'
                       '        data = b""\n'
                       '        while not data.endswith(b"exit 0\\n"):\n'
                       '            chunk = os.read(body.stdout.fileno(), 4096)\n'
                       '            if not chunk:\n'
                       '                break\n'
                       '            data += chunk\n'
                       '        events.put(("data", data))\n'
                       '        events.put(("eof", b""))\n'
                       '    threading.Thread(target=grouped_fixture_reader, daemon=True).start()\n')
            shell = once(shell, anchor, grouped)
            shell = once(shell, marker, body + marker)
            shell = once(shell, '        say("the std/secure_dns exercise holds")\n', '        say("fixture supervisor completed")\n')
            expected = "fixture body reached"
        elif mode == "body-early":
            shell = once(shell, marker, 'echo "fixture body exited early"\nexit 0\n' + marker)
            expected = "the secure DNS exercise exited without completing its control stream"
        elif mode in ("silent", "arm-after-death"):
            server = once(server, "\nimport os\n", "\nimport os; os._exit(23)\n")
            if mode == "arm-after-death":
                # The supervisor arms, starts its server, sees it exit and leaves
                # before bash reads the process table for the first time. Holding
                # bash until its own table reports the job gone fixes that order.
                shell = once(shell, "  bootstrap_deadline=$((SECONDS + PYTHON_PREFLIGHT_SECONDS))\n",
                             "  until ! owned_active; do command sleep 0.05; done\n"
                             "  bootstrap_deadline=$((SECONDS + PYTHON_PREFLIGHT_SECONDS))\n")
            expected = "the scripted servers exited silently before readiness (status 23)"
        elif mode == "crash":
            server = once(server, "def main():\n",
                          'def main():\n'
                          '    sys.stderr.write("discarded-crash-prefix\\n" + "C" * 20000 + "\\n")\n'
                          '    raise RuntimeError("controlled startup crash")\n')
            expected = "the scripted servers exited before readiness (status 1); server output follows"
        elif mode == "hang":
            server = once(server, "faulthandler.dump_traceback_later(15, exit=False)",
                          "faulthandler.dump_traceback_later(0.5, exit=False)")
            anchor = '    write(work, "stage", "pki\\n")\n'
            stall = (
                '    while b"Timeout (" not in open(os.path.join(os.path.dirname(work), "server.log"), "rb").read():\n'
                '        threading.Event().wait(0.01)\n'
                '    print("fixture stall at pki", file=sys.stderr, flush=True)\n'
                '    open(os.path.join(work, "fixture.armed"), "w").close()\n'
                '    threading.Event().wait()\n'
            )
            server = once(server, anchor, anchor + stall)
            expected = "the scripted servers hung before signaling readiness, at stage: pki"
        elif mode == "import-hang":
            stall = (
                '\nprint("fixture stall during import", file=__import__("sys").stderr, flush=True)\n'
                'open(os.path.join(__import__("sys").argv[1], "fixture.armed"), "w").close()\n'
                '__import__("threading").Event().wait()\nimport base64\n'
            )
            server = once(server, "\nimport base64\n", stall)
            expected = "the scripted servers hung before signaling readiness, at stage: none"
        elif mode == "ready-dead":
            server = once(server, ready, ready + '    os._exit(23)\n')
            # Whether the supervisor accepts the ready file before the exit is
            # a race; either order must end in a named status 76 failure.
            expected = ("the scripted servers exited during the exercise (status 23)",
                        "the scripted servers exited before readiness was accepted (status 23)")
        elif mode == "diagnostic":
            program = ('import threading; print("discarded-diagnostic-prefix", flush=True); '
                       'print("D" * 20000, flush=True); print("partial-diagnostic", flush=True); '
                       'threading.Event().wait()')
            anchor = "    commands = []\n"
            shell = once(shell, anchor, '    commands = [[sys.executable, "-c", ' + repr(program) + ']]\n')
            shell = once(shell, '    if system == "darwin" or system.startswith("linux"):\n', '    if False:\n')
            anchor = '    write(work, "stage", "pki\\n")\n'
            server = once(server, anchor, anchor +
                          '    print("fixture diagnostic stall", file=sys.stderr, flush=True)\n'
                          '    open(os.path.join(work, "fixture.armed"), "w").close()\n'
                          '    threading.Event().wait()\n')
            expected = "startup diagnostics watchdog expired"
        elif mode == "broken-h2":
            package = root / "h2"
            package.mkdir()
            (package / "__init__.py").write_text("")
            (package / "connection.py").write_text('raise ImportError("controlled broken h2")\n')
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
                         '    while not pathlib.Path(os.environ["SDNS_TEST_FIXTURE_STOP"]).exists():\n'
                         '        threading.Event().wait(0.01)\n' + anchor)
            env["SDNS_TEST_SUPERVISOR_PID"] = str(root / "supervisor-pid")
            shell = hold_bash_deadlines(shell)
            expected = "Python supervisor startup watchdog expired"
        elif mode == "bootstrap-exit":
            anchor = '    (work / "supervisor.armed").touch()\n'
            shell = once(shell, anchor, '    sys.exit(23)\n' + anchor)
            expected = "Python supervisor exited before arming (status 23)"
        elif mode in ("interpreter-hang", "interpreter-exit-124", "interpreter-exit-137",
                      "dependency-hang", "dependency-broken", "dependency-exit-124", "dependency-exit-137"):
            if mode.startswith("interpreter-"):
                program = (tool_program("fixture interpreter preflight evidence") if mode.endswith("hang")
                           else "import sys; sys.exit(%s)" % mode.rsplit("-", 1)[1])
                anchor = '"$candidate" -c \'import sys\''
                shell = once(shell, anchor, '"$candidate" -c ' + shlex.quote(program))
                expected = ("Python interpreter startup watchdog expired" if mode.endswith("hang")
                            else "Python interpreter preflight failed")
            else:
                start = '  bounded "$PYTHON_PREFLIGHT_SECONDS" "$WORK/crypto-preflight.log" "$PY" -c '
                end = '\n  case "$BOUNDED" in\n'
                if mode.endswith("hang"):
                    program = tool_program("fixture dependency preflight evidence")
                elif mode == "dependency-broken":
                    program = 'raise ImportError("controlled broken dependency")'
                else:
                    program = "import sys; sys.exit(%s)" % mode.rsplit("-", 1)[1]
                shell = between(shell, start, end, shlex.quote(program) + ' || exit "$CANCEL_STATUS"')
                expected = ("Python dependency preflight watchdog expired" if mode.endswith("hang")
                            else "Python dependency preflight failed")
            if mode.endswith("hang"):
                shell = hold_bash_deadlines(shell)
        elif mode in ("build-hang", "mutation-build-hang", "mutation-patch-hang",
                      "dig-hang", "dig-query-hang", "dig-version-hang",
                      "gap-hang", "gap-evidence-hang", "server-exit-tool"):
            program = tool_program("fixture %s partial evidence" % mode)
            if mode in ("build-hang", "server-exit-tool"):
                anchor = '  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_secure_dns_exercise.iyi" \\\n'
                shell = once(shell, anchor, '  if ! "$PY" -c ' + shlex.quote(program) + ' \\\n')
                if mode == "build-hang":
                    shell = once(shell, "BUILD_SECONDS=300\n", "BUILD_SECONDS=1\n")
                    expected = "plain: build watchdog expired (1 s)"
                else:
                    anchor = '                stage_deadline = time.monotonic() + stage_seconds\n'
                    shell = once(shell, anchor, anchor +
                                 '                if stage_label == "plain: build":\n'
                                 '                    (srv / "stage.armed").touch()\n')
                    anchor = '    faulthandler.cancel_dump_traceback_later()\n'
                    server = once(server, anchor, anchor +
                                  '    while not (os.path.exists(os.environ["SDNS_TEST_TOOL_OPENED"]) and\n'
                                  '               os.path.exists(os.path.join(work, "stage.armed"))):\n'
                                  '        threading.Event().wait(0.01)\n'
                                  '    os._exit(23)\n')
                    expected = "the scripted servers exited during the exercise (status 23)"
            elif mode in ("mutation-build-hang", "mutation-patch-hang"):
                (root / "src/std").mkdir(parents=True)
                shutil.copy2(ROOT / "src/std/secure_dns.iyi", root / "src/std/secure_dns.iyi")
                shell = without_comparisons(shell)
                shell = once(shell, "BUILD_SECONDS=300\n", "BUILD_SECONDS=1\n")
                if mode == "mutation-patch-hang":
                    anchor = '"$PY" - >"$WORK/$dir/patch.log"'
                    shell = once(shell, anchor,
                                 '"$PY" -c ' + shlex.quote(program) + ' >"$WORK/$dir/patch.log"')
                    expected = "the server's name not verified: patch watchdog expired (1 s)"
                else:
                    anchor = ('  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -o "$WORK/$dir/program" \\\n'
                              '       "$REPO/bench/std_secure_dns_exercise.iyi"')
                    shell = once(shell, anchor, '  if ! "$PY" -c ' + shlex.quote(program))
                    expected = "the server's name not verified: build watchdog expired (1 s)"
            elif mode in ("dig-hang", "dig-query-hang", "dig-version-hang"):
                shell = once(shell, 'for mode in plain release; do\n', 'for mode in ; do\n')
                shell = once(shell, "DIG_SECONDS=30\n", "DIG_SECONDS=1\n")
                if mode == "dig-hang":
                    shell = once(shell, 'HAS_TLS=no\n', 'dig() { :; }\nHAS_TLS=no\n')
                    anchor = '  dig -h >"$WORK/dig.help" 2>&1 </dev/null 3<&- 4>&-\n'
                    shell = once(shell, anchor,
                                 '  "$PY" -c ' + shlex.quote(program) + ' >"$WORK/dig.help" 2>&1 </dev/null 3<&- 4>&-\n')
                    expected = "dig help watchdog expired (1 s)"
                else:
                    help_text = "Usage: dig [options]\n +[no]short\n"
                    if mode == "dig-query-hang":
                        help_text += " +[no]tls \n"
                    fake = ('dig() {\n'
                            '  if [ "$1" = "-h" ]; then printf %s ' + shlex.quote(help_text) + '; return 0; fi\n'
                            '  "$PY" -c ' + shlex.quote(program) + '\n'
                            '}\nHAS_TLS=no\n')
                    shell = once(shell, 'HAS_TLS=no\n', fake)
                    expected = ("dig certificate watchdog expired (1 s)" if mode == "dig-query-hang"
                                else "dig version watchdog expired (1 s)")
            else:
                command = ('"$PY" -c ' + shlex.quote(program) +
                           ' >"$WORK/gap.log" 2>&1 </dev/null 3<&- 4>&-\n')
                if mode == "gap-hang":
                    # The initial stage has no evidence file, so the server log
                    # must not be printed in its place.
                    shell = once(shell, "STAGE_SECONDS = 60\n", "STAGE_SECONDS = 1\n")
                    command = 'printf "unrelated server output\\n" >>"$WORK/server.log"\n' + command
                    expected = "the secure DNS exercise watchdog expired (1 s)"
                else:
                    command = 'stage 1 gap.log "fixture gap"\n' + command
                    expected = "fixture gap watchdog expired (1 s)"
                shell = once(shell, marker, command + marker)
            if mode != "server-exit-tool":
                # The watchdog may start only after the fixture process is
                # alive and its native handle has been retained.
                anchor = '                remaining = stage_deadline - time.monotonic()\n'
                shell = once(shell, anchor,
                             '                if not pathlib.Path(os.environ["SDNS_TEST_TOOL_OPENED"]).exists():\n'
                             '                    stage_deadline = time.monotonic() + 1\n' + anchor)
        elif mode in ("dig-broken", "dig-junk", "dig-usage-only"):
            shell = once(shell, 'for mode in plain release; do\n', 'for mode in ; do\n')
            shell = once(shell, 'HAS_TLS=no\n', 'dig() { :; }\nHAS_TLS=no\n')
            anchor = '  dig -h >"$WORK/dig.help" 2>&1 </dev/null 3<&- 4>&-\n'
            output_text = "Usage: dig [@server] name [type]" if mode == "dig-usage-only" else "controlled broken dig"
            program = 'import sys; print(%r); sys.exit(%s)' % (output_text, "1" if mode == "dig-broken" else "0")
            shell = once(shell, anchor, '  "$PY" -c ' + shlex.quote(program) + ' >"$WORK/dig.help" 2>&1 </dev/null 3<&- 4>&-\n')
            expected = "dig help failed"
        elif mode in ("plain-timeout", "release-timeout", "exit-124", "exit-137"):
            env["IYI"] = "true"
            selected = "release" if mode.startswith("release") else "plain"
            anchor = '  "$WORK/$name" "$SRV" >"$WORK/$name.out" 2>&1 </dev/null 3<&- 4>&-\n'
            if mode.endswith("timeout"):
                program = tool_program("fixture %s partial evidence" % mode)
                shell = once(shell, "CLIENT_SECONDS=180\n", "CLIENT_SECONDS=1\n")
                expected = "%s: client watchdog expired (1 s)" % selected
            else:
                number = mode.split("-")[-1]
                program = "import sys; sys.exit(%s)" % number
                expected = "plain: exited " + number
            shell = once(shell, anchor,
                         '  "$PY" -c ' + shlex.quote(program) + ' >"$WORK/$name.out" 2>&1 </dev/null 3<&- 4>&-\n')
            if mode == "release-timeout":
                shell = once(shell, 'for mode in plain release; do\n', 'for mode in release; do\n')
            if mode.startswith("exit-"):
                anchor = '    build_and_run "plain" dns-plain\n'
                shell = once(shell, anchor, anchor + '    exit $?\n')
        elif mode == "mutation-timeout":
            env["IYI"] = "true"
            (root / "src/std").mkdir(parents=True)
            shutil.copy2(ROOT / "src/std/secure_dns.iyi", root / "src/std/secure_dns.iyi")
            shell = without_comparisons(shell)
            program = tool_program("a server whose certificate does not name wrong.test")
            shell = once(shell, "BROKEN_SECONDS=120\n", "BROKEN_SECONDS=1\n")
            shell = once(shell, '  "$WORK/$dir/program" "$SRV" >"$WORK/$dir/out" 2>&1 </dev/null 3<&- 4>&-\n',
                         '  "$PY" -c ' + shlex.quote(program) + ' >"$WORK/$dir/out" 2>&1 </dev/null 3<&- 4>&-\n')
            expected = "the server's name not verified: broken copy watchdog expired (1 s)"
        else:
            raise RuntimeError("unknown mode " + mode)
        # A startup failure ends before the body runs, and its verdict lines
        # are exactly the expected ones: no stray sentence from another stage.
        startup_failures = {"silent", "arm-after-death", "crash", "hang", "import-hang", "diagnostic", "broken-h2",
                            "bootstrap-exit", "bootstrap-hang", "interpreter-hang", "interpreter-exit-124",
                            "dependency-hang", "dependency-broken", "dependency-exit-124", "dependency-self"}
        verdict_modes = startup_failures | {"ready-dead", "body-early"}
        if mode in startup_failures:
            shell = once(shell, marker, 'echo "fixture body reached"\n' + marker)
        if mode in ("hang", "import-hang", "diagnostic"):
            anchor = '            outcome = startup(server, deadline)\n'
            shell = once(shell, anchor,
                         '            while server.poll() is None and not (srv / "fixture.armed").exists():\n'
                         '                if cancelled(): break\n'
                         '                time.sleep(0.01)\n'
                         '            deadline = time.monotonic() + 1\n' + anchor)
        client_timeout_modes = {"plain-timeout", "release-timeout", "mutation-timeout"}
        if mode in client_timeout_modes:
            # The stage watchdog starts only once the fixture is alive and its
            # native handle is retained.
            anchor = '                remaining = stage_deadline - time.monotonic()\n'
            shell = once(shell, anchor,
                         '                if not pathlib.Path(os.environ["SDNS_TEST_TOOL_OPENED"]).exists():\n'
                         '                    stage_deadline = time.monotonic() + 1\n' + anchor)
        server_live_modes = {
            "body-early", "hang", "import-hang", "diagnostic", "queued-frames",
            "build-hang", "mutation-build-hang", "mutation-patch-hang",
            "dig-hang", "dig-query-hang", "dig-version-hang", "gap-hang", "gap-evidence-hang",
            "dig-broken", "dig-junk", "dig-usage-only",
            "plain-timeout", "release-timeout", "mutation-timeout", "exit-124", "exit-137",
        }
        if mode in server_live_modes:
            env["SDNS_TEST_SERVER_REAPED"] = str(root / "server-reaped")
            anchor = '        return True\n    except ProcessLookupError:\n'
            replacement = ('        if len(child.args) > 1 and child.args[1] == SERVER:\n'
                           '            pathlib.Path(os.environ["SDNS_TEST_SERVER_REAPED"]).write_text("reaped")\n' + anchor)
            shell = once(shell, anchor, replacement)
        (bench / "std_secure_dns_exercise.sh").write_text(shell, newline="\n")
        (bench / "std_secure_dns_server.py").write_text(server, newline="\n")
        output = root / "fixture-output.log"
        pid = None
        native = None
        process = None
        pid_modes = {
            "bootstrap-hang", "interpreter-hang", "dependency-hang",
            "build-hang", "mutation-build-hang", "mutation-patch-hang",
            "dig-hang", "dig-query-hang", "dig-version-hang", "gap-hang", "gap-evidence-hang",
            "server-exit-tool", "plain-timeout", "release-timeout", "mutation-timeout",
        }
        stop_path = None
        if mode in pid_modes:
            fd, name = tempfile.mkstemp(prefix="sdns-fixture-stop-")
            os.close(fd)
            os.unlink(name)
            stop_path = pathlib.Path(name)
            env["SDNS_TEST_FIXTURE_STOP"] = str(stop_path)
            env["SDNS_TEST_TOOL_OPENED"] = str(root / "tool-opened")
            env["SDNS_TEST_TOOL_FDS"] = str(root / "tool-fds")
            if mode != "bootstrap-hang":
                env["SDNS_TEST_TOOL_PID"] = str(root / "tool-pid")
        try:
            with output.open("wb") as log:
                process = subprocess.Popen([SHELL, (bench / "std_secure_dns_exercise.sh").as_posix()], env=env,
                                           stdout=log, stderr=subprocess.STDOUT)
                if mode in pid_modes:
                    # Healthy runs publish within seconds. Under six CPU-bound
                    # processes on the 4-core runner, publication took more than
                    # 40 s, so the bound is 180 s; a hang still ends the run.
                    deadline = time.monotonic() + 180
                    marker = root / ("supervisor-pid" if mode == "bootstrap-hang" else "tool-pid")
                    while time.monotonic() < deadline and process.poll() is None:
                        text = marker.read_text().strip() if marker.exists() else ""
                        if text.isdigit():
                            pid = int(text)
                            break
                        time.sleep(0.05)
                    if pid is None:
                        raise RuntimeError("%s: fixture child did not publish its PID" % mode)
                    native = open_handle(pid)
                    (root / "tool-opened").touch()
                returncode = process.wait(timeout=80)
                if pid is not None:
                    deadline = time.monotonic() + 5
                    while not gone(pid, native) and time.monotonic() < deadline:
                        time.sleep(0.05)
                    if not gone(pid, native):
                        raise RuntimeError("%s: fixture PID %s survived cleanup" % (mode, pid))
                    print("%s fixture PID %s is gone" % (mode, pid), flush=True)
        except subprocess.TimeoutExpired as error:
            print(output.read_text(errors="replace"), flush=True)
            raise RuntimeError("%s: fixture watchdog expired" % mode) from error
        finally:
            # The stop file belongs only to this fixture. It cannot target a
            # recycled POSIX PID, even if the gate shell has already exited.
            if stop_path is not None:
                stop_path.touch()
            if process is not None and process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            confirmed = process is None
            if pid is not None and (os.name != "nt" or native is not None):
                deadline = time.monotonic() + 5
                while not gone(pid, native) and time.monotonic() < deadline:
                    time.sleep(0.05)
                if native is not None:
                    kernel, handle = native
                    if not gone(pid, native):
                        kernel.TerminateProcess(handle, 1)
                        kernel.WaitForSingleObject(handle, 5000)
                    confirmed = gone(pid, native)
                    kernel.CloseHandle(handle)
                else:
                    confirmed = gone(pid, None)
            if stop_path is not None:
                if confirmed:
                    stop_path.unlink()
                else:
                    print("%s: fixture stop marker retained at %s" % (mode, stop_path), file=sys.stderr, flush=True)
                    if pid is not None:
                        raise RuntimeError("%s: fixture child did not stop" % mode)
        captured = output.read_text(errors="replace")
        lines = captured.splitlines()
        status = 0 if mode in success else (1 if mode.startswith("exit-") else 76)
        print("=== %s status=%s ===" % (mode, returncode), flush=True)
        print(captured, flush=True)
        expected_lines = (expected,) if isinstance(expected, str) else expected
        if returncode != status or sum(lines.count(text) for text in expected_lines) != 1:
            raise RuntimeError("%s: expected status %s and exactly one of %r" % (mode, status, expected_lines))
        if mode in verdict_modes:
            verdicts = [line for line in lines if line.startswith(VERDICT_PREFIXES)]
            wanted = verdict_alternatives(mode, expected)
            if verdicts not in wanted:
                raise RuntimeError("%s: expected the verdict lines %r, got %r" % (mode, wanted, verdicts))
        if "supervisor cleanup is unconfirmed" in captured:
            raise RuntimeError("supervisor cleanup was not confirmed")
        if mode == "bootstrap-hang" and lines.count("the secure DNS supervisor did not stop during cleanup") != 1:
            raise RuntimeError("bootstrap-hang did not reach forced supervisor cleanup")
        if mode in server_live_modes and (root / "server-reaped").read_text() != "reaped":
            raise RuntimeError("server was not reaped by its supervisor")
        if mode in success and lines.count("fixture supervisor completed") != 1:
            raise RuntimeError("fixture did not complete its supervisor handoff")
        if mode == "dig-usage-only":
            if lines.count("  | Usage: dig [@server] name [type]") != 1 or "skipped: this dig has neither" in captured:
                raise RuntimeError("usage-only dig output was not rejected as a failed preflight")
        if mode == "broken-h2" and "controlled broken h2" not in captured:
            raise RuntimeError("broken h2 traceback missing")
        if mode == "hang":
            for text in ("Timeout (", "(most recent call first):", "fixture stall at pki"):
                if text not in captured:
                    raise RuntimeError("synchronized startup evidence missing: " + text)
            if (sys.platform == "darwin" or sys.platform.startswith("linux")) and "== startup diagnostics: uptime" not in lines:
                raise RuntimeError("startup diagnostics did not run")
        if mode in ("import-hang", "diagnostic"):
            stall = {"import-hang": "fixture stall during import",
                     "diagnostic": "fixture diagnostic stall"}[mode]
            if stall not in lines:
                raise RuntimeError("fixture stall evidence missing: " + stall)
        if mode == "diagnostic":
            if lines.count("partial-diagnostic") != 1 or lines.count("the scripted servers hung before signaling readiness, at stage: pki") != 1:
                raise RuntimeError("partial diagnostic output or stage verdict missing")
            if "last 16384 of " not in captured or "discarded-diagnostic-prefix" in captured or "D" * 16385 in captured:
                raise RuntimeError("diagnostic evidence was not capped")
        if mode == "crash":
            if "RuntimeError: controlled startup crash" not in captured:
                raise RuntimeError("crash traceback missing")
            if "last 16384 of " not in captured or "discarded-crash-prefix" in captured or "C" * 16385 in captured:
                raise RuntimeError("crash evidence was not capped")
        if mode == "gap-hang" and "unrelated server output" in captured:
            raise RuntimeError("an initial stage with no evidence file printed the server log")
        evidence_modes = {
            "interpreter-hang", "dependency-hang", "build-hang", "mutation-build-hang", "mutation-patch-hang",
            "dig-hang", "dig-query-hang", "dig-version-hang",
            "gap-evidence-hang", "server-exit-tool", "plain-timeout", "release-timeout", "mutation-timeout",
        }
        if mode in evidence_modes:
            evidence = ("a server whose certificate does not name wrong.test" if mode == "mutation-timeout"
                        else "fixture interpreter preflight evidence" if mode == "interpreter-hang"
                        else "fixture dependency preflight evidence" if mode == "dependency-hang"
                        else "fixture %s partial evidence" % mode)
            if evidence not in captured or "last 16384 of " not in captured:
                raise RuntimeError("%s: capped partial evidence missing" % mode)
            if "discarded-evidence-prefix" in captured or "X" * 16385 in captured:
                raise RuntimeError("%s: evidence exceeded its cap" % mode)
            if mode in client_timeout_modes and lines.count(evidence) != 1:
                raise RuntimeError("%s: stage evidence was not retained" % mode)
        fd_modes = {"build-hang", "mutation-build-hang", "mutation-patch-hang",
                    "dig-hang", "dig-query-hang", "dig-version-hang",
                    "gap-hang", "gap-evidence-hang", "server-exit-tool"}
        if mode in fd_modes and os.name != "nt" and (root / "tool-fds").read_text() != "control fds closed":
            raise RuntimeError("%s: tool inherited a control fd" % mode)
        if mode in startup_failures and "fixture body reached" in lines:
            raise RuntimeError("body ran after failed startup")
        if "the std/secure_dns exercise holds" in lines:
            raise RuntimeError("a fixture was mistaken for a full gate pass")
        if mode == "mutation-timeout" and "caught at" in captured:
            raise RuntimeError("timeout was counted as a catch")
        if (mode.startswith("exit-") or "-exit-" in mode) and "watchdog expired" in captured:
            raise RuntimeError("natural exit was mistaken for a timeout")


if __name__ == "__main__":
    modes = sys.argv[3:] or [
        "body-early", "silent", "crash", "hang", "import-hang", "ready-dead", "queued-frames",
        "diagnostic", "broken-h2", "bootstrap-hang", "bootstrap-exit",
        "interpreter-hang", "dependency-hang", "interpreter-exit-124", "interpreter-exit-137",
        "dependency-exit-124", "dependency-exit-137", "dependency-broken", "dependency-self",
        "build-hang", "mutation-build-hang", "mutation-patch-hang",
        "dig-hang", "dig-query-hang", "dig-version-hang",
        "gap-hang", "gap-evidence-hang", "server-exit-tool",
        "dig-broken", "dig-junk", "dig-usage-only", "plain-timeout", "release-timeout",
        "mutation-timeout", "exit-124", "exit-137",
    ]
    for mode in modes:
        test(mode)
