#!/usr/bin/env python3
"""Does the union-plus-impls model hold at the size of a real AST?

Crystal's AST is ~120 node types and the compiler runs many passes over it.
Four members compiling is not evidence about 120 members and 3 passes: the
union's dispatch is a switch over type ids, and every trait method is
stencilled per implementing type, so both grow with the product.
"""
import subprocess, sys, pathlib, time

N = int(sys.argv[1]) if len(sys.argv) > 1 else 120
PASSES = 8
out = pathlib.Path("/tmp/astprobe/big.iyi")

L = ["module main", ""]
for i in range(N):
    L += [f"pub struct N{i}",
          "  getter kids : Array(Node)",
          "  def initialize(@kids : Array(Node))",
          "  end",
          "end", ""]
L.append("pub alias Node = " + " | ".join(f"N{i}" for i in range(N)))
L.append("")
for p in range(PASSES):
    L += [f"pub trait Pass{p}", f"  abstract def pass{p} : Int32", "end", ""]
    for i in range(N):
        L += [f"impl Pass{p} for N{i}",
              f"  def pass{p} : Int32",
              f"    total = {i}",
              f"    kids.each {{ |k| total = total + k.pass{p} }}",
              "    total",
              "  end",
              "end", ""]
L += [
    "leaf = N0.new([] of Node)",
    "tree = N1.new([leaf.as(Node)] of Node)",
] + [f"puts tree.pass{p}" for p in range(PASSES)]
out.write_text("\n".join(L) + "\n")
lines = len(L)

env = {"IYI_PATH": "/Users/jwaldrip/dev/worktrees/iyi-rebase/src",
       "IYI_CACHE_DIR": "/tmp/astprobe/cbig",
       "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
       "LIBRARY_PATH": "/opt/homebrew/opt/bdw-gc/lib"}
t = time.time()
r = subprocess.run(["/Users/jwaldrip/dev/worktrees/iyi-rebase/bin/iyi", "build",
                    "-o", "/tmp/astprobe/big", str(out)],
                   capture_output=True, text=True, env=env)
took = time.time() - t
print(f"  {N} node types, {PASSES} passes, {lines} lines")
print(f"  build exit={r.returncode} in {took:.1f}s")
if r.returncode:
    print("\n".join("    " + l[:150] for l in (r.stdout + r.stderr).splitlines()[:8]))
else:
    print("    ran:", subprocess.run(["/tmp/astprobe/big"], capture_output=True, text=True).stdout.split())
