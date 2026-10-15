#!/usr/bin/env bash
# Exercises `std/system`.
#
#     bash bench/std_system_exercise.sh
#
# The exercise checks what it can know on its own; this gate hands it what
# other programs answer for the same machine - Python's
# `socket.gethostname()`, `len(os.sched_getaffinity(0))` and
# `os.sysconf('SC_PAGE_SIZE')`, then `uname -n`, `nproc` and
# `getconf PAGESIZE` - runs it held to fewer CPUs with `taskset`, and
# proves on patched copies of the module that the fallbacks answer and
# that each check fails when the code it watches is broken.
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

# The oracle and the negative proofs are python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

LINUX=0
[ "$(uname -s)" = Linux ] && LINUX=1

# `taskset` proven to run, as python is: a container can ship the binary
# and refuse `sched_setaffinity` to it.
TASKSET=0
if [ "$LINUX" -eq 1 ] && command -v taskset >/dev/null 2>&1 && taskset -c 0 true >/dev/null 2>&1; then
  TASKSET=1
fi

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
EXERCISE="$REPO/bench/std_system_exercise.iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$EXERCISE" >"$WORK/$name.build.log" 2>&1; then
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
  if ! grep -q "ALL CHECKS PASSED" "$WORK/$name.out"; then
    echo "$label: missing pass sentinel"
    status=1
    return 1
  fi
  return 0
}

# What Python answers, one line each: the hostname, the CPUs this process
# may run on, the CPUs online, the page size, and the CPU list `taskset`
# pins to below - the first and third CPUs of the mask when it holds three,
# the second alone when it holds two - with the count Python sees under
# that pin. A pin of two CPUs that are not neighbours is what tells a count
# of bits from a count of positions up to the highest.
PY_HOST="" PY_CPUS="" PY_ONLINE="" PY_PAGE="" PIN="" PIN_CPUS=""
if [ -n "$PY" ]; then
  "$PY" - >"$WORK/oracle" <<'PY'
import mmap, os, socket
mask = sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else []
print(socket.gethostname())
print(len(mask) if mask else os.cpu_count())
print(os.cpu_count())
# Windows' Python has no sysconf; mmap's PAGESIZE is the page there too.
print(os.sysconf("SC_PAGE_SIZE") if hasattr(os, "sysconf") else mmap.PAGESIZE)
if len(mask) >= 3:
    print("%d,%d" % (mask[0], mask[2]))
elif len(mask) == 2:
    print(mask[1])
else:
    print("")
PY
  PY_HOST="$(sed -n 1p "$WORK/oracle")"
  PY_CPUS="$(sed -n 2p "$WORK/oracle")"
  PY_ONLINE="$(sed -n 3p "$WORK/oracle")"
  PY_PAGE="$(sed -n 4p "$WORK/oracle")"
  PIN="$(sed -n 5p "$WORK/oracle")"
  if [ "$TASKSET" -eq 1 ] && [ -n "$PIN" ]; then
    PIN_CPUS="$(taskset -c "$PIN" "$PY" -c 'import os; print(len(os.sched_getaffinity(0)))')"
  fi
fi

# The exercise with Python's answers to compare against.
run_against_python() { # run_against_python <binary> <output> [taskset list] [cpus]
  local binary="$1" output="$2" pin="${3:-}" cpus="${4:-$PY_CPUS}"
  if [ -n "$pin" ]; then
    SYSTEM_EXPECT_HOSTNAME="$PY_HOST" SYSTEM_EXPECT_CPUS="$cpus" SYSTEM_EXPECT_PAGE_SIZE="$PY_PAGE" \
      taskset -c "$pin" "$binary" >"$output" 2>&1
  else
    SYSTEM_EXPECT_HOSTNAME="$PY_HOST" SYSTEM_EXPECT_CPUS="$cpus" SYSTEM_EXPECT_PAGE_SIZE="$PY_PAGE" \
      "$binary" >"$output" 2>&1
  fi
}

echo "== the std/system exercise, plain build"
build_and_run "plain" system-plain

echo
echo "== every system section reported"
for phrase in "== hostname" "== cpu count" "== page size" "== another program agrees"; do
  if ! grep -q "$phrase" "$WORK/system-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" system-release --release >/dev/null && echo "  passed"

echo
echo "== Python agrees: socket.gethostname(), sched_getaffinity(0), sysconf('SC_PAGE_SIZE')"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3"
else
  for build in plain release; do
    if run_against_python "$WORK/system-$build" "$WORK/py-$build.out" && grep -q "ALL CHECKS PASSED" "$WORK/py-$build.out"; then
      echo "  $build: $(grep -E '^  (hostname|cpu_count|page_size) ' "$WORK/py-$build.out" | sed 's/^  //' | tr '\n' ' ')"
    else
      echo "  $build: disagrees with Python"
      sed 's/^/    /' "$WORK/py-$build.out"
      status=1
    fi
  done
fi

echo
echo "== the system's own tools agree: uname -n, nproc, getconf PAGESIZE"
if [ "$LINUX" -eq 1 ] && command -v nproc >/dev/null 2>&1 && command -v getconf >/dev/null 2>&1; then
  # `nproc` counts the affinity mask, as `cpu_count` does; `nproc --all`
  # would be the machine's.
  if SYSTEM_EXPECT_HOSTNAME="$(uname -n)" SYSTEM_EXPECT_CPUS="$(nproc)" SYSTEM_EXPECT_PAGE_SIZE="$(getconf PAGESIZE)" \
       "$WORK/system-plain" >"$WORK/tools.out" 2>&1 && grep -q "ALL CHECKS PASSED" "$WORK/tools.out"; then
    echo "  $(uname -n), $(nproc) CPUs, $(getconf PAGESIZE)-byte pages"
  else
    echo "  disagrees with the system's tools"
    sed 's/^/    /' "$WORK/tools.out"
    status=1
  fi
else
  echo "  skipped: not Linux, or no nproc/getconf"
fi

echo
echo "== cpu_count follows the affinity mask (taskset)"
if [ "$TASKSET" -eq 0 ] || [ -z "$PY" ]; then
  echo "  skipped: no working taskset or python3"
else
  for pin in 0 ${PIN:+"$PIN"}; do
    want="$(taskset -c "$pin" "$PY" -c 'import os; print(len(os.sched_getaffinity(0)))')"
    if run_against_python "$WORK/system-plain" "$WORK/pin.out" "$pin" "$want" && grep -q "ALL CHECKS PASSED" "$WORK/pin.out"; then
      echo "  taskset -c $pin: cpu_count $(grep -m1 '^  cpu_count ' "$WORK/pin.out" | sed 's/^  cpu_count //'), Python $want"
    else
      echo "  taskset -c $pin: cpu_count did not follow the mask (Python counts $want)"
      sed 's/^/    /' "$WORK/pin.out"
      status=1
    fi
  done
fi

# A copy of the module with each (old, new) pair applied once, every old
# text required to be in it exactly once, into $WORK/patched/std.
patch_copy() { # patch_copy <old> <new> [<old> <new> ...]
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  "$PY" - "$@" <<PY
import sys
from pathlib import Path
src = Path("$REPO/src/std/system.iyi").read_text()
pairs = sys.argv[1:]
for old, new in zip(pairs[0::2], pairs[1::2]):
    if src.count(old) != 1:
        raise SystemExit("patch site missing or not unique: " + old)
    src = src.replace(old, new, 1)
Path("$WORK/patched/std/system.iyi").write_text(src)
PY
}

patched_build=0
# Builds the exercise against the patched copy into $PATCHED_BIN, a binary
# of its own each time: on Windows the last one's file can still be held a
# moment after it ended, and a link over it fails.
build_patched() {
  patched_build=$((patched_build + 1))
  PATCHED_BIN="$WORK/patched-$patched_build.bin"
  IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" \
    "$IYI" build -o "$PATCHED_BIN" "$EXERCISE" >"$WORK/patched.build" 2>&1
}

# The forced fallback: `sched_getaffinity` answered as refused.
NO_AFFINITY=("count = affinity_count
" "count = 0
")

echo
echo "== the fallbacks answer (patched copies that must still pass)"
if [ "$LINUX" -eq 0 ] || [ -z "$PY" ]; then
  echo "  skipped: the fallbacks are Linux's, and the copies are patched by python3"
else
  # sched_getaffinity refused: the online count, which is what glibc's
  # get_nprocs and so Python's os.cpu_count() answer.
  if ! patch_copy "${NO_AFFINITY[@]}" || ! build_patched; then
    echo "  online fallback: the patched copy did not build"
    sed -n '1,6p' "$WORK/patched.build"
    status=1
  elif run_against_python "$PATCHED_BIN" "$WORK/fallback.out" "" "$PY_ONLINE" && grep -q "ALL CHECKS PASSED" "$WORK/fallback.out"; then
    echo "  sched_getaffinity refused: cpu_count $PY_ONLINE, os.cpu_count() $PY_ONLINE"
  else
    echo "  sched_getaffinity refused: the online count is not os.cpu_count() ($PY_ONLINE)"
    sed 's/^/    /' "$WORK/fallback.out"
    status=1
  fi
  # A first buffer smaller than the kernel's mask: -EINVAL, and the
  # buffer grows until it fits.
  if ! patch_copy "bytes = 128
" "bytes = 2
" || ! build_patched; then
    echo "  mask growth: the patched copy did not build"
    sed -n '1,6p' "$WORK/patched.build"
    status=1
  elif run_against_python "$PATCHED_BIN" "$WORK/growth.out" && grep -q "ALL CHECKS PASSED" "$WORK/growth.out"; then
    echo "  a 2-byte first mask: grown to fit, cpu_count $PY_CPUS"
  else
    echo "  a 2-byte first mask: not grown to fit"
    sed 's/^/    /' "$WORK/growth.out"
    status=1
  fi
fi

echo
echo "== what is refused, and the sentence it is refused with"
# A kernel that answers neither source is a panic naming both, never a
# count made up; a Linux without /proc/self/auxv the same for the page.
refuses() { # refuses <label> <sentence> <old> <new> [<old> <new> ...]
  local label="$1" sentence="$2"
  shift 2
  if ! patch_copy "$@" || ! build_patched; then
    echo "  $label: the patched copy did not build"
    sed -n '1,6p' "$WORK/patched.build"
    status=1
  elif "$PATCHED_BIN" >"$WORK/refuse.out" 2>&1; then
    echo "  $label: answered instead of refusing"
    status=1
  elif ! grep -qxF "iyi: panic: $sentence" "$WORK/refuse.out"; then
    echo "  $label: refused with another sentence:"
    sed -n '1,3p' "$WORK/refuse.out" | sed 's/^/    /'
    status=1
  else
    echo "  $label: $sentence"
  fi
}
if [ "$LINUX" -eq 0 ] || [ -z "$PY" ]; then
  echo "  skipped: the refusals are Linux's, and the copies are patched by python3"
else
  refuses "no affinity, no /sys" \
    "System.cpu_count: the kernel answered neither sched_getaffinity nor /sys/devices/system/cpu/online" \
    "${NO_AFFINITY[@]}" 'read_small("/sys/devices/system/cpu/online")' 'read_small("/sys/devices/system/cpu/no-such-file")'
  refuses "no auxiliary vector" \
    "System.page_size: /proc/self/auxv holds no AT_PAGESZ" \
    'read_small("/proc/self/auxv")' 'read_small("/proc/self/no-such-file")'
fi

echo
echo "== proving the checks can fail when the module is broken"
mutations=0
# prove_broken <label> <phrase> <how> <old> <new> [<old> <new> ...]: <how>
# is `python` (Python's answers, unpinned), `pinned` (held to $PIN with
# the count Python sees there) or `online` (Python's online count).
prove_broken() {
  local label="$1" phrase="$2" how="$3"
  shift 3
  mutations=$((mutations + 1))
  if ! patch_copy "$@"; then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi
  # Build first, then run: a patch that does not compile would also
  # "fail", and that proves nothing about whether the exercise catches it.
  if ! build_patched; then
    echo "  $label: the broken copy did not compile"
    sed -n '1,6p' "$WORK/patched.build"
    status=1
    return
  fi
  case "$how" in
    pinned) run_against_python "$PATCHED_BIN" "$WORK/mut.out" "$PIN" "$PIN_CPUS" ;;
    online) run_against_python "$PATCHED_BIN" "$WORK/mut.out" "" "$PY_ONLINE" ;;
    *) run_against_python "$PATCHED_BIN" "$WORK/mut.out" ;;
  esac
  if [ $? -eq 0 ]; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF -- "$phrase" "$WORK/mut.out"; then
    echo "  $label: failed, but not at the check that names '$phrase':"
    sed -n '1,4p' "$WORK/mut.out" | sed 's/^/    /'
    status=1
  else
    echo "  $label: caught - $(grep -m1 'ASSERTION FAILED' "$WORK/mut.out" | sed 's/^iyi: panic: ASSERTION FAILED: //')"
  fi
}
if [ "$LINUX" -eq 0 ] || [ -z "$PY" ]; then
  echo "  skipped: the patched code is Linux's, and the copies are patched by python3"
else
  # uname's sysname ("Linux") read where the nodename is.
  prove_broken "the sysname for the nodename" "hostname is /proc/sys/kernel/hostname" python \
    'c_text(buffer + 65_i64, 65)' 'c_text(buffer, 65)'
  # The name taken to the end of its field, NULs and all.
  prove_broken "a name not cut at its NUL" "hostname holds no NUL" python \
    'while length < limit && text[length] != 0_u8' 'while length < limit'
  # The page's tag mistaken for AT_PHNUM's.
  prove_broken "AT_PHNUM read as the page size" "page_size is at least 4 KiB" python \
    'AT_PAGESZ = 6_u64' 'AT_PAGESZ = 5_u64'
  # A fallback that counts the CPUs a range spans one short.
  if grep -q -- - /sys/devices/system/cpu/online 2>/dev/null; then
    prove_broken "an online range counted one short" "cpu_count is what Python counts" online \
      "${NO_AFFINITY[@]}" 'count = count + (last - first + 1)' 'count = count + (last - first)'
  else
    echo "  an online range counted one short: skipped, /sys/devices/system/cpu/online holds no range"
  fi
  if [ "$TASKSET" -eq 0 ] || [ -z "$PIN" ]; then
    echo "  the affinity proofs: skipped, they need taskset and two CPUs to pin to"
  else
    # The machine's online count where the process's mask was asked for.
    prove_broken "the online count for the mask" "cpu_count is what Python counts" pinned \
      "${NO_AFFINITY[@]}"
    # Every position up to the highest set bit counted, not the set bits.
    prove_broken "positions counted for bits" "cpu_count is what Python counts" pinned \
      'count = count + (word & 1_u64).to_i32' 'count = count + 1'
    # A first buffer too small, and -EINVAL taken as a refusal.
    prove_broken "a mask buffer never grown" "cpu_count is what Python counts" pinned \
      "bytes = 128
" "bytes = 2
" 'return 0 if got != -22_i64' 'return 0'
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/system exercise holds"
else
  echo "the std/system exercise did not hold"
fi
exit $status
