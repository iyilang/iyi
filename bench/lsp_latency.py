#!/usr/bin/env python3
"""Measures what `iyi lsp` claims: that a real compile per question fits
an editor's budget. The corpus is this repository's own samples — the
calc language, the kemal port, the app/std modules — opened in one
session, then asked the questions a person asks: a keystroke's verdict,
a hover, a completion, references. Wall time is measured from request
to answer, percentiles are printed, and a p95 over budget names its
verb and exits 1. `bench/lsp_session.py` is the correctness gate; this
is the speed half of the same claim.

Budgets are deliberately loose (CI machines are not laptops); the point
they hold is architectural: no question is allowed to cost a rebuild of
the world, because R-1 made the module the unit.
"""

import glob
import os
import re
import sys
import time

from lsp_session import Client

CORPUS_ROOT = os.path.join(os.path.dirname(__file__), "..", "samples", "iyi")

# p95 budgets, seconds.
BUDGETS = {
    "didChange": 2.0,
    "hover": 2.0,
    "completion": 2.0,
    # Workspace-wide, one compile per entry whose imports reach the
    # declaring module. Every entry compiled instead: 4.6 s on this
    # corpus with an unoptimised compiler, which is what the budget is
    # set under, so "ask everybody" cannot come back unnoticed.
    "references": 3.0,
}

# A hover is answered from the verdict the keystroke before it already
# compiled: no compile of its own, so its median is the transport's, and
# is held to that. On Windows it was 47 to 52 ms - the frame waited for a
# thread the reader was holding - where Linux answers in 1; a budget of
# seconds could not see it.
HOVER_P50 = 0.010


def percentile(samples, p):
    ordered = sorted(samples)
    index = min(len(ordered) - 1, max(0, round(p / 100 * len(ordered)) - 1))
    return ordered[index]


def main():
    root = os.path.abspath(CORPUS_ROOT)
    files = sorted(
        f for f in glob.glob(os.path.join(root, "**", "*.iyi"), recursive=True)
    )
    if not files:
        sys.exit(f"no corpus under {root}")

    c = Client()
    started = time.perf_counter()
    c.send("initialize", {"rootUri": "file://" + root, "capabilities": {}})
    c.send("initialized", {}, wait=False)
    startup = time.perf_counter() - started

    texts = {}
    for path in files:
        with open(path) as f:
            texts[path] = f.read()
        c.send("textDocument/didOpen",
               {"textDocument": {"uri": "file://" + path, "languageId": "iyi",
                                 "version": 1, "text": texts[path]}},
               wait=False)
        c.diagnostics("file://" + path)

    timings = {verb: [] for verb in BUDGETS}

    def timed(verb, thunk):
        t0 = time.perf_counter()
        thunk()
        timings[verb].append(time.perf_counter() - t0)

    # A probe position per file: the first def's name.
    probes = {}
    for path in files:
        m = re.search(r"^(?:pub )?def (\w+)", texts[path], re.M)
        if m:
            line = texts[path][:m.start()].count("\n")
            col = texts[path].splitlines()[line].index(m.group(1))
            probes[path] = (line, col + 1)

    for round_no in range(2):
        for path in files:
            uri = "file://" + path
            # 1. the keystroke: a comment toggled at the end, full
            #    verdict awaited. Round two returns to the original, so
            #    the corpus is left as found.
            text = texts[path] + "# t\n" if round_no == 0 else texts[path]
            timed("didChange", lambda: (
                c.send("textDocument/didChange",
                       {"textDocument": {"uri": uri, "version": 2 + round_no},
                        "contentChanges": [{"text": text}]}, wait=False),
                c.diagnostics(uri)))

            if path not in probes:
                continue
            line, col = probes[path]
            timed("hover", lambda: c.send(
                "textDocument/hover",
                {"textDocument": {"uri": uri},
                 "position": {"line": line, "character": col}}))
            timed("completion", lambda: c.send(
                "textDocument/completion",
                {"textDocument": {"uri": uri},
                 "position": {"line": line, "character": col}}))

    # References are workspace-wide — every module compiles — so a few
    # samples say what there is to say.
    for path in list(probes)[:5]:
        uri = "file://" + path
        line, col = probes[path]
        timed("references", lambda: c.send(
            "textDocument/references",
            {"textDocument": {"uri": uri},
             "position": {"line": line, "character": col},
             "context": {"includeDeclaration": True}}))

    c.send("shutdown", {})
    c.send("exit", {}, wait=False)

    print(f"corpus: {len(files)} modules under samples/iyi, "
          f"startup {startup * 1000:.0f} ms")
    print(f"{'verb':<12}{'n':>5}{'p50':>9}{'p95':>9}{'max':>9}")
    over = []
    for verb, samples in timings.items():
        p50 = percentile(samples, 50)
        p95 = percentile(samples, 95)
        print(f"{verb:<12}{len(samples):>5}"
              f"{p50 * 1000:>7.0f}ms{p95 * 1000:>7.0f}ms"
              f"{max(samples) * 1000:>7.0f}ms")
        if p95 > BUDGETS[verb]:
            over.append(f"{verb}: p95 {p95 * 1000:.0f}ms > "
                        f"{BUDGETS[verb] * 1000:.0f}ms")
    hover_p50 = percentile(timings["hover"], 50)
    if hover_p50 > HOVER_P50:
        over.append(f"hover: p50 {hover_p50 * 1000:.1f}ms > "
                    f"{HOVER_P50 * 1000:.0f}ms - a question that costs no "
                    f"compile waited on the transport")
    if over:
        print("\nOVER BUDGET")
        for line in over:
            print(f"  {line}")
        sys.exit(1)
    print("\nlsp latency: every verb inside its budget")


if __name__ == "__main__":
    main()
