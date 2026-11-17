#!/usr/bin/env bash
# Native proof of the Windows path and IyiIO observation boundaries.
# bash bench/stale_win_paths.sh
set -euo pipefail

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *) echo 'windows-only: Win32 path resolution and handle probes require Windows'; exit 0 ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/.build/iyi.exe}"
[ -x "$IYI" ] || { echo "stale_win_paths: compiler not found at $IYI" >&2; exit 1; }
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(sys.platform != "win32")' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
[ -n "$PY" ] || { echo 'stale_win_paths: native Windows Python is required' >&2; exit 1; }

WORK="$(mktemp -d /tmp/iyi-stale-win-paths.XXXXXX)"
cleanup() {
  status=$?
  if [ "$status" -eq 0 ]; then
    rm -rf "$WORK"
  else
    echo "stale_win_paths: preserving failed run at $WORK" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$WORK/scratch" "$WORK/cache"
NATIVE_REPO="$(cygpath -m "$REPO")"
NATIVE_WORK="$(cygpath -m "$WORK")"
NATIVE_IYI="$(cygpath -m "$IYI")"
export IYI_PATH="$NATIVE_REPO/src;$NATIVE_REPO/samples/iyi"
export IYI_LIBRARY_PATH="$NATIVE_REPO/lib"
export IYI_CACHE_DIR="$NATIVE_WORK/cache"

"$NATIVE_IYI" build -Diyi_observe -o "$NATIVE_WORK/probe.exe" \
  "$NATIVE_REPO/bench/stale_win_paths.iyi" >"$WORK/build.log" 2>&1 || {
  cat "$WORK/build.log" >&2
  exit 1
}

"$PY" - "$NATIVE_WORK" "$NATIVE_WORK/probe.exe" <<'PY'
import ntpath
import os
from pathlib import Path
import struct
import subprocess
import sys

work, exe = sys.argv[1:]
scratch = os.path.join(work, "scratch")
first = os.path.join(scratch, "drive-cwd-a")
second = os.path.join(scratch, "drive-cwd-b")
os.makedirs(first, exist_ok=True)
os.makedirs(second, exist_ok=True)
probe_file = os.path.join(scratch, "stream.txt")
Path(probe_file).write_bytes(b"stale path probe\n")
drive, _ = ntpath.splitdrive(scratch)
if len(drive) != 2 or drive[1] != ":":
    raise SystemExit(f"stale_win_paths: scratch must have a drive letter, got {scratch!r}")
if len(scratch) >= 190:
    raise SystemExit(f"stale_win_paths: scratch path is too long for the short-path control: {scratch!r}")

sequence = 0

def read_trace(path):
    data = Path(path).read_bytes()
    offset = 0
    records = []
    taints = []
    while offset < len(data):
        if offset + 4 > len(data):
            raise AssertionError("truncated trace header")
        size, = struct.unpack_from("<I", data, offset)
        offset += 4
        if size < 9 or offset + size > len(data):
            raise AssertionError("truncated or malformed trace record")
        record = data[offset:offset + size]
        offset += size
        kind = record[0]
        records.append(kind)
        if kind == 8:
            if len(record) < 14:
                raise AssertionError("truncated taint record")
            length, = struct.unpack_from("<I", record, 10)
            if len(record) != 14 + length:
                raise AssertionError("malformed taint site")
            taints.append((record[9], record[14:].decode("utf-8")))
        elif kind == 0x7f:
            if len(record) != 13 or struct.unpack_from("<i", record, 9)[0] != 0:
                raise AssertionError("trace did not end with END(0)")
            if offset != len(data):
                raise AssertionError("trace has records after END")
    if not records or records[-1] != 0x7f:
        raise AssertionError("trace is missing END(0)")
    return taints

def run(label, mode, arguments=(), cwd=scratch, expected=None, host_state=False, site=None):
    global sequence
    sequence += 1
    trace = os.path.join(work, f"trace-{sequence}.bin")
    env = os.environ.copy()
    env.update(IYI_OBSERVE=trace, TMPDIR=scratch, TEMP=scratch, TMP=scratch)
    result = subprocess.run([exe, mode, *arguments], cwd=cwd, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    stdout = result.stdout.decode("utf-8", errors="replace").strip()
    stderr = result.stderr.decode("utf-8", errors="replace").strip()
    if result.returncode != 0:
        raise AssertionError(f"{label}: exit {result.returncode}, stdout={stdout!r}, stderr={stderr!r}")
    if expected is not None:
        if mode == "path":
            if not stdout.startswith("PATH:") or ntpath.normcase(stdout[5:]) != ntpath.normcase(expected):
                raise AssertionError(f"{label}: expected PATH:{expected!r}, got {stdout!r}")
        elif mode == "drive-change":
            actual = stdout.splitlines()
            wanted = ["FIRST:" + expected[0], "SECOND:" + expected[1]]
            if len(actual) != 2 or any(ntpath.normcase(a) != ntpath.normcase(b) for a, b in zip(actual, wanted)):
                raise AssertionError(f"{label}: expected {wanted!r}, got {actual!r}")
        elif stdout != expected:
            raise AssertionError(f"{label}: expected {expected!r}, got {stdout!r}")
    taints = read_trace(trace)
    if host_state:
        if len(taints) != 1 or taints[0][0] != 41 or (site and not taints[0][1].startswith(site)):
            raise AssertionError(f"{label}: expected host_state at {site}, got {taints!r}")
    elif taints:
        raise AssertionError(f"{label}: expected no taint, got {taints!r}")
    print(f"  {label}: {'host_state' if host_state else 'no taint'}")
    return stdout

prelude = "toolchain:iyi/prelude.iyi:"
io = "toolchain:iyi/io.iyi:"
short_absolute = ntpath.join(scratch, "unicode-ü-字.txt")
tail = "\\".join(["longcomponent"] * 23 + ["leaf.txt"])
long_absolute = drive + "\\" + tail
expected_long = "\\\\?\\" + ntpath.normpath(long_absolute)
if len(short_absolute) >= 248 or len(long_absolute) < 248:
    raise AssertionError("short and long path controls do not straddle the limit")

print("== fixed UTF-8 conversion and fully qualified paths")
run("short absolute UTF-8", "path", (short_absolute,), expected=short_absolute)
run("long drive-absolute", "path", (long_absolute,), cwd=first, expected=expected_long)
run("same absolute after cwd change", "path", (long_absolute,), cwd=second, expected=expected_long)
run("invalid UTF-8", "invalid", expected="INVALID:refused")

print("== cwd-dependent and conservative paths")
run("short relative negative control", "path", ("relative.txt",), expected="relative.txt", host_state=True, site=prelude)
# `splitdrive` returns the drive with its colon already: `C:` + tail is the
# drive-relative `C:longcomponent\...`, and adding another colon made `C::...`.
relative = drive + tail
expected_first = "\\\\?\\" + ntpath.normpath(ntpath.join(first, tail))
expected_second = "\\\\?\\" + ntpath.normpath(ntpath.join(second, tail))
if ntpath.normcase(expected_first) == ntpath.normcase(expected_second):
    raise AssertionError("per-drive cwd controls do not differ")
run("drive-relative cwd A", "path", (relative,), cwd=first, expected=expected_first, host_state=True, site=prelude)
run("drive-relative cwd B", "path", (relative,), cwd=second, expected=expected_second, host_state=True, site=prelude)
run("drive-relative changes within one process", "drive-change", (first, second, relative),
    expected=(expected_first, expected_second), host_state=True, site=prelude)
root_relative = "\\" + tail
run("current-drive-rooted", "path", (root_relative,), expected=expected_long, host_state=True, site=prelude)
unc = "\\\\server\\share\\" + tail
run("long UNC", "path", (unc,), expected="\\\\?\\UNC\\server\\share\\" + tail, host_state=True, site=prelude)
device = "\\\\?\\" + drive + "\\" + tail
run("long device path", "path", (device,), expected=device, host_state=True, site=prelude)

print("== standard and nonstandard handles")
run("fd 0, 1 and 2", "streams", expected="STREAMS:ok")
# A disk file asks the host nothing: whether it is a console is answered by its
# type, which the observed open and metadata already fix. A character device
# (a console, NUL) asks the console subsystem and is host state; that arm is
# reached only through a device path, which the prelude already refuses at its
# unproven path resolution, so no probe reaches it separately.
run("nonstandard disk file handle", "file", (probe_file,), expected="FILE:ok")
print("stale_win_paths: all native trace checks passed")
PY
