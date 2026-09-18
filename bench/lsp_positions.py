#!/usr/bin/env python3
"""Every cursor question the server answers, asked at positions all over the
standard library.

`bench/lsp_session.py` asks the protocol's questions once each on a file
written for them, and `bench/lsp_soak.py` abuses the transport. Neither asks
a question *from a position nobody chose*, and that is where the answers were
wrong: a sweep of 96,608 requests over `src/std` found eighteen internal
errors with two causes, both of them a visitor reading `.type` off a node the
front end never typed — a variable assigned only inside a macro branch this
target does not take, and one assigned inside an `if` nobody reaches. An
editor does exactly this sweep, one keystroke at a time.

Its teeth, measured rather than asserted: run against the commit before the
fix (`25602f704~1`), this sweep at stride 200 over `std/dir` and `std/path`
alone reports seventeen of them — `BUG: flag?(:win32) ... has no type` and
`BUG: s_len ... has no type`, the two shapes above.

What it asserts, per module: the server survives every question, none of
them is answered `-32603` (which says *this server* is broken — a client's
mistake is -32602 and an unknown method -32601), the module opens with no
diagnostics, and the process exits 0 on `shutdown`.

**A fresh server per module, which is not a detail.** `iyi lsp` is the same
binary as the compiler and carries no collector (SPEC.md III.9, `-Dgc_none`),
so a process that compiles module after module never gives a byte back: this
sweep against one long-lived server was killed by the kernel at 19 GB, and
that is the honest upper bound of an allocator that never frees rather than a
leak. A compiler invocation compiles one program and exits; so does a server
here, once per module, and the memory each one reaches is measured below and
held under a bound. What a session of hours costs an editor is a separate
question, recorded in CHANGELOG under 0.13.0.

    python3 bench/lsp_positions.py [stride]

`stride` is the line step of the plain sweep, 200 by default. Two shapes are
asked at besides it, because they are the two the defects were found on: a
macro directive line (`{% if flag?(:win32) %}`, where a variable assigned in
the arm this target does not take has no type) and a local assignment (where
`_, anchor_end = anchor_indices` inside an unreached `if` has none either).
"""

import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lsp_session import Client  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
MODULES = sorted((REPO / "src/std").glob("*.iyi"))

# Asked at every position: the questions an editor sends on a cursor move,
# a keystroke and a hover. Each takes a `TextDocumentPositionParams`.
AT_POSITION = (
    "textDocument/hover",
    "textDocument/definition",
    "textDocument/completion",
    "textDocument/typeDefinition",
    "textDocument/implementation",
    "textDocument/documentHighlight",
    "textDocument/signatureHelp",
    "textDocument/prepareRename",
    "textDocument/prepareCallHierarchy",
)

# Asked once per module: the whole-file questions, which have no position.
WHOLE_FILE = (
    "textDocument/documentSymbol",
    "textDocument/semanticTokens/full",
    "textDocument/foldingRange",
    "textDocument/codeLens",
    "textDocument/documentLink",
)

# `references` and `rename` compile every open document to answer, so they
# are asked at a handful of positions rather than all of them: the sweep is
# for the cursor questions, and this is the reminder that the two cost more.
EXPENSIVE_POSITIONS = 3

# A fresh server every this many questions, and the reason is the paragraph
# above: with no collector each answered question keeps what it allocated -
# measured at some 3 MB a question - so density is paid for in memory rather
# than in time. Restarting is what a compiler invocation does anyway, and it
# costs one compile of the module.
RESTART_AFTER = 400

# The bound on one server's memory. A chunk of `RESTART_AFTER` questions on
# the largest module of the library reaches 1.4 GB here; four leaves room for
# a module that grows and is far under what a long-lived session reached
# (19 GB, killed by the kernel).
RSS_CEILING_MB = 4096

FAILURES: list[str] = []


def rss_mb(pid: int) -> int:
    """Resident megabytes, or 0 where the kernel does not say.

    `/proc` is Linux's. On darwin and Windows this answers 0 and the bound
    below goes unmeasured rather than unasserted-and-claimed: the sweep is
    about the answers, and the memory is the Linux job's to hold."""
    try:
        with open(f"/proc/{pid}/status") as status:
            for line in status:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) // 1024
    except OSError:
        return 0
    return 0


MACRO_LINE = re.compile(r"\{%")
ASSIGNMENT = re.compile(r"^\s*[\w, ]+ = [^=]")


def positions(lines: list[str], stride: int) -> list[tuple[int, int]]:
    """Line and column pairs, in three helpings.

    The plain sweep every *stride* lines, at the start, middle and end of the
    line — where a cursor sits, and where the three shapes differ: a name, an
    operator, and the nothing after the last character.

    Then every second macro directive line and every twelfth local
    assignment, at the start and the middle. Those two are not a guess: the
    eighteen internal errors the first sweep found were all on one or the
    other, because a variable an arm this target does not take never got a
    type and a visitor read it anyway.
    """
    chosen: set[tuple[int, int]] = set()
    for line_no in range(0, len(lines), stride):
        text = lines[line_no]
        for column in {0, len(text) // 2, max(len(text) - 1, 0)}:
            chosen.add((line_no, column))
    # Sampled with the stride rather than beside it, so one number thins the
    # whole sweep: a slower runner asks a larger stride and gets fewer of
    # these too, instead of the targeted lines dominating what it costs.
    macro = [i for i, text in enumerate(lines) if MACRO_LINE.search(text)]
    assign = [i for i, text in enumerate(lines) if ASSIGNMENT.match(text)]
    macro_step = max(2, stride // 100)
    assign_step = max(12, stride // 16)
    for line_no in macro[::macro_step] + assign[::assign_step]:
        text = lines[line_no]
        for column in {0, len(text) // 2}:
            chosen.add((line_no, column))
    return sorted(chosen)


def questions(path: Path, stride: int) -> list[tuple[str, dict, str]]:
    """Every request this module is asked, in order, as method and params."""
    lines = path.read_text().split("\n")
    uri = "file://" + str(path)
    asks: list[tuple[str, dict, str]] = []
    for method in WHOLE_FILE:
        asks.append((method, {"textDocument": {"uri": uri}}, path.name))
    asks.append(("textDocument/inlayHint",
                 {"textDocument": {"uri": uri},
                  "range": {"start": {"line": 0, "character": 0},
                            "end": {"line": len(lines), "character": 0}}}, path.name))
    for index, (line_no, column) in enumerate(positions(lines, stride)):
        params = {"textDocument": {"uri": uri},
                  "position": {"line": line_no, "character": column}}
        where = f"{path.name}:{line_no + 1}:{column + 1}"
        for method in AT_POSITION:
            asks.append((method, params, where))
        asks.append(("textDocument/selectionRange",
                     {"textDocument": {"uri": uri}, "positions": [params["position"]]}, where))
        if index < EXPENSIVE_POSITIONS:
            asks.append(("textDocument/references",
                         dict(params, context={"includeDeclaration": True}), where))
    return asks


def sweep(path: Path, stride: int) -> tuple[int, int, int]:
    """One module. Answers the requests asked, the peak RSS of any one server,
    and how many servers it took."""
    text = path.read_text()
    uri = "file://" + str(path)
    asks = questions(path, stride)
    asked = 0
    peak = 0
    servers = 0
    checked_diagnostics = False

    for start in range(0, len(asks), RESTART_AFTER):
        chunk = asks[start:start + RESTART_AFTER]
        servers += 1
        client = Client()
        try:
            client.send("initialize", {"rootUri": "file://" + str(REPO), "capabilities": {}})
            client.send("initialized", {}, wait=False)
            client.send("textDocument/didOpen",
                        {"textDocument": {"uri": uri, "languageId": "iyi",
                                          "version": 1, "text": text}}, wait=False)
            published = client.diagnostics(uri)
            if not checked_diagnostics:
                checked_diagnostics = True
                if published["diagnostics"]:
                    first = published["diagnostics"][0]
                    FAILURES.append(
                        f"{path.name} opened with {len(published['diagnostics'])} diagnostic(s), "
                        f"first: {first.get('message', '')[:100]}"
                    )
            for method, params, where in chunk:
                asked += 1
                reply = client.send(method, params)
                error = reply.get("error")
                if error and error.get("code") == -32603:
                    FAILURES.append(f"{where} {method}: -32603 {error.get('message', '')[:120]}")
            peak = max(peak, rss_mb(client.proc.pid))
            client.send("shutdown", {})
            client.send("exit", {}, wait=False)
            code = client.proc.wait(timeout=30)
            if code != 0:
                FAILURES.append(f"{path.name}: the server exited {code} on shutdown, wanted 0")
        except SystemExit as died:
            FAILURES.append(f"{path.name}: the server stopped answering ({died})")
        except subprocess.TimeoutExpired:
            FAILURES.append(f"{path.name}: the server did not exit on shutdown")
        finally:
            if client.proc.poll() is None:
                client.proc.kill()

    if peak == 0:
        pass  # no /proc here; see `rss_mb`
    elif peak > RSS_CEILING_MB:
        FAILURES.append(
            f"{path.name} took {peak} MB, over the {RSS_CEILING_MB} MB bound: a server here "
            f"carries no collector, so this is what {RESTART_AFTER} questions cost"
        )
    return asked, peak, servers


def prove_it_can_fail(stride: int) -> None:
    """A module that does not compile, swept the same way.

    The sweep's own assertions are "no -32603, no death, no diagnostics", and
    a sweep that asked nothing would satisfy all three. So one module is made
    wrong on purpose — a copy of `std/bool` with a body that does not answer
    its declared type — and the sweep has to *see* it: diagnostics where
    there were none, and the cursor questions still answered, because a
    buffer that does not compile is the state an editor is in most of the
    time (`Analysis#result_for` falls back to the last good program).
    """
    work = REPO / ".lsp_positions_broken"
    (work / "std").mkdir(parents=True, exist_ok=True)
    broken = (REPO / "src/std/bool.iyi").read_text().replace(
        "module std/bool", "module std/bool\n\npub def __broken : Int32\n  \"not an Int32\"\nend", 1)
    target = work / "std/bool.iyi"
    target.write_text(broken)
    saved = os.environ.get("IYI_PATH")
    os.environ["IYI_PATH"] = f"{work}{os.pathsep}{REPO / 'src'}"
    before = len(FAILURES)
    try:
        asked, _, _ = sweep(target, stride)
        seen = [f for f in FAILURES[before:] if "opened with" in f]
        del FAILURES[before:]
        if not seen:
            FAILURES.append(
                "the broken copy opened with no diagnostics: this sweep cannot see a "
                "module that stopped compiling, so its 'no diagnostics' arm proves nothing"
            )
        if asked < 10:
            FAILURES.append(f"the broken copy was asked {asked} questions, which is not a sweep")
        internal = [f for f in FAILURES[before:] if "-32603" in f]
        if internal:
            FAILURES.extend(internal)
    finally:
        if saved is None:
            os.environ.pop("IYI_PATH", None)
        else:
            os.environ["IYI_PATH"] = saved
        target.unlink()
        (work / "std").rmdir()
        work.rmdir()


def main() -> int:
    stride = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    # Names narrow it to those modules, for a bisect or a repair.
    wanted = set(sys.argv[2:])
    modules = [p for p in MODULES if not wanted or p.name in wanted]
    if wanted and len(modules) != len(wanted):
        print(f"lsp positions: no module under src/std named {sorted(wanted - {p.name for p in modules})}")
        return 1
    if not MODULES:
        print("lsp positions: no module under src/std, so this checked nothing")
        return 1

    print(f"== every cursor question, every {stride} lines, one server per module")
    total = 0
    worst = (0, "")
    servers = 0
    for path in modules:
        asked, peak, started = sweep(path, stride)
        total += asked
        servers += started
        if peak > worst[0]:
            worst = (peak, path.name)
        print(f"  {path.name:28s} {asked:5d} questions, {started:2d} server(s), {peak:5d} MB")

    print()
    print("== proving the sweep sees a module that stopped compiling")
    prove_it_can_fail(stride)
    if not any("cannot see" in f or "not a sweep" in f for f in FAILURES):
        print("  a broken module is reported as diagnostics, and the cursor questions still answer")

    print()
    if worst[0]:
        print(f"asked {total:,} questions over {len(modules)} modules on {servers} servers; "
              f"the largest was {worst[0]} MB ({worst[1]}), under the {RSS_CEILING_MB} MB bound")
    else:
        print(f"asked {total:,} questions over {len(modules)} modules on {servers} servers; "
              f"what each one took went unmeasured here (no /proc)")
    if FAILURES:
        print()
        for failure in FAILURES:
            print(f"FAIL {failure}")
        print(f"\nlsp positions: {len(FAILURES)} of them")
        return 1
    print("lsp positions: every question answered, none of them -32603")
    return 0


if __name__ == "__main__":
    sys.exit(main())
