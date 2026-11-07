#!/usr/bin/env bash
# Exercises `std/debug`, the resolver that turns a panic's captured frames into
# `file:line:column` by reading the program's own DWARF.
#
#     bash bench/std_debug_exercise.sh
#
# What it proves, in order:
#
#   Every platform with python3:
#   0. The line-table reader names the file of an address in a hand-written
#      version 3 table, whose directories start a byte before version 4's;
#      a copy that reads every table at version 4's offset is refused.
#
#   Darwin and Linux:
#   1. A panic several calls deep resolves every frame to the right line. The
#      probe's call sites sit at known lines and each is checked by number,
#      because a plausible line number that points at the wrong statement is
#      worse than an address: it is believed.
#   2. Moving the raise moves the reported line, so resolution is positional
#      rather than a fixed string that happens to match.
#   3. A program that does NOT import `std/debug` still panics, still exits
#      non-zero, and still links only the platform libc. The resolver is a
#      library a program opts into, not a cost the prelude carries.
#   4. The resolved program links only the platform libc as well, which is the
#      dependency floor's rule and the reason this module may bind at all
#      (`bench/std_exercise.sh` records that exception).
#
#   Linux, where the module walks the stack itself (`.eh_frame`) and reads
#   `/proc/self/exe` for the names:
#   5. Against binutils: a stripped copy prints its frames' addresses, and
#      `nm` and `addr2line` on the unstripped program name the function and
#      the line the resolver printed for each.
#   6. The walk holds where its rules differ: an optimised build, a build
#      that keeps frame pointers (each CFA through rbp), a panic on a task's
#      own stack, and a stripped program, which prints addresses.
#   7. The program asks libc for nothing: `say` goes through `__iyi_write`
#      and the walk through the prelude's syscalls. A patched copy that
#      binds `LibC.write` is refused, so the check has teeth.
#   8. Six broken copies of the walk and the reader, each caught by a check
#      above.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# the patches and oracles below are written in python, and windows answers
# `python3` with a store stub that prints and exits rather than running it, so
# the interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from `pwd` is `/c/...` and finds no prelude at all, and a
# scratch directory named `/tmp/tmp.X` is silently ignored on that path, so
# the patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src"

case "$(uname -s)" in
  Darwin) PLATFORM=darwin ;;
  Linux) PLATFORM=linux ;;
  *)
    echo "std/debug: the Darwin and Linux resolvers are exercised here; Windows' PDB reader by bench/panics.sh"
    exit 0
    ;;
esac

fail() {
  echo "  FAIL: $1"
  status=1
}

links_of() {
  case "$(uname -s)" in
    Darwin) otool -L "$1" 2>/dev/null | sed 1d | awk '{print $1}' ;;
    *) readelf -d "$1" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' ;;
  esac
}

platform_libc_only() {
  local binary="$1" label="$2" lib
  for lib in $(links_of "$binary"); do
    case "$lib" in
      *libSystem*|*libc.so*|*ld-linux*|*libgcc_s*) ;;
      *) fail "$label links $lib, not just the platform libc" ;;
    esac
  done
}

# Darwin dyld names, plus libc write: a Linux import must not grow any of these
# as undefined symbols. Bare iyi programs already have __libc_start_main.
# A symbol may arrive versioned — `write@GLIBC_2.2.5` is what `nm -u` prints
# for a binary linked against a glibc that versions it — and the pattern was
# anchored on the bare name, so on such a machine this saw nothing at all.
# That is the shape a check fails in silence: the proof below, which binds
# `LibC.write` on purpose, passed here while the symbol sat in the table.
forbidden_undef() {
  nm -u "$1" 2>/dev/null | grep -E ' (write|dladdr|_NSGetExecutablePath|_dyld_get_image_vmaddr_slide)(@.*)?$'
}

# ── The line-table reader, on every platform: a version 3 table
#
# The Darwin arm reads `__debug_line` with `DwarfResolver.resolve_line`, and
# the walk itself is the same bytes on any machine, so it is run here on a
# table written out by hand rather than only where a dSYM exists. Version 3
# puts its directories one byte before version 4 does (no
# maximum_operations_per_instruction); read from version 4's offset, the
# first directory lost its first byte, and with no directories at all the
# first file name was taken for one and every frame was named `??`. The
# reader is private to the module, so its four defs are lifted out of the
# source into a harness that hands it the table.
line_reader_names() { # line_reader_names <debug.iyi> <name> -> prints what it resolved
  local src="$1" name="$2"
  "$PY" - "$src" "$WORK/$name.iyi" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("  def self.read_uleb128"))
stop = next(i for i, l in enumerate(lines) if i > start and l.startswith("  {% if flag?(:win32) %}"))
body = "\n".join(lines[start:stop])
# unit_length, version 3, header_length; min_inst 1, default_is_stmt 1,
# line_base -5, line_range 14, opcode_base 13 and its 12 lengths; one
# directory, one file in it; then the program: set_address 0x1000,
# advance_line +41, set_column 7, copy, advance_pc 16, advance_line +1,
# copy, advance_pc 16, end_sequence.
header = [1, 1, 0xFB, 14, 13, 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1]
header += list(b"/src\0") + [0] + list(b"a.c\0") + [1, 0, 0] + [0]
program = [0, 9, 2] + list((0x1000).to_bytes(8, "little")) + [3, 41, 5, 7, 1, 2, 16, 3, 1, 1, 2, 16, 0, 1, 1]
after_length = [3, 0] + list(len(header).to_bytes(4, "little")) + header + program
table = list(len(after_length).to_bytes(4, "little")) + after_length
open(sys.argv[2], "w").write(
    "struct LineReader\n" + body + "\nend\n\n" +
    "table = [" + ", ".join("%d_u8" % b for b in table) + "]\n" +
    "puts LineReader.resolve_line(0x1004_u64, table.to_unsafe, table.size.to_i64).inspect\n")
PY
  "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1 || {
    sed -n '1,8p' "$WORK/$name.build"
    return 1
  }
  "$WORK/$name"
}

echo "== the line-table reader names a version 3 table's file"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the version 3 table is unmeasured"
else
  v3=$(line_reader_names "$REPO/src/std/debug.iyi" v3_reader)
  if [ "$v3" = '"/src/a.c:42:7"' ]; then
    echo "  0x1004 in a version 3 table: /src/a.c:42:7"
  else
    fail "a version 3 table resolved 0x1004 to $v3, not /src/a.c:42:7"
  fi
  mkdir -p "$WORK/v4only"
  if ! "$PY" - "$REPO/src/std/debug.iyi" "$WORK/v4only/debug.iyi" <<'PY'
import sys
t = open(sys.argv[1]).read()
old = "(version >= 4 ? 16_i64 : 15_i64)"
if old not in t:
    raise SystemExit("the directory offset no longer reads the version")
open(sys.argv[2], "w").write(t.replace(old, "16_i64", 1))
PY
  then
    fail "the version-4-only copy could not be made"
  elif ! v4only=$(line_reader_names "$WORK/v4only/debug.iyi" v4only_reader); then
    fail "the version-4-only copy did not build: $v4only"
  elif [ "$v4only" = '"/src/a.c:42:7"' ]; then
    fail "a reader that takes every table for version 4 resolved the version 3 one anyway"
  else
    echo "  a reader that takes every table for version 4 answers $v4only, so the check has teeth"
  fi
fi

# ── 1. a panic several calls deep, with the call sites on known lines
#
# Written so the line numbers are stated here rather than discovered: the raise
# is line 6, and the three callers are lines 11, 15 and 18.
cat > "$WORK/deep.iyi" <<'EOF'
module deep

import std/debug

def gamma(n : Int32) : Int32
  raise "boom"
  n
end

def beta(n : Int32) : Int32
  gamma(n)
end

def alpha(n : Int32) : Int32
  beta(n)
end

puts alpha(1)
EOF

# The first check a run of `deep` fails, or nothing: shared by the run
# itself and by the broken copies below, which must each fail one.
# Darwin's names are not asked for here; Linux's are, in order.
deep_holds() { # deep_holds <output>
  local out="$1" line
  grep -q "^iyi: panic: boom" "$out" || { echo "the message is the first line"; return; }
  for line in 6 11 15 18; do
    grep -q "deep.iyi:$line" "$out" || { echo "a frame at deep.iyi:$line"; return; }
  done
  if [ "$PLATFORM" = linux ]; then
    grep -qE "^0 +gamma at .*deep\.iyi:6:" "$out" &&
      grep -qE "^1 +beta at .*deep\.iyi:11:" "$out" &&
      grep -qE "^2 +alpha at .*deep\.iyi:15:" "$out" ||
      echo "frames 0 to 2 are gamma, beta and alpha"
  fi
}

echo "== a panic resolves its frames to file, line and column"
if ! "$IYI" build -o "$WORK/deep" "$WORK/deep.iyi" > "$WORK/deep.build" 2>&1; then
  echo "  build failed"
  sed 's/^/    /' "$WORK/deep.build"
  exit 1
fi
"$WORK/deep" > "$WORK/deep.out" 2>&1
code=$?
sed 's/^/  /' "$WORK/deep.out"

[ "$code" -ne 0 ] || fail "a panicking program exited 0"
missing="$(deep_holds "$WORK/deep.out")"
[ -z "$missing" ] || fail "the trace does not hold: $missing"
platform_libc_only "$WORK/deep" "the resolved program"

# ── 2. move the raise, and the reported line moves with it
echo "== the line follows the raise"
cat > "$WORK/moved.iyi" <<'EOF'
module moved

import std/debug

def gamma(n : Int32) : Int32
  x = n + 1
  y = x + 1
  raise "boom"
  y
end

puts gamma(1)
EOF
if "$IYI" build -o "$WORK/moved" "$WORK/moved.iyi" > "$WORK/moved.build" 2>&1; then
  "$WORK/moved" > "$WORK/moved.out" 2>&1
  sed 's/^/  /' "$WORK/moved.out"
  grep -q "moved.iyi:8" "$WORK/moved.out" \
    || fail "the raise is on line 8 and no frame says so"
  grep -q "moved.iyi:6" "$WORK/moved.out" \
    && fail "a frame named line 6, where the raise is not"
else
  echo "  build failed"
  sed 's/^/    /' "$WORK/moved.build"
  status=1
fi

# ── 3. a program that does not import it keeps the minimal panic path
echo "== without the import, the panic path is unchanged"
cat > "$WORK/bare.iyi" <<'EOF'
module bare

raise "boom"
EOF
if "$IYI" build -o "$WORK/bare" "$WORK/bare.iyi" > "$WORK/bare.build" 2>&1; then
  "$WORK/bare" > "$WORK/bare.out" 2>&1
  bare_code=$?
  sed 's/^/  /' "$WORK/bare.out"
  [ "$bare_code" -ne 0 ] || fail "the bare program exited 0"
  grep -q "^iyi: panic: boom" "$WORK/bare.out" || fail "the bare panic lost its message"
  grep -q "\.iyi:[0-9]*:[0-9]*" "$WORK/bare.out" \
    && fail "a program that never imported std/debug resolved a column anyway"
  platform_libc_only "$WORK/bare" "the bare program"
else
  echo "  build failed"
  sed 's/^/    /' "$WORK/bare.build"
  status=1
fi

if [ "$PLATFORM" = linux ]; then
  # ── 5. the walk and the names, against binutils
  #
  # A stripped copy prints its frames as addresses, and the load base is
  # the program's first mapping, which it prints before it panics: each
  # address, less that base and the one byte back to its call, is asked
  # of `addr2line -f` (which function DWARF names, which line) on the
  # unstripped program - and both must be what the resolver printed for
  # the same frame. A copy stripped of its debug information alone names
  # its frames by `.symtab`, each the symbol `nm` says holds the address.
  # The raise is line 7, its callers 12, 16 and 22.
  echo "== the walk and the names, against binutils"
  cat > "$WORK/probe.iyi" <<'EOF'
module probe

import std/debug
import std/file

def gamma(n : Int32) : Int32
  raise "boom"
  n
end

def beta(n : Int32) : Int32
  gamma(n)
end

def alpha(n : Int32) : Int32
  beta(n)
end

puts "base " + File.read("/proc/self/maps").split('-')[0]
STDOUT.flush
puts alpha(1)
EOF
  if [ -z "$PY" ] || ! command -v addr2line >/dev/null 2>&1 || ! command -v strip >/dev/null 2>&1; then
    echo "  no python3, addr2line or strip here, so the comparison with binutils is unmeasured"
  elif ! "$IYI" build -o "$WORK/probe" "$WORK/probe.iyi" > "$WORK/probe.build" 2>&1; then
    fail "the probe did not build"
    sed 's/^/    /' "$WORK/probe.build"
  else
    cp "$WORK/probe" "$WORK/probe-stripped" && strip "$WORK/probe-stripped"
    cp "$WORK/probe" "$WORK/probe-nodebug" && strip -g "$WORK/probe-nodebug"
    "$WORK/probe-stripped" > "$WORK/stripped.out" 2> "$WORK/stripped.err"
    "$WORK/probe" > /dev/null 2> "$WORK/named.err"
    "$WORK/probe-nodebug" > "$WORK/nodebug.out" 2> "$WORK/nodebug.err"
    if ! "$PY" - "$WORK/probe" "$WORK/stripped.out" "$WORK/stripped.err" "$WORK/named.err" "$WORK/nodebug.out" "$WORK/nodebug.err" <<'PY'
import re, subprocess, sys
program, out, raw, named, nodebug_out, nodebug = sys.argv[1:]
def base_of(path):
    return int(re.search(r"^base ([0-9a-f]+)$", open(path).read(), re.M).group(1), 16)
base = base_of(out)
addresses = [int(m, 16) for m in re.findall(r"^\d+ +\[0x([0-9a-f]+)\]$", open(raw).read(), re.M)]
printed = re.findall(r"^\d+ +(\S+) at (\S+):(\d+):\d+$", open(named).read(), re.M)
links = [a - base - 1 for a in addresses]
answers = subprocess.run(["addr2line", "-f", "-e", program] + ["%x" % a for a in links],
                         capture_output=True, text=True).stdout.splitlines()
if len(addresses) < 4 or len(addresses) != len(printed):
    sys.exit("  the stripped copy printed %d addresses and the program named %d frames" % (len(addresses), len(printed)))
bad = 0
for index, (name, path, number) in enumerate(printed):
    function, where = answers[2 * index], answers[2 * index + 1].split(" ")[0]
    if function != name or where != "%s:%s" % (path, number):
        print("  frame %d: printed %s at %s:%s; addr2line says %s at %s" % (index, name, path, number, function, where))
        bad += 1
functions = []
for line in subprocess.run(["nm", "-S", "--defined-only", program], capture_output=True, text=True).stdout.splitlines():
    parts = line.split(" ", 3)
    if len(parts) == 4 and parts[2] in ("t", "T"):
        functions.append((int(parts[0], 16), int(parts[1], 16), parts[3]))
fallback = re.findall(r"^\d+ +(.+) \[0x([0-9a-f]+)\]$", open(nodebug).read(), re.M)
nodebug_base = base_of(nodebug_out)
if len(fallback) != len(printed):
    print("  the copy without debug information named %d frames, the program %d" % (len(fallback), len(printed)))
    bad += 1
for index, (name, address) in enumerate(fallback):
    link = int(address, 16) - nodebug_base - 1
    holders = [f[2] for f in functions if f[0] <= link < f[0] + f[1]]
    if holders != [name]:
        print("  frame %d without debug information: printed %s; nm says %s" % (index, name, holders))
        bad += 1
if bad:
    sys.exit(1)
print("  %d frames: each the function and line addr2line names for its address" % len(printed))
print("  without debug information, each the symbol nm says holds it")
PY
    then
      fail "the resolver and binutils disagree"
    fi
  fi

  # ── 6. the walk where its rules differ
  echo "== the walk where its rules differ"
  # Optimised, gamma and beta are inlined into alpha and their frames are
  # alpha's: the raise's line and main's must still be there.
  if "$IYI" build --release -o "$WORK/deep-release" "$WORK/deep.iyi" > "$WORK/release.build" 2>&1; then
    "$WORK/deep-release" > "$WORK/release.out" 2>&1
    if grep -q "deep.iyi:6:" "$WORK/release.out" && grep -q "deep.iyi:18:" "$WORK/release.out"; then
      echo "  --release: the raise at deep.iyi:6 and its call from deep.iyi:18"
    else
      fail "an optimised build lost the raise's line or main's"
      sed 's/^/    /' "$WORK/release.out"
    fi
  else
    fail "the optimised build failed"
  fi
  # Every function keeping its frame pointer defines its CFA by it.
  if "$IYI" build --frame-pointers always -o "$WORK/deep-fp" "$WORK/deep.iyi" > "$WORK/fp.build" 2>&1; then
    "$WORK/deep-fp" > "$WORK/fp.out" 2>&1
    missing="$(deep_holds "$WORK/fp.out")"
    if [ -z "$missing" ]; then
      echo "  --frame-pointers always: every frame, each CFA found through the frame pointer"
    else
      fail "with frame pointers kept, the trace does not hold: $missing"
      sed 's/^/    /' "$WORK/fp.out"
    fi
  else
    fail "the frame-pointer build failed"
  fi
  # A task runs on a stack of its own, mapped by the scheduler, which the
  # walk follows down to the fiber's entry.
  cat > "$WORK/task.iyi" <<'EOF'
module task

import std/debug

def inner(n : Int32) : Int32
  raise "in a task" if n > 0
  n
end

def outer(n : Int32) : Int32
  inner(n) + 1
end

group do |g|
  g.spawn do
    outer(3)
    nil
  end
end
EOF
  if "$IYI" build -o "$WORK/task" "$WORK/task.iyi" > "$WORK/task.build" 2>&1; then
    "$WORK/task" > "$WORK/task.out" 2>&1
    if grep -qE "^0 +inner at .*task\.iyi:6:" "$WORK/task.out" &&
       grep -qE "^1 +outer at .*task\.iyi:11:" "$WORK/task.out" &&
       grep -qE "^2 +[^ ]* at .*task\.iyi:16:" "$WORK/task.out"; then
      echo "  a task's panic: inner, outer and the spawned block, on the task's own stack"
    else
      fail "a panic in a task did not name inner, outer and the spawned block"
      sed 's/^/    /' "$WORK/task.out"
    fi
  else
    fail "the task program did not build"
  fi
  # No `.symtab` and no `.debug_line`: the walk still runs, and each frame
  # is its address alone.
  if command -v strip >/dev/null 2>&1; then
    cp "$WORK/deep" "$WORK/deep-stripped" && strip "$WORK/deep-stripped"
    "$WORK/deep-stripped" > "$WORK/stripped-deep.out" 2>&1
    stripped_code=$?
    frames="$(grep -cE '^[0-9]+ +\[0x[0-9a-f]+\]$' "$WORK/stripped-deep.out")"
    if [ "$stripped_code" -eq 1 ] && [ "$frames" -ge 4 ] && ! grep -q "deep.iyi:[0-9]*:" "$WORK/stripped-deep.out"; then
      echo "  stripped: $frames frames, each an address"
    else
      fail "a stripped program's panic is not its addresses (exit $stripped_code):"
      sed 's/^/    /' "$WORK/stripped-deep.out"
    fi
  fi

  # ── 7. libc is asked for nothing
  echo "== the walk and the reader ask libc for nothing"
  if forbidden_undef "$WORK/deep" | grep -q .; then
    fail "the resolved program leaves a darwin or libc symbol undefined:"
    forbidden_undef "$WORK/deep" | sed 's/^/    /'
  else
    echo "  no write, and no darwin name, undefined in the resolved program"
  fi
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the LibC.write proof is unmeasured"
  else
    mkdir -p "$WORK/bad/std"
    "$PY" - "$REPO/src/std/debug.iyi" "$WORK/bad/std/debug.iyi" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
old = "n = __iyi_write("
if old not in t:
    raise SystemExit("say no longer goes through __iyi_write")
t = t.replace(old, "n = LibC.write(", 1)
# Darwin already has LibC.write behind the flag. Linux needs a declaration
# so the patched copy can bind `write` and fail the undefined-symbol check.
anchor = "module std/debug\n"
if anchor not in t:
    raise SystemExit("module header missing")
t = t.replace(anchor, """module std/debug

{% unless flag?(:darwin) %}
  lib LibC
    fun write(fd : Int32, buf : Void*, count : UInt64) : Int64
  end
{% end %}
""", 1)
open(dst, "w").write(t)
PY
    if IYI_PATH="$WORK/bad${PSEP}$REPO/src" "$IYI" build -o "$WORK/badprog" "$WORK/deep.iyi" \
         > "$WORK/badprog.build" 2>&1; then
      if forbidden_undef "$WORK/badprog" | grep -qE ' write(@.*)?$'; then
        echo "  a LibC.write copy leaves write undefined, so the check has teeth"
      else
        fail "a module that binds LibC.write passed the write check"
      fi
    else
      fail "the LibC.write copy failed to build"
      sed 's/^/    /' "$WORK/badprog.build"
    fi
  fi

  # ── 8. broken copies, each caught by the check it names
  echo "== proving the checks can fail when the walk or the reader is broken"
  proofs=0
  prove_broken() { # prove_broken <label> <expected check> <old> <new> [build flags...]
    local label="$1" expected="$2" old="$3" new="$4"
    shift 4
    proofs=$((proofs + 1))
    rm -rf "$WORK/broken" && mkdir -p "$WORK/broken/std"
    if [ -z "$PY" ]; then
      echo "  $label: no python3, unmeasured"
      return
    fi
    if ! OLD="$old" NEW="$new" "$PY" - "$REPO/src/std/debug.iyi" "$WORK/broken/std/debug.iyi" <<'PY'
import os, sys
t = open(sys.argv[1]).read()
if t.count(os.environ["OLD"]) != 1:
    sys.exit("patch site missing or not one")
open(sys.argv[2], "w").write(t.replace(os.environ["OLD"], os.environ["NEW"]))
PY
    then
      fail "the $label patch did not apply"
      return
    fi
    if ! IYI_PATH="$WORK/broken${PSEP}$REPO/src" "$IYI" build "$@" -o "$WORK/broken-deep" "$WORK/deep.iyi" \
         > "$WORK/broken.build" 2>&1; then
      fail "$label: the broken copy did not build"
      sed -n '1,8p' "$WORK/broken.build" | sed 's/^/    /'
      return
    fi
    "$WORK/broken-deep" > "$WORK/broken.out" 2>&1
    got="$(deep_holds "$WORK/broken.out")"
    if [ "$got" = "$expected" ]; then
      echo "  $label: caught - $expected"
    elif [ -z "$got" ]; then
      fail "$label: the exercise PASSED on a broken module"
    else
      fail "$label: failed, but at '$got', not '$expected'"
      sed 's/^/    /' "$WORK/broken.out"
    fi
  }
  # The CFA's offset never moved past the CIE's: every frame past the
  # first is found at the wrong address.
  prove_broken "def_cfa_offset ignored" "a frame at deep.iyi:11" \
    '          when 0x0e
            state[1] = read_uleb128(pointerof(cursor)).unsafe_to_i64' \
    '          when 0x0e
            read_uleb128(pointerof(cursor))'
  # The rules of the whole function, not of the address: a row past it
  # applied.
  prove_broken "a row past the address applied" "a frame at deep.iyi:11" \
    '          loc = loc &+ (op & 0x3f).to_u64 &* code_align
          return true if loc > target' \
    '          loc = loc &+ (op & 0x3f).to_u64 &* code_align'
  # A caller's frame looked up by its return address, which after a call
  # that does not return is the next function's first byte.
  prove_broken "a return address looked up as itself" "a frame at deep.iyi:11" \
    'lookup = first ? pc : pc &- 1_u64' 'lookup = pc'
  # A CFA defined by the frame pointer refused.
  prove_broken "the frame pointer never a CFA base" "a frame at deep.iyi:11" \
    'elsif state[0] == FP_COLUMN && fp_known' 'elsif false' --frame-pointers always
  # A subprogram's high_pc, which DWARF 4 writes as a length, read as the
  # address it ends at: no function holds a frame, and each is named by
  # `.symtab` instead.
  prove_broken "a subprogram's length read as its end" "frames 0 to 2 are gamma, beta and alpha" \
    'finish = high_is_offset ? low &+ high : high' 'finish = high'
  # The name and line of the return address rather than the call.
  prove_broken "the resolver reading the return address" "frames 0 to 2 are gamma, beta and alpha" \
    'addresses << ((frames + i).value.address &- bias &- 1_u64)' 'addresses << ((frames + i).value.address &- bias)'
  echo "  $proofs broken copies"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "std/debug resolves frames, and costs nothing to a program that skips it"
else
  echo "STD DEBUG EXERCISE FAILED"
fi
exit $status
