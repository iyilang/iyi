#!/usr/bin/env python3
"""The editor, in a workspace whose dependency is an artifact and nothing else.

A library arrives as `.iyimod` files (SPEC.md III.7), and a program built
with `--use-iyimod` compiles against them with the module's source deleted —
that is R-1's whole claim and `bench/samples_roundtrip.sh` gates it for the
build. The *editor* was not asked. It compiled imports from source alone, so
the same workspace opened with

    can't find module 'app/base'. A module's path is its file's path …

on the import line, hover and definition empty, about a module the build
compiles fine against. SPEC.md IV says the server's inner loop *is* what
`--use-iyimod` already does; this asserts that it does it.

The comparison is the one that matters: the same program, the same
questions, answered twice — once with the dependency's source present and
once with only its artifact — and the answers have to agree. Where they
differ on purpose is `definition`, which lands in the source when there is
one and in the artifact's declarations when there is not; both are checked
for pointing at something that exists.

What is asserted, per workspace:

  * `didOpen` reports no diagnostics,
  * `hover` names the local's type, which is the imported function's return,
  * `definition` answers exactly one location, in a file that is there,
  * `iyi/contextPack` carries the import's surface, with the same interface
    hash on both sides — the strongest form of "the same module arrived".

Exits non-zero if any of them fails.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.abspath(os.path.dirname(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bench"))
IYI = os.path.join(ROOT, "bin", "iyi")

# The program is one def so that `hover` has a local to name — the shape
# `bench/lsp_session.py` established as the question an editor asks.
MAIN = """module main

import app/base
using app/base::{value}

def run : Int32
  n = value
  n
end

puts run
"""

BASE = """module app/base

pub def value : Int32
  42
end
"""

status = 0


def say(label, ok, detail=""):
    global status
    print(f"  {'ok  ' if ok else 'FAIL'} {label}" + (f" — {detail}" if detail else ""))
    if not ok:
        status = 1


def workspace(where, keep_source):
    """A built workspace: artifacts written, the dependency's source kept or
    deleted. Building it first is also the control — a workspace the build
    cannot read is not a question for the editor."""
    os.makedirs(os.path.join(where, "app"), exist_ok=True)
    with open(os.path.join(where, "main.iyi"), "w") as f:
        f.write(MAIN)
    with open(os.path.join(where, "app", "base.iyi"), "w") as f:
        f.write(BASE)
    env = dict(os.environ, IYI_PATH=os.path.join(ROOT, "src") + os.pathsep + where)
    emit = subprocess.run([IYI, "build", "--emit-iyimod", "mods", "-o", "out", "main.iyi"],
                          cwd=where, env=env, capture_output=True, text=True)
    if emit.returncode != 0:
        say(f"{os.path.basename(where)}: the workspace builds", False,
            emit.stdout.splitlines()[:1] or emit.stderr.splitlines()[:1])
        return None
    if not keep_source:
        os.remove(os.path.join(where, "app", "base.iyi"))
        use = subprocess.run([IYI, "build", "--use-iyimod", "mods", "-o", "out2", "main.iyi"],
                             cwd=where, env=env, capture_output=True, text=True)
        if use.returncode != 0:
            say("the artifact-only workspace builds", False,
                (use.stdout + use.stderr).splitlines()[:1])
            return None
    return env


def ask(where, env, label):
    """Every question, asked of one workspace. Returns the interface hash the
    context pack carried, so the two runs can be compared."""
    os.environ.update(env)
    import lsp_session as session

    main = os.path.join(where, "main.iyi")
    uri = "file://" + main
    client = session.Client()
    client.send("initialize", {"rootUri": "file://" + where, "capabilities": {}})
    client.send("initialized", {}, wait=False)
    client.send("textDocument/didOpen", {"textDocument": {
        "uri": uri, "languageId": "iyi", "version": 1, "text": MAIN}}, wait=False)

    diagnostics = client.diagnostics(uri)["diagnostics"]
    say(f"{label}: opens with no diagnostics", not diagnostics,
        json.dumps(diagnostics)[:160])

    hover = client.send("textDocument/hover", {"textDocument": {"uri": uri},
                                               "position": {"line": 6, "character": 2}})
    shown = ((hover.get("result") or {}).get("contents") or {}).get("value", "")
    say(f"{label}: hover names the imported type", "n : Int32" in shown,
        shown.replace("\n", " "))

    jump = client.send("textDocument/definition", {"textDocument": {"uri": uri},
                                                   "position": {"line": 6, "character": 6}})
    locations = jump.get("result") or []
    target = locations[0]["uri"][len("file://"):] if locations else ""
    say(f"{label}: definition lands in a file that is there",
        len(locations) == 1 and os.path.isfile(target), target or "no location")

    pack = client.send("iyi/contextPack", {"textDocument": {"uri": uri}})
    result = pack.get("result") or {}
    surface = json.loads(result.get("output") or "{}") if result.get("ok") else {}
    imports = surface.get("imports") or [{}]
    api = imports[0].get("api") or {}
    names = [f.get("name") for f in (api.get("functions") or [])]
    say(f"{label}: the context pack carries the import's surface",
        "value" in names, imports[0].get("error") or json.dumps(names))

    client.send("shutdown", {})
    client.send("exit", {}, wait=False)
    return api.get("interface_hash")


def main():
    work = tempfile.mkdtemp(prefix="iyi-lsp-artifacts")
    try:
        hashes = {}
        for label, keep in (("with source", True), ("artifact only", False)):
            where = os.path.join(work, label.replace(" ", "-"))
            env = workspace(where, keep)
            if env is None:
                continue
            hashes[label] = ask(where, env, label)
        say("the same module arrived: one interface hash",
            len(hashes) == 2 and len(set(hashes.values())) == 1 and all(hashes.values()),
            json.dumps(hashes))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print()
    if status == 0:
        print("the editor answers the same whether the dependency is source or artifact.")
    else:
        print("the editor does not answer from an artifact.")
    return status


if __name__ == "__main__":
    sys.exit(main())
