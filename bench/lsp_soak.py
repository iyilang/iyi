#!/usr/bin/env python3
"""Abuses `iyi lsp`'s transport and asks for a hover after every blow.
"The server's whole value is being there on the next keystroke" is a
sentence this file makes literal: stray blank lines, garbage headers,
bodies that are not JSON, bodies that are not UTF-8, requests with
malformed params, positions past the end of the file, edits to
documents that were never opened — after each one, the same hover must
still answer. A server that dies on any of them fails the step that
names the abuse.
"""

import json
import os
import sys
import tempfile

from lsp_session import Client

FAILURES = []


def step(name, ok, detail=""):
    mark = "ok" if ok else "FAIL"
    print(f"soak {mark:4} {name}  {detail}")
    if not ok:
        FAILURES.append(name)


def raw(c, payload: bytes):
    c.proc.stdin.write(payload)
    c.proc.stdin.flush()


def hover_alive(c, uri):
    reply = c.send("textDocument/hover",
                   {"textDocument": {"uri": uri},
                    "position": {"line": 2, "character": 9}})
    return "id" in reply and "error" not in reply


def main():
    work = tempfile.mkdtemp(prefix="iyi-lsp-soak")
    path = os.path.join(work, "alive.iyi")
    text = ("module alive\n\npub def ping : String\n  \"pong\"\nend\n\n"
            "puts ping\n")
    with open(path, "w") as f:
        f.write(text)
    uri = "file://" + path

    c = Client()
    c.send("initialize", {"rootUri": "file://" + work, "capabilities": {}})
    c.send("initialized", {}, wait=False)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": uri, "languageId": "iyi",
                             "version": 1, "text": text}}, wait=False)
    c.diagnostics(uri)
    step("baseline hover", hover_alive(c, uri))

    raw(c, b"\r\n\r\n\r\n")
    step("stray blank lines", hover_alive(c, uri))

    raw(c, b"X-Garbage: yes\r\nContent-Length: nonsense\r\n")
    step("garbage headers", hover_alive(c, uri))

    body = b"this is not json {"
    raw(c, b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
    step("body that is not JSON", hover_alive(c, uri))

    body = b'{"jsonrpc": "2.0", "method": "x", "params": "\xff\xfe"}'
    raw(c, b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
    step("body that is not UTF-8", hover_alive(c, uri))

    # -32602, not -32603: the client left out a field it owes, which is
    # invalid params. -32603 is "this server is broken", and the server
    # said that here — with the JSON library's `Missing hash key` for a
    # message — until the session gate's five error cases were written.
    reply = c.send("textDocument/hover", {"textDocument": {"uri": uri}})
    step("request missing its position",
         reply.get("error", {}).get("code") == -32602 and hover_alive(c, uri))

    reply = c.send("textDocument/hover",
                   {"textDocument": {"uri": uri},
                    "position": {"line": 999999, "character": 999999}})
    step("position past the end of the file",
         "error" not in reply and hover_alive(c, uri))

    c.send("textDocument/didChange",
           {"textDocument": {"uri": "file://" + work + "/ghost.iyi",
                             "version": 1},
            "contentChanges": [{"text": "module ghost\n"}]}, wait=False)
    c.diagnostics("file://" + work + "/ghost.iyi")
    step("didChange for a document never opened", hover_alive(c, uri))

    big = "module big\n\n" + "".join(
        f"pub def f{n} : Int32\n  {n}\nend\n\n" for n in range(1500))
    big_uri = "file://" + os.path.join(work, "big.iyi")
    with open(os.path.join(work, "big.iyi"), "w") as f:
        f.write(big)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": big_uri, "languageId": "iyi",
                             "version": 1, "text": big}}, wait=False)
    c.diagnostics(big_uri)
    step("a 1,500-def module", hover_alive(c, uri))

    # A cursor next to a node the front end never typed: a variable
    # assigned only inside a macro branch this target does not take, and
    # one assigned inside an `if` nobody reaches. `ContextVisitor` read
    # `.type` off both and the answer was -32603 "BUG: ... has no type";
    # 96,608 requests over the whole standard library found 18 of them.
    dead = ("module dead\n\n"
            "def whole(s : String) : Int32\n"
            "  {% if flag?(:win32) %}\n    w = s.bytesize\n  {% else %}\n    w = 0\n  {% end %}\n"
            "  if s.empty? && !s.empty?\n    s_len = s.bytesize\n  end\n"
            "  w\nend\n\nputs whole(\"x\")\n")
    dead_uri = "file://" + os.path.join(work, "dead.iyi")
    with open(os.path.join(work, "dead.iyi"), "w") as f:
        f.write(dead)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": dead_uri, "languageId": "iyi",
                             "version": 1, "text": dead}}, wait=False)
    c.diagnostics(dead_uri)
    untyped_ok = True
    for line, ch in ((4, 8), (8, 8), (9, 4)):
        for method in ("textDocument/hover", "textDocument/completion"):
            reply = c.send(method, {"textDocument": {"uri": dead_uri},
                                    "position": {"line": line, "character": ch}})
            if reply.get("error", {}).get("code") == -32603:
                untyped_ok = False
    step("a cursor beside a node the front end never typed", untyped_ok)

    c.send("shutdown", {})
    c.send("exit", {}, wait=False)
    step("shutdown still orderly", c.proc.wait(timeout=10) == 0)

    if FAILURES:
        sys.exit(f"soak: the server flinched at {FAILURES}")
    print("lsp soak: the server was there on every next keystroke")


if __name__ == "__main__":
    main()
