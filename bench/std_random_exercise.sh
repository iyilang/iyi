#!/usr/bin/env bash
# Exercises `std/random`.
#
#     bash bench/std_random_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The negative proofs are patched by python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_random_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/random exercise, plain build"
build_and_run "plain" random-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/random-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every random section reported"
for phrase in "== seed" "== array" "== static array" "== secure" "== bounds" "== seeded draws"; do
  if ! grep -q "$phrase" "$WORK/random-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" random-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/random-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what rand refuses"
# A bound or range that holds no value is a panic that says so, never a
# zero or an end of the range made up. One probe program, the case named
# by its argument.
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/random::{Random}

r = Random.new(1)
case Program.args[0]
when "exclusive" then puts r.rand(5...5)
when "reversed"  then puts r.rand(3_i64..2_i64)
when "zero"      then puts r.rand(0_u64)
when "negative"  then puts r.rand(-4_i64)
when "float"     then puts r.rand(0.0)
when "floats"    then puts r.rand(2.0..1.0)
when "bytes"     then puts Random::Secure.random_bytes(-1).size
end
IYI
if ! "$IYI" build -o "$WORK/refuse" "$WORK/refuse.iyi" >"$WORK/refuse.build" 2>&1; then
  echo "  the probe did not build"
  sed -n '1,10p' "$WORK/refuse.build"
  status=1
else
  for case_name in exclusive reversed zero negative float floats bytes; do
    if "$WORK/refuse" "$case_name" >"$WORK/refuse.out" 2>&1; then
      echo "  $case_name: answered $(cat "$WORK/refuse.out") instead of refusing"
      status=1
    elif ! grep -qE "empty range|negative size" "$WORK/refuse.out"; then
      echo "  $case_name: refused without saying why: $(sed -n '1p' "$WORK/refuse.out")"
      status=1
    else
      echo "  $case_name: $(sed -n '1p' "$WORK/refuse.out" | sed 's/^iyi: panic: //')"
    fi
  done
fi

echo
echo "== the /dev/urandom fallback"
# `Random::Secure` reads /dev/urandom only when `getrandom` answers ENOSYS,
# which no kernel these gates run on does by itself: a seccomp filter makes
# it. `noentropy.py` installs one that answers ENOSYS to `getrandom` and
# allows everything else, then executes the program, which keeps the filter.
# Under it the module as it is must read the device (it is a character
# device, so 32 bytes come back, twice, different). Then a copy of the
# module that differs from it in one line, `URANDOM = "..."` naming a
# regular file full of 'A's, must refuse with a panic that names the file
# for what it is: before the check, it read the file and handed its bytes
# out as random, 4141... The copy is a test of the module, not a mutation,
# and the program has no other way to name the path, so nothing in it can
# be pointed at a file by whoever runs it. Linux only (seccomp, and the
# fallback is Linux's), x86_64 and aarch64, where the filter's syscall
# numbers are known.
cat >"$WORK/noentropy.py" <<'PY'
import ctypes, errno, os, platform, struct, sys
arch = platform.machine()
if arch in ("x86_64", "AMD64"):
    audit, nr = 0xC000003E, 318
elif arch in ("aarch64", "arm64"):
    audit, nr = 0xC00000B7, 278
else:
    print("skip: no getrandom number known for " + arch); sys.exit(3)
# BPF: the architecture, then the call; getrandom answers ENOSYS (38),
# anything else is allowed.
def op(code, jt, jf, k): return struct.pack("HBBI", code, jt, jf, k)
prog = b"".join([
    op(0x20, 0, 0, 4),                   # ld arch
    op(0x15, 0, 3, audit),               # jeq arch, else allow
    op(0x20, 0, 0, 0),                   # ld nr
    op(0x15, 0, 1, nr),                  # jeq getrandom, else allow
    op(0x06, 0, 0, 0x00050000 | 38),     # ret errno ENOSYS
    op(0x06, 0, 0, 0x7FFF0000),          # ret allow
])
buf = ctypes.create_string_buffer(prog, len(prog))
class Fprog(ctypes.Structure):
    _fields_ = [("len", ctypes.c_ushort), ("filter", ctypes.c_void_p)]
fprog = Fprog(len(prog) // 8, ctypes.addressof(buf))
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(38, 1, 0, 0, 0) != 0 or libc.prctl(22, 2, ctypes.byref(fprog), 0, 0) != 0:
    print("skip: seccomp refused: " + os.strerror(ctypes.get_errno())); sys.exit(3)
try:
    os.getrandom(1)
    print("skip: getrandom still answers under the filter"); sys.exit(3)
except OSError as e:
    if e.errno != errno.ENOSYS:
        print("skip: getrandom answered " + str(e)); sys.exit(3)
os.execv(sys.argv[1], sys.argv[1:])
PY
cat >"$WORK/fallback.iyi" <<'IYI'
module fallback

import std/random::{Random}

2.times do
  bytes = Random::Secure.random_bytes(32)
  puts bytes.map { |b| (b.to_i32 < 16 ? "0" : "") + b.to_i32.to_s(16) }.join
end
IYI
printf 'A%.0s' $(seq 1 4096) >"$WORK/not-a-device"
# fallback_build <copy of random.iyi> <label> [device]: the probe built
# over that copy, its `URANDOM` line naming *device* when one is given, as
# $WORK/fallback-<label>. Fails when the line is missing or the build does.
fallback_build() {
  rm -rf "$WORK/devcopy" && mkdir -p "$WORK/devcopy/std"
  "$PY" - "$1" "$WORK/devcopy/std/random.iyi" "${3:-/dev/urandom}" <<'PY' || return 1
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'URANDOM = "/dev/urandom"'
if src.count(old) != 1:
    raise SystemExit("the device's line is missing or not one")
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(src.replace(old, 'URANDOM = "' + sys.argv[3] + '"', 1))
PY
  IYI_PATH="$WORK/devcopy${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/fallback-$2" "$WORK/fallback.iyi" >"$WORK/fallback-$2.build" 2>&1
}
# device_read <label>: under the filter, two draws of 32 bytes, different
# and not all zero - what the device gives.
device_read() {
  "$PY" "$WORK/noentropy.py" "$WORK/fallback-$1" >"$WORK/fallback-$1.out" 2>&1 || return 1
  local first second
  first="$(sed -n '1p' "$WORK/fallback-$1.out")"
  second="$(sed -n '2p' "$WORK/fallback-$1.out")"
  [ "${#first}" -eq 64 ] && [ "$first" != "$second" ] && [ "$first" != "$(printf '0%.0s' $(seq 1 64))" ]
}
# file_refused <label>: under the filter, a panic naming the regular file.
file_refused() {
  "$PY" "$WORK/noentropy.py" "$WORK/fallback-$1" >"$WORK/fallback-$1.out" 2>&1
  grep -qF "$WORK/not-a-device is not a character device" "$WORK/fallback-$1.out"
}
case "$(uname -s)" in
  Linux) fallback_os=yes ;;
  *) fallback_os=no ;;
esac
fallback_ready=no
if [ "$fallback_os" = no ] || [ -z "$PY" ]; then
  echo "  skipped: the fallback and seccomp are Linux's, and this is $(uname -s) (or no python3 to install the filter)"
elif ! fallback_build "$REPO/src/std/random.iyi" device; then
  echo "  the probe did not build"
  sed -n '1,10p' "$WORK/fallback-device.build"
  status=1
else
  "$PY" "$WORK/noentropy.py" /bin/true >"$WORK/noentropy.out" 2>&1
  if [ $? -eq 3 ]; then
    echo "  skipped: $(sed -n '1p' "$WORK/noentropy.out" | sed 's/^skip: //'), so the fallback cannot be reached here"
  else
    fallback_ready=yes
    if device_read device; then
      echo "  getrandom answering ENOSYS under seccomp, /dev/urandom read: two draws of 32 bytes, different"
    else
      echo "  FAIL: getrandom hidden, the device read: $(sed -n '1,2p' "$WORK/fallback-device.out" | tr '\n' ' ')"
      status=1
    fi
    if ! fallback_build "$REPO/src/std/random.iyi" file "$WORK/not-a-device"; then
      echo "  FAIL: the copy naming a regular file could not be made or built"
      sed -n '1,6p' "$WORK/fallback-file.build"
      status=1
    elif file_refused file; then
      echo "  a regular file where the device was: $(grep -m1 'panic' "$WORK/fallback-file.out" | sed 's/^iyi: panic: //' | sed "s|$WORK/||")"
    else
      echo "  FAIL: a regular file where the device was is read: $(sed -n '1p' "$WORK/fallback-file.out")"
      status=1
    fi
  fi
fi

echo
echo "== proving the checks can fail when the module is broken"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  # A bounded draw that answers zero, and the stream taken from the seed
  # rather than from the sequence - which is what this module did, and
  # why a seeded program printed other numbers than the other library's.
  # And any integer's sequence dropped on the way to the generator's own.
  # Then the secure source that answers nothing (every draw the zero the
  # word started as), its bulk path alone doing the same, a draw taken mod
  # the bound with nothing thrown away at 32 and at 64 bits, and an
  # inclusive range that leaves its end out: each must be caught by the
  # check written for it, named by the phrase after the patch.
  for label in bounded stream static any secure bulk bias32 bias64 inclusive; do
    rm -rf "$WORK/patched" && mkdir -p "$WORK/patched/std"
    phrase="$(PROOF="$label" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/random.iyi").read_text()
proofs = {
    "bounded": ("result.unsafe_mod(bound).to_i32", "0", ""),
    "stream": ("@inc = (sequence << 1) | 1_u64", "@inc = (seed << 1) | 1_u64", ""),
    "static": ("    i = N - 1\n", "    i = N - 2\n", ""),
    "any": ("new(seed.to_u64, sequence.to_u64)", "new(seed.to_u64, 0_u64)", ""),
    "secure": ("    return if count == 0\n", "    return\n", "10,000 secure draws hold only"),
    "bulk": ("    Secure.fill(buffer.to_unsafe, buffer.size)\n", "    buffer.size\n", "secure 128-bit tokens repeat"),
    "bias32": ("return result32.unsafe_mod(bound).to_u64 if result32 < limit32 || limit32 == 0_u32",
               "return result32.unsafe_mod(bound).to_u64", "rand(3 * 2^30) is unbiased"),
    "bias64": ("return result.unsafe_mod(n) if result < limit || limit == 0_u64",
               "return result.unsafe_mod(n)", "rand(3 * 2^62) is unbiased"),
    "inclusive": ("      span = span + 1_u64\n    end\n    first &+ below(span).to_u32",
                  "    end\n    first &+ below(span).to_u32", "rand(-3..3) draws each"),
}
old, new, phrase = proofs[os.environ["PROOF"]]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique")
Path("$WORK/patched/std/random.iyi").write_text(src.replace(old, new, 1))
print(phrase)
PY
)"
    if [ $? -ne 0 ]; then
      echo "  $label: the patch did not apply"
      status=1
    elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_random_exercise.iyi" >"$WORK/mut.out" 2>&1; then
      echo "  $label: the exercise PASSED on a broken module"
      status=1
    elif [ -n "$phrase" ] && ! grep -qF -- "$phrase" "$WORK/mut.out"; then
      echo "  $label: failed, but not at the check written for it ($phrase):"
      sed -n '1,3p' "$WORK/mut.out" | sed 's/^/    /'
      status=1
    else
      echo "  $label: caught - $(grep -m1 'panic' "$WORK/mut.out" | sed 's/^iyi: panic: //')"
    fi
  done
  # The fallback's two checks, each broken in a copy: the device's kind
  # not asked (the module before the check), caught where a regular file
  # must be refused; and st_mode read at the other architecture's offset,
  # caught where the real device must still be read.
  if [ "$fallback_ready" = yes ]; then
    for label in unchecked offset; do
      rm -rf "$WORK/patched" && mkdir -p "$WORK/patched/std"
      PROOF="$label" "$PY" - "$REPO/src/std/random.iyi" "$WORK/patched/std/random.iyi" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
old, new = {
    "unchecked": ("      unless character_device?(fd)\n", "      unless true\n"),
    "offset": ("        at = 24\n", "        at = 16\n") if os.uname().machine == "x86_64" else ("        at = 16\n", "        at = 24\n"),
}[os.environ["PROOF"]]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique")
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(src.replace(old, new, 1))
PY
      if [ $? -ne 0 ]; then
        echo "  $label: the patch did not apply"
        status=1
      elif [ "$label" = unchecked ]; then
        if ! fallback_build "$WORK/patched/std/random.iyi" unchecked "$WORK/not-a-device"; then
          echo "  unchecked: the broken copy did not build"
          status=1
        elif file_refused unchecked; then
          echo "  unchecked: a regular file was still refused without the check"
          status=1
        else
          echo "  unchecked: caught at \"a regular file where the device was\" - it read $(sed -n '1p' "$WORK/fallback-unchecked.out" | cut -c1-16)..."
        fi
      else
        if ! fallback_build "$WORK/patched/std/random.iyi" offset; then
          echo "  offset: the broken copy did not build"
          status=1
        elif device_read offset; then
          echo "  offset: the device was still read with st_mode taken from the wrong bytes"
          status=1
        else
          echo "  offset: caught at \"/dev/urandom read\" - $(grep -m1 'panic' "$WORK/fallback-offset.out" | sed 's/^iyi: panic: //')"
        fi
      fi
    done
  else
    echo "  the fallback's proofs: skipped with its section, which could not reach the fallback here"
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/random exercise holds"
else
  echo "the std/random exercise did not hold"
fi
exit $status
