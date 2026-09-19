#!/usr/bin/env python3
"""`iyi build --debug` works, and the fields it describes are the fields
the object has.

iyi does not keep a class's type id in the object's struct: it lives in
the high half of the header word under the pointer (GC_DESIGN.md Stage
5), which is why a node of a binary tree is 16 bytes here and not 24.
Every place in codegen that indexes a field asks `iyi_object_layout?`
about that - except the one that wrote debug info, which kept Crystal's
rule that field zero is the type id and so asked for the field *after*
the last one for every class in the program.

What that cost, measured rather than reasoned about:

  * LLVM 21 and later, which is what a current distribution ships:
    `LLVMOffsetOfElement` past the last field calls
    `report_fatal_error`, so `iyi build --debug` aborted (SIGABRT) on
    every program it was given, `puts 1` included.
  * LLVM 20 and earlier: no abort, a garbage offset. The debug info
    said every field lived one field along, so a debugger showed the
    neighbour's bytes and the last field's were off the end.

So this gate holds three things: the build works, the offsets are the
ones iyi's layout requires, and - where the machine has a debugger -
the debugger reads the values the program actually set.

Teeth: against the commit before the fix, step 1 aborts here and step 3
reads 32/64/96 where it wants 0/32/64.

No external tool is needed. The offsets are read out of the LLVM IR the
compiler itself emits (`--emit llvm-ir`), because a gate that depends on
`llvm-dwarfdump` being in the image is a gate that quietly skips.
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
    """An absolute path to the compiler.

    One step below runs in the temporary directory so the `.ll` lands
    there, and `./bin/iyi` means nothing from inside it."""
    if os.path.isabs(spec):
        return spec
    local = REPO / spec
    if local.exists():
        return str(local.resolve())
    return shutil.which(spec) or spec


IYI = compiler(os.environ.get("IYI", "./bin/iyi"))

# Three fields of known sizes, so the offsets are arithmetic and not a
# guess: two Int32s and a reference, which is 0, 4, 8 under iyi's layout
# and 4, 8, 16 under a layout with the type id in front.
FIXTURE = """class Shape
  getter width : Int32
  getter height : Int32
  getter name : String

  def initialize(@width : Int32, @height : Int32, @name : String)
  end

  def area : Int32
    @width * @height
  end
end

shape = Shape.new(3, 4, "rect")
puts shape.area.inspect
"""

# name => offset in bits, as `!DIDerivedType` writes it (and omits at 0).
WANTED = {"width": 0, "height": 32, "name": 64}

MEMBER = re.compile(
    r'!DIDerivedType\(tag: DW_TAG_member, name: "(\w+)".*?'
    r'(?:offset: (\d+))?\)')

FAILURES = []


def step(name, ok, detail=""):
    print(f"debug info {'ok' if ok else 'FAIL'} {name}  {detail}")
    if not ok:
        FAILURES.append(name)


def main():
    work = Path(tempfile.mkdtemp(prefix="iyi-debug-info"))
    source = work / "shape.iyi"
    source.write_text(FIXTURE)
    binary = work / "shape"

    built = subprocess.run([IYI, "build", "--debug", str(source),
                            "-o", str(binary)],
                           capture_output=True, text=True, cwd=REPO)
    # A compiler that dies here dies on a signal, and "exit code -6" is
    # the difference between "it refused" and "it aborted".
    step("a program builds with --debug", built.returncode == 0,
         f"exit {built.returncode}" +
         (f": {(built.stderr or built.stdout).strip()[:120]}"
          if built.returncode != 0 else ""))

    if built.returncode == 0:
        ran = subprocess.run([str(binary)], capture_output=True, text=True)
        step("and runs", ran.stdout.strip() == "12",
             f"printed {ran.stdout.strip()!r}, wanted '12'")

    # The offsets, from the compiler's own IR.
    emitted = subprocess.run([IYI, "build", "--debug", "--emit", "llvm-ir",
                              str(source), "-o", str(work / "shape-ir")],
                             capture_output=True, text=True, cwd=work)
    listing = next(iter(sorted(work.glob("*.ll"))), None)
    if emitted.returncode != 0 or listing is None:
        step("the field offsets are iyi's, not Crystal's", False,
             f"--emit llvm-ir exited {emitted.returncode} and wrote no .ll")
    else:
        text = listing.read_text()
        found = {}
        for line in text.split("\n"):
            if "DW_TAG_member" not in line:
                continue
            name = re.search(r'name: "(\w+)"', line)
            if not name or name.group(1) not in WANTED:
                continue
            offset = re.search(r"offset: (\d+)", line)
            found[name.group(1)] = int(offset.group(1)) if offset else 0
        step("the field offsets are iyi's, not Crystal's", found == WANTED,
             f"{found}, wanted {WANTED}")

    # Every sample, because "every program" is the claim the abort broke.
    samples = sorted((REPO / "samples/iyi").glob("*.iyi"))
    broken = []
    for sample in samples:
        out = work / (sample.stem + ".bin")
        result = subprocess.run([IYI, "build", "--debug", str(sample),
                                 "-o", str(out)],
                                capture_output=True, text=True, cwd=REPO)
        if result.returncode != 0:
            broken.append(f"{sample.name} ({result.returncode})")
    step("every sample builds with --debug", not broken,
         f"{len(samples)} samples" if not broken
         else f"{len(broken)}: {', '.join(broken[:4])}")

    # And where there is a debugger, what it reads.
    debugger = shutil.which("gdb")
    if not debugger or built.returncode != 0:
        print("debug info ---- no gdb here, so what a debugger reads goes "
              "unchecked; the offsets above are the claim")
    else:
        session = subprocess.run(
            [debugger, "-q", "-batch", "-ex", "break shape.iyi:15",
             "-ex", "run", "-ex", "print *shape", str(binary)],
            capture_output=True, text=True, cwd=work, timeout=120)
        said = session.stdout
        step("a debugger reads the values the program set",
             "width = 3" in said and "height = 4" in said,
             said.strip().split("\n")[-1][:90])

    shutil.rmtree(work, ignore_errors=True)

    if FAILURES:
        print(f"debug info: {len(FAILURES)} step(s) failed: "
              f"{', '.join(FAILURES)}")
        return 1
    print("debug info: --debug builds, and the fields are where the object "
          "keeps them")
    return 0


if __name__ == "__main__":
    sys.exit(main())
