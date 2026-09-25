#!/usr/bin/env python3
"""Drives `iyi lsp` through one scripted editing session and asserts on
every answer. This is the gate for SPEC.md III.8 #2: each claim the
release makes about the server is a step here, and a step that fails
names itself and exits 1.

The session is a person's first five minutes, plus the agent's first
question:
  1. initialize        -> the server names itself and its capabilities
  2. didOpen broken    -> diagnostics arrive, on the right line, citing SPEC
  3. didChange fixed   -> diagnostics empty (and the round trip is timed)
  4. hover             -> the variable's type
  5. definition        -> jumps into the sibling module, unsaved-buffer aware
  6. documentSymbol    -> the outline, nested
  7. iyi/contextPack   -> the import's surface as data, from the buffer

Then the everyday half a person meets in the first hour: incremental
range edits, the did-you-mean quickfix, signature help mid-call,
document highlight, folding, workspace symbols, prepareRename,
semantic tokens, inlay hints, type definition, and formatting.
"""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time

IYI = os.environ.get("IYI", "./bin/iyi")

# Every server this gate started, and the last step that finished: what the
# watchdog kills and names when a session stops answering.
LIVE = []
LAST = {"step": 0, "at": time.monotonic()}


def watchdog(seconds):
    """A server that stops answering hangs `read_message` forever, and the
    runner only kills the job at its own limit, with what the gate printed
    still in a pipe's buffer — a Windows run sat at "the language server
    holds its session" for most of an hour and said nothing. Past *seconds*
    with no step finished, this names the last one that did, kills every
    server, and exits 1. The whole session is under a minute everywhere."""
    if LAST.get("watching"):
        return
    LAST["watching"], LAST["at"] = True, time.monotonic()

    def watch():
        while True:
            time.sleep(5)
            if time.monotonic() - LAST["at"] > seconds:
                print(f"step {LAST['step'] + 1} never finished: no answer in "
                      f"{seconds} s after step {LAST['step']}", flush=True)
                for proc in LIVE:
                    proc.kill()
                os._exit(1)
    threading.Thread(target=watch, daemon=True).start()


def uri_path(uri):
    """The filesystem path a `file://` URI names, spelled and cased the
    way this platform compares paths — the inverse of `file_uri`, for a
    check that asks whether a target lies under a directory."""
    from urllib.parse import unquote, urlparse
    path = unquote(urlparse(uri).path)
    if os.name == "nt" and len(path) > 2 and path[0] == "/" and path[2] == ":":
        path = path[1:]
    return os.path.normcase(os.path.normpath(path))


def file_uri(path):
    """The URI an editor would send for *path*: `file:///tmp/x` on POSIX
    and `file:///C:/Users/x` on Windows. `"file://" + path` was the
    former by luck and `file://C:\\Users\\x` on Windows, a string no
    editor sends and the server could not read back."""
    return pathlib.Path(os.path.abspath(path)).as_uri()


def rss_mb(pid):
    """Resident megabytes of one process, or 0 where the kernel does not
    say. `/proc` is Linux's, and Windows says it through the process's
    working set; on darwin this answers 0 and whoever asked reports its
    bound unmeasured rather than unasserted-and-claimed."""
    if os.name == "nt":
        return nt_working_set_mb(pid)
    try:
        with open(f"/proc/{pid}/status") as status:
            for line in status:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) // 1024
    except OSError:
        return 0
    return 0


def nt_working_set_mb(pid):
    """The working set - the pages resident for the process, Windows'
    VmRSS - through kernel32's `K32GetProcessMemoryInfo`. 0 for a process
    that is gone or cannot be opened."""
    import ctypes
    from ctypes import wintypes

    class Counters(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                    ("PeakWorkingSetSize", ctypes.c_size_t),
                    ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t),
                    ("PeakPagefileUsage", ctypes.c_size_t)]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.K32GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    # PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ
    handle = kernel32.OpenProcess(0x1000 | 0x0010, False, pid)
    if not handle:
        return 0
    try:
        counters = Counters()
        counters.cb = ctypes.sizeof(Counters)
        if not kernel32.K32GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
            return 0
        return counters.WorkingSetSize // (1024 * 1024)
    finally:
        kernel32.CloseHandle(handle)


def children(pid):
    """The pids *pid* started and that are still running. `ps --ppid` is
    procps'; Windows has no `ps`, and the process snapshot kernel32 keeps
    names every process's parent, which is the same question."""
    if os.name == "nt":
        return nt_children(pid)
    listed = subprocess.run(["ps", "-o", "pid=", "--ppid", str(pid)],
                            capture_output=True, text=True)
    return [int(line) for line in listed.stdout.split() if line.isdigit()]


def nt_children(pid):
    import ctypes
    from ctypes import wintypes

    class Entry(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                    ("th32ProcessID", wintypes.DWORD),
                    ("th32DefaultHeapID", ctypes.c_size_t),
                    ("th32ModuleID", wintypes.DWORD),
                    ("cntThreads", wintypes.DWORD),
                    ("th32ParentProcessID", wintypes.DWORD),
                    ("pcPriClassBase", ctypes.c_long),
                    ("dwFlags", wintypes.DWORD),
                    ("szExeFile", ctypes.c_wchar * 260)]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(Entry)]
    kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(Entry)]
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    snapshot = kernel32.CreateToolhelp32Snapshot(0x2, 0)  # TH32CS_SNAPPROCESS
    if snapshot == wintypes.HANDLE(-1).value:
        raise OSError(ctypes.get_last_error(), "CreateToolhelp32Snapshot")
    found = []
    try:
        entry = Entry()
        entry.dwSize = ctypes.sizeof(Entry)
        more = kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while more:
            if entry.th32ParentProcessID == pid:
                found.append(entry.th32ProcessID)
            more = kernel32.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snapshot)
    return found


def tree_mb(pid):
    """A session's whole cost: `iyi lsp` keeps the buffers and runs a
    child that compiles, so counting only the parent would make the
    split look free and prove nothing — the memory moved to the child,
    it did not vanish."""
    return rss_mb(pid) + sum(rss_mb(child) for child in children(pid))


class Client:
    def __init__(self, argv=("lsp",)):
        """*argv* is the verb to run. `("lsp",)` is the server a person
        points an editor at — a proxy that keeps the buffers and a child
        that compiles. `("lsp", "--worker")` is that child alone, which
        is the single-process shape `lsp_memory.py --direct` measures to
        show what the split is worth."""
        self.proc = subprocess.Popen(
            [IYI, *argv], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        LIVE.append(self.proc)
        self.next_id = 0

    def send(self, method, params, wait=True):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if wait:
            message["id"] = self.next_id
        body = json.dumps(message).encode()
        self.proc.stdin.write(
            b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
        self.proc.stdin.flush()
        if wait:
            return self.wait_for(lambda m: m.get("id") == self.next_id)
        return None

    def raw(self, payload: bytes):
        """A frame written as-is, for the ones that are not valid JSON."""
        self.proc.stdin.write(payload)
        self.proc.stdin.flush()

    def send_raw_request(self, message, request_id):
        """A message written as given - a shape the client class would
        not build, for the ones that are wrong on purpose."""
        body = json.dumps(message).encode()
        self.proc.stdin.write(
            b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
        self.proc.stdin.flush()
        return self.wait_for(lambda m: m.get("id") == request_id)

    def request_nowait(self, method, params):
        """A request whose answer is read later — how a cancel gets to
        overtake it."""
        self.next_id += 1
        message = {"jsonrpc": "2.0", "method": method, "params": params,
                   "id": self.next_id}
        body = json.dumps(message).encode()
        self.proc.stdin.write(
            b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
        self.proc.stdin.flush()
        return self.next_id

    def write_batch(self, frames):
        """Several frames in one write, which is what makes the queue's
        claims *facts* rather than races.

        The server reads what is already in the pipe before it parks
        again, so a batch written together is a batch that is drained
        together — and then "a cancel overtakes queued work" and "a
        burst coalesces" do not depend on how fast the machine is. Both
        steps below used to send frame by frame and pass on this
        laptop by luck; the darwin runner is quicker than the laptop
        and answered the request before its cancel arrived, which is
        the server's documented limit (in-flight work is
        uninterruptible), not a bug it should be blamed for.

        *frames* is a list of (method, params, wants_id); returns the
        ids handed out, in order.
        """
        blob = b""
        ids = []
        for method, params, wants_id in frames:
            message = {"jsonrpc": "2.0", "method": method, "params": params}
            # A notification takes no id and must not consume one, or the
            # caller's arithmetic for "the id this batch will hand out"
            # is wrong and it waits for an answer nobody will send.
            if wants_id:
                self.next_id += 1
                message["id"] = self.next_id
                ids.append(self.next_id)
            body = json.dumps(message).encode()
            blob += b"Content-Length: %d\r\n\r\n%s" % (len(body), body)
        self.proc.stdin.write(blob)
        self.proc.stdin.flush()
        return ids

    def read_message(self):
        length = None
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise SystemExit("server closed the pipe")
            line = line.strip()
            if not line:
                break
            if line.startswith(b"Content-Length:"):
                length = int(line.split(b":")[1])
        return json.loads(self.proc.stdout.read(length))

    def wait_for(self, predicate):
        while True:
            message = self.read_message()
            if predicate(message):
                return message

    def diagnostics(self, uri=None):
        return self.wait_for(
            lambda m: m.get("method") == "textDocument/publishDiagnostics"
            and (uri is None or m["params"]["uri"] == uri)
        )["params"]


def step(n, name, ok, detail=""):
    mark = "ok" if ok else "FAIL"
    print(f"step {n:2} {name}: {mark}  {detail}", flush=True)
    if isinstance(n, int):
        LAST["step"], LAST["at"] = n, time.monotonic()
    if not ok:
        sys.exit(1)


def package_fixture(home):
    """A package in a bare mirror, fetched into a cache, and a buffer that
    imports it beside a sibling module.

    Returns (path, text, cache) or None where git is not there to make one.
    The cache is warmed here so the server resolves rather than fetches.
    """
    # The same binary the session runs, not `bin/iyi` by its path: that
    # is a shell script, and Windows cannot start one.
    iyi = os.path.abspath(IYI)
    env = dict(os.environ)
    lib = os.path.join(home, "work", "liba")
    os.makedirs(lib, exist_ok=True)
    steps = [["git", "init", "-q", lib],
             ["git", "-C", lib, "config", "user.email", "t@t"],
             ["git", "-C", lib, "config", "user.name", "t"]]
    for command in steps:
        if subprocess.run(command, capture_output=True).returncode != 0:
            return None
    with open(os.path.join(lib, "iyi.mod"), "w") as f:
        f.write("module example.test/user/liba\n")
    with open(os.path.join(lib, "liba.iyi"), "w") as f:
        f.write('module liba\n\npub def greeting : String\n'
                '  "hello from liba"\nend\n')
    for command in [["git", "-C", lib, "add", "-A"],
                    ["git", "-C", lib, "commit", "-qm", "one"],
                    ["git", "-C", lib, "tag", "v1.0.0"]]:
        if subprocess.run(command, capture_output=True).returncode != 0:
            return None
    mirror = os.path.join(home, "mirror", "example.test", "user")
    os.makedirs(mirror, exist_ok=True)
    if subprocess.run(["git", "clone", "-q", "--bare", lib,
                       os.path.join(mirror, "liba")],
                      capture_output=True).returncode != 0:
        return None

    app = os.path.join(home, "app")
    os.makedirs(app, exist_ok=True)
    with open(os.path.join(app, "iyi.mod"), "w") as f:
        f.write("module example.test/user/app\n"
                "require example.test/user/liba v1.0.0\n")
    with open(os.path.join(app, "helper.iyi"), "w") as f:
        f.write('module helper\n\npub def shout(s : String) : String\n'
                '  s + "!"\nend\n')
    text = ("import example.test/user/liba\n"
            "import helper\n"
            "import example.test/user/liba::{greeting}\n"
            "import helper::{shout}\n"
            "\n"
            "puts shout(greeting)\n")
    path = os.path.join(app, "main.iyi")
    with open(path, "w") as f:
        f.write(text)
    warm = subprocess.run([iyi, "build", "main.iyi", "-o", "warm"],
                          cwd=app, env=env, capture_output=True)
    if warm.returncode != 0:
        return None
    return path, text, os.path.join(home, "cache")


def main():
    watchdog(180)
    # Set before the server starts, because a child inherits the environment
    # it was spawned with: the package step below needs the server to find a
    # checkout in this cache rather than fetch one.
    pkg_home = tempfile.mkdtemp(prefix="iyi-lsp-pkg")
    os.environ["IYI_CACHE_DIR"] = os.path.join(pkg_home, "cache")
    os.environ["IYI_MOD_MIRROR"] = os.path.join(pkg_home, "mirror")

    work = tempfile.mkdtemp(prefix="iyi-lsp-gate")
    lib = os.path.join(work, "greet.iyi")
    app = os.path.join(work, "app.iyi")
    with open(lib, "w") as f:
        f.write('module greet\n\npub def shout(name : String) : String\n'
                '  name.upcase\nend\n')
    with open(app, "w") as f:
        f.write("module app\n")
    app_uri = file_uri(app)

    c = Client()

    # 1. initialize
    reply = c.send("initialize", {"rootUri": file_uri(work),
                                  "capabilities": {"textDocument": {
                                      "completion": {"completionItem": {
                                          "snippetSupport": True}}}}})
    caps = reply["result"]["capabilities"]
    step(1, "initialize", reply["result"]["serverInfo"]["name"] == "iyi"
         and caps["hoverProvider"] and caps["definitionProvider"]
         and caps["documentSymbolProvider"]
         and caps["textDocumentSync"]["change"] == 2
         and caps["signatureHelpProvider"]
         and caps["documentFormattingProvider"]
         and caps["documentHighlightProvider"]
         and caps["foldingRangeProvider"]
         and caps["workspaceSymbolProvider"]
         and caps["inlayHintProvider"]
         and caps["typeDefinitionProvider"]
         and caps["renameProvider"]["prepareProvider"]
         and caps["codeActionProvider"]["codeActionKinds"] == [
             "quickfix", "source.organizeImports"]
         and caps["workspace"]["fileOperations"]["willRename"]["filters"]
         and caps["implementationProvider"]
         and caps["callHierarchyProvider"]
         and caps["selectionRangeProvider"]
         and caps["diagnosticProvider"]["workspaceDiagnostics"]
         and caps["typeHierarchyProvider"]
         and caps["documentLinkProvider"] is not None
         and caps["codeLensProvider"] is not None
         and caps["executeCommandProvider"]["commands"] == ["iyi.run"]
         and caps["semanticTokensProvider"]["full"]["delta"],
         f"server {reply['result']['serverInfo']['version']}")
    c.send("initialized", {}, wait=False)

    # 2. didOpen a file whose call mis-types the argument. The def is only
    #    typed when called, so the fixture calls it.
    broken = ("module app\n\nimport greet\nimport greet::{shout}\n\n"
              "def run : String\n  shout(42)\nend\n\nputs run\n")
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": app_uri, "languageId": "iyi",
                             "version": 1, "text": broken}}, wait=False)
    diags = c.diagnostics()["diagnostics"]
    step(2, "didOpen broken -> diagnostics",
         len(diags) == 1 and diags[0]["range"]["start"]["line"] == 6,
         f"line {diags[0]['range']['start']['line'] + 1}: "
         f"{diags[0]['message'].splitlines()[0][:60]}")

    # 3. didChange to a SPEC-citing error (`!` on a union with no error
    #    member is refused and the message names its section), then fixed.
    speccy = ("module app\n\nimport greet\nimport greet::{shout}\n\n"
              "def run : String\n  shout(\"iyi\")!\nend\n\nputs run\n")
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 2},
            "contentChanges": [{"text": speccy}]}, wait=False)
    diags = c.diagnostics()["diagnostics"]
    cites = diags and diags[0].get("code", "").startswith("SPEC")
    step(3, "error cites its SPEC section as data", bool(cites),
         f"code {diags[0].get('code')!r}, "
         f"link {'yes' if diags[0].get('codeDescription') else 'no'}")

    fixed = ("module app\n\nimport greet\nimport greet::{shout}\n\n"
             "def run : String\n  shout(\"iyi\")\nend\n\nputs run\n")
    started = time.monotonic()
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 3},
            "contentChanges": [{"text": fixed}]}, wait=False)
    diags = c.diagnostics()["diagnostics"]
    elapsed = time.monotonic() - started
    step(4, "didChange fixed -> clean", diags == [],
         f"keystroke to verdict {elapsed * 1000:.0f} ms")
    if elapsed > 5.0:
        step(4, "keystroke latency bound", False, f"{elapsed:.2f}s > 5s")

    # 5. hover on a local whose type came through the import.
    hovered = ("module app\n\nimport greet\nimport greet::{shout}\n\n"
               "def run : String\n  loud = shout(\"iyi\")\n"
               "  loud\nend\n\nputs run\n")
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 4},
            "contentChanges": [{"text": hovered}]}, wait=False)
    c.diagnostics()
    reply = c.send("textDocument/hover",
                   {"textDocument": {"uri": app_uri},
                    "position": {"line": 7, "character": 3}})
    value = (reply["result"] or {}).get("contents", {}).get("value", "")
    step(5, "hover names the type", "loud : String" in value,
         value.replace("\n", " "))

    # 6. definition on the call jumps into the sibling module's def.
    reply = c.send("textDocument/definition",
                   {"textDocument": {"uri": app_uri},
                    "position": {"line": 6, "character": 11}})
    locs = reply["result"] or []
    step(6, "definition jumps to the import",
         any(l["uri"].endswith("greet.iyi") and
             l["range"]["start"]["line"] == 2 for l in locs),
         f"{len(locs)} location(s), first {locs and locs[0]['uri']}")

    # 7. documentSymbol: the outline — the header's module at the root,
    #    the def nested inside it.
    reply = c.send("textDocument/documentSymbol",
                   {"textDocument": {"uri": app_uri}})

    def flatten(symbols):
        for s in symbols:
            yield s["name"]
            yield from flatten(s.get("children", []))

    names = list(flatten(reply["result"]))
    step(7, "documentSymbol lists the outline",
         "App" in names and "run" in names, f"symbols {names}")

    # 8. iyi/contextPack: the agent's question, answered from the buffer.
    reply = c.send("iyi/contextPack", {"textDocument": {"uri": app_uri}})
    result = reply["result"]
    pack = json.loads(result["output"]) if result["ok"] else {}
    surfaces = [i for i in pack.get("imports", []) if i.get("api")]
    step(8, "iyi/contextPack grounds the buffer",
         result["ok"] and len(surfaces) == 1 and
         surfaces[0]["import"] == "greet",
         f"{len(surfaces)} surface(s), interface_hash "
         f"{surfaces[0]['api'].get('interface_hash', '')[:12]}")

    # 9. the unsaved sibling: rename greet's def in its *buffer* only,
    #    follow the rename in app. The verdict is clean because the
    #    import reads the buffer, not the disk — and the disk still says
    #    `shout`, which is the whole claim.
    greet_uri = file_uri(lib)
    with open(lib) as f:
        greet_text = f.read()
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": greet_uri, "languageId": "iyi",
                             "version": 1, "text": greet_text}}, wait=False)
    c.diagnostics(greet_uri)
    c.send("textDocument/didChange",
           {"textDocument": {"uri": greet_uri, "version": 2},
            "contentChanges": [{"text": greet_text.replace("shout",
                                                           "holler")}]},
           wait=False)
    c.diagnostics(greet_uri)
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 5},
            "contentChanges": [{"text": hovered.replace("shout",
                                                        "holler")}]},
           wait=False)
    diags = c.diagnostics(app_uri)["diagnostics"]
    with open(lib) as f:
        disk_still = "shout" in f.read()
    step(9, "unsaved sibling is seen through the import",
         diags == [] and disk_still,
         "buffer renamed shout->holler, disk untouched, verdict clean")

    # 10. a nested module opened on its own: `parser.iyi` lives under
    #     calc/, its header says so, and its import names the sibling
    #     from the root. The root is derived from the header (IV.6 read
    #     backwards), so the verdict is clean — the way a build from the
    #     root would see it, without one.
    calc = os.path.join(work, "calc")
    os.makedirs(calc)
    with open(os.path.join(calc, "lexer.iyi"), "w") as f:
        f.write("module calc/lexer\n\npub def token : String\n"
                '  "NUM"\nend\n\npub def glyph : String\n  "+"\nend\n')
    parser_path = os.path.join(calc, "parser.iyi")
    parser_text = ("module calc/parser\n\nimport calc/lexer\n"
                   "import calc/lexer::{token}\n\n"
                   "pub def first : String\n  token\nend\n\nputs first\n")
    with open(parser_path, "w") as f:
        f.write(parser_text)
    parser_uri = file_uri(parser_path)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": parser_uri, "languageId": "iyi",
                             "version": 1, "text": parser_text}}, wait=False)
    diags = c.diagnostics(parser_uri)["diagnostics"]
    step(10, "nested module resolves from its header's root", diags == [],
         "calc/parser.iyi imports calc/lexer, opened alone, clean")

    # 11. completion after a dot: the buffer stops compiling the moment
    #     the dot lands, which is exactly when completion fires — so the
    #     answer comes from the last result that held together.
    holler_app = hovered.replace("shout", "holler")
    dotted = holler_app.replace("\n  loud\n", "\n  loud.up\n")
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 6},
            "contentChanges": [{"text": dotted}]}, wait=False)
    c.diagnostics(app_uri)
    reply = c.send("textDocument/completion",
                   {"textDocument": {"uri": app_uri},
                    "position": {"line": 7, "character": 9}})
    items = reply["result"]["items"]
    labels = [i["label"] for i in items]
    upcase = next((i for i in items if i["label"] == "upcase"), None)
    step(11, "completion after a dot lists the receiver's methods",
         upcase is not None and all(l.startswith("up") for l in labels),
         f"{len(labels)} item(s) for 'loud.up', "
         f"upcase detail {upcase and upcase['detail']!r}")

    # 12. bare completion: the scope's own names, typed.
    bare = holler_app.replace("\n  loud\n", "\n  lo\n")
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 7},
            "contentChanges": [{"text": bare}]}, wait=False)
    c.diagnostics(app_uri)
    reply = c.send("textDocument/completion",
                   {"textDocument": {"uri": app_uri},
                    "position": {"line": 7, "character": 4}})
    items = reply["result"]["items"]
    loud = next((i for i in items if i["label"] == "loud"), None)
    step(12, "bare completion offers the scope, typed",
         loud is not None and loud["kind"] == 6 and
         loud["detail"] == "String",
         f"loud : {loud and loud['detail']}")

    # 12b. the same question with nothing typed yet — Ctrl+Space, which is
    #      how an editor asks for the whole scope rather than for what
    #      starts with two letters. The scope is the compiler's, and the
    #      compiler keeps its own variables in it: definition typing writes
    #      `__iyi_dt_*` probes, `uninitialized` receivers and return values
    #      in an `if false`, to check a def against its declaration. They
    #      came back as the first two items, ahead of the author's own
    #      name, each with kind 6 — "Variable" — on it.
    #
    #      Its own buffer, opened and never written: a struct with a typed
    #      method is enough to produce a probe, and the session's other
    #      steps assert over `app.iyi` and `greet.iyi` by name.
    probe_uri = file_uri(os.path.join(work, "probe.iyi"))
    probe_text = ("struct Point\n  getter x : Int32\n\n"
                  "  def initialize(@x : Int32)\n  end\n\n"
                  "  def double : Int32\n    x * 2\n  end\nend\n\n"
                  "spot = Point.new(2)\nputs spot.double\n")
    c.send("textDocument/didOpen", {"textDocument": {
        "uri": probe_uri, "languageId": "iyi", "version": 1,
        "text": probe_text}}, wait=False)
    c.diagnostics(probe_uri)
    c.send("textDocument/didChange",
           {"textDocument": {"uri": probe_uri, "version": 2},
            "contentChanges": [{"text": probe_text + "\n"}]}, wait=False)
    c.diagnostics(probe_uri)
    reply = c.send("textDocument/completion",
                   {"textDocument": {"uri": probe_uri},
                    "position": {"line": 13, "character": 0}})
    labels = [i["label"] for i in reply["result"]["items"]]
    invented = [l for l in labels if l.startswith(("__iyi_", "__temp_", "#"))]
    step("12b", "an empty prefix offers the author's scope and nothing invented",
         "spot" in labels and not invented,
         f"{len(labels)} item(s)"
         + (f", invented: {invented[:3]}" if invented else ""))
    c.send("textDocument/didClose",
           {"textDocument": {"uri": probe_uri}}, wait=False)

    # 13. references, asked at the *def*: under R-1 the callers live in
    #     the consumers' compiles, so the session answers from every open
    #     document — the call in app.iyi, the import's `{...}` selection that
    #     brings the name in (the gate's own find: miss it and a rename
    #     leaves a program that does not compile), and the declaration.
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 8},
            "contentChanges": [{"text": holler_app}]}, wait=False)
    c.diagnostics(app_uri)
    reply = c.send("textDocument/references",
                   {"textDocument": {"uri": greet_uri},
                    "position": {"line": 2, "character": 9},
                    "context": {"includeDeclaration": True}})
    locs = reply["result"] or []
    names = sorted({l["uri"].rsplit("/", 1)[-1] for l in locs})
    app_lines = sorted(l["range"]["start"]["line"] for l in locs
                       if l["uri"].endswith("app.iyi"))
    step(13, "references cross the module boundary, import line included",
         names == ["app.iyi", "greet.iyi"] and len(locs) == 3 and
         app_lines == [3, 6],
         f"{len(locs)} site(s): "
         + ", ".join(f"{l['uri'].rsplit('/', 1)[-1]}:{l['range']['start']['line']}" for l in locs)
         + " (wanted app.iyi:3 import, app.iyi:6 call, greet.iyi:2 declaration)")

    # 14. rename off the typed graph: one request, two files edited —
    #     then both buffers change to the edit and the verdicts are clean.
    reply = c.send("textDocument/rename",
                   {"textDocument": {"uri": greet_uri},
                    "position": {"line": 2, "character": 9},
                    "newName": "yell"})
    changes = reply["result"]["changes"]
    edit_count = sum(len(e) for e in changes.values())
    texts = {app_uri: holler_app,
             greet_uri: greet_text.replace("shout", "holler")}
    for uri, edits in changes.items():
        lines = texts[uri].split("\n")
        for e in sorted(edits, key=lambda e: -e["range"]["start"]["character"]):
            l = e["range"]["start"]["line"]
            s, t = e["range"]["start"]["character"], e["range"]["end"]["character"]
            lines[l] = lines[l][:s] + e["newText"] + lines[l][t:]
        texts[uri] = "\n".join(lines)
    clean = True
    for version, uri in ((3, greet_uri), (9, app_uri)):
        c.send("textDocument/didChange",
               {"textDocument": {"uri": uri, "version": version},
                "contentChanges": [{"text": texts[uri]}]}, wait=False)
        clean = clean and c.diagnostics(uri)["diagnostics"] == []
    step(14, "rename edits both files, import line too, both stay clean",
         len(changes) == 2 and edit_count == 3 and
         "import greet::{yell}" in texts[app_uri] and
         "def yell" in texts[greet_uri] and clean,
         f"{edit_count} edit(s) across {len(changes)} file(s)")

    # 15. incremental didChange: a range edit in wire units, not a full
    #     text — the server applies it, breaks, then a second range edit
    #     heals it.
    app_text = texts[app_uri]
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 10},
            "contentChanges": [{
                "range": {"start": {"line": 6, "character": 9},
                          "end": {"line": 6, "character": 13}},
                "text": "yel"}]}, wait=False)
    diags = c.diagnostics(app_uri)["diagnostics"]
    broke = len(diags) == 1 and diags[0]["range"]["start"]["line"] == 6
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 11},
            "contentChanges": [{
                "range": {"start": {"line": 6, "character": 9},
                          "end": {"line": 6, "character": 12}},
                "text": "yell"}]}, wait=False)
    healed = c.diagnostics(app_uri)["diagnostics"] == []
    step(15, "incremental sync: range edits apply", broke and healed,
         "yell -> yel broke line 7, a range edit back healed it")

    # 16. codeAction: the compiler's own "Did you mean", made clickable.
    typo = app_text.replace("\n  loud\n", "\n  loud.upcas\n")
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 12},
            "contentChanges": [{"text": typo}]}, wait=False)
    diags = c.diagnostics(app_uri)["diagnostics"]
    reply = c.send("textDocument/codeAction",
                   {"textDocument": {"uri": app_uri},
                    "range": diags[0]["range"] if diags else
                    {"start": {"line": 7, "character": 0},
                     "end": {"line": 7, "character": 0}},
                    "context": {"diagnostics": diags}})
    actions = reply["result"] or []
    fix = next((a for a in actions
                if a["title"] == "Change to 'upcase'"), None)
    applied = ""
    if fix:
        lines = typo.split("\n")
        for uri, edits in fix["edit"]["changes"].items():
            for e in edits:
                l = e["range"]["start"]["line"]
                s = e["range"]["start"]["character"]
                t = e["range"]["end"]["character"]
                lines[l] = lines[l][:s] + e["newText"] + lines[l][t:]
        applied = "\n".join(lines)
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 13},
            "contentChanges": [{"text": applied or typo}]}, wait=False)
    clean = c.diagnostics(app_uri)["diagnostics"] == []
    step(16, "codeAction turns did-you-mean into a quickfix",
         fix is not None and "loud.upcase" in applied and clean,
         f"{len(actions)} action(s), quickfix applied and clean")

    # 17. signatureHelp, asked right after the `(` lands — the buffer
    #     has no syntax there; the overload comes off the typed graph.
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 14},
            "contentChanges": [{"text": app_text}]}, wait=False)
    c.diagnostics(app_uri)
    reply = c.send("textDocument/signatureHelp",
                   {"textDocument": {"uri": app_uri},
                    "position": {"line": 6, "character": 14}})
    result = reply["result"] or {}
    sigs = result.get("signatures", [])
    label = sigs[0]["label"] if sigs else ""
    step(17, "signatureHelp names the overload mid-call",
         label.startswith("yell(") and "String" in label and
         result.get("activeParameter") == 0,
         f"label {label!r}")

    # 18. documentHighlight on the def: the declaration is the write,
    #     the call is the read, both in this buffer alone.
    reply = c.send("textDocument/documentHighlight",
                   {"textDocument": {"uri": app_uri},
                    "position": {"line": 5, "character": 5}})
    highlights = reply["result"] or []
    kinds = sorted(h["kind"] for h in highlights)
    hl_lines = sorted(h["range"]["start"]["line"] for h in highlights)
    step(18, "documentHighlight marks def and call",
         kinds == [2, 3] and hl_lines == [5, 10],
         f"{len(highlights)} range(s) at lines {hl_lines}")

    # 19. foldingRange: the def folds off the outline, the import
    #     header off the text.
    reply = c.send("textDocument/foldingRange",
                   {"textDocument": {"uri": app_uri}})
    folds = reply["result"] or []
    has_def = any(f["startLine"] == 5 and f["endLine"] == 8 for f in folds)
    has_imports = any(f.get("kind") == "imports" and f["startLine"] == 2
                      and f["endLine"] == 3 for f in folds)
    step(19, "foldingRange folds the def and the import header",
         has_def and has_imports, f"{len(folds)} fold(s)")

    # 20. workspace/symbol: the open buffer wins over the disk — the
    #     disk still says shout, the buffer says yell, yell is found.
    reply = c.send("workspace/symbol", {"query": "yell"})
    syms = reply["result"] or []
    hit = next((s for s in syms if s["name"] == "yell"
                and s["location"]["uri"].endswith("greet.iyi")), None)
    step(20, "workspace/symbol finds the def across the project",
         hit is not None, f"{len(syms)} symbol(s)")

    # 21. prepareRename: the range and placeholder before the input box.
    reply = c.send("textDocument/prepareRename",
                   {"textDocument": {"uri": greet_uri},
                    "position": {"line": 2, "character": 9}})
    result = reply["result"] or {}
    step(21, "prepareRename names the range and placeholder",
         result.get("placeholder") == "yell" and
         result["range"]["start"]["character"] == 8 and
         result["range"]["end"]["character"] == 12,
         f"placeholder {result.get('placeholder')!r}")

    # 22. semanticTokens: the lexer colors the buffer — keyword, def
    #     name, type, string — with no grammar installed anywhere.
    reply = c.send("textDocument/semanticTokens/full",
                   {"textDocument": {"uri": app_uri}})
    data = (reply["result"] or {}).get("data", [])
    decoded = []
    line = 0
    start = 0
    for i in range(0, len(data), 5):
        dl, ds, ln, tt, _ = data[i:i + 5]
        line += dl
        start = start + ds if dl == 0 else ds
        decoded.append((line, start, ln, tt))
    # legend: 0 keyword, 1 string, 4 type, 5 function, 6 variable
    has_def_kw = (5, 0, 3, 0) in decoded
    has_fn = (5, 4, 3, 5) in decoded
    has_str = any(l == 6 and tt == 1 for (l, s, ln, tt) in decoded)
    has_var = (6, 2, 4, 6) in decoded       # `loud`, a variable
    has_call = (6, 9, 4, 5) in decoded      # `yell(`, a call
    has_type_len = (5, 10, 6, 4) in decoded  # `String`, all six letters
    step(22, "semanticTokens color the buffer with no grammar",
         has_def_kw and has_fn and has_str and
         has_var and has_call and has_type_len,
         f"{len(decoded)} token(s)")

    # 23. inlayHint: the inferred type after the assignment, the
    #     parameter's name before the bare literal.
    reply = c.send("textDocument/inlayHint",
                   {"textDocument": {"uri": app_uri},
                    "range": {"start": {"line": 0, "character": 0},
                              "end": {"line": 11, "character": 0}}})
    hints = reply["result"] or []
    type_hint = next((h for h in hints if h["label"] == ": String"
                      and h["position"]["line"] == 6), None)
    param_hint = next((h for h in hints if h["label"] == "name:"), None)
    step(23, "inlayHint shows inferred type and parameter name",
         type_hint is not None and param_hint is not None and
         param_hint["position"] == {"line": 6, "character": 14},
         f"{len(hints)} hint(s): {[h['label'] for h in hints]}")

    # 24. typeDefinition: from the local to where String is declared.
    reply = c.send("textDocument/typeDefinition",
                   {"textDocument": {"uri": app_uri},
                    "position": {"line": 7, "character": 3}})
    locs = reply["result"] or []
    step(24, "typeDefinition jumps to the type's declaration",
         len(locs) >= 1,
         f"{len(locs)} location(s), first {locs and locs[0]['uri']}")

    # 25. formatting: the formatter, in process, one whole-document edit.
    sloppy = app_text.replace('yell("iyi")', 'yell(  "iyi" )')
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 15},
            "contentChanges": [{"text": sloppy}]}, wait=False)
    c.diagnostics(app_uri)
    reply = c.send("textDocument/formatting",
                   {"textDocument": {"uri": app_uri},
                    "options": {"tabSize": 2, "insertSpaces": True}})
    edits = reply["result"] or []
    formatted = edits[0]["newText"] if edits else ""
    step(25, "formatting is the formatter, in process",
         len(edits) == 1 and 'yell("iyi")' in formatted and
         formatted.count("\n") == sloppy.count("\n"),
         "one whole-document edit, call tightened")

    # 25b. and formatting a buffer that imports a package. The host segment
    #      is one segment to the parser and three tokens to the lexer, and
    #      the formatter fell behind its own stream on it — raising a plain
    #      exception, which this handler does not rescue: an editor asking
    #      to format any file that imports a package got an error back
    #      rather than an edit. The path has to survive the round trip.
    # Outside the workspace on purpose: the import does not resolve — there
    # is no such package — and step 31 judges every file the workspace
    # holds. Formatting is a question about bytes, so the file needs no
    # dependency to answer it.
    outside = tempfile.mkdtemp(prefix="iyi-lsp-gate-outside")
    pkg_path = os.path.join(outside, "pkg.iyi")
    pkg_text = ("import example.test/user/lib\n"
                "import example.test/user/lib::{value}\n\nx=value\n")
    with open(pkg_path, "w") as f:
        f.write(pkg_text)
    pkg_uri = file_uri(pkg_path)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": pkg_uri, "languageId": "iyi",
                             "version": 1, "text": pkg_text}}, wait=False)
    c.diagnostics(pkg_uri)
    reply = c.send("textDocument/formatting",
                   {"textDocument": {"uri": pkg_uri},
                    "options": {"tabSize": 2, "insertSpaces": True}})
    edits = reply.get("result") or []
    formatted = edits[0]["newText"] if edits else ""
    step(25, "formatting a buffer that imports a package",
         "error" not in reply and len(edits) == 1 and
         "import example.test/user/lib\n" in formatted and
         "import example.test/user/lib::{value}\n" in formatted and
         "x = value" in formatted,
         reply.get("error", {}).get("message", "the path survived, x = value"))
    # Closed again, the way an editor closes a buffer: an open document is
    # one the server judges, and step 31's verdict is about the workspace.
    c.send("textDocument/didClose", {"textDocument": {"uri": pkg_uri}},
           wait=False)

    # 26. a trait, its impl, and the call graph around them — one
    #     fixture serves implementation, call hierarchy, and selection.
    shapes_path = os.path.join(work, "shapes.iyi")
    shapes_text = ("module shapes\n\n"
                   "pub trait Paint\n  abstract def paint : String\nend\n\n"
                   "pub struct Dot\nend\n\n"
                   "impl Paint for Dot\n  def paint : String\n"
                   '    "."\n  end\nend\n\n'
                   "pub def render(thing : Dot) : String\n"
                   "  thing.paint\nend\n\nputs render(Dot.new)\n")
    with open(shapes_path, "w") as f:
        f.write(shapes_text)
    shapes_uri = file_uri(shapes_path)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": shapes_uri, "languageId": "iyi",
                             "version": 1, "text": shapes_text}}, wait=False)
    diags = c.diagnostics(shapes_uri)["diagnostics"]
    step(26, "the trait fixture compiles clean", diags == [],
         "shapes.iyi: trait Paint, impl for Dot, render calls paint")

    # 27. implementation: the trait name answers with its implementors.
    reply = c.send("textDocument/implementation",
                   {"textDocument": {"uri": shapes_uri},
                    "position": {"line": 2, "character": 11}})
    locs = reply["result"] or []
    step(27, "implementation jumps from the trait to its impl types",
         any(l["uri"].endswith("shapes.iyi") and
             l["range"]["start"]["line"] == 6 for l in locs),
         f"{len(locs)} implementor(s)")

    # 28. call hierarchy: prepare on the call, incoming names the
    #     enclosing def, outgoing from that def names the callee.
    reply = c.send("textDocument/prepareCallHierarchy",
                   {"textDocument": {"uri": shapes_uri},
                    "position": {"line": 16, "character": 9}})
    items = reply["result"] or []
    paint_item = items[0] if items else None
    incoming = []
    if paint_item:
        reply = c.send("callHierarchy/incomingCalls", {"item": paint_item})
        incoming = reply["result"] or []
    callers = sorted(e["from"]["name"] for e in incoming)
    reply = c.send("textDocument/prepareCallHierarchy",
                   {"textDocument": {"uri": shapes_uri},
                    "position": {"line": 15, "character": 9}})
    render_items = reply["result"] or []
    outgoing = []
    if render_items:
        reply = c.send("callHierarchy/outgoingCalls",
                       {"item": render_items[0]})
        outgoing = reply["result"] or []
    callees = sorted(e["to"]["name"] for e in outgoing)
    step(28, "call hierarchy answers both directions",
         paint_item is not None and paint_item["name"] == "paint" and
         "render" in callers and "paint" in callees,
         f"paint <- {callers}, render -> {callees}")

    # 29. selectionRange: expand from inside the string literal, out
    #     through the def, to the file — strictly nested.
    reply = c.send("textDocument/selectionRange",
                   {"textDocument": {"uri": shapes_uri},
                    "positions": [{"line": 11, "character": 5}]})
    chain = (reply["result"] or [None])[0] or {}
    depth = 0
    node = chain
    nested = True
    while node:
        depth += 1
        parent = node.get("parent")
        if parent:
            inner, outer = node["range"], parent["range"]
            nested = nested and (
                (outer["start"]["line"], outer["start"]["character"]) <=
                (inner["start"]["line"], inner["start"]["character"]) and
                (inner["end"]["line"], inner["end"]["character"]) <=
                (outer["end"]["line"], outer["end"]["character"]))
        node = parent
    step(29, "selectionRange expands strictly outward",
         depth >= 3 and nested and
         chain.get("range", {}).get("start", {}).get("line") == 11,
         f"{depth} nested range(s)")

    # 30. pull diagnostics: the agent's shape — ask, don't subscribe.
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 16},
            "contentChanges": [{"text": sloppy.replace("yell(", "yel(")}]},
           wait=False)
    c.diagnostics(app_uri)
    reply = c.send("textDocument/diagnostic",
                   {"textDocument": {"uri": app_uri}})
    pulled = reply["result"]
    broke = pulled["kind"] == "full" and len(pulled["items"]) == 1
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 17},
            "contentChanges": [{"text": app_text}]}, wait=False)
    c.diagnostics(app_uri)
    reply = c.send("textDocument/diagnostic",
                   {"textDocument": {"uri": app_uri}})
    healed = reply["result"]["items"] == []
    step(30, "pull diagnostics answer on request", broke and healed,
         "broken pulled 1 item, fixed pulled none")

    # 31. workspace diagnostics: the whole project's verdict in one
    #     request — a file nobody opened is still judged, R-1 makes
    #     every module its own cheap compile.
    with open(os.path.join(work, "broken.iyi"), "w") as f:
        f.write("module broken\n\ndef boom : String\n  1\nend\n\nputs boom\n")
    reply = c.send("workspace/diagnostic", {})
    items = reply["result"]["items"]
    dirty = [i for i in items if i["items"]]
    step(31, "workspace diagnostics judge the whole project",
         len(dirty) == 1 and dirty[0]["uri"].endswith("broken.iyi") and
         any(i["uri"].endswith("shapes.iyi") for i in items) and
         all(i["kind"] == "full" and i["resultId"] for i in items),
         f"{len(items)} file(s) judged, {len(dirty)} dirty")

    # 31b. and asked again with the ids it handed out — which VS Code
    #      does two seconds after every answer, for as long as the
    #      window is open — nothing is compiled: every item is
    #      `unchanged`, and the answer takes no time. This is the
    #      difference between an idle editor and a laptop fan.
    previous = [{"uri": i["uri"], "value": i["resultId"]} for i in items]
    started = time.monotonic()
    reply = c.send("workspace/diagnostic", {"previousResultIds": previous})
    elapsed = time.monotonic() - started
    again = reply["result"]["items"]
    step("31b", "the same workspace, pulled again, is unchanged and free",
         len(again) == len(items) and
         all(i["kind"] == "unchanged" and i["resultId"] for i in again) and
         elapsed < 0.5,
         f"{sum(i['kind'] == 'unchanged' for i in again)} of {len(again)} "
         f"unchanged in {elapsed * 1000:.0f} ms")

    # 31b'. and still so after the worker is replaced. The proxy retires
    #       it when the wire is quiet for two seconds, and the ids the
    #       client holds are handed to the successor: an id seeded by the
    #       process that made it read as changed there, and the first
    #       pull after every replacement compiled the whole workspace.
    #       A retirement on the memory bound may have come first, and
    #       then the first quiet warms that successor and the next one
    #       replaces it, so the wait is for the pid to move, bounded.
    #       Where the workers cannot be listed (BSD `ps` has no `--ppid`)
    #       the wait is the two quiet periods that cover it, and the pid
    #       move is reported unmeasured rather than asserted. Windows lists
    #       them from the process snapshot (`children`).
    before = children(c.proc.pid)
    if before:
        deadline = time.monotonic() + 10
        while children(c.proc.pid) == before and time.monotonic() < deadline:
            time.sleep(0.25)
        time.sleep(0.5)
    else:
        time.sleep(5)
    after = children(c.proc.pid)
    replaced = before != after if before else True
    started = time.monotonic()
    reply = c.send("workspace/diagnostic", {"previousResultIds": previous})
    elapsed = time.monotonic() - started
    kinds = [i["kind"] for i in reply["result"]["items"]]
    step("31b'", "a replaced worker reads the same ids as unchanged",
         replaced and len(kinds) == len(items) and
         all(k == "unchanged" for k in kinds) and elapsed < 0.5,
         f"worker {before or 'unmeasured'} -> {after or 'unmeasured'}, "
         f"{kinds.count('unchanged')} of "
         f"{len(kinds)} unchanged in {elapsed * 1000:.0f} ms")

    # 31c. one file on disk moves, and the next pull is full for that
    #      file and unchanged for every other: `broken.iyi` imports
    #      nothing and nobody imports it, so its verdict is the only one
    #      the change can reach.
    with open(os.path.join(work, "broken.iyi"), "w") as f:
        f.write("module broken\n\ndef boom : String\n  \"1\"\nend\n\nputs boom\n")
    reply = c.send("workspace/diagnostic", {"previousResultIds": previous})
    healed = reply["result"]["items"]
    full = sorted(i["uri"].rsplit("/", 1)[-1] for i in healed if i["kind"] == "full")
    step("31c", "a changed file makes the next pull full for itself alone",
         full == ["broken.iyi"] and
         not any(i.get("items") for i in healed),
         f"{full} full, {len(healed) - len(full)} unchanged, none dirty")

    # 31d. a module somebody imports moves, and the pull is full for it
    #      and its importers — `calc/lexer.iyi` on disk, `calc/parser.iyi`
    #      an open buffer that imports it — and unchanged for the rest.
    #      An import's declarations are part of a verdict; a stranger's
    #      are not.
    previous = [{"uri": i["uri"], "value": i["resultId"]} for i in healed]
    with open(os.path.join(calc, "lexer.iyi"), "a") as f:
        f.write("# touched\n")
    reply = c.send("workspace/diagnostic", {"previousResultIds": previous})
    touched = reply["result"]["items"]
    full = sorted(i["uri"].rsplit("/", 1)[-1] for i in touched if i["kind"] == "full")
    step("31d", "a changed import makes the pull full for its importers",
         full == ["lexer.iyi", "parser.iyi"],
         f"{full} full, {len(touched) - len(full)} unchanged")

    # 31e. and a keystroke while that walk is running is answered
    #      first. The walk is a compile per file and it used to own the
    #      loop for all of them: measured on the compiler's own tree, a
    #      hover sent 50 ms into a 94-file pull was answered 10.9
    #      seconds later, which is what "the editor froze" means. The
    #      server now reads its inbox between files; anything waiting
    #      stops the walk, and the pull says `-32802` with
    #      `retriggerRequest`, which is the code the diagnostic request
    #      has for exactly this and which the client answers by asking
    #      again when the typing stops.
    fill = os.path.join(work, "fill")
    os.makedirs(fill, exist_ok=True)
    for n in range(16):
        with open(os.path.join(fill, f"m{n:02}.iyi"), "w") as f:
            f.write(f"module fill/m{n:02}\n\n"
                    f"pub def value{n:02} : Int32\n  {n}\nend\n")
    pull_id = c.request_nowait("workspace/diagnostic", {"previousResultIds": []})
    time.sleep(0.25)
    started = time.monotonic()
    asked_id = c.request_nowait("textDocument/documentSymbol",
                                {"textDocument": {"uri": app_uri}})
    answers = {}
    while len(answers) < 2:
        message = c.read_message()
        if message.get("id") in (pull_id, asked_id):
            answers[message["id"]] = (time.monotonic() - started, message)
    waited, _ = answers[asked_id]
    _, pull = answers[pull_id]
    error = pull.get("error") or {}
    retrigger = (error.get("code") == -32802 and
                 (error.get("data") or {}).get("retriggerRequest") is True)
    step("31e", "a request during the workspace pull is answered first",
         waited < 1.5 and (retrigger or "result" in pull),
         f"answered in {waited * 1000:.0f} ms, pull "
         f"{'asked to be retriggered' if retrigger else 'ran to the end'}")
    shutil.rmtree(fill)

    # 32. references reach a file nobody opened: printer.iyi calls
    #     `token` from the disk, and the workspace walk finds it beside
    #     the open buffer's call — the gap gopls' index covers, closed
    #     without one.
    printer_path = os.path.join(calc, "printer.iyi")
    printer_text = ("module calc/printer\n\nimport calc/lexer\n"
                    "import calc/lexer::{token}\n\n"
                    "pub def show : String\n  token\nend\n\nputs show\n")
    with open(printer_path, "w") as f:
        f.write(printer_text)
    lexer_uri = file_uri(os.path.join(calc, "lexer.iyi"))
    reply = c.send("textDocument/references",
                   {"textDocument": {"uri": lexer_uri},
                    "position": {"line": 2, "character": 9},
                    "context": {"includeDeclaration": False}})
    locs = reply["result"] or []
    files = sorted({l["uri"].rsplit("/", 1)[-1] for l in locs})
    step(32, "references reach files nobody opened",
         "printer.iyi" in files and "parser.iyi" in files,
         f"{len(locs)} site(s) across {files}")

    # 33. rename follows: one request edits the declaration, the open
    #     consumer, and the consumer on disk — miss the last and the
    #     rename ships a program that does not compile.
    reply = c.send("textDocument/rename",
                   {"textDocument": {"uri": lexer_uri},
                    "position": {"line": 2, "character": 9},
                    "newName": "lex"})
    changes = reply["result"]["changes"]
    changed = sorted(u.rsplit("/", 1)[-1] for u in changes)
    step(33, "rename edits the unopened consumer too",
         changed == ["lexer.iyi", "parser.iyi", "printer.iyi"],
         f"{sum(len(e) for e in changes.values())} edit(s) across {changed}")

    # 34. incoming calls cross the same boundary: the def in lexer.iyi
    #     is called by defs in both consumers, one of them never opened.
    reply = c.send("textDocument/prepareCallHierarchy",
                   {"textDocument": {"uri": lexer_uri},
                    "position": {"line": 2, "character": 9}})
    items = reply["result"] or []
    incoming = []
    if items:
        reply = c.send("callHierarchy/incomingCalls", {"item": items[0]})
        incoming = reply["result"] or []
    callers = sorted(e["from"]["name"] for e in incoming)
    step(34, "incoming calls name the unopened caller",
         "first" in callers and "show" in callers,
         f"token <- {callers}")

    # 34b. which entries a workspace question compiles is R-1's answer,
    #      not "all of them": a module can refer to a def only through
    #      the module that declares it, imported directly or through
    #      another import. `use.iyi` imports only `shape/make`, whose
    #      `make` answers a `Box`, and calls `area` on it — a reference
    #      two imports away from the declaration, and found. `lone.iyi`
    #      imports nothing and declares an `area` of its own: it cannot
    #      hold a reference, so it is not compiled — which this step
    #      cannot see and `bench/lsp_latency.py`'s references budget
    #      can — and its `area` is not in the answer.
    shape = os.path.join(work, "shape")
    os.makedirs(shape, exist_ok=True)
    with open(os.path.join(shape, "base.iyi"), "w") as f:
        f.write("module shape/base\n\npub struct Box\n  def initialize\n  end\n\n"
                "  def area : Int32\n    4\n  end\nend\n")
    with open(os.path.join(shape, "make.iyi"), "w") as f:
        f.write("module shape/make\n\nimport shape/base::{Box}\n\n\n"
                "pub def make : Box\n  Box.new\nend\n")
    with open(os.path.join(work, "use.iyi"), "w") as f:
        f.write("module use\n\nimport shape/make::{make}\n\n\n"
                "puts make.area\n")
    with open(os.path.join(work, "lone.iyi"), "w") as f:
        f.write("module lone\n\nstruct Other\n  def area : Int32\n    1\n  end\nend\n\n"
                "puts Other.new.area\n")
    base_uri = file_uri(os.path.join(shape, "base.iyi"))
    reply = c.send("textDocument/references",
                   {"textDocument": {"uri": base_uri},
                    "position": {"line": 6, "character": 6},
                    "context": {"includeDeclaration": False}})
    locs = reply["result"] or []
    files = sorted({l["uri"].rsplit("/", 1)[-1] for l in locs})
    step("34b", "references reach through a transitive import",
         files == ["use.iyi"],
         f"{len(locs)} site(s) across {files}")

    # 35. auto-import completion: a fresh buffer that has never
    #     compiled types `tok`; the workspace's exports answer anyway
    #     (R-2 made `pub` a parse-time fact), and the item carries the
    #     import line as an additionalTextEdit - one line, since
    #     `import calc/lexer::{token}` loads the module and brings the name
    #     into scope, and the buffer compiling clean after it is
    #     the proof that the line is enough.
    scratch_path = os.path.join(work, "scratch.iyi")
    scratch_text = ("module scratch\n\ndef go : String\n  tok\nend\n\n"
                    "puts go\n")
    scratch_uri = file_uri(scratch_path)
    with open(scratch_path, "w") as f:
        f.write(scratch_text)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": scratch_uri, "languageId": "iyi",
                             "version": 1, "text": scratch_text}}, wait=False)
    c.diagnostics(scratch_uri)
    reply = c.send("textDocument/completion",
                   {"textDocument": {"uri": scratch_uri},
                    "position": {"line": 3, "character": 5}})
    items = reply["result"]["items"]
    token_item = next((i for i in items if i["label"] == "token"), None)
    edited = scratch_text
    if token_item:
        lines = edited.split("\n")
        lines[3] = "  token"
        for e in sorted(token_item.get("additionalTextEdits", []),
                        key=lambda e: -e["range"]["start"]["line"]):
            l = e["range"]["start"]["line"]
            s = e["range"]["start"]["character"]
            t = e["range"]["end"]["character"]
            if s == t == 0 and e["newText"].endswith("\n"):
                lines[l:l] = e["newText"].split("\n")[:-1]
            else:
                lines[l] = lines[l][:s] + e["newText"] + lines[l][t:]
        edited = "\n".join(lines)
    c.send("textDocument/didChange",
           {"textDocument": {"uri": scratch_uri, "version": 2},
            "contentChanges": [{"text": edited}]}, wait=False)
    clean = c.diagnostics(scratch_uri)["diagnostics"] == []
    step(35, "completion auto-imports across the workspace",
         token_item is not None and
         token_item["labelDetails"]["description"] == "calc/lexer" and
         "import calc/lexer" not in edited.split("\n") and
         "import calc/lexer::{token}" in edited and clean,
         "never-compiled buffer, item wrote the one import line")

    # 36. the selective import grows instead of doubling: the buffer
    #     already selects {token}; completing glyph extends that line.
    broken2 = edited.replace("\nputs go\n", "\nputs go\nputs gly\n")
    c.send("textDocument/didChange",
           {"textDocument": {"uri": scratch_uri, "version": 3},
            "contentChanges": [{"text": broken2}]}, wait=False)
    c.diagnostics(scratch_uri)
    last_line = broken2.count("\n") - 1
    reply = c.send("textDocument/completion",
                   {"textDocument": {"uri": scratch_uri},
                    "position": {"line": last_line, "character": 8}})
    items = reply["result"]["items"]
    glyph_item = next((i for i in items if i["label"] == "glyph"), None)
    extends = (glyph_item or {}).get("additionalTextEdits", [])
    new_using = extends[0]["newText"] if extends else ""
    step(36, "completion extends the selective import line",
         glyph_item is not None and len(extends) == 1 and
         new_using == "import calc/lexer::{token, glyph}",
         f"edit: {new_using!r}")

    # 37. fuzzy ranks below prefix but still answers: `ucs` finds
    #     upcase on the receiver, tiered after any prefix match.
    fuzzy_text = app_text.replace("\n  loud\n", "\n  loud.ucs\n")
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 18},
            "contentChanges": [{"text": fuzzy_text}]}, wait=False)
    c.diagnostics(app_uri)
    reply = c.send("textDocument/completion",
                   {"textDocument": {"uri": app_uri},
                    "position": {"line": 7, "character": 10}})
    items = reply["result"]["items"]
    upcase = next((i for i in items if i["label"] == "upcase"), None)
    step(37, "fuzzy completion finds upcase from ucs",
         upcase is not None and upcase["sortText"].startswith("4"),
         f"{len(items)} item(s), upcase tier "
         f"{upcase and upcase['sortText'][0]!r}")

    # 38. a queued request cancels before it compiles. The three frames
    #     go out in one write, so the server drains them together: the
    #     didChange is the work, the request queues behind it, and the
    #     sweep registers the cancel before the request is ever
    #     dispatched. Written frame by frame this asserted timing, not
    #     behaviour — and lost on a runner quicker than the laptop.
    rid = c.next_id + 1
    ids = c.write_batch([
        ("textDocument/didChange",
         {"textDocument": {"uri": app_uri, "version": 19},
          "contentChanges": [{"text": app_text}]}, False),
        ("workspace/diagnostic", {}, True),
        ("$/cancelRequest", {"id": rid}, False),
    ])
    reply = c.wait_for(lambda m: m.get("id") == rid)
    step(38, "a queued request cancels before the work",
         ids == [rid] and reply.get("error", {}).get("code") == -32800,
         f"answer: {reply.get('error', reply.get('result'))!r}")

    # 39. a typing burst is one verdict: six didChanges drained
    #     together coalesce into one compile, and the verdict is the
    #     final text's. One write again, for the same reason.
    burst = [("textDocument/didChange",
              {"textDocument": {"uri": app_uri, "version": 20 + n},
               "contentChanges": [{"text": app_text + f"# burst {n}\n"
                                   if n < 5 else app_text}]}, False)
             for n in range(6)]
    burst.append(("textDocument/documentSymbol",
                  {"textDocument": {"uri": app_uri}}, True))
    probe = c.write_batch(burst)[0]
    published = 0
    last = None
    while True:
        m = c.read_message()
        if m.get("method") == "textDocument/publishDiagnostics":
            published += 1
            last = m["params"]["diagnostics"]
        if m.get("id") == probe:
            break
    step(39, "a burst of six changes is one compile",
         published == 1 and last == [],
         f"{published} publish(es) for 6 didChanges, final verdict clean")

    # 40. document links: the import block is clickable — `import
    #     calc/lexer` and `import calc/lexer::{token}` both target lexer.iyi.
    reply = c.send("textDocument/documentLink",
                   {"textDocument": {"uri": parser_uri}})
    links = reply["result"] or []
    targets = {l["target"].rsplit("/", 1)[-1] for l in links}
    link_lines = sorted(l["range"]["start"]["line"] for l in links)
    step(40, "documentLink makes the import block clickable",
         targets == {"lexer.iyi"} and link_lines == [2, 3],
         f"{len(links)} link(s) at lines {link_lines}")

    # 41. type hierarchy, upward: Dot's supertypes include the trait
    #     its impl brought in.
    reply = c.send("textDocument/prepareTypeHierarchy",
                   {"textDocument": {"uri": shapes_uri},
                    "position": {"line": 6, "character": 12}})
    items = reply["result"] or []
    dot = items[0] if items else None
    supers = []
    if dot:
        reply = c.send("typeHierarchy/supertypes", {"item": dot})
        supers = reply["result"] or []
    super_names = sorted(s["name"] for s in supers)
    step(41, "type hierarchy climbs from Dot to Paint",
         dot is not None and dot["name"] == "Dot" and dot["kind"] == 23 and
         "Paint" in super_names,
         f"Dot <: {super_names}")

    # 42. and downward: Paint's subtypes include Dot.
    reply = c.send("textDocument/prepareTypeHierarchy",
                   {"textDocument": {"uri": shapes_uri},
                    "position": {"line": 2, "character": 11}})
    items = reply["result"] or []
    paint = items[0] if items else None
    subs = []
    if paint:
        reply = c.send("typeHierarchy/subtypes", {"item": paint})
        subs = reply["result"] or []
    sub_names = sorted(s["name"] for s in subs)
    step(42, "type hierarchy descends from Paint to Dot",
         paint is not None and paint["kind"] == 11 and "Dot" in sub_names,
         f"Paint :> {sub_names}")

    # 43. code lens and its command: the runnable module carries one
    #     lens, and executing it runs the program and returns what it
    #     printed — the released verb, over the wire.
    reply = c.send("textDocument/codeLens",
                   {"textDocument": {"uri": shapes_uri}})
    lenses = reply["result"] or []
    lens = lenses[0] if lenses else None
    ran = {}
    if lens:
        reply = c.send("workspace/executeCommand",
                       {"command": lens["command"]["command"],
                        "arguments": lens["command"]["arguments"]})
        ran = reply["result"] or {}
    step(43, "code lens runs the module over the wire",
         lens is not None and lens["range"]["start"]["line"] == 19 and
         ran.get("ok") and ran.get("output", "").strip() == ".",
         f"lens at line {lens and lens['range']['start']['line'] + 1}, "
         f"output {ran.get('output', '')!r}")

    # 43b. and a lens over a program that does not come back does not
    #      take the session with it. `iyi run` hands its pipes to the
    #      program it builds, so a program that serves holds them open
    #      for as long as it serves — and waiting on that pipe is what
    #      the server used to do, on the loop, with a thirty-second
    #      guard that could not fire because it waited on the same
    #      pipe. One click on a web app's `▶ run` and nothing was ever
    #      answered again. The verb rides its own fiber now.
    slow = os.path.join(work, "slow.iyi")
    with open(slow, "w") as f:
        f.write('module slow\n\nputs "started"\nsleep(2000)\nputs "done"\n')
    slow_uri = file_uri(slow)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": slow_uri, "languageId": "iyi",
                             "version": 1, "text": open(slow).read()}},
           wait=False)
    c.diagnostics(slow_uri)
    run_id = c.request_nowait("workspace/executeCommand",
                              {"command": "iyi.run", "arguments": [slow_uri]})
    started = time.monotonic()
    reply = c.send("textDocument/documentSymbol",
                   {"textDocument": {"uri": shapes_uri}})
    waited = time.monotonic() - started
    ran = c.wait_for(lambda m: m.get("id") == run_id)["result"]
    step("43b", "a run that does not return does not take the session",
         waited < 1.5 and ran.get("ok") and
         "done" in ran.get("output", ""),
         f"answered in {waited * 1000:.0f} ms while the program slept, "
         f"then the run said {ran.get('output', '').split()[-1]!r}")

    # 44. snippet completion: a callable with parameters lands with the
    #     cursor inside its parentheses, because initialize said the
    #     client renders snippets.
    snippet_text = edited + "puts yel\n"
    c.send("textDocument/didChange",
           {"textDocument": {"uri": scratch_uri, "version": 5},
            "contentChanges": [{"text": snippet_text}]}, wait=False)
    c.diagnostics(scratch_uri)
    reply = c.send("textDocument/completion",
                   {"textDocument": {"uri": scratch_uri},
                    "position": {"line": snippet_text.count("\n") - 1,
                                 "character": 8}})
    items = reply["result"]["items"]
    yell_item = next((i for i in items if i["label"] == "yell"), None)
    step(44, "completion snippets stop inside the parentheses",
         yell_item is not None and
         yell_item.get("insertText") == "yell($1)" and
         yell_item.get("insertTextFormat") == 2,
         f"insertText {yell_item and yell_item.get('insertText')!r}")

    # 45. semantic tokens delta: one appended line moves a few
    #     integers, not the file's whole stream, and the splice
    #     reconstructs exactly what a full answer says.
    reply = c.send("textDocument/semanticTokens/full",
                   {"textDocument": {"uri": shapes_uri}})
    first = reply["result"]
    c.send("textDocument/didChange",
           {"textDocument": {"uri": shapes_uri, "version": 2},
            "contentChanges": [{"text": shapes_text + "# renk\n"}]},
           wait=False)
    c.diagnostics(shapes_uri)
    reply = c.send("textDocument/semanticTokens/full/delta",
                   {"textDocument": {"uri": shapes_uri},
                    "previousResultId": first["resultId"]})
    delta = reply["result"]
    rebuilt = list(first["data"])
    for e in delta.get("edits", []):
        rebuilt[e["start"]:e["start"] + e["deleteCount"]] = e["data"]
    reply = c.send("textDocument/semanticTokens/full",
                   {"textDocument": {"uri": shapes_uri}})
    fresh = reply["result"]["data"]
    step(45, "semantic token deltas splice to the full answer",
         "edits" in delta and "data" not in delta and rebuilt == fresh,
         f"{len(delta.get('edits', []))} edit(s) over "
         f"{len(first['data'])} ints")

    # 46. the binary is rebuilt under the running session, and the
    #     session holds: `make iyi` unlinks the executable, which makes
    #     Process.executable_path nil on Linux — the first Cursor
    #     screenshot's "$ORIGIN" failure. The server pinned its origin
    #     at startup, so a fresh compile still finds the library. On
    #     Windows a running binary cannot be unlinked, and Makefile.win
    #     renames it aside instead (`REPLACE`), so that is what is done
    #     to it here.
    binary = os.environ.get("IYI_BINARY",
                            ".build/iyi.exe" if os.name == "nt" else ".build/iyi")
    if os.path.exists(binary):
        backup = binary + ".gate-backup"
        if os.name != "nt":
            shutil.copy2(binary, backup)
        # A didChange to app invalidates every sibling's overrides, so
        # the next question about greet is a fresh compile, not a memo.
        c.send("textDocument/didChange",
               {"textDocument": {"uri": app_uri, "version": 26},
                "contentChanges": [{"text": app_text + "# gone\n"}]},
               wait=False)
        c.diagnostics(app_uri)
        if os.name == "nt":
            os.rename(binary, backup)
        else:
            os.remove(binary)
        try:
            reply = c.send("textDocument/diagnostic",
                           {"textDocument": {"uri": greet_uri}})
        finally:
            shutil.move(backup, binary)
        held = (reply.get("result") or {}).get("kind") == "full"
        step(46, "a rebuilt binary does not lobotomise the session",
             held and "error" not in reply,
             "compiled with the executable moved aside, as a rebuild does"
             if os.name == "nt" else
             "compiled with the executable unlinked; $ORIGIN was pinned")
    else:
        step(46, "a rebuilt binary does not lobotomise the session", True,
             f"skipped: {binary} not present under this runner")

    # 47. organize imports: duplicates merge, selections of one module
    #     unify sorted, the bare import folds into the selection — and the
    #     organized buffer still compiles.
    messy_path = os.path.join(work, "tidy.iyi")
    messy = ("module tidy\n\n"
             "import calc/lexer::{token}\n"
             "import calc/lexer\n"
             "import calc/lexer::{glyph}\n"
             "import calc/lexer\n\n"
             "puts token\nputs glyph\n")
    messy_uri = file_uri(messy_path)
    with open(messy_path, "w") as f:
        f.write(messy)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": messy_uri, "languageId": "iyi",
                             "version": 1, "text": messy}}, wait=False)
    c.diagnostics(messy_uri)
    reply = c.send("textDocument/codeAction",
                   {"textDocument": {"uri": messy_uri},
                    "range": {"start": {"line": 0, "character": 0},
                              "end": {"line": 0, "character": 0}},
                    "context": {"diagnostics": [],
                                "only": ["source.organizeImports"]}})
    organizers = reply["result"] or []
    tidied = messy
    if organizers:
        lines = messy.split("\n")
        for e in organizers[0]["edit"]["changes"][messy_uri]:
            s, t = e["range"]["start"]["line"], e["range"]["end"]["line"]
            lines[s:t + 1] = e["newText"].split("\n")
        tidied = "\n".join(lines)
    c.send("textDocument/didChange",
           {"textDocument": {"uri": messy_uri, "version": 2},
            "contentChanges": [{"text": tidied}]}, wait=False)
    clean = c.diagnostics(messy_uri)["diagnostics"] == []
    step(47, "organize imports canonicalises the header",
         len(organizers) == 1 and clean and
         "import calc/lexer::{glyph, token}\n\n" in tidied
         and tidied.count("import calc/lexer") == 1,
         "four imports of one module -> one selective line, sorted, still clean")

    # 48. willRenameFiles: moving the file is renaming the module
    #     (IV.6), so one request rewrites the header and every
    #     consumer's imports — buffers and never-opened disk files
    #     alike — and the moved module still compiles.
    lexer_path = os.path.join(calc, "lexer.iyi")
    scanner_path = os.path.join(calc, "scanner.iyi")
    reply = c.send("workspace/willRenameFiles",
                   {"files": [{"oldUri": file_uri(lexer_path),
                               "newUri": file_uri(scanner_path)}]})
    changes = (reply["result"] or {}).get("changes", {})
    touched = sorted(u.rsplit("/", 1)[-1] for u in changes)

    def apply(text, edits):
        lines = text.split("\n")
        for e in sorted(edits, key=lambda e: (-e["range"]["start"]["line"],
                                              -e["range"]["start"]["character"])):
            l = e["range"]["start"]["line"]
            s, t = e["range"]["start"]["character"], e["range"]["end"]["character"]
            lines[l] = lines[l][:s] + e["newText"] + lines[l][t:]
        return "\n".join(lines)

    with open(lexer_path) as f:
        lexer_text = f.read()
    moved = apply(lexer_text, changes.get(file_uri(lexer_path), []))
    with open(scanner_path, "w") as f:
        f.write(moved)
    os.remove(lexer_path)
    parser_moved = apply(parser_text, changes.get(parser_uri, []))
    c.send("textDocument/didChange",
           {"textDocument": {"uri": parser_uri, "version": 2},
            "contentChanges": [{"text": parser_moved}]}, wait=False)
    clean = c.diagnostics(parser_uri)["diagnostics"] == []
    step(48, "willRenameFiles moves the module with the file",
         touched == ["lexer.iyi", "parser.iyi", "printer.iyi",
                     "scratch.iyi", "tidy.iyi"] and
         "module calc/scanner" in moved and
         "import calc/scanner" in parser_moved and clean,
         f"{sum(len(e) for e in changes.values())} edit(s) across {touched}")

    # 48b. A document link on an import, including a package's. The links
    #      were a filename guess — `<root>/<path>.iyi`, with the path taken
    #      as the run of `[A-Za-z0-9_/]` after the keyword — so a dotted
    #      package path stopped at the first `.` and the file it names is
    #      not under the workspace at all: it is a checkout in the cache,
    #      which `iyi.mod`, `iyi.sum` and the fetcher decide between them.
    #      Every import of a dependency was a link that went nowhere, in an
    #      editor where the same click works on a sibling module. The
    #      fixture lives outside the workspace because its import does not
    #      resolve without the cache this test warms, and step 31 judges
    #      every file the workspace holds.
    pkg = package_fixture(pkg_home)
    if pkg:
        pkg_path, pkg_text, pkg_cache = pkg
        pkg_uri = file_uri(pkg_path)
        c.send("textDocument/didOpen",
               {"textDocument": {"uri": pkg_uri, "languageId": "iyi",
                                 "version": 1, "text": pkg_text}}, wait=False)
        c.diagnostics(pkg_uri)
        reply = c.send("textDocument/documentLink", {"textDocument": {"uri": pkg_uri}})
        links = reply.get("result") or []
        by_line = {l["range"]["start"]["line"]: l["target"] for l in links}
        # As paths, not strings: `pkg_cache` is a filesystem path and a
        # target is a URI, which on Windows share no substring at all.
        cache_dir = os.path.normcase(os.path.normpath(pkg_cache))
        into_cache = [t for t in by_line.values()
                      if uri_path(t).startswith(cache_dir + os.sep)]
        beside = [t for t in by_line.values() if t.endswith("/helper.iyi")]
        step(48, "a document link follows a package import into the cache",
             len(links) == 4 and len(into_cache) == 2 and len(beside) == 2,
             f"{len(links)} link(s): {sorted(os.path.basename(t) for t in by_line.values())}")
        c.send("textDocument/didClose", {"textDocument": {"uri": pkg_uri}},
               wait=False)
    else:
        step(48, "a document link follows a package import into the cache",
             False, "the package fixture needs git, which this run has none of")

    # 49-52. What the server says when it cannot answer. Every one of
    # these used to be an empty result or an "internal error": an unknown
    # method answered `result: null`, which a client cannot tell from
    # "nothing at that position" and which is how it learns to stop
    # asking; a frame that is not JSON was dropped in silence, leaving
    # the request it carried unanswered forever; a file the client named
    # that is not there came back -32603 ("this server is broken") in the
    # runtime's own words, `Error opening file with mode 'r'`; and a
    # request with no `textDocument` came back with the JSON library's
    # `Missing hash key`.
    reply = c.send("nonesuch/method", {})
    step(49, "an unknown method is method-not-found",
         reply.get("error", {}).get("code") == -32601
         and "nonesuch/method" in reply["error"]["message"],
         json.dumps(reply.get("error"))[:80])

    c.raw(b"Content-Length: 5\r\n\r\n{oops")
    parse_error = c.wait_for(lambda m: "error" in m)
    step(50, "a frame that is not JSON is a parse error, not silence",
         parse_error["error"]["code"] == -32700 and parse_error["id"] is None,
         json.dumps(parse_error)[:80])

    reply = c.send("textDocument/hover", {
        "textDocument": {"uri": file_uri(os.path.join(work, "nope.iyi"))},
        "position": {"line": 0, "character": 0}})
    step(51, "a file the client named that is not there is invalid params",
         reply.get("error", {}).get("code") == -32602
         and "No such file" in reply["error"]["message"]
         and "mode 'r'" not in reply["error"]["message"],
         json.dumps(reply.get("error"))[:80])

    reply = c.send("textDocument/hover", {})
    step(52, "a request with no textDocument names what is missing",
         reply.get("error", {}).get("code") == -32602
         and "textDocument" in reply["error"]["message"]
         and "Missing hash key" not in reply["error"]["message"],
         json.dumps(reply.get("error"))[:80])

    # 52b. The client's other mistakes, each with the protocol's own code:
    # a request with no params at all was -32603 "Nil assertion failed"
    # (the server blaming itself for the client's omission), one whose
    # params are the wrong shape was -32603 with the JSON library's
    # sentence, and a frame whose body is JSON but not an object - `[]` -
    # raised outside every rescue and took the server down, backtrace
    # and all. A request with no method got nothing, and the client
    # waited for it.
    reply = c.send_raw_request({"jsonrpc": "2.0", "id": 9001, "method": "textDocument/hover"}, 9001)
    step("52b", "a request with no params is invalid params, not the server's fault",
         reply.get("error", {}).get("code") == -32602
         and "no params" in reply["error"]["message"],
         json.dumps(reply.get("error"))[:80])
    reply = c.send_raw_request({"jsonrpc": "2.0", "id": 9002, "method": "textDocument/hover", "params": "string"}, 9002)
    step("52c", "params of the wrong shape are invalid params",
         reply.get("error", {}).get("code") == -32602
         and "shape" in reply["error"]["message"],
         json.dumps(reply.get("error"))[:80])
    c.raw(b"Content-Length: 2\r\n\r\n[]")
    reply = c.wait_for(lambda m: m.get("id") is None and "error" in m)
    step("52d", "a JSON array is an invalid request, and the session goes on",
         reply.get("error", {}).get("code") == -32600 and c.proc.poll() is None,
         json.dumps(reply.get("error"))[:80])
    reply = c.send_raw_request({"jsonrpc": "2.0", "id": 9003}, 9003)
    step("52e", "a request with no method is an invalid request",
         reply.get("error", {}).get("code") == -32600,
         json.dumps(reply.get("error"))[:80])
    reply = c.send("textDocument/hover", {
        "textDocument": {"uri": app_uri}, "position": {"line": 0, "character": 0}})
    step("52f", "and the session is still answering after all four",
         "error" not in reply or reply["error"].get("code") not in (-32603,),
         json.dumps(reply)[:60])

    # 53. shutdown/exit: the server leaves when told, not before — and
    # between the two it answers a request with the code the protocol has
    # for it rather than an empty result.
    c.send("shutdown", {})
    reply = c.send("textDocument/hover", {
        "textDocument": {"uri": app_uri}, "position": {"line": 0, "character": 0}})
    step(53, "after shutdown, a request is refused rather than half answered",
         reply.get("error", {}).get("code") == -32600,
         json.dumps(reply.get("error"))[:80])
    c.send("exit", {}, wait=False)
    step(54, "shutdown then exit", c.proc.wait(timeout=10) == 0)

    # 55. A fresh server, asked before the handshake and left without one:
    # a request before `initialize` is -32002 by the protocol's own code
    # (it used to be answered as if the root were the working directory),
    # and an `exit` with no `shutdown` before it exits 1, which is how a
    # client that reads the code learns which conversation it had.
    d = Client()
    reply = d.send("textDocument/hover", {
        "textDocument": {"uri": app_uri}, "position": {"line": 0, "character": 0}})
    step(55, "a request before initialize is told so",
         reply.get("error", {}).get("code") == -32002,
         json.dumps(reply.get("error"))[:80])
    d.send("exit", {}, wait=False)
    step(56, "exit without shutdown exits 1", d.proc.wait(timeout=10) == 1)

    print("lsp gate: every step held")


if __name__ == "__main__":
    main()
