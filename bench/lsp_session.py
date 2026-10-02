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


def process_binary(pid):
    """The file *pid* was started from. Linux's `/proc/<pid>/exe`; on
    Windows the image name the kernel keeps for the process, which is the
    same path, and a running `.exe` may be renamed there, not deleted."""
    if os.name != "nt":
        return os.readlink(f"/proc/{pid}/exe")
    import ctypes
    from ctypes import wintypes
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.QueryFullProcessImageNameW.argtypes = [
        wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        raise OSError(ctypes.get_last_error(), "OpenProcess")
    try:
        size = wintypes.DWORD(32768)
        path = ctypes.create_unicode_buffer(size.value)
        if not kernel32.QueryFullProcessImageNameW(handle, 0, path, ctypes.byref(size)):
            raise OSError(ctypes.get_last_error(), "QueryFullProcessImageNameW")
        return path.value
    finally:
        kernel32.CloseHandle(handle)


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


def opened(c, work, name, text):
    """Write *name* under *work*, open it, and wait for its verdict."""
    path = os.path.join(work, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    uri = file_uri(path)
    c.send("textDocument/didOpen", {"textDocument": {
        "uri": uri, "languageId": "iyi", "version": 1, "text": text}}, wait=False)
    c.diagnostics(uri)
    return uri


def at(text, line, needle, nth=0):
    """The UTF-16 character of the *nth* *needle* on *line* of *text*."""
    row = text.split("\n")[line]
    index = -1
    for _ in range(nth + 1):
        index = row.index(needle, index + 1)
    return len(row[:index].encode("utf-16-le")) // 2


def span_text(text, rng):
    row = text.split("\n")[rng["start"]["line"]]
    units = row.encode("utf-16-le")
    return units[2 * rng["start"]["character"]:2 * rng["end"]["character"]].decode("utf-16-le")


def fuzz_steps(c, work):
    """What a fuzz over the library and the samples found: 441,870
    requests from positions nobody chose. Each step failed before its fix."""

    # 52j. Every `getter` was one method. A def a macro writes is keyed by
    # its file, and the file of every expansion was "expanded macro:
    # getter", at the same line and column: references to `p.x` listed
    # `p.y` and `n.first`, and a rename rewrote all three.
    getters = ("module getters\n\nstruct Point\n  getter x : Int32\n  getter y : Int32\n\n"
               "  def initialize(@x : Int32, @y : Int32)\n  end\nend\n\n"
               "struct Name\n  getter first : String\n\n  def initialize(@first : String)\n  end\nend\n\n"
               "p = Point.new(1, 2)\nn = Name.new(\"a\")\nputs p.x\nputs p.y\nputs n.first\n")
    uri = opened(c, work, "getters.iyi", getters)
    reply = c.send("textDocument/references", {
        "textDocument": {"uri": uri}, "position": {"line": 19, "character": 7},
        "context": {"includeDeclaration": True}})
    texts = {span_text(getters, loc["range"]) for loc in reply.get("result") or []}
    step("52j", "references to one getter are that getter's alone", texts == {"x"}, str(sorted(texts)))
    reply = c.send("textDocument/rename", {
        "textDocument": {"uri": uri}, "position": {"line": 19, "character": 7}, "newName": "xx"})
    step("52k", "a getter is not renamed from a call, which would leave the getter behind",
         reply.get("error", {}).get("code") == -32803, json.dumps(reply)[:100])

    # 52l. A `new` the compiler makes from `initialize` carries the
    # initialize's location, so the two were one def: renaming
    # `Point.new` wrote the new name over `def initialize`, keyword and
    # name, and renaming `initialize` rewrote the `def` and the `.new`.
    reply = c.send("textDocument/rename", {
        "textDocument": {"uri": uri}, "position": {"line": 17, "character": 10}, "newName": "make"})
    step("52l", "`new` made from initialize is refused a rename",
         reply.get("error", {}).get("code") == -32803, json.dumps(reply)[:100])
    reply = c.send("textDocument/rename", {
        "textDocument": {"uri": uri}, "position": {"line": 6, "character": 8}, "newName": "setup"})
    edits = [span_text(getters, e["range"])
             for e in (reply.get("result") or {}).get("changes", {}).get(uri, [])]
    step("52m", "renaming initialize touches its name and nothing else", edits == ["initialize"], str(edits))

    # 52n. Signature help counted every `,` walking back to the `(`:
    # inside a string, an array, a hash. `pair(1, "x, y"` was on the
    # third parameter of a two-parameter method.
    sig = ("module sig\n\nstruct Words\n  def initialize(@a : Array(String))\n  end\nend\n\n"
           "struct Nums\n  def initialize(@a : Array(Int32))\n  end\nend\n\n"
           "def pair(a : Int32, b : String) : String\n  \"#{a}#{b}\"\nend\n\n"
           "w = Words.new([\"pear\", \"fig\", \"plum\"])\nn = Nums.new([3, 1, 4])\n"
           "puts pair(1, \"x, y\")\nputs [1, 2].zip([\"a\", \"b\"])\n")
    uri = opened(c, work, "sig.iyi", sig)

    def helped(line, needle):
        return c.send("textDocument/signatureHelp", {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": at(sig, line, needle)}}).get("result") or {}
    in_string = helped(18, ")").get("activeParameter")
    in_array = helped(19, "\"b").get("activeParameter")
    step("52n", "commas in a string or an array are not arguments",
         in_string == 1 and in_array == 0, f"pair: {in_string}, zip: {in_array}")

    # 52o. `Nums.new(` in a module file: the type was looked up at the top
    # level only, where a module's types are not, and the fallback took
    # every call named `new` in the file - `Words`' constructor first.
    labels = [s["label"] for s in helped(17, "4").get("signatures", [])]
    step("52o", "a constructor's signatures are its own type's", labels == ["new(a : Array(Int32))"], str(labels))

    # 52p. The outline's selection is the name as written: it was the
    # listed name's length from the name's start (`self.encode` covered
    # `encode(v`) or from the keyword (`enum Level` covered `enum `).
    outline = ("module outline\n\nenum Level\n  Low\n  High\nend\n\nstruct Box\n"
               "  def self.make(v : Int32) : Box\n    Box.new\n  end\nend # 🎉\n")
    uri = opened(c, work, "outline.iyi", outline)
    reply = c.send("textDocument/documentSymbol", {"textDocument": {"uri": uri}})
    found = {}

    def walk(symbols):
        for s in symbols or []:
            found[s["name"]] = (span_text(outline, s["selectionRange"]), s["range"])
            walk(s.get("children"))
    walk(reply.get("result"))
    named = {name: written for name, (written, _) in found.items()}
    box_end = found.get("Box", (None, {"end": {}}))[1]["end"].get("character")
    step("52p", "a symbol's selection is its written name, and its range ends in UTF-16",
         named.get("self.make") == "make" and named.get("Level") == "Level" and box_end == 8,
         f"{named} Box ends at {box_end}")

    # 52q. A buffer that stops compiling is answered from the last program
    # that did, and that program's lines were read as the buffer's: press
    # Enter above a call, type half a call, and definition on `greet`
    # landed on `def shout`, the line below's callee.
    stale = ("module stale\n\ndef greet(name : String) : String\n  \"hi #{name}\"\nend\n\n"
             "def shout(name : String) : String\n  name.upcase\nend\n\n"
             "a = greet(\"x\")\nb = shout(\"y\")\nputs a\nputs b\n")
    uri = opened(c, work, "stale.iyi", stale)
    c.send("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": 2},
        "contentChanges": [{"range": {"start": {"line": 10, "character": 0},
                                      "end": {"line": 10, "character": 0}},
                            "text": "c = greet(\n"}]}, wait=False)
    c.diagnostics(uri)
    lines = []
    for line in (11, 12):
        reply = c.send("textDocument/definition", {
            "textDocument": {"uri": uri}, "position": {"line": line, "character": 4}})
        lines.append([loc["range"]["start"]["line"] for loc in reply.get("result") or []])
    step("52q", "below a line being typed, definition still names the callee written there",
         lines == [[2], [6]], str(lines))


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

    # 70i. A diagnostic's relatedInformation is in wire units like its
    #      range: the "instantiating" note for an `f(1)` behind two emoji
    #      went out at character 10, the codepoint column, where the
    #      editor has the call at 12.
    related_uri = file_uri(os.path.join(tempfile.mkdtemp(prefix="iyi-lsp-related"), "related.iyi"))
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": related_uri, "languageId": "iyi", "version": 1,
                             "text": 'module related\n\ndef f(x)\n  x.nope\nend\n\ns = "\U0001F600\U0001F600"; f(1)\n'}},
           wait=False)
    notes = [(r["location"]["range"]["start"]["line"], r["location"]["range"]["start"]["character"])
             for d in c.diagnostics(related_uri)["diagnostics"] for r in d.get("relatedInformation", [])]
    c.send("textDocument/didClose", {"textDocument": {"uri": related_uri}}, wait=False)
    step("70i", "relatedInformation is in UTF-16 units", (6, 12) in notes, f"notes at {notes}")

    # 70n. An error inside a macro's expansion is placed at the call. Its
    #      line and column were the expansion's, read as the file's, so the
    #      typo in `{{x}}.upcse`, expanded from line 6, was underlined on
    #      the `module` header - line 0, characters 8 to 10 on the wire -
    #      with a quick fix that wrote `upcase` into the header.
    macro_uri = file_uri(os.path.join(tempfile.mkdtemp(prefix="iyi-lsp-macro"), "mac.iyi"))
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": macro_uri, "languageId": "iyi", "version": 1,
                             "text": 'module mac\n\nmacro m(x)\n  {{x}}.upcse\nend\nputs m("abc")\n'}},
           wait=False)
    macro_diags = c.diagnostics(macro_uri)["diagnostics"]
    placed = [(d["range"]["start"]["line"], d["range"]["start"]["character"], d["range"]["end"]["character"])
              for d in macro_diags]
    reply = c.send("textDocument/codeAction",
                   {"textDocument": {"uri": macro_uri},
                    "range": macro_diags[0]["range"] if macro_diags else
                    {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}},
                    "context": {"diagnostics": macro_diags}})
    macro_fixes = [a["title"] for a in reply.get("result") or []]
    c.send("textDocument/didClose", {"textDocument": {"uri": macro_uri}}, wait=False)
    step("70n", "an error in a macro's expansion is at the call, with no edit",
         placed == [(5, 5, 6)] and "upcse" in macro_diags[0]["message"] and macro_fixes == [],
         f"at {placed}, fixes {macro_fixes}")

    # 71a. A diagnostic's message is text, not a terminal's. The server's
    #      compiler kept the colour every compiler had unless `--no-color`
    #      said otherwise, and messages carry it in their text: a nil
    #      receiver's diagnostic, published and pulled, read
    #      "for Nil\u001b[33;1m (compile-time type is (String | Nil))".
    nil_uri = file_uri(os.path.join(tempfile.mkdtemp(prefix="iyi-lsp-colour"), "nilsize.iyi"))
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": nil_uri, "languageId": "iyi", "version": 1,
                             "text": 'module nilsize\n\nx = Program.args.size > 0 ? "a" : nil\nputs x.size\n'}},
           wait=False)
    published = [d["message"] for d in c.diagnostics(nil_uri)["diagnostics"]]
    reply = c.send("textDocument/diagnostic", {"textDocument": {"uri": nil_uri}})
    pulled = [d["message"] for d in (reply.get("result") or {}).get("items", [])]
    c.send("textDocument/didClose", {"textDocument": {"uri": nil_uri}}, wait=False)
    said = published + pulled
    step("71a", "a diagnostic's message carries no colour, published or pulled",
         len(published) == 1 and len(pulled) == 1
         and all("for Nil (compile-time type is (String | Nil))" in m and "\x1b" not in m for m in said),
         f"{[m[:60] for m in said]}")

    # 6. definition on the call jumps into the sibling module's def.
    reply = c.send("textDocument/definition",
                   {"textDocument": {"uri": app_uri},
                    "position": {"line": 6, "character": 11}})
    locs = reply["result"] or []
    step(6, "definition jumps to the import",
         any(l["uri"].endswith("greet.iyi") and
             l["range"]["start"]["line"] == 2 for l in locs),
         f"{len(locs)} location(s), first {locs and locs[0]['uri']}")

    # 6b. definition on a call in the module's top-level code: `puts run`,
    #     line 10, jumps to `def run` in the same file. The module a header
    #     opens was marked as ending on the header's line, and the lookup
    #     never looked inside it - the same call in a `def` found its target.
    reply = c.send("textDocument/definition",
                   {"textDocument": {"uri": app_uri},
                    "position": {"line": 10, "character": 6}})
    locs = reply["result"] or []
    step("6b", "definition from top-level code jumps to the def",
         any(l["uri"] == app_uri and l["range"]["start"]["line"] == 5
             for l in locs),
         f"{len(locs)} location(s), first {locs and (locs[0]['uri'], locs[0]['range']['start']['line'])}")

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
         "app" in names and "run" in names, f"symbols {names}")

    # 70l. and a symbol's selectionRange is its name. The file's module was
    #      named `App`, the desugared spelling, and selected `mod` - the
    #      `module` keyword's column for that name's length - and an enum
    #      selected `enum`. The module is named as its header writes it.
    unit_sel = ((reply["result"] or [{}])[0]).get("selectionRange", {})
    renk_uri = file_uri(os.path.join(tempfile.mkdtemp(prefix="iyi-lsp-outline"), "renk.iyi"))
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": renk_uri, "languageId": "iyi", "version": 1,
                             "text": "module renk\n\nenum Renk\n  Kirmizi\n  Yesil\nend\n\nputs Renk::Yesil\n"}},
           wait=False)
    c.diagnostics(renk_uri)
    renk = c.send("textDocument/documentSymbol", {"textDocument": {"uri": renk_uri}})["result"] or [{}]
    c.send("textDocument/didClose", {"textDocument": {"uri": renk_uri}}, wait=False)
    spans = [(s["name"], s["selectionRange"]["start"]["character"], s["selectionRange"]["end"]["character"])
             for s in [renk[0]] + renk[0].get("children", [])]
    step("70l", "a symbol's selectionRange is its name",
         (unit_sel.get("start", {}).get("character"), unit_sel.get("end", {}).get("character")) == (7, 10)
         and spans == [("renk", 7, 11), ("Renk", 5, 9)],
         f"app selects {unit_sel}, renk {spans}")

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

    # 12a. bare completion offers the module's own functions: `run` has no
    #      `pub`, so it is the module's alone - callable anywhere in it
    #      without a receiver, and left off the list because the list
    #      dropped every private def; and top-level code had no `self` in
    #      its scope to ask at all. Typed once inside a def, once at the top.
    offered = []
    for version, text, line, character in (
            (70, holler_app.replace("\n  loud\n", "\n  ru\n"), 7, 4),
            (71, holler_app.replace("\nputs run\n", "\nputs ru\n"), 10, 7)):
        c.send("textDocument/didChange",
               {"textDocument": {"uri": app_uri, "version": version},
                "contentChanges": [{"text": text}]}, wait=False)
        c.diagnostics(app_uri)
        reply = c.send("textDocument/completion",
                       {"textDocument": {"uri": app_uri},
                        "position": {"line": line, "character": character}})
        offered.append(any(i["label"] == "run" for i in reply["result"]["items"]))
    step("12a", "bare completion offers the module's own functions",
         offered == [True, True],
         f"inside a def {offered[0]}, at the top level {offered[1]}")
    # Back to the text step 12 left, for the steps that follow.
    c.send("textDocument/didChange",
           {"textDocument": {"uri": app_uri, "version": 72},
            "contentChanges": [{"text": bare}]}, wait=False)
    c.diagnostics(app_uri)

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

    # 70h. A quick fix is still offered after an idle replacement, for every
    #      open file and not only the one last edited. The successor is
    #      handed the buffers and compiles the focused one, and the other's
    #      verdict, still on screen, had no fix behind it: "Change to
    #      'upcase'" before a three-second pause, [] after it.
    quick_root = tempfile.mkdtemp(prefix="iyi-lsp-quickfix")
    quick = {"a.iyi": 'module a\n\nloud = "x"\nputs loud.upcsae\n',
             "b.iyi": 'module b\n\nquiet = "y"\nputs quiet.downcsae\n'}
    for name, body in quick.items():
        with open(os.path.join(quick_root, name), "w", newline="") as f:
            f.write(body)
    q = Client()
    q.send("initialize", {"rootUri": file_uri(quick_root), "capabilities": {}})
    q.send("initialized", {}, wait=False)
    quick_diags = {}
    for name, body in quick.items():
        uri = file_uri(os.path.join(quick_root, name))
        q.send("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "iyi",
                                                          "version": 1, "text": body}}, wait=False)
        quick_diags[name] = (uri, q.diagnostics(uri)["diagnostics"])

    def quick_fixes():
        uri, diags = quick_diags["a.iyi"]
        reply = q.send("textDocument/codeAction", {"textDocument": {"uri": uri}, "range": diags[0]["range"],
                                                   "context": {"diagnostics": diags}})
        return [a["title"] for a in reply.get("result") or []]
    before = quick_fixes()
    time.sleep(3)  # the proxy replaces a worker after two quiet seconds
    after = quick_fixes()
    q.send("shutdown", {})
    q.send("exit", {}, wait=False)
    q.proc.wait(timeout=10)
    step("70h", "a quick fix outlives an idle replacement in every open file",
         before == after == ["Change to 'upcase'"], f"before {before}, after {after}")

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

    # 18b. documentHighlight on a local variable, which is neither a def
    #      nor a call: it answered null. Its scope is the def, a block's
    #      own parameter is another variable, and a same-named local in
    #      another def is not this one. A document of its own, open in
    #      the editor and never saved, so no other step sees it.
    scoped = ("module locals\n\n"
              "def one(count : Int32) : Int32\n"
              "  total = count\n"
              "  [1, 2].each do |count|\n"
              "    total = total + count\n"
              "  end\n"
              "  total\n"
              "end\n\n"
              "def two : Int32\n"
              "  total = 5\n"
              "  total\n"
              "end\n\n"
              "puts one(1) + two\n")
    locals_uri = file_uri(os.path.join(work, "locals.iyi"))
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": locals_uri, "languageId": "iyi",
                             "version": 1, "text": scoped}}, wait=False)
    c.diagnostics(locals_uri)

    def sites(line, character):
        reply = c.send("textDocument/documentHighlight",
                       {"textDocument": {"uri": locals_uri},
                        "position": {"line": line, "character": character}})
        return sorted((h["range"]["start"]["line"],
                       h["range"]["start"]["character"], h["kind"])
                      for h in reply["result"] or [])

    total = sites(7, 3)
    param = sites(3, 10)
    block = sites(5, 21)
    step("18b", "documentHighlight marks a local in its own scope",
         total == [(3, 2, 3), (5, 4, 3), (5, 12, 2), (7, 2, 2)] and
         param == [(2, 8, 3), (3, 10, 2)] and
         block == [(4, 18, 3), (5, 20, 2)],
         f"total {total}, count {param}, the block's count {block}")

    # 18c. The same sites answer references and rename, which refused a
    #      local ("rename serves defs and their calls"): an editor could
    #      not rename a variable at all. A new name already used in the
    #      scope is refused, since the two would become one variable.
    at_total = {"textDocument": {"uri": locals_uri},
                "position": {"line": 7, "character": 3}}
    refs = c.send("textDocument/references",
                  dict(at_total, context={"includeDeclaration": False}))["result"] or []
    ref_lines = sorted((r["range"]["start"]["line"], r["range"]["start"]["character"]) for r in refs)
    prepared = c.send("textDocument/prepareRename", at_total)["result"] or {}
    renamed = c.send("textDocument/rename", dict(at_total, newName="sum"))
    edits = (renamed.get("result") or {}).get("changes", {})
    edit_sites = sorted((e["range"]["start"]["line"], e["range"]["start"]["character"], e["newText"])
                        for e in edits.get(locals_uri, []))
    clash = c.send("textDocument/rename", dict(at_total, newName="count"))
    clash_error = (clash.get("error") or {}).get("message", "")
    step("18c", "references and rename serve a local, and a clash is refused",
         ref_lines == [(5, 4), (5, 12), (7, 2)] and
         prepared.get("placeholder") == "total" and
         list(edits) == [locals_uri] and
         edit_sites == [(3, 2, "sum"), (5, 4, "sum"), (5, 12, "sum"), (7, 2, "sum")] and
         "already a name" in clash_error,
         f"references {ref_lines}, rename {edit_sites}, clash {clash_error[:60]!r}")

    # 18d. Definition on a local is where it is first bound: a use of
    #      `total` jumps to its first assignment, a use of the parameter
    #      `count` to the parameter, a use of the block's `count` to the
    #      block's. It answered null, `tool implementations` knowing calls.
    def defined(line, character):
        reply = c.send("textDocument/definition",
                       {"textDocument": {"uri": locals_uri},
                        "position": {"line": line, "character": character}})
        return [(d["range"]["start"]["line"], d["range"]["start"]["character"])
                for d in reply["result"] or []]
    jumps = [defined(7, 3), defined(3, 10), defined(5, 21)]
    step("18d", "definition on a local is where it is bound",
         jumps == [[(3, 2)], [(2, 8)], [(4, 18)]], f"{jumps}")
    c.send("textDocument/didClose",
           {"textDocument": {"uri": locals_uri}}, wait=False)

    # 18e. An instance variable: every `@count` of its class, and the name
    #      its accessor declares, which is the field's declaration. The
    #      `@count` parameter is the field's too, not a local; a local
    #      `count` beside it is its own variable; a nested class's
    #      `@count` is another field. It answered null to all three
    #      questions, and it is not renamed alone: its accessor carries the
    #      name as a method.
    fields = ("module fields\n\n"
              "class Counter\n"
              "  getter count : Int32\n"
              "\n"
              "  def initialize(@count : Int32)\n"
              "  end\n"
              "\n"
              "  def bump : Nil\n"
              "    count = 5\n"
              "    @count = @count + count\n"
              "  end\n"
              "\n"
              "  class Inner\n"
              "    def initialize(@count : Int32)\n"
              "    end\n"
              "  end\n"
              "end\n\n"
              "puts Counter.new(1).count\n")
    fields_uri = file_uri(os.path.join(work, "fields.iyi"))
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": fields_uri, "languageId": "iyi",
                             "version": 1, "text": fields}}, wait=False)
    c.diagnostics(fields_uri)
    at_field = {"textDocument": {"uri": fields_uri},
                "position": {"line": 10, "character": 14}}
    lit = sorted((h["range"]["start"]["line"], h["range"]["start"]["character"],
                  h["range"]["end"]["character"], h["kind"])
                 for h in c.send("textDocument/documentHighlight", at_field)["result"] or [])
    local_lit = sorted((h["range"]["start"]["line"], h["range"]["start"]["character"])
                       for h in c.send("textDocument/documentHighlight",
                                       {"textDocument": {"uri": fields_uri},
                                        "position": {"line": 10, "character": 23}})["result"] or [])
    field_refs = sorted((r["range"]["start"]["line"], r["range"]["start"]["character"])
                        for r in c.send("textDocument/references",
                                        dict(at_field, context={"includeDeclaration": False}))["result"] or [])
    field_def = [(d["range"]["start"]["line"], d["range"]["start"]["character"])
                 for d in c.send("textDocument/definition", at_field)["result"] or []]
    refused = c.send("textDocument/rename", dict(at_field, newName="total")).get("error") or {}
    step("18e", "an instance variable is its class's: highlight, references, definition",
         lit == [(3, 9, 14, 3), (5, 17, 23, 3), (10, 4, 10, 3), (10, 13, 19, 2)] and
         local_lit == [(9, 4), (10, 22)] and
         field_refs == [(5, 17), (10, 4), (10, 13)] and
         field_def == [(3, 9)] and
         refused.get("code") == -32803 and "accessors" in refused.get("message", ""),
         f"field {lit}, local {local_lit}, references {field_refs}, "
         f"definition {field_def}, rename {refused.get('code')}")
    c.send("textDocument/didClose",
           {"textDocument": {"uri": fields_uri}}, wait=False)

    # 18f. A rename onto a name its owner already has is refused. It was
    #      carried out: `shout` renamed to an existing `yell` left two
    #      `def yell(name : String)`, the later replaced the earlier, and
    #      `puts shout("a")` printed "a!" where it had printed "A". The top
    #      level counts too - a def renamed `puts` would take the prelude's
    #      bare calls - and a free name still renames.
    clash = ("module clash\n\n"
             "def shout(name : String) : String\n  name.upcase\nend\n\n"
             "def yell(name : String) : String\n  name + \"!\"\nend\n\n"
             "puts shout(\"a\")\nputs yell(\"b\")\n")
    clash_uri = file_uri(os.path.join(work, "clash.iyi"))
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": clash_uri, "languageId": "iyi",
                             "version": 1, "text": clash}}, wait=False)
    c.diagnostics(clash_uri)
    at_shout = {"textDocument": {"uri": clash_uri},
                "position": {"line": 2, "character": 5}}
    onto_yell = c.send("textDocument/rename", dict(at_shout, newName="yell")).get("error") or {}
    onto_puts = c.send("textDocument/rename", dict(at_shout, newName="puts")).get("error") or {}
    free = (c.send("textDocument/rename", dict(at_shout, newName="holler")).get("result") or {}).get("changes", {})
    step("18f", "a rename onto a name already there is refused",
         onto_yell.get("code") == -32803 and "already a method" in onto_yell.get("message", "") and
         onto_puts.get("code") == -32803 and
         len(free.get(clash_uri, [])) == 2,
         f"onto yell {onto_yell.get('code')}, onto puts {onto_puts.get('code')}, "
         f"onto holler {len(free.get(clash_uri, []))} edit(s)")
    c.send("textDocument/didClose",
           {"textDocument": {"uri": clash_uri}}, wait=False)

    # 18g. A local renamed onto a name a block inside its scope binds: the
    #      block's uses of the local would read the block's parameter. It
    #      was carried out, and `total = total + n` became `n = n + n`,
    #      so the def returned 100 where it had returned 103.
    shadow = ("module shadow\n\n"
              "def sum : Int32\n"
              "  total = 100\n"
              "  [1, 2].each do |n|\n"
              "    total = total + n\n"
              "  end\n"
              "  total\n"
              "end\n\n"
              "puts sum\n")
    shadow_uri = file_uri(os.path.join(work, "shadow.iyi"))
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": shadow_uri, "languageId": "iyi",
                             "version": 1, "text": shadow}}, wait=False)
    c.diagnostics(shadow_uri)
    at_total = {"textDocument": {"uri": shadow_uri},
                "position": {"line": 3, "character": 3}}
    onto_n = c.send("textDocument/rename", dict(at_total, newName="n")).get("error") or {}
    onto_acc = (c.send("textDocument/rename", dict(at_total, newName="acc")).get("result") or {}).get("changes", {})
    step("18g", "a local is not renamed onto a block parameter's name",
         onto_n.get("code") == -32803 and "already a name" in onto_n.get("message", "") and
         len(onto_acc.get(shadow_uri, [])) == 4,
         f"onto n {onto_n.get('code')}, onto acc {len(onto_acc.get(shadow_uri, []))} edit(s)")
    c.send("textDocument/didClose",
           {"textDocument": {"uri": shadow_uri}}, wait=False)

    # 18h. A rename onto a name a module that imports the def has of its
    #      own is refused too. A module's own def beats an imported one
    #      (II.3 rule 2), so `shout` renamed to `yell` in `loud/lib` moved
    #      `import loud/lib::{shout}` to `{yell}` in `loud/app`, and app's
    #      `puts shout("a")` became `puts yell("a")` - app's own `yell` -
    #      printing "a!" where it had printed "A", with nothing refused.
    #      The importer is a file nobody opened; a free name still renames
    #      both files.
    loud = os.path.join(work, "loud")
    os.makedirs(loud)
    loud_lib = os.path.join(loud, "lib.iyi")
    loud_lib_text = "module loud/lib\n\npub def shout(s : String) : String\n  s.upcase\nend\n"
    with open(loud_lib, "w", newline="") as f:
        f.write(loud_lib_text)
    with open(os.path.join(loud, "app.iyi"), "w", newline="") as f:
        f.write("module loud/app\n\nimport loud/lib::{shout}\n\n"
                "def yell(s : String) : String\n  s + \"!\"\nend\n\n"
                "puts shout(\"a\")\nputs yell(\"b\")\n")
    loud_uri = file_uri(loud_lib)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": loud_uri, "languageId": "iyi",
                             "version": 1, "text": loud_lib_text}}, wait=False)
    c.diagnostics(loud_uri)
    at_loud = {"textDocument": {"uri": loud_uri},
               "position": {"line": 2, "character": 9}}
    onto_app = c.send("textDocument/rename", dict(at_loud, newName="yell")).get("error") or {}
    free = (c.send("textDocument/rename", dict(at_loud, newName="holler")).get("result") or {}).get("changes", {})
    free_files = sorted(u.rsplit("/", 1)[-1] for u in free)
    step("18h", "a rename onto a name an importer has is refused",
         onto_app.get("code") == -32803 and "loud/app" in onto_app.get("message", "") and
         free_files == ["app.iyi", "lib.iyi"] and sum(len(e) for e in free.values()) == 3,
         f"onto yell {onto_app.get('code')} {onto_app.get('message', '')[:80]!r}, "
         f"onto holler {sum(len(e) for e in free.values())} edit(s) in {free_files}")
    c.send("textDocument/didClose",
           {"textDocument": {"uri": loud_uri}}, wait=False)

    # 18i. An importer compiles against an unsaved buffer of a module
    #      below the root. The resolver spells that file with the module
    #      path's own `/` inside a native root, the buffer is keyed by the
    #      path its URI names, and on Windows the two never met: a def
    #      renamed in `nest/lib`'s buffer left `nest/use`'s verdict clean,
    #      compiled against the disk.
    nest = os.path.join(work, "nest")
    os.makedirs(nest)
    nest_lib = os.path.join(nest, "lib.iyi")
    nest_use = os.path.join(nest, "use.iyi")
    nest_lib_text = "module nest/lib\n\npub def token : String\n  \"NUM\"\nend\n"
    nest_use_text = "module nest/use\n\nimport nest/lib::{token}\n\nputs token\n"
    with open(nest_lib, "w", newline="") as f:
        f.write(nest_lib_text)
    with open(nest_use, "w", newline="") as f:
        f.write(nest_use_text)
    nest_lib_uri, nest_use_uri = file_uri(nest_lib), file_uri(nest_use)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": nest_use_uri, "languageId": "iyi",
                             "version": 1, "text": nest_use_text}}, wait=False)
    clean_first = c.diagnostics(nest_use_uri)["diagnostics"] == []
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": nest_lib_uri, "languageId": "iyi", "version": 1,
                             "text": nest_lib_text.replace("def token", "def tok")}}, wait=False)
    c.diagnostics(nest_lib_uri)
    c.send("textDocument/didChange",
           {"textDocument": {"uri": nest_use_uri, "version": 2},
            "contentChanges": [{"text": nest_use_text + "\n"}]}, wait=False)
    after = c.diagnostics(nest_use_uri)["diagnostics"]
    step("18i", "an importer compiles against a nested module's unsaved buffer",
         clean_first and any("token" in d["message"] for d in after),
         f"clean first {clean_first}, after the buffer's rename: "
         f"{[d['message'][:60] for d in after]}")
    for uri in (nest_lib_uri, nest_use_uri):
        c.send("textDocument/didClose", {"textDocument": {"uri": uri}}, wait=False)

    # 18j. Where the project sits is not what it holds. The workspace walk
    #      skipped a file whose absolute path had `/.` or `/lib/` in it -
    #      meant for `.git` and a dependency's `lib` inside the root - so a
    #      project under `~/.config` or any `lib` directory had no files:
    #      a rename edited the def and left its importer calling a name
    #      that no longer exists. A server of its own, rooted there.
    for parent in (".outer", "lib"):
        proj = os.path.join(work, "placed", parent, "proj")
        os.makedirs(proj)
        placed_lib = os.path.join(proj, "greet.iyi")
        placed_text = "module greet\n\npub def shout(s : String) : String\n  s.upcase\nend\n"
        with open(placed_lib, "w", newline="") as f:
            f.write(placed_text)
        with open(os.path.join(proj, "app.iyi"), "w", newline="") as f:
            f.write("module app\n\nimport greet::{shout}\n\nputs shout(\"a\")\n")
        # And on Windows two junctions the walk has to step past: one back
        # to the root, which it followed until the paths were too long to
        # open, and one this user may not list, which failed every
        # workspace question with -32602 "Access is denied".
        denied = None
        if os.name == "nt" and parent == "lib":
            subprocess.run(["cmd", "/c", "mklink", "/J", os.path.join(proj, "loop"), proj], capture_output=True)
            os.makedirs(os.path.join(work, "placed", "elsewhere"))
            denied = os.path.join(proj, "legacy")
            subprocess.run(["cmd", "/c", "mklink", "/J", denied, os.path.join(work, "placed", "elsewhere")], capture_output=True)
            subprocess.run(["icacls", denied, "/deny", os.environ["USERNAME"] + ":(RD)", "/L"], capture_output=True)
        e = Client()
        e.send("initialize", {"rootUri": file_uri(proj), "capabilities": {}})
        e.send("initialized", {}, wait=False)
        placed_uri = file_uri(placed_lib)
        e.send("textDocument/didOpen",
               {"textDocument": {"uri": placed_uri, "languageId": "iyi",
                                 "version": 1, "text": placed_text}}, wait=False)
        e.diagnostics(placed_uri)
        placed = (e.send("textDocument/rename",
                         {"textDocument": {"uri": placed_uri},
                          "position": {"line": 2, "character": 9},
                          "newName": "holler"}).get("result") or {}).get("changes", {})
        placed_files = sorted(u.rsplit("/", 1)[-1] for u in placed)
        e.send("shutdown", {})
        e.send("exit", {}, wait=False)
        e.proc.wait(timeout=10)
        if denied:
            subprocess.run(["icacls", denied, "/remove:d", os.environ["USERNAME"], "/L"], capture_output=True)
            for junction in (denied, os.path.join(proj, "loop")):
                os.rmdir(junction)
        step(f"18j{parent}", f"a project under a `{parent}` directory renames into its importer",
             placed_files == ["app.iyi", "greet.iyi"],
             f"rename edited {placed_files}")

    # 18m. A multi-root workspace is every folder, not the first: a rename
    #      in the second folder left its importer calling the old name, and
    #      workspace/symbol knew nothing of it.
    folders = [os.path.join(work, "roots", name) for name in ("first", "second")]
    for folder in folders:
        os.makedirs(folder)
    with open(os.path.join(folders[0], "other.iyi"), "w", newline="") as f:
        f.write("module other\n\nputs 1\n")
    second_lib = os.path.join(folders[1], "greet.iyi")
    second_text = "module greet\n\npub def shout(s : String) : String\n  s.upcase\nend\n"
    with open(second_lib, "w", newline="") as f:
        f.write(second_text)
    with open(os.path.join(folders[1], "app.iyi"), "w", newline="") as f:
        f.write("module app\n\nimport greet::{shout}\n\ndef announce : String\n  shout(\"a\")\nend\n\nputs announce\n")
    e = Client()
    e.send("initialize", {"rootUri": file_uri(folders[0]), "capabilities": {},
                          "workspaceFolders": [{"uri": file_uri(folder), "name": os.path.basename(folder)}
                                               for folder in folders]})
    e.send("initialized", {}, wait=False)
    second_uri = file_uri(second_lib)
    e.send("textDocument/didOpen",
           {"textDocument": {"uri": second_uri, "languageId": "iyi",
                             "version": 1, "text": second_text}}, wait=False)
    e.diagnostics(second_uri)
    multi = (e.send("textDocument/rename",
                    {"textDocument": {"uri": second_uri},
                     "position": {"line": 2, "character": 9},
                     "newName": "holler"}).get("result") or {}).get("changes", {})
    multi_files = sorted(u.rsplit("/", 1)[-1] for u in multi)
    announced = [sym["name"] for sym in e.send("workspace/symbol", {"query": "announce"}).get("result") or []]
    e.send("shutdown", {})
    e.send("exit", {}, wait=False)
    e.proc.wait(timeout=10)
    step("18m", "a multi-root workspace is every folder, not the first",
         multi_files == ["app.iyi", "greet.iyi"] and announced == ["announce"],
         f"rename edited {multi_files}, workspace/symbol found {announced}")

    # 70c. A workspace file the server may not read is skipped, as a directory
    #      that will not list is. One held open by a process that shares
    #      nothing failed workspace symbols, completion, references, rename
    #      and workspace diagnostics with -32602 "locked.iyi: The process
    #      cannot access the file because it is being used by another
    #      process."; one whose ACL denies reading, with "Access is denied.".
    locked_root = tempfile.mkdtemp(prefix="iyi-lsp-locked")
    locked_files = {"greet.iyi": "module greet\n\npub def shout(s : String) : String\n  s.upcase\nend\n",
                    "app.iyi": "module app\n\nimport greet::{shout}\n\nputs shout(\"a\")\n",
                    "locked.iyi": "module locked\n\nputs 1\n"}
    for name, body in locked_files.items():
        with open(os.path.join(locked_root, name), "w", newline="") as f:
            f.write(body)
    locked = os.path.join(locked_root, "locked.iyi")
    if os.name == "nt":
        import ctypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateFileW.restype = ctypes.c_void_p
        kernel32.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                                         ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        held = kernel32.CreateFileW(locked, 0x80000000, 0, None, 3, 0x80, None)  # read, share nothing
        release = lambda: kernel32.CloseHandle(held)
    else:
        os.chmod(locked, 0)
        release = lambda: os.chmod(locked, 0o644)
    try:
        open(locked).close()
        unreadable = False  # root reads anything
    except OSError:
        unreadable = True
    lk = Client()
    lk.send("initialize", {"rootUri": file_uri(locked_root), "capabilities": {}})
    lk.send("initialized", {}, wait=False)
    locked_app = file_uri(os.path.join(locked_root, "app.iyi"))
    lk.send("textDocument/didOpen", {"textDocument": {"uri": locked_app, "languageId": "iyi", "version": 1,
                                                       "text": locked_files["app.iyi"]}}, wait=False)
    lk.diagnostics(locked_app)
    at_shout = {"textDocument": {"uri": locked_app}, "position": {"line": 4, "character": 6}}
    asks = [("workspace/symbol", {"query": "sh"}),
            ("textDocument/completion", {"textDocument": {"uri": locked_app}, "position": {"line": 4, "character": 7}}),
            ("textDocument/references", dict(at_shout, context={"includeDeclaration": True})),
            ("textDocument/rename", dict(at_shout, newName="yell")),
            ("workspace/diagnostic", {"previousResultIds": []})]
    failed = [method for method, params in asks if "error" in lk.send(method, params)]
    lk.send("shutdown", {})
    lk.send("exit", {}, wait=False)
    lk.proc.wait(timeout=10)
    release()
    step("70c", "a workspace file the server may not read is skipped",
         not failed, f"failed {failed}" if unreadable else "skipped: this user reads every file")

    # 70d. and workspace/symbol lists the workspace in linear time. Each
    #      file was checked against every path already listed: a query that
    #      matched nothing took 344 ms over 500 files and 3,031 ms over
    #      2,000, nine times as long for four times the files.
    def symbol_seconds(count):
        root = tempfile.mkdtemp(prefix=f"iyi-lsp-symbols{count}")
        for i in range(count):
            with open(os.path.join(root, f"m{i:04d}.iyi"), "w", newline="") as f:
                f.write(f"module m{i:04d}\n\npub def f{i}(x : Int32) : Int32\n  x\nend\n")
        s = Client()
        s.send("initialize", {"rootUri": file_uri(root), "capabilities": {}})
        s.send("initialized", {}, wait=False)
        best = None
        for query in ("zzqqzz", "zzqqzy", "zzqqzx"):
            started = time.monotonic()
            s.send("workspace/symbol", {"query": query})
            took = time.monotonic() - started
            best = took if best is None else min(best, took)
        s.send("shutdown", {})
        s.send("exit", {}, wait=False)
        s.proc.wait(timeout=10)
        return best
    small, large = symbol_seconds(500), symbol_seconds(2000)
    step("70d", "workspace/symbol takes time linear in the workspace", large < 6 * small,
         "2,000 files held under six times 500's")

    # 18k. The URIs an answer names are URIs: the client's own for a file
    #      it has open, and for any other one a percent-encoded URI that
    #      names that file. The path went behind `file:///` as it stood,
    #      so `#` made the rest of the path a fragment, `%41` decoded to
    #      another name, and a space never equalled the spelling an editor
    #      sent - here VS Code's, `c%3A` and all.
    from urllib.parse import quote
    odd = os.path.join(work, "odd #1 50%41 \u011f")
    os.makedirs(odd)
    odd_lib = os.path.join(odd, "greet.iyi")
    odd_app = os.path.join(odd, "app.iyi")
    with open(odd_lib, "w", newline="") as f:
        f.write("module greet\n\npub def shout(s : String) : String\n  s.upcase\nend\n")
    odd_app_text = "module app\n\nimport greet::{shout}\n\nputs shout(\"a\")\n"
    with open(odd_app, "w", newline="") as f:
        f.write(odd_app_text)
    absolute = os.path.abspath(odd_app).replace("\\", "/")
    if os.name == "nt":
        vscode_uri = "file:///" + absolute[0].lower() + "%3A" + quote(absolute[2:])
    else:
        vscode_uri = "file://" + quote(absolute)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": vscode_uri, "languageId": "iyi",
                             "version": 1, "text": odd_app_text}}, wait=False)
    c.diagnostics(vscode_uri)
    at_call = {"textDocument": {"uri": vscode_uri}, "position": {"line": 4, "character": 6}}
    found = c.send("textDocument/definition", at_call).get("result") or []
    found_uri = found[0]["uri"] if found else ""
    renamed = (c.send("textDocument/rename", dict(at_call, newName="holler")).get("result") or {}).get("changes", {})
    keys = sorted(renamed)
    others = [k for k in keys if k != vscode_uri]
    step("18k", "answers name files by the client's URI, or by an encoded one",
         found_uri != "" and uri_path(found_uri) == uri_path(file_uri(odd_lib)) and os.path.exists(uri_path(found_uri)) and
         vscode_uri in keys and len(keys) == 2 and
         all(os.path.exists(uri_path(k)) for k in others),
         f"definition {found_uri!r}, rename keys {keys}")
    c.send("textDocument/didClose", {"textDocument": {"uri": vscode_uri}}, wait=False)
    # And a file on a share: `file://server/share/...` names a UNC path.
    #  Its authority was read as the path's first segment, relative to the
    #  server's own directory, and the module beside it was not found.
    share = r"\\127.0.0.1\C$"
    if os.name == "nt" and os.path.splitdrive(odd_app)[0].upper() == "C:" and os.path.exists(share):
        unc_uri = pathlib.Path(share + odd_app[2:]).as_uri()
        c.send("textDocument/didOpen",
               {"textDocument": {"uri": unc_uri, "languageId": "iyi",
                                 "version": 1, "text": odd_app_text}}, wait=False)
        unc_diags = [d["message"][:60] for d in c.diagnostics(unc_uri)["diagnostics"]]
        c.send("textDocument/didClose", {"textDocument": {"uri": unc_uri}}, wait=False)
        step("18k-unc", "a file on a share finds the module beside it", unc_diags == [],
             f"{unc_uri}: {unc_diags}")

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

    # 70b. A module whose bytes are not UTF-8 - saved as Windows-1254 - is a
    #      diagnostic, and only its own. The in-process compile exited on
    #      it: its hover and diagnostic pull answered -32603 "did not
    #      survive it", and workspace symbols and completion in every other
    #      file -32603 "Unexpected byte 0xfe".
    legacy_root = tempfile.mkdtemp(prefix="iyi-lsp-legacy")
    legacy_app_text = "module app\n\nimport greet::{shout}\n\nputs shout(\"a\")\nputs sho\n"
    with open(os.path.join(legacy_root, "greet.iyi"), "w", newline="") as f:
        f.write("module greet\n\npub def shout(s : String) : String\n  s.upcase\nend\n")
    with open(os.path.join(legacy_root, "app.iyi"), "w", newline="") as f:
        f.write(legacy_app_text)
    with open(os.path.join(legacy_root, "legacy.iyi"), "wb") as f:
        f.write("module legacy\n\n# şarkı söyle\npub def şık : String\n  \"ğüş\"\nend\n".encode("cp1254"))
    lg = Client()
    lg.send("initialize", {"rootUri": file_uri(legacy_root), "capabilities": {}})
    lg.send("initialized", {}, wait=False)
    legacy_app = file_uri(os.path.join(legacy_root, "app.iyi"))
    legacy_uri = file_uri(os.path.join(legacy_root, "legacy.iyi"))
    lg.send("textDocument/didOpen", {"textDocument": {"uri": legacy_app, "languageId": "iyi", "version": 1,
                                                       "text": legacy_app_text}}, wait=False)
    lg.diagnostics(legacy_app)
    pulled = lg.send("textDocument/diagnostic", {"textDocument": {"uri": legacy_uri}})
    symbols = lg.send("workspace/symbol", {"query": "shout"})
    offered = lg.send("textDocument/completion", {"textDocument": {"uri": legacy_app},
                                                  "position": {"line": 5, "character": 8}})
    outline = lg.send("textDocument/documentSymbol", {"textDocument": {"uri": legacy_uri}})
    lg.send("shutdown", {})
    lg.send("exit", {}, wait=False)
    lg.proc.wait(timeout=10)
    errors = [r["error"]["message"][:60] for r in (pulled, symbols, offered, outline) if "error" in r]
    said = [d["message"] for d in (pulled.get("result") or {}).get("items", [])]
    labels = [i["label"] for i in (offered.get("result") or {}).get("items", [])]
    step("70b", "a module that is not UTF-8 is its own diagnostic, and nobody else's",
         not errors and any("not a valid iyi source file" in m for m in said) and "shout" in labels
         and [s["name"] for s in symbols.get("result") or []] == ["shout"],
         f"errors {errors}, said {[m[:50] for m in said]}")

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

    # 25c. A CRLF buffer formats in CRLF, as `iyi format` writes a file:
    #      a formatted one needs no edit, and a sloppy one's edit keeps
    #      every line's `\r\n`. The server answered both with LF, a
    #      whole-document rewrite on every save. And an edit whose range
    #      runs past a line's end stops before its `\r`, which the spec
    #      says and the server's offsets did not: the buffer lost the `\r`
    #      and stopped matching the editor's.
    crlf_path = os.path.join(work, "crlf.iyi")
    crlf_text = "module crlf\r\n\r\nputs 1\r\nputs 2\r\n"
    crlf_uri = file_uri(crlf_path)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": crlf_uri, "languageId": "iyi",
                             "version": 1, "text": crlf_text}}, wait=False)
    c.diagnostics(crlf_uri)
    fmt = {"textDocument": {"uri": crlf_uri}, "options": {"tabSize": 2, "insertSpaces": True}}
    clean = c.send("textDocument/formatting", fmt)["result"]
    c.send("textDocument/didChange",
           {"textDocument": {"uri": crlf_uri, "version": 2},
            "contentChanges": [{"range": {"start": {"line": 2, "character": 5},
                                          "end": {"line": 2, "character": 100}},
                                "text": "3"}]}, wait=False)
    c.diagnostics(crlf_uri)
    after_edit = c.send("textDocument/formatting", fmt)["result"]
    c.send("textDocument/didChange",
           {"textDocument": {"uri": crlf_uri, "version": 3},
            "contentChanges": [{"text": "module crlf\r\n\r\nputs(  3 )\r\nputs 2\r\n"}]}, wait=False)
    c.diagnostics(crlf_uri)
    sloppy_edits = c.send("textDocument/formatting", fmt)["result"] or []
    sloppy_text = sloppy_edits[0]["newText"] if sloppy_edits else ""
    step("25c", "a CRLF buffer formats in CRLF, and an edit past a line's end keeps its \\r",
         clean == [] and after_edit == [] and
         sloppy_text.count("\r\n") == 4 and sloppy_text.count("\n") == 4,
         f"formatted: {clean!r}, after the edit: {len(after_edit or [])} edit(s), "
         f"sloppy: {sloppy_text!r}")
    c.send("textDocument/didClose", {"textDocument": {"uri": crlf_uri}}, wait=False)

    # 25d. Rename takes the names the compiler takes: `şarkı` for a local,
    #      `söyle` for a def, and back from one to ASCII. It refused every
    #      non-ASCII name ("'şarkı' is not an iyi variable name"), where
    #      `def söyle(şarkı : String)` compiles. A name the lexer reads as a
    #      constant, `Şarkı`, is still refused for a local.
    def applied(text, edits):
        lines = text.split("\n")
        for e in sorted(edits, key=lambda e: (e["range"]["start"]["line"], e["range"]["start"]["character"]), reverse=True):
            r = e["range"]
            line = lines[r["start"]["line"]]
            lines[r["start"]["line"]] = line[:r["start"]["character"]] + e["newText"] + line[r["end"]["character"]:]
        return "\n".join(lines)
    uni_path = os.path.join(work, "uni.iyi")
    uni_uri = file_uri(uni_path)
    uni_text = 'module uni\n\ndef sing(song : String) : String\n  song + song\nend\n\nputs sing("la")\n'
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": uni_uri, "languageId": "iyi",
                             "version": 1, "text": uni_text}}, wait=False)
    c.diagnostics(uni_uri)
    def renamed(line, character, name):
        reply = c.send("textDocument/rename",
                       {"textDocument": {"uri": uni_uri},
                        "position": {"line": line, "character": character},
                        "newName": name})
        return reply.get("result"), reply.get("error")
    to_local, _ = renamed(3, 3, "şarkı")
    step_one = applied(uni_text, (to_local or {}).get("changes", {}).get(uni_uri, []))
    to_def, _ = renamed(6, 6, "söyle")
    step_two = applied(step_one, (to_def or {}).get("changes", {}).get(uni_uri, []))
    c.send("textDocument/didChange",
           {"textDocument": {"uri": uni_uri, "version": 2},
            "contentChanges": [{"text": step_two}]}, wait=False)
    uni_diags = c.diagnostics(uni_uri)["diagnostics"]
    back, _ = renamed(3, 4, "tune")
    step_three = applied(step_two, (back or {}).get("changes", {}).get(uni_uri, []))
    _, constant = renamed(3, 4, "Şarkı")
    step("25d", "rename takes the names the compiler takes, in any script",
         step_two == 'module uni\n\ndef söyle(şarkı : String) : String\n  şarkı + şarkı\nend\n\nputs söyle("la")\n' and
         not uni_diags and
         step_three == step_two.replace("şarkı", "tune") and
         constant is not None,
         # ascii(): a runner's console may be cp1252, which has no `ş`.
         f"after two renames {ascii(step_two)}, diagnostics {ascii(uni_diags)}, back {ascii(step_three)}, "
         f"the constant-cased name refused: {constant is not None}")
    c.send("textDocument/didClose", {"textDocument": {"uri": uni_uri}}, wait=False)

    # 70e. A rename onto a word the lexer does not read as a plain name is
    #      refused, and a keyword is judged by the parser where it lands.
    #      `end`, `nil`, `Hi` and `_` were taken for a def, and `do`,
    #      `typeof`, `abstract`, `__LINE__` and `_` for a variable, each
    #      applied and each leaving an error. The server asks the lexer
    #      (`lexed_name`) and parses the result; `type` still renames.
    names_path = os.path.join(tempfile.mkdtemp(prefix="iyi-lsp-names"), "names.iyi")
    names_text = "module names\n\ndef hi(n : Int32) : Int32\n  n + 1\nend\n\nputs hi(2)\nv = 3\nputs v\n"
    with open(names_path, "w", newline="") as f:
        f.write(names_text)
    names_uri = file_uri(names_path)
    c.send("textDocument/didOpen", {"textDocument": {"uri": names_uri, "languageId": "iyi", "version": 1,
                                                      "text": names_text}}, wait=False)
    c.diagnostics(names_uri)

    def rename_code(line, name):
        reply = c.send("textDocument/rename", {"textDocument": {"uri": names_uri},
                                               "position": {"line": line, "character": 5}, "newName": name})
        return (reply.get("error") or {}).get("code", "applied")
    refusals = [rename_code(6, w) for w in ("end", "nil", "Hi", "_")] + \
        [rename_code(8, w) for w in ("do", "typeof", "abstract", "__LINE__", "_")]
    kept = [rename_code(8, "type"), rename_code(6, "hey")]
    c.send("textDocument/didClose", {"textDocument": {"uri": names_uri}}, wait=False)
    step("70e", "a rename onto a reserved word is refused, a name is not",
         refusals == [-32803] * 9 and kept == ["applied", "applied"], f"refused {refusals}, kept {kept}")

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

    # 28b. and a def's callers are the calls the person wrote: `render`
    #      is called once, at the file's last line. Incoming calls to any
    #      def also listed the def's own file as a caller at the def's own
    #      line - a call the compiler made there.
    render_callers = []
    if render_items:
        reply = c.send("callHierarchy/incomingCalls", {"item": render_items[0]})
        render_callers = [(e["from"]["name"], [r["start"]["line"] for r in e["fromRanges"]])
                          for e in reply["result"] or []]
    step("28b", "a def's incoming calls are the calls written",
         [lines for _, lines in render_callers] == [[19]],
         f"render <- {render_callers}")

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
    # The successor is warmed as it starts - the focused buffer's
    # diagnostics, a compile - and a request behind that waits for it:
    # on a Windows runner the pull once read 594 ms, the warm-up's tail,
    # against 15 to 47 ms every other run. One cheap round trip first, so
    # the time below is the pull's own.
    c.send("textDocument/documentSymbol", {"textDocument": {"uri": app_uri}})
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

    # 70a. And asked at a call: references and rename reach every importer
    #      from either end. The cursor's place went to every entry's
    #      compile, and only a compile holding the cursor's file matched it,
    #      so `other.iyi` - an importer like `app.iyi` - was missed and the
    #      rename left it calling a name that was gone. The defs the first
    #      compile adopts are the seeds of the rest.
    seeds_root = tempfile.mkdtemp(prefix="iyi-lsp-seeds")
    seeds_files = {"greet.iyi": "module greet\n\npub def shout(s : String) : String\n  s.upcase\nend\n",
                   "app.iyi": "module app\n\nimport greet::{shout}\n\nputs shout(\"a\")\n",
                   "other.iyi": "module other\n\nimport greet::{shout}\n\nputs shout(\"b\")\n"}
    for name, body in seeds_files.items():
        with open(os.path.join(seeds_root, name), "w", newline="") as f:
            f.write(body)
    sd = Client()
    sd.send("initialize", {"rootUri": file_uri(seeds_root), "capabilities": {}})
    sd.send("initialized", {}, wait=False)
    seeds_app = file_uri(os.path.join(seeds_root, "app.iyi"))
    sd.send("textDocument/didOpen", {"textDocument": {"uri": seeds_app, "languageId": "iyi", "version": 1,
                                                       "text": seeds_files["app.iyi"]}}, wait=False)
    sd.diagnostics(seeds_app)
    seeds_at = {"textDocument": {"uri": seeds_app}, "position": {"line": 4, "character": 6}}
    found = sd.send("textDocument/references", dict(seeds_at, context={"includeDeclaration": True})).get("result") or []
    found_sites = sorted((u["uri"].rsplit("/", 1)[-1], u["range"]["start"]["line"]) for u in found)
    renamed = (sd.send("textDocument/rename", dict(seeds_at, newName="yell")).get("result") or {}).get("changes", {})
    renamed_sites = sorted((u.rsplit("/", 1)[-1], len(edits)) for u, edits in renamed.items())
    sd.send("shutdown", {})
    sd.send("exit", {}, wait=False)
    sd.proc.wait(timeout=10)
    step("70a", "references and rename from a call reach every importer",
         found_sites == [("app.iyi", 2), ("app.iyi", 4), ("greet.iyi", 2), ("other.iyi", 2), ("other.iyi", 4)]
         and renamed_sites == [("app.iyi", 2), ("greet.iyi", 1), ("other.iyi", 2)],
         f"references {found_sites}, rename {renamed_sites}")

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

    # 70k. The auto-import line is written in the buffer's own line ending:
    #      a CRLF buffer was handed `import greet::{shout}\n`, and a client
    #      that applies an edit as written makes the file mixed.
    crlf_root = tempfile.mkdtemp(prefix="iyi-lsp-crlf")
    crlf_app_text = "module app\r\n\r\nputs sho\r\n"
    with open(os.path.join(crlf_root, "greet.iyi"), "w", newline="") as f:
        f.write("module greet\r\n\r\npub def shout(s : String) : String\r\n  s.upcase\r\nend\r\n")
    with open(os.path.join(crlf_root, "app.iyi"), "w", newline="") as f:
        f.write(crlf_app_text)
    cr = Client()
    cr.send("initialize", {"rootUri": file_uri(crlf_root), "capabilities": {}})
    cr.send("initialized", {}, wait=False)
    crlf_app = file_uri(os.path.join(crlf_root, "app.iyi"))
    cr.send("textDocument/didOpen", {"textDocument": {"uri": crlf_app, "languageId": "iyi", "version": 1,
                                                       "text": crlf_app_text}}, wait=False)
    cr.diagnostics(crlf_app)
    reply = cr.send("textDocument/completion", {"textDocument": {"uri": crlf_app},
                                                "position": {"line": 2, "character": 8}})
    cr.send("shutdown", {})
    cr.send("exit", {}, wait=False)
    cr.proc.wait(timeout=10)
    texts = [e["newText"] for i in (reply.get("result") or {}).get("items", []) if i["label"] == "shout"
             for e in i.get("additionalTextEdits", [])]
    step("70k", "an auto-import into a CRLF buffer ends its line in CRLF",
         texts == ["import greet::{shout}\r\n"], f"edits {texts!r}")

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

    # 70g. A `$/cancelRequest` whose params are not an object names nothing
    #      and is dropped. `["x"]`, `"x"` and `5` raised in the worker's own
    #      loop, outside every rescue: the compiler-bug banner on stderr,
    #      the worker gone, and the next request answered -32603.
    survived = []
    for odd in (["x"], "x", 5):
        c.send("$/cancelRequest", odd, wait=False)
        reply = c.send("textDocument/hover", {"textDocument": {"uri": app_uri},
                                              "position": {"line": 0, "character": 0}})
        survived.append("error" not in reply)
    step("70g", "a cancel whose params are not an object is dropped",
         survived == [True] * 3, f"answered after each: {survived}")

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

    # 43c. and a buffer with no file behind it runs, and leaves nothing
    #      behind. VS Code's `untitled:` buffer was run from a scratch
    #      file beside the server's working directory whose name held the
    #      scheme's `:`, which NTFS reads as a stream's name: the run
    #      failed "The directory name is invalid" and left an empty
    #      `.untitled` there.
    untitled_uri = "untitled:Untitled-1"
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": untitled_uri, "languageId": "iyi",
                             "version": 1,
                             "text": 'module scratch\n\nputs "from nowhere"\n'}},
           wait=False)
    c.diagnostics(untitled_uri)
    ran = c.send("workspace/executeCommand",
                 {"command": "iyi.run", "arguments": [untitled_uri]})["result"] or {}
    stray = [n for n in os.listdir(os.getcwd()) if n.startswith(".untitled")]
    step("43c", "a buffer with no file behind it runs, and leaves nothing behind",
         ran.get("ok") and ran.get("output", "").strip() == "from nowhere" and not stray,
         f"ok {ran.get('ok')}, output {ran.get('output', '')!r}, "
         f"error {ran.get('error', '')[:160]!r}, left {stray}")
    for name in stray:
        os.remove(os.path.join(os.getcwd(), name))
    c.send("textDocument/didClose", {"textDocument": {"uri": untitled_uri}}, wait=False)

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
    #     The proxy retires a worker that has grown, between any two
    #     requests, and a fresh worker knows no earlier resultId: its full
    #     answer then is the protocol's fallback, not a failure. So a full
    #     answer where a delta was asked is asked again, once.
    retired = 0
    for attempt in range(2):
        reply = c.send("textDocument/semanticTokens/full",
                       {"textDocument": {"uri": shapes_uri}})
        first = reply["result"]
        c.send("textDocument/didChange",
               {"textDocument": {"uri": shapes_uri, "version": 2 + attempt},
                "contentChanges": [{"text": shapes_text + "# renk\n" * (attempt + 1)}]},
               wait=False)
        c.diagnostics(shapes_uri)
        reply = c.send("textDocument/semanticTokens/full/delta",
                       {"textDocument": {"uri": shapes_uri},
                        "previousResultId": first["resultId"]})
        delta = reply["result"]
        if "data" not in delta:
            break
        retired += 1
    rebuilt = list(first["data"])
    for e in delta.get("edits", []):
        rebuilt[e["start"]:e["start"] + e["deleteCount"]] = e["data"]
    reply = c.send("textDocument/semanticTokens/full",
                   {"textDocument": {"uri": shapes_uri}})
    fresh = reply["result"]["data"]
    step(45, "semantic token deltas splice to the full answer",
         "edits" in delta and "data" not in delta and rebuilt == fresh,
         f"{len(delta.get('edits', []))} edit(s) over "
         f"{len(first['data'])} ints, {retired} full answer(s) first")

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
             ("compiled with the executable moved aside, as a rebuild does"
              if os.name == "nt" else
              "compiled with the executable unlinked; $ORIGIN was pinned") +
             ("" if held and "error" not in reply else f"; answered {json.dumps(reply)[:400]}"))
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

    # 70f. Moving a module saved with a byte order mark moves its header
    #      too: `\uFEFFmodule calc/lexer` never started with `module `, so
    #      the importer was edited and the header was not, and the moved
    #      file named a path it no longer had.
    bom_root = tempfile.mkdtemp(prefix="iyi-lsp-bom")
    os.makedirs(os.path.join(bom_root, "calc"))
    with open(os.path.join(bom_root, "calc", "lexer.iyi"), "w", encoding="utf-8-sig", newline="") as f:
        f.write("module calc/lexer\n\npub def token(s : String) : String\n  s\nend\n")
    with open(os.path.join(bom_root, "app.iyi"), "w", newline="") as f:
        f.write("module app\n\nimport calc/lexer::{token}\n\nputs token(\"x\")\n")
    bm = Client()
    bm.send("initialize", {"rootUri": file_uri(bom_root), "capabilities": {}})
    bm.send("initialized", {}, wait=False)
    reply = bm.send("workspace/willRenameFiles", {"files": [
        {"oldUri": file_uri(os.path.join(bom_root, "calc", "lexer.iyi")),
         "newUri": file_uri(os.path.join(bom_root, "calc", "scanner.iyi"))}]})
    bm.send("shutdown", {})
    bm.send("exit", {}, wait=False)
    bm.proc.wait(timeout=10)
    bom_edits = sorted((u.rsplit("/", 1)[-1], e["range"]["start"]["line"], e["range"]["start"]["character"],
                        e["range"]["end"]["character"], e["newText"])
                       for u, edits in ((reply.get("result") or {}).get("changes") or {}).items() for e in edits)
    step("70f", "a module saved with a byte order mark moves its header too",
         bom_edits == [("app.iyi", 2, 7, 17, "calc/scanner"), ("lexer.iyi", 0, 7, 17, "calc/scanner")],
         f"edits {bom_edits}")

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

    # 60a. A lone surrogate escape - `\ud83d`, half an emoji, which an
    #      editor's buffer can hold and `JSON.stringify` writes as is - is
    #      valid JSON the JSON library refuses, and it was answered as the
    #      frame above is: a didOpen carrying one got -32700 and the buffer
    #      never opened, so every answer after it read the disk. It opens
    #      now with U+FFFD in the surrogate's place, one UTF-16 unit as the
    #      surrogate was, so the columns after it still land: `nope` is at
    #      character 10. The proxy mends the frame it hands on, and the
    #      worker alone mends its own.
    sur = os.path.join(work, "sur.iyi")
    with open(sur, "w") as f:
        f.write("module sur\n\nputs 1\n")
    sur_uri = file_uri(sur)

    def surrogate_verdict(client):
        client.send("textDocument/didOpen",
                    {"textDocument": {"uri": sur_uri, "languageId": "iyi", "version": 1,
                                      "text": 'module sur\n\nputs "\ud83d", nope\n'}}, wait=False)
        reply = client.send("textDocument/diagnostic", {"textDocument": {"uri": sur_uri}})
        return [(d["range"]["start"]["line"], d["range"]["start"]["character"])
                for d in (reply.get("result") or {}).get("items", []) if "nope" in d["message"]]
    proxied = surrogate_verdict(c)
    w = Client(("lsp", "--worker"))
    w.send("initialize", {"rootUri": file_uri(work), "capabilities": {}})
    w.send("initialized", {}, wait=False)
    alone = surrogate_verdict(w)
    w.send("shutdown", {})
    w.send("exit", {}, wait=False)
    w.proc.wait(timeout=10)
    step("60a", "a lone surrogate in a buffer is U+FFFD, and the buffer opens",
         proxied == [(2, 10)] and alone == [(2, 10)],
         f"proxy {proxied}, worker alone {alone}")

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

    # 70m. A uri that names a directory is said to be one: Windows answered
    #      "Access is denied.", the reason its CreateFile gives and not the
    #      fact that holds.
    reply = c.send("textDocument/hover", {"textDocument": {"uri": file_uri(work)},
                                          "position": {"line": 0, "character": 0}})
    step("70m", "a directory uri is said to be one",
         reply.get("error", {}).get("code") == -32602 and "Is a directory" in reply["error"]["message"],
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

    # 52g. A request the server understood and will not carry out is
    # RequestFailed with the reason: a rename with nothing renameable under
    # the cursor left as -32603, the code for "this server is broken". And
    # a command the server does not have is the client's mistake, -32602.
    reply = c.send("textDocument/rename", {
        "textDocument": {"uri": app_uri}, "position": {"line": 0, "character": 0},
        "newName": "renamed"})
    step("52g", "a refused rename is request-failed, with its reason",
         reply.get("error", {}).get("code") == -32803
         and "nothing renameable" in reply["error"]["message"],
         json.dumps(reply.get("error"))[:80])
    reply = c.send("workspace/executeCommand", {"command": "iyi.nonesuch", "arguments": []})
    step("52h", "an unknown command is invalid params",
         reply.get("error", {}).get("code") == -32602
         and "iyi.nonesuch" in reply["error"]["message"],
         json.dumps(reply.get("error"))[:80])

    # 70j. A position is read as the protocol's uinteger, and anything else
    #      is the client's mistake. Hover, completion and nine more at line
    #      2147483647 answered -32603 "Arithmetic overflow" where line 999
    #      answers null, and a line that is "6", a uri that is 7 or a
    #      newName that is 5 was -32603 "Cast from ... failed, at
    #      C:\...\src\json\any.cr:178:5", the build machine's path included.
    #      Positions go through the server's `position_of` now.
    edge = {"line": 2 ** 31 - 1, "character": 0}
    answers = [c.send(m, {"textDocument": {"uri": app_uri}, "position": edge})
               for m in ("textDocument/hover", "textDocument/definition",
                         "textDocument/documentHighlight", "textDocument/completion")]
    answers.append(c.send("textDocument/references", {"textDocument": {"uri": app_uri}, "position": edge, "context": {"includeDeclaration": True}}))
    overflowed = [a["error"]["message"] for a in answers if "error" in a]
    misshapen = [c.send("textDocument/hover", {"textDocument": {"uri": app_uri},
                                               "position": {"line": "6", "character": 0}}),
                 c.send("textDocument/hover", {"textDocument": {"uri": 7},
                                               "position": {"line": 0, "character": 0}}),
                 c.send("textDocument/rename", {"textDocument": {"uri": app_uri},
                                                "position": {"line": 0, "character": 0}, "newName": 5})]
    codes = [(a.get("error") or {}).get("code") for a in misshapen]
    leaked = [a["error"]["message"] for a in misshapen if "any.cr" in (a.get("error") or {}).get("message", "")]
    step("70j", "a position past the end is answered, a misshapen one is invalid params",
         not overflowed and codes == [-32602] * 3 and not leaked,
         f"overflowed {overflowed[:1]}, codes {codes}, leaked {len(leaked)}")

    # 52i. A hover inside `x.or(0)`: the `or` tests a variable of the
    # compiler's own, and the cursor context looked it up among the names
    # it had recorded, which leave those out - a KeyError the server
    # answered as the client's, "the request is missing \"__temp_3\"".
    orer = os.path.join(work, "orer.iyi")
    orer_text = ("module orer\n\npub struct Bad\nend\n\nimpl Error for Bad\n"
                 "  def message : String\n    \"bad\"\n  end\nend\n\n"
                 "def load(path : String) : Int32 | Bad\n"
                 "  path == \"x\" ? 1 : Bad.new\nend\n\n"
                 "[\"a\", \"x\"].each do |path|\n"
                 "  puts \"or: #{load(path).or(0)}\"\nend\n")
    with open(orer, "w") as f:
        f.write(orer_text)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": file_uri(orer), "languageId": "iyi",
                             "version": 1, "text": orer_text}}, wait=False)
    c.diagnostics(file_uri(orer))
    reply = c.send("textDocument/hover", {
        "textDocument": {"uri": file_uri(orer)},
        "position": {"line": 16, "character": 17}})
    step("52i", "a hover inside an `or` is answered, not refused",
         "error" not in reply,
         json.dumps(reply.get("error") or reply.get("result"))[:80])

    fuzz_steps(c, work)

    # 60b. The proxy keeps a copy of every open buffer, and it read the
    #      four notifications that carry one as the protocol spells them:
    #      any other shape raised outside every rescue and the session
    #      ended with exit 1 - a didOpen with no text ("Missing hash key"),
    #      a change whose line is 0.5 or 2^40 ("Cast from Float64",
    #      "Arithmetic overflow"), a didSave whose params are a string
    #      ("Expected Hash"). The worker alone had survived every one. Each
    #      is sent here, and the hover after it must be answered.
    mal = os.path.join(work, "mal.iyi")
    with open(mal, "w") as f:
        f.write("module mal\n\nputs 1\n")
    mal_uri = file_uri(mal)
    c.send("textDocument/didOpen",
           {"textDocument": {"uri": mal_uri, "languageId": "iyi",
                             "version": 1, "text": "module mal\n\nputs 1\n"}}, wait=False)
    c.diagnostics(mal_uri)
    here = {"uri": mal_uri, "version": 2}
    origin = {"line": 0, "character": 0}
    far = {"line": 2 ** 40, "character": 0}
    misshapen = [
        ("textDocument/didOpen", {"textDocument": {"uri": mal_uri, "languageId": "iyi", "version": 1}}),
        ("textDocument/didOpen", {"textDocument": {"uri": 5, "text": "x"}}),
        ("textDocument/didOpen", None),
        ("textDocument/didChange", {"textDocument": here}),
        ("textDocument/didChange", {"textDocument": here, "contentChanges": [
            {"range": {"start": origin, "end": origin}}]}),
        ("textDocument/didChange", {"textDocument": here, "contentChanges": [
            {"range": {"start": {"line": 0.5, "character": 0}, "end": origin}, "text": "x"}]}),
        ("textDocument/didChange", {"textDocument": here, "contentChanges": [
            {"range": {"start": far, "end": far}, "text": "x"}]}),
        ("textDocument/didChange", "oops"),
        ("textDocument/didClose", [1]),
        ("textDocument/didSave", "x"),
    ]
    held = 0
    for method, params in misshapen:
        try:
            c.send(method, params, wait=False)
            reply = c.send("textDocument/hover", {
                "textDocument": {"uri": mal_uri}, "position": {"line": 2, "character": 0}})
        except (SystemExit, OSError):
            break
        if "error" in reply:
            break
        held += 1
    step("60b", "a buffer notification of the wrong shape does not end the session",
         held == len(misshapen), f"{held} of {len(misshapen)} answered after")

    # 60c. and a change that cannot be read is skipped, not the frame it
    #      came in: the worker raised on it and dropped the whole frame, so
    #      the readable change after it was lost too.
    span = {"start": {"line": 2, "character": 5}, "end": {"line": 2, "character": 6}}
    c.send("textDocument/didChange",
           {"textDocument": {"uri": mal_uri, "version": 30},
            "contentChanges": [{"range": span}, {"range": span, "text": "nope"}]}, wait=False)
    reply = c.send("textDocument/diagnostic", {"textDocument": {"uri": mal_uri}})
    items = (reply.get("result") or {}).get("items", [])
    step("60c", "a change that cannot be read is skipped, and the next one applies",
         [d["range"]["start"]["line"] for d in items if "nope" in d["message"]] == [2],
         f"{len(items)} item(s): {items and items[0]['message'][:50]}")
    # 53. shutdown/exit: the server leaves when told, not before — and
    # between the two it answers a request with the code the protocol has
    # for it rather than an empty result.
    c.send("shutdown", {})
    reply = c.send("textDocument/hover", {
        "textDocument": {"uri": app_uri}, "position": {"line": 0, "character": 0}})
    step(53, "after shutdown, a request is refused rather than half answered",
         reply.get("error", {}).get("code") == -32600,
         json.dumps(reply.get("error"))[:80])

    # 60d. and still after a pause. The proxy replaced a worker after two
    #      quiet seconds, and the successor had not been told of the
    #      shutdown: the same hover after a 3.5 s pause was answered in
    #      full. 60e. A successor started because the worker died is handed
    #      the client's `shutdown` (`Proxy@shutdown_frame`). Where the
    #      workers cannot be listed, 60e is unmeasured.
    time.sleep(3)
    reply = c.send("textDocument/hover", {
        "textDocument": {"uri": app_uri}, "position": {"line": 0, "character": 0}})
    step("60d", "after shutdown and a quiet pause, a request is still refused",
         reply.get("error", {}).get("code") == -32600,
         json.dumps(reply.get("error") or reply.get("result"))[:80])
    import signal
    workers = children(c.proc.pid)
    for pid in workers:
        os.kill(pid, signal.SIGTERM if os.name == "nt" else signal.SIGKILL)
    # The request the dead worker held is told so (-32603); the one after
    # it reaches the successor.
    for _ in range(3):
        reply = c.send("textDocument/hover", {
            "textDocument": {"uri": app_uri}, "position": {"line": 0, "character": 0}})
        if reply.get("error", {}).get("code") != -32603:
            break
    step("60e", "and after the worker is gone, a request is still refused",
         not workers or reply.get("error", {}).get("code") == -32600,
         f"{len(workers) or 'unmeasured'} worker(s) killed, then "
         + json.dumps(reply.get("error") or reply.get("result"))[:60])
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
