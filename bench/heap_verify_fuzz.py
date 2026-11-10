#!/usr/bin/env python3
"""heap22's crossings, fuzzed: random programs that move random value graphs
through every crossing the design (heap22-design-partition.md §2.1) closes,
run under -Dheap_verify with the chaos scheduler and a local collection at
every chaos point, and compared with a build that has no heap flags.

  python3 bench/heap_verify_fuzz.py gen --seed S --out DIR
      one program, DIR/heap_verify_fuzz_S.iyi

  python3 bench/heap_verify_fuzz.py run --programs N --seeds K [--first F]
          [--workers W[,W...]] [--false-words] [--release]
      for program seeds F..F+N-1: build each twice (no heap flags, the
      reference; and -Dheap_partitions -Dheap_verify -Diyi_chaos), run the
      reference once and the verify build K times per worker count under
      IYI_CHAOS=<seed> IYI_HEAP_STRESS=1 IYI_WORKERS=<W>, and compare.

A program is a sequence of steps, some run at once in units of their own,
some nested a unit or two deep. Each step builds values inside a unit from
seeds the generator fixed: Share graphs (structurally immutable classes and
structs, a class typed as its abstract base, String, List, tuples, unions)
and non-Share ones (a mutable class with Array, Hash and back pointers, an
Array, a Hash). It hands them over one crossing, with allocation churn
around it so that local collections find garbage, and the receiving side
folds what it got into an FNV checksum. The step also rebuilds what was sent
from the same seeds where nothing crosses and folds that, so a line says
`ok` when the two agree. Where the order of arrival depends on the schedule
(several senders, several lock holders) the fold is a sum over the values,
which no order changes. The main thread prints one line per step, in step
order, after joining it: nothing printed depends on the schedule or an
address. Non-Share graphs never cross: they stay in the unit that made them,
in a `Unit`, under a `Mutex`, or come back whole as a `unit: :new` task's
answer (row 2, where the dead child's partition is adopted).

Builds go through ~/.cache/heavy.sh, one build per call. Runs do not.
"""

import argparse
import os
import random
import shutil
import signal
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HEAVY = Path.home() / ".cache" / "heavy.sh"
DEFAULT_TMP = Path(os.environ.get("TMPDIR") or (Path.home() / ".cache" / "h22-hp-s4-tmp"))
VERIFY_FLAGS = ["-Dheap_partitions", "-Dheap_verify", "-Diyi_chaos"]
RUN_TIMEOUT = 120

# ── The fixed part of every program ─────────────────────────────────────────

SUPPORT = r'''
@[Unsafe("heap_verify_fuzz: Box.box and GC.malloc hand an object over as an address kept in a class variable, and ENV is set from units (heap22 rows 9 and 13)")]
import std/mutex::{Mutex}
import std/unit::{Unit}
import std/shared_proc::{SharedProc}
import std/list::{List}
import std/box::{Box}
import std/gc::{GC}
import std/env::{ENV}

FNV_BASIS = 0xcbf29ce484222325_u64
FNV_PRIME = 0x100000001b3_u64
BAD       = 0xbadbadbadbadbad_u64

def mix(x : UInt64) : UInt64
  z = x &+ 0x9e3779b97f4a7c15_u64
  z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9_u64
  z = (z ^ (z >> 27)) &* 0x94d049bb133111eb_u64
  z ^ (z >> 31)
end

def fnv_i(h : UInt64, v : UInt64) : UInt64
  i = 0
  while i < 8
    h = (h ^ ((v >> (i * 8)) & 0xff_u64)) &* FNV_PRIME
    i += 1
  end
  h
end

def fnv_s(h : UInt64, s : String) : UInt64
  p = s.to_unsafe
  n = s.bytesize
  i = 0
  while i < n
    h = (h ^ p[i].to_u64) &* FNV_PRIME
    i += 1
  end
  fnv_i(h, n.to_u64)
end

# A string made at run time, of a length that is now and then large enough
# for a size class of its own.
def label_of(r : UInt64, len : Int32) : String
  "s" + (r % 1000003_u64).to_s + "-" + "x" * len
end

def len_of(r : UInt64, size : Int32) : Int32
  return 1000 + (r % 7000_u64).to_i32 if r % 23_u64 == 0_u64
  (r % (8 * size + 4).to_u64).to_i32
end

# ── Share values ────────────────────────────────────────────────────────────

struct SPair
  getter a : String
  getter b : Int64

  def initialize(@a : String, @b : Int64)
  end
end

abstract class SShape
  abstract def name : String
  abstract def fold_into(h : UInt64) : UInt64
end

class SCircle < SShape
  getter name : String
  getter radius : Int64

  def initialize(@name : String, @radius : Int64)
  end

  def fold_into(h : UInt64) : UInt64
    fnv_i(fnv_s(fnv_i(h, 1_u64), @name), @radius.to_u64)
  end
end

class SPoly < SShape
  getter name : String
  getter points : List({Int64, Int64})

  def initialize(@name : String, @points : List({Int64, Int64}))
  end

  def fold_into(h : UInt64) : UInt64
    h = fnv_s(fnv_i(h, 2_u64), @name)
    i = 0
    while i < @points.size
      point = @points[i]
      h = fnv_i(fnv_i(h, point[0].to_u64), point[1].to_u64)
      i += 1
    end
    h
  end
end

class SNode
  getter label : String
  getter num : Int64
  getter kids : List(SNode)
  getter pair : SPair
  getter tag : {String, Int32} | Int64
  getter shape : SShape?

  def initialize(@label : String, @num : Int64, @kids : List(SNode), @pair : SPair, @tag : {String, Int32} | Int64, @shape : SShape?)
  end
end

def make_shape(seed : UInt64, size : Int32) : SShape
  r = mix(seed)
  if r % 2_u64 == 0_u64
    return SCircle.new(label_of(r >> 3, len_of(r >> 7, size)), ((r >> 11) % 100000_u64).to_i64)
  end
  points = [] of {Int64, Int64}
  n = size * 3 + ((r >> 5) % 4_u64).to_i32
  i = 0
  while i < n
    q = mix(seed &+ (i + 1).to_u64)
    points << {(q % 1000_u64).to_i64, ((q >> 20) % 1000_u64).to_i64}
    i += 1
  end
  SPoly.new(label_of(r >> 9, len_of(r >> 13, size)), List.new(points))
end

def build_s(seed : UInt64, depth : Int32) : SNode
  r = mix(seed)
  kids = [] of SNode
  if depth > 0
    n = ((r >> 7) % 4_u64).to_i32
    i = 0
    while i < n
      kids << build_s(mix(seed &+ (i + 1).to_u64), depth - 1)
      i += 1
    end
  end
  tag = (r >> 11) % 3_u64 == 0_u64 ? ((r >> 13) % 1000_u64).to_i64 : {label_of(r >> 3, 3), ((r >> 17) % 100_u64).to_i32}
  shape = (r >> 19) % 4_u64 == 0_u64 ? make_shape(r, 1) : nil
  how = (r >> 23) % 3_u64
  list = List.new(kids)
  if how == 1_u64
    list = List.new([] of SNode).concatenated(list)
  elsif how == 2_u64 && kids.size > 0
    list = List.new([kids[0]])
    j = 1
    while j < kids.size
      list = list.appended(kids[j])
      j += 1
    end
  end
  SNode.new(label_of(r, len_of(r >> 29, 2)), ((r >> 5) % 1000000_u64).to_i64, list,
    SPair.new(label_of(r >> 9, 2), ((r >> 31) % 77777_u64).to_i64), tag, shape)
end

def make_node(seed : UInt64, size : Int32) : SNode
  build_s(seed, size > 4 ? 4 : size)
end

def make_nodes(seed : UInt64, size : Int32) : List(SNode)
  items = [] of SNode
  n = size * 2 + 1
  i = 0
  while i < n
    items << build_s(mix(seed &+ i.to_u64), 1 + i % 2)
    i += 1
  end
  List.new(items)
end

def make_strs(seed : UInt64, size : Int32) : List(String)
  n = size * 6 + (seed % 5_u64).to_i32
  if seed % 2_u64 == 0_u64
    list = List.new([label_of(seed, 1)])
    i = 1
    while i < n
      q = mix(seed &+ i.to_u64)
      list = list.appended(label_of(q, len_of(q >> 8, size)))
      i += 1
    end
    return list
  end
  items = [] of String
  i = 0
  while i < n
    q = mix(seed &+ i.to_u64)
    items << label_of(q, len_of(q >> 8, size))
    i += 1
  end
  List.new(items)
end

def make_deep(seed : UInt64, size : Int32) : List(List(String))
  items = [] of List(String)
  i = 0
  while i <= size
    items << make_strs(mix(seed &+ i.to_u64), 1)
    i += 1
  end
  List.new(items)
end

def make_tuple(seed : UInt64, size : Int32) : {String, Int64, SNode}
  r = mix(seed)
  {label_of(r, len_of(r >> 3, size)), ((r >> 9) % 100000_u64).to_i64, build_s(mix(r), size > 2 ? 2 : size)}
end

def make_pair(seed : UInt64, size : Int32) : SPair
  r = mix(seed)
  SPair.new(label_of(r, len_of(r >> 3, size)), ((r >> 7) % 100000_u64).to_i64)
end

def make_str(seed : UInt64, size : Int32) : String
  r = mix(seed)
  label_of(r, len_of(r >> 5, size * 20))
end

# ── Folds: FNV over labels and integers ────────────────────────────────────

def fold(h : UInt64, v : String) : UInt64
  fnv_s(h, v)
end

def fold(h : UInt64, v : Int64) : UInt64
  fnv_i(h, v.to_u64)
end

def fold(h : UInt64, v : Nil) : UInt64
  fnv_i(h, 0x6e696c_u64)
end

def fold(h : UInt64, v : SPair) : UInt64
  fnv_i(fnv_s(h, v.a), v.b.to_u64)
end

def fold(h : UInt64, v : SShape) : UInt64
  v.fold_into(h)
end

def fold(h : UInt64, v : {String, Int32}) : UInt64
  fnv_i(fnv_s(h, v[0]), v[1].to_u64)
end

def fold(h : UInt64, v : {String, Int64, SNode}) : UInt64
  fold(fnv_i(fnv_s(h, v[0]), v[1].to_u64), v[2])
end

def fold(h : UInt64, v : List(T)) : UInt64 forall T
  h = fnv_i(h, v.size.to_u64)
  i = 0
  while i < v.size
    h = fold(h, v[i])
    i += 1
  end
  h
end

def fold(h : UInt64, v : SNode) : UInt64
  h = fnv_i(fnv_s(h, v.label), v.num.to_u64)
  h = fold(h, v.pair)
  h = fold(h, v.tag)
  h = fold(h, v.shape)
  fold(h, v.kids)
end

def fold(h : UInt64, v : Panicked) : UInt64
  h ^ BAD
end

def fold(h : UInt64, v : ChannelClosed) : UInt64
  h ^ BAD
end

def fold(h : UInt64, v : Cancelled) : UInt64
  h ^ BAD
end

# A string out of a Share value, for a mutation or a lock to keep.
def pick(v : String) : String
  v
end

def pick(v : SNode) : String
  v.label
end

def pick(v : SPair) : String
  v.a
end

def pick(v : SShape) : String
  v.name
end

def pick(v : {String, Int64, SNode}) : String
  v[0]
end

def pick(v : List(T)) : String forall T
  v.size > 0 ? pick(v[0]) : "empty"
end

def num(x : UInt64) : UInt64
  x
end

def num(x : Panicked | ChannelClosed | Cancelled) : UInt64
  BAD
end

def pair_of(x : {UInt64, UInt64}) : {UInt64, UInt64}
  x
end

def pair_of(x : Panicked) : {UInt64, UInt64}
  {BAD, 0_u64}
end

def msg(x : Panicked) : UInt64
  fnv_s(FNV_BASIS, x.message)
end

def msg(x : UInt64) : UInt64
  BAD
end

def message_of(x : Panicked) : String
  x.message
end

def message_of(x : UInt64) : String
  "no panic"
end

def string_or(x : String) : String
  x
end

def string_or(x : Panicked) : String
  "panicked"
end

def panic_text(s : String, seed : UInt64) : String
  "heap_verify_fuzz panics on purpose: " + s + " " + label_of(seed, 4)
end

# ── Non-Share values: a mutable graph with back pointers ───────────────────

class MNode
  property label : String
  property up : MNode?
  getter items : Array(MNode)
  getter table : Hash(String, Int64)
  getter notes : Array(String)

  def initialize(@label : String)
    @up = nil
    @items = [] of MNode
    @table = {} of String => Int64
    @notes = [] of String
  end
end

def build_m(seed : UInt64, size : Int32) : MNode
  root = MNode.new(label_of(seed, 5))
  all = [root]
  n = size * 4 + 2
  i = 0
  while i < n
    r = mix(seed &+ (i + 1).to_u64)
    parent = all[((r >> 3) % all.size.to_u64).to_i32]
    child = MNode.new(label_of(r, len_of(r >> 9, 2)))
    child.up = parent
    parent.items << child
    parent.table[label_of(r >> 5, 1)] = ((r >> 13) % 10000_u64).to_i64
    parent.notes << label_of(r >> 21, ((r >> 27) % 12_u64).to_i32)
    all << child
    i += 1
  end
  root
end

def unit_init(seed : UInt64, size : Int32, extra : String) : MNode
  m = build_m(seed, size)
  m.notes << extra
  m
end

def mutate_m(root : MNode, s : String, seed : UInt64) : Nil
  r = mix(seed)
  node = root
  steps = ((r >> 3) % 4_u64).to_i32
  while steps > 0 && node.items.size > 0
    node = node.items[((r >> (steps * 5)) % node.items.size.to_u64).to_i32]
    steps -= 1
  end
  child = MNode.new(s + "/" + label_of(r >> 7, 1))
  child.up = node
  node.items << child
  node.notes << s
  node.notes.shift if node.notes.size > 6
  node.table[s] = node.table.fetch(s, 0_i64) &+ 1_i64
  node.table.delete(label_of(r >> 17, 1))
  node.label = node.label + "+" if (r >> 11) % 3_u64 == 0_u64
end

def fold(h : UInt64, n : MNode) : UInt64
  h = fnv_s(h, n.label)
  n.table.each { |key, value| h = fnv_i(fnv_s(h, key), value.to_u64) }
  n.notes.each { |note| h = fnv_s(h, note) }
  h = fnv_i(h, n.items.size.to_u64)
  n.items.each { |child| h = fold(h, child) }
  h
end

# The joiner's turn at an adopted graph: mutate it, then fold it.
def fold_joined(x : MNode, seed : UInt64) : UInt64
  mutate_m(x, label_of(seed, 2), seed)
  fold(FNV_BASIS, x)
end

def fold_joined(x : Panicked, seed : UInt64) : UInt64
  BAD
end

# A Share copy of a mutable graph, sharing its strings.
def mirror(n : MNode, depth : Int32) : SNode
  kids = [] of SNode
  n.items.each { |child| kids << mirror(child, depth - 1) } if depth > 0
  SNode.new(n.label, n.items.size.to_i64, List.new(kids),
    SPair.new(n.notes.size > 0 ? n.notes[0] : "none", n.table.size.to_i64), n.table.size.to_i64, nil)
end

# ── Lists for row 21 ───────────────────────────────────────────────────────

def list_share(seed : UInt64, size : Int32) : List(SNode)
  items = [] of SNode
  i = 0
  while i < size * 3 + 1
    items << build_s(mix(seed &+ i.to_u64), 2)
    i += 1
  end
  List.new(items)
end

def list_mutable(seed : UInt64, size : Int32) : List(String)
  m = build_m(seed, size)
  mutate_m(m, label_of(seed, 3), seed)
  items = [] of String
  m.items.each { |child| items << child.label }
  m.notes.each { |note| items << note }
  List.new(items)
end

def list_appended(seed : UInt64, size : Int32) : List(String)
  list = List.new([] of String)
  i = 0
  while i < size * 5 + 1
    q = mix(seed &+ i.to_u64)
    list = list.appended(label_of(q, len_of(q >> 4, size)))
    i += 1
  end
  list
end

def list_concat(seed : UInt64, size : Int32) : List(SNode)
  list = List.new([build_s(seed, 1)])
  i = 0
  while i < size + 1
    list = list.concatenated(list_share(mix(seed &+ i.to_u64), 1))
    i += 1
  end
  list
end

# ── Mutex contents: operations whose order does not change the fold ────────

def init_arr(first : String, seed : UInt64) : Array(String)
  [first, label_of(seed, 3)]
end

def op_lock(held : Array(String), s : String, seed : UInt64) : Nil
  held << s
  held << label_of(seed, len_of(seed >> 3, 2))
end

def op_update(held : Array(String), s : String, seed : UInt64) : Array(String)
  fresh = held.dup
  fresh << s + "!" + label_of(seed, 1)
  fresh
end

def peek(held : Array(String)) : Int32
  held.size
end

def bag(v : Array(String)) : UInt64
  h = fnv_i(FNV_BASIS, v.size.to_u64)
  v.each { |s| h = h &+ fnv_s(FNV_BASIS, s) }
  h
end

def init_hash(first : String, seed : UInt64) : Hash(String, Int64)
  table = {} of String => Int64
  table[first] = 1_i64
  table[label_of(seed, 2)] = (seed % 1000_u64).to_i64
  table
end

def op_lock(held : Hash(String, Int64), s : String, seed : UInt64) : Nil
  key = label_of(seed % 5_u64, 1)
  held[key] = held.fetch(key, 0_i64) &+ (seed % 1000_u64).to_i64
  held[s] = held.fetch(s, 0_i64) &+ 1_i64
end

def op_update(held : Hash(String, Int64), s : String, seed : UInt64) : Hash(String, Int64)
  fresh = held.dup
  key = label_of(seed % 3_u64, 2)
  fresh[key] = fresh.fetch(key, 0_i64) &+ 7_i64
  fresh
end

def peek(held : Hash(String, Int64)) : Int32
  held.size
end

def bag(v : Hash(String, Int64)) : UInt64
  h = fnv_i(FNV_BASIS, v.size.to_u64)
  v.each { |key, value| h = h &+ fnv_i(fnv_s(FNV_BASIS, key), value.to_u64) }
  h
end

def init_mnode(first : String, seed : UInt64) : MNode
  m = build_m(seed, 1)
  m.notes << first
  m
end

def op_lock(held : MNode, s : String, seed : UInt64) : Nil
  child = build_m(seed, 1)
  child.label = s
  child.up = held
  held.items << child
  held.notes << label_of(seed, 2)
  held.table[s] = held.table.fetch(s, 0_i64) &+ 1_i64
end

def op_update(held : MNode, s : String, seed : UInt64) : MNode
  child = MNode.new(s + "?" + label_of(seed, 1))
  child.up = held
  held.items << child
  held
end

def peek(held : MNode) : Int32
  held.items.size
end

def bag(v : MNode) : UInt64
  h = fnv_i(FNV_BASIS, v.items.size.to_u64)
  v.items.each { |child| h = h &+ fold(FNV_BASIS, child) }
  h = h &+ bag(v.notes)
  h &+ bag(v.table)
end

# ── Garbage between steps ──────────────────────────────────────────────────

@[NoInline]
def churn(seed : UInt64, n : Int32) : Nil
  i = 0
  while i < n
    r = mix(seed &+ i.to_u64)
    k = r % 6_u64
    if k == 0_u64
      label_of(r, (r % 300_u64).to_i32)
    elsif k == 1_u64
      Array(UInt64).new(((r >> 8) % 100_u64).to_i32 + 1, r)
    elsif k == 2_u64
      build_m(r, 1)
    elsif k == 3_u64
      build_s(r, 2)
    elsif k == 4_u64
      make_strs(r, 1)
    else
      label_of(r, 2000 + ((r >> 4) % 20000_u64).to_i32)
    end
    i += 1
  end
end

def report(total : UInt64, index : Int32, desc : String, r : {UInt64, UInt64}) : UInt64
  if r[0] == r[1]
    print "step #{index} #{desc}: #{r[0]} ok\n"
  else
    print "step #{index} #{desc}: #{r[0]} MISMATCH, rebuilt #{r[1]}\n"
  end
  fnv_i(total, r[0])
end

def report(total : UInt64, index : Int32, desc : String, r : Panicked) : UInt64
  print "step #{index} #{desc}: PANICKED #{r.message}\n"
  fnv_i(total, BAD)
end
'''

# ── The generator ───────────────────────────────────────────────────────────

# Share value kinds: the type, and the def that makes one from (seed, size).
KINDS = {
    "node": ("SNode", "make_node"),
    "nodes": ("List(SNode)", "make_nodes"),
    "strs": ("List(String)", "make_strs"),
    "deep": ("List(List(String))", "make_deep"),
    "tuple": ("{String, Int64, SNode}", "make_tuple"),
    "pair": ("SPair", "make_pair"),
    "str": ("String", "make_str"),
    "shape": ("SShape", "make_shape"),
}

# Step kinds and the design rows each drives.
STEPS = {
    "capture": "1",
    "thread": "1c",
    "spawn_in": "1d, 4",
    "answer": "2",
    "unit_answer": "2b, 4",
    "channel": "3",
    "mutex": "4b",
    "panic": "7",
    "shared_proc": "8",
    "pin": "9",
    "env": "13",
    "list": "21",
}

MUTEX_TYPES = {
    "arr": ("Array(String)", "init_arr"),
    "hash": ("Hash(String, Int64)", "init_hash"),
    "mnode": ("MNode", "init_mnode"),
}

LISTS = {
    "share": ("List(SNode)", "list_share"),
    "mutable": ("List(String)", "list_mutable"),
    "appended": ("List(String)", "list_appended"),
    "concat": ("List(SNode)", "list_concat"),
}


def indent(lines, n):
    pad = "  " * n
    return [pad + line if line else line for line in lines]


class Gen:
    def __init__(self, seed, only=None):
        self.seed = seed
        self.only = only
        self.r = random.Random(seed)
        self.defs = []

    # Random pieces.
    def lit(self):
        return f"0x{self.r.getrandbits(48):x}_u64"

    def size(self):
        return self.r.choice([1, 1, 2, 2, 3, 4, 5])

    def kind(self, allowed=None):
        return self.r.choice(sorted(allowed or KINDS))

    def churn(self, most=10):
        n = self.r.randint(0, most)
        return [f"churn({self.lit()}, {n})"] if n else []

    def park(self):
        x = self.r.random()
        if x < 0.35:
            return ["sleep(0)"]
        if x < 0.45:
            return ["sleep(1)"]
        return []

    def spawn_how(self):
        return self.r.choice(["g.spawn(unit: :new) do", "g.spawn(unit: :new) do", "g.spawn do"])

    def add(self, text):
        self.defs.append(text)

    # Each step writes its defs and answers (desc, the name of a def that
    # answers {got, want}).
    def step_capture(self, k):
        caps_per = []
        launch_calls = []
        local_task = self.r.random() < 0.3
        for j in range(self.r.randint(1, 3)):
            caps = [(self.kind(), self.lit(), self.size()) for _ in range(self.r.randint(1, 3))]
            caps_per.append(caps)
            how = self.spawn_how()
            body = [f"c{i} = {KINDS[kd][1]}({s}, {z})" for i, (kd, s, z) in enumerate(caps)]
            fold = "FNV_BASIS"
            for i in range(len(caps)):
                fold = f"fold({fold}, c{i})"
            inner = self.park() + self.churn() + [fold]
            self.add("\n".join(
                ["@[NoInline]", f"def step_{k}_launch_{j}(g : IyiGroup) : IyiTask(UInt64)"]
                + indent(body + [how] + indent(inner, 1) + ["end"], 1) + ["end"]))
            launch_calls.append(how.split(" do")[0].replace("g.", ""))
        lines = ["got = 0_u64", "want = 0_u64", "group do |g|"]
        tasks = [f"t{j} = step_{k}_launch_{j}(g)" for j in range(len(caps_per))]
        body = tasks
        if local_task:
            # A plain spawn that captures a non-Share array: it may not
            # cross, so it stays in the spawner's unit.
            ls = self.lit()
            body += [f"local = [label_of({ls}, 3)]", "tl = g.spawn do",
                     f"  local << label_of({ls} &+ 1_u64, 2)", "  bag(local)", "end"]
        body += self.churn() + self.park()
        body += [f"got = got &+ num(t{j}.value)" for j in range(len(caps_per))]
        if local_task:
            body += ["got = got &+ num(tl.value)"]
        lines += indent(body, 1) + ["end"]
        for caps in caps_per:
            fold = "FNV_BASIS"
            for kd, s, z in caps:
                fold = f"fold({fold}, {KINDS[kd][1]}({s}, {z}))"
            lines.append(f"want = want &+ {fold}")
        if local_task:
            lines.append(f"want = want &+ bag([label_of({ls}, 3), label_of({ls} &+ 1_u64, 2)])")
        lines.append("{got, want}")
        self.add_step(k, lines)
        hows = ",".join(sorted(set(launch_calls)))
        caps = "+".join(kd for caps in caps_per for kd, _, _ in caps)
        return f"capture tasks={len(caps_per)} via={hows} caps={caps}" + (" local=plain" if local_task else "")

    def step_thread(self, k):
        n = self.r.randint(1, 2)
        want = []
        for j in range(n):
            kd, s, z = self.kind(), self.lit(), self.size()
            self.add("\n".join(
                ["@[NoInline]", f"def step_{k}_launch_{j}(results : Channel(UInt64)) : IyiThread"]
                + indent([f"c = {KINDS[kd][1]}({s}, {z})", "IyiThread.start do"]
                         + indent(self.park() + self.churn() + ["results.send(fold(FNV_BASIS, c))", "nil"], 1)
                         + ["end"], 1) + ["end"]))
            want.append(f"want = want &+ fold(FNV_BASIS, {KINDS[kd][1]}({s}, {z}))")
        lines = ["got = 0_u64", "want = 0_u64", f"results = Channel(UInt64).new({n})"]
        lines += [f"th{j} = step_{k}_launch_{j}(results)" for j in range(n)]
        lines += self.churn()
        lines += [f"got = got &+ num(results.receive)" for j in range(n)]
        lines += [f"th{j}.join" for j in range(n)]
        lines += want + ["{got, want}"]
        self.add_step(k, lines)
        return f"thread threads={n}"

    def step_spawn_in(self, k):
        su, zu = self.lit(), self.size()
        made = self.r.choice(["here", "here", "child"])
        extra_seed, extra_size = self.lit(), self.size()
        ops = []
        for j in range(self.r.randint(2, 5)):
            kd, sv, zv, sm = self.kind(), self.lit(), self.size(), self.lit()
            site = self.r.choice(["here", "child"])
            ops.append((kd, sv, zv, sm, site))
            self.add("\n".join(
                ["@[NoInline]", f"def step_{k}_in_{j}(g : IyiGroup, u : Unit(MNode)) : IyiTask(UInt64)"]
                + indent([f"v = {KINDS[kd][1]}({sv}, {zv})", "g.spawn(in: u) do |value|"]
                         + indent([f"mutate_m(value, pick(v), {sm})"] + self.churn(6)
                                  + ["fold(fold(FNV_BASIS, v), value)"], 1)
                         + ["end"], 1) + ["end"]))
        lines = ["got = 0_u64"]
        if made == "here":
            lines += [f"first = make_str({extra_seed}, {extra_size})",
                      f"u = Unit.new {{ unit_init({su}, {zu}, first) }}"]
        else:
            self.add("\n".join(
                ["@[NoInline]", f"def step_{k}_unit(g : IyiGroup) : IyiTask(Unit(MNode))"]
                + indent(["g.spawn(unit: :new) do"]
                         + indent([f"first = make_str({extra_seed}, {extra_size})"] + self.churn(4)
                                  + [f"Unit.new {{ unit_init({su}, {zu}, first) }}"], 1)
                         + ["end"], 1) + ["end"]))
            lines += ["um = Unit.new { MNode.new(\"lost\") }", "group do |g|",
                      f"  x = step_{k}_unit(g).value", "  um = x unless x.is_a?(Panicked)", "end",
                      "u = um"]
        body = []
        for j, (kd, sv, zv, sm, site) in enumerate(ops):
            if site == "here":
                body.append(f"got = got &+ num(step_{k}_in_{j}(g, u).value)")
            else:
                body += [f"tc{j} = g.spawn(unit: :new) do", "  acc = BAD", "  group do |g2|",
                         f"    acc = num(step_{k}_in_{j}(g2, u).value)", "  end", "  acc", "end",
                         f"got = got &+ num(tc{j}.value)"]
            body += self.churn(4)
        body.append("got = got &+ num(g.spawn(in: u) { |value| fold(FNV_BASIS, value) }.value)")
        lines += ["group do |g|"] + indent(body, 1) + ["end"]
        lines += [f"sim = unit_init({su}, {zu}, make_str({extra_seed}, {extra_size}))", "want = 0_u64"]
        for j, (kd, sv, zv, sm, site) in enumerate(ops):
            lines += [f"v{j} = {KINDS[kd][1]}({sv}, {zv})", f"mutate_m(sim, pick(v{j}), {sm})",
                      f"want = want &+ fold(fold(FNV_BASIS, v{j}), sim)"]
        lines += ["want = want &+ fold(FNV_BASIS, sim)", "{got, want}"]
        self.add_step(k, lines)
        sites = ",".join(sorted({op[4] for op in ops}))
        return f"spawn_in unit={made} ops={len(ops)} from={sites}"

    def step_unit_answer(self, k):
        su, zu = self.lit(), self.size()
        ops = []
        for j in range(self.r.randint(1, 4)):
            ops.append((self.r.choice(["notes", "mirror", "make"]), self.lit(), self.kind(), self.lit(), self.size()))
        lines = ["got = 0_u64", f"u = Unit.new {{ unit_init({su}, {zu}, \"in\") }}", "group do |g|"]
        body = []
        for j, (how, sm, kd, sv, zv) in enumerate(ops):
            if how == "notes":
                answer = "List.new(value.notes)"
            elif how == "mirror":
                answer = "mirror(value, 2)"
            else:
                answer = f"{KINDS[kd][1]}({sv}, {zv})"
            body += [f"r{j} = g.spawn(in: u) do |value|", f"  mutate_m(value, label_of({sm}, 2), {sm})"]
            body += indent(self.churn(4), 1) + [f"  {answer}", "end.value"]
            body += self.churn(4) + [f"got = got &+ fold(FNV_BASIS, r{j})"]
        lines += indent(body, 1) + ["end", f"sim = unit_init({su}, {zu}, \"in\")", "want = 0_u64"]
        for j, (how, sm, kd, sv, zv) in enumerate(ops):
            lines.append(f"mutate_m(sim, label_of({sm}, 2), {sm})")
            if how == "notes":
                lines.append("want = want &+ fold(FNV_BASIS, List.new(sim.notes))")
            elif how == "mirror":
                lines.append("want = want &+ fold(FNV_BASIS, mirror(sim, 2))")
            else:
                lines.append(f"want = want &+ fold(FNV_BASIS, {KINDS[kd][1]}({sv}, {zv}))")
        lines.append("{got, want}")
        self.add_step(k, lines)
        return "unit_answer answers=" + ",".join(op[0] for op in ops)

    def step_answer(self, k):
        n = self.r.randint(1, 3)
        lines = ["got = 0_u64", "want = 0_u64", "group do |g|"]
        body, want, descs = [], [], []
        for j in range(n):
            mutable = self.r.random() < 0.4
            relay = self.r.random() < 0.35
            s, z, sj = self.lit(), self.size(), self.lit()
            if mutable:
                typ = "MNode"
                sm = self.lit()
                make = [f"m = build_m({s}, {z})", f"mutate_m(m, label_of({sm}, 2), {sm})"]
                value = "m"
                fallback = "MNode.new(\"lost\")"
                want.append(f"w{j} = build_m({s}, {z})")
                want.append(f"mutate_m(w{j}, label_of({sm}, 2), {sm})")
                want.append(f"want = want &+ fold_joined(w{j}, {sj})")
            else:
                kd = self.kind()
                typ = KINDS[kd][0]
                make = []
                value = f"{KINDS[kd][1]}({s}, {z})"
                fallback = f"{KINDS[kd][1]}(0_u64, 1)"
                want.append(f"want = want &+ fold(FNV_BASIS, {value})")
            how = "g.spawn(unit: :new) do" if relay else self.spawn_how()
            if relay:
                inner = ["kept = " + fallback, "group do |g2|",
                         "  x = g2.spawn(unit: :new) do"] + indent(self.churn(6) + make + [value], 2) + [
                    "  end.value", "  kept = x unless x.is_a?(Panicked)", "end"]
                if mutable:
                    inner += [f"mutate_m(kept, label_of({sj} &+ 1_u64, 1), {sj} &+ 1_u64)"]
                    want.insert(-1, f"mutate_m(w{j}, label_of({sj} &+ 1_u64, 1), {sj} &+ 1_u64)")
                inner += self.churn(4) + ["kept"]
            else:
                inner = self.churn(6) + make + [value]
            self.add("\n".join(
                ["@[NoInline]", f"def step_{k}_launch_{j}(g : IyiGroup) : IyiTask({typ})"]
                + indent([how] + indent(inner, 1) + ["end"], 1) + ["end"]))
            body.append(f"t{j} = step_{k}_launch_{j}(g)")
            descs.append(("mutable" if mutable else kd) + ("/relay" if relay else "")
                         + ("/plain" if how == "g.spawn do" else ""))
            if mutable:
                tail = [f"got = got &+ fold_joined(t{j}.value, {sj})"]
            else:
                tail = [f"got = got &+ fold(FNV_BASIS, t{j}.value)"]
            body.extend(self.r.choice([[], ["sleep(2)"]]))
            body.extend(tail)
            body.extend(self.churn(4))
        lines += indent(body, 1) + ["end"] + want + ["{got, want}"]
        self.add_step(k, lines)
        return "answer " + ",".join(descs)

    def step_channel(self, k):
        kd = self.kind()
        typ, make = KINDS[kd]
        cap = self.r.choice([0, 0, 1, 1, 2, 3])
        senders = []
        for j in range(self.r.randint(1, 3)):
            count = self.r.randint(1, 7)
            mode = self.r.choice(["send", "select", "mixed"])
            s, z = self.lit(), self.size()
            senders.append((count, s, z, mode))
            send = ["box.send(v)"]
            select = ["select", "when box.send(v)", "  nil", "end"]
            if mode == "send":
                op = send
            elif mode == "select":
                op = select
            else:
                op = ["if i % 2 == 0"] + indent(select, 1) + ["else"] + indent(send, 1) + ["end"]
            loop = [f"v = {make}(mix({s} &+ i.to_u64), {z})"] + op + self.churn(4)
            if self.r.random() < 0.4:
                loop += ["sleep(0) if i % 3 == 1"]
            loop += ["i += 1"]
            self.add("\n".join(
                ["@[NoInline]", f"def step_{k}_send_{j}(box : Channel({typ})) : Nil"]
                + indent(["i = 0", f"while i < {count}"] + indent(loop, 1) + ["end"], 1) + ["end"]))
        total = sum(c for c, _, _, _ in senders)
        nrecv = self.r.randint(1, min(3, total))
        counts = [total // nrecv + (1 if i < total % nrecv else 0) for i in range(nrecv)]
        rchurn = self.r.randint(0, 3)
        self.add("\n".join(
            ["@[NoInline]", f"def step_{k}_recv(box : Channel({typ}), count : Int32, seed : UInt64) : UInt64"]
            + indent(["acc = 0_u64", "i = 0", "while i < count"]
                     + indent(["acc = acc &+ fold(FNV_BASIS, box.receive)"]
                              + ([f"churn(mix(seed &+ i.to_u64), {rchurn})"] if rchurn else []) + ["i += 1"], 1)
                     + ["end", "acc"], 1) + ["end"]))
        same = nrecv > 1 and self.r.random() < 0.5
        sender_here = self.r.random() < 0.3
        ctor = f"Channel({typ}).new" if cap == 0 and self.r.random() < 0.5 else f"Channel({typ}).new({cap})"
        lines = [f"box = {ctor}", "got = 0_u64", "group do |g|"]
        body = []
        if same:
            body += ["rr = g.spawn(unit: :new) do", "  acc = 0_u64", "  group do |g2|"]
            for i, c in enumerate(counts):
                body.append(f"    a{i} = g2.spawn(unit: :same) {{ step_{k}_recv(box, {c}, {self.lit()}) }}")
            for i in range(len(counts)):
                body.append(f"    acc = acc &+ num(a{i}.value)")
            body += ["  end", "  acc", "end"]
        else:
            for i, c in enumerate(counts):
                body.append(f"r{i} = g.spawn(unit: :new) {{ step_{k}_recv(box, {c}, {self.lit()}) }}")
        for j in range(len(senders)):
            if sender_here and j == len(senders) - 1:
                continue
            delay = self.r.choice([[], [], ["sleep(1)"], ["sleep(5)"]])
            body += [f"s{j} = g.spawn(unit: :new) do"] + indent(delay + [f"step_{k}_send_{j}(box)", "0_u64"], 1) + ["end"]
        if sender_here:
            body.append(f"step_{k}_send_{len(senders) - 1}(box)")
        if same:
            body.append("got = got &+ num(rr.value)")
        else:
            body += [f"got = got &+ num(r{i}.value)" for i in range(len(counts))]
        lines += indent(body, 1) + ["end", "want = 0_u64"]
        for j, (count, s, z, mode) in enumerate(senders):
            lines += ["i = 0", f"while i < {count}",
                      f"  want = want &+ fold(FNV_BASIS, {make}(mix({s} &+ i.to_u64), {z}))", "  i += 1", "end"]
        lines.append("{got, want}")
        self.add_step(k, lines)
        modes = ",".join(m for _, _, _, m in senders)
        return (f"channel {kd} cap={cap} values={total} senders={len(senders)}({modes})"
                + (" +here" if sender_here else "") + f" receivers={nrecv}" + ("/same" if same else ""))

    def step_mutex(self, k):
        mt = self.r.choice(sorted(MUTEX_TYPES))
        typ, init = MUTEX_TYPES[mt]
        sf, zf, si = self.lit(), self.size(), self.lit()
        made = self.r.choice(["here", "answer", "channel"])
        self.add("\n".join(
            ["@[NoInline]", f"def step_{k}_mutex : Mutex({typ})"]
            + indent([f"first = make_str({sf}, {zf})", f"Mutex.new {{ {init}(first, {si}) }}"], 1) + ["end"]))
        workers = []
        for j in range(self.r.randint(1, 3)):
            kd, sv, zv = self.kind(), self.lit(), self.size()
            ops = [(self.r.choice(["lock", "lock", "update", "get"]), self.lit()) for _ in range(self.r.randint(1, 4))]
            workers.append((kd, sv, zv, ops, self.r.choice(["unit", "unit", "plain", "here"])))
            body = [f"v = {KINDS[kd][1]}({sv}, {zv})"]
            for op, so in ops:
                if op == "lock":
                    body.append(f"m.lock {{ |held| op_lock(held, pick(v), {so}) }}")
                elif op == "update":
                    body.append(f"m.update {{ |held| op_update(held, pick(v), {so}) }}")
                else:
                    body.append("m.get { |held| peek(held) }")
                body += self.park() + self.churn(4)
            self.add("\n".join(["@[NoInline]", f"def step_{k}_work_{j}(m : Mutex({typ})) : Nil"]
                               + indent(body, 1) + ["end"]))
        lines = ["got = 0_u64"]
        lost = f"Mutex.new {{ {init}(\"lost\", 0_u64) }}"
        if made == "here":
            lines.append(f"m = step_{k}_mutex")
        elif made == "answer":
            lines += ["mt = Mutex.new { " + init + "(\"unset\", 0_u64) }", "group do |g|",
                      "  t = g.spawn(unit: :new) do"] + indent(self.churn(4) + [f"step_{k}_mutex"], 2) + [
                "  end.value", "  mt = t unless t.is_a?(Panicked)", "end", "m = mt"]
        else:
            lines += [f"mc = Channel(Mutex({typ})).new(1)", "group do |g|",
                      "  g.spawn(unit: :new) do"] + indent([f"mc.send(step_{k}_mutex)"] + self.churn(4) + ["0_u64"], 2) + [
                "  end", "end", "mr = mc.receive", f"m = mr.is_a?(Mutex({typ})) ? mr : {lost}"]
        body = []
        for j, (kd, sv, zv, ops, site) in enumerate(workers):
            if site == "unit":
                body += [f"w{j} = g.spawn(unit: :new) do", f"  step_{k}_work_{j}(m)", "  0_u64", "end"]
            elif site == "plain":
                body += [f"w{j} = g.spawn do", f"  step_{k}_work_{j}(m)", "  0_u64", "end"]
        for j, (kd, sv, zv, ops, site) in enumerate(workers):
            if site == "here":
                body.append(f"step_{k}_work_{j}(m)")
        for j, (kd, sv, zv, ops, site) in enumerate(workers):
            if site != "here":
                body.append(f"w{j}.value")
        lines += ["group do |g|"] + indent(body, 1) + ["end", "got = num(m.get { |held| bag(held) })"]
        lines.append(f"sim = {init}(make_str({sf}, {zf}), {si})")
        for j, (kd, sv, zv, ops, site) in enumerate(workers):
            lines.append(f"v{j} = {KINDS[kd][1]}({sv}, {zv})")
            for op, so in ops:
                if op == "lock":
                    lines.append(f"op_lock(sim, pick(v{j}), {so})")
                elif op == "update":
                    lines.append(f"sim = op_update(sim, pick(v{j}), {so})")
        lines.append("{got, bag(sim)}")
        self.add_step(k, lines)
        sites = ",".join(w[4] for w in workers)
        ops = "+".join(o for w in workers for o, _ in w[3])
        return f"mutex {mt} made={made} workers={sites} ops={ops}"

    def step_panic(self, k):
        kd, s, z, sp = self.kind(), self.lit(), self.size(), self.lit()
        relay = self.r.random() < 0.4
        self.add("\n".join(
            ["@[NoInline]", f"def step_{k}_launch(g : IyiGroup) : IyiTask(UInt64)"]
            + indent(["g.spawn(unit: :new) do"]
                     + indent([f"v = {KINDS[kd][1]}({s}, {z})"] + self.churn(6)
                              + [f"raise panic_text(pick(v), {sp})", "0_u64"], 1)
                     + ["end"], 1) + ["end"]))
        lines = ["got = 0_u64", "group do |g|"]
        if relay:
            lines += ["  t = g.spawn(unit: :new) do", "    kept = \"none\"", "    group do |g2|",
                      f"      kept = message_of(step_{k}_launch(g2).value)", "    end"] + indent(self.churn(4), 2) + [
                "    kept", "  end", "  got = fnv_s(FNV_BASIS, string_or(t.value))"]
        else:
            lines += [f"  t = step_{k}_launch(g)"] + indent(self.r.choice([[], ["sleep(2)"]]) + self.churn(4), 1) + [
                "  got = msg(t.value)"]
        lines += ["end", f"{{got, fnv_s(FNV_BASIS, panic_text(pick({KINDS[kd][1]}({s}, {z})), {sp}))}}"]
        self.add_step(k, lines)
        return f"panic {kd}" + ("/relay" if relay else "")

    def step_shared_proc(self, k):
        caps = [(self.kind(), self.lit(), self.size()) for _ in range(self.r.randint(1, 2))]
        body = [f"c{i} = {KINDS[kd][1]}({s}, {z})" for i, (kd, s, z) in enumerate(caps)]
        fold = "FNV_BASIS"
        for i in range(len(caps)):
            fold = f"fold({fold}, c{i})"
        self.add("\n".join(
            ["@[NoInline]", f"def step_{k}_proc : SharedProc(Int64, UInt64)"]
            + indent(body + ["SharedProc(Int64, UInt64).of do |n|", f"  fnv_s({fold}, pick(c0) + n.to_s)", "end"], 1)
            + ["end"]))
        how = self.r.choice(["channel", "answer"])
        typ = "SharedProc(Int64, UInt64)"
        lost = f"{typ}.of {{ |n| BAD }}"
        lines = ["got = 0_u64"]
        if how == "channel":
            lines += [f"pc = Channel({typ}).new({self.r.choice([0, 1])})", "pm = " + lost, "group do |g|",
                      "  g.spawn(unit: :new) do"] + indent([f"pc.send(step_{k}_proc)"] + self.churn(4) + ["0_u64"], 2) + [
                "  end", "  x = pc.receive", f"  pm = x if x.is_a?({typ})", "end", "sp = pm"]
        else:
            lines += ["pm = " + lost, "group do |g|", "  t = g.spawn(unit: :new) do"] + indent(
                self.churn(4) + [f"step_{k}_proc"], 2) + ["  end.value", "  pm = t unless t.is_a?(Panicked)", "end", "sp = pm"]
        consumers = [(self.r.randint(1, 5), self.r.randint(0, 50)) for _ in range(self.r.randint(1, 3))]
        body = []
        for j, (calls, base) in enumerate(consumers):
            body += [f"c{j} = g.spawn(unit: :new) do", "  acc = 0_u64", "  i = 0", f"  while i < {calls}",
                     f"    acc = acc &+ sp.call(i.to_i64 + {base}_i64)"] + indent(self.churn(2), 2) + [
                "    i += 1", "  end", "  acc", "end"]
        body += [f"got = got &+ num(c{j}.value)" for j in range(len(consumers))]
        lines += ["group do |g|"] + indent(body, 1) + ["end", f"q = step_{k}_proc", "want = 0_u64"]
        for calls, base in consumers:
            lines += [f"i = 0", f"while i < {calls}", f"  want = want &+ q.call(i.to_i64 + {base}_i64)", "  i += 1", "end"]
        lines.append("{got, want}")
        self.add_step(k, lines)
        return f"shared_proc {how} caps={'+'.join(c[0] for c in caps)} consumers={len(consumers)}"

    def step_pin(self, k):
        how = self.r.choice(["box", "box", "malloc"])
        kd = self.kind() if how == "box" else "node"
        s, z = self.lit(), self.size()
        typ, make = KINDS[kd]
        self.add("\n".join([f"class Stash{k}", "  @@slot = 0_u64", "", "  def self.put(address : UInt64) : Nil",
                            "    @@slot = address", "  end", "", "  def self.take : UInt64", "    @@slot", "  end", "end"]))
        if how == "box":
            stash = [f"Stash{k}.put(Box.box({make}({s}, {z})).address)"]
            read = f"fold(FNV_BASIS, Box({typ}).unbox(Pointer(Void).new(Stash{k}.take)))"
        else:
            stash = ["raw = GC.malloc(16).as(Pointer(UInt64))", f"raw.value = {make}({s}, {z}).object_id",
                     f"Stash{k}.put(raw.address)"]
            read = f"fold(FNV_BASIS, Pointer(Void).new(Pointer(UInt64).new(Stash{k}.take).value).as({typ}))"
        self.add("\n".join(["@[NoInline]", f"def step_{k}_stash : Nil"] + indent(stash, 1) + ["end"]))
        self.add("\n".join([f"def step_{k}_read : UInt64", f"  {read}", "end"]))
        reader = self.r.choice(["here", "unit"])
        lines = ["group do |g|", "  g.spawn(unit: :new) do"] + indent([f"step_{k}_stash"] + self.churn(6) + ["0_u64"], 2) + [
            "  end", "end"]
        lines += self.churn(4)
        if reader == "here":
            lines.append(f"got = step_{k}_read")
        else:
            lines += ["got = 0_u64", "group do |g|", "  t = g.spawn(unit: :new) do"] + indent(
                self.churn(4) + [f"step_{k}_read"], 2) + ["  end", "  got = num(t.value)", "end"]
        lines.append(f"{{got, fold(FNV_BASIS, {make}({s}, {z}))}}")
        self.add_step(k, lines)
        return f"pin {how} {kd} read={reader}"

    def step_env(self, k):
        name = f"IYI_H22FUZZ_{self.seed}_{k}"
        s1, s2, s3, z = self.lit(), self.lit(), self.lit(), self.size()
        self.add("\n".join(
            ["@[NoInline]", f"def step_{k}_set : Nil"]
            + indent([f"ENV[\"{name}\"] = make_str({s1}, {z})"] + self.churn(4)
                     + [f"ENV[\"{name}\"] = make_str({s2}, {z})", f"ENV[\"{name}_B\"] = label_of({s3}, 2)"], 1)
            + ["end"]))
        self.add("\n".join([f"def step_{k}_get : UInt64",
                            f"  fnv_s(fnv_s(FNV_BASIS, ENV[\"{name}\"]? || \"unset\"), ENV[\"{name}_B\"]? || \"unset\")",
                            "end"]))
        reader = self.r.choice(["here", "unit"])
        lines = ["group do |g|", "  g.spawn(unit: :new) do"] + indent([f"step_{k}_set"] + self.churn(4) + ["0_u64"], 2) + [
            "  end", "end"]
        if reader == "here":
            lines.append(f"got = step_{k}_get")
        else:
            lines += ["got = 0_u64", "group do |g|", f"  got = num(g.spawn(unit: :new) {{ step_{k}_get }}.value)", "end"]
        lines.append(f"{{got, fnv_s(fnv_s(FNV_BASIS, make_str({s2}, {z})), label_of({s3}, 2))}}")
        self.add_step(k, lines)
        return f"env read={reader}"

    def step_list(self, k):
        src = self.r.choice(sorted(LISTS))
        typ, make = LISTS[src]
        s, z = self.lit(), self.size()
        how = self.r.choice(["channel", "answer", "capture"])
        lines = ["got = 0_u64", "group do |g|"]
        if how == "channel":
            body = [f"box = Channel({typ}).new({self.r.choice([0, 1])})",
                    "g.spawn(unit: :new) do"] + indent([f"box.send({make}({s}, {z}))"] + self.churn(6) + ["0_u64"], 1) + [
                "end", "t = g.spawn(unit: :new) do"] + indent(self.churn(4) + ["fold(FNV_BASIS, box.receive)"], 1) + ["end",
                                                                                                                      "got = num(t.value)"]
        elif how == "answer":
            body = ["t = g.spawn(unit: :new) do"] + indent(self.churn(4) + [f"{make}({s}, {z})"], 1) + ["end"] + self.churn(4) + [
                "got = fold(FNV_BASIS, t.value)"]
        else:
            self.add("\n".join(
                ["@[NoInline]", f"def step_{k}_launch(g : IyiGroup) : IyiTask(UInt64)"]
                + indent([f"l = {make}({s}, {z})", "g.spawn(unit: :new) do"] + indent(self.park() + self.churn(4) + [
                    "fold(FNV_BASIS, l)"], 1) + ["end"], 1) + ["end"]))
            body = [f"t = step_{k}_launch(g)"] + self.churn(4) + ["got = num(t.value)"]
        lines += indent(body, 1) + ["end", f"{{got, fold(FNV_BASIS, {make}({s}, {z}))}}"]
        # The list made in a unit of its own, so its elements are born in a partition.
        self.add_step(k, lines)
        return f"list {src} via={how}"

    def add_step(self, k, lines):
        self.add("\n".join([f"def step_{k} : {{UInt64, UInt64}}"] + indent(lines, 1) + ["end"]))

    def program(self):
        if self.only:
            kinds = list(self.only)
        else:
            kinds = list(STEPS)
            self.r.shuffle(kinds)
            kinds += [self.r.choice(list(STEPS)) for _ in range(self.r.randint(0, 4))]
        descs = []
        for k, kind in enumerate(kinds, 1):
            descs.append(getattr(self, "step_" + kind)(k))
        depths = [self.r.choice([0, 1, 1, 2]) for _ in kinds]
        for k, d in enumerate(depths, 1):
            if d == 2:
                self.add("\n".join([f"def nest_{k} : {{UInt64, UInt64}}", "  kept = {BAD, 0_u64}", "  group do |g|",
                                    f"    kept = pair_of(g.spawn(unit: :new) {{ step_{k} }}.value)", "  end", "  kept",
                                    "end"]))
        main = [f"total = FNV_BASIS", f"print \"heap_verify_fuzz program {self.seed}: {len(kinds)} steps\\n\""]
        k = 1
        while k <= len(kinds):
            batch = list(range(k, min(len(kinds), k + self.r.randint(0, 2)) + 1))
            k = batch[-1] + 1
            body = []
            for i in batch:
                if depths[i - 1] == 1:
                    body.append(f"t{i} = g.spawn(unit: :new) {{ step_{i} }}")
                elif depths[i - 1] == 2:
                    body.append(f"t{i} = g.spawn(unit: :new) {{ nest_{i} }}")
            for i in batch:
                if depths[i - 1] == 0:
                    body.append(f"v{i} = step_{i}")
            for i in batch:
                if depths[i - 1] != 0:
                    body.append(f"v{i} = t{i}.value")
            for i in batch:
                where = ["main", "unit", "unit/unit"][depths[i - 1]]
                body.append(f"total = report(total, {i}, \"{descs[i - 1]} [{where}]\", v{i})")
            main += ["group do |g|"] + indent(body, 1) + ["end"] + self.churn(8)
        main.append(f"print \"heap_verify_fuzz program {self.seed}: transcript #{{total}}\\n\"")
        head = [f"# heap_verify_fuzz program {self.seed}, made by",
                f"#   python3 bench/heap_verify_fuzz.py gen --seed {self.seed}"
                + (f" --only {','.join(self.only)}" if self.only else "") + " --out DIR",
                "# Steps (heap22 design §2.1 rows):"]
        head += [f"#   {i}. {kinds[i - 1]} (row {STEPS[kinds[i - 1]]}): {d}" for i, d in enumerate(descs, 1)]
        return "\n".join(head) + "\n" + SUPPORT + "\n" + "\n\n".join(self.defs) + "\n\n" + "\n".join(main) + "\n", kinds


def generate(seed, out_dir, only=None):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    text, kinds = Gen(seed, only).program()
    path = out_dir / (f"heap_verify_fuzz_{seed}" + ("_" + "_".join(only) if only else "") + ".iyi")
    path.write_text(text)
    return path, kinds


# ── The driver ──────────────────────────────────────────────────────────────

def build(src, out, flags, release, log, tmp):
    cmd = ([str(HEAVY)] if HEAVY.exists() else []) + [str(ROOT / "bin" / "iyi"), "build"]
    cmd += (["--release"] if release else []) + flags + ["-o", str(out), str(src)]
    env = dict(os.environ, TMPDIR=str(tmp))
    started = time.monotonic()
    with open(log, "w") as f:
        rc = subprocess.call(cmd, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT, env=env)
    return rc == 0 and out.exists(), time.monotonic() - started


def run_one(binary, env_extra, tmp):
    env = {k: v for k, v in os.environ.items() if not k.startswith("IYI_")}
    env.update(env_extra, TMPDIR=str(tmp))
    started = time.monotonic()
    proc = subprocess.Popen([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                            start_new_session=True)
    try:
        out, err = proc.communicate(timeout=RUN_TIMEOUT)
        timed_out = False
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        out, err = proc.communicate()
        timed_out = True
    return proc.returncode, out.decode(errors="replace"), err.decode(errors="replace"), timed_out, \
        time.monotonic() - started


def env_text(env):
    return " ".join(f"{k}={v}" for k, v in env.items())


def run(args):
    tmp = Path(args.tmp).expanduser()
    work = tmp / "fuzz"
    fails = tmp / "fuzz-fail"
    workers = [int(w) for w in str(args.workers).split(",")]
    flags_text = " ".join(VERIFY_FLAGS) + (" --release" if args.release else "")
    started = time.monotonic()
    ref_times, run_times, build_times = [], [], []
    runs = 0
    failures = []
    programs = range(args.first, args.first + args.programs)
    for seed in programs:
        name = f"p{seed}" + ("-" + "-".join(args.only) if args.only else "")
        pdir = work / name
        if pdir.exists():
            shutil.rmtree(pdir)
        src, kinds = generate(seed, pdir, args.only)
        ref, ver = pdir / "reference", pdir / "verify"

        def keep(reason, detail, files):
            dest = fails / name
            dest.mkdir(parents=True, exist_ok=True)
            for f in [src, ref, ver] + files:
                if Path(f).exists():
                    shutil.copy2(f, dest / Path(f).name)
            failures.append((seed, reason, detail))
            print(f"FAIL program {seed}: {reason}\n  {detail}\n  kept in {dest}", flush=True)
            return dest

        ok, took = build(src, ref, [], args.release, pdir / "reference.build.log", tmp)
        build_times.append(took)
        if not ok:
            keep("the reference build failed", f"log {pdir / 'reference.build.log'}", [pdir / "reference.build.log"])
            print((pdir / "reference.build.log").read_text()[-3000:])
            continue
        ok, took = build(src, ver, VERIFY_FLAGS, args.release, pdir / "verify.build.log", tmp)
        build_times.append(took)
        if not ok:
            keep("the verify build failed", f"log {pdir / 'verify.build.log'}", [pdir / "verify.build.log"])
            print((pdir / "verify.build.log").read_text()[-3000:])
            continue
        rc, expected, err, timed_out, took = run_one(ref, {}, tmp)
        ref_times.append(took)
        (pdir / "reference.out").write_text(expected)
        if rc != 0 or timed_out or "MISMATCH" in expected or "PANICKED" in expected:
            (pdir / "reference.err").write_text(err)
            keep("the reference run failed (a generator bug)",
                 f"rc={rc} timed_out={timed_out}; {pdir / 'reference'}",
                 [pdir / "reference.out", pdir / "reference.err"])
            continue
        print(f"program {seed}: {len(kinds)} steps, built in {build_times[-2]:.0f}+{build_times[-1]:.0f} s", flush=True)
        for w in workers:
            for index in range(1, args.seeds + 1):
                chaos = seed * 1000 + index
                env = {"IYI_CHAOS": str(chaos), "IYI_HEAP_STRESS": "1", "IYI_WORKERS": str(w)}
                if args.false_words:
                    env["IYI_HEAP_FALSE_WORDS"] = "1"
                rc, got, err, timed_out, took = run_one(ver, env, tmp)
                runs += 1
                run_times.append(took)
                reasons = []
                if timed_out:
                    reasons.append(f"timed out after {RUN_TIMEOUT} s")
                elif rc < 0:
                    reasons.append(f"killed by signal {-rc}")
                elif rc != 0:
                    reasons.append(f"exit {rc}")
                if "heap_verify:" in err:
                    reasons.append("heap_verify reported")
                if got != expected:
                    reasons.append("stdout differs from the reference")
                if reasons:
                    tag = f"c{chaos}-w{w}"
                    (pdir / f"{tag}.out").write_text(got)
                    (pdir / f"{tag}.err").write_text(err)
                    dest = fails / f"p{seed}"
                    repro = (f"cd {ROOT} && ./bin/iyi build {flags_text} -o {dest}/verify {dest}/{src.name} && "
                             f"{env_text(env)} {dest}/verify")
                    keep(", ".join(reasons), f"chaos seed {chaos}, IYI_WORKERS={w}\n  repro: {repro}\n  stderr: "
                         + " | ".join(line for line in err.splitlines()[-6:]),
                         [pdir / f"{tag}.out", pdir / f"{tag}.err", pdir / "reference.out"])
        print(f"program {seed}: {args.seeds * len(workers)} runs done", flush=True)
    wall = time.monotonic() - started
    print("\nsummary")
    print(f"  programs {len(programs)}, runs {runs}, failures {len(failures)}")
    print(f"  workers {','.join(map(str, workers))}, chaos seeds per program and worker count {args.seeds}"
          + (", false words" if args.false_words else "") + (", release" if args.release else ""))
    if run_times:
        print(f"  verify run wall: median {statistics.median(run_times):.2f} s, max {max(run_times):.2f} s")
    if ref_times:
        print(f"  reference run wall: median {statistics.median(ref_times):.2f} s")
    if build_times:
        print(f"  build wall (heavy.sh wait included): median {statistics.median(build_times):.0f} s")
    print(f"  total wall {wall:.0f} s")
    for seed, reason, detail in failures:
        print(f"  FAIL program {seed}: {reason}\n    {detail}")
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    g = sub.add_parser("gen", help="write one program")
    g.add_argument("--seed", type=int, required=True)
    g.add_argument("--out", required=True)
    g.add_argument("--only", type=lambda text: text.split(","), help="these step kinds, in this order (" + ",".join(STEPS) + ")")
    r = sub.add_parser("run", help="build, run and compare N programs")
    r.add_argument("--programs", type=int, required=True)
    r.add_argument("--seeds", type=int, required=True, help="chaos seeds per program and worker count")
    r.add_argument("--first", type=int, default=1, help="the first program seed")
    r.add_argument("--workers", default="1", help="IYI_WORKERS, or a comma list of them (1 is the simulated schedule)")
    r.add_argument("--false-words", action="store_true", help="IYI_HEAP_FALSE_WORDS=1 too")
    r.add_argument("--release", action="store_true", help="build with --release")
    r.add_argument("--tmp", default=str(DEFAULT_TMP), help="work directory (fuzz/ and fuzz-fail/ go under it)")
    r.add_argument("--only", type=lambda text: text.split(","), help="as gen's --only")
    args = parser.parse_args()
    if args.command == "gen":
        path, kinds = generate(args.seed, args.out, args.only)
        print(path)
        return 0
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
