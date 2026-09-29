#!/usr/bin/env bash
# Exercises IyiIO: flush, short reads, buffer boundaries, EOF, and puts.
#
#     bash bench/io_exercise.sh
#
# Follows the house style: exercises the stream abstraction plain and with
# --release, and proves each check can fail by breaking the mechanism in a
# patched copy of the library.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs whatever compiler the caller names; `bin/iyi` is a shell
# wrapper, and on Windows the caller has to point at the built exe itself.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` on it is silently ignored, so the patched
# copy is never read and the proof that a check can fail quietly stops
# proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

status=0

run_case() {
  local label="$1" name="$2"
  shift 2
  echo "== $label"
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/io_exercise.iyi" >"$WORK/$name.build.log" 2>&1; then
    echo "  $label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return
  fi
  # From the scratch directory, because the program writes its two files
  # into the working one: run from the repository they landed in the
  # repository, and two of them were committed before anybody noticed.
  (cd "$WORK" && "$WORK/$name") </dev/null >"$WORK/$name.out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    echo "  $label: failed with exit code $exit_code"
    sed -n '$p' "$WORK/$name.out"
    status=1
    return
  fi
  if ! grep -q "all io checks passed" "$WORK/$name.out"; then
    echo "  $label: did not reach all io checks passed"
    status=1
    return
  fi
  # Every line the program prints is a check's, and its last one ends in
  # a newline already: an empty line is `puts` ending it twice.
  if grep -q '^$' "$WORK/$name.out"; then
    echo "  $label: standard output has an empty line: puts ended a line that had ended"
    status=1
    return
  fi
  echo "  $label: all io checks passed"
}

run_case "the exercise, plain build" io-plain
echo
run_case "the same program with optimisation on" io-release --release

echo
echo "== the checks fail when the mechanism is broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  awk "$script" "$REPO/src/iyi/io.iyi" > "$WORK/$dir/iyi/io.iyi"
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/io_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched library did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  (cd "$WORK/$dir" && "$WORK/$dir/program") </dev/null >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! tr -d '\0' < "$WORK/$dir/out" | grep -q "$phrase"; then
    echo "  $label: failed, but not at the expected check ($phrase)"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(tr -d '\0' < "$WORK/$dir/out" | grep -m1 "$phrase" | sed 's/^iyi: panic: //')"
}

# 1. Flush broken: flush is a no-op so unflushed write never reaches disk
prove_fails "flush check fails" noflush "flush:" \
  '{ sub(/def flush : Nil/, "def flush : Nil\n    return"); print }'

# 2. Short reads broken: bytes in read_bytes corrupted
prove_fails "short reads fail" noshort "short_reads:" \
  '{ sub(/target\.copy_from\(result_buf, total_read\)/, "target[0] = 63_u8"); print }'

# 3. Buffer boundary broken: take count in multi-buffer read_line corrupted
prove_fails "read across buffer boundary fails" noboundary "buffer_boundary:" \
  '{ if ($0 ~ /take = found_idx - @read_pos \+ 1/) { print "take = 1"; next } print }'

# 4. EOF check broken: eof? always returns false
prove_fails "eof check fails" noeof "eof:" \
  '{ sub(/def eof\? : Bool/, "def eof? : Bool\n    return false"); print }'

# 4b. read_all through the stream's buffer again, a buffer at a time
case "$(uname -s)" in
  Linux)
    prove_fails "read_all a buffer at a time fails" noread_all "read_all:" \
      '{ if ($0 ~ /got = low_level_read\(@fd, \(buffer \+ filled\).as\(Void\*\), \(capacity - filled\).to_u64\)/) { print "      got = low_level_read(@fd, (buffer + filled).as(Void*), 4096_u64)"; next } print }'
    ;;
esac

# 5. puts ends every line, ended or not
prove_fails "puts ending an ended line fails" noends "puts:" \
  '{ if ($0 ~ /text.bytesize > 0 && text.to_unsafe\[text.bytesize - 1\] == 10_u8 \? write\(text\) : write_line\(text\)/) { print "    write_line(text)"; next } print }'

# 6. A real console, which a pipe is not: typed keys, read wide. A
#    program reading to the end of its input could not be ended from the
#    keyboard - Ctrl+Z then Enter, the end of input to the C runtime,
#    Python, Go and Rust, was read as a line holding 0x1A - and a line
#    longer than one read lost the character whose surrogate pair the read
#    split, as two U+FFFD. Driven from Python: the program gets a console
#    of its own, and keys are written into it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    PY=""
    for candidate in python3 python; do
      if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
        PY="$candidate"; break
      fi
    done
    echo
    echo "== a console's end of input and its long lines"
    printf 'module main\n\nwhile line = STDIN.gets(true)\n  puts "got #{line.bytesize}"\nend\nputs "the end of input"\nsleep(3000)\n' > "$WORK/console.iyi"
    if [ -z "$PY" ]; then
      echo "  no python3 on this machine, so the console is unmeasured"
    elif ! "$IYI" build -o "$WORK/console" "$WORK/console.iyi" > "$WORK/console.build" 2>&1; then
      echo "  the console program did not build"; sed -n '1,10p' "$WORK/console.build"; status=1
    else
      "$PY" - "$WORK/console.exe" > "$WORK/console.out" 2>&1 <<'PY'
import ctypes, subprocess, sys, time
from ctypes import wintypes
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.CreateFileW.restype = wintypes.HANDLE
class KEY(ctypes.Structure):
    _fields_ = [("down", wintypes.BOOL), ("repeat", wintypes.WORD), ("vk", wintypes.WORD),
                ("scan", wintypes.WORD), ("char", wintypes.WCHAR), ("state", wintypes.DWORD)]
class RECORD(ctypes.Structure):
    class U(ctypes.Union):
        _fields_ = [("key", KEY), ("pad", ctypes.c_byte * 16)]
    _fields_ = [("kind", wintypes.WORD), ("event", U)]
def keys(handle, text):
    units = text.encode("utf-16-le")
    records = []
    for i in range(0, len(units), 2):
        unit = units[i:i + 2].decode("utf-16-le", "surrogatepass")
        for down in (1, 0):
            r = RECORD(); r.kind = 1
            r.event.key.down = down; r.event.key.repeat = 1
            r.event.key.vk = 0x0D if unit == "\r" else 0
            r.event.key.char = unit
            records.append(r)
    written = wintypes.DWORD()
    array = (RECORD * len(records))(*records)
    if not k32.WriteConsoleInputW(handle, array, len(records), ctypes.byref(written)):
        raise SystemExit(f"WriteConsoleInputW: {ctypes.get_last_error()}")
info = subprocess.STARTUPINFO(); info.dwFlags = 1; info.wShowWindow = 0
child = subprocess.Popen([sys.argv[1]], creationflags=0x10, startupinfo=info)
time.sleep(1.5)
k32.FreeConsole()
if not k32.AttachConsole(child.pid):
    child.kill(); print(f"UNMEASURED: AttachConsole {ctypes.get_last_error()}"); sys.exit(0)
conin = k32.CreateFileW("CONIN$", 0xC0000000, 3, None, 3, 0, None)
conout = k32.CreateFileW("CONOUT$", 0xC0000000, 3, None, 3, 0, None)
keys(conin, "a" * 1364 + "\U0001F600" + "\r"); time.sleep(0.7)
keys(conin, "\x1a\r"); time.sleep(1.0)
lines, row = [], ctypes.create_unicode_buffer(120)
for y in range(40):
    n = wintypes.DWORD()
    k32.ReadConsoleOutputCharacterW(conout, row, 120, wintypes.DWORD(y << 16), ctypes.byref(n))
    lines.append(row.value[:n.value].rstrip())
k32.FreeConsole()
try:
    child.wait(timeout=10)
except subprocess.TimeoutExpired:
    child.kill()
print("\n".join(line for line in lines if line.startswith(("got", "the end"))))
PY
      if grep -q '^UNMEASURED' "$WORK/console.out"; then
        echo "  no console to attach to here, so the console is unmeasured: $(cat "$WORK/console.out")"
      else
        grep -qx 'got 1368' "$WORK/console.out" ||
          { echo "  a 1,366-unit line did not read as its 1,368 bytes:"; sed 's/^/    /' "$WORK/console.out"; status=1; }
        grep -qx 'the end of input' "$WORK/console.out" ||
          { echo "  Ctrl+Z then Enter did not end the input:"; sed 's/^/    /' "$WORK/console.out"; status=1; }
        [ "$status" -eq 0 ] && echo "  a long line reads whole, and Ctrl+Z then Enter ends the input"
      fi
    fi
    ;;
esac

echo
if [ "$status" -eq 0 ]; then
  echo "all io exercise checks and failure proofs passed"
fi
exit $status
