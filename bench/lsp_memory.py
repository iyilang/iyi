#!/usr/bin/env python3
"""An editing session's memory is bounded by what is open, not by how
long it has been open.

`iyi` carries no collector (SPEC.md III.9), which is the right bargain
for a verb that compiles one program and exits and the wrong one for a
process an editor keeps for a day. Measured on this laptop before the
split: forty edits and hovers on a 327-line module took one server from
87 MB to **1,636 MB**, and a session of `references` over `std/big`
reached 19 GB, at which point the kernel killed it — mid-keystroke, with
the person's answers inside it.

So `iyi lsp` is a proxy that keeps the protocol and the buffers and a
worker that compiles and is replaced (`src/compiler/iyi/lsp/proxy.cr`).
This file is what says that is true, and it is the only kind of proof
that counts here: the same client traffic, the resident megabytes of the
whole process tree read from the kernel, and the answers still right
either side of a replacement.

Four things it holds to:

  1. typing with no pause is bounded — the worker reports what it has
     cost and is retired at `RETIRE_FOOTPRINT`
  2. typing the way a person types (pauses) is *cheap*, because the
     replacement is warmed in the silence
  3. the answers do not change across a retirement, which is what makes
     the replacement invisible rather than merely quiet
  4. a worker killed outright is one bad answer, not a dead session:
     whoever was waiting is told, and the next question is answered

Run with `--direct` to drive `iyi lsp --worker` — the single-process
shape — and watch 1 and 2 fail. That is the gate's teeth, kept in the
gate rather than in a commit message.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lsp_session import Client, children, rss_mb, tree_mb  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
# A module with imports and traits, so a compile is a real compile: this
# is the file the 1,636 MB was measured on.
MODULE = REPO / "src/std/semantic_version.iyi"

# What the tree may hold while typing without a single pause. The proxy
# was measured at 401-504 MB here (the worker's 512 MB budget, plus the
# proxy's own 30 MB, plus what the kernel has not reclaimed yet); the
# single process was measured at 1,636 MB.
TYPING_CEILING_MB = 760

# What it may hold when the person pauses the way people do. Measured:
# 95-112 MB, because each pause leaves a fresh worker behind.
PACED_CEILING_MB = 300

EDITS = 40
PAUSE_EVERY = 10
PAUSE = 2.2

FAILURES = []


def step(name, ok, detail=""):
    print(f"memory {'ok' if ok else 'FAIL'} {name}  {detail}")
    if not ok:
        FAILURES.append(name)


def open_module(client, path, text):
    uri = "file://" + str(path)
    client.send("initialize", {"processId": None,
                               "rootUri": "file://" + str(REPO),
                               "capabilities": {}})
    client.send("initialized", {}, wait=False)
    client.send("textDocument/didOpen",
                {"textDocument": {"uri": uri, "languageId": "iyi",
                                  "version": 1, "text": text}}, wait=False)
    client.diagnostics(uri)
    return uri


def hover(client, uri, line, character):
    reply = client.send("textDocument/hover",
                        {"textDocument": {"uri": uri},
                         "position": {"line": line, "character": character}})
    result = reply.get("result")
    if not result:
        return ""
    contents = result.get("contents", {})
    return contents.get("value", "") if isinstance(contents, dict) else ""


def edit(client, uri, version, at_line):
    """One character typed at the end of the file: a new version, and so
    a compile that no memo can answer."""
    client.send("textDocument/didChange",
                {"textDocument": {"uri": uri, "version": version},
                 "contentChanges": [{
                     "range": {"start": {"line": at_line, "character": 0},
                               "end": {"line": at_line, "character": 0}},
                     "text": "\n"}]}, wait=False)
    client.diagnostics(uri)


def candidates(text):
    """Positions worth asking a hover about, likeliest first.

    Which nodes carry a type is the front end's business and not a thing
    to guess from the outside: a def's *name* has none, a parameter in
    the signature does, a receiver in front of a `.` usually does, and
    which of them a given module offers changes as the library is
    edited. So the gate offers candidates and lets the server pick."""
    for number, line in enumerate(text.split("\n")):
        bare = line.strip()
        if not bare or bare.startswith("#"):
            continue
        indent = len(line) - len(bare)
        dot = line.find(".")
        if dot > indent and (line[dot - 1].isalnum() or line[dot - 1] in "_?!"):
            yield number, dot - 1
        equals = line.find(" = ")
        if equals > indent:
            yield number, indent
        colon = line.find(" : ")
        if colon > indent:
            yield number, colon - 1


def hovering_position(client, uri, text, tries=80):
    """The first candidate the server answers, and what it answered.

    A step that watched a position nothing answers would be comparing
    two empty strings for ever and passing."""
    for number, (line, character) in enumerate(candidates(text)):
        if number >= tries:
            break
        said = hover(client, uri, line, character)
        if said:
            return line, character, said
    raise SystemExit(
        f"no hover in {MODULE} answered in {tries} tries: the gate cannot "
        f"watch an answer it cannot get")


def typing_session(argv, pause_every=None):
    """*EDITS* edits, each followed by a hover, and what the tree cost.

    Returns the peak tree megabytes, the cost at rest after each pause,
    and the hover answers first and last: a session that stayed small by
    forgetting the buffers would pass the megabytes and fail the
    answers."""
    text = MODULE.read_text()
    end = text.count("\n")
    client = Client(argv)
    uri = open_module(client, MODULE, text)
    line, character, first = hovering_position(client, uri, text)
    peak = 0
    resting = []
    for round_number in range(EDITS):
        edit(client, uri, round_number + 2, end + round_number)
        hover(client, uri, line, character)
        peak = max(peak, tree_mb(client.proc.pid))
        if pause_every and (round_number + 1) % pause_every == 0:
            # What the session costs once the person stops for a moment:
            # the bound that matters, because it is the one an hour of
            # editing either returns to or does not.
            time.sleep(PAUSE)
            resting.append(tree_mb(client.proc.pid))
    last = hover(client, uri, line, character)
    client.send("shutdown", {})
    client.send("exit", {}, wait=False)
    code = client.proc.wait(timeout=30)
    return peak, resting, first, last, code


def killed_mid_compile(argv, direct, work):
    """Kill the process that is compiling, while it is compiling.

    The in-flight request is a run that does not return — the code lens
    on a module that sleeps — so the kill lands on work that is
    certainly still going, rather than on a race with a hover that may
    already have been answered."""
    text = MODULE.read_text()
    client = Client(argv)
    uri = open_module(client, MODULE, text)
    line, character, _ = hovering_position(client, uri, text)
    slow = os.path.join(work, "slow.iyi")
    with open(slow, "w") as sleeper:
        sleeper.write('module slow\n\nputs "started"\nsleep(2000)\n')
    slow_uri = "file://" + slow
    client.send("textDocument/didOpen",
                {"textDocument": {"uri": slow_uri, "languageId": "iyi",
                                  "version": 1, "text": open(slow).read()}},
                wait=False)
    client.diagnostics(slow_uri)
    running = client.request_nowait("workspace/executeCommand",
                                    {"command": "iyi.run",
                                     "arguments": [slow_uri]})
    time.sleep(1.0)
    victims = [client.proc.pid] if direct else children(client.proc.pid)
    if not victims:
        step("whoever was waiting is told the compile died", False,
             "no worker process to kill")
        return client
    for victim in victims:
        try:
            os.kill(victim, 9)
        except ProcessLookupError:
            pass
    try:
        answer = client.wait_for(lambda m: m.get("id") == running)
        error = answer.get("error", {})
        step("whoever was waiting is told the compile died",
             error.get("code") == -32603 and "did not survive" in
             error.get("message", ""), json.dumps(error)[:100])
    except SystemExit:
        step("whoever was waiting is told the compile died", False,
             "the session closed its pipe: the process that died was the "
             "one holding it")
        return client

    reply = client.send("textDocument/hover",
                        {"textDocument": {"uri": uri},
                         "position": {"line": line, "character": character}})
    step("the next question is answered by a new worker",
         "error" not in reply and bool(reply.get("result")),
         f"worker(s) now {children(client.proc.pid)}")
    return client


def binary_gone():
    """The compiler's binary, moved out from under a live session.

    Which binary is asked of the kernel rather than assumed: the worker
    is started from the path the proxy captured at startup, and reading
    `/proc/<pid>/exe` is how this gate learns it without hardcoding a
    build layout. Where there is no `/proc`, the step says so."""
    text = MODULE.read_text()
    client = Client(("lsp",))
    uri = open_module(client, MODULE, text)
    line, character, _ = hovering_position(client, uri, text)
    workers = children(client.proc.pid)
    if not workers:
        step("a session outlives the binary it was started from", False,
             "no worker process to look at")
        return
    try:
        binary = os.readlink(f"/proc/{workers[0]}/exe")
    except OSError:
        print("memory ---- no /proc/<pid>/exe here, so which binary the "
              "worker runs is not knowable; step skipped")
        client.proc.kill()
        return

    aside = binary + ".gate-aside"
    os.rename(binary, aside)
    try:
        os.kill(workers[0], 9)
        time.sleep(0.4)
        reply = client.send("textDocument/hover",
                            {"textDocument": {"uri": uri},
                             "position": {"line": line,
                                          "character": character}})
        error = reply.get("error", {})
        step("a session outlives the binary it was started from",
             error.get("code") == -32603
             and "could not be started" in error.get("message", "")
             and client.proc.poll() is None,
             json.dumps(error)[:100] or "no error, and no binary either")
    finally:
        os.rename(aside, binary)

    reply = client.send("textDocument/hover",
                        {"textDocument": {"uri": uri},
                         "position": {"line": line, "character": character}})
    step("and answers again the moment it is back",
         "error" not in reply and bool(reply.get("result")),
         f"worker(s) now {children(client.proc.pid)}")
    client.proc.kill()

def main():
    direct = "--direct" in sys.argv
    argv = ("lsp", "--worker") if direct else ("lsp",)
    if direct:
        print("memory ---- driving `iyi lsp --worker`: one process, no "
              "retirement. This is the shape the bounds below rule out.")
    measured = rss_mb(os.getpid()) > 0

    peak, _, first, last, code = typing_session(argv)
    detail = f"{EDITS} edits with no pause, peak {peak} MB"
    if not measured:
        step("typing without a pause is bounded", True,
             detail + " (no /proc here; unmeasured)")
    else:
        step("typing without a pause is bounded", peak <= TYPING_CEILING_MB,
             detail + f", bound {TYPING_CEILING_MB} MB")
    step("the session exits 0 after shutdown", code == 0, f"exit {code}")
    # The answers, either side of however many retirements happened in
    # between. `first` is from the worker that opened the file; `last`
    # may be from its fourth successor.
    step("the hover survives every replacement",
         bool(first) and first == last,
         f"{len(first)} chars, identical" if first == last
         else f"{first[:40]!r} -> {last[:40]!r}")

    _, resting, first, last, code = typing_session(argv,
                                                   pause_every=PAUSE_EVERY)
    rested = max(resting) if resting else 0
    detail = (f"{EDITS} edits, a {PAUSE}s pause every {PAUSE_EVERY}, "
              f"at rest {resting} MB")
    if not measured:
        step("a pause hands the memory back", True,
             detail + " (no /proc here; unmeasured)")
    else:
        step("a pause hands the memory back", rested <= PACED_CEILING_MB,
             detail + f", bound {PACED_CEILING_MB} MB")
    step("the paced session's hover is right too",
         bool(first) and first == last, f"{len(first)} chars")

    # A rebuild unlinks the binary under a running session, which
    # `lsp_session.py` step 46 holds for the process the editor talks to.
    # The worker is a *second* process started from that same path, so
    # the split opened a new window: no worker, no binary, a client
    # holding buffers. The answer has to be a refusal that names the
    # path, not a session that ends.
    if direct:
        print("memory ---- the missing-binary step needs a worker to "
              "respawn; there is none in this shape")
    else:
        binary_gone()

    with tempfile.TemporaryDirectory(prefix="iyi-lsp-memory") as work:
        client = killed_mid_compile(argv, direct, work)
        try:
            client.proc.kill()
        except OSError:
            pass

    if FAILURES:
        print(f"lsp memory: {len(FAILURES)} step(s) failed: "
              f"{', '.join(FAILURES)}")
        sys.exit(1)
    print("lsp memory: a session's cost is what is open, not how long it "
          "has been open")


if __name__ == "__main__":
    main()
