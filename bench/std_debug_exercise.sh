#!/usr/bin/env bash
# Exercises `std/debug`, the resolver that turns a panic's captured frames into
# `file:line:column` by reading the program's own DWARF.
#
#     bash bench/std_debug_exercise.sh
#
# What it proves, in order:
#
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
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src"

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
