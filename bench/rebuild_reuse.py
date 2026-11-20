#!/usr/bin/env python3
"""A rebuild with nothing changed reuses every object, `_main` included (#141).

    python3 bench/rebuild_reuse.py

A build writes one LLVM module per type, compares each with the bitcode the
previous build left in the cache, and compiles to an object only the ones
that differ. So a rebuild is as cheap as the compiler is deterministic: an
object is reused only when the same source produced the same bytes.

It was not. Debug builds ordered the initialisers of independent modules
(SPEC.md III.5 rule 2) with a fresh `Random` each build, codegen is
demand-driven from `__iyi_main`, and so every build of a program was a
slightly different program: `_main` changed, and with it the order functions
were emitted into whichever units an initialiser reached first. Ten
no-change rebuilds of the fixture below compiled 1 to 12 of its 100 objects
again, `_main` every time and `String`, `Hash(String, Int32)`,
`Array(String)`, `Std::Regex::RxCompiler` and `String::Builder` among the
rest, the shape of the report on a 10,700-line application (#141).
Disassembled, every unit three such rebuilds compiled again defined the same
functions as the build before it, most of them in another order: `_main`'s
66 behind another order of the five initialisers in `__iyi_main`,
`String`'s 52, `Int32`'s 9. Where the functions kept their order the
`declare`s had moved, or a `printf` declaration had landed in
`Hash(String, Int32)` in one build and not the next.
The order is now a hash of the module paths, the same every build, and the
same ten rebuilds compile nothing.

The fixture is seven modules, five of them independent of one another and
six with top-level code to run: generics (`Box(T)`, `Counter(K)`), unions
(`Measure`, `Counter(Int32 | String)`), std/regex, `derive serializable` from
std/json, and an EIY template rendered by `Eiy.def_to_s`. Into a private
cache:

  1. a cold build, and the program prints what it should;
  2. three builds with nothing changed: each reports every object reused;
  3. one line of one module's function body edited: that module's unit is
     the one object compiled again, and the program prints the edit;
  4. one more build with nothing changed: every object reused;
  5. on Windows, one more while another process holds the program, shared
     for reading only, for a second: the build waits for it and links;
  6. eleven other programs built into the same cache, then the fixture
     again: the EIY helper its template runs is reused, not built again,
     and the rotation left the ten builds it keeps;
  7. on Linux and macOS, the fixture's directory, made the oldest and
     padded to 50,000 files so that removing it takes a while, removed by
     another build's rotation: while files are still going, the removal
     holds the directory's `compiler.lock`, and the fixture built meanwhile
     waits for it and links; then the fixture built while this script holds
     the lock, the directory and the lock file removed before it is let go:
     the build makes the directory again and compiles every object;
  8. the reach verdicts at the cache's root, in a cache of their own: the
     fixture's made older than as many others as the rotation keeps
     (`CacheDir::REACH_KEPT`, 240), and the fixture built again: it reads
     them, proving nothing again, and its rotation keeps them and removes
     the oldest others; then 5,000 stale verdicts more, the fixture's the
     oldest of all, and the fixture built while another build's rotation
     removes them: both builds link, the fixture prints what it should,
     and after one more build 240 verdicts are left, the fixture's among
     them with the bytes it first stored. And no more std modules hold a
     `@[SafeReach]` claim than `CacheDir::REACH_MODULES` counts.

Step 5 is what Smart App Control's services do, evaluating, on Windows 11:
the Restart Manager named `CryptSvc`, `AppIDSvc` and the `applockerfltr`
filter holding a program 0.1 to 1.1 s after it ran, and a build begun at
once stopped at "LNK1104: cannot open file" in 6 of 60 builds of the probe
below - and this gate in 8 runs of 8 - where the compiler neither waited
nor linked again. Against that compiler step 5 failed in 2 runs of 2, at
"prog.exe is in use and cannot be replaced or moved aside".

Step 6 is #143: the cache keeps the ten directories used last, and the
helper counted with them. Against the compiler before helpers were kept
apart it failed in 1 run of 1, the helper built again in 2.38 s.

Step 7 is the self-hosted Mac's three CI jobs sharing one cache: a broken
copy of the std/secure_dns exercise stopped at "clang: error: no such file
or directory: 'P-ointer40U-I-nt841.o0.o'" (job 135882647898) while another
job built nine samples, each ending in a rotation. The removal asked
whether anyone held the directory and then deleted it holding nothing, so
a build that took the directory in between kept the objects it found and
linked after they were gone. Against that compiler (18333d052) on Linux,
on ext4, the first half failed 5 runs of 5 ("the removal did not hold the
lock: ... compiler.lock was free"), and the second half, run alone, 5 of 5
("a codegen thread failed: Error opening file with mode 'w': ...
_main.o0.bc: No such file or directory"); a build begun during a removal
padded to 200,000 files stopped 5 times of 5 at the Mac's own "cannot find
P-ointer40U-I-nt841.o0.o: No such file or directory". On that Mac (Apple
M2 Pro, APFS) the first half failed 3 runs of 3 and the second 3 of
3, and a build begun during a removal padded to 100,000 files stopped 2
times of 3 at "clang: error: no such file or directory: 'U-I-nt64.o0.o'";
with the fix the whole gate passed there and on Linux, and those builds
waited out the removal and linked 3 of 3. The second half needs to see
that the build has the lock file open, which Linux's /proc and macOS's
lsof show. Step 7 does not run on Windows: Python opens a file without
FILE_SHARE_DELETE, so this script could neither delete a lock file it
holds nor let the compiler delete one it has open.

Step 8 is the reach verdicts nothing removed: one per std module with
claims, keyed by the module's bytes, the flags and the compiler's own
executable, so every rebuild of the compiler wrote a new set, and the
rotation, removing directories only, passed over them. ~/.cache/iyi held
24,428 on the project's Mac (59.6 MB) and 16,660 on the Linux box. Against
the compiler before (6b131f8d8) the first half failed 3 runs of 3 on Linux
and 3 of 3 on Windows 11 ("the rotation left 241 reach verdicts, not 240"),
and against the fix with a read no longer marking the verdict used, 3 of 3
on Linux ("the rotation removed 1 of the 1 verdicts the build it ended had
just read"). With the fix the whole gate passed on both.

And because the old shuffle was there for a reason, rule 2's reordering is
held too: `probe/a` and `probe/b` both import `probe/log` and each
initialiser appends its letter to a class variable there, so the program
prints the order they ran in. Built under seeds 0 to 7, twice each, every
seed prints one order on both builds and the eight print the table SPEC.md
III.5 quotes, both orders in it: debug builds still reorder independent
modules, they no longer change their mind between builds. A release build
prints the load order.

Teeth: against the compiler before the fix (bdaeabbe6, fix/issue-140's
head), three runs of this gate each failed at step 2's first rebuild, which
compiled 2, 1 and 6 objects again, `_main` each time.

Exits non-zero, naming the step, if anything differs.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def compiler(spec):
    """An absolute path to the compiler: the builds below run in a temporary
    directory, where `./bin/iyi` means nothing."""
    if os.path.isabs(spec):
        return spec
    local = REPO / spec
    if local.exists():
        return str(local.resolve())
    return shutil.which(spec) or spec


IYI = compiler(os.environ.get("IYI", "./bin/iyi"))

FIXTURE = {
    "main.iyi": """module main

import app/shapes
import app/records
import app/patterns
import app/views
import app/tally
import app/report

puts App::Shapes.describe(1)
puts App::Shapes.describe(2.5)
puts App::Shapes.describe("x")
puts App::Shapes.total
puts App::Shapes.labels
puts App::Records.default_item.to_json
puts App::Patterns.numbers("a1 b22 c333").sum
puts App::Views.home
puts App::Tally.seen("start")
puts App::Tally.mixed
puts App::Report.line
""",
    "app/shapes.iyi": """module app/shapes

pub struct Box(T)
  getter value : T

  def initialize(@value : T)
  end
end

pub alias Measure = Int32 | Float64 | String

pub def describe(measure : Measure) : String
  case measure
  when Int32
    "int #{measure}"
  when Float64
    "float #{measure}"
  else
    "text #{measure}"
  end
end

SIZES = [Box.new(3), Box.new(4)]
LABELS = [Box.new("small"), Box.new("large")]

pub def total : Int32
  SIZES.sum(&.value)
end

pub def labels : String
  LABELS.map(&.value).join(",")
end
""",
    "app/records.iyi": """module app/records

import std/json::{JSON, serializable}

pub struct Item
  getter name : String
  getter count : Int32
  getter tags : Array(String)
  getter note : String?

  def initialize(@name : String, @count : Int32, @tags : Array(String), @note : String?)
  end

  derive serializable
end

DEFAULT = Item.from_json(%({"name": "tea", "count": 2, "tags": ["hot", "black"], "note": null}))

pub def default_item : Item
  DEFAULT
end

pub def round_trip(item : Item) : String
  Item.from_json(item.to_json).to_json
end
""",
    "app/patterns.iyi": """module app/patterns

import std/regex::{Regex}

WORD = Regex.compile("[a-z]+")
NUMBER = Regex.compile("[0-9]+")

pub def words(text : String) : Array(String)
  WORD.scan(text)
end

pub def numbers(text : String) : Array(Int32)
  NUMBER.scan(text).map(&.to_i)
end
""",
    "app/views.iyi": """module app/views

import std/eiy::{Eiy}

pub class Page
  getter title : String
  getter items : Array(String)

  def initialize(@title : String, @items : Array(String))
  end

  Eiy.def_to_s("page.eiy")
end

HOME = Page.new("home", ["a", "b"])

pub def home : String
  HOME.to_s
end
""",
    "app/page.eiy": """<h1><%= title %></h1>
<% items.each do |item| -%>
<li><%= item %></li>
<% end -%>
""",
    "app/tally.iyi": """module app/tally

pub class Counter(K)
  @counts = {} of K => Int32

  def add(key : K) : Nil
    @counts[key] = @counts.fetch(key, 0) + 1
  end

  def count(key : K) : Int32
    @counts.fetch(key, 0)
  end
end

SEEN = Counter(String).new
SEEN.add("start")
NUMBERS = Counter(Int32 | String).new
NUMBERS.add(1)
NUMBERS.add("one")

pub def seen(key : String) : Int32
  SEEN.count(key)
end

pub def mixed : Int32
  NUMBERS.count(1) + NUMBERS.count("one")
end
""",
    "app/report.iyi": """module app/report

import app/records
import app/patterns

pub def line : String
  item = App::Records.default_item
  "#{item.name}: #{App::Patterns.words(item.tags.join(" ")).size} words, #{App::Records.round_trip(item)}"
end
""",
}

EXPECTED = """int 1
float 2.5
text x
7
small,large
{"name":"tea","count":2,"tags":["hot","black"],"note":null}
356
<h1>home</h1>
<li>a</li>
<li>b</li>
1
2
tea: 2 words, {"name":"tea","count":2,"tags":["hot","black"],"note":null}
"""

# Step 3's edit: one line of one function body in one module. Its return type
# and every signature stay as they were, so nothing outside the unit the body
# is emitted into has anything new to say.
EDIT_FILE = "app/shapes.iyi"
EDIT_FROM = '    "int #{measure}"\n'
EDIT_TO = '    "integer #{measure}"\n'
EDITED_UNIT = "App::Shapes"

PROBE = {
    "probe/log.iyi": """module probe/log

pub class Log
  @@items = [] of String

  def self.add(item : String) : Nil
    @@items << item
  end

  def self.items : Array(String)
    @@items
  end
end
""",
    "probe/a.iyi": """module probe/a

import probe/log::{Log}

Log.add("a")
""",
    "probe/b.iyi": """module probe/b

import probe/log::{Log}

Log.add("b")
""",
    "probe/main.iyi": """module probe/main

import probe/a
import probe/b
import probe/log::{Log}

puts Log.items.join(",")
""",
}

PROBE_SEEDS = range(8)

# What SPEC.md III.5 quotes for the probe: the order each seed hands out, the
# default being seed 0, and the load order a release build keeps. A change to
# the hash changes every debug build's order, and has to change that sentence.
PROBE_ORDERS = {"b,a": [0, 2, 5, 6], "a,b": [1, 3, 4, 7]}
PROBE_RELEASE = "a,b"

REUSED = re.compile(r"^ - (all previous|no previous|(\d+)/(\d+)) \.o files were reused", re.M)
UNIT = re.compile(r"^ - (.+) \(([^()]+\.bc)\)$", re.M)


def write(root, files):
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, newline="\n")


def environment(cache):
    env = dict(os.environ)
    env["IYI_CACHE_DIR"] = str(cache)
    # A pinned order is what this gate exists to make unnecessary; inherited,
    # it would hide the bug rather than test the fix.
    env.pop("IYI_INIT_SEED", None)
    return env


def build(root, entry, output, env, extra=()):
    """`iyi build -s --force`: the objects it compiled again, or None when all
    were reused. `--force` because a build with nothing changed is now
    skipped before codegen (#142), and the objects' reuse is what this gate
    asks about."""
    proc = subprocess.run([IYI, "build", "-s", "--force", *extra, entry, "-o", output], cwd=root, env=env,
                          capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"rebuild_reuse: `iyi build {entry}` failed\n{proc.stdout}{proc.stderr}")
    found = REUSED.search(proc.stdout)
    if not found:
        sys.exit(f"rebuild_reuse: `iyi build -s` printed no reuse line\n{proc.stdout}")
    if found.group(1) == "all previous":
        return None
    rest = proc.stdout[found.end():]
    return [name for name, _ in UNIT.findall(rest)] or ["(every object)"]


def run(root, output):
    exe = root / (output + ".exe" if os.name == "nt" else output)
    proc = subprocess.run([str(exe)], cwd=root, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"rebuild_reuse: {exe} exited {proc.returncode}\n{proc.stdout}{proc.stderr}")
    return proc.stdout.replace("\r\n", "\n")


def fail(step, message):
    print(f"  FAIL: {step}: {message}")
    sys.exit(1)


def reuse(work):
    root = work / "project"
    write(root, FIXTURE)
    env = environment(work / "cache")

    build(root, "main.iyi", "prog", env)
    printed = run(root, "prog")
    if printed != EXPECTED:
        fail("1. cold build", f"the program printed\n{printed}")
    print("  ok   1. a cold build, and the program prints what it should")

    for again in (1, 2, 3):
        rebuilt = build(root, "main.iyi", "prog", env)
        if rebuilt is not None:
            fail(f"2. no-change rebuild {again}", f"compiled again: {', '.join(rebuilt)}")
    print("  ok   2. three no-change rebuilds, every object reused each time")

    path = root / EDIT_FILE
    text = path.read_text()
    if text.count(EDIT_FROM) != 1:
        fail("3. edit", f"the line the edit replaces is not once in {EDIT_FILE}")
    path.write_text(text.replace(EDIT_FROM, EDIT_TO), newline="\n")
    rebuilt = build(root, "main.iyi", "prog", env)
    if rebuilt != [EDITED_UNIT]:
        fail("3. one-line edit", f"compiled again: {', '.join(rebuilt or ['nothing'])}; wanted {EDITED_UNIT} alone")
    printed = run(root, "prog")
    if printed != EXPECTED.replace("int 1\n", "integer 1\n", 1):
        fail("3. one-line edit", f"the program printed\n{printed}")
    print(f"  ok   3. one line of {EDIT_FILE} edited: {EDITED_UNIT} compiled again, nothing else")

    rebuilt = build(root, "main.iyi", "prog", env)
    if rebuilt is not None:
        fail("4. no-change rebuild after the edit", f"compiled again: {', '.join(rebuilt)}")
    print("  ok   4. a no-change rebuild after the edit, every object reused")


def probe(work):
    root = work / "probe"
    write(root, PROBE)
    env = environment(work / "probe-cache")
    orders = {}
    for seed in PROBE_SEEDS:
        env["IYI_INIT_SEED"] = str(seed)
        seen = set()
        for _ in (1, 2):
            build(root, "probe/main.iyi", "probe-out", env)
            seen.add(run(root, "probe-out").strip())
        if len(seen) != 1:
            fail("rule 2", f"IYI_INIT_SEED={seed} printed {' and '.join(sorted(seen))} on two builds")
        orders.setdefault(seen.pop(), []).append(seed)

    def described(table):
        return "; ".join(f"{order} under {', '.join(map(str, seeds))}" for order, seeds in sorted(table.items()))

    if orders != PROBE_ORDERS:
        fail("rule 2", f"seeds {PROBE_SEEDS.start}-{PROBE_SEEDS.stop - 1} printed {described(orders)}; "
                       f"SPEC.md III.5 says {described(PROBE_ORDERS)}")
    print(f"  ok   rule 2: each seed prints one order on every build, both orders appear ({described(orders)})")

    env.pop("IYI_INIT_SEED")
    build(root, "probe/main.iyi", "probe-release", env, extra=("--release",))
    released = run(root, "probe-release").strip()
    if released != PROBE_RELEASE:
        fail("rule 2", f"a release build printed {released}; the load order is {PROBE_RELEASE}")
    print(f"  ok   rule 2: a release build keeps the load order ({released})")


# How long step 5 holds the program: past the half second a rebuild that
# reuses every object takes to reach its link here, inside the two seconds
# the compiler waits.
HOLD_SECONDS = 1.0


def held(work):
    """Windows: the program rebuilt while another process has it open for
    reading and shares it for reading only, as Smart App Control's services
    have a program that just ran."""
    if os.name != "nt":
        return
    import ctypes
    import threading
    from ctypes import wintypes

    root = work / "project"
    env = environment(work / "cache")
    exe = root / "prog.exe"
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                                     wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    # GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING.
    handle = kernel32.CreateFileW(str(exe), 0x80000000, 1, None, 3, 0, None)
    if handle is None or handle == wintypes.HANDLE(-1).value:
        fail("5. a held program", f"could not open {exe}: error {ctypes.get_last_error()}")
    release = threading.Timer(HOLD_SECONDS, kernel32.CloseHandle, (handle,))
    release.start()
    try:
        build(root, "main.iyi", "prog", env)
    finally:
        release.join()
    printed = run(root, "prog")
    if printed != EXPECTED.replace("int 1\n", "integer 1\n", 1):
        fail("5. a held program", f"the program printed\n{printed}")
    print(f"  ok   5. a rebuild while another process held the program for {HOLD_SECONDS:g} s, shared for reading only")


# More other programs than the cache's rotation keeps (`CacheDir::KEPT`).
KEPT = 10
OTHERS = KEPT + 1
HELPER = re.compile(r"^ - .*eiy[\\/]process\.iyi: (.*)$", re.M)


def builds(cache):
    """The build directories in *cache*: not the helpers, which the rotation
    counts apart (`CacheDir::MACRO_RUN`)."""
    return [entry for entry in cache.iterdir() if entry.is_dir() and not (entry / "macro_run").exists()]


def outlived(work):
    """The EIY helper `Eiy.def_to_s` runs is still built after more other
    programs than the cache keeps were built into the same cache."""
    root = work / "project"
    env = environment(work / "cache")
    others = work / "others"
    for i in range(OTHERS):
        write(others, {f"other{i}.iyi": f"module other{i}\n\nputs {i}\n"})
        proc = subprocess.run([IYI, "build", f"other{i}.iyi", "-o", f"other{i}"], cwd=others, env=env,
                              capture_output=True, text=True)
        if proc.returncode != 0:
            fail("6. a helper outlives other builds", f"other{i}.iyi did not build\n{proc.stdout}{proc.stderr}")
    proc = subprocess.run([IYI, "build", "-s", "--force", "main.iyi", "-o", "prog"], cwd=root, env=env,
                          capture_output=True, text=True)
    if proc.returncode != 0:
        fail("6. a helper outlives other builds", f"main.iyi did not build\n{proc.stdout}{proc.stderr}")
    found = HELPER.search(proc.stdout)
    if not found:
        fail("6. a helper outlives other builds", f"`iyi build -s` named no EIY helper\n{proc.stdout}")
    if not found.group(1).startswith("reused previous compilation"):
        fail("6. a helper outlives other builds", f"after {OTHERS} other programs the EIY helper was built again: {found.group(1)}")
    kept = builds(work / "cache")
    if len(kept) != KEPT:
        fail("6. a helper outlives other builds",
             f"after {OTHERS + 1} programs the rotation left {len(kept)} builds, not {KEPT}: "
             f"{', '.join(sorted(entry.name for entry in kept))}")
    print(f"  ok   6. after {OTHERS} other programs into the same cache, the EIY helper is reused, and {KEPT} builds are kept")


# Files added to the fixture's directory so that removing it takes long
# enough to be looked at: about 0.6 s on Linux (ext4).
PADS = 50_000


def entries(directory):
    """How many entries *directory* holds; -1 once it is gone."""
    try:
        return len(os.listdir(directory))
    except FileNotFoundError:
        return -1


def has_open(pid, path):
    """Whether process *pid* has *path* open: Linux's /proc, else lsof."""
    target = os.path.realpath(path)
    fds = f"/proc/{pid}/fd"
    if os.path.isdir(fds):
        for fd in os.listdir(fds):
            try:
                if os.path.realpath(os.readlink(os.path.join(fds, fd))) == target:
                    return True
            except OSError:
                pass
        return False
    proc = subprocess.run(["lsof", "-a", "-p", str(pid), "-Fn"], capture_output=True, text=True)
    return any(line[1:] and os.path.realpath(line[1:]) == target for line in proc.stdout.splitlines() if line.startswith("n"))


def directory_of(cache, root):
    """The fixture's build directory in *cache*: named after its entry's path."""
    tail = f"-{root.name}-main.iyi"
    found = [entry for entry in builds(cache) if entry.name.endswith(tail)]
    if len(found) != 1:
        fail("7. a directory removed under a build", f"{len(found)} directories in {cache} end in {tail}")
    return found[0]


def reported(output):
    found = REUSED.search(output)
    return found.group(1) if found else "no reuse line"


def contested(work):
    """A build whose cache directory another build's rotation is removing."""
    step = "7. a directory removed under a build"
    if os.name == "nt":
        print("  skip 7. Windows: this script cannot hold a file the compiler deletes (Python opens files without FILE_SHARE_DELETE)")
        return
    import fcntl

    root = work / "contested"
    write(root, FIXTURE)
    cache = work / "contested-cache"
    env = environment(cache)
    build(root, "main.iyi", "prog", env)
    directory = directory_of(cache, root)
    lock = directory / "compiler.lock"

    # The removal: the fixture's directory the oldest of eleven builds, and
    # another build's rotation at its end.
    for i in range(PADS):
        open(directory / f"pad-{i}", "w").close()
    os.utime(directory, (946684800, 946684800))
    for i in range(KEPT):
        (cache / f"newer-{i}").mkdir()
    whole = entries(directory)
    others = work / "contested-others"
    write(others, {"rotate.iyi": "module rotate\n\nputs 0\n"})
    rotation = subprocess.Popen([IYI, "build", "rotate.iyi", "-o", "rotate"], cwd=others, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    while entries(directory) >= whole:
        if rotation.poll() is not None:
            fail(step, f"the rotation did not remove the oldest directory (exit {rotation.returncode})\n{rotation.stdout.read()}")
        time.sleep(0.001)

    # Looked at mid-way: the lock tried, then the files counted, so a removal
    # that still had files to delete after the try was under way during it.
    try:
        fd = os.open(lock, os.O_RDONLY)
    except FileNotFoundError:
        held = "gone"
    else:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            held = "free"
            fcntl.flock(fd, fcntl.LOCK_UN)
        except BlockingIOError:
            held = "held"
        os.close(fd)
    left = entries(directory)
    if left <= 1:
        fail(step, f"the removal of {whole} entries ended before it could be looked at; pad the directory more than {PADS}")
    if held != "held":
        fail(step, f"the removal did not hold the lock: with {left} of {whole} entries left, compiler.lock was {held}")

    during = subprocess.run([IYI, "build", "-s", "--force", "main.iyi", "-o", "prog"], cwd=root, env=env,
                            capture_output=True, text=True)
    rotated = rotation.communicate()[0]
    if rotation.returncode != 0:
        fail(step, f"the build whose rotation removed the directory failed\n{rotated}")
    if during.returncode != 0:
        fail(step, f"the fixture built during the removal failed\n{during.stdout}{during.stderr}")
    if run(root, "prog") != EXPECTED:
        fail(step, "the fixture built during the removal printed something else")
    if any(name.startswith("pad-") for name in (os.listdir(directory) if directory.exists() else [])):
        fail(step, "the removal left files behind")
    print(f"  ok   7. a removal holds compiler.lock while it deletes ({left} of {whole} entries left),"
          f" and a build meanwhile waits for it and links")

    # The build waiting while the lock's holder removes the directory, the
    # lock file and all: it has to find it holds a file that is gone.
    fd = os.open(lock, os.O_RDWR | os.O_CREAT)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        waiting = subprocess.Popen([IYI, "build", "-s", "--force", "main.iyi", "-o", "prog"], cwd=root, env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        deadline = time.monotonic() + 120
        while not has_open(waiting.pid, lock):
            if waiting.poll() is not None:
                fail(step, f"the fixture built while its directory's lock was held by another\n{waiting.stdout.read()}")
            if time.monotonic() > deadline:
                waiting.kill()
                fail(step, "the fixture's build did not open compiler.lock in 120 s")
            time.sleep(0.01)
        for name in os.listdir(directory):
            if (directory / name).is_dir():
                shutil.rmtree(directory / name)
            elif name != lock.name:
                os.unlink(directory / name)
        os.unlink(lock)
        os.rmdir(directory)
    finally:
        os.close(fd)
    printed = waiting.communicate()[0]
    if waiting.returncode != 0:
        fail(step, f"the build that waited while its directory was removed failed\n{printed}")
    if reported(printed) != "no previous":
        fail(step, f"the build that waited while its directory was removed said: {reported(printed)}")
    if run(root, "prog") != EXPECTED:
        fail(step, "the build that waited while its directory was removed printed something else")
    print("  ok   7. a build waiting on a directory its lock's holder removed makes it again and compiles every object")


# The reach verdicts the rotation keeps (`CacheDir::REACH_KEPT`): one for
# each std module that holds a `@[SafeReach]` claim
# (`CacheDir::REACH_MODULES`), for every build and helper it keeps.
REACH_MODULES = 12
REACH_KEPT = 2 * KEPT * REACH_MODULES
# The verdicts no build reads that step 8 leaves a rotation to cut down
# while the fixture builds.
STALE = 5_000
CLAIM = re.compile(r"^\s*@\[SafeReach\b", re.M)
# 2000-01-01, and a year: dates older than any build of today's.
AGED = 946684800
YEAR = 365 * 86400


def verdicts(cache):
    """The reach verdicts at *cache*'s root, by name."""
    return {entry.name: entry for entry in cache.iterdir() if entry.name.startswith("reach-") and entry.is_file()}


def counted(cache):
    return sum(1 for name in os.listdir(cache) if name.startswith("reach-"))


def plant(cache, tag, count, start):
    """*count* verdicts no build reads, the first dated *start* and each a
    second newer than the one before; their names, oldest first."""
    names = []
    for i in range(count):
        path = cache / f"reach-{tag}-{i:08d}"
        path.write_text("iyi reach verdict 2\nend\n", newline="\n")
        os.utime(path, (start + i, start + i))
        names.append(path.name)
    return names


def age(paths, when):
    for path in paths:
        os.utime(path, (when, when))


def verdicts_rotated(work):
    """The rotation keeps the reach verdicts used last, those a build has
    just read among them, and a build whose verdicts it removes proves them
    again to the same answer."""
    step = "8. reach verdicts"
    modules = [path for path in sorted((REPO / "src" / "std").rglob("*.iyi"))
               if CLAIM.search(path.read_text(encoding="utf-8"))]
    if len(modules) > REACH_MODULES:
        fail(step, f"{len(modules)} std modules hold a @[SafeReach] claim, and the rotation keeps verdicts for "
                   f"{REACH_MODULES} a build: raise CacheDir::REACH_MODULES, and REACH_MODULES here")

    root = work / "reach"
    write(root, FIXTURE)
    cache = work / "reach-cache"
    env = environment(cache)
    build(root, "main.iyi", "prog", env)
    first = verdicts(cache)
    if not first:
        fail(step, "the fixture's build stored no reach verdict")
    if len(first) > REACH_MODULES:
        fail(step, f"the fixture's build stored {len(first)} reach verdicts, more than the {REACH_MODULES} a build may")
    stored = {name: (entry.stat().st_ino, entry.read_bytes()) for name, entry in first.items()}

    # The fixture's verdicts made older than as many others as the rotation
    # keeps: the build that reads them makes them its newest.
    age(first.values(), AGED)
    planted = plant(cache, "kept", REACH_KEPT, AGED + YEAR)
    build(root, "main.iyi", "prog", env)
    left = verdicts(cache)
    gone = sorted(set(first) - set(left))
    if gone:
        fail(step, f"the rotation removed {len(gone)} of the {len(first)} verdicts the build it ended had just read: {', '.join(gone)}")
    # Read, a verdict keeps its file; proven again, it is written to another
    # and renamed over the first.
    proven = sorted(name for name in first if left[name].stat().st_ino != stored[name][0])
    if proven:
        fail(step, f"the rebuild proved {len(proven)} of its {len(first)} stored verdicts again: {', '.join(proven)}")
    if len(left) != REACH_KEPT:
        fail(step, f"the rotation left {len(left)} reach verdicts, not {REACH_KEPT}")
    removed = [name for name in planted if name not in left]
    if removed != planted[:len(first)]:
        fail(step, f"the rotation removed {len(removed)} of the planted verdicts, not the {len(first)} oldest")
    print(f"  ok   8. the fixture's reach verdicts ({len(first)}), made the oldest of {len(first) + REACH_KEPT},"
          f" outlive the rotation of the build that reads them, and the {REACH_KEPT} kept are the newest")

    # A rotation with STALE more to remove, the fixture's own the oldest
    # of all, and the fixture built while it removes them.
    plant(cache, "stale", STALE, AGED - YEAR)
    age((cache / name for name in first), AGED - 2 * YEAR)
    whole = counted(cache)
    others = work / "reach-others"
    write(others, {"rotate.iyi": "module rotate\n\nputs 0\n"})
    rotation = subprocess.Popen([IYI, "build", "rotate.iyi", "-o", "rotate"], cwd=others, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    while (begun := counted(cache)) >= whole:
        if rotation.poll() is not None and counted(cache) >= whole:
            fail(step, f"the rotation removed no reach verdict of {whole} (exit {rotation.returncode})\n{rotation.stdout.read()}")
        time.sleep(0.001)
    during = subprocess.run([IYI, "build", "-s", "--force", "main.iyi", "-o", "prog"], cwd=root, env=env,
                            capture_output=True, text=True)
    rotated = rotation.communicate()[0]
    if rotation.returncode != 0:
        fail(step, f"the build whose rotation removed the verdicts failed\n{rotated}")
    if during.returncode != 0:
        fail(step, f"the fixture built while its verdicts were being removed failed\n{during.stdout}{during.stderr}")
    if run(root, "prog") != EXPECTED:
        fail(step, "the fixture built while its verdicts were being removed printed something else")
    build(root, "main.iyi", "prog", env)
    last = verdicts(cache)
    if len(last) != REACH_KEPT:
        fail(step, f"after {STALE} stale verdicts the rotation left {len(last)}, not {REACH_KEPT}")
    changed = sorted(name for name in first if name not in last or last[name].read_bytes() != stored[name][1])
    if changed:
        fail(step, f"the fixture's verdicts, removed and proven again, are missing or answer otherwise: {', '.join(changed)}")
    print(f"  ok   8. the fixture built with {begun} of {whole} verdicts left to a rotation that removes its own,"
          f" and its verdicts back after it with the same bytes; {REACH_KEPT} kept")


def main():
    work = Path(tempfile.mkdtemp(prefix="iyi-rebuild-reuse"))
    try:
        print(f"rebuild reuse ({IYI}):")
        reuse(work)
        held(work)
        outlived(work)
        contested(work)
        verdicts_rotated(work)
        probe(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("\nrebuild reuse: a rebuild with nothing changed compiles nothing, and an edit compiles its own unit")


if __name__ == "__main__":
    main()
