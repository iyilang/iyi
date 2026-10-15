#!/usr/bin/env bash
# Exercises `std/term`.
#
#     bash bench/std_term_exercise.sh
#
# Proves the exercise holds plain and --release; drives both builds through
# a pseudo-terminal from Python's `pty` module - raw mode really is raw (a
# byte arrives without a newline, Ctrl-C is a byte and not a signal, CR
# stays CR), echo off really does not echo, a password is read without
# being shown, the previous termios is back after each block and after a
# panic in one (Python's `tcgetattr` and `stty -g` before and after), and
# `Term.size` follows the TIOCSWINSZ this side sets, as `stty size` and
# `os.get_terminal_size` do; checks the mode bits against Python's own
# termios constants; checks what the module refuses by its exact panic
# sentence; and proves each of those checks fails on a copy of the module
# broken in the way it guards against.
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
# The terminal half needs a pseudo-terminal, which Python's `pty` and
# `termios` give on Linux and darwin and Windows has neither of.
PTY=""
if [ -n "$PY" ] && "$PY" -c 'import pty, termios, fcntl' >/dev/null 2>&1 && command -v stty >/dev/null 2>&1; then
  PTY=yes
fi

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
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

# The exercise's own standard input is closed off: its terminal-free checks
# run a copy of itself with pipes on all three streams, and nothing here
# should wait on whoever started the gate.
build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_term_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" </dev/null >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

# The pseudo-terminal driver. `drive.py PROGRAM [section...]` runs PROGRAM
# with each mode the exercise knows inside a fresh pty whose slave end is
# the program's three standard streams and its controlling terminal - a
# session of its own, so Ctrl-C has a foreground group to signal - and
# prints `ok:` or `FAIL:` per check.
cat >"$WORK/drive.py" <<'PY'
import fcntl, itertools, os, select, signal, struct, subprocess, sys, termios, time

PROGRAM = sys.argv[1]
ONLY = sys.argv[2:]  # names of checks to run, all when empty
failures = []
# Each line as it is printed: a run the gate's `timeout` ends kept nothing
# of what it had found, and a darwin run that ran out said not one word.
sys.stdout.reconfigure(line_buffering=True)

# The session's leader, which owns the terminal and outlives the program it
# runs in its foreground group: darwin revokes a terminal whose session
# leader has gone, so with the program as leader the terminal could not be
# read after it, and every check of the mode left behind failed there. It
# catches SIGINT and SIGQUIT with a handler, which exec puts back to the
# default, so Ctrl-C still reaches the program; it writes the program's pid
# and then its exit status, and waits to be killed.
HERE = os.path.dirname(os.path.abspath(__file__))
LEADER = os.path.join(HERE, "leader.py")
with open(LEADER, "w") as leader:
    leader.write("""import os, signal, subprocess, sys, time
signal.signal(signal.SIGINT, lambda number, frame: None)
signal.signal(signal.SIGQUIT, lambda number, frame: None)
status = sys.argv[1]
child = subprocess.Popen(sys.argv[2:])
with open(status + ".pid", "w") as f:
    f.write(str(child.pid))
code = child.wait()
with open(status + ".part", "w") as f:
    f.write(str(code))
os.rename(status + ".part", status)
while True:
    time.sleep(60)
""")
RUNS = itertools.count()


def check(name, ok, detail=""):
    if ok:
        print(f"  ok: {name}")
    else:
        print(f"  FAIL: {name}" + (f" ({detail})" if detail else ""))
        failures.append(name)
    return ok


def set_size(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def stty_g(slave):
    return subprocess.run(["stty", "-g"], stdin=slave, capture_output=True, text=True).stdout.strip()


# The bit the kernel keeps for itself on darwin (see `Pty.restored`); 0
# elsewhere, where the kernel leaves the local flags as the program set them.
KERNEL_LFLAG = getattr(termios, "PENDIN", 0) if sys.platform == "darwin" else 0


def kernel_free(attrs):
    attrs = list(attrs)
    attrs[3] = attrs[3] & ~KERNEL_LFLAG
    return attrs


def stty_kernel_free(text):
    # `stty -g` is iflag:oflag:cflag:lflag:... in hex on both platforms.
    fields = text.split(":")
    if len(fields) > 3 and KERNEL_LFLAG:
        fields[3] = format(int(fields[3], 16) & ~KERNEL_LFLAG, "x")
    return ":".join(fields)



class Pty:
    def __init__(self, mode, rows=24, cols=80):
        self.master, self.slave = os.openpty()
        set_size(self.slave, rows, cols)
        # VMIN and VTIME away from a fresh pty's 1 and 0, which canonical
        # mode does not read: raw mode must write both, and a byte written
        # at the wrong index would otherwise land on the value already there.
        start = termios.tcgetattr(self.slave)
        start[6][termios.VMIN] = b"\x05"
        start[6][termios.VTIME] = b"\x03"
        termios.tcsetattr(self.slave, termios.TCSANOW, start)
        self.before = termios.tcgetattr(self.slave)
        self.before_stty = stty_g(self.slave)

        def controlling():
            # The new session's terminal, so ISIG has a foreground group to
            # signal: without it Ctrl-C would be a byte in every mode.
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        # The leader's status file: the program's exit, once it has one.
        self.status = os.path.join(HERE, f"status-{next(RUNS)}")
        self.proc = subprocess.Popen([sys.executable, LEADER, self.status, PROGRAM, mode],
                                     stdin=self.slave, stdout=self.slave, stderr=self.slave,
                                     start_new_session=True, preexec_fn=controlling)
        self.seen = b""

    def read_until(self, token, timeout=10.0):
        token = token.encode() if isinstance(token, str) else token
        deadline = time.monotonic() + timeout
        while token not in self.seen:
            left = deadline - time.monotonic()
            if left <= 0:
                return False
            ready, _, _ = select.select([self.master], [], [], left)
            if ready:
                try:
                    chunk = os.read(self.master, 4096)
                except OSError:
                    return False
                if not chunk:
                    return False
                self.seen += chunk
        return True

    def quiet_for(self, seconds):
        """What arrives in *seconds*, when nothing should."""
        start = len(self.seen)
        deadline = time.monotonic() + seconds
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                break
            ready, _, _ = select.select([self.master], [], [], left)
            if ready:
                try:
                    self.seen += os.read(self.master, 4096)
                except OSError:
                    break
        return self.seen[start:]

    def type(self, data):
        os.write(self.master, data.encode() if isinstance(data, str) else data)

    def now(self):
        return termios.tcgetattr(self.slave)

    # The program's exit status, from its leader: a negative number for the
    # signal that ended it, as subprocess says. One still running past
    # *timeout* is killed.
    def finish(self, timeout=10.0):
        deadline = time.monotonic() + timeout
        while not os.path.exists(self.status) and time.monotonic() < deadline:
            time.sleep(0.02)
        if not os.path.exists(self.status):
            try:
                os.kill(int(open(self.status + ".pid").read()), signal.SIGKILL)
            except (OSError, ValueError):
                pass
            later = time.monotonic() + 5.0
            while not os.path.exists(self.status) and time.monotonic() < later:
                time.sleep(0.02)
        code = int(open(self.status).read()) if os.path.exists(self.status) else None
        self.quiet_for(0.2)
        return code

    def restored(self, label):
        # Read while the leader holds the terminal. One that cannot be read
        # is this check failing, said by name. Compared without PENDIN on
        # darwin: BSD's tty layer sets it itself whenever ICANON comes back
        # on, to retype pending input, so a terminal a program restored
        # exactly reads back with it until the next read clears it.
        try:
            after = kernel_free(termios.tcgetattr(self.slave))
            detail = f"before {self.before[:4]} after {after[:4]}"
        except termios.error as error:
            after = None
            detail = f"the terminal could not be read after the program: {error}"
        check(f"{label}: the termios is the one before (Python tcgetattr)", after == kernel_free(self.before), detail)
        after_stty = stty_kernel_free(stty_g(self.slave))
        check(f"{label}: `stty -g` before and after agree", after_stty == stty_kernel_free(self.before_stty),
              f"{self.before_stty} / {after_stty}")

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        os.close(self.master)
        os.close(self.slave)


def flags(t):
    return t[0], t[1], t[2], t[3]


def cc_int(v):
    return v if isinstance(v, int) else v[0]


T = termios
RAW_I = T.IGNBRK | T.BRKINT | T.PARMRK | T.ISTRIP | T.INLCR | T.IGNCR | T.ICRNL | T.IXON
RAW_L = T.ECHO | T.ECHONL | T.ICANON | T.ISIG | T.IEXTEN
NOECHO_L = T.ECHO | T.ECHOE | T.ECHOK | T.ECHONL


def expected_raw(t):
    # termios(3)'s cfmakeraw, as Go's x/term makeRaw writes it, in the
    # numbers Python's termios module has for this machine.
    i, o, c, l = flags(t)
    return (i & ~RAW_I, o & ~T.OPOST, (c & ~(T.CSIZE | T.PARENB)) | T.CS8, l & ~RAW_L)


def wanted(name):
    return not ONLY or name in ONLY


if wanted("tty"):
    print("== tty? and size inside the pty")
    p = Pty("tty", 37, 101)
    check("tty? is true for the three standard streams", p.read_until("TTY in=true out=true err=true fd0=true"),
          p.seen.decode(errors="replace"))
    check("Python agrees the slave is a terminal", os.isatty(p.slave))
    p.finish()
    p.close()

if wanted("size"):
    print("== size follows TIOCSWINSZ")
    p = Pty("size", 37, 101)
    ok = p.read_until("SIZE 37 101 in=37 101 out=37 101")
    check("37 rows by 101 columns, as set before the start", ok, p.seen.decode(errors="replace")[-120:])
    stty = subprocess.run(["stty", "size"], stdin=p.slave, capture_output=True, text=True).stdout.strip()
    check("`stty size` says the same", stty == "37 101", stty)
    py = os.get_terminal_size(p.slave)
    check("Python's os.get_terminal_size says the same", (py.lines, py.columns) == (37, 101), str(py))
    set_size(p.slave, 50, 132)
    p.type("\n")
    check("50 by 132 after TIOCSWINSZ from this side", p.read_until("SIZE 50 132 in=50 132 out=50 132"),
          p.seen.decode(errors="replace")[-120:])
    set_size(p.slave, 1, 65535)
    p.type("\n")
    check("1 by 65535, the edge of the 16-bit fields", p.read_until("SIZE 1 65535"), p.seen.decode(errors="replace")[-120:])
    set_size(p.slave, 0, 0)
    p.type("\n")
    check("0 by 0 is no size", p.read_until("SIZE none in=none out=none"), p.seen.decode(errors="replace")[-120:])
    p.type("q\n")
    p.finish()
    p.close()

if wanted("cooked"):
    print("== the control: a terminal left alone")
    p = Pty("cooked")
    p.read_until("READY cooked-line")
    p.type("visible\n")
    ok = p.read_until('LINE "visible"')
    check("a line typed in cooked mode is echoed", ok and b"visible\r\n" in p.seen, repr(p.seen[-80:]))
    p.read_until("READY cooked")
    p.type("a")
    early = p.quiet_for(0.5)
    check("a byte waits for its newline in cooked mode", b"BYTE" not in early, repr(early))
    p.type("\x03")
    code = p.finish()
    check("Ctrl-C ends a cooked program with SIGINT", code == -signal.SIGINT, f"exit {code}")
    p.close()

if wanted("raw"):
    print("== raw mode is raw")
    p = Pty("raw")
    if check("the program enters raw mode", p.read_until("READY raw"), repr(p.seen)):
        during = p.now()
        want = expected_raw(p.before)
        check("the flags are cfmakeraw's, by Python's termios constants", flags(during) == want,
              f"want {[hex(x) for x in want]} got {[hex(x) for x in flags(during)]}")
        check("VMIN 1 and VTIME 0", cc_int(during[6][T.VMIN]) == 1 and cc_int(during[6][T.VTIME]) == 0,
              f"VMIN {during[6][T.VMIN]!r} VTIME {during[6][T.VTIME]!r}")
        check("the speeds are untouched", during[4:6] == p.before[4:6])
        p.type("a")
        check("a byte arrives without a newline", p.read_until("BYTE 97", 3.0), repr(p.seen[-60:]))
        check("and is not echoed", b"a" not in p.seen.split(b"READY raw", 1)[1].replace(b"BYTE 97", b""),
              repr(p.seen))
        p.type("\x03")
        check("Ctrl-C is byte 3, not a signal", p.read_until("BYTE 3\r", 3.0), repr(p.seen[-60:]))
        p.type("\r")
        check("CR stays CR (ICRNL off)", p.read_until("BYTE 13", 3.0), repr(p.seen[-60:]))
        check("the block's value comes back after it", p.read_until("DONE raw kept"), repr(p.seen[-60:]))
    code = p.finish()
    check("the raw program exits 0", code == 0, f"exit {code}")
    p.restored("raw")
    p.close()

if wanted("noecho"):
    print("== echo off does not echo")
    p = Pty("noecho")
    if check("the program turns echo off", p.read_until("READY noecho"), repr(p.seen)):
        during = p.now()
        i, o, c, l = flags(p.before)
        check("ECHO ECHOE ECHOK ECHONL off, nothing else changed",
              flags(during) == (i, o, c, l & ~NOECHO_L) and during[6] == p.before[6],
              f"lflag {hex(l)} -> {hex(during[3])}")
        p.type("secret\n")
        ok = p.read_until('LINE "secret"')
        check("the line is read whole", ok, repr(p.seen))
        check("and nothing of it was echoed", b"secret" not in p.seen.split(b"LINE", 1)[0], repr(p.seen))
        p.read_until("DONE noecho")
    code = p.finish()
    check("the noecho program exits 0", code == 0, f"exit {code}")
    p.restored("noecho")
    p.close()

if wanted("password"):
    print("== read_password")
    p = Pty("password")
    if check("the prompt is written", p.read_until("Password: "), repr(p.seen)):
        during = p.now()
        i, o, c, l = flags(p.before)
        check("echo off, ICANON ISIG ICRNL on (Go's readPassword)",
              flags(during) == (i | T.ICRNL, o, c, (l & ~NOECHO_L) | T.ICANON | T.ISIG),
              f"lflag {hex(l)} -> {hex(during[3])}")
        p.type("hunter2\r")
        ok = p.read_until('PW "hunter2"')
        check("the Enter key's CR ends the line", ok, repr(p.seen))
        check("the password is not echoed", b"hunter2" not in p.seen.split(b"PW", 1)[0], repr(p.seen))
        check("the newline the terminal did not echo is written", b"Password: \r\n" in p.seen, repr(p.seen))
        p.read_until("Again: ")
        p.type("\x04")
        check("Ctrl-D on an empty line is nil", p.read_until("PW nil"), repr(p.seen[-60:]))
        p.read_until("DONE password")
    code = p.finish()
    check("the password program exits 0", code == 0, f"exit {code}")
    p.restored("password")
    p.close()

if wanted("password-in-raw"):
    print("== read_password from inside raw mode")
    p = Pty("password-in-raw")
    if check("the prompt is written inside raw mode", p.read_until("Password: "), repr(p.seen)):
        during = p.now()
        check("the password mode turns ICANON and ICRNL back on", during[3] & T.ICANON and during[0] & T.ICRNL
              and not during[3] & T.ECHO, f"iflag {hex(during[0])} lflag {hex(during[3])}")
        # A typo and the erase key (the terminal's VERASE, DEL here): only a
        # canonical terminal edits the line before the program reads it.
        erase = p.before[6][T.VERASE]
        p.type(b"open sesamX" + erase + b"e\r")
        check("a password typed in raw mode is read as an edited line, ended by CR",
              p.read_until('PW "open sesame"', 3.0), repr(p.seen))
        check("and is not echoed", b"open sesam" not in p.seen.split(b"PW", 1)[0], repr(p.seen))
        if check("raw mode is back after the password", p.read_until("READY back-in-raw"), repr(p.seen)):
            check("raw is what is left", flags(p.now()) == expected_raw(p.before))
        p.type("z")
        p.read_until("DONE password-in-raw")
    code = p.finish()
    check("the password-in-raw program exits 0", code == 0, f"exit {code}")
    p.restored("password-in-raw")
    p.close()

if wanted("panic"):
    print("== a panic in the block restores the terminal")
    for mode, message in (("panic-raw", "boom inside raw"), ("panic-noecho", "boom inside no_echo")):
        p = Pty(mode)
        entered = p.read_until(f"READY {mode}")
        check(f"{mode}: the mode was entered", entered, repr(p.seen))
        if entered and mode == "panic-raw":
            check(f"{mode}: and it was raw", flags(p.now()) == expected_raw(p.before))
            p.type("x")
        if entered and mode == "panic-noecho":
            check(f"{mode}: and echo was off", p.now()[3] & T.ECHO == 0)
            p.type("go\n")
        code = p.finish()
        check(f"{mode}: the panic ends the program with 1", code == 1, f"exit {code}")
        check(f"{mode}: and prints its message", message.encode() in p.seen, repr(p.seen[-120:]))
        check(f"{mode}: nothing after the block ran", b"UNREACHED" not in p.seen)
        p.restored(mode)
        p.close()

if wanted("nested"):
    print("== nested modes unwind in order")
    p = Pty("nested")
    if check("raw inside echo-off", p.read_until("READY nested-raw"), repr(p.seen)):
        i, o, c, l = flags(p.before)
        check("raw is on, made from the echo-off mode", flags(p.now()) == expected_raw((i, o, c, l & ~NOECHO_L)))
        p.type("x")
        if check("leaving raw goes back to echo-off", p.read_until("READY nested-noecho"), repr(p.seen)):
            i, o, c, l = flags(p.before)
            check("echo-off is what is left", flags(p.now()) == (i, o, c, l & ~NOECHO_L))
        p.type("y\n")
        p.read_until("DONE nested")
    code = p.finish()
    check("the nested program exits 0", code == 0, f"exit {code}")
    p.restored("nested")
    p.close()

print(f"  {len(failures)} failed" if failures else "  all pty checks held")
sys.exit(1 if failures else 0)
PY

echo "== the std/term exercise, plain build"
build_and_run "plain" term-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/term-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every term section reported"
for phrase in "== tty? on a pipe, a file and descriptors that are not open" \
              "== size without a terminal" \
              "== raw and no_echo refuse a stream that is not a terminal" \
              "== read_password from a pipe" \
              "== a file and closed streams"; do
  if ! grep -qF "$phrase" "$WORK/term-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" term-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/term-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
else
  echo "  ALL CHECKS PASSED"
fi

echo
echo "== inside a pseudo-terminal, plain build (Python pty, stty, termios)"
if [ -z "$PTY" ]; then
  echo "  no Python pty, termios or stty on this machine, so the terminal half is unmeasured"
elif [ -x "$WORK/term-plain" ]; then
  if ! timeout 300 "$PY" "$WORK/drive.py" "$WORK/term-plain" >"$WORK/pty-plain.out" 2>&1; then
    status=1
  fi
  sed 's/^/  /' "$WORK/pty-plain.out"
fi

echo
echo "== inside a pseudo-terminal, --release"
if [ -z "$PTY" ]; then
  echo "  unmeasured, as above"
elif [ -x "$WORK/term-release" ]; then
  if timeout 300 "$PY" "$WORK/drive.py" "$WORK/term-release" >"$WORK/pty-release.out" 2>&1; then
    echo "  $(grep -c '^  ok:' "$WORK/pty-release.out") checks held"
  else
    grep -E 'FAIL|Traceback|Error' "$WORK/pty-release.out" | sed 's/^/  /'
    status=1
  fi
fi

echo
echo "== no C library on Linux"
# The module reaches the terminal by `ioctl` system calls there, as the
# prelude's `__iyi_isatty` does; a libc termios call in the binary would be
# a new link-time dependency (SPEC.md III.9).
if [ "$(uname -s)" = Linux ] && command -v nm >/dev/null 2>&1 && [ -x "$WORK/term-plain" ]; then
  if nm -u "$WORK/term-plain" | grep -E ' (ioctl|tcgetattr|tcsetattr|isatty|cfmakeraw)(@|$)'; then
    echo "  the exercise binds a libc terminal call"
    status=1
  else
    echo "  no ioctl, tcgetattr, tcsetattr or isatty among the binary's undefined symbols"
  fi
else
  echo "  not Linux, or no nm: unmeasured"
fi

echo
echo "== what term refuses"
# refuses <label> <name> <phrase> <stdin> <program>: the program must fail
# and say <phrase>, the sentence a person reading the panic acts on.
refuses() {
  local label="$1" name="$2" phrase="$3" input="$4"
  shift 4
  cat >"$WORK/$name.iyi" <<EOF
module $name

import std/term::{Term}

$*
EOF
  if "$IYI" run "$WORK/$name.iyi" <"$input" >"$WORK/$name.out" 2>&1; then
    echo "  $label: accepted"
    status=1
  elif ! grep -qF "$phrase" "$WORK/$name.out"; then
    echo "  $label: failed without the expected sentence ($phrase)"
    sed 's/^/    /' "$WORK/$name.out"
    status=1
  else
    echo "  $label: $phrase"
  fi
}
printf 'not a terminal\n' >"$WORK/input.txt"
refuses "raw on a closed stream" closed_raw "Term: cannot enter raw mode on a closed stream" /dev/null \
  'f = File.open("'"$WORK"'/input.txt"); f.close; Term.raw(f) { 1 }'
refuses "no_echo on a closed stream" closed_echo "Term: cannot turn echo off on a closed stream" /dev/null \
  'f = File.open("'"$WORK"'/input.txt"); f.close; Term.no_echo(f) { 1 }'
refuses "raw on a file, insisted on" file_raw "cannot enter raw mode on standard input: not a terminal" "$WORK/input.txt" \
  'Term.raw { 1 }.or_panic'
refuses "no_echo on a file opened by hand, insisted on" file_echo "cannot turn echo off on descriptor " /dev/null \
  'Term.no_echo(File.open("'"$WORK"'/input.txt")) { 1 }.or_panic'
# The descriptor's number is whatever the open was given; the reason after
# it is the part that is fixed.
if grep -qE "cannot turn echo off on descriptor [0-9]+: not a terminal" "$WORK/file_echo.out"; then
  echo "    ... N: not a terminal"
else
  echo "  no_echo on a file: the reason is missing"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <where> <old> <new>: the exercise must fail
# on a copy of the module with <old> replaced, at the check that names
# <phrase>. <where> is `plain` for the terminal-free exercise, or the
# driver's section names for the pseudo-terminal half.
prove_broken() {
  local label="$1" phrase="$2" where="$3"
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $label proof is unmeasured"
    return
  fi
  if [ "$where" != plain ] && [ -z "$PTY" ]; then
    echo "  no pseudo-terminal here, so the $label proof is unmeasured"
    return
  fi
  if ! OLD="$4" NEW="$5" "$PY" - "$REPO/src/std/term.iyi" "$WORK/patched/std/term.iyi" <<'PY'
import os, sys
src = open(sys.argv[1]).read()
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not unique")
open(sys.argv[2], "w").write(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $label patch did not apply"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/patched/program" \
       "$REPO/bench/std_term_exercise.iyi" >"$WORK/patched/build.log" 2>&1; then
    echo "  $label: the broken copy did not compile"
    sed -n '1,6p' "$WORK/patched/build.log" | sed 's/^/    /'
    status=1
    return
  fi
  local code
  if [ "$where" = plain ]; then
    "$WORK/patched/program" </dev/null >"$WORK/mut.out" 2>&1
    code=$?
  else
    # shellcheck disable=SC2086
    timeout 300 "$PY" "$WORK/drive.py" "$WORK/patched/program" $where >"$WORK/mut.out" 2>&1
    code=$?
  fi
  if [ "$code" -eq 0 ]; then
    echo "  the exercise PASSED on $label"
    status=1
  elif grep -qF "$phrase" "$WORK/mut.out"; then
    echo "  $label is caught"
  else
    echo "  $label failed, but not where it should have:"
    tail -3 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
case "$(uname -s)" in
  Linux)
    prove_broken "tty? answering yes for anything" "tty? is false for a pipe on standard input" plain \
      '      return false if fd > 2147483647_i64
      __iyi_isatty(fd.to_i32)' '      true'
    # The Linux arm's VMIN is byte 23; one short writes VTIME twice and
    # leaves the VMIN of 5 the driver sets before every run.
    prove_broken "VMIN written at the wrong byte" "FAIL: VMIN 1 and VTIME 0" raw \
      'VMIN_AT     = 17 + 6' 'VMIN_AT     = 16 + 6'
    ;;
esac
# Both platforms' arms of the refusal, so the proof means something on the
# one that compiles each: the POSIX line alone left Windows' intact.
prove_broken "a refusal that is not reported" "raw refuses a pipe and does not run the block" plain \
  '    {% if flag?(:win32) %}
      return TermError.new(operation, fd, code, false) if code != 0
    {% else %}
      return TermError.new(operation, fd, code, code != 25) if code != 0
    {% end %}
' ''
prove_broken "the prompt on standard output" "a password piped in is read" plain \
  'STDERR.write(prompt) unless prompt.empty?' 'STDOUT.write(prompt) unless prompt.empty?'
prove_broken "raw mode that keeps ICANON" "FAIL: a byte arrives without a newline" raw \
  'clear(mode, 3, ECHO | ECHONL | ICANON | ISIG | IEXTEN)' 'clear(mode, 3, ECHO | ECHONL | ISIG | IEXTEN)'
prove_broken "raw mode that keeps ISIG" "FAIL: Ctrl-C is byte 3, not a signal" raw \
  'clear(mode, 3, ECHO | ECHONL | ICANON | ISIG | IEXTEN)' 'clear(mode, 3, ECHO | ECHONL | ICANON | IEXTEN)'
prove_broken "echo off that keeps ECHO" "FAIL: and nothing of it was echoed" noecho \
  'clear(mode, 3, ECHO | ECHOE | ECHOK | ECHONL)' 'clear(mode, 3, ECHOE | ECHOK | ECHONL)'
prove_broken "a password read without ICANON back on" "FAIL: a password typed in raw mode is read as an edited line" password-in-raw \
  'set(mode, 3, ICANON | ISIG)' 'set(mode, 3, ISIG)'
prove_broken "the mode restored only when the block returns" "FAIL: panic-raw: the termios is the one before" panic \
  '    defer set_mode(fd, saved)
    yield' '    answer = yield
    set_mode(fd, saved)
    answer'
prove_broken "the mode never restored" 'FAIL: raw: `stty -g` before and after agree' raw \
  '    defer set_mode(fd, saved)
' ''
prove_broken "rows and columns swapped" "FAIL: 37 rows by 101 columns" size \
  '      rows = bytes[0].to_i32 | (bytes[1].to_i32 << 8)
      columns = bytes[2].to_i32 | (bytes[3].to_i32 << 8)' '      columns = bytes[0].to_i32 | (bytes[1].to_i32 << 8)
      rows = bytes[2].to_i32 | (bytes[3].to_i32 << 8)'
prove_broken "a 0 by 0 terminal given as a size" "FAIL: 0 by 0 is no size" size \
  '    return nil if rows <= 0 || columns <= 0
' ''

echo
if [ "$status" -eq 0 ]; then
  echo "std/term: all plain, release, pseudo-terminal, refusal and mutation checks passed"
else
  echo "std/term: exercise failed"
fi
exit $status
