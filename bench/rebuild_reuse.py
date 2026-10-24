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
  4. one more build with nothing changed: every object reused.

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
    """`iyi build -s`: the objects it compiled again, or None when all were
    reused."""
    proc = subprocess.run([IYI, "build", "-s", *extra, entry, "-o", output], cwd=root, env=env,
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


def main():
    work = Path(tempfile.mkdtemp(prefix="iyi-rebuild-reuse"))
    try:
        print(f"rebuild reuse ({IYI}):")
        reuse(work)
        probe(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("\nrebuild reuse: a rebuild with nothing changed compiles nothing, and an edit compiles its own unit")


if __name__ == "__main__":
    main()
