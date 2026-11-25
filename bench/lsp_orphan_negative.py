#!/usr/bin/env python3
"""Prove the LSP orphan gate rejects a worker that was not killed."""

import os
import threading

import lsp_session as gate

original_kill = os.kill
victims = []
original_step = gate.step


def skip_first_kill(pid, sig):
    # The watchdog kills from a thread of its own, and those kills are not
    # the step's: swallowed here, a server that stopped answering outlived
    # the watchdog's exit.
    if threading.current_thread() is not threading.main_thread():
        return original_kill(pid, sig)
    victims.append((pid, sig))
    os.kill = original_kill
    print("negative control: deliberately left the held worker alive", flush=True)


def check_step(label, name, ok, detail=""):
    if label == "73j":
        if not victims or ok or "no answer" not in detail:
            raise RuntimeError(f"the orphan gate did not reject the skipped kill: {detail}")
        print(f"negative control: step {label} rejected the skipped kill: {detail}", flush=True)
        raise SystemExit(0)
    original_step(label, name, ok, detail)


# Under the session gate's watchdog: these steps wait on a server and walk a
# worker's processes as the session does, and with nothing to end a wait,
# Windows CI job 139176708533 sat here for 51 minutes without a line.
gate.watchdog(180)
try:
    os.kill = skip_first_kill
    gate.step = check_step
    gate.orphan_steps()
    if not victims:
        raise RuntimeError("the held worker was never reached")
finally:
    os.kill = original_kill
    gate.step = original_step
    for pid, sig in victims:
        try:
            original_kill(pid, sig)
        except OSError:
            pass
    # Nothing still reading a server's pipe when the interpreter shuts down.
    # 73j's reader waits on the proxy's stdout, which the worker left alive
    # holds, and the server's stderr reader on a pipe that worker and its
    # `cmd` hold: a daemon thread that woke to print as Python exited took
    # stdout's lock with it, and the step failed at "could not acquire lock
    # for <_io.BufferedWriter name='<stdout>'> at interpreter shutdown"
    # (Windows CI job 138828714339). With every process the steps started
    # killed, each pipe ends; one that does not is held by a process the
    # steps did not kill, which is the gate's to say.
    readers = gate.READERS + [client.stderr_reader for client in gate.LIVE]
    for reader in readers:
        reader.join(30)
    waiting = [reader for reader in readers if reader.is_alive()]
    if waiting:
        raise RuntimeError(f"{len(waiting)} reader(s) still waiting on a server's pipe 30 s after "
                           "every process the steps started was killed: something else holds it")
