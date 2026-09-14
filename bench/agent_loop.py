#!/usr/bin/env python3
"""Drives the agent's whole loop through the verbs built for it and
asserts on every answer. This is the gate for the agentic wave: each
claim the release makes — check's verdict-as-data, suggested_edit,
fix's convergence, --affected's exact selection, the MCP server, the
budget ladder — is a step here, and a step that fails names itself and
exits 1.

The loop is the one an agent actually runs:
    ground -> edit -> check -> fix -> test (only what the edit reaches)
and the server underneath it (mcp) speaking the same answers.

`run --sandbox` is asserted only when a wasi toolchain is present: the
sandbox refusing to fall back to native is its own contract, so a
machine without wasmtime skips the step loudly rather than faking it.
"""

import json
import os
import subprocess
import sys
import tempfile

IYI = os.path.abspath(os.environ.get("IYI", "./bin/iyi"))

passed = 0


def step(name, ok, detail=""):
    global passed
    mark = "ok" if ok else "FAIL"
    print(f"step {passed + 1} {name}: {mark}  {detail}")
    if not ok:
        sys.exit(1)
    passed += 1


def run(*args, cwd=None):
    proc = subprocess.run([IYI, *args], capture_output=True, text=True, cwd=cwd)
    return proc


def main():
    work = tempfile.mkdtemp(prefix="iyi-agent-loop")
    os.makedirs(os.path.join(work, "calc"))

    def write(rel, text):
        with open(os.path.join(work, rel), "w") as f:
            f.write(text)

    write("calc/add.iyi", (
        "module calc/add\n\n"
        "# Adds two integers.\n"
        "pub def add(a : Int32, b : Int32) : Int32\n  a + b\nend\n"
    ))
    write("calc/mul.iyi", (
        "module calc/mul\n\n"
        "# Multiplies two integers.\n"
        "pub def mul(a : Int32, b : Int32) : Int32\n  a * b\nend\n"
    ))
    write("app.iyi", (
        "module app\n\n"
        "pub def shout(n : Int32) : Int32\n  n * 2\nend\n\n"
        "pub def go() : Int32\n  shoutt(3)\nend\n\n"
        "go()\n"
    ))
    # A test asserts by exiting non-zero, and `assert` is the one word the
    # prelude gives it: a false condition is a panic naming the site.
    write("add_test.iyi", (
        "import calc/add\nusing calc/add::{add}\n\n"
        "assert add(2, 2) == 4, \"add broke\"\n"
    ))
    write("mul_test.iyi", (
        "import calc/mul\nusing calc/mul::{mul}\n\n"
        "assert mul(2, 3) == 6, \"mul broke\"\n"
    ))

    # 1. ground: the context pack names every import, docs included
    proc = run("mod", "context", "--json", "add_test.iyi", cwd=work)
    pack = json.loads(proc.stdout)
    names = [i["import"] for i in pack["imports"]]
    step("context grounds the test", names == ["calc/add"], f"imports {names}")

    write("ground.iyi", "import calc/add\nimport calc/mul\n\nputs 1\n")
    # 2. the budget ladder: a huge budget keeps the docs, a tight one
    # still names every import, and --json refuses the flag
    proc = run("mod", "context", "--budget", "10000", "ground.iyi", cwd=work)
    step("a huge budget keeps the docs",
         "# Adds two integers." in proc.stdout and "# pack:" in proc.stdout, "")
    proc = run("mod", "context", "--budget", "20", "ground.iyi", cwd=work)
    step("a tight budget still names every import",
         "calc/add" in proc.stdout and "calc/mul" in proc.stdout
         and "elided" in proc.stdout, "")
    step("--json with --budget is refused",
         run("mod", "context", "--json", "--budget", "10", "ground.iyi", cwd=work).returncode != 0,
         "budget shapes text; json is data")

    # 3. check: the verdict is data, and it carries the edit
    proc = run("check", "-f", "json", "app.iyi", cwd=work)
    step("check exits 1 on the broken file", proc.returncode == 1, "")
    errors = json.loads(proc.stderr)
    edit = next((e["suggested_edit"] for e in errors if "suggested_edit" in e), None)
    step("the error carries suggested_edit",
         edit is not None and edit["replacement"] == "shout" and edit["size"] == 6,
         f"edit {edit}")
    # And the error class an agent meets first, the syntax error: its
    # span is unknown, and `size` was `null` where every type error has
    # an integer - the one field of the promised five that changed type.
    write("cut.iyi", "module cut\n\ndef f(\n")
    proc = run("check", "-f", "json", "cut.iyi", cwd=work)
    errors = json.loads(proc.stderr)
    step("a syntax error's size is an integer, like every other's",
         proc.returncode == 1 and len(errors) == 1
         and all(isinstance(errors[0][k], int) for k in ("line", "column", "size")),
         f"{ {k: errors[0].get(k) for k in ('line', 'column', 'size')} }")
    os.remove(os.path.join(work, "cut.iyi"))  # unparseable files are always "affected"

    # 4. fix: applies exactly that edit and converges
    proc = run("fix", "--json", "app.iyi", cwd=work)
    fixed = json.loads(proc.stdout)
    step("fix applies the compiler's own edit",
         fixed["clean"] and [(a["from"], a["to"]) for a in fixed["applied"]] == [("shoutt", "shout")],
         f"applied {fixed['applied']}")
    proc = run("check", "app.iyi", cwd=work)
    step("check confirms clean", proc.returncode == 0, "")

    # 4a. the edit that spans a literal rather than a name: a
    # one-character string where a Char is wanted is the guess every
    # arrival makes about `split`, and the round the context pack's
    # gate kept losing. The span is the literal, quotes included, and
    # fix writes the Char with its escape.
    write("chars.iyi", (
        "module app\n\n"
        "puts \"/a/b\".split(\"/\").size\n"
        "puts \"a\\tb\".index(\"\\t\")\n"
    ))
    proc = run("check", "-f", "json", "chars.iyi", cwd=work)
    errors = json.loads(proc.stderr)
    edit = next((e["suggested_edit"] for e in errors if "suggested_edit" in e), None)
    step("a one-character string where a Char is wanted carries the Char",
         edit is not None and edit["replacement"] == "'/'" and edit["size"] == 3
         and "Did you mean '/'" in errors[0]["message"],
         f"edit {edit}")
    proc = run("fix", "--json", "chars.iyi", cwd=work)
    fixed = json.loads(proc.stdout)
    step("fix writes the Chars, escapes included",
         fixed["clean"] and [a["to"] for a in fixed["applied"]] == ["'/'", "'\\t'"],
         f"applied {[a['to'] for a in fixed['applied']]}")

    # 4a'. the edit that lives in another file. `fix main.iyi` with the
    # typo in the module main imports printed main's frame, the typo's
    # message and `Did you mean`, applied nothing, and exited 1 - an
    # invitation to run it again, forever. It names the file to run it
    # on now, in prose and in data, and pointing there converges.
    write("calc/typo.iyi", (
        "module calc/typo\n\n"
        "def helper(n : Int32) : Int32\n  n + 1\nend\n\n"
        "pub def bump(n : Int32) : Int32\n  helperr(n)\nend\n"
    ))
    write("bumps.iyi", (
        "module bumps\n\n"
        "import calc/typo\nusing calc/typo::{bump}\n\n"
        "puts bump(1)\n"
    ))
    proc = run("fix", "--json", "bumps.iyi", cwd=work)
    fixed = json.loads(proc.stdout)
    cause = fixed.get("cause", {})
    step("fix names the file the remaining error is in",
         not fixed["clean"] and fixed["applied"] == []
         and cause.get("file", "").endswith("calc/typo.iyi") and cause.get("line") == 8,
         f"cause {cause}")
    proc = run("fix", "bumps.iyi", cwd=work)
    step("and says so in prose",
         "the cause is in calc/typo.iyi:8:3" in proc.stderr and "iyi fix calc/typo.iyi" in proc.stderr,
         proc.stderr.strip().splitlines()[-1])
    proc = run("fix", "--json", "calc/typo.iyi", cwd=work)
    fixed = json.loads(proc.stdout)
    step("and fixing that file converges",
         fixed["clean"] and [(a["from"], a["to"]) for a in fixed["applied"]] == [("helperr", "helper")]
         and run("check", "bumps.iyi", cwd=work).returncode == 0,
         f"applied {fixed['applied']}")

    # 4b. the blind spot, closed as a language rule: an uncalled body is
    # typed against its declared signature (definition-site typing,
    # R-2's dividend) — by check AND by a plain build; fix converges to
    # the same verdict
    write("uncalled.iyi", (
        "module app\n\n"
        "pub def go() : Int32\n  shoutt(3)\nend\n\n"
        "pub def shout(n : Int32) : Int32\n  n * 2\nend\n"
    ))
    proc = run("check", "uncalled.iyi", cwd=work)
    step("check types the body nobody calls", proc.returncode == 1,
         "R-2's declared types stand in for the caller")
    proc = run("build", "--no-codegen", "uncalled.iyi", cwd=work)
    step("a plain build refuses it too - the rule is the language's",
         proc.returncode == 1, "")

    # 4b'. the generic half: a trait bound is written, and a bound is
    # enough — the body is typed against a synthesized witness, so a
    # generic def calling anything outside its bound dies at the
    # definition. duck-typed generics never check this.
    write("bounded.iyi", (
        "module app2\n\n"
        "pub trait Sized\n  abstract def size() : Int32\nend\n\n"
        "pub def total(s : Sized) : Int32\n  s.size() + s.length()\nend\n"
    ))
    proc = run("check", "bounded.iyi", cwd=work)
    step("a generic body cannot leave its bound",
         proc.returncode == 1 and "IyiDefTypeWitness_" in (proc.stdout + proc.stderr),
         "typed against the trait's witness")
    write("bounded.iyi", (
        "module app2\n\n"
        "pub trait Sized\n  abstract def size() : Int32\nend\n\n"
        "pub def total(s : Sized) : Int32\n  s.size() * 2\nend\n"
    ))
    step("and the honest generic body is clean",
         run("check", "bounded.iyi", cwd=work).returncode == 0, "")

    # 4b''. the import wall is per-file, and `pub import` is the one
    # door through it: a module in the program because *somebody else*
    # imported it is not reachable by `using` — the phantom-dependency
    # disease R-1 exists to refuse
    os.makedirs(os.path.join(work, "lib"), exist_ok=True)
    write("lib/inner.iyi", "module lib/inner\n\npub def shine() : Int32\n  7\nend\n")
    write("lib/facade.iyi", (
        "module lib/facade\nimport lib/inner\n\n"
        "pub def front() : Int32\n  1\nend\n"
    ))
    write("phantom.iyi", "import lib/facade\nusing lib/inner\n\nputs shine()\n")
    proc = run("check", "phantom.iyi", cwd=work)
    step("a phantom dependency is refused by name",
         proc.returncode == 1 and "pub import" in (proc.stdout + proc.stderr),
         "the error teaches both fixes")
    write("lib/facade.iyi", (
        "module lib/facade\npub import lib/inner\n\n"
        "pub def front() : Int32\n  1\nend\n"
    ))
    step("pub import is the door",
         run("check", "phantom.iyi", cwd=work).returncode == 0, "")
    write("qualified.iyi", "import lib/facade\n\nputs Lib::Inner.shine()\n")
    write("lib/facade.iyi", (
        "module lib/facade\nimport lib/inner\n\n"
        "pub def front() : Int32\n  1\nend\n"
    ))
    proc = run("check", "qualified.iyi", cwd=work)
    step("the wall holds for qualified names too",
         proc.returncode == 1 and "not imported here" in (proc.stdout + proc.stderr),
         "Lib::Inner.shine() without an import")
    write("lib/facade.iyi", (
        "module lib/facade\npub import lib/inner\n\n"
        "pub def front() : Int32\n  1\nend\n"
    ))
    step("and pub import opens both doors",
         run("check", "qualified.iyi", cwd=work).returncode == 0, "")
    proc = run("fix", "--json", "uncalled.iyi", cwd=work)
    fixed = json.loads(proc.stdout)
    step("fix converges to check's verdict",
         fixed["clean"] and [(a["from"], a["to"]) for a in fixed["applied"]] == [("shoutt", "shout")],
         f"applied {fixed['applied']}")
    step("and check agrees", run("check", "uncalled.iyi", cwd=work).returncode == 0, "")

    # 4c. the suggestion pool includes `using`-imported names — the miss
    # that motivated it: `addd` went unsuggested while `add` sat one
    # edit away in the file's own using line
    write("uses.iyi", (
        "import calc/add\nusing calc/add::{add}\n\n"
        "if addd(2, 2) != 4\n    puts \"broke\"\nend\n"
    ))
    proc = run("fix", "--json", "uses.iyi", cwd=work)
    fixed = json.loads(proc.stdout)
    step("a using-imported name is suggested and fixed",
         fixed["clean"] and [(a["from"], a["to"]) for a in fixed["applied"]] == [("addd", "add")],
         f"applied {fixed['applied']}")

    # 5. test --affected: the exact selection, both directions
    proc = run("test", "--json", "--affected", "calc/add.iyi", cwd=work)
    report = json.loads(proc.stdout)
    files = sorted(t["file"] for t in report["tests"])
    step("an edit to add runs only add's test",
         files == ["./add_test.iyi"] and report["skipped"] == 1,
         f"ran {files}, skipped {report['skipped']}")
    step("and the test passed by its assert", report["passed"] == 1, "")
    # The other direction: a test that asserts something false fails, by
    # exit code, with the site in what it printed.
    write("broken_test.iyi", (
        "import calc/add\nusing calc/add::{add}\n\n"
        "assert add(2, 2) == 5, \"arithmetic\"\n"
    ))
    proc = run("test", "--json", "broken_test.iyi", cwd=work)
    report = json.loads(proc.stdout)
    step("a false assert fails its test and names the line",
         proc.returncode != 0 and report["failed"] == 1
         and "assertion failed: arithmetic" in report["tests"][0]["output"]
         and "broken_test.iyi:4" in report["tests"][0]["output"],
         report["tests"][0]["output"].strip())
    os.remove(os.path.join(work, "broken_test.iyi"))
    proc = run("test", "--json", "--affected", "app.iyi", cwd=work)
    report = json.loads(proc.stdout)
    step("an edit nothing imports runs nothing",
         report["tests"] == [] and report["skipped"] == 2,
         f"skipped {report['skipped']}")

    # 5b. check --affected: the ripple — a surface break names exactly
    # the consumer it reaches, and a clean tree answers "all compile"
    write("consumer.iyi", (
        "import calc/add\nusing calc/add::{add}\n\n"
        "puts add(1, 1)\n"
    ))
    proc = run("check", "--affected", "calc/add.iyi", cwd=work)
    step("a clean ripple compiles everyone",
         proc.returncode == 0 and "all compile" in proc.stdout, proc.stdout.strip())
    write("calc/add.iyi", (
        "module calc/add\n\n"
        "# Adds three integers now.\n"
        "pub def add(a : Int32, b : Int32, c : Int32) : Int32\n  a + b + c\nend\n"
    ))
    proc = run("check", "--affected", "calc/add.iyi", cwd=work)
    step("a surface break names its consumers",
         proc.returncode == 1 and "broke" in proc.stdout, proc.stdout.splitlines()[-1])
    write("calc/add.iyi", (
        "module calc/add\n\n"
        "# Adds two integers.\n"
        "pub def add(a : Int32, b : Int32) : Int32\n  a + b\nend\n"
    ))
    step("and the repair closes it",
         run("check", "--affected", "calc/add.iyi", cwd=work).returncode == 0, "")
    # And a deletion, the one change certain to break every importer. It
    # answered "0 consumer(s) checked, all compile", exit 0, because the
    # closure dropped an import it could not open; an import names a path,
    # and the path outlives the file.
    os.rename(os.path.join(work, "calc/add.iyi"), os.path.join(work, "calc/add.gone"))
    proc = run("check", "--affected", "calc/add.iyi", cwd=work)
    step("a deleted module names the importers it breaks",
         proc.returncode == 1 and "consumer.iyi" in proc.stdout
         and "calc/add.iyi is not there" in proc.stdout,
         proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else repr(proc.stderr[:80]))
    proc = run("check", "--affected", "calc/add.iyi", "--json", cwd=work)
    report = json.loads(proc.stdout)
    step("and says so in the data",
         report.get("affected_not_found") == ["calc/add.iyi"]
         and any(f["file"] == "consumer.iyi" for f in report["failed"]),
         f"affected_not_found {report.get('affected_not_found')}")
    os.rename(os.path.join(work, "calc/add.gone"), os.path.join(work, "calc/add.iyi"))

    # 5c. the loop is around a language that can do work now: a pure-iyi
    # tool reads its args, its environment, and the disk — no --crystal
    write("nameplate.iyi", (
        "module nameplate\n\n"
        "pub def run() : Nil\n"
        "  args = Program.args\n"
        "  puts \"args: #{args.size}\"\n"
        "  home = Program.env(\"HOME\")\n"
        "  puts \"HOME present: #{home.is_a?(String)}\"\n"
        "  File.write(\"note.txt\", \"from a pure iyi tool\")\n"
        "  puts File.read(\"note.txt\")\n"
        "  File.delete(\"note.txt\")\n"
        "end\n\n"
        "run()\n"
    ))
    binary = os.path.join(work, "nameplate")
    proc = run("build", "nameplate.iyi", "-o", binary, cwd=work)
    step("the nameplate tool builds", proc.returncode == 0, proc.stderr.strip()[:80])
    out = subprocess.run([binary, "a", "b", "c"], capture_output=True, text=True, cwd=work)
    step("args, env and the disk answer",
         out.stdout == "args: 3\nHOME present: true\nfrom a pure iyi tool\n",
         repr(out.stdout))

    # 6. mcp: the same answers, over the wire
    server = subprocess.Popen([IYI, "mcp"], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, text=True, cwd=work)

    def rpc(method, params=None, id=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if id is not None:
            msg["id"] = id
        if params is not None:
            msg["params"] = params
        server.stdin.write(json.dumps(msg) + "\n")
        server.stdin.flush()
        if id is not None:
            return json.loads(server.stdout.readline())

    reply = rpc("initialize", {"protocolVersion": "2025-06-18"}, 1)
    step("mcp initialize names the server",
         reply["result"]["serverInfo"]["name"] == "iyi", "")
    rpc("notifications/initialized")
    tools = [t["name"] for t in rpc("tools/list", None, 2)["result"]["tools"]]
    step("mcp lists the loop's tools",
         tools == ["check", "fix", "context", "test", "doc"], f"{tools}")
    reply = rpc("tools/call", {"name": "check", "arguments": {"file": "app.iyi"}}, 3)
    step("mcp check answers [] on the clean file",
         json.loads(reply["result"]["content"][0]["text"]) == [], "")
    reply = rpc("tools/call", {"name": "test",
                               "arguments": {"affected": ["calc/mul.iyi"]}}, 4)
    report = json.loads(reply["result"]["content"][0]["text"])
    step("mcp test honours affected",
         [t["file"] for t in report["tests"]] == ["./mul_test.iyi"], "")
    reply = rpc("tools/call", {"name": "doc", "arguments": {"target": "String"}}, 5)
    text = reply["result"]["content"][0]["text"]
    step("mcp doc answers a prelude type's surface",
         text.startswith("#") and "class String" in text and "  def to_i : Int32" in text, text[:80])

    # The flag an agent branches on. It was the constant `false`, so a tool
    # that could not answer said it had: a missing file came back as a
    # success envelope whose text began with "Error:". The exit code cannot
    # decide it either — `check` exits 1 when the file has diagnostics and
    # `test` exits 1 when a test fails, and both of those are answers — so
    # all four cases are held here.
    reply = rpc("tools/call", {"name": "check", "arguments": {"file": "nope.iyi"}}, 6)
    refusal = reply["result"]
    step("mcp says isError when it could not answer",
         refusal["isError"] is True and "no such file" in refusal["content"][0]["text"],
         repr(refusal)[:90])
    write("broken.iyi", 'module broken\n\npub def x : Int32\n  "not a number"\nend\n')
    reply = rpc("tools/call", {"name": "check", "arguments": {"file": "broken.iyi"}}, 7)
    verdict = reply["result"]
    step("mcp keeps isError false for a verdict it did answer",
         verdict["isError"] is False
         and isinstance(json.loads(verdict["content"][0]["text"]), list)
         and json.loads(verdict["content"][0]["text"]) != [],
         repr(verdict)[:90])
    reply = rpc("tools/call", {"name": "doc", "arguments": {"target": "Nonesuch"}}, 8)
    missing_type = reply["result"]
    step("mcp says isError for a type the prelude has not",
         missing_type["isError"] is True, repr(missing_type)[:90])
    # And nothing in a payload an agent parses is meant for a terminal: the
    # compiler colourised three error paths whatever they were writing into,
    # so `\x1b[31;1mError: ` reached this JSON.
    with open(os.path.join(work, "binary.iyi"), "wb") as raw:
        raw.write(b"\xff\xfe\xff\xfe")
    reply = rpc("tools/call", {"name": "check", "arguments": {"file": "binary.iyi"}}, 9)
    bytes_reply = reply["result"]
    step("mcp answers bytes that are not text as an error, uncoloured",
         bytes_reply["isError"] is True
         and "not a valid iyi source file" in bytes_reply["content"][0]["text"]
         and "\x1b" not in bytes_reply["content"][0]["text"],
         repr(bytes_reply["content"][0]["text"])[:90])

    # What a malformed request gets told. An agent writes these by
    # accident - a field left out of a template, a tool name guessed -
    # and the answer has to say which mistake it was. A call with no
    # `name` came back "unknown tool: ", a sentence about a tool called
    # nothing, and a request with no `method` came back -32601 ("ask for
    # something else") where JSON-RPC means -32600 ("that is not a
    # request").
    reply = rpc("tools/call", {"arguments": {}}, 10)
    nameless = reply["result"]
    step("mcp names the missing field, not a tool called nothing",
         nameless["isError"] is True
         and "tools/call needs a name" in nameless["content"][0]["text"]
         and "check" in nameless["content"][0]["text"],
         repr(nameless["content"][0]["text"])[:90])
    reply = rpc("tools/call", {"name": "nonesuch", "arguments": {}}, 11)
    unknown = reply["result"]
    step("mcp lists its tools when one is guessed wrong",
         unknown["isError"] is True
         and "unknown tool: nonesuch" in unknown["content"][0]["text"]
         and "context" in unknown["content"][0]["text"],
         repr(unknown["content"][0]["text"])[:90])
    server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 12}) + "\n")
    server.stdin.flush()
    methodless = json.loads(server.stdout.readline())
    step("mcp tells a non-request from an unknown method",
         methodless.get("error", {}).get("code") == -32600,
         repr(methodless)[:90])
    rpc("exit")
    server.wait(timeout=10)
    step("mcp exits on exit", server.returncode == 0, "")

    # 7. the sandbox, where the toolchain exists
    wasi_cc = os.environ.get("IYI_WASI_CC") or next(
        (p for p in ["/opt/wasi-sdk/bin/clang",
                     os.path.expanduser("~/.local/opt/wasi-sdk/bin/clang")]
         if os.path.exists(p)), None)
    wasmtime = os.environ.get("IYI_WASMTIME") or next(
        (p for p in [os.path.expanduser("~/.wasmtime/bin/wasmtime")]
         if os.path.exists(p)), None) or subprocess.run(
        ["which", "wasmtime"], capture_output=True).returncode == 0
    if wasi_cc and wasmtime:
        write("honest.iyi", "module honest\n\npub def work() : Int32\n  55\nend\n\nputs work()\n")
        proc = run("run", "--sandbox", "honest.iyi", cwd=work)
        step("sandbox runs the honest program",
             proc.returncode == 0 and proc.stdout.strip() == "55", "")
        write("theft.iyi", "module theft\n\nf = File.open(\"/etc/passwd\")\nputs f\n")
        proc = run("run", "--sandbox", "theft.iyi", cwd=work)
        step("sandbox refuses the theft, leaks nothing",
             proc.returncode != 0 and "root:" not in proc.stdout,
             "refused at the compile fence")
    else:
        print("step - sandbox: skipped (no wasi-sdk/wasmtime on this machine) — the CI wasi job runs it")

    print("agent loop gate: every step held")


if __name__ == "__main__":
    main()
