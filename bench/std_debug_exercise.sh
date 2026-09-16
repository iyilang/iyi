#!/usr/bin/env bash
# Exercises `std/debug`, the resolver that turns a panic's captured frames into
# `file:line:column` by reading the program's own DWARF.
#
#     bash bench/std_debug_exercise.sh
#
# What it proves, in order:
#
#   Darwin:
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
#   Linux (ELF reader not yet built):
#   1. `import std/debug` still compiles and runs.
#   2. A panic with the import does not grow `file:line:column` frames; the
#      prelude's raise does not capture a backtrace on Linux, so the hook is
#      never invoked.
#   3. Invoking the installed hook dumps hex PCs, not source locations.
#   4. The program does not leave `write` (or Darwin dyld symbols) undefined.
#      `say` goes through `__iyi_write` (a syscall on Linux). A patched copy
#      that binds `LibC.write` is refused, so the check has teeth.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src"

case "$(uname -s)" in
  Darwin) PLATFORM=darwin ;;
  Linux) PLATFORM=linux ;;
  *)
    echo "std/debug: Darwin Mach-O/DWARF resolver (Linux ELF and Windows PE not yet built)"
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
forbidden_undef() {
  nm -u "$1" 2>/dev/null | grep -E ' (write|dladdr|_NSGetExecutablePath|_dyld_get_image_vmaddr_slide)$'
}

# ── Linux: compile, refuse a fake DWARF resolution, keep the syscall write
if [ "$PLATFORM" = linux ]; then
  cat > "$WORK/imp.iyi" <<'EOF'
module imp

import std/debug

print "ok\n"
EOF

  echo "== import std/debug compiles and runs"
  if ! "$IYI" build -o "$WORK/imp" "$WORK/imp.iyi" > "$WORK/imp.build" 2>&1; then
    echo "  build failed"
    sed 's/^/    /' "$WORK/imp.build"
    exit 1
  fi
  "$WORK/imp" > "$WORK/imp.out" 2>&1
  grep -q "^ok$" "$WORK/imp.out" || fail "import ran but did not print ok"
  platform_libc_only "$WORK/imp" "the imported program"
  if forbidden_undef "$WORK/imp" | grep -q .; then
    fail "import leaves a Darwin/libc symbol undefined:"
    forbidden_undef "$WORK/imp" | sed 's/^/    /'
  fi

  cat > "$WORK/boom.iyi" <<'EOF'
module boom

import std/debug

raise "boom"
EOF

  echo "== a panic with the import still has no DWARF frames"
  if "$IYI" build -o "$WORK/boom" "$WORK/boom.iyi" > "$WORK/boom.build" 2>&1; then
    "$WORK/boom" > "$WORK/boom.out" 2>&1
    boom_code=$?
    sed 's/^/  /' "$WORK/boom.out"
    [ "$boom_code" -ne 0 ] || fail "a panicking program exited 0"
    grep -q "^iyi: panic: boom" "$WORK/boom.out" || fail "the message is not the first line"
    grep -q "\.iyi:[0-9]*:[0-9]*" "$WORK/boom.out" \
      && fail "Linux panic grew a file:line:column frame; the ELF reader is not built"
  else
    echo "  build failed"
    sed 's/^/    /' "$WORK/boom.build"
    status=1
  fi

  cat > "$WORK/hook.iyi" <<'EOF'
module hook

import std/debug

slot = Pointer(Void).new(0x401000_u64)
if r = IyiPanic.resolver
  r.call(pointerof(slot).as(Pointer(Void*)), 1)
else
  print "hook-nil\n"
end
EOF

  echo "== the installed hook dumps hex, not file:line:column"
  if "$IYI" build -o "$WORK/hook" "$WORK/hook.iyi" > "$WORK/hook.build" 2>&1; then
    "$WORK/hook" > "$WORK/hook.out" 2>&1
    sed 's/^/  /' "$WORK/hook.out"
    grep -q "\[0x401000\]" "$WORK/hook.out" || fail "the Linux fallback did not dump the PC"
    grep -q "\.iyi:[0-9]*:[0-9]*" "$WORK/hook.out" \
      && fail "the Linux fallback resolved a column anyway"
    grep -q "hook-nil" "$WORK/hook.out" && fail "import did not install the panic hook"
  else
    echo "  build failed"
    sed 's/^/    /' "$WORK/hook.build"
    status=1
  fi

  echo "== proving the write check fails when say binds LibC.write"
  mkdir -p "$WORK/bad/std"
  python3 - "$REPO/src/std/debug.iyi" "$WORK/bad/std/debug.iyi" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
t = t.replace("{% if flag?(:darwin) %}\n", "", 1)
t = t.replace("{% end %}\n\nstruct DwarfResolver", "\nstruct DwarfResolver", 1)
t = t.replace("n = __iyi_write(", "n = LibC.write(", 1)
open(dst, "w").write(t)
PY
  cat > "$WORK/badprog.iyi" <<'EOF'
module badprog

import std/debug

print "ok\n"
EOF
  if IYI_PATH="$WORK/bad:$REPO/src" "$IYI" build -o "$WORK/badprog" "$WORK/badprog.iyi" \
       > "$WORK/badprog.build" 2>&1; then
    if forbidden_undef "$WORK/badprog" | grep -q ' write$'; then
      echo "  a LibC.write copy leaves write undefined, so the check has teeth"
    else
      fail "a module that binds LibC.write passed the write check"
      forbidden_undef "$WORK/badprog" | sed 's/^/    /'
    fi
  else
    echo "  patched copy failed to build"
    sed 's/^/    /' "$WORK/badprog.build"
    status=1
  fi

  echo
  if [ "$status" -eq 0 ]; then
    echo "std/debug imports on Linux, dumps hex, and does not bind libc write"
  else
    echo "STD DEBUG EXERCISE FAILED"
  fi
  exit $status
fi

# ── 1. a panic several calls deep, with the call sites on known lines
#
# Written so the line numbers are stated here rather than discovered: the raise
# is line 7, and the three callers are lines 11, 15 and 18.
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
grep -q "^iyi: panic: boom" "$WORK/deep.out" || fail "the message is not the first line"

for line in 6 11 15 18; do
  grep -q "deep.iyi:$line" "$WORK/deep.out" \
    || fail "no frame at deep.iyi:$line, and that is a known call site"
done
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

echo
if [ "$status" -eq 0 ]; then
  echo "std/debug resolves frames, and costs nothing to a program that skips it"
else
  echo "STD DEBUG EXERCISE FAILED"
fi
exit $status
