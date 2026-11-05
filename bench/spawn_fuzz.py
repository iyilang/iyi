#!/usr/bin/env python3
"""Differential fuzzing of where a plain spawn runs, from source and from artifacts.

    python3 bench/spawn_fuzz.py SEEDS [--minutes M] [--keep DIR] [--workers N]

SEEDS is `N`, `A-B` or a comma list of those. Each seed generates, by
`random.Random(seed)` alone, a small program of two or three levels of
modules: dependency modules holding module state - constants and class
variables of `Share` types (an `Atomic`, a `Mutex`, a class of one) and of
types that are not (an `Array`, a counter class) - some under
`@[SafeReach]` or `@[UnsafeReach]`, some written only at module init, some
behind a `Mutex#lock`, some after the module's own first spawn; functions
reaching that state directly, through calls, through a generic, a block, a
proc, an overload, a method of a class (plain, generic, holding a private
type, virtual), a `pub macro`, a mid module's wrapper and a `pub import`,
and through std calling back into the module (`==` from `Array#includes?`);
functions of the modules that spawn tasks of their own; and a main program
of plain `g.spawn` calls into all of it, with writes before and after its
first parallel task.

Each program is built twice and the two compared (SPEC.md III.4.15, III.4.4):

  (a) from source: `iyi build --explain-spawn`. A `@[SafeReach]` the
      source build refuses is taken out (its line becomes a comment, so
      no line moves) and the build run again, until it builds: that is
      the reference, the program as the compiler proves it.
  (b) from artifacts: the dependencies built to `.iyimod`s by a producing
      program - one calling every function once (`first.iyi`), or the
      main program itself - and the main program built against them
      alone, the sources gone. A claim the producer refuses is taken out
      of the program both builds read.

The invariant: (b) may keep a spawn in its unit that (a) runs in parallel,
and never runs one in parallel that (a) keeps in its unit - the main
program's spawns by `--explain-spawn`, each dependency's own by what its
artifact recorded (`iyi mod dump`). A spawn whose claim the source refuses
is held to the source build without the claim. Either breach is a
VIOLATION.

The second oracle runs what was built: the source build on one worker
(`IYI_WORKERS=1`, where no spawn leaves the main thread) gives the
output; both builds on four workers, three times each, must print it.
Every write to module state adds one, so a lost update prints a smaller
count. A state under `@[UnsafeReach]` - the author's word, which nothing
checks - is left out of the comparison. A RACE is a difference.

Outputs are deleted as each seed finishes, except a seed with a finding,
copied to `--keep` (default: none). Exits 1 when anything was found.
"""
import argparse
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

KINDS = ["arr", "ctr", "atom", "mtx", "abox", "harr", "hatom"]
VIAS = ["g", "blk", "proc", "ovl", "cls", "gcls", "virt", "mac", "eq", "tos", "fan", "rfan", "rawg", "pfan", "hook", "cinit", "ans"]
# Ways of reaching state a run leaves out (`--without`), so that one hole
# found does not hide the others behind it.
WITHOUT = set()


def count_expr(kind, x):
    return {
        "arr": f"{x}.size",
        "ctr": f"{x}.count",
        "atom": f"{x}.get",
        "mtx": f"{x}.get {{ |a| a.size }}.as(Int32)",
        "abox": f"{x}.count",
        "harr": f"{x}.v.size",
        "hatom": f"{x}.v.get",
    }[kind]


def write_stmt(kind, x):
    return {
        "arr": f"{x} << 1",
        "ctr": f"{x}.bump",
        "atom": f"{x}.add(1)",
        "mtx": f"{x}.lock {{ |a| a << 1 }}",
        "abox": f"{x}.bump",
        "harr": f"{x}.v << 1",
        "hatom": f"{x}.v.add(1)",
    }[kind]


def init_expr(kind):
    return {
        "arr": "[] of Int32",
        "ctr": "Ctr.new",
        "atom": "Atomic(Int32).new(0)",
        "mtx": "Mutex.new { [] of Int32 }",
        "abox": "ABox.new",
        "harr": "Hold(Array(Int32)).new([] of Int32)",
        "hatom": "Hold(Atomic(Int32)).new(Atomic(Int32).new(0))",
    }[kind]


def decl_type(kind):
    return {
        "arr": "Array(Int32)",
        "ctr": "Ctr",
        "atom": "Atomic(Int32)",
        "mtx": "Mutex(Array(Int32))",
        "abox": "ABox",
        "harr": "Hold(Array(Int32))",
        "hatom": "Hold(Atomic(Int32))",
    }[kind]


def type_name(path):
    return "::".join(part[0].upper() + part[1:] for part in path.split("/"))


class Cell:
    def __init__(self, k, mod, rng):
        self.k = k
        self.mod = mod
        self.holder = rng.choice(["const", "const", "cvar"])
        self.kind = rng.choice(KINDS)
        self.claim = rng.choice([None, None, "safe", "safe", "safe", "unsafe"])
        if self.claim == "unsafe" and self.kind in ("arr", "harr"):
            # A racing `Array#<<` may crash the run, not lose a count.
            self.claim = "safe"
        self.lock = rng.random() < 0.35
        self.exported = self.holder == "const" and rng.random() < 0.2
        self.pub_class = rng.random() < 0.5
        self.raw_pub = self.lock and rng.random() < 0.4
        # A module's own spawns standing on a claim, and writes its
        # producer never makes, are what an artifact can get wrong: more
        # of them where a lock makes the claim provable.
        odds = {"fan": 0.5, "rfan": 0.4, "rawg": 0.6} if self.lock else {"rfan": 0.4}
        self.vias = [v for v in VIAS if rng.random() < odds.get(v, 0.3) and v not in WITHOUT]
        if not self.lock and "rawg" in self.vias:
            self.vias.remove("rawg")
        self.init_writes = rng.choice([0, 0, 1, 2])
        self.after_start_write = rng.random() < 0.15
        self.handle = rng.choice(["plain", "int", "arr", "priv", "privw"])
        if "ans" in self.vias and (self.holder != "const" or self.kind not in ("arr", "atom", "mtx")):
            self.vias.remove("ans")
        # Read-only after the module's initialiser, which writes it in
        # statements of its own: the state a claim can hold on for every
        # importer, unless a function answers it.
        self.ro = self.holder == "const" and not self.lock and rng.random() < 0.2
        if self.ro:
            self.vias = [v for v in self.vias if v in ("rfan", "ans")]
            self.raw_pub = False
            self.init_writes = rng.choice([1, 2])
            self.after_start_write = False


class Module:
    def __init__(self, path, level):
        self.path = path
        self.level = level
        self.type = type_name(path)
        self.cells = []
        self.imports = []
        self.reexports = []
        self.wrapped = []  # (cell, via) a mid module wraps
        self.lines = []
        self.uses_pointer = False


def gen(seed):
    """The program for *seed*: {relative path: text}, and its metadata."""
    rng = random.Random(seed)
    leaves = [Module(f"dep/l{i}", 2) for i in range(rng.randint(1, 3))]
    mids = [Module(f"dep/m{i}", 1) for i in range(rng.randint(0, 2))]
    k = 0
    for mod in leaves + mids:
        for _ in range(rng.randint(1, 3) if mod.level == 2 else rng.randint(0, 1)):
            mod.cells.append(Cell(k, mod, rng))
            k += 1
    cells = [cell for mod in leaves + mids for cell in mod.cells]
    for mid in mids:
        for leaf in leaves:
            if rng.random() < 0.7:
                mid.imports.append(leaf)
                if rng.random() < 0.4:
                    mid.reexports.append(leaf)
                for cell in leaf.cells:
                    if cell.ro:
                        continue
                    for via in ["w", "wg", "wfan"]:
                        if rng.random() < 0.4:
                            mid.wrapped.append((cell, via))

    files = {}
    for mod in leaves + mids:
        files[mod.path + ".iyi"] = module_text(mod, rng)
    ops = []  # (description, code, cell, writes per call)
    for cell in cells:
        ops.extend(cell_ops(cell))
    for mid in mids:
        for cell, via in mid.wrapped:
            if via == "w":
                ops.append((f"{mid.type}.w{cell.k}", f"{mid.type}.w{cell.k}", cell, 1))
            elif via == "wg":
                ops.append((f"{mid.type}.wg{cell.k}", f"{mid.type}.wg{cell.k}(\"s\")", cell, 1))
    files["app.iyi"], meta = app_text(rng, leaves, mids, cells, ops)
    files["first.iyi"] = first_text(rng, leaves, mids, cells)
    meta["producer"] = rng.choice(["first", "first", "first", "self"])
    meta["unsafe"] = sorted(f"s{cell.k}" for cell in cells if cell.claim == "unsafe")
    return files, meta


def module_text(mod, rng):
    out = [f"module {mod.path}", "", "import std/mutex::{Mutex}"]
    for leaf in mod.imports:
        names = []
        for cell in leaf.cells:
            names += ([] if cell.ro else [f"bump{cell.k}"]) + [f"read{cell.k}"]
        out.append(f"import {leaf.path}::{{{', '.join(names)}}}" if names else f"import {leaf.path}")
    for leaf in mod.reexports:
        out.append(f"pub import {leaf.path}")
    out.append("")
    pub = "pub " if rng.random() < 0.5 else ""
    out += [
        f"{pub}class Ctr", "  def initialize", "    @n = 0", "  end", "",
        "  def bump : Nil", "    @n += 1", "    nil", "  end", "",
        "  def count : Int32", "    @n", "  end", "end", "",
        f"{pub}class ABox", "  def initialize", "    @a = Atomic(Int32).new(0)", "  end", "",
        "  def bump : Nil", "    @a.add(1)", "    nil", "  end", "",
        "  def count : Int32", "    @a.get", "  end", "end", "",
        f"{pub}class Hold(T)", "  getter v : T", "", "  def initialize(@v : T)", "  end", "end", "",
        "class PrivBox", "  def initialize", "    @a = Atomic(Int32).new(0)", "  end", "",
        "  def get : Int32", "    @a.get", "  end", "end", "",
        "class PrivW", "  def initialize", "    @n = 0", "  end", "",
        "  def set(n : Int32) : Nil", "    @n = n", "  end", "end", "",
    ]
    t = mod.type
    for cell in mod.cells:
        k = cell.k
        claim = {None: None, "safe": f'@[SafeReach("fuzz {k}")]', "unsafe": f'@[UnsafeReach("fuzz {k}")]'}[cell.claim]
        if cell.claim == "unsafe":
            mod.uses_pointer = True
        if cell.lock:
            out += [f"LK{k} = Mutex.new {{ 0 }}", ""]
        if cell.holder == "const":
            if claim:
                out.append(claim)
            out += [f"{'pub ' if cell.exported else ''}S{k} = {init_expr(cell.kind)}", ""]
            if not cell.ro:
                out += [f"def raw_bump{k} : Nil", f"  {write_stmt(cell.kind, f'S{k}')}", "  nil", "end", ""]
            out += [f"def raw_read{k} : Int32", f"  {count_expr(cell.kind, f'S{k}')}", "end", ""]
        else:
            out.append(f"{'pub ' if cell.pub_class else ''}class Reg{k}")
            if claim:
                out.append("  " + claim)
            out += [f"  @@s : {decl_type(cell.kind)} = {init_expr(cell.kind)}", ""]
            out += ["  def self.bump : Nil", f"    {write_stmt(cell.kind, '@@s')}", "    nil", "  end", ""]
            out += ["  def self.read : Int32", f"    {count_expr(cell.kind, '@@s')}", "  end", "end", ""]
            out += [f"def raw_bump{k} : Nil", f"  Reg{k}.bump", "end", ""]
            out += [f"def raw_read{k} : Int32", f"  Reg{k}.read", "end", ""]
        if cell.lock:
            out += [f"pub def bump{k} : Nil", f"  LK{k}.lock {{ |_| raw_bump{k} }}", "  nil", "end", ""]
            out += [f"pub def read{k} : Int32", f"  LK{k}.get {{ |_| raw_read{k} }}.as(Int32)", "end", ""]
            if cell.raw_pub:
                out += [f"pub def bump{k}_raw : Nil", f"  raw_bump{k}", "end", ""]
        elif cell.ro:
            out += [f"pub def read{k} : Int32", f"  raw_read{k}", "end", ""]
        else:
            out += [f"pub def bump{k} : Nil", f"  raw_bump{k}", "end", ""]
            out += [f"pub def read{k} : Int32", f"  raw_read{k}", "end", ""]
        for via in cell.vias:
            if via == "g":
                out += [f"pub def bump{k}_g(v : T) : Nil forall T", f"  bump{k}", "end", ""]
            elif via == "blk":
                out += [f"pub def with{k}(&block : -> Nil) : Nil", "  block.call", f"  bump{k}", "end", ""]
            elif via == "proc":
                out += [f"pub def bumper{k} : Proc(Nil)", f"  -> {{ bump{k}; nil }}", "end", ""]
            elif via == "ovl":
                out += [f"pub def touch{k}(n : Int32) : Nil", f"  bump{k}", "end", ""]
                out += [f"pub def touch{k}(s : String) : Int32", f"  read{k}", "end", ""]
            elif via == "cls":
                out.append(f"pub class H{k}")
                field = {
                    "plain": [],
                    "int": ["  @v : Int32", "", "  def initialize", "    @v = 1", "  end", ""],
                    "arr": ["  @v : Array(Int32)", "", "  def initialize", "    @v = [] of Int32", "  end", ""],
                    "priv": ["  @v : PrivBox", "", "  def initialize", "    @v = PrivBox.new", "  end", ""],
                    "privw": ["  @v : PrivW", "", "  def initialize", "    @v = PrivW.new", "  end", ""],
                }[cell.handle]
                out += field
                out += ["  def bump : Nil", f"    {t}.bump{k}", "  end", "end", ""]
            elif via == "gcls":
                out += [f"pub class GH{k}(T)", "  def initialize(@v : T)", "  end", "",
                        "  def bump : Nil", f"    {t}.bump{k}", "  end", "end", ""]
            elif via == "virt":
                out += [f"pub abstract class Base{k}", "  abstract def act : Nil", "end", "",
                        f"pub class Quiet{k} < Base{k}", "  def act : Nil", "    nil", "  end", "end", "",
                        f"pub class Loud{k} < Base{k}", "  def act : Nil", f"    {t}.bump{k}", "  end", "end", "",
                        f"pub class Louder{k} < Loud{k}", "end", "",
                        f"pub def pick{k}(i : Int32) : Base{k}",
                        f"  i > 1 ? Louder{k}.new.as(Base{k}) : (i > 0 ? Loud{k}.new.as(Base{k}) : Quiet{k}.new.as(Base{k}))", "end", ""]
            elif via == "mac":
                out += [f"pub macro bump{k}_m", f"  ::{t}.bump{k}", "end", ""]
            elif via == "eq":
                out += [f"pub class Key{k}", f"  def ==(other : Key{k}) : Bool", f"    {t}.bump{k}", "    true",
                        "  end", "end", ""]
            elif via == "tos":
                out += [f"pub class Shown{k}", "  def to_s : String", f"    {t}.bump{k}", '    "s"', "  end", "end", ""]
            elif via == "rawg":
                # Unlocked, and a generic: its body travels, so the
                # producer need not call it for the artifact to carry it.
                out += [f"pub def bump{k}_rawg(v : T) : Nil forall T", f"  raw_bump{k}", "end", ""]
            elif via == "rfan":
                out += [f"pub def rfan{k}(t : Int32, r : Int32) : Int32", "  seen = Atomic(Int32).new(0)", "  group do |g|", "    t.times do",
                        f"      g.spawn {{ r.times {{ seen.add(read{k}) }}; nil }}", "    end", "  end", "  seen.get", "end", ""]
            elif via == "pfan":
                out += [f"pub def pfan{k}(t : Int32, r : Int32, &block : -> Nil) : Nil", "  group do |g|", "    t.times do",
                        "      g.spawn { r.times { block.call }; nil }", "    end", "  end", f"  bump{k}", "end", ""]
            elif via == "ans":
                out += [f"pub def all{k} : {decl_type(cell.kind)}", f"  S{k}", "end", ""]
            elif via == "cinit":
                out += [f"def make{k} : Int32", f"  bump{k}", "  7", "end", "", f"pub T{k} = make{k}", ""]
            elif via == "hook":
                out += [f"pub HOOK{k} = -> {{ bump{k}; nil }}", ""]
            elif via == "fan":
                op = f"bump{k}_raw" if cell.raw_pub and rng.random() < 0.5 else f"bump{k}"
                out += [f"pub def fan{k}(t : Int32, r : Int32) : Nil", "  group do |g|", "    t.times do",
                        f"      g.spawn {{ r.times {{ {op} }}; nil }}", "    end", "  end", "end", ""]
    for cell, via in mod.wrapped:
        k = cell.k
        if via == "w":
            out += [f"pub def w{k} : Nil", f"  bump{k}", "end", ""]
        elif via == "wg":
            out += [f"pub def wg{k}(v : T) : Nil forall T", f"  bump{k}", "end", ""]
        elif via == "wfan":
            out += [f"pub def wfan{k}(t : Int32, r : Int32) : Nil", "  group do |g|", "    t.times do",
                    f"      g.spawn {{ r.times {{ bump{k} }}; nil }}", "    end", "  end", "end", ""]
    if mod.uses_pointer:
        out += ["def touch_pointer : Bool", "  Pointer(UInt8).malloc(1_u64).address > 0_u64", "end", ""]
    # The module's initialiser: writes, a spawn of its own, a write after.
    for cell in mod.cells:
        for _ in range(cell.init_writes):
            out.append(write_stmt(cell.kind, f"S{cell.k}") if cell.ro else f"bump{cell.k}")
    started = False
    for cell in mod.cells:
        if cell.after_start_write:
            if not started:
                out += ["group do |g|", f"  g.spawn {{ read{cell.k}; nil }}", "end"]
                started = True
            out.append(f"bump{cell.k}")
    return "\n".join(out) + "\n"


def cell_ops(cell):
    """Each way the main program can reach *cell*: (label, code, cell, writes)."""
    t, k = cell.mod.type, cell.k
    ops = [(f"read{k}", f"{t}.read{k}", cell, 0)]
    if not cell.ro:
        ops.append((f"bump{k}", f"{t}.bump{k}", cell, 1))
    if cell.raw_pub:
        ops.append((f"bump{k}_raw", f"{t}.bump{k}_raw", cell, 1))
    if cell.holder == "cvar" and cell.pub_class:
        ops.append((f"Reg{k}.bump", f"{t}::Reg{k}.bump", cell, 1))
    if cell.exported:
        ops.append((f"S{k}", write_stmt(cell.kind, f"{t}::S{k}"), cell, 1))
    for via in cell.vias:
        ops += {
            "g": [(f"bump{k}_g", f"{t}.bump{k}_g(1.5)", cell, 1)],
            "blk": [(f"with{k}", f"{t}.with{k} {{ nil }}", cell, 1)],
            "proc": [(f"bumper{k}", f"{t}.bumper{k}.call", cell, 1)],
            "ovl": [(f"touch{k}(Int32)", f"{t}.touch{k}(1)", cell, 1), (f"touch{k}(String)", f"{t}.touch{k}(\"r\")", cell, 0)],
            "cls": [(f"H{k}#bump", f"{t}::H{k}.new.bump", cell, 1)],
            "gcls": [(f"GH{k}#bump", f"{t}::GH{k}(String).new(\"v\").bump", cell, 1)],
            "virt": [(f"Base{k}#act", f"{t}.pick{k}(1).act", cell, 1), (f"Louder{k}#act", f"{t}.pick{k}(2).act", cell, 1)],
            "mac": [(f"bump{k}_m", f"{t}.bump{k}_m", cell, 1)],
            "eq": [(f"Key{k}#==", f"[{t}::Key{k}.new].includes?({t}::Key{k}.new)", cell, 1)],
            "tos": [(f"Shown{k}#to_s", f"\"#{{{t}::Shown{k}.new}}\"", cell, 1)],
            "fan": [],
            "rfan": [],
            "rawg": [(f"bump{k}_rawg", f"{t}.bump{k}_rawg(1.5)", cell, 1)],
            "pfan": [(f"pfan{k}", f"{t}.pfan{k}(2, 10) {{ {t}.bump{k} }}", cell, 21)],
            "hook": [(f"HOOK{k}", f"{t}::HOOK{k}.call", cell, 1)],
            "cinit": [(f"T{k}", f"{t}::T{k} + 1", cell, 0)],
            "ans": [(f"all{k}", write_stmt(cell.kind, f"{t}.all{k}"), cell, 1)],
        }[via]
    return ops


def app_text(rng, leaves, mids, cells, ops):
    out = ["module main", ""]
    handed_on = {leaf.path for mid in mids for leaf in mid.reexports}
    for mod in leaves + mids:
        # A module a mid module hands on by `pub import` is sometimes
        # reached through that alone.
        if mod.path not in handed_on or rng.random() < 0.5:
            out.append(f"import {mod.path}")
    out.append("")
    # Writes before the first parallel task.
    for _ in range(rng.randint(0, 3)):
        writers = [op for op in ops if op[3]]
        if writers:
            out.append(rng.choice(writers)[1])
    # Values the spawns capture.
    captured = []
    for cell in cells:
        if "cls" in cell.vias and rng.random() < 0.5:
            name = f"h{cell.k}"
            out.append(f"{name} = {cell.mod.type}::H{cell.k}.new")
            captured.append((f"{name}.bump", cell))
        if "gcls" in cell.vias and rng.random() < 0.4:
            name = f"gh{cell.k}"
            out.append(f"{name} = {cell.mod.type}::GH{cell.k}(Int32).new(1)")
            captured.append((f"{name}.bump", cell))
    fans = []
    for cell in cells:
        if "fan" in cell.vias:
            fans.append(f"{cell.mod.type}.fan{cell.k}")
        if "rfan" in cell.vias:
            fans.append(f"{cell.mod.type}.rfan{cell.k}")
    for mid in mids:
        for cell, via in mid.wrapped:
            if via == "wfan":
                fans.append(f"{mid.type}.wfan{cell.k}")
    out.append("group do |g|")
    for _ in range(rng.randint(3, 10)):
        choice = rng.random()
        if fans and choice < 0.15:
            body = f"{rng.choice(fans)}({rng.choice([2, 4])}, {rng.choice([100, 1000])})"
        elif captured and choice < 0.3:
            body = f"{rng.choice([100, 1000])}.times {{ {rng.choice(captured)[0]} }}"
        elif choice < 0.4:
            # A spawn inside a spawn.
            body = f"group {{ |inner| 2.times {{ inner.spawn {{ {rng.choice([100, 1000])}.times {{ {rng.choice(ops)[1]} }}; nil }} }} }}"
        else:
            picks = [rng.choice(ops)[1] for _ in range(rng.choice([1, 1, 2]))]
            body = f"{rng.choice([1, 100, 1000])}.times {{ {'; '.join(picks)} }}"
        times = rng.choice([1, 2, 4])
        if times == 1:
            out.append(f"  g.spawn {{ {body}; nil }}")
        else:
            out += [f"  {times}.times do", f"    g.spawn {{ {body}; nil }}", "  end"]
    out.append("end")
    # Writes after it, and the modules' own spawns from the top level.
    for _ in range(rng.randint(0, 2)):
        writers = [op for op in ops if op[3]]
        if writers and rng.random() < 0.5:
            out.append(rng.choice(writers)[1])
        elif fans:
            out.append(f"{rng.choice(fans)}(4, 1000)")
    for cell in cells:
        out.append(f"puts \"s{cell.k}=#{{{cell.mod.type}.read{cell.k}}}\"")
    return "\n".join(out) + "\n", {}


def first_text(rng, leaves, mids, cells):
    """A producer calling every function of every module once, so each
    artifact's object code holds each one: writes first, then reads, then
    the modules' spawns."""
    out = ["module main", ""]
    for mod in leaves + mids:
        out.append(f"import {mod.path}")
    out.append("")
    writes, reads, spawns = [], [], []
    for cell in cells:
        t, k = cell.mod.type, cell.k
        if not cell.ro:
            writes.append(f"{t}.bump{k}")
        reads.append(f"puts {t}.read{k}")
        if cell.raw_pub:
            writes.append(f"{t}.bump{k}_raw")
        if cell.holder == "cvar" and cell.pub_class:
            writes.append(f"{t}::Reg{k}.bump")
            reads.append(f"puts {t}::Reg{k}.read")
        for via in cell.vias:
            writes += {
                "g": [f"{t}.bump{k}_g(1)"],
                "blk": [f"{t}.with{k} {{ nil }}"],
                "proc": [f"{t}.bumper{k}.call"],
                "ovl": [f"{t}.touch{k}(1)", f"puts {t}.touch{k}(\"r\")"],
                "cls": [f"{t}::H{k}.new.bump"],
                "gcls": [f"{t}::GH{k}(Int32).new(1).bump"],
                "virt": [f"{t}.pick{k}(1).act", f"{t}.pick{k}(0).act", f"{t}.pick{k}(2).act"],
                "mac": [f"{t}.bump{k}_m"],
                "eq": [f"puts [{t}::Key{k}.new].includes?({t}::Key{k}.new)"],
                "tos": [f"puts \"#{{{t}::Shown{k}.new}}\""],
                "fan": [],
                "rfan": [],
                "rawg": [],
                "pfan": [f"{t}.pfan{k}(1, 1) {{ nil }}"],
                "hook": [f"{t}::HOOK{k}.call"],
                "cinit": [f"puts {t}::T{k}"],
                "ans": [f"puts {count_expr(cell.kind, f'{t}.all{k}')}"],
            }[via]
            if via == "fan":
                spawns.append(f"{t}.fan{k}(1, 1)")
            if via == "rfan":
                spawns.append(f"{t}.rfan{k}(1, 1)")
    for mid in mids:
        for cell, via in mid.wrapped:
            if via == "w":
                writes.append(f"{mid.type}.w{cell.k}")
            elif via == "wg":
                writes.append(f"{mid.type}.wg{cell.k}(1)")
            else:
                spawns.append(f"{mid.type}.wfan{cell.k}(1, 1)")
    rng.shuffle(writes)
    rng.shuffle(spawns)
    if rng.random() < 0.3 and reads:
        # Some reads from tasks of the producer's own.
        out += ["group do |g|"] + [f"  g.spawn {{ {r[5:]}; nil }}" for r in reads[:2]] + ["end"]
    return "\n".join(out + writes + reads + spawns) + "\n"


# ── the oracle ─────────────────────────────────────────────────────────────

NOTE = re.compile(r"^(?P<file>[^\s:][^:]*):(?P<line>\d+):(?P<col>\d+): note: spawn (?P<rest>.*)$")
DUMP_SPAWN = re.compile(r"^  (?P<owner>.+?) (?P<line>\d+):(?P<col>\d+) (?P<verdict>parallel|in its unit: .*?)( \(asked\))?$")
REFUSED = re.compile(r"^In (?P<file>[^\s:]+):(?P<line>\d+):\d+$")


# `IYI_SPAWN_BROKEN` for the producing build and the build from artifacts
# alone (`--broken-artifact`): a broken copy of one side, which the
# differential oracle has to catch against the other.
BROKEN_ARTIFACT = {}


def iyi_run(iyi, args, cwd, timeout=180, artifact_side=False):
    env = dict(os.environ)
    if artifact_side and BROKEN_ARTIFACT:
        env["IYI_SPAWN_BROKEN"] = BROKEN_ARTIFACT["name"]
    try:
        done = subprocess.run([iyi] + args, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
        return done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired:
        return 124, "timed out"


def notes_of(log, root):
    """Each spawn the build noted, by its file relative to the program's
    directory - a body that travelled in an artifact is noted where the
    producer's source had it, which is the same file of the same tree."""
    placed = {}
    for line in log.splitlines():
        m = NOTE.match(line)
        if not m:
            continue
        path = os.path.relpath(m["file"], root) if os.path.isabs(m["file"]) else m["file"]
        path = re.sub(r"^\.\./(src|prod)/", "", path)
        placed[(path, int(m["line"]), int(m["col"]))] = m["rest"]
    return placed


def refused_claims(log):
    """The `@[SafeReach]` lines the build refused: [(file, line)]."""
    found = []
    lines = log.splitlines()
    for i, line in enumerate(lines):
        m = REFUSED.match(line.strip())
        if m and any("@[SafeReach] on" in later or "@[UnsafeReach] on" in later for later in lines[i:i + 8]):
            found.append((m["file"], int(m["line"])))
    return found


def strip_claim(root, file, line):
    path = os.path.join(root, file)
    with open(path) as f:
        text = f.read().split("\n")
    if "Reach(" not in text[line - 1]:
        return False
    indent = text[line - 1][: len(text[line - 1]) - len(text[line - 1].lstrip())]
    text[line - 1] = indent + "# refused claim"
    with open(path, "w") as f:
        f.write("\n".join(text))
    return True


VERBOSE = []


def build_stripping(iyi, root, args, stripped, artifact_side=False):
    """Builds in *root*, taking out each claim refused, until it builds or
    fails some other way: (exit status, log)."""
    for _ in range(12):
        rc, log = iyi_run(iyi, args, root, artifact_side=artifact_side)
        if rc == 0:
            return rc, log
        claims = refused_claims(log)
        if not claims:
            return rc, log
        if VERBOSE:
            for line in log.splitlines():
                if line.startswith("Error: @[SafeReach]"):
                    print(f"  {os.path.basename(root)} refused: {line[:400]}")
        for file, line in claims:
            if not strip_claim(root, file, line):
                return rc, log
            stripped.append(f"{file}:{line}")
    return rc, log


def dump_spawns(iyi, mods):
    placed = {}
    for dirpath, _, names in os.walk(mods):
        for name in names:
            if not name.endswith(".iyimod"):
                continue
            path = os.path.join(dirpath, name)
            module = os.path.relpath(path, mods)[: -len(".iyimod")]
            rc, log = iyi_run(iyi, ["mod", "dump", path], mods, artifact_side=True)
            inside = False
            for line in log.splitlines():
                if line == "spawns":
                    inside = True
                    continue
                if inside and not line.startswith("  "):
                    inside = False
                if inside:
                    m = DUMP_SPAWN.match(line)
                    if m:
                        verdict = m["verdict"]
                        rest = "runs in parallel" if verdict == "parallel" else "stays in its spawner's unit: " + verdict[len("in its unit: "):]
                        placed[(module + ".iyi", int(m["line"]), int(m["col"]))] = rest
    return placed


def parallel(rest):
    return rest.startswith("runs in parallel")


def run_binary(path, cwd, workers, timeout=60):
    env = dict(os.environ, IYI_WORKERS=str(workers))
    try:
        done = subprocess.run([path], cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
        return done.returncode, done.stdout
    except subprocess.TimeoutExpired:
        return 124, "timed out"


def comparable(output, unsafe):
    return [line for line in output.splitlines() if line.split("=")[0] not in unsafe]


def write_files(root, files):
    for rel, text in files.items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)


def check_seed(seed, iyi, work, runs):
    """Every finding for *seed*: [(kind, text)], and the counts it adds."""
    files, meta = gen(seed)
    root = os.path.join(work, f"s{seed}")
    shutil.rmtree(root, ignore_errors=True)
    src = os.path.join(root, "src")
    write_files(src, files)
    stats = {"seeds": 1}
    findings = []

    # The producer first: what it refuses, neither build reads.
    producer_stripped = []
    prod = os.path.join(root, "prod")
    shutil.copytree(src, prod)
    if meta["producer"] == "first":
        rc, log = build_stripping(iyi, prod, ["build", "--emit-iyimod", "mods", "-o", "first", "first.iyi"], producer_stripped, True)
    else:
        rc, log = build_stripping(iyi, prod, ["build", "--emit-iyimod", "mods", "--explain-spawn", "-o", "app_prod", "app.iyi"], producer_stripped, True)
    if rc != 0:
        stats["producer_failed"] = 1
        findings.append(("GENERATOR", f"the producer did not build:\n{log[-3000:]}"))
        return findings, stats, root
    stats["producer_refused"] = len(producer_stripped)
    for entry in producer_stripped:
        file, line = entry.rsplit(":", 1)
        strip_claim(src, file, int(line))

    # (a) From source, its refused claims taken out.
    source_stripped = []
    rc, src_log = build_stripping(iyi, src, ["build", "--explain-spawn", "-o", "app_src", "app.iyi"], source_stripped)
    if rc != 0:
        stats["source_failed"] = 1
        findings.append(("GENERATOR", f"the source build did not build:\n{src_log[-3000:]}"))
        return findings, stats, root
    stats["source_refused"] = len(source_stripped)
    reference = notes_of(src_log, src)

    # (b) From artifacts, the sources gone.
    art = os.path.join(root, "art")
    os.makedirs(art)
    shutil.copy(os.path.join(prod, "app.iyi"), art)
    shutil.copytree(os.path.join(prod, "mods"), os.path.join(art, "mods"))
    rc, art_log = iyi_run(iyi, ["build", "--use-iyimod", "mods", "--explain-spawn", "-o", "app_art", "app.iyi"], art, artifact_side=True)
    if rc != 0:
        findings.append(("ARTIFACT-BUILD", f"the build from artifacts failed where the source built:\n{art_log[-3000:]}"))
        return findings, stats, root
    placed = notes_of(art_log, art)
    dumped = dump_spawns(iyi, os.path.join(art, "mods"))
    placed.update(dumped)

    for key, rest in sorted(placed.items()):
        stats["spawns"] = stats.get("spawns", 0) + 1
        ref = reference.get(key)
        if ref is None:
            # A module's own spawn in a function the main program never
            # calls: the source build places nothing it does not reach.
            if key in dumped:
                stats["unreached"] = stats.get("unreached", 0) + 1
            elif parallel(rest):
                findings.append(("UNMATCHED", f"{key[0]}:{key[1]}:{key[2]} runs in parallel from artifacts and the source build has no note for it"))
            continue
        if parallel(rest) and not parallel(ref):
            findings.append(("VIOLATION", f"{key[0]}:{key[1]}:{key[2]} runs in parallel from artifacts and stays in its unit from source: {ref}"))
        elif parallel(ref) and not parallel(rest):
            stats["conservative"] = stats.get("conservative", 0) + 1
        if parallel(rest):
            stats["parallel"] = stats.get("parallel", 0) + 1
    if source_stripped:
        stats["claims_refused_by_source"] = len(source_stripped)

    # The second oracle: what runs.
    if any(parallel(rest) for rest in list(placed.values()) + list(reference.values())):
        stats["ran"] = 1
        unsafe = set(meta["unsafe"])
        rc, want = run_binary(os.path.join(src, "app_src"), src, 1)
        if rc != 0:
            findings.append(("RUN", f"the source build failed on one worker (exit {rc}):\n{want[-2000:]}"))
        else:
            for name, binary, cwd in (("source", os.path.join(src, "app_src"), src), ("artifact", os.path.join(art, "app_art"), art)):
                for attempt in range(runs):
                    rc, got = run_binary(binary, cwd, 4)
                    if rc != 0 or comparable(got, unsafe) != comparable(want, unsafe):
                        findings.append(("RACE", f"the {name} build on four workers, run {attempt + 1}, exit {rc}:\n"
                                         f"want {comparable(want, unsafe)}\ngot  {comparable(got, unsafe)}"))
                        break
    return findings, stats, root


def parse_seeds(text):
    seeds = []
    for part in text.split(","):
        if "-" in part:
            a, b = part.split("-")
            seeds.extend(range(int(a), int(b) + 1))
        else:
            seeds.append(int(part))
    return seeds


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("seeds")
    parser.add_argument("--iyi", default=os.environ.get("IYI", os.path.join(REPO, "bin", "iyi")))
    parser.add_argument("--minutes", type=float, default=0, help="stop starting seeds after this long")
    parser.add_argument("--keep", default="", help="copy each seed with a finding here")
    parser.add_argument("--runs", type=int, default=3, help="runs on four workers per build")
    parser.add_argument("--show", action="store_true", help="print the program of the first seed and stop")
    parser.add_argument("--expect", default="", help="stop at the first seed that finds this kind, and exit 0 only if one does (a broken copy's proof)")
    parser.add_argument("--broken-artifact", default="", help="IYI_SPAWN_BROKEN for the producing build and the build from artifacts only")
    parser.add_argument("--verbose", action="store_true", help="print each claim a build refused")
    parser.add_argument("--without", default="", help="ways of reaching state to leave out, comma-separated: " + ", ".join(VIAS))
    args = parser.parse_args()
    WITHOUT.update(v for v in args.without.split(",") if v)
    if args.verbose:
        VERBOSE.append(True)
    if args.broken_artifact:
        BROKEN_ARTIFACT["name"] = args.broken_artifact
    seeds = parse_seeds(args.seeds)
    if args.show:
        files, meta = gen(seeds[0])
        for rel, text in sorted(files.items()):
            print(f"==> {rel}\n{text}")
        print(meta)
        return 0
    work = tempfile.mkdtemp(prefix="spawn_fuzz.")
    started = time.time()
    totals = {}
    kinds = {}
    try:
        for seed in seeds:
            if args.minutes and time.time() - started > args.minutes * 60:
                print(f"stopped at {args.minutes} min, before seed {seed}")
                break
            findings, stats, root = check_seed(seed, args.iyi, work, args.runs)
            for key, value in stats.items():
                totals[key] = totals.get(key, 0) + value
            for kind, text in findings:
                kinds[kind] = kinds.get(kind, 0) + 1
                print(f"seed {seed}: {kind}: {text}")
            if findings and args.keep:
                keep = os.path.join(args.keep, f"s{seed}")
                shutil.rmtree(keep, ignore_errors=True)
                shutil.copytree(root, keep, ignore=shutil.ignore_patterns("app_src", "app_art", "app_prod", "first", "*.o"))
            shutil.rmtree(root, ignore_errors=True)
            if args.expect and kinds.get(args.expect):
                print(f"seed {seed} found a {args.expect}: stopped")
                break
    finally:
        shutil.rmtree(work, ignore_errors=True)
    elapsed = time.time() - started
    print(f"{totals.get('seeds', 0)} seeds in {elapsed:.0f} s: " + ", ".join(f"{k} {v}" for k, v in sorted(totals.items())))
    print("findings: " + (", ".join(f"{k} {v}" for k, v in sorted(kinds.items())) or "none"))
    if args.expect:
        return 0 if kinds.get(args.expect) else 1
    return 1 if kinds else 0


if __name__ == "__main__":
    sys.exit(main())
